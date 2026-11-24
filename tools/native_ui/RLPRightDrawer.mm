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
//   POST /api/seek  pos=…      → 点歌词行跳转（0..1 比例，参数名与 web doSeek 一致）
#import "RLPRightDrawer.h"
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPTheme.h"
#import "RLPLyrics.h"

#include <math.h>   // fmin/fmax：歌词行比例钳位（勿依赖 AppKit 的间接包含）

// ── 队列行（web .qi）──
@interface RLPDrawerQueueRow : NSView
@property (nonatomic, assign) NSInteger index;
@property (nonatomic, assign) BOOL current;
@property (nonatomic, copy) NSString *path;
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
/// 右键菜单（歌词 AI 六项）：行本体与文字标签都要设，否则点在文字上没有菜单。
- (void)setContextMenu:(NSMenu *)menu;
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
- (void)setContextMenu:(NSMenu *)menu {
    self.menu = menu;    // NSView 的默认 menuForEvent 返回 self.menu
    _label.menu = menu;  // 点在文字上时是 label 收到右键，所以它也要有
}
@end

#pragma mark - 抽屉本体

/// 滚动区 documentView 必须是翻转坐标：非翻转的 NSStackView 作为 documentView 时，
/// 内容从**底部**开始排（用户实测：队列 9 行全挤在右侧面板下半部 = 播放列表错位）。
/// 翻转后第一行从顶部开始，和 web #qlist 一致。
@interface RLPFlippedStackView : NSStackView
@end
@implementation RLPFlippedStackView
- (BOOL)isFlipped { return YES; }
@end

/// 滚动区 documentView 用翻转坐标：内容从顶部开始（非翻转 doc 会把内容钉在底部）。
@interface RLPFlippedDocumentView : NSView
@end
@implementation RLPFlippedDocumentView
- (BOOL)isFlipped { return YES; }
@end

@interface RLPRightDrawer () <NSMenuDelegate>
@property (nonatomic, copy, readwrite) NSString *tab;
@property (nonatomic, assign, readwrite) BOOL polling;
@property (nonatomic, strong) NSButton *qTab;
@property (nonatomic, strong) NSButton *lTab;
@property (nonatomic, strong) NSLayoutConstraint *qTabWidthConstraint;
@property (nonatomic, strong) NSLayoutConstraint *lTabWidthConstraint;
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
/// 队列快照代次：旧 /api/queue 回包不得覆盖新队列。
@property (nonatomic, assign) NSUInteger loadSeq;
/// 同一行的连点去重（双击/连击不重复打断起播）。
@property (nonatomic, copy) NSString *lastPlayKey;
@property (nonatomic, assign) NSTimeInterval lastPlayAt;
@property (nonatomic, copy) NSArray<RLPLyricLine *> *lines;
@property (nonatomic, copy) NSString *lyricFile;
@property (nonatomic, assign) NSInteger lyricRetry;
@property (nonatomic, strong) NSTimer *lyricTimer;
@property (nonatomic, assign) NSInteger activeLine;
@property (nonatomic, assign) double lastPos;
@property (nonatomic, assign) double dur;
@property (nonatomic, copy, nullable) NSString *lHintKey;
@property (nonatomic, copy, nullable) NSString *lHintErr;
@property (nonatomic, copy, nullable) NSString *lyricMsgKey;
@property (nonatomic, strong) NSMutableArray<RLPDrawerLyricRow *> *lyricRows;
/// 歌词 AI：翻译/音译/假名/繁体应用前的原文（"恢复原文"用）。
@property (nonatomic, copy) NSArray<RLPLyricLine *> *originalLyricLines;
@property (nonatomic, assign) BOOL lyricAiApplied;
@property (nonatomic, assign) BOOL lyricAiBusy;
@property (nonatomic, assign) BOOL deleteInFlight;
@property (nonatomic, strong) NSMenu *lyricAiMenu;
/// 歌词 AI：菜单构造 / 提示 / 请求（实现见文件后半「歌词 AI」段；先声明以避"selector 未声明"告警）。
- (NSMenu *)lyricAiMenu;
- (NSMenuItem *)lyricAiItem:(NSString *)title action:(SEL)sel;
- (void)showLyricHint:(NSString *)msg;
- (void)runLyricAiTask:(NSString *)task lang:(NSString *)lang;
- (void)deleteIndex:(NSInteger)i expectedPath:(NSString *)expectedPath;
@end

