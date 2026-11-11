// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPMainWindowController.mm — 主窗口：侧栏 + 顶栏 + 内容页 + 底部播放条（纯 AppKit）
//
// 顶栏是全局入口（搜索 / 主题 / 队列 / 单曲页），页面自己的标题在页面内；
// 路由只按 sidebar 的 row 走，页面 VC 懒创建并缓存。
#import "RLPMainWindowController.h"
#import "RLPSidebarViewController.h"
#import "RLPAlbumsViewController.h"
#import "RLPPlaybackBarView.h"
#import "RLPPlaceholderViewController.h"
#import "RLPStreamingViewController.h"
#import "RLPQuickStartViewController.h"
#import "RLPWorkbenchViewController.h"
#import "RLPPlaylistsViewController.h"
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
#import "RLPAlbumDetailViewController.h"
#import "RLPArtistDetailViewController.h"
#import "RLPCoreClient.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

/// 顶栏：标题/计数是纯 frame 子视图，Auto Layout pass 会把它们归零，
/// 所以每次 layout 后重放一次位置（离屏渲染也走这条路）。
@interface RLPTopbarView : NSView
@property (nonatomic, weak) NSTextField *title;
@property (nonatomic, weak) NSTextField *count;
@end
@implementation RLPTopbarView
- (void)layout {
    [super layout];
    if (self.title) {
        [self.title sizeToFit];
        CGRect f = self.title.frame;
        f.origin = CGPointMake(20, (self.bounds.size.height - f.size.height) / 2.0);
        self.title.frame = f;
    }
    if (self.count) {
        [self.count sizeToFit];
        CGRect f = self.count.frame;
        f.origin = CGPointMake(CGRectGetMaxX(self.title.frame) + 8,
                               (self.bounds.size.height - f.size.height) / 2.0);
        self.count.frame = f;
    }
}
@end

static const CGFloat kSidebarWidth = 232.0;
static const CGFloat kPlaybackHeight = 76.0;
static const CGFloat kTopbarHeight = 46.0;

@interface RLPMainWindowController ()
@property (nonatomic, strong, readwrite) RLPSidebarViewController *sidebar;
@property (nonatomic, strong, readwrite) RLPAlbumsViewController *albums;
@property (nonatomic, strong, readwrite) RLPPlaybackBarView *playbackBar;
@property (nonatomic, strong) NSView *topbar;
@property (nonatomic, strong) NSView *pageHost;
@property (nonatomic, strong) NSSearchField *search;
@property (nonatomic, strong) NSTextField *pageTitle;   // 顶栏页标题（web #pth）
@property (nonatomic, strong) NSTextField *pageCount;   // 计数（web #cnt）
@property (nonatomic, strong) NSViewController *currentContent;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSViewController *> *pageCache;
/// 详情页的返回栈（只存"从哪个列表页进来"），返回时回到原列表页。
@property (nonatomic, strong) NSMutableArray<NSString *> *rowStack;
@property (nonatomic, strong) RLPNowPlayingViewController *npPage;
/// 顶栏的模式切换（聆听 / 专业）。这是两个模式的唯一入口。
@property (nonatomic, strong) NSSegmentedControl *modeSwitch;
@end

@implementation RLPMainWindowController

