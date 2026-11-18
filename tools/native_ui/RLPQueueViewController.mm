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
#import <objc/runtime.h>

static NSString *const kQueueDragType = @"com.rta.rlplayer.queue-row";
static const void *kRLPQueueDeletePathKey = &kRLPQueueDeletePathKey;

/// 队列行视图：web `.qrow` 的 hover / 当前行 / 底部分隔线。
/// 悬停状态由 RLPHoverRowView 的 tracking area 提供（判据入口 setHoveredForAudit:），
/// 控制器据此决定行尾 × 是否显示（web `.qdel` opacity 0 → hover 1）。
@interface RLPQueueRowView : RLPHoverRowView
@property (nonatomic, assign) BOOL currentRow;
@property (nonatomic, copy, nullable) void (^onHoverChanged)(RLPQueueRowView *rowView, BOOL hovered);
@end

@implementation RLPQueueRowView
- (void)setHoveredForAudit:(BOOL)hovered {
    [super setHoveredForAudit:hovered];
    if (self.onHoverChanged) self.onHoverChanged(self, hovered);
}
- (void)drawBackgroundInRect:(NSRect)dirtyRect {
    [super drawBackgroundInRect:dirtyRect];
    RLPTheme *t = [RLPTheme current];
    // web .qrow.on 背景 --acc-weak（在悬停色之下、选中高亮之上，当前行始终可见）。
    if (self.currentRow) {
        [t.accentWeak setFill];
        NSRectFill(dirtyRect);
    }
    // web .qrow border-bottom:1px solid var(--line)。
    [t.line setFill];
    const CGFloat y = self.isFlipped ? NSMaxY(self.bounds) - 1 : 0;
    NSRectFill(NSMakeRect(0, y, NSWidth(self.bounds), 1));
}
@end

@interface RLPQueueViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSTableView *table;
@property (nonatomic, strong) NSScrollView *tableScroll;
@property (nonatomic, strong) NSTextField *empty;
@property (nonatomic, copy) NSArray<NSString *> *paths;
@property (nonatomic, copy) NSArray<NSDictionary *> *metas;
// web S.q.cues：/api/queue?meta=1 的 [cs,ce] 数组，排序/播放都必须带上（否则 CUE 分轨会丢区间）。
@property (nonatomic, copy) NSArray<NSArray<NSNumber *> *> *cues;
@property (nonatomic, assign) NSInteger currentIndex;
/// 最近一次 /api/status 的播放中状态（仅用于「播放中不许替换队列」的守卫）。
@property (nonatomic, assign) BOOL isPlayingNow;
@property (nonatomic, assign) NSInteger mode;
@property (nonatomic, assign) NSUInteger seq;
@property (nonatomic, strong) NSPopUpButton *sortPopup;
/// 已生效的排序档（P6：失败时把下拉回滚到这里；web 用未改写的 S.queueSort 重渲染）。
@property (nonatomic, copy) NSString *sortKey;
/// P7：空队列时「保存为歌单」必须禁用（web 空队列根本不渲染保存按钮）。
@property (nonatomic, strong) NSButton *saveButton;
@property (nonatomic, strong) NSTextField *sortLabel;
@property (nonatomic, strong) NSMutableArray<NSButton *> *actionButtons;
@property (nonatomic, assign) BOOL hasLoaded;
@property (nonatomic, assign) NSInteger hoveredRow;
/// 行删除的「同一时刻只允许一个在途」闸门：连点行尾 × / 右键重复时，
/// 第二次用的还是旧 tag，会把顶上来那一首也删掉（2026-11-18 夜间评审 A1）。
@property (nonatomic, assign) BOOL deleteInFlight;
@property (nonatomic, assign) BOOL saveInFlight;
/// 队列重排（排序 / 拖动排序）在途：这期间任何刷新快照都不得落到表格上。
/// 证据：页面把队列落到表格只有 reloadData / applyQueueSnapshot 两条路径，
/// 它们由 onExternalQueueChanged / activate / 任何轮询接线调用；排序/拖动在途时
/// 这些回包里的旧快照会覆盖刚提交的新顺序，并让拖动的行号错位。
@property (nonatomic, assign) BOOL sortInFlight;
@property (nonatomic, assign) BOOL moveInFlight;
/// 拖动会话进行中：此时刷新同样不得改列表（AppKit 的拖动源行号会失效）。
@property (nonatomic, assign) BOOL dragSessionActive;
@property (nonatomic, copy) NSString *lastPlayKey;
@property (nonatomic, assign) NSTimeInterval lastPlayAt;
- (void)restoreSortSelection:(NSString *)key;
- (void)savePlaylistNamed:(NSString *)name;
- (void)applyQueueSnapshot:(NSDictionary *)json;
@end

@implementation RLPQueueViewController

- (instancetype)init {
    self = [super initWithTitle:RLPTr(@"播放队列")];
    if (self) {
        _paths = @[]; _metas = @[]; _cues = @[]; _currentIndex = -1; _hoveredRow = -1;
        _sortKey = @"default";
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onExternalQueueChanged:)
                                                     name:RLPQueueChangedNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)onExternalQueueChanged:(NSNotification *)note {
    if (note.object == self) return;
    if (![RLPCoreClient shared].started) return;
    [self reloadData];
}