@implementation RLPRightDrawer

- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    if (self) {
        _tab = @"q";
        _items = @[]; _cues = @[]; _lines = @[]; _qIndex = -1; _activeLine = -1;
        _lyricRows = [NSMutableArray array];
        [self buildUI];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onExternalQueueChanged:)
                                                     name:RLPQueueChangedNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self deactivate];
    [_lyricTimer invalidate];
}

- (void)onExternalQueueChanged:(NSNotification *)note {
    if (note.object == self) return;
    if (![RLPCoreClient shared].started) return;
    [self loadQueue];
}

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

    self.qStack = [[RLPFlippedStackView alloc] initWithFrame:NSZeroRect];
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

    self.lStack = [[RLPFlippedStackView alloc] initWithFrame:NSZeroRect];
    self.lStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.lStack.alignment = NSLayoutAttributeLeading;
    self.lStack.spacing = 0;
    self.lStack.identifier = @"right.lyricbox"; // web #lyricbox
    self.lStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.lScroll = [self scrollWith:self.lStack ident:@"right.lbody"];
    self.lScroll.hidden = YES;
    // 歌词区任意位置右键都要出 AI 菜单（空白处也是），所以滚动区与栈也挂同一份菜单。
    self.lStack.menu = [self lyricAiMenu];
    self.lScroll.menu = [self lyricAiMenu];

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
    NSLayoutConstraint *wc = [b.widthAnchor constraintEqualToConstant:52];
    wc.active = YES;
    if ([ident isEqualToString:@"right.tab.q"]) self.qTabWidthConstraint = wc;
    else if ([ident isEqualToString:@"right.tab.l"]) self.lTabWidthConstraint = wc;
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
    NSView *doc = [[RLPFlippedDocumentView alloc] initWithFrame:NSZeroRect];
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
        NSLayoutConstraint *wc = (b == self.qTab) ? self.qTabWidthConstraint : self.lTabWidthConstraint;
        if (wc) {
            wc.constant = ceil(tw) + 20;
        } else {
            wc = [b.widthAnchor constraintEqualToConstant:ceil(tw) + 20];
            wc.active = YES;
            if (b == self.qTab) self.qTabWidthConstraint = wc;
            else self.lTabWidthConstraint = wc;
        }
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

/// 当前队列项路径（qIndex 越界/空队列返回 nil）。
- (NSString *)currentTrackPath {
    if (self.qIndex >= 0 && self.qIndex < (NSInteger)self.items.count)
        return self.items[(NSUInteger)self.qIndex];
    return nil;
}

- (void)loadQueue {
    if (![RLPCoreClient shared].started) return;
    const NSUInteger seq = ++self.loadSeq;
    __weak __typeof__(self) w = self;
    [[RLPCoreClient shared] getJSON:@"/api/queue" completion:^(NSDictionary * _Nullable j) {
        __typeof__(self) s = w;
        if (!s || seq != s.loadSeq) return;   // 旧回包不得覆盖新队列
        if (![j isKindOfClass:[NSDictionary class]]) return;   // 失败原地不动（web 同口径）
        NSArray *items = [j[@"items"] isKindOfClass:[NSArray class]] ? j[@"items"] : nil;
        if (!items) return;
        s.items = items;
        s.cues = [j[@"cues"] isKindOfClass:[NSArray class]] ? j[@"cues"] : @[];
        s.qIndex = [j[@"index"] respondsToSelector:@selector(integerValue)] ? [j[@"index"] integerValue] : -1;
        [s renderQueue];
        // 换曲检测（web：pollStatus 发现 lastCur 变化就 loadLyrics 新曲）。
        // 旧码的 1s 轮询只更新 qIndex，从不重拉歌词 ⟹ 在歌词页签切歌后永远停在上一首的词。
        // 判据口径：只有「当前曲真的变了」才重拉（同一首每秒重拉 = 把后端打爆，也违反 web 语义）。
        NSString *nowPath = [s currentTrackPath] ?: @"";
        if (![s.tab isEqualToString:@"l"]) return;
        if ([nowPath isEqualToString:(s.lyricFile ?: @"")]) return;
        [s loadLyricsForCurrent:NO];
    }];
}

