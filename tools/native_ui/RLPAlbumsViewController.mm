// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPAlbumsViewController.mm — 专辑网格（纯 AppKit / NSCollectionView）
//
// 数据与封面全部走进程内 /api（RLPCoreClient），不复制曲库真相；
// 封面异步加载且做 key 校验（item 复用时不把 A 的图贴到 B 上）；
// 双击专辑 = 播放整张（/api/lib/play?k=…），单击只选中。
#import "RLPAlbumsViewController.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

static const NSUserInterfaceItemIdentifier kAlbumItemID = @"RLPAlbumItem";

#pragma mark - 卡片视图（承载 tracking area）

// tracking area 属于 NSView。NSCollectionViewItem 是控制器，收不到 mouseEntered，
// 所以用一个视图子类把悬停事件转回 item。
@class RLPAlbumItem;
@interface RLPAlbumCardView : NSView
@property (nonatomic, weak) RLPAlbumItem *item;
@end



#pragma mark - 专辑卡片

@interface RLPAlbumItem : NSCollectionViewItem
@property (nonatomic, strong) NSImageView *coverView;
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSTextField *artistLabel;
@property (nonatomic, strong) NSTextField *placeholderLabel;
@property (nonatomic, copy) NSString *albumKey;
/// 悬停时浮起的红色圆形播放键（web .card .cv .pl 同款：右下角 32px 圆、默认隐藏）
@property (nonatomic, strong) NSButton *playBadge;
/// 点播放键时回调（控制器注入；item 不该直接持有控制器）
@property (nonatomic, copy, nullable) void (^onPlayRequested)(NSString *albumKey);
- (void)applyTheme;
- (void)cardHoverChanged:(BOOL)on;
@end

@implementation RLPAlbumCardView {
    NSTrackingArea *_area;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_area) { [self removeTrackingArea:_area]; _area = nil; }
    _area = [[NSTrackingArea alloc] initWithRect:self.bounds
                                        options:(NSTrackingMouseEnteredAndExited |
                                                 NSTrackingActiveInKeyWindow |
                                                 NSTrackingInVisibleRect)
                                          owner:self userInfo:nil];
    [self addTrackingArea:_area];
}
- (void)mouseEntered:(NSEvent *)e { (void)e; [self.item cardHoverChanged:YES]; }
- (void)mouseExited:(NSEvent *)e { (void)e; [self.item cardHoverChanged:NO]; }
@end

@implementation RLPAlbumItem {
    BOOL _hovered;
}

