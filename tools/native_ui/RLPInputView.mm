// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPInputView.mm — 音频输入采集（CoreAudio AUHAL 输入侧）
//
// 后端契约（tools/rtaweb.cpp:11805 起，逐行核实）：
//   GET  /api/input/devices → {"ok":true,"devices":[{"id","name","channels","loopback"}]}
//   GET  /api/input/state   → {"ok":true,"running":bool,…}
//   POST /api/input/start   表单键：mode=record|monitor|null、dev、seconds、out
//        ⚠️ 后端对 device/deviceId/devid 这类形似键**显式拒绝**（防静默回落默认设备）
//        ✅ macOS 14.2+ 支持 dev=__system_loopback__ / loopback=1 系统混音回环（Process Tap）
//   POST /api/input/stop    空 body
//
// 铁律 1：本文件**绝不**自动开始采集或播放。所有采集都必须用户显式点按钮，
// 且直通监听默认关 —— 否则可能把输入直接送到用户的听音设备。
#import "RLPInputView.h"
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

@interface RLPInputView ()
@property (nonatomic, assign, readwrite) BOOL statusOnly;
@property (nonatomic, strong) NSStackView *stack;
/// 本视图自带的整页滚动（嵌入设置页时会被整根拆掉，见 setEmbeddedInPage:）。
@property (nonatomic, strong) NSScrollView *scroll;
@property (nonatomic, strong) NSArray<NSLayoutConstraint *> *scrollConstraints;
@property (nonatomic, assign) BOOL embeddedInPage;
@property (nonatomic, strong) NSPopUpButton *backend;
@property (nonatomic, strong) NSPopUpButton *device;
@property (nonatomic, strong) NSPopUpButton *mode;
@property (nonatomic, strong) NSTextField *seconds;
@property (nonatomic, strong) NSTextField *outPath;
@property (nonatomic, strong) NSButton *refreshBtn;
@property (nonatomic, strong) NSButton *startBtn;
@property (nonatomic, strong) NSButton *stopBtn;
@property (nonatomic, strong) NSTextField *status;
@property (nonatomic, strong) NSTextField *warning;
@property (nonatomic, strong) NSTextField *statHeader;
@property (nonatomic, strong) NSTextField *lbHint;
@property (nonatomic, copy) NSArray<NSDictionary *> *devices;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, strong, nullable) NSTimer *pollTimer;
@property (nonatomic, assign) BOOL pollInFlight;
@property (nonatomic, assign) BOOL hasXrunAlert;
@property (nonatomic, assign) BOOL hasClipAlert;
@property (nonatomic, assign) BOOL statusFollowsRunState;
@property (nonatomic, copy, nullable) NSDictionary *lastStateJson;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *rowLabelEntries;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *rowHintEntries;
// 采集实时状态（web sp_stat_* / sp_meter_*，1 秒轮询 /api/input/state）
@property (nonatomic, strong) NSTextField *statRunning;
@property (nonatomic, strong) NSTextField *statFrames;
@property (nonatomic, strong) NSTextField *statSpec;
@property (nonatomic, strong) NSTextField *statWater;
@property (nonatomic, strong) NSProgressIndicator *meterWater;
@property (nonatomic, strong) NSTextField *statXrun;
@property (nonatomic, strong) NSTextField *statClips;
@property (nonatomic, strong) NSTextField *statRms;
@property (nonatomic, strong) NSProgressIndicator *meterRms;
@property (nonatomic, strong) NSTextField *statPeak;
@property (nonatomic, strong) NSProgressIndicator *meterPeak;
@property (nonatomic, strong) NSTextField *statOut;
@property (nonatomic, strong) NSTextField *statErr;
@property (nonatomic, strong) NSView *statErrBox;
@end

@implementation RLPInputView

- (instancetype)initWithFrame:(NSRect)r {
    return [self initWithFrame:r statusOnly:NO];
}

- (instancetype)initStatusOnlyWithFrame:(NSRect)r {
    return [self initWithFrame:r statusOnly:YES];
}

- (instancetype)initWithFrame:(NSRect)r statusOnly:(BOOL)statusOnly {
    self = [super initWithFrame:r];
    if (self) {
        _devices = @[];
        _statusOnly = statusOnly;
        _rowLabelEntries = [NSMutableArray array];
        _rowHintEntries = [NSMutableArray array];
        [self build];
    }
    return self;
}

