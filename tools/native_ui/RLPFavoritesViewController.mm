// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later

#import "RLPFavoritesViewController.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPTheme.h"
#import "RLPSupport.h"
#import "RLPTrackActions.h"
#import <objc/runtime.h>

// web .favhead 第 5 列：行尾心形（实心 ⟹ 点一下取消收藏）。
static NSString * const kFavColHeart = @"ColFavHeart";
static const void *kRLPFavUnfavPathKey = &kRLPFavUnfavPathKey;
// web .favhead 网格（ui_script.h:3703-3721）：34px # / 1fr 标题 / 180px 艺术家 / 200px 专辑 / 34px 心。
// **没有时长列**——旧原生多出的「时长」列在 web 列集里不存在（P12）。
static const CGFloat kFavIndexW = 34.0;
static const CGFloat kFavArtistW = 180.0;
static const CGFloat kFavAlbumW = 200.0;
static const CGFloat kFavHeartW = 34.0;
static const CGFloat kFavTitleMinW = 120.0;
static const CGFloat kFavRowH = 36.0;
static const CGFloat kFavHeaderH = 26.0;

static NSString *RLPFavDisplayTitle(RLPTrack *t) {
    if (t.title.length) return t.title;
    NSString *stem = t.path.lastPathComponent.stringByDeletingPathExtension;
    return stem.length ? stem : (t.path.lastPathComponent ?: @"");
}

static NSString *RLPFavDisplayAlbum(RLPTrack *t) {
    if (t.album.length) return t.album;
    NSString *parent = t.path.stringByDeletingLastPathComponent.lastPathComponent;
    if (!parent.length || [parent isEqualToString:@"remote-cache"] || [parent isEqualToString:@"/"]) {
        return @"";
    }
    return parent;
}

@interface RLPFavHeaderView : NSTableHeaderView
@end

@implementation RLPFavHeaderView
- (void)drawRect:(NSRect)dirtyRect {
    RLPTheme *t = [RLPTheme current];
    [t.bg setFill];
    NSRectFill(dirtyRect);
    [t.line setFill];
    const CGFloat lineY = self.isFlipped ? NSMaxY(self.bounds) - 1.0 : 0.0;
    NSRectFill(NSMakeRect(0, lineY, NSWidth(self.bounds), 1.0));

    NSTableView *tv = self.tableView;
    if (!tv) return;
    NSMutableParagraphStyle *leftStyle = [[NSMutableParagraphStyle alloc] init];
    leftStyle.lineBreakMode = NSLineBreakByTruncatingTail;
    leftStyle.alignment = NSTextAlignmentLeft;
    NSMutableParagraphStyle *rightStyle = [[NSMutableParagraphStyle alloc] init];
    rightStyle.lineBreakMode = NSLineBreakByTruncatingTail;
    rightStyle.alignment = NSTextAlignmentRight;
    NSDictionary *baseAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: t.mut2,
    };
    for (NSInteger i = 0; i < (NSInteger)tv.tableColumns.count; ++i) {
        NSTableColumn *col = tv.tableColumns[(NSUInteger)i];
        if (col.hidden) continue;
        NSString *title = col.title ?: @"";
        if (!title.length) continue;
        NSRect hr = [self headerRectOfColumn:i];
        if (NSWidth(hr) <= 4.0) continue;
        NSMutableDictionary *attrs = [baseAttrs mutableCopy];
        attrs[NSParagraphStyleAttributeName] = (i == 0) ? rightStyle : leftStyle;
        NSRect tr = NSInsetRect(hr, 6.0, 0.0);
        tr.origin.y = floor((NSHeight(hr) - 14.0) * 0.5);
        tr.size.height = 15.0;
        [title drawInRect:tr withAttributes:attrs];
    }
}
@end

@interface RLPFavRowView : RLPHoverRowView
@end

