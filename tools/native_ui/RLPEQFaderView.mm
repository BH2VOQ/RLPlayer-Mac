// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPEQFaderView.h"
#import "RLPEQGeometry.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

/// 顶部"数值输入行"高度；底部"频率标签行"高度；左侧 dB 刻度宽。
static const CGFloat kValueRowH = 28.0;
static const CGFloat kFreqRowH = 20.0;
static const CGFloat kScaleW = 38.0;
/// 推子轨道宽（用户截图里是很粗的竖条）。
static const CGFloat kTrackW = 7.0;
/// 把手半径（白色实心圆 + 描边）。
static const CGFloat kKnobR = 9.0;

@implementation RLPEQFaderView {
    NSMutableArray<NSTextField *> *_fields;
    NSInteger _dragBand;      // 正在拖的段（-1 = 无）
    double _dragStartDb;
    CGFloat _dragStartY;
    NSInteger _drawCount;
    CGFloat _lastKnobY0;
}
@synthesize drawCount = _drawCount;
@synthesize lastDrawnKnobYForBand0 = _lastKnobY0;

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    self.bandFreqs = @[];
    self.bandGains = @[];
    self.activeBand = -1;
    _dragBand = -1;
    _fields = [NSMutableArray array];
    self.wantsLayer = YES;
    return self;
}

- (BOOL)isFlipped { return NO; }

#pragma mark - 几何

- (NSRect)plotRect {
    NSRect b = self.bounds;
    return NSMakeRect(b.origin.x + kScaleW, b.origin.y + kFreqRowH,
                      MAX(0, b.size.width - kScaleW - 6),
                      MAX(0, b.size.height - kValueRowH - kFreqRowH));
}

- (NSUInteger)bandCount { return self.bandFreqs.count; }

- (CGFloat)xForBand:(NSUInteger)i {
    NSRect plot = [self plotRect];
    const NSUInteger n = [self bandCount];
    if (!n) return NSMidX(plot);
    // 等宽槽位（硬件 EQ 的画法）：x 由段号决定，不由频率决定。
    return plot.origin.x + ((CGFloat)i + 0.5) * (plot.size.width / (CGFloat)n);
}

- (CGFloat)yForDb:(double)db {
    NSRect plot = [self plotRect];
    const double c = MAX(-RLPEQDbRange, MIN(RLPEQDbRange, db));
    return plot.origin.y + (CGFloat)((c + RLPEQDbRange) / (2.0 * RLPEQDbRange)) * plot.size.height;
}

- (NSRect)trackRectForBand:(NSUInteger)i {
    NSRect plot = [self plotRect];
    const CGFloat x = [self xForBand:i];
    return NSMakeRect(x - kTrackW / 2, plot.origin.y + kKnobR,
                      kTrackW, MAX(1, plot.size.height - kKnobR * 2));
}

- (NSTextField *)valueFieldForBand:(NSUInteger)i {
    return (i < _fields.count) ? _fields[i] : nil;
}

#pragma mark - 频率文本

/// 20 段 ISO 频点的显示文本。规则与用户截图一致：
/// <1000 用整数（20 / 125 / 500）；>=1000 用 k（1K / 2K / 16K / 20K），
/// 非整 k 的保留一位小数（1.25K / 3.15K / 6.3K / 12.5K）。
- (NSString *)freqLabelForBand:(NSUInteger)i {
    if (i >= self.bandFreqs.count) return @"";
    const double f = self.bandFreqs[i].doubleValue;
    if (f < 999.5) return [NSString stringWithFormat:@"%.0f", f];
    const double k = f / 1000.0;
    if (fabs(k - round(k)) < 0.05) return [NSString stringWithFormat:@"%.0fK", round(k)];
    if (fabs(k * 10 - round(k * 10)) < 0.05) return [NSString stringWithFormat:@"%.1fK", k];
    return [NSString stringWithFormat:@"%.2fK", k];
}

#pragma mark - 数值输入框（用户要求"上面可以输入 ±db 详细数据"）

