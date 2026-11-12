// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPRightDrawer.mm — 队列 / 歌词抽屉，逐项对齐 web #right。
//
// 后端契约（与 web 同一条路径，不复制业务）：
//   GET  /api/queue            → {items:[path], cues:[[cs,ce]], index, mode, shuffle}
//   POST /api/qdel?i=N         → 移除第 N 项
//   POST /api/play  file=&cs=&ce=  → 播第 N 项（CUE 分轨要带 cs/ce）
//   POST /api/clear            → 清空队列
//   GET  /api/lyrics?file=…    → {ok, lrc}
//   POST /api/seek  ratio=…    → 点歌词行跳转
#import "RLPRightDrawer.h"
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPTheme.h"
#import "RLPLyrics.h"

// ── 队列行（web .qi）──
@interface RLPDrawerQueueRow : NSView
@property (nonatomic, assign) NSInteger index;
@property (nonatomic, assign) BOOL current;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) void (^onPlay)(NSInteger);
@property (nonatomic, copy) void (^onDelete)(NSInteger);
@end

@implementation RLPDrawerQueueRow {
    NSTextField *_num;
    NSTextField *_name;
    NSButton *_del;
    NSTrackingArea *_track;
    BOOL _hover;
}

- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    if (self) {
        self.wantsLayer = YES;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        _num = RLPLabel(@"", [RLPTheme current].caption, [RLPTheme current].mut2);
        _num.identifier = @"right.q.num";
        _num.alignment = NSTextAlignmentRight;
        _name = RLPLabel(@"", [NSFont systemFontOfSize:12.5], [RLPTheme current].text);
        _name.identifier = @"right.q.title";
        _name.lineBreakMode = NSLineBreakByTruncatingTail;
        _del = [NSButton buttonWithTitle:@"×" target:self action:@selector(delClicked:)];
        _del.identifier = @"right.q.del";
        _del.bezelStyle = NSBezelStyleInline;
        _del.font = [NSFont systemFontOfSize:14];
        _del.alphaValue = 0;                       // web: opacity 0，悬停才出现
        for (NSView *v in @[ _num, _name, _del ]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:v];
        }
        [NSLayoutConstraint activateConstraints:@[
            [self.heightAnchor constraintEqualToConstant:33],   // .qi padding 8+8 + 行高
            [_num.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
            [_num.widthAnchor constraintEqualToConstant:20],    // .qi .n width:20px
            [_num.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_name.leadingAnchor constraintEqualToAnchor:_num.trailingAnchor constant:9],
            [_name.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_del.leadingAnchor constraintEqualToAnchor:_name.trailingAnchor constant:6],
            [_del.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14],
            [_del.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_del.widthAnchor constraintEqualToConstant:20],
            [_del.heightAnchor constraintEqualToConstant:20],
        ]];
    }
    return self;
}

- (void)setTitle:(NSString *)title {
    _title = [title copy];
    _name.stringValue = title ?: @"";
    _name.toolTip = title;
}
- (void)setIndex:(NSInteger)index { _index = index; _num.stringValue = @(index + 1).stringValue; }

- (void)setCurrent:(BOOL)current {
    _current = current;
    [self repaint];
}

- (void)repaint {
    RLPTheme *t = [RLPTheme current];
    // .qi.on{background:var(--acc-weak);border-left-color:var(--acc);color:var(--acc-text)}
    self.layer.backgroundColor = self.current ? t.accentWeak.CGColor
                                  : (_hover ? t.hov.CGColor : [NSColor clearColor].CGColor);
    _name.textColor = self.current ? t.accentText : t.text;
    _name.font = self.current ? [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold]
                              : [NSFont systemFontOfSize:12.5];
    _num.textColor = t.mut2;
    self.needsDisplay = YES;
}

// 当前行左侧 3px 强调色竖条（web border-left:3px solid var(--acc)）
- (void)drawRect:(NSRect)dirty {
    [super drawRect:dirty];
    if (!self.current) return;
    [[RLPTheme current].accent setFill];
    NSRectFill(NSMakeRect(0, 0, 3, self.bounds.size.height));
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_track) { [self removeTrackingArea:_track]; _track = nil; }
    _track = [[NSTrackingArea alloc] initWithRect:self.bounds
        options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect)
        owner:self userInfo:nil];
    [self addTrackingArea:_track];
}
- (void)mouseEntered:(NSEvent *)e { _hover = YES; _del.alphaValue = 1; [self repaint]; }
- (void)mouseExited:(NSEvent *)e  { _hover = NO;  _del.alphaValue = 0; [self repaint]; }