- (void)loadView {
    RLPTheme *t = [RLPTheme current];
    RLPAlbumCardView *v = [[RLPAlbumCardView alloc] initWithFrame:NSMakeRect(0, 0, 168, 214)];
    v.item = self;
    v.wantsLayer = YES;
    v.layer.masksToBounds = NO;   // 阴影要能画到卡片外
    self.view = v;

    _coverView = [[RLPCoverImageView alloc] initWithFrame:NSZeroRect];
    _coverView.wantsLayer = YES;
    _coverView.layer.cornerRadius = 9;
    _coverView.layer.masksToBounds = YES;
    _coverView.layer.borderWidth = 1;
    _coverView.layer.borderColor = t.hairline.CGColor;
    _coverView.imageScaling = NSImageScaleProportionallyUpOrDown;
    _coverView.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_coverView];

    _placeholderLabel = [NSTextField labelWithString:@"♪"];
    _placeholderLabel.font = [NSFont systemFontOfSize:30 weight:NSFontWeightLight];
    _placeholderLabel.textColor = t.mut;
    _placeholderLabel.alignment = NSTextAlignmentCenter;
    _placeholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_placeholderLabel];

    _nameLabel = [NSTextField labelWithString:@""];
    _nameLabel.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold];
    _nameLabel.textColor = t.text;
    _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _nameLabel.maximumNumberOfLines = 1;
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_nameLabel];

    _artistLabel = [NSTextField labelWithString:@""];
    _artistLabel.font = [NSFont systemFontOfSize:11];
    _artistLabel.textColor = t.mut;
    _artistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _artistLabel.maximumNumberOfLines = 1;
    _artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_artistLabel];

    // 悬停浮起的红色圆形播放键（web .card .cv .pl：32px 圆、右下 7px、默认 opacity:0）
    _playBadge = [[NSButton alloc] initWithFrame:NSZeroRect];
    _playBadge.bordered = NO;
    _playBadge.imagePosition = NSImageOnly;
    _playBadge.imageScaling = NSImageScaleProportionallyDown;
    _playBadge.image = [NSImage imageWithSystemSymbolName:@"play.fill" accessibilityDescription:RLPTr(@"播放整张")];
    _playBadge.contentTintColor = NSColor.whiteColor;
    _playBadge.toolTip = RLPTr(@"播放整张");
    _playBadge.target = self;
    _playBadge.action = @selector(onPlayBadge:);
    _playBadge.identifier = @"album.playbadge";   // 运行时判据：悬停才可见
    _playBadge.wantsLayer = YES;
    _playBadge.layer.cornerRadius = 16;
    _playBadge.layer.backgroundColor = t.accent.CGColor;
    _playBadge.hidden = YES;
    _playBadge.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_playBadge];

    [NSLayoutConstraint activateConstraints:@[
        [_coverView.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [_coverView.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [_coverView.topAnchor constraintEqualToAnchor:v.topAnchor],
        // web .card .cv{aspect-ratio:1}：封面必须是正方形；旧实现写死 180 高 + 每列宽不一
        // ⟹ 方图被压进非正方形容器里 letterbox，用户实测「封面都留白边」。
        [_coverView.heightAnchor constraintEqualToAnchor:_coverView.widthAnchor],
        [_placeholderLabel.centerXAnchor constraintEqualToAnchor:_coverView.centerXAnchor],
        [_placeholderLabel.centerYAnchor constraintEqualToAnchor:_coverView.centerYAnchor],
        [_playBadge.trailingAnchor constraintEqualToAnchor:_coverView.trailingAnchor constant:-8],
        [_playBadge.bottomAnchor constraintEqualToAnchor:_coverView.bottomAnchor constant:-8],
        [_playBadge.widthAnchor constraintEqualToConstant:32],
        [_playBadge.heightAnchor constraintEqualToConstant:32],
        [_nameLabel.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:2],
        [_nameLabel.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-2],
        [_nameLabel.topAnchor constraintEqualToAnchor:_coverView.bottomAnchor constant:9],
        [_artistLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_artistLabel.trailingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor],
        [_artistLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],
    ]];
}

- (void)setAlbum:(RLPAlbum *)album cover:(NSImage *)cover {
    RLPTheme *t = [RLPTheme current];
    self.albumKey = album.key;
    self.nameLabel.stringValue = album.name.length ? album.name : RLPTr(@"未知专辑");
    // 副标题与 web 一致：艺术家 · 年份 · 采样率/位深（缺的段不拼空串）
    NSMutableArray<NSString *> *sub = [NSMutableArray array];
    if (album.artist.length) [sub addObject:album.artist];
    if (album.year > 0) [sub addObject:[NSString stringWithFormat:@"%ld", (long)album.year]];
    if (album.sampleRate > 0) {
        NSString *sr = (album.sampleRate % 1000 == 0)
            ? [NSString stringWithFormat:@"%ldk", (long)(album.sampleRate / 1000)]
            : [NSString stringWithFormat:@"%.1fk", album.sampleRate / 1000.0];
        [sub addObject:(album.bits > 0 ? [NSString stringWithFormat:@"%@/%ld", sr, (long)album.bits] : sr)];
    }
    self.artistLabel.stringValue = sub.count ? [sub componentsJoinedByString:@" · "] : RLPTr(@"未知艺术家");
    self.coverView.image = cover;
    self.coverView.layer.backgroundColor = t.bg2.CGColor;
    self.placeholderLabel.hidden = (cover != nil);
    self.placeholderLabel.stringValue = album.name.length ? [album.name substringToIndex:1] : @"♪";
    [self applyTheme];
}

// 卡片自己也要能换肤：NSCollectionView 复用 item，切主题时不重刷就会留着旧色文字。
- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.nameLabel.textColor = t.text;
    self.artistLabel.textColor = t.mut;
    self.placeholderLabel.textColor = t.mut;
    self.coverView.layer.backgroundColor = t.bg2.CGColor;
    [self refreshHighlight];
}

// 悬停/选中时给封面加一圈强调边 + 轻微阴影（web 版 .card:hover 的观感）。
// 只改 layer 属性，不重建视图 —— 网格上百张卡，重建会卡。
// NSCollectionViewItem 没有 highlighted 属性，所以悬停自己用 tracking area 管。
- (void)refreshHighlight {
    RLPTheme *t = [RLPTheme current];
    const BOOL on = _hovered || self.selected;
    self.coverView.layer.borderWidth = on ? 2.0 : 0.0;
    self.coverView.layer.borderColor = on ? t.accent.CGColor : NSColor.clearColor.CGColor;
    self.view.layer.shadowOpacity = on ? 0.16 : 0.0;
    self.view.layer.shadowRadius = on ? 7 : 0;
    self.view.layer.shadowOffset = CGSizeMake(0, -2);
    self.view.layer.shadowColor = NSColor.blackColor.CGColor;
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    [self refreshHighlight];
}

- (void)cardHoverChanged:(BOOL)on {
    _hovered = on;
    self.playBadge.hidden = !on;   // 悬停才浮现（web 的 opacity 过渡等效）
    [self refreshHighlight];
}

/// 点卡片上的播放键 = 播放整张（不经过详情页）。
- (void)onPlayBadge:(id)sender {
    (void)sender;
    if (self.albumKey.length && self.onPlayRequested) self.onPlayRequested(self.albumKey);
}

@end

#pragma mark - 专辑网格

