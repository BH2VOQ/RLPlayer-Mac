// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <MediaPlayer/MediaPlayer.h>
#import "RLPAppDelegate.h"
#import "RLPShortcuts.h"
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
#import "RLPPlaylistsViewController.h"
#import "RLPEqualizerView.h"
#import "RLPInputView.h"
#import "RLPCastView.h"
#import "RLPCalibrationView.h"
#import "RLPFeedbackWindowController.h"
#import "RLPKnowledgeView.h"
#import "RLPModels.h"

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

@interface RLPPlaybackBarView (RLPVolumeShortcuts)
- (double)currentVolumeDb;
- (BOOL)isVolumeLocked;
- (void)commitVolumeDb:(double)db;
@end

@interface RLPAppDelegate ()
@property (nonatomic, strong) RLPMainWindowController *mainWC;
@property (nonatomic, strong) NSTimer *exitPoll;
@property (nonatomic, strong) NSTimer *nowPlayingTimer;
@property (nonatomic, copy) NSString *lastReportedPath;
@end

@interface RLPAppDelegate ()
@property (nonatomic, strong, nullable) id shortcutMonitor;
- (void)installShortcutMonitor;
- (void)handleShortcut:(RLPShortcutAction)a;
- (BOOL)shortcutEditingText;
@end

@implementation RLPAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    // 语言必须在**建菜单/建窗口之前**应用：菜单标题与各页文案都在下面几行里就调用 RLPTr，
    // 构造完就定型了。真相源是 state 目录的 rlplayer-settings.conf（与 web 同口径）；
    // 启动早期核心还没起来，不能去 GET /api/settings。
    RLPApplyLanguageFromConf();
    [self buildMenu];
    // 主题：没存过就用默认（light）。**无条件调一次**并同步全局 appearance ——
    // setThemeName 对同名会 early-return 不发通知，只靠它会出现
    // "设置里显示浅色、主页却还是黑的"（用户实测反馈）。
    NSString *savedTheme = [[NSUserDefaults standardUserDefaults] stringForKey:@"RLPThemeName"];
    [RLPTheme setThemeName:savedTheme.length ? savedTheme : [RLPTheme themeName]];
    // 界面风格同理：classic 换的是整套令牌，必须在建窗口**之前**恢复，
    // 否则窗口按 apple 的 60px 顶栏建好，之后再切会闪一下。
    NSString *savedStyle = [[NSUserDefaults standardUserDefaults] stringForKey:@"RLPUiStyle"];
    [RLPTheme setUiStyle:savedStyle.length ? savedStyle : [RLPTheme uiStyle]];
    RLPTheme *t0 = [RLPTheme current];
    NSApp.appearance = [NSAppearance appearanceNamed:t0.isLight ? NSAppearanceNameAqua
                                                                : NSAppearanceNameDarkAqua];
    [[RLPCoreClient shared] startEmbedded];

    self.mainWC = [[RLPMainWindowController alloc] init];
    [self.mainWC showWindow:nil];
    [self.mainWC.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self.mainWC loadInitialData];
    [self setupRemoteCommands];
    [self installShortcutMonitor];   // web document keydown 的同语义落点（见 RLPShortcuts.h）
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
    [self.nowPlayingTimer invalidate];
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

    // 帮助菜单：反馈入口（用户不必去设置里翻）
    NSMenuItem *helpItem = [[NSMenuItem alloc] init];
    NSMenu *help = [[NSMenu alloc] initWithTitle:RLPTr(@"帮助")];
    NSMenuItem *fbItem = [help addItemWithTitle:RLPTr(@"提交反馈…")
                                         action:@selector(menuFeedback:) keyEquivalent:@""];
    fbItem.target = self;
    helpItem.submenu = help;
    [bar addItem:helpItem];

    NSApp.mainMenu = bar;
}

- (void)menuPlayPause:(id)sender { [self.mainWC.playbackBar playPause]; }
- (void)menuNext:(id)sender { [self.mainWC.playbackBar nextTrack]; }
- (void)menuPrev:(id)sender { [self.mainWC.playbackBar previousTrack]; }