- (void)mouseDown:(NSEvent *)e {
    // 点行 = 播这一首（web e.onclick → playPath）。删除按钮自己吃掉点击。
    if (self.onPlay) self.onPlay(self.index);
}
- (void)delClicked:(id)sender { if (self.onDelete) self.onDelete(self.index); }

// 右键只弹菜单，**不**直接删（web 修过的真故障：右击立刻 qdel 把行删了）
- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSMenu *m = [[NSMenu alloc] init];
    NSMenuItem *play = [[NSMenuItem alloc] initWithTitle:RLPTr(@"播放")
        action:@selector(menuPlay:) keyEquivalent:@""];
    play.target = self;
    NSMenuItem *del = [[NSMenuItem alloc] initWithTitle:RLPTr(@"从队列移除")
        action:@selector(menuDelete:) keyEquivalent:@""];
    del.target = self;
    [m addItem:play];
    [m addItem:[NSMenuItem separatorItem]];
    [m addItem:del];
    return m;
}
- (void)menuPlay:(id)sender   { if (self.onPlay) self.onPlay(self.index); }
- (void)menuDelete:(id)sender { if (self.onDelete) self.onDelete(self.index); }
@end

#pragma mark - 歌词行（web .ly）

@interface RLPDrawerLyricRow : NSView
@property (nonatomic, assign) double t;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, copy) void (^onSeek)(double);
@end

@implementation RLPDrawerLyricRow {
    NSTextField *_label;
    NSTrackingArea *_track;
    BOOL _hover;
}
- (instancetype)initWithText:(NSString *)text timed:(double)t {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        self.wantsLayer = YES;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        _t = t;
        _label = RLPLabel(text ?: @"", [NSFont systemFontOfSize:13.5], [RLPTheme current].mut2);
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        _label.lineBreakMode = NSLineBreakByWordWrapping;
        _label.maximumNumberOfLines = 3;
        [self addSubview:_label];
        [NSLayoutConstraint activateConstraints:@[
            [_label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:6],
            [_label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6],
            [_label.topAnchor constraintEqualToAnchor:self.topAnchor constant:5],
            [_label.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-5],
        ]];
    }
    return self;
}
- (void)setActive:(BOOL)active {
    _active = active;
    RLPTheme *t = [RLPTheme current];
    // .ly.on{color:var(--txt);font-weight:600;font-size:15px}
    _label.textColor = active ? t.text : (_hover ? t.mut : t.mut2);
    _label.font = active ? [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold]
                         : [NSFont systemFontOfSize:13.5];
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_track) { [self removeTrackingArea:_track]; _track = nil; }
    _track = [[NSTrackingArea alloc] initWithRect:self.bounds
        options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect)
        owner:self userInfo:nil];
    [self addTrackingArea:_track];
}
- (void)mouseEntered:(NSEvent *)e { _hover = YES; self.layer.backgroundColor = [RLPTheme current].hov.CGColor; [self setActive:_active]; }
- (void)mouseExited:(NSEvent *)e  { _hover = NO;  self.layer.backgroundColor = [NSColor clearColor].CGColor;   [self setActive:_active]; }
- (void)mouseDown:(NSEvent *)e {
    // 只有带时间轴的行能跳（web: l.t >= 0 && S.dur > 0）
    if (self.t >= 0 && self.onSeek) self.onSeek(self.t);
}
@end

#pragma mark - 抽屉本体

