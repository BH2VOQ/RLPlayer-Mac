// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_npmeta_chips.mm — 正在播放页 #npMeta 芯片行与 web 的**逐值**对齐
//
// ============================ 这条判据在证明什么 ============================
// web 真相（src/net/ui_page.h + ui_script.h）：
//   .npmline  : display:flex; align-items:center; gap:6; flex-wrap:wrap;
//               margin-top:10; min-height:22                        (ui_page.h:824)
//   .badge    : 9.5px/600; letter-spacing:.3px; padding:2px 7px; radius:5;
//               bg/border --acc-weak; color --acc-text; white-space:nowrap
//                                                                        (ui_page.h:1096)
//   .badge.g  : bg --ok-bg / color --ok-text / border --ok-line（「已补全」）
//   .chip     : 11px; padding:3px 9px; radius:12; bg --bg3; color --txt2;
//               border --line; gap:5                                    (ui_page.h:1097)
//   #npMeta   : innerHTML = buildNpMetaHtml(m)          ← /api/meta（enriched + sources）
//                          + npEqChipsHtml()            ← /api/settings kv.eq / kv.ir
//                          + npCastBtnHtml()              ← 投放 / 加歌单          (ui_script.h:13516)
 //  芯片文案 : `年份  2019`（两个空格）、tooltip `来源: <sources[key] or 本地标签>`
//             EQ: `当前 EQ：<basename>（点击打开 EQ 与房间校正）`，点击 closeNowPlaying + openSettingsTab('eq')
//
// 1.1.7.26 的原生实现（本文件对**未修改的生产码**先跑红）：
//   #npMeta 里只有 4 个 11pt/radius10 的 NSButton（年份/流派/专辑艺术家/已补全），
//   整行在 meta.enriched!==true 时直接 hidden ⟹ EQ/IR/投放/加歌单**永远不可能出现在这一行**；
//   投放/加歌单是两个 94×24 的独立按钮（在下面 infoY+113 那一行），不是 .chip；
//   行内没有 flex-wrap（一个 cx 单调右移，窄了直接溢出）。
//   ⟹ 本文件里的「徽标 9.5/600/kern.3/radius5/acc-weak」「EQ/IR 芯片」「cast/add 在行内」
//      「enriched=false 仍有 EQ 行」「窄宽换行不重叠」全部红。
//
// ============================ 铁律：绝不出声 / 不开窗 ============================
// RLPCoreClient 全桩（只记录 URL，按夹具回 JSON）；不启动核心、不碰音频设备、
// 不创建可见窗口（off-window 视图树 + run-loop pump）；点击只走 target/action 的
// sendAction，真正弹层/弹窗的路径不触发（NSPopover 在无窗口视图上会被生产码跳过）。
//
// 红→绿：evidence/native-npmeta-chips-red-20261114.log → ...-green-20261114.log
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "RLPNowPlayingViewController.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

#include <cmath>
#include <cstdio>

static int g_fail = 0, g_pass = 0;

static void Ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++g_fail; }
}
static void EqStr(NSString *got, NSString *want, const char *what) {
    Ck([got isEqualToString:want], what,
       [NSString stringWithFormat:@"got=「%@」 want=「%@」", got ?: @"", want ?: @""]);
}
static void HasStr(NSString *got, NSString *needle, const char *what) {
    Ck([got containsString:needle], what,
       [NSString stringWithFormat:@"got=「%@」 缺少「%@」", got ?: @"", needle ?: @""]);
}

#pragma mark - 桩客户端（零真实请求）

static NSMutableArray<NSString *> *g_urls = nil;
static NSMutableDictionary *g_lastPost = nil;
static BOOL g_enriched = YES;

static NSString *const kPath = @"/Music/夜想曲.m4a";

static NSDictionary *MetaFixture(BOOL enriched) {
    return @{
        @"ok": @YES, @"title": @"夜想曲", @"artist": @"Aimer", @"album": @"Album Y",
        @"year": @"2019", @"genre": @"日本流行樂", @"albumArtist": @"Aimer",
        @"codec": @"flac", @"sampleRate": @96000, @"bits": @24,
        @"summaryEnabled": @NO, @"summaryAvailable": @NO,
        @"meta": @{ @"enriched": @(enriched), @"sources": @{ @"year": @"在线补全" } },
    };
}

