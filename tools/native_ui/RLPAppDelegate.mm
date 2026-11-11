// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <MediaPlayer/MediaPlayer.h>
#import "RLPAppDelegate.h"
#import "RLPSupport.h"
#import "RLPCoreClient.h"
#import "RLPMainWindowController.h"
#import "RLPPlaybackBarView.h"
#import "RLPSidebarViewController.h"
#import "RLPAlbumsViewController.h"
#import "RLPTheme.h"
// selftest 要逐个构造迁移页面：把它们的头文件都 include 进来，少一个就编不过（这本身也是判据）
#import "RLPAlbumDetailViewController.h"
#import "RLPArtistDetailViewController.h"
#import "RLPArtistsViewController.h"
#import "RLPTracksViewController.h"
#import "RLPFoldersViewController.h"
#import "RLPQueueViewController.h"
#import "RLPRecentViewController.h"
#import "RLPFavoritesViewController.h"
#import "RLPSettingsViewController.h"
#import "RLPNowPlayingViewController.h"
#import "RLPUpdateWindowController.h"
#import "RLPStreamingViewController.h"
#import "RLPQuickStartViewController.h"

#include <cstdio>

#include "version.h"
#include "rlapp_core.h"

static int gSelfTestFail = 0;
static void STCheck(BOOL ok, const char *what, NSString *detail) {
    if (ok) {
        printf("  [PASS] %s\n", what);
    } else {
        printf("  [FAIL] %s  %s\n", what, detail.UTF8String ?: "");
        ++gSelfTestFail;
    }
}

@interface RLPAppDelegate ()
@property (nonatomic, strong) RLPMainWindowController *mainWC;
@property (nonatomic, strong) NSTimer *exitPoll;
@end

@implementation RLPAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [self buildMenu];
    NSString *savedTheme = [[NSUserDefaults standardUserDefaults] stringForKey:@"RLPThemeName"];
    if (savedTheme.length) [RLPTheme setThemeName:savedTheme];
    [[RLPCoreClient shared] startEmbedded];

    self.mainWC = [[RLPMainWindowController alloc] init];
    [self.mainWC showWindow:nil];
    [self.mainWC.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self.mainWC loadInitialData];
    [self setupRemoteCommands];
    [self setupNowPlayingCenter];

    self.exitPoll = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
        if (rlapp::exit_requested()) {
            [t invalidate];
            [NSApp terminate:nil];
        }
    }];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }

- (void)applicationWillTerminate:(NSNotification *)note {
    [self.exitPoll invalidate];
    [self.mainWC stopAllActivity];
    [[RLPCoreClient shared] shutdown];
}

// ---------------- 菜单（原生入口与快捷键的唯一落点） ----------------
- (void)buildMenu {
    NSMenu *bar = [[NSMenu alloc] init];

    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"RLPlayer"];
    NSString *ver = [NSString stringWithUTF8String:RLPLAYER_VERSION];
    [appMenu addItemWithTitle:[NSString stringWithFormat:@"关于 RLPlayer %@", ver] action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    // ⌘, 打开设置：这是 macOS 的固定约定（HIG），用户不需要被告知。
    NSMenuItem *pref = [appMenu addItemWithTitle:RLPTr(@"设置…")
                                          action:@selector(menuOpenSettings:)
                                   keyEquivalent:@","];
    pref.target = self;
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [appMenu addItemWithTitle:@"退出 RLPlayer" action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    appItem.submenu = appMenu;
    [bar addItem:appItem];

    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"编辑"];
    [edit addItemWithTitle:@"撤销" action:@selector(undo:) keyEquivalent:@"z"];
    [edit addItemWithTitle:@"重做" action:@selector(redo:) keyEquivalent:@"Z"];
    [edit addItem:[NSMenuItem separatorItem]];
    [edit addItemWithTitle:@"剪切" action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:@"拷贝" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"粘贴" action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:@"全选" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = edit;
    [bar addItem:editItem];

    NSMenuItem *playItem = [[NSMenuItem alloc] init];
    NSMenu *play = [[NSMenu alloc] initWithTitle:@"播放"];
    NSMenuItem *toggle = [play addItemWithTitle:@"播放 / 暂停" action:@selector(menuPlayPause:) keyEquivalent:@" "];
    toggle.target = self;
    NSMenuItem *next = [play addItemWithTitle:@"下一首" action:@selector(menuNext:) keyEquivalent:[NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey]];
    next.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    next.target = self;
    NSMenuItem *prev = [play addItemWithTitle:@"上一首" action:@selector(menuPrev:) keyEquivalent:[NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey]];
    prev.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    prev.target = self;
    playItem.submenu = play;
    [bar addItem:playItem];

    NSApp.mainMenu = bar;
}

- (void)menuPlayPause:(id)sender { [self.mainWC.playbackBar playPause]; }
- (void)menuNext:(id)sender { [self.mainWC.playbackBar nextTrack]; }
- (void)menuPrev:(id)sender { [self.mainWC.playbackBar previousTrack]; }

- (void)menuOpenSettings:(id)sender {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenSettingsPaneNotification"
                                                        object:@"adv"];
}