- (void)buildContent {
    RLPTheme *t = [RLPTheme current];
    NSView *host = self.contentView;

    NSStackView *bar = [[NSStackView alloc] init];
    bar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bar.spacing = 8;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    // web 的排序是一个下拉（#qSort: 默认 / 标题 / 艺术家 / …），不是三个按钮。
    self.sortPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    // web #qSort 的 8 档，顺序/representedObject 逐值照抄（ui_script.h:12564-12574）。
    NSArray<NSArray<NSString *> *> *sortSpecs = @[
        @[ @"default", RLPTr(@"默认顺序") ], @[ @"title", RLPTr(@"标题") ],
        @[ @"artist", RLPTr(@"艺术家") ], @[ @"album", RLPTr(@"专辑") ],
        @[ @"dur", RLPTr(@"时长") ], @[ @"year", RLPTr(@"年份") ],
        @[ @"shuffle", RLPTr(@"随机打乱") ], @[ @"reverse", RLPTr(@"反转顺序") ] ];
    for (NSArray<NSString *> *spec in sortSpecs) {
        [self.sortPopup addItemWithTitle:spec[1]];
        NSMenuItem *item = self.sortPopup.lastItem;
        item.representedObject = spec[0];
        item.target = self;
        item.action = @selector(onSortMenuItemPicked:);
    }
    self.sortPopup.identifier = @"queue.sort";   // 对应 web #qSort（parity_map ctrl）
    self.sortPopup.target = self;
    self.sortPopup.action = @selector(onSortPicked:);
    [self.sortPopup selectItemAtIndex:0];   // 生效档位 = 默认顺序（P6 回滚基准）
    self.sortPopup.translatesAutoresizingMaskIntoConstraints = NO;
    self.sortLabel = RLPLabel(RLPTr(@"排序："), [NSFont systemFontOfSize:11], [RLPTheme current].mut2);
    [bar addArrangedSubview:self.sortLabel];
    [bar addArrangedSubview:self.sortPopup];
    self.actionButtons = [NSMutableArray array];
    NSArray *acts = @[
        @[ RLPTr(@"刷新"), @"refresh" ],
        @[ RLPTr(@"保存为歌单"), @"save" ],
        @[ RLPTr(@"导入 M3U 到队列"), @"qImportM3u" ],   // v3.3.11 新增
        @[ RLPTr(@"清空队列"), @"clear" ],
    ];
    for (NSArray *a in acts) {
        NSButton *b = [NSButton buttonWithTitle:a[0] target:self action:@selector(onAction:)];
        b.bezelStyle = NSBezelStyleRounded;
        b.identifier = a[1];
        [bar addArrangedSubview:b];
        [self.actionButtons addObject:b];
        if ([a[1] isEqualToString:@"save"]) {
            self.saveButton = b;
            b.enabled = NO;   // P7：队列数据回来之前不可保存（空队列不弹框、不发请求）
        }
    }
    [host addSubview:bar];

    self.table = [[RLPTrackActionTableView alloc] initWithFrame:NSZeroRect];
    self.table.dataSource = self;
    self.table.delegate = self;
    // web 的行没有斑马底：开交替色时 AppKit 会把空表区域也铺满条带
    // （0 首队列也会出现一屏灰条，截图里非常明显，用户会以为是坏掉）。
    self.table.usesAlternatingRowBackgroundColors = NO;
    // web .qrow：padding 9 18 + 12.5 正文 ≈ 38pt 行高；无列头（页面自带排序栏）。
    self.table.rowHeight = 38;
    self.table.intercellSpacing = NSMakeSize(0, 0);
    self.table.backgroundColor = t.bg;
    self.table.headerView = nil;
    if (@available(macOS 11.0, *)) self.table.style = NSTableViewStylePlain;
    // 4 列 = web .qrow 的四个子元素：序号 / 标题 / 所在文件夹 / 行尾 ×。
    NSArray<NSString *> *colIDs = @[ @"q.n", @"q.t", @"q.f", @"q.del" ];
    for (NSString *cid in colIDs) {
        NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:cid];
        c.title = @"";
        c.minWidth = 0; c.maxWidth = 10000;
        c.width = [cid isEqualToString:@"q.n"] ? 26.0 : ([cid isEqualToString:@"q.del"] ? 24.0 : 300.0);
        [self.table addTableColumn:c];
    }
    // 关键：**不要**让 NSTableView 把多余宽度摊到各列。
    // 默认(均匀)分配会把行尾 × 列推到表格右边界之外 —— 表格比滚动视口宽时，
    // 这一列就整列看不见（2026-11-13 截图抓到的：x=1157 而可视右沿只有 1150）。
    self.table.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
    // 与 web 版一致：**单击**即触发（web 的行 onclick 就是单击）。
    // 双击保留兼容；两者指向同一动作，重复触发幂等。
    self.table.action = @selector(onDouble:);
    // web 队列行是单击起播：doubleAction 再指同一动作会让一次双击触发两遍。
    self.table.doubleAction = NULL;
    self.table.target = self;

    // 右键菜单 = RLPTrackActionTableView 的共享菜单（menuForEvent 按被点行构造）。
    // 旧静态菜单挂到 table.menu 但从未生效（P11 死代码，删除）；「从队列移除」仍由
    // removeAction 接进共享菜单，删除入口不丢。    // 右键改用共享菜单（与 web 一致：播放/入队/收藏/存歌单/体检/对比 + 从队列移除）
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
    self.empty = RLPLabel([RLPTr(@"队列是空的") stringByAppendingFormat:@"\n%@", RLPTr(@"把文件拖进窗口，或右键专辑/曲目「加入队列」")], t.body, t.mut);
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
    [self layoutQueueColumnsForWidth:clip.width];
}

#pragma mark - 行悬停（web .qrow:hover；× 仅悬停时显示）

/// web .qrow 的所在文件夹名（只显示 basename，全路径放 tooltip）。
/// macOS 路径分隔符固定为 /，与 web `parentFolder()` 同语义。
static NSString *RLPQueueParentFolder(NSString *path) {
    if (!path.length) return @"";
    NSString *dir = [path stringByDeletingLastPathComponent];
    NSString *name = dir.lastPathComponent;
    return name.length ? name : dir;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    RLPQueueRowView *v = [[RLPQueueRowView alloc] initWithFrame:NSZeroRect];
    v.hoverColor = [RLPTheme current].hov;
    v.currentRow = (row == self.currentIndex);
    __weak __typeof__(self) ws = self;
    v.onHoverChanged = ^(RLPQueueRowView *rv, BOOL hovered) {
        __typeof__(self) s = ws;
        if (!s) return;
        const NSInteger r = [tableView rowForView:rv];
        if (r < 0) return;
        if (hovered) s.hoveredRow = r;
        else if (s.hoveredRow == r) s.hoveredRow = -1;
        // 只刷行尾 × 这一列，避免整表重绘导致悬停闪烁。
        [tableView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)r]
                             columnIndexes:[NSIndexSet indexSetWithIndex:3]];
    };
    return v;
}

#pragma mark - 表格

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { (void)tv; return (NSInteger)self.paths.count; }

- (NSDictionary *)metaAt:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.metas.count) return @{};
    id m = self.metas[row];
    return [m isKindOfClass:[NSDictionary class]] ? m : @{};
}