- (instancetype)init {
    RLPTheme *t = [RLPTheme current];
    NSRect frame = NSMakeRect(0, 0, 1180, 760);
    NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                   NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                   NSWindowStyleMaskFullSizeContentView)
          backing:NSBackingStoreBuffered defer:NO];
    win.title = @"RLPlayer";
    win.titlebarAppearsTransparent = YES;
    win.titleVisibility = NSWindowTitleHidden;
    win.backgroundColor = t.bg;
    win.minSize = NSMakeSize(900, 600);
    win.appearance = [NSAppearance appearanceNamed:t.isLight ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua];
    // 默认尺寸 1180×760（用户 2026-11-11 明确满意的 web 版尺寸）。
    // autosave 键**换名**：旧键 RLPNativeMainWindow 里存着开发期离屏审计写坏的宽度
    // （1257/1361…），沿用旧键会让用户一直看到错尺寸。换键即丢弃那批脏记录，
    // 同时保留"用户之后自己调整的大小仍被记住"这一正常行为。
    [win setFrameAutosaveName:@"RLPNativeMainWindow.v2"];
    if (![[NSUserDefaults standardUserDefaults] stringForKey:@"NSWindow Frame RLPNativeMainWindow.v2"])
        [win setFrame:NSMakeRect(0, 0, 1180, 760) display:NO];
    [win center];

    self = [super initWithWindow:win];
    if (!self) return nil;

    NSView *root = win.contentView;
    root.wantsLayer = YES;
    root.layer.backgroundColor = t.bg.CGColor;

    _pageCache = [NSMutableDictionary dictionary];
    _rowStack = [NSMutableArray array];
    _sidebar = [[RLPSidebarViewController alloc] init];
    _albums = [[RLPAlbumsViewController alloc] init];
    _playbackBar = [[RLPPlaybackBarView alloc] init];
    _playbackBar.wantsLayer = YES;
    _playbackBar.layer.cornerRadius = 16;
    _playbackBar.layer.borderWidth = 1;
    _playbackBar.layer.masksToBounds = NO;
    _playbackBar.layer.shadowColor = NSColor.blackColor.CGColor;
    _playbackBar.layer.shadowOpacity = 0.13;
    _playbackBar.layer.shadowRadius = 19;
    _playbackBar.layer.shadowOffset = CGSizeMake(0, -6);
    _topbar = [[RLPTopbarView alloc] initWithFrame:NSZeroRect];
    _topbar.wantsLayer = YES;
    _topbar.layer.backgroundColor = t.bg.CGColor;
    _pageHost = [[NSView alloc] initWithFrame:NSZeroRect];
    _pageHost.wantsLayer = YES;
    _pageHost.layer.backgroundColor = t.bg.CGColor;

    for (NSView *v in @[_sidebar.view, _topbar, _pageHost, _playbackBar]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:v];
    }

    // ---- 顶栏内容 ----
    // 页标题+计数在左（web 顶栏同口径），搜索框在它们右边。
    // 顶栏标题/计数用**纯 frame**（不参与 Auto Layout）：
    // 离屏渲染时 intrinsic-size 约束重算不及时，标题会画不出来（实测）。
    _pageTitle = RLPLabel(@"", [NSFont systemFontOfSize:17 weight:NSFontWeightBold], t.text);
    [_topbar addSubview:_pageTitle];
    _pageCount = RLPLabel(@"", t.small, t.mut);
    [_topbar addSubview:_pageCount];
    ((RLPTopbarView *)_topbar).title = _pageTitle;
    ((RLPTopbarView *)_topbar).count = _pageCount;

    _search = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    _search.placeholderString = RLPTr(@"搜索曲目 / 专辑 / 艺术家");
    _search.translatesAutoresizingMaskIntoConstraints = NO;
    _search.target = self;
    _search.action = @selector(onSearch:);
    [_topbar addSubview:_search];

    // ---- 模式切换（聆听 / 专业）----
    // 差别在"能做什么"：切模式会重建侧栏项与首页（聆听室 / 专业工作台），不是换皮。
    _modeSwitch = [NSSegmentedControl segmentedControlWithLabels:@[RLPTr(@"聆听模式"), RLPTr(@"专业模式")]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(onModeChanged:)];
    _modeSwitch.selectedSegment = (RLPCurrentAppMode() == RLPAppModePro) ? 1 : 0;
    _modeSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    _modeSwitch.toolTip = RLPTr(@"聆听模式：安静听歌，设置就在这一页；专业模式：信号链、滤波与升频快速切换、A/B 对比");
    [_topbar addSubview:_modeSwitch];

    NSButton *queueBtn = RLPSymbolButton(@"list.bullet", RLPTr(@"播放队列"), self, @selector(onQueue:));
    queueBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_topbar addSubview:queueBtn];

    NSButton *npBtn = RLPSymbolButton(@"play.rectangle", RLPTr(@"正在播放"), self, @selector(onNowPlaying:));
    npBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_topbar addSubview:npBtn];

    [NSLayoutConstraint activateConstraints:@[
        [_sidebar.view.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_sidebar.view.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_sidebar.view.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [_sidebar.view.widthAnchor constraintEqualToConstant:kSidebarWidth],

        [_topbar.leadingAnchor constraintEqualToAnchor:_sidebar.view.trailingAnchor],
        [_topbar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_topbar.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_topbar.heightAnchor constraintEqualToConstant:kTopbarHeight],

        [_search.leadingAnchor constraintEqualToAnchor:_topbar.leadingAnchor constant:210],
        [_search.centerYAnchor constraintEqualToAnchor:_topbar.centerYAnchor],
        [_search.widthAnchor constraintEqualToConstant:300],

        [_modeSwitch.trailingAnchor constraintEqualToAnchor:queueBtn.leadingAnchor constant:-14],
        [_modeSwitch.centerYAnchor constraintEqualToAnchor:_topbar.centerYAnchor],

        [npBtn.trailingAnchor constraintEqualToAnchor:_topbar.trailingAnchor constant:-16],
        [npBtn.centerYAnchor constraintEqualToAnchor:_topbar.centerYAnchor],
        [npBtn.widthAnchor constraintEqualToConstant:28],
        [queueBtn.trailingAnchor constraintEqualToAnchor:npBtn.leadingAnchor constant:-10],
        [queueBtn.centerYAnchor constraintEqualToAnchor:_topbar.centerYAnchor],
        [queueBtn.widthAnchor constraintEqualToConstant:28],

        // 悬浮播放条（web .bar）：左右 24 / 底 14 / 高 66 / 圆角 16。
        // 内容区底也停在播放条顶之上 14，避免专辑网格被悬浮条遮住。
        [_playbackBar.leadingAnchor constraintEqualToAnchor:_sidebar.view.trailingAnchor constant:24],
        [_playbackBar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-24],
        [_playbackBar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-14],
        [_playbackBar.heightAnchor constraintEqualToConstant:66],

        [_pageHost.leadingAnchor constraintEqualToAnchor:_sidebar.view.trailingAnchor],
        [_pageHost.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_pageHost.topAnchor constraintEqualToAnchor:_topbar.bottomAnchor],
        [_pageHost.bottomAnchor constraintEqualToAnchor:_playbackBar.topAnchor constant:-14],
    ]];

    __weak __typeof__(self) weakSelf = self;
    _sidebar.onSelect = ^(NSInteger row) { [weakSelf showContentForRow:row]; };
    _albums.onPlayAlbum = ^(NSString *key) {
        RLPPlayAlbum(key, 0);
    };

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onThemeChanged:)
                                                 name:RLPThemeDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onOpenAlbum:)
                                                 name:RLPOpenAlbumNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onOpenArtist:)
                                                 name:RLPOpenArtistNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onBack:)
                                                 name:RLPBackNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onOpenSettingsPane:)
                                                 name:@"RLPOpenSettingsPaneNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onAppModeChanged:)
                                                 name:RLPAppModeDidChangeNotification object:nil];
    // 页面里发"去某个导航页"的意图（聆听室的查看全部/打开音乐库等），按 key 路由。
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onNavigateKey:)
                                                 name:@"RLPNavigateKeyNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onOpenNowPlayingNote:)
                                                 name:@"RLPOpenNowPlayingNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onPageCount:)
                                                 name:@"RLPPageCountNotification" object:nil];

    // 首页随模式：聆听 ⟹ 聆听室；专业 ⟹ 专业工作台。
    [_sidebar selectRow:0];
    [self showContentForRow:0];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - 路由