static id ResponseForPath(NSString *path) {
    if ([path hasPrefix:@"/api/meta"]) return MetaFixture(g_enriched);
    // web loadSettings 的同一份 kv：autoanl / eq / ir 全在这一个响应里。
    if ([path hasPrefix:@"/api/settings"]) return @{ @"ok": @YES, @"kv": @{
        @"autoanl": @"0", @"eq": @"eq/test.txt", @"ir": @"ir/test.wav" } };
    if ([path hasPrefix:@"/api/cast/state"]) return @{ @"ok": @YES, @"running": @NO, @"device": @"" };
    if ([path hasPrefix:@"/api/status"]) return @{ @"ok": @YES, @"playing": @YES, @"paused": @NO,
        @"current": kPath, @"dur": @225, @"pos": @0, @"volDb": @(-120) };
    if ([path hasPrefix:@"/api/queue"]) return @{ @"ok": @YES, @"items": @[], @"index": @(-1), @"mode": @0 };
    if ([path hasPrefix:@"/api/fav/list"]) return @{ @"ok": @YES, @"files": @[] };
    if ([path hasPrefix:@"/api/sq/list"]) return @{ @"ok": @YES,
        @"queues": @[ @{ @"name": @"测试歌单", @"n": @2 } ] };
    if ([path hasPrefix:@"/api/lyrics"]) return @{ @"ok": @NO };
    return @{ @"ok": @NO };
}

#pragma mark clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RLPCoreClient
+ (instancetype)shared { static RLPCoreClient *c; if (!c) c = [self new]; return c; }
- (BOOL)started { return NO; }
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    [g_urls addObject:path];
    NSDictionary *resp = ResponseForPath(path);
    dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(resp); });
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done {
    [g_urls addObject:path];
    if (done) done(nil);
}
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    [g_urls addObject:path];
    g_lastPost = [@{ @"path": path ?: @"", @"body": body ?: @"" } mutableCopy];
    if (done) done(@{ @"ok": @YES });
}
@end
#pragma mark clang diagnostic pop

#pragma mark - 通知记录

static NSMutableArray<NSDictionary *> *g_notes = nil;
static NSMutableArray<id> *g_observers = nil;

static void ObserveAll(void) {
    if (g_notes) return;
    g_notes = [NSMutableArray array];
    g_observers = [NSMutableArray array];
    for (NSString *name in @[ @"RLPCloseNowPlayingNotification", @"RLPOpenSettingsPaneNotification" ]) {
        id token = [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil
            usingBlock:^(NSNotification *n) {
                [g_notes addObject:@{ @"name": n.name,
                                      @"object": [n.object isKindOfClass:[NSString class]] ? n.object : @"" }];
            }];
        [g_observers addObject:token];
    }
}

#pragma mark - 测试入口声明（生产里是私有方法；category 不改生产头文件）

@interface RLPNowPlayingViewController (NPMetaChipsTest)
- (void)renderMetaChipsFromMeta:(NSDictionary *)json;
- (void)layoutWebPlayback;
- (void)loadMetaAndKnowledgeForPath:(NSString *)path;
- (void)anlRefreshAutoSettingIfStale;
- (void)onEqChip:(id)sender;
- (void)onIrChip:(id)sender;
- (void)onSaveCurrent:(id)sender;
- (void)onCastCurrent:(id)sender;
@end

#pragma mark - 视图查找 / 判据工具

static NSView *FindById(NSView *root, NSString *ident) {
    if (!root) return nil;
    if ([root.identifier isEqualToString:ident]) return root;
    for (NSView *s in root.subviews) {
        NSView *r = FindById(s, ident);
        if (r) return r;
    }
    return nil;
}

