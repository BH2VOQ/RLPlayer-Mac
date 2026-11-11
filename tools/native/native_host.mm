// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// native_host.mm — 纯 AppKit（Objective-C++，ARC）原生界面 P1 骨架（1.1.7，新增）
//
// 对应 docs/ui-redo/UI_REDESIGN_PLAN.md §2（窗口/视图层级）、§3（状态管理）、§9（G 组件）。
// 本轮交付：单主窗口 + NSSplitViewController（侧栏/主区/右栏）+ 底部播放条 + 菜单/命令
// + 播放状态轮询（10 Hz）+ 专辑网格/队列/播放控制。全部状态只读 C++ 核心（rlnative 桥）。
//
// 明确不做：WKWebView 主内容区、Swift/SwiftUI、XIB/Storyboard、迷你窗/桌面歌词/强制更新。
// 功能对齐矩阵里 P2/P3 的页面（设置 10 页/更新窗口/Now Playing/分析/AI 等）本轮尚未做，
// 逐项在文档 §10 的阶段表与交付报告里如实挂账，不谎报完成。
#import <AppKit/AppKit.h>

#include <atomic>
#include <chrono>
#include <string>
#include <thread>
#include <vector>

#include "native/core_bridge.h"
#include "native/native_host.h"
#include "rlapp_core.h"

namespace {

// ---------------------------------------------------------------------------
// 主题 token（方案 §9.6）：三套配色 × 语义色。视图里禁止写死 NSColor(red:...)。
// P1 只做 dark/light/blue 的基色与强调色；细粒度 token 随页面迁移补齐。
// ---------------------------------------------------------------------------
struct Theme {
    // ARC 不允许 C++ struct 直接强持有 ObjC 对象；Theme 只按值临时传递、
    // 生命周期局限在当前 autorelease pool 内，用 __unsafe_unretained 是安全且必要的。
    __unsafe_unretained NSColor* bg;
    __unsafe_unretained NSColor* surface;
    __unsafe_unretained NSColor* text;
    __unsafe_unretained NSColor* muted;
    __unsafe_unretained NSColor* accent;
    __unsafe_unretained NSColor* separator;
};

static Theme theme_dark() {
    return Theme{
        [NSColor colorWithSRGBRed:0.043 green:0.047 blue:0.055 alpha:1],
        [NSColor colorWithSRGBRed:0.086 green:0.094 blue:0.110 alpha:1],
        [NSColor colorWithSRGBRed:0.910 green:0.925 blue:0.960 alpha:1],
        [NSColor colorWithSRGBRed:0.541 green:0.565 blue:0.620 alpha:1],
        [NSColor colorWithSRGBRed:0.231 green:0.510 blue:0.965 alpha:1],
        [NSColor colorWithSRGBRed:0.160 green:0.176 blue:0.200 alpha:1],
    };
}
static Theme theme_light() {
    return Theme{
        [NSColor colorWithSRGBRed:0.965 green:0.973 blue:0.984 alpha:1],
        [NSColor whiteColor],
        [NSColor colorWithSRGBRed:0.067 green:0.090 blue:0.125 alpha:1],
        [NSColor colorWithSRGBRed:0.420 green:0.455 blue:0.510 alpha:1],
        [NSColor colorWithSRGBRed:0.145 green:0.388 blue:0.922 alpha:1],
        [NSColor colorWithSRGBRed:0.850 green:0.875 blue:0.905 alpha:1],
    };
}
static Theme theme_blue() {
    return Theme{
        [NSColor colorWithSRGBRed:0.914 green:0.949 blue:0.996 alpha:1],
        [NSColor colorWithSRGBRed:0.969 green:0.984 blue:1.000 alpha:1],
        [NSColor colorWithSRGBRed:0.043 green:0.145 blue:0.271 alpha:1],
        [NSColor colorWithSRGBRed:0.353 green:0.443 blue:0.560 alpha:1],
        [NSColor colorWithSRGBRed:0.050 green:0.430 blue:0.992 alpha:1],
        [NSColor colorWithSRGBRed:0.780 green:0.855 blue:0.945 alpha:1],
    };
}

// ---------------------------------------------------------------------------
// 命令表（方案 §9.8）：所有入口只发 command，不在按钮 action 里直接改状态。
// ---------------------------------------------------------------------------
enum class Cmd : int {
    PlayPause = 1, Next, Previous, Stop, VolumeUp, VolumeDown, SeekForward, SeekBackward,
    ModeSequential, ModeListLoop, ModeSingleLoop, ModeShuffle, CycleMode,
    ToggleSidebar, ToggleQueueRail, FocusSearch, OpenSettings, CheckUpdate,
};

static NSString* mode_title(int m) {
    switch (m) {
        case 0: return @"顺序播放";
        case 1: return @"列表循环";
        case 2: return @"单曲循环";
        case 3: return @"随机播放";
        default: return @"顺序播放";
    }
}
static NSString* mode_a11y(int m) {
    return [NSString stringWithFormat:@"播放模式：%@", mode_title(m)];
}

} // namespace

