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
@property (nonatomic, weak) NSButton *backButton;
@end
@implementation RLPTopbarView
- (void)layout {
    [super layout];
    if (self.backButton) {
        self.backButton.frame = NSMakeRect(14, (self.bounds.size.height - 28) / 2.0, 28, 28);
    }
    if (self.title) {
        [self.title sizeToFit];
        CGRect f = self.title.frame;
        const CGFloat titleX = (self.backButton && !self.backButton.hidden) ? 52 : 20;
        f.origin = CGPointMake(titleX, (self.bounds.size.height - f.size.height) / 2.0);
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
static void * const kRLPRightDrawerKVOContext = (void *)&kRLPRightDrawerKVOContext;

@interface RLPMainWindowController () <NSSearchFieldDelegate>
@property (nonatomic, strong, readwrite) RLPSidebarViewController *sidebar;
@property (nonatomic, strong, readwrite) RLPAlbumsViewController *albums;
@property (nonatomic, strong, readwrite) RLPPlaybackBarView *playbackBar;
@property (nonatomic, strong) NSView *mainHost;
@property (nonatomic, strong) NSView *topbar;
@property (nonatomic, strong) NSView *pageHost;
/// 顶栏高度约束：classic 风格是 52，apple 是 60（web #app grid-template-rows）。
/// 存下来才能在切风格时实时改，而不是只存偏好值不生效。
@property (nonatomic, strong) NSLayoutConstraint *topbarHeightConstraint;
/// 右侧抽屉（web #right）：队列 / 歌词，悬浮毛玻璃卡片。
@property (nonatomic, strong) RLPRightDrawer *rightDrawer;
@property (nonatomic, assign) BOOL drawerOpen;
@property (nonatomic, assign) BOOL updatingDrawerState;
- (void)syncDrawerButtons;
- (void)setDrawerOpenState:(BOOL)open;
- (void)toggleLyricDrawer;
@property (nonatomic, strong) NSSearchField *search;
/// 顶栏搜索的防抖定时器（web #q oninput 的 260ms setTimeout）。
@property (nonatomic, strong) NSTimer *searchDebounce;
/// 当前生效的搜索词（清空/Esc 时按它判断要不要重拉）。
@property (nonatomic, copy) NSString *searchQuery;
/// 上一次真正分派出去的「落点视图 + 搜索词」，用于去重（同一落点同一个词不重复发请求）。
@property (nonatomic, copy) NSString *appliedQuery;
@property (nonatomic, copy) NSString *appliedView;
@property (nonatomic, assign) BOOL applyingSearchNavigation;
@property (nonatomic, strong) NSTextField *pageTitle;   // 顶栏页标题（web #pth）
@property (nonatomic, strong) NSTextField *pageCount;   // 计数（web #cnt）
@property (nonatomic, strong) NSViewController *currentContent;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSViewController *> *pageCache;
/// 详情页的返回栈（存来源 key、真实上层 VC 与是否顶级页标记），返回时逐层退回。
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *rowStack;
@property (nonatomic, strong) RLPNowPlayingViewController *npPage;
@property (nonatomic, strong) RLPWorksViewController *worksPage;
@property (nonatomic, readwrite) BOOL nowPlayingOverlayVisible;
@property (nonatomic,strong) NSButton *webBackButton;
@property (nonatomic,strong) NSButton *topQueueBtn;
@property (nonatomic,strong) NSButton *topScanBtn;
@property (nonatomic,strong) NSButton *topNpBtn;
// 2026-11-17（UI 缺口审计）：扫描没有进度、扫完不刷新。用窄端点 /api/lib/status 轮询。
@property (nonatomic,strong,nullable) NSTimer *scanPollTimer;
@property (nonatomic,assign) BOOL scanWasScanning;
@property (nonatomic, copy, readwrite) NSString *uiMode;
@property (nonatomic, copy) NSString *confirmedUiMode;
@property (nonatomic, strong, readwrite) NSSegmentedControl *modeControl;
@property (nonatomic, assign) NSUInteger modeEpoch;
@property (nonatomic, assign) NSUInteger modeReadSequence;
@property (nonatomic, assign) NSUInteger modeWriteSequence;
@property (nonatomic, assign) NSUInteger modeConfirmedSequence;
@property (nonatomic, assign) NSUInteger modeBaselineEpoch;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *inFlightModeWrites;
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

static NSString * const kRLPMainWindowAutosaveName = @"RLPNativeMainWindow.v2";
static NSString * const kRLPMainWindowFrameDefaultsKey = @"NSWindow Frame RLPNativeMainWindow.v2";

static BOOL RLPRectsAlmostEqual(NSRect a, NSRect b) {
    const CGFloat eps = 1e-3;
    return fabs((double)a.origin.x - (double)b.origin.x) <= eps &&
           fabs((double)a.origin.y - (double)b.origin.y) <= eps &&
           fabs((double)a.size.width - (double)b.size.width) <= eps &&
           fabs((double)a.size.height - (double)b.size.height) <= eps;
}

enum { kRLPMaxClampScreens = 8 };   // 窗口收敛最多考虑的屏幕数（M4 实际 1–2 块，8 是上限兜底）

/// 收集当前所有屏的 visibleFrame（供纯函数判据使用）。
static NSUInteger RLPCurrentVisibleFrames(NSRect *out, NSUInteger cap) {
    if (!out || cap == 0) return 0;
    const NSArray<NSScreen *> *screens = NSScreen.screens;
    const NSUInteger used = MIN(screens.count, cap);
    for (NSUInteger i = 0; i < used; ++i) out[i] = screens[i].visibleFrame;
    return used;
}

/// 设计上的窗口尺寸 / 最小尺寸（用户 2026-11-11 明确满意的 web 版尺寸是 1180×760）。
/// **最小尺寸的真相源只在这里**：小屏收敛时会临时把它压到可用区以内（否则窗口会被 minSize 撑回去），
/// 屏恢复后再从这里重算回 900×600 —— 不能从 win.minSize 反读，读过一次就是被压小的值。
static const NSRect kRLPMainWindowDefaultFrame = { { 0, 0 }, { 1180, 760 } };
static const NSSize kRLPMainWindowMinSize = { 900, 600 };

/// 已落盘的 autosave frame 字符串（AppKit 的键名是 "NSWindow Frame <autosaveName>"）。
static NSString *RLPStoredMainWindowFrameString(void) {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kRLPMainWindowFrameDefaultsKey];
}

/// 把窗口收敛到「它所在的屏」的可见区（就地改 frame），并把 win.minSize 压到可用区以内。
/// 返回 YES 表示 frame 真的变了；已经收敛的 frame 再调一次返回 NO 且不碰窗口（幂等）。
static BOOL RLPConvergeMainWindowFrame(NSWindow *win, BOOL display) {
    if (!win) return NO;
    // 全屏时 frame 由系统接管，这里不动；退出全屏后有专门的一次收敛（onWindowDidExitFullScreen:）。
    if ((win.styleMask & NSWindowStyleMaskFullScreen) != 0) return NO;
    NSRect visibles[kRLPMaxClampScreens];
    const NSUInteger usedScreens = RLPCurrentVisibleFrames(visibles, kRLPMaxClampScreens);
    if (usedScreens == 0) return NO;

    // 跨屏窗口不许被单屏 visibleFrame 压窄（2026-11-18 夜间评审 B1）；
    // 并且只认窗口真正碰到的屏 —— 拔屏后留下的死区 / 屏间空隙不算合法位置，一块都没碰到就落到最近的屏。
    const NSRect usable = RLPWindowUsableScreenRect(win.frame, visibles, (size_t)usedScreens);
    if (NSIsEmptyRect(usable)) return NO;

    // 小屏撑破：可见区比设计最小尺寸还小时（800×500 的扩展屏），只把 frame 收敛小是不够的 ——
    // 窗口自己的 minSize 仍是 900×600，用户一拉、或 AppKit 按 minSize 重排就把窗口撑回去、右侧被切掉。
    // 结论：minSize 与可用区取 min；下次可用区变大时再按设计值重算（不记住被压小的值）。
    win.minSize = NSMakeSize(MIN(kRLPMainWindowMinSize.width, usable.size.width),
                             MIN(kRLPMainWindowMinSize.height, usable.size.height));

    const NSRect current = win.frame;
    const NSRect clamped = RLPClampWindowFrameToVisible(current, usable, win.minSize);
    if (RLPRectsAlmostEqual(clamped, current)) return NO;
    [win setFrame:clamped display:display];
    return YES;
}

/// 把当前 frame 写回 autosave（主窗口固定键名）—— **只在**已落盘记录与当前 frame 不一致
/// （或记录损坏）时写。幂等：第二轮启动记录已经等于收敛结果，不再触碰 defaults；
/// 脏记录（换屏/拔屏/越界）就地清掉。
static BOOL RLPWriteBackMainWindowFrameIfDiffers(NSWindow *win) {
    if (!win) return NO;
    NSString *stored = RLPStoredMainWindowFrameString();
    if (!stored.length) return NO;    // 首启没有记录：没有脏值要清
    NSRect saved = NSZeroRect;
    if (RLPParseSavedWindowFrame(stored.UTF8String, &saved) && RLPRectsAlmostEqual(saved, win.frame)) return NO;
    [win saveFrameUsingName:kRLPMainWindowAutosaveName];
    return YES;
}

/// 屏参数变化（插屏/拔屏/分辨率或主屏变化）与退出全屏后的统一入口：先收敛，再按需写回。
static void RLPConvergeAndWriteBackMainWindowFrame(NSWindow *win) {
    if (!win) return;
    RLPConvergeMainWindowFrame(win, win.isVisible);
    RLPWriteBackMainWindowFrameIfDiffers(win);
}

@implementation RLPMainWindowController

- (instancetype)init {
    RLPTheme *t = [RLPTheme current];
    NSRect frame = kRLPMainWindowDefaultFrame;
    NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                   NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                   NSWindowStyleMaskFullSizeContentView)
          backing:NSBackingStoreBuffered defer:NO];
    win.title = @"RLPlayer";
    win.titlebarAppearsTransparent = YES;
    win.titleVisibility = NSWindowTitleHidden;
    win.backgroundColor = t.bg;
    win.minSize = kRLPMainWindowMinSize;
    win.appearance = [NSAppearance appearanceNamed:t.isLight ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua];
    // 默认尺寸 1180×760（用户 2026-11-11 明确满意的 web 版尺寸）。
    // autosave 键**换名**：旧键 RLPNativeMainWindow 里存着开发期离屏审计写坏的宽度
    // （1257/1361…），沿用旧键会让用户一直看到错尺寸。换键即丢弃那批脏记录，
    // 同时保留"用户之后自己调整的大小仍被记住"这一正常行为。
    NSString *previousSavedFrame = RLPStoredMainWindowFrameString();
    // 2026-11-18 夜间评审 B2 的追加修订：顺序必须是「先收敛、再挂 autosave 名」。
    // 旧顺序先 setFrameAutosaveName:（这一步会按名把 autosave 里的 frame 恢复/注册回来），再覆盖/收敛；
    // 其间 AppKit 看到的是**未收敛**的 frame —— 启动时窗口先出现在旧位置再被拉/缩回来（跳屏），
    // 脏 frame 也被重新注册了一次。新顺序：算启动 frame → 收敛 → 把收敛结果写回同名 defaults
    // → 最后才 setFrameAutosaveName:；挂名时恢复到的就是刚写进去的收敛 frame，不会再跳。
    // 仍然显式回放保存值（不依赖 setFrameAutosaveName: 的恢复时序）：只有确实没有保存值时才居中，
    // 否则会把用户放在副屏/自定义位置的 origin 覆盖成主屏中心（B2）。
    {
        NSRect visibles[kRLPMaxClampScreens];
        const NSUInteger usedScreens = RLPCurrentVisibleFrames(visibles, kRLPMaxClampScreens);
        const RLPWindowStartupFrame start =
            RLPWindowStartupFrameForSavedState(previousSavedFrame.UTF8String,
                                               kRLPMainWindowDefaultFrame,
                                               visibles, (size_t)usedScreens,
                                               kRLPMainWindowMinSize);
        [win setFrame:start.frame display:NO];
        if (start.center) [win center];
    }
    // 换屏/外接显示器/历史拖拽会把 autosave frame 存成超出当前屏幕的尺寸、或落在屏间死区（拔屏后
    // 旧屏坐标还在）：启动时统一收敛到它所在屏的可见区，并把脏记录写回去（记录已相等则不写，幂等）。
    RLPConvergeMainWindowFrame(win, NO);
    RLPWriteBackMainWindowFrameIfDiffers(win);
    const NSRect convergedFrame = win.frame;
    [win setFrameAutosaveName:kRLPMainWindowAutosaveName];
    if (!RLPRectsAlmostEqual(win.frame, convergedFrame)) {
        // 不同系统版本挂名时的恢复时序不同：万一 AppKit 又恢复出另一个值的 frame，再收敛并写回兜底。
        RLPConvergeMainWindowFrame(win, NO);
        RLPWriteBackMainWindowFrameIfDiffers(win);
    }

    self = [super initWithWindow:win];
    if (!self) return nil;

    NSView *root = win.contentView;
    root.wantsLayer = YES;
    root.layer.backgroundColor = t.bg.CGColor;

    _pageCache = [NSMutableDictionary dictionary];
    _rowStack = [NSMutableArray array];
    _uiMode = @"listen";
    _confirmedUiMode = @"listen";
    _inFlightModeWrites = [NSMutableArray array];
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
    _mainHost = [[NSView alloc] initWithFrame:NSZeroRect];
    _mainHost.identifier = @"mainHost";
    _mainHost.wantsLayer = YES;
    _mainHost.layer.backgroundColor = t.bg.CGColor;
    _mainHost.translatesAutoresizingMaskIntoConstraints = NO;
    _topbar = [[RLPTopbarView alloc] initWithFrame:NSZeroRect];
    _topbar.wantsLayer = YES;
    _topbar.layer.backgroundColor = t.bg.CGColor;
    _pageHost = [[NSView alloc] initWithFrame:NSZeroRect];
    _pageHost.wantsLayer = YES;
    _pageHost.layer.backgroundColor = t.bg.CGColor;

    _sidebar.view.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_sidebar.view];
    [root addSubview:_mainHost];

    for (NSView *v in @[_topbar, _pageHost, _playbackBar]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [_mainHost addSubview:v];
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
    // web #q 的 oninput：边输入边搜（260ms 防抖），不能只靠回车。
    // 旧实现只有 target/action ⟹ 必须按回车才触发，与 web 的即时搜索不是同一个东西。
    _search.delegate = self;
    // 打字期间不要 AppKit 再发一次 action（否则会和 260ms 防抖双发）；回车/清除键仍走 onSearch:。
    _search.sendsWholeSearchString = YES;
    [_topbar addSubview:_search];

    self.topQueueBtn = RLPSymbolButton(@"list.bullet", RLPTr(@"播放队列"), self, @selector(onQueue:));
    self.topQueueBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_topbar addSubview:self.topQueueBtn];

    // 顶栏「刷新曲库」（web #bScan：重新扫描音乐库；用户实测「没做刷新曲库的按钮」）。
    self.topScanBtn = RLPSymbolButton(@"arrow.clockwise", RLPTr(@"重新扫描音乐库"), self, @selector(onScanLibrary:));
    self.topScanBtn.translatesAutoresizingMaskIntoConstraints = NO;
    self.topScanBtn.identifier = @"top.scan";
    [_topbar addSubview:self.topScanBtn];

    self.topNpBtn = RLPSymbolButton(@"play.rectangle", RLPTr(@"正在播放"), self, @selector(onNowPlaying:));
    self.topNpBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_topbar addSubview:self.topNpBtn];

    _modeControl = [NSSegmentedControl segmentedControlWithLabels:@[RLPTr(@"聆听"), RLPTr(@"专业")]
                                                    trackingMode:NSSegmentSwitchTrackingSelectOne
                                                          target:self
                                                          action:@selector(onModeSegmentChanged:)];
    _modeControl.identifier = @"top.mode";
    _modeControl.selectedSegment = 0;
    _modeControl.translatesAutoresizingMaskIntoConstraints = NO;
    [_topbar addSubview:_modeControl];

    NSLayoutConstraint *searchPrefW = [_search.widthAnchor constraintEqualToConstant:300];
    searchPrefW.priority = NSLayoutPriorityDefaultHigh;

    [NSLayoutConstraint activateConstraints:@[
        [_sidebar.view.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_sidebar.view.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_sidebar.view.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [_sidebar.view.widthAnchor constraintEqualToConstant:kSidebarWidth],

        // 主内容区容器：严格对齐侧边栏右缘到窗口右缘（不包含侧边栏）。
        [_mainHost.leadingAnchor constraintEqualToAnchor:_sidebar.view.trailingAnchor],
        [_mainHost.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_mainHost.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_mainHost.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],

        [_topbar.leadingAnchor constraintEqualToAnchor:_mainHost.leadingAnchor],
        [_topbar.trailingAnchor constraintEqualToAnchor:_mainHost.trailingAnchor],
        [_topbar.topAnchor constraintEqualToAnchor:_mainHost.topAnchor],
        // 占位：真正的约束在下面单独建并存起来（切 classic 时要改它）


        [_search.leadingAnchor constraintEqualToAnchor:_topbar.leadingAnchor constant:210],
        [_search.centerYAnchor constraintEqualToAnchor:_topbar.centerYAnchor],
        searchPrefW,
        [_search.widthAnchor constraintGreaterThanOrEqualToConstant:140],
        [_search.widthAnchor constraintLessThanOrEqualToConstant:300],
        [_search.trailingAnchor constraintLessThanOrEqualToAnchor:_modeControl.leadingAnchor constant:-12],

        [_modeControl.trailingAnchor constraintEqualToAnchor:self.topScanBtn.leadingAnchor constant:-12],
        [_modeControl.centerYAnchor constraintEqualToAnchor:_topbar.centerYAnchor],

        [self.topNpBtn.trailingAnchor constraintEqualToAnchor:_topbar.trailingAnchor constant:-16],
        [self.topNpBtn.centerYAnchor constraintEqualToAnchor:_topbar.centerYAnchor],
        [self.topNpBtn.widthAnchor constraintEqualToConstant:28],
        [self.topQueueBtn.trailingAnchor constraintEqualToAnchor:self.topNpBtn.leadingAnchor constant:-10],
        [self.topQueueBtn.centerYAnchor constraintEqualToAnchor:_topbar.centerYAnchor],
        [self.topQueueBtn.widthAnchor constraintEqualToConstant:28],
        [self.topScanBtn.trailingAnchor constraintEqualToAnchor:self.topQueueBtn.leadingAnchor constant:-10],
        [self.topScanBtn.centerYAnchor constraintEqualToAnchor:_topbar.centerYAnchor],
        [self.topScanBtn.widthAnchor constraintEqualToConstant:28],

        // 悬浮播放条：放在 _mainHost 内并相对主内容区左右边界居中（最大宽 1120 / 底 14 / 高 66）。
        // 宽度用 DefaultHigh 等式吃满主内容区可用宽（width = _mainHost - 48），再用 required 的 ≤1120 与 ≥24pt 边距兜底；
        // 右侧抽屉悬浮在 root 上、不改变 _mainHost 宽度，窗口缩放与抽屉开合时播放条始终在主内容区居中。
        [_playbackBar.centerXAnchor constraintEqualToAnchor:_mainHost.centerXAnchor],
        [_playbackBar.bottomAnchor constraintEqualToAnchor:_mainHost.bottomAnchor constant:-14],
        [_playbackBar.heightAnchor constraintEqualToConstant:kPlaybackHeight],
        [_playbackBar.leadingAnchor constraintGreaterThanOrEqualToAnchor:_mainHost.leadingAnchor constant:24],
        [_playbackBar.trailingAnchor constraintLessThanOrEqualToAnchor:_mainHost.trailingAnchor constant:-24],

        [_pageHost.leadingAnchor constraintEqualToAnchor:_mainHost.leadingAnchor],
        [_pageHost.trailingAnchor constraintEqualToAnchor:_mainHost.trailingAnchor],
        [_pageHost.topAnchor constraintEqualToAnchor:_topbar.bottomAnchor],
        [_pageHost.bottomAnchor constraintEqualToAnchor:_playbackBar.topAnchor constant:-14],
    ]];

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
    [_rightDrawer addObserver:self forKeyPath:@"tab" options:0 context:kRLPRightDrawerKVOContext];
    [_rightDrawer addObserver:self forKeyPath:@"hidden" options:0 context:kRLPRightDrawerKVOContext];

    _topbarHeightConstraint = [_topbar.heightAnchor constraintEqualToConstant:[RLPTheme current].topH];
    _topbarHeightConstraint.active = YES;

    NSLayoutConstraint *fill = [_playbackBar.widthAnchor constraintEqualToAnchor:_mainHost.widthAnchor constant:-48];
    fill.priority = NSLayoutPriorityDefaultHigh;   // 750：窄窗口按主内容区可用宽度铺满
    NSLayoutConstraint *cap = [_playbackBar.widthAnchor constraintLessThanOrEqualToConstant:1120];
    [NSLayoutConstraint activateConstraints:@[fill, cap]];

    __weak __typeof__(self) weakSelf = self;
    _sidebar.onSelect = ^(NSInteger row) { [weakSelf showContentForRow:row]; };
    _albums.onPlayAlbum = ^(NSString *key) {
        RLPPlayAlbum(key, 0);
    };

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onThemeChanged:)
                                                 name:RLPThemeDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onLanguageChanged:)
                                                 name:RLPLanguageDidChangeNotification
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
    // 设置页「打开专业工作台」→ 切专业模式并路由到 station
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onSwitchToProWorkbench:)
                                                 name:@"RLPSwitchToProWorkbenchNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onFocusSearch:)
                                                 name:@"RLPFocusSearchNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onScreenParametersChanged:)
                                                 name:NSApplicationDidChangeScreenParametersNotification object:nil];
    // 全屏时 onScreenParametersChanged: 会早退（frame 由系统接管）；退出全屏 AppKit 才把 pre-fullscreen frame
    // 还回来，若那块显示器在期间被拔掉，还回来的 frame 落在已不存在的坐标（拔屏死区），没有别的路径再夹它。
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onWindowDidExitFullScreen:)
                                                 name:NSWindowDidExitFullScreenNotification object:self.window];

    [_sidebar selectRow:0];
    [self showContentForRow:0];
    [self syncDrawerButtons];
    return self;
}

