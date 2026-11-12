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
@property (nonatomic, strong) NSTextField *timeLabel;
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
    self.playBtn.layer.cornerRadius = 20;
    self.playBtn.layer.backgroundColor = t.accent.CGColor;
    self.playBtn.contentTintColor = NSColor.whiteColor;

    // 封面缩略图（web 底栏最左）
    self.coverView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    self.coverView.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.coverView.wantsLayer = YES;
    self.coverView.layer.cornerRadius = 6;
    self.coverView.layer.masksToBounds = YES;
    self.coverView.layer.backgroundColor = t.bg3.CGColor;
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
    self.titleLabel.stringValue = RLPTr(@"未播放");
    self.subLabel = [self labelWithFont:t.small color:t.mut];
    self.subLabel.stringValue = @"—";
    self.timeLabel = [self labelWithFont:t.mono color:t.mut];
    self.timeLabel.stringValue = @"0:00 / 0:00";

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

    NSImage *volIcon = [NSImage imageWithSystemSymbolName:@"speaker.wave.2"
                                 accessibilityDescription:@"音量"];
    NSImageView *volView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    volView.image = volIcon;
    volView.contentTintColor = t.mut;
    volView.translatesAutoresizingMaskIntoConstraints = NO;
    self.volIconView = volView;

    self.volume = [[RLPCommitSlider alloc] initWithFrame:NSZeroRect];
    self.volume.minValue = -60.0;
    self.volume.maxValue = 0.0;
    self.volume.doubleValue = -12.0;
    self.volume.continuous = YES;
    self.volume.controlSize = NSControlSizeSmall;
    self.volume.target = self;
    self.volume.action = @selector(volumeChanged:);
    self.volume.onCommit = ^{ [weakSelf commitVolume]; };

    for (NSView *v in @[self.titleLabel, self.subLabel, self.timeLabel, self.progress, volView, self.volume]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:v];
    }

    // 内部不用 Auto Layout：固定 66px 高的悬浮条，手动布局最稳
    // （约束方案在本机出现过控制键被挤出卡片的问题，见 layoutSubviews）。
}

/// 手动布局（66px 悬浮条）：左=曲目信息，**中=控制键（真居中）**，右=时间+音量，
/// 进度条作为细线贴底贯穿（图三要求：比例协调、不再压着按钮）。
- (void)layout {
    [super layout];
    const CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    if (W < 400 || H < 40) return;
    const CGFloat cy = H / 2.0;
    void (^place)(NSView *, CGFloat, CGFloat, CGFloat, CGFloat) =
        ^(NSView *v, CGFloat x, CGFloat y, CGFloat w, CGFloat h) { v.frame = NSMakeRect(x, y, w, h); };

    // 左：封面 + 标题/副标题
    place(self.coverView, 14, cy - 21, 42, 42);
    place(self.titleLabel, 66, cy - 16, 180, 18);
    place(self.subLabel, 66, cy + 2, 180, 14);

    // 中：控制键一组**按窗口宽度居中**（旧实现从 x=250 硬编码起排 ⟹ 宽窗口下整组偏左，
    // 用户实测「播放条的比例也不对」的直接原因）。
    const CGFloat keyW = 24 + 8 + 28 + 6 + 44 + 6 + 28 + 8 + 24 + 8 + 24;  // 合计
    CGFloat x = (W - keyW) / 2.0;
    if (x < 250) x = 250;   // 窄窗口时给左侧信息区让位
    const CGFloat ccy = cy - 3;   // 略上移，给贴底进度条留呼吸
    place(self.shuffleBtn, x, ccy - 12, 24, 24); x += 24 + 8;
    place(self.prevBtn,   x, ccy - 14, 28, 28); x += 28 + 6;
    place(self.playBtn,   x, ccy - 22, 44, 44); x += 44 + 6;
    place(self.nextBtn,   x, ccy - 14, 28, 28); x += 28 + 8;
    place(self.stopBtn,   x, ccy - 12, 24, 24); x += 24 + 8;
    place(self.repeatBtn, x, ccy - 12, 24, 24);

    // 右：时间 + 音量图标 + 音量条（BIT-PERFECT 徽标在时间左侧）
    const CGFloat badgeW = self.bpBadge.hidden ? 0 : 84;
    place(self.volume, W - 16 - 96, cy - 8, 96, 14);
    place(self.volIconView, W - 16 - 96 - 8 - 16, cy - 8, 16, 16);
    place(self.timeLabel, W - 16 - 96 - 8 - 16 - 8 - 92, cy - 8, 92, 16);
    if (!self.bpBadge.hidden)
        place(self.bpBadge, W - 16 - 96 - 8 - 16 - 8 - 92 - 10 - badgeW, cy - 9, badgeW, 18);

    // 进度条：控制键下方的独立一条，**给足高度**（8pt 细线贴底边既看不见也拖不动；
    // 目标图里它是明显的可拖动滑杆）。左右与信息区/音量区对齐。
    const CGFloat progL = 66 + 180 + 20;
    const CGFloat progR = W - 16 - 96 - 8 - 16 - 12;
    place(self.progress, progL, 6, MAX(120, progR - progL), 18);
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
    self.timeLabel.textColor = t.mut;
    for (NSButton *b in @[self.prevBtn, self.nextBtn, self.stopBtn, self.shuffleBtn, self.repeatBtn])
        b.contentTintColor = t.text;
    self.playBtn.contentTintColor = NSColor.whiteColor;
    self.playBtn.layer.backgroundColor = t.accent.CGColor;
    self.layer.borderColor = t.line.CGColor;
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
    self.timeLabel.stringValue = [NSString stringWithFormat:@"%@ / %@",
        [self mmss:st.position], [self mmss:dur]];

    if (!self.progress.dragging) {
        self.progress.doubleValue = (dur > 0) ? (st.position / dur) : 0.0;
    }
    if (!self.volume.dragging && st.volumeDb <= 0.0 && st.volumeDb >= -60.0) {
        self.volume.doubleValue = st.volumeDb;
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
        self.timeLabel.stringValue = [NSString stringWithFormat:@"%@ / %@",
            [self mmss:self.progress.doubleValue * dur], [self mmss:dur]];
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
    double db = self.volume.doubleValue;
    if (db > 0) db = 0;
    if (db < -60) db = -60;
    NSString *path = [NSString stringWithFormat:@"/api/volume?db=%.1f", db];
    [[RLPCoreClient shared] postJSON:path body:nil completion:nil];
}

@end