/// 响应式列宽：web .qrow 的四个 flex 子项（序号 26、标题 flex、文件夹 max 38%、× 24）。
- (void)layoutQueueColumnsForWidth:(CGFloat)width {
    if (!self.table || width < 80) return;
    const CGFloat nW = 26.0, delW = 24.0;
    const CGFloat folderW = MIN(width * 0.38, MAX(60.0, width * 0.38));
    const CGFloat titleW = MAX(40.0, width - nW - delW - folderW);
    NSDictionary<NSString *, NSNumber *> *ws = @{ @"q.n": @(nW), @"q.t": @(titleW),
                                                  @"q.f": @(folderW), @"q.del": @(delW) };
    for (NSTableColumn *c in self.table.tableColumns) {
        NSNumber *w = ws[c.identifier];
        if (w) c.width = w.doubleValue;
    }
    [self.table tile];
}

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    RLPTheme *t = [RLPTheme current];
    NSString *ident = col.identifier;
    if (row < 0 || row >= (NSInteger)self.paths.count) return nil;
    NSString *path = self.paths[(NSUInteger)row];
    NSDictionary *m = [self metaAt:row];
    NSString *reuse = [ident stringByAppendingString:@".cell"];

    if ([ident isEqualToString:@"q.del"]) {
        // web .qdel：24×24、radius 6、默认 opacity 0，行悬停才出现（点击只删这一行）。
        NSTableCellView *cell = [tv makeViewWithIdentifier:reuse owner:self];
        if (!cell) {
            cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 24, tv.rowHeight)];
            cell.identifier = reuse;
            NSButton *b = [NSButton buttonWithTitle:@"\u00d7" target:self action:@selector(onRowDelete:)];
            b.bordered = NO;
            b.identifier = @"q.del";
            b.font = [NSFont systemFontOfSize:13];
            b.wantsLayer = YES;
            b.layer.cornerRadius = 6;
            b.translatesAutoresizingMaskIntoConstraints = NO;
            [cell addSubview:b];
            [NSLayoutConstraint activateConstraints:@[
                [b.centerXAnchor constraintEqualToAnchor:cell.centerXAnchor],
                [b.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
                [b.widthAnchor constraintEqualToConstant:24],
                [b.heightAnchor constraintEqualToConstant:24],
            ]];
            cell.textField = nil;
        }
        NSButton *btn = nil;
        for (NSView *v in cell.subviews) if ([v isKindOfClass:[NSButton class]]) btn = (NSButton *)v;
        btn.tag = row;
        if (btn) {
            objc_setAssociatedObject(btn,
                                     kRLPQueueDeletePathKey,
                                     [path isKindOfClass:[NSString class]] ? path : nil,
                                     OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        btn.contentTintColor = t.mut2;
        btn.toolTip = RLPTr(@"从队列移除");
        // 悬停行显示，其它行透明（web .qrow:hover .qdel opacity:1）。
        btn.alphaValue = (row == self.hoveredRow) ? 1.0 : 0.0;
        cell.frame = NSMakeRect(0, 0, 24, tv.rowHeight);
        return cell;
    }

    NSTableCellView *cell = [tv makeViewWithIdentifier:reuse owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, MAX(20, col.width), tv.rowHeight)];
        cell.identifier = reuse;
        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        tf.maximumNumberOfLines = 1;
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.identifier = ident;
        [cell addSubview:tf];
        cell.textField = tf;
        // web .qrow padding 9 18：单元格左右各内缩 10pt（行间 gap 12 由列宽承担）。
        [NSLayoutConstraint activateConstraints:@[
            [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:10.0],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-10.0],
            [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }
    NSTextField *tf = cell.textField;
    tf.alignment = NSTextAlignmentLeft;
    tf.textColor = t.text;
    tf.font = [NSFont systemFontOfSize:12.5];
    tf.toolTip = nil;
    cell.toolTip = nil;

    if ([ident isEqualToString:@"q.n"]) {
        tf.alignment = NSTextAlignmentRight;
        tf.textColor = t.mut2;
        tf.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
        tf.stringValue = [NSString stringWithFormat:@"%ld", (long)(row + 1)];
    } else if ([ident isEqualToString:@"q.t"]) {
        NSString *title = [m[@"t"] isKindOfClass:[NSString class]] ? m[@"t"] : @"";
        if (!title.length) title = path.lastPathComponent.stringByDeletingPathExtension;
        const BOOL current = (row == self.currentIndex);
        // web .qrow.on .qt{color:--acc-text;font-weight:650}。
        tf.font = [NSFont systemFontOfSize:12.5 weight:current ? NSFontWeightSemibold : NSFontWeightRegular];
        tf.textColor = current ? t.accentText : t.text;
        tf.stringValue = title;
        tf.toolTip = path;   // web .qt title = 全路径
    } else if ([ident isEqualToString:@"q.f"]) {
        tf.alignment = NSTextAlignmentLeft;
        tf.textColor = t.mut2;
        tf.font = [NSFont systemFontOfSize:11];
        tf.stringValue = RLPQueueParentFolder(path);
        tf.toolTip = path;   // web .qp title = 全路径
        cell.toolTip = path;
    }
    return cell;
}

- (void)clearHoveredRowAfterDelete {
    const NSInteger prev = self.hoveredRow;
    self.hoveredRow = -1;
    if (prev >= 0 && self.table && prev < self.table.numberOfRows &&
        prev < (NSInteger)self.paths.count && self.table.numberOfColumns > 3) {
        [self.table reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)prev]
                              columnIndexes:[NSIndexSet indexSetWithIndex:3]];
    }
}

- (void)deleteRow:(NSInteger)row capturedPath:(NSString *)capturedPath successToast:(NSString *)successToast {
    if (self.deleteInFlight) return;   // 删除在途时拒绝同 index 重复删除（并避免并发删除导致索引漂移）
    // 排序/拖动在途：qdel 的索引与在途 qorder/qmove 共用同一队列，
    // 若在途请求先落地，验证过的索引会指向另一首 ⟹ 拒绝这一次删除。
    if (self.sortInFlight || self.moveInFlight || self.dragSessionActive) {
        RLPToast(RLPTr(@"正在更新…"));
        return;
    }
    if (row < 0) {
        if (capturedPath.length) {
            [self clearHoveredRowAfterDelete];
            RLPToast(RLPTr(@"移除失败"));
            [self reloadData];
        }
        return;
    }
    if (row >= (NSInteger)self.paths.count) {
        if (capturedPath.length) {
            [self clearHoveredRowAfterDelete];
            RLPToast(RLPTr(@"移除失败"));
            [self reloadData];
        }
        return;
    }
    id localObj = self.paths[(NSUInteger)row];
    NSString *localPath = [localObj isKindOfClass:[NSString class]] ? (NSString *)localObj : nil;
    NSString *expectedPath = capturedPath.length ? [capturedPath copy] : [localPath copy];
    if (!expectedPath.length) return;
    if (capturedPath.length && ![localPath isEqualToString:expectedPath]) {
        [self clearHoveredRowAfterDelete];
        RLPToast(RLPTr(@"移除失败"));
        [self reloadData];
        return;
    }
    self.deleteInFlight = YES;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/queue?meta=1" completion:^(NSDictionary * _Nullable qjson) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *items = ([qjson isKindOfClass:[NSDictionary class]] &&
                          (!qjson[@"ok"] || [qjson[@"ok"] boolValue]) &&
                          [qjson[@"items"] isKindOfClass:[NSArray class]])
                       ? qjson[@"items"] : nil;
        id remoteObj = (items && row < (NSInteger)items.count) ? items[(NSUInteger)row] : nil;
        id curObj = (row < (NSInteger)self_.paths.count) ? self_.paths[(NSUInteger)row] : nil;
        const BOOL remoteMatch = ([remoteObj isKindOfClass:[NSString class]] &&
                                  [(NSString *)remoteObj isEqualToString:expectedPath]);
        const BOOL localMatch = ([curObj isKindOfClass:[NSString class]] &&
                                 [(NSString *)curObj isEqualToString:expectedPath]);
        if (!remoteMatch || !localMatch) {
            self_.deleteInFlight = NO;
            [self_ clearHoveredRowAfterDelete];
            RLPToast(RLPTr(@"移除失败"));
            [self_ reloadData];
            return;
        }
        NSString *url = [NSString stringWithFormat:@"/api/qdel?i=%ld", (long)row];
        [[RLPCoreClient shared] postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
            __typeof__(self) self2 = weakSelf;
            if (!self2) return;
            self2.deleteInFlight = NO;
            [self2 clearHoveredRowAfterDelete];
            if (!json || ![json[@"ok"] boolValue]) {
                NSString *err = ([json[@"error"] isKindOfClass:[NSString class]] && [(NSString *)json[@"error"] length])
                              ? json[@"error"] : RLPTr(@"移除失败");
                RLPToast(err);
                [self2 reloadData];
                return;
            }
            RLPToast(successToast);
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPQueueChangedNotification object:self2];
            [self2 reloadData];
        }];
    }];
}

