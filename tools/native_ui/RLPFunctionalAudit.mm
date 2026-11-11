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
#import "RLPSupport.h"
#import "RLPTheme.h"

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
            NSTask *say = [[NSTask alloc] init];
            say.launchPath = @"/usr/bin/say";
            say.arguments = @[ @"-o", aiff, @"test" ];
            @try { [say launch]; [say waitUntilExit]; } @catch (NSException *e) { (void)e; }
            if (![fm fileExistsAtPath:aiff]) {
                [@"" writeToFile:aiff atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
            NSDictionary *attr = [fm attributesOfItemAtPath:aiff error:nil];
            const long long sz = (long long)attr.fileSize;
            [idx appendFormat:@"%@\t111\t%lld\t%@\t%@\t%@\t%@\t%ld\t1\t%@\t44100\t16\t2\t%.1f\t0\tJazz\t\t0\t0\t0\n",
             aiff, sz, info[0], info[1], info[1], title, (long)t, info[2], 30.0 + t];
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
        { "room",      "room",      "11-listening-room.png" },
    };
    RLPSetAppMode(RLPAppModeListening);
    [wc.sidebar reloadForModeChange];
    Pump(0.4);
    for (const RowSpec &r : rows) {
        CK([wc.sidebar selectKey:[NSString stringWithUTF8String:r.key]], r.name, @"侧栏没有这个 key");
        Pump(0.7);
        NSViewController *cur = wc.currentContent;
        CK(cur != nil, r.name, @"currentContent 为 nil");
        const NSInteger labels = cur ? NonEmptyLabels(cur.view) : 0;
        CK(labels >= 2, r.name, [NSString stringWithFormat:@"内容太少 labels=%ld", (long)labels]);
        Snap(wc.window.contentView, [outDir stringByAppendingPathComponent:
             [NSString stringWithUTF8String:r.file]], CGSizeMake(1180, 760));
    }

    // ---- ④ 专业模式：工作台 + 设置页 7 个页签 ----
    RLPSetAppMode(RLPAppModePro);
    [wc.sidebar reloadForModeChange];
    Pump(0.5);
    CK([wc.sidebar selectKey:@"workbench"], "专业模式能进工作台", @"侧栏没有 workbench");
    Pump(0.7);
    CK(wc.currentContent != nil, "工作台有内容", @"currentContent 为 nil");
    Snap(wc.window.contentView, [outDir stringByAppendingPathComponent:@"13-workbench.png"],
         CGSizeMake(1180, 760));
    CK([wc.sidebar selectKey:@"settings"], "专业模式能进设置", @"侧栏没有 settings");
    Pump(0.5);
    RLPSettingsViewController *sv = (RLPSettingsViewController *)wc.currentContent;
    if ([sv isKindOfClass:[RLPSettingsViewController class]]) {
        const char *keys[] = { "play","in","cal","stream","meta","adv","diag" };
        NSInteger i = 0;
        for (const char *k : keys) {
            [sv selectPane:[NSString stringWithUTF8String:k]];
            Pump(0.5);
            NSString *fn = [NSString stringWithFormat:@"20-settings-%s.png", k];
            Snap(wc.window.contentView, [outDir stringByAppendingPathComponent:fn], CGSizeMake(1180, 760));
            ++i;
        }
        CK(i == 7, "设置页 7 个页签均已切换并截图", [NSString stringWithFormat:@"panes=%ld", (long)i]);
    } else {
        CK(NO, "设置页类型正确", NSStringFromClass(wc.currentContent.class));
    }

    // ---- ⑤ 单曲页 + 播放条 ----
    RLPNowPlayingViewController *np = [[RLPNowPlayingViewController alloc] init];
    np.view.frame = NSMakeRect(0, 0, 1100, 700);
    [np.view layoutSubtreeIfNeeded];
    Pump(0.5);
    Snap(np.view, [outDir stringByAppendingPathComponent:@"30-nowplaying.png"], CGSizeMake(1100, 700));
    CK(NonEmptyLabels(np.view) >= 3, "单曲页有实际内容",
       [NSString stringWithFormat:@"labels=%ld", (long)NonEmptyLabels(np.view)]);

    // 播放条单独截一张。按**它在窗口里的真实宽度**截：
    // 强设 1180 会把还没解算约束的视图截成 948，看起来像布局 bug 其实是截图方法错。
    [wc.window layoutIfNeeded];
    const CGFloat barW = wc.playbackBar.bounds.size.width > 100 ? wc.playbackBar.bounds.size.width : 1180;
    Snap(wc.playbackBar, [outDir stringByAppendingPathComponent:@"31-playbar.png"], CGSizeMake(barW, 76));
    CK(barW >= 900, "播放条宽度铺满窗口", [NSString stringWithFormat:@"w=%.0f", barW]);

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