// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPCastView.mm — 推送到设备（UPnP / DLNA），对齐 web 设置·流媒体页的投放区块
//
// 后端契约（tools/rtaweb.cpp，逐行核实）：
//   GET  /api/cast/devices  → {"ok":true,"devices":[…],"hint":"…"}（web 用这个；?scan=1 强制重扫）
//   GET  /api/cast/state    → {"ok":true,"running":bool,"device":…,…, phase/pos/transport/…}
//   POST /api/cast/start    表单键 **dev**（不是 device）
//   POST /api/cast/stop     空 body
//
// 控件 identifier 就是 web 的 id（sp_cast_*），parity 表据此机械核对 —— 名字一致
// 才能证明"web 的投放面板原生也有"，而不是另做了一套相似的东西。
//
// 纪律：
//   * 绝不自动发起投放（会让用户设备出声，违反铁律 1）——只由用户点按钮。
//   * 核心未启动时不发请求、不启动轮询（selftest 会断言）。
#import "RLPCastView.h"
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

@interface RLPCastView ()
@property (nonatomic, strong) NSStackView *stack;
@property (nonatomic, strong) NSPopUpButton *devicePop;
@property (nonatomic, strong) NSButton *scanBtn;
@property (nonatomic, strong) NSTextField *devMsg;
@property (nonatomic, strong) NSButton *pushBtn;
@property (nonatomic, strong) NSButton *stopBtn;
@property (nonatomic, strong) NSTextField *msg;
/// 投放升频三件套（web cast_up / cast_ceil / cast_force）
@property (nonatomic, strong) NSSwitch *upSwitch;
@property (nonatomic, strong) NSTextField *upLabel;
@property (nonatomic, strong) NSPopUpButton *upCeilPopup;
@property (nonatomic, strong) NSSwitch *upForceSwitch;
@property (nonatomic, strong) NSTextField *forceLabel;
@property (nonatomic, strong) NSTextField *upInfo;
/// 实时状态（web sp_cast_stat_*）
@property (nonatomic, strong) NSTextField *statPhase;
@property (nonatomic, strong) NSTextField *statDev;
@property (nonatomic, strong) NSTextField *statPos;
@property (nonatomic, strong) NSTextField *statTransport;
@property (nonatomic, strong) NSTextField *statBytes;
@property (nonatomic, strong) NSTextField *statReqs;
@property (nonatomic, strong) NSTextField *statPort;
@property (nonatomic, strong) NSTextField *statRateMatch;
@property (nonatomic, strong) NSTextField *statPrep;
@property (nonatomic, strong) NSTextField *statWarn;
@property (nonatomic, strong) NSTextField *statErr;
@property (nonatomic, strong) NSView *prepBox;
@property (nonatomic, strong) NSView *warnBox;
@property (nonatomic, strong) NSView *errBox;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *statLabelEntries;
@property (nonatomic, strong) NSTimer *poll;
@property (nonatomic, assign, readwrite) BOOL polling;
@property (nonatomic, copy) NSArray<NSDictionary *> *devices;
@property (nonatomic, copy) NSString *savedUpnpDev;
@property (nonatomic, copy, nullable) NSDictionary *lastSettingsJson;
@property (nonatomic, copy, nullable) NSDictionary *lastDevicesJson;
@property (nonatomic, copy, nullable) NSDictionary *lastStateJson;
@end

@implementation RLPCastView

- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    if (self) {
        _devices = @[];
        _savedUpnpDev = @"";
        _statLabelEntries = [NSMutableArray array];
        [self build];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onExternalSettingsChanged:)
                                                     name:RLPSettingsChangedNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopPolling];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) [self stopPolling];
    else if ([RLPCoreClient shared].started) [self reload];
}

- (void)onExternalSettingsChanged:(NSNotification *)note {
    if (note.object == self) return;
    if (![RLPCoreClient shared].started) return;
    [self reloadSettings];
}

/// 一行「标签 : 值」，值控件带 web 的 identifier。
- (NSStackView *)statRow:(NSString *)labelKey value:(NSTextField *)value t:(RLPTheme *)t {
    NSStackView *row = [[NSStackView alloc] init];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeTop;
    row.spacing = 8;
    NSTextField *l = RLPLabel(RLPTr(labelKey), t.small, t.mut);
    l.maximumNumberOfLines = 2;
    l.lineBreakMode = NSLineBreakByWordWrapping;
    NSLayoutConstraint *lw = [l.widthAnchor constraintEqualToConstant:130];
    lw.priority = 750;
    lw.active = YES;
    [l.widthAnchor constraintLessThanOrEqualToConstant:130].active = YES;
    NSLayoutConstraint *lmin = [l.widthAnchor constraintGreaterThanOrEqualToConstant:88];
    lmin.priority = 750;
    lmin.active = YES;
    [self.statLabelEntries addObject:@{ @"key": labelKey, @"label": l }];
    [row addArrangedSubview:l];
    [row addArrangedSubview:value];
    return row;
}