/// NSButton 的可见文案：优先 attributedTitle（web 的 letter-spacing 落在那里）。
static NSString *ChipText(NSButton *b) {
    if (!b) return @"";
    NSAttributedString *as = b.attributedTitle;
    return as.length ? as.string : (b.title ?: @"");
}
static double KernOf(NSButton *b) {
    NSAttributedString *as = b.attributedTitle;
    if (!as.length) return 0.0;
    id k = [as attribute:NSKernAttributeName atIndex:0 effectiveRange:NULL];
    return k ? [k doubleValue] : 0.0;
}
static BOOL WeightIs600(NSFont *f) {
    if (!f) return NO;
    NSFont *probe = [NSFont systemFontOfSize:f.pointSize weight:NSFontWeightSemibold];
    return probe && [f isEqual:probe];
}
static NSColor *LayerBg(NSView *v) {
    return v.layer && v.layer.backgroundColor ? [NSColor colorWithCGColor:v.layer.backgroundColor] : nil;
}
static NSColor *LayerBorder(NSView *v) {
    return v.layer && v.layer.borderColor ? [NSColor colorWithCGColor:v.layer.borderColor] : nil;
}
static double LayerRadius(NSView *v) { return v.layer ? (double)v.layer.cornerRadius : 0.0; }
static double LayerBorderWidth(NSView *v) { return v.layer ? (double)v.layer.borderWidth : 0.0; }
static BOOL SameRGBA(NSColor *a, NSColor *b) {
    if (!a || !b) return a == b;
    NSColor *ca = [a colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    NSColor *cb = [b colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!ca || !cb) return NO;
    return fabs(ca.redComponent - cb.redComponent) < 0.035 &&
           fabs(ca.greenComponent - cb.greenComponent) < 0.035 &&
           fabs(ca.blueComponent - cb.blueComponent) < 0.035 &&
           fabs(ca.alphaComponent - cb.alphaComponent) < 0.05;
}
/// 徽标/芯片内文字颜色（attributedTitle 的 foreground 属性）。
static NSColor *TextColorOf(NSButton *b) {
    NSAttributedString *as = b.attributedTitle;
    if (!as.length) return nil;
    id c = [as attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL];
    return [c isKindOfClass:[NSColor class]] ? c : nil;
}

static void CheckChipGeometryAndIcon(NSButton *b) {
    if (!b) return;
    NSString *ident = b.identifier ?: @"(nil)";
    Class chipCls = NSClassFromString(@"RLPMetaChipButton");
    Ck(chipCls != Nil && [b isKindOfClass:chipCls],
       "芯片使用 RLPMetaChipButton（自定义居中 cell）",
       [NSString stringWithFormat:@"id=%@ cls=%@", ident, NSStringFromClass(b.class)]);
    Ck(fabs(b.frame.size.height - 24.0) <= 0.5,
       "芯片按钮高 24（web .chip line-height≈24）",
       [NSString stringWithFormat:@"id=%@ frame=%@", ident, NSStringFromRect(b.frame)]);
    Ck(b.image != nil,
       "芯片带 SF Symbol 图标",
       [NSString stringWithFormat:@"id=%@ image=nil", ident]);
    if (b.image) {
        NSImageSymbolConfiguration *symCfg = b.image.symbolConfiguration;
        double symPt = 0.0;
        BOOL hasSymPt = NO;
        if (symCfg && [symCfg respondsToSelector:NSSelectorFromString(@"pointSize")]) {
            id v = [symCfg valueForKey:@"pointSize"];
            if ([v respondsToSelector:@selector(doubleValue)]) {
                symPt = [v doubleValue];
                hasSymPt = YES;
            }
        }
        NSImageSymbolConfiguration *wantCfg =
            [NSImageSymbolConfiguration configurationWithPointSize:10.5 weight:NSFontWeightMedium];
        const BOOL ptOk = hasSymPt ? (symPt >= 10.0 && symPt <= 11.0)
                                   : (symCfg != nil && [symCfg isEqual:wantCfg]);
        Ck(ptOk,
           "芯片图标配置 pointSize 10.5（允许 10–11，新设计替代旧 11×11 写死尺寸）",
           [NSString stringWithFormat:@"id=%@ pt=%.2f hasPt=%d imgSize=%@ cfg=%@",
            ident, symPt, hasSymPt, NSStringFromSize(b.image.size), symCfg]);
    }

    NSRect bounds = b.bounds;
    NSRect iconRect = [b.cell imageRectForBounds:bounds];
    NSRect titleRect = [b.cell titleRectForBounds:bounds];
    NSString *rectDetail = [NSString stringWithFormat:@"id=%@ bounds=%@ iconRect=%@ titleRect=%@",
                            ident, NSStringFromRect(bounds), NSStringFromRect(iconRect), NSStringFromRect(titleRect)];
    Ck(!NSIsEmptyRect(iconRect) && !NSIsEmptyRect(titleRect),
       "RLPMetaChipCell 计算出非空 iconRect 与 titleRect", rectDetail);
    if (!NSIsEmptyRect(iconRect) && !NSIsEmptyRect(titleRect)) {
        Ck(iconRect.size.width >= 8.0 && iconRect.size.width <= 12.0 &&
           iconRect.size.height >= 8.0 && iconRect.size.height <= 12.0,
           "渲染 iconRect 落在合理缩放区间（8–12pt，不拉伸变形）", rectDetail);
        Ck(fabs(NSMidY(iconRect) - NSMidY(titleRect)) <= 1.0,
           "iconRect 与 titleRect 垂直居中对齐（midY 差 <= 1）", rectDetail);
        Ck(NSMinX(titleRect) >= NSMaxX(iconRect) + 3.5,
           "iconRect 与 titleRect 水平不重叠（保留间距）", rectDetail);
        NSAttributedString *attr = b.attributedTitle.length
            ? b.attributedTitle
            : [[NSAttributedString alloc] initWithString:(b.title ?: @"")
                                              attributes:@{ NSFontAttributeName: (b.font ?: [NSFont systemFontOfSize:11.0]) }];
        NSRect rawR = [attr boundingRectWithSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)
                                         options:(NSStringDrawingUsesLineFragmentOrigin |
                                                  NSStringDrawingTruncatesLastVisibleLine)
                                         context:nil];
        const double needW = ceil(rawR.size.width);
        Ck(titleRect.size.width >= needW - 0.5 && NSMaxX(titleRect) <= NSWidth(bounds) - 7.5,
           "芯片文本完整不截断（titleRect 容得下全文且不越出右侧内边距）",
           [NSString stringWithFormat:@"%@ needW=%.1f", rectDetail, needW]);
    }
}

