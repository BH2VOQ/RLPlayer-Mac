// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPPlaybackBarView.mm — 底部播放条（纯 AppKit）
//
// 设计要点：
//   * 状态真相源是 C++ 核心：每 500 ms 轮询 /api/status（与 web 版同一字段），UI 不自己猜状态。
//   * 控制动作只走 /api/pause、/api/skip、/api/seek、/api/volume —— 与 web 版完全同一条后端路径，
//     不新增第二套播放逻辑。
//   * 拖动进度/音量期间不用轮询值回写（否则滑块会被"橡皮筋"拉回去）；松手才提交一次。
//   * 没开始轮询（核心未启动/selftest）时不发任何请求。
#import "RLPPlaybackBarView.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPTheme.h"
#import "RLPSupport.h"   // RLPTr / RLPToast / RLPPostJSON（播放模式按钮用）
#import "RLPSignalChain.h"   // 底栏「信号链」弹层（与工作台同一份纯函数）

#pragma mark - 可拖动滑块（区分"用户正在拖"与"轮询回写"）

@interface RLPCommitSlider : NSSlider
@property (nonatomic, assign, readonly) BOOL dragging;
@property (nonatomic, copy, nullable) void (^onCommit)(void);
@end

@implementation RLPCommitSlider
- (void)mouseDown:(NSEvent *)event {
    _dragging = YES;
    [super mouseDown:event];      // NSSlider 在这里跑完整个拖动循环
    _dragging = NO;
    if (self.onCommit) self.onCommit();
}
@end

// 底栏封面：web 的 #cv 本身没有 click 绑定（进播放页靠 #npOpen），但用户明确要求
// 「播放栏点击作品封面需要可以跳转到播放页」⟹ 两边都该多这个入口，原生先做。
// 用 mouseDown 直接处理而不是手势识别器：手势在离屏/非 key window 下容易不触发，
// 而这里要的判据恰恰是"点下去真的开了播放页"。
@interface RLPBarCoverView : NSImageView
@property (nonatomic, copy, nullable) void (^onClick)(void);
@property (nonatomic, assign) BOOL hovered;
@end

@implementation RLPBarCoverView {
    NSTrackingArea *_hoverArea;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_hoverArea) { [self removeTrackingArea:_hoverArea]; _hoverArea = nil; }
    _hoverArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                              options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow)
                                                owner:self userInfo:nil];
    [self addTrackingArea:_hoverArea];
}
- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    self.hovered = YES;
    [[NSCursor pointingHandCursor] set];   // 可点的视觉提示（不可点的话用户根本不会去点）
    [self setNeedsDisplay:YES];
}
- (void)mouseExited:(NSEvent *)event {
    (void)event;
    self.hovered = NO;
    [self setNeedsDisplay:YES];
}
- (void)mouseDown:(NSEvent *)event {
    // 单击由 mouseDown/mouseUp 一对构成；这里在按下时就开页，与 web #npOpen 的 onclick 同观感。
    (void)event;
    if (self.onClick) self.onClick();
}
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if (!self.hovered || !self.image) return;
    // 悬停时压一层很淡的亮色（圆角由 layer masksToBounds 裁掉）——告诉用户这块能点。
    NSColor *c = (NSApp.effectiveAppearance.name == NSAppearanceNameDarkAqua)
               ? [NSColor colorWithWhite:1 alpha:0.10] : [NSColor colorWithWhite:0 alpha:0.06];
    [c setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:8 yRadius:8] fill];
}
@end

// Keep NSSlider's native keyboard/accessibility/tracking, but not its OS-blue paint.
/// 徽标标签：把文字画在**正中心**（水平 + 垂直）。
///
/// 为什么不能用 `NSTextField` 的原生绘制：固定高度的胶囊里，NSTextField 会把单行文字
/// 排在**顶部**（实测 gpuBadge：20pt 高的框里，"GPU" 墨迹顶部留白 0.5pt、底部 9.0pt），
/// 而且它的 `alignment` 只影响水平方向，且 `NSTextAlignmentNatural` 会退化成左对齐
/// （实测 `gpuBadge` 左留白 0.5pt、右留白 10pt）。
/// 两者叠加就是用户报的「文字不在徽章正中心」。
///
/// 这里直接按 attributed string 的实测尺寸算中心点落笔：
/// 水平 `(bounds.w - text.w)/2`、垂直 `(bounds.h - text.h)/2`，两个方向各留 ≤1pt 误差。
/// 背景与边框仍由 layer 负责（wantsLayer + backgroundColor/borderColor），
/// 所以这个类只接管"字画在哪"，不接管"胶囊长什么样"。
@interface RLPBadgeLabel : NSTextField
@end

@implementation RLPBadgeLabel
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSAttributedString *as = self.attributedStringValue.length
        ? self.attributedStringValue
        : [[NSAttributedString alloc] initWithString:(self.stringValue ?: @"")
                                          attributes:@{ NSFontAttributeName: self.font ?: [NSFont systemFontOfSize:9.5],
                                                        NSForegroundColorAttributeName: self.textColor ?: NSColor.labelColor }];
    if (as.length == 0) return;
    const NSSize sz = as.size;
    const NSRect b = self.bounds;
    if (b.size.width < 2 || b.size.height < 2) return;
    // round 到整点：亚像素落笔会让墨迹包围盒出现 0.5pt 的抖动，判据（≤1pt）要它稳。
    const NSRect r = NSMakeRect(round((b.size.width - sz.width) / 2.0),
                               round((b.size.height - sz.height) / 2.0),
                               ceil(sz.width), ceil(sz.height));
    [as drawInRect:r];
}
@end

/// 徽标文字：web `.badge` 有 letter-spacing（.badge .3px / #bpBadge .4px），
/// NSTextField 属性里没有字距，必须走 attributedStringValue 才能有"高级感"。
static void RLPSetBadgeText(NSTextField *label, NSString *text, NSColor *color, CGFloat kern) {
    if (!label) return;
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = NSTextAlignmentCenter;
    NSDictionary *attrs = @{
        NSFontAttributeName: label.font ?: [NSFont systemFontOfSize:9.5],
        NSForegroundColorAttributeName: color ?: NSColor.labelColor,
        NSKernAttributeName: @(kern),
        NSParagraphStyleAttributeName: ps,
    };
    label.attributedStringValue = [[NSAttributedString alloc] initWithString:text attributes:attrs];
    // 同时维护 stringValue：`attributedStringValue` 的 setter **不会**回填 `stringValue`，
    // 而既有的「徽标文案随状态变」判据（以及任何按 stringValue 判断的代码）读的是后者。
    // 只设 attributed 会让那条判据永远读到空串 —— 它过去一直"通过"是因为压根没比较成功过。
    label.stringValue = text ?: @"";
}

