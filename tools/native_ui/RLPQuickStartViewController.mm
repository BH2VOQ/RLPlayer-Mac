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
@property (nonatomic, strong) NSTextField *headerTitle;
@property (nonatomic, strong) NSTextField *headerSubtitle;
@property (nonatomic, strong) NSButton *foldersButton;
// 四张卡容器与响应式约束
@property (nonatomic, strong) NSView *cardsContainer;
@property (nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *cardsLayoutConstraints;
@property (nonatomic, assign) NSInteger currentCardColumns;
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
// 正在播放 + 队列预览响应式容器
@property (nonatomic, strong) NSView *npQueueRow;
@property (nonatomic, strong) NSView *npCard;
@property (nonatomic, strong) NSView *queueCard;
@property (nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *npQueueConstraints;
@property (nonatomic, assign) BOOL npQueueLayoutInitialized;
@property (nonatomic, assign) BOOL currentNpStacked;
// 正在播放 / 队列 / 专辑
@property (nonatomic, strong) NSImageView *npCover;
@property (nonatomic, strong) NSTextField *npTitle;
@property (nonatomic, strong) NSTextField *npSub;
@property (nonatomic, strong) NSTextField *npState;
@property (nonatomic, strong) NSButton *npToggle;
@property (nonatomic, strong) NSButton *npOpenButton;
@property (nonatomic, strong) NSButton *queueAllButton;
@property (nonatomic, strong) NSButton *openLibButton;
@property (nonatomic, strong) NSButton *moreButton;
@property (nonatomic, strong) NSButton *devRefreshButton;
@property (nonatomic, strong) NSButton *outCardButton;
@property (nonatomic, strong) NSButton *playCardButton;
@property (nonatomic, strong) NSButton *styleCardButton;
@property (nonatomic, weak, nullable) NSTextField *queueEmptyLabel;
@property (nonatomic, weak, nullable) NSTextField *albumEmptyLabel;
@property (nonatomic, copy, nullable) NSString *defaultDeviceName;
@property (nonatomic, assign) BOOL hasLoadedLibrary;
@property (nonatomic, assign) BOOL hasLoadedStatus;
@property (nonatomic, strong) NSStackView *queueList;
@property (nonatomic, strong) NSStackView *albumRow;
@property (nonatomic, strong) NSButton *libButton;
@property (nonatomic, strong) NSTextField *libDesc;
// 数据缓存（全部来自后端）
@property (nonatomic, copy) NSArray<NSDictionary *> *devices;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *castDevices;
@property (nonatomic, copy) NSArray<NSDictionary *> *filters;
@property (nonatomic, copy) NSDictionary *settings;
@property (nonatomic, copy, nullable) NSString *localDevice;
@property (nonatomic, copy, nullable) NSDictionary *presetCapsJSON;
@property (nonatomic, copy, nullable) NSString *presetCapsKey;
@property (nonatomic, copy) NSString *currentPath;
@property (nonatomic, assign) BOOL hasRoots;
@property (nonatomic, assign) BOOL playing;
/// v3.3.11 `rlApplyDailyPreset` 用 `S.playing||S.paused` 判定「请先停止播放」——
/// `playing` 已经是 `st.playing && !st.paused`，暂停态必须单独记一个，否则暂停时会被当成"可以应用"。
@property (nonatomic, assign) BOOL pausedNow;
@property (nonatomic, strong) NSPopover *popover;
@property (nonatomic, copy) NSString *outputDraftBackend;
@property (nonatomic, copy) NSString *outputDraftUpnpDev;
@property (nonatomic, weak, nullable) NSPopUpButton *outputUpnpPopup;
@property (nonatomic, weak, nullable) NSButton *outputUpnpScanButton;
@property (nonatomic, weak, nullable) NSButton *outputUpnpApplyButton;
@property (nonatomic, weak, nullable) NSTextField *outputUpnpStatusLabel;
@property (nonatomic, weak, nullable) NSButton *outputHogCheck;
@property (nonatomic, copy) NSArray<NSButton *> *outputBackendButtons;
@property (nonatomic, assign) NSUInteger castDiscoverSeq;
@property (nonatomic, assign) NSUInteger coverSeq;
@property (nonatomic, strong) NSTimer *poll;
@property (nonatomic, assign) NSUInteger statusEpoch;
@property (nonatomic, assign) BOOL statusInflight;
@property (nonatomic, assign) NSUInteger settingsSeq;
@property (nonatomic, assign) NSUInteger settingsWriteSeq;
@property (nonatomic, strong, nullable) NSNumber *lastHogAcquired;
@property (nonatomic, copy) NSString *lastFallbackWhy;
@end

// v3.3.11 `quickStartModel` 的三项能力结论（`/api/preset/caps` 的真实响应派生）。
// 为什么必须真的用起来：只把 caps 拉下来再丢掉，等于「能力探测」是个装饰品 ——
// 用户点「DSD 升频」会得到后端 `notes` 里的降级说明，但他事先看不到按钮为什么不该点。
@interface RLPQuickStartViewController ()
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
        _cardsLayoutConstraints = [NSMutableArray array];
        _npQueueConstraints = [NSMutableArray array];
        _currentCardColumns = 0;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onPlaybackActionCompleted:)
                                                     name:@"RLPPlaybackActionCompletedNotification"
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onExternalSettingsChanged:)
                                                     name:RLPSettingsChangedNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)onExternalSettingsChanged:(NSNotification *)note {
    if (note.object == self) return;
    if (![RLPCoreClient shared].started) return;
    [self reloadSettings];
}

- (void)onPlaybackActionCompleted:(NSNotification *)note {
    (void)note;
    if (!self.poll) return;
    [self reloadStatus];
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
    NSView *headerRow = [[NSView alloc] initWithFrame:NSZeroRect];
    headerRow.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *title = RLPLabel(RLPTr(@"聆听室"), t.display, t.hero);
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.tag = 0;   // 0=正文（applyTheme 里按 t.text 重刷）
    self.headerTitle = title;
    NSTextField *subtitle = RLPLabel(RLPTr(@"安静听歌，常用设置就在卡片里"), t.body, t.mut);
    subtitle.identifier = @"room.subtitle";
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.tag = 1;   // 1=次要（t.mut）
    self.headerSubtitle = subtitle;
    // 登记到 dynamicLabels：切主题时这两个常驻标签也要跟着重刷（A6 判据会抓漏刷）。
    [self.dynamicLabels addObject:title];
    [self.dynamicLabels addObject:subtitle];
    self.foldersButton = [NSButton buttonWithTitle:RLPTr(@"音乐文件夹") target:self action:@selector(onOpenFolders:)];
    self.foldersButton.identifier = @"room.folders";
    self.foldersButton.bezelStyle = NSBezelStyleRounded;
    self.foldersButton.translatesAutoresizingMaskIntoConstraints = NO;
    [headerRow addSubview:title];
    [headerRow addSubview:subtitle];
    [headerRow addSubview:self.foldersButton];
    [self.stack addArrangedSubview:headerRow];
    [NSLayoutConstraint activateConstraints:@[
        [headerRow.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48],
        [title.leadingAnchor constraintEqualToAnchor:headerRow.leadingAnchor],
        [title.topAnchor constraintEqualToAnchor:headerRow.topAnchor],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:self.foldersButton.leadingAnchor constant:-12],
        [subtitle.leadingAnchor constraintEqualToAnchor:headerRow.leadingAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [subtitle.trailingAnchor constraintLessThanOrEqualToAnchor:self.foldersButton.leadingAnchor constant:-12],
        [subtitle.bottomAnchor constraintEqualToAnchor:headerRow.bottomAnchor],
        [self.foldersButton.trailingAnchor constraintEqualToAnchor:headerRow.trailingAnchor],
        [self.foldersButton.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
    ]];

    [self buildFourCards];
    [self buildNowPlayingAndQueue];
    [self buildAlbumRow];
    [self buildLibraryCard];
    [self updateResponsiveLayoutForWidth:1052.0];
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
    self.devRefreshButton = devRefresh;
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
    self.outCardButton = outBtn;
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
    self.playCardButton = playBtn;
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
    self.styleCardButton = styleBtn;
    [self.styleCard addSubview:d4];
    [self.styleCard addSubview:self.styleValue];
    [self.styleCard addSubview:self.styleSub];
    [self.styleCard addSubview:styleBtn];

    self.cardsContainer = [[NSView alloc] initWithFrame:NSZeroRect];
    self.cardsContainer.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *c in @[self.deviceCard, self.outputCard, self.playCard, self.styleCard])
        [self.cardsContainer addSubview:c];
    [self.stack addArrangedSubview:self.cardsContainer];

    [[self.cardsContainer.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48] setActive:YES];

    // 这里只放**卡内**布局；四卡行/列几何由 updateResponsiveLayoutForWidth: 统一控制。
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
    self.npQueueRow = row;

    NSView *np = [self cardWithIdentifier:@"room.nowplaying"];
    self.npCard = np;
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
    self.npOpenButton = npOpen;
    for (NSView *v in @[self.npCover, self.npState, self.npTitle, self.npSub, self.npToggle, npOpen])
        [np addSubview:v];

    NSView *qcard = [self cardWithIdentifier:@"room.queue"];
    self.queueCard = qcard;
    self.queueCaption = RLPLabel(RLPTr(@"播放队列"), t.heading, t.text);
    self.queueCaption.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *qAll = [NSButton buttonWithTitle:RLPTr(@"查看全部") target:self action:@selector(onOpenQueue:)];
    qAll.bezelStyle = NSBezelStyleRounded;
    qAll.translatesAutoresizingMaskIntoConstraints = NO;
    self.queueAllButton = qAll;
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

        [self.npCover.leadingAnchor constraintEqualToAnchor:np.leadingAnchor constant:20],
        [self.npCover.centerYAnchor constraintEqualToAnchor:np.centerYAnchor],
        [self.npCover.widthAnchor constraintEqualToConstant:180],
        [self.npCover.heightAnchor constraintEqualToConstant:180],

        // 右侧文字列：状态 → 大曲名 → 副标题 → 两个按钮（每个都必须显式定位，
        // 否则无约束控件全堆在 (0,0) 重叠成一团 —— 离屏截图实测到的真 bug）。
        [self.npState.leadingAnchor constraintEqualToAnchor:self.npCover.trailingAnchor constant:20],
        [self.npState.topAnchor constraintEqualToAnchor:np.topAnchor constant:28],
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
        [self.queueList.bottomAnchor constraintLessThanOrEqualToAnchor:qcard.bottomAnchor constant:-12],
    ]];
}