- (void)presentDetailViewController:(NSViewController *)vc {
    if (self.currentContent) [self.currentContent.view removeFromSuperview];
    self.currentContent = vc;
    NSView *v = vc.view;
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [self.pageHost addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [v.leadingAnchor constraintEqualToAnchor:self.pageHost.leadingAnchor],
        [v.trailingAnchor constraintEqualToAnchor:self.pageHost.trailingAnchor],
        [v.topAnchor constraintEqualToAnchor:self.pageHost.topAnchor],
        [v.bottomAnchor constraintEqualToAnchor:self.pageHost.bottomAnchor],
    ]];
    [self syncTopbarTitle];
    if ([vc respondsToSelector:@selector(activate)]) [(id)vc activate];
}

/// 行号 → 符号 key → 页面。**行号只在当前模式内有意义**，缓存一律按 key 存，
/// 否则切模式后同一个行号会指向另一页（聆听模式 11 项 / 专业模式 12 项，下标会错位）。
- (void)showContentForRow:(NSInteger)row {
    NSString *key = [self.sidebar keyForRow:row];
    [self showContentForKey:key.length ? key : @"albums"];
}

- (void)showContentForKey:(NSString *)key {
    if (!key.length) key = @"albums";
    NSViewController *vc = self.pageCache[key];
    if (!vc) {
        if ([key isEqualToString:@"albums"])         vc = self.albums;
        else if ([key isEqualToString:@"artists"])   vc = [[RLPArtistsViewController alloc] init];
        else if ([key isEqualToString:@"tracks"])    vc = [[RLPTracksViewController alloc] init];
        else if ([key isEqualToString:@"folders"])   vc = [[RLPFoldersViewController alloc] init];
        else if ([key isEqualToString:@"streaming"]) vc = [[RLPStreamingViewController alloc] init];
        else if ([key isEqualToString:@"queue"])     vc = [[RLPQueueViewController alloc] init];
        else if ([key isEqualToString:@"recent"])    vc = [[RLPRecentViewController alloc] init];
        else if ([key isEqualToString:@"favorites"]) vc = [[RLPFavoritesViewController alloc] init];
        else if ([key isEqualToString:@"playlists"]) vc = [[RLPPlaylistsViewController alloc] init];
        else if ([key isEqualToString:@"room"])      vc = [[RLPQuickStartViewController alloc] init];
        else if ([key isEqualToString:@"workbench"]) vc = [self makeWorkbench];
        else if ([key isEqualToString:@"settings"])  vc = [[RLPSettingsViewController alloc] init];
        else vc = self.albums;
        self.pageCache[key] = vc;
    }
    if (vc == self.currentContent) {
        // 同页再次点选：也要重设标题并按需重新上报计数
        [self syncTopbarTitle];
        if ([vc respondsToSelector:@selector(activate)]) [(id)vc activate];
        return;
    }
    if (self.currentContent) [self.currentContent.view removeFromSuperview];
    self.currentContent = vc;

    NSView *v = vc.view;
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [self.pageHost addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [v.leadingAnchor constraintEqualToAnchor:self.pageHost.leadingAnchor],
        [v.trailingAnchor constraintEqualToAnchor:self.pageHost.trailingAnchor],
        [v.topAnchor constraintEqualToAnchor:self.pageHost.topAnchor],
        [v.bottomAnchor constraintEqualToAnchor:self.pageHost.bottomAnchor],
    ]];
    // 顺序重要：先同步标题（会清空计数），再 activate（页面此时上报计数）
    [self syncTopbarTitle];
    if ([vc respondsToSelector:@selector(activate)]) [(id)vc activate];
}

