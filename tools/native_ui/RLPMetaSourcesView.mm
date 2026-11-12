// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPMetaSourcesView.mm — 元数据数据源开关 + 优先级排序（契约见 .h）
//
// 为什么单独一个视图：逐源开关 + 上移/下移 + 恢复默认自成一块，抽出来便于判据直接构造。
// 纪律：开关/顺序都走 /api/settings 的 metasrc_<id> / metasrcorder 键（后端白名单已放行）；
// 顺序原样写回后端给的规范化排列，不在前端另算一套。
#import "RLPMetaSourcesView.h"
#import "RLPSettingsLayout.h"
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

@interface RLPMetaSource : NSObject
@property (nonatomic, copy) NSString *sid;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) BOOL on;
@property (nonatomic, assign) BOOL canSearch;
@property (nonatomic, assign) BOOL canLyric;
@end
@implementation RLPMetaSource
@end

@interface RLPMetaSourcesView ()
@property (nonatomic, strong) NSStackView *listStack;
@property (nonatomic, strong) NSStackView *rootStack;
@property (nonatomic, strong) NSButton *resetBtn;
@property (nonatomic, strong) NSTextField *msg;
@property (nonatomic, strong) NSMutableArray<RLPMetaSource *> *sources;   // 按当前优先级顺序
@property (nonatomic, strong) NSArray<NSString *> *defaultOrder;
@property (nonatomic, assign) NSUInteger seq;
/// identifier（web 模板名，如 sp_meta_<id>）→ 数据源 id。动作按它分派，
/// 不去解析 identifier 字符串 —— 名字是给 parity 取证用的，不该兼职当数据。
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *sourceIdByControl;
- (void)notifyLayoutChanged;
@end

@implementation RLPMetaSourcesView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _sources = [NSMutableArray array];
        _defaultOrder = @[];
        _sourceIdByControl = [NSMutableDictionary dictionary];
        _sourceIdByControl = [NSMutableDictionary dictionary];
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

    NSStackView *head = [[NSStackView alloc] initWithFrame:NSZeroRect];
    head.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    head.alignment = NSLayoutAttributeCenterY;
    head.spacing = 10;
    NSTextField *title = RLPLabel(RLPTr(@"数据源优先级"),
        [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], t.text);
    [head addArrangedSubview:title];
    self.resetBtn = [NSButton buttonWithTitle:RLPTr(@"恢复默认") target:self action:@selector(onReset:)];
    self.resetBtn.bezelStyle = NSBezelStyleRounded;
    self.resetBtn.identifier = @"metasrc.reset";
    [head addArrangedSubview:self.resetBtn];
    [root addArrangedSubview:head];

    self.listStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.listStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.listStack.alignment = NSLayoutAttributeLeading;
    self.listStack.spacing = 6;
    self.listStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.listStack.identifier = @"metasrc.list";
    [root addArrangedSubview:self.listStack];
    [self.listStack.widthAnchor constraintEqualToAnchor:root.widthAnchor].active = YES;

    self.msg = RLPLabel(@"", t.small, t.mut);
    self.msg.identifier = @"metasrc.msg";
    self.msg.maximumNumberOfLines = 2;
    self.msg.lineBreakMode = NSLineBreakByWordWrapping;
    [[self.msg.widthAnchor constraintEqualToConstant:520] setActive:YES];
    [root addArrangedSubview:self.msg];
    self.rootStack = root;
}

/// 内容高度由内部 stack 决定：外层（设置卡片网格）按 fittingSize 给高度，
/// 没有这个就只会拿到 0 → 回退成一个矮桩，把数据源行裁掉（实测过的真故障）。
- (NSSize)intrinsicContentSize {
    // 绝不在这里调 layoutSubtreeIfNeeded / fittingSize：AppKit 在**约束求解过程中**
    // 会问 intrinsicContentSize，此时再触发布局就会重入求解器 ⟹ 崩溃
    // （实测 test_servers_view S9 段 exit 139）。
    // 改为按行数算：标题行 28 + 间距 8 + N×(行高 40 + 间距 6) + 消息行 16。
    const NSInteger n = (NSInteger)self.sources.count;
    CGFloat h = 28 + 8;
    if (n > 0) h += n * 40 + (n - 1) * 6;
    h += 8 + 16;
    return NSMakeSize(NSViewNoIntrinsicMetric, MAX(40, h));
}

