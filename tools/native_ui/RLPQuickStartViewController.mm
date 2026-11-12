// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPQuickStartViewController.mm — 聆听室（1.1.7.1 合并页）
//
// 用户要求（逐条对应）：
//   ① 聆听室与快速开始**合并成一页**（不再是两个模块）。
//   ② 页内设置**全部用卡片式弹层就地完成**，不跳设置页。
//   ③ 这一页能直接做：当前设备下拉切换 / 输出（含独占）/ 播放三档 / 听音风格。
//   ④ 聆听模式里**没有「设置」入口**（要动设置去专业模式）。
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
// 四张卡（目标图版式：一行四张、等宽；小标签在上、大字值在下、右侧 chevron）
@property (nonatomic, strong) NSView *deviceCard;
@property (nonatomic, strong) NSView *outputCard;
@property (nonatomic, strong) NSView *playCard;
@property (nonatomic, strong) NSView *styleCard;
@property (nonatomic, strong) NSButton *deviceValue;   // 无边框大字按钮：显示真实设备名，点击出菜单
@property (nonatomic, strong) NSTextField *outputValue;
@property (nonatomic, strong) NSTextField *playValue;
@property (nonatomic, strong) NSTextField *styleValue;
@property (nonatomic, strong) NSButton *musicFolderButton;
@property (nonatomic, strong) NSTextField *heroTitle;
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
/// 细线（队列行分隔 / 专辑行分隔）：主题切换要跟着重刷，否则浅色主题下是深色线。
@property (nonatomic, strong) NSMutableArray<NSView *> *hairlines;
/// 卡片右侧 chevron（模板图，颜色随主题）。
@property (nonatomic, strong) NSMutableArray<NSImageView *> *chevrons;
@property (nonatomic, strong) NSTextField *presetNotes;
// 正在播放 / 队列 / 专辑
@property (nonatomic, strong) NSImageView *npCover;
@property (nonatomic, strong) NSTextField *npTitle;
@property (nonatomic, strong) NSTextField *npSub;
@property (nonatomic, strong) NSTextField *npState;
@property (nonatomic, strong) NSButton *npFav;
@property (nonatomic, strong) NSButton *npOpen;
@property (nonatomic, assign) BOOL npFavOn;
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
@property (nonatomic, strong) NSPopover *popover;
@property (nonatomic, assign) NSUInteger coverSeq;
@property (nonatomic, strong) NSTimer *poll;
@end

@implementation RLPQuickStartViewController

- (instancetype)init {
    self = [super initWithTitle:RLPTr(@"聆听室")];
    if (self) {
        _dynamicLabels = [NSMutableArray array];
        _hairlines = [NSMutableArray array];
        _chevrons = [NSMutableArray array];
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

    // 头部：大标题 + 右上「音乐文件夹」。
    // 目标图没有副标题；旧版副标题与页面实际能力不符，已删。
    // 「音乐文件夹」沿用既有导航（文件夹页）与既有 /api/lib/* 动作，不新造后端。
    NSView *head = [[NSView alloc] initWithFrame:NSZeroRect];
    head.translatesAutoresizingMaskIntoConstraints = NO;
    NSFont *heroFont = [NSFont fontWithName:@"Georgia-Bold" size:38];
    if (!heroFont) heroFont = t.display;
    NSTextField *title = RLPLabel(RLPTr(@"聆听室"), heroFont, t.hero);
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.identifier = @"room.hero";
    self.heroTitle = title;
    self.musicFolderButton = [NSButton buttonWithTitle:RLPTr(@"音乐文件夹")
                                                target:self action:@selector(onOpenMusicFolder:)];
    self.musicFolderButton.bezelStyle = NSBezelStyleRounded;
    self.musicFolderButton.identifier = @"room.musicfolder";
    self.musicFolderButton.translatesAutoresizingMaskIntoConstraints = NO;
    [head addSubview:title];
    [head addSubview:self.musicFolderButton];
    [self.stack addArrangedSubview:head];

    [NSLayoutConstraint activateConstraints:@[
        [head.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48],
        [head.heightAnchor constraintEqualToConstant:52],
        [title.leadingAnchor constraintEqualToAnchor:head.leadingAnchor],
        [title.centerYAnchor constraintEqualToAnchor:head.centerYAnchor],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:self.musicFolderButton.leadingAnchor constant:-12],
        [self.musicFolderButton.trailingAnchor constraintEqualToAnchor:head.trailingAnchor],
        [self.musicFolderButton.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [self.musicFolderButton.heightAnchor constraintEqualToConstant:28],
        [self.musicFolderButton.widthAnchor constraintGreaterThanOrEqualToConstant:92],
    ]];

    [self buildFourCards];
    [self buildNowPlayingAndQueue];
    [self buildAlbumRow];
}

/// 卡片外壳（圆角 + 边框，颜色在 applyTheme 里重刷）。
- (NSView *)cardWithIdentifier:(NSString *)ident {
    RLPTheme *t = [RLPTheme current];
    NSView *c = [[NSView alloc] initWithFrame:NSZeroRect];
    c.identifier = ident;
    c.wantsLayer = YES;
    c.layer.cornerRadius = t.rMd;
    c.layer.backgroundColor = (t.isLight ? t.bg2 : t.card).CGColor;
    c.layer.borderWidth = 1;
    c.layer.borderColor = t.line.CGColor;
    c.translatesAutoresizingMaskIntoConstraints = NO;
    return c;
}

#pragma mark - ① 四张卡

/// 卡面小标签（小字在上，目标图版式）。
- (NSTextField *)cardCaption:(NSString *)text card:(NSView *)card {
    RLPTheme *t = [RLPTheme current];
    NSTextField *l = RLPLabel(text, t.small, t.mut);
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [l.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [l.topAnchor constraintEqualToAnchor:card.topAnchor constant:10],
    ]];
    return l;
}

/// 卡面右侧 chevron（模板图，颜色在 applyTheme 里重刷）。centerY 由调用方钉到值上。
- (NSImageView *)chevronInCard:(NSView *)card down:(BOOL)down {
    NSImage *img = [NSImage imageWithSystemSymbolName:(down ? @"chevron.down" : @"chevron.right")
                            accessibilityDescription:nil];
    NSImageView *iv = [[NSImageView alloc] initWithFrame:NSZeroRect];
    iv.image = img;
    iv.contentTintColor = [RLPTheme current].mut;
    iv.imageScaling = NSImageScaleProportionallyDown;
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:iv];
    [self.chevrons addObject:iv];
    [NSLayoutConstraint activateConstraints:@[
        [iv.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [iv.widthAnchor constraintEqualToConstant:12],
        [iv.heightAnchor constraintEqualToConstant:12],
    ]];
    return iv;
}