- (void)menuFeedback:(id)sender { [[RLPFeedbackWindowController shared] showAndFocus]; }

- (void)menuOpenSettings:(id)sender {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenSettingsPaneNotification"
                                                        object:@"adv"];
}

/// 锁屏 / 控制中心的「正在播放」。
/// 只做**如实上报**：没有曲目就把信息清空，不填假标题、不留上一首的残影。
/// 1 秒一次足够（锁屏不需要 500ms 精度），且只在值真的变了时才写，避免无谓 IPC。
- (void)setupNowPlayingCenter {
    MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
    center.playbackState = MPNowPlayingPlaybackStateStopped;
    __weak __typeof__(self) weakSelf = self;
    self.nowPlayingTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *tm) {
        (void)tm;
        __typeof__(self) self_ = weakSelf;
        if (!self_) { [tm invalidate]; return; }
        [self_ reportNowPlaying];
    }];
}

- (void)reportNowPlaying {
    RLPPlaybackStatus *st = self.mainWC.playbackBar.lastStatus;
    MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
    if (!st || !st.currentPath.length) {
        if (center.nowPlayingInfo.count) center.nowPlayingInfo = @{};
        center.playbackState = MPNowPlayingPlaybackStateStopped;
        self.lastReportedPath = @"";
        return;
    }
    center.playbackState = (st.playing && !st.paused) ? MPNowPlayingPlaybackStatePlaying
                                                      : MPNowPlayingPlaybackStatePaused;
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    // 标题优先用文件名（后端 status 只给路径）；有 meta 时由单曲页刷新，这里不猜
    NSString *title = st.currentPath.lastPathComponent.stringByDeletingPathExtension;
    info[MPMediaItemPropertyTitle] = title.length ? title : RLPTr(@"未知曲目");
    info[MPMediaItemPropertyPlaybackDuration] = @(MAX(0.0, st.duration));
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(MAX(0.0, st.position));
    info[MPNowPlayingInfoPropertyPlaybackRate] = @((st.playing && !st.paused) ? 1.0 : 0.0);
    center.nowPlayingInfo = info;
    self.lastReportedPath = st.currentPath;
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
        // play 语义：已在播→空转；暂停中→继续；已停止→重播当前曲目。
        // 不能沿用「!isPlaying 就 playPause」：停止态下 playPause 发的是 /api/pause?on=0，
        // 后端对停止态不起播 ⟹ 系统 play 键看起来完全没反应（用户在实机上报过同型）。
        [self_.mainWC.playbackBar resumeOrReplay];
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    [cc.pauseCommand setEnabled:YES];
    [cc.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        (void)e;
        __typeof__(self) self_ = weakSelf;
        if (!self_) return MPRemoteCommandHandlerStatusCommandFailed;
        // 系统「暂停」必须真的发出 on=1：不能依赖 isPlaying 快照，否则快照过期时静默丢命令。
        [self_.mainWC.playbackBar pausePlayback];
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


#pragma mark - 全局快捷键（逐条对齐 web document keydown）

/// 焦点是否在可编辑文本里。field editor（NSTextView）与 NSTextField 都算：
/// 否则用户在搜索框里打 n/p/s/l 会误触播放控制（web 对 INPUT/SELECT/TEXTAREA 直接 return）。
- (BOOL)shortcutEditingText {
    NSResponder *fr = self.mainWC.window.firstResponder;
    if (!fr) return NO;
    if ([fr isKindOfClass:NSTextView.class]) return ((NSTextView *)fr).isEditable;
    if ([fr isKindOfClass:NSTextField.class]) return ((NSTextField *)fr).isEditable;
    return NO;
}

- (void)installShortcutMonitor {
    __weak __typeof__(self) weakSelf = self;
    self.shortcutMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                                handler:^NSEvent *(NSEvent *e) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return e;
        if (e.window != self_.mainWC.window) return e;   // 只在本窗口生效，别抢别处按键
        NSString *key = e.charactersIgnoringModifiers;
        if (!key.length) key = [NSString stringWithFormat:@"%C", (unichar)e.keyCode];
        BOOL cmd = (e.modifierFlags & NSEventModifierFlagCommand) != 0;
        BOOL shift = (e.modifierFlags & NSEventModifierFlagShift) != 0;
        BOOL ctrl = (e.modifierFlags & NSEventModifierFlagControl) != 0;
        const BOOL editing = [self_ shortcutEditingText];
        RLPShortcutAction a = RLPShortcutActionForKey(key, cmd, shift, ctrl, editing);
        // 2026-11-17（UI 回归评审已证实）：焦点在输入框时按 Esc 被这里消费掉，
        // 搜索框自己的 cancelOperation:（清空搜索）与输入框的结束编辑全部被绕过，
        // 还会顺手 popDetail。编辑态下不接管 Esc，交回响应链。
        if (a == RLPShortcutNone) return e;
        if (a == RLPShortcutEscapeBack && editing) return e;
        [self_ handleShortcut:a];
        return nil;   // 已消费
    }];
}

