// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPTracksViewController.mm — 曲目列表页（纯 AppKit / NSTableView）
//
#import "RLPTracksViewController.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

static NSString * const kColIndex = @"ColIndex";
static NSString * const kColTitle = @"ColTitle";
static NSString * const kColArtist = @"ColArtist";
static NSString * const kColAlbum = @"ColAlbum";
static NSString * const kColDuration = @"ColDuration";

#pragma mark - 支持右键选中行的表格视图

@interface RLPTrackTableView : NSTableView
@end

@implementation RLPTrackTableView

- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = [self rowAtPoint:p];
    if (row >= 0 && row < self.numberOfRows) {
        if (![self isRowSelected:row]) {
            [self selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
        }
        return self.menu;
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
}

- (instancetype)init {
    self = [super initWithTitle:RLPTr(@"曲目")];
    if (self) {
        _tracks = [NSMutableArray array];
        _limit = 300;
        _totalCount = 0;
        _hasLoaded = NO;
        _searchSeq = 0;
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

    // 2. 表格与滚动容器
    _tableView = [[RLPTrackTableView alloc] initWithFrame:NSZeroRect];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 28.0;
    _tableView.intercellSpacing = NSMakeSize(0, 0);
    _tableView.headerView = [[NSTableHeaderView alloc] initWithFrame:NSZeroRect];
    _tableView.backgroundColor = [NSColor clearColor];
    _tableView.target = self;
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

    // 表头：# / 标题 / 艺术家 / 专辑 / 时长
    NSTableColumn *colIndex = [[NSTableColumn alloc] initWithIdentifier:kColIndex];
    colIndex.title = @"#";
    colIndex.width = 44.0;
    colIndex.minWidth = 36.0;
    colIndex.maxWidth = 60.0;
    colIndex.resizingMask = NSTableColumnNoResizing;
    [_tableView addTableColumn:colIndex];

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

#pragma mark - 双击与右键菜单动作

- (void)onDoubleClickRow:(id)sender {
    (void)sender;
    NSInteger row = _tableView.clickedRow;
    if (row < 0 || row >= (NSInteger)_tracks.count) return;
    RLPTrack *t = _tracks[(NSUInteger)row];
    if (t.path.length) {
        RLPPlayPath(t.path);
    }
}

- (void)onPlayContextMenu:(id)sender {
    (void)sender;
    NSInteger row = _tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)_tracks.count) return;
    RLPTrack *t = _tracks[(NSUInteger)row];
    if (t.path.length) {
        RLPPlayPath(t.path);
    }
}

- (void)onEnqueueContextMenu:(id)sender {
    (void)sender;
    NSInteger row = _tableView.selectedRow;
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

@end
