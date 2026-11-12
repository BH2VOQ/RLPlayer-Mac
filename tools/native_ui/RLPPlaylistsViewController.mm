// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPPlaylistsViewController.mm — 歌单（saved queues）
//
// 后端契约（tools/rtaweb.cpp，已逐条核实）：
//   GET  /api/sq/list                 → {"ok":true,"queues":[{"name":…,"n":条数}]}
//   GET  /api/sq/info?name=…          → {"ok":true,"name":…,"items":[{"file":…,"cs":起,"ce":止}]}
//                                       cs/ce 是 CUE 分轨起止秒（-1 = 整文件），**不能丢**
//   POST /api/sq/add?name=…           新建空歌单
//   POST /api/sq/save?name=…          把当前播放队列存成歌单
//   POST /api/sq/rename?from=…&to=…   重命名
//   POST /api/sq/delete?name=…        删除
//   POST /api/sq/play?name=…&i=…      载入队列（之后还要按 file/cs/ce 真正起播）
//
// 为什么只显示文件名 + 所在目录：后端 info 只给 file/cs/ce，没有标签。web 版同口径。
// 不为了"好看"逐曲打 /api/meta —— 几百首的歌单会瞬间打出几百个探测请求。
#import "RLPPlaylistsViewController.h"
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPTheme.h"
#import "RLPTrackActions.h"

@interface RLPPlaylistRow : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) NSInteger count;
@end
@implementation RLPPlaylistRow
@end

@interface RLPPlaylistItem : NSObject
@property (nonatomic, copy) NSString *file;
@property (nonatomic, assign) double cs;
@property (nonatomic, assign) double ce;
@end
@implementation RLPPlaylistItem
@end

@interface RLPPlaylistsViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSTableView *listTable;
@property (nonatomic, strong) NSTableView *itemTable;
@property (nonatomic, strong) NSMutableArray<RLPPlaylistRow *> *playlists;
@property (nonatomic, strong) NSMutableArray<RLPPlaylistItem *> *items;
@property (nonatomic, copy) NSString *selectedName;
@property (nonatomic, strong) NSButton *playAllBtn;
@property (nonatomic, strong) NSButton *renameBtn;
@property (nonatomic, strong) NSButton *deleteBtn;
@property (nonatomic, assign) NSUInteger listSeq;
@property (nonatomic, assign) NSUInteger itemSeq;
@end

@implementation RLPPlaylistsViewController

- (instancetype)init {
    self = [super initWithTitle:RLPTr(@"歌单")];
    if (self) {
        _playlists = [NSMutableArray array];
        _items = [NSMutableArray array];
        _selectedName = @"";
        // 侧栏「+ 新建」发来的请求（侧栏不持有本页实例，用通知广播）
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onNewPlaylistNote:)
                                                     name:@"RLPNewPlaylistNotification" object:nil];
        // 侧栏点某份歌单：页面按名字选中并加载（web renderSavedQueuePage(name)）。
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onSelectSavedQueueNote:)
                                                     name:@"RLPSelectSavedQueueNotification" object:nil];
        // 别处（侧栏 ✎/×）改了歌单：本页也要重拉，否则两处数据分叉。
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onSavedQueuesChangedNote:)
                                                     name:@"RLPSavedQueuesChangedNotification" object:nil];
    }
    return self;
}

- (void)onNewPlaylistNote:(NSNotification *)note {
    (void)note;
    [self onNew:nil];   // 复用页内「新建」按钮的同一条路径
}

- (void)onSelectSavedQueueNote:(NSNotification *)note {
    id obj = note.object;
    if (![obj isKindOfClass:[NSString class]] || ![obj length]) return;
    self.selectedName = obj;
    // 先把列表里对应的行选中（列表可能还没拉到 ⟹ reloadData 之后由 reloadData 的 stillThere 分支补）
    [self selectRowForName:obj];
    [self loadItems];
}

- (void)onSavedQueuesChangedNote:(NSNotification *)note {
    (void)note;
    [self reloadData];
}