- (void)rebuildValueFieldsIfNeeded {
    // 段数 = max(bandFreqs, bandGains)：两个 setter 到达顺序不保证，
    // 若只看 bandFreqs，先设 gains 时会建出 0 个框，之后 count 相等就短路返回，
    // 结果界面上永远是空框（实测踩到：20 个框全空白）。
    const NSUInteger n = MAX(self.bandFreqs.count, self.bandGains.count);
    if (_fields.count == n && n > 0) {
        // ⚠️ 这条短路必须同时**刷新数值**。第一版只 layout 不 sync，
        // 于是"先设 bandFreqs（建 20 个空框）→ 再设 bandGains（短路，只重排）"，
        // 结果是 20 个框永远空着（实测踩到）。
        [self layoutValueFields];
        [self syncFieldValues];
        return;
    }
    if (n == 0) return;
    for (NSTextField *f in _fields) [f removeFromSuperview];
    [_fields removeAllObjects];
    for (NSUInteger i = 0; i < n; ++i) {
        NSTextField *f = [[NSTextField alloc] initWithFrame:NSZeroRect];
        f.identifier = [NSString stringWithFormat:@"eq.fader.value.%lu", (unsigned long)i];
        f.alignment = NSTextAlignmentCenter;
        f.font = [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular];
        f.textColor = [RLPTheme current].text;
        f.bezeled = YES;
        f.bezelStyle = NSTextFieldSquareBezel;
        f.drawsBackground = YES;
        f.focusRingType = NSFocusRingTypeExterior;
        f.tag = (NSInteger)i;
        f.target = self;
        f.action = @selector(onValueFieldCommitted:);   // 回车/失焦才提交，不是每个击键
        f.toolTip = RLPTr(@"直接输入该段的增益，范围 ±24 dB");
        [self addSubview:f];
        [_fields addObject:f];
    }
    [self layoutValueFields];
    [self syncFieldValues];
}

- (void)layoutValueFields {
    const NSUInteger n = _fields.count;
    if (!n) return;
    NSRect b = self.bounds;
    // 槽距 = plot 宽 / 段数（20 段 ≈ 47.8pt）；框宽必须**小于**槽距，
    // 否则相邻框会贴在一起（第一版写死 48 就贴上了）。
    const CGFloat slot = n ? (NSWidth([self plotRect]) / (CGFloat)n) : 48.0;
    const CGFloat w = MIN(44.0, MAX(30.0, slot - 4.0));
    // ⚠️ 高度必须 ≥ 22：带 bezel 的 NSTextField 内部要吃掉约 8pt 边框，
    // 第一版给 18pt（净高 10pt）配 10.5pt 字号 ⟹ 文字整个被裁掉，
    // 渲染出来的框全是空的（截图实测）。字号也降到 10 以放进 44pt 宽。
    const CGFloat fh = 22.0;
    const CGFloat y = NSMaxY(b) - fh - 4.0;
    for (NSUInteger i = 0; i < n; ++i) {
        NSTextField *f = _fields[i];
        const CGFloat x = [self xForBand:i];
        f.frame = NSMakeRect(x - w / 2, y, w, fh);
    }
}

- (void)layout {
    [super layout];
    [self layoutValueFields];
}

- (void)setBandFreqs:(NSArray<NSNumber *> *)bandFreqs {
    _bandFreqs = [bandFreqs copy] ?: @[];
    [self rebuildValueFieldsIfNeeded];
    [self setNeedsDisplay:YES];
}

- (void)setBandGains:(NSArray<NSNumber *> *)bandGains {
    _bandGains = [bandGains copy] ?: @[];
    // ⚠️ 必须先确保输入框已建好：宿主（RLPEqualizerView）的设置顺序是
    // bandFreqs → bandGains，但首次可能先设 gains。若此处 _fields 还是空的，
    // syncFieldValues 一个框都不会填 ⟹ 界面上 20 个框全是空白（实测踩到）。
    [self rebuildValueFieldsIfNeeded];
    [self syncFieldValues];
    [self setNeedsDisplay:YES];
}

