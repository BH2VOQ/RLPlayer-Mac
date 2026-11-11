// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPServersView.mm — 流媒体服务器管理（对齐 web 版 SRC 区块，契约见 .h）
//
// 为什么单独一个视图：设置·流媒体页原来只读（交接单 §2.2 挂账项），
// 增删改/启用/测试的交互与表单校验自成一块，抽出来便于判据直接构造。
// 纪律：所有写入走 /api/src/config 的 action 协议；密码留空 = 不改（后端 keepPass）。
#import "RLPServersView.h"
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

@interface RLPServerRow : NSObject
@property (nonatomic, copy) NSString *sid;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSString *base;
@property (nonatomic, copy) NSString *user;
@property (nonatomic, assign) BOOL active;
@end
@implementation RLPServerRow
@end

@interface RLPServersView ()
@property (nonatomic, strong) NSStackView *listStack;
@property (nonatomic, strong) NSButton *addBtn;
// 表单（默认隐藏；点「添加/编辑」展开）
@property (nonatomic, strong) NSView *formBox;
@property (nonatomic, strong) NSTextField *formTitle;
@property (nonatomic, strong) NSTextField *nameField;
@property (nonatomic, strong) NSPopUpButton *kindPopup;
@property (nonatomic, strong) NSTextField *baseField;
@property (nonatomic, strong) NSTextField *userField;
@property (nonatomic, strong) NSSecureTextField *passField;
@property (nonatomic, strong) NSTextField *formMsg;
@property (nonatomic, copy) NSString *editingId;   // 空 = 新增
@property (nonatomic, strong) NSMutableArray<RLPServerRow *> *servers;
@property (nonatomic, assign) NSUInteger seq;
@end

@implementation RLPServersView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _servers = [NSMutableArray array];
        _editingId = @"";
        [self buildUI];
    }
    return self;
}

- (void)buildUI {
    RLPTheme *t = [RLPTheme current];
    self.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *root = [[NSStackView alloc] initWithFrame:NSZeroRect];
    root.orientation = NSUserInterfaceLayoutOrientationVertical;
    root.alignment = NSLayoutAttributeLeading;
    root.spacing = 8;
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [root.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [root.topAnchor constraintEqualToAnchor:self.topAnchor],
        [root.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];

    self.addBtn = [NSButton buttonWithTitle:RLPTr(@"添加服务器") target:self action:@selector(onAdd:)];
    self.addBtn.bezelStyle = NSBezelStyleRounded;
    self.addBtn.identifier = @"srv.add";
    [root addArrangedSubview:self.addBtn];

    self.listStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.listStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.listStack.alignment = NSLayoutAttributeLeading;
    self.listStack.spacing = 6;
    self.listStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.listStack.identifier = @"srv.list";
    [root addArrangedSubview:self.listStack];
    [self.listStack.widthAnchor constraintEqualToAnchor:root.widthAnchor].active = YES;

    [self buildForm];
    self.formBox.hidden = YES;
    [root addArrangedSubview:self.formBox];
    [self.formBox.widthAnchor constraintEqualToAnchor:root.widthAnchor].active = YES;
    (void)t;
}

- (void)buildForm {
    RLPTheme *t = [RLPTheme current];
    NSStackView *box = [[NSStackView alloc] initWithFrame:NSZeroRect];
    box.orientation = NSUserInterfaceLayoutOrientationVertical;
    box.alignment = NSLayoutAttributeLeading;
    box.spacing = 8;
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.identifier = @"srv.form";
    box.wantsLayer = YES;
    box.layer.cornerRadius = 10;
    box.layer.borderWidth = 1;
    box.layer.borderColor = t.line.CGColor;
    box.edgeInsets = NSEdgeInsetsMake(12, 14, 12, 14);
    self.formBox = box;

    self.formTitle = RLPLabel(RLPTr(@"添加服务器"),
        [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], t.text);
    self.formTitle.identifier = @"srv.form.title";
    [box addArrangedSubview:self.formTitle];

    self.nameField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.nameField.placeholderString = RLPTr(@"名称（可选）");
    self.nameField.identifier = @"srv.form.name";
    [[self.nameField.widthAnchor constraintEqualToConstant:320] setActive:YES];
    [box addArrangedSubview:self.nameField];

    self.kindPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.kindPopup addItemWithTitle:@"Navidrome / Subsonic"];
    [self.kindPopup addItemWithTitle:@"Emby"];
    self.kindPopup.identifier = @"srv.form.kind";
    [box addArrangedSubview:self.kindPopup];

    self.baseField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.baseField.placeholderString = @"https://music.example.com";
    self.baseField.identifier = @"srv.form.base";
    [[self.baseField.widthAnchor constraintEqualToConstant:320] setActive:YES];
    [box addArrangedSubview:self.baseField];

    self.userField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.userField.placeholderString = RLPTr(@"用户名");
    self.userField.identifier = @"srv.form.user";
    [[self.userField.widthAnchor constraintEqualToConstant:320] setActive:YES];
    [box addArrangedSubview:self.userField];

    self.passField = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    self.passField.placeholderString = RLPTr(@"密码");
    self.passField.identifier = @"srv.form.pass";
    [[self.passField.widthAnchor constraintEqualToConstant:320] setActive:YES];
    [box addArrangedSubview:self.passField];

    NSStackView *btns = [[NSStackView alloc] initWithFrame:NSZeroRect];
    btns.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    btns.spacing = 8;
    NSButton *save = [NSButton buttonWithTitle:RLPTr(@"保存") target:self action:@selector(onSave:)];
    save.bezelStyle = NSBezelStyleRounded;
    save.identifier = @"srv.form.save";
    NSButton *test = [NSButton buttonWithTitle:RLPTr(@"测试") target:self action:@selector(onTestForm:)];
    test.bezelStyle = NSBezelStyleRounded;
    test.identifier = @"srv.form.test";
    NSButton *cancel = [NSButton buttonWithTitle:RLPTr(@"取消") target:self action:@selector(onCancel:)];
    cancel.bezelStyle = NSBezelStyleRounded;
    cancel.identifier = @"srv.form.cancel";
    for (NSButton *b in @[save, test, cancel]) [btns addArrangedSubview:b];
    [box addArrangedSubview:btns];

    self.formMsg = RLPLabel(@"", t.small, t.mut);
    self.formMsg.identifier = @"srv.form.msg";
    self.formMsg.maximumNumberOfLines = 2;
    self.formMsg.lineBreakMode = NSLineBreakByWordWrapping;
    [[self.formMsg.widthAnchor constraintEqualToConstant:420] setActive:YES];
    [box addArrangedSubview:self.formMsg];
}

