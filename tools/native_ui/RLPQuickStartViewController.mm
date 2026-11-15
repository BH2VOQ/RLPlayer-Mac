// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPQuickStartViewController.mm — 聆听室（1.1.7.1 合并页）
//
// 用户要求（逐条对应）：
//   ① 聆听室与快速开始**合并成一页**（不再是两个模块）。
//   ② 页内设置**全部用卡片式弹层就地完成**，不跳设置页。
//   ③ 这一页能直接做：当前设备下拉切换 / 输出（含独占）/ 播放三档 / 听音风格。
//   ④ 侧栏始终有「设置」入口（双模式拆掉后不再有「某模式没有设置」的情形）。
//
// 面向"只想安静听歌的人"：文案说人话，滤波真名只作副标题小字。
// 真相源全部来自既有后端，UI 不发明第二套状态：
//   /api/devices /api/settings /api/filters /api/preset/apply /api/status /api/queue /api/lib/*
#import "RLPQuickStartViewController.h"
#import "RLPCoreClient.h"
#import "RLPListeningRoom.h"
#import "RLPModels.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

@interface RLPQuickStartViewController ()
@property (nonatomic, strong) NSStackView *stack;
// 四张卡
@property (nonatomic, strong) NSView *deviceCard;
@property (nonatomic, strong) NSView *outputCard;
@property (nonatomic, strong) NSView *playCard;
@property (nonatomic, strong) NSView *styleCard;
@property (nonatomic, strong) NSPopUpButton *devicePopup;
@property (nonatomic, strong) NSTextField *outputValue;
@property (nonatomic, strong) NSTextField *playValue;
@property (nonatomic, strong) NSTextField *styleValue;
@property (nonatomic, strong) NSTextField *styleSub;
// 卡片小标题与分区标题：必须在 applyTheme 里重刷颜色。它们是 RLPLabel 建出来的一次性标签，
// 漏刷就停在旧主题的灰上 —— 浅底配深灰几乎看不见字（本轮实测到的真故障）。
@property (nonatomic, strong) NSTextField *deviceCaption;
@property (nonatomic, strong) NSTextField *outputCaption;
@property (nonatomic, strong) NSTextField *playCaption;
@property (nonatomic, strong) NSTextField *styleCaption;
@property (nonatomic, strong) NSTextField *queueCaption;
@property (nonatomic, strong) NSTextField *albumCaption;
// 动态建出来的标签（队列行 / 专辑名 / 空态）登记在这里，主题切换时一并重刷。
@property (nonatomic, strong) NSMutableArray<NSTextField *> *dynamicLabels;
@property (nonatomic, strong) NSTextField *presetNotes;
// 正在播放 / 队列 / 专辑
@property (nonatomic, strong) NSImageView *npCover;
@property (nonatomic, strong) NSTextField *npTitle;
@property (nonatomic, strong) NSTextField *npSub;
@property (nonatomic, strong) NSTextField *npState;
@property (nonatomic, strong) NSButton *npToggle;
@property (nonatomic, strong) NSStackView *queueList;
@property (nonatomic, strong) NSStackView *albumRow;
@property (nonatomic, strong) NSButton *libButton;
@property (nonatomic, strong) NSTextField *libDesc;
// 数据缓存（全部来自后端）
@property (nonatomic, copy) NSArray<NSDictionary *> *devices;
@property (nonatomic, copy) NSArray<NSDictionary *> *filters;
@property (nonatomic, copy) NSDictionary *settings;
@property (nonatomic, copy) NSString *currentPath;
@property (nonatomic, assign) BOOL hasRoots;
@property (nonatomic, assign) BOOL playing;
/// v3.3.11 `rlApplyDailyPreset` 用 `S.playing||S.paused` 判定「请先停止播放」——
/// `playing` 已经是 `st.playing && !st.paused`，暂停态必须单独记一个，否则暂停时会被当成"可以应用"。
@property (nonatomic, assign) BOOL pausedNow;
@property (nonatomic, strong) NSPopover *popover;
@property (nonatomic, assign) NSUInteger coverSeq;
@property (nonatomic, strong) NSTimer *poll;
@end

// v3.3.11 `quickStartModel` 的三项能力结论（`/api/preset/caps` 的真实响应派生）。
// 为什么必须真的用起来：只把 caps 拉下来再丢掉，等于「能力探测」是个装饰品 ——
// 用户点「DSD 升频」会得到后端 `notes` 里的降级说明，但他事先看不到按钮为什么不该点。
@interface RLPQuickStartViewController (RLPPresetCapsState)
@property (nonatomic, assign) BOOL presetCapsKnown;
@property (nonatomic, assign) BOOL presetPcmReady;
@property (nonatomic, assign) BOOL presetDsdReady;
@property (nonatomic, copy, nullable) NSString *presetCapsDevice;
@end

@implementation RLPQuickStartViewController

- (instancetype)init {
    self = [super initWithTitle:RLPTr(@"聆听室")];
    if (self) {
        _dynamicLabels = [NSMutableArray array];
    }
    return self;
}

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
    self.stack.spacing = 14;
    self.stack.edgeInsets = NSEdgeInsetsMake(4, 24, 20, 24);
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = self.stack;

    // ⚠️ documentView **只钉 leading/trailing/top/width，不钉 bottom**：
    // 钉了 bottom 会把纵向 stack 拉伸到填满可视高度，卡片之间被撑出大片空白
    // （本轮离屏截图实测到的真缺陷：标题与首卡之间约 200px 空白）。
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

    RLPTheme *t = [RLPTheme current];
    NSTextField *title = RLPLabel(RLPTr(@"聆听室"), t.display, t.hero);
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.tag = 0;   // 0=正文（applyTheme 里按 t.text 重刷）
    NSTextField *subtitle = RLPLabel(RLPTr(@"微调每一组声音，随时对比同一片段"), t.body, t.mut);
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.tag = 1;   // 1=次要（t.mut）
    // 登记到 dynamicLabels：切主题时这两个常驻标签也要跟着重刷（A6 判据会抓漏刷）。
    [self.dynamicLabels addObject:title];
    [self.dynamicLabels addObject:subtitle];
    [self.stack addArrangedSubview:title];
    [self.stack addArrangedSubview:subtitle];

    [self buildFourCards];
    [self buildNowPlayingAndQueue];
    [self buildAlbumRow];
    [self buildLibraryCard];
}

/// 卡片外壳（圆角 + 边框，颜色在 applyTheme 里重刷）。
- (NSView *)cardWithIdentifier:(NSString *)ident {
    RLPTheme *t = [RLPTheme current];
    NSView *c = [[NSView alloc] initWithFrame:NSZeroRect];
    c.identifier = ident;
    c.wantsLayer = YES;
    c.layer.cornerRadius = t.rMd;
    c.layer.backgroundColor = t.bg2.CGColor;
    c.layer.borderWidth = 1;
    c.layer.borderColor = t.line.CGColor;
    c.translatesAutoresizingMaskIntoConstraints = NO;
    return c;
}

#pragma mark - ① 四张卡