@interface RLPAlbumsViewController () <NSCollectionViewDataSource, NSCollectionViewDelegate>
@property (nonatomic, copy, readwrite) NSString *pageTitle;
@property (nonatomic, strong) NSCollectionView *collection;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *countLabel;
@property (nonatomic, strong) NSMutableArray<RLPAlbum *> *albums;
@property (nonatomic, strong) NSCache<NSString *, NSImage *> *coverCache;
/// 当前生效的过滤词（空 = 整库）。reload 一律按它发请求，避免「清空后仍是过滤结果」。
@property (nonatomic, copy) NSString *query;
/// 请求世代：连续打字/清空时只允许最新一次响应落地（否则旧响应会把新结果覆盖掉）。
@property (nonatomic, assign) NSUInteger reloadSeq;
@property (nonatomic, assign) BOOL hasLoaded;
@property (nonatomic, copy) NSArray *lastRoots;
// 专辑页空态（web emptyStateHtml 的非 classic 分支）：只在曲库 0 张专辑时出现。
@property (nonatomic, strong) NSView *emptyCard;
@property (nonatomic, strong) NSTextField *emptyTitleLabel;
@property (nonatomic, strong) NSTextField *emptyHintLabel;
@property (nonatomic, strong) NSTextField *emptyRootLabel;
@property (nonatomic, strong) NSButton *emptyAddBtn;
@property (nonatomic, strong) NSButton *emptyScanBtn;
@property (nonatomic, strong) NSButton *emptyStationBtn;
@end

@implementation RLPAlbumsViewController {
    CGFloat _lastLayoutWidth;
    BOOL _relayouting;
}

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _pageTitle = RLPTr(@"专辑");
        _albums = [NSMutableArray array];
        _coverCache = [[NSCache alloc] init];
        _coverCache.countLimit = 400;
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSInteger)albumCount { return (NSInteger)self.albums.count; }

