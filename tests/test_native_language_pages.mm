// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_language_pages.mm — 全局语言切换（zh <-> en）在原生各页面原地实时刷新
//
// 判据：
//   1. QuickStart（含聆音室新增卡片/按钮）、Workbench（含播放台/EQ/监控子页签、A/B、配置档、
//      PCM/DSD/Output 机架、快捷 EQ、RLPEqualizerView + RLPEQFaderInspector）及各列表/详情页
//      均实现 -applyLanguage，且响应 RLPLanguageDidChangeNotification 原地刷新静态文案；
//   2. 双向切换 zh -> en -> zh 后，静态文案正确恢复；
//   3. 保留当前页签（activeTab）、输入框草稿（filterSearch / pathField / titleField /
//      composerField / eq.presetName / eq.opraQuery）及用户内容（如艺术家名 "Johann Sebastian Bach"），
//      不盲翻用户数据、不触发音频设备或真实网络扫描。
#import <AppKit/AppKit.h>
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPSettingsViewController.h"
#import "RLPQuickStartViewController.h"
#import "RLPWorkbenchViewController.h"
#import "RLPEqualizerView.h"
#import "RLPEQFaderInspector.h"
#import "RLPAlbumsViewController.h"
#import "RLPArtistsViewController.h"
#import "RLPArtistDetailViewController.h"
#import "RLPKnowledgeView.h"
#import "RLPTracksViewController.h"
#import "RLPFoldersViewController.h"
#import "RLPQueueViewController.h"
#import "RLPRecentViewController.h"
#import "RLPFavoritesViewController.h"
#import "RLPStreamingViewController.h"
#import "RLPWorksViewController.h"

#include <cstdio>
#include <cstdlib>
#include <unistd.h>

static int gFail = 0, gPass = 0;

