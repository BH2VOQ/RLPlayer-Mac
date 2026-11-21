// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPArtistDetailViewController.mm — 艺术家详情实现（纯 AppKit）
//
// ================================= 排版口径 =================================
// 用户 2026-11-21 实测：「艺术家资料页设计不合格，排版混乱，不够简洁。主要是资料部分，
// 甚至不如 web 版，要做到图二的那个效果。」
//
// 旧实现把资料区整个塞成播放页右侧那个 RLPKnowledgeView 抽屉（自带标题/复制/重新整理/
// 滚动条）并钉死 215pt 高 ⟹ 全页只有一个抽屉、没有卡片层次。本文件按 web 的
// openArtistProfile（src/net/ui_script.h:2800-3060 + src/net/ui_page.h:333-352）重做，
// 自上而下：
//
//   ① 返回按钮行        ‹ 返回艺术家列表
//   ② Hero 行           圆形头像 168×168 | eyebrow / 26pt 大标题 / 副标题 / 三个按钮
//   ③ 卡片「AI 整理」   sec-title + 字段网格 + 引用芯片行 + 脚注   ← 本页主内容
//   ④ 卡片「简介」      sec-title + 正文（长文默认折叠 4 行 + 展开全部/收起简介）
//   ⑤ 卡片「风格与相似」有 genre/similar 材料才渲染
//   ⑥ 卡片「资料来源」  每行：来源徽章 + 标题 + 取回于日期 + 复制链接/复制
//   ⑦ 专辑网格          NSCollectionView（保持原行为：单击进入专辑）
//
// 为什么字段网格不复用 RLPFieldGrid（tools/native_ui/RLPSettingsLayout.h）：
// 本文件被 6 个 CMake 目标编译，其中 test_native_artist_profile **没有**链接
// RLPSettingsLayout.mm；一旦引用该类，那条判据直接链接失败。这里自带一份同算法的
// 响应式网格（列数 = floor((可用宽+列距)/(列下限+列距))，即 CSS
// `repeat(auto-fill,minmax(260px,1fr))` 的等价式），见 RLPArtistFieldGrid。
//
// 布局全部走**手工 frame 计算**（同 RLPKnowledgeView 的 relayoutAll）：本页是
// 「滚动文档 + 多层等宽卡片 + 多行文本」，用 Auto Layout 嵌套约束容易在宽度变化时
// 出现约束打架（设置页当年就被压成 0 高过）。手工布局只有一个入口，宽度变了重排一次即可。
//
// 数据契约（不改后端）：
//   GET /api/entity/knowledge?kind=person&name=…[&refresh=1]
//   GET /api/entity/summary?kind=person&name=…&lang=zh[&refresh=1]
// 两者各自独立异步填充：骨架 + hero + 专辑网格先出来，加载文案只出现在卡片内。
#import "RLPArtistDetailViewController.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

static const NSUserInterfaceItemIdentifier kArtistAlbumItemID = @"RLPArtistAlbumItem";

#pragma mark - 排版常量（逐个对齐 web src/net/ui_page.h）

static const CGFloat kArtistPagePadX   = 22.0;   // .artist-body padding:0 22px 30px
static const CGFloat kArtistCardPadX   = 18.0;   // .sec-card padding:14px 18px
static const CGFloat kArtistCardPadY   = 14.0;
static const CGFloat kArtistCardGap    = 20.0;   // 卡片之间
static const CGFloat kArtistAvatarSide = 168.0;  // .ahead .cv 168×168
// web .efields{grid-template-columns:repeat(auto-fill,minmax(178px,1fr))}
// —— 是 178，不是 260。写成 260 会让宽窗口只肯开两列、每列 700pt，
// 而字段值多是「摇滚」「日本」这种短词，文字后面拖出一大片空白，
// 看上去就是"排版乱"（用户 2026-11-21 截图反馈的实际观感）。
static const CGFloat kArtistFieldMinW  = 178.0;  // .efields minmax(178px,1fr)
static const CGFloat kArtistFieldColGap = 22.0;  // .efields gap:13px 22px
static const CGFloat kArtistFieldRowGap = 13.0;

#pragma mark - 小工具

/// 翻转容器：滚动区 documentView 必须是翻转坐标，内容才会从顶部开始排。
@interface RLPArtistFlippedView : NSView
@end
@implementation RLPArtistFlippedView
- (BOOL)isFlipped { return YES; }
@end

static NSMutableParagraphStyle *RLPArtistPara(CGFloat lineSpacing) {
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.lineBreakMode = NSLineBreakByWordWrapping;
    ps.lineSpacing = MAX(0.0, lineSpacing);
    return ps;
}

static NSDictionary *RLPArtistAttrs(NSFont *font, NSColor *color, CGFloat kern, CGFloat lineSpacing) {
    NSMutableDictionary *a = [NSMutableDictionary dictionary];
    if (font) a[NSFontAttributeName] = font;
    if (color) a[NSForegroundColorAttributeName] = color;
    a[NSParagraphStyleAttributeName] = RLPArtistPara(lineSpacing);
    if (fabs(kern) > 0.001) a[NSKernAttributeName] = @(kern);
    return a;
}

static NSAttributedString *RLPArtistAttr(NSString *s, NSFont *font, NSColor *color,
                                         CGFloat kern, CGFloat lineSpacing) {
    return [[NSAttributedString alloc] initWithString:s ?: @""
                                           attributes:RLPArtistAttrs(font, color, kern, lineSpacing)];
}

/// 多行文本高度（与显示侧同一套 attributes 量，量出来才会和排出来一致）。
static CGFloat RLPArtistTextH(NSString *s, NSFont *font, CGFloat width, CGFloat lineSpacing) {
    if (!s.length || !font || width < 1.0) return 0.0;
    NSRect br = [s boundingRectWithSize:NSMakeSize(width, CGFLOAT_MAX)
                                options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                             attributes:RLPArtistAttrs(font, nil, 0, lineSpacing)];
    return ceil(br.size.height);
}

/// unix 秒 → 本地时区 `2026-11-09`（web fmtDate 同口径）。
static NSString *RLPArtistFmtDate(id raw) {
    double secs = 0;
    if ([raw respondsToSelector:@selector(doubleValue)]) secs = [raw doubleValue];
    if (!(secs > 0) || !isfinite(secs)) return @"";
    static NSDateFormatter *df = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [[NSDateFormatter alloc] init];
        df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        df.dateFormat = @"yyyy-MM-dd";
        df.timeZone = [NSTimeZone localTimeZone];
    });
    return [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:secs]] ?: @"";
}

/// fields 的值可能是字符串/数字/数组；空值一律返回 @""（空值 = 后端不知道 ⟹ 不渲染）。
static NSString *RLPArtistFieldText(id v) {
    if (v == nil || (id)v == (id)[NSNull null]) return @"";
    if ([v isKindOfClass:[NSString class]]) {
        return [(NSString *)v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
    if ([v isKindOfClass:[NSArray class]]) {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (id o in (NSArray *)v) {
            NSString *s = RLPArtistFieldText(o);
            if (s.length) [parts addObject:s];
        }
        return [parts componentsJoinedByString:@"\n"];
    }
    return [v description] ?: @"";
}

/// 来源徽章名（web renderArtistProfile 的同一条映射；认不出就原样显示 source）。
static NSString *RLPArtistSourceBadge(NSString *source) {
    NSString *s = [(source ?: @"") lowercaseString];
    if ([s containsString:@"wikipedia"]) return RLPTr(@"维基百科");
    if ([s containsString:@"moegirl"]) return RLPTr(@"萌娘百科");
    if ([s containsString:@"discogs"]) return @"Discogs";
    if ([s containsString:@"lastfm"] || [s containsString:@"last.fm"]) return @"Last.fm";
    return source ?: @"";
}

/// web EF_ORDER.person（src/net/ui_script.h:1935）——字段的固定渲染顺序。
static NSArray<NSString *> *RLPArtistPersonOrder(void) {
    static NSArray<NSString *> *o = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ o = @[ @"简介", @"国籍", @"活跃年代", @"风格", @"代表作品", @"厂牌", @"合作" ]; });
    return o;
}

/// web EF_WIDE（src/net/ui_script.h:1941）——一定独占整行的长文本标签。
static BOOL RLPArtistIsWideLabel(NSString *label) {
    static NSSet<NSString *> *w = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        w = [NSSet setWithArray:@[ @"简介", @"专辑介绍", @"曲目列表", @"制作人员",
                                   @"歌词赏析", @"关联", @"衍生作品", @"版本说明" ]];
    });
    return [w containsObject:(label ?: @"")];
}

static NSTextField *RLPArtistMakeLabel(NSString *ident) {
    NSTextField *l = [NSTextField labelWithString:@""];
    l.identifier = ident;
    l.alignment = NSTextAlignmentLeft;
    l.drawsBackground = NO;
    l.bordered = NO;
    l.editable = NO;
    l.selectable = YES;
    l.translatesAutoresizingMaskIntoConstraints = YES;
    l.autoresizingMask = NSViewNotSizable;
    return l;
}

static void RLPArtistStyleWrap(NSTextField *tf) {
    tf.lineBreakMode = NSLineBreakByWordWrapping;
    tf.maximumNumberOfLines = 0;
    tf.usesSingleLineMode = NO;
    if ([tf.cell isKindOfClass:[NSTextFieldCell class]]) {
        NSTextFieldCell *c = (NSTextFieldCell *)tf.cell;
        c.wraps = YES;
        c.scrollable = NO;
        c.usesSingleLineMode = NO;
    }
}

/// web `.btn` / `.cite-chip` 的底座：一个自绘圆角描边的无边框按钮。
@interface RLPArtistChip : NSButton
@property (nonatomic, assign) BOOL filled;      // YES = background:var(--hov)（web .btn）
@property (nonatomic, assign) CGFloat radius;   // 默认 rSm
/// 用纯文本设置标题（同时写 title 与 attributedTitle）。
/// 为什么必须同时写：排版本与 RLPArtistChipW 都按 `title` 量宽、NSButton 绘制按
/// `attributedTitle`。只设 attributedTitle 会得到「空框 + 最小宽度」——
/// 2026-11-21 离屏截图实测：三个 hero 按钮成了三个空白胶囊，
/// 来源行「复制链接 / 复制」芯片与整行徽章也一起塌掉/被撑满。
- (void)setText:(NSString *)text color:(NSColor *)color font:(NSFont *)font;
@end

@implementation RLPArtistChip
- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.bordered = NO;
        self.bezelStyle = NSBezelStyleRegularSquare;
        self.wantsLayer = NO;
        self.radius = 8.0;
    }
    return self;
}

- (void)setText:(NSString *)text color:(NSColor *)color font:(NSFont *)font {
    NSString *s = text ?: @"";
    NSFont *f = font ?: [NSFont systemFontOfSize:12];
    self.font = f;
    self.title = s;                       // 量宽来源
    self.attributedTitle = RLPArtistAttr(s, f, color ?: [RLPTheme current].text, 0, 0);  // 绘制来源
}
- (void)drawRect:(NSRect)dirtyRect {
    RLPTheme *t = [RLPTheme current];
    // 先画背景与边框，再让 NSButton **自己画标题**。
    //
    // 为什么不能只画圆角框就返回：NSButton 的标题由它自己的 cell 绘制，
    // 覆盖 drawRect 而不调 super 就等于把文字整个抹掉 —— 画面上只剩空药丸。
    // （2026-11-21 离屏截图实测：hero 三个按钮与来源行的复制芯片全是空框，
    //  而 title/attributedTitle 都有值。判据只量几何，抓不到"字没画出来"。）
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5)
                                                      xRadius:self.radius yRadius:self.radius];
    if (self.filled) { [t.hov setFill]; [p fill]; }
    [t.line setStroke];
    p.lineWidth = 1.0;
    [p stroke];
    [super drawRect:dirtyRect];   // ← 标题由 cell 画
}
@end

/// 芯片推荐宽度：文字宽 + 左右 9pt。
static CGFloat RLPArtistChipW(NSString *title, NSFont *font) {
    CGFloat w = ceil([(title ?: @"") sizeWithAttributes:@{ NSFontAttributeName: font ?: [NSFont systemFontOfSize:12] }].width);
    return MAX(32.0, w + 20.0);
}

