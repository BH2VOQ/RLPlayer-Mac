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
@property (nonatomic, strong) NSViewController *currentContent;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSViewController *> *pageCache;
/// 详情页的返回栈（只存"从哪个列表页进来"），返回时回到原列表页。
@property (nonatomic, strong) NSMutableArray<NSNumber *> *rowStack;
@property (nonatomic, strong) RLPNowPlayingViewController *npPage;
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
    [win setFrameAutosaveName:@"RLPNativeMainWindow"];
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
    _topbar = [[NSView alloc] initWithFrame:NSZeroRect];
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
    _search = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    _search.placeholderString = RLPTr(@"搜索曲目 / 专辑 / 艺术家");
    _search.translatesAutoresizingMaskIntoConstraints = NO;
    _search.target = self;
    _search.action = @selector(onSearch:);
    [_topbar addSubview:_search];

    NSButton *queueBtn = RLPSymbolButton(@"list.bullet", @"播放队列", self, @selector(onQueue:));
    queueBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_topbar addSubview:queueBtn];

    NSButton *npBtn = RLPSymbolButton(@"play.rectangle", @"正在播放", self, @selector(onNowPlaying:));
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

        [_search.leadingAnchor constraintEqualToAnchor:_topbar.leadingAnchor constant:16],
        [_search.centerYAnchor constraintEqualToAnchor:_topbar.centerYAnchor],
        [_search.widthAnchor constraintEqualToConstant:300],

        [npBtn.trailingAnchor constraintEqualToAnchor:_topbar.trailingAnchor constant:-16],
        [npBtn.centerYAnchor constraintEqualToAnchor:_topbar.centerYAnchor],
        [npBtn.widthAnchor constraintEqualToConstant:28],
        [queueBtn.trailingAnchor constraintEqualToAnchor:npBtn.leadingAnchor constant:-10],
        [queueBtn.centerYAnchor constraintEqualToAnchor:_topbar.centerYAnchor],
        [queueBtn.widthAnchor constraintEqualToConstant:28],

        [_playbackBar.leadingAnchor constraintEqualToAnchor:_sidebar.view.trailingAnchor],
        [_playbackBar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_playbackBar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [_playbackBar.heightAnchor constraintEqualToConstant:kPlaybackHeight],

        [_pageHost.leadingAnchor constraintEqualToAnchor:_sidebar.view.trailingAnchor],
        [_pageHost.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_pageHost.topAnchor constraintEqualToAnchor:_topbar.bottomAnchor],
        [_pageHost.bottomAnchor constraintEqualToAnchor:_playbackBar.topAnchor],
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

    [self showContentForRow:0];
    [_sidebar selectRow:0];
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
    if ([vc respondsToSelector:@selector(activate)]) [(id)vc activate];
}

- (void)showContentForRow:(NSInteger)row {
    NSViewController *vc = self.pageCache[@(row)];
    if (!vc) {
        switch (row) {
            case 0: vc = self.albums; break;
            case 1: {
                RLPArtistsViewController *a = [[RLPArtistsViewController alloc] init];
                vc = a;
                break;
            }
            case 2: {
                RLPTracksViewController *tr = [[RLPTracksViewController alloc] init];
                vc = tr;
                break;
            }
            case 3: vc = [[RLPFoldersViewController alloc] init]; break;
            case 4: vc = [[RLPStreamingViewController alloc] init]; break;
            case 5: vc = [[RLPQueueViewController alloc] init]; break;
            case 6: vc = [[RLPRecentViewController alloc] init]; break;
            case 7: vc = [[RLPFavoritesViewController alloc] init]; break;
            case 8: vc = [[RLPPlaylistsViewController alloc] init]; break;
            case 9: vc = [[RLPQuickStartViewController alloc] init]; break;
            case 10: vc = [[RLPSettingsViewController alloc] init]; break;
            default: vc = self.albums; break;
        }
        self.pageCache[@(row)] = vc;
    }
    if (vc == self.currentContent) {
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
    if ([vc respondsToSelector:@selector(activate)]) [(id)vc activate];
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
    [self.sidebar selectRow:10];
    RLPSettingsViewController *settings = (RLPSettingsViewController *)self.pageCache[@(10)];
    if (![settings isKindOfClass:[RLPSettingsViewController class]]) return;
    [settings selectPane:(NSString *)note.object];
}

- (void)pushDetail:(NSViewController *)detail {
    if (!detail) return;
    if (self.currentContent) {
        // 记住"从哪一行进来的"，返回时回到那一行（不重置用户的位置）
        [self.rowStack addObject:@([self currentRow])];
    }
    [self swapContentTo:detail];
}

- (void)popDetail {
    NSNumber *back = self.rowStack.lastObject;
    if (!back) return;
    [self.rowStack removeLastObject];
    NSViewController *vc = self.pageCache[back];
    if (!vc) return;
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
    if ([vc respondsToSelector:@selector(activate)]) [(id)vc activate];
}

#pragma mark - 顶栏动作

- (void)onSearch:(id)sender {
    NSString *q = [self.search.stringValue stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // 全局搜索的落点 = 曲目页（与 web 版一致：搜索是跨库的，不是页内过滤）
    NSViewController *tracks = self.pageCache[@(2)];
    if (![tracks isKindOfClass:[RLPTracksViewController class]]) {
        tracks = [[RLPTracksViewController alloc] init];
        self.pageCache[@(2)] = tracks;
    }
    [self.sidebar selectRow:2];
    [(RLPTracksViewController *)tracks searchWithQuery:q ?: @""];
}

- (void)onQueue:(id)sender {
    [self.sidebar selectRow:5];
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
    // **所有缓存页**都要刷，不只是当前页：否则切到浅色后再点别的导航项，
    // 那一页还是深色的（用户实测的"主页还是黑的"就是这个）。
    for (NSNumber *key in self.pageCache) {
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