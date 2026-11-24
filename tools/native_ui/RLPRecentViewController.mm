// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later

#import "RLPRecentViewController.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPSupport.h"
#import "RLPTrackActions.h"
#import "RLPTheme.h"

// web 最近播放（ui_script.h:3595-3599 的 grid-template-columns:34px 1fr 160px 92px）：
// 4 列（#/标题/艺术家/专辑），**没有时长列**；列表也**没有表头行**（行模板直接贴进 #list）。
// 旧原生多出「时长」列且挂了表头视图（P12）。
static const CGFloat kRecentIndexW = 34.0;
static const CGFloat kRecentArtistW = 160.0;
static const CGFloat kRecentAlbumW = 92.0;
static const CGFloat kRecentTitleMinW = 120.0;
static const CGFloat kRecentRowH = 34.0;

@interface RLPRecentRowView : RLPHoverRowView
@end

@implementation RLPRecentRowView
- (void)drawBackgroundInRect:(NSRect)dirtyRect {
    [super drawBackgroundInRect:dirtyRect];
    [RLPTheme.current.line setFill];
    const CGFloat y = self.isFlipped ? NSMaxY(self.bounds) - 1.0 : 0.0;
    NSRectFill(NSMakeRect(0, y, NSWidth(self.bounds), 1.0));
}
@end

@interface RLPRecentViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSTextField *emptyLabel;   // web：还没有播放记录
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSMutableArray<RLPTrack *> *tracks;
@property (nonatomic, assign) BOOL hasLoaded;
@property (nonatomic, assign) BOOL lastLoadFailed;
@property (nonatomic, assign) NSUInteger loadSeq;
@property (nonatomic, assign) BOOL layingOutColumns;
@end

@implementation RLPRecentViewController