#pragma mark - 字段行（web .efrow：标签在上、值在下）

@interface RLPArtistFieldRow : NSView
@property (nonatomic, strong) NSTextField *label;
@property (nonatomic, strong) NSTextField *value;
@property (nonatomic, copy) NSString *fieldName;
@property (nonatomic, assign) BOOL wide;
/// 以给定宽度排好自己两个子标签，返回本行高度。
- (CGFloat)layoutWidth:(CGFloat)width;
- (instancetype)initWithFieldName:(NSString *)name value:(NSString *)value;
@end

@implementation RLPArtistFieldRow

- (BOOL)isFlipped { return YES; }

- (instancetype)initWithFieldName:(NSString *)name value:(NSString *)value {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        RLPTheme *t = [RLPTheme current];
        _fieldName = [name copy] ?: @"";
        // web .efrow .lb{font-size:10px;letter-spacing:.8px;color:var(--mut2);font-weight:600}
        _label = RLPArtistMakeLabel(@"efrow.label");
        _label.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
        _label.textColor = t.mut2;
        _label.lineBreakMode = NSLineBreakByTruncatingTail;
        _label.maximumNumberOfLines = 1;
        _label.attributedStringValue = RLPArtistAttr(_fieldName,
            [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold], t.mut2, 0.8, 0);
        [self addSubview:_label];

        // web .efrow .vl{font-size:12.5px;line-height:1.72;color:var(--txt)}
        _value = RLPArtistMakeLabel(@"efrow.value");
        _value.font = [NSFont systemFontOfSize:12.5];
        _value.textColor = t.text;
        RLPArtistStyleWrap(_value);
        _value.attributedStringValue = RLPArtistAttr(value, [NSFont systemFontOfSize:12.5], t.text, 0, 6.0);
        [self addSubview:_value];
    }
    return self;
}

- (CGFloat)layoutWidth:(CGFloat)width {
    const CGFloat w = MAX(1.0, width);
    const CGFloat labelH = 13.0;   // 10px × 1.3
    const CGFloat gap = 3.0;       // web margin-bottom:3px
    const CGFloat valueH = MAX(16.0, RLPArtistTextH(self.value.stringValue, self.value.font, w, 6.0));
    self.label.frame = NSMakeRect(0, 0, w, labelH);
    self.value.frame = NSMakeRect(0, labelH + gap, w, valueH);
    const CGFloat h = ceil(labelH + gap + valueH);
    self.frame = NSMakeRect(self.frame.origin.x, self.frame.origin.y, w, h);
    return h;
}

@end

#pragma mark - 响应式字段网格（web .efields）

/// 列数 = floor((可用宽 + 列距) / (列下限 + 列距))，至少 1 列。
/// 宽窗口两列、窄窗口一列，永不横向溢出。
@interface RLPArtistFieldGrid : NSView
@property (nonatomic, readonly) NSInteger columnCount;
- (void)addItem:(RLPArtistFieldRow *)item wide:(BOOL)wide;
- (void)removeAllItems;
/// 按给定宽度摆好全部字段并把自身 frame 高度定好，返回内容高度。
- (CGFloat)layoutWidth:(CGFloat)width;
@end

@implementation RLPArtistFieldGrid {
    NSMutableArray<RLPArtistFieldRow *> *_items;
    NSMutableArray<NSNumber *> *_wides;
}

- (BOOL)isFlipped { return YES; }

- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    if (self) {
        _items = [NSMutableArray array];
        _wides = [NSMutableArray array];
        _columnCount = 1;
        self.autoresizingMask = NSViewNotSizable;
    }
    return self;
}

- (void)addItem:(RLPArtistFieldRow *)item wide:(BOOL)wide {
    if (!item) return;
    [_items addObject:item];
    [_wides addObject:@(wide)];
    [self addSubview:item];
}

- (void)removeAllItems {
    for (RLPArtistFieldRow *v in _items) [v removeFromSuperview];
    [_items removeAllObjects];
    [_wides removeAllObjects];
    _columnCount = 1;
}

- (CGFloat)layoutWidth:(CGFloat)width {
    const CGFloat w = MAX(1.0, width);
    const CGFloat colGap = kArtistFieldColGap;
    const CGFloat rowGap = kArtistFieldRowGap;
    // 与 web 的 `repeat(auto-fill, minmax(178px, 1fr))` 同口径：
    // 列数 = 能塞下多少个「不小于 178pt 的等宽列」，而不是写死两列。
    // 宽窗口因此自然变成 3–4 列，短字段不再拖出一大片空白。
    NSInteger cols = (NSInteger)floor((w + colGap) / (kArtistFieldMinW + colGap));
    cols = MAX(1, MIN(cols, 6));                 // 上限 6 列，避免超宽屏把字段挤成一条缝
    _columnCount = cols;
    const CGFloat colW = MAX(1.0, (w - colGap * (CGFloat)(cols - 1)) / (CGFloat)MAX(1, cols));

    CGFloat y = 0.0, rowH = 0.0;
    NSInteger col = 0;
    BOOL placed = NO;
    for (NSUInteger i = 0; i < _items.count; ++i) {
        RLPArtistFieldRow *row = _items[i];
        if (row.hidden) continue;
        const BOOL wide = _wides[i].boolValue;
        const BOOL full = wide || cols <= 1;
        if (wide && col > 0) { y += rowH + rowGap; col = 0; rowH = 0.0; }
        const CGFloat itemW = full ? w : colW;
        const CGFloat x = (CGFloat)col * (colW + colGap);
        row.frame = NSMakeRect(x, y, itemW, row.frame.size.height);
        const CGFloat h = [row layoutWidth:itemW];
        rowH = MAX(rowH, h);
        placed = YES;
        if (full) { y += rowH + rowGap; col = 0; rowH = 0.0; }
        else if (++col >= cols) { y += rowH + rowGap; col = 0; rowH = 0.0; }
    }
    if (col > 0) y += rowH + rowGap;
    const CGFloat height = placed ? MAX(1.0, y - rowGap) : 0.0;
    self.frame = NSMakeRect(self.frame.origin.x, self.frame.origin.y, w, MAX(1.0, height));
    return height;
}

@end

#pragma mark - 专辑卡片（168x214）

/// 资料来源的一行（web `.trow.source-row`）：整行 hov 底 + 左侧「来源徽章」药丸。
///
/// 药丸底必须由**行视图**在文字之前画，不能挂在徽章 label 的 layer 上：
/// NSTextField 的 layer.backgroundColor 会把 cell 随后画的文字盖掉，
/// 画面上只剩一条粉色色块（2026-11-21 离屏截图实测到的真实缺陷）。
@interface RLPArtistSourceRow : RLPArtistFlippedView
/// 徽章药丸底（真实子视图，一直在文字 label 之下）。
@property (nonatomic, strong, readonly) NSView *badgePill;
@end

@implementation RLPArtistSourceRow
- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _badgePill = [[NSView alloc] initWithFrame:NSZeroRect];
        _badgePill.wantsLayer = YES;
        _badgePill.layer.cornerRadius = 5.0;
        _badgePill.layer.backgroundColor = [RLPTheme current].accentWeak.CGColor;
        // 药丸必须先于文字加进来（同层级按 subviews 顺序绘制，后加的在上面）。
        [self addSubview:_badgePill];
    }
    return self;
}
@end

@interface RLPArtistAlbumItem : NSCollectionViewItem
@property (nonatomic, strong) NSImageView *coverView;
@property (nonatomic, strong) NSTextField *placeholderLabel;
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSTextField *yearLabel;
@property (nonatomic, copy) NSString *albumKey;
- (void)setAlbum:(RLPAlbum *)album;
@end

@implementation RLPArtistAlbumItem

- (void)loadView {
    RLPTheme *t = [RLPTheme current];
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 168, 214)];
    v.wantsLayer = YES;
    self.view = v;

    _coverView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _coverView.wantsLayer = YES;
    _coverView.layer.cornerRadius = 8;
    _coverView.layer.masksToBounds = YES;
    _coverView.layer.backgroundColor = t.bg2.CGColor;
    _coverView.imageScaling = NSImageScaleProportionallyUpOrDown;
    _coverView.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_coverView];

    _placeholderLabel = [NSTextField labelWithString:@"♪"];
    _placeholderLabel.font = [NSFont systemFontOfSize:30 weight:NSFontWeightLight];
    _placeholderLabel.textColor = t.mut;
    _placeholderLabel.alignment = NSTextAlignmentCenter;
    _placeholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_placeholderLabel];

    _nameLabel = [NSTextField labelWithString:@""];
    _nameLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    _nameLabel.textColor = t.text;
    _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _nameLabel.maximumNumberOfLines = 1;
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_nameLabel];

    _yearLabel = [NSTextField labelWithString:@""];
    _yearLabel.font = [NSFont systemFontOfSize:11.5];
    _yearLabel.textColor = t.mut;
    _yearLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _yearLabel.maximumNumberOfLines = 1;
    _yearLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_yearLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_coverView.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [_coverView.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [_coverView.topAnchor constraintEqualToAnchor:v.topAnchor],
        [_coverView.heightAnchor constraintEqualToConstant:168],

        [_placeholderLabel.centerXAnchor constraintEqualToAnchor:_coverView.centerXAnchor],
        [_placeholderLabel.centerYAnchor constraintEqualToAnchor:_coverView.centerYAnchor],

        [_nameLabel.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:2],
        [_nameLabel.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-2],
        [_nameLabel.topAnchor constraintEqualToAnchor:_coverView.bottomAnchor constant:8],

        [_yearLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_yearLabel.trailingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor],
        [_yearLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],
    ]];
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    RLPTheme *t = [RLPTheme current];
    if (selected) {
        self.view.layer.backgroundColor = [t.accent colorWithAlphaComponent:0.15].CGColor;
        self.view.layer.cornerRadius = 8;
    } else {
        self.view.layer.backgroundColor = NSColor.clearColor.CGColor;
    }
}

- (void)setAlbum:(RLPAlbum *)album {
    RLPTheme *t = [RLPTheme current];
    self.albumKey = album.key ?: @"";
    self.nameLabel.stringValue = album.name.length ? album.name : RLPTr(@"未知专辑");
    self.yearLabel.stringValue = album.year > 0 ? [NSString stringWithFormat:@"%ld", (long)album.year] : @"—";
    self.coverView.layer.backgroundColor = t.bg2.CGColor;

    if (album.key.length == 0) {
        self.coverView.image = nil;
        self.placeholderLabel.hidden = NO;
        return;
    }

    NSImage *cached = [[RLPCoverLoader shared] cachedCoverForAlbumKey:album.key];
    if (cached) {
        self.coverView.image = cached;
        self.placeholderLabel.hidden = YES;
    } else {
        self.coverView.image = nil;
        self.placeholderLabel.hidden = NO;
        if (album.hasCover) {
            NSString *expectedKey = album.key;
            __weak __typeof__(self) weakSelf = self;
            [[RLPCoverLoader shared] coverForAlbumKey:album.key completion:^(NSImage * _Nullable img) {
                __typeof__(self) self_ = weakSelf;
                if (!self_) return;
                if ([self_.albumKey isEqualToString:expectedKey]) {
                    if (img) {
                        self_.coverView.image = img;
                        self_.placeholderLabel.hidden = YES;
                    } else {
                        self_.coverView.image = nil;
                        self_.placeholderLabel.hidden = NO;
                    }
                }
            }];
        }
    }
}

@end
#pragma mark - 艺术家详情控制器

@interface RLPArtistDetailViewController () <NSCollectionViewDataSource, NSCollectionViewDelegate>

@property (nonatomic, copy, readwrite) NSString *artistName;
@property (nonatomic, readwrite) NSInteger albumCount;
@property (nonatomic, readwrite) NSInteger totalTracks;
@property (nonatomic, readwrite) double totalDuration;
@property (nonatomic) BOOL loaded;