- (void)buildFourCards {
    RLPTheme *t = [RLPTheme current];
    NSView *row = [[NSView alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    // ---- 卡 1：当前设备（就地下拉切换）----
    self.deviceCard = [self cardWithIdentifier:@"room.device"];
    self.deviceCaption = RLPLabel(RLPTr(@"当前设备"), t.small, t.mut);
    NSTextField *d1 = self.deviceCaption;
    d1.translatesAutoresizingMaskIntoConstraints = NO;
    self.devicePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.devicePopup.translatesAutoresizingMaskIntoConstraints = NO;
    self.devicePopup.target = self;
    self.devicePopup.action = @selector(onDeviceChanged:);
    self.devicePopup.font = t.body;
    [self.devicePopup addItemWithTitle:RLPTr(@"系统默认")];
    NSButton *devRefresh = RLPSymbolButton(@"arrow.clockwise", RLPTr(@"重新检测设备"), self, @selector(onReloadDevices:));
    devRefresh.translatesAutoresizingMaskIntoConstraints = NO;
    [self.deviceCard addSubview:d1];
    [self.deviceCard addSubview:self.devicePopup];
    [self.deviceCard addSubview:devRefresh];

    // ---- 卡 2：输出（弹层）----
    self.outputCard = [self cardWithIdentifier:@"room.output"];
    self.outputCaption = RLPLabel(RLPTr(@"输出"), t.small, t.mut);
    NSTextField *d2 = self.outputCaption;
    d2.translatesAutoresizingMaskIntoConstraints = NO;
    self.outputValue = RLPLabel(RLPTr(@"读取中…"), t.body, t.text);
    self.outputValue.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *outBtn = [NSButton buttonWithTitle:@"" target:self action:@selector(onOpenOutput:)];
    outBtn.bordered = NO;
    outBtn.translatesAutoresizingMaskIntoConstraints = NO;
    outBtn.toolTip = RLPTr(@"点击选择输出方式");
    [self.outputCard addSubview:d2];
    [self.outputCard addSubview:self.outputValue];
    [self.outputCard addSubview:outBtn];

    // ---- 卡 3：播放（三档，弹层）----
    self.playCard = [self cardWithIdentifier:@"room.play"];
    self.playCaption = RLPLabel(RLPTr(@"播放"), t.small, t.mut);
    NSTextField *d3 = self.playCaption;
    d3.translatesAutoresizingMaskIntoConstraints = NO;
    self.playValue = RLPLabel(RLPTr(@"原音直通"), t.body, t.text);
    self.playValue.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *playBtn = [NSButton buttonWithTitle:@"" target:self action:@selector(onOpenPlay:)];
    playBtn.bordered = NO;
    playBtn.translatesAutoresizingMaskIntoConstraints = NO;
    playBtn.toolTip = RLPTr(@"点击选择播放方式");
    [self.playCard addSubview:d3];
    [self.playCard addSubview:self.playValue];
    [self.playCard addSubview:playBtn];

    // ---- 卡 4：听音风格（新增，弹层）----
    self.styleCard = [self cardWithIdentifier:@"room.style"];
    self.styleCaption = RLPLabel(RLPTr(@"听音风格"), t.small, t.mut);
    NSTextField *d4 = self.styleCaption;
    d4.translatesAutoresizingMaskIntoConstraints = NO;
    self.styleValue = RLPLabel(RLPTr(@"均衡自然"), t.body, t.text);
    self.styleValue.translatesAutoresizingMaskIntoConstraints = NO;
    self.styleSub = RLPLabel(@"", t.small, t.mut);
    self.styleSub.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *styleBtn = [NSButton buttonWithTitle:@"" target:self action:@selector(onOpenStyle:)];
    styleBtn.bordered = NO;
    styleBtn.translatesAutoresizingMaskIntoConstraints = NO;
    styleBtn.toolTip = RLPTr(@"点击选择听感风格");
    [self.styleCard addSubview:d4];
    [self.styleCard addSubview:self.styleValue];
    [self.styleCard addSubview:self.styleSub];
    [self.styleCard addSubview:styleBtn];

    for (NSView *c in @[self.deviceCard, self.outputCard, self.playCard, self.styleCard])
        [row addSubview:c];
    [self.stack addArrangedSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [row.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48],
        [row.heightAnchor constraintEqualToConstant:100],
        [self.deviceCard.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [self.deviceCard.widthAnchor constraintEqualToAnchor:row.widthAnchor multiplier:0.24],
        [self.deviceCard.topAnchor constraintEqualToAnchor:row.topAnchor],
        [self.deviceCard.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        
        [self.outputCard.leadingAnchor constraintEqualToAnchor:self.deviceCard.trailingAnchor constant:12],
        [self.outputCard.widthAnchor constraintEqualToAnchor:self.deviceCard.widthAnchor],
        [self.outputCard.topAnchor constraintEqualToAnchor:row.topAnchor],
        [self.outputCard.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],

        [self.playCard.leadingAnchor constraintEqualToAnchor:self.outputCard.trailingAnchor constant:12],
        [self.playCard.widthAnchor constraintEqualToAnchor:self.deviceCard.widthAnchor],
        [self.playCard.topAnchor constraintEqualToAnchor:row.topAnchor],
        [self.playCard.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],

        [self.styleCard.leadingAnchor constraintEqualToAnchor:self.playCard.trailingAnchor constant:12],
        [self.styleCard.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [self.styleCard.topAnchor constraintEqualToAnchor:row.topAnchor],
        [self.styleCard.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
    ]];

    // 行级几何（等宽一行、加高卡片）已在上面 activateConstraints 统一设定，
    // 这里只放**卡内**布局，不再重复 row.width/height 与四卡 leading/width（重复会冲突）。
    NSMutableArray *cs = [NSMutableArray array];
    // 卡内布局
    [cs addObjectsFromArray:@[
        [d1.leadingAnchor constraintEqualToAnchor:self.deviceCard.leadingAnchor constant:14],
        [d1.topAnchor constraintEqualToAnchor:self.deviceCard.topAnchor constant:10],
        [self.devicePopup.leadingAnchor constraintEqualToAnchor:self.deviceCard.leadingAnchor constant:10],
        [self.devicePopup.topAnchor constraintEqualToAnchor:d1.bottomAnchor constant:4],
        [self.devicePopup.trailingAnchor constraintEqualToAnchor:devRefresh.leadingAnchor constant:-4],
        [devRefresh.trailingAnchor constraintEqualToAnchor:self.deviceCard.trailingAnchor constant:-10],
        [devRefresh.centerYAnchor constraintEqualToAnchor:self.devicePopup.centerYAnchor],
        [devRefresh.widthAnchor constraintEqualToConstant:22],
    ]];
    NSArray *pairs = @[@[d2, self.outputValue, self.outputCard, outBtn],
                       @[d3, self.playValue, self.playCard, playBtn],
                       @[d4, self.styleValue, self.styleCard, styleBtn]];
    for (NSArray *p in pairs) {
        NSTextField *lab = p[0], *val = p[1];
        NSView *card = p[2]; NSButton *btn = p[3];
        [cs addObjectsFromArray:@[
            [lab.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
            [lab.topAnchor constraintEqualToAnchor:card.topAnchor constant:10],
            [val.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
            [val.topAnchor constraintEqualToAnchor:lab.bottomAnchor constant:6],
            [val.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
            // 整卡可点（透明按钮盖满），符合"卡片式"心智
            [btn.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
            [btn.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
            [btn.topAnchor constraintEqualToAnchor:card.topAnchor],
            [btn.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        ]];
    }
    [cs addObjectsFromArray:@[
        [self.styleSub.leadingAnchor constraintEqualToAnchor:self.styleCard.leadingAnchor constant:14],
        [self.styleSub.trailingAnchor constraintEqualToAnchor:self.styleCard.trailingAnchor constant:-14],
        [self.styleSub.topAnchor constraintEqualToAnchor:self.styleValue.bottomAnchor constant:2],
    ]];
    [NSLayoutConstraint activateConstraints:cs];

    // 预设说明（后端 notes 照实显示）
    self.presetNotes = RLPLabel(@"", t.small, t.mut);
    self.presetNotes.translatesAutoresizingMaskIntoConstraints = NO;
    self.presetNotes.maximumNumberOfLines = 2;
    self.presetNotes.lineBreakMode = NSLineBreakByWordWrapping;
    [self.stack addArrangedSubview:self.presetNotes];
    [[self.presetNotes.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48] setActive:YES];
}

#pragma mark - ② 正在播放 + 队列预览

- (void)buildNowPlayingAndQueue {
    RLPTheme *t = [RLPTheme current];
    NSView *row = [[NSView alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *np = [self cardWithIdentifier:@"room.nowplaying"];
    self.npCover = [[NSImageView alloc] initWithFrame:NSZeroRect];
    self.npCover.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.npCover.wantsLayer = YES;
    self.npCover.layer.cornerRadius = t.rSm;
    self.npCover.layer.masksToBounds = YES;
    self.npCover.layer.backgroundColor = t.bg3.CGColor;
    self.npCover.translatesAutoresizingMaskIntoConstraints = NO;
    [self showCoverPlaceholder];   // 第一帧就有音符占位，不闪空白方块
    self.npState = RLPLabel(RLPTr(@"未播放"), t.small, t.mut);
    self.npState.translatesAutoresizingMaskIntoConstraints = NO;
    self.npTitle = RLPLabel(RLPTr(@"还没有在播放的音乐"), t.serif, t.text);
    self.npTitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.npTitle.maximumNumberOfLines = 2;
    self.npTitle.lineBreakMode = NSLineBreakByWordWrapping;
    self.npSub = RLPLabel(RLPTr(@"从下面的专辑挑一张开始"), t.small, t.mut);
    self.npSub.translatesAutoresizingMaskIntoConstraints = NO;
    self.npToggle = [NSButton buttonWithTitle:RLPTr(@"继续播放") target:self action:@selector(onTogglePlay:)];
    self.npToggle.bezelStyle = NSBezelStyleRounded;
    self.npToggle.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *npOpen = [NSButton buttonWithTitle:RLPTr(@"打开曲目详情") target:self action:@selector(onOpenNowPlaying:)];
    npOpen.bezelStyle = NSBezelStyleRounded;
    npOpen.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *v in @[self.npCover, self.npState, self.npTitle, self.npSub, self.npToggle, npOpen])
        [np addSubview:v];

    NSView *qcard = [self cardWithIdentifier:@"room.queue"];
    self.queueCaption = RLPLabel(RLPTr(@"播放队列"), t.heading, t.text);
    self.queueCaption.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *qAll = [NSButton buttonWithTitle:RLPTr(@"查看全部") target:self action:@selector(onOpenQueue:)];
    qAll.bezelStyle = NSBezelStyleRounded;
    qAll.translatesAutoresizingMaskIntoConstraints = NO;
    self.queueList = [[NSStackView alloc] init];
    self.queueList.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.queueList.alignment = NSLayoutAttributeLeading;
    self.queueList.spacing = 6;
    self.queueList.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *v in @[self.queueCaption, qAll, self.queueList]) [qcard addSubview:v];

    [row addSubview:np];
    [row addSubview:qcard];
    [self.stack addArrangedSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [row.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48],
        [row.heightAnchor constraintEqualToConstant:240],
        [np.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [np.topAnchor constraintEqualToAnchor:row.topAnchor],
        [np.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [np.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-312],
        [qcard.leadingAnchor constraintEqualToAnchor:np.trailingAnchor constant:12],
        [qcard.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [qcard.topAnchor constraintEqualToAnchor:row.topAnchor],
        [qcard.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        
        [self.npCover.leadingAnchor constraintEqualToAnchor:np.leadingAnchor constant:20],
        [self.npCover.centerYAnchor constraintEqualToAnchor:np.centerYAnchor],
        [self.npCover.widthAnchor constraintEqualToConstant:200],
        [self.npCover.heightAnchor constraintEqualToConstant:200],

        // 右侧文字列：状态 → 大曲名 → 副标题 → 两个按钮（每个都必须显式定位，
        // 否则无约束控件全堆在 (0,0) 重叠成一团 —— 离屏截图实测到的真 bug）。
        [self.npState.leadingAnchor constraintEqualToAnchor:self.npCover.trailingAnchor constant:20],
        [self.npState.topAnchor constraintEqualToAnchor:np.topAnchor constant:34],
        [self.npState.trailingAnchor constraintLessThanOrEqualToAnchor:np.trailingAnchor constant:-20],
        [self.npTitle.leadingAnchor constraintEqualToAnchor:self.npState.leadingAnchor],
        [self.npTitle.trailingAnchor constraintEqualToAnchor:np.trailingAnchor constant:-20],
        [self.npTitle.topAnchor constraintEqualToAnchor:self.npState.bottomAnchor constant:8],
        [self.npSub.leadingAnchor constraintEqualToAnchor:self.npState.leadingAnchor],
        [self.npSub.trailingAnchor constraintEqualToAnchor:np.trailingAnchor constant:-20],
        [self.npSub.topAnchor constraintEqualToAnchor:self.npTitle.bottomAnchor constant:8],
        [self.npToggle.leadingAnchor constraintEqualToAnchor:self.npState.leadingAnchor],
        [self.npToggle.topAnchor constraintEqualToAnchor:self.npSub.bottomAnchor constant:16],
        [npOpen.leadingAnchor constraintEqualToAnchor:self.npToggle.trailingAnchor constant:10],
        [npOpen.centerYAnchor constraintEqualToAnchor:self.npToggle.centerYAnchor],

        [self.queueCaption.leadingAnchor constraintEqualToAnchor:qcard.leadingAnchor constant:14],
        [self.queueCaption.topAnchor constraintEqualToAnchor:qcard.topAnchor constant:14],
        [qAll.trailingAnchor constraintEqualToAnchor:qcard.trailingAnchor constant:-14],
        [qAll.centerYAnchor constraintEqualToAnchor:self.queueCaption.centerYAnchor],
        [self.queueList.leadingAnchor constraintEqualToAnchor:qcard.leadingAnchor constant:14],
        [self.queueList.trailingAnchor constraintEqualToAnchor:qcard.trailingAnchor constant:-14],
        [self.queueList.topAnchor constraintEqualToAnchor:self.queueCaption.bottomAnchor constant:10],
    ]];
}

#pragma mark - ③ 专辑行

- (void)buildAlbumRow {
    RLPTheme *t = [RLPTheme current];
    NSView *head = [[NSView alloc] initWithFrame:NSZeroRect];
    head.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *at = RLPLabel(RLPTr(@"专辑"), t.heading, t.text);
    self.albumCaption = at;
    at.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *openLib = [NSButton buttonWithTitle:RLPTr(@"打开音乐库") target:self action:@selector(onOpenAlbums:)];
    openLib.bezelStyle = NSBezelStyleRounded;
    openLib.translatesAutoresizingMaskIntoConstraints = NO;
    [head addSubview:at];
    [head addSubview:openLib];
    [self.stack addArrangedSubview:head];

    self.albumRow = [[NSStackView alloc] init];
    self.albumRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.albumRow.spacing = 12;
    self.albumRow.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stack addArrangedSubview:self.albumRow];

    [NSLayoutConstraint activateConstraints:@[
        [head.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48],
        [head.heightAnchor constraintEqualToConstant:28],
        [at.leadingAnchor constraintEqualToAnchor:head.leadingAnchor],
        [at.centerYAnchor constraintEqualToAnchor:head.centerYAnchor],
        [openLib.trailingAnchor constraintEqualToAnchor:head.trailingAnchor],
        [openLib.centerYAnchor constraintEqualToAnchor:head.centerYAnchor],
        [self.albumRow.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48],
        [self.albumRow.heightAnchor constraintEqualToConstant:120],
    ]];
}

#pragma mark - ④ 音乐库（就地弹层，不跳设置）

- (void)buildLibraryCard {
    RLPTheme *t = [RLPTheme current];
    NSView *c = [self cardWithIdentifier:@"room.library"];
    self.libDesc = RLPLabel(@"", t.small, t.mut);
    self.libDesc.translatesAutoresizingMaskIntoConstraints = NO;
    self.libDesc.maximumNumberOfLines = 2;
    self.libDesc.lineBreakMode = NSLineBreakByWordWrapping;
    self.libButton = [NSButton buttonWithTitle:RLPTr(@"添加音乐目录") target:self action:@selector(onLibraryAction:)];
    self.libButton.bezelStyle = NSBezelStyleRounded;
    self.libButton.translatesAutoresizingMaskIntoConstraints = NO;
    // 更多入口：功能不能删，但聆听室里不放「设置」字样。
    NSButton *more = [NSButton buttonWithTitle:RLPTr(@"更多") target:self action:@selector(onOpenMore:)];
    more.bezelStyle = NSBezelStyleRounded;
    more.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *v in @[self.libDesc, self.libButton, more]) [c addSubview:v];
    [self.stack addArrangedSubview:c];
    [NSLayoutConstraint activateConstraints:@[
        [c.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48],
        [c.heightAnchor constraintEqualToConstant:64],
        [self.libDesc.leadingAnchor constraintEqualToAnchor:c.leadingAnchor constant:14],
        [self.libDesc.topAnchor constraintEqualToAnchor:c.topAnchor constant:12],
        [self.libDesc.trailingAnchor constraintEqualToAnchor:more.leadingAnchor constant:-12],
        [self.libButton.leadingAnchor constraintEqualToAnchor:c.leadingAnchor constant:14],
        [self.libButton.topAnchor constraintEqualToAnchor:self.libDesc.bottomAnchor constant:6],
        [more.trailingAnchor constraintEqualToAnchor:c.trailingAnchor constant:-14],
        [more.centerYAnchor constraintEqualToAnchor:c.centerYAnchor],
        [more.widthAnchor constraintEqualToConstant:72],
    ]];
}


#pragma mark - 卡片式弹层（就地改设置，不跳设置页）

/// 弹层里的一个可选行（标题 + 说明 + 勾选态）。
- (NSButton *)popRowWithTitle:(NSString *)title note:(NSString *)note on:(BOOL)on action:(SEL)action ident:(NSString *)ident {
    RLPTheme *t = [RLPTheme current];
    NSButton *b = [NSButton buttonWithTitle:title target:self action:action];
    b.bordered = NO;
    b.identifier = ident;
    b.alignment = NSTextAlignmentLeft;
    b.font = [NSFont systemFontOfSize:13 weight:on ? NSFontWeightSemibold : NSFontWeightRegular];
    b.contentTintColor = on ? t.accentText : t.text;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.toolTip = note;
    return b;
}

- (void)showPopoverFrom:(NSView *)anchor withCard:(NSView *)card width:(CGFloat)w minH:(CGFloat)h {
    [self.popover close];
    NSViewController *vc = RLPCardController(card, w, h);
    self.popover = RLPShowCardPopover(anchor, vc, w);
}

/// 弹层内容骨架：标题 + 说明 + 纵向选项容器。
- (NSStackView *)popStackWithTitle:(NSString *)title note:(NSString *)note {
    RLPTheme *t = [RLPTheme current];
    NSStackView *s = [[NSStackView alloc] init];
    s.orientation = NSUserInterfaceLayoutOrientationVertical;
    s.alignment = NSLayoutAttributeLeading;
    s.spacing = 8;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *ti = RLPLabel(title, [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], t.text);
    [s addArrangedSubview:ti];
    if (note.length) {
        NSTextField *no = RLPLabel(note, t.small, t.mut);
        no.maximumNumberOfLines = 0;
        no.lineBreakMode = NSLineBreakByWordWrapping;
        no.preferredMaxLayoutWidth = 330;
        [s addArrangedSubview:no];
    }
    return s;
}

#pragma mark 输出弹层

- (void)onOpenOutput:(id)sender {
    NSString *bk = [self.settings[@"backend"] isKindOfClass:[NSString class]] ? self.settings[@"backend"] : @"coreaudio";
    const BOOL hog = [self str:@"hogexcl" def:@"1"].boolValue;
    NSStackView *s = [self popStackWithTitle:RLPTr(@"输出方式")
        note:RLPTr(@"独占播放音质最稳；共享播放和其它 App 一起出声。")];
    NSArray *opts = @[
        @[@"coreaudio", RLPTr(@"本机 · 独占播放"), RLPTr(@"独占设备，音质最稳（推荐）")],
        @[@"coreaudio-shared", RLPTr(@"本机 · 共享播放"), RLPTr(@"和其它 App 一起出声，兼容性最好")],
        @[@"upnp", RLPTr(@"投放到局域网设备"), RLPTr(@"投到支持 UPnP/DLNA 的播放器")],
    ];
    for (NSArray *o in opts) {
        NSButton *b = [self popRowWithTitle:o[1] note:o[2] on:[bk isEqualToString:o[0]]
                                     action:@selector(onPickBackend:) ident:o[0]];
        [s addArrangedSubview:b];
        [[b.widthAnchor constraintEqualToConstant:330] setActive:YES];
        NSTextField *sub = RLPLabel(o[2], [RLPTheme current].small, [RLPTheme current].mut);
        [s addArrangedSubview:sub];
        [[sub.widthAnchor constraintEqualToConstant:330] setActive:YES];
    }
    // 严格独占：副作用必须如实写清（macOS Hog 机制限制，实测确认）
    NSButton *hogBtn = [NSButton checkboxWithTitle:RLPTr(@"严格独占（抢 Hog Mode）") target:self action:@selector(onToggleHog:)];
    hogBtn.state = hog ? NSControlStateValueOn : NSControlStateValueOff;
    hogBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [s addArrangedSubview:hogBtn];
    NSTextField *hogNote = RLPLabel(RLPTr(@"开启后系统音量条与音量键会失效，只能用本程序的音量条；它不能阻止其它 App 播放。"),
        [RLPTheme current].small, [RLPTheme current].warn);
    hogNote.maximumNumberOfLines = 0;
    hogNote.lineBreakMode = NSLineBreakByWordWrapping;
    hogNote.preferredMaxLayoutWidth = 330;
    [s addArrangedSubview:hogNote];
    [[hogNote.widthAnchor constraintEqualToConstant:330] setActive:YES];
    [self showPopoverFrom:self.outputCard withCard:s width:360 minH:280];
}

- (void)onPickBackend:(NSButton *)sender {
    [self postSettings:@{@"backend": sender.identifier}];
    [self.popover close];
}
- (void)onToggleHog:(NSButton *)sender {
    [self postSettings:@{@"hogexcl": (sender.state == NSControlStateValueOn ? @"1" : @"0")}];
}

#pragma mark 播放弹层（三档）

- (void)onOpenPlay:(id)sender {
    const BOOL isDsd = RLPPathIsDsd(self.currentPath);
    NSStackView *s = [self popStackWithTitle:RLPTr(@"播放方式")
        note:RLPTr(@"不确定就选「原音直通」：文件是什么就播什么。")];
    NSArray *opts = @[
        @[@0, RLPTr(@"原音直通"), RLPTr(@"文件是什么就播什么，不做任何加工")],
        @[@1, RLPTr(@"PCM 升频"), RLPTr(@"把普通高清音源提升到设备支持的更高采样率")],
        @[@2, RLPTr(@"DSD 升频"), RLPTr(@"转换成 DSD 信号输出，声音更绵密（需要设备支持 DoP）")],
    ];
    // v3.3.11 `rlPaintPreset` 的两条闸门，逐条移植：
    //   ① 正在播放/暂停时不许应用（`请先停止播放，再应用预设。`）
    //   ② PCM / DSD 档按 `/api/preset/caps` 的真实能力置灰（`能力尚未确认，请先选择输出设备。`）
    const BOOL busy = [self playbackIsActive];
    for (NSArray *o in opts) {
        const NSInteger code = [o[0] integerValue];
        BOOL enabled = !busy;
        if (enabled && code == 1) enabled = self.presetPcmReady;
        if (enabled && code == 2) enabled = self.presetDsdReady;
        NSButton *b = [self popRowWithTitle:o[1] note:o[2] on:NO action:@selector(onPickPlayMode:) ident:[o[0] stringValue]];
        b.enabled = enabled;
        if (!enabled) {
            // 说清"为什么点不了"：上游把原因写在按钮下方（`当前能力未确认或不支持`）。
            b.toolTip = busy ? RLPTr(@"请先停止播放，再应用预设。")
                             : (self.presetCapsKnown ? RLPTr(@"当前设备不支持这一档")
                                                    : RLPTr(@"能力尚未确认，请先选择输出设备。"));
        }
        [s addArrangedSubview:b];
        [[b.widthAnchor constraintEqualToConstant:330] setActive:YES];
        NSTextField *sub = RLPLabel(o[2], [RLPTheme current].small, [RLPTheme current].mut);
        sub.maximumNumberOfLines = 0;
        sub.lineBreakMode = NSLineBreakByWordWrapping;
        sub.preferredMaxLayoutWidth = 330;
        [s addArrangedSubview:sub];
        [[sub.widthAnchor constraintEqualToConstant:330] setActive:YES];
    }
    if (busy || !self.presetCapsKnown || !self.presetPcmReady || !self.presetDsdReady) {
        NSString *why = busy ? RLPTr(@"请先停止播放，再应用预设。")
                      : (!self.presetCapsKnown ? RLPTr(@"能力尚未确认，请先选择输出设备。")
                                              : RLPTr(@"当前设备不支持置灰的那几档。"));
        NSTextField *gate = RLPLabel(why, [RLPTheme current].small, [RLPTheme current].mut2);
        gate.identifier = @"quickstart.presetGate";
        gate.maximumNumberOfLines = 0;
        gate.lineBreakMode = NSLineBreakByWordWrapping;
        gate.preferredMaxLayoutWidth = 330;
        [s addArrangedSubview:gate];
        [[gate.widthAnchor constraintEqualToConstant:330] setActive:YES];
    }
    NSTextField *dsdNote = RLPLabel(isDsd
        ? RLPTr(@"当前是 DSD 文件：DSD 升频会走 DSD→DSD。")
        : RLPTr(@"播放 DSD 文件时，DSD 升频会自动改用 DSD→DSD。"),
        [RLPTheme current].small, [RLPTheme current].mut);
    dsdNote.maximumNumberOfLines = 0;
    dsdNote.lineBreakMode = NSLineBreakByWordWrapping;
    dsdNote.preferredMaxLayoutWidth = 330;
    [s addArrangedSubview:dsdNote];
    [[dsdNote.widthAnchor constraintEqualToConstant:330] setActive:YES];
    [self showPopoverFrom:self.playCard withCard:s width:360 minH:260];
}

/// 是否正在播放或暂停（上游 `S.playing||S.paused`）。用页面已轮询到的状态，
/// 不新开一条轮询：`self.webStatus` 是该页唯一的状态快照。
- (BOOL)playbackIsActive {
    return self.playing || self.pausedNow;
}

- (void)onPickPlayMode:(NSButton *)sender {
    const RLPPlayMode3 mode = (RLPPlayMode3)sender.identifier.integerValue;
    NSString *profile = RLPProfileForPlayMode(mode, RLPPathIsDsd(self.currentPath));
    [self.popover close];
    self.playValue.stringValue = (mode == RLPPlayMode3Direct ? RLPTr(@"原音直通")
                                 : mode == RLPPlayMode3Pcm ? RLPTr(@"PCM 升频") : RLPTr(@"DSD 升频"));
    self.presetNotes.stringValue = RLPTr(@"正在应用…");
    NSString *path = [NSString stringWithFormat:@"/api/preset/apply?profile=%@", RLPEnc(profile)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:path body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            // notes 是后端给的决策说明（含降级原因），照实显示，不自己编"已优化"。
            NSArray *notes = [json[@"notes"] isKindOfClass:[NSArray class]] ? json[@"notes"] : @[];
            self_.presetNotes.stringValue = notes.count ? [notes componentsJoinedByString:@"；"] : RLPTr(@"已应用");
            RLPToast(RLPTr(@"已应用"));
            [self_ reloadSettings];
        } else {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"应用失败");
            self_.presetNotes.stringValue = err;
            RLPToast(err);
        }
    }];
}

#pragma mark 听音风格弹层

- (void)onOpenStyle:(id)sender {
    NSStackView *s = [self popStackWithTitle:RLPTr(@"听音风格")
        note:RLPTr(@"不用懂滤波：往温和走声音更柔顺，往锐利走更清亮。")];
    if (!self.filters.count) {
        NSTextField *na = RLPLabel(RLPTr(@"滤波列表读取失败，请稍后重试"), [RLPTheme current].small, [RLPTheme current].warn);
        [s addArrangedSubview:na];
        [[na.widthAnchor constraintEqualToConstant:330] setActive:YES];
    }
    NSString *curFilter = [self str:@"filter" def:@""];
    for (NSInteger i = RLPToneStyleSharp; i <= RLPToneStyleWarm; ++i) {
        NSString *name = RLPFilterForToneStyle((RLPToneStyle)i, self.filters);
        NSButton *b = [self popRowWithTitle:RLPToneStyleName((RLPToneStyle)i) note:name ?: @""
                                          on:[curFilter isEqualToString:name ?: @""]
                                      action:@selector(onPickStyle:) ident:[@(i) stringValue]];
        [s addArrangedSubview:b];
        [[b.widthAnchor constraintEqualToConstant:330] setActive:YES];
        // 滤波真名只作副标题小字：让人不用懂滤波也能挑
        NSTextField *sub = RLPLabel(name ?: RLPTr(@"无可用滤波"), [RLPTheme current].small, [RLPTheme current].mut);
        [s addArrangedSubview:sub];
        [[sub.widthAnchor constraintEqualToConstant:330] setActive:YES];
    }
    [self showPopoverFrom:self.styleCard withCard:s width:360 minH:230];
}

- (void)onPickStyle:(NSButton *)sender {
    const RLPToneStyle st = (RLPToneStyle)sender.identifier.integerValue;
    NSString *name = RLPFilterForToneStyle(st, self.filters);
    if (!name.length) { RLPToast(RLPTr(@"没有可用滤波")); return; }
    // forNx 项要写 filterNx 键，写错键会被后端静默丢弃。
    NSString *key = RLPFilterUsesNxKey(name, self.filters) ? @"filterNx" : @"filter";
    [self postSettings:@{key: name}];
    [self.popover close];
}

#pragma mark 更多入口（功能不删，但不放「设置」字样）

- (void)onOpenMore:(id)sender {
    NSStackView *s = [self popStackWithTitle:RLPTr(@"更多")
        note:RLPTr(@"流媒体在这里挂载；AI 资料与音频输入在左侧「设置」里调整。")];
    NSButton *stream = [self popRowWithTitle:RLPTr(@"挂载流媒体服务") note:RLPTr(@"打开流媒体页") on:NO
                                       action:@selector(onOpenStreaming:) ident:@"more.stream"];
    [s addArrangedSubview:stream];
    [[stream.widthAnchor constraintEqualToConstant:330] setActive:YES];
    NSTextField *ro = RLPLabel(RLPTr(@"AI 资料补全与音频输入采集：在左侧「设置」里调整。"),
        [RLPTheme current].small, [RLPTheme current].mut);
    ro.maximumNumberOfLines = 0;
    ro.lineBreakMode = NSLineBreakByWordWrapping;
    ro.preferredMaxLayoutWidth = 330;
    [s addArrangedSubview:ro];
    [[ro.widthAnchor constraintEqualToConstant:330] setActive:YES];
    [self showPopoverFrom:self.libButton withCard:s width:360 minH:150];
}


#pragma mark - 动作

- (NSString *)str:(NSString *)key def:(NSString *)def {
    id v = self.settings[key];
    if ([v isKindOfClass:[NSString class]]) return (NSString *)v;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
    return def;
}

/// 写设置：一次 POST 多个键，然后**读回校验**（不维护第二套状态）。
- (void)postSettings:(NSDictionary<NSString *, NSString *> *)kv {
    if (!kv.count) return;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in kv) [parts addObject:[NSString stringWithFormat:@"%@=%@", k, RLPEnc(kv[k])]];
    NSString *body = [parts componentsJoinedByString:@"&"];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/settings" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            RLPToast(RLPTr(@"已生效"));
            [self_ reloadSettings];
        } else {
            RLPToast(RLPTr(@"保存失败"));
        }
    }];
}

- (void)onDeviceChanged:(NSPopUpButton *)sender {
    const NSInteger idx = sender.indexOfSelectedItem;
    if (idx < 0) return;
    // 第 0 项是"系统默认"（device 空串）；其余对应 devices[idx-1]
    NSString *devId = @"";
    if (idx > 0 && (idx - 1) < (NSInteger)self.devices.count) {
        NSDictionary *d = self.devices[idx - 1];
        devId = [d[@"id"] isKindOfClass:[NSString class]] ? d[@"id"] : @"";
    }
    [self postSettings:@{@"device": devId}];
}

- (void)onReloadDevices:(id)sender { [self reloadDevices]; RLPToast(RLPTr(@"已重新检测设备")); }

- (void)onTogglePlay:(id)sender {
    // 与播放条同一条路径：/api/pause?on=1 暂停、on=0 继续。
    // ⚠️ 不能用 /api/play 当"继续" —— 那会从头重播当前曲目。
    NSString *path = [NSString stringWithFormat:@"/api/pause?on=%d", self.playing ? 1 : 0];
    RLPPostJSON(path, nil);
}
- (void)onOpenNowPlaying:(id)sender {
    // 正在播放页由主窗口的顶栏入口承载；这里发既有通知，不新造路由。
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenNowPlayingNotification" object:nil];
}
- (void)onOpenQueue:(id)sender {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPNavigateKeyNotification" object:@"queue"];
}
- (void)onOpenAlbums:(id)sender {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPNavigateKeyNotification" object:@"albums"];
}
- (void)onOpenStreaming:(id)sender {
    [self.popover close];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPNavigateKeyNotification" object:@"streaming"];
}

/// 音乐库：就地弹层选目录（NSOpenPanel），不跳设置页。
- (void)onLibraryAction:(id)sender {
    if (self.hasRoots) {
        RLPPostJSON(@"/api/lib/scan?full=1", nil);
        RLPToast(RLPTr(@"已开始全量重扫"));
        return;
    }
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseDirectories = YES;
    p.canChooseFiles = NO;
    p.allowsMultipleSelection = NO;
    p.prompt = RLPTr(@"选择");
    p.message = RLPTr(@"选择存放音乐的目录");
    __weak __typeof__(self) weakSelf = self;
    [p beginWithCompletionHandler:^(NSInteger result) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || result != NSModalResponseOK) return;
        NSString *path = p.URL.path;
        if (!path.length) return;
        [[RLPCoreClient shared] postJSON:@"/api/lib/roots"
            body:[NSString stringWithFormat:@"add=%@", RLPEnc(path)]
            completion:^(NSDictionary * _Nullable json) {
            __typeof__(self) s2 = weakSelf;
            if (!s2) return;
            if (json && [json[@"ok"] boolValue]) {
                RLPPostJSON(@"/api/lib/scan?full=1", nil);
                RLPToast(RLPTr(@"已添加目录，开始扫描"));
                [s2 reloadLibrary];
            } else {
                NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"添加失败");
                RLPToast(err);
            }
        }];
    }];
}

#pragma mark - 数据

- (void)activate {
    [self reloadAll];
    if (!self.poll && [RLPCoreClient shared].started) {
        __weak __typeof__(self) weakSelf = self;
        self.poll = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            (void)t; [weakSelf reloadStatus];
        }];
    }
}