// ---------------------------------------------------------------------------
// RLNativeAppDelegate：进程内起 AppKit 应用（不复用 mac_host.mm 的 WKWebView 路径）
// ---------------------------------------------------------------------------
@interface RLNativeAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate,
                                            NSSplitViewDelegate, NSTableViewDataSource,
                                            NSTableViewDelegate, NSCollectionViewDataSource,
                                            NSCollectionViewDelegate, NSMenuItemValidation>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSSplitViewController *split;
@property (nonatomic, strong) NSVisualEffectView *sidebar;
@property (nonatomic, strong) NSScrollView *contentScroll;
@property (nonatomic, strong) NSCollectionView *albumGrid;
@property (nonatomic, strong) NSTableView *queueTable;
@property (nonatomic, strong) NSView *playerBar;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *artistLabel;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSButton *playButton;
@property (nonatomic, strong) NSButton *modeButton;
@property (nonatomic, strong) NSSlider *seekSlider;
@property (nonatomic, strong) NSSlider *volumeSlider;
@property (nonatomic, strong) NSTextField *searchField;
@property (nonatomic, strong) NSTextField *headerLabel;
@property (nonatomic, strong) NSProgressIndicator *scanSpinner;
@property (nonatomic, strong) NSMenuItem *queueRailMenuItem;
@property (nonatomic, strong) NSMutableArray<NSMenuItem*> *modeMenuItems;
@property (nonatomic, strong) NSMutableArray<NSString*> *navItems;
@property (nonatomic, assign) NSInteger selectedNav;
@property (nonatomic, strong) NSArray<NSString*> *albumKeys;
@property (nonatomic, strong) NSTimer *pollTimer;
@end

@implementation RLNativeAppDelegate {
    NSInteger _themeIndex;
    rlnative::PlaybackSnapshot _snap;
    std::vector<rlnative::Album> _albums;
    std::vector<rlnative::QueueItem> _queue;
}

- (instancetype)init {
    if ((self = [super init])) {
        _themeIndex = 0;
        _selectedNav = 0;
        _albumKeys = @[];
        _navItems = [@[@"专辑", @"艺术家", @"曲目", @"文件夹", @"流媒体",
                       @"播放队列", @"最近播放", @"我的最爱", @"快速开始", @"设置"] mutableCopy];
        _modeMenuItems = [NSMutableArray array];
    }
    return self;
}

- (Theme)currentTheme {
    switch (_themeIndex) {
        case 1: return theme_light();
        case 2: return theme_blue();
        default: return theme_dark();
    }
}

- (void)applicationDidFinishLaunching:(NSNotification*)n {
    (void)n;
    [self buildMenu];
    [self buildWindow];
    [self applyTheme];

    // 10 Hz 状态轮询：只在主线程读桥 + 刷 UI；不做鼠标/键盘自动化、不开发声设备。
    // 用显式类型而非 typeof()：-std=c++23 下 GNU typeof 不是标准标识符（OBJCXX 同受约束）。
    __weak RLNativeAppDelegate* weakSelf = self;
    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer* t) {
        (void)t;
        RLNativeAppDelegate* strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf refreshSnapshot];
    }];
    [self reloadAlbums:@""];
    [self refreshSnapshot];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)a {
    (void)a; return YES;
}

- (void)applicationWillTerminate:(NSNotification*)n {
    (void)n;
    // 复用既有协作收尾：/api/stop 停播放 + request_shutdown + stop_embedded（绝不 force-kill）。
    {
        rta::net::HttpRequest rq; rq.method = "POST"; rq.path = "/api/stop";
        std::string ct; (void)rlapp::dispatch(rq, ct);
    }
    rlapp::request_shutdown();
    rlapp::stop_embedded();
}