// —— 头部（保留旧私有名：test_native_pages_fixes 的 (PagesFixesAudit) 直接取这些）——
@property (nonatomic, strong) NSView *avatarView;
@property (nonatomic, strong) NSImageView *avatarImage;
@property (nonatomic, assign) NSUInteger avatarSeq;
@property (nonatomic, assign) NSUInteger avatarFallbackSeq;
@property (nonatomic, assign) BOOL avatarArtistImageFailed;
@property (nonatomic, assign) BOOL avatarLoadedFromArtistImage;
@property (nonatomic, strong) NSTextField *initialLabel;
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSTextField *statsLabel;      // 保留（点击「查看专辑」时的专辑计数行）
@property (nonatomic, strong) NSTextField *emptyLabel;
@property (nonatomic, strong) NSButton *backBtn;            // 保留（顶栏返回按钮）
@property (nonatomic, strong) NSCollectionView *collection;
@property (nonatomic, strong) NSMutableArray<RLPAlbum *> *albums;

// —— 新排版 ——
@property (nonatomic, strong) NSScrollView *pageScroll;
@property (nonatomic, strong) NSView *doc;
@property (nonatomic, strong) NSTextField *eyebrowLabel;
@property (nonatomic, strong) NSTextField *subLabel;         // 缓存/资料 · 日期 取回
@property (nonatomic, strong) NSButton *btnAlbums;
@property (nonatomic, strong) NSButton *btnRefresh;
@property (nonatomic, strong) NSButton *btnBackList;

@property (nonatomic, strong) NSView *cardSummary;
@property (nonatomic, strong) NSTextField *summaryTitle;
@property (nonatomic, strong) RLPArtistFieldGrid *summaryGrid;
@property (nonatomic, strong) NSTextField *summaryStatus;    // 正在获取资料… / 失败行 / 暂无资料
@property (nonatomic, strong) NSButton *summaryRetry;        // 重试获取（仅空态）
@property (nonatomic, strong) NSMutableArray<NSView *> *citeChips;
@property (nonatomic, strong) NSTextField *summaryFoot;

@property (nonatomic, strong) NSView *cardBio;
@property (nonatomic, strong) NSTextField *bioTitle;
@property (nonatomic, strong) NSTextField *bioText;
@property (nonatomic, strong) NSButton *bioToggle;
@property (nonatomic, strong) NSView *cardStyles;
@property (nonatomic, strong) NSMutableArray<NSTextField *> *styleBadges;
@property (nonatomic, strong) NSView *cardSources;
@property (nonatomic, strong) NSTextField *sourcesTitle;
@property (nonatomic, strong) NSMutableArray<NSView *> *sourceRows;

// —— 数据 ——
@property (nonatomic, copy) NSArray<NSDictionary *> *materials;
@property (nonatomic, copy) NSDictionary *summaryFields;
@property (nonatomic, copy) NSArray<NSDictionary *> *summaryCitations;
@property (nonatomic, copy) NSArray<NSDictionary *> *summarySections;
@property (nonatomic, assign) BOOL knowledgeFromCache;
@property (nonatomic, assign) BOOL knowledgeDone;
@property (nonatomic, assign) BOOL knowledgeFailed;
@property (nonatomic, assign) BOOL summaryDone;
@property (nonatomic, assign) BOOL summaryFailed;
@property (nonatomic, copy) NSString *summaryFailText;
@property (nonatomic, assign) BOOL bioExpanded;
@property (nonatomic, assign) NSUInteger knowledgeSeq;
@property (nonatomic, assign) NSUInteger summarySeq;
@property (nonatomic, assign) NSInteger summaryPollCount;
@property (nonatomic, assign) BOOL inLayout;
@property (nonatomic, assign) CGFloat lastLayoutWidth;

- (void)relayoutPage;
- (void)reloadKnowledge:(BOOL)refresh;
- (void)reloadSummary:(BOOL)refresh;
@end

@implementation RLPArtistDetailViewController

- (BOOL)usesPageHeaderSpacing { return NO; }

- (instancetype)initWithArtistName:(NSString *)name {
    NSString *title = name.length ? name : RLPTr(@"艺术家");
    self = [super initWithTitle:title];
    if (self) {
        _artistName = [name copy] ?: @"";
        _albums = [NSMutableArray array];
        _citeChips = [NSMutableArray array];
        _styleBadges = [NSMutableArray array];
        _sourceRows = [NSMutableArray array];
        _materials = @[];
        _summaryCitations = @[];
        _summarySections = @[];
    }
    return self;
}

- (void)dealloc { [NSObject cancelPreviousPerformRequestsWithTarget:self]; }

#pragma mark - 建树