- (void)dealloc {
    [_rightDrawer removeObserver:self forKeyPath:@"tab" context:kRLPRightDrawerKVOContext];
    [_rightDrawer removeObserver:self forKeyPath:@"hidden" context:kRLPRightDrawerKVOContext];
    [_searchDebounce invalidate];
    [self stopScanPolling];   // 扫描轮询必须停表，否则测试进程会延迟退出
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

- (NSString *)cacheKeyForRouteKey:(NSString *)key {
    if ([key isEqualToString:@"station"]) {
        return [self.uiMode isEqualToString:@"pro"] ? @"station:pro" : @"station:listen";
    }
    return key;
}

- (NSViewController *)stationViewControllerForCurrentMode {
    NSString *ck = [self cacheKeyForRouteKey:@"station"];
    NSViewController *vc = self.pageCache[ck];
    if (!vc) {
        vc = [self.uiMode isEqualToString:@"pro"]
            ? (NSViewController *)[[RLPWorkbenchViewController alloc] init]
            : (NSViewController *)[[RLPQuickStartViewController alloc] init];
        self.pageCache[ck] = vc;
    }
    return vc;
}

/// 行号 → 符号 key → 页面。缓存一律按 key 存，不按行号 ——
/// 行号会随导航项顺序变化而错位（web 也是按 data-v 的 key 路由）。
- (void)showContentForRow:(NSInteger)row {
    NSString *key = [self.sidebar keyForRow:row];
    [self showContentForKey:key.length ? key : @"albums"];
}

- (void)showContentForKey:(NSString *)key {
    [self cancelSearchDebounce];
    if (!self.applyingSearchNavigation) {
        const BOOL hadSearch = self.search.stringValue.length > 0 ||
                               self.searchQuery.length > 0 ||
                               self.appliedQuery.length > 0 ||
                               self.appliedView.length > 0;
        if (hadSearch) {
            self.searchQuery = @"";
            self.appliedQuery = @"";
            self.appliedView = @"";
            if (self.search.stringValue.length) self.search.stringValue = @"";
            for (NSString *k in @[@"albums", @"artists", @"tracks"]) {
                id p = [k isEqualToString:@"albums"] ? self.albums : self.pageCache[k];
                if (p && [p respondsToSelector:@selector(searchWithQuery:)]) {
                    [p searchWithQuery:@""];
                }
            }
        }
    }
    if (!key.length) key = @"albums";
    NSString *cacheKey = [self cacheKeyForRouteKey:key];
    NSViewController *vc = self.pageCache[cacheKey];
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
        else if ([key isEqualToString:@"station"]) {
            vc = [self.uiMode isEqualToString:@"pro"]
                ? (NSViewController *)[[RLPWorkbenchViewController alloc] init]
                : (NSViewController *)[[RLPQuickStartViewController alloc] init];
        }
        else if ([key isEqualToString:@"settings"]) {
            RLPSettingsViewController *sv = [[RLPSettingsViewController alloc] init];
            [sv applyUiMode:self.uiMode];
            vc = sv;
        }
        else vc = self.albums;
        self.pageCache[cacheKey] = vc;
    }
    if (vc == self.currentContent) {
        // 同页再次点选：清详情返回栈、重设标题并按需重新上报计数
        [self.rowStack removeAllObjects];
        [self syncTopbarTitle];
        if ([vc respondsToSelector:@selector(activate)]) [(id)vc activate];
        return;
    }
    [self.rowStack removeAllObjects];
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
        ((RLPTopbarView *)self.topbar).backButton = b;
        [self.topbar addSubview:b];
    }
    self.webBackButton.frame=NSMakeRect(14, (self.topbar.bounds.size.height-28)/2.0, 28, 28);
    self.webBackButton.hidden=self.rowStack.count==0;
    NSString *title = nil;
    if ([self.currentContent isKindOfClass:[RLPWorkbenchViewController class]])
        title = @"数字音乐台";
    else if ([self.currentContent respondsToSelector:@selector(pageTitle)])
        title = [(id)self.currentContent pageTitle];
    const BOOL dataTitle = [self.currentContent isKindOfClass:RLPAlbumDetailViewController.class] ||
                           [self.currentContent isKindOfClass:RLPArtistDetailViewController.class] ||
                           [self.currentContent isKindOfClass:RLPPlaylistsViewController.class];
    self.pageTitle.stringValue = title.length ? (dataTitle ? title : RLPTr(title)) : @"";
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
        // 2026-11-17：请求本身失败时不要报「开始扫描」，更不要开始轮询（否则首轮就会
        // 误报「扫描完成」——119 的边角问题，这里收紧）。
        if (!json || ![json[@"ok"] boolValue]) {
            RLPToast(RLPTr(@"扫描请求失败"));
            return;
        }
        BOOL started = [json[@"started"] respondsToSelector:@selector(boolValue)] ? [json[@"started"] boolValue] : YES;
        RLPToast(started ? RLPTr(@"开始扫描音乐库") : RLPTr(@"扫描已在进行中"));
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPLibraryChangedNotification" object:nil];
        [self_ startScanPolling];
        // 曲目/专辑/艺术家页都重拉一次（与 web libChanged 同口径）
        [self_ reloadVisibleLibraryPages];
    }];
}

