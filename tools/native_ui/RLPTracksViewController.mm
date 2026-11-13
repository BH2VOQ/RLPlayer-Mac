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

static NSString * const kColIndex = @"ColIndex";
static NSString * const kColTitle = @"ColTitle";
static NSString * const kColArtist = @"ColArtist";
static NSString * const kColAlbum = @"ColAlbum";
static NSString * const kColDuration = @"ColDuration";
// web .trow-track 的第 2 列（收藏心形 24px）与第 7 列（入队 + 26px）。
// 旧实现只有 5 列：页面上**没有任何收藏/入队入口**，只能右键——等于没有入口。
static NSString * const kColFav = @"ColFav";
static NSString * const kColAdd = @"ColAdd";

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
    NSLayoutConstraint *_footerHeightConstraint;

    NSMutableArray<RLPTrack *> *_tracks;
    NSInteger _limit;
    NSInteger _totalCount;
    BOOL _hasLoaded;
    NSInteger _searchSeq;
    NSTimer *_debounceTimer;
    NSMutableSet<NSString *> *_favoritePaths;   // /api/fav/list 的路径集合（心形实心/空心）
    NSString *_trackSort;                       // web S.trackSort：default/title/artist/album/dur/year/fav
    NSPopUpButton *_sortPopup;
}

- (instancetype)init {
    self = [super initWithTitle:RLPTr(@"曲目")];
    if (self) {
        _tracks = [NSMutableArray array];
        _limit = 300;
        _totalCount = 0;
        _hasLoaded = NO;
        _searchSeq = 0;
        _favoritePaths = [NSMutableSet set];
        _trackSort = @"default";
    }
    return self;
}

- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithTitle:title.length ? title : RLPTr(@"曲目")];
    if (self) {
        _tracks = [NSMutableArray array];
        _limit = 300;
        _totalCount = 0;
        _hasLoaded = NO;
        _searchSeq = 0;
        _favoritePaths = [NSMutableSet set];
        _trackSort = @"default";
    }
    return self;
}

- (void)dealloc {
    [_debounceTimer invalidate];
    _debounceTimer = nil;
}

