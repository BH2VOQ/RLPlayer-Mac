// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPEqualizerView.mm — 20 段 PEQ + OPRA 耳机目标曲线
//
// 后端契约（已核实 src/net/ui_script.h 的 peqApply / peqLoadState / opra*）：
//   GET  /api/peq  → {"ok":true,"bypass":bool,"preamp":dB,"fs":Hz,
//                     "bands":[{"f":Hz,"g":dB,"q":Q,"type":"peak"},…20],
//                     "points":[[Hz,dB],…]}   ← 曲线由后端算，前端不抄第二份
//   POST /api/peq  body "bypass=0&preamp=<n>&bands=<f,g,q,type;…>"（20 段全量）
//                  → 返回**完整新状态**，必须用它刷新曲线（web 版踩过的坑）
//   POST /api/peq/preset  body "action=list|save|load|delete&name=…"
//   GET  /api/opra/index          → {"ok":true,"items":[["id","vendor","name"],…]}
//                                    （**不带 q**：web 全量拉一次做本地过滤；items 是数组三元组）
//        也接受 ?q= 的历史形态，但原生不再用它（第8项：旧实现按字典解析数组 ⟹ 搜索结果恒空）
//   GET  /api/opra/presets?productId=… → {"ok":true,"items":[
//                                    {"id","author","details","link","gainDb","bandsCount"}]}
//                                    （**没有 name 字段**：显示名 = author · details）
//   POST /api/opra/apply  body "productId=…&presetId=…" → {"ok":true,"path":…}
//        成功后必须写回 POST /api/settings 的 eq=/opraproduct=/oprapreset=（web saveSettings(true)），
//        否则后端热重载不触发（第8项断点③/④）
//
// 节流：文字输入 260ms 后才 POST。每敲一个字符打一次后端会把正在播的歌反复重启。
#import "RLPEqualizerView.h"
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPTheme.h"
#import "RLPTargetCurve.h"

#include <cmath>
#include <initializer_list>

#pragma mark - 频响曲线（自绘）

@interface RLPEQCurveView : NSView
@property (nonatomic, copy) NSArray<NSArray<NSNumber *> *> *points;
/// 每个 PEQ 段的中心频率（用于把鼠标 x 映射到最近的一段）
@property (nonatomic, copy) NSArray<NSNumber *> *bandFreqs;
/// 手动拖拽曲线：返回 (段索引, 目标增益 dB)。web 版 PEQ_DRAG 同语义。
@property (nonatomic, copy) void (^onDragBand)(NSInteger index, double gainDb);
/// 耳机目标曲线图层（第8项）。web 用 `.tc-curve` + targetCurveSvg 画在预设卡片/说明区；
/// 原生直接叠加到 EQ 图上，用户能看到"我选的目标曲线长这样"以及它与当前 PEQ 的关系。
/// nil = 不画（没选预设时不该假装有目标）。
@property (nonatomic, strong, nullable) RLPTargetCurve *targetCurve;   // 曲线表是共享只读数据，不 copy（RLPTargetCurve 不是 NSCopying）
@end

@implementation RLPEQCurveView

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    RLPTheme *t = [RLPTheme current];
    NSRect b = self.bounds;
    [t.bg2 setFill];
    NSRectFill(b);

    const CGFloat padL = 34, padR = 8, padT = 8, padB = 18;
    NSRect plot = NSMakeRect(b.origin.x + padL, b.origin.y + padB,
                             b.size.width - padL - padR, b.size.height - padT - padB);
    if (plot.size.width <= 4 || plot.size.height <= 4) return;

    // x 轴对数 20Hz..20kHz；y 轴 ±18dB
    const double fMin = 20.0, fMax = 20000.0, dbMax = 18.0;
    const double lfMin = log10(fMin), lfMax = log10(fMax);
    CGFloat (^X)(double) = ^CGFloat(double f) {
        double c = MAX(fMin, MIN(fMax, f));
        return plot.origin.x + (CGFloat)((log10(c) - lfMin) / (lfMax - lfMin)) * plot.size.width;
    };
    CGFloat (^Y)(double) = ^CGFloat(double db) {
        double c = MAX(-dbMax, MIN(dbMax, db));
        return plot.origin.y + (CGFloat)((c + dbMax) / (2 * dbMax)) * plot.size.height;
    };

    // 网格：十倍频程 + 每 6dB 一条
    [t.line setStroke];
    for (double f : { 100.0, 1000.0, 10000.0 }) {
        NSBezierPath *g = [NSBezierPath bezierPath];
        [g moveToPoint:NSMakePoint(X(f), plot.origin.y)];
        [g lineToPoint:NSMakePoint(X(f), NSMaxY(plot))];
        g.lineWidth = 0.5;
        [g stroke];
    }
    for (double db = -12.0; db <= 12.0; db += 6.0) {
        if (fabs(db) < 0.001) continue;
        NSBezierPath *g = [NSBezierPath bezierPath];
        [g moveToPoint:NSMakePoint(plot.origin.x, Y(db))];
        [g lineToPoint:NSMakePoint(NSMaxX(plot), Y(db))];
        g.lineWidth = 0.5;
        [g stroke];
    }
    // 0dB 基准线画粗一点
    NSBezierPath *zero = [NSBezierPath bezierPath];
    [zero moveToPoint:NSMakePoint(plot.origin.x, Y(0))];
    [zero lineToPoint:NSMakePoint(NSMaxX(plot), Y(0))];
    zero.lineWidth = 1.0;
    [t.mut setStroke];
    [zero stroke];

    // 轴标注
    NSDictionary *attrs = @{ NSFontAttributeName: t.small, NSForegroundColorAttributeName: t.mut };
    [@"+18" drawAtPoint:NSMakePoint(2, NSMaxY(plot) - 12) withAttributes:attrs];
    [@"0" drawAtPoint:NSMakePoint(2, Y(0) - 6) withAttributes:attrs];
    [@"-18" drawAtPoint:NSMakePoint(2, plot.origin.y) withAttributes:attrs];
    [@"20" drawAtPoint:NSMakePoint(plot.origin.x, 2) withAttributes:attrs];
    [@"1k" drawAtPoint:NSMakePoint(X(1000) - 6, 2) withAttributes:attrs];
    [@"20k" drawAtPoint:NSMakePoint(NSMaxX(plot) - 22, 2) withAttributes:attrs];

    if (!self.points.count) {
        // 没数据就如实说，不画一条假装是"平直响应"的线
        NSString *msg = RLPTr(@"无曲线数据");
        NSSize sz = [msg sizeWithAttributes:attrs];
        [msg drawAtPoint:NSMakePoint(NSMidX(plot) - sz.width / 2, NSMidY(plot) - sz.height / 2)
          withAttributes:attrs];
        return;
    }

    // ---- 耳机目标曲线图层（第8项）----
    // 画在 PEQ 主曲线**之前**：主曲线压在上面，用户能同时看到"当前 EQ"与"目标形状"。
    // 竖直量程用 web 的 MAXDB=9 / MINDB=-2（映射到同一 plot 高度），与 web 的示意一致；
    // 用虚线 + 次级色，避免与实线 PEQ 混淆。
    if (self.targetCurve) {
        const double kMaxDb = 9.0, kMinDb = -2.0;
        NSMutableArray<NSValue *> *tpts = [NSMutableArray array];
        for (NSArray<NSNumber *> *p in self.targetCurve.points) {
            if (p.count < 2) continue;
            const double x = MAX(0.0, MIN(1.0, p[0].doubleValue));
            const double db = MAX(kMinDb, MIN(kMaxDb, p[1].doubleValue));
            const CGFloat px = plot.origin.x + (CGFloat)x * plot.size.width;
            const CGFloat py = plot.origin.y + (CGFloat)((kMaxDb - db) / (kMaxDb - kMinDb)) * plot.size.height;
            [tpts addObject:[NSValue valueWithPoint:NSMakePoint(px, py)]];
        }
        if (tpts.count >= 2) {
            NSBezierPath *tc = [NSBezierPath bezierPath];
            [tc moveToPoint:tpts[0].pointValue];
            for (NSUInteger i = 1; i < tpts.count; ++i) [tc lineToPoint:tpts[i].pointValue];
            tc.lineWidth = 1.4;
            CGFloat dash[2] = { 4.0, 3.0 };
            [tc setLineDash:dash count:2 phase:0];
            [(t.accent2 ?: t.accent) setStroke];
            [tc stroke];
            // 端点小圆点（web targetCurveSvg 的首尾 circle）
            for (NSValue *vv in @[ tpts.firstObject, tpts.lastObject ]) {
                const NSPoint pt = vv.pointValue;
                NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:
                                     NSMakeRect(pt.x - 2, pt.y - 2, 4, 4)];
                [(t.accent2 ?: t.accent) setFill];
                [dot fill];
            }
        }
    }

    NSBezierPath *curve = [NSBezierPath bezierPath];
    BOOL started = NO;
    for (NSArray<NSNumber *> *pt in self.points) {
        if (pt.count < 2) continue;
        const double f = pt[0].doubleValue, db = pt[1].doubleValue;
        if (!isfinite(f) || !isfinite(db) || f <= 0) continue;
        NSPoint p = NSMakePoint(X(f), Y(db));
        if (!started) { [curve moveToPoint:p]; started = YES; }
        else [curve lineToPoint:p];
    }
    if (started) {
        curve.lineWidth = 1.8;
        [t.accent setStroke];
        [curve stroke];
    }
}

