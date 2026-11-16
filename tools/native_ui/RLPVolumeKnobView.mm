// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPVolumeKnobView.mm — 音量旋钮（几何 + 绘制 + 拖动）
#import "RLPVolumeKnobView.h"
#import "RLPTheme.h"

#include <cmath>

const double RLPVolKnobMinDb = -120.0;
const double RLPVolKnobMaxDb = 20.0;

/// 逻辑空间边长（与 web svg viewBox 0 0 64 64 同值）
static const CGFloat kKnobLogical = 64.0;
/// 上游：轨道与弧半径 24；cap r=20；刻度外/内半径 major 29.2/25.8、minor 28.4/26.6。
static const CGFloat kArcRadius = 24.0;
static const CGFloat kCapRadius = 20.0;

double RLPVolClampDb(double db) {
    if (!std::isfinite(db)) return 0.0;
    const double c = fmin(RLPVolKnobMaxDb, fmax(RLPVolKnobMinDb, db));
    return round(c * 10.0) / 10.0;
}

double RLPVolDbToNorm(double db) {
    if (!std::isfinite(db)) db = 0.0;
    const double d = fmin(RLPVolKnobMaxDb, fmax(RLPVolKnobMinDb, db));
    if (d >= 0.0) return 0.5 + 0.5 * log1p(d / 8.0) / log1p(RLPVolKnobMaxDb / 8.0);
    return 0.5 - 0.5 * log1p(-d / 8.0) / log1p(-RLPVolKnobMinDb / 8.0);
}

double RLPVolNormToDb(double norm) {
    if (!std::isfinite(norm)) norm = 0.0;
    const double n = fmin(1.0, fmax(0.0, norm));
    if (n >= 0.5) return RLPVolClampDb(8.0 * (std::exp(((n - 0.5) / 0.5) * log1p(RLPVolKnobMaxDb / 8.0)) - 1.0));
    return RLPVolClampDb(-8.0 * (std::exp(((0.5 - n) / 0.5) * log1p(-RLPVolKnobMinDb / 8.0)) - 1.0));
}

NSPoint RLPVolKnobPoint(double norm, double radius) {
    const double n = fmin(1.0, fmax(0.0, std::isfinite(norm) ? norm : 0.0));
    // 上游 rlVolPoint：角度 = (-135 + 270*norm - 90)°，SVG 坐标（y 向下）。
    const double a = (-135.0 + 270.0 * n - 90.0) * M_PI / 180.0;
    return NSMakePoint(32.0 + radius * std::cos(a), 32.0 + radius * std::sin(a));
}

BOOL RLPVolKnobArcIsLarge(double norm) {
    const double n = fmin(1.0, fmax(0.0, std::isfinite(norm) ? norm : 0.0));
    return (270.0 * n) > 180.0;   // ★ 阈值 2/3，不是 0.5
}

NSString *RLPVolKnobArcPath(double norm) {
    const double n = fmin(1.0, fmax(0.0, std::isfinite(norm) ? norm : 0.0));
    if (n <= 0.0001) return @"";
    const NSPoint a = RLPVolKnobPoint(0.0, kArcRadius);
    const NSPoint b = RLPVolKnobPoint(n, kArcRadius);
    return [NSString stringWithFormat:@"M%.2f %.2f A%.0f %.0f 0 %d 1 %.2f %.2f",
            a.x, a.y, kArcRadius, kArcRadius, RLPVolKnobArcIsLarge(n) ? 1 : 0, b.x, b.y];
}

NSArray<NSNumber *> *RLPVolKnobTickDbs(void) {
    static NSArray<NSNumber *> *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        t = @[ @(-120), @(-60), @(-30), @(-18), @(-12), @(-9), @(-6), @(-3),
               @0, @3, @6, @12, @20 ];
    });
    return t;
}

BOOL RLPVolKnobTickIsMajor(double db) {
    return db == -120 || db == -60 || db == -12 || db == 0 || db == 6 || db == 12 || db == 20;
}

