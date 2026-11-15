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
// 页内不再持有歌单列表：列表在侧栏（web #sqList 同址）。页面只负责"当前这份歌单"。
@property (nonatomic, strong) NSTableView *itemTable;
@property (nonatomic, strong) NSMutableArray<RLPPlaylistRow *> *playlists;
@property (nonatomic, strong) NSMutableArray<RLPPlaylistItem *> *items;
@property (nonatomic, copy) NSString *selectedName;
@property (nonatomic, strong) NSButton *playAllBtn;
@property (nonatomic, strong) NSButton *renameBtn;
@property (nonatomic, strong) NSButton *deleteBtn;
@property (nonatomic, strong) NSTextField *emptyLabel;   // web 空态「这个歌单是空的」
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
    // 侧栏点某份歌单 = web renderSavedQueuePage(name)：同一入口负责 title/count/表格/按钮。
    [self openPlaylist:obj];
}

- (void)onSavedQueuesChangedNote:(NSNotification *)note {
    (void)note;
    [self reloadData];
}

/// 按名字定位歌单（页内已没有列表：真实列表在侧栏；这里只负责记下当前名）。
- (void)selectRowForName:(NSString *)name {
    (void)name;
}

- (void)buildContent {
    RLPTheme *t = [RLPTheme current];
    NSView *host = self.contentView;

    // 结构对齐 web renderSavedQueuePage（ui_script.h:3760+）：
    //   head(name, N 首, [播放整列][重命名][删除])  →  曲目表（# / 标题 / 所在目录）
    //   →  空态整块 "这个歌单是空的"
    // **不再有页内左侧歌单列表**：web 的歌单列表在**左导航**（#sqList），原生同一份也在侧栏。
    // 页内再放一份等于两处真相源（点哪边都改选中，选中态还会分叉）。
    // 「新建」「存当前队列」是原生侧保留的入口（功能不能删），并入同一行按钮，位置向 web 靠拢。
    NSButton *playAll = [NSButton buttonWithTitle:RLPTr(@"播放整列") target:self action:@selector(onPlayAll:)];
    NSButton *rename = [NSButton buttonWithTitle:RLPTr(@"重命名") target:self action:@selector(onRename:)];
    NSButton *del = [NSButton buttonWithTitle:RLPTr(@"删除") target:self action:@selector(onDelete:)];
    NSButton *newBtn = [NSButton buttonWithTitle:RLPTr(@"新建") target:self action:@selector(onNew:)];
    NSButton *saveBtn = [NSButton buttonWithTitle:RLPTr(@"存当前队列") target:self action:@selector(onSaveCurrent:)];
    self.playAllBtn = playAll; self.renameBtn = rename; self.deleteBtn = del;
    playAll.identifier = @"sq.playall";
    rename.identifier = @"sq.rename";
    del.identifier = @"sq.delete";
    newBtn.identifier = @"sq.new";
    saveBtn.identifier = @"sq.savecurrent";
    NSStackView *bar = [[NSStackView alloc] init];
    bar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bar.spacing = 8;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.identifier = @"sq.header";
    for (NSButton *b in @[ playAll, rename, del, newBtn, saveBtn ]) {
        b.bezelStyle = NSBezelStyleRounded;
        b.controlSize = NSControlSizeSmall;
        [bar addArrangedSubview:b];
    }
    playAll.enabled = NO; rename.enabled = NO; del.enabled = NO;
    [host addSubview:bar];

    // 空态：web `D('list').innerHTML = '<div class=empty>这个歌单是空的</div>'`
    self.emptyLabel = RLPLabel(RLPTr(@"这个歌单是空的"), t.body, t.mut);
    self.emptyLabel.identifier = @"sq.empty.list";
    self.emptyLabel.alignment = NSTextAlignmentCenter;
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.hidden = YES;   // 真正 addSubview 在表格之后（见下），这里是先建对象

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
    self.itemTable.usesAlternatingRowBackgroundColors = NO;   // web 的行没有斑马底（截图里的条带就是它）
    self.itemTable.rowHeight = 30;
    self.itemTable.backgroundColor = t.bg;
    NSArray<NSString *> *cols = @[ @"#", RLPTr(@"标题"), RLPTr(@"所在目录") ];
    NSArray<NSNumber *> *widths = @[ @44, @520, @360 ];
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
    // 空态文字必须在表格之上：表格背景是不透明主题色，先加就会被它整个盖住
    // （2026-11-13 截图里"这个歌单是空的"看不到就是这个原因，不是没渲染）。
    [host addSubview:self.emptyLabel positioned:NSWindowAbove relativeTo:is];

    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:16],
        [bar.topAnchor constraintEqualToAnchor:host.topAnchor constant:8],
        [bar.trailingAnchor constraintLessThanOrEqualToAnchor:host.trailingAnchor constant:-16],
        [is.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:16],
        [is.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-16],
        [is.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:8],
        [is.bottomAnchor constraintEqualToAnchor:host.bottomAnchor constant:-12],
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:host.centerXAnchor],
        [self.emptyLabel.topAnchor constraintEqualToAnchor:host.topAnchor constant:120],
    ]];
}

