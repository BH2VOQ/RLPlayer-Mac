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
#import <QuartzCore/QuartzCore.h>
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

/// 固定宿主的专辑网格布局：AppKit 自带的 NSCollectionViewFlowLayout 在
/// NSCollectionView 并非 enclosingScrollView.documentView（而是嵌在有左右留白的 _doc 里）时，
/// 滚动触发重排会错拿 enclosingScrollView.contentView.bounds.size.width 当版心，
/// 导致间距瞬间被拉宽、最右列溢出进滚动条。这里严格只按 collectionView.bounds 排布，
/// 并在纵向滚动时保持横向位置恒定，同时仍继承 NSCollectionViewFlowLayout 以兼容既有接口。
@interface RLPArtistAlbumFlowLayout : NSCollectionViewFlowLayout
@end

@implementation RLPArtistAlbumFlowLayout {
    NSMutableArray<NSCollectionViewLayoutAttributes *> *_cachedAttrs;
    NSSize _cachedContentSize;
    CGFloat _preparedWidth;
}

- (void)prepareLayout {
    if (!_cachedAttrs) _cachedAttrs = [NSMutableArray array];
    [_cachedAttrs removeAllObjects];

    NSCollectionView *cv = self.collectionView;
    const CGFloat boundsW = cv ? NSWidth(cv.bounds) : 0.0;
    _preparedWidth = boundsW;
    const NSInteger count = (cv && cv.numberOfSections > 0) ? [cv numberOfItemsInSection:0] : 0;
    const NSEdgeInsets ins = self.sectionInset;
    const CGFloat availW = MAX(0.0, boundsW - ins.left - ins.right);
    const CGFloat itemW = MAX(1.0, self.itemSize.width);
    const CGFloat itemH = MAX(1.0, self.itemSize.height);
    const CGFloat minGapX = MAX(0.0, self.minimumInteritemSpacing);
    const CGFloat gapY = MAX(0.0, self.minimumLineSpacing);

    if (count <= 0 || boundsW < 1.0) {
        _cachedContentSize = NSMakeSize(boundsW, 0.0);
        return;
    }

    NSInteger cols = 1;
    if (availW >= itemW) {
        cols = MAX(1, (NSInteger)floor((availW + minGapX + 0.01) / (itemW + minGapX)));
    }
    const CGFloat usedW = (CGFloat)cols * itemW + (CGFloat)(cols - 1) * minGapX;
    const CGFloat extra = (cols > 1 && count >= cols) ? MAX(0.0, availW - usedW) : 0.0;
    const CGFloat actualGapX = (cols > 1) ? (minGapX + extra / (CGFloat)(cols - 1)) : 0.0;
    const CGFloat maxItemX = ins.left + MAX(0.0, availW - itemW);

    for (NSInteger i = 0; i < count; ++i) {
        const NSInteger row = i / cols;
        const NSInteger col = i % cols;
        CGFloat x = ins.left;
        if (cols > 1 && col > 0) {
            if (col == cols - 1 && count >= cols && availW >= itemW) {
                x = ins.left + availW - itemW;
            } else {
                x = ins.left + round(((CGFloat)col * (itemW + actualGapX)) * 2.0) * 0.5;
                if (x > maxItemX) x = maxItemX;
            }
        }
        const CGFloat y = ins.top + (CGFloat)row * (itemH + gapY);
        NSIndexPath *ip = [NSIndexPath indexPathForItem:i inSection:0];
        NSCollectionViewLayoutAttributes *a =
            [NSCollectionViewLayoutAttributes layoutAttributesForItemWithIndexPath:ip];
        a.frame = NSMakeRect(x, y, itemW, itemH);
        [_cachedAttrs addObject:a];
    }

    const NSInteger rows = (count + cols - 1) / cols;
    const CGFloat totalH = ins.top + ins.bottom + (CGFloat)rows * itemH + (CGFloat)MAX(0, rows - 1) * gapY;
    _cachedContentSize = NSMakeSize(boundsW, totalH);
}

- (NSSize)collectionViewContentSize {
    return _cachedContentSize;
}

- (NSArray<NSCollectionViewLayoutAttributes *> *)layoutAttributesForElementsInRect:(NSRect)rect {
    NSMutableArray<NSCollectionViewLayoutAttributes *> *res = [NSMutableArray array];
    for (NSCollectionViewLayoutAttributes *a in _cachedAttrs) {
        if (NSIntersectsRect(a.frame, rect)) {
            [res addObject:a];
        }
    }
    return res;
}

- (NSCollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath {
    if (!indexPath || indexPath.section != 0 || indexPath.item < 0 ||
        indexPath.item >= (NSInteger)_cachedAttrs.count) {
        return nil;
    }
    return _cachedAttrs[(NSUInteger)indexPath.item];
}

- (BOOL)shouldInvalidateLayoutForBoundsChange:(NSRect)newBounds {
    return fabs(NSWidth(newBounds) - _preparedWidth) > 0.5;
}

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

static NSAttributedString *RLPArtistSingleLineAttr(NSString *s, NSFont *font, NSColor *color,
                                                   CGFloat kern, NSTextAlignment alignment) {
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    ps.alignment = alignment;
    NSMutableDictionary *a = [NSMutableDictionary dictionary];
    if (font) a[NSFontAttributeName] = font;
    if (color) a[NSForegroundColorAttributeName] = color;
    a[NSParagraphStyleAttributeName] = ps;
    if (fabs(kern) > 0.001) a[NSKernAttributeName] = @(kern);
    return [[NSAttributedString alloc] initWithString:s ?: @"" attributes:a];
}

/// 多行文本高度（与显示侧同一套 attributes 量，减 4pt 匹配 NSTextFieldCell 内边距，避免最末行被裁切）。
static CGFloat RLPArtistTextH(NSString *s, NSFont *font, CGFloat width, CGFloat lineSpacing) {
    if (!s.length || !font || width < 1.0) return 0.0;
    const CGFloat wrapW = MAX(1.0, width - 4.0);
    NSRect br = [s boundingRectWithSize:NSMakeSize(wrapW, CGFLOAT_MAX)
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
    l.selectable = NO;
    l.translatesAutoresizingMaskIntoConstraints = YES;
    l.autoresizingMask = NSViewNotSizable;
    return l;
}

static NSTextField *RLPArtistMakeSelectableLabel(NSString *ident) {
    NSTextField *l = RLPArtistMakeLabel(ident);
    l.selectable = YES;
    l.allowsEditingTextAttributes = YES;
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

/// web `.btn` / `.cite-chip` 的底座：精确居中自绘圆角芯片/动作按钮。
@interface RLPArtistChip : NSButton
@property (nonatomic, assign) BOOL filled;         // YES = background:var(--hov) + 边框
@property (nonatomic, assign) BOOL accentFill;     // YES = 主色渐变实心动作按钮
@property (nonatomic, assign) BOOL ghost;          // YES = 无静态边框（仅悬停出底），用于顶栏返回面包屑
@property (nonatomic, assign) BOOL playTriangle;   // YES = 文字左侧自绘矢量播放三角（同 RLPAlbumButton）
@property (nonatomic, copy, nullable) NSString *leadingSymbol;
@property (nonatomic, assign) CGFloat radius;      // 默认 8.0
@property (nonatomic, assign) CGFloat padX;        // 默认 13.0（两侧对称内边距）
@property (nonatomic, strong, nullable) NSColor *chipTextColor;
@property (nonatomic, strong, nullable) NSFont *chipFont;
- (void)setText:(NSString *)text color:(NSColor *)color font:(NSFont *)font;
- (CGFloat)preferredWidth;
@end

@implementation RLPArtistChip {
    BOOL _hovered;
    NSTrackingArea *_hoverArea;
}
- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.bordered = NO;
        self.bezelStyle = NSBezelStyleRegularSquare;
        self.alignment = NSTextAlignmentCenter;
        self.wantsLayer = NO;
        self.radius = 8.0;
        self.padX = 13.0;
    }
    return self;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_hoverArea) [self removeTrackingArea:_hoverArea];
    _hoverArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                              options:(NSTrackingMouseEnteredAndExited |
                                                       NSTrackingActiveInKeyWindow |
                                                       NSTrackingInVisibleRect)
                                                owner:self
                                             userInfo:nil];
    [self addTrackingArea:_hoverArea];
}
- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}
- (void)mouseEntered:(NSEvent *)event { (void)event; _hovered = YES; [self setNeedsDisplay:YES]; }
- (void)mouseExited:(NSEvent *)event { (void)event; _hovered = NO; [self setNeedsDisplay:YES]; }

- (void)setText:(NSString *)text color:(NSColor *)color font:(NSFont *)font {
    NSString *s = text ?: @"";
    NSFont *f = font ?: [NSFont systemFontOfSize:12];
    _chipFont = f;
    _chipTextColor = color;
    self.font = f;
    self.title = s;
    self.alignment = NSTextAlignmentCenter;
    [self setNeedsDisplay:YES];
}

- (CGFloat)iconWidth {
    if (self.playTriangle) return 8.0;
    if (self.leadingSymbol.length || self.image) return 11.0;
    return 0.0;
}

- (CGFloat)iconGap {
    return ([self iconWidth] > 0.0) ? (self.playTriangle ? 7.0 : 5.0) : 0.0;
}