- (NSTextField *)statValue:(NSString *)identifier t:(RLPTheme *)t {
    NSTextField *f = RLPLabel(@"-", t.small, t.text);
    f.identifier = identifier;
    f.maximumNumberOfLines = 0;
    f.lineBreakMode = NSLineBreakByWordWrapping;
    [f setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSLayoutConstraint *fw = [f.widthAnchor constraintEqualToConstant:300];
    fw.priority = 250;
    fw.active = YES;
    return f;
}

- (void)build {
    RLPTheme *t = [RLPTheme current];
    self.stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    self.stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.stack.alignment = NSLayoutAttributeLeading;
    self.stack.spacing = 10;
    [self addSubview:self.stack];
    NSLayoutConstraint *bottomEq = [self.stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor];
    bottomEq.priority = NSLayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [self.stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:self.topAnchor],
        bottomEq,
    ]];

    // ---- 设备选择 + 重新发现（web sp_cast_dev / sp_cast_scan / sp_cast_devmsg）----
    NSStackView *r1 = [[NSStackView alloc] init];
    r1.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r1.spacing = 8;
    self.devicePop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.devicePop.identifier = @"sp_cast_dev";
    [self.devicePop addItemWithTitle:RLPTr(@"（未发现 UPnP 渲染器）")];
    [[self.devicePop lastItem] setRepresentedObject:@""];
    self.devicePop.target = self;
    self.devicePop.action = @selector(onDeviceChanged:);
    [self.devicePop setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                             forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSLayoutConstraint *devPref = [self.devicePop.widthAnchor constraintEqualToConstant:360];
    devPref.priority = 750;
    devPref.active = YES;
    [self.devicePop.widthAnchor constraintLessThanOrEqualToConstant:360].active = YES;
    NSLayoutConstraint *devMin = [self.devicePop.widthAnchor constraintGreaterThanOrEqualToConstant:140];
    devMin.priority = 750;
    devMin.active = YES;
    [r1 addArrangedSubview:self.devicePop];
    self.scanBtn = [NSButton buttonWithTitle:RLPTr(@"重新发现") target:self action:@selector(onRefresh:)];
    self.scanBtn.bezelStyle = NSBezelStyleRounded;
    self.scanBtn.identifier = @"sp_cast_scan";
    [r1 addArrangedSubview:self.scanBtn];
    [self.stack addArrangedSubview:r1];
    [r1.widthAnchor constraintLessThanOrEqualToAnchor:self.stack.widthAnchor].active = YES;

    self.devMsg = RLPLabel(RLPTr(@"点「重新发现」扫描局域网里的 MediaRenderer"), t.small, t.mut);
    self.devMsg.identifier = @"sp_cast_devmsg";
    self.devMsg.maximumNumberOfLines = 0;
    self.devMsg.lineBreakMode = NSLineBreakByWordWrapping;
    [self.devMsg setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                          forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.stack addArrangedSubview:self.devMsg];
    [self.devMsg.widthAnchor constraintLessThanOrEqualToAnchor:self.stack.widthAnchor].active = YES;

    // ---- 投放升频（web cast_up / cast_ceil / cast_force / cast_up_info）----
    self.upSwitch = [[NSSwitch alloc] initWithFrame:NSZeroRect];
    self.upSwitch.identifier = @"cast_up";
    // 旧实现是只读镜像，所以从来没绑过 target/action。现在它是真开关，
    // 不绑就等于画一个永远点不动的控件（而 UI 还显示成可点）—— 那是欺骗。
    self.upSwitch.target = self;
    self.upSwitch.action = @selector(onCastUpsample:);
    self.upSwitch.enabled = NO;
    self.upSwitch.toolTip = RLPTr(@"勾选后投放按上限与设备声明能力升频（独立于全局播放方式）");
    NSStackView *upRow = [[NSStackView alloc] init];
    upRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    upRow.spacing = 8;
    [upRow addArrangedSubview:self.upSwitch];
    self.upLabel = RLPLabel(RLPTr(@"投放升频"), t.small, t.text);
    self.upLabel.maximumNumberOfLines = 2;
    self.upLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [self.upLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                           forOrientation:NSLayoutConstraintOrientationHorizontal];
    [upRow addArrangedSubview:self.upLabel];
    [self.stack addArrangedSubview:upRow];
    [upRow.widthAnchor constraintLessThanOrEqualToAnchor:self.stack.widthAnchor].active = YES;

    self.upCeilPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.upCeilPopup.identifier = @"cast_ceil";
    // 第一项 `auto` = 不设额外天花板，直接跟随 UPnP 渲染器声明的最高速率。
    // 2026-11-21（用户原话：「那个数值不应该根据 UPnP 的源自动变动吗」）：
    // 旧版只有四个写死的绝对档位（默认 96000/192000），设备明明声明到 192k，
    // 手填的上限却可能把它压住，导致"能升却不升"。现在默认 auto。
    // 选具体档位时仍当硬天花板（用户显式意愿优先）。
    [self.upCeilPopup removeAllItems];
    [self.upCeilPopup addItemWithTitle:RLPTr(@"自动（跟随设备）")];
    [[self.upCeilPopup lastItem] setRepresentedObject:@"auto"];
    for (NSString *v in @[ @"96000", @"192000", @"384000", @"768000" ]) {
        [self.upCeilPopup addItemWithTitle:v];
        [[self.upCeilPopup lastItem] setRepresentedObject:v];
    }
    self.upCeilPopup.target = self;
    self.upCeilPopup.action = @selector(onCastCeiling:);
    NSLayoutConstraint *ceilPref = [self.upCeilPopup.widthAnchor constraintEqualToConstant:160];
    ceilPref.priority = 750;
    ceilPref.active = YES;
    [self.stack addArrangedSubview:self.upCeilPopup];
    [self.upCeilPopup.widthAnchor constraintLessThanOrEqualToAnchor:self.stack.widthAnchor].active = YES;

    self.upForceSwitch = [[NSSwitch alloc] initWithFrame:NSZeroRect];
    self.upForceSwitch.identifier = @"cast_force";
    self.upForceSwitch.target = self;
    self.upForceSwitch.action = @selector(onCastForce:);
    NSStackView *forceRow = [[NSStackView alloc] init];
    forceRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    forceRow.spacing = 8;
    [forceRow addArrangedSubview:self.upForceSwitch];
    self.forceLabel = RLPLabel(RLPTr(@"强制目标率（忽略渲染器声明）"), t.small, t.text);
    self.forceLabel.maximumNumberOfLines = 2;
    self.forceLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [self.forceLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                              forOrientation:NSLayoutConstraintOrientationHorizontal];
    [forceRow addArrangedSubview:self.forceLabel];
    [self.stack addArrangedSubview:forceRow];
    [forceRow.widthAnchor constraintLessThanOrEqualToAnchor:self.stack.widthAnchor].active = YES;

    self.upInfo = RLPLabel(RLPTr(@"跟随播放方式（加载设置后同步）"), t.small, t.mut);
    self.upInfo.identifier = @"sp_cast_up_info";
    self.upInfo.maximumNumberOfLines = 0;
    self.upInfo.lineBreakMode = NSLineBreakByWordWrapping;
    [self.upInfo setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                          forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.stack addArrangedSubview:self.upInfo];
    [self.upInfo.widthAnchor constraintLessThanOrEqualToAnchor:self.stack.widthAnchor].active = YES;

    // ---- 推送 / 停止 / 消息（web sp_cast_push / sp_cast_stop / sp_cast_msg）----
    NSStackView *r2 = [[NSStackView alloc] init];
    r2.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r2.spacing = 8;
    self.pushBtn = [NSButton buttonWithTitle:RLPTr(@"推送当前曲") target:self action:@selector(onPush:)];
    self.pushBtn.bezelStyle = NSBezelStyleRounded;
    self.pushBtn.identifier = @"sp_cast_push";
    self.stopBtn = [NSButton buttonWithTitle:RLPTr(@"停止投放") target:self action:@selector(onStop:)];
    self.stopBtn.bezelStyle = NSBezelStyleRounded;
    self.stopBtn.identifier = @"sp_cast_stop";
    self.stopBtn.enabled = NO;
    self.msg = RLPLabel(@"", t.small, t.mut);
    self.msg.identifier = @"sp_cast_msg";
    self.msg.maximumNumberOfLines = 2;
    self.msg.lineBreakMode = NSLineBreakByWordWrapping;
    [self.msg setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    [r2 addArrangedSubview:self.pushBtn];
    [r2 addArrangedSubview:self.stopBtn];
    [r2 addArrangedSubview:self.msg];
    [self.stack addArrangedSubview:r2];
    [r2.widthAnchor constraintLessThanOrEqualToAnchor:self.stack.widthAnchor].active = YES;

    // ---- 实时状态（web sp_cast_stat_*，1 秒轮询 /api/cast/state）----
    self.statPhase = [self statValue:@"sp_cast_stat_phase" t:t];
    self.statDev = [self statValue:@"sp_cast_stat_dev" t:t];
    self.statPos = [self statValue:@"sp_cast_stat_pos" t:t];
    self.statTransport = [self statValue:@"sp_cast_stat_transport" t:t];
    self.statBytes = [self statValue:@"sp_cast_stat_bytes" t:t];
    self.statReqs = [self statValue:@"sp_cast_stat_reqs" t:t];
    self.statPort = [self statValue:@"sp_cast_stat_port" t:t];
    self.statRateMatch = [self statValue:@"sp_cast_stat_ratematch" t:t];
    self.statPrep = [self statValue:@"sp_cast_stat_prep" t:t];
    self.statWarn = [self statValue:@"sp_cast_stat_warn" t:t];
    self.statWarn.textColor = t.warn;
    self.statErr = [self statValue:@"sp_cast_stat_err" t:t];
    self.statErr.textColor = t.danger;

    for (NSArray *pair in @[
        @[ @"运行阶段", self.statPhase ],
        @[ @"目标渲染器", self.statDev ],
        @[ @"播放进度", self.statPos ],
        @[ @"传输状态", self.statTransport ],
        @[ @"供源传输字节", self.statBytes ],
        @[ @"供源请求数", self.statReqs ],
        @[ @"供源端口", self.statPort ],
        @[ @"采样率取证", self.statRateMatch ],
        @[ @"准备进度", self.statPrep ],
        @[ @"采样率告警", self.statWarn ],
        @[ @"错误信息", self.statErr ],
    ]) {
        NSView *row = [self statRow:pair[0] value:pair[1] t:t];
        // web 把「准备进度 / 采样率告警 / 错误信息」三行各包在一个 id 为 *_box 的容器里，
        // 平时 display:none、有内容才显示。原生同样按内容显隐，identifier 落在容器上。
        if ([pair[1] isEqual:self.statPrep])      { row.identifier = @"sp_cast_stat_prep_box"; self.prepBox = row; row.hidden = YES; }
        else if ([pair[1] isEqual:self.statWarn]) { row.identifier = @"sp_cast_stat_warn_box"; self.warnBox = row; row.hidden = YES; }
        else if ([pair[1] isEqual:self.statErr])  { row.identifier = @"sp_cast_stat_err_box";  self.errBox = row;  row.hidden = YES; }
        [self.stack addArrangedSubview:row];
        [row.widthAnchor constraintLessThanOrEqualToAnchor:self.stack.widthAnchor].active = YES;
    }
}

#pragma mark - 动作

- (void)onRefresh:(id)sender { [self loadDevicesForce:YES]; }

/// 发起投放。**只由用户点按钮触发**（铁律 1：绝不自动让用户设备出声）。
- (void)onPush:(id)sender {
    if (![RLPCoreClient shared].started) { RLPToast(RLPTr(@"核心未启动")); return; }
    const NSInteger idx = self.devicePop.indexOfSelectedItem;
    if (idx < 0 || idx >= (NSInteger)self.devices.count) {
        RLPToast(RLPTr(@"请先选择一台设备"));
        return;
    }
    NSDictionary *d = self.devices[idx];
    // 后端读 dev（rtaweb.cpp）。优先 id，退回 name；都没有就不发请求，不猜。
    NSString *dev = [d[@"id"] isKindOfClass:[NSString class]] ? d[@"id"] : nil;
    if (!dev.length) dev = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : nil;
    if (!dev.length) { RLPToast(RLPTr(@"这台设备没有可用标识")); return; }

    NSString *body = [NSString stringWithFormat:@"dev=%@", RLPEnc(dev)];
    self.msg.stringValue = RLPTr(@"正在连接设备…");
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/cast/start" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"投放启动失败");
            self_.msg.stringValue = err;
            RLPToast(err);
            return;
        }
        [self_ refreshState];
    }];
}

