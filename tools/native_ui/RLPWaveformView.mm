// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// RLPWaveformView.mm — 自绘波形（对称包络 / 已播未播双色 / 播放头 / 选区）。
//
// 纪律：
//   * 不取数：peaks/rms/duration 只由上层 setPeaks:rms:duration: 写入；
//   * 播放头只由 /api/status 轮询写（本视图不做任何请求、不启定时器）；
//   * 颜色只用 RLPTheme 的 web 令牌（--acc / --acc-weak / --line），不自造色；
//   * 坐标是 top-left（isFlipped=YES），与 #npPage 的画布同一套。
#import "RLPWaveformView.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

static const CGFloat kBaselineInset = 2.0;   // 包络上下各留 2pt（不贴边）
static const CGFloat kMinColumnWidth = 1.0;  // bins 多于像素时也不退化成 0 宽
static const CGFloat kDragThreshold = 4.0;   // 4pt 以内算点击，手抖不算拖选
static const double kMinSelectionSeconds = 0.5;

@implementation RLPWaveformView {
    double _selectionStart;   // 0..1，已排序
    double _selectionEnd;
    BOOL _selecting;
    BOOL _pressActive;
    BOOL _dragging;
    double _dragAnchor;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    self.wantsLayer = YES;
    self.toolTip = RLPTr(@"波形");
    [self setAccessibilityLabel:RLPTr(@"波形")];
    // 主题切换（设置页/跟随系统）要重绘；视图不持有主题快照，每次绘制再取当前值。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(themeDidChange:)
                                                 name:RLPThemeDidChangeNotification
                                               object:nil];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)themeDidChange:(NSNotification *)note {
    (void)note;
    [self setNeedsDisplay:YES];
}

/// top-left 坐标系（与 #npPage 画布一致）：frame 由上层按网页同构几何给出。
- (BOOL)isFlipped { return YES; }

- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }

#pragma mark - 数据

- (void)setPeaks:(NSArray<NSNumber *> *)peaks
              rms:(NSArray<NSNumber *> *)rms
         duration:(double)duration {
    _peaks = [peaks copy];
    _rms = [rms copy];
    _duration = (isfinite(duration) && duration > 0.0) ? duration : 0.0;
    [self clearSelection];     // 新曲不许带着上一首的选区
    [self setNeedsDisplay:YES];
}

- (void)clearWaveform {
    _peaks = nil;
    _rms = nil;
    _duration = 0.0;
    _selectionStart = _selectionEnd = 0.0;
    _selecting = NO;
    if (_playheadFraction != 0.0) _playheadFraction = 0.0;
    [self setNeedsDisplay:YES];
}

- (void)setPlayheadFraction:(double)fraction {
    if (!isfinite(fraction)) fraction = 0.0;
    fraction = fmin(1.0, fmax(0.0, fraction));
    if (fabs(_playheadFraction - fraction) < 1e-6) return;
    _playheadFraction = fraction;
    [self setNeedsDisplay:YES];   // 只重绘；不重算波形、不发请求
}

#pragma mark - 几何 / 取色（绘制与判据共用同一批函数）

/// 归一化用的分母：数组里最大的峰值。全零/空数组时给 1，避免除零。
- (double)maxPeakValue {
    double maxValue = 0.0;
    for (NSNumber *n in _peaks) {
        const double v = n.doubleValue;
        if (isfinite(v) && v > maxValue) maxValue = v;
    }
    return maxValue > 0.0 ? maxValue : 1.0;
}

- (CGFloat)xForFraction:(double)fraction {
    const CGFloat width = NSWidth(self.bounds);
    if (width <= 0.0) return 0.0;
    if (!isfinite(fraction)) fraction = 0.0;
    return (CGFloat)fmin(1.0, fmax(0.0, fraction)) * width;
}

- (NSRect)envelopeRectForBin:(NSInteger)bin {
    const NSInteger n = (NSInteger)_peaks.count;
    if (n <= 0 || bin < 0 || bin >= n || NSWidth(self.bounds) <= 0.0) return NSZeroRect;
    const CGFloat center = NSMidY(self.bounds);
    const CGFloat half = MAX(0.0, center - kBaselineInset);
    double value = _peaks[(NSUInteger)bin].doubleValue / [self maxPeakValue];
    if (!isfinite(value) || value < 0.0) value = 0.0;
    value = fmin(1.0, value);
    const CGFloat h = 2.0 * half * (CGFloat)value;
    const CGFloat x0 = NSWidth(self.bounds) * (CGFloat)bin / (CGFloat)n;
    const CGFloat x1 = NSWidth(self.bounds) * (CGFloat)(bin + 1) / (CGFloat)n;
    return NSMakeRect(x0, center - h / 2.0, MAX(kMinColumnWidth, x1 - x0), h);
}