- (void)buildContent {
    RLPTheme *t = [RLPTheme current];

    // ---- 滚动容器 ----
    _pageScroll = [[NSScrollView alloc] initWithFrame:self.contentView.bounds];
    _pageScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _pageScroll.drawsBackground = NO;
    _pageScroll.hasVerticalScroller = YES;
    _pageScroll.autohidesScrollers = YES;
    _pageScroll.borderType = NSNoBorder;
    [self.contentView addSubview:_pageScroll];

    _doc = [[RLPArtistFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 954, 700)];
    _pageScroll.documentView = _doc;

    // ---- 顶栏返回按钮（保留 _backBtn，导航契约判据要读它的 title）----
    _backBtn = [NSButton buttonWithTitle:RLPTr(@"返回艺术家列表") target:self action:@selector(onBack:)];
    _backBtn.bezelStyle = NSBezelStyleRounded;
    _backBtn.identifier = @"artist.back.top";
    _backBtn.image = [NSImage imageWithSystemSymbolName:@"chevron.left"
                               accessibilityDescription:RLPTr(@"返回艺术家列表")];
    _backBtn.imagePosition = NSImageLeading;
    _backBtn.font = t.small;
    [_doc addSubview:_backBtn];

    // ---- Hero ----
    _avatarView = [[NSView alloc] initWithFrame:NSZeroRect];
    _avatarView.wantsLayer = YES;
    _avatarView.layer.cornerRadius = kArtistAvatarSide / 2.0;   // 圆形（web border-radius:50%）
    _avatarView.layer.masksToBounds = YES;
    _avatarView.layer.backgroundColor = t.cvBg.CGColor;
    _avatarView.identifier = @"artist.hero.avatar";
    [_doc addSubview:_avatarView];

    NSString *trimmed = [_artistName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *initial = trimmed.length ? [trimmed substringToIndex:1].uppercaseString : @"?";
    _initialLabel = RLPLabel(initial, [NSFont systemFontOfSize:46 weight:NSFontWeightHeavy], t.phText);
    _initialLabel.alignment = NSTextAlignmentCenter;
    [_avatarView addSubview:_initialLabel];

    // 真头像盖在首字母之上：拿到图就显示，拿不到就露出首字母占位。
    _avatarImage = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _avatarImage.imageScaling = NSImageScaleProportionallyUpOrDown;
    _avatarImage.hidden = YES;
    [_avatarView addSubview:_avatarImage];

    // web .ahead .kind{font-size:10px;letter-spacing:1.4px;color:var(--mut2);font-weight:600}
    _eyebrowLabel = RLPArtistMakeLabel(@"artist.hero.eyebrow");
    _eyebrowLabel.attributedStringValue = RLPArtistAttr(RLPTr(@"ARTIST · 艺术家资料"),
        [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold], t.mut2, 1.4, 0);
    [_doc addSubview:_eyebrowLabel];

    // web .ahead h1{font-size:26px;font-weight:750;letter-spacing:-.4px;单行截断}
    _nameLabel = RLPArtistMakeLabel(@"artist.hero.name");
    _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _nameLabel.maximumNumberOfLines = 1;
    _nameLabel.usesSingleLineMode = YES;
    _nameLabel.attributedStringValue = RLPArtistAttr(_artistName.length ? _artistName : RLPTr(@"未知艺术家"),
        [NSFont systemFontOfSize:26 weight:NSFontWeightBold], t.text, -0.4, 0);
    [_doc addSubview:_nameLabel];

    // web .ahead .sub{font-size:12.5px;color:var(--mut)}——没有资料时整行不显示
    _subLabel = RLPArtistMakeLabel(@"artist.hero.sub");
    _subLabel.hidden = YES;
    _subLabel.textColor = t.mut;
    _subLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _subLabel.maximumNumberOfLines = 1;
    [_doc addSubview:_subLabel];

    // 三个按钮（横排，web .btn）
    _btnAlbums = [self heroButton:RLPTr(@"查看专辑") ident:@"artist.hero.btn.albums" action:@selector(onScrollToAlbums:)];
    _btnRefresh = [self heroButton:RLPTr(@"刷新资料") ident:@"artist.hero.btn.refresh" action:@selector(onRefresh:)];
    _btnBackList = [self heroButton:RLPTr(@"返回列表") ident:@"artist.hero.btn.back" action:@selector(onBack:)];
    for (NSButton *b in @[ _btnAlbums ?: (id)[NSNull null], _btnRefresh ?: (id)[NSNull null],
                           _btnBackList ?: (id)[NSNull null] ]) {
        if ([b isKindOfClass:[NSButton class]]) [_doc addSubview:b];
    }

    // 旧的统计行（点击「查看专辑」滚到专辑网格时给出条数；仍在树里，但默认隐藏）
    _statsLabel = RLPLabel(@"", [NSFont systemFontOfSize:12], t.mut);
    _statsLabel.identifier = @"artist.hero.stats";
    _statsLabel.hidden = YES;
    [_doc addSubview:_statsLabel];

    // ---- 三张卡片 ----
    [self buildSummaryCard];
    [self buildBioCard];
    [self buildStylesCard];
    [self buildSourcesCard];

    // ---- 专辑网格 ----
    _collection = [[NSCollectionView alloc] initWithFrame:NSZeroRect];
    NSCollectionViewFlowLayout *layout = [[NSCollectionViewFlowLayout alloc] init];
    layout.itemSize = NSMakeSize(168, 214);
    layout.minimumInteritemSpacing = 18;
    layout.minimumLineSpacing = 22;
    layout.sectionInset = NSEdgeInsetsMake(0, 0, 0, 0);
    _collection.collectionViewLayout = layout;
    _collection.dataSource = self;
    _collection.delegate = self;
    _collection.selectable = YES;
    _collection.allowsMultipleSelection = NO;
    _collection.backgroundColors = @[ NSColor.clearColor ];
    _collection.identifier = @"artist.albums";
    [_collection registerClass:[RLPArtistAlbumItem class] forItemWithIdentifier:kArtistAlbumItemID];

    NSClickGestureRecognizer *dbl = [[NSClickGestureRecognizer alloc] initWithTarget:self
                                                                            action:@selector(onDoubleClick:)];
    dbl.numberOfClicksRequired = 1;
    [_collection addGestureRecognizer:dbl];
    [_doc addSubview:_collection];

    _emptyLabel = RLPLabel(@"", t.body, t.mut);
    _emptyLabel.identifier = @"artist.albums.empty";
    _emptyLabel.alignment = NSTextAlignmentCenter;
    _emptyLabel.hidden = YES;
    [_doc addSubview:_emptyLabel];

    [self applyTheme];
}

- (NSButton *)heroButton:(NSString *)title ident:(NSString *)ident action:(SEL)action {
    RLPArtistChip *b = [[RLPArtistChip alloc] initWithFrame:NSZeroRect];
    b.identifier = ident;
    b.filled = YES;
    b.radius = 8.0;
    b.target = self;
    b.action = action;
    b.alignment = NSTextAlignmentCenter;
    [b setText:title color:[RLPTheme current].text font:[NSFont systemFontOfSize:12]];
    // 注意：不在这里 sizeToFit。relayoutPage 会给按钮明确的 frame（h=28），
    // sizeToFit 之后 NSButton 会把 cell 高度压到 14pt，文字被裁掉（离屏实测）。
    return b;
}

/// 一张 web `.sec-card`：1px 边框 + 圆角 + bg2 底色 + 12pt/600 字距 1 的小节标题。
///
/// 卡片内部**必须**是翻转坐标：relayoutPage 是按「y 自上而下增长」算内部排版的
/// （与 web 的文档流一致）。卡片若是 AppKit 默认的非翻转 NSView，同样的 y 值会被
/// 从底边量起 ⟹ 小节标题跑到卡片**底部**、正文与来源行上下颠倒。
/// （2026-11-21 离屏截图实测到的真实缺陷：AI 整理 / 简介 / 资料来源 三个标题全在卡底。）
- (NSView *)newCard:(NSString *)ident title:(NSString *)title {
    RLPTheme *t = [RLPTheme current];
    NSView *card = [[RLPArtistFlippedView alloc] initWithFrame:NSZeroRect];
    card.identifier = ident;
    card.wantsLayer = YES;
    card.layer.cornerRadius = 12.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = t.line.CGColor;
    card.layer.backgroundColor = t.bg2.CGColor;
    card.autoresizingMask = NSViewNotSizable;
    [_doc addSubview:card];

    NSTextField *head = RLPArtistMakeLabel(@"artist.card.title");
    head.attributedStringValue = RLPArtistAttr(title,
        [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold], t.mut2, 1.0, 0);
    head.maximumNumberOfLines = 1;
    head.lineBreakMode = NSLineBreakByTruncatingTail;
    [card addSubview:head];
    return card;
}

/// 取卡片里的那个小节标题（newCard 里唯一带 artist.card.title 的标签）。
- (NSTextField *)cardTitleOf:(NSView *)card {
    for (NSView *v in card.subviews) {
        if ([v isKindOfClass:[NSTextField class]] &&
            [v.identifier isEqualToString:@"artist.card.title"]) return (NSTextField *)v;
    }
    return nil;
}

- (void)buildSummaryCard {
    _cardSummary = [self newCard:@"artist.card.summary" title:RLPTr(@"AI 整理")];
    _summaryTitle = [self cardTitleOf:_cardSummary];

    _summaryGrid = [[RLPArtistFieldGrid alloc] initWithFrame:NSZeroRect];
    _summaryGrid.identifier = @"artist.summary.grid";
    [_cardSummary addSubview:_summaryGrid];

    // 卡片内状态行（「正在获取资料…」/失败行/暂无资料）——加载文案只出现在卡片里
    _summaryStatus = RLPArtistMakeLabel(@"artist.summary.status");
    RLPArtistStyleWrap(_summaryStatus);
    _summaryStatus.hidden = YES;
    [_cardSummary addSubview:_summaryStatus];

    RLPArtistChip *retryChip = [[RLPArtistChip alloc] initWithFrame:NSZeroRect];
    _summaryRetry = retryChip;
    retryChip.filled = YES;
    retryChip.radius = 8.0;
    _summaryRetry.identifier = @"artist.summary.retry";
    _summaryRetry.target = self;
    _summaryRetry.action = @selector(onRetry:);
    _summaryRetry.hidden = YES;
    _summaryRetry.attributedTitle = RLPArtistAttr(RLPTr(@"重试获取"), [NSFont systemFontOfSize:12],
                                                  [RLPTheme current].text, 0, 0);
    [_cardSummary addSubview:_summaryRetry];

    _summaryFoot = RLPArtistMakeLabel(@"artist.summary.foot");
    RLPArtistStyleWrap(_summaryFoot);
    _summaryFoot.hidden = YES;
    [_cardSummary addSubview:_summaryFoot];
}

- (void)buildBioCard {
    _cardBio = [self newCard:@"artist.card.bio" title:RLPTr(@"简介")];
    _bioTitle = [self cardTitleOf:_cardBio];
    _bioText = RLPArtistMakeLabel(@"artist.bio.text");
    RLPArtistStyleWrap(_bioText);
    [_cardBio addSubview:_bioText];

    RLPArtistChip *toggleChip = [[RLPArtistChip alloc] initWithFrame:NSZeroRect];
    _bioToggle = toggleChip;
    toggleChip.filled = YES;
    toggleChip.radius = 8.0;
    _bioToggle.identifier = @"artist.bio.toggle";
    _bioToggle.target = self;
    _bioToggle.action = @selector(onToggleBio:);
    _bioToggle.hidden = YES;
    _bioToggle.attributedTitle = RLPArtistAttr(RLPTr(@"展开全部"), [NSFont systemFontOfSize:12],
                                               [RLPTheme current].text, 0, 0);
    [_cardBio addSubview:_bioToggle];
    _cardBio.hidden = YES;
}

- (void)buildStylesCard {
    _cardStyles = [self newCard:@"artist.card.styles" title:RLPTr(@"风格与相似")];
    _cardStyles.hidden = YES;
}

- (void)buildSourcesCard {
    _cardSources = [self newCard:@"artist.card.sources" title:RLPTr(@"资料来源")];
    _sourcesTitle = [self cardTitleOf:_cardSources];
    _cardSources.hidden = YES;
}

#pragma mark - 排版（唯一入口：宽度变了 / 数据到了都调它）

- (void)viewDidLayout {
    [super viewDidLayout];
    [self syncDocWidthToScroll];
    [self relayoutPage];
}

/// 把文档视图的宽度**同步到滚动容器**。
///
/// 这就是用户 2026-11-21 截图里「卡片只占半屏、右边一大片空白」的根因：
/// relayoutPage 用 `_doc.bounds.size.width` 当可用宽度，而把文档视图写回
/// `NSMakeRect(0,0,W,totalH)` 用的又是同一个 W —— 自我循环，**没有任何地方**
/// 把文档宽度改成滚动容器的宽度。于是它永远停在 buildContent 里的初始值 954，
/// 窗口放大到 1518 宽后，所有卡片仍按 954 排版，右侧留空。
/// （web 版文档是流式的，天然随容器变宽，所以看不出这个问题。）
- (void)syncDocWidthToScroll {
    if (!_pageScroll || !_doc) return;
    const CGFloat clipW = _pageScroll.contentView.bounds.size.width;
    if (clipW < 40.0) return;
    if (fabs(_doc.frame.size.width - clipW) > 0.5) {
        NSSize sz = _doc.frame.size;
        sz.width = clipW;
        _doc.frame = NSMakeRect(0, 0, clipW, MAX(sz.height, _doc.frame.size.height));
    }
}

- (void)viewDidAppear {
    [super viewDidAppear];
    [self relayoutPage];
}

- (void)relayoutPage {
    if (!_doc || _inLayout) return;
    // 所有排版入口（数据到达 / 主题 / 语言 / 尺寸变化）都会走到这里，
    // 所以在这里兜底同步一次文档宽度，不依赖某一处回调恰好被调用。
    [self syncDocWidthToScroll];
    const CGFloat W = _doc.bounds.size.width;
    if (W < 40.0) return;
    _inLayout = YES;
    RLPTheme *t = [RLPTheme current];

    const CGFloat padX = kArtistPagePadX;
    const CGFloat contentW = MAX(80.0, W - padX * 2.0);
    CGFloat y = 6.0;

    // ---- ① 顶栏返回按钮 ----
    {
        const CGFloat bw = MIN(contentW, MAX(96.0, RLPArtistChipW(_backBtn.title, _backBtn.font) + 26.0));
        const CGFloat bh = 26.0;
        _backBtn.frame = NSMakeRect(padX, y, bw, bh);
        y += bh + 8.0;
    }

    // ---- ② Hero ----
    const CGFloat avatarS = kArtistAvatarSide;
    const CGFloat heroLeft = padX;
    const CGFloat infoX = heroLeft + avatarS + 20.0;       // web .ahead gap:20px
    const CGFloat infoW = MAX(60.0, W - infoX - padX);
    const CGFloat eyebrowH = 14.0;
    const CGFloat nameH = 32.0;                            // 26pt 单行
    const CGFloat subH = 18.0;
    const CGFloat btnH = 28.0;                             // web .btn 6px+12px+2px

    // eyebrow / 大标题 / 副标题 / 按钮 自顶向下堆叠，整体与头像底对齐（web align-items:flex-end）
    const BOOL hasSub = !_subLabel.hidden;
    const CGFloat stackH = eyebrowH + 5.0 + nameH + 7.0
                         + (hasSub ? subH : 0.0)
                         + 13.0 + btnH;                     // web .sub margin-bottom:13px
    const CGFloat heroTop = y;
    const CGFloat heroH = MAX(avatarS, stackH);
    const CGFloat stackTop = heroTop + MAX(0.0, heroH - avatarS);

    _avatarView.frame = NSMakeRect(heroLeft, heroTop, avatarS, avatarS);
    _avatarImage.frame = _avatarView.bounds;
    {
        const CGFloat iw = 120.0, ih = 56.0;
        _initialLabel.frame = NSMakeRect((avatarS - iw) / 2.0, (avatarS - ih) / 2.0, iw, ih);
    }

    CGFloat sy = stackTop;
    _eyebrowLabel.frame = NSMakeRect(infoX, sy, infoW, eyebrowH);
    sy += eyebrowH + 5.0;
    _nameLabel.frame = NSMakeRect(infoX, sy, infoW, nameH);
    sy += nameH + 7.0;
    if (hasSub) {
        _subLabel.frame = NSMakeRect(infoX, sy, infoW, subH);
        sy += subH;
    } else {
        _subLabel.frame = NSZeroRect;
    }
    sy += 13.0;

    // 三个按钮横排（放不下就换行，永不溢出）
    {
        CGFloat bx = infoX;
        CGFloat by = sy;
        CGFloat bwSum = 0.0;
        NSArray<NSButton *> *btns = @[ _btnAlbums, _btnRefresh, _btnBackList ];
        const CGFloat gap = 8.0;
        for (NSButton *b in btns) {
            const CGFloat bw = RLPArtistChipW(b.title, b.font) + 6.0;
            bwSum += bw + gap;
        }
        const BOOL oneRow = (infoX + bwSum - gap) <= (W - padX + 0.5);
        for (NSButton *b in btns) {
            const CGFloat bw = RLPArtistChipW(b.title, b.font) + 6.0;
            if (!oneRow && bx > infoX && (bx + bw) > (W - padX + 0.5)) { bx = infoX; by += btnH + 8.0; }
            b.frame = NSMakeRect(bx, by, bw, btnH);
            bx += bw + gap;
        }
    }
    _statsLabel.frame = NSZeroRect;
    y = heroTop + heroH + 18.0;

    // ---- ③ ~ ⑥ 纵向卡片 ----
    y = [self layoutSummaryCardAt:y width:contentW x:padX];
    y += kArtistCardGap;
    y = [self layoutBioCardAt:y width:contentW x:padX];
    if (!_cardStyles.hidden) { y += kArtistCardGap; y = [self layoutStylesCardAt:y width:contentW x:padX]; }
    if (!_cardSources.hidden) { y += kArtistCardGap; y = [self layoutSourcesCardAt:y width:contentW x:padX]; }

    // ---- ⑦ 专辑网格 ----
    y += 8.0;
    const NSInteger cols = MAX(1, (NSInteger)floor((contentW + 18.0) / (168.0 + 18.0)));
    const NSInteger n = (NSInteger)self.albums.count;
    const NSInteger rows = (cols > 0 && n > 0) ? ((n + cols - 1) / cols) : 0;
    const CGFloat gridH = (rows > 0) ? (CGFloat)rows * 214.0 + (CGFloat)(rows - 1) * 22.0 : 0.0;
    if (gridH > 0.5) {
        _collection.hidden = NO;
        _collection.frame = NSMakeRect(padX, y, contentW, gridH);
        if (NSCollectionViewFlowLayout *fl = (NSCollectionViewFlowLayout *)_collection.collectionViewLayout) {
            if (fabs(fl.itemSize.width - 168.0) > 0.5) fl.itemSize = NSMakeSize(168, 214);
        }
        y += gridH;
    } else {
        _collection.hidden = YES;
        _collection.frame = NSZeroRect;
    }
    if (!_emptyLabel.hidden) {
        const CGFloat eh = 22.0;
        _emptyLabel.frame = NSMakeRect(padX, y + 6.0, contentW, eh);
        y += eh + 6.0;
    } else {
        _emptyLabel.frame = NSZeroRect;
    }

    // 文档高度（翻转坐标下就是内容总高）
    const CGFloat totalH = MAX(_pageScroll.contentView.bounds.size.height, y + 30.0);
    if (fabs(_doc.frame.size.height - totalH) > 0.5 || fabs(_doc.frame.size.width - W) > 0.5) {
        _doc.frame = NSMakeRect(0, 0, W, totalH);
    }
    _lastLayoutWidth = W;
    _inLayout = NO;
}

- (CGFloat)cardTitleH { return 15.0; }
- (CGFloat)cardTitleGap { return 8.0; }

- (CGFloat)layoutSummaryCardAt:(CGFloat)top width:(CGFloat)contentW x:(CGFloat)left {
    RLPTheme *t = [RLPTheme current];
    const CGFloat innerW = MAX(40.0, contentW - kArtistCardPadX * 2.0);
    CGFloat y = kArtistCardPadY;
    _summaryTitle.frame = NSMakeRect(kArtistCardPadX, y, innerW, [self cardTitleH]);
    y += [self cardTitleH] + [self cardTitleGap];

    // 字段网格
    const CGFloat gridH = [_summaryGrid layoutWidth:innerW];
    _summaryGrid.frame = NSMakeRect(kArtistCardPadX, y, innerW, MAX(1.0, gridH));
    if (!_summaryGrid.hidden && gridH > 0.5) y += gridH + 10.0;

    // 状态行（正在获取资料… / 暂无资料 / 失败行）
    if (!_summaryStatus.hidden) {
        const CGFloat sh = MAX(18.0, RLPArtistTextH(_summaryStatus.stringValue, _summaryStatus.font, innerW, 0));
        _summaryStatus.frame = NSMakeRect(kArtistCardPadX, y, innerW, sh);
        y += sh + 8.0;
    } else {
        _summaryStatus.frame = NSZeroRect;
    }
    if (!_summaryRetry.hidden) {
        const CGFloat bw = RLPArtistChipW(_summaryRetry.title, _summaryRetry.font);
        _summaryRetry.frame = NSMakeRect(kArtistCardPadX, y, bw, 26.0);
        y += 26.0 + 8.0;
    } else {
        _summaryRetry.frame = NSZeroRect;
    }

    // 引用芯片（[1] 标题 + 复制）
    if (_citeChips.count) {
        for (NSView *row in _citeChips) [row removeFromSuperview];
        [_citeChips removeAllObjects];
    }
    for (NSUInteger i = 0; i < _summaryCitations.count; ++i) {
        NSDictionary *c = _summaryCitations[i];
        NSString *title = [c[@"title"] isKindOfClass:[NSString class]] ? c[@"title"] : nil;
        NSString *src = [c[@"source"] isKindOfClass:[NSString class]] ? c[@"source"] : nil;
        NSString *url = [c[@"url"] isKindOfClass:[NSString class]] ? c[@"url"] : @"";
        NSString *label = [NSString stringWithFormat:@"[%lu] %@", (unsigned long)(i + 1),
                           title.length ? title : (src.length ? src : @"")];
        RLPArtistChip *chip = [[RLPArtistChip alloc] initWithFrame:NSZeroRect];
        chip.identifier = [NSString stringWithFormat:@"artist.summary.cite.%lu", (unsigned long)(i + 1)];
        chip.filled = NO;
        chip.radius = 6.0;
        chip.font = [NSFont systemFontOfSize:11];
        chip.attributedTitle = RLPArtistAttr(label, [NSFont systemFontOfSize:11], t.mut, 0, 0);
        chip.toolTip = url;
        chip.target = self;
        chip.action = @selector(onCopyChip:);
        [_cardSummary addSubview:chip];
        [_citeChips addObject:chip];
    }
    if (_citeChips.count) {
        const CGFloat gap = 6.0;
        CGFloat cx = kArtistCardPadX, cy = y;
        const CGFloat ch = 22.0;
        for (NSButton *chip in _citeChips) {
            NSString *ti = chip.title;
            const CGFloat cw = MIN(innerW, RLPArtistChipW(ti, chip.font) + 20.0);
            if (cx > kArtistCardPadX && (cx + cw) > (kArtistCardPadX + innerW + 0.5)) {
                cx = kArtistCardPadX; cy += ch + gap;
            }
            chip.frame = NSMakeRect(cx, cy, cw, ch);
            cx += cw + gap;
        }
        y = cy + ch + 8.0;
    }

    // 脚注
    if (!_summaryFoot.hidden) {
        const CGFloat fh = MAX(14.0, RLPArtistTextH(_summaryFoot.stringValue, _summaryFoot.font, innerW, 0));
        _summaryFoot.frame = NSMakeRect(kArtistCardPadX, y, innerW, fh);
        y += fh + 2.0;
    } else {
        _summaryFoot.frame = NSZeroRect;
    }

    const CGFloat cardH = MAX(kArtistCardPadY * 2.0 + [self cardTitleH] + [self cardTitleGap], y + kArtistCardPadY);
    _cardSummary.frame = NSMakeRect(left, top, contentW, cardH);
    return top + cardH;
}

- (CGFloat)layoutBioCardAt:(CGFloat)top width:(CGFloat)contentW x:(CGFloat)left {
    if (_cardBio.hidden) { _cardBio.frame = NSZeroRect; return top; }
    const CGFloat innerW = MAX(40.0, contentW - kArtistCardPadX * 2.0);
    CGFloat y = kArtistCardPadY;
    _bioTitle.frame = NSMakeRect(kArtistCardPadX, y, innerW, [self cardTitleH]);
    y += [self cardTitleH] + 10.0;   // web .bio-sec 的 sec-title margin-bottom:10px

    const CGFloat fullH = RLPArtistTextH(_bioText.stringValue, _bioText.font, innerW, 8.0);
    const CGFloat collapsedH = 4.0 * 21.5;      // 12.5pt × 1.7 ≈ 21.25 ⟹ 折叠 4 行
    const BOOL needToggle = (fullH > collapsedH + 1.0);
    const CGFloat showH = (needToggle && !_bioExpanded) ? collapsedH : fullH;
    _bioText.frame = NSMakeRect(kArtistCardPadX, y, innerW, MAX(16.0, showH));
    _bioText.superview.layer.masksToBounds = YES;   // 折叠时真的裁掉后面的行
    y += MAX(16.0, showH);

    if (needToggle) {
        _bioToggle.hidden = NO;
        NSString *title = _bioExpanded ? RLPTr(@"收起简介") : RLPTr(@"展开全部");
        _bioToggle.attributedTitle = RLPArtistAttr(title, [NSFont systemFontOfSize:12],
                                                   [RLPTheme current].text, 0, 0);
        const CGFloat bw = RLPArtistChipW(title, _bioToggle.font);
        y += 10.0;
        _bioToggle.frame = NSMakeRect(kArtistCardPadX, y, bw, 26.0);
        y += 26.0;
    } else {
        _bioToggle.hidden = YES;
        _bioToggle.frame = NSZeroRect;
    }

    const CGFloat cardH = y + kArtistCardPadY;
    _cardBio.frame = NSMakeRect(left, top, contentW, cardH);
    return top + cardH;
}

- (CGFloat)layoutStylesCardAt:(CGFloat)top width:(CGFloat)contentW x:(CGFloat)left {
    const CGFloat innerW = MAX(40.0, contentW - kArtistCardPadX * 2.0);
    CGFloat y = kArtistCardPadY;
    NSTextField *head = nil;
    for (NSView *v in _cardStyles.subviews) {
        if ([v isKindOfClass:[NSTextField class]]) { head = (NSTextField *)v; break; }
    }
    if (head) { head.frame = NSMakeRect(kArtistCardPadX, y, innerW, [self cardTitleH]); }
    y += [self cardTitleH] + 10.0;

    const CGFloat gap = 8.0, bh = 20.0;
    CGFloat bx = kArtistCardPadX, by = y;
    for (NSTextField *b in _styleBadges) {
        const CGFloat bw = MIN(innerW, RLPArtistChipW(b.stringValue, b.font) + 12.0);
        if (bx > kArtistCardPadX && (bx + bw) > (kArtistCardPadX + innerW + 0.5)) {
            bx = kArtistCardPadX; by += bh + gap;
        }
        b.frame = NSMakeRect(bx, by, bw, bh);
        bx += bw + gap;
    }
    y = by + bh;
    const CGFloat cardH = y + kArtistCardPadY;
    _cardStyles.frame = NSMakeRect(left, top, contentW, cardH);
    return top + cardH;
}

- (CGFloat)layoutSourcesCardAt:(CGFloat)top width:(CGFloat)contentW x:(CGFloat)left {
    RLPTheme *t = [RLPTheme current];
    const CGFloat innerW = MAX(40.0, contentW - kArtistCardPadX * 2.0);
    CGFloat y = kArtistCardPadY;
    _sourcesTitle.frame = NSMakeRect(kArtistCardPadX, y, innerW, [self cardTitleH]);
    y += [self cardTitleH] + 12.0;

    const CGFloat rowH = 34.0, rowGap = 8.0;
    for (NSView *row in _sourceRows) {
        row.frame = NSMakeRect(kArtistCardPadX, y, innerW, rowH);
        // 行内：徽章 / 标题 / 取回于日期 / 复制链接 + 复制
        NSArray<NSView *> *subs = row.subviews;
        CGFloat right = innerW;
        // 从右往左放两个芯片
        for (NSInteger i = (NSInteger)subs.count - 1; i >= 0; --i) {
            NSView *v = subs[(NSUInteger)i];
            if (![v isKindOfClass:[NSButton class]]) continue;
            NSButton *b = (NSButton *)v;
            const CGFloat bw = RLPArtistChipW(b.title, b.font);
            right -= bw;
            b.frame = NSMakeRect(right, (rowH - 22.0) / 2.0, bw, 22.0);
            right -= 6.0;
        }
        // 左侧：徽章（定宽，按文字）/ 标题（吃掉剩余宽度）/ 日期（定宽，靠右）
        //
        // 旧写法给徽章算的是 `right - lx - 20`，即「把右侧剩余宽度全给徽章」⟹
        // 徽章被撑成整行、日期被挤到最右被截断、两个芯片被顶出行外
        // （2026-11-21 离屏截图实测：徽章像一条粉色横条）。
        // 现在：徽章与日期都按文字量宽，只有标题伸缩。
        CGFloat lx = 0.0;
        NSTextField *badgeTF = nil, *titleTF = nil, *dateTF = nil;
        for (NSView *v in subs) {
            if (![v isKindOfClass:[NSTextField class]]) continue;
            NSTextField *tf = (NSTextField *)v;
            // 注意 identifier 的实际形态：徽章是 `artist.sources.badge.<n>`（**带序号**），
            // 标题/日期是 `artist.sources.title` / `artist.sources.date`。
            // 旧写法按 hasSuffix:@".badge" 匹配，永远匹配不到带序号的徽章 ⟹ badgeTF 恒为 nil、
            // 徽章从不参与排版，一直保持 NSTextField 的默认 4×16 小框
            //（2026-11-21 离屏截图实测：来源徽章是一小条粉色、日期被挪到最右）。
            if ([tf.identifier containsString:@".badge"]) badgeTF = tf;
            else if ([tf.identifier hasSuffix:@".date"]) dateTF = tf;
            else titleTF = tf;
        }
        // 徽章：纯文字宽度 + 左右各 8pt 内边距（web .badge padding:2px 8px）
        if (badgeTF) {
            // 取「属性字符串里真正的字体」来量宽，而不是 badgeTF.font：
            // setting attributedStringValue 之后 control 的 font 可能不同步，
            // 实测按 tf.font 量出的徽章宽度只有 4pt（药丸几乎不可见）。
            NSAttributedString *bas = badgeTF.attributedStringValue;
            NSString *bt = bas.length ? bas.string : (badgeTF.stringValue ?: @"");
            NSFont *bfont = (bas.length && [bas attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL])
                ? [bas attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL]
                : (badgeTF.font ?: [NSFont systemFontOfSize:9.5]);
            const CGFloat bw = MIN(MAX(28.0, ceil([bt sizeWithAttributes:@{ NSFontAttributeName: bfont }].width) + 16.0),
                                   MAX(28.0, right - 40.0));
            // 药丸只有「文字高 + 上下 3pt」这么高，并整体在行内垂直居中。
            // 注意：**不能用 ascender - descender** —— NSFont.ascender 是负值
            // （基线在字形盒上方，Apple 的约定），相减会得到负数，药丸高度变负 ⟹
            // 一个像素都画不出来（2026-11-21 离屏截图实测：来源徽章整块消失）。
            // defaultLineHeightForFont 才是「这一号字一行占多高」的正解。
            const CGFloat badgeH = ceil(bfont.boundingRectForFont.size.height) + 8.0;
            badgeTF.frame = NSMakeRect(lx, round((rowH - badgeH) / 2.0), bw, badgeH);
            if ([row isKindOfClass:[RLPArtistSourceRow class]]) {
                RLPArtistSourceRow *sr = (RLPArtistSourceRow *)row;
                sr.badgePill.frame = badgeTF.frame;         // 药丸底 = 文字框同一矩形
                sr.badgePill.layer.backgroundColor = t.accentWeak.CGColor;
            }
            lx += bw + 12.0;
        }
        // 日期：定宽靠右，绝不截断（「取回于 2026-11-09」整串要看得见）
        CGFloat dateW = 0.0;
        if (dateTF) {
            NSAttributedString *das = dateTF.attributedStringValue;
            NSString *dt = das.length ? das.string : (dateTF.stringValue ?: @"");
            NSFont *dfont = (das.length && [das attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL])
                ? [das attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL]
                : (dateTF.font ?: [NSFont systemFontOfSize:11.5]);
            dateW = ceil([dt sizeWithAttributes:@{ NSFontAttributeName: dfont }].width) + 4.0;
            dateW = MIN(dateW, MAX(0.0, right - lx - 120.0));
        }
        // 标题：吃掉中间剩余宽度
        if (titleTF) {
            const CGFloat tw = MAX(40.0, right - lx - dateW - 12.0);
            titleTF.frame = NSMakeRect(lx, (rowH - 17.0) / 2.0, tw, 17.0);
            lx += tw + 10.0;
        }
        if (dateTF) {
            dateTF.frame = NSMakeRect(MAX(lx, right - dateW), (rowH - 16.0) / 2.0, MAX(20.0, dateW), 16.0);
        }
        (void)t;
        y += rowH + rowGap;
    }
    y -= (_sourceRows.count ? rowGap : 0.0);
    const CGFloat cardH = y + kArtistCardPadY;
    _cardSources.frame = NSMakeRect(left, top, contentW, cardH);
    return top + cardH;
}

#pragma mark - 渲染三张卡片的内容

/// 从知识材料里取简介正文（web：第一条 biography/disambiguation 或带 text 的材料）。
- (NSDictionary *)bioMaterial {
    for (NSDictionary *m in self.materials) {
        NSString *kind = [m[@"kind"] isKindOfClass:[NSString class]] ? m[@"kind"] : @"";
        NSString *text = [m[@"text"] isKindOfClass:[NSString class]] ? m[@"text"] : @"";
        if (text.length == 0) continue;
        if ([kind isEqualToString:@"biography"] || [kind isEqualToString:@"disambiguation"]) return m;
    }
    for (NSDictionary *m in self.materials) {
        NSString *text = [m[@"text"] isKindOfClass:[NSString class]] ? m[@"text"] : @"";
        if (text.length) return m;
    }
    return nil;
}

- (BOOL)hasBio {
    NSDictionary *m = [self bioMaterial];
    return [[m[@"text"] ?: @"" description] length] > 0;
}

/// 副标题：有缓存资料 `缓存 · <日期> 取回`；刚取回 `资料 · <日期> 取回`；没有资料整行不显示。
- (void)refreshSubLabel {
    NSString *sub = @"";
    if (self.materials.count) {
        NSString *date = RLPArtistFmtDate(self.materials.firstObject[@"fetched_at"]);
        NSString *prefix = self.knowledgeFromCache ? RLPTr(@"缓存 ·") : RLPTr(@"资料");
        if (date.length) {
            sub = [NSString stringWithFormat:@"%@ · %@ %@", prefix, date, RLPTr(@"取回")];
        }
    }
    _subLabel.stringValue = sub;
    _subLabel.hidden = (sub.length == 0);
}

/// 失败行由三个**词表里真实存在**的碎片拼成：`资料整理失败（` + 原因 + `）· 点击重试`
/// （web artistSummRetry 同一拼法）。整句式不是词表键，直接写会破 i18n 覆盖率门禁。
- (NSString *)summaryFailLine:(NSString *)reason {
    return [NSString stringWithFormat:@"%@%@%@",
            RLPTr(@"资料整理失败（"), reason.length ? reason : RLPTr(@"超时"),
            RLPTr(@"）· 点击重试")];
}

- (void)refreshSummaryCard {
    RLPTheme *t = [RLPTheme current];
    [_summaryGrid removeAllItems];

    // 1) 字段网格：先按 EF_ORDER.person 输出有值的键，再输出其余有值的键（不许丢字段、不许占位）
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSDictionary *fields = self.summaryFields ?: @{};
    for (NSString *k in RLPArtistPersonOrder()) {
        NSString *v = RLPArtistFieldText(fields[k]);
        if (!v.length) continue;
        // 已有词条简介 ⟹ AI 网格里跳过「简介」，避免同页两段简介
        if ([k isEqualToString:@"简介"] && [self hasBio]) continue;
        [labels addObject:k];
        [seen addObject:k];
    }
    // 契约外的标签也照渲染（web renderFieldGrid：前端不许丢后端给的内容）
    NSArray<NSString *> *extraKeys = [fields.allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    for (NSString *k in extraKeys) {
        if ([seen containsObject:k]) continue;
        if ([k isEqualToString:@"简介"] && [self hasBio]) continue;
        if (!RLPArtistFieldText(fields[k]).length) continue;
        [labels addObject:k];
    }
    // sections 兜底：fields 为空时用段落文本（heading 为「概述」「简介」不加小标题）
    if (labels.count == 0 && self.summarySections.count) {
        NSMutableString *acc = [NSMutableString string];
        for (NSDictionary *sec in self.summarySections) {
            NSString *heading = [sec[@"heading"] isKindOfClass:[NSString class]] ? sec[@"heading"] : @"";
            NSArray *paras = [sec[@"paragraphs"] isKindOfClass:[NSArray class]] ? sec[@"paragraphs"] : @[];
            if (!paras.count) continue;
            BOOL headingUseful = heading.length &&
                ![heading isEqualToString:@"概述"] && ![heading isEqualToString:@"简介"];
            if (headingUseful && ![heading isEqualToString:@"简介"]) {
                // section 小标题直接作为字段标签
                if (![seen containsObject:heading]) {
                    [labels addObject:heading];
                    [seen addObject:heading];
                }
                continue;
            }
            for (NSDictionary *p in paras) {
                NSString *txt = [p[@"text"] isKindOfClass:[NSString class]] ? p[@"text"] : @"";
                if (txt.length) {
                    if (acc.length) [acc appendString:@"\n"];
                    [acc appendString:txt];
                }
            }
        }
        if (acc.length) {
            NSString *bioKey = RLPTr(@"简介");
            if (![seen containsObject:bioKey] && ![self hasBio]) {
                [labels insertObject:bioKey atIndex:0];
                seen = [NSMutableSet setWithObject:bioKey];
            }
        }
    }

    for (NSString *label in labels) {
        NSString *value = RLPArtistFieldText(fields[label]);
        if (!value.length) continue;
        RLPArtistFieldRow *row = [[RLPArtistFieldRow alloc] initWithFieldName:label value:value];
        row.identifier = [@"artist.summary.field." stringByAppendingString:label];
        const BOOL wide = RLPArtistIsWideLabel(label) || value.length > 46 ||
                          [value rangeOfString:@"\n"].location != NSNotFound;
        row.wide = wide;
        [_summaryGrid addItem:row wide:wide];
    }
    _summaryGrid.hidden = (labels.count == 0);

    // 2) 状态行：加载中 / 失败 / 空态——加载文案只在卡片内
    BOOL showStatus = NO, showRetry = NO;
    NSString *statusText = @"";
    NSColor *statusColor = t.mut2;
    if (self.summaryFailed) {
        // 两条纪律要分开，否则空态会长出两个可点控件（用户要求「简洁」）：
        //   · 连同词条材料一起什么都没有 ⟹ 空态：一行「暂无资料」+ 一个「重试获取」（纪律 4）
        //   · 有材料但整理失败 ⟹ 一行「资料整理失败（…）· 点击重试」（纪律 5，整行自身可点）
        const BOOL noDataAtAll = (self.materials.count == 0);
        showStatus = YES;
        showRetry = noDataAtAll;
        statusText = noDataAtAll
            ? RLPTr(@"暂无资料")
            : (self.summaryFailText.length ? self.summaryFailText : [self summaryFailLine:RLPTr(@"超时")]);
        statusColor = t.mut;
    } else if (!self.summaryDone && self.summaryFields.count == 0 && self.summarySections.count == 0) {
        showStatus = YES;
        statusText = RLPTr(@"正在获取资料…");
    } else if (labels.count == 0 && self.knowledgeDone && self.materials.count == 0) {
        // 知识材料为空且 AI 整理也没出东西 ⟹ 一张卡内「暂无资料」+「重试获取」，不写解释
        showStatus = YES; showRetry = YES;
        statusText = RLPTr(@"暂无资料");
        statusColor = t.mut;
    }
    _summaryStatus.hidden = !showStatus;
    _summaryStatus.stringValue = statusText;
    _summaryStatus.textColor = statusColor;
    _summaryStatus.attributedStringValue = RLPArtistAttr(statusText, [NSFont systemFontOfSize:12],
                                                         statusColor, 0, 0);
    _summaryRetry.hidden = !showRetry;

    // 3) 引用芯片 / 脚注
    NSArray *cites = self.summaryCitations ?: @[];
    _summaryFoot.hidden = (cites.count == 0);
    _summaryFoot.attributedStringValue = RLPArtistAttr(
        RLPTr(@"依据上面的来源整理，可能不完整，请以来源为准"),
        [NSFont systemFontOfSize:11], t.mut2, 0, 0);
    [self relayoutPage];
}

- (void)refreshBioCard {
    RLPTheme *t = [RLPTheme current];
    NSDictionary *m = [self bioMaterial];
    NSString *text = [m[@"text"] isKindOfClass:[NSString class]] ? m[@"text"] : @"";
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) {
        _cardBio.hidden = YES;
        _bioText.stringValue = @"";
        return;
    }
    _cardBio.hidden = NO;
    _bioText.attributedStringValue = RLPArtistAttr(text, [NSFont systemFontOfSize:12.5], t.text2, 0, 8.0);
}

- (void)refreshStylesCard {
    RLPTheme *t = [RLPTheme current];
    for (NSTextField *b in _styleBadges) [b removeFromSuperview];
    [_styleBadges removeAllObjects];

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSDictionary *m in self.materials) {
        NSString *kind = [m[@"kind"] isKindOfClass:[NSString class]] ? m[@"kind"] : @"";
        if (!([kind isEqualToString:@"genre"] || [kind isEqualToString:@"similar"])) continue;
        NSString *title = [m[@"title"] isKindOfClass:[NSString class]] ? m[@"title"] : @"";
        NSString *text = [m[@"text"] isKindOfClass:[NSString class]] ? m[@"text"] : @"";
        NSString *src = title.length ? title : text;
        if (src.length) [names addObject:src];
    }
    if (names.count == 0) {
        _cardStyles.hidden = YES;
        return;
    }
    _cardStyles.hidden = NO;
    for (NSString *n in names) {
        NSTextField *badge = RLPArtistMakeLabel(@"artist.style.badge");
        badge.attributedStringValue = RLPArtistAttr(n, [NSFont systemFontOfSize:11], t.accentText, 0, 0);
        badge.alignment = NSTextAlignmentCenter;
        badge.wantsLayer = YES;
        badge.layer.cornerRadius = 5.0;
        badge.layer.backgroundColor = t.accentWeak.CGColor;
        badge.maximumNumberOfLines = 1;
        badge.lineBreakMode = NSLineBreakByTruncatingTail;
        [_cardStyles addSubview:badge];
        [_styleBadges addObject:badge];
    }
}

