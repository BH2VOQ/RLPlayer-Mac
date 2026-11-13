// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPQueueViewController.mm — 播放队列（含编辑）
//
// 后端契约（已核实）：
//   GET  /api/queue?meta=1 → {"ok":true,"items":[路径…],"index":N,"mode":0..3,
//                             "metas":[{"t":标题,"a":艺术家,"al":专辑,"d":秒}…]}
//   POST /api/qdel?i=N            移除第 N 项
//   POST /api/qmove?from=A&to=B   拖动排序
//   POST /api/qorder  body "files=<换行分隔的全量路径>"  整体重排（排序用）
//   POST /api/qsort?by=default    恢复默认顺序
//   POST /api/clear               清空
//   POST /api/sq/save?name=…      把当前队列存成歌单（**不是 sq/add**，那是新建空歌单）
//
// 右键纪律（web 版反馈 #9）：右击**只弹菜单**，绝不立刻删除。
// 用户只是想看看右键能干什么，行就消失了 —— 那是与"加入队列"完全相反的破坏性默认。
#import "RLPQueueViewController.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPSupport.h"
#import "RLPTrackActions.h"
#import "RLPTheme.h"

static NSString *const kQueueDragType = @"RLPQueueRowDrag";

@interface RLPQueueViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSTableView *table;
@property (nonatomic, strong) NSScrollView *tableScroll;
@property (nonatomic, strong) NSTextField *empty;
@property (nonatomic, copy) NSArray<NSString *> *paths;
@property (nonatomic, copy) NSArray<NSDictionary *> *metas;
@property (nonatomic, assign) NSInteger currentIndex;
@property (nonatomic, assign) NSInteger mode;
@property (nonatomic, assign) NSUInteger seq;
@end

@implementation RLPQueueViewController

- (instancetype)init {
    self = [super initWithTitle:RLPTr(@"播放队列")];
    if (self) { _paths = @[]; _metas = @[]; _currentIndex = -1; }
    return self;
}