#pragma mark - 表格

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    (void)tv;
    return (NSInteger)self.items.count;
}

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    RLPTheme *t = [RLPTheme current];
    NSString *ident = col.identifier;
    NSTextField *label = [tv makeViewWithIdentifier:ident owner:self];
    if (!label) {
        label = RLPLabel(@"", t.body, t.text);
        label.identifier = ident;
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

/// 兼容旧入口（页内列表已移除，列表在侧栏）：仍然可用于按名字切换当前歌单。
- (void)onListSelect:(id)sender {
    (void)sender;
}

- (void)openPlaylist:(NSString *)name {
    self.selectedName = name ?: @"";
    const BOOL has = self.selectedName.length > 0;
    // P8：顶栏标题 = 歌单名（web head(name, it.length + ' 首', …)）。旧实现只读 pageTitle，
    // 歌单页标题于是永远停在「歌单」；没有选中具体歌单时回到页面名。
    self.pageTitle = has ? self.selectedName : RLPTr(@"歌单");
    self.playAllBtn.enabled = has;
    self.renameBtn.enabled = has;
    self.deleteBtn.enabled = has;
    // web renderSavedQueuePage 的中间态：head(name, '加载中…', '')，info 回来后再换成「N 首」。
    [self setSubtitle:has ? RLPTr(@"加载中…") : @""];
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
    // P3：单曲循环（mode==2）下"播放整列/点第 N 首"会卡在同一首无限重复。
    // web ensureSequentialMode 同口径：起播前先读模式，是 2 就切回列表循环(1)。
    // 与「我的最爱」整列播放共用 RLPSupport 的同一守卫（不各写一套）。
    __weak __typeof__(self) weakSelf = self;
    RLPEnsureSequentialMode(^{
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        [self_ loadQueueAndPlayAt:index];
    });
}

/// 起播后半段：/api/sq/play 换队列 → 按该曲 file/cs/ce 真正 /api/play。
- (void)loadQueueAndPlayAt:(NSInteger)index {
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
            [self_ setPageTitle:to];
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
            [self_ setPageTitle:RLPTr(@"歌单")];
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
        BOOL stillThere = NO;
        for (RLPPlaylistRow *r in self_.playlists)
            if ([r.name isEqualToString:self_.selectedName]) { stillThere = YES; break; }
        if (!stillThere) {
            self_.selectedName = @"";
            [self_ setPageTitle:RLPTr(@"歌单")];
            [self_ setSubtitle:[NSString stringWithFormat:RLPTr(@"%ld 个歌单"), (long)self_.playlists.count]];
            [self_.items removeAllObjects];
            [self_.itemTable reloadData];
            self_.playAllBtn.enabled = NO;
            self_.renameBtn.enabled = NO;
            self_.deleteBtn.enabled = NO;
            // P8：顶栏计数 = 歌单个数（主窗口顶栏 #cnt 的 RLPPageCountNotification 接缝）。
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPPageCountNotification"
                object:[NSString stringWithFormat:RLPTr(@"%ld 个歌单"), (long)self_.playlists.count]];
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
            // web：失败分支 head(name, '', '') —— 标题仍是歌单名，计数清空。
            [self_ setSubtitle:RLPTr(@"歌单不存在（可能已被删除）")];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPPageCountNotification" object:@""];
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
        // web：空歌单整块显示「这个歌单是空的」（不是一行小字，也不是空表格）
        self_.emptyLabel.hidden = self_.items.count > 0;
        NSString *count = [NSString stringWithFormat:RLPTr(@"%ld 首"), (long)self_.items.count];
        [self_ setSubtitle:count];
        // P8：web head(name, it.length + ' 首') 的第二个参数画在顶栏标题旁（#cnt）。
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPPageCountNotification" object:count];
    }];
}

- (void)applyTheme {
    [super applyTheme];
    RLPTheme *t = [RLPTheme current];
    self.itemTable.backgroundColor = t.bg;
    self.emptyLabel.textColor = t.mut;
    [self.itemTable reloadData];
}

@end