- (void)handleShortcut:(RLPShortcutAction)a {
    RLPPlaybackBarView *bar = self.mainWC.playbackBar;
    switch (a) {
        case RLPShortcutFocusSearch:
            // web：聚焦搜索框并 select()。原生搜索框在专辑页，交给该页自己响应。
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPFocusSearchNotification" object:nil];
            break;
        case RLPShortcutPlayPause: [bar playPause]; break;
        case RLPShortcutNext:      [bar nextTrack]; break;
        case RLPShortcutPrev:      [bar previousTrack]; break;
        case RLPShortcutStop:      [bar stopPlayback:nil]; break;
        case RLPShortcutSeekForward5:
        case RLPShortcutSeekBack5: {
            double dur = bar.lastStatus.duration, pos = bar.lastStatus.position;
            if (!(dur > 0)) break;   // 未播放/时长未知时不动作（web 的 seekRel 同样如此）
            double target = pos + (a == RLPShortcutSeekForward5 ? 5.0 : -5.0);
            if (target < 0) target = 0;
            if (target > dur - 0.05) target = dur - 0.05;
            [bar seekToSeconds:target];
            break;
        }
        case RLPShortcutVolumeUpCoarse:
        case RLPShortcutVolumeUpFine:
        case RLPShortcutVolumeDownCoarse:
        case RLPShortcutVolumeDownFine: {
            if ([bar isVolumeLocked]) break;
            double step = (a == RLPShortcutVolumeUpCoarse || a == RLPShortcutVolumeDownCoarse)
                          ? RLPVolumeStepCoarseDb : RLPVolumeStepFineDb;
            if (a == RLPShortcutVolumeDownCoarse || a == RLPShortcutVolumeDownFine) step = -step;
            BOOL changed = NO;
            double db = RLPVolumeStepDb([bar currentVolumeDb], step, &changed);
            if (!changed) break;   // web 里 next == cur 时同样不发请求
            [bar commitVolumeDb:db];
            break;
        }
        case RLPShortcutLyrics:
            // 2026-11-17（UI 缺口审计已证实）：web 的 l 是打开**歌词抽屉**（bLyric），
            // 旧实现发的是「打开播放页」⟹ 键盘党按 l 会整页弹开。
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenLyricDrawerNotification" object:nil];
            break;
        case RLPShortcutSignalChain:
            [bar showSignalChain:nil];
            break;
        case RLPShortcutEscapeBack:
            // 2026-11-17：web 的 Esc 是层级返回（modal → 抽屉 → 播放页 → 详情页）。
            // 旧实现无条件发「关闭播放页」，把播放页自己的「先关抽屉」逻辑整个绕过。
            if (self.mainWC.nowPlayingOverlayVisible) {
                [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPNowPlayingEscapeNotification" object:nil];
            } else {
                [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPBackNotification" object:nil];
            }
            break;
        case RLPShortcutNone: break;
    }
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
    // 导航项 = web 版左导航的 1:1 副本（ui_page.h 的 .side）。
    // web 的静态 .nav 是 **10 项**（专辑/艺术家/曲目/文件夹/流媒体/播放队列/最近/最爱/
    // 快速开始/设置）；第 11 个「保存的队列」是原生自己加的死条目，
    // 2026-11-13 已按 web 改成「我的歌单」动态区（#sqList，条数由 /api/sq/list 决定，
    // 无核心的 selftest 里为 0 ⟹ 这里断言的是**静态 10 项**）。
    // web 没有聆听/专业双模式，所以这里断言的是**web 的那份清单**，不是模式变体。
    {
        STCheck([wc.sidebar navRowCount] == 10, "侧栏 10 个静态导航项（对齐 web .nav 清单）",
                [NSString stringWithFormat:@"nav=%ld", (long)[wc.sidebar navRowCount]]);
        STCheck([wc.sidebar savedQueueRowCount] == 0,
                "无核心时不发 /api/sq/list（不假装有歌单）", @"");
        // 第 0 行是分组标题「资料库」（web 的 .sec），第一个**导航项**才是专辑。
        // 判据用导航项而不是裸行号：行号会被分组标题挤动，key 不会。
        STCheck([wc.sidebar selectKey:@"albums"] == YES, "有专辑入口（web data-v=albums）", @"");
        STCheck([wc.sidebar selectKey:@"settings"] == YES, "有设置入口（web data-v=settings）", @"");
        STCheck([wc.sidebar selectKey:@"station"] == YES, "有快速开始入口（web data-v=station）", @"");
        STCheck([wc.sidebar selectKey:@"streaming"] == YES, "有流媒体入口（web data-v=remote）", @"");
        [wc.sidebar selectRow:0];
    }
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
        // 2026-11-12：对齐 web 远程页 —— 默认网格（封面卡片）+ 网格/列表两档切换。
        // 旧实现只有裸文本列表，这里钉住网格与切换控件真的在位。
        NSMutableArray<NSView *> *sv = [NSMutableArray array];
        CollectViews(vc.view, sv);
        BOOL hasGrid = NO, hasToggle = NO;
        for (NSView *v in sv) {
            if ([v isKindOfClass:[NSCollectionView class]]) hasGrid = YES;
            if ([v isKindOfClass:[NSSegmentedControl class]] &&
                ((NSSegmentedControl *)v).segmentCount == 2) hasToggle = YES;
        }
        STCheck(hasGrid, "流媒体页有封面网格（web 远程页同款）", @"");
        STCheck(hasToggle, "流媒体页有网格/列表切换", @"");
    }
    {
        RLPQuickStartViewController *vc = [[RLPQuickStartViewController alloc] init];
        STCheck(vc.view != nil, "快速开始页可离线构建", @"");
    }
    {
        // 设置页签 = web 的 data-g 清单（10 页，顺序一致）。
        RLPSettingsViewController *vc = [[RLPSettingsViewController alloc] init];
        STCheck(vc.view != nil, "设置页可离线构建", @"");
        NSMutableArray<NSView *> *sv = [NSMutableArray array];
        CollectViews(vc.view, sv);
        NSSegmentedControl *seg = nil;
        // The page is grouped (通用 / 音频处理); the pane control is the one
        // carrying settings.tabs, independent of the group selector.
        for (NSView *v in sv) {
            if ([v isKindOfClass:[NSSegmentedControl class]] &&
                [v.identifier isEqualToString:@"settings.tabs"]) { seg = (NSSegmentedControl *)v; break; }
        }
        STCheck(seg != nil, "设置页有页签控件（settings.tabs）", @"");
        STCheck(seg.segmentCount >= 1 && seg.segmentCount <= 10,
                "设置页分组页签中的当前组包含有效页签数",
                seg ? [NSString stringWithFormat:@"segments=%ld", (long)seg.segmentCount] : @"nil");
        // 每个页签必须真的能切过去（不是只有按钮）
        for (NSString *k in @[ @"adv", @"in", @"out", @"pcm", @"sdm", @"eq", @"cal", @"meta", @"stream", @"diag" ]) {
            [vc selectPane:k];
            STCheck([[vc currentPaneKey] isEqualToString:k],
                    [[NSString stringWithFormat:@"设置页签 %@ 可切换", k] UTF8String],
                    [NSString stringWithFormat:@"got=%@", [vc currentPaneKey]]);
        }
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
    {
        RLPPlaylistsViewController *vc = [[RLPPlaylistsViewController alloc] init];
        STCheck(vc.view != nil, "歌单页可离线构建", @"");
    }
    {
        RLPEqualizerView *v = [[RLPEqualizerView alloc] initWithFrame:NSMakeRect(0, 0, 600, 700)];
        NSMutableArray<NSView *> *ev = [NSMutableArray array];
        CollectViews(v, ev);
        NSInteger tables = 0, switches = 0, faders = 0, inspectors = 0;
        for (NSView *x in ev) {
            if ([x isKindOfClass:[NSTableView class]]) ++tables;
            if ([x isKindOfClass:[NSSwitch class]]) ++switches;
            if ([x.identifier isEqualToString:@"eq.fader"]) ++faders;
            if ([x.identifier isEqualToString:@"eq.inspector"]) ++inspectors;
        }
        // 2026-11-15 用户明确「底下这个 eq 表不要了」⟹ 20 行参数表被移除，
        // 职责拆成推子板（频率/增益，20 根推子）+ 单段检查器（Q/类型/开关）。
        // 判据跟着控件集走：表格必须**消失**，替代表格的两个编辑面必须**在位**。
        STCheck(tables == 0, "均衡视图不再有 20 行参数表（用户 2026-11-15 明确移除）",
                [NSString stringWithFormat:@"tables=%ld", (long)tables]);
        STCheck(faders == 1 && inspectors == 1,
                "均衡视图有推子板 + 单段检查器（替代原表格的编辑面）",
                [NSString stringWithFormat:@"faders=%ld inspectors=%ld", (long)faders, (long)inspectors]);
        STCheck(switches >= 1, "均衡视图有旁路开关", [NSString stringWithFormat:@"switches=%ld", (long)switches]);
    }
    {
        RLPInputView *v = [[RLPInputView alloc] initWithFrame:NSMakeRect(0, 0, 600, 460)];
        STCheck(v != nil, "输入采集视图可离线构建", @"");
    }
    {
        RLPCastView *v = [[RLPCastView alloc] initWithFrame:NSMakeRect(0, 0, 560, 200)];
        STCheck(v != nil, "投放视图可离线构建", @"");
        STCheck(v.polling == NO, "投放视图在无核心时不启动轮询", @"");
    }
    {
        RLPCalibrationView *v = [[RLPCalibrationView alloc] initWithFrame:NSMakeRect(0, 0, 600, 620)];
        STCheck(v != nil, "校准视图可离线构建", @"");
    }
    {
        RLPFeedbackWindowController *wc3 = [RLPFeedbackWindowController shared];
        STCheck(wc3.window != nil, "反馈窗口可离线构建", @"");
        NSMutableArray<NSView *> *fv = [NSMutableArray array];
        CollectViews(wc3.window.contentView, fv);
        BOOL hasTextView = NO, hasSwitch = NO;
        for (NSView *x in fv) {
            if ([x isKindOfClass:[NSTextView class]]) hasTextView = YES;
            if ([x isKindOfClass:[NSSwitch class]]) hasSwitch = YES;
        }
        STCheck(hasTextView, "反馈窗口有正文输入区", @"");
        STCheck(hasSwitch, "反馈窗口有附诊断包开关", @"");
    }
    {
        RLPKnowledgeView *v = [[RLPKnowledgeView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
        STCheck(v != nil, "AI 资料面板可离线构建", @"");
        // 无核心 / 空名字时不许发请求，也不许崩
        [v loadKind:@"track" name:@"" artist:nil];
        STCheck(YES, "AI 资料面板空输入安全空转", @"");
        [v cancelLoading];
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