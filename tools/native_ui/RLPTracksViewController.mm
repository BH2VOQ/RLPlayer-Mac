// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPTracksViewController.mm — 曲目列表页（纯 AppKit / NSTableView）
//
#import "RLPTracksViewController.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPSupport.h"
#import "RLPTrackActions.h"
#import "RLPTheme.h"

static NSString * const kColIndex = @"track.index";
static NSString * const kColFav = @"track.fav";
static NSString * const kColTitle = @"track.title";
// web 2026-10-26 起：艺术家与专辑是**同一格** `.ar`，文本 `artist — album`
// （ui_script.h:3395）。旧原生的独立 180px「专辑」列已删除。
static NSString * const kColArtistAlbum = @"track.artistAlbum";
// web fmtTag(sr,bits) 的规格列 `.bd`（92px，只在表格宽 >1400 时出现）。
static NSString * const kColFormat = @"track.format";
static NSString * const kColDuration = @"track.duration";
static NSString * const kColAdd = @"track.add";

// web ui_script.h:3391 的固定轨道宽与 gap；标题/艺术家按剩余宽度分。
static const CGFloat kTrackIndexW = 28.0;
static const CGFloat kTrackFavW = 24.0;
static const CGFloat kTrackFormatW = 92.0;
static const CGFloat kTrackDurationW = 58.0;
static const CGFloat kTrackAddW = 26.0;
static const CGFloat kTrackGap = 8.0;
static const CGFloat kTrackTitleMinW = 120.0;

/// web fmtTag(sr,bits)：整数千赫 → "96k"，否则一位小数 "44.1k"；空采样率 → 空串。
/// 与 RLPNowPlayingViewController.mm 的私有版本同一算法，但这里只服务曲目页，
/// 不再往 RLPSupport 里塞一个只有一个调用点的“公共”函数。
static NSString *RLPTrackFormatText(NSInteger sr, NSInteger bits) {
    if (sr <= 0) return @"";
    NSString *rate = (sr % 1000 == 0)
        ? [NSString stringWithFormat:@"%ldk", (long)(sr / 1000)]
        : [NSString stringWithFormat:@"%.1fk", round((double)sr / 100.0) / 10.0];
    if (bits <= 0) return rate;
    return [NSString stringWithFormat:@"%@/%ld", rate, (long)bits];
}

/// web `.ar` 的合并文本：`artist — album`（U+2014 两侧各一空格）。
/// 空字段要优雅降级：只有一个时不吐悬空破折号，两个都空就是空串。
static NSString *RLPTrackArtistAlbumText(RLPTrack *t) {
    NSString *artist = t.artist ?: @"";
    NSString *album = t.album ?: @"";
    if (artist.length && album.length)
        return [NSString stringWithFormat:@"%@ \u2014 %@", artist, album];
    if (artist.length) return artist;
    if (album.length) return album;
    return @"";
}

#pragma mark - 支持右键选中行的表格视图

@interface RLPTrackTableView : NSTableView
/// 按行取路径：右键菜单必须针对**被点的那一行**，不能用静态菜单。
@property (nonatomic, copy) NSString *_Nullable (^pathForRow)(NSInteger row);
@end

@implementation RLPTrackTableView

- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = [self rowAtPoint:p];
    if (row >= 0 && row < self.numberOfRows) {
        if (![self isRowSelected:row]) {
            [self selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
        }
        // 与 web trackActionMenu 同一套：播放/入队/收藏/存歌单/体检/对比
        NSString *path = self.pathForRow ? self.pathForRow(row) : nil;
        NSMenu *m = RLPTrackMenuForPath(path, self, nil, nil);
        return m ?: self.menu;
    }
    return nil;
}

@end

#pragma mark - 曲目列表控制器

@interface RLPTracksViewController () <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate>
@end

@implementation RLPTracksViewController {
    NSSearchField *_searchField;
    RLPTrackTableView *_tableView;
    NSScrollView *_scrollView;
    NSView *_footerView;
    NSButton *_loadMoreButton;
    NSTextField *_emptyLabel;
    // P9：搜索无结果时的整块空态（带搜索词 + 提示 + 「清空搜索词」），与普通空态分开，
    // 因为 web 只在 q 非空时渲染这一块（ui_script.h:3337-3345）。
    NSStackView *_searchEmptyView;
    NSTextField *_searchEmptyTitle;
    NSTextField *_searchEmptyHint;
    NSButton *_searchClearButton;
    NSLayoutConstraint *_footerHeightConstraint;

    NSMutableArray<RLPTrack *> *_tracks;
    // P5：接口返回的**原始顺序**。每次排序都从这里派生，绝不就地覆盖 ——
    // 否则切回「默认排序」不可逆（web ui_script.h:3352 每次用原始 trackRows 的拷贝）。
    NSMutableArray<RLPTrack *> *_rawTracks;
    NSInteger _limit;
    NSInteger _totalCount;
    BOOL _hasLoaded;
    BOOL _lastLoadFailed;
    NSInteger _searchSeq;
    NSTimer *_debounceTimer;
    NSMutableSet<NSString *> *_favoritePaths;   // /api/fav/list 的路径集合（心形实心/空心）
    NSString *_trackSort;                       // web S.trackSort：default/title/artist/album/dur/year/fav
    NSPopUpButton *_sortPopup;

    // 7 个轨道（web grid-template-columns 一一对应）；宽度由
    // -layoutTrackColumnsForWidth: 按表格宽重新分配。
    NSTableColumn *_colIndex;
    NSTableColumn *_colFav;
    NSTableColumn *_colTitle;
    NSTableColumn *_colArtistAlbum;
    NSTableColumn *_colFormat;
    NSTableColumn *_colDuration;
    NSTableColumn *_colAdd;
    BOOL _layingOutColumns;
}