static void Pump(double seconds) {
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static RLPNowPlayingViewController *NewVC(CGFloat width) {
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"RLPNPRailHidden"];
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"RLPNPAnalysisHidden"];
    RLPNowPlayingViewController *vc = [RLPNowPlayingViewController new];
    NSView *v = vc.view;                       // loadView → buildContent（离屏视图树）
    v.frame = NSMakeRect(0, 0, width, 760);
    [v layoutSubtreeIfNeeded];
    return vc;
}

static RLPPlaybackStatus *LiveStatus(void) {
    return [RLPPlaybackStatus statusFromJSON:@{ @"ok": @YES, @"playing": @YES, @"paused": @NO,
        @"current": kPath, @"dur": @225, @"pos": @0, @"volDb": @(-120) }];
}

/// 生产装配：当前曲目 + live 播放状态 + /api/meta + /api/settings（两条异步路径都走生产函数）。
static void AssembleLive(RLPNowPlayingViewController *vc) {
    g_enriched = YES;
    [vc setValue:kPath forKey:@"currentPath"];
    [vc setValue:LiveStatus() forKey:@"webStatus"];
    [vc loadMetaAndKnowledgeForPath:kPath];
    [vc anlRefreshAutoSettingIfStale];
    Pump(0.8);
    [vc layoutWebPlayback];
}

static BOOL RectOverlap(NSRect a, NSRect b) {
    return NSIntersectionRect(a, b).size.width > 0.5 && NSIntersectionRect(a, b).size.height > 0.5;
}

#pragma mark - 场景