- (void)loadView {
    RLPTheme *t = [RLPTheme current];
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 674, 520)];
    root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    root.wantsLayer = YES;
    root.layer.backgroundColor = t.bg.CGColor;
    self.view = root;

    self.titleLabel = [NSTextField labelWithString:RLPTr(@"专辑")];
    self.titleLabel.font = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
    self.titleLabel.textColor = t.text;
    [self.titleLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                             forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    // 标题与计数统一由主窗口顶栏承载（web #pth/#cnt 同口径），页内不再画。
    self.titleLabel.hidden = YES;
    [root addSubview:self.titleLabel];
    NSTextField *title = self.titleLabel;

    self.countLabel = [NSTextField labelWithString:@"—"];
    self.countLabel.font = t.small;
    self.countLabel.textColor = t.mut;
    self.countLabel.alignment = NSTextAlignmentRight;
    [self.countLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                             forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.countLabel.hidden = YES;   // 计数走顶栏 RLPPageCountNotification
    [root addSubview:self.countLabel];

    // web .grid：repeat(auto-fill, minmax(152px,1fr)) / gap:16 / padding:18。
    // 之前原生写死 180×230 + inset 20/24 + lineSpacing 20，卡片比 web 宽、行距也更大。
    // 现在按可用宽度算列数（与 CSS auto-fill 同算法），列宽随之拉伸填满。
    NSCollectionViewFlowLayout *layout = [[NSCollectionViewFlowLayout alloc] init];
    layout.itemSize = NSMakeSize(152, 191);      // 152 封面 + 9 + 15(标题) + 2 + 13(艺术家) = 191
    layout.sectionInset = NSEdgeInsetsMake(18, 18, 18, 18);   // .grid padding:18
    layout.minimumInteritemSpacing = 16;         // .grid gap:16
    layout.minimumLineSpacing = 16;

    self.collection = [[NSCollectionView alloc] initWithFrame:NSMakeRect(0, 0, 674, 520)];
    self.collection.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.collection.collectionViewLayout = layout;
    self.collection.dataSource = self;
    self.collection.delegate = self;
    self.collection.selectable = YES;
    self.collection.allowsMultipleSelection = NO;
    self.collection.backgroundColors = @[NSColor.clearColor];
    [self.collection registerClass:[RLPAlbumItem class] forItemWithIdentifier:kAlbumItemID];

    // 与 web 版同语义：**点专辑 = 进详情页**（不是直接播放）。
    // 之前双击直接调 onPlayAlbum，导致专辑详情页永远进不去 —— 这是本轮修的核心故障。
    // 单击进详情；双击也进详情（用户习惯双击打开，不该变成播放）。
    NSClickGestureRecognizer *single = [[NSClickGestureRecognizer alloc] initWithTarget:self
                                                                                action:@selector(onOpenItem:)];
    single.numberOfClicksRequired = 1;
    [self.collection addGestureRecognizer:single];

    // 右键菜单：想直接播放/入队的人走这里，不占用主点击语义
    NSMenu *itemMenu = [[NSMenu alloc] init];
    [itemMenu addItemWithTitle:RLPTr(@"打开") action:@selector(onMenuOpen:) keyEquivalent:@""];
    [itemMenu addItemWithTitle:RLPTr(@"播放整张") action:@selector(onMenuPlay:) keyEquivalent:@""];
    [itemMenu addItemWithTitle:RLPTr(@"加入队列") action:@selector(onMenuEnqueue:) keyEquivalent:@""];
    for (NSMenuItem *mi in itemMenu.itemArray) mi.target = self;
    self.collection.menu = itemMenu;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.documentView = self.collection;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:scroll];
    if (scroll.contentView) {
        scroll.contentView.postsFrameChangedNotifications = YES;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(clipViewFrameDidChange:)
                                                     name:NSViewFrameDidChangeNotification
                                                   object:scroll.contentView];
    }

    // ---- 空态卡（web .empty-guide-card）：0 张专辑时盖在网格区上方，说明 + 三个入口 ----
    self.emptyCard = [[NSView alloc] initWithFrame:NSZeroRect];
    self.emptyCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyCard.wantsLayer = YES;
    self.emptyCard.layer.cornerRadius = 12;
    self.emptyCard.layer.borderWidth = 1;
    self.emptyCard.hidden = YES;
    [root addSubview:self.emptyCard];

    NSStackView *emptyStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    emptyStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    emptyStack.alignment = NSLayoutAttributeCenterX;
    emptyStack.spacing = 8;
    emptyStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.emptyCard addSubview:emptyStack];

    NSTextField *emoji = [NSTextField labelWithString:@"\U0001F3B5"];   // 🎵
    emoji.font = [NSFont systemFontOfSize:36];
    emoji.alignment = NSTextAlignmentCenter;
    [emptyStack addArrangedSubview:emoji];

    self.emptyTitleLabel = RLPLabel(RLPTr(@"还没有添加音乐目录"),
                                    [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold], t.text);
    self.emptyTitleLabel.alignment = NSTextAlignmentCenter;
    self.emptyTitleLabel.maximumNumberOfLines = 2;
    self.emptyTitleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [emptyStack addArrangedSubview:self.emptyTitleLabel];

    self.emptyHintLabel = RLPLabel(@"", [NSFont systemFontOfSize:12.5], t.mut2);
    self.emptyHintLabel.alignment = NSTextAlignmentCenter;
    self.emptyHintLabel.maximumNumberOfLines = 4;
    self.emptyHintLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [[self.emptyHintLabel.widthAnchor constraintEqualToConstant:460] setActive:YES];
    [emptyStack addArrangedSubview:self.emptyHintLabel];

    self.emptyRootLabel = RLPLabel(@"", [NSFont systemFontOfSize:11], t.mut2);
    self.emptyRootLabel.alignment = NSTextAlignmentCenter;
    self.emptyRootLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.emptyRootLabel.maximumNumberOfLines = 1;
    self.emptyRootLabel.hidden = YES;
    [emptyStack addArrangedSubview:self.emptyRootLabel];

    NSStackView *emptyRow = [[NSStackView alloc] initWithFrame:NSZeroRect];
    emptyRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    emptyRow.spacing = 12;
    emptyRow.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyAddBtn = [NSButton buttonWithTitle:RLPTr(@"添加音乐目录") target:self
                                         action:@selector(onEmptyAddRoot:)];
    self.emptyAddBtn.bezelStyle = NSBezelStyleRounded;
    self.emptyAddBtn.identifier = @"albums.emptyAdd";
    self.emptyAddBtn.keyEquivalent = @"\r";
    self.emptyScanBtn = [NSButton buttonWithTitle:RLPTr(@"扫描目录") target:self
                                           action:@selector(onEmptyScan:)];
    self.emptyScanBtn.bezelStyle = NSBezelStyleRounded;
    self.emptyScanBtn.identifier = @"albums.emptyScan";
    self.emptyStationBtn = [NSButton buttonWithTitle:RLPTr(@"打开快速开始") target:self
                                              action:@selector(onEmptyStation:)];
    self.emptyStationBtn.bezelStyle = NSBezelStyleRounded;
    self.emptyStationBtn.identifier = @"albums.emptyStation";
    [emptyRow addArrangedSubview:self.emptyAddBtn];
    [emptyRow addArrangedSubview:self.emptyScanBtn];
    [emptyRow addArrangedSubview:self.emptyStationBtn];
    [emptyStack addArrangedSubview:emptyRow];

    [NSLayoutConstraint activateConstraints:@[
        [self.emptyCard.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [self.emptyCard.topAnchor constraintEqualToAnchor:scroll.topAnchor constant:40],
        [self.emptyCard.widthAnchor constraintEqualToConstant:520],
        [emptyStack.leadingAnchor constraintEqualToAnchor:self.emptyCard.leadingAnchor constant:28],
        [emptyStack.trailingAnchor constraintEqualToAnchor:self.emptyCard.trailingAnchor constant:-28],
        [emptyStack.topAnchor constraintEqualToAnchor:self.emptyCard.topAnchor constant:32],
        [emptyStack.bottomAnchor constraintEqualToAnchor:self.emptyCard.bottomAnchor constant:-32],
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:24],
        [title.topAnchor constraintEqualToAnchor:root.topAnchor constant:18],
        [self.countLabel.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-24],
        [self.countLabel.firstBaselineAnchor constraintEqualToAnchor:title.firstBaselineAnchor],
        [self.countLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:title.trailingAnchor constant:12],

        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12],
        [scroll.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];
}