- (void)viewDidDisappear {
    [self.poll invalidate];
    self.poll = nil;
    [super viewDidDisappear];
}

- (void)reloadData { [self reloadAll]; }

- (void)reloadAll {
    if (![RLPCoreClient shared].started) { [self setSubtitle:RLPTr(@"核心未启动")]; return; }
    [self reloadDevices];
    [self reloadSettings];
    [self reloadFilters];
    [self reloadLibrary];
    [self reloadStatus];
    [self reloadQueue];
    [self reloadAlbums];
}

- (void)reloadDevices {
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/devices" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        self_.devices = [json[@"devices"] isKindOfClass:[NSArray class]] ? json[@"devices"] : @[];
        [self_.devicePopup removeAllItems];
        [self_.devicePopup addItemWithTitle:RLPTr(@"系统默认")];
        NSString *defName = nil;
        for (NSDictionary *d in self_.devices) {
            NSString *n = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : RLPTr(@"未知设备");
            [self_.devicePopup addItemWithTitle:n];
            if ([d[@"default"] boolValue]) defName = n;
        }
        if (defName.length) [[self_.devicePopup itemAtIndex:0] setTitle:[NSString stringWithFormat:@"%@（%@）", RLPTr(@"系统默认"), defName]];
        [self_ syncDeviceSelection];
    }];
}