- (CGFloat)preferredWidth {
    NSFont *f = _chipFont ?: (self.font ?: [NSFont systemFontOfSize:12]);
    CGFloat tw = ceil([(self.title ?: @"") sizeWithAttributes:@{ NSFontAttributeName: f }].width);
    CGFloat iw = [self iconWidth];
    CGFloat ig = (self.title.length > 0 && iw > 0.0) ? [self iconGap] : 0.0;
    CGFloat px = (self.padX > 0.0) ? self.padX : 12.0;
    return MAX(34.0, ceil(tw + iw + ig + px * 2.0));
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    RLPTheme *t = [RLPTheme current];
    const NSRect b = self.bounds;
    if (NSWidth(b) < 2.0 || NSHeight(b) < 2.0) return;

    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(b, 0.5, 0.5)
                                                      xRadius:self.radius yRadius:self.radius];
    const BOOL pressed = self.isHighlighted;
    if (self.accentFill) {
        NSColor *c0 = (_hovered || pressed) ? t.accent2 : t.accent;
        NSColor *c1 = t.accent2;
        NSGradient *grad = [[NSGradient alloc] initWithStartingColor:c0 endingColor:c1];
        [grad drawInBezierPath:p angle:-90];
    } else if (self.ghost) {
        if (_hovered || pressed) {
            [(pressed ? t.hov2 : t.hov) setFill];
            [p fill];
            [t.line setStroke];
            p.lineWidth = 1.0;
            [p stroke];
        }
    } else {
        if (pressed) {
            [t.hov2 setFill];
            [p fill];
        } else if (self.filled) {
            [(_hovered ? t.hov2 : t.hov) setFill];
            [p fill];
        } else if (_hovered) {
            [t.hov setFill];
            [p fill];
        }
        [(_hovered || pressed ? t.line2 : t.line) setStroke];
        p.lineWidth = 1.0;
        [p stroke];
    }

    NSFont *f = _chipFont ?: (self.font ?: [NSFont systemFontOfSize:12]);
    NSColor *fg = self.accentFill ? NSColor.whiteColor : (_chipTextColor ?: t.text);
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    ps.alignment = NSTextAlignmentLeft;
    NSDictionary *attrs = @{
        NSFontAttributeName: f,
        NSForegroundColorAttributeName: fg,
        NSParagraphStyleAttributeName: ps
    };
    NSString *title = self.title ?: @"";
    NSSize tsz = [title sizeWithAttributes:attrs];
    const CGFloat iw = [self iconWidth];
    const CGFloat ig = (title.length > 0 && iw > 0.0) ? [self iconGap] : 0.0;
    const CGFloat pad = MAX(4.0, self.padX);
    const CGFloat maxContentW = MAX(4.0, NSWidth(b) - pad * 2.0);
    const CGFloat textW = MIN(ceil(tsz.width), MAX(0.0, maxContentW - iw - ig));
    const CGFloat totalW = iw + ig + textW;
    const CGFloat startX = floor((NSWidth(b) - totalW) * 0.5);

    if (self.playTriangle) {
        const CGFloat th = 10.0;
        const CGFloat ty = round((NSHeight(b) - th) * 0.5);
        NSBezierPath *tri = [NSBezierPath bezierPath];
        [tri moveToPoint:NSMakePoint(startX, ty)];
        [tri lineToPoint:NSMakePoint(startX + iw, ty + th * 0.5)];
        [tri lineToPoint:NSMakePoint(startX, ty + th)];
        [tri closePath];
        [fg setFill];
        [tri fill];
    } else if (iw > 0.0) {
        NSImage *sym = self.leadingSymbol.length
            ? [NSImage imageWithSystemSymbolName:self.leadingSymbol accessibilityDescription:title]
            : self.image;
        if (sym) {
            if (@available(macOS 11.0, *)) {
                NSImageSymbolConfiguration *cfg =
                    [NSImageSymbolConfiguration configurationWithPointSize:MAX(10.0, f.pointSize - 0.5)
                                                                    weight:NSFontWeightMedium];
                NSImage *configured = [sym imageWithSymbolConfiguration:cfg];
                if (configured) sym = configured;
            }
            NSColor *symColor = self.ghost ? t.mut : fg;
            NSImage *tinted = [NSImage imageWithSize:NSMakeSize(iw, iw) flipped:NO drawingHandler:^BOOL(NSRect dst) {
                [sym drawInRect:dst fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                       fraction:1.0 respectFlipped:NO hints:nil];
                [symColor set];
                NSRectFillUsingOperation(dst, NSCompositingOperationSourceAtop);
                return YES;
            }];
            const CGFloat iy = round((NSHeight(b) - iw) * 0.5);
            [tinted drawInRect:NSMakeRect(startX, iy, iw, iw)
                      fromRect:NSZeroRect
                     operation:NSCompositingOperationSourceOver
                      fraction:1.0
                respectFlipped:YES
                         hints:nil];
        }
    }

    if (title.length > 0 && textW > 0.5) {
        const CGFloat tx = startX + iw + ig;
        const CGFloat th = ceil(tsz.height);
        const CGFloat ty = round((NSHeight(b) - th) * 0.5);
        [title drawInRect:NSMakeRect(tx, ty, textW + 2.0, th) withAttributes:attrs];
    }
}
@end

static CGFloat RLPArtistChipW(NSString *title, NSFont *font) {
    CGFloat w = ceil([(title ?: @"") sizeWithAttributes:@{ NSFontAttributeName: font ?: [NSFont systemFontOfSize:12] }].width);
    return MAX(34.0, w + 26.0);
}

static CGFloat RLPArtistChipWidth(NSButton *btn) {
    if ([btn isKindOfClass:[RLPArtistChip class]]) {
        return [(RLPArtistChip *)btn preferredWidth];
    }
    return RLPArtistChipW(btn.title, btn.font);
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
        _value = RLPArtistMakeSelectableLabel(@"efrow.value");
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
    // 与 web 的 `repeat(auto-fill, minmax(178px, 1fr))` 同口径，上限 4 列避免超宽屏拆得太碎。
    NSInteger cols = (NSInteger)floor((w + colGap) / (kArtistFieldMinW + colGap));
    cols = MAX(1, MIN(cols, 4));
    {
        NSInteger visible = 0;
        for (NSUInteger i = 0; i < _items.count; ++i) if (!_items[i].hidden) ++visible;
        if (visible > 0) cols = MIN(cols, MAX(1, visible));
    }
    _columnCount = cols;
    const CGFloat naturalColW = MAX(1.0, (w - colGap * (CGFloat)(cols - 1)) / (CGFloat)MAX(1, cols));
    // 宽屏且轨道较宽时把默认列宽限制在 300pt，避免仅有 2–3 个短字段时中间裂出 700pt+ 大空白；
    // 同时允许每行最后一个短字段向右借用余宽，让稍长的代表作品列表能单行展示。
    const CGFloat trackW = (cols > 1 && w > 760.0) ? MIN(naturalColW, 300.0) : naturalColW;

    CGFloat y = 0.0, rowH = 0.0;
    NSInteger col = 0;
    BOOL placed = NO;
    for (NSUInteger i = 0; i < _items.count; ++i) {
        RLPArtistFieldRow *row = _items[i];
        if (row.hidden) continue;
        const BOOL wide = _wides[i].boolValue;
        const BOOL full = wide || cols <= 1;
        if (wide && col > 0) { y += rowH + rowGap; col = 0; rowH = 0.0; }
        const CGFloat x = full ? 0.0 : (CGFloat)col * (trackW + colGap);
        BOOL nextIsWideOrEnd = YES;
        for (NSUInteger j = i + 1; j < _items.count; ++j) {
            if (_items[j].hidden) continue;
            nextIsWideOrEnd = _wides[j].boolValue;
            break;
        }
        const BOOL lastOnRow = !full && ((col + 1 >= cols) || nextIsWideOrEnd);
        CGFloat itemW = full ? w : trackW;
        if (lastOnRow && trackW < naturalColW) {
            itemW = MIN(MAX(1.0, w - x), MAX(trackW, 640.0));
        } else {
            itemW = MIN(MAX(1.0, w - x), itemW);
        }
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

@interface RLPArtistStyleBadgeView : RLPArtistFlippedView
@property (nonatomic, strong, readonly) NSTextField *label;
@property (nonatomic, strong, readonly) NSFont *badgeFont;
- (instancetype)initWithTitle:(NSString *)title;
- (CGFloat)preferredWidth;
@end

@implementation RLPArtistStyleBadgeView
- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        RLPTheme *t = [RLPTheme current];
        self.identifier = @"artist.style.badge";
        self.wantsLayer = YES;
        self.layer.cornerRadius = 6.0;
        self.layer.masksToBounds = YES;
        self.layer.backgroundColor = t.accentWeak.CGColor;
        _badgeFont = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        _label = [NSTextField labelWithString:title ?: @""];
        _label.font = _badgeFont;
        _label.textColor = t.accentText;
        _label.attributedStringValue = RLPArtistSingleLineAttr(title ?: @"", _badgeFont, t.accentText, 0, NSTextAlignmentCenter);
        _label.alignment = NSTextAlignmentCenter;
        _label.maximumNumberOfLines = 1;
        _label.lineBreakMode = NSLineBreakByTruncatingTail;
        _label.drawsBackground = NO;
        _label.wantsLayer = NO;
        [self addSubview:_label];
    }
    return self;
}
- (CGFloat)preferredWidth {
    NSString *s = _label.stringValue ?: @"";
    CGFloat w = ceil([s sizeWithAttributes:@{ NSFontAttributeName: _badgeFont }].width);
    return MAX(32.0, w + 20.0);
}
- (void)layout {
    [super layout];
    const CGFloat h = NSHeight(self.bounds);
    const CGFloat w = NSWidth(self.bounds);
    const CGFloat lh = ceil([_label sizeThatFits:NSMakeSize(MAX(1.0, w - 12.0), CGFLOAT_MAX)].height);
    const CGFloat ly = MAX(0.0, round((h - lh) * 0.5));
    _label.frame = NSMakeRect(6.0, ly, MAX(0.0, w - 12.0), lh);
}
@end

/// 资料来源的一行（web `.trow.source-row`）：整行 hov 底 + 左侧「来源徽章」药丸。
///
/// 药丸底必须由**行视图**在文字之前画，不能挂在徽章 label 的 layer 上：
/// NSTextField 的 layer.backgroundColor 会把 cell 随后画的文字盖掉，
/// 画面上只剩一条粉色色块（2026-11-21 离屏截图实测到的真实缺陷）。
@interface RLPArtistSourceRow : RLPArtistFlippedView
/// 徽章药丸底（真实子视图，一直在文字 label 之下）。
@property (nonatomic, strong, readonly) NSView *badgePill;
@end

@implementation RLPArtistSourceRow {
    NSTrackingArea *_hoverArea;
}
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
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_hoverArea) [self removeTrackingArea:_hoverArea];
    _hoverArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                              options:(NSTrackingMouseEnteredAndExited |
                                                       NSTrackingActiveInKeyWindow |
                                                       NSTrackingInVisibleRect)
                                                owner:self
                                             userInfo:nil];
    [self addTrackingArea:_hoverArea];
}
- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    RLPTheme *t = [RLPTheme current];
    self.layer.backgroundColor = t.hov2.CGColor;
    self.layer.borderColor = t.line.CGColor;
}
- (void)mouseExited:(NSEvent *)event {
    (void)event;
    RLPTheme *t = [RLPTheme current];
    self.layer.backgroundColor = t.hov.CGColor;
    self.layer.borderColor = t.hairline.CGColor;
}
@end

@class RLPArtistAlbumItem;
@interface RLPArtistAlbumCardView : NSView
@property (nonatomic, weak) RLPArtistAlbumItem *item;
@property (nonatomic, strong) NSTrackingArea *hoverArea;
@end

@interface RLPArtistAlbumItem : NSCollectionViewItem
@property (nonatomic, strong) NSImageView *coverView;
@property (nonatomic, strong) NSTextField *placeholderLabel;
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSTextField *yearLabel;
@property (nonatomic, strong) NSButton *playBadge;
@property (nonatomic, copy) NSString *albumKey;
- (void)setAlbum:(RLPAlbum *)album;
- (void)cardHoverChanged:(BOOL)hovered;
- (void)applyTheme;
@end