- (NSColor *)envelopeColorForBin:(NSInteger)bin {
    RLPTheme *t = [RLPTheme current];
    if (_peaks.count == 0) return t.accentWeak;
    const double center = ((double)bin + 0.5) / (double)_peaks.count;
    return center < _playheadFraction ? t.accent : t.accentWeak;
}

#pragma mark - 绘制

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    RLPTheme *t = [RLPTheme current];
    const NSRect bounds = self.bounds;
    if (NSWidth(bounds) <= 0.0 || NSHeight(bounds) <= 0.0) return;

    // 中心基线：与 web 进度轨同一令牌（--line）。
    [t.line setFill];
    NSRectFill(NSMakeRect(0.0, floor(NSMidY(bounds)) - 0.5, NSWidth(bounds), 1.0));

    // 选区：先画半透明底，再画两端竖线（压在包络**下面**，不挡住波形）。
    if (_selecting) {
        CGFloat xa = [self xForFraction:_selectionStart];
        CGFloat xb = [self xForFraction:_selectionEnd];
        if (xa > xb) { const CGFloat tmp = xa; xa = xb; xb = tmp; }
        [[t.accent colorWithAlphaComponent:0.16] setFill];
        NSRectFillUsingOperation(NSMakeRect(xa, 0.0, xb - xa, NSHeight(bounds)),
                                NSCompositingOperationSourceOver);
        [t.accent setFill];
        NSRectFill(NSMakeRect(xa, 0.0, 1.0, NSHeight(bounds)));
        NSRectFill(NSMakeRect(MAX(0.0, xb - 1.0), 0.0, 1.0, NSHeight(bounds)));
    }

    // 对称包络：每根柱子就是一个 bin，上下等距、按最大峰值归一化。
    const NSInteger n = (NSInteger)_peaks.count;
    for (NSInteger i = 0; i < n; ++i) {
        const NSRect r = [self envelopeRectForBin:i];
        if (NSHeight(r) <= 0.0 || NSWidth(r) <= 0.0) continue;
        [[self envelopeColorForBin:i] setFill];
        NSRectFillUsingOperation(r, NSCompositingOperationSourceOver);
    }

    // 播放头：整高竖线，画在最上层（无波形时不画，避免看起来像"卡住"）。
    if (n > 0) {
        const CGFloat px = [self xForFraction:_playheadFraction];
        [t.text setFill];
        NSRectFill(NSMakeRect(MIN(NSWidth(bounds) - 1.5, MAX(0.0, px - 0.75)), 0.0,
                              1.5, NSHeight(bounds)));
    }
}

#pragma mark - 鼠标（点击 seek / 横向拖选）

- (double)fractionForEvent:(NSEvent *)event {
    const NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    const CGFloat width = NSWidth(self.bounds);
    if (width <= 0.0) return 0.0;
    double fraction = (double)point.x / (double)width;
    if (!isfinite(fraction)) fraction = 0.0;
    return fmin(1.0, fmax(0.0, fraction));
}

- (void)mouseDown:(NSEvent *)event {
    _pressActive = YES;
    _dragging = NO;
    _dragAnchor = [self fractionForEvent:event];
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_pressActive) return;
    const double fraction = [self fractionForEvent:event];
    const CGFloat dx = (CGFloat)fabs(fraction - _dragAnchor) * NSWidth(self.bounds);
    if (!_dragging && dx < kDragThreshold) return;   // 手抖仍按"点击"处理
    _dragging = YES;
    _selecting = YES;
    _selectionStart = MIN(_dragAnchor, fraction);
    _selectionEnd = MAX(_dragAnchor, fraction);
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event {
    if (!_pressActive) return;
    _pressActive = NO;
    if (!_dragging) {
        // 单击 = 跳转（与 web 进度条点击同语义）。选区先清掉，避免旧高亮留在新位置旁。
        [self clearSelection];
        if (self.onSeek) self.onSeek([self fractionForEvent:event]);
        return;
    }
    _dragging = NO;
    const double seconds = fabs(_selectionEnd - _selectionStart) * _duration;
    if (_duration <= 0.0 || seconds < kMinSelectionSeconds) {
        [self clearSelection];   // <0.5 s 的碎片不留（用户没法取消它）
        return;
    }
    if (self.onSelect) self.onSelect(_selectionStart, _selectionEnd, seconds);
    [self setNeedsDisplay:YES];
}

- (void)clearSelection {
    _selectionStart = 0.0;
    _selectionEnd = 0.0;
    _selecting = NO;
    [self setNeedsDisplay:YES];
}

- (BOOL)isSelecting { return _selecting; }
- (double)selectionStart { return _selectionStart; }
- (double)selectionEnd { return _selectionEnd; }

@end
