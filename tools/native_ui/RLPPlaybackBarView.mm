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

    NSView *hair = [[NSView alloc] initWithFrame:NSZeroRect];
    hair.wantsLayer = YES;
    hair.layer.backgroundColor = t.line.CGColor;
    hair.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:hair];

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

    self.titleLabel = [self labelWithFont:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]
                                    color:t.text];
    self.titleLabel.stringValue = @"未播放";
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

    [NSLayoutConstraint activateConstraints:@[
        // 顶部 1px 分隔线
        [hair.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [hair.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [hair.topAnchor constraintEqualToAnchor:self.topAnchor],
        [hair.heightAnchor constraintEqualToConstant:1],

        // 左：上一首 / 播放 / 下一首
        [self.prevBtn.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [self.prevBtn.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.prevBtn.widthAnchor constraintEqualToConstant:30],
        [self.prevBtn.heightAnchor constraintEqualToConstant:30],
        [self.playBtn.leadingAnchor constraintEqualToAnchor:self.prevBtn.trailingAnchor constant:4],
        [self.playBtn.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.playBtn.widthAnchor constraintEqualToConstant:34],
        [self.playBtn.heightAnchor constraintEqualToConstant:34],
        [self.nextBtn.leadingAnchor constraintEqualToAnchor:self.playBtn.trailingAnchor constant:4],
        [self.nextBtn.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.nextBtn.widthAnchor constraintEqualToConstant:30],
        [self.nextBtn.heightAnchor constraintEqualToConstant:30],
        [self.stopBtn.leadingAnchor constraintEqualToAnchor:self.nextBtn.trailingAnchor constant:8],
        [self.stopBtn.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.stopBtn.widthAnchor constraintEqualToConstant:26],
        [self.stopBtn.heightAnchor constraintEqualToConstant:26],
        [self.shuffleBtn.leadingAnchor constraintEqualToAnchor:self.stopBtn.trailingAnchor constant:10],
        [self.shuffleBtn.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.shuffleBtn.widthAnchor constraintEqualToConstant:26],
        [self.shuffleBtn.heightAnchor constraintEqualToConstant:26],
        [self.repeatBtn.leadingAnchor constraintEqualToAnchor:self.shuffleBtn.trailingAnchor constant:2],
        [self.repeatBtn.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.repeatBtn.widthAnchor constraintEqualToConstant:26],
        [self.repeatBtn.heightAnchor constraintEqualToConstant:26],

        // 右：音量图标 + 音量条
        [self.volume.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [self.volume.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.volume.widthAnchor constraintEqualToConstant:96],
        [volView.trailingAnchor constraintEqualToAnchor:self.volume.leadingAnchor constant:-8],
        [volView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [volView.widthAnchor constraintEqualToConstant:16],
        [volView.heightAnchor constraintEqualToConstant:16],

        // 中：标题 / 副标题 / 进度
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.repeatBtn.trailingAnchor constant:18],
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:14],
        [self.subLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.subLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2],
        [self.subLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.timeLabel.leadingAnchor constant:-12],

        [self.timeLabel.trailingAnchor constraintEqualToAnchor:volView.leadingAnchor constant:-14],
        [self.timeLabel.centerYAnchor constraintEqualToAnchor:self.titleLabel.centerYAnchor],
        [self.timeLabel.widthAnchor constraintEqualToConstant:88],

        [self.progress.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.progress.trailingAnchor constraintEqualToAnchor:self.timeLabel.trailingAnchor],
        [self.progress.topAnchor constraintEqualToAnchor:self.subLabel.bottomAnchor constant:4],
        [self.progress.heightAnchor constraintEqualToConstant:16],
    ]];
}

/// 首次显示时按默认模式（顺序）着色，避免两个按钮都是灰的看不出来。
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) [self refreshModeButtons];
}

- (NSButton *)symbolButton:(NSString *)symbol tip:(NSString *)tip {
    NSButton *b = [[NSButton alloc] initWithFrame:NSZeroRect];
    b.bordered = NO;
    b.imagePosition = NSImageOnly;
    b.imageScaling = NSImageScaleProportionallyDown;
    b.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip];
    b.contentTintColor = [RLPTheme current].text;
    b.toolTip = tip;
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
    for (NSButton *b in @[self.prevBtn, self.playBtn, self.nextBtn]) b.contentTintColor = t.text;
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
                                   accessibilityDescription:@"播放 / 暂停"];

    NSString *name = st.currentPath.lastPathComponent;
    if (name.length == 0) name = st.playing ? @"未命名曲目" : @"未播放";
    self.titleLabel.stringValue = name;

    if (st.error.length) {
        self.subLabel.stringValue = st.error;
        self.subLabel.textColor = [RLPTheme current].danger;
    } else {
        NSString *bp = [st.bitPerfect isEqualToString:@"yes"] ? @"bit-perfect" : @"—";
        self.subLabel.stringValue = bp;
        self.subLabel.textColor = [RLPTheme current].mut;
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