- (instancetype)init {
    self = [super initWithTitle:RLPTr(@"曲目")];
    if (self) {
        _tracks = [NSMutableArray array];
        _rawTracks = [NSMutableArray array];
        _limit = 300;
        _totalCount = 0;
        _hasLoaded = NO;
        _searchSeq = 0;
        _favoritePaths = [NSMutableSet set];
        _trackSort = @"default";
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onExternalFavoritesChanged:)
                                                     name:RLPFavoritesChangedNotification
                                                   object:nil];
    }
    return self;
}

- (void)onExternalFavoritesChanged:(NSNotification *)note {
    if (note.object == self) return;
    if (![RLPCoreClient shared].started) return;
    [self loadFavoriteSet];
}

- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithTitle:title.length ? title : RLPTr(@"曲目")];
    if (self) {
        _tracks = [NSMutableArray array];
        _rawTracks = [NSMutableArray array];
        _limit = 300;
        _totalCount = 0;
        _hasLoaded = NO;
        _searchSeq = 0;
        _favoritePaths = [NSMutableSet set];
        _trackSort = @"default";
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onExternalFavoritesChanged:)
                                                     name:RLPFavoritesChangedNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_debounceTimer invalidate];
    _debounceTimer = nil;
}

- (void)buildContent {
    RLPTheme *theme = [RLPTheme current];
    NSView *container = self.contentView;

    // 1. 页内搜索框：**不再显示**（P10）。web 的曲目页只有顶栏 #q 一个搜索入口，
    //    旧原生在页面里又放了一个 300px NSSearchField ⟹ 同一个页面两个入口，各写各的搜索。
    //    这里保留这个控件当**查询状态载体**（fetchTracks 读它的 stringValue；
    //    searchWithQuery: 仍由顶栏分派进来），只是从视觉/交互上隐藏。
    _searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    _searchField.placeholderString = RLPTr(@"搜索专辑 / 艺术家 / 曲目…");
    _searchField.delegate = self;
    _searchField.target = self;
    _searchField.action = @selector(onSearchFieldAction:);
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;
    _searchField.hidden = YES;
    [container addSubview:_searchField];

    // 1b. 排序下拉（web track-sort：默认/标题/艺术家/专辑/时长/年份/收藏优先），贴右上角。
    _sortPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _sortPopup.identifier = @"tracks.sort";
    _sortPopup.font = [NSFont systemFontOfSize:12];
    _sortPopup.translatesAutoresizingMaskIntoConstraints = NO;
    {
        NSArray *items = @[ @[@"default", RLPTr(@"默认排序")], @[@"title", RLPTr(@"标题")],
                            @[@"artist", RLPTr(@"艺术家")], @[@"album", RLPTr(@"专辑")],
                            @[@"dur", RLPTr(@"时长")], @[@"year", RLPTr(@"年份")],
                            @[@"fav", RLPTr(@"收藏优先")] ];
        for (NSArray *it in items) {
            [_sortPopup addItemWithTitle:it[1]];
            _sortPopup.lastItem.representedObject = it[0];
        }
    }
    _sortPopup.target = self;
    _sortPopup.action = @selector(onSortChanged:);
    [container addSubview:_sortPopup];

    // 2. 表格与滚动容器
    _tableView = [[RLPTrackTableView alloc] initWithFrame:NSZeroRect];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    // web .trow：12.5px 正文 + 上下各 8px padding ≈ 34pt 行高。
    _tableView.rowHeight = 34.0;
    // web grid gap:8px：列与列之间 8pt（列宽本身由 -layoutTrackColumnsForWidth: 分配）。
    _tableView.intercellSpacing = NSMakeSize(kTrackGap, 0);
    // web 曲目页**没有列头行**（行模板直接进列表）；旧原生的 标题/艺术家/专辑/时长
    // 表头是凭空多出来的，且横向列宽与 web 对不上。这里整行去掉列头，排序下拉等
    // 页面 chrome 不动。
    _tableView.headerView = nil;
    _tableView.backgroundColor = [NSColor clearColor];
    _tableView.target = self;
    // web 版曲目行是**单击播放**（trow.onclick = playPath）。原生改成单击，
    // 双击也保留（老习惯）。tableView.action 在单击时触发。
    _tableView.action = @selector(onSingleClickRow:);
    _tableView.doubleAction = @selector(onDoubleClickRow:);
    // 列宽我们自己按 web 的三个断点分配（不交给 AppKit 均匀拉伸，否则会覆盖断点比例）。
    _tableView.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
    // macOS 11+ 的 NSTableViewStyle 默认 automatic/inset 会在左右各加 10pt 内缩，
    // 让表格自然宽比可视宽多 20pt（+ 列被裁掉/留白）。web 的网格是满宽铺开，用 plain。
    if (@available(macOS 11.0, *)) _tableView.style = NSTableViewStylePlain;

    // 右键上下文菜单：播放、加入队列
    NSMenu *contextMenu = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *playItem = [[NSMenuItem alloc] initWithTitle:RLPTr(@"播放")
                                                      action:@selector(onPlayContextMenu:)
                                               keyEquivalent:@""];
    playItem.target = self;
    [contextMenu addItem:playItem];

    NSMenuItem *enqueueItem = [[NSMenuItem alloc] initWithTitle:RLPTr(@"加入队列")
                                                         action:@selector(onEnqueueContextMenu:)
                                                  keyEquivalent:@""];
    enqueueItem.target = self;
    [contextMenu addItem:enqueueItem];
    _tableView.menu = contextMenu;
    // 动态菜单按被点行取路径（静态菜单只对第一次选中的行有效，是错的）
    __weak __typeof__(self) weakSelf = self;
    ((RLPTrackTableView *)_tableView).pathForRow = ^NSString *(NSInteger row) {
        __typeof__(self) s = weakSelf;
        if (!s) return nil;
        return [s pathAtRow:row];
    };

    // 7 个轨道，与 web `grid-template-columns:28px 24px minmax(120px,1.6fr)
    // minmax(0,1fr) 92px 58px 26px` 逐列对应。
    _colIndex = [[NSTableColumn alloc] initWithIdentifier:kColIndex];
    _colIndex.title = @"";
    _colIndex.width = kTrackIndexW;
    _colIndex.minWidth = kTrackIndexW;
    _colIndex.maxWidth = kTrackIndexW;
    _colIndex.resizingMask = NSTableColumnNoResizing;
    [_tableView addTableColumn:_colIndex];

    // web 第 2 列：收藏心形（24px，实心=已收藏）
    _colFav = [[NSTableColumn alloc] initWithIdentifier:kColFav];
    _colFav.title = @"";
    _colFav.width = kTrackFavW;
    _colFav.minWidth = kTrackFavW;
    _colFav.maxWidth = kTrackFavW;
    _colFav.resizingMask = NSTableColumnNoResizing;
    [_tableView addTableColumn:_colFav];

    _colTitle = [[NSTableColumn alloc] initWithIdentifier:kColTitle];
    _colTitle.title = @"";
    _colTitle.width = 300.0;
    _colTitle.minWidth = kTrackTitleMinW;
    _colTitle.maxWidth = 10000.0;
    _colTitle.resizingMask = NSTableColumnNoResizing;
    [_tableView addTableColumn:_colTitle];

    // web 第 4 列：artist — album 合并单格（旧原生的独立专辑列已删除）。
    _colArtistAlbum = [[NSTableColumn alloc] initWithIdentifier:kColArtistAlbum];
    _colArtistAlbum.title = @"";
    _colArtistAlbum.width = 200.0;
    _colArtistAlbum.minWidth = 0.0;
    _colArtistAlbum.maxWidth = 10000.0;
    _colArtistAlbum.resizingMask = NSTableColumnNoResizing;
    [_tableView addTableColumn:_colArtistAlbum];

    // web 第 5 列：规格 `.bd`（92px，只在表格宽 >1400 时出现）。
    _colFormat = [[NSTableColumn alloc] initWithIdentifier:kColFormat];
    _colFormat.title = @"";
    _colFormat.width = 0.0;
    _colFormat.minWidth = 0.0;
    _colFormat.maxWidth = kTrackFormatW;
    _colFormat.resizingMask = NSTableColumnNoResizing;
    _colFormat.hidden = YES;
    [_tableView addTableColumn:_colFormat];

    _colDuration = [[NSTableColumn alloc] initWithIdentifier:kColDuration];
    _colDuration.title = @"";
    _colDuration.width = kTrackDurationW;
    _colDuration.minWidth = kTrackDurationW;
    _colDuration.maxWidth = kTrackDurationW;
    _colDuration.resizingMask = NSTableColumnNoResizing;
    [_tableView addTableColumn:_colDuration];

    // web 第 7 列：「+」入队（26px，断点下永不收起）
    _colAdd = [[NSTableColumn alloc] initWithIdentifier:kColAdd];
    _colAdd.title = @"";
    _colAdd.width = kTrackAddW;
    _colAdd.minWidth = kTrackAddW;
    _colAdd.maxWidth = kTrackAddW;
    _colAdd.resizingMask = NSTableColumnNoResizing;
    [_tableView addTableColumn:_colAdd];

    _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scrollView.drawsBackground = NO;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.hasHorizontalScroller = NO;
    _scrollView.autohidesScrollers = YES;
    _scrollView.documentView = _tableView;
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:_scrollView];

    // 表格宽度 = 滚动容器可视宽。窗口/页面宽度变化时重分配 7 列（响应式断点）。
    _scrollView.contentView.postsFrameChangedNotifications = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onClipFrameChanged:)
                                                 name:NSViewFrameDidChangeNotification
                                               object:_scrollView.contentView];

    // 3. 居中空状态提示
    _emptyLabel = [NSTextField labelWithString:@""];
    _emptyLabel.font = theme.body;
    _emptyLabel.textColor = theme.mut;
    _emptyLabel.alignment = NSTextAlignmentCenter;
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyLabel.hidden = YES;
    [container addSubview:_emptyLabel];

    // 3b. P9 搜索无结果空态（web ui_script.h:3337-3345）：
    //   「未找到与 “<q>” 相关的曲目」 + 小字提示 + 「清空搜索词」按钮（点击 = 顶栏 qClear）。
    // 旧原生只有一行「没有匹配的曲目」，既不告诉用户搜了什么，也没有清空入口。
    _searchEmptyView = [[NSStackView alloc] init];
    _searchEmptyView.orientation = NSUserInterfaceLayoutOrientationVertical;
    _searchEmptyView.alignment = NSLayoutAttributeCenterX;
    _searchEmptyView.spacing = 8;
    _searchEmptyView.translatesAutoresizingMaskIntoConstraints = NO;
    _searchEmptyView.hidden = YES;
    _searchEmptyView.identifier = @"tracks.searchempty";

    _searchEmptyTitle = RLPLabel(@"", [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold], theme.text);
    _searchEmptyTitle.alignment = NSTextAlignmentCenter;
    _searchEmptyTitle.maximumNumberOfLines = 0;
    _searchEmptyTitle.lineBreakMode = NSLineBreakByWordWrapping;
    _searchEmptyTitle.preferredMaxLayoutWidth = 560;

    _searchEmptyHint = RLPLabel(RLPTr(@"请尝试缩短搜索词，或检查是否有错别字"),
                                [NSFont systemFontOfSize:12], theme.mut2);
    _searchEmptyHint.alignment = NSTextAlignmentCenter;

    _searchClearButton = [NSButton buttonWithTitle:RLPTr(@"清空搜索词")
                                             target:self
                                             action:@selector(onSearchClear:)];
    _searchClearButton.bezelStyle = NSBezelStyleRounded;
    _searchClearButton.controlSize = NSControlSizeSmall;
    _searchClearButton.identifier = @"tracks.searchclear";

    [_searchEmptyView addArrangedSubview:_searchEmptyTitle];
    [_searchEmptyView addArrangedSubview:_searchEmptyHint];
    [_searchEmptyView addArrangedSubview:_searchClearButton];
    [container addSubview:_searchEmptyView];

    // 4. 底栏与“加载更多”按钮
    _footerView = [[NSView alloc] initWithFrame:NSZeroRect];
    _footerView.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:_footerView];

    _loadMoreButton = [NSButton buttonWithTitle:RLPTr(@"加载更多")
                                         target:self
                                         action:@selector(onLoadMore:)];
    _loadMoreButton.bezelStyle = NSBezelStyleRounded;
    _loadMoreButton.translatesAutoresizingMaskIntoConstraints = NO;
    _loadMoreButton.hidden = YES;
    [_footerView addSubview:_loadMoreButton];

    _footerHeightConstraint = [_footerView.heightAnchor constraintEqualToConstant:0.0];

    [NSLayoutConstraint activateConstraints:@[
        [_searchField.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:24.0],
        [_searchField.topAnchor constraintEqualToAnchor:container.topAnchor constant:4.0],
        [_searchField.widthAnchor constraintEqualToConstant:300.0],
        [_searchField.heightAnchor constraintEqualToConstant:24.0],
        [_sortPopup.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-24.0],
        [_sortPopup.centerYAnchor constraintEqualToAnchor:_searchField.centerYAnchor],

        [_scrollView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:24.0],
        [_scrollView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-24.0],
        [_scrollView.topAnchor constraintEqualToAnchor:_searchField.bottomAnchor constant:12.0],
        [_scrollView.bottomAnchor constraintEqualToAnchor:_footerView.topAnchor],

        [_emptyLabel.centerXAnchor constraintEqualToAnchor:_scrollView.centerXAnchor],
        [_emptyLabel.centerYAnchor constraintEqualToAnchor:_scrollView.centerYAnchor],

        [_searchEmptyView.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [_searchEmptyView.centerYAnchor constraintEqualToAnchor:_scrollView.centerYAnchor],
        [_searchEmptyView.widthAnchor constraintLessThanOrEqualToAnchor:container.widthAnchor constant:-80],

        [_footerView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:24.0],
        [_footerView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-24.0],
        [_footerView.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8.0],
        _footerHeightConstraint,

        [_loadMoreButton.centerXAnchor constraintEqualToAnchor:_footerView.centerXAnchor],
        [_loadMoreButton.centerYAnchor constraintEqualToAnchor:_footerView.centerYAnchor],
        [_loadMoreButton.heightAnchor constraintEqualToConstant:28.0],
    ]];
}