- (void)viewDidLayout {
    [super viewDidLayout];
    const CGFloat w = self.view.bounds.size.width;
    if (w > 48.0) [self updateResponsiveLayoutForWidth:w - 48.0];
}

- (void)updateResponsiveLayoutForWidth:(CGFloat)availWidth {
    const CGFloat w = availWidth > 100.0 ? availWidth : 1052.0;
    const NSInteger cols = RLPQuickStartColumnsForWidth(w);
    if (cols != self.currentCardColumns && self.cardsContainer) {
        [NSLayoutConstraint deactivateConstraints:self.cardsLayoutConstraints];
        [self.cardsLayoutConstraints removeAllObjects];
        self.currentCardColumns = cols;

        NSView *c = self.cardsContainer;
        NSView *c1 = self.deviceCard, *c2 = self.outputCard, *c3 = self.playCard, *c4 = self.styleCard;
        if (cols == 4) {
            [self.cardsLayoutConstraints addObjectsFromArray:@[
                [c1.leadingAnchor constraintEqualToAnchor:c.leadingAnchor],
                [c1.topAnchor constraintEqualToAnchor:c.topAnchor],
                [c1.heightAnchor constraintEqualToConstant:100],
                [c2.leadingAnchor constraintEqualToAnchor:c1.trailingAnchor constant:12],
                [c2.topAnchor constraintEqualToAnchor:c.topAnchor],
                [c2.widthAnchor constraintEqualToAnchor:c1.widthAnchor],
                [c2.heightAnchor constraintEqualToAnchor:c1.heightAnchor],
                [c3.leadingAnchor constraintEqualToAnchor:c2.trailingAnchor constant:12],
                [c3.topAnchor constraintEqualToAnchor:c.topAnchor],
                [c3.widthAnchor constraintEqualToAnchor:c1.widthAnchor],
                [c3.heightAnchor constraintEqualToAnchor:c1.heightAnchor],
                [c4.leadingAnchor constraintEqualToAnchor:c3.trailingAnchor constant:12],
                [c4.trailingAnchor constraintEqualToAnchor:c.trailingAnchor],
                [c4.topAnchor constraintEqualToAnchor:c.topAnchor],
                [c4.widthAnchor constraintEqualToAnchor:c1.widthAnchor],
                [c4.heightAnchor constraintEqualToAnchor:c1.heightAnchor],
                [c.bottomAnchor constraintEqualToAnchor:c1.bottomAnchor],
            ]];
        } else if (cols == 2) {
            [self.cardsLayoutConstraints addObjectsFromArray:@[
                [c1.leadingAnchor constraintEqualToAnchor:c.leadingAnchor],
                [c1.topAnchor constraintEqualToAnchor:c.topAnchor],
                [c1.heightAnchor constraintEqualToConstant:96],
                [c2.leadingAnchor constraintEqualToAnchor:c1.trailingAnchor constant:12],
                [c2.trailingAnchor constraintEqualToAnchor:c.trailingAnchor],
                [c2.topAnchor constraintEqualToAnchor:c.topAnchor],
                [c2.widthAnchor constraintEqualToAnchor:c1.widthAnchor],
                [c2.heightAnchor constraintEqualToAnchor:c1.heightAnchor],
                [c3.leadingAnchor constraintEqualToAnchor:c.leadingAnchor],
                [c3.topAnchor constraintEqualToAnchor:c1.bottomAnchor constant:10],
                [c3.widthAnchor constraintEqualToAnchor:c1.widthAnchor],
                [c3.heightAnchor constraintEqualToAnchor:c1.heightAnchor],
                [c4.leadingAnchor constraintEqualToAnchor:c3.trailingAnchor constant:12],
                [c4.trailingAnchor constraintEqualToAnchor:c.trailingAnchor],
                [c4.topAnchor constraintEqualToAnchor:c3.topAnchor],
                [c4.widthAnchor constraintEqualToAnchor:c1.widthAnchor],
                [c4.heightAnchor constraintEqualToAnchor:c1.heightAnchor],
                [c.bottomAnchor constraintEqualToAnchor:c3.bottomAnchor],
            ]];
        } else {
            [self.cardsLayoutConstraints addObjectsFromArray:@[
                [c1.leadingAnchor constraintEqualToAnchor:c.leadingAnchor],
                [c1.trailingAnchor constraintEqualToAnchor:c.trailingAnchor],
                [c1.topAnchor constraintEqualToAnchor:c.topAnchor],
                [c1.heightAnchor constraintEqualToConstant:88],
                [c2.leadingAnchor constraintEqualToAnchor:c.leadingAnchor],
                [c2.trailingAnchor constraintEqualToAnchor:c.trailingAnchor],
                [c2.topAnchor constraintEqualToAnchor:c1.bottomAnchor constant:10],
                [c2.heightAnchor constraintEqualToAnchor:c1.heightAnchor],
                [c3.leadingAnchor constraintEqualToAnchor:c.leadingAnchor],
                [c3.trailingAnchor constraintEqualToAnchor:c.trailingAnchor],
                [c3.topAnchor constraintEqualToAnchor:c2.bottomAnchor constant:10],
                [c3.heightAnchor constraintEqualToAnchor:c1.heightAnchor],
                [c4.leadingAnchor constraintEqualToAnchor:c.leadingAnchor],
                [c4.trailingAnchor constraintEqualToAnchor:c.trailingAnchor],
                [c4.topAnchor constraintEqualToAnchor:c3.bottomAnchor constant:10],
                [c4.heightAnchor constraintEqualToAnchor:c1.heightAnchor],
                [c.bottomAnchor constraintEqualToAnchor:c4.bottomAnchor],
            ]];
        }
        [NSLayoutConstraint activateConstraints:self.cardsLayoutConstraints];
    }

    const BOOL stacked = (w <= 750.0);
    if ((!self.npQueueLayoutInitialized || stacked != self.currentNpStacked) && self.npQueueRow) {
        [NSLayoutConstraint deactivateConstraints:self.npQueueConstraints];
        [self.npQueueConstraints removeAllObjects];
        self.npQueueLayoutInitialized = YES;
        self.currentNpStacked = stacked;

        NSView *row = self.npQueueRow, *np = self.npCard, *qcard = self.queueCard;
        if (!stacked) {
            [self.npQueueConstraints addObjectsFromArray:@[
                [np.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
                [np.topAnchor constraintEqualToAnchor:row.topAnchor],
                [np.heightAnchor constraintEqualToConstant:232],
                [np.trailingAnchor constraintEqualToAnchor:qcard.leadingAnchor constant:-12],
                [qcard.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
                [qcard.topAnchor constraintEqualToAnchor:row.topAnchor],
                [qcard.widthAnchor constraintEqualToConstant:300],
                [qcard.heightAnchor constraintEqualToAnchor:np.heightAnchor],
                [row.bottomAnchor constraintEqualToAnchor:np.bottomAnchor],
            ]];
        } else {
            [self.npQueueConstraints addObjectsFromArray:@[
                [np.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
                [np.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
                [np.topAnchor constraintEqualToAnchor:row.topAnchor],
                [np.heightAnchor constraintEqualToConstant:220],
                [qcard.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
                [qcard.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
                [qcard.topAnchor constraintEqualToAnchor:np.bottomAnchor constant:12],
                [qcard.heightAnchor constraintEqualToConstant:176],
                [row.bottomAnchor constraintEqualToAnchor:qcard.bottomAnchor],
            ]];
        }
        [NSLayoutConstraint activateConstraints:self.npQueueConstraints];
    }

    if (self.albumRow && self.albumRow.arrangedSubviews.count > 1) {
        const NSInteger maxAlbums = MAX(1, (NSInteger)floor((w + 12.0) / 116.0));
        NSArray<NSView *> *items = self.albumRow.arrangedSubviews;
        for (NSUInteger i = 0; i < items.count; ++i) {
            if ([items[i] isKindOfClass:[NSTextField class]]) continue; // 空态提示标签不隐藏
            items[i].hidden = ((NSInteger)i >= maxAlbums);
        }
    }
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
    self.openLibButton = openLib;
    [head addSubview:at];
    [head addSubview:openLib];
    [self.stack addArrangedSubview:head];

    self.albumRow = [[NSStackView alloc] init];
    self.albumRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.albumRow.spacing = 12;
    self.albumRow.detachesHiddenViews = YES;
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
    self.moreButton = more;
    for (NSView *v in @[self.libDesc, self.libButton, more]) [c addSubview:v];
    [self.stack addArrangedSubview:c];
    [NSLayoutConstraint activateConstraints:@[
        [c.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48],
        [c.heightAnchor constraintGreaterThanOrEqualToConstant:64],
        [self.libDesc.leadingAnchor constraintEqualToAnchor:c.leadingAnchor constant:14],
        [self.libDesc.topAnchor constraintEqualToAnchor:c.topAnchor constant:12],
        [self.libDesc.trailingAnchor constraintEqualToAnchor:more.leadingAnchor constant:-12],
        [self.libButton.leadingAnchor constraintEqualToAnchor:c.leadingAnchor constant:14],
        [self.libButton.topAnchor constraintEqualToAnchor:self.libDesc.bottomAnchor constant:6],
        [self.libButton.bottomAnchor constraintLessThanOrEqualToAnchor:c.bottomAnchor constant:-10],
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
    (void)sender;
    RLPTheme *t = [RLPTheme current];
    NSString *bk = [self str:@"backend" def:@"coreaudio"];
    NSString *upnpDev = [self str:@"upnpdev" def:@""];
    self.outputDraftBackend = bk;
    self.outputDraftUpnpDev = upnpDev;
    const BOOL hog = [self str:@"hogexcl" def:@"1"].boolValue;

    NSStackView *s = [self popStackWithTitle:RLPTr(@"输出方式")
        note:RLPTr(@"独占播放音质最稳；共享播放和其它 App 一起出声。")];
    NSArray *opts = @[
        @[@"coreaudio", RLPTr(@"本机 · 独占播放"), RLPTr(@"独占设备，音质最稳（推荐）")],
        @[@"coreaudio-shared", RLPTr(@"本机 · 共享播放"), RLPTr(@"和其它 App 一起出声，兼容性最好")],
        @[@"upnp", RLPTr(@"投放到局域网设备"), RLPTr(@"投到支持 UPnP/DLNA 的播放器")],
    ];
    NSMutableArray<NSButton *> *bkBtns = [NSMutableArray array];
    for (NSArray *o in opts) {
        NSButton *b = [self popRowWithTitle:o[1] note:o[2] on:[bk isEqualToString:o[0]]
                                     action:@selector(onPickBackend:) ident:o[0]];
        [s addArrangedSubview:b];
        [[b.widthAnchor constraintEqualToConstant:330] setActive:YES];
        [bkBtns addObject:b];
        NSTextField *sub = RLPLabel(o[2], t.small, t.mut);
        sub.maximumNumberOfLines = 0;
        sub.lineBreakMode = NSLineBreakByWordWrapping;
        sub.preferredMaxLayoutWidth = 330;
        [s addArrangedSubview:sub];
        [[sub.widthAnchor constraintEqualToConstant:330] setActive:YES];
    }
    self.outputBackendButtons = bkBtns;

    // ---- UPnP 发现与具体设备选择（同一浮层内完成，不嵌套浮层）----
    NSTextField *upnpTitle = RLPLabel(RLPTr(@"局域网投放设备"), t.small, t.mut);
    [s addArrangedSubview:upnpTitle];
    [[upnpTitle.widthAnchor constraintEqualToConstant:330] setActive:YES];

    NSPopUpButton *upnpPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    upnpPopup.identifier = @"output.upnpDevice";
    upnpPopup.font = t.body;
    upnpPopup.target = self;
    upnpPopup.action = @selector(onUpnpDevicePopupChanged:);
    upnpPopup.translatesAutoresizingMaskIntoConstraints = NO;
    [s addArrangedSubview:upnpPopup];
    [[upnpPopup.widthAnchor constraintEqualToConstant:330] setActive:YES];
    self.outputUpnpPopup = upnpPopup;

    NSStackView *upnpActions = [[NSStackView alloc] init];
    upnpActions.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    upnpActions.spacing = 8;
    upnpActions.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *scanBtn = [NSButton buttonWithTitle:RLPTr(@"发现网络播放器") target:self action:@selector(onScanUpnpDevices:)];
    scanBtn.identifier = @"output.upnpScan";
    scanBtn.bezelStyle = NSBezelStyleRounded;
    NSButton *applyBtn = [NSButton buttonWithTitle:RLPTr(@"应用投放设备") target:self action:@selector(onApplyUpnpOutput:)];
    applyBtn.identifier = @"output.upnpApply";
    applyBtn.bezelStyle = NSBezelStyleRounded;
    [upnpActions addArrangedSubview:scanBtn];
    [upnpActions addArrangedSubview:applyBtn];
    [s addArrangedSubview:upnpActions];
    self.outputUpnpScanButton = scanBtn;
    self.outputUpnpApplyButton = applyBtn;

    NSTextField *upnpStatus = RLPLabel(@"", t.small, t.mut);
    upnpStatus.identifier = @"output.upnpStatus";
    upnpStatus.maximumNumberOfLines = 0;
    upnpStatus.lineBreakMode = NSLineBreakByWordWrapping;
    upnpStatus.preferredMaxLayoutWidth = 330;
    [s addArrangedSubview:upnpStatus];
    [[upnpStatus.widthAnchor constraintEqualToConstant:330] setActive:YES];
    self.outputUpnpStatusLabel = upnpStatus;

    // 严格独占：副作用必须如实写清（macOS Hog 机制限制，实测确认）
    NSButton *hogBtn = [NSButton checkboxWithTitle:RLPTr(@"严格独占（抢 Hog Mode）") target:self action:@selector(onToggleHog:)];
    hogBtn.identifier = @"output.hogexcl";
    hogBtn.state = hog ? NSControlStateValueOn : NSControlStateValueOff;
    hogBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [s addArrangedSubview:hogBtn];
    self.outputHogCheck = hogBtn;

    NSTextField *hogNote = RLPLabel(RLPTr(@"开启后系统音量条与音量键会失效，只能用本程序的音量条；它不能阻止其它 App 播放。"),
        t.small, t.warn);
    hogNote.maximumNumberOfLines = 0;
    hogNote.lineBreakMode = NSLineBreakByWordWrapping;
    hogNote.preferredMaxLayoutWidth = 330;
    [s addArrangedSubview:hogNote];
    [[hogNote.widthAnchor constraintEqualToConstant:330] setActive:YES];

    [self syncOutputPopoverState];
    [self showPopoverFrom:self.outputCard withCard:s width:360 minH:370];
    if ([bk isEqualToString:@"upnp"] && [RLPCoreClient shared].started && !self.castDevices.count) {
        [self discoverCastDevicesForce:NO];
    }
}

- (void)syncOutputPopoverState {
    RLPTheme *t = [RLPTheme current];
    NSString *bk = self.outputDraftBackend.length ? self.outputDraftBackend : [self str:@"backend" def:@"coreaudio"];
    for (NSButton *b in self.outputBackendButtons) {
        const BOOL on = [b.identifier isEqualToString:bk];
        b.font = [NSFont systemFontOfSize:13 weight:on ? NSFontWeightSemibold : NSFontWeightRegular];
        b.contentTintColor = on ? t.accentText : t.text;
    }
    if (self.outputHogCheck) {
        self.outputHogCheck.enabled = [bk isEqualToString:@"coreaudio"];
    }
    NSPopUpButton *pop = self.outputUpnpPopup;
    if (pop) {
        [pop removeAllItems];
        NSString *wanted = self.outputDraftUpnpDev ?: @"";
        NSInteger selectIdx = -1;
        for (NSUInteger i = 0; i < self.castDevices.count; ++i) {
            NSDictionary<NSString *, NSString *> *d = self.castDevices[i];
            NSString *name = d[@"name"].length ? d[@"name"] : RLPTr(@"网络播放器");
            NSString *devId = d[@"id"] ?: @"";
            [pop addItemWithTitle:name];
            [[pop lastItem] setRepresentedObject:devId];
            if (wanted.length && [devId isEqualToString:wanted]) {
                selectIdx = (NSInteger)i;
            }
        }
        if (selectIdx < 0 && wanted.length) {
            [pop addItemWithTitle:wanted];
            [[pop lastItem] setRepresentedObject:wanted];
            selectIdx = pop.numberOfItems - 1;
        }
        if (pop.numberOfItems == 0) {
            [pop addItemWithTitle:RLPTr(@"（尚未发现设备）")];
            [[pop lastItem] setRepresentedObject:@""];
            pop.enabled = NO;
        } else {
            pop.enabled = YES;
            if (selectIdx < 0) selectIdx = 0;
            [pop selectItemAtIndex:selectIdx];
            NSString *picked = [pop.selectedItem.representedObject isKindOfClass:[NSString class]]
                ? pop.selectedItem.representedObject : @"";
            if (!self.outputDraftUpnpDev.length && picked.length) {
                self.outputDraftUpnpDev = picked;
            }
        }
    }
    if (self.outputUpnpApplyButton) {
        NSString *picked = [self.outputUpnpPopup.selectedItem.representedObject isKindOfClass:[NSString class]]
            ? self.outputUpnpPopup.selectedItem.representedObject : @"";
        self.outputUpnpApplyButton.enabled = (picked.length > 0);
    }
}

- (void)applyCastDevicesPayload:(NSDictionary * _Nullable)json {
    RLPTheme *t = [RLPTheme current];
    if (!json || ![json[@"ok"] boolValue]) {
        NSString *err = [json[@"error"] isKindOfClass:[NSString class]] && [json[@"error"] length]
            ? json[@"error"] : RLPTr(@"设备发现失败（/api/cast/devices 无响应）");
        if (self.outputUpnpStatusLabel) {
            self.outputUpnpStatusLabel.stringValue = err;
            self.outputUpnpStatusLabel.textColor = t.warn;
        }
        [self syncOutputPopoverState];
        return;
    }
    self.castDevices = RLPNormalizeCastDevices(json[@"devices"]);
    if (!self.outputDraftUpnpDev.length && self.castDevices.count) {
        self.outputDraftUpnpDev = self.castDevices.firstObject[@"id"] ?: @"";
    }
    if (self.outputUpnpStatusLabel) {
        self.outputUpnpStatusLabel.textColor = t.mut;
        if (self.castDevices.count) {
            self.outputUpnpStatusLabel.stringValue = [NSString stringWithFormat:RLPTr(@"共发现 %lu 台设备"),
                (unsigned long)self.castDevices.count];
        } else {
            NSString *hint = [json[@"hint"] isKindOfClass:[NSString class]] ? json[@"hint"] : @"";
            self.outputUpnpStatusLabel.stringValue = hint.length ? hint
                : RLPTr(@"暂未发现网络播放器，请确认它已开启并连接同一网络。");
        }
    }
    [self syncOutputPopoverState];
    [self syncOutputSummary];
}

- (void)discoverCastDevicesForce:(BOOL)force {
    if (![RLPCoreClient shared].started) return;
    const NSUInteger seq = ++self.castDiscoverSeq;
    RLPTheme *t = [RLPTheme current];
    if (self.outputUpnpScanButton) self.outputUpnpScanButton.enabled = NO;
    if (self.outputUpnpStatusLabel) {
        self.outputUpnpStatusLabel.textColor = t.mut;
        self.outputUpnpStatusLabel.stringValue = RLPTr(@"正在发现网络播放器…");
    }
    NSString *url = force ? @"/api/cast/devices?scan=1" : @"/api/cast/devices";
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.castDiscoverSeq) return;
        if (self_.outputUpnpScanButton) self_.outputUpnpScanButton.enabled = YES;
        [self_ applyCastDevicesPayload:json];
    }];
}

- (void)onScanUpnpDevices:(id)sender {
    (void)sender;
    [self discoverCastDevicesForce:YES];
}

- (void)onUpnpDevicePopupChanged:(NSPopUpButton *)sender {
    NSString *devId = [sender.selectedItem.representedObject isKindOfClass:[NSString class]]
        ? sender.selectedItem.representedObject : @"";
    self.outputDraftUpnpDev = devId;
    [self syncOutputPopoverState];
}

- (void)onApplyUpnpOutput:(id)sender {
    (void)sender;
    NSString *devId = self.outputDraftUpnpDev.length ? self.outputDraftUpnpDev
        : ([self.outputUpnpPopup.selectedItem.representedObject isKindOfClass:[NSString class]]
           ? self.outputUpnpPopup.selectedItem.representedObject : @"");
    if (!devId.length) {
        RLPToast(RLPTr(@"请先选择网络播放器"));
        return;
    }
    [self postSettings:RLPOutputSettingsPatchForBackend(@"upnp", devId, self.localDevice)];
    [self.popover close];
}

- (void)onPickBackend:(NSButton *)sender {
    NSString *bk = sender.identifier;
    if (!bk.length) return;
    if ([bk isEqualToString:@"upnp"]) {
        self.outputDraftBackend = @"upnp";
        [self syncOutputPopoverState];
        if (!self.castDevices.count && [RLPCoreClient shared].started) {
            [self discoverCastDevicesForce:NO];
        }
        return;
    }
    [self postSettings:RLPOutputSettingsPatchForBackend(bk, nil, self.localDevice)];
    [self.popover close];
}
- (void)onToggleHog:(NSButton *)sender {
    [self postSettings:@{@"hogexcl": (sender.state == NSControlStateValueOn ? @"1" : @"0")}];
}

#pragma mark 播放弹层（三档）

- (void)onOpenPlay:(id)sender {
    const BOOL isDsd = RLPPathIsDsd(self.currentPath);
    const BOOL active = [self playbackIsActive];
    NSString *popNote = active
        ? RLPTr(@"当前正在播放或暂停：切换播放方式只保存设置，将于下一首或重新播放时生效（不会中断当前播放）。")
        : RLPTr(@"不确定就选「原音直通」：文件是什么就播什么。");
    NSStackView *s = [self popStackWithTitle:RLPTr(@"播放方式")
        note:popNote];
    NSDictionary<NSString *, NSDictionary *> *statuses =
        [[self class] presetStatusForCapsJSON:self.presetCapsJSON
                                     settings:self.settings
                                      playing:self.playing
                                       paused:self.pausedNow];
    NSString *curProf = RLPPlayModeFromSettings(self.settings);
    NSArray *opts = @[
        @[@0, @"bitperfect", RLPTr(@"原音直通"), RLPTr(@"文件是什么就播什么，不做任何加工")],
        @[@1, @"pcm",        RLPTr(@"PCM 升频"), RLPTr(@"把普通高清音源提升到设备支持的更高采样率")],
        @[@2, isDsd ? @"dsd" : @"pcm2dsd", RLPTr(@"DSD 升频"), RLPTr(@"转换成 DSD 信号输出，声音更绵密（需要设备支持 DoP）")],
    ];
    NSMutableArray<NSString *> *reasons = [NSMutableArray array];
    for (NSArray *o in opts) {
        NSString *pkey = o[1];
        NSDictionary *st = statuses[pkey];
        const BOOL enabled = [st[@"enabled"] boolValue];
        NSString *reason = [st[@"reason"] isKindOfClass:[NSString class]] ? st[@"reason"] : @"";
        NSString *result = [st[@"result"] isKindOfClass:[NSString class]] ? st[@"result"] : @"";
        const BOOL isCurrent = ([curProf isEqualToString:pkey] ||
                                ([pkey isEqualToString:@"pcm2dsd"] && [curProf isEqualToString:@"dsd"]));
        NSButton *b = [self popRowWithTitle:o[2] note:o[3] on:isCurrent action:@selector(onPickPlayMode:) ident:[o[0] stringValue]];
        b.enabled = enabled;
        if (!enabled && reason.length) {
            b.toolTip = reason;
            if (![reasons containsObject:reason]) [reasons addObject:reason];
        }
        [s addArrangedSubview:b];
        [[b.widthAnchor constraintEqualToConstant:330] setActive:YES];
        NSString *subText = enabled ? (result.length ? result : o[3])
                                    : (reason.length ? [NSString stringWithFormat:@"%@ · %@", o[3], reason] : o[3]);
        NSTextField *sub = RLPLabel(subText, [RLPTheme current].small,
                                    enabled ? [RLPTheme current].mut : [RLPTheme current].warn);
        sub.maximumNumberOfLines = 0;
        sub.lineBreakMode = NSLineBreakByWordWrapping;
        sub.preferredMaxLayoutWidth = 330;
        [s addArrangedSubview:sub];
        [[sub.widthAnchor constraintEqualToConstant:330] setActive:YES];
    }
    if (reasons.count) {
        NSTextField *gate = RLPLabel([reasons componentsJoinedByString:@" "],
                                     [RLPTheme current].small, [RLPTheme current].mut2);
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

    NSButton *retryCaps = [NSButton buttonWithTitle:RLPTr(@"重新读取设备能力") target:self action:@selector(onRetryCaps:)];
    retryCaps.bezelStyle = NSBezelStyleRounded;
    retryCaps.translatesAutoresizingMaskIntoConstraints = NO;
    [s addArrangedSubview:retryCaps];

    [self showPopoverFrom:self.playCard withCard:s width:360 minH:290];
}

- (void)onRetryCaps:(id)sender {
    (void)sender;
    [self loadPresetCaps:YES];
    RLPToast(RLPTr(@"正在重新读取设备能力…"));
    [self.popover close];
}

/// 是否正在播放或暂停（上游 `S.playing||S.paused`）。用页面已轮询到的状态，
/// 不新开一条轮询：`self.webStatus` 是该页唯一的状态快照。
- (BOOL)playbackIsActive {
    return self.playing || self.pausedNow;
}

+ (NSDictionary<NSString *, NSString *> *)playModeFeedbackForNotes:(NSArray * _Nullable)notes
                                                  playbackActive:(BOOL)active {
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    if ([notes isKindOfClass:[NSArray class]]) {
        for (id item in notes) {
            if ([item isKindOfClass:[NSString class]] && [(NSString *)item length]) {
                [clean addObject:(NSString *)item];
            }
        }
    }
    NSString *joined = clean.count ? [clean componentsJoinedByString:@"；"] : @"";
    if (active) {
        NSString *prefix = RLPTr(@"已保存设置，将在下一首或重新播放时生效");
        NSString *banner = joined.length ? [NSString stringWithFormat:@"%@ · %@", prefix, joined] : prefix;
        return @{ @"toast": prefix, @"notes": banner };
    }
    return @{
        @"toast": RLPTr(@"已应用"),
        @"notes": joined.length ? joined : RLPTr(@"已应用"),
    };
}

- (void)onPickPlayMode:(NSButton *)sender {
    const RLPPlayMode3 mode = (RLPPlayMode3)sender.identifier.integerValue;
    NSString *profile = RLPProfileForPlayMode(mode, RLPPathIsDsd(self.currentPath));
    const BOOL active = [self playbackIsActive];
    [self.popover close];
    self.playValue.stringValue = (mode == RLPPlayMode3Direct ? RLPTr(@"原音直通")
                                 : mode == RLPPlayMode3Pcm ? RLPTr(@"PCM 升频") : RLPTr(@"DSD 升频"));
    self.presetNotes.stringValue = active
        ? RLPTr(@"正在保存设置（下一首或重新播放时生效）…")
        : RLPTr(@"正在应用…");
    NSString *path = [NSString stringWithFormat:@"/api/preset/apply?profile=%@", RLPEnc(profile)];
    const NSUInteger writeSeq = ++self.settingsWriteSeq;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:path body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || writeSeq != self_.settingsWriteSeq) return;
        if (json && [json[@"ok"] boolValue]) {
            // notes 是后端给的决策说明（含降级原因），照实显示，不自己编"已优化"。
            NSArray *notes = [json[@"notes"] isKindOfClass:[NSArray class]] ? json[@"notes"] : @[];
            const BOOL deferred = active || [self_ playbackIsActive];
            NSDictionary<NSString *, NSString *> *fb =
                [[self_ class] playModeFeedbackForNotes:notes playbackActive:deferred];
            self_.presetNotes.stringValue = fb[@"notes"];
            RLPToast(fb[@"toast"]);
            [self_ reloadSettings];
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPSettingsChangedNotification
                                                                object:self_];
        } else {
            NSString *err = ([json[@"error"] isKindOfClass:[NSString class]] && [(NSString *)json[@"error"] length])
                ? json[@"error"] : RLPTr(@"应用失败");
            self_.presetNotes.stringValue = err;
            RLPToast(err);
            [self_ syncPlayAndStyleCards];
        }
    }];
}

#pragma mark 听音风格弹层

- (void)onOpenStyle:(id)sender {
    const BOOL straight = [RLPPlayModeFromSettings(self.settings) isEqualToString:@"bitperfect"];
    NSStackView *s = [self popStackWithTitle:RLPTr(@"听音风格")
        note:RLPTr(@"不用懂滤波：往温和走声音更柔顺，往锐利走更清亮。")];
    if (straight) {
        NSTextField *bpNote = RLPLabel(
            RLPTr(@"当前保持原音直通，听音风格暂不可用（不偷偷破坏直通）。如需调整听音风格，请先在「播放」中选择 PCM 升频或 DSD 升频。"),
            [RLPTheme current].small, [RLPTheme current].warn);
        bpNote.identifier = @"quickstart.styleBitperfectNote";
        bpNote.maximumNumberOfLines = 0;
        bpNote.lineBreakMode = NSLineBreakByWordWrapping;
        bpNote.preferredMaxLayoutWidth = 330;
        [s addArrangedSubview:bpNote];
        [[bpNote.widthAnchor constraintEqualToConstant:330] setActive:YES];
    }
    if (!self.filters.count) {
        NSTextField *na = RLPLabel(RLPTr(@"滤波列表读取失败，请稍后重试"), [RLPTheme current].small, [RLPTheme current].warn);
        [s addArrangedSubview:na];
        [[na.widthAnchor constraintEqualToConstant:330] setActive:YES];
    }
    NSString *curFilter = [self str:@"filter" def:@""];
    for (NSInteger i = RLPToneStyleSharp; i <= RLPToneStyleWarm; ++i) {
        NSString *name = RLPFilterForToneStyle((RLPToneStyle)i, self.filters);
        NSButton *b = [self popRowWithTitle:RLPToneStyleName((RLPToneStyle)i) note:name ?: @""
                                          on:(!straight && [curFilter isEqualToString:name ?: @""])
                                      action:@selector(onPickStyle:) ident:[@(i) stringValue]];
        b.enabled = !straight && (name.length > 0);
        [s addArrangedSubview:b];
        [[b.widthAnchor constraintEqualToConstant:330] setActive:YES];
        // 滤波真名只作副标题小字：让人不用懂滤波也能挑
        NSTextField *sub = RLPLabel(name ?: RLPTr(@"无可用滤波"), [RLPTheme current].small, [RLPTheme current].mut);
        [s addArrangedSubview:sub];
        [[sub.widthAnchor constraintEqualToConstant:330] setActive:YES];
    }
    [self showPopoverFrom:self.styleCard withCard:s width:360 minH:straight ? 270 : 230];
}

- (void)onPickStyle:(NSButton *)sender {
    if ([RLPPlayModeFromSettings(self.settings) isEqualToString:@"bitperfect"]) {
        RLPToast(RLPTr(@"原音直通模式下听音风格不可用"));
        [self.popover close];
        return;
    }
    const RLPToneStyle st = (RLPToneStyle)sender.identifier.integerValue;
    NSDictionary<NSString *, NSString *> *patch = RLPSettingsPatchForToneStyle(st, self.filters);
    if (!patch.count) { RLPToast(RLPTr(@"没有可用滤波")); return; }
    [self postSettings:patch];
    [self.popover close];
}

#pragma mark 音乐文件夹弹层（页头入口，对标 Windows ui_listening_library）

- (void)onOpenFolders:(id)sender {
    (void)sender;
    RLPTheme *t = [RLPTheme current];
    NSStackView *s = [self popStackWithTitle:RLPTr(@"音乐文件夹")
        note:RLPTr(@"选择保存音乐的文件夹，添加后会自动整理歌曲。")];
    NSStackView *listStack = [[NSStackView alloc] init];
    listStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    listStack.alignment = NSLayoutAttributeLeading;
    listStack.spacing = 6;
    listStack.translatesAutoresizingMaskIntoConstraints = NO;
    [s addArrangedSubview:listStack];
    [[listStack.widthAnchor constraintEqualToConstant:360] setActive:YES];

    NSTextField *loading = RLPLabel(RLPTr(@"正在读取音乐文件夹…"), t.small, t.mut);
    [listStack addArrangedSubview:loading];

    NSStackView *actions = [[NSStackView alloc] init];
    actions.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    actions.spacing = 8;
    NSButton *addBtn = [NSButton buttonWithTitle:RLPTr(@"添加文件夹…") target:self action:@selector(onFoldersAdd:)];
    addBtn.bezelStyle = NSBezelStyleRounded;
    NSButton *scanBtn = [NSButton buttonWithTitle:RLPTr(@"刷新音乐库") target:self action:@selector(onFoldersScan:)];
    scanBtn.bezelStyle = NSBezelStyleRounded;
    [actions addArrangedSubview:addBtn];
    [actions addArrangedSubview:scanBtn];
    [s addArrangedSubview:actions];

    NSTextField *statsLabel = RLPLabel(@"", t.small, t.mut);
    statsLabel.maximumNumberOfLines = 2;
    statsLabel.lineBreakMode = NSLineBreakByWordWrapping;
    statsLabel.preferredMaxLayoutWidth = 360;
    [s addArrangedSubview:statsLabel];
    [[statsLabel.widthAnchor constraintEqualToConstant:360] setActive:YES];

    NSTextField *keepNote = RLPLabel(RLPTr(@"移除只会更改音乐库列表，音乐文件会保留。"), t.small, t.mut2);
    keepNote.maximumNumberOfLines = 0;
    keepNote.lineBreakMode = NSLineBreakByWordWrapping;
    keepNote.preferredMaxLayoutWidth = 360;
    [s addArrangedSubview:keepNote];
    [[keepNote.widthAnchor constraintEqualToConstant:360] setActive:YES];

    [self showPopoverFrom:(self.foldersButton ?: self.libButton) withCard:s width:392 minH:230];

    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/lib/stats" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        for (NSView *v in [listStack.arrangedSubviews copy]) {
            [listStack removeArrangedSubview:v];
            [v removeFromSuperview];
        }
        NSArray *roots = [json[@"roots"] isKindOfClass:[NSArray class]] ? json[@"roots"] : @[];
        if (!roots.count) {
            NSTextField *empty = RLPLabel(RLPTr(@"还没有添加音乐文件夹。"), t.small, t.mut);
            [listStack addArrangedSubview:empty];
        } else {
            for (id r in roots) {
                if (![r isKindOfClass:[NSString class]] || ![(NSString *)r length]) continue;
                NSString *path = (NSString *)r;
                NSView *row = [[NSView alloc] initWithFrame:NSZeroRect];
                row.translatesAutoresizingMaskIntoConstraints = NO;
                NSTextField *pl = RLPLabel(path, t.small, t.text);
                pl.lineBreakMode = NSLineBreakByTruncatingMiddle;
                pl.translatesAutoresizingMaskIntoConstraints = NO;
                NSButton *rm = [NSButton buttonWithTitle:RLPTr(@"移除") target:self_ action:@selector(onFoldersRemove:)];
                rm.identifier = path;
                rm.bezelStyle = NSBezelStyleRounded;
                rm.translatesAutoresizingMaskIntoConstraints = NO;
                [row addSubview:pl];
                [row addSubview:rm];
                [listStack addArrangedSubview:row];
                [NSLayoutConstraint activateConstraints:@[
                    [row.widthAnchor constraintEqualToConstant:360],
                    [row.heightAnchor constraintEqualToConstant:26],
                    [pl.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
                    [pl.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
                    [pl.trailingAnchor constraintLessThanOrEqualToAnchor:rm.leadingAnchor constant:-8],
                    [rm.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
                    [rm.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
                ]];
            }
        }
        const BOOL scanning = [json[@"scanning"] boolValue];
        const NSInteger tracks = [json[@"tracks"] integerValue];
        statsLabel.stringValue = scanning
            ? [NSString stringWithFormat:RLPTr(@"正在整理音乐：%ld / %ld"),
               (long)[json[@"scanned"] integerValue], (long)[json[@"total"] integerValue]]
            : [NSString stringWithFormat:RLPTr(@"音乐库共有 %ld 首曲目"), (long)tracks];
    }];
}

- (void)onFoldersAdd:(id)sender {
    (void)sender;
    [self.popover close];
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
                [s2 reloadAlbums];
            } else {
                NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"添加失败");
                RLPToast(err);
            }
        }];
    }];
}