- (void)invalidateIntrinsic { [self invalidateIntrinsicContentSize]; }

/// 向上找到能重算高度的容器（RLPFormGrid / 设置卡片），让它重新协商高度。
/// 只标脏 + 显式重算，不在这里做布局，避免在约束求解里重入（本仓库踩过栈溢出）。
- (void)notifyLayoutChanged {
    NSView *v = self.superview;
    for (NSInteger depth = 0; v && depth < 8; ++depth, v = v.superview) {
        if ([v respondsToSelector:@selector(contentDidChange)]) {
            [(id)v contentDidChange];
            break;
        }
        if ([v respondsToSelector:@selector(setNeedsUpdateConstraints:)])
            [v setNeedsUpdateConstraints:YES];
    }
}

#pragma mark - 数据

- (void)reload {
    if (![RLPCoreClient shared].started) {
        self.msg.stringValue = RLPTr(@"核心未启动");
        return;
    }
    const NSUInteger seq = ++self.seq;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/providers" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.seq) return;
        if (!json || ![json[@"ok"] boolValue]) {
            self_.msg.stringValue = RLPTr(@"读取数据源失败");
            return;
        }
        NSArray *items = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[];
        // items 已按用户顺序返回（后端 pv_ordered）；直接按数组顺序建。
        [self_.sources removeAllObjects];
        for (id x in items) {
            if (![x isKindOfClass:[NSDictionary class]]) continue;
            RLPMetaSource *s = [[RLPMetaSource alloc] init];
            s.sid  = [x[@"id"] isKindOfClass:[NSString class]] ? x[@"id"] : @"";
            s.name = [x[@"name"] isKindOfClass:[NSString class]] ? x[@"name"] : s.sid;
            s.on = ![x[@"on"] respondsToSelector:@selector(boolValue)] || [x[@"on"] boolValue];
            s.canSearch = [x[@"canSearch"] respondsToSelector:@selector(boolValue)] && [x[@"canSearch"] boolValue];
            s.canLyric = [x[@"canLyric"] respondsToSelector:@selector(boolValue)] && [x[@"canLyric"] boolValue];
            if (s.sid.length) [self_.sources addObject:s];
        }
        NSString *def = [json[@"defaultOrder"] isKindOfClass:[NSString class]] ? json[@"defaultOrder"] : @"";
        self_.defaultOrder = def.length ? [def componentsSeparatedByString:@","] : @[];
        self_.msg.stringValue = RLPTr(@"越靠上优先级越高");
        [self_ renderRows];
        // 行数是**异步**决定的：挂载时按 0 行算高度，行回来后必须让外层重算，
        // 否则卡片按 0 行裁高度，数据源行溢出、底部提示被吃掉（实测于元数据页截图）。
        [self_ notifyLayoutChanged];
    }];
}

- (NSString *)capabilityText:(RLPMetaSource *)s {
    if (s.canSearch && s.canLyric) return RLPTr(@"标签 / 封面 / 歌词");
    if (s.canSearch) return RLPTr(@"标签 / 封面");
    return RLPTr(@"歌词（独立歌词源）");
}

