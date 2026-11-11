// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPStreamingViewController.h"
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

@interface RLPStreamingViewController () <NSTableViewDelegate, NSTableViewDataSource> {
    NSTableView *_tableView;
    NSScrollView *_scrollView;
    NSPopUpButton *_serverPicker;
    NSTextField *_pathBreadcrumb;
    NSButton *_backButton;
    
    NSArray<NSDictionary *> *_servers;
    NSMutableArray *_breadcrumbStack;
    NSArray<NSDictionary *> *_items;
    NSUInteger _requestSeq;
}
@end

@implementation RLPStreamingViewController

- (instancetype)init {
    self = [super initWithTitle:RLPTr(@"流媒体")];
    if (self) {
        _breadcrumbStack = [NSMutableArray array];
    }
    return self;
}

- (void)buildContent {
    [super buildContent];
    
    NSStackView *toolbar = [NSStackView stackViewWithViews:@[]];
    toolbar.edgeInsets = NSEdgeInsetsMake(0, 0, 10, 0);
    
    _serverPicker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_serverPicker setTarget:self];
    [_serverPicker setAction:@selector(serverChanged:)];
    [toolbar addView:_serverPicker inGravity:NSStackViewGravityLeading];
    
    NSButton *refreshBtn = RLPSymbolButton(@"arrow.clockwise", RLPTr(@"刷新"), self, @selector(refresh:));
    [toolbar addView:refreshBtn inGravity:NSStackViewGravityLeading];

    // 测速：POST /api/src/ping?id=N（测已保存的那台）。连不上要如实说，不假装成功。
    NSButton *pingBtn = [NSButton buttonWithTitle:RLPTr(@"测试连接") target:self action:@selector(onPing:)];
    pingBtn.bezelStyle = NSBezelStyleRounded;
    [toolbar addView:pingBtn inGravity:NSStackViewGravityLeading];
    
    _backButton = RLPSymbolButton(@"arrow.left", RLPTr(@"上一级"), self, @selector(goBack:));
    _backButton.enabled = NO;
    [toolbar addView:_backButton inGravity:NSStackViewGravityLeading];
    
    _pathBreadcrumb = RLPLabel(@"", [NSFont systemFontOfSize:12], RLPTheme.current.mut);
    [toolbar addView:_pathBreadcrumb inGravity:NSStackViewGravityLeading];
    
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:toolbar];
    
    _tableView = [[NSTableView alloc] initWithFrame:self.contentView.bounds];
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.headerView = nil;
    _tableView.doubleAction = @selector(doubleClick:);
    
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"main"];
    [_tableView addTableColumn:col];
    
    _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scrollView.documentView = _tableView;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.drawsBackground = NO;
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_scrollView];

    // 之前 toolbar / scrollView 都没上约束：工具栏不显示、表格与它重叠。
    // 这里补齐（与队列页同一套布局口径）。
    [NSLayoutConstraint activateConstraints:@[
        [toolbar.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [toolbar.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [toolbar.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [_scrollView.topAnchor constraintEqualToAnchor:toolbar.bottomAnchor constant:10],
        [_scrollView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],
    ]];
}

- (void)reloadData {
    [super reloadData];
    NSUInteger seq = ++_requestSeq;
    [RLPCoreClient.shared getJSON:@"/api/src/config" completion:^(NSDictionary * _Nullable json) {
        if (seq != self->_requestSeq) return;
        if (!json || ![json[@"ok"] boolValue]) return;
        
        self->_servers = json[@"servers"];
        [self->_serverPicker removeAllItems];
        for (NSDictionary *s in self->_servers) {
            [self->_serverPicker addItemWithTitle:s[@"name"] ?: @""];
        }
        
        if (![json[@"configured"] boolValue] || self->_servers.count == 0) {
            self->_items = nil;
            [self->_tableView reloadData];
            [self setSubtitle:RLPTr(@"未配置服务器")];
            RLPToast(RLPTr(@"请在「设置 → 流媒体」中添加服务器"));
            return;
        }
        
        [self browseId:@""];
    }];
}

- (void)browseId:(NSString *)key {
    NSUInteger seq = ++_requestSeq;
    [RLPCoreClient.shared getJSON:[NSString stringWithFormat:@"/api/src/browse?id=%@", key] completion:^(NSDictionary * _Nullable json) {
        if (seq != self->_requestSeq) return;
        if (!json || ![json[@"ok"] boolValue]) {
            [self setSubtitle:json[@"error"] ?: RLPTr(@"浏览失败")];
            return;
        }
        
        NSString *err = json[@"err"];
        if (err && err.length > 0) {
            self->_items = nil;
            [self setSubtitle:err];
        } else {
            self->_items = json[@"items"];
            [self setSubtitle:[NSString stringWithFormat:RLPTr(@"%ld 项"), (long)self->_items.count]];
        }
        [self->_tableView reloadData];
    }];
}

/// 测试当前选中服务器的连通性。POST /api/src/ping?id=N。
- (void)onPing:(id)sender {
    if (![RLPCoreClient shared].started) { RLPToast(RLPTr(@"核心未启动")); return; }
    const NSInteger idx = _serverPicker.indexOfSelectedItem;
    if (idx < 0 || idx >= (NSInteger)_servers.count) { RLPToast(RLPTr(@"请先选择一台服务器")); return; }
    NSString *sid = [_servers[idx][@"id"] isKindOfClass:[NSString class]] ? _servers[idx][@"id"] : @"";
    if (!sid.length) { RLPToast(RLPTr(@"这台服务器没有可用标识")); return; }
    NSString *url = [NSString stringWithFormat:@"/api/src/ping?id=%@", RLPEnc(sid)];
    RLPToast(RLPTr(@"正在测试连接…"));
    [[RLPCoreClient shared] postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
        if (json && [json[@"ok"] boolValue]) {
            NSString *note = [json[@"note"] isKindOfClass:[NSString class]] ? json[@"note"] : @"";
            RLPToast(note.length ? note : RLPTr(@"连接正常"));
        } else {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"连接失败");
            RLPToast(err);
        }
    }];
}

