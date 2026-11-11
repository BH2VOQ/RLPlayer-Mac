// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPQuickStartViewController.mm — 快速开始（原生首页）
//
// 三段的真相源（全部来自既有后端，UI 不发明第二套）：
//   ① 三张能力卡：音乐库状态来自 /api/lib/roots（有根 ⟹ "目录已就绪"）。
//   ② 官方推荐预设：**端点与取值都以 rtaweb 为准**
//        GET  /api/preset/caps            → {"ok":true,"device":{…},"readonly":true,"notes":[…]}
//        POST /api/preset/apply?profile=  → profile ∈ bitperfect | pcm | dsd | pcm2dsd
//      （2026-11-11 核实：不是 name=，也没有 conservative/balanced/aggressive/max 这四档 ——
//       那四档是另一套"决策档位"的内部概念，从未作为 API 取值存在。）
//   ③ 四个快捷入口：如实跳转到设置页对应页签，不发不存在的通知。
#import "RLPQuickStartViewController.h"
#import "RLPCoreClient.h"
#import "RLPSettingsViewController.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

/// 预设档位（与 src/engine/preset_profiles.h 的 PresetProfile 规范名一一对应）。
static NSString *const kPresetKeys[] = { @"bitperfect", @"pcm", @"dsd", @"pcm2dsd" };

@interface RLPQuickStartViewController ()
@property (nonatomic, strong) NSStackView *stack;
@property (nonatomic, strong) NSTextField *libDesc;      // 卡 1 的说明文字
@property (nonatomic, strong) NSButton *libButton;       // 卡 1 的按钮
@property (nonatomic, strong) NSPopUpButton *presetPopup;
@property (nonatomic, strong) NSButton *presetApply;
@property (nonatomic, strong) NSTextField *presetStatus;
@property (nonatomic, strong) NSTextField *deviceLine;   // 预设卡上的设备摘要
@property (nonatomic, assign) BOOL hasRoots;
/// /api/preset/caps 读到的目标采样率表（用于给用户看清"这台设备能到多少"）
@property (nonatomic, copy) NSString *capsSummary;
@end

@implementation RLPQuickStartViewController

- (instancetype)init { return [super initWithTitle:RLPTr(@"快速开始")]; }

#pragma mark - 骨架

- (void)buildContent {
    NSView *host = self.contentView;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:scroll];

    self.stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.stack.alignment = NSLayoutAttributeLeading;
    self.stack.spacing = 16;
    self.stack.edgeInsets = NSEdgeInsetsMake(8, 24, 24, 24);
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = self.stack;

    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:host.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
        [self.stack.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [self.stack.trailingAnchor constraintEqualToAnchor:scroll.contentView.trailingAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [self.stack.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
    ]];

    [self buildCapabilityCards];
    [self buildPresetCard];
    [self buildQuickEntries];
}

#pragma mark - ① 三张能力卡

