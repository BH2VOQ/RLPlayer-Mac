// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_workbench_async_contract.mm — RLPWorkbenchViewController 异步竞态与状态契约
//
// 验证：
//   1. reloadEqPresets 旧 GET 不可覆盖较新的 bypass / preset 写结果
//   2. /api/peq 返回 nil 或 ok:false 不得清空已知 EQ 状态（bypass 与预设列表）
//   3. /api/health 返回 cancelled:true 或 code:analysis.cancelled 应呈中性非失败态
//   4. 音质监控总开关关闭后重开，同曲应可再次自动分析
//   5. viewDidDisappear 后到达的旧 /api/status 不得触发新的 /api/health
//   6. /api/profiles GET 失败（nil / ok:false）应保留旧列表与激活项
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

@interface RLPWorkbenchViewController (AsyncContractTestAccess)
@property (nonatomic, assign) BOOL peqBypassed;
@property (nonatomic, copy) NSArray<NSString *> *eqPresetNames;
@property (nonatomic, strong) NSPopUpButton *eqPresetPopup;
@property (nonatomic, strong) NSPopUpButton *quickEqPresetPopup;
@property (nonatomic, strong) NSButton *quickEqBypassCheck;
@property (nonatomic, strong) NSTextField *quickEqStatusLabel;
@property (nonatomic, strong) NSButton *monMasterCheck;
@property (nonatomic, strong) NSButton *monAutoCheck;
@property (nonatomic, strong) NSButton *monRetryBtn;
@property (nonatomic, strong) NSButton *tabBtnMonitor;
@property (nonatomic, strong) NSTextField *monDynValue;
@property (nonatomic, strong) NSTextField *monQualValue;
@property (nonatomic, strong) NSTextField *monFakeValue;
@property (nonatomic, strong) NSTextField *monAnlStatus;
@property (nonatomic, assign) BOOL monMasterEnabled;
@property (nonatomic, copy, nullable) NSDictionary *anlHealth;
@property (nonatomic, copy, nullable) NSString *anlError;
@property (nonatomic, copy, nullable) NSString *anlPath;
@property (nonatomic, copy, nullable) NSString *anlAutoDonePath;
@property (nonatomic, assign) BOOL anlBusy;
@property (nonatomic, copy) NSDictionary *settings;
@property (nonatomic, copy) NSDictionary *status;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *profiles;
@property (nonatomic, copy) NSString *profileActive;
@property (nonatomic, strong) NSTableView *profileTable;
@property (nonatomic, strong) NSTextField *profileStatus;
- (void)selectStudioTab:(NSString *)tab;
- (void)reloadEqPresets;
- (void)onEqPresetLoad:(NSPopUpButton *)sender;
- (void)onEqBypass:(id)sender;
- (void)onMonMasterChanged:(NSButton *)sender;
- (void)fetchMonitorHealthForPath:(NSString *)path force:(BOOL)force;
- (void)applyStatusPayload:(NSDictionary *)st forSeq:(NSUInteger)seq;
- (void)applySettingsPayload:(NSDictionary *)kv forSeq:(NSUInteger)seq;
- (void)reloadStatus;
- (void)reloadProfiles;
- (void)maybeAutoAnalyzeFromStatus;
@property (nonatomic, assign) NSUInteger statusSeq;
@end

#pragma mark - 可控异步 Mock 客户端（swizzle +[RLPCoreClient shared]）

@interface RLPWorkbenchAsyncSpy : NSObject
@property (nonatomic, assign) BOOL peqBypassed;
@property (nonatomic, copy) NSArray<NSString *> *peqPresets;
@property (nonatomic, assign) BOOL peqPresetLoadBypass;
@property (nonatomic, assign) BOOL holdPeqGet;
@property (nonatomic, strong) NSMutableArray<RLPJSONCompletion> *heldPeqGets;
@property (nonatomic, assign) BOOL returnNilForPeqGet;
@property (nonatomic, copy, nullable) NSDictionary *customPeqResponse;

@property (nonatomic, assign) BOOL holdHealthGet;
@property (nonatomic, strong) NSMutableArray<RLPJSONCompletion> *heldHealthGets;
@property (nonatomic, copy, nullable) NSDictionary *healthGetResponse;
@property (nonatomic, assign) NSInteger healthRequestCount;
@property (nonatomic, copy, nullable) NSString *lastHealthPath;