// ---------------------------------------------------------------------------
// 菜单（方案 §9.8）：App / 编辑 / 播放 / 显示 / 窗口 / 帮助
// ---------------------------------------------------------------------------
- (void)buildMenu {
    NSMenu* bar = [[NSMenu alloc] init];

    // App
    NSMenuItem* appItem = [[NSMenuItem alloc] init];
    NSMenu* appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"关于 RLPlayer" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"设置…" action:@selector(cmdOpenSettings:) keyEquivalent:@","];
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem* upd = [appMenu addItemWithTitle:@"检查更新…" action:@selector(cmdCheckUpdate:) keyEquivalent:@""];
    upd.target = self;
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"退出 RLPlayer" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [bar addItem:appItem];

    // 编辑（nil target 走响应链，与现有 web 壳一致）
    NSMenuItem* editItem = [[NSMenuItem alloc] initWithTitle:@"编辑" action:nil keyEquivalent:@""];
    NSMenu* editMenu = [[NSMenu alloc] initWithTitle:@"编辑"];
    for (NSArray* row in @[@[@"撤销", @"undo:", @"z", @(NSEventModifierFlagCommand)],
                           @[@"剪切", @"cut:", @"x", @(NSEventModifierFlagCommand)],
                           @[@"拷贝", @"copy:", @"c", @(NSEventModifierFlagCommand)],
                           @[@"粘贴", @"paste:", @"v", @(NSEventModifierFlagCommand)],
                           @[@"全选", @"selectAll:", @"a", @(NSEventModifierFlagCommand)]]) {
        NSMenuItem* it = [editMenu addItemWithTitle:row[0] action:NSSelectorFromString(row[1]) keyEquivalent:row[2]];
        it.target = nil;
        it.keyEquivalentModifierMask = (NSEventModifierFlags)[row[3] unsignedIntegerValue];
    }
    editItem.submenu = editMenu;
    [bar addItem:editItem];

    // 播放
    NSMenuItem* playItem = [[NSMenuItem alloc] initWithTitle:@"播放" action:nil keyEquivalent:@""];
    NSMenu* playMenu = [[NSMenu alloc] initWithTitle:@"播放"];
    [self addCmd:playMenu title:@"播放 / 暂停" key:@" " cmd:Cmd::PlayPause];
    [playMenu addItem:[NSMenuItem separatorItem]];
    [self addCmd:playMenu title:@"下一首" key:@"\u2192" cmd:Cmd::Next];
    [self addCmd:playMenu title:@"上一首" key:@"\u2190" cmd:Cmd::Previous];
    [self addCmd:playMenu title:@"停止" key:@"s" cmd:Cmd::Stop];
    [playMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem* modeItem = [[NSMenuItem alloc] initWithTitle:@"播放模式" action:nil keyEquivalent:@""];
    NSMenu* modeMenu = [[NSMenu alloc] initWithTitle:@"播放模式"];
    for (int m = 0; m < 4; ++m) {
        NSMenuItem* mi = [modeMenu addItemWithTitle:mode_title(m) action:@selector(cmdSetMode:) keyEquivalent:@""];
        mi.target = self; mi.tag = m;
        [self->_modeMenuItems addObject:mi];
    }
    modeItem.submenu = modeMenu;
    [playMenu addItem:modeItem];
    [self addCmd:playMenu title:@"切换播放模式" key:@"M" cmd:Cmd::CycleMode];
    playItem.submenu = playMenu;
    [bar addItem:playItem];

    // 显示
    NSMenuItem* viewItem = [[NSMenuItem alloc] initWithTitle:@"显示" action:nil keyEquivalent:@""];
    NSMenu* viewMenu = [[NSMenu alloc] initWithTitle:@"显示"];
    [self addCmd:viewMenu title:@"显示/隐藏侧栏" key:@"S" cmd:Cmd::ToggleSidebar];
    NSMenuItem* rail = [self addCmd:viewMenu title:@"显示/隐藏队列" key:@"2" cmd:Cmd::ToggleQueueRail];
    _queueRailMenuItem = rail;
    for (int t = 0; t < 3; ++t) {
        NSMenuItem* mi = [viewMenu addItemWithTitle:(t == 0 ? @"深色" : t == 1 ? @"浅色" : @"浅蓝")
                                              action:@selector(cmdSetTheme:) keyEquivalent:@""];
        mi.target = self; mi.tag = t;
    }
    viewItem.submenu = viewMenu;
    [bar addItem:viewItem];

    [NSApp setMainMenu:bar];
}

- (NSMenuItem*)addCmd:(NSMenu*)menu title:(NSString*)title key:(NSString*)key cmd:(Cmd)c {
    NSMenuItem* mi = [menu addItemWithTitle:title action:@selector(dispatchCmd:) keyEquivalent:key];
    mi.target = self; mi.tag = (NSInteger)c;
    if (![key isEqualToString:@" "] && ![key isEqualToString:@"\u2192"] && ![key isEqualToString:@"\u2190"])
        mi.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    return mi;
}

- (BOOL)validateMenuItem:(NSMenuItem*)item {
    if (item.action == @selector(cmdSetMode:)) {
        item.state = (item.tag == _snap.mode) ? NSControlStateValueOn : NSControlStateValueOff;
    }
    return YES;
}

// ---------------------------------------------------------------------------
// 窗口（方案 §2.3）：单主窗口 + NSSplitViewController（侧栏 232 / 主区 / 右栏 280）+ 播放条
// ---------------------------------------------------------------------------
- (void)buildWindow {
    NSRect frame = NSMakeRect(0, 0, 1180, 760);
    self.window = [[NSWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                  NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                  NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"RLPlayer";
    self.window.titleVisibility = NSWindowTitleHidden;
    self.window.titlebarAppearsTransparent = YES;
    self.window.minSize = NSMakeSize(760, 480);
    self.window.delegate = self;
    [self.window setFrameAutosaveName:@"RLPlayerMainWindow"];  // 方案 IA-7：窗口状态恢复
    [self.window center];

    NSView* root = self.window.contentView;
    root.wantsLayer = YES;

    // 分栏：侧栏 / 主区 / 右栏
    _split = [[NSSplitViewController alloc] init];
    _split.splitView.vertical = YES;
    _split.splitView.dividerStyle = NSSplitViewDividerStyleThin;
    [self addSplitItem:[self buildSidebar] width:232];
    [self addSplitItem:[self buildContent] width:640];
    [self addSplitItem:[self buildQueueRail] width:280];
    _split.view.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_split.view];
    [NSLayoutConstraint activateConstraints:@[
        [_split.view.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_split.view.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_split.view.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_split.view.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-68.0],
    ]];

    _playerBar = [self buildPlayerBar];
    [root addSubview:_playerBar];
    _playerBar.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [_playerBar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_playerBar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_playerBar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [_playerBar.heightAnchor constraintEqualToConstant:68.0],
    ]];

    [self.window makeKeyAndOrderFront:nil];
}

