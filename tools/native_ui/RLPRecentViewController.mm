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

@interface RLPRecentViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSTextField *emptyLabel;   // web：还没有播放记录
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSMutableArray<RLPTrack *> *tracks;
@end

@implementation RLPRecentViewController

- (instancetype)init {
    return [super initWithTitle:RLPTr(@"最近播放")];
}

- (void)buildContent {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:self.contentView.bounds];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:scroll];

    _tableView = [[RLPTrackActionTableView alloc] initWithFrame:scroll.bounds];
    _tableView.delegate = self;
    _tableView.dataSource = self;
    // 右键 = 与 web 一致的完整曲目动作（播放/入队/收藏/存歌单/体检/对比）
    {
        __weak __typeof__(self) ws = self;
        ((RLPTrackActionTableView *)_tableView).pathForRow = ^NSString *(NSInteger row) {
            __typeof__(self) s = ws;
            NSArray<RLPTrack *> *ts = _tracks;
            if (!s || row < 0 || row >= (NSInteger)ts.count) return nil;
            return ts[(NSUInteger)row].path;
        };
    }
    // web 最近列表没有表头行（.trow 行模板直接进 #list，不画 head 的列名）。
    _tableView.headerView = nil;
    _tableView.backgroundColor = NSColor.clearColor;
    _tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    // 与 web 版一致：**单击**即触发（web 的行 onclick 就是单击）。
    // 双击保留兼容；两者指向同一动作，重复触发幂等。
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
                col.width = 420; col.minWidth = kRecentTitleMinW; col.maxWidth = 10000;
                break;
            case 2:
                col.width = kRecentArtistW; col.minWidth = kRecentArtistW; col.maxWidth = kRecentArtistW;
                break;
            default:
                col.width = kRecentAlbumW; col.minWidth = kRecentAlbumW; col.maxWidth = kRecentAlbumW;
                break;
        }
        [_tableView addTableColumn:col];
    }
    // 不交给 AppKit 均匀拉伸：标题列按 web 的 1fr 自己吃剩余宽度（见 -viewDidLayout）。
    _tableView.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
    
    scroll.documentView = _tableView;

    _emptyLabel = RLPLabel(RLPTr(@"还没有播放记录"), [NSFont systemFontOfSize:13], [RLPTheme current].mut);
    _emptyLabel.identifier = @"recent.empty";
    _emptyLabel.alignment = NSTextAlignmentCenter;
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyLabel.hidden = YES;
    [self.contentView addSubview:_emptyLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_emptyLabel.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [_emptyLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
    ]];
    
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
    ]];
    
    _tracks = [NSMutableArray array];
}

/// web .trow 的标题列是 1fr：随页面宽度伸缩，其余三列固定（34 / 160 / 92）。
/// 旧原生把宽度交给 AppKit 均匀拉伸 ⟹ 4 列都摊成 100pt，和 web 的列宽完全不是一回事。
- (void)viewDidLayout {
    [super viewDidLayout];
    const CGFloat width = NSWidth(self.contentView.bounds);
    if (!_tableView || !(width > 1.0)) return;
    NSTableColumn *title = nil;
    for (NSTableColumn *c in _tableView.tableColumns)
        if ([c.identifier isEqualToString:@"col1"]) { title = c; break; }
    if (!title) return;
    const CGFloat rest = width - (kRecentIndexW + kRecentArtistW + kRecentAlbumW);
    title.width = MAX(kRecentTitleMinW, rest);
}

- (void)activate {
    [super activate];
    [self reloadData];
}

- (void)reloadData {
    if (![RLPCoreClient shared].started) {
        [self setSubtitle:RLPTr(@"核心未启动")];
        return;
    }
    
    __weak RLPRecentViewController *weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/recent" completion:^(NSDictionary * _Nullable json) {
        RLPRecentViewController *self_ = weakSelf;
        if (!self_) return;
        
        if (!json || ![json[@"ok"] boolValue]) {
            [self_ setSubtitle:RLPTr(@"加载失败")];
            return;
        }
        
        NSArray<RLPTrack *> *tracks = [RLPTrack tracksFromJSON:json key:nil];
        [self_.tracks removeAllObjects];
        [self_.tracks addObjectsFromArray:tracks];
        [self_.tableView reloadData];
        [self_ setSubtitle:[NSString stringWithFormat:RLPTr(@"%ld 首"), (long)tracks.count]];
        self_.emptyLabel.hidden = self_.tracks.count > 0;
    }];
}

#pragma mark - TableView

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_tracks.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    RLPTrack *track = _tracks[(NSUInteger)row];
    NSString *identifier = tableColumn.identifier;
    
    NSTextField *label = [NSTextField labelWithString:@""];
    label.font = [RLPTheme current].body;
    label.textColor = [RLPTheme current].text;
    
    if ([identifier isEqualToString:@"col0"]) label.stringValue = [NSString stringWithFormat:@"%ld", (long)row + 1];
    else if ([identifier isEqualToString:@"col1"]) label.stringValue = track.title.length ? track.title : track.path.lastPathComponent;
    else if ([identifier isEqualToString:@"col2"]) label.stringValue = track.artist.length ? track.artist : RLPTr(@"未知");
    else if ([identifier isEqualToString:@"col3"]) label.stringValue = track.album.length ? track.album : RLPTr(@"未知");
    
    return label;
}

/// 共享右键菜单的动作入口。
- (void)rlp_trackMenuAction:(NSMenuItem *)sender {
    RLPHandleTrackAction(sender, self.view);
}

- (void)onDoubleClick:(id)sender {
    NSInteger row = [_tableView clickedRow];
    if (row < 0 || row >= (NSInteger)_tracks.count) return;
    RLPTrack *track = _tracks[(NSUInteger)row];
    RLPPlayPath(track.path);
}

@end