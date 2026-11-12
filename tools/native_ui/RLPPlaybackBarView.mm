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

    // 悬浮卡片形态：边框/圆角/阴影由主窗口设置，这里不再画贴边细线。

    self.prevBtn = [self symbolButton:@"backward.fill" tip:@"上一首"];
    self.playBtn = [self symbolButton:@"play.fill" tip:@"播放 / 暂停"];
    self.nextBtn = [self symbolButton:@"forward.fill" tip:@"下一首"];
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
    self.stopBtn.target = self;
    self.stopBtn.action = @selector(stopPlayback:);
    for (NSButton *b in @[self.prevBtn, self.playBtn, self.nextBtn, self.stopBtn, self.shuffleBtn, self.repeatBtn])
        [self addSubview:b];
    self.playBtn.imageScaling = NSImageScaleProportionallyDown;
    // 红色实心圆播放键（web 底栏的视觉锚点）
    self.playBtn.wantsLayer = YES;
    self.playBtn.layer.cornerRadius = 17;
    self.playBtn.layer.backgroundColor = t.accent.CGColor;
    self.playBtn.contentTintColor = NSColor.whiteColor;
    self.playBtn.identifier = @"pb.play";

    // 封面缩略图（web 底栏最左）
    self.coverView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    self.coverView.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.coverView.wantsLayer = YES;
    self.coverView.layer.cornerRadius = 6;
    self.coverView.layer.masksToBounds = YES;
    self.coverView.layer.backgroundColor = t.bg3.CGColor;
    self.coverView.identifier = @"pb.cover";
    [self addSubview:self.coverView];

    // BIT-PERFECT 徽标（只在后端确实判定位完美时显示）
    self.bpBadge = [self labelWithFont:[NSFont systemFontOfSize:9.5 weight:NSFontWeightBold] color:t.ok];
    self.bpBadge.stringValue = @"BIT-PERFECT";
    self.bpBadge.wantsLayer = YES;
    self.bpBadge.layer.cornerRadius = 4;
    self.bpBadge.layer.borderWidth = 1;
    self.bpBadge.layer.borderColor = t.ok.CGColor;
    self.bpBadge.alignment = NSTextAlignmentCenter;
    self.bpBadge.hidden = YES;
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
    self.fmtBadge = [self labelWithFont:[NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold]
                                  color:t.accentText];
    self.fmtBadge.stringValue = @"--";
    self.fmtBadge.identifier = @"pb.fmt";
    self.fmtBadge.alignment = NSTextAlignmentCenter;
    self.fmtBadge.wantsLayer = YES;
    self.fmtBadge.layer.cornerRadius = 4;
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

/// 底栏布局：严格照 web `.bar` 的三列 grid（1.1fr / 1.6fr / 1.1fr，最大 1120，gap 14，padding 18）。
///   左列：44pt 封面 + 曲名/艺术家两行
///   中列：控制键（居中）+ 下方进度行（当前时间 / 滑杆 / 总时长）
///   右列：歌词 / 信号链 / bit-perfect / 格式 / 音量（从右往左排，放不下时按优先级隐藏——与 web 媒体查询同思路）
- (void)layout {
    [super layout];
    const CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    if (W < 400 || H < 40) return;
    void (^place)(NSView *, CGFloat, CGFloat, CGFloat, CGFloat) =
        ^(NSView *v, CGFloat x, CGFloat y, CGFloat w, CGFloat h) { v.frame = NSMakeRect(x, y, w, h); };

    const CGFloat pad = 18.0, gap = 14.0;
    CGFloat avail = W - pad * 2 - gap * 2;
    if (avail < 300) avail = 300;
    CGFloat centerW = avail * (1.6 / 3.8);
    if (centerW > 440.0) centerW = 440.0;
    const CGFloat sideW = (avail - centerW) / 2.0;
    const CGFloat leftX = pad;
    const CGFloat centerX = pad + sideW + gap;
    const CGFloat rightX = centerX + centerW + gap;

    // ── 左列：封面 44（web .cv2）+ 两行文本 ──
    place(self.coverView, leftX, (H - 44) / 2.0, 44, 44);
    const CGFloat tx = leftX + 44 + 11;
    const CGFloat tw = MAX(80.0, sideW - 44 - 11 - 8);
    place(self.titleLabel, tx, H / 2.0 + 2, tw, 17);
    place(self.subLabel, tx, H / 2.0 - 16, tw, 15);

    // ── 中列上层：六个控制键（随机 / 上一首 / 播放 / 下一首 / 停止 / 循环）──
    // 尺寸与 web 一致：普通键 32、主键 34；gap 6。整组在列内水平居中。
    const CGFloat keyGap = 6.0, small = 32.0, big = 34.0;
    const CGFloat keysW = small * 5 + big + keyGap * 5;
    CGFloat kx = centerX + (centerW - keysW) / 2.0;
    const CGFloat rowCY = H - 7.0 - 17.0;   // 上层垂直中心 = 42（H=66）
    place(self.shuffleBtn, kx, rowCY - small / 2, small, small); kx += small + keyGap;
    place(self.prevBtn,    kx, rowCY - small / 2, small, small); kx += small + keyGap;
    place(self.playBtn,    kx, rowCY - big / 2,   big,   big);   kx += big + keyGap;
    place(self.nextBtn,    kx, rowCY - small / 2, small, small); kx += small + keyGap;
    place(self.stopBtn,    kx, rowCY - small / 2, small, small); kx += small + keyGap;
    place(self.repeatBtn,  kx, rowCY - small / 2, small, small);

    // ── 中列下层：进度行（时间 / 滑杆 / 时间），贴底 7pt ──
    const CGFloat progY = 7.0, progH = 16.0, timeW = 34.0, timeGap = 8.0;
    place(self.posLabel, centerX, progY, timeW, progH);
    place(self.durLabel, centerX + centerW - timeW, progY, timeW, progH);
    const CGFloat sliderX = centerX + timeW + timeGap;
    const CGFloat sliderW = MAX(80.0, centerW - (timeW + timeGap) * 2);
    place(self.progress, sliderX, progY, sliderW, progH);

    // ── 右列：从右往左排，放不下按优先级隐藏（音量 > 歌词/信号链 > bit-perfect > 格式）──
    CGFloat rx = W - pad;                       // 当前已占用的最左缘（从右往左）
    const CGFloat volW = (sideW < 330.0) ? 76.0 : 88.0;
    rx -= volW;
    place(self.volume, rx, rowCY - 8, volW, 16);
    rx -= 8 + 14;
    place(self.volIconView, rx, rowCY - 7, 14, 14);

    const BOOL showFmt = (sideW >= 330.0);
    const BOOL showBp  = (sideW >= 292.0);
    const BOOL showIcons = (sideW >= 210.0);
    if (showFmt) {
        rx -= 8 + 50;
        place(self.fmtBadge, rx, rowCY - 9, 50, 18);
        self.fmtBadge.hidden = NO;
    } else {
        // 放不下就**真的藏起来**。之前只是"不摆放"，控件保留默认零帧留在原点，
        // 于是播放条左下角出现一个孤立的 "--" 小胶囊（实测截图里那个红点）。
        self.fmtBadge.hidden = YES;
    }
    if (showBp && !self.bpBadge.hidden) {
        rx -= 8 + 76;
        place(self.bpBadge, rx, rowCY - 9, 76, 18);
    }
    if (showIcons) {
        rx -= 8 + small;
        place(self.chainBtn, rx, rowCY - small / 2, small, small);
        rx -= 6 + small;
        place(self.lyricBtn, rx, rowCY - small / 2, small, small);
        self.chainBtn.hidden = NO;
        self.lyricBtn.hidden = NO;
    } else {
        // 用 hidden 而不是"挪到 -100 且尺寸 0"：后者仍在视图树里参与命中测试与无障碍遍历。
        self.chainBtn.hidden = YES;
        self.lyricBtn.hidden = YES;
    }
    (void)rightX;
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
// 两个按钮各管一个维度，但**写入同一个 mode**：
//   * 随机键：在「随机(3)」与「进随机前的模式」之间切；
//   * 循环键：0 → 1 → 2 → 0 轮转。
// 这样先开随机再关掉，不会丢掉用户原本选的循环方式（与 QQ 音乐/Spotify 手感一致）。
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
        case 2: next = 0; break;   // 单曲循环 → 顺序
        default: next = 1; break;  // 随机下点循环：落到列表循环（随机与循环互斥）
    }
    [self applyPlayMode:next];
}