/// 卡面大字值（在标签下；目标图是大字，不是 13px 正文）。
- (NSTextField *)cardValue:(NSString *)text card:(NSView *)card caption:(NSTextField *)caption
                     ident:(NSString *)ident chevron:(NSImageView *)chevron {
    RLPTheme *t = [RLPTheme current];
    NSTextField *v = RLPLabel(text, [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold], t.text);
    v.identifier = ident;
    v.lineBreakMode = NSLineBreakByTruncatingTail;
    v.maximumNumberOfLines = 1;
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [v.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [v.topAnchor constraintEqualToAnchor:caption.bottomAnchor constant:4],
        [v.trailingAnchor constraintEqualToAnchor:chevron.leadingAnchor constant:-8],
        [chevron.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
    ]];
    return v;
}

/// 整卡可点（透明按钮盖满，点开卡片式弹层）。
- (NSButton *)cardHitButton:(NSView *)card action:(SEL)action tip:(NSString *)tip {
    NSButton *b = [NSButton buttonWithTitle:@"" target:self action:action];
    b.bordered = NO;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.toolTip = tip;
    [card addSubview:b];
    [NSLayoutConstraint activateConstraints:@[
        [b.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [b.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [b.topAnchor constraintEqualToAnchor:card.topAnchor],
        [b.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];
    return b;
}

- (void)buildFourCards {
    RLPTheme *t = [RLPTheme current];
    NSView *row = [[NSView alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.identifier = @"room.cardrow";

    // ---- 卡 1：当前设备（大字 = /api/devices 里的真实设备名；值可点出下拉菜单）----
    self.deviceCard = [self cardWithIdentifier:@"room.device"];
    self.deviceCaption = [self cardCaption:RLPTr(@"当前设备") card:self.deviceCard];
    NSButton *devRefresh = RLPSymbolButton(@"arrow.clockwise", RLPTr(@"重新检测设备"), self, @selector(onReloadDevices:));
    devRefresh.translatesAutoresizingMaskIntoConstraints = NO;
    devRefresh.identifier = @"room.device.refresh";
    [self.deviceCard addSubview:devRefresh];
    // 名单未到时显示「系统默认」（这是选择语义，不是设备名）；拿到名单后替换为真实默认设备名。
    self.deviceValue = [NSButton buttonWithTitle:RLPTr(@"系统默认") target:self action:@selector(onDeviceMenu:)];
    self.deviceValue.bordered = NO;
    self.deviceValue.alignment = NSTextAlignmentLeft;
    self.deviceValue.font = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
    self.deviceValue.contentTintColor = t.text;
    self.deviceValue.identifier = @"room.device.value";
    [(NSButtonCell *)self.deviceValue.cell setLineBreakMode:NSLineBreakByTruncatingTail];
    self.deviceValue.translatesAutoresizingMaskIntoConstraints = NO;
    [self.deviceCard addSubview:self.deviceValue];
    NSImageView *downChevron = [self chevronInCard:self.deviceCard down:YES];
    [NSLayoutConstraint activateConstraints:@[
        [self.deviceValue.leadingAnchor constraintEqualToAnchor:self.deviceCard.leadingAnchor constant:14],
        [self.deviceValue.topAnchor constraintEqualToAnchor:self.deviceCaption.bottomAnchor constant:4],
        [self.deviceValue.trailingAnchor constraintLessThanOrEqualToAnchor:downChevron.leadingAnchor constant:-8],
        [downChevron.centerYAnchor constraintEqualToAnchor:self.deviceValue.centerYAnchor],
        [devRefresh.trailingAnchor constraintEqualToAnchor:self.deviceCard.trailingAnchor constant:-12],
        [devRefresh.centerYAnchor constraintEqualToAnchor:self.deviceCaption.centerYAnchor],
        [devRefresh.widthAnchor constraintEqualToConstant:20],
        [devRefresh.heightAnchor constraintEqualToConstant:20],
        [self.deviceCaption.trailingAnchor constraintLessThanOrEqualToAnchor:devRefresh.leadingAnchor constant:-6],
    ]];

    // ---- 卡 2：输出（弹层）----
    self.outputCard = [self cardWithIdentifier:@"room.output"];
    self.outputCaption = [self cardCaption:RLPTr(@"输出") card:self.outputCard];
    NSImageView *outChevron = [self chevronInCard:self.outputCard down:NO];
    self.outputValue = [self cardValue:RLPTr(@"读取中…") card:self.outputCard caption:self.outputCaption
                                 ident:@"room.output.value" chevron:outChevron];
    [self cardHitButton:self.outputCard action:@selector(onOpenOutput:) tip:RLPTr(@"点击选择输出方式")];

    // ---- 卡 3：播放方式（三档，弹层）----
    self.playCard = [self cardWithIdentifier:@"room.play"];
    self.playCaption = [self cardCaption:RLPTr(@"播放方式") card:self.playCard];
    NSImageView *playChevron = [self chevronInCard:self.playCard down:NO];
    self.playValue = [self cardValue:RLPTr(@"原音直通") card:self.playCard caption:self.playCaption
                               ident:@"room.play.value" chevron:playChevron];
    [self cardHitButton:self.playCard action:@selector(onOpenPlay:) tip:RLPTr(@"点击选择播放方式")];

    // ---- 卡 4：听音风格（弹层）----
    self.styleCard = [self cardWithIdentifier:@"room.style"];
    self.styleCaption = [self cardCaption:RLPTr(@"听音风格") card:self.styleCard];
    NSImageView *styleChevron = [self chevronInCard:self.styleCard down:NO];
    self.styleValue = [self cardValue:RLPTr(@"均衡自然") card:self.styleCard caption:self.styleCaption
                                ident:@"room.style.value" chevron:styleChevron];
    [self cardHitButton:self.styleCard action:@selector(onOpenStyle:) tip:RLPTr(@"点击选择听感风格")];

    for (NSView *c in @[self.deviceCard, self.outputCard, self.playCard, self.styleCard])
        [row addSubview:c];
    [self.stack addArrangedSubview:row];

    // 目标图：四张卡同一行、等宽铺满。用"四卡互相等宽 + 间距 12 + 首尾贴边"表达，
    // 不再用 0.24 的百分比（百分比会让最后一张差出 4%，肉眼可见不齐）。
    [NSLayoutConstraint activateConstraints:@[
        [row.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48],
        [row.heightAnchor constraintEqualToConstant:64],
        [self.deviceCard.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [self.outputCard.leadingAnchor constraintEqualToAnchor:self.deviceCard.trailingAnchor constant:12],
        [self.playCard.leadingAnchor constraintEqualToAnchor:self.outputCard.trailingAnchor constant:12],
        [self.styleCard.leadingAnchor constraintEqualToAnchor:self.playCard.trailingAnchor constant:12],
        [self.styleCard.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [self.deviceCard.widthAnchor constraintEqualToAnchor:self.outputCard.widthAnchor],
        [self.outputCard.widthAnchor constraintEqualToAnchor:self.playCard.widthAnchor],
        [self.playCard.widthAnchor constraintEqualToAnchor:self.styleCard.widthAnchor],
        [self.deviceCard.topAnchor constraintEqualToAnchor:row.topAnchor],
        [self.deviceCard.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [self.outputCard.topAnchor constraintEqualToAnchor:row.topAnchor],
        [self.outputCard.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [self.playCard.topAnchor constraintEqualToAnchor:row.topAnchor],
        [self.playCard.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [self.styleCard.topAnchor constraintEqualToAnchor:row.topAnchor],
        [self.styleCard.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
    ]];

    // 预设说明（后端 notes 照实显示；没有就不占版面，目标图这里没有这一行）。
    self.presetNotes = RLPLabel(@"", t.small, t.mut);
    self.presetNotes.translatesAutoresizingMaskIntoConstraints = NO;
    self.presetNotes.maximumNumberOfLines = 2;
    self.presetNotes.lineBreakMode = NSLineBreakByWordWrapping;
    self.presetNotes.hidden = YES;
    [self.stack addArrangedSubview:self.presetNotes];
    [[self.presetNotes.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48] setActive:YES];
}

#pragma mark - ② 正在播放 + 队列预览

- (void)buildNowPlayingAndQueue {
    RLPTheme *t = [RLPTheme current];
    NSView *row = [[NSView alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.identifier = @"room.nprow";

    NSView *np = [self cardWithIdentifier:@"room.nowplaying"];
    self.npCover = [[NSImageView alloc] initWithFrame:NSZeroRect];
    self.npCover.identifier = @"room.np.cover";
    self.npCover.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.npCover.wantsLayer = YES;
    self.npCover.layer.cornerRadius = t.rSm;
    self.npCover.layer.masksToBounds = YES;
    self.npCover.layer.backgroundColor = t.bg3.CGColor;
    self.npCover.translatesAutoresizingMaskIntoConstraints = NO;
    [self showCoverPlaceholder];   // 第一帧就有音符占位，不闪空白方块

    self.npState = RLPLabel(RLPTr(@"未播放"), [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold], t.mut);
    self.npState.identifier = @"room.np.state";
    self.npState.translatesAutoresizingMaskIntoConstraints = NO;

    // 大号衬线曲名（目标图是 Georgia Bold，可两行）
    NSFont *npFont = [NSFont fontWithName:@"Georgia-Bold" size:28];
    if (!npFont) npFont = t.serif;
    self.npTitle = RLPLabel(RLPTr(@"还没有在播放的音乐"), npFont, t.text);
    self.npTitle.identifier = @"room.np.title";
    self.npTitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.npTitle.maximumNumberOfLines = 2;
    self.npTitle.lineBreakMode = NSLineBreakByWordWrapping;

    self.npSub = RLPLabel(RLPTr(@"从下面的专辑挑一张开始"), t.body, t.mut);
    self.npSub.identifier = @"room.np.sub";
    self.npSub.translatesAutoresizingMaskIntoConstraints = NO;
    self.npSub.lineBreakMode = NSLineBreakByTruncatingTail;
    self.npSub.maximumNumberOfLines = 1;

    // 收藏：/api/fav（与专辑页、单曲页同一端点，不新造后端）。未播放时禁用并如实空态。
    self.npFav = [NSButton buttonWithTitle:RLPTr(@"收藏") target:self action:@selector(onFav:)];
    self.npFav.identifier = @"room.np.fav";
    self.npFav.bezelStyle = NSBezelStyleRounded;
    self.npFav.image = [NSImage imageWithSystemSymbolName:@"heart" accessibilityDescription:RLPTr(@"收藏")];
    self.npFav.imagePosition = NSImageLeading;
    self.npFav.enabled = NO;
    self.npFav.translatesAutoresizingMaskIntoConstraints = NO;

    self.npOpen = [NSButton buttonWithTitle:RLPTr(@"打开曲目详情") target:self action:@selector(onOpenNowPlaying:)];
    self.npOpen.identifier = @"room.np.open";
    self.npOpen.bezelStyle = NSBezelStyleRounded;
    self.npOpen.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSView *v in @[self.npCover, self.npState, self.npTitle, self.npSub, self.npFav, self.npOpen])
        [np addSubview:v];

    NSView *qcard = [self cardWithIdentifier:@"room.queue"];
    self.queueCaption = RLPLabel(RLPTr(@"播放队列"), t.heading, t.text);
    self.queueCaption.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *qAll = [NSButton buttonWithTitle:RLPTr(@"查看全部") target:self action:@selector(onOpenQueue:)];
    qAll.bezelStyle = NSBezelStyleRounded;
    qAll.identifier = @"room.queue.all";
    qAll.translatesAutoresizingMaskIntoConstraints = NO;
    self.queueList = [[NSStackView alloc] init];
    self.queueList.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.queueList.alignment = NSLayoutAttributeLeading;
    self.queueList.spacing = 0;
    self.queueList.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *v in @[self.queueCaption, qAll, self.queueList]) [qcard addSubview:v];

    [row addSubview:np];
    [row addSubview:qcard];
    [self.stack addArrangedSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [row.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48],
        // 目标图：左卡高约 335（1180 宽窗口下 300 上下），右栏队列卡同高
        [row.heightAnchor constraintEqualToConstant:300],
        [np.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [np.topAnchor constraintEqualToAnchor:row.topAnchor],
        [np.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [np.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-322],
        [qcard.leadingAnchor constraintEqualToAnchor:np.trailingAnchor constant:12],
        [qcard.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [qcard.topAnchor constraintEqualToAnchor:row.topAnchor],
        [qcard.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],

        // 左封面：目标图封面几乎占满卡高（>=180 是硬判据），居中留 30 边距
        [self.npCover.leadingAnchor constraintEqualToAnchor:np.leadingAnchor constant:30],
        [self.npCover.centerYAnchor constraintEqualToAnchor:np.centerYAnchor],
        [self.npCover.widthAnchor constraintEqualToConstant:240],
        [self.npCover.heightAnchor constraintEqualToConstant:240],

        // 右侧文字列：状态 → 大曲名 → 艺术家·专辑 → 两个按钮（每个都必须显式定位，
        // 否则无约束控件全堆在 (0,0) 重叠成一团 —— 离屏截图实测到的真 bug）。
        [self.npState.leadingAnchor constraintEqualToAnchor:self.npCover.trailingAnchor constant:24],
        [self.npState.topAnchor constraintEqualToAnchor:np.topAnchor constant:28],
        [self.npState.trailingAnchor constraintLessThanOrEqualToAnchor:np.trailingAnchor constant:-24],
        [self.npTitle.leadingAnchor constraintEqualToAnchor:self.npState.leadingAnchor],
        [self.npTitle.trailingAnchor constraintEqualToAnchor:np.trailingAnchor constant:-24],
        [self.npTitle.topAnchor constraintEqualToAnchor:self.npState.bottomAnchor constant:8],
        [self.npSub.leadingAnchor constraintEqualToAnchor:self.npState.leadingAnchor],
        [self.npSub.trailingAnchor constraintEqualToAnchor:np.trailingAnchor constant:-24],
        [self.npSub.topAnchor constraintGreaterThanOrEqualToAnchor:self.npTitle.bottomAnchor constant:8],
        [self.npSub.bottomAnchor constraintLessThanOrEqualToAnchor:self.npFav.topAnchor constant:-14],
        [self.npFav.leadingAnchor constraintEqualToAnchor:self.npState.leadingAnchor],
        [self.npFav.bottomAnchor constraintEqualToAnchor:np.bottomAnchor constant:-24],
        [self.npFav.heightAnchor constraintEqualToConstant:30],
        [self.npOpen.leadingAnchor constraintEqualToAnchor:self.npFav.trailingAnchor constant:10],
        [self.npOpen.centerYAnchor constraintEqualToAnchor:self.npFav.centerYAnchor],
        [self.npOpen.heightAnchor constraintEqualToConstant:30],
        [self.npOpen.trailingAnchor constraintLessThanOrEqualToAnchor:np.trailingAnchor constant:-24],

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

/// 队列行：编号 + 曲名 + 底部细线（目标图版式）。current 行用强调绿高亮。
- (NSView *)queueRowWithNumber:(NSInteger)number name:(NSString *)name current:(BOOL)current {
    RLPTheme *t = [RLPTheme current];
    NSView *r = [[NSView alloc] initWithFrame:NSZeroRect];
    r.translatesAutoresizingMaskIntoConstraints = NO;
    r.identifier = [NSString stringWithFormat:@"room.queue.row.%ld", (long)(number - 1)];
    if (current) r.tag = 1;   // 判据用：当前行

    NSTextField *num = [self trackedLabel:[NSString stringWithFormat:@"%ld", (long)number]
                                     font:t.small role:(current ? 3 : 1)];
    num.alignment = NSTextAlignmentRight;
    num.identifier = [NSString stringWithFormat:@"room.queue.num.%ld", (long)(number - 1)];
    NSTextField *nm = [self trackedLabel:(name.length ? name : @"")
                                    font:[NSFont systemFontOfSize:13 weight:(current ? NSFontWeightSemibold : NSFontWeightRegular)]
                                    role:(current ? 3 : 0)];
    nm.lineBreakMode = NSLineBreakByTruncatingTail;
    nm.identifier = [NSString stringWithFormat:@"room.queue.name.%ld", (long)(number - 1)];

    NSView *sep = [[NSView alloc] initWithFrame:NSZeroRect];
    sep.wantsLayer = YES;
    sep.layer.backgroundColor = t.hairline.CGColor;
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    sep.identifier = [NSString stringWithFormat:@"room.queue.sep.%ld", (long)(number - 1)];
    [self.hairlines addObject:sep];

    for (NSView *v in @[num, nm, sep]) [r addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [r.heightAnchor constraintEqualToConstant:36],
        [num.leadingAnchor constraintEqualToAnchor:r.leadingAnchor],
        [num.widthAnchor constraintEqualToConstant:20],
        [num.centerYAnchor constraintEqualToAnchor:r.centerYAnchor],
        [nm.leadingAnchor constraintEqualToAnchor:num.trailingAnchor constant:12],
        [nm.trailingAnchor constraintEqualToAnchor:r.trailingAnchor constant:-14],
        [nm.centerYAnchor constraintEqualToAnchor:r.centerYAnchor],
        [sep.leadingAnchor constraintEqualToAnchor:r.leadingAnchor],
        [sep.trailingAnchor constraintEqualToAnchor:r.trailingAnchor],
        [sep.bottomAnchor constraintEqualToAnchor:r.bottomAnchor],
        [sep.heightAnchor constraintEqualToConstant:1],
    ]];
    return r;
}

/// 渲染真实队列（/api/queue?meta=1 的 items/metas/index）。空队列如实提示，不占位造数。
- (void)renderQueueWithItems:(NSArray *)items metas:(NSArray *)metas index:(NSInteger)index {
    RLPTheme *t = [RLPTheme current];
    [self.hairlines removeAllObjects];
    for (NSView *v in [self.queueList.arrangedSubviews copy]) {
        [self.queueList removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    if (!items.count) {
        NSTextField *e = [self trackedLabel:RLPTr(@"队列是空的") font:t.small role:1];
        e.identifier = @"room.queue.empty";
        [self.queueList addArrangedSubview:e];
        return;
    }
    NSInteger n = 0;
    for (id it in items) {
        if (n >= 5) break;
        NSString *name = nil;
        if (n < (NSInteger)metas.count && [metas[n] isKindOfClass:[NSDictionary class]]) {
            NSString *mt = [metas[n][@"t"] isKindOfClass:[NSString class]] ? metas[n][@"t"] : nil;
            if (mt.length) name = mt;
        }
        if (!name.length) {
            if ([it isKindOfClass:[NSString class]]) {
                name = [(NSString *)it lastPathComponent];
            } else if ([it isKindOfClass:[NSDictionary class]]) {
                NSString *p = [it[@"path"] isKindOfClass:[NSString class]] ? it[@"path"] : it[@"file"];
                name = [p lastPathComponent];
            }
        }
        NSView *r = [self queueRowWithNumber:n + 1 name:name current:(index == n)];
        [self.queueList addArrangedSubview:r];
        [[r.widthAnchor constraintEqualToAnchor:self.queueList.widthAnchor] setActive:YES];
        ++n;
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
    openLib.identifier = @"room.album.openlibrary";
    openLib.bezelStyle = NSBezelStyleRounded;
    openLib.translatesAutoresizingMaskIntoConstraints = NO;
    [head addSubview:at];
    [head addSubview:openLib];
    [self.stack addArrangedSubview:head];

    self.albumRow = [[NSStackView alloc] init];
    self.albumRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.albumRow.distribution = NSStackViewDistributionFillEqually;   // 目标图：三列等宽横排
    self.albumRow.alignment = NSLayoutAttributeTop;
    self.albumRow.spacing = 24;
    self.albumRow.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stack addArrangedSubview:self.albumRow];

    [NSLayoutConstraint activateConstraints:@[
        [head.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48],
        [head.heightAnchor constraintEqualToConstant:30],
        [at.leadingAnchor constraintEqualToAnchor:head.leadingAnchor],
        [at.centerYAnchor constraintEqualToAnchor:head.centerYAnchor],
        [openLib.trailingAnchor constraintEqualToAnchor:head.trailingAnchor],
        [openLib.centerYAnchor constraintEqualToAnchor:at.centerYAnchor],
        [self.albumRow.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48],
        [self.albumRow.heightAnchor constraintEqualToConstant:76],
    ]];
}

/// 一列专辑：封面 + 名字 + 底部细线（目标图是"表格行"质感，不是大封面卡片）。
- (NSView *)albumCellWithKey:(NSString *)key name:(NSString *)name index:(NSInteger)idx {
    RLPTheme *t = [RLPTheme current];
    NSView *cell = [[NSView alloc] initWithFrame:NSZeroRect];
    cell.translatesAutoresizingMaskIntoConstraints = NO;
    cell.identifier = [NSString stringWithFormat:@"room.album.%ld", (long)idx];

    NSImageView *iv = [[NSImageView alloc] initWithFrame:NSZeroRect];
    iv.identifier = [NSString stringWithFormat:@"room.albumcover.%ld", (long)idx];
    iv.imageScaling = NSImageScaleProportionallyUpOrDown;
    iv.wantsLayer = YES;
    iv.layer.cornerRadius = t.rSm;
    iv.layer.masksToBounds = YES;
    iv.layer.backgroundColor = t.bg3.CGColor;
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    // 先放音符占位：封面异步加载失败时不留空白方块（目标图每格都有封面）
    NSImage *ph = [NSImage imageWithSystemSymbolName:@"music.note" accessibilityDescription:RLPTr(@"封面")];
    iv.image = ph;
    iv.contentTintColor = t.mut;
    iv.imageScaling = NSImageScaleProportionallyDown;

    NSFont *nameFont = [NSFont fontWithName:@"Georgia-Bold" size:16];
    if (!nameFont) nameFont = t.title;
    NSTextField *nm = [self trackedLabel:(name.length ? name : RLPTr(@"未知专辑")) font:nameFont role:0];
    nm.identifier = [NSString stringWithFormat:@"room.album.name.%ld", (long)idx];
    nm.lineBreakMode = NSLineBreakByTruncatingTail;
    nm.maximumNumberOfLines = 1;
    nm.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *sep = [[NSView alloc] initWithFrame:NSZeroRect];
    sep.wantsLayer = YES;
    sep.layer.backgroundColor = t.hairline.CGColor;
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    sep.identifier = [NSString stringWithFormat:@"room.album.sep.%ld", (long)idx];
    [self.hairlines addObject:sep];

    NSButton *hit = [NSButton buttonWithTitle:@"" target:self action:@selector(onAlbumClicked:)];
    hit.bordered = NO;
    hit.identifier = key;
    hit.translatesAutoresizingMaskIntoConstraints = NO;
    hit.toolTip = name ?: @"";

    for (NSView *v in @[iv, nm, sep, hit]) [cell addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [iv.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor],
        [iv.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        [iv.widthAnchor constraintEqualToConstant:60],
        [iv.heightAnchor constraintEqualToConstant:60],
        [nm.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:12],
        [nm.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],
        [nm.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        [sep.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor],
        [sep.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor],
        [sep.bottomAnchor constraintEqualToAnchor:cell.bottomAnchor],
        [sep.heightAnchor constraintEqualToConstant:1],
        [hit.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor],
        [hit.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor],
        [hit.topAnchor constraintEqualToAnchor:cell.topAnchor],
        [hit.bottomAnchor constraintEqualToAnchor:cell.bottomAnchor],
    ]];

    // 封面走共享缓存（后端 /api/lib/cover?k=…）；后端没起来（纯离线单测）就不发请求。
    if ([RLPCoreClient shared].started) {
        [[RLPCoverLoader shared] coverForAlbumKey:key completion:^(NSImage * _Nullable image) {
            if (!image) return;
            iv.image = image;
            iv.contentTintColor = nil;
        }];
    }
    return cell;
}

- (void)renderAlbums:(NSArray *)albums {
    RLPTheme *t = [RLPTheme current];
    for (NSView *v in [self.albumRow.arrangedSubviews copy]) {
        [self.albumRow removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [self.hairlines removeAllObjects];
    NSInteger n = 0;
    for (id it in albums) {
        if (n >= 3) break;   // 目标图一屏三列；完整列表在「打开音乐库」里
        if (![it isKindOfClass:[NSDictionary class]]) continue;
        NSString *key = [it[@"k"] isKindOfClass:[NSString class]] ? it[@"k"] : nil;
        if (!key.length) continue;
        // /api/lib/albums 的专辑名字段是 name（al 是队列 metas 里的字段，别混）
        NSString *name = [it[@"name"] isKindOfClass:[NSString class]] ? it[@"name"] : RLPTr(@"未知专辑");
        [self.albumRow addArrangedSubview:[self albumCellWithKey:key name:name index:n]];
        ++n;
    }
    // 固定三列：缺的列补空视图，保证列宽不随专辑数跳动（与目标图一致）
    while (n > 0 && n < 3) {
        NSView *pad = [[NSView alloc] initWithFrame:NSZeroRect];
        pad.translatesAutoresizingMaskIntoConstraints = NO;
        [self.albumRow addArrangedSubview:pad];
        ++n;
    }
    if (n == 0) {
        NSTextField *e = [self trackedLabel:RLPTr(@"还没有专辑 · 先添加音乐目录") font:t.small role:1];
        e.identifier = @"room.album.empty";
        [self.albumRow addArrangedSubview:e];
    }
}

#pragma mark - ④ 音乐文件夹（右上入口；沿用既有导航与既有 /api/lib/* 动作，不新造后端）

/// 右上「音乐文件夹」：卡片式弹层。目标图把旧页面的"音乐库卡"收进了这个入口 ——
/// 功能一个没删（文件夹页 / 添加目录 / 重新扫描 / 更多都在），只是不再占页面版面。
- (void)onOpenMusicFolder:(id)sender {
    RLPTheme *t = [RLPTheme current];
    NSStackView *s = [self popStackWithTitle:RLPTr(@"音乐文件夹")
        note:RLPTr(@"浏览曲库目录、添加音乐目录或重新扫描；流媒体等入口在「更多」里。")];

    NSButton *browse = [NSButton buttonWithTitle:RLPTr(@"文件夹") target:self action:@selector(onOpenFolders:)];
    browse.bezelStyle = NSBezelStyleRounded;
    browse.identifier = @"room.musicfolder.browse";
    browse.translatesAutoresizingMaskIntoConstraints = NO;
    [s addArrangedSubview:browse];
    [[browse.widthAnchor constraintEqualToConstant:330] setActive:YES];

    self.libDesc = RLPLabel(@"", t.small, t.mut);
    self.libDesc.maximumNumberOfLines = 2;
    self.libDesc.lineBreakMode = NSLineBreakByWordWrapping;
    self.libDesc.preferredMaxLayoutWidth = 330;
    self.libDesc.translatesAutoresizingMaskIntoConstraints = NO;
    [s addArrangedSubview:self.libDesc];
    [[self.libDesc.widthAnchor constraintEqualToConstant:330] setActive:YES];

    self.libButton = [NSButton buttonWithTitle:(self.hasRoots ? RLPTr(@"重新扫描音乐库") : RLPTr(@"添加音乐目录"))
                                        target:self action:@selector(onLibraryAction:)];
    self.libButton.bezelStyle = NSBezelStyleRounded;
    self.libButton.identifier = @"room.musicfolder.library";
    self.libButton.translatesAutoresizingMaskIntoConstraints = NO;
    [s addArrangedSubview:self.libButton];
    [[self.libButton.widthAnchor constraintEqualToConstant:190] setActive:YES];

    NSButton *more = [NSButton buttonWithTitle:RLPTr(@"更多") target:self action:@selector(onOpenMore:)];
    more.bezelStyle = NSBezelStyleRounded;
    more.translatesAutoresizingMaskIntoConstraints = NO;
    [s addArrangedSubview:more];
    [[more.widthAnchor constraintEqualToConstant:120] setActive:YES];

    // 文案与当前曲库状态一致（根目录数量来自 /api/lib/roots）
    self.libDesc.stringValue = self.hasRoots
        ? RLPTr(@"音乐目录已就绪 · 可重新扫描更新专辑与封面")
        : RLPTr(@"支持 FLAC · DSD (DSF/DFF) · ALAC · WAV · APE");
    [self showPopoverFrom:self.musicFolderButton withCard:s width:360 minH:220];
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
    for (NSArray *o in opts) {
        NSButton *b = [self popRowWithTitle:o[1] note:o[2] on:NO action:@selector(onPickPlayMode:) ident:[o[0] stringValue]];
        [s addArrangedSubview:b];
        [[b.widthAnchor constraintEqualToConstant:330] setActive:YES];
        NSTextField *sub = RLPLabel(o[2], [RLPTheme current].small, [RLPTheme current].mut);
        sub.maximumNumberOfLines = 0;
        sub.lineBreakMode = NSLineBreakByWordWrapping;
        sub.preferredMaxLayoutWidth = 330;
        [s addArrangedSubview:sub];
        [[sub.widthAnchor constraintEqualToConstant:330] setActive:YES];
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

- (void)onPickPlayMode:(NSButton *)sender {
    const RLPPlayMode3 mode = (RLPPlayMode3)sender.identifier.integerValue;
    NSString *profile = RLPProfileForPlayMode(mode, RLPPathIsDsd(self.currentPath));
    [self.popover close];
    self.playValue.stringValue = (mode == RLPPlayMode3Direct ? RLPTr(@"原音直通")
                                 : mode == RLPPlayMode3Pcm ? RLPTr(@"PCM 升频") : RLPTr(@"DSD 升频"));
    self.presetNotes.hidden = NO;
    self.presetNotes.stringValue = RLPTr(@"正在应用…");
    NSString *path = [NSString stringWithFormat:@"/api/preset/apply?profile=%@", RLPEnc(profile)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:path body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            // notes 是后端给的决策说明（含降级原因），照实显示，不自己编"已优化"。
            NSArray *notes = [json[@"notes"] isKindOfClass:[NSArray class]] ? json[@"notes"] : @[];
            self_.presetNotes.hidden = NO;
            self_.presetNotes.stringValue = notes.count ? [notes componentsJoinedByString:@"；"] : RLPTr(@"已应用");
            RLPToast(RLPTr(@"已应用"));
            [self_ reloadSettings];
        } else {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"应用失败");
            self_.presetNotes.hidden = NO;
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
    [self showPopoverFrom:self.musicFolderButton withCard:s width:360 minH:150];
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

/// 设备大字值被点：弹出真实设备菜单（/api/devices），选完走既有 /api/settings 写回。
/// 不用 NSPopUpButton 的默认外观：目标图卡面是"大字 + chevron"，popup 的蓝灰胶囊会破坏版式。
- (void)onDeviceMenu:(id)sender {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:RLPTr(@"当前设备")];
    NSString *cur = [self str:@"device" def:@""];
    NSString *defName = nil;
    for (NSDictionary *d in self.devices)
        if ([d[@"default"] boolValue]) {
            defName = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : nil;
            break;
        }
    NSString *defTitle = defName.length
        ? [NSString stringWithFormat:@"%@（%@）", RLPTr(@"系统默认"), defName] : RLPTr(@"系统默认");
    NSMenuItem *defItem = [menu addItemWithTitle:defTitle action:@selector(onPickDevice:) keyEquivalent:@""];
    defItem.target = self;
    defItem.representedObject = @"";
    defItem.state = cur.length ? NSControlStateValueOff : NSControlStateValueOn;
    for (NSDictionary *d in self.devices) {
        NSString *did = [d[@"id"] isKindOfClass:[NSString class]] ? d[@"id"] : @"";
        NSString *nm = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : RLPTr(@"未知设备");
        NSMenuItem *it = [menu addItemWithTitle:nm action:@selector(onPickDevice:) keyEquivalent:@""];
        it.target = self;
        it.representedObject = did;
        it.state = [cur isEqualToString:did] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    if (!self.devices.count) {
        NSMenuItem *none = [menu addItemWithTitle:RLPTr(@"读取中…") action:nil keyEquivalent:@""];
        none.enabled = NO;
    }
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSMaxY(self.deviceValue.bounds))
                            inView:self.deviceValue];
}

- (void)onPickDevice:(NSMenuItem *)sender {
    NSString *devId = [sender.representedObject isKindOfClass:[NSString class]]
        ? (NSString *)sender.representedObject : @"";
    [self postSettings:@{@"device": devId}];
}

- (void)onReloadDevices:(id)sender { [self reloadDevices]; RLPToast(RLPTr(@"已重新检测设备")); }

#pragma mark 收藏（/api/fav，与专辑页、单曲页同一端点）

- (void)updateFavButton {
    RLPTheme *t = [RLPTheme current];
    NSString *title = self.npFavOn ? RLPTr(@"已收藏") : RLPTr(@"收藏");
    [self.npFav setTitle:title];
    self.npFav.image = [NSImage imageWithSystemSymbolName:(self.npFavOn ? @"heart.fill" : @"heart")
                                  accessibilityDescription:title];
    self.npFav.contentTintColor = self.npFavOn ? t.accent : nil;
    self.npFav.enabled = (self.currentPath.length > 0);
}

/// 收藏态回读：/api/fav/list?meta=1 里有没有当前曲目（不在 UI 里私存一份收藏表）。
- (void)reloadFavState {
    NSString *path = self.currentPath ?: @"";
    if (!path.length) {
        self.npFavOn = NO;
        [self updateFavButton];
        return;
    }
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/fav/list?meta=1" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (![path isEqualToString:self_.currentPath ?: @""]) return;   // 过期回调不动新状态
        NSArray *files = [json[@"files"] isKindOfClass:[NSArray class]] ? json[@"files"] : @[];
        BOOL on = NO;
        for (id it in files) {
            NSString *p = nil;
            if ([it isKindOfClass:[NSDictionary class]]) p = it[@"path"];
            else if ([it isKindOfClass:[NSString class]]) p = it;
            if ([p isEqualToString:path]) { on = YES; break; }
        }
        self_.npFavOn = on;
        [self_ updateFavButton];
    }];
}

- (void)onFav:(id)sender {
    if (!self.currentPath.length) { RLPToast(RLPTr(@"没有正在播放的曲目")); return; }
    const BOOL nextOn = !self.npFavOn;
    NSString *url = [NSString stringWithFormat:@"/api/fav?file=%@&on=%d",
                     RLPEnc(self.currentPath), nextOn ? 1 : 0];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:url body:@"" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            self_.npFavOn = nextOn;
            [self_ updateFavButton];
            RLPToast(nextOn ? RLPTr(@"已收藏") : RLPTr(@"已取消收藏"));
        } else {
            RLPToast(nextOn ? RLPTr(@"收藏失败") : RLPTr(@"取消收藏失败"));
        }
    }];
}

- (void)onOpenNowPlaying:(id)sender {- (void)onOpenNowPlaying:(id)sender {
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
/// 「音乐文件夹」里的浏览入口：走既有文件夹页（不新造路由）。
- (void)onOpenFolders:(id)sender {
    [self.popover close];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPNavigateKeyNotification" object:@"folders"];
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
        [self_ refreshDeviceSummary];
    }];
}

/// 设备大字值 ← /api/devices + /api/settings.device（唯一真相源；UI 不写死任何设备名）。
/// 规则：device 非空 ⟹ 找同 id 的设备名；device 为空 ⟹ /api/devices 里 default=1 的设备名；
/// 名单还没到 ⟹ 「系统默认」（选择语义，不是设备名）。
- (void)refreshDeviceSummary {
    NSString *cur = [self str:@"device" def:@""];
    NSString *name = nil;
    if (cur.length) {
        for (NSDictionary *d in self.devices) {
            NSString *did = [d[@"id"] isKindOfClass:[NSString class]] ? d[@"id"] : nil;
            if ([did isEqualToString:cur]) {
                name = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : nil;
                break;
            }
        }
    } else {
        for (NSDictionary *d in self.devices) {
            if ([d[@"default"] boolValue]) {
                name = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : nil;
                break;
            }
        }
    }
    [self.deviceValue setTitle:(name.length ? name : RLPTr(@"系统默认"))];
}

- (void)reloadSettings {
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/settings" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        // ⚠️ /api/settings 的值在 **kv** 子对象里（与设置页同一口径）。
        // 直接读顶层会全部取不到 ⟹ 静默回落默认值，界面显示与真实设置脱节。
        self_.settings = [json[@"kv"] isKindOfClass:[NSDictionary class]] ? json[@"kv"] : @{};
        [self_ refreshDeviceSummary];
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
        // 听音风格回显：大字是档位人话，滤波真名只作 tooltip（目标图卡面只有一行大字）
        NSString *f = [self_ str:@"filter" def:@""];
        NSInteger st = RLPToneStyleForFilter(f, self_.filters);
        self_.styleValue.stringValue = (st >= 0) ? RLPToneStyleName((RLPToneStyle)st) : RLPTr(@"自定义");
        self_.styleValue.toolTip = f.length ? f : RLPTr(@"跟随默认");
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
        self_.styleValue.toolTip = f.length ? f : RLPTr(@"跟随默认");
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
        NSString *path = st.currentPath ?: @"";
        // 目标图的状态标签是「播放中」；未播放/暂停如实显示，不用假绿点冒充在播。
        self_.npState.stringValue = path.length ? (self_.playing ? RLPTr(@"播放中") : RLPTr(@"已暂停"))
                                                : RLPTr(@"未播放");
        self_.npState.textColor = self_.playing ? [RLPTheme current].ok : [RLPTheme current].mut;
        if (!path.length) {
            self_.npFavOn = NO;
            [self_ updateFavButton];
        }
        if (![path isEqualToString:self_.currentPath ?: @""]) {
            self_.currentPath = path;
            self_.npTitle.stringValue = path.length ? path.lastPathComponent.stringByDeletingPathExtension : RLPTr(@"还没有在播放的音乐");
            self_.npSub.stringValue = path.length ? @"" : RLPTr(@"从下面的专辑挑一张开始");
            [self_ loadCoverForPath:path];
            [self_ loadMetaForPath:path];
            [self_ reloadFavState];
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
        // 目标图副标题是「艺术家 · 专辑」（不是专辑 · 艺术家）
        NSMutableArray *p = [NSMutableArray array];
        if (artist.length) [p addObject:artist];
        if (album.length) [p addObject:album];
        self_.npSub.stringValue = [p componentsJoinedByString:@" · "];
    }];
}

- (void)reloadQueue {
    __weak __typeof__(self) weakSelf = self;
    // 队列契约：GET /api/queue?meta=1 → {items:[路径…], metas:[{t,a,al,d}…], index}
    // （键是 items，不是 queue；读错键会永远显示"队列是空的"）
    [[RLPCoreClient shared] getJSON:@"/api/queue?meta=1" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *items = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[];
        NSArray *metas = [json[@"metas"] isKindOfClass:[NSArray class]] ? json[@"metas"] : @[];
        // index 是"当前在播的第几首"（0 基）。缺这个键就当作没有当前行，不臆造高亮。
        NSInteger idx = [json[@"index"] isKindOfClass:[NSNumber class]] ? [json[@"index"] integerValue] : -1;
        [self_ renderQueueWithItems:items metas:metas index:idx];
    }];
}

- (void)reloadAlbums {
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/lib/albums" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *albs = [json[@"albums"] isKindOfClass:[NSArray class]] ? json[@"albums"] : @[];
        [self_ renderAlbums:albs];
    }];
}

- (void)onAlbumClicked:(NSButton *)sender { RLPRequestOpenAlbum(sender.identifier); }

#pragma mark - 主题

/// 运行时建出来的标签登记进来：主题切换时静态清单够不着它们。
/// role: 0=正文 1=次要文字 2=警示 3=强调（当前播放行）
- (NSTextField *)trackedLabel:(NSString *)text font:(NSFont *)font role:(NSInteger)role {
    RLPTheme *t = [RLPTheme current];
    NSColor *c = (role == 1) ? t.mut : (role == 2 ? t.warn : (role == 3 ? t.ok : t.text));
    NSTextField *l = RLPLabel(text, font, c);
    l.tag = role;
    if (!self.dynamicLabels) self.dynamicLabels = [NSMutableArray array];
    [self.dynamicLabels addObject:l];
    return l;
}

/// 递归重刷带圆角/边框的图层：卡片底色、封面占位底色、细线。
/// 为什么递归：专辑封面在 cell 里（stack → cell → image），静态两层遍历够不到。
- (void)tintLayersInView:(NSView *)v cardBg:(NSColor *)cardBg coverBg:(NSColor *)coverBg line:(NSColor *)line {
    for (NSView *s in v.subviews) {
        if (s.wantsLayer && s.layer.cornerRadius > 0) {
            const BOOL isCover = [s.identifier hasPrefix:@"room.albumcover"] ||
                                 [s.identifier isEqualToString:@"room.np.cover"];
            s.layer.backgroundColor = (isCover ? coverBg : cardBg).CGColor;
            if (s.layer.borderWidth > 0) s.layer.borderColor = line.CGColor;
        }
        [self tintLayersInView:s cardBg:cardBg coverBg:coverBg line:line];
    }
}

- (void)applyTheme {
    [super applyTheme];
    RLPTheme *t = [RLPTheme current];
    [self tintLayersInView:self.stack
                    cardBg:(t.isLight ? t.bg2 : t.card)
                   coverBg:t.bg3
                      line:t.line];
    self.heroTitle.textColor = t.hero;
    self.npCover.layer.backgroundColor = t.bg3.CGColor;
    if (self.libDesc) self.libDesc.textColor = t.mut;
    self.presetNotes.textColor = t.mut;
    self.npState.textColor = self.playing ? t.ok : t.mut;
    self.npSub.textColor = t.mut;
    self.npTitle.textColor = t.text;
    self.outputValue.textColor = t.text;
    self.playValue.textColor = t.text;
    self.styleValue.textColor = t.text;
    self.deviceValue.contentTintColor = t.text;
    for (NSImageView *iv in self.chevrons) iv.contentTintColor = t.mut;
    // 卡片小标题 / 分区标题（之前漏刷：浅色主题下它们仍是深色主题的灰，几乎看不见）
    for (NSTextField *l in @[ self.deviceCaption, self.outputCaption, self.playCaption, self.styleCaption ])
        l.textColor = t.mut;
    self.queueCaption.textColor = t.text;
    self.albumCaption.textColor = t.text;
    for (NSView *line in self.hairlines) {
        line.wantsLayer = YES;
        line.layer.backgroundColor = t.hairline.CGColor;
    }
    // 动态行（队列预览 / 专辑名 / 空态）：运行时建出来的，静态清单里没有它们。
    // 角色记在 NSView.tag 上（0=正文 1=次要 2=警示 3=强调），不另存第二套状态。
    for (NSTextField *l in self.dynamicLabels) {
        l.textColor = (l.tag == 1) ? t.mut : (l.tag == 2 ? t.warn : (l.tag == 3 ? t.ok : t.text));
    }
}
@end

@end