@interface RLPBarSliderCell : NSSliderCell
/// web #vol/#npVol 是原生 range 滑块：红色填充 + 白色胶囊滑块头，**滑块头右缘贴住轨道右端**。
/// 旧实现画 10px 红圆点、填充一路画到最右 ⟹ 用户实测「最大音量不是直接拉到头的」。
@property (nonatomic, assign) BOOL capsuleStyle;
/// 进度条：web .track 只有填充线、没有滑块头，这里同款（音量条才画胶囊头）。
@property (nonatomic, assign) BOOL hideKnob;
@end
@implementation RLPBarSliderCell
- (void)drawBarInside:(NSRect)rect flipped:(BOOL)flipped {
    NSRect track = NSMakeRect(rect.origin.x, NSMidY(rect)-2, rect.size.width, 4);
    [[RLPTheme current].track setFill];
    [[NSBezierPath bezierPathWithRoundedRect:track xRadius:2 yRadius:2] fill];
    double fraction = (self.doubleValue-self.minValue)/MAX(1e-9,self.maxValue-self.minValue);
    fraction = MAX(0.0, MIN(1.0, fraction));
    CGFloat fillEnd;
    if (self.capsuleStyle) {
        // 与 web 同几何：滑块头中心在 [左端+半头宽, 右端-半头宽] 之间移动，
        // 填充画到头中心为止（最右端时头右缘正好贴住轨道右端）。
        const CGFloat knobW = 22.0;
        CGFloat minC = NSMinX(track) + knobW/2.0;
        CGFloat maxC = NSMaxX(track) - knobW/2.0;
        fillEnd = minC + fraction * MAX(0.0, maxC - minC);
    } else {
        fillEnd = NSMinX(track) + NSWidth(track) * fraction;
    }
    NSRect fill = track;
    fill.size.width = MAX(0.0, fillEnd - NSMinX(track));
    if (fill.size.width > 0) {
        [[RLPTheme current].accent setFill];
        [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:2 yRadius:2] fill];
    }
}

- (void)drawKnob:(NSRect)rect {
    if (self.hideKnob) return;
    if (!self.capsuleStyle) {
        [[RLPTheme current].accent setFill];
        NSRect knob = NSMakeRect(NSMidX(rect)-5,NSMidY(rect)-5,10,10);
        [[NSBezierPath bezierPathWithOvalInRect:knob] fill];
        return;
    }
    // web 原生 range 滑块头：白色横向胶囊（约 22×13）+ 很淡的投影，压在红色填充上。
    const CGFloat knobW = 22.0, knobH = 13.0;
    NSRect knob = NSMakeRect(NSMidX(rect)-knobW/2.0, NSMidY(rect)-knobH/2.0, knobW, knobH);
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [NSColor blackColor];
    shadow.shadowBlurRadius = 3.0;
    shadow.shadowOffset = NSMakeSize(0, -1);
    [shadow set];
    [[NSColor whiteColor] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:knob xRadius:knobH/2.0 yRadius:knobH/2.0] fill];
    [[NSGraphicsContext currentContext] setShouldAntialias:YES];
}
@end

#pragma mark - 播放条

@interface RLPPlaybackBarView ()
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, assign, readwrite) BOOL polling;
@property (nonatomic, strong) NSButton *prevBtn;
@property (nonatomic, strong) NSButton *playBtn;
@property (nonatomic, strong) NSButton *nextBtn;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *subLabel;
@property (nonatomic, strong) NSTextField *posLabel;    // 进度左端「当前时间」
@property (nonatomic, strong) NSTextField *durLabel;    // 进度右端「总时长」
@property (nonatomic, strong) NSTextField *fmtBadge;    // 「44.1k/24」格式徽标（web #fmt）
@property (nonatomic, strong) NSButton *lyricBtn;       // 歌词（web #bLyric）
@property (nonatomic, strong) NSButton *chainBtn;       // 信号链（web #bChain）
@property (nonatomic, strong) RLPCommitSlider *progress;
@property (nonatomic, strong) RLPCommitSlider *volume;
@property (nonatomic, strong) NSImageView *volIconView;
@property (nonatomic, strong) NSImageView *coverView;      // 封面缩略图（web 底栏左侧）
@property (nonatomic, strong) NSTextField *bpBadge;        // BIT-PERFECT 绿色徽标
@property (nonatomic, copy) NSString *coverPath;
@property (nonatomic, assign) NSUInteger coverSeq;
@property (nonatomic, copy) NSString *metaPath;
@property (nonatomic, copy) NSString *metaTitle;
@property (nonatomic, copy) NSDictionary *statusDetails;
@property (nonatomic, strong) NSTextField *gpuBadge;
/// 磨砂玻璃层（第14项）。必须位于内容之下，frame 覆盖整条。
@property (nonatomic, strong) NSVisualEffectView *glassEffect;
@property (nonatomic, strong) RLPPlaybackStatus *lastStatus;
/// 播放模式：**唯一真相源**是 /api/playmode 的 mode（0=顺序 1=列表循环 2=单曲循环 3=随机）。
/// /api/repeat 与 /api/shuffle 在核心侧只是它的派生写入口，没有独立存储 ——
/// 所以 UI 也只读写 mode 一个值，不自己维护第二份状态（否则两处真相必然打架）。
@property (nonatomic, assign) NSInteger playMode;
@property (nonatomic, strong) NSButton *shuffleBtn;
@property (nonatomic, strong) NSButton *repeatBtn;
@property (nonatomic, strong) NSButton *stopBtn;
/// 进随机之前的模式：退出随机时回到它（而不是硬编码回顺序）。
@property (nonatomic, assign) NSInteger modeBeforeShuffle;
/// 播放模式的读取节流计数（每 4 次状态轮询读一次 /api/playmode）。
@property (nonatomic, assign) NSInteger modePollTick;
@end

@implementation RLPPlaybackBarView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) [self setup];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) [self setup];
    return self;
}

