// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_analysis_panel.mm — 「正在播放 · 音频分析面板」web #npAnal 对齐判据
//
// ============================ 这条判据在证明什么 ============================
// web 的真相源（src/net/ui_page.h）：
//   #npAnal            padding:8px 11px 9px, gap:6px, radius:14（:874）
//   .anlhead           flex-column, gap:8（:888）
//   .anllab            9.5px / 700 / letter-spacing:1.5（:909）
//   #npAnlStat         10px, flex:1, text-align:right, tabular-nums（:910-912）
//   .npseg             一个外框：1px border, radius 9, overflow hidden（:894-895）
//   .npseg>b           10.5px / 600 / padding:3px 11px / border-left 发丝（:896-899）
//   .anlcard           padding:7px 9px 8px, gap:4px, radius:10, border 1px（:930-931）
//   .anlct             10.5px / 700 / letter-spacing:.8（:933）
//   .anlcs             11.5px / line-height:1.45（:934）
//   .anlbadge          9.5px / radius 5 / padding 1px 5px（:935）
//   .anlgrid           2 列 / gap:1px 10px（:936）
//   .anlml             justify-between / gap:8 / padding:1px 0 / 底发丝（:937-938）
//   .anllb             10px（:939）；.anlv 11px / tabular / text-align:right（:940-941）
//   .anlv.na           灰字 + 允许换行（绝不省略号吃掉原因）（:943）
//   .anlv.warn         琥珀色 600（:944）
//   .anlsec            10px / 700 / letter-spacing:.7 / 顶部 1px 规则（:945-946）
//   .anlwarn           10.5px / 琥珀 rgba(234,179,8,.10) 底 + .24 边 / radius 7（:948-949）
//
// 旧实现（1.1.7.24）与本判据的差距，也就是**这条判据为什么先红**：
//   * 头部把「音频分析」和状态合成一条 9.5pt 文本（x=12），状态左对齐；
//   * 三个动作是三枚**各自带边框**的 NSButton（48/54/46×25），不是一个分段控件；
//   * 摘要卡是自绘 NSButton：标题 11pt 无字距、摘要 11pt 单行截断、固定高 100/74，
//     没有多声道徽标；
//   * 展开档把三张卡 hidden 掉、换成一块纯文本 NSTextView（RLPAnlDetailText）。
//   新实现必须让这些**真实视图树里的几何/子视图**出现，所以判据量的是 frame/字体/字距/
//   layer 边框与背景，而不是"调了哪些方法"。
//
// 红→绿纪律：先对未修改的生产码跑（截屏/日志 evidence/native-analysis-panel-red-*.log），
// 改完再跑必须绿。数据来自后端 fixture（channels=6、真峰过载、DR/LRA 不适用），
// 不编造任何数值。
//
// ============================ 铁律②：绝不出声 ============================
// 不启动核心、不碰音频设备、不打开可见窗口：RLPCoreClient 用桩（按 fixture 回 JSON，
// 记录请求 URL/body）；RLPNowPlayingViewController 只构造视图树 + 离屏 layout。
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "RLPNowPlayingViewController.h"
#import "RLPCoreClient.h"
#import "RLPAnalysisSummary.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

#include <cstdio>
#include <cmath>

static int g_fail = 0, g_pass = 0;

static void Ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++g_fail; }
}
static void Geo(const char *what, double web, double native_, double tol) {
    const double d = native_ - web;
    const BOOL ok = std::fabs(d) <= tol;
    if (ok) { std::printf("  [PASS] %-28s web=%6.2f native=%6.2f diff=%+6.2f (tol %.1f)\n",
                          what, web, native_, d, tol); ++g_pass; }
    else { std::printf("  [FAIL] %-28s web=%6.2f native=%6.2f diff=%+6.2f (tol %.1f)\n",
                       what, web, native_, d, tol); ++g_fail; }
}

#pragma mark - 桩客户端（不发任何真实请求）

static NSMutableArray<NSString *> *g_getURLs = nil;
static NSMutableArray<NSString *> *g_postURLs = nil;
static NSMutableArray<NSString *> *g_postBodies = nil;
static NSDictionary *g_healthEnv = nil;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RLPCoreClient
+ (instancetype)shared { static RLPCoreClient *c; if (!c) c = [self new]; return c; }
- (BOOL)started { return NO; }
- (BOOL)startEmbedded { return YES; }
- (void)shutdown {}
- (NSDictionary *)jsonWithMethod:(NSString *)m path:(NSString *)p body:(NSString *)b {
    if (b.length) return @{ @"ok": @YES };
    if ([p hasPrefix:@"/api/track/health"] || [p hasPrefix:@"/api/health"])
        return g_healthEnv ?: @{ @"ok": @NO };
    return @{ @"ok": @NO };
}
- (NSData *)dataWithMethod:(NSString *)m path:(NSString *)p body:(NSString *)b contentType:(NSString **)ct {
    return nil;
}
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    if (!g_getURLs) g_getURLs = [NSMutableArray array];
    [g_getURLs addObject:path ?: @""];
    if (done) {
        if ([path hasPrefix:@"/api/track/health"] || [path hasPrefix:@"/api/health"]) done(g_healthEnv ?: @{ @"ok": @NO });
        else done(@{ @"ok": @NO });
    }
}
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    if (!g_postURLs) g_postURLs = [NSMutableArray array];
    if (!g_postBodies) g_postBodies = [NSMutableArray array];
    [g_postURLs addObject:path ?: @""];
    [g_postBodies addObject:body ?: @""];
    if (done) done(@{ @"ok": @YES });
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done { if (done) done(nil); }
- (void)postData:(NSString *)p body:(NSData *)b contentType:(NSString *)c completion:(RLPJSONCompletion)done {
    if (done) done(@{ @"ok": @YES });
}
@end
#pragma clang diagnostic pop

#pragma mark - 生产私有入口（用 category 声明，不改生产头文件）

@interface RLPNowPlayingViewController (AnlPanelTest)
- (void)layoutWebPlayback;
- (void)anlPaint;
- (void)anlOpenLevel:(RLPAnlLevel)level;
- (void)onAnlExpand:(id)sender;
- (void)onAnlReanalyze:(id)sender;
- (void)onToggleAuto:(id)sender;
@property(nonatomic,strong) NSView *analysisPanel;
@end

#pragma mark - 视图树工具

