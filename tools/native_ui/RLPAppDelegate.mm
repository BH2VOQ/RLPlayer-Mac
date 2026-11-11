// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPAppDelegate.h"
#import "RLPCoreClient.h"
#import "RLPMainWindowController.h"
#import "RLPPlaybackBarView.h"
#import "RLPSidebarViewController.h"
#import "RLPAlbumsViewController.h"
#import "RLPTheme.h"

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
    [[RLPCoreClient shared] startEmbedded];

    self.mainWC = [[RLPMainWindowController alloc] init];
    [self.mainWC showWindow:nil];
    [self.mainWC.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self.mainWC loadInitialData];

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

    printf("\n%s（%d 项失败）\n", gSelfTestFail == 0 ? "native_ui selftest 全部通过" : "native_ui selftest 有失败", gSelfTestFail);
    return gSelfTestFail == 0 ? 0 : gSelfTestFail;
}