- (void)onFoldersRemove:(NSButton *)sender {
    NSString *path = sender.identifier;
    if (!path.length) return;
    [self.popover close];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/lib/roots"
                                body:[NSString stringWithFormat:@"remove=%@", RLPEnc(path)]
                          completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            RLPPostJSON(@"/api/lib/scan", nil);
            RLPToast(RLPTr(@"已移除目录"));
            [self_ reloadLibrary];
            [self_ reloadAlbums];
        } else {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"移除失败");
            RLPToast(err);
        }
    }];
}

- (void)onFoldersScan:(id)sender {
    (void)sender;
    [self.popover close];
    RLPPostJSON(@"/api/lib/scan?full=1", nil);
    RLPToast(RLPTr(@"已开始全量重扫"));
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
    const NSUInteger writeSeq = ++self.settingsWriteSeq;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in kv) [parts addObject:[NSString stringWithFormat:@"%@=%@", k, RLPEnc(kv[k])]];
    NSString *body = [parts componentsJoinedByString:@"&"];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/settings" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || writeSeq != self_.settingsWriteSeq) return;
        if (json && [json[@"ok"] boolValue]) {
            RLPToast(RLPTr(@"已生效"));
            [self_ reloadSettings];
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPSettingsChangedNotification
                                                                object:self_];
        } else {
            NSString *err = ([json[@"error"] isKindOfClass:[NSString class]] && [(NSString *)json[@"error"] length])
                ? json[@"error"] : RLPTr(@"保存失败");
            [self_ syncDeviceSelection];
            [self_ syncOutputSummary];
            [self_ syncPlayAndStyleCards];
            if (self_.outputHogCheck) {
                self_.outputHogCheck.state = [self_ str:@"hogexcl" def:@"0"].boolValue
                    ? NSControlStateValueOn : NSControlStateValueOff;
            }
            RLPToast(err);
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
    (void)sender;
    ++self.statusEpoch;
    self.statusInflight = NO; // Empty-queue no-op has no completion callback.
    // 与底栏/播放页同一条决策：播放中→暂停、暂停中→继续、已停止且有曲目→/api/play 重播。
    // 不乐观翻转 playing/pausedNow，动作完成后由通知立即刷新状态。
    RLPPlaybackToggle(self.playing, self.pausedNow, self.currentPath);
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
            (void)t; [weakSelf reloadStatusFromTimer];
        }];
    }
}

