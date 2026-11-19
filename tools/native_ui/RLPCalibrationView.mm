// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPCalibrationView.mm — 房间测量向导 + 房间校正 IR
//
// 后端契约（已核实）：
//   GET  /api/roomcorr/plan?layout=2.0&sec=6
//        → {"ok":true,"layout","chCount","sweepSeconds","totalSeconds","levelDbfs",
//           "playDevice","captureDevice","warning"}
//   POST /api/roomcorr/measure?layout=…&sec=…&confirm=1   ← confirm=1 是后端的出声许可
//   POST /api/roomcorr/cancel
//   GET  /api/roomcorr/status
//   校正 IR 文件路径走 POST /api/settings 的 ir / irgpu 两键。
//
// ⚠️ 铁律 1：这条链路**会真的向用户设备播放扫频**。
// 顺序不可颠倒：plan → 把设备/时长/电平/警告摆出来 → 用户确认 → measure(confirm=1)。
#import "RLPCalibrationView.h"
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

@interface RLPCalibrationView ()
/// IR 段独立容器（web cal 页第三张卡）。设置页把它整段搬进「房间校正 IR」卡。
@property (nonatomic, strong) NSScrollView *scroll;
@property (nonatomic, copy) NSArray<NSLayoutConstraint *> *scrollConstraints;
@property (nonatomic, strong) NSStackView *irSection;
@property (nonatomic, strong) NSTextField *irStatus;
@property (nonatomic, strong) NSStackView *stack;
@property (nonatomic, strong) NSPopUpButton *layout;
@property (nonatomic, strong) NSTextField *sweepSec;
@property (nonatomic, strong) NSTextField *planInfo;
@property (nonatomic, strong) NSButton *planBtn;
@property (nonatomic, strong) NSButton *cancelBtn;
@property (nonatomic, strong) NSTextField *irPath;
@property (nonatomic, strong) NSSwitch *irGpu;
/// U4：测量麦克风校准（导入/清除；状态由 GET /api/miccal 驱动）
@property (nonatomic, strong) NSTextField *micCalNote;
@property (nonatomic, strong) NSButton *micCalImportBtn;
@property (nonatomic, strong) NSButton *micCalClearBtn;
@property (nonatomic, strong) NSTextField *status;
@property (nonatomic, copy) NSDictionary *plan;   // 最近一次 plan 的原始返回
@end

@implementation RLPCalibrationView

- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    if (self) [self build];
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

    [self.stack addArrangedSubview:RLPLabel(RLPTr(@"房间测量"),
        [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], t.text)];

    NSTextField *warn = RLPLabel(
        RLPTr(@"测量会真的向输出设备播放扫频信号。生成计划后请先核对设备、时长与电平，再决定是否开始。"),
        t.small, t.danger);
    warn.maximumNumberOfLines = 2;
    warn.lineBreakMode = NSLineBreakByWordWrapping;
    [[warn.widthAnchor constraintEqualToConstant:560] setActive:YES];
    [self.stack addArrangedSubview:warn];

    self.layout = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.layout addItemsWithTitles:@[ @"2.0", @"2.1", @"5.1", @"7.1" ]];
    [[self.layout.widthAnchor constraintEqualToConstant:120] setActive:YES];
    [self.stack addArrangedSubview:[self row:RLPTr(@"声道布局") control:self.layout hint:nil]];

    self.sweepSec = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.sweepSec.stringValue = @"6";
    [[self.sweepSec.widthAnchor constraintEqualToConstant:80] setActive:YES];
    [self.stack addArrangedSubview:[self row:RLPTr(@"每声道扫频（秒）") control:self.sweepSec hint:nil]];

    NSStackView *btns = [[NSStackView alloc] init];
    btns.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    btns.spacing = 8;
    self.planBtn = [NSButton buttonWithTitle:RLPTr(@"生成计划并确认") target:self action:@selector(onPlan:)];
    self.cancelBtn = [NSButton buttonWithTitle:RLPTr(@"取消测量") target:self action:@selector(onCancelMeasure:)];
    for (NSButton *b in @[ self.planBtn, self.cancelBtn ]) b.bezelStyle = NSBezelStyleRounded;
    [btns addArrangedSubview:self.planBtn];
    [btns addArrangedSubview:self.cancelBtn];
    [self.stack addArrangedSubview:btns];

    self.planInfo = RLPLabel(@"", t.small, t.mut);
    self.planInfo.maximumNumberOfLines = 6;
    self.planInfo.lineBreakMode = NSLineBreakByWordWrapping;
    [[self.planInfo.widthAnchor constraintEqualToConstant:560] setActive:YES];
    [self.stack addArrangedSubview:self.planInfo];

    // ---- 房间校正 IR（web cal 页第三张 sgroup「房间校正 IR（WAV 脉冲响应）」）----
    // 独立成一段（settings 页把这一整段搬进第三张卡片）：同一份视图/交互，不复制控件。
    self.irSection = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.irSection.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.irSection.alignment = NSLayoutAttributeLeading;
    self.irSection.spacing = 10;
    self.irSection.translatesAutoresizingMaskIntoConstraints = NO;
    [self.irSection addArrangedSubview:RLPLabel(RLPTr(@"房间校正 IR"),
        [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], t.text)];
    [self.irSection addArrangedSubview:RLPLabel(
        RLPTr(@"填入卷积用的 IR WAV 路径；留空 = 不做房间校正。也可用 REW / AutoEq 导出的文件。"),
        t.small, t.mut)];

    self.irPath = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.irPath.identifier = @"sp_ir";          // web #sp_ir（设置页「房间校正 IR」路径输入）
    self.irPath.placeholderString = RLPTr(@"例如 /Volumes/Music/ir/room.wav");
    [self.irPath.widthAnchor constraintGreaterThanOrEqualToConstant:260].active = YES;
    // 回车即落盘（web 表单保存时同样写 ir）；「应用」按钮保留给鼠标用户。
    self.irPath.target = self;
    self.irPath.action = @selector(onApplyIR:);
    NSStackView *irRow = (NSStackView *)[self row:RLPTr(@"IR 文件") control:self.irPath hint:nil];
    NSButton *pick = [NSButton buttonWithTitle:RLPTr(@"选择…") target:self action:@selector(onPickIR:)];
    pick.bezelStyle = NSBezelStyleRounded;
    [irRow addArrangedSubview:pick];
    NSButton *apply = [NSButton buttonWithTitle:RLPTr(@"应用") target:self action:@selector(onApplyIR:)];
    apply.bezelStyle = NSBezelStyleRounded;
    [irRow addArrangedSubview:apply];
    [self.irSection addArrangedSubview:irRow];

    self.irGpu = [[NSSwitch alloc] initWithFrame:NSZeroRect];
    self.irGpu.identifier = @"sp_irgpu";        // web #sp_irgpu（GPU 卷积开关）
    self.irGpu.target = self;
    self.irGpu.action = @selector(onIrGpu:);
    [self.irSection addArrangedSubview:[self row:RLPTr(@"GPU 卷积") control:self.irGpu
                                       hint:RLPTr(@"长 IR 用 GPU 更省 CPU")]];

    // IR 段自己的状态行：不再借用测量向导卡里的 status（那会让用户以为测量出了事）。
    self.irStatus = RLPLabel(@"", t.small, t.mut);
    self.irStatus.identifier = @"sp_irstatus";
    self.irStatus.maximumNumberOfLines = 2;
    self.irStatus.lineBreakMode = NSLineBreakByWordWrapping;
    [self.irSection addArrangedSubview:self.irStatus];
    [self.stack addArrangedSubview:self.irSection];

    // ---- U4：测量麦克风校准（把话筒自身频响从房间测量里扣掉）----
    // 为什么放在校准页：房间校正测到的是「房间 + 话筒」；不扣话筒曲线，话筒的起伏
    // 会被当成房间的峰谷写进校正 FIR。状态**只由 GET /api/miccal 驱动**，导入/清除
    // 成功后同样回读，不在本地推算数字（避免「界面说有 4 点、后端其实没换表」）。
    NSStackView *micCalSection = [[NSStackView alloc] initWithFrame:NSZeroRect];
    micCalSection.orientation = NSUserInterfaceLayoutOrientationVertical;
    micCalSection.alignment = NSLayoutAttributeLeading;
    micCalSection.spacing = 8;
    [micCalSection addArrangedSubview:RLPLabel(RLPTr(@"麦克风校准"),
        [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], t.text)];
    NSTextField *micHint = RLPLabel(
        RLPTr(@"导入两列文本（频率 Hz、幅度 dB；支持 UMIK / REW 导出的 txt、csv）。校准表已可导入，接入校正计算将在下一版完成。"),
        t.small, t.mut);
    micHint.maximumNumberOfLines = 2;
    micHint.lineBreakMode = NSLineBreakByWordWrapping;
    [[micHint.widthAnchor constraintEqualToConstant:560] setActive:YES];
    [micCalSection addArrangedSubview:micHint];

    NSStackView *micBtns = [[NSStackView alloc] init];
    micBtns.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    micBtns.spacing = 8;
    self.micCalImportBtn = [NSButton buttonWithTitle:RLPTr(@"导入麦克风校准文件…")
                                             target:self action:@selector(onImportMicCal:)];
    self.micCalImportBtn.identifier = @"sp_miccal_import";
    self.micCalClearBtn = [NSButton buttonWithTitle:RLPTr(@"清除")
                                            target:self action:@selector(onClearMicCal:)];
    self.micCalClearBtn.identifier = @"sp_miccal_clear";
    for (NSButton *b in @[ self.micCalImportBtn, self.micCalClearBtn ]) b.bezelStyle = NSBezelStyleRounded;
    [micBtns addArrangedSubview:self.micCalImportBtn];
    [micBtns addArrangedSubview:self.micCalClearBtn];
    [micCalSection addArrangedSubview:[self row:RLPTr(@"麦克风校准文件") control:micBtns hint:nil]];

    self.micCalNote = RLPLabel(RLPTr(@"未导入"), t.small, t.mut);
    self.micCalNote.identifier = @"sp_miccal_note";
    self.micCalNote.maximumNumberOfLines = 2;
    self.micCalNote.lineBreakMode = NSLineBreakByWordWrapping;
    [micCalSection addArrangedSubview:self.micCalNote];
    [self.stack addArrangedSubview:micCalSection];

    self.status = RLPLabel(@"", t.small, t.mut);
    self.status.maximumNumberOfLines = 2;
    self.status.lineBreakMode = NSLineBreakByWordWrapping;
    [self.stack addArrangedSubview:self.status];
}