- (void)addSplitItem:(NSViewController*)vc width:(CGFloat)w {
    NSSplitViewItem* item = [NSSplitViewItem splitViewItemWithViewController:vc];
    item.minimumThickness = (w < 250) ? 200.0 : 320.0;
    item.maximumThickness = (w < 250) ? 320.0 : 400.0;
    item.canCollapse = (w < 250);
    item.collapsed = NO;
    [_split addSplitViewItem:item];
}

- (NSViewController*)buildSidebar {
    NSViewController* vc = [[NSViewController alloc] init];
    NSVisualEffectView* side = [[NSVisualEffectView alloc] init];
    side.material = NSVisualEffectMaterialSidebar;
    side.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    side.wantsLayer = YES;
    _sidebar = side;
    vc.view = side;

    // 顶部安全区（红绿灯）
    NSView* top = [[NSView alloc] init];
    top.translatesAutoresizingMaskIntoConstraints = NO;
    [side addSubview:top];
    [NSLayoutConstraint activateConstraints:@[
        [top.leadingAnchor constraintEqualToAnchor:side.leadingAnchor],
        [top.trailingAnchor constraintEqualToAnchor:side.trailingAnchor],
        [top.topAnchor constraintEqualToAnchor:side.topAnchor],
        [top.heightAnchor constraintEqualToConstant:38.0],
    ]];

    NSScrollView* scroll = [[NSScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;
    [side addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:side.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:side.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:top.bottomAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:side.bottomAnchor constant:-56.0],
    ]];

    NSStackView* stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 2.0;
    stack.edgeInsets = NSEdgeInsetsMake(8, 12, 8, 12);
    for (NSUInteger i = 0; i < _navItems.count; ++i) {
        if (i == 0 || i == 5 || i == 8) {
            NSTextField* sec = [NSTextField labelWithString:(i == 0 ? @"资料库" : i == 5 ? @"播放列表" : @"音频引擎")];
            sec.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
            sec.textColor = [NSColor secondaryLabelColor];
            [stack addView:sec inGravity:NSStackViewGravityTop];
        }
        NSButton* b = [NSButton buttonWithTitle:_navItems[i] target:self action:@selector(cmdNav:)];
        b.bezelStyle = NSBezelStyleInline;
        b.tag = (NSInteger)i;
        b.alignment = NSTextAlignmentLeft;
        b.font = [NSFont systemFontOfSize:13];
        b.accessibilityLabel = [NSString stringWithFormat:@"导航：%@", _navItems[i]];
        [stack addView:b inGravity:NSStackViewGravityTop];
        [b.widthAnchor constraintEqualToConstant:200].active = YES;
    }
    scroll.documentView = stack;
    [stack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor].active = YES;

    // 品牌行（版本来自 src/version.h 编译期注入）
    NSTextField* brand = [NSTextField labelWithString:[NSString stringWithFormat:@"RLPlayer  v%s", RLPLAYER_VERSION_STR]];
    brand.translatesAutoresizingMaskIntoConstraints = NO;
    brand.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    brand.textColor = [NSColor secondaryLabelColor];
    [side addSubview:brand];
    [NSLayoutConstraint activateConstraints:@[
        [brand.leadingAnchor constraintEqualToAnchor:side.leadingAnchor constant:14],
        [brand.bottomAnchor constraintEqualToAnchor:side.bottomAnchor constant:-14],
    ]];
    return vc;
}