/// 锁屏/控制中心显示"正在播放"的信息。
/// 只做**如实上报**：拿不到信息就清空，不填假标题。
- (void)setupNowPlayingCenter {
    MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
    center.playbackState = MPNowPlayingPlaybackStateStopped;
}

#pragma mark - 媒体键（F7/F8/F9 与蓝牙耳机按键）

/// 接 MPRemoteCommandCenter：不加这一段，键盘上的播放/上一首/下一首在 app 不是前台时**完全无效**。
/// 这是原生客户端的必备能力（web 版靠页面 JS 做不到）。
/// 纪律：只注册命令并转发到播放条（幂等动作），不在这里自己维护播放状态。
- (void)setupRemoteCommands {
    MPRemoteCommandCenter *cc = [MPRemoteCommandCenter sharedCommandCenter];
    __weak __typeof__(self) weakSelf = self;

    [cc.playCommand setEnabled:YES];
    [cc.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        (void)e;
        __typeof__(self) self_ = weakSelf;
        if (!self_) return MPRemoteCommandHandlerStatusCommandFailed;
        // play 语义是"继续播放"，但如果本来在播就什么都不做（幂等）
        if (!self_.mainWC.playbackBar.isPlaying) [self_.mainWC.playbackBar playPause];
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    [cc.pauseCommand setEnabled:YES];
    [cc.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        (void)e;
        __typeof__(self) self_ = weakSelf;
        if (!self_) return MPRemoteCommandHandlerStatusCommandFailed;
        if (self_.mainWC.playbackBar.isPlaying) [self_.mainWC.playbackBar playPause];
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    [cc.togglePlayPauseCommand setEnabled:YES];
    [cc.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        (void)e;
        __typeof__(self) self_ = weakSelf;
        if (!self_) return MPRemoteCommandHandlerStatusCommandFailed;
        [self_.mainWC.playbackBar playPause];
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    [cc.nextTrackCommand setEnabled:YES];
    [cc.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        (void)e;
        __typeof__(self) self_ = weakSelf;
        if (!self_) return MPRemoteCommandHandlerStatusCommandFailed;
        [self_.mainWC.playbackBar nextTrack];
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    [cc.previousTrackCommand setEnabled:YES];
    [cc.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        (void)e;
        __typeof__(self) self_ = weakSelf;
        if (!self_) return MPRemoteCommandHandlerStatusCommandFailed;
        [self_.mainWC.playbackBar previousTrack];
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    // 进度拖动（耳机线控/锁屏拖拽）
    [cc.changePlaybackPositionCommand setEnabled:YES];
    [cc.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *ev) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return MPRemoteCommandHandlerStatusCommandFailed;
        MPRemoteCommand *cmd = (MPRemoteCommand *)nil;
        (void)cmd;
        if (![ev isKindOfClass:[MPChangePlaybackPositionCommandEvent class]])
            return MPRemoteCommandHandlerStatusCommandFailed;
        MPChangePlaybackPositionCommandEvent *pe = (MPChangePlaybackPositionCommandEvent *)ev;
        [self_.mainWC.playbackBar seekToSeconds:pe.positionTime];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
}

@end

// ===========================================================================
// 离线自检：只构建视图树与契约，不启动核心、不读用户曲库、不联网。
// ===========================================================================
static void CollectViews(NSView *v, NSMutableArray<NSView *> *out) {
    if (!v) return;
    [out addObject:v];
    for (NSView *s in v.subviews) CollectViews(s, out);
}

int RLPAppDelegateRunSelfTest(void) {
    printf("=== rlplayer_native self-test（纯视图树，无核心/无网络）===\n");
    NSApplication *app = [NSApplication sharedApplication];
    (void)app;

    RLPMainWindowController *wc = [[RLPMainWindowController alloc] init];
    NSWindow *win = wc.window;
    STCheck(win != nil, "主窗口已创建", @"");
    if (win) {
        STCheck(win.frame.size.width >= 900 && win.frame.size.height >= 600,
                "默认窗口尺寸 >= 900x600", NSStringFromSize(win.frame.size));
        STCheck([win.contentView isKindOfClass:[NSView class]], "contentView 是原生 NSView", @"");
    }
    STCheck(wc.sidebar != nil, "侧栏导航已创建", @"");
    STCheck(wc.sidebar.rowCount == 10, "侧栏导航 10 项（与 web 版一致）",
            [NSString stringWithFormat:@"rows=%ld", (long)wc.sidebar.rowCount]);
    STCheck(wc.albums != nil, "专辑网格已创建", @"");
    STCheck(wc.playbackBar != nil, "播放条已创建", @"");
    STCheck(wc.playbackBar.polling == NO, "selftest 不启动状态轮询（无核心时不发请求）", @"");

    NSMutableArray<NSView *> *all = [NSMutableArray array];
    CollectViews(win.contentView, all);
    BOOL anyWeb = NO;
    for (NSView *v in all) {
        if ([NSStringFromClass(v.class) containsString:@"WKWebView"]) anyWeb = YES;
    }
    STCheck(!anyWeb, "主内容区没有任何 WKWebView（纯 AppKit）",
            [NSString stringWithFormat:@"views=%lu", (unsigned long)all.count]);
    STCheck(all.count >= 10, "视图树节点数 >= 10", [NSString stringWithFormat:@"views=%lu", (unsigned long)all.count]);

    // ---- 1.1.7.1 迁移页契约：每个页面都必须能离线构造出来（不启动核心、不发请求）----
    // 判据是"能建出来 + 关键控件在位"，不是"看起来像"。页面若依赖核心数据才可见，
    // 那它就不该在 selftest 里要求网络 —— 所以这里只断言控件骨架。
    {
        RLPStreamingViewController *vc = [[RLPStreamingViewController alloc] init];
        STCheck(vc.view != nil, "流媒体页可离线构建", @"");
        STCheck(vc.pageTitle.length > 0, "流媒体页有标题", vc.pageTitle ?: @"");
    }
    {
        RLPQuickStartViewController *vc = [[RLPQuickStartViewController alloc] init];
        STCheck(vc.view != nil, "快速开始页可离线构建", @"");
    }
    {
        RLPSettingsViewController *vc = [[RLPSettingsViewController alloc] init];
        STCheck(vc.view != nil, "设置页可离线构建", @"");
        // 10 个页签是"功能不删减"的硬指标：少一个就是少了一整块功能。
        NSMutableArray<NSView *> *sv = [NSMutableArray array];
        CollectViews(vc.view, sv);
        NSSegmentedControl *seg = nil;
        for (NSView *v in sv) {
            if ([v isKindOfClass:[NSSegmentedControl class]]) { seg = (NSSegmentedControl *)v; break; }
        }
        STCheck(seg != nil, "设置页有页签控件", @"");
        STCheck(seg.segmentCount == 10, "设置页 10 个页签（与 web 版一致）",
                seg ? [NSString stringWithFormat:@"segments=%ld", (long)seg.segmentCount] : @"nil");
    }
    {
        RLPAlbumDetailViewController *vc = [[RLPAlbumDetailViewController alloc] initWithAlbumKey:@"selftest"];
        STCheck(vc.view != nil, "专辑详情页可离线构建", @"");
    }
    {
        RLPArtistDetailViewController *vc = [[RLPArtistDetailViewController alloc] initWithArtistName:@"selftest"];
        STCheck(vc.view != nil, "艺术家详情页可离线构建", @"");
    }
    {
        RLPNowPlayingViewController *vc = [[RLPNowPlayingViewController alloc] init];
        STCheck(vc.view != nil, "正在播放页可离线构建", @"");
    }
    {
        RLPTracksViewController *vc = [[RLPTracksViewController alloc] init];
        STCheck(vc.view != nil, "曲目页可离线构建", @"");
    }
    {
        RLPArtistsViewController *vc = [[RLPArtistsViewController alloc] init];
        STCheck(vc.view != nil, "艺术家页可离线构建", @"");
    }
    {
        RLPFoldersViewController *vc = [[RLPFoldersViewController alloc] init];
        STCheck(vc.view != nil, "文件夹页可离线构建", @"");
    }
    {
        RLPQueueViewController *vc = [[RLPQueueViewController alloc] init];
        STCheck(vc.view != nil, "队列页可离线构建", @"");
    }
    {
        RLPRecentViewController *vc = [[RLPRecentViewController alloc] init];
        STCheck(vc.view != nil, "最近播放页可离线构建", @"");
    }
    {
        RLPFavoritesViewController *vc = [[RLPFavoritesViewController alloc] init];
        STCheck(vc.view != nil, "我的最爱页可离线构建", @"");
    }
    // 更新窗口：一窗两视图 + 五出口（借 QQ 音乐的结构，不照搬资源）
    {
        RLPUpdateWindowController *wc2 = [RLPUpdateWindowController shared];
        STCheck(wc2.window != nil, "更新窗口可离线构建", @"");
        NSMutableArray<NSView *> *uv = [NSMutableArray array];
        CollectViews(wc2.window.contentView, uv);
        NSInteger buttons = 0;
        for (NSView *v in uv) if ([v isKindOfClass:[NSButton class]]) ++buttons;
        STCheck(buttons >= 5, "更新窗口有 5 个出口按钮",
                [NSString stringWithFormat:@"buttons=%ld", (long)buttons]);
    }
    // 播放模式按钮（随机/循环）必须在播放条里 —— 这是本轮"借鉴 QQ 音乐"的可测落点
    {
        NSMutableArray<NSView *> *pv = [NSMutableArray array];
        CollectViews(wc.playbackBar, pv);
        NSInteger sym = 0;
        for (NSView *v in pv) {
            if (![v isKindOfClass:[NSButton class]]) continue;
            NSButton *b = (NSButton *)v;
            if ([b.toolTip containsString:@"随机"] || [b.toolTip containsString:@"循环"]) ++sym;
        }
        STCheck(sym >= 2, "播放条有随机与循环按钮",
                [NSString stringWithFormat:@"modeButtons=%ld", (long)sym]);
    }

    printf("\n%s（%d 项失败）\n", gSelfTestFail == 0 ? "native_ui selftest 全部通过" : "native_ui selftest 有失败", gSelfTestFail);
    return gSelfTestFail == 0 ? 0 : gSelfTestFail;
}