/// 顶栏页标题 = 当前页的 pageTitle；详情页也用它自己的标题。
- (void)syncTopbarTitle {
    NSString *title = nil;
    if ([self.currentContent respondsToSelector:@selector(pageTitle)])
        title = [(id)self.currentContent pageTitle];
    self.pageTitle.stringValue = title.length ? RLPTr(title) : @"";
    // 计数先清空，随后由页面的 activate 重新上报（调用点保证"先 sync 再 activate"）。
    // 之前顺序反了（activate 上报 → sync 清空）⟹ 顶栏计数一直是空的。
    self.pageCount.stringValue = @"";
    // 离屏渲染时 intrinsic-size 约束不会及时重算（实测宽度停在旧值），
    // 直接 sizeToFit 设 frame，保证标题在任何渲染路径下都画得出来。
    [self.pageTitle sizeToFit];
    CGRect f = self.pageTitle.frame;
    f.origin = CGPointMake(20, (self.topbar.bounds.size.height - f.size.height) / 2.0);
    self.pageTitle.frame = f;
}

- (void)onPageCount:(NSNotification *)note {
    if (![note.object isKindOfClass:[NSString class]]) return;
    self.pageCount.stringValue = (NSString *)note.object;
    [self.pageCount sizeToFit];
    CGRect f = self.pageCount.frame;
    f.origin = CGPointMake(CGRectGetMaxX(self.pageTitle.frame) + 8,
                           (self.topbar.bounds.size.height - f.size.height) / 2.0);
    self.pageCount.frame = f;
}

