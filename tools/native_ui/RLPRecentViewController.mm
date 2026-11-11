// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later

#import "RLPRecentViewController.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPSupport.h"
#import "RLPTrackActions.h"
#import "RLPTheme.h"

@interface RLPRecentViewController () <NSTableViewDataSource, NSTableViewDelegate>
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
    _tableView.headerView = [[NSTableHeaderView alloc] initWithFrame:NSZeroRect];
    _tableView.backgroundColor = NSColor.clearColor;
    _tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    // 与 web 版一致：**单击**即触发（web 的行 onclick 就是单击）。
    // 双击保留兼容；两者指向同一动作，重复触发幂等。
    _tableView.action = @selector(onDoubleClick:);
    _tableView.doubleAction = @selector(onDoubleClick:);
    _tableView.target = self;
    
    // Columns
    NSArray<NSString *> *headers = @[RLPTr(@"#"), RLPTr(@"标题"), RLPTr(@"艺术家"), RLPTr(@"专辑"), RLPTr(@"时长")];
    for (int i = 0; i < 5; i++) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"col%d", i]];
        col.title = headers[i];
        [_tableView addTableColumn:col];
    }
    
    scroll.documentView = _tableView;
    
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
    ]];
    
    _tracks = [NSMutableArray array];
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
    else if ([identifier isEqualToString:@"col4"]) label.stringValue = RLPFmtDuration(track.duration);
    
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