- (void)setup {
    RLPTheme *t = [RLPTheme current];
    self.wantsLayer = YES;
    self.layer.backgroundColor = t.barBg.CGColor;

    // ---- 磨砂玻璃层（第14项：Apple Music 式悬浮胶囊条）----
    //
    // 材质选型：`.hudWindow`。理由是参考图（用户给的 Apple Music 截图）里，条内的模糊是
    // **强模糊 + 轻微提亮**，底下封面被糊成一片色晕而不是可辨认的图；`.sidebar` 偏冷、
    // `.underWindowBackground` 偏透且几乎不提亮，两者都与参考图观感不符。
    // blendingMode 用 `.withinWindow`：内容就在同一窗口里（专辑网格/页面），
    // 用 `.behindWindow` 会把桌面也透进来，与参考图不符。
    // state 用 `.active`：跟随窗口激活态自动切换会被动变灰，参考图里失焦也不发死灰。
    //
    // 关键：这一层必须**在最底下**（`positioned:NSWindowBelow relativeTo:nil`），
    // 否则它会盖住文字与按钮。
    NSVisualEffectView *glass = [[NSVisualEffectView alloc] initWithFrame:self.bounds];
    glass.identifier = @"pb.glass";
    glass.material = NSVisualEffectMaterialHUDWindow;
    glass.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    glass.state = NSVisualEffectStateActive;
    glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    // 圆角与播放条一致：NSVisualEffectView 自己按 layer 圆角裁剪
    glass.wantsLayer = YES;
    glass.layer.cornerRadius = 16;
    glass.layer.masksToBounds = YES;
    [self addSubview:glass positioned:NSWindowBelow relativeTo:nil];
    self.glassEffect = glass;

    // 悬浮卡片形态：边框/圆角/阴影由主窗口设置，这里不再画贴边细线。

    self.prevBtn = [self symbolButton:@"backward.fill" tip:@"上一首"];
    self.playBtn = [self symbolButton:@"play.fill" tip:@"播放 / 暂停"];
    self.nextBtn = [self symbolButton:@"forward.fill" tip:@"下一首"];
    // 稳定锚点（与 web #bPrev/#bPause/#bNext 一一对应；行为扫描用它们核对绑定）：
    self.prevBtn.identifier = @"pb.prev";
    self.playBtn.identifier = @"pb.play";
    self.nextBtn.identifier = @"pb.next";
    self.prevBtn.action = @selector(previousTrack);
    self.playBtn.action = @selector(playPause);
    self.nextBtn.action = @selector(nextTrack);
    // 播放模式：随机（Fisher–Yates 整表乱序，核心侧已实现）与列表循环。
    // 放在播放键左侧，与 QQ 音乐 / Spotify 的位置习惯一致。
    self.shuffleBtn = [self symbolButton:@"shuffle" tip:@"随机播放"];
    self.shuffleBtn.target = self;
    self.shuffleBtn.action = @selector(toggleShuffle:);
    self.repeatBtn = [self symbolButton:@"repeat" tip:@"列表循环"];
    self.repeatBtn.target = self;
    self.repeatBtn.action = @selector(toggleRepeat:);
    // 停止（与暂停不同：停止会释放设备，web 版底栏也有这个键）
    self.stopBtn = [self symbolButton:@"stop.fill" tip:@"停止"];
    self.stopBtn.identifier = @"pb.stop";
    self.stopBtn.target = self;
    self.stopBtn.action = @selector(stopPlayback:);
    for (NSButton *b in @[self.prevBtn, self.playBtn, self.nextBtn, self.stopBtn, self.shuffleBtn, self.repeatBtn])
        [self addSubview:b];
    self.playBtn.imageScaling = NSImageScaleProportionallyDown;
    // 红色实心圆播放键（web 底栏的视觉锚点）
    self.playBtn.wantsLayer = YES;
    self.playBtn.layer.cornerRadius = 17;
    self.shuffleBtn.hidden = YES; // API preserved; four-mode repeat control is the visible entry.
    self.playBtn.layer.backgroundColor = t.accent.CGColor;
    self.playBtn.contentTintColor = NSColor.whiteColor;
    self.playBtn.identifier = @"pb.play";

    // 封面缩略图（web 底栏最左）
    RLPBarCoverView *cv = [[RLPBarCoverView alloc] initWithFrame:NSZeroRect];
    cv.imageScaling = NSImageScaleProportionallyUpOrDown;
    __weak __typeof__(self) weakCoverBar = self;
    cv.onClick = ^{
        __typeof__(self) s = weakCoverBar;
        if (s) [s openNowPlaying:nil];
    };
    cv.toolTip = RLPTr(@"打开正在播放");
    self.coverView = cv;
    self.coverView.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.coverView.wantsLayer = YES;
    self.coverView.layer.cornerRadius = 8;
    self.coverView.layer.masksToBounds = YES;
    self.coverView.layer.backgroundColor = t.bg3.CGColor;
    self.coverView.identifier = @"pb.cover";
    [self addSubview:self.coverView];

    // BIT-PERFECT 徽标（只在后端确实判定位完美时显示）
    self.bpBadge = [self badgeLabelWithFont:[NSFont systemFontOfSize:9.5 weight:NSFontWeightBold] color:t.ok];
    self.bpBadge.stringValue = @"BIT-PERFECT";
    self.bpBadge.wantsLayer = YES;
    self.bpBadge.layer.cornerRadius = 5;          // web #bpBadge{border-radius:5px}
    self.bpBadge.layer.borderWidth = 1;
    self.bpBadge.layer.borderColor = t.okLine.CGColor;
    self.bpBadge.alignment = NSTextAlignmentCenter;
    self.bpBadge.identifier = @"pb.bp";
    self.bpBadge.stringValue = RLPTr(@"待播放验证");
    self.bpBadge.hidden = NO;
    [self addSubview:self.bpBadge];

    self.titleLabel = [self labelWithFont:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]
                                    color:t.text];
    // 与 web .np 同口径：底栏左侧只放两行（曲名 + 艺术家·专辑），技术信息不进底栏左侧。
    self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.titleLabel.stringValue = RLPTr(@"未播放");
    self.subLabel = [self labelWithFont:[NSFont systemFontOfSize:11] color:t.mut];
    self.subLabel.stringValue = @"—";

    // 进度两端的当前时间 / 总时长（web #tpos / #tdur：分列在滑杆两侧，不再挤成一行）。
    self.posLabel = [self labelWithFont:[NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightRegular]
                                  color:t.mut];
    self.posLabel.stringValue = @"0:00";
    self.posLabel.alignment = NSTextAlignmentRight;
    self.posLabel.identifier = @"pb.pos";
    self.durLabel = [self labelWithFont:[NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightRegular]
                                  color:t.mut];
    self.durLabel.stringValue = @"0:00";
    self.durLabel.identifier = @"pb.dur";

    // 格式徽标（web #fmt：「44.1k/24」）。没有开始播放时显示 "--"，与 web 一致。
    self.fmtBadge = [self badgeLabelWithFont:[NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold]
                                       color:t.accentText];
    self.fmtBadge.stringValue = @"--";
    self.gpuBadge = [self badgeLabelWithFont:[NSFont systemFontOfSize:9.5 weight:NSFontWeightBold] color:t.okText];
    self.gpuBadge.stringValue = @"GPU";
    self.gpuBadge.identifier = @"pb.gpu";
    // 与另外两枚同一构件（用户第13项要求"三枚徽章统一成同一构件"）：
    // web `.badge.g{background:var(--ok-bg);color:var(--ok-text);border-color:var(--ok-line)}`
    // —— 旧实现在这里只设了文字色、没给胶囊底与描边，截图上看起来是个裸文字。
    self.gpuBadge.wantsLayer = YES;
    self.gpuBadge.layer.cornerRadius = 5;          // 与 bpBadge 同圆角
    self.gpuBadge.layer.borderWidth = 1;
    self.gpuBadge.layer.borderColor = t.okLine.CGColor;
    self.gpuBadge.layer.backgroundColor = t.okBg.CGColor;
    self.gpuBadge.hidden = YES;
    [self addSubview:self.gpuBadge];
    self.fmtBadge.identifier = @"pb.fmt";
    self.fmtBadge.alignment = NSTextAlignmentCenter;
    self.fmtBadge.wantsLayer = YES;
    self.fmtBadge.layer.cornerRadius = 5;         // web .badge{border-radius:5px}
    self.fmtBadge.layer.borderWidth = 1;
    self.fmtBadge.layer.borderColor = t.accentWeak.CGColor;
    self.fmtBadge.layer.backgroundColor = t.accentWeak.CGColor;

    // 歌词 / 信号链（web #bLyric / #bChain，两个 32pt 图标键）
    self.lyricBtn = [self symbolButton:@"music.note.list" tip:@"歌词"];
    self.lyricBtn.identifier = @"pb.lyric";
    self.lyricBtn.target = self;
    // web #bLyric 打开的是右侧抽屉的歌词页，不是单曲页。
    self.lyricBtn.action = @selector(openLyricDrawer:);
    self.chainBtn = [self symbolButton:@"waveform.path" tip:@"信号链"];
    self.chainBtn.identifier = @"pb.chain";
    self.chainBtn.target = self;
    self.chainBtn.action = @selector(showSignalChain:);

    self.progress = [[RLPCommitSlider alloc] initWithFrame:NSZeroRect];
    RLPBarSliderCell *progCell = [[RLPBarSliderCell alloc] init];
    progCell.hideKnob = YES;             // web .track：只有填充线，没有圆点
    self.progress.cell = progCell;
    self.progress.minValue = 0.0;
    self.progress.maxValue = 1.0;
    self.progress.doubleValue = 0.0;
    self.progress.continuous = YES;
    self.progress.controlSize = NSControlSizeSmall;
    self.progress.target = self;
    self.progress.action = @selector(progressChanged:);
    __weak __typeof__(self) weakSelf = self;
    self.progress.onCommit = ^{ [weakSelf commitSeek]; };
    self.progress.identifier = @"pb.progress";

    NSImage *volIcon = [NSImage imageWithSystemSymbolName:@"speaker.wave.2"
                                 accessibilityDescription:@"音量"];
    NSImageView *volView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    volView.image = volIcon;
    volView.contentTintColor = t.mut;
    volView.translatesAutoresizingMaskIntoConstraints = NO;
    self.volIconView = volView;

    // 音量滑块改用**位置刻度 0..1000**（web 2026-10-25 修过的曲线）：
    // 旧实现是线性 dB 刻度，拖到中间就 -30 dB（只剩 3% 振幅），用户会以为"没声音"。
    self.volume = [[RLPCommitSlider alloc] initWithFrame:NSZeroRect];
    RLPBarSliderCell *volCell = [[RLPBarSliderCell alloc] init];
    volCell.capsuleStyle = YES;          // web #vol 的白色胶囊滑块头
    self.volume.cell = volCell;
    self.volume.minValue = 0.0;
    self.volume.maxValue = 1000.0;
    self.volume.doubleValue = 1000.0;
    self.volume.continuous = YES;
    self.volume.controlSize = NSControlSizeSmall;
    self.volume.target = self;
    self.volume.action = @selector(volumeChanged:);
    self.volume.onCommit = ^{ [weakSelf commitVolume]; };
    self.volume.identifier = @"pb.vol";

    for (NSView *v in @[self.titleLabel, self.subLabel, self.posLabel, self.durLabel, self.fmtBadge,
                        self.lyricBtn, self.chainBtn, self.progress, volView, self.volume]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:v];
    }

    // 内部不用 Auto Layout：固定 66px 高的悬浮条，手动布局最稳
    // （约束方案在本机出现过控制键被挤出卡片的问题，见 layout）。
}

