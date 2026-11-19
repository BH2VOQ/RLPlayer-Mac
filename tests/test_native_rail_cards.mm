// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_rail_cards.mm — 「AI 整理」栏三张卡片（歌曲/专辑/艺术家）几何判据（第5项）
//
// ============================ 这条判据在证明什么 ============================
// 用户 2026-11-13 第 5 项：「AI 整理栏三张卡片间距与排版对齐 web」。
// web 的真实几何在 src/net/ui_page.h:742-763：
//   .nprailcard  padding:10px, gap:8px（栏头 → 卡片区）
//   .npchipwrap  flex-column, gap:6px（卡片之间）
//   .npchip      padding:8px 10px 9px, border-radius:11px, gap:2px
//   .npchip-top  gap:7px；.dot 5px；name 11.5px/700；.npchip-st 9.5px
//   .npchip-p1   11.5px；.npchip-p2 10.5px；line-height:1.45
//   .nprailcap   9.5px, letter-spacing:1.5px
//
// 为什么不能只断言"调了哪些方法"：旧实现是 NSButton + attributedTitle（一行里塞
// 「歌曲\n值\n风格」），AppKit 把多行标题画在卡片**左下角**，卡片上半部全空 ——
// 这正是用户在音频分析卡上也报过的同一个病（d717ef0 修的是左栏）。
// 所以判据量的是**真实视图树里的几何**：子视图相对卡片的 inset、卡片之间的 gap、
// 栏头与首卡的 gap、字体字号与行距、栏头字距。
//
// 红→绿纪律：本文件先对旧码跑（旧码没有 dot/name/status/p1/p2 子视图、
// 卡片 gap=8、栏头 gap=11、栏头无字距）⟹ 必须红；改完再跑必须绿。
// 证据：evidence/native-item5-red-20261113.log、native-item5-green-20261113.log
//
// ============================ 铁律②：绝不出声 ============================
// 不启动核心、不碰音频设备；RLPCoreClient 用桩（只记录，不发请求）。
// 不开窗口上屏：只构造视图树 + layout（与 --audit 的离屏路径同一条）。
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "RLPNowPlayingViewController.h"
#import "RLPCoreClient.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

#include <cstdio>
#include <cmath>

static int g_fail = 0, g_pass = 0;

/// 每条几何断言都打印 web/native/差值，交付报告的三列表格直接来自这里。
static void Geo(const char *what, double web, double native_, double tol) {
    const double d = native_ - web;
    const BOOL ok = std::fabs(d) <= tol;
    if (ok) { std::printf("  [PASS] %-26s web=%6.2f native=%6.2f diff=%+6.2f (tol %.1f)\n",
                          what, web, native_, d, tol); ++g_pass; }
    else { std::printf("  [FAIL] %-26s web=%6.2f native=%6.2f diff=%+6.2f (tol %.1f)\n",
                       what, web, native_, d, tol); ++g_fail; }
}
static void Ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++g_fail; }
}

#pragma mark - 桩客户端（不发任何请求）

#pragma mark clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RLPCoreClient
+ (instancetype)shared { static RLPCoreClient *c; if (!c) c = [self new]; return c; }
- (BOOL)started { return NO; }
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done { if (done) done(@{ @"ok": @NO }); }
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done { if (done) done(nil); }
-(void)postJSON:(NSString*)p body:(NSString*)b completion:(RLPJSONCompletion)d { if (d) d(@{@"ok":@NO}); }
@end
#pragma mark clang diagnostic pop

/// 测试专用入口（生产代码里都是私有的；用 category 声明避免改生产头文件）。
@interface RLPNowPlayingViewController (RailTest)
- (void)renderRailMetadata;
- (void)layoutWebPlayback;
@end

static NSView *FindById(NSView *root, NSString *ident) {
    if (!root) return nil;
    if ([root.identifier isEqualToString:ident]) return root;
    for (NSView *s in root.subviews) {
        NSView *r = FindById(s, ident);
        if (r) return r;
    }
    return nil;
}
static NSView *FindByIdIn(NSView *root, NSString *ident) { return FindById(root, ident); }

