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
//   9. 顶部 trackCover：/api/status 加载封面、切歌清旧图、乱序丢弃、无封面/错图占位、暗色主题与 900x600(96pt)/1180x760(116pt) 布局
//   9-11. 顶部输出设备切换器：900×600/1180×760 可见不越界、fake A/B/C 切 B 发 POST 并刷新摘要、
//         失败回滚 A、空列表空态、devices 异步 seq 丢弃、英文文案完整、与 devicePopup 同步
//   12. 专业台重设计版式几何契约（R1–R3）：Hero 高度/封面(96/116)/首屏可见/独立信号链与 A-B 卡/响应式机架无溢出与无重叠
//
// 纪律：真实 RLPWorkbenchViewController + swizzle +[RLPCoreClient shared] 指向可控异步 mock，
//       不改写 production RLPCoreClient 实现、不启服务、不触碰 8899、不碰音频设备、不建可见窗口。
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "RLPCoreClient.h"
#import "RLPWorkbenchViewController.h"
#import "RLPWorkbench.h"
#import "RLPEqualizerView.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

#include <cmath>
#include <cstdio>

static int g_pass = 0, g_fail = 0;
static void Ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++g_fail; }
}

@interface RLPWorkbenchViewController (AsyncContractTestAccess)
@property (nonatomic, strong) NSScrollView *scroll;
@property (nonatomic, strong) NSStackView *stack;
@property (nonatomic, strong) NSStackView *topDeviceBar;
@property (nonatomic, strong) NSTextField *topDeviceLabel;
@property (nonatomic, strong) NSPopUpButton *topDevicePopup;
@property (nonatomic, strong) NSButton *topDeviceRefreshBtn;
@property (nonatomic, strong) NSPopUpButton *devicePopup;
@property (nonatomic, strong) NSTextField *sigOut;
@property (nonatomic, strong) NSTextField *statusMessage;
@property (nonatomic, strong) NSTextField *heroSpecLabel;
@property (nonatomic, strong) NSButton *trackPlayBtn;
@property (nonatomic, strong) NSView *chainCard;
@property (nonatomic, strong) NSStackView *rackHeaderRow;
@property (nonatomic, strong) NSStackView *rackStack;
@property (nonatomic, strong) NSView *rackPCM;
@property (nonatomic, strong) NSView *rackDSD;
@property (nonatomic, strong) NSView *rackOutput;
@property (nonatomic, assign) NSInteger rackColumns;
@property (nonatomic, assign) BOOL chainCompact;
@property (nonatomic, assign) BOOL abCompact;
@property (nonatomic, strong) NSMutableArray<NSView *> *abSlotCards;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *abSlots;
@property (nonatomic, strong) NSMutableArray<NSButton *> *abButtons;
@property (nonatomic, strong) NSMutableArray<NSTextField *> *abSummaries;
@property (nonatomic, assign) NSInteger abActive;
@property (nonatomic, copy) NSArray<NSDictionary *> *devices;
@property (nonatomic, assign) NSUInteger devicesSeq;
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
@property (nonatomic, strong) NSImageView *trackCover;
@property (nonatomic, strong, nullable) NSImageView *trackCoverPlaceholder;
@property (nonatomic, strong) NSTextField *trackTitle;
@property (nonatomic, strong) NSTextField *trackSub;
- (void)applyTheme;
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
- (void)reloadDevices;
- (void)reloadSettings;
- (void)onDeviceChanged:(NSPopUpButton *)sender;
- (void)applyDevicesPayload:(nullable NSDictionary *)json forSeq:(NSUInteger)seq;
- (void)applyLanguage;
- (void)maybeAutoAnalyzeFromStatus;
- (void)onABPick:(NSButton *)sender;
- (void)onABSave:(NSButton *)sender;
- (void)refreshAB;
- (void)postSettings:(NSDictionary<NSString *, NSString *> *)kv;
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

@property (nonatomic, copy) NSArray<NSDictionary *> *devicesGetList;
@property (nonatomic, assign) BOOL holdDevicesGet;
@property (nonatomic, strong) NSMutableArray<RLPJSONCompletion> *heldDevicesGets;
@property (nonatomic, assign) BOOL returnNilForDevicesGet;

@property (nonatomic, assign) BOOL failSettingsPost;
@property (nonatomic, assign) BOOL returnNilForSettingsPost;
@property (nonatomic, copy, nullable) NSString *settingsPostError;

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *settingsKV;
@property (nonatomic, assign) NSInteger cancelCount;
@property (nonatomic, strong) NSMutableArray<NSDictionary<NSString *, NSString *> *> *postLog;

@property (nonatomic, assign) BOOL holdGetData;
@property (nonatomic, strong) NSMutableArray<RLPDataCompletion> *heldGetDatas;
@property (nonatomic, strong) NSMutableArray<NSString *> *getDataLog;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSData *> *dataByPath;
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
        _devicesGetList = @[];
        _heldDevicesGets = [NSMutableArray array];
        _settingsKV = [NSMutableDictionary dictionary];
        _postLog = [NSMutableArray array];
        _heldGetDatas = [NSMutableArray array];
        _getDataLog = [NSMutableArray array];
        _dataByPath = [NSMutableDictionary dictionary];
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
    NSString *p = path ?: @"";
    [self.getDataLog addObject:p];
    if (self.holdGetData) {
        if (done) [self.heldGetDatas addObject:[done copy]];
        return;
    }
    NSData *resp = self.dataByPath[p];
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(resp); });
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
        if (self.holdDevicesGet) {
            [self.heldDevicesGets addObject:[done copy]];
            return;
        }
        NSDictionary *resp = self.returnNilForDevicesGet
            ? nil
            : @{@"ok": @YES, @"devices": self.devicesGetList ?: @[]};
        dispatch_async(dispatch_get_main_queue(), ^{ done(resp); });
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
    if ([p isEqualToString:@"/api/settings"]) {
        if (self.returnNilForSettingsPost) {
            if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(nil); });
            return;
        }
        if (self.failSettingsPost) {
            NSDictionary *resp = @{@"ok": @NO, @"error": self.settingsPostError ?: @"device_busy"};
            if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(resp); });
            return;
        }
        for (NSString *pair in [b componentsSeparatedByString:@"&"]) {
            NSRange eq = [pair rangeOfString:@"="];
            if (eq.location == NSNotFound) continue;
            NSString *k = [[pair substringToIndex:eq.location] stringByRemovingPercentEncoding] ?: @"";
            NSString *v = [[pair substringFromIndex:eq.location + 1] stringByRemovingPercentEncoding] ?: @"";
            if (k.length) self.settingsKV[k] = v;
        }
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

static BOOL HasCJKChars(NSString *s) {
    for (NSUInteger i = 0; i < s.length; ++i) {
        unichar c = [s characterAtIndex:i];
        if (c >= 0x4E00 && c <= 0x9FFF) return YES;
    }
    return NO;
}

static RLPWorkbenchViewController *MakeOffscreenWorkbench(void) {
    RLPWorkbenchViewController *vc = [[RLPWorkbenchViewController alloc] init];
    (void)vc.view;
    vc.view.frame = NSMakeRect(0, 0, 1080, 760);
    [vc.view layoutSubtreeIfNeeded];
    return vc;
}

static NSData *MakeSolidPNGData(NSInteger width, NSInteger height, NSColor *color) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height
                   bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:ctx];
    [color setFill];
    NSRectFill(NSMakeRect(0, 0, width, height));
    [NSGraphicsContext restoreGraphicsState];
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

static NSView * _Nullable FindSubviewByIdentifier(NSView *root, NSString *ident) {
    if ([root.identifier isEqualToString:ident]) return root;
    for (NSView *sub in root.subviews) {
        NSView *found = FindSubviewByIdentifier(sub, ident);
        if (found) return found;
    }
    return nil;
}

static NSString *DescribeBorderColor(CGColorRef cg) {
    if (!cg) return @"nil";
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorRef conv = CGColorCreateCopyByMatchingToColorSpace(srgb, kCGRenderingIntentDefault, cg, NULL);
    CGColorSpaceRelease(srgb);
    CGColorRef src = conv ?: cg;
    const size_t n = CGColorGetNumberOfComponents(src);
    const CGFloat *c = CGColorGetComponents(src);
    NSString *out = @"";
    if (n >= 4) out = [NSString stringWithFormat:@"rgba(%.3f,%.3f,%.3f,%.3f)", c[0], c[1], c[2], c[3]];
    else if (n == 2) out = [NSString stringWithFormat:@"gray(%.3f,a=%.3f)", c[0], c[1]];
    else out = [NSString stringWithFormat:@"comps(%zu)", n];
    if (conv) CGColorRelease(conv);
    return out;
}