- (void)syncDeviceSelection {
    NSString *cur = [self str:@"device" def:@""];
    if (!cur.length) { [self.devicePopup selectItemAtIndex:0]; return; }
    for (NSInteger i = 0; i < (NSInteger)self.devices.count; ++i) {
        if ([self.devices[i][@"id"] isEqualToString:cur]) { [self.devicePopup selectItemAtIndex:i + 1]; return; }
    }
    [self.devicePopup selectItemAtIndex:0];
}

- (void)reloadSettings {
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/settings" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        // ⚠️ /api/settings 的值在 **kv** 子对象里（与设置页同一口径）。
        // 直接读顶层会全部取不到 ⟹ 静默回落默认值，界面显示与真实设置脱节。
        self_.settings = [json[@"kv"] isKindOfClass:[NSDictionary class]] ? json[@"kv"] : @{};
        [self_ syncDeviceSelection];
        // 输出摘要（人话）
        NSString *bk = [self_ str:@"backend" def:@"coreaudio"];
        NSString *bkName = [bk isEqualToString:@"coreaudio-shared"] ? RLPTr(@"共享播放")
                         : [bk isEqualToString:@"upnp"] ? RLPTr(@"局域网投放")
                         : [bk isEqualToString:@"null"] ? RLPTr(@"不出声（仅分析）") : RLPTr(@"独占播放");
        const BOOL hog = [self_ str:@"hogexcl" def:@"1"].boolValue;
        self_.outputValue.stringValue = [NSString stringWithFormat:@"%@%@", bkName,
            ([bk isEqualToString:@"coreaudio"] && hog) ? @" · Hog" : @""];
        // 播放档位摘要：从 dsd/rate 反推（不维护第二套状态）
        const NSInteger dsd = [self_ str:@"dsd" def:@"0"].integerValue;
        NSString *rate = [self_ str:@"rate" def:@"follow"];
        self_.playValue.stringValue = dsd > 0 ? RLPTr(@"DSD 升频")
            : ([rate isEqualToString:@"follow"] || !rate.length ? RLPTr(@"原音直通") : RLPTr(@"PCM 升频"));
        // 听音风格回显
        NSString *f = [self_ str:@"filter" def:@""];
        NSInteger st = RLPToneStyleForFilter(f, self_.filters);
        self_.styleValue.stringValue = (st >= 0) ? RLPToneStyleName((RLPToneStyle)st) : RLPTr(@"自定义");
        self_.styleSub.stringValue = f.length ? f : RLPTr(@"跟随默认");
    }];
}

