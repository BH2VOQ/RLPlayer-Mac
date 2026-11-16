// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPVolumeSliderView.h"
#import "RLPVolumeKnobView.h"      // 复用 dB 换算（RLPVolClampDb / DbToNorm / NormToDb）
#import "RLPTheme.h"
#import "RLPSupport.h"

// 本视图自己的量程常量（与后端/web 同值 -120..+20）。
const double RLPVolSliderMinDb = -120.0;
const double RLPVolSliderMaxDb = 20.0;

// 与旋钮（RLPVolumeKnobView）**逐字同构**的换算。
// 背景：web ui_script.h:6221-6231 的 volDbToNorm/volNormToDb 不是幂函数，而是
// 以 0 dB 为圆心的**对数**曲线（k = 8 的 log1p）：
//     db >= 0:  norm = 0.5 + 0.5 * log1p(db / 8) / log1p(20 / 8)
//     db <  0:  norm = 0.5 - 0.5 * log1p(-db / 8) / log1p(120 / 8)
// 目的是让 0 dB 附近在轨道上占更大行程（听得准的地方给更多手指行程）。
// ⚠️ 我第一版按 pow(x, 1/2.5) 猜了一份，S1/S2 判据立刻红了 —— 这里必须以旋钮实现为准。
// k=8 与两边端值 20 / 120 都必须同步修改。
static const double kVolLogK = 8.0;

double RLPVolSliderClampDb(double db) {
    if (!isfinite(db)) return 0.0;
    double v = round(db * 10.0) / 10.0;
    return MAX(RLPVolSliderMinDb, MIN(RLPVolSliderMaxDb, v));
}

double RLPVolSliderDbToNorm(double db) {
    if (!isfinite(db)) db = 0.0;
    const double d = MAX(RLPVolSliderMinDb, MIN(RLPVolSliderMaxDb, db));
    if (d >= 0.0) {
        return 0.5 + 0.5 * log1p(d / kVolLogK) / log1p(RLPVolSliderMaxDb / kVolLogK);
    }
    return 0.5 - 0.5 * log1p(-d / kVolLogK) / log1p(-RLPVolSliderMinDb / kVolLogK);
}

double RLPVolSliderNormToDb(double norm) {
    if (!isfinite(norm)) norm = 0.0;
    const double n = MAX(0.0, MIN(1.0, norm));
    if (n >= 0.5) {
        return RLPVolSliderClampDb(kVolLogK *
            (exp(((n - 0.5) / 0.5) * log1p(RLPVolSliderMaxDb / kVolLogK)) - 1.0));
    }
    return RLPVolSliderClampDb(-kVolLogK *
        (exp(((0.5 - n) / 0.5) * log1p(-RLPVolSliderMinDb / kVolLogK)) - 1.0));
}

static const CGFloat kIconW = 20.0;        // 左侧喇叭
static const CGFloat kValueW = 56.0;       // 右侧数值
static const CGFloat kTrackH = 6.0;        // 轨道厚度
static const CGFloat kKnobR = 7.0;         // 滑块半径

@implementation RLPVolumeSliderView {
    NSButton *_mute;
    NSTextField *_value;
    BOOL _dragging;
    CGFloat _dragStartX;
    double _dragStartNorm;
    NSRect _track;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    _db = 0.0;
    _showsAccessories = YES;   // 独立使用默认自足；底栏会显式关掉
    self.wantsLayer = YES;

    _mute = [NSButton buttonWithTitle:@"" target:self action:@selector(onMute:)];
    _mute.identifier = @"vol.mute";
    _mute.bezelStyle = NSBezelStyleInline;
    _mute.bordered = NO;
    _mute.imagePosition = NSImageOnly;
    _mute.toolTip = RLPTr(@"静音 / 取消静音");
    [self addSubview:_mute];

    _value = RLPLabel(@"0.0", [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular],
                      [RLPTheme current].mut);
    _value.identifier = @"vol.value";
    _value.alignment = NSTextAlignmentRight;
    [self addSubview:_value];
    return self;
}

#pragma mark - 数值

- (void)setDb:(double)db {
    _db = RLPVolSliderClampDb(db);
    [self refreshAppearance];
}

- (void)setIsLocked:(BOOL)isLocked {
    _isLocked = isLocked;
    if (isLocked) _dragging = NO;
    _mute.enabled = !isLocked;
    [self setNeedsDisplay:YES];
}

- (BOOL)dragging { return _dragging; }

- (void)setShowsAccessories:(BOOL)showsAccessories {
    _showsAccessories = showsAccessories;
    _mute.hidden = !showsAccessories;
    _value.hidden = !showsAccessories;
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}

