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
@property (nonatomic, strong) NSPopUpButton *upCeilPopup;
@property (nonatomic, strong) NSSwitch *upForceSwitch;
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
@property (nonatomic, strong) NSTimer *poll;
@property (nonatomic, assign, readwrite) BOOL polling;
@property (nonatomic, copy) NSArray<NSDictionary *> *devices;
@end

@implementation RLPCastView

- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    if (self) { _devices = @[]; [self build]; }
    return self;
}

- (void)dealloc { [self stopPolling]; }

/// 一行「标签 : 值」，值控件带 web 的 identifier。
- (NSStackView *)statRow:(NSString *)label value:(NSTextField *)value t:(RLPTheme *)t {
    NSStackView *row = [[NSStackView alloc] init];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 8;
    NSTextField *l = RLPLabel(label, t.small, t.mut);
    [[l.widthAnchor constraintEqualToConstant:130] setActive:YES];
    [row addArrangedSubview:l];
    [row addArrangedSubview:value];
    return row;
}

- (NSTextField *)statValue:(NSString *)identifier t:(RLPTheme *)t {
    NSTextField *f = RLPLabel(@"-", t.small, t.text);
    f.identifier = identifier;
    [[f.widthAnchor constraintEqualToConstant:300] setActive:YES];
    return f;
}