- (void)reloadFilters {
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/filters" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        self_.filters = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[];
        NSString *f = [self_ str:@"filter" def:@""];
        NSInteger st = RLPToneStyleForFilter(f, self_.filters);
        self_.styleValue.stringValue = (st >= 0) ? RLPToneStyleName((RLPToneStyle)st) : RLPTr(@"自定义");
        self_.styleSub.stringValue = f.length ? f : RLPTr(@"跟随默认");
    }];
}

- (void)reloadLibrary {
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/lib/roots" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *roots = [json[@"roots"] isKindOfClass:[NSArray class]] ? json[@"roots"] : @[];
        self_.hasRoots = roots.count > 0;
        self_.libDesc.stringValue = self_.hasRoots
            ? RLPTr(@"音乐目录已就绪 · 可重新扫描更新专辑与封面")
            : RLPTr(@"支持 FLAC · DSD (DSF/DFF) · ALAC · WAV · APE");
        [self_.libButton setTitle:self_.hasRoots ? RLPTr(@"重新扫描音乐库") : RLPTr(@"添加音乐目录")];
    }];
}

- (void)reloadStatus {
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/status" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        RLPPlaybackStatus *st = [RLPPlaybackStatus statusFromJSON:json];
        if (!st) return;
        self_.playing = st.playing && !st.paused;
        self_.pausedNow = st.paused;
        NSString *path = st.currentPath ?: @"";
        [self_.npToggle setTitle:self_.playing ? RLPTr(@"暂停") : RLPTr(@"继续播放")];
        self_.npState.stringValue = path.length ? (self_.playing ? RLPTr(@"正在播放") : RLPTr(@"已暂停")) : RLPTr(@"未播放");
        if (![path isEqualToString:self_.currentPath ?: @""]) {
            self_.currentPath = path;
            self_.npTitle.stringValue = path.length ? path.lastPathComponent.stringByDeletingPathExtension : RLPTr(@"还没有在播放的音乐");
            self_.npSub.stringValue = path.length ? @"" : RLPTr(@"从下面的专辑挑一张开始");
            [self_ loadCoverForPath:path];
            [self_ loadMetaForPath:path];
        }
    }];
}