@interface RLPRightDrawer ()
@property (nonatomic, copy, readwrite) NSString *tab;
@property (nonatomic, assign, readwrite) BOOL polling;
@property (nonatomic, strong) NSButton *qTab;
@property (nonatomic, strong) NSButton *lTab;
@property (nonatomic, strong) NSTextField *count;
@property (nonatomic, strong) NSButton *clearBtn;
@property (nonatomic, strong) NSScrollView *qScroll;
@property (nonatomic, strong) NSStackView *qStack;
@property (nonatomic, strong) NSScrollView *lScroll;
@property (nonatomic, strong) NSStackView *lStack;
@property (nonatomic, strong) NSTextField *lHint;
@property (nonatomic, strong) NSTimer *poll;
@property (nonatomic, copy) NSArray<NSString *> *items;
@property (nonatomic, copy) NSArray *cues;
@property (nonatomic, assign) NSInteger qIndex;
@property (nonatomic, copy) NSArray<RLPLyricLine *> *lines;
@property (nonatomic, copy) NSString *lyricFile;
@property (nonatomic, assign) NSInteger lyricRetry;
@property (nonatomic, strong) NSTimer *lyricTimer;
@property (nonatomic, assign) NSInteger activeLine;
@property (nonatomic, assign) double dur;
@property (nonatomic, strong) NSMutableArray<RLPDrawerLyricRow *> *lyricRows;
@end

@implementation RLPRightDrawer

- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    if (self) {
        _tab = @"q";
        _items = @[]; _cues = @[]; _lines = @[]; _qIndex = -1; _activeLine = -1;
        _lyricRows = [NSMutableArray array];
        [self buildUI];
    }
    return self;
}

- (void)dealloc { [self deactivate]; [_lyricTimer invalidate]; }

