// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_filter_selection_contract.mm — 专业工作台 1x/Nx 滤波两槽语义与信号链真值契约
//
// 证明两件事：
//   1. 编辑槽（1x filter vs Nx filterNx）区分清楚：选 forNx 项写 filterNx 后，
//      rebuildFilterControls / syncPhaseSeg / onPhaseChanged / openNodePopover 不回弹到 1x；
//      同时保留两槽语义，非空 filterNx 存在时切回 1x 仍可正常编辑与相位快切（同槽落盘）。
//   2. 信号链（refreshChain）只展示按播放采样率生效的滤波（fs >= 88200 用 filterNx，
//      否则用 filter），绝不把 UI 编辑槽冒充为当前实际播放滤波。
#import <AppKit/AppKit.h>
#import "RLPWorkbench.h"
#import "RLPWorkbenchViewController.h"
#import "RLPSupport.h"

#include <cstdio>

static int gFail = 0, gPass = 0;
static void CK(BOOL ok, const char *what, NSString *detail) {
    if (ok) { ++gPass; std::printf("  [PASS] %s\n", what); }
    else { ++gFail; std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); }
}

// 暴露 RLPWorkbenchViewController 的私有属性与方法，供离线契约测试直接驱动 UI 控件
@interface RLPWorkbenchViewController (TestContractAccess)
@property (nonatomic, strong) NSStackView *filterQuick;
@property (nonatomic, strong) NSPopUpButton *filterAll;
@property (nonatomic, strong) NSSegmentedControl *phaseSeg;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSTextField *> *chainValues;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSButton *> *chainHits;
@property (nonatomic, strong) NSTextField *pipelineStageLine;
@property (nonatomic, strong) NSPopover *popover;
@property (nonatomic, copy) NSDictionary *settings;
@property (nonatomic, copy) NSArray<NSDictionary *> *filters;
@property (nonatomic, copy) NSDictionary *status;
- (void)postSettings:(NSDictionary<NSString *, NSString *> *)kv;
- (void)rebuildFilterControls;
- (void)syncPhaseSeg;
- (void)onPhaseChanged:(NSSegmentedControl *)sender;
- (void)onFilterQuick:(NSButton *)sender;
- (void)onFilterAllChanged:(NSPopUpButton *)sender;
- (void)onChainNodeClicked:(NSButton *)sender;
- (void)onNodeFilter:(NSPopUpButton *)s;
- (void)refreshChain;
@end

@interface TestWorkbenchVC : RLPWorkbenchViewController
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *lastPostedKV;
@property (nonatomic, assign) NSInteger postCount;
@end

@implementation TestWorkbenchVC
- (void)postSettings:(NSDictionary<NSString *, NSString *> *)kv {
    self.lastPostedKV = kv;
    self.postCount += 1;
    // 模拟 /api/settings 保存成功并由 reloadSettings 回读到当前 settings
    NSMutableDictionary *next = [self.settings mutableCopy] ?: [NSMutableDictionary dictionary];
    [next addEntriesFromDictionary:kv];
    self.settings = next;
    [self rebuildFilterControls];
    [self refreshChain];
}
@end

static NSArray<NSDictionary *> *ContractFilters(void) {
    return @[
        @{@"name": @"poly-sinc-gauss-long",     @"phase": @"linear",       @"phaseName": @"线性", @"taps": @32767, @"forNx": @NO},
        @{@"name": @"poly-sinc-gauss-long-mp",  @"phase": @"minimum",      @"phaseName": @"最小", @"taps": @32767, @"forNx": @NO},
        @{@"name": @"poly-sinc-tight-lp",       @"phase": @"linear",       @"phaseName": @"线性", @"taps": @4095,  @"forNx": @NO},
        @{@"name": @"poly-sinc-tight-mp",       @"phase": @"minimum",      @"phaseName": @"最小", @"taps": @4095,  @"forNx": @NO},
        @{@"name": @"poly-sinc-gauss-hires-lp", @"phase": @"linear",       @"phaseName": @"线性", @"taps": @65535, @"forNx": @YES},
        @{@"name": @"poly-sinc-gauss-hires-mp", @"phase": @"minimum",      @"phaseName": @"最小", @"taps": @65535, @"forNx": @YES},
        @{@"name": @"poly-sinc-gauss-hires-ip", @"phase": @"intermediate", @"phaseName": @"混合", @"taps": @65535, @"forNx": @YES},
    ];
}