#pragma mark - 数据
#pragma mark - 空态（web emptyStateHtml 非 classic 分支）

- (void)onEmptyAddRoot:(id)sender {
    (void)sender;
    // web bEmptyAddRoot：openSettingsTab('adv') —— 目录管理在「通用」页。
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenSettingsPaneNotification" object:@"adv"];
}

- (void)onEmptyScan:(id)sender {
    (void)sender;
    // web bEmptyScan：触发顶栏 bScan（POST /api/lib/scan）。
    [[RLPCoreClient shared] postJSON:@"/api/lib/scan" body:@"" completion:nil];
    RLPToast(RLPTr(@"开始重新扫描"));
}

- (void)onEmptyStation:(id)sender {
    (void)sender;
    // web emptyGoStation：打开快速开始页（原生导航 key "station"）。
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPNavigateKeyNotification" object:@"station"];
}

/// 空态显隐：0 张专辑时卡片可见，网格滚动区隐藏（不留一块空网格底）。
- (void)setEmptyStateVisible:(BOOL)visible {
    self.emptyCard.hidden = !visible;
    self.collection.enclosingScrollView.hidden = visible;
    if (!visible) {
        const CGFloat w = [self effectiveGridWidth];
        if (w > 1.0) [self relayoutGridForWidth:w];
        [self.collection setNeedsLayout:YES];
        return;
    }
    if (self.query.length > 0) {
        self.emptyTitleLabel.stringValue = [NSString stringWithFormat:RLPTr(@"未找到与 “%@” 相关的专辑"), self.query];
        self.emptyHintLabel.stringValue = RLPTr(@"请尝试缩短搜索词，或检查是否有错别字");
        self.emptyRootLabel.stringValue = @"";
        self.emptyRootLabel.hidden = YES;
        self.emptyAddBtn.hidden = YES;
        self.emptyScanBtn.hidden = YES;
        self.emptyStationBtn.hidden = YES;
        return;
    }
    self.emptyAddBtn.hidden = NO;
    self.emptyScanBtn.hidden = NO;
    self.emptyStationBtn.hidden = NO;
    // 先用「无目录」默认文案，再拉 roots 决定「有目录但没歌」的变体（web S.roots 同源）。
    [self refreshEmptyStateWithRoots:@[]];
    __weak __typeof__(self) ws = self;
    [[RLPCoreClient shared] getJSON:@"/api/lib/stats" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) s = ws;
        if (!s) return;
        NSArray *roots = [json[@"roots"] isKindOfClass:[NSArray class]] ? json[@"roots"] : @[];
        [s refreshEmptyStateWithRoots:roots];
    }];
}

- (void)refreshEmptyStateWithRoots:(NSArray *)roots {
    self.lastRoots = roots ?: @[];
    NSString *rootPath = @"";
    for (id r in roots) {
        if ([r isKindOfClass:[NSString class]] && [(NSString *)r length]) { rootPath = r; break; }
    }
    const BOOL hasRoots = rootPath.length > 0;
    self.emptyTitleLabel.stringValue = hasRoots
        ? RLPTr(@"已添加音乐目录，但未找到音频文件")
        : RLPTr(@"还没有添加音乐目录");
    if (hasRoots) {
        self.emptyHintLabel.stringValue = RLPTr(@"当前目录中未发现可识别的音频文件，请确认音频格式或更换目录。");
        self.emptyRootLabel.stringValue = rootPath;
        self.emptyRootLabel.hidden = NO;
    } else {
        self.emptyHintLabel.stringValue = [NSString stringWithFormat:@"%@\n%@",
            RLPTr(@"RLPlayer 会自动为您建立高保真音乐库并整理专辑与元数据。"),
            RLPTr(@"支持 FLAC、DSD (DSF/DFF)、WAV、ALAC、CUE 分轨等格式。")];
        self.emptyRootLabel.stringValue = @"";
        self.emptyRootLabel.hidden = YES;
    }
    [self.emptyAddBtn setTitle:(hasRoots ? RLPTr(@"管理音乐目录") : RLPTr(@"添加音乐目录"))];
    [self.emptyScanBtn setTitle:(hasRoots ? RLPTr(@"重新扫描") : RLPTr(@"扫描目录"))];
}


/// 每次切到本页都重报一次计数（主窗口 sync 会先清空计数）。
- (void)activate {
    const CGFloat w = [self effectiveGridWidth];
    if (w > 1.0) [self relayoutGridForWidth:w];
    [self.view setNeedsLayout:YES];
    if (self.albums.count) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPPageCountNotification"
            object:[NSString stringWithFormat:RLPTr(@"%ld 张专辑"), (long)self.albums.count]];
    } else {
        [self reload];
    }
}