- (void)onStop:(id)sender {
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/cast/stop" body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"停止投放失败");
            RLPToast(err);
            return;
        }
        [self_ refreshState];
    }];
}

- (void)onDeviceChanged:(NSPopUpButton *)sender {
    id ro = sender.selectedItem.representedObject;
    NSString *val = [ro isKindOfClass:[NSString class]] ? (NSString *)ro : @"";
    self.savedUpnpDev = val;
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/settings"
                                body:[NSString stringWithFormat:@"upnpdev=%@", RLPEnc(val)]
                          completion:^(NSDictionary * _Nullable json) {
        (void)json;
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        [self_ reloadSettings];
        [[NSNotificationCenter defaultCenter] postNotificationName:RLPSettingsChangedNotification object:self_];
    }];
}

static NSInteger RLPCastParseDsdLevel(id _Nullable obj) {
    NSString *s = [obj isKindOfClass:[NSString class]] ? (NSString *)obj
                : ([obj respondsToSelector:@selector(stringValue)] ? [obj stringValue] : @"0");
    NSString *low = [[s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if ([low hasPrefix:@"native"]) low = [low substringFromIndex:6];
    else if ([low hasPrefix:@"nat"]) low = [low substringFromIndex:3];
    else if ([low hasPrefix:@"dop"]) low = [low substringFromIndex:3];
    const NSInteger v = [low integerValue];
    return (v == 64 || v == 128 || v == 256 || v == 512) ? v : 0;
}

- (void)onCastUpsample:(NSSwitch *)s {
    // 用户显式选择「投放升频」。写 cast_upsample 后由后端
    // resolve_cast_upsample_from_playback 的 ⓪ 分支接管：目标率取 max，
    // 再由 cast_upsample_plan 按 ceiling 与渲染器声明能力收口。
    __weak __typeof__(self) weakSelf = self;
    [RLPCoreClient.shared postJSON:@"/api/settings"
                              body:[NSString stringWithFormat:@"cast_upsample=%@",
                                    s.state == NSControlStateValueOn ? @"1" : @"0"]
                        completion:^(NSDictionary * _Nullable json) {
        (void)json;
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        [self_ reloadSettings];
        [self_ refreshState];
        [[NSNotificationCenter defaultCenter] postNotificationName:RLPSettingsChangedNotification object:self_];
    }];
}
- (void)onCastCeiling:(NSPopUpButton *)s {
    // 提交的是 representedObject（auto / 96000 / …），不是显示文案：
    // 「自动（跟随设备）」这四个字写进 conf 会被后端当成无法识别的值。
    NSString *v = [s.selectedItem.representedObject isKindOfClass:[NSString class]]
        ? (NSString *)s.selectedItem.representedObject
        : (s.titleOfSelectedItem ?: @"auto");
    __weak __typeof__(self) weakSelf = self;
    [RLPCoreClient.shared postJSON:@"/api/settings"
                              body:[NSString stringWithFormat:@"cast_upsample_ceiling=%@", v]
                        completion:^(NSDictionary * _Nullable json) {
        (void)json;
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        [self_ reloadSettings];
        [self_ refreshState];
        [[NSNotificationCenter defaultCenter] postNotificationName:RLPSettingsChangedNotification object:self_];
    }];
}
- (void)onCastForce:(NSSwitch *)s {
    __weak __typeof__(self) weakSelf = self;
    [RLPCoreClient.shared postJSON:@"/api/settings"
                              body:[NSString stringWithFormat:@"cast_upsample_force=%@",
                                    s.state == NSControlStateValueOn ? @"1" : @"0"]
                        completion:^(NSDictionary * _Nullable json) {
        (void)json;
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        [self_ reloadSettings];
        [self_ refreshState];
        [[NSNotificationCenter defaultCenter] postNotificationName:RLPSettingsChangedNotification object:self_];
    }];
}

#pragma mark - 数据

- (void)syncDeviceSelection {
    NSString *want = self.savedUpnpDev ?: @"";
    if (!want.length) return;
    for (NSInteger i = 0; i < (NSInteger)self.devicePop.numberOfItems; ++i) {
        id ro = [self.devicePop itemAtIndex:i].representedObject;
        if ([ro isKindOfClass:[NSString class]] && [(NSString *)ro isEqualToString:want]) {
            [self.devicePop selectItemAtIndex:i];
            return;
        }
    }
    [self.devicePop addItemWithTitle:[NSString stringWithFormat:@"%@%@", RLPTr(@"（上次选择 · 离线/需刷新）"), want]];
    [[self.devicePop lastItem] setRepresentedObject:want];
    [self.devicePop selectItemAtIndex:self.devicePop.numberOfItems - 1];
}

- (void)applySettingsPayload:(NSDictionary *)json {
    if (![json isKindOfClass:[NSDictionary class]]) return;
    self.lastSettingsJson = json;
    NSDictionary *kv = [json[@"kv"] isKindOfClass:[NSDictionary class]] ? json[@"kv"] : json;

    id dirObj = kv[@"directsdm"];
    NSString *dirStr = [dirObj isKindOfClass:[NSString class]] ? (NSString *)dirObj
                     : ([dirObj respondsToSelector:@selector(stringValue)] ? [dirObj stringValue] : @"0");
    const BOOL directSdm = [dirStr isEqualToString:@"1"] || [[dirStr lowercaseString] isEqualToString:@"true"];

    id rateObj = kv[@"rate"];
    NSString *rateRaw = [rateObj isKindOfClass:[NSString class]] ? (NSString *)rateObj
                      : ([rateObj respondsToSelector:@selector(stringValue)] ? [rateObj stringValue] : @"");
    NSString *rateStr = [rateRaw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    const BOOL rateIsSrc = (!rateStr.length || [rateStr isEqualToString:@"src"] || [rateStr isEqualToString:@"follow"]);

    const NSInteger dsdLevel = RLPCastParseDsdLevel(kv[@"dsd"]);

    id filtObj = kv[@"filter"];
    NSString *filterStr = [filtObj isKindOfClass:[NSString class]]
        ? [(NSString *)filtObj stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        : @"";

    // 用户在投放区显式勾选「投放升频」→ 独立于全局播放方式（见后端
    // resolve_cast_upsample_from_playback 的 ⓪ 分支）。
    id cuObj = kv[@"cast_upsample"];
    NSString *cuStr = [cuObj isKindOfClass:[NSString class]] ? (NSString *)cuObj
                    : ([cuObj respondsToSelector:@selector(stringValue)] ? [cuObj stringValue] : @"");
    const BOOL castOptIn = [cuStr isEqualToString:@"1"] || [cuStr isEqualToString:@"true"];

    BOOL followUpsample = NO;
    NSString *infoText = nil;
    if (castOptIn && !directSdm) {
        // 显式选择优先：目标率取 max（= min(上限, 渲染器声明最高率)）
        followUpsample = YES;
        infoText = [NSString stringWithFormat:
                    RLPTr(@"已按投放设置独立升频：目标率取上限与设备声明的最低者（上限 %@ Hz）"),
                    ([kv[@"cast_upsample_ceiling"] respondsToSelector:@selector(description)]
                     ? [kv[@"cast_upsample_ceiling"] description] : @"auto")];
    } else if (directSdm) {
        followUpsample = NO;
        infoText = RLPTr(@"已跟随播放方式：DirectSDM / 原音直通（投放不升频）");
    } else if (dsdLevel >= 64) {
        followUpsample = YES;
        infoText = [NSString stringWithFormat:
                    RLPTr(@"已跟随播放方式：DSD%ld 升频（PCM 投放按上限升频；DSD 源保持 DoP 直通）"),
                    (long)dsdLevel];
    } else if (!rateIsSrc) {
        followUpsample = YES;
        infoText = [NSString stringWithFormat:
                    RLPTr(@"已跟随播放方式：PCM 升频（目标率 %@ · 上限与强制选项生效）"),
                    rateStr];
    } else if (filterStr.length > 0) {
        followUpsample = NO;
        infoText = RLPTr(@"已跟随播放方式：跟随源采样率（仅滤波器自定义，投放不升频）");
    } else {
        followUpsample = NO;
        infoText = RLPTr(@"已跟随播放方式：原音直通（投放不升频）");
    }

    // 开关可点击：它现在真的会写 cast_upsample（旧实现是只读镜像）。
    // DirectSDM 下仍然禁用 —— 那条路径本来就不经过重采样，勾了也不会生效，
    // 让可点的控件去做一件不发生的事才是欺骗。
    self.upSwitch.enabled = !directSdm;
    self.upSwitch.state = followUpsample ? NSControlStateValueOn : NSControlStateValueOff;
    self.upInfo.stringValue = infoText;

    NSString *ceilVal = [kv[@"cast_upsample_ceiling"] isKindOfClass:[NSString class]]
        ? kv[@"cast_upsample_ceiling"]
        : ([kv[@"cast_upsample_ceiling"] respondsToSelector:@selector(stringValue)] ? [kv[@"cast_upsample_ceiling"] stringValue] : @"auto");
    if (!ceilVal.length || [ceilVal isEqualToString:@"0"]) ceilVal = @"auto";
    // 按 representedObject 选，不是按显示文案（auto 的文案是可翻译的）。
    NSInteger wantIdx = 0;
    for (NSInteger i = 0; i < (NSInteger)self.upCeilPopup.numberOfItems; ++i) {
        id ro = [self.upCeilPopup itemAtIndex:i].representedObject;
        if ([ro isKindOfClass:[NSString class]] && [(NSString *)ro isEqualToString:ceilVal]) { wantIdx = i; break; }
    }
    [self.upCeilPopup selectItemAtIndex:wantIdx];
    NSString *force = [kv[@"cast_upsample_force"] respondsToSelector:@selector(description)] ? [kv[@"cast_upsample_force"] description] : @"0";
    self.upForceSwitch.state = [force isEqualToString:@"1"] ? NSControlStateValueOn : NSControlStateValueOff;
    NSString *upnpDev = [kv[@"upnpdev"] isKindOfClass:[NSString class]] ? kv[@"upnpdev"] : @"";
    self.savedUpnpDev = upnpDev;
    [self syncDeviceSelection];
}

- (void)reloadSettings {
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/settings" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || ![json isKindOfClass:[NSDictionary class]]) return;
        [self_ applySettingsPayload:json];
    }];
}

- (void)applyDevicesPayload:(NSDictionary *)json {
    if (![json isKindOfClass:[NSDictionary class]]) return;
    self.lastDevicesJson = json;
    NSArray *list = [json[@"devices"] isKindOfClass:[NSArray class]] ? json[@"devices"] : @[];
    self.devices = list;
    [self.devicePop removeAllItems];
    if (!list.count) {
        [self.devicePop addItemWithTitle:RLPTr(@"（未发现 UPnP 渲染器）")];
        [[self.devicePop lastItem] setRepresentedObject:@""];
        NSString *hint = [json[@"hint"] isKindOfClass:[NSString class]] ? json[@"hint"] : nil;
        self.devMsg.stringValue = hint.length ? hint
            : RLPTr(@"未发现 UPnP/DLNA 渲染器（确认设备已开机并开启 DLNA/UPnP）");
    } else {
        for (NSDictionary *d in list) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            NSString *n = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : RLPTr(@"未知设备");
            NSString *devId = [d[@"id"] isKindOfClass:[NSString class]] && [d[@"id"] length] ? d[@"id"]
                            : ([d[@"location"] isKindOfClass:[NSString class]] && [d[@"location"] length] ? d[@"location"]
                            : ([d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : @""));
            [self.devicePop addItemWithTitle:n];
            [[self.devicePop lastItem] setRepresentedObject:devId];
        }
        self.devMsg.stringValue = [NSString stringWithFormat:RLPTr(@"共发现 %lu 个渲染器"),
                                    (unsigned long)list.count];
    }
    [self syncDeviceSelection];
}

- (void)loadDevices { [self loadDevicesForce:NO]; }

/// /api/upnp：web「快速开始 / 设置·输出」页的后端设备列表端点。
/// 与 /api/cast/devices 是**两个端点**（前者用于选择目标渲染器，后者用于投放会话），
/// 两边都要有，不能拿一个顶另一个。
- (void)loadUpnpDevices {
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/upnp" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || ![json isKindOfClass:[NSDictionary class]]) return;
        [self_ applyDevicesPayload:json];
    }];
}

