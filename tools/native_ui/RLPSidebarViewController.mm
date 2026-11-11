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

/// 导航项 = 模式的函数。**这是"两个模式差别在能做什么"的落点之一**：
/// 聆听模式没有「设置」（用户明确要求：需要动设置的人请他去专业模式），
/// 首页是「聆听室」；专业模式首页是「专业工作台」，并保留设置入口。
/// 曲库浏览与播放相关项两个模式都有 —— 合并页签不等于砍功能。
static NSArray<NSDictionary *> *RLPSidebarItemsForMode(RLPAppMode mode) {
    NSMutableArray *items = [NSMutableArray array];
    if (mode == RLPAppModePro) {
        [items addObject:@{@"name": @"专业工作台", @"icon": @"slider.horizontal.3", @"key": @"workbench"}];
    } else {
        [items addObject:@{@"name": @"聆听室", @"icon": @"headphones", @"key": @"room"}];
    }
    [items addObjectsFromArray:@[
        @{@"name": @"专辑",     @"icon": @"square.stack", @"key": @"albums"},
        @{@"name": @"艺术家",   @"icon": @"person.2",     @"key": @"artists"},
        @{@"name": @"曲目",     @"icon": @"music.note",   @"key": @"tracks"},
        @{@"name": @"文件夹",   @"icon": @"folder",       @"key": @"folders"},
        @{@"name": @"流媒体",   @"icon": @"antenna.radiowaves.left.and.right", @"key": @"streaming"},
        @{@"name": @"播放队列", @"icon": @"list.bullet",  @"key": @"queue"},
        @{@"name": @"最近播放", @"icon": @"clock",        @"key": @"recent"},
        @{@"name": @"我的最爱", @"icon": @"heart",        @"key": @"favorites"},
        @{@"name": @"歌单",     @"icon": @"music.note.list", @"key": @"playlists"},
    ]];
    // 设置只在专业模式出现。聆听模式里想改设置 ⟹ 顶栏切到专业模式。
    if (mode == RLPAppModePro)
        [items addObject:@{@"name": @"设置", @"icon": @"gearshape", @"key": @"settings"}];
    return items;
}

@implementation RLPSidebarViewController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _lastSelectedRow = -1;
        _hoverRow = -1;
        _pendingRow = -1;
        _selectedRow = -1;
        _menuItems = RLPSidebarItemsForMode(RLPCurrentAppMode());
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

- (NSInteger)selectedRow { return _selectedRow; }

- (void)loadView {
    RLPTheme *t = [RLPTheme current];
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 232, 700)];
    view.wantsLayer = YES;
    view.layer.backgroundColor = t.bg2.CGColor;
    self.view = view;

    // ---- 品牌区（让开红绿灯） ----
    NSView *brand = [[NSView alloc] initWithFrame:NSZeroRect];
    brand.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:brand];

    NSTextField *title = [NSTextField labelWithString:@"RLPlayer"];
    title.font = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
    title.textColor = t.text;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [brand addSubview:title];

    NSTextField *sub = [NSTextField labelWithString:@"AppKit"];
    sub.font = [NSFont systemFontOfSize:11];
    sub.textColor = t.mut;
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    [brand addSubview:sub];

    NSView *hair1 = [[NSView alloc] initWithFrame:NSZeroRect];
    hair1.wantsLayer = YES;
    hair1.layer.backgroundColor = t.line.CGColor;
    hair1.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:hair1];

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
        [brand.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [brand.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [brand.topAnchor constraintEqualToAnchor:view.topAnchor],
        [brand.heightAnchor constraintEqualToConstant:52],
        [title.leadingAnchor constraintEqualToAnchor:brand.leadingAnchor constant:80],
        [title.centerYAnchor constraintEqualToAnchor:brand.centerYAnchor],
        [sub.leadingAnchor constraintEqualToAnchor:title.trailingAnchor constant:8],
        [sub.trailingAnchor constraintLessThanOrEqualToAnchor:brand.trailingAnchor constant:-12],
        [sub.firstBaselineAnchor constraintEqualToAnchor:title.firstBaselineAnchor],

        [hair1.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [hair1.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [hair1.topAnchor constraintEqualToAnchor:brand.bottomAnchor],
        [hair1.heightAnchor constraintEqualToConstant:1],

        [scroll.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:hair1.bottomAnchor constant:6],
        [scroll.bottomAnchor constraintEqualToAnchor:view.bottomAnchor],
    ]];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)_menuItems.count; }

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
    if (row >= 0) [self selectRow:row];
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
    if (!_tableView) { _pendingRow = row; return; }
    if (_selectedRow == row) return;
    _selectedRow = row;
    _lastSelectedRow = row;
    [_tableView reloadData];
    if (self.onSelect) self.onSelect(row);
    NSString *k = [self keyForRow:row];
    if (k.length && self.onSelectKey) self.onSelectKey(k);
}

#pragma mark - 符号 key 路由（模式切换后行号会错位，所以对外一律用 key）

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

- (void)reloadForModeChange {
    // 记住"当前在哪一页"，模式切换后若那页还在就留在原地（不把用户踢回首页）。
    NSString *keep = [self selectedKey];
    _menuItems = RLPSidebarItemsForMode(RLPCurrentAppMode());
    _selectedRow = -1;
    _lastSelectedRow = -1;
    _hoverRow = -1;
    if (!_tableView) { _pendingRow = 0; return; }
    [_tableView reloadData];
    if (keep.length && [self selectKey:keep]) return;
    [self selectRow:0];   // 那页在新模式里不存在（如聆听模式下的设置）⟹ 回该模式首页
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

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.view.layer.backgroundColor = t.bg2.CGColor;
    [_tableView reloadData];
    [self.view setNeedsDisplay:YES];
}

@end