- (void)startScanPolling {
    if (self.scanPollTimer) return;
    self.scanWasScanning = YES;
    __weak __typeof__(self) weakSelf = self;
    NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *timer) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) { [timer invalidate]; return; }
        [self_ pollScanStatus];
    }];
    self.scanPollTimer = t;
    [self pollScanStatus];   // 立刻出一次「扫描中 X/Y」
}

- (void)stopScanPolling {
    [self.scanPollTimer invalidate];
    self.scanPollTimer = nil;
    self.scanWasScanning = NO;
}

- (void)pollScanStatus {
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/lib/status" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        const BOOL ok = [json[@"ok"] respondsToSelector:@selector(boolValue)] ? [json[@"ok"] boolValue] : NO;
        if (!ok) { [self_ stopScanPolling]; return; }
        const BOOL scanning = [json[@"scanning"] respondsToSelector:@selector(boolValue)] ? [json[@"scanning"] boolValue] : NO;
        if (scanning) {
            NSInteger scanned = [json[@"scanned"] respondsToSelector:@selector(integerValue)] ? [json[@"scanned"] integerValue] : 0;
            NSInteger total = [json[@"total"] respondsToSelector:@selector(integerValue)] ? [json[@"total"] integerValue] : 0;
            self_.scanWasScanning = YES;
            NSString *text = [NSString stringWithFormat:RLPTr(@"扫描中 %ld/%ld"), (long)scanned, (long)total];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPPageCountNotification" object:text];
        } else if (self_.scanWasScanning) {
            // 扫描结束：停表、提示、刷新所有已缓存曲库页。
            [self_ stopScanPolling];
            RLPToast(RLPTr(@"扫描完成"));
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPLibraryChangedNotification" object:nil];
            [self_ reloadVisibleLibraryPages];
        }
    }];
}

