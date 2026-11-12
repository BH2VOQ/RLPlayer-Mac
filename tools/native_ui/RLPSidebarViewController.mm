// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPSidebarViewController.mm — 左侧导航（纯 AppKit，Auto Layout）
//
// 注意：窗口是 FullSizeContentView，侧栏会从窗口最顶端开始 ⟹ 品牌区必须让开 macOS
// 红绿灯（x≈12..70、y≈19..32），所以文字从 x=80 起，避免被遮挡。
#import "RLPSidebarViewController.h"
#import "RLPSupport.h"
#import "RLPTheme.h"
#include "version.h"

@interface RLPSidebarViewController () <NSTableViewDataSource, NSTableViewDelegate> {
    NSTableView *_tableView;
    NSInteger _lastSelectedRow;
    NSArray<NSDictionary *> *_menuItems;
    NSInteger _hoverRow;
    // 待落地的选中行：selectRow: 可能在 loadView 之前被调用（主窗口 init 里就是），
    // 那时 _tableView 还是 nil，选中会**静默丢失** ⟹ 侧栏永远没有高亮。
    NSInteger _pendingRow;
    NSInteger _selectedRow;   // 业务选中态（唯一真相，见 selectRow: 注释）
    NSTrackingArea *_tracking;
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

/// 导航项 = **web 版左导航的 1:1 副本**（ui_page.h 的 .side 结构）。
///
/// 分组与顺序逐条对齐 web：
///   资料库   : 专辑 / 艺术家 / 曲目 / 文件夹 / 流媒体（web data-v=remote）
///   播放列表 : 播放队列 / 最近播放 / 我的最爱 / 保存的队列（web #sqList，动态）
///   音频引擎 : 快速开始（web data-v=station）/ 设置
///
/// 为什么不再按"模式"分叉：web 版没有聆听/专业双模式，那是本仓库自己发明的，
/// 会让「web 有的我是否都有」无法机械验证。双模式留到 parity 全绿后作为薄表现层回归，
/// 现在先把地基做平（见 docs/native-ui/PLAN.md）。
static NSArray<NSDictionary *> *RLPSidebarItems(void) {
    NSMutableArray *items = [NSMutableArray array];

    // sec = 分组小标题（web 版 .sec：资料库 / 播放列表 / 音频引擎）。
    [items addObjectsFromArray:@[
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
        // web 在这里渲染 #sqList（保存的队列，动态）。原生用独立页承载同一份数据。
        @{@"name": @"保存的队列", @"icon": @"music.note.list", @"key": @"playlists"},
        @{@"sec": @"音频引擎"},
        // web data-v=station 的标题就是「快速开始」。
        @{@"name": @"快速开始", @"icon": @"play.square.stack", @"key": @"station"},
        @{@"name": @"设置",     @"icon": @"gearshape", @"key": @"settings"},
    ]];
    return items;
}

/// 行是不是分组标题行（不可选中）。
static BOOL RLPRowIsSection(NSArray<NSDictionary *> *items, NSInteger row) {
    if (row < 0 || row >= (NSInteger)items.count) return NO;
    return items[row][@"sec"] != nil;
}

@implementation RLPSidebarViewController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _lastSelectedRow = -1;
        _hoverRow = -1;
        _pendingRow = -1;
        _selectedRow = -1;
        _menuItems = RLPSidebarItems();
    }
    return self;
    // 选中必须在**表格已经有行之后**才设：reloadData 之前 selectRowIndexes 会被丢弃，
    // 侧栏于是永远没有高亮（本轮实测到的真故障：selectedRow 恒为 -1）。
    [_tableView reloadData];
    if (_pendingRow >= 0 && _pendingRow < (NSInteger)_menuItems.count) {
        const NSInteger want = _pendingRow;
        _pendingRow = -1;
        _selectedRow = want;
        _lastSelectedRow = want;
        [_tableView reloadData];
    }

}

- (NSInteger)rowCount { return (NSInteger)_menuItems.count; }