@implementation RLPArtistAlbumCardView
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_hoverArea) [self removeTrackingArea:_hoverArea];
    _hoverArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                              options:(NSTrackingMouseEnteredAndExited |
                                                       NSTrackingActiveAlways |
                                                       NSTrackingInVisibleRect)
                                                owner:self
                                             userInfo:nil];
    [self addTrackingArea:_hoverArea];
}
- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}
- (void)mouseEntered:(NSEvent *)event { (void)event; [self.item cardHoverChanged:YES]; }
- (void)mouseExited:(NSEvent *)event { (void)event; [self.item cardHoverChanged:NO]; }
@end

@implementation RLPArtistAlbumItem { BOOL _hovered; }

- (void)loadView {
    RLPTheme *t = [RLPTheme current];
    RLPArtistAlbumCardView *v = [[RLPArtistAlbumCardView alloc] initWithFrame:NSMakeRect(0, 0, 168, 214)];
    v.item = self;
    v.wantsLayer = YES;
    v.layer.masksToBounds = NO;
    self.view = v;

    _coverView = [[RLPCoverImageView alloc] initWithFrame:NSZeroRect];
    _coverView.wantsLayer = YES;
    _coverView.layer.cornerRadius = 10;
    _coverView.layer.masksToBounds = YES;
    _coverView.layer.borderWidth = 1.0;
    _coverView.layer.borderColor = t.hairline.CGColor;
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

    _playBadge = [[NSButton alloc] initWithFrame:NSZeroRect];
    _playBadge.bordered = NO;
    _playBadge.imagePosition = NSImageOnly;
    _playBadge.imageScaling = NSImageScaleProportionallyDown;
    _playBadge.image = [NSImage imageWithSystemSymbolName:@"play.fill"
                                   accessibilityDescription:RLPTr(@"播放整张")];
    _playBadge.contentTintColor = NSColor.whiteColor;
    _playBadge.toolTip = RLPTr(@"播放整张");
    _playBadge.target = self;
    _playBadge.action = @selector(onPlayBadge:);
    _playBadge.identifier = @"artist.album.playbadge";
    _playBadge.wantsLayer = YES;
    _playBadge.layer.cornerRadius = 16;
    _playBadge.layer.backgroundColor = t.accent.CGColor;
    _playBadge.hidden = YES;
    _playBadge.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_playBadge];

    [NSLayoutConstraint activateConstraints:@[
        [_coverView.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [_coverView.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [_coverView.topAnchor constraintEqualToAnchor:v.topAnchor],
        [_coverView.heightAnchor constraintEqualToAnchor:_coverView.widthAnchor],
        [_placeholderLabel.centerXAnchor constraintEqualToAnchor:_coverView.centerXAnchor],
        [_placeholderLabel.centerYAnchor constraintEqualToAnchor:_coverView.centerYAnchor],
        [_playBadge.trailingAnchor constraintEqualToAnchor:_coverView.trailingAnchor constant:-8],
        [_playBadge.bottomAnchor constraintEqualToAnchor:_coverView.bottomAnchor constant:-8],
        [_playBadge.widthAnchor constraintEqualToConstant:32],
        [_playBadge.heightAnchor constraintEqualToConstant:32],
        [_nameLabel.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:2],
        [_nameLabel.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-2],
        [_nameLabel.topAnchor constraintEqualToAnchor:_coverView.bottomAnchor constant:8],
        [_yearLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_yearLabel.trailingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor],
        [_yearLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],
    ]];
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    _nameLabel.textColor = t.text;
    _yearLabel.textColor = t.mut;
    _placeholderLabel.textColor = t.mut;
    _coverView.layer.backgroundColor = t.bg2.CGColor;
    _playBadge.layer.backgroundColor = t.accent.CGColor;
    [self refreshHighlight];
}

- (void)refreshHighlight {
    RLPTheme *t = [RLPTheme current];
    const BOOL on = _hovered || self.selected;
    _coverView.layer.borderWidth = on ? 2.0 : 1.0;
    _coverView.layer.borderColor = on ? t.accent.CGColor : t.hairline.CGColor;
    self.view.layer.shadowOpacity = on ? 0.16 : 0.0;
    self.view.layer.shadowRadius = on ? 7 : 0;
    self.view.layer.shadowOffset = CGSizeMake(0, -2);
    self.view.layer.shadowColor = NSColor.blackColor.CGColor;
}

- (void)setSelected:(BOOL)selected { [super setSelected:selected]; [self refreshHighlight]; }
- (void)cardHoverChanged:(BOOL)hovered { _hovered = hovered; _playBadge.hidden = !hovered; [self refreshHighlight]; }
- (void)onPlayBadge:(id)sender { (void)sender; if (self.albumKey.length) RLPPlayAlbum(self.albumKey, 0); }

- (void)setAlbum:(RLPAlbum *)album {
    _hovered = NO;
    _playBadge.hidden = YES;
    self.albumKey = album.key ?: @"";
    self.nameLabel.stringValue = album.name.length ? album.name : (album.key.length ? album.key : @"");
    self.placeholderLabel.stringValue = album.name.length ? [album.name substringToIndex:1] : @"♪";

    NSMutableArray<NSString *> *metaParts = [NSMutableArray array];
    if (album.year > 0) [metaParts addObject:[NSString stringWithFormat:@"%ld", (long)album.year]];
    if (album.trackCount > 0) [metaParts addObject:[NSString stringWithFormat:@"%ld %@", (long)album.trackCount, RLPTr(@"首")]];
    if (album.sampleRate > 0) {
        NSString *sr = (album.sampleRate % 1000 == 0)
            ? [NSString stringWithFormat:@"%ldk", (long)(album.sampleRate / 1000)]
            : [NSString stringWithFormat:@"%.1fk", album.sampleRate / 1000.0];
        [metaParts addObject:(album.bits > 0 ? [NSString stringWithFormat:@"%@/%ld", sr, (long)album.bits] : sr)];
    } else if (album.duration > 0.5) {
        const NSInteger sec = (NSInteger)llround(album.duration);
        const NSInteger h = sec / 3600, m = (sec % 3600) / 60, sc = sec % 60;
        [metaParts addObject:(h > 0 ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)h, (long)m, (long)sc]
                                    : [NSString stringWithFormat:@"%ld:%02ld", (long)m, (long)sc])];
    }
    NSString *meta = metaParts.count ? [metaParts componentsJoinedByString:@" · "] : @"";
    self.yearLabel.stringValue = meta;
    self.yearLabel.hidden = (meta.length == 0);
    [self applyTheme];

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
                    self_.coverView.image = img;
                    self_.placeholderLabel.hidden = (img != nil);
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
@property (nonatomic, assign) BOOL lastLoadFailed;

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
@property (nonatomic, strong) NSView *albumsDivider;
@property (nonatomic, strong) NSTextField *albumsTitle;
@property (nonatomic, strong) RLPArtistChip *playAllBtn;

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
@property (nonatomic, strong) NSView *bioClip;
@property (nonatomic, strong) NSView *bioFade;
@property (nonatomic, strong) CAGradientLayer *bioFadeGrad;
@property (nonatomic, strong) NSTextField *bioText;
@property (nonatomic, strong) NSButton *bioToggle;
@property (nonatomic, strong) NSView *cardStyles;
@property (nonatomic, strong) NSTextField *stylesTitle;
@property (nonatomic, strong) NSMutableArray<NSView *> *styleBadges;
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
@property (nonatomic, assign) CGFloat lastGridContentW;
@property (nonatomic, assign) NSInteger lastGridCount;

- (void)relayoutPage;
- (void)relayoutForWidth:(CGFloat)W;
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

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

- (void)setSubtitle:(NSString *)text {
    [super setSubtitle:text];
    if (self.isViewLoaded) self.subtitleLabel.hidden = YES;
    if (self.isViewLoaded && self.view.window && text.length) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPPageCountNotification" object:text];
    }
}

#pragma mark - 建树

- (void)buildContent {
    RLPTheme *t = [RLPTheme current];
    self.subtitleLabel.hidden = YES;

    // ---- 滚动容器 ----
    _pageScroll = [[NSScrollView alloc] initWithFrame:self.contentView.bounds];
    _pageScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _pageScroll.drawsBackground = NO;
    _pageScroll.hasVerticalScroller = YES;
    _pageScroll.autohidesScrollers = YES;
    _pageScroll.borderType = NSNoBorder;
    [self.contentView addSubview:_pageScroll];
    if (_pageScroll.contentView) {
        _pageScroll.contentView.postsFrameChangedNotifications = YES;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(clipViewFrameDidChange:)
                                                     name:NSViewFrameDidChangeNotification
                                                   object:_pageScroll.contentView];
    }

    _doc = [[RLPArtistFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 954, 700)];
    _pageScroll.documentView = _doc;

    // ---- 顶栏返回按钮（保留 _backBtn，导航契约判据要读它的 title）----
    RLPArtistChip *backChip = [[RLPArtistChip alloc] initWithFrame:NSZeroRect];
    backChip.ghost = YES;
    backChip.radius = 7.0;
    backChip.padX = 8.0;
    backChip.leadingSymbol = @"chevron.left";
    backChip.target = self;
    backChip.action = @selector(onBack:);
    [backChip setText:RLPTr(@"返回艺术家列表")
                color:t.mut
                 font:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]];
    _backBtn = backChip;
    _backBtn.identifier = @"artist.back.top";
    [_doc addSubview:_backBtn];

    // ---- Hero ----
    _avatarView = [[NSView alloc] initWithFrame:NSZeroRect];
    _avatarView.wantsLayer = YES;
    _avatarView.layer.cornerRadius = kArtistAvatarSide / 2.0;   // 圆形（web border-radius:50%）
    _avatarView.layer.masksToBounds = YES;
    _avatarView.layer.backgroundColor = t.cvBg.CGColor;
    _avatarView.layer.borderWidth = 1.0;
    _avatarView.layer.borderColor = t.line.CGColor;
    _avatarView.identifier = @"artist.hero.avatar";
    [_doc addSubview:_avatarView];

    NSString *trimmed = [_artistName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *initial = trimmed.length ? [trimmed substringToIndex:1].uppercaseString : @"?";
    _initialLabel = RLPLabel(initial, [NSFont systemFontOfSize:46 weight:NSFontWeightHeavy], t.phText);
    _initialLabel.alignment = NSTextAlignmentCenter;
    [_avatarView addSubview:_initialLabel];

    // 真头像盖在首字母之上：拿到图就显示，拿不到就露出首字母占位。
    _avatarImage = [[RLPCoverImageView alloc] initWithFrame:NSZeroRect];
    _avatarImage.imageScaling = NSImageScaleProportionallyUpOrDown;
    _avatarImage.hidden = YES;
    [_avatarView addSubview:_avatarImage];

    // web .ahead .kind{font-size:10px;letter-spacing:1.4px;color:var(--mut2);font-weight:600}
    NSFont *eyebrowFont = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
    _eyebrowLabel = RLPArtistMakeLabel(@"artist.hero.eyebrow");
    _eyebrowLabel.font = eyebrowFont;
    _eyebrowLabel.textColor = t.mut2;
    _eyebrowLabel.usesSingleLineMode = NO;
    _eyebrowLabel.maximumNumberOfLines = 1;
    _eyebrowLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _eyebrowLabel.attributedStringValue = RLPArtistSingleLineAttr(RLPTr(@"ARTIST · 艺术家资料"),
        eyebrowFont, t.mut2, 1.4, NSTextAlignmentLeft);
    [_doc addSubview:_eyebrowLabel];

    // web .ahead h1{font-size:28px;font-weight:750;letter-spacing:-.5px;单行截断}
    NSFont *nameFont = [NSFont systemFontOfSize:28 weight:NSFontWeightBold];
    _nameLabel = RLPArtistMakeSelectableLabel(@"artist.hero.name");
    _nameLabel.font = nameFont;
    _nameLabel.textColor = t.text;
    _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _nameLabel.maximumNumberOfLines = 1;
    _nameLabel.usesSingleLineMode = NO;
    _nameLabel.attributedStringValue = RLPArtistSingleLineAttr(_artistName.length ? _artistName : RLPTr(@"未知艺术家"),
        nameFont, t.text, -0.5, NSTextAlignmentLeft);
    [_doc addSubview:_nameLabel];

    // web .ahead .sub{font-size:12.5px;color:var(--mut)}——没有资料时整行不显示
    _subLabel = RLPArtistMakeLabel(@"artist.hero.sub");
    _subLabel.hidden = YES;
    _subLabel.font = [NSFont systemFontOfSize:12.5];
    _subLabel.textColor = t.mut;
    _subLabel.usesSingleLineMode = NO;
    _subLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _subLabel.maximumNumberOfLines = 1;
    [_doc addSubview:_subLabel];

    // 三个按钮（横排，web .btn；查看专辑带图标填充主视觉，刷新资料与返回列表用次级描边层级）
    _btnAlbums = [self heroButton:RLPTr(@"查看专辑") ident:@"artist.hero.btn.albums" action:@selector(onScrollToAlbums:)];
    _btnRefresh = [self heroButton:RLPTr(@"刷新资料") ident:@"artist.hero.btn.refresh" action:@selector(onRefresh:)];
    _btnBackList = [self heroButton:RLPTr(@"返回列表") ident:@"artist.hero.btn.back" action:@selector(onBack:)];
    if ([_btnAlbums isKindOfClass:[RLPArtistChip class]]) {
        RLPArtistChip *c = (RLPArtistChip *)_btnAlbums;
        c.leadingSymbol = @"square.grid.2x2";
        [c setText:RLPTr(@"查看专辑") color:t.text font:[NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold]];
    }
    if ([_btnRefresh isKindOfClass:[RLPArtistChip class]]) {
        RLPArtistChip *c = (RLPArtistChip *)_btnRefresh;
        c.leadingSymbol = @"arrow.clockwise";
        c.filled = NO;
        [c setText:RLPTr(@"刷新资料") color:t.text font:[NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium]];
    }
    if ([_btnBackList isKindOfClass:[RLPArtistChip class]]) {
        RLPArtistChip *c = (RLPArtistChip *)_btnBackList;
        c.filled = NO;
        [c setText:RLPTr(@"返回列表") color:t.text2 font:[NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium]];
    }
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

    // ---- 唱片作品小节头 ----
    _albumsDivider = [[NSView alloc] initWithFrame:NSZeroRect];
    _albumsDivider.wantsLayer = YES;
    _albumsDivider.layer.backgroundColor = t.line.CGColor;
    [_doc addSubview:_albumsDivider];

    NSFont *albumsTitleFont = [NSFont systemFontOfSize:14.5 weight:NSFontWeightBold];
    _albumsTitle = RLPArtistMakeLabel(@"artist.albums.title");
    _albumsTitle.font = albumsTitleFont;
    _albumsTitle.textColor = t.text;
    _albumsTitle.usesSingleLineMode = NO;
    _albumsTitle.attributedStringValue = RLPArtistSingleLineAttr(RLPTr(@"唱片作品"),
        albumsTitleFont, t.text, 0.2, NSTextAlignmentLeft);
    _albumsTitle.maximumNumberOfLines = 1;
    _albumsTitle.lineBreakMode = NSLineBreakByTruncatingTail;
    [_doc addSubview:_albumsTitle];

    _playAllBtn = [[RLPArtistChip alloc] initWithFrame:NSZeroRect];
    _playAllBtn.identifier = @"artist.albums.playall";
    _playAllBtn.accentFill = YES;
    _playAllBtn.playTriangle = YES;
    _playAllBtn.radius = 8.0;
    _playAllBtn.padX = 15.0;
    _playAllBtn.target = self;
    _playAllBtn.action = @selector(onPlayAllAlbums:);
    _playAllBtn.hidden = YES;
    [_playAllBtn setText:RLPTr(@"播放全部")
                  color:[NSColor whiteColor]
                   font:[NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold]];
    [_doc addSubview:_playAllBtn];

    // ---- 专辑网格 ----
    _collection = [[NSCollectionView alloc] initWithFrame:NSZeroRect];
    NSCollectionViewFlowLayout *layout = [[RLPArtistAlbumFlowLayout alloc] init];
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
    b.padX = 14.0;
    b.target = self;
    b.action = action;
    b.alignment = NSTextAlignmentCenter;
    [b setText:title color:[RLPTheme current].text font:[NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium]];
    // 注意：不在这里 sizeToFit。relayoutPage 会给按钮明确的 frame（h=30），
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

    NSFont *headFont = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    NSTextField *head = RLPArtistMakeLabel(@"artist.card.title");
    head.font = headFont;
    head.textColor = t.mut2;
    head.usesSingleLineMode = NO;
    head.attributedStringValue = RLPArtistSingleLineAttr(title,
        headFont, t.mut2, 1.0, NSTextAlignmentLeft);
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
    _summaryStatus.font = [NSFont systemFontOfSize:12];
    _summaryStatus.textColor = [RLPTheme current].mut2;
    RLPArtistStyleWrap(_summaryStatus);
    _summaryStatus.hidden = YES;
    {
        NSClickGestureRecognizer *retryTap = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(onClickSummaryStatus:)];
        retryTap.numberOfClicksRequired = 1;
        [_summaryStatus addGestureRecognizer:retryTap];
    }
    [_cardSummary addSubview:_summaryStatus];

    RLPArtistChip *retryChip = [[RLPArtistChip alloc] initWithFrame:NSZeroRect];
    _summaryRetry = retryChip;
    retryChip.filled = YES;
    retryChip.radius = 8.0;
    _summaryRetry.identifier = @"artist.summary.retry";
    _summaryRetry.target = self;
    _summaryRetry.action = @selector(onRetry:);
    _summaryRetry.hidden = YES;
    [retryChip setText:RLPTr(@"重试获取") color:[RLPTheme current].text font:[NSFont systemFontOfSize:12]];
    [_cardSummary addSubview:_summaryRetry];

    _summaryFoot = RLPArtistMakeLabel(@"artist.summary.foot");
    _summaryFoot.font = [NSFont systemFontOfSize:11];
    _summaryFoot.textColor = [RLPTheme current].mut2;
    RLPArtistStyleWrap(_summaryFoot);
    _summaryFoot.hidden = YES;
    [_cardSummary addSubview:_summaryFoot];
}

- (void)buildBioCard {
    RLPTheme *t = [RLPTheme current];
    _cardBio = [self newCard:@"artist.card.bio" title:RLPTr(@"简介")];
    _bioTitle = [self cardTitleOf:_cardBio];
    _bioClip = [[RLPArtistFlippedView alloc] initWithFrame:NSZeroRect];
    _bioClip.wantsLayer = YES;
    _bioClip.layer.masksToBounds = YES;
    [_cardBio addSubview:_bioClip];

    _bioText = RLPArtistMakeSelectableLabel(@"artist.bio.text");
    _bioText.font = [NSFont systemFontOfSize:12.5];
    _bioText.textColor = t.text2;
    RLPArtistStyleWrap(_bioText);
    [_bioClip addSubview:_bioText];

    _bioFade = [[NSView alloc] initWithFrame:NSZeroRect];
    _bioFade.wantsLayer = YES;
    _bioFadeGrad = [CAGradientLayer layer];
    _bioFadeGrad.startPoint = CGPointMake(0.5, 1.0);   // 非翻转视图：y=1 在上、y=0 在下
    _bioFadeGrad.endPoint = CGPointMake(0.5, 0.0);
    _bioFadeGrad.colors = @[(__bridge id)[t.bg2 colorWithAlphaComponent:0.0].CGColor,
                            (__bridge id)t.bg2.CGColor];
    [_bioFade.layer addSublayer:_bioFadeGrad];
    _bioFade.hidden = YES;
    [_bioClip addSubview:_bioFade];

    RLPArtistChip *toggleChip = [[RLPArtistChip alloc] initWithFrame:NSZeroRect];
    _bioToggle = toggleChip;
    toggleChip.filled = YES;
    toggleChip.radius = 8.0;
    _bioToggle.identifier = @"artist.bio.toggle";
    _bioToggle.target = self;
    _bioToggle.action = @selector(onToggleBio:);
    _bioToggle.hidden = YES;
    [toggleChip setText:RLPTr(@"展开全部") color:[RLPTheme current].text font:[NSFont systemFontOfSize:12]];
    [_cardBio addSubview:_bioToggle];
    _cardBio.hidden = YES;
}

- (void)buildStylesCard {
    _cardStyles = [self newCard:@"artist.card.styles" title:RLPTr(@"风格与相似")];
    _stylesTitle = [self cardTitleOf:_cardStyles];
    _cardStyles.hidden = YES;
}

- (void)buildSourcesCard {
    _cardSources = [self newCard:@"artist.card.sources" title:RLPTr(@"资料来源")];
    _sourcesTitle = [self cardTitleOf:_cardSources];
    _cardSources.hidden = YES;
}

#pragma mark - 排版（唯一入口：宽度变了 / 数据到了都调它）

- (void)clipViewFrameDidChange:(NSNotification *)note {
    (void)note;
    if (_inLayout || !_pageScroll.contentView) return;
    const CGFloat clipW = _pageScroll.contentView.bounds.size.width;
    if (clipW < 40.0) return;
    if (fabs(_lastLayoutWidth - clipW) >= 0.5 || fabs(_doc.frame.size.width - clipW) >= 0.5) {
        [self syncDocWidthToScroll];
        [self relayoutPage];
    }
}

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
    [self relayoutForWidth:W];
    // 传统滚动条（NSScrollerStyleLegacy）会在总高超出可视区时收窄 clipW（约 17pt），
    // 且 clipViewFrameDidChange 在 _inLayout 期间会提前返回；这里立即同步做第 2 遍排版，
    // 保证播放全部与专辑网格右缘严丝合缝，绝不被滚动条压住或向右溢出。
    if (_pageScroll) {
        [_pageScroll layoutSubtreeIfNeeded];
        if (_pageScroll.contentView) {
            const CGFloat afterW = _pageScroll.contentView.bounds.size.width;
            if (afterW >= 40.0 && fabs(afterW - W) >= 0.5) {
                if (fabs(_doc.frame.size.width - afterW) > 0.5) {
                    _doc.frame = NSMakeRect(0, 0, afterW, _doc.frame.size.height);
                }
                [self relayoutForWidth:afterW];
                [_pageScroll layoutSubtreeIfNeeded];
            }
        }
    }
    _inLayout = NO;
}

- (void)relayoutForWidth:(CGFloat)W {
    if (!_doc || W < 40.0) return;

    const CGFloat padX = kArtistPagePadX;
    const CGFloat contentW = MAX(80.0, W - padX * 2.0);
    CGFloat y = 12.0;

    // ---- ① 顶栏返回按钮 ----
    {
        const CGFloat bw = MIN(contentW, RLPArtistChipWidth(_backBtn));
        const CGFloat bh = 26.0;
        _backBtn.frame = NSMakeRect(padX, y, bw, bh);
        y += bh + 12.0;
    }

    // ---- ② Hero ----
    const CGFloat avatarS = kArtistAvatarSide;
    const CGFloat heroLeft = padX;
    const CGFloat infoX = heroLeft + avatarS + 24.0;
    const CGFloat infoW = MAX(60.0, W - infoX - padX);
    const CGFloat eyebrowH = MAX(13.0, ceil([_eyebrowLabel sizeThatFits:NSMakeSize(infoW, CGFLOAT_MAX)].height));
    const CGFloat nameH = MAX(33.0, ceil([_nameLabel sizeThatFits:NSMakeSize(infoW, CGFLOAT_MAX)].height));
    const CGFloat subH = MAX(16.0, ceil([_subLabel sizeThatFits:NSMakeSize(infoW, CGFLOAT_MAX)].height));
    const CGFloat btnH = 30.0;

    const BOOL hasSub = !_subLabel.hidden;
    const CGFloat stackH = eyebrowH + 6.0 + nameH
                         + (hasSub ? (6.0 + subH) : 0.0)
                         + 13.0 + btnH;
    const CGFloat heroTop = y;
    const CGFloat stackTop = heroTop + MAX(0.0, avatarS - stackH - 5.0);

    _avatarView.frame = NSMakeRect(heroLeft, heroTop, avatarS, avatarS);
    _avatarImage.frame = _avatarView.bounds;
    {
        const CGFloat iw = 120.0, ih = 56.0;
        _initialLabel.frame = NSMakeRect((avatarS - iw) / 2.0, (avatarS - ih) / 2.0, iw, ih);
    }

    CGFloat sy = stackTop;
    _eyebrowLabel.frame = NSMakeRect(infoX, sy, infoW, eyebrowH);
    sy += eyebrowH + 6.0;
    _nameLabel.frame = NSMakeRect(infoX, sy, infoW, nameH);
    sy += nameH;
    if (hasSub) {
        sy += 6.0;
        _subLabel.frame = NSMakeRect(infoX, sy, infoW, subH);
        sy += subH;
    } else {
        _subLabel.frame = NSZeroRect;
    }
    sy += 13.0;

    // 三个按钮横排（严格按 preferredWidth 定宽、放不下就换行，永不左侧挤压或溢出）
    {
        CGFloat bx = infoX;
        CGFloat by = sy;
        CGFloat bwSum = 0.0;
        NSArray<NSButton *> *btns = @[ _btnAlbums, _btnRefresh, _btnBackList ];
        const CGFloat gap = 10.0;
        for (NSButton *b in btns) {
            const CGFloat bw = MIN(infoW, RLPArtistChipWidth(b));
            bwSum += bw + gap;
        }
        const BOOL oneRow = (infoX + bwSum - gap) <= (W - padX + 0.5);
        CGFloat btnsBottom = sy + btnH;
        for (NSButton *b in btns) {
            const CGFloat bw = MIN(infoW, RLPArtistChipWidth(b));
            if (!oneRow && bx > infoX && (bx + bw) > (W - padX + 0.5)) { bx = infoX; by += btnH + 8.0; }
            b.frame = NSMakeRect(bx, by, bw, btnH);
            btnsBottom = MAX(btnsBottom, by + btnH);
            bx += bw + gap;
        }
        y = MAX(heroTop + avatarS, btnsBottom) + 22.0;
    }

    // ---- ③ ~ ⑥ 纵向卡片 ----
    y = [self layoutSummaryCardAt:y width:contentW x:padX];
    y += kArtistCardGap;
    y = [self layoutBioCardAt:y width:contentW x:padX];
    if (!_cardStyles.hidden) { y += kArtistCardGap; y = [self layoutStylesCardAt:y width:contentW x:padX]; }
    if (!_cardSources.hidden) { y += kArtistCardGap; y = [self layoutSourcesCardAt:y width:contentW x:padX]; }

    // ---- ⑦ 唱片作品头部 + 响应式专辑网格 ----
    const NSInteger n = (NSInteger)self.albums.count;
    const BOOL showAlbumsSection = (n > 0 || !_emptyLabel.hidden);
    if (showAlbumsSection) {
        y += 22.0;
        _albumsDivider.hidden = NO;
        _albumsDivider.frame = NSMakeRect(padX, y, contentW, 1.0);
        y += 14.0;

        _albumsTitle.hidden = NO;
        const NSSize tsz = [_albumsTitle sizeThatFits:NSMakeSize(contentW, CGFLOAT_MAX)];
        const CGFloat tw = MIN(contentW, ceil(tsz.width) + 6.0);
        const CGFloat th = MAX(18.0, ceil(tsz.height));
        const CGFloat rowH = 30.0;
        CGFloat rightEdge = padX + contentW;
        if (n > 0) {
            _playAllBtn.hidden = NO;
            const CGFloat pbw = MIN(contentW * 0.45, RLPArtistChipWidth(_playAllBtn));
            _playAllBtn.frame = NSMakeRect(padX + contentW - pbw, y, pbw, rowH);
            rightEdge = NSMinX(_playAllBtn.frame) - 12.0;
        } else {
            _playAllBtn.hidden = YES;
            _playAllBtn.frame = NSZeroRect;
        }
        _albumsTitle.frame = NSMakeRect(padX, y + round((rowH - th) * 0.5), tw, th);
        if (!_statsLabel.hidden && _statsLabel.stringValue.length > 0 && rightEdge > padX + tw + 18.0) {
            const CGFloat sx = padX + tw + 10.0;
            const CGFloat sh = MAX(15.0, ceil([_statsLabel sizeThatFits:NSMakeSize(MAX(1.0, rightEdge - sx), CGFLOAT_MAX)].height));
            _statsLabel.frame = NSMakeRect(sx, y + round((rowH - sh) * 0.5), MAX(0.0, rightEdge - sx), sh);
        } else {
            _statsLabel.frame = NSZeroRect;
        }
        y += rowH + 14.0;
    } else {
        _albumsDivider.hidden = YES;
        _albumsTitle.hidden = YES;
        _playAllBtn.hidden = YES;
        _statsLabel.frame = NSZeroRect;
    }

    const CGFloat gapX = 16.0, gapY = 20.0, minItemW = 148.0;
    const NSInteger cols = MAX(1, (NSInteger)floor((contentW + gapX) / (minItemW + gapX)));
    const CGFloat itemW = MAX(80.0, floor((contentW - gapX * (CGFloat)(cols - 1)) / (CGFloat)cols));
    const CGFloat itemH = itemW + 46.0;
    const NSInteger rows = (cols > 0 && n > 0) ? ((n + cols - 1) / cols) : 0;
    CGFloat gridH = (rows > 0) ? (CGFloat)rows * itemH + (CGFloat)(rows - 1) * gapY : 0.0;
    if (gridH > 0.5) {
        _collection.hidden = NO;
        _collection.frame = NSMakeRect(padX, y, contentW, gridH);
        NSCollectionViewFlowLayout *cur = [_collection.collectionViewLayout isKindOfClass:[RLPArtistAlbumFlowLayout class]]
            ? (NSCollectionViewFlowLayout *)_collection.collectionViewLayout : nil;
        const BOOL needRebuildLayout = !cur ||
            fabs(cur.itemSize.width - itemW) > 0.5 ||
            fabs(cur.itemSize.height - itemH) > 0.5 ||
            fabs(cur.minimumInteritemSpacing - gapX) > 0.5 ||
            fabs(cur.minimumLineSpacing - gapY) > 0.5 ||
            fabs(_lastGridContentW - contentW) > 0.5 ||
            _lastGridCount != n;
        if (needRebuildLayout) {
            NSSet<NSIndexPath *> *sel = [_collection.selectionIndexPaths copy];
            NSCollectionViewFlowLayout *fl = [[RLPArtistAlbumFlowLayout alloc] init];
            fl.itemSize = NSMakeSize(itemW, itemH);
            fl.minimumInteritemSpacing = gapX;
            fl.minimumLineSpacing = gapY;
            fl.sectionInset = NSEdgeInsetsMake(0, 0, 0, 0);
            _collection.collectionViewLayout = fl;
            if (sel.count) _collection.selectionIndexPaths = sel;
            _lastGridContentW = contentW;
            _lastGridCount = n;
        }
        [_collection layoutSubtreeIfNeeded];
        if (_collection.collectionViewLayout) {
            const CGFloat flowH = ceil(_collection.collectionViewLayout.collectionViewContentSize.height);
            if (flowH > gridH + 0.5) {
                gridH = flowH;
                _collection.frame = NSMakeRect(padX, y, contentW, gridH);
                [_collection layoutSubtreeIfNeeded];
            }
        }
        y += gridH;
    } else {
        _collection.hidden = YES;
        _collection.frame = NSZeroRect;
        _lastGridContentW = contentW;
        _lastGridCount = n;
    }
    if (!_emptyLabel.hidden) {
        const CGFloat eh = 22.0;
        _emptyLabel.frame = NSMakeRect(padX, y + 6.0, contentW, eh);
        y += eh + 6.0;
    } else {
        _emptyLabel.frame = NSZeroRect;
    }

    // 文档高度（底部留出 96pt 以避开浮动播放栏）
    const CGFloat totalH = MAX(_pageScroll.contentView.bounds.size.height, y + 96.0);
    if (fabs(_doc.frame.size.height - totalH) > 0.5 || fabs(_doc.frame.size.width - W) > 0.5) {
        _doc.frame = NSMakeRect(0, 0, W, totalH);
    }
    _lastLayoutWidth = W;
}

- (CGFloat)cardTitleH { return 15.0; }
- (CGFloat)cardTitleGap { return 8.0; }

- (CGFloat)layoutSummaryCardAt:(CGFloat)top width:(CGFloat)contentW x:(CGFloat)left {
    RLPTheme *t = [RLPTheme current];
    const CGFloat innerW = MAX(40.0, contentW - kArtistCardPadX * 2.0);
    CGFloat y = kArtistCardPadY;
    _summaryTitle.frame = NSMakeRect(kArtistCardPadX, y, innerW, [self cardTitleH]);
    y += [self cardTitleH] + [self cardTitleGap];

    BOOL hasBody = NO;

    // 字段网格
    const CGFloat gridH = [_summaryGrid layoutWidth:innerW];
    _summaryGrid.frame = NSMakeRect(kArtistCardPadX, y, innerW, MAX(1.0, gridH));
    if (!_summaryGrid.hidden && gridH > 0.5) {
        y += gridH;
        hasBody = YES;
    }

    // 状态行（正在获取资料… / 暂无资料 / 失败行）
    if (!_summaryStatus.hidden) {
        if (hasBody) y += 10.0;
        const CGFloat sh = MAX(18.0, RLPArtistTextH(_summaryStatus.stringValue, _summaryStatus.font, innerW, 0));
        _summaryStatus.frame = NSMakeRect(kArtistCardPadX, y, innerW, sh);
        y += sh;
        hasBody = YES;
    } else {
        _summaryStatus.frame = NSZeroRect;
    }
    if (!_summaryRetry.hidden) {
        if (hasBody) y += 8.0;
        if ([_summaryRetry isKindOfClass:[RLPArtistChip class]]) ((RLPArtistChip *)_summaryRetry).padX = 12.0;
        const CGFloat bw = RLPArtistChipWidth(_summaryRetry);
        _summaryRetry.frame = NSMakeRect(kArtistCardPadX, y, bw, 28.0);
        y += 28.0;
        hasBody = YES;
    } else {
        _summaryRetry.frame = NSZeroRect;
    }

    // 引用芯片（[1] 标题）
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
        chip.padX = 10.0;
        [chip setText:label color:t.mut font:[NSFont systemFontOfSize:11]];
        chip.toolTip = url;
        chip.target = self;
        chip.action = @selector(onCopyChip:);
        [_cardSummary addSubview:chip];
        [_citeChips addObject:chip];
    }
    if (_citeChips.count) {
        if (hasBody) y += 10.0;
        const CGFloat gap = 6.0;
        CGFloat cx = kArtistCardPadX, cy = y;
        const CGFloat ch = 24.0;
        for (NSButton *chip in _citeChips) {
            const CGFloat cw = MIN(innerW, RLPArtistChipWidth(chip));
            if (cx > kArtistCardPadX && (cx + cw) > (kArtistCardPadX + innerW + 0.5)) {
                cx = kArtistCardPadX; cy += ch + gap;
            }
            chip.frame = NSMakeRect(cx, cy, cw, ch);
            cx += cw + gap;
        }
        y = cy + ch;
        hasBody = YES;
    }

    // 脚注
    if (!_summaryFoot.hidden) {
        if (hasBody) y += 8.0;
        const CGFloat fh = MAX(14.0, RLPArtistTextH(_summaryFoot.stringValue, _summaryFoot.font, innerW, 0));
        _summaryFoot.frame = NSMakeRect(kArtistCardPadX, y, innerW, fh);
        y += fh;
    } else {
        _summaryFoot.frame = NSZeroRect;
    }

    const CGFloat cardH = MAX(kArtistCardPadY * 2.0 + [self cardTitleH] + [self cardTitleGap], y + kArtistCardPadY);
    _cardSummary.frame = NSMakeRect(left, top, contentW, cardH);
    return top + cardH;
}

- (CGFloat)layoutBioCardAt:(CGFloat)top width:(CGFloat)contentW x:(CGFloat)left {
    if (_cardBio.hidden) { _cardBio.frame = NSZeroRect; return top; }
    RLPTheme *t = [RLPTheme current];
    const CGFloat innerW = MAX(40.0, contentW - kArtistCardPadX * 2.0);
    CGFloat y = kArtistCardPadY;
    _bioTitle.frame = NSMakeRect(kArtistCardPadX, y, innerW, [self cardTitleH]);
    y += [self cardTitleH] + 10.0;   // web .bio-sec 的 sec-title margin-bottom:10px

    NSFont *bf = _bioText.font ?: [NSFont systemFontOfSize:12.5];
    const CGFloat fullH = ceil(RLPArtistTextH(_bioText.stringValue, bf, innerW, 8.0));
    const CGFloat collapsedH = MAX(80.0, ceil(RLPArtistTextH(@"第一行Ag\n第二行Ag\n第三行Ag\n第四行Ag", bf, innerW, 8.0)));
    const BOOL needToggle = (fullH > collapsedH + 2.0);
    const CGFloat showH = (needToggle && !_bioExpanded) ? collapsedH : fullH;
    const CGFloat clipH = MAX(16.0, showH);
    _bioClip.frame = NSMakeRect(kArtistCardPadX, y, innerW, clipH);
    _bioText.frame = NSMakeRect(0.0, 0.0, innerW, MAX(clipH, fullH));
    if (_bioFade) {
        if (needToggle && !_bioExpanded && clipH >= 28.0) {
            const CGFloat fadeH = MIN(26.0, clipH * 0.35);
            _bioFade.hidden = NO;
            _bioFade.frame = NSMakeRect(0.0, clipH - fadeH, innerW, fadeH);
            _bioFadeGrad.frame = _bioFade.bounds;
            _bioFadeGrad.colors = @[(__bridge id)[t.bg2 colorWithAlphaComponent:0.0].CGColor,
                                    (__bridge id)t.bg2.CGColor];
        } else {
            _bioFade.hidden = YES;
        }
    }
    y += clipH;

    if (needToggle) {
        _bioToggle.hidden = NO;
        NSString *title = _bioExpanded ? RLPTr(@"收起简介") : RLPTr(@"展开全部");
        if ([_bioToggle isKindOfClass:[RLPArtistChip class]]) {
            ((RLPArtistChip *)_bioToggle).padX = 12.0;
            [(RLPArtistChip *)_bioToggle setText:title color:t.text font:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]];
        }
        const CGFloat bw = RLPArtistChipWidth(_bioToggle);
        y += 10.0;
        _bioToggle.frame = NSMakeRect(kArtistCardPadX, y, bw, 28.0);
        y += 28.0;
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
    NSTextField *head = _stylesTitle ?: [self cardTitleOf:_cardStyles];
    if (head) { head.frame = NSMakeRect(kArtistCardPadX, y, innerW, [self cardTitleH]); }
    y += [self cardTitleH] + 10.0;

    const CGFloat gap = 8.0, bh = 22.0;
    CGFloat bx = kArtistCardPadX, by = y;
    for (NSView *b in _styleBadges) {
        CGFloat rawW = [b isKindOfClass:[RLPArtistStyleBadgeView class]]
            ? [(RLPArtistStyleBadgeView *)b preferredWidth]
            : 48.0;
        const CGFloat bw = MIN(innerW, rawW);
        if (bx > kArtistCardPadX && (bx + bw) > (kArtistCardPadX + innerW + 0.5)) {
            bx = kArtistCardPadX; by += bh + gap;
        }
        b.frame = NSMakeRect(bx, by, bw, bh);
        bx += bw + gap;
    }
    y = _styleBadges.count ? (by + bh) : y;
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

    const CGFloat rowH = 42.0, rowGap = 8.0;
    for (NSView *row in _sourceRows) {
        row.frame = NSMakeRect(kArtistCardPadX, y, innerW, rowH);
        NSArray<NSView *> *subs = row.subviews;
        CGFloat right = innerW - 14.0;
        // 从右往左放可见芯片（无 URL 时 copyChip 已隐藏，跳过不占宽度）
        for (NSInteger i = (NSInteger)subs.count - 1; i >= 0; --i) {
            NSView *v = subs[(NSUInteger)i];
            if (![v isKindOfClass:[NSButton class]] || v.hidden) continue;
            NSButton *b = (NSButton *)v;
            const CGFloat bw = RLPArtistChipWidth(b);
            right -= bw;
            b.frame = NSMakeRect(right, round((rowH - 26.0) / 2.0), bw, 26.0);
            right -= 14.0;
        }
        CGFloat lx = 14.0;
        NSTextField *badgeTF = nil, *titleTF = nil, *dateTF = nil;
        for (NSView *v in subs) {
            if (![v isKindOfClass:[NSTextField class]]) continue;
            NSTextField *tf = (NSTextField *)v;
            if ([tf.identifier containsString:@".badge"]) badgeTF = tf;
            else if ([tf.identifier hasSuffix:@".date"]) dateTF = tf;
            else titleTF = tf;
        }
        if (badgeTF) {
            NSFont *bf = badgeTF.font ?: [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold];
            const CGFloat bTxtW = ceil([badgeTF.stringValue sizeWithAttributes:@{
                NSFontAttributeName: bf, NSKernAttributeName: @(0.2)
            }].width);
            const NSSize bsz = [badgeTF sizeThatFits:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)];
            const CGFloat bw = MIN(MAX(42.0, MAX(bTxtW, ceil(bsz.width)) + 16.0),
                                   MAX(42.0, right - lx - 40.0));
            const CGFloat textH = MAX(14.0, ceil([badgeTF sizeThatFits:NSMakeSize(bw, CGFLOAT_MAX)].height));
            const CGFloat pillH = MAX(22.0, textH + 6.0);
            const CGFloat pillY = round((rowH - pillH) * 0.5);
            badgeTF.frame = NSMakeRect(lx, pillY + round((pillH - textH) * 0.5), bw, textH);
            if ([row isKindOfClass:[RLPArtistSourceRow class]]) {
                RLPArtistSourceRow *sr = (RLPArtistSourceRow *)row;
                sr.badgePill.frame = NSMakeRect(lx, pillY, bw, pillH);
                sr.badgePill.layer.backgroundColor = t.accentWeak.CGColor;
            }
            lx += bw + 12.0;
        }
        CGFloat dateW = 0.0;
        CGFloat dateH = 16.0;
        if (dateTF) {
            NSString *dt = dateTF.stringValue ?: @"";
            if (dt.length) {
                NSFont *df = dateTF.font ?: [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightRegular];
                const CGFloat dTxtW = ceil([dt sizeWithAttributes:@{ NSFontAttributeName: df }].width);
                const NSSize dsz = [dateTF sizeThatFits:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)];
                dateH = MAX(15.0, ceil(dsz.height));
                dateW = MAX(dTxtW, ceil(dsz.width)) + 12.0;
                const CGFloat maxDateW = MAX(0.0, right - lx - 80.0);
                dateW = MIN(dateW, maxDateW);
                dateTF.hidden = (dateW < 24.0);
                if (dateTF.hidden) dateW = 0.0;
            } else {
                dateTF.hidden = YES;
            }
        }
        if (titleTF) {
            const CGFloat dateReserve = (dateW > 0.5) ? (dateW + 14.0) : 0.0;
            const CGFloat tw = MAX(40.0, right - lx - dateReserve);
            const CGFloat th = MAX(16.0, ceil([titleTF sizeThatFits:NSMakeSize(tw, CGFLOAT_MAX)].height));
            titleTF.frame = NSMakeRect(lx, round((rowH - th) / 2.0), tw, th);
            lx += tw + 14.0;
        }
        if (dateTF && !dateTF.hidden && dateW > 0.5) {
            dateTF.frame = NSMakeRect(MAX(lx, right - dateW), round((rowH - dateH) / 2.0), dateW, dateH);
        } else if (dateTF) {
            dateTF.frame = NSZeroRect;
        }
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
        NSString *rawPrefix = self.knowledgeFromCache ? RLPTr(@"缓存 ·") : RLPTr(@"资料");
        NSString *trimmedPrefix = [rawPrefix stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *prefix = self.knowledgeFromCache
            ? [trimmedPrefix stringByAppendingString:@" "]
            : [NSString stringWithFormat:@"%@ · ", trimmedPrefix];
        if (date.length) {
            sub = [NSString stringWithFormat:@"%@%@ %@", prefix, date, RLPTr(@"取回")];
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
    NSMutableDictionary *effectiveFields = [fields mutableCopy];
    if (labels.count == 0 && self.summarySections.count) {
        NSMutableString *acc = [NSMutableString string];
        for (NSDictionary *sec in self.summarySections) {
            NSString *heading = [sec[@"heading"] isKindOfClass:[NSString class]] ? sec[@"heading"] : @"";
            NSArray *paras = [sec[@"paragraphs"] isKindOfClass:[NSArray class]] ? sec[@"paragraphs"] : @[];
            if (!paras.count) continue;
            NSMutableString *secTxt = [NSMutableString string];
            for (NSDictionary *p in paras) {
                NSString *txt = [p[@"text"] isKindOfClass:[NSString class]] ? p[@"text"] : @"";
                if (txt.length) {
                    if (secTxt.length) [secTxt appendString:@"\n"];
                    [secTxt appendString:txt];
                }
            }
            if (!secTxt.length) continue;
            BOOL headingUseful = heading.length &&
                ![heading isEqualToString:@"概述"] && ![heading isEqualToString:@"简介"];
            if (headingUseful) {
                if (![seen containsObject:heading]) {
                    [labels addObject:heading];
                    [seen addObject:heading];
                    effectiveFields[heading] = secTxt;
                }
                continue;
            }
            if (acc.length) [acc appendString:@"\n"];
            [acc appendString:secTxt];
        }
        if (acc.length) {
            NSString *bioKey = RLPTr(@"简介");
            if (![seen containsObject:bioKey] && ![self hasBio]) {
                [labels insertObject:bioKey atIndex:0];
                [seen addObject:bioKey];
                effectiveFields[bioKey] = acc;
            }
        }
    }

    for (NSString *label in labels) {
        NSString *value = RLPArtistFieldText(effectiveFields[label]);
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
    _summaryStatus.font = [NSFont systemFontOfSize:12];
    _summaryStatus.textColor = statusColor;
    _summaryStatus.attributedStringValue = RLPArtistAttr(statusText, [NSFont systemFontOfSize:12],
                                                         statusColor, 0, 0);
    _summaryRetry.hidden = !showRetry;

    // 3) 引用芯片 / 脚注
    NSArray *cites = self.summaryCitations ?: @[];
    _summaryFoot.hidden = (cites.count == 0);
    _summaryFoot.font = [NSFont systemFontOfSize:11];
    _summaryFoot.textColor = t.mut2;
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
    NSFont *bioFont = [NSFont systemFontOfSize:12.5];
    _bioText.font = bioFont;
    _bioText.textColor = t.text2;
    if (!text.length) {
        _cardBio.hidden = YES;
        _bioText.stringValue = @"";
        return;
    }
    _cardBio.hidden = NO;
    _bioText.attributedStringValue = RLPArtistAttr(text, bioFont, t.text2, 0, 8.0);
}

- (void)refreshStylesCard {
    for (NSView *b in _styleBadges) [b removeFromSuperview];
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
        RLPArtistStyleBadgeView *badge = [[RLPArtistStyleBadgeView alloc] initWithTitle:n];
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
        row.layer.borderWidth = 1.0;
        row.layer.borderColor = t.hairline.CGColor;
        row.layer.backgroundColor = t.hov.CGColor;
        row.autoresizingMask = NSViewNotSizable;

        NSTextField *badge = RLPArtistMakeLabel(@"artist.sources.badge");
        badge.identifier = [NSString stringWithFormat:@"artist.sources.badge.%ld", (long)idx];
        NSString *srcName = RLPArtistSourceBadge([m[@"source"] isKindOfClass:[NSString class]] ? m[@"source"] : @"");
        NSFont *badgeFont = [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold];
        badge.font = badgeFont;
        badge.textColor = t.accentText;
        badge.usesSingleLineMode = NO;
        badge.attributedStringValue = RLPArtistSingleLineAttr(srcName, badgeFont, t.accentText, 0.2, NSTextAlignmentCenter);
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

        NSTextField *title = RLPArtistMakeSelectableLabel(@"artist.sources.title");
        NSString *ttl = [m[@"title"] isKindOfClass:[NSString class]] ? m[@"title"] : @"";
        NSFont *titleFont = [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold];
        title.font = titleFont;
        title.textColor = t.text;
        title.usesSingleLineMode = NO;
        title.attributedStringValue = RLPArtistSingleLineAttr(ttl, titleFont, t.text, 0, NSTextAlignmentLeft);
        title.maximumNumberOfLines = 1;
        title.lineBreakMode = NSLineBreakByTruncatingTail;
        [row addSubview:title];

        NSTextField *date = RLPArtistMakeLabel(@"artist.sources.date");
        NSString *d = RLPArtistFmtDate(m[@"fetched_at"]);
        NSString *dText = d.length ? [NSString stringWithFormat:@"%@ %@", RLPTr(@"取回于"), d] : @"";
        NSFont *dateFont = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightRegular];
        date.font = dateFont;
        date.textColor = t.mut2;
        date.usesSingleLineMode = NO;
        date.attributedStringValue = RLPArtistSingleLineAttr(dText, dateFont, t.mut2, 0, NSTextAlignmentRight);
        date.alignment = NSTextAlignmentRight;
        date.maximumNumberOfLines = 1;
        date.lineBreakMode = NSLineBreakByTruncatingTail;
        [row addSubview:date];

        NSString *url = [m[@"url"] isKindOfClass:[NSString class]] ? m[@"url"] : @"";
        RLPArtistChip *copyChip = [[RLPArtistChip alloc] initWithFrame:NSZeroRect];
        copyChip.identifier = [NSString stringWithFormat:@"artist.sources.copy.%ld", (long)idx];
        copyChip.filled = YES;
        copyChip.radius = 7.0;
        copyChip.padX = 11.0;
        copyChip.leadingSymbol = @"doc.on.doc";
        [copyChip setText:RLPTr(@"复制链接") color:t.text font:[NSFont systemFontOfSize:11 weight:NSFontWeightMedium]];
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
    if (!self.loaded) {
        [self reloadData];
    } else if (self.view.window) {
        NSString *cnt = (self.albums.count == 0)
            ? [NSString stringWithFormat:@"0 %@", RLPTr(@"张专辑")]
            : [NSString stringWithFormat:@"%ld %@ · %ld %@",
               (long)self.albums.count, RLPTr(@"张专辑"),
               (long)self.totalTracks, RLPTr(@"首")];
        [self setSubtitle:cnt];
    }
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
        self.lastLoadFailed = NO;
        self.loaded = NO;
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

    self.lastLoadFailed = NO;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/lib/albums" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            self_.lastLoadFailed = YES;
            self_.loaded = NO;
            [self_ setSubtitle:RLPTr(@"读取失败")];
            self_.emptyLabel.stringValue = RLPTr(@"读取失败");
            self_.emptyLabel.hidden = NO;
            [self_ relayoutPage];
            return;
        }
        self_.lastLoadFailed = NO;
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
            self_.statsLabel.stringValue = @"";
            self_.statsLabel.hidden = YES;
            self_.emptyLabel.stringValue = RLPTr(@"这个艺术家还没有专辑");
            self_.emptyLabel.hidden = NO;
        } else {
            [self_ setSubtitle:[NSString stringWithFormat:@"%ld %@ · %ld %@",
                                (long)filtered.count, RLPTr(@"张专辑"),
                                (long)totalTracks, RLPTr(@"首")]];
            [self_ updateAlbumsStatsText];
            self_.statsLabel.hidden = NO;
            self_.emptyLabel.stringValue = @"";
            self_.emptyLabel.hidden = YES;
        }
        [self_.collection reloadData];
        [self_ relayoutPage];
    }];
}

#pragma mark - 事件

- (void)onBack:(id)sender { (void)sender; RLPRequestBack(); }

- (void)updateAlbumsStatsText {
    if (self.albumCount <= 0) {
        self.statsLabel.stringValue = @"";
        return;
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:[NSString stringWithFormat:@"%ld %@", (long)self.albumCount, RLPTr(@"张专辑")]];
    if (self.totalTracks > 0) {
        [parts addObject:[NSString stringWithFormat:@"%ld %@", (long)self.totalTracks, RLPTr(@"首")]];
    }
    if (self.totalDuration > 0.5) {
        const NSInteger sec = (NSInteger)llround(self.totalDuration);
        const NSInteger h = sec / 3600, m = (sec % 3600) / 60, sc = sec % 60;
        [parts addObject:(h > 0
            ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)h, (long)m, (long)sc]
            : [NSString stringWithFormat:@"%ld:%02ld", (long)m, (long)sc])];
    }
    self.statsLabel.stringValue = [parts componentsJoinedByString:@" · "];
}

- (void)enqueueRemainingAlbums:(NSArray<NSString *> *)keys index:(NSUInteger)idx {
    if (idx >= keys.count) return;
    NSString *k = keys[idx];
    if (!k.length) { [self enqueueRemainingAlbums:keys index:idx + 1]; return; }
    NSString *url = [NSString stringWithFormat:@"/api/lib/enqueue?k=%@", RLPEnc(k)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
        (void)json;
        [weakSelf enqueueRemainingAlbums:keys index:idx + 1];
    }];
}

- (void)onPlayAllAlbums:(id)sender {
    (void)sender;
    if (!self.albums.count || ![RLPCoreClient shared].started) return;
    NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithCapacity:self.albums.count];
    for (RLPAlbum *a in self.albums) {
        if (a.key.length) [keys addObject:a.key];
    }
    if (!keys.count) return;
    if (keys.count == 1) {
        RLPPlayAlbum(keys[0], 0);
        return;
    }
    NSString *body = [NSString stringWithFormat:@"k=%@&i=0", RLPEnc(keys[0])];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/lib/play" body:body completion:^(NSDictionary * _Nullable json) {
        if (json && [json[@"ok"] boolValue]) {
            [weakSelf enqueueRemainingAlbums:keys index:1];
        }
    }];
}

- (void)onScrollToAlbums:(id)sender {
    (void)sender;
    if (!_pageScroll || !_doc) return;
    const NSRect f = (_albumsDivider && !_albumsDivider.hidden) ? _albumsDivider.frame : _collection.frame;
    const CGFloat maxY = MAX(0.0, NSHeight(_doc.bounds) - NSHeight(_pageScroll.contentView.bounds));
    const CGFloat targetY = MAX(0.0, MIN(maxY, NSMinY(f) - 16.0));
    [_pageScroll.contentView scrollToPoint:NSMakePoint(0, targetY)];
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

- (void)onClickSummaryStatus:(id)sender {
    (void)sender;
    if (self.summaryFailed && self.materials.count > 0) {
        [self onRetry:nil];
    }
}

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
    NSCollectionViewItem *it = [self.collection itemAtIndexPath:ip];
    if ([it isKindOfClass:[RLPArtistAlbumItem class]]) {
        RLPArtistAlbumItem *ai = (RLPArtistAlbumItem *)it;
        if (ai.playBadge && !ai.playBadge.hidden) {
            const NSPoint bp = [g locationInView:ai.playBadge];
            if (NSPointInRect(bp, ai.playBadge.bounds)) return;
        }
    }
    RLPAlbum *album = self.albums[(NSUInteger)ip.item];
    if (album.key.length) RLPRequestOpenAlbum(album.key);
}

#pragma mark - 主题 / 语言

- (void)applyTheme {
    [super applyTheme];
    if (!self.isViewLoaded) return;
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
        if ([_backBtn isKindOfClass:[RLPArtistChip class]]) {
            [(RLPArtistChip *)_backBtn setText:RLPTr(@"返回艺术家列表")
                                         color:t.mut
                                          font:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]];
        }
        NSFont *eyebrowFont = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
        NSFont *nameFont = [NSFont systemFontOfSize:28 weight:NSFontWeightBold];
        NSFont *cardTitleFont = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
        NSFont *albumsTitleFont = [NSFont systemFontOfSize:14.5 weight:NSFontWeightBold];
        _eyebrowLabel.font = eyebrowFont;
        _eyebrowLabel.textColor = t.mut2;
        _nameLabel.font = nameFont;
        _nameLabel.textColor = t.text;
        _subLabel.font = [NSFont systemFontOfSize:12.5];
        _subLabel.textColor = t.mut;
        _statsLabel.textColor = t.mut;
        _eyebrowLabel.attributedStringValue = RLPArtistSingleLineAttr(RLPTr(@"ARTIST · 艺术家资料"),
            eyebrowFont, t.mut2, 1.4, NSTextAlignmentLeft);
        _nameLabel.attributedStringValue = RLPArtistSingleLineAttr(_artistName.length ? _artistName : RLPTr(@"未知艺术家"),
            nameFont, t.text, -0.5, NSTextAlignmentLeft);
        if ([_btnAlbums isKindOfClass:[RLPArtistChip class]]) {
            [(RLPArtistChip *)_btnAlbums setText:RLPTr(@"查看专辑") color:t.text font:[NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold]];
        }
        if ([_btnRefresh isKindOfClass:[RLPArtistChip class]]) {
            [(RLPArtistChip *)_btnRefresh setText:RLPTr(@"刷新资料") color:t.text font:[NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium]];
        }
        if ([_btnBackList isKindOfClass:[RLPArtistChip class]]) {
            [(RLPArtistChip *)_btnBackList setText:RLPTr(@"返回列表") color:t.text2 font:[NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium]];
        }
        if ([_summaryRetry isKindOfClass:[RLPArtistChip class]]) {
            [(RLPArtistChip *)_summaryRetry setText:_summaryRetry.title color:t.text font:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]];
        }
        if ([_bioToggle isKindOfClass:[RLPArtistChip class]]) {
            [(RLPArtistChip *)_bioToggle setText:_bioToggle.title color:t.text font:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]];
        }
        if (_bioFadeGrad) {
            _bioFadeGrad.colors = @[(__bridge id)[t.bg2 colorWithAlphaComponent:0.0].CGColor,
                                    (__bridge id)t.bg2.CGColor];
        }
        for (NSTextField *ct in @[ _summaryTitle ?: (id)[NSNull null], _bioTitle ?: (id)[NSNull null],
                                   _stylesTitle ?: (id)[NSNull null], _sourcesTitle ?: (id)[NSNull null] ]) {
            if ([ct isKindOfClass:[NSTextField class]]) {
                ct.font = cardTitleFont;
                ct.textColor = t.mut2;
            }
        }
        _summaryTitle.attributedStringValue = RLPArtistSingleLineAttr(RLPTr(@"AI 整理"),
            cardTitleFont, t.mut2, 1.0, NSTextAlignmentLeft);
        _bioTitle.attributedStringValue = RLPArtistSingleLineAttr(RLPTr(@"简介"),
            cardTitleFont, t.mut2, 1.0, NSTextAlignmentLeft);
        _stylesTitle.attributedStringValue = RLPArtistSingleLineAttr(RLPTr(@"风格与相似"),
            cardTitleFont, t.mut2, 1.0, NSTextAlignmentLeft);
        _sourcesTitle.attributedStringValue = RLPArtistSingleLineAttr(RLPTr(@"资料来源"),
            cardTitleFont, t.mut2, 1.0, NSTextAlignmentLeft);
        _avatarView.layer.borderColor = t.line.CGColor;
        _albumsDivider.layer.backgroundColor = t.line.CGColor;
        _albumsTitle.font = albumsTitleFont;
        _albumsTitle.textColor = t.text;
        _albumsTitle.attributedStringValue = RLPArtistSingleLineAttr(RLPTr(@"唱片作品"),
            albumsTitleFont, t.text, 0.2, NSTextAlignmentLeft);
        [_playAllBtn setText:RLPTr(@"播放全部")
                      color:[NSColor whiteColor]
                       font:[NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold]];
    }
    [self.collection reloadData];
    [self refreshAllCards];
    [self.view setNeedsLayout:YES];
}

- (void)applyLanguage {
    self.pageTitle = self.artistName.length ? self.artistName : RLPTr(@"艺术家");
    if (!self.isViewLoaded) return;
    RLPTheme *t = [RLPTheme current];
    if ([_backBtn isKindOfClass:[RLPArtistChip class]]) {
        [(RLPArtistChip *)_backBtn setText:RLPTr(@"返回艺术家列表")
                                     color:t.mut
                                      font:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]];
    } else {
        _backBtn.title = RLPTr(@"返回艺术家列表");
    }
    NSFont *eyebrowFont = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
    NSFont *nameFont = [NSFont systemFontOfSize:28 weight:NSFontWeightBold];
    NSFont *cardTitleFont = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    NSFont *albumsTitleFont = [NSFont systemFontOfSize:14.5 weight:NSFontWeightBold];
    _eyebrowLabel.font = eyebrowFont;
    _eyebrowLabel.textColor = t.mut2;
    _eyebrowLabel.attributedStringValue = RLPArtistSingleLineAttr(RLPTr(@"ARTIST · 艺术家资料"),
        eyebrowFont, t.mut2, 1.4, NSTextAlignmentLeft);
    if (!self.artistName.length) {
        _nameLabel.font = nameFont;
        _nameLabel.textColor = t.text;
        _nameLabel.attributedStringValue = RLPArtistSingleLineAttr(RLPTr(@"未知艺术家"),
            nameFont, t.text, -0.5, NSTextAlignmentLeft);
    }
    [(RLPArtistChip *)_btnAlbums setText:RLPTr(@"查看专辑") color:t.text font:[NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold]];
    [(RLPArtistChip *)_btnRefresh setText:RLPTr(@"刷新资料") color:t.text font:[NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium]];
    [(RLPArtistChip *)_btnBackList setText:RLPTr(@"返回列表") color:t.text2 font:[NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium]];
    for (NSTextField *ct in @[ _summaryTitle ?: (id)[NSNull null], _bioTitle ?: (id)[NSNull null],
                               _stylesTitle ?: (id)[NSNull null], _sourcesTitle ?: (id)[NSNull null] ]) {
        if ([ct isKindOfClass:[NSTextField class]]) {
            ct.font = cardTitleFont;
            ct.textColor = t.mut2;
        }
    }
    _summaryTitle.attributedStringValue = RLPArtistSingleLineAttr(RLPTr(@"AI 整理"),
        cardTitleFont, t.mut2, 1.0, NSTextAlignmentLeft);
    _bioTitle.attributedStringValue = RLPArtistSingleLineAttr(RLPTr(@"简介"),
        cardTitleFont, t.mut2, 1.0, NSTextAlignmentLeft);
    _stylesTitle.attributedStringValue = RLPArtistSingleLineAttr(RLPTr(@"风格与相似"),
        cardTitleFont, t.mut2, 1.0, NSTextAlignmentLeft);
    _sourcesTitle.attributedStringValue = RLPArtistSingleLineAttr(RLPTr(@"资料来源"),
        cardTitleFont, t.mut2, 1.0, NSTextAlignmentLeft);
    [(RLPArtistChip *)_summaryRetry setText:RLPTr(@"重试获取") color:t.text font:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]];
    if ([_bioToggle isKindOfClass:[RLPArtistChip class]]) {
        [(RLPArtistChip *)_bioToggle setText:(_bioExpanded ? RLPTr(@"收起简介") : RLPTr(@"展开全部")) color:t.text font:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]];
    }
    _albumsTitle.font = albumsTitleFont;
    _albumsTitle.textColor = t.text;
    _albumsTitle.attributedStringValue = RLPArtistSingleLineAttr(RLPTr(@"唱片作品"),
        albumsTitleFont, t.text, 0.2, NSTextAlignmentLeft);
    [_playAllBtn setText:RLPTr(@"播放全部")
                  color:[NSColor whiteColor]
                   font:[NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold]];
    [self updateAlbumsStatsText];
    if (self.lastLoadFailed) {
        [self setSubtitle:RLPTr(@"读取失败")];
        self.emptyLabel.stringValue = RLPTr(@"读取失败");
    } else if (![RLPCoreClient shared].started && !self.loaded) {
        [self setSubtitle:RLPTr(@"核心未启动")];
        self.emptyLabel.stringValue = RLPTr(@"核心未启动");
    } else if (self.loaded && self.albums.count == 0) {
        [self setSubtitle:[NSString stringWithFormat:@"0 %@", RLPTr(@"张专辑")]];
        self.emptyLabel.stringValue = RLPTr(@"这个艺术家还没有专辑");
    } else if (self.loaded && self.albums.count > 0) {
        [self setSubtitle:[NSString stringWithFormat:@"%ld %@ · %ld %@",
                           (long)self.albums.count, RLPTr(@"张专辑"),
                           (long)self.totalTracks, RLPTr(@"首")]];
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
