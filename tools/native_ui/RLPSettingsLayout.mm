// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPSettingsLayout.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

// web .sgbody 的列下限与间距（ui_page.h:1218）
static const CGFloat kFieldMinW = 260.0;   // minmax(260px, 1fr)
static const CGFloat kColGap   = 20.0;     // gap 的行内间距（列间）
static const CGFloat kRowGap   = 14.0;     // gap 的行间
static const CGFloat kBodyPadX = 16.0;     // .sgbody padding:14px 16px
static const CGFloat kBodyPadY = 14.0;

@interface RLPFieldGrid ()
@property (nonatomic, strong) NSMutableArray<NSView *> *items;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *spans;
@property (nonatomic, assign, readwrite) NSInteger columnCount;
@property (nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *live;
/// 重入护栏：relayout 会激活约束 → 触发 layout → 又调 relayout，无护栏就是死循环
/// （实测：--audit 在设置页停住）。同时记录上次宽度，宽度没变就不重排。
@property (nonatomic, assign) BOOL inRelayout;
@property (nonatomic, assign) CGFloat lastWidth;
@property (nonatomic, assign) NSUInteger lastItemCount;
/// 最近一次排出来的内容高度。
@property (nonatomic, assign) CGFloat contentHeight;
@end

@implementation RLPFieldGrid

- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    if (self) {
        _items = [NSMutableArray array];
        _spans = [NSMutableArray array];
        _live = [NSMutableArray array];
        _columnCount = 1;
        self.translatesAutoresizingMaskIntoConstraints = NO;
    }
    return self;
}

- (void)addItem:(NSView *)item span:(BOOL)fullWidth {
    item.translatesAutoresizingMaskIntoConstraints = NO;
    [self.items addObject:item];
    [self.spans addObject:@(fullWidth)];
    [self addSubview:item];
    [self relayout];
}

/// 列数 = floor((可用宽 + 列间距) / (列下限 + 列间距))，至少 1。
/// 这就是 CSS repeat(auto-fill, minmax(260px,1fr)) 的等价算法。
- (NSInteger)columnsForWidth:(CGFloat)w {
    CGFloat avail = w - kBodyPadX * 2;
    if (avail < kFieldMinW) return 1;
    NSInteger n = (NSInteger)floor((avail + kColGap) / (kFieldMinW + kColGap));
    return MAX(1, n);
}