@implementation RLPFavRowView
- (void)drawBackgroundInRect:(NSRect)dirtyRect {
    [super drawBackgroundInRect:dirtyRect];
    [RLPTheme.current.line setFill];
    const CGFloat y = self.isFlipped ? NSMaxY(self.bounds) - 1.0 : 0.0;
    NSRectFill(NSMakeRect(0, y, NSWidth(self.bounds), 1.0));
}
@end

@interface RLPFavoritesViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSMutableArray<RLPTrack *> *tracks;
@property (nonatomic, strong) NSView *hintBanner;        // web .favhint 圆角浅底条
@property (nonatomic, strong) NSTextField *hintLabel;    // web .favhint：双击顺序播放整个最爱列表
@property (nonatomic, strong) NSTextField *emptyLabel;   // web 空态：还没有收藏 + 怎么做
@property (nonatomic, assign) BOOL hasLoaded;
@property (nonatomic, assign) BOOL lastLoadFailed;
@property (nonatomic, assign) NSUInteger loadSeq;
@property (nonatomic, assign) NSUInteger actionEpoch;
@property (nonatomic, assign) BOOL layingOutColumns;
@property (nonatomic, assign) BOOL unfavInFlight;
@property (nonatomic, assign) BOOL needsExternalReload;
@end

@implementation RLPFavoritesViewController

- (instancetype)init {
    self = [super initWithTitle:RLPTr(@"我的最爱")];
    if (self) {
        _tracks = [NSMutableArray array];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onExternalFavoritesChanged:)
                                                     name:RLPFavoritesChangedNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)onExternalFavoritesChanged:(NSNotification *)note {
    if (note.object == self) return;
    if (![RLPCoreClient shared].started) return;
    if (!self.isViewLoaded) {
        self.needsExternalReload = YES;
        return;
    }
    [self reloadData];
}