- (instancetype)init {
    return [super initWithTitle:RLPTr(@"最近播放")];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)buildContent {
    RLPTheme *t = [RLPTheme current];
    NSView *host = self.contentView;

    _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scrollView.drawsBackground = NO;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.hasHorizontalScroller = NO;
    _scrollView.autohidesScrollers = YES;
    _scrollView.hidden = YES;
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:_scrollView];

    _tableView = [[RLPTrackActionTableView alloc] initWithFrame:NSZeroRect];
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.rowHeight = kRecentRowH;
    _tableView.intercellSpacing = NSMakeSize(8.0, 0.0);
    // 右键 = 与 web 一致的完整曲目动作（播放/入队/收藏/存歌单/体检/对比）
    {
        __weak __typeof__(self) ws = self;
        ((RLPTrackActionTableView *)_tableView).pathForRow = ^NSString *(NSInteger row) {
            __typeof__(self) s = ws;
            if (!s) return nil;
            NSArray<RLPTrack *> *ts = s.tracks;
            if (row < 0 || row >= (NSInteger)ts.count) return nil;
            return ts[(NSUInteger)row].path;
        };
    }
    // web 最近列表没有表头行（.trow 行模板直接进 #list，不画 head 的列名）。
    _tableView.headerView = nil;
    _tableView.backgroundColor = [NSColor clearColor];
    _tableView.usesAlternatingRowBackgroundColors = NO;
    if (@available(macOS 11.0, *)) _tableView.style = NSTableViewStylePlain;
    _tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    // 与 web 版一致：**单击**即触发（web 的行 onclick 就是单击）。
    _tableView.action = @selector(onDoubleClick:);
    _tableView.doubleAction = @selector(onDoubleClick:);
    _tableView.target = self;

    // P12：web 最近播放 4 列（#/标题/艺术家/专辑），旧原生的第 5 列「时长」是 web 不存在的多余列。
    NSArray<NSString *> *headers = @[RLPTr(@"#"), RLPTr(@"标题"), RLPTr(@"艺术家"), RLPTr(@"专辑")];
    for (int i = 0; i < 4; i++) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"col%d", i]];
        col.title = headers[i];
        col.resizingMask = NSTableColumnNoResizing;
        switch (i) {
            case 0:
                col.width = kRecentIndexW; col.minWidth = kRecentIndexW; col.maxWidth = kRecentIndexW;
                break;
            case 1:
                col.width = 420; col.minWidth = 80.0; col.maxWidth = 10000;
                break;
            case 2:
                col.width = kRecentArtistW; col.minWidth = 80.0; col.maxWidth = kRecentArtistW;
                break;
            default:
                col.width = kRecentAlbumW; col.minWidth = 60.0; col.maxWidth = kRecentAlbumW;
                break;
        }
        [_tableView addTableColumn:col];
    }
    // 不交给 AppKit 均匀拉伸：标题列按 web 的 1fr 自己吃剩余宽度（见 -layoutRecentColumns）。
    _tableView.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;

    _scrollView.documentView = _tableView;
    _scrollView.contentView.postsFrameChangedNotifications = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onClipFrameChanged:)
                                                 name:NSViewFrameDidChangeNotification
                                               object:_scrollView.contentView];

    _emptyLabel = RLPLabel(RLPTr(@"还没有播放记录"), [NSFont systemFontOfSize:13], t.mut);
    _emptyLabel.identifier = @"recent.empty";
    _emptyLabel.alignment = NSTextAlignmentCenter;
    _emptyLabel.maximumNumberOfLines = 0;
    _emptyLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [_emptyLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                          forOrientation:NSLayoutConstraintOrientationHorizontal];
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyLabel.hidden = YES;
    [host addSubview:_emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_emptyLabel.centerXAnchor constraintEqualToAnchor:host.centerXAnchor],
        [_emptyLabel.centerYAnchor constraintEqualToAnchor:host.centerYAnchor],
        [_emptyLabel.widthAnchor constraintLessThanOrEqualToAnchor:host.widthAnchor constant:-40],

        [_scrollView.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:16],
        [_scrollView.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-16],
        [_scrollView.topAnchor constraintEqualToAnchor:host.topAnchor constant:8],
        [_scrollView.bottomAnchor constraintEqualToAnchor:host.bottomAnchor constant:-12],
    ]];

    _tracks = [NSMutableArray array];
    [self applyTheme];
}

/// web .trow 的标题列是 1fr：随页面宽度伸缩，其余三列固定（34 / 160 / 92）。
- (void)layoutRecentColumns {
    if (!_tableView || _layingOutColumns) return;
    CGFloat availW = _scrollView ? NSWidth(_scrollView.contentView.bounds) : 0.0;
    if (!(availW > 1.0)) {
        const CGFloat cw = NSWidth(self.contentView.bounds);
        if (cw > 32.0) availW = cw - 32.0;
    }
    if (!(availW > 1.0)) return;

    _layingOutColumns = YES;
    NSTableColumn *colIdx = nil, *colTitle = nil, *colArtist = nil, *colAlbum = nil;
    for (NSTableColumn *c in _tableView.tableColumns) {
        if ([c.identifier isEqualToString:@"col0"]) colIdx = c;
        else if ([c.identifier isEqualToString:@"col1"]) colTitle = c;
        else if ([c.identifier isEqualToString:@"col2"]) colArtist = c;
        else if ([c.identifier isEqualToString:@"col3"]) colAlbum = c;
    }
    if (colIdx && colTitle && colArtist && colAlbum) {
        const CGFloat spacing = _tableView.intercellSpacing.width * (CGFloat)_tableView.tableColumns.count;
        const CGFloat budget = MAX(120.0, availW - spacing);
        CGFloat artistW = kRecentArtistW;
        CGFloat albumW = kRecentAlbumW;
        CGFloat fixed = kRecentIndexW + artistW + albumW;
        if (budget - fixed < kRecentTitleMinW) {
            const CGFloat deficit = kRecentTitleMinW - (budget - fixed);
            const CGFloat shrinkArtist = MIN(deficit * 0.7, MAX(0.0, artistW - 80.0));
            artistW -= shrinkArtist;
            const CGFloat rem = deficit - shrinkArtist;
            const CGFloat shrinkAlbum = MIN(rem, MAX(0.0, albumW - 60.0));
            albumW -= shrinkAlbum;
            fixed = kRecentIndexW + artistW + albumW;
        }
        colIdx.width = kRecentIndexW;
        colTitle.width = MAX(80.0, budget - fixed);
        colArtist.width = artistW;
        colAlbum.width = albumW;
        if (_scrollView && fabs(NSWidth(_tableView.frame) - availW) > 0.5) {
            NSRect tf = _tableView.frame;
            tf.size.width = availW;
            _tableView.frame = tf;
        }
        [_tableView tile];
    }
    _layingOutColumns = NO;
}

