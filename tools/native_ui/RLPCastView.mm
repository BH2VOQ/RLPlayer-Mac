// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPCastView.mm — 投放到 AirPlay / UPnP 设备
//
// 后端契约（tools/rtaweb.cpp:10891 起，逐行核实）：
//   GET  /api/upnp        → 设备发现列表
//   GET  /api/cast/state  → {"ok":true,"running":bool,"device":…,"airplay":bool,
//                            "sourceRate":Hz,"servedRate":Hz,"resampled":bool,…}
//   POST /api/cast/start  表单键 **dev**（不是 device！见 10915 行 if (k == "dev")）
//   POST /api/cast/stop   空 body
//
// 纪律：
//   * 绝不自动发起投放（会让用户设备出声，违反铁律 1）——只由用户点按钮。
//   * AirPlay 必须如实标注"端到端 bit-perfect 未获验证"（项目既有结论）。
//   * 核心未启动时不发请求、不启动轮询（selftest 会断言）。
#import "RLPCastView.h"
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

@interface RLPCastView ()
@property (nonatomic, strong) NSStackView *stack;
@property (nonatomic, strong) NSPopUpButton *devicePop;
@property (nonatomic, strong) NSButton *pushBtn;
@property (nonatomic, strong) NSButton *stopBtn;
@property (nonatomic, strong) NSTextField *statusLabel;
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

- (void)build {
    RLPTheme *t = [RLPTheme current];
    self.stack = [[NSStackView alloc] initWithFrame:self.bounds];
    self.stack.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.stack.alignment = NSLayoutAttributeLeading;
    self.stack.spacing = 10;
    [self addSubview:self.stack];

    [self.stack addArrangedSubview:RLPLabel(RLPTr(@"推送到设备"),
        [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], t.text)];

    NSStackView *r1 = [[NSStackView alloc] init];
    r1.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r1.spacing = 8;
    self.devicePop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.devicePop addItemWithTitle:RLPTr(@"未发现可投放设备")];
    [[self.devicePop.widthAnchor constraintEqualToConstant:280] setActive:YES];
    [r1 addArrangedSubview:self.devicePop];
    NSButton *refresh = [NSButton buttonWithTitle:RLPTr(@"刷新设备") target:self action:@selector(onRefresh:)];
    refresh.bezelStyle = NSBezelStyleRounded;
    [r1 addArrangedSubview:refresh];
    [self.stack addArrangedSubview:r1];

    NSStackView *r2 = [[NSStackView alloc] init];
    r2.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r2.spacing = 8;
    self.pushBtn = [NSButton buttonWithTitle:RLPTr(@"推送到此设备") target:self action:@selector(onPush:)];
    self.stopBtn = [NSButton buttonWithTitle:RLPTr(@"停止投放") target:self action:@selector(onStop:)];
    for (NSButton *b in @[ self.pushBtn, self.stopBtn ]) b.bezelStyle = NSBezelStyleRounded;
    self.stopBtn.enabled = NO;
    [r2 addArrangedSubview:self.pushBtn];
    [r2 addArrangedSubview:self.stopBtn];
    [self.stack addArrangedSubview:r2];

    self.statusLabel = RLPLabel(RLPTr(@"未在投放"), t.small, t.mut);
    self.statusLabel.maximumNumberOfLines = 5;
    self.statusLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [[self.statusLabel.widthAnchor constraintEqualToConstant:520] setActive:YES];
    [self.stack addArrangedSubview:self.statusLabel];
}

#pragma mark - 动作

- (void)onRefresh:(id)sender { [self loadDevices]; }