#pragma mark - 响应式列宽（web .trow-track 三个断点）

/// 页面布局完成 / 滚动容器宽度变化时重算 7 个轨道。
- (void)viewDidLayout {
    [super viewDidLayout];
    [self layoutTrackColumnsForWidth:NSWidth(_scrollView.contentView.bounds)];
}

- (void)onClipFrameChanged:(NSNotification *)note {
    (void)note;
    [self layoutTrackColumnsForWidth:NSWidth(_scrollView.contentView.bounds)];
}

/// 与 web 逐值对齐（ui_script.h:3391 + ui_page.h:229）：
///   >1400        : 28 / 24 / 1.6fr / 1fr / 92 / 58 / 26，gap 8
///   1121…1400    : 规格列 0，标题:艺术家 = 1.8:1
///   ≤1120        : 规格列 0，标题:艺术家 = 1:0.9（标题最小 120，+ 列永在）
/// 表格宽 = 滚动容器可视宽；列宽总和 + 列间隙必须正好铺满，否则最右「+」会被压掉。
- (void)layoutTrackColumnsForWidth:(CGFloat)tableWidth {
    if (!_tableView || _layingOutColumns) return;
    if (!(tableWidth > 1.0)) return;
    _layingOutColumns = YES;

    const BOOL showFormat = (tableWidth > 1400.0);
    _colFormat.hidden = !showFormat;
    _colFormat.width = showFormat ? kTrackFormatW : 0.0;

    // 隐藏列不参与 AppKit 的列间隙：可见 7 列 → 6 个 gap，可见 6 列 → 5 个 gap。
    const CGFloat gaps = (showFormat ? 6.0 : 5.0) * kTrackGap;
    const CGFloat fixed = kTrackIndexW + kTrackFavW + kTrackDurationW + kTrackAddW +
                          (showFormat ? kTrackFormatW : 0.0);
    CGFloat remaining = tableWidth - gaps - fixed;
    if (!(remaining > kTrackTitleMinW)) remaining = kTrackTitleMinW;

    CGFloat titleW = 0.0;
    if (showFormat) {
        titleW = remaining * 1.6 / 2.6;          // 1.6 : 1
    } else if (tableWidth > 1120.0) {
        titleW = remaining * 1.8 / 2.8;          // 1.8 : 1
    } else {
        titleW = remaining / 1.9;                // 1 : 0.9
    }
    if (titleW < kTrackTitleMinW) titleW = kTrackTitleMinW;
    CGFloat artistW = remaining - titleW;
    if (artistW < 0.0) artistW = 0.0;

    _colIndex.width = kTrackIndexW;
    _colFav.width = kTrackFavW;
    _colTitle.width = titleW;
    _colArtistAlbum.width = artistW;
    _colDuration.width = kTrackDurationW;
    _colAdd.width = kTrackAddW;

    [_tableView tile];
    [_tableView setNeedsDisplay:YES];
    _layingOutColumns = NO;
}