- (NSViewController*)buildContent {
    NSViewController* vc = [[NSViewController alloc] init];
    NSView* v = [[NSView alloc] init];
    v.wantsLayer = YES;
    vc.view = v;

    _headerLabel = [NSTextField labelWithString:@"专辑"];
    _headerLabel.font = [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold];
    _headerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_headerLabel];

    _searchField = [[NSSearchField alloc] init];
    _searchField.placeholderString = @"搜索专辑 / 艺术家 / 曲目…";
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;
    _searchField.target = self;
    _searchField.action = @selector(cmdSearch:);
    _searchField.accessibilityLabel = @"搜索资料库";
    [v addSubview:_searchField];

    _scanSpinner = [[NSProgressIndicator alloc] init];
    _scanSpinner.style = NSProgressIndicatorStyleSpinning;
    _scanSpinner.controlSize = NSControlSizeSmall;
    _scanSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    _scanSpinner.hidden = YES;
    [v addSubview:_scanSpinner];

    _contentScroll = [[NSScrollView alloc] init];
    _contentScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _contentScroll.hasVerticalScroller = YES;
    _contentScroll.drawsBackground = NO;
    [v addSubview:_contentScroll];

    [NSLayoutConstraint activateConstraints:@[
        [_headerLabel.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:24],
        [_headerLabel.topAnchor constraintEqualToAnchor:v.topAnchor constant:24],
        [_searchField.centerYAnchor constraintEqualToAnchor:_headerLabel.centerYAnchor],
        [_searchField.leadingAnchor constraintEqualToAnchor:_headerLabel.trailingAnchor constant:24],
        [_searchField.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-24],
        [_scanSpinner.centerYAnchor constraintEqualToAnchor:_headerLabel.centerYAnchor],
        [_scanSpinner.trailingAnchor constraintEqualToAnchor:_searchField.leadingAnchor constant:-8],
        [_contentScroll.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [_contentScroll.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [_contentScroll.topAnchor constraintEqualToAnchor:_headerLabel.bottomAnchor constant:16],
        [_contentScroll.bottomAnchor constraintEqualToAnchor:v.bottomAnchor],
    ]];

    // 专辑网格（NSCollectionView + diffable 在 P2 接；P1 用 NSCollectionView 基础流布局）
    NSCollectionViewFlowLayout* flow = [[NSCollectionViewFlowLayout alloc] init];
    flow.itemSize = NSMakeSize(160, 200);
    flow.minimumInteritemSpacing = 16;
    flow.minimumLineSpacing = 20;
    flow.sectionInset = NSEdgeInsetsMake(8, 24, 24, 24);
    _albumGrid = [[NSCollectionView alloc] initWithFrame:NSZeroRect];
    _albumGrid.collectionViewLayout = flow;
    _albumGrid.dataSource = self;
    _albumGrid.delegate = self;
    _albumGrid.wantsLayer = YES;
    [_albumGrid registerClass:[NSCollectionViewItem class] forItemWithIdentifier:@"AlbumCell"];
    _contentScroll.documentView = _albumGrid;

    // 队列表格（右栏用，切到「播放队列」视图时显示在主区）
    _queueTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
    NSTableColumn* col = [[NSTableColumn alloc] initWithIdentifier:@"title"];
    col.title = @"曲目";
    col.width = 420;
    [_queueTable addTableColumn:col];
    _queueTable.dataSource = self;
    _queueTable.delegate = self;
    _queueTable.hidden = YES;
    return vc;
}

- (NSViewController*)buildQueueRail {
    NSViewController* vc = [[NSViewController alloc] init];
    NSView* v = [[NSView alloc] init];
    v.wantsLayer = YES;
    vc.view = v;
    NSTextField* t = [NSTextField labelWithString:@"播放队列"];
    t.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    t.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:t];
    [NSLayoutConstraint activateConstraints:@[
        [t.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:16],
        [t.topAnchor constraintEqualToAnchor:v.topAnchor constant:16],
    ]];

    NSScrollView* scroll = [[NSScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES;
    [v addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:8],
        [scroll.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-8],
        [scroll.topAnchor constraintEqualToAnchor:t.bottomAnchor constant:12],
        [scroll.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-8],
    ]];
    // 与主区共用一份数据，但独立视图：把 queueTable 放到右栏 scroll 里（P1 简化：右栏显示队列）
    // 主区 queueTable 用于「播放队列」整页视图，二者不冲突（不同父视图时 copy 一份）。
    NSTableView* railTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
    NSTableColumn* c = [[NSTableColumn alloc] initWithIdentifier:@"title"];
    c.title = @"队列"; c.width = 250;
    [railTable addTableColumn:c];
    railTable.dataSource = self;
    scroll.documentView = railTable;
    return vc;
}