/// 空态/无封面时给一个音符占位，避免左侧是纯空白方块（目标图有唱片质感）。
- (void)showCoverPlaceholder {
    NSImage *sym = [NSImage imageWithSystemSymbolName:@"music.note" accessibilityDescription:RLPTr(@"封面")];
    self.npCover.image = sym;
    self.npCover.contentTintColor = [RLPTheme current].mut;
    self.npCover.imageScaling = NSImageScaleProportionallyDown;
}

- (void)loadCoverForPath:(NSString *)path {
    if (!path.length) { [self showCoverPlaceholder]; return; }
    const NSUInteger seq = ++self.coverSeq;
    NSString *url = [NSString stringWithFormat:@"/api/cover?file=%@", RLPEnc(path)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getData:url completion:^(NSData * _Nullable data) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.coverSeq) return;
        if (data.length) {
            NSImage *img = [[NSImage alloc] initWithData:data];
            if (img) {
                self_.npCover.image = img;
                self_.npCover.imageScaling = NSImageScaleProportionallyUpOrDown;
                self_.npCover.contentTintColor = nil;
                return;
            }
        }
        [self_ showCoverPlaceholder];
    }];
}

- (void)loadMetaForPath:(NSString *)path {
    if (!path.length) return;
    NSString *url = [NSString stringWithFormat:@"/api/meta?file=%@", RLPEnc(path)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || ![path isEqualToString:self_.currentPath ?: @""]) return;
        NSString *title = [json[@"title"] isKindOfClass:[NSString class]] ? json[@"title"] : @"";
        NSString *artist = [json[@"artist"] isKindOfClass:[NSString class]] ? json[@"artist"] : @"";
        NSString *album = [json[@"album"] isKindOfClass:[NSString class]] ? json[@"album"] : @"";
        if (title.length) self_.npTitle.stringValue = title;
        NSMutableArray *p = [NSMutableArray array];
        if (album.length) [p addObject:album];
        if (artist.length) [p addObject:artist];
        self_.npSub.stringValue = [p componentsJoinedByString:@" · "];
    }];
}