@property (nonatomic, assign) BOOL holdStatusGet;
@property (nonatomic, strong) NSMutableArray<RLPJSONCompletion> *heldStatusGets;
@property (nonatomic, copy, nullable) NSDictionary *statusGetResponse;

@property (nonatomic, assign) BOOL holdProfilesGet;
@property (nonatomic, strong) NSMutableArray<RLPJSONCompletion> *heldProfilesGets;
@property (nonatomic, assign) BOOL returnNilForProfilesGet;
@property (nonatomic, copy, nullable) NSDictionary *profilesGetResponse;

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *settingsKV;
@property (nonatomic, assign) NSInteger cancelCount;
@property (nonatomic, strong) NSMutableArray<NSDictionary<NSString *, NSString *> *> *postLog;
@end

@implementation RLPWorkbenchAsyncSpy
- (instancetype)init {
    self = [super init];
    if (self) {
        _peqPresets = @[];
        _heldPeqGets = [NSMutableArray array];
        _heldHealthGets = [NSMutableArray array];
        _heldStatusGets = [NSMutableArray array];
        _heldProfilesGets = [NSMutableArray array];
        _settingsKV = [NSMutableDictionary dictionary];
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
        NSDictionary *resp = nil;
        if (!self.returnNilForPeqGet) {
            resp = self.customPeqResponse ?: @{
                @"ok": @YES,
                @"bypass": @(self.peqBypassed),
                @"presets": self.peqPresets ?: @[],
                @"bands": @[],
            };
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(resp); });
        return;
    }
    if ([p hasPrefix:@"/api/health"]) {
        self.healthRequestCount += 1;
        self.lastHealthPath = p;
        if (self.holdHealthGet) {
            [self.heldHealthGets addObject:[done copy]];
            return;
        }
        NSDictionary *resp = self.healthGetResponse ?: @{
            @"ok": @YES,
            @"health": @{@"dr_available": @YES, @"dr_db": @14.5},
        };
        dispatch_async(dispatch_get_main_queue(), ^{ done(resp); });
        return;
    }
    if ([p hasPrefix:@"/api/status"]) {
        if (self.holdStatusGet) {
            [self.heldStatusGets addObject:[done copy]];
            return;
        }
        NSDictionary *resp = self.statusGetResponse ?: @{
            @"ok": @YES, @"playing": @NO, @"paused": @NO, @"current": @"", @"volDb": @(-120)
        };
        dispatch_async(dispatch_get_main_queue(), ^{ done(resp); });
        return;
    }
    if ([p hasPrefix:@"/api/profiles"]) {
        if (self.holdProfilesGet) {
            [self.heldProfilesGets addObject:[done copy]];
            return;
        }
        NSDictionary *resp = nil;
        if (!self.returnNilForProfilesGet) {
            resp = self.profilesGetResponse ?: @{@"ok": @YES, @"profiles": @[], @"active": @""};
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(resp); });
        return;
    }
    if ([p hasPrefix:@"/api/settings"]) {
        NSDictionary *kv = [self.settingsKV copy];
        dispatch_async(dispatch_get_main_queue(), ^{ done(@{@"ok": @YES, @"kv": kv}); });
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
        if ([b containsString:@"bypass=1"]) self.peqBypassed = YES;
        else if ([b containsString:@"bypass=0"]) self.peqBypassed = NO;
        NSDictionary *resp = @{@"ok": @YES, @"bypass": @(self.peqBypassed)};
        if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(resp); });
        return;
    }
    if ([p isEqualToString:@"/api/peq/preset"]) {
        if ([b containsString:@"action=load"]) self.peqBypassed = self.peqPresetLoadBypass;
        NSDictionary *resp = @{
            @"ok": @YES,
            @"bypass": @(self.peqBypassed),
            @"presets": self.peqPresets ?: @[],
        };
        if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(resp); });
        return;
    }
    if ([p isEqualToString:@"/api/anl/cancel"]) {
        self.cancelCount += 1;
        if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(@{@"ok": @YES}); });
        return;
    }
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(@{@"ok": @YES}); });
}
@end

