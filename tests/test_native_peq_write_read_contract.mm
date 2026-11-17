// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_peq_write_read_contract.mm — RLPWorkbenchViewController PEQ 读写序号竞态契约
//
// 验证：
//   1. 扣留 onEqBypass POST 完成回调，期间 reloadEqPresets 发 GET 并返回旧 bypass/旧 presets，
//      随后放行正确 POST 成功；最终必须显示最新写状态，不能被 GET 递增 peqSeq 打掉。
//   2. 扣留 onEqPresetLoad POST 完成回调，期间 reloadEqPresets 发 GET 并返回旧 bypass/旧 presets，
//      随后放行正确 POST 成功；最终必须显示最新写状态，不能被 GET 递增 peqSeq 打掉。
//   3. 对照组：正常 onEqBypass / onEqPresetLoad POST 生效；以及旧 GET 先发后到不得覆盖较新写结果。
//
// 纪律：真实 RLPWorkbenchViewController + swizzle +[RLPCoreClient shared] 指向可控异步 mock，
//       不改写 production RLPCoreClient 实现、不启服务、不触碰 8899、不碰音频设备、不建可见窗口。
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "RLPCoreClient.h"
#import "RLPWorkbenchViewController.h"
#import "RLPEqualizerView.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

#include <cstdio>

static int g_pass = 0, g_fail = 0;
static void Ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++g_fail; }
}

@interface RLPWorkbenchViewController (PeqWriteReadContractAccess)
@property (nonatomic, assign) BOOL peqBypassed;
@property (nonatomic, copy) NSArray<NSString *> *eqPresetNames;
@property (nonatomic, strong) NSPopUpButton *eqPresetPopup;
@property (nonatomic, strong) NSPopUpButton *quickEqPresetPopup;
@property (nonatomic, strong) NSButton *quickEqBypassCheck;
@property (nonatomic, strong) NSTextField *quickEqStatusLabel;
- (void)reloadEqPresets;
- (void)onEqPresetLoad:(NSPopUpButton *)sender;
- (void)onEqBypass:(id)sender;
@end

#pragma mark - 可控异步 Mock 客户端（swizzle +[RLPCoreClient shared]）

@interface RLPPeqWriteReadSpy : NSObject
@property (nonatomic, assign) BOOL peqBypassed;
@property (nonatomic, copy) NSArray<NSString *> *peqPresets;
@property (nonatomic, assign) BOOL peqPresetLoadBypass;
@property (nonatomic, assign) BOOL holdPeqGet;
@property (nonatomic, strong) NSMutableArray<RLPJSONCompletion> *heldPeqGets;
@property (nonatomic, assign) BOOL holdPeqPost;
@property (nonatomic, strong) NSMutableArray<dispatch_block_t> *heldPeqPosts;
@property (nonatomic, strong) NSMutableArray<NSDictionary<NSString *, NSString *> *> *postLog;
@end

@implementation RLPPeqWriteReadSpy
- (instancetype)init {
    self = [super init];
    if (self) {
        _peqPresets = @[];
        _heldPeqGets = [NSMutableArray array];
        _heldPeqPosts = [NSMutableArray array];
        _postLog = [NSMutableArray array];
    }
    return self;
}

- (BOOL)started { return YES; }
- (BOOL)startEmbedded { return NO; }
- (void)shutdown {}

- (nullable NSDictionary *)jsonWithMethod:(NSString *)method path:(NSString *)path body:(nullable NSString *)body {
    (void)method; (void)path; (void)body;
    return nil;
}
- (nullable NSData *)dataWithMethod:(NSString *)method path:(NSString *)path body:(nullable NSString *)body
                        contentType:(NSString * _Nullable * _Nullable)contentType {
    (void)method; (void)path; (void)body; (void)contentType;
    return nil;
}
- (void)getData:(NSString *)path completion:(nullable RLPDataCompletion)done {
    (void)path;
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(nil); });
}
- (void)postData:(NSString *)path body:(NSData *)body contentType:(NSString *)contentType
      completion:(nullable RLPJSONCompletion)done {
    (void)path; (void)body; (void)contentType;
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(@{@"ok": @YES}); });
}