/// 在左侧列表里按名字选中（找不到就清空选中，不硬造行）。
- (void)selectRowForName:(NSString *)name {
    NSInteger hit = -1;
    for (NSUInteger i = 0; i < self.playlists.count; ++i)
        if ([self.playlists[i].name isEqualToString:name]) { hit = (NSInteger)i; break; }
    if (hit >= 0) {
        [self.listTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)hit]
                     byExtendingSelection:NO];
        [self.listTable scrollRowToVisible:hit];
    }
}

- (void)buildContent {
    RLPTheme *t = [RLPTheme current];
    NSView *host = self.contentView;

    self.listTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.listTable.dataSource = self;
    self.listTable.delegate = self;
    self.listTable.headerView = nil;
    self.listTable.rowHeight = 28;
    self.listTable.backgroundColor = t.bg2;
    NSTableColumn *lc = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    lc.width = 200;
    [self.listTable addTableColumn:lc];
    self.listTable.target = self;
    self.listTable.action = @selector(onListSelect:);

    NSScrollView *ls = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    ls.documentView = self.listTable;
    ls.hasVerticalScroller = YES;
    ls.drawsBackground = NO;
    ls.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:ls];

    NSStackView *lbar = [[NSStackView alloc] init];
    lbar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    lbar.spacing = 6;
    lbar.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *newBtn = [NSButton buttonWithTitle:RLPTr(@"新建") target:self action:@selector(onNew:)];
    newBtn.bezelStyle = NSBezelStyleRounded;
    NSButton *saveBtn = [NSButton buttonWithTitle:RLPTr(@"存当前队列") target:self action:@selector(onSaveCurrent:)];
    saveBtn.bezelStyle = NSBezelStyleRounded;
    [lbar addArrangedSubview:newBtn];
    [lbar addArrangedSubview:saveBtn];
    [host addSubview:lbar];

    // 曲目表接**共享动作表格**：右键 = 与 web 一致的完整曲目动作
    // （播放/入队/收藏/存歌单/体检/对比/AI 补全）。交接单列的未对齐项，2026-11-12 补上。
    self.itemTable = [[RLPTrackActionTableView alloc] initWithFrame:NSZeroRect];
    {
        __weak __typeof__(self) ws = self;
        ((RLPTrackActionTableView *)self.itemTable).pathForRow = ^NSString *(NSInteger row) {
            __typeof__(self) s = ws;
            if (!s || row < 0 || row >= (NSInteger)s.items.count) return nil;
            return s.items[(NSUInteger)row].file;
        };
    }
    self.itemTable.dataSource = self;
    self.itemTable.delegate = self;
    self.itemTable.usesAlternatingRowBackgroundColors = YES;
    self.itemTable.rowHeight = 26;
    self.itemTable.backgroundColor = t.bg;
    NSArray<NSString *> *cols = @[ @"#", RLPTr(@"标题"), RLPTr(@"所在目录") ];
    NSArray<NSNumber *> *widths = @[ @40, @420, @300 ];
    for (NSInteger i = 0; i < (NSInteger)cols.count; ++i) {
        NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"c%ld", (long)i]];
        c.title = cols[i];
        c.width = widths[i].doubleValue;
        [self.itemTable addTableColumn:c];
    }
    // 与 web 版一致：**单击**即触发（web 的行 onclick 就是单击）。
    // 双击保留兼容；两者指向同一动作，重复触发幂等。
    self.itemTable.action = @selector(onItemDouble:);
    self.itemTable.doubleAction = @selector(onItemDouble:);
    self.itemTable.target = self;

    NSScrollView *is = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    is.documentView = self.itemTable;
    is.hasVerticalScroller = YES;
    is.drawsBackground = NO;
    is.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:is];

    NSStackView *ibar = [[NSStackView alloc] init];
    ibar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    ibar.spacing = 8;
    ibar.translatesAutoresizingMaskIntoConstraints = NO;
    self.playAllBtn = [NSButton buttonWithTitle:RLPTr(@"播放整列") target:self action:@selector(onPlayAll:)];
    self.renameBtn = [NSButton buttonWithTitle:RLPTr(@"重命名") target:self action:@selector(onRename:)];
    self.deleteBtn = [NSButton buttonWithTitle:RLPTr(@"删除") target:self action:@selector(onDelete:)];
    for (NSButton *b in @[ self.playAllBtn, self.renameBtn, self.deleteBtn ]) {
        b.bezelStyle = NSBezelStyleRounded;
        b.enabled = NO;
        [ibar addArrangedSubview:b];
    }
    [host addSubview:ibar];

    [NSLayoutConstraint activateConstraints:@[
        [ls.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:16],
        [ls.widthAnchor constraintEqualToConstant:220],
        [ls.topAnchor constraintEqualToAnchor:host.topAnchor constant:8],
        [ls.bottomAnchor constraintEqualToAnchor:lbar.topAnchor constant:-8],
        [lbar.leadingAnchor constraintEqualToAnchor:ls.leadingAnchor],
        [lbar.bottomAnchor constraintEqualToAnchor:host.bottomAnchor constant:-12],
        [ibar.leadingAnchor constraintEqualToAnchor:ls.trailingAnchor constant:16],
        [ibar.topAnchor constraintEqualToAnchor:host.topAnchor constant:8],
        [is.leadingAnchor constraintEqualToAnchor:ibar.leadingAnchor],
        [is.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-16],
        [is.topAnchor constraintEqualToAnchor:ibar.bottomAnchor constant:8],
        [is.bottomAnchor constraintEqualToAnchor:host.bottomAnchor constant:-12],
    ]];
}