#pragma mark - 生命周期与刷新

- (void)activate {
    if (!_hasLoaded) {
        [self reloadData];
    }
}

- (void)reloadData {
    _limit = 300;
    [self fetchTracks];
}

- (void)applyTheme {
    [super applyTheme];
    if (!self.isViewLoaded) return;
    RLPTheme *theme = [RLPTheme current];
    _emptyLabel.textColor = theme.mut;
    _searchEmptyTitle.textColor = theme.text;
    _searchEmptyHint.textColor = theme.mut2;
    [_tableView reloadData];
}

#pragma mark - 数据请求

- (void)fetchTracks {
    _lastLoadFailed = NO;
    if (![RLPCoreClient shared].started) {
        [self setSubtitle:RLPTr(@"核心未启动")];
        [_tracks removeAllObjects];
        [_rawTracks removeAllObjects];
        _totalCount = 0;
        _hasLoaded = NO;
        _emptyLabel.stringValue = RLPTr(@"核心未启动");
        _emptyLabel.hidden = NO;
        _searchEmptyView.hidden = YES;
        [self updateFooterVisibility];
        [_tableView reloadData];
        return;
    }

    NSString *q = _searchField.stringValue ?: @"";
    NSString *path = [NSString stringWithFormat:@"/api/lib/search?q=%@&limit=%ld",
                      RLPEnc(q), (long)_limit];

    NSInteger seq = ++_searchSeq;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:path completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || self_->_searchSeq != seq) return;

        // web：头部标题随查询词变化（head(q ? ('搜索：' + q) : '曲目', …)，ui_script.h:3334）。
        [self_ setPageTitle:q.length ? [NSString stringWithFormat:RLPTr(@"搜索：%@"), q] : RLPTr(@"曲目")];

        if (!json || ![json[@"ok"] boolValue]) {
            self_->_hasLoaded = NO;
            self_->_lastLoadFailed = YES;
            [self_ setSubtitle:RLPTr(@"读取失败")];
            [self_->_tracks removeAllObjects];
            [self_->_rawTracks removeAllObjects];
            self_->_totalCount = 0;
            self_->_emptyLabel.stringValue = RLPTr(@"读取失败");
            self_->_emptyLabel.hidden = NO;
            self_->_searchEmptyView.hidden = YES;
            [self_ updateFooterVisibility];
            [self_->_tableView reloadData];
            return;
        }
        self_->_hasLoaded = YES;
        self_->_lastLoadFailed = NO;

        NSArray<RLPTrack *> *list = [RLPTrack tracksFromJSON:json key:@"tracks"];
        [self_->_rawTracks setArray:list];   // P5：只维护原始序；_tracks 由 applyTrackSort 派生

        NSInteger total = [json[@"total"] respondsToSelector:@selector(integerValue)]
            ? [json[@"total"] integerValue]
            : (NSInteger)list.count;
        if (total < (NSInteger)list.count) total = (NSInteger)list.count;
        self_->_totalCount = total;

        if (list.count == 0) {
            [self_ setSubtitle:RLPTr(@"没有匹配的曲目")];
            if (q.length) {
                // web 只在 q 非空时给这块空态（含搜索词与清空入口）；q 为空仍是一行提示。
                self_->_emptyLabel.hidden = YES;
                self_->_searchEmptyTitle.stringValue =
                    [NSString stringWithFormat:RLPTr(@"未找到与 “%@” 相关的曲目"), q];
                self_->_searchEmptyView.hidden = NO;
            } else {
                self_->_searchEmptyView.hidden = YES;
                self_->_emptyLabel.stringValue = RLPTr(@"没有匹配的曲目");
                self_->_emptyLabel.hidden = NO;
            }
        } else {
            self_->_emptyLabel.hidden = YES;
            self_->_searchEmptyView.hidden = YES;
            if (total > (NSInteger)list.count) {
                [self_ setSubtitle:[NSString stringWithFormat:@"%ld / %ld %@",
                                    (long)list.count, (long)total, RLPTr(@"首")]];
            } else {
                [self_ setSubtitle:[NSString stringWithFormat:@"%ld %@",
                                    (long)list.count, RLPTr(@"首")]];
            }
        }

        // 先派生 _tracks（P5 从 _rawTracks），footer 的「加载更多」判据读的是 _tracks.count。
        [self_ applyTrackSort];
        [self_ updateFooterVisibility];
        [self_ loadFavoriteSet];
        [self_->_tableView reloadData];
    }];
}