- (void)applyPlayMode:(NSInteger)mode {
    self.playMode = mode;
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
    self.repeatBtn.toolTip = (self.playMode == 1) ? RLPTr(@"列表循环")
                           : (self.playMode == 2) ? RLPTr(@"单曲循环") : RLPTr(@"列表循环");
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
    self.layer.backgroundColor = t.barBg.CGColor;
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
    self.bpBadge.layer.borderColor = t.ok.CGColor;
    self.lyricBtn.contentTintColor = t.mut;
    self.chainBtn.contentTintColor = t.mut;
    self.volIconView.contentTintColor = t.mut;
}

- (void)fetchStatus {
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/status" completion:^(NSDictionary * _Nullable json) {
        RLPPlaybackStatus *st = [RLPPlaybackStatus statusFromJSON:json];
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
    self.titleLabel.stringValue = name;

    if (st.error.length) {
        self.subLabel.stringValue = st.error;
        self.subLabel.textColor = [RLPTheme current].danger;
    } else {
        // 副标题 = 艺术家 · 专辑（web 底栏同口径）；bit-perfect 改用独立徽标显示。
        self.subLabel.textColor = [RLPTheme current].mut;
        [self refreshMetaForPath:st.currentPath];
    }
    // BIT-PERFECT 徽标：只在后端确实判定 yes 时出现（不自己猜）
    const BOOL bpOK = [st.bitPerfect isEqualToString:@"yes"];
    if (self.bpBadge.hidden == bpOK) {
        self.bpBadge.hidden = !bpOK;
        self.bpBadge.toolTip = st.bitPerfectWhy.length ? st.bitPerfectWhy : nil;
        self.needsLayout = YES;
    }
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
        self.fmtBadge.stringValue = [NSString stringWithFormat:@"%@/%ld", kstr, (long)st.outBits];
    } else {
        self.fmtBadge.stringValue = @"--";
    self.fmtBadge.identifier = @"pb.fmt";
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
    if (!path.length) { self.coverView.image = nil; return; }
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
    if (!path.length) { self.subLabel.stringValue = @"—"; return; }
    if ([path isEqualToString:self.metaPath ?: @""]) return;
    self.metaPath = path;
    NSString *url = [NSString stringWithFormat:@"/api/meta?file=%@", RLPEnc(path)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || ![path isEqualToString:self_.metaPath ?: @""]) return;
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
    BOOL playing = self.lastStatus.playing && !self.lastStatus.paused;
    NSString *path = [NSString stringWithFormat:@"/api/pause?on=%d", playing ? 1 : 0];
    [[RLPCoreClient shared] postJSON:path body:nil completion:nil];
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