- (void)buildContent {
    RLPTheme *t = [RLPTheme current];
    NSView *host = self.contentView;

    // web .favhint：圆角提示条（不压在表头上，空表时整条隐藏）。
    _hintBanner = [[NSView alloc] initWithFrame:NSZeroRect];
    _hintBanner.identifier = @"fav.hintBanner";
    _hintBanner.wantsLayer = YES;
    _hintBanner.layer.cornerRadius = t.rSm;
    _hintBanner.layer.borderWidth = 1.0;
    _hintBanner.layer.backgroundColor = t.hov.CGColor;
    _hintBanner.layer.borderColor = t.line.CGColor;
    _hintBanner.hidden = YES;
    _hintBanner.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:_hintBanner];

    _hintLabel = RLPLabel(@"", [NSFont systemFontOfSize:12], t.text2);
    _hintLabel.identifier = @"fav.hint";
    _hintLabel.maximumNumberOfLines = 0;
    _hintLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [_hintLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];
    _hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_hintBanner addSubview:_hintLabel];

    _tableView = [[RLPTrackActionTableView alloc] initWithFrame:NSZeroRect];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = kFavRowH;
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
    _tableView.headerView = [[RLPFavHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 0, kFavHeaderH)];
    // 同队列页：web 无斑马底；空表时交替色会在空白区域铺出条带。
    _tableView.usesAlternatingRowBackgroundColors = NO;
    _tableView.backgroundColor = [NSColor clearColor];
    if (@available(macOS 11.0, *)) _tableView.style = NSTableViewStylePlain;
    _tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;

    // P12：web .favhead 是 5 列（34px # / 1fr 标题 / 180px 艺术家 / 200px 专辑 / 34px 心），
    // 旧原生的第 5 列「时长」是 web 不存在的多余列（网格模板里没有 dur）。
    NSArray *cols = @[@"#", RLPTr(@"标题"), RLPTr(@"艺术家"), RLPTr(@"专辑"), @""];
    for (NSInteger i = 0; i < (NSInteger)cols.count; i++) {
        NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"col%ld", (long)i]];
        c.title = cols[i];
        c.resizingMask = NSTableColumnNoResizing;
        switch (i) {
            case 0:
                c.width = kFavIndexW; c.minWidth = kFavIndexW; c.maxWidth = kFavIndexW;
                break;
            case 1:
                c.width = 420; c.minWidth = 80.0; c.maxWidth = 10000;
                break;
            case 2:
                c.width = kFavArtistW; c.minWidth = 80.0; c.maxWidth = kFavArtistW;
                break;
            case 3:
                c.width = kFavAlbumW; c.minWidth = 80.0; c.maxWidth = kFavAlbumW;
                break;
            default:
                c.identifier = kFavColHeart;
                c.width = kFavHeartW; c.minWidth = kFavHeartW; c.maxWidth = kFavHeartW;
                break;
        }
        [_tableView addTableColumn:c];
    }
    // 不交给 AppKit 均匀拉伸：标题列按 web 的 1fr 自己吃剩余宽度（见 -layoutFavColumns）。
    _tableView.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;

    _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scrollView.documentView = _tableView;
    _scrollView.drawsBackground = NO;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.hasHorizontalScroller = NO;
    _scrollView.autohidesScrollers = YES;
    _scrollView.hidden = YES;
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:_scrollView];

    _scrollView.contentView.postsFrameChangedNotifications = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onClipFrameChanged:)
                                                 name:NSViewFrameDidChangeNotification
                                               object:_scrollView.contentView];

    // 双击播放（P1）：单击**只选中**，绝不整列开播。
    _tableView.action = NULL;
    _tableView.doubleAction = @selector(onDoubleClick:);
    _tableView.target = self;

    // web 空态：还没有收藏 / 在曲目行或单曲页点心形，就会出现在这里
    _emptyLabel = RLPLabel([RLPTr(@"还没有收藏") stringByAppendingFormat:@"\n%@", RLPTr(@"在曲目行或单曲页点心形，就会出现在这里")],
                           [NSFont systemFontOfSize:13], t.mut);
    _emptyLabel.identifier = @"fav.empty";
    _emptyLabel.alignment = NSTextAlignmentCenter;
    _emptyLabel.maximumNumberOfLines = 0;
    _emptyLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [_emptyLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                          forOrientation:NSLayoutConstraintOrientationHorizontal];
    _emptyLabel.hidden = YES;
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:_emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_hintLabel.topAnchor constraintEqualToAnchor:_hintBanner.topAnchor constant:8],
        [_hintLabel.bottomAnchor constraintEqualToAnchor:_hintBanner.bottomAnchor constant:-8],
        [_hintLabel.leadingAnchor constraintEqualToAnchor:_hintBanner.leadingAnchor constant:16],
        [_hintLabel.trailingAnchor constraintEqualToAnchor:_hintBanner.trailingAnchor constant:-16],

        [_hintBanner.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:16],
        [_hintBanner.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-16],
        [_hintBanner.topAnchor constraintEqualToAnchor:host.topAnchor constant:8],

        [_scrollView.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:16],
        [_scrollView.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-16],
        [_scrollView.topAnchor constraintEqualToAnchor:_hintBanner.bottomAnchor constant:10],
        [_scrollView.bottomAnchor constraintEqualToAnchor:host.bottomAnchor constant:-12],

        [_emptyLabel.centerXAnchor constraintEqualToAnchor:host.centerXAnchor],
        [_emptyLabel.centerYAnchor constraintEqualToAnchor:host.centerYAnchor],
        [_emptyLabel.widthAnchor constraintLessThanOrEqualToAnchor:host.widthAnchor constant:-40],
    ]];

    [self applyTheme];
}