- (void)renderQueue {
    for (NSView *v in [self.qStack.arrangedSubviews copy]) {
        [self.qStack removeArrangedSubview:v]; [v removeFromSuperview];
    }
    RLPTheme *t = [RLPTheme current];
    self.count.stringValue = [NSString stringWithFormat:RLPTr(@"共 %lu 首"), (unsigned long)self.items.count];
    if (!self.items.count) {
        NSTextField *e = RLPLabel([RLPTr(@"队列为空") stringByAppendingFormat:@"\n%@", RLPTr(@"右键专辑或曲目可加入")], t.small, t.mut2);
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
        id itemObj = self.items[(NSUInteger)i];
        NSString *path = [itemObj isKindOfClass:[NSString class]] ? (NSString *)itemObj : @"";
        RLPDrawerQueueRow *row = [[RLPDrawerQueueRow alloc] initWithFrame:NSZeroRect];
        row.index = i;
        row.path = path;
        row.title = path.lastPathComponent.stringByDeletingPathExtension;
        row.current = (i == self.qIndex);
        NSString *capturedPath = [path copy];
        row.onPlay = ^(NSInteger idx) { [w playIndex:idx]; };
        row.onDelete = ^(NSInteger idx) { [w deleteIndex:idx expectedPath:capturedPath]; };
        [self.qStack addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.qStack.widthAnchor].active = YES;
    }
}

- (void)playIndex:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)self.items.count) return;
    NSString *f = self.items[(NSUInteger)i];
    // 同一行 350ms 内连点/双击只起播一次，避免刚起播就被自己打断重头。
    NSString *key = [NSString stringWithFormat:@"%ld:%@", (long)i, f];
    const NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    if ([key isEqualToString:self.lastPlayKey] && now - self.lastPlayAt < 0.35) return;
    self.lastPlayKey = key;
    self.lastPlayAt = now;
    NSArray *c = (i < (NSInteger)self.cues.count) ? self.cues[(NSUInteger)i] : nil;
    double cs = (c.count >= 2) ? [c[0] doubleValue] : -1;
    double ce = (c.count >= 2) ? [c[1] doubleValue] : -1;
    // CUE 分轨必须带 cs/ce，否则会播整轨（web playPath 同口径）
    NSMutableString *body = [NSMutableString stringWithFormat:@"file=%@", RLPEnc(f)];
    if (cs >= 0) [body appendFormat:@"&cs=%.3f", cs];
    if (ce >= 0) [body appendFormat:@"&ce=%.3f", ce];
    const uint64_t actionEpoch = RLPBeginPlaybackAction();
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/play" body:body completion:^(NSDictionary * _Nullable j) {
        __typeof__(self) self_ = weakSelf;
        if (actionEpoch != RLPPlaybackActionEpoch()) return;
        RLPHandlePlaybackActionResponse(j, @"播放失败");
        // 这里**不能**直接 loadLyricsForCurrent：此刻 qIndex/items 还是旧队列，
        // 读到的是上一首的 file（审计 C 项的成因）。歌词跟随由 loadQueue 的换曲检测驱动。
        [self_ loadQueue];
    }];
}

- (void)deleteIndex:(NSInteger)i {
    [self deleteIndex:i expectedPath:nil];
}