- (void)setOnLiveChange:(void (^)(double))onLiveChange { _onLiveChange = [onLiveChange copy]; }
- (void)setOnCommit:(void (^)(double))onCommit { _onCommit = [onCommit copy]; }

- (void)refreshAppearance {
    if (_value) {
        _value.stringValue = (_db <= RLPVolSliderMinDb + 0.05)
            ? RLPTr(@"静音")
            : [NSString stringWithFormat:@"%+.1f", _db];
    }
    if (_mute) {
        NSString *sym = (_db <= RLPVolSliderMinDb + 0.05) ? @"speaker.slash.fill"
            : (_db < 0.0 ? @"speaker.fill" : @"speaker.wave.3.fill");
        NSImage *img = [NSImage imageWithSystemSymbolName:sym accessibilityDescription:RLPTr(@"音量")];
        _mute.image = img;
        _mute.imagePosition = NSImageOnly;
    }
    [self setNeedsDisplay:YES];
}

- (NSButton *)muteButton { return _mute; }
- (NSTextField *)valueLabel { return _value; }

#pragma mark - 几何

/// 轨道矩形按当前 bounds 现算，不依赖 layout 是否已经跑过。
/// 为什么：_track 只在 -layout 里赋值，而父视图直接对子视图调用几何方法
/// （判据，或 bar 只对自身 layout）时 -layout 可能还没跑，读到的就是空矩形，
/// 于是「滑杆行程够不够」这类断言会毫无理由地假红（实测踩到）。
- (NSRect)trackRect { return [self computeTrackRect]; }

- (NSRect)computeTrackRect {
    NSRect b = self.bounds;
    const CGFloat midY = NSMidY(b);
    if (!_showsAccessories) {
        // 不带附件：轨道吃满整个宽度（底栏场景，喇叭与 dB 由底栏自己提供）
        return NSMakeRect(NSMinX(b), midY - kTrackH / 2, MAX(20, NSWidth(b)), kTrackH);
    }
    return NSMakeRect(NSMinX(b) + kIconW + 6, midY - kTrackH / 2,
                      MAX(20, NSWidth(b) - kIconW - kValueW - 18), kTrackH);
}

- (void)layout {
    [super layout];
    NSRect b = self.bounds;
    const CGFloat midY = NSMidY(b);
    _track = [self computeTrackRect];
    _mute.hidden = !_showsAccessories;
    _value.hidden = !_showsAccessories;
    _mute.frame = NSMakeRect(NSMinX(b), midY - 9, kIconW, 18);
    _value.frame = NSMakeRect(NSMaxX(b) - kValueW, midY - 9, kValueW, 18);
}

- (CGFloat)xForNorm:(double)norm {
    const NSRect track = [self trackRect];
    const double n = MAX(0.0, MIN(1.0, norm));
    return NSMinX(track) + (CGFloat)n * NSWidth(track);
}

- (double)normForX:(CGFloat)x {
    const NSRect track = [self trackRect];
    if (NSWidth(track) <= 1) return 0.5;
    return MAX(0.0, MIN(1.0, (double)((x - NSMinX(track)) / NSWidth(track))));
}

#pragma mark - 交互

- (void)mouseDown:(NSEvent *)event {
    if (self.isLocked) { [super mouseDown:event]; return; }
    // 双击 = 回 0 dB。放在最前面：双击不该先触发一次"点哪跳哪"。
    if (event.clickCount == 2) {
        self.db = 0.0;
        if (self.onLiveChange) self.onLiveChange(_db);
        if (self.onCommit) self.onCommit(_db);
        return;
    }
    const NSRect track = [self trackRect];
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    // 点轨道以外（比如只在数值上点）不改变音量，避免误触。
    if (!NSMouseInRect(p, NSInsetRect(track, -kKnobR, -kKnobR * 2), [self isFlipped]) &&
        !NSMouseInRect(p, NSInsetRect(track, -6, -10), NO)) {
        [super mouseDown:event];
        return;
    }
    _dragging = YES;
    _dragStartX = p.x;
    _dragStartNorm = RLPVolSliderDbToNorm(_db);
    // 单击 = 跳到该位置（点哪到哪，符合滑杆直觉）；随后若继续拖动则**增量**移动。
    const double n = [self normForX:p.x];
    const double db = RLPVolSliderNormToDb(n);
    if (fabs(db - _db) > 0.05) {
        self.db = db;
        if (self.onLiveChange) self.onLiveChange(_db);
    }
    _dragStartNorm = RLPVolSliderDbToNorm(_db);
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_dragging || self.isLocked) return;
    const NSRect track = [self trackRect];
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    // **增量**映射：拖动期间不改"点哪到哪"，只按指针位移走。
    // 直接绝对映射的问题：一旦指针偏离轨道中心线，同一次拖动会自己加速，
    // 想停在 -6.0 这种具体值几乎做不到（这是旧旋钮最被诟病的点）。
    const BOOL fine = (event.modifierFlags & NSEventModifierFlagOption) != 0;
    const CGFloat sens = fine ? 0.25 : 1.0;
    const CGFloat dx = (p.x - _dragStartX) * sens;
    const double n = MAX(0.0, MIN(1.0, _dragStartNorm + (double)(dx / MAX(1.0, NSWidth(track)))));
    const double db = RLPVolSliderNormToDb(n);
    if (fabs(db - _db) < 0.0499) return;
    self.db = db;
    if (self.onLiveChange) self.onLiveChange(_db);
}