- (void)buildUI {
    RLPTheme *t = [RLPTheme current];
    self.wantsLayer = YES;
    self.identifier = @"right";                 // web #right
    self.layer.cornerRadius = 14;               // border-radius:14px
    self.layer.borderWidth = 1;
    self.layer.borderColor = t.barBorder.CGColor;
    self.layer.backgroundColor = t.barBg.CGColor;
    self.layer.masksToBounds = YES;
    // backdrop-filter:blur(32px) saturate(190%) → 毛玻璃
    self.layer.shadowColor = [NSColor blackColor].CGColor;
    self.layer.shadowOpacity = t.isLight ? 0.13 : 0.55;
    self.layer.shadowRadius = 22;
    self.layer.shadowOffset = CGSizeMake(0, -8);

    NSView *head = [[NSView alloc] initWithFrame:NSZeroRect];
    head.identifier = @"right.head";            // web .rhead
    head.translatesAutoresizingMaskIntoConstraints = NO;
    head.wantsLayer = YES;
    [self addSubview:head];

    self.qTab = [self tabButton:RLPTr(@"队列") ident:@"right.tab.q" action:@selector(tabQ:)];
    self.lTab = [self tabButton:RLPTr(@"歌词") ident:@"right.tab.l" action:@selector(tabL:)];
    self.count = RLPLabel(@"", t.caption, t.mut2);
    self.count.identifier = @"right.count";     // web #rcnt
    self.count.translatesAutoresizingMaskIntoConstraints = NO;
    // 空串时 intrinsic 宽度接近 0，之后设了文字也不会重新协商 ⟹ 显式给宽度
    [self.count.widthAnchor constraintGreaterThanOrEqualToConstant:64].active = YES;
    self.clearBtn = [NSButton buttonWithTitle:RLPTr(@"清除") target:self action:@selector(clearQueue:)];
    self.clearBtn.identifier = @"right.clear";  // web #qclr
    self.clearBtn.bezelStyle = NSBezelStyleInline;
    self.clearBtn.font = [NSFont systemFontOfSize:11.5];
    self.clearBtn.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSView *v in @[ self.qTab, self.lTab, self.count, self.clearBtn ]) [head addSubview:v];

    self.qStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.qStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.qStack.alignment = NSLayoutAttributeLeading;
    self.qStack.spacing = 0;
    self.qStack.identifier = @"right.qlist";    // web #qlist
    self.qStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.qScroll = [self scrollWith:self.qStack ident:@"right.qbody"];

    self.lHint = RLPLabel(@"", [NSFont systemFontOfSize:10.5], t.mut2);
    self.lHint.identifier = @"right.ly.hint";   // web .ly-hint
    self.lHint.hidden = YES;
    self.lHint.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:self.lHint];

    self.lStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.lStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.lStack.alignment = NSLayoutAttributeLeading;
    self.lStack.spacing = 0;
    self.lStack.identifier = @"right.lyricbox"; // web #lyricbox
    self.lStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.lScroll = [self scrollWith:self.lStack ident:@"right.lbody"];
    self.lScroll.hidden = YES;

    [NSLayoutConstraint activateConstraints:@[
        [head.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [head.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [head.topAnchor constraintEqualToAnchor:self.topAnchor],
        [head.heightAnchor constraintEqualToConstant:42],       // .rhead min-height:42px

        [self.qTab.leadingAnchor constraintEqualToAnchor:head.leadingAnchor constant:14],
        [self.qTab.centerYAnchor constraintEqualToAnchor:head.centerYAnchor],
        [self.lTab.leadingAnchor constraintEqualToAnchor:self.qTab.trailingAnchor constant:8],
        [self.lTab.centerYAnchor constraintEqualToAnchor:head.centerYAnchor],
        [self.count.leadingAnchor constraintEqualToAnchor:self.lTab.trailingAnchor constant:8],
        [self.count.centerYAnchor constraintEqualToAnchor:head.centerYAnchor],
        [self.clearBtn.trailingAnchor constraintEqualToAnchor:head.trailingAnchor constant:-14],
        [self.clearBtn.centerYAnchor constraintEqualToAnchor:head.centerYAnchor],

        [self.lHint.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
        [self.lHint.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14],
        [self.lHint.topAnchor constraintEqualToAnchor:head.bottomAnchor constant:3],

        [self.qScroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.qScroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.qScroll.topAnchor constraintEqualToAnchor:head.bottomAnchor],
        [self.qScroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [self.qStack.widthAnchor constraintEqualToAnchor:self.qScroll.widthAnchor],

        [self.lScroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.lScroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.lScroll.topAnchor constraintEqualToAnchor:self.lHint.bottomAnchor constant:4],
        [self.lScroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [self.lStack.widthAnchor constraintEqualToAnchor:self.lScroll.widthAnchor],
    ]];
    [self refreshTabs];
}

/// 页签按钮 = web .rtab：一个文字胶囊（padding 4/10、圆角 7、11.5px）。
/// 不用系统 bezel：Inline bezel 会自带背景与内边距，且 contentTintColor 对标题不一定生效
/// （实测：按钮在截图里完全看不见）。这里用无边框按钮 + 富文本标题，颜色显式给定。
- (NSButton *)tabButton:(NSString *)title ident:(NSString *)ident action:(SEL)act {
    NSButton *b = [NSButton buttonWithTitle:title target:self action:act];
    b.identifier = ident;
    b.bordered = NO;
    b.bezelStyle = NSBezelStyleRegularSquare;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.wantsLayer = YES;
    [b.heightAnchor constraintEqualToConstant:24].active = YES;   // 4+16+4
    return b;
}

- (NSScrollView *)scrollWith:(NSStackView *)stack ident:(NSString *)ident {
    NSScrollView *sc = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    sc.identifier = ident;
    sc.translatesAutoresizingMaskIntoConstraints = NO;
    sc.drawsBackground = NO;
    sc.hasVerticalScroller = YES;
    sc.autohidesScrollers = YES;
    sc.scrollerStyle = NSScrollerStyleOverlay;
    NSView *doc = [[NSView alloc] initWithFrame:NSZeroRect];
    doc.translatesAutoresizingMaskIntoConstraints = NO;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [doc addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:doc.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:doc.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:doc.bottomAnchor],
    ]];
    sc.documentView = doc;
    [self addSubview:sc];
    return sc;
}

- (void)refreshTabs {
    RLPTheme *t = [RLPTheme current];
    const BOOL q = [self.tab isEqualToString:@"q"];
    // .rtab.on{background:var(--acc-weak);color:var(--acc-text);font-weight:600}
    for (NSButton *b in @[ self.qTab, self.lTab ]) {
        const BOOL on = (b == self.qTab) ? q : !q;
        b.layer.cornerRadius = 7;                       // .rtab border-radius:7px
        b.layer.backgroundColor = on ? t.accentWeak.CGColor : [NSColor clearColor].CGColor;
        NSFont *f = on ? [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold]
                       : [NSFont systemFontOfSize:11.5];
        // 富文本标题：颜色必须写进 attributedTitle，否则无边框按钮用默认色（浅色主题下几乎看不见）
        NSDictionary *attrs = @{ NSFontAttributeName: f,
                                 NSForegroundColorAttributeName: on ? t.accentText : t.mut };
        b.attributedTitle = [[NSAttributedString alloc] initWithString:b.title attributes:attrs];
        // 无边框按钮改 attributedTitle 后 intrinsic 宽度会塌成 0（实测：胶囊完全看不见）。
        // 显式按文字宽度 + web .rtab 的左右 padding 10px 给宽度。
        const CGFloat tw = [b.title sizeWithAttributes:attrs].width;
        [b.widthAnchor constraintEqualToConstant:ceil(tw) + 20].active = YES;
    }
    self.qScroll.hidden = !q;
    self.lScroll.hidden = q;
    self.lHint.hidden = q || self.lHint.stringValue.length == 0;
    self.clearBtn.hidden = !q;
    self.count.hidden = !q;
}

- (void)showTab:(NSString *)tab {
    self.tab = [tab isEqualToString:@"l"] ? @"l" : @"q";
    [self refreshTabs];
    if ([self.tab isEqualToString:@"l"]) [self loadLyricsForCurrent:NO];
    else [self loadQueue];
}
- (void)tabQ:(id)s { [self showTab:@"q"]; }
- (void)tabL:(id)s { [self showTab:@"l"]; }

#pragma mark - 队列

- (void)loadQueue {
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) w = self;
    [[RLPCoreClient shared] getJSON:@"/api/queue" completion:^(NSDictionary * _Nullable j) {
        __typeof__(self) s = w;
        if (!s || ![j isKindOfClass:[NSDictionary class]]) return;   // 失败原地不动（web 同口径）
        NSArray *items = [j[@"items"] isKindOfClass:[NSArray class]] ? j[@"items"] : nil;
        if (!items) return;
        s.items = items;
        s.cues = [j[@"cues"] isKindOfClass:[NSArray class]] ? j[@"cues"] : @[];
        s.qIndex = [j[@"index"] respondsToSelector:@selector(integerValue)] ? [j[@"index"] integerValue] : -1;
        [s renderQueue];
    }];
}

- (void)renderQueue {
    for (NSView *v in [self.qStack.arrangedSubviews copy]) {
        [self.qStack removeArrangedSubview:v]; [v removeFromSuperview];
    }
    RLPTheme *t = [RLPTheme current];
    self.count.stringValue = [NSString stringWithFormat:RLPTr(@"共 %lu 首"), (unsigned long)self.items.count];
    if (!self.items.count) {
        NSTextField *e = RLPLabel(RLPTr(@"队列为空\n右键专辑或曲目可加入"), t.small, t.mut2);
        e.identifier = @"right.q.empty";
        e.alignment = NSTextAlignmentCenter;
        e.maximumNumberOfLines = 2;
        e.translatesAutoresizingMaskIntoConstraints = NO;
        [self.qStack addArrangedSubview:e];
        [e.widthAnchor constraintEqualToAnchor:self.qStack.widthAnchor].active = YES;
        return;
    }
    __weak __typeof__(self) w = self;
    for (NSInteger i = 0; i < (NSInteger)self.items.count; ++i) {
        NSString *path = self.items[(NSUInteger)i];
        RLPDrawerQueueRow *row = [[RLPDrawerQueueRow alloc] initWithFrame:NSZeroRect];
        row.index = i;
        row.title = path.lastPathComponent.stringByDeletingPathExtension;
        row.current = (i == self.qIndex);
        row.onPlay = ^(NSInteger idx) { [w playIndex:idx]; };
        row.onDelete = ^(NSInteger idx) { [w deleteIndex:idx]; };
        [self.qStack addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.qStack.widthAnchor].active = YES;
    }
}

- (void)playIndex:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)self.items.count) return;
    NSString *f = self.items[(NSUInteger)i];
    NSArray *c = (i < (NSInteger)self.cues.count) ? self.cues[(NSUInteger)i] : nil;
    double cs = (c.count >= 2) ? [c[0] doubleValue] : -1;
    double ce = (c.count >= 2) ? [c[1] doubleValue] : -1;
    // CUE 分轨必须带 cs/ce，否则会播整轨（web playPath 同口径）
    NSMutableString *body = [NSMutableString stringWithFormat:@"file=%@", RLPEnc(f)];
    if (cs >= 0) [body appendFormat:@"&cs=%.3f", cs];
    if (ce >= 0) [body appendFormat:@"&ce=%.3f", ce];
    [[RLPCoreClient shared] postJSON:@"/api/play" body:body completion:^(NSDictionary * _Nullable j) {
        [self loadQueue];
        [self loadLyricsForCurrent:NO];
    }];
}