/// 1) 1180px：徽标逐值 + EQ/IR + cast/add 全在同一行。
static void ScenarioBadgesAndChipsAt1180(void) {
    std::printf("--- 场景1：1180px 徽标（.badge）与 EQ/IR/投放/加歌单（.chip）同处 #npMeta ---\n");
    [g_urls removeAllObjects];
    RLPNowPlayingViewController *vc = NewVC(1180);
    AssembleLive(vc);
    RLPTheme *t = [RLPTheme current];

    NSView *row = FindById(vc.view, @"npMeta");
    Ck(row != nil, "找得到 #npMeta", @"npMeta 缺失");
    Ck(row && !row.hidden, "有芯片时 #npMeta 显示", @"npMeta 仍隐藏");
    if (!row) return;

    NSButton *year = (NSButton *)FindById(row, @"npMeta.year");
    NSButton *genre = (NSButton *)FindById(row, @"npMeta.genre");
    NSButton *albumArtist = (NSButton *)FindById(row, @"npMeta.albumArtist");
    NSButton *enriched = (NSButton *)FindById(row, @"npMeta.enriched");
    Ck(year && genre && albumArtist && enriched, "四个徽标都在 #npMeta 里（标识符不变）",
       @"缺 npMeta.year/genre/albumArtist/enriched");
    if (!year || !genre || !albumArtist || !enriched) return;
    Ck(!year.hidden && !genre.hidden && !albumArtist.hidden && !enriched.hidden,
       "enriched=true 时四个徽标都可见", @"有徽标仍隐藏");

    // ---- web .badge 的逐值：9.5/600、kern .3、radius 5、acc-weak 背景/描边、acc-text 文字 ----
    Ck(fabs(year.font.pointSize - 9.5) < 0.01 && WeightIs600(year.font),
       "徽标 9.5pt/600（web .badge font-size:9.5px;font-weight:600）",
       [NSString stringWithFormat:@"pt=%.2f w600=%d", year.font.pointSize, WeightIs600(year.font)]);
    Ck(fabs(KernOf(year) - 0.3) < 0.05, "徽标 letter-spacing .3（web letter-spacing:.3px）",
       [NSString stringWithFormat:@"kern=%.3f", KernOf(year)]);
    Ck(fabs(LayerRadius(year) - 5.0) < 0.01, "徽标 radius 5（web border-radius:5px）",
       [NSString stringWithFormat:@"r=%.2f", LayerRadius(year)]);
    Ck(LayerBorderWidth(year) == 1.0, "徽标 1px 描边（web border:1px solid）",
       [NSString stringWithFormat:@"bw=%.2f", LayerBorderWidth(year)]);
    Ck(SameRGBA(LayerBg(year), t.accentWeak), "徽标背景 = --acc-weak", @"背景不是 acc-weak");
    Ck(SameRGBA(LayerBorder(year), t.accentWeak), "徽标描边 = --acc-weak", @"描边不是 acc-weak");
    Ck(SameRGBA(TextColorOf(year), t.accentText), "徽标文字 = --acc-text", @"文字不是 acc-text");

    // ---- 文案：label + **两个**空格 + value（web p[1] + '  ' + v）----
    EqStr(ChipText(year), [NSString stringWithFormat:@"%@  2019", RLPTr(@"年份")],
          "年份徽标文案 = `年份  2019`（两个空格）");
    EqStr(ChipText(genre), [NSString stringWithFormat:@"%@  日本流行樂", RLPTr(@"流派")],
          "流派徽标文案 = `流派  日本流行樂`（两个空格）");
    EqStr(ChipText(albumArtist), [NSString stringWithFormat:@"%@  Aimer", RLPTr(@"专辑艺术家")],
          "专辑艺术家徽标文案 = `专辑艺术家  Aimer`（两个空格）");
    EqStr(ChipText(enriched), RLPTr(@"已补全"), "「已补全」徽标文案");
    for (NSButton *badge in @[ year, genre, albumArtist, enriched ]) {
        const double needW = ceil(badge.attributedTitle.size.width);
        Ck(badge.frame.size.width >= needW + 14.0 - 0.5,
           "徽标宽度容得下全文+左右内边距（不截断）",
           [NSString stringWithFormat:@"id=%@ frame=%@ needW=%.1f",
            badge.identifier, NSStringFromRect(badge.frame), needW]);
    }

    // ---- 来源提示：sources[key] 优先，缺失时「本地标签」----
    HasStr(year.toolTip, @"来源", "年份 tooltip 以「来源」开头（web esc('来源: ')）");
    HasStr(year.toolTip, @"在线补全", "年份 tooltip 用 meta.sources 的值（在线补全）");
    HasStr(genre.toolTip, RLPTr(@"本地标签"),
           "无 sources 的字段 tooltip 回落「本地标签」（不编造来源）");

    // ---- .badge.g 绿色三令牌 ----
    Ck(SameRGBA(LayerBg(enriched), t.okBg), "「已补全」背景 = --ok-bg", @"不是 ok-bg");
    Ck(SameRGBA(LayerBorder(enriched), t.okLine), "「已补全」描边 = --ok-line", @"不是 ok-line");
    Ck(SameRGBA(TextColorOf(enriched), t.okText), "「已补全」文字 = --ok-text", @"不是 ok-text");

    // ---- EQ / IR：同一行、.chip 度量、tooltip 含文件名、点击发两条通知 ----
    NSButton *eq = (NSButton *)FindById(row, @"npEqChip");
    NSButton *ir = (NSButton *)FindById(row, @"npIrChip");
    Ck(eq && ir, "EQ / IR 芯片存在（标识符 npEqChip / npIrChip）", @"缺 npEqChip/npIrChip");
    if (!eq || !ir) return;
    Ck(!eq.hidden && !ir.hidden, "kv.eq / kv.ir 非空时 EQ/IR 芯片可见", @"芯片被隐藏");
    Ck(eq.superview == year.superview && ir.superview == year.superview,
       "EQ/IR 与徽标同一个 superview（web 同一个 #npMeta）", @"不在 #npMeta 里");
    for (NSButton *b in @[ eq, ir ]) {
        Ck(fabs(b.font.pointSize - 11.0) < 0.01, "chip 11pt（web .chip font-size:11px）",
           [NSString stringWithFormat:@"pt=%.2f", b.font.pointSize]);
        Ck(fabs(LayerRadius(b) - 12.0) < 0.01, "chip radius 12（web border-radius:12px）",
           [NSString stringWithFormat:@"r=%.2f", LayerRadius(b)]);
        Ck(SameRGBA(LayerBg(b), t.bg3), "chip 背景 = --bg3", @"不是 bg3");
        Ck(SameRGBA(LayerBorder(b), t.line), "chip 描边 = --line", @"不是 line");
        Ck(SameRGBA(TextColorOf(b), t.text2), "chip 文字 = --txt2", @"不是 txt2");
    }
    EqStr(ChipText(eq), @"EQ", "EQ 芯片文案");
    EqStr(ChipText(ir), @"IR", "IR 芯片文案");
    CheckChipGeometryAndIcon(eq);
    CheckChipGeometryAndIcon(ir);
    HasStr(eq.toolTip, @"test.txt", "EQ tooltip 含当前 EQ 文件名（basename）");
    HasStr(eq.toolTip, RLPTr(@"当前 EQ："), "EQ tooltip 以「当前 EQ：」开头（web 同文案）");
    HasStr(eq.toolTip, RLPTr(@"（点击打开 EQ 与房间校正）"), "EQ tooltip 含点击说明");
    HasStr(ir.toolTip, @"test.wav", "IR tooltip 含当前 IR 文件名（basename）");
    HasStr(ir.toolTip, RLPTr(@"当前 IR："), "IR tooltip 以「当前 IR：」开头");

    // 点击 = closeNowPlaying() + openSettingsTab('eq')（通知对象 @"eq"）。
    EqStr(NSStringFromSelector(eq.action), @"onEqChip:", "EQ 芯片 action 指向生产方法 onEqChip:");
    Ck(eq.target == vc, "EQ 芯片 target = 控制器", @"target 不对");
    Ck(ir.target == vc, "IR 芯片 target = 控制器", @"target 不对");
    EqStr(NSStringFromSelector(ir.action), @"onIrChip:", "IR 芯片 action 指向生产方法 onIrChip:");
    for (NSButton *b in @[ eq, ir ]) {
        [g_notes removeAllObjects];
        @try { [NSApp sendAction:b.action to:b.target from:b]; }
        @catch (NSException *e) { std::printf("  (sendAction caught: %s)\n", e.reason.UTF8String ?: ""); }
        Ck(g_notes.count >= 2, "点击芯片发两条通知（先关页、再开设置）",
           [NSString stringWithFormat:@"n=%lu", (unsigned long)g_notes.count]);
        Ck(g_notes.count >= 1 &&
           [g_notes[0][@"name"] isEqualToString:@"RLPCloseNowPlayingNotification"],
           "第 1 条 = RLPCloseNowPlayingNotification（web closeNowPlaying()）",
           g_notes.count ? [g_notes componentsJoinedByString:@"|"] : @"无通知");
        Ck(g_notes.count >= 2 &&
           [g_notes[1][@"name"] isEqualToString:@"RLPOpenSettingsPaneNotification"],
           "第 2 条 = RLPOpenSettingsPaneNotification", @"通知顺序不对");
        Ck(g_notes.count >= 2 && [g_notes[1][@"object"] isEqualToString:@"eq"],
           "第 2 条通知对象 = @\"eq\"（openSettingsTab('eq')）", @"对象不是 eq");
    }

    // ---- 投放 / 加歌单：同一行 + 生产 action + .chip 度量 ----
    NSButton *cast = (NSButton *)FindById(row, @"npCastBtn");
    NSButton *add = (NSButton *)FindById(row, @"npAddSq");
    Ck(cast && add, "投放 / 加歌单芯片存在（npCastBtn / npAddSq）", @"缺 npCastBtn/npAddSq");
    if (!cast || !add) return;
    Ck(cast.superview == year.superview && add.superview == year.superview,
       "投放/加歌单与徽标同一个 superview（web 同一个 #npMeta）", @"不在 #npMeta 里");
    Ck(!cast.hidden && !add.hidden, "live 态下投放/加歌单可见", @"被隐藏");
    EqStr(NSStringFromSelector(cast.action), @"onCastCurrent:", "投放芯片 action = 既有 onCastCurrent:");
    EqStr(NSStringFromSelector(add.action), @"onSaveCurrent:", "加歌单芯片 action = 既有 onSaveCurrent:");
    Ck(cast.target == vc && add.target == vc, "两个芯片 target 都是控制器", @"target 不对");
    EqStr(ChipText(cast), RLPTr(@"推送到设备"), "未投放时文案「推送到设备」（web npCastBtnHtml）");
    EqStr(ChipText(add), RLPTr(@"添加到歌单"), "加歌单文案「添加到歌单」（web npAddSq）");
    Ck(fabs(cast.font.pointSize - 11.0) < 0.01 && fabs(LayerRadius(cast) - 12.0) < 0.01 &&
       SameRGBA(LayerBg(cast), t.bg3) && SameRGBA(LayerBorder(cast), t.line),
       "投放芯片是 web .chip 度量（11pt/radius12/bg3/line）", @"度量不对");
    Ck(fabs(add.font.pointSize - 11.0) < 0.01 && fabs(LayerRadius(add) - 12.0) < 0.01 &&
       SameRGBA(LayerBg(add), t.bg3) && SameRGBA(LayerBorder(add), t.line),
       "加歌单芯片是 web .chip 度量（11pt/radius12/bg3/line）", @"度量不对");
    CheckChipGeometryAndIcon(cast);
    CheckChipGeometryAndIcon(add);

    // 点击加歌单 = 走既有保存路径（RLPShowSaveToPlaylist → /api/sq/list）。无窗口时生产码跳过弹层。
    [g_urls removeAllObjects];
    @try { [NSApp sendAction:add.action to:add.target from:add]; }
    @catch (NSException *e) { std::printf("  (add sendAction caught: %s)\n", e.reason.UTF8String ?: ""); }
    Ck([g_urls containsObject:@"/api/sq/list"],
       "点击加歌单走既有保存路径（请求 /api/sq/list）", [g_urls componentsJoinedByString:@" | "]);

    // ---- 1180px 一行放得下：行高 = 单行 24（.chip 高度），不溢出 ----
    std::printf("  (npMeta frame at 1180: x=%.1f y=%.1f w=%.1f h=%.1f)\n",
                row.frame.origin.x, row.frame.origin.y, row.frame.size.width, row.frame.size.height);
    Ck(fabs(row.frame.size.height - 24.0) < 1.5,
       "1180px 下所有芯片同一行，行高=24（web .chip line-height≈24）",
       [NSString stringWithFormat:@"h=%.1f", row.frame.size.height]);
    Ck(NSMaxX(cast.frame) <= row.frame.size.width + 0.5 &&
       NSMaxX(add.frame) <= row.frame.size.width + 0.5,
       "最右芯片不超出 #npMeta 宽度（单行不溢出）", @"芯片溢出到行外");
}

