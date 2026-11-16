// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPWorkbenchViewController.mm — 专业工作台（1.1.7.1）
//
// 用户原话：「凡是靠装饰性 UI（比如黑胶唱片那一类）撑专业感的，一律去掉」
// 「信号链、快速 EQ、快速滤波切换、快速升频切换、快速输出切换…凡是发烧友会反复调的
//   东西，都摆在这一栏，能当场切换，不用进设置」
// 「允许同一首歌挂不同的滤波、不同的升频规格，存成多套配置，左右点着就能切、当场对比」
//
// 所以这一页每个像素都对应一个**真实可读/可改**的状态：没有唱片、没有旋转动画、没有假仪表。
// 真相源全部是既有后端；A/B 槽是 UI 偏好（NSUserDefaults），生效值永远从 /api/settings 读回。
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
@property (nonatomic, strong) NSStackView *stack;
// 信号链
@property (nonatomic, strong) NSStackView *chainRow;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSView *> *chainNodes;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSTextField *> *chainValues;
/// 节点上的"点击接收器"。节点不适用时它必须 enabled==NO —— 这是 B2 可断言的那一个属性。
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSButton *> *chainHits;
/// DSD 路径下 status.filter 是**管线阶段名**（DsdRateConverter/DirectSDM），
/// 不是用户选的滤波。两者同屏时必须标清楚哪个是哪个。
@property (nonatomic, strong) NSTextField *pipelineStageLine;
// ⑦ 更多快速开关（折叠区：发烧友偶尔调、但确实会调的那些）
@property (nonatomic, strong) NSButton *moreToggle;
@property (nonatomic, strong) NSStackView *moreBox;
@property (nonatomic, assign) BOOL moreExpanded;
@property (nonatomic, strong) NSPopUpButton *bitsPopup;
@property (nonatomic, strong) NSPopUpButton *tapsPopup;
@property (nonatomic, strong) NSPopUpButton *bufferPopup;
@property (nonatomic, strong) NSButton *twoStageCheck;
@property (nonatomic, strong) NSButton *directSdmCheck;
@property (nonatomic, strong) NSButton *ispCheck;
// ⑤ EQ 开关（eq=1/0）与"旁路"按钮是两件不同的事，必须分开。
@property (nonatomic, strong) NSButton *eqOnCheck;
@property (nonatomic, strong) NSTextField *bpLine;
// 快速切换
@property (nonatomic, strong) NSStackView *filterQuick;
@property (nonatomic, strong) NSPopUpButton *filterAll;
@property (nonatomic, strong) NSSegmentedControl *phaseSeg;      // 相位快切（同家族）
@property (nonatomic, strong) NSSearchField *filterSearch;       // 几十项滤波要能搜
@property (nonatomic, strong) NSPopUpButton *modOrderPopup;      // 调制阶数（DSD 路径）
@property (nonatomic, strong) NSPopUpButton *eqPresetPopup;      // PEQ 预设快速加载
@property (nonatomic, copy) NSArray<NSString *> *eqPresetNames;
@property (nonatomic, copy) NSString *filterQuery;
@property (nonatomic, assign) BOOL editingNxFilter;              // 当前正在编辑 1x(filter) 还是 Nx(filterNx) 槽
@property (nonatomic, strong) NSPopUpButton *ratePopup;
@property (nonatomic, strong) NSSegmentedControl *dsdSeg;
@property (nonatomic, strong) NSPopUpButton *shaperPopup;
@property (nonatomic, strong) NSPopUpButton *modFamilyPopup;
@property (nonatomic, strong) NSPopUpButton *devicePopup;
@property (nonatomic, strong) NSPopUpButton *backendPopup;
@property (nonatomic, strong) NSButton *hogCheck;
@property (nonatomic, strong) NSButton *eqBypass;
@property (nonatomic, strong) RLPEqualizerView *eqView;
// A/B
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *abSlots;
@property (nonatomic, strong) NSMutableArray<NSButton *> *abButtons;
@property (nonatomic, strong) NSMutableArray<NSTextField *> *abSummaries;
@property (nonatomic, strong) NSButton *abToggle;
@property (nonatomic, assign) NSInteger abActive;
// U16 配置档（命名档；档列表与 active 都只来自后端 /api/profiles，不落 NSUserDefaults）
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *profiles;
@property (nonatomic, copy) NSString *profileActive;
@property (nonatomic, strong) NSTableView *profileTable;
@property (nonatomic, strong) NSScrollView *profileScroll;
@property (nonatomic, strong) NSTextField *profileStatus;
@property (nonatomic, strong) NSButton *profileSaveButton;
@property (nonatomic, strong) NSButton *profileApplyButton;
@property (nonatomic, strong) NSButton *profileDeleteButton;
// 数据
@property (nonatomic, copy) NSDictionary *settings;
@property (nonatomic, copy) NSArray<NSDictionary *> *filters;
@property (nonatomic, copy) NSArray<NSDictionary *> *devices;
@property (nonatomic, copy) NSArray<NSNumber *> *rates;
@property (nonatomic, copy) NSDictionary *status;
@property (nonatomic, strong) NSPopover *popover;
@property (nonatomic, strong) NSTimer *poll;
// 页头大标题 / 当前曲目卡（图一「数字音乐台」核心区块，数据全部来自 /api/status）
@property (nonatomic, strong) NSTextField *headerTitle;
@property (nonatomic, strong) NSTextField *headerSubtitle;
@property (nonatomic, strong) NSImageView *trackCover;
@property (nonatomic, strong) NSTextField *trackTitle;
@property (nonatomic, strong) NSTextField *trackSub;
@property (nonatomic, strong) NSTextField *sigSrc;
@property (nonatomic, strong) NSTextField *sigDsp;
@property (nonatomic, strong) NSTextField *sigOut;
@property (nonatomic, strong) NSMutableArray<NSTextField *> *headerLabels;
// 前向声明：ObjC 里"先用后定义"的私有方法必须在这里声明，否则报 no visible @interface。
- (NSString *)str:(NSString *)key def:(NSString *)def;
- (void)postSettings:(NSDictionary<NSString *, NSString *> *)kv;
- (void)reloadSettings;
- (void)reloadRates;
- (void)reloadStatus;
- (void)reloadFilters;
- (void)reloadDevices;
- (void)reloadAll;
- (void)refreshChain;
- (void)refreshAB;
- (void)buildProfiles;
- (void)reloadProfiles;
- (void)refreshProfileStatus;
- (NSDictionary *)selectedProfile;
- (void)rebuildFilterControls;
- (void)reloadEqPresets;
- (void)syncPhaseSeg;
- (void)syncOutputControls;
- (NSDictionary *)currentDeviceDict;
- (NSTextField *)inlineLabel:(NSString *)text;
- (NSView *)cardWithIdentifier:(NSString *)ident;
- (NSTextField *)sectionTitle:(NSString *)text;
- (void)addFullWidth:(NSView *)v height:(CGFloat)h;
- (void)buildTrackCard;
- (void)refreshTrackCard;
- (void)onTrackCardPlay:(id)sender;
- (void)buildMoreSection;
- (void)refreshMoreControls;
- (void)syncEqOnCheck;
@end

@implementation RLPWorkbenchViewController