- (void)deleteIndex:(NSInteger)i {
    [[RLPCoreClient shared] postJSON:[NSString stringWithFormat:@"/api/qdel?i=%ld", (long)i]
                                body:nil completion:^(NSDictionary * _Nullable j) {
        RLPToast(RLPTr(@"已移除"));
        [self loadQueue];
    }];
}

- (void)clearQueue:(id)sender {
    if (!self.items.count) return;
    // 破坏性操作要确认（web 的 qclr 也是先确认）
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = RLPTr(@"清空播放队列？");
    a.informativeText = RLPTr(@"当前播放会停止，队列中的曲目将被移除。");
    [a addButtonWithTitle:RLPTr(@"清空")];
    [a addButtonWithTitle:RLPTr(@"取消")];
    a.alertStyle = NSAlertStyleWarning;
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    [[RLPCoreClient shared] postJSON:@"/api/clear" body:nil completion:^(NSDictionary * _Nullable j) {
        [self loadQueue];
    }];
}

#pragma mark - 歌词

- (void)loadLyricsForCurrent:(BOOL)isRetry {
    if (![RLPCoreClient shared].started) return;
    NSString *file = nil;
    if (self.qIndex >= 0 && self.qIndex < (NSInteger)self.items.count)
        file = self.items[(NSUInteger)self.qIndex];
    if (!file.length) { [self renderLyricMessage:RLPTr(@"还没有播放曲目")]; return; }
    if ([file hasPrefix:@"http://"] || [file hasPrefix:@"https://"]) {
        [self renderLyricMessage:RLPTr(@"网络曲目暂无歌词")]; return;
    }
    if (!isRetry) {
        self.lyricFile = file; self.lyricRetry = 0;
        [self.lyricTimer invalidate]; self.lyricTimer = nil;
    }
    __weak __typeof__(self) w = self;
    NSString *url = [@"/api/lyrics?file=" stringByAppendingString:RLPEnc(file)];
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable j) {
        __typeof__(self) s = w;
        if (!s) return;
        NSString *lrc = [j[@"lrc"] isKindOfClass:[NSString class]] ? j[@"lrc"] : @"";
        s.lines = [RLPLyrics parse:lrc];
        s.activeLine = -1;
        if (s.lines.count) { [s renderLyrics]; return; }
        // 空结果退避重试（web 1/2/3/5/8/13s，最多 6 次 ≈ 32s）：后台可能正在补全
        const NSInteger waits[] = {1, 2, 3, 5, 8, 13};
        if ([s.lyricFile isEqualToString:file] && s.lyricRetry < 6) {
            NSTimeInterval wait = waits[s.lyricRetry];
            s.lyricRetry++;
            [s renderLyricMessage:RLPTr(@"歌词加载中…\n正在等后台补全（首次播放新曲目时可能要几秒）")];
            [s.lyricTimer invalidate];
            s.lyricTimer = [NSTimer scheduledTimerWithTimeInterval:wait repeats:NO block:^(NSTimer *tm) {
                __typeof__(self) s2 = w;
                if (!s2) return;
                if ([s2.lyricFile isEqualToString:file]) [s2 loadLyricsForCurrent:YES];
            }];
            return;
        }
        [s renderLyricMessage:RLPTr(@"没有歌词\n同名 .lrc 文件、内嵌歌词，或播放时自动在线补全")];
    }];
}

