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
#import "RLPRemoveDir.h"

@interface RLPFoldersViewController () <NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate>
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
    self = [super initWithTitle:RLPTr(@"文件夹")];
    if (self) {
        _dirs = @[];
        _files = @[];
    }
    return self;
}

- (void)buildContent {
    RLPTheme *t = [RLPTheme current];
    NSView *host = self.contentView;

    self.upBtn = RLPSymbolButton(@"arrow.up", RLPTr(@"上一级"), self, @selector(onUp:));
    self.upBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.upBtn];

    NSButton *refresh = RLPSymbolButton(@"arrow.clockwise", RLPTr(@"刷新"), self, @selector(onRefresh:));
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
    // 目录行的「删除磁盘目录」（对齐 web .fdel）：走统计 → 二次确认 → 真删。
    // 破坏性操作，仅对目录行显示（菜单按被点行动态重建，见 menuForEvent 等价处理）。
    NSMenuItem *del = [menu addItemWithTitle:RLPTr(@"删除磁盘目录…") action:@selector(ctxRemoveDir:) keyEquivalent:@""];
    del.target = self;
    menu.delegate = self;
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
        [self setSubtitle:RLPTr(@"核心未启动")];
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
            [strongSelf setSubtitle:RLPTr(@"读取失败")];
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

#pragma mark - 删除磁盘目录（破坏性；统计 → 二次确认 → 真删）

/// 菜单按被点行动态更新：只有目录行才显示「删除磁盘目录…」与「播放」互斥。
- (void)menuNeedsUpdate:(NSMenu *)menu {
    const NSInteger row = self.table.clickedRow;
    const BOOL isDir = (row >= 0 && row < (NSInteger)self.dirs.count);
    for (NSMenuItem *item in menu.itemArray) {
        if (!item.action) continue;
        // SEL 是 C 指针，不能用 -isEqual:；用 NSStringFromSelector 比较。
        NSString *act = NSStringFromSelector(item.action);
        if ([act isEqualToString:@"ctxRemoveDir:"]) item.hidden = !isDir;
        if ([act isEqualToString:@"ctxPlay:"]) item.hidden = isDir;
    }
}

/// 右键目录行 → 先统计（后端安全校验：库根之下/非库根/非符号链接），拿到数字才弹确认。
- (void)ctxRemoveDir:(id)sender {
    (void)sender;
    const NSInteger row = self.table.clickedRow;
    if (row < 0 || row >= (NSInteger)self.dirs.count) return;   // 文件行绝不删
    NSString *child = self.dirs[(NSUInteger)row];
    NSString *target = [self.dir stringByAppendingPathComponent:child];
    if (!target.length) return;

    RLPToast(RLPTr(@"正在统计要删除的文件…"));
    NSString *body = [NSString stringWithFormat:@"dir=%@", RLPEnc(target)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/lib/rmdirinfo" body:body
                          completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        // 拿不到数字（后端拒绝：库外 / 库根 / 含软链 / 不存在）⟹ 绝不继续，原因如实告诉用户。
        if (!json || ![json[@"ok"] boolValue]) {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"无法统计该目录，已取消");
            RLPToast(err);
            return;
        }
        const NSInteger files = [json[@"files"] respondsToSelector:@selector(integerValue)] ? [json[@"files"] integerValue] : 0;
        const NSInteger dirs  = [json[@"dirs"] respondsToSelector:@selector(integerValue)] ? [json[@"dirs"] integerValue] : 0;
        [self_ confirmRemoveDir:target files:files dirs:dirs];
    }];
}

/// 二次确认。**最左按钮是「取消」**（回车默认落到取消，避免误触删盘），确认按钮在右侧。
- (void)confirmRemoveDir:(NSString *)target files:(NSInteger)files dirs:(NSInteger)dirs {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = RLPRemoveDirAlertTitle();
    a.informativeText = RLPRemoveDirAlertBody(target, files, dirs);
    [a addButtonWithTitle:RLPTr(@"取消")];                       // 最左 = 默认 = 安全
    [a addButtonWithTitle:RLPRemoveDirConfirmButtonTitle(files)];
    // 破坏性操作用 caution 图标，视觉上再拦一道。
    a.alertStyle = NSAlertStyleCritical;
    if ([a runModal] != NSAlertSecondButtonReturn) return;     // 只有明确点「删除 N 个文件」才继续

    NSString *body = [NSString stringWithFormat:@"dir=%@", RLPEnc(target)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/lib/rmdir" body:body
                          completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"删除失败");
            RLPToast(err);
            return;
        }
        const NSInteger n = [json[@"files"] respondsToSelector:@selector(integerValue)] ? [json[@"files"] integerValue] : files;
        const NSInteger removed = [json[@"removedTracks"] respondsToSelector:@selector(integerValue)] ? [json[@"removedTracks"] integerValue] : 0;
        RLPToast(RLPRemoveDirSuccessText(n, removed));
        [self_ loadDir:self_.dir];   // 刷新当前目录（被删子目录消失）
    }];
}

- (void)applyTheme {
    [super applyTheme];
    self.pathLabel.textColor = [RLPTheme current].mut;
    [self.table reloadData];
}

@end