// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_settings_window_growth.mm — 设置页 pane 撑宽主窗：离屏复现 + 归因（只诊断，不改生产）
//
// ============================ 这条判据在证明什么 ============================
// test_native_modes_contract 实测：940pt 固定宽 fixture 下遍历设置页后，主窗被撑到
// 1304pt（G1/G4 红）。buildPane 的 stack.width == clip.width 是 required
// (RLPSettingsViewController.mm:893)，但窗口仍变宽。本测试定位根因：
//
//   【根因】主窗是 NSWindowStyleMaskResizable 且**未钉 contentMinSize/AspectRatio**，
//   AppKit 在 pane 挂载、声明约束变化时会把窗口**重新 fit 到内容 fittingSize**。
//   设置页多数 pane 的内容 fitting 宽 > 940，于是窗口被一次性撑宽：
//     · 主窗自身基线（不进设置）= 980（顶栏/播放条 fitting，非设置页问题）；
//     · adv/in/out/pcm/sdm/cal/stream/diag → 980（内容 fitting ≤ 980，停在主窗基线）；
//     · eq → 994（PEQ 卡 head 说明 fitting≈700 + 边距）；
//     · meta → 1304（**隐藏的 sp_metaadv 高级选项容器** fitting=1253，是最大贡献源）。
//
//   【关键反直觉点】撑宽不是「持续的 required 最小宽」：二分探测当前视图树的最小宽
//   只有 412pt（ProbeMinWindowWidth），隐藏单个控件也不触发重 fit。它是**挂载那一刻**
//   AppKit 按 fittingSize 重排可缩放窗口的一次性行为。因此「stack.width==clip.width
//   required」没错——错在窗口可被内容 fitting 撑大，且 meta 把**隐藏的高级容器**也
//   计入了 fitting 宽（NSStackView 对 hidden arrangedSubview 仍参与 fitting 计算）。
//
//   【归因证据】fresh-window 预移除实验（hook showTab，在重 fit 前摘掉 sp_metaadv）：
//     保留 sp_metaadv → 1304；构建后即摘 → 980。差 324pt 全部来自 sp_metaadv。
//     其中 twoCol.width==adv.width(2882) / adv.width==stack.width(2888) 两条 required
//     等宽链把隐藏容器的 fitting 宽刚性传导到外层 stack。
//
// ⚠️ 未解决项（铁律 4）：本文件是**红基线复现**。生产未修复前 W 组断言预期 FAIL；
// 退出码：RLP_GROWTH_EXPECT_RED=1 时把「复现到撑宽」当作成功（诊断模式），否则按回归
// 契约（窗口必须保持 940）判定 —— 修复落地后应全绿。
//
// 纪律（铁律 1/2/3）：Accessory 离屏、窗口不 orderFront；spy 客户端 backend=null、
// volume=-120；不启动核心、不碰 8899、不出声、不动真实键鼠；probeFeedbackChannel
// 置空；归因实验只改诊断进程内的视图树/约束，不动生产源码。
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "RLPCoreClient.h"
#import "RLPMainWindowController.h"
#import "RLPSidebarViewController.h"
#import "RLPSettingsViewController.h"
#import "RLPSettingsLayout.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>

static int g_pass = 0, g_fail = 0;
static void Ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++g_fail; }
}

#pragma mark - Spy 客户端（照抄 modes 契约 fixture，扩展 channels/backend 变体）

@interface RLPWindowGrowthSpy : NSObject
@property (nonatomic, copy) NSString *channels;
@property (nonatomic, copy) NSString *backend;
@property (nonatomic, strong) NSMutableArray<NSString *> *requests;
@end