/// 收藏集合（/api/fav/list）——心形实心/空心的事实源；不自己猜。
- (void)loadFavoriteSet {
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/fav/list" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        [self_->_favoritePaths removeAllObjects];
        NSArray *files = [json[@"files"] isKindOfClass:[NSArray class]] ? json[@"files"] : @[];
        for (id f in files) {
            if ([f isKindOfClass:[NSString class]]) [self_->_favoritePaths addObject:RLPFavNormalizePath(f)];
            else if ([f isKindOfClass:[NSDictionary class]] && [f[@"file"] isKindOfClass:[NSString class]])
                [self_->_favoritePaths addObject:RLPFavNormalizePath(f[@"file"])];
        }
        [self_->_tableView reloadData];
    }];
}

- (void)updateFooterVisibility {
    // 2026-11-17（UI 缺口审计）：旧实现把「加载更多」卡在 5000 首，超过就无法继续翻。
    // 与 Web 版一致：只要还有未加载的曲目就允许翻倍。
    BOOL canLoadMore = (_totalCount > (NSInteger)_tracks.count);
    _footerHeightConstraint.constant = canLoadMore ? 40.0 : 0.0;
    _loadMoreButton.hidden = !canLoadMore;
}

#pragma mark - 搜索与防抖

- (void)controlTextDidChange:(NSNotification *)obj {
    if (obj.object == _searchField) {
        [_debounceTimer invalidate];
        _debounceTimer = nil;

        __weak __typeof__(self) weakSelf = self;
        _debounceTimer = [NSTimer scheduledTimerWithTimeInterval:0.35
                                                         repeats:NO
                                                           block:^(NSTimer * _Nonnull timer) {
            (void)timer;
            __typeof__(self) self_ = weakSelf;
            if (!self_) return;
            self_->_debounceTimer = nil;
            self_->_limit = 300;
            [self_ fetchTracks];
        }];
    }
}

- (void)onSearchFieldAction:(id)sender {
    (void)sender;
    [_debounceTimer invalidate];
    _debounceTimer = nil;
    _limit = 300;
    [self fetchTracks];
}

