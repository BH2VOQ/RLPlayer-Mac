// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPSidebarViewController.mm — 左侧导航（纯 AppKit，Auto Layout）
//
// 注意：窗口是 FullSizeContentView，侧栏会从窗口最顶端开始 ⟹ 品牌区必须让开 macOS
// 红绿灯（x≈12..70、y≈19..32），所以文字从 x=80 起，避免被遮挡。
#import "RLPSidebarViewController.h"
#import <QuartzCore/QuartzCore.h>
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPTheme.h"
#include "version.h"

@interface RLPSidebarViewController () <NSTableViewDataSource, NSTableViewDelegate> {
    NSTableView *_tableView;
    NSInteger _lastSelectedRow;
    NSMutableArray<NSDictionary *> *_menuItems;
    NSInteger _hoverRow;
    // 待落地的选中行：selectRow: 可能在 loadView 之前被调用（主窗口 init 里就是），
    // 那时 _tableView 还是 nil，选中会**静默丢失** ⟹ 侧栏永远没有高亮。
    NSInteger _pendingRow;
    NSInteger _selectedRow;   // 业务选中态（唯一真相，见 selectRow: 注释）
    NSTrackingArea *_tracking;
    // 「我的歌单」动态行（web #sqList = /api/sq/list 的结果，不是硬编码条目）。
    NSArray<NSDictionary *> *_savedQueues;   // @{@"name":…, @"n":…}
    NSUInteger _sqSeq;                       // 异步竞态序号：晚到的旧响应直接丢弃
    NSString *_pendingSavedQueueName;        // 详情页压栈时记住目标歌单（页面可能尚未创建）
}
@end

#pragma mark - 虚线边框盒（web .sqempty 的 border:1px dashed）

/// NSView 的 backing layer 默认是 CALayer。web 的「＋ 新建歌单」是**虚线**框，
/// 用 CAShapeLayer 才能画虚线；所以这里换 backing layer 类，其余不动。
@interface RLPDashedBox : NSView
@property (nonatomic, strong) NSColor *strokeColor;
@property (nonatomic, strong) NSColor *fillColor;
@end

@interface RLPDashedLayer : CAShapeLayer
@end

@implementation RLPDashedLayer
@end

@implementation RLPDashedBox

- (CALayer *)makeBackingLayer {
    RLPDashedLayer *l = [RLPDashedLayer layer];
    l.cornerRadius = 8;
    l.lineWidth = 1;
    l.lineDashPattern = @[@4, @3];
    l.fillColor = NSColor.clearColor.CGColor;
    l.strokeColor = [RLPTheme current].line.CGColor;
    return l;
}

- (void)setStrokeColor:(NSColor *)strokeColor {
    _strokeColor = strokeColor;
    ((CAShapeLayer *)self.layer).strokeColor = strokeColor.CGColor;
    [self setNeedsLayout:YES];
}

- (void)setFillColor:(NSColor *)fillColor {
    _fillColor = fillColor;
    ((CAShapeLayer *)self.layer).fillColor = fillColor.CGColor;
}

- (void)layout {
    [super layout];
    // 虚线路径要跟着 bounds 走；只画边框（fill 由 layer.fillColor 负责）。
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddRect(path, NULL, self.bounds);
    ((CAShapeLayer *)self.layer).path = path;
    CGPathRelease(path);
}

@end

#pragma mark - 侧栏表格（自己管 tracking area）

// tracking area 属于 NSView 而非控制器，放这里才收得到 mouseMoved。
@interface RLPSidebarTable : NSTableView
@property (nonatomic, weak) RLPSidebarViewController *ownerVC;
@end

@implementation RLPSidebarTable {
    NSTrackingArea *_area;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_area) { [self removeTrackingArea:_area]; _area = nil; }
    _area = [[NSTrackingArea alloc] initWithRect:self.bounds
                                        options:(NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                                 NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect)
                                          owner:self userInfo:nil];
    [self addTrackingArea:_area];
}

