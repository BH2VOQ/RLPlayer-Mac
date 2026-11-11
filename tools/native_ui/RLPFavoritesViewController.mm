// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later

#import "RLPFavoritesViewController.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPTheme.h"
#import "RLPSupport.h"
#import "RLPTrackActions.h"

static const NSUserInterfaceItemIdentifier kFavTableID = @"RLPFavTable";

@interface RLPFavoritesViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSMutableArray<RLPTrack *> *tracks;
@end

@implementation RLPFavoritesViewController

- (instancetype)init {
    self = [super initWithTitle:RLPTr(@"我的最爱")];
    if (self) {
        _tracks = [NSMutableArray array];
    }
    return self;
}

- (void)buildContent {

    
    _tableView = [[RLPTrackActionTableView alloc] initWithFrame:self.contentView.bounds];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    // 右键 = 与 web 一致的完整曲目动作（播放/入队/收藏/存歌单/体检/对比）
    {
        __weak __typeof__(self) ws = self;
        ((RLPTrackActionTableView *)_tableView).pathForRow = ^NSString *(NSInteger row) {
            __typeof__(self) s = ws;
            NSArray<RLPTrack *> *ts = self.tracks;
            if (!s || row < 0 || row >= (NSInteger)ts.count) return nil;
            return ts[(NSUInteger)row].path;
        };
    }
    _tableView.headerView = [[NSTableHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 0, 24)];
    _tableView.usesAlternatingRowBackgroundColors = YES;
    
    NSArray *cols = @[@"#", RLPTr(@"标题"), RLPTr(@"艺术家"), RLPTr(@"专辑"), RLPTr(@"时长")];
    for (NSInteger i = 0; i < (NSInteger)cols.count; i++) {
        NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"col%ld", (long)i]];
        c.title = cols[i];
        [_tableView addTableColumn:c];
    }
    
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:self.contentView.bounds];
    scroll.documentView = _tableView;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    [self.contentView addSubview:scroll];
    
    // 双击播放
    // 与 web 版一致：**单击**即触发（web 的行 onclick 就是单击）。
    // 双击保留兼容；两者指向同一动作，重复触发幂等。
    _tableView.action = @selector(onDoubleClick:);
    _tableView.doubleAction = @selector(onDoubleClick:);
    _tableView.target = self;
    
    // 右键菜单
    NSMenu *menu = [[NSMenu alloc] init];
    [menu addItemWithTitle:RLPTr(@"播放") action:@selector(onPlay:) keyEquivalent:@""];
    [menu addItemWithTitle:RLPTr(@"加入队列") action:@selector(onEnqueue:) keyEquivalent:@""];
    [menu addItemWithTitle:RLPTr(@"取消收藏") action:@selector(onUnfav:) keyEquivalent:@""];
    _tableView.menu = menu;
}

- (void)reloadData {
    if (![RLPCoreClient shared].started) {
        [self.tracks removeAllObjects];
        [self setSubtitle:RLPTr(@"核心未启动")];
        [_tableView reloadData];
        return;
    }
    
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/fav/list?meta=1" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || !json || ![json[@"ok"] boolValue]) {
            [self_ setSubtitle:RLPTr(@"加载失败")];
            return;
        }
        
        NSArray *files = json[@"files"];
        NSMutableArray *tracks = [NSMutableArray array];
        for (id item in files) {
            RLPTrack *t = [RLPTrack trackFromJSON:item];
            if (t) [tracks addObject:t];
        }
        self_.tracks = tracks;
        [self_ setSubtitle:[NSString stringWithFormat:RLPTr(@"%ld 首"), (long)tracks.count]];
        [self_.tableView reloadData];
    }];
}

#pragma mark - Actions

/// 共享右键菜单的动作入口。
- (void)rlp_trackMenuAction:(NSMenuItem *)sender {
    RLPHandleTrackAction(sender, self.view);
}

- (void)onDoubleClick:(id)sender {
    NSInteger row = [_tableView clickedRow];
    if (row < 0 || row >= (NSInteger)_tracks.count) return;
    // 与 web 我的最爱页同语义：双击不是只播这一首，而是把整个收藏列表建成队列、
    // 从被点那首开始顺序播放（/api/queue/set → playPath）。单曲循环模式会被切回列表循环。
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (RLPTrack *t in _tracks) if (t.path.length) [paths addObject:t.path];
    // start 要用"在过滤后列表里的位置"；_tracks 全有 path 时与 row 一致。
    NSInteger start = row;
    RLPPlayWholeListFrom(paths, start);
}

- (void)onPlay:(id)sender {
    NSInteger row = _tableView.clickedRow >= 0 ? _tableView.clickedRow : _tableView.selectedRow;
    if (row < 0) return;
    RLPPlayPath(_tracks[row].path);
}

- (void)onEnqueue:(id)sender {
    NSInteger row = _tableView.clickedRow >= 0 ? _tableView.clickedRow : _tableView.selectedRow;
    if (row < 0) return;
    RLPEnqueuePath(_tracks[row].path);
}

- (void)onUnfav:(id)sender {
    NSInteger row = _tableView.clickedRow >= 0 ? _tableView.clickedRow : _tableView.selectedRow;
    if (row < 0) return;
    NSString *path = _tracks[row].path;
    NSString *url = [NSString stringWithFormat:@"/api/fav?file=%@&on=0", RLPEnc(path)];
    
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (json && [json[@"ok"] boolValue]) {
            [self_ reloadData];
        } else {
            RLPToast(RLPTr(@"取消收藏失败"));
        }
    }];
}

#pragma mark - NSTableView

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_tracks.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    RLPTrack *t = _tracks[row];
    NSString *cid = tableColumn.identifier;
    NSString *val = @"";
    if ([cid isEqualToString:@"col0"]) val = [NSString stringWithFormat:@"%ld", (long)row + 1];
    else if ([cid isEqualToString:@"col1"]) val = t.title;
    else if ([cid isEqualToString:@"col2"]) val = t.artist;
    else if ([cid isEqualToString:@"col3"]) val = t.album;
    else if ([cid isEqualToString:@"col4"]) val = RLPFmtDuration(t.duration);
    
    NSTextField *tf = RLPLabel(val, [RLPTheme current].body, [RLPTheme current].text);
    return tf;
}

@end