/// 把 bandGains 写进 20 个输入框（正在编辑的那个不覆盖，否则用户打字打一半被抹掉）。
- (void)syncFieldValues {
    // 注意 [[self window] firstResponder]：没有 window（离屏视图 / 判据里 new 出来的）时
    // 两个比较都是 nil == nil ⟹ 所有框都会 continue，一个都不填。
    // 所以先判 window 存在，再判"是不是正在编辑"。
    NSWindow *win = [self window];
    id fr = win.firstResponder;
    for (NSUInteger i = 0; i < _fields.count; ++i) {
        NSTextField *f = _fields[i];
        if (win && fr && (fr == f || fr == [f currentEditor])) continue;
        const double g = (i < self.bandGains.count) ? self.bandGains[i].doubleValue : 0.0;
        f.stringValue = [NSString stringWithFormat:@"%.1f", g];
    }
}

- (void)onValueFieldCommitted:(NSTextField *)f {
    const NSInteger i = f.tag;
    if (i < 0 || !self.onBandGainEdited) return;
    double v = f.doubleValue;
    if (!isfinite(v)) {
        // 用户输入了无法解析的内容：退回当前值，不假装接受
        v = (i < (NSInteger)self.bandGains.count) ? self.bandGains[(NSUInteger)i].doubleValue : 0.0;
    }
    v = MAX(-RLPEQDbRange, MIN(RLPEQDbRange, v));
    f.stringValue = [NSString stringWithFormat:@"%.1f", v];
    self.onBandGainEdited(i, v);
}

#pragma mark - 拖推子（位移累加，同曲线视图的口径）

- (void)applyDragEvent:(NSEvent *)event {
    if (!self.onBandGainEdited) return;
    const NSUInteger n = [self bandCount];
    if (!n) return;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSRect plot = [self plotRect];
    if (plot.size.width <= 1 || plot.size.height <= 1) return;

    if (_dragBand < 0) {
        if (p.y < plot.origin.y || p.y > NSMaxY(plot)) return;
        // 命中：最近的槽位（等宽，所以直接按 x 分槽）
        const CGFloat rel = (p.x - plot.origin.x) / plot.size.width;
        if (rel < 0 || rel > 1) return;
        NSInteger idx = (NSInteger)floor(rel * (CGFloat)n);
        idx = MAX(0, MIN((NSInteger)n - 1, idx));
        _dragBand = idx;
        _dragStartDb = (idx < (NSInteger)self.bandGains.count)
            ? self.bandGains[(NSUInteger)idx].doubleValue : 0.0;
        _dragStartY = p.y;
        self.activeBand = idx;
    }
    const CGFloat pxPerDb = plot.size.height / (2.0 * RLPEQDbRange);
    double db = _dragStartDb + (double)((p.y - _dragStartY) / pxPerDb);
    db = MAX(-RLPEQDbRange, MIN(RLPEQDbRange, db));
    // 四舍五入到 0.1 dB：与输入框显示精度一致，避免"框里 3.2、实际 3.1874"
    db = round(db * 10.0) / 10.0;
    self.activeBand = _dragBand;
    self.onBandGainEdited(_dragBand, db);
}

- (void)mouseDown:(NSEvent *)event {
    _dragBand = -1;
    [self applyDragEvent:event];
}
- (void)mouseDragged:(NSEvent *)event { [self applyDragEvent:event]; }
- (void)mouseUp:(NSEvent *)event { (void)event; _dragBand = -1; }