#pragma mark - 曲线拖拽（web PEQ_DRAG：拖动波形图改对应段的增益）

// 与 drawRect 同一套坐标（对数频率 x、±18dB y）。
- (NSRect)plotRect {
    NSRect b = self.bounds;
    const CGFloat padL = 34, padR = 8, padT = 8, padB = 18;
    return NSMakeRect(b.origin.x + padL, b.origin.y + padB,
                      b.size.width - padL - padR, b.size.height - padT - padB);
}

- (CGFloat)xForFreq:(double)f {
    NSRect plot = [self plotRect];
    const double fMin = 20.0, fMax = 20000.0;
    double c = MAX(fMin, MIN(fMax, f));
    return plot.origin.x + (CGFloat)((log10(c) - log10(fMin)) / (log10(fMax) - log10(fMin))) * plot.size.width;
}

- (void)applyDragEvent:(NSEvent *)event {
    if (!self.onDragBand || self.bandFreqs.count == 0) return;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSRect plot = [self plotRect];
    if (p.x < plot.origin.x || p.x > NSMaxX(plot)) return;
    if (p.y < plot.origin.y || p.y > NSMaxY(plot)) return;
    NSInteger best = -1;
    CGFloat bestDist = CGFLOAT_MAX;
    for (NSUInteger i = 0; i < self.bandFreqs.count; ++i) {
        CGFloat bx = [self xForFreq:self.bandFreqs[i].doubleValue];
        CGFloat d = fabs(bx - p.x);
        if (d < bestDist) { bestDist = d; best = (NSInteger)i; }
    }
    if (best < 0) return;
    double db = -18.0 + ((p.y - plot.origin.y) / plot.size.height) * 36.0;
    if (db > 18.0) db = 18.0;
    if (db < -18.0) db = -18.0;
    self.onDragBand(best, db);
}

- (void)mouseDown:(NSEvent *)event {
    if (self.onDragBand) { [self applyDragEvent:event]; return; }
    [super mouseDown:event];
}

- (void)mouseDragged:(NSEvent *)event {
    if (self.onDragBand) { [self applyDragEvent:event]; return; }
    [super mouseDragged:event];
}
@end

#pragma mark - OPRA 型号/预设卡片（web #eqModelCards / #eqPresetCards）

/// 型号卡片上的一张小目标曲线（web `.tc-curve` 的同构）：只画曲线，不画坐标轴。
@interface RLPOpraCurveThumb : NSView
@property (nonatomic, strong, nullable) RLPTargetCurve *targetCurve;
@end

@implementation RLPOpraCurveThumb
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    RLPTheme *t = [RLPTheme current];
    NSRect b = NSInsetRect(self.bounds, 1, 1);
    if (b.size.width < 4 || b.size.height < 4) return;
    [t.bg2 setFill];
    NSRectFill(b);
    NSArray<NSValue *> *pts = [RLPTargetCurveLibrary plotPoints:self.targetCurve inRect:b];
    if (pts.count < 2) return;
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:pts.firstObject.pointValue];
    for (NSUInteger i = 1; i < pts.count; ++i) [p lineToPoint:pts[i].pointValue];
    p.lineWidth = 1.4;
    [(t.accent2 ?: t.accent) setStroke];
    [p stroke];
    for (NSValue *v in @[ pts.firstObject, pts.lastObject ]) {
        NSPoint pt = v.pointValue;
        NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(pt.x - 2, pt.y - 2, 4, 4)];
        [(t.accent2 ?: t.accent) setFill];
        [dot fill];
    }
}
@end

/// 型号卡片：`vendor · name` + 「OPRA 校准预设 · 查看调音预设」。点击 = 选中并加载预设墙。
@interface RLPOpraModelCard : NSView
@property (nonatomic, copy) NSString *productId;
@property (nonatomic, copy) NSString *vendor;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, copy, nullable) void (^onClick)(void);
@end

@implementation RLPOpraModelCard
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    if (self) {
        self.identifier = @"opra.model.card";
        self.wantsLayer = YES;
        self.layer.cornerRadius = 8;
        self.layer.borderWidth = 1;
        [self applyTheme];
    }
    return self;
}
- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.layer.backgroundColor = (self.active ? t.accentWeak : t.bg2).CGColor;
    self.layer.borderColor = (self.active ? t.accent : t.line).CGColor;
}
- (void)setActive:(BOOL)active { _active = active; [self applyTheme]; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    RLPTheme *t = [RLPTheme current];
    NSString *title = self.vendor.length
        ? [NSString stringWithFormat:@"%@ · %@", self.vendor, self.name ?: @""]
        : (self.name ?: @"");
    NSDictionary *ta = @{ NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
                          NSForegroundColorAttributeName: t.text };
    NSDictionary *sa = @{ NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightRegular],
                          NSForegroundColorAttributeName: t.mut2 };
    [title drawInRect:NSMakeRect(12, 7, self.bounds.size.width - 24, 18) withAttributes:ta];
    [RLPTr(@"OPRA 校准预设 · 查看调音预设")
        drawInRect:NSMakeRect(12, 27, self.bounds.size.width - 24, 14) withAttributes:sa];
}
- (void)mouseDown:(NSEvent *)event {
    (void)event;
    if (self.onClick) self.onClick();
}
- (void)click { if (self.onClick) self.onClick(); }
@end

/// 预设卡片：目标曲线小图 / 作者·详情 / 段数 / 前级增益 / 应用到 EQ / 当前态。
@interface RLPOpraPresetCard : NSView
@property (nonatomic, assign) NSInteger presetIndex;
@property (nonatomic, copy) NSString *productId;
@property (nonatomic, copy) NSString *presetId;
@property (nonatomic, copy) NSString *titleText;
@property (nonatomic, copy) NSString *detailsText;
@property (nonatomic, copy) NSString *curveName;
@property (nonatomic, copy) NSString *scene;
@property (nonatomic, assign) NSInteger bandsCount;
@property (nonatomic, assign) double gainDb;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, strong) RLPOpraCurveThumb *thumb;
@property (nonatomic, strong) NSButton *applyBtn;
@property (nonatomic, copy, nullable) void (^onSelect)(void);
@property (nonatomic, copy, nullable) void (^onApply)(void);
@end