- (NSView*)buildPlayerBar {
    NSVisualEffectView* bar = [[NSVisualEffectView alloc] init];
    bar.material = NSVisualEffectMaterialPopover;
    bar.wantsLayer = YES;

    _titleLabel = [NSTextField labelWithString:@"未播放"];
    _titleLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    _artistLabel = [NSTextField labelWithString:@""];
    _artistLabel.font = [NSFont systemFontOfSize:11];
    _artistLabel.textColor = [NSColor secondaryLabelColor];
    NSStackView* info = [NSStackView stackViewWithViews:@[_titleLabel, _artistLabel]];
    info.orientation = NSUserInterfaceLayoutOrientationVertical;
    info.alignment = NSLayoutAttributeLeading;
    info.spacing = 2;

    _playButton = [NSButton buttonWithTitle:@"▶" target:self action:@selector(dispatchCmd:)];
    _playButton.tag = (NSInteger)Cmd::PlayPause;
    _playButton.bezelStyle = NSBezelStyleCircular;
    _playButton.accessibilityLabel = @"播放或暂停";
    NSButton* prev = [NSButton buttonWithTitle:@"⏮" target:self action:@selector(dispatchCmd:)];
    prev.tag = (NSInteger)Cmd::Previous; prev.accessibilityLabel = @"上一首";
    NSButton* next = [NSButton buttonWithTitle:@"⏭" target:self action:@selector(dispatchCmd:)];
    next.tag = (NSInteger)Cmd::Next; next.accessibilityLabel = @"下一首";
    NSButton* stop = [NSButton buttonWithTitle:@"⏹" target:self action:@selector(dispatchCmd:)];
    stop.tag = (NSInteger)Cmd::Stop; stop.accessibilityLabel = @"停止";
    _modeButton = [NSButton buttonWithTitle:@"顺序播放" target:self action:@selector(dispatchCmd:)];
    _modeButton.tag = (NSInteger)Cmd::CycleMode;
    _modeButton.bezelStyle = NSBezelStyleInline;
    _modeButton.accessibilityLabel = mode_a11y(0);
    NSStackView* keys = [NSStackView stackViewWithViews:@[_modeButton, prev, _playButton, next, stop]];
    keys.spacing = 6;

    _seekSlider = [NSSlider sliderWithTarget:self action:@selector(cmdSeek:)];
    _seekSlider.minValue = 0; _seekSlider.maxValue = 1; _seekSlider.doubleValue = 0;
    _seekSlider.continuous = NO;
    _seekSlider.accessibilityLabel = @"播放进度";
    _volumeSlider = [NSSlider sliderWithTarget:self action:@selector(cmdVolume:)];
    _volumeSlider.minValue = -60; _volumeSlider.maxValue = 0; _volumeSlider.doubleValue = 0;
    _volumeSlider.continuous = NO;
    _volumeSlider.accessibilityLabel = @"音量 dB";

    _statusLabel = [NSTextField labelWithString:@"0:00 / 0:00"];
    _statusLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    _statusLabel.textColor = [NSColor secondaryLabelColor];

    NSStackView* mid = [NSStackView stackViewWithViews:@[keys, _seekSlider, _statusLabel]];
    mid.orientation = NSUserInterfaceLayoutOrientationVertical;
    mid.spacing = 2;

    NSStackView* row = [NSStackView stackViewWithViews:@[info, mid, _volumeSlider]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 16;
    row.edgeInsets = NSEdgeInsetsMake(8, 16, 8, 16);
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor],
        [row.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor],
    ]];
    [info.widthAnchor constraintEqualToConstant:200].active = YES;
    [_volumeSlider.widthAnchor constraintEqualToConstant:120].active = YES;
    return bar;
}