#pragma mark - 嵌入设置页

/// 嵌入设置页（页面本身已有一个整页滚动容器）：拆掉本视图自己的 NSScrollView，
/// 内容直接铺开由外层页面滚动（用户 2026-11-13 要求「整页只有一根滚动条」）。
- (void)setEmbeddedInPage:(BOOL)embedded {
    if (!embedded || !self.scroll) return;
    [NSLayoutConstraint deactivateConstraints:self.scrollConstraints];
    [self.scroll removeFromSuperview];
    self.scroll = nil;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:self.stack];
    [NSLayoutConstraint activateConstraints:@[
        [self.stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:self.topAnchor],
    ]];
}

/// 内容自然高度（嵌入设置页时由设置页给高度约束；本视图没有 intrinsic 高度）。
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

/// 房间校正 IR 段（web cal 页第三张卡）。设置页把它整段搬进「房间校正 IR」卡。
- (NSView *)irSectionView { return self.irSection; }

#pragma mark - 测量（会出声，必须先确认）

- (void)onPlan:(id)sender {
    if (![RLPCoreClient shared].started) { RLPToast(RLPTr(@"核心未启动")); return; }
    NSString *lay = self.layout.titleOfSelectedItem ?: @"2.0";
    double sec = self.sweepSec.doubleValue;
    if (sec <= 0 || !isfinite(sec)) sec = 6;
    NSString *url = [NSString stringWithFormat:@"/api/roomcorr/plan?layout=%@&sec=%.3f",
                     RLPEnc(lay), sec];
    self.planInfo.stringValue = RLPTr(@"生成计划…");
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"无法生成测量计划");
            self_.planInfo.stringValue = err;
            return;
        }
        self_.plan = json;
        [self_ showPlanAndConfirm];
    }];
}

