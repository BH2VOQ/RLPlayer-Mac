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
#import "RLPRightDrawer.h"
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
#import "RLPWorksViewController.h"
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

// 几何一律取 web 的确切值（ui_page.h）：--sidew:226 / .top height:60 / .bar height:66。
// 之前原生写 232/46/76 是自造的，导致侧栏偏宽、顶栏偏矮、播放条偏高。
// classic 风格顶栏是 52（html[data-uistyle=classic] #app grid-template-rows:52px）。
static const CGFloat kSidebarWidth = 226.0;   // --sidew
static const CGFloat kPlaybackHeight = 66.0;  // .bar height
static const CGFloat kTopbarHeight = 60.0;    // .top height（classic 52，见 topbarHeight()）

@interface RLPMainWindowController ()
@property (nonatomic, strong, readwrite) RLPSidebarViewController *sidebar;
@property (nonatomic, strong, readwrite) RLPAlbumsViewController *albums;
@property (nonatomic, strong, readwrite) RLPPlaybackBarView *playbackBar;
@property (nonatomic, strong) NSView *topbar;
@property (nonatomic, strong) NSView *pageHost;
/// 顶栏高度约束：classic 风格是 52，apple 是 60（web #app grid-template-rows）。
/// 存下来才能在切风格时实时改，而不是只存偏好值不生效。
@property (nonatomic, strong) NSLayoutConstraint *topbarHeightConstraint;
/// 右侧抽屉（web #right）：队列 / 歌词，悬浮毛玻璃卡片。
@property (nonatomic, strong) RLPRightDrawer *rightDrawer;
@property (nonatomic, assign) BOOL drawerOpen;
@property (nonatomic, strong) NSSearchField *search;
@property (nonatomic, strong) NSTextField *pageTitle;   // 顶栏页标题（web #pth）
@property (nonatomic, strong) NSTextField *pageCount;   // 计数（web #cnt）
@property (nonatomic, strong) NSViewController *currentContent;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSViewController *> *pageCache;
/// 详情页的返回栈（只存"从哪个列表页进来"），返回时回到原列表页。
@property (nonatomic, strong) NSMutableArray<NSString *> *rowStack;
@property (nonatomic, strong) RLPNowPlayingViewController *npPage;
@property (nonatomic, strong) RLPWorksViewController *worksPage;
@property (nonatomic, readwrite) BOOL nowPlayingOverlayVisible;
@property (nonatomic,strong) NSButton *webBackButton;
@end