- (void)loadDevicesForce:(BOOL)force {
    if (![RLPCoreClient shared].started) return;
    self.devMsg.stringValue = RLPTr(@"正在发现渲染器…");
    NSString *url = force ? @"/api/cast/devices?scan=1" : @"/api/cast/devices";
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || ![json isKindOfClass:[NSDictionary class]]) return;
        [self_ applyDevicesPayload:json];
    }];
}

- (void)applyStatePayload:(NSDictionary *)json {
    if (![json isKindOfClass:[NSDictionary class]]) return;
    self.lastStateJson = json;
    const BOOL running = [json[@"running"] boolValue];
    self.stopBtn.enabled = running;
    self.pushBtn.enabled = !running;
    self.statPhase.stringValue = running ? RLPTr(@"投放中") : RLPTr(@"已停止");
    self.statDev.stringValue = [json[@"device"] isKindOfClass:[NSString class]]
        ? json[@"device"] : @"-";
    // 进度：后端给秒数；没有时间格式化成 m:ss
    id pos = json[@"pos"];
    self.statPos.stringValue = [pos respondsToSelector:@selector(doubleValue)]
        ? RLPFmtDuration([pos doubleValue]) : @"0:00";
    self.statTransport.stringValue = [json[@"transport"] isKindOfClass:[NSString class]]
        ? json[@"transport"] : (running ? @"PLAYING" : @"STOPPED");
    id bytes = json[@"bytes"];
    self.statBytes.stringValue = [bytes respondsToSelector:@selector(doubleValue)]
        ? RLPFmtBytes([bytes doubleValue]) : @"0 B";
    id reqs = json[@"reqs"];
    self.statReqs.stringValue = [reqs respondsToSelector:@selector(integerValue)]
        ? [NSString stringWithFormat:RLPTr(@"%ld 次"), (long)[reqs integerValue]] : @"0";
    id port = json[@"port"];
    self.statPort.stringValue = [port respondsToSelector:@selector(integerValue)]
        ? [NSString stringWithFormat:@"%ld", (long)[port integerValue]] : @"-";
    // 采样率取证：源/供出不一致时明说，不假装 bit-perfect
    id srcR = json[@"sourceRate"], srvR = json[@"servedRate"];
    if ([srcR respondsToSelector:@selector(integerValue)] &&
        [srvR respondsToSelector:@selector(integerValue)] &&
        [srcR integerValue] > 0 && [srvR integerValue] > 0) {
        const BOOL same = [srcR integerValue] == [srvR integerValue];
        self.statRateMatch.stringValue = same
            ? [NSString stringWithFormat:RLPTr(@"一致 %ld Hz"), (long)[srcR integerValue]]
            : [NSString stringWithFormat:RLPTr(@"已重采样 %ld → %ld Hz"),
               (long)[srcR integerValue], (long)[srvR integerValue]];
    } else {
        self.statRateMatch.stringValue = RLPTr(@"未取证");
    }
    id prep = json[@"prep"];
    const BOOL hasPrep = [prep respondsToSelector:@selector(doubleValue)] && [prep doubleValue] > 0.0;
    self.statPrep.stringValue = hasPrep
        ? [NSString stringWithFormat:@"%.0f%%", [prep doubleValue] * 100.0] : @"-";
    self.prepBox.hidden = !hasPrep;

    NSString *warnStr = [json[@"warn"] isKindOfClass:[NSString class]] ? json[@"warn"] : @"";
    self.statWarn.stringValue = warnStr.length ? warnStr : @"-";
    self.warnBox.hidden = (warnStr.length == 0);

    NSString *errStr = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : @"";
    self.statErr.stringValue = errStr.length ? errStr : @"-";
    self.errBox.hidden = (errStr.length == 0);
}