/// 把计划摆给用户看 + 模态确认。**只有用户点了确认才发 measure**。
- (void)showPlanAndConfirm {
    NSDictionary *p = self.plan;
    if (!p) return;
    NSString *playDev = [p[@"playDevice"] isKindOfClass:[NSString class]] ? p[@"playDevice"] : @"?";
    NSString *capDev = [p[@"captureDevice"] isKindOfClass:[NSString class]] ? p[@"captureDevice"] : @"?";
    NSString *warning = [p[@"warning"] isKindOfClass:[NSString class]] ? p[@"warning"] : @"";
    const NSInteger ch = [p[@"chCount"] respondsToSelector:@selector(integerValue)] ? [p[@"chCount"] integerValue] : 0;
    const double total = [p[@"totalSeconds"] respondsToSelector:@selector(doubleValue)] ? [p[@"totalSeconds"] doubleValue] : 0;
    const double sweep = [p[@"sweepSeconds"] respondsToSelector:@selector(doubleValue)] ? [p[@"sweepSeconds"] doubleValue] : 0;
    const double level = [p[@"levelDbfs"] respondsToSelector:@selector(doubleValue)] ? [p[@"levelDbfs"] doubleValue] : 0;

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"%@：%ld · %@ %.0f %@",
                      RLPTr(@"声道"), (long)ch, RLPTr(@"约"), total, RLPTr(@"秒")]];
    [lines addObject:[NSString stringWithFormat:@"%@：%.0f ms · %@ %.1f dBFS",
                      RLPTr(@"每声道扫频"), sweep * 1000.0, RLPTr(@"电平"), level]];
    [lines addObject:[NSString stringWithFormat:@"%@：%@", RLPTr(@"输出设备"), playDev]];
    [lines addObject:[NSString stringWithFormat:@"%@：%@", RLPTr(@"采集设备"), capDev]];
    self.planInfo.stringValue = [lines componentsJoinedByString:@"\n"];

    NSAlert *a = [[NSAlert alloc] init];
    a.alertStyle = NSAlertStyleWarning;
    a.messageText = RLPTr(@"这次测量会真的出声");
    NSMutableString *info = [NSMutableString string];
    if (warning.length) [info appendFormat:@"%@\n\n", warning];
    [info appendString:[lines componentsJoinedByString:@"\n"]];
    a.informativeText = info;
    [a addButtonWithTitle:RLPTr(@"确认开始测量")];
    [a addButtonWithTitle:RLPTr(@"取消")];
    if ([a runModal] != NSAlertFirstButtonReturn) {
        self.status.stringValue = RLPTr(@"已取消（未出声）");
        return;
    }
    [self startMeasure];
}

- (void)startMeasure {
    NSDictionary *p = self.plan;
    if (!p) return;
    NSString *lay = [p[@"layout"] isKindOfClass:[NSString class]] ? p[@"layout"] : @"2.0";
    const double sweep = [p[@"sweepSeconds"] respondsToSelector:@selector(doubleValue)] ? [p[@"sweepSeconds"] doubleValue] : 6;
    // confirm=1 是后端要求的出声许可，不能省
    NSString *url = [NSString stringWithFormat:@"/api/roomcorr/measure?layout=%@&sec=%.3f&confirm=1",
                     RLPEnc(lay), sweep];
    self.status.stringValue = RLPTr(@"测量进行中…");
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"测量失败");
            self_.status.stringValue = err;
            RLPToast(err);
            return;
        }
        self_.status.stringValue = RLPTr(@"测量已开始，可用「取消测量」中止");
    }];
}

- (void)onCancelMeasure:(id)sender {
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/roomcorr/cancel" body:nil completion:^(NSDictionary * _Nullable json) {
        (void)json;
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        self_.status.stringValue = RLPTr(@"已请求取消");
    }];
}

#pragma mark - 麦克风校准（U4）

/// 状态唯一来源 = GET /api/miccal。导入/清除成功后同样回读，避免「界面说有 N 点、
/// 后端其实没换表」这种自欺。
- (void)refreshMicCalState {
    if (![RLPCoreClient shared].started) {
        self.micCalNote.stringValue = RLPTr(@"核心未启动");
        return;
    }
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/miccal" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue] || ![json[@"active"] boolValue]) {
            self_.micCalNote.stringValue = RLPTr(@"未导入");
            self_.micCalNote.toolTip = nil;
            return;
        }
        const NSInteger n = [json[@"n_points"] respondsToSelector:@selector(integerValue)]
                                ? [json[@"n_points"] integerValue] : 0;
        const double mn = [json[@"min_db"] respondsToSelector:@selector(doubleValue)]
                              ? [json[@"min_db"] doubleValue] : 0.0;
        const double mx = [json[@"max_db"] respondsToSelector:@selector(doubleValue)]
                              ? [json[@"max_db"] doubleValue] : 0.0;
        self_.micCalNote.stringValue =
            [NSString stringWithFormat:RLPTr(@"%ld 点 / %+.1f ~ %+.1f dB"), (long)n, mn, mx];
        // 2026-11-16（评审 P0-3）：后端如实回 wired=false（校准表导入了，但生产链路还没有
        // 调用 build_corrections）⟹ 不在界面上假装它已经参与校正。提示文案由后端给
        //（wired_note），这里只负责显示，不新增 RLPTr 中文串。
        NSString *wiredNote = [json[@"wired_note"] isKindOfClass:[NSString class]]
                                  ? json[@"wired_note"] : nil;
        if (json[@"wired"] && ![json[@"wired"] boolValue] && wiredNote.length)
            self_.micCalNote.stringValue =
                [self_.micCalNote.stringValue stringByAppendingFormat:@" · %@", wiredNote];
        NSString *path = [json[@"path"] isKindOfClass:[NSString class]] ? json[@"path"] : @"";
        self_.micCalNote.toolTip = path.length ? path : nil;
    }];
}