- (NSInteger)navRowCount {
    NSInteger n = 0;
    for (NSDictionary *it in _menuItems) if (!it[@"sec"]) ++n;
    return n;
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
    NSView *hair1 = [[NSView alloc] initWithFrame:NSZeroRect];
    hair1.wantsLayer = YES;
    hair1.layer.backgroundColor = t.line.CGColor;
    hair1.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:hair1];

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
    [view addSubview:scroll];

    RLPSidebarTable *tv = [[RLPSidebarTable alloc] initWithFrame:NSZeroRect];
    tv.ownerVC = self;
    _tableView = tv;
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
        // 顶部 52pt 让开红绿灯；其下是导航
        [hair1.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [hair1.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [hair1.topAnchor constraintEqualToAnchor:view.topAnchor constant:52],
        [hair1.heightAnchor constraintEqualToConstant:1],

        [scroll.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:hair1.bottomAnchor constant:2],
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
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)_menuItems.count; }

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    return RLPRowIsSection(_menuItems, row) ? 26 : 34;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    RLPTheme *t = [RLPTheme current];
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"Cell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 232, 34)];
        cell.identifier = @"Cell";
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
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:label];

        [NSLayoutConstraint activateConstraints:@[
            [iconView.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:20],
            [iconView.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [iconView.widthAnchor constraintEqualToConstant:16],
            [iconView.heightAnchor constraintEqualToConstant:16],
            [label.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:10],
            [label.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-12],
            [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }

    NSDictionary *item = _menuItems[row];
    // 分组标题行：11px 灰字、无图标无胶囊（web .sec 同口径）。
    if (RLPRowIsSection(_menuItems, row)) {
        NSTextField *sec = [tableView makeViewWithIdentifier:@"Sec" owner:self];
        if (!sec) {
            sec = [NSTextField labelWithString:@""];
            sec.identifier = @"Sec";
            sec.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
            sec.translatesAutoresizingMaskIntoConstraints = NO;
        }
        sec.stringValue = RLPTr(item[@"sec"]);
        sec.textColor = [RLPTheme current].mut;
        (void)0;
        // 用一个容器包住以便左缩进
        NSTableCellView *wrap = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 232, 26)];
        [wrap addSubview:sec];
        NSMutableArray *cs = [NSMutableArray arrayWithObjects:
            [sec.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:20],
            [sec.centerYAnchor constraintEqualToAnchor:wrap.centerYAnchor constant:3], nil];
        // 「我的歌单」右侧给「+ 新建」（web .sqnew-btn 同位置同语义）
        if ([item[@"sec"] isEqualToString:@"我的歌单"]) {
            NSButton *plus = [NSButton buttonWithTitle:RLPTr(@"+ 新建") target:self
                                                action:@selector(onNewPlaylist:)];
            plus.bordered = NO;
            plus.identifier = @"side.newplaylist";
            plus.font = [NSFont systemFontOfSize:11];
            plus.contentTintColor = [RLPTheme current].accent;
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
    NSImageView *iconView = nil;
    NSTextField *label = nil;
    for (NSView *sub in cell.subviews) {
        if ([sub.identifier isEqualToString:@"icon"]) iconView = (NSImageView *)sub;
        if ([sub.identifier isEqualToString:@"label"]) label = (NSTextField *)sub;
    }

    const BOOL selected = (_selectedRow == row);
    const BOOL hovered = (self.hoverRow == row);
    iconView.image = [NSImage imageWithSystemSymbolName:item[@"icon"] accessibilityDescription:item[@"name"]];
    iconView.contentTintColor = selected ? t.accent : t.mut;
    label.stringValue = RLPTr(item[@"name"]);
    label.font = selected ? [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]
                          : [NSFont systemFontOfSize:13];
    label.textColor = selected ? t.accentText : t.text;

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
    if (row >= 0 && !RLPRowIsSection(_menuItems, row)) [self selectRow:row];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    (void)notification;
    const NSInteger row = _tableView.selectedRow;
    if (row >= 0 && row != _selectedRow) [self selectRow:row];
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
    if (self.onSelect) self.onSelect(row);
    NSString *k = [self keyForRow:row];
    if (k.length && self.onSelectKey) self.onSelectKey(k);
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
        if ([_menuItems[i][@"key"] isEqualToString:key]) { [self selectRow:i]; return YES; }
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

/// 侧栏「+ 新建」：切到歌单页并发一次新建请求（歌单页自己弹命名框）。
- (void)onNewPlaylist:(id)sender {
    (void)sender;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPNavigateKeyNotification" object:@"playlists"];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPNewPlaylistNotification" object:nil];
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.view.layer.backgroundColor = t.bg2.CGColor;
    [_tableView reloadData];
    [self.view setNeedsDisplay:YES];
}

@end