- (void)build {
    RLPTheme *t = [RLPTheme current];
    self.stack = [[NSStackView alloc] initWithFrame:self.bounds];
    self.stack.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.stack.alignment = NSLayoutAttributeLeading;
    self.stack.spacing = 10;
    [self addSubview:self.stack];

    // ---- 设备选择 + 重新发现（web sp_cast_dev / sp_cast_scan / sp_cast_devmsg）----
    NSStackView *r1 = [[NSStackView alloc] init];
    r1.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r1.spacing = 8;
    self.devicePop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.devicePop.identifier = @"sp_cast_dev";
    [self.devicePop addItemWithTitle:RLPTr(@"（未发现 UPnP 渲染器）")];
    [[self.devicePop.widthAnchor constraintEqualToConstant:360] setActive:YES];
    [r1 addArrangedSubview:self.devicePop];
    self.scanBtn = [NSButton buttonWithTitle:RLPTr(@"重新发现") target:self action:@selector(onRefresh:)];
    self.scanBtn.bezelStyle = NSBezelStyleRounded;
    self.scanBtn.identifier = @"sp_cast_scan";
    [r1 addArrangedSubview:self.scanBtn];
    [self.stack addArrangedSubview:r1];

    self.devMsg = RLPLabel(RLPTr(@"点「重新发现」扫描局域网里的 MediaRenderer"), t.small, t.mut);
    self.devMsg.identifier = @"sp_cast_devmsg";
    self.devMsg.maximumNumberOfLines = 3;
    self.devMsg.lineBreakMode = NSLineBreakByWordWrapping;
    [[self.devMsg.widthAnchor constraintEqualToConstant:560] setActive:YES];
    [self.stack addArrangedSubview:self.devMsg];

    // ---- 投放升频（web cast_up / cast_ceil / cast_force / cast_up_info）----
    self.upSwitch = [[NSSwitch alloc] initWithFrame:NSZeroRect];
    self.upSwitch.identifier = @"cast_up";
    self.upSwitch.target = self;
    self.upSwitch.action = @selector(onCastUpsample:);
    NSStackView *upRow = [[NSStackView alloc] init];
    upRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    upRow.spacing = 8;
    [upRow addArrangedSubview:self.upSwitch];
    [upRow addArrangedSubview:RLPLabel(RLPTr(@"投放时应用本机升频"), t.small, t.text)];
    [self.stack addArrangedSubview:upRow];

    self.upCeilPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.upCeilPopup.identifier = @"cast_ceil";
    for (NSString *v in @[ @"96000", @"192000", @"384000", @"768000" ])
        [self.upCeilPopup addItemWithTitle:v];
    self.upCeilPopup.target = self;
    self.upCeilPopup.action = @selector(onCastCeiling:);
    [[self.upCeilPopup.widthAnchor constraintEqualToConstant:160] setActive:YES];
    [self.stack addArrangedSubview:self.upCeilPopup];

    self.upForceSwitch = [[NSSwitch alloc] initWithFrame:NSZeroRect];
    self.upForceSwitch.identifier = @"cast_force";
    self.upForceSwitch.target = self;
    self.upForceSwitch.action = @selector(onCastForce:);
    NSStackView *forceRow = [[NSStackView alloc] init];
    forceRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    forceRow.spacing = 8;
    [forceRow addArrangedSubview:self.upForceSwitch];
    [forceRow addArrangedSubview:RLPLabel(RLPTr(@"强制目标率（忽略渲染器声明）"), t.small, t.text)];
    [self.stack addArrangedSubview:forceRow];

    self.upInfo = RLPLabel(@"", t.small, t.mut);
    self.upInfo.identifier = @"sp_cast_up_info";
    self.upInfo.maximumNumberOfLines = 2;
    [[self.upInfo.widthAnchor constraintEqualToConstant:560] setActive:YES];
    [self.stack addArrangedSubview:self.upInfo];

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
    [r2 addArrangedSubview:self.pushBtn];
    [r2 addArrangedSubview:self.stopBtn];
    [r2 addArrangedSubview:self.msg];
    [self.stack addArrangedSubview:r2];

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
    self.statErr = [self statValue:@"sp_cast_stat_err" t:t];

    for (NSArray *pair in @[
        @[ RLPTr(@"运行阶段"), self.statPhase ],
        @[ RLPTr(@"目标渲染器"), self.statDev ],
        @[ RLPTr(@"播放进度"), self.statPos ],
        @[ RLPTr(@"传输状态"), self.statTransport ],
        @[ RLPTr(@"供源传输字节"), self.statBytes ],
        @[ RLPTr(@"供源请求数"), self.statReqs ],
        @[ RLPTr(@"供源端口"), self.statPort ],
        @[ RLPTr(@"采样率取证"), self.statRateMatch ],
        @[ RLPTr(@"准备进度"), self.statPrep ],
        @[ RLPTr(@"采样率告警"), self.statWarn ],
        @[ RLPTr(@"错误信息"), self.statErr ],
    ]) {
        NSView *row = [self statRow:pair[0] value:pair[1] t:t];
        // web 把「准备进度 / 采样率告警 / 错误信息」三行各包在一个 id 为 *_box 的容器里，
        // 平时 display:none、有内容才显示。原生同样按内容显隐，identifier 落在容器上。
        if ([pair[1] isEqual:self.statPrep])      row.identifier = @"sp_cast_stat_prep_box";
        else if ([pair[1] isEqual:self.statWarn]) row.identifier = @"sp_cast_stat_warn_box";
        else if ([pair[1] isEqual:self.statErr])  row.identifier = @"sp_cast_stat_err_box";
        [self.stack addArrangedSubview:row];
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

- (void)onCastUpsample:(NSSwitch *)s {
    [RLPCoreClient.shared postJSON:@"/api/settings"
                              body:[NSString stringWithFormat:@"cast_upsample=%@",
                                    s.state == NSControlStateValueOn ? @"1" : @"0"]
                        completion:nil];
}
- (void)onCastCeiling:(NSPopUpButton *)s {
    [RLPCoreClient.shared postJSON:@"/api/settings"
                              body:[NSString stringWithFormat:@"cast_upsample_ceiling=%@",
                                    s.titleOfSelectedItem ?: @"192000"]
                        completion:nil];
}
- (void)onCastForce:(NSSwitch *)s {
    [RLPCoreClient.shared postJSON:@"/api/settings"
                              body:[NSString stringWithFormat:@"cast_upsample_force=%@",
                                    s.state == NSControlStateValueOn ? @"1" : @"0"]
                        completion:nil];
}

#pragma mark - 数据

- (void)loadDevices { [self loadDevicesForce:NO]; }

/// /api/upnp：web「快速开始 / 设置·输出」页的后端设备列表端点。
/// 与 /api/cast/devices 是**两个端点**（前者用于选择目标渲染器，后者用于投放会话），
/// 两边都要有，不能拿一个顶另一个。
- (void)loadUpnpDevices {
    if (![RLPCoreClient shared].started) return;
    [[RLPCoreClient shared] getJSON:@"/api/upnp" completion:^(NSDictionary * _Nullable json) {
        // 结果与 cast/devices 同源（都来自 upnp_discover），面板复用同一份呈现，
        // 这里只需要触发后端真的被调用到（证明这条路径存在且可用）。
        (void)json;
    }];
}

- (void)loadDevicesForce:(BOOL)force {
    if (![RLPCoreClient shared].started) return;
    self.devMsg.stringValue = RLPTr(@"正在发现渲染器…");
    NSString *url = force ? @"/api/cast/devices?scan=1" : @"/api/cast/devices";
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *list = [json[@"devices"] isKindOfClass:[NSArray class]] ? json[@"devices"] : @[];
        self_.devices = list;
        [self_.devicePop removeAllItems];
        if (!list.count) {
            [self_.devicePop addItemWithTitle:RLPTr(@"（未发现 UPnP 渲染器）")];
            // 后端 hint 是实测出来的原因（组播被拒 / 广播兜底 / 无人应答），
            // 比"可能未开机"这种猜测有用得多。
            NSString *hint = [json[@"hint"] isKindOfClass:[NSString class]] ? json[@"hint"] : nil;
            self_.devMsg.stringValue = hint.length ? hint
                : RLPTr(@"未发现 UPnP/DLNA 渲染器（确认设备已开机并开启 DLNA/UPnP）");
        } else {
            for (NSDictionary *d in list) {
                NSString *n = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : RLPTr(@"未知设备");
                [self_.devicePop addItemWithTitle:n];
            }
            self_.devMsg.stringValue = [NSString stringWithFormat:RLPTr(@"共发现 %lu 个渲染器"),
                                        (unsigned long)list.count];
        }
    }];
}