- (void)buildContent {
    RLPTheme *t = [RLPTheme current];
    NSView *host = self.contentView;

    NSStackView *bar = [[NSStackView alloc] init];
    bar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bar.spacing = 8;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    NSArray *acts = @[
        @[ RLPTr(@"刷新"), @"refresh" ],
        @[ RLPTr(@"按标题排序"), @"title" ],
        @[ RLPTr(@"按艺术家排序"), @"artist" ],
        @[ RLPTr(@"恢复默认顺序"), @"default" ],
        @[ RLPTr(@"存为歌单"), @"save" ],
        @[ RLPTr(@"清空"), @"clear" ],
    ];
    for (NSArray *a in acts) {
        NSButton *b = [NSButton buttonWithTitle:a[0] target:self action:@selector(onAction:)];
        b.bezelStyle = NSBezelStyleRounded;
        b.identifier = a[1];
        [bar addArrangedSubview:b];
    }
    [host addSubview:bar];

    self.table = [[RLPTrackActionTableView alloc] initWithFrame:NSZeroRect];
    self.table.dataSource = self;
    self.table.delegate = self;
    // web 的行没有斑马底：开交替色时 AppKit 会把空表区域也铺满条带
    // （0 首队列也会出现一屏灰条，截图里非常明显，用户会以为是坏掉）。
    self.table.usesAlternatingRowBackgroundColors = NO;
    self.table.rowHeight = 26;
    self.table.backgroundColor = t.bg;
    // 与 web 队列行同比：句首 #、标题、艺术家、专辑、时长，**行尾 × 移除**
    //（web .qdel 每个队列行常显一个 ×；旧实现只有右键菜单，用户看不到"怎么删"）。
    NSArray *titles = @[ @"#", RLPTr(@"标题"), RLPTr(@"艺术家"), RLPTr(@"专辑"), RLPTr(@"时长"), @"" ];
    // 列宽总和必须明显小于可视宽度（922@1180）：NSTableView 的行内 cell 间距会再吃掉几十 pt，
    // 贴着上限算会让最后一列（行尾 ×）刚好落到视口外（2026-11-13 实测：x=1157 > 可视右沿）。
    NSArray *ws = @[ @34, @300, @150, @170, @64, @28 ];
    for (NSInteger i = 0; i < (NSInteger)titles.count; ++i) {
        NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"c%ld", (long)i]];
        c.title = titles[i];
        c.minWidth = 0; c.maxWidth = 10000;
        c.width = [ws[i] doubleValue];
        [self.table addTableColumn:c];
    }
    // 关键：**不要**让 NSTableView 把多余宽度摊到各列。
    // 默认(均匀)分配会把行尾 × 列推到表格右边界之外 —— 表格比滚动视口宽时，
    // 这一列就整列看不见（2026-11-13 截图抓到的：x=1157 而可视右沿只有 1150）。
    self.table.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
    // 与 web 版一致：**单击**即触发（web 的行 onclick 就是单击）。
    // 双击保留兼容；两者指向同一动作，重复触发幂等。
    self.table.action = @selector(onDouble:);
    self.table.doubleAction = @selector(onDouble:);
    self.table.target = self;

    // 右键菜单：只弹菜单，删除必须显式再点一次
    NSMenu *menu = [[NSMenu alloc] init];
    [menu addItemWithTitle:RLPTr(@"播放") action:@selector(onMenuPlay:) keyEquivalent:@""];
    [menu addItemWithTitle:RLPTr(@"从队列移除") action:@selector(onMenuRemove:) keyEquivalent:@""];
    for (NSMenuItem *mi in menu.itemArray) mi.target = self;
    self.table.menu = menu;
    // 右键改用共享菜单（与 web 一致：播放/入队/收藏/存歌单/体检/对比 + 从队列移除）
    {
        __weak __typeof__(self) ws = self;
        RLPTrackActionTableView *tv = (RLPTrackActionTableView *)self.table;
        tv.pathForRow = ^NSString *(NSInteger row) {
            __typeof__(self) s = ws;
            if (!s || row < 0 || row >= (NSInteger)s.paths.count) return nil;
            return s.paths[(NSUInteger)row];
        };
        tv.removeAction = @selector(onMenuRemove:);
        tv.removeTarget = self;
    }

    // 拖动排序
    [self.table registerForDraggedTypes:@[ kQueueDragType ]];
    self.table.draggingDestinationFeedbackStyle = NSTableViewDraggingDestinationFeedbackStyleGap;

    NSScrollView *sc = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.tableScroll = sc;
    sc.documentView = self.table;
    sc.hasVerticalScroller = YES;
    sc.drawsBackground = NO;
    sc.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:sc];

    // web：'队列是空的' + 小字'把文件拖进窗口，或右键专辑/曲目「加入队列」'（两行，居中）。
    self.empty = RLPLabel(RLPTr(@"队列是空的\n把文件拖进窗口，或右键专辑/曲目「加入队列」"), t.body, t.mut);
    self.empty.maximumNumberOfLines = 2;
    self.empty.alignment = NSTextAlignmentCenter;
    self.empty.translatesAutoresizingMaskIntoConstraints = NO;
    self.empty.hidden = YES;
    [host addSubview:self.empty];

    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:16],
        [bar.topAnchor constraintEqualToAnchor:host.topAnchor constant:8],
        [sc.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:16],
        [sc.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-16],
        [sc.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:10],
        [sc.bottomAnchor constraintEqualToAnchor:host.bottomAnchor constant:-12],
        [self.empty.centerXAnchor constraintEqualToAnchor:sc.centerXAnchor],
        [self.empty.centerYAnchor constraintEqualToAnchor:sc.centerYAnchor],
    ]];
}

#pragma mark - 布局

/// 表格宽度必须等于滚动视口的宽度：NSTableView 的列布局按**表格自己的 frame** 算，
/// 表格比视口宽时，最右侧的列会落到视口外（行尾 × 就是这么消失的）。
- (void)viewDidLayout {
    [super viewDidLayout];
    NSScrollView *sc = self.tableScroll;
    if (!sc) return;
    const NSSize clip = sc.contentSize;
    if (clip.width < 1 || clip.height < 1) return;
    [self syncTableWidth];
}

#pragma mark - 表格

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)self.paths.count; }