/// 行尾 ×：只删这一行（web .qdel），与右键菜单是两条入口，语义相同。
- (void)onRowDelete:(NSButton *)sender {
    const NSInteger row = sender ? sender.tag : -1;
    id assoc = sender ? objc_getAssociatedObject(sender, kRLPQueueDeletePathKey) : nil;
    NSString *capturedPath = [assoc isKindOfClass:[NSString class]] ? (NSString *)assoc : nil;
    [self deleteRow:row capturedPath:capturedPath successToast:RLPTr(@"已从队列移除")];
}

#pragma mark - 拖动排序

- (id<NSPasteboardWriting>)tableView:(NSTableView *)tv pasteboardWriterForRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.paths.count) return nil;
    // 负载必须带**行身份**（路径 + CUE 区间），不能只带行号：
    // 1s 轮询/外部通知的刷新会让同一行号指向另一首，落下时 qmove 就会搬错歌。
    id pathObj = self.paths[(NSUInteger)row];
    if (![pathObj isKindOfClass:[NSString class]]) return nil;
    double cs = -1.0, ce = -1.0;
    if (row < (NSInteger)self.cues.count) {
        NSArray<NSNumber *> *cue = self.cues[(NSUInteger)row];
        if (cue.count >= 2) { cs = cue[0].doubleValue; ce = cue[1].doubleValue; }
    }
    NSDictionary *payload = @{ @"row": @(row), @"path": (NSString *)pathObj,
                               @"cs": @(cs), @"ce": @(ce) };
    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    [item setPropertyList:payload forType:kQueueDragType];
    return item;
}

#pragma mark - 拖动会话（拖动期间冻结刷新）

- (void)tableView:(NSTableView *)tableView draggingSession:(NSDraggingSession *)session
    willBeginAtPoint:(NSPoint)screenPoint forRowIndexes:(NSIndexSet *)rowIndexes {
    (void)tableView; (void)session; (void)screenPoint; (void)rowIndexes;
    // 纯 AppKit 表格的拖动期间（1s 轮询可能正好回来），不能让 rows 变短/变序：
    // 数据源行号一旦被刷新改写，acceptDrop 的 from 就会对不上拖动源。
    self.dragSessionActive = YES;
}

- (void)tableView:(NSTableView *)tableView draggingSession:(NSDraggingSession *)session
      endedAtPoint:(NSPoint)screenPoint operation:(NSDragOperation)operation {
    (void)tableView; (void)session; (void)screenPoint; (void)operation;
    self.dragSessionActive = NO;
    // 拖动期间被压下的刷新（外部入队/删除/轮询）在这里补一次；
    // 若 qmove 在途则由它的完成回调补拉，避免两个请求互相覆盖。
    if (self.sortInFlight || self.moveInFlight) return;
    [self reloadData];
}

- (NSDragOperation)tableView:(NSTableView *)tv validateDrop:(id<NSDraggingInfo>)info
                 proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)op {
    // 只接受"插到某行之前"，不接受"覆盖某行"
    if (op != NSTableViewDropAbove) return NSDragOperationNone;
    // 队列改写/删除在途时索引不再可信：拒绝落下（acceptDrop 里还有路径身份复核）。
    if (self.sortInFlight || self.moveInFlight || self.deleteInFlight) return NSDragOperationNone;
    return [info.draggingPasteboard.types containsObject:kQueueDragType] ? NSDragOperationMove : NSDragOperationNone;
}

- (BOOL)tableView:(NSTableView *)tv acceptDrop:(id<NSDraggingInfo>)info
              row:(NSInteger)row dropOperation:(NSTableViewDropOperation)op {
    (void)op;
    // 重排/删除在途时拒绝落下：from/to 是相对“提交那一刻的队列”的索引，
    // 与在途的 qorder/qmove 并发会改错顺序（后端 qmove 不做曲目身份校验）。
    if (self.sortInFlight || self.moveInFlight || self.deleteInFlight) return NO;
    id plist = [info.draggingPasteboard propertyListForType:kQueueDragType];
    if (![plist isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *payload = (NSDictionary *)plist;
    id rowObj = payload[@"row"];
    const NSInteger from = [rowObj respondsToSelector:@selector(integerValue)] ? [rowObj integerValue] : -1;
    if (from < 0 || from >= (NSInteger)self.paths.count) return NO;
    NSString *dragPath = [payload[@"path"] isKindOfClass:[NSString class]] ? (NSString *)payload[@"path"] : nil;
    if (!dragPath.length || ![self.paths[(NSUInteger)from] isEqualToString:dragPath]) {
        // 队列在拖动期间变过（1s 轮询/外部通知）：同一行号已不是原来那首，绝不搬错。
        RLPToast(RLPTr(@"排序失败"));
        [self reloadData];   // 本地拖动会话中会被 dragSessionActive 压住，结束后补拉
        return NO;
    }
    // CUE 分轨身份：同一文件可有多行（不同 cs/ce），只比路径仍会搬错。
    double curCs = -1.0, curCe = -1.0, dragCs = -1.0, dragCe = -1.0;
    if (from < (NSInteger)self.cues.count) {
        NSArray<NSNumber *> *cue = self.cues[(NSUInteger)from];
        if (cue.count >= 2) { curCs = cue[0].doubleValue; curCe = cue[1].doubleValue; }
    }
    if ([payload[@"cs"] respondsToSelector:@selector(doubleValue)]) dragCs = [payload[@"cs"] doubleValue];
    if ([payload[@"ce"] respondsToSelector:@selector(doubleValue)]) dragCe = [payload[@"ce"] doubleValue];
    if (fabs(curCs - dragCs) > 0.0005 || fabs(curCe - dragCe) > 0.0005) {
        RLPToast(RLPTr(@"排序失败"));
        [self reloadData];
        return NO;
    }
    // DropAbove row 表示插到 row 之前；从前面往后拖时要减 1（源行会先被移走）
    NSInteger to = row;
    if (from < to) to -= 1;
    to = MAX(0, MIN(to, (NSInteger)self.paths.count - 1));
    if (from == to) return NO;
    self.moveInFlight = YES;
    // 作废在途的旧队列读取：它们的回包不得在 qmove 完成后覆盖新顺序。
    ++self.seq;
    NSString *url = [NSString stringWithFormat:@"/api/qmove?from=%ld&to=%ld", (long)from, (long)to];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        self_.moveInFlight = NO;
        if (json && [json[@"ok"] boolValue]) {
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPQueueChangedNotification object:self_];
        }
        [self_ reloadData];
    }];
    return YES;
}