- (void)mouseMoved:(NSEvent *)event {
    [self.ownerVC sidebarHoverAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    [self.ownerVC sidebarHoverAtPoint:NSMakePoint(-1, -1)];
}
@end

/// 导航项 = **web 版左导航 + 顶部模式单入口**。
///
/// 顶部快捷区（分组标题之前，900/1180 下均在侧栏可视区顶部）：
///   单入口 station（随 _uiMode 显示 聆听室 / 数字音乐台；由顶栏模式开关自动切换）
/// 分组与顺序逐条对齐 web：
///   资料库   : 专辑 / 艺术家 / 曲目 / 文件夹 / 流媒体（web data-v=remote）
///   播放列表 : 播放队列 / 最近播放 / 我的最爱
///   我的歌单 : web #sqList —— 标题「我的歌单」+「＋ 新建」，下方是**动态**歌单行；
///             空态是一整行可点的「＋ 新建歌单」（web .sqempty）
///   音频引擎 : 设置（原底部聆听室已统一上移到顶部，不留重复/不同步入口）
static NSArray<NSDictionary *> *RLPSidebarItems(NSString *uiMode) {
    const BOOL isPro = [uiMode isEqualToString:@"pro"];
    return @[
        @{@"name": isPro ? @"数字音乐台" : @"聆听室",
          @"icon": isPro ? @"slider.horizontal.3" : @"headphones",
          @"key": @"station"},
        @{@"sec": @"资料库"},
        @{@"name": @"专辑",     @"icon": @"square.stack", @"key": @"albums"},
        @{@"name": @"艺术家",   @"icon": @"person.2",     @"key": @"artists"},
        @{@"name": @"曲目",     @"icon": @"music.note",   @"key": @"tracks"},
        @{@"name": @"文件夹",   @"icon": @"folder",       @"key": @"folders"},
        @{@"name": @"流媒体",   @"icon": @"antenna.radiowaves.left.and.right", @"key": @"streaming"},
        @{@"sec": @"播放列表"},
        @{@"name": @"播放队列", @"icon": @"list.bullet",  @"key": @"queue"},
        @{@"name": @"最近播放", @"icon": @"clock",        @"key": @"recent"},
        @{@"name": @"我的最爱", @"icon": @"heart",        @"key": @"favorites"},
        @{@"sec": @"音频引擎"},
        @{@"name": @"设置",     @"icon": @"gearshape",    @"key": @"settings"},
    ];
}

/// 侧栏「我的歌单」区块的锚点分组标题（web .sqhd 的标题行；含右侧「＋ 新建」）。
static NSString * const kSQSavedQueueSection = @"我的歌单";

/// 行是不是分组标题行（不可选中）。
static BOOL RLPRowIsSection(NSArray<NSDictionary *> *items, NSInteger row) {
    if (row < 0 || row >= (NSInteger)items.count) return NO;
    return items[row][@"sec"] != nil;
}

@implementation RLPSidebarViewController

- (void)dealloc {
    // 2026-11-17（并发审计）：init 里注册了通知但从未注销（配对遗漏）。
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
@synthesize lastSavedQueueToast = _lastSavedQueueToast;

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _lastSelectedRow = -1;
        _hoverRow = -1;
        _pendingRow = -1;
        _selectedRow = -1;
        _uiMode = @"listen";
        _savedQueues = @[];
        _menuItems = [NSMutableArray array];
        [self rebuildMenuItems];
        // 歌单在别处被新建/改名/删除后，侧栏必须跟着变（web paintSavedQueues 同语义）。
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onSavedQueuesChangedNote:)
                                                     name:@"RLPSavedQueuesChangedNotification"
                                                   object:nil];
    }
    return self;
}

- (NSInteger)rowCount { return (NSInteger)_menuItems.count; }

- (NSInteger)navRowCount {
    // 「我的歌单」的空态行（web .sqempty）是可点入口但不是 .nav，不计入导航项；
    // 顶部 station 单入口随模式显示，按唯一静态导航 key 计数。
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSDictionary *it in _menuItems) {
        if (it[@"sec"] || [it[@"empty"] boolValue] || it[@"sqindex"]) continue;
        NSString *k = it[@"key"];
        if (k.length) [seen addObject:k];
    }
    return (NSInteger)seen.count;
}

- (BOOL)item:(NSDictionary *)item matchesKey:(NSString *)key {
    return key.length && [item[@"key"] isEqualToString:key];
}

#pragma mark - 「我的歌单」：web #sqList 的原生复刻

/// 把「我的歌单」分组插进静态清单：分组标题 + （歌单行 | 空态行）。
/// web 结构（ui_page.h:1484 + ui_script.h paintSavedQueues）：
///   `<div id=sqList class=sqlist>` → 标题行 .sqhd / 歌单行 .sqrow(name + ✎ + ×) / 空态 .sqempty
- (void)setUiMode:(NSString *)uiMode {
    NSString *next = [uiMode isEqualToString:@"pro"] ? @"pro" : @"listen";
    if ([_uiMode isEqualToString:next]) return;
    NSString *prevKey = [self selectedKey];
    NSString *prevSQ = (_selectedRow >= 0 && _selectedRow < (NSInteger)_menuItems.count && _menuItems[_selectedRow][@"sqindex"])
        ? _menuItems[_selectedRow][@"name"] : nil;
    _uiMode = [next copy];
    [self rebuildMenuItems];
    // 原子保持当前选中项，不触发 onSelect/onSelectKey 副作用。
    if (prevSQ.length) {
        for (NSInteger i = 0; i < (NSInteger)_menuItems.count; ++i) {
            if (_menuItems[i][@"sqindex"] && [_menuItems[i][@"name"] isEqualToString:prevSQ]) {
                _selectedRow = i;
                _lastSelectedRow = i;
                break;
            }
        }
    } else if (prevKey.length) {
        for (NSInteger i = 0; i < (NSInteger)_menuItems.count; ++i) {
            if ([self item:_menuItems[i] matchesKey:prevKey]) {
                _selectedRow = i;
                _lastSelectedRow = i;
                break;
            }
        }
    }
    [_tableView reloadData];
}