- (void)reloadStatusFromTimer {
    if (self.statusInflight) return;
    [self reloadStatus];
}

- (void)viewDidDisappear {
    [self.poll invalidate];
    self.poll = nil;
    ++self.statusEpoch;
    self.statusInflight = NO;
    [super viewDidDisappear];
}

- (void)reloadData { [self reloadAll]; }

- (void)reloadAll {
    if (![RLPCoreClient shared].started) { [self setSubtitle:RLPTr(@"核心未启动")]; return; }
    [self reloadDevices];
    [self reloadSettings];
    [self reloadFilters];
    [self reloadPresetCaps:NO];
    [self reloadLibrary];
    [self reloadStatus];
    [self reloadQueue];
    [self reloadAlbums];
}

- (void)reloadPresetCaps:(BOOL)force {
    [self loadPresetCaps:force];
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
        self_.defaultDeviceName = defName;
        [self_ syncDeviceSelection];
    }];
}

- (void)syncDeviceSelection {
    NSString *bk = [self str:@"backend" def:@"coreaudio"];
    NSString *cur = ([bk isEqualToString:@"upnp"] || [bk isEqualToString:@"null"])
        ? (self.localDevice ?: @"")
        : [self str:@"device" def:@""];
    if (!cur.length || [cur isEqualToString:@"null"]) { [self.devicePopup selectItemAtIndex:0]; return; }
    for (NSInteger i = 0; i < (NSInteger)self.devices.count; ++i) {
        if ([self.devices[i][@"id"] isEqualToString:cur]) { [self.devicePopup selectItemAtIndex:i + 1]; return; }
    }
    [self.devicePopup selectItemAtIndex:0];
}