/// web .favhead 的标题列是 1fr：随页面宽度伸缩，其余四列固定（34 / 180 / 200 / 34）。
- (void)layoutFavColumns {
    if (!_tableView || _layingOutColumns) return;
    CGFloat availW = _scrollView ? NSWidth(_scrollView.contentView.bounds) : 0.0;
    if (!(availW > 1.0)) {
        const CGFloat cw = NSWidth(self.contentView.bounds);
        if (cw > 32.0) availW = cw - 32.0;
    }
    if (!(availW > 1.0)) return;

    _layingOutColumns = YES;
    NSTableColumn *colIdx = nil, *colTitle = nil, *colArtist = nil, *colAlbum = nil, *colHeart = nil;
    for (NSTableColumn *c in _tableView.tableColumns) {
        if ([c.identifier isEqualToString:@"col0"]) colIdx = c;
        else if ([c.identifier isEqualToString:@"col1"]) colTitle = c;
        else if ([c.identifier isEqualToString:@"col2"]) colArtist = c;
        else if ([c.identifier isEqualToString:@"col3"]) colAlbum = c;
        else if ([c.identifier isEqualToString:kFavColHeart]) colHeart = c;
    }
    if (colIdx && colTitle && colArtist && colAlbum && colHeart) {
        const CGFloat spacing = _tableView.intercellSpacing.width * (CGFloat)_tableView.tableColumns.count;
        const CGFloat budget = MAX(120.0, availW - spacing);
        CGFloat artistW = kFavArtistW;
        CGFloat albumW = kFavAlbumW;
        CGFloat fixed = kFavIndexW + artistW + albumW + kFavHeartW;
        if (budget - fixed < kFavTitleMinW) {
            const CGFloat deficit = kFavTitleMinW - (budget - fixed);
            const CGFloat shrinkAlbum = MIN(deficit * 0.55, MAX(0.0, albumW - 80.0));
            albumW -= shrinkAlbum;
            const CGFloat remDeficit = deficit - shrinkAlbum;
            const CGFloat shrinkArtist = MIN(remDeficit, MAX(0.0, artistW - 80.0));
            artistW -= shrinkArtist;
            fixed = kFavIndexW + artistW + albumW + kFavHeartW;
        }
        const CGFloat titleW = MAX(80.0, budget - fixed);
        colIdx.width = kFavIndexW;
        colTitle.width = titleW;
        colArtist.width = artistW;
        colAlbum.width = albumW;
        colHeart.width = kFavHeartW;
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
    [self layoutFavColumns];
}

- (void)onClipFrameChanged:(NSNotification *)note {
    (void)note;
    [self layoutFavColumns];
}

- (void)activate {
    [super activate];
    self.needsExternalReload = NO;
    [self reloadData];
}

- (void)deactivate {
    ++self.actionEpoch;
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    [self deactivate];
}

- (void)updateListChrome {
    const BOOL started = [RLPCoreClient shared].started;
    const NSInteger n = (NSInteger)_tracks.count;
    if (!started) {
        [self setSubtitle:RLPTr(@"核心未启动")];
        _hintLabel.stringValue = @"";
        _hintBanner.hidden = YES;
        _scrollView.hidden = YES;
        _emptyLabel.stringValue = RLPTr(@"核心未启动");
        _emptyLabel.hidden = NO;
        return;
    }
    if (n == 0) {
        if (self.lastLoadFailed) {
            [self setSubtitle:RLPTr(@"加载失败")];
            _hintLabel.stringValue = @"";
            _hintBanner.hidden = YES;
            _scrollView.hidden = YES;
            _emptyLabel.stringValue = RLPTr(@"加载失败");
            _emptyLabel.hidden = NO;
            return;
        }
        if (self.hasLoaded) {
            [self setSubtitle:[NSString stringWithFormat:RLPTr(@"%ld 首"), 0L]];
        }
        _hintLabel.stringValue = @"";
        _hintBanner.hidden = YES;
        _scrollView.hidden = YES;
        _emptyLabel.stringValue = [RLPTr(@"还没有收藏") stringByAppendingFormat:@"\n%@",
            RLPTr(@"在曲目行或单曲页点心形，就会出现在这里")];
        _emptyLabel.hidden = !self.hasLoaded;
        return;
    }
    [self setSubtitle:[NSString stringWithFormat:RLPTr(@"%ld 首"), (long)n]];
    _hintLabel.stringValue = [NSString stringWithFormat:RLPTr(@"双击任意一首，从这首开始顺序播放整个最爱列表（%ld 首）"), (long)n];
    _hintBanner.hidden = NO;
    _scrollView.hidden = NO;
    _emptyLabel.hidden = YES;
}

- (void)reloadData {
    const NSUInteger seq = ++self.loadSeq;
    self.needsExternalReload = NO;
    self.lastLoadFailed = NO;
    if (![RLPCoreClient shared].started) {
        [self.tracks removeAllObjects];
        [_tableView reloadData];
        [self updateListChrome];
        return;
    }

    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/fav/list?meta=1" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.loadSeq) return;
        if (!json || ![json[@"ok"] boolValue]) {
            self_.lastLoadFailed = YES;
            [self_ setSubtitle:RLPTr(@"加载失败")];
            if (self_.tracks.count == 0) {
                self_.hintBanner.hidden = YES;
                self_.scrollView.hidden = YES;
                self_.emptyLabel.stringValue = RLPTr(@"加载失败");
                self_.emptyLabel.hidden = NO;
            }
            return;
        }

        NSArray *files = [json[@"files"] isKindOfClass:[NSArray class]] ? json[@"files"] : @[];
        NSMutableArray *tracks = [NSMutableArray array];
        for (id item in files) {
            RLPTrack *t = [RLPTrack trackFromJSON:item];
            if (t) [tracks addObject:t];
        }
        self_.hasLoaded = YES;
        self_.lastLoadFailed = NO;
        self_.tracks = tracks;
        [self_.tableView reloadData];
        [self_ updateListChrome];
        [self_.view setNeedsLayout:YES];
        [self_ layoutFavColumns];
    }];
}