- (NSView *)row:(NSString *)labelKey control:(NSView *)ctl hint:(nullable NSString *)hintKey {
    RLPTheme *t = [RLPTheme current];
    NSStackView *r = [[NSStackView alloc] init];
    r.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r.alignment = NSLayoutAttributeCenterY;
    r.spacing = 10;
    NSTextField *l = RLPLabel(RLPTr(labelKey), t.body, t.text);
    l.maximumNumberOfLines = 2;
    l.lineBreakMode = NSLineBreakByWordWrapping;
    NSLayoutConstraint *lw = [l.widthAnchor constraintEqualToConstant:150];
    lw.priority = 750;
    lw.active = YES;
    [l.widthAnchor constraintLessThanOrEqualToConstant:150].active = YES;
    NSLayoutConstraint *lmin = [l.widthAnchor constraintGreaterThanOrEqualToConstant:96];
    lmin.priority = 750;
    lmin.active = YES;
    [self.rowLabelEntries addObject:@{ @"key": labelKey, @"label": l }];
    [r addArrangedSubview:l];
    [r addArrangedSubview:ctl];
    if (hintKey.length) {
        NSTextField *h = RLPLabel(RLPTr(hintKey), t.small, t.mut);
        h.maximumNumberOfLines = 2;
        h.lineBreakMode = NSLineBreakByWordWrapping;
        [h setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self.rowHintEntries addObject:@{ @"key": hintKey, @"hint": h }];
        [r addArrangedSubview:h];
    }
    return r;
}

- (void)addStackRow:(NSView *)v {
    [self.stack addArrangedSubview:v];
    [v.widthAnchor constraintLessThanOrEqualToAnchor:self.stack.widthAnchor].active = YES;
}