- (void)reloadSettings {
    const NSUInteger seq = ++self.settingsSeq;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/settings" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.settingsSeq) return;
        // ⚠️ /api/settings 的值在 **kv** 子对象里（与设置页同一口径）。
        // 直接读顶层会全部取不到 ⟹ 静默回落默认值，界面显示与真实设置脱节。
        self_.settings = [json[@"kv"] isKindOfClass:[NSDictionary class]] ? json[@"kv"] : @{};
        self_.localDevice = RLPRememberedLocalDevice(self_.settings, self_.localDevice);
        [self_ syncDeviceSelection];
        // 输出摘要（人话）
        NSString *bk = [self_ str:@"backend" def:@"coreaudio"];
        NSString *dev = [self_ str:@"device" def:@""];
        NSString *capsKey = [NSString stringWithFormat:@"%@|%@", bk, dev];
        if (![capsKey isEqualToString:self_.presetCapsKey ?: @""]) {
            self_.presetCapsKey = capsKey;
            [self_ loadPresetCaps:YES];
        }
        [self_ syncOutputSummary];
        [self_ syncPlayAndStyleCards];
    }];
}

- (void)syncOutputSummary {
    NSString *bk = [self str:@"backend" def:@"coreaudio"];
    if ([bk isEqualToString:@"upnp"]) {
        NSString *upnpDev = [self str:@"upnpdev" def:@""];
        NSString *devLabel = nil;
        for (NSDictionary<NSString *, NSString *> *d in self.castDevices) {
            if ([d[@"id"] isEqualToString:upnpDev]) { devLabel = d[@"name"]; break; }
        }
        if (!devLabel.length && upnpDev.length) devLabel = upnpDev;
        self.outputValue.stringValue = devLabel.length
            ? [NSString stringWithFormat:@"%@ · %@", RLPTr(@"局域网投放"), devLabel]
            : RLPTr(@"局域网投放");
        return;
    }
    NSString *bkName = [bk isEqualToString:@"coreaudio-shared"] ? RLPTr(@"共享播放")
                     : [bk isEqualToString:@"null"] ? RLPTr(@"不出声（仅分析）") : RLPTr(@"独占播放");
    const BOOL hog = [self str:@"hogexcl" def:@"1"].boolValue;
    const BOOL hogFallback = (self.lastFallbackWhy.length > 0) ||
                             (self.lastHogAcquired != nil && !self.lastHogAcquired.boolValue);
    NSString *hogSuffix = ([bk isEqualToString:@"coreaudio"] && hog)
        ? (hogFallback ? RLPTr(@" · Hog（已回退）") : @" · Hog")
        : @"";
    self.outputValue.stringValue = [NSString stringWithFormat:@"%@%@", bkName, hogSuffix];
}