- (void)renderLyricMessage:(NSString *)msg {
    for (NSView *v in [self.lStack.arrangedSubviews copy]) {
        [self.lStack removeArrangedSubview:v]; [v removeFromSuperview];
    }
    [self.lyricRows removeAllObjects];
    self.lHint.hidden = YES;
    NSTextField *l = RLPLabel(msg, [NSFont systemFontOfSize:12], [RLPTheme current].mut2);
    l.identifier = @"right.ly.none";
    l.maximumNumberOfLines = 4;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [self.lStack addArrangedSubview:l];
    [l.widthAnchor constraintEqualToAnchor:self.lStack.widthAnchor constant:-28].active = YES;
}

- (void)renderLyrics {
    for (NSView *v in [self.lStack.arrangedSubviews copy]) {
        [self.lStack removeArrangedSubview:v]; [v removeFromSuperview];
    }
    [self.lyricRows removeAllObjects];
    const BOOL timed = [RLPLyrics isTimed:self.lines];
    // 纯文本歌词给显式提示（web：否则"不滚"看起来像坏了）
    self.lHint.stringValue = timed ? @"" : RLPTr(@"纯文本歌词（无时间轴）· 不会自动跟随滚动");
    self.lHint.hidden = timed || ![self.tab isEqualToString:@"l"];
    __weak __typeof__(self) w = self;
    for (RLPLyricLine *line in self.lines) {
        RLPDrawerLyricRow *row = [[RLPDrawerLyricRow alloc] initWithText:line.text timed:line.t];
        row.onSeek = ^(double t) {
            __typeof__(self) s = w;
            if (!s || s.dur <= 0) return;
            [[RLPCoreClient shared] postJSON:
                [NSString stringWithFormat:@"/api/seek?ratio=%.6f", t / s.dur]
                body:nil completion:nil];
        };
        [self.lyricRows addObject:row];
        [self.lStack addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.lStack.widthAnchor constant:-16].active = YES;
    }
}