static BOOL IsRedBorderColor(CGColorRef cg) {
    if (!cg) return NO;
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorRef conv = CGColorCreateCopyByMatchingToColorSpace(srgb, kCGRenderingIntentDefault, cg, NULL);
    CGColorSpaceRelease(srgb);
    CGColorRef src = conv ?: cg;
    const size_t n = CGColorGetNumberOfComponents(src);
    const CGFloat *c = CGColorGetComponents(src);
    BOOL isRed = NO;
    if (n >= 4) {
        isRed = (c[0] >= 0.65 && c[3] >= 0.8 && c[0] > c[1] * 1.8 && c[0] > c[2] * 1.8);
    }
    if (conv) CGColorRelease(conv);
    return isRed;
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
        NSString *savedLang = [RLPLanguage() copy];
        RLPSetLanguage(@"zh");

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

        // -----------------------------------------------------------------
        // 9. 顶部 trackCover：真实封面加载、切歌清旧图、乱序丢弃、失败占位与双尺寸 Hero 布局
        // -----------------------------------------------------------------
        {
            RLPWorkbenchViewController *vc = MakeOffscreenWorkbench();
            vc.view.frame = NSMakeRect(0, 0, 900, 600);
            [vc.view layoutSubtreeIfNeeded];

            NSView *trackCard = FindSubviewByIdentifier(vc.view, @"wb.trackcard");
            NSView *topRow = vc.trackCover.superview;
            NSView *detailBtn = FindSubviewByIdentifier(vc.view, @"wb.chaindetail");
            NSView *playBtn = FindSubviewByIdentifier(vc.view, @"wb.trackplay");
            NSImage *placeholderImg = vc.trackCover.image;
            const CGFloat cardHeightBefore = trackCard ? trackCard.frame.size.height : 0.0;
            const CGFloat topRowHeightBefore = topRow ? topRow.frame.size.height : 0.0;
            Ck(vc.trackCover != nil && placeholderImg != nil && placeholderImg.isTemplate &&
               std::fabs(vc.trackCover.frame.size.width - 96.0) <= 4.0 &&
               std::fabs(vc.trackCover.frame.size.height - 96.0) <= 14.0 &&
               trackCard != nil && cardHeightBefore >= 120.0 && topRowHeightBefore >= 120.0,
               "9-precondition: initial trackCover at 900x600 is 96x96 template placeholder in >=120pt hero",
               [NSString stringWithFormat:@"cover=%@ img=%@ tpl=%d size=%@ cardH=%.1f rowH=%.1f",
                vc.trackCover, placeholderImg, placeholderImg.isTemplate,
                NSStringFromSize(vc.trackCover.frame.size), cardHeightBefore, topRowHeightBefore]);

            NSData *pngA = MakeSolidPNGData(120, 80, NSColor.systemRedColor);
            NSData *pngB = MakeSolidPNGData(80, 120, NSColor.systemBlueColor);
            NSString *pathA = @"/tmp/mock-cover-a.flac";
            NSString *pathB = @"/tmp/mock-cover-b.flac";
            NSString *urlA = [NSString stringWithFormat:@"/api/cover?file=%@", RLPEnc(pathA)];
            NSString *urlB = [NSString stringWithFormat:@"/api/cover?file=%@", RLPEnc(pathB)];

            g_spy.holdGetData = NO;
            [g_spy.heldGetDatas removeAllObjects];
            [g_spy.getDataLog removeAllObjects];
            [g_spy.dataByPath removeAllObjects];
            g_spy.dataByPath[urlA] = pngA;
            g_spy.dataByPath[urlB] = pngB;
            g_spy.holdStatusGet = NO;

            // 9a: fake /api/status 返回曲 A，加载真实封面且状态轮询不重复打请求
            g_spy.statusGetResponse = @{
                @"ok": @YES, @"playing": @YES, @"paused": @NO,
                @"current": pathA, @"title": @"Track A", @"artist": @"Artist A", @"album": @"Album A",
            };
            [vc reloadStatus];
            Pump(0.05);
            [vc.view layoutSubtreeIfNeeded];
            Ck(vc.trackCover.image != nil && vc.trackCover.image != placeholderImg &&
               !vc.trackCover.image.isTemplate &&
               NSEqualSizes(vc.trackCover.image.size, NSMakeSize(120, 80)) &&
               std::fabs(vc.trackCover.frame.size.width - 96.0) <= 4.0 &&
               std::fabs(vc.trackCover.frame.size.height - 96.0) <= 14.0 &&
               (vc.trackCoverPlaceholder == nil || vc.trackCoverPlaceholder.hidden) &&
               std::fabs((topRow ? topRow.frame.size.height : 0.0) - topRowHeightBefore) <= 2.0 &&
               std::fabs(trackCard.frame.size.height - cardHeightBefore) <= 2.0 &&
               [g_spy.getDataLog containsObject:urlA],
               "9a: track A status loads real cover NSImage and keeps 96x96 & card height at 900x600",
               [NSString stringWithFormat:@"img=%@ tpl=%d imgSz=%@ frameSz=%@ rowH=%.1f/%.1f cardH=%.1f/%.1f log=%@",
                vc.trackCover.image, vc.trackCover.image.isTemplate,
                NSStringFromSize(vc.trackCover.image.size), NSStringFromSize(vc.trackCover.frame.size),
                topRow ? topRow.frame.size.height : 0.0, topRowHeightBefore,
                trackCard.frame.size.height, cardHeightBefore, g_spy.getDataLog]);

            const NSUInteger fetchCountAfterA = g_spy.getDataLog.count;
            [vc reloadStatus];
            Pump(0.05);
            Ck(g_spy.getDataLog.count == fetchCountAfterA &&
               NSEqualSizes(vc.trackCover.image.size, NSMakeSize(120, 80)),
               "9a-poll: repeated /api/status poll for same track A does not re-fetch or clear cover",
               [NSString stringWithFormat:@"count=%lu imgSz=%@",
                (unsigned long)g_spy.getDataLog.count, NSStringFromSize(vc.trackCover.image.size)]);

            // 9b: 切歌 A -> B，切歌瞬间立即清 A 的旧图；按序返回 B 后显示 B 且尺寸不变
            g_spy.holdGetData = YES;
            [g_spy.heldGetDatas removeAllObjects];
            g_spy.statusGetResponse = @{
                @"ok": @YES, @"playing": @YES, @"paused": @NO,
                @"current": pathB, @"title": @"Track B", @"artist": @"Artist B", @"album": @"Album B",
            };
            [vc reloadStatus];
            Pump(0.05);
            Ck(vc.trackCover.image == placeholderImg &&
               (vc.trackCoverPlaceholder == nil || !vc.trackCoverPlaceholder.hidden) &&
               g_spy.heldGetDatas.count == 1 && [g_spy.getDataLog.lastObject isEqualToString:urlB],
               "9b-pre: switching A->B immediately clears A's old cover before B callback returns",
               [NSString stringWithFormat:@"img=%@ held=%lu lastUrl=%@",
                vc.trackCover.image, (unsigned long)g_spy.heldGetDatas.count, g_spy.getDataLog.lastObject]);

            RLPDataCompletion cbB = g_spy.heldGetDatas.firstObject;
            [g_spy.heldGetDatas removeAllObjects];
            if (cbB) cbB(pngB);
            Pump(0.05);
            [vc.view layoutSubtreeIfNeeded];
            Ck(vc.trackCover.image != nil && vc.trackCover.image != placeholderImg &&
               !vc.trackCover.image.isTemplate &&
               NSEqualSizes(vc.trackCover.image.size, NSMakeSize(80, 120)) &&
               std::fabs(vc.trackCover.frame.size.width - 96.0) <= 4.0 &&
               std::fabs(vc.trackCover.frame.size.height - 96.0) <= 14.0 &&
               (vc.trackCoverPlaceholder == nil || vc.trackCoverPlaceholder.hidden),
               "9b: B cover callback shows B NSImage and keeps 96x96 at 900x600",
               [NSString stringWithFormat:@"imgSz=%@ frameSz=%@",
                NSStringFromSize(vc.trackCover.image.size), NSStringFromSize(vc.trackCover.frame.size)]);

            // 9c: 乱序回调丢弃 — 先请求 A 再切 B，B 先返回后到达的旧 A 回调不得覆盖 B
            [vc applyStatusPayload:@{@"ok": @YES, @"playing": @YES, @"current": pathA, @"title": @"Track A2"} forSeq:vc.statusSeq + 1];
            [vc applyStatusPayload:@{@"ok": @YES, @"playing": @YES, @"current": pathB, @"title": @"Track B2"} forSeq:vc.statusSeq + 1];
            Ck(g_spy.heldGetDatas.count == 2,
               "9c-precondition: both A and B cover requests held",
               [NSString stringWithFormat:@"held=%lu", (unsigned long)g_spy.heldGetDatas.count]);
            RLPDataCompletion staleCbA = g_spy.heldGetDatas[0];
            RLPDataCompletion freshCbB = g_spy.heldGetDatas[1];
            [g_spy.heldGetDatas removeAllObjects];
            freshCbB(pngB);
            Pump(0.05);
            staleCbA(pngA);
            Pump(0.05);
            Ck(NSEqualSizes(vc.trackCover.image.size, NSMakeSize(80, 120)) &&
               vc.trackCover.image != placeholderImg,
               "9c: stale cover callback for A arriving after B does not overwrite B",
               [NSString stringWithFormat:@"imgSz=%@", NSStringFromSize(vc.trackCover.image.size)]);

            // 9d: 无封面 (nil) / 损坏图片字节 / 空曲 均回到占位且不卡住
            g_spy.holdGetData = NO;
            [vc applyStatusPayload:@{@"ok": @YES, @"playing": @YES, @"current": @"/tmp/mock-no-cover.flac", @"title": @"No Cover"}
                            forSeq:vc.statusSeq + 1];
            Pump(0.05);
            Ck(vc.trackCover.image == placeholderImg &&
               (vc.trackCoverPlaceholder == nil || !vc.trackCoverPlaceholder.hidden) &&
               std::fabs(vc.trackCover.frame.size.width - 96.0) <= 4.0 &&
               std::fabs(vc.trackCover.frame.size.height - 96.0) <= 14.0,
               "9d-nil: track without cover displays placeholder and does not keep B's old image",
               [NSString stringWithFormat:@"img=%@ frameSz=%@", vc.trackCover.image, NSStringFromSize(vc.trackCover.frame.size)]);

            NSString *badPath = @"/tmp/mock-bad-cover.flac";
            g_spy.dataByPath[[NSString stringWithFormat:@"/api/cover?file=%@", RLPEnc(badPath)]] =
                [@"not-an-image" dataUsingEncoding:NSUTF8StringEncoding];
            [vc applyStatusPayload:@{@"ok": @YES, @"playing": @YES, @"current": badPath, @"title": @"Bad Cover"}
                            forSeq:vc.statusSeq + 1];
            Pump(0.05);
            Ck(vc.trackCover.image == placeholderImg &&
               (vc.trackCoverPlaceholder == nil || !vc.trackCoverPlaceholder.hidden),
               "9d-bad: invalid cover bytes safely fall back to placeholder", @"");

            [vc applyStatusPayload:@{@"ok": @YES, @"playing": @YES, @"current": pathA, @"title": @"Track A"}
                            forSeq:vc.statusSeq + 1];
            Pump(0.05);
            [vc applyStatusPayload:@{@"ok": @YES, @"playing": @NO, @"current": @""}
                            forSeq:vc.statusSeq + 1];
            Pump(0.05);
            Ck(vc.trackCover.image == placeholderImg &&
               (vc.trackCoverPlaceholder == nil || !vc.trackCoverPlaceholder.hidden),
               "9d-idle: empty current track resets cover to placeholder", @"");

            // 9e: 暗色主题可读性与 900x600 (96pt) / 1180x760 (116pt) Hero 内部零交叠、不越界
            [RLPTheme setThemeName:@"dark"];
            [vc applyTheme];
            Ck(vc.trackCover.layer.backgroundColor != nil &&
               (vc.trackCoverPlaceholder == nil || [vc.trackCoverPlaceholder.contentTintColor isEqual:[RLPTheme current].mut]),
               "9e-dark: dark theme updates placeholder tint and cover container background", @"");

            [vc applyStatusPayload:@{
                @"ok": @YES, @"playing": @YES, @"current": pathA,
                @"inRate": @96000, @"outBits": @24,
                @"title": @"Very Long Track Title That Should Truncate Without Overlapping Right Action Buttons In Narrow Layout",
                @"artist": @"Artist Name", @"album": @"Album Name",
            } forSeq:vc.statusSeq + 1];
            Pump(0.05);
            BOOL layoutOk900 = NO, layoutOk1180 = NO;
            NSString *heroLayoutDetail = @"";
            for (NSNumber *wNum in @[@900, @1180]) {
                const CGFloat w = [wNum doubleValue];
                const CGFloat h = (w < 1000.0) ? 600.0 : 760.0;
                const CGFloat expectedCover = (w < 1000.0) ? 96.0 : 116.0;
                vc.view.frame = NSMakeRect(0, 0, w, h);
                [vc.view layoutSubtreeIfNeeded];
                NSRect coverR = [vc.trackCover convertRect:vc.trackCover.bounds toView:trackCard];
                NSRect titleR = [vc.trackTitle convertRect:vc.trackTitle.bounds toView:trackCard];
                NSRect subR = [vc.trackSub convertRect:vc.trackSub.bounds toView:trackCard];
                NSRect specR = vc.heroSpecLabel ? [vc.heroSpecLabel convertRect:vc.heroSpecLabel.bounds toView:trackCard] : NSZeroRect;
                NSRect detailR = detailBtn ? [detailBtn convertRect:detailBtn.bounds toView:trackCard] : NSZeroRect;
                NSRect playR = playBtn ? [playBtn convertRect:playBtn.bounds toView:trackCard] : NSZeroRect;
                NSRect devBarR = vc.topDeviceBar ? [vc.topDeviceBar convertRect:vc.topDeviceBar.bounds toView:trackCard] : NSZeroRect;
                NSRect cardInset = NSInsetRect(trackCard.bounds, -0.5, -0.5);
                BOOL ok = std::fabs(vc.trackCover.frame.size.width - expectedCover) <= 4.0 &&
                          std::fabs(vc.trackCover.frame.size.height - expectedCover) <= 4.0 &&
                          trackCard.frame.size.height >= 120.0 &&
                          NSContainsRect(cardInset, coverR) &&
                          NSContainsRect(cardInset, titleR) &&
                          NSContainsRect(cardInset, detailR) &&
                          NSContainsRect(cardInset, playR) &&
                          NSContainsRect(cardInset, devBarR) &&
                          !NSIntersectsRect(coverR, titleR) &&
                          !NSIntersectsRect(coverR, subR) &&
                          !NSIntersectsRect(coverR, specR) &&
                          !NSIntersectsRect(coverR, detailR) &&
                          !NSIntersectsRect(coverR, devBarR) &&
                          !NSIntersectsRect(titleR, subR) &&
                          !NSIntersectsRect(titleR, specR) &&
                          !NSIntersectsRect(titleR, detailR) &&
                          !NSIntersectsRect(titleR, playR) &&
                          !NSIntersectsRect(titleR, devBarR) &&
                          !NSIntersectsRect(subR, detailR) &&
                          !NSIntersectsRect(subR, playR) &&
                          !NSIntersectsRect(subR, devBarR) &&
                          !NSIntersectsRect(specR, detailR) &&
                          !NSIntersectsRect(specR, playR) &&
                          !NSIntersectsRect(specR, devBarR) &&
                          !NSIntersectsRect(detailR, playR) &&
                          !NSIntersectsRect(detailR, devBarR) &&
                          !NSIntersectsRect(playR, devBarR);
                heroLayoutDetail = [heroLayoutDetail stringByAppendingFormat:@"[%.0fx%.0f cover=%.1fx%.1f card=%.1fx%.1f dev=%.1fx%.1f] ",
                                    w, h, vc.trackCover.frame.size.width, vc.trackCover.frame.size.height,
                                    trackCard.frame.size.width, trackCard.frame.size.height,
                                    devBarR.size.width, devBarR.size.height];
                if (w < 1000.0) layoutOk900 = ok;
                else layoutOk1180 = ok;
            }
            Ck(layoutOk900 && layoutOk1180 && NSEqualSizes(vc.trackCover.image.size, NSMakeSize(120, 80)),
               "9e-layout: 900x600 (96pt cover) and 1180x760 (116pt cover) preserve hero >=120 and zero overlap under dark theme",
               [NSString stringWithFormat:@"ok900=%d ok1180=%d %@", layoutOk900, layoutOk1180, heroLayoutDetail]);

            // 9f: 无路径仅有 albumKey 时通过 RLPCoverLoader 加载
            NSString *albKey = @"alb-wb-cover-1";
            g_spy.dataByPath[[NSString stringWithFormat:@"/api/lib/cover?k=%@", RLPEnc(albKey)]] = pngB;
            [vc applyStatusPayload:@{@"ok": @YES, @"playing": @YES, @"current": @"", @"albumKey": albKey, @"title": @"Album Only"}
                            forSeq:vc.statusSeq + 1];
            Pump(0.05);
            Ck(vc.trackCover.image != placeholderImg && !vc.trackCover.image.isTemplate &&
               NSEqualSizes(vc.trackCover.image.size, NSMakeSize(80, 120)),
               "9f: albumKey fallback loads cover via RLPCoverLoader",
               [NSString stringWithFormat:@"imgSz=%@", NSStringFromSize(vc.trackCover.image.size)]);

            [RLPTheme setThemeName:@"light"];
            g_spy.holdGetData = NO;
            [g_spy.dataByPath removeAllObjects];
            [g_spy.heldGetDatas removeAllObjects];
        }
        // 9. 顶部输出设备切换器位置/尺寸/不越界（900x600 / 1180x760 / 680x600）及初始选中 A
        // -----------------------------------------------------------------
        {
            NSArray<NSDictionary *> *abcDevices = @[
                @{@"id": @"devA", @"name": @"A", @"default": @YES},
                @{@"id": @"devB", @"name": @"B", @"default": @NO},
                @{@"id": @"devC", @"name": @"C", @"default": @NO},
            ];
            g_spy.failSettingsPost = NO;
            g_spy.returnNilForSettingsPost = NO;
            g_spy.holdDevicesGet = NO;
            g_spy.returnNilForDevicesGet = NO;
            g_spy.devicesGetList = abcDevices;
            g_spy.settingsKV = [@{@"device": @"devA", @"backend": @"coreaudio"} mutableCopy];
            [g_spy.postLog removeAllObjects];

            RLPWorkbenchViewController *vc = MakeOffscreenWorkbench();
            [vc reloadDevices];
            [vc reloadSettings];
            Pump(0.05);

            // 位于顶部 wb.trackcard（在页签栏 wb.tabs 之上）
            NSInteger trackIdx = NSNotFound, tabsIdx = NSNotFound;
            NSView *trackCard = nil;
            for (NSUInteger i = 0; i < vc.stack.arrangedSubviews.count; ++i) {
                NSView *v = vc.stack.arrangedSubviews[i];
                if ([v.identifier isEqualToString:@"wb.trackcard"]) { trackIdx = (NSInteger)i; trackCard = v; }
                if ([v.identifier isEqualToString:@"wb.tabs"]) tabsIdx = (NSInteger)i;
            }
            Ck(vc.topDeviceBar != nil && vc.topDevicePopup != nil && vc.topDeviceLabel != nil && vc.devicePopup != nil &&
               trackCard != nil && trackIdx != NSNotFound && tabsIdx != NSNotFound && trackIdx < tabsIdx &&
               [vc.topDevicePopup isDescendantOf:trackCard] &&
               !vc.topDeviceBar.isHidden && !vc.topDevicePopup.isHidden,
               "9a: top output device switcher exists inside top hero card above tabs and is visible",
               [NSString stringWithFormat:@"topPop=%@ card=%@ trackIdx=%ld tabsIdx=%ld",
                vc.topDevicePopup, trackCard, (long)trackIdx, (long)tabsIdx]);

            Ck([vc.topDevicePopup.titleOfSelectedItem isEqualToString:@"A"] &&
               [vc.devicePopup.titleOfSelectedItem isEqualToString:@"A"] &&
               [vc.sigOut.stringValue containsString:@"A"] &&
               vc.topDevicePopup.enabled && vc.devicePopup.enabled,
               "9b: fake devices A/B/C initially select A in both popups and top summary",
               [NSString stringWithFormat:@"top=%@ rack=%@ sigOut=%@",
                vc.topDevicePopup.titleOfSelectedItem, vc.devicePopup.titleOfSelectedItem, vc.sigOut.stringValue]);

            // 检查 900x600 / 1180x760 / 680x600（900 窗减侧栏）可见且不越界
            BOOL layoutOk = YES;
            NSMutableString *layoutDetail = [NSMutableString string];
            NSArray<NSValue *> *sizes = @[
                [NSValue valueWithSize:NSMakeSize(1180, 760)],
                [NSValue valueWithSize:NSMakeSize(900, 600)],
                [NSValue valueWithSize:NSMakeSize(680, 600)],
            ];
            for (NSValue *szVal in sizes) {
                NSSize sz = szVal.sizeValue;
                vc.view.frame = NSMakeRect(0, 0, sz.width, sz.height);
                [vc.view layoutSubtreeIfNeeded];
                NSRect barInView = [vc.topDeviceBar convertRect:vc.topDeviceBar.bounds toView:vc.view];
                NSRect labInBar = [vc.topDeviceLabel convertRect:vc.topDeviceLabel.bounds toView:vc.topDeviceBar];
                NSRect popInBar = [vc.topDevicePopup convertRect:vc.topDevicePopup.bounds toView:vc.topDeviceBar];
                NSRect refInBar = [vc.topDeviceRefreshBtn convertRect:vc.topDeviceRefreshBtn.bounds toView:vc.topDeviceBar];
                NSRect popInView = [vc.topDevicePopup convertRect:vc.topDevicePopup.bounds toView:vc.view];
                NSRect popInStack = [vc.topDevicePopup convertRect:vc.topDevicePopup.bounds toView:vc.stack];
                const CGFloat distFromTop = vc.stack.isFlipped
                    ? NSMaxY(popInStack)
                    : (NSMaxY(vc.stack.bounds) - NSMinY(popInStack));
                NSRect barInset = NSInsetRect(vc.topDeviceBar.bounds, -0.5, -0.5);
                const BOOL okSz = (NSMinX(barInView) >= -0.5 && NSMaxX(barInView) <= sz.width + 0.5 &&
                                   NSMinX(popInView) >= -0.5 && NSMaxX(popInView) <= sz.width + 0.5 &&
                                   NSContainsRect(barInset, labInBar) &&
                                   NSContainsRect(barInset, popInBar) &&
                                   NSContainsRect(barInset, refInBar) &&
                                   labInBar.size.width >= 20.0 && refInBar.size.width >= 20.0 &&
                                   NSMaxX(labInBar) <= NSMinX(popInBar) + 0.5 &&
                                   NSMaxX(popInBar) <= NSMinX(refInBar) + 0.5 &&
                                   popInView.size.width >= 150.0 && popInView.size.height >= 18.0 &&
                                   distFromTop > 0.0 && distFromTop <= sz.height);
                if (!okSz) {
                    layoutOk = NO;
                    [layoutDetail appendFormat:@"[%.0fx%.0f bar=%@ lab=%@ pop=%@ ref=%@ distTop=%.1f] ",
                     sz.width, sz.height, NSStringFromRect(barInView), NSStringFromRect(labInBar),
                     NSStringFromRect(popInView), NSStringFromRect(refInBar), distFromTop];
                }
            }
            Ck(layoutOk, "9c: top device switcher fits cleanly without clipping at 1180x760, 900x600, and 680x600", layoutDetail);
        }

        // -----------------------------------------------------------------
        // 10. 选 B 发 POST 并刷新 UI 摘要为 B；POST 失败 toast 且回滚 A；两处下拉双向同步
        // -----------------------------------------------------------------
        {
            NSArray<NSDictionary *> *abcDevices = @[
                @{@"id": @"devA", @"name": @"A", @"default": @YES},
                @{@"id": @"devB", @"name": @"B", @"default": @NO},
                @{@"id": @"devC", @"name": @"C", @"default": @NO},
            ];
            g_spy.failSettingsPost = NO;
            g_spy.returnNilForSettingsPost = NO;
            g_spy.holdDevicesGet = NO;
            g_spy.returnNilForDevicesGet = NO;
            g_spy.devicesGetList = abcDevices;
            g_spy.settingsKV = [@{@"device": @"devA", @"backend": @"coreaudio"} mutableCopy];
            [g_spy.postLog removeAllObjects];

            RLPWorkbenchViewController *vc = MakeOffscreenWorkbench();
            [vc reloadDevices];
            [vc reloadSettings];
            Pump(0.05);

            // 10a: 选 B 发 POST /api/settings device=devB 且 UI 摘要刷新为 B
            [vc.topDevicePopup selectItemWithTitle:@"B"];
            [vc onDeviceChanged:vc.topDevicePopup];
            Pump(0.05);

            BOOL postedB = NO;
            for (NSDictionary *p in g_spy.postLog) {
                if ([p[@"path"] isEqualToString:@"/api/settings"] && [p[@"body"] isEqualToString:@"device=devB"]) {
                    postedB = YES;
                }
            }
            Ck(postedB &&
               [vc.topDevicePopup.titleOfSelectedItem isEqualToString:@"B"] &&
               [vc.devicePopup.titleOfSelectedItem isEqualToString:@"B"] &&
               [vc.settings[@"device"] isEqualToString:@"devB"] &&
               [vc.sigOut.stringValue containsString:@"B"],
               "10a: selecting B posts device=devB, syncs both popups, and refreshes top summary to B",
               [NSString stringWithFormat:@"postedB=%d top=%@ rack=%@ settingsDev=%@ sigOut=%@",
                postedB, vc.topDevicePopup.titleOfSelectedItem, vc.devicePopup.titleOfSelectedItem,
                vc.settings[@"device"], vc.sigOut.stringValue]);

            // 10b: 切回 A 后模拟请求失败（ok:NO 与 nil）：应保留原值并回滚到 A（两处下拉与摘要均为 A）
            [vc.topDevicePopup selectItemWithTitle:@"A"];
            [vc onDeviceChanged:vc.topDevicePopup];
            Pump(0.05);

            [g_spy.postLog removeAllObjects];
            g_spy.failSettingsPost = YES;
            g_spy.settingsPostError = @"device_switch_failed";
            [vc.topDevicePopup selectItemWithTitle:@"B"];
            [vc onDeviceChanged:vc.topDevicePopup];
            Pump(0.05);

            BOOL postedFailB = NO;
            for (NSDictionary *p in g_spy.postLog) {
                if ([p[@"path"] isEqualToString:@"/api/settings"] && [p[@"body"] isEqualToString:@"device=devB"]) postedFailB = YES;
            }
            Ck(postedFailB &&
               [vc.topDevicePopup.titleOfSelectedItem isEqualToString:@"A"] &&
               [vc.devicePopup.titleOfSelectedItem isEqualToString:@"A"] &&
               [vc.settings[@"device"] isEqualToString:@"devA"] &&
               [vc.sigOut.stringValue containsString:@"A"] &&
               [vc.statusMessage.stringValue isEqualToString:RLPTr(@"保存失败，已保留原值")],
               "10b: failed POST /api/settings (ok:NO) rolls back both popups and summary to A",
               [NSString stringWithFormat:@"posted=%d top=%@ rack=%@ settingsDev=%@ sigOut=%@ msg=%@",
                postedFailB, vc.topDevicePopup.titleOfSelectedItem, vc.devicePopup.titleOfSelectedItem,
                vc.settings[@"device"], vc.sigOut.stringValue, vc.statusMessage.stringValue]);

            g_spy.failSettingsPost = NO;
            g_spy.returnNilForSettingsPost = YES;
            [vc.topDevicePopup selectItemWithTitle:@"C"];
            [vc onDeviceChanged:vc.topDevicePopup];
            Pump(0.05);
            Ck([vc.topDevicePopup.titleOfSelectedItem isEqualToString:@"A"] &&
               [vc.devicePopup.titleOfSelectedItem isEqualToString:@"A"] &&
               [vc.settings[@"device"] isEqualToString:@"devA"] &&
               [vc.sigOut.stringValue containsString:@"A"] &&
               [vc.statusMessage.stringValue isEqualToString:RLPTr(@"保存失败，已保留原值")],
               "10b2: nil POST /api/settings response rolls back both popups and summary to A",
               [NSString stringWithFormat:@"top=%@ rack=%@ settingsDev=%@ sigOut=%@",
                vc.topDevicePopup.titleOfSelectedItem, vc.devicePopup.titleOfSelectedItem,
                vc.settings[@"device"], vc.sigOut.stringValue]);
            g_spy.returnNilForSettingsPost = NO;

            // 10c: 从输出规格卡 devicePopup 选 C，顶部 topDevicePopup 与摘要同步变为 C
            g_spy.failSettingsPost = NO;
            [vc.devicePopup selectItemWithTitle:@"C"];
            [vc onDeviceChanged:vc.devicePopup];
            Pump(0.05);
            Ck([vc.topDevicePopup.titleOfSelectedItem isEqualToString:@"C"] &&
               [vc.devicePopup.titleOfSelectedItem isEqualToString:@"C"] &&
               [vc.sigOut.stringValue containsString:@"C"],
               "10c: changing rack devicePopup to C syncs topDevicePopup and summary to C",
               [NSString stringWithFormat:@"top=%@ rack=%@ sigOut=%@",
                vc.topDevicePopup.titleOfSelectedItem, vc.devicePopup.titleOfSelectedItem, vc.sigOut.stringValue]);
        }

        // -----------------------------------------------------------------
        // 11. 空设备列表空态 + devices 异步 seq 丢弃旧结果 + 英文文案完整
        // -----------------------------------------------------------------
        {
            g_spy.failSettingsPost = NO;
            g_spy.returnNilForSettingsPost = NO;
            g_spy.holdDevicesGet = NO;
            g_spy.returnNilForDevicesGet = NO;
            g_spy.devicesGetList = @[];
            g_spy.settingsKV = [@{@"device": @"", @"backend": @"coreaudio"} mutableCopy];

            RLPWorkbenchViewController *vc = MakeOffscreenWorkbench();
            [vc reloadDevices];
            [vc reloadSettings];
            Pump(0.05);

            NSString *emptyTitle = vc.topDevicePopup.titleOfSelectedItem ?: @"";
            Ck(vc.topDevicePopup.enabled && vc.devicePopup.enabled &&
               vc.topDevicePopup.numberOfItems == 1 && vc.devicePopup.numberOfItems == 1 &&
               [emptyTitle containsString:@"未发现设备"] && [emptyTitle containsString:@"系统默认"] &&
               [vc.devicePopup.titleOfSelectedItem isEqualToString:emptyTitle] &&
               [vc.sigOut.stringValue containsString:@"未发现设备"],
               "11a: empty device list shows non-disabled empty state (not blank) in both popups and summary",
               [NSString stringWithFormat:@"enabled=%d/%d items=%ld title=%@ sigOut=%@",
                vc.topDevicePopup.enabled, vc.devicePopup.enabled,
                (long)vc.topDevicePopup.numberOfItems, emptyTitle, vc.sigOut.stringValue]);

            // 11b: 英文文案完整（空态 + 有设备默认项 + 顶部标签）
            RLPSetLanguage(@"en");
            [vc applyLanguage];
            NSString *enEmpty = vc.topDevicePopup.titleOfSelectedItem ?: @"";
            Ck([vc.topDeviceLabel.stringValue isEqualToString:@"Output Device"] &&
               !HasCJKChars(vc.topDeviceLabel.stringValue) &&
               !HasCJKChars(enEmpty) && !HasCJKChars(vc.sigOut.stringValue) &&
               [enEmpty containsString:@"System default"],
               "11b: English copy is complete with no leftover Chinese in empty state",
               [NSString stringWithFormat:@"label=%@ empty=%@ sigOut=%@",
                vc.topDeviceLabel.stringValue, enEmpty, vc.sigOut.stringValue]);

            // 有设备时英文“系统默认”项也应为英文
            g_spy.devicesGetList = @[
                @{@"id": @"devA", @"name": @"A"},
                @{@"id": @"devB", @"name": @"B"},
            ];
            [vc reloadDevices];
            Pump(0.05);
            NSString *enDefItem = [vc.topDevicePopup itemAtIndex:0].title ?: @"";
            Ck([enDefItem isEqualToString:@"System default"] &&
               [vc.devicePopup itemAtIndex:0].title &&
               [[vc.devicePopup itemAtIndex:0].title isEqualToString:@"System default"] &&
               !HasCJKChars(vc.sigOut.stringValue),
               "11c: English System default item and summary have complete English copy",
               [NSString stringWithFormat:@"def0=%@ sigOut=%@", enDefItem, vc.sigOut.stringValue]);
            RLPSetLanguage(@"zh");
            [vc applyLanguage];

            // 11d: devices 异步回包按 seq 丢弃旧结果
            g_spy.holdDevicesGet = YES;
            [g_spy.heldDevicesGets removeAllObjects];
            [vc reloadDevices]; // req1 (older)
            Ck(g_spy.heldDevicesGets.count == 1, "11d-precondition: older devices GET held", @"");
            RLPJSONCompletion staleDevicesGet = g_spy.heldDevicesGets.firstObject;
            [g_spy.heldDevicesGets removeAllObjects];
            g_spy.holdDevicesGet = NO;

            g_spy.devicesGetList = @[
                @{@"id": @"devB", @"name": @"B"},
                @{@"id": @"devC", @"name": @"C"},
            ];
            [vc reloadDevices]; // req2 (newer)
            Pump(0.05);

            // 旧回包携带陈旧设备 StaleDAC 迟到
            if (staleDevicesGet) {
                staleDevicesGet(@{@"ok": @YES, @"devices": @[@{@"id": @"stale", @"name": @"StaleDAC"}]});
            }
            Pump(0.05);
            BOOL hasStale = NO;
            for (NSMenuItem *it in vc.topDevicePopup.itemArray) {
                if ([it.title isEqualToString:@"StaleDAC"]) hasStale = YES;
            }
            Ck(!hasStale && vc.devices.count == 2 &&
               [vc.topDevicePopup itemWithTitle:@"B"] != nil &&
               [vc.topDevicePopup itemWithTitle:@"C"] != nil,
               "11d: stale /api/devices response is discarded by seq",
               [NSString stringWithFormat:@"hasStale=%d count=%lu items=%@",
                hasStale, (unsigned long)vc.devices.count, vc.topDevicePopup.itemTitles]);
        }

        // -----------------------------------------------------------------
        // 12. 专业台重设计 R1–R3 几何契约（Hero 封面 96/116、首屏、信号链/A-B/机架无溢出与无重叠）
        // -----------------------------------------------------------------
        {
            g_spy.failSettingsPost = NO;
            g_spy.returnNilForSettingsPost = NO;
            g_spy.holdDevicesGet = NO;
            g_spy.returnNilForDevicesGet = NO;
            g_spy.devicesGetList = @[
                @{@"id": @"devLong", @"name": @"Very Long Reference DAC Audio Interface USB Exclusive Output Name", @"default": @YES},
                @{@"id": @"devB", @"name": @"B", @"default": @NO},
            ];
            g_spy.settingsKV = [@{
                @"device": @"devLong",
                @"backend": @"coreaudio",
                @"filter": @"poly-sinc-gauss-long",
                @"shaper": @"LNS15",
            } mutableCopy];
            g_spy.statusGetResponse = @{
                @"ok": @YES,
                @"playing": @YES,
                @"paused": @NO,
                @"current": @"/tmp/mock-geom-track.flac",
                @"title": @"A Very Long Classical Movement Title That Should Cleanly Truncate Inside Hero",
                @"artist": @"Symphony Orchestra",
                @"album": @"Reference Recording",
                @"inRate": @192000,
                @"outBits": @24,
                @"bitPerfect": @"yes",
            };

            RLPWorkbenchViewController *vc = MakeOffscreenWorkbench();
            [vc reloadDevices];
            [vc reloadSettings];
            [vc reloadStatus];
            Pump(0.05);

            // 检查 card 内所有可见直系/深层子控件横向均不超过 card bounds
            BOOL (^CardChildrenFitWidth)(NSView *, NSMutableArray<NSString *> *) =
                ^BOOL(NSView *card, NSMutableArray<NSString *> *badOut) {
                if (!card) return NO;
                __block BOOL ok = YES;
                __block void (^__weak weakWalk)(NSView *);
                void (^walk)(NSView *) = ^(NSView *cur) {
                    for (NSView *sub in cur.subviews) {
                        if (sub.isHidden) continue;
                        NSRect r = [sub convertRect:sub.bounds toView:card];
                        if (r.size.width > 0.5 && r.size.height > 0.5) {
                            if (NSMinX(r) < -1.0 || NSMaxX(r) > card.bounds.size.width + 1.0) {
                                ok = NO;
                                [badOut addObject:[NSString stringWithFormat:@"%@(%@) r=%@ cardW=%.1f",
                                                   sub.identifier ?: NSStringFromClass(sub.class),
                                                   card.identifier ?: @"", NSStringFromRect(r),
                                                   card.bounds.size.width]];
                            }
                        }
                        if (![sub isKindOfClass:NSControl.class]) {
                            weakWalk(sub);
                        }
                    }
                };
                weakWalk = walk;
                walk(card);
                return ok;
            };

            CGFloat (^DistBottomFromStackTop)(NSView *) = ^CGFloat(NSView *v) {
                NSRect r = [v convertRect:v.bounds toView:vc.stack];
                return vc.stack.isFlipped ? NSMaxY(r) : (NSMaxY(vc.stack.bounds) - NSMinY(r));
            };

            NSView *trackCard = FindSubviewByIdentifier(vc.view, @"wb.trackcard");
            NSView *chainCard = vc.chainCard ?: FindSubviewByIdentifier(vc.view, @"wb.chaincard");
            NSView *tabsBar = FindSubviewByIdentifier(vc.view, @"wb.tabs");
            NSView *abCard = FindSubviewByIdentifier(vc.view, @"wb.ab");
            NSView *profilesCard = FindSubviewByIdentifier(vc.view, @"wb.profiles");
            NSView *rackHdr = vc.rackHeaderRow ?: FindSubviewByIdentifier(vc.view, @"wb.rack.header");
            NSView *rackView = vc.rackStack ?: FindSubviewByIdentifier(vc.view, @"wb.rack");
            NSView *rackPCM = vc.rackPCM ?: FindSubviewByIdentifier(vc.view, @"wb.rack.pcm");
            NSView *rackDSD = vc.rackDSD ?: FindSubviewByIdentifier(vc.view, @"wb.rack.dsd");
            NSView *rackOut = vc.rackOutput ?: FindSubviewByIdentifier(vc.view, @"wb.rack.output");
            NSView *quickEq = FindSubviewByIdentifier(vc.view, @"wb.quickeq");

            BOOL r1Ok = NO, r2Ok = NO, r3Ok = YES;
            NSMutableArray<NSString *> *badDetails = [NSMutableArray array];

            for (NSDictionary *cfg in @[
                @{@"lang": @"zh", @"theme": @"light"},
                @{@"lang": @"en", @"theme": @"dark"},
            ]) {
                RLPSetLanguage(cfg[@"lang"]);
                [RLPTheme setThemeName:cfg[@"theme"]];
                [vc applyTheme];
                [vc applyLanguage];

                for (NSValue *szVal in @[
                    [NSValue valueWithSize:NSMakeSize(900, 600)],
                    [NSValue valueWithSize:NSMakeSize(1180, 760)],
                    [NSValue valueWithSize:NSMakeSize(680, 600)],
                ]) {
                    const NSSize sz = szVal.sizeValue;
                    vc.view.frame = NSMakeRect(0, 0, sz.width, sz.height);
                    [vc.view layoutSubtreeIfNeeded];
                    NSView *clipView = vc.scroll.contentView ?: vc.view;
                    const CGFloat clipW = clipView.bounds.size.width;
                    const CGFloat expCover = (sz.width >= 1140.0) ? 116.0 : 96.0;

                    const BOOL coverMatch =
                        std::fabs(vc.trackCover.frame.size.width - expCover) <= 4.0 &&
                        std::fabs(vc.trackCover.frame.size.height - expCover) <= 14.0;
                    const BOOL heroHeightOk = trackCard && trackCard.frame.size.height >= 120.0;

                    NSArray *topCards = @[
                        (id)trackCard ?: [NSNull null], (id)chainCard ?: [NSNull null], (id)tabsBar ?: [NSNull null],
                        (id)abCard ?: [NSNull null], (id)profilesCard ?: [NSNull null], (id)rackHdr ?: [NSNull null],
                        (id)rackView ?: [NSNull null], (id)rackPCM ?: [NSNull null], (id)rackDSD ?: [NSNull null],
                        (id)rackOut ?: [NSNull null], (id)quickEq ?: [NSNull null],
                    ];
                    BOOL allCardsFit = (vc.stack.frame.size.width <= clipW + 1.0);
                    for (id obj in topCards) {
                        if (obj == [NSNull null]) { allCardsFit = NO; continue; }
                        NSView *v = (NSView *)obj;
                        NSRect rClip = [v convertRect:v.bounds toView:clipView];
                        if (v.isHiddenOrHasHiddenAncestor || rClip.size.width <= 0.5 || rClip.size.height <= 0.5 ||
                            NSMinX(rClip) < -0.5 || NSMaxX(rClip) > clipW + 0.5) {
                            allCardsFit = NO;
                            [badDetails addObject:[NSString stringWithFormat:@"%@[%.0fx%.0f %@/%@]: card %@ rClip=%@ clipW=%.1f",
                                                   @"oob", sz.width, sz.height, cfg[@"lang"], cfg[@"theme"],
                                                   v.identifier, NSStringFromRect(rClip), clipW]];
                        }
                    }

                    // 独立区不重叠：hero / chain / tabs / ab / profiles / rackHeader / rack / quickEq
                    NSRect heroR = [trackCard convertRect:trackCard.bounds toView:vc.stack];
                    NSRect chainR = [chainCard convertRect:chainCard.bounds toView:vc.stack];
                    NSRect rackR = [rackView convertRect:rackView.bounds toView:vc.stack];
                    NSRect abR = [abCard convertRect:abCard.bounds toView:vc.stack];
                    const BOOL disjointMajor =
                        !NSIntersectsRect(NSInsetRect(heroR, 0.5, 0.5), NSInsetRect(chainR, 0.5, 0.5)) &&
                        !NSIntersectsRect(NSInsetRect(heroR, 0.5, 0.5), NSInsetRect(rackR, 0.5, 0.5)) &&
                        !NSIntersectsRect(NSInsetRect(chainR, 0.5, 0.5), NSInsetRect(rackR, 0.5, 0.5)) &&
                        !NSIntersectsRect(NSInsetRect(abR, 0.5, 0.5), NSInsetRect(rackR, 0.5, 0.5));

                    // 机架 3 列不互相重叠且内部控件不溢出
                    NSRect pcmR = [rackPCM convertRect:rackPCM.bounds toView:vc.stack];
                    NSRect dsdR = [rackDSD convertRect:rackDSD.bounds toView:vc.stack];
                    NSRect outR = [rackOut convertRect:rackOut.bounds toView:vc.stack];
                    const BOOL rackDisjoint =
                        !NSIntersectsRect(NSInsetRect(pcmR, 0.5, 0.5), NSInsetRect(dsdR, 0.5, 0.5)) &&
                        !NSIntersectsRect(NSInsetRect(pcmR, 0.5, 0.5), NSInsetRect(outR, 0.5, 0.5)) &&
                        !NSIntersectsRect(NSInsetRect(dsdR, 0.5, 0.5), NSInsetRect(outR, 0.5, 0.5));
                    const NSInteger expCols = (sz.width < 940.0) ? 2 : 3;
                    const BOOL colsMatch = (vc.rackColumns == expCols);

                    BOOL abSlotsOk = (vc.abSlotCards.count == 4);
                    NSMutableArray<NSValue *> *abRects = [NSMutableArray array];
                    NSRect abInset = abCard ? NSInsetRect(abCard.bounds, -0.5, -0.5) : NSZeroRect;
                    for (NSView *slot in vc.abSlotCards) {
                        NSRect sInAB = [slot convertRect:slot.bounds toView:abCard];
                        NSRect sInClip = [slot convertRect:slot.bounds toView:clipView];
                        if (slot.isHiddenOrHasHiddenAncestor || !NSContainsRect(abInset, sInAB) ||
                            NSMaxX(sInClip) > clipW + 0.5 || !CardChildrenFitWidth(slot, badDetails)) {
                            abSlotsOk = NO;
                            [badDetails addObject:[NSString stringWithFormat:@"abSlot %@ inAB=%@ inClip=%@",
                                                   slot.identifier, NSStringFromRect(sInAB), NSStringFromRect(sInClip)]];
                        }
                        [abRects addObject:[NSValue valueWithRect:sInAB]];
                    }
                    for (NSUInteger i = 0; i < abRects.count; ++i) {
                        for (NSUInteger j = i + 1; j < abRects.count; ++j) {
                            if (NSIntersectsRect(NSInsetRect([abRects[i] rectValue], 0.5, 0.5),
                                                 NSInsetRect([abRects[j] rectValue], 0.5, 0.5))) {
                                abSlotsOk = NO;
                            }
                        }
                    }

                    const BOOL childrenOk =
                        CardChildrenFitWidth(trackCard, badDetails) &&
                        CardChildrenFitWidth(chainCard, badDetails) &&
                        CardChildrenFitWidth(rackPCM, badDetails) &&
                        CardChildrenFitWidth(rackDSD, badDetails) &&
                        CardChildrenFitWidth(rackOut, badDetails);

                    if (!(coverMatch && heroHeightOk && allCardsFit && disjointMajor && rackDisjoint && colsMatch && abSlotsOk && childrenOk)) {
                        r3Ok = NO;
                        [badDetails addObject:[NSString stringWithFormat:@"[%.0fx%.0f %@/%@ cov=%.1f heroH=%.1f fit=%d maj=%d rack=%d cols=%ld/%ld ab=%d ch=%d]",
                                               sz.width, sz.height, cfg[@"lang"], cfg[@"theme"],
                                               vc.trackCover.frame.size.width, trackCard.frame.size.height,
                                               allCardsFit, disjointMajor, rackDisjoint,
                                               (long)vc.rackColumns, (long)expCols, abSlotsOk, childrenOk]];
                    }

                    if ((NSInteger)sz.width == 900 && [cfg[@"lang"] isEqualToString:@"zh"] && [cfg[@"theme"] isEqualToString:@"light"]) {
                        const BOOL firstScreenOk =
                            !vc.trackTitle.isHiddenOrHasHiddenAncestor && !vc.topDevicePopup.isHiddenOrHasHiddenAncestor &&
                            DistBottomFromStackTop(vc.trackCover) <= sz.height &&
                            DistBottomFromStackTop(vc.trackTitle) <= sz.height &&
                            DistBottomFromStackTop(vc.topDevicePopup) <= sz.height &&
                            NSMaxX([vc.trackTitle convertRect:vc.trackTitle.bounds toView:clipView]) <= clipW + 0.5 &&
                            NSMaxX([vc.topDevicePopup convertRect:vc.topDevicePopup.bounds toView:clipView]) <= clipW + 0.5;
                        r1Ok = (coverMatch && heroHeightOk && firstScreenOk);
                        std::printf("  [R1 900x600] cover=%s hero=%s titleBottom=%.1f devBottom=%.1f clipW=%.1f\n",
                                    NSStringFromSize(vc.trackCover.frame.size).UTF8String,
                                    NSStringFromSize(trackCard.frame.size).UTF8String,
                                    DistBottomFromStackTop(vc.trackTitle),
                                    DistBottomFromStackTop(vc.topDevicePopup), clipW);
                    }
                    if ((NSInteger)sz.width == 1180 && [cfg[@"lang"] isEqualToString:@"zh"] && [cfg[@"theme"] isEqualToString:@"light"]) {
                        r2Ok = (coverMatch && heroHeightOk && disjointMajor && colsMatch);
                        std::printf("  [R2 1180x760] cover=%s hero=%s rackCols=%ld rack=%s clipW=%.1f\n",
                                    NSStringFromSize(vc.trackCover.frame.size).UTF8String,
                                    NSStringFromSize(trackCard.frame.size).UTF8String,
                                    (long)vc.rackColumns, NSStringFromSize(rackView.frame.size).UTF8String, clipW);
                    }
                }
            }

            // 展开所有高级折叠区并切 EQ / Monitor 页签也必须 <= clipW
            [RLPTheme setThemeName:@"light"];
            RLPSetLanguage(@"zh");
            [vc applyTheme];
            [vc applyLanguage];
            vc.view.frame = NSMakeRect(0, 0, 900, 600);
            for (NSString *togId in @[@"wb.pcm.adv.toggle", @"wb.dsd.adv.toggle", @"wb.output.adv.toggle", @"wb.profile.toggle"]) {
                NSButton *btn = (NSButton *)FindSubviewByIdentifier(vc.view, togId);
                if (btn) [btn performClick:nil];
            }
            [vc.view layoutSubtreeIfNeeded];
            NSView *clipView = vc.scroll.contentView ?: vc.view;
            const CGFloat clipW900 = clipView.bounds.size.width;
            const BOOL advOk = CardChildrenFitWidth(rackPCM, badDetails) &&
                               CardChildrenFitWidth(rackDSD, badDetails) &&
                               CardChildrenFitWidth(rackOut, badDetails) &&
                               (vc.stack.frame.size.width <= clipW900 + 1.0);
            [vc selectStudioTab:@"eq"];
            [vc.view layoutSubtreeIfNeeded];
            NSView *eqCard = FindSubviewByIdentifier(vc.view, @"wb.eq");
            const BOOL eqOk = eqCard && NSMaxX([eqCard convertRect:eqCard.bounds toView:clipView]) <= clipW900 + 0.5;
            [vc selectStudioTab:@"monitor"];
            [vc.view layoutSubtreeIfNeeded];
            NSView *monCard = FindSubviewByIdentifier(vc.view, @"wb.monitor");
            const BOOL monOk = monCard && NSMaxX([monCard convertRect:monCard.bounds toView:clipView]) <= clipW900 + 0.5;
            [vc selectStudioTab:@"ab"];

            Ck(r1Ok, "12a (R1): 900x600 hero height >=120, cover 96+-4, title & device visible in first screen without clipping", @"");
            Ck(r2Ok, "12b (R2): 1180x760 cover 116+-4, 3-col rack & hero never overlap", @"");
            Ck(r3Ok && advOk && eqOk && monOk,
               "12c (R3): 900x600/1180x760/680x600 + zh/en + light/dark + adv/eq/monitor all stay maxX<=clip with disjoint A/B slots",
               [badDetails componentsJoinedByString:@" | "]);
        }

        // -----------------------------------------------------------------
        // 13. A/B/C/D 槽选中红框、无意义 A=B 来回按钮移除、切换不丢配置且失败不假高亮
        // -----------------------------------------------------------------
        {
            id savedABSlotsPref = [ud objectForKey:@"RLPWorkbenchABSlots"];
            [ud removeObjectForKey:@"RLPWorkbenchABSlots"];

            g_spy.failSettingsPost = NO;
            g_spy.returnNilForSettingsPost = NO;
            g_spy.settingsKV = [@{
                @"device": @"devA",
                @"backend": @"coreaudio",
                @"shaper": @"auto",
                @"bits": @"-1",
                @"filter": @"sinc-M",
                @"rate": @"176400",
            } mutableCopy];
            [g_spy.postLog removeAllObjects];

            RLPWorkbenchViewController *vc = MakeOffscreenWorkbench();
            [vc reloadSettings];
            Pump(0.05);

            NSView *toggleBtn = FindSubviewByIdentifier(vc.view, @"wb.ab.toggle");
            Ck(toggleBtn == nil && vc.abSlotCards.count == 4 && vc.abButtons.count == 4,
               "13a: meaningless wb.ab.toggle button is removed while A/B/C/D cards and pick buttons remain",
               [NSString stringWithFormat:@"toggle=%@ cards=%lu btns=%lu",
                toggleBtn, (unsigned long)vc.abSlotCards.count, (unsigned long)vc.abButtons.count]);

            // A/B 含子集键（模拟旧存档或少键场景）+ C/D 含完整快照；切换不得丢已存配置
            vc.abSlots[0] = RLPABSnapshotFromSettings(@{@"filter": @"poly-sinc-gauss-long", @"rate": @"follow"});
            vc.abSlots[1] = RLPABSnapshotFromSettings(@{@"filter": @"sinc-M", @"rate": @"176400"});
            vc.abSlots[2] = RLPABSnapshotFromSettings(@{@"filter": @"ext2", @"rate": @"96000", @"shaper": @"LNS15"});
            vc.abSlots[3] = RLPABSnapshotFromSettings(@{@"filter": @"poly-sinc-short-lp", @"rate": @"88200", @"shaper": @"NS5"});
            [vc refreshAB];

            BOOL (^VerifyOnlySlotActive)(NSInteger, NSString *) = ^BOOL(NSInteger expectedSlot, NSString *tag) {
                if (vc.abActive != expectedSlot) {
                    std::printf("  [%s] abActive=%ld expected=%ld\n", tag.UTF8String, (long)vc.abActive, (long)expectedSlot);
                    return NO;
                }
                NSArray<NSString *> *slotNames = @[@"A", @"B", @"C", @"D"];
                BOOL allOk = YES;
                for (NSInteger i = 0; i < 4; ++i) {
                    NSView *card = vc.abSlotCards[(NSUInteger)i];
                    const CGFloat bw = card.layer.borderWidth;
                    CGColorRef bc = card.layer.borderColor;
                    const BOOL isRed = IsRedBorderColor(bc);
                    std::printf("  [%s slot %s] active=%d borderWidth=%.2f borderColor=%s isRed=%d\n",
                                tag.UTF8String, slotNames[(NSUInteger)i].UTF8String,
                                (i == expectedSlot) ? 1 : 0, bw,
                                DescribeBorderColor(bc).UTF8String, isRed ? 1 : 0);
                    if (i == expectedSlot) {
                        if (!(bw >= 1.5 && isRed)) allOk = NO;
                    } else {
                        if (!(bw < 1.5 && !isRed)) allOk = NO;
                    }
                    BOOL labelVisible = NO;
                    for (NSView *sub in card.subviews) {
                        if ([sub isKindOfClass:NSTextField.class] &&
                            [((NSTextField *)sub).stringValue isEqualToString:slotNames[(NSUInteger)i]] &&
                            !sub.isHidden && sub.alphaValue > 0.5) {
                            labelVisible = YES;
                        }
                    }
                    if (!labelVisible || vc.abSummaries[(NSUInteger)i].isHidden || !vc.abSummaries[(NSUInteger)i].stringValue.length) {
                        allOk = NO;
                    }
                }
                return allOk;
            };

            // 13b: 点击 A 切换 -> A 显示红框 (>=1.5, red)，B/C/D 无红框
            [vc.abButtons[0] performClick:nil];
            Pump(0.05);
            Ck(VerifyOnlySlotActive(0, @"13b-pick-A") &&
               [vc.settings[@"filter"] isEqualToString:@"poly-sinc-gauss-long"] &&
               [vc.abSlots[0][@"filter"] isEqualToString:@"poly-sinc-gauss-long"] &&
               [vc.abSlots[1][@"filter"] isEqualToString:@"sinc-M"] &&
               [vc.abSlots[2][@"filter"] isEqualToString:@"ext2"] &&
               [vc.abSlots[3][@"filter"] isEqualToString:@"poly-sinc-short-lp"],
               "13b: picking slot A shows red border (>=1.5) only on A, clears B/C/D, and preserves all saved slots",
               [NSString stringWithFormat:@"abActive=%ld filter=%@", (long)vc.abActive, vc.settings[@"filter"]]);

            // 13c: 依次点击 B / C / D 切换 -> 同一时刻仅当前槽有红框，其余恢复普通边框
            [vc.abButtons[1] performClick:nil];
            Pump(0.05);
            const BOOL bOk = VerifyOnlySlotActive(1, @"13c-pick-B");
            [vc.abButtons[2] performClick:nil];
            Pump(0.05);
            const BOOL cOk = VerifyOnlySlotActive(2, @"13c-pick-C");
            [vc.abButtons[3] performClick:nil];
            Pump(0.05);
            const BOOL dOk = VerifyOnlySlotActive(3, @"13c-pick-D");
            Ck(bOk && cOk && dOk &&
               [vc.abSlots[0][@"filter"] isEqualToString:@"poly-sinc-gauss-long"] &&
               [vc.abSlots[1][@"filter"] isEqualToString:@"sinc-M"] &&
               [vc.abSlots[2][@"filter"] isEqualToString:@"ext2"] &&
               [vc.abSlots[3][@"filter"] isEqualToString:@"poly-sinc-short-lp"],
               "13c: picking B/C/D keeps exactly one red border on active slot and preserves all slot configs", @"");

            // 13d: 切回 A 后，POST 失败切换 B 不得假装高亮 B
            [vc.abButtons[0] performClick:nil];
            Pump(0.05);
            g_spy.failSettingsPost = YES;
            [vc.abButtons[1] performClick:nil];
            Pump(0.05);
            g_spy.failSettingsPost = NO;
            Ck(VerifyOnlySlotActive(0, @"13d-fail-B-keep-A"),
               "13d: failed POST when switching to B keeps A active with red border", @"");

            // 13e: 暗色 apple / 浅色 classic 主题下当前槽 A 仍保持红框
            [RLPTheme setThemeName:@"dark"];
            [RLPTheme setUiStyle:@"apple"];
            [vc applyTheme];
            const BOOL darkOk = VerifyOnlySlotActive(0, @"13e-dark-apple");
            [RLPTheme setThemeName:@"light"];
            [RLPTheme setUiStyle:@"classic"];
            [vc applyTheme];
            const BOOL classicOk = VerifyOnlySlotActive(0, @"13e-light-classic");
            [RLPTheme setThemeName:@"light"];
            [RLPTheme setUiStyle:@"apple"];
            [vc applyTheme];
            Ck(darkOk && classicOk,
               "13e: active slot A preserves red border across dark/apple and light/classic themes", @"");

            // 13f: 手动改动听感参数后清除选中红框
            [vc postSettings:@{@"filter": @"manual-custom-filter"}];
            Pump(0.05);
            Ck(VerifyOnlySlotActive(-1, @"13f-manual-clear"),
               "13f: manual filter change clears active slot highlight across all 4 cards", @"");

            if (savedABSlotsPref) [ud setObject:savedABSlotsPref forKey:@"RLPWorkbenchABSlots"];
            else [ud removeObjectForKey:@"RLPWorkbenchABSlots"];
        }

        method_setImplementation(shared, origShared);
        RLPSetLanguage(savedLang);
        if (savedMonPref) [ud setObject:savedMonPref forKey:@"RLPWorkbenchMonitorEnabled"];
        else [ud removeObjectForKey:@"RLPWorkbenchMonitorEnabled"];

        std::printf("RESULT: %d passed, %d failed\n", g_pass, g_fail);
        return g_fail ? 1 : 0;
    }
}