- (NSDictionary *)metaAt:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.metas.count) return @{};
    id m = self.metas[row];
    return [m isKindOfClass:[NSDictionary class]] ? m : @{};
}

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    RLPTheme *t = [RLPTheme current];
    NSString *ident = col.identifier;
    NSTextField *l = [tv makeViewWithIdentifier:ident owner:self];
    if (!l) { l = RLPLabel(@"", t.body, t.text); l.identifier = ident; }
    if (row < 0 || row >= (NSInteger)self.paths.count) { l.stringValue = @""; return l; }
    NSDictionary *m = [self metaAt:row];
    NSString *path = self.paths[row];
    NSString *title = [m[@"t"] isKindOfClass:[NSString class]] ? m[@"t"] : @"";
    if (!title.length) title = path.lastPathComponent.stringByDeletingPathExtension;
    if ([ident isEqualToString:@"c0"]) l.stringValue = [NSString stringWithFormat:@"%ld", (long)(row + 1)];
    else if ([ident isEqualToString:@"c1"]) l.stringValue = title;
    else if ([ident isEqualToString:@"c2"]) l.stringValue = [m[@"a"] isKindOfClass:[NSString class]] ? m[@"a"] : @"";
    else if ([ident isEqualToString:@"c3"]) l.stringValue = [m[@"al"] isKindOfClass:[NSString class]] ? m[@"al"] : @"";
    else l.stringValue = RLPFmtDuration([m[@"d"] respondsToSelector:@selector(doubleValue)] ? [m[@"d"] doubleValue] : 0);
    if ([ident isEqualToString:@"c5"]) {
        // 行尾 ×（web .qdel）：点一下**只删这一行**，不触发播放（行点击由 action 处理）。
        NSTableCellView *cell = [tv makeViewWithIdentifier:@"qdel" owner:self];
        if (!cell) {
            cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 34, 26)];
            cell.identifier = @"qdel";
            NSButton *b = [NSButton buttonWithTitle:@"\u00d7" target:self action:@selector(onRowDelete:)];
            b.bordered = NO;
            b.identifier = @"q.del";
            b.font = [NSFont systemFontOfSize:13];
            b.tag = -1;
            b.frame = NSMakeRect(4, 1, 26, 24);
            b.autoresizingMask = NSViewMinXMargin;
            [cell addSubview:b];
            cell.textField = nil;
        }
        NSButton *btn = nil;
        for (NSView *v in cell.subviews) if ([v isKindOfClass:[NSButton class]]) btn = (NSButton *)v;
        btn.tag = row;
        btn.contentTintColor = t.mut;
        btn.toolTip = RLPTr(@"从队列移除");
        cell.frame = NSMakeRect(0, 0, 34, tv.rowHeight);
        return cell;
    }
    // 当前曲用强调色标出来（用户要知道"正在播的是哪一行"）
    l.textColor = (row == self.currentIndex) ? t.accent : t.text;
    return l;
}

/// 行尾 ×：只删这一行（web .qdel），与右键菜单是两条入口，语义相同。
- (void)onRowDelete:(NSButton *)sender {
    const NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)self.paths.count) return;
    NSString *url = [NSString stringWithFormat:@"/api/qdel?i=%ld", (long)row];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && ![json[@"ok"] boolValue]) {
            RLPToast([json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"移除失败"));
        } else {
            RLPToast(RLPTr(@"已从队列移除"));
        }
        [self_ reloadData];
    }];
}

#pragma mark - 拖动排序

- (id<NSPasteboardWriting>)tableView:(NSTableView *)tv pasteboardWriterForRow:(NSInteger)row {
    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    [item setString:[NSString stringWithFormat:@"%ld", (long)row] forType:kQueueDragType];
    return item;
}

- (NSDragOperation)tableView:(NSTableView *)tv validateDrop:(id<NSDraggingInfo>)info
                 proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)op {
    // 只接受"插到某行之前"，不接受"覆盖某行"
    if (op != NSTableViewDropAbove) return NSDragOperationNone;
    return [info.draggingPasteboard.types containsObject:kQueueDragType] ? NSDragOperationMove : NSDragOperationNone;
}