static NSView *FindById(NSView *root, NSString *ident) {
    if (!root) return nil;
    if ([root.identifier isEqualToString:ident]) return root;
    for (NSView *s in root.subviews) {
        NSView *r = FindById(s, ident);
        if (r) return r;
    }
    return nil;
}
static void CollectById(NSView *root, NSString *ident, NSMutableArray<NSView *> *out) {
    if (!root) return;
    if ([root.identifier isEqualToString:ident]) [out addObject:root];
    for (NSView *s in root.subviews) CollectById(s, ident, out);
}
/// `#npAnlBody` 的自绘滚动拇指（生产实现里是 RLPNPAnalBody 的方法；旧码没有）。
@interface NSView (RLPAnalThumbTest)
- (NSRect)scrollThumbRect;
@end

static void CollectAll(NSView *root, NSMutableArray<NSView *> *out) {
    if (!root) return;
    [out addObject:root];
    for (NSView *s in root.subviews) CollectAll(s, out);
}
static BOOL ContainsView(NSView *ancestor, NSView *needle) {
    if (!ancestor || !needle) return NO;
    if (ancestor == needle) return YES;
    for (NSView *s in ancestor.subviews)
        if (ContainsView(s, needle)) return YES;
    return NO;
}
static double LayerRadius(NSView *v) { return v.layer ? (double)v.layer.cornerRadius : 0.0; }
static double BorderWidth(NSView *v) { return v.layer ? (double)v.layer.borderWidth : 0.0; }

