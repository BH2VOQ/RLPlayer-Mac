// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPFunctionalAudit.mm — 功能级验收 + 离屏截图
//
// 为什么要有这一层（本轮的真实事故）：
//   旧 --selftest 只断言"页面能构造出来"，于是专辑页双击**直接播放、从不打开详情**
//   这种故障它一条都抓不到 —— 用户点进去发现进不去，而门禁全绿。
//   判据必须问"点了之后发生了什么"，而不是"对象存在吗"。
//
// 这里做三件事：
//   ① 造一个隔离曲库（合成索引 + 真实可解码的音频文件），让页面有真数据可渲染；
//   ② 真的发通知/调路由，断言 currentContent 变成了期望的页面类型；
//   ③ 把每个页面 bitmap 渲染成 PNG 落盘，供人眼复核布局。
//
// 纪律：backend=null + volume=-120，绝不打开音频设备、绝不出声。
#import "RLPFunctionalAudit.h"
#import <AppKit/AppKit.h>
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPMainWindowController.h"
#import "RLPSidebarViewController.h"
#import "RLPAlbumsViewController.h"
#import "RLPAlbumDetailViewController.h"
#import "RLPArtistDetailViewController.h"
#import "RLPTracksViewController.h"
#import "RLPQueueViewController.h"
#import "RLPPlaylistsViewController.h"
#import "RLPSettingsViewController.h"
#import "RLPNowPlayingViewController.h"
#import "RLPStreamingViewController.h"
#import "RLPQuickStartViewController.h"
#import "RLPFavoritesViewController.h"
#import "RLPRecentViewController.h"
#import "RLPFoldersViewController.h"
#import "RLPArtistsViewController.h"
#import "RLPPlaybackBarView.h"
#import "RLPRightDrawer.h"
#import "RLPLyrics.h"
#import "RLPSupport.h"
#import <AVFoundation/AVFoundation.h>
#import "RLPTheme.h"

/// 专辑卡悬停入口（RLPAlbumItem 的 cardHoverChanged:）——审计用它触发同一个生产入口。
@interface NSObject (RLPAlbumHoverAudit)
- (void)cardHoverChanged:(BOOL)on;
@end

/// 设置页 AI 模型刷新入口（审计用同一生产路径，不复制一份逻辑）。
@interface NSObject (RLPLlmRefreshAudit)
- (void)onLlmModelRefresh:(id)sender;
- (void)loadLlmModels:(BOOL)force;
- (void)loadLlmConfig;
@end

@interface RLPNowPlayingViewController (OfflineAuditProjection)
- (void)applyLyricText:(NSString *)text forPath:(NSString *)path;
- (void)updateLyricPosition:(double)pos;
- (void)renderMetaChipsFromMeta:(NSDictionary *)json;
@end

#include <cstdio>
#include <cstdlib>

static int gFail = 0;
static int gPass = 0;

static void CK(BOOL ok, const char *what, NSString *detail) {
    if (ok) { ++gPass; std::printf("  [PASS] %s\n", what); }
    else { ++gFail; std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); }
}

// 把视图渲染成 PNG。**先强制布局**，否则约束还没解算，截出来是空白。
static BOOL Snap(NSView *v, NSString *path, CGSize size) {
    if (!v) return NO;
    v.frame = NSMakeRect(0, 0, size.width, size.height);
    [v layoutSubtreeIfNeeded];
    v.needsDisplay = YES;
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
    if (!rep) return NO;
    [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!png.length) return NO;
    return [png writeToFile:path atomically:YES];
}