- (NSView *)cardWithBadge:(NSString *)badge
                    title:(NSString *)title
                     desc:(NSTextField *)desc
                   button:(NSButton *)button {
    RLPTheme *t = [RLPTheme current];
    NSView *card = [[NSView alloc] initWithFrame:NSZeroRect];
    card.wantsLayer = YES;
    card.layer.cornerRadius = 12;
    card.layer.backgroundColor = t.bg2.CGColor;
    card.layer.borderWidth = 1;
    card.layer.borderColor = t.line.CGColor;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *badgeLabel = RLPLabel(badge, t.small, t.mut);
    badgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *titleLabel = RLPLabel(title, [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold], t.text);
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    desc.translatesAutoresizingMaskIntoConstraints = NO;
    desc.maximumNumberOfLines = 2;
    desc.lineBreakMode = NSLineBreakByWordWrapping;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.bezelStyle = NSBezelStyleRounded;

    [card addSubview:badgeLabel];
    [card addSubview:titleLabel];
    [card addSubview:desc];
    [card addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [badgeLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [badgeLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [titleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [titleLabel.topAnchor constraintEqualToAnchor:badgeLabel.bottomAnchor constant:8],
        [desc.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [desc.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [desc.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:8],
        [button.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [button.topAnchor constraintEqualToAnchor:desc.bottomAnchor constant:12],
        [button.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
        [card.heightAnchor constraintGreaterThanOrEqualToConstant:170],
    ]];
    return card;
}

- (void)buildCapabilityCards {
    RLPTheme *t = [RLPTheme current];

    NSView *row = [[NSView alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    // 卡 1：无损音乐库
    self.libDesc = RLPLabel(@"", t.small, t.mut);
    self.libButton = [NSButton buttonWithTitle:RLPTr(@"添加音乐目录")
                                        target:self
                                        action:@selector(onLibraryAction:)];
    NSView *c1 = [self cardWithBadge:@"Hi-Fi Library"
                               title:RLPTr(@"无损音乐库")
                                desc:self.libDesc
                              button:self.libButton];

    // 卡 2：独占直通引擎
    NSTextField *d2 = RLPLabel(RLPTr(@"Bit-Perfect 硬件独占 · 自动跟随源采样率 · DoP / SDM 调制器"),
                               t.small, t.mut);
    NSButton *b2 = [NSButton buttonWithTitle:RLPTr(@"配置输出设备") target:self
                                      action:@selector(onGoOutput:)];
    NSView *c2 = [self cardWithBadge:@"CoreAudio · Hog Mode"
                               title:RLPTr(@"独占直通引擎") desc:d2 button:b2];

    // 卡 3：PEQ 与 OPRA
    NSTextField *d3 = RLPLabel(RLPTr(@"内置 6200+ 款耳机 OPRA 目标曲线 · 卷积房间校正 IR · 响度分析"),
                               t.small, t.mut);
    NSButton *b3 = [NSButton buttonWithTitle:RLPTr(@"打开均衡与校正") target:self
                                      action:@selector(onGoEq:)];
    NSView *c3 = [self cardWithBadge:@"DSP · 64-Bit Float"
                               title:RLPTr(@"20 段 PEQ 与 OPRA") desc:d3 button:b3];

    for (NSView *c in @[ c1, c2, c3 ]) [row addSubview:c];
    [self.stack addArrangedSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [row.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48],
        [c1.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [c1.topAnchor constraintEqualToAnchor:row.topAnchor],
        [c1.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [c2.leadingAnchor constraintEqualToAnchor:c1.trailingAnchor constant:14],
        [c2.topAnchor constraintEqualToAnchor:row.topAnchor],
        [c2.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [c3.leadingAnchor constraintEqualToAnchor:c2.trailingAnchor constant:14],
        [c3.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [c3.topAnchor constraintEqualToAnchor:row.topAnchor],
        [c3.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [c2.widthAnchor constraintEqualToAnchor:c1.widthAnchor],
        [c3.widthAnchor constraintEqualToAnchor:c1.widthAnchor],
    ]];
}

#pragma mark - ② 官方推荐预设

- (void)buildPresetCard {
    RLPTheme *t = [RLPTheme current];
    NSView *card = [[NSView alloc] initWithFrame:NSZeroRect];
    card.wantsLayer = YES;
    card.layer.cornerRadius = 12;
    card.layer.backgroundColor = t.bg2.CGColor;
    card.layer.borderWidth = 1;
    card.layer.borderColor = t.line.CGColor;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *title = RLPLabel(RLPTr(@"官方推荐预设"),
        [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], t.text);
    title.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *desc = RLPLabel(RLPTr(@"一键把输出链路调到合适档位；改动会写入设置并立即生效"),
        t.small, t.mut);
    desc.translatesAutoresizingMaskIntoConstraints = NO;

    self.presetPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    // 四个规范名，与 preset_profiles.h 一一对应（顺序也照它的枚举）
    [self.presetPopup addItemWithTitle:RLPTr(@"原音直通（PCM 直出 / DSD 直通）")];
    [self.presetPopup addItemWithTitle:RLPTr(@"PCM → PCM 升频")];
    [self.presetPopup addItemWithTitle:RLPTr(@"DSD → DSD 升频")];
    [self.presetPopup addItemWithTitle:RLPTr(@"PCM → DSD")];
    self.presetPopup.translatesAutoresizingMaskIntoConstraints = NO;
    [[self.presetPopup.widthAnchor constraintEqualToConstant:260] setActive:YES];

    self.presetApply = [NSButton buttonWithTitle:RLPTr(@"一键应用") target:self
                                          action:@selector(onApplyPreset:)];
    self.presetApply.bezelStyle = NSBezelStyleRounded;
    self.presetApply.translatesAutoresizingMaskIntoConstraints = NO;

    self.presetStatus = RLPLabel(@"", t.small, t.mut);
    self.presetStatus.translatesAutoresizingMaskIntoConstraints = NO;
    self.presetStatus.maximumNumberOfLines = 2;
    self.presetStatus.lineBreakMode = NSLineBreakByWordWrapping;

    self.deviceLine = RLPLabel(@"", t.small, t.mut);
    self.deviceLine.translatesAutoresizingMaskIntoConstraints = NO;
    self.deviceLine.maximumNumberOfLines = 2;
    self.deviceLine.lineBreakMode = NSLineBreakByWordWrapping;

    for (NSView *v in @[ title, desc, self.presetPopup, self.presetApply,
                         self.deviceLine, self.presetStatus ])
        [card addSubview:v];

    [self.stack addArrangedSubview:card];
    [NSLayoutConstraint activateConstraints:@[
        [card.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [desc.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [desc.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [desc.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [self.presetPopup.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.presetPopup.topAnchor constraintEqualToAnchor:desc.bottomAnchor constant:12],
        [self.presetApply.leadingAnchor constraintEqualToAnchor:self.presetPopup.trailingAnchor constant:10],
        [self.presetApply.centerYAnchor constraintEqualToAnchor:self.presetPopup.centerYAnchor],
        [self.deviceLine.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.deviceLine.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [self.deviceLine.topAnchor constraintEqualToAnchor:self.presetPopup.bottomAnchor constant:10],
        [self.presetStatus.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.presetStatus.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [self.presetStatus.topAnchor constraintEqualToAnchor:self.deviceLine.bottomAnchor constant:6],
        [self.presetStatus.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
    ]];
}

#pragma mark - ③ 四个快捷入口

- (void)buildQuickEntries {
    RLPTheme *t = [RLPTheme current];
    NSArray<NSArray<NSString *> *> *items = @[
        @[ @"folder",        RLPTr(@"设置文件夹位置"),   @"adv" ],
        @[ @"cloud",         RLPTr(@"挂载流媒体服务"),   @"stream" ],
        @[ @"sparkles",      RLPTr(@"AI 资料与封面补全"), @"meta" ],
        @[ @"mic",           RLPTr(@"音频输入采集"),     @"in" ],
    ];
    NSStackView *row = [[NSStackView alloc] init];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 10;
    row.distribution = NSStackViewDistributionFillEqually;
    row.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSArray<NSString *> *it in items) {
        NSButton *b = [NSButton buttonWithTitle:it[1] target:self action:@selector(onQuickEntry:)];
        b.bezelStyle = NSBezelStyleRounded;
        b.image = [NSImage imageWithSystemSymbolName:it[0] accessibilityDescription:it[1]];
        b.imagePosition = NSImageLeading;
        b.identifier = it[2];   // 目标页签 key
        b.font = t.body;
        [row addArrangedSubview:b];
    }
    [self.stack addArrangedSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48],
    ]];
}

#pragma mark - 动作

- (void)onLibraryAction:(id)sender {
    if (self.hasRoots) {
        RLPPostJSON(@"/api/lib/scan?full=1", nil);
        RLPToast(RLPTr(@"已开始全量重扫"));
    } else {
        [self openSettingsTab:@"adv"];
    }
}

- (void)onGoOutput:(id)sender { [self openSettingsTab:@"out"]; }
- (void)onGoEq:(id)sender { [self openSettingsTab:@"eq"]; }

- (void)onQuickEntry:(NSButton *)sender {
    [self openSettingsTab:sender.identifier];
}

/// 跳到设置页对应页签：走通知（主窗口负责切到设置行并选中页签），
/// 页面之间不互相持有实例。
- (void)openSettingsTab:(NSString *)key {
    if (!key.length) return;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenSettingsPaneNotification"
                                                        object:key];
}

- (void)onApplyPreset:(id)sender {
    const NSInteger idx = self.presetPopup.indexOfSelectedItem;
    if (idx < 0 || idx > 3) return;
    NSString *profile = kPresetKeys[idx];
    self.presetApply.enabled = NO;
    self.presetStatus.stringValue = RLPTr(@"正在应用…");

    NSString *path = [NSString stringWithFormat:@"/api/preset/apply?profile=%@", RLPEnc(profile)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:path body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        self_.presetApply.enabled = YES;
        if (json && [json[@"ok"] boolValue]) {
            // notes 是后端给的决策说明（为什么这么设），照实显示 —— 不自己编"已优化"。
            NSArray *notes = [json[@"notes"] isKindOfClass:[NSArray class]] ? json[@"notes"] : @[];
            NSString *noteText = notes.count ? [notes componentsJoinedByString:@"；"] : @"";
            self_.presetStatus.stringValue = noteText.length
                ? [NSString stringWithFormat:@"%@ %@", RLPTr(@"已应用 ·"), noteText]
                : RLPTr(@"已应用");
            RLPToast(RLPTr(@"预设已应用"));
        } else {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"]
                                                                          : RLPTr(@"应用失败");
            self_.presetStatus.stringValue = err;
            RLPToast(err);
        }
    }];
}

#pragma mark - 数据

- (void)activate { [self reloadData]; }

- (void)reloadData {
    if (![RLPCoreClient shared].started) {
        self.presetStatus.stringValue = RLPTr(@"核心未启动");
        return;
    }
    __weak __typeof__(self) weakSelf = self;

    [[RLPCoreClient shared] getJSON:@"/api/lib/roots" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *roots = [json[@"roots"] isKindOfClass:[NSArray class]] ? json[@"roots"] : @[];
        self_.hasRoots = roots.count > 0;
        self_.libDesc.stringValue = self_.hasRoots
            ? RLPTr(@"目录已就绪 · 点击重新扫描建立专辑与封面索引")
            : RLPTr(@"支持 FLAC · DSD (DSF/DFF) · ALAC · WAV · APE · 多碟盒装自动聚合");
        [self_.libButton setTitle:self_.hasRoots ? RLPTr(@"重新扫描音乐库")
                                                 : RLPTr(@"添加音乐目录")];
    }];

    // 预设能力：只读探测（后端不开流、不抢设备）。读不到就把按钮禁用并说明，不填假数据。
    [[RLPCoreClient shared] getJSON:@"/api/preset/caps" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSDictionary *dev = [json[@"device"] isKindOfClass:[NSDictionary class]] ? json[@"device"] : nil;
        if (!dev) {
            self_.presetApply.enabled = NO;
            self_.deviceLine.stringValue = RLPTr(@"预设能力读取失败：请检查输出设备");
            return;
        }
        self_.presetApply.enabled = YES;
        NSString *name = [dev[@"name"] isKindOfClass:[NSString class]] ? dev[@"name"] : RLPTr(@"未知设备");
        NSArray *rates = [dev[@"rates"] isKindOfClass:[NSArray class]] ? dev[@"rates"] : @[];
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        [parts addObject:name];
        if (rates.count) {
            id maxRate = rates.lastObject;
            [parts addObject:[NSString stringWithFormat:@"%@ %@ Hz", RLPTr(@"最高"), maxRate]];
        }
        if ([dev[@"dop"] boolValue]) [parts addObject:@"DoP"];
        if ([dev[@"dsdNative"] boolValue]) [parts addObject:RLPTr(@"DSD 原生")];
        if ([dev[@"exclusive"] boolValue]) [parts addObject:RLPTr(@"可独占")];
        self_.deviceLine.stringValue = [parts componentsJoinedByString:@" · "];
    }];
}

#pragma mark - 主题

- (void)applyTheme {
    [super applyTheme];
    RLPTheme *t = [RLPTheme current];
    // 卡片的圆角底/边框是 layer 颜色，不会自动跟随主题：重扫一遍已建视图。
    for (NSView *v in self.stack.arrangedSubviews) {
        if (!v.wantsLayer || v.layer.cornerRadius <= 0) continue;
        v.layer.backgroundColor = t.bg2.CGColor;
        v.layer.borderColor = t.line.CGColor;
    }
    self.libDesc.textColor = t.mut;
    self.presetStatus.textColor = t.mut;
    self.deviceLine.textColor = t.mut;
}

@end