- (void)build {
    RLPTheme *t = [RLPTheme current];
    NSScrollView *sc = [[NSScrollView alloc] initWithFrame:self.bounds];
    sc.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    sc.drawsBackground = NO;
    sc.hasVerticalScroller = YES;
    [self addSubview:sc];
    self.scroll = sc;

    self.stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.stack.alignment = NSLayoutAttributeLeading;
    self.stack.spacing = 12;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    sc.documentView = self.stack;
    self.scrollConstraints = @[
        [self.stack.leadingAnchor constraintEqualToAnchor:sc.contentView.leadingAnchor],
        [self.stack.trailingAnchor constraintEqualToAnchor:sc.contentView.trailingAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:sc.contentView.topAnchor],
        [self.stack.widthAnchor constraintEqualToAnchor:sc.contentView.widthAnchor],
    ];
    [NSLayoutConstraint activateConstraints:self.scrollConstraints];

    if (!self.statusOnly) {
    self.backend = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.backend addItemsWithTitles:@[ @"none", @"coreaudio", @"coreaudio-shared" ]];
    self.backend.target = self;
    self.backend.action = @selector(onBackend:);
    NSLayoutConstraint *bePref = [self.backend.widthAnchor constraintEqualToConstant:220];
    bePref.priority = 750;
    bePref.active = YES;
    [self.backend setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self addStackRow:[self row:@"输入后端" control:self.backend hint:nil]];

    self.device = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.device addItemWithTitle:RLPTr(@"默认输入设备")];
    NSLayoutConstraint *devPref = [self.device.widthAnchor constraintEqualToConstant:280];
    devPref.priority = 750;
    devPref.active = YES;
    NSLayoutConstraint *devMin = [self.device.widthAnchor constraintGreaterThanOrEqualToConstant:120];
    devMin.priority = 750;
    devMin.active = YES;
    [self.device setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                        forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *devRow = (NSStackView *)[self row:@"输入设备" control:self.device hint:nil];
    self.refreshBtn = [NSButton buttonWithTitle:RLPTr(@"刷新") target:self action:@selector(onRefreshDevices:)];
    self.refreshBtn.bezelStyle = NSBezelStyleRounded;
    [devRow addArrangedSubview:self.refreshBtn];
    [self addStackRow:devRow];

    self.mode = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.mode addItemsWithTitles:@[ RLPTr(@"录制到文件"), RLPTr(@"直通监听"), RLPTr(@"空跑（不开设备）") ]];
    self.mode.target = self;
    self.mode.action = @selector(onMode:);
    NSLayoutConstraint *modePref = [self.mode.widthAnchor constraintEqualToConstant:220];
    modePref.priority = 750;
    modePref.active = YES;
    [self.mode setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                      forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self addStackRow:[self row:@"采集模式" control:self.mode hint:nil]];

    self.seconds = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.seconds.stringValue = @"0";
    NSLayoutConstraint *secPref = [self.seconds.widthAnchor constraintEqualToConstant:90];
    secPref.priority = 750;
    secPref.active = YES;
    [self addStackRow:[self row:@"时长（秒）" control:self.seconds
                                        hint:@"0 = 不限，直到手动停止"]];

    self.outPath = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.outPath.placeholderString = RLPTr(@"留空 = 自动存到 Application Support/RLPlayer/recordings");
    NSLayoutConstraint *outPref = [self.outPath.widthAnchor constraintEqualToConstant:380];
    outPref.priority = 750;
    outPref.active = YES;
    NSLayoutConstraint *outMin = [self.outPath.widthAnchor constraintGreaterThanOrEqualToConstant:140];
    outMin.priority = 750;
    outMin.active = YES;
    [self.outPath setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self addStackRow:[self row:@"输出文件" control:self.outPath hint:nil]];

    self.warning = RLPLabel(RLPTr(@"直通监听会把输入直接送到输出设备：请先确认音量，注意啸叫与回声。"),
                            t.small, t.danger);
    self.warning.maximumNumberOfLines = 0;
    self.warning.lineBreakMode = NSLineBreakByWordWrapping;
    [self.warning setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.warning.hidden = YES;   // 默认模式是录制，不显示这条
    [self addStackRow:self.warning];

    NSStackView *btns = [[NSStackView alloc] init];
    btns.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    btns.spacing = 8;
    self.startBtn = [NSButton buttonWithTitle:RLPTr(@"开始采集") target:self action:@selector(onStart:)];
    self.stopBtn = [NSButton buttonWithTitle:RLPTr(@"停止采集") target:self action:@selector(onStop:)];
    for (NSButton *b in @[ self.startBtn, self.stopBtn ]) b.bezelStyle = NSBezelStyleRounded;
    self.stopBtn.enabled = NO;
    [btns addArrangedSubview:self.startBtn];
    [btns addArrangedSubview:self.stopBtn];
    [self addStackRow:btns];

    self.status = RLPLabel(@"", t.small, t.mut);
    self.status.maximumNumberOfLines = 0;
    self.status.lineBreakMode = NSLineBreakByWordWrapping;
    [self.status setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                        forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self addStackRow:self.status];
    }   // !statusOnly

    // ---- 采集实时状态（1:1 对齐 web 的「采集实时状态」区块）----
    // 每个值都用 web 的 id；缺一个 parity 就会报缺口，所以这是清单而不是装饰。
    RLPTheme *t2 = [RLPTheme current];
    // statusOnly 时设置页的卡片头已经写了「采集实时状态」，不再重复一行小标题（实测截图里的重复头部）。
    if (!self.statusOnly) {
        self.statHeader = RLPLabel(RLPTr(@"采集实时状态"),
            [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold], t2.text);
        [self.stack addArrangedSubview:self.statHeader];
    }

    self.statRunning = RLPLabel(@"-", t2.small, t2.text);
    self.statRunning.identifier = @"sp_stat_running";
    self.statFrames = RLPLabel(@"-", t2.small, t2.text);
    self.statFrames.identifier = @"sp_stat_frames";
    self.statSpec = RLPLabel(@"-", t2.small, t2.text);
    self.statSpec.identifier = @"sp_stat_spec";
    self.statSpec.lineBreakMode = NSLineBreakByTruncatingTail;
    self.statWater = RLPLabel(@"-", t2.small, t2.text);
    self.statWater.identifier = @"sp_stat_water";
    self.statXrun = RLPLabel(@"-", t2.small, t2.text);
    self.statXrun.identifier = @"sp_stat_xrun";
    self.statClips = RLPLabel(@"-", t2.small, t2.text);
    self.statClips.identifier = @"sp_stat_clips";
    self.statRms = RLPLabel(@"-", t2.small, t2.text);
    self.statRms.identifier = @"sp_stat_rms";
    self.statPeak = RLPLabel(@"-", t2.small, t2.text);
    self.statPeak.identifier = @"sp_stat_peak";
    self.statOut = RLPLabel(@"-", t2.small, t2.mut);
    self.statOut.identifier = @"sp_stat_out";
    self.statOut.lineBreakMode = NSLineBreakByTruncatingMiddle;
    for (NSTextField *vf in @[ self.statRunning, self.statFrames, self.statSpec, self.statWater,
                               self.statXrun, self.statClips, self.statRms, self.statPeak, self.statOut ]) {
        [vf setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    }

    self.meterWater = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.meterWater.identifier = @"sp_meter_water";
    self.meterRms = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.meterRms.identifier = @"sp_meter_rms";
    self.meterPeak = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.meterPeak.identifier = @"sp_meter_peak";
    for (NSProgressIndicator *m in @[ self.meterWater, self.meterRms, self.meterPeak ]) {
        m.style = NSProgressIndicatorStyleBar;
        m.indeterminate = NO;
        m.minValue = 0;
        m.maxValue = 100;
        m.doubleValue = 0;
        NSLayoutConstraint *mw = [m.widthAnchor constraintEqualToConstant:220];
        mw.priority = 750;
        mw.active = YES;
        [m setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    }

    [self addStackRow:[self row:@"运行状态" control:self.statRunning hint:nil]];
    [self addStackRow:[self row:@"采集帧数 / 时长" control:self.statFrames hint:nil]];
    [self addStackRow:[self row:@"采样规格" control:self.statSpec hint:nil]];
    [self addStackRow:[self row:@"缓冲水位" control:self.statWater hint:nil]];
    [self addStackRow:self.meterWater];
    [self addStackRow:[self row:@"溢出 / 欠载" control:self.statXrun hint:nil]];
    [self addStackRow:[self row:@"削波计数 (正 / 负)" control:self.statClips hint:nil]];
    [self addStackRow:[self row:@"RMS 电平" control:self.statRms hint:nil]];
    [self addStackRow:self.meterRms];
    [self addStackRow:[self row:@"峰值电平" control:self.statPeak hint:nil]];
    [self addStackRow:self.meterPeak];
    [self addStackRow:[self row:@"输出文件" control:self.statOut hint:nil]];

    // 错误行：平时隐藏（web sp_stat_err_box display:none），有错误才显示
    self.statErr = RLPLabel(@"", t2.small, t2.danger);
    self.statErr.identifier = @"sp_stat_err";
    self.statErr.maximumNumberOfLines = 0;
    self.statErr.lineBreakMode = NSLineBreakByWordWrapping;
    [self.statErr setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.statErrBox = [self row:@"错误信息" control:self.statErr hint:nil];
    self.statErrBox.identifier = @"sp_stat_err_box";
    self.statErrBox.hidden = YES;
    [self addStackRow:self.statErrBox];

    self.lbHint = RLPLabel(
        RLPTr(@"选择带「回环」标记的端点可采集系统混音（需 macOS 14.2+ 与录音权限）；输出处于独占模式时无法抓取系统混音。"),
        t.small, t.mut);
    self.lbHint.maximumNumberOfLines = 0;
    self.lbHint.lineBreakMode = NSLineBreakByWordWrapping;
    [self.lbHint setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                        forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self addStackRow:self.lbHint];
}

- (void)dealloc { [self stopPolling]; }

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) [self stopPolling];
    else if ([RLPCoreClient shared].started) [self reload];
}

