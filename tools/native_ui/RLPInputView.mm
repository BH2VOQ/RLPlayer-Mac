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
//        ⚠️ loopback=1 在 macOS 会被拒绝："首版不支持系统混音回环"
//   POST /api/input/stop    空 body
//
// 铁律 1：本文件**绝不**自动开始采集或播放。所有采集都必须用户显式点按钮，
// 且直通监听默认关 —— 否则可能把输入直接送到用户的听音设备。
#import "RLPInputView.h"
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

@interface RLPInputView ()
@property (nonatomic, strong) NSStackView *stack;
@property (nonatomic, strong) NSPopUpButton *backend;
@property (nonatomic, strong) NSPopUpButton *device;
@property (nonatomic, strong) NSPopUpButton *mode;
@property (nonatomic, strong) NSTextField *seconds;
@property (nonatomic, strong) NSTextField *outPath;
@property (nonatomic, strong) NSButton *startBtn;
@property (nonatomic, strong) NSButton *stopBtn;
@property (nonatomic, strong) NSTextField *status;
@property (nonatomic, strong) NSTextField *warning;
@property (nonatomic, copy) NSArray<NSDictionary *> *devices;
@property (nonatomic, assign) BOOL running;
@end

@implementation RLPInputView

- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    if (self) { _devices = @[]; [self build]; }
    return self;
}

- (NSView *)row:(NSString *)label control:(NSView *)ctl hint:(NSString *)hint {
    RLPTheme *t = [RLPTheme current];
    NSStackView *r = [[NSStackView alloc] init];
    r.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r.alignment = NSLayoutAttributeCenterY;
    r.spacing = 10;
    NSTextField *l = RLPLabel(label, t.body, t.text);
    [[l.widthAnchor constraintEqualToConstant:150] setActive:YES];
    [r addArrangedSubview:l];
    [r addArrangedSubview:ctl];
    if (hint.length) [r addArrangedSubview:RLPLabel(hint, t.small, t.mut)];
    return r;
}