- (void)deleteIndex:(NSInteger)i expectedPath:(NSString *)expectedPath {
    if (i < 0) return;
    if (self.deleteInFlight) return;   // 删除在途时拒绝同 index 重复删除（并避免并发删除导致索引漂移）
    if (i >= (NSInteger)self.items.count) {
        if (expectedPath.length) {
            RLPToast(RLPTr(@"移除失败"));
            [self loadQueue];
        }
        return;
    }
    id localObj = self.items[(NSUInteger)i];
    NSString *localPath = [localObj isKindOfClass:[NSString class]] ? (NSString *)localObj : nil;
    NSString *capturedPath = expectedPath.length ? [expectedPath copy] : [localPath copy];
    if (!capturedPath.length) return;
    if (expectedPath.length && ![localPath isEqualToString:capturedPath]) {
        RLPToast(RLPTr(@"移除失败"));
        [self loadQueue];
        return;
    }
    self.deleteInFlight = YES;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/queue" completion:^(NSDictionary * _Nullable qj) {
        __typeof__(self) s = weakSelf;
        if (!s) return;
        NSArray *qItems = ([qj isKindOfClass:[NSDictionary class]] &&
                           (!qj[@"ok"] || [qj[@"ok"] boolValue]) &&
                           [qj[@"items"] isKindOfClass:[NSArray class]])
                        ? qj[@"items"] : nil;
        id remoteObj = (qItems && i < (NSInteger)qItems.count) ? qItems[(NSUInteger)i] : nil;
        id curObj = (i < (NSInteger)s.items.count) ? s.items[(NSUInteger)i] : nil;
        const BOOL remoteMatch = ([remoteObj isKindOfClass:[NSString class]] &&
                                  [(NSString *)remoteObj isEqualToString:capturedPath]);
        const BOOL localMatch = ([curObj isKindOfClass:[NSString class]] &&
                                 [(NSString *)curObj isEqualToString:capturedPath]);
        if (!remoteMatch || !localMatch) {
            s.deleteInFlight = NO;
            RLPToast(RLPTr(@"移除失败"));
            [s loadQueue];
            return;
        }
        [[RLPCoreClient shared] postJSON:[NSString stringWithFormat:@"/api/qdel?i=%ld", (long)i]
                                    body:nil completion:^(NSDictionary * _Nullable j) {
            __typeof__(self) s2 = weakSelf;
            if (!s2) return;
            s2.deleteInFlight = NO;
            if (!j || ![j[@"ok"] boolValue]) {
                NSString *err = ([j[@"error"] isKindOfClass:[NSString class]] && [(NSString *)j[@"error"] length])
                              ? j[@"error"] : RLPTr(@"移除失败");
                RLPToast(err);
                if (j) [s2 loadQueue];
                return;
            }
            RLPToast(RLPTr(@"已移除"));
            [s2 loadQueue];
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPQueueChangedNotification object:s2];
        }];
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
    __weak __typeof__(self) w = self;
    [[RLPCoreClient shared] postJSON:@"/api/clear" body:nil completion:^(NSDictionary * _Nullable j) {
        (void)j;
        __typeof__(self) s = w;
        if (!s) return;
        [s loadQueue];
        [[NSNotificationCenter defaultCenter] postNotificationName:RLPQueueChangedNotification object:s];
    }];
}

#pragma mark - 歌词

- (void)loadLyricsForCurrent:(BOOL)isRetry {
    if (![RLPCoreClient shared].started) return;
    NSString *file = [self currentTrackPath];
    if (!file.length) {
        self.lyricFile = nil;
        self.lyricRetry = 0;
        [self.lyricTimer invalidate]; self.lyricTimer = nil;
        self.lines = @[];
        self.activeLine = -1;
        self.originalLyricLines = nil;
        self.lyricAiApplied = NO;
        self.lyricAiBusy = NO;
        [self renderLyricMessageForKey:@"noTrack"];
        return;
    }
    if (!isRetry) {
        self.lyricFile = file; self.lyricRetry = 0;
        [self.lyricTimer invalidate]; self.lyricTimer = nil;
        self.lines = @[];
        self.activeLine = -1;
        self.originalLyricLines = nil;
        self.lyricAiApplied = NO;
        self.lyricAiBusy = NO;
        self.lHintKey = nil;
        self.lHintErr = nil;
        self.lHint.stringValue = @"";
        self.lHint.hidden = YES;
    }
    // lyricFile 必须在「无歌词」分支之前就记下：否则 loadQueue 的换曲检测会把它当成
    // 新曲，每秒重渲染一次空态（网络曲目就是这条路径）。
    if ([file hasPrefix:@"http://"] || [file hasPrefix:@"https://"]) {
        self.lines = @[];
        self.activeLine = -1;
        self.originalLyricLines = nil;
        self.lyricAiApplied = NO;
        self.lyricAiBusy = NO;
        [self renderLyricMessageForKey:@"net"];
        return;
    }
    __weak __typeof__(self) w = self;
    NSString *url = [@"/api/lyrics?file=" stringByAppendingString:RLPEnc(file)];
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable j) {
        __typeof__(self) s = w;
        if (!s) return;
        if (![s.lyricFile isEqualToString:file]) return;
        NSString *lrc = [j[@"lrc"] isKindOfClass:[NSString class]] ? j[@"lrc"] : @"";
        s.lines = [RLPLyrics parse:lrc];
        s.activeLine = -1;
        // 换歌/换词必须作废上一首的 AI 结果：否则会把上一首的译文贴到这一首（指纹失配）。
        s.originalLyricLines = nil;
        s.lyricAiApplied = NO;
        if (s.lines.count) { [s renderLyrics]; return; }
        // 空结果退避重试（web 1/2/3/5/8/13s，最多 6 次 ≈ 32s）：后台可能正在补全
        const NSInteger waits[] = {1, 2, 3, 5, 8, 13};
        if ([s.lyricFile isEqualToString:file] && s.lyricRetry < 6) {
            NSTimeInterval wait = waits[s.lyricRetry];
            s.lyricRetry++;
            [s renderLyricMessageForKey:@"loading"];
            [s.lyricTimer invalidate];
            s.lyricTimer = [NSTimer scheduledTimerWithTimeInterval:wait repeats:NO block:^(NSTimer *tm) {
                (void)tm;
                __typeof__(self) s2 = w;
                if (!s2) return;
                if ([s2.lyricFile isEqualToString:file]) [s2 loadLyricsForCurrent:YES];
            }];
            return;
        }
        [s renderLyricMessageForKey:@"none"];
    }];
}