- (void)reload { [self reloadWithQuery:self.query ?: @""]; }

- (void)searchWithQuery:(NSString *)query { [self reloadWithQuery:query ?: @""]; }

/// web loadAlbums(q)：带 q 走服务端过滤（后端 /api/lib/albums?q= 按专辑名+艺术家匹配），
/// 不带 q 才是整库。旧原生的 reload 永远发裸路径 ⟹ 顶栏搜索在专辑页根本没有过滤能力。
- (void)reloadWithQuery:(NSString *)query {
    self.query = query ?: @"";
    if (![RLPCoreClient shared].started) {
        [self.albums removeAllObjects];
        self.countLabel.stringValue = RLPTr(@"核心未启动");
        [self.collection reloadData];
        return;
    }
    const NSUInteger seq = ++self.reloadSeq;
    NSString *path = self.query.length
        ? [NSString stringWithFormat:@"/api/lib/albums?q=%@", RLPEnc(self.query)]
        : @"/api/lib/albums";
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:path completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (self_.reloadSeq != seq) return;   // 已发出更新的查询，旧响应作废
        if (!json || ![json[@"ok"] boolValue]) {
            self_.countLabel.stringValue = RLPTr(@"加载失败");
            return;
        }
        NSArray<RLPAlbum *> *list = [RLPAlbum albumsFromJSON:json];
        self_.hasLoaded = YES;
        [self_.albums setArray:list];
        const CGFloat w = [self_ effectiveGridWidth];
        if (w > 1.0) [self_ relayoutGridForWidth:w];
        [self_.collection reloadData];
        NSString *cnt = [NSString stringWithFormat:RLPTr(@"%ld 张专辑"), (long)list.count];
        self_.countLabel.stringValue = cnt;
        [self_ setEmptyStateVisible:(list.count == 0)];
        if (self_.view.superview) {
            [self_.view setNeedsLayout:YES];
            if (!self_.collection.enclosingScrollView.hidden) {
                [self_.collection setNeedsLayout:YES];
            }
            [self_.view layoutSubtreeIfNeeded];
        }
        // 顶栏计数（web #cnt 同口径）：页加载完上报，主窗口显示在页标题旁。
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPPageCountNotification"
            object:cnt];
    }];
}

#pragma mark - NSCollectionViewDataSource

- (NSInteger)collectionView:(NSCollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)self.albums.count;
}

- (NSCollectionViewItem *)collectionView:(NSCollectionView *)collectionView
     itemForRepresentedObjectAtIndexPath:(NSIndexPath *)indexPath {
    RLPAlbumItem *item = (RLPAlbumItem *)[collectionView makeItemWithIdentifier:kAlbumItemID forIndexPath:indexPath];
    if (indexPath.item >= (NSInteger)self.albums.count) return item;
    RLPAlbum *album = self.albums[(NSUInteger)indexPath.item];
    item.onPlayRequested = self.onPlayAlbum;
    [item setAlbum:album cover:[self.coverCache objectForKey:album.key]];
    if (album.hasCover) [self loadCoverForAlbum:album atIndexPath:indexPath];
    return item;
}

- (void)loadCoverForAlbum:(RLPAlbum *)album atIndexPath:(NSIndexPath *)indexPath {
    if (album.key.length == 0) return;
    NSImage *cached = [self.coverCache objectForKey:album.key];
    if (cached) return;
    NSString *enc = [album.key stringByAddingPercentEncodingWithAllowedCharacters:
                     [NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *path = [NSString stringWithFormat:@"/api/lib/cover?k=%@", enc];
    NSUInteger expectedIndex = (NSUInteger)indexPath.item;
    NSString *expectedKey = album.key;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getData:path completion:^(NSData * _Nullable data) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || data.length == 0) return;
        // item 复用保护：回调回来时下标处必须仍是同一张专辑，否则丢弃
        if (expectedIndex >= self_.albums.count) return;
        if (![self_.albums[expectedIndex].key isEqualToString:expectedKey]) return;
        NSImage *img = [[NSImage alloc] initWithData:data];
        if (!img) return;
        [self_.coverCache setObject:img forKey:expectedKey];
        NSIndexPath *now = [NSIndexPath indexPathForItem:(NSInteger)expectedIndex inSection:0];
        NSCollectionViewItem *item = [self_.collection itemAtIndexPath:now];
        if ([item isKindOfClass:[RLPAlbumItem class]]) {
            RLPAlbumItem *ai = (RLPAlbumItem *)item;
            if ([ai.albumKey isEqualToString:expectedKey]) [ai setAlbum:self_.albums[expectedIndex] cover:img];
        }
    }];
}

#pragma mark - 双击播放

/// 命中测试：把点击位置换算成专辑；点空白处返回 nil。
- (RLPAlbum *)albumAtPoint:(NSPoint)p {
    NSIndexPath *ip = [self.collection indexPathForItemAtPoint:p];
    if (!ip || ip.item < 0 || ip.item >= (NSInteger)self.albums.count) return nil;
    return self.albums[(NSUInteger)ip.item];
}