- (void)refreshSourcesCard {
    RLPTheme *t = [RLPTheme current];
    for (NSView *row in _sourceRows) [row removeFromSuperview];
    [_sourceRows removeAllObjects];

    if (self.materials.count == 0) {
        _cardSources.hidden = YES;
        return;
    }
    _cardSources.hidden = NO;

    NSInteger idx = 0;
    for (NSDictionary *m in self.materials) {
        idx += 1;
        RLPArtistSourceRow *row = [[RLPArtistSourceRow alloc] initWithFrame:NSZeroRect];
        row.identifier = [NSString stringWithFormat:@"artist.sources.row.%ld", (long)idx];
        row.wantsLayer = YES;
        row.layer.cornerRadius = 9.0;
        row.layer.backgroundColor = t.hov.CGColor;
        row.autoresizingMask = NSViewNotSizable;

        NSTextField *badge = RLPArtistMakeLabel(@"artist.sources.badge");
        badge.identifier = [NSString stringWithFormat:@"artist.sources.badge.%ld", (long)idx];
        NSString *srcName = RLPArtistSourceBadge([m[@"source"] isKindOfClass:[NSString class]] ? m[@"source"] : @"");
        badge.attributedStringValue = RLPArtistAttr(srcName, [NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold],
                                                    t.accentText, 0.3, 0);
        badge.alignment = NSTextAlignmentCenter;
        // 药丸底**不挂在这个 label 的 layer 上**：NSTextField 的 layer 背景会盖住
        // 它自己 cell 画的文字（离屏截图实测：粉色条盖掉了「萌娘百科」，只剩一条色块）。
        // 改为在行视图（RLPArtistSourceRow）里单独画一层底，label 只负责文字。
        badge.drawsBackground = NO;
        badge.wantsLayer = NO;
        badge.maximumNumberOfLines = 1;
        badge.lineBreakMode = NSLineBreakByTruncatingTail;
        [row addSubview:badge];
        // 药丸是行的第一个子视图（构造时加的），徽章 label 后加 ⟹ 自然在它上面。
        // 这里再显式确认一次，避免以后有人在中间插入别的子视图把顺序打乱。
        if ([row isKindOfClass:[RLPArtistSourceRow class]]) {
            [badge removeFromSuperview];
            [row addSubview:badge];
        }

        NSTextField *title = RLPArtistMakeLabel(@"artist.sources.title");
        NSString *ttl = [m[@"title"] isKindOfClass:[NSString class]] ? m[@"title"] : @"";
        title.attributedStringValue = RLPArtistAttr(ttl, [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold],
                                                    t.text, 0, 0);
        title.maximumNumberOfLines = 1;
        title.lineBreakMode = NSLineBreakByTruncatingTail;
        [row addSubview:title];

        NSTextField *date = RLPArtistMakeLabel(@"artist.sources.date");
        NSString *d = RLPArtistFmtDate(m[@"fetched_at"]);
        NSString *dText = d.length ? [NSString stringWithFormat:@"%@ %@", RLPTr(@"取回于"), d] : @"";
        date.attributedStringValue = RLPArtistAttr(dText, [NSFont systemFontOfSize:11.5], t.mut2, 0, 0);
        date.maximumNumberOfLines = 1;
        date.lineBreakMode = NSLineBreakByTruncatingTail;
        [row addSubview:date];

        NSString *url = [m[@"url"] isKindOfClass:[NSString class]] ? m[@"url"] : @"";
        RLPArtistChip *openChip = [[RLPArtistChip alloc] initWithFrame:NSZeroRect];
        openChip.identifier = [NSString stringWithFormat:@"artist.sources.open.%ld", (long)idx];
        openChip.filled = YES;
        openChip.radius = 7.0;
        [openChip setText:RLPTr(@"复制链接") color:t.text font:[NSFont systemFontOfSize:11]];
        openChip.toolTip = url;
        openChip.target = self;
        openChip.action = @selector(onCopySourceURL:);
        openChip.hidden = (url.length == 0);
        [row addSubview:openChip];

        RLPArtistChip *copyChip = [[RLPArtistChip alloc] initWithFrame:NSZeroRect];
        copyChip.identifier = [NSString stringWithFormat:@"artist.sources.copy.%ld", (long)idx];
        copyChip.filled = YES;
        copyChip.radius = 7.0;
        [copyChip setText:RLPTr(@"复制") color:t.text font:[NSFont systemFontOfSize:11]];
        copyChip.toolTip = url;
        copyChip.target = self;
        copyChip.action = @selector(onCopySourceURL:);
        copyChip.hidden = (url.length == 0);
        [row addSubview:copyChip];

        [_cardSources addSubview:row];
        [_sourceRows addObject:row];
    }
}