- (void)reloadQueue {
    RLPTheme *t = [RLPTheme current];
    __weak __typeof__(self) weakSelf = self;
    // 队列契约：GET /api/queue?meta=1 → {items:[路径…], metas:[{t,a,al,d}…], index}
    // （键是 items，不是 queue；读错键会永远显示"队列是空的"）
    [[RLPCoreClient shared] getJSON:@"/api/queue?meta=1" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *items = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[];
        NSArray *metas = [json[@"metas"] isKindOfClass:[NSArray class]] ? json[@"metas"] : @[];
        for (NSView *v in [self_.queueList.arrangedSubviews copy]) [self_.queueList removeArrangedSubview:v], [v removeFromSuperview];
        if (!items.count) {
            NSTextField *e = [self_ trackedLabel:RLPTr(@"队列是空的") font:t.small role:1];
            [self_.queueList addArrangedSubview:e];
            return;
        }
        NSInteger n = 0;
        for (id it in items) {
            if (n >= 5) break;
            NSString *name = nil;
            if (n < (NSInteger)metas.count && [metas[n] isKindOfClass:[NSDictionary class]]) {
                NSString *t = [metas[n][@"t"] isKindOfClass:[NSString class]] ? metas[n][@"t"] : nil;
                if (t.length) name = t;
            }
            if (!name.length) {
                if ([it isKindOfClass:[NSString class]])
                    name = [(NSString *)it lastPathComponent].stringByDeletingPathExtension;
                else if ([it isKindOfClass:[NSDictionary class]]) {
                    NSString *p = [it[@"path"] isKindOfClass:[NSString class]] ? it[@"path"] : it[@"file"];
                    name = p.lastPathComponent.stringByDeletingPathExtension;
                }
            }
            NSTextField *l = [self_ trackedLabel:[NSString stringWithFormat:@"%ld  %@", (long)(n + 1), name ?: @""] font:t.small role:0];
            l.translatesAutoresizingMaskIntoConstraints = NO;
            [self_.queueList addArrangedSubview:l];
            [[l.widthAnchor constraintLessThanOrEqualToConstant:270] setActive:YES];
            ++n;
        }
    }];
}

- (void)reloadAlbums {
    RLPTheme *t = [RLPTheme current];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/lib/albums" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *albs = [json[@"albums"] isKindOfClass:[NSArray class]] ? json[@"albums"] : @[];
        for (NSView *v in [self_.albumRow.arrangedSubviews copy]) [self_.albumRow removeArrangedSubview:v], [v removeFromSuperview];
        NSInteger n = 0;
        for (id it in albs) {
            if (n >= 6) break;
            if (![it isKindOfClass:[NSDictionary class]]) continue;
            NSString *key = [it[@"k"] isKindOfClass:[NSString class]] ? it[@"k"] : nil;
            if (!key.length) continue;
            // /api/lib/albums 的专辑名字段是 name（al 是队列 metas 里的字段，别混）
            NSString *name = [it[@"name"] isKindOfClass:[NSString class]] ? it[@"name"] : nil;
            // 封面卡：封面图 + 专辑名（点任意处进详情）。只有文字按钮不像"音乐库"。
            NSView *cell = [[NSView alloc] initWithFrame:NSZeroRect];
            cell.translatesAutoresizingMaskIntoConstraints = NO;
            NSImageView *iv = [[NSImageView alloc] initWithFrame:NSZeroRect];
            iv.imageScaling = NSImageScaleProportionallyUpOrDown;
            iv.wantsLayer = YES;
            iv.layer.cornerRadius = t.rSm;
            iv.layer.masksToBounds = YES;
            iv.layer.backgroundColor = t.bg3.CGColor;
            iv.translatesAutoresizingMaskIntoConstraints = NO;
            iv.identifier = [NSString stringWithFormat:@"room.albumcover.%ld", (long)n];
            NSTextField *nm = [self_ trackedLabel:(name ?: RLPTr(@"未知专辑")) font:t.small role:0];
            nm.translatesAutoresizingMaskIntoConstraints = NO;
            nm.lineBreakMode = NSLineBreakByTruncatingTail;
            NSButton *hit = [NSButton buttonWithTitle:@"" target:self_ action:@selector(onAlbumClicked:)];
            hit.bordered = NO;
            hit.identifier = key;
            hit.translatesAutoresizingMaskIntoConstraints = NO;
            hit.toolTip = name ?: @"";
            for (NSView *v in @[iv, nm, hit]) [cell addSubview:v];
            [NSLayoutConstraint activateConstraints:@[
                [cell.widthAnchor constraintEqualToConstant:104],
                [cell.heightAnchor constraintEqualToConstant:120],
                [iv.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor],
                [iv.topAnchor constraintEqualToAnchor:cell.topAnchor],
                [iv.widthAnchor constraintEqualToConstant:104],
                [iv.heightAnchor constraintEqualToConstant:96],
                [nm.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor],
                [nm.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor],
                [nm.topAnchor constraintEqualToAnchor:iv.bottomAnchor constant:4],
                [hit.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor],
                [hit.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor],
                [hit.topAnchor constraintEqualToAnchor:cell.topAnchor],
                [hit.bottomAnchor constraintEqualToAnchor:cell.bottomAnchor],
            ]];
            [self_.albumRow addArrangedSubview:cell];
            // 封面走共享缓存（后端 /api/lib/cover?k=…），失败留占位底色，不重试不阻塞
            [[RLPCoverLoader shared] coverForAlbumKey:key completion:^(NSImage * _Nullable image) {
                if (image) iv.image = image;
            }];
            ++n;
        }
        if (!n) {
            NSTextField *e = [self_ trackedLabel:RLPTr(@"还没有专辑 · 先添加音乐目录") font:t.small role:1];
            [self_.albumRow addArrangedSubview:e];
        }
    }];
}