- (void)startPolling {
    if (self.pollTimer) return;
    __weak __typeof__(self) weakSelf = self;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer * _Nonnull t) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) { [t invalidate]; return; }
        if (!self_.window) { [self_ stopPolling]; return; }
        [self_ pollStateOnce];
    }];
}

- (void)stopPolling {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    self.pollInFlight = NO;
}

- (void)pollStateOnce {
    if (![RLPCoreClient shared].started || self.pollInFlight) return;
    self.pollInFlight = YES;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/input/state" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        self_.pollInFlight = NO;
        if (![json isKindOfClass:[NSDictionary class]]) return;
        const BOOL run = [json[@"running"] respondsToSelector:@selector(boolValue)] && [json[@"running"] boolValue];
        self_.running = run;
        self_.startBtn.enabled = !run;
        self_.stopBtn.enabled = run;
        self_.statusFollowsRunState = YES;
        self_.status.stringValue = run ? RLPTr(@"采集进行中") : RLPTr(@"未在采集");
        [self_ applyInputState:json];
        if (self_.onStateUpdated) self_.onStateUpdated(json);
        if (!run) [self_ stopPolling];
    }];
}

#pragma mark - 动作

- (void)onBackend:(id)sender {
    [self postSetting:@"inbackend" value:self.backend.titleOfSelectedItem];
}