- (void)renderLyricMessageForKey:(NSString *)key {
    self.lyricMsgKey = key;
    NSString *msg = @"";
    if ([key isEqualToString:@"noTrack"]) {
        msg = RLPTr(@"还没有播放曲目");
    } else if ([key isEqualToString:@"net"]) {
        msg = RLPTr(@"网络曲目暂无歌词");
    } else if ([key isEqualToString:@"loading"]) {
        msg = [RLPTr(@"歌词加载中…") stringByAppendingFormat:@"\n%@",
               RLPTr(@"正在等后台补全（首次播放新曲目时可能要几秒）")];
    } else {
        msg = [RLPTr(@"没有歌词") stringByAppendingFormat:@"\n%@",
               RLPTr(@"同名 .lrc 文件、内嵌歌词，或播放时自动在线补全")];
    }
    [self renderLyricMessage:msg];
}

- (void)renderLyricMessage:(NSString *)msg {
    for (NSView *v in [self.lStack.arrangedSubviews copy]) {
        [self.lStack removeArrangedSubview:v]; [v removeFromSuperview];
    }
    [self.lyricRows removeAllObjects];
    self.lHintKey = nil;
    self.lHintErr = nil;
    self.lHint.stringValue = @"";
    self.lHint.hidden = YES;
    NSTextField *l = RLPLabel(msg, [NSFont systemFontOfSize:12], [RLPTheme current].mut2);
    l.identifier = @"right.ly.none";
    l.maximumNumberOfLines = 4;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [self.lStack addArrangedSubview:l];
    [l.widthAnchor constraintEqualToAnchor:self.lStack.widthAnchor constant:-28].active = YES;
}

- (void)renderLyrics {
    self.lyricMsgKey = nil;
    for (NSView *v in [self.lStack.arrangedSubviews copy]) {
        [self.lStack removeArrangedSubview:v]; [v removeFromSuperview];
    }
    [self.lyricRows removeAllObjects];
    const BOOL timed = [RLPLyrics isTimed:self.lines];
    // 纯文本歌词给显式提示（web：否则"不滚"看起来像坏了）
    if (timed) {
        if ([self.lHintKey isEqualToString:@"untimed"] || !self.lHint.stringValue.length) {
            self.lHintKey = nil;
            self.lHintErr = nil;
            self.lHint.stringValue = @"";
            self.lHint.hidden = YES;
        } else {
            self.lHint.hidden = ![self.tab isEqualToString:@"l"];
        }
    } else {
        self.lHintKey = @"untimed";
        self.lHintErr = nil;
        self.lHint.stringValue = RLPTr(@"纯文本歌词（无时间轴）· 不会自动跟随滚动");
        self.lHint.hidden = ![self.tab isEqualToString:@"l"];
    }
    __weak __typeof__(self) w = self;
    for (RLPLyricLine *line in self.lines) {
        RLPDrawerLyricRow *row = [[RLPDrawerLyricRow alloc] initWithText:line.text timed:line.t];
        [row setContextMenu:[self lyricAiMenu]];   // 歌词区右键：AI 六项
        row.onSeek = ^(double t) {
            __typeof__(self) s = w;
            if (!s || s.dur <= 0) return;
            // 参数名必须是 pos（ui_script.h:6671 doSeek）：后端 /api/seek 只读 "?pos="，
            // 旧码发 ?ratio= ⟹ 找不到 pos ⟹ frac=0 ⟹ 每次点歌词都跳回曲首（不是"跳不准"）。
            // 上界钉 0.9999（web 同口径：pos=1.0 会让后端精确跳到文件末尾）。
            const double f = fmin(0.9999, fmax(0.0, t / s.dur));
            [[RLPCoreClient shared] postJSON:
                [NSString stringWithFormat:@"/api/seek?pos=%.4f", f]
                body:nil completion:nil];
        };
        [self.lyricRows addObject:row];
        [self.lStack addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.lStack.widthAnchor constant:-16].active = YES;
    }
}