static void CollectPopups(NSView *v, NSMutableArray<NSPopUpButton *> *out) {
    if (!v) return;
    if ([v isKindOfClass:[NSPopUpButton class]]) [out addObject:(NSPopUpButton *)v];
    for (NSView *s in v.subviews) CollectPopups(s, out);
}

// Shortcut buttons may be arranged in responsive rows; locate the real control recursively.
static NSButton *FindFilterButton(NSView *root, NSString *name) {
    if ([root isKindOfClass:NSButton.class] && [root.identifier isEqualToString:name]) return (NSButton *)root;
    for (NSView *child in root.subviews) {
        NSButton *button = FindFilterButton(child, name);
        if (button) return button;
    }
    return nil;
}

static NSString *SelectedFilterAllName(RLPWorkbenchViewController *vc) {
    NSDictionary *ro = vc.filterAll.selectedItem.representedObject;
    return [ro isKindOfClass:[NSDictionary class]] ? (ro[@"name"] ?: @"") : @"";
}

static BOOL SelectFilterAllByName(RLPWorkbenchViewController *vc, NSString *name) {
    for (NSInteger i = 0; i < (NSInteger)vc.filterAll.numberOfItems; ++i) {
        NSDictionary *ro = [[vc.filterAll itemAtIndex:i] representedObject];
        if ([ro isKindOfClass:[NSDictionary class]] && [ro[@"name"] isEqualToString:name]) {
            [vc.filterAll selectItemAtIndex:i];
            [vc onFilterAllChanged:vc.filterAll];
            return YES;
        }
    }
    return NO;
}

static NSPopUpButton *FindNodeFilterPopup(RLPWorkbenchViewController *vc) {
    NSMutableArray<NSPopUpButton *> *pops = [NSMutableArray array];
    CollectPopups(vc.popover.contentViewController.view, pops);
    for (NSPopUpButton *p in pops) {
        NSString *firstVal = [[p itemAtIndex:0] representedObject];
        if ([firstVal isKindOfClass:[NSString class]] && [firstVal hasPrefix:@"poly-sinc-"]) {
            return p;
        }
    }
    return nil;
}