- (void)applyTheme {
    Theme t = [self currentTheme];
    self.window.backgroundColor = t.bg;
    self.window.appearance = (_themeIndex == 0)
        ? [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]
        : [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    // 视图背景靠 layer；纯 AppKit 下用 wantsLayer + backgroundColor 统一三主题。
    for (NSView* v in @[self.window.contentView, _split.view]) {
        v.wantsLayer = YES;
        v.layer.backgroundColor = t.bg.CGColor;
    }
    _headerLabel.textColor = t.text;
    _titleLabel.textColor = t.text;
    _artistLabel.textColor = t.muted;
    _statusLabel.textColor = t.muted;
    _contentScroll.backgroundColor = t.bg;
    _albumGrid.backgroundColors = @[t.bg];
}

// ---------------------------------------------------------------------------
// 数据：全部来自 rlnative 桥（C++ 核心单真相源），UI 不保存第二份
// ---------------------------------------------------------------------------
- (void)reloadAlbums:(NSString*)q {
    _albums = rlnative::albums(q ? q.UTF8String : "");
    NSMutableArray* keys = [NSMutableArray arrayWithCapacity:_albums.size()];
    for (const auto& a : _albums) [keys addObject:[NSString stringWithUTF8String:a.key.c_str()]];
    _albumKeys = keys;
    [_albumGrid reloadData];
}

- (void)refreshSnapshot {
    rlnative::PlaybackSnapshot s = rlnative::snapshot();
    if (s.revision == _snap.revision && (s.pos - _snap.pos) < 0.05 && (s.pos - _snap.pos) > -0.05) {
        // 状态没变、进度变化 <50ms：只不动 UI（避免 10Hz 全量重绘）
        return;
    }
    _snap = s;

    NSString* title = @"未播放";
    NSString* artist = @"";
    if (!s.current.empty()) {
        NSString* path = [NSString stringWithUTF8String:s.current.c_str()];
        title = path.lastPathComponent.stringByDeletingPathExtension;
        // 队列里通常有元数据；P1 简化显示文件名（P2 接 metas 后替换）
        artist = [NSString stringWithUTF8String:s.current.c_str()];
    }
    _titleLabel.stringValue = title;
    _artistLabel.stringValue = artist;
    _playButton.title = (s.playing && !s.paused) ? @"⏸" : @"▶";
    _modeButton.title = mode_title(s.mode);
    _modeButton.accessibilityLabel = mode_a11y(s.mode);
    _modeButton.toolTip = mode_a11y(s.mode);
    _statusLabel.stringValue = [NSString stringWithFormat:@"%d:%02d / %d:%02d",
        (int)s.pos / 60, (int)s.pos % 60, (int)s.dur / 60, (int)s.dur % 60];
    if (s.dur > 0) _seekSlider.doubleValue = s.pos / s.dur;
    _volumeSlider.doubleValue = s.volDb;
    for (NSMenuItem* mi in _modeMenuItems) mi.state = (mi.tag == s.mode) ? NSControlStateValueOn : NSControlStateValueOff;
    if (!s.error.empty()) {
        _statusLabel.stringValue = [NSString stringWithUTF8String:s.error.c_str()];
        _statusLabel.textColor = [NSColor systemRedColor];
    } else {
        _statusLabel.textColor = [NSColor secondaryLabelColor];
    }
}

// ---------------------------------------------------------------------------
// NSCollectionViewDataSource / Delegate（专辑网格）
// ---------------------------------------------------------------------------
- (NSInteger)numberOfSectionsInCollectionView:(NSCollectionView*)cv { (void)cv; return 1; }
- (NSInteger)collectionView:(NSCollectionView*)cv numberOfItemsInSection:(NSInteger)sec {
    (void)cv; (void)sec; return (NSInteger)_albums.size();
}
- (NSCollectionViewItem*)collectionView:(NSCollectionView*)cv itemForRepresentedObjectAtIndexPath:(NSIndexPath*)ip {
    (void)cv;
    NSCollectionViewItem* item = [cv makeItemWithIdentifier:@"AlbumCell" forIndexPath:ip];
    const auto& a = _albums[(size_t)ip.item];
    NSString* name = [NSString stringWithUTF8String:a.name.c_str()];
    NSString* artist = [NSString stringWithUTF8String:a.artist.c_str()];
    NSTextField* tf = item.textField;
    if (!tf) {
        tf = [NSTextField labelWithString:name];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        tf.maximumNumberOfLines = 2;
        [item.view addSubview:tf];
        [NSLayoutConstraint activateConstraints:@[
            [tf.leadingAnchor constraintEqualToAnchor:item.view.leadingAnchor constant:4],
            [tf.trailingAnchor constraintEqualToAnchor:item.view.trailingAnchor constant:-4],
            [tf.bottomAnchor constraintEqualToAnchor:item.view.bottomAnchor constant:-4],
        ]];
    } else tf.stringValue = name;
    tf.stringValue = [NSString stringWithFormat:@"%@\n%@", name, artist];
    tf.accessibilityLabel = [NSString stringWithFormat:@"专辑：%@，%@", name, artist];
    item.view.wantsLayer = YES;
    item.view.layer.cornerRadius = 8;
    item.view.layer.backgroundColor = [self currentTheme].surface.CGColor;
    return item;
}
- (void)collectionView:(NSCollectionView*)cv didSelectItemsAtIndexPaths:(NSSet<NSIndexPath*>*)ips {
    (void)cv;
    NSIndexPath* ip = ips.anyObject;
    if (!ip || ip.item >= (NSInteger)_albums.size()) return;
    const auto& a = _albums[(size_t)ip.item];
    rlnative::play_album(a.key, 0);
    [self refreshSnapshot];
}

// ---------------------------------------------------------------------------
// NSTableViewDataSource（队列）
// ---------------------------------------------------------------------------
- (NSInteger)numberOfRowsInTableView:(NSTableView*)tv {
    (void)tv;
    rlnative::QueueState q = rlnative::queue(false);
    _queue = q.items;
    return (NSInteger)_queue.size();
}
- (NSView*)tableView:(NSTableView*)tv viewForTableColumn:(NSTableColumn*)col row:(NSInteger)row {
    (void)col;
    if (row >= (NSInteger)_queue.size()) return nil;
    NSString* ident = @"QueueCell";
    NSTextField* tf = [tv makeViewWithIdentifier:ident owner:self];
    if (!tf) {
        tf = [NSTextField labelWithString:@""];
        tf.identifier = ident;
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    const auto& it = _queue[(size_t)row];
    NSString* p = [NSString stringWithUTF8String:it.path.c_str()];
    tf.stringValue = p.lastPathComponent;
    tf.accessibilityLabel = [NSString stringWithFormat:@"队列曲目：%@", p.lastPathComponent];
    return tf;
}

// ---------------------------------------------------------------------------
// Command 分发（方案 §6.0b：所有入口只发命令）
// ---------------------------------------------------------------------------
- (void)dispatchCmd:(id)sender {
    NSInteger tag = [sender isKindOfClass:[NSView class]] ? [(NSView*)sender tag]
                  : [sender isKindOfClass:[NSMenuItem class]] ? [(NSMenuItem*)sender tag] : 0;
    [self handleCmd:(Cmd)tag];
}

- (void)handleCmd:(Cmd)c {
    switch (c) {
        case Cmd::PlayPause:      rlnative::toggle_pause(); break;
        case Cmd::Next:           rlnative::next_track(); break;
        case Cmd::Previous:       rlnative::previous_track(); break;
        case Cmd::Stop:           rlnative::stop(); break;
        case Cmd::VolumeUp:       { auto s = rlnative::snapshot(); rlnative::set_volume_db(s.volDb + 0.5); break; }
        case Cmd::VolumeDown:     { auto s = rlnative::snapshot(); rlnative::set_volume_db(s.volDb - 0.5); break; }
        case Cmd::SeekForward:    { auto s = rlnative::snapshot(); rlnative::seek(s.dur > 0 ? (s.pos + 5) / s.dur : 0); break; }
        case Cmd::SeekBackward:   { auto s = rlnative::snapshot(); rlnative::seek(s.dur > 0 ? (s.pos - 5) / s.dur : 0); break; }
        case Cmd::CycleMode:      rlnative::set_mode((_snap.mode + 1) % 4); break;
        case Cmd::ModeSequential: rlnative::set_mode(0); break;
        case Cmd::ModeListLoop:   rlnative::set_mode(1); break;
        case Cmd::ModeSingleLoop: rlnative::set_mode(2); break;
        case Cmd::ModeShuffle:    rlnative::set_mode(3); break;
        case Cmd::ToggleSidebar:  [self toggleSplitItem:0]; break;
        case Cmd::ToggleQueueRail:[self toggleSplitItem:2]; break;
        case Cmd::FocusSearch:    [self.window makeFirstResponder:_searchField]; break;
        case Cmd::OpenSettings:   [self cmdOpenSettings:nil]; break;
        case Cmd::CheckUpdate:    [self cmdCheckUpdate:nil]; break;
    }
    [self refreshSnapshot];
}

- (void)toggleSplitItem:(NSInteger)idx {
    if (idx >= (NSInteger)_split.splitViewItems.count) return;
    NSSplitViewItem* item = _split.splitViewItems[idx];
    item.collapsed = !item.collapsed;
}

- (void)cmdSetMode:(NSMenuItem*)sender { [self handleCmd:(Cmd)((int)Cmd::ModeSequential + (int)sender.tag)]; }
- (void)cmdSetTheme:(NSMenuItem*)sender {
    _themeIndex = sender.tag;
    [self applyTheme];
}
- (void)cmdNav:(NSButton*)sender {
    _selectedNav = sender.tag;
    NSString* name = _navItems[_selectedNav];
    _headerLabel.stringValue = name;
    if (_selectedNav == 5 || _selectedNav == 0) {
        // 播放队列 / 专辑：P1 把专辑网格与队列文本视图切换
        _albumGrid.hidden = (_selectedNav == 5);
        _queueTable.hidden = (_selectedNav != 5);
        if (_selectedNav == 5) [self reloadQueueIntoMain];
    }
    // 其余视图 P2/P3 补齐（如实挂账，不谎报）
}
- (void)reloadQueueIntoMain {
    rlnative::QueueState q = rlnative::queue(true);
    _queue = q.items;
    [_queueTable reloadData];
}
- (void)cmdSearch:(id)sender { [self reloadAlbums:_searchField.stringValue]; }
- (void)cmdSeek:(id)sender   { rlnative::seek(_seekSlider.doubleValue); }
- (void)cmdVolume:(id)sender { rlnative::set_volume_db(_volumeSlider.doubleValue); }

- (void)cmdOpenSettings:(id)sender {
    (void)sender;
    NSAlert* a = [[NSAlert alloc] init];
    a.messageText = @"设置";
    a.informativeText = @"设置窗口（10 页签）在 P3 交付；P1 阶段仅提供菜单入口，不谎报完成。";
    [a addButtonWithTitle:@"好"];
    [a runModal];
}
- (void)cmdCheckUpdate:(id)sender {
    (void)sender;
    NSAlert* a = [[NSAlert alloc] init];
    a.messageText = @"检查更新";
    a.informativeText = @"独立更新窗口（状态机 + 门槛 + 忽略/稍后持久化）在 P3 交付；P1 阶段仅提供菜单入口。";
    [a addButtonWithTitle:@"好"];
    [a runModal];
}

@end

// ---------------------------------------------------------------------------
// C 入口：由 tools/mac_host.mm 在 RLPLAYER_UI=native 时调用
// ---------------------------------------------------------------------------
static std::atomic<int> g_terminate_flag{0};

int rlnative_start(void) {
    @autoreleasepool {
        RLNativeAppDelegate* del = [[RLNativeAppDelegate alloc] init];
        NSApplication* app = [NSApplication sharedApplication];
        app.delegate = del;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 1;
}

int rlnative_should_terminate(void) {
    return g_terminate_flag.load();
}