double RLPVolKnobDbFromAngleDegrees(double degrees) {
    if (!std::isfinite(degrees)) return 0.0;
    const double d = fmin(135.0, fmax(-135.0, degrees));
    const double norm = (d + 135.0) / 270.0;
    return RLPVolNormToDb(norm);
}

#pragma mark - 视图

@interface RLPVolumeKnobView ()
@property (nonatomic, assign) BOOL dragging;
@end

@implementation RLPVolumeKnobView

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _db = 0.0;
        self.wantsLayer = YES;
    }
    return self;
}

- (BOOL)isFlipped { return YES; }   // 与 SVG 同向（原点左上、y 向下），几何函数直接可用

- (void)setDb:(double)db {
    _db = RLPVolClampDb(db);
    self.needsDisplay = YES;
}

- (void)setLocked:(BOOL)locked {
    _locked = locked;
    if (locked) self.dragging = NO;
    self.needsDisplay = YES;
}

- (CGFloat)scale { return fmin(self.bounds.size.width, self.bounds.size.height) / kKnobLogical; }

/// 逻辑坐标（0..64）→ 视图坐标
- (NSPoint)viewPointFromLogical:(NSPoint)p {
    const CGFloat s = [self scale];
    const CGFloat ox = (self.bounds.size.width - kKnobLogical * s) / 2.0;
    const CGFloat oy = (self.bounds.size.height - kKnobLogical * s) / 2.0;
    return NSMakePoint(ox + p.x * s, oy + p.y * s);
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    RLPTheme *t = [RLPTheme current];
    const CGFloat s = [self scale];
    const NSPoint center = [self viewPointFromLogical:NSMakePoint(32.0, 32.0)];

    // 圆形底盘（web .rlVolKnob::before：inset 2px、field 底、1px line 边）
    const CGFloat discR = 30.0 * s;
    NSBezierPath *disc = [NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(center.x - discR, center.y - discR, discR * 2.0, discR * 2.0)];
    [t.field setFill];
    [disc fill];
    [t.line setStroke];
    disc.lineWidth = 1.0;
    [disc stroke];

    // 轨道：整段 270° 弧（-135° → +135°），stroke 4、圆头
    const CGFloat strokeW = 4.0 * s;
    const CGFloat arcR = kArcRadius * s;
    NSBezierPath *track = [NSBezierPath bezierPath];
    // 用足够多的小段逼近弧，避免 NSBezierPath 三次曲线在两端的圆头差异
    const NSInteger seg = 96;
    for (NSInteger i = 0; i <= seg; ++i) {
        const double n = (double)i / (double)seg;
        const NSPoint lp = RLPVolKnobPoint(n, kArcRadius);
        const NSPoint vp = [self viewPointFromLogical:lp];
        if (i == 0) [track moveToPoint:vp]; else [track lineToPoint:vp];
    }
    track.lineWidth = strokeW;
    [t.line setStroke];
    [track stroke];

    // 刻度（minor 1.2/.65，major 1.7/.95）
    for (NSNumber *n in RLPVolKnobTickDbs()) {
        const double db = n.doubleValue;
        const BOOL major = RLPVolKnobTickIsMajor(db);
        const double norm = RLPVolDbToNorm(db);
        const NSPoint p1 = [self viewPointFromLogical:RLPVolKnobPoint(norm, major ? 29.2 : 28.4)];
        const NSPoint p2 = [self viewPointFromLogical:RLPVolKnobPoint(norm, major ? 25.8 : 26.6)];
        NSBezierPath *tick = [NSBezierPath bezierPath];
        [tick moveToPoint:p1];
        [tick lineToPoint:p2];
        tick.lineWidth = (major ? 1.7 : 1.2) * s;
        [(major ? t.text : t.mut2) setStroke];
        [tick stroke];
    }

    // 值弧（accent，stroke 4 圆头）：从起点画到当前值
    const double norm = RLPVolDbToNorm(self.db);
    if (norm > 0.0001) {
        NSBezierPath *arc = [NSBezierPath bezierPath];
        const NSInteger seg2 = MAX(2, (NSInteger)ceil(270.0 * norm / 3.0));
        for (NSInteger i = 0; i <= seg2; ++i) {
            const double n = norm * (double)i / (double)seg2;
            const NSPoint vp = [self viewPointFromLogical:RLPVolKnobPoint(n, kArcRadius)];
            if (i == 0) [arc moveToPoint:vp]; else [arc lineToPoint:vp];
        }
        arc.lineWidth = strokeW;
        [t.accent setStroke];
        [arc stroke];
    }

    // 中心盖（cap r=20，bg2 填充 + 1px line 边）
    const CGFloat capR = kCapRadius * s;
    NSBezierPath *cap = [NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(center.x - capR, center.y - capR, capR * 2.0, capR * 2.0)];
    [t.bg2 setFill];
    [cap fill];
    [t.line setStroke];
    cap.lineWidth = 1.0;
    [cap stroke];

    if (self.isLocked) {   // web .rlVolKnob[data-locked=true]{opacity:.45}
        [[t.bg colorWithAlphaComponent:0.45] setFill];
        NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
    }
}