static double KernOf(NSTextField *tf) {
    NSAttributedString *as = tf.attributedStringValue;
    if (!as || as.length == 0) return 0.0;
    id k = [as attribute:NSKernAttributeName atIndex:0 effectiveRange:NULL];
    return k ? [k doubleValue] : 0.0;
}
static NSFont *FontOfView(id v) {
    if ([v respondsToSelector:@selector(font)]) return (NSFont *)[v font];
    return nil;
}
/// 字重判据：与同字号的系统字重字体**逐 descriptor 比较**（NSFont isEqual 比 descriptor），
/// 这样 600/700 不会被 AppKit 的字体回退糊成同一个值；descriptor 缺字重时才退回 NSFontManager。
static BOOL FontIsWeight(NSFont *f, NSFontWeight weight) {
    if (!f) return NO;
    NSFont *probe = [NSFont systemFontOfSize:f.pointSize weight:weight];
    if (probe && [f isEqual:probe]) return YES;
    id w = [f.fontDescriptor objectForKey:NSFontWeightTrait];
    if ([w respondsToSelector:@selector(doubleValue)]) {
        const double d = [w doubleValue];
        if (weight >= NSFontWeightBold) return d >= 0.35;
        if (weight >= NSFontWeightSemibold) return d >= 0.25;
        return d >= 0.10;
    }
    const NSInteger mw = [[NSFontManager sharedFontManager] weightOfFont:f];
    if (weight >= NSFontWeightBold) return mw >= 7;
    if (weight >= NSFontWeightSemibold) return mw >= 5;
    return mw >= 4;
}
static BOOL SameColor(NSColor *a, NSColor *b) {
    if (!a || !b) return a == b;
    NSColor *ca = [a colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    NSColor *cb = [b colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!ca || !cb) return NO;
    return fabs(ca.redComponent - cb.redComponent) < 0.035 &&
           fabs(ca.greenComponent - cb.greenComponent) < 0.035 &&
           fabs(ca.blueComponent - cb.blueComponent) < 0.035;
}
/// 卡片内文字被 `line-height` 排出的高度：11.5 × 1.45 ≈ 16.675。
static const double kAnlSumLine = 11.5 * 1.45;

#pragma mark - 夹具（真实后端 JSON 形状：{ok, cached, health:{…}}）

static NSDictionary *AnlFixtureHealth(void) {
    return @{
        @"dr_available": @NO, @"dr_db": @(-300),
        @"lufs": @(-14.2), @"lufs_available": @YES,
        @"lra_available": @NO, @"lra": @(-300),
        @"true_peak_dbtp": @1.8, @"true_peak_available": @YES,
        @"peak_dbfs": @(-1.2), @"channels": @6,
        @"status": @"ready", @"fs": @48000, @"bits": @24,
        @"duration_sec": @212.5, @"analyzed_at_ms": @1731000000000,
        @"lossless_suspected": @NO, @"cutoff_hz": @21000, @"confidence": @0.9,
        @"fake24": @NO,
        @"quality": @{
            @"available": @YES, @"peak_dbfs_q": @(-1.2), @"rms_dbfs": @(-18.4),
            @"clipped_samples": @0, @"clipped_runs": @0, @"longest_clip_run": @0,
            @"crest_db": @14.1, @"snr_db": @18.2,
            @"centroid_hz": @2500, @"noise_floor_dbfs": @-72,
            @"hf_ratio_10k_available": @NO,
            @"stereo": @YES, @"channel_corr": @0.0,
            @"side_mid_db": @-2.0, @"mono_loss_db": @0.0,
            @"spectral_windows": @120
        }
    };
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        std::printf("=== test_native_analysis_panel（音频分析面板 · 离屏几何 · 不出声）===\n");
        std::printf("--- web 基准: ui_page.h:874-950（#npAnal/.anllab/.npseg/.anlcard/.anlgrid）---\n");
        [RLPTheme setThemeName:@"light"];

        // 测试环境里面板不能被用户上一次的「隐藏」偏好挡住（否则量到 0 是假红）。
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"RLPNPAnalysisHidden"];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"RLPNPRailHidden"];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"RLPNPRailDetail"];

        g_healthEnv = @{ @"ok": @YES, @"cached": @NO, @"health": AnlFixtureHealth() };

        RLPNowPlayingViewController *vc = [RLPNowPlayingViewController new];
        NSView *v = vc.view;
        v.frame = NSMakeRect(0, 0, 1400, 900);
        [vc setValue:@"/music/fixture.flac" forKey:@"currentPath"];
        // 生产取数入口：点「分析」= onAnlReanalyze（force=1）；桩同步回调 fixture。
        [vc onAnlReanalyze:nil];
        [vc layoutWebPlayback];
        [v layoutSubtreeIfNeeded];

        NSView *panel = FindById(v, @"npAnal");
        Ck(panel != nil && panel.frame.size.width > 100 && panel.frame.size.height > 100,
           "找得到音频分析面板 #npAnal 且已量到尺寸",
           NSStringFromRect(panel.frame));
        if (!panel) { std::printf("结果：FAIL（面板未构建）\n"); return 1; }
        Ck(!panel.hidden, "面板可见（否则几何全是假红）", @"panel.hidden=YES");
        const double panelW = panel.bounds.size.width;

        // ---------------------------------------------------------------
        // ① 头部：独立标题（9.5/700/kern1.5）+ 右对齐状态（距右缘 13±1）
        // ---------------------------------------------------------------
        NSTextField *lab = (NSTextField *)FindById(panel, @"npAnlLab");
        Ck(lab != nil, "头部有独立的「音频分析」标签 #npAnlLab（不再与状态合成一条）", @"npAnlLab 缺失");
        if (lab) {
            Ck([lab.stringValue isEqualToString:@"音频分析"], "标签文案就是「音频分析」",
               [NSString stringWithFormat:@"got=「%@」", lab.stringValue ?: @""]);
            Geo("anslab.font", 9.5, lab.font.pointSize, 0.3);
            Ck(FontIsWeight(lab.font, NSFontWeightBold), "标签字重 700（web .anllab font-weight:700）",
               [NSString stringWithFormat:@"trait=%@", [lab.font.fontDescriptor objectForKey:NSFontWeightTrait] ?: @"nil"]);
            Geo("anslab.kern", 1.5, KernOf(lab), 0.15);
            Geo("anslab.left", 12, NSMinX(lab.frame), 0.5);   // web: padding 11 + 1px border ⟹ 12（原生无边框，直接量 12）
            {
                // 字距 1.5 计入显示宽度：frame 必须容得下 attributed 宽，否则标题会变成「音频…」
                double need = ceil(lab.attributedStringValue.size.width);
                Ck(lab.frame.size.width >= need - 0.5, "标题不被字距撑破（frame ≥ attributed 宽）",
                   [NSString stringWithFormat:@"frame=%.1f need=%.1f", lab.frame.size.width, need]);
            }
        }

        NSTextField *stat = (NSTextField *)FindById(panel, @"npAnlStat");
        Ck(stat != nil, "状态文字 #npAnlStat 存在", @"npAnlStat 缺失");
        if (stat) {
            // web：`ui_page.h` 的 `.anlheadtop{padding-right:26px}`（1.1.4-beta6，为右上角 `.anlhide`
            // 留位）+ `#npAnlStat{padding-right:2px}` + `#npAnal` padding-left/right 11 + **1px 边框**
            // ⟹ 状态 frame 右缘距面板右缘 38。1.1.7.57 之前原生按「无边框」自洽成 37（差 1pt，
            // 判据把这个偏差烘进了期望值）；本包把左/右内边距改 12（= web 的 11+1）后回到 38。
            Geo("stat.rightGap", 38, panelW - NSMaxX(stat.frame), 0.5);   // web: 26 padding-right + 11 padding + 1px border ⟹ 38
            Ck(stat.alignment == NSTextAlignmentRight, "状态文字右对齐（web text-align:right）",
               [NSString stringWithFormat:@"alignment=%ld", (long)stat.alignment]);
            Geo("stat.font", 10, stat.font.pointSize, 0.3);
            {
                double need = ceil([stat.stringValue sizeWithAttributes:@{ NSFontAttributeName: stat.font }].width);
                Ck(stat.frame.size.width >= need - 0.5, "状态文字不被截断（frame 容得下全文）",
                   [NSString stringWithFormat:@"frame=%.1f need=%.1f got=「%@」",
                    stat.frame.size.width, need, stat.stringValue]);
            }
            {
                // web 的 26px 右内边距就是给 `.anlhide` 留的：两枚元素不许在水平方向重叠。
                NSView *anlHide = FindById(panel, @"npAnalHide");
                Ck(anlHide != nil, "面板右上角有 web #npAnalHide 收起键", @"npAnalHide 缺失");
                if (anlHide)
                    // web `.anlhide{right:8px}` 相对 padding box；`#npAnal` 有 1px 边框 ⟹
                    // 从面板外缘量 = 9pt（ego 实测 right=9）。1.1.7.58 起原生从 8 改 9。
                    Geo("anlhide.rightGap", 9, panelW - NSMaxX(anlHide.frame), 0.5);
                if (anlHide)
                    Ck(NSMinX(anlHide.frame) >= NSMaxX(stat.frame) - 1.0,
                       "收起键不压住状态文字（web .anlheadtop padding-right:26 的用途）",
                       [NSString stringWithFormat:@"stat.maxX=%.1f hide.minX=%.1f",
                        NSMaxX(stat.frame), NSMinX(anlHide.frame)]);
            }
            Ck(![stat.stringValue containsString:@"音频分析"],
               "状态不再重复「音频分析」（标题已独立成一条）",
               [NSString stringWithFormat:@"got=「%@」", stat.stringValue ?: @""]);
        }
        Ck(lab && stat && NSMinX(stat.frame) > NSMaxX(lab.frame) + 4,
           "标题与状态分开占位（状态在右端）", @"");

        // 三个动作：仍在同一行、同一分段容器内，且**恰好一个**带边框容器。
        NSButton *autoBtn = (NSButton *)FindById(panel, @"npAnlAuto");
        NSButton *togBtn  = (NSButton *)FindById(panel, @"npAnlToggle");
        NSButton *runBtn  = (NSButton *)FindById(panel, @"npAnlRun");
        Ck(autoBtn && togBtn && runBtn, "npAnlAuto / npAnlToggle / npAnlRun 三个动作都在",
           [NSString stringWithFormat:@"auto=%d toggle=%d run=%d", !!autoBtn, !!togBtn, !!runBtn]);
        NSMutableArray<NSView *> *bordered = [NSMutableArray array];
        CollectAll(panel, bordered);
        NSInteger borderedWithAll = 0;
        NSView *segBox = nil;
        for (NSView *n in bordered) {
            if (n == panel) continue;                       // 面板自己的边框不算分段容器
            if (BorderWidth(n) <= 0) continue;
            if (autoBtn && togBtn && runBtn &&
                ContainsView(n, autoBtn) && ContainsView(n, togBtn) && ContainsView(n, runBtn)) {
                ++borderedWithAll; segBox = n;
            }
        }
        Ck(borderedWithAll == 1,
           "恰好一个带边框容器同时包住三个动作（web .npseg 一个外框）",
           [NSString stringWithFormat:@"found=%ld", (long)borderedWithAll]);
        if (segBox) {
            Geo("npseg.radius", 9, LayerRadius(segBox), 1.0);
            Ck(BorderWidth(segBox) >= 1, "分段容器有外框（borderWidth>0）",
               [NSString stringWithFormat:@"%.1f", BorderWidth(segBox)]);
            Ck(autoBtn.superview == segBox && togBtn.superview == segBox && runBtn.superview == segBox,
               "三段直接位于同一容器内（不是各自带边框的药丸）", @"");
            // 相邻段之间 ≤1（web 是 1px 发丝分隔，没有留白）
            NSArray<NSButton *> *acts = @[autoBtn, togBtn, runBtn];
            for (NSUInteger i = 0; i + 1 < acts.count; ++i)
                Geo("npseg.gap", 1, NSMinX(acts[i + 1].frame) - NSMaxX(acts[i].frame), 0.5);
            for (NSButton *b in acts) {
                Geo("npseg.font", 10.5, b.font.pointSize, 0.3);
                Ck(FontIsWeight(b.font, NSFontWeightSemibold), "分段文字 600（web .npseg>b font-weight:600）",
                   [NSString stringWithFormat:@"%.1fpt", b.font.pointSize]);
            }
        }

        // ---------------------------------------------------------------
        // ② 摘要卡 L0：标题 10.5/700/kern .8、摘要 11.5/1.45、内边距 7/9/8、
        //    高度随文本生长（旧码是自绘 NSButton + 固定高 100/74）。
        // ---------------------------------------------------------------
        NSView *dyn = FindById(panel, @"anl.dyn");
        NSView *qual = FindById(panel, @"anl.qual");
        NSView *fake = FindById(panel, @"anl.fake");
        Ck(dyn && qual && fake, "三张摘要卡（动态/音质/假无损）都在",
           [NSString stringWithFormat:@"dyn=%d qual=%d fake=%d", !!dyn, !!qual, !!fake]);

        NSArray<NSString *> *keys = @[@"anl.dyn", @"anl.qual", @"anl.fake"];
        NSView *cards[3] = { dyn, qual, fake };
        for (NSUInteger i = 0; i < 3; ++i) {
            NSView *card = cards[i];
            if (!card) continue;
            NSString *key = keys[i];
            Ck(!card.hidden && card.frame.size.width > 0 && card.frame.size.height > 0,
               "摘要卡可见且量到尺寸（L0）",
               [NSString stringWithFormat:@"%@ %@ hidden=%d", key, NSStringFromRect(card.frame), card.hidden]);
            Geo("anlcard.radius", 10, LayerRadius(card), 1.0);
            Geo("anlcard.left", 12, NSMinX([card.superview convertRect:card.frame toView:panel]), 0.5);   // web 内容从 12 起（padding 11 + 1px border）
            // web 实测（ego 打开 ?selftest=1，C8）：panelW=301 时 cardW=264，卡右缘距面板右缘 25
            // （= padding-right 13 + 滚动条 11 + 右内边距/边框 1）。1.1.7.57 起原生内边距取 12（= web 的
            // 11 padding + 1px 边框），故同结构下 cardW = panelW - 37（与 web 实测 264 逐点相同，右侧仍是 25）。
            // 这里从 panelW-22 改期望值，差因见 evidence/native-anl-gutter-20261114.md。
            Geo("anlcard.width", panelW - 37, card.frame.size.width, 0.5);
            NSTextField *title = (NSTextField *)FindById(card, [key stringByAppendingString:@".title"]);
            NSTextField *sum = (NSTextField *)FindById(card, [key stringByAppendingString:@".sum"]);
            Ck(title != nil && sum != nil,
               "卡片标题/摘要都是真实子视图（不是自绘按钮的一行字）",
               [NSString stringWithFormat:@"%@ title=%d sum=%d", key, !!title, !!sum]);
            if (!title || !sum) continue;
            Geo("anlct.font", 10.5, title.font.pointSize, 0.3);
            Ck(FontIsWeight(title.font, NSFontWeightBold), "卡片标题 700（web .anlct font-weight:700）",
               [NSString stringWithFormat:@"%.1fpt", title.font.pointSize]);
            Geo("anlct.kern", 0.8, KernOf(title), 0.15);
            Geo("anlct.padTop", 7, NSMinY(title.frame), 1.5);
            Geo("anlct.padLeft", 9, NSMinX(title.frame), 1.5);
            Geo("anlcs.font", 11.5, sum.font.pointSize, 0.3);
            // 摘要行距：web line-height:1.45 ⟹ 每行 16.675pt。段落样式必须真的设了它。
            NSAttributedString *as = sum.attributedStringValue;
            NSParagraphStyle *ps = as.length ? [as attribute:NSParagraphStyleAttributeName
                                                     atIndex:0 effectiveRange:NULL] : nil;
            Ck(ps != nil, "摘要带段落样式（行距来自 web line-height）", @"段落样式缺失");
            if (ps) Geo("anlcs.lineHeight", kAnlSumLine, ps.minimumLineHeight, 0.6);
            // 摘要不被裁掉：卡片底 = 最后一个可见子视图的底 + 8（web .anlcard padding-bottom:8）
            {
                double lastBottom = NSMaxY(sum.frame);
                for (NSView *child in card.subviews) {
                    if (child.hidden || child.frame.size.height <= 0) continue;
                    lastBottom = MAX(lastBottom, NSMaxY(child.frame));
                }
                Geo("anlcard.padBottom", 8, card.frame.size.height - lastBottom, 1.5);
            }
            // 头部块（标题或徽标，取更高的那个）→摘要 gap 4（web .anlcard gap:4）
            {
                NSTextField *badge = (NSTextField *)FindById(card, [key stringByAppendingString:@".badge"]);
                double headBottom = NSMaxY(title.frame);
                if (badge && !badge.hidden) headBottom = MAX(headBottom, NSMaxY(badge.frame));
                Geo("anlcard.gapTitleSum", 4, NSMinY(sum.frame) - headBottom, 1.5);
            }
        }

        // 长摘要必须把卡片撑高，而不是截断。
        {
            NSTextField *sum = dyn ? (NSTextField *)FindById(dyn, @"anl.dyn.sum") : nil;
            if (sum) {
                NSString *orig = sum.stringValue;
                const double heightBefore = dyn.frame.size.height;
                NSString *longText = @"这是一段很长的动态判读摘要，用来验证卡片高度随文本生长而不是固定上限："
                                     @"素材过短的时候动态不适用，响度与真峰仍然给出真实测量值。";
                sum.stringValue = longText;
                [vc layoutWebPlayback];
                [v layoutSubtreeIfNeeded];
                NSMutableParagraphStyle *mps = [[NSMutableParagraphStyle alloc] init];
                mps.minimumLineHeight = kAnlSumLine;
                mps.maximumLineHeight = kAnlSumLine;
                NSRect need = [longText boundingRectWithSize:NSMakeSize(sum.frame.size.width, CGFLOAT_MAX)
                                                     options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                                  attributes:@{NSFontAttributeName: sum.font,
                                                               NSParagraphStyleAttributeName: mps}];
                const double needH = ceil(need.size.height);
                Ck(sum.frame.size.height >= needH - 1.5,
                   "长摘要独占的行高足够（不被省略号/固定高裁掉）",
                   [NSString stringWithFormat:@"label=%.1f need=%.1f", sum.frame.size.height, needH]);
                Ck(dyn.frame.size.height > heightBefore + 8,
                   "长摘要把卡片撑高（旧码的固定高上限不存在了）",
                   [NSString stringWithFormat:@"before=%.1f after=%.1f", heightBefore, dyn.frame.size.height]);
                Ck(dyn.frame.size.height >= 7 + 13 + 4 + needH + 8 - 1.5,
                   "卡片高度 ≥ 标题 + 长摘要 + 内边距（height grows to fit）",
                   [NSString stringWithFormat:@"card=%.1f need=%.1f", dyn.frame.size.height, needH]);
                sum.stringValue = orig;
                [vc layoutWebPlayback];
                [v layoutSubtreeIfNeeded];
            } else {
                Ck(NO, "长摘要生长判据", @"没有摘要子视图，无法量（旧码的固定高就是本条要抓的病）");
            }
        }

        // 多声道徽标（fixture channels=6 ⟹ web .anlbadge「多声道 6 ch」）
        {
            NSTextField *badge = dyn ? (NSTextField *)FindById(dyn, @"anl.dyn.badge") : nil;
            Ck(badge != nil, "多声道徽标出现（channels=6）", @"anl.dyn.badge 缺失");
            if (badge) {
                Ck([badge.stringValue isEqualToString:@"多声道 6 ch"], "徽标文案「多声道 6 ch」",
                   [NSString stringWithFormat:@"got=「%@」", badge.stringValue ?: @""]);
                Geo("anlbadge.font", 9.5, badge.font.pointSize, 0.3);
                Geo("anlbadge.radius", 5, LayerRadius(badge), 1.0);
                Ck(!badge.hidden, "徽标可见", @"badge.hidden=YES");
            }
        }

        // 卡片点击 = 打开详细档（web 点卡头 = anlSetLvl，旧码是 NSButton action）
        {
            NSView *card = dyn;
            BOOL hasTap = card && [card respondsToSelector:@selector(onTap)];
            id blk = hasTap ? [card valueForKey:@"onTap"] : nil;
            Ck(hasTap && blk != nil, "卡片暴露生产点击入口（tap → 详细档）",
               [NSString stringWithFormat:@"respondsToSelector=%d block=%d", hasTap, !!blk]);
        }

        // ---------------------------------------------------------------
        // ③ 展开档 L1：三张卡**仍然可见**，卡内长出 2 列指标网格。
        //    （旧码在展开时 button.hidden=open + 一块纯文本 blob，这正是要删掉的路径。）
        // ---------------------------------------------------------------
        [vc onAnlExpand:nil];        // 生产入口：与点「详细」分段同一路径
        [vc layoutWebPlayback];
        [v layoutSubtreeIfNeeded];
        const NSInteger lvl1 = [[vc valueForKey:@"anlLevel"] integerValue];
        Ck(lvl1 == 1, "点「详细」进入 L1（生产档位）",
           [NSString stringWithFormat:@"level=%ld", (long)lvl1]);
        NSView *dyn1 = FindById(panel, @"anl.dyn");
        const double dynL1H = dyn1 ? dyn1.frame.size.height : 0;
        NSView *qual1 = FindById(panel, @"anl.qual");
        NSView *fake1 = FindById(panel, @"anl.fake");
        Ck(dyn1 && qual1 && fake1, "展开档三张卡仍在视图树里（不是被换成一块文本）",
           [NSString stringWithFormat:@"dyn=%d qual=%d fake=%d", !!dyn1, !!qual1, !!fake1]);
        NSInteger visibleCards = 0;
        for (NSView *c in @[dyn1, qual1, fake1])
            if (c && !c.hidden && c.frame.size.height > 40) ++visibleCards;
        Ck(visibleCards == 3, "展开档三张卡全部可见且有内容高度",
           [NSString stringWithFormat:@"visible=%ld", (long)visibleCards]);

        NSMutableArray<NSView *> *lbs = [NSMutableArray array], *vals = [NSMutableArray array];
        CollectById(panel, @"anl.lb", lbs);
        CollectById(panel, @"anl.v", vals);
        Ck(lbs.count >= 12 && vals.count >= 12,
           "指标网格 ≥12 对 label/value（web L1 是 6+8+6 行）",
           [NSString stringWithFormat:@"labels=%lu values=%lu", (unsigned long)lbs.count, (unsigned long)vals.count]);
        for (NSView *n in lbs) {
            NSFont *f = FontOfView(n);
            if (f && f.pointSize > 10.5) { Geo("anllb.font", 10, f.pointSize, 0.3); break; }
        }
        {
            NSFont *f = nil;
            for (NSView *n in lbs) { NSFont *ff = FontOfView(n); if (ff) { f = ff; break; } }
            Ck(f != nil && fabs(f.pointSize - 10) <= 0.3, "标签 10px（web .anllb）",
               [NSString stringWithFormat:@"%.1f", f ? f.pointSize : -1]);
            NSFont *vf = nil, *naf = nil;
            for (NSView *n in vals) {
                if (![n isKindOfClass:[NSTextField class]]) continue;
                NSTextField *tf = (NSTextField *)n;
                if ([tf.stringValue hasPrefix:@"NA"]) { if (!naf) naf = tf.font; }
                else if (!vf) vf = tf.font;
            }
            Ck(vf != nil && fabs(vf.pointSize - 11) <= 0.3, "数值 11px（web .anlv）",
               [NSString stringWithFormat:@"%.1f", vf ? vf.pointSize : -1]);
            Ck(naf != nil && fabs(naf.pointSize - 10.5) <= 0.3,
               "NA 值 10.5px（web .anlv.na 略小一档、可换行）",
               [NSString stringWithFormat:@"%.1f", naf ? naf.pointSize : -1]);
        }
        NSInteger flushOK = 0, flushTotal = 0, rightAligned = 0;
        for (NSView *n in vals) {
            if (![n isKindOfClass:[NSTextField class]]) continue;
            NSTextField *tf = (NSTextField *)n;
            if (tf.alignment == NSTextAlignmentRight) ++rightAligned;
            NSView *card = nil;
            for (NSView *s = n.superview; s; s = s.superview) {
                if ([s.identifier isEqualToString:@"anl.dyn"] ||
                    [s.identifier isEqualToString:@"anl.qual"] ||
                    [s.identifier isEqualToString:@"anl.fake"]) { card = s; break; }
            }
            if (!card) continue;
            const double w = card.bounds.size.width;
            const double contentW = w - 18;
            const double colRightL = 9 + (contentW - 10) / 2.0;
            const double colRightR = w - 9;
            const double got = NSMaxX(tf.frame);
            ++flushTotal;
            if (fabs(got - colRightL) <= 1.6 || fabs(got - colRightR) <= 1.6) ++flushOK;
        }
        Ck(flushTotal > 0 && flushOK == flushTotal,
           "数值右缘贴齐所在列右缘（web .anlml justify-content:space-between）",
           [NSString stringWithFormat:@"%ld/%ld", (long)flushOK, (long)flushTotal]);
        Ck(rightAligned == (NSInteger)vals.count && vals.count > 0,
           "数值全部右对齐（web .anlv text-align:right）",
           [NSString stringWithFormat:@"%ld/%lu", (long)rightAligned, (unsigned long)vals.count]);

        // 分组标题：10px/700/kern .7 + 顶部 1px 规则（web .anlsec）
        NSMutableArray<NSView *> *secs = [NSMutableArray array];
        CollectById(panel, @"anl.sec", secs);
        Ck(secs.count >= 1, "至少一个分组标题 .anlsec", [NSString stringWithFormat:@"secs=%lu", (unsigned long)secs.count]);
        {
            NSTextField *sec = nil;
            for (NSView *n in secs) if ([n isKindOfClass:[NSTextField class]]) { sec = (NSTextField *)n; break; }
            Ck(sec != nil, "分组标题是真实文本子视图", @"");
            if (sec) {
                Geo("anlsec.font", 10, sec.font.pointSize, 0.3);
                Ck(FontIsWeight(sec.font, NSFontWeightBold), "分组标题 700（web .anlsec font-weight:700）",
                   [NSString stringWithFormat:@"%.1fpt", sec.font.pointSize]);
                Geo("anlsec.kern", 0.7, KernOf(sec), 0.15);
            }
            NSMutableArray<NSView *> *rules = [NSMutableArray array];
            CollectById(panel, @"anl.sec.rule", rules);
            BOOL hasRule = NO;
            for (NSView *r in rules)
                if (r.layer && r.layer.backgroundColor != NULL) hasRule = YES;
            Ck(hasRule, "分组标题带顶部 1px 规则（border-top）",
               [NSString stringWithFormat:@"rules=%lu", (unsigned long)rules.count]);
        }

        // 真峰过载警告框：必须 1px 边 + 琥珀底（任何档位都不许被折叠掉）
        {
            NSView *warn = FindById(panel, @"anl.dyn.warn");
            Ck(warn != nil, "真峰过载警告框存在（anl.dyn.warn）", @"warn 缺失");
            if (warn) {
                Ck(BorderWidth(warn) >= 1, "警告框有边框", [NSString stringWithFormat:@"%.1f", BorderWidth(warn)]);
                const CGFloat alpha = warn.layer && warn.layer.backgroundColor
                    ? CGColorGetAlpha(warn.layer.backgroundColor) : 0;
                Ck(alpha >= 0.05, "警告框有琥珀底色（web .anlwarn rgba(234,179,8,.10)）",
                   [NSString stringWithFormat:@"alpha=%.2f", (double)alpha]);
                Geo("anlwarn.radius", 7, LayerRadius(warn), 1.0);
                NSTextField *wt = (NSTextField *)FindById(warn, @"anl.warn.txt");
                Ck(wt != nil, "警告框有主文", @"anl.warn.txt 缺失");
                if (wt) {
                    Geo("anlwarn.font", 10.5, wt.font.pointSize, 0.3);
                    Ck([wt.stringValue containsString:@"母带要修"],
                       "主文说清「母带要修」（不编造数值，只用后端给的 +1.80 dBTP）",
                       [NSString stringWithFormat:@"got=「%@」", wt.stringValue ?: @""]);
                    Ck([wt.stringValue containsString:@"+1.80"] || [wt.stringValue containsString:@"1.80"],
                       "警告里带后端真峰值", [NSString stringWithFormat:@"got=「%@」", wt.stringValue ?: @""]);
                }
            }
        }

        // N/A 必须是灰字，且绝不能把 -300 哨兵排成测量值
        {
            NSMutableArray<NSView *> *naVals = [NSMutableArray array];
            for (NSView *n in vals) {
                if (![n isKindOfClass:[NSTextField class]]) continue;
                NSTextField *tf = (NSTextField *)n;
                if ([tf.stringValue hasPrefix:@"NA"]) [naVals addObject:tf];
            }
            Ck(naVals.count >= 1, "fixture 的 DR/LRA 不适用 ⟹ 出现 NA 值",
               [NSString stringWithFormat:@"na=%lu", (unsigned long)naVals.count]);
            NSInteger greyOK = 0;
            for (NSTextField *tf in naVals) if (SameColor(tf.textColor, [RLPTheme current].mut2)) ++greyOK;
            Ck(naVals.count > 0 && greyOK == (NSInteger)naVals.count,
               "NA 值用灰字（web .anlv.na color:var(--mut2)）",
               [NSString stringWithFormat:@"%ld/%lu", (long)greyOK, (unsigned long)naVals.count]);
            BOOL anyNA = NO, anySentinel = NO;
            for (NSView *n in vals) {
                if (![n isKindOfClass:[NSTextField class]]) continue;
                NSString *s = ((NSTextField *)n).stringValue;
                if ([s containsString:@"-300"]) anySentinel = YES;
                if ([s hasPrefix:@"NA"]) anyNA = YES;
            }
            Ck(!anySentinel, "网格里绝不出现 -300 哨兵（后端哨兵不是测量值）", @"found -300");
            Ck(anyNA, "不适用原因以 NA（…）如实显示（不是 0）", @"");

            // 真实值也必须来自 fixture：-14.20 LUFS / 48 kHz / 6 ch
            BOOL sawLUFS = NO, sawCh = NO;
            for (NSView *n in vals) {
                if (![n isKindOfClass:[NSTextField class]]) continue;
                NSString *s = ((NSTextField *)n).stringValue;
                if ([s containsString:@"-14.20"]) sawLUFS = YES;
                if ([s containsString:@"6 ch"]) sawCh = YES;
            }
            Ck(sawLUFS && sawCh, "L1 真实数值逐项来自 health（-14.20 LUFS / 6 ch）",
               [NSString stringWithFormat:@"lufs=%d ch=%d", sawLUFS, sawCh]);
        }

        // ---------------------------------------------------------------
        // ④ L2「全部指标」：更多分组，卡片仍可见。
        // ---------------------------------------------------------------
        [vc onAnlExpand:nil];
        [vc layoutWebPlayback];
        [v layoutSubtreeIfNeeded];
        const NSInteger lvl2 = [[vc valueForKey:@"anlLevel"] integerValue];
        Ck(lvl2 == 2, "再点一次进入 L2（全部指标）", [NSString stringWithFormat:@"level=%ld", (long)lvl2]);
        NSMutableArray<NSView *> *lbs2 = [NSMutableArray array], *vals2 = [NSMutableArray array];
        CollectById(panel, @"anl.lb", lbs2);
        CollectById(panel, @"anl.v", vals2);
        Ck(lbs2.count > lbs.count, "L2 指标多于 L1（全量指标真的显示出来）",
           [NSString stringWithFormat:@"L1=%lu L2=%lu", (unsigned long)lbs.count, (unsigned long)lbs2.count]);
        NSMutableArray<NSView *> *secs2 = [NSMutableArray array];
        CollectById(panel, @"anl.sec", secs2);
        Ck(secs2.count > secs.count, "L2 有更多分组标题（采样规格/原始证据等）",
           [NSString stringWithFormat:@"L1=%lu L2=%lu", (unsigned long)secs.count, (unsigned long)secs2.count]);
        NSView *dyn2 = FindById(panel, @"anl.dyn");
        Ck(dyn2 && !dyn2.hidden && dyn2.frame.size.height > 40, "L2 三卡仍可见（没有被纯文本 blob 顶掉）", @"");
        {
            BOOL sawFs2 = NO;
            for (NSView *n in vals2) {
                if (![n isKindOfClass:[NSTextField class]]) continue;
                if ([((NSTextField *)n).stringValue containsString:@"48000"]) sawFs2 = YES;
            }
            Ck(sawFs2, "L2 采样规格显示后端 fs=48000 Hz", @"");
        }

        // ---------------------------------------------------------------
        // ⑤ 切回收起：同样的卡片身份回到紧凑档（不再有指标行）。
        // ---------------------------------------------------------------
        // web `#npAnlBody` 的 13pt 沟槽：盒子撑到面板右缘、卡片右缘到盒子右缘 25（13 留白 +
        // 12pt 拇指条），拇指自绘在沟槽里、不与卡片相交；不新增 NSScrollView（单层滚动）。
        {
            NSView *body = FindById(panel, @"npAnlBody");
            Ck(body != nil, "npAnlBody 存在（沟槽判据前提）", @"");
            if (body) {
                Ck(fabs(NSMaxX(body.frame) - panelW) <= 1.0,
                   "npAnlBody 右缘撑到面板右缘（web margin-right:-11）",
                   [NSString stringWithFormat:@"body.maxX=%.1f panelW=%.1f", NSMaxX(body.frame), panelW]);
                Ck(fabs(NSWidth(body.frame) - (panelW - 12)) <= 0.5,
                   "npAnlBody 宽度 = panelW-12（左缘 12；右缘撑满面板 ⇒ 比 web 的 panelW-13 宽 1pt，卡宽仍 25 沟槽对齐）",
                   [NSString stringWithFormat:@"bodyW=%.1f want=%.1f", NSWidth(body.frame), panelW - 12]);
                // 两者都要在**同一坐标系**里量：卡片 frame 是 body 局部坐标，body 宽也用 bounds。
                Ck(fabs((NSWidth(body.frame) - NSMaxX(dyn.frame)) - 25.0) <= 1.5,
                   "卡片右缘到盒子右缘 = 25（13pt 留白 + 12pt 拇指条，常驻）",
                   [NSString stringWithFormat:@"gap=%.1f bodyW=%.1f cardMaxX=%.1f",
                    NSWidth(body.frame) - NSMaxX(dyn.frame), NSWidth(body.frame), NSMaxX(dyn.frame)]);
                BOOL hasThumb = [body respondsToSelector:@selector(scrollThumbRect)];
                Ck(hasThumb, "npAnlBody 暴露自绘拇指矩形（不靠 NSScrollView）", @"");
                if (hasThumb) {
                    NSRect thumb = [body scrollThumbRect];
                    Ck(!NSIsEmptyRect(thumb), "L2 溢出时拇指出现（内容高 > 可见高）",
                       [NSString stringWithFormat:@"thumb=%@ contentH=%.1f", NSStringFromRect(thumb),
                        [[body valueForKey:@"contentHeight"] doubleValue]]);
                    if (!NSIsEmptyRect(thumb)) {
                        Ck(NSMinX(thumb) - NSMaxX(dyn.frame) >= 13.0,
                           "拇指与卡片右缘 ≥13pt（滚动条不压卡片圆角）",
                           [NSString stringWithFormat:@"clear=%.1f", NSMinX(thumb) - NSMaxX(dyn.frame)]);
                        Ck(NSMaxX(thumb) <= NSWidth(body.frame) + 0.5,
                           "拇指在 body 右缘沟槽内", NSStringFromRect(thumb));
                    }
                }
                Ck(![body isKindOfClass:[NSScrollView class]],
                   "卡片区不是 NSScrollView（单层滚动判据不新增滚动容器）", @"");
            }
        }

        [vc onAnlExpand:nil];     // L2 → L0
        [vc layoutWebPlayback];
        [v layoutSubtreeIfNeeded];
        Ck([[vc valueForKey:@"anlLevel"] integerValue] == 0, "第三次点击回到收起档",
           [NSString stringWithFormat:@"level=%ld", (long)[[vc valueForKey:@"anlLevel"] integerValue]]);
        NSView *dyn0 = FindById(panel, @"anl.dyn");
        NSView *qual0 = FindById(panel, @"anl.qual");
        NSView *fake0 = FindById(panel, @"anl.fake");
        Ck(dyn0 == dyn && qual0 == qual && fake0 == fake,
           "收起档恢复同一批卡片视图（身份不变，不是重建一套）",
           [NSString stringWithFormat:@"dyn=%d qual=%d fake=%d", dyn0 == dyn, qual0 == qual, fake0 == fake]);
        NSMutableArray<NSView *> *lbs0 = [NSMutableArray array], *vals0 = [NSMutableArray array];
        CollectById(panel, @"anl.lb", lbs0);
        CollectById(panel, @"anl.v", vals0);
        Ck(lbs0.count == 0 && vals0.count == 0,
           "收起档没有指标行（回到紧凑摘要档）",
           [NSString stringWithFormat:@"labels=%lu values=%lu", (unsigned long)lbs0.count, (unsigned long)vals0.count]);
        Ck(dyn0 && dyn0.frame.size.height < dynL1H,
           "收起档比展开档矮（固定高上限已移除，同时仍按内容收缩）",
           [NSString stringWithFormat:@"L0=%.1f L1=%.1f", dyn0 ? dyn0.frame.size.height : -1, dynL1H]);
        if (togBtn) {
            Ck([togBtn.title isEqualToString:@"详细"] || [[togBtn attributedTitle].string isEqualToString:@"详细"],
               "收起档分段标题回到「详细」",
               [NSString stringWithFormat:@"got=「%@」/「%@」", togBtn.title, [togBtn attributedTitle].string]);
        }

        // ---------------------------------------------------------------
        // ⑥ 既有行为：自动分析开关、强制重算 URL 不变。
        // ---------------------------------------------------------------
        [vc onToggleAuto:nil];
        BOOL lastPostSettings = NO;
        NSString *lastBody = g_postBodies.lastObject ?: @"";
        for (NSString *u in g_postURLs) if ([u isEqualToString:@"/api/settings"]) lastPostSettings = YES;
        Ck(lastPostSettings && [lastBody isEqualToString:@"autoanl=1"],
           "「自动」段仍然真的把 autoanl 写回后端（行为未变）",
           [NSString stringWithFormat:@"body=「%@」", lastBody]);
        Ck([[vc valueForKey:@"anlAutoEnabled"] boolValue], "自动开关状态已置为开", @"");

        NSString *lastHealth = nil;
        for (NSString *u in g_getURLs) if ([u hasPrefix:@"/api/track/health"]) lastHealth = u;
        Ck(lastHealth != nil && [lastHealth containsString:@"force=1"],
           "「分析」段仍然强制重算（force=1，URL 形状未变）",
           [NSString stringWithFormat:@"got=「%@」", lastHealth ?: @""]);
        Ck(g_getURLs.count >= 1, "分析请求真的发过一次（不是只改了文案）",
           [NSString stringWithFormat:@"gets=%lu", (unsigned long)g_getURLs.count]);

        // ---------------------------------------------------------------
        // ⑦ 生产默认窗口 1180×760：头部三件东西在窄面板里也不能被截断。
        // ---------------------------------------------------------------
        {
            v.frame = NSMakeRect(0, 0, 1180, 760);
            [vc layoutWebPlayback];
            [v layoutSubtreeIfNeeded];
            NSTextField *lab2 = (NSTextField *)FindById(panel, @"npAnlLab");
            NSTextField *stat2 = (NSTextField *)FindById(panel, @"npAnlStat");
            NSView *seg2 = FindById(panel, @"npAnlSeg");
            const double pw = panel.bounds.size.width;
            Ck(lab2 && lab2.frame.size.width >= ceil(lab2.attributedStringValue.size.width) - 0.5,
               "1180 窗口下面板标题仍完整（不被截断）",
               [NSString stringWithFormat:@"panel=%.1f frame=%.1f need=%.1f", pw,
                lab2.frame.size.width, lab2.attributedStringValue.size.width]);
            // 同 279 行：web `.anlheadtop` 的 26px 右内边距 + 面板 11 ⟹ 37（旧码漏算 26 写成 13）。
            Ck(stat2 && fabs(NSMaxX(stat2.frame) - (pw - 37)) <= 1.0,
               "1180 窗口下状态仍贴右（距面板右缘 37±1，web .anlheadtop padding-right:26）",
               [NSString stringWithFormat:@"panel=%.1f right=%.1f", pw, NSMaxX(stat2.frame)]);
            Ck(seg2 && NSMaxX(seg2.frame) <= pw - 11 + 0.5 && NSMaxX(seg2.frame) >= pw - 12,
               "1180 窗口下分段控件右端贴齐面板内容右缘（11px 内边距）",
               [NSString stringWithFormat:@"panel=%.1f segRight=%.1f", pw, NSMaxX(seg2.frame)]);
        }

        // ---------------------------------------------------------------
        // ⑧ U10 完整性：后端判 incomplete 时，状态串必须说「文件可能不完整」，
        //    三张摘要卡不许把"分析成功但文件可能短了一截"说成「分析未完成」。
        //    （后端 note 的"首行原样展示"在详情文本路径上，由 test_analysis_row 的纯函数用例钉住。）
        // ---------------------------------------------------------------
        {
            NSMutableDictionary *inc = [AnlFixtureHealth() mutableCopy];
            inc[@"status"] = @"incomplete";
            inc[@"incomplete"] = @YES;
            inc[@"declared_sec"] = @10.0;
            inc[@"duration_sec"] = @4.99;
            inc[@"note"] = @"文件可能不完整：容器声明 10.000 s，实际解码 4.990 s（49.9%）—— "
                           @"若这首正在拷贝/下载，请等复制完成后再分析一次";
            g_healthEnv = @{ @"ok": @YES, @"usable": @YES, @"cached": @NO, @"health": inc };
            [vc onAnlReanalyze:nil];
            [vc layoutWebPlayback];
            [v layoutSubtreeIfNeeded];
            NSTextField *statU10 = (NSTextField *)FindById(panel, @"npAnlStat");
            Ck(statU10 != nil && [statU10.stringValue isEqualToString:@"文件可能不完整"],
               "U10 状态串：incomplete ⟹「文件可能不完整」（不是「已分析」也不是「分析失败」）",
               [NSString stringWithFormat:@"got=「%@」", statU10.stringValue ?: @""]);
            // 卡片标识由 setCardKey 派生：「anl.fake」⟹ 摘要标签是「anl.fake.sum」。
            NSView *fakeCard = FindById(panel, @"anl.fake");
            NSTextField *fakeSumLab = (NSTextField *)FindById(fakeCard, @"anl.fake.sum");
            NSString *fakeSum = nil;
            if ([fakeSumLab isKindOfClass:[NSTextField class]]) {
                NSAttributedString *as = fakeSumLab.attributedStringValue;
                fakeSum = as.string.length ? as.string : fakeSumLab.stringValue;
            }
            Ck(fakeSum != nil && ![fakeSum containsString:@"分析未完成"],
               "U10 摘要：incomplete 不被说成「分析未完成」（前端若这么说，用户会去重跑而不是等拷贝）",
               [NSString stringWithFormat:@"got=「%@」", fakeSum ?: @"(nil)"]);
        }

        std::printf("结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