- (void)rebuildMenuItems {
    NSArray *base = RLPSidebarItems(_uiMode ?: @"listen");
    NSMutableArray *out = [NSMutableArray array];
    NSString *prevSec = nil;
    BOOL inserted = NO;
    for (NSDictionary *it in base) {
        // 「我的歌单」插在「播放列表」分组的最后一项（我的最爱）之后、音频引擎之前。
        if (!inserted && it[@"sec"] && prevSec && [it[@"sec"] isEqualToString:@"音频引擎"]) {
            [self appendSavedQueueItemsTo:out];
            inserted = YES;
        }
        [out addObject:it];
        if (it[@"sec"]) prevSec = it[@"sec"];
    }
    if (!inserted) [self appendSavedQueueItemsTo:out];   // 兜底：清单改了也不会丢这一组
    _menuItems = out;
}

- (void)appendSavedQueueItemsTo:(NSMutableArray *)out {
    [out addObject:@{@"sec": kSQSavedQueueSection}];
    if (!_savedQueues.count) {
        // 空态：web 用**一整行可点**的占位（不是"去右上角点新建"的提示文字）。
        [out addObject:@{@"empty": @YES, @"name": @"＋ 新建歌单", @"key": @"playlists"}];
        return;
    }
    for (NSUInteger i = 0; i < _savedQueues.count; ++i) {
        NSDictionary *q = _savedQueues[i];
        [out addObject:@{@"sqindex": @(i),
                         @"name": q[@"name"] ?: @"",
                         @"count": q[@"n"] ?: @0,
                         @"key": @"playlists"}];
    }
}

- (void)reloadSavedQueues {
    RLPCoreClient *core = [RLPCoreClient shared];
    if (self.ignoreSavedQueues) {
        _savedQueues = @[];
        [self rebuildMenuItems];
        [_tableView reloadData];
        return;
    }
    if (!core.started) {
        // 没有核心（selftest / 纯视图树）时不发请求，保持 0 个歌单。
        _savedQueues = @[];
        [self rebuildMenuItems];
        [_tableView reloadData];
        return;
    }
    const NSUInteger seq = ++_sqSeq;
    __weak __typeof__(self) weakSelf = self;
    [core getJSON:@"/api/sq/list" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_->_sqSeq) return;
        NSArray *qs = [json[@"queues"] isKindOfClass:[NSArray class]] ? json[@"queues"] : @[];
        NSMutableArray *rows = [NSMutableArray array];
        for (id x in qs) {
            if (![x isKindOfClass:[NSDictionary class]]) continue;
            NSString *name = [x[@"name"] isKindOfClass:[NSString class]] ? x[@"name"] : @"";
            if (!name.length) continue;
            [rows addObject:@{@"name": name,
                              @"n": [x[@"n"] respondsToSelector:@selector(integerValue)] ? x[@"n"] : @0}];
        }
        NSScrollView *scroll = self_->_tableView.enclosingScrollView;
        const BOOL wasAtTop = (!scroll || scroll.contentView.bounds.origin.y <= 0.5);
        self_->_savedQueues = rows;
        [self_ rebuildMenuItems];
        [self_->_tableView reloadData];
        if (wasAtTop && scroll) {
            [scroll.contentView scrollToPoint:NSZeroPoint];
            [scroll reflectScrolledClipView:scroll.contentView];
        }
    }];
}

- (void)onSavedQueuesChangedNote:(NSNotification *)note {
    (void)note;
    [self reloadSavedQueues];
}

- (NSInteger)savedQueueRowCount { return (NSInteger)_savedQueues.count; }
- (NSArray<NSString *> *)savedQueueNames {
    NSMutableArray *names = [NSMutableArray array];
    for (NSDictionary *q in _savedQueues) [names addObject:q[@"name"] ?: @""];
    return names;
}

- (BOOL)validSavedQueueIndex:(NSInteger)index {
    return index >= 0 && index < (NSInteger)_savedQueues.count;
}

- (void)postSavedQueuesChanged {
    // 侧栏自己刷新 + 通知歌单页（页面缓存里的实例也要跟着重拉，否则两处数据会分叉）。
    [self reloadSavedQueues];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPSavedQueuesChangedNotification"
                                                        object:nil];
}

- (void)renameSavedQueueAtIndex:(NSInteger)index to:(NSString *)newName {
    if (![self validSavedQueueIndex:index] || !newName.length) return;
    NSString *from = _savedQueues[index][@"name"] ?: @"";
    if ([newName isEqualToString:from]) return;
    NSString *url = [NSString stringWithFormat:@"/api/sq/rename?from=%@&to=%@",
                     RLPEnc(from), RLPEnc(newName)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            RLPToast(RLPTr(@"已重命名"));
            [self_ postSavedQueuesChanged];
        } else {
            RLPToast([json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"重命名失败"));
        }
    }];
}

- (void)deleteSavedQueueAtIndex:(NSInteger)index {
    if (![self validSavedQueueIndex:index]) return;
    NSString *name = _savedQueues[index][@"name"] ?: @"";
    NSString *url = [NSString stringWithFormat:@"/api/sq/delete?name=%@", RLPEnc(name)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            RLPToast(RLPTr(@"已删除歌单"));
            [self_ postSavedQueuesChanged];
        } else {
            RLPToast([json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"删除失败"));
        }
    }];
}

/// 点歌单行：先按 key 路由到歌单页，再把目标歌单名交给页面（页面可能刚刚才被创建，
/// 所以用通知而不是直接调方法 —— 创建顺序由主窗口决定，侧栏不该依赖页面实例存在）。
- (void)openSavedQueueNamed:(NSString *)name {
    if (!name.length) return;
    _pendingSavedQueueName = name;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPNavigateKeyNotification"
                                                        object:@"playlists"];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPSelectSavedQueueNotification"
                                                        object:name];
}