- (void)relayout {
    if (self.inRelayout) return;
    const CGFloat wNow = self.bounds.size.width > 1 ? self.bounds.size.width : 640;
    // 宽度与项数都没变 ⟹ 布局结果不会变，直接返回（避免 layout↔relayout 死循环）
    if (fabs(wNow - self.lastWidth) < 0.5 && self.lastItemCount == self.items.count && self.live.count)
        return;
    self.inRelayout = YES;
    self.lastWidth = wNow;
    self.lastItemCount = self.items.count;
    if (self.live.count) { [NSLayoutConstraint deactivateConstraints:self.live]; [self.live removeAllObjects]; }
    const CGFloat w = wNow;
    const NSInteger cols = [self columnsForWidth:w];
    self.columnCount = cols;
    const CGFloat colW = (w - kBodyPadX * 2 - kColGap * (cols - 1)) / cols;

    // 逐行摆放：整行项独占一行；普通项按列填充。
    CGFloat y = kBodyPadY;
    NSInteger col = 0;
    CGFloat rowH = 0;
    NSMutableArray<NSLayoutConstraint *> *cs = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.items.count; ++i) {
        NSView *v = self.items[i];
        const BOOL full = self.spans[i].boolValue;
        if (full && col > 0) { y += rowH + kRowGap; col = 0; rowH = 0; }
        const CGFloat x = kBodyPadX + col * (colW + kColGap);
        const CGFloat itemW = full ? (w - kBodyPadX * 2) : colW;
        // 用 fittingSize / intrinsicContentSize 量高度，不调 layoutSubtreeIfNeeded：
        // 后者在约束求解过程中会重入（实测栈溢出）。
        CGFloat h = v.fittingSize.height;
        // 自定义整行视图（数据源列表 / 表格 / 子面板）用 intrinsicContentSize 报真实高度；
        // fittingSize 对"四边钉死但无内在高度"的容器会返回 0。
        if (h < 1) {
            const NSSize ic = v.intrinsicContentSize;
            if (ic.height > 0 && ic.height != NSViewNoIntrinsicMetric) h = ic.height;
        }
        if (h < 1) h = 44;
        [cs addObject:[v.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:x]];
        [cs addObject:[v.topAnchor constraintEqualToAnchor:self.topAnchor constant:y]];
        [cs addObject:[v.widthAnchor constraintEqualToConstant:itemW]];
        rowH = MAX(rowH, h);
        if (full) { y += rowH + kRowGap; col = 0; rowH = 0; }
        else if (++col >= cols) { y += rowH + kRowGap; col = 0; rowH = 0; }
    }
    if (col > 0) y += rowH + kRowGap;
    // 网格自身高度：优先级低于「卡片底 = 网格底」的钉子，避免两条等式互相打架
    // （实测打架结果是网格被压成 0 高、卡片只剩标题条，字段全被裁掉）。
    NSLayoutConstraint *hc = [self.heightAnchor constraintEqualToConstant:MAX(1, y - kRowGap + kBodyPadY)];
    hc.priority = NSLayoutPriorityDefaultHigh;
    [cs addObject:hc];
    self.contentHeight = MAX(1, y - kRowGap + kBodyPadY);
    [NSLayoutConstraint activateConstraints:cs];
    self.live = cs;
    self.inRelayout = NO;
    // 内容高度变了 ⟹ 让父卡片重新协商自身高度（只标脏，不在此处布局）
    if ([self.superview respondsToSelector:@selector(setNeedsUpdateConstraints:)])
        [self.superview setNeedsUpdateConstraints:YES];
}

#pragma mark - 异步内容到位（数据源行 / 表格返回后）

/// 数据是**异步**到的：挂载时按 0 行量高度，行回来之后必须重算一次，
/// 否则整块被按"0 行"裁掉 —— 底部提示「越靠上优先级越高」就是这么消失的
/// （2026-11-13 在元数据页截图里抓到：卡片只有标题行那么高，数据源行溢出卡片）。
/// 这里显式清掉"宽/项数未变"的短路，重算项高度，再让父卡片重新协商自身高度。
- (void)contentDidChange {
    self.lastItemCount = -1;
    [self relayout];
    [self invalidateIntrinsicContentSize];
    if ([self.superview respondsToSelector:@selector(contentDidChange)])
        [(id)self.superview contentDidChange];
}

- (void)setFrameSize:(NSSize)s {
    const BOOL changed = fabs(s.width - self.bounds.size.width) > 0.5;
    [super setFrameSize:s];
    if (changed) [self relayout];
}
- (void)layout { [super layout]; [self relayout]; }
/// 卡片被加进 stack 后宽度才确定：显式失效一次，让下一次 layout 重排。
- (void)invalidateLayout { self.lastWidth = -1; self.lastItemCount = NSUIntegerMax; [self setNeedsLayout:YES]; }

/// 内容（行数/行高）变了：强制下一次 layout 重排。
- (void)invalidateIntrinsicContentSize {
    [super invalidateIntrinsicContentSize];
    self.lastWidth = -1;
    self.lastItemCount = NSUIntegerMax;
    [self setNeedsLayout:YES];
}
@end

#pragma mark - 分组卡片

@interface RLPSettingsGroup ()
@property (nonatomic, strong) NSView *head;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *hintLabel;
@property (nonatomic, strong) RLPFieldGrid *grid;
/// 卡片总高约束：必须显式给出，否则外层 NSStackView 会把多余竖向空间摊给卡片，
/// 内部 head/grid 的钉子被挤压 ⟹ 标题条跑偏、字段被裁（实测过的真故障）。
@property (nonatomic, strong) NSLayoutConstraint *heightC;
@property (nonatomic, assign) BOOL syncingHeight;
@end