- (void)applyTheme {
    [super applyTheme];
    if (!self.isViewLoaded) return;
    RLPTheme *t = [RLPTheme current];
    _hintBanner.layer.cornerRadius = t.rSm;
    _hintBanner.layer.backgroundColor = t.hov.CGColor;
    _hintBanner.layer.borderColor = t.line.CGColor;
    _hintLabel.textColor = t.text2;
    _emptyLabel.textColor = t.mut;
    _tableView.backgroundColor = [NSColor clearColor];
    [_tableView.headerView setNeedsDisplay:YES];

    NSIndexSet *sel = [_tableView.selectedRowIndexes copy];
    NSPoint origin = _scrollView ? _scrollView.contentView.bounds.origin : NSZeroPoint;
    [_tableView reloadData];
    if (sel.count) [_tableView selectRowIndexes:sel byExtendingSelection:NO];
    if (_scrollView) {
        [_scrollView.contentView scrollToPoint:origin];
        [_scrollView reflectScrolledClipView:_scrollView.contentView];
    }
}

#pragma mark - Actions

/// 共享右键菜单的动作入口。
- (void)rlp_trackMenuAction:(NSMenuItem *)sender {
    RLPHandleTrackAction(sender, self.view);
}

- (void)onDoubleClick:(id)sender {
    (void)sender;
    NSInteger row = [_tableView clickedRow];
    if (row < 0 || row >= (NSInteger)_tracks.count) return;
    [self playRowAtIndex:row];
}