@implementation RLPWindowGrowthSpy
- (instancetype)init {
    self = [super init];
    if (self) { _channels = @"0"; _backend = @"null"; _requests = [NSMutableArray array]; }
    return self;
}
- (BOOL)started { return YES; }
- (BOOL)startEmbedded { return NO; }
- (void)shutdown { }
- (id)jsonWithMethod:(NSString *)method path:(NSString *)path body:(NSString *)body {
    [self.requests addObject:[NSString stringWithFormat:@"%@ %@", method ?: @"GET", path ?: @""]];
    if ([path hasPrefix:@"/api/settings"] && ![method isEqualToString:@"POST"]) return [self fixtureForPath:path];
    return @{ @"ok": @YES };
}
- (NSData *)dataWithMethod:(NSString *)method path:(NSString *)path body:(NSString *)body
               contentType:(NSString **)contentType {
    (void)method; (void)path; (void)body; (void)contentType;
    return nil;
}
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    [self.requests addObject:[NSString stringWithFormat:@"GET %@", path ?: @""]];
    if (!done) return;
    NSDictionary *json = [self fixtureForPath:path ?: @""];
    dispatch_async(dispatch_get_main_queue(), ^{ done(json); });
}
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    [self.requests addObject:[NSString stringWithFormat:@"POST %@", path ?: @""]];
    if (!done) return;
    dispatch_async(dispatch_get_main_queue(), ^{ done(@{ @"ok": @YES }); });
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done {
    (void)path;
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(nil); });
}
- (void)postData:(NSString *)path body:(NSData *)body contentType:(NSString *)contentType
       completion:(RLPJSONCompletion)done {
    (void)path; (void)body; (void)contentType;
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(@{ @"ok": @YES }); });
}
- (NSDictionary *)fixtureForPath:(NSString *)path {
    if ([path hasPrefix:@"/api/settings"]) {
        return @{ @"ok": @YES,
                  @"kv": @{ @"uimode": @"listen", @"backend": self.backend ?: @"null",
                            @"volume": @"-120", @"theme": @"light",
                            @"channels": self.channels ?: @"0" } };
    }
    if ([path hasPrefix:@"/api/status"]) return @{ @"ok": @YES, @"playing": @NO, @"paused": @NO, @"volDb": @(-120) };
    if ([path hasPrefix:@"/api/queue"]) return @{ @"ok": @YES, @"items": @[], @"index": @0, @"mode": @0 };
    if ([path hasPrefix:@"/api/lib/albums"]) return @{ @"ok": @YES, @"albums": @[] };
    if ([path hasPrefix:@"/api/lib/artists"]) return @{ @"ok": @YES, @"artists": @[] };
    if ([path hasPrefix:@"/api/lib/search"]) return @{ @"ok": @YES, @"tracks": @[], @"total": @0, @"n": @0 };
    if ([path hasPrefix:@"/api/lib/stats"]) return @{ @"ok": @YES, @"roots": @[] };
    if ([path hasPrefix:@"/api/sq/list"]) return @{ @"ok": @YES, @"queues": @[] };
    if ([path hasPrefix:@"/api/devices"]) return @{ @"ok": @YES, @"devices": @[] };
    if ([path hasPrefix:@"/api/filters"]) return @{ @"ok": @YES, @"items": @[] };
    if ([path hasPrefix:@"/api/preset/caps"]) return @{ @"ok": @YES, @"known": @YES, @"pcmReady": @YES, @"dsdReady": @YES };
    if ([path hasPrefix:@"/api/cast/state"]) return @{ @"ok": @YES, @"running": @NO, @"device": @"" };
    return @{ @"ok": @YES };
}
@end

static RLPWindowGrowthSpy *g_spy;
static id FakeSharedClient(id cls, SEL sel) { (void)cls; (void)sel; return g_spy; }
static void NoopProbe(id self, SEL sel) { (void)self; (void)sel; }

static void Pump(double seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}

#pragma mark - 几何采集

static NSView *FindById(NSView *root, NSString *ident) {
    if (!root) return nil;
    if ([root.identifier isEqualToString:ident]) return root;
    for (NSView *s in root.subviews) {
        NSView *r = FindById(s, ident);
        if (r) return r;
    }
    return nil;
}

struct GrowthGeo { CGFloat win, host, paneHost, page, scroll, clip, doc; };

static GrowthGeo Capture(RLPMainWindowController *wc, RLPSettingsViewController *settings, BOOL doLayout) {
    if (doLayout) [wc.window.contentView layoutSubtreeIfNeeded];
    GrowthGeo g{};
    g.win = wc.window.frame.size.width;
    NSView *host = [wc valueForKey:@"pageHost"];
    g.host = host.bounds.size.width;
    g.page = wc.currentContent.view.bounds.size.width;
    NSView *ph = settings ? (NSView *)[settings valueForKey:@"paneHost"] : nil;
    g.paneHost = ph.bounds.size.width;
    NSScrollView *sv = nil;
    if (ph.subviews.count && [ph.subviews.firstObject isKindOfClass:NSScrollView.class])
        sv = (NSScrollView *)ph.subviews.firstObject;
    if (sv) {
        g.scroll = sv.bounds.size.width;
        g.clip = sv.contentView.bounds.size.width;
        g.doc = sv.documentView.bounds.size.width;
    }
    return g;
}