#pragma mark - 表格

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    return tv == self.listTable ? (NSInteger)self.playlists.count : (NSInteger)self.items.count;
}

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    RLPTheme *t = [RLPTheme current];
    NSString *ident = col.identifier;
    NSTextField *label = [tv makeViewWithIdentifier:ident owner:self];
    if (!label) {
        label = RLPLabel(@"", t.body, t.text);
        label.identifier = ident;
    }
    if (tv == self.listTable) {
        if (row < 0 || row >= (NSInteger)self.playlists.count) return label;
        RLPPlaylistRow *pl = self.playlists[row];
        label.stringValue = [NSString stringWithFormat:@"%@  (%ld)", pl.name, (long)pl.count];
        label.textColor = [pl.name isEqualToString:self.selectedName] ? t.accent : t.text;
        return label;
    }
    if (row < 0 || row >= (NSInteger)self.items.count) return label;
    RLPPlaylistItem *it = self.items[row];
    NSString *base = it.file.lastPathComponent.stringByDeletingPathExtension;
    // CUE 分轨要标出来，否则同一文件出现十几次会被当成 bug
    if (it.cs >= 0 && it.ce > it.cs) {
        base = [base stringByAppendingFormat:@"  [%@-%@]", RLPFmtDuration(it.cs), RLPFmtDuration(it.ce)];
    }
    if ([ident isEqualToString:@"c0"]) label.stringValue = [NSString stringWithFormat:@"%ld", (long)(row + 1)];
    else if ([ident isEqualToString:@"c1"]) label.stringValue = base;
    else label.stringValue = it.file.stringByDeletingLastPathComponent.lastPathComponent;
    label.textColor = t.text;
    return label;
}

#pragma mark - 动作

- (void)onListSelect:(id)sender {
    const NSInteger row = self.listTable.clickedRow >= 0 ? self.listTable.clickedRow : self.listTable.selectedRow;
    if (row < 0 || row >= (NSInteger)self.playlists.count) return;
    [self openPlaylist:self.playlists[row].name];
}

- (void)openPlaylist:(NSString *)name {
    self.selectedName = name ?: @"";
    const BOOL has = self.selectedName.length > 0;
    self.playAllBtn.enabled = has;
    self.renameBtn.enabled = has;
    self.deleteBtn.enabled = has;
    [self.listTable reloadData];
    [self loadItems];
}

- (void)onItemDouble:(id)sender {
    const NSInteger row = self.itemTable.clickedRow;
    if (row < 0) return;
    [self playFromIndex:row];
}

/// 共享曲目菜单的分派落点（responder chain）。
/// 「播放」在歌单语境 = 载入整列并从该曲起播（带 CUE cs/ce），与单击/双击同语义；
/// 其余动作（入队/收藏/存歌单/体检/对比/AI）走共享实现，不另写一套。
- (void)rlp_trackMenuAction:(NSMenuItem *)sender {
    if (sender.tag == RLPTrackActionPlay) {
        NSString *path = [sender.representedObject isKindOfClass:[NSString class]] ? sender.representedObject : nil;
        if (path.length) {
            for (NSInteger i = 0; i < (NSInteger)self.items.count; ++i) {
                if ([self.items[(NSUInteger)i].file isEqualToString:path]) { [self playFromIndex:i]; return; }
            }
        }
    }
    RLPHandleTrackAction(sender, self.view);
}