#pragma mark - 歌词 AI（翻译 / 音译 / 日语假名 / 简转繁）

/// 歌词区右键菜单（六项）：翻译…（子菜单选目标语言）/ 音译 / 日语假名 / 转繁体 /
/// 恢复原文 / 复制歌词。移植上游 v3.3.11 的歌词右键菜单（"显示选项"归主题设置，这里只做 AI 类）。
///
/// 为什么翻译要选语言：后端 translate 必须有目标语言（空着只会让模型自己猜、白花钱），
/// 所以"翻译…"带省略号 + 子菜单，选了语言才发请求。
- (NSMenu *)lyricAiMenu {
    if (_lyricAiMenu) return _lyricAiMenu;
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"lyrics-ai"];
    m.autoenablesItems = NO;
    m.delegate = self;

    NSMenuItem *tr = [[NSMenuItem alloc] initWithTitle:RLPTr(@"翻译…") action:nil keyEquivalent:@""];
    NSMenu *langs = [[NSMenu alloc] initWithTitle:@"lyrics-ai-lang"];
    // 语言标签写成字面量（不是拼接变量）：原生 i18n 覆盖检查只认 RLPTr(@"…") 字面量。
    NSArray<NSArray<NSString *> *> *pairs = @[
        @[ @"zh", RLPTr(@"中文") ], @[ @"en", RLPTr(@"英文") ],
        @[ @"ja", RLPTr(@"日语") ], @[ @"ko", RLPTr(@"韩语") ],
        @[ @"fr", RLPTr(@"法语") ], @[ @"de", RLPTr(@"德语") ],
        @[ @"ru", RLPTr(@"俄语") ], @[ @"es", RLPTr(@"西班牙语") ],
    ];
    for (NSArray<NSString *> *p in pairs) {
        NSMenuItem *it = [self lyricAiItem:p[1] action:@selector(lyricAiTranslateLang:)];
        it.representedObject = p[0];
        [langs addItem:it];
    }
    tr.submenu = langs;
    [m addItem:tr];

    [m addItem:[self lyricAiItem:RLPTr(@"音译") action:@selector(lyricAiTransliterate:)]];
    [m addItem:[self lyricAiItem:RLPTr(@"日语假名") action:@selector(lyricAiFurigana:)]];
    [m addItem:[self lyricAiItem:RLPTr(@"转繁体") action:@selector(lyricAiTradChinese:)]];

    [m addItem:[NSMenuItem separatorItem]];

    NSMenuItem *restore = [[NSMenuItem alloc] initWithTitle:RLPTr(@"恢复原文")
                                                     action:@selector(lyricRestoreOriginal:)
                                              keyEquivalent:@""];
    restore.target = self;
    [m addItem:restore];

    NSMenuItem *copy = [[NSMenuItem alloc] initWithTitle:RLPTr(@"复制歌词")
                                                  action:@selector(lyricCopyAll:)
                                           keyEquivalent:@""];
    copy.target = self;
    [m addItem:copy];

    _lyricAiMenu = m;
    return m;
}

/// 统一构造菜单项（target 一律是本抽屉）。
- (NSMenuItem *)lyricAiItem:(NSString *)title action:(SEL)sel {
    NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:(title ?: @"") action:sel keyEquivalent:@""];
    it.target = self;
    return it;
}

/// 菜单打开时按当前状态启停：没歌词 ⟹ AI 类与复制都禁用；没应用过 AI ⟹ "恢复原文"禁用。
/// 不这样做的话，用户点了没反应（web 那边踩过"点了像没反应"的同类问题）。
- (void)menuWillOpen:(NSMenu *)menu {
    const BOOL has = self.lines.count > 0;
    for (NSMenuItem *it in menu.itemArray) {
        if (it.isSeparatorItem) continue;
        if (it.action == @selector(lyricRestoreOriginal:)) it.enabled = self.lyricAiApplied;
        else it.enabled = has;
    }
}

- (void)showLyricHint:(NSString *)msg {
    self.lHint.hidden = NO;
    self.lHint.stringValue = msg ?: @"";
}

