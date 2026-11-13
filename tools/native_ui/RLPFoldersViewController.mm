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
@property (nonatomic, strong) NSTextField *pathField;      // web #fPath（可输入后回车跳转）
@property (nonatomic, strong) NSPopUpButton *rootPopup;     // web #fRoot（音乐库根目录跳转）
@property (nonatomic, strong) NSButton *goBtn;              // web #fGo
@property (nonatomic, strong) NSButton *upBtn;
@property (nonatomic) BOOL loaded;
// web 空态：`此目录没有音频文件`（只有目录/文件都为空时出现，dirs 非空不算空）。
@property (nonatomic, strong) NSTextField *emptyLabel;
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

    // web 地址栏：可输入路径 + 回车/「↩」跳转 + 音乐库根目录下拉（#fPath/#fGo/#fRoot）。
    // 旧实现只有一个只读路径文字 —— 用户问「没做刷新曲库」之外，也看不到怎么跳目录。
    self.rootPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.rootPopup.identifier = @"fRoot";
    self.rootPopup.target = self;
    self.rootPopup.action = @selector(onRootPicked:);
    self.rootPopup.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.rootPopup];

    self.pathField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.pathField.identifier = @"fPath";
    self.pathField.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.pathField.placeholderString = RLPTr(@"输入目录后回车，例如 /Users/你的用户名/Music");
    self.pathField.target = self;
    self.pathField.action = @selector(onGoIn:);
    self.pathField.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.pathField];

    self.goBtn = [NSButton buttonWithTitle:@"↩" target:self action:@selector(onGo:)] ;
    self.goBtn.bordered = NO;
    self.goBtn.bezelStyle = NSBezelStyleRegularSquare;
    self.goBtn.identifier = @"fGo";
    self.goBtn.toolTip = RLPTr(@"转到");
    self.goBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.goBtn];

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

    self.emptyLabel = RLPLabel(RLPTr(@"此目录没有音频文件"), t.body, t.mut2);
    self.emptyLabel.identifier = @"folders.empty";
    self.emptyLabel.alignment = NSTextAlignmentCenter;
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.hidden = YES;
    [host addSubview:self.emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.upBtn.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:24],
        [self.upBtn.topAnchor constraintEqualToAnchor:host.topAnchor constant:6],
        [self.upBtn.widthAnchor constraintEqualToConstant:24],
        [self.upBtn.heightAnchor constraintEqualToConstant:24],
        [refresh.leadingAnchor constraintEqualToAnchor:self.upBtn.trailingAnchor constant:8],
        [refresh.centerYAnchor constraintEqualToAnchor:self.upBtn.centerYAnchor],
        [refresh.widthAnchor constraintEqualToConstant:24],
        [refresh.heightAnchor constraintEqualToConstant:24],
        [self.rootPopup.leadingAnchor constraintEqualToAnchor:refresh.trailingAnchor constant:8],
        [self.rootPopup.centerYAnchor constraintEqualToAnchor:self.upBtn.centerYAnchor],
        [self.rootPopup.widthAnchor constraintEqualToConstant:150],
        [self.pathField.leadingAnchor constraintEqualToAnchor:self.rootPopup.trailingAnchor constant:8],
        [self.pathField.centerYAnchor constraintEqualToAnchor:self.upBtn.centerYAnchor],
        [self.goBtn.leadingAnchor constraintEqualToAnchor:self.pathField.trailingAnchor constant:4],
        [self.goBtn.centerYAnchor constraintEqualToAnchor:self.upBtn.centerYAnchor],
        [self.goBtn.widthAnchor constraintEqualToConstant:24],
        [self.goBtn.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-24],
        [scroll.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:24],
        [scroll.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-24],
        [scroll.topAnchor constraintEqualToAnchor:self.upBtn.bottomAnchor constant:10],
        [scroll.bottomAnchor constraintEqualToAnchor:host.bottomAnchor constant:-12],
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:scroll.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:scroll.centerYAnchor],
    ]];
}

- (void)activate {
    if (!self.loaded) [self reloadData];
    [self loadRoots];
}

/// 音乐库根目录下拉（web #fRoot）：来自 /api/lib/stats 的 roots。
- (void)loadRoots {
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/lib/stats" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || ![json isKindOfClass:[NSDictionary class]]) return;
        NSArray *roots = [json[@"roots"] isKindOfClass:[NSArray class]] ? json[@"roots"] : @[];
        [self_.rootPopup removeAllItems];
        [self_.rootPopup addItemWithTitle:RLPTr(@"音乐库…")];
        for (id r in roots) if ([r isKindOfClass:[NSString class]] && [r length])
            [self_.rootPopup addItemWithTitle:((NSString *)r).lastPathComponent];
    }];
}

- (void)onRootPicked:(NSPopUpButton *)sender {
    if (sender.indexOfSelectedItem <= 0) return;
    NSString *title = sender.titleOfSelectedItem;
    if (!title.length) return;
    // 下拉里只显示目录名：真正的路径从 /api/lib/stats 再取一次（同名目录不歧义）
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/lib/stats" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *roots = [json[@"roots"] isKindOfClass:[NSArray class]] ? json[@"roots"] : @[];
        for (id r in roots) {
            if (![r isKindOfClass:[NSString class]]) continue;
            if ([[(NSString *)r lastPathComponent] isEqualToString:title]) { [self_ loadDir:r]; return; }
        }
        [self_ loadDir:title];
    }];
}

- (void)onGo:(id)sender {
    NSString *v = [self.pathField.stringValue stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (v.length) [self loadDir:v];
}

- (void)onGoIn:(NSTextField *)sender { (void)sender; [self onGo:nil]; }

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
        strongSelf.pathField.stringValue = strongSelf.dir;
        strongSelf.upBtn.enabled = strongSelf.dir.length > 1 && ![strongSelf.dir isEqualToString:@"/"];
        [strongSelf.table reloadData];
        strongSelf.emptyLabel.hidden = ((strongSelf.dirs.count + strongSelf.files.count) > 0);
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
    self.pathField.textColor = [RLPTheme current].text;
    [self.table reloadData];
}


/// POST /api/upload?name=<文件名>，body = 文件原始字节。
/// 用途与 web 的拖拽上传一致：**当调用方拿不到真实路径时**，先上传到本机服务再由它入队。
/// 原生拖拽通常能拿到 path（走 /api/add 即可），但在沙盒/网络卷下会拿不到 ——
/// 那时这条路径就是唯一能工作的方式，不能因为"平时用不到"就删掉。
- (void)uploadFileAtURL:(NSURL *)url completion:(void (^)(NSString * _Nullable path))completion {
    if (!url || !url.lastPathComponent.length) { if (completion) completion(nil); return; }
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data.length) { if (completion) completion(nil); return; }
    NSString *path = [NSString stringWithFormat:@"/api/upload?name=%@", RLPEnc(url.lastPathComponent)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postData:path body:data contentType:@"application/octet-stream"
                          completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) weakSelf2 = weakSelf;
        (void)weakSelf2;
        NSString *p = [json[@"path"] isKindOfClass:[NSString class]] ? json[@"path"] : nil;
        if (completion) completion(p);
    }];
}

@end