#pragma mark - 列表

- (void)reload {
    if (![RLPCoreClient shared].started) {
        [self showEmpty:RLPTr(@"核心未启动")];
        return;
    }
    const NSUInteger seq = ++self.seq;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/src/config" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.seq) return;
        [self_.servers removeAllObjects];
        NSArray *arr = [json[@"servers"] isKindOfClass:[NSArray class]] ? json[@"servers"] : @[];
        for (id x in arr) {
            if (![x isKindOfClass:[NSDictionary class]]) continue;
            RLPServerRow *r = [[RLPServerRow alloc] init];
            r.sid  = [x[@"id"] isKindOfClass:[NSString class]] ? x[@"id"] : @"";
            r.name = [x[@"name"] isKindOfClass:[NSString class]] ? x[@"name"] : @"";
            r.kind = [x[@"kind"] isKindOfClass:[NSString class]] ? x[@"kind"] : @"subsonic";
            r.base = [x[@"base"] isKindOfClass:[NSString class]] ? x[@"base"] : @"";
            r.user = [x[@"user"] isKindOfClass:[NSString class]] ? x[@"user"] : @"";
            r.active = [x[@"active"] respondsToSelector:@selector(boolValue)] && [x[@"active"] boolValue];
            if (r.sid.length) [self_.servers addObject:r];
        }
        [self_ renderRows];
    }];
}