- (void)onMode:(id)sender {
    // 只有选了直通监听才显示警示（默认录制不打扰）
    self.warning.hidden = (self.mode.indexOfSelectedItem != 1);
}

- (void)postSetting:(NSString *)key value:(NSString *)value {
    if (![RLPCoreClient shared].started || !key.length) return;
    NSString *body = [NSString stringWithFormat:@"%@=%@", key, RLPEnc(value ?: @"")];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/settings" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        self_.statusFollowsRunState = NO;
        if (json && [json[@"ok"] boolValue]) self_.status.stringValue = RLPTr(@"已保存");
        else self_.status.stringValue = [json[@"error"] isKindOfClass:[NSString class]]
            ? json[@"error"] : RLPTr(@"保存失败");
    }];
}

- (void)onRefreshDevices:(id)sender { [self loadDevices]; }

/// 开始采集。**只由用户点按钮触发**，绝不自动调用（铁律 1）。
- (void)onStart:(id)sender {
    if (![RLPCoreClient shared].started) { RLPToast(RLPTr(@"核心未启动")); return; }
    if (self.running) { RLPToast(RLPTr(@"采集已在运行中")); return; }

    NSString *modeStr = @"record";
    if (self.mode.indexOfSelectedItem == 1) modeStr = @"monitor";
    else if (self.mode.indexOfSelectedItem == 2) modeStr = @"null";

    // 直通监听要二次确认：它可能让用户的听音设备突然出声/啸叫
    if ([modeStr isEqualToString:@"monitor"]) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = RLPTr(@"开启直通监听？");
        a.informativeText = RLPTr(@"输入会被直接送到当前输出设备。请先确认音量，注意啸叫与回声。");
        a.alertStyle = NSAlertStyleWarning;
        [a addButtonWithTitle:RLPTr(@"确认开启")];
        [a addButtonWithTitle:RLPTr(@"取消")];
        if ([a runModal] != NSAlertFirstButtonReturn) return;
    }

    NSMutableString *body = [NSMutableString stringWithFormat:@"mode=%@", modeStr];
    // 键名必须是 dev：后端对 device/deviceId/devid 会显式拒绝（防静默回落默认设备）
    id ro = self.device.selectedItem.representedObject;
    NSString *devId = [ro isKindOfClass:[NSString class]] ? (NSString *)ro : @"";
    if (!devId.length) {
        const NSInteger di = self.device.indexOfSelectedItem;
        if (di > 0 && di <= (NSInteger)self.devices.count) {
            id cand = self.devices[di - 1][@"id"];
            if ([cand isKindOfClass:[NSString class]]) devId = cand;
        }
    }
    if (devId.length) [body appendFormat:@"&dev=%@", RLPEnc(devId)];
    const double secs = self.seconds.doubleValue;
    if (secs > 0) [body appendFormat:@"&seconds=%.3f", secs];
    NSString *out = [self.outPath.stringValue stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (out.length) [body appendFormat:@"&out=%@", RLPEnc(out)];

    self.statusFollowsRunState = NO;
    self.status.stringValue = RLPTr(@"正在启动采集…");
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/input/start" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"启动失败");
            self_.statusFollowsRunState = NO;
            self_.status.stringValue = err;
            RLPToast(err);
            return;
        }
        self_.running = YES;
        self_.startBtn.enabled = NO;
        self_.stopBtn.enabled = YES;
        self_.statusFollowsRunState = YES;
        self_.status.stringValue = RLPTr(@"采集进行中");
        [self_ pollStateOnce];
        if (self_.window) [self_ startPolling];
    }];
}

- (void)onStop:(id)sender {
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/input/stop" body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        self_.running = NO;
        self_.startBtn.enabled = YES;
        self_.stopBtn.enabled = NO;
        [self_ stopPolling];
        [self_ pollStateOnce];
        self_.statusFollowsRunState = NO;
        if (json && [json[@"ok"] boolValue]) self_.status.stringValue = RLPTr(@"已停止采集");
        else self_.status.stringValue = [json[@"error"] isKindOfClass:[NSString class]]
            ? json[@"error"] : RLPTr(@"停止失败");
    }];
}

#pragma mark - 数据