/// 整列起播（双击的真实落点；判据直接调这里，不依赖鼠标事件）。
- (void)playRowAtIndex:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_tracks.count) return;
    RLPTrack *clicked = _tracks[(NSUInteger)row];
    if (!clicked.path.length) {
        RLPToast(RLPTr(@"未指定音频文件路径"));
        return;
    }
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSInteger cleanIndex = -1;
    for (NSInteger i = 0; i < (NSInteger)_tracks.count; ++i) {
        RLPTrack *t = _tracks[(NSUInteger)i];
        if (!t.path.length) continue;
        if (i == row) cleanIndex = (NSInteger)paths.count;
        [paths addObject:t.path];
    }
    if (cleanIndex < 0 || cleanIndex >= (NSInteger)paths.count) {
        RLPToast(RLPTr(@"未指定音频文件路径"));
        return;
    }

    const NSUInteger pageEpoch = ++self.actionEpoch;
    const uint64_t playbackEpoch = RLPBeginPlaybackAction();
    NSArray<NSString *> *snapshotPaths = [paths copy];
    NSString *targetPath = snapshotPaths[(NSUInteger)cleanIndex];
    __weak __typeof__(self) weakSelf = self;
    BOOL (^shouldContinue)(void) = ^BOOL {
        __typeof__(self) self_ = weakSelf;
        return self_ && pageEpoch == self_.actionEpoch && playbackEpoch == RLPPlaybackActionEpoch();
    };
    RLPEnsureSequentialModeWhile(shouldContinue, ^{
        if (!shouldContinue()) return;
        NSString *body = [NSString stringWithFormat:@"files=%@",
                          RLPEnc([snapshotPaths componentsJoinedByString:@"\n"])];
        [[RLPCoreClient shared] postJSON:@"/api/queue/set" body:body
                              completion:^(NSDictionary * _Nullable j) {
            if (!shouldContinue()) return;
            if (!j || [j[@"ok"] boolValue] == NO) {
                NSString *rawErr = [j[@"error"] isKindOfClass:[NSString class]] ? (NSString *)j[@"error"] : nil;
                NSString *err = rawErr.length ? rawErr : RLPTr(@"建立队列失败");
                if ([NSThread isMainThread]) RLPToast(err);
                else dispatch_async(dispatch_get_main_queue(), ^{ RLPToast(err); });
                return;
            }
            RLPPlayPath(targetPath);
        }];
    });
}