#pragma mark - 动作

- (void)onDouble:(id)sender {
    const NSInteger row = self.table.clickedRow;
    if (row < 0 || row >= (NSInteger)self.paths.count) return;
    [self playRow:row];
}

/// 共享右键菜单的动作入口。
- (void)rlp_trackMenuAction:(NSMenuItem *)sender {
    RLPHandleTrackAction(sender, self.view);
}

- (void)onMenuRemove:(id)sender {
    const NSInteger row = self.table.clickedRow;
    NSString *capturedPath = nil;
    if ([sender isKindOfClass:[NSMenuItem class]]) {
        id rep = ((NSMenuItem *)sender).representedObject;
        if ([rep isKindOfClass:[NSString class]]) capturedPath = (NSString *)rep;
    }
    [self deleteRow:row capturedPath:capturedPath successToast:RLPTr(@"已移除")];
}

- (void)playRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.paths.count) return;
    NSString *key = [NSString stringWithFormat:@"%ld:%@", (long)row, self.paths[(NSUInteger)row]];
    const NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    if ([key isEqualToString:self.lastPlayKey] && now - self.lastPlayAt < 0.35) return;
    self.lastPlayKey = key;
    self.lastPlayAt = now;
    // web 队列行点击：playPath(items[i], cues[i][0], cues[i][1]) —— CUE 分轨必须带区间。
    double cs = -1, ce = -1;
    if (row < (NSInteger)self.cues.count) {
        NSArray<NSNumber *> *c = self.cues[(NSUInteger)row];
        if (c.count >= 2) { cs = c[0].doubleValue; ce = c[1].doubleValue; }
    }
    RLPPlayPathCue(self.paths[(NSUInteger)row], cs, ce);
}

/// web #qSort：排序下拉改变的是**队列顺序**（/api/qorder），不改变正在播放的那一首。
- (void)onSortMenuItemPicked:(NSMenuItem *)sender {
    NSString *key = [sender.representedObject isKindOfClass:[NSString class]] ? sender.representedObject : nil;
    if (!key.length) return;
    const NSInteger idx = [self.sortPopup indexOfItem:sender];
    if (idx >= 0) [self.sortPopup selectItemAtIndex:idx];
    [self sortBy:key];
}

- (void)onSortPicked:(NSPopUpButton *)sender {
    NSArray<NSString *> *keys = @[ @"default", @"title", @"artist", @"album",
                                   @"dur", @"year", @"shuffle", @"reverse" ];
    const NSInteger i = sender.indexOfSelectedItem;
    if (i < 0 || i >= (NSInteger)keys.count) return;
    [self sortBy:keys[(NSUInteger)i]];
}

- (void)onAction:(NSButton *)sender {
    NSString *a = sender.identifier;
    if ([a isEqualToString:@"refresh"]) { [self reloadData]; return; }
    if ([a isEqualToString:@"clear"]) { [self confirmClear]; return; }
    if ([a isEqualToString:@"save"]) { [self saveAsPlaylist]; return; }
    if ([a isEqualToString:@"qImportM3u"]) { [self promptImportM3U]; return; }
    if ([a isEqualToString:@"default"]) { [self sortBy:@"default"]; return; }
    // 按标题 / 艺术家排序：本地算出新顺序，再整体提交 /api/qorder
    [self sortBy:a];
}

static NSDictionary *RLPQueueMeta(NSArray<NSDictionary *> *metas, NSInteger i) {
    if (i < 0 || i >= (NSInteger)metas.count) return @{};
    id m = metas[(NSUInteger)i];
    return [m isKindOfClass:[NSDictionary class]] ? m : @{};
}

static double RLPQueueMetaNum(NSDictionary *m, NSString *k) {
    id v = m[k];
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0.0;
}

/// 空 meta 的文本回落 = 路径 basename（web 的 txt(i,k) 若为空同样退到标题/路径语义）。
static NSString *RLPQueueMetaText(NSDictionary *m, NSString *k,
                                 NSArray<NSString *> *paths, NSInteger i) {
    id v = m[k];
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
    if (i >= 0 && i < (NSInteger)paths.count)
        return paths[(NSUInteger)i].lastPathComponent.stringByDeletingPathExtension;
    return @"";
}

