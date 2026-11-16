// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPWorkbenchViewController.mm — 专业数字音乐台（ui_studio 对齐）
//
// 布局结构：
//   顶部：当前曲目 / 源与输出规格 + 三摘要信号链 + 「本次播放路径…」详情入口 + 7 节点信号链
//   页签：播放台 | EQ 调音台 | 音质监控（主体单层滚动，切换页签不重启播放）
//   播放台：A-D 固定工具区 + /api/profiles 配置档 + PCM / DSD / 输出三列机架（基础直达、高级按区展开）
//   EQ 调音台：嵌入 RLPEqualizerView（推子板 + 单段检查器 + OPRA）
//   音质监控：仅显示实际 /api/status 字段，无值 N/A
#import "RLPWorkbenchViewController.h"
#import "RLPWorkbench.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPEqualizerView.h"
#import "RLPSupport.h"
#import "RLPTheme.h"
#import "RLPSignalChain.h"

static NSString *const kABSlotsKey = @"RLPWorkbenchABSlots";
static const NSInteger kABSlotCount = 4;

@interface RLPWorkbenchViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSScrollView *scroll;
@property (nonatomic, strong) NSStackView *stack;

// 页头与顶部状态
@property (nonatomic, strong) NSTextField *headerTitle;
@property (nonatomic, strong) NSTextField *headerSubtitle;
@property (nonatomic, strong) NSTextField *statusMessage;
@property (nonatomic, strong) NSImageView *trackCover;
@property (nonatomic, strong) NSTextField *trackTitle;
@property (nonatomic, strong) NSTextField *trackSub;
@property (nonatomic, strong) NSTextField *sigSrc;
@property (nonatomic, strong) NSTextField *sigDsp;
@property (nonatomic, strong) NSTextField *sigOut;
@property (nonatomic, strong) NSMutableArray<NSTextField *> *headerLabels;

// 信号链（保留 7 节点与详情弹窗）
@property (nonatomic, strong) NSStackView *chainRow;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSView *> *chainNodes;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSTextField *> *chainValues;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSButton *> *chainHits;
@property (nonatomic, strong) NSTextField *pipelineStageLine;
@property (nonatomic, strong) NSTextField *bpLine;

// 三页签
@property (nonatomic, copy) NSString *activeTab;
@property (nonatomic, strong) NSSegmentedControl *tabControl;
@property (nonatomic, strong) NSButton *tabBtnAB;
@property (nonatomic, strong) NSButton *tabBtnEQ;
@property (nonatomic, strong) NSButton *tabBtnMonitor;
@property (nonatomic, strong) NSStackView *panelAB;
@property (nonatomic, strong) NSStackView *panelEQ;
@property (nonatomic, strong) NSStackView *panelMonitor;

// A-D 对比槽
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *abSlots;
@property (nonatomic, strong) NSMutableArray<NSButton *> *abButtons;
@property (nonatomic, strong) NSMutableArray<NSTextField *> *abSummaries;
@property (nonatomic, strong) NSButton *abToggle;
@property (nonatomic, assign) NSInteger abActive;

// U16 命名配置档（/api/profiles）
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *profiles;
@property (nonatomic, copy) NSString *profileActive;
@property (nonatomic, strong) NSTableView *profileTable;
@property (nonatomic, strong) NSScrollView *profileScroll;
@property (nonatomic, strong) NSLayoutConstraint *profileScrollHeight;
@property (nonatomic, strong) NSTextField *profileStatus;
@property (nonatomic, strong) NSButton *profileSaveButton;
@property (nonatomic, strong) NSButton *profileApplyButton;
@property (nonatomic, strong) NSButton *profileDeleteButton;

// 三列机架
@property (nonatomic, strong) NSStackView *rackStack;
@property (nonatomic, strong) NSView *rackPCM;
@property (nonatomic, strong) NSView *rackDSD;
@property (nonatomic, strong) NSView *rackOutput;

// PCM 列控件（保留测试所需的 filterQuick/filterAll/phaseSeg/filterSearch）
@property (nonatomic, strong) NSSegmentedControl *pcmSlotSeg;
@property (nonatomic, strong) NSStackView *filterQuick;
@property (nonatomic, strong) NSPopUpButton *filterAll;
@property (nonatomic, strong) NSSegmentedControl *phaseSeg;
@property (nonatomic, strong) NSSearchField *filterSearch;
@property (nonatomic, copy) NSString *filterQuery;
@property (nonatomic, assign) BOOL editingNxFilter;
@property (nonatomic, strong) NSTextField *pcmSlotsSummary;
@property (nonatomic, strong) NSTextField *filterOverrideLabel;
@property (nonatomic, strong) NSButton *filterResetButton;
@property (nonatomic, strong) NSButton *twoStageCheck;
@property (nonatomic, strong) NSPopUpButton *shaperPopup;
// PCM 高级折叠
@property (nonatomic, strong) NSButton *pcmAdvToggle;
@property (nonatomic, strong) NSStackView *pcmAdvBox;
@property (nonatomic, assign) BOOL pcmAdvExpanded;
@property (nonatomic, strong) NSPopUpButton *phaseOverridePopup;
@property (nonatomic, strong) NSPopUpButton *tapsPopup;
@property (nonatomic, strong) NSPopUpButton *attenPopup;
@property (nonatomic, strong) NSPopUpButton *transitionPopup;
@property (nonatomic, strong) NSButton *ispCheck;

// DSD 列控件
@property (nonatomic, strong) NSPopUpButton *sdmFilt1Popup;
@property (nonatomic, strong) NSPopUpButton *sdmFiltNxPopup;
@property (nonatomic, strong) NSPopUpButton *modFamilyPopup;
@property (nonatomic, strong) NSPopUpButton *modOrderPopup;
// DSD 高级折叠
@property (nonatomic, strong) NSButton *dsdAdvToggle;
@property (nonatomic, strong) NSStackView *dsdAdvBox;
@property (nonatomic, assign) BOOL dsdAdvExpanded;
@property (nonatomic, strong) NSButton *directSdmCheck;
@property (nonatomic, strong) NSPopUpButton *modCutPopup;
@property (nonatomic, strong) NSPopUpButton *ahmBitsPopup;
@property (nonatomic, strong) NSPopUpButton *dsdKindPopup;
@property (nonatomic, strong) NSPopUpButton *dsdConvPopup;
@property (nonatomic, strong) NSButton *dsd2StageCheck;

// 输出列控件
@property (nonatomic, strong) NSSegmentedControl *dsdSeg;
@property (nonatomic, strong) NSPopUpButton *ratePopup;
@property (nonatomic, strong) NSPopUpButton *rateFamilyPopup;
@property (nonatomic, strong) NSPopUpButton *devicePopup;
@property (nonatomic, strong) NSPopUpButton *backendPopup;
@property (nonatomic, strong) NSButton *hogCheck;
// 输出高级折叠（保留 wb.more.toggle 兼容测试）
@property (nonatomic, strong) NSButton *moreToggle;
@property (nonatomic, strong) NSStackView *outputAdvBox;
@property (nonatomic, assign) BOOL outputAdvExpanded;
@property (nonatomic, strong) NSPopUpButton *bitsPopup;
@property (nonatomic, strong) NSPopUpButton *bufferPopup;
@property (nonatomic, strong) NSPopUpButton *channelsPopup;
@property (nonatomic, strong) NSButton *loudnessCheck;
@property (nonatomic, strong) NSPopUpButton *rgModePopup;
@property (nonatomic, strong) NSButton *irGpuCheck;

// EQ 页签
@property (nonatomic, strong) NSPopUpButton *eqPresetPopup;
@property (nonatomic, copy) NSArray<NSString *> *eqPresetNames;
@property (nonatomic, strong) NSButton *eqOnCheck;
@property (nonatomic, strong) NSButton *eqBypass;
@property (nonatomic, strong) RLPEqualizerView *eqView;
@property (nonatomic, strong) NSLayoutConstraint *eqHeightConstraint;

// 音质监控页签
@property (nonatomic, strong) NSStackView *monitorRowsStack;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSTextField *> *monitorValueLabels;

// 数据与乱序序号
@property (nonatomic, copy) NSDictionary *settings;
@property (nonatomic, copy) NSArray<NSDictionary *> *filters;
@property (nonatomic, copy) NSArray<NSDictionary *> *devices;
@property (nonatomic, copy) NSArray<NSNumber *> *rates;
@property (nonatomic, copy) NSDictionary *status;
@property (nonatomic, strong) NSPopover *popover;
@property (nonatomic, strong) NSTimer *poll;
@property (nonatomic, assign) NSUInteger settingsSeq;
@property (nonatomic, assign) NSUInteger statusSeq;
@property (nonatomic, assign) NSUInteger filtersSeq;
@property (nonatomic, assign) NSUInteger ratesSeq;
@property (nonatomic, assign) NSUInteger devicesSeq;
@property (nonatomic, assign) NSUInteger profilesSeq;

- (NSString *)str:(NSString *)key def:(NSString *)def;
- (void)postSettings:(NSDictionary<NSString *, NSString *> *)kv;
- (void)applySettingsPayload:(NSDictionary *)kv forSeq:(NSUInteger)seq;
- (void)applyStatusPayload:(NSDictionary *)st forSeq:(NSUInteger)seq;
- (void)selectStudioTab:(NSString *)tab;
- (void)reloadSettings;
- (void)reloadRates;
- (void)reloadStatus;
- (void)reloadFilters;
- (void)reloadDevices;
- (void)reloadAll;
- (void)refreshChain;
- (void)refreshAB;
- (void)reloadProfiles;
- (void)refreshProfileStatus;
- (NSDictionary *)selectedProfile;
- (void)rebuildFilterControls;
- (void)reloadEqPresets;
- (void)syncPhaseSeg;
- (void)syncOutputControls;
- (void)syncAllControlsFromSettings;
- (NSDictionary *)currentDeviceDict;
- (NSTextField *)inlineLabel:(NSString *)text;
- (NSView *)cardWithIdentifier:(NSString *)ident;
- (NSTextField *)sectionTitle:(NSString *)text;
- (void)addFullWidth:(NSView *)v toStack:(NSStackView *)target height:(CGFloat)h;
- (void)refreshTrackCard;
- (void)refreshMonitor;
- (void)syncEqOnCheck;
@end

@implementation RLPWorkbenchViewController

- (instancetype)init {
    self = [super initWithTitle:RLPTr(@"专业工作台")];
    if (self) {
        _activeTab = @"ab";
        _chainNodes = [NSMutableDictionary dictionary];
        _chainValues = [NSMutableDictionary dictionary];
        _chainHits = [NSMutableDictionary dictionary];
        _headerLabels = [NSMutableArray array];
        _abButtons = [NSMutableArray array];
        _abSummaries = [NSMutableArray array];
        _abActive = -1;
        _abSlots = [NSMutableArray array];
        _profiles = [NSMutableArray array];
        _profileActive = @"";
        _monitorValueLabels = [NSMutableDictionary dictionary];
        NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kABSlotsKey];
        for (NSInteger i = 0; i < kABSlotCount; ++i) {
            NSDictionary *s = (i < (NSInteger)saved.count && [saved[i] isKindOfClass:[NSDictionary class]]) ? saved[i] : @{};
            [_abSlots addObject:s];
        }
    }
    return self;
}

- (void)buildContent {
    NSView *host = self.contentView;
    self.scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.scroll.drawsBackground = NO;
    self.scroll.hasVerticalScroller = YES;
    self.scroll.autohidesScrollers = YES;
    self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.scroll];

    self.stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.stack.alignment = NSLayoutAttributeLeading;
    self.stack.spacing = 12;
    self.stack.edgeInsets = NSEdgeInsetsMake(6, 20, 20, 20);
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    self.scroll.documentView = self.stack;

    NSLayoutConstraint *stackW = [self.stack.widthAnchor constraintEqualToAnchor:self.scroll.contentView.widthAnchor];
    stackW.priority = 450; // 低于 NSLayoutPriorityWindowSizeStayPut(500)，允许窗口缩窄后由 viewWillLayout 切竖排
    [NSLayoutConstraint activateConstraints:@[
        [self.scroll.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [self.scroll.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [self.scroll.topAnchor constraintEqualToAnchor:host.topAnchor],
        [self.scroll.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
        [self.stack.leadingAnchor constraintEqualToAnchor:self.scroll.contentView.leadingAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:self.scroll.contentView.topAnchor],
        stackW,
    ]];

    [self buildHeader];
    [self buildTrackAndSignalHeader];
    [self buildTabBar];
    [self buildPanels];
    [self selectStudioTab:@"ab"];

    self.view.postsFrameChangedNotifications = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onViewFrameChanged:)
                                                 name:NSViewFrameDidChangeNotification
                                               object:self.view];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)onViewFrameChanged:(NSNotification *)note {
    (void)note;
    [self updateRackOrientation];
}

- (void)updateRackOrientation {
    const CGFloat w = self.view.bounds.size.width;
    if (self.rackStack) {
        const BOOL narrow = (w > 1.0 && w < 900.0);
        NSUserInterfaceLayoutOrientation want = narrow
            ? NSUserInterfaceLayoutOrientationVertical
            : NSUserInterfaceLayoutOrientationHorizontal;
        if (self.rackStack.orientation != want) {
            self.rackStack.orientation = want;
            self.rackStack.distribution = narrow ? NSStackViewDistributionFill : NSStackViewDistributionFillEqually;
            self.rackStack.alignment = narrow ? NSLayoutAttributeLeading : NSLayoutAttributeTop;
        }
    }
}

- (void)viewWillLayout {
    [super viewWillLayout];
    [self updateRackOrientation];
}

#pragma mark - 顶部：标题 + 曲目 + 三摘要信号链 + 7 节点明细

- (void)buildHeader {
    RLPTheme *t = [RLPTheme current];
    NSStackView *row = [[NSStackView alloc] init];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeBottom;
    row.spacing = 12;
    row.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *left = [[NSStackView alloc] init];
    left.orientation = NSUserInterfaceLayoutOrientationVertical;
    left.alignment = NSLayoutAttributeLeading;
    left.spacing = 3;
    self.headerTitle = RLPLabel(RLPTr(@"数字音乐台"), t.display, t.hero);
    self.headerTitle.tag = 0;
    self.headerSubtitle = RLPLabel(RLPTr(@"微调每一组声音，随时对比同一片段"), t.body, t.mut);
    self.headerSubtitle.tag = 1;
    [left addArrangedSubview:self.headerTitle];
    [left addArrangedSubview:self.headerSubtitle];

    self.statusMessage = RLPLabel(@"", t.small, t.mut);
    self.statusMessage.identifier = @"wb.message";
    self.statusMessage.alignment = NSTextAlignmentRight;
    self.statusMessage.lineBreakMode = NSLineBreakByTruncatingTail;
    [row addArrangedSubview:left];
    [row addArrangedSubview:[[NSView alloc] init]];
    [row addArrangedSubview:self.statusMessage];
    [self.headerLabels addObjectsFromArray:@[self.headerTitle, self.headerSubtitle]];
    [self addFullWidth:row toStack:self.stack height:0];
}