- (void)mouseUp:(NSEvent *)event {
    (void)event;
    if (!_dragging) return;
    _dragging = NO;
    if (self.onCommit) self.onCommit(_db);
}

/// 滚轮：macOS 上最常用的细调通路（每格 0.5 dB，按 ⌥ 变 0.1 dB）。
- (void)scrollWheel:(NSEvent *)event {
    if (self.isLocked) { [super scrollWheel:event]; return; }
    const double step = (event.modifierFlags & NSEventModifierFlagOption) ? 0.1 : 0.5;
    const double dy = event.scrollingDeltaY;
    if (fabs(dy) < 0.01) return;
    const double next = _db + (dy > 0 ? step : -step);
    const double clamped = RLPVolSliderClampDb(next);
    if (fabs(clamped - _db) < 1e-9) return;
    self.db = clamped;
    if (self.onLiveChange) self.onLiveChange(_db);
    if (self.onCommit) self.onCommit(_db);
}

/// 双击 = 回到 0 dB（专业软件的统一习惯，比"拖到某个位置"可靠）。

- (void)onMute:(id)sender {
    (void)sender;
    if (self.isLocked) return;
    // 静音 = 拉到最小；再次点击回到 0 dB（不记忆上次值会让"取消静音"无处可回，
    // 所以这里固定回 0 dB，与 web 的静音按钮同语义）。
    const BOOL muted = (_db <= RLPVolSliderMinDb + 0.05);
    self.db = muted ? 0.0 : RLPVolSliderMinDb;
    if (self.onLiveChange) self.onLiveChange(_db);
    if (self.onCommit) self.onCommit(_db);
}

#pragma mark - 绘制

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    RLPTheme *t = [RLPTheme current];
    const NSRect track = [self trackRect];
    const double norm = RLPVolSliderDbToNorm(_db);
    const CGFloat kx = [self xForNorm:norm];

    // 底槽：整条淡灰（一眼看出"还能往哪走"）
    NSBezierPath *slot = [NSBezierPath bezierPathWithRoundedRect:track
                                                        xRadius:kTrackH / 2 yRadius:kTrackH / 2];
    [[t.mut colorWithAlphaComponent:0.28] setFill];
    [slot fill];

    // 已填充段：从 0 dB 位置到当前位置。
    // 与 EQ 推子板同一套语义（红/强调色长度 = 偏离 0 dB 的量），用户不用学两套。
    const CGFloat x0 = [self xForNorm:RLPVolSliderDbToNorm(0.0)];
    if (fabs(kx - x0) > 0.5) {
        const CGFloat left = MIN(x0, kx), right = MAX(x0, kx);
        NSRect fillRect = NSMakeRect(left, NSMinY(track), right - left, kTrackH);
        NSBezierPath *fp = [NSBezierPath bezierPathWithRoundedRect:fillRect
                                                          xRadius:kTrackH / 2 yRadius:kTrackH / 2];
        [(self.isLocked ? [t.accent colorWithAlphaComponent:0.35] : t.accent) setFill];
        [fp fill];
    }

    // 0 dB 刻度短线：给"回到中性"一个可对齐的锚
    NSBezierPath *zero = [NSBezierPath bezierPath];
    [zero moveToPoint:NSMakePoint(x0, NSMinY(track) - 3)];
    [zero lineToPoint:NSMakePoint(x0, NSMaxY(track) + 3)];
    zero.lineWidth = 1.0;
    [[t.mut colorWithAlphaComponent:0.55] setStroke];
    [zero stroke];

    // 滑块：白色圆 + 强调色描边（拖动时加粗）
    NSRect knob = NSMakeRect(kx - kKnobR, NSMidY(track) - kKnobR, kKnobR * 2, kKnobR * 2);
    NSBezierPath *kp = [NSBezierPath bezierPathWithOvalInRect:knob];
    [[NSColor whiteColor] setFill];
    [kp fill];
    [(self.isLocked ? t.mut : t.accent) setStroke];
    kp.lineWidth = _dragging ? 2.2 : 1.4;
    [kp stroke];
}

@end