- (BOOL)tableView:(NSTableView *)tv acceptDrop:(id<NSDraggingInfo>)info
              row:(NSInteger)row dropOperation:(NSTableViewDropOperation)op {
    NSString *s = [info.draggingPasteboard stringForType:kQueueDragType];
    if (!s.length) return NO;
    const NSInteger from = s.integerValue;
    if (from < 0 || from >= (NSInteger)self.paths.count) return NO;
    // DropAbove row 表示插到 row 之前；从前面往后拖时要减 1（源行会先被移走）
    NSInteger to = row;
    if (from < to) to -= 1;
    to = MAX(0, MIN(to, (NSInteger)self.paths.count - 1));
    if (from == to) return NO;
    NSString *url = [NSString stringWithFormat:@"/api/qmove?from=%ld&to=%ld", (long)from, (long)to];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
        (void)json;
        [weakSelf reloadData];
    }];
    return YES;
}

#pragma mark - 动作

- (void)onDouble:(id)sender {
    const NSInteger row = self.table.clickedRow;
    if (row < 0 || row >= (NSInteger)self.paths.count) return;
    [self playRow:row];
}

- (void)onMenuPlay:(id)sender {
    const NSInteger row = self.table.clickedRow;
    if (row >= 0) [self playRow:row];
}

/// 共享右键菜单的动作入口。
- (void)rlp_trackMenuAction:(NSMenuItem *)sender {
    RLPHandleTrackAction(sender, self.view);
}

- (void)onMenuRemove:(id)sender {
    const NSInteger row = self.table.clickedRow;
    if (row < 0 || row >= (NSInteger)self.paths.count) return;
    NSString *url = [NSString stringWithFormat:@"/api/qdel?i=%ld", (long)row];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && ![json[@"ok"] boolValue]) {
            RLPToast([json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"移除失败"));
        } else {
            RLPToast(RLPTr(@"已移除"));
        }
        [self_ reloadData];
    }];
}

- (void)playRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.paths.count) return;
    RLPPlayPath(self.paths[row]);
}

- (void)onAction:(NSButton *)sender {
    NSString *a = sender.identifier;
    if ([a isEqualToString:@"refresh"]) { [self reloadData]; return; }
    if ([a isEqualToString:@"clear"]) { [self confirmClear]; return; }
    if ([a isEqualToString:@"save"]) { [self saveAsPlaylist]; return; }
    if ([a isEqualToString:@"default"]) {
        __weak __typeof__(self) weakSelf = self;
        [[RLPCoreClient shared] postJSON:@"/api/qsort?by=default" body:nil completion:^(NSDictionary * _Nullable json) {
            (void)json;
            [weakSelf reloadData];
        }];
        return;
    }
    // 按标题 / 艺术家排序：本地算出新顺序，再整体提交 /api/qorder
    [self sortBy:a];
}

- (void)sortBy:(NSString *)key {
    if (!self.paths.count) { RLPToast(RLPTr(@"队列是空的")); return; }
    NSMutableArray<NSNumber *> *idx = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)self.paths.count; ++i) [idx addObject:@(i)];
    __weak __typeof__(self) weakSelf = self;
    NSArray<NSDictionary *> *metas = self.metas;
    NSArray<NSString *> *paths = self.paths;
    NSString *mk = [key isEqualToString:@"artist"] ? @"a" : @"t";
    [idx sortUsingComparator:^NSComparisonResult(NSNumber *x, NSNumber *y) {
        const NSInteger a = x.integerValue, b = y.integerValue;
        NSDictionary *ma = (a < (NSInteger)metas.count && [metas[a] isKindOfClass:[NSDictionary class]]) ? metas[a] : @{};
        NSDictionary *mb = (b < (NSInteger)metas.count && [metas[b] isKindOfClass:[NSDictionary class]]) ? metas[b] : @{};
        NSString *sa = [ma[mk] isKindOfClass:[NSString class]] ? ma[mk] : @"";
        NSString *sb = [mb[mk] isKindOfClass:[NSString class]] ? mb[mk] : @"";
        if (!sa.length) sa = paths[a].lastPathComponent;
        if (!sb.length) sb = paths[b].lastPathComponent;
        return [sa localizedStandardCompare:sb];
    }];
    NSMutableArray<NSString *> *ordered = [NSMutableArray array];
    for (NSNumber *n in idx) [ordered addObject:paths[n.integerValue]];
    NSString *body = [NSString stringWithFormat:@"files=%@",
                      RLPEnc([ordered componentsJoinedByString:@"\n"])];
    [[RLPCoreClient shared] postJSON:@"/api/qorder" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && ![json[@"ok"] boolValue]) {
            RLPToast([json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"排序失败"));
        }
        [self_ reloadData];
    }];
}