/// 音量位置刻度 ↔ dB 的互逆曲线（逐字对齐 web ui_script.h 的 volPosToDb / volDbToPos）。
/// pos=0..5 为静音档（-120 dB），其余按 -55·(1-p)^1.6；见 web 注释里"拖到中间没声音"的事故。
static const double kVolMinDb = -55.0;
static const double kVolSilentDb = -120.0;
static const int kVolSilentPos = 5;

static double RLPVolPosToDb(double pos) {
    if (!isfinite(pos)) return kVolSilentDb;
    double p = fmax(0.0, fmin(1000.0, pos)) / 1000.0;
    if (pos <= kVolSilentPos) return kVolSilentDb;
    return -fabs(kVolMinDb) * pow(1.0 - p, 1.6);
}

static double RLPVolDbToPos(double db) {
    if (!isfinite(db) || db >= 0.0) return 1000.0;
    if (db <= kVolMinDb) return 0.0;
    return round(1000.0 * (1.0 - pow(-db / fabs(kVolMinDb), 1.0 / 1.6)));
}

/// Web .bar/.ctr/.keys/.vol: five keys, measured status cluster, no width-based badge hiding.
- (void)layout {
    [super layout];
    CGFloat W=NSWidth(self.bounds), H=NSHeight(self.bounds);
    if (W<=0 || H<=0) return;
    void (^place)(NSView *,CGFloat,CGFloat,CGFloat,CGFloat)=^(NSView *v,CGFloat x,CGFloat y,CGFloat w,CGFloat h){ v.frame=NSMakeRect(x,y,MAX(0,w),h); };
    if (self.glassEffect) self.glassEffect.frame = self.bounds;
    CGFloat pad=18, gap=14, itemGap=6;
    CGFloat bpW=ceil(self.bpBadge.intrinsicContentSize.width)+14;
    CGFloat fmtW=MAX(40,ceil(self.fmtBadge.intrinsicContentSize.width)+14);   // web .badge 左右 padding 7
    CGFloat gpuW=self.gpuBadge.hidden?0:34;
    CGFloat volW=76, iconW=32;
    CGFloat rightW=32*2+bpW+fmtW+14+volW+itemGap*5+(gpuW?gpuW+itemGap:0);
    CGFloat available=W-2*pad-2*gap;
    CGFloat centerW=MIN(440,available*1.6/3.8);
    // Equal left/right columns keep the five-key group centered on the whole bar.
    // Expand BOTH side columns for content, never steal only from the left column.
    centerW=MIN(centerW,available-2*rightW);
    BOOL wrap=centerW<198;
    if (wrap) {
        volW=48;
        CGFloat sideBudget=(available-198)/2;
        iconW=MIN(32,MAX(24,(sideBudget-bpW-2*itemGap)/2));
        CGFloat topW=2*iconW+bpW+itemGap*2;
        CGFloat bottomW=fmtW+14+volW+itemGap*2+(gpuW?gpuW+itemGap:0);
        rightW=MAX(topW,bottomW);
        centerW=MAX(198,MIN(440,MIN(available*1.6/3.8,available-2*rightW)));
    }
    CGFloat leftW=(available-centerW)/2;
    CGFloat cx=(W-centerW)/2, rx=cx+centerW+gap;
    place(self.coverView,pad,(H-44)/2,44,44);
    place(self.titleLabel,pad+55,H/2+2,leftW-55,17);
    place(self.subLabel,pad+55,H/2-16,leftW-55,15);
    CGFloat small=32,big=34,keyGap=6,keysW=small*4+big+keyGap*4;
    CGFloat x=cx+(centerW-keysW)/2, cy=H-24;
    for (NSButton *key in @[self.repeatBtn,self.prevBtn,self.playBtn,self.nextBtn,self.stopBtn]) {
        CGFloat size=key==self.playBtn?big:small;
        place(key,x,cy-size/2,size,size); x+=size+keyGap;
    }
    self.shuffleBtn.hidden=YES;
    CGFloat timeW=34,timeGap=8;
    place(self.posLabel,cx,7,timeW,16);
    place(self.progress,cx+timeW+timeGap,7,centerW-2*(timeW+timeGap),16);
    place(self.durLabel,cx+centerW-timeW,7,timeW,16);
    NSArray *rows=wrap?@[@[self.lyricBtn,self.chainBtn,self.bpBadge],
                         @[self.fmtBadge,self.gpuBadge,self.volIconView,self.volume]]:
                        @[@[self.lyricBtn,self.chainBtn,self.bpBadge,self.fmtBadge,self.gpuBadge,self.volIconView,self.volume]];
    for (NSUInteger row=0;row<rows.count;++row) {
        CGFloat rowX=rx;
        for (NSView *v in rows[row]) {
            if (v==self.gpuBadge && v.hidden) continue;
            CGFloat w=v==self.volume?volW:v==self.volIconView?14:v==self.bpBadge?bpW:v==self.fmtBadge?fmtW:v==self.gpuBadge?gpuW:iconW;
            CGFloat h=(v==self.lyricBtn || v==self.chainBtn)?32:v==self.volume?16:20;
            CGFloat rowCY=wrap?(row==0?H-21:13):H/2;
            place(v,rowX,rowCY-h/2,w,h); rowX+=w+itemGap;
        }
    }
}