- (NSInteger)selectedRow { return _selectedRow; }

- (void)loadView {
    RLPTheme *t = [RLPTheme current];
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 232, 700)];
    view.wantsLayer = YES;
    view.layer.backgroundColor = t.bg2.CGColor;
    self.view = view;

    // ---- 顶部只留导航（让开红绿灯），品牌区移到**最底部** ----
    // web 版 .side-brand 就在侧栏最底（Apple Music 左下角个人徽标的位置），
    // 视觉重心与 web 一致；顶部不再放品牌，避免与红绿灯挤在一起。
    // web .side-top 是**红绿灯安全区**（machost 下 height:38px），不是一条分隔线。
    // 之前原生在这里画了 1px 横线，web 没有 ⟹ 侧栏顶部多出一条杂线（实测截图可见）。
    NSView *sideTop = [[NSView alloc] initWithFrame:NSZeroRect];
    sideTop.identifier = @"side.top";
    sideTop.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:sideTop];

    NSView *brand = [[NSView alloc] initWithFrame:NSZeroRect];
    brand.translatesAutoresizingMaskIntoConstraints = NO;
    brand.identifier = @"side.brand";
    [view addSubview:brand];
    NSView *hairB = [[NSView alloc] initWithFrame:NSZeroRect];
    hairB.wantsLayer = YES;
    hairB.layer.backgroundColor = t.line.CGColor;
    hairB.translatesAutoresizingMaskIntoConstraints = NO;
    [brand addSubview:hairB];

    NSImageView *logo = [[NSImageView alloc] initWithFrame:NSZeroRect];
    logo.image = [NSImage imageWithSystemSymbolName:@"waveform" accessibilityDescription:@"RLPlayer"];
    logo.contentTintColor = t.accent;
    logo.wantsLayer = YES;
    logo.layer.cornerRadius = 7;
    logo.translatesAutoresizingMaskIntoConstraints = NO;
    [brand addSubview:logo];

    NSTextField *title = [NSTextField labelWithString:@"RLPlayer"];
    title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    title.textColor = t.text;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [brand addSubview:title];

    NSTextField *ver = [NSTextField labelWithString:[NSString stringWithFormat:@"v%s", RLPLAYER_VERSION]];
    ver.font = [NSFont systemFontOfSize:10];
    ver.textColor = t.mut;
    ver.wantsLayer = YES;
    ver.layer.cornerRadius = 8;
    ver.layer.backgroundColor = t.hov.CGColor;
    ver.translatesAutoresizingMaskIntoConstraints = NO;
    [brand addSubview:ver];

    NSTextField *sub = [NSTextField labelWithString:@"HI-FI AUDIO ENGINE"];
    sub.font = [NSFont systemFontOfSize:9.5 weight:NSFontWeightMedium];
    sub.textColor = t.mut;
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    [brand addSubview:sub];

    // ---- 导航表 ----
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.automaticallyAdjustsContentInsets = NO;
    [view addSubview:scroll];

    RLPSidebarTable *tv = [[RLPSidebarTable alloc] initWithFrame:NSZeroRect];
    tv.ownerVC = self;
    _tableView = tv;
    if (@available(macOS 11.0, *)) _tableView.style = NSTableViewStylePlain;
    _tableView.backgroundColor = [NSColor clearColor];
    _tableView.headerView = nil;
    _tableView.rowHeight = 34;
    _tableView.intercellSpacing = NSMakeSize(0, 2);
    _tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.focusRingType = NSFocusRingTypeNone;
    _tableView.target = self;
    _tableView.action = @selector(onRowClicked:);
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"SidebarCol"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_tableView addTableColumn:col];
    scroll.documentView = _tableView;

    [NSLayoutConstraint activateConstraints:@[
        // 顶部安全区 38pt（web html.machost .side-top height:38px）+ 4pt 下外边距
        [sideTop.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [sideTop.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [sideTop.topAnchor constraintEqualToAnchor:view.topAnchor],
        [sideTop.heightAnchor constraintEqualToConstant:38],

        [scroll.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:sideTop.bottomAnchor constant:4],
        [scroll.bottomAnchor constraintEqualToAnchor:brand.topAnchor],

        // 品牌区贴底（web .side-brand）
        [brand.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [brand.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [brand.bottomAnchor constraintEqualToAnchor:view.bottomAnchor],
        [brand.heightAnchor constraintEqualToConstant:56],
        [hairB.leadingAnchor constraintEqualToAnchor:brand.leadingAnchor],
        [hairB.trailingAnchor constraintEqualToAnchor:brand.trailingAnchor],
        [hairB.topAnchor constraintEqualToAnchor:brand.topAnchor],
        [hairB.heightAnchor constraintEqualToConstant:1],
        [logo.leadingAnchor constraintEqualToAnchor:brand.leadingAnchor constant:14],
        [logo.centerYAnchor constraintEqualToAnchor:brand.centerYAnchor constant:2],
        [logo.widthAnchor constraintEqualToConstant:28],
        [logo.heightAnchor constraintEqualToConstant:28],
        [title.leadingAnchor constraintEqualToAnchor:logo.trailingAnchor constant:9],
        [title.topAnchor constraintEqualToAnchor:brand.topAnchor constant:12],
        [ver.leadingAnchor constraintEqualToAnchor:title.trailingAnchor constant:6],
        [ver.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [sub.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [sub.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:1],
    ]];

    [_tableView reloadData];
    if (_pendingRow >= 0 && _pendingRow < (NSInteger)_menuItems.count && !RLPRowIsSection(_menuItems, _pendingRow)) {
        const NSInteger want = _pendingRow;
        _pendingRow = -1;
        _selectedRow = want;
        _lastSelectedRow = want;
        [_tableView reloadData];
    }
    [scroll.contentView scrollToPoint:NSZeroPoint];
    [scroll reflectScrolledClipView:scroll.contentView];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)_menuItems.count; }

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    // 「我的歌单」标题行 web .sqhd 是 14px 上边距，比普通 .sec 略高，但仍用同一行高。
    return RLPRowIsSection(_menuItems, row) ? 26 : 34;
}

/// 分组标题行（web .sec；「我的歌单」这一组额外带右侧「＋ 新建」= web .sqnew-btn）。
- (NSView *)sectionCellForTableView:(NSTableView *)tableView item:(NSDictionary *)item {
    NSTextField *sec = [NSTextField labelWithString:RLPTr(item[@"sec"])];
    sec.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    sec.textColor = [RLPTheme current].mut;   // web .sec color:var(--mut)
    sec.translatesAutoresizingMaskIntoConstraints = NO;

    NSTableCellView *wrap = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 232, 26)];
    wrap.identifier = @"SecWrap";
    [wrap addSubview:sec];
    NSMutableArray *cs = [NSMutableArray arrayWithObjects:
        [sec.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:20],
        [sec.centerYAnchor constraintEqualToAnchor:wrap.centerYAnchor constant:3], nil];
    if ([item[@"sec"] isEqualToString:kSQSavedQueueSection]) {
        NSButton *plus = [NSButton buttonWithTitle:RLPTr(@"＋ 新建") target:self
                                            action:@selector(onCreateSavedQueue:)];
        plus.bordered = NO;
        plus.identifier = @"sq.new";
        plus.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
        plus.contentTintColor = [RLPTheme current].mut;   // web .sqnew-btn color:var(--mut)
        plus.translatesAutoresizingMaskIntoConstraints = NO;
        [wrap addSubview:plus];
        [cs addObjectsFromArray:@[
            [plus.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor constant:-12],
            [plus.centerYAnchor constraintEqualToAnchor:sec.centerYAnchor],
        ]];
    }
    [NSLayoutConstraint activateConstraints:cs];
    return wrap;
}

/// 空态行（web .sqempty：虚线边框 + 「＋ 新建歌单」整行可点）。
- (NSView *)emptySavedQueueCellForTableView:(NSTableView *)tableView {
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"SQEmpty" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 232, 34)];
        cell.identifier = @"SQEmpty";
        RLPDashedBox *box = [[RLPDashedBox alloc] initWithFrame:NSZeroRect];
        box.identifier = @"sq.empty";
        box.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:box];
        NSTextField *lab = [NSTextField labelWithString:RLPTr(@"＋ 新建歌单")];
        lab.identifier = @"sq.empty.label";
        lab.font = [NSFont systemFontOfSize:13];
        lab.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:lab];
        [NSLayoutConstraint activateConstraints:@[
            // web .sqempty 的边框盒子与 .nav 同左沿（8），内部文字与导航文字同基线（20）。
            [box.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:8],
            [box.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],
            [box.topAnchor constraintEqualToAnchor:cell.topAnchor constant:1],
            [box.bottomAnchor constraintEqualToAnchor:cell.bottomAnchor constant:-1],
            [lab.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:20],
            [lab.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [lab.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-16],
        ]];
    }
    RLPTheme *t = [RLPTheme current];
    RLPDashedBox *box = nil;
    NSTextField *lab = nil;
    for (NSView *s in cell.subviews) {
        if ([s.identifier isEqualToString:@"sq.empty"]) box = (RLPDashedBox *)s;
        if ([s.identifier isEqualToString:@"sq.empty.label"]) lab = (NSTextField *)s;
    }
    box.strokeColor = t.line;
    box.fillColor = (_hoverRow == [tableView rowForView:cell] && _hoverRow >= 0) ? t.hov : NSColor.clearColor;
    lab.stringValue = RLPTr(@"＋ 新建歌单");
    lab.textColor = t.mut;
    cell.toolTip = RLPTr(@"新建歌单");
    return cell;
}