/// 视图根节点的 identifier 表 —— **字面量**，不做字符串拼接。
/// 原因：parity 扫描器（tools/native_ui/parity_scan.py）只认源码里的字面量；
/// 拼接出来的值它看不见，会把一整批**已实现**的视图误报成 missing（假缺口）。
/// key = 原生路由 key；value = web 的 view key 对应的原生锚点。
static NSString *RLPPageIdentifier(NSString *key) {
    static NSDictionary<NSString *, NSString *> *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = @{
            @"albums":    @"page.albums",     // web data-v=albums
            @"artists":   @"page.artists",    // web data-v=artists
            @"tracks":    @"page.tracks",     // web data-v=tracks
            @"folders":   @"page.files",      // web data-v=files
            @"streaming": @"page.remote",     // web data-v=remote
            @"queue":     @"page.queue",      // web data-v=queue
            @"recent":    @"page.recent",     // web data-v=recent
            @"favorites": @"page.favs",       // web data-v=favs
            @"playlists": @"page.sq",         // web data-v=sq
            @"station":   @"page.station",    // web data-v=station
            @"settings":  @"page.settings",   // web data-v=settings
        };
    });
    return m[key];
}

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
    // ⚠️ 顺序关键（本轮实测踩到）：`_playbackBar` 在 `init` 里就被创建，而它的 `setup`
    // 里 `self.layer.backgroundColor = ...` 会**新建/复用 layer**。如果上面这几行写在
    // `[[RLPPlaybackBarView alloc] init]` 之前（或之后又被重设 layer），shadow 会被清零。
    // 现在统一在**主题应用后**再写一次，保证任何一次 applyTheme 之后形状都在。
    // （审计读到的 op=0.00 就是这个顺序问题造成的，不是主题覆盖。）
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

    NSButton *queueBtn = RLPSymbolButton(@"list.bullet", RLPTr(@"播放队列"), self, @selector(onQueue:));
    queueBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_topbar addSubview:queueBtn];

    // 顶栏「刷新曲库」（web #bScan：重新扫描音乐库；用户实测「没做刷新曲库的按钮」）。
    NSButton *scanBtn = RLPSymbolButton(@"arrow.clockwise", RLPTr(@"重新扫描音乐库"), self, @selector(onScanLibrary:));
    scanBtn.translatesAutoresizingMaskIntoConstraints = NO;
    scanBtn.identifier = @"top.scan";
    [_topbar addSubview:scanBtn];

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
        // 占位：真正的约束在下面单独建并存起来（切 classic 时要改它）


        [_search.leadingAnchor constraintEqualToAnchor:_topbar.leadingAnchor constant:210],
        [_search.centerYAnchor constraintEqualToAnchor:_topbar.centerYAnchor],
        [_search.widthAnchor constraintEqualToConstant:300],

        [npBtn.trailingAnchor constraintEqualToAnchor:_topbar.trailingAnchor constant:-16],
        [npBtn.centerYAnchor constraintEqualToAnchor:_topbar.centerYAnchor],
        [npBtn.widthAnchor constraintEqualToConstant:28],
        [queueBtn.trailingAnchor constraintEqualToAnchor:npBtn.leadingAnchor constant:-10],
        [queueBtn.centerYAnchor constraintEqualToAnchor:_topbar.centerYAnchor],
        [queueBtn.widthAnchor constraintEqualToConstant:28],
        [scanBtn.trailingAnchor constraintEqualToAnchor:queueBtn.leadingAnchor constant:-10],
        [scanBtn.centerYAnchor constraintEqualToAnchor:_topbar.centerYAnchor],
        [scanBtn.widthAnchor constraintEqualToConstant:28],

        // 悬浮播放条（web .bar）：最大宽 1120 **居中**、底 14 / 高 66 / 圆角 16。
        // 旧实现钉死左右各 24 ⟹ 宽窗口下播放条比 web 版宽，右侧状态簇被拉散，
        // 用户看到的「播放条比例不对」有一部分来自这里（web 是 max-width:1120;margin:auto）。
        // 宽度用低优先级等式给足可用宽，再用 required 的 ≤1120 与左右边距兜底。
        // ⚠️ 居中基准是**整个窗口**，不是 _pageHost（内容区）。
        // 参考图（Apple Music 截图）里胶囊条相对整个窗口居中、左右留白近似相等；
        // 早先钉在 _pageHost 上会让它偏右（实测 left=250 / right=24，明显不居中）。
        [_playbackBar.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [_playbackBar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-14],
        [_playbackBar.heightAnchor constraintEqualToConstant:66],
        [_playbackBar.leadingAnchor constraintGreaterThanOrEqualToAnchor:_sidebar.view.trailingAnchor constant:24],
        [_playbackBar.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-24],

        [_pageHost.leadingAnchor constraintEqualToAnchor:_sidebar.view.trailingAnchor],
        [_pageHost.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_pageHost.topAnchor constraintEqualToAnchor:_topbar.bottomAnchor],
        [_pageHost.bottomAnchor constraintEqualToAnchor:_playbackBar.topAnchor constant:-14],
    ]];
    {
        // ---- 右侧抽屉（web #right）----
    // web: position:fixed; top:68px; right:18px; bottom:92px; width:320px。
    // 它是**悬浮**卡片，不占网格列 ⟹ 打开时主内容区宽度不变（web 明确修过这一点）。
    _rightDrawer = [[RLPRightDrawer alloc] initWithFrame:NSZeroRect];
    _rightDrawer.translatesAutoresizingMaskIntoConstraints = NO;
    _rightDrawer.hidden = YES;
    [root addSubview:_rightDrawer];
    [NSLayoutConstraint activateConstraints:@[
        [_rightDrawer.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-18],
        [_rightDrawer.topAnchor constraintEqualToAnchor:root.topAnchor constant:68],
        [_rightDrawer.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-92],
        [_rightDrawer.widthAnchor constraintEqualToConstant:320],
    ]];

    _topbarHeightConstraint = [_topbar.heightAnchor constraintEqualToConstant:[RLPTheme current].topH];
    _topbarHeightConstraint.active = YES;

    NSLayoutConstraint *fill = [_playbackBar.widthAnchor constraintEqualToAnchor:_pageHost.widthAnchor constant:-48];
        fill.priority = NSLayoutPriorityDefaultHigh;   // 750：窄窗口按可用宽度铺满
        NSLayoutConstraint *cap = [_playbackBar.widthAnchor constraintLessThanOrEqualToConstant:1120];
        [NSLayoutConstraint activateConstraints:@[fill, cap]];
    }

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
    // 页面里发"去某个导航页"的意图（聆听室的查看全部/打开音乐库等），按 key 路由。
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onNavigateKey:)
                                                 name:@"RLPNavigateKeyNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onOpenNowPlayingNote:)
                                                 name:@"RLPOpenNowPlayingNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onCloseNowPlaying:) name:@"RLPCloseNowPlayingNotification" object:nil];
    // 古典作品 · 演绎版本（web 只从单曲页「作品」tab 进入，左导航不放入口）。
    // object = @{@"title":…, @"composer":…}；从单曲页进来时给返回按钮。
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onOpenWorksNote:)
                                                 name:@"RLPOpenWorksNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onPageCount:)
                                                 name:@"RLPPageCountNotification" object:nil];
    // 播放位置心跳 → 抽屉歌词高亮（web 用同一次轮询驱动 syncLyrics）
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onPlaybackTick:)
                                                 name:@"RLPPlaybackTickNotification" object:nil];
    // 底栏歌词键 → 打开抽屉的歌词页
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onOpenLyricDrawerNote:)
                                                 name:@"RLPOpenLyricDrawerNotification" object:nil];

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
    // 详情页也有稳定锚点（web 的 album / artist / works 视图）：
    // 页面类型 → 锚点，同样是字面量表。没有这张表，「专辑详情页存在」就只剩口头声明。
    if ([vc isKindOfClass:[RLPAlbumDetailViewController class]])         v.identifier = @"page.album";
    else if ([vc isKindOfClass:[RLPArtistDetailViewController class]])   v.identifier = @"page.artist";
    else if ([vc isKindOfClass:[RLPWorksViewController class]])          v.identifier = @"page.works";
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

