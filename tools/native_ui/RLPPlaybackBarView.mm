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
    for (NSButton *b in @[self.prevBtn, self.playBtn, self.nextBtn]) [self addSubview:b];
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

        // 右：音量图标 + 音量条
        [self.volume.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [self.volume.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.volume.widthAnchor constraintEqualToConstant:96],
        [volView.trailingAnchor constraintEqualToAnchor:self.volume.leadingAnchor constant:-8],
        [volView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [volView.widthAnchor constraintEqualToConstant:16],
        [volView.heightAnchor constraintEqualToConstant:16],

        // 中：标题 / 副标题 / 进度
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.nextBtn.trailingAnchor constant:18],
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

- (void)fetchStatus {
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/status" completion:^(NSDictionary * _Nullable json) {
        RLPPlaybackStatus *st = [RLPPlaybackStatus statusFromJSON:json];
        [weakSelf applyStatus:st];
    }];
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
    NSString *path = [NSString stringWithFormat:@"/api/seek?f=%.4f", frac];
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