/// 歌单行（web .sqrow：名字 + ✎ + ×，选中态 .on）。
- (NSView *)savedQueueCellForTableView:(NSTableView *)tableView row:(NSInteger)row item:(NSDictionary *)item {
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"SQRow" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 232, 34)];
        cell.identifier = @"SQRow";
        NSView *pill = [[NSView alloc] initWithFrame:NSZeroRect];
        pill.identifier = @"gain";   // 与普通导航行同名 pill，颜色更新路径一致
        pill.wantsLayer = YES;
        pill.layer.cornerRadius = 8;
        pill.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:pill];
        NSTextField *lab = RLPLabel(@"", [NSFont systemFontOfSize:13], [RLPTheme current].text);
        lab.identifier = @"label";
        lab.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:lab];
        NSButton *ren = [NSButton buttonWithTitle:@"\u270e" target:self action:@selector(onRenameSavedQueue:)];
        ren.bordered = NO;
        ren.identifier = @"sq.ren";
        ren.font = [NSFont systemFontOfSize:12];
        ren.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:ren];
        NSButton *del = [NSButton buttonWithTitle:@"\u00d7" target:self action:@selector(onDeleteSavedQueue:)];
        del.bordered = NO;
        del.identifier = @"sq.del";
        del.font = [NSFont systemFontOfSize:12];
        del.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:del];
        [NSLayoutConstraint activateConstraints:@[
            [pill.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:8],
            [pill.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],
            [pill.topAnchor constraintEqualToAnchor:cell.topAnchor constant:1],
            [pill.bottomAnchor constraintEqualToAnchor:cell.bottomAnchor constant:-1],
            [del.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-12],
            [del.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [del.widthAnchor constraintEqualToConstant:18],
            [del.heightAnchor constraintEqualToConstant:18],
            [ren.trailingAnchor constraintEqualToAnchor:del.leadingAnchor constant:-4],
            [ren.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [ren.widthAnchor constraintEqualToConstant:18],
            [ren.heightAnchor constraintEqualToConstant:18],
            [lab.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:20],
            [lab.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [lab.trailingAnchor constraintLessThanOrEqualToAnchor:ren.leadingAnchor constant:-6],
        ]];
    }
    RLPTheme *t = [RLPTheme current];
    NSView *pill = nil;
    NSTextField *lab = nil;
    NSButton *ren = nil, *del = nil;
    for (NSView *s in cell.subviews) {
        if ([s.identifier isEqualToString:@"gain"]) pill = s;
        if ([s.identifier isEqualToString:@"label"]) lab = (NSTextField *)s;
        if ([s.identifier isEqualToString:@"sq.ren"]) ren = (NSButton *)s;
        if ([s.identifier isEqualToString:@"sq.del"]) del = (NSButton *)s;
    }
    NSString *name = item[@"name"] ?: @"";
    const BOOL selected = (_selectedRow == row);
    const BOOL hovered = (_hoverRow == row);
    lab.stringValue = name;
    lab.toolTip = name;
    lab.font = selected ? [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]
                        : [NSFont systemFontOfSize:13];
    lab.textColor = selected ? t.accentText : t.text;
    pill.layer.backgroundColor = selected ? t.accentWeak.CGColor
                                : (hovered ? t.hov.CGColor : NSColor.clearColor.CGColor);
    ren.tag = del.tag = [item[@"sqindex"] integerValue];
    ren.contentTintColor = t.mut;
    del.contentTintColor = t.mut;
    ren.toolTip = RLPTr(@"重命名");
    del.toolTip = RLPTr(@"删除");
    cell.layer.backgroundColor = NSColor.clearColor.CGColor;
    return cell;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    (void)tableColumn;
    RLPTheme *t = [RLPTheme current];
    NSDictionary *item = _menuItems[row];

    // 分组标题行（web .sec）：11px 灰字、无图标无胶囊。
    if (RLPRowIsSection(_menuItems, row)) return [self sectionCellForTableView:tableView item:item];
    // 「我的歌单」空态整行（web .sqempty）+ 动态歌单行（web .sqrow）。
    if ([item[@"empty"] boolValue]) return [self emptySavedQueueCellForTableView:tableView];
    if (item[@"sqindex"]) return [self savedQueueCellForTableView:tableView row:row item:item];

    const BOOL isStation = [item[@"key"] isEqualToString:@"station"];
    NSString *cellId = isStation ? @"side.station" : @"Cell";

    NSTableCellView *cell = [tableView makeViewWithIdentifier:cellId owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 232, 34)];
        cell.identifier = cellId;
        cell.wantsLayer = YES;

        // 选中/悬停的底是**内缩的圆角胶囊**（web 版 .nav 就是 margin 8 + radius 8），
        // 铺满整行会显得像表格而不是导航。
        NSView *pill = [[NSView alloc] initWithFrame:NSZeroRect];
        pill.identifier = @"pill";
        pill.wantsLayer = YES;
        pill.layer.cornerRadius = 8;
        pill.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:pill];
        [NSLayoutConstraint activateConstraints:@[
            [pill.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:8],
            [pill.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],
            [pill.topAnchor constraintEqualToAnchor:cell.topAnchor constant:1],
            [pill.bottomAnchor constraintEqualToAnchor:cell.bottomAnchor constant:-1],
        ]];

        NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
        iconView.identifier = @"icon";
        iconView.imageScaling = NSImageScaleProportionallyDown;
        iconView.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:iconView];

        NSTextField *label = [NSTextField labelWithString:@""];
        label.identifier = @"label";
        label.font = [NSFont systemFontOfSize:13];
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        label.maximumNumberOfLines = 1;
        label.usesSingleLineMode = YES;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:label];

        const CGFloat rightPad = isStation ? -10.0 : -12.0;
        [NSLayoutConstraint activateConstraints:@[
            [iconView.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:20],
            [iconView.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [iconView.widthAnchor constraintEqualToConstant:16],
            [iconView.heightAnchor constraintEqualToConstant:16],
            [label.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:10],
            [label.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:rightPad],
            [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }

    NSImageView *iconView = nil;
    NSTextField *label = nil;
    for (NSView *sub in cell.subviews) {
        if ([sub.identifier isEqualToString:@"icon"]) iconView = (NSImageView *)sub;
        if ([sub.identifier isEqualToString:@"label"]) label = (NSTextField *)sub;
    }

    const BOOL selected = (_selectedRow == row);
    const BOOL hovered = (_hoverRow == row);
    iconView.image = [NSImage imageWithSystemSymbolName:item[@"icon"] accessibilityDescription:item[@"name"]];
    iconView.contentTintColor = selected ? t.accent : t.mut;
    label.stringValue = RLPTr(item[@"name"]);
    label.font = selected ? [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]
                          : [NSFont systemFontOfSize:13];
    label.textColor = selected ? t.accentText : t.text;
    cell.toolTip = isStation
        ? ([_uiMode isEqualToString:@"pro"] ? RLPTr(@"专业工作台") : RLPTr(@"聆听室"))
        : nil;

    NSView *pill = nil;
    for (NSView *sub in cell.subviews)
        if ([sub.identifier isEqualToString:@"pill"]) pill = sub;
    pill.layer.backgroundColor = selected ? t.accentWeak.CGColor
                                : (hovered ? t.hov.CGColor : NSColor.clearColor.CGColor);
    cell.layer.backgroundColor = NSColor.clearColor.CGColor;
    return cell;
}

// 鼠标点击：用 action 回调（不依赖 selectionDidChange，理由同 selectRow:）。
- (void)onRowClicked:(id)sender {
    (void)sender;
    const NSInteger row = _tableView.clickedRow;
    if (row < 0 || row >= (NSInteger)_menuItems.count) return;
    if (RLPRowIsSection(_menuItems, row)) return;
    NSDictionary *item = _menuItems[row];
    // web .sqempty：整行点击 ⟹ 直接弹「新建歌单」对话框（不是去右上角找按钮）。
    if ([item[@"empty"] boolValue]) { [self onCreateSavedQueue:nil]; return; }
    // web .sqrow：点击 ⟹ renderSavedQueuePage(q.name)。
    if (item[@"sqindex"]) { [self selectRow:row]; [self openSavedQueueNamed:item[@"name"]]; return; }
    [self selectRow:row];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    (void)notification;
    const NSInteger row = _tableView.selectedRow;
    if (row >= 0 && row != _selectedRow) [self selectRow:row];
}

- (void)scrollToRowIfNeeded:(NSInteger)row {
    NSScrollView *scroll = _tableView.enclosingScrollView;
    if (!scroll || row < 0 || row >= (NSInteger)_menuItems.count) return;
    const CGFloat clipH = scroll.contentView.bounds.size.height;
    if (clipH <= 0.5) return;
    if (row <= 1) {
        if (scroll.contentView.bounds.origin.y > 0.5) {
            [scroll.contentView scrollToPoint:NSZeroPoint];
            [scroll reflectScrolledClipView:scroll.contentView];
        }
        return;
    }
    const NSRect rowRect = [_tableView rectOfRow:row];
    const NSRect vis = scroll.documentVisibleRect;
    if (NSContainsRect(vis, rowRect)) return;
    if (NSMaxY(rowRect) <= clipH) {
        [scroll.contentView scrollToPoint:NSZeroPoint];
        [scroll reflectScrolledClipView:scroll.contentView];
        return;
    }
    [_tableView scrollRowToVisible:row];
}

// 选中态**自己持有**，不依赖 NSTableView.selectedRow。
// 实测：表格不在 key window 里时 selectRowIndexes 会静默失败（调用后 selectedRow 仍是 -1），
// 于是侧栏永远没有高亮。导航选中是业务状态，本来就不该托付给控件的焦点相关行为。
- (void)selectRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_menuItems.count) return;
    if (RLPRowIsSection(_menuItems, row)) return;   // 标题行不可选中
    if (!_tableView) { _pendingRow = row; return; }
    // 注意：即使行号没变也要发 onSelect —— 详情页压栈后 currentContent 已不是
    // 侧栏选中行对应的页，点同一行必须能路由回去（否则顶栏标题会被清成空）。
    _selectedRow = row;
    _lastSelectedRow = row;
    [_tableView reloadData];
    [self scrollToRowIfNeeded:row];
    if (self.onSelect) self.onSelect(row);
    NSString *k = [self keyForRow:row];
    if (k.length && self.onSelectKey) self.onSelectKey(k);
    // 选中某份歌单时把目标名广播给歌单页（web 进入 sq 页必然知道 sqName）。
    NSString *sqName = _menuItems[row][@"sqindex"] ? _menuItems[row][@"name"] : nil;
    if (sqName.length) {
        _pendingSavedQueueName = sqName;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPSelectSavedQueueNotification"
                                                            object:sqName];
    }
}