/// 数据齐了之后把三张卡片重画一遍并重排。
- (void)refreshAllCards {
    [self refreshSubLabel];
    [self refreshSummaryCard];
    [self refreshBioCard];
    [self refreshStylesCard];
    [self refreshSourcesCard];
    [self relayoutPage];
}

#pragma mark - 取数（两条独立通道，序号守卫丢弃旧实体回包）

- (void)activate {
    if (!self.loaded) [self reloadData];
    [self loadAvatar];
    // 换实体后旧回包必须丢弃：两个 seq 各自独立（同 RLPKnowledgeView 的缺口1 做法）
    ++self.knowledgeSeq;
    ++self.summarySeq;
    self.knowledgeDone = NO;
    self.knowledgeFailed = NO;
    self.knowledgeFromCache = NO;
    self.summaryDone = NO;
    self.summaryFailed = NO;
    self.summaryFailText = nil;
    self.summaryPollCount = 0;
    // 换实体/重取时先把上一轮内容清空：旧实体的字段绝不能留在网格里冒充本轮结果
    self.materials = @[];
    self.summaryFields = @{};
    self.summaryCitations = @[];
    self.summarySections = @[];
    if (_artistName.length) {
        [self reloadKnowledge:NO];
        [self reloadSummary:NO];
    }
    [self refreshAllCards];
}