- (NSButton *)symbolButton:(NSString *)symbol tip:(NSString *)tip {
    NSButton *b = [[NSButton alloc] initWithFrame:NSZeroRect];
    b.bordered = NO;
    b.imagePosition = NSImageOnly;
    b.imageScaling = NSImageScaleProportionallyDown;
    b.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:RLPTr(tip)];
    b.contentTintColor = [RLPTheme current].text;
    b.toolTip = RLPTr(tip);   // 多语言：tooltip 也必须过词表
    b.target = self;
    return b;
}

/// 胶囊徽章用：与 labelWithFont: 同参，但用的是自绘居中的 RLPBadgeLabel。
- (NSTextField *)badgeLabelWithFont:(NSFont *)font color:(NSColor *)color {
    RLPBadgeLabel *l = [[RLPBadgeLabel alloc] initWithFrame:NSZeroRect];
    l.editable = NO;
    l.selectable = NO;
    l.bezeled = NO;
    l.drawsBackground = NO;
    l.bordered = NO;
    l.font = font;
    l.textColor = color;
    l.alignment = NSTextAlignmentCenter;
    return l;
}

- (NSTextField *)labelWithFont:(NSFont *)font color:(NSColor *)color {
    NSTextField *l = [NSTextField labelWithString:@""];
    l.font = font;
    l.textColor = color;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    l.maximumNumberOfLines = 1;
    return l;
}

#pragma mark - 媒体键支持

- (BOOL)isPlaying {
    RLPPlaybackStatus *st = self.lastStatus;
    return st != nil && st.playing && !st.paused;
}

- (void)seekToSeconds:(double)seconds {
    RLPPlaybackStatus *st = self.lastStatus;
    // 没有时长就没有可跳的范围：直接返回，绝不猜一个比例发出去。
    if (!st || st.duration <= 0.0) return;
    double clamped = MAX(0.0, MIN(seconds, st.duration));
    self.progress.doubleValue = clamped / st.duration;
    [self commitSeek];
}

/// 停止播放：释放设备（与暂停不同）。走 /api/stop，与 web 版底栏同一个端点。
- (void)stopPlayback:(id)sender {
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/stop" body:nil completion:^(NSDictionary * _Nullable json) {
        (void)json;
        [weakSelf fetchStatus];
    }];
}

#pragma mark - 播放模式

// 四种模式（见 rtaweb.cpp 的 QueueState.mode）：
//   0 顺序（播到末尾停） 1 列表循环 2 单曲循环 3 随机
// 五键布局只有一个可见模式键：0 → 1 → 2 → 3 → 0。
// toggleShuffle: 仍保留原调用语义，所有入口只写 /api/playmode 一个真相源。
- (void)toggleShuffle:(id)sender {
    if (self.playMode == 3) {
        [self applyPlayMode:self.modeBeforeShuffle];
    } else {
        self.modeBeforeShuffle = self.playMode;
        [self applyPlayMode:3];
    }
}

- (void)toggleRepeat:(id)sender {
    NSInteger next = 1;
    switch (self.playMode) {
        case 0: next = 1; break;   // 顺序 → 列表循环
        case 1: next = 2; break;   // 列表循环 → 单曲循环
        case 2: next = 3; break;   // 单曲循环 → 随机
        default: next = 0; break;  // 随机 → 顺序
    }
    [self applyPlayMode:next];
}

- (void)applyPlayMode:(NSInteger)mode {
    self.playMode = mode;
    [self refreshModeButtons];
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:[NSString stringWithFormat:@"/api/playmode?mode=%ld", (long)mode]
                                body:nil
                          completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            [self_ refreshModeButtons];
        } else {
            // 失败就回读一次：别让按钮显示一个没生效的模式
            [self_ fetchStatus];
        }
    }];
}

