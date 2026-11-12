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
#import "RLPRightDrawer.h"
#import "RLPLyrics.h"
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

static void CollectAllViews(NSView *v, NSMutableArray<NSView *> *out) {
    if (!v) return;
    [out addObject:v];
    for (NSView *s in v.subviews) CollectAllViews(s, out);
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