- (void)onOpenItem:(NSClickGestureRecognizer *)g {
    RLPAlbum *album = [self albumAtPoint:[g locationInView:self.collection]];
    if (album.key.length) RLPRequestOpenAlbum(album.key);
}

/// 右键菜单的三项：以**右键那一行**为准（clickedItem 可能为空，回退到选中项）。
- (RLPAlbum *)menuItemAlbum {
    NSPoint p = [self.collection convertPoint:[self.collection.window mouseLocationOutsideOfEventStream]
                                    fromView:nil];
    RLPAlbum *a = [self albumAtPoint:p];
    if (a) return a;
    NSIndexPath *sel = self.collection.selectionIndexPaths.anyObject;
    if (sel && sel.item >= 0 && sel.item < (NSInteger)self.albums.count)
        return self.albums[(NSUInteger)sel.item];
    return nil;
}

- (void)onMenuOpen:(id)sender {
    RLPAlbum *a = [self menuItemAlbum];
    if (a.key.length) RLPRequestOpenAlbum(a.key);
}

- (void)onMenuPlay:(id)sender {
    RLPAlbum *a = [self menuItemAlbum];
    if (a.key.length) RLPPlayAlbum(a.key, 0);
}

// 换肤：根背景 + 标题 + 计数 + **所有已实例化的卡片**。
// 只刷 visibleItems 不够（滚动出去再回来会复用旧色 item），所以直接 reloadData。
/// 按可用宽度重算卡片尺寸 —— CSS repeat(auto-fill,minmax(152px,1fr)) 的等价算法：
/// 先算能放几列（列下限 152、间距 16），再把剩余宽度均分给各列（1fr）。
/// 不这么做的话卡片恒为 152 宽，右侧留一条空白，与 web 铺满的观感不一致。
- (CGFloat)effectiveGridWidth {
    NSScrollView *scroll = self.collection.enclosingScrollView;
    if (scroll && scroll.contentView && scroll.contentView.bounds.size.width > 1.0) {
        return scroll.contentView.bounds.size.width;
    }
    const CGFloat viewW = self.view.bounds.size.width;
    if (viewW > 1.0) return viewW;
    if (self.view.superview && self.view.superview.bounds.size.width > 1.0) {
        return self.view.superview.bounds.size.width;
    }
    return 0.0;
}

- (void)clipViewFrameDidChange:(NSNotification *)note {
    (void)note;
    if (_relayouting) return;
    NSScrollView *scroll = self.collection.enclosingScrollView;
    if (!scroll || scroll.hidden || !scroll.contentView) return;
    const CGFloat w = scroll.contentView.bounds.size.width;
    if (w <= 1.0) return;
    NSCollectionViewFlowLayout *l = [self.collection.collectionViewLayout isKindOfClass:[NSCollectionViewFlowLayout class]]
        ? (NSCollectionViewFlowLayout *)self.collection.collectionViewLayout : nil;
    const CGFloat avail = w - 36.0;
    NSInteger cols = (avail >= 152.0) ? (NSInteger)floor((avail + 16.0) / 168.0) : 1;
    if (cols < 1) cols = 1;
    const CGFloat expectedItemW = (avail >= 152.0) ? floor((avail - 16.0 * (cols - 1)) / cols) : 152.0;
    const BOOL needsUpdate = fabs(_lastLayoutWidth - w) >= 0.5 ||
                             fabs(self.collection.frame.size.width - w) >= 0.5 ||
                             (l && fabs(l.itemSize.width - expectedItemW) >= 0.5);
    if (!needsUpdate) return;
    _relayouting = YES;
    [self relayoutGridForWidth:w];
    [self.collection setNeedsLayout:YES];
    [self.view setNeedsLayout:YES];
    _relayouting = NO;
}

- (void)relayoutGridForWidth:(CGFloat)w {
    if (![self.collection.collectionViewLayout isKindOfClass:[NSCollectionViewFlowLayout class]]) return;
    NSCollectionViewFlowLayout *l = (NSCollectionViewFlowLayout *)self.collection.collectionViewLayout;
    const CGFloat pad = 18, gap = 16, minW = 152;
    const CGFloat avail = w - pad * 2;
    if (avail < minW) return;
    NSInteger cols = (NSInteger)floor((avail + gap) / (minW + gap));
    if (cols < 1) cols = 1;
    const CGFloat itemW = floor((avail - gap * (cols - 1)) / cols);
    const BOOL widthChanged = fabs(_lastLayoutWidth - w) >= 0.5;
    const BOOL itemChanged = fabs(l.itemSize.width - itemW) >= 0.5;
    const BOOL colWidthMismatch = fabs(self.collection.frame.size.width - w) >= 0.5;
    if (!widthChanged && !itemChanged && !colWidthMismatch) return;
    _lastLayoutWidth = w;
    // web：封面(正方形) + .nm margin-top 9 + 行高 15 + .ar margin-top 2 + 行高 13 = +39；
    // 行距 16 由 layout.minimumLineSpacing 负责。旧实现文字区写 62（行间距比 web 大 23pt）。
    l.itemSize = NSMakeSize(itemW, itemW + 39);
    if (colWidthMismatch) {
        NSRect cf = self.collection.frame;
        cf.size.width = w;
        self.collection.frame = cf;
    }
    [l invalidateLayout];
}

