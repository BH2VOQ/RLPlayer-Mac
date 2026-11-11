// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPFoldersViewController.mm — 文件夹浏览（纯 AppKit）
//
// 为什么用后端 /api/files 而不是本地 NSFileManager：曲库根目录、坏根跳过、隐藏文件过滤
// 这些规则已经在后端实现过一遍（且带"根目录坏掉就跳过"的修复历史），UI 再实现一次必然分叉。
#import "RLPFoldersViewController.h"
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

@interface RLPFoldersViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, copy) NSString *dir;
@property (nonatomic, strong) NSArray<NSString *> *dirs;
@property (nonatomic, strong) NSArray<NSString *> *files;
@property (nonatomic, strong) NSTableView *table;
@property (nonatomic, strong) NSTextField *pathLabel;
@property (nonatomic, strong) NSButton *upBtn;
@property (nonatomic) BOOL loaded;
@end

@implementation RLPFoldersViewController

- (instancetype)init {
    self = [super initWithTitle:@"文件夹"];
    if (self) {
        _dirs = @[];
        _files = @[];
    }
    return self;
}

- (void)buildContent {
    RLPTheme *t = [RLPTheme current];
    NSView *host = self.contentView;

    self.upBtn = RLPSymbolButton(@"arrow.up", @"上一级", self, @selector(onUp:));
    self.upBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.upBtn];

    NSButton *refresh = RLPSymbolButton(@"arrow.clockwise", @"刷新", self, @selector(onRefresh:));
    refresh.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:refresh];

    self.pathLabel = RLPLabel(@"", t.mono, t.mut);
    self.pathLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.pathLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.pathLabel];

    self.table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.table.backgroundColor = [NSColor clearColor];
    self.table.headerView = nil;
    self.table.rowHeight = 30;
    self.table.intercellSpacing = NSMakeSize(0, 1);
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.target = self;
    // 与 web 版一致：**单击**即触发（web 的行 onclick 就是单击）。
    // 双击保留兼容；两者指向同一动作，重复触发幂等。
    self.table.action = @selector(onRowDoubleClick:);
    self.table.doubleAction = @selector(onRowDoubleClick:);
    NSTableColumn *icon = [[NSTableColumn alloc] initWithIdentifier:@"icon"];
    icon.width = 26;
    [self.table addTableColumn:icon];
    NSTableColumn *name = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    name.width = 640;
    [self.table addTableColumn:name];

    NSMenu *menu = [[NSMenu alloc] init];
    NSMenuItem *mi = [menu addItemWithTitle:RLPTr(@"播放") action:@selector(ctxPlay:) keyEquivalent:@""];
    mi.target = self;
    self.table.menu = menu;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.documentView = self.table;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:scroll];

    [NSLayoutConstraint activateConstraints:@[
        [self.upBtn.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:24],
        [self.upBtn.topAnchor constraintEqualToAnchor:host.topAnchor constant:6],
        [self.upBtn.widthAnchor constraintEqualToConstant:24],
        [self.upBtn.heightAnchor constraintEqualToConstant:24],
        [refresh.leadingAnchor constraintEqualToAnchor:self.upBtn.trailingAnchor constant:8],
        [refresh.centerYAnchor constraintEqualToAnchor:self.upBtn.centerYAnchor],
        [refresh.widthAnchor constraintEqualToConstant:24],
        [refresh.heightAnchor constraintEqualToConstant:24],
        [self.pathLabel.leadingAnchor constraintEqualToAnchor:refresh.trailingAnchor constant:12],
        [self.pathLabel.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-24],
        [self.pathLabel.centerYAnchor constraintEqualToAnchor:self.upBtn.centerYAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:24],
        [scroll.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-24],
        [scroll.topAnchor constraintEqualToAnchor:self.upBtn.bottomAnchor constant:10],
        [scroll.bottomAnchor constraintEqualToAnchor:host.bottomAnchor constant:-12],
    ]];
}

- (void)activate {
    if (!self.loaded) [self reloadData];
}