- (void)buildContent {
    RLPTheme *theme = [RLPTheme current];
    NSView *container = self.contentView;

    // 1. 页面内搜索框（宽度 300，可清空）
    _searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    _searchField.placeholderString = RLPTr(@"搜索专辑 / 艺术家 / 曲目…");
    _searchField.delegate = self;
    _searchField.target = self;
    _searchField.action = @selector(onSearchFieldAction:);
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;
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
    _tableView.rowHeight = 28.0;
    _tableView.intercellSpacing = NSMakeSize(0, 0);
    _tableView.headerView = [[NSTableHeaderView alloc] initWithFrame:NSZeroRect];
    _tableView.backgroundColor = [NSColor clearColor];
    _tableView.target = self;
    // web 版曲目行是**单击播放**（trow.onclick = playPath）。原生改成单击，
    // 双击也保留（老习惯）。tableView.action 在单击时触发。
    _tableView.action = @selector(onSingleClickRow:);
    _tableView.doubleAction = @selector(onDoubleClickRow:);
    _tableView.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;

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

    // 表头：# / 标题 / 艺术家 / 专辑 / 时长
    NSTableColumn *colIndex = [[NSTableColumn alloc] initWithIdentifier:kColIndex];
    colIndex.title = @"#";
    colIndex.width = 44.0;
    colIndex.minWidth = 36.0;
    colIndex.maxWidth = 60.0;
    colIndex.resizingMask = NSTableColumnNoResizing;
    [_tableView addTableColumn:colIndex];

    // web：第 2 列是收藏心形（24px，实心=已收藏）
    NSTableColumn *colFav = [[NSTableColumn alloc] initWithIdentifier:kColFav];
    colFav.title = @"";
    colFav.width = 26.0; colFav.minWidth = 24.0; colFav.maxWidth = 30.0;
    colFav.resizingMask = NSTableColumnNoResizing;
    [_tableView addTableColumn:colFav];

    NSTableColumn *colTitle = [[NSTableColumn alloc] initWithIdentifier:kColTitle];
    colTitle.title = RLPTr(@"标题");
    colTitle.width = 240.0;
    colTitle.minWidth = 140.0;
    colTitle.resizingMask = NSTableColumnAutoresizingMask;
    [_tableView addTableColumn:colTitle];

    NSTableColumn *colArtist = [[NSTableColumn alloc] initWithIdentifier:kColArtist];
    colArtist.title = RLPTr(@"艺术家");
    colArtist.width = 160.0;
    colArtist.minWidth = 100.0;
    colArtist.resizingMask = NSTableColumnAutoresizingMask;
    [_tableView addTableColumn:colArtist];

    NSTableColumn *colAlbum = [[NSTableColumn alloc] initWithIdentifier:kColAlbum];
    colAlbum.title = RLPTr(@"专辑");
    colAlbum.width = 180.0;
    colAlbum.minWidth = 100.0;
    colAlbum.resizingMask = NSTableColumnAutoresizingMask;
    [_tableView addTableColumn:colAlbum];

    NSTableColumn *colDuration = [[NSTableColumn alloc] initWithIdentifier:kColDuration];
    colDuration.title = RLPTr(@"时长");
    colDuration.width = 70.0;
    colDuration.minWidth = 60.0;
    colDuration.maxWidth = 90.0;
    colDuration.resizingMask = NSTableColumnNoResizing;
    [_tableView addTableColumn:colDuration];

    // web：第 7 列是「+」入队（26px）
    NSTableColumn *colAdd = [[NSTableColumn alloc] initWithIdentifier:kColAdd];
    colAdd.title = @"";
    colAdd.width = 30.0; colAdd.minWidth = 26.0; colAdd.maxWidth = 34.0;
    colAdd.resizingMask = NSTableColumnNoResizing;
    [_tableView addTableColumn:colAdd];

    _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scrollView.drawsBackground = NO;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.hasHorizontalScroller = NO;
    _scrollView.autohidesScrollers = YES;
    _scrollView.documentView = _tableView;
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:_scrollView];

    // 3. 居中空状态提示
    _emptyLabel = [NSTextField labelWithString:@""];
    _emptyLabel.font = theme.body;
    _emptyLabel.textColor = theme.mut;
    _emptyLabel.alignment = NSTextAlignmentCenter;
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyLabel.hidden = YES;
    [container addSubview:_emptyLabel];

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

        [_footerView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:24.0],
        [_footerView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-24.0],
        [_footerView.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8.0],
        _footerHeightConstraint,

        [_loadMoreButton.centerXAnchor constraintEqualToAnchor:_footerView.centerXAnchor],
        [_loadMoreButton.centerYAnchor constraintEqualToAnchor:_footerView.centerYAnchor],
        [_loadMoreButton.heightAnchor constraintEqualToConstant:28.0],
    ]];
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
    RLPTheme *theme = [RLPTheme current];
    _emptyLabel.textColor = theme.mut;
    [_tableView reloadData];
}

#pragma mark - 数据请求