@implementation RLPOpraPresetCard
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    if (self) {
        self.identifier = @"opra.preset.card";
        self.wantsLayer = YES;
        self.layer.cornerRadius = 9;
        self.layer.borderWidth = 1;
        for (NSString *ident in @[ @"opra.preset.title", @"opra.preset.badge",
                                   @"opra.preset.meta", @"opra.preset.scene" ]) {
            NSTextField *l = [NSTextField labelWithString:@""];
            l.identifier = ident;
            l.bezeled = NO;
            l.drawsBackground = NO;
            l.editable = NO;
            l.selectable = NO;
            l.maximumNumberOfLines = 2;
            l.lineBreakMode = NSLineBreakByTruncatingTail;
            [self addSubview:l];
        }
        self.thumb = [[RLPOpraCurveThumb alloc] initWithFrame:NSZeroRect];
        self.thumb.identifier = @"opra.preset.curve";
        [self addSubview:self.thumb];
        self.applyBtn = [NSButton buttonWithTitle:RLPTr(@"应用到 EQ")
                                            target:self action:@selector(onApplyButton:)];
        self.applyBtn.bezelStyle = NSBezelStyleRounded;
        self.applyBtn.identifier = @"opra.preset.apply";
        self.applyBtn.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        [self addSubview:self.applyBtn];
        [self applyTheme];
    }
    return self;
}
- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.layer.backgroundColor = (self.active ? t.accentWeak : t.bg2).CGColor;
    self.layer.borderColor = (self.active ? t.accent : t.line).CGColor;
    self.applyBtn.title = self.active ? RLPTr(@"已应用当前预设") : RLPTr(@"应用到 EQ");
    NSTextField *title = [self labelWithIdentifier:@"opra.preset.title"];
    title.font = [NSFont systemFontOfSize:13.5 weight:NSFontWeightSemibold];
    title.textColor = t.text;
    title.stringValue = self.titleText ?: @"";
    NSTextField *badge = [self labelWithIdentifier:@"opra.preset.badge"];
    badge.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
    badge.textColor = t.accentText;
    badge.stringValue = [NSString stringWithFormat:@"%ld %@", (long)self.bandsCount, RLPTr(@"段")];
    badge.alignment = NSTextAlignmentRight;
    NSTextField *meta = [self labelWithIdentifier:@"opra.preset.meta"];
    meta.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightRegular];
    meta.textColor = t.mut2;
    meta.stringValue = [NSString stringWithFormat:@"%@%.1f dB · %@%ld %@",
                        RLPTr(@"前级增益："), self.gainDb, RLPTr(@"频段数："),
                        (long)self.bandsCount, RLPTr(@"段")];
    meta.maximumNumberOfLines = 1;
    NSTextField *desc = [self labelWithIdentifier:@"opra.preset.scene"];
    desc.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    desc.textColor = t.mut;
    desc.stringValue = [NSString stringWithFormat:@"%@%@", RLPTr(@"目标曲线："), self.curveName ?: @""];
    desc.maximumNumberOfLines = 1;
    self.thumb.targetCurve = [RLPTargetCurveLibrary curveForKind:
        [RLPTargetCurveLibrary kindForDetails:self.detailsText]];
    [self.thumb setNeedsDisplay:YES];
    [self setNeedsLayout:YES];
}
- (void)setActive:(BOOL)active { _active = active; [self applyTheme]; }
- (NSTextField *)labelWithIdentifier:(NSString *)ident {
    for (NSView *v in self.subviews) {
        if ([v.identifier isEqualToString:ident] && [v isKindOfClass:[NSTextField class]])
            return (NSTextField *)v;
    }
    return nil;
}
- (void)layout {
    [super layout];
    const CGFloat W = self.bounds.size.width;
    [(NSTextField *)[self labelWithIdentifier:@"opra.preset.title"]
        setFrame:NSMakeRect(12, 8, W - 92, 18)];
    [(NSTextField *)[self labelWithIdentifier:@"opra.preset.badge"]
        setFrame:NSMakeRect(W - 78, 9, 66, 16)];
    self.thumb.frame = NSMakeRect(12, 32, W - 24, 40);
    [(NSTextField *)[self labelWithIdentifier:@"opra.preset.scene"]
        setFrame:NSMakeRect(12, 78, W - 24, 16)];
    [(NSTextField *)[self labelWithIdentifier:@"opra.preset.meta"]
        setFrame:NSMakeRect(12, 100, W - 24, 16)];
    self.applyBtn.frame = NSMakeRect(MAX(12, W - 134), 126, 122, 26);
}
- (void)mouseDown:(NSEvent *)event {
    (void)event;
    if (self.onSelect) self.onSelect();
}
- (void)onApplyButton:(id)sender { (void)sender; if (self.onApply) self.onApply(); }
- (void)selectCard { if (self.onSelect) self.onSelect(); }
- (void)applyCard { if (self.onApply) self.onApply(); }
@end


#pragma mark - 均衡主视图

@interface RLPEqualizerView () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSStackView *stack;
@property (nonatomic, strong) NSScrollView *scroll;
@property (nonatomic, strong) NSArray<NSLayoutConstraint *> *scrollConstraints;
@property (nonatomic, assign) BOOL embeddedInPage;
@property (nonatomic, strong) RLPEQCurveView *curve;
@property (nonatomic, strong) NSSwitch *bypass;
@property (nonatomic, strong) NSTextField *preamp;
@property (nonatomic, strong) NSTextField *status;
@property (nonatomic, strong) NSTableView *bandTable;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *bands;
@property (nonatomic, strong) NSTimer *applyTimer;
@property (nonatomic, assign) BOOL loading;
- (void)applyOpraQuery:(NSString *)qq;
- (void)previewTargetCurveForPreset:(nullable NSDictionary *)p;
- (void)resetTargetCurvePreview;
@property (nonatomic, strong) NSPopUpButton *presetPop;
@property (nonatomic, strong) NSTextField *presetName;
@property (nonatomic, strong) NSTextField *opraQuery;
@property (nonatomic, strong) NSStackView *opraModelCards;
@property (nonatomic, strong) NSStackView *opraPresetCards;
@property (nonatomic, strong) NSTextField *opraGuide;
@property (nonatomic, strong) NSTextField *opraSelectedTitle;
@property (nonatomic, copy) NSArray<RLPOpraModelCard *> *opraModelCardViews;
@property (nonatomic, copy) NSArray<RLPOpraPresetCard *> *opraPresetCardViews;
@property (nonatomic, assign) NSInteger opraSelectedProductIndex;
@property (nonatomic, assign) NSInteger opraSelectedPresetIndex;
@property (nonatomic, copy) NSString *appliedProductId;
@property (nonatomic, copy) NSString *appliedPresetId;
@property (nonatomic, strong) NSTextField *opraStatus;
@property (nonatomic, copy) NSArray<NSDictionary *> *opraItems;
@property (nonatomic, copy) NSArray<NSDictionary *> *opraPresets;
/// /api/opra/index 的一次性缓存（web loadOpraIndex 同语义：**不带 q**，全量拉一次，前端本地过滤）。
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> *opraIndexCache;
/// 型号切换竞态守卫（web OPRA_CUR_PRODUCT：只认最后一次选择）。
@property (nonatomic, assign) NSInteger opraProductSeq;
/// 目标曲线说明（web showTargetCurveInfo 的原生同构：名称/是什么/适合谁/增益与段数）。
@property (nonatomic, strong) NSTextField *opraInfo;
@end

@implementation RLPEqualizerView

- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    if (self) {
        _bands = [NSMutableArray array];
        _opraItems = @[];
        _opraPresets = @[];
        _opraIndexCache = nil;
        _opraProductSeq = 0;
        _opraSelectedProductIndex = -1;
        _opraSelectedPresetIndex = -1;
        _appliedProductId = @"";
        _appliedPresetId = @"";
        [self build];
    }
    return self;
}