- (instancetype)init {
    self = [super initWithTitle:RLPTr(@"专业工作台")];
    if (self) {
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
    // documentView 不钉 bottom（钉了会把纵向 stack 拉伸、卡片间撑出大片空白）。
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

    [self buildHeader];
    [self buildTrackCard];
    [self buildChain];
    [self buildABSlots];
    [self buildProfiles];
    [self buildFilterSection];
    [self buildUpsampleSection];
    [self buildOutputSection];
    [self buildEqSection];
    [self buildMoreSection];
}

- (void)buildHeader {
    RLPTheme *t = [RLPTheme current];
    NSStackView *header = [[NSStackView alloc] init];
    header.orientation = NSUserInterfaceLayoutOrientationVertical;
    header.alignment = NSLayoutAttributeLeading;
    header.spacing = 4;
    header.translatesAutoresizingMaskIntoConstraints = NO;

    self.headerTitle = RLPLabel(RLPTr(@"数字音乐台"), t.display, t.hero);
    self.headerTitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerTitle.tag = 0;
    [header addArrangedSubview:self.headerTitle];

    self.headerSubtitle = RLPLabel(RLPTr(@"微调每一组声音，随时对比同一片段"), t.body, t.mut);
    self.headerSubtitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerSubtitle.tag = 1;
    [header addArrangedSubview:self.headerSubtitle];

    [self.headerLabels addObjectsFromArray:@[self.headerTitle, self.headerSubtitle]];
    [self addFullWidth:header height:0];
}

/// 图一「当前曲目 + 实际信号路径」大卡：全部数值来自 /api/status，UI 只排版不臆造。
- (void)buildTrackCard {
    RLPTheme *t = [RLPTheme current];
    NSView *card = [self cardWithIdentifier:@"wb.trackcard"];
    card.layer.backgroundColor = t.card.CGColor;
    card.layer.borderColor = t.hairline.CGColor;

    self.trackCover = [[NSImageView alloc] initWithFrame:NSZeroRect];
    self.trackCover.wantsLayer = YES;
    self.trackCover.layer.cornerRadius = t.rSm;
    self.trackCover.layer.masksToBounds = YES;
    self.trackCover.layer.backgroundColor = t.cardAlt.CGColor;
    self.trackCover.imageScaling = NSImageScaleProportionallyDown;
    self.trackCover.image = [NSImage imageWithSystemSymbolName:@"music.note" accessibilityDescription:RLPTr(@"封面")];
    self.trackCover.contentTintColor = t.mut;
    self.trackCover.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:self.trackCover];

    self.trackTitle = RLPLabel(RLPTr(@"还没有在播放的音乐"), t.heading, t.hero);
    self.trackTitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.trackTitle.tag = 0;
    self.trackTitle.maximumNumberOfLines = 2;
    self.trackTitle.lineBreakMode = NSLineBreakByTruncatingTail;
    [card addSubview:self.trackTitle];

    self.trackSub = RLPLabel(RLPTr(@"挑一张专辑开始聆听"), t.small, t.mut);
    self.trackSub.translatesAutoresizingMaskIntoConstraints = NO;
    self.trackSub.tag = 1;
    [card addSubview:self.trackSub];

    // 红色主按钮「播放」：与图一同款；点了走 /api/pause?on=0（继续），不重头播。
    NSButton *playBtn = [NSButton buttonWithTitle:RLPTr(@"播放") target:self action:@selector(onTrackCardPlay:)];
    playBtn.bezelStyle = NSBezelStyleRounded;
    playBtn.wantsLayer = YES;
    playBtn.layer.backgroundColor = t.accent.CGColor;
    playBtn.layer.cornerRadius = t.rSm;
    playBtn.contentTintColor = NSColor.whiteColor;
    playBtn.translatesAutoresizingMaskIntoConstraints = NO;
    playBtn.identifier = @"wb.trackplay";
    [card addSubview:playBtn];

    // 「实际信号路径」三列：源文件 / 声音处理 / 设备输出。
    NSView *sig = [[NSView alloc] initWithFrame:NSZeroRect];
    sig.translatesAutoresizingMaskIntoConstraints = NO;
    sig.wantsLayer = YES;
    sig.layer.borderWidth = 1;
    sig.layer.borderColor = t.hairline.CGColor;
    sig.layer.cornerRadius = t.rSm;
    [card addSubview:sig];
    NSArray<NSString *> *caps = @[RLPTr(@"源文件"), RLPTr(@"声音处理"), RLPTr(@"设备输出")];
    NSMutableArray<NSTextField *> *vals = [NSMutableArray array];
    NSMutableArray<NSTextField *> *labs = [NSMutableArray array];
    for (NSString *cap in caps) {
        NSTextField *lab = RLPLabel(cap, t.caption, t.mut);
        lab.translatesAutoresizingMaskIntoConstraints = NO;
        lab.tag = 1;
        NSTextField *val = RLPLabel(@"—", t.body, t.text);
        val.translatesAutoresizingMaskIntoConstraints = NO;
        val.tag = 0;
        val.maximumNumberOfLines = 2;
        val.lineBreakMode = NSLineBreakByTruncatingTail;
        [sig addSubview:lab]; [sig addSubview:val];
        [labs addObject:lab]; [vals addObject:val];
        [self.headerLabels addObject:lab];
        [self.headerLabels addObject:val];
    }
    self.sigSrc = vals[0]; self.sigDsp = vals[1]; self.sigOut = vals[2];
    [self.headerLabels addObjectsFromArray:@[self.trackTitle, self.trackSub]];

    [self addFullWidth:card height:190];
    [NSLayoutConstraint activateConstraints:@[
        [self.trackCover.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.trackCover.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [self.trackCover.widthAnchor constraintEqualToConstant:72],
        [self.trackCover.heightAnchor constraintEqualToConstant:72],
        [self.trackTitle.leadingAnchor constraintEqualToAnchor:self.trackCover.trailingAnchor constant:16],
        [self.trackTitle.topAnchor constraintEqualToAnchor:card.topAnchor constant:22],
        [self.trackTitle.trailingAnchor constraintLessThanOrEqualToAnchor:playBtn.leadingAnchor constant:-16],
        [self.trackSub.leadingAnchor constraintEqualToAnchor:self.trackTitle.leadingAnchor],
        [self.trackSub.topAnchor constraintEqualToAnchor:self.trackTitle.bottomAnchor constant:6],
        [self.trackSub.trailingAnchor constraintEqualToAnchor:self.trackTitle.trailingAnchor],
        [playBtn.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [playBtn.centerYAnchor constraintEqualToAnchor:self.trackCover.centerYAnchor],
        [playBtn.widthAnchor constraintEqualToConstant:84],
        [sig.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [sig.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [sig.topAnchor constraintEqualToAnchor:self.trackCover.bottomAnchor constant:14],
        [sig.heightAnchor constraintEqualToConstant:64],
    ]];
    // 三列等宽 + 列内标签在上值在下
    NSArray<NSTextField *> *allLabs = labs;
    for (NSInteger i = 0; i < 3; ++i) {
        NSTextField *lab = allLabs[i], *val = vals[i];
        NSLayoutXAxisAnchor *x = (i == 0) ? sig.leadingAnchor : vals[i - 1].trailingAnchor;
        [NSLayoutConstraint activateConstraints:@[
            [lab.leadingAnchor constraintEqualToAnchor:x constant:14],
            [lab.topAnchor constraintEqualToAnchor:sig.topAnchor constant:10],
            [val.leadingAnchor constraintEqualToAnchor:lab.leadingAnchor],
            [val.topAnchor constraintEqualToAnchor:lab.bottomAnchor constant:4],
            [val.widthAnchor constraintEqualToAnchor:sig.widthAnchor multiplier:0.30],
        ]];
    }
}

/// 图一红色「播放」：继续当前播放（/api/pause?on=0），不重头播。
- (void)onTrackCardPlay:(id)sender {
    (void)sender;
    RLPPostJSON(@"/api/pause?on=0", nil);
}

/// 用 /api/status 真值刷新当前曲目卡与三列信号路径（绝不臆造数值）。
- (void)refreshTrackCard {
    NSDictionary *st = self.status ?: @{};
    NSString *path = [st[@"file"] isKindOfClass:[NSString class]] ? st[@"file"] : nil;
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

    const double fs = [st[@"fs"] respondsToSelector:@selector(doubleValue)] ? [st[@"fs"] doubleValue] : 0.0;
    const NSInteger bits = [st[@"bits"] respondsToSelector:@selector(integerValue)] ? [st[@"bits"] integerValue] : 0;
    self.sigSrc.stringValue = (fs > 0)
        ? [NSString stringWithFormat:@"%.1f kHz / %ld bit", fs / 1000.0, (long)bits]
        : @"—";
    NSString *bp = [st[@"bitPerfect"] isKindOfClass:[NSString class]] ? st[@"bitPerfect"] : nil;
    self.sigDsp.stringValue = bp.length ? [NSString stringWithFormat:@"bit-perfect: %@", bp] : @"—";
    NSString *dev = self.devicePopup.titleOfSelectedItem;
    NSString *backend = [self str:@"backend" def:@"coreaudio"];
    self.sigOut.stringValue = [NSString stringWithFormat:@"%@ · %@", dev.length ? dev : RLPTr(@"默认设备"), backend];
}

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

- (void)addFullWidth:(NSView *)v height:(CGFloat)h {
    [self.stack addArrangedSubview:v];
    NSMutableArray *cs = [NSMutableArray array];
    [cs addObject:[v.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48]];
    if (h > 0) [cs addObject:[v.heightAnchor constraintEqualToConstant:h]];
    [NSLayoutConstraint activateConstraints:cs];
}

#pragma mark - 信号链详情（/api/signal 真实播放路径，对齐 web showChain）

/// 点「本次播放路径…」：拉 /api/signal，用 RLPSignalChain 纯函数生成节点并排版成弹层。
/// - 没开始播放（ok:false）⟹ 如实写「还没有开始播放」，不填假节点。
/// - 节点种类决定圆点颜色（lossless 绿 / dsp 蓝 / gpu 蓝绿 / tel 灰），与 web .cnode 同口径。
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

    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/signal" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        (void)self_;
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
            NSTextField *empty = RLPLabel(RLPTr(@"还没有开始播放"), t.body, t.mut);
            [nodeList addArrangedSubview:empty];
            return;
        }
        for (RLPSignalNode *n in nodes) {
            NSStackView *row = [[NSStackView alloc] init];
            row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
            row.alignment = NSLayoutAttributeTop;
            row.spacing = 8;
            // 圆点：颜色 = 节点种类
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
            NSString *head = n.badge.length
                ? [NSString stringWithFormat:@"%@   ·   %@", n.key, n.badge] : n.key;
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

#pragma mark - ① 信号链

- (void)buildChain {
    RLPTheme *t = [RLPTheme current];
    // 信号链详情入口（对齐 web 的「信号链」弹窗 / bChain）：
    // 下面 7 个节点是**按设置推导**的静态链；这里再给一个按钮打开 /api/signal 的
    // **本次真实播放路径**（逐节点真值 + bit-perfect 结论），两者不互相冒充。
    NSStackView *chainHead = [[NSStackView alloc] init];
    chainHead.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    chainHead.alignment = NSLayoutAttributeCenterY;
    chainHead.spacing = 10;
    NSTextField *chainTitle = RLPLabel(RLPTr(@"信号链"),
        [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], t.text);
    [chainHead addArrangedSubview:chainTitle];
    NSButton *detail = [NSButton buttonWithTitle:RLPTr(@"本次播放路径…")
        target:self action:@selector(showSignalChainDetail:)];
    detail.bezelStyle = NSBezelStyleRounded;
    detail.identifier = @"wb.chaindetail";
    [chainHead addArrangedSubview:detail];
    [self addFullWidth:chainHead height:22];

    self.bpLine = RLPLabel(@"", t.small, t.mut);
    self.bpLine.translatesAutoresizingMaskIntoConstraints = NO;
    self.bpLine.maximumNumberOfLines = 2;
    self.bpLine.lineBreakMode = NSLineBreakByWordWrapping;
    [self addFullWidth:self.bpLine height:0];

    self.chainRow = [[NSStackView alloc] init];
    self.chainRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.chainRow.spacing = 6;
    self.chainRow.translatesAutoresizingMaskIntoConstraints = NO;

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
        NSTextField *title = RLPLabel(n[1], t.small, t.mut);
        title.translatesAutoresizingMaskIntoConstraints = NO;
        NSTextField *val = RLPLabel(@"—", t.body, t.text);
        val.translatesAutoresizingMaskIntoConstraints = NO;
        val.lineBreakMode = NSLineBreakByTruncatingTail;
        NSTextField *why = RLPLabel(@"", [NSFont systemFontOfSize:10], t.warn);
        why.translatesAutoresizingMaskIntoConstraints = NO;
        why.lineBreakMode = NSLineBreakByTruncatingTail;
        NSButton *hit = [NSButton buttonWithTitle:@"" target:self action:@selector(onChainNodeClicked:)];
        hit.bordered = NO;
        hit.identifier = key;
        hit.translatesAutoresizingMaskIntoConstraints = NO;
        for (NSView *v in @[title, val, why, hit]) [node addSubview:v];
        [NSLayoutConstraint activateConstraints:@[
            [node.widthAnchor constraintEqualToConstant:132],
            [node.heightAnchor constraintEqualToConstant:74],
            [title.leadingAnchor constraintEqualToAnchor:node.leadingAnchor constant:10],
            [title.topAnchor constraintEqualToAnchor:node.topAnchor constant:8],
            [val.leadingAnchor constraintEqualToAnchor:node.leadingAnchor constant:10],
            [val.trailingAnchor constraintEqualToAnchor:node.trailingAnchor constant:-10],
            [val.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
            [why.leadingAnchor constraintEqualToAnchor:node.leadingAnchor constant:10],
            [why.trailingAnchor constraintEqualToAnchor:node.trailingAnchor constant:-8],
            [why.topAnchor constraintEqualToAnchor:val.bottomAnchor constant:2],
            [hit.leadingAnchor constraintEqualToAnchor:node.leadingAnchor],
            [hit.trailingAnchor constraintEqualToAnchor:node.trailingAnchor],
            [hit.topAnchor constraintEqualToAnchor:node.topAnchor],
            [hit.bottomAnchor constraintEqualToAnchor:node.bottomAnchor],
        ]];
        self.chainNodes[key] = node;
        self.chainValues[key] = val;
        self.chainHits[key] = hit;
        // 初始态就要安全：默认 PCM（dsd=0）⟹ SDM 节点先禁用。
        // 只在 refreshChain 里禁会漏掉"还没拿到设置"的那段时间（判据 B2j 抓到的）。
        {
            NSString *why0 = RLPChainNodeDisabledReason(key, @{});
            if (why0.length) {
                hit.enabled = NO;
                hit.toolTip = why0;
                node.alphaValue = 0.55;
            }
        }
        // 不适用原因用 tag 关联的 label 取回（identifier 已被节点占用）
        why.identifier = [NSString stringWithFormat:@"wb.why.%@", key];
        [self.chainRow addArrangedSubview:node];
    }
    [self addFullWidth:self.chainRow height:74];

    // DSD 路径专用的一行：管线阶段名 vs 用户选的滤波。
    // 后端 /api/status 的 filter 在 DSD 路径下是 "DsdRateConverter"/"DirectSDM"（阶段名），
    // 拿它当"用户选的滤波"显示是错的 —— 那一栏必须来自 /api/settings。
    self.pipelineStageLine = RLPLabel(@"", [NSFont systemFontOfSize:10], t.mut);
    self.pipelineStageLine.identifier = @"wb.pipelinestage";
    self.pipelineStageLine.translatesAutoresizingMaskIntoConstraints = NO;
    self.pipelineStageLine.maximumNumberOfLines = 2;
    self.pipelineStageLine.lineBreakMode = NSLineBreakByWordWrapping;
    [self addFullWidth:self.pipelineStageLine height:0];
}

#pragma mark - ② A/B 配置槽

- (void)buildABSlots {
    RLPTheme *t = [RLPTheme current];
    NSView *card = [self cardWithIdentifier:@"wb.ab"];
    NSTextField *ti = [self sectionTitle:RLPTr(@"A/B 对比")];
    NSTextField *note = RLPLabel(RLPTr(@"把当前设置存成多套配置，点着就能切、边听边比。只切听感相关项，不动输出设备。"), t.small, t.mut);
    note.translatesAutoresizingMaskIntoConstraints = NO;
    note.maximumNumberOfLines = 0;
    note.lineBreakMode = NSLineBreakByWordWrapping;
    for (NSView *v in @[ti, note]) [card addSubview:v];

    NSStackView *row = [[NSStackView alloc] init];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 10;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:row];

    NSArray *names = @[@"A", @"B", @"C", @"D"];
    for (NSInteger i = 0; i < kABSlotCount; ++i) {
        NSView *slot = [[NSView alloc] initWithFrame:NSZeroRect];
        slot.translatesAutoresizingMaskIntoConstraints = NO;
        slot.wantsLayer = YES;
        slot.layer.cornerRadius = t.rMd;
        slot.layer.backgroundColor = t.card.CGColor;
        slot.layer.borderWidth = 1;
        slot.layer.borderColor = t.hairline.CGColor;
        slot.identifier = [NSString stringWithFormat:@"wb.abslot.%ld", (long)i];
        // 大组名（图一四张独立调音卡）。名字就是槽位字母，不编造"流行/女声"之类
        // 用户没存过的流派 —— 真实配置摘要由 refreshAB 从 abSlots 快照填。
        NSTextField *big = RLPLabel(names[i], t.heading, t.hero);
        big.translatesAutoresizingMaskIntoConstraints = NO;
        big.tag = 0;
        NSTextField *cap = RLPLabel(RLPTr(@"独立配置 · 自动保存"), t.caption, t.mut);
        cap.translatesAutoresizingMaskIntoConstraints = NO;
        cap.tag = 1;
        [self.headerLabels addObject:big];
        [self.headerLabels addObject:cap];
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
        for (NSView *v in @[big, cap, pick, save, sum]) [slot addSubview:v];
        [NSLayoutConstraint activateConstraints:@[
            [slot.heightAnchor constraintEqualToConstant:118],
            [big.leadingAnchor constraintEqualToAnchor:slot.leadingAnchor constant:14],
            [big.topAnchor constraintEqualToAnchor:slot.topAnchor constant:12],
            [cap.leadingAnchor constraintEqualToAnchor:big.leadingAnchor],
            [cap.topAnchor constraintEqualToAnchor:big.bottomAnchor constant:2],
            [cap.trailingAnchor constraintEqualToAnchor:slot.trailingAnchor constant:-10],
            [pick.leadingAnchor constraintEqualToAnchor:big.leadingAnchor],
            [pick.topAnchor constraintEqualToAnchor:cap.bottomAnchor constant:10],
            [save.leadingAnchor constraintEqualToAnchor:pick.trailingAnchor constant:6],
            [save.centerYAnchor constraintEqualToAnchor:pick.centerYAnchor],
            [sum.leadingAnchor constraintEqualToAnchor:big.leadingAnchor],
            [sum.trailingAnchor constraintEqualToAnchor:slot.trailingAnchor constant:-10],
            [sum.topAnchor constraintEqualToAnchor:pick.bottomAnchor constant:6],
        ]];
        [self.abButtons addObject:pick];
        [self.abSummaries addObject:sum];
        [row addArrangedSubview:slot];
    }
    // 四卡等宽（去掉固定 190pt，让它随窗口铺满，与图一同观感）。
    [row.heightAnchor constraintEqualToConstant:118].active = YES;
    for (NSInteger i = 1; i < (NSInteger)row.arrangedSubviews.count; ++i)
        [row.arrangedSubviews[i].widthAnchor constraintEqualToAnchor:row.arrangedSubviews[0].widthAnchor].active = YES;
    self.abToggle = [NSButton buttonWithTitle:RLPTr(@"A⇄B 来回") target:self action:@selector(onABToggle:)];
    self.abToggle.bezelStyle = NSBezelStyleRounded;
    self.abToggle.identifier = @"wb.ab.toggle";
    self.abToggle.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:self.abToggle];

    [self addFullWidth:card height:210];
    [NSLayoutConstraint activateConstraints:@[
        [ti.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [ti.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [note.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [note.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [note.topAnchor constraintEqualToAnchor:ti.bottomAnchor constant:2],
        [row.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [row.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [row.topAnchor constraintEqualToAnchor:note.bottomAnchor constant:10],
        [self.abToggle.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [self.abToggle.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
    ]];
}

- (void)persistABSlots {
    [[NSUserDefaults standardUserDefaults] setObject:self.abSlots forKey:kABSlotsKey];
}

/// 存槽：抓的是**后端实测值**（/api/settings），不是 UI 上的临时选择。
- (void)onABSave:(NSButton *)sender {
    NSDictionary *snap = RLPABSnapshotFromSettings(self.settings);
    if (!snap.count) { RLPToast(RLPTr(@"设置还没读到")); return; }
    self.abSlots[sender.tag] = snap;
    [self persistABSlots];
    [self refreshAB];
    RLPToast([NSString stringWithFormat:@"%@ %@", RLPTr(@"已存为"), @[@"A",@"B",@"C",@"D"][sender.tag]]);
}

/// 切槽：一次 POST 多个键，**不停播放**（发烧友要边听边切），然后读回校验。
- (void)onABPick:(NSButton *)sender {
    NSDictionary *snap = self.abSlots[sender.tag];
    if (![snap isKindOfClass:[NSDictionary class]] || !snap.count) {
        RLPToast(RLPTr(@"这个槽还没保存 · 点「存为」把当前设置存进来"));
        return;
    }
    NSString *body = RLPABFormBody(snap);
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/settings" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            RLPToast([NSString stringWithFormat:@"%@ %@", RLPTr(@"已切到"), @[@"A",@"B",@"C",@"D"][sender.tag]]);
            [self_ reloadSettings];
        } else RLPToast(RLPTr(@"切换失败"));
    }];
}

- (void)onABToggle:(id)sender {
    // 在当前命中的槽与"另一个"之间来回；都没命中时从 A 开始。
    NSInteger cur = RLPABMatchSlot(self.settings, self.abSlots);
    NSInteger next = (cur == 0) ? 1 : 0;
    if (![self.abSlots[next] count]) {
        RLPToast(RLPTr(@"先把 A 与 B 都存好，再来回对比"));
        return;
    }
    NSButton *b = self.abButtons[next];
    [self onABPick:b];
}

- (void)refreshAB {
    RLPTheme *t = [RLPTheme current];
    const NSInteger hit = RLPABMatchSlot(self.settings, self.abSlots);
    self.abActive = hit;
    for (NSInteger i = 0; i < (NSInteger)self.abButtons.count; ++i) {
        NSButton *b = self.abButtons[i];
        const BOOL on = (i == hit);
        b.font = [NSFont systemFontOfSize:13 weight:on ? NSFontWeightBold : NSFontWeightRegular];
        b.contentTintColor = on ? t.accentText : t.text;
        NSDictionary *s = self.abSlots[i];
        self.abSummaries[i].stringValue = RLPABSlotSummary(s);
        self.abSummaries[i].toolTip = RLPABSlotSummary(s);
        self.abSummaries[i].textColor = on ? t.accentText : t.mut;
    }
}

#pragma mark - ②b 配置档（U16 命名档）

/// 配置档卡：命名档列表 + 保存/应用/删除。
/// 纪律：档列表与生效状态**只来自后端** /api/profiles（持久化在 state 目录），
/// NSUserDefaults 里只有旧的 A/B 槽；两者不混用，也不允许把 UI 上的临时选择当成档。
- (void)buildProfiles {
    RLPTheme *t = [RLPTheme current];
    NSView *card = [self cardWithIdentifier:@"wb.profiles"];
    NSTextField *ti = [self sectionTitle:RLPTr(@"配置档")];
    NSTextField *note = RLPLabel(RLPTr(@"把当前听感设置存成命名档，点应用即可切换。切档只动滤波/升频/DSD/EQ 等听感项，不动输出设备、独占与缓冲。"), t.small, t.mut);
    note.translatesAutoresizingMaskIntoConstraints = NO;
    note.maximumNumberOfLines = 0;
    note.lineBreakMode = NSLineBreakByWordWrapping;

    self.profileTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 640, 96)];
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

    self.profileScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.profileScroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.profileScroll.hasVerticalScroller = YES;
    self.profileScroll.autohidesScrollers = YES;
    self.profileScroll.drawsBackground = NO;
    self.profileScroll.borderType = NSNoBorder;
    self.profileScroll.documentView = self.profileTable;

    self.profileSaveButton = [NSButton buttonWithTitle:RLPTr(@"保存当前为配置档…") target:self action:@selector(onProfileSave:)];
    self.profileSaveButton.bezelStyle = NSBezelStyleRounded;
    self.profileSaveButton.identifier = @"wb.profile.save";
    self.profileSaveButton.font = t.small;
    self.profileSaveButton.translatesAutoresizingMaskIntoConstraints = NO;

    self.profileApplyButton = [NSButton buttonWithTitle:RLPTr(@"应用") target:self action:@selector(onProfileApply:)];
    self.profileApplyButton.bezelStyle = NSBezelStyleRounded;
    self.profileApplyButton.identifier = @"wb.profile.apply";
    self.profileApplyButton.font = t.small;
    self.profileApplyButton.translatesAutoresizingMaskIntoConstraints = NO;

    self.profileDeleteButton = [NSButton buttonWithTitle:RLPTr(@"删除") target:self action:@selector(onProfileDelete:)];
    self.profileDeleteButton.bezelStyle = NSBezelStyleRounded;
    self.profileDeleteButton.identifier = @"wb.profile.delete";
    self.profileDeleteButton.font = t.small;
    self.profileDeleteButton.translatesAutoresizingMaskIntoConstraints = NO;

    self.profileStatus = RLPLabel(RLPTr(@"还没有配置档"), t.caption, t.mut);
    self.profileStatus.identifier = @"wb.profile.status";
    self.profileStatus.translatesAutoresizingMaskIntoConstraints = NO;
    self.profileStatus.lineBreakMode = NSLineBreakByTruncatingTail;

    for (NSView *v in @[ti, note, self.profileScroll, self.profileSaveButton,
                        self.profileApplyButton, self.profileDeleteButton, self.profileStatus])
        [card addSubview:v];

    [NSLayoutConstraint activateConstraints:@[
        [ti.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [ti.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [note.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [note.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [note.topAnchor constraintEqualToAnchor:ti.bottomAnchor constant:2],
        [self.profileScroll.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [self.profileScroll.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [self.profileScroll.topAnchor constraintEqualToAnchor:note.bottomAnchor constant:8],
        [self.profileScroll.heightAnchor constraintEqualToConstant:96],
        [self.profileSaveButton.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [self.profileSaveButton.topAnchor constraintEqualToAnchor:self.profileScroll.bottomAnchor constant:10],
        [self.profileApplyButton.leadingAnchor constraintEqualToAnchor:self.profileSaveButton.trailingAnchor constant:8],
        [self.profileApplyButton.centerYAnchor constraintEqualToAnchor:self.profileSaveButton.centerYAnchor],
        [self.profileDeleteButton.leadingAnchor constraintEqualToAnchor:self.profileApplyButton.trailingAnchor constant:8],
        [self.profileDeleteButton.centerYAnchor constraintEqualToAnchor:self.profileSaveButton.centerYAnchor],
        [self.profileStatus.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [self.profileStatus.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [self.profileStatus.topAnchor constraintEqualToAnchor:self.profileSaveButton.bottomAnchor constant:6],
    ]];
    [self addFullWidth:card height:262];
    [self refreshProfileStatus];
}

- (void)refreshProfileStatus {
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

/// 读档列表：只认后端。失败/核心未启动时清空成空态（不沿用旧快照，避免"看起来还生效"）。
- (void)reloadProfiles {
    if (![RLPCoreClient shared].started) {
        self.profiles = [NSMutableArray array];
        self.profileActive = @"";
        [self.profileTable reloadData];
        [self refreshProfileStatus];
        return;
    }
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/profiles" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue] && [json[@"profiles"] isKindOfClass:[NSArray class]]) {
            self_.profiles = [(NSArray *)json[@"profiles"] mutableCopy];
            self_.profileActive = [json[@"active"] isKindOfClass:[NSString class]] ? json[@"active"] : @"";
        } else {
            self_.profiles = [NSMutableArray array];
            self_.profileActive = @"";
        }
        [self_.profileTable reloadData];
        // 选回当前档；没有 active 就选第一行 —— 「应用/删除」要有明确对象。
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
            if (skipped > 0) {
                RLPToast([NSString stringWithFormat:RLPTr(@"已应用配置档：%@ · 有 %ld 项没有生效"),
                          name, (long)skipped]);
            } else {
                RLPToast([NSString stringWithFormat:RLPTr(@"已应用配置档：%@"), name]);
            }
            // 工作台自己的读数立即刷新（设置页由 RLPSettingsChangedNotification 重读）。
            [self_ reloadSettings];
            [self_ reloadStatus];
            [self_ reloadEqPresets];
            [self_.eqView reload];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPSettingsChangedNotification"
                                                                object:nil];
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

#pragma mark - NSTableViewDataSource / NSTableViewDelegate（配置档列表）

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

#pragma mark - ③ 快速滤波切换

- (void)buildFilterSection {
    RLPTheme *t = [RLPTheme current];
    NSView *card = [self cardWithIdentifier:@"wb.filter"];
    NSTextField *ti = [self sectionTitle:RLPTr(@"滤波")];
    NSTextField *note = RLPLabel(RLPTr(@"点即切换。gauss 族更柔顺，poly-sinc/tight 更锐利；相位影响瞬态与预回声。"), t.small, t.mut);
    note.translatesAutoresizingMaskIntoConstraints = NO;
    note.maximumNumberOfLines = 0;
    note.lineBreakMode = NSLineBreakByWordWrapping;
    self.filterQuick = [[NSStackView alloc] init];
    self.filterQuick.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.filterQuick.spacing = 6;
    self.filterQuick.translatesAutoresizingMaskIntoConstraints = NO;
    self.filterAll = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.filterAll.translatesAutoresizingMaskIntoConstraints = NO;
    self.filterAll.target = self;
    self.filterAll.action = @selector(onFilterAllChanged:);
    self.filterAll.font = t.small;
    [[self.filterAll.widthAnchor constraintEqualToConstant:300] setActive:YES];
    // 相位快切：发烧友常来回比线性/最小相位的瞬态与预回声。
    self.phaseSeg = [NSSegmentedControl segmentedControlWithLabels:@[RLPTr(@"线性"), RLPTr(@"最小"), RLPTr(@"混合")]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(onPhaseChanged:)];
    self.phaseSeg.translatesAutoresizingMaskIntoConstraints = NO;
    self.phaseSeg.identifier = @"wb.phase";
    self.phaseSeg.toolTip = RLPTr(@"在当前滤波的同家族内切换相位；同家族没有该相位时该档不可用");
    // 滤波有几十项，必须能搜（否则下拉里翻半天）
    self.filterSearch = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    self.filterSearch.placeholderString = RLPTr(@"搜索滤波名");
    self.filterSearch.identifier = @"wb.filtersearch";
    self.filterSearch.translatesAutoresizingMaskIntoConstraints = NO;
    self.filterSearch.target = self;
    self.filterSearch.action = @selector(onFilterSearch:);
    self.filterSearch.font = t.small;
    [[self.filterSearch.widthAnchor constraintEqualToConstant:200] setActive:YES];
    for (NSView *v in @[ti, note, self.filterQuick, self.filterAll, self.phaseSeg, self.filterSearch]) [card addSubview:v];
    [self addFullWidth:card height:170];
    [NSLayoutConstraint activateConstraints:@[
        [ti.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [ti.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [note.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [note.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [note.topAnchor constraintEqualToAnchor:ti.bottomAnchor constant:2],
        [self.filterQuick.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [self.filterQuick.topAnchor constraintEqualToAnchor:note.bottomAnchor constant:8],
        [self.filterAll.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10],
        [self.filterAll.topAnchor constraintEqualToAnchor:self.filterQuick.bottomAnchor constant:6],
        [self.filterSearch.leadingAnchor constraintEqualToAnchor:self.filterAll.trailingAnchor constant:10],
        [self.filterSearch.centerYAnchor constraintEqualToAnchor:self.filterAll.centerYAnchor],
        [self.phaseSeg.leadingAnchor constraintEqualToAnchor:self.filterSearch.trailingAnchor constant:12],
        [self.phaseSeg.centerYAnchor constraintEqualToAnchor:self.filterAll.centerYAnchor],
    ]];
}

/// 常用项做成可点即切的按钮；完整列表（几十项）放下拉，按家族分组。
- (void)rebuildFilterControls {
    RLPTheme *t = [RLPTheme current];
    for (NSView *v in [self.filterQuick.arrangedSubviews copy]) {
        [self.filterQuick removeArrangedSubview:v]; [v removeFromSuperview];
    }
    BOOL slotIsNx = self.editingNxFilter;
    NSString *cur = RLPWorkbenchEditingFilter(self.settings, self.editingNxFilter, &slotIsNx);
    self.editingNxFilter = slotIsNx;
    // 搜索过滤：只影响下拉列表，不影响快捷区（快捷区是"常用"，不该被搜索词清空）。
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
            // **每组各取前 2 个**进快捷区：按分组顺序取前 6 会全落在 gauss 组，
            // 锐利族一个都点不到（离屏截图实测到的真缺陷）。
            if (perGroup < 2 && quick < 8 && !self.filterQuery.length) {
                NSButton *b = [NSButton buttonWithTitle:n target:self action:@selector(onFilterQuick:)];
                b.bezelStyle = NSBezelStyleRounded;
                b.font = [NSFont systemFontOfSize:10];
                b.identifier = n;
                b.translatesAutoresizingMaskIntoConstraints = NO;
                b.contentTintColor = [n isEqualToString:cur] ? t.accentText : t.text;
                b.font = [NSFont systemFontOfSize:10 weight:[n isEqualToString:cur] ? NSFontWeightBold : NSFontWeightRegular];
                [[b.widthAnchor constraintLessThanOrEqualToConstant:170] setActive:YES];
                [self.filterQuick addArrangedSubview:b];
                ++quick; ++perGroup;
            }
        }
    }
    // 回显当前项
    for (NSInteger i = 0; i < (NSInteger)self.filterAll.numberOfItems; ++i) {
        NSDictionary *ro = [[self.filterAll itemAtIndex:i] representedObject];
        if ([ro isKindOfClass:[NSDictionary class]] && [ro[@"name"] isEqualToString:cur]) {
            [self.filterAll selectItemAtIndex:i]; break;
        }
    }
    [self syncPhaseSeg];
}

#pragma mark 相位快切 / 滤波搜索

/// 相位档回显 + 可用性：同家族没有该相位就禁用那一档（不假装能切）。
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
        // 当前相位那一档始终可选（它就是当前值）
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
    NSString *name = ro[@"name"];
    if (!name.length) return;
    const BOOL nx = [ro[@"nx"] boolValue];
    self.editingNxFilter = nx;
    [self postSettings:@{(nx ? @"filterNx" : @"filter"): name}];
}


#pragma mark - ④ 快速升频切换

- (void)buildUpsampleSection {
    RLPTheme *t = [RLPTheme current];
    NSView *card = [self cardWithIdentifier:@"wb.upsample"];
    NSTextField *ti = [self sectionTitle:RLPTr(@"升频与调制")];
    NSTextField *note = RLPLabel(RLPTr(@"采样率只列设备真正支持的档；DSD 需要设备有 DoP 载波。"), t.small, t.mut);
    note.translatesAutoresizingMaskIntoConstraints = NO;
    note.maximumNumberOfLines = 0;
    note.lineBreakMode = NSLineBreakByWordWrapping;

    self.ratePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.ratePopup.translatesAutoresizingMaskIntoConstraints = NO;
    self.ratePopup.target = self; self.ratePopup.action = @selector(onRateChanged:);
    self.ratePopup.font = t.small;
    [[self.ratePopup.widthAnchor constraintEqualToConstant:190] setActive:YES];

    self.dsdSeg = [NSSegmentedControl segmentedControlWithLabels:@[@"PCM", @"DSD64", @"128", @"256", @"512"]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(onDsdChanged:)];
    self.dsdSeg.translatesAutoresizingMaskIntoConstraints = NO;

    self.shaperPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.shaperPopup.translatesAutoresizingMaskIntoConstraints = NO;
    self.shaperPopup.target = self; self.shaperPopup.action = @selector(onShaperChanged:);
    self.shaperPopup.font = t.small;
    [self.shaperPopup addItemsWithTitles:@[@"none", @"auto"]];
    [[self.shaperPopup.widthAnchor constraintEqualToConstant:110] setActive:YES];

    self.modFamilyPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.modFamilyPopup.translatesAutoresizingMaskIntoConstraints = NO;
    self.modFamilyPopup.target = self; self.modFamilyPopup.action = @selector(onModFamilyChanged:);
    self.modFamilyPopup.font = t.small;
    [self.modFamilyPopup addItemsWithTitles:@[@"dsd", @"chebyshev", @"ec", @"ahm"]];
    [[self.modFamilyPopup.widthAnchor constraintEqualToConstant:120] setActive:YES];

    // 调制阶数：DSD 路径下发烧友会反复试（ec 常用 7）
    self.modOrderPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.modOrderPopup.translatesAutoresizingMaskIntoConstraints = NO;
    self.modOrderPopup.target = self; self.modOrderPopup.action = @selector(onModOrderChanged:);
    self.modOrderPopup.identifier = @"wb.modorder";
    self.modOrderPopup.font = t.small;
    [self.modOrderPopup addItemsWithTitles:@[@"5", @"6", @"7", @"8", @"9"]];
    [[self.modOrderPopup.widthAnchor constraintEqualToConstant:70] setActive:YES];
    // 初始按 PCM 处理（默认 dsd=0）：调制器族与阶数先禁用，读到真实设置后再按 dsd 放开。
    // 只在回调里禁会留一个"看起来能调其实不生效"的控件（判据 B7e 抓到的）。
    self.modOrderPopup.enabled = NO;
    self.modFamilyPopup.enabled = NO;
    self.modOrderPopup.toolTip = RLPTr(@"PCM 输出不经过调制器");
    self.modFamilyPopup.toolTip = RLPTr(@"PCM 输出不经过调制器");

    NSStackView *r1 = [[NSStackView alloc] init];
    r1.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r1.spacing = 10;
    r1.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *v in @[[self inlineLabel:RLPTr(@"采样率")], self.ratePopup,
                        [self inlineLabel:RLPTr(@"抖动")], self.shaperPopup,
                        [self inlineLabel:RLPTr(@"调制器")], self.modFamilyPopup,
                        [self inlineLabel:RLPTr(@"阶数")], self.modOrderPopup])
        [r1 addArrangedSubview:v];
    NSStackView *r2 = [[NSStackView alloc] init];
    r2.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r2.spacing = 10;
    r2.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *v in @[[self inlineLabel:RLPTr(@"输出模式")], self.dsdSeg]) [r2 addArrangedSubview:v];

    // 官方预设四档（一键把链路调到对应目标；notes 照实显示）
    NSStackView *r3 = [[NSStackView alloc] init];
    r3.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r3.spacing = 6;
    r3.translatesAutoresizingMaskIntoConstraints = NO;
    NSArray *presets = @[@[@"bitperfect", RLPTr(@"原音直通")], @[@"pcm", RLPTr(@"PCM 升频")],
                         @[@"dsd", RLPTr(@"DSD→DSD")], @[@"pcm2dsd", RLPTr(@"PCM→DSD")]];
    for (NSArray *p in presets) {
        NSButton *b = [NSButton buttonWithTitle:p[1] target:self action:@selector(onPresetApply:)];
        b.bezelStyle = NSBezelStyleRounded;
        b.identifier = p[0];
        b.font = t.small;
        [r3 addArrangedSubview:b];
    }
    for (NSView *v in @[ti, note, r1, r2, r3]) [card addSubview:v];
    // 高度要容得下三行控件 + 标题说明：186 会把底部预设行裁掉（离屏截图实测）。
    [self addFullWidth:card height:200];
    [NSLayoutConstraint activateConstraints:@[
        [ti.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [ti.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [note.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [note.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [note.topAnchor constraintEqualToAnchor:ti.bottomAnchor constant:2],
        [r1.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [r1.topAnchor constraintEqualToAnchor:note.bottomAnchor constant:8],
        [r2.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [r2.topAnchor constraintEqualToAnchor:r1.bottomAnchor constant:8],
        [r3.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [r3.topAnchor constraintEqualToAnchor:r2.bottomAnchor constant:8],
    ]];
}

- (NSTextField *)inlineLabel:(NSString *)text {
    NSTextField *l = RLPLabel(text, [RLPTheme current].small, [RLPTheme current].mut);
    l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}

- (void)onRateChanged:(NSPopUpButton *)sender {
    NSString *v = sender.selectedItem.representedObject;
    if (![v isKindOfClass:[NSString class]]) return;
    [self postSettings:@{@"rate": v}];
}
- (void)onDsdChanged:(NSSegmentedControl *)sender {
    NSArray *vals = @[@"0", @"64", @"128", @"256", @"512"];
    const NSInteger i = sender.selectedSegment;
    if (i < 0 || i >= (NSInteger)vals.count) return;
    [self postSettings:@{@"dsd": vals[i]}];
}
- (void)onShaperChanged:(NSPopUpButton *)sender {
    [self postSettings:@{@"shaper": sender.titleOfSelectedItem ?: @"auto"}];
}
- (void)onModFamilyChanged:(NSPopUpButton *)sender {
    [self postSettings:@{@"modfamily": sender.titleOfSelectedItem ?: @"ec"}];
}
- (void)onModOrderChanged:(NSPopUpButton *)sender {
    [self postSettings:@{@"modorder": sender.titleOfSelectedItem ?: @"7"}];
}
- (void)onPresetApply:(NSButton *)sender {
    NSString *path = [NSString stringWithFormat:@"/api/preset/apply?profile=%@", RLPEnc(sender.identifier)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:path body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            NSArray *notes = [json[@"notes"] isKindOfClass:[NSArray class]] ? json[@"notes"] : @[];
            // notes 是后端的决策说明（含降级原因），照实显示。
            self_.bpLine.stringValue = notes.count ? [notes componentsJoinedByString:@"；"] : RLPTr(@"已应用");
            RLPToast(RLPTr(@"已应用"));
            [self_ reloadSettings];
        } else {
            RLPToast([json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"应用失败"));
        }
    }];
}

#pragma mark - ⑤ 快速输出切换

- (void)buildOutputSection {
    RLPTheme *t = [RLPTheme current];
    NSView *card = [self cardWithIdentifier:@"wb.output"];
    NSTextField *ti = [self sectionTitle:RLPTr(@"输出")];
    self.devicePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.devicePopup.translatesAutoresizingMaskIntoConstraints = NO;
    self.devicePopup.target = self; self.devicePopup.action = @selector(onDeviceChanged:);
    self.devicePopup.font = t.small;
    [[self.devicePopup.widthAnchor constraintEqualToConstant:260] setActive:YES];
    self.backendPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.backendPopup.translatesAutoresizingMaskIntoConstraints = NO;
    self.backendPopup.target = self; self.backendPopup.action = @selector(onBackendChanged:);
    self.backendPopup.font = t.small;
    // mac 上真正有意义的三个；**绝不出现 wasapi/asio/native/NAA**（本平台不存在）
    [self.backendPopup addItemsWithTitles:@[RLPTr(@"硬件直通（独占）"), RLPTr(@"系统混音（共享）"), RLPTr(@"UPnP 投放")]];
    [[self.backendPopup.widthAnchor constraintEqualToConstant:190] setActive:YES];
    self.hogCheck = [NSButton checkboxWithTitle:RLPTr(@"严格独占（Hog）") target:self action:@selector(onHogChanged:)];
    self.hogCheck.translatesAutoresizingMaskIntoConstraints = NO;
    self.hogCheck.font = t.small;
    self.hogCheck.toolTip = RLPTr(@"开启后系统音量条与音量键失效，只能用本程序音量条；不能阻止其它 App 播放。");
    NSTextField *warn = RLPLabel(RLPTr(@"Hog 会让系统音量条失效（macOS 机制）"), [NSFont systemFontOfSize:10], t.warn);
    warn.translatesAutoresizingMaskIntoConstraints = NO;
    NSStackView *row = [[NSStackView alloc] init];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 10;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *v in @[self.devicePopup, self.backendPopup, self.hogCheck, warn]) [row addArrangedSubview:v];
    for (NSView *v in @[ti, row]) [card addSubview:v];
    [self addFullWidth:card height:86];
    [NSLayoutConstraint activateConstraints:@[
        [ti.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [ti.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [row.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10],
        [row.topAnchor constraintEqualToAnchor:ti.bottomAnchor constant:8],
    ]];
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
    if (i < 0 || i >= (NSInteger)vals.count) return;
    [self postSettings:@{@"backend": vals[i]}];
}
- (void)onHogChanged:(NSButton *)sender {
    [self postSettings:@{@"hogexcl": (sender.state == NSControlStateValueOn ? @"1" : @"0")}];
}

#pragma mark - ⑥ 快速 EQ

- (void)buildEqSection {
    RLPTheme *t = [RLPTheme current];
    NSView *card = [self cardWithIdentifier:@"wb.eq"];
    NSTextField *ti = [self sectionTitle:RLPTr(@"均衡（20 段 PEQ）")];
    self.eqBypass = [NSButton buttonWithTitle:RLPTr(@"旁路 EQ") target:self action:@selector(onEqBypass:)];
    self.eqBypass.bezelStyle = NSBezelStyleRounded;
    self.eqBypass.font = t.small;
    self.eqBypass.translatesAutoresizingMaskIntoConstraints = NO;
    // PEQ 预设快速加载（名单来自 GET /api/peq 的 presets，不硬编码）
    self.eqPresetPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.eqPresetPopup.translatesAutoresizingMaskIntoConstraints = NO;
    self.eqPresetPopup.target = self; self.eqPresetPopup.action = @selector(onEqPresetLoad:);
    self.eqPresetPopup.identifier = @"wb.eqpreset";
    self.eqPresetPopup.font = t.small;
    [self.eqPresetPopup addItemWithTitle:RLPTr(@"加载预设…")];
    [[self.eqPresetPopup.widthAnchor constraintEqualToConstant:200] setActive:YES];
    // EQ 开关（写 eq=<路径> / eq= 空）。与「旁路」按钮是同一件事的两个方向，
    // 但开关让"现在是开还是关"有明确的状态回显（按钮只能表达动作）。
    self.eqOnCheck = [NSButton checkboxWithTitle:RLPTr(@"EQ 开") target:self action:@selector(onEqOnChanged:)];
    self.eqOnCheck.identifier = @"wb.eqon";
    self.eqOnCheck.font = t.small;
    self.eqOnCheck.translatesAutoresizingMaskIntoConstraints = NO;
    self.eqView = [[RLPEqualizerView alloc] initWithFrame:NSMakeRect(0, 0, 900, 260)];
    self.eqView.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *v in @[ti, self.eqOnCheck, self.eqBypass, self.eqPresetPopup, self.eqView]) [card addSubview:v];
    [self addFullWidth:card height:310];
    [NSLayoutConstraint activateConstraints:@[
        [ti.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [ti.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [self.eqBypass.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [self.eqBypass.centerYAnchor constraintEqualToAnchor:ti.centerYAnchor],
        [self.eqOnCheck.trailingAnchor constraintEqualToAnchor:self.eqPresetPopup.leadingAnchor constant:-10],
        [self.eqOnCheck.centerYAnchor constraintEqualToAnchor:ti.centerYAnchor],
        [self.eqPresetPopup.trailingAnchor constraintEqualToAnchor:self.eqBypass.leadingAnchor constant:-10],
        [self.eqPresetPopup.centerYAnchor constraintEqualToAnchor:ti.centerYAnchor],
        [self.eqView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [self.eqView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [self.eqView.topAnchor constraintEqualToAnchor:ti.bottomAnchor constant:8],
        [self.eqView.heightAnchor constraintEqualToConstant:250],
    ]];
}

/// PEQ 预设名单：GET /api/peq 的 presets（内置 + 用户），UI 不硬编码第二份。
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
    if (i <= 0) return;                       // 第 0 项是占位标题
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
        // 没有 EQ 文件时"开启"写什么都不对：如实说明，绝不写一个空值假装已开。
        RLPToast(RLPTr(@"还没有 EQ 文件：设置里选一个，或用上面的 PEQ 预设"));
        sender.state = NSControlStateValueOff;
        return;
    }
    [self postSettings:@{@"eq": want ? cur : @""}];
}

/// 旁路 EQ：发烧友 A/B 时最常用的动作之一（不删曲线，只切 eq 开关）。
- (void)onEqBypass:(id)sender {
    const BOOL on = [[self str:@"eq" def:@"0"] isEqualToString:@"1"];
    [self postSettings:@{@"eq": on ? @"0" : @"1"}];
}

#pragma mark - ⑦ 更多快速开关（折叠区，别把页面堆成大杂烩）

/// 这些键都在后端 /api/settings 的白名单里，也都是发烧友真会去动的。
/// 但它们不是每次听歌都要调，所以收在一个折叠区里，而不是跟信号链抢位置。
- (void)buildMoreSection {
    RLPTheme *t = [RLPTheme current];
    NSView *card = [self cardWithIdentifier:@"wb.more"];
    self.moreToggle = [NSButton buttonWithTitle:RLPTr(@"更多快速开关 ▸")
                                          target:self action:@selector(onMoreToggle:)];
    self.moreToggle.bezelStyle = NSBezelStyleInline;
    self.moreToggle.identifier = @"wb.more.toggle";
    self.moreToggle.translatesAutoresizingMaskIntoConstraints = NO;

    self.moreBox = [[NSStackView alloc] init];
    self.moreBox.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.moreBox.alignment = NSLayoutAttributeLeading;
    self.moreBox.spacing = 8;
    self.moreBox.hidden = YES;
    self.moreBox.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *r1 = [[NSStackView alloc] init];
    r1.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r1.spacing = 10;
    r1.translatesAutoresizingMaskIntoConstraints = NO;

    self.bitsPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.bitsPopup.identifier = @"wb.bits";
    self.bitsPopup.target = self; self.bitsPopup.action = @selector(onBitsChanged:);
    self.bitsPopup.font = t.small;
    // -1 = 跟随源；0 = 24bit（后端语义：0 与 24 等价，这里只摆真正不同的档）
    [self.bitsPopup addItemsWithTitles:@[RLPTr(@"跟随源 (-1)"), @"16 bit", @"24 bit", @"32 bit"]];
    [[self.bitsPopup.widthAnchor constraintEqualToConstant:130] setActive:YES];

    self.tapsPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.tapsPopup.identifier = @"wb.taps";
    self.tapsPopup.target = self; self.tapsPopup.action = @selector(onTapsChanged:);
    self.tapsPopup.font = t.small;
    [self.tapsPopup addItemsWithTitles:@[RLPTr(@"跟随预设 (0)"), @"4095", @"32767", @"262143", @"1048575"]];
    [[self.tapsPopup.widthAnchor constraintEqualToConstant:140] setActive:YES];

    self.bufferPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.bufferPopup.identifier = @"wb.buffer";
    self.bufferPopup.target = self; self.bufferPopup.action = @selector(onBufferChanged:);
    self.bufferPopup.font = t.small;
    [self.bufferPopup addItemsWithTitles:@[@"50", @"100", @"200", @"500", @"1000"]];
    [[self.bufferPopup.widthAnchor constraintEqualToConstant:100] setActive:YES];

    for (NSView *v in @[[self inlineLabel:RLPTr(@"输出位深")], self.bitsPopup,
                        [self inlineLabel:RLPTr(@"抽头预算")], self.tapsPopup,
                        [self inlineLabel:RLPTr(@"缓冲 (ms)")], self.bufferPopup])
        [r1 addArrangedSubview:v];

    NSStackView *r2 = [[NSStackView alloc] init];
    r2.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r2.spacing = 14;
    r2.translatesAutoresizingMaskIntoConstraints = NO;
    self.twoStageCheck = [NSButton checkboxWithTitle:RLPTr(@"两段式升频")
                                              target:self action:@selector(onTwoStageChanged:)];
    self.twoStageCheck.identifier = @"wb.twostage";
    self.twoStageCheck.font = t.small;
    self.directSdmCheck = [NSButton checkboxWithTitle:RLPTr(@"DSD 直通（DirectSDM）")
                                               target:self action:@selector(onDirectSdmChanged:)];
    self.directSdmCheck.identifier = @"wb.directsdm";
    self.directSdmCheck.font = t.small;
    self.directSdmCheck.toolTip = RLPTr(@"仅当 DSD 源与目标同速率、且无 EQ/IR/音量处理时才能真正直通，否则后端会降级并给出原因。");
    self.ispCheck = [NSButton checkboxWithTitle:RLPTr(@"ISP 峰值预衰减")
                                         target:self action:@selector(onIspChanged:)];
    self.ispCheck.identifier = @"wb.isp";
    self.ispCheck.font = t.small;
    self.ispCheck.toolTip = RLPTr(@"升频后可能削波时提前降一点电平（过采样峰值预扫）。");
    for (NSView *v in @[self.twoStageCheck, self.directSdmCheck, self.ispCheck]) [r2 addArrangedSubview:v];

    for (NSView *v in @[self.moreToggle, self.moreBox]) [card addSubview:v];
    [self.moreBox addArrangedSubview:r1];
    [self.moreBox addArrangedSubview:r2];
    [self addFullWidth:card height:0];
    [NSLayoutConstraint activateConstraints:@[
        [self.moreToggle.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [self.moreToggle.topAnchor constraintEqualToAnchor:card.topAnchor constant:8],
        [self.moreBox.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [self.moreBox.trailingAnchor constraintLessThanOrEqualToAnchor:card.trailingAnchor constant:-14],
        [self.moreBox.topAnchor constraintEqualToAnchor:self.moreToggle.bottomAnchor constant:6],
        [card.bottomAnchor constraintEqualToAnchor:self.moreBox.bottomAnchor constant:12],
    ]];
}

- (void)onMoreToggle:(id)sender {
    self.moreExpanded = !self.moreExpanded;
    self.moreBox.hidden = !self.moreExpanded;
    self.moreToggle.title = self.moreExpanded ? RLPTr(@"更多快速开关 ▾") : RLPTr(@"更多快速开关 ▸");
}

- (void)onBitsChanged:(NSPopUpButton *)sender {
    NSArray *vals = @[@"-1", @"16", @"24", @"32"];
    const NSInteger i = sender.indexOfSelectedItem;
    if (i < 0 || i >= (NSInteger)vals.count) return;
    [self postSettings:@{@"bits": vals[i]}];
}
- (void)onTapsChanged:(NSPopUpButton *)sender {
    NSArray *vals = @[@"0", @"4095", @"32767", @"262143", @"1048575"];
    const NSInteger i = sender.indexOfSelectedItem;
    if (i < 0 || i >= (NSInteger)vals.count) return;
    [self postSettings:@{@"taps": vals[i]}];
}
- (void)onBufferChanged:(NSPopUpButton *)sender {
    NSString *v = sender.titleOfSelectedItem;
    if (v.length) [self postSettings:@{@"buffer": v}];
}
- (void)onTwoStageChanged:(NSButton *)s {
    [self postSettings:@{@"twostage": s.state == NSControlStateValueOn ? @"1" : @"0"}];
}
- (void)onDirectSdmChanged:(NSButton *)s {
    [self postSettings:@{@"directsdm": s.state == NSControlStateValueOn ? @"1" : @"0"}];
}
- (void)onIspChanged:(NSButton *)s {
    [self postSettings:@{@"isp": s.state == NSControlStateValueOn ? @"1" : @"0"}];
}

/// 折叠区回显：全部按 /api/settings 的真实值，不猜默认。
- (void)refreshMoreControls {
    NSArray *bits = @[@"-1", @"16", @"24", @"32"];
    NSInteger bi = [bits indexOfObject:[self str:@"bits" def:@"-1"]];
    [self.bitsPopup selectItemAtIndex:(bi == NSNotFound) ? 0 : bi];
    NSArray *taps = @[@"0", @"4095", @"32767", @"262143", @"1048575"];
    NSInteger ti = [taps indexOfObject:[self str:@"taps" def:@"0"]];
    [self.tapsPopup selectItemAtIndex:(ti == NSNotFound) ? 0 : ti];
    NSString *buf = [self str:@"buffer" def:@""];
    if (buf.length && [self.bufferPopup itemWithTitle:buf]) [self.bufferPopup selectItemWithTitle:buf];
    self.twoStageCheck.state = [[self str:@"twostage" def:@"0"] isEqualToString:@"1"] ? NSControlStateValueOn : NSControlStateValueOff;
    self.directSdmCheck.state = [[self str:@"directsdm" def:@"0"] isEqualToString:@"1"] ? NSControlStateValueOn : NSControlStateValueOff;
    self.ispCheck.state = [[self str:@"isp" def:@"0"] isEqualToString:@"1"] ? NSControlStateValueOn : NSControlStateValueOff;
}

/// EQ 开关回显（eq 键存的是 EQ 文本路径；空 = 没有 EQ）。
- (void)syncEqOnCheck {
    const BOOL on = [self str:@"eq" def:@""].length > 0;
    self.eqOnCheck.state = on ? NSControlStateValueOn : NSControlStateValueOff;
}

#pragma mark - 信号链节点点击（就地弹层看/改这一项）

- (void)onChainNodeClicked:(NSButton *)sender {
    NSString *key = sender.identifier;
    NSString *why = RLPChainNodeDisabledReason(key, self.settings);
    if (why.length) { RLPToast(why); return; }   // 不适用的节点如实说明，不假装能改
    RLPTheme *t = [RLPTheme current];
    NSStackView *s = [[NSStackView alloc] init];
    s.orientation = NSUserInterfaceLayoutOrientationVertical;
    s.alignment = NSLayoutAttributeLeading;
    s.spacing = 8;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *ti = RLPLabel([NSString stringWithFormat:@"%@ %@", RLPTr(@"调整"), key],
        [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], t.text);
    [s addArrangedSubview:ti];
    NSTextField *hint = RLPLabel(RLPTr(@"当前真实值如下；用下面各区的快速控件即可当场切换。"), t.small, t.mut);
    hint.maximumNumberOfLines = 0; hint.lineBreakMode = NSLineBreakByWordWrapping;
    hint.preferredMaxLayoutWidth = 300;
    [s addArrangedSubview:hint];
    [[hint.widthAnchor constraintEqualToConstant:300] setActive:YES];
    // ---- 就地可改：每个节点给自己的那一个真控件，改完立即 POST ----
    if ([key isEqualToString:@"resample"]) {
        // 目标采样率（只列设备真支持的档）+ 当前滤波（从 /api/filters 取，不硬编码）
        NSMutableArray<NSString *> *rateVals = [NSMutableArray arrayWithObject:@"follow"];
        NSMutableArray<NSString *> *rateTitles = [NSMutableArray arrayWithObject:RLPTr(@"跟随源")];
        for (id r in self.rates) {
            [rateVals addObject:[r stringValue]];
            [rateTitles addObject:[NSString stringWithFormat:@"%@ Hz", r]];
        }
        NSPopUpButton *ratePop = [self popoverPopupWithValues:rateVals titles:rateTitles
                                                       action:@selector(onNodeRate:)];
        NSString *curRate = [self str:@"rate" def:@"follow"];
        NSInteger ri = [rateVals indexOfObject:curRate];
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
        NSPopUpButton *filtPop = [self popoverPopupWithValues:fVals titles:fTitles
                                                       action:@selector(onNodeFilter:)];
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
        [s addArrangedSubview:[self inlineLabel:[NSString stringWithFormat:@"eq = %@",
            [self str:@"eq" def:RLPTr(@"（空 = 没有 EQ）")]]]];
    } else if ([key isEqualToString:@"ir"]) {
        NSButton *off = [NSButton buttonWithTitle:RLPTr(@"关闭卷积（清空 IR）")
                                           target:self action:@selector(onNodeIrOff:)];
        off.bezelStyle = NSBezelStyleRounded;
        off.enabled = [self str:@"ir" def:@""].length > 0;
        [s addArrangedSubview:off];
        [s addArrangedSubview:[self inlineLabel:[NSString stringWithFormat:@"ir = %@",
            [self str:@"ir" def:RLPTr(@"（空 = 不卷积）")]]]];
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
        NSArray *fams = @[@"dsd", @"ec", @"chebyshev", @"ahm"];
        NSPopUpButton *fp = [self popoverPopupWithValues:fams titles:fams action:@selector(onNodeModFamily:)];
        NSInteger f = [fams indexOfObject:[self str:@"modfamily" def:@"dsd"]];
        [fp selectItemAtIndex:(f == NSNotFound) ? 0 : f];
        [s addArrangedSubview:fp];
    } else if ([key isEqualToString:@"out"]) {
        NSArray *bvals = @[@"coreaudio", @"coreaudio-shared", @"upnp"];
        NSArray *btitles = @[RLPTr(@"硬件直通（独占）"), RLPTr(@"系统混音（共享）"), RLPTr(@"UPnP 投放")];
        NSPopUpButton *bp = [self popoverPopupWithValues:bvals titles:btitles action:@selector(onNodeBackend:)];
        NSInteger bi = [bvals indexOfObject:[self str:@"backend" def:@"coreaudio"]];
        [bp selectItemAtIndex:(bi == NSNotFound) ? 0 : bi];
        [s addArrangedSubview:bp];
        NSMutableArray<NSString *> *dvals = [NSMutableArray arrayWithObject:@""];
        NSMutableArray<NSString *> *dtitles = [NSMutableArray arrayWithObject:RLPTr(@"系统默认")];
        for (NSDictionary *d in self.devices) {
            [dvals addObject:d[@"id"] ?: @""];
            [dtitles addObject:d[@"name"] ?: RLPTr(@"未知设备")];
        }
        NSPopUpButton *dp = [self popoverPopupWithValues:dvals titles:dtitles action:@selector(onNodeDevice:)];
        NSInteger di = [dvals indexOfObject:[self str:@"device" def:@""]];
        [dp selectItemAtIndex:(di == NSNotFound) ? 0 : di];
        [s addArrangedSubview:dp];
        NSButton *hog = [NSButton checkboxWithTitle:RLPTr(@"严格独占（Hog，会让系统音量条失效）")
                                             target:self action:@selector(onNodeHog:)];
        hog.state = [[self str:@"hogexcl" def:@"0"] isEqualToString:@"1"] ? NSControlStateValueOn : NSControlStateValueOff;
        [s addArrangedSubview:hog];
    } else if ([key isEqualToString:@"ir"]) {
        NSButton *off = [NSButton buttonWithTitle:RLPTr(@"关闭卷积") target:self action:@selector(onNodeIrOff:)];
        off.bezelStyle = NSBezelStyleRounded;
        [s addArrangedSubview:off];
    } else {
        // src：源规格由曲目决定，没有可调项 —— 如实说，不摆一个改不了的控件。
        [s addArrangedSubview:[self inlineLabel:RLPTr(@"源规格由当前曲目决定，没有可调项。")]];
    }
    [self.popover close];
    NSView *anchor = self.chainNodes[key] ?: self.view;
    self.popover = RLPShowCardPopover(anchor, RLPCardController(s, 330, 120), 330);
}

#pragma mark - 节点弹层控件（就地可改）

/// 弹层里的下拉：representedObject 存真实值，title 给人看。
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

- (void)onNodeRate:(NSPopUpButton *)s {
    NSString *v = s.selectedItem.representedObject;
    if ([v isKindOfClass:[NSString class]]) [self postSettings:@{@"rate": v}];
}
- (void)onNodeFilter:(NSPopUpButton *)s {
    NSString *n = s.selectedItem.representedObject;
    if (![n isKindOfClass:[NSString class]] || !n.length) return;
    BOOL nx = NO;
    for (NSDictionary *it in self.filters) if ([it[@"name"] isEqualToString:n]) nx = RLPWorkbenchFilterUsesNx(it);
    self.editingNxFilter = nx;
    [self postSettings:@{(nx ? @"filterNx" : @"filter"): n}];
}
- (void)onNodeShaper:(NSPopUpButton *)s {
    NSString *v = s.selectedItem.representedObject;
    if ([v isKindOfClass:[NSString class]]) [self postSettings:@{@"shaper": v}];
}
- (void)onNodeDsd:(NSPopUpButton *)s {
    NSString *v = s.selectedItem.representedObject;
    if ([v isKindOfClass:[NSString class]]) [self postSettings:@{@"dsd": v}];
}
- (void)onNodeModFamily:(NSPopUpButton *)s {
    NSString *v = s.selectedItem.representedObject;
    if ([v isKindOfClass:[NSString class]]) [self postSettings:@{@"modfamily": v}];
}
- (void)onNodeBackend:(NSPopUpButton *)s {
    NSString *v = s.selectedItem.representedObject;
    if ([v isKindOfClass:[NSString class]]) [self postSettings:@{@"backend": v}];
}
- (void)onNodeDevice:(NSPopUpButton *)s {
    NSString *v = s.selectedItem.representedObject;
    if ([v isKindOfClass:[NSString class]]) [self postSettings:@{@"device": v}];
    [self reloadRates];
}
- (void)onNodeHog:(NSButton *)s {
    [self postSettings:@{@"hogexcl": (s.state == NSControlStateValueOn ? @"1" : @"0")}];
}
- (void)onNodeIrOff:(id)s {
    (void)s;
    [self postSettings:@{@"ir": @"0"}];
    [self.popover close];
}

#pragma mark - 数据

- (NSString *)str:(NSString *)key def:(NSString *)def {
    id v = self.settings[key];
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
    return def;
}

- (void)postSettings:(NSDictionary<NSString *, NSString *> *)kv {
    if (!kv.count) return;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in kv) [parts addObject:[NSString stringWithFormat:@"%@=%@", k, RLPEnc(kv[k])]];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/settings" body:[parts componentsJoinedByString:@"&"]
        completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) { RLPToast(RLPTr(@"已生效")); [self_ reloadSettings]; }
        else RLPToast(RLPTr(@"保存失败"));
    }];
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
        [self refreshChain]; [self refreshAB];
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
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/filters" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        self_.filters = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[];
        [self_ rebuildFilterControls];
        [self_ refreshChain];
    }];
}

- (void)reloadDevices {
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/devices" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
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
    NSString *dev = [self str:@"device" def:@""];
    NSString *url = dev.length ? [NSString stringWithFormat:@"/api/rates?device=%@", RLPEnc(dev)] : @"/api/rates";
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
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
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/settings" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        // ⚠️ 值在 kv 子对象里（读顶层会静默回落默认值，A/B 快照也会抓空）。
        self_.settings = [json[@"kv"] isKindOfClass:[NSDictionary class]] ? json[@"kv"] : @{};
        [self_ syncOutputControls];
        [self_ rebuildFilterControls];
        [self_ refreshChain];
        [self_ refreshAB];
        // U16：应用配置档可能改掉 eq（EQ 文本路径）。旧实现从未调用这个回显，
        // 勾选状态会停在旧值 —— 应用档后读数是假的。
        [self_ syncEqOnCheck];
        const BOOL eqOn = [[self_ str:@"eq" def:@"0"] isEqualToString:@"1"];
        [self_.eqBypass setTitle:eqOn ? RLPTr(@"旁路 EQ") : RLPTr(@"启用 EQ")];
        NSArray *vals = @[@"0", @"64", @"128", @"256", @"512"];
        NSInteger idx = [vals indexOfObject:[self_ str:@"dsd" def:@"0"]];
        self_.dsdSeg.selectedSegment = (idx == NSNotFound) ? 0 : idx;
        [self_.shaperPopup selectItemWithTitle:[self_ str:@"shaper" def:@"auto"]];
        [self_.modFamilyPopup selectItemWithTitle:[self_ str:@"modfamily" def:@"ec"]];
        [self_.modOrderPopup selectItemWithTitle:[self_ str:@"modorder" def:@"7"]];
        // PCM 输出不经过调制器 ⟹ 族与阶数都禁用（与信号链 SDM 节点灰显同口径）
        const BOOL dsdOn = [self_ str:@"dsd" def:@"0"].integerValue > 0;
        self_.modFamilyPopup.enabled = dsdOn;
        self_.modOrderPopup.enabled = dsdOn;
        self_.modOrderPopup.toolTip = dsdOn ? RLPTr(@"调制阶数（ec 常用 7）") : RLPTr(@"PCM 输出不经过调制器");
        NSDictionary *d = [self_ currentDeviceDict];
        const BOOL hasDop = d && [d[@"dopCarrierRate"] isKindOfClass:[NSNumber class]] && [d[@"dopCarrierRate"] doubleValue] > 0;
        for (NSInteger i = 1; i < 5; ++i) [self_.dsdSeg setEnabled:hasDop forSegment:i];
        self_.dsdSeg.toolTip = hasDop ? RLPTr(@"DSD 走 DoP 承载") : RLPTr(@"该设备无 DoP 载波，DSD 档不可用");
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
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/status" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        self_.status = json ?: @{};
        [self_ refreshChain];
        [self_ refreshTrackCard];   // 当前曲目卡 + 三列信号路径（真值，不臆造）
    }];
}

/// 信号链刷新：每个节点显示真实当前值；不适用的灰掉并写原因。
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
        // 不只是"看起来灰"：点击接收器必须真的禁用，否则用户点了会弹出一个改不动的层。
        // 这也是 B2 能断言的那一个属性（enabled==NO）。
        NSButton *hit = self.chainHits[key];
        if (hit) { hit.enabled = applies; hit.toolTip = applies ? RLPTr(@"点击看当前值") : why; }
        for (NSView *sub in node.subviews) {
            if ([sub.identifier isEqualToString:[NSString stringWithFormat:@"wb.why.%@", key]])
                ((NSTextField *)sub).stringValue = why ?: @"";
        }
    }
    // DSD 路径：status.filter 是管线阶段名，不是用户选的滤波 —— 同屏必须标清楚。
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
    } else if (!self.bpLine.stringValue.length) {
        self.bpLine.stringValue = RLPTr(@"信号链：源 → 重采样 → EQ → 卷积 → 抖动 → 调制 → 输出（点节点看当前值）");
        self.bpLine.textColor = t.mut;
    }
}

#pragma mark - 主题

- (void)applyTheme {
    [super applyTheme];
    RLPTheme *t = [RLPTheme current];
    for (NSView *v in self.stack.arrangedSubviews) {
        if (v.wantsLayer && v.layer.cornerRadius > 0) {
            v.layer.backgroundColor = t.bg2.CGColor;
            v.layer.borderColor = t.line.CGColor;
        }
    }
    for (NSString *k in self.chainNodes) self.chainNodes[k].layer.backgroundColor = t.bg2.CGColor;
    // 页头大标题 / 曲目卡 / 三列信号路径：新增常驻标签必须跟着主题重刷，
    // 否则浅底配深灰几乎看不见（聆听室 A6 同款真故障）。
    for (NSTextField *l in self.headerLabels)
        l.textColor = (l.tag == 1) ? t.mut : t.text;
    self.headerTitle.textColor = t.hero;
    self.trackTitle.textColor = t.hero;
    if (self.trackCover) {
        self.trackCover.layer.backgroundColor = t.cardAlt.CGColor;
        self.trackCover.contentTintColor = t.mut;
    }
    for (NSView *v in self.stack.arrangedSubviews) {
        if ([v.identifier isEqualToString:@"wb.trackcard"]) {
            v.layer.backgroundColor = t.card.CGColor;
            v.layer.borderColor = t.hairline.CGColor;
        }
    }
    [self.eqView applyTheme];
    [self refreshChain];
    [self refreshTrackCard];
    [self refreshAB];
    // U16：配置档状态行与档列表的行颜色也要跟着主题重刷（否则浅底深灰几乎看不见）。
    if (self.profileStatus) self.profileStatus.textColor = t.mut;
    if (self.profileTable) [self.profileTable reloadData];
}

@end