int main() {
    @autoreleasepool {
        [NSApplication sharedApplication];
        std::printf("=== test_native_filter_selection_contract ===\n");

        TestWorkbenchVC *vc = [[TestWorkbenchVC alloc] init];
        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1180, 760)
                                                    styleMask:NSWindowStyleMaskBorderless
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
        win.contentView = vc.view;
        [vc.view layoutSubtreeIfNeeded];
        vc.filters = ContractFilters();
        vc.settings = @{
            @"filter": @"poly-sinc-gauss-long",
            @"filterNx": @"",
            @"rate": @"176400",
            @"dsd": @"0",
        };
        vc.status = @{@"inRate": @44100};
        [vc rebuildFilterControls];
        [vc refreshChain];

        CK([SelectedFilterAllName(vc) isEqualToString:@"poly-sinc-gauss-long"],
           "F1 初始 1x 回显为 poly-sinc-gauss-long", SelectedFilterAllName(vc));

        // ---- 1. 选 forNx 预设写 filterNx 后，控件与弹层不回弹到 1x ----
        BOOL pickedNx = SelectFilterAllByName(vc, @"poly-sinc-gauss-hires-lp");
        CK(pickedNx, "F2a 下拉中存在 poly-sinc-gauss-hires-lp", @"");
        CK([vc.lastPostedKV isEqualToDictionary:@{@"filterNx": @"poly-sinc-gauss-hires-lp"}],
           "F2b 选 forNx 项写入 filterNx 键", vc.lastPostedKV.description);
        CK([SelectedFilterAllName(vc) isEqualToString:@"poly-sinc-gauss-hires-lp"],
           "F2c 保存回读后 filterAll 保持选中 poly-sinc-gauss-hires-lp（不回弹到 1x）",
           SelectedFilterAllName(vc));
        CK(vc.phaseSeg.selectedSegment == 0 && [vc.phaseSeg isEnabledForSegment:2],
           "F2d syncPhaseSeg 按 hires 族启用混合相位档（gauss-long 无混合相位）",
           [NSString stringWithFormat:@"seg=%ld ipEnabled=%d",
            (long)vc.phaseSeg.selectedSegment, (int)[vc.phaseSeg isEnabledForSegment:2]]);

        NSButton *resampleHit = vc.chainHits[@"resample"];
        if (resampleHit) [vc onChainNodeClicked:resampleHit];
        NSPopUpButton *nodeFiltPop = FindNodeFilterPopup(vc);
        NSString *nodeSel = nodeFiltPop.selectedItem.representedObject ?: @"";
        CK([nodeSel isEqualToString:@"poly-sinc-gauss-hires-lp"],
           "F2e 节点弹层 onChainNodeClicked 回显当前编辑槽 poly-sinc-gauss-hires-lp", nodeSel);
        [vc.popover close];

        // ---- 2. 编辑 Nx 槽时相位快切仍在 filterNx 同槽，不动 1x filter ----
        vc.phaseSeg.selectedSegment = 1; // minimum
        [vc onPhaseChanged:vc.phaseSeg];
        CK([vc.lastPostedKV isEqualToDictionary:@{@"filterNx": @"poly-sinc-gauss-hires-mp"}],
           "F3a Nx 槽相位快切写回 filterNx（同槽）", vc.lastPostedKV.description);
        CK([vc.settings[@"filter"] isEqualToString:@"poly-sinc-gauss-long"],
           "F3b Nx 相位快切不覆盖 1x filter 槽", vc.settings[@"filter"] ?: @"");
        CK([SelectedFilterAllName(vc) isEqualToString:@"poly-sinc-gauss-hires-mp"] &&
           vc.phaseSeg.selectedSegment == 1,
           "F3c 保存回读后仍显示 poly-sinc-gauss-hires-mp 且选中最小相位",
           SelectedFilterAllName(vc));

        // ---- 3. 非空 filterNx 存在时，切回 1x 仍可编辑与相位快切 ----
        NSButton *tightBtn = FindFilterButton(vc.filterQuick, @"poly-sinc-tight-lp");
        CK(tightBtn != nil, "F4a 快捷区存在 1x 滤波 poly-sinc-tight-lp", @"");
        if (tightBtn) [vc onFilterQuick:tightBtn];
        CK([vc.lastPostedKV isEqualToDictionary:@{@"filter": @"poly-sinc-tight-lp"}],
           "F4b 非空 filterNx 存在时点 1x 滤波写入 filter 键", vc.lastPostedKV.description);
        CK([SelectedFilterAllName(vc) isEqualToString:@"poly-sinc-tight-lp"],
           "F4c 回读后 filterAll 选中 1x poly-sinc-tight-lp（不被非空 filterNx 抢占）",
           SelectedFilterAllName(vc));
        CK(![vc.phaseSeg isEnabledForSegment:2],
           "F4d 回读后 syncPhaseSeg 反映 1x tight 族（无混合相位）",
           [NSString stringWithFormat:@"ipEnabled=%d", (int)[vc.phaseSeg isEnabledForSegment:2]]);

        vc.phaseSeg.selectedSegment = 1; // minimum
        [vc onPhaseChanged:vc.phaseSeg];
        CK([vc.lastPostedKV isEqualToDictionary:@{@"filter": @"poly-sinc-tight-mp"}],
           "F4e 1x 槽相位快切写回 filter（同槽）", vc.lastPostedKV.description);
        CK([vc.settings[@"filterNx"] isEqualToString:@"poly-sinc-gauss-hires-mp"],
           "F4f 1x 相位快切不覆盖 filterNx 槽", vc.settings[@"filterNx"] ?: @"");

        // ---- 4. 信号链不可把编辑槽冒充实际播放 ----
        // 4a: 正在编辑 Nx 槽，但实际播放 44.1 kHz (1x) -> 信号链必须显示 1x filter
        SelectFilterAllByName(vc, @"poly-sinc-gauss-hires-lp"); // 切到编辑 Nx
        vc.status = @{@"inRate": @44100};
        [vc refreshChain];
        NSString *res1x = vc.chainValues[@"resample"].stringValue ?: @"";
        CK([res1x rangeOfString:@"poly-sinc-tight-mp"].location != NSNotFound &&
           [res1x rangeOfString:@"poly-sinc-gauss-hires-lp"].location == NSNotFound,
           "F5a 编辑 Nx 槽但播放 44.1kHz 时，信号链显示实际生效 1x 滤波（不冒充）", res1x);

        // 4b: 正在编辑 1x 槽，但实际播放 96 kHz (Nx) -> 信号链必须显示 filterNx
        if (tightBtn) [vc onFilterQuick:tightBtn]; // 切到编辑 1x (filter = poly-sinc-tight-lp)
        vc.status = @{@"inRate": @96000};
        [vc refreshChain];
        NSString *resNx = vc.chainValues[@"resample"].stringValue ?: @"";
        CK([resNx rangeOfString:@"poly-sinc-gauss-hires-lp"].location != NSNotFound &&
           [resNx rangeOfString:@"poly-sinc-tight-lp"].location == NSNotFound,
           "F5b 编辑 1x 槽但播放 96kHz 时，信号链显示实际生效 filterNx", resNx);

        // 4c: 播放 96 kHz 但 filterNx 为空 -> 回落显示 filter
        NSMutableDictionary *noNx = [vc.settings mutableCopy];
        noNx[@"filterNx"] = @"";
        vc.settings = noNx;
        [vc refreshChain];
        NSString *resNxFallback = vc.chainValues[@"resample"].stringValue ?: @"";
        CK([resNxFallback rangeOfString:@"poly-sinc-tight-lp"].location != NSNotFound,
           "F5c 播放 96kHz 且 filterNx 为空时，信号链沿用 1x filter", resNxFallback);

        // 4d: 空闲（无 fs）时即便在编辑 Nx 槽，信号链也不能把 Nx 编辑槽冒充正在播放
        NSMutableDictionary *withNx = [vc.settings mutableCopy];
        withNx[@"filterNx"] = @"poly-sinc-gauss-hires-lp";
        vc.settings = withNx;
        SelectFilterAllByName(vc, @"poly-sinc-gauss-hires-lp");
        vc.status = @{};
        [vc refreshChain];
        NSString *resIdle = vc.chainValues[@"resample"].stringValue ?: @"";
        CK([resIdle rangeOfString:@"poly-sinc-tight-lp"].location != NSNotFound &&
           [resIdle rangeOfString:@"poly-sinc-gauss-hires-lp"].location == NSNotFound,
           "F5d 空闲无播放采样率时，信号链不把 Nx 编辑槽冒充实际播放", resIdle);

        // 4e: DSD 路径下的 pipelineStageLine 也使用实际生效滤波，不用编辑槽冒充
        NSMutableDictionary *dsdSet = [vc.settings mutableCopy];
        dsdSet[@"dsd"] = @"256";
        vc.settings = dsdSet;
        vc.status = @{@"inRate": @44100, @"filter": @"DsdRateConverter"};
        [vc refreshChain];
        NSString *dsdLine = vc.pipelineStageLine.stringValue ?: @"";
        CK([dsdLine rangeOfString:@"poly-sinc-tight-lp"].location != NSNotFound &&
           [dsdLine rangeOfString:@"poly-sinc-gauss-hires-lp"].location == NSNotFound,
           "F5e DSD 44.1kHz 下 pipelineStageLine 显示 1x 滤波而非 Nx 编辑槽", dsdLine);

        CK([RLPWorkbenchActivePlaybackFilter(@{@"filter": @"pcm1", @"filterNx": @"pcmn", @"dsd": @"256", @"sdmfilt": @"sdm1", @"sdmfiltnx": @"sdmn"}, @{@"inRate": @96000, @"fs": @44100}, @"default") isEqualToString:@"sdmn"], "F6a SDM Nx 使用独立槽且只读真实 inRate 字段", @"");
        CK([RLPWorkbenchActivePlaybackFilter(@{@"filter": @"pcm1", @"filterNx": @"pcmn", @"dsd": @"256", @"sdmfilt": @"sdm1"}, @{@"inRate": @44100}, @"default") isEqualToString:@"sdm1"], "F6b SDM 1x 优先独立槽", @"");

        std::printf("\n%s（%d 项失败，%d 项通过）\n",
                    gFail == 0 ? "test_native_filter_selection_contract 全部通过"
                               : "test_native_filter_selection_contract 有失败",
                    gFail, gPass);
        return gFail == 0 ? 0 : 1;
    }
}