- (void)refreshModeButtons {
    RLPTheme *t = [RLPTheme current];
    // SF Symbol 的 shuffle/repeat 只有一个形态，状态靠颜色区分
    // （与 web 版 .nav.on 的强调色同思路，不引入第二套图标资源）。
    self.shuffleBtn.contentTintColor = (self.playMode == 3) ? t.accent : t.mut;
    self.repeatBtn.contentTintColor = (self.playMode == 1 || self.playMode == 2) ? t.accent : t.mut;
    self.shuffleBtn.toolTip = (self.playMode == 3) ? RLPTr(@"随机播放（已开启）") : RLPTr(@"随机播放");
    NSString *symbol=self.playMode==3?@"shuffle":self.playMode==2?@"repeat.1":@"repeat";
    self.repeatBtn.image=[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    self.repeatBtn.contentTintColor=self.playMode==0?t.mut:t.accent;
    self.repeatBtn.toolTip=RLPTr(@[@"顺序播放",@"列表循环",@"单曲循环",@"随机播放"][self.playMode]);
}

#pragma mark - 轮询

- (void)startPolling {
    if (self.polling) return;
    if (![RLPCoreClient shared].started) return;   // 没核心就不发请求（selftest/离线安全）
    self.polling = YES;
    __weak __typeof__(self) weakSelf = self;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf fetchStatus];
    }];
    [self fetchStatus];
}

- (void)stopPolling {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    self.polling = NO;
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    // 有玻璃层时，底下的纯色改为**极淡的蒙版**（保证可读性，见文件末尾说明）；
    // 没有玻璃层（旧路径/测试构造）时保持原纯色，行为不退化。
    self.layer.backgroundColor = (self.glassEffect
        ? [t.barBg colorWithAlphaComponent:t.isLight ? 0.35 : 0.30]
        : t.barBg).CGColor;
    if (self.glassEffect) self.glassEffect.layer.cornerRadius = self.layer.cornerRadius;
    self.titleLabel.textColor = t.text;
    self.subLabel.textColor = t.mut;
    self.posLabel.textColor = t.mut;
    self.durLabel.textColor = t.mut;
    for (NSButton *b in @[self.prevBtn, self.nextBtn, self.stopBtn, self.shuffleBtn, self.repeatBtn])
        b.contentTintColor = t.text;
    self.playBtn.contentTintColor = NSColor.whiteColor;
    self.playBtn.layer.backgroundColor = t.accent.CGColor;
    self.layer.borderColor = t.line.CGColor;
    self.fmtBadge.textColor = t.accentText;
    self.fmtBadge.layer.borderColor = t.accentWeak.CGColor;
    self.fmtBadge.layer.backgroundColor = t.accentWeak.CGColor;
    if (self.fmtBadge.attributedStringValue.length == 0)
        RLPSetBadgeText(self.fmtBadge, self.fmtBadge.stringValue ?: @"--", t.accentText, 0.3);
    if (self.bpBadge.attributedStringValue.length == 0)
        RLPSetBadgeText(self.bpBadge, self.bpBadge.stringValue ?: @"", t.mut, 0.4);
    self.bpBadge.layer.borderColor = t.okLine.CGColor;   // web: 1px var(--ok-line)
    self.lyricBtn.contentTintColor = t.mut;
    self.chainBtn.contentTintColor = t.mut;
    self.volIconView.contentTintColor = t.mut;
    [self refreshModeButtons];
    [self refreshBadges];
    self.volume.needsDisplay=YES; self.progress.needsDisplay=YES;
}

- (void)refreshBadges {
    RLPTheme *t=RLPTheme.current;
    RLPPlaybackStatus *st=self.lastStatus;
    NSDictionary *d=self.statusDetails ?: @{};
    NSString *state=st.bitPerfect ?: @"", *why=st.bitPerfectWhy ?: @"";
    NSString *fallback=[d[@"fallbackWhy"] isKindOfClass:NSString.class]?d[@"fallbackWhy"]:@"";
    NSString *tip=fallback.length?[NSString stringWithFormat:@"降级原因：%@%@",fallback,(why.length && ![why isEqual:fallback])?[@"；" stringByAppendingString:why]:@""]:why;
    NSString *text=@"待播放验证"; NSColor *color=t.mut;
    if ([state isEqual:@"direct"]) { text=@"BIT-PERFECT·1bit"; color=t.bpDirect; }
    else if ([state isEqual:@"yes"]) { text=@"BIT-PERFECT"; color=t.okText; }
    else if (state.length) {
        text=@"非 bit-perfect"; color=t.warn;
        double input=[d[@"inRate"] doubleValue], output=st.outRate;
        NSString *transport=[d[@"transport"] isKindOfClass:NSString.class]?d[@"transport"]:@"";
        NSString *outMode=[d[@"outMode"] isKindOfClass:NSString.class]?d[@"outMode"]:@"";
        BOOL cast=[@[@"airplay",@"upnp"] containsObject:transport] || [@[@"airplay",@"upnp"] containsObject:outMode] || [why containsString:@"AirPlay"] || [why containsString:@"UPnP"];
        BOOL hardVeto=[why containsString:@"物理格式未锁定"] || [why containsString:@"其它程序"];
        if (!cast && [d[@"dsd"] doubleValue]>0) {
            NSString *ext=st.currentPath.pathExtension.lowercaseString;
            text=([@[@"dsf",@"dff",@"dsd",@"iso"] containsObject:ext])?@"DSD-DSD 升频":@"PCM-DSD 升频"; color=t.accent;
        } else if ((!cast || [d[@"resampled"] boolValue]) && (cast || !hardVeto) && input>0 && output>0 && input!=output) {
            text=output<input?@"PCM 降采样":@"PCM-PCM 升频";
            color=output<input?t.warn:t.accent;
        }
    }
    self.bpBadge.hidden=NO;
    self.bpBadge.textColor=color;
    RLPSetBadgeText(self.bpBadge, RLPTr(text), color, 0.4);   // web #bpBadge letter-spacing:.4px
    // web #bpBadge：bp-yes 用 --ok-line 边框 + --ok-bg 底；空态(.bp-idle) 用 --line；
    // 其余态边框跟文字同色（currentColor）。
    NSColor *border = [state length] ? ([state isEqual:@"yes"] ? t.okLine : color) : t.line;
    self.bpBadge.layer.borderColor=border.CGColor;
    self.bpBadge.layer.backgroundColor=([state isEqual:@"yes"]?t.okBg:t.hov).CGColor;
    self.bpBadge.toolTip=tip.length?tip:([state length]?RLPTr(text):RLPTr(@"当前预设已保存，但尚未播放。bit-perfect 结论只对实际播放生效"));
    self.gpuBadge.hidden=!st.gpuUsed; self.gpuBadge.textColor=t.okText;
    self.gpuBadge.layer.borderColor=t.okLine.CGColor;
    self.gpuBadge.layer.backgroundColor=t.okBg.CGColor;
    self.needsLayout=YES;
}