- (void)viewDidLayout {
    [super viewDidLayout];
    [self layoutRecentColumns];
}

- (void)onClipFrameChanged:(NSNotification *)note {
    (void)note;
    [self layoutRecentColumns];
}

- (void)activate {
    [super activate];
    [self reloadData];
}

- (void)reloadData {
    const NSUInteger seq = ++self.loadSeq;
    self.lastLoadFailed = NO;
    if (![RLPCoreClient shared].started) {
        [self setSubtitle:RLPTr(@"核心未启动")];
        [_tracks removeAllObjects];
        [_tableView reloadData];
        _scrollView.hidden = YES;
        _emptyLabel.stringValue = RLPTr(@"核心未启动");
        _emptyLabel.hidden = NO;
        return;
    }

    __weak RLPRecentViewController *weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/recent" completion:^(NSDictionary * _Nullable json) {
        RLPRecentViewController *self_ = weakSelf;
        if (!self_ || seq != self_.loadSeq) return;

        if (!json || ![json[@"ok"] boolValue]) {
            self_.lastLoadFailed = YES;
            [self_ setSubtitle:RLPTr(@"加载失败")];
            if (self_.tracks.count == 0) {
                self_.scrollView.hidden = YES;
                self_.emptyLabel.stringValue = RLPTr(@"加载失败");
                self_.emptyLabel.hidden = NO;
            }
            return;
        }

        NSArray<RLPTrack *> *tracks = [RLPTrack tracksFromJSON:json key:nil];
        self_.hasLoaded = YES;
        self_.lastLoadFailed = NO;
        [self_.tracks removeAllObjects];
        [self_.tracks addObjectsFromArray:tracks];
        [self_.tableView reloadData];
        [self_ setSubtitle:[NSString stringWithFormat:RLPTr(@"%ld 首"), (long)tracks.count]];
        self_.emptyLabel.stringValue = RLPTr(@"还没有播放记录");
        self_.emptyLabel.hidden = self_.tracks.count > 0;
        self_.scrollView.hidden = (self_.tracks.count == 0);
        [self_.view setNeedsLayout:YES];
        [self_ layoutRecentColumns];
    }];
}

- (void)applyTheme {
    [super applyTheme];
    if (!self.isViewLoaded) return;
    RLPTheme *t = [RLPTheme current];
    _emptyLabel.textColor = t.mut;
    _tableView.backgroundColor = [NSColor clearColor];

    NSIndexSet *sel = [_tableView.selectedRowIndexes copy];
    NSPoint origin = _scrollView ? _scrollView.contentView.bounds.origin : NSZeroPoint;
    [_tableView reloadData];
    if (sel.count) [_tableView selectRowIndexes:sel byExtendingSelection:NO];
    if (_scrollView) {
        [_scrollView.contentView scrollToPoint:origin];
        [_scrollView reflectScrolledClipView:_scrollView.contentView];
    }
}