- (void)updatePosition:(double)pos duration:(double)dur {
    self.dur = dur;
    if (![self.tab isEqualToString:@"l"] || ![RLPLyrics isTimed:self.lines]) return;
    const NSInteger idx = [RLPLyrics activeIndex:self.lines position:pos];
    if (idx == self.activeLine) return;
    if (self.activeLine >= 0 && self.activeLine < (NSInteger)self.lyricRows.count)
        self.lyricRows[(NSUInteger)self.activeLine].active = NO;
    self.activeLine = idx;
    if (idx >= 0 && idx < (NSInteger)self.lyricRows.count) {
        RLPDrawerLyricRow *row = self.lyricRows[(NSUInteger)idx];
        row.active = YES;
        // 跟随滚动：把当前行滚到可视区中部（web syncLyrics 同语义）
        NSRect r = row.frame;
        CGFloat target = r.origin.y - self.lScroll.contentView.bounds.size.height / 2 + r.size.height / 2;
        CGFloat maxY = MAX(0, self.lStack.frame.size.height - self.lScroll.contentView.bounds.size.height);
        target = MAX(0, MIN(target, maxY));
        [self.lScroll.contentView scrollToPoint:NSMakePoint(0, target)];
        [self.lScroll reflectScrolledClipView:self.lScroll.contentView];
    }
}

#pragma mark - 生命周期

- (void)activate {
    [self loadQueue];
    if ([self.tab isEqualToString:@"l"]) [self loadLyricsForCurrent:NO];
    if (self.poll || ![RLPCoreClient shared].started) return;
    self.polling = YES;
    __weak __typeof__(self) w = self;
    self.poll = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *tm) {
        __typeof__(self) s = w;
        if (!s) { [tm invalidate]; return; }
        [s loadQueue];      // web pollSchedule：队列 1s
    }];
}

- (void)deactivate {
    [self.poll invalidate]; self.poll = nil; self.polling = NO;
    [self.lyricTimer invalidate]; self.lyricTimer = nil;
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.layer.backgroundColor = t.barBg.CGColor;
    self.layer.borderColor = t.barBorder.CGColor;
    self.layer.shadowOpacity = t.isLight ? 0.13 : 0.55;
    self.count.textColor = t.mut2;
    self.lHint.textColor = t.mut2;
    [self refreshTabs];
    [self renderQueue];
    if (self.lines.count) [self renderLyrics];
}

@end