/// 行号 → 符号 key → 页面。缓存一律按 key 存，不按行号 ——
/// 行号会随导航项顺序变化而错位（web 也是按 data-v 的 key 路由）。
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
        else if ([key isEqualToString:@"station"])   vc = [[RLPQuickStartViewController alloc] init];
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
    // 页面根视图的 identifier = "page.<web view key>"（字面量表 RLPPageIdentifier）。
    // 这不是装饰：parity 表靠字面量机械抽取原生侧事实，页面没有稳定锚点就没法证明
    // 「web 的某个视图在原生存在」，只能靠人记 —— 那就等于没证据。
    v.identifier = RLPPageIdentifier(key);
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
    // web 顶栏左上角是**圆形 chevron 返回键**（回到上一页），旧实现是"← 返回专辑"文字胶囊，
    // 且固定钉在右侧 —— 用户实测「这个返回专辑的按钮是无意义的，改成图二返回上一页的布局」。
    if(!self.webBackButton){
        NSButton *b = RLPSymbolButton(@"chevron.left", RLPTr(@"返回上一页"), self, @selector(onTopbarBack:));
        b.title = @"";          // 纯图标键（NSButton 默认 title="Button" 会画出一截文字）
        b.bordered = NO;
        b.wantsLayer = YES;
        b.layer.cornerRadius = 14;
        b.layer.backgroundColor = [RLPTheme current].hov.CGColor;
        b.identifier = @"top.back";
        self.webBackButton = b;
        [self.topbar addSubview:b];
    }
    self.webBackButton.frame=NSMakeRect(14, (self.topbar.bounds.size.height-28)/2.0, 28, 28);
    self.webBackButton.hidden=self.rowStack.count==0;
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
    f.origin = CGPointMake(self.webBackButton.hidden ? 20 : 52,
                           (self.topbar.bounds.size.height - f.size.height) / 2.0);
    self.pageTitle.frame = f;
}

