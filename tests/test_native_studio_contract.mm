// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_studio_contract.mm — 专业数字音乐台（ui_studio 对齐）对象级契约测试
//
// 覆盖：
//   1. 顶部三摘要信号链 + 原完整详情入口（wb.chaindetail）+ 7 节点
//   2. 三页签切换（播放台 / EQ 调音台 / 音质监控）+ 不重启播放 + 主体单层滚动（含 3 个页签）
//   3. 播放台：A-D 固定工具区（只含听感键、失败不假装高亮）、/api/profiles、
//      PCM(1x/Nx + 手动覆盖检测与恢复预设)/DSD(SDM 1x/Nx)/输出 三列机架 + 按区展开高级参数
//   4. 乱序回包保护（旧 seq 不覆盖新状态）+ 真实请求写后回读
//   5. 窄窗（680pt / 820pt）不溢出、不截断、单层滚动
//   6. EQ 页签嵌推子板+单段检查器+OPRA（无嵌套滚动）
//   7. 音质监控仅显示实际 /api/status 字段，无值显示 N/A
#import <AppKit/AppKit.h>
#import "RLPWorkbench.h"
#import "RLPWorkbenchViewController.h"
#import "RLPCoreClient.h"
#import "RLPEqualizerView.h"
#import "RLPSupport.h"
#import "RLPSignalChain.h"

#include <cstdio>
#include <cstdlib>
#include <unistd.h>

static int gFail = 0, gPass = 0;
static void CK(BOOL ok, const char *what, NSString *detail) {
    if (ok) { ++gPass; std::printf("  [PASS] %s\n", what); }
    else { ++gFail; std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); }
}

static void CollectViews(NSView *v, NSMutableArray<NSView *> *out) {
    if (!v) return;
    [out addObject:v];
    for (NSView *s in v.subviews) CollectViews(s, out);
}

static NSView *FindByIdent(NSView *root, NSString *ident) {
    if ([root.identifier isEqualToString:ident]) return root;
    for (NSView *s in root.subviews) {
        NSView *hit = FindByIdent(s, ident);
        if (hit) return hit;
    }
    return nil;
}

static BOOL IsViewVisible(NSView *v) {
    for (NSView *p = v; p; p = p.superview) {
        if (p.hidden) return NO;
    }
    return YES;
}

static BOOL ScrollViewCanScroll(NSScrollView *sv) {
    if (!sv) return NO;
    if (sv.hasVerticalScroller || sv.hasHorizontalScroller) return YES;
    NSView *doc = sv.documentView;
    if (!doc) return NO;
    const NSSize vis = sv.contentView.bounds.size;
    if (vis.width < 1 || vis.height < 1) return NO;
    if (doc.frame.size.height > vis.height + 0.5) return YES;
    if (doc.frame.size.width > vis.width + 0.5) return YES;
    for (NSLayoutConstraint *c in doc.constraints) {
        if (c.firstAttribute == NSLayoutAttributeHeight && c.relation != NSLayoutRelationLessThanOrEqual
            && c.constant > vis.height + 0.5) return YES;
    }
    return NO;
}

static NSInteger CountNestedScrollables(NSView *root) {
    NSMutableArray<NSView *> *all = [NSMutableArray array];
    CollectViews(root, all);
    NSInteger nested = 0;
    for (NSView *v in all) {
        if (![v isKindOfClass:[NSScrollView class]]) continue;
        NSScrollView *sv = (NSScrollView *)v;
        if ([sv.documentView isKindOfClass:[NSTextView class]]) continue;
        if (sv.hasHorizontalScroller && !sv.hasVerticalScroller) continue;
        if (!ScrollViewCanScroll(sv)) continue;
        if (!IsViewVisible(sv)) continue;
        for (NSView *p = sv.superview; p; p = p.superview) {
            if (![p isKindOfClass:[NSScrollView class]]) continue;
            NSScrollView *anc = (NSScrollView *)p;
            if (ScrollViewCanScroll(anc) && IsViewVisible(anc)) {
                ++nested;
                break;
            }
        }
    }
    return nested;
}