- (void)build {
    RLPTheme *t = [RLPTheme current];
    NSScrollView *sc = [[NSScrollView alloc] initWithFrame:self.bounds];
    sc.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    sc.drawsBackground = NO;
    sc.hasVerticalScroller = YES;
    [self addSubview:sc];

    self.stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.stack.alignment = NSLayoutAttributeLeading;
    self.stack.spacing = 12;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    sc.documentView = self.stack;
    [NSLayoutConstraint activateConstraints:@[
        [self.stack.leadingAnchor constraintEqualToAnchor:sc.contentView.leadingAnchor],
        [self.stack.trailingAnchor constraintEqualToAnchor:sc.contentView.trailingAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:sc.contentView.topAnchor],
        [self.stack.widthAnchor constraintEqualToAnchor:sc.contentView.widthAnchor],
    ]];

    self.backend = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.backend addItemsWithTitles:@[ @"none", @"coreaudio", @"coreaudio-shared" ]];
    self.backend.target = self;
    self.backend.action = @selector(onBackend:);
    [[self.backend.widthAnchor constraintEqualToConstant:220] setActive:YES];
    [self.stack addArrangedSubview:[self row:RLPTr(@"输入后端") control:self.backend hint:nil]];

    self.device = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.device addItemWithTitle:RLPTr(@"默认输入设备")];
    [[self.device.widthAnchor constraintEqualToConstant:280] setActive:YES];
    NSStackView *devRow = (NSStackView *)[self row:RLPTr(@"输入设备") control:self.device hint:nil];
    NSButton *refresh = [NSButton buttonWithTitle:RLPTr(@"刷新") target:self action:@selector(onRefreshDevices:)];
    refresh.bezelStyle = NSBezelStyleRounded;
    [devRow addArrangedSubview:refresh];
    [self.stack addArrangedSubview:devRow];

    self.mode = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.mode addItemsWithTitles:@[ RLPTr(@"录制到文件"), RLPTr(@"直通监听"), RLPTr(@"空跑（不开设备）") ]];
    self.mode.target = self;
    self.mode.action = @selector(onMode:);
    [[self.mode.widthAnchor constraintEqualToConstant:220] setActive:YES];
    [self.stack addArrangedSubview:[self row:RLPTr(@"采集模式") control:self.mode hint:nil]];

    self.seconds = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.seconds.stringValue = @"0";
    [[self.seconds.widthAnchor constraintEqualToConstant:90] setActive:YES];
    [self.stack addArrangedSubview:[self row:RLPTr(@"时长（秒）") control:self.seconds
                                        hint:RLPTr(@"0 = 不限，直到手动停止")]];

    self.outPath = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.outPath.placeholderString = RLPTr(@"留空 = 自动存到 Application Support/RLPlayer/recordings");
    [[self.outPath.widthAnchor constraintEqualToConstant:380] setActive:YES];
    [self.stack addArrangedSubview:[self row:RLPTr(@"输出文件") control:self.outPath hint:nil]];

    self.warning = RLPLabel(RLPTr(@"直通监听会把输入直接送到输出设备：请先确认音量，注意啸叫与回声。"),
                            t.small, t.danger);
    self.warning.maximumNumberOfLines = 2;
    self.warning.lineBreakMode = NSLineBreakByWordWrapping;
    self.warning.hidden = YES;   // 默认模式是录制，不显示这条
    [self.stack addArrangedSubview:self.warning];

    NSStackView *btns = [[NSStackView alloc] init];
    btns.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    btns.spacing = 8;
    self.startBtn = [NSButton buttonWithTitle:RLPTr(@"开始采集") target:self action:@selector(onStart:)];
    self.stopBtn = [NSButton buttonWithTitle:RLPTr(@"停止采集") target:self action:@selector(onStop:)];
    for (NSButton *b in @[ self.startBtn, self.stopBtn ]) b.bezelStyle = NSBezelStyleRounded;
    self.stopBtn.enabled = NO;
    [btns addArrangedSubview:self.startBtn];
    [btns addArrangedSubview:self.stopBtn];
    [self.stack addArrangedSubview:btns];

    self.status = RLPLabel(@"", t.small, t.mut);
    self.status.maximumNumberOfLines = 2;
    self.status.lineBreakMode = NSLineBreakByWordWrapping;
    [self.stack addArrangedSubview:self.status];

    [self.stack addArrangedSubview:RLPLabel(
        RLPTr(@"macOS 当前不支持系统混音回环采集（后端会明确拒绝），只能采集物理输入设备。"),
        t.small, t.mut)];
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
    const NSInteger di = self.device.indexOfSelectedItem;
    if (di > 0 && di <= (NSInteger)self.devices.count) {
        NSString *devId = self.devices[di - 1][@"id"];
        if ([devId isKindOfClass:[NSString class]] && devId.length)
            [body appendFormat:@"&dev=%@", RLPEnc(devId)];
    }
    const double secs = self.seconds.doubleValue;
    if (secs > 0) [body appendFormat:@"&seconds=%.3f", secs];
    NSString *out = [self.outPath.stringValue stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (out.length) [body appendFormat:@"&out=%@", RLPEnc(out)];

    self.status.stringValue = RLPTr(@"正在启动采集…");
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/input/start" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"启动失败");
            self_.status.stringValue = err;
            RLPToast(err);
            return;
        }
        self_.running = YES;
        self_.startBtn.enabled = NO;
        self_.stopBtn.enabled = YES;
        self_.status.stringValue = RLPTr(@"采集进行中");
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
        if (json && [json[@"ok"] boolValue]) self_.status.stringValue = RLPTr(@"已停止采集");
        else self_.status.stringValue = [json[@"error"] isKindOfClass:[NSString class]]
            ? json[@"error"] : RLPTr(@"停止失败");
    }];
}

#pragma mark - 数据

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
        [self_.device removeAllItems];
        [self_.device addItemWithTitle:RLPTr(@"默认输入设备")];
        for (NSDictionary *d in good) {
            NSString *nm = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : @"";
            if (!nm.length) continue;
            // loopback 是后端真实字段名（不是 isLoopback）；macOS 不支持，标出来但不让选
            const BOOL lb = [d[@"loopback"] respondsToSelector:@selector(boolValue)] && [d[@"loopback"] boolValue];
            NSString *title = lb ? [nm stringByAppendingString:RLPTr(@"（系统混音·本机不支持）")] : nm;
            [self_.device addItemWithTitle:title];
            if (lb) [[self_.device itemAtIndex:self_.device.numberOfItems - 1] setEnabled:NO];
        }
    }];
}

- (void)reload {
    if (![RLPCoreClient shared].started) {
        self.status.stringValue = RLPTr(@"核心未启动");
        return;
    }
    [self loadDevices];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/input/state" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        const BOOL run = [json[@"running"] respondsToSelector:@selector(boolValue)] && [json[@"running"] boolValue];
        self_.running = run;
        self_.startBtn.enabled = !run;
        self_.stopBtn.enabled = run;
        self_.status.stringValue = run ? RLPTr(@"采集进行中") : RLPTr(@"未在采集");
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

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.status.textColor = t.mut;
    self.warning.textColor = t.danger;
}

@end