- (void)searchWithQuery:(NSString *)query {
    [_debounceTimer invalidate];
    _debounceTimer = nil;
    _searchField.stringValue = query ?: @"";
    _limit = 300;
    [self fetchTracks];
}

/// P9：空态里的「清空搜索词」= web 的 D('qClear').click()（ui_script.h:3342-3344）：
/// 清空顶栏搜索框并按当前视图重拉，而不是只把页内查询置空（那样顶栏还留着旧词）。
- (void)onSearchClear:(id)sender {
    (void)sender;
    NSWindowController *wc = self.isViewLoaded ? self.view.window.windowController : nil;
    if ([wc respondsToSelector:@selector(clearSearchQuery)]) {
        [(id)wc performSelector:@selector(clearSearchQuery)];
        return;
    }
    // 主窗口（D 包合并前）还没有 clearSearchQuery：清空它的搜索框并走 onSearch:（qClear 同一落点）。
    if ([wc respondsToSelector:@selector(onSearch:)]) {
        NSSearchField *topSearch = nil;
        @try {
            topSearch = (NSSearchField *)[wc valueForKey:@"search"];
        } @catch (NSException *e) {
            (void)e;
            topSearch = nil;
        }
        if ([topSearch isKindOfClass:[NSSearchField class]]) {
            topSearch.stringValue = @"";
            [(id)wc performSelector:@selector(onSearch:) withObject:topSearch];
            return;
        }
    }
    [self searchWithQuery:@""];   // 没有主窗口（离屏单页）时至少清掉本页查询
}

- (void)onLoadMore:(id)sender {
    (void)sender;
    _limit = _limit > 0 ? _limit * 2 : 100;   // 与 Web 的 cur*2 一致，不再封顶
    [self fetchTracks];
}

#pragma mark - 单击 / 双击 / 右键菜单动作

/// 单击播放（与 web 版 trow.onclick 一致）。
/// 注意：NSTableView 在双击时会先触发 action 再触发 doubleAction，
/// 两者都指向"播放这一首"，所以重复触发是幂等的，不会播两次不同的歌。
- (void)onSingleClickRow:(id)sender {
    (void)sender;
    NSInteger row = _tableView.clickedRow;
    if (row < 0 || row >= (NSInteger)_tracks.count) return;
    RLPTrack *t = _tracks[(NSUInteger)row];
    if (t.path.length) RLPPlayPath(t.path);
}

- (void)onDoubleClickRow:(id)sender {
    (void)sender;
    NSInteger row = _tableView.clickedRow;
    if (row < 0 || row >= (NSInteger)_tracks.count) return;
    RLPTrack *t = _tracks[(NSUInteger)row];
    if (t.path.length) {
        RLPPlayPath(t.path);
    }
}

/// 供动态右键菜单按行取路径。
- (NSString *)pathAtRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_tracks.count) return nil;
    return _tracks[(NSUInteger)row].path;
}

/// 共享菜单的动作入口（RLPTrackMenuForPath 的项走 responder chain 到这里）。
- (void)rlp_trackMenuAction:(NSMenuItem *)sender {
    RLPHandleTrackAction(sender, self.view);
}

- (void)onPlayContextMenu:(id)sender {
    (void)sender;
    NSInteger row = _tableView.clickedRow >= 0 ? _tableView.clickedRow : _tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)_tracks.count) return;
    RLPTrack *t = _tracks[(NSUInteger)row];
    if (t.path.length) {
        RLPPlayPath(t.path);
    }
}

- (void)onEnqueueContextMenu:(id)sender {
    (void)sender;
    NSInteger row = _tableView.clickedRow >= 0 ? _tableView.clickedRow : _tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)_tracks.count) return;
    RLPTrack *t = _tracks[(NSUInteger)row];
    if (t.path.length) {
        RLPEnqueuePath(t.path);
        RLPToast(RLPTr(@"已加入队列"));
    }
}