- (void)getJSON:(NSString *)path completion:(nullable RLPJSONCompletion)done {
    if (!done) return;
    NSString *p = path ?: @"";
    if ([p isEqualToString:@"/api/peq"]) {
        if (self.holdPeqGet) {
            [self.heldPeqGets addObject:[done copy]];
            return;
        }
        NSDictionary *resp = @{
            @"ok": @YES,
            @"bypass": @(self.peqBypassed),
            @"presets": self.peqPresets ?: @[],
            @"bands": @[],
        };
        dispatch_async(dispatch_get_main_queue(), ^{ done(resp); });
        return;
    }
    if ([p hasPrefix:@"/api/status"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            done(@{@"ok": @YES, @"playing": @NO, @"paused": @NO, @"current": @"", @"volDb": @(-120)});
        });
        return;
    }
    if ([p hasPrefix:@"/api/settings"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(@{@"ok": @YES, @"kv": @{}}); });
        return;
    }
    if ([p hasPrefix:@"/api/filters"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(@{@"ok": @YES, @"items": @[]}); });
        return;
    }
    if ([p hasPrefix:@"/api/devices"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(@{@"ok": @YES, @"devices": @[]}); });
        return;
    }
    if ([p hasPrefix:@"/api/rates"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(@{@"ok": @YES, @"rates": @[@44100, @48000]}); });
        return;
    }
    if ([p hasPrefix:@"/api/profiles"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(@{@"ok": @YES, @"profiles": @[], @"active": @""}); });
        return;
    }
    if ([p hasPrefix:@"/api/opra/"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(@{@"ok": @YES, @"items": @[]}); });
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ done(@{@"ok": @YES}); });
}

- (void)postJSON:(NSString *)path body:(nullable NSString *)body completion:(nullable RLPJSONCompletion)done {
    NSString *p = path ?: @"";
    NSString *b = body ?: @"";
    [self.postLog addObject:@{@"path": p, @"body": b}];

    if ([p isEqualToString:@"/api/peq"]) {
        BOOL nextBypass = self.peqBypassed;
        if ([b containsString:@"bypass=1"]) nextBypass = YES;
        else if ([b containsString:@"bypass=0"]) nextBypass = NO;
        NSDictionary *resp = @{@"ok": @YES, @"bypass": @(nextBypass)};
        RLPJSONCompletion doneCopy = [done copy];
        __weak __typeof__(self) weakSelf = self;
        dispatch_block_t deliver = ^{
            __typeof__(self) self_ = weakSelf;
            if (self_) self_.peqBypassed = nextBypass;
            if (doneCopy) doneCopy(resp);
        };
        if (self.holdPeqPost) {
            [self.heldPeqPosts addObject:[deliver copy]];
            return;
        }
        dispatch_async(dispatch_get_main_queue(), deliver);
        return;
    }
    if ([p isEqualToString:@"/api/peq/preset"]) {
        BOOL nextBypass = [b containsString:@"action=load"] ? self.peqPresetLoadBypass : self.peqBypassed;
        NSDictionary *resp = @{
            @"ok": @YES,
            @"bypass": @(nextBypass),
            @"presets": self.peqPresets ?: @[],
        };
        RLPJSONCompletion doneCopy = [done copy];
        __weak __typeof__(self) weakSelf = self;
        dispatch_block_t deliver = ^{
            __typeof__(self) self_ = weakSelf;
            if (self_) self_.peqBypassed = nextBypass;
            if (doneCopy) doneCopy(resp);
        };
        if (self.holdPeqPost) {
            [self.heldPeqPosts addObject:[deliver copy]];
            return;
        }
        dispatch_async(dispatch_get_main_queue(), deliver);
        return;
    }
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(@{@"ok": @YES}); });
}
@end

static RLPPeqWriteReadSpy *g_spy;
static id FakeSharedClient(id cls, SEL sel) { (void)cls; (void)sel; return g_spy; }

static void Pump(double seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}