- (void)reloadVisibleLibraryPages {
    for (NSString *key in @[@"albums", @"artists", @"tracks", @"folders"]) {
        NSViewController *vc = self.pageCache[key];
        if (!vc) continue;
        if ([vc respondsToSelector:@selector(reloadData)]) [(id)vc reloadData];
        else if ([vc respondsToSelector:@selector(reload)]) [(id)vc reload];   // 专辑页的入口叫 reload
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
    if (!detail || detail == self.currentContent) return;
    if (self.currentContent) {
        // 记住"从哪一页进来的"：顶级页记 key + root=YES，嵌套详情页保留真实上层 VC（root=NO），
        // 返回时逐层退回，不跳层也不依赖侧栏当前高亮推算。
        NSString *k = self.sidebar.selectedKey;
        NSString *key = k.length ? k : @"albums";
        const BOOL isRoot = (self.pageCache[[self cacheKeyForRouteKey:key]] == self.currentContent);
        [self.rowStack addObject:@{
            @"key": key,
            @"vc": self.currentContent,
            @"root": @(isRoot),
        }];
    }
    [self swapContentTo:detail];
}

- (void)popDetail {
    [self cancelSearchDebounce];
    NSDictionary *entry = self.rowStack.lastObject;
    if (![entry isKindOfClass:[NSDictionary class]]) return;
    [self.rowStack removeLastObject];
    NSViewController *vc = entry[@"vc"];
    NSString *backKey = [entry[@"key"] isKindOfClass:[NSString class]] ? entry[@"key"] : @"";
    const BOOL isRoot = [entry[@"root"] boolValue];
    if (isRoot && [backKey isEqualToString:@"station"]) {
        // 若在详情页期间切换了聆听/专业模式，返回 station 时落到当前模式对应的主页 VC。
        vc = [self stationViewControllerForCurrentMode];
        vc.view.identifier = RLPPageIdentifier(@"station");
    }
    if (!vc && backKey.length) vc = self.pageCache[[self cacheKeyForRouteKey:backKey]];
    if (!vc) {
        [self syncTopbarTitle];
        return;
    }
    if (isRoot && backKey.length && ![self.sidebar.selectedKey isEqualToString:backKey]) {
        [self.sidebar selectKey:backKey];
        return;
    }
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

#pragma mark - 顶栏搜索（web #q：oninput 260ms 防抖 + 按当前视图分派）

/// 当前视图 key（web S.view）。详情页/覆盖页不是库列表页本身（web 里是 album/artist/works），
/// 所以用 currentContent 与 pageCache 的对应关系判定，而不是只看左导航选中项。
- (NSString *)currentViewKey {
    NSString *key = self.sidebar.selectedKey ?: @"albums";
    NSViewController *page = self.pageCache[[self cacheKeyForRouteKey:key]];
    if (page && page != self.currentContent) return @"detail";
    return key;
}

/// web dispatchSearchQuery 的原生同构：
///   专辑 / 艺术家 / 曲目 = **页内过滤**（不跳页）；其余视图（文件夹/流媒体/队列/最近/
///   最爱/歌单/设置，以及详情页）才切到曲目页做全局搜索。
/// 旧实现无条件切曲目页 ⟹ 用户停在专辑页打字就被拽走，页内过滤根本用不上。
- (void)applySearchQuery:(NSString *)query {
    NSString *q = [query stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    NSString *view = [self currentViewKey];
    const BOOL libraryPage = [view isEqualToString:@"albums"] ||
                              [view isEqualToString:@"artists"] ||
                              [view isEqualToString:@"tracks"];
    NSString *target = libraryPage ? view : @"tracks";
    // 已经在目标页 + 同一个词才去重：打字停顿后 AppKit 仍可能再发一次 action，
    // 回车也会落到这里；web 用 260ms 定时器 + 分派，没有双发。
    // 注意必须同时看「当前视图」——在设置页输入时 target 也是 tracks，但这时还得切页。
    if (q.length && [self.appliedQuery isEqualToString:q] &&
        [self.appliedView isEqualToString:target] && [view isEqualToString:target])
        return;
    self.searchQuery = q;
    self.appliedQuery = q;
    self.appliedView = target;
    if ([target isEqualToString:@"albums"]) { [self.albums searchWithQuery:q]; return; }
    if (libraryPage) {
        id page = self.pageCache[target];
        if ([page respondsToSelector:@selector(searchWithQuery:)]) [page searchWithQuery:q];
        return;
    }
    // 其余视图：整页搜索落点是曲目页（web 的 setView('tracks') + loadTracks(q)）。
    // 必须走 sidebar 选中而不是直接 swap 内容：否则内容换了、左导航高亮还停在上一个页。
    self.applyingSearchNavigation = YES;
    if (![self.sidebar selectKey:@"tracks"]) [self showContentForKey:@"tracks"];
    self.applyingSearchNavigation = NO;
    id tracks = self.pageCache[@"tracks"];
    if ([tracks respondsToSelector:@selector(searchWithQuery:)]) [tracks searchWithQuery:q];
}

/// web clearSearchQuery：清空搜索框并按**当前视图**重拉整库。
/// 专辑/艺术家/曲目各自重拉；其余视图回到专辑页（与 web else 分支的 loadAlbums('') 同口径）。
- (void)clearSearchQuery {
    [self.searchDebounce invalidate];
    self.searchDebounce = nil;
    self.searchQuery = @"";
    self.appliedQuery = @"";
    self.appliedView = @"";
    if (self.search.stringValue.length) self.search.stringValue = @"";
    NSString *view = [self currentViewKey];
    if ([view isEqualToString:@"albums"]) {
        [self.albums searchWithQuery:@""];
        return;
    }
    for (NSString *key in @[@"artists", @"tracks"]) {
        if (![view isEqualToString:key]) continue;
        id page = self.pageCache[key];
        if ([page respondsToSelector:@selector(searchWithQuery:)]) [page searchWithQuery:@""];
        return;
    }
    if (![self.sidebar selectKey:@"albums"]) [self showContentForKey:@"albums"];
    [self.albums searchWithQuery:@""];
}

- (void)cancelSearchDebounce {
    [self.searchDebounce invalidate];
    self.searchDebounce = nil;
}

- (void)onFocusSearch:(NSNotification *)note {
    (void)note;
    if (!self.search || !self.window) return;
    [self.window makeFirstResponder:self.search];
    [self.search selectText:nil];
}

/// web #q.oninput：每次输入重置 260ms 防抖，到点按当前视图分派（不需要回车）。
- (void)controlTextDidChange:(NSNotification *)note {
    if (note.object && note.object != self.search) return;
    [self.searchDebounce invalidate];
    __weak __typeof__(self) weakSelf = self;
    self.searchDebounce = [NSTimer scheduledTimerWithTimeInterval:0.26 repeats:NO block:^(NSTimer *tm) {
        (void)tm;
        __typeof__(self) s = weakSelf;
        if (!s) return;
        s.searchDebounce = nil;
        NSString *q = [s.search.stringValue stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
        if (q.length) [s applySearchQuery:q];
        else [s clearSearchQuery];
    }];
}

/// web #q.onkeydown 的 Escape 分支：清空并按当前视图重拉（这里吞掉事件，避免系统 beep）。
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
    (void)textView;
    if (control != self.search) return NO;
    if (commandSelector == @selector(cancelOperation:)) {
        [self clearSearchQuery];
        return YES;
    }
    return NO;   // 回车走 target/action（onSearch:），其它按键原样放行
}

/// 回车（action）与搜索框自带清除键：立即分派，不等防抖（web 的清空键也是立刻 clearSearchQuery）。
- (void)onSearch:(id)sender {
    (void)sender;
    [self.searchDebounce invalidate];
    self.searchDebounce = nil;
    NSString *q = [self.search.stringValue stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    if (!q.length) { [self clearSearchQuery]; return; }
    [self applySearchQuery:q];
}

- (void)observeValueForKeyPath:(nullable NSString *)keyPath
                      ofObject:(nullable id)object
                        change:(nullable NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(nullable void *)context {
    (void)change;
    if (context != kRLPRightDrawerKVOContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    if (object != self.rightDrawer) return;
    if ([keyPath isEqualToString:@"hidden"]) {
        if (!self.updatingDrawerState) {
            const BOOL open = !self.rightDrawer.hidden;
            if (self.drawerOpen != open) {
                [self setDrawerOpenState:open];
                return;
            }
        }
        [self syncDrawerButtons];
        return;
    }
    if ([keyPath isEqualToString:@"tab"]) {
        if (!self.updatingDrawerState) [self syncDrawerButtons];
        return;
    }
}

/// 统一同步抽屉状态与触发按钮：以 rightDrawer.hidden / tab 为准同步 drawerOpen、顶栏队列键与底栏键。
- (void)syncDrawerButtons {
    const BOOL open = !self.rightDrawer.hidden;
    self.drawerOpen = open;
    NSString *tab = [self.rightDrawer.tab isEqualToString:@"l"] ? @"l" : @"q";
    RLPTheme *t = [RLPTheme current];
    const BOOL queueActive = open && ![tab isEqualToString:@"l"];
    self.topQueueBtn.contentTintColor = queueActive ? t.accent : t.text;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPRightDrawerStateDidChangeNotification"
                                                        object:self.playbackBar
                                                      userInfo:@{
                                                          @"open": @(open),
                                                          @"tab": tab,
                                                          @"hidden": @(self.rightDrawer.hidden),
                                                      }];
}

- (void)setDrawerOpenState:(BOOL)open {
    const BOOL wasUpdating = self.updatingDrawerState;
    self.updatingDrawerState = YES;
    self.drawerOpen = open;
    self.rightDrawer.hidden = !open;
    if (open) {
        [self.rightDrawer activate];
        // 打开时浮到最上层（web z-index:20）
        [self.rightDrawer.superview addSubview:self.rightDrawer positioned:NSWindowAbove relativeTo:nil];
    } else {
        [self.rightDrawer deactivate];
    }
    self.updatingDrawerState = wasUpdating;
    [self syncDrawerButtons];
}

/// 顶栏队列键 = **切换右侧抽屉**（web #bQueue 切 #app.qopen）。
/// 打开但停在歌词页签时先切回队列页签，已停在队列页签时再次点击关闭。
- (void)onQueue:(id)sender {
    (void)sender;
    const BOOL open = !self.rightDrawer.hidden;
    NSString *tab = self.rightDrawer.tab ?: @"q";
    if (!open) {
        if (![tab isEqualToString:@"q"]) {
            const BOOL wasUpdating = self.updatingDrawerState;
            self.updatingDrawerState = YES;
            [self.rightDrawer showTab:@"q"];
            self.drawerOpen = YES;
            self.rightDrawer.hidden = NO;
            [self.rightDrawer activate];
            [self.rightDrawer.superview addSubview:self.rightDrawer positioned:NSWindowAbove relativeTo:nil];
            self.updatingDrawerState = wasUpdating;
            [self syncDrawerButtons];
        } else {
            [self setDrawerOpenState:YES];
        }
        return;
    }
    if (![tab isEqualToString:@"q"]) {
        [self.rightDrawer showTab:@"q"];
        [self syncDrawerButtons];
        return;
    }
    [self setDrawerOpenState:NO];
}

- (void)toggleDrawer {
    [self setDrawerOpenState:self.rightDrawer.hidden];
}

- (void)onPlaybackTick:(NSNotification *)note {
    if (!self.drawerOpen || self.rightDrawer.hidden) return;   // 抽屉没开就不做无用的布局计算
    NSDictionary *u = note.userInfo;
    [self.rightDrawer updatePosition:[u[@"pos"] doubleValue] duration:[u[@"dur"] doubleValue]];
}

- (void)onOpenLyricDrawerNote:(NSNotification *)note {
    (void)note;
    [self toggleLyricDrawer];
}

/// 底栏 pb.lyric / 快捷键 l 入口：
/// - 抽屉未开时单击打开并切到歌词页签；
/// - 已打开且在队列页签时切到歌词页签，不误关队列抽屉；
/// - 已打开且停在歌词页签时再次单击关闭抽屉，同步 hidden 与 drawerOpen。
- (void)toggleLyricDrawer {
    const BOOL open = !self.rightDrawer.hidden;
    NSString *tab = self.rightDrawer.tab ?: @"q";
    if (!open) {
        if (![tab isEqualToString:@"l"]) {
            const BOOL wasUpdating = self.updatingDrawerState;
            self.updatingDrawerState = YES;
            self.drawerOpen = YES;
            self.rightDrawer.hidden = NO;
            [self.rightDrawer activate];
            [self.rightDrawer.superview addSubview:self.rightDrawer positioned:NSWindowAbove relativeTo:nil];
            [self.rightDrawer showTab:@"l"];
            self.updatingDrawerState = wasUpdating;
            [self syncDrawerButtons];
        } else {
            [self setDrawerOpenState:YES];
        }
        return;
    }
    if (![tab isEqualToString:@"l"]) {
        [self.rightDrawer showTab:@"l"];
        [self syncDrawerButtons];
        return;
    }
    [self setDrawerOpenState:NO];
}

/// 底栏歌词键（web #bLyric）→ 单击打开、再次单击关闭，与 hidden / drawerOpen 同步。
- (void)openLyricDrawer {
    [self toggleLyricDrawer];
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
    if (self.webBackButton) {
        self.webBackButton.layer.backgroundColor = t.hov.CGColor;
        self.webBackButton.contentTintColor = t.text;
    }
    for (NSButton *b in @[self.topQueueBtn, self.topScanBtn, self.topNpBtn]) b.contentTintColor = t.text;
    self.topbarHeightConstraint.constant = t.topH;   // apple 60 / classic 52
    self.mainHost.layer.backgroundColor = t.bg.CGColor;
    self.pageHost.layer.backgroundColor = t.bg.CGColor;
    [self.sidebar applyTheme];
    [self.playbackBar applyTheme];
    [self.rightDrawer applyTheme];
    [self syncDrawerButtons];
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

#pragma mark - 语言实时切换

- (nullable NSString *)zhTitleForRouteCacheKey:(NSString *)cacheKey {
    static NSDictionary<NSString *, NSString *> *titles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        titles = @{
            @"albums":         @"专辑",
            @"artists":        @"艺术家",
            @"tracks":         @"曲目",
            @"folders":        @"文件夹",
            @"streaming":      @"流媒体",
            @"queue":          @"播放队列",
            @"recent":         @"最近播放",
            @"favorites":      @"我的最爱",
            @"playlists":      @"歌单",
            @"station:listen": @"聆听室",
            @"station:pro":    @"数字音乐台",
            @"settings":       @"设置",
        };
    });
    return titles[cacheKey];
}

- (void)onLanguageChanged:(NSNotification *)note {
    (void)note;
    self.search.placeholderString = RLPTr(@"搜索曲目 / 专辑 / 艺术家");
    self.topQueueBtn.toolTip = RLPTr(@"播放队列");
    self.topScanBtn.toolTip = RLPTr(@"重新扫描音乐库");
    self.topNpBtn.toolTip = RLPTr(@"正在播放");
    if (self.webBackButton) self.webBackButton.toolTip = RLPTr(@"返回上一页");
    [self.modeControl setLabel:RLPTr(@"聆听") forSegment:0];
    [self.modeControl setLabel:RLPTr(@"专业") forSegment:1];

    [self.sidebar applyLanguage];
    [self.playbackBar applyLanguage];
    [self.rightDrawer applyLanguage];
    if (self.npPage.isViewLoaded && [self.npPage respondsToSelector:@selector(applyLanguage)]) {
        [(id)self.npPage applyLanguage];
    }
    NSMutableOrderedSet<NSViewController *> *languagePages = [NSMutableOrderedSet orderedSetWithArray:self.pageCache.allValues];
    for (NSDictionary *entry in self.rowStack) {
        NSViewController *vc = entry[@"vc"];
        if ([vc isKindOfClass:NSViewController.class]) [languagePages addObject:vc];
    }
    if (self.worksPage) [languagePages addObject:self.worksPage];
    if (self.currentContent) [languagePages addObject:self.currentContent];
    for (NSViewController *vc in languagePages) {
        if ([vc respondsToSelector:@selector(applyLanguage)]) [(id)vc applyLanguage];
    }

    // 顶栏标题：仅翻译已知静态路由/页面标题，绝不误翻译用户专辑名/艺术家名/歌单名
    NSString *resolvedTitle = nil;
    if ([self.currentContent isKindOfClass:[RLPWorkbenchViewController class]]) {
        resolvedTitle = RLPTr(@"数字音乐台");
    } else if (self.currentContent == self.npPage) {
        resolvedTitle = RLPTr(@"正在播放");
    } else if ([self.currentContent isKindOfClass:[RLPWorksViewController class]]) {
        resolvedTitle = RLPTr(@"古典作品 · 演绎版本");
    } else if ([self.currentContent isKindOfClass:[RLPPlaylistsViewController class]]) {
        resolvedTitle = [(id)self.currentContent pageTitle];
    } else {
        for (NSString *ck in self.pageCache) {
            if (self.pageCache[ck] == self.currentContent) {
                NSString *zh = [self zhTitleForRouteCacheKey:ck];
                if (zh.length) resolvedTitle = RLPTr(zh);
                break;
            }
        }
    }
    if (resolvedTitle.length) {
        self.pageTitle.stringValue = resolvedTitle;
        [self.pageTitle sizeToFit];
        [(RLPTopbarView *)self.topbar setNeedsLayout:YES];
    }
}

#pragma mark - 聆听 / 专业双模式

- (void)onModeSegmentChanged:(id)sender {
    (void)sender;
    NSString *mode = (self.modeControl.selectedSegment == 1) ? @"pro" : @"listen";
    [self setUiMode:mode persist:YES];
}

- (void)onSwitchToProWorkbench:(NSNotification *)note {
    (void)note;
    const BOOL wasPro = [self.uiMode isEqualToString:@"pro"];
    [self setUiMode:@"pro" persist:YES];
    if (wasPro && ![self.sidebar.selectedKey isEqualToString:@"station"]) {
        if (![self.sidebar selectKey:@"station"]) [self showContentForKey:@"station"];
    }
}

- (void)setUiMode:(NSString *)mode persist:(BOOL)persist {
    [self applyUiMode:mode persist:persist navigateToStation:YES];
}

- (void)applyUiModeDisplay:(NSString *)next navigateToStation:(BOOL)navigate {
    const BOOL changed = ![self.uiMode isEqualToString:next];
    self.uiMode = next;
    self.modeControl.selectedSegment = [next isEqualToString:@"pro"] ? 1 : 0;
    self.sidebar.uiMode = next;
    NSViewController *sv = self.pageCache[@"settings"];
    if ([sv respondsToSelector:@selector(applyUiMode:)]) {
        [(id)sv applyUiMode:next];
    }
    if (changed) {
        if (navigate) {
            // 模式是一项导航事务：同一帧同步侧栏、标题与模式首页，
            // 不把旧模式详情留在栈里，也不触碰播放条或核心播放状态。
            [self.rowStack removeAllObjects];
            if (self.nowPlayingOverlayVisible) [self onCloseNowPlaying:nil];
            if (![self.sidebar selectKey:@"station"]) [self showContentForKey:@"station"];
        } else if (self.rowStack.count == 0 &&
                   [self.sidebar.selectedKey isEqualToString:@"station"]) {
            // 初始化回读若用户正好停在 station，刷新为对应模式的 station 页；
            // 若用户已打开其他页面或详情页，绝不强行清栈或跳回 station。
            [self showContentForKey:@"station"];
        }
    }
}

- (void)applyUiMode:(NSString *)mode persist:(BOOL)persist navigateToStation:(BOOL)navigate {
    [self cancelSearchDebounce];
    NSString *next = [mode isEqualToString:@"pro"] ? @"pro" : @"listen";
    ++self.modeEpoch;
    ++self.modeReadSequence;
    if (persist && [RLPCoreClient shared].started) {
        const NSUInteger writeSeq = ++self.modeWriteSequence;
        const NSUInteger baseline = self.modeBaselineEpoch;
        NSNumber *writeToken = @(writeSeq);
        [self.inFlightModeWrites addObject:writeToken];
        [self applyUiModeDisplay:next navigateToStation:navigate];
        NSString *body = [NSString stringWithFormat:@"uimode=%@", RLPEnc(next)];
        __weak __typeof__(self) weakSelf = self;
        [[RLPCoreClient shared] postJSON:@"/api/settings" body:body completion:^(NSDictionary * _Nullable json) {
            __typeof__(self) self_ = weakSelf;
            if (!self_) return;
            if (baseline != self_->_modeBaselineEpoch ||
                ![self_->_inFlightModeWrites containsObject:writeToken]) {
                return;
            }
            [self_->_inFlightModeWrites removeObject:writeToken];
            ++self_->_modeEpoch;
            ++self_->_modeReadSequence;
            id okVal = [json isKindOfClass:[NSDictionary class]] ? json[@"ok"] : nil;
            const BOOL ok = [json isKindOfClass:[NSDictionary class]] &&
                            (!okVal || ([okVal respondsToSelector:@selector(boolValue)] && [okVal boolValue]));
            if (ok) {
                if (writeSeq > self_->_modeConfirmedSequence) {
                    self_.confirmedUiMode = next;
                    self_->_modeConfirmedSequence = writeSeq;
                    if (self_->_inFlightModeWrites.count == 0 &&
                        ![self_.uiMode isEqualToString:self_.confirmedUiMode]) {
                        [self_ applyUiModeDisplay:self_.confirmedUiMode navigateToStation:navigate];
                    }
                }
                return;
            }
            if (writeSeq != self_->_modeWriteSequence) return;
            RLPToast(RLPTr(@"保存模式设置失败"));
            NSString *fallback = self_.confirmedUiMode ?: @"listen";
            [self_ applyUiModeDisplay:fallback navigateToStation:navigate];
        }];
        return;
    }
    self.confirmedUiMode = next;
    ++self.modeBaselineEpoch;
    self.modeConfirmedSequence = self.modeWriteSequence;
    [self.inFlightModeWrites removeAllObjects];
    [self applyUiModeDisplay:next navigateToStation:navigate];
}

- (void)reloadUiModePreference {
    if (![RLPCoreClient shared].started) return;
    const NSUInteger epoch = self.modeEpoch;
    const NSUInteger sequence = ++self.modeReadSequence;
    const NSUInteger writeSeq = self.modeWriteSequence;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/settings" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ ||
            self_->_inFlightModeWrites.count > 0 ||
            epoch != self_->_modeEpoch ||
            sequence != self_->_modeReadSequence ||
            writeSeq != self_->_modeWriteSequence) return;
        NSDictionary *kv = ([json isKindOfClass:[NSDictionary class]] &&
                            [json[@"kv"] isKindOfClass:[NSDictionary class]]) ? json[@"kv"] : nil;
        id okVal = kv ? json[@"ok"] : nil;
        const BOOL ok = !okVal || ([okVal respondsToSelector:@selector(boolValue)] && [okVal boolValue]);
        if (!kv || !ok) return; // 读取失败不能重置用户模式
        NSString *raw = [kv[@"uimode"] isKindOfClass:[NSString class]] ? kv[@"uimode"] : nil;
        NSString *resolved = [raw isEqualToString:@"pro"] ? @"pro" : @"listen";
        [self_ applyUiMode:resolved persist:NO navigateToStation:NO];
    }];
}

#pragma mark - 生命周期

- (void)loadInitialData {
    if (![RLPCoreClient shared].started) return;
    [self reloadUiModePreference];
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
    [self stopScanPolling];
}

- (void)onScreenParametersChanged:(NSNotification *)note {
    (void)note;
    if ([NSThread isMainThread]) {
        RLPConvergeAndWriteBackMainWindowFrame(self.window);
    } else {
        __weak __typeof__(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __typeof__(self) self_ = weakSelf;
            if (!self_) return;
            RLPConvergeAndWriteBackMainWindowFrame(self_.window);
        });
    }
}

- (void)onWindowDidExitFullScreen:(NSNotification *)note {
    (void)note;
    // 退出全屏的动画期间 frame 还是全屏尺寸：此时收敛会把窗口改成"屏幕可见区大小"，所以要等恢复完成。
    // 0.5s 后做的仍然是幂等收敛 —— 窗口本来就在可见区时什么都不会发生；只有落在死区的 frame
    // （拔屏后还是旧屏坐标）会被夹回最近的屏，并写回 autosave。
    __weak __typeof__(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        RLPConvergeAndWriteBackMainWindowFrame(self_.window);
    });
}

@end