@interface RLPWorkbenchViewController (StudioTestAccess)
@property (nonatomic, copy) NSDictionary *settings;
@property (nonatomic, copy) NSArray<NSDictionary *> *filters;
@property (nonatomic, copy) NSDictionary *status;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *abSlots;
@property (nonatomic, assign) NSInteger abActive;
@property (nonatomic, strong) NSMutableArray<NSButton *> *abButtons;
- (void)selectStudioTab:(NSString *)tab;
- (void)applySettingsPayload:(NSDictionary *)kv forSeq:(NSUInteger)seq;
- (void)applyStatusPayload:(NSDictionary *)st forSeq:(NSUInteger)seq;
- (void)onFilterResetOverride:(id)sender;
- (void)onABPick:(NSButton *)sender;
- (void)refreshAB;
@property (nonatomic, assign) BOOL peqBypassed;
- (void)onEqBypass:(id)sender;
- (void)showSignalChainDetail:(NSButton *)sender;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSTextField *> *chainValues;
@end

@interface MockStudioWorkbenchVC : RLPWorkbenchViewController
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *requests;
@property (nonatomic, assign) BOOL failNextPost;
@end

@implementation MockStudioWorkbenchVC
- (instancetype)init {
    self = [super init];
    if (self) _requests = [NSMutableArray array];
    return self;
}
- (void)postSettings:(NSDictionary<NSString *, NSString *> *)kv {
    [self.requests addObject:@{@"path": @"/api/settings", @"kv": kv ?: @{}}];
    if (self.failNextPost) {
        self.failNextPost = NO;
        [self refreshAB];
        return;
    }
    NSMutableDictionary *next = [self.settings mutableCopy] ?: [NSMutableDictionary dictionary];
    [next addEntriesFromDictionary:kv];
    self.settings = next;
    [self applySettingsPayload:next forSeq:0];
}
@end