- (void)syncPlayAndStyleCards {
    NSString *prof = RLPPlayModeFromSettings(self.settings);
    if ([prof isEqualToString:@"bitperfect"]) {
        self.playValue.stringValue = RLPTr(@"原音直通");
        self.styleValue.stringValue = RLPTr(@"保持原音");
        self.styleSub.stringValue = RLPTr(@"原音直通时听音风格不参与");
        self.styleCard.alphaValue = 0.65;
    } else {
        self.styleCard.alphaValue = 1.0;
        if ([prof isEqualToString:@"pcm"]) self.playValue.stringValue = RLPTr(@"PCM 升频");
        else if ([prof isEqualToString:@"dsd"] || [prof isEqualToString:@"pcm2dsd"]) self.playValue.stringValue = RLPTr(@"DSD 升频");
        else self.playValue.stringValue = RLPTr(@"自定义播放方式");
        NSString *f = [self str:@"filter" def:@""];
        NSInteger st = RLPToneStyleForFilter(f, self.filters);
        self.styleValue.stringValue = (st >= 0) ? RLPToneStyleName((RLPToneStyle)st) : RLPTr(@"自定义");
        self.styleSub.stringValue = f.length ? f : RLPTr(@"跟随默认");
    }
}

- (void)reloadFilters {
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/filters" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        self_.filters = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[];
        [self_ syncPlayAndStyleCards];
    }];
}