- (NSString *)knowledgeURL:(BOOL)refresh {
    NSMutableString *u = [NSMutableString stringWithFormat:@"/api/entity/knowledge?kind=person&name=%@",
                          RLPEnc(_artistName ?: @"")];
    if (refresh) [u appendString:@"&refresh=1"];
    return u;
}

- (NSString *)summaryURL:(BOOL)refresh {
    NSMutableString *u = [NSMutableString stringWithFormat:
                          @"/api/entity/summary?kind=person&name=%@&lang=zh", RLPEnc(_artistName ?: @"")];
    if (refresh) [u appendString:@"&refresh=1"];
    return u;
}

- (void)reloadKnowledge:(BOOL)refresh {
    if (!_artistName.length || ![RLPCoreClient shared].started) {
        self.knowledgeDone = YES;
        self.knowledgeFailed = YES;
        [self refreshAllCards];
        return;
    }
    const NSUInteger seq = self.knowledgeSeq;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:[self knowledgeURL:refresh]
                         completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        // 切走/换实体后丢弃旧响应
        if (seq != self_.knowledgeSeq) return;
        NSArray *mats = [json[@"materials"] isKindOfClass:[NSArray class]] ? json[@"materials"] : nil;
        if (!json || ![json[@"ok"] boolValue] || !mats) {
            self_.knowledgeDone = YES;
            self_.knowledgeFailed = YES;
            self_.materials = @[];
            [self_ refreshAllCards];
            return;
        }
        self_.knowledgeDone = YES;
        self_.knowledgeFailed = NO;
        self_.knowledgeFromCache = [json[@"from_cache"] respondsToSelector:@selector(boolValue)] &&
                                   [json[@"from_cache"] boolValue];
        NSMutableArray<NSDictionary *> *clean = [NSMutableArray array];
        for (id m in mats) if ([m isKindOfClass:[NSDictionary class]]) [clean addObject:(NSDictionary *)m];
        self_.materials = clean;
        [self_ refreshAllCards];
    }];
}

- (void)reloadSummary:(BOOL)refresh {
    if (!_artistName.length || ![RLPCoreClient shared].started) {
        self.summaryDone = YES;
        self.summaryFailed = YES;
        [self refreshAllCards];
        return;
    }
    const NSUInteger seq = self.summarySeq;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:[self summaryURL:refresh]
                         completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (seq != self_.summarySeq) return;

        if (!json) {
            self_.summaryDone = YES;
            self_.summaryFailed = YES;
            self_.summaryFields = @{};
            self_.summaryCitations = @[];
            self_.summarySections = @[];
            self_.summaryFailText = [self_ summaryFailLine:RLPTr(@"超时")];
            [self_ refreshAllCards];
            return;
        }
        // pending = 异步 job 未完成：按 retryAfterMs 轮询同一 URL，不当失败；总超时 120s
        if ([json[@"pending"] respondsToSelector:@selector(boolValue)] && [json[@"pending"] boolValue]) {
            if (self_.summaryPollCount++ >= 300) {      // 400ms × 300 = 120s
                self_.summaryDone = YES;
                self_.summaryFailed = YES;
                self_.summaryFailText = [self_ summaryFailLine:RLPTr(@"超时")];
                [self_ refreshAllCards];
                return;
            }
            double delay = 400.0;
            id ra = json[@"retryAfterMs"];
            if ([ra respondsToSelector:@selector(doubleValue)] &&
                [ra doubleValue] >= 150 && [ra doubleValue] <= 2000) {
                delay = [ra doubleValue];
            }
            const NSUInteger keep = seq;
            __weak __typeof__(self) w2 = weakSelf;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_MSEC)),
                           dispatch_get_main_queue(), ^{
                __typeof__(self) s2 = w2;
                if (!s2 || keep != s2.summarySeq) return;
                [s2 reloadSummary:NO];
            });
            self_.summaryDone = NO;
            [self_ refreshAllCards];
            return;
        }
        self_.summaryPollCount = 0;
        self_.summaryDone = YES;

        if ([json[@"insufficient"] boolValue]) {
            self_.summaryFields = @{};
            self_.summaryCitations = @[];
            self_.summarySections = @[];
            self_.summaryFailed = YES;
            self_.summaryFailText = RLPTr(@"暂无可确认的资料");
            [self_ refreshAllCards];
            return;
        }
        if (![json[@"ok"] boolValue] && ![json[@"fields"] isKindOfClass:[NSDictionary class]]) {
            self_.summaryFailed = YES;
            self_.summaryFields = @{};
            self_.summaryCitations = @[];
            self_.summarySections = @[];
            id err = json[@"error"];
            NSString *errText = [err isKindOfClass:[NSString class]] && [err length] ? err : RLPTr(@"超时");
            self_.summaryFailText = [self_ summaryFailLine:errText];
            [self_ refreshAllCards];
            return;
        }
        self_.summaryFailed = NO;
        self_.summaryFailText = nil;
        self_.summaryFields = [json[@"fields"] isKindOfClass:[NSDictionary class]] ? json[@"fields"] : @{};
        self_.summaryCitations = [json[@"citations"] isKindOfClass:[NSArray class]] ? json[@"citations"] : @[];
        self_.summarySections = [json[@"sections"] isKindOfClass:[NSArray class]] ? json[@"sections"] : @[];
        [self_ refreshAllCards];
    }];
}

#pragma mark - 头像（三层回退：/api/artist/image → /api/lib/cover → 首字母）

- (void)loadAvatarFallbackCoverIfNeeded {
    if (self.avatarLoadedFromArtistImage || !self.avatarArtistImageFailed) return;
    if (![RLPCoreClient shared].started || self.avatarFallbackSeq == self.avatarSeq) return;
    NSString *fallbackKey = nil;
    for (RLPAlbum *a in self.albums) {
        if (a.hasCover && a.key.length) { fallbackKey = a.key; break; }
    }
    if (!fallbackKey.length) return;
    const NSUInteger seq = self.avatarSeq;
    self.avatarFallbackSeq = seq;
    NSString *coverURL = [NSString stringWithFormat:@"/api/lib/cover?k=%@", RLPEnc(fallbackKey)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getData:coverURL completion:^(NSData * _Nullable cdata) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.avatarSeq || self_.avatarLoadedFromArtistImage) return;
        NSImage *cimg = cdata.length ? [[NSImage alloc] initWithData:cdata] : nil;
        if (cimg) {
            self_.avatarImage.image = cimg;
            self_.avatarImage.hidden = NO;
            self_.initialLabel.hidden = YES;
        }
    }];
}