#pragma mark - 页面导航（详情页压栈；返回回原列表页）

- (void)onOpenAlbum:(NSNotification *)note {
    if (![note.object isKindOfClass:[NSString class]] || ![(NSString *)note.object length]) return;
    RLPAlbumDetailViewController *detail = [[RLPAlbumDetailViewController alloc] initWithAlbumKey:(NSString *)note.object];
    [self pushDetail:detail];
}

- (void)onOpenArtist:(NSNotification *)note {
    if (![note.object isKindOfClass:[NSString class]] || ![(NSString *)note.object length]) return;
    RLPArtistDetailViewController *detail = [[RLPArtistDetailViewController alloc] initWithArtistName:(NSString *)note.object];
    [self pushDetail:detail];
}

- (void)onBack:(NSNotification *)note {
    [self popDetail];
}

- (void)onOpenSettingsPane:(NSNotification *)note {
    if (![note.object isKindOfClass:[NSString class]]) return;
    // 设置只存在于专业模式：从聆听模式发来的跳转请求要先切模式，否则请求会被静默丢弃。
    if (RLPCurrentAppMode() != RLPAppModePro) {
        RLPSetAppMode(RLPAppModePro);
        [self applyModeChange];
    }
    [self.sidebar selectKey:@"settings"];
    RLPSettingsViewController *settings = (RLPSettingsViewController *)self.pageCache[@"settings"];
    if (![settings isKindOfClass:[RLPSettingsViewController class]]) return;
    [settings selectPane:(NSString *)note.object];
}

- (void)onNavigateKey:(NSNotification *)note {
    if (![note.object isKindOfClass:[NSString class]]) return;
    NSString *key = (NSString *)note.object;
    // 目标页在当前模式不存在（如聆听模式下的 settings）⟹ 交给设置跳转逻辑处理切模式。
    if ([self.sidebar selectKey:key]) return;
    if ([key isEqualToString:@"settings"]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenSettingsPaneNotification" object:@"out"];
    }
}

- (void)onOpenNowPlayingNote:(NSNotification *)note {
    (void)note;
    [self onNowPlaying:nil];
}

#pragma mark - 模式切换

- (void)onModeChanged:(NSSegmentedControl *)sender {
    RLPSetAppMode(sender.selectedSegment == 1 ? RLPAppModePro : RLPAppModeListening);
    [self applyModeChange];
}

/// 模式变了：重建侧栏项、同步分段控件、把内容切到该模式仍存在的页（不存在则回首页）。
- (void)applyModeChange {
    self.modeSwitch.selectedSegment = (RLPCurrentAppMode() == RLPAppModePro) ? 1 : 0;
    NSString *before = self.sidebar.selectedKey;
    [self.sidebar reloadForModeChange];
    NSString *after = self.sidebar.selectedKey;
    // 侧栏选中项没变（那页两个模式都有）⟹ 内容不用动；变了则跟着走。
    if (![before isEqualToString:after ?: @""]) [self showContentForKey:after ?: @"albums"];
}

- (void)onAppModeChanged:(NSNotification *)note {
    (void)note;
    // 别处（如设置跳转）改了模式时，顶栏与侧栏也要跟上。
    [self applyModeChange];
}

/// 专业工作台（专业模式首页）：信号链 + 快速切换 + A/B 槽位。
- (NSViewController *)makeWorkbench {
    return [[RLPWorkbenchViewController alloc] init];
}

- (void)pushDetail:(NSViewController *)detail {
    if (!detail) return;
    if (self.currentContent) {
        // 记住"从哪一页进来的"，返回时回到那一页（不重置用户的位置）。
        // 存 key 而不是行号：模式切换后行号会错位。
        NSString *k = self.sidebar.selectedKey;
        [self.rowStack addObject:(k.length ? k : @"albums")];
    }
    [self swapContentTo:detail];
}