- (void)onAlbumClicked:(NSButton *)sender { RLPRequestOpenAlbum(sender.identifier); }

#pragma mark - 主题

/// 运行时建出来的标签登记进来：主题切换时静态清单够不着它们。
/// role: 0=正文 1=次要文字 2=警示
- (NSTextField *)trackedLabel:(NSString *)text font:(NSFont *)font role:(NSInteger)role {
    RLPTheme *t = [RLPTheme current];
    NSColor *c = (role == 1) ? t.mut : (role == 2 ? t.warn : t.text);
    NSTextField *l = RLPLabel(text, font, c);
    l.tag = role;
    if (!self.dynamicLabels) self.dynamicLabels = [NSMutableArray array];
    [self.dynamicLabels addObject:l];
    return l;
}

- (void)applyTheme {
    [super applyTheme];
    RLPTheme *t = [RLPTheme current];
    for (NSView *v in self.stack.arrangedSubviews) {
        if (v.wantsLayer && v.layer.cornerRadius > 0) {
            v.layer.backgroundColor = t.bg2.CGColor;
            v.layer.borderColor = t.line.CGColor;
        }
        for (NSView *s in v.subviews) {
            if (s.wantsLayer && s.layer.cornerRadius > 0) {
                s.layer.backgroundColor = t.bg2.CGColor;
                s.layer.borderColor = t.line.CGColor;
            }
        }
    }
    self.npCover.layer.backgroundColor = t.bg3.CGColor;
    self.libDesc.textColor = t.mut;
    self.presetNotes.textColor = t.mut;
    self.styleSub.textColor = t.mut;
    self.npState.textColor = t.mut;
    self.npSub.textColor = t.mut;
    self.npTitle.textColor = t.text;
    self.outputValue.textColor = t.text;
    self.playValue.textColor = t.text;
    self.styleValue.textColor = t.text;
    // 卡片小标题 / 分区标题（之前漏刷：浅色主题下它们仍是深色主题的灰，几乎看不见）
    for (NSTextField *l in @[ self.deviceCaption, self.outputCaption, self.playCaption, self.styleCaption ])
        l.textColor = t.mut;
    self.queueCaption.textColor = t.text;
    self.albumCaption.textColor = t.text;
    // 动态行（队列预览 / 专辑名 / 空态）：运行时建出来的，静态清单里没有它们。
    // 角色记在 NSView.tag 上（0=正文 1=次要 2=警示），不另存第二套状态。
    for (NSTextField *l in self.dynamicLabels) {
        l.textColor = (l.tag == 1) ? t.mut : (l.tag == 2 ? t.warn : t.text);
    }
}


/// /api/preset/caps：探测本机对官方推荐预设的支持能力（web loadPresetCaps 同源）。
/// 为什么不写死：能力取决于当前输出设备（DSD 直通、采样率上限都随设备变），
/// 写死一张表就等于在界面上撒谎。
- (void)loadPresetCaps:(BOOL)force {
    if (![RLPCoreClient shared].started) return;
    NSString *url = force ? @"/api/preset/caps?refresh=1" : @"/api/preset/caps";
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        [self_ applyPresetCaps:json];
    }];
}

/// v3.3.11 `quickStartModel` 的逐条移植：从 `/api/preset/caps` 算出
/// `pcmReady` / `dsdReady`，供「播放方式」弹层置灰用。
///
/// 上游判定（ui_script.h:5326-5338）：
///   remote = backend=='upnp'; shared = backend=='wasapi-shared'; offline = backend=='null';
///   known  = !offline && !remote && caps.ok && device.name && rates 非空 && maxRate>0
///   pcmReady = known && !remote && !shared
///   dsdReady = known && !remote && !shared && (dsdNative || dop)
/// mac 侧 `upnp`/`wasapi-shared` 不存在（backend 是 coreaudio/…），但 `offline(null)` 与
/// `dsdNative` 判定同样成立：mac 的 DSD 只有 DoP，故 dsdReady 实际靠 `dop` 决定。
/// 纯函数：`/api/preset/caps` 响应 → 三档可用性（v3.3.11 `quickStartModel` 的逐条移植）。
/// 抽成类方法的理由：这条决策决定按钮能不能点，必须能被判据**直接**测，
/// 而不是只能靠"打开弹层再找按钮"间接测（间接测会因为布局时机变红变绿）。
/// 返回 @{@"known":BOOL, @"pcmReady":BOOL, @"dsdReady":BOOL}。
+ (NSDictionary<NSString *, NSNumber *> *)gatingForCapsJSON:(NSDictionary * _Nullable)json {
    const id okv = json[@"ok"];
    const BOOL ok = [okv respondsToSelector:@selector(boolValue)] && [okv boolValue];
    NSDictionary *dev = [json[@"device"] isKindOfClass:[NSDictionary class]] ? json[@"device"] : nil;
    NSString *backend = [dev[@"backend"] isKindOfClass:[NSString class]] ? dev[@"backend"] : @"";
    NSString *name = [dev[@"name"] isKindOfClass:[NSString class]] ? dev[@"name"] : @"";
    NSArray *rates = [dev[@"rates"] isKindOfClass:[NSArray class]] ? dev[@"rates"] : @[];
    double maxRate = [dev[@"maxRate"] respondsToSelector:@selector(doubleValue)]
                     ? [dev[@"maxRate"] doubleValue] : 0.0;
    const BOOL offline = [backend isEqualToString:@"null"];
    const BOOL remote = [backend isEqualToString:@"upnp"];
    const BOOL shared = [backend isEqualToString:@"wasapi-shared"];
    const BOOL known = ok && !offline && !remote && name.length > 0 && rates.count > 0 && maxRate > 0;
    const BOOL dsdNative = [dev[@"dsdNative"] respondsToSelector:@selector(boolValue)] &&
                           [dev[@"dsdNative"] boolValue];
    const BOOL dop = [dev[@"dop"] respondsToSelector:@selector(boolValue)] && [dev[@"dop"] boolValue];
    return @{ @"known": @(known),
              @"pcmReady": @(known && !remote && !shared),
              @"dsdReady": @(known && !remote && !shared && (dsdNative || dop)) };
}

- (void)applyPresetCaps:(NSDictionary * _Nullable)json {
    NSDictionary<NSString *, NSNumber *> *g = [[self class] gatingForCapsJSON:json];
    self.presetCapsKnown = [g[@"known"] boolValue];
    self.presetPcmReady = [g[@"pcmReady"] boolValue];
    self.presetDsdReady = [g[@"dsdReady"] boolValue];
    NSDictionary *dev = [json[@"device"] isKindOfClass:[NSDictionary class]] ? json[@"device"] : nil;
    self.presetCapsDevice = [dev[@"name"] isKindOfClass:[NSString class]] ? dev[@"name"] : nil;
}
@end

