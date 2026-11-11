// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPSidebarViewController.mm — 左侧导航（纯 AppKit，Auto Layout）
//
// 注意：窗口是 FullSizeContentView，侧栏会从窗口最顶端开始 ⟹ 品牌区必须让开 macOS
// 红绿灯（x≈12..70、y≈19..32），所以文字从 x=80 起，避免被遮挡。
#import "RLPSidebarViewController.h"
#import "RLPTheme.h"

@interface RLPSidebarViewController () <NSTableViewDataSource, NSTableViewDelegate> {
    NSTableView *_tableView;
    NSInteger _lastSelectedRow;
    NSArray<NSDictionary *> *_menuItems;
}
@end

@implementation RLPSidebarViewController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _lastSelectedRow = -1;
        _menuItems = @[
            @{@"name": @"专辑", @"icon": @"square.stack"},
            @{@"name": @"艺术家", @"icon": @"person.2"},
            @{@"name": @"曲目", @"icon": @"music.note"},
            @{@"name": @"文件夹", @"icon": @"folder"},
            @{@"name": @"流媒体", @"icon": @"antenna.radiowaves.left.and.right"},
            @{@"name": @"播放队列", @"icon": @"list.bullet"},
            @{@"name": @"最近播放", @"icon": @"clock"},
            @{@"name": @"我的最爱", @"icon": @"heart"},
            @{@"name": @"快速开始", @"icon": @"sparkles"},
            @{@"name": @"设置", @"icon": @"gearshape"}
        ];
    }
    return self;
}

- (NSInteger)rowCount { return (NSInteger)_menuItems.count; }

- (NSInteger)selectedRow {
    // selftest 期间可能还没建表（loadView 未触发），此时安全返回 -1
    return _tableView ? _tableView.selectedRow : -1;
}

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

    _tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    _tableView.backgroundColor = [NSColor clearColor];
    _tableView.headerView = nil;
    _tableView.rowHeight = 34;
    _tableView.intercellSpacing = NSMakeSize(0, 2);
    _tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.focusRingType = NSFocusRingTypeNone;
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
            [iconView.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:16],
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

    BOOL selected = (_tableView.selectedRow == row);
    iconView.image = [NSImage imageWithSystemSymbolName:item[@"icon"] accessibilityDescription:item[@"name"]];
    iconView.contentTintColor = selected ? t.accent : t.mut;
    label.stringValue = item[@"name"];
    label.textColor = selected ? t.accent : t.text;
    cell.layer.backgroundColor = selected
        ? [t.accent colorWithAlphaComponent:0.16].CGColor
        : NSColor.clearColor.CGColor;
    cell.layer.cornerRadius = 7;
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = _tableView.selectedRow;
    if (row < 0 || row == _lastSelectedRow) return;
    _lastSelectedRow = row;
    [_tableView reloadData];
    if (self.onSelect) self.onSelect(row);
}

- (void)selectRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_menuItems.count) return;
    if (_tableView.selectedRow == row) return;
    [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.view.layer.backgroundColor = t.bg2.CGColor;
    [_tableView reloadData];
    [self.view setNeedsDisplay:YES];
}

@end