- (void)onPlayAll:(id)sender { [self playFromIndex:0]; }

/// 载入歌单并起播：先 /api/sq/play 换队列，再按该曲 file/cs/ce 真正起播。
/// cs/ce 必须带 —— 否则 CUE 分轨会从整张碟开头播（web 版明确处理过）。
- (void)playFromIndex:(NSInteger)index {
    if (!self.selectedName.length) return;
    NSString *url = [NSString stringWithFormat:@"/api/sq/play?name=%@&i=%ld",
                     RLPEnc(self.selectedName), (long)index];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"载入失败");
            RLPToast(err);
            return;
        }
        if (index < 0 || index >= (NSInteger)self_.items.count) return;
        RLPPlaylistItem *it = self_.items[index];
        NSMutableString *body = [NSMutableString stringWithFormat:@"file=%@", RLPEnc(it.file)];
        if (it.cs >= 0) [body appendFormat:@"&cs=%.3f", it.cs];
        if (it.ce > it.cs) [body appendFormat:@"&ce=%.3f", it.ce];
        RLPPostJSON(@"/api/play", body);
    }];
}

/// 输入名字对话框；返回 nil = 取消或空。
- (NSString *)promptName:(NSString *)title initial:(NSString *)initial {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = RLPTr(title);
    [a addButtonWithTitle:RLPTr(@"确定")];
    [a addButtonWithTitle:RLPTr(@"取消")];
    NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    tf.stringValue = initial ?: @"";
    a.accessoryView = tf;
    if ([a runModal] != NSAlertFirstButtonReturn) return nil;
    NSString *v = [tf.stringValue stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return v.length ? v : nil;
}

- (void)onNew:(id)sender {
    // 与 web newSavedQueueDialog 同口径：标题「新建歌单」/ 主按钮「创建」/ 占位符 + 提示小字。
    NSString *name = RLPAskText(@"新建歌单", @"创建", @"",
                                @"例如 睡眠专区",
                                @"创建一份空歌单；可通过右键歌曲或单曲页「添加到歌单」加歌");
    if (!name) return;
    NSString *url = [NSString stringWithFormat:@"/api/sq/add?name=%@", RLPEnc(name)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            NSString *created = [json[@"name"] isKindOfClass:[NSString class]] ? json[@"name"] : name;
            // web toast 带歌单名（旧实现丢了这个名字，用户图六能看到区别）。
            RLPToast([NSString stringWithFormat:@"%@%@", RLPTr(@"已新建歌单："), created]);
            self_.selectedName = created;
            [self_ reloadData];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPSavedQueuesChangedNotification"
                                                                object:nil];
        } else {
            RLPToast([json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"新建失败"));
        }
    }];
}

- (void)onSaveCurrent:(id)sender {
    NSString *name = [self promptName:RLPTr(@"把当前队列存为歌单") initial:@""];
    if (!name) return;
    NSString *url = [NSString stringWithFormat:@"/api/sq/save?name=%@", RLPEnc(name)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            RLPToast(RLPTr(@"已保存歌单"));
            [self_ reloadData];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPSavedQueuesChangedNotification"
                                                                object:nil];
        }
        else RLPToast([json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"保存失败"));
    }];
}

- (void)onRename:(id)sender {
    if (!self.selectedName.length) return;
    NSString *to = [self promptName:RLPTr(@"重命名歌单") initial:self.selectedName];
    if (!to || [to isEqualToString:self.selectedName]) return;
    NSString *url = [NSString stringWithFormat:@"/api/sq/rename?from=%@&to=%@",
                     RLPEnc(self.selectedName), RLPEnc(to)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            self_.selectedName = to;
            RLPToast(RLPTr(@"已重命名"));
            [self_ reloadData];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPSavedQueuesChangedNotification"
                                                                object:nil];
        } else {
            RLPToast([json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"重命名失败"));
        }
    }];
}