- (void)fetchTracks {
    if (![RLPCoreClient shared].started) {
        [self setSubtitle:RLPTr(@"核心未启动")];
        [_tracks removeAllObjects];
        _totalCount = 0;
        _hasLoaded = YES;
        _emptyLabel.stringValue = RLPTr(@"核心未启动");
        _emptyLabel.hidden = NO;
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
        self_->_hasLoaded = YES;

        if (!json || ![json[@"ok"] boolValue]) {
            [self_ setSubtitle:RLPTr(@"读取失败")];
            [self_->_tracks removeAllObjects];
            self_->_totalCount = 0;
            self_->_emptyLabel.stringValue = RLPTr(@"读取失败");
            self_->_emptyLabel.hidden = NO;
            [self_ updateFooterVisibility];
            [self_->_tableView reloadData];
            return;
        }

        NSArray<RLPTrack *> *list = [RLPTrack tracksFromJSON:json key:@"tracks"];
        [self_->_tracks setArray:list];

        NSInteger total = [json[@"total"] respondsToSelector:@selector(integerValue)]
            ? [json[@"total"] integerValue]
            : (NSInteger)list.count;
        if (total < (NSInteger)list.count) total = (NSInteger)list.count;
        self_->_totalCount = total;

        if (list.count == 0) {
            [self_ setSubtitle:RLPTr(@"没有匹配的曲目")];
            self_->_emptyLabel.stringValue = RLPTr(@"没有匹配的曲目");
            self_->_emptyLabel.hidden = NO;
        } else {
            self_->_emptyLabel.hidden = YES;
            if (total > (NSInteger)list.count) {
                [self_ setSubtitle:[NSString stringWithFormat:@"%ld / %ld %@",
                                    (long)list.count, (long)total, RLPTr(@"首")]];
            } else {
                [self_ setSubtitle:[NSString stringWithFormat:@"%ld %@",
                                    (long)list.count, RLPTr(@"首")]];
            }
        }

        [self_ updateFooterVisibility];
        [self_ loadFavoriteSet];
        [self_ applyTrackSort];
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
            if ([f isKindOfClass:[NSString class]]) [self_->_favoritePaths addObject:f];
            else if ([f isKindOfClass:[NSDictionary class]] && [f[@"file"] isKindOfClass:[NSString class]])
                [self_->_favoritePaths addObject:f[@"file"]];
        }
        [self_->_tableView reloadData];
    }];
}

- (void)updateFooterVisibility {
    BOOL canLoadMore = (_totalCount > (NSInteger)_tracks.count) && (_limit < 5000);
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

- (void)onLoadMore:(id)sender {
    (void)sender;
    if (_limit >= 5000) return;
    _limit = MIN(_limit * 2, 5000);
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

    if ([tableColumn.identifier isEqualToString:kColFav] || [tableColumn.identifier isEqualToString:kColAdd]) {
        const BOOL isFavCol = [tableColumn.identifier isEqualToString:kColFav];
        NSTableCellView *bc = [tableView makeViewWithIdentifier:tableColumn.identifier owner:self];
        if (!bc) {
            bc = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableColumn.width, 24)];
            bc.identifier = tableColumn.identifier;
            NSButton *b = [NSButton buttonWithTitle:@"" target:self
                                             action:isFavCol ? @selector(onRowFav:) : @selector(onRowAdd:)];
            b.bordered = NO;
            b.imagePosition = NSImageOnly;
            b.imageScaling = NSImageScaleProportionallyDown;
            b.identifier = isFavCol ? @"track.fav" : @"track.add";
            b.frame = NSMakeRect(2, 1, tableColumn.width - 4, 22);
            b.autoresizingMask = NSViewWidthSizable;
            [bc addSubview:b];
            bc.textField = nil;
        }
        NSButton *btn = nil;
        for (NSView *v in bc.subviews) if ([v isKindOfClass:[NSButton class]]) btn = (NSButton *)v;
        const BOOL fav = [_favoritePaths containsObject:t.path];
        btn.tag = row;
        btn.image = [NSImage imageWithSystemSymbolName:(isFavCol ? (fav ? @"heart.fill" : @"heart") : @"plus")
                              accessibilityDescription:isFavCol ? RLPTr(@"收藏") : RLPTr(@"加入队列")];
        btn.contentTintColor = fav ? [RLPTheme current].accent : [RLPTheme current].mut;
        btn.toolTip = isFavCol ? (fav ? RLPTr(@"取消收藏") : RLPTr(@"收藏")) : RLPTr(@"加入队列");
        return bc;
    }

    NSTableCellView *cell = [tableView makeViewWithIdentifier:tableColumn.identifier owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableColumn.width, 24)];
        cell.identifier = tableColumn.identifier;

        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        tf.maximumNumberOfLines = 1;
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:tf];
        cell.textField = tf;

        [NSLayoutConstraint activateConstraints:@[
            [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4.0],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4.0],
            [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }

    NSTextField *tf = cell.textField;
    tf.font = theme.body;

    if ([tableColumn.identifier isEqualToString:kColIndex]) {
        tf.alignment = NSTextAlignmentRight;
        tf.textColor = theme.mut;
        tf.font = theme.mono ?: theme.small;
        tf.stringValue = [NSString stringWithFormat:@"%ld", (long)(row + 1)];
    } else if ([tableColumn.identifier isEqualToString:kColTitle]) {
        tf.alignment = NSTextAlignmentLeft;
        tf.textColor = theme.text;
        tf.stringValue = t.title.length ? t.title : @"-";
    } else if ([tableColumn.identifier isEqualToString:kColArtist]) {
        tf.alignment = NSTextAlignmentLeft;
        tf.textColor = theme.mut;
        tf.stringValue = t.artist.length ? t.artist : @"-";
    } else if ([tableColumn.identifier isEqualToString:kColAlbum]) {
        tf.alignment = NSTextAlignmentLeft;
        tf.textColor = theme.mut;
        tf.stringValue = t.album.length ? t.album : @"-";
    } else if ([tableColumn.identifier isEqualToString:kColDuration]) {
        tf.alignment = NSTextAlignmentRight;
        tf.textColor = theme.mut;
        tf.font = theme.mono ?: theme.body;
        tf.stringValue = RLPFmtDuration(t.duration);
    }

    return cell;
}