@implementation RLPSettingsGroup

- (instancetype)initWithTitle:(NSString *)title hint:(NSString *)hint {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        RLPTheme *t = [RLPTheme current];
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.wantsLayer = YES;
        self.identifier = @"set.group";
        self.layer.cornerRadius = 12;                 // .sgroup border-radius:12px
        self.layer.borderWidth = 1;
        self.layer.borderColor = t.line.CGColor;
        self.layer.backgroundColor = t.bg2.CGColor;   // .sgroup background:var(--bg2)

        _head = [[NSView alloc] initWithFrame:NSZeroRect];
        _head.identifier = @"set.group.head";
        _head.translatesAutoresizingMaskIntoConstraints = NO;
        _head.wantsLayer = YES;
        _head.layer.backgroundColor = t.bg3.CGColor;  // .sghead background:var(--bg3)
        [self addSubview:_head];

        _titleLabel = RLPLabel(title ?: @"", [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold], t.text);
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [_head addSubview:_titleLabel];
        if (hint.length) {
            _hintLabel = RLPLabel(hint, [NSFont systemFontOfSize:11], t.mut2);
            _hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
            _hintLabel.lineBreakMode = NSLineBreakByTruncatingTail;
            [_head addSubview:_hintLabel];
        }

        _grid = [[RLPFieldGrid alloc] initWithFrame:NSMakeRect(0, 0, 640, 10)];
        _grid.identifier = @"set.group.body";
        [self addSubview:_grid];

        NSMutableArray *cs = [NSMutableArray arrayWithArray:@[
            [_head.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:1],
            [_head.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-1],
            [_head.topAnchor constraintEqualToAnchor:self.topAnchor constant:1],
            [_head.heightAnchor constraintEqualToConstant:38],   // 11+16 内容 + 上下 padding
            [_titleLabel.leadingAnchor constraintEqualToAnchor:_head.leadingAnchor constant:16],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:_head.centerYAnchor],
            [_grid.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_grid.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_grid.topAnchor constraintEqualToAnchor:_head.bottomAnchor],
            [_grid.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-1],
        ]];
        if (_hintLabel) {
            [cs addObject:[_hintLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor constant:9]];
            [cs addObject:[_hintLabel.centerYAnchor constraintEqualToAnchor:_head.centerYAnchor]];
            [cs addObject:[_hintLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_head.trailingAnchor constant:-16]];
        }
        [NSLayoutConstraint activateConstraints:cs];
        _heightC = [self.heightAnchor constraintEqualToConstant:200];
        _heightC.priority = NSLayoutPriorityRequired;
        _heightC.active = YES;
        // 卡片不参与外层 stack 的竖向拉伸
        [self setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];
        [self setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];
    }
    return self;
}

- (NSInteger)columnCount { return self.grid.columnCount; }

/// 卡片高 = 上边框 1 + 标题条 38 + 网格内容高 + 下边框 1。
- (void)syncHeight { [self setNeedsUpdateConstraints:YES]; }