static NSString *GeoLine(const GrowthGeo &g) {
    return [NSString stringWithFormat:
        @"win=%.1f pageHost=%.1f paneHost=%.1f page=%.1f scroll=%.1f clip=%.1f doc=%.1f",
        g.win, g.host, g.paneHost, g.page, g.scroll, g.clip, g.doc];
}

#pragma mark - 归因工具

static NSString *ViewDesc(NSView *v) {
    if (!v) return @"(nil)";
    NSString *ident = v.identifier.length ? v.identifier : @"-";
    NSString *extra = @"";
    if ([v isKindOfClass:NSTextField.class]) {
        NSString *s = ((NSTextField *)v).stringValue ?: @"";
        if (s.length > 24) s = [[s substringToIndex:24] stringByAppendingString:@"…"];
        extra = [NSString stringWithFormat:@" \"%@\"", s];
    } else if ([v isKindOfClass:NSButton.class]) {
        NSString *s = ((NSButton *)v).title ?: @"";
        if (s.length > 24) s = [[s substringToIndex:24] stringByAppendingString:@"…"];
        extra = [NSString stringWithFormat:@" \"%@\"", s];
    }
    return [NSString stringWithFormat:@"%@#%@%@", NSStringFromClass(v.class), ident, extra];
}

/// 递归量 fittingSize.width：AppKit 挂载 pane 时按内容 fitting 宽重 fit 窗口，
/// 「哪个容器的 fitting 宽最大」就是撑宽的直接来源。
static void DumpFittingTree(NSView *v, int depth, CGFloat threshold) {
    if (!v || depth > 12) return;
    const NSSize fs = v.fittingSize;
    const BOOL isContainer = [v isKindOfClass:NSStackView.class] ||
                             [NSStringFromClass(v.class) isEqualToString:@"RLPSettingsGroup"] ||
                             [NSStringFromClass(v.class) isEqualToString:@"RLPFieldGrid"] ||
                             [v isKindOfClass:NSScrollView.class];
    if (fs.width >= threshold || (isContainer && fs.width > 0)) {
        NSMutableString *pad = [NSMutableString string];
        for (int i = 0; i < depth; ++i) [pad appendString:@"  "];
        std::printf("      %sfitting=%.1f×%.1f bounds=%.1f %s%s\n",
                    pad.UTF8String, fs.width, fs.height, v.bounds.size.width,
                    ViewDesc(v).UTF8String, v.hidden ? " [hidden]" : "");
    }
    for (NSView *s in v.subviews) DumpFittingTree(s, depth + 1, threshold);
}

/// 二分探测「当前视图树把窗口撑到的最小宽」。用于证明撑宽**不是**持续 required 最小宽：
/// 若最小宽远小于实测撑宽值，说明撑宽是挂载时的一次性 fitting 重排，而非约束下限。
static CGFloat ProbeMinWindowWidth(RLPMainWindowController *wc) {
    CGFloat lo = 300, hi = 2200;
    for (int i = 0; i < 14; ++i) {
        const CGFloat mid = (lo + hi) / 2;
        NSRect f = wc.window.frame; f.size.width = mid;
        [wc.window setFrame:f display:NO];
        [wc.window.contentView layoutSubtreeIfNeeded];
        const CGFloat got = wc.window.frame.size.width;
        if (got > mid + 0.5) lo = got; else hi = mid;
        if (hi - lo < 1.0) break;
    }
    NSRect f = wc.window.frame; f.size.width = hi;
    [wc.window setFrame:f display:NO];
    [wc.window.contentView layoutSubtreeIfNeeded];
    return wc.window.frame.size.width;
}

#pragma mark - 主流程

static const CGFloat kFixtureW = 940.0, kFixtureH = 690.0;

