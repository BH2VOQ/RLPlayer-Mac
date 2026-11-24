// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_artist_profile.mm — 艺术家资料页排版判据（A1–A7）
//
// ============================ 这条判据在证明什么 ============================
// 用户 2026-11-21 实测：「艺术家资料页设计不合格，排版混乱，不够简洁。主要是资料部分，
// 甚至不如 web 版，要做到图二的那个效果。」
//
// 旧实现的资料区只是把播放页右侧那个 RLPKnowledgeView（自带标题/复制/重新整理/滚动条
// 的抽屉）整块塞进页面，固定 215pt 高 —— 既不是 web 的卡片层次，也没有字段网格。
//
// 判据量的是**结构与几何**，不是"看起来顺眼"：
//   A1 hero 齐全：eyebrow / 大标题 / 副标题位 / 三个按钮，且 eyebrow 在标题之上、按钮在标题之下；
//   A2 三张卡片各自存在且**纵向不重叠**、宽度一致（web 的 sec-card 是等宽的纵向堆叠）；
//   A3 字段网格按 web 的 person 顺序排列（简介/国籍/活跃年代/风格/代表作品/厂牌/合作），
//      且**空值标签不出现**（AI 不知道的标签根本不该占位 —— 后端契约的硬纪律）；
//   A4 宽字段（简介/专辑介绍/曲目列表/制作人员/歌词赏析/关联/衍生作品/版本说明，或 >46 字）
//      独占整行：其宽度 ≥ 卡片内容宽 - 1；
//   A5 「简介」与「资料来源」两张卡片在网格之外独立存在，且有真实正文/来源行；
//   A6 响应式：窄宿主（674pt）下字段网格降为单列且**不横向溢出**（maxX ≤ 卡片右缘）；
//   A7 无数据时安静：materials 为空且无 AI 摘要 → 不出现任何「未知 / —」占位标签。
//
// 为什么不用截图人眼比对：那不可复跑。这里的每一条都能在离屏 runloop 里量出来，
// 且**先红后绿**（旧实现 A2/A3/A4/A5 全红 —— 旧码根本没有这三张卡片和字段网格）。
//
// 纪律（铁律 1/3/4）：隔离 state/library；核心走桩（backend=null、volume=-120），
// 不打开音频设备、不出声、不联网、不 orderFront 窗口。
#import <AppKit/AppKit.h>
#import "RLPArtistDetailViewController.h"
#import "RLPCoreClient.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>

static int gPass = 0, gFail = 0;
static void Ck(BOOL ok, NSString *what, NSString *detail) {
    if (ok) { ++gPass; std::printf("  [PASS] %s\n", what.UTF8String); }
    else {
        ++gFail;
        std::printf("  [FAIL] %s — %s\n", what.UTF8String, detail.UTF8String ?: "");
    }
}