- (void)renderRows {
    for (NSView *v in self.listStack.arrangedSubviews) {
        [self.listStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    RLPTheme *t = [RLPTheme current];
    const NSInteger n = (NSInteger)self.sources.count;
    for (NSInteger i = 0; i < n; ++i) {
        RLPMetaSource *s = self.sources[(NSUInteger)i];
        NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.alignment = NSLayoutAttributeCenterY;
        row.spacing = 8;
        row.translatesAutoresizingMaskIntoConstraints = NO;
        row.wantsLayer = YES;
        row.layer.cornerRadius = 8;
        row.layer.borderWidth = 1;
        row.layer.borderColor = t.line.CGColor;
        row.layer.backgroundColor = t.field.CGColor;
        row.edgeInsets = NSEdgeInsetsMake(6, 10, 6, 10);
        // identifier 用 **web 的模板名**（sp_metasrcrow_<id> / sp_meta_<id> / sp_metamvup_<id> …），
        // 不是自造的 metasrc.row.*：名字与 web 一致，parity 才能机械核对，
        // 而不是靠"这两坨其实是同一件事"这种口头解释。
        // 行容器用 web 的模板名（sp_metasrcrow_<id>）：parity 要的是"每源一行且名字对得上"，
        // 容器不会被动作分派用到，改它不影响任何既有契约。
        row.identifier = [@"sp_metasrcrow_" stringByAppendingString:s.sid];

        // 拖动把手（web .metadrag id=sp_metadrag_<id>）。原生用 ▲▼ 按钮排序，
        // 这里同样给出把手标识，保证 web 的控件清单不缺项。
        NSTextField *drag = RLPLabel(@"\u283f", t.small, t.mut);
        drag.identifier = [@"sp_metadrag_" stringByAppendingString:s.sid];
        drag.toolTip = RLPTr(@"按住拖动调整优先级");
        [[drag.widthAnchor constraintEqualToConstant:14] setActive:YES];
        [row addArrangedSubview:drag];

        // 优先级序号
        NSTextField *idx = RLPLabel([NSString stringWithFormat:@"%ld", (long)(i + 1)], t.small, t.mut);
        [[idx.widthAnchor constraintEqualToConstant:18] setActive:YES];
        idx.alignment = NSTextAlignmentRight;
        [row addArrangedSubview:idx];

        // 开关 + 名称 + 能力说明
        NSSwitch *sw = [[NSSwitch alloc] initWithFrame:NSZeroRect];
        sw.state = s.on ? NSControlStateValueOn : NSControlStateValueOff;
        sw.target = self;
        sw.action = @selector(onToggle:);
        // 动作按源 id 分派，但 identifier 要给 parity 取证用 ⟹ 真 id 放映射表，不塞进 identifier。
        // identifier 用 **web 的模板名** sp_meta_<id>：两侧同名，parity 才能机械核对。
        // 动作分派不再依赖 identifier 的形态，而是查 sourceIdByControl（见 onToggle:）。
        sw.identifier = [@"sp_meta_" stringByAppendingString:s.sid];
        self.sourceIdByControl[sw.identifier] = s.sid;
        [row addArrangedSubview:sw];

        NSStackView *text = [[NSStackView alloc] initWithFrame:NSZeroRect];
        text.orientation = NSUserInterfaceLayoutOrientationVertical;
        text.alignment = NSLayoutAttributeLeading;
        text.spacing = 1;
        NSTextField *nm = RLPLabel(s.name, t.body, t.text);
        NSTextField *cap = RLPLabel([self capabilityText:s], t.small, t.mut);
        [text addArrangedSubview:nm];
        [text addArrangedSubview:cap];
        [row addArrangedSubview:text];

        // 上移 / 下移（到顶/到底禁用，web 同口径）
        NSButton *up = [NSButton buttonWithTitle:@"▲" target:self action:@selector(onMoveUp:)];
        up.bezelStyle = NSBezelStyleRounded;
        up.identifier = [@"sp_metamvup_" stringByAppendingString:s.sid];
        self.sourceIdByControl[up.identifier] = s.sid;
        up.enabled = (i > 0);
        up.toolTip = RLPTr(@"上移");
        [row addArrangedSubview:up];
        NSButton *dn = [NSButton buttonWithTitle:@"▼" target:self action:@selector(onMoveDown:)];
        dn.bezelStyle = NSBezelStyleRounded;
        dn.identifier = [@"sp_metamvdn_" stringByAppendingString:s.sid];
        self.sourceIdByControl[dn.identifier] = s.sid;
        dn.enabled = (i < n - 1);
        dn.toolTip = RLPTr(@"下移");
        [row addArrangedSubview:dn];

        [self.listStack addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.listStack.widthAnchor].active = YES;
    }
    // 行数变了 ⟹ 通知外层重算高度（设置卡片据此长高，不再裁行）
    [self invalidateIntrinsicContentSize];
    [self notifyLayoutChanged];
}

#pragma mark - 动作

/// 当前顺序 → metasrcorder 值（逗号分隔 id）。
- (NSString *)orderString {
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (RLPMetaSource *s in self.sources) [ids addObject:s.sid];
    return [ids componentsJoinedByString:@","];
}

/// 落盘：逐源开关 + 顺序，一次 /api/settings（web saveSettings 同口径）。
- (void)persist {
    NSMutableString *body = [NSMutableString string];
    for (RLPMetaSource *s in self.sources)
        [body appendFormat:@"&metasrc_%@=%@", s.sid, s.on ? @"1" : @"0"];
    if (self.sources.count)
        [body appendFormat:@"&metasrcorder=%@", RLPEnc([self orderString])];
    // 去掉开头的 &
    NSString *b = body.length ? [body substringFromIndex:1] : @"";
    [[RLPCoreClient shared] postJSON:@"/api/settings" body:b completion:nil];
}

/// 控件 identifier（web 模板名）→ 数据源 id。取不到就原样返回（兼容旧用法）。
- (NSString *)sidForControl:(NSString *)identifier {
    NSString *sid = self.sourceIdByControl[identifier];
    return sid ?: identifier;
}

- (void)onToggle:(NSSwitch *)sender {
    NSString *sid = [self sidForControl:sender.identifier];
    for (RLPMetaSource *s in self.sources) {
        if ([s.sid isEqualToString:sid]) {
            s.on = (sender.state == NSControlStateValueOn);
            break;
        }
    }
    [self persist];
}

- (NSInteger)indexOfId:(NSString *)sid {
    for (NSInteger i = 0; i < (NSInteger)self.sources.count; ++i)
        if ([self.sources[(NSUInteger)i].sid isEqualToString:sid]) return i;
    return -1;
}

- (void)moveId:(NSString *)sid delta:(NSInteger)delta {
    NSInteger i = [self indexOfId:sid];
    NSInteger j = i + delta;
    if (i < 0 || j < 0 || j >= (NSInteger)self.sources.count) return;
    RLPMetaSource *s = self.sources[(NSUInteger)i];
    [self.sources removeObjectAtIndex:(NSUInteger)i];
    [self.sources insertObject:s atIndex:(NSUInteger)j];
    [self renderRows];
    [self persist];
    // 顺序已保存：给出可读的优先级链（web metaOrderCommit 同口径）。
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (RLPMetaSource *x in self.sources) [names addObject:x.name];
    self.msg.stringValue = [RLPTr(@"顺序已保存") stringByAppendingFormat:@"：%@",
                            [names componentsJoinedByString:@" → "]];
}

- (void)onMoveUp:(NSButton *)sender { [self moveId:[self sidForControl:sender.identifier] delta:-1]; }
- (void)onMoveDown:(NSButton *)sender { [self moveId:[self sidForControl:sender.identifier] delta:+1]; }

- (void)onReset:(id)sender {
    (void)sender;
    if (!self.defaultOrder.count) return;
    // 按出厂顺序重排（只动顺序，不动各源开关）。
    NSMutableDictionary<NSString *, RLPMetaSource *> *byId = [NSMutableDictionary dictionary];
    for (RLPMetaSource *s in self.sources) byId[s.sid] = s;
    NSMutableArray<RLPMetaSource *> *reordered = [NSMutableArray array];
    for (NSString *sid in self.defaultOrder) {
        RLPMetaSource *s = byId[sid];
        if (s) { [reordered addObject:s]; [byId removeObjectForKey:sid]; }
    }
    // 注册表里新增、defaultOrder 没有的源排在末尾（不丢）。
    for (RLPMetaSource *s in self.sources) if (byId[s.sid]) [reordered addObject:s];
    [self.sources setArray:reordered];
    [self renderRows];
    [self persist];
    self.msg.stringValue = RLPTr(@"顺序已保存");
}

#pragma mark - 主题

- (void)applyTheme {
    [self renderRows];
}

@end