/// 2) enriched=false 但 settings 有 eq：只隐藏徽标，EQ 芯片与整行仍在。
static void ScenarioEnrichedFalseKeepsEq(void) {
    std::printf("--- 场景2：enriched=false + kv.eq → #npMeta 仍在，只隐藏徽标 ---\n");
    RLPNowPlayingViewController *vc = NewVC(1180);
    AssembleLive(vc);
    NSView *row = FindById(vc.view, @"npMeta");
    NSButton *eq = (NSButton *)FindById(row, @"npEqChip");
    Ck(row && eq, "行与 EQ 芯片都在", @"缺 npMeta/npEqChip");
    if (!row || !eq) return;

    [vc renderMetaChipsFromMeta:@{ @"meta": @{ @"enriched": @NO } }];
    [vc layoutWebPlayback];
    Ck(!row.hidden, "enriched=false 时 #npMeta 仍显示（EQ 芯片还在）", @"又退回「整行隐藏」的旧闸门");
    Ck(!eq.hidden, "EQ 芯片仍可见", @"EQ 被连带隐藏");
    Ck(eq.superview == row, "EQ 仍在 #npMeta 里", @"EQ 被移走");
    BOOL anyBadge = NO;
    for (NSString *ident in @[ @"npMeta.year", @"npMeta.genre", @"npMeta.albumArtist", @"npMeta.enriched" ]) {
        NSButton *b = (NSButton *)FindById(row, ident);
        if (b && !b.hidden) anyBadge = YES;
    }
    Ck(!anyBadge, "enriched=false 时只隐藏四个徽标（不假装有资料）", @"有徽标仍可见");
}