- (void)onDelete:(id)sender {
    if (!self.selectedName.length) return;
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = [NSString stringWithFormat:RLPTr(@"删除歌单「%@」？"), self.selectedName];
    a.informativeText = RLPTr(@"只删歌单记录，不删磁盘上的音乐文件。");
    [a addButtonWithTitle:RLPTr(@"删除")];
    [a addButtonWithTitle:RLPTr(@"取消")];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    NSString *url = [NSString stringWithFormat:@"/api/sq/delete?name=%@", RLPEnc(self.selectedName)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            self_.selectedName = @"";
            [self_.items removeAllObjects];
            [self_.itemTable reloadData];
            self_.playAllBtn.enabled = NO;
            self_.renameBtn.enabled = NO;
            self_.deleteBtn.enabled = NO;
            RLPToast(RLPTr(@"已删除歌单"));
            [self_ reloadData];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPSavedQueuesChangedNotification"
                                                                object:nil];
        } else {
            RLPToast([json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"删除失败"));
        }
    }];
}

#pragma mark - 数据

- (void)activate { [self reloadData]; }

- (void)reloadData {
    if (![RLPCoreClient shared].started) { [self setSubtitle:RLPTr(@"核心未启动")]; return; }
    const NSUInteger seq = ++self.listSeq;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/sq/list" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.listSeq) return;
        [self_.playlists removeAllObjects];
        NSArray *qs = [json[@"queues"] isKindOfClass:[NSArray class]] ? json[@"queues"] : @[];
        for (id x in qs) {
            if (![x isKindOfClass:[NSDictionary class]]) continue;
            RLPPlaylistRow *r = [[RLPPlaylistRow alloc] init];
            r.name = [x[@"name"] isKindOfClass:[NSString class]] ? x[@"name"] : @"";
            r.count = [x[@"n"] respondsToSelector:@selector(integerValue)] ? [x[@"n"] integerValue] : 0;
            if (r.name.length) [self_.playlists addObject:r];
        }
        [self_.listTable reloadData];
        [self_ setSubtitle:[NSString stringWithFormat:RLPTr(@"%ld 个歌单"), (long)self_.playlists.count]];
        BOOL stillThere = NO;
        for (RLPPlaylistRow *r in self_.playlists)
            if ([r.name isEqualToString:self_.selectedName]) { stillThere = YES; break; }
        if (!stillThere) {
            self_.selectedName = @"";
            [self_.items removeAllObjects];
            [self_.itemTable reloadData];
            self_.playAllBtn.enabled = NO;
            self_.renameBtn.enabled = NO;
            self_.deleteBtn.enabled = NO;
        } else {
            [self_ loadItems];
        }
    }];
}

- (void)loadItems {
    if (!self.selectedName.length || ![RLPCoreClient shared].started) return;
    const NSUInteger seq = ++self.itemSeq;
    NSString *url = [NSString stringWithFormat:@"/api/sq/info?name=%@", RLPEnc(self.selectedName)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.itemSeq) return;
        [self_.items removeAllObjects];
        if (!json || ![json[@"ok"] boolValue]) {
            [self_.itemTable reloadData];
            [self_ setSubtitle:RLPTr(@"歌单不存在（可能已被删除）")];
            return;
        }
        NSArray *arr = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[];
        for (id x in arr) {
            if (![x isKindOfClass:[NSDictionary class]]) continue;
            RLPPlaylistItem *it = [[RLPPlaylistItem alloc] init];
            it.file = [x[@"file"] isKindOfClass:[NSString class]] ? x[@"file"] : @"";
            it.cs = [x[@"cs"] respondsToSelector:@selector(doubleValue)] ? [x[@"cs"] doubleValue] : -1;
            it.ce = [x[@"ce"] respondsToSelector:@selector(doubleValue)] ? [x[@"ce"] doubleValue] : -1;
            if (it.file.length) [self_.items addObject:it];
        }
        [self_.itemTable reloadData];
        [self_ setSubtitle:[NSString stringWithFormat:RLPTr(@"%ld 首"), (long)self_.items.count]];
    }];
}

- (void)applyTheme {
    [super applyTheme];
    RLPTheme *t = [RLPTheme current];
    self.listTable.backgroundColor = t.bg2;
    self.itemTable.backgroundColor = t.bg;
    [self.listTable reloadData];
    [self.itemTable reloadData];
}

@end