- (void)reloadLibrary {
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/lib/roots" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *roots = [json[@"roots"] isKindOfClass:[NSArray class]] ? json[@"roots"] : @[];
        self_.hasLoadedLibrary = YES;
        self_.hasRoots = roots.count > 0;
        self_.libDesc.stringValue = self_.hasRoots
            ? RLPTr(@"音乐目录已就绪 · 可重新扫描更新专辑与封面")
            : RLPTr(@"支持 FLAC · DSD (DSF/DFF) · ALAC · WAV · APE");
        [self_.libButton setTitle:self_.hasRoots ? RLPTr(@"重新扫描音乐库") : RLPTr(@"添加音乐目录")];
    }];
}

- (void)applyStatusJSON:(NSDictionary *)json {
    if (![json isKindOfClass:[NSDictionary class]]) return;
    self.lastHogAcquired = [json[@"hogAcquired"] respondsToSelector:@selector(boolValue)]
        ? @([json[@"hogAcquired"] boolValue]) : nil;
    self.lastFallbackWhy = [json[@"fallbackWhy"] isKindOfClass:[NSString class]] ? json[@"fallbackWhy"] : @"";
    [self syncOutputSummary];
    RLPPlaybackStatus *st = [RLPPlaybackStatus statusFromJSON:json];
    if (!st) return;
    self.hasLoadedStatus = YES;
    self.playing = st.playing && !st.paused;
    self.pausedNow = st.paused;
    NSString *path = st.currentPath ?: @"";
    [self.npToggle setTitle:self.playing ? RLPTr(@"暂停") : RLPTr(@"继续播放")];
    self.npState.stringValue = path.length ? (self.playing ? RLPTr(@"正在播放") : RLPTr(@"已暂停")) : RLPTr(@"未播放");
    if (![path isEqualToString:self.currentPath ?: @""]) {
        self.currentPath = path;
        self.npTitle.stringValue = path.length ? path.lastPathComponent.stringByDeletingPathExtension : RLPTr(@"还没有在播放的音乐");
        self.npSub.stringValue = path.length ? @"" : RLPTr(@"从下面的专辑挑一张开始");
        [self loadCoverForPath:path];
        [self loadMetaForPath:path];
    }
}

- (void)reloadStatus {
    const NSUInteger seq = ++self.statusEpoch;
    self.statusInflight = YES;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/status" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (seq == self_.statusEpoch) self_.statusInflight = NO;
        if (seq != self_.statusEpoch) return;
        [self_ applyStatusJSON:json ?: @{}];
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
            self_.queueEmptyLabel = e;
            [self_.queueList addArrangedSubview:e];
            return;
        }
        self_.queueEmptyLabel = nil;
        NSInteger n = 0;
        for (id it in items) {
            if (n >= 4) break;
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
            self_.albumEmptyLabel = e;
            [self_.albumRow addArrangedSubview:e];
        } else {
            self_.albumEmptyLabel = nil;
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
    const BOOL shared = [backend isEqualToString:@"wasapi-shared"] || [backend isEqualToString:@"coreaudio-shared"];
    const BOOL known = ok && !offline && !remote && name.length > 0 && rates.count > 0 && maxRate > 0;
    const BOOL dsdNative = [dev[@"dsdNative"] respondsToSelector:@selector(boolValue)] &&
                           [dev[@"dsdNative"] boolValue];
    const BOOL dop = [dev[@"dop"] respondsToSelector:@selector(boolValue)] && [dev[@"dop"] boolValue];
    return @{ @"known": @(known),
              @"pcmReady": @(known && !remote && !shared),
              @"dsdReady": @(known && !remote && !shared && (dsdNative || dop)) };
}