static void Pump(NSTimeInterval s) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:s];
    while ([until timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
}

static void Collect(NSView *v, NSMutableArray<NSView *> *out) {
    if (!v) return;
    [out addObject:v];
    for (NSView *s in v.subviews) Collect(s, out);
}
static NSView *FindId(NSView *root, NSString *ident) {
    NSMutableArray<NSView *> *all = [NSMutableArray array];
    Collect(root, all);
    for (NSView *v in all) if ([v.identifier isEqualToString:ident]) return v;
    return nil;
}
static NSArray<NSView *> *AllWithPrefix(NSView *root, NSString *prefix) {
    NSMutableArray<NSView *> *all = [NSMutableArray array], *hits = [NSMutableArray array];
    Collect(root, all);
    // 按文档顺序返回（Collect 是前序 DFS）
    for (NSView *v in all) if (v.identifier.length && [v.identifier hasPrefix:prefix]) [hits addObject:v];
    return hits;
}
/// 转成某个容器的坐标系（并要求容器同样翻转，避免上下颠倒）。
static NSRect RectIn(NSView *sub, NSView *container) {
    if (!sub || !container) return NSZeroRect;
    return [sub convertRect:sub.bounds toView:container];
}
static BOOL Visible(NSView *v) {
    if (!v) return NO;
    if (v.isHiddenOrHasHiddenAncestor) return NO;
    if (v.frame.size.width < 1.0 || v.frame.size.height < 1.0) return NO;
    for (NSView *p = v.superview; p; p = p.superview) if (p.hidden) return NO;
    return YES;
}
/// 把控件画进位图，数「与参考色差异明显的像素」= 真正画出来的墨迹量。
///
/// 为什么必须这样量：几何判据（size/frame/identifier 都在）在
/// 「drawRect 覆盖没调 super，标题被抹掉」「layer 背景盖住 cell 画的文字」
/// 这两类缺陷下**全绿**。只有像素能证明"字真的出现在屏幕上"。
/// 把 **host 整块**画进位图，再裁出 target 的矩形，数「与周围底色差异明显」的像素。
///
/// 为什么必须画 host 而不是只画 target：
///   `bitmapImageRepForCachingDisplayInRect:` + `cacheDisplayInRect:` 只画**该视图自己**
///   画的东西，未绘制区域是透明/黑。于是「白色页面上的深色按钮文字」在单独渲染时
///   得到的是「黑底 + 深色字」= 零对比度，判据恒红（本轮实测踩到两次）。
///   渲染 host 后裁剪，按钮就落在它真实的页面底色上，对比度才有意义。
static NSInteger InkPixels(NSView *host, NSView *target, NSColor *pageBg) {
    if (!host || !target) return 0;
    const NSRect hostBounds = host.bounds;
    if (hostBounds.size.width < 8 || hostBounds.size.height < 8) return 0;
    NSBitmapImageRep *rep = [host bitmapImageRepForCachingDisplayInRect:hostBounds];
    if (!rep) return 0;
    [host cacheDisplayInRect:hostBounds toBitmapImageRep:rep];

    // target 在 host 坐标系里的矩形 → 位图坐标（位图与 host.bounds 同尺寸，左上为原点）。
    NSRect r = [target convertRect:target.bounds toView:host];
    const BOOL hostFlipped = host.isFlipped;
    const CGFloat scaleX = rep.pixelsWide / MAX(1.0, hostBounds.size.width);
    const CGFloat scaleY = rep.pixelsHigh / MAX(1.0, hostBounds.size.height);
    CGFloat top = hostFlipped ? NSMinY(r) : (hostBounds.size.height - NSMaxY(r));
    NSInteger x0 = (NSInteger)lround((NSMinX(r) + 3.0) * scaleX);
    NSInteger y0 = (NSInteger)lround((top + 3.0) * scaleY);
    NSInteger x1 = (NSInteger)lround((NSMaxX(r) - 3.0) * scaleX);
    NSInteger y1 = (NSInteger)lround((top + r.size.height - 3.0) * scaleY);
    x0 = MAX(0, x0); y0 = MAX(0, y0);
    x1 = MIN(rep.pixelsWide, x1); y1 = MIN(rep.pixelsHigh, y1);
    if (x1 - x0 < 4 || y1 - y0 < 4) return 0;

    // 以页面底色为基准，数「与底色亮度差 > 0.15」的像素 = 笔画。
    // 主题无关：深色主题下文字比底色亮，浅色主题下更暗，都用绝对值比较。
    NSColor *bg = [(pageBg ?: [NSColor whiteColor]) colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    const double bgLum = 0.299 * bg.redComponent + 0.587 * bg.greenComponent + 0.114 * bg.blueComponent;
    NSInteger ink = 0;
    for (NSInteger y = y0; y < y1; ++y) {
        for (NSInteger x = x0; x < x1; ++x) {
            NSColor *c = [[rep colorAtX:x y:y] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            if (!c) continue;
            const double lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent;
            if (fabs(lum - bgLum) > 0.15) ++ink;
        }
    }
    return ink;
}

/// 与 InkPixels 同法渲染 host 再裁剪，但按**目标前景色**判定：
/// 徽章的药丸底色本身与页面底色就不同，用页面底色当基准会把粉色底整片算成墨迹，
/// 于是「文字被底色盖住」这种缺陷也能通过（实测踩到）。
/// 这里先统计块内颜色直方图，取占比最大的两种颜色；只要存在**明显更接近 refColor**
/// 的一批像素，就说明文字画出来了。
static NSInteger InkPixelsAgainst(NSView *host, NSView *target, NSColor *refColor) {
    if (!host || !target) return 0;
    const NSRect hostBounds = host.bounds;
    if (hostBounds.size.width < 8 || hostBounds.size.height < 8) return 0;
    NSBitmapImageRep *rep = [host bitmapImageRepForCachingDisplayInRect:hostBounds];
    if (!rep) return 0;
    [host cacheDisplayInRect:hostBounds toBitmapImageRep:rep];
    NSRect r = [target convertRect:target.bounds toView:host];
    const BOOL hostFlipped = host.isFlipped;
    const CGFloat sx = rep.pixelsWide / MAX(1.0, hostBounds.size.width);
    const CGFloat sy = rep.pixelsHigh / MAX(1.0, hostBounds.size.height);
    CGFloat top = hostFlipped ? NSMinY(r) : (hostBounds.size.height - NSMaxY(r));
    NSInteger x0 = MAX(0, (NSInteger)lround((NSMinX(r) + 4.0) * sx));
    NSInteger y0 = MAX(0, (NSInteger)lround((top + 4.0) * sy));
    NSInteger x1 = MIN(rep.pixelsWide, (NSInteger)lround((NSMaxX(r) - 4.0) * sx));
    NSInteger y1 = MIN(rep.pixelsHigh, (NSInteger)lround((top + r.size.height - 4.0) * sy));
    if (x1 - x0 < 4 || y1 - y0 < 4) return 0;
    NSColor *ref = [(refColor ?: [NSColor labelColor]) colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!ref) return 0;
    NSInteger hit = 0;
    for (NSInteger y = y0; y < y1; ++y) {
        for (NSInteger x = x0; x < x1; ++x) {
            NSColor *c = [[rep colorAtX:x y:y] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            if (!c) continue;
            const double d = fabs(c.redComponent - ref.redComponent) +
                             fabs(c.greenComponent - ref.greenComponent) +
                             fabs(c.blueComponent - ref.blueComponent);
            if (d < 0.28) ++hit;
        }
    }
    return hit;
}

/// 量控件内部「内容墨迹（跳过 2pt 边框）」左右留白是否对称（防左挤右空）。
static BOOL InkMarginsBalanced(NSView *host, NSView *target, NSColor *refOrBg, BOOL againstRef,
                               CGFloat *outLeftPt, CGFloat *outRightPt) {
    if (!host || !target) return NO;
    const NSRect hostBounds = host.bounds;
    if (hostBounds.size.width < 8 || hostBounds.size.height < 8) return NO;
    NSBitmapImageRep *rep = [host bitmapImageRepForCachingDisplayInRect:hostBounds];
    if (!rep) return NO;
    [host cacheDisplayInRect:hostBounds toBitmapImageRep:rep];
    NSRect r = [target convertRect:target.bounds toView:host];
    const BOOL hostFlipped = host.isFlipped;
    const CGFloat sx = rep.pixelsWide / MAX(1.0, hostBounds.size.width);
    const CGFloat sy = rep.pixelsHigh / MAX(1.0, hostBounds.size.height);
    CGFloat top = hostFlipped ? NSMinY(r) : (hostBounds.size.height - NSMaxY(r));
    NSInteger x0 = MAX(0, (NSInteger)lround((NSMinX(r) + 2.0) * sx));
    NSInteger y0 = MAX(0, (NSInteger)lround((top + 3.0) * sy));
    NSInteger x1 = MIN(rep.pixelsWide, (NSInteger)lround((NSMaxX(r) - 2.0) * sx));
    NSInteger y1 = MIN(rep.pixelsHigh, (NSInteger)lround((top + r.size.height - 3.0) * sy));
    if (x1 - x0 < 6 || y1 - y0 < 4) return NO;

    NSColor *ref = [(refOrBg ?: [NSColor whiteColor]) colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    const double refLum = 0.299 * ref.redComponent + 0.587 * ref.greenComponent + 0.114 * ref.blueComponent;
    NSInteger minX = NSIntegerMax, maxX = -1;
    for (NSInteger y = y0; y < y1; ++y) {
        for (NSInteger x = x0; x < x1; ++x) {
            NSColor *c = [[rep colorAtX:x y:y] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            if (!c) continue;
            BOOL isInk = NO;
            if (againstRef) {
                const double d = fabs(c.redComponent - ref.redComponent) +
                                 fabs(c.greenComponent - ref.greenComponent) +
                                 fabs(c.blueComponent - ref.blueComponent);
                isInk = (d < 0.28);
            } else {
                const double lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent;
                isInk = (fabs(lum - refLum) > 0.15);
            }
            if (isInk) {
                if (x < minX) minX = x;
                if (x > maxX) maxX = x;
            }
        }
    }
    if (maxX < minX) return NO;
    const CGFloat leftPt = ((CGFloat)minX / sx) - NSMinX(r);
    const CGFloat rightPt = NSMaxX(r) - ((CGFloat)(maxX + 1) / sx);
    if (outLeftPt) *outLeftPt = leftPt;
    if (outRightPt) *outRightPt = rightPt;
    return fabs(leftPt - rightPt) <= 5.5;
}

/// 某标签文字是否出现在视图树里（用于「空值标签不该出现」）。
static BOOL HasText(NSView *root, NSString *text) {
    NSMutableArray<NSView *> *all = [NSMutableArray array];
    Collect(root, all);
    for (NSView *v in all) {
        if (Visible(v) && [v isKindOfClass:[NSTextField class]] &&
            [((NSTextField *)v).stringValue isEqualToString:text]) return YES;
    }
    return NO;
}

#pragma mark - 桩核心（只回答 artist 页真正会问的端点；不启动核心、不联网、不出声）

static NSArray<NSDictionary *> *g_materials = nil;
static NSDictionary *g_summaryFields = nil;
static NSArray<NSDictionary *> *g_summaryCitations = nil;
static NSArray<NSDictionary *> *g_summarySections = nil;
static BOOL g_summaryOk = YES;
static BOOL g_pendingOnce = NO;
static NSArray<NSDictionary *> *g_albums = nil;

@implementation RLPCoreClient
+ (instancetype)shared { static RLPCoreClient *c; if (!c) c = [self new]; return c; }
- (BOOL)started { return YES; }
- (BOOL)startEmbedded { return YES; }
- (void)shutdown {}
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    if (!done) return;
    NSDictionary *reply = nil;
    if ([path hasPrefix:@"/api/lib/albums"]) {
        reply = @{ @"ok": @YES, @"albums": g_albums ?: @[] };
    } else if ([path hasPrefix:@"/api/entity/knowledge"]) {
        if (g_pendingOnce) {
            g_pendingOnce = NO;
            reply = @{ @"ok": @YES, @"pending": @YES, @"retryAfterMs": @150 };
        } else {
            reply = @{ @"ok": @YES, @"pending": @NO,
                       @"entity": @{ @"id": @"p:artist", @"kind": @"person", @"name": @"结束バンド" },
                       @"materials": g_materials ?: @[],
                       @"from_cache": @YES, @"offline": @NO, @"errors": @[] };
        }
    } else if ([path hasPrefix:@"/api/entity/summary"]) {
        if (!g_summaryOk) {
            reply = @{ @"ok": @NO };
        } else {
            reply = @{ @"ok": @YES, @"kind": @"person",
                       @"fields": g_summaryFields ?: @{},
                       @"sections": g_summarySections ?: @[],
                       @"citations": g_summaryCitations ?: @[] };
        }
    } else if ([path hasPrefix:@"/api/playmode"]) {
        reply = @{ @"ok": @YES, @"mode": @0 };
    } else {
        reply = @{ @"ok": @YES };
    }
    // 同步回调即可：被测页面只关心"数据到了之后长什么样"。
    done(reply);
}
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    if (done) done(@{ @"ok": @YES });
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done {
    if (done) done(nil);   // 头像/封面取不到 → 页面回落首字母占位
}
- (NSDictionary *)jsonWithMethod:(NSString *)m path:(NSString *)p body:(NSString *)b { return @{ @"ok": @YES }; }
- (NSData *)dataWithMethod:(NSString *)m path:(NSString *)p body:(NSString *)b
               contentType:(NSString **)ct { return nil; }
- (void)postData:(NSString *)p body:(NSData *)b contentType:(NSString *)c
      completion:(RLPJSONCompletion)done { if (done) done(@{ @"ok": @YES }); }
@end

#pragma mark - 夹具

// 与 web 版图二同形的一份资料：有简介 / 风格 / 代表作品 / 国籍，缺「活跃年代」「厂牌」「合作」。
// 缺的那三个就是 A3 里"不许出现空值标签"的反证。
static NSArray<NSDictionary *> *FixtureMaterials(void) {
    return @[
        @{ @"source": @"moegirl", @"kind": @"biography", @"title": @"结束乐队",
           @"text": @"结束乐队（日文：結束バンド，英文：Kessoku Band）是《孤独摇滚！》及其衍生作品中"
                    @"登场的一个架空的乐队，同时在三次元中成员声优也以结束乐队名义参与动画衍生的演唱会和其他音乐会。",
           @"url": @"https://zh.moegirl.org.cn/结束乐队", @"fetched_at": @1762732800, @"lang": @"zh" },
        @{ @"source": @"wikipedia", @"kind": @"genre", @"title": @"风格",
           @"text": @"摇滚 · 流行摇滚", @"url": @"https://zh.wikipedia.org/wiki/結束バンド",
           @"fetched_at": @1762732800, @"lang": @"zh" },
    ];
}

static NSDictionary *FixtureSummaryFields(void) {
    return @{
        @"风格": @"摇滚",
        @"代表作品": @"专辑《结束バンド》(2022年12月)",
        @"国籍": @"日本",
    };
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [RLPTheme setThemeName:@"light"];
        std::printf("=== test_native_artist_profile（艺术家资料页排版 · 离屏 · 不出声）===\n");

        NSString *rootDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"rlp-artist-%d", (int)getpid()]];
        NSString *state = [rootDir stringByAppendingPathComponent:@"state"];
        NSString *lib = [rootDir stringByAppendingPathComponent:@"lib"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:lib withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("RLPLAYER_STATE_DIR", state.fileSystemRepresentation, 1);
        setenv("RLPLAYER_LIBRARY_DIR", lib.fileSystemRepresentation, 1);
        g_materials = FixtureMaterials();
        g_summaryFields = FixtureSummaryFields();

        RLPArtistDetailViewController *vc =
            [[RLPArtistDetailViewController alloc] initWithArtistName:@"结束バンド"];
        NSView *v = vc.view;
        // 必须放进一个真实 NSWindow：NSButton/NSTextField 的**文字由 cell 绘制**，
        // 而离屏 cacheDisplay 时没有 window 的视图不会走完整绘制路径 ⟹
        // 按钮文字量出来恒为 0（本轮实测踩到：单测里空药丸也数不出墨迹，
        // 但把它放进 window 后立刻正常）。窗口不 orderFront，仍然完全离屏。
        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 954, 700)
                                                    styleMask:NSWindowStyleMaskBorderless
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
        win.releasedWhenClosed = NO;
        win.contentView = v;
        v.frame = NSMakeRect(0, 0, 954, 700);
        [v layoutSubtreeIfNeeded];
        [vc activate];
        Pump(1.2);                        // 让 knowledge / summary 的异步回包落地
        [v layoutSubtreeIfNeeded];

        // ---- A1 hero 结构与相对位置 ----
        NSView *eyebrow = FindId(v, @"artist.hero.eyebrow");
        NSView *name = FindId(v, @"artist.hero.name");
        NSView *sub = FindId(v, @"artist.hero.sub");
        NSView *btnAlbums = FindId(v, @"artist.hero.btn.albums");
        NSView *btnRefresh = FindId(v, @"artist.hero.btn.refresh");
        NSView *btnBack = FindId(v, @"artist.hero.btn.back");
        Ck(Visible(eyebrow) && Visible(name) && Visible(btnAlbums) &&
           Visible(btnRefresh) && Visible(btnBack),
           @"A1a hero 齐全：eyebrow / 大标题 / 查看专辑 / 刷新资料 / 返回列表",
           [NSString stringWithFormat:@"eyebrow=%d name=%d albums=%d refresh=%d back=%d",
            Visible(eyebrow), Visible(name), Visible(btnAlbums), Visible(btnRefresh), Visible(btnBack)]);
        if (Visible(eyebrow) && Visible(name) && Visible(btnAlbums)) {
            const NSRect rE = RectIn(eyebrow, v), rN = RectIn(name, v), rB = RectIn(btnAlbums, v);
            // v 非翻转：y 大 = 更靠上。eyebrow 在标题之上、按钮在标题之下。
            Ck(NSMinY(rE) >= NSMaxY(rN) - 1.0, @"A1b eyebrow 在大标题之上",
               [NSString stringWithFormat:@"eyebrow=%@@%.1f name=%@@%.1f",
                @"y", NSMinY(rE), @"y", NSMinY(rN)]);
            Ck(NSMaxY(rB) <= NSMinY(rN) + 1.0, @"A1c 三个按钮在大标题之下",
               [NSString stringWithFormat:@"btnMaxY=%.1f nameMinY=%.1f", NSMaxY(rB), NSMinY(rN)]);
        }
        if (Visible(sub)) {
            NSString *s = [sub isKindOfClass:[NSTextField class]] ? ((NSTextField *)sub).stringValue : @"";
            Ck(s.length == 0 || [s containsString:@"取回"] || [s containsString:@"缓存"],
               @"A1d 副标题只放「缓存/资料 · 日期 取回」，不放「资料暂缺」这类解释",
               s ?: @"nil");
            Ck(![s containsString:@"资料暂缺"] && ![s containsString:@"权威"],
               @"A1e 副标题不出现「资料暂缺 / 权威」字样（用户明确要求删掉的说法）", s ?: @"nil");
            Ck(![s containsString:@"· ·"],
               @"A1f 副标题「缓存 · 日期 取回」不能出现双中点（缓存 · · 日期）", s ?: @"nil");
        }
        Ck(vc.subtitleLabel.hidden,
           @"A1g 艺术家详情页隐藏 RLPPageViewController 浮动副标题（避免遮挡顶栏返回行）",
           vc.subtitleLabel.stringValue ?: @"nil");

        // ---- A2 三张卡片：存在、等宽、纵向不重叠 ----
        NSView *cardSummary = FindId(v, @"artist.card.summary");
        NSView *cardBio = FindId(v, @"artist.card.bio");
        NSView *cardSources = FindId(v, @"artist.card.sources");
        Ck(Visible(cardSummary) && Visible(cardBio) && Visible(cardSources),
           @"A2a AI 整理 / 简介 / 资料来源 三张卡片都在",
           [NSString stringWithFormat:@"summary=%d bio=%d sources=%d",
            Visible(cardSummary), Visible(cardBio), Visible(cardSources)]);
        if (Visible(cardSummary) && Visible(cardBio) && Visible(cardSources)) {
            const NSRect rS = RectIn(cardSummary, v), rB = RectIn(cardBio, v), rSrc = RectIn(cardSources, v);
            const BOOL sameWidth = fabs(NSWidth(rS) - NSWidth(rB)) <= 2.0 &&
                                   fabs(NSWidth(rB) - NSWidth(rSrc)) <= 2.0;
            Ck(sameWidth, @"A2b 三张卡片等宽（web sec-card 是等宽纵向堆叠）",
               [NSString stringWithFormat:@"w=%.1f/%.1f/%.1f", NSWidth(rS), NSWidth(rB), NSWidth(rSrc)]);
            // 非翻转容器里：上面那张的最大 y 要 <= 下面那张的最小 y（允许 1pt 误差）。
            const BOOL noOverlap = NSMinY(rS) >= NSMaxY(rB) - 1.0 && NSMinY(rB) >= NSMaxY(rSrc) - 1.0;
            Ck(noOverlap, @"A2c 三张卡片纵向依次排列且互不重叠",
               [NSString stringWithFormat:@"summary=%.1f..%.1f bio=%.1f..%.1f src=%.1f..%.1f",
                NSMinY(rS), NSMaxY(rS), NSMinY(rB), NSMaxY(rB), NSMinY(rSrc), NSMaxY(rSrc)]);
        }

        // ---- A3 字段网格：顺序 + 空值不出现 ----
        NSView *grid = FindId(v, @"artist.summary.grid");
        Ck(Visible(grid), @"A3a 存在字段网格容器 artist.summary.grid", grid ? @"有" : @"缺");
        NSArray<NSString *> *wantOrder = @[ @"简介", @"国籍", @"活跃年代", @"风格", @"代表作品", @"厂牌", @"合作" ];
        if (Visible(grid)) {
            NSMutableArray<NSString *> *present = [NSMutableArray array];
            for (NSString *label in wantOrder) {
                NSView *row = FindId(grid, [@"artist.summary.field." stringByAppendingString:label]);
                if (Visible(row)) [present addObject:label];
            }
            Ck([present containsObject:@"风格"] && [present containsObject:@"代表作品"],
               @"A3b 后端给了的标签都渲染出来了（风格 / 代表作品）",
               [present componentsJoinedByString:@","]);
            // 顺序按 EF_ORDER 的 person 序：present 必须是 wantOrder 的子序列。
            NSUInteger last = NSNotFound;
            BOOL ordered = YES;
            for (NSString *label in present) {
                const NSUInteger idx = [wantOrder indexOfObject:label];
                if (idx == NSNotFound) continue;
                if (last != NSNotFound && idx < last) { ordered = NO; break; }
                last = idx;
            }
            Ck(ordered, @"A3c 字段顺序遵循 web EF_ORDER.person（简介/国籍/活跃年代/风格/代表作品/厂牌/合作）",
               [present componentsJoinedByString:@","]);
            // 空值标签不出现（夹具里没有「活跃年代」「厂牌」「合作」的值）
            NSMutableArray<NSString *> *phantom = [NSMutableArray array];
            for (NSString *label in @[ @"活跃年代", @"厂牌", @"合作" ]) {
                if (Visible(FindId(grid, [@"artist.summary.field." stringByAppendingString:label])))
                    [phantom addObject:label];
            }
            Ck(phantom.count == 0, @"A3d 后端没给的标签不占位（不许用空值/未知标签冒充有数据）",
               [phantom componentsJoinedByString:@","]);

            v.frame = NSMakeRect(0, 0, 1600, 700);
            [v layoutSubtreeIfNeeded];
            Pump(0.15);
            [v layoutSubtreeIfNeeded];
            NSView *fStyle = FindId(grid, @"artist.summary.field.风格");
            NSView *fWorks = FindId(grid, @"artist.summary.field.代表作品");
            if (Visible(fStyle) && Visible(fWorks)) {
                const NSRect rStyle = RectIn(fStyle, grid);
                const NSRect rWorks = RectIn(fWorks, grid);
                Ck(NSMinX(rStyle) <= 340.0 && NSMinX(rWorks) <= 680.0,
                   @"A3e 宽屏 1600pt 下少字段网格紧凑排布不裂出大空白（col2≤340pt, col3≤680pt）",
                   [NSString stringWithFormat:@"styleX=%.1f worksX=%.1f gridW=%.1f",
                    NSMinX(rStyle), NSMinX(rWorks), NSWidth(grid.bounds)]);
            }
            v.frame = NSMakeRect(0, 0, 954, 700);
            [v layoutSubtreeIfNeeded];
            Pump(0.15);
            [v layoutSubtreeIfNeeded];
        }

        // ---- A4 宽字段独占整行 ----
        if (Visible(grid) && Visible(cardSummary)) {
            NSMutableArray<NSString *> *bad = [NSMutableArray array];
            for (NSString *label in @[ @"简介", @"专辑介绍", @"曲目列表", @"制作人员", @"歌词赏析", @"关联" ]) {
                NSView *row = FindId(grid, [@"artist.summary.field." stringByAppendingString:label]);
                if (!Visible(row)) continue;
                const NSRect r = RectIn(row, grid);
                const CGFloat need = NSWidth(grid.bounds) - 1.0;
                if (NSWidth(r) < need) {
                    [bad addObject:[NSString stringWithFormat:@"%@(w=%.1f need=%.1f)", label, NSWidth(r), need]];
                }
            }
            Ck(bad.count == 0, @"A4 宽字段（简介等长文本）独占整行，不挤在网格的一列里",
               [bad componentsJoinedByString:@","]);
        }

        // ---- A5 简介正文 / 来源行有真实内容 ----
        NSView *bioText = FindId(v, @"artist.bio.text");
        Ck(Visible(bioText), @"A5a 简介卡片里有正文控件 artist.bio.text", bioText ? @"有" : @"缺");
        if (Visible(bioText)) {
            NSString *t = [bioText isKindOfClass:[NSTextField class]] ? ((NSTextField *)bioText).stringValue : @"";
            Ck(t.length > 20 && [t containsString:@"结束乐队"],
               @"A5b 简介正文是知识材料的真实文本（不是占位/空白）",
               [NSString stringWithFormat:@"len=%lu head=%@", (unsigned long)t.length,
                t.length > 30 ? [t substringToIndex:30] : t]);
        }
        NSArray<NSView *> *srcRows = AllWithPrefix(v, @"artist.sources.row.");
        Ck(srcRows.count >= 1, @"A5c 资料来源逐行渲染（每条材料一行）",
           [NSString stringWithFormat:@"rows=%lu", (unsigned long)srcRows.count]);
        NSArray<NSView *> *copyChips = AllWithPrefix(v, @"artist.sources.copy.");
        Ck(copyChips.count >= 1, @"A5d 每条来源带「复制」芯片（复制的是来源 URL）",
           [NSString stringWithFormat:@"chips=%lu", (unsigned long)copyChips.count]);
        NSView *row1 = FindId(v, @"artist.sources.row.1");
        NSView *date1 = row1 ? FindId(row1, @"artist.sources.date") : nil;
        NSView *copy1 = row1 ? FindId(row1, @"artist.sources.copy.1") : nil;
        NSView *open1 = row1 ? FindId(row1, @"artist.sources.open.1") : nil;
        if (Visible(row1) && Visible(date1) && Visible(copy1)) {
            const NSRect dr = RectIn(date1, row1);
            const NSRect cr = RectIn(copy1, row1);
            const CGFloat gapDC = NSMinX(cr) - NSMaxX(dr);
            Ck(!Visible(open1) && gapDC >= 10.0,
               @"A5e 来源行仅保留单个复制链接按钮且日期与按钮间距 ≥10pt",
               [NSString stringWithFormat:@"openVis=%d gap=%.1f", Visible(open1), gapDC]);
            if ([date1 isKindOfClass:[NSTextField class]]) {
                NSTextField *dtf = (NSTextField *)date1;
                const CGFloat needW = ceil([dtf.stringValue sizeWithAttributes:@{
                    NSFontAttributeName: dtf.font ?: [NSFont systemFontOfSize:11.5]
                }].width);
                Ck(NSWidth(dr) >= needW + 6.0,
                   @"A5f 来源日期字段宽裕度足以完整展示日期（不截断尾位数字）",
                   [NSString stringWithFormat:@"dateW=%.1f needW=%.1f str=%@", NSWidth(dr), needW, dtf.stringValue]);
            }
        }

        // ---- A6 窄宿主响应式：不横向溢出 ----
        {
            v.frame = NSMakeRect(0, 0, 674, 700);
            [v layoutSubtreeIfNeeded];
            Pump(0.25);
            [v layoutSubtreeIfNeeded];
            NSMutableArray<NSString *> *overflow = [NSMutableArray array];
            NSArray<NSView *> *cards = @[ cardSummary ?: (id)[NSNull null], cardBio ?: (id)[NSNull null],
                                          cardSources ?: (id)[NSNull null] ];
            for (NSView *card in cards) {
                if (![card isKindOfClass:[NSView class]]) continue;
                const NSRect rc = RectIn(card, v);
                if (NSMaxX(rc) > NSWidth(v.bounds) + 1.0 || NSMinX(rc) < -1.0) {
                    [overflow addObject:[NSString stringWithFormat:@"card x=%.1f..%.1f v.w=%.1f",
                                         NSMinX(rc), NSMaxX(rc), NSWidth(v.bounds)]];
                }
            }
            if (Visible(grid)) {
                for (NSView *row in grid.subviews) {
                    if (!Visible(row)) continue;
                    const NSRect rr = RectIn(row, grid);
                    if (NSMaxX(rr) > NSWidth(grid.bounds) + 1.0) {
                        [overflow addObject:[NSString stringWithFormat:@"%@ maxX=%.1f gridW=%.1f",
                                             row.identifier ?: @"-", NSMaxX(rr), NSWidth(grid.bounds)]];
                        break;
                    }
                }
            }
            Ck(overflow.count == 0, @"A6 窄宿主 674pt 下资料区不横向溢出（卡片与字段都在容器内）",
               [overflow componentsJoinedByString:@" | "]);
            v.frame = NSMakeRect(0, 0, 954, 700);
            [v layoutSubtreeIfNeeded];
            Pump(0.2);
        }

        // ---- A7 无数据时安静：不出现占位标签 ----
        g_materials = @[];
        g_summaryFields = @{};
        g_summaryOk = NO;
        [vc activate];
        Pump(1.0);
        [v layoutSubtreeIfNeeded];
        {
            NSMutableArray<NSString *> *phantoms = [NSMutableArray array];
            for (NSString *bad in @[ @"简介", @"国籍", @"活跃年代", @"风格", @"代表作品", @"厂牌", @"合作" ]) {
                if (Visible(FindId(v, [@"artist.summary.field." stringByAppendingString:bad])))
                    [phantoms addObject:bad];
            }
            Ck(phantoms.count == 0,
               @"A7 后端一个字段都没有时，网格里不得出现任何字段标签占位",
               [phantoms componentsJoinedByString:@","]);
            // 也不许出现「未知」「—」这类冒充值的文本
            Ck(!HasText(v, @"未知") && !HasText(v, @"—"),
               @"A7b 无数据时不显示「未知 / —」占位值", @"出现了占位值");
        }

        // ---- A8：芯片/徽章必须**真的画出字**，不能只是空框 ----
        //
        // 这一条是本轮最重要的补丁。前面 A1–A7 全是几何判据，它们在下面这些真实缺陷下
        // **全绿**：hero 三个按钮是三个空药丸（title 有值但 drawRect 覆盖没调 super）、
        // 来源行两个复制芯片空框、来源徽章只剩一条粉色（identifier 匹配不到 ⟹ 从未排版）。
        // 铁律 3：判据量不到的东西就等于没验。这里改成量**渲染出来的像素**：
        // 把控件画进位图，数「与背景差异明显的深色像素」，为 0 就是字没画出来。
        {
            // A7 把知识材料清空过（验"无数据时安静"），这里必须**恢复夹具**再验渲染，
            // 否则徽章/芯片根本不存在，A8 会退化成"检查 0 个对象 = 通过"。
            g_materials = FixtureMaterials();
            g_summaryFields = FixtureSummaryFields();
            g_summaryOk = YES;
            [vc activate];
            Pump(1.0);
            [v layoutSubtreeIfNeeded];

            RLPTheme *t = [RLPTheme current];
            NSMutableArray<NSString *> *invisible = [NSMutableArray array];
            NSArray<NSString *> *chipIds = @[ @"artist.hero.btn.albums", @"artist.hero.btn.refresh",
                                              @"artist.hero.btn.back",
                                              @"artist.sources.open.1", @"artist.sources.copy.1" ];
            for (NSString *ident in chipIds) {
                NSView *chip = FindId(v, ident);
                if (!Visible(chip)) continue;
                const NSInteger ink = InkPixels(v, chip, t.bg);
                if (ink < 12) {
                    [invisible addObject:[NSString stringWithFormat:@"%@(ink=%ld)", ident, (long)ink]];
                }
            }
            Ck(invisible.count == 0,
               @"A8a 按钮/芯片的文字真的画出来了（不是空药丸；按渲染像素判定）",
               [invisible componentsJoinedByString:@", "]);

            // 徽章：药丸要有足够的宽度（按文字量，不是默认 4pt）与**可见的文字**。
            //
            // 反恒真：夹具里知识材料必须有内容，且徽章必须真的存在。
            // 旧写法用 `if (!Visible(badge)) continue;` —— 一旦徽章不渲染就整条跳过、
            // 判据自动变绿，等于没有判据（本轮实测：连"徽章只有 4pt"这个真实缺陷都放过了）。
            NSMutableArray<NSString *> *badBadges = [NSMutableArray array];
            NSInteger checkedBadges = 0;
            for (NSInteger i = 1; i <= 2; ++i) {
                NSView *badge = FindId(v, [NSString stringWithFormat:@"artist.sources.badge.%ld", (long)i]);
                if (!badge || badge.isHiddenOrHasHiddenAncestor) {
                    [badBadges addObject:[NSString stringWithFormat:@"badge.%ld(不存在或隐藏 ⟹ 来源行没渲染)",
                                          (long)i]];
                    continue;
                }
                ++checkedBadges;
                if (NSWidth(badge.frame) < 28.0) {
                    [badBadges addObject:[NSString stringWithFormat:@"badge.%ld(w=%.1f 未参与排版)",
                                          (long)i, NSWidth(badge.frame)]];
                    continue;
                }
                const NSInteger ink = InkPixelsAgainst(v, badge, t.accentText);
                if (ink < 8) {
                    [badBadges addObject:[NSString stringWithFormat:@"badge.%ld(ink=%ld 被底色盖住)",
                                          (long)i, (long)ink]];
                }
            }
            Ck(checkedBadges == 2 && badBadges.count == 0,
               @"A8b 来源徽章既存在、宽度按文字量、文字也没被药丸底色盖住",
               badBadges.count ? [badBadges componentsJoinedByString:@", "]
                               : [NSString stringWithFormat:@"只验到 %ld 个徽章（夹具未渲染来源行）",
                                                            (long)checkedBadges]);

            NSMutableArray<NSString *> *offCenter = [NSMutableArray array];
            NSArray<NSString *> *centerIds = @[ @"artist.back.top", @"artist.hero.btn.albums",
                                                @"artist.hero.btn.refresh", @"artist.hero.btn.back",
                                                @"artist.sources.copy.1" ];
            for (NSString *ident in centerIds) {
                NSView *chip = FindId(v, ident);
                if (!Visible(chip)) {
                    [offCenter addObject:[NSString stringWithFormat:@"%@(missing)", ident]];
                    continue;
                }
                CGFloat lp = -1, rp = -1;
                if (!InkMarginsBalanced(v, chip, t.bg, NO, &lp, &rp)) {
                    [offCenter addObject:[NSString stringWithFormat:@"%@(L=%.1f R=%.1f)", ident, lp, rp]];
                }
            }
            Ck(offCenter.count == 0,
               @"A8c 全部芯片/按钮文字与图标左右居中对称（不左挤右空）",
               [offCenter componentsJoinedByString:@", "]);
        }

        // ---- A9 唱片作品头部、播放全部与响应式专辑网格（含 year==0 无占位） ----
        {
            g_albums = @[
                @{ @"k": @"alb-no-year", @"name": @"未标年份专辑", @"artist": @"结束バンド",
                   @"year": @0, @"n": @10, @"dur": @2400.0,
                   @"sr": @96000, @"bits": @24, @"cv": @NO },
                @{ @"k": @"alb-with-year", @"name": @"結束バンド", @"artist": @"结束バンド",
                   @"year": @2022, @"n": @14, @"dur": @3240.0,
                   @"sr": @48000, @"bits": @24, @"cv": @NO },
                @{ @"k": @"alb-third", @"name": @"Re:結束バンド", @"artist": @"结束バンド",
                   @"year": @2024, @"n": @6, @"dur": @1500.0,
                   @"sr": @44100, @"bits": @16, @"cv": @NO },
            ];
            RLPArtistDetailViewController *vc9 =
                [[RLPArtistDetailViewController alloc] initWithArtistName:@"结束バンド"];
            NSView *v9 = vc9.view;
            win.contentView = v9;
            v9.frame = NSMakeRect(0, 0, 954, 700);
            [v9 layoutSubtreeIfNeeded];
            [vc9 activate];
            Pump(0.6);
            [v9 layoutSubtreeIfNeeded];

            NSView *albTitle = FindId(v9, @"artist.albums.title");
            NSView *playAll = FindId(v9, @"artist.albums.playall");
            NSView *col = FindId(v9, @"artist.albums");
            Ck(Visible(albTitle) && Visible(playAll) && Visible(col),
               @"A9a 艺术家页面显示唱片作品小节头、播放全部按钮与专辑网格",
               [NSString stringWithFormat:@"title=%d playAll=%d col=%d",
                Visible(albTitle), Visible(playAll), Visible(col)]);
            if (Visible(playAll)) {
                [vc9 performSelector:@selector(onScrollToAlbums:) withObject:nil];
                [v9 layoutSubtreeIfNeeded];
                const NSInteger whiteInk = InkPixelsAgainst(v9, playAll, [NSColor whiteColor]);
                Ck(whiteInk >= 12,
                   @"A9e 播放全部实心红按钮渲染清晰白色文字（非红底红字）",
                   [NSString stringWithFormat:@"whiteInk=%ld frameInV9=%@",
                    (long)whiteInk, NSStringFromRect(RectIn(playAll, v9))]);
                CGFloat lp = -1, rp = -1;
                const BOOL centered = InkMarginsBalanced(v9, playAll, [NSColor whiteColor], YES, &lp, &rp);
                Ck(centered,
                   @"A9f 播放全部按钮三角形与文字水平居中对称（不左挤右空）",
                   [NSString stringWithFormat:@"L=%.1f R=%.1f frame=%@", lp, rp, NSStringFromRect(playAll.frame)]);
            }
            Ck(!HasText(v9, @"未知") && !HasText(v9, @"—"),
               @"A9b 年份为空时专辑卡片不显示「未知 / —」占位符", @"发现占位符");
            if (Visible(col)) {
                const NSRect rc954 = RectIn(col, v9);
                Ck(NSMaxX(rc954) <= NSWidth(v9.bounds) + 1.0 && NSHeight(rc954) > 100.0,
                   @"A9c 专辑网格在 954pt 宽度下无溢出且高度有效",
                   [NSString stringWithFormat:@"frame=%@", NSStringFromRect(rc954)]);
            }
            v9.frame = NSMakeRect(0, 0, 674, 700);
            [v9 layoutSubtreeIfNeeded];
            Pump(0.2);
            if (Visible(col) && Visible(playAll)) {
                const NSRect rc674 = RectIn(col, v9);
                const NSRect rp674 = RectIn(playAll, v9);
                Ck(NSMaxX(rc674) <= NSWidth(v9.bounds) + 1.0 && NSMaxX(rp674) <= NSWidth(v9.bounds) + 1.0,
                   @"A9d 窄宿主 674pt 下唱片作品头部与专辑网格均不横向溢出",
                   [NSString stringWithFormat:@"colMaxX=%.1f playMaxX=%.1f w=%.1f",
                    NSMaxX(rc674), NSMaxX(rp674), NSWidth(v9.bounds)]);
            }
        }

        // ---- A10 风格徽章文字渲染 / 长简介不与展开按钮重叠 / 无 URL 来源行不留白 / 引用与底边距 ----
        {
            NSMutableString *longBio = [NSMutableString stringWithString:
                @"结束乐队（日文：結束バンド，英文：Kessoku Band）是《孤独摇滚！》及其衍生作品中登场的架空摇滚乐队。"];
            for (int i = 0; i < 8; ++i) {
                [longBio appendString:@"第一行补充说明演奏编曲细节、现场 Live 演出历程、主唱与吉他手合作记录以及专辑制作背景，确保文本远超四行折叠高度。"];
            }
            g_materials = @[
                @{ @"source": @"moegirl", @"kind": @"biography", @"title": @"结束乐队长简介",
                   @"text": longBio,
                   @"url": @"https://zh.moegirl.org.cn/结束乐队", @"fetched_at": @1762732800, @"lang": @"zh" },
                @{ @"source": @"wikipedia", @"kind": @"genre", @"title": @"J-Rock",
                   @"text": @"摇滚 · 流行摇滚", @"url": @"", @"lang": @"zh" },
            ];
            g_summaryFields = @{};
            g_summarySections = @[
                @{ @"heading": @"曲风定位",
                   @"paragraphs": @[ @{ @"text": @"吉他驱动流行摇滚" } ] },
            ];
            g_summaryCitations = @[
                @{ @"title": @"萌娘百科", @"source": @"moegirl",
                   @"url": @"https://zh.moegirl.org.cn/结束乐队" },
            ];
            g_summaryOk = YES;

            RLPArtistDetailViewController *vc10 =
                [[RLPArtistDetailViewController alloc] initWithArtistName:@"结束バンド"];
            NSView *v10 = vc10.view;
            win.contentView = v10;
            v10.frame = NSMakeRect(0, 0, 954, 700);
            [v10 layoutSubtreeIfNeeded];
            [vc10 activate];
            Pump(1.0);
            [v10 layoutSubtreeIfNeeded];

            RLPTheme *t10 = [RLPTheme current];
            NSView *badge10 = FindId(v10, @"artist.style.badge");
            const NSInteger badgeInk10 = Visible(badge10) ? InkPixelsAgainst(v10, badge10, t10.accentText) : 0;
            Ck(Visible(badge10) && NSWidth(badge10.frame) >= 32.0 && NSHeight(badge10.frame) >= 20.0 && badgeInk10 >= 8,
               @"A10a 风格与相似徽章尺寸正常且文字真实绘制（不被 layer 背景遮挡）",
               [NSString stringWithFormat:@"vis=%d frame=%@ ink=%ld",
                Visible(badge10), NSStringFromRect(badge10 ? badge10.frame : NSZeroRect), (long)badgeInk10]);

            NSView *bioText10 = FindId(v10, @"artist.bio.text");
            NSView *bioClip10 = bioText10 ? bioText10.superview : nil;
            NSView *bioToggle10 = FindId(v10, @"artist.bio.toggle");
            NSView *cardBio10 = FindId(v10, @"artist.card.bio");
            if (Visible(bioClip10) && Visible(bioToggle10) && Visible(cardBio10)) {
                const NSRect clipR = RectIn(bioClip10, cardBio10);
                const NSRect toggleR = RectIn(bioToggle10, cardBio10);
                Ck(!NSIntersectsRect(clipR, toggleR) && NSMaxY(clipR) <= NSMinY(toggleR) + 0.5,
                   @"A10b 长简介折叠裁剪区与展开按钮不重叠",
                   [NSString stringWithFormat:@"clip=%@ toggle=%@",
                    NSStringFromRect(clipR), NSStringFromRect(toggleR)]);
            } else {
                Ck(NO, @"A10b 长简介折叠裁剪区与展开按钮不重叠",
                   [NSString stringWithFormat:@"clip=%d toggle=%d cardBio=%d",
                    Visible(bioClip10), Visible(bioToggle10), Visible(cardBio10)]);
            }

            NSView *row2 = FindId(v10, @"artist.sources.row.2");
            NSView *open2 = FindId(v10, @"artist.sources.open.2");
            NSView *copy2 = FindId(v10, @"artist.sources.copy.2");
            NSView *title2 = row2 ? FindId(row2, @"artist.sources.title") : nil;
            if (Visible(row2) && Visible(title2)) {
                const NSRect titleR = RectIn(title2, row2);
                const BOOL chipsHidden = (!Visible(open2) && !Visible(copy2));
                const BOOL fullUse = NSMaxX(titleR) >= NSWidth(row2.bounds) - 20.0;
                Ck(chipsHidden && fullUse,
                   @"A10c 无 URL 来源行隐藏操作芯片并将宽度完整让给标题",
                   [NSString stringWithFormat:@"chipsHidden=%d titleMaxX=%.1f rowW=%.1f",
                    chipsHidden, NSMaxX(titleR), NSWidth(row2.bounds)]);
            } else {
                Ck(NO, @"A10c 无 URL 来源行隐藏操作芯片并将宽度完整让给标题",
                   [NSString stringWithFormat:@"row2=%d title2=%d", Visible(row2), Visible(title2)]);
            }

            NSView *secField = FindId(v10, @"artist.summary.field.曲风定位");
            NSView *cite1 = FindId(v10, @"artist.summary.cite.1");
            NSView *cardSum10 = FindId(v10, @"artist.card.summary");
            NSView *foot10 = FindId(v10, @"artist.summary.foot");
            const NSInteger citeInk10 = Visible(cite1) ? InkPixels(v10, cite1, t10.bg2) : 0;
            CGFloat bottomPad = -1.0;
            if (Visible(cardSum10) && Visible(foot10)) {
                bottomPad = NSHeight(cardSum10.bounds) - NSMaxY(RectIn(foot10, cardSum10));
            }
            Ck(Visible(secField) && Visible(cite1) && citeInk10 >= 12 &&
               bottomPad >= 12.0 && bottomPad <= 17.0,
               @"A10d summarySections 兜底、引用芯片绘制与摘要卡片底边距对称",
               [NSString stringWithFormat:@"secField=%d cite=%d ink=%ld bottomPad=%.1f",
                Visible(secField), Visible(cite1), (long)citeInk10, bottomPad]);

            g_summarySections = @[];
            g_summaryCitations = @[];
        }

        // ---- A11 点击文字不改变字体/字号，非内容标签禁用 selectable ----
        {
            g_materials = FixtureMaterials();
            g_summaryFields = FixtureSummaryFields();
            g_summaryOk = YES;
            RLPArtistDetailViewController *vc11 =
                [[RLPArtistDetailViewController alloc] initWithArtistName:@"Aimer"];
            NSView *v11 = vc11.view;
            NSWindow *kw = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1180, 720)
                                                       styleMask:NSWindowStyleMaskTitled
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
            kw.releasedWhenClosed = NO;
            kw.contentView = v11;
            v11.frame = NSMakeRect(0, 0, 1180, 720);
            [v11 layoutSubtreeIfNeeded];
            [vc11 activate];
            Pump(0.6);
            [v11 layoutSubtreeIfNeeded];

            NSMutableArray<NSView *> *all11 = [NSMutableArray array];
            Collect(v11, all11);
            NSMutableArray<NSString *> *badChromeSel = [NSMutableArray array];
            NSSet<NSString *> *chromeIds = [NSSet setWithArray:@[
                @"artist.hero.eyebrow", @"artist.hero.sub", @"artist.card.title",
                @"artist.albums.title", @"artist.summary.status", @"artist.summary.foot",
                @"efrow.label", @"artist.sources.date"
            ]];
            for (NSView *item in all11) {
                if (![item isKindOfClass:[NSTextField class]]) continue;
                NSTextField *tf = (NSTextField *)item;
                NSString *ident = tf.identifier ?: @"";
                if ([chromeIds containsObject:ident] || [ident hasPrefix:@"artist.sources.badge"]) {
                    if (tf.selectable) [badChromeSel addObject:ident];
                }
            }
            Ck(badChromeSel.count == 0,
               @"A11a 非正文装饰标签（eyebrow/副标题/卡片标题/字段名/来源日期等）禁用 selectable",
               [badChromeSel componentsJoinedByString:@", "]);

            NSView *nameV = FindId(v11, @"artist.hero.name");
            NSView *bioV = FindId(v11, @"artist.bio.text");
            NSView *srcTitleV = FindId(v11, @"artist.sources.title");
            NSView *efValV = FindId(v11, @"efrow.value");
            NSMutableArray<NSString *> *badEditAttr = [NSMutableArray array];
            for (NSView *item in @[ nameV ?: (id)[NSNull null], bioV ?: (id)[NSNull null],
                                    srcTitleV ?: (id)[NSNull null], efValV ?: (id)[NSNull null] ]) {
                if (![item isKindOfClass:[NSTextField class]]) {
                    [badEditAttr addObject:@"missing"];
                    continue;
                }
                NSTextField *tf = (NSTextField *)item;
                if (!tf.selectable || !tf.allowsEditingTextAttributes) {
                    [badEditAttr addObject:tf.identifier ?: @"tf"];
                }
            }
            Ck(badEditAttr.count == 0,
               @"A11b 可复制正文（艺人名/字段值/简介/来源标题）启用 selectable + allowsEditingTextAttributes",
               [badEditAttr componentsJoinedByString:@", "]);

            auto checkClickPreservesFont = [&](NSTextField *tf, CGFloat wantPt, BOOL wantBold,
                                               CGFloat wantKern, CGFloat wantLineSpacing, NSString *tag) -> NSString * {
                if (!tf) return [NSString stringWithFormat:@"%@(nil)", tag];
                if (fabs(tf.font.pointSize - wantPt) > 0.25) {
                    return [NSString stringWithFormat:@"%@(baseFont=%.1f want=%.1f)", tag, tf.font.pointSize, wantPt];
                }
                [kw makeFirstResponder:tf];
                [tf selectText:nil];
                Pump(0.05);
                NSResponder *fr = kw.firstResponder;
                if (![fr isKindOfClass:[NSTextView class]]) {
                    return [NSString stringWithFormat:@"%@(firstResponder=%@)", tag, NSStringFromClass([fr class])];
                }
                NSTextView *fe = (NSTextView *)fr;
                NSFont *feFont = fe.font;
                if (!feFont && fe.textStorage.length > 0) {
                    feFont = [fe.textStorage attribute:NSFontAttributeName atIndex:0 effectiveRange:nil];
                }
                NSFont *runFont = (fe.textStorage.length > 0)
                    ? [fe.textStorage attribute:NSFontAttributeName atIndex:0 effectiveRange:nil]
                    : feFont;
                NSNumber *runKern = (fe.textStorage.length > 0)
                    ? [fe.textStorage attribute:NSKernAttributeName atIndex:0 effectiveRange:nil]
                    : nil;
                NSParagraphStyle *runPs = (fe.textStorage.length > 0)
                    ? [fe.textStorage attribute:NSParagraphStyleAttributeName atIndex:0 effectiveRange:nil]
                    : nil;
                const BOOL isBold = runFont && ((runFont.fontDescriptor.symbolicTraits & NSFontDescriptorTraitBold) != 0);
                if (!feFont || fabs(feFont.pointSize - wantPt) > 0.25 ||
                    !runFont || fabs(runFont.pointSize - wantPt) > 0.25 ||
                    (wantBold && !isBold) ||
                    (fabs(wantKern) > 0.01 && (!runKern || fabs(runKern.doubleValue - wantKern) > 0.05)) ||
                    (wantLineSpacing > 0.1 && (!runPs || fabs(runPs.lineSpacing - wantLineSpacing) > 0.2))) {
                    return [NSString stringWithFormat:@"%@(fe=%.1f run=%.1f bold=%d kern=%.2f ls=%.1f)",
                            tag, feFont ? feFont.pointSize : -1.0, runFont ? runFont.pointSize : -1.0,
                            isBold, runKern ? runKern.doubleValue : 0.0, runPs ? runPs.lineSpacing : 0.0];
                }
                [kw makeFirstResponder:nil];
                return nil;
            };

            NSMutableArray<NSString *> *fontDrift = [NSMutableArray array];
            for (NSString *err in @[
                checkClickPreservesFont((NSTextField *)nameV, 28.0, YES, -0.5, 0.0, @"name") ?: @"",
                checkClickPreservesFont((NSTextField *)efValV, 12.5, NO, 0.0, 6.0, @"efrow.value") ?: @"",
                checkClickPreservesFont((NSTextField *)bioV, 12.5, NO, 0.0, 8.0, @"bio") ?: @"",
                checkClickPreservesFont((NSTextField *)srcTitleV, 12.5, YES, 0.0, 0.0, @"source.title") ?: @"",
            ]) {
                if (err.length) [fontDrift addObject:err];
            }
            Ck(fontDrift.count == 0,
               @"A11c 点击选中艺人名与卡片文字后 field editor 保持原字号/字重/字距/行距（不变小、不变字体）",
               [fontDrift componentsJoinedByString:@", "]);

            // ---- A12 Hero 艺人名排版与对齐 ----
            NSView *eyebrow12 = FindId(v11, @"artist.hero.eyebrow");
            NSView *sub12 = FindId(v11, @"artist.hero.sub");
            NSView *avatar12 = FindId(v11, @"artist.hero.avatar");
            NSView *btnAlb12 = FindId(v11, @"artist.hero.btn.albums");
            NSTextField *nameTF = (NSTextField *)nameV;
            const NSRect rE12 = RectIn(eyebrow12, v11);
            const NSRect rN12 = RectIn(nameV, v11);
            const NSRect rS12 = RectIn(sub12, v11);
            const NSRect rA12 = RectIn(avatar12, v11);
            const NSRect rB12 = RectIn(btnAlb12, v11);
            const CGFloat gapAbove = NSMinY(rE12) - NSMaxY(rN12);
            const CGFloat gapBelow = NSMinY(rN12) - NSMaxY(rS12);
            const BOOL heroAligned = Visible(nameV) && Visible(sub12) &&
                                     !nameTF.usesSingleLineMode && nameTF.maximumNumberOfLines == 1 &&
                                     NSHeight(rN12) >= 32.0 && NSHeight(rN12) <= 36.0 &&
                                     fabs(NSMinX(rE12) - NSMinX(rN12)) < 0.5 &&
                                     fabs(NSMinX(rS12) - NSMinX(rN12)) < 0.5 &&
                                     fabs(gapAbove - gapBelow) <= 1.5 &&
                                     NSMinY(rB12) >= NSMinY(rA12) - 1.0;
            Ck(heroAligned,
               @"A12 Hero 艺人名不使用 singleLineMode 偏心框，且与 eyebrow/副标题左对齐、上下间距对称",
               [NSString stringWithFormat:@"single=%d h=%.1f x=%.1f/%.1f/%.1f gap=%.1f/%.1f btnMinY=%.1f avMinY=%.1f",
                nameTF.usesSingleLineMode, NSHeight(rN12), NSMinX(rE12), NSMinX(rN12), NSMinX(rS12),
                gapAbove, gapBelow, NSMinY(rB12), NSMinY(rA12)]);
            kw.contentView = nil;
        }

        // ---- A13 多专辑（43 张专辑）Across 宽/窄/168边界/传统滚动条宽度全量显示且不裁切 ----
        {
            NSMutableArray<NSDictionary *> *many = [NSMutableArray arrayWithCapacity:43];
            for (NSInteger i = 0; i < 43; ++i) {
                [many addObject:@{
                    @"k": [NSString stringWithFormat:@"aimer-%ld", (long)i],
                    @"name": [NSString stringWithFormat:@"Album %02ld", (long)(i + 1)],
                    @"artist": @"Aimer",
                    @"year": @(2011 + (i % 15)),
                    @"n": @(8 + (i % 6)),
                    @"dur": @(2100.0 + i * 30.0),
                    @"sr": @96000, @"bits": @24, @"cv": @NO
                }];
            }
            g_albums = many;
            g_materials = FixtureMaterials();
            g_summaryFields = FixtureSummaryFields();
            g_summaryOk = YES;

            RLPArtistDetailViewController *vc13 =
                [[RLPArtistDetailViewController alloc] initWithArtistName:@"Aimer"];
            NSView *v13 = vc13.view;
            win.contentView = v13;
            v13.frame = NSMakeRect(0, 0, 1710, 714);
            [v13 layoutSubtreeIfNeeded];
            [vc13 activate];
            Pump(0.5);
            [v13 layoutSubtreeIfNeeded];

            NSCollectionView *col13 = (NSCollectionView *)FindId(v13, @"artist.albums");
            NSView *playAll13 = FindId(v13, @"artist.albums.playall");
            NSScrollView *sv13 = col13.enclosingScrollView;
            NSView *doc13 = sv13.documentView;

            NSMutableArray<NSString *> *gridFailures = [NSMutableArray array];
            const CGFloat widths13[] = { 1710.0, 1518.0, 1366.0, 674.0 };
            for (size_t wi = 0; wi < sizeof(widths13) / sizeof(widths13[0]); ++wi) {
                const CGFloat tw = widths13[wi];
                const CGFloat th = (wi == 2) ? 900.0 : 714.0;
                v13.frame = NSMakeRect(0, 0, tw, th);
                [v13 layoutSubtreeIfNeeded];
                Pump(0.15);
                [v13 layoutSubtreeIfNeeded];

                const CGFloat clipW = sv13.contentView.bounds.size.width;
                const CGFloat contentW = MAX(80.0, clipW - 44.0);
                const CGFloat gapX = 16.0, minItemW = 148.0;
                const NSInteger cols = MAX(1, (NSInteger)floor((contentW + gapX) / (minItemW + gapX)));
                const CGFloat wantItemW = MAX(80.0, floor((contentW - gapX * (CGFloat)(cols - 1)) / (CGFloat)cols));
                const CGFloat wantItemH = wantItemW + 46.0;

                if (fabs(NSWidth(doc13.frame) - clipW) > 1.0) {
                    [gridFailures addObject:[NSString stringWithFormat:@"w=%.0f docW=%.1f!=clipW=%.1f",
                                             tw, NSWidth(doc13.frame), clipW]];
                }
                if (NSMaxX(col13.frame) > clipW - 22.0 + 1.0) {
                    [gridFailures addObject:[NSString stringWithFormat:@"w=%.0f colMaxX=%.1f>right=%.1f",
                                             tw, NSMaxX(col13.frame), clipW - 22.0]];
                }
                if (Visible(playAll13) && NSMaxX(col13.frame) > NSMaxX(playAll13.frame) + 1.0) {
                    [gridFailures addObject:[NSString stringWithFormat:@"w=%.0f colMaxX=%.1f>playAllMaxX=%.1f",
                                             tw, NSMaxX(col13.frame), NSMaxX(playAll13.frame)]];
                }
                if (NSHeight(doc13.frame) < NSMaxY(col13.frame) + 90.0) {
                    [gridFailures addObject:[NSString stringWithFormat:@"w=%.0f docH=%.1f<colBottom+90=%.1f",
                                             tw, NSHeight(doc13.frame), NSMaxY(col13.frame) + 90.0]];
                }
                NSCollectionViewFlowLayout *fl = (NSCollectionViewFlowLayout *)col13.collectionViewLayout;
                if (!fl || fabs(fl.itemSize.width - wantItemW) > 0.5 || fabs(fl.itemSize.height - wantItemH) > 0.5) {
                    [gridFailures addObject:[NSString stringWithFormat:@"w=%.0f item=%.1fx%.1f want=%.1fx%.1f",
                                             tw, fl ? fl.itemSize.width : -1.0, fl ? fl.itemSize.height : -1.0,
                                             wantItemW, wantItemH]];
                }
                for (NSInteger idx = 0; idx < 43; ++idx) {
                    NSIndexPath *ip = [NSIndexPath indexPathForItem:idx inSection:0];
                    NSCollectionViewLayoutAttributes *attr = [fl layoutAttributesForItemAtIndexPath:ip];
                    if (!attr) {
                        [gridFailures addObject:[NSString stringWithFormat:@"w=%.0f attrNil#%ld", tw, (long)idx]];
                        break;
                    }
                    if (fabs(attr.frame.size.width - wantItemW) > 0.5 ||
                        fabs(attr.frame.size.height - wantItemH) > 0.5 ||
                        NSMaxX(attr.frame) > col13.bounds.size.width + 0.5 ||
                        NSMaxY(attr.frame) > col13.bounds.size.height + 0.5) {
                        [gridFailures addObject:[NSString stringWithFormat:@"w=%.0f item#%ld frame=%@ col=%@",
                                                 tw, (long)idx, NSStringFromRect(attr.frame),
                                                 NSStringFromSize(col13.bounds.size)]];
                        break;
                    }
                }
            }

            // 回到 1710 滚到底部，核实第 43 张专辑真实实例化且没有被裁出边界
            v13.frame = NSMakeRect(0, 0, 1710, 714);
            [v13 layoutSubtreeIfNeeded];
            const CGFloat maxScrollY = MAX(0.0, NSHeight(doc13.frame) - NSHeight(sv13.contentView.bounds));
            [sv13.contentView scrollToPoint:NSMakePoint(0, maxScrollY)];
            [sv13 reflectScrolledClipView:sv13.contentView];
            Pump(0.15);
            [v13 layoutSubtreeIfNeeded];
            NSCollectionViewItem *lastItem = [col13 itemAtIndexPath:[NSIndexPath indexPathForItem:42 inSection:0]];
            if (!lastItem || NSMaxY(lastItem.view.frame) > col13.bounds.size.height + 0.5 ||
                NSMaxX(lastItem.view.frame) > col13.bounds.size.width + 0.5) {
                [gridFailures addObject:[NSString stringWithFormat:@"bottomItem42=%@ col=%@",
                                         lastItem ? NSStringFromRect(lastItem.view.frame) : @"nil",
                                         NSStringFromSize(col13.bounds.size)]];
            }
            Ck(gridFailures.count == 0,
               @"A13 43张专辑在 1710/1518/1366/674 宽及滚动到底部时均完整排布，不溢出、不吞尾项",
               [gridFailures componentsJoinedByString:@" | "]);

            // ---- A14 回归：向下渐进滚动时，_collection 最右列与 contentSize 绝不能被 enclosingScrollView 宽度拉宽溢出 ----
            NSMutableArray<NSString *> *scrollFailures = [NSMutableArray array];
            const CGFloat scrollWidths[] = { 1710.0, 1518.0, 1366.0, 674.0 };
            for (size_t wi = 0; wi < sizeof(scrollWidths) / sizeof(scrollWidths[0]); ++wi) {
                const CGFloat tw = scrollWidths[wi];
                const CGFloat th = (wi == 2) ? 900.0 : 714.0;
                v13.frame = NSMakeRect(0, 0, tw, th);
                [sv13.contentView scrollToPoint:NSZeroPoint];
                [sv13 reflectScrolledClipView:sv13.contentView];
                [v13 layoutSubtreeIfNeeded];
                Pump(0.1);
                [v13 layoutSubtreeIfNeeded];

                const CGFloat maxSY = MAX(0.0, NSHeight(doc13.frame) - NSHeight(sv13.contentView.bounds));
                const CGFloat offsets[] = {
                    60.0, 140.0, 260.0, 420.0, 620.0, maxSY
                };
                for (size_t oi = 0; oi < sizeof(offsets) / sizeof(offsets[0]); ++oi) {
                    const CGFloat sy = MIN(maxSY, offsets[oi]);
                    [sv13.contentView scrollToPoint:NSMakePoint(0, sy)];
                    [sv13 reflectScrolledClipView:sv13.contentView];
                    Pump(0.08);
                    [v13 layoutSubtreeIfNeeded];

                    NSCollectionViewFlowLayout *fl = (NSCollectionViewFlowLayout *)col13.collectionViewLayout;
                    if (!fl || fl.collectionViewContentSize.width > NSWidth(col13.bounds) + 0.5) {
                        [scrollFailures addObject:[NSString stringWithFormat:@"w=%.0f sy=%.0f contentW=%.1f>colW=%.1f",
                                                   tw, sy, fl ? fl.collectionViewContentSize.width : -1.0,
                                                   NSWidth(col13.bounds)]];
                        break;
                    }
                    NSArray<NSCollectionViewItem *> *visItems = col13.visibleItems ?: @[];
                    if (visItems.count == 0) {
                        for (NSInteger idx = 0; idx < 43; ++idx) {
                            NSCollectionViewItem *it = [col13 itemAtIndexPath:[NSIndexPath indexPathForItem:idx inSection:0]];
                            if (it) visItems = [visItems arrayByAddingObject:it];
                        }
                    }
                    for (NSCollectionViewItem *it in visItems) {
                        const NSRect inDoc = [it.view convertRect:it.view.bounds toView:doc13];
                        if (NSMaxX(it.view.frame) > NSWidth(col13.bounds) + 0.5 ||
                            (Visible(playAll13) && NSMaxX(inDoc) > NSMaxX(playAll13.frame) + 0.5)) {
                            [scrollFailures addObject:[NSString stringWithFormat:@"w=%.0f sy=%.0f item=%@ inDoc=%@ colW=%.1f playMax=%.1f",
                                                       tw, sy, NSStringFromRect(it.view.frame),
                                                       NSStringFromRect(inDoc), NSWidth(col13.bounds),
                                                       NSMaxX(playAll13.frame)]];
                            break;
                        }
                    }
                    for (NSInteger idx = 0; idx < 43; ++idx) {
                        NSCollectionViewLayoutAttributes *attr =
                            [fl layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:idx inSection:0]];
                        if (!attr || NSMaxX(attr.frame) > NSWidth(col13.bounds) + 0.5) {
                            [scrollFailures addObject:[NSString stringWithFormat:@"w=%.0f sy=%.0f attr#%ld=%@ colW=%.1f",
                                                       tw, sy, (long)idx,
                                                       attr ? NSStringFromRect(attr.frame) : @"nil",
                                                       NSWidth(col13.bounds)]];
                            break;
                        }
                    }
                    if (scrollFailures.count > 0) break;
                }
            }
            Ck(scrollFailures.count == 0,
               @"A14 向下滚动后所有专辑卡片右缘仍严丝合缝对齐内容区（不因滚动拉宽间隙并溢出滚动条）",
               [scrollFailures componentsJoinedByString:@" | "]);
            g_albums = nil;
        }

        std::printf("结果：%d passed, %d failed\n", gPass, gFail);
        return gFail == 0 ? 0 : 1;
    }
}