/// 3) 窄宽换行：行高 > 单行、芯片不重叠、按钮行在行底之下。
static void ScenarioWrappingAtNarrowWidth(void) {
    std::printf("--- 场景3：窄宽 flex-wrap（gap 6；行高按实际行数增长） ---\n");
    RLPNowPlayingViewController *vc = NewVC(1180);
    AssembleLive(vc);
    [vc renderMetaChipsFromMeta:MetaFixture(YES)];   // 保证四个徽标也在（AssembleLive 已喂过，这里复位确定）
    [vc layoutWebPlayback];
    NSView *row = FindById(vc.view, @"npMeta");
    Ck(row && !row.hidden, "#npMeta 可见", @"行隐藏，无法量几何");
    if (!row) return;
    const CGFloat oneLine = row.frame.size.height;

    NSRect wideFrame = row.frame;
    // 640px：扣掉封面+间距后可用宽度 ≈ 392px，8 个芯片放不进一行。
    vc.view.frame = NSMakeRect(0, 0, 640, 760);
    [vc.view layoutSubtreeIfNeeded];
    [vc layoutWebPlayback];
    std::printf("  (1180 h=%.1f → 640 h=%.1f, x=%.1f w=%.1f)\n", oneLine, row.frame.size.height,
                row.frame.origin.x, row.frame.size.width);
    Ck(row.frame.size.height > oneLine + 6.0,
       "窄宽时行高 > 单行（flex-wrap 换行，不是裁掉/溢出）",
       [NSString stringWithFormat:@"one=%.1f narrow=%.1f", oneLine, row.frame.size.height]);

    // 同一坐标系（#npMeta 内）两两不相交；间距至少 6（水平同行为 6，竖向行间为 6）。
    NSMutableArray<NSButton *> *vis = [NSMutableArray array];
    for (NSString *ident in @[ @"npMeta.year", @"npMeta.genre", @"npMeta.albumArtist", @"npMeta.enriched",
                               @"npEqChip", @"npIrChip", @"npCastBtn", @"npAddSq" ]) {
        NSButton *b = (NSButton *)FindById(row, ident);
        if (b && !b.hidden) [vis addObject:b];
    }
    Ck(vis.count == 8, "8 个芯片都可见", [NSString stringWithFormat:@"n=%lu", (unsigned long)vis.count]);
    BOOL overlap = NO, gapOk = YES;
    for (NSUInteger i = 0; i < vis.count; i++) {
        for (NSUInteger j = i + 1; j < vis.count; j++) {
            NSRect a = vis[i].frame, b = vis[j].frame;
            if (RectOverlap(a, b)) {
                overlap = YES;
                std::printf("  overlap: %s %s\n", vis[i].identifier.UTF8String, vis[j].identifier.UTF8String);
            }
            // 同一行：右边缘到左边缘 >= 6 - 0.5；不同行：上下间隔 >= 6 - 0.5。
            BOOL sameLine = fabs(NSMidY(a) - NSMidY(b)) < 1.0;
            if (sameLine) {
                CGFloat g = MAX(NSMinX(b) - NSMaxX(a), NSMinX(a) - NSMaxX(b));
                if (g < 5.5) gapOk = NO;
            } else {
                CGFloat g = MAX(NSMinY(b) - NSMaxY(a), NSMinY(a) - NSMaxY(b));
                if (g < 5.5) gapOk = NO;
            }
        }
    }
    Ck(!overlap, "换行后芯片两两不相交（pairwise intersection = 0）", @"有芯片重叠");
    Ck(gapOk, "换行后间距不塌缩（web gap:6 横竖同值）", @"间距小于 6");

    // 不压标题/副标题；旧的按钮行（隐藏的对比/作品）推到行底之下。
    NSView *title = FindById(vc.view, @"npTitle");
    NSView *sub = FindById(vc.view, @"npSub");
    Ck(title && sub && NSMinY(row.frame) >= NSMaxY(sub.frame) + 9.5,
       "#npMeta 不压标题/副标题（web .npmline margin-top:10）",
       [NSString stringWithFormat:@"rowY=%.1f subMaxY=%.1f", NSMinY(row.frame), NSMaxY(sub.frame)]);
    NSButton *cmpBtn = (NSButton *)FindById(vc.view, @"npCompare");
    NSButton *worksBtn = (NSButton *)FindById(vc.view, @"np.works");
    Ck(cmpBtn && worksBtn && NSMinY(cmpBtn.frame) > NSMaxY(row.frame) + 5.5 &&
       NSMinY(worksBtn.frame) > NSMaxY(row.frame) + 5.5,
       "按钮行 y 在 #npMeta 行底之下（不再是固定 infoY+113）",
       [NSString stringWithFormat:@"rowMaxY=%.1f btnY=%.1f", NSMaxY(row.frame), NSMinY(cmpBtn.frame)]);
    // 也不压下面三栏面板。
    NSView *anal = FindById(vc.view, @"npAnal");
    NSView *rail = FindById(vc.view, @"npRail");
    Ck(anal && rail && NSMaxY(row.frame) < NSMinY(anal.frame) + 0.5 &&
       NSMaxY(row.frame) < NSMinY(rail.frame) + 0.5,
       "换行后的 #npMeta 不压音频分析/AI 整理面板",
       [NSString stringWithFormat:@"rowMaxY=%.1f panelY=%.1f", NSMaxY(row.frame),
        anal ? NSMinY(anal.frame) : -1.0]);

    // 宽帧换回 1180 再确认回到单行（同一实例反复布局）。
    vc.view.frame = wideFrame.size.width > 200 ? NSMakeRect(0, 0, 1180, 760) : NSMakeRect(0, 0, 1180, 760);
    [vc.view layoutSubtreeIfNeeded];
    [vc layoutWebPlayback];
    Ck(fabs(row.frame.size.height - oneLine) < 1.0, "回到 1180px 后行高收回单行",
       [NSString stringWithFormat:@"h=%.1f", row.frame.size.height]);
}