/// 一个字段：标签在上（11px/--mut）、控件、说明在下（10.5px/--mut2）。
- (NSView *)fieldWithLabel:(NSString *)label control:(NSView *)control hint:(NSString *)hint {
    RLPTheme *t = [RLPTheme current];
    NSStackView *box = [[NSStackView alloc] initWithFrame:NSZeroRect];
    box.orientation = NSUserInterfaceLayoutOrientationVertical;
    box.alignment = NSLayoutAttributeLeading;
    box.spacing = 5;
    box.translatesAutoresizingMaskIntoConstraints = NO;
    if (label.length) {
        NSTextField *l = RLPLabel(label, [NSFont systemFontOfSize:11 weight:NSFontWeightMedium], t.mut);
        l.translatesAutoresizingMaskIntoConstraints = NO;
        [box addArrangedSubview:l];
    }
    control.translatesAutoresizingMaskIntoConstraints = NO;
    [box addArrangedSubview:control];
    [control.widthAnchor constraintEqualToAnchor:box.widthAnchor].active = YES;
    if (hint.length) {
        NSTextField *hn = RLPLabel(hint, [NSFont systemFontOfSize:10.5], t.mut2);
        hn.translatesAutoresizingMaskIntoConstraints = NO;
        hn.lineBreakMode = NSLineBreakByWordWrapping;
        hn.maximumNumberOfLines = 3;
        [box addArrangedSubview:hn];
        [hn.widthAnchor constraintEqualToAnchor:box.widthAnchor].active = YES;
    }
    return box;
}

- (void)addField:(NSString *)label control:(NSView *)control hint:(NSString *)hint {
    [self.grid addItem:[self fieldWithLabel:label control:control hint:hint] span:NO];
    [self syncHeight];
}
- (void)addWideField:(NSString *)label control:(NSView *)control hint:(NSString *)hint {
    [self.grid addItem:[self fieldWithLabel:label control:control hint:hint] span:YES];
    [self syncHeight];
}

/// 开关行（web .chk）：开关在左、文字在右。
- (void)addCheck:(NSString *)label control:(NSView *)control hint:(NSString *)hint {
    RLPTheme *t = [RLPTheme current];
    NSStackView *box = [[NSStackView alloc] initWithFrame:NSZeroRect];
    box.orientation = NSUserInterfaceLayoutOrientationVertical;
    box.alignment = NSLayoutAttributeLeading;
    box.spacing = 4;
    box.translatesAutoresizingMaskIntoConstraints = NO;
    NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 8;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    control.translatesAutoresizingMaskIntoConstraints = NO;
    [row addArrangedSubview:control];
    NSTextField *l = RLPLabel(label ?: @"", [NSFont systemFontOfSize:12], t.text2);
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.lineBreakMode = NSLineBreakByWordWrapping;
    l.maximumNumberOfLines = 2;
    [row addArrangedSubview:l];
    [box addArrangedSubview:row];
    [row.widthAnchor constraintEqualToAnchor:box.widthAnchor].active = YES;
    if (hint.length) {
        NSTextField *hn = RLPLabel(hint, [NSFont systemFontOfSize:10.5], t.mut2);
        hn.translatesAutoresizingMaskIntoConstraints = NO;
        hn.lineBreakMode = NSLineBreakByWordWrapping;
        hn.maximumNumberOfLines = 3;
        [box addArrangedSubview:hn];
        [hn.widthAnchor constraintEqualToAnchor:box.widthAnchor].active = YES;
    }
    [self.grid addItem:box span:YES];
    [self syncHeight];
}

- (void)addButtonRow:(NSArray<NSView *> *)buttons {
    NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 8;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *b in buttons) {
        b.translatesAutoresizingMaskIntoConstraints = NO;
        [row addArrangedSubview:b];
    }
    [self.grid addItem:row span:YES];
    [self syncHeight];
}