/// web #qSort：排序下拉改变的是**队列顺序**（/api/qorder），不改变正在播放的那一首。
/// 8 档逐条对齐 `ui_script.h:12496-12540`；qorder 行必须保留 CUE 区间（queueItemLine）。
- (void)sortBy:(NSString *)key {
    if (!key.length) return;
    // 队列改写一次只允许一个在途：排序/拖动/删除在途时再发 qorder，
    // 后到的请求会把新顺序改回旧顺序（qorder 也是按当时索引/全量顺序提交的）。
    if (self.sortInFlight || self.moveInFlight || self.dragSessionActive || self.deleteInFlight) {
        [self restoreSortSelection:(self.sortKey.length ? self.sortKey : @"default")];
        return;
    }
    // P6：失败回滚基准 = 上一档已生效的排序（web 失败时不改 S.queueSort，重渲染仍是旧档）。
    NSString *previous = self.sortKey.length ? self.sortKey : @"default";
    if (!self.paths.count) {
        RLPToast(RLPTr(@"队列是空的"));
        [self restoreSortSelection:previous];
        return;
    }
    if ([key isEqualToString:@"default"]) {
        self.sortInFlight = YES;
        // 作废在途的旧队列读取：旧快照不得在新顺序落库之后又落表。
        ++self.seq;
        __weak __typeof__(self) weakSelf = self;
        [[RLPCoreClient shared] postJSON:@"/api/qsort?by=default" body:nil completion:^(NSDictionary * _Nullable json) {
            __typeof__(self) self_ = weakSelf;
            if (!self_) return;
            self_.sortInFlight = NO;
            if (json && [json[@"ok"] boolValue]) {
                self_.sortKey = @"default";
                // 排序在途时下拉若被改过（并发选择已被拒绝），成功落档后同步回实际档位。
                [self_ restoreSortSelection:self_.sortKey];
                RLPToast(RLPTr(@"已恢复默认顺序"));   // web ui_script.h:12500
                [[NSNotificationCenter defaultCenter] postNotificationName:RLPQueueChangedNotification object:self_];
                [self_ reloadData];
                return;
            }
            NSString *err = ([json[@"error"] isKindOfClass:[NSString class]] && [json[@"error"] length])
                          ? json[@"error"] : RLPTr(@"没有可恢复的排序");
            RLPToast(err);
            [self_ restoreSortSelection:previous];
            [self_ reloadData];
        }];
        return;
    }
    const NSInteger n = (NSInteger)self.paths.count;
    NSMutableArray<NSNumber *> *idx = [NSMutableArray array];
    for (NSInteger i = 0; i < n; ++i) [idx addObject:@(i)];
    NSArray<NSDictionary *> *metas = self.metas;
    NSArray<NSString *> *paths = self.paths;

    if ([key isEqualToString:@"shuffle"]) {
        // web：Fisher-Yates（Math.random 等价 → arc4random_uniform，避免可预测顺序）。
        for (NSInteger k = n - 1; k > 0; --k) {
            const uint32_t r = arc4random_uniform((uint32_t)(k + 1));
            [idx exchangeObjectAtIndex:(NSUInteger)k withObjectAtIndex:(NSUInteger)r];
        }
    } else if ([key isEqualToString:@"reverse"]) {
        idx = [[[idx reverseObjectEnumerator] allObjects] mutableCopy];
    } else if ([key isEqualToString:@"dur"] || [key isEqualToString:@"year"]) {
        const BOOL year = [key isEqualToString:@"year"];
        [idx sortUsingComparator:^NSComparisonResult(NSNumber *x, NSNumber *y) {
            double a = RLPQueueMetaNum(RLPQueueMeta(metas, x.integerValue), @"d");
            double b = RLPQueueMetaNum(RLPQueueMeta(metas, y.integerValue), @"d");
            if (year) {
                a = RLPQueueMetaNum(RLPQueueMeta(metas, x.integerValue), @"y");
                b = RLPQueueMetaNum(RLPQueueMeta(metas, y.integerValue), @"y");
                // web year 是降序（新到旧）。
                if (a > b) return NSOrderedAscending;
                if (a < b) return NSOrderedDescending;
                return NSOrderedSame;
            }
            if (a < b) return NSOrderedAscending;
            if (a > b) return NSOrderedDescending;
            return NSOrderedSame;
        }];
    } else if ([key isEqualToString:@"title"] || [key isEqualToString:@"artist"] || [key isEqualToString:@"album"]) {
        NSString *mk = [key isEqualToString:@"title"] ? @"t" : ([key isEqualToString:@"artist"] ? @"a" : @"al");
        [idx sortUsingComparator:^NSComparisonResult(NSNumber *x, NSNumber *y) {
            NSString *sa = RLPQueueMetaText(RLPQueueMeta(metas, x.integerValue), mk, paths, x.integerValue);
            NSString *sb = RLPQueueMetaText(RLPQueueMeta(metas, y.integerValue), mk, paths, y.integerValue);
            return [sa localizedStandardCompare:sb];
        }];
    }
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSNumber *num in idx) {
        const NSInteger i = num.integerValue;
        NSString *line = paths[(NSUInteger)i];
        // web queueItemLine：cs>=0 的行追加 "	<cs>	<ce>"，否则只发路径。
        if (i < (NSInteger)self.cues.count) {
            NSArray<NSNumber *> *c = self.cues[(NSUInteger)i];
            if (c.count >= 2 && c[0].doubleValue >= 0) {
                line = [line stringByAppendingFormat:@"\t%.3f\t%.3f", c[0].doubleValue, c[1].doubleValue];
            }
        }
        [lines addObject:line];
    }
    self.sortInFlight = YES;
    // 作废在途的旧队列读取：旧快照不得在新顺序落库之后又落表。
    ++self.seq;
    __weak __typeof__(self) weakSelf = self;
    NSString *body = [NSString stringWithFormat:@"files=%@", RLPEnc([lines componentsJoinedByString:@"\n"])];
    [[RLPCoreClient shared] postJSON:@"/api/qorder" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        self_.sortInFlight = NO;
        if (json && [json[@"ok"] boolValue]) {
            self_.sortKey = key;   // 成功才提交档位
            [self_ restoreSortSelection:key];   // 与 sortKey 同步，避免下拉停在被拒的并发选择
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPQueueChangedNotification object:self_];
            [self_ reloadData];
            return;
        }
        NSString *err = ([json[@"error"] isKindOfClass:[NSString class]] && [json[@"error"] length])
                      ? json[@"error"] : RLPTr(@"排序失败");
        RLPToast(err);                                  // P6：不再静默
        [self_ restoreSortSelection:previous];          // P6：下拉回滚上一档
        [self_ reloadData];
    }];
}

/// P6：把排序下拉恢复到上一档（不触发 action，只改选中项）。
- (void)restoreSortSelection:(NSString *)key {
    if (!self.sortPopup || !key.length) return;
    NSArray<NSString *> *keys = @[ @"default", @"title", @"artist", @"album",
                                   @"dur", @"year", @"shuffle", @"reverse" ];
    const NSInteger idx = (NSInteger)[keys indexOfObject:key];
    [self.sortPopup selectItemAtIndex:(idx == NSNotFound) ? 0 : idx];
}

#pragma mark - v3.3.11 M3U 导入

/// 打开系统文件面板选 .m3u/.m3u8（等价 web 的隐藏 `<input id=qM3uFile type=file>`）。
/// 播放中直接拒绝（web 语义「请先停止播放，再替换队列」），不弹面板。
- (void)promptImportM3U {
    if (self.isPlayingNow) { RLPToast(RLPTr(@"请先停止播放，再替换队列。")); return; }
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseFiles = YES;
    p.canChooseDirectories = NO;
    p.allowsMultipleSelection = NO;
    if (@available(macOS 11.0, *)) {
        p.allowedContentTypes = @[];
    }
    p.allowedFileTypes = @[ @"m3u", @"m3u8" ];
    p.message = RLPTr(@"选择 M3U 歌单");
    __weak __typeof__(self) ws = self;
    [p beginWithCompletionHandler:^(NSModalResponse r) {
        __typeof__(self) s2 = ws;
        if (!s2 || r != NSModalResponseOK) return;
        [s2 importM3UAtPath:p.URL.path playing:NO];
    }];
}

/// 生产接缝（判据直接调，绕过系统面板）：读文件 → `RLPParseM3U`（folder = 文件所在目录）
/// → 16 MiB 闸门 → `require_stopped=1&files=` POST `/api/queue/set` → 刷新。
- (void)importM3UAtPath:(NSString *)path playing:(BOOL)playing {
    if (!path.length) return;
    if (playing) { RLPToast(RLPTr(@"请先停止播放，再替换队列。")); return; }
    if (![path.pathExtension.lowercaseString isEqualToString:@"m3u"] &&
        ![path.pathExtension.lowercaseString isEqualToString:@"m3u8"]) {
        RLPToast(RLPTr(@"歌单包含不支持的路径或格式")); return;
    }
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if ([attrs[NSFileSize] unsignedLongLongValue] > 16ull * 1024ull * 1024ull) {
        RLPToast(RLPTr(@"歌单过大")); return;
    }
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text) text = [NSString stringWithContentsOfFile:path encoding:NSUTF16StringEncoding error:nil];
    if (!text) { RLPToast(RLPTr(@"歌单包含不支持的路径或格式")); return; }
    NSDictionary *parsed = RLPParseM3U(text, path.stringByDeletingLastPathComponent);
    NSArray<NSString *> *items = parsed[@"items"];
    if (![items isKindOfClass:[NSArray class]] || items.count == 0) {
        RLPToast(RLPTr(@"歌单包含不支持的路径或格式")); return;
    }
    NSString *files = [items componentsJoinedByString:@"\n"];
    NSString *body = [NSString stringWithFormat:@"require_stopped=1&files=%@", RLPEnc(files)];
    __weak __typeof__(self) ws = self;
    [[RLPCoreClient shared] postJSON:@"/api/queue/set" body:body completion:^(NSDictionary * _Nullable j) {
        __typeof__(self) s2 = ws;
        if (!s2) return;
        if (![j[@"ok"] boolValue]) {
            RLPToast(RLPTr(@"导入失败"));
            return;
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:RLPQueueChangedNotification object:s2];
        [s2 reloadData];
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
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPQueueChangedNotification object:self_];
        }
        [self_ reloadData];
    }];
}