#pragma mark - NSTableViewDataSource & NSTableViewDelegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return (NSInteger)_tracks.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_tracks.count) return nil;
    RLPTrack *t = _tracks[(NSUInteger)row];
    RLPTheme *theme = [RLPTheme current];
    NSString *reuse = [tableColumn.identifier stringByAppendingString:@".cell"];

    if ([tableColumn.identifier isEqualToString:kColFav] || [tableColumn.identifier isEqualToString:kColAdd]) {
        const BOOL isFavCol = [tableColumn.identifier isEqualToString:kColFav];
        NSTableCellView *bc = [tableView makeViewWithIdentifier:reuse owner:self];
        if (!bc) {
            bc = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableColumn.width, 34)];
            bc.identifier = reuse;
            NSButton *b = [NSButton buttonWithTitle:@"" target:self
                                             action:isFavCol ? @selector(onRowFav:) : @selector(onRowAdd:)];
            b.bordered = NO;
            b.imagePosition = NSImageOnly;
            b.imageScaling = NSImageScaleProportionallyDown;
            b.identifier = isFavCol ? kColFav : kColAdd;
            b.translatesAutoresizingMaskIntoConstraints = NO;
            [bc addSubview:b];
            [NSLayoutConstraint activateConstraints:@[
                [b.centerXAnchor constraintEqualToAnchor:bc.centerXAnchor],
                [b.centerYAnchor constraintEqualToAnchor:bc.centerYAnchor],
                [b.widthAnchor constraintEqualToConstant:22.0],
                [b.heightAnchor constraintEqualToConstant:22.0],
            ]];
            bc.textField = nil;
        }
        NSButton *btn = nil;
        for (NSView *v in bc.subviews) if ([v isKindOfClass:[NSButton class]]) btn = (NSButton *)v;
        const BOOL fav = [_favoritePaths containsObject:RLPFavNormalizePath(t.path)];
        btn.tag = row;
        btn.image = [NSImage imageWithSystemSymbolName:(isFavCol ? (fav ? @"heart.fill" : @"heart") : @"plus")
                              accessibilityDescription:isFavCol ? RLPTr(@"收藏") : RLPTr(@"加入队列")];
        // 心形：已收藏用强调色；「+」永远是次要色（旧码会把已收藏曲目的 + 也染成 accent）。
        btn.contentTintColor = (isFavCol && fav) ? theme.accent : theme.mut;
        btn.toolTip = isFavCol ? (fav ? RLPTr(@"取消收藏") : RLPTr(@"收藏")) : RLPTr(@"加入队列");
        return bc;
    }

    NSTableCellView *cell = [tableView makeViewWithIdentifier:reuse owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableColumn.width, 34)];
        cell.identifier = reuse;

        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        tf.maximumNumberOfLines = 1;
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        // 测试/审计用 identifier 定位真实文本字段；按钮的 track.fav/track.add 不受影响。
        tf.identifier = tableColumn.identifier;
        [cell addSubview:tf];
        cell.textField = tf;

        // web .trow padding 8px 20px + margin 0 10px ⟹ 单元格左右各内缩 ~10pt。
        [NSLayoutConstraint activateConstraints:@[
            [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:10.0],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-10.0],
            [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }

    NSTextField *tf = cell.textField;
    tf.alignment = NSTextAlignmentLeft;
    tf.textColor = theme.text;
    tf.font = [NSFont systemFontOfSize:12.5];
    tf.toolTip = nil;
    cell.toolTip = nil;

    NSString *ident = tableColumn.identifier;
    if ([ident isEqualToString:kColIndex]) {
        tf.alignment = NSTextAlignmentRight;
        tf.textColor = theme.mut2;
        tf.font = theme.mono ?: theme.small;
        tf.stringValue = [NSString stringWithFormat:@"%ld", (long)(row + 1)];
    } else if ([ident isEqualToString:kColTitle]) {
        tf.alignment = NSTextAlignmentLeft;
        tf.textColor = theme.text;
        tf.font = [NSFont systemFontOfSize:12.5];
        tf.stringValue = t.title.length ? t.title : @"-";
        tf.toolTip = t.title.length ? t.title : nil;
    } else if ([ident isEqualToString:kColArtistAlbum]) {
        // web `.ar`：artist — album 单格 + 同串 tooltip。
        NSString *ar = RLPTrackArtistAlbumText(t);
        tf.alignment = NSTextAlignmentLeft;
        tf.textColor = theme.mut2;
        tf.font = [NSFont systemFontOfSize:11.5];
        tf.stringValue = ar;
        tf.toolTip = ar.length ? ar : nil;
        cell.toolTip = ar.length ? ar : nil;
    } else if ([ident isEqualToString:kColFormat]) {
        // web `.bd`：9.5px / accent-text / 右对齐 / letter-spacing .3。
        NSString *bd = RLPTrackFormatText(t.sampleRate, t.bits);
        tf.alignment = NSTextAlignmentRight;
        tf.textColor = theme.accentText;
        tf.font = [NSFont systemFontOfSize:9.5];
        NSAttributedString *as = [[NSAttributedString alloc] initWithString:bd attributes:@{
            NSFontAttributeName: tf.font,
            NSForegroundColorAttributeName: theme.accentText,
            NSKernAttributeName: @0.3,
        }];
        tf.attributedStringValue = as;
        tf.toolTip = bd.length ? bd : nil;
    } else if ([ident isEqualToString:kColDuration]) {
        tf.alignment = NSTextAlignmentRight;
        tf.textColor = theme.mut2;
        tf.font = theme.mono ?: theme.small;
        tf.stringValue = RLPFmtDuration(t.duration);
    } else {
        tf.stringValue = @"";
    }

    return cell;
}

#pragma mark - 行悬停（web .trow:hover）

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    (void)tableView; (void)row;
    RLPHoverRowView *v = [[RLPHoverRowView alloc] initWithFrame:NSZeroRect];
    v.hoverColor = [RLPTheme current].hov;
    return v;
}

#pragma mark - 排序（web track-sort，客户端排序与 web 同口径）

- (void)onSortChanged:(NSPopUpButton *)sender {
    id rep = sender.selectedItem.representedObject;
    _trackSort = [rep isKindOfClass:[NSString class]] ? rep : @"default";
    [self applyTrackSort];
    [_tableView reloadData];
}

/// 与 web 的排序键逐条对齐（web 只排**当前已加载的这一片**，不改变后端分页）。
/// 每次都从 _rawTracks（接口原始顺序）派生；default = 原序（P5：可逆）。
- (void)applyTrackSort {
    if (!_rawTracks) { [_tracks removeAllObjects]; return; }
    if (!_rawTracks.count || [_trackSort isEqualToString:@"default"]) {
        [_tracks setArray:_rawTracks];
        return;
    }
    NSArray *sorted = [_rawTracks sortedArrayUsingComparator:^NSComparisonResult(RLPTrack *a, RLPTrack *b) {
        if ([self->_trackSort isEqualToString:@"title"])
            return [(a.title ?: @"") caseInsensitiveCompare:(b.title ?: @"")];
        if ([self->_trackSort isEqualToString:@"artist"])
            return [(a.artist ?: @"") caseInsensitiveCompare:(b.artist ?: @"")];
        if ([self->_trackSort isEqualToString:@"album"])
            return [(a.album ?: @"") caseInsensitiveCompare:(b.album ?: @"")];
        if ([self->_trackSort isEqualToString:@"dur"])
            return a.duration < b.duration ? NSOrderedAscending : (a.duration > b.duration ? NSOrderedDescending : NSOrderedSame);
        if ([self->_trackSort isEqualToString:@"year"]) {
            // web ui_script.h:3362-3363 的 year 是**降序**：(b.year||0)-(a.year||0)，新到旧。
            // 后端 /api/lib/search 本来就回 "year"（rtaweb.cpp:8244），RLPTrack 已解析，
            // 旧码注释「曲目没有 year 字段」不成立。
            if (a.year == b.year) return NSOrderedSame;
            // JS 的 (b.year - a.year) 为正 ⟹ a 排在 b 之后 ⟹ NSOrderedDescending。
            return (b.year > a.year) ? NSOrderedDescending : NSOrderedAscending;
        }
        if ([self->_trackSort isEqualToString:@"fav"]) {
            const BOOL fa = [self->_favoritePaths containsObject:RLPFavNormalizePath(a.path)];
            const BOOL fb = [self->_favoritePaths containsObject:RLPFavNormalizePath(b.path)];
            if (fa != fb) return fa ? NSOrderedAscending : NSOrderedDescending;
            return [(a.title ?: @"") caseInsensitiveCompare:(b.title ?: @"")];
        }
        return NSOrderedSame;
    }];
    [_tracks setArray:sorted];
}