static RLPWorkbenchViewController *MakeOffscreenWorkbench(void) {
    RLPWorkbenchViewController *vc = [[RLPWorkbenchViewController alloc] init];
    (void)vc.view;
    vc.view.frame = NSMakeRect(0, 0, 1080, 760);
    [vc.view layoutSubtreeIfNeeded];
    return vc;
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [RLPTheme setThemeName:@"light"];
        [RLPTheme setUiStyle:@"apple"];

        g_spy = [RLPPeqWriteReadSpy new];
        Method shared = class_getClassMethod(RLPCoreClient.class, @selector(shared));
        IMP origShared = method_setImplementation(shared, (IMP)FakeSharedClient);

        std::printf("=== test_native_peq_write_read_contract ===\n");

        // -----------------------------------------------------------------
        // 1. onEqBypass POST 在途 + 期间 reloadEqPresets GET 返回旧态
        //    放行正确 POST 后，必须显示最新写状态，不能被 GET 递增 peqSeq 打掉
        // -----------------------------------------------------------------
        {
            RLPWorkbenchViewController *vc = MakeOffscreenWorkbench();
            g_spy.holdPeqGet = NO;
            g_spy.holdPeqPost = NO;
            [g_spy.heldPeqGets removeAllObjects];
            [g_spy.heldPeqPosts removeAllObjects];
            g_spy.peqBypassed = NO;
            g_spy.peqPresets = @[@"Flat", @"Harman"];
            [vc reloadEqPresets];
            Pump(0.05);
            Ck(!vc.peqBypassed && vc.quickEqBypassCheck.state == NSControlStateValueOn,
               "1-precondition: initial peqBypassed=NO",
               [NSString stringWithFormat:@"bypass=%d state=%ld", vc.peqBypassed, (long)vc.quickEqBypassCheck.state]);

            // 扣留 onEqBypass 的 POST 完成回调（目标：bypass=1）
            g_spy.holdPeqPost = YES;
            vc.quickEqBypassCheck.state = NSControlStateValueOff;
            [vc onEqBypass:vc.quickEqBypassCheck];
            Ck(g_spy.heldPeqPosts.count == 1,
               "1-precondition: onEqBypass POST completion held",
               [NSString stringWithFormat:@"heldPosts=%lu", (unsigned long)g_spy.heldPeqPosts.count]);
            dispatch_block_t releaseBypassPost = g_spy.heldPeqPosts.firstObject;
            [g_spy.heldPeqPosts removeAllObjects];
            g_spy.holdPeqPost = NO;

            // POST 完成前，reloadEqPresets 发 GET 并返回旧 bypass=NO / 旧 presets
            g_spy.peqBypassed = NO;
            g_spy.peqPresets = @[@"Flat"];
            [vc reloadEqPresets];
            Pump(0.05);

            // 放行正确 POST 成功（@{@"ok": @YES, @"bypass": @YES}）
            if (releaseBypassPost) releaseBypassPost();
            Pump(0.05);

            Ck(vc.peqBypassed == YES && vc.quickEqBypassCheck.state == NSControlStateValueOff,
               "1: onEqBypass POST result survives intervening reloadEqPresets GET",
               [NSString stringWithFormat:@"bypass=%d state=%ld status=%@",
                vc.peqBypassed, (long)vc.quickEqBypassCheck.state, vc.quickEqStatusLabel.stringValue]);
        }

        // -----------------------------------------------------------------
        // 2. onEqPresetLoad POST 在途 + 期间 reloadEqPresets GET 返回旧态
        //    放行正确 POST 后，必须显示最新写状态，不能被 GET 递增 peqSeq 打掉
        // -----------------------------------------------------------------
        {
            RLPWorkbenchViewController *vc = MakeOffscreenWorkbench();
            g_spy.holdPeqGet = NO;
            g_spy.holdPeqPost = NO;
            [g_spy.heldPeqGets removeAllObjects];
            [g_spy.heldPeqPosts removeAllObjects];
            g_spy.peqBypassed = YES;
            g_spy.peqPresets = @[@"Flat", @"Harman"];
            [vc reloadEqPresets];
            Pump(0.05);
            Ck(vc.peqBypassed == YES && vc.quickEqBypassCheck.state == NSControlStateValueOff,
               "2-precondition: initial peqBypassed=YES",
               [NSString stringWithFormat:@"bypass=%d state=%ld", vc.peqBypassed, (long)vc.quickEqBypassCheck.state]);

            // 扣留 onEqPresetLoad 的 POST 完成回调（载入 Harman 后 bypass=NO）
            g_spy.holdPeqPost = YES;
            g_spy.peqPresetLoadBypass = NO;
            [vc.eqPresetPopup selectItemWithTitle:@"Harman"];
            [vc onEqPresetLoad:vc.eqPresetPopup];
            Ck(g_spy.heldPeqPosts.count == 1,
               "2-precondition: onEqPresetLoad POST completion held",
               [NSString stringWithFormat:@"heldPosts=%lu", (unsigned long)g_spy.heldPeqPosts.count]);
            dispatch_block_t releasePresetPost = g_spy.heldPeqPosts.firstObject;
            [g_spy.heldPeqPosts removeAllObjects];
            g_spy.holdPeqPost = NO;

            // POST 完成前，reloadEqPresets 发 GET 并返回旧 bypass=YES / 旧 presets=@[@"Flat"]
            g_spy.peqBypassed = YES;
            g_spy.peqPresets = @[@"Flat"];
            [vc reloadEqPresets];
            Pump(0.05);

            // 放行正确 POST 成功（@{@"ok": @YES, @"bypass": @NO}）
            if (releasePresetPost) releasePresetPost();
            Pump(0.05);

            Ck(vc.peqBypassed == NO && vc.quickEqBypassCheck.state == NSControlStateValueOn,
               "2: onEqPresetLoad POST result survives intervening reloadEqPresets GET",
               [NSString stringWithFormat:@"bypass=%d state=%ld status=%@",
                vc.peqBypassed, (long)vc.quickEqBypassCheck.state, vc.quickEqStatusLabel.stringValue]);
        }

        // -----------------------------------------------------------------
        // 3. 对照组 A：正常 POST（无并发 GET 干扰）
        // -----------------------------------------------------------------
        {
            RLPWorkbenchViewController *vc = MakeOffscreenWorkbench();
            g_spy.holdPeqGet = NO;
            g_spy.holdPeqPost = NO;
            g_spy.peqBypassed = NO;
            g_spy.peqPresets = @[@"Flat", @"Harman"];
            [vc reloadEqPresets];
            Pump(0.05);

            vc.quickEqBypassCheck.state = NSControlStateValueOff;
            [vc onEqBypass:vc.quickEqBypassCheck];
            Pump(0.05);
            Ck(vc.peqBypassed == YES && vc.quickEqBypassCheck.state == NSControlStateValueOff,
               "3a-control: normal onEqBypass POST applies bypass=YES",
               [NSString stringWithFormat:@"bypass=%d state=%ld", vc.peqBypassed, (long)vc.quickEqBypassCheck.state]);

            g_spy.peqPresetLoadBypass = NO;
            [vc.eqPresetPopup selectItemWithTitle:@"Harman"];
            [vc onEqPresetLoad:vc.eqPresetPopup];
            Pump(0.05);
            Ck(vc.peqBypassed == NO && vc.quickEqBypassCheck.state == NSControlStateValueOn,
               "3b-control: normal onEqPresetLoad POST applies bypass=NO",
               [NSString stringWithFormat:@"bypass=%d state=%ld", vc.peqBypassed, (long)vc.quickEqBypassCheck.state]);
        }

        // -----------------------------------------------------------------
        // 4. 对照组 B：旧 GET 先发后到，不得覆盖较新的 POST 写结果
        // -----------------------------------------------------------------
        {
            RLPWorkbenchViewController *vc = MakeOffscreenWorkbench();
            g_spy.holdPeqGet = NO;
            g_spy.holdPeqPost = NO;
            g_spy.peqBypassed = NO;
            g_spy.peqPresets = @[@"Flat", @"Harman"];
            [vc reloadEqPresets];
            Pump(0.05);

            // 旧 GET 先发并扣留
            g_spy.holdPeqGet = YES;
            [vc reloadEqPresets];
            Ck(g_spy.heldPeqGets.count == 1, "4a-precondition: stale GET held before bypass write",
               [NSString stringWithFormat:@"heldGets=%lu", (unsigned long)g_spy.heldPeqGets.count]);
            RLPJSONCompletion staleBypassGet = g_spy.heldPeqGets.firstObject;
            [g_spy.heldPeqGets removeAllObjects];
            g_spy.holdPeqGet = NO;

            // 较新的 onEqBypass POST 完成
            vc.quickEqBypassCheck.state = NSControlStateValueOff;
            [vc onEqBypass:vc.quickEqBypassCheck];
            Pump(0.05);
            Ck(vc.peqBypassed == YES && vc.quickEqBypassCheck.state == NSControlStateValueOff,
               "4a-precondition: newer onEqBypass write took effect",
               [NSString stringWithFormat:@"bypass=%d state=%ld", vc.peqBypassed, (long)vc.quickEqBypassCheck.state]);

            // 旧 GET 后到，带陈旧 bypass=NO
            if (staleBypassGet) staleBypassGet(@{@"ok": @YES, @"bypass": @NO, @"presets": @[@"Flat"]});
            Pump(0.05);
            Ck(vc.peqBypassed == YES && vc.quickEqBypassCheck.state == NSControlStateValueOff,
               "4a-control: stale GET arriving after onEqBypass POST does not overwrite write",
               [NSString stringWithFormat:@"bypass=%d state=%ld", vc.peqBypassed, (long)vc.quickEqBypassCheck.state]);
        }

        {
            RLPWorkbenchViewController *vc = MakeOffscreenWorkbench();
            g_spy.holdPeqGet = NO;
            g_spy.holdPeqPost = NO;
            g_spy.peqBypassed = YES;
            g_spy.peqPresets = @[@"Flat", @"Harman"];
            [vc reloadEqPresets];
            Pump(0.05);

            // 旧 GET 先发并扣留
            g_spy.holdPeqGet = YES;
            [vc reloadEqPresets];
            Ck(g_spy.heldPeqGets.count == 1, "4b-precondition: stale GET held before preset write",
               [NSString stringWithFormat:@"heldGets=%lu", (unsigned long)g_spy.heldPeqGets.count]);
            RLPJSONCompletion stalePresetGet = g_spy.heldPeqGets.firstObject;
            [g_spy.heldPeqGets removeAllObjects];
            g_spy.holdPeqGet = NO;

            // 较新的 onEqPresetLoad POST 完成
            g_spy.peqPresetLoadBypass = NO;
            [vc.eqPresetPopup selectItemWithTitle:@"Harman"];
            [vc onEqPresetLoad:vc.eqPresetPopup];
            Pump(0.05);
            Ck(vc.peqBypassed == NO && vc.quickEqBypassCheck.state == NSControlStateValueOn,
               "4b-precondition: newer onEqPresetLoad write took effect",
               [NSString stringWithFormat:@"bypass=%d state=%ld", vc.peqBypassed, (long)vc.quickEqBypassCheck.state]);

            // 旧 GET 后到，带陈旧 bypass=YES 与旧 presets
            if (stalePresetGet) stalePresetGet(@{@"ok": @YES, @"bypass": @YES, @"presets": @[@"Flat"]});
            Pump(0.05);
            Ck(vc.peqBypassed == NO && vc.quickEqBypassCheck.state == NSControlStateValueOn && vc.eqPresetNames.count == 2,
               "4b-control: stale GET arriving after onEqPresetLoad POST does not overwrite write",
               [NSString stringWithFormat:@"bypass=%d state=%ld presets=%@",
                vc.peqBypassed, (long)vc.quickEqBypassCheck.state, vc.eqPresetNames]);
        }

        // An obsolete write callback must release its in-flight marker so later reads can refresh.
        {
            RLPWorkbenchViewController *vc = MakeOffscreenWorkbench();
            g_spy.holdPeqGet = NO;
            g_spy.holdPeqPost = NO;
            g_spy.peqBypassed = NO;
            g_spy.peqPresets = @[@"Flat"];
            [vc reloadEqPresets];
            Pump(0.05);

            g_spy.holdPeqPost = YES;
            vc.quickEqBypassCheck.state = NSControlStateValueOff;
            [vc onEqBypass:vc.quickEqBypassCheck];
            Ck(g_spy.heldPeqPosts.count == 1, "5-precondition: obsolete write held", @"");
            dispatch_block_t releaseOldWrite = g_spy.heldPeqPosts.firstObject;
            [g_spy.heldPeqPosts removeAllObjects];
            g_spy.holdPeqPost = NO;

            [vc onEqBypass:vc.quickEqBypassCheck];
            Pump(0.05);
            if (releaseOldWrite) releaseOldWrite();
            Pump(0.05);

            g_spy.peqPresets = @[@"Flat", @"Harman"];
            [vc reloadEqPresets];
            Pump(0.05);
            Ck(vc.eqPresetNames.count == 2, "5: later read refreshes after an obsolete write returns",
               [NSString stringWithFormat:@"presets=%@", vc.eqPresetNames]);
        }

        method_setImplementation(shared, origShared);

        std::printf("RESULT: %d passed, %d failed\n", g_pass, g_fail);
        return g_fail ? 1 : 0;
    }
}