- (void)saveAsPlaylist {
    if (self.saveInFlight) return;
    // P7 空队列守卫：直接提示，不弹框、不发请求（web saveQueueDialog 的 n==0 分支）。
    if (!self.paths.count) {
        RLPToast(RLPTr(@"队列是空的，先加几首歌再保存"));
        return;
    }
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
    [self savePlaylistNamed:name];
}

/// 保存当前队列为歌单（生产接缝：对话框只负责取名；判据直接调这里，不弹模态框）。
- (void)savePlaylistNamed:(NSString *)name {
    NSString *rawName = [name isKindOfClass:[NSString class]] ? name : @"";
    NSString *trimmed = [rawName stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length) { RLPToast(RLPTr(@"请先填写歌单名称")); return; }
    if (self.saveInFlight) return;
    if (![RLPCoreClient shared].started) {
        RLPToast(RLPTr(@"核心未启动"));
        return;
    }
    self.saveInFlight = YES;
    // sq/save = 存当前队列；sq/add 是新建空歌单（两者不能混）
    NSString *url = [NSString stringWithFormat:@"/api/sq/save?name=%@", RLPEnc(trimmed)];
    const NSUInteger seqAtStart = self.seq;
    __weak __typeof__(self) weakSelf = self;
    // P7 + 队列变化校验：向核心核实实时队列（不拿陈旧 self.paths 放行空队列、误拒已入队队列，也不回退旧计数）。
    [[RLPCoreClient shared] getJSON:@"/api/queue?meta=1" completion:^(NSDictionary * _Nullable qjson) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        const BOOL qOk = [qjson isKindOfClass:[NSDictionary class]] &&
                         (!qjson[@"ok"] || ([qjson[@"ok"] respondsToSelector:@selector(boolValue)] &&
                                            [qjson[@"ok"] boolValue])) &&
                         [qjson[@"items"] isKindOfClass:[NSArray class]];
        if (!qOk) {
            self_.saveInFlight = NO;
            NSString *rawErr = ([qjson isKindOfClass:[NSDictionary class]] &&
                                [qjson[@"error"] isKindOfClass:[NSString class]])
                             ? (NSString *)qjson[@"error"] : nil;
            NSString *trimmedErr = [rawErr stringByTrimmingCharactersInSet:
                                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            RLPToast(trimmedErr.length ? rawErr : RLPTr(@"保存失败"));
            return;
        }
        NSMutableArray<NSString *> *liveItems = [NSMutableArray array];
        for (id x in (NSArray *)qjson[@"items"]) {
            if ([x isKindOfClass:[NSString class]] && [(NSString *)x length]) {
                [liveItems addObject:x];
            }
        }
        if (!liveItems.count) {
            self_.saveInFlight = NO;
            if (!self_.hasLoaded || ![liveItems isEqualToArray:self_.paths]) {
                if (seqAtStart == self_.seq) {
                    ++self_.seq;
                    [self_ applyQueueSnapshot:qjson];
                } else {
                    [self_ reloadData];
                }
            }
            RLPToast(RLPTr(@"队列是空的，先加几首歌再保存"));
            return;
        }
        if (!self_.hasLoaded || ![liveItems isEqualToArray:self_.paths]) {
            if (seqAtStart == self_.seq && [qjson[@"metas"] isKindOfClass:[NSArray class]]) {
                ++self_.seq;
                [self_ applyQueueSnapshot:qjson];
            } else {
                [self_ reloadData];
            }
        }
        [[RLPCoreClient shared] postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
            __typeof__(self) self2 = weakSelf;
            if (!self2) return;
            self2.saveInFlight = NO;
            const BOOL okFlag = [json isKindOfClass:[NSDictionary class]] &&
                                [json[@"ok"] respondsToSelector:@selector(boolValue)] &&
                                [json[@"ok"] boolValue];
            id countVal = [json isKindOfClass:[NSDictionary class]] ? json[@"count"] : nil;
            NSInteger count = 0;
            BOOL hasValidCount = NO;
            if ([countVal isKindOfClass:[NSNumber class]] &&
                CFGetTypeID((__bridge CFTypeRef)countVal) != CFBooleanGetTypeID()) {
                const double d = [countVal doubleValue];
                const long long ll = [countVal longLongValue];
                if (isfinite(d) && d >= 1.0 && floor(d) == d && ll >= 1 && ll <= NSIntegerMax) {
                    count = (NSInteger)ll;
                    hasValidCount = YES;
                }
            }
            if (!okFlag || !hasValidCount) {
                NSString *rawErr = ([json isKindOfClass:[NSDictionary class]] &&
                                    [json[@"error"] isKindOfClass:[NSString class]])
                                 ? (NSString *)json[@"error"] : nil;
                NSString *trimmedErr = [rawErr stringByTrimmingCharactersInSet:
                                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                RLPToast(trimmedErr.length ? rawErr : RLPTr(@"保存失败"));
                [self2 reloadData];
                return;
            }
            if (count != (NSInteger)self2.paths.count) {
                [self2 reloadData];
            }
            // P2：web ui_script.h:3930-3932 —— toast 带歌单名/首数，并通知侧栏重拉（行数 +1）。
            NSString *rawSaved = [json[@"name"] isKindOfClass:[NSString class]] ? (NSString *)json[@"name"] : nil;
            NSString *trimmedSaved = [rawSaved stringByTrimmingCharactersInSet:
                                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString *saved = trimmedSaved.length ? trimmedSaved : trimmed;
            RLPToast([NSString stringWithFormat:@"%@%@（%ld %@）",
                      RLPTr(@"已存为歌单："), saved, (long)count, RLPTr(@"首")]);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPSavedQueuesChangedNotification"
                                                                object:nil];
        }];
    }];
}

#pragma mark - 数据

- (void)activate {
    // 拖动会话不可能跨页存活；清掉残留的拖动状态，避免 reloadData 被永久压住。
    // 排序/拖动请求的在途标志交给各自的完成回调清（与 deleteInFlight 同口径）。
    self.dragSessionActive = NO;
    [self reloadData];
}

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