#pragma mark - 行内动作（web favIconHtml / 第 7 列 +）

- (void)onRowFav:(NSButton *)sender {
    const NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)_tracks.count) return;
    RLPTrack *t = _tracks[(NSUInteger)row];
    NSString *normPath = RLPFavNormalizePath(t.path);
    const BOOL was = [_favoritePaths containsObject:normPath];
    NSString *url = [NSString stringWithFormat:@"/api/fav?file=%@&on=%d", RLPEnc(t.path), was ? 0 : 1];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:url body:@"" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            if (was) [self_->_favoritePaths removeObject:normPath];
            else [self_->_favoritePaths addObject:normPath];
            [self_->_tableView reloadData];
            RLPToast(was ? RLPTr(@"已取消收藏") : RLPTr(@"已收藏"));
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPFavoritesChangedNotification object:self_];
        } else {
            RLPToast(RLPTr(@"收藏失败"));
        }
    }];
}

- (void)onRowAdd:(NSButton *)sender {
    const NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)_tracks.count) return;
    // 2026-11-17（UI 缺口审计已证实）：CUE 分轨的行级「+」此前直接 RLPEnqueuePath，
    // 丢掉区间 ⟹ 入队后会从整轨第 1 首开播。有区间时必须走 RLPEnqueuePathCue。
    RLPTrack *tr = _tracks[(NSUInteger)row];
    if (tr.cueStart >= 0) RLPEnqueuePathCue(tr.path, tr.cueStart, tr.cueEnd);
    else RLPEnqueuePath(tr.path);
}

/// 右键菜单的区间提供者（RLPTrackActionTableView 会查这个方法决定是否带 CUE 区间）。
- (nullable NSDictionary<NSString *, NSNumber *> *)rlp_cueRangeForRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_tracks.count) return nil;
    RLPTrack *tr = _tracks[(NSUInteger)row];
    if (tr.cueStart < 0) return nil;
    return @{ @"cs": @(tr.cueStart), @"ce": @(tr.cueEnd) };
}

- (void)applyLanguage {
    NSString *curQ = [_searchField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    self.pageTitle = (_hasLoaded && curQ.length) ? [NSString stringWithFormat:RLPTr(@"搜索：%@"), curQ] : RLPTr(@"曲目");
    if (!self.isViewLoaded) return;
    _searchField.placeholderString = RLPTr(@"搜索专辑 / 艺术家 / 曲目…");
    NSArray<NSString *> *sortTitles = @[@"默认排序", @"标题", @"艺术家", @"专辑", @"时长", @"年份", @"收藏优先"];
    for (NSUInteger i = 0; i < (NSUInteger)_sortPopup.numberOfItems && i < sortTitles.count; ++i) {
        [_sortPopup itemAtIndex:(NSInteger)i].title = RLPTr(sortTitles[i]);
    }
    NSArray<NSMenuItem *> *menuItems = _tableView.menu.itemArray;
    if (menuItems.count >= 2) {
        menuItems[0].title = RLPTr(@"播放");
        menuItems[1].title = RLPTr(@"加入队列");
    }
    _searchEmptyHint.stringValue = RLPTr(@"请尝试缩短搜索词，或检查是否有错别字");
    _searchClearButton.title = RLPTr(@"清空搜索词");
    _loadMoreButton.title = RLPTr(@"加载更多");
    if (!_searchEmptyView.hidden) {
        NSString *q = [_searchField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (q.length > 0) {
            _searchEmptyTitle.stringValue = [NSString stringWithFormat:RLPTr(@"未找到与 “%@” 相关的曲目"), q];
        }
    }
    if (![RLPCoreClient shared].started && !_hasLoaded) {
        [self setSubtitle:RLPTr(@"核心未启动")];
        if (!_emptyLabel.hidden) _emptyLabel.stringValue = RLPTr(@"核心未启动");
    } else if (_lastLoadFailed && _tracks.count == 0) {
        [self setSubtitle:RLPTr(@"读取失败")];
        if (!_emptyLabel.hidden) _emptyLabel.stringValue = RLPTr(@"读取失败");
    } else if (_hasLoaded) {
        if (_tracks.count == 0) {
            [self setSubtitle:RLPTr(@"没有匹配的曲目")];
            if (!_emptyLabel.hidden) _emptyLabel.stringValue = RLPTr(@"没有匹配的曲目");
        } else if (_totalCount > (NSInteger)_tracks.count) {
            [self setSubtitle:[NSString stringWithFormat:@"%ld / %ld %@",
                               (long)_tracks.count, (long)_totalCount, RLPTr(@"首")]];
        } else {
            [self setSubtitle:[NSString stringWithFormat:@"%ld %@", (long)_tracks.count, RLPTr(@"首")]];
        }
    }
    NSIndexSet *sel = [_tableView.selectedRowIndexes copy];
    NSPoint origin = _scrollView ? _scrollView.contentView.bounds.origin : NSZeroPoint;
    [_tableView reloadData];
    if (sel.count) [_tableView selectRowIndexes:sel byExtendingSelection:NO];
    if (_scrollView) {
        [_scrollView.contentView scrollToPoint:origin];
        [_scrollView reflectScrolledClipView:_scrollView.contentView];
    }
}

@end