- (void)refreshState {
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/cast/state" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || ![json isKindOfClass:[NSDictionary class]]) return;
        [self_ applyStatePayload:json];
    }];
}

- (void)reload {
    if (![RLPCoreClient shared].started) return;
    [self reloadSettings];
    [self loadDevicesForce:NO];
    [self refreshState];
    if (self.window) [self startPolling];
}

- (void)startPolling {
    if (self.poll || ![RLPCoreClient shared].started) return;
    self.polling = YES;
    __weak __typeof__(self) weakSelf = self;
    self.poll = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) { [t invalidate]; return; }
        [self_ refreshState];
    }];
}

- (void)stopPolling {
    [self.poll invalidate];
    self.poll = nil;
    self.polling = NO;
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.devMsg.textColor = t.mut;
    self.msg.textColor = t.mut;
    self.upLabel.textColor = t.text;
    self.forceLabel.textColor = t.text;
    self.upInfo.textColor = t.mut;
    for (NSDictionary *entry in self.statLabelEntries) {
        NSTextField *lbl = entry[@"label"];
        lbl.textColor = t.mut;
    }
    for (NSTextField *f in @[ self.statPhase, self.statDev, self.statPos, self.statTransport,
                              self.statBytes, self.statReqs, self.statPort, self.statRateMatch,
                              self.statPrep ])
        f.textColor = t.text;
    self.statWarn.textColor = t.warn;
    self.statErr.textColor = t.danger;
}