- (void)applyQueueSnapshot:(NSDictionary *)json {
    // 与 reloadData 同一道闸：在途重排/拖动期间，旧快照（包括 savePlaylistNamed
    // 直接调进来的实时校验快照）不得落到表格。
    if (self.sortInFlight || self.moveInFlight || self.dragSessionActive) return;
    NSArray *items = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[];
    NSMutableArray<NSString *> *ps = [NSMutableArray array];
    for (id x in items) if ([x isKindOfClass:[NSString class]] && [(NSString *)x length]) [ps addObject:x];
    self.paths = ps;
    if (self.hoveredRow >= (NSInteger)ps.count) self.hoveredRow = -1;
    NSArray *ms = [json[@"metas"] isKindOfClass:[NSArray class]] ? json[@"metas"] : @[];
    NSMutableArray<NSDictionary *> *mm = [NSMutableArray array];
    for (id x in ms) [mm addObject:[x isKindOfClass:[NSDictionary class]] ? x : @{}];
    self.metas = mm;
    // web S.q.cues：排序与播放都靠它保住 CUE 分轨区间。
    NSArray *cs = [json[@"cues"] isKindOfClass:[NSArray class]] ? json[@"cues"] : @[];
    NSMutableArray<NSArray<NSNumber *> *> *cc = [NSMutableArray array];
    for (id x in cs) {
        if ([x isKindOfClass:[NSArray class]] && [(NSArray *)x count] >= 2) {
            NSArray *pair = (NSArray *)x;
            double a = [pair[0] respondsToSelector:@selector(doubleValue)] ? [pair[0] doubleValue] : -1;
            double b = [pair[1] respondsToSelector:@selector(doubleValue)] ? [pair[1] doubleValue] : -1;
            [cc addObject:@[ @(a), @(b) ]];
        } else {
            [cc addObject:@[ @(-1), @(-1) ]];
        }
    }
    self.cues = cc;
    self.currentIndex = [json[@"index"] respondsToSelector:@selector(integerValue)] ? [json[@"index"] integerValue] : -1;
    self.mode = [json[@"mode"] respondsToSelector:@selector(integerValue)] ? [json[@"mode"] integerValue] : 0;
    self.hasLoaded = YES;
    [self.table reloadData];
    self.empty.hidden = ps.count > 0;
    self.saveButton.enabled = ps.count > 0;   // P7：空队列禁用「保存为歌单」
    NSArray *names = @[ RLPTr(@"顺序"), RLPTr(@"列表循环"), RLPTr(@"单曲循环"), RLPTr(@"随机") ];
    NSString *mn = names[MIN(MAX(self.mode, 0), 3)];
    [self setSubtitle:[NSString stringWithFormat:RLPTr(@"%ld 首 · 当前第 %ld 首 · %@"),
                       (long)ps.count, (long)(self.currentIndex + 1), mn]];
    [self syncTableWidth];
}

- (void)reloadData {
    if (![RLPCoreClient shared].started) {
        [self setSubtitle:RLPTr(@"核心未启动")];
        self.saveButton.enabled = NO;   // P7：没有队列数据 ⟹ 不能保存
        return;
    }
    // 排序/拖动在途：压住这次刷新。旧快照会覆盖刚提交的新顺序，也会让拖动的行号错位；
    // 各操作的完成回调（以及拖动结束）会补拉一次。
    if (self.sortInFlight || self.moveInFlight || self.dragSessionActive) return;
    const NSUInteger seq = ++self.seq;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/queue?meta=1" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.seq) return;
        if (![json isKindOfClass:[NSDictionary class]] ||
            ![json[@"ok"] respondsToSelector:@selector(boolValue)] ||
            ![json[@"ok"] boolValue]) {
            [self_ setSubtitle:RLPTr(@"读取失败")];
            return;
        }
        // 「播放中不许替换队列」的守卫需要真实播放态：与页面同一份 /api/status 轮询口径，
        // 不自己维护第二份播放状态（核心是唯一真相源）。
        [[RLPCoreClient shared] getJSON:@"/api/status" completion:^(NSDictionary * _Nullable st) {
            __typeof__(self) s3 = weakSelf;
            if (!s3 || seq != s3.seq) return;
            s3.isPlayingNow = [st isKindOfClass:[NSDictionary class]] &&
                              [st[@"playing"] respondsToSelector:@selector(boolValue)] &&
                              [st[@"playing"] boolValue] &&
                              !([st[@"paused"] respondsToSelector:@selector(boolValue)] &&
                                [st[@"paused"] boolValue]);
        }];
        [self_ applyQueueSnapshot:json];
    }];
}

- (void)applyTheme {
    [super applyTheme];
    RLPTheme *t = [RLPTheme current];
    self.table.backgroundColor = t.bg;
    self.empty.textColor = t.mut;
    [self.table reloadData];
}

- (void)applyLanguage {
    self.pageTitle = RLPTr(@"播放队列");
    if (!self.isViewLoaded) return;
    self.sortLabel.stringValue = RLPTr(@"排序：");
    NSArray<NSString *> *sortTitles = @[@"默认顺序", @"标题", @"艺术家", @"专辑", @"时长", @"年份", @"随机打乱", @"反转顺序"];
    for (NSUInteger i = 0; i < (NSUInteger)self.sortPopup.numberOfItems && i < sortTitles.count; ++i) {
        [self.sortPopup itemAtIndex:(NSInteger)i].title = RLPTr(sortTitles[i]);
    }
    NSDictionary<NSString *, NSString *> *btnMap = @{
        @"refresh": @"刷新",
        @"save": @"保存为歌单",
        @"qImportM3u": @"导入 M3U 到队列",
        @"clear": @"清空队列",
    };
    for (NSButton *b in self.actionButtons) {
        NSString *zh = btnMap[b.identifier ?: @""];
        if (zh.length) b.title = RLPTr(zh);
    }
    self.empty.stringValue = [RLPTr(@"队列是空的") stringByAppendingFormat:@"\n%@",
        RLPTr(@"把文件拖进窗口，或右键专辑/曲目「加入队列」")];
    if (self.hasLoaded) {
        NSArray *names = @[ RLPTr(@"顺序"), RLPTr(@"列表循环"), RLPTr(@"单曲循环"), RLPTr(@"随机") ];
        NSString *mn = names[MIN(MAX(self.mode, 0), 3)];
        [self setSubtitle:[NSString stringWithFormat:RLPTr(@"%ld 首 · 当前第 %ld 首 · %@"),
                           (long)self.paths.count, (long)(self.currentIndex + 1), mn]];
    } else if (![RLPCoreClient shared].started) {
        [self setSubtitle:RLPTr(@"核心未启动")];
    }
    NSIndexSet *sel = [self.table.selectedRowIndexes copy];
    NSPoint origin = self.tableScroll ? self.tableScroll.contentView.bounds.origin : NSZeroPoint;
    [self.table reloadData];
    if (sel.count) [self.table selectRowIndexes:sel byExtendingSelection:NO];
    if (self.tableScroll) {
        [self.tableScroll.contentView scrollToPoint:origin];
        [self.tableScroll reflectScrolledClipView:self.tableScroll.contentView];
    }
}

@end