/// 找 railPanel 的直接子视图里所有卡片（identifier 前缀 npChip.），按屏幕从上到下排。
static NSArray<NSView *> *RailCards(NSView *rail, NSMutableArray<NSView *> *out) {
    // web `.npchip` 位于 `.npchipwrap` 里（不是 railcard 的直接子视图）：
    // 递归找，但排序仍按同一 wrap 内的 frame.y（所有卡片同一父视图）。
    __block void (^collect)(NSView *);
    __block NSMutableArray<NSView *> *all=[NSMutableArray array];
    collect = ^(NSView *root){
        for (NSView *v in root.subviews) {
            NSString *cid=v.identifier;
            // 卡片 identifier 是 `npChip.歌曲/专辑/艺术家`；卡内子标签是 `npChip.dot/name/st/p1/p2`。
            BOOL isChild=[cid isEqualToString:@"npChip.dot"]||[cid isEqualToString:@"npChip.name"]||
                         [cid isEqualToString:@"npChip.st"]||[cid isEqualToString:@"npChip.p1"]||
                         [cid isEqualToString:@"npChip.p2"];
            if ([cid hasPrefix:@"npChip."] && !isChild) [all addObject:v];
            collect(v);
        }
    };
    collect(rail);
    [out addObjectsFromArray:all];
    [out sortUsingComparator:^NSComparisonResult(NSView *a, NSView *b) {
        if (a.frame.origin.y > b.frame.origin.y) return NSOrderedAscending;
        if (a.frame.origin.y < b.frame.origin.y) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return out;
}

static double LayerRadius(NSView *v) {
    return v.layer ? (double)v.layer.cornerRadius : 0.0;
}
/// 属性字符串的字距（取第一个字符）。
static double KernOf(NSTextField *tf) {
    NSAttributedString *as = tf.attributedStringValue;
    if (!as || as.length == 0) return 0.0;
    id k = [as attribute:NSKernAttributeName atIndex:0 effectiveRange:NULL];
    return k ? [k doubleValue] : 0.0;
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        std::printf("=== test_native_rail_cards（第5项 · 离屏几何 · 不出声）===\n");
        std::printf("--- web 基准: ui_page.h:742-763（.nprailcard/.npchipwrap/.npchip）---\n");

        // 测试环境里面板不能被用户上一次的「隐藏」偏好挡住。
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"RLPNPRailHidden"];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"RLPNPAnalysisHidden"];

        RLPNowPlayingViewController *vc = [RLPNowPlayingViewController new];
        NSView *v = vc.view;                       // loadView → buildContent
        v.frame = NSMakeRect(0, 0, 1400, 900);
        [vc setValue:@{
            @"title": @"Track X", @"album": @"Album Y",
            @"artist": @"Artist Z", @"genre": @"Rock"
        } forKey:@"trackMetadata"];
        [vc performSelector:@selector(renderRailMetadata)];
        [v layoutSubtreeIfNeeded];
        [vc performSelector:@selector(layoutWebPlayback)];
        [v layoutSubtreeIfNeeded];

        NSView *rail = FindById(v, @"npRail");
        Ck(rail != nil, "找得到 AI 整理栏 #npRail", @"identifier npRail 缺失");
        if (!rail) { std::printf("结果：FAIL（拦未构建）\n"); return 1; }
        Ck(!rail.hidden, "AI 整理栏在测试里可见（否则量到 0 是假红）", @"rail.hidden=YES");

        NSMutableArray<NSView *> *cards = [NSMutableArray array];
        RailCards(rail, cards);
        // 1.1.7.55：右栏新增第 4 张「作品」卡（web npDataTargets 的 work tab），
        // 只在古典曲目显示。这里的 meta 是 Rock ⟹ 结构 4 张、可见 3 张。
        Ck(cards.count == 4, "四张卡片槽（歌曲/专辑/艺术家/作品）",
           [NSString stringWithFormat:@"cards=%lu", (unsigned long)cards.count]);
        NSMutableArray<NSView *> *vis = [NSMutableArray array];
        for (NSView *c in cards) if (!c.hidden) [vis addObject:c];
        Ck(vis.count == 3, "非古典曲目可见 3 张（作品卡隐藏）",
           [NSString stringWithFormat:@"visible=%lu", (unsigned long)vis.count]);
        if (vis.count != 3) { std::printf("结果：FAIL（可见卡片数不足）\n"); return 1; }
        for (NSView *c in cards) std::printf("  [dbg] %s frame=%s hidden=%d\n",
            c.identifier.UTF8String, NSStringFromRect(c.frame).UTF8String, (int)c.hidden);
        NSView *chips4 = nil;
        for (NSView *c in cards) if ([c.identifier isEqualToString:@"npChip.作品"]) chips4 = c;
        Ck(chips4 != nil && (NSWidth(chips4.frame) < 1 || NSHeight(chips4.frame) < 1),
           "隐藏的作品卡不占排版空间（frame 归零，不留缝）",
           chips4 ? NSStringFromRect(chips4.frame) : @"缺 npChip.作品");

        // ---- 栏的整体左右内边距（web .nprailcard padding:10px）----
        // 卡片现在在 `.npchipwrap` 里（独立滚动区），frame 是 wrap 局部坐标 ⟹ 一律转到 rail 坐标再量。
        #define RAILRECT(v) [(v) convertRect:(v).bounds toView:rail]
                // web 11 = padding:10 + border:1（border-box）—— 见 kRailHeadPadX 的注释。
Geo("rail.padX.left", 11, NSMinX(RAILRECT(vis[0])), 2);
        // web 实测：**溢出时**卡右缘距面板右 = padding 10 + border 1 + 滚动条占位 11 = 22；
        // 不溢出时不占位 ⟹ 10（原生无 1px 边框，故溢出情形为 21）。
        // 1.1.7.75 起占位随**实际溢出**决定（旧码无条件占位，短列表也空一条 11pt 槽）；
        // 因此这里按 contentHeight 判定期望值，并对两者都保留覆盖（旧码在"不溢出"情形会失败）。
        id kdWrap = [vc valueForKey:@"railChipWrap"];
        const double kdContent = kdWrap ? [[kdWrap valueForKey:@"contentHeight"] doubleValue] : -1.0;
        const BOOL kdOverflow = kdWrap && (kdContent > [kdWrap bounds].size.height + 0.5);
        const CGFloat kdRightPad = kdOverflow ? 22.0 : 11.0;   // web 11 + 滚动条 11
        const CGFloat kdCardW = rail.bounds.size.width - 22.0 - (kdOverflow ? 11.0 : 0.0);   // 左右各 11
        Geo("rail.padX.right", kdRightPad, rail.bounds.size.width - NSMaxX(RAILRECT(vis[0])), 2);
        // 卡宽 = railW - 左右内边距 20 - (溢出 ? 滚动条占位 11 : 0)。
        Geo("rail.card.width", kdCardW, NSWidth(RAILRECT(vis[0])), 2);

        // ---- 卡片间距（web .npchipwrap gap:6px）----
        for (NSUInteger i = 0; i + 1 < vis.count; ++i)
            Geo("chip.gap", 6, NSMinY(RAILRECT(vis[i])) - NSMaxY(RAILRECT(vis[i + 1])), 2);

        // ---- 栏头（标题 + 简略/详细）与首卡间距（web .nprailcard gap:8px）----
        NSTextField *cap = (NSTextField *)FindById(rail, @"npRailCap");
        if (!cap) {   // 旧码没有 identifier：按文案兜底，保证红/绿两边都能量到同一元素
            for (NSView *s in rail.subviews)
                if ([s isKindOfClass:[NSTextField class]] &&
                    [((NSTextField *)s).stringValue isEqualToString:RLPTr(@"AI 整理")]) cap = (NSTextField *)s;
        }
        NSView *seg = FindById(rail, @"npRailSeg");
        Ck(cap != nil, "栏头标题存在", @"找不到「AI 整理」标题");
        Ck(seg != nil, "栏头简略/详细分段存在", @"npRailSeg 缺失");
        if (cap && seg) {
            const double headBottom = MIN(NSMinY(cap.frame), NSMinY(seg.frame));
            Geo("head.gapToFirstCard", 8, headBottom - NSMaxY(RAILRECT(vis[0])), 2);
            Geo("rail.padY.top", 10, rail.bounds.size.height - NSMaxY(seg.frame), 2);
            Geo("railcap.kern", 1.5, KernOf(cap), 0.2);
            Ck(cap.font.pointSize >= 9.0 && cap.font.pointSize <= 10.5,
               "栏头字号 9.5（web .nprailcap）",
               [NSString stringWithFormat:@"%.1f", cap.font.pointSize]);
        }

        // ---- 卡片内边距 / 行距 / 字体（web .npchip）----
        for (NSUInteger i = 0; i < vis.count; ++i) {
            NSView *chip = vis[i];
            NSView *dot = FindByIdIn(chip, @"npChip.dot");
            NSTextField *nm = (NSTextField *)FindByIdIn(chip, @"npChip.name");
            NSTextField *st = (NSTextField *)FindByIdIn(chip, @"npChip.st");
            NSTextField *p1 = (NSTextField *)FindByIdIn(chip, @"npChip.p1");
            NSTextField *p2 = (NSTextField *)FindByIdIn(chip, @"npChip.p2");
            NSString *tag = [NSString stringWithFormat:@"chip%lu", (unsigned long)i];
            Ck(dot && nm && st && p1,
               "卡片内有 dot / name / status / p1 子视图（标题在左上，不是 NSButton 多行标题）",
               [NSString stringWithFormat:@"%@ dot=%d name=%d st=%d p1=%d",
                tag, !!dot, !!nm, !!st, !!p1]);
            Geo("chip.padY.top", 8, chip.bounds.size.height - NSMaxY(nm.frame), 2);
            Geo("chip.padX.left", 10, NSMinX(dot.frame), 2);
            if (nm && dot) Geo("chip.dot.gap", 7, NSMinX(nm.frame) - NSMaxX(dot.frame), 2);
            if (dot) Geo("chip.dot.size", 5, dot.frame.size.width, 2);
            if (st) Geo("chip.padX.right", 10, chip.bounds.size.width - NSMaxX(st.frame), 2);
            if (p1) Geo("chip.rowGap.top", 2, NSMinY(nm.frame) - NSMaxY(p1.frame), 2);
            if (p2) {
                Geo("chip.rowGap.p2", 2, NSMinY(p1.frame) - NSMaxY(p2.frame), 2);
                Geo("chip.padY.bottom", 9, NSMinY(p2.frame), 2);
                Geo("chip.p2.font", 10.5, p2.font.pointSize, 0.5);
            } else {
                Geo("chip.padY.bottom", 9, NSMinY(p1.frame), 2);
            }
            if (nm) Geo("chip.name.font", 11.5, nm.font.pointSize, 0.5);
            if (st) Geo("chip.st.font", 9.5, st.font.pointSize, 0.5);
            if (p1) Geo("chip.p1.font", 11.5, p1.font.pointSize, 0.5);
            Geo("chip.radius", 11, LayerRadius(chip), 2);
        }

        std::printf("结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
