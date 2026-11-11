// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPQueueViewController.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

@interface RLPQueueViewController () {
    NSTableView *_tableView;
    NSScrollView *_scrollView;
    RLPQueueSnapshot *_snapshot;
    NSArray<NSDictionary *> *_metas;
}
@end

@implementation RLPQueueViewController

- (void)buildContent {
    [super buildContent];
    
    // 工具栏
    NSStackView *toolbar = [NSStackView stackViewWithViews:@[
        RLPSymbolButton(@"arrow.clockwise", RLPTr(@"刷新"), self, @selector(refresh:)),
        RLPSymbolButton(@"trash", RLPTr(@"清空"), self, @selector(clearQueue:)),
        RLPSymbolButton(@"arrow.down.doc", RLPTr(@"保存为歌单"), self, @selector(savePlaylist:))
    ]];
    toolbar.spacing = 10;
    toolbar.edgeInsets = NSEdgeInsetsMake(0, 0, 10, 0);
    [self.contentView addSubview:toolbar];
    
    // 表格
    _tableView = [[NSTableView alloc] initWithFrame:self.contentView.bounds];
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.headerView = [[NSTableHeaderView alloc] init];
    _tableView.doubleAction = @selector(doubleClick:);
    
    NSArray *columns = @[RLPTr(@"#"), RLPTr(@"标题"), RLPTr(@"艺术家"), RLPTr(@"专辑"), RLPTr(@"时长")];
    for (int i = 0; i < 5; i++) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"%d", i]];
        col.title = columns[i];
        [_tableView addTableColumn:col];
    }
    
    _scrollView = [[NSScrollView alloc] initWithFrame:self.contentView.bounds];
    _scrollView.documentView = _tableView;
    _scrollView.hasVerticalScroller = YES;
    [self.contentView addSubview:_scrollView];
}

- (void)reloadData {
    [super reloadData];
    [RLPCoreClient.shared getJSON:@"/api/queue?meta=1" completion:^(NSDictionary * _Nullable json) {
        if (!json || ![json[@"ok"] boolValue]) return;
        self->_snapshot = [RLPQueueSnapshot snapshotFromJSON:json];
        self->_metas = json[@"metas"];
        [self->_tableView reloadData];
        
        NSString *modeName = @[RLPTr(@"顺序"), RLPTr(@"列表循环"), RLPTr(@"单曲循环"), RLPTr(@"随机")][self->_snapshot.mode % 4];
        [self setSubtitle:[NSString stringWithFormat:RLPTr(@"%ld 首 · 当前第 %ld 首 · %@"), (long)self->_snapshot.paths.count, (long)self->_snapshot.index + 1, modeName]];
    }];
}

- (void)doubleClick:(id)sender {
    NSInteger row = [_tableView clickedRow];
    if (row >= 0 && row < (NSInteger)_snapshot.paths.count) {
        RLPPlayPath(_snapshot.paths[row]);
    }
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return _snapshot ? (NSInteger)_snapshot.paths.count : 0;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSTextField *tf = RLPLabel(@"", [NSFont systemFontOfSize:13], RLPTheme.current.text);
    NSDictionary *m = _metas[row];
    switch ([tableColumn.identifier intValue]) {
        case 0: tf.stringValue = [NSString stringWithFormat:@"%ld", (long)row + 1]; break;
        case 1: tf.stringValue = m[@"t"] ?: @""; break;
        case 2: tf.stringValue = m[@"a"] ?: @""; break;
        case 3: tf.stringValue = m[@"al"] ?: @""; break;
        case 4: tf.stringValue = RLPFmtDuration([m[@"d"] doubleValue]); break;
    }
    return tf;
}

- (void)refresh:(id)sender { [self reloadData]; }

- (void)clearQueue:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = RLPTr(@"确定清空播放队列？");
    if ([alert runModal] == NSModalResponseOK) {
        [RLPCoreClient.shared postJSON:@"/api/clear" body:nil completion:^(NSDictionary * _Nullable j){ [self reloadData]; }];
    }
}

- (void)savePlaylist:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = RLPTr(@"歌单名称");
    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    alert.accessoryView = input;
    if ([alert runModal] == NSModalResponseOK) {
        NSString *name = RLPEnc(input.stringValue);
        [RLPCoreClient.shared postJSON:[NSString stringWithFormat:@"/api/sq/add?name=%@", name] body:nil completion:^(NSDictionary * _Nullable j){
            RLPToast(j[@"ok"] ? RLPTr(@"保存成功") : RLPTr(@"保存失败"));
            [self reloadData];
        }];
    }
}

@end