- (void)showLyricHintKey:(NSString *)key err:(nullable NSString *)err text:(NSString *)msg {
    self.lHintKey = key;
    self.lHintErr = err;
    [self showLyricHint:msg];
}

- (void)lyricAiTranslateLang:(NSMenuItem *)item {
    NSString *code = [item.representedObject isKindOfClass:[NSString class]] ? (NSString *)item.representedObject : @"zh";
    [self runLyricAiTask:@"translate" lang:code];
}
- (void)lyricAiTransliterate:(id)sender { [self runLyricAiTask:@"translit" lang:nil]; }
- (void)lyricAiFurigana:(id)sender      { [self runLyricAiTask:@"furigana" lang:nil]; }
- (void)lyricAiTradChinese:(id)sender    { [self runLyricAiTask:@"trad" lang:nil]; }

/// 发请求 → 按行贴回。
///
/// 关键约束（与后端同一套）：行由 UI 发给后端（lines，时间轴留在 UI），回来按**行数**贴回；
/// 后端已按 20/14 行切块 + 磁盘缓存，同一首歌第二次是秒出（fromCache）。
/// 这里不重试：AI 调用按次计费，失败就失败，用户再点一次才有意义。
- (void)runLyricAiTask:(NSString *)task lang:(NSString *)lang {
    if (self.lyricAiBusy) return;
    if (![RLPCoreClient shared].started) { [self showLyricHintKey:@"nostart" err:nil text:RLPTr(@"核心未启动，稍后再试")]; return; }
    // 已应用过 AI 时以"原文"为基准再处理（否则会在译文上再翻一遍，越翻越偏）。
    NSArray<RLPLyricLine *> *base = self.lyricAiApplied ? self.originalLyricLines : self.lines;
    if (!base.count) { [self showLyricHintKey:@"nolyrics" err:nil text:RLPTr(@"这首曲目没有歌词")]; return; }

    NSMutableArray<NSString *> *texts = [NSMutableArray arrayWithCapacity:base.count];
    for (RLPLyricLine *l in base) [texts addObject:(l.text ?: @"")];
    NSString *body = [RLPLyrics aiRequestBodyTask:task lang:lang sourceLang:nil lines:texts];

    NSString *reqFile = [self.lyricFile copy];
    self.lyricAiBusy = YES;
    const BOOL isTr = [task isEqualToString:@"translate"];
    [self showLyricHintKey:(isTr ? @"busy_tr" : @"busy_ai") err:nil text:(isTr ? RLPTr(@"正在翻译歌词…") : RLPTr(@"正在处理歌词…"))];
    __weak __typeof__(self) w = self;
    [[RLPCoreClient shared] postJSON:@"/api/lyrics/ai" body:body completion:^(NSDictionary * _Nullable j) {
        __typeof__(self) s = w;
        if (!s) return;
        if (!reqFile.length || ![s.lyricFile isEqualToString:reqFile]) return;
        s.lyricAiBusy = NO;
        NSString *err = nil;
        NSArray<RLPLyricLine *> *applied = [RLPLyrics linesFromAiResponse:j appliedTo:base error:&err];
        if (!applied) {
            [s showLyricHintKey:@"fail" err:err text:[RLPTr(@"歌词处理失败") stringByAppendingFormat:@"：%@", (err ?: RLPTr(@"未知错误"))]];
            return;
        }
        if (!s.lyricAiApplied) { s.originalLyricLines = base; s.lyricAiApplied = YES; }
        s.lines = applied;
        s.activeLine = -1;
        [s renderLyrics];   // 时间戳没变 ⟹ 高亮/滚动/点行跳转全部照旧
        [s updatePosition:s.lastPos duration:s.dur];
        const BOOL cached = [j[@"fromCache"] respondsToSelector:@selector(boolValue)] && [j[@"fromCache"] boolValue];
        [s showLyricHintKey:(cached ? @"cached" : @"done") err:nil text:(cached ? RLPTr(@"已载入（缓存）") : RLPTr(@"完成"))];
    }];
}

- (void)lyricRestoreOriginal:(id)sender {
    if (!self.lyricAiApplied || !self.originalLyricLines.count) return;
    self.lines = self.originalLyricLines;
    self.originalLyricLines = nil;
    self.lyricAiApplied = NO;
    self.activeLine = -1;
    [self renderLyrics];
    [self updatePosition:self.lastPos duration:self.dur];
    [self showLyricHintKey:@"restored" err:nil text:RLPTr(@"已恢复原文")];
}