- (void)popDetail {
    NSString *back = self.rowStack.lastObject;
    if (!back.length) return;
    [self.rowStack removeLastObject];
    NSViewController *vc = self.pageCache[back];
    if (!vc) return;
    [self.sidebar selectKey:back];
    [self swapContentTo:vc];
}

- (NSInteger)currentRow {
    return self.sidebar.selectedRow >= 0 ? self.sidebar.selectedRow : 0;
}

- (void)swapContentTo:(NSViewController *)vc {
    if (!vc || vc == self.currentContent) return;
    if (self.currentContent) [self.currentContent.view removeFromSuperview];
    self.currentContent = vc;
    NSView *v = vc.view;
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [self.pageHost addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [v.leadingAnchor constraintEqualToAnchor:self.pageHost.leadingAnchor],
        [v.trailingAnchor constraintEqualToAnchor:self.pageHost.trailingAnchor],
        [v.topAnchor constraintEqualToAnchor:self.pageHost.topAnchor],
        [v.bottomAnchor constraintEqualToAnchor:self.pageHost.bottomAnchor],
    ]];
    [self syncTopbarTitle];
    if ([vc respondsToSelector:@selector(activate)]) [(id)vc activate];
}

#pragma mark - 顶栏动作

- (void)onSearch:(id)sender {
    NSString *q = [self.search.stringValue stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // 全局搜索的落点 = 曲目页（与 web 版一致：搜索是跨库的，不是页内过滤）
    NSViewController *tracks = self.pageCache[@"tracks"];
    if (![tracks isKindOfClass:[RLPTracksViewController class]]) {
        tracks = [[RLPTracksViewController alloc] init];
        self.pageCache[@"tracks"] = tracks;
    }
    [self.sidebar selectKey:@"tracks"];
    [(RLPTracksViewController *)tracks searchWithQuery:q ?: @""];
}

- (void)onQueue:(id)sender {
    [self.sidebar selectKey:@"queue"];
}

- (void)onNowPlaying:(id)sender {
    if (!self.npPage) self.npPage = [[RLPNowPlayingViewController alloc] init];
    [self pushDetail:self.npPage];
}

#pragma mark - 主题

- (void)onThemeChanged:(NSNotification *)note {
    RLPTheme *t = [RLPTheme current];
    self.window.backgroundColor = t.bg;
    self.window.appearance = [NSAppearance appearanceNamed:t.isLight ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua];
    self.window.contentView.layer.backgroundColor = t.bg.CGColor;
    self.topbar.layer.backgroundColor = t.bg.CGColor;
    self.pageHost.layer.backgroundColor = t.bg.CGColor;
    [self.sidebar applyTheme];
    [self.playbackBar applyTheme];
    self.playbackBar.layer.borderColor = t.line.CGColor;
    self.pageTitle.textColor = t.text;
    self.pageCount.textColor = t.mut;
    [self.modeSwitch setLabel:RLPTr(@"聆听模式") forSegment:0];
    [self.modeSwitch setLabel:RLPTr(@"专业模式") forSegment:1];
    // **所有缓存页**都要刷，不只是当前页：否则切到浅色后再点别的导航项，
    // 那一页还是深色的（用户实测的"主页还是黑的"就是这个）。
    for (NSString *key in self.pageCache) {
        NSViewController *vc = self.pageCache[key];
        if ([vc respondsToSelector:@selector(applyTheme)]) [(id)vc applyTheme];
    }
    if ([self.currentContent respondsToSelector:@selector(applyTheme)]) [(id)self.currentContent applyTheme];
}

#pragma mark - 生命周期

- (void)loadInitialData {
    if (![RLPCoreClient shared].started) return;
    [self.albums reload];
    [self.playbackBar startPolling];
    // 启动检查更新：延迟 3 秒（先让界面出来），自动模式不打扰——只在有新版本时弹窗
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[RLPUpdateWindowController shared] checkManually:NO];
    });
}

- (void)stopAllActivity {
    [self.playbackBar stopPolling];
}

@end