/// 4) 与审计⑤a同源契约：没有任何芯片数据时整行隐藏（不摆空壳）。
static void ScenarioNoDataHidesRow(void) {
    std::printf("--- 场景4：无 meta/无 settings/无播放状态 → #npMeta 隐藏 ---\n");
    RLPNowPlayingViewController *vc = NewVC(1180);
    NSView *row = FindById(vc.view, @"npMeta");
    NSButton *eq = (NSButton *)FindById(row, @"npEqChip");
    [vc renderMetaChipsFromMeta:@{ @"meta": @{ @"enriched": @NO } }];
    [vc layoutWebPlayback];
    Ck(row && row.hidden, "无任何芯片数据时 #npMeta 隐藏（不写「暂无资料」占位）", @"行被显示");
    Ck(eq && eq.hidden, "没有 kv.eq 时 EQ 芯片隐藏", @"EQ 芯片空壳");
    NSButton *cast = (NSButton *)FindById(row, @"npCastBtn");
    Ck(cast && cast.hidden, "还没有播放状态快照时投放芯片隐藏（无对象不摆空壳）",
       @"投放芯片空壳");
}

#pragma mark - main

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        g_urls = [NSMutableArray array];
        ObserveAll();
        [RLPTheme setThemeName:@"light"];
        [RLPTheme setUiStyle:@"apple"];
        std::printf("=== test_native_npmeta_chips（#npMeta 逐值对齐 · 离屏 · 不出声 · 零真实请求）===\n");
        std::printf("--- 基准: ui_page.h:824/1096-1097 与 ui_script.h:4237-4254,12755-12765,8918-8927,13516 ---\n");
        std::printf("--- 基准: tools/native_ui/RLPNowPlayingViewController.mm 旧实现 npMeta 行 ---\n");

        ScenarioBadgesAndChipsAt1180();
        ScenarioEnrichedFalseKeepsEq();
        ScenarioWrappingAtNarrowWidth();
        ScenarioNoDataHidesRow();

        std::printf("结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