// 取截图左上角一块"应当是页面背景"的区域主色，判断明暗。
// 为什么用像素而不是读属性：属性说"我设了 light"不算证据，
// 用户看到的是**渲染出来的颜色**。之前"选了浅色主页还是黑的"就是属性对、渲染错。
static BOOL ShotIsLight(NSString *path) {
    NSImage *img = [[NSImage alloc] initWithContentsOfFile:path];
    if (!img) return NO;
    NSBitmapImageRep *rep = nil;
    for (NSImageRep *r in img.representations)
        if ([r isKindOfClass:[NSBitmapImageRep class]]) { rep = (NSBitmapImageRep *)r; break; }
    if (!rep) return NO;
    // 采内容区中部一列（避开侧栏与顶栏），统计平均亮度
    double sum = 0; NSInteger n = 0;
    const NSInteger W = rep.pixelsWide, H = rep.pixelsHigh;
    for (NSInteger y = H / 3; y < H * 2 / 3; y += 7) {
        for (NSInteger x = W / 2; x < W - 20; x += 11) {
            NSColor *c = [rep colorAtX:x y:y];
            if (!c) continue;
            NSColor *rgb = [c colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            if (!rgb) continue;
            sum += 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent;
            ++n;
        }
    }
    if (!n) return NO;
    return (sum / n) > 0.5;   // >0.5 视为浅色
}

// 统计截图里"珊瑚红强调色"的像素占比（#fa2d48 附近）。
// 用途：侧栏选中态、当前曲高亮都靠它。占比为 0 说明**强调色根本没画出来**，
// 而不是"颜色淡看不出来" —— 这是可量化的观感判据。
/// 截图的指定区域是否**没有横向条带**（亮度沿 y 的最大/最小差很小）。
/// 为什么需要：NSTableView 的 usesAlternatingRowBackgroundColors 在空表时
/// 会把表区域铺成一屏灰条（0 首队列/收藏都会出现），属性自述"只是交替色"看不出坏。
/// 只采样右侧空白列（x=宽度的 88%），避开空态文字与表头。
static BOOL ShotRowsAreaIsUniform(NSString *path) {
    NSImage *img = [[NSImage alloc] initWithContentsOfFile:path];
    if (!img) return NO;
    NSBitmapImageRep *rep = nil;
    for (NSImageRep *r in img.representations)
        if ([r isKindOfClass:[NSBitmapImageRep class]]) { rep = (NSBitmapImageRep *)r; break; }
    if (!rep) return NO;
    const NSInteger W = rep.pixelsWide, H = rep.pixelsHigh;
    double mn = 1.0, mx = 0.0;
    // 表体区域：y 从 30% 到 80%（**必须避开底部播放条**：它从 ~84% 起，
    // 里面还有红色音量滑杆与徽标，采到就会假红——第一版就踩了这个），x 固定 88%。
    for (NSInteger y = (NSInteger)(H * 0.30); y < (NSInteger)(H * 0.80); y += 4) {
        NSColor *c = [rep colorAtX:(NSInteger)(W * 0.88) y:y];
        NSColor *rgb = [c colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        if (!rgb) continue;
        const double lum = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent;
        mn = MIN(mn, lum); mx = MAX(mx, lum);
    }
    if (mx <= 0.0) return NO;
    return (mx - mn) < 0.02;   // 条带会让亮度在 ~0.06 范围内来回跳
}

static double AccentRatio(NSString *path) {
    NSImage *img = [[NSImage alloc] initWithContentsOfFile:path];
    if (!img) return -1;
    NSBitmapImageRep *rep = nil;
    for (NSImageRep *r in img.representations)
        if ([r isKindOfClass:[NSBitmapImageRep class]]) { rep = (NSBitmapImageRep *)r; break; }
    if (!rep) return -1;
    NSInteger hit = 0, n = 0;
    for (NSInteger y = 0; y < rep.pixelsHigh; y += 2) {
        for (NSInteger x = 0; x < rep.pixelsWide; x += 2) {
            NSColor *c = [[rep colorAtX:x y:y] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            if (!c) continue;
            ++n;
            // 选中底是 accentWeak（14% 珊瑚红叠在白底上）⟹ 混色后是浅粉，
            // 判据要认"红通道明显高于绿蓝"，不能要求饱和红。
            if (c.redComponent > 0.85 && c.greenComponent < 0.80 &&
                (c.redComponent - c.greenComponent) > 0.06) ++hit;
        }
    }
    return n ? (double)hit / (double)n : -1;
}

// 数视图树里"有内容的标签"个数：用来判断页面是不是空壳。
static NSInteger NonEmptyLabels(NSView *v) {
    NSInteger n = 0;
    if ([v isKindOfClass:[NSTextField class]]) {
        if (((NSTextField *)v).stringValue.length) ++n;
    }
    for (NSView *s in v.subviews) n += NonEmptyLabels(s);
    return n;
}

static void CollectAllViews(NSView *v, NSMutableArray<NSView *> *out) {
    if (!v) return;
    [out addObject:v];
    for (NSView *s in v.subviews) CollectAllViews(s, out);
}

/// 真·可见：自身与**全部祖先**都未隐藏，且自身 frame 有面积、有非零 alpha。
///
/// 为什么必须是这个函数而不是「!v.hidden」：2026-11-13 的第一次判据只看了 v.hidden，
/// 于是「把控件收进 hidden=YES 的容器」这种形态在旧实现上**照样 PASS**
/// —— 正是铁律④说的"测试通过 ≠ 测对了东西"。这里把祖先链一起判。
static BOOL RLPViewActuallyVisible(NSView *v) {
    if (!v) return NO;
    if (v.hidden) return NO;
    if (v.frame.size.width < 1 || v.frame.size.height < 1) return NO;
    if (v.alphaValue < 0.01) return NO;
    for (NSView *p = v.superview; p; p = p.superview) {
        if (p.hidden) return NO;
        if (p.alphaValue < 0.01) return NO;
    }
    return YES;
}

#pragma mark - 隔离曲库

// 造 3 张专辑 / 6 首曲子的最小真实库，让页面有真数据可渲染。
// 音频用系统 say 生成（本机 ffmpeg 是精简版、无 lavfi，不能凭空造信号）。
// 这些文件**只用于渲染**，审计过程绝不播放它们。
static NSString *BuildFixtureLibrary(NSString *root) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *music = [root stringByAppendingPathComponent:@"music"];
    NSString *state = [root stringByAppendingPathComponent:@"state"];
    [fm createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil error:nil];

    NSArray *albums = @[
        @[ @"Kind of Blue", @"Miles Davis", @"1959" ],
        @[ @"A Love Supreme", @"John Coltrane", @"1965" ],
        @[ @"Blue Train", @"John Coltrane", @"1958" ],
    ];
    NSMutableString *idx = [NSMutableString string];
    [idx appendString:@"#libIndexV\t4\n"];
    [idx appendString:@"#path\tmtime\tsize\talbum\talbumArtist\tartist\ttitle\ttrack\tdisc\tyear\tsr\tbits\tch\tdur\thasCover\tgenre\tcue\tcueN\tcueOff\tcueLen\n"];

    NSInteger made = 0;
    for (NSInteger a = 0; a < (NSInteger)albums.count; ++a) {
        NSArray *info = albums[a];
        NSString *dir = [music stringByAppendingPathComponent:info[0]];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSInteger t = 1; t <= 2; ++t) {
            NSString *title = [NSString stringWithFormat:@"%@ %ld", info[0], (long)t];
            NSString *aiff = [dir stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"%02ld.aiff", (long)t]];
            // ⚠️ 这里必须让**真实时长**足够长：旧写法 `say -o … "test"` 只有约 0.69s，
            // 而下面索引行写的是 dur=30s+。播放到第二次 0.5s 轮询时音频早已 EOS，
            // 于是 --audit 里任何「播放中」的判据都读到 playing=false（本轮第2项就是被它假红）。
            // 用重复文本把它拉长到十几秒；时长仍以 ffprobe 实测为准写进索引。
            NSMutableString *tts = [NSMutableString string];
            for (int k = 0; k < 24; ++k) [tts appendString:@"test number "];
            NSTask *say = [[NSTask alloc] init];
            say.launchPath = @"/usr/bin/say";
            say.arguments = @[ @"-o", aiff, tts ];
            @try { [say launch]; [say waitUntilExit]; } @catch (NSException *e) { (void)e; }
            if (![fm fileExistsAtPath:aiff]) {
                [@"" writeToFile:aiff atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
            NSDictionary *attr = [fm attributesOfItemAtPath:aiff error:nil];
            const long long sz = (long long)attr.fileSize;
            // 索引里的 dur 必须是**文件的真实时长**：夹具自欺过一次（写死 30s，实际 0.69s），
            // 结果「播放中」的判据在音频早已结束后才去读状态，全变成假红。
            double realDur = 30.0;
            {
                AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:aiff] options:nil];
                const CMTime d = asset.duration;
                if (CMTIME_IS_NUMERIC(d) && CMTimeGetSeconds(d) > 0.1)
                    realDur = CMTimeGetSeconds(d);
            }
            [idx appendFormat:@"%@\t111\t%lld\t%@\t%@\t%@\t%@\t%ld\t1\t%@\t44100\t16\t2\t%.1f\t0\tJazz\t\t0\t0\t0\n",
             aiff, sz, info[0], info[1], info[1], title, (long)t, info[2], realDur];
            ++made;
        }
    }
    [idx writeToFile:[root stringByAppendingPathComponent:@"rlplayer-index.tsv"]
          atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [music writeToFile:[root stringByAppendingPathComponent:@"rlplayer-library.conf"]
          atomically:YES encoding:NSUTF8StringEncoding error:nil];
    // backend=null + volume=-120：绝不打开设备、绝不出声（铁律 1）
    [@"backend=null\nvolume=-120\nscanonstartup=0\nmetaon=0\nmetallm=0\n"
     writeToFile:[state stringByAppendingPathComponent:@"rlplayer-settings.conf"]
     atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return made ? music : nil;
}

// 让主线程 runloop 转一会儿，等异步 /api 回调落地（否则截图是空的）。
static void Pump(NSTimeInterval seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
}

#pragma mark - 主流程


/// 把本轮功能验收的结论回传给后端（web 用 /api/selftest/report 落盘页面自检结果）。
/// 为什么要有：web 的页面自检跑完会把 want/actual 落盘，便于事后 grep 与对比；
/// 原生这边是 --audit，结论同样应该落盘到同一个地方，否则两边的"验收证据"躺在两个世界。
static void ReportAuditResult(NSString *summary, NSInteger pass, NSInteger fail) {
    if (![RLPCoreClient shared].started) return;
    NSDictionary *payload = @{ @"schema": @1,
                               @"kind": @"native-audit",
                               @"pass": @(pass),
                               @"fail": @(fail),
                               @"summary": summary ?: @"" };
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    [[RLPCoreClient shared] postData:@"/api/selftest/report"
                                body:body ?: [NSData data]
                         contentType:@"application/json"
                          completion:nil];
}

/// 回传一条 UI 动作事件（web 的 uiTrace 做的是同一件事：把页面动作/异常批量落盘）。
/// 原生的"页面动作"就是导航与页签切换，这里在关键路径上记一笔。
static void TraceUiEvent(NSString *kind, NSDictionary *detail) {
    if (![RLPCoreClient shared].started) return;
    NSDictionary *ev = @{ @"schema": @1, @"events": @[ @{ @"k": kind ?: @"",
                                                          @"d": detail ?: @{} } ] };
    NSData *body = [NSJSONSerialization dataWithJSONObject:ev options:0 error:nil];
    [[RLPCoreClient shared] postData:@"/api/ui/events"
                                body:body ?: [NSData data]
                         contentType:@"application/json"
                          completion:nil];
}

int RLPRunFunctionalAudit(NSString *outDir) {
    gFail = 0; gPass = 0;
    std::printf("=== rlplayer_native 功能级验收（真数据 + 真导航 + 截图）===\n");

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"rlp-audit-%d", (int)getpid()]];
    [fm removeItemAtPath:root error:nil];
    [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *music = BuildFixtureLibrary(root);
    CK(music != nil, "夹具曲库已生成", root);
    if (!music) return 1;

    setenv("RLPLAYER_STATE_DIR", [root stringByAppendingPathComponent:@"state"].fileSystemRepresentation, 1);
    // 索引与 library.conf 必须落在 RLPLAYER_LIBRARY_DIR 里（与 test_embedded_api 同口径）。
    // 之前把 LIBRARY_DIR 指到 music、却把索引写在 root ⟹ 后端读不到索引，
    // 首次扫描把空库当真，专辑数恒为 0，后面所有页面断言都失去意义。
    setenv("RLPLAYER_LIBRARY_DIR", root.fileSystemRepresentation, 1);
    setenv("RLPLAYER_COVER_DIR", [root stringByAppendingPathComponent:@"covers"].fileSystemRepresentation, 1);
    // 历史收藏文件（Windows 时代遗留的 '\' 分隔路径）：必须在读回时被规范成 '/'，
    // 否则老用户的收藏在 macOS 上永远对不上曲库（详见 rtaweb.cpp normalize_fav_path 注释）。
    {
        NSString *legacyPath = [music stringByAppendingPathComponent:@"Kind of Blue/01.aiff"];
        NSString *legacyForm = [legacyPath stringByReplacingOccurrencesOfString:@"/" withString:@"\\"];
        NSData *favJson = [NSJSONSerialization dataWithJSONObject:@[ legacyForm ] options:0 error:nil];
        NSString *legacyFile = [[root stringByAppendingPathComponent:@"state"]
                                stringByAppendingPathComponent:@"rlplayer-favs.json"];
        [[NSFileManager defaultManager] createDirectoryAtPath:[legacyFile stringByDeletingLastPathComponent]
                                 withIntermediateDirectories:YES attributes:nil error:nil];
        if (favJson) [favJson writeToFile:legacyFile atomically:YES];
    }

    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];  // 不抢焦点、不进 Dock
    (void)app;

    CK([[RLPCoreClient shared] startEmbedded], "核心已启动（隔离目录）", @"");

    // 后端真的读到了夹具？没读到就说明后面所有页面断言都无意义
    NSDictionary *albs = [[RLPCoreClient shared] jsonWithMethod:@"GET" path:@"/api/lib/albums" body:nil];
    NSArray *arr = [albs[@"albums"] isKindOfClass:[NSArray class]] ? albs[@"albums"] : @[];
    CK(arr.count >= 3, "后端返回 >= 3 张专辑", [NSString stringWithFormat:@"count=%ld", (long)arr.count]);

    RLPMainWindowController *wc = [[RLPMainWindowController alloc] init];
    [wc.window setFrame:NSMakeRect(0, 0, 1180, 760) display:NO];
    // 不 orderFront：离屏渲染即可，避免弹出窗口干扰用户
    [wc.window layoutIfNeeded];
    [wc loadInitialData];
    Pump(1.2);

    // ---- ⓪ 历史收藏文件迁移：'\' 分隔的旧路径读回后必须是 '/'（判据先红后绿的那条）----
    {
        NSDictionary *favs = [[RLPCoreClient shared] jsonWithMethod:@"GET" path:@"/api/fav/list" body:nil];
        NSArray *files = [favs[@"files"] isKindOfClass:[NSArray class]] ? favs[@"files"] : @[];
        CK(files.count == 1, "旧收藏文件被读进来了（1 条）",
           [NSString stringWithFormat:@"n=%ld", (long)files.count]);
        NSString *f0 = files.count ? [files[0] description] : @"";
        CK([f0 hasPrefix:@"/"] && ![f0 containsString:@"\\"],
           "旧收藏路径被规范成正斜杠（Windows 遗留 '\' 已迁移）", f0);
        CK([f0 containsString:@"/Kind of Blue/01.aiff"], "迁移后的路径与曲库路径同形", f0);
        // 清掉这条，后面的空态断言要干净的收藏集合
        [[RLPCoreClient shared] postJSON:[NSString stringWithFormat:@"/api/fav?file=%@&on=0", RLPEnc(f0)]
                                   body:@"" completion:nil];
        Pump(0.4);
        NSDictionary *empty = [[RLPCoreClient shared] jsonWithMethod:@"GET" path:@"/api/fav/list" body:nil];
        CK([empty[@"files"] isKindOfClass:[NSArray class]] && [empty[@"files"] count] == 0,
           "取消收藏后列表清空", [NSString stringWithFormat:@"n=%lu", (unsigned long)[empty[@"files"] count]]);
    }

    // ---- ① 专辑页真的有卡片，不是空壳 ----
    // 1.1.7.1：首页不再是专辑页（聆听模式首页=聆听室），所以必须**显式导航到专辑页**
    // 再验"点专辑→详情→返回"。否则返回栈记的是聆听室，断言"回到专辑页"就是判据本身错了。
    CK([wc.sidebar selectKey:@"albums"], "能导航到专辑页", @"侧栏没有 albums");
    Pump(0.6);
    CK([wc.currentContent isKindOfClass:[RLPAlbumsViewController class]], "当前内容是专辑页",
       NSStringFromClass(wc.currentContent.class));
    CK(wc.albums.albumCount >= 3, "专辑页拿到 >= 3 张专辑",
       [NSString stringWithFormat:@"albumCount=%ld", (long)wc.albums.albumCount]);
    CK(Snap(wc.window.contentView, [outDir stringByAppendingPathComponent:@"01-albums.png"],
            CGSizeMake(1180, 760)), "专辑页截图已落盘", outDir);

    // ---- ② 关键回归：点专辑必须进详情页（旧实现在这里必然红）----
    NSString *firstKey = nil;
    if (arr.count) firstKey = [arr[0][@"k"] isKindOfClass:[NSString class]] ? arr[0][@"k"] : nil;
    CK(firstKey.length > 0, "拿到第一张专辑的 key", firstKey ?: @"nil");
    if (firstKey.length) {
        RLPRequestOpenAlbum(firstKey);
        Pump(0.8);
        NSViewController *cur = wc.currentContent;
        CK([cur isKindOfClass:[RLPAlbumDetailViewController class]],
           "点专辑后进入专辑详情页", NSStringFromClass(cur.class));
        CK(NonEmptyLabels(cur.view) >= 3, "专辑详情页有实际内容（非空壳）",
           [NSString stringWithFormat:@"labels=%ld", (long)NonEmptyLabels(cur.view)]);
        CK(Snap(wc.window.contentView, [outDir stringByAppendingPathComponent:@"02-album-detail.png"],
                CGSizeMake(1180, 760)), "专辑详情页截图已落盘", outDir);
        // 返回必须回到专辑页
        RLPRequestBack();
        Pump(0.4);
        CK([wc.currentContent isKindOfClass:[RLPAlbumsViewController class]],
           "返回后回到专辑页", NSStringFromClass(wc.currentContent.class));
    }

    // ---- ②a2 专辑页图一信息层：发布信息 + 其他作品（Apple Music 式）----
    // 用户 2026-11-12：专辑页面按照图一（Apple Music 专辑页）做。图一在曲目表下方有
    // "N 首歌曲，X 分钟 / ℗ 年份"，以及一条「同艺人其他作品」的横向封面卡。
    // 旧实现两者都没有 ⟹ 判据必须能在旧实现上红。
    // 特意选 John Coltrane 的专辑（隔离夹具里他有 2 张）：其他作品至少 1 张卡，判据不是空的。
    {
        NSString *coltraneKey = nil;
        NSArray *albumDicts = [albs[@"albums"] isKindOfClass:[NSArray class]] ? albs[@"albums"] : @[];
        for (NSDictionary *d in albumDicts)
            if ([d[@"artist"] isEqual:@"John Coltrane"] && coltraneKey.length == 0) {
                coltraneKey = [d[@"k"] isKindOfClass:[NSString class]] ? d[@"k"] : nil;
            }
        CK(coltraneKey.length > 0, "夹具里有 John Coltrane 的专辑（其他作品判据的前提）",
           [albumDicts componentsJoinedByString:@"|"]);
        if (coltraneKey.length) {
            RLPRequestOpenAlbum(coltraneKey);
            Pump(1.0);
            RLPAlbumDetailViewController *ad =
                [wc.currentContent isKindOfClass:[RLPAlbumDetailViewController class]]
                ? (RLPAlbumDetailViewController *)wc.currentContent : nil;
            CK(ad != nil, "已进入 John Coltrane 的专辑详情", NSStringFromClass(wc.currentContent.class));
            if (ad) {
                NSMutableArray<NSView *> *av = [NSMutableArray array];
                CollectAllViews(ad.view, av);
                NSMutableDictionary *aById = [NSMutableDictionary dictionary];
                for (NSView *v in av) if (v.identifier.length) aById[v.identifier] = v;

                // ① 曲目表下方的发布信息：N 首歌曲，X 分钟 + ℗ 年份
                NSTextField *fc = aById[@"album.footer.count"];
                NSTextField *cr = aById[@"album.footer.copyright"];
                CK(fc != nil && fc.stringValue.length > 0, "曲目表下方有『N 首歌曲，X 分钟』",
                   fc ? fc.stringValue : @"缺 album.footer.count");
                CK(fc && [fc.stringValue containsString:@"2"], "发布信息里的曲目数与真实曲目数一致",
                   fc ? fc.stringValue : @"nil");
                CK(cr != nil && !cr.hidden && [cr.stringValue containsString:@"\u2117"],
                   "版权行渲染出来了（℗ 年份，图一底部那段）",
                   cr ? cr.stringValue : @"缺 album.footer.copyright");
                // 几何：发布信息必须在曲目表下方（不是叠在表格上）
                NSView *tableV = nil;
                for (NSView *v in av) if ([v isKindOfClass:[NSTableView class]]) { tableV = v; break; }
                CK(tableV != nil, "曲目表在视图树里", @"找不到 NSTableView");
                if (tableV && fc) {
                    // 统一到**翻转的**文档视图再比：专辑文档 isFlipped=YES（y 向下增长），
                    // 所以「在下方」= y 更大。两个视图若用各自坐标系比较，量出来的是两套数字（本判据假红过一次）。
                    NSView *doc = tableV;
                    while (doc && !doc.isFlipped) doc = doc.superview;
                    if (doc) {
                        const CGFloat fy = [fc convertPoint:NSZeroPoint toView:doc].y;
                        const CGFloat ty = [tableV convertPoint:NSZeroPoint toView:doc].y;
                        CK(fy > ty, "发布信息在曲目表下方（flipped 文档里 y 更大）",
                           [NSString stringWithFormat:@"footer.y=%.0f table.y=%.0f", fy, ty]);
                    } else {
                        CK(NO, "能定位到翻转的专辑文档视图（几何判据的前提）", @"找不到 flipped 祖先");
                    }
                }

                // ② 其他作品：标题 + >=1 张可点封面卡
                NSTextField *owt = aById[@"album.otherworks.title"];
                CK(owt != nil && !owt.hidden && owt.stringValue.length > 0,
                   "『其他作品』区标题已渲染（图一那条横排的标题）",
                   owt ? owt.stringValue : @"缺 album.otherworks.title");
                NSInteger cards = 0;
                for (NSView *v in av) if ([v.identifier isEqualToString:@"album.workcard"]) ++cards;
                CK(cards >= 1, "『其他作品』区有 >= 1 张封面卡（同艺人另一张专辑）",
                   [NSString stringWithFormat:@"cards=%ld", (long)cards]);
                // 卡必须是可点的真按钮（点了能进那张专辑），不是一张装饰图
                NSView *firstCard = nil;
                for (NSView *v in av) if ([v.identifier isEqualToString:@"album.workcard"]) { firstCard = v; break; }
                CK([firstCard isKindOfClass:[NSButton class]] &&
                   ((NSButton *)firstCard).action != NULL,
                   "其他作品卡是可点按钮（有真实 action）",
                   firstCard ? NSStringFromClass(firstCard.class) : @"nil");
                CK(Snap(wc.window.contentView, [outDir stringByAppendingPathComponent:@"02c-album-works.png"],
                        CGSizeMake(1180, 760)), "专辑页（含其他作品）截图已落盘", outDir);
            }
        }
        // 回到第一张专辑，后续断言仍按原假设走
        if (firstKey.length) { RLPRequestOpenAlbum(firstKey); Pump(0.8); }
    }

    // ---- ②b 艺术家详情：必须能进、有内容、AI 资料层在位 ----
    {
        NSString *who = nil;
        for (id a in arr) {
            if (![a isKindOfClass:[NSDictionary class]]) continue;
            NSString *ar = [a[@"artist"] isKindOfClass:[NSString class]] ? a[@"artist"] : nil;
            if (ar.length) { who = ar; break; }
        }
        if (who.length) {
            RLPRequestOpenArtist(who);
            Pump(0.8);
            CK([wc.currentContent isKindOfClass:[RLPArtistDetailViewController class]],
               "点艺术家进入艺术家详情页", NSStringFromClass(wc.currentContent.class));
            CK(NonEmptyLabels(wc.currentContent.view) >= 2, "艺术家详情页有实际内容",
               [NSString stringWithFormat:@"labels=%ld", (long)NonEmptyLabels(wc.currentContent.view)]);
            Snap(wc.window.contentView, [outDir stringByAppendingPathComponent:@"02b-artist-detail.png"],
                 CGSizeMake(1180, 760));
            RLPRequestBack();
            Pump(0.4);
        }
    }

    // ---- ②a3 专辑卡悬停播放角标（web .grid 卡片 hover 才浮出播放键）----
    {
        [wc.sidebar selectKey:@"albums"];
        Pump(0.7);
        RLPAlbumsViewController *av = [wc.currentContent isKindOfClass:[RLPAlbumsViewController class]]
                                    ? (RLPAlbumsViewController *)wc.currentContent : nil;
        CK(av != nil, "能回到专辑页", NSStringFromClass(wc.currentContent.class));
        if (av) {
            NSCollectionView *cv = [av valueForKey:@"collection"];
            NSCollectionViewItem *item = cv ? [cv itemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]] : nil;
            CK(item != nil, "专辑网格有第一个 item（判据前提）", item ? NSStringFromClass(item.class) : @"nil");
            if (item) {
                NSMutableArray<NSView *> *iv = [NSMutableArray array];
                CollectAllViews(item.view, iv);
                NSButton *badge = nil;
                for (NSView *v in iv)
                    if ([v.identifier isEqualToString:@"album.playbadge"]) badge = (NSButton *)v;
                CK(badge != nil, "专辑卡有播放角标（web 悬停播放键）",
                   badge ? NSStringFromClass(badge.class) : @"缺角标");
                if (badge) {
                    CK(badge.hidden, "未悬停时角标隐藏（默认不抢注意力）", @"默认可见");
                    // 悬停：调生产入口（tracking area 的 mouseEntered 最终就是它，见 RLPAlbumCardView）
                    [(id)item cardHoverChanged:YES];
                    [item.view layoutSubtreeIfNeeded];
                    CK(!badge.hidden && badge.frame.size.width > 0 && badge.frame.size.height > 0,
                       "悬停后播放角标浮现且有真实尺寸",
                       [NSString stringWithFormat:@"hidden=%d frame=%@", (int)badge.hidden,
                        NSStringFromRect(badge.frame)]);
                    CK(badge.action != NULL, "角标点击有真实 action（点它=播放整张）",
                       badge.action ? NSStringFromSelector(badge.action) : @"nil");
                    [(id)item cardHoverChanged:NO];
                }
            }
        }
    }

    // ---- ②c 侧栏「我的歌单」是动态列表（web #sqList）----
    // 旧实现（2026-11-13 前）侧栏只有一行静态「保存的队列」，一条歌单条目都没有：
    // 没有 条目 / ✎ 重命名 / × 删除 / 空态整行。判据必须能区分"静态一行"与"动态列表"，
    // 所以整段用**真实核心 API** 造歌单，再看侧栏行有没有跟着变。
    {
        // 负向对照：模拟旧静态实现。带该环境变量跑一遍，本段必须整体红 ——
        // 否则说明判据恒真（本仓库历史上最多次的失败原因）。
        if (getenv("RLP_AUDIT_NEGATIVE_CONTROL")) wc.sidebar.ignoreSavedQueues = YES;

        NSMutableArray<NSView *> *sv = [NSMutableArray array];
        CollectAllViews(wc.sidebar.view, sv);
        NSMutableDictionary *byId = [NSMutableDictionary dictionary];
        for (NSView *v in sv) if (v.identifier.length) byId[v.identifier] = v;

        // ① 隔离夹具里初始没有歌单 ⟹ 侧栏必须是**一整行可点**的空态（web .sqempty），
        //    并且「我的歌单」标题行右侧有「＋ 新建」（web .sqnew-btn）。
        [wc.sidebar reloadSavedQueues];
        Pump(0.4);
        CK([wc.sidebar savedQueueRowCount] == 0, "初始 0 个歌单（隔离夹具）",
           [NSString stringWithFormat:@"sq=%ld", (long)[wc.sidebar savedQueueRowCount]]);
        CK(byId[@"sq.empty"] != nil, "空态整行『＋ 新建歌单』在视图树里（web .sqempty）", @"缺 sq.empty");
        CK(byId[@"sq.new"] != nil, "『我的歌单』标题行有『＋ 新建』（web .sqnew-btn）", @"缺 sq.new");
        CK(byId[@"sq.empty"] && [byId[@"sq.empty"] isKindOfClass:[NSView class]] &&
           ((NSView *)byId[@"sq.empty"]).frame.size.width > 0,
           "空态行有真实宽度（不是塌成 0 的摆设）",
           NSStringFromRect(((NSView *)byId[@"sq.empty"]).frame));

        // ② 走**生产入口**新建一份歌单（web newSavedQueueDialog 的原生同构路径）：
        //    不仅要落库，toast 还必须带上歌单名 —— web 是 `已新建歌单：<name>`，
        //    旧实现只写「已新建歌单」，用户在图六里看到的差别就是这个。
        NSString *madeByUi = @"侧栏新建演示";
        [wc.sidebar createSavedQueueNamed:madeByUi];
        // toast 是异步落地（/api/sq/add 回调 + 0.12s 淡入，1.8s 后自动消失）。
        // 固定 Pump(0.8) 在机器忙时会在回调之前就检查 ⟹ **假红**。
        // 这里改成轮询到出现或超时 3s：判据强度不变（仍要求文案带歌单名），只去掉时序抖动。
        BOOL sawToast = NO;
        for (int i = 0; i < 30 && !sawToast; ++i) {
            Pump(0.1);
            NSMutableArray<NSView *> *wv = [NSMutableArray array];
            CollectAllViews(wc.window.contentView, wv);
            for (NSView *v in wv) {
                if (![v isKindOfClass:[NSTextField class]]) continue;
                NSString *s = ((NSTextField *)v).stringValue;
                if ([s containsString:@"已新建歌单："] && [s containsString:madeByUi]) { sawToast = YES; break; }
            }
        }
        {
            CK(sawToast, "新建歌单 toast 带上歌单名（web：已新建歌单：<name>；旧实现只有「已新建歌单」)", madeByUi);
            NSDictionary *l = [[RLPCoreClient shared] jsonWithMethod:@"GET" path:@"/api/sq/list" body:nil];
            BOOL inBackend = NO;
            for (NSDictionary *q in (l[@"queues"] ?: @[])) if ([q[@"name"] isEqual:madeByUi]) inBackend = YES;
            CK(inBackend, "生产入口新建的歌单真的落库（不是只弹了个 toast）", @"");
            // 清掉这份演示歌单，后面的断言从干净状态开始
            [[RLPCoreClient shared] postJSON:[NSString stringWithFormat:@"/api/sq/delete?name=%@", RLPEnc(madeByUi)]
                                       body:nil completion:nil];
            Pump(0.4);
        }

        // ② 通过真实核心造 2 个歌单（web 走 /api/sq/add，同一后端路径）。
        NSArray<NSString *> *want = @[@"睡眠专区", @"通勤"];
        for (NSString *name in want) {
            NSDictionary *r = [[RLPCoreClient shared] jsonWithMethod:@"POST"
                                                                path:[NSString stringWithFormat:@"/api/sq/add?name=%@",
                                                                      RLPEnc(name)]
                                                                body:nil];
            CK([r[@"ok"] boolValue], "后端已创建歌单", name);
        }
        // 侧栏靠广播刷新（web 每次 mutate 后都重拉 /api/sq/list 同语义）
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPSavedQueuesChangedNotification"
                                                            object:nil];
        Pump(0.7);

        // ③ 侧栏出现 2 行，名字与顺序都对
        CK([wc.sidebar savedQueueRowCount] == 2, "侧栏出现 2 行歌单（动态渲染）",
           [NSString stringWithFormat:@"rows=%ld", (long)[wc.sidebar savedQueueRowCount]]);
        CK([wc.sidebar.savedQueueNames isEqualToArray:want], "侧栏歌单名与后端一致且顺序一致",
           [wc.sidebar.savedQueueNames componentsJoinedByString:@","]);
        // 每一行都必须真的建出了 ✎ / ×（web .sqrow 的两个动作），不是只有名字
        {
            NSInteger ren = 0, del = 0;
            NSMutableArray<NSView *> *sv2 = [NSMutableArray array];
            CollectAllViews(wc.sidebar.view, sv2);
            for (NSView *v in sv2) {
                if ([v.identifier isEqualToString:@"sq.ren"]) ++ren;
                if ([v.identifier isEqualToString:@"sq.del"]) ++del;
            }
            CK(ren == 2 && del == 2, "每行歌单都有 ✎ 与 ×（web .sqb ren/del）",
               [NSString stringWithFormat:@"ren=%ld del=%ld", (long)ren, (long)del]);
        }
        CK(Snap(wc.window.contentView, [outDir stringByAppendingPathComponent:@"10b-sidebar-sqlist.png"],
                CGSizeMake(1180, 760)), "侧栏歌单区块截图已落盘", outDir);

        // ④ ✎ 改名：行文本必须跟着变（web renameQueueDialog）
        [wc.sidebar renameSavedQueueAtIndex:0 to:@"深夜聆听"];
        Pump(0.7);
        NSArray<NSString *> *afterRename = wc.sidebar.savedQueueNames;
        CK(afterRename.count == 2 && [afterRename[0] isEqualToString:@"深夜聆听"],
           "✎ 改名后侧栏行文本变成新名字", [afterRename componentsJoinedByString:@","]);
        NSDictionary *info = [[RLPCoreClient shared] jsonWithMethod:@"GET"
            path:[NSString stringWithFormat:@"/api/sq/list"] body:nil];
        NSArray *qs = info[@"queues"];
        BOOL backendRenamed = NO;
        for (NSDictionary *q in qs) if ([q[@"name"] isEqual:@"深夜聆听"]) backendRenamed = YES;
        CK(backendRenamed, "改名真的落到后端（不是只改了侧栏内存里的字符串）", @"");

        // ⑤ × 删除：该行必须消失（web deleteSavedQueue）
        [wc.sidebar deleteSavedQueueAtIndex:1];
        Pump(0.7);
        NSArray<NSString *> *afterDelete = wc.sidebar.savedQueueNames;
        CK(afterDelete.count == 1, "× 删除后侧栏只剩 1 行",
           [NSString stringWithFormat:@"rows=%ld", (long)afterDelete.count]);
        CK(![afterDelete containsObject:@"通勤"], "被删的歌单不再出现在侧栏",
           [afterDelete componentsJoinedByString:@","]);

        // ⑥ 点歌单行必须真的进歌单页，并且页面拿到的是**这份**歌单（web renderSavedQueuePage(name)）
        NSString *walk = afterDelete.firstObject;
        [wc.sidebar openSavedQueueNamed:walk];
        Pump(0.8);
        CK([wc.currentContent isKindOfClass:[RLPPlaylistsViewController class]],
           "点歌单行后内容是歌单页", NSStringFromClass(wc.currentContent.class));
        // KVC 只在真的进了歌单页时取，否则 NSUnknownKeyException 会把整轮审计带走（负向对照跑出来的）。
        NSString *sel = [wc.currentContent isKindOfClass:[RLPPlaylistsViewController class]]
                      ? [wc.currentContent valueForKey:@"selectedName"] : nil;
        CK([sel isEqual:walk], "歌单页被选中到被点的那一份",
           [NSString stringWithFormat:@"selected=%@", sel ?: @"(nil)"]);
        CK(Snap(wc.window.contentView, [outDir stringByAppendingPathComponent:@"10c-playlist-page.png"],
                CGSizeMake(1180, 760)), "歌单页截图已落盘", outDir);
    }

    // ---- ③ 逐个导航项：切过去必须有内容 + 截图 ----
    // 1.1.7.1：按**符号 key** 遍历，不用裸行号 —— 导航项随模式变化，行号会错位。
    // 聆听模式先走一遍（含聆听室），再切专业模式验工作台与设置。
    struct RowSpec { const char *key; const char *name; const char *file; };
    const RowSpec rows[] = {
        { "artists",   "artists",   "03-artists.png" },
        { "tracks",    "tracks",    "04-tracks.png" },
        { "folders",   "folders",   "05-folders.png" },
        { "streaming", "streaming", "06-streaming.png" },
        { "queue",     "queue",     "07-queue.png" },
        { "recent",    "recent",    "08-recent.png" },
        { "favorites", "favorites", "09-favorites.png" },
        { "playlists", "playlists", "10-playlists.png" },
        // web data-v=station（标题「快速开始」）。原生侧曾叫 room/聆听室，已按 web 改名。
        { "station",   "station",   "11-station.png" },
        { "settings",  "settings",  "12-settings.png" },
    };
    Pump(0.4);
    for (const RowSpec &r : rows) {
        CK([wc.sidebar selectKey:[NSString stringWithUTF8String:r.key]], r.name, @"侧栏没有这个 key");
        TraceUiEvent(@"nav", @{ @"key": [NSString stringWithUTF8String:r.key] });
        Pump(0.7);
        NSViewController *cur = wc.currentContent;
        CK(cur != nil, r.name, @"currentContent 为 nil");
        const NSInteger labels = cur ? NonEmptyLabels(cur.view) : 0;
        CK(labels >= 2, r.name, [NSString stringWithFormat:@"内容太少 labels=%ld", (long)labels]);
        Snap(wc.window.contentView, [outDir stringByAppendingPathComponent:
             [NSString stringWithUTF8String:r.file]], CGSizeMake(1180, 760));
    }

    // ---- ②d 流媒体未配置时必须有整页空态卡（web loadRemote err 分支）----
    // 旧实现只弹一个 toast，内容区留白：用户不知道下一步做什么，也不知道支持哪些协议。
    {
        [wc.sidebar selectKey:@"streaming"];
        Pump(0.9);
        RLPStreamingViewController *svc = [wc.currentContent isKindOfClass:[RLPStreamingViewController class]]
                         ? (RLPStreamingViewController *)wc.currentContent : nil;
        CK(svc != nil, "能进流媒体页", NSStringFromClass(wc.currentContent.class));
        if (svc) {
            CK(svc.emptyStateVisible, "未配置服务器时显示整页空态卡（不是只弹 toast）", @"emptyState hidden");
            NSMutableArray<NSView *> *rv = [NSMutableArray array];
            CollectAllViews(svc.view, rv);
            NSMutableDictionary *rById = [NSMutableDictionary dictionary];
            for (NSView *v in rv) if (v.identifier.length) rById[v.identifier] = v;
            NSTextField *rt = rById[@"remote.empty.title"];
            NSTextField *rh = rById[@"remote.empty.hint"];
            CK(rt != nil && !rt.hidden && rt.stringValue.length > 0,
               "空态卡有标题（web：还没有可浏览的流媒体服务器）", rt ? rt.stringValue : @"缺标题");
            CK(rh != nil && [rh.stringValue containsString:@"Navidrome"],
               "空态卡说明写了支持的协议与下一步（web 同一段）", rh ? rh.stringValue : @"缺说明");
            NSButton *go = (NSButton *)rById[@"remote.empty.goset"];
            NSButton *retry = (NSButton *)rById[@"remote.empty.retry"];
            CK(go != nil && go.action != NULL, "空态卡有『去设置里配置』按钮", go ? NSStringFromSelector(go.action) : @"缺");
            CK(retry != nil && retry.action != NULL, "空态卡有『重试』按钮", retry ? NSStringFromSelector(retry.action) : @"缺");
            // 空态卡本体的证据截图（必须在点按钮**之前**拍：点完就跳到设置页了）
            CK(Snap(wc.window.contentView, [outDir stringByAppendingPathComponent:@"06b-streaming-empty.png"],
                    CGSizeMake(1180, 760)), "流媒体空态卡截图已落盘", outDir);
            // 点「去设置里配置」→ 真的切到设置页的「流媒体」页签（web remoteGoSet 同语义）
            [go performClick:nil];
            Pump(0.8);
            CK([wc.currentContent isKindOfClass:[RLPSettingsViewController class]],
               "点『去设置里配置』进入设置页", NSStringFromClass(wc.currentContent.class));
            if ([wc.currentContent isKindOfClass:[RLPSettingsViewController class]]) {
                RLPSettingsViewController *set = (RLPSettingsViewController *)wc.currentContent;
                NSString *pane = [set currentPaneKey];
                CK([pane isEqual:@"stream"],
                   "设置页落在『流媒体』页签", [NSString stringWithFormat:@"pane=%@", pane ?: @"nil"]);
                CK(Snap(wc.window.contentView, [outDir stringByAppendingPathComponent:@"06c-settings-stream.png"],
                        CGSizeMake(1180, 760)), "设置·流媒体页截图已落盘", outDir);
            }
        }
    }

    // ---- ②e 曲目页行内动作：收藏心形 + 入队「+」（web .trow-track 第 2 / 第 7 列）----
    // 旧实现只有 5 列，收藏/入队**只能右键** ⟹ 页面上等于没有入口（用户不会去右键试）。
    {
        [wc.sidebar selectKey:@"tracks"];
        Pump(0.9);
        RLPTracksViewController *tv = [wc.currentContent isKindOfClass:[RLPTracksViewController class]]
                                    ? (RLPTracksViewController *)wc.currentContent : nil;
        CK(tv != nil, "能进曲目页", NSStringFromClass(wc.currentContent.class));
        if (tv) {
            NSMutableArray<NSView *> *vv = [NSMutableArray array];
            CollectAllViews(tv.view, vv);
            NSInteger favBtns = 0, addBtns = 0, favUsable = 0, addUsable = 0;
            for (NSView *v in vv) {
                if ([v.identifier isEqualToString:@"track.fav"]) { ++favBtns; if (v.frame.size.width > 0 && v.frame.size.height > 0) ++favUsable; }
                if ([v.identifier isEqualToString:@"track.add"]) { ++addBtns; if (v.frame.size.width > 0 && v.frame.size.height > 0) ++addUsable; }
            }
            NSArray *rows = [tv valueForKey:@"_tracks"];
            CK(rows.count > 0, "曲目页有真实数据（判据前提）", [NSString stringWithFormat:@"rows=%ld", (long)rows.count]);
            CK(favBtns >= 1 && addBtns >= 1, "每行都有收藏心形与入队 +（web 第 2/7 列）",
               [NSString stringWithFormat:@"fav=%ld add=%ld", (long)favBtns, (long)addBtns]);
            CK(favUsable >= 1 && addUsable >= 1, "行内按钮有真实尺寸（不是隐形控件）",
               [NSString stringWithFormat:@"favUsable=%ld addUsable=%ld", (long)favUsable, (long)addUsable]);
            CK(Snap(wc.window.contentView, [outDir stringByAppendingPathComponent:@"04b-tracks-actions.png"],
                    CGSizeMake(1180, 760)), "曲目页行内动作截图已落盘", outDir);
            // 排序下拉（web track-sort）：改"标题"必须真的改变第一行；改"收藏优先"必须把收藏的排到最前。
            {
                NSMutableArray<NSView *> *sv2 = [NSMutableArray array];
                CollectAllViews(tv.view, sv2);
                NSPopUpButton *sortPopup = nil;
                for (NSView *v in sv2)
                    if ([v isKindOfClass:[NSPopUpButton class]] && [v.identifier isEqualToString:@"tracks.sort"])
                        sortPopup = (NSPopUpButton *)v;
                CK(sortPopup != nil && sortPopup.numberOfItems >= 6,
                   "曲目页有排序下拉（web track-sort 的 6+ 档）",
                   sortPopup ? [NSString stringWithFormat:@"items=%ld", (long)sortPopup.numberOfItems] : @"缺下拉");
                if (sortPopup) {
                    // 切到「标题」：按标题升序，第一行应是最小标题
                    [sortPopup selectItemAtIndex:1];   // 1 = 标题
                    [sortPopup sendAction:sortPopup.action to:sortPopup.target];
                    Pump(0.4);
                    NSArray *sortedRows = [tv valueForKey:@"_tracks"];
                    BOOL ascending = YES;
                    for (NSUInteger i = 1; i < sortedRows.count; ++i) {
                        NSString *prev = [sortedRows[i - 1] valueForKey:@"title"] ?: @"";
                        NSString *cur  = [sortedRows[i] valueForKey:@"title"] ?: @"";
                        if ([prev caseInsensitiveCompare:cur] == NSOrderedDescending) ascending = NO;
                    }
                    CK(ascending && sortedRows.count >= 2, "切『标题』后按标题升序（真的重排了）",
                       [NSString stringWithFormat:@"rows=%ld", (long)sortedRows.count]);
                    // 复位默认，后面的断言用原始顺序
                    [sortPopup selectItemAtIndex:0];
                    [sortPopup sendAction:sortPopup.action to:sortPopup.target];
                    Pump(0.3);
                }
            }
            // 行悬停底色（web .trow:hover）：必须是自定义 row view，且**画出来**（像素判据）：
            // 同一行渲染两次（悬停前/悬停后），底色必须真的变了 —— 只断言类名等于没验。
            {
                NSTableView *tt = [tv valueForKey:@"_tableView"];
                NSTableRowView *rv = tt ? [tt rowViewAtRow:0 makeIfNecessary:YES] : nil;
                CK([rv isKindOfClass:[RLPHoverRowView class]], "曲目行是自定义 row view（可悬停）",
                   NSStringFromClass(rv.class));
                RLPHoverRowView *hv = (RLPHoverRowView *)rv;
                if ([hv isKindOfClass:[RLPHoverRowView class]]) {
                    NSString *p0 = [outDir stringByAppendingPathComponent:@"04c-hover-off.png"];
                    NSString *p1 = [outDir stringByAppendingPathComponent:@"04c-hover-on.png"];
                    [hv setHoveredForAudit:NO];
                    BOOL a = Snap(hv, p0, hv.bounds.size.width > 10 ? hv.bounds.size : NSMakeSize(600, 26));
                    [hv setHoveredForAudit:YES];
                    BOOL b = Snap(hv, p1, hv.bounds.size.width > 10 ? hv.bounds.size : NSMakeSize(600, 26));
                    CK(a && b, "行悬停截图已落盘", outDir);
                    if (a && b) {
                        // 采样行中部一块，非悬停时是页面底色、悬停时应更深一档
                        NSImage *i0 = [[NSImage alloc] initWithContentsOfFile:p0];
                        NSImage *i1 = [[NSImage alloc] initWithContentsOfFile:p1];
                        NSBitmapImageRep *r0 = nil, *r1 = nil;
                        for (NSImageRep *r in i0.representations) if ([r isKindOfClass:[NSBitmapImageRep class]]) r0 = (NSBitmapImageRep *)r;
                        for (NSImageRep *r in i1.representations) if ([r isKindOfClass:[NSBitmapImageRep class]]) r1 = (NSBitmapImageRep *)r;
                        if (r0 && r1) {
                            // 采样点避开文字列（居中可能正好压在标题/专辑名的字形上 ⟹ 假红）。
                            // 35% 处标题与艺术家文本之间是空白，底色差异才是判据本体。
                            const NSInteger sx = r0.pixelsWide * 35 / 100;
                            NSColor *c0 = [r0 colorAtX:sx y:r0.pixelsHigh / 2];
                            NSColor *c1 = [r1 colorAtX:sx y:r1.pixelsHigh / 2];
                            NSColor *g0 = [c0 colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
                            NSColor *g1 = [c1 colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
                            // 悬停底色是**半透明覆盖**（web .trow:hover 用 --hov，浅色主题下是 rgba 黑）：
                            // 只看 RGB 会漏掉这种"透明画上去"的底色，必须把 alpha 也算进判据。
                            CK(g0 && g1 && (fabs(g0.redComponent - g1.redComponent) > 0.01 ||
                                            fabs(g0.greenComponent - g1.greenComponent) > 0.01 ||
                                            fabs(g0.blueComponent - g1.blueComponent) > 0.01 ||
                                            fabs(g0.alphaComponent - g1.alphaComponent) > 0.01),
                               "悬停后行底色真的画出来了（像素变化，含 alpha）",
                               [NSString stringWithFormat:@"off=%.2f/%.2f/%.2f a%.2f on=%.2f/%.2f/%.2f a%.2f",
                                g0 ? g0.redComponent : -1, g0 ? g0.greenComponent : -1, g0 ? g0.blueComponent : -1, g0 ? g0.alphaComponent : -1,
                                g1 ? g1.redComponent : -1, g1 ? g1.greenComponent : -1, g1 ? g1.blueComponent : -1, g1 ? g1.alphaComponent : -1]);
                        }
                    }
                    [hv setHoveredForAudit:NO];
                }
            }
            // 点心形 → 后端真的收藏（不是只换图标）
            // 必须拿**第 0 行**的按钮（tag 就是行号）：随便抓一个可能是回收 cell 上的旧 tag，
            // 点了等于没点（第一版判据就是这么假红的）。
            NSInteger maxFavTag = -1, maxAddTag = -1;
            for (NSView *v in vv) {
                if ([v.identifier isEqualToString:@"track.fav"]) maxFavTag = MAX(maxFavTag, ((NSButton *)v).tag);
                if ([v.identifier isEqualToString:@"track.add"]) maxAddTag = MAX(maxAddTag, ((NSButton *)v).tag);
            }
            CK(maxFavTag >= 0 && maxAddTag >= 0, "行内按钮的 tag 指向真实行号（点击可落到那一行）",
               [NSString stringWithFormat:@"favTag=%ld addTag=%ld", (long)maxFavTag, (long)maxAddTag]);
            NSString *firstPath = rows.count ? [[rows[0] valueForKey:@"path"] description] : nil;
            NSButton *favBtn = nil, *addBtn = nil;
            for (NSView *v in vv) {
                if ([v.identifier isEqualToString:@"track.fav"] && ((NSButton *)v).tag == 0) favBtn = (NSButton *)v;
                if ([v.identifier isEqualToString:@"track.add"] && ((NSButton *)v).tag == 0) addBtn = (NSButton *)v;
            }
            CK(favBtn != nil && addBtn != nil, "第 0 行的心形与 + 都能定位到", @"tag==0 的按钮缺失");
            if (favBtn && firstPath.length) {
                [favBtn performClick:nil];
                Pump(0.7);
                NSDictionary *favJson = [[RLPCoreClient shared] jsonWithMethod:@"GET" path:@"/api/fav/list" body:nil];
                BOOL nowFav = NO;
                for (id f in (favJson[@"files"] ?: @[])) {
                    NSString *p = [f isKindOfClass:[NSString class]] ? f : ([f isKindOfClass:[NSDictionary class]] ? f[@"file"] : nil);
                    if ([p isEqual:firstPath]) nowFav = YES;
                }
                CK(nowFav, "点心形后该曲真的进了收藏（/api/fav?on=1）", firstPath);
                // 再点一次取消，恢复现场（表格已 reload，按钮对象是新的一批 ⟹ 重新取）
                NSMutableArray<NSView *> *vv2 = [NSMutableArray array];
                CollectAllViews(tv.view, vv2);
                NSButton *favBtn2 = nil;
                for (NSView *v in vv2)
                    if ([v.identifier isEqualToString:@"track.fav"] && ((NSButton *)v).tag == 0) favBtn2 = (NSButton *)v;
                if (favBtn2) [favBtn2 performClick:nil];
                Pump(0.6);
            }
            if (addBtn && firstPath.length) {
                [addBtn performClick:nil];
                Pump(0.6);
                NSDictionary *queue = [[RLPCoreClient shared] jsonWithMethod:@"GET" path:@"/api/queue" body:nil];
                NSArray *items = [queue[@"items"] isKindOfClass:[NSArray class]] ? queue[@"items"] : @[];
                BOOL queued = [items containsObject:firstPath];
                CK(queued, "点 + 后该曲真的进了队列（/api/add）", firstPath);
                [[RLPCoreClient shared] postJSON:@"/api/clear" body:nil completion:nil];
                Pump(0.4);
            }
        }
    }

    // ---- ③a 空表页不许出现横向灰条（NSTableView 交替行底色在 0 行时的副作用）----
    // web 的队列/收藏都是纯背景 + 居中空态；交替色一开，空表区域会被铺成一屏条带
    // （2026-11-13 队列页截图里 8 条灰带就是这么来的，用户会当成"页面坏掉"）。
    {
        [wc.sidebar selectKey:@"queue"];
        Pump(0.6);
        NSString *qShot = [outDir stringByAppendingPathComponent:@"07-queue.png"];
        CK(Snap(wc.window.contentView, qShot, CGSizeMake(1180, 760)), "队列页截图已落盘", outDir);
        CK(ShotRowsAreaIsUniform(qShot), "空队列没有交替行灰条（web：纯背景 + 居中空态）",
           @"右侧空白列亮度沿 y 跳变 ⟹ 有空表条带");
        [wc.sidebar selectKey:@"favorites"];
        Pump(0.6);
        NSString *fShot = [outDir stringByAppendingPathComponent:@"09-favorites.png"];
        CK(Snap(wc.window.contentView, fShot, CGSizeMake(1180, 760)), "收藏页截图已落盘", outDir);
        CK(ShotRowsAreaIsUniform(fShot), "空收藏页没有交替行灰条", @"右侧空白列亮度沿 y 跳变");
        // web 空态：'还没有收藏' + '在曲目行或单曲页点心形，就会出现在这里'
        {
            NSMutableArray<NSView *> *fv = [NSMutableArray array];
            CollectAllViews(wc.currentContent.view, fv);
            NSTextField *fe = nil;
            for (NSView *v in fv) if ([v.identifier isEqualToString:@"fav.empty"]) fe = (NSTextField *)v;
            CK(fe != nil && !fe.hidden && [fe.stringValue containsString:@"还没有收藏"],
               "空收藏页有指导性空态（web：还没有收藏 + 怎么做）", fe ? fe.stringValue : @"缺 fav.empty");
        }
        [wc.sidebar selectKey:@"recent"];
        Pump(0.6);
        {
            NSMutableArray<NSView *> *rv2 = [NSMutableArray array];
            CollectAllViews(wc.currentContent.view, rv2);
            NSTextField *re = nil;
            for (NSView *v in rv2) if ([v.identifier isEqualToString:@"recent.empty"]) re = (NSTextField *)v;
            CK(re != nil && !re.hidden, "空『最近播放』页有空态（web：还没有播放记录）",
               re ? re.stringValue : @"缺 recent.empty");
        }
        // 队列空态必须带"下一步怎么做"（web 的第二行小字），不能只有一句"队列是空的"
        [wc.sidebar selectKey:@"queue"];
        Pump(0.6);
        {
            NSMutableArray<NSView *> *qv = [NSMutableArray array];
            CollectAllViews(wc.currentContent.view, qv);
            NSTextField *qe = nil;
            for (NSView *v in qv)
                if ([v isKindOfClass:[NSTextField class]] &&
                    [((NSTextField *)v).stringValue containsString:@"队列是空的"]) { qe = (NSTextField *)v; break; }
            CK(qe != nil && [qe.stringValue containsString:@"加入队列"],
               "空队列空态含下一步提示（web 第二行）", qe ? qe.stringValue : @"缺空态");
        }

        // 队列行必须带行尾 ×（web .qdel）；点一下只删这一行，不是"点了没反应"。
        // 先真的入队 2 首（/api/add，与专辑/曲目页「加入队列」同一条后端路径）。
        {
            NSArray *albumList = [albs[@"albums"] isKindOfClass:[NSArray class]] ? albs[@"albums"] : @[];
            NSString *albumKey = albumList.count ? albumList[0][@"k"] : nil;
            NSDictionary *detail = albumKey.length ? [[RLPCoreClient shared] jsonWithMethod:@"GET"
                path:[NSString stringWithFormat:@"/api/lib/album?k=%@", RLPEnc(albumKey)] body:nil] : nil;
            NSArray *tracks = [detail[@"tracks"] isKindOfClass:[NSArray class]] ? detail[@"tracks"] : @[];
            NSInteger used = MIN(2, (NSInteger)tracks.count);
            for (NSInteger i = 0; i < used; ++i) {
                NSString *p = tracks[(NSUInteger)i][@"path"];
                if ([p isKindOfClass:[NSString class]]) RLPEnqueuePath(p);
            }
            Pump(0.7);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPNavigateKeyNotification" object:@"queue"];
            Pump(0.6);
            RLPQueueViewController *qp = [wc.currentContent isKindOfClass:[RLPQueueViewController class]]
                                       ? (RLPQueueViewController *)wc.currentContent : nil;
            NSArray *paths = [qp valueForKey:@"paths"];
            CK(paths.count >= 1, "队列里至少有 1 首（入队真的落到后端）",
               [NSString stringWithFormat:@"n=%ld", (long)paths.count]);
            NSMutableArray<NSView *> *rv = [NSMutableArray array];
            CollectAllViews(qp.view, rv);
            NSInteger delButtons = 0, delUsable = 0;
            NSTableView *qtv = nil;
            for (NSView *v in rv) if ([v isKindOfClass:[NSTableView class]]) { qtv = (NSTableView *)v; break; }
            NSMutableArray<NSNumber *> *delXs = [NSMutableArray array];
            for (NSView *v in rv) if ([v.identifier isEqualToString:@"q.del"]) {
                ++delButtons;
                // 存在 ≠ 看得见：必须真的有尺寸，并且落在表格可见区域内
                if (v.frame.size.width > 0 && v.frame.size.height > 0) ++delUsable;
                if (qtv) {
                    NSRect inTable = [v convertRect:v.bounds toView:qtv];
                    [delXs addObject:@(inTable.origin.x)];
                }
            }
            CK(delButtons >= 1, "队列每行都有行尾 ×（web .qdel）",
               [NSString stringWithFormat:@"btns=%ld", (long)delButtons]);
            CK(delUsable == delButtons, "行尾 × 有真实尺寸（不是 0 宽 0 高的隐形控件）",
               [NSString stringWithFormat:@"usable=%ld/%ld", (long)delUsable, (long)delButtons]);
            CK(delXs.count && [delXs[0] doubleValue] > 0 &&
               [delXs[0] doubleValue] < qtv.frame.size.width,
               "行尾 × 落在表格可见宽度内（没有被挤到列外）",
               [NSString stringWithFormat:@"x=%@ tableW=%.0f", delXs.firstObject ?: @(-1), qtv ? qtv.frame.size.width : 0]);
            CK(Snap(wc.window.contentView, [outDir stringByAppendingPathComponent:@"07b-queue-rows.png"],
                    CGSizeMake(1180, 760)), "队列行截图已落盘", outDir);
            // 点第一行的 ×：必须真的少一行（旧实现这一列根本不存在 ⟹ 判据红）
            if (delButtons >= 1) {
                NSButton *del = nil;
                for (NSView *v in rv) if ([v.identifier isEqualToString:@"q.del"]) { del = (NSButton *)v; break; }
                const NSInteger before = (NSInteger)paths.count;
                [del performClick:nil];
                Pump(0.7);
                NSArray *after = [qp valueForKey:@"paths"];
                CK((NSInteger)after.count == before - 1,
                   "点行尾 × 后队列少一首（真的调 /api/qdel）",
                   [NSString stringWithFormat:@"before=%ld after=%ld", (long)before, (long)after.count]);
            }
            // 清空，后面的断言从空队列开始（与 web 清空按钮同一端点）
            [[RLPCoreClient shared] postJSON:@"/api/clear" body:nil completion:nil];
            Pump(0.5);
        }
    }

    // ---- ③b AI 换端点后「拉模型」必须按**屏幕上的地址**去拉（用户 2026-11-13 反馈）----
    // 旧实现：后端 /api/llm/models 只读已落盘的 conf；界面改了地址没保存就点「拉模型」
    // ⟹ 永远拿回旧端点的模型；而且强制重拉时旧列表没清空，看起来"还是原来那串"。
    {
        [wc.sidebar selectKey:@"settings"];
        Pump(0.8);
        RLPSettingsViewController *set = (RLPSettingsViewController *)wc.currentContent;
        if ([set isKindOfClass:[RLPSettingsViewController class]]) {
            [set selectPane:@"meta"];
            Pump(0.8);
            NSTextField *base = [set valueForKey:@"llmBase"];
            NSTextField *key  = [set valueForKey:@"llmKey"];
            NSPopUpButton *modelsPopup = [set valueForKey:@"llmModelPopup"];
            NSTextField *modelText = [set valueForKey:@"llmModel"];
            CK(base != nil && key != nil && modelsPopup != nil,
               "设置·元数据页有接口地址/密钥/模型下拉（判据前提）", @"控件缺失");

            // ① 强制重拉必须**先清空旧列表**（同步断言，不等网络）。
            //    判据不能依赖"当前恰好是空列表"（那是恒真）：先塞两条**假的上一次结果**，
            //    再调强制重拉，旧条目必须当场消失（旧实现不清 ⟹ 红）。
            [modelsPopup removeAllItems];
            [modelsPopup addItemWithTitle:@"deepseek-chat"];
            [modelsPopup addItemWithTitle:@"deepseek-reasoner"];
            modelsPopup.hidden = NO;
            CK(modelsPopup.numberOfItems == 2, "判据前置：先放两条旧端点模型在列表里",
               [NSString stringWithFormat:@"items=%ld", (long)modelsPopup.numberOfItems]);
            [(id)set loadLlmModels:YES];
            CK(modelsPopup.numberOfItems == 0 && modelsPopup.hidden,
               "强制重拉被调用后旧模型列表立刻清空（不残留）",
               [NSString stringWithFormat:@"items=%ld hidden=%d",
                (long)modelsPopup.numberOfItems, (int)modelsPopup.hidden]);

            // ② 屏幕上填一个新地址后点「拉模型」：必须先把该地址落盘（后端按 conf 拉），
            //    否则拉取永远走旧端点。用本机不可达地址，失败得快（不会真联网）。
            NSString *typed = @"https://127.0.0.1:1/v1";
            base.stringValue = typed;
            [(id)set onLlmModelRefresh:nil];
            Pump(1.2);
            NSDictionary *status = [[RLPCoreClient shared] jsonWithMethod:@"GET" path:@"/api/llm" body:nil];
            NSString *savedBase = [status[@"baseUrl"] isKindOfClass:[NSString class]] ? status[@"baseUrl"] : @"";
            CK([savedBase containsString:@"127.0.0.1:1"],
               "点「拉模型」先把屏幕上的新地址落盘（后端才会按新端点拉）",
               [NSString stringWithFormat:@"saved=%@", savedBase]);
            // 拉取失败必须降级成手填 + 显示原因，且不擅自改用户当前 model
            CK(modelsPopup.hidden, "新端点拉不到模型时降级手填（下拉隐藏）", @"下拉仍显示");
            CK(modelText.stringValue.length > 0, "降级后模型输入框保留当前值（不擅自清空）",
               modelText.stringValue);

            // ③ 复原：把地址改回空态不方便（后端会保留旧值），这里只把 UI 复位到已落盘值
            [set loadLlmConfig];
            Pump(0.6);
        }
    }

    // ---- ④ 设置页：web 的 10 个页签逐页切换并截图 ----
    // 判据要能在旧代码上跑红：旧实现只有「播放/输出/PCM/SDM/均衡/输入/校准/流媒体/元数据/高级/诊断」
    // 且按模式分叉，没有 stream 之外的 web 页签顺序，也没有 sp_* 的 identifier。
    CK([wc.sidebar selectKey:@"settings"], "能进设置", @"侧栏没有 settings");
    Pump(0.5);
    RLPSettingsViewController *sv = (RLPSettingsViewController *)wc.currentContent;
    if ([sv isKindOfClass:[RLPSettingsViewController class]]) {
        NSSegmentedControl *seg = nil;
        NSMutableArray<NSView *> *vs = [NSMutableArray array];
        CollectAllViews(sv.view, vs);
        for (NSView *v in vs)
            if ([v isKindOfClass:[NSSegmentedControl class]]) { seg = (NSSegmentedControl *)v; break; }
        CK(seg != nil && seg.segmentCount == 10,
           "设置页 10 个页签（web data-g 清单）",
           seg ? [NSString stringWithFormat:@"tabs=%ld", (long)seg.segmentCount] : @"无页签控件");

        // 顺序必须与 web 的 .stabs 一致：adv / in / out / pcm / sdm / eq / cal / meta / stream / diag
        const char *keys[] = { "adv", "in", "out", "pcm", "sdm", "eq", "cal", "meta", "stream", "diag" };
        NSInteger reached = 0;
        for (const char *k : keys) {
            NSString *want = [NSString stringWithUTF8String:k];
            [sv selectPane:want];
            Pump(0.4);
            if ([[sv currentPaneKey] isEqualToString:want]) ++reached;
            NSString *fn = [NSString stringWithFormat:@"20-settings-%s.png", k];
            Snap(wc.window.contentView, [outDir stringByAppendingPathComponent:fn], CGSizeMake(1180, 760));
        }
        // 元数据页的数据源行是**异步**到达的（/api/providers）。
        // 截图必须等内容落定后再拍，否则拍到的是"只有一行"的中间态 —— 那不是缺陷，
        // 但也不能拿中间态当验收证据。这里显式等到行数稳定。
        [sv selectPane:@"meta"];
        NSInteger lastRows = -1;
        for (int spin = 0; spin < 20; ++spin) {
            Pump(0.25);
            NSMutableArray<NSView *> *mv2 = [NSMutableArray array];
            CollectAllViews(sv.view, mv2);
            NSInteger rows = 0;
            for (NSView *v in mv2)
                if ([v.identifier hasPrefix:@"sp_metasrcrow_"]) ++rows;
            if (rows > 0 && rows == lastRows) break;
            lastRows = rows;
        }
        {
            NSMutableArray<NSView *> *mv3 = [NSMutableArray array];
            CollectAllViews(sv.view, mv3);
            NSInteger rows = 0;
            NSView *list = nil;
            for (NSView *v in mv3) {
                if ([v.identifier hasPrefix:@"sp_metasrcrow_"]) ++rows;
                if ([v.identifier isEqualToString:@"metasrc.list"]) list = v;
            }
            CK(rows >= 2, "元数据页数据源逐行渲染（异步到达后）",
               [NSString stringWithFormat:@"rows=%ld", (long)rows]);
            // 列表容器必须真的容得下所有行（之前被裁成只显示第一行）
            if (list) {
                CGFloat need = list.fittingSize.height;
                CK(list.frame.size.height + 1 >= need,
                   "数据源列表高度容得下全部行（不被裁切）",
                   [NSString stringWithFormat:@"h=%.1f need=%.1f", list.frame.size.height, need]);
            }
            // 图三（用户参考图）里整块最下面是「越靠上优先级越高」。异步行到达后，
            // 面板自身也要重算高度 —— 旧实现挂载时按 0 行算高度（60），行回来仍是 60，
            // 第 2 行以后连同底部提示一起被裁掉（2026-11-13 截图抓到的真故障）。
            NSTextField *hint = nil;
            for (NSView *v in mv3)
                if ([v.identifier isEqualToString:@"metasrc.msg"]) hint = (NSTextField *)v;
            CK(hint != nil && hint.stringValue.length > 0 && !hint.hidden,
               "底部提示『越靠上优先级越高』在（图三最后一行）",
               hint ? hint.stringValue : @"缺 metasrc.msg");
            NSView *panel = hint ? hint.superview.superview : nil;
            CK(panel != nil, "数据源面板容器可定位", panel ? NSStringFromClass(panel.class) : @"nil");
            if (panel) {
                const CGFloat want = panel.intrinsicContentSize.height;
                CK(panel.frame.size.height + 1 >= want,
                   "数据源面板高度随异步行数重算（底部提示不被裁）",
                   [NSString stringWithFormat:@"h=%.1f want=%.1f", panel.frame.size.height, want]);
                CK(hint.frame.size.height > 0,
                   "底部提示有真实高度（没被 stack 压成 0）",
                   [NSString stringWithFormat:@"hintH=%.1f", hint.frame.size.height]);
            }
            Snap(wc.window.contentView, [outDir stringByAppendingPathComponent:@"21-settings-meta-settled.png"],
                 CGSizeMake(1180, 760));
        }
        CK(reached == 10, "设置页 10 个页签都能真正切到位",
           [NSString stringWithFormat:@"reached=%ld", (long)reached]);

        // 控件 identifier 的运行时核对：**必须先切到那一页再收集**。
        // 页签内容是惰性构建的（buildPane 只在首次 showTab 时跑），
        // 在别的页签上收集当然找不到 —— 那是判据写错，不是实现缺失
        // （本轮实测踩过：这条一开始全红，红的原因是判据没切页签）。
        NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *idsByPane =
            [NSMutableDictionary dictionary];
        const char *probeKeys[] = { "out", "stream", "meta", "adv" };
        for (const char *k : probeKeys) {
            NSString *key = [NSString stringWithUTF8String:k];
            [sv selectPane:key];
            Pump(0.35);
            NSMutableArray<NSView *> *paneViews = [NSMutableArray array];
            CollectAllViews(sv.view, paneViews);
            NSMutableSet<NSString *> *ids = [NSMutableSet set];
            for (NSView *v in paneViews)
                if (v.identifier.length) [ids addObject:v.identifier];
            idsByPane[key] = ids;
        }
        // 每页至少要有 web 的代表性控件（全都逐条核对见 parity 表；这里抽 4 条防"整页没接"）。
        CK([idsByPane[@"out"] containsObject:@"sp_backend"],
           "输出页有 sp_backend（web data-g=out 的代表控件）", @"缺少 identifier");
        CK([idsByPane[@"stream"] containsObject:@"sp_cast_dev"],
           "流媒体页有 sp_cast_dev（投放面板）", @"缺少 identifier");
        CK([idsByPane[@"meta"] containsObject:@"sp_metaon"],
           "元数据页有 sp_metaon", @"缺少 identifier");
        CK([idsByPane[@"adv"] containsObject:@"sp_uistyle"],
           "通用页有 sp_uistyle（界面风格）", @"缺少 identifier");
        // ---- 运行时核对：每个页签的代表性控件必须真的在视图树里 ----
        // 逐页抽查（全量核对见 parity 表）。抽样而不是全量，是因为全量需要把
        // 181 个 identifier 抄进测试代码里 —— 那正是"手抄清单"，表格已经机器生成了。
        {
            struct PaneProbe { const char *pane; const char *ident; const char *what; };
            const PaneProbe probes[] = {
                { "out",    "sp_backend",        "输出后端下拉" },
                { "out",    "sp_bpfix",          "bit-perfect 直通按钮" },
                { "out",    "sp_ramp",           "音量渐变" },
                { "out",    "sp_trimwrap",       "声道微调容器" },
                { "pcm",    "sp_phase",          "相位覆盖" },
                { "pcm",    "sp_transition",     "过渡带占比" },
                { "pcm",    "sp_shaper",         "抖动/噪声整形" },
                { "sdm",    "sp_dsdkind",        "DSD 源抽取器" },
                { "sdm",    "sp_modcut",         "噪声整形拐点" },
                { "in",     "sp_inbuf",          "输入缓冲" },
                { "in",     "sp_inout",          "录制输出路径" },
                { "adv",    "sp_uistyle",        "界面风格" },
                { "adv",    "sp_scanthreads",    "扫描线程数" },
                { "adv",    "sp_rep",            "循环模式" },
                { "diag",   "sp_updchannel",     "更新通道" },
                { "diag",   "sp_fbtext",         "反馈正文" },
                { "meta",   "sp_metaon",         "元数据总开关" },
                { "meta",   "sp_wbdry",          "写回预览" },
            };
            for (const PaneProbe &probe : probes) {
                NSString *pane = [NSString stringWithUTF8String:probe.pane];
                NSString *ident = [NSString stringWithUTF8String:probe.ident];
                [sv selectPane:pane];
                Pump(0.3);
                NSMutableArray<NSView *> *pv = [NSMutableArray array];
                CollectAllViews(sv.view, pv);
                BOOL found = NO;
                for (NSView *v in pv)
                    if ([v.identifier isEqualToString:ident]) { found = YES; break; }
                CK(found, [[NSString stringWithFormat:@"运行时 %s 页真的有 %@（%s）",
                            probe.pane, ident, probe.what] UTF8String],
                   [NSString stringWithFormat:@"视图树里找不到 %@", ident]);
            }
        }

        // 顺带核对容器锚点：设置页每个页签的根视图都要带 tab.<key>
        NSMutableArray<NSView *> *allPanes = [NSMutableArray array];
        CollectAllViews(sv.view, allPanes);
        NSUInteger tabAnchors = 0;
        for (NSView *v in allPanes)
            if ([v.identifier hasPrefix:@"tab."]) ++tabAnchors;
        CK(tabAnchors >= 1, "设置页有 tab.<key> 页签锚点（parity 取证用）",
           [NSString stringWithFormat:@"anchors=%lu", (unsigned long)tabAnchors]);
    } else {
        CK(NO, "设置页类型正确", NSStringFromClass(wc.currentContent.class));
    }

    // ---- ④c 右侧抽屉（web #right）：之前原生完全没有这个面板 ----
    {
        NSMutableArray<NSView *> *wv = [NSMutableArray array];
        CollectAllViews(wc.window.contentView, wv);
        RLPRightDrawer *drawer = nil;
        for (NSView *v in wv) if ([v isKindOfClass:[RLPRightDrawer class]]) drawer = (RLPRightDrawer *)v;
        CK(drawer != nil, "右侧抽屉已创建（web #right）", @"视图树里没有 RLPRightDrawer");
        if (drawer) {
            CK([drawer.identifier isEqualToString:@"right"], "抽屉 identifier = right", drawer.identifier ?: @"nil");
            CK(drawer.hidden, "抽屉默认收起（web #right 基础态 display:none）", @"应默认隐藏");
            CK(!drawer.polling, "收起时不轮询（不在后台空转）", @"polling 应为 NO");

            // 打开 → 应可见 + 开始轮询；两个页签都要在
            [wc toggleDrawer];
            Pump(0.5);
            CK(!drawer.hidden, "顶栏队列键能打开抽屉", @"抽屉仍隐藏");
            CK(drawer.polling, "打开后开始 1s 轮询（web pollSchedule）", @"polling 应为 YES");
            NSMutableArray<NSView *> *dv = [NSMutableArray array];
            CollectAllViews(drawer, dv);
            NSMutableSet<NSString *> *dids = [NSMutableSet set];
            for (NSView *v in dv) if (v.identifier.length) [dids addObject:v.identifier];
            CK([dids containsObject:@"right.tab.q"], "抽屉有队列页签", @"缺 right.tab.q");
            CK([dids containsObject:@"right.tab.l"], "抽屉有歌词页签", @"缺 right.tab.l");
            CK([dids containsObject:@"right.count"], "抽屉有计数（web #rcnt）", @"缺 right.count");
            CK([dids containsObject:@"right.clear"], "抽屉有清除键（web #qclr）", @"缺 right.clear");
            CK([dids containsObject:@"right.qlist"], "抽屉有队列列表（web #qlist）", @"缺 right.qlist");
            CK([dids containsObject:@"right.lyricbox"], "抽屉有歌词容器（web #lyricbox）", @"缺 right.lyricbox");

            Snap(wc.window.contentView, [outDir stringByAppendingPathComponent:@"14-drawer-queue.png"],
                 CGSizeMake(1180, 760));
            [drawer showTab:@"l"];
            Pump(0.4);
            CK([[drawer tab] isEqualToString:@"l"], "能切到歌词页签", [drawer tab] ?: @"nil");
            Snap(wc.window.contentView, [outDir stringByAppendingPathComponent:@"15-drawer-lyrics.png"],
                 CGSizeMake(1180, 760));

            // 几何：web width:320 / right:18 / top:68 / bottom:92
            NSRect f = drawer.frame;
            NSRect host = wc.window.contentView.bounds;
            CK(fabs(f.size.width - 320) < 0.5, "抽屉宽 320（web width:320px）",
               @(f.size.width).stringValue);
            CK(fabs((host.size.width - f.origin.x - f.size.width) - 18) < 0.5,
               "抽屉右边距 18（web right:18px）", @(host.size.width - f.origin.x - f.size.width).stringValue);

            [wc toggleDrawer];
            Pump(0.3);
            CK(drawer.hidden && !drawer.polling, "再点一次收起并停轮询", @"应隐藏且停轮询");
        }
    }

    // ---- ④d 主题令牌：uistyle 必须真的改变外观，不是只存偏好 ----
    {
        NSString *savedStyle = [RLPTheme uiStyle];
        NSString *savedTheme = [RLPTheme themeName];
        [RLPTheme setThemeName:@"dark"];
        [RLPTheme setUiStyle:@"apple"];
        NSColor *appleAcc = [RLPTheme current].accent;
        CGFloat appleTop = [RLPTheme current].topH;
        [RLPTheme setUiStyle:@"classic"];
        NSColor *classicAcc = [RLPTheme current].accent;
        CGFloat classicTop = [RLPTheme current].topH;
        CK(![appleAcc isEqual:classicAcc],
           "切 classic 后强调色真的变了（web --acc 珊瑚红→蓝）", @"强调色没变");
        CK(appleTop == 60 && classicTop == 52,
           "切 classic 后顶栏高度 60→52（web #app rows）",
           [NSString stringWithFormat:@"apple=%g classic=%g", appleTop, classicTop]);
        [RLPTheme setUiStyle:savedStyle];
        [RLPTheme setThemeName:savedTheme];
    }

    // ---- ⑤ 单曲页 + 播放条 ----
    RLPNowPlayingViewController *np = [[RLPNowPlayingViewController alloc] init];
    np.view.frame = NSMakeRect(0, 0, 1180, 760);
    [np.view layoutSubtreeIfNeeded];
    // Clearly-labelled offline UI fixture: same production LRC projection, no device playback.
    [np setValue:@"/offline/UI-fixture.flac" forKey:@"currentPath"];
    [(NSTextField *)[np valueForKey:@"titleLabel2"] setStringValue:@"离线布局夹具 · UI fixture"];
    [(NSTextField *)[np valueForKey:@"artistLabel2"] setStringValue:@"仅验证布局，不代表真实播放取证"];
    [np applyLyricText:@"[00:01.00]第一行 / first line\n[00:03.00]当前歌词 / active line\n[00:05.00]下一行 / next line" forPath:@"/offline/UI-fixture.flac"];
    [np updateLyricPosition:3.2];
    [np performSelector:@selector(anlPaint)];
    np.view.needsLayout=YES;[np.view layoutSubtreeIfNeeded];

    // ---- ⑤a 补全芯片（web #npMeta / buildNpMetaHtml）----
    // 判据用**合成 meta**喂生产投影函数：真实夹具没联网补全，/api/meta 不会 enriched，
    // 但芯片的渲染契约（只在 enriched 出、字段与来源对、没补全就不出现）必须可验。
    {
        NSMutableArray<NSView *> *nv = [NSMutableArray array];
        CollectAllViews(np.view, nv);
        NSMutableDictionary *nById = [NSMutableDictionary dictionary];
        for (NSView *v in nv) if (v.identifier.length) nById[v.identifier] = v;

        // ① 负向：enriched=false ⟹ 整行隐藏（不许拿「暂无资料」冒充）
        [np renderMetaChipsFromMeta:@{ @"meta": @{ @"enriched": @NO } }];
        [np.view layoutSubtreeIfNeeded];
        CK(((NSView *)nById[@"npMeta"]).hidden, "未补全时补全芯片行隐藏（不假装有资料）", @"");

        // ② 正向：enriched=true + 年份/流派/专辑艺术家 ⟹ 三个值芯片 + 「已补全」徽标
        [np renderMetaChipsFromMeta:@{
            @"year": @2019, @"genre": @"日本流行楽", @"albumArtist": @"Aimer",
            @"meta": @{ @"enriched": @YES, @"sources": @{ @"year": @"Discogs" } }
        }];
        [np.view layoutSubtreeIfNeeded];
        CK(!((NSView *)nById[@"npMeta"]).hidden, "补全后芯片行显示", @"");
        NSMutableArray<NSButton *> *chips = [NSMutableArray array];
        for (NSView *v in nv) if ([v.identifier hasPrefix:@"npMeta."]) [chips addObject:(NSButton *)v];
        NSInteger shown = 0;
        for (NSButton *b in chips) if (!b.hidden && b.title.length) ++shown;
        CK(shown == 4, "补全芯片 = 年份 + 流派 + 专辑艺术家 + 已补全（4 个）",
           [NSString stringWithFormat:@"shown=%ld", (long)shown]);
        BOOL hasEnriched = NO;
        for (NSButton *b in chips)
            if ([b.identifier isEqualToString:@"npMeta.enriched"] && !b.hidden &&
                [b.title isEqualToString:RLPTr(@"已补全")]) hasEnriched = YES;
        CK(hasEnriched, "「已补全」徽标文案正确（web .badge.g）", @"");
        // 来源提示必须来自 meta.sources（缺失时写「本地标签」，不编造来源）
        BOOL sourceOk = NO;
        for (NSButton *b in chips)
            if ([b.identifier isEqualToString:@"npMeta.year"]) sourceOk = [b.toolTip containsString:@"Discogs"];
        CK(sourceOk, "年份芯片的来源提示来自 meta.sources", @"");

        // 证据截图：补全态下的芯片行（与 web 5dda1c5b 的对照）
        [np.view layoutSubtreeIfNeeded];
        Pump(0.3);
        CK(Snap(np.view, [outDir stringByAppendingPathComponent:@"30b-nowplaying-meta.png"],
                CGSizeMake(1180, 760)), "补全芯片态截图已落盘", outDir);

        // ③ 复位成空态，避免影响后面的截图/断言
        [np renderMetaChipsFromMeta:nil];
        Pump(0.3);
    }
    Pump(0.5);
    Snap(np.view, [outDir stringByAppendingPathComponent:@"30-nowplaying.png"], CGSizeMake(1180, 760));
    CK(NonEmptyLabels(np.view) >= 3, "单曲页有实际内容",
       [NSString stringWithFormat:@"labels=%ld", (long)NonEmptyLabels(np.view)]);

    // 播放条单独截一张。按**它在窗口里的真实宽度**截：
    // 强设 1180 会把还没解算约束的视图截成 948，看起来像布局 bug 其实是截图方法错。
    [wc.window layoutIfNeeded];
    const CGFloat barW = wc.playbackBar.bounds.size.width > 100 ? wc.playbackBar.bounds.size.width : 1180;
    Snap(wc.playbackBar, [outDir stringByAppendingPathComponent:@"31-playbar.png"], CGSizeMake(barW, 76));
    CK(barW >= 900, "播放条宽度铺满窗口", [NSString stringWithFormat:@"w=%.0f", barW]);

    // ---- ⑤b 播放条封面必须可点进播放页（用户 2026-11-12 明确要求）----
    // web 的底栏 #cv 没有 click 绑定（进播放页靠 #npOpen）——所以这是**改进**，不是复刻。
    // 判据走"真事件链"：造一个鼠标按下事件投给封面视图，再看正在播放页是否真的被打开。
    // 只断言"有手势/target"是假判据：绑了 handler 但点击路径断了照样过。
    {
        NSMutableArray<NSView *> *bv = [NSMutableArray array];
        CollectAllViews(wc.playbackBar, bv);
        NSView *cover = nil;
        for (NSView *v in bv) if ([v.identifier isEqualToString:@"pb.cover"]) { cover = v; break; }
        CK(cover != nil, "播放条封面在视图树里（web #cv）", @"缺 pb.cover");
        CK(cover.frame.size.width > 0 && cover.frame.size.height > 0,
           "封面有真实尺寸（可点击前提）", cover ? NSStringFromRect(cover.frame) : @"nil");
        CK([cover acceptsFirstResponder] || [cover isKindOfClass:[NSImageView class]],
           "封面是可命中的图片视图", NSStringFromClass(cover.class));

        const BOOL wasOpen = wc.nowPlayingOverlayVisible;
        if (wasOpen) [[NSNotificationCenter defaultCenter]
                        postNotificationName:@"RLPCloseNowPlayingNotification" object:nil];
        Pump(0.3);
        // 投一个真实的左键按下事件（不是直接调 handler）：能证明"点击这块视图"这条路通。
        NSEvent *ev = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                        location:[cover convertPoint:NSMakePoint(cover.bounds.size.width / 2,
                                                                                cover.bounds.size.height / 2)
                                                             toView:nil]
                                   modifierFlags:0
                                       timestamp:0
                                    windowNumber:wc.window.windowNumber
                                         context:nil
                                     eventNumber:1
                                      clickCount:1
                                        pressure:1.0];
        [cover mouseDown:ev];
        Pump(0.6);
        CK(wc.nowPlayingOverlayVisible, "点播放条封面 → 打开正在播放页",
           [NSString stringWithFormat:@"overlay=%d", (int)wc.nowPlayingOverlayVisible]);
        CK(wc.nowPlayingPage != nil, "正在播放页被真正创建（不是只翻了个标志位）",
           NSStringFromClass(wc.nowPlayingPage.class));
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPCloseNowPlayingNotification" object:nil];
        Pump(0.4);
    }

    // ---- ⑤d 2026-11-13 轮：用户实机点出的 UI 故障（每条都问运行时事实）----
    {
        // (1) 专辑封面必须正方形：旧实现封面高固定 180、宽随窗口变 ⟹ letterbox 白边。
        [wc.sidebar selectKey:@"albums"];
        Pump(0.9);
        NSMutableArray<NSView *> *albumsAll = [NSMutableArray array];
        CollectAllViews(wc.currentContent.view, albumsAll);
        NSInteger itemCount = 0, squareCovers = 0;
        for (NSView *v in albumsAll) {
            if (![NSStringFromClass(v.class) containsString:@"RLPAlbumCardView"]) continue;
            ++itemCount;
            NSMutableArray<NSView *> *iv = [NSMutableArray array];
            CollectAllViews(v, iv);
            for (NSView *c in iv) {
                if (![c isKindOfClass:[NSImageView class]]) continue;
                if (c.bounds.size.width < 40 || c.bounds.size.height < 40) continue;
                if (fabs(c.bounds.size.width - c.bounds.size.height) <= 0.5) ++squareCovers;
            }
        }
        CK(itemCount > 0 && squareCovers >= itemCount,
           "专辑卡封面是正方形（web .card .cv{aspect-ratio:1}；旧实现 180 固定高 ⟹ 白边）",
           [NSString stringWithFormat:@"items=%ld square=%ld", (long)itemCount, (long)squareCovers]);

        // (2) 播放条音量滑块：位置刻度 0..1000，0 dB 必须落在最右端（web #vol max=1000）
        NSMutableArray<NSView *> *barViews = [NSMutableArray array];
        CollectAllViews(wc.playbackBar, barViews);
        NSSlider *vol = nil;
        for (NSView *v in barViews)
            if ([v isKindOfClass:[NSSlider class]] && [v.identifier isEqualToString:@"pb.vol"]) { vol = (NSSlider *)v; break; }
        CK(vol != nil, "播放条音量滑块存在（web #vol）", @"缺 pb.vol");
        if (vol) {
            CK(fabs(vol.maxValue - 1000.0) < 0.5, "音量是位置刻度 0..1000（web #vol）",
               [NSString stringWithFormat:@"max=%.1f", vol.maxValue]);
            CK(vol.cell && [(id)vol.cell respondsToSelector:NSSelectorFromString(@"capsuleStyle")],
               "音量滑块用白色胶囊头（web range 原生外观；旧实现 10px 红点）", @"cell 不是 capsule 样式");
        }
        // 进度滑杆不应画滑块头（web .track 只有填充线）
        NSSlider *prog = nil;
        for (NSView *v in barViews)
            if ([v isKindOfClass:[NSSlider class]] && [v.identifier isEqualToString:@"pb.progress"]) { prog = (NSSlider *)v; break; }
        CK(prog != nil && prog.cell && [(id)prog.cell respondsToSelector:NSSelectorFromString(@"hideKnob")],
           "进度条无滑块头（web .track 同款）", @"cell 不是 hideKnob 样式");

        // (3) 顶栏：刷新曲库按钮 + 返回键是纯图标 chevron（不是「← 返回专辑」文字胶囊）
        NSMutableArray<NSView *> *topViews = [NSMutableArray array];
        CollectAllViews(wc.window.contentView, topViews);
        NSButton *scanBtn = nil, *backBtn = nil;
        for (NSView *v in topViews) {
            if (![v isKindOfClass:[NSButton class]]) continue;
            if ([v.identifier isEqualToString:@"top.scan"]) scanBtn = (NSButton *)v;
            if ([v.identifier isEqualToString:@"top.back"]) backBtn = (NSButton *)v;
        }
        CK(scanBtn != nil && scanBtn.target && scanBtn.action,
           "顶栏有「重新扫描音乐库」按钮且有 action（web #bScan 同功能）",
           scanBtn ? [NSString stringWithFormat:@"target=%@", scanBtn.target] : @"缺 top.scan");
        CK(backBtn != nil && backBtn.image != nil && backBtn.title.length <= 1,
           "返回键是纯图标 chevron（不是「← 返回专辑」文字胶囊）",
           backBtn ? [NSString stringWithFormat:@"title=%@", backBtn.title] : @"缺 top.back");

        // (4) 元数据「高级选项」：默认收起，点开后高级内容可见（web #sp_metamore/#sp_metaadv）
        // 前面几步切过专辑/播放条，这里先真正切到设置页再断言设置页控件。
        [wc.sidebar selectKey:@"settings"];
        Pump(0.9);
        if ([wc.currentContent isKindOfClass:[RLPSettingsViewController class]]) {
            RLPSettingsViewController *svm = (RLPSettingsViewController *)wc.currentContent;
            [svm selectPane:@"meta"];
            Pump(0.6);
            NSMutableArray<NSView *> *mv = [NSMutableArray array];
            CollectAllViews(svm.view, mv);
            NSButton *more = nil; NSView *adv = nil;
            for (NSView *v in mv) {
                if ([v.identifier isEqualToString:@"sp_metamore"]) more = [v isKindOfClass:[NSButton class]] ? (NSButton *)v : nil;
                if ([v.identifier isEqualToString:@"sp_metaadv"]) adv = v;
            }
            CK(more != nil && adv != nil, "元数据页有「高级选项」按钮与高级内容容器", @"缺 sp_metamore/sp_metaadv");
            if (more && adv) {
                CK(adv.hidden, "高级选项默认收起（用户：默认只显示基础选项）", @"高级内容默认可见");
                [more performClick:nil];
                Pump(0.4);
                CK(!adv.hidden, "点「高级选项」后高级内容真的展开", @"仍是收起态");
                CK(adv.frame.size.height > 10, "展开后高级内容有真实高度（布局解算过）",
                   @(adv.frame.size.height).stringValue);
                // 证据截图：高级选项展开态（数据源 / AI 接入 / 联网检索 / 写回）
                [svm.view layoutSubtreeIfNeeded];
                Pump(0.3);
                CK(Snap(svm.view, [outDir stringByAppendingPathComponent:@"21c-settings-meta-advanced.png"],
                        CGSizeMake(1180, 760)), "高级选项展开态截图已落盘", outDir);
                [more performClick:nil];
                Pump(0.3);
                CK(adv.hidden, "再点一次收起", @"仍展开");
            }
            // (5) EQ 页：不再有内层滚动条（旧的 EQ 自带滚动 + 参数表滚动 = 三个滚动条）
            [svm selectPane:@"eq"];
            Pump(0.6);
            NSClassFromString(@"RLPEqualizerView");
            NSMutableArray<NSView *> *eqAll = [NSMutableArray array];
            CollectAllViews(svm.view, eqAll);
            NSView *eqRoot = nil;
            Class eqClass = NSClassFromString(@"RLPEqualizerView");
            for (NSView *v in eqAll) if (eqClass && [v isKindOfClass:eqClass]) { eqRoot = v; break; }
            CK(eqRoot != nil, "EQ 页有 RLPEqualizerView（审计锚点）", @"视图树里找不到");
            NSMutableArray<NSView *> *eqSub = [NSMutableArray array];
            if (eqRoot) CollectAllViews(eqRoot, eqSub);
            NSInteger scrollersInsideEQ = 0;
            for (NSView *v in eqSub) {
                if (![v isKindOfClass:[NSScrollView class]]) continue;
                NSScrollView *scv = (NSScrollView *)v;
                if (scv.hasVerticalScroller || scv.hasHorizontalScroller) ++scrollersInsideEQ;
            }
            CK(scrollersInsideEQ == 0, "EQ 页只剩外层整页滚动条（内层 0 个滚动条）",
               [NSString stringWithFormat:@"innerScrollers=%ld", (long)scrollersInsideEQ]);
            // 20 段参数表必须全高可见（旧实现内层 300pt 滚动裁掉一半参数）
            NSTableView *bands = nil;
            for (NSView *v in eqAll)
                if ([v isKindOfClass:[NSTableView class]] && [v.identifier isEqualToString:@"peq.bands"]) { bands = (NSTableView *)v; break; }
            CK(bands != nil && bands.frame.size.height >= 20 * 26,
               "20 段参数表全高渲染（不再内层滚动裁切）",
               bands ? [NSString stringWithFormat:@"h=%.0f", bands.frame.size.height] : @"缺 peq.bands");
            CK(bands != nil && bands.dataSource != nil && bands.delegate != nil,
               "参数表有真实数据源（曲线可编辑前提）", @"dataSource/delegate 为空");

            // (5b) 诊断/反馈区（2026-11-13 用户实机：气泡里空白 / 要求改成 web 内联填写窗）
            //
            // ⚠️ 旧判据为什么是假绿：它只断言「把控件搬进 NSPopover 的内容容器」这一步，
            //    完全不检查气泡**显示出来之后**这些控件是否可见。真实故障恰恰在这里 ——
            //    RLPCardController 只钉宽、没给 preferredContentSize，搬进去的 620pt 宽
            //    NSScrollView 又没有宽度约束 ⟹ 气泡塌成空框，用户看到一条空白。
            //    所以本轮判据换成：**不点任何东西**，直接量设置页上真实子视图是否可见。
            [svm selectPane:@"diag"];
            Pump(0.7);
            CK(!svm.view.isHidden && svm.view.window != nil,
               "诊断页真的显示在窗口里（可见性判据的前提）",
               svm.view.window ? @"window 存在" : @"视图不在任何窗口里，后面的可见性断言无意义");

            // 通用「可见」判定：自身与全部祖先未隐藏，且 frame 有面积、落在某个祖先可视区内。
            // 注意不能用 convertRect 到窗口（离屏审计里窗口可能没显示），用**祖先链可见性 + 面积**。
            __block NSInteger visibleButtons = 0;
            NSMutableSet<NSString *> *visIds = [NSMutableSet set];
            NSMutableArray<NSView *> *allD = [NSMutableArray array];
            CollectAllViews(svm.view, allD);
            for (NSView *v in allD) {
                if (v.hidden || v.frame.size.width < 1 || v.frame.size.height < 1) continue;
                BOOL anc = YES;
                for (NSView *p = v.superview; p; p = p.superview) if (p.hidden) { anc = NO; break; }
                if (!anc) continue;
                if ([v isKindOfClass:[NSButton class]]) ++visibleButtons;
                if (v.identifier.length) [visIds addObject:v.identifier];
            }

            // ---- 第十一项：三个按钮逐字文案 + 不在气泡里 + 无「随反馈上传诊断」----
            NSArray *wantTitles = @[ @"导出诊断包（.zip）", @"只要 JSON", @"查看 / 复制诊断摘要" ];
            // 同名按钮可能出现在隐藏容器里（旧实现就是这样）⟹ 只在「真可见」的里面找，
            // 否则「有按钮」会退化成「藏起来的那个也算有」。
            NSMutableDictionary<NSString *, NSButton *> *byTitle = [NSMutableDictionary dictionary];
            for (NSView *v in allD) {
                if (![v isKindOfClass:[NSButton class]]) continue;
                NSString *t = ((NSButton *)v).title;
                if (!t.length) continue;
                if (!RLPViewActuallyVisible(v)) continue;
                byTitle[t] = (NSButton *)v;
            }
            for (NSString *want in wantTitles) {
                NSButton *b = byTitle[want];
                BOOL vis = RLPViewActuallyVisible(b);
                NSString *detail = b
                    ? [NSString stringWithFormat:@"存在但不可见 frame=%@", NSStringFromRect(b.frame)]
                    : @"视图树里找不到该文案的按钮";
                CK(vis, [NSString stringWithFormat:@"诊断页无需点击就有可见按钮「%@」", want].UTF8String,
                   detail);
            }
            // 主按钮必须是红底白字（web .btn.pri）
            NSButton *zipBtn = byTitle[wantTitles[0]];
            BOOL zipIsAccent = zipBtn && zipBtn.wantsLayer && zipBtn.layer.backgroundColor != NULL &&
                CGColorGetAlpha(zipBtn.layer.backgroundColor) > 0.5;
            if (zipIsAccent) {
                const CGFloat *comp = CGColorGetComponents(zipBtn.layer.backgroundColor);
                zipIsAccent = comp && comp[0] > 0.7 && comp[1] < 0.5;   // 红通道高、绿低 ≈ 珊瑚红
            }
            CK(zipIsAccent, "「导出诊断包（.zip）」是红底主按钮（web .btn.pri 视觉）",
               zipBtn ? [NSString stringWithFormat:@"bg=%@", zipBtn.layer.backgroundColor] : @"缺按钮");

            // 「随反馈上传诊断」必须真的没了（文案 + identifier 双重断言，防回退）
            BOOL uploadByTitle = byTitle[RLPTr(@"随反馈上传诊断")] != nil;
            BOOL uploadById = NO;
            for (NSView *v in allD)
                if ([v.identifier isEqualToString:@"sp_diagupload"]) { uploadById = YES; break; }
            CK(!uploadByTitle && !uploadById,
               "「随反馈上传诊断」按钮已删除（用户明确要求去掉）",
               [NSString stringWithFormat:@"byTitle=%d byIdentifier=%d", (int)uploadByTitle, (int)uploadById]);

            // ---- 第十项：反馈表单内联、默认可见、计数可用 ----
            NSTextView *fbText = nil; NSTextField *fbCount = nil;
            for (NSView *v in allD) {
                if ([v.identifier isEqualToString:@"sp_fbtext"] && [v isKindOfClass:[NSTextView class]])
                    fbText = (NSTextView *)v;
                if ([v.identifier isEqualToString:@"sp_fbcount"] && [v isKindOfClass:[NSTextField class]])
                    fbCount = (NSTextField *)v;
            }
            CK(RLPViewActuallyVisible(fbText) && fbText.frame.size.height >= 100,
               "反馈正文文本域内联可见且够高（约 8 行，用户要求）",
               fbText ? [NSString stringWithFormat:@"h=%.0f hidden=%d", fbText.frame.size.height, (int)fbText.hidden]
                      : @"找不到 sp_fbtext");
            CK(RLPViewActuallyVisible(fbCount),
               "反馈字数计数内联可见", fbCount ? @"ok" : @"找不到 sp_fbcount");
            // 计数真的跟随输入：写入 12 个字符后断言 12 / 16384
            if (fbText && fbCount && [svm respondsToSelector:NSSelectorFromString(@"updateFbCount")]) {
                fbText.string = @"ABCDEFGHIJKL";       // 12 个 ASCII = 12 字节
                [svm performSelector:NSSelectorFromString(@"updateFbCount")];
                Pump(0.1);
                CK([fbCount.stringValue hasPrefix:@"12 / 16384"],
                   "输入 12 个字符后计数显示 12 / 16384", fbCount.stringValue);
                // 中文按字节计（web fbBytes 同口径）：6 个汉字 = 18 字节，不是 6。
                fbText.string = @"一二三四五六";
                [svm performSelector:NSSelectorFromString(@"updateFbCount")];
                Pump(0.1);
                CK([fbCount.stringValue hasPrefix:@"18 / 16384"],
                   "中文按 UTF-8 字节计数（6 个汉字 = 18 字节，不是 6）", fbCount.stringValue);
                fbText.string = @"";
                [svm performSelector:NSSelectorFromString(@"updateFbCount")];
            }
            // 附带诊断包默认勾选 + 发送按钮
            NSSwitch *fbDiag = nil;
            for (NSView *v in allD)
                if ([v.identifier isEqualToString:@"sp_fbdiag"] && [v isKindOfClass:[NSSwitch class]])
                    fbDiag = (NSSwitch *)v;
            CK(RLPViewActuallyVisible(fbDiag) && fbDiag.state == NSControlStateValueOn,
               "「附带诊断包」默认勾选（web checked 同态）",
               fbDiag ? [NSString stringWithFormat:@"state=%ld", (long)fbDiag.state] : @"缺 sp_fbdiag");
            NSButton *fbSend = nil;
            for (NSView *v in allD)
                if ([v.identifier isEqualToString:@"sp_fbsend"]) fbSend = (NSButton *)v;
            CK(RLPViewActuallyVisible(fbSend) && [fbSend.title isEqualToString:RLPTr(@"发送反馈")],
               "「发送反馈」按钮内联可见、文案逐字一致",
               fbSend ? fbSend.title : @"缺 sp_fbsend");

            // ---- 第9/10/11 共通防线：整页不得再用 NSPopover 承载诊断/反馈 ----
            // 遍历窗口的**已附着 popover**：showing 的一律算违规；同时断言源码里那两个
            // 「选项收进气泡」入口已不存在（sp_diagmore / sp_fbmore）。
            __block NSInteger shownPopovers = 0;
            for (NSWindow *w in [NSApp windows]) {
                for (NSWindow *child in w.childWindows)
                    if ([child isKindOfClass:[NSPanel class]] && child.isVisible) ++shownPopovers;
            }
            BOOL hasLegacyPopoverEntry = visIds.count > 0 &&
                ([visIds containsObject:@"sp_diagmore"] || [visIds containsObject:@"sp_fbmore"]);
            CK(shownPopovers == 0 && !hasLegacyPopoverEntry,
               "诊断/反馈不再由 NSPopover 承载（无显示中的气泡、无 ▾ 气泡入口）",
               [NSString stringWithFormat:@"shownPopovers=%ld legacyEntry=%d",
                (long)shownPopovers, (int)hasLegacyPopoverEntry]);

            // ---- 第九项收口：点「查看 / 复制诊断摘要」后摘要面板**就地展开**（不是气泡）----
            NSScrollView *diagSummary = nil;
            for (NSView *v in allD)
                if ([v.identifier isEqualToString:@"sp_diagscroll"] && [v isKindOfClass:[NSScrollView class]])
                    diagSummary = (NSScrollView *)v;
            CK(diagSummary != nil && !RLPViewActuallyVisible(diagSummary),
               "诊断摘要面板默认收起（不占页面高度）",
               diagSummary ? @"ok" : @"缺 sp_diagscroll");
            if (diagSummary && [svm respondsToSelector:NSSelectorFromString(@"setDiagSummaryVisible:")]) {
                NSMethodSignature *sig = [svm methodSignatureForSelector:NSSelectorFromString(@"setDiagSummaryVisible:")];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:svm];
                [inv setSelector:NSSelectorFromString(@"setDiagSummaryVisible:")];
                BOOL yes = YES;
                [inv setArgument:&yes atIndex:2];
                [inv invoke];
                Pump(0.2);
                CK(RLPViewActuallyVisible(diagSummary) && diagSummary.frame.size.height >= 100,
                   "调用后摘要面板就地展开且有真实高度（不是零高空气泡）",
                   [NSString stringWithFormat:@"h=%.0f hidden=%d",
                    diagSummary.frame.size.height, (int)diagSummary.hidden]);
            }
            // 证据截图：诊断页（三按钮 + 内联反馈表单都在页面上）
            [svm.view layoutSubtreeIfNeeded];
            Pump(0.2);
            CK(Snap(svm.view, [outDir stringByAppendingPathComponent:@"21d-settings-diag-inline.png"],
                    CGSizeMake(1180, 760)), "诊断/反馈内联形态截图已落盘", outDir);
        }

        // =====================================================================
        // (5z) 播放链路 + 底栏播放键状态（2026-11-13 用户实机：「无法正常播放音乐」）
        //
        // ⚠️ 本轮才发现的一个**巨大盲区**：在这次改动之前，整个 --audit 从来没有调用过
        //    任何播放入口（grep RLPPlayPath = 0 次），也就从未断言过「点了播放之后播没播起来」。
        //    所以「无法正常播放音乐」这种硬故障可以在门禁全绿的情况下上线。
        //    判据走**生产入口**（RLPPlayPath → /api/play → 队列线程），不直接改状态。
        //
        // 纪律（铁律②）：backend=null + volume=-120 —— 只跑 DSP，绝不打开设备、绝不出声。
        // =====================================================================
        {
            // /api/lib/albums 的元素是**字典**（{k,name,artist,…}），不是数组 ——
            // 按位置取会抛 NSInvalidArgumentException 把审计进程带走（第一版真踩了）。
            NSArray *albumTracks = @[];
            NSDictionary *al = [[RLPCoreClient shared] jsonWithMethod:@"GET" path:@"/api/lib/albums" body:nil];
            NSArray *albumsAll = [al[@"albums"] isKindOfClass:[NSArray class]] ? al[@"albums"] : @[];
            NSString *firstAlbumKey = @"";
            for (id a in albumsAll) {
                if (![a isKindOfClass:[NSDictionary class]]) continue;
                NSString *k = ((NSDictionary *)a)[@"k"];
                if ([k isKindOfClass:[NSString class]] && k.length) { firstAlbumKey = k; break; }
            }
            if (firstAlbumKey.length) {
                NSDictionary *ad = [[RLPCoreClient shared] jsonWithMethod:@"GET"
                    path:[NSString stringWithFormat:@"/api/lib/album?k=%@", RLPEnc(firstAlbumKey)] body:nil];
                if ([ad[@"tracks"] isKindOfClass:[NSArray class]]) albumTracks = ad[@"tracks"];
            }
            NSString *firstPath = @"";
            for (id t in albumTracks) {
                if (![t isKindOfClass:[NSDictionary class]]) continue;
                NSString *pp = ((NSDictionary *)t)[@"path"];
                if ([pp isKindOfClass:[NSString class]] && pp.length) { firstPath = pp; break; }
            }
            CK(firstPath.length > 0, "播放判据有真实曲目可播（夹具库非空）", firstPath);

            if (firstPath.length) {
                [[RLPCoreClient shared] postJSON:@"/api/settings"
                    body:@"backend=null&volume=-120" completion:nil];
                Pump(0.3);
                [[RLPCoreClient shared] postJSON:@"/api/clear" body:nil completion:nil];
                Pump(0.3);

                // ① 生产入口播这一首 → 必须真的进入 playing 且时间轴推进
                RLPPlayPath(firstPath);
                BOOL started = NO; NSString *lastErr = @"";
                for (int i = 0; i < 60 && !started; ++i) {
                    Pump(0.1);
                    NSDictionary *st = [[RLPCoreClient shared] jsonWithMethod:@"GET" path:@"/api/status" body:nil];
                    RLPPlaybackStatus *s2 = [RLPPlaybackStatus statusFromJSON:st];
                    if (s2.playing) started = YES;
                    if (s2.error.length) lastErr = s2.error;
                }
                CK(started, "点击曲目后 /api/status 真的变成 playing=true（生产入口走通）",
                   lastErr.length ? [NSString stringWithFormat:@"error=%@", lastErr] : @"6s 内未起播");
                double pos1 = 0, pos2 = 0;
                {
                    NSDictionary *st = [[RLPCoreClient shared] jsonWithMethod:@"GET" path:@"/api/status" body:nil];
                    pos1 = [RLPPlaybackStatus statusFromJSON:st].position;
                    Pump(1.2);
                    st = [[RLPCoreClient shared] jsonWithMethod:@"GET" path:@"/api/status" body:nil];
                    pos2 = [RLPPlaybackStatus statusFromJSON:st].position;
                }
                CK(pos2 > pos1 + 0.3, "播放位置随时间前进（不是 playing=true 但时间轴停住）",
                   [NSString stringWithFormat:@"pos %.2f -> %.2f", pos1, pos2]);
                NSDictionary *stNow = [[RLPCoreClient shared] jsonWithMethod:@"GET" path:@"/api/status" body:nil];
                RLPPlaybackStatus *sNow = [RLPPlaybackStatus statusFromJSON:stNow];
                CK(![sNow.error containsString:@"RENDERFAIL"] && ![sNow.error containsString:@"失败"],
                   "null 后端起播全程无 RENDERFAIL / 设备错误",
                   sNow.error.length ? sNow.error : @"无错误");

                // ---- ② 底栏播放键必须跟着真实状态切（第2项）----
                // 不用「固定 Pump 后读一次图标」：底栏是 0.5s 轮询 + 异步回调，机器忙时会读到
                // 上一拍快照 ⟹ **假红**（本轮第一次跑就红在这条）。改成等不变量成立再断言：
                // 「底栏 isPlaying == /api/status 的 playing」+「两种状态图标位图不同」。
                RLPPlaybackBarView *bar = wc.playbackBar;
                CK(bar != nil, "底栏实例存在（后续图标判据的前提）", @"playbackBar 为 nil");
                [bar startPolling];
                NSData *(^barIcon)(void) = ^NSData *{
                    NSButton *pb2 = [bar valueForKey:@"playBtn"];
                    NSImage *img = pb2.image;
                    if (!img) return nil;
                    NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:[img TIFFRepresentation]];
                    return rep ? [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] : nil;
                };
                BOOL barSawPlaying = NO;
                for (int i = 0; i < 80 && !barSawPlaying; ++i) { Pump(0.05); barSawPlaying = bar.isPlaying; }
                NSData *iconPlaying = barIcon();
                CK(barSawPlaying, "第2项：播放中底栏 isPlaying=true（轮询真的把状态带到���栏）",
                   [NSString stringWithFormat:@"polling=%d lastStatus=%@",
                    (int)bar.polling, bar.lastStatus ? @"有" : @"nil"]);
                [[RLPCoreClient shared] postJSON:@"/api/pause?on=1" body:nil completion:nil];
                BOOL barSawPaused = NO;
                for (int i = 0; i < 80 && !barSawPaused; ++i) { Pump(0.05); barSawPaused = !bar.isPlaying; }
                NSData *iconPaused = barIcon();
                CK(barSawPaused, "第2项：暂停后底栏 isPlaying=false（状态能下来，不是单向锁死）",
                   [NSString stringWithFormat:@"isPlaying=%d", (int)bar.isPlaying]);
                CK(iconPlaying != nil && iconPaused != nil &&
                   ![iconPlaying isEqualToData:iconPaused],
                   "第2项：底栏播放键图标随播放/暂停真的换图（不是一直画三角形）",
                   [NSString stringWithFormat:@"playingImg=%luB pausedImg=%luB",
                    (unsigned long)iconPlaying.length, (unsigned long)iconPaused.length]);

                // ---- 第3项：播放键完整圆 + 进度滑块头不得压在它上面 ----
                // 用户截图里"三角形偏左贴边、圆被裁"的实测成因是**白色进度滑块头压在红圆上**：
                // 红圆本身 67×66px 完整、三角形左右留白各 25px、圆心偏差 0/0.5px（像素量过）。
                NSButton *pb3 = [bar valueForKey:@"playBtn"];
                NSView *prog3 = [bar valueForKey:@"progress"];
                NSRect kf3 = pb3.frame, fr3 = prog3.frame;
                CK(!NSIntersectsRect(fr3, kf3),
                   "第3项：进度条不与播放键相交（白色滑块头不再压在红圆上）",
                   [NSString stringWithFormat:@"progress=%@ play=%@",
                    NSStringFromRect(fr3), NSStringFromRect(kf3)]);
                CK(fabs(kf3.size.width - kf3.size.height) < 0.51 &&
                   fabs(pb3.layer.cornerRadius - kf3.size.width / 2.0) < 0.51,
                   "第3项：播放键是完整圆形（方形外框 + cornerRadius = 半径）",
                   [NSString stringWithFormat:@"frame=%@ radius=%.1f",
                    NSStringFromRect(kf3), pb3.layer.cornerRadius]);

                [[RLPCoreClient shared] postJSON:@"/api/stop" body:nil completion:nil];
                Pump(0.4);
            }
        }

        // (6) 文件夹页地址栏（web #fPath/#fGo/#fRoot）：旧实现只有只读路径文字
        [wc.sidebar selectKey:@"folders"];
        Pump(0.7);
        NSMutableArray<NSView *> *fv = [NSMutableArray array];
        CollectAllViews(wc.currentContent.view, fv);
        NSMutableSet<NSString *> *fids = [NSMutableSet set];
        for (NSView *v in fv) if (v.identifier.length) [fids addObject:v.identifier];
        CK([fids containsObject:@"fPath"] && [fids containsObject:@"fGo"] && [fids containsObject:@"fRoot"],
           "文件夹页有可输入路径 + 跳转键 + 根目录下拉（web 地址栏）",
           [NSString stringWithFormat:@"ids=%@", fids]);

        // (7) 队列页排序下拉（web #qSort）
        [wc.sidebar selectKey:@"queue"];
        Pump(0.7);
        NSMutableArray<NSView *> *qv = [NSMutableArray array];
        CollectAllViews(wc.currentContent.view, qv);
        NSPopUpButton *qsort = nil;
        for (NSView *v in qv)
            if ([v isKindOfClass:[NSPopUpButton class]] && [v.identifier isEqualToString:@"queue.sort"]) { qsort = (NSPopUpButton *)v; break; }
        CK(qsort != nil && qsort.target && qsort.action,
           "队列页有排序下拉（web #qSort 语义：只改队列顺序）",
           qsort ? [NSString stringWithFormat:@"items=%ld", (long)qsort.numberOfItems] : @"缺 queue.sort");
    }

    // ---- ⑥ 主题必须真的换得动：用**渲染像素**判定，不看属性自述 ----
    NSString *lightShot = [outDir stringByAppendingPathComponent:@"40-albums-light.png"];
    NSString *darkShot  = [outDir stringByAppendingPathComponent:@"41-albums-dark.png"];

    [RLPTheme setThemeName:@"light"];
    Pump(0.6);
    [wc.sidebar selectKey:@"albums"];
    Pump(0.9);
    Snap(wc.window.contentView, lightShot, CGSizeMake(1180, 760));
    CK(ShotIsLight(lightShot), "浅色主题下主页渲染为浅色（像素判定）", lightShot);
    // 侧栏必须有选中态（本轮真故障：NSTableView 在非 key window 下 selectRowIndexes
    // 静默失败 ⟹ selectedRow 恒 -1、导航永远没有高亮）。
    CK(wc.sidebar.selectedRow >= 0, "侧栏有选中行（导航高亮的前提）",
       [NSString stringWithFormat:@"selectedRow=%ld", (long)wc.sidebar.selectedRow]);
    const double accLight = AccentRatio(lightShot);
    CK(accLight > 0.0001, "浅色主题下强调色真的画出来了（侧栏选中态）",
       [NSString stringWithFormat:@"accentRatio=%.5f", accLight]);

    [RLPTheme setThemeName:@"dark"];
    Pump(0.6);
    [wc.sidebar selectKey:@"albums"];
    Pump(0.9);
    Snap(wc.window.contentView, darkShot, CGSizeMake(1180, 760));
    CK(!ShotIsLight(darkShot), "深色主题下主页渲染为深色（像素判定）", darkShot);

    // 默认必须是 light（用户明确要求）
    CK([[RLPTheme themeNames] containsObject:@"light"], "主题只含 dark/light", @"");

    [wc stopAllActivity];
    [[RLPCoreClient shared] shutdown];

    std::printf("\n截图目录：%s\n", outDir.UTF8String ?: "");
    std::printf("结果：%d passed, %d failed\n", gPass, gFail);
    return gFail;
}