- (void)rebuildDeviceMenu {
    id keepRO = self.device.selectedItem.representedObject;
    NSString *keepId = [keepRO isKindOfClass:[NSString class]] ? (NSString *)keepRO : nil;
    [self.device removeAllItems];
    [self.device addItemWithTitle:RLPTr(@"默认输入设备")];
    [[self.device itemAtIndex:0] setRepresentedObject:@""];
    for (NSDictionary *d in self.devices) {
        NSString *nm = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : @"";
        if (!nm.length) continue;
        NSString *did = [d[@"id"] isKindOfClass:[NSString class]] ? d[@"id"] : @"";
        const BOOL lb = [d[@"loopback"] respondsToSelector:@selector(boolValue)] && [d[@"loopback"] boolValue];
        const BOOL isDef = [d[@"default"] respondsToSelector:@selector(boolValue)] && [d[@"default"] boolValue];
        NSString *title = nm;
        if (lb && [title rangeOfString:@"回环"].location == NSNotFound &&
            [title rangeOfString:@"Loopback" options:NSCaseInsensitiveSearch].location == NSNotFound) {
            title = [title stringByAppendingString:RLPTr(@" · 回环")];
        }
        if (isDef && [title rangeOfString:@"（默认）"].location == NSNotFound) {
            title = [title stringByAppendingString:RLPTr(@"（默认）")];
        }
        [self.device addItemWithTitle:title];
        NSMenuItem *it = [self.device itemAtIndex:self.device.numberOfItems - 1];
        if (did.length) [it setRepresentedObject:did];
    }
    if (keepId.length) {
        for (NSInteger i = 0; i < (NSInteger)self.device.numberOfItems; ++i) {
            id ro = [self.device itemAtIndex:i].representedObject;
            if ([ro isKindOfClass:[NSString class]] && [(NSString *)ro isEqualToString:keepId]) {
                [self.device selectItemAtIndex:i];
                break;
            }
        }
    }
}

- (void)loadDevices {
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/input/devices" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *arr = [json[@"devices"] isKindOfClass:[NSArray class]] ? json[@"devices"] : @[];
        NSMutableArray<NSDictionary *> *good = [NSMutableArray array];
        for (id x in arr) if ([x isKindOfClass:[NSDictionary class]]) [good addObject:x];
        self_.devices = good;
        [self_ rebuildDeviceMenu];
    }];
}

- (void)reload {
    if (![RLPCoreClient shared].started) {
        self.statusFollowsRunState = YES;
        self.status.stringValue = RLPTr(@"核心未启动");
        return;
    }
    if (!self.statusOnly) [self loadDevices];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/input/state" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        const BOOL run = [json[@"running"] respondsToSelector:@selector(boolValue)] && [json[@"running"] boolValue];
        self_.running = run;
        self_.startBtn.enabled = !run;
        self_.stopBtn.enabled = run;
        self_.statusFollowsRunState = YES;
        self_.status.stringValue = run ? RLPTr(@"采集进行中") : RLPTr(@"未在采集");
        [self_ applyInputState:json];
        if (self_.onStateUpdated) self_.onStateUpdated(json);
        if (run && self_.window) [self_ startPolling];
        else if (!run) [self_ stopPolling];
    }];
    [[RLPCoreClient shared] getJSON:@"/api/settings" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSDictionary *kv = [json[@"kv"] isKindOfClass:[NSDictionary class]] ? json[@"kv"] : nil;
        if (!kv) return;
        NSString *be = [kv[@"inbackend"] isKindOfClass:[NSString class]] ? kv[@"inbackend"] : nil;
        if (be.length && [self_.backend itemWithTitle:be]) [self_.backend selectItemWithTitle:be];
    }];
}