- (void)showEmpty:(NSString *)text {
    for (NSView *v in self.listStack.arrangedSubviews) {
        [self.listStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    NSTextField *l = RLPLabel(text, [RLPTheme current].small, [RLPTheme current].mut);
    [self.listStack addArrangedSubview:l];
}

- (void)renderRows {
    for (NSView *v in self.listStack.arrangedSubviews) {
        [self.listStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    if (!self.servers.count) {
        [self showEmpty:RLPTr(@"还没有配置流媒体服务器")];
        return;
    }
    RLPTheme *t = [RLPTheme current];
    for (RLPServerRow *r in self.servers) {
        NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.alignment = NSLayoutAttributeCenterY;
        row.spacing = 8;
        row.translatesAutoresizingMaskIntoConstraints = NO;
        row.wantsLayer = YES;
        row.layer.cornerRadius = 8;
        row.layer.backgroundColor = (r.active ? t.accentWeak : t.bg2).CGColor;
        row.edgeInsets = NSEdgeInsetsMake(6, 10, 6, 10);

        NSStackView *main = [[NSStackView alloc] initWithFrame:NSZeroRect];
        main.orientation = NSUserInterfaceLayoutOrientationVertical;
        main.alignment = NSLayoutAttributeLeading;
        main.spacing = 1;
        NSString *kindName = [r.kind isEqualToString:@"emby"] ? @"Emby" : @"Navidrome / Subsonic";
        NSString *title = [NSString stringWithFormat:@"%@  ·  %@%@",
                           r.name.length ? r.name : r.base, kindName,
                           r.active ? [@"  ·  " stringByAppendingString:RLPTr(@"已启用")] : @""];
        NSTextField *nm = RLPLabel(title, t.body, r.active ? t.accentText : t.text);
        nm.identifier = @"srv.row.name";
        NSString *sub = r.user.length ? [NSString stringWithFormat:@"%@ · %@", r.base, r.user] : r.base;
        NSTextField *url = RLPLabel(sub, t.small, t.mut);
        url.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [main addArrangedSubview:nm];
        [main addArrangedSubview:url];
        [row addArrangedSubview:main];

        // 动作按钮：启用（未启用时）/ 测试 / 编辑 / 删除 —— 与 web renderSrcList 同口径。
        if (!r.active) {
            NSButton *on = [NSButton buttonWithTitle:RLPTr(@"启用") target:self action:@selector(onActivate:)];
            on.bezelStyle = NSBezelStyleRounded;
            on.identifier = r.sid;
            [row addArrangedSubview:on];
        }
        NSButton *test = [NSButton buttonWithTitle:RLPTr(@"测试") target:self action:@selector(onTestSaved:)];
        test.bezelStyle = NSBezelStyleRounded;
        test.identifier = r.sid;
        [row addArrangedSubview:test];
        NSButton *edit = [NSButton buttonWithTitle:RLPTr(@"编辑") target:self action:@selector(onEdit:)];
        edit.bezelStyle = NSBezelStyleRounded;
        edit.identifier = r.sid;
        [row addArrangedSubview:edit];
        NSButton *del = [NSButton buttonWithTitle:RLPTr(@"删除") target:self action:@selector(onRemove:)];
        del.bezelStyle = NSBezelStyleRounded;
        del.identifier = r.sid;
        del.contentTintColor = t.danger;
        [row addArrangedSubview:del];

        [self.listStack addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.listStack.widthAnchor].active = YES;
    }
}

- (RLPServerRow *)rowForId:(NSString *)sid {
    for (RLPServerRow *r in self.servers) if ([r.sid isEqualToString:sid]) return r;
    return nil;
}

#pragma mark - 表单

- (void)showFormFor:(RLPServerRow *)r {
    self.editingId = r ? r.sid : @"";
    self.formTitle.stringValue = r ? [RLPTr(@"编辑服务器") stringByAppendingFormat:@" · %@",
                                      r.name.length ? r.name : r.base]
                                   : RLPTr(@"添加服务器");
    self.nameField.stringValue = r ? r.name : @"";
    [self.kindPopup selectItemAtIndex:(r && [r.kind isEqualToString:@"emby"]) ? 1 : 0];
    self.baseField.stringValue = r ? r.base : @"";
    self.userField.stringValue = r ? r.user : @"";
    self.passField.stringValue = @"";   // 密码红线：永不回填
    self.passField.placeholderString = r ? RLPTr(@"留空 = 保持原密码") : RLPTr(@"密码");
    self.formMsg.stringValue = @"";
    self.formBox.hidden = NO;
}

- (void)onAdd:(id)sender { (void)sender; [self showFormFor:nil]; }
- (void)onCancel:(id)sender { (void)sender; self.formBox.hidden = YES; self.editingId = @""; }

- (void)onEdit:(NSButton *)sender {
    RLPServerRow *r = [self rowForId:sender.identifier];
    if (r) [self showFormFor:r];
}

/// 表单字段 → POST body（与 web srcFormBody 同口径；trim 后编码）。
- (NSString *)formBody {
    NSString *kind = (self.kindPopup.indexOfSelectedItem == 1) ? @"emby" : @"subsonic";
    NSString *name = [self.nameField.stringValue stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *base = [self.baseField.stringValue stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *user = [self.userField.stringValue stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [NSString stringWithFormat:@"kind=%@&name=%@&base=%@&user=%@&pass=%@",
            kind, RLPEnc(name), RLPEnc(base), RLPEnc(user), RLPEnc(self.passField.stringValue ?: @"")];
}

/// 前端校验与 web srcSave 完全一致：地址必填且 http(s):// 开头、用户名必填。
/// 返回 nil = 通过；否则返回错误文案。
- (NSString *)validateForm {
    NSString *base = [self.baseField.stringValue stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *user = [self.userField.stringValue stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!base.length) return RLPTr(@"请填写服务器地址");
    if (![base hasPrefix:@"http://"] && ![base hasPrefix:@"https://"])
        return RLPTr(@"地址要以 http:// 或 https:// 开头");
    if (!user.length) return RLPTr(@"请填写用户名");
    return nil;
}

- (void)onSave:(id)sender {
    (void)sender;
    NSString *err = [self validateForm];
    if (err) { self.formMsg.stringValue = err; self.formMsg.textColor = [RLPTheme current].danger; return; }
    const BOOL wasEdit = self.editingId.length > 0;
    NSString *body = [NSString stringWithFormat:@"action=%@%@&%@",
                      wasEdit ? @"update" : @"add",
                      wasEdit ? [@"&id=" stringByAppendingString:RLPEnc(self.editingId)] : @"",
                      [self formBody]];
    self.formMsg.stringValue = RLPTr(@"保存中…");
    self.formMsg.textColor = [RLPTheme current].mut;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/src/config" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            NSString *e = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"保存失败");
            self_.formMsg.stringValue = e;
            self_.formMsg.textColor = [RLPTheme current].danger;
            return;
        }
        self_.formBox.hidden = YES;
        self_.editingId = @"";
        RLPToast(wasEdit ? RLPTr(@"服务器已更新") : RLPTr(@"服务器已添加"));
        [self_ reload];
    }];
}

- (void)onTestForm:(id)sender {
    (void)sender;
    self.formMsg.stringValue = RLPTr(@"测试中…");
    self.formMsg.textColor = [RLPTheme current].mut;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/src/ping" body:[self formBody]
                          completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        const BOOL ok = json && [json[@"ok"] boolValue];
        NSString *e = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"失败");
        self_.formMsg.stringValue = ok ? RLPTr(@"连接成功") : [@"✗ " stringByAppendingString:e];
        self_.formMsg.textColor = ok ? [RLPTheme current].ok : [RLPTheme current].danger;
    }];
}

#pragma mark - 行动作

- (void)onActivate:(NSButton *)sender {
    RLPServerRow *r = [self rowForId:sender.identifier];
    NSString *body = [@"action=active&id=" stringByAppendingString:RLPEnc(sender.identifier)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/src/config" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            NSString *e = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"启用失败");
            RLPToast(e);
            return;
        }
        RLPToast([NSString stringWithFormat:RLPTr(@"已启用「%@」"), r.name.length ? r.name : r.base]);
        [self_ reload];
    }];
}