- (void)confirmClear {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = RLPTr(@"确定清空播放队列？");
    a.informativeText = RLPTr(@"只清队列，不删磁盘上的音乐文件。");
    [a addButtonWithTitle:RLPTr(@"清空")];
    [a addButtonWithTitle:RLPTr(@"取消")];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/clear" body:nil completion:^(NSDictionary * _Nullable json) {
        (void)json;
        [weakSelf reloadData];
    }];
}

- (void)saveAsPlaylist {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = RLPTr(@"把当前队列存为歌单");
    [a addButtonWithTitle:RLPTr(@"保存")];
    [a addButtonWithTitle:RLPTr(@"取消")];
    NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    tf.placeholderString = RLPTr(@"歌单名称");
    a.accessoryView = tf;
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    NSString *name = [tf.stringValue stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!name.length) { RLPToast(RLPTr(@"请先填写歌单名称")); return; }
    // sq/save = 存当前队列；sq/add 是新建空歌单（两者不能混）
    NSString *url = [NSString stringWithFormat:@"/api/sq/save?name=%@", RLPEnc(name)];
    [[RLPCoreClient shared] postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
        if (json && [json[@"ok"] boolValue]) RLPToast(RLPTr(@"已保存歌单"));
        else RLPToast([json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"保存失败"));
    }];
}

#pragma mark - 数据

- (void)activate { [self reloadData]; }

/// 让表格宽度严格等于滚动视口宽度（见 viewDidLayout 注释）。
- (void)syncTableWidth {
    NSScrollView *sc = self.tableScroll;
    if (!sc || !self.table) return;
    const NSSize cs = sc.contentSize;
    if (cs.width < 1) return;
    NSRect f = self.table.frame;
    if (fabs(f.size.width - cs.width) > 0.5) f.size.width = cs.width;
    f.size.height = MAX(cs.height, (CGFloat)self.paths.count * self.table.rowHeight);
    if (!NSEqualRects(f, self.table.frame)) self.table.frame = f;
}

- (void)reloadData {
    if (![RLPCoreClient shared].started) { [self setSubtitle:RLPTr(@"核心未启动")]; return; }
    const NSUInteger seq = ++self.seq;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/queue?meta=1" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.seq) return;
        if (!json || ![json[@"ok"] boolValue]) {
            [self_ setSubtitle:RLPTr(@"读取失败")];
            return;
        }
        NSArray *items = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[];
        NSMutableArray<NSString *> *ps = [NSMutableArray array];
        for (id x in items) if ([x isKindOfClass:[NSString class]]) [ps addObject:x];
        self_.paths = ps;
        NSArray *ms = [json[@"metas"] isKindOfClass:[NSArray class]] ? json[@"metas"] : @[];
        NSMutableArray<NSDictionary *> *mm = [NSMutableArray array];
        for (id x in ms) [mm addObject:[x isKindOfClass:[NSDictionary class]] ? x : @{}];
        self_.metas = mm;
        self_.currentIndex = [json[@"index"] respondsToSelector:@selector(integerValue)] ? [json[@"index"] integerValue] : -1;
        self_.mode = [json[@"mode"] respondsToSelector:@selector(integerValue)] ? [json[@"mode"] integerValue] : 0;
        [self_.table reloadData];
        self_.empty.hidden = ps.count > 0;
        NSArray *names = @[ RLPTr(@"顺序"), RLPTr(@"列表循环"), RLPTr(@"单曲循环"), RLPTr(@"随机") ];
        NSString *mn = names[MIN(MAX(self_.mode, 0), 3)];
        [self_ setSubtitle:[NSString stringWithFormat:RLPTr(@"%ld 首 · 当前第 %ld 首 · %@"),
                            (long)ps.count, (long)(self_.currentIndex + 1), mn]];
        [self_ syncTableWidth];
    }];
}

- (void)applyTheme {
    [super applyTheme];
    RLPTheme *t = [RLPTheme current];
    self.table.backgroundColor = t.bg;
    self.empty.textColor = t.mut;
    [self.table reloadData];
}

@end