#pragma mark - 排序（web track-sort，客户端排序与 web 同口径）

- (void)onSortChanged:(NSPopUpButton *)sender {
    id rep = sender.selectedItem.representedObject;
    _trackSort = [rep isKindOfClass:[NSString class]] ? rep : @"default";
    [self applyTrackSort];
    [_tableView reloadData];
}

/// 与 web 的排序键逐条对齐（web 只排**当前已加载的这一片**，不改变后端分页）。
- (void)applyTrackSort {
    if (!_tracks.count || [_trackSort isEqualToString:@"default"]) return;
    NSArray *sorted = [_tracks sortedArrayUsingComparator:^NSComparisonResult(RLPTrack *a, RLPTrack *b) {
        if ([self->_trackSort isEqualToString:@"title"])
            return [(a.title ?: @"") caseInsensitiveCompare:(b.title ?: @"")];
        if ([self->_trackSort isEqualToString:@"artist"])
            return [(a.artist ?: @"") caseInsensitiveCompare:(b.artist ?: @"")];
        if ([self->_trackSort isEqualToString:@"album"])
            return [(a.album ?: @"") caseInsensitiveCompare:(b.album ?: @"")];
        if ([self->_trackSort isEqualToString:@"dur"])
            return a.duration < b.duration ? NSOrderedAscending : (a.duration > b.duration ? NSOrderedDescending : NSOrderedSame);
        if ([self->_trackSort isEqualToString:@"year"]) {
            // 曲目没有 year 字段（web 用 a.year，后端 search 不回该键）⟹ 保持原序，不编造。
            return NSOrderedSame;
        }
        if ([self->_trackSort isEqualToString:@"fav"]) {
            const BOOL fa = [self->_favoritePaths containsObject:a.path];
            const BOOL fb = [self->_favoritePaths containsObject:b.path];
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
    const BOOL was = [_favoritePaths containsObject:t.path];
    NSString *url = [NSString stringWithFormat:@"/api/fav?file=%@&on=%d", RLPEnc(t.path), was ? 0 : 1];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:url body:@"" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            if (was) [self_->_favoritePaths removeObject:t.path];
            else [self_->_favoritePaths addObject:t.path];
            [self_->_tableView reloadData];
            RLPToast(was ? RLPTr(@"已取消收藏") : RLPTr(@"已收藏"));
        } else {
            RLPToast(RLPTr(@"收藏失败"));
        }
    }];
}

- (void)onRowAdd:(NSButton *)sender {
    const NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)_tracks.count) return;
    RLPEnqueuePath(_tracks[(NSUInteger)row].path);
    RLPToast(RLPTr(@"已加入队列"));
}

@end