- (void)build {
    RLPTheme *t = [RLPTheme current];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:self.bounds];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.drawsBackground = NO;
    // 内层滚动条默认不画（设置页外层已有整页滚动；独立使用时可显式打开）
    scroll.hasVerticalScroller = NO;
    [self addSubview:scroll];
    self.scroll = scroll;

    self.stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.stack.alignment = NSLayoutAttributeLeading;
    self.stack.spacing = 10;
    self.stack.edgeInsets = NSEdgeInsetsMake(4, 0, 16, 0);
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = self.stack;
    self.scrollConstraints = @[
        [self.stack.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [self.stack.trailingAnchor constraintEqualToAnchor:scroll.contentView.trailingAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [self.stack.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
    ];
    [NSLayoutConstraint activateConstraints:self.scrollConstraints];

    NSStackView *top = [[NSStackView alloc] init];
    top.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    top.spacing = 10;
    self.bypass = [[NSSwitch alloc] initWithFrame:NSZeroRect];
    self.bypass.identifier = @"peqBypass";     // web #peqBypass（行为扫描锚点）
    self.bypass.target = self;
    self.bypass.action = @selector(onBypass:);
    [top addArrangedSubview:self.bypass];
    [top addArrangedSubview:RLPLabel(RLPTr(@"旁路（不改声音）"), t.body, t.text)];
    [top addArrangedSubview:RLPLabel(RLPTr(@"前级"), t.body, t.text)];
    self.preamp = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.preamp.identifier = @"peqPreamp";     // web #peqPreamp（行为扫描锚点）
    self.preamp.stringValue = @"0";
    self.preamp.target = self;
    self.preamp.action = @selector(onPreampEnter:);
    [[self.preamp.widthAnchor constraintEqualToConstant:64] setActive:YES];
    [top addArrangedSubview:self.preamp];
    [top addArrangedSubview:RLPLabel(@"dB", t.small, t.mut)];
    [self.stack addArrangedSubview:top];

    self.status = RLPLabel(@"", t.small, t.mut);
    self.status.maximumNumberOfLines = 2;
    self.status.lineBreakMode = NSLineBreakByWordWrapping;
    [self.stack addArrangedSubview:self.status];

    self.curve = [[RLPEQCurveView alloc] initWithFrame:NSZeroRect];
    self.curve.identifier = @"eq.curve";          // 判据（第8项像素采样）用它定位曲线视图
    self.curve.wantsLayer = YES;
    self.curve.layer.cornerRadius = 8;
    self.curve.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stack addArrangedSubview:self.curve];
    [NSLayoutConstraint activateConstraints:@[
        [self.curve.heightAnchor constraintEqualToConstant:170],
        [self.curve.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-4],
    ]];
    // web PEQ_DRAG 等价：在曲线上按住拖动 → 改最近一段的增益（260ms 节流后下发）。
    __weak __typeof__(self) weakCurve = self;
    self.curve.onDragBand = ^(NSInteger idx, double db) {
        __typeof__(self) s = weakCurve;
        if (!s || idx < 0 || idx >= (NSInteger)s.bands.count) return;
        s.bands[(NSUInteger)idx][@"g"] = @(db);
        [s.bandTable reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)idx]
                             columnIndexes:[NSIndexSet indexSetWithIndex:0]];
        [s scheduleApply];
    };

    [self.stack addArrangedSubview:RLPLabel(RLPTr(@"20 段参数"),
        [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], t.text)];
    self.bandTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.bandTable.identifier = @"peq.bands";
    self.bandTable.dataSource = self;
    self.bandTable.delegate = self;
    self.bandTable.rowHeight = 26;
    self.bandTable.backgroundColor = t.bg;
    NSArray *titles = @[ @"#", RLPTr(@"频率 Hz"), RLPTr(@"增益 dB"), @"Q", RLPTr(@"类型") ];
    NSArray *ids = @[ @"n", @"f", @"g", @"q", @"type" ];
    NSArray *ws = @[ @34, @90, @90, @70, @130 ];
    for (NSInteger i = 0; i < (NSInteger)titles.count; ++i) {
        NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:ids[i]];
        c.title = titles[i];
        c.width = [ws[i] doubleValue];
        [self.bandTable addTableColumn:c];
    }
    NSScrollView *bs = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    bs.documentView = self.bandTable;
    bs.hasVerticalScroller = NO;             // 20 段一次全显示（用户：只要外层那个滚动条）
    bs.drawsBackground = NO;
    bs.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stack addArrangedSubview:bs];
    [NSLayoutConstraint activateConstraints:@[
        // 表头 + 20 行 × 26pt：不再用 300pt 内层滚动裁掉一半参数（18/20 段本该可见）。
        [bs.heightAnchor constraintEqualToConstant:20 * 26 + 26],
        [bs.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-4],
    ]];

    [self buildPresetSection];
    [self buildOpraSection];
}

- (void)buildPresetSection {
    RLPTheme *t = [RLPTheme current];
    [self.stack addArrangedSubview:RLPLabel(RLPTr(@"PEQ 预设"),
        [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], t.text)];
    NSStackView *row = [[NSStackView alloc] init];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 8;
    self.presetPop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [[self.presetPop.widthAnchor constraintEqualToConstant:200] setActive:YES];
    [row addArrangedSubview:self.presetPop];
    self.presetName = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.presetName.placeholderString = RLPTr(@"预设名");
    [[self.presetName.widthAnchor constraintEqualToConstant:150] setActive:YES];
    [row addArrangedSubview:self.presetName];
    NSArray *acts = @[ @[RLPTr(@"加载"), @"load"], @[RLPTr(@"保存"), @"save"], @[RLPTr(@"删除"), @"delete"] ];
    for (NSArray *pair in acts) {
        NSButton *b = [NSButton buttonWithTitle:pair[0] target:self action:@selector(onPresetAction:)];
        b.bezelStyle = NSBezelStyleRounded;
        b.identifier = pair[1];
        [row addArrangedSubview:b];
    }
    [self.stack addArrangedSubview:row];
}