- (void)addSubHeader:(NSString *)title hint:(NSString *)hint {
    RLPTheme *t = [RLPTheme current];
    NSView *box = [[NSView alloc] initWithFrame:NSZeroRect];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.identifier = @"set.subhead";
    NSTextField *titleL = RLPLabel(title ?: @"", [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold], t.text);
    titleL.translatesAutoresizingMaskIntoConstraints = NO;
    titleL.identifier = @"set.subhead.title";
    titleL.lineBreakMode = NSLineBreakByTruncatingTail;
    [box addSubview:titleL];
    NSView *line = [[NSView alloc] initWithFrame:NSZeroRect];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.wantsLayer = YES;
    line.layer.backgroundColor = t.line.CGColor;
    line.identifier = @"set.subhead.line";
    [box addSubview:line];
    NSMutableArray<NSLayoutConstraint *> *cs = [NSMutableArray arrayWithArray:@[
        [titleL.leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
        [titleL.topAnchor constraintEqualToAnchor:box.topAnchor],
        [line.leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
        [line.trailingAnchor constraintEqualToAnchor:box.trailingAnchor],
        [line.topAnchor constraintEqualToAnchor:titleL.bottomAnchor constant:8],
        [line.heightAnchor constraintEqualToConstant:1],
        [line.bottomAnchor constraintEqualToAnchor:box.bottomAnchor],
    ]];
    if (hint.length) {
        NSTextField *h = RLPLabel(hint, [NSFont systemFontOfSize:11], t.mut2);
        h.translatesAutoresizingMaskIntoConstraints = NO;
        h.identifier = @"set.subhead.hint";
        [box addSubview:h];
        [cs addObjectsFromArray:@[
            [h.leadingAnchor constraintEqualToAnchor:titleL.trailingAnchor constant:9],
            [h.centerYAnchor constraintEqualToAnchor:titleL.centerYAnchor],
            [h.trailingAnchor constraintLessThanOrEqualToAnchor:box.trailingAnchor],
        ]];
    }
    [NSLayoutConstraint activateConstraints:cs];
    [self.grid addItem:box span:YES];
    [self syncHeight];
}

- (void)addNoteView:(NSTextField *)note {
    if (!note) return;
    // hintForKey 当年为了老横向布局写死了 560pt；进卡片后必须改由网格给宽度，
    // 否则窄窗口下会横向溢出（第12项同时要修的就是这个"散块"来源之一）。
    for (NSLayoutConstraint *c in note.constraints.copy) {
        if (c.firstAttribute == NSLayoutAttributeWidth && c.secondItem == nil) c.active = NO;
    }
    note.translatesAutoresizingMaskIntoConstraints = NO;
    [self.grid addItem:note span:YES];
    [self syncHeight];
}

- (void)addNote:(NSString *)text {
    NSTextField *l = RLPLabel(text ?: @"", [NSFont systemFontOfSize:10.5], [RLPTheme current].mut2);
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.lineBreakMode = NSLineBreakByWordWrapping;
    l.maximumNumberOfLines = 6;
    [self.grid addItem:l span:YES];
    [self syncHeight];
}

- (void)addFullRow:(NSView *)view {
    [self.grid addItem:view span:YES];
    [self syncHeight];
}


/// 高度在 updateConstraints 里协商，**绝不在 -layout 里改约束**：
/// -layout 改约束 → 标脏 → 又进 -layout ⟹ 无限递归 → 栈溢出
/// （实测：test_servers_view SIGSEGV，栈里全是 AppKit 的 updateConstraintsForSubtree）。
- (void)updateConstraints {
    // 只读网格已经算好的 contentHeight，**不在这里触发任何布局**：
    // 在 updateConstraints 里调 layoutSubtreeIfNeeded 会重入约束求解 ⟹ 无限递归 → 栈溢出。
    const CGFloat want = 1 + 38 + self.grid.contentHeight + 1;
    if (want > 40 && fabs(self.heightC.constant - want) > 0.5) {
        self.heightC.constant = want;
    }
    [super updateConstraints];
}

/// 内容（异步到达的数据源行）变了 ⟹ 请求重新协商高度。
/// **只由数据加载方显式调用一次**，不挂任何 frame/通知观察者：
/// 观察者会在布局过程中触发 → 标脏 → 再布局，AppKit 直接 abort（实测 SIGTRAP）。
- (void)contentDidChange {
    [self.grid invalidateIntrinsicContentSize];
    [self setNeedsUpdateConstraints:YES];
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.layer.backgroundColor = t.bg2.CGColor;
    self.layer.borderColor = t.line.CGColor;
    self.head.layer.backgroundColor = t.bg3.CGColor;
    self.titleLabel.textColor = t.text;
    self.hintLabel.textColor = t.mut2;
}
@end