+ (NSDictionary<NSString *, NSDictionary *> *)presetStatusForCapsJSON:(NSDictionary * _Nullable)json
                                                           settings:(NSDictionary * _Nullable)kv
                                                            playing:(BOOL)playing
                                                             paused:(BOOL)paused {
    (void)playing;
    (void)paused;
    NSDictionary<NSString *, NSNumber *> *g = [self gatingForCapsJSON:json];
    const BOOL known = [g[@"known"] boolValue];
    const BOOL pcmReady = [g[@"pcmReady"] boolValue];
    const BOOL dsdReady = [g[@"dsdReady"] boolValue];

    NSDictionary *dev = [json[@"device"] isKindOfClass:[NSDictionary class]] ? json[@"device"] : nil;
    NSString *capBackend = [dev[@"backend"] isKindOfClass:[NSString class]] ? dev[@"backend"] : @"";
    NSString *kvBackend = [kv[@"backend"] isKindOfClass:[NSString class]] ? kv[@"backend"] : @"";
    NSString *backend = kvBackend.length ? kvBackend : (capBackend.length ? capBackend : @"coreaudio");
    const BOOL isShared = [backend isEqualToString:@"coreaudio-shared"] || [backend isEqualToString:@"wasapi-shared"];
    const BOOL isOffline = [backend isEqualToString:@"null"];
    const BOOL isRemote = [backend isEqualToString:@"upnp"];
    const BOOL isAirPlay = [backend isEqualToString:@"airplay"];

    double maxRate = [dev[@"maxRate"] respondsToSelector:@selector(doubleValue)] ? [dev[@"maxRate"] doubleValue] : 0.0;
    NSString *dopMax = [dev[@"dopMax"] isKindOfClass:[NSString class]] ? dev[@"dopMax"] : @"";
    const BOOL dsdNative = [dev[@"dsdNative"] respondsToSelector:@selector(boolValue)] && [dev[@"dsdNative"] boolValue];

    NSString *pcmWhy = @"";
    if (isShared || isAirPlay) pcmWhy = RLPTr(@"共享/隔空播放不支持升频，请在「输出」中开启独占设备。");
    else if (isOffline) pcmWhy = RLPTr(@"离线处理模式不连接设备，不支持设备升频。");
    else if (isRemote) pcmWhy = RLPTr(@"网络播放器由远端负责输出，不支持本机升频。");
    else if (!known) pcmWhy = RLPTr(@"能力尚未确认，请先选择输出设备。");
    else if (!pcmReady) pcmWhy = RLPTr(@"当前设备不支持 PCM 升频。");

    NSString *dsdWhy = @"";
    if (isShared || isAirPlay) dsdWhy = RLPTr(@"共享/隔空播放不支持 DSD/DoP，请在「输出」中开启独占设备。");
    else if (isOffline) dsdWhy = RLPTr(@"离线处理模式不连接设备，不支持 DSD 升频。");
    else if (isRemote) dsdWhy = RLPTr(@"网络播放器不支持本机 DoP 升频。");
    else if (!known) dsdWhy = RLPTr(@"能力尚未确认，请先选择输出设备。");
    else if (!dsdReady) dsdWhy = RLPTr(@"当前设备不支持 DoP，无法输出 DSD。");

    NSString *pcmResult = (pcmReady && maxRate > 0)
        ? [NSString stringWithFormat:RLPTr(@"目标采样率最高 %.1f kHz（封顶 384 kHz）"),
           (maxRate > 384000.0 ? 384000.0 : maxRate) / 1000.0]
        : RLPTr(@"按设备能力匹配 PCM 升频规格");
    NSString *dsdResult = dsdReady
        ? (dopMax.length
            ? [NSString stringWithFormat:RLPTr(@"DoP 最高 %@"), dopMax.uppercaseString]
            : (dsdNative ? RLPTr(@"支持 DSD 输出") : RLPTr(@"支持 DoP 输出")))
        : RLPTr(@"需要设备支持 DoP");

    NSDictionary *bpEntry = @{
        @"enabled": @YES,
        @"reason": @"",
        @"result": RLPTr(@"保持源采样率与原始声音（禁用 EQ/IR 与听音风格）"),
    };
    NSDictionary *pcmEntry = @{
        @"enabled": @(pcmReady && !isShared && !isOffline && !isRemote && !isAirPlay),
        @"reason": pcmWhy,
        @"result": pcmResult,
    };
    NSDictionary *dsdEntry = @{
        @"enabled": @(dsdReady && !isShared && !isOffline && !isRemote && !isAirPlay),
        @"reason": dsdWhy,
        @"result": dsdResult,
    };
    return @{
        @"bitperfect": bpEntry,
        @"pcm": pcmEntry,
        @"dsd": dsdEntry,
        @"pcm2dsd": dsdEntry,
    };
}

- (void)applyPresetCaps:(NSDictionary * _Nullable)json {
    self.presetCapsJSON = json;
    NSDictionary<NSString *, NSNumber *> *g = [[self class] gatingForCapsJSON:json];
    self.presetCapsKnown = [g[@"known"] boolValue];
    self.presetPcmReady = [g[@"pcmReady"] boolValue];
    self.presetDsdReady = [g[@"dsdReady"] boolValue];
    NSDictionary *dev = [json[@"device"] isKindOfClass:[NSDictionary class]] ? json[@"device"] : nil;
    self.presetCapsDevice = [dev[@"name"] isKindOfClass:[NSString class]] ? dev[@"name"] : nil;
}

- (void)applyLanguage {
    self.pageTitle = RLPTr(@"聆听室");
    if (!self.isViewLoaded) return;
    if (self.popover.isShown) [self.popover close];

    self.headerTitle.stringValue = RLPTr(@"聆听室");
    self.headerSubtitle.stringValue = RLPTr(@"安静听歌，常用设置就在卡片里");
    self.foldersButton.title = RLPTr(@"音乐文件夹");

    self.deviceCaption.stringValue = RLPTr(@"当前设备");
    self.devRefreshButton.toolTip = RLPTr(@"重新检测设备");
    if (self.devicePopup.numberOfItems > 0) {
        NSString *defTitle = self.defaultDeviceName.length
            ? [NSString stringWithFormat:@"%@（%@）", RLPTr(@"系统默认"), self.defaultDeviceName]
            : RLPTr(@"系统默认");
        [self.devicePopup itemAtIndex:0].title = defTitle;
    }

    self.outputCaption.stringValue = RLPTr(@"输出");
    self.outCardButton.toolTip = RLPTr(@"点击选择输出方式");
    self.playCaption.stringValue = RLPTr(@"播放");
    self.playCardButton.toolTip = RLPTr(@"点击选择播放方式");
    self.styleCaption.stringValue = RLPTr(@"听音风格");
    self.styleCardButton.toolTip = RLPTr(@"点击选择听感风格");

    if (self.settings) {
        [self syncOutputSummary];
        [self syncPlayAndStyleCards];
    } else {
        self.outputValue.stringValue = RLPTr(@"读取中…");
        self.playValue.stringValue = RLPTr(@"原音直通");
        self.styleValue.stringValue = RLPTr(@"均衡自然");
    }

    if (!self.currentPath.length) {
        self.npState.stringValue = RLPTr(@"未播放");
        self.npTitle.stringValue = RLPTr(@"还没有在播放的音乐");
        self.npSub.stringValue = RLPTr(@"从下面的专辑挑一张开始");
        [self.npToggle setTitle:RLPTr(@"继续播放")];
    } else {
        self.npState.stringValue = self.playing ? RLPTr(@"正在播放") : RLPTr(@"已暂停");
        [self.npToggle setTitle:self.playing ? RLPTr(@"暂停") : RLPTr(@"继续播放")];
    }
    self.npOpenButton.title = RLPTr(@"打开曲目详情");

    self.queueCaption.stringValue = RLPTr(@"播放队列");
    self.queueAllButton.title = RLPTr(@"查看全部");
    if (self.queueEmptyLabel) {
        self.queueEmptyLabel.stringValue = RLPTr(@"队列是空的");
    }

    self.albumCaption.stringValue = RLPTr(@"专辑");
    self.openLibButton.title = RLPTr(@"打开音乐库");
    if (self.albumEmptyLabel) {
        self.albumEmptyLabel.stringValue = RLPTr(@"还没有专辑 · 先添加音乐目录");
    }

    if (self.hasLoadedLibrary) {
        self.libDesc.stringValue = self.hasRoots
            ? RLPTr(@"音乐目录已就绪 · 可重新扫描更新专辑与封面")
            : RLPTr(@"支持 FLAC · DSD (DSF/DFF) · ALAC · WAV · APE");
        [self.libButton setTitle:self.hasRoots ? RLPTr(@"重新扫描音乐库") : RLPTr(@"添加音乐目录")];
    } else {
        [self.libButton setTitle:RLPTr(@"添加音乐目录")];
    }
    self.moreButton.title = RLPTr(@"更多");
}
@end