#pragma mark - TableView

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return (NSInteger)_tracks.count;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    (void)tableView; (void)row;
    RLPRecentRowView *rv = [[RLPRecentRowView alloc] initWithFrame:NSZeroRect];
    rv.hoverColor = [RLPTheme current].hov;
    return rv;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_tracks.count) return nil;
    RLPTrack *track = _tracks[(NSUInteger)row];
    RLPTheme *t = [RLPTheme current];
    NSString *identifier = tableColumn.identifier;
    NSString *reuse = [identifier stringByAppendingString:@".cell"];

    NSTableCellView *cell = [tableView makeViewWithIdentifier:reuse owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, MAX(20.0, tableColumn.width), kRecentRowH)];
        cell.identifier = reuse;
        NSTextField *label = [NSTextField labelWithString:@""];
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        label.maximumNumberOfLines = 1;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:label];
        cell.textField = label;
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:6.0],
            [label.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-6.0],
            [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }

    NSTextField *label = cell.textField;
    label.toolTip = nil;
    if ([identifier isEqualToString:@"col0"]) {
        label.alignment = NSTextAlignmentRight;
        label.font = t.mono ?: t.small;
        label.textColor = t.mut2;
        label.stringValue = [NSString stringWithFormat:@"%ld", (long)row + 1];
    } else if ([identifier isEqualToString:@"col1"]) {
        NSString *title = track.title.length ? track.title : (track.path.lastPathComponent.stringByDeletingPathExtension ?: track.path.lastPathComponent ?: @"");
        label.alignment = NSTextAlignmentLeft;
        label.font = [NSFont systemFontOfSize:12.5];
        label.textColor = t.text;
        label.stringValue = title;
        label.toolTip = track.path.length ? track.path : title;
    } else if ([identifier isEqualToString:@"col2"]) {
        NSString *artist = track.artist.length ? track.artist : RLPTr(@"未知");
        label.alignment = NSTextAlignmentLeft;
        label.font = [NSFont systemFontOfSize:12.0];
        label.textColor = t.text2;
        label.stringValue = artist;
        label.toolTip = artist;
    } else if ([identifier isEqualToString:@"col3"]) {
        NSString *album = track.album.length ? track.album : RLPTr(@"未知");
        label.alignment = NSTextAlignmentLeft;
        label.font = [NSFont systemFontOfSize:12.0];
        label.textColor = t.mut2;
        label.stringValue = album;
        label.toolTip = album;
    } else {
        label.stringValue = @"";
    }
    return cell;
}

/// 共享右键菜单的动作入口。
- (void)rlp_trackMenuAction:(NSMenuItem *)sender {
    RLPHandleTrackAction(sender, self.view);
}

- (void)onDoubleClick:(id)sender {
    (void)sender;
    NSInteger row = [_tableView clickedRow];
    if (row < 0 || row >= (NSInteger)_tracks.count) return;
    RLPTrack *track = _tracks[(NSUInteger)row];
    RLPPlayPath(track.path);
}

- (void)applyLanguage {
    self.pageTitle = RLPTr(@"最近播放");
    if (!self.isViewLoaded) return;
    NSArray<NSString *> *headers = @[RLPTr(@"#"), RLPTr(@"标题"), RLPTr(@"艺术家"), RLPTr(@"专辑")];
    for (NSUInteger i = 0; i < _tableView.tableColumns.count && i < headers.count; ++i) {
        _tableView.tableColumns[i].title = headers[i];
    }
    if (![RLPCoreClient shared].started) {
        [self setSubtitle:RLPTr(@"核心未启动")];
        _emptyLabel.stringValue = RLPTr(@"核心未启动");
    } else if (self.lastLoadFailed && _tracks.count == 0) {
        [self setSubtitle:RLPTr(@"加载失败")];
        _emptyLabel.stringValue = RLPTr(@"加载失败");
    } else {
        _emptyLabel.stringValue = RLPTr(@"还没有播放记录");
        if (self.hasLoaded) {
            [self setSubtitle:[NSString stringWithFormat:RLPTr(@"%ld 首"), (long)_tracks.count]];
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