#pragma mark - 绘制

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    _drawCount += 1;
    RLPTheme *t = [RLPTheme current];
    NSRect b = self.bounds;
    [t.bg2 setFill];
    NSRectFill(b);

    [self rebuildValueFieldsIfNeeded];
    NSRect plot = [self plotRect];
    if (plot.size.width <= 4 || plot.size.height <= 4) return;

    NSDictionary *small = @{ NSFontAttributeName: t.small,
                             NSForegroundColorAttributeName: t.mut };
    NSDictionary *tiny = @{ NSFontAttributeName:
                                [NSFont monospacedDigitSystemFontOfSize:9.5 weight:NSFontWeightRegular],
                            NSForegroundColorAttributeName: t.mut };

    // ---- 水平网格 + 左侧 dB 刻度 ----
    // 每 6 dB 一条；标尺只在 ±24 / ±12 / 0 处写数字，与用户截图一致（不堆满数字）。
    [t.line setStroke];
    for (double db = -RLPEQDbRange; db <= RLPEQDbRange + 1e-9; db += 6.0) {
        const CGFloat y = [self yForDb:db];
        if (fabs(db) > 0.001) {
            NSBezierPath *g = [NSBezierPath bezierPath];
            [g moveToPoint:NSMakePoint(plot.origin.x, y)];
            [g lineToPoint:NSMakePoint(NSMaxX(plot), y)];
            g.lineWidth = 0.5;
            [[t.line colorWithAlphaComponent:0.55] setStroke];
            [g stroke];
        }
        if (fabs(fabs(db) - RLPEQDbRange) < 0.001 || fabs(fabs(db) - 12.0) < 0.001
            || fabs(db) < 0.001) {
            NSString *lab = (fabs(db) < 0.001) ? @"0 dB"
                : [NSString stringWithFormat:@"%+.0f dB", db];
            NSSize sz = [lab sizeWithAttributes:tiny];
            [lab drawAtPoint:NSMakePoint(plot.origin.x - sz.width - 4, y - sz.height / 2)
              withAttributes:tiny];
        }
    }
    // 0 dB 基准线略重
    {
        NSBezierPath *zero = [NSBezierPath bezierPath];
        [zero moveToPoint:NSMakePoint(plot.origin.x, [self yForDb:0])];
        [zero lineToPoint:NSMakePoint(NSMaxX(plot), [self yForDb:0])];
        zero.lineWidth = 1.0;
        [[t.mut colorWithAlphaComponent:0.7] setStroke];
        [zero stroke];
    }

    // ---- 每段：竖直粗轨道 + 白色圆把手 + 下方频率标签 ----
    const NSUInteger n = [self bandCount];
    for (NSUInteger i = 0; i < n; ++i) {
        const BOOL active = (i == (NSUInteger)self.activeBand);
        const double db = (i < self.bandGains.count) ? self.bandGains[i].doubleValue : 0.0;

        // 轨道：底槽用淡灰画满全程；红色只填充 0 dB 到当前值那一段。
        // 用户 2026-11-15 明确：推子的红颜色要跟着柱子高度走，往上推就高，往下推就低。
        // 所以红色不是选中态的整根高亮，而是增益量本身的可视化：
        // 正值从 0 dB 往上长，负值从 0 dB 往下长，0 dB 时红色长度为 0。
        NSRect track = [self trackRectForBand:i];
        NSBezierPath *slot = [NSBezierPath bezierPathWithRoundedRect:track
                                                            xRadius:kTrackW / 2 yRadius:kTrackW / 2];
        [[t.mut colorWithAlphaComponent:0.30] setFill];
        [slot fill];

        const CGFloat y0 = [self yForDb:0.0];
        const CGFloat yNow = [self yForDb:db];
        if (fabs(yNow - y0) > 0.5) {
            const CGFloat top = MAX(y0, yNow), bot = MIN(y0, yNow);
            NSRect fillRect = NSMakeRect(NSMinX(track), bot, NSWidth(track), top - bot);
            NSBezierPath *fl = [NSBezierPath bezierPathWithRoundedRect:fillRect
                                                              xRadius:kTrackW / 2 yRadius:kTrackW / 2];
            // 正在调的那段用满强度 accent，其余用同一套红稍淡：
            // 哪根在动仍一眼看出，同时红色长度始终等于增益量。
            [(active ? t.accent : [t.accent colorWithAlphaComponent:0.70]) setFill];
            [fl fill];
        }

        // 把手：白色实心圆 + 深色细描边（截图形态）
        const CGFloat hy = [self yForDb:db];
        const CGFloat hx = [self xForBand:i];
        NSRect knob = NSMakeRect(hx - kKnobR, hy - kKnobR, kKnobR * 2, kKnobR * 2);
        NSBezierPath *kp = [NSBezierPath bezierPathWithOvalInRect:knob];
        [[NSColor whiteColor] setFill];
        [kp fill];
        [(active ? t.accent : [t.mut colorWithAlphaComponent:0.9]) setStroke];
        kp.lineWidth = (active ? 2.0 : 1.2);
        [kp stroke];
        if (i == 0) _lastKnobY0 = hy;

        // 下方频率
        NSString *fl = [self freqLabelForBand:i];
        NSSize fsz = [fl sizeWithAttributes:small];
        [fl drawAtPoint:NSMakePoint(hx - fsz.width / 2, 3) withAttributes:small];
    }
}

@end