- (void)loadAvatar {
    if (!self.artistName.length || ![RLPCoreClient shared].started) return;
    const NSUInteger seq = ++self.avatarSeq;
    self.avatarArtistImageFailed = NO;
    self.avatarLoadedFromArtistImage = NO;
    self.avatarFallbackSeq = 0;
    NSString *url = [NSString stringWithFormat:@"/api/artist/image?who=%@", RLPEnc(self.artistName)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getData:url completion:^(NSData * _Nullable data) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.avatarSeq) return;
        NSImage *img = data.length ? [[NSImage alloc] initWithData:data] : nil;
        if (img) {
            self_.avatarLoadedFromArtistImage = YES;
            self_.avatarImage.image = img;
            self_.avatarImage.hidden = NO;
            self_.initialLabel.hidden = YES;
            return;
        }
        self_.avatarArtistImageFailed = YES;
        self_.avatarImage.image = nil;
        self_.avatarImage.hidden = YES;
        self_.initialLabel.hidden = NO;
        [self_ loadAvatarFallbackCoverIfNeeded];
    }];
}

#pragma mark - 专辑网格取数（沿用原逻辑：按 RLPSplitArtistNames 归属）

- (void)reloadData {
    if (![RLPCoreClient shared].started) {
        [self.albums removeAllObjects];
        self.albumCount = 0;
        self.totalTracks = 0;
        self.totalDuration = 0;
        [self setSubtitle:RLPTr(@"核心未启动")];
        self.emptyLabel.stringValue = RLPTr(@"核心未启动");
        self.emptyLabel.hidden = NO;
        [self.collection reloadData];
        [self relayoutPage];
        return;
    }

    NSString *target = [self.artistName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (target.length == 0) target = RLPTr(@"未知艺术家");

    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/lib/albums" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            self_.loaded = YES;
            [self_ setSubtitle:RLPTr(@"读取失败")];
            self_.emptyLabel.stringValue = RLPTr(@"读取失败");
            self_.emptyLabel.hidden = NO;
            [self_ relayoutPage];
            return;
        }
        self_.loaded = YES;
        NSArray<RLPAlbum *> *all = [RLPAlbum albumsFromJSON:json];
        NSMutableArray<RLPAlbum *> *filtered = [NSMutableArray array];
        NSInteger totalTracks = 0;
        double totalDuration = 0.0;
        for (RLPAlbum *a in all) {
            BOOL contains = NO;
            for (NSString *art in RLPSplitArtistNames(a.artist)) {
                if ([art localizedCaseInsensitiveCompare:target] == NSOrderedSame) { contains = YES; break; }
            }
            if (!contains) continue;
            [filtered addObject:a];
            totalTracks += a.trackCount;
            totalDuration += a.duration;
        }
        [filtered sortUsingComparator:^NSComparisonResult(RLPAlbum *a, RLPAlbum *b) {
            if (a.year != b.year) return a.year > b.year ? NSOrderedAscending : NSOrderedDescending;
            return [a.name localizedCaseInsensitiveCompare:b.name];
        }];
        [self_.albums setArray:filtered];
        self_.albumCount = (NSInteger)filtered.count;
        self_.totalTracks = totalTracks;
        self_.totalDuration = totalDuration;
        [self_ loadAvatarFallbackCoverIfNeeded];

        if (filtered.count == 0) {
            [self_ setSubtitle:[NSString stringWithFormat:@"0 %@", RLPTr(@"张专辑")]];
            self_.emptyLabel.stringValue = RLPTr(@"这个艺术家还没有专辑");
            self_.emptyLabel.hidden = NO;
        } else {
            [self_ setSubtitle:[NSString stringWithFormat:@"%ld %@ · %ld %@",
                                (long)filtered.count, RLPTr(@"张专辑"),
                                (long)totalTracks, RLPTr(@"首")]];
            self_.emptyLabel.stringValue = @"";
            self_.emptyLabel.hidden = YES;
        }
        [self_.collection reloadData];
        [self_ relayoutPage];
    }];
}

#pragma mark - 事件

- (void)onBack:(id)sender { (void)sender; RLPRequestBack(); }

- (void)onScrollToAlbums:(id)sender {
    (void)sender;
    if (!_pageScroll) return;
    const NSRect f = _collection.frame;
    [_pageScroll.contentView scrollToPoint:NSMakePoint(0, MAX(0.0, NSMinY(f) - 12.0))];
    [_pageScroll reflectScrolledClipView:_pageScroll.contentView];
}

- (void)onRefresh:(id)sender {
    (void)sender;
    self.bioExpanded = NO;
    // 「刷新资料」= web bArtistRefresh：带 refresh=1 重新取两条通道
    ++self.knowledgeSeq;
    ++self.summarySeq;
    self.knowledgeDone = NO;
    self.knowledgeFailed = NO;
    self.knowledgeFromCache = NO;
    self.summaryDone = NO;
    self.summaryFailed = NO;
    self.summaryFailText = nil;
    self.summaryPollCount = 0;
    self.materials = @[];
    self.summaryFields = @{};
    self.summaryCitations = @[];
    self.summarySections = @[];
    [self refreshAllCards];
    [self reloadKnowledge:YES];
    [self reloadSummary:YES];
}

- (void)onRetry:(id)sender { [self onRefresh:sender]; }

- (void)onToggleBio:(id)sender {
    (void)sender;
    self.bioExpanded = !self.bioExpanded;
    [self relayoutPage];
}

- (void)onCopyChip:(NSButton *)sender {
    NSString *u = sender.toolTip ?: @"";
    if (!u.length) return;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:u forType:NSPasteboardTypeString];
    RLPToast(RLPTr(@"已复制来源链接"));
}

- (void)onCopySourceURL:(NSButton *)sender { [self onCopyChip:sender]; }

- (void)onDoubleClick:(NSClickGestureRecognizer *)g {
    NSPoint p = [g locationInView:self.collection];
    NSIndexPath *ip = [self.collection indexPathForItemAtPoint:p];
    if (!ip || ip.item < 0 || ip.item >= (NSInteger)self.albums.count) return;
    RLPAlbum *album = self.albums[(NSUInteger)ip.item];
    if (album.key.length) RLPRequestOpenAlbum(album.key);
}

#pragma mark - 主题 / 语言

- (void)applyTheme {
    [super applyTheme];
    RLPTheme *t = [RLPTheme current];
    self.avatarView.layer.backgroundColor = t.cvBg.CGColor;
    self.initialLabel.textColor = t.phText;
    self.emptyLabel.textColor = t.mut;
    for (NSView *card in @[ _cardSummary ?: (id)[NSNull null], _cardBio ?: (id)[NSNull null],
                            _cardStyles ?: (id)[NSNull null], _cardSources ?: (id)[NSNull null] ]) {
        if (![card isKindOfClass:[NSView class]]) continue;
        card.layer.borderColor = t.line.CGColor;
        card.layer.backgroundColor = t.bg2.CGColor;
    }
    // 文字颜色随主题重刷（reload 会重建字段行/芯片，颜色自然带上）
    if (!_doc) { /* 未建树，无需刷色 */ }
    else {
        _eyebrowLabel.textColor = t.mut2;
        _nameLabel.textColor = t.text;
        _subLabel.textColor = t.mut;
        _statsLabel.textColor = t.mut;
        _eyebrowLabel.attributedStringValue = RLPArtistAttr(RLPTr(@"ARTIST · 艺术家资料"),
            [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold], t.mut2, 1.4, 0);
        _nameLabel.attributedStringValue = RLPArtistAttr(_artistName.length ? _artistName : RLPTr(@"未知艺术家"),
            [NSFont systemFontOfSize:26 weight:NSFontWeightBold], t.text, -0.4, 0);
        for (NSButton *b in @[ _btnAlbums, _btnRefresh, _btnBackList ]) {
            if (![b isKindOfClass:[NSButton class]]) continue;
            b.attributedTitle = RLPArtistAttr(b.title, [NSFont systemFontOfSize:12], t.text, 0, 0);
        }
    }
    [self.collection reloadData];
    [self refreshAllCards];
    [self.view setNeedsLayout:YES];
}

- (void)applyLanguage {
    self.pageTitle = self.artistName.length ? self.artistName : RLPTr(@"艺术家");
    if (!self.isViewLoaded) return;
    RLPTheme *t = [RLPTheme current];
    _backBtn.title = RLPTr(@"返回艺术家列表");
    _backBtn.image = [NSImage imageWithSystemSymbolName:@"chevron.left"
                               accessibilityDescription:RLPTr(@"返回艺术家列表")];
    _eyebrowLabel.attributedStringValue = RLPArtistAttr(RLPTr(@"ARTIST · 艺术家资料"),
        [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold], t.mut2, 1.4, 0);
    if (!self.artistName.length) {
        _nameLabel.attributedStringValue = RLPArtistAttr(RLPTr(@"未知艺术家"),
            [NSFont systemFontOfSize:26 weight:NSFontWeightBold], t.text, -0.4, 0);
    }
    _btnAlbums.attributedTitle = RLPArtistAttr(RLPTr(@"查看专辑"), [NSFont systemFontOfSize:12], t.text, 0, 0);
    _btnRefresh.attributedTitle = RLPArtistAttr(RLPTr(@"刷新资料"), [NSFont systemFontOfSize:12], t.text, 0, 0);
    _btnBackList.attributedTitle = RLPArtistAttr(RLPTr(@"返回列表"), [NSFont systemFontOfSize:12], t.text, 0, 0);
    _summaryTitle.attributedStringValue = RLPArtistAttr(RLPTr(@"AI 整理"),
        [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold], t.mut2, 1.0, 0);
    _bioTitle.attributedStringValue = RLPArtistAttr(RLPTr(@"简介"),
        [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold], t.mut2, 1.0, 0);
    _sourcesTitle.attributedStringValue = RLPArtistAttr(RLPTr(@"资料来源"),
        [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold], t.mut2, 1.0, 0);
    _summaryRetry.attributedTitle = RLPArtistAttr(RLPTr(@"重试获取"), [NSFont systemFontOfSize:12], t.text, 0, 0);
    if (![RLPCoreClient shared].started && !self.loaded) {
        [self setSubtitle:RLPTr(@"核心未启动")];
        self.emptyLabel.stringValue = RLPTr(@"核心未启动");
    } else if (self.loaded && self.albums.count == 0) {
        [self setSubtitle:[NSString stringWithFormat:@"0 %@", RLPTr(@"张专辑")]];
        self.emptyLabel.stringValue = RLPTr(@"这个艺术家还没有专辑");
    }
    // 重建依赖 RLPTr 的卡片内容
    [self refreshAllCards];
    NSSet<NSIndexPath *> *sel = [self.collection.selectionIndexPaths copy];
    NSPoint origin = _pageScroll ? _pageScroll.contentView.bounds.origin : NSZeroPoint;
    [self.collection reloadData];
    if (sel.count) self.collection.selectionIndexPaths = sel;
    if (_pageScroll) {
        [_pageScroll.contentView scrollToPoint:origin];
        [_pageScroll reflectScrolledClipView:_pageScroll.contentView];
    }
    [self.view setNeedsLayout:YES];
}

#pragma mark - NSCollectionViewDataSource

- (NSInteger)collectionView:(NSCollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    (void)collectionView; (void)section;
    return (NSInteger)self.albums.count;
}

- (NSCollectionViewItem *)collectionView:(NSCollectionView *)collectionView
        itemForRepresentedObjectAtIndexPath:(NSIndexPath *)indexPath {
    RLPArtistAlbumItem *item = (RLPArtistAlbumItem *)[collectionView makeItemWithIdentifier:kArtistAlbumItemID
                                                                            forIndexPath:indexPath];
    if (indexPath.item >= 0 && indexPath.item < (NSInteger)self.albums.count) {
        [item setAlbum:self.albums[(NSUInteger)indexPath.item]];
    }
    return item;
}

@end