- (void)loadDir:(NSString *)dir {
    if (![RLPCoreClient shared].started) {
        [self setSubtitle:@"核心未启动"];
        return;
    }
    NSString *path = dir.length ? [NSString stringWithFormat:@"/api/files?dir=%@", RLPEnc(dir)]
                                : @"/api/files";
    __weak __typeof__(self) self_ = self;
    [[RLPCoreClient shared] getJSON:path completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) strongSelf = self_;
        if (!strongSelf) return;
        strongSelf.loaded = YES;
        if (!json || ![json[@"ok"] boolValue]) {
            [strongSelf setSubtitle:@"读取失败"];
            RLPToast(RLPTr(@"目录读取失败"));
            return;
        }
        strongSelf.dir = json[@"dir"] ?: @"";
        strongSelf.dirs = json[@"dirs"] ?: @[];
        strongSelf.files = json[@"files"] ?: @[];
        strongSelf.pathLabel.stringValue = strongSelf.dir;
        strongSelf.upBtn.enabled = strongSelf.dir.length > 1 && ![strongSelf.dir isEqualToString:@"/"];
        [strongSelf.table reloadData];
        [strongSelf setSubtitle:[NSString stringWithFormat:@"%ld %@ · %ld %@",
            (long)strongSelf.dirs.count, RLPTr(@"个文件夹"),
            (long)strongSelf.files.count, RLPTr(@"首")]];
    }];
}

- (void)reloadData { [self loadDir:self.dir]; }

- (void)onUp:(id)sender {
    if (!self.dir.length) return;
    NSString *parent = [self.dir stringByDeletingLastPathComponent];
    if (!parent.length || [parent isEqualToString:@"/"]) parent = @"/";
    [self loadDir:parent];
}

- (void)onRefresh:(id)sender { [self loadDir:self.dir]; }

#pragma mark - 表格

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)(self.dirs.count + self.files.count);
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    RLPTheme *t = [RLPTheme current];
    BOOL isDir = row < (NSInteger)self.dirs.count;
    NSString *name = isDir ? self.dirs[(NSUInteger)row]
                           : self.files[(NSUInteger)(row - (NSInteger)self.dirs.count)];
    NSString *ident = col.identifier;
    if ([ident isEqualToString:@"icon"]) {
        NSImageView *iv = [tableView makeViewWithIdentifier:ident owner:self];
        if (!iv) {
            iv = [[NSImageView alloc] initWithFrame:NSZeroRect];
            iv.identifier = ident;
            iv.imageScaling = NSImageScaleProportionallyDown;
        }
        iv.image = [NSImage imageWithSystemSymbolName:(isDir ? @"folder" : @"music.note")
                             accessibilityDescription:nil];
        iv.contentTintColor = isDir ? t.accent : t.mut;
        return iv;
    }
    NSTextField *label = [tableView makeViewWithIdentifier:ident owner:self];
    if (!label) {
        label = RLPLabel(@"", t.body, t.text);
        label.identifier = ident;
    }
    label.stringValue = name;
    label.textColor = isDir ? t.text : t.mut;
    return label;
}

- (void)onRowDoubleClick:(id)sender {
    NSInteger row = self.table.clickedRow;
    if (row < 0) return;
    if (row < (NSInteger)self.dirs.count) {
        NSString *child = self.dirs[(NSUInteger)row];
        NSString *next = [self.dir stringByAppendingPathComponent:child];
        [self loadDir:next];
        return;
    }
    NSString *leaf = self.files[(NSUInteger)(row - (NSInteger)self.dirs.count)];
    RLPPlayPath([self.dir stringByAppendingPathComponent:leaf]);
}

- (void)ctxPlay:(id)sender {
    NSInteger row = self.table.clickedRow;
    if (row < (NSInteger)self.dirs.count || row < 0) return;
    NSString *leaf = self.files[(NSUInteger)(row - (NSInteger)self.dirs.count)];
    RLPPlayPath([self.dir stringByAppendingPathComponent:leaf]);
}

- (void)applyTheme {
    [super applyTheme];
    self.pathLabel.textColor = [RLPTheme current].mut;
    [self.table reloadData];
}

@end