#pragma mark - 符号 key 路由（对外一律用 key，不用裸行号）

- (NSString *)keyForRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_menuItems.count) return nil;
    NSString *k = _menuItems[row][@"key"];
    return [k isKindOfClass:[NSString class]] ? k : nil;
}

- (NSString *)selectedKey { return [self keyForRow:_selectedRow]; }

- (BOOL)selectKey:(NSString *)key {
    if (!key.length) return NO;
    for (NSInteger i = 0; i < (NSInteger)_menuItems.count; ++i) {
        if ([self item:_menuItems[i] matchesKey:key]) { [self selectRow:i]; return YES; }
    }
    return NO;
}

/// 表格把鼠标位置转进来：只在行号变化时刷新受影响的两行，不整表 reload
/// （整表 reload 会让滚动位置与选中态抖动）。
- (void)sidebarHoverAtPoint:(NSPoint)p {
    const NSInteger row = (p.x < 0) ? -1 : [_tableView rowAtPoint:p];
    if (row == _hoverRow) return;
    const NSInteger old = _hoverRow;
    _hoverRow = row;
    NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
    if (old >= 0 && old < (NSInteger)_menuItems.count) [rows addIndex:(NSUInteger)old];
    if (row >= 0 && row < (NSInteger)_menuItems.count) [rows addIndex:(NSUInteger)row];
    if (rows.count) {
        [_tableView reloadDataForRowIndexes:rows columnIndexes:[NSIndexSet indexSetWithIndex:0]];
    }
}