- (void)onTestSaved:(NSButton *)sender {
    NSString *u = [@"/api/src/ping?id=" stringByAppendingString:RLPEnc(sender.identifier)];
    sender.enabled = NO;
    __weak __typeof__(self) weakSelf = self;
    __weak NSButton *weakBtn = sender;
    [[RLPCoreClient shared] getJSON:u completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        weakBtn.enabled = YES;
        if (!self_) return;
        const BOOL ok = json && [json[@"ok"] boolValue];
        NSString *e = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"未知错误");
        RLPToast(ok ? RLPTr(@"连接成功") : [RLPTr(@"连接失败") stringByAppendingFormat:@"：%@", e]);
    }];
}

- (void)onRemove:(NSButton *)sender {
    RLPServerRow *r = [self rowForId:sender.identifier];
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = [NSString stringWithFormat:RLPTr(@"删除服务器「%@」？"), r.name.length ? r.name : r.base];
    a.informativeText = RLPTr(@"只删配置，不动已下载缓存。");
    [a addButtonWithTitle:RLPTr(@"删除")];
    [a addButtonWithTitle:RLPTr(@"取消")];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    NSString *body = [@"action=remove&id=" stringByAppendingString:RLPEnc(sender.identifier)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/src/config" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            NSString *e = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"删除失败");
            RLPToast(e);
            return;
        }
        if ([self_.editingId isEqualToString:sender.identifier]) {
            self_.formBox.hidden = YES;
            self_.editingId = @"";
        }
        RLPToast(RLPTr(@"已删除"));
        [self_ reload];
    }];
}

#pragma mark - 主题

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.formBox.layer.borderColor = t.line.CGColor;
    self.formTitle.textColor = t.text;
    self.formMsg.textColor = t.mut;
    [self renderRows];
}

@end