- (void)fetchStatus {
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/status" completion:^(NSDictionary * _Nullable json) {
        RLPPlaybackStatus *st = [RLPPlaybackStatus statusFromJSON:json];
        if (st) weakSelf.statusDetails = json;
        [weakSelf applyStatus:st];
    }];
    // 播放模式不在 /api/status 里（它属于队列，不是播放状态），必须单独读 /api/playmode。
    // 节流到每 4 次轮询（约 2 s）一次：模式是低频状态，没必要跟 500 ms 的进度一起刷。
    if (++self.modePollTick >= 4) {
        self.modePollTick = 0;
        [[RLPCoreClient shared] getJSON:@"/api/playmode" completion:^(NSDictionary * _Nullable json) {
            __typeof__(self) self_ = weakSelf;
            if (!self_) return;
            id m = json[@"mode"];
            if (![m respondsToSelector:@selector(integerValue)]) return;
            NSInteger mode = [m integerValue];
            if (mode < 0 || mode > 3) return;
            if (mode == self_.playMode) return;      // 没变就不动 UI（避免闪烁）
            self_.playMode = mode;
            [self_ refreshModeButtons];
        }];
    }
}

- (void)applyStatus:(RLPPlaybackStatus *)st {
    if (!st) return;
    self.lastStatus = st;

    // 把位置/时长广播出去：右抽屉的歌词高亮靠它（web 用同一次状态轮询驱动 syncLyrics）。
    // 用通知而不是相互持有：播放条不该知道抽屉存在。
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPPlaybackTickNotification"
        object:nil userInfo:@{ @"pos": @(st.position), @"dur": @(st.duration),
                               @"path": st.currentPath ?: @"" }];

    BOOL playing = st.playing && !st.paused;
    self.playBtn.image = [NSImage imageWithSystemSymbolName:(playing ? @"pause.fill" : @"play.fill")
                                   accessibilityDescription:RLPTr(@"播放 / 暂停")];

    NSString *name = st.currentPath.lastPathComponent;
    if (name.length == 0) name = st.playing ? RLPTr(@"未命名曲目") : RLPTr(@"未播放");
    self.titleLabel.stringValue = ([st.currentPath isEqualToString:self.metaPath] && self.metaTitle.length) ? self.metaTitle : name;

    // 副标题 = 艺术家 · 专辑（web 底栏同口径）；bit-perfect 改用独立徽标显示。
    // 错误原文（RENDERFAIL 等）只进单曲页告警条与诊断包，绝不长期占据底栏副标题
    // （旧实现 st.error 非空就顶掉副标题，用户实测「第一次播放歌曲显示这个提示」）。
    self.subLabel.textColor = [RLPTheme current].mut;
    [self refreshMetaForPath:st.currentPath];
    if (st.error.length) self.subLabel.toolTip = st.error;
    else self.subLabel.toolTip = nil;
    [self refreshBadges];
    // 封面：切歌才重新取（避免每 500ms 拉一次图）
    if (![st.currentPath isEqualToString:self.coverPath ?: @""]) {
        self.coverPath = st.currentPath;
        [self loadCoverForPath:st.currentPath];
    }

    double dur = st.duration > 0 ? st.duration : 0;
    self.posLabel.stringValue = [self mmss:st.position];
    self.durLabel.stringValue = [self mmss:dur];

    // 格式徽标：与 web #fmt 同字段同格式（44100 → "44.1k/24"；48000 → "48k/24"）。
    if (st.outRate > 0 && st.outBits > 0) {
        const double k = round(st.outRate / 100.0) / 10.0;
        NSString *kstr = (fabs(k - round(k)) < 1e-6)
            ? [NSString stringWithFormat:@"%.0fk", k]
            : [NSString stringWithFormat:@"%.1fk", k];
        RLPSetBadgeText(self.fmtBadge,
                        [NSString stringWithFormat:@"%@/%ld", kstr, (long)st.outBits],
                        [RLPTheme current].accentText, 0.3);   // web .badge letter-spacing:.3px
    } else {
        RLPSetBadgeText(self.fmtBadge, @"--", [RLPTheme current].accentText, 0.3);
    }

    if (!self.progress.dragging) {
        self.progress.doubleValue = (dur > 0) ? (st.position / dur) : 0.0;
    }
    // 音量滑块是**位置刻度 0..1000**（不是 dB），必须换算；sb 静音档 -120 也要能落回最左端。
    if (!self.volume.dragging && isfinite(st.volumeDb)) {
        self.volume.doubleValue = RLPVolDbToPos(st.volumeDb);
    }
}

/// 封面（/api/cover?file=…，与单曲页同一端点）；请求序号丢弃过期结果。
- (void)loadCoverForPath:(NSString *)path {
    if (!path.length) { ++self.coverSeq; self.coverView.image = nil; return; }
    const NSUInteger seq = ++self.coverSeq;
    NSString *url = [NSString stringWithFormat:@"/api/cover?file=%@", RLPEnc(path)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getData:url completion:^(NSData * _Nullable data) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.coverSeq) return;
        self_.coverView.image = data.length ? [[NSImage alloc] initWithData:data] : nil;
    }];
}

/// 副标题：艺术家 · 专辑（/api/meta?file=…）。同曲不重复请求。
- (void)refreshMetaForPath:(NSString *)path {
    if (!path.length) { self.metaPath=@""; self.metaTitle=@""; self.subLabel.stringValue = @"—"; return; }
    if ([path isEqualToString:self.metaPath ?: @""]) return;
    self.metaPath = path;
    self.metaTitle = @"";
    self.subLabel.stringValue = @"—";
    NSString *url = [NSString stringWithFormat:@"/api/meta?file=%@", RLPEnc(path)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || ![path isEqualToString:self_.metaPath ?: @""]) return;
        self_.metaTitle = [json[@"title"] isKindOfClass:NSString.class] ? json[@"title"] : @"";
        if (self_.metaTitle.length) self_.titleLabel.stringValue = self_.metaTitle;
        NSMutableArray<NSString *> *p = [NSMutableArray array];
        if ([json[@"artist"] isKindOfClass:[NSString class]] && [json[@"artist"] length]) [p addObject:json[@"artist"]];
        if ([json[@"album"] isKindOfClass:[NSString class]] && [json[@"album"] length]) [p addObject:json[@"album"]];
        self_.subLabel.stringValue = p.count ? [p componentsJoinedByString:@" · "] : @"—";
    }];
}

- (NSString *)mmss:(double)sec {
    if (!(sec > 0)) sec = 0;
    int s = (int)(sec + 0.5);
    return [NSString stringWithFormat:@"%d:%02d", s / 60, s % 60];
}

#pragma mark - 动作

- (void)playPause {
    if (!self.polling) return;
    RLPPlaybackStatus *st = self.lastStatus;
    // 与 web playOrPause 同一条判定（播放中→暂停 / 暂停中→继续 / 已停止→重播）：
    // 以前这里在「已停止」时只发 /api/pause?on=0，后端对停止态不会起播 ⟹ 看起来"按钮没反应"。
    RLPPlaybackToggle(st.playing, st.paused, st.currentPath);
}