static void ResetWindowWidth(RLPMainWindowController *wc) {
    NSRect f = wc.window.frame;
    f.size.width = kFixtureW;
    [wc.window setFrame:f display:NO];
    [wc.window.contentView layoutSubtreeIfNeeded];
    Pump(0.03);
    if (wc.window.frame.size.width > kFixtureW + 0.5) {
        std::printf("    [reset] 940 钉不住：layout 后=%.1f（当前内容 fitting 已超 940）\n",
                    wc.window.frame.size.width);
        f = wc.window.frame; f.size.width = kFixtureW;
        [wc.window setFrame:f display:NO];
    }
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        g_spy = [RLPWindowGrowthSpy new];
        [RLPTheme setThemeName:@"light"];
        [RLPTheme setUiStyle:@"apple"];
        [RLPSettingsViewController setRlp_confirmsBitPerfectFix:NO];

        Method shared = class_getClassMethod(RLPCoreClient.class, @selector(shared));
        method_setImplementation(shared, (IMP)FakeSharedClient);
        Method probe = class_getInstanceMethod(RLPSettingsViewController.class, @selector(probeFeedbackChannel));
        if (probe) method_setImplementation(probe, (IMP)NoopProbe);

        const BOOL expectRed = getenv("RLP_GROWTH_EXPECT_RED") && atoi(getenv("RLP_GROWTH_EXPECT_RED")) == 1;
        std::printf("=== test_native_settings_window_growth（设置页撑宽主窗 · 离屏诊断）===\n");
        std::printf("模式：%s\n", expectRed ? "诊断（复现撑宽=PASS；生产未修，W 断言按红基线记录）"
                                           : "回归契约（窗口必须保持 940）");

        RLPMainWindowController *wc = [[RLPMainWindowController alloc] init];
        [wc.window setFrameAutosaveName:@""];
        NSRect fixtureFrame = wc.window.frame;
        fixtureFrame.size = NSMakeSize(kFixtureW, kFixtureH);
        [wc.window setFrame:fixtureFrame display:NO];
        [wc.window.contentView layoutSubtreeIfNeeded];
        Pump(0.1);
        ResetWindowWidth(wc);
        const GrowthGeo base = Capture(wc, nil, YES);
        std::printf("  [geometry] fixture %s\n", GeoLine(base).UTF8String);
        Ck(std::abs(base.win - kFixtureW) < 1.0, "W0 固定宽 fixture 生效（940）", GeoLine(base));

        [wc.sidebar selectKey:@"settings"];
        Pump(0.15);
        RLPSettingsViewController *settings = (RLPSettingsViewController *)wc.currentContent;
        Ck([settings isKindOfClass:RLPSettingsViewController.class],
           "W0b 进入设置页", NSStringFromClass(wc.currentContent.class));
        const GrowthGeo entered = Capture(wc, settings, YES);
        std::printf("  [geometry] enter-settings(默认 adv) %s\n", GeoLine(entered).UTF8String);
        Ck(std::abs(entered.win - kFixtureW) < 1.0,
           "W1 进入设置页（默认 pane=adv）不得撑宽主窗", GeoLine(entered));

        NSArray<NSString *> *panes = @[ @"adv", @"in", @"out", @"pcm", @"sdm", @"eq", @"cal", @"meta", @"stream", @"diag" ];
        NSMutableArray<NSString *> *grownPanes = [NSMutableArray array];
        NSString *worstPane = nil; CGFloat worstWin = kFixtureW;

        for (NSString *p in panes) {
            ResetWindowWidth(wc);   // 每个 pane 独立基线
            const GrowthGeo before = Capture(wc, settings, YES);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenSettingsPaneNotification" object:p];
            Pump(0.12);
            const GrowthGeo pumped = Capture(wc, settings, NO);
            const GrowthGeo after = Capture(wc, settings, YES);
            const BOOL reached = [[settings currentPaneKey] isEqualToString:p];
            std::printf("  [pane %-6s] before{%s}\n              pumped{%s}\n              after {%s} reached=%d\n",
                        p.UTF8String, GeoLine(before).UTF8String, GeoLine(pumped).UTF8String,
                        GeoLine(after).UTF8String, (int)reached);
            Ck(reached, [[NSString stringWithFormat:@"W2-%@ 深链切到位", p] UTF8String], [settings currentPaneKey]);
            const BOOL grew = after.win > kFixtureW + 1.0 || pumped.win > kFixtureW + 1.0;
            Ck(!grew, [[NSString stringWithFormat:@"W3-%@ 进入该 pane 主窗保持 940", p] UTF8String],
               [NSString stringWithFormat:@"win %.1f → %.1f（pumped %.1f）", before.win, after.win, pumped.win]);
            if (grew) {
                [grownPanes addObject:p];
                const CGFloat peak = MAX(after.win, pumped.win);
                if (peak > worstWin) { worstWin = peak; worstPane = p; }
                NSView *ph = [settings valueForKey:@"paneHost"];
                NSView *pane = ph.subviews.firstObject;
                std::printf("  [attrib] pane=%s 稳定后 win=%.1f\n", p.UTF8String, wc.window.frame.size.width);
                const CGFloat minW = ProbeMinWindowWidth(wc);
                std::printf("    [min-probe] 当前视图树最小宽=%.1f（远小于撑宽值 ⟹ 非持续 required 下限）\n", minW);
                std::printf("    [fitting-tree] pane 子树 fitting 宽（阈值 %.0f）：\n", peak - 300);
                DumpFittingTree(pane, 0, peak - 300);
            }
        }
        std::printf("  [summary] 撑宽 pane：%s；最宽 %.1f（%s）\n",
                    grownPanes.count ? [grownPanes componentsJoinedByString:@", "].UTF8String : "(无)",
                    worstWin, (worstPane ?: @"-").UTF8String);

        // ---- 变体 A：channels=8（trim 8 行）+ out 页 ----
        {
            g_spy.channels = @"8";
            [settings performSelector:NSSelectorFromString(@"reloadData")];
            Pump(0.15);
            ResetWindowWidth(wc);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenSettingsPaneNotification" object:@"out"];
            Pump(0.1);
            const GrowthGeo g = Capture(wc, settings, YES);
            NSView *ph = [settings valueForKey:@"paneHost"];
            NSView *trim = FindById(ph, @"sp_trimwrap");
            NSInteger rows = [trim isKindOfClass:NSStackView.class] ? (NSInteger)((NSStackView *)trim).arrangedSubviews.count : -1;
            std::printf("  [variant channels=8 → out] %s trim 行数=%ld\n", GeoLine(g).UTF8String, (long)rows);
            Ck(std::abs(g.win - kFixtureW) < 1.0, "W4 channels=8 的输出页不得撑宽主窗", GeoLine(g));
            g_spy.channels = @"0";
        }

        // ---- 变体 B：meta「高级选项」展开 ----
        {
            ResetWindowWidth(wc);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenSettingsPaneNotification" object:@"meta"];
            Pump(0.1);
            NSView *ph = [settings valueForKey:@"paneHost"];
            NSButton *more = (NSButton *)FindById(ph, @"sp_metamore");
            Ck([more isKindOfClass:NSButton.class], "W5a meta 高级选项按钮存在", more ? @"ok" : @"nil");
            if (more) {
                ResetWindowWidth(wc);
                [more performClick:nil];
                Pump(0.12);
                const GrowthGeo expanded = Capture(wc, settings, YES);
                std::printf("  [variant meta-advanced expanded] %s\n", GeoLine(expanded).UTF8String);
                Ck(std::abs(expanded.win - kFixtureW) < 1.0,
                   "W5b meta 高级选项展开不得撑宽主窗", GeoLine(expanded));
                [more performClick:nil];
                Pump(0.05);
            }
        }

        // ---- 变体 C：UPnP 后端（upnpwrap 显形） ----
        {
            g_spy.backend = @"upnp";
            [settings performSelector:NSSelectorFromString(@"reloadData")];
            Pump(0.15);
            ResetWindowWidth(wc);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenSettingsPaneNotification" object:@"out"];
            Pump(0.1);
            const GrowthGeo g = Capture(wc, settings, YES);
            NSView *ph = [settings valueForKey:@"paneHost"];
            NSView *wrap = FindById(ph, @"sp_upnpwrap");
            std::printf("  [variant backend=upnp → out] %s upnpwrap.hidden=%d\n",
                        GeoLine(g).UTF8String, wrap ? (int)wrap.hidden : -1);
            Ck(std::abs(g.win - kFixtureW) < 1.0, "W6 UPnP 后端的输出页不得撑宽主窗", GeoLine(g));
            g_spy.backend = @"null";
        }

        // ---- 隔离实验：fresh window 逐 pane + meta 预移除归因 ----
        {
            auto freshSetup = [&](void) -> RLPMainWindowController * {
                RLPMainWindowController *w = [[RLPMainWindowController alloc] init];
                [w.window setFrameAutosaveName:@""];
                NSRect f = w.window.frame; f.size = NSMakeSize(kFixtureW, kFixtureH);
                [w.window setFrame:f display:NO];
                [w.window.contentView layoutSubtreeIfNeeded];
                Pump(0.08);
                return w;
            };
            {   // (a) 主窗自身基线：不进设置
                RLPMainWindowController *w = freshSetup();
                Pump(0.1);
                [w.window.contentView layoutSubtreeIfNeeded];
                std::printf("  [iso-a] 主窗不进设置：win=%.1f（980 基线来自主窗自身）\n", w.window.frame.size.width);
                [w stopAllActivity];
            }
            {   // (b) fresh→meta
                RLPMainWindowController *w = freshSetup();
                [w.sidebar selectKey:@"settings"]; Pump(0.12);
                [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenSettingsPaneNotification" object:@"meta"];
                Pump(0.12);
                [w.window.contentView layoutSubtreeIfNeeded];
                std::printf("  [iso-b] fresh→meta：win=%.1f\n", w.window.frame.size.width);
                [w stopAllActivity];
            }
            {   // (e) fresh→eq
                RLPMainWindowController *w = freshSetup();
                [w.sidebar selectKey:@"settings"]; Pump(0.12);
                [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenSettingsPaneNotification" object:@"eq"];
                Pump(0.12);
                [w.window.contentView layoutSubtreeIfNeeded];
                std::printf("  [iso-e] fresh→eq：win=%.1f\n", w.window.frame.size.width);
                [w stopAllActivity];
            }
            // (pre) hook showTab：pane 构建完成、窗口重 fit 之前就摘掉 sp_metaadv
            static BOOL sStripAdv = NO;
            static IMP sOrigShowTab = NULL;
            struct ShowTabHook {
                static void Hooked(RLPSettingsViewController *self, SEL sel, NSInteger tab) {
                    reinterpret_cast<void (*)(id, SEL, NSInteger)>(sOrigShowTab)(self, sel, tab);
                    if (!sStripAdv) return;
                    NSView *ph = [self valueForKey:@"paneHost"];
                    NSView *adv = FindById(ph, @"sp_metaadv");
                    if ([adv isKindOfClass:NSStackView.class]) {
                        NSStackView *parent = (NSStackView *)adv.superview;
                        if ([parent isKindOfClass:NSStackView.class]) [parent removeArrangedSubview:adv];
                        [adv removeFromSuperview];
                    }
                }
            };
            Method showTabM = class_getInstanceMethod(RLPSettingsViewController.class, @selector(showTab:));
            sOrigShowTab = method_getImplementation(showTabM);
            method_setImplementation(showTabM, (IMP)ShowTabHook::Hooked);
            auto freshMeta = [&](BOOL strip) -> CGFloat {
                sStripAdv = strip;
                RLPMainWindowController *w = freshSetup();
                [w.sidebar selectKey:@"settings"]; Pump(0.12);
                [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenSettingsPaneNotification" object:@"meta"];
                Pump(0.12);
                [w.window.contentView layoutSubtreeIfNeeded];
                const CGFloat got = w.window.frame.size.width;
                [w stopAllActivity];
                sStripAdv = NO;
                return got;
            };
            const CGFloat withAdv = freshMeta(NO);
            const CGFloat withoutAdv = freshMeta(YES);
            std::printf("  [pre-a] fresh→meta 保留 sp_metaadv：win=%.1f\n", withAdv);
            std::printf("  [pre-b] fresh→meta 构建后即摘 sp_metaadv：win=%.1f（差 %.1f = sp_metaadv 的贡献）\n",
                        withoutAdv, withAdv - withoutAdv);
            method_setImplementation(showTabM, sOrigShowTab);
            Ck(withAdv - withoutAdv > 100.0,
               "W8 归因：sp_metaadv（隐藏高级容器）是 meta 撑宽的主贡献源",
               [NSString stringWithFormat:@"with=%.1f without=%.1f", withAdv, withoutAdv]);
        }

        [wc stopAllActivity];
        std::printf("\n结果：%d passed, %d failed\n", g_pass, g_fail);
        if (expectRed) {
            const BOOL reproduced = grownPanes.count > 0 || g_fail > 0;
            std::printf("诊断模式：%s（红基线已记录，生产未修复）\n", reproduced ? "已复现撑宽" : "未复现——判据本身需要复查！");
            return reproduced ? 0 : 2;
        }
        return g_fail == 0 ? 0 : 1;
    }
}