#pragma mark - 「我的歌单」动作（web newSavedQueueDialog / renameQueueDialog / deleteSavedQueue）

/// 「＋ 新建」（分组标题右侧与空态整行共用；web .sqnew-btn / .sqempty 同一个 newSavedQueueDialog）。
- (void)onCreateSavedQueue:(id)sender {
    (void)sender;
    // web newSavedQueueDialog 的原生同构：标题「新建歌单」/ 主按钮「创建」/ 占位符 / 提示小字。
    NSString *name = RLPAskText(@"新建歌单", @"创建", @"",
                                @"例如 睡眠专区",
                                @"创建一份空歌单；可通过右键歌曲或单曲页「添加到歌单」加歌");
    if (!name) return;
    [self createSavedQueueNamed:name];
}

- (void)createSavedQueueNamed:(NSString *)name {
    if (!name.length) return;
    NSString *url = [NSString stringWithFormat:@"/api/sq/add?name=%@", RLPEnc(name)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            RLPToast([json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"创建失败"));
            return;
        }
        // web：toast('已新建歌单：' + j.name) —— 必须带歌单名（旧实现只写「已新建歌单」）。
        NSString *created = [json[@"name"] isKindOfClass:[NSString class]] ? json[@"name"] : name;
        // 记下"最后一次新建歌单的提示文案"：轻提示（toast）只活 ~1.8s，
        // 自动化审计在忙的时候会整段错过那个窗口 ⟹ 偶发假红（ctest 里真踩到过）。
        // 文案本身是产品行为的一部分，记在这里既让判据稳定，也让用户可见的那句话可被核对。
        _lastSavedQueueToast = [NSString stringWithFormat:@"%@%@", RLPTr(@"已新建歌单："), created];
        RLPToast(_lastSavedQueueToast);
        [self_ postSavedQueuesChanged];
        [self_ openSavedQueueNamed:created];   // web renderSavedQueuePage(j.name)
    }];
}