- (void)buildTrackAndSignalHeader {
    RLPTheme *t = [RLPTheme current];
    NSView *card = [self cardWithIdentifier:@"wb.trackcard"];
    card.layer.backgroundColor = t.card.CGColor;
    card.layer.borderColor = t.hairline.CGColor;

    NSStackView *inner = [[NSStackView alloc] init];
    inner.orientation = NSUserInterfaceLayoutOrientationVertical;
    inner.alignment = NSLayoutAttributeLeading;
    inner.spacing = 10;
    inner.edgeInsets = NSEdgeInsetsMake(14, 16, 14, 16);
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:inner];
    [NSLayoutConstraint activateConstraints:@[
        [inner.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [inner.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [inner.topAnchor constraintEqualToAnchor:card.topAnchor],
        [inner.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    // 当前曲目行
    NSStackView *topRow = [[NSStackView alloc] init];
    topRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    topRow.alignment = NSLayoutAttributeCenterY;
    topRow.spacing = 12;

    self.trackCover = [[NSImageView alloc] initWithFrame:NSZeroRect];
    self.trackCover.wantsLayer = YES;
    self.trackCover.layer.cornerRadius = t.rSm;
    self.trackCover.layer.masksToBounds = YES;
    self.trackCover.layer.backgroundColor = t.cardAlt.CGColor;
    self.trackCover.imageScaling = NSImageScaleProportionallyDown;
    self.trackCover.image = [NSImage imageWithSystemSymbolName:@"music.note" accessibilityDescription:RLPTr(@"封面")];
    self.trackCover.contentTintColor = t.mut;
    [self.trackCover.widthAnchor constraintEqualToConstant:56].active = YES;
    [self.trackCover.heightAnchor constraintEqualToConstant:56].active = YES;

    NSStackView *metaCol = [[NSStackView alloc] init];
    metaCol.orientation = NSUserInterfaceLayoutOrientationVertical;
    metaCol.alignment = NSLayoutAttributeLeading;
    metaCol.spacing = 3;
    self.trackTitle = RLPLabel(RLPTr(@"还没有在播放的音乐"), t.heading, t.hero);
    self.trackTitle.tag = 0;
    self.trackTitle.maximumNumberOfLines = 1;
    self.trackTitle.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.trackTitle setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.trackSub = RLPLabel(RLPTr(@"挑一张专辑开始聆听"), t.small, t.mut);
    self.trackSub.tag = 1;
    self.trackSub.maximumNumberOfLines = 1;
    self.trackSub.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.trackSub setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [metaCol addArrangedSubview:self.trackTitle];
    [metaCol addArrangedSubview:self.trackSub];
    [self.headerLabels addObjectsFromArray:@[self.trackTitle, self.trackSub]];

    NSButton *playBtn = [NSButton buttonWithTitle:RLPTr(@"播放") target:self action:@selector(onTrackCardPlay:)];
    playBtn.bezelStyle = NSBezelStyleRounded;
    playBtn.wantsLayer = YES;
    playBtn.layer.backgroundColor = t.accent.CGColor;
    playBtn.layer.cornerRadius = t.rSm;
    playBtn.contentTintColor = NSColor.whiteColor;
    playBtn.identifier = @"wb.trackplay";
    [playBtn.widthAnchor constraintEqualToConstant:76].active = YES;

    NSButton *detailBtn = [NSButton buttonWithTitle:RLPTr(@"本次播放路径…") target:self action:@selector(showSignalChainDetail:)];
    detailBtn.bezelStyle = NSBezelStyleRounded;
    detailBtn.identifier = @"wb.chaindetail";

    [topRow addArrangedSubview:self.trackCover];
    [topRow addArrangedSubview:metaCol];
    [topRow addArrangedSubview:[[NSView alloc] init]];
    [topRow addArrangedSubview:detailBtn];
    [topRow addArrangedSubview:playBtn];
    [inner addArrangedSubview:topRow];
    [topRow.widthAnchor constraintEqualToAnchor:inner.widthAnchor constant:-32].active = YES;

    // 三摘要信号节点（源文件 / 声音处理 / 设备输出）
    NSStackView *sig = [[NSStackView alloc] init];
    sig.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    sig.distribution = NSStackViewDistributionFillEqually;
    sig.spacing = 8;
    sig.wantsLayer = YES;
    sig.layer.borderWidth = 1;
    sig.layer.borderColor = t.hairline.CGColor;
    sig.layer.cornerRadius = t.rSm;
    sig.edgeInsets = NSEdgeInsetsMake(8, 12, 8, 12);
    NSArray<NSString *> *caps = @[RLPTr(@"源文件"), RLPTr(@"声音处理"), RLPTr(@"设备输出")];
    NSMutableArray<NSTextField *> *vals = [NSMutableArray array];
    for (NSString *cap in caps) {
        NSStackView *col = [[NSStackView alloc] init];
        col.orientation = NSUserInterfaceLayoutOrientationVertical;
        col.alignment = NSLayoutAttributeLeading;
        col.spacing = 2;
        NSTextField *lab = RLPLabel(cap, t.caption, t.mut);
        lab.tag = 1;
        NSTextField *val = RLPLabel(@"—", t.body, t.text);
        val.tag = 0;
        val.maximumNumberOfLines = 2;
        val.lineBreakMode = NSLineBreakByTruncatingTail;
        [val setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [col addArrangedSubview:lab];
        [col addArrangedSubview:val];
        [vals addObject:val];
        [self.headerLabels addObjectsFromArray:@[lab, val]];
        [sig addArrangedSubview:col];
    }
    self.sigSrc = vals[0];
    self.sigDsp = vals[1];
    self.sigOut = vals[2];
    [inner addArrangedSubview:sig];
    [sig.widthAnchor constraintEqualToAnchor:inner.widthAnchor constant:-32].active = YES;

    // 7 节点交互信号链（窄窗自适应等分，不溢出）
    self.bpLine = RLPLabel(@"", t.small, t.mut);
    self.bpLine.maximumNumberOfLines = 2;
    self.bpLine.lineBreakMode = NSLineBreakByWordWrapping;
    [self.bpLine setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [inner addArrangedSubview:self.bpLine];

    self.chainRow = [[NSStackView alloc] init];
    self.chainRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.chainRow.distribution = NSStackViewDistributionFillEqually;
    self.chainRow.spacing = 6;
    NSArray *nodes = @[
        @[@"src",      RLPTr(@"源")],
        @[@"resample", RLPTr(@"重采样")],
        @[@"eq",       RLPTr(@"EQ")],
        @[@"ir",       RLPTr(@"卷积 IR")],
        @[@"shaper",   RLPTr(@"抖动")],
        @[@"sdm",      RLPTr(@"SDM 调制")],
        @[@"out",      RLPTr(@"输出")],
    ];
    for (NSArray *n in nodes) {
        NSString *key = n[0];
        NSView *node = [self cardWithIdentifier:[NSString stringWithFormat:@"wb.node.%@", key]];
        [node setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSTextField *title = RLPLabel(n[1], t.caption, t.mut);
        title.translatesAutoresizingMaskIntoConstraints = NO;
        [title setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSTextField *val = RLPLabel(@"—", t.small, t.text);
        val.translatesAutoresizingMaskIntoConstraints = NO;
        val.lineBreakMode = NSLineBreakByTruncatingTail;
        [val setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSTextField *why = RLPLabel(@"", [NSFont systemFontOfSize:10], t.warn);
        why.translatesAutoresizingMaskIntoConstraints = NO;
        why.lineBreakMode = NSLineBreakByTruncatingTail;
        [why setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        why.identifier = [NSString stringWithFormat:@"wb.why.%@", key];
        NSButton *hit = [NSButton buttonWithTitle:@"" target:self action:@selector(onChainNodeClicked:)];
        hit.bordered = NO;
        hit.identifier = key;
        hit.translatesAutoresizingMaskIntoConstraints = NO;
        for (NSView *v in @[title, val, why, hit]) [node addSubview:v];
        [NSLayoutConstraint activateConstraints:@[
            [node.heightAnchor constraintEqualToConstant:62],
            [title.leadingAnchor constraintEqualToAnchor:node.leadingAnchor constant:8],
            [title.topAnchor constraintEqualToAnchor:node.topAnchor constant:6],
            [val.leadingAnchor constraintEqualToAnchor:node.leadingAnchor constant:8],
            [val.trailingAnchor constraintEqualToAnchor:node.trailingAnchor constant:-6],
            [val.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2],
            [why.leadingAnchor constraintEqualToAnchor:node.leadingAnchor constant:8],
            [why.trailingAnchor constraintEqualToAnchor:node.trailingAnchor constant:-6],
            [why.topAnchor constraintEqualToAnchor:val.bottomAnchor constant:2],
            [hit.leadingAnchor constraintEqualToAnchor:node.leadingAnchor],
            [hit.trailingAnchor constraintEqualToAnchor:node.trailingAnchor],
            [hit.topAnchor constraintEqualToAnchor:node.topAnchor],
            [hit.bottomAnchor constraintEqualToAnchor:node.bottomAnchor],
        ]];
        self.chainNodes[key] = node;
        self.chainValues[key] = val;
        self.chainHits[key] = hit;
        NSString *why0 = RLPChainNodeDisabledReason(key, @{});
        if (why0.length) {
            hit.enabled = NO;
            hit.toolTip = why0;
            node.alphaValue = 0.55;
        }
        [self.chainRow addArrangedSubview:node];
    }
    [inner addArrangedSubview:self.chainRow];
    [self.chainRow.widthAnchor constraintEqualToAnchor:inner.widthAnchor constant:-32].active = YES;

    self.pipelineStageLine = RLPLabel(@"", [NSFont systemFontOfSize:10], t.mut);
    self.pipelineStageLine.identifier = @"wb.pipelinestage";
    self.pipelineStageLine.maximumNumberOfLines = 2;
    self.pipelineStageLine.lineBreakMode = NSLineBreakByWordWrapping;
    [inner addArrangedSubview:self.pipelineStageLine];

    [self addFullWidth:card toStack:self.stack height:0];
}

- (void)onTrackCardPlay:(id)sender {
    (void)sender;
    RLPPostJSON(@"/api/pause?on=0", nil);
}

- (void)refreshTrackCard {
    NSDictionary *st = self.status ?: @{};
    NSString *path = [st[@"file"] isKindOfClass:[NSString class]] ? st[@"file"] : ([st[@"current"] isKindOfClass:[NSString class]] ? st[@"current"] : nil);
    NSString *title = [st[@"title"] isKindOfClass:[NSString class]] ? st[@"title"] : nil;
    NSString *artist = [st[@"artist"] isKindOfClass:[NSString class]] ? st[@"artist"] : nil;
    NSString *album = [st[@"album"] isKindOfClass:[NSString class]] ? st[@"album"] : nil;
    if (title.length) self.trackTitle.stringValue = title;
    else if (path.length) self.trackTitle.stringValue = path.lastPathComponent.stringByDeletingPathExtension;
    else self.trackTitle.stringValue = RLPTr(@"还没有在播放的音乐");
    NSMutableArray<NSString *> *sub = [NSMutableArray array];
    if (artist.length) [sub addObject:artist];
    if (album.length) [sub addObject:album];
    self.trackSub.stringValue = sub.count ? [sub componentsJoinedByString:@" · "] : RLPTr(@"挑一张专辑开始聆听");

    double fs = [st[@"inRate"] respondsToSelector:@selector(doubleValue)] ? [st[@"inRate"] doubleValue] : 0.0;
    if (fs <= 0 && [st[@"fs"] respondsToSelector:@selector(doubleValue)]) fs = [st[@"fs"] doubleValue];
    const NSInteger bits = [st[@"outBits"] respondsToSelector:@selector(integerValue)] ? [st[@"outBits"] integerValue]
                         : ([st[@"bits"] respondsToSelector:@selector(integerValue)] ? [st[@"bits"] integerValue] : 0);
    self.sigSrc.stringValue = (fs > 0)
        ? [NSString stringWithFormat:@"%.1f kHz%@", fs / 1000.0, bits > 0 ? [NSString stringWithFormat:@" / %ld bit", (long)bits] : @""]
        : @"—";
    NSString *bp = [st[@"bitPerfect"] isKindOfClass:[NSString class]] ? st[@"bitPerfect"] : nil;
    NSString *activeF = RLPWorkbenchActivePlaybackFilter(self.settings, st, RLPTr(@"默认"));
    self.sigDsp.stringValue = bp.length
        ? [NSString stringWithFormat:@"%@ · bit-perfect: %@", activeF, bp]
        : activeF;
    NSString *dev = self.devicePopup.titleOfSelectedItem;
    NSString *backend = [self str:@"backend" def:@"coreaudio"];
    self.sigOut.stringValue = [NSString stringWithFormat:@"%@ · %@", dev.length ? dev : RLPTr(@"默认设备"), backend];
}

#pragma mark - 三页签导航

- (void)buildTabBar {
    RLPTheme *t = [RLPTheme current];
    NSStackView *bar = [[NSStackView alloc] init];
    bar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bar.alignment = NSLayoutAttributeCenterY;
    bar.spacing = 8;
    bar.identifier = @"wb.tabs";
    bar.translatesAutoresizingMaskIntoConstraints = NO;

    auto MakeTab = ^NSButton *(NSString *title, NSString *ident, SEL act) {
        NSButton *b = [NSButton buttonWithTitle:title target:self action:act];
        b.bezelStyle = NSBezelStyleRounded;
        b.identifier = ident;
        b.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
        b.wantsLayer = YES;
        b.layer.cornerRadius = t.rSm;
        return b;
    };
    self.tabBtnAB = MakeTab(RLPTr(@"播放台"), @"wb.tab.ab", @selector(onTabClicked:));
    self.tabBtnEQ = MakeTab(RLPTr(@"EQ 调音台"), @"wb.tab.eq", @selector(onTabClicked:));
    self.tabBtnMonitor = MakeTab(RLPTr(@"音质监控"), @"wb.tab.monitor", @selector(onTabClicked:));
    [bar addArrangedSubview:self.tabBtnAB];
    [bar addArrangedSubview:self.tabBtnEQ];
    [bar addArrangedSubview:self.tabBtnMonitor];
    [bar addArrangedSubview:[[NSView alloc] init]];
    [self addFullWidth:bar toStack:self.stack height:32];
}

- (void)onTabClicked:(NSButton *)sender {
    if (sender == self.tabBtnAB) [self selectStudioTab:@"ab"];
    else if (sender == self.tabBtnEQ) [self selectStudioTab:@"eq"];
    else if (sender == self.tabBtnMonitor) [self selectStudioTab:@"monitor"];
}

- (void)selectStudioTab:(NSString *)tab {
    if (![@[@"ab", @"eq", @"monitor"] containsObject:tab]) return;
    self.activeTab = tab;
    self.panelAB.hidden = ![tab isEqualToString:@"ab"];
    self.panelEQ.hidden = ![tab isEqualToString:@"eq"];
    self.panelMonitor.hidden = ![tab isEqualToString:@"monitor"];
    RLPTheme *t = [RLPTheme current];
    NSArray<NSButton *> *btns = @[self.tabBtnAB, self.tabBtnEQ, self.tabBtnMonitor];
    NSArray<NSString *> *keys = @[@"ab", @"eq", @"monitor"];
    for (NSUInteger i = 0; i < btns.count; ++i) {
        const BOOL on = [keys[i] isEqualToString:tab];
        btns[i].contentTintColor = on ? t.accentText : t.mut;
        btns[i].layer.backgroundColor = (on ? t.accentWeak : NSColor.clearColor).CGColor;
    }
    if ([tab isEqualToString:@"eq"]) [self updateEqHeight];
    if ([tab isEqualToString:@"monitor"]) [self refreshMonitor];
}

- (void)buildPanels {
    self.panelAB = [[NSStackView alloc] init];
    self.panelAB.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.panelAB.alignment = NSLayoutAttributeLeading;
    self.panelAB.spacing = 12;
    self.panelAB.identifier = @"wb.panel.ab";
    self.panelAB.translatesAutoresizingMaskIntoConstraints = NO;
    [self addFullWidth:self.panelAB toStack:self.stack height:0];

    self.panelEQ = [[NSStackView alloc] init];
    self.panelEQ.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.panelEQ.alignment = NSLayoutAttributeLeading;
    self.panelEQ.spacing = 12;
    self.panelEQ.identifier = @"wb.panel.eq";
    self.panelEQ.hidden = YES;
    self.panelEQ.translatesAutoresizingMaskIntoConstraints = NO;
    [self addFullWidth:self.panelEQ toStack:self.stack height:0];

    self.panelMonitor = [[NSStackView alloc] init];
    self.panelMonitor.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.panelMonitor.alignment = NSLayoutAttributeLeading;
    self.panelMonitor.spacing = 12;
    self.panelMonitor.identifier = @"wb.panel.monitor";
    self.panelMonitor.hidden = YES;
    self.panelMonitor.translatesAutoresizingMaskIntoConstraints = NO;
    [self addFullWidth:self.panelMonitor toStack:self.stack height:0];

    // Tab 1: 播放台
    [self buildABSlots];
    [self buildProfiles];
    [self buildStudioRack];

    // Tab 2: EQ 调音台
    [self buildEqSection];

    // Tab 3: 音质监控
    [self buildMonitorSection];
}

#pragma mark - 播放台：A-D 固定工具区

- (void)buildABSlots {
    RLPTheme *t = [RLPTheme current];
    NSView *card = [self cardWithIdentifier:@"wb.ab"];
    NSStackView *inner = [[NSStackView alloc] init];
    inner.orientation = NSUserInterfaceLayoutOrientationVertical;
    inner.alignment = NSLayoutAttributeLeading;
    inner.spacing = 8;
    inner.edgeInsets = NSEdgeInsetsMake(12, 14, 12, 14);
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:inner];
    [NSLayoutConstraint activateConstraints:@[
        [inner.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [inner.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [inner.topAnchor constraintEqualToAnchor:card.topAnchor],
        [inner.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    NSStackView *head = [[NSStackView alloc] init];
    head.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    head.alignment = NSLayoutAttributeCenterY;
    NSTextField *ti = [self sectionTitle:RLPTr(@"A/B 对比 · 四组独立调音")];
    self.abToggle = [NSButton buttonWithTitle:RLPTr(@"A⇄B 来回") target:self action:@selector(onABToggle:)];
    self.abToggle.bezelStyle = NSBezelStyleRounded;
    self.abToggle.identifier = @"wb.ab.toggle";
    [head addArrangedSubview:ti];
    [head addArrangedSubview:[[NSView alloc] init]];
    [head addArrangedSubview:self.abToggle];
    [inner addArrangedSubview:head];
    [head.widthAnchor constraintEqualToAnchor:inner.widthAnchor constant:-28].active = YES;

    NSTextField *note = RLPLabel(RLPTr(@"只切滤波/升频/DSD/EQ 等听感键，不含音量、设备、后端与独占。成功回读后才高亮当前组。"), t.small, t.mut);
    note.maximumNumberOfLines = 0;
    note.lineBreakMode = NSLineBreakByWordWrapping;
    [note setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [inner addArrangedSubview:note];

    NSStackView *row = [[NSStackView alloc] init];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.distribution = NSStackViewDistributionFillEqually;
    row.spacing = 8;
    NSArray *names = @[@"A", @"B", @"C", @"D"];
    for (NSInteger i = 0; i < kABSlotCount; ++i) {
        NSView *slot = [[NSView alloc] initWithFrame:NSZeroRect];
        slot.wantsLayer = YES;
        slot.layer.cornerRadius = t.rSm;
        slot.layer.backgroundColor = t.card.CGColor;
        slot.layer.borderWidth = 1;
        slot.layer.borderColor = t.hairline.CGColor;
        slot.identifier = [NSString stringWithFormat:@"wb.abslot.%ld", (long)i];

        NSTextField *big = RLPLabel(names[i], t.heading, t.hero);
        big.translatesAutoresizingMaskIntoConstraints = NO;
        big.tag = 0;
        NSButton *pick = [NSButton buttonWithTitle:RLPTr(@"切换") target:self action:@selector(onABPick:)];
        pick.bezelStyle = NSBezelStyleRounded;
        pick.identifier = [NSString stringWithFormat:@"wb.ab.%ld", (long)i];
        pick.tag = i;
        pick.font = t.small;
        pick.translatesAutoresizingMaskIntoConstraints = NO;
        NSButton *save = [NSButton buttonWithTitle:RLPTr(@"存为") target:self action:@selector(onABSave:)];
        save.bezelStyle = NSBezelStyleRounded;
        save.tag = i;
        save.font = t.small;
        save.translatesAutoresizingMaskIntoConstraints = NO;
        NSTextField *sum = RLPLabel(RLPTr(@"未保存"), t.caption, t.mut);
        sum.translatesAutoresizingMaskIntoConstraints = NO;
        sum.lineBreakMode = NSLineBreakByTruncatingTail;
        sum.identifier = [NSString stringWithFormat:@"wb.absum.%ld", (long)i];
        [sum setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self.headerLabels addObject:big];
        for (NSView *v in @[big, pick, save, sum]) [slot addSubview:v];
        [NSLayoutConstraint activateConstraints:@[
            [slot.heightAnchor constraintEqualToConstant:94],
            [big.leadingAnchor constraintEqualToAnchor:slot.leadingAnchor constant:10],
            [big.topAnchor constraintEqualToAnchor:slot.topAnchor constant:8],
            [pick.leadingAnchor constraintEqualToAnchor:slot.leadingAnchor constant:10],
            [pick.topAnchor constraintEqualToAnchor:big.bottomAnchor constant:4],
            [save.leadingAnchor constraintEqualToAnchor:pick.trailingAnchor constant:4],
            [save.centerYAnchor constraintEqualToAnchor:pick.centerYAnchor],
            [save.trailingAnchor constraintLessThanOrEqualToAnchor:slot.trailingAnchor constant:-8],
            [sum.leadingAnchor constraintEqualToAnchor:slot.leadingAnchor constant:10],
            [sum.trailingAnchor constraintEqualToAnchor:slot.trailingAnchor constant:-8],
            [sum.topAnchor constraintEqualToAnchor:pick.bottomAnchor constant:6],
        ]];
        [self.abButtons addObject:pick];
        [self.abSummaries addObject:sum];
        [row addArrangedSubview:slot];
    }
    [inner addArrangedSubview:row];
    [row.widthAnchor constraintEqualToAnchor:inner.widthAnchor constant:-28].active = YES;
    [self addFullWidth:card toStack:self.panelAB height:0];
}

- (void)persistABSlots {
    [[NSUserDefaults standardUserDefaults] setObject:self.abSlots forKey:kABSlotsKey];
}

- (void)onABSave:(NSButton *)sender {
    NSDictionary *snap = RLPABSnapshotFromSettings(self.settings);
    if (!snap.count) { RLPToast(RLPTr(@"设置还没读到")); return; }
    self.abSlots[sender.tag] = snap;
    [self persistABSlots];
    [self refreshAB];
    RLPToast([NSString stringWithFormat:@"%@ %@", RLPTr(@"已存为"), @[@"A",@"B",@"C",@"D"][sender.tag]]);
}

- (void)onABPick:(NSButton *)sender {
    NSDictionary *snap = self.abSlots[sender.tag];
    if (![snap isKindOfClass:[NSDictionary class]] || !snap.count) {
        RLPToast(RLPTr(@"这个槽还没保存 · 点「存为」把当前设置存进来"));
        return;
    }
    NSString *body = RLPABFormBody(snap);
    if (!body.length) return;
    self.statusMessage.stringValue = RLPTr(@"应用中…");
    // 通过 postSettings: 走统一事务路径（失败不假装高亮）
    [self postSettings:snap];
}

- (void)onABToggle:(id)sender {
    (void)sender;
    NSInteger cur = RLPABMatchSlot(self.settings, self.abSlots);
    NSInteger next = (cur == 0) ? 1 : 0;
    if (![self.abSlots[next] count]) {
        RLPToast(RLPTr(@"先把 A 与 B 都存好，再来回对比"));
        return;
    }
    [self onABPick:self.abButtons[next]];
}

- (void)refreshAB {
    RLPTheme *t = [RLPTheme current];
    const NSInteger hit = RLPABMatchSlot(self.settings, self.abSlots);
    self.abActive = hit;
    for (NSInteger i = 0; i < (NSInteger)self.abButtons.count; ++i) {
        NSButton *b = self.abButtons[i];
        const BOOL on = (i == hit);
        b.font = [NSFont systemFontOfSize:12 weight:on ? NSFontWeightBold : NSFontWeightRegular];
        b.contentTintColor = on ? t.accentText : t.text;
        NSDictionary *s = self.abSlots[i];
        self.abSummaries[i].stringValue = RLPABSlotSummary(s);
        self.abSummaries[i].toolTip = RLPABSlotSummary(s);
        self.abSummaries[i].textColor = on ? t.accentText : t.mut;
        NSView *slot = b.superview;
        if (slot) {
            slot.layer.borderColor = (on ? t.accent : t.hairline).CGColor;
        }
    }
}

#pragma mark - 播放台：/api/profiles 命名配置档（无内嵌滚动条）

- (void)buildProfiles {
    RLPTheme *t = [RLPTheme current];
    NSView *card = [self cardWithIdentifier:@"wb.profiles"];
    NSStackView *inner = [[NSStackView alloc] init];
    inner.orientation = NSUserInterfaceLayoutOrientationVertical;
    inner.alignment = NSLayoutAttributeLeading;
    inner.spacing = 8;
    inner.edgeInsets = NSEdgeInsetsMake(12, 14, 12, 14);
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:inner];
    [NSLayoutConstraint activateConstraints:@[
        [inner.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [inner.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [inner.topAnchor constraintEqualToAnchor:card.topAnchor],
        [inner.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    NSTextField *ti = [self sectionTitle:RLPTr(@"配置档（/api/profiles）")];
    self.profileStatus = RLPLabel(RLPTr(@"还没有配置档"), t.caption, t.mut);
    self.profileStatus.identifier = @"wb.profile.status";

    self.profileTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 640, 28)];
    self.profileTable.identifier = @"wb.profile.list";
    self.profileTable.headerView = nil;
    self.profileTable.rowHeight = 24;
    self.profileTable.backgroundColor = NSColor.clearColor;
    self.profileTable.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    self.profileTable.dataSource = self;
    self.profileTable.delegate = self;
    self.profileTable.autoresizingMask = NSViewWidthSizable;
    if (@available(macOS 11.0, *)) self.profileTable.style = NSTableViewStylePlain;
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"profile"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [self.profileTable addTableColumn:col];
    self.profileTable.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;

    // 关键：关闭内嵌滚动条并按行数撑开高度，确保页面只有外层一根滚动条
    self.profileScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.profileScroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.profileScroll.hasVerticalScroller = NO;
    self.profileScroll.hasHorizontalScroller = NO;
    self.profileScroll.drawsBackground = NO;
    self.profileScroll.borderType = NSNoBorder;
    self.profileScroll.documentView = self.profileTable;
    self.profileScrollHeight = [self.profileScroll.heightAnchor constraintEqualToConstant:28];
    self.profileScrollHeight.active = YES;

    self.profileSaveButton = [NSButton buttonWithTitle:RLPTr(@"保存当前为配置档…") target:self action:@selector(onProfileSave:)];
    self.profileSaveButton.bezelStyle = NSBezelStyleRounded;
    self.profileSaveButton.identifier = @"wb.profile.save";
    self.profileSaveButton.font = t.small;

    self.profileApplyButton = [NSButton buttonWithTitle:RLPTr(@"应用") target:self action:@selector(onProfileApply:)];
    self.profileApplyButton.bezelStyle = NSBezelStyleRounded;
    self.profileApplyButton.identifier = @"wb.profile.apply";
    self.profileApplyButton.font = t.small;

    self.profileDeleteButton = [NSButton buttonWithTitle:RLPTr(@"删除") target:self action:@selector(onProfileDelete:)];
    self.profileDeleteButton.bezelStyle = NSBezelStyleRounded;
    self.profileDeleteButton.identifier = @"wb.profile.delete";
    self.profileDeleteButton.font = t.small;

    NSStackView *btnRow = [[NSStackView alloc] init];
    btnRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    btnRow.spacing = 8;
    for (NSView *v in @[self.profileSaveButton, self.profileApplyButton, self.profileDeleteButton, self.profileStatus])
        [btnRow addArrangedSubview:v];

    [inner addArrangedSubview:ti];
    [inner addArrangedSubview:self.profileScroll];
    [self.profileScroll.widthAnchor constraintEqualToAnchor:inner.widthAnchor constant:-28].active = YES;
    [inner addArrangedSubview:btnRow];
    [self addFullWidth:card toStack:self.panelAB height:0];
    [self refreshProfileStatus];
}

- (void)refreshProfileStatus {
    const CGFloat h = MAX(28.0, (CGFloat)self.profiles.count * 24.0 + 4.0);
    self.profileScrollHeight.constant = h;
    if (self.profiles.count == 0) {
        self.profileStatus.stringValue = RLPTr(@"还没有配置档");
    } else {
        NSString *count = [NSString stringWithFormat:RLPTr(@"共 %ld 档"), (long)self.profiles.count];
        NSString *activeName = nil;
        for (NSDictionary *p in self.profiles) {
            id pid = p[@"id"];
            if ([pid isKindOfClass:[NSString class]] && [(NSString *)pid isEqualToString:self.profileActive]) {
                activeName = [p[@"name"] isKindOfClass:[NSString class]] ? p[@"name"] : nil;
                break;
            }
        }
        self.profileStatus.stringValue = activeName.length
            ? [NSString stringWithFormat:@"%@ · %@", [NSString stringWithFormat:RLPTr(@"当前：%@"), activeName], count]
            : count;
    }
    self.profileApplyButton.enabled = self.profiles.count > 0;
    self.profileDeleteButton.enabled = self.profiles.count > 0;
}

- (NSDictionary *)selectedProfile {
    const NSInteger row = self.profileTable.selectedRow;
    if (row >= 0 && row < (NSInteger)self.profiles.count) return self.profiles[(NSUInteger)row];
    if (self.profileActive.length) {
        for (NSDictionary *p in self.profiles) {
            id pid = p[@"id"];
            if ([pid isKindOfClass:[NSString class]] && [(NSString *)pid isEqualToString:self.profileActive]) return p;
        }
    }
    return nil;
}

- (void)reloadProfiles {
    if (![RLPCoreClient shared].started) {
        self.profiles = [NSMutableArray array];
        self.profileActive = @"";
        [self.profileTable reloadData];
        [self refreshProfileStatus];
        return;
    }
    const NSUInteger seq = ++self.profilesSeq;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/profiles" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.profilesSeq) return;
        if (json && [json[@"ok"] boolValue] && [json[@"profiles"] isKindOfClass:[NSArray class]]) {
            self_.profiles = [(NSArray *)json[@"profiles"] mutableCopy];
            self_.profileActive = [json[@"active"] isKindOfClass:[NSString class]] ? json[@"active"] : @"";
        } else {
            self_.profiles = [NSMutableArray array];
            self_.profileActive = @"";
        }
        [self_.profileTable reloadData];
        NSInteger sel = -1;
        for (NSInteger i = 0; i < (NSInteger)self_.profiles.count; ++i) {
            id pid = self_.profiles[(NSUInteger)i][@"id"];
            if ([pid isKindOfClass:[NSString class]] && [(NSString *)pid isEqualToString:self_.profileActive]) { sel = i; break; }
        }
        if (sel < 0 && self_.profiles.count > 0) sel = 0;
        if (sel >= 0) [self_.profileTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)sel]
                                      byExtendingSelection:NO];
        [self_ refreshProfileStatus];
    }];
}

- (void)onProfileSave:(id)sender {
    (void)sender;
    if (![RLPCoreClient shared].started) { RLPToast(RLPTr(@"核心未启动")); return; }
    NSString *name = RLPAskText(RLPTr(@"保存为配置档"), RLPTr(@"保存"), @"",
                                RLPTr(@"配置档名称"), RLPTr(@"名称不能为空，最多 140 字节。"));
    if (!name.length) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:[NSString stringWithFormat:@"/api/profiles?save=%@", RLPEnc(name)]
                                  body:nil
                            completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            RLPToast([NSString stringWithFormat:RLPTr(@"已保存配置档：%@"), name]);
            [self_ reloadProfiles];
        } else {
            NSString *why = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : @"";
            RLPToast([NSString stringWithFormat:@"%@ %@", RLPTr(@"保存失败"), why]);
        }
    }];
}

- (void)onProfileApply:(id)sender {
    (void)sender;
    NSDictionary *p = [self selectedProfile];
    if (!p) { RLPToast(RLPTr(@"先选中一个配置档")); return; }
    NSString *pid = [p[@"id"] isKindOfClass:[NSString class]] ? p[@"id"] : @"";
    if (!pid.length) return;
    NSString *name = [p[@"name"] isKindOfClass:[NSString class]] ? p[@"name"] : pid;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:[NSString stringWithFormat:@"/api/profiles?apply=%@", RLPEnc(pid)]
                                  body:nil
                            completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            const NSInteger skipped = [json[@"skipped"] isKindOfClass:[NSArray class]]
                ? (NSInteger)[(NSArray *)json[@"skipped"] count] : 0;
            RLPToast(skipped > 0
                ? [NSString stringWithFormat:RLPTr(@"已应用配置档：%@ · 有 %ld 项没有生效"), name, (long)skipped]
                : [NSString stringWithFormat:RLPTr(@"已应用配置档：%@"), name]);
            [self_ reloadSettings];
            [self_ reloadStatus];
            [self_ reloadEqPresets];
            [self_.eqView reload];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPSettingsChangedNotification" object:nil];
            [self_ reloadProfiles];
        } else {
            NSString *why = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : @"";
            RLPToast([NSString stringWithFormat:@"%@ %@", RLPTr(@"应用失败"), why]);
        }
    }];
}

- (void)onProfileDelete:(id)sender {
    (void)sender;
    NSDictionary *p = [self selectedProfile];
    if (!p) { RLPToast(RLPTr(@"先选中一个配置档")); return; }
    NSString *pid = [p[@"id"] isKindOfClass:[NSString class]] ? p[@"id"] : @"";
    if (!pid.length) return;
    NSString *name = [p[@"name"] isKindOfClass:[NSString class]] ? p[@"name"] : pid;
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = [NSString stringWithFormat:RLPTr(@"删除配置档「%@」？"), name];
    a.informativeText = RLPTr(@"删除后无法恢复。");
    [a addButtonWithTitle:RLPTr(@"删除")];
    [a addButtonWithTitle:RLPTr(@"取消")];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:[NSString stringWithFormat:@"/api/profiles?delete=%@", RLPEnc(pid)]
                                  body:nil
                            completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            RLPToast([NSString stringWithFormat:RLPTr(@"已删除配置档：%@"), name]);
            [self_ reloadProfiles];
        } else {
            NSString *why = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : @"";
            RLPToast([NSString stringWithFormat:@"%@ %@", RLPTr(@"删除失败"), why]);
        }
    }];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return (NSInteger)self.profiles.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    (void)tableColumn;
    if (row < 0 || row >= (NSInteger)self.profiles.count) return nil;
    RLPTheme *t = [RLPTheme current];
    NSDictionary *p = self.profiles[(NSUInteger)row];
    NSTextField *label = (NSTextField *)[tableView makeViewWithIdentifier:@"wb.profile.cell" owner:self];
    if (!label) {
        label = RLPLabel(@"", t.body, t.text);
        label.identifier = @"wb.profile.cell";
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        label.maximumNumberOfLines = 1;
    }
    NSString *name = [p[@"name"] isKindOfClass:[NSString class]] ? p[@"name"] : @"—";
    NSString *text = [NSString stringWithFormat:@"%@   ·   %@", name, RLPProfileSummary(p)];
    label.stringValue = text;
    label.toolTip = text;
    id pid = p[@"id"];
    const BOOL on = [pid isKindOfClass:[NSString class]] && [(NSString *)pid isEqualToString:self.profileActive];
    label.textColor = on ? t.accentText : t.text;
    return label;
}

#pragma mark - 播放台：PCM / DSD / 输出 三列机架

- (void)buildStudioRack {
    self.rackStack = [[NSStackView alloc] init];
    self.rackStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.rackStack.alignment = NSLayoutAttributeTop;
    self.rackStack.distribution = NSStackViewDistributionFillEqually;
    self.rackStack.spacing = 12;
    self.rackStack.identifier = @"wb.rack";
    self.rackStack.translatesAutoresizingMaskIntoConstraints = NO;

    self.rackPCM = [self buildRackPCMColumn];
    self.rackDSD = [self buildRackDSDColumn];
    self.rackOutput = [self buildRackOutputColumn];
    for (NSView *col in @[self.rackPCM, self.rackDSD, self.rackOutput]) {
        [col setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self.rackStack addArrangedSubview:col];
        [col.widthAnchor constraintLessThanOrEqualToAnchor:self.rackStack.widthAnchor].active = YES;
    }
    [self.rackStack setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    [self addFullWidth:self.rackStack toStack:self.panelAB height:0];
}

- (NSView *)buildRackPCMColumn {
    RLPTheme *t = [RLPTheme current];
    NSView *card = [self cardWithIdentifier:@"wb.rack.pcm"];
    NSStackView *col = [[NSStackView alloc] init];
    col.orientation = NSUserInterfaceLayoutOrientationVertical;
    col.alignment = NSLayoutAttributeLeading;
    col.spacing = 8;
    col.edgeInsets = NSEdgeInsetsMake(12, 12, 12, 12);
    col.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:col];
    [NSLayoutConstraint activateConstraints:@[
        [col.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [col.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [col.topAnchor constraintEqualToAnchor:card.topAnchor],
        [col.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    NSStackView *head = [[NSStackView alloc] init];
    head.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    head.alignment = NSLayoutAttributeCenterY;
    NSTextField *ti = [self sectionTitle:RLPTr(@"PCM 滤波")];
    self.pcmSlotSeg = [NSSegmentedControl segmentedControlWithLabels:@[@"1x", @"Nx"]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(onPcmSlotChanged:)];
    self.pcmSlotSeg.identifier = @"wb.pcm.slot";
    self.pcmSlotSeg.selectedSegment = 0;
    self.pcmAdvToggle = [NSButton buttonWithTitle:RLPTr(@"高级 ▸") target:self action:@selector(onPcmAdvToggle:)];
    self.pcmAdvToggle.bezelStyle = NSBezelStyleInline;
    self.pcmAdvToggle.identifier = @"wb.pcm.adv.toggle";
    [head addArrangedSubview:ti];
    [head addArrangedSubview:self.pcmSlotSeg];
    [head addArrangedSubview:[[NSView alloc] init]];
    [head addArrangedSubview:self.pcmAdvToggle];
    [col addArrangedSubview:head];

    self.pcmSlotsSummary = RLPLabel(@"1x: — · Nx: —", t.caption, t.mut);
    self.pcmSlotsSummary.lineBreakMode = NSLineBreakByTruncatingTail;
    [col addArrangedSubview:self.pcmSlotsSummary];

    self.filterQuick = [[NSStackView alloc] init];
    self.filterQuick.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.filterQuick.spacing = 4;
    [col addArrangedSubview:self.filterQuick];

    self.filterAll = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.filterAll.target = self;
    self.filterAll.action = @selector(onFilterAllChanged:);
    self.filterAll.font = t.small;
    [self.filterAll setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [col addArrangedSubview:self.filterAll];
    [self.filterAll.widthAnchor constraintLessThanOrEqualToAnchor:col.widthAnchor constant:-24].active = YES;

    NSStackView *searchPhase = [[NSStackView alloc] init];
    searchPhase.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    searchPhase.spacing = 6;
    self.filterSearch = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    self.filterSearch.placeholderString = RLPTr(@"搜索滤波名");
    self.filterSearch.identifier = @"wb.filtersearch";
    self.filterSearch.target = self;
    self.filterSearch.action = @selector(onFilterSearch:);
    self.filterSearch.font = t.small;
    [self.filterSearch setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.phaseSeg = [NSSegmentedControl segmentedControlWithLabels:@[RLPTr(@"线性"), RLPTr(@"最小"), RLPTr(@"混合")]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(onPhaseChanged:)];
    self.phaseSeg.identifier = @"wb.phase";
    [self.phaseSeg setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [searchPhase addArrangedSubview:self.filterSearch];
    [searchPhase addArrangedSubview:self.phaseSeg];
    [col addArrangedSubview:searchPhase];

    NSStackView *shaperRow = [[NSStackView alloc] init];
    shaperRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    shaperRow.spacing = 8;
    self.twoStageCheck = [NSButton checkboxWithTitle:RLPTr(@"两段式升频") target:self action:@selector(onTwoStageChanged:)];
    self.twoStageCheck.identifier = @"wb.twostage";
    self.twoStageCheck.font = t.small;
    self.shaperPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.shaperPopup.target = self;
    self.shaperPopup.action = @selector(onShaperChanged:);
    self.shaperPopup.font = t.small;
    [self.shaperPopup addItemsWithTitles:@[@"auto", @"none", @"NS1", @"NS4", @"NS5", @"NS9", @"LNS15", @"TPDF"]];
    [shaperRow addArrangedSubview:self.twoStageCheck];
    [shaperRow addArrangedSubview:[self inlineLabel:RLPTr(@"抖动")]];
    [shaperRow addArrangedSubview:self.shaperPopup];
    [col addArrangedSubview:shaperRow];

    // 手动覆盖提示 + 恢复预设值按钮
    NSStackView *ovRow = [[NSStackView alloc] init];
    ovRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    ovRow.spacing = 8;
    self.filterOverrideLabel = RLPLabel(RLPTr(@"跟随滤波器预设"), t.caption, t.mut);
    self.filterOverrideLabel.identifier = @"wb.filter.override";
    self.filterOverrideLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.filterResetButton = [NSButton buttonWithTitle:RLPTr(@"恢复预设值") target:self action:@selector(onFilterResetOverride:)];
    self.filterResetButton.bezelStyle = NSBezelStyleRounded;
    self.filterResetButton.identifier = @"wb.filter.reset";
    self.filterResetButton.font = t.small;
    self.filterResetButton.enabled = NO;
    [ovRow addArrangedSubview:self.filterOverrideLabel];
    [ovRow addArrangedSubview:self.filterResetButton];
    [col addArrangedSubview:ovRow];

    // PCM 高级参数折叠区
    self.pcmAdvBox = [[NSStackView alloc] init];
    self.pcmAdvBox.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.pcmAdvBox.alignment = NSLayoutAttributeLeading;
    self.pcmAdvBox.spacing = 6;
    self.pcmAdvBox.hidden = YES;

    self.phaseOverridePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.phaseOverridePopup.identifier = @"wb.phaseoverride";
    self.phaseOverridePopup.font = t.small;
    self.phaseOverridePopup.target = self;
    self.phaseOverridePopup.action = @selector(onPhaseOverrideChanged:);
    NSArray *poTitles = @[RLPTr(@"跟随预设"), @"linear", @"minimum", @"intermediate"];
    NSArray *poVals = @[@"", @"linear", @"minimum", @"intermediate"];
    for (NSUInteger i = 0; i < poTitles.count; ++i) {
        [self.phaseOverridePopup addItemWithTitle:poTitles[i]];
        [[self.phaseOverridePopup lastItem] setRepresentedObject:poVals[i]];
    }

    self.tapsPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.tapsPopup.identifier = @"wb.taps";
    self.tapsPopup.target = self;
    self.tapsPopup.action = @selector(onTapsChanged:);
    self.tapsPopup.font = t.small;
    [self.tapsPopup addItemsWithTitles:@[RLPTr(@"跟随预设 (0)"), @"4095", @"32767", @"262143", @"1048575"]];

    self.attenPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.attenPopup.identifier = @"wb.atten";
    self.attenPopup.target = self;
    self.attenPopup.action = @selector(onAttenChanged:);
    self.attenPopup.font = t.small;
    [self.attenPopup addItemsWithTitles:@[RLPTr(@"跟随预设 (0)"), @"120", @"160", @"180", @"220"]];

    self.transitionPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.transitionPopup.identifier = @"wb.transition";
    self.transitionPopup.target = self;
    self.transitionPopup.action = @selector(onTransitionChanged:);
    self.transitionPopup.font = t.small;
    [self.transitionPopup addItemsWithTitles:@[RLPTr(@"跟随预设 (0)"), @"0.02", @"0.04", @"0.08", @"0.15"]];

    self.ispCheck = [NSButton checkboxWithTitle:RLPTr(@"ISP 峰值预衰减") target:self action:@selector(onIspChanged:)];
    self.ispCheck.identifier = @"wb.isp";
    self.ispCheck.font = t.small;

    for (NSArray *pair in @[@[RLPTr(@"相位覆盖"), self.phaseOverridePopup],
                            @[RLPTr(@"抽头预算"), self.tapsPopup],
                            @[RLPTr(@"阻带衰减"), self.attenPopup],
                            @[RLPTr(@"过渡带"), self.transitionPopup]]) {
        NSStackView *r = [[NSStackView alloc] init];
        r.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        r.spacing = 6;
        [r addArrangedSubview:[self inlineLabel:pair[0]]];
        [r addArrangedSubview:pair[1]];
        [self.pcmAdvBox addArrangedSubview:r];
    }
    [self.pcmAdvBox addArrangedSubview:self.ispCheck];
    [col addArrangedSubview:self.pcmAdvBox];
    return card;
}

- (NSView *)buildRackDSDColumn {
    RLPTheme *t = [RLPTheme current];
    NSView *card = [self cardWithIdentifier:@"wb.rack.dsd"];
    NSStackView *col = [[NSStackView alloc] init];
    col.orientation = NSUserInterfaceLayoutOrientationVertical;
    col.alignment = NSLayoutAttributeLeading;
    col.spacing = 8;
    col.edgeInsets = NSEdgeInsetsMake(12, 12, 12, 12);
    col.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:col];
    [NSLayoutConstraint activateConstraints:@[
        [col.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [col.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [col.topAnchor constraintEqualToAnchor:card.topAnchor],
        [col.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    NSStackView *head = [[NSStackView alloc] init];
    head.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    head.alignment = NSLayoutAttributeCenterY;
    NSTextField *ti = [self sectionTitle:RLPTr(@"DSD 调制")];
    self.dsdAdvToggle = [NSButton buttonWithTitle:RLPTr(@"高级 ▸") target:self action:@selector(onDsdAdvToggle:)];
    self.dsdAdvToggle.bezelStyle = NSBezelStyleInline;
    self.dsdAdvToggle.identifier = @"wb.dsd.adv.toggle";
    [head addArrangedSubview:ti];
    [head addArrangedSubview:[[NSView alloc] init]];
    [head addArrangedSubview:self.dsdAdvToggle];
    [col addArrangedSubview:head];

    self.sdmFilt1Popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.sdmFilt1Popup.identifier = @"wb.sdmfilt";
    self.sdmFilt1Popup.font = t.small;
    self.sdmFilt1Popup.target = self;
    self.sdmFilt1Popup.action = @selector(onSdmFilt1Changed:);
    [self.sdmFilt1Popup setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.sdmFiltNxPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.sdmFiltNxPopup.identifier = @"wb.sdmfiltnx";
    self.sdmFiltNxPopup.font = t.small;
    self.sdmFiltNxPopup.target = self;
    self.sdmFiltNxPopup.action = @selector(onSdmFiltNxChanged:);
    [self.sdmFiltNxPopup setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    [col addArrangedSubview:[self inlineLabel:RLPTr(@"SDM 1x 滤波")]];
    [col addArrangedSubview:self.sdmFilt1Popup];
    [self.sdmFilt1Popup.widthAnchor constraintLessThanOrEqualToAnchor:col.widthAnchor constant:-24].active = YES;
    [col addArrangedSubview:[self inlineLabel:RLPTr(@"SDM Nx 滤波")]];
    [col addArrangedSubview:self.sdmFiltNxPopup];
    [self.sdmFiltNxPopup.widthAnchor constraintLessThanOrEqualToAnchor:col.widthAnchor constant:-24].active = YES;

    self.modFamilyPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.modFamilyPopup.target = self;
    self.modFamilyPopup.action = @selector(onModFamilyChanged:);
    self.modFamilyPopup.font = t.small;
    [self.modFamilyPopup addItemsWithTitles:@[@"dsd", @"chebyshev", @"ec", @"ahm"]];

    self.modOrderPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.modOrderPopup.target = self;
    self.modOrderPopup.action = @selector(onModOrderChanged:);
    self.modOrderPopup.identifier = @"wb.modorder";
    self.modOrderPopup.font = t.small;
    [self.modOrderPopup addItemsWithTitles:@[@"5", @"6", @"7", @"8", @"9"]];
    self.modOrderPopup.enabled = NO;
    self.modFamilyPopup.enabled = NO;

    NSStackView *modRow = [[NSStackView alloc] init];
    modRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    modRow.spacing = 6;
    [modRow addArrangedSubview:[self inlineLabel:RLPTr(@"调制器")]];
    [modRow addArrangedSubview:self.modFamilyPopup];
    [modRow addArrangedSubview:[self inlineLabel:RLPTr(@"阶数")]];
    [modRow addArrangedSubview:self.modOrderPopup];
    [col addArrangedSubview:modRow];

    // DSD 高级参数折叠区
    self.dsdAdvBox = [[NSStackView alloc] init];
    self.dsdAdvBox.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.dsdAdvBox.alignment = NSLayoutAttributeLeading;
    self.dsdAdvBox.spacing = 6;
    self.dsdAdvBox.hidden = YES;

    self.directSdmCheck = [NSButton checkboxWithTitle:RLPTr(@"DSD 直通（DirectSDM）") target:self action:@selector(onDirectSdmChanged:)];
    self.directSdmCheck.identifier = @"wb.directsdm";
    self.directSdmCheck.font = t.small;

    self.modCutPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.modCutPopup.font = t.small;
    self.modCutPopup.target = self;
    self.modCutPopup.action = @selector(onModCutChanged:);
    [self.modCutPopup addItemsWithTitles:@[@"0", @"100", @"120", @"160", @"200"]];

    self.ahmBitsPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.ahmBitsPopup.font = t.small;
    self.ahmBitsPopup.target = self;
    self.ahmBitsPopup.action = @selector(onAhmBitsChanged:);
    [self.ahmBitsPopup addItemsWithTitles:@[@"6", @"8"]];

    self.dsdKindPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.dsdKindPopup.font = t.small;
    self.dsdKindPopup.target = self;
    self.dsdKindPopup.action = @selector(onDsdKindChanged:);
    [self.dsdKindPopup addItemsWithTitles:@[@"fir", @"iir", @"cic"]];

    self.dsdConvPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.dsdConvPopup.font = t.small;
    self.dsdConvPopup.target = self;
    self.dsdConvPopup.action = @selector(onDsdConvChanged:);
    [self.dsdConvPopup addItemsWithTitles:@[@"narrow", @"wide", @"xfi"]];

    self.dsd2StageCheck = [NSButton checkboxWithTitle:RLPTr(@"DSD 两段抽取") target:self action:@selector(onDsd2StageChanged:)];
    self.dsd2StageCheck.font = t.small;

    [self.dsdAdvBox addArrangedSubview:self.directSdmCheck];
    for (NSArray *pair in @[@[RLPTr(@"整形拐点 kHz"), self.modCutPopup],
                            @[RLPTr(@"AHM 位数"), self.ahmBitsPopup],
                            @[RLPTr(@"DSD 抽取器"), self.dsdKindPopup],
                            @[RLPTr(@"DSD 通带"), self.dsdConvPopup]]) {
        NSStackView *r = [[NSStackView alloc] init];
        r.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        r.spacing = 6;
        [r addArrangedSubview:[self inlineLabel:pair[0]]];
        [r addArrangedSubview:pair[1]];
        [self.dsdAdvBox addArrangedSubview:r];
    }
    [self.dsdAdvBox addArrangedSubview:self.dsd2StageCheck];
    [col addArrangedSubview:self.dsdAdvBox];
    return card;
}

- (NSView *)buildRackOutputColumn {
    RLPTheme *t = [RLPTheme current];
    NSView *card = [self cardWithIdentifier:@"wb.rack.output"];
    NSStackView *col = [[NSStackView alloc] init];
    col.orientation = NSUserInterfaceLayoutOrientationVertical;
    col.alignment = NSLayoutAttributeLeading;
    col.spacing = 8;
    col.edgeInsets = NSEdgeInsetsMake(12, 12, 12, 12);
    col.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:col];
    [NSLayoutConstraint activateConstraints:@[
        [col.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [col.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [col.topAnchor constraintEqualToAnchor:card.topAnchor],
        [col.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    NSStackView *head = [[NSStackView alloc] init];
    head.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    head.alignment = NSLayoutAttributeCenterY;
    NSTextField *ti = [self sectionTitle:RLPTr(@"输出规格")];
    self.moreToggle = [NSButton buttonWithTitle:RLPTr(@"高级 ▸") target:self action:@selector(onMoreToggle:)];
    self.moreToggle.bezelStyle = NSBezelStyleInline;
    self.moreToggle.identifier = @"wb.output.adv.toggle";
    // 兼容旧测试 B9 检查 wb.more.toggle
    NSButton *compatMore = [NSButton buttonWithTitle:@"" target:self action:@selector(onMoreToggle:)];
    compatMore.identifier = @"wb.more.toggle";
    compatMore.hidden = YES;
    [head addArrangedSubview:ti];
    [head addArrangedSubview:compatMore];
    [head addArrangedSubview:[[NSView alloc] init]];
    [head addArrangedSubview:self.moreToggle];
    [col addArrangedSubview:head];

    self.dsdSeg = [NSSegmentedControl segmentedControlWithLabels:@[@"PCM", @"DSD64", @"128", @"256", @"512"]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(onDsdChanged:)];
    [self.dsdSeg setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [col addArrangedSubview:self.dsdSeg];

    self.ratePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.ratePopup.target = self;
    self.ratePopup.action = @selector(onRateChanged:);
    self.ratePopup.font = t.small;

    self.rateFamilyPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.rateFamilyPopup.identifier = @"wb.ratefamily";
    self.rateFamilyPopup.target = self;
    self.rateFamilyPopup.action = @selector(onRateFamilyChanged:);
    self.rateFamilyPopup.font = t.small;
    NSArray *rfTitles = @[RLPTr(@"优先同族 (prefer)"), RLPTr(@"严格同族 (strict)"), RLPTr(@"兼容回退 (compatible)")];
    NSArray *rfVals = @[@"prefer", @"strict", @"compatible"];
    for (NSUInteger i = 0; i < rfTitles.count; ++i) {
        [self.rateFamilyPopup addItemWithTitle:rfTitles[i]];
        [[self.rateFamilyPopup lastItem] setRepresentedObject:rfVals[i]];
    }

    NSStackView *rateRow = [[NSStackView alloc] init];
    rateRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    rateRow.spacing = 6;
    [rateRow addArrangedSubview:[self inlineLabel:RLPTr(@"采样率")]];
    [rateRow addArrangedSubview:self.ratePopup];
    [col addArrangedSubview:rateRow];

    NSStackView *rfRow = [[NSStackView alloc] init];
    rfRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    rfRow.spacing = 6;
    [rfRow addArrangedSubview:[self inlineLabel:RLPTr(@"率族")]];
    [rfRow addArrangedSubview:self.rateFamilyPopup];
    [col addArrangedSubview:rfRow];

    self.devicePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.devicePopup.target = self;
    self.devicePopup.action = @selector(onDeviceChanged:);
    self.devicePopup.font = t.small;
    [self.devicePopup setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [col addArrangedSubview:self.devicePopup];
    [self.devicePopup.widthAnchor constraintLessThanOrEqualToAnchor:col.widthAnchor constant:-24].active = YES;

    NSStackView *beRow = [[NSStackView alloc] init];
    beRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    beRow.spacing = 6;
    self.backendPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.backendPopup.target = self;
    self.backendPopup.action = @selector(onBackendChanged:);
    self.backendPopup.font = t.small;
    [self.backendPopup addItemsWithTitles:@[RLPTr(@"硬件直通（独占）"), RLPTr(@"系统混音（共享）"), RLPTr(@"UPnP 投放")]];
    self.hogCheck = [NSButton checkboxWithTitle:RLPTr(@"独占 Hog") target:self action:@selector(onHogChanged:)];
    self.hogCheck.font = t.small;
    [beRow addArrangedSubview:self.backendPopup];
    [beRow addArrangedSubview:self.hogCheck];
    [col addArrangedSubview:beRow];

    // 官方预设四档
    NSStackView *preRow = [[NSStackView alloc] init];
    preRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    preRow.spacing = 4;
    [preRow setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSArray *presets = @[@[@"bitperfect", RLPTr(@"直通")], @[@"pcm", @"PCM"],
                         @[@"dsd", @"DSD"], @[@"pcm2dsd", @"PCM→DSD"]];
    for (NSArray *p in presets) {
        NSButton *b = [NSButton buttonWithTitle:p[1] target:self action:@selector(onPresetApply:)];
        b.bezelStyle = NSBezelStyleRounded;
        b.identifier = p[0];
        b.font = [NSFont systemFontOfSize:10];
        [b setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [preRow addArrangedSubview:b];
    }
    [col addArrangedSubview:preRow];

    // 输出高级参数折叠区
    self.outputAdvBox = [[NSStackView alloc] init];
    self.outputAdvBox.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.outputAdvBox.alignment = NSLayoutAttributeLeading;
    self.outputAdvBox.spacing = 6;
    self.outputAdvBox.hidden = YES;

    self.bitsPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.bitsPopup.identifier = @"wb.bits";
    self.bitsPopup.target = self;
    self.bitsPopup.action = @selector(onBitsChanged:);
    self.bitsPopup.font = t.small;
    [self.bitsPopup addItemsWithTitles:@[RLPTr(@"跟随源 (-1)"), @"16 bit", @"24 bit", @"32 bit"]];

    self.bufferPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.bufferPopup.identifier = @"wb.buffer";
    self.bufferPopup.target = self;
    self.bufferPopup.action = @selector(onBufferChanged:);
    self.bufferPopup.font = t.small;
    [self.bufferPopup addItemsWithTitles:@[@"50", @"100", @"200", @"500", @"1000"]];

    self.channelsPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.channelsPopup.font = t.small;
    self.channelsPopup.target = self;
    self.channelsPopup.action = @selector(onChannelsChanged:);
    [self.channelsPopup addItemsWithTitles:@[@"0", @"1", @"2", @"6", @"8"]];

    self.rgModePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.rgModePopup.font = t.small;
    self.rgModePopup.target = self;
    self.rgModePopup.action = @selector(onRgModeChanged:);
    [self.rgModePopup addItemsWithTitles:@[@"off", @"track", @"album"]];

    self.loudnessCheck = [NSButton checkboxWithTitle:RLPTr(@"响度补偿") target:self action:@selector(onLoudnessChanged:)];
    self.loudnessCheck.font = t.small;
    self.irGpuCheck = [NSButton checkboxWithTitle:RLPTr(@"GPU 卷积") target:self action:@selector(onIrGpuChanged:)];
    self.irGpuCheck.font = t.small;

    for (NSArray *pair in @[@[RLPTr(@"输出位深"), self.bitsPopup],
                            @[RLPTr(@"缓冲 ms"), self.bufferPopup],
                            @[RLPTr(@"声道数"), self.channelsPopup],
                            @[@"ReplayGain", self.rgModePopup]]) {
        NSStackView *r = [[NSStackView alloc] init];
        r.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        r.spacing = 6;
        [r addArrangedSubview:[self inlineLabel:pair[0]]];
        [r addArrangedSubview:pair[1]];
        [self.outputAdvBox addArrangedSubview:r];
    }
    NSStackView *chkRow = [[NSStackView alloc] init];
    chkRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    chkRow.spacing = 8;
    [chkRow addArrangedSubview:self.loudnessCheck];
    [chkRow addArrangedSubview:self.irGpuCheck];
    [self.outputAdvBox addArrangedSubview:chkRow];
    [col addArrangedSubview:self.outputAdvBox];
    return card;
}

#pragma mark - EQ 调音台页签

- (void)buildEqSection {
    RLPTheme *t = [RLPTheme current];
    NSView *card = [self cardWithIdentifier:@"wb.eq"];
    NSStackView *inner = [[NSStackView alloc] init];
    inner.orientation = NSUserInterfaceLayoutOrientationVertical;
    inner.alignment = NSLayoutAttributeLeading;
    inner.spacing = 10;
    inner.edgeInsets = NSEdgeInsetsMake(12, 14, 14, 14);
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:inner];
    [NSLayoutConstraint activateConstraints:@[
        [inner.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [inner.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [inner.topAnchor constraintEqualToAnchor:card.topAnchor],
        [inner.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    NSStackView *head = [[NSStackView alloc] init];
    head.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    head.alignment = NSLayoutAttributeCenterY;
    head.spacing = 10;
    NSTextField *ti = [self sectionTitle:RLPTr(@"均衡（20 段 PEQ · 推子板 + 单段检查器 + OPRA）")];

    self.eqOnCheck = [NSButton checkboxWithTitle:RLPTr(@"EQ 开") target:self action:@selector(onEqOnChanged:)];
    self.eqOnCheck.identifier = @"wb.eqon";
    self.eqOnCheck.font = t.small;

    self.eqPresetPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.eqPresetPopup.target = self;
    self.eqPresetPopup.action = @selector(onEqPresetLoad:);
    self.eqPresetPopup.identifier = @"wb.eqpreset";
    self.eqPresetPopup.font = t.small;
    [self.eqPresetPopup addItemWithTitle:RLPTr(@"加载预设…")];

    self.eqBypass = [NSButton buttonWithTitle:RLPTr(@"旁路 EQ") target:self action:@selector(onEqBypass:)];
    self.eqBypass.bezelStyle = NSBezelStyleRounded;
    self.eqBypass.font = t.small;

    [head addArrangedSubview:ti];
    [head addArrangedSubview:[[NSView alloc] init]];
    [head addArrangedSubview:self.eqOnCheck];
    [head addArrangedSubview:self.eqPresetPopup];
    [head addArrangedSubview:self.eqBypass];
    [inner addArrangedSubview:head];
    [head.widthAnchor constraintEqualToAnchor:inner.widthAnchor constant:-28].active = YES;

    self.eqView = [[RLPEqualizerView alloc] initWithFrame:NSMakeRect(0, 0, 900, 520)];
    self.eqView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.eqView setEmbeddedInPage:YES];
    [self.eqView setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    __weak __typeof__(self) weakSelf = self;
    self.eqView.onContentSizeChanged = ^{
        [weakSelf updateEqHeight];
    };
    self.eqHeightConstraint = [self.eqView.heightAnchor constraintEqualToConstant:MAX(360, [self.eqView preferredContentHeight])];
    self.eqHeightConstraint.active = YES;
    [inner addArrangedSubview:self.eqView];
    NSLayoutConstraint *eqW = [self.eqView.widthAnchor constraintEqualToAnchor:inner.widthAnchor constant:-28];
    eqW.priority = NSLayoutPriorityDefaultHigh;
    eqW.active = YES;
    [self addFullWidth:card toStack:self.panelEQ height:0];
}

- (void)updateEqHeight {
    if (!self.eqView || !self.eqHeightConstraint) return;
    CGFloat h = [self.eqView preferredContentHeight];
    if (h < 320.0) h = 320.0;
    self.eqHeightConstraint.constant = h;
}

#pragma mark - 音质监控页签（仅真实 /api/status 字段，无值 N/A）

- (void)buildMonitorSection {
    RLPTheme *t = [RLPTheme current];
    NSView *card = [self cardWithIdentifier:@"wb.monitor"];
    NSStackView *inner = [[NSStackView alloc] init];
    inner.orientation = NSUserInterfaceLayoutOrientationVertical;
    inner.alignment = NSLayoutAttributeLeading;
    inner.spacing = 10;
    inner.edgeInsets = NSEdgeInsetsMake(12, 14, 14, 14);
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:inner];
    [NSLayoutConstraint activateConstraints:@[
        [inner.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [inner.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [inner.topAnchor constraintEqualToAnchor:card.topAnchor],
        [inner.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    NSTextField *ti = [self sectionTitle:RLPTr(@"音质监控（真实 /api/status 遥测）")];
    NSTextField *note = RLPLabel(RLPTr(@"仅显示后端 /api/status 实际返回字段，未播放或不可用字段显示 N/A。"), t.small, t.mut);
    [inner addArrangedSubview:ti];
    [inner addArrangedSubview:note];

    self.monitorRowsStack = [[NSStackView alloc] init];
    self.monitorRowsStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.monitorRowsStack.alignment = NSLayoutAttributeLeading;
    self.monitorRowsStack.spacing = 6;
    [inner addArrangedSubview:self.monitorRowsStack];
    [self.monitorRowsStack.widthAnchor constraintEqualToAnchor:inner.widthAnchor constant:-28].active = YES;

    [self addFullWidth:card toStack:self.panelMonitor height:0];
    [self refreshMonitor];
}

- (void)refreshMonitor {
    if (!self.monitorRowsStack) return;
    RLPTheme *t = [RLPTheme current];
    NSArray<NSDictionary<NSString *, NSString *> *> *rows = RLPWorkbenchMonitorRows(self.status);
    if (self.monitorValueLabels.count == 0) {
        NSString *lastGrp = nil;
        for (NSDictionary<NSString *, NSString *> *r in rows) {
            NSString *grp = r[@"group"] ?: @"";
            if (![grp isEqualToString:lastGrp]) {
                lastGrp = grp;
                NSTextField *gh = RLPLabel(grp, [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold], t.accentText);
                [self.monitorRowsStack addArrangedSubview:gh];
            }
            NSStackView *line = [[NSStackView alloc] init];
            line.orientation = NSUserInterfaceLayoutOrientationHorizontal;
            line.alignment = NSLayoutAttributeCenterY;
            line.spacing = 8;
            NSTextField *lab = RLPLabel(r[@"label"] ?: @"", t.small, t.mut);
            [lab.widthAnchor constraintEqualToConstant:150].active = YES;
            NSTextField *val = RLPLabel(r[@"value"] ?: @"N/A", t.mono, t.text);
            val.identifier = [NSString stringWithFormat:@"wb.mon.%@", r[@"key"] ?: @""];
            val.lineBreakMode = NSLineBreakByTruncatingTail;
            [line addArrangedSubview:lab];
            [line addArrangedSubview:val];
            self.monitorValueLabels[r[@"key"] ?: @""] = val;
            [self.monitorRowsStack addArrangedSubview:line];
        }
    } else {
        for (NSDictionary<NSString *, NSString *> *r in rows) {
            NSTextField *val = self.monitorValueLabels[r[@"key"] ?: @""];
            if (val) {
                NSString *v = r[@"value"] ?: @"N/A";
                val.stringValue = v;
                val.textColor = [v isEqualToString:@"N/A"] ? t.mut : t.text;
            }
        }
    }
}

#pragma mark - 滤波 / 相位 / 覆盖控制

- (void)onPcmSlotChanged:(NSSegmentedControl *)sender {
    self.editingNxFilter = (sender.selectedSegment == 1);
    [self rebuildFilterControls];
}

- (void)onPcmAdvToggle:(id)sender {
    (void)sender;
    self.pcmAdvExpanded = !self.pcmAdvExpanded;
    self.pcmAdvBox.hidden = !self.pcmAdvExpanded;
    self.pcmAdvToggle.title = self.pcmAdvExpanded ? RLPTr(@"高级 ▾") : RLPTr(@"高级 ▸");
}

- (void)onDsdAdvToggle:(id)sender {
    (void)sender;
    self.dsdAdvExpanded = !self.dsdAdvExpanded;
    self.dsdAdvBox.hidden = !self.dsdAdvExpanded;
    self.dsdAdvToggle.title = self.dsdAdvExpanded ? RLPTr(@"高级 ▾") : RLPTr(@"高级 ▸");
}

- (void)onMoreToggle:(id)sender {
    (void)sender;
    self.outputAdvExpanded = !self.outputAdvExpanded;
    self.outputAdvBox.hidden = !self.outputAdvExpanded;
    self.moreToggle.title = self.outputAdvExpanded ? RLPTr(@"高级 ▾") : RLPTr(@"高级 ▸");
}

- (void)onFilterResetOverride:(id)sender {
    (void)sender;
    [self postSettings:RLPWorkbenchClearFilterOverridePayload()];
}

- (void)rebuildFilterControls {
    RLPTheme *t = [RLPTheme current];
    for (NSView *v in [self.filterQuick.arrangedSubviews copy]) {
        [self.filterQuick removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    BOOL slotIsNx = self.editingNxFilter;
    NSString *cur = RLPWorkbenchEditingFilter(self.settings, self.editingNxFilter, &slotIsNx);
    self.editingNxFilter = slotIsNx;
    if (self.pcmSlotSeg) self.pcmSlotSeg.selectedSegment = slotIsNx ? 1 : 0;

    NSString *f1 = [self str:@"filter" def:@""];
    NSString *fnx = [self str:@"filterNx" def:@""];
    self.pcmSlotsSummary.stringValue = [NSString stringWithFormat:@"1x: %@ · Nx: %@",
        f1.length ? f1 : RLPTr(@"自动"), fnx.length ? fnx : RLPTr(@"跟随 1x")];

    NSArray<NSDictionary *> *pool = self.filters;
    if (self.filterQuery.length) {
        NSString *q = self.filterQuery.lowercaseString;
        NSMutableArray *hit = [NSMutableArray array];
        for (NSDictionary *it in self.filters) {
            NSString *n = [it[@"name"] isKindOfClass:[NSString class]] ? it[@"name"] : @"";
            if ([n.lowercaseString rangeOfString:q].location != NSNotFound) [hit addObject:it];
        }
        pool = hit;
    }
    NSArray<NSDictionary *> *groups = RLPFilterGroups(pool);
    [self.filterAll removeAllItems];
    // 允许自动（空值）选项
    if (!self.filterQuery.length) {
        [self.filterAll addItemWithTitle:RLPTr(@"自动（推荐）")];
        [[self.filterAll lastItem] setRepresentedObject:@{@"name": @"", @"nx": @(slotIsNx)}];
    }
    NSInteger quick = 0;
    for (NSDictionary *g in groups) {
        NSInteger perGroup = 0;
        NSString *gname = g[@"group"];
        NSMenuItem *header = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"— %@ —", gname] action:nil keyEquivalent:@""];
        header.enabled = NO;
        [[self.filterAll menu] addItem:header];
        for (NSDictionary *it in g[@"items"]) {
            NSString *n = it[@"name"];
            NSString *label = [NSString stringWithFormat:@"%@  ·  %@  ·  %@ taps", n, it[@"phaseName"] ?: @"", it[@"taps"] ?: @0];
            [self.filterAll addItemWithTitle:label];
            [[self.filterAll lastItem] setRepresentedObject:@{@"name": n, @"nx": @(RLPWorkbenchFilterUsesNx(it))}];
            if (perGroup < 2 && quick < 6 && !self.filterQuery.length) {
                NSButton *b = [NSButton buttonWithTitle:n target:self action:@selector(onFilterQuick:)];
                b.bezelStyle = NSBezelStyleRounded;
                b.identifier = n;
                b.contentTintColor = [n isEqualToString:cur] ? t.accentText : t.text;
                b.font = [NSFont systemFontOfSize:10 weight:[n isEqualToString:cur] ? NSFontWeightBold : NSFontWeightRegular];
                [self.filterQuick addArrangedSubview:b];
                ++quick; ++perGroup;
            }
        }
    }
    for (NSInteger i = 0; i < (NSInteger)self.filterAll.numberOfItems; ++i) {
        NSDictionary *ro = [[self.filterAll itemAtIndex:i] representedObject];
        if ([ro isKindOfClass:[NSDictionary class]] && [ro[@"name"] isEqualToString:cur]) {
            [self.filterAll selectItemAtIndex:i];
            break;
        }
    }
    // 同步 SDM 1x/Nx 滤波下拉
    auto FillSdmPopup = ^(NSPopUpButton *pop, NSString *defTitle, NSString *curVal) {
        if (!pop) return;
        [pop removeAllItems];
        [pop addItemWithTitle:defTitle];
        [[pop lastItem] setRepresentedObject:@""];
        for (NSDictionary *it in self.filters) {
            NSString *n = it[@"name"];
            if (![n isKindOfClass:[NSString class]] || !n.length) continue;
            [pop addItemWithTitle:n];
            [[pop lastItem] setRepresentedObject:n];
        }
        NSInteger sel = 0;
        for (NSInteger i = 0; i < (NSInteger)pop.numberOfItems; ++i) {
            if ([[[pop itemAtIndex:i] representedObject] isEqualToString:curVal ?: @""]) { sel = i; break; }
        }
        [pop selectItemAtIndex:sel];
    };
    FillSdmPopup(self.sdmFilt1Popup, RLPTr(@"跟随 PCM 1x"), [self str:@"sdmfilt" def:@""]);
    FillSdmPopup(self.sdmFiltNxPopup, RLPTr(@"跟随 PCM Nx"), [self str:@"sdmfiltnx" def:@""]);

    // 手动覆盖状态与恢复按钮
    BOOL hasOv = RLPWorkbenchHasFilterOverride(self.settings);
    NSString *ovSum = RLPWorkbenchFilterOverrideSummary(self.settings);
    self.filterOverrideLabel.stringValue = hasOv
        ? [NSString stringWithFormat:@"%@：%@", RLPTr(@"已手动覆盖"), ovSum]
        : RLPTr(@"跟随滤波器预设");
    self.filterOverrideLabel.textColor = hasOv ? t.warn : t.mut;
    self.filterResetButton.enabled = hasOv;

    [self syncPhaseSeg];
}

- (void)syncPhaseSeg {
    BOOL slotIsNx = self.editingNxFilter;
    NSString *cur = RLPWorkbenchEditingFilter(self.settings, self.editingNxFilter, &slotIsNx);
    self.editingNxFilter = slotIsNx;
    NSArray *phases = @[@"linear", @"minimum", @"intermediate"];
    NSString *curPhase = nil;
    for (NSDictionary *it in self.filters)
        if ([it[@"name"] isEqualToString:cur]) curPhase = it[@"phase"];
    for (NSInteger i = 0; i < (NSInteger)phases.count; ++i) {
        NSString *target = RLPFilterWithPhase(cur, phases[i], self.filters);
        const BOOL avail = (target.length > 0) || [phases[i] isEqualToString:curPhase ?: @""];
        [self.phaseSeg setEnabled:avail forSegment:i];
    }
    NSInteger idx = curPhase ? [phases indexOfObject:curPhase] : NSNotFound;
    if (idx != NSNotFound) self.phaseSeg.selectedSegment = idx;
}

- (void)onPhaseChanged:(NSSegmentedControl *)sender {
    NSArray *phases = @[@"linear", @"minimum", @"intermediate"];
    const NSInteger i = sender.selectedSegment;
    if (i < 0 || i >= (NSInteger)phases.count) return;
    BOOL slotIsNx = self.editingNxFilter;
    NSString *cur = RLPWorkbenchEditingFilter(self.settings, self.editingNxFilter, &slotIsNx);
    self.editingNxFilter = slotIsNx;
    NSString *target = RLPFilterWithPhase(cur, phases[i], self.filters);
    if (!target.length) { RLPToast(RLPTr(@"当前滤波的同家族没有这个相位")); [self syncPhaseSeg]; return; }
    if ([target isEqualToString:cur]) return;
    [self postSettings:@{(slotIsNx ? @"filterNx" : @"filter"): target}];
}

- (void)onFilterSearch:(NSSearchField *)sender {
    self.filterQuery = sender.stringValue;
    [self rebuildFilterControls];
}

- (void)onFilterQuick:(NSButton *)sender {
    NSString *name = sender.identifier;
    BOOL nx = NO;
    for (NSDictionary *it in self.filters) if ([it[@"name"] isEqualToString:name]) nx = RLPWorkbenchFilterUsesNx(it);
    self.editingNxFilter = nx;
    [self postSettings:@{(nx ? @"filterNx" : @"filter"): name}];
}

- (void)onFilterAllChanged:(NSPopUpButton *)sender {
    NSDictionary *ro = sender.selectedItem.representedObject;
    if (![ro isKindOfClass:[NSDictionary class]]) return;
    NSString *name = ro[@"name"] ?: @"";
    const BOOL nx = [ro[@"nx"] boolValue];
    self.editingNxFilter = nx;
    [self postSettings:@{(nx ? @"filterNx" : @"filter"): name}];
}

#pragma mark - 机架各参数 Action

- (void)onPhaseOverrideChanged:(NSPopUpButton *)sender {
    NSString *v = sender.selectedItem.representedObject;
    if ([v isKindOfClass:[NSString class]]) [self postSettings:@{@"phase": v}];
}
- (void)onTapsChanged:(NSPopUpButton *)sender {
    NSArray *vals = @[@"0", @"4095", @"32767", @"262143", @"1048575"];
    const NSInteger i = sender.indexOfSelectedItem;
    if (i >= 0 && i < (NSInteger)vals.count) [self postSettings:@{@"taps": vals[i]}];
}
- (void)onAttenChanged:(NSPopUpButton *)sender {
    NSArray *vals = @[@"0", @"120", @"160", @"180", @"220"];
    const NSInteger i = sender.indexOfSelectedItem;
    if (i >= 0 && i < (NSInteger)vals.count) [self postSettings:@{@"atten": vals[i]}];
}
- (void)onTransitionChanged:(NSPopUpButton *)sender {
    NSArray *vals = @[@"0", @"0.02", @"0.04", @"0.08", @"0.15"];
    const NSInteger i = sender.indexOfSelectedItem;
    if (i >= 0 && i < (NSInteger)vals.count) [self postSettings:@{@"transition": vals[i]}];
}
- (void)onTwoStageChanged:(NSButton *)s {
    [self postSettings:@{@"twostage": s.state == NSControlStateValueOn ? @"1" : @"0"}];
}
- (void)onIspChanged:(NSButton *)s {
    [self postSettings:@{@"isp": s.state == NSControlStateValueOn ? @"1" : @"0"}];
}
- (void)onShaperChanged:(NSPopUpButton *)sender {
    [self postSettings:@{@"shaper": sender.titleOfSelectedItem ?: @"auto"}];
}
- (void)onSdmFilt1Changed:(NSPopUpButton *)sender {
    NSString *v = sender.selectedItem.representedObject;
    if ([v isKindOfClass:[NSString class]]) [self postSettings:@{@"sdmfilt": v}];
}
- (void)onSdmFiltNxChanged:(NSPopUpButton *)sender {
    NSString *v = sender.selectedItem.representedObject;
    if ([v isKindOfClass:[NSString class]]) [self postSettings:@{@"sdmfiltnx": v}];
}
- (void)onModFamilyChanged:(NSPopUpButton *)sender {
    [self postSettings:@{@"modfamily": sender.titleOfSelectedItem ?: @"ec"}];
}
- (void)onModOrderChanged:(NSPopUpButton *)sender {
    [self postSettings:@{@"modorder": sender.titleOfSelectedItem ?: @"7"}];
}
- (void)onDirectSdmChanged:(NSButton *)s {
    [self postSettings:@{@"directsdm": s.state == NSControlStateValueOn ? @"1" : @"0"}];
}
- (void)onModCutChanged:(NSPopUpButton *)sender {
    if (sender.titleOfSelectedItem.length) [self postSettings:@{@"modcut": sender.titleOfSelectedItem}];
}
- (void)onAhmBitsChanged:(NSPopUpButton *)sender {
    if (sender.titleOfSelectedItem.length) [self postSettings:@{@"ahmbits": sender.titleOfSelectedItem}];
}
- (void)onDsdKindChanged:(NSPopUpButton *)sender {
    if (sender.titleOfSelectedItem.length) [self postSettings:@{@"dsdkind": sender.titleOfSelectedItem}];
}
- (void)onDsdConvChanged:(NSPopUpButton *)sender {
    if (sender.titleOfSelectedItem.length) [self postSettings:@{@"dsdconv": sender.titleOfSelectedItem}];
}
- (void)onDsd2StageChanged:(NSButton *)s {
    [self postSettings:@{@"dsd2stage": s.state == NSControlStateValueOn ? @"1" : @"0"}];
}
- (void)onRateChanged:(NSPopUpButton *)sender {
    NSString *v = sender.selectedItem.representedObject;
    if ([v isKindOfClass:[NSString class]]) [self postSettings:@{@"rate": v}];
}
- (void)onRateFamilyChanged:(NSPopUpButton *)sender {
    NSString *v = sender.selectedItem.representedObject;
    if ([v isKindOfClass:[NSString class]]) [self postSettings:@{@"rateFamilyPolicy": v}];
}
- (void)onDsdChanged:(NSSegmentedControl *)sender {
    NSArray *vals = @[@"0", @"64", @"128", @"256", @"512"];
    const NSInteger i = sender.selectedSegment;
    if (i >= 0 && i < (NSInteger)vals.count) [self postSettings:@{@"dsd": vals[i]}];
}
- (void)onDeviceChanged:(NSPopUpButton *)sender {
    NSDictionary *d = sender.selectedItem.representedObject;
    NSString *devId = [d isKindOfClass:[NSDictionary class]] ? (d[@"id"] ?: @"") : @"";
    [self postSettings:@{@"device": devId}];
    [self reloadRates];
}
- (void)onBackendChanged:(NSPopUpButton *)sender {
    NSArray *vals = @[@"coreaudio", @"coreaudio-shared", @"upnp"];
    const NSInteger i = sender.indexOfSelectedItem;
    if (i >= 0 && i < (NSInteger)vals.count) [self postSettings:@{@"backend": vals[i]}];
}
- (void)onHogChanged:(NSButton *)sender {
    [self postSettings:@{@"hogexcl": (sender.state == NSControlStateValueOn ? @"1" : @"0")}];
}
- (void)onBitsChanged:(NSPopUpButton *)sender {
    NSArray *vals = @[@"-1", @"16", @"24", @"32"];
    const NSInteger i = sender.indexOfSelectedItem;
    if (i >= 0 && i < (NSInteger)vals.count) [self postSettings:@{@"bits": vals[i]}];
}
- (void)onBufferChanged:(NSPopUpButton *)sender {
    if (sender.titleOfSelectedItem.length) [self postSettings:@{@"buffer": sender.titleOfSelectedItem}];
}
- (void)onChannelsChanged:(NSPopUpButton *)sender {
    if (sender.titleOfSelectedItem.length) [self postSettings:@{@"channels": sender.titleOfSelectedItem}];
}
- (void)onRgModeChanged:(NSPopUpButton *)sender {
    if (sender.titleOfSelectedItem.length) [self postSettings:@{@"rgmode": sender.titleOfSelectedItem}];
}
- (void)onLoudnessChanged:(NSButton *)s {
    [self postSettings:@{@"loudness": s.state == NSControlStateValueOn ? @"1" : @"0"}];
}
- (void)onIrGpuChanged:(NSButton *)s {
    [self postSettings:@{@"irgpu": s.state == NSControlStateValueOn ? @"1" : @"0"}];
}

- (void)onPresetApply:(NSButton *)sender {
    NSString *path = [NSString stringWithFormat:@"/api/preset/apply?profile=%@", RLPEnc(sender.identifier)];
    self.statusMessage.stringValue = RLPTr(@"应用中…");
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:path body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            NSArray *notes = [json[@"notes"] isKindOfClass:[NSArray class]] ? json[@"notes"] : @[];
            NSString *saved = RLPTr(@"已保存设置，将在下一首或重新播放时生效");
            self_.bpLine.stringValue = notes.count ? [NSString stringWithFormat:@"%@ · %@", saved, [notes componentsJoinedByString:@"；"]] : saved;
            self_.statusMessage.stringValue = saved;
            RLPToast(saved);
            [self_ reloadSettings];
        } else {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"应用失败");
            self_.statusMessage.stringValue = err;
            RLPToast(err);
            [self_ syncAllControlsFromSettings];
        }
    }];
}

#pragma mark - EQ 动作

- (void)reloadEqPresets {
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/peq" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *names = [json[@"presets"] isKindOfClass:[NSArray class]] ? json[@"presets"] : @[];
        self_.eqPresetNames = names;
        [self_.eqPresetPopup removeAllItems];
        [self_.eqPresetPopup addItemWithTitle:RLPTr(@"加载预设…")];
        for (id n in names) if ([n isKindOfClass:[NSString class]]) [self_.eqPresetPopup addItemWithTitle:n];
        [self_.eqPresetPopup selectItemAtIndex:0];
    }];
}

- (void)onEqPresetLoad:(NSPopUpButton *)sender {
    const NSInteger i = sender.indexOfSelectedItem;
    if (i <= 0) return;
    NSString *name = sender.titleOfSelectedItem;
    if (!name.length) return;
    NSString *body = [NSString stringWithFormat:@"action=load&name=%@", RLPEnc(name)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/peq/preset" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            RLPToast([NSString stringWithFormat:@"%@ %@", RLPTr(@"已加载"), name]);
            [self_.eqView reload];
            [self_ reloadSettings];
        } else {
            RLPToast([json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"加载失败"));
        }
        [self_.eqPresetPopup selectItemAtIndex:0];
    }];
}

- (void)onEqOnChanged:(NSButton *)sender {
    const BOOL want = sender.state == NSControlStateValueOn;
    NSString *cur = [self str:@"eq" def:@""];
    if (want && !cur.length) {
        RLPToast(RLPTr(@"还没有 EQ 文件：请先加载 PEQ 预设或 OPRA"));
        sender.state = NSControlStateValueOff;
        return;
    }
    [self postSettings:@{@"eq": want ? cur : @""}];
}

- (void)onEqBypass:(id)sender {
    (void)sender;
    const BOOL on = [[self str:@"eq" def:@"0"] isEqualToString:@"1"];
    [self postSettings:@{@"eq": on ? @"0" : @"1"}];
}

- (void)syncEqOnCheck {
    const BOOL on = [self str:@"eq" def:@""].length > 0;
    self.eqOnCheck.state = on ? NSControlStateValueOn : NSControlStateValueOff;
}

#pragma mark - 信号链详情弹窗与节点弹层

- (void)showSignalChainDetail:(NSButton *)sender {
    RLPTheme *t = [RLPTheme current];
    NSStackView *card = [[NSStackView alloc] init];
    card.orientation = NSUserInterfaceLayoutOrientationVertical;
    card.alignment = NSLayoutAttributeLeading;
    card.spacing = 6;
    card.edgeInsets = NSEdgeInsetsMake(16, 18, 16, 18);
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [[card.widthAnchor constraintEqualToConstant:560] setActive:YES];

    NSTextField *hero = RLPLabel(RLPTr(@"读取信号链…"),
        [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], t.text);
    hero.maximumNumberOfLines = 2;
    hero.lineBreakMode = NSLineBreakByWordWrapping;
    [[hero.widthAnchor constraintEqualToConstant:520] setActive:YES];
    [card addArrangedSubview:hero];

    NSStackView *nodeList = [[NSStackView alloc] init];
    nodeList.orientation = NSUserInterfaceLayoutOrientationVertical;
    nodeList.alignment = NSLayoutAttributeLeading;
    nodeList.spacing = 5;
    nodeList.translatesAutoresizingMaskIntoConstraints = NO;
    [[nodeList.widthAnchor constraintEqualToConstant:520] setActive:YES];
    [card addArrangedSubview:nodeList];

    NSViewController *vc = RLPCardController(card, 580, 320);
    NSView *anchor = sender ?: self.view;
    RLPShowCardPopover(anchor, vc, 580);

    [[RLPCoreClient shared] getJSON:@"/api/signal" completion:^(NSDictionary * _Nullable json) {
        NSDictionary *resp = json ?: @{};
        NSString *why = nil;
        NSString *title = [RLPSignalChain heroTitleForResponse:resp why:&why];
        hero.stringValue = [title stringByAppendingFormat:@"\n%@", why ?: @""];
        hero.textColor = ([title rangeOfString:@"BIT-PERFECT"].location != NSNotFound) ? t.ok
                       : ([title rangeOfString:@"非 Bit-Perfect"].location != NSNotFound ? t.warn : t.text);

        for (NSView *v in [nodeList.arrangedSubviews copy]) {
            [nodeList removeArrangedSubview:v];
            [v removeFromSuperview];
        }
        NSArray<RLPSignalNode *> *nodes = [RLPSignalChain nodesForResponse:resp];
        if (!nodes.count) {
            [nodeList addArrangedSubview:RLPLabel(RLPTr(@"还没有开始播放"), t.body, t.mut)];
            return;
        }
        for (RLPSignalNode *n in nodes) {
            NSStackView *row = [[NSStackView alloc] init];
            row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
            row.alignment = NSLayoutAttributeTop;
            row.spacing = 8;
            NSView *dot = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 8, 8)];
            dot.wantsLayer = YES;
            dot.layer.cornerRadius = 4;
            NSColor *dotColor = n.kind == RLPSignalNodeLossless ? t.ok
                              : (n.kind == RLPSignalNodeGpu ? t.accent : t.mut);
            dot.layer.backgroundColor = dotColor.CGColor;
            [dot.widthAnchor constraintEqualToConstant:8].active = YES;
            [dot.heightAnchor constraintEqualToConstant:8].active = YES;
            [row addArrangedSubview:dot];

            NSStackView *text = [[NSStackView alloc] init];
            text.orientation = NSUserInterfaceLayoutOrientationVertical;
            text.alignment = NSLayoutAttributeLeading;
            text.spacing = 1;
            NSString *head = n.badge.length ? [NSString stringWithFormat:@"%@   ·   %@", n.key, n.badge] : n.key;
            NSTextField *k = RLPLabel(head, [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold], t.text);
            NSTextField *v = RLPLabel(n.value, t.small, t.text2);
            v.lineBreakMode = NSLineBreakByWordWrapping;
            v.maximumNumberOfLines = 3;
            [[v.widthAnchor constraintEqualToConstant:480] setActive:YES];
            [text addArrangedSubview:k];
            [text addArrangedSubview:v];
            [row addArrangedSubview:text];
            [nodeList addArrangedSubview:row];
        }
    }];
}

- (void)onChainNodeClicked:(NSButton *)sender {
    NSString *key = sender.identifier;
    NSString *why = RLPChainNodeDisabledReason(key, self.settings);
    if (why.length) { RLPToast(why); return; }
    RLPTheme *t = [RLPTheme current];
    NSStackView *s = [[NSStackView alloc] init];
    s.orientation = NSUserInterfaceLayoutOrientationVertical;
    s.alignment = NSLayoutAttributeLeading;
    s.spacing = 8;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *ti = RLPLabel([NSString stringWithFormat:@"%@ %@", RLPTr(@"调整"), key],
        [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], t.text);
    [s addArrangedSubview:ti];

    if ([key isEqualToString:@"resample"]) {
        NSMutableArray<NSString *> *rateVals = [NSMutableArray arrayWithObject:@"follow"];
        NSMutableArray<NSString *> *rateTitles = [NSMutableArray arrayWithObject:RLPTr(@"跟随源")];
        for (id r in self.rates) {
            [rateVals addObject:[r stringValue]];
            [rateTitles addObject:[NSString stringWithFormat:@"%@ Hz", r]];
        }
        NSPopUpButton *ratePop = [self popoverPopupWithValues:rateVals titles:rateTitles action:@selector(onNodeRate:)];
        NSInteger ri = [rateVals indexOfObject:[self str:@"rate" def:@"follow"]];
        [ratePop selectItemAtIndex:(ri == NSNotFound) ? 0 : ri];
        [s addArrangedSubview:[self inlineLabel:RLPTr(@"目标采样率")]];
        [s addArrangedSubview:ratePop];

        NSMutableArray<NSString *> *fVals = [NSMutableArray array];
        NSMutableArray<NSString *> *fTitles = [NSMutableArray array];
        for (NSDictionary *it in self.filters) {
            NSString *n = it[@"name"];
            if (![n isKindOfClass:[NSString class]] || !n.length) continue;
            [fVals addObject:n];
            [fTitles addObject:[NSString stringWithFormat:@"%@ · %@ · %@ taps · %@", n,
                                it[@"phaseName"] ?: @"", it[@"taps"] ?: @0,
                                RLPWorkbenchFilterUsesNx(it) ? @"filterNx" : @"filter"]];
        }
        NSPopUpButton *filtPop = [self popoverPopupWithValues:fVals titles:fTitles action:@selector(onNodeFilter:)];
        NSString *curFilter = RLPWorkbenchEditingFilter(self.settings, self.editingNxFilter, NULL);
        NSInteger fi = [fVals indexOfObject:curFilter];
        [filtPop selectItemAtIndex:(fi == NSNotFound) ? 0 : fi];
        [s addArrangedSubview:[self inlineLabel:RLPTr(@"滤波（1x / Nx 写的键不同）")]];
        [s addArrangedSubview:filtPop];
    } else if ([key isEqualToString:@"eq"]) {
        NSButton *on = [NSButton checkboxWithTitle:RLPTr(@"EQ 开") target:self action:@selector(onEqOnToggleFromNode:)];
        on.identifier = @"wb.node.eq.on";
        on.state = [self str:@"eq" def:@""].length ? NSControlStateValueOn : NSControlStateValueOff;
        [s addArrangedSubview:on];
    } else if ([key isEqualToString:@"ir"]) {
        NSButton *off = [NSButton buttonWithTitle:RLPTr(@"关闭卷积（清空 IR）") target:self action:@selector(onNodeIrOff:)];
        off.bezelStyle = NSBezelStyleRounded;
        off.enabled = [self str:@"ir" def:@""].length > 0;
        [s addArrangedSubview:off];
    } else if ([key isEqualToString:@"shaper"]) {
        NSArray *shapers = @[@"none", @"auto", @"NS1", @"NS4", @"NS5", @"NS9", @"LNS15", @"TPDF"];
        NSPopUpButton *p = [self popoverPopupWithValues:shapers titles:shapers action:@selector(onNodeShaper:)];
        NSInteger i = [shapers indexOfObject:[self str:@"shaper" def:@"none"]];
        [p selectItemAtIndex:(i == NSNotFound) ? 0 : i];
        [s addArrangedSubview:p];
    } else if ([key isEqualToString:@"sdm"]) {
        NSArray *vals = @[@"0", @"64", @"128", @"256", @"512"];
        NSArray *titles = @[RLPTr(@"PCM 输出（关）"), @"DSD64", @"DSD128", @"DSD256", @"DSD512"];
        NSPopUpButton *p = [self popoverPopupWithValues:vals titles:titles action:@selector(onNodeDsd:)];
        NSInteger i = [vals indexOfObject:[self str:@"dsd" def:@"0"]];
        [p selectItemAtIndex:(i == NSNotFound) ? 0 : i];
        [s addArrangedSubview:p];
    } else if ([key isEqualToString:@"out"]) {
        NSArray *bvals = @[@"coreaudio", @"coreaudio-shared", @"upnp"];
        NSArray *btitles = @[RLPTr(@"硬件直通（独占）"), RLPTr(@"系统混音（共享）"), RLPTr(@"UPnP 投放")];
        NSPopUpButton *bp = [self popoverPopupWithValues:bvals titles:btitles action:@selector(onNodeBackend:)];
        NSInteger bi = [bvals indexOfObject:[self str:@"backend" def:@"coreaudio"]];
        [bp selectItemAtIndex:(bi == NSNotFound) ? 0 : bi];
        [s addArrangedSubview:bp];
    } else {
        [s addArrangedSubview:[self inlineLabel:RLPTr(@"源规格由当前曲目决定，没有可调项。")]];
    }
    [self.popover close];
    NSView *anchor = self.chainNodes[key] ?: self.view;
    self.popover = RLPShowCardPopover(anchor, RLPCardController(s, 330, 120), 330);
}

- (NSPopUpButton *)popoverPopupWithValues:(NSArray<NSString *> *)values
                                   titles:(NSArray<NSString *> *)titles
                                   action:(SEL)action {
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    p.translatesAutoresizingMaskIntoConstraints = NO;
    p.font = [RLPTheme current].small;
    p.target = self;
    p.action = action;
    for (NSUInteger i = 0; i < values.count; ++i) {
        [p addItemWithTitle:(i < titles.count ? titles[i] : values[i])];
        [[p lastItem] setRepresentedObject:values[i]];
    }
    [[p.widthAnchor constraintEqualToConstant:300] setActive:YES];
    return p;
}

- (void)onEqOnToggleFromNode:(NSButton *)s { [self onEqOnChanged:s]; }
- (void)onNodeRate:(NSPopUpButton *)s { NSString *v = s.selectedItem.representedObject; if ([v isKindOfClass:[NSString class]]) [self postSettings:@{@"rate": v}]; }
- (void)onNodeFilter:(NSPopUpButton *)s {
    NSString *n = s.selectedItem.representedObject;
    if (![n isKindOfClass:[NSString class]] || !n.length) return;
    BOOL nx = NO;
    for (NSDictionary *it in self.filters) if ([it[@"name"] isEqualToString:n]) nx = RLPWorkbenchFilterUsesNx(it);
    self.editingNxFilter = nx;
    [self postSettings:@{(nx ? @"filterNx" : @"filter"): n}];
}
- (void)onNodeShaper:(NSPopUpButton *)s { NSString *v = s.selectedItem.representedObject; if ([v isKindOfClass:[NSString class]]) [self postSettings:@{@"shaper": v}]; }
- (void)onNodeDsd:(NSPopUpButton *)s { NSString *v = s.selectedItem.representedObject; if ([v isKindOfClass:[NSString class]]) [self postSettings:@{@"dsd": v}]; }
- (void)onNodeBackend:(NSPopUpButton *)s { NSString *v = s.selectedItem.representedObject; if ([v isKindOfClass:[NSString class]]) [self postSettings:@{@"backend": v}]; }
- (void)onNodeIrOff:(id)s { (void)s; [self postSettings:@{@"ir": @"0"}]; [self.popover close]; }

#pragma mark - 数据读写与乱序保护

- (NSString *)str:(NSString *)key def:(NSString *)def {
    id v = self.settings[key];
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
    return def;
}

- (void)postSettings:(NSDictionary<NSString *, NSString *> *)kv {
    if (!kv.count) return;
    ++self.settingsSeq; // 使更早发出的 GET /api/settings 失效
    self.statusMessage.stringValue = RLPTr(@"应用中…");
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in kv) [parts addObject:[NSString stringWithFormat:@"%@=%@", k, RLPEnc(kv[k])]];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/settings" body:[parts componentsJoinedByString:@"&"]
        completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            self_.statusMessage.stringValue = RLPTr(@"已生效");
            RLPToast(RLPTr(@"已生效"));
            [self_ reloadSettings];
        } else {
            self_.statusMessage.stringValue = RLPTr(@"保存失败，已保留原值");
            RLPToast(RLPTr(@"保存失败"));
            [self_ syncAllControlsFromSettings];
        }
    }];
}

- (void)applySettingsPayload:(NSDictionary *)kv forSeq:(NSUInteger)seq {
    if (seq > 0 && seq < self.settingsSeq) return; // 丢弃乱序到达的旧回包
    if (seq > self.settingsSeq) self.settingsSeq = seq;
    self.settings = [kv isKindOfClass:[NSDictionary class]] ? kv : @{};
    [self syncAllControlsFromSettings];
}

- (void)applyStatusPayload:(NSDictionary *)st forSeq:(NSUInteger)seq {
    if (seq > 0 && seq < self.statusSeq) return; // 丢弃乱序到达的旧回包
    if (seq > self.statusSeq) self.statusSeq = seq;
    self.status = [st isKindOfClass:[NSDictionary class]] ? st : @{};
    [self refreshChain];
    [self refreshTrackCard];
    if ([self.activeTab isEqualToString:@"monitor"]) [self refreshMonitor];
}

- (void)syncAllControlsFromSettings {
    [self syncOutputControls];
    [self rebuildFilterControls];
    [self refreshChain];
    [self refreshAB];
    [self syncEqOnCheck];
    const BOOL eqOn = [[self str:@"eq" def:@"0"] isEqualToString:@"1"];
    [self.eqBypass setTitle:eqOn ? RLPTr(@"旁路 EQ") : RLPTr(@"启用 EQ")];

    NSArray *vals = @[@"0", @"64", @"128", @"256", @"512"];
    NSInteger idx = [vals indexOfObject:[self str:@"dsd" def:@"0"]];
    self.dsdSeg.selectedSegment = (idx == NSNotFound) ? 0 : idx;
    [self.shaperPopup selectItemWithTitle:[self str:@"shaper" def:@"auto"]];
    [self.modFamilyPopup selectItemWithTitle:[self str:@"modfamily" def:@"ec"]];
    [self.modOrderPopup selectItemWithTitle:[self str:@"modorder" def:@"7"]];

    const BOOL dsdOn = [self str:@"dsd" def:@"0"].integerValue > 0;
    self.modFamilyPopup.enabled = dsdOn;
    self.modOrderPopup.enabled = dsdOn;

    NSDictionary *d = [self currentDeviceDict];
    const BOOL hasDop = d && [d[@"dopCarrierRate"] isKindOfClass:[NSNumber class]] && [d[@"dopCarrierRate"] doubleValue] > 0;
    for (NSInteger i = 1; i < 5; ++i) [self.dsdSeg setEnabled:hasDop forSegment:i];

    // 同步高级参数控件
    self.twoStageCheck.state = [[self str:@"twostage" def:@"0"] isEqualToString:@"1"] ? NSControlStateValueOn : NSControlStateValueOff;
    self.directSdmCheck.state = [[self str:@"directsdm" def:@"0"] isEqualToString:@"1"] ? NSControlStateValueOn : NSControlStateValueOff;
    self.ispCheck.state = [[self str:@"isp" def:@"0"] isEqualToString:@"1"] ? NSControlStateValueOn : NSControlStateValueOff;
    self.loudnessCheck.state = [[self str:@"loudness" def:@"0"] isEqualToString:@"1"] ? NSControlStateValueOn : NSControlStateValueOff;
    self.irGpuCheck.state = [[self str:@"irgpu" def:@"0"] isEqualToString:@"1"] ? NSControlStateValueOn : NSControlStateValueOff;
    self.dsd2StageCheck.state = [[self str:@"dsd2stage" def:@"0"] isEqualToString:@"1"] ? NSControlStateValueOn : NSControlStateValueOff;

    NSArray *bits = @[@"-1", @"16", @"24", @"32"];
    NSInteger bi = [bits indexOfObject:[self str:@"bits" def:@"-1"]];
    [self.bitsPopup selectItemAtIndex:(bi == NSNotFound) ? 0 : bi];
    NSArray *taps = @[@"0", @"4095", @"32767", @"262143", @"1048575"];
    NSInteger ti = [taps indexOfObject:[self str:@"taps" def:@"0"]];
    [self.tapsPopup selectItemAtIndex:(ti == NSNotFound) ? 0 : ti];
    NSArray *attens = @[@"0", @"120", @"160", @"180", @"220"];
    NSInteger ai = [attens indexOfObject:[self str:@"atten" def:@"0"]];
    [self.attenPopup selectItemAtIndex:(ai == NSNotFound) ? 0 : ai];
    NSArray *trans = @[@"0", @"0.02", @"0.04", @"0.08", @"0.15"];
    NSInteger tri = [trans indexOfObject:[self str:@"transition" def:@"0"]];
    [self.transitionPopup selectItemAtIndex:(tri == NSNotFound) ? 0 : tri];
    NSString *po = [self str:@"phase" def:@""];
    for (NSInteger i = 0; i < (NSInteger)self.phaseOverridePopup.numberOfItems; ++i) {
        if ([[[self.phaseOverridePopup itemAtIndex:i] representedObject] isEqualToString:po]) {
            [self.phaseOverridePopup selectItemAtIndex:i]; break;
        }
    }
    NSString *rf = [self str:@"rateFamilyPolicy" def:@"prefer"];
    for (NSInteger i = 0; i < (NSInteger)self.rateFamilyPopup.numberOfItems; ++i) {
        if ([[[self.rateFamilyPopup itemAtIndex:i] representedObject] isEqualToString:rf]) {
            [self.rateFamilyPopup selectItemAtIndex:i]; break;
        }
    }
    NSString *buf = [self str:@"buffer" def:@""];
    if (buf.length && [self.bufferPopup itemWithTitle:buf]) [self.bufferPopup selectItemWithTitle:buf];
    NSString *ch = [self str:@"channels" def:@"0"];
    if ([self.channelsPopup itemWithTitle:ch]) [self.channelsPopup selectItemWithTitle:ch];
    NSString *rg = [self str:@"rgmode" def:@"off"];
    if ([self.rgModePopup itemWithTitle:rg]) [self.rgModePopup selectItemWithTitle:rg];
}

- (void)activate {
    [self reloadAll];
    if (!self.poll && [RLPCoreClient shared].started) {
        __weak __typeof__(self) weakSelf = self;
        self.poll = [NSTimer scheduledTimerWithTimeInterval:1.2 repeats:YES block:^(NSTimer *t) {
            (void)t; [weakSelf reloadStatus];
        }];
    }
}
- (void)viewDidDisappear { [self.poll invalidate]; self.poll = nil; [super viewDidDisappear]; }
- (void)reloadData { [self reloadAll]; }

- (void)reloadAll {
    if (![RLPCoreClient shared].started) {
        [self setSubtitle:RLPTr(@"核心未启动")];
        [self refreshChain]; [self refreshAB]; [self refreshMonitor];
        return;
    }
    [self reloadFilters];
    [self reloadDevices];
    [self reloadSettings];
    [self reloadStatus];
    [self reloadProfiles];
    [self.eqView reload];
    [self reloadEqPresets];
}

- (void)reloadFilters {
    const NSUInteger seq = ++self.filtersSeq;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/filters" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.filtersSeq) return;
        self_.filters = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[];
        [self_ rebuildFilterControls];
        [self_ refreshChain];
    }];
}

- (void)reloadDevices {
    const NSUInteger seq = ++self.devicesSeq;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/devices" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.devicesSeq) return;
        self_.devices = [json[@"devices"] isKindOfClass:[NSArray class]] ? json[@"devices"] : @[];
        [self_.devicePopup removeAllItems];
        [self_.devicePopup addItemWithTitle:RLPTr(@"系统默认")];
        [[self_.devicePopup lastItem] setRepresentedObject:@{}];
        for (NSDictionary *d in self_.devices) {
            [self_.devicePopup addItemWithTitle:[d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : RLPTr(@"未知设备")];
            [[self_.devicePopup lastItem] setRepresentedObject:d];
        }
        [self_ syncOutputControls];
        [self_ reloadRates];
    }];
}

- (void)reloadRates {
    const NSUInteger seq = ++self.ratesSeq;
    NSString *dev = [self str:@"device" def:@""];
    NSString *url = dev.length ? [NSString stringWithFormat:@"/api/rates?device=%@", RLPEnc(dev)] : @"/api/rates";
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.ratesSeq) return;
        NSArray *rs = [json[@"rates"] isKindOfClass:[NSArray class]] ? json[@"rates"] : @[];
        self_.rates = rs;
        [self_.ratePopup removeAllItems];
        [self_.ratePopup addItemWithTitle:RLPTr(@"跟随源")];
        [[self_.ratePopup lastItem] setRepresentedObject:@"follow"];
        for (id r in rs) {
            if (![r isKindOfClass:[NSNumber class]]) continue;
            [self_.ratePopup addItemWithTitle:[NSString stringWithFormat:@"%@ Hz", r]];
            [[self_.ratePopup lastItem] setRepresentedObject:[(NSNumber *)r stringValue]];
        }
        NSString *cur = [self_ str:@"rate" def:@"follow"];
        for (NSInteger i = 0; i < (NSInteger)self_.ratePopup.numberOfItems; ++i) {
            if ([[self_.ratePopup itemAtIndex:i].representedObject isEqualToString:cur]) {
                [self_.ratePopup selectItemAtIndex:i]; break;
            }
        }
    }];
}

- (void)reloadSettings {
    const NSUInteger seq = ++self.settingsSeq;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/settings" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSDictionary *kv = [json[@"kv"] isKindOfClass:[NSDictionary class]] ? json[@"kv"] : @{};
        [self_ applySettingsPayload:kv forSeq:seq];
    }];
}

- (NSDictionary *)currentDeviceDict {
    NSString *cur = [self str:@"device" def:@""];
    for (NSDictionary *d in self.devices) {
        if (!cur.length && [d[@"default"] boolValue]) return d;
        if (cur.length && [d[@"id"] isEqualToString:cur]) return d;
    }
    return nil;
}

- (void)syncOutputControls {
    NSString *cur = [self str:@"device" def:@""];
    NSInteger sel = 0;
    if (cur.length) {
        for (NSInteger i = 0; i < (NSInteger)self.devices.count; ++i)
            if ([self.devices[i][@"id"] isEqualToString:cur]) { sel = i + 1; break; }
    }
    if (sel < (NSInteger)self.devicePopup.numberOfItems) [self.devicePopup selectItemAtIndex:sel];
    NSArray *vals = @[@"coreaudio", @"coreaudio-shared", @"upnp"];
    NSInteger bi = [vals indexOfObject:[self str:@"backend" def:@"coreaudio"]];
    [self.backendPopup selectItemAtIndex:(bi == NSNotFound ? 0 : bi)];
    self.hogCheck.state = [[self str:@"hogexcl" def:@"1"] isEqualToString:@"1"] ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)reloadStatus {
    const NSUInteger seq = ++self.statusSeq;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/status" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        [self_ applyStatusPayload:json ?: @{} forSeq:seq];
    }];
}

- (void)refreshChain {
    RLPTheme *t = [RLPTheme current];
    NSDictionary *s = self.settings ?: @{};
    NSDictionary *st = self.status ?: @{};
    NSString *fs = [st[@"inRate"] isKindOfClass:[NSNumber class]] ? [st[@"inRate"] stringValue] : nil;
    NSString *bits = [st[@"bits"] isKindOfClass:[NSNumber class]] ? [st[@"bits"] stringValue] : [self str:@"bits" def:@"—"];
    const BOOL dsd = [self str:@"dsd" def:@"0"].integerValue > 0;
    NSString *activeFilter = RLPWorkbenchActivePlaybackFilter(s, st, RLPTr(@"默认"));
    NSDictionary *vals = @{
        @"src": fs ? [NSString stringWithFormat:@"%@ Hz / %@ bit", fs, bits] : (dsd ? @"DSD" : @"—"),
        @"resample": [NSString stringWithFormat:@"%@ · %@", [self str:@"rate" def:@"follow"], activeFilter],
        @"eq": [[self str:@"eq" def:@"0"] isEqualToString:@"1"] ? RLPTr(@"开") : RLPTr(@"旁路"),
        @"ir": [self str:@"ir" def:@"0"],
        @"shaper": dsd ? @"none (DoP)" : [self str:@"shaper" def:@"auto"],
        @"sdm": dsd ? [NSString stringWithFormat:@"DSD%@ · %@%@", [self str:@"dsd" def:@"0"],
                       [self str:@"modfamily" def:@"ec"], [self str:@"modorder" def:@"7"]] : @"—",
        @"out": [NSString stringWithFormat:@"%@%@", [self str:@"backend" def:@"coreaudio"],
                 [[self str:@"hogexcl" def:@"1"] isEqualToString:@"1"] ? @" · Hog" : @""],
    };
    for (NSString *key in self.chainNodes) {
        NSView *node = self.chainNodes[key];
        NSString *why = RLPChainNodeDisabledReason(key, s);
        const BOOL applies = (why == nil);
        self.chainValues[key].stringValue = vals[key] ?: @"—";
        self.chainValues[key].textColor = applies ? t.text : t.mut;
        node.layer.borderColor = applies ? t.line.CGColor : t.line2.CGColor;
        node.alphaValue = applies ? 1.0 : 0.55;
        NSButton *hit = self.chainHits[key];
        if (hit) { hit.enabled = applies; hit.toolTip = applies ? RLPTr(@"点击看当前值") : why; }
        for (NSView *sub in node.subviews) {
            if ([sub.identifier isEqualToString:[NSString stringWithFormat:@"wb.why.%@", key]])
                ((NSTextField *)sub).stringValue = why ?: @"";
        }
    }
    NSString *stage = [st[@"filter"] isKindOfClass:[NSString class]] ? st[@"filter"] : nil;
    if (dsd && stage.length) {
        self.pipelineStageLine.stringValue = [NSString stringWithFormat:@"%@%@ · %@%@",
            RLPTr(@"管线阶段："), stage, RLPTr(@"你选的滤波："), activeFilter];
    } else {
        self.pipelineStageLine.stringValue = @"";
    }

    NSString *bp = [st[@"bitPerfect"] isKindOfClass:[NSString class]] ? st[@"bitPerfect"] : nil;
    NSString *why = [st[@"bitPerfectWhy"] isKindOfClass:[NSString class]] ? st[@"bitPerfectWhy"] : nil;
    if (bp.length) {
        self.bpLine.stringValue = [NSString stringWithFormat:@"bit-perfect: %@%@", bp, why.length ? [@" · " stringByAppendingString:why] : @""];
        self.bpLine.textColor = [bp isEqualToString:@"yes"] ? t.ok : t.mut;
    } else {
        self.bpLine.stringValue = RLPTr(@"信号链：源 → 重采样 → EQ → 卷积 → 抖动 → 调制 → 输出（点节点可改）");
        self.bpLine.textColor = t.mut;
    }
}

#pragma mark - 视图辅助与主题

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

- (NSTextField *)sectionTitle:(NSString *)text {
    NSTextField *l = RLPLabel(text, [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], [RLPTheme current].text);
    l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}

- (NSTextField *)inlineLabel:(NSString *)text {
    NSTextField *l = RLPLabel(text, [RLPTheme current].small, [RLPTheme current].mut);
    l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}

- (void)addFullWidth:(NSView *)v toStack:(NSStackView *)target height:(CGFloat)h {
    [target addArrangedSubview:v];
    NSMutableArray *cs = [NSMutableArray array];
    CGFloat pad = (target == self.stack) ? -40.0 : 0.0;
    [cs addObject:[v.widthAnchor constraintEqualToAnchor:target.widthAnchor constant:pad]];
    if (h > 0) [cs addObject:[v.heightAnchor constraintEqualToConstant:h]];
    [NSLayoutConstraint activateConstraints:cs];
}

- (void)applyTheme {
    [super applyTheme];
    RLPTheme *t = [RLPTheme current];
    for (NSView *card in @[self.rackPCM ?: [NSView new], self.rackDSD ?: [NSView new], self.rackOutput ?: [NSView new]]) {
        card.layer.backgroundColor = t.bg2.CGColor;
        card.layer.borderColor = t.line.CGColor;
    }
    for (NSView *v in self.stack.arrangedSubviews) {
        if (v.wantsLayer && v.layer.cornerRadius > 0) {
            v.layer.backgroundColor = ([v.identifier isEqualToString:@"wb.trackcard"] ? t.card : t.bg2).CGColor;
            v.layer.borderColor = ([v.identifier isEqualToString:@"wb.trackcard"] ? t.hairline : t.line).CGColor;
        }
    }
    for (NSString *k in self.chainNodes) self.chainNodes[k].layer.backgroundColor = t.bg2.CGColor;
    for (NSTextField *l in self.headerLabels) l.textColor = (l.tag == 1) ? t.mut : t.text;
    self.headerTitle.textColor = t.hero;
    self.trackTitle.textColor = t.hero;
    if (self.trackCover) {
        self.trackCover.layer.backgroundColor = t.cardAlt.CGColor;
        self.trackCover.contentTintColor = t.mut;
    }
    [self selectStudioTab:self.activeTab ?: @"ab"];
    [self.eqView applyTheme];
    [self refreshChain];
    [self refreshTrackCard];
    [self refreshAB];
    [self refreshMonitor];
    if (self.profileStatus) self.profileStatus.textColor = t.mut;
    if (self.profileTable) [self.profileTable reloadData];
}

@end