- (void)onTopbarBack:(id)sender { [self popDetail]; }

/// 顶栏「重新扫描音乐库」= web #bScan（POST /api/lib/scan，body 空）。
/// 后端已在扫时 started=false，提示"扫描已在进行中"，不假装启动。
- (void)onScanLibrary:(id)sender {
    if (![RLPCoreClient shared].started) { RLPToast(RLPTr(@"核心未启动")); return; }
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/lib/scan" body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        BOOL started = [json[@"started"] respondsToSelector:@selector(boolValue)] ? [json[@"started"] boolValue] : YES;
        RLPToast(started ? RLPTr(@"开始扫描音乐库") : RLPTr(@"扫描已在进行中"));
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPLibraryChangedNotification" object:nil];
        // 曲目/专辑/艺术家页都重拉一次（与 web libChanged 同口径）
        [self_ reloadVisibleLibraryPages];
    }];
}

- (void)reloadVisibleLibraryPages {
    for (NSString *key in @[@"albums", @"artists", @"tracks", @"folders"]) {
        NSViewController *vc = self.pageCache[key];
        if ([vc respondsToSelector:@selector(reloadData)]) [(id)vc reloadData];
    }
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
    if(self.nowPlayingOverlayVisible){[self onCloseNowPlaying:nil];return;}
    [self popDetail];
}

- (void)onOpenSettingsPane:(NSNotification *)note {
    if (![note.object isKindOfClass:[NSString class]]) return;
    [self.sidebar selectKey:@"settings"];
    RLPSettingsViewController *settings = (RLPSettingsViewController *)self.pageCache[@"settings"];
    if (![settings isKindOfClass:[RLPSettingsViewController class]]) return;
    [settings selectPane:(NSString *)note.object];
}

- (void)onNavigateKey:(NSNotification *)note {
    if (![note.object isKindOfClass:[NSString class]]) return;
    NSString *key = (NSString *)note.object;
    // 目标页不存在 ⟹ 退回设置页的默认页签。
    if ([self.sidebar selectKey:key]) return;
    if ([key isEqualToString:@"settings"]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenSettingsPaneNotification" object:@"play"];
    }
}

- (void)onOpenNowPlayingNote:(NSNotification *)note {
    (void)note;
    [self onNowPlaying:nil];
}