- (void)lyricCopyAll:(id)sender {
    if (!self.lines.count) return;
    NSMutableArray<NSString *> *rows = [NSMutableArray arrayWithCapacity:self.lines.count];
    for (RLPLyricLine *l in self.lines) [rows addObject:(l.text ?: @"")];
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:[rows componentsJoinedByString:@"\n"] forType:NSPasteboardTypeString];
    [self showLyricHintKey:@"copied" err:nil text:RLPTr(@"歌词已复制")];
}

- (void)updatePosition:(double)pos duration:(double)dur {
    self.lastPos = pos;
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
    if (self.lines.count) {
        const NSInteger prevActive = self.activeLine;
        [self renderLyrics];
        if (prevActive >= 0 && prevActive < (NSInteger)self.lyricRows.count) {
            self.activeLine = prevActive;
            self.lyricRows[(NSUInteger)prevActive].active = YES;
        }
    } else {
        for (NSView *v in self.lStack.arrangedSubviews) {
            if ([v isKindOfClass:[NSTextField class]] && [v.identifier isEqualToString:@"right.ly.none"]) {
                ((NSTextField *)v).textColor = t.mut2;
            }
        }
    }
}

- (void)applyLanguage {
    [self.qTab setTitle:RLPTr(@"队列")];
    [self.lTab setTitle:RLPTr(@"歌词")];
    [self.clearBtn setTitle:RLPTr(@"清除")];
    [self refreshTabs];
    _lyricAiMenu = nil;
    NSMenu *menu = [self lyricAiMenu];
    self.lStack.menu = menu;
    self.lScroll.menu = menu;
    for (RLPDrawerLyricRow *row in self.lyricRows) {
        [row setContextMenu:menu];
    }
    self.count.stringValue = [NSString stringWithFormat:RLPTr(@"共 %lu 首"), (unsigned long)self.items.count];
    if (!self.items.count) [self renderQueue];
    if (!self.lines.count) {
        if (self.lyricMsgKey.length) {
            [self renderLyricMessageForKey:self.lyricMsgKey];
        } else if ([RLPCoreClient shared].started && [self.tab isEqualToString:@"l"]) {
            [self loadLyricsForCurrent:NO];
        } else {
            NSString *file = [self currentTrackPath];
            if (!file.length) {
                [self renderLyricMessageForKey:@"noTrack"];
            } else if ([file hasPrefix:@"http://"] || [file hasPrefix:@"https://"]) {
                [self renderLyricMessageForKey:@"net"];
            } else {
                [self renderLyricMessageForKey:@"none"];
            }
        }
    } else if ([self.lHintKey isEqualToString:@"busy_tr"]) {
        self.lHint.stringValue = RLPTr(@"正在翻译歌词…");
    } else if ([self.lHintKey isEqualToString:@"busy_ai"]) {
        self.lHint.stringValue = RLPTr(@"正在处理歌词…");
    } else if ([self.lHintKey isEqualToString:@"nostart"]) {
        self.lHint.stringValue = RLPTr(@"核心未启动，稍后再试");
    } else if ([self.lHintKey isEqualToString:@"nolyrics"]) {
        self.lHint.stringValue = RLPTr(@"这首曲目没有歌词");
    } else if ([self.lHintKey isEqualToString:@"cached"]) {
        self.lHint.stringValue = RLPTr(@"已载入（缓存）");
    } else if ([self.lHintKey isEqualToString:@"done"]) {
        self.lHint.stringValue = RLPTr(@"完成");
    } else if ([self.lHintKey isEqualToString:@"restored"]) {
        self.lHint.stringValue = RLPTr(@"已恢复原文");
    } else if ([self.lHintKey isEqualToString:@"copied"]) {
        self.lHint.stringValue = RLPTr(@"歌词已复制");
    } else if ([self.lHintKey isEqualToString:@"fail"]) {
        self.lHint.stringValue = [RLPTr(@"歌词处理失败") stringByAppendingFormat:@"：%@", (self.lHintErr ?: RLPTr(@"未知错误"))];
    } else if (self.lHint.stringValue.length && ![RLPLyrics isTimed:self.lines]) {
        self.lHint.stringValue = RLPTr(@"纯文本歌词（无时间轴）· 不会自动跟随滚动");
    }
}

@end