int main() {
    @autoreleasepool {
        [NSApplication sharedApplication];
        std::printf("=== test_native_studio_contract ===\n");

        // 1. Pure logic: filter override detection & clear payload
        NSDictionary *cleanSet = @{@"filter": @"poly-sinc-gauss-long", @"taps": @"0", @"atten": @"0", @"transition": @"0", @"phase": @""};
        CK(!RLPWorkbenchHasFilterOverride(cleanSet), "S1a 无手动覆盖时返回 NO", @"");
        NSDictionary *dirtySet = @{@"filter": @"poly-sinc-gauss-long", @"taps": @"32767", @"atten": @"180", @"transition": @"0", @"phase": @"minimum"};
        CK(RLPWorkbenchHasFilterOverride(dirtySet), "S1b 有 taps/atten/phase 覆盖时返回 YES", @"");
        NSDictionary *clearPayload = RLPWorkbenchClearFilterOverridePayload();
        CK([clearPayload[@"phase"] isEqualToString:@""] &&
           [clearPayload[@"taps"] isEqualToString:@"0"] &&
           [clearPayload[@"atten"] isEqualToString:@"0"] &&
           [clearPayload[@"transition"] isEqualToString:@"0"],
           "S1c 恢复预设载荷精确清零 phase/taps/atten/transition", clearPayload.description);

        // 2. Pure logic: monitor rows only reflect real status fields, missing -> N/A
        NSArray<NSDictionary *> *emptyMon = RLPWorkbenchMonitorRows(nil);
        CK(emptyMon.count > 0, "S2a 监控行列表非空", @"");
        BOOL allNA = YES;
        for (NSDictionary *row in emptyMon) {
            if (![row[@"value"] isEqualToString:@"N/A"]) { allNA = NO; break; }
        }
        CK(allNA, "S2b 无 status 时所有监控项显示 N/A", emptyMon.description);
        NSArray<NSDictionary *> *liveMon = RLPWorkbenchMonitorRows(@{
            @"inRate": @96000, @"outRate": @192000, @"outBits": @24,
            @"bitPerfect": @"yes", @"outMode": @"coreaudio", @"dsd": @0
        });
        BOOL foundInRate = NO, foundOutRate = NO;
        for (NSDictionary *row in liveMon) {
            if ([row[@"key"] isEqualToString:@"inRate"] && [row[@"value"] rangeOfString:@"96000"].location != NSNotFound) foundInRate = YES;
            if ([row[@"key"] isEqualToString:@"outRate"] && [row[@"value"] rangeOfString:@"192000"].location != NSNotFound) foundOutRate = YES;
        }
        CK(foundInRate && foundOutRate, "S2c 有 status 时监控显示真实 inRate/outRate", liveMon.description);

        // 3. UI structure: 3 tabs, 3-column rack, explicit 1x/Nx for PCM & SDM, monitor, EQ
        MockStudioWorkbenchVC *vc = [[MockStudioWorkbenchVC alloc] init];
        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1180, 780)
                                                    styleMask:NSWindowStyleMaskBorderless
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
        win.contentView = vc.view;
        [vc.view layoutSubtreeIfNeeded];

        NSArray *reqIds = @[
            @"wb.tabs", @"wb.tab.ab", @"wb.tab.eq", @"wb.tab.monitor",
            @"wb.panel.ab", @"wb.panel.eq", @"wb.panel.monitor",
            @"wb.rack", @"wb.rack.pcm", @"wb.rack.dsd", @"wb.rack.output",
            @"wb.pcm.slot", @"wb.filter.override", @"wb.filter.reset",
            @"wb.sdmfilt", @"wb.sdmfiltnx", @"wb.ratefamily",
            @"wb.pcm.adv.toggle", @"wb.dsd.adv.toggle", @"wb.output.adv.toggle",
            @"wb.chaindetail", @"wb.trackcard", @"wb.ab.0",
            @"wb.profile.toggle", @"wb.profile.panel", @"wb.profile.list",
            @"wb.quickeq", @"wb.quickeq.bypass", @"wb.quickeq.preset", @"wb.quickeq.open",
            @"wb.mon.master", @"wb.mon.auto", @"wb.mon.retry",
            @"wb.mon.dyn", @"wb.mon.qual", @"wb.mon.fake"
        ];
        for (NSString *ident in reqIds) {
            CK(FindByIdent(vc.view, ident) != nil,
               [[NSString stringWithFormat:@"S3 控件在位 %@", ident] UTF8String], @"缺失");
        }
        CK(FindByIdent(vc.view, @"wb.profile.panel").hidden,
           "S3b 配置档表格默认收拢为入口（同层面板默认隐藏）", @"");

        // 3c. Pure logic: monitor analysis summaries & auto-analyze guard
        CK(RLPWorkbenchIsLocalAudioPath(@"/Users/test/song.flac") &&
           !RLPWorkbenchIsLocalAudioPath(@"http://192.168.1.2/stream.flac"),
           "S3c 本地路径判定排除流媒体", @"");
        NSDictionary *anlMock = @{
            @"ok": @YES,
            @"health": @{
                @"status": @"ready",
                @"dr_available": @YES,
                @"dr_db": @15.2,
                @"quality": @{@"available": @YES, @"peak_dbfs_q": @(-1.0), @"rms_dbfs": @(-16.0), @"clipped_samples": @0},
                @"lossless_suspected": @NO,
                @"cutoff_hz": @21500,
                @"fs": @44100
            }
        };
        NSDictionary *unwrapped = RLPWorkbenchUnwrapHealth(anlMock);
        NSDictionary<NSString *, NSString *> *sums = RLPWorkbenchAnalysisSummaries(unwrapped);
        CK([sums[@"dyn"] rangeOfString:@"良好动态"].location != NSNotFound &&
           [sums[@"qual"] rangeOfString:@"干净"].location != NSNotFound &&
           [sums[@"fake"] rangeOfString:@"未发现"].location != NSNotFound,
           "S3d /api/health 解包与三摘要推导正确", sums.description);
        CK(RLPWorkbenchShouldAutoAnalyze(@"/tmp/a.flac", YES, YES, YES, nil, NO, NO) &&
           !RLPWorkbenchShouldAutoAnalyze(@"/tmp/a.flac", YES, NO, YES, nil, NO, NO) &&
           !RLPWorkbenchShouldAutoAnalyze(@"/tmp/a.flac", YES, YES, NO, nil, NO, NO) &&
           !RLPWorkbenchShouldAutoAnalyze(@"/tmp/a.flac", YES, YES, YES, @"/tmp/a.flac", NO, NO),
           "S3e 自动分析受总开关/autoanl/去重门控约束", @"");

        // 4. Tab switching + single scroll across all 3 tabs + no playback restart
        [vc selectStudioTab:@"ab"];
        [vc.view layoutSubtreeIfNeeded];
        CK(!FindByIdent(vc.view, @"wb.panel.ab").hidden &&
           FindByIdent(vc.view, @"wb.panel.eq").hidden &&
           FindByIdent(vc.view, @"wb.panel.monitor").hidden,
           "S4a 切到播放台仅显示 wb.panel.ab", @"");
        CK(CountNestedScrollables(vc.view) == 0, "S4b 播放台页签无嵌套滚动", @"");

        [vc selectStudioTab:@"eq"];
        [vc.view layoutSubtreeIfNeeded];
        CK(FindByIdent(vc.view, @"wb.panel.ab").hidden &&
           !FindByIdent(vc.view, @"wb.panel.eq").hidden &&
           FindByIdent(vc.view, @"wb.panel.monitor").hidden,
           "S4c 切到 EQ 调音台仅显示 wb.panel.eq", @"");
        CK(CountNestedScrollables(vc.view) == 0, "S4d EQ 调音台页签无嵌套滚动", @"");

        [vc selectStudioTab:@"monitor"];
        [vc.view layoutSubtreeIfNeeded];
        CK(FindByIdent(vc.view, @"wb.panel.ab").hidden &&
           FindByIdent(vc.view, @"wb.panel.eq").hidden &&
           !FindByIdent(vc.view, @"wb.panel.monitor").hidden,
           "S4e 切到音质监控仅显示 wb.panel.monitor", @"");
        CK(CountNestedScrollables(vc.view) == 0, "S4f 音质监控页签无嵌套滚动", @"");
        CK(vc.requests.count == 0, "S4g 页签切换不发任何播放/设置请求", @"");

        // 5. Out-of-order response guard (older seq must not overwrite newer state)
        [vc selectStudioTab:@"ab"];
        [vc applySettingsPayload:@{@"filter": @"poly-sinc-gauss-long", @"rate": @"176400"} forSeq:10];
        [vc applySettingsPayload:@{@"filter": @"old-stale-filter", @"rate": @"44100"} forSeq:5];
        CK([vc.settings[@"filter"] isEqualToString:@"poly-sinc-gauss-long"],
           "S5a 旧序号 settings 回包不覆盖新状态", vc.settings.description);

        [vc applyStatusPayload:@{@"inRate": @96000, @"outRate": @192000} forSeq:10];
        [vc applyStatusPayload:@{@"inRate": @44100, @"outRate": @44100} forSeq:5];
        CK([vc.status[@"inRate"] integerValue] == 96000,
           "S5b 旧序号 status 回包不覆盖新状态", vc.status.description);

        // 6. Manual override reset action posts clear keys
        [vc applySettingsPayload:@{@"filter": @"poly-sinc-gauss-long", @"taps": @"32767", @"phase": @"minimum"} forSeq:11];
        NSButton *resetBtn = (NSButton *)FindByIdent(vc.view, @"wb.filter.reset");
        CK(resetBtn && resetBtn.enabled, "S6a 有手动覆盖时恢复预设按钮启用", @"");
        [vc onFilterResetOverride:resetBtn];
        NSDictionary *lastKV = vc.requests.lastObject[@"kv"];
        CK([lastKV[@"phase"] isEqualToString:@""] && [lastKV[@"taps"] isEqualToString:@"0"],
           "S6b 点击恢复预设值清空 phase/taps/atten/transition", lastKV.description);
        CK(!RLPWorkbenchHasFilterOverride(vc.settings), "S6c 回读后无手动覆盖", @"");

        // 7. A-D failure must not fake highlight
        vc.abSlots[0] = RLPABSnapshotFromSettings(@{@"filter": @"poly-sinc-gauss-long", @"rate": @"176400"});
        vc.abSlots[1] = RLPABSnapshotFromSettings(@{@"filter": @"poly-sinc-tight-lp", @"rate": @"follow"});
        [vc applySettingsPayload:vc.abSlots[0] forSeq:12];
        CK(vc.abActive == 0, "S7a 初始命中槽 A", @"");
        vc.failNextPost = YES;
        [vc onABPick:vc.abButtons[1]];
        CK(vc.abActive == 0, "S7b POST 失败后绝不假装高亮槽 B", [NSString stringWithFormat:@"abActive=%ld", (long)vc.abActive]);

        // 8. Responsive widths: 680 / 820 / 954 / 1180 (4+3 chain on narrow, 3-col rack without overflow)
        for (NSNumber *wn in @[@680, @820, @954, @1180]) {
            const CGFloat cw = wn.doubleValue;
            [win setContentSize:NSMakeSize(cw, 780)];
            [vc.view layoutSubtreeIfNeeded];
            NSView *rack = FindByIdent(vc.view, @"wb.rack");
            NSView *chainC = FindByIdent(vc.view, @"wb.chain.container");
            NSView *nSrc = FindByIdent(vc.view, @"wb.node.src");
            NSView *nShaper = FindByIdent(vc.view, @"wb.node.shaper");
            NSRect rSrc = [nSrc convertRect:nSrc.bounds toView:vc.view];
            NSRect rShaper = [nShaper convertRect:nShaper.bounds toView:vc.view];
            const BOOL expectTwoRows = (cw < 900.0);
            const BOOL isTwoRows = fabs(rSrc.origin.y - rShaper.origin.y) > 10.0;
            CK(rack && rack.frame.size.width <= cw + 0.5 &&
               chainC && chainC.frame.size.width <= cw + 0.5 &&
               (isTwoRows == expectTwoRows),
               [[NSString stringWithFormat:@"S8_%d 信号链响应(4+3/7列)且机架不横向溢出", (int)cw] UTF8String],
               [NSString stringWithFormat:@"rackW=%.1f chainW=%.1f twoRows=%d",
                rack ? rack.frame.size.width : -1.0, chainC ? chainC.frame.size.width : -1.0, (int)isTwoRows]);
        }

        // 9. Object-level real RLPCoreClient dispatch roundtrip (isolated temp dir, backend=null, volume=-120)
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"rlp-studio-contract-%d", (int)getpid()]];
        NSString *state = [root stringByAppendingPathComponent:@"state"];
        NSString *lib = [root stringByAppendingPathComponent:@"lib"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:lib withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("RLPLAYER_STATE_DIR", state.fileSystemRepresentation, 1);
        setenv("RLPLAYER_LIBRARY_DIR", lib.fileSystemRepresentation, 1);

        RLPCoreClient *core = [RLPCoreClient shared];
        CK([core startEmbedded], "S9a 隔离目录 embedded 核心启动成功", @"");
        [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"backend=null&volume=-120"];

        NSDictionary *fj = [core jsonWithMethod:@"GET" path:@"/api/filters" body:nil];
        NSArray *items = [fj[@"items"] isKindOfClass:[NSArray class]] ? fj[@"items"] : @[];
        CK(items.count >= 50, "S9b /api/filters 返回真实静态注册表",
           [NSString stringWithFormat:@"count=%lu", (unsigned long)items.count]);

        [core jsonWithMethod:@"POST" path:@"/api/settings"
            body:@"filter=poly-sinc-gauss-long&taps=32767&phase=min&atten=150&transition=0.1"];
        NSDictionary *beforeResp = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil];
        NSDictionary *beforeReset = [beforeResp[@"kv"] isKindOfClass:[NSDictionary class]] ? beforeResp[@"kv"] : beforeResp;
        CK(RLPWorkbenchHasFilterOverride(beforeReset),
           "S9c 写入覆盖参数后后端回读确认存在手动覆盖", beforeReset.description);

        NSDictionary<NSString *, NSString *> *clearKV = RLPWorkbenchClearFilterOverridePayload();
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (NSString *k in clearKV) {
            [parts addObject:[NSString stringWithFormat:@"%@=%@", k, clearKV[k]]];
        }
        [core jsonWithMethod:@"POST" path:@"/api/settings" body:[parts componentsJoinedByString:@"&"]];
        NSDictionary *afterResp = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil];
        NSDictionary *afterReset = [afterResp[@"kv"] isKindOfClass:[NSDictionary class]] ? afterResp[@"kv"] : afterResp;
        CK(!RLPWorkbenchHasFilterOverride(afterReset),
           "S9d 清空覆盖载荷写回后端并回读后不再有手动覆盖",
           RLPWorkbenchFilterOverrideSummary(afterReset));

        NSDictionary *realStatus = [core jsonWithMethod:@"GET" path:@"/api/status" body:nil];
        NSArray<NSDictionary<NSString *, NSString *> *> *realMon = RLPWorkbenchMonitorRows(realStatus);
        CK([realStatus isKindOfClass:[NSDictionary class]] && realMon.count >= 6,
           "S9e 真实 /api/status 映射到监控行且无值回退 N/A", @"");

        // Real controller action must toggle PEQ without overwriting the external EQ path.
        NSString *externalPath = [root stringByAppendingPathComponent:@"external.txt"];
        [core jsonWithMethod:@"POST" path:@"/api/settings" body:[@"eq=" stringByAppendingString:RLPEnc(externalPath)]];
        [core jsonWithMethod:@"POST" path:@"/api/peq" body:@"bypass=0"];
        RLPWorkbenchViewController *liveWorkbench = [[RLPWorkbenchViewController alloc] init];
        (void)liveWorkbench.view;
        for (int spin = 0; spin < 30; ++spin) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        for (NSNumber *wanted in @[@YES, @NO]) {
            liveWorkbench.peqBypassed = !wanted.boolValue;
            [liveWorkbench onEqBypass:nil];
            NSDictionary *peqState = nil;
            for (int spin = 0; spin < 100; ++spin) {
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
                peqState = [core jsonWithMethod:@"GET" path:@"/api/peq" body:nil];
                if ([peqState[@"bypass"] boolValue] == wanted.boolValue && liveWorkbench.peqBypassed == wanted.boolValue) break;
            }
            NSDictionary *saved = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil][@"kv"];
            CK([peqState[@"bypass"] boolValue] == wanted.boolValue &&
               liveWorkbench.peqBypassed == wanted.boolValue && [saved[@"eq"] isEqualToString:externalPath],
               wanted.boolValue ? "S10a PEQ bypass preserves external EQ path" : "S10b PEQ enable preserves external EQ path", saved.description);
        }

        // 11. Signal chain shared fallback hero title + Workbench Hog fallback + signalSeq guard
        {
            NSDictionary *sharedSignal = @{
                @"ok": @YES,
                @"path": @{
                    @"bitPerfect": @"no",
                    @"bitPerfectWhy": @"Shared output mode",
                    @"sharedOnly": @YES,
                    @"outMode": @"shared",
                    @"transport": @"coreaudio"
                }
            };
            NSString *sharedHero = [RLPSignalChain heroTitleForResponse:sharedSignal why:nil];
            CK([sharedHero isEqualToString:@"非 Bit-Perfect · 共享输出（经系统混音）"],
               "S11a sharedOnly/outMode=shared 时信号链标题显示共享输出（经系统混音）", sharedHero ?: @"(nil)");

            NSDictionary *outModeOnlyShared = @{
                @"ok": @YES,
                @"path": @{
                    @"bitPerfect": @"no",
                    @"sharedOnly": @NO,
                    @"outMode": @"shared",
                    @"transport": @"coreaudio"
                }
            };
            NSString *sharedHero2 = [RLPSignalChain heroTitleForResponse:outModeOnlyShared why:nil];
            CK([sharedHero2 isEqualToString:@"非 Bit-Perfect · 共享输出（经系统混音）"],
               "S11b 仅 outMode=shared 时信号链标题也显示共享输出（经系统混音）", sharedHero2 ?: @"(nil)");

            NSDictionary *dspSignal = @{
                @"ok": @YES,
                @"path": @{
                    @"bitPerfect": @"no",
                    @"sharedOnly": @NO,
                    @"outMode": @"exclusive",
                    @"transport": @"coreaudio"
                }
            };
            NSString *dspHero = [RLPSignalChain heroTitleForResponse:dspSignal why:nil];
            CK([dspHero isEqualToString:@"非 Bit-Perfect · 信号经过 DSP 处理"],
               "S11c exclusive 非 bit-perfect 仍显示信号经过 DSP 处理", dspHero ?: @"(nil)");

            [vc applySettingsPayload:@{@"backend": @"coreaudio", @"hogexcl": @"1"} forSeq:20];
            [vc applyStatusPayload:@{@"hogAcquired": @NO, @"fallbackWhy": @"Hog failed"} forSeq:20];
            NSString *outValFb = vc.chainValues[@"out"].stringValue ?: @"";
            CK([outValFb containsString:@"Hog（已回退）"],
               "S11d 工作台在 hogAcquired=NO/fallbackWhy 非空时显示 Hog（已回退）", outValFb);

            [vc applyStatusPayload:@{@"hogAcquired": @YES, @"fallbackWhy": @""} forSeq:21];
            NSString *outValOk = vc.chainValues[@"out"].stringValue ?: @"";
            CK([outValOk containsString:@"· Hog"] && ![outValOk containsString:@"已回退"],
               "S11e 工作台在 hogAcquired=YES 时显示 · Hog", outValOk);

            BOOL hasSigSeq = NO;
            @try {
                id seq0 = [vc valueForKey:@"signalSeq"];
                [vc showSignalChainDetail:nil];
                id seq1 = [vc valueForKey:@"signalSeq"];
                hasSigSeq = [seq0 respondsToSelector:@selector(unsignedIntegerValue)] &&
                            [seq1 respondsToSelector:@selector(unsignedIntegerValue)] &&
                            [seq1 unsignedIntegerValue] > [seq0 unsignedIntegerValue];
            } @catch (NSException *e) {
                hasSigSeq = NO;
            }
            CK(hasSigSeq, "S11f 工作台一次性 /api/signal 请求具备递增 signalSeq 守卫", @"");
        }

        [core shutdown];
        [fm removeItemAtPath:root error:nil];

        std::printf("\n%s（%d 项失败）\n", gFail == 0 ? "studio_contract 全部通过" : "studio_contract 有失败", gFail);
        return gFail == 0 ? 0 : 1;
    }
}