- (void)onImportMicCal:(id)sender {
    if (![RLPCoreClient shared].started) { RLPToast(RLPTr(@"核心未启动")); return; }
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseFiles = YES;
    p.canChooseDirectories = NO;
    p.allowsMultipleSelection = NO;
    if (@available(macOS 11.0, *)) {
        p.allowedContentTypes = @[];
    }
    p.allowedFileTypes = @[ @"txt", @"csv" ];   // 只选文本校准文件（UMIK / REW 导出）
    p.message = RLPTr(@"选择麦克风校准文件");
    __weak __typeof__(self) weakSelf = self;
    [p beginWithCompletionHandler:^(NSModalResponse r) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || r != NSModalResponseOK || !p.URL.path.length) return;
        NSString *url = [NSString stringWithFormat:@"/api/miccal?path=%@", RLPEnc(p.URL.path)];
        self_.micCalNote.stringValue = RLPTr(@"导入中…");
        [[RLPCoreClient shared] postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
            __typeof__(self) self2 = weakSelf;
            if (!self2) return;
            if (json && [json[@"ok"] boolValue]) {
                [self2 refreshMicCalState];
                return;
            }
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]]
                                ? json[@"error"] : RLPTr(@"导入失败");
            self2.micCalNote.stringValue = err;
            RLPToast(err);
        }];
    }];
}

- (void)onClearMicCal:(id)sender {
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/miccal?clear=1" body:nil
                           completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            [self_ refreshMicCalState];
            return;
        }
        NSString *err = [json[@"error"] isKindOfClass:[NSString class]]
                            ? json[@"error"] : RLPTr(@"清除失败");
        self_.micCalNote.stringValue = err;
        RLPToast(err);
    }];
}

#pragma mark - 校正 IR

- (void)onPickIR:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseFiles = YES;
    p.canChooseDirectories = NO;
    p.allowsMultipleSelection = NO;
    if ([p runModal] != NSModalResponseOK || !p.URL) return;
    self.irPath.stringValue = p.URL.path ?: @"";
}

- (void)onApplyIR:(id)sender {
    NSString *path = [self.irPath.stringValue stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [self postSetting:@"ir" value:path];
}

- (void)onIrGpu:(id)sender {
    [self postSetting:@"irgpu" value:(self.irGpu.state == NSControlStateValueOn ? @"1" : @"0")];
}

- (void)postSetting:(NSString *)key value:(NSString *)value {
    if (![RLPCoreClient shared].started) return;
    NSString *body = [NSString stringWithFormat:@"%@=%@", key, RLPEnc(value ?: @"")];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/settings" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            self_.irStatus.stringValue = RLPTr(@"已保存");
            RLPToast(RLPTr(@"已保存"));
        } else {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"保存失败");
            self_.irStatus.stringValue = err;
        }
    }];
}

#pragma mark - 数据与主题

- (void)reload {
    if (![RLPCoreClient shared].started) {
        self.status.stringValue = RLPTr(@"核心未启动");
        return;
    }
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/settings" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSDictionary *kv = [json[@"kv"] isKindOfClass:[NSDictionary class]] ? json[@"kv"] : nil;
        if (!kv) return;
        NSString *ir = [kv[@"ir"] isKindOfClass:[NSString class]] ? kv[@"ir"] : @"";
        self_.irPath.stringValue = ir;
        id g = kv[@"irgpu"];
        if ([g respondsToSelector:@selector(boolValue)])
            self_.irGpu.state = [g boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    }];
    [[RLPCoreClient shared] getJSON:@"/api/roomcorr/status" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        const BOOL running = [json[@"running"] respondsToSelector:@selector(boolValue)] && [json[@"running"] boolValue];
        if (running) self_.status.stringValue = RLPTr(@"测量进行中…");
    }];
    // U4：校准表状态同样走现有 reload（页面重建/嵌入设置页时一起刷新）
    [self refreshMicCalState];
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.status.textColor = t.mut;
    self.planInfo.textColor = t.mut;
    self.micCalNote.textColor = t.mut;
}

@end