- (void)serverChanged:(id)sender {
    NSInteger idx = [_serverPicker indexOfSelectedItem];
    if (idx < 0) return;
    NSDictionary *s = _servers[idx];
    NSString *body = [NSString stringWithFormat:@"action=active&id=%@", s[@"id"]];
    [RLPCoreClient.shared postJSON:@"/api/src/config" body:body completion:^(NSDictionary * _Nullable) {
        [self reloadData];
    }];
}

- (void)refresh:(id)sender { [self browseId:_breadcrumbStack.lastObject[@"id"] ?: @""]; }

- (void)goBack:(id)sender {
    [_breadcrumbStack removeLastObject];
    _backButton.enabled = _breadcrumbStack.count > 0;
    [self browseId:_breadcrumbStack.lastObject[@"id"] ?: @""];
}

- (void)doubleClick:(id)sender {
    NSInteger row = [_tableView clickedRow];
    if (row < 0 || row >= (NSInteger)_items.count) return;
    NSDictionary *item = _items[row];
    if ([item[@"dir"] boolValue]) {
        [_breadcrumbStack addObject:@{@"id": item[@"id"], @"t": item[@"t"]}];
        _backButton.enabled = YES;
        [self browseId:item[@"id"]];
    } else {
        RLPPlayPath(item[@"id"]);
    }
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)_items.count; }

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSDictionary *item = _items[row];
    NSTextField *tf = RLPLabel(item[@"t"] ?: @"", [NSFont systemFontOfSize:13], RLPTheme.current.text);
    return tf;
}

- (void)applyTheme {
    [super applyTheme];
    _tableView.backgroundColor = RLPTheme.current.bg;
    _scrollView.backgroundColor = RLPTheme.current.bg;
}

- (void)activate { [super activate]; }

@end