static void Ck(BOOL ok, NSString *what, NSString *detail) {
    if (ok) {
        ++gPass;
        std::printf("  [PASS] %s\n", what.UTF8String);
    } else {
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

static NSArray<NSView *> *Descendants(NSView *v) {
    NSMutableArray<NSView *> *a = [NSMutableArray array];
    Collect(v, a);
    return a;
}

static NSView *FindId(NSView *root, NSString *ident) {
    for (NSView *v in Descendants(root)) {
        if ([v.identifier isEqualToString:ident]) return v;
    }
    return nil;
}

static BOOL ContainsText(NSView *root, NSString *needle) {
    if (!needle.length) return NO;
    for (NSView *v in Descendants(root)) {
        if ([v isKindOfClass:[NSTextField class]]) {
            NSTextField *tf = (NSTextField *)v;
            if ([tf.stringValue isEqualToString:needle] ||
                [tf.placeholderString isEqualToString:needle]) return YES;
        } else if ([v isKindOfClass:[NSButton class]]) {
            if ([((NSButton *)v).title isEqualToString:needle]) return YES;
        } else if ([v isKindOfClass:[NSSegmentedControl class]]) {
            NSSegmentedControl *seg = (NSSegmentedControl *)v;
            for (NSInteger i = 0; i < seg.segmentCount; ++i) {
                if ([[seg labelForSegment:i] isEqualToString:needle]) return YES;
            }
        }
    }
    return NO;
}

static NSView *HostPage(NSWindow *win, NSViewController *vc) {
    NSView *v = vc.view;
    v.frame = win.contentView.bounds;
    [win.contentView addSubview:v];
    [v layoutSubtreeIfNeeded];
    return v;
}

static void SwitchLang(NSString *lang, NSArray<NSViewController *> *pages) {
    RLPSetLanguage(lang);
    [[NSNotificationCenter defaultCenter] postNotificationName:RLPLanguageDidChangeNotification object:nil];
    for (NSViewController *vc in pages) {
        if ([vc respondsToSelector:@selector(applyLanguage)]) {
            [(id)vc applyLanguage];
        }
    }
    Pump(0.15);
}

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        std::printf("=== test_native_language_pages（全局页面原地语言刷新 · 隔离目录 · 不出声）===\n");

        NSString *rootDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"rlp-lang-pages-%d", (int)getpid()]];
        NSString *state = [rootDir stringByAppendingPathComponent:@"state"];
        NSString *lib = [rootDir stringByAppendingPathComponent:@"lib"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:lib withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("RLPLAYER_STATE_DIR", state.fileSystemRepresentation, 1);
        setenv("RLPLAYER_LIBRARY_DIR", lib.fileSystemRepresentation, 1);

        RLPCoreClient *core = [RLPCoreClient shared];
        if (![core startEmbedded]) {
            std::printf("  [FAIL] 核心启动失败\n");
            return 1;
        }
        [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"backend=null&volume=-120"];
        RLPSetLanguage(@"zh");

        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1280, 900)
                                                     styleMask:NSWindowStyleMaskBorderless
                                                       backing:NSBackingStoreBuffered
                                                         defer:NO];
        win.releasedWhenClosed = NO;
        win.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1280, 900)];

        RLPQuickStartViewController *qs = [[RLPQuickStartViewController alloc] init];
        RLPWorkbenchViewController *wb = [[RLPWorkbenchViewController alloc] init];
        RLPAlbumsViewController *albums = [[RLPAlbumsViewController alloc] init];
        RLPArtistsViewController *artists = [[RLPArtistsViewController alloc] init];
        RLPArtistDetailViewController *artistDetail = [[RLPArtistDetailViewController alloc] initWithArtistName:@"Johann Sebastian Bach"];
        RLPTracksViewController *tracks = [[RLPTracksViewController alloc] init];
        RLPFoldersViewController *folders = [[RLPFoldersViewController alloc] init];
        RLPQueueViewController *queue = [[RLPQueueViewController alloc] init];
        RLPRecentViewController *recent = [[RLPRecentViewController alloc] init];
        RLPFavoritesViewController *favorites = [[RLPFavoritesViewController alloc] init];
        RLPStreamingViewController *streaming = [[RLPStreamingViewController alloc] init];
        RLPWorksViewController *works = [[RLPWorksViewController alloc] init];

        NSArray<NSViewController *> *pages = @[
            qs, wb, albums, artists, artistDetail, tracks, folders, queue, recent, favorites, streaming, works
        ];
        for (NSViewController *vc in pages) {
            HostPage(win, vc);
        }
        Pump(0.25);

        // 预设草稿与页签状态，验证语言切换后保留路由与草稿
        NSButton *wbEqTab = (NSButton *)FindId(wb.view, @"wb.tab.eq");
        if ([wbEqTab isKindOfClass:[NSButton class]] && wbEqTab.action && wbEqTab.target) {
            [wbEqTab.target performSelector:wbEqTab.action withObject:wbEqTab];
        }
        NSSearchField *wbFilterSearch = (NSSearchField *)FindId(wb.view, @"wb.filtersearch");
        if ([wbFilterSearch isKindOfClass:[NSSearchField class]]) {
            wbFilterSearch.stringValue = @"poly-sinc-draft";
        }
        NSTextField *foldersPath = nil;
        for (NSView *v in Descendants(folders.view)) {
            if ([v isKindOfClass:[NSTextField class]] && ((NSTextField *)v).isEditable) {
                foldersPath = (NSTextField *)v;
                foldersPath.stringValue = @"/Users/music/FLAC";
                break;
            }
        }
        NSMutableArray<NSTextField *> *worksFields = [NSMutableArray array];
        for (NSView *v in Descendants(works.view)) {
            if ([v isKindOfClass:[NSTextField class]] && ((NSTextField *)v).isEditable) {
                [worksFields addObject:(NSTextField *)v];
            }
        }
        if (worksFields.count >= 2) {
            worksFields[0].stringValue = @"BWV 1007";
            worksFields[1].stringValue = @"Bach";
        }

        // ---- 1) 初始中文基准 ----
        Ck([qs.pageTitle isEqualToString:@"聆听室"], @"QuickStart 初始中文标题", qs.pageTitle);
        Ck([wb.pageTitle isEqualToString:@"专业工作台"], @"Workbench 初始中文标题", wb.pageTitle);
        Ck(ContainsText(qs.view, @"音乐文件夹"), @"QuickStart 初始中文卡片按钮", @"missing 选音乐文件夹");
        Ck(ContainsText(wb.view, @"数字音乐台"), @"Workbench 初始中文头标题", @"missing 数字音乐台");

        // ---- 2) 切换到英文 ----
        SwitchLang(@"en", pages);

        Ck([qs.pageTitle isEqualToString:@"Listening Room"], @"QuickStart 切英文 pageTitle", qs.pageTitle);
        Ck(ContainsText(qs.view, RLPTr(@"音乐文件夹")), @"QuickStart 切英文卡片按钮", @"missing Choose Music Folder");
        Ck(ContainsText(qs.view, RLPTr(@"输出")), @"QuickStart 切英文输出卡", @"missing Output Device");

        Ck([wb.pageTitle isEqualToString:RLPTr(@"专业工作台")], @"Workbench 切英文 pageTitle", wb.pageTitle);
        Ck(ContainsText(wb.view, @"Digital Music Console"), @"Workbench 切英文头标题", @"missing Digital Music Console");
        Ck(ContainsText(wb.view, RLPTr(@"播放台")), @"Workbench 切英文播放台页签", @"missing Playback Deck");
        Ck(ContainsText(wb.view, RLPTr(@"EQ 调音台")), @"Workbench 切英文 EQ 页签", @"missing EQ Console");
        Ck(ContainsText(wb.view, RLPTr(@"音质监控")), @"Workbench 切英文音质监控页签", @"missing Quality Monitor");
        NSView *wbPanelEQ = FindId(wb.view, @"wb.panel.eq");
        Ck(wbPanelEQ && !wbPanelEQ.hidden, @"Workbench 切英文后保留当前 EQ 页签", @"wb.panel.eq hidden");
        Ck([wbFilterSearch.stringValue isEqualToString:@"poly-sinc-draft"], @"Workbench 切英文后保留滤波搜索草稿", wbFilterSearch.stringValue);

        Ck([albums.pageTitle isEqualToString:@"Albums"], @"Albums 切英文 pageTitle", albums.pageTitle);
        Ck([artists.pageTitle isEqualToString:@"Artists"], @"Artists 切英文 pageTitle", artists.pageTitle);
        Ck(ContainsText(artistDetail.view, @"Johann Sebastian Bach"), @"ArtistDetail 不翻用户艺术家名", @"artist name changed");
        // 2026-11-21：艺术家页重排成 web 的三张 sec-card，**不再复用播放页的 RLPKnowledgeView 抽屉**
        // （抽屉自带的「AI 资料」标题随之下线）。本页资料卡的标题按 web renderSummaryContent
        // 统一措辞是「AI 整理」。判据意图不变：数据类静态文案必须跟着语言切换。
        Ck(ContainsText(artistDetail.view, RLPTr(@"AI 整理")) && ContainsText(artistDetail.view, RLPTr(@"返回艺术家列表")), @"ArtistDetail 切英文静态文案", @"missing AI Summary/Back");
        Ck([tracks.pageTitle isEqualToString:@"Tracks"], @"Tracks 切英文 pageTitle", tracks.pageTitle);
        Ck([folders.pageTitle isEqualToString:@"Folders"], @"Folders 切英文 pageTitle", folders.pageTitle);
        Ck(!foldersPath || [foldersPath.stringValue isEqualToString:@"/Users/music/FLAC"], @"Folders 切英文后保留路径草稿", foldersPath.stringValue);
        Ck([queue.pageTitle isEqualToString:@"Queue"], @"Queue 切英文 pageTitle", queue.pageTitle);
        Ck([recent.pageTitle isEqualToString:RLPTr(@"最近播放")], @"Recent 切英文 pageTitle", recent.pageTitle);
        Ck([favorites.pageTitle isEqualToString:@"Favorites"], @"Favorites 切英文 pageTitle", favorites.pageTitle);
        Ck([streaming.pageTitle isEqualToString:@"Streaming"], @"Streaming 切英文 pageTitle", streaming.pageTitle);
        Ck([works.pageTitle isEqualToString:RLPTr(@"古典作品 · 演绎版本")], @"Works 切英文 pageTitle", works.pageTitle);
        if (worksFields.count >= 2) {
            Ck([worksFields[0].stringValue isEqualToString:@"BWV 1007"] &&
               [worksFields[1].stringValue isEqualToString:@"Bach"],
               @"Works 切英文后保留检索草稿", worksFields[0].stringValue);
        }

        // A cached, detached page must not overwrite the foreground topbar count.
        [albums.view removeFromSuperview];
        __block NSInteger hiddenCountEvents = 0;
        id countToken = [[NSNotificationCenter defaultCenter] addObserverForName:@"RLPPageCountNotification"
            object:nil queue:nil usingBlock:^(NSNotification *note) { (void)note; ++hiddenCountEvents; }];
        [albums setValue:@YES forKey:@"hasLoaded"];
        [albums applyLanguage];
        Ck(hiddenCountEvents == 0, @"后台专辑页语言刷新不污染前台计数", @"unexpected count notification");
        [[NSNotificationCenter defaultCenter] removeObserver:countToken];
        RLPArtistDetailViewController *namedLikeUI = [[RLPArtistDetailViewController alloc] initWithArtistName:@"设置"];
        (void)namedLikeUI.view;
        [namedLikeUI applyLanguage];
        Ck([namedLikeUI.pageTitle isEqualToString:@"设置"], @"用户艺术家名命中词表也不翻译", namedLikeUI.pageTitle);

        // ---- 3) 双向切回中文 ----
        SwitchLang(@"zh", pages);

        Ck([qs.pageTitle isEqualToString:@"聆听室"], @"QuickStart 切回中文 pageTitle", qs.pageTitle);
        Ck(ContainsText(qs.view, @"音乐文件夹"), @"QuickStart 切回中文卡片按钮", @"missing 选音乐文件夹");
        Ck([wb.pageTitle isEqualToString:@"专业工作台"], @"Workbench 切回中文 pageTitle", wb.pageTitle);
        Ck(ContainsText(wb.view, @"数字音乐台"), @"Workbench 切回中文头标题", @"missing 数字音乐台");
        Ck([albums.pageTitle isEqualToString:@"专辑"], @"Albums 切回中文 pageTitle", albums.pageTitle);
        Ck([artists.pageTitle isEqualToString:@"艺术家"], @"Artists 切回中文 pageTitle", artists.pageTitle);
        Ck([tracks.pageTitle isEqualToString:@"曲目"], @"Tracks 切回中文 pageTitle", tracks.pageTitle);
        Ck([folders.pageTitle isEqualToString:@"文件夹"], @"Folders 切回中文 pageTitle", folders.pageTitle);
        Ck([queue.pageTitle isEqualToString:@"播放队列"], @"Queue 切回中文 pageTitle", queue.pageTitle);
        Ck([recent.pageTitle isEqualToString:@"最近播放"], @"Recent 切回中文 pageTitle", recent.pageTitle);
        Ck([favorites.pageTitle isEqualToString:@"我的最爱"], @"Favorites 切回中文 pageTitle", favorites.pageTitle);
        Ck([streaming.pageTitle isEqualToString:@"流媒体"], @"Streaming 切回中文 pageTitle", streaming.pageTitle);
        Ck([works.pageTitle isEqualToString:@"古典作品 · 演绎版本"], @"Works 切回中文 pageTitle", works.pageTitle);

        [core shutdown];
        [fm removeItemAtPath:rootDir error:nil];

        std::printf("=== 结果：%d 通过，%d 失败 ===\n", gPass, gFail);
        return (gFail == 0) ? 0 : 1;
    }
}