/// 打开古典作品页并检索（对齐 web loadWorksView(title, composer, fromNp)）。
- (void)onOpenWorksNote:(NSNotification *)note {
    if(self.nowPlayingOverlayVisible)[self onCloseNowPlaying:nil];
    NSDictionary *info = [note.object isKindOfClass:[NSDictionary class]] ? note.object : @{};
    NSString *title = [info[@"title"] isKindOfClass:[NSString class]] ? info[@"title"] : @"";
    NSString *composer = [info[@"composer"] isKindOfClass:[NSString class]] ? info[@"composer"] : @"";
    if (!self.worksPage) self.worksPage = [[RLPWorksViewController alloc] init];
    [self pushDetail:self.worksPage];
    [self.worksPage loadWork:title composer:composer fromNowPlaying:YES];
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

/// 顶栏队列键 = **切换右侧抽屉**（web #bQueue 切 #app.qopen）。
/// 之前原生把它做成"跳到队列页"，那是另一个东西：web 的队列页与右抽屉是两个入口，
/// 抽屉是"边听边看"，队列页是"整理队列"。两者都要有。
- (void)onQueue:(id)sender {
    [self toggleDrawer];
}

- (void)toggleDrawer {
    self.drawerOpen = !self.drawerOpen;
    self.rightDrawer.hidden = !self.drawerOpen;
    if (self.drawerOpen) {
        [self.rightDrawer activate];
        // 打开时浮到最上层（web z-index:20）
        [self.rightDrawer.superview addSubview:self.rightDrawer positioned:NSWindowAbove relativeTo:nil];
    } else {
        [self.rightDrawer deactivate];
    }
}

- (void)onPlaybackTick:(NSNotification *)note {
    if (!self.drawerOpen) return;   // 抽屉没开就不做无用的布局计算
    NSDictionary *u = note.userInfo;
    [self.rightDrawer updatePosition:[u[@"pos"] doubleValue] duration:[u[@"dur"] doubleValue]];
}

- (void)onOpenLyricDrawerNote:(NSNotification *)note { [self openLyricDrawer]; }

/// 底栏歌词键 → 打开抽屉并切到歌词页（web #bLyric 同语义）。
- (void)openLyricDrawer {
    if (!self.drawerOpen) [self toggleDrawer];
    [self.rightDrawer showTab:@"l"];
}

// npPage is a full content-window overlay, not a page inside the sidebar grid.
- (void)onNowPlaying:(id)sender {
    if(self.nowPlayingOverlayVisible)return;
    if(!self.npPage)self.npPage=[RLPNowPlayingViewController new];
    _nowPlayingPage = self.npPage;   // 判据用只读出口（覆盖页是懒创建的）
    NSView *root=self.window.contentView,*v=self.npPage.view;
    self.nowPlayingOverlayVisible=YES;v.translatesAutoresizingMaskIntoConstraints=NO;
    [root addSubview:v positioned:NSWindowAbove relativeTo:nil];
    [NSLayoutConstraint activateConstraints:@[[v.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],[v.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],[v.topAnchor constraintEqualToAnchor:root.topAnchor],[v.bottomAnchor constraintEqualToAnchor:root.bottomAnchor]]];
    [self.npPage activate];
    [self.window makeFirstResponder:v];
}
- (void)onCloseNowPlaying:(NSNotification *)note {
    if(!self.nowPlayingOverlayVisible)return;
    [self.npPage viewDidDisappear];[self.npPage.view removeFromSuperview];self.nowPlayingOverlayVisible=NO;
}


#pragma mark - 主题

- (void)onThemeChanged:(NSNotification *)note {
    RLPTheme *t = [RLPTheme current];
    self.window.backgroundColor = t.bg;
    self.window.appearance = [NSAppearance appearanceNamed:t.isLight ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua];
    self.window.contentView.layer.backgroundColor = t.bg.CGColor;
    // web .top 的背景是 --topbg（半透明 + backdrop-blur），不是 --bg。
    self.topbar.layer.backgroundColor = t.topBg.CGColor;
    if (self.webBackButton) self.webBackButton.layer.backgroundColor = t.hov.CGColor;
    self.topbarHeightConstraint.constant = t.topH;   // apple 60 / classic 52
    self.pageHost.layer.backgroundColor = t.bg.CGColor;
    [self.sidebar applyTheme];
    [self.playbackBar applyTheme];
    [self.rightDrawer applyTheme];
    if(self.npPage.isViewLoaded)[self.npPage applyTheme];
    self.playbackBar.layer.borderColor = t.line.CGColor;
    // 悬浮胶囊条的投影与圆角属于"形状"，不属于"颜色"：主题切换不该把它抹掉。
    self.playbackBar.layer.cornerRadius = 16;
    self.playbackBar.layer.masksToBounds = NO;
    self.playbackBar.layer.shadowColor = NSColor.blackColor.CGColor;
    self.playbackBar.layer.shadowOpacity = t.isLight ? 0.13 : 0.34;
    self.playbackBar.layer.shadowRadius = 19;
    self.playbackBar.layer.shadowOffset = CGSizeMake(0, -6);
    self.pageTitle.textColor = t.text;
    self.pageCount.textColor = t.mut;
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
    // 侧栏「我的歌单」是 /api/sq/list 的动态列表（web #sqList），核心起来后拉一次。
    [self.sidebar reloadSavedQueues];
    [self.playbackBar startPolling];
    // 启动检查更新：延迟 3 秒（先让界面出来），自动模式不打扰——只在有新版本时弹窗
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[RLPUpdateWindowController shared] checkManually:NO];
    });
}

- (void)stopAllActivity {
    [self.playbackBar stopPolling];
    [self.rightDrawer deactivate];
    [self.npPage stopPolling];
}

@end