- (void)viewWillLayout {
    [super viewWillLayout];
    const CGFloat w = [self effectiveGridWidth];
    if (w > 1.0) [self relayoutGridForWidth:w];
}

- (void)viewDidLayout {
    [super viewDidLayout];
    if (_relayouting) return;
    _relayouting = YES;
    for (int pass = 0; pass < 2; ++pass) {
        const CGFloat w = [self effectiveGridWidth];
        if (w <= 1.0) break;
        NSCollectionViewFlowLayout *l = [self.collection.collectionViewLayout isKindOfClass:[NSCollectionViewFlowLayout class]]
            ? (NSCollectionViewFlowLayout *)self.collection.collectionViewLayout : nil;
        const CGFloat prevItemW = l ? l.itemSize.width : 0.0;
        const CGFloat prevColW = self.collection.frame.size.width;
        const CGFloat prevLastW = _lastLayoutWidth;
        [self relayoutGridForWidth:w];
        const BOOL changed = (l && fabs(l.itemSize.width - prevItemW) >= 0.5) ||
                             fabs(self.collection.frame.size.width - prevColW) >= 0.5 ||
                             fabs(_lastLayoutWidth - prevLastW) >= 0.5;
        NSScrollView *scroll = self.collection.enclosingScrollView;
        if (!scroll || scroll.hidden) break;
        if (changed || pass == 0) {
            [scroll layoutSubtreeIfNeeded];
        } else {
            break;
        }
        const CGFloat nextW = [self effectiveGridWidth];
        if (fabs(nextW - w) < 0.5) break;
    }
    _relayouting = NO;
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.view.layer.backgroundColor = t.bg.CGColor;
    self.titleLabel.textColor = t.text;
    self.countLabel.textColor = t.mut;
    self.collection.backgroundColors = @[ NSColor.clearColor ];
    [self.collection reloadData];
}

- (void)onMenuEnqueue:(id)sender {
    RLPAlbum *a = [self menuItemAlbum];
    if (!a.key.length || ![RLPCoreClient shared].started) return;
    NSString *url = [NSString stringWithFormat:@"/api/lib/enqueue?k=%@", RLPEnc(a.key)];
    [[RLPCoreClient shared] postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
        if (json && [json[@"ok"] boolValue]) RLPToast(RLPTr(@"整张专辑已加入队列"));
        else RLPToast([json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"加入失败"));
    }];
}

- (void)applyLanguage {
    self.pageTitle = RLPTr(@"专辑");
    if (!self.isViewLoaded) return;
    self.titleLabel.stringValue = RLPTr(@"专辑");
    NSArray<NSString *> *menuTitles = @[@"打开", @"播放整张", @"加入队列"];
    NSArray<NSMenuItem *> *menuItems = self.collection.menu.itemArray;
    for (NSUInteger i = 0; i < menuItems.count && i < menuTitles.count; ++i) {
        menuItems[i].title = RLPTr(menuTitles[i]);
    }
    self.emptyStationBtn.title = RLPTr(@"打开快速开始");
    if (!self.emptyCard.hidden) {
        if (self.query.length > 0) {
            self.emptyTitleLabel.stringValue = [NSString stringWithFormat:RLPTr(@"未找到与 “%@” 相关的专辑"), self.query];
            self.emptyHintLabel.stringValue = RLPTr(@"请尝试缩短搜索词，或检查是否有错别字");
        } else {
            [self refreshEmptyStateWithRoots:self.lastRoots ?: @[]];
        }
    }
    if (self.hasLoaded) {
        NSString *cnt = [NSString stringWithFormat:RLPTr(@"%ld 张专辑"), (long)self.albums.count];
        self.countLabel.stringValue = cnt;
        if (self.view.window) [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPPageCountNotification" object:cnt];
    }
    NSSet<NSIndexPath *> *sel = [self.collection.selectionIndexPaths copy];
    NSScrollView *scroll = self.collection.enclosingScrollView;
    NSPoint origin = scroll ? scroll.contentView.bounds.origin : NSZeroPoint;
    [self.collection reloadData];
    for (NSCollectionViewItem *it in self.collection.visibleItems) {
        if ([it isKindOfClass:[RLPAlbumItem class]]) {
            ((RLPAlbumItem *)it).playBadge.toolTip = RLPTr(@"播放整张");
        }
    }
    if (sel.count) self.collection.selectionIndexPaths = sel;
    if (scroll) {
        [scroll.contentView scrollToPoint:origin];
        [scroll reflectScrolledClipView:scroll.contentView];
    }
}

@end