/// 把 /api/input/state 的真实字段铺到实时状态行上。
/// 口径与 web renderInputStats 一致：**数字全部来自后端，前端不做再计算**；
/// 不可用的指标显示 "不适用"，绝不显示 0 冒充正常。
- (void)applyInputState:(NSDictionary *)st {
    if (![st isKindOfClass:[NSDictionary class]]) return;
    self.lastStateJson = st;
    const BOOL running = [st[@"running"] respondsToSelector:@selector(boolValue)] && [st[@"running"] boolValue];

    NSString *mode = [st[@"mode"] isKindOfClass:[NSString class]] ? st[@"mode"] : @"";
    if (running) {
        self.statRunning.stringValue = [mode isEqualToString:@"monitor"] ? RLPTr(@"直通监听中")
            : [mode isEqualToString:@"null"] ? RLPTr(@"模拟源运行中") : RLPTr(@"录制中");
    } else {
        self.statRunning.stringValue = RLPTr(@"空闲");
    }

    double sec = [st[@"seconds"] respondsToSelector:@selector(doubleValue)] ? [st[@"seconds"] doubleValue] : 0;
    long frames = [st[@"frames"] respondsToSelector:@selector(longValue)] ? [st[@"frames"] longValue] : 0;
    self.statFrames.stringValue = [NSString stringWithFormat:RLPTr(@"%ld 帧 (%.1fs)"), frames, sec];

    id rate = st[@"rate"], ch = st[@"channels"], dev = st[@"device"];
    if ([rate respondsToSelector:@selector(integerValue)] && [ch respondsToSelector:@selector(integerValue)] &&
        [rate integerValue] > 0) {
        NSString *spec = [NSString stringWithFormat:@"%ld Hz / %ld %@",
                          (long)[rate integerValue], (long)[ch integerValue], RLPTr(@"声道")];
        if ([dev isKindOfClass:[NSString class]] && [dev length])
            spec = [spec stringByAppendingFormat:@" · %@", dev];
        self.statSpec.stringValue = spec;
    } else {
        self.statSpec.stringValue = ([dev isKindOfClass:[NSString class]] && [dev length]) ? dev : @"-";
    }

    double water = [st[@"water"] respondsToSelector:@selector(doubleValue)] ? [st[@"water"] doubleValue] : 0;
    water = MAX(0.0, MIN(1.0, water));
    self.statWater.stringValue = [NSString stringWithFormat:@"%.1f%%", water * 100.0];
    self.meterWater.doubleValue = water * 100.0;

    long ovf = [st[@"overflow"] respondsToSelector:@selector(longValue)] ? [st[@"overflow"] longValue] : 0;
    long unf = [st[@"underflow"] respondsToSelector:@selector(longValue)] ? [st[@"underflow"] longValue] : 0;
    self.hasXrunAlert = (ovf > 0 || unf > 0);
    self.statXrun.stringValue = [NSString stringWithFormat:RLPTr(@"溢出 %ld / 欠载 %ld"), ovf, unf];
    self.statXrun.textColor = self.hasXrunAlert ? [RLPTheme current].danger : [RLPTheme current].text;

    long pos = [st[@"posClips"] respondsToSelector:@selector(longValue)] ? [st[@"posClips"] longValue] : 0;
    long neg = [st[@"negClips"] respondsToSelector:@selector(longValue)] ? [st[@"negClips"] longValue] : 0;
    self.hasClipAlert = (pos > 0 || neg > 0);
    self.statClips.stringValue = [NSString stringWithFormat:@"+%ld / -%ld", pos, neg];
    self.statClips.textColor = self.hasClipAlert ? [RLPTheme current].danger : [RLPTheme current].text;

    // 电平：后端给 dBFS；-inf 或缺失显示 -∞，条按 -60..0 dB 线性映射
    double rms = [st[@"rmsDb"] respondsToSelector:@selector(doubleValue)] ? [st[@"rmsDb"] doubleValue] : -INFINITY;
    double peak = [st[@"peakDb"] respondsToSelector:@selector(doubleValue)] ? [st[@"peakDb"] doubleValue] : -INFINITY;
    self.statRms.stringValue = isfinite(rms) ? [NSString stringWithFormat:@"%.1f dBFS", rms] : RLPTr(@"-∞ dBFS");
    self.statPeak.stringValue = isfinite(peak) ? [NSString stringWithFormat:@"%.1f dBFS", peak] : RLPTr(@"-∞ dBFS");
    self.meterRms.doubleValue = isfinite(rms) ? MAX(0.0, MIN(100.0, (rms + 60.0) / 60.0 * 100.0)) : 0;
    self.meterPeak.doubleValue = isfinite(peak) ? MAX(0.0, MIN(100.0, (peak + 60.0) / 60.0 * 100.0)) : 0;

    NSString *outFile = [st[@"outFile"] isKindOfClass:[NSString class]] ? st[@"outFile"] : nil;
    self.statOut.stringValue = outFile.length ? outFile : @"-";

    NSString *err = [st[@"error"] isKindOfClass:[NSString class]] ? st[@"error"] : nil;
    self.statErr.stringValue = err.length ? err : @"";
    if (self.statErrBox) self.statErrBox.hidden = (err.length == 0);
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.status.textColor = t.mut;
    self.warning.textColor = t.danger;
    self.statHeader.textColor = t.text;
    self.lbHint.textColor = t.mut;
    for (NSDictionary *entry in self.rowLabelEntries) {
        NSTextField *lbl = entry[@"label"];
        lbl.textColor = t.text;
    }
    for (NSDictionary *entry in self.rowHintEntries) {
        NSTextField *hint = entry[@"hint"];
        hint.textColor = t.mut;
    }
    for (NSTextField *vf in @[ self.statRunning, self.statFrames, self.statSpec,
                               self.statWater, self.statRms, self.statPeak ]) {
        vf.textColor = t.text;
    }
    self.statXrun.textColor = self.hasXrunAlert ? t.danger : t.text;
    self.statClips.textColor = self.hasClipAlert ? t.danger : t.text;
    self.statOut.textColor = t.mut;
    self.statErr.textColor = t.danger;
}