- (void)pausePlayback {
    if (!self.polling) return;
    // 系统「暂停」是显式命令：不看 0.5s 轮询快照（后台 App Nap/丢请求时快照可能过期）。
    RLPPlaybackPauseExplicit();
}

- (void)resumeOrReplay {
    if (!self.polling) return;
    RLPPlaybackStatus *st = self.lastStatus;
    RLPPlaybackResumeOrReplay(st.playing, st.paused, st.currentPath);
}

- (void)nextTrack {
    if (!self.polling) return;
    [[RLPCoreClient shared] postJSON:@"/api/skip?dir=1" body:nil completion:nil];
}

- (void)previousTrack {
    if (!self.polling) return;
    [[RLPCoreClient shared] postJSON:@"/api/skip?dir=-1" body:nil completion:nil];
}

- (void)progressChanged:(id)sender {
    // 拖动期间只更新时间预览；真正的 seek 在松手（onCommit）时提交一次。
    double dur = self.lastStatus.duration;
    if (dur > 0) {
        self.posLabel.stringValue = [self mmss:self.progress.doubleValue * dur];
        self.durLabel.stringValue = [self mmss:dur];
    }
}

- (void)commitSeek {
    if (!self.polling) return;
    double frac = self.progress.doubleValue;
    if (frac < 0) frac = 0;
    if (frac > 1) frac = 1;
    // 参数名必须是 pos（不是 f）：后端读的是 rq.path.find("?pos=")，写错会被静默当成 0
    // —— 用户拖到中间松手，播放却回到开头，且后端回 ok:true 看不出错。
    NSString *path = [NSString stringWithFormat:@"/api/seek?pos=%.6f", frac];
    [[RLPCoreClient shared] postJSON:path body:nil completion:nil];
}

- (void)volumeChanged:(id)sender {
    (void)sender;
}

- (void)commitVolume {
    if (!self.polling) return;
    // 位置 → dB（web volPosToDb 同曲线）：最左端是**真静音 -120**，不是 -55/-60 的"很小声"。
    double db = RLPVolPosToDb(self.volume.doubleValue);
    if (db > 0) db = 0;
    if (db < kVolSilentDb) db = kVolSilentDb;
    NSString *path = [NSString stringWithFormat:@"/api/volume?db=%.1f", db];
    [[RLPCoreClient shared] postJSON:path body:nil completion:nil];
}

#pragma mark - 歌词 / 信号链（web 底栏同款两个图标键）

- (void)openNowPlaying:(id)sender {
    (void)sender;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenNowPlayingNotification" object:nil];
}

/// 歌词键 → 主窗口打开右抽屉并切到歌词页。
- (void)openLyricDrawer:(id)sender {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenLyricDrawerNotification" object:nil];
}

/// 底栏「信号链」：与工作台同一个 /api/signal + RLPSignalChain 纯函数，弹层逐节点列真值。
/// 不在 UI 里另算语义（bit-perfect 结论也来自后端）。
- (void)showSignalChain:(NSButton *)sender {
    RLPTheme *t = [RLPTheme current];
    NSStackView *card = [[NSStackView alloc] init];
    card.orientation = NSUserInterfaceLayoutOrientationVertical;
    card.alignment = NSLayoutAttributeLeading;
    card.spacing = 6;
    card.edgeInsets = NSEdgeInsetsMake(14, 16, 14, 16);
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [[card.widthAnchor constraintEqualToConstant:520] setActive:YES];

    NSTextField *hero = RLPLabel(RLPTr(@"读取信号链…"),
        [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], t.text);
    hero.maximumNumberOfLines = 2;
    hero.lineBreakMode = NSLineBreakByWordWrapping;
    [[hero.widthAnchor constraintEqualToConstant:488] setActive:YES];
    [card addArrangedSubview:hero];

    NSStackView *nodes = [[NSStackView alloc] init];
    nodes.orientation = NSUserInterfaceLayoutOrientationVertical;
    nodes.alignment = NSLayoutAttributeLeading;
    nodes.spacing = 4;
    nodes.translatesAutoresizingMaskIntoConstraints = NO;
    [[nodes.widthAnchor constraintEqualToConstant:488] setActive:YES];
    [card addArrangedSubview:nodes];

    NSViewController *vc = RLPCardController(card, 540, 260);
    RLPShowCardPopover(sender ?: self, vc, 540);

    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/signal" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        (void)self_;
        NSDictionary *resp = json ?: @{};
        NSString *why = nil;
        NSString *title = [RLPSignalChain heroTitleForResponse:resp why:&why];
        hero.stringValue = why.length ? [title stringByAppendingFormat:@"\n%@", why] : title;
        for (NSView *v in [nodes.arrangedSubviews copy]) {
            [nodes removeArrangedSubview:v];
            [v removeFromSuperview];
        }
        NSArray<RLPSignalNode *> *list = [RLPSignalChain nodesForResponse:resp];
        if (!list.count) {
            [nodes addArrangedSubview:RLPLabel(RLPTr(@"还没有开始播放"), [NSFont systemFontOfSize:12], t.mut)];
            return;
        }
        for (RLPSignalNode *n in list) {
            NSStackView *row = [[NSStackView alloc] init];
            row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
            row.alignment = NSLayoutAttributeTop;
            row.spacing = 8;
            NSView *dot = [[NSView alloc] initWithFrame:NSZeroRect];
            dot.wantsLayer = YES;
            dot.layer.cornerRadius = 4;
            NSColor *c = n.kind == RLPSignalNodeLossless ? t.ok
                        : (n.kind == RLPSignalNodeGpu ? t.accent : t.mut);
            dot.layer.backgroundColor = c.CGColor;
            [dot.widthAnchor constraintEqualToConstant:8].active = YES;
            [dot.heightAnchor constraintEqualToConstant:8].active = YES;
            [row addArrangedSubview:dot];
            NSStackView *txt = [[NSStackView alloc] init];
            txt.orientation = NSUserInterfaceLayoutOrientationVertical;
            txt.alignment = NSLayoutAttributeLeading;
            txt.spacing = 1;
            NSString *head = n.badge.length ? [NSString stringWithFormat:@"%@   ·   %@", n.key, n.badge] : n.key;
            NSTextField *k = RLPLabel(head, [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold], t.text);
            NSTextField *v = RLPLabel(n.value, [NSFont systemFontOfSize:11], t.text2);
            v.maximumNumberOfLines = 2;
            v.lineBreakMode = NSLineBreakByWordWrapping;
            [[v.widthAnchor constraintEqualToConstant:450] setActive:YES];
            [txt addArrangedSubview:k];
            [txt addArrangedSubview:v];
            [row addArrangedSubview:txt];
            [nodes addArrangedSubview:row];
        }
    }];
}

@end