- (void)applyLanguage {
    self.scanBtn.title = RLPTr(@"重新发现");
    self.pushBtn.title = RLPTr(@"推送当前曲");
    self.stopBtn.title = RLPTr(@"停止投放");
    self.upLabel.stringValue = RLPTr(@"投放升频");
    self.upSwitch.toolTip = RLPTr(@"勾选后投放按上限与设备声明能力升频（独立于全局播放方式）");
    self.forceLabel.stringValue = RLPTr(@"强制目标率（忽略渲染器声明）");
    if (self.upCeilPopup.numberOfItems > 0) {
        [self.upCeilPopup itemAtIndex:0].title = RLPTr(@"自动（跟随设备）");
    }
    for (NSDictionary *entry in self.statLabelEntries) {
        NSString *key = entry[@"key"];
        NSTextField *lbl = entry[@"label"];
        lbl.stringValue = RLPTr(key);
    }
    if (self.lastDevicesJson) {
        [self applyDevicesPayload:self.lastDevicesJson];
    } else {
        if (self.devicePop.numberOfItems > 0) {
            [self.devicePop itemAtIndex:0].title = RLPTr(@"（未发现 UPnP 渲染器）");
        }
        self.devMsg.stringValue = RLPTr(@"点「重新发现」扫描局域网里的 MediaRenderer");
    }
    if (self.lastSettingsJson) {
        [self applySettingsPayload:self.lastSettingsJson];
    } else {
        self.upInfo.stringValue = RLPTr(@"跟随播放方式（加载设置后同步）");
    }
    if (self.lastStateJson) {
        [self applyStatePayload:self.lastStateJson];
    }
}

@end