/// 逻辑坐标（0..64，y 向下）→ dB。中心为 (32,32)，正上方为 0°。
- (double)dbForLogicalPoint:(NSPoint)p {
    const double dx = p.x - 32.0;
    const double dy = 32.0 - p.y;          // 上游用 (cy - y) 算角度
    const double deg = std::atan2(dx, dy) * 180.0 / M_PI;
    return RLPVolKnobDbFromAngleDegrees(deg);
}

- (BOOL)dragToPointForAudit:(NSPoint)pointIn64 {
    if (self.isLocked) return NO;
    const double db = [self dbForLogicalPoint:pointIn64];
    const BOOL changed = (db != self.db);
    self.db = db;
    if (self.onLiveChange) self.onLiveChange(self.db);
    return changed;
}

- (void)mouseDown:(NSEvent *)event {
    if (self.isLocked) { [super mouseDown:event]; return; }
    if (event.clickCount == 2) {
        self.db = 0.0;
        if (self.onLiveChange) self.onLiveChange(self.db);
        if (self.onCommit) self.onCommit(self.db);
        return;
    }
    self.dragging = YES;
    [self applyEvent:event];
}

- (void)mouseDragged:(NSEvent *)event {
    if (!self.dragging || self.isLocked) return;
    [self applyEvent:event];
}

- (void)mouseUp:(NSEvent *)event {
    (void)event;
    if (!self.dragging) return;
    self.dragging = NO;
    if (self.onCommit) self.onCommit(self.db);
}

- (void)scrollWheel:(NSEvent *)event {
    if (self.isLocked) { [super scrollWheel:event]; return; }
    const double step = ((event.modifierFlags & (NSEventModifierFlagOption | NSEventModifierFlagShift)) != 0) ? 0.1 : 0.5;
    const double dy = event.scrollingDeltaY;
    if (std::fabs(dy) < 0.01) return;
    const double next = RLPVolClampDb(self.db + (dy > 0 ? step : -step));
    if (std::fabs(next - self.db) < 1e-9) return;
    self.db = next;
    if (self.onLiveChange) self.onLiveChange(self.db);
    if (self.onCommit) self.onCommit(self.db);
}

- (void)applyEvent:(NSEvent *)event {
    const NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
    const CGFloat s = [self scale];
    const CGFloat ox = (self.bounds.size.width - kKnobLogical * s) / 2.0;
    const CGFloat oy = (self.bounds.size.height - kKnobLogical * s) / 2.0;
    const NSPoint logical = NSMakePoint((local.x - ox) / s, (local.y - oy) / s);
    const double db = [self dbForLogicalPoint:logical];
    if (db == self.db) return;
    self.db = db;
    if (self.onLiveChange) self.onLiveChange(self.db);
}

@end