/// 发起投放。**只由用户点按钮触发**（铁律 1：绝不自动让用户设备出声）。
- (void)onPush:(id)sender {
    if (![RLPCoreClient shared].started) { RLPToast(RLPTr(@"核心未启动")); return; }
    const NSInteger idx = self.devicePop.indexOfSelectedItem;
    if (idx < 0 || idx >= (NSInteger)self.devices.count) {
        RLPToast(RLPTr(@"请先选择一台设备"));
        return;
    }
    NSDictionary *d = self.devices[idx];
    // 后端读 dev（rtaweb.cpp:10915）。优先 id，退回 name；都没有就不发请求，不猜。
    NSString *dev = [d[@"id"] isKindOfClass:[NSString class]] ? d[@"id"] : nil;
    if (!dev.length) dev = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : nil;
    if (!dev.length) { RLPToast(RLPTr(@"这台设备没有可用标识")); return; }

    // 表单串 + RLPEnc：绝不手拼 JSON（设备名里的引号会把请求体拼坏）
    NSString *body = [NSString stringWithFormat:@"dev=%@", RLPEnc(dev)];
    self.statusLabel.stringValue = RLPTr(@"正在连接设备…");
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/cast/start" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"投放启动失败");
            self_.statusLabel.stringValue = err;
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

#pragma mark - 数据

- (void)loadDevices {
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/upnp" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *arr = [json[@"devices"] isKindOfClass:[NSArray class]] ? json[@"devices"] : @[];
        NSMutableArray<NSDictionary *> *good = [NSMutableArray array];
        for (id x in arr) if ([x isKindOfClass:[NSDictionary class]]) [good addObject:x];
        self_.devices = good;
        [self_.devicePop removeAllItems];
        if (!good.count) {
            [self_.devicePop addItemWithTitle:RLPTr(@"未发现可投放设备")];
            self_.pushBtn.enabled = NO;
            return;
        }
        self_.pushBtn.enabled = YES;
        for (NSDictionary *d in good) {
            NSString *nm = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : @"";
            if (!nm.length) continue;
            const BOOL ap = [d[@"airplay"] respondsToSelector:@selector(boolValue)] && [d[@"airplay"] boolValue];
            [self_.devicePop addItemWithTitle:ap ? [nm stringByAppendingString:@"  (AirPlay)"] : nm];
        }
    }];
}

- (void)refreshState {
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/cast/state" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        const BOOL running = [json[@"running"] respondsToSelector:@selector(boolValue)] && [json[@"running"] boolValue];
        self_.stopBtn.enabled = running;
        if (!running) {
            self_.statusLabel.stringValue = RLPTr(@"未在投放");
            return;
        }
        NSString *dev = [json[@"device"] isKindOfClass:[NSString class]] ? json[@"device"] : RLPTr(@"未知设备");
        const NSInteger src = [json[@"sourceRate"] respondsToSelector:@selector(integerValue)] ? [json[@"sourceRate"] integerValue] : 0;
        const NSInteger served = [json[@"servedRate"] respondsToSelector:@selector(integerValue)] ? [json[@"servedRate"] integerValue] : 0;
        const BOOL resampled = [json[@"resampled"] respondsToSelector:@selector(boolValue)] && [json[@"resampled"] boolValue];
        const BOOL airplay = [json[@"airplay"] respondsToSelector:@selector(boolValue)] && [json[@"airplay"] boolValue];
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        [lines addObject:[NSString stringWithFormat:@"%@：%@", RLPTr(@"正在投放到"), dev]];
        [lines addObject:[NSString stringWithFormat:@"%@：%ld Hz → %ld Hz%@",
                          RLPTr(@"采样率"), (long)src, (long)served,
                          resampled ? [@" · " stringByAppendingString:RLPTr(@"已重采样")] : @""]];
        // AirPlay 端到端逐位直通**未获验证**（项目既有结论），不许写成 bit-perfect
        [lines addObject:airplay
            ? RLPTr(@"AirPlay：44100 Hz / 16 bit ALAC，端到端 bit-perfect 未获验证")
            : RLPTr(@"UPnP：按原采样率供源，本机不做升频；接收端是否重采样由对方决定")];
        self_.statusLabel.stringValue = [lines componentsJoinedByString:@"\n"];
    }];
}

- (void)reload {
    [self loadDevices];
    [self refreshState];
}

#pragma mark - 轮询

- (void)startPolling {
    if (self.polling) return;
    if (![RLPCoreClient shared].started) return;   // selftest / 无核心时不发请求
    self.polling = YES;
    __weak __typeof__(self) weakSelf = self;
    self.poll = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *tm) {
        (void)tm;
        [weakSelf refreshState];
    }];
}

- (void)stopPolling {
    [self.poll invalidate];
    self.poll = nil;
    self.polling = NO;
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.statusLabel.textColor = t.mut;
}

@end