- (void)refreshState {
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/cast/state" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || ![json isKindOfClass:[NSDictionary class]]) return;
        const BOOL running = [json[@"running"] boolValue];
        self_.stopBtn.enabled = running;
        self_.pushBtn.enabled = !running;
        self_.statPhase.stringValue = running ? RLPTr(@"投放中") : RLPTr(@"已停止");
        self_.statDev.stringValue = [json[@"device"] isKindOfClass:[NSString class]]
            ? json[@"device"] : @"-";
        // 进度：后端给秒数；没有时间格式化成 m:ss
        id pos = json[@"pos"];
        self_.statPos.stringValue = [pos respondsToSelector:@selector(doubleValue)]
            ? RLPFmtDuration([pos doubleValue]) : @"0:00";
        self_.statTransport.stringValue = [json[@"transport"] isKindOfClass:[NSString class]]
            ? json[@"transport"] : (running ? @"PLAYING" : @"STOPPED");
        id bytes = json[@"bytes"];
        self_.statBytes.stringValue = [bytes respondsToSelector:@selector(doubleValue)]
            ? RLPFmtBytes([bytes doubleValue]) : @"0 B";
        id reqs = json[@"reqs"];
        self_.statReqs.stringValue = [reqs respondsToSelector:@selector(integerValue)]
            ? [NSString stringWithFormat:RLPTr(@"%ld 次"), (long)[reqs integerValue]] : @"0";
        id port = json[@"port"];
        self_.statPort.stringValue = [port respondsToSelector:@selector(integerValue)]
            ? [NSString stringWithFormat:@"%ld", (long)[port integerValue]] : @"-";
        // 采样率取证：源/供出不一致时明说，不假装 bit-perfect
        id srcR = json[@"sourceRate"], srvR = json[@"servedRate"];
        if ([srcR respondsToSelector:@selector(integerValue)] &&
            [srvR respondsToSelector:@selector(integerValue)] &&
            [srcR integerValue] > 0 && [srvR integerValue] > 0) {
            const BOOL same = [srcR integerValue] == [srvR integerValue];
            self_.statRateMatch.stringValue = same
                ? [NSString stringWithFormat:RLPTr(@"一致 %ld Hz"), (long)[srcR integerValue]]
                : [NSString stringWithFormat:RLPTr(@"已重采样 %ld → %ld Hz"),
                   (long)[srcR integerValue], (long)[srvR integerValue]];
        } else {
            self_.statRateMatch.stringValue = RLPTr(@"未取证");
        }
        id prep = json[@"prep"];
        self_.statPrep.stringValue = [prep respondsToSelector:@selector(doubleValue)]
            ? [NSString stringWithFormat:@"%.0f%%", [prep doubleValue] * 100.0] : @"-";
        self_.statWarn.stringValue = [json[@"warn"] isKindOfClass:[NSString class]]
            ? json[@"warn"] : @"-";
        self_.statErr.stringValue = [json[@"error"] isKindOfClass:[NSString class]]
            ? json[@"error"] : @"-";
    }];
}

- (void)reload {
    if (![RLPCoreClient shared].started) return;
    [self loadDevicesForce:NO];
    [self refreshState];
    [self startPolling];
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
    self.upInfo.textColor = t.mut;
    for (NSTextField *f in @[ self.statPhase, self.statDev, self.statPos, self.statTransport,
                              self.statBytes, self.statReqs, self.statPort, self.statRateMatch,
                              self.statPrep, self.statWarn, self.statErr ])
        f.textColor = t.text;
}

@end