#pragma mark - NSTableView

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return (NSInteger)_tracks.count;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    (void)tableView; (void)row;
    RLPFavRowView *rv = [[RLPFavRowView alloc] initWithFrame:NSZeroRect];
    rv.hoverColor = [RLPTheme current].hov;
    return rv;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_tracks.count) return nil;
    RLPTheme *theme = [RLPTheme current];
    RLPTrack *t = _tracks[(NSUInteger)row];
    NSString *cid = tableColumn.identifier;
    NSString *reuse = [cid stringByAppendingString:@".cell"];

    // 行尾心形（web .fav-btn）：最爱页里的心永远是实心，点一下 = 取消收藏。
    if ([cid isEqualToString:kFavColHeart]) {
        NSTableCellView *cell = [tableView makeViewWithIdentifier:reuse owner:self];
        if (!cell) {
            cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, kFavHeartW, kFavRowH)];
            cell.identifier = reuse;
            NSButton *b = [NSButton buttonWithTitle:@"" target:self action:@selector(onRowUnfav:)];
            b.bordered = NO;
            b.imagePosition = NSImageOnly;
            b.imageScaling = NSImageScaleProportionallyDown;
            b.identifier = @"fav.heart";
            b.translatesAutoresizingMaskIntoConstraints = NO;
            [cell addSubview:b];
            [NSLayoutConstraint activateConstraints:@[
                [b.centerXAnchor constraintEqualToAnchor:cell.centerXAnchor],
                [b.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
                [b.widthAnchor constraintEqualToConstant:24.0],
                [b.heightAnchor constraintEqualToConstant:24.0],
            ]];
            cell.textField = nil;
        }
        NSButton *btn = nil;
        for (NSView *v in cell.subviews) if ([v isKindOfClass:[NSButton class]]) { btn = (NSButton *)v; break; }
        btn.tag = row;
        objc_setAssociatedObject(btn, kRLPFavUnfavPathKey, t.path, OBJC_ASSOCIATION_COPY_NONATOMIC);
        btn.image = [NSImage imageWithSystemSymbolName:@"heart.fill" accessibilityDescription:RLPTr(@"取消收藏")];
        btn.contentTintColor = theme.accent;
        btn.toolTip = RLPTr(@"取消收藏");
        return cell;
    }

    NSTableCellView *cell = [tableView makeViewWithIdentifier:reuse owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, MAX(20.0, tableColumn.width), kFavRowH)];
        cell.identifier = reuse;
        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        tf.maximumNumberOfLines = 1;
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.identifier = [@"fav." stringByAppendingString:cid];
        [cell addSubview:tf];
        cell.textField = tf;
        [NSLayoutConstraint activateConstraints:@[
            [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:6.0],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-6.0],
            [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }

    NSTextField *tf = cell.textField;
    tf.toolTip = nil;
    cell.toolTip = nil;

    if ([cid isEqualToString:@"col0"]) {
        tf.alignment = NSTextAlignmentRight;
        tf.font = theme.mono ?: theme.small;
        tf.textColor = theme.mut2;
        tf.stringValue = [NSString stringWithFormat:@"%ld", (long)row + 1];
    } else if ([cid isEqualToString:@"col1"]) {
        NSString *title = RLPFavDisplayTitle(t);
        tf.alignment = NSTextAlignmentLeft;
        tf.font = [NSFont systemFontOfSize:12.5];
        tf.textColor = theme.text;
        tf.stringValue = title;
        tf.toolTip = t.path.length ? t.path : title;
    } else if ([cid isEqualToString:@"col2"]) {
        NSString *artist = t.artist ?: @"";
        tf.alignment = NSTextAlignmentLeft;
        tf.font = [NSFont systemFontOfSize:12.0];
        tf.textColor = theme.text2;
        tf.stringValue = artist;
        tf.toolTip = artist.length ? artist : nil;
    } else if ([cid isEqualToString:@"col3"]) {
        NSString *album = RLPFavDisplayAlbum(t);
        tf.alignment = NSTextAlignmentLeft;
        tf.font = [NSFont systemFontOfSize:12.0];
        tf.textColor = theme.mut2;
        tf.stringValue = album;
        tf.toolTip = album.length ? album : nil;
    } else {
        tf.stringValue = @"";
    }
    return cell;
}

/// 行尾心形：取消收藏（web unfavFromFavs 同端点）。
- (void)onRowUnfav:(NSButton *)sender {
    if (self.unfavInFlight) return;
    id assoc = sender ? objc_getAssociatedObject(sender, kRLPFavUnfavPathKey) : nil;
    NSString *path = [assoc isKindOfClass:[NSString class]] ? (NSString *)assoc : nil;
    if (!path.length && sender) {
        const NSInteger row = sender.tag;
        if (row >= 0 && row < (NSInteger)_tracks.count) {
            path = _tracks[(NSUInteger)row].path;
        }
    }
    if (!path.length) return;
    self.unfavInFlight = YES;
    NSString *url = [NSString stringWithFormat:@"/api/fav?file=%@&on=0", RLPEnc(path)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:url body:@"" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        self_.unfavInFlight = NO;
        if (json && [json[@"ok"] boolValue]) {
            RLPToast(RLPTr(@"已取消收藏"));
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPFavoritesChangedNotification object:self_];
            [self_ reloadData];
        } else {
            RLPToast(RLPTr(@"取消收藏失败"));
        }
    }];
}

- (void)applyLanguage {
    self.pageTitle = RLPTr(@"我的最爱");
    if (!self.isViewLoaded) return;
    NSArray<NSString *> *cols = @[@"#", RLPTr(@"标题"), RLPTr(@"艺术家"), RLPTr(@"专辑"), @""];
    for (NSUInteger i = 0; i < _tableView.tableColumns.count && i < cols.count; ++i) {
        _tableView.tableColumns[i].title = cols[i];
    }
    [_tableView.headerView setNeedsDisplay:YES];
    [self updateListChrome];
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