static RLPWorkbenchAsyncSpy *g_spy;
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

        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        id savedMonPref = [ud objectForKey:@"RLPWorkbenchMonitorEnabled"];
        [ud setBool:YES forKey:@"RLPWorkbenchMonitorEnabled"];

        g_spy = [RLPWorkbenchAsyncSpy new];
        Method shared = class_getClassMethod(RLPCoreClient.class, @selector(shared));
        IMP origShared = method_setImplementation(shared, (IMP)FakeSharedClient);

        std::printf("=== test_native_workbench_async_contract ===\n");

        // -----------------------------------------------------------------
        // 1. reloadEqPresets 旧 GET 不可覆盖较新的 bypass / preset 写
        // -----------------------------------------------------------------
        {
            RLPWorkbenchViewController *vc = MakeOffscreenWorkbench();
            g_spy.peqBypassed = NO;
            g_spy.peqPresets = @[@"Flat", @"Harman"];
            [vc reloadEqPresets];
            Pump(0.05);
            Ck(!vc.peqBypassed && vc.quickEqBypassCheck.state == NSControlStateValueOn,
               "1a-precondition: initial peqBypassed=NO",
               [NSString stringWithFormat:@"bypass=%d state=%ld", vc.peqBypassed, (long)vc.quickEqBypassCheck.state]);

            // 挂起一个旧 GET /api/peq
            g_spy.holdPeqGet = YES;
            [vc reloadEqPresets];
            Ck(g_spy.heldPeqGets.count == 1, "1a-precondition: old GET /api/peq held",
               [NSString stringWithFormat:@"count=%lu", (unsigned long)g_spy.heldPeqGets.count]);
            RLPJSONCompletion staleBypassGet = g_spy.heldPeqGets.firstObject;
            [g_spy.heldPeqGets removeAllObjects];
            g_spy.holdPeqGet = NO;

            // 较新的 bypass=1 写完成
            vc.quickEqBypassCheck.state = NSControlStateValueOff;
            [vc onEqBypass:vc.quickEqBypassCheck];
            Pump(0.05);
            Ck(vc.peqBypassed == YES && vc.quickEqBypassCheck.state == NSControlStateValueOff,
               "1a-precondition: newer bypass=1 write took effect",
               [NSString stringWithFormat:@"bypass=%d state=%ld", vc.peqBypassed, (long)vc.quickEqBypassCheck.state]);

            // 旧 GET 回包到达，带着陈旧的 bypass=NO
            if (staleBypassGet) staleBypassGet(@{@"ok": @YES, @"bypass": @NO, @"presets": @[@"Flat", @"Harman"]});
            Pump(0.05);
            Ck(vc.peqBypassed == YES && vc.quickEqBypassCheck.state == NSControlStateValueOff,
               "1a: stale reloadEqPresets GET does not overwrite newer bypass write",
               [NSString stringWithFormat:@"bypass=%d state=%ld status=%@",
                vc.peqBypassed, (long)vc.quickEqBypassCheck.state, vc.quickEqStatusLabel.stringValue]);
        }

        {
            RLPWorkbenchViewController *vc = MakeOffscreenWorkbench();
            g_spy.peqBypassed = YES;
            g_spy.peqPresets = @[@"Flat", @"Harman"];
            [vc reloadEqPresets];
            Pump(0.05);

            // 挂起旧 GET /api/peq
            g_spy.holdPeqGet = YES;
            [vc reloadEqPresets];
            RLPJSONCompletion stalePresetGet = g_spy.heldPeqGets.firstObject;
            [g_spy.heldPeqGets removeAllObjects];
            g_spy.holdPeqGet = NO;

            // 较新的 preset load 完成（载入 Harman 后旁路关闭：bypass=NO）
            g_spy.peqPresetLoadBypass = NO;
            [vc.eqPresetPopup selectItemWithTitle:@"Harman"];
            [vc onEqPresetLoad:vc.eqPresetPopup];
            Pump(0.05);
            Ck(vc.peqBypassed == NO && vc.quickEqBypassCheck.state == NSControlStateValueOn,
               "1b-precondition: newer preset load set bypass=NO",
               [NSString stringWithFormat:@"bypass=%d state=%ld", vc.peqBypassed, (long)vc.quickEqBypassCheck.state]);

            // 旧 GET 回包到达，带着陈旧的 bypass=YES 与旧预设列表
            if (stalePresetGet) stalePresetGet(@{@"ok": @YES, @"bypass": @YES, @"presets": @[@"Flat"]});
            Pump(0.05);
            Ck(vc.peqBypassed == NO && vc.quickEqBypassCheck.state == NSControlStateValueOn && vc.eqPresetNames.count == 2,
               "1b: stale reloadEqPresets GET does not overwrite newer preset write",
               [NSString stringWithFormat:@"bypass=%d state=%ld presets=%@",
                vc.peqBypassed, (long)vc.quickEqBypassCheck.state, vc.eqPresetNames]);
        }

        // -----------------------------------------------------------------
        // 2. /api/peq 返回 nil / ok:false 不得清空已知 EQ 状态
        // -----------------------------------------------------------------
        {
            RLPWorkbenchViewController *vc = MakeOffscreenWorkbench();
            g_spy.peqBypassed = YES;
            g_spy.peqPresets = @[@"Harman", @"Studio"];
            g_spy.returnNilForPeqGet = NO;
            g_spy.customPeqResponse = nil;
            [vc reloadEqPresets];
            Pump(0.05);
            Ck(vc.peqBypassed == YES && vc.eqPresetNames.count == 2 && vc.eqPresetPopup.numberOfItems == 3,
               "2-precondition: known EQ state populated (bypass=YES, 2 presets)",
               [NSString stringWithFormat:@"bypass=%d names=%lu items=%ld",
                vc.peqBypassed, (unsigned long)vc.eqPresetNames.count, (long)vc.eqPresetPopup.numberOfItems]);

            g_spy.returnNilForPeqGet = YES;
            [vc reloadEqPresets];
            Pump(0.05);
            Ck(vc.peqBypassed == YES && vc.eqPresetNames.count == 2 &&
               vc.eqPresetPopup.numberOfItems == 3 && vc.quickEqPresetPopup.numberOfItems == 3 &&
               vc.quickEqBypassCheck.state == NSControlStateValueOff,
               "2a: nil /api/peq response preserves known EQ state",
               [NSString stringWithFormat:@"bypass=%d names=%@ eqItems=%ld quickItems=%ld",
                vc.peqBypassed, vc.eqPresetNames, (long)vc.eqPresetPopup.numberOfItems, (long)vc.quickEqPresetPopup.numberOfItems]);

            g_spy.returnNilForPeqGet = NO;
            g_spy.customPeqResponse = @{@"ok": @NO, @"error": @"peq_busy"};
            [vc reloadEqPresets];
            Pump(0.05);
            Ck(vc.peqBypassed == YES && vc.eqPresetNames.count == 2 &&
               vc.eqPresetPopup.numberOfItems == 3 && vc.quickEqPresetPopup.numberOfItems == 3 &&
               vc.quickEqBypassCheck.state == NSControlStateValueOff,
               "2b: ok:false /api/peq response preserves known EQ state",
               [NSString stringWithFormat:@"bypass=%d names=%@ eqItems=%ld quickItems=%ld",
                vc.peqBypassed, vc.eqPresetNames, (long)vc.eqPresetPopup.numberOfItems, (long)vc.quickEqPresetPopup.numberOfItems]);

            g_spy.customPeqResponse = nil;
        }

        // -----------------------------------------------------------------
        // 3. health cancelled:true / code:analysis.cancelled 应中性非失败
        // -----------------------------------------------------------------
        {
            RLPWorkbenchViewController *vc = MakeOffscreenWorkbench();
            [vc selectStudioTab:@"monitor"];
            vc.monMasterEnabled = YES;
            vc.settings = @{@"autoanl": @"0"};
            [vc applyStatusPayload:@{@"ok": @YES, @"playing": @YES, @"paused": @NO, @"current": @"/tmp/mock-cancelled.flac"} forSeq:1];

            g_spy.holdHealthGet = NO;
            g_spy.healthGetResponse = @{@"ok": @NO, @"cancelled": @YES, @"error": @"cancelled"};
            [vc fetchMonitorHealthForPath:@"/tmp/mock-cancelled.flac" force:YES];
            Pump(0.05);
            Ck(!vc.anlBusy && vc.anlError.length == 0 &&
               ![vc.monDynValue.stringValue isEqualToString:RLPTr(@"分析失败")] &&
               ![vc.monAnlStatus.stringValue containsString:RLPTr(@"分析失败")] &&
               ![vc.monRetryBtn.title isEqualToString:RLPTr(@"重试")],
               "3a: health cancelled:true stays neutral (non-failure)",
               [NSString stringWithFormat:@"busy=%d err=%@ dyn=%@ status=%@ retry=%@",
                vc.anlBusy, vc.anlError, vc.monDynValue.stringValue, vc.monAnlStatus.stringValue, vc.monRetryBtn.title]);

            g_spy.healthGetResponse = @{@"ok": @NO, @"code": @"analysis.cancelled", @"error": @"分析已取消"};
            [vc fetchMonitorHealthForPath:@"/tmp/mock-cancelled.flac" force:YES];
            Pump(0.05);
            Ck(!vc.anlBusy && vc.anlError.length == 0 &&
               ![vc.monDynValue.stringValue isEqualToString:RLPTr(@"分析失败")] &&
               ![vc.monAnlStatus.stringValue containsString:RLPTr(@"分析失败")] &&
               ![vc.monRetryBtn.title isEqualToString:RLPTr(@"重试")],
               "3b: health code:analysis.cancelled stays neutral (non-failure)",
               [NSString stringWithFormat:@"busy=%d err=%@ dyn=%@ status=%@ retry=%@",
                vc.anlBusy, vc.anlError, vc.monDynValue.stringValue, vc.monAnlStatus.stringValue, vc.monRetryBtn.title]);
        }

        // -----------------------------------------------------------------
        // 4. 监控关闭后重开，同曲应可自动分析
        // -----------------------------------------------------------------
        {
            RLPWorkbenchViewController *vc = MakeOffscreenWorkbench();
            [vc selectStudioTab:@"monitor"];
            vc.settings = @{@"autoanl": @"1"};
            vc.monMasterEnabled = YES;
            vc.monMasterCheck.state = NSControlStateValueOn;

            g_spy.healthRequestCount = 0;
            g_spy.holdHealthGet = YES;
            [vc applyStatusPayload:@{@"ok": @YES, @"playing": @YES, @"paused": @NO, @"current": @"/tmp/mock-reopen.flac"} forSeq:1];
            Ck(g_spy.healthRequestCount == 1 && vc.anlBusy == YES,
               "4-precondition: initial auto-analyze started for track",
               [NSString stringWithFormat:@"count=%ld busy=%d", (long)g_spy.healthRequestCount, vc.anlBusy]);

            // 关闭监控总开关（打断在途分析）
            vc.monMasterCheck.state = NSControlStateValueOff;
            [vc onMonMasterChanged:vc.monMasterCheck];
            Pump(0.05);
            [g_spy.heldHealthGets removeAllObjects];

            // 重新打开监控总开关（仍在播放同一曲目）
            g_spy.holdHealthGet = NO;
            g_spy.healthGetResponse = @{@"ok": @YES, @"health": @{@"dr_available": @YES, @"dr_db": @14.2}};
            vc.monMasterCheck.state = NSControlStateValueOn;
            [vc onMonMasterChanged:vc.monMasterCheck];
            Pump(0.05);
            Ck(g_spy.healthRequestCount == 2 && vc.anlHealth != nil,
               "4: reopening monitoring on same track triggers auto-analyze",
               [NSString stringWithFormat:@"count=%ld hasHealth=%d autoDone=%@",
                (long)g_spy.healthRequestCount, vc.anlHealth != nil, vc.anlAutoDonePath]);
        }

        // -----------------------------------------------------------------
        // 5. viewDidDisappear 后到达的旧 status 不能触发新的 health
        // -----------------------------------------------------------------
        {
            RLPWorkbenchViewController *vc = MakeOffscreenWorkbench();
            vc.settings = @{@"autoanl": @"1"};
            vc.monMasterEnabled = YES;

            g_spy.healthRequestCount = 0;
            g_spy.holdHealthGet = NO;
            g_spy.holdStatusGet = YES;
            [g_spy.heldStatusGets removeAllObjects];

            [vc reloadStatus];
            Ck(g_spy.heldStatusGets.count == 1,
               "5-precondition: status GET in flight",
               [NSString stringWithFormat:@"held=%lu", (unsigned long)g_spy.heldStatusGets.count]);
            RLPJSONCompletion staleStatusGet = g_spy.heldStatusGets.firstObject;
            [g_spy.heldStatusGets removeAllObjects];
            g_spy.holdStatusGet = NO;

            [vc viewDidDisappear];

            if (staleStatusGet) {
                staleStatusGet(@{@"ok": @YES, @"playing": @YES, @"paused": @NO, @"current": @"/tmp/mock-after-disappear.flac"});
            }
            Pump(0.05);
            Ck(g_spy.healthRequestCount == 0,
               "5: stale status arriving after viewDidDisappear does not trigger health",
               [NSString stringWithFormat:@"healthCount=%ld lastPath=%@",
                (long)g_spy.healthRequestCount, g_spy.lastHealthPath]);
        }

        // -----------------------------------------------------------------
        // Leaving during analysis must allow the same track to be analyzed after returning.
        {
            RLPWorkbenchViewController *vc = MakeOffscreenWorkbench();
            vc.settings = @{@"autoanl": @"1"};
            vc.monMasterEnabled = YES;
            vc.status = @{@"ok": @YES, @"playing": @YES, @"paused": @NO, @"current": @"/tmp/reenter-analysis.flac"};
            g_spy.healthRequestCount = 0;
            g_spy.holdHealthGet = YES;
            [g_spy.heldHealthGets removeAllObjects];
            [vc maybeAutoAnalyzeFromStatus];
            Ck(g_spy.heldHealthGets.count == 1, "7-precondition: health held before leaving", @"");
            RLPJSONCompletion staleHealth = g_spy.heldHealthGets.firstObject;
            [g_spy.heldHealthGets removeAllObjects];
            [vc viewDidDisappear];
            g_spy.holdHealthGet = NO;
            g_spy.healthGetResponse = @{@"ok": @YES, @"health": @{@"dr_available": @YES, @"dr_db": @14.0}};
            if (staleHealth) staleHealth(@{@"ok": @NO, @"error": @"cancelled-by-leave"});
            [vc activate];
            Pump(0.05);
            [vc applyStatusPayload:@{@"ok": @YES, @"playing": @YES, @"paused": @NO, @"current": @"/tmp/reenter-analysis.flac"} forSeq:vc.statusSeq];
            Pump(0.05);
            Ck(g_spy.healthRequestCount == 1, "7: same track is analyzed again after returning",
               [NSString stringWithFormat:@"count=%ld autoDone=%@", (long)g_spy.healthRequestCount, vc.anlAutoDonePath]);
        }

        // A delayed settings payload must not start analysis on a hidden workbench either.
        {
            RLPWorkbenchViewController *vc = MakeOffscreenWorkbench();
            vc.status = @{@"ok": @YES, @"playing": @YES, @"paused": @NO, @"current": @"/tmp/hidden-settings.flac"};
            vc.settings = @{@"autoanl": @"0"};
            vc.monMasterEnabled = YES;
            [vc viewDidDisappear];
            g_spy.healthRequestCount = 0;
            [vc applySettingsPayload:@{@"autoanl": @"1"} forSeq:0];
            Pump(0.05);
            Ck(g_spy.healthRequestCount == 0, "5b: delayed settings does not analyze after view disappears", @"");
        }

        // 6. profiles GET 失败应保留旧列表
        // -----------------------------------------------------------------
        {
            RLPWorkbenchViewController *vc = MakeOffscreenWorkbench();
            NSArray *initialProfiles = @[
                @{@"id": @"p1", @"name": @"Night", @"filter": @"poly-sinc-gauss-long"},
                @{@"id": @"p2", @"name": @"Reference", @"filter": @"sinc-M"},
            ];
            g_spy.holdProfilesGet = NO;
            g_spy.returnNilForProfilesGet = NO;
            g_spy.profilesGetResponse = @{@"ok": @YES, @"profiles": initialProfiles, @"active": @"p1"};
            [vc reloadProfiles];
            Pump(0.05);
            Ck(vc.profiles.count == 2 && [vc.profileActive isEqualToString:@"p1"] && vc.profileTable.numberOfRows == 2,
               "6-precondition: initial profiles loaded (2 items, active=p1)",
               [NSString stringWithFormat:@"count=%lu active=%@ rows=%ld",
                (unsigned long)vc.profiles.count, vc.profileActive, (long)vc.profileTable.numberOfRows]);

            g_spy.returnNilForProfilesGet = YES;
            [vc reloadProfiles];
            Pump(0.05);
            Ck(vc.profiles.count == 2 && [vc.profileActive isEqualToString:@"p1"] &&
               vc.profileTable.numberOfRows == 2 &&
               ![vc.profileStatus.stringValue isEqualToString:RLPTr(@"还没有配置档")],
               "6a: nil /api/profiles response preserves old profiles list",
               [NSString stringWithFormat:@"count=%lu active=%@ rows=%ld status=%@",
                (unsigned long)vc.profiles.count, vc.profileActive, (long)vc.profileTable.numberOfRows, vc.profileStatus.stringValue]);

            g_spy.returnNilForProfilesGet = NO;
            g_spy.profilesGetResponse = @{@"ok": @NO, @"error": @"disk_err"};
            [vc reloadProfiles];
            Pump(0.05);
            Ck(vc.profiles.count == 2 && [vc.profileActive isEqualToString:@"p1"] &&
               vc.profileTable.numberOfRows == 2 &&
               ![vc.profileStatus.stringValue isEqualToString:RLPTr(@"还没有配置档")],
               "6b: ok:false /api/profiles response preserves old profiles list",
               [NSString stringWithFormat:@"count=%lu active=%@ rows=%ld status=%@",
                (unsigned long)vc.profiles.count, vc.profileActive, (long)vc.profileTable.numberOfRows, vc.profileStatus.stringValue]);
        }

        // -----------------------------------------------------------------
        // 7. A1/A2/A4: status currentPath/path/file 兼容 + autoanl 开关/不重复/切歌取消/失败不暂停
        // -----------------------------------------------------------------
        {
            RLPWorkbenchViewController *vc = MakeOffscreenWorkbench();
            [vc selectStudioTab:@"monitor"];
            vc.monMasterEnabled = YES;
            vc.monMasterCheck.state = NSControlStateValueOn;
            vc.settings = @{@"autoanl": @"1"};

            g_spy.healthRequestCount = 0;
            g_spy.cancelCount = 0;
            [g_spy.heldHealthGets removeAllObjects];
            [g_spy.postLog removeAllObjects];
            g_spy.holdHealthGet = YES;

            [vc applyStatusPayload:@{@"ok": @YES, @"playing": @YES, @"paused": @NO,
                                     @"currentPath": @"/tmp/mock-curpath.flac"} forSeq:1];
            Ck([vc.anlPath isEqualToString:@"/tmp/mock-curpath.flac"] && g_spy.healthRequestCount == 1,
               "7a: status currentPath triggers one /api/health auto-analysis",
               [NSString stringWithFormat:@"path=%@ count=%ld", vc.anlPath, (long)g_spy.healthRequestCount]);

            // 同曲二次 status 不重复
            [vc applyStatusPayload:@{@"ok": @YES, @"playing": @YES, @"paused": @NO,
                                     @"currentPath": @"/tmp/mock-curpath.flac"} forSeq:2];
            Ck(g_spy.healthRequestCount == 1,
               "7b: repeated status for same currentPath does not duplicate health request",
               [NSString stringWithFormat:@"count=%ld", (long)g_spy.healthRequestCount]);

            // 切歌（path 字段）：取消在途分析并启动新曲
            [vc applyStatusPayload:@{@"ok": @YES, @"playing": @YES, @"paused": @NO,
                                     @"path": @"/tmp/mock-path2.flac"} forSeq:3];
            Ck(g_spy.cancelCount == 1 && [vc.anlPath isEqualToString:@"/tmp/mock-path2.flac"] &&
               g_spy.healthRequestCount == 2,
               "7c: track switch via path cancels previous and runs new track analysis",
               [NSString stringWithFormat:@"cancel=%ld path=%@ count=%ld",
                (long)g_spy.cancelCount, vc.anlPath, (long)g_spy.healthRequestCount]);

            // 分析失败不暂停播放
            g_spy.holdHealthGet = NO;
            RLPJSONCompletion hDone2 = g_spy.heldHealthGets.lastObject;
            [g_spy.heldHealthGets removeAllObjects];
            if (hDone2) hDone2(@{@"ok": @NO, @"error": @"decode failed"});
            Pump(0.05);
            [vc applyStatusPayload:@{@"ok": @YES, @"playing": @YES, @"paused": @NO,
                                     @"path": @"/tmp/mock-path2.flac"} forSeq:4];
            NSInteger pausePosts = 0;
            for (NSDictionary *p in g_spy.postLog) {
                if ([(NSString *)p[@"path"] containsString:@"/api/pause"]) ++pausePosts;
            }
            Ck(!vc.anlBusy && pausePosts == 0 && [vc.status[@"playing"] boolValue] && g_spy.healthRequestCount == 2,
               "7d: failed health leaves playing=YES, pause=0, and does not spam retries",
               [NSString stringWithFormat:@"busy=%d pause=%ld playing=%d count=%ld",
                vc.anlBusy, (long)pausePosts, [vc.status[@"playing"] boolValue], (long)g_spy.healthRequestCount]);

            // autoanl=0 + file 字段：路径可解析但不再发起自动分析
            vc.settings = @{@"autoanl": @"0"};
            [vc applyStatusPayload:@{@"ok": @YES, @"playing": @YES, @"paused": @NO,
                                     @"file": @"/tmp/mock-file3.flac"} forSeq:5];
            Ck([vc.anlPath isEqualToString:@"/tmp/mock-file3.flac"] && g_spy.healthRequestCount == 2,
               "7e: autoanl=0 parses file key without triggering auto-analysis",
               [NSString stringWithFormat:@"path=%@ count=%ld", vc.anlPath, (long)g_spy.healthRequestCount]);
        }

        // -----------------------------------------------------------------
        // 8. A3/A4: 点击音质监控页签及分析控件不触发 /api/pause 且不抢占焦点/空格
        // -----------------------------------------------------------------
        {
            RLPWorkbenchViewController *vc = MakeOffscreenWorkbench();
            NSWindow *wbWin = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 960, 720)
                                                          styleMask:NSWindowStyleMaskTitled
                                                            backing:NSBackingStoreBuffered defer:NO];
            wbWin.contentView = vc.view;
            [wbWin makeFirstResponder:nil];
            NSResponder *frBefore = wbWin.firstResponder;
            [vc selectStudioTab:@"ab"];
            vc.monMasterEnabled = YES;
            vc.settings = @{@"autoanl": @"1"};
            [vc applyStatusPayload:@{@"ok": @YES, @"playing": @YES, @"paused": @NO,
                                     @"currentPath": @"/tmp/mock-click.flac"} forSeq:1];
            Pump(0.05);
            [g_spy.postLog removeAllObjects];

            Ck(!vc.tabBtnMonitor.keyEquivalent.length && !vc.monMasterCheck.keyEquivalent.length &&
               !vc.monAutoCheck.keyEquivalent.length && !vc.monRetryBtn.keyEquivalent.length &&
               vc.tabBtnMonitor.refusesFirstResponder && vc.monMasterCheck.refusesFirstResponder &&
               vc.monAutoCheck.refusesFirstResponder && vc.monRetryBtn.refusesFirstResponder,
               "8a: monitor tab and controls have empty keyEquivalent and refusesFirstResponder=YES", @"");

            [vc.tabBtnMonitor performClick:nil];
            [vc.monAutoCheck performClick:nil];
            [vc.monRetryBtn performClick:nil];
            [vc.monMasterCheck performClick:nil];
            Pump(0.05);

            NSMutableArray<NSString *> *postSeq = [NSMutableArray array];
            NSInteger pausePosts = 0;
            for (NSDictionary *p in g_spy.postLog) {
                NSString *rp = p[@"path"] ?: @"";
                [postSeq addObject:[NSString stringWithFormat:@"POST %@", rp]];
                if ([rp containsString:@"/api/pause"]) ++pausePosts;
            }
            std::printf("A4 wb postLog (%lu): %s | pause=%ld\n",
                        (unsigned long)postSeq.count,
                        [postSeq componentsJoinedByString:@", "].UTF8String ?: "",
                        (long)pausePosts);
            Ck(pausePosts == 0 && [vc.status[@"playing"] boolValue] &&
               wbWin.firstResponder == frBefore && ![wbWin.firstResponder isKindOfClass:NSButton.class],
               "8b: clicking monitor controls produces 0 /api/pause requests, keeps playing=YES, and keeps firstResponder",
               [NSString stringWithFormat:@"pause=%ld playing=%d fr=%@ before=%@",
                (long)pausePosts, [vc.status[@"playing"] boolValue], wbWin.firstResponder, frBefore]);
            [wbWin orderOut:nil];
            static NSWindow *sWbWin; sWbWin = wbWin; (void)sWbWin;
        }

        method_setImplementation(shared, origShared);
        if (savedMonPref) [ud setObject:savedMonPref forKey:@"RLPWorkbenchMonitorEnabled"];
        else [ud removeObjectForKey:@"RLPWorkbenchMonitorEnabled"];

        std::printf("RESULT: %d passed, %d failed\n", g_pass, g_fail);
        return g_fail ? 1 : 0;
    }
}