/// 歌单行 ✎（web .sqb.ren → renameQueueDialog）。
- (void)onRenameSavedQueue:(id)sender {
    const NSInteger idx = [(NSButton *)sender tag];
    if (![self validSavedQueueIndex:idx]) return;
    NSString *from = _savedQueues[(NSUInteger)idx][@"name"] ?: @"";
    NSString *to = RLPAskText(@"重命名歌单", @"改名", from, nil,
                              @"改名后立刻写入 rlplayer-savedqueues.conf（重启后是新名字）");
    if (!to) return;
    [self renameSavedQueueAtIndex:idx to:to];
}

/// 歌单行 ×（web .sqb.del → deleteSavedQueue，先确认）。
- (void)onDeleteSavedQueue:(id)sender {
    const NSInteger idx = [(NSButton *)sender tag];
    if (![self validSavedQueueIndex:idx]) return;
    NSString *name = _savedQueues[(NSUInteger)idx][@"name"] ?: @"";
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = [NSString stringWithFormat:@"%@%@」？", RLPTr(@"删除歌单「"), name];
    a.informativeText = RLPTr(@"只删歌单记录，不删磁盘上的音乐文件。");
    [a addButtonWithTitle:RLPTr(@"删除")];
    [a addButtonWithTitle:RLPTr(@"取消")];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    [self deleteSavedQueueAtIndex:idx];
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.view.layer.backgroundColor = t.bg2.CGColor;
    [_tableView reloadData];
    [self.view setNeedsDisplay:YES];
}

- (void)applyLanguage {
    NSScrollView *scroll = _tableView.enclosingScrollView;
    NSPoint savedOrigin = scroll ? scroll.contentView.bounds.origin : NSZeroPoint;
    [_tableView reloadData];
    if (scroll) {
        [scroll.contentView scrollToPoint:savedOrigin];
        [scroll reflectScrolledClipView:scroll.contentView];
    }
    [self.view setNeedsDisplay:YES];
}

@end