- (void)buildOpraSection {
    RLPTheme *t = [RLPTheme current];
    [self.stack addArrangedSubview:RLPLabel(RLPTr(@"OPRA 耳机目标曲线"),
        [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], t.text)];
    [self.stack addArrangedSubview:RLPLabel(
        RLPTr(@"输入耳机型号搜索；应用后会把 PEQ 换成该耳机的补偿曲线"), t.small, t.mut)];

    NSStackView *r1 = [[NSStackView alloc] init];
    r1.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r1.spacing = 8;
    self.opraQuery = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.opraQuery.placeholderString = RLPTr(@"例如 HD650");
    self.opraQuery.identifier = @"opra.query";
    self.opraQuery.target = self;
    self.opraQuery.action = @selector(onOpraSearch:);
    [[self.opraQuery.widthAnchor constraintEqualToConstant:220] setActive:YES];
    [r1 addArrangedSubview:self.opraQuery];
    NSButton *sb = [NSButton buttonWithTitle:RLPTr(@"搜索") target:self action:@selector(onOpraSearch:)];
    sb.bezelStyle = NSBezelStyleRounded;
    sb.identifier = @"opra.search";
    [r1 addArrangedSubview:sb];
    [self.stack addArrangedSubview:r1];

    // 型号卡片区（web #eqModelCards）：点击才加载该型号的预设墙。
    self.opraGuide = RLPLabel(RLPTr(@"点击卡片选中"), t.small, t.mut);
    self.opraGuide.identifier = @"opra.guide";
    self.opraGuide.hidden = YES;
    [self.stack addArrangedSubview:self.opraGuide];

    self.opraModelCards = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.opraModelCards.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.opraModelCards.alignment = NSLayoutAttributeLeading;
    self.opraModelCards.spacing = 6;
    self.opraModelCards.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stack addArrangedSubview:self.opraModelCards];
    [[self.opraModelCards.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-4] setActive:YES];

    // 预设卡片墙（web #eqPresetCards）：作者·详情 / 段数 / 曲线小图 / 前级增益 / 应用按钮。
    self.opraSelectedTitle = RLPLabel(@"", [NSFont systemFontOfSize:13.5 weight:NSFontWeightSemibold], t.text);
    self.opraSelectedTitle.identifier = @"opra.presets.title";
    self.opraSelectedTitle.maximumNumberOfLines = 2;
    self.opraSelectedTitle.lineBreakMode = NSLineBreakByWordWrapping;
    self.opraSelectedTitle.hidden = YES;
    [self.stack addArrangedSubview:self.opraSelectedTitle];

    self.opraPresetCards = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.opraPresetCards.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.opraPresetCards.alignment = NSLayoutAttributeLeading;
    self.opraPresetCards.spacing = 8;
    self.opraPresetCards.translatesAutoresizingMaskIntoConstraints = NO;
    self.opraPresetCards.hidden = YES;
    [self.stack addArrangedSubview:self.opraPresetCards];
    [[self.opraPresetCards.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-4] setActive:YES];

    self.opraStatus = RLPLabel(@"", t.small, t.mut);
    self.opraStatus.identifier = @"opra.status";
    [self.stack addArrangedSubview:self.opraStatus];

    // web showTargetCurveInfo：选中的目标曲线要给出「名称 / 是什么 / 适合谁 / 前级增益 / 段数」。
    self.opraInfo = RLPLabel(@"", t.small, t.mut);
    self.opraInfo.identifier = @"opra.info";
    self.opraInfo.maximumNumberOfLines = 6;
    self.opraInfo.lineBreakMode = NSLineBreakByWordWrapping;
    [[self.opraInfo.widthAnchor constraintEqualToConstant:600] setActive:YES];
    [self.stack addArrangedSubview:self.opraInfo];
}

#pragma mark - OPRA 卡片渲染 / 选择 / 应用

/// 清空栈里的卡片（arrangedSubviews + superview 双清，避免隐藏层残留）。
- (void)clearCardStack:(NSStackView *)stack {
    for (NSView *v in [stack.arrangedSubviews copy]) {
        [stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
}

- (void)renderModelCards {
    [self clearCardStack:self.opraModelCards];
    NSMutableArray<RLPOpraModelCard *> *cards = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.opraItems.count; ++i) {
        NSDictionary *x = self.opraItems[i];
        RLPOpraModelCard *c = [[RLPOpraModelCard alloc] initWithFrame:NSMakeRect(0, 0, 400, 48)];
        c.productId = [x[@"id"] isKindOfClass:[NSString class]] ? x[@"id"] : @"";
        c.vendor = [x[@"vendor"] isKindOfClass:[NSString class]] ? x[@"vendor"] : @"";
        c.name = [x[@"name"] isKindOfClass:[NSString class]] ? x[@"name"] : @"";
        c.active = ([c.productId isEqualToString:self.appliedProductId] ||
                    (NSInteger)i == self.opraSelectedProductIndex);
        __weak __typeof__(self) ws = self;
        c.onClick = ^{ [ws onModelCardSelected:(NSInteger)i]; };
        c.translatesAutoresizingMaskIntoConstraints = NO;
        [self.opraModelCards addArrangedSubview:c];
        [[c.widthAnchor constraintEqualToAnchor:self.opraModelCards.widthAnchor] setActive:YES];
        [[c.heightAnchor constraintEqualToConstant:48] setActive:YES];
        [cards addObject:c];
    }
    self.opraModelCardViews = cards;
}

- (void)onModelCardSelected:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.opraItems.count) return;
    self.opraSelectedProductIndex = index;
    [self renderModelCards];
    [self loadProductPresets:index];
}

- (void)renderPresetCards {
    [self clearCardStack:self.opraPresetCards];
    if (self.opraSelectedProductIndex < 0 ||
        self.opraSelectedProductIndex >= (NSInteger)self.opraItems.count) {
        self.opraPresetCardViews = @[];
        return;
    }
    NSDictionary *prod = self.opraItems[(NSUInteger)self.opraSelectedProductIndex];
    NSString *pid = [prod[@"id"] isKindOfClass:[NSString class]] ? prod[@"id"] : @"";
    NSMutableArray<RLPOpraPresetCard *> *cards = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.opraPresets.count; ++i) {
        NSDictionary *p = self.opraPresets[i];
        RLPOpraPresetCard *c = [[RLPOpraPresetCard alloc] initWithFrame:NSMakeRect(0, 0, 400, 164)];
        c.presetIndex = (NSInteger)i;
        c.productId = pid;
        c.presetId = [p[@"id"] isKindOfClass:[NSString class]] ? p[@"id"] : @"";
        NSString *author = [p[@"author"] isKindOfClass:[NSString class]] ? p[@"author"] : @"";
        NSString *details = [p[@"details"] isKindOfClass:[NSString class]] ? p[@"details"] : @"";
        c.titleText = author.length ? author : @"OPRA";
        if (details.length) c.titleText = [c.titleText stringByAppendingFormat:@" · %@", details];
        c.detailsText = details;
        c.bandsCount = [p[@"bandsCount"] respondsToSelector:@selector(integerValue)]
            ? [p[@"bandsCount"] integerValue] : 0;
        c.gainDb = [p[@"gainDb"] respondsToSelector:@selector(doubleValue)] ? [p[@"gainDb"] doubleValue] : 0.0;
        c.curveName = [RLPTargetCurveLibrary targetCurveNameForDetails:details author:author];
        c.active = ([c.productId isEqualToString:self.appliedProductId] &&
                    [c.presetId isEqualToString:self.appliedPresetId]);
        __weak __typeof__(self) ws = self;
        __weak RLPOpraPresetCard *weakCard = c;
        c.onSelect = ^{
            ws.opraSelectedPresetIndex = (NSInteger)i;
            [ws previewTargetCurveForPreset:ws.opraPresets.count > (NSUInteger)i ? ws.opraPresets[i] : nil];
            [ws renderPresetCards];
        };
        c.onApply = ^{ [ws applyOpraPreset:pid presetId:weakCard.presetId]; };
        [c applyTheme];
        c.translatesAutoresizingMaskIntoConstraints = NO;
        [self.opraPresetCards addArrangedSubview:c];
        [[c.widthAnchor constraintEqualToAnchor:self.opraPresetCards.widthAnchor] setActive:YES];
        [[c.heightAnchor constraintEqualToConstant:164] setActive:YES];
        [cards addObject:c];
    }
    self.opraPresetCardViews = cards;
}

#pragma mark - 20 段表格（可编辑）

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)self.bands.count; }

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    RLPTheme *t = [RLPTheme current];
    if (row < 0 || row >= (NSInteger)self.bands.count) return nil;
    NSMutableDictionary *band = self.bands[row];
    NSString *key = col.identifier;

    if ([key isEqualToString:@"n"] || [key isEqualToString:@"f"]) {
        NSTextField *l = [tv makeViewWithIdentifier:key owner:self];
        if (!l) { l = RLPLabel(@"", t.body, t.text); l.identifier = key; }
        if ([key isEqualToString:@"n"]) l.stringValue = [NSString stringWithFormat:@"%ld", (long)(row + 1)];
        else l.stringValue = [NSString stringWithFormat:@"%.1f", [band[@"f"] doubleValue]];
        l.textColor = t.text;
        return l;
    }
    if ([key isEqualToString:@"type"]) {
        NSPopUpButton *p = [tv makeViewWithIdentifier:key owner:self];
        if (!p) {
            p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
            [p addItemsWithTitles:@[ @"peak", @"lowshelf", @"highshelf" ]];
            p.identifier = key;
            p.target = self;
            p.action = @selector(onBandType:);
            p.font = t.small;
        }
        p.tag = row;
        NSString *ty = [band[@"type"] isKindOfClass:[NSString class]] ? band[@"type"] : @"peak";
        if ([p itemWithTitle:ty]) [p selectItemWithTitle:ty];
        return p;
    }
    // g / q：可编辑数字框
    NSString *ident = [key stringByAppendingString:@"Field"];
    NSTextField *tf = [tv makeViewWithIdentifier:ident owner:self];
    if (!tf) {
        tf = [[NSTextField alloc] initWithFrame:NSZeroRect];
        tf.identifier = ident;
        tf.font = t.mono;
        tf.bezeled = YES;
        tf.bezelStyle = NSTextFieldRoundedBezel;
        tf.target = self;
        tf.action = @selector(onBandField:);
    }
    tf.tag = row;
    tf.textColor = t.text;
    tf.backgroundColor = t.bg2;
    // 回填期间不要覆盖用户正在输入的内容
    if (!self.loading || [[tv window] firstResponder] != tf) {
        tf.stringValue = [NSString stringWithFormat:@"%.2f", [band[key] doubleValue]];
    }
    return tf;
}

#pragma mark - 编辑与节流提交

- (void)onBandField:(NSTextField *)sender {
    const NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)self.bands.count) return;
    // identifier 形如 "gField" / "qField"
    NSString *key = [sender.identifier substringToIndex:1];
    self.bands[row][key] = @(sender.doubleValue);
    [self scheduleApply];
}

- (void)onBandType:(NSPopUpButton *)sender {
    const NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)self.bands.count) return;
    self.bands[row][@"type"] = sender.titleOfSelectedItem ?: @"peak";
    [self scheduleApply];
}

- (void)onBypass:(id)sender { [self scheduleApply]; }
- (void)onPreampEnter:(id)sender { [self scheduleApply]; }

/// 260ms 节流：每敲一个字符就 POST 会把正在播的歌反复重启（web 版明确记过）。
- (void)scheduleApply {
    if (self.loading) return;
    [self.applyTimer invalidate];
    __weak __typeof__(self) weakSelf = self;
    self.applyTimer = [NSTimer scheduledTimerWithTimeInterval:0.26 repeats:NO block:^(NSTimer *tm) {
        (void)tm;
        [weakSelf applyNow];
    }];
}

- (NSString *)bandsParam {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSDictionary *b in self.bands) {
        [parts addObject:[NSString stringWithFormat:@"%.4f,%.4f,%.4f,%@",
                          [b[@"f"] doubleValue], [b[@"g"] doubleValue],
                          [b[@"q"] doubleValue],
                          [b[@"type"] isKindOfClass:[NSString class]] ? b[@"type"] : @"peak"]];
    }
    return [parts componentsJoinedByString:@";"];
}

- (void)applyNow {
    if (![RLPCoreClient shared].started || !self.bands.count) return;
    NSString *body = [NSString stringWithFormat:@"bypass=%d&preamp=%.3f&bands=%@",
                      (self.bypass.state == NSControlStateValueOn ? 1 : 0),
                      self.preamp.doubleValue, RLPEnc([self bandsParam])];
    self.status.stringValue = RLPTr(@"应用中…");
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/peq" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"未知错误");
            self_.status.stringValue = [RLPTr(@"失败：") stringByAppendingString:err];
            return;
        }
        // 关键：用**后端返回的状态**刷新（含新曲线），不用本地猜测值
        [self_ absorbState:json];
    }];
}

/// 把后端状态吸收进 UI。loading 期间禁止触发新的 POST，避免回填→提交→回填的死循环。
- (void)absorbState:(NSDictionary *)json {
    self.loading = YES;
    if ([json[@"bypass"] respondsToSelector:@selector(boolValue)])
        self.bypass.state = [json[@"bypass"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    if ([json[@"preamp"] respondsToSelector:@selector(doubleValue)])
        self.preamp.stringValue = [NSString stringWithFormat:@"%.2f", [json[@"preamp"] doubleValue]];

    NSArray *bs = [json[@"bands"] isKindOfClass:[NSArray class]] ? json[@"bands"] : nil;
    if (bs.count) {
        [self.bands removeAllObjects];
        for (id x in bs) {
            if (![x isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *m = [NSMutableDictionary dictionary];
            m[@"f"] = @([x[@"f"] respondsToSelector:@selector(doubleValue)] ? [x[@"f"] doubleValue] : 0);
            m[@"g"] = @([x[@"g"] respondsToSelector:@selector(doubleValue)] ? [x[@"g"] doubleValue] : 0);
            m[@"q"] = @([x[@"q"] respondsToSelector:@selector(doubleValue)] ? [x[@"q"] doubleValue] : 1);
            m[@"type"] = [x[@"type"] isKindOfClass:[NSString class]] ? x[@"type"] : @"peak";
            [self.bands addObject:m];
        }
        [self.bandTable reloadData];
    }

    NSArray *pts = [json[@"points"] isKindOfClass:[NSArray class]] ? json[@"points"] : nil;
    NSMutableArray<NSArray<NSNumber *> *> *clean = [NSMutableArray array];
    for (id p in pts) {
        if (![p isKindOfClass:[NSArray class]] || [(NSArray *)p count] < 2) continue;
        NSArray *a = (NSArray *)p;
        if (![a[0] respondsToSelector:@selector(doubleValue)] || ![a[1] respondsToSelector:@selector(doubleValue)]) continue;
        [clean addObject:@[ @([a[0] doubleValue]), @([a[1] doubleValue]) ]];
    }
    self.curve.points = clean;
    NSMutableArray<NSNumber *> *freqs = [NSMutableArray array];
    for (NSDictionary *b in self.bands) if (b[@"f"]) [freqs addObject:b[@"f"]];
    self.curve.bandFreqs = freqs;
    [self.curve setNeedsDisplay:YES];

    // 状态行：以事实为准（几段非 0、前级多少、采样率）
    NSInteger active = 0;
    for (NSDictionary *b in self.bands) if (fabs([b[@"g"] doubleValue]) >= 0.001) ++active;
    const BOOL byp = self.bypass.state == NSControlStateValueOn;
    NSString *fs = [json[@"fs"] respondsToSelector:@selector(doubleValue)]
        ? [NSString stringWithFormat:@"%.0f", [json[@"fs"] doubleValue]] : @"?";
    self.status.stringValue = [NSString stringWithFormat:@"%@ · %@ %ld/%ld · %@ %@ dB · %@ %@ Hz",
        byp ? RLPTr(@"已旁路") : RLPTr(@"生效"),
        RLPTr(@"非零段"), (long)active, (long)self.bands.count,
        RLPTr(@"前级"), self.preamp.stringValue, RLPTr(@"采样率"), fs];
    self.loading = NO;
}

#pragma mark - PEQ 预设

- (void)onPresetAction:(NSButton *)sender {
    NSString *action = sender.identifier;
    NSString *name = self.presetName.stringValue.length
        ? self.presetName.stringValue : (self.presetPop.titleOfSelectedItem ?: @"");
    if (![action isEqualToString:@"list"] && !name.length) {
        RLPToast(RLPTr(@"请先填写或选择预设名"));
        return;
    }
    NSString *body = [NSString stringWithFormat:@"action=%@&name=%@", RLPEnc(action), RLPEnc(name)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/peq/preset" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"未知错误");
            RLPToast([RLPTr(@"预设操作失败：") stringByAppendingString:err]);
            return;
        }
        [self_ absorbState:json];
        [self_ loadPresetList];
        if ([action isEqualToString:@"load"]) RLPToast(RLPTr(@"已加载预设"));
        else if ([action isEqualToString:@"save"]) RLPToast(RLPTr(@"已保存预设"));
        else if ([action isEqualToString:@"delete"]) RLPToast(RLPTr(@"已删除预设"));
    }];
}

- (void)loadPresetList {
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/peq/preset" body:@"action=list&name="
                          completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *items = [json[@"presets"] isKindOfClass:[NSArray class]] ? json[@"presets"]
                       : ([json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : nil);
        if (!items) return;
        [self_.presetPop removeAllItems];
        for (id x in items) {
            NSString *nm = [x isKindOfClass:[NSString class]] ? x
                         : ([x isKindOfClass:[NSDictionary class]] ? x[@"name"] : nil);
            if (nm.length) [self_.presetPop addItemWithTitle:nm];
        }
    }];
}

#pragma mark - OPRA（耳机目标曲线）

// web 的三条纪律，逐条照抄：
//   ① 索引**只拉一次且不带 q**（web loadOpraIndex：`api('/api/opra/index')`），
//      之后在本地按 `vendor name id` 全 token 子串过滤（web doSearch）；
//      空输入**不发起任何请求**（261023-03 #6）。
//   ② 预设列表返回的字段是 id/author/details/link/gainDb/bandsCount（**没有 name**），
//      显示名 = `author · details`（web preset-card 的 b 标签）。
//   ③ 选中/应用预设后展示目标曲线说明（web showTargetCurveInfo），并同步写回
//      settings 的 opraproduct/oprapreset/eq（web applyOpraPreset → saveSettings(true)）。

/// 把 /api/opra/index 的两种历史形态统一成 @{id,vendor,name}：
/// 现在后端返回的是 **[id, vendor, name] 数组三元组**（tools/rtaweb.cpp:11285），
/// 旧实现只认 NSDictionary ⟹ 搜索结果恒为空 —— 这是第8项①层断点的直接原因。
static NSDictionary *RLPOpraIndexItem(id x) {
    if ([x isKindOfClass:[NSArray class]]) {
        NSArray *a = (NSArray *)x;
        if (a.count < 3) return nil;
        NSMutableArray *vals = [NSMutableArray array];
        for (id v in a) [vals addObject:[v isKindOfClass:[NSString class]] ? v : @""];
        return @{ @"id": vals[0], @"vendor": vals[1], @"name": vals[2] };
    }
    if ([x isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)x;
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        m[@"id"] = [d[@"id"] isKindOfClass:[NSString class]] ? d[@"id"] : @"";
        m[@"vendor"] = [d[@"vendor"] isKindOfClass:[NSString class]] ? d[@"vendor"] : @"";
        m[@"name"] = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : @"";
        return [(NSString *)m[@"id"] length] ? m : nil;
    }
    return nil;
}

/// web doSearch 的过滤口径：query 按空白切 token，**每个 token** 都要出现在
/// `vendor name id`（小写）里；命中最多 30 条（web 的 `slice(0,30)`）。
static NSArray<NSDictionary *> *RLPOpraFilter(NSArray<NSDictionary *> *index, NSString *query) {
    NSString *q = [(query ?: @"") stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!q.length) return @[];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *t in [[q lowercaseString] componentsSeparatedByCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]])
        if (t.length) [tokens addObject:t];
    NSMutableArray<NSDictionary *> *hits = [NSMutableArray array];
    for (NSDictionary *it in index) {
        NSString *haystack = [[NSString stringWithFormat:@"%@ %@ %@",
                               it[@"vendor"] ?: @"", it[@"name"] ?: @"", it[@"id"] ?: @""] lowercaseString];
        BOOL match = YES;
        for (NSString *t in tokens) if ([haystack rangeOfString:t].location == NSNotFound) { match = NO; break; }
        if (!match) continue;
        [hits addObject:it];
        if (hits.count >= 30) break;
    }
    return hits;
}

- (void)resetTargetCurvePreview {
    self.curve.targetCurve = nil;
    self.opraInfo.stringValue = @"";
    [self.curve setNeedsDisplay:YES];
}

/// web showTargetCurveInfo(p)：曲线名称 + 「是什么 / 适合谁」+ 前级增益/段数/预设名。
- (void)previewTargetCurveForPreset:(NSDictionary *)p {
    if (!p) { [self resetTargetCurvePreview]; return; }
    NSString *details = [p[@"details"] isKindOfClass:[NSString class]] ? p[@"details"] : @"";
    NSString *author = [p[@"author"] isKindOfClass:[NSString class]] ? p[@"author"] : @"";
    RLPTargetCurve *curve = [RLPTargetCurveLibrary curveForKind:
                             [RLPTargetCurveLibrary kindForDetails:details]];
    self.curve.targetCurve = curve;
    NSString *name = [RLPTargetCurveLibrary targetCurveNameForDetails:details author:author];
    NSString *scene = [RLPTargetCurveLibrary targetCurveSceneForDetails:details author:author];
    NSString *tech = [RLPTargetCurveLibrary targetCurveTechForDetails:details author:author];
    const double gain = [p[@"gainDb"] respondsToSelector:@selector(doubleValue)] ? [p[@"gainDb"] doubleValue] : 0.0;
    const NSInteger bands = [p[@"bandsCount"] respondsToSelector:@selector(integerValue)] ? [p[@"bandsCount"] integerValue] : 0;
    self.opraInfo.stringValue = [NSString stringWithFormat:
        @"%@\n%@%@\n%@%@\n%@%.1f dB · %@%ld %@ · %@%@",
        [NSString stringWithFormat:RLPTr(@"目标曲线：%@"), name],
        RLPTr(@"是什么："), tech,
        RLPTr(@"适合谁："), scene,
        RLPTr(@"前级增益："), gain, RLPTr(@"滤波段数："), (long)bands, RLPTr(@"段"),
        RLPTr(@"预设："), details.length ? details : (p[@"id"] ?: @"")];
    self.opraInfo.textColor = [RLPTheme current].mut;
    [self.curve setNeedsDisplay:YES];
}

- (void)onOpraSearch:(id)sender {
    NSString *qq = [self.opraQuery.stringValue stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // 空关键词不发请求（web 261023-03 第6条：避免一进页面就拉整个索引）
    if (!qq.length) { self.opraStatus.stringValue = RLPTr(@"请输入耳机型号"); return; }
    if (![RLPCoreClient shared].started) return;
    [self resetTargetCurvePreview];
    self.opraItems = @[];
    self.opraSelectedProductIndex = -1;
    self.opraSelectedPresetIndex = -1;
    self.opraPresets = @[];
    [self renderModelCards];
    [self renderPresetCards];
    self.opraGuide.hidden = YES;
    self.opraSelectedTitle.hidden = YES;
    if (self.opraIndexCache) { [self applyOpraQuery:qq]; return; }
    self.opraStatus.stringValue = RLPTr(@"正在加载耳机数据库…");
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/opra/index" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *raw = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[];
        NSMutableArray<NSDictionary *> *idx = [NSMutableArray array];
        for (id x in raw) { NSDictionary *it = RLPOpraIndexItem(x); if (it) [idx addObject:it]; }
        self_.opraIndexCache = idx;
        [self_ applyOpraQuery:qq];
    }];
}

- (void)applyOpraQuery:(NSString *)qq {
    NSArray<NSDictionary *> *hits = RLPOpraFilter(self.opraIndexCache ?: @[], qq);
    self.opraItems = hits;
    self.opraSelectedProductIndex = -1;
    self.opraSelectedPresetIndex = -1;
    self.opraPresets = @[];
    [self renderModelCards];
    [self renderPresetCards];
    self.opraSelectedTitle.hidden = YES;
    // web：有结果才显示型号卡片区；空结果给"未找到"并在下方给出可操作提示。
    self.opraGuide.hidden = hits.count ? NO : YES;
    self.opraStatus.stringValue = hits.count
        ? [NSString stringWithFormat:RLPTr(@"%ld 个结果"), (long)hits.count]
        : RLPTr(@"未找到匹配的耳机型号，请尝试不同关键词");
}

- (void)loadProductPresets:(NSInteger)productIndex {
    if (productIndex < 0 || productIndex >= (NSInteger)self.opraItems.count) return;
    NSDictionary *prod = self.opraItems[(NSUInteger)productIndex];
    NSString *pid = [prod[@"id"] isKindOfClass:[NSString class]] ? prod[@"id"] : @"";
    if (!pid.length) return;
    NSString *vendor = [prod[@"vendor"] isKindOfClass:[NSString class]] ? prod[@"vendor"] : @"";
    NSString *name = [prod[@"name"] isKindOfClass:[NSString class]] ? prod[@"name"] : @"";
    self.opraSelectedTitle.hidden = NO;
    self.opraSelectedTitle.stringValue = [NSString stringWithFormat:@"%@ %@ · %@",
        vendor, name, RLPTr(@"调音预设")];
    self.opraPresetCards.hidden = NO;
    self.opraPresets = @[];
    [self renderPresetCards];
    self.opraStatus.stringValue = RLPTr(@"正在获取预设…");
    const NSInteger seq = ++self.opraProductSeq;   // 只认最后一次选择（web OPRA_CUR_PRODUCT）
    [self resetTargetCurvePreview];
    NSString *url = [NSString stringWithFormat:@"/api/opra/presets?productId=%@", RLPEnc(pid)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.opraProductSeq) return;
        NSArray *items = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[];
        NSMutableArray<NSDictionary *> *good = [NSMutableArray array];
        for (id x in items) if ([x isKindOfClass:[NSDictionary class]]) [good addObject:x];
        self_.opraPresets = good;
        // 当前态：优先命中 settings 写回的 oprapreset，否则预览第一条。
        NSInteger selected = 0;
        for (NSUInteger i = 0; i < good.count; ++i) {
            NSString *eid = good[i][@"id"];
            if ([eid isKindOfClass:[NSString class]] && [eid isEqualToString:self_.appliedPresetId]) {
                selected = (NSInteger)i;
                break;
            }
        }
        self_.opraSelectedPresetIndex = good.count ? selected : -1;
        [self_ renderPresetCards];
        if (!good.count) {
            self_.opraStatus.stringValue = RLPTr(@"这款耳机没有可用曲线");
            return;
        }
        self_.opraStatus.stringValue = [NSString stringWithFormat:RLPTr(@"%ld 种调音目标"), (long)good.count];
        [self_ previewTargetCurveForPreset:good[(NSUInteger)selected]];
    }];
}

- (void)applyOpraPreset:(NSString *)pid presetId:(NSString *)eid {
    if (!pid.length || !eid.length) {
        RLPToast(RLPTr(@"请先选择耳机与曲线"));
        return;
    }
    // 与 web applyOpraPreset 的请求体逐字段一致：productId=…&presetId=…（两者都做 encodeURIComponent）。
    NSString *body = [NSString stringWithFormat:@"productId=%@&presetId=%@", RLPEnc(pid), RLPEnc(eid)];
    self.opraStatus.stringValue = RLPTr(@"应用中…");
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/opra/apply" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"未知错误");
            self_.opraStatus.stringValue = [RLPTr(@"失败：") stringByAppendingString:err];
            return;
        }
        // 当前态立刻落 UI（要等 reload 回来才显示会闪一下）
        self_.appliedProductId = pid;
        self_.appliedPresetId = eid;
        [self_ renderModelCards];
        [self_ renderPresetCards];
        self_.opraStatus.stringValue = RLPTr(@"已应用耳机曲线");
        RLPToast(RLPTr(@"已应用耳机曲线"));
        // web applyOpraPreset：成功路径是 `j.path`（eqPath 仅兼容），随后 **saveSettings(true)**
        // 把 eq / opraproduct / oprapreset 一起落盘。后端热重载靠这份写回触发。
        NSString *appliedPath = [json[@"path"] isKindOfClass:[NSString class]] ? json[@"path"]
                               : ([json[@"eqPath"] isKindOfClass:[NSString class]] ? json[@"eqPath"] : nil);
        if (appliedPath.length) {
            NSString *settings = [NSString stringWithFormat:@"eq=%@&opraproduct=%@&oprapreset=%@",
                                  RLPEnc(appliedPath), RLPEnc(pid), RLPEnc(eid)];
            [[RLPCoreClient shared] postJSON:@"/api/settings" body:settings completion:nil];
        }
        // EQ 已被换成耳机曲线 ⟹ 必须重新拉 /api/peq 才能看到真实新状态
        [self_ reload];
        NSDictionary *cur = nil;
        for (NSDictionary *x in self_.opraPresets) {
            if ([x[@"id"] isKindOfClass:[NSString class]] && [x[@"id"] isEqualToString:eid]) { cur = x; break; }
        }
        if (cur) [self_ previewTargetCurveForPreset:cur];
    }];
}

#pragma mark - 数据与主题

- (void)reload {
    if (![RLPCoreClient shared].started) {
        self.status.stringValue = RLPTr(@"核心未启动");
        return;
    }
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/peq" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            self_.status.stringValue = RLPTr(@"读取失败");
            return;
        }
        [self_ absorbState:json];
    }];
    [self loadPresetList];
    // 当前态：settings 的 opraproduct/oprapreset 是 web 的唯一真相源（预设卡的"已应用当前预设"靠它）。
    [[RLPCoreClient shared] getJSON:@"/api/settings" completion:^(NSDictionary * _Nullable j) {
        __typeof__(self) s = weakSelf;
        if (!s) return;
        NSDictionary *kv = [j[@"kv"] isKindOfClass:[NSDictionary class]] ? j[@"kv"] : nil;
        if (kv) {
            if ([kv[@"opraproduct"] isKindOfClass:[NSString class]]) s.appliedProductId = kv[@"opraproduct"];
            if ([kv[@"oprapreset"] isKindOfClass:[NSString class]]) s.appliedPresetId = kv[@"oprapreset"];
        }
        [s renderModelCards];
        [s renderPresetCards];
    }];
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.bandTable.backgroundColor = t.bg;
    self.status.textColor = t.mut;
    self.opraStatus.textColor = t.mut;
    self.opraInfo.textColor = t.mut;
    [self.bandTable reloadData];
    [self.curve setNeedsDisplay:YES];
}


#pragma mark - 嵌入设置页（去掉本视图自己的滚动，交给整页滚动）

- (void)setEmbeddedInPage:(BOOL)embedded {
    if (_embeddedInPage == embedded) return;
    _embeddedInPage = embedded;
    if (!embedded || !self.scroll) return;
    // 拆掉内层 NSScrollView：stack 直接铺在外层页面上，外层页面负责滚动。
    [NSLayoutConstraint deactivateConstraints:self.scrollConstraints];
    [self.scroll removeFromSuperview];
    self.scroll = nil;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:self.stack];
    [NSLayoutConstraint activateConstraints:@[
        [self.stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:self.topAnchor],
    ]];
    // 高度约束由宿主（设置页 fillEqualizer）持有，避免两边各加一条 required 约束互相冲突。
}

- (CGFloat)preferredContentHeight {
    CGFloat total = self.stack.edgeInsets.top + self.stack.edgeInsets.bottom;
    NSInteger n = 0;
    for (NSView *v in self.stack.arrangedSubviews) {
        if (v.hidden) continue;
        // NSScrollView / 自绘视图在布局前 fittingSize 是 0 —— 先看显式高度约束。
        CGFloat h = 0;
        for (NSLayoutConstraint *c in v.constraints) {
            if (c.firstAttribute == NSLayoutAttributeHeight && c.secondItem == nil
                && c.relation == NSLayoutRelationEqual) { h = c.constant; break; }
        }
        if (h <= 0) h = v.fittingSize.height;
        total += h;
        ++n;
    }
    if (n > 1) total += self.stack.spacing * (n - 1);
    return ceil(total);
}

@end