- (void)applyLanguage {
    for (NSDictionary *entry in self.rowLabelEntries) {
        NSString *key = entry[@"key"];
        NSTextField *lbl = entry[@"label"];
        lbl.stringValue = RLPTr(key);
    }
    for (NSDictionary *entry in self.rowHintEntries) {
        NSString *key = entry[@"key"];
        NSTextField *hint = entry[@"hint"];
        hint.stringValue = RLPTr(key);
    }
    if (!self.statusOnly) {
        self.refreshBtn.title = RLPTr(@"刷新");
        [self rebuildDeviceMenu];
        if (self.mode.numberOfItems >= 3) {
            [self.mode itemAtIndex:0].title = RLPTr(@"录制到文件");
            [self.mode itemAtIndex:1].title = RLPTr(@"直通监听");
            [self.mode itemAtIndex:2].title = RLPTr(@"空跑（不开设备）");
        }
        self.outPath.placeholderString = RLPTr(@"留空 = 自动存到 Application Support/RLPlayer/recordings");
        self.warning.stringValue = RLPTr(@"直通监听会把输入直接送到输出设备：请先确认音量，注意啸叫与回声。");
        self.startBtn.title = RLPTr(@"开始采集");
        self.stopBtn.title = RLPTr(@"停止采集");
        self.statHeader.stringValue = RLPTr(@"采集实时状态");
        if (self.statusFollowsRunState) {
            if (![RLPCoreClient shared].started) {
                self.status.stringValue = RLPTr(@"核心未启动");
            } else {
                self.status.stringValue = self.running ? RLPTr(@"采集进行中") : RLPTr(@"未在采集");
            }
        }
    }
    self.lbHint.stringValue = RLPTr(@"选择带「回环」标记的端点可采集系统混音（需 macOS 14.2+ 与录音权限）；输出处于独占模式时无法抓取系统混音。");
    if (self.lastStateJson) {
        [self applyInputState:self.lastStateJson];
    }
}

#pragma mark - 嵌入整页滚动的宿主（去掉本视图自己的滚动）

- (void)setEmbeddedInPage:(BOOL)embedded {
    if (_embeddedInPage == embedded) return;
    _embeddedInPage = embedded;
    if (!embedded || !self.scroll) return;
    // 拆掉内层 NSScrollView：stack 直接铺在本视图里，滚动交给设置页那根整页滚动条。
    // 不拆的话，滚轮停在「采集实时状态」上会被这里吃掉，整页滚不动
    // （用户 2026-11-15：每个界面只允许整页滚动，禁止页面中的小页面滚动）。
    [NSLayoutConstraint deactivateConstraints:self.scrollConstraints];
    self.scrollConstraints = @[];
    [self.scroll removeFromSuperview];
    self.scroll = nil;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:self.stack];
    NSLayoutConstraint *bottomEq = [self.stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor];
    bottomEq.priority = NSLayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [self.stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:self.topAnchor],
        bottomEq,
    ]];
}

- (CGFloat)preferredContentHeight {
    CGFloat total = self.stack.edgeInsets.top + self.stack.edgeInsets.bottom;
    NSInteger n = 0;
    for (NSView *v in self.stack.arrangedSubviews) {
        if (v.hidden) continue;
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
