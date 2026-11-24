// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPArtistsViewController.mm — 艺术家网格实现
//
#import "RLPArtistsViewController.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

static const NSUserInterfaceItemIdentifier kArtistItemID = @"RLPArtistItem";

/// 艺术家卡片尺寸与专辑卡同算法（web：.grid minmax(150px,1fr) + gap16 + padding18）。
/// 头像 = 列宽的正方形（再裁成圆），文字区 39pt；旧实现写死 168×196 / 116pt 小圆。
static const CGFloat kCardW = 168;
static const CGFloat kCardH = 214;

#pragma mark - 艺术家卡片

/// 卡片根视图：圆角半径跟着列宽走（web border-radius:50%），并带悬停高亮与指针反馈。
@class RLPArtistItem;
@interface RLPArtistCardView : NSView
@property (nonatomic, weak) RLPArtistItem *item;
@property (nonatomic, weak) NSView *avatarView;
@property (nonatomic, weak) NSView *coverView;
@property (nonatomic, strong) NSTrackingArea *hoverArea;
@end

@interface RLPArtistItem : NSCollectionViewItem
@property (nonatomic, strong) NSView *avatarView;
@property (nonatomic, strong) NSImageView *coverView;
@property (nonatomic, strong) NSTextField *initialLabel;
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSTextField *countLabel;
@property (nonatomic, copy) NSString *artistName;
@property (nonatomic, assign) NSInteger albumCount;
- (void)cardHoverChanged:(BOOL)hovered;
- (void)applyTheme;
@end

@implementation RLPArtistCardView
- (void)layout {
    [super layout];
    CGFloat side = self.avatarView ? NSWidth(self.avatarView.bounds) : NSWidth(self.bounds);
    if (side > 0) {
        self.avatarView.layer.cornerRadius = side / 2.0;
        self.coverView.layer.cornerRadius = side / 2.0;
    }
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_hoverArea) [self removeTrackingArea:_hoverArea];
    _hoverArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                              options:(NSTrackingMouseEnteredAndExited |
                                                       NSTrackingActiveAlways |
                                                       NSTrackingInVisibleRect)
                                                owner:self
                                             userInfo:nil];
    [self addTrackingArea:_hoverArea];
}
- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}
- (void)mouseEntered:(NSEvent *)event { (void)event; [self.item cardHoverChanged:YES]; }
- (void)mouseExited:(NSEvent *)event { (void)event; [self.item cardHoverChanged:NO]; }
@end

@implementation RLPArtistItem {
    BOOL _hovered;
}

/// 卡片尺寸：大圆头像（卡片内边距 6pt）+ 下方两行文字（姓名 + 专辑数 + 底部留白 = 46pt）。

- (void)loadView {
    RLPTheme *t = [RLPTheme current];
    RLPArtistCardView *v = [[RLPArtistCardView alloc] initWithFrame:NSMakeRect(0, 0, kCardW, kCardH)];
    v.item = self;
    v.wantsLayer = YES;
    v.layer.cornerRadius = 12.0;
    v.layer.backgroundColor = NSColor.clearColor.CGColor;
    self.view = v;

    // 圆形头像容器：留出 6pt 卡片内边距以承载悬停高亮背景（web .card padding:7px;border-radius:11px）
    _avatarView = [[NSView alloc] initWithFrame:NSZeroRect];
    _avatarView.wantsLayer = YES;
    _avatarView.layer.masksToBounds = YES;
    _avatarView.layer.backgroundColor = t.cvBg.CGColor;
    _avatarView.layer.borderWidth = 1.0;
    _avatarView.layer.borderColor = t.line.CGColor;
    _avatarView.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_avatarView];

    _initialLabel = [NSTextField labelWithString:@""];
    _initialLabel.font = [NSFont systemFontOfSize:40 weight:NSFontWeightMedium];
    _initialLabel.textColor = t.phText;
    _initialLabel.alignment = NSTextAlignmentCenter;
    _initialLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_avatarView addSubview:_initialLabel];

    // 真封面（/api/artist/image）盖在圆形占位上；没有封面时露出首字母（web 同层序）。
    _coverView = [[RLPCoverImageView alloc] initWithFrame:NSZeroRect];
    _coverView.imageScaling = NSImageScaleProportionallyUpOrDown;
    _coverView.wantsLayer = YES;
    _coverView.layer.masksToBounds = YES;
    _coverView.translatesAutoresizingMaskIntoConstraints = NO;
    [_avatarView addSubview:_coverView];

    _nameLabel = [NSTextField labelWithString:@""];
    _nameLabel.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold];
    _nameLabel.textColor = t.text;
    _nameLabel.alignment = NSTextAlignmentLeft;   // web .card .nm 默认左对齐
    _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _nameLabel.maximumNumberOfLines = 1;
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_nameLabel];

    _countLabel = [NSTextField labelWithString:@""];
    _countLabel.font = [NSFont systemFontOfSize:11];
    _countLabel.textColor = t.mut2;
    _countLabel.alignment = NSTextAlignmentLeft;
    _countLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _countLabel.maximumNumberOfLines = 1;
    _countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_countLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_avatarView.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:6],
        [_avatarView.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-6],
        [_avatarView.topAnchor constraintEqualToAnchor:v.topAnchor constant:6],
        [_avatarView.heightAnchor constraintEqualToAnchor:_avatarView.widthAnchor],
        [_coverView.leadingAnchor constraintEqualToAnchor:_avatarView.leadingAnchor],
        [_coverView.trailingAnchor constraintEqualToAnchor:_avatarView.trailingAnchor],
        [_coverView.topAnchor constraintEqualToAnchor:_avatarView.topAnchor],
        [_coverView.bottomAnchor constraintEqualToAnchor:_avatarView.bottomAnchor],
        [_initialLabel.centerXAnchor constraintEqualToAnchor:_avatarView.centerXAnchor],
        [_initialLabel.centerYAnchor constraintEqualToAnchor:_avatarView.centerYAnchor],
        [_nameLabel.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:6],
        [_nameLabel.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-6],
        [_nameLabel.topAnchor constraintEqualToAnchor:_avatarView.bottomAnchor constant:8],
        [_countLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_countLabel.trailingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor],
        [_countLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],
    ]];
    ((RLPArtistCardView *)v).avatarView = _avatarView;
    ((RLPArtistCardView *)v).coverView = _coverView;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    _hovered = NO;
    [self applyTheme];
}

- (void)cardHoverChanged:(BOOL)hovered {
    if (_hovered == hovered) return;
    _hovered = hovered;
    [self applyTheme];
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    [self applyTheme];
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    const BOOL on = _hovered || self.selected;
    self.view.layer.backgroundColor = self.selected ? t.accentWeak.CGColor
                                                    : (_hovered ? t.hov.CGColor : NSColor.clearColor.CGColor);
    _avatarView.layer.backgroundColor = t.cvBg.CGColor;
    _avatarView.layer.borderColor = (on ? t.accent : t.line).CGColor;
    _avatarView.layer.borderWidth = on ? 1.5 : 1.0;
    _initialLabel.textColor = t.phText;
    _nameLabel.textColor = on ? t.accent : t.text;
    _countLabel.textColor = t.mut2;
}

// 圆半径在 RLPArtistCardView -layout 里算（见上）。
- (void)setArtist:(RLPArtist *)artist {
    self.artistName = artist.name;
    self.albumCount = artist.albumCount;
    self.nameLabel.stringValue = artist.name;
    self.countLabel.stringValue = [NSString stringWithFormat:RLPTr(@"%ld 张专辑"), (long)artist.albumCount];
    self.initialLabel.stringValue = artist.name.length ? [artist.name substringToIndex:1].uppercaseString : @"?";
    self.coverView.image = nil;
    self.initialLabel.hidden = NO;
    _hovered = NO;
    [self applyTheme];
    // 三层降级与 web 同款：① /api/artist/image（真头像）→ ② /api/lib/cover（该艺术家第一张
    // 有封面专辑的图）→ ③ 首字母占位。
    if (!artist.name.length) return;
    NSString *who = artist.name;
    NSString *fallbackKey = artist.coverKey;
    NSString *url = [NSString stringWithFormat:@"/api/artist/image?who=%@", RLPEnc(who)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getData:url completion:^(NSData * _Nullable data) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        // 复用回来的 item 可能已被换给别的艺术家：名字不一致就丢弃。
        if (![self_.artistName isEqualToString:who]) return;
        NSImage *img = data.length ? [[NSImage alloc] initWithData:data] : nil;
        if (img) {
            self_.coverView.image = img;
            self_.initialLabel.hidden = YES;
            return;
        }
        if (!fallbackKey.length) return;
        NSString *coverURL = [NSString stringWithFormat:@"/api/lib/cover?k=%@", RLPEnc(fallbackKey)];
        [[RLPCoreClient shared] getData:coverURL completion:^(NSData * _Nullable cdata) {
            __typeof__(self) self_ = weakSelf;
            if (!self_ || cdata.length == 0) return;
            if (![self_.artistName isEqualToString:who]) return;
            NSImage *cimg = [[NSImage alloc] initWithData:cdata];
            if (cimg) { self_.coverView.image = cimg; self_.initialLabel.hidden = YES; }
        }];
    }];
}

@end

#pragma mark - 艺术家网格

@interface RLPArtistsViewController () <NSCollectionViewDataSource, NSCollectionViewDelegate>
@property (nonatomic, strong) NSTextField *artistsTitleLabel;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSCollectionView *collection;
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, strong) NSTextField *countLabel;
@property (nonatomic, strong) NSView *emptyCard;
@property (nonatomic, strong) NSTextField *emptyTitleLabel;
@property (nonatomic, strong) NSButton *emptyClearBtn;
@property (nonatomic, strong) NSMutableArray<RLPArtist *> *allArtists;
@property (nonatomic, strong) NSMutableArray<RLPArtist *> *filteredArtists;
@property (nonatomic, assign) BOOL hasLoaded;
@property (nonatomic, assign) BOOL lastLoadFailed;
@property (nonatomic, assign) NSUInteger reloadSeq;
@end

@implementation RLPArtistsViewController {
    CGFloat _lastLayoutWidth;
    BOOL _relayouting;
}

- (instancetype)init {
    self = [super initWithTitle:RLPTr(@"艺术家")];
    if (self) {
        _allArtists = [NSMutableArray array];
        _filteredArtists = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)usesPageHeaderSpacing { return NO; }

- (void)buildContent {
    RLPTheme *t = [RLPTheme current];
    NSView *container = self.contentView ?: self.view;

    // 标题、搜索、计数统一由主窗口顶栏承载（web #pth/#cnt/#q 同口径），页内隐藏但保留属性以兼容既有检索接口。
    self.artistsTitleLabel = [NSTextField labelWithString:RLPTr(@"艺术家")];
    self.artistsTitleLabel.font = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
    self.artistsTitleLabel.textColor = t.text;
    self.artistsTitleLabel.hidden = YES;
    self.artistsTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:self.artistsTitleLabel];

    self.searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    self.searchField.placeholderString = RLPTr(@"搜索艺术家...");
    self.searchField.target = self;
    self.searchField.action = @selector(onSearch:);
    self.searchField.hidden = YES;
    self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:self.searchField];

    self.countLabel = [NSTextField labelWithString:@""];
    self.countLabel.font = t.small;
    self.countLabel.textColor = t.mut;
    self.countLabel.hidden = YES;
    self.countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:self.countLabel];

    NSCollectionViewFlowLayout *layout = [[NSCollectionViewFlowLayout alloc] init];
    // web：`.grid{grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:16px;padding:18px}`
    // 头像 = 列宽正方形 + 文字区 46；列数随可用宽度重算（clipViewFrameDidChange / viewDidLayout）。
    layout.itemSize = NSMakeSize(150, 196);
    layout.sectionInset = NSEdgeInsetsMake(18, 18, 18, 18);
    layout.minimumInteritemSpacing = 16;
    layout.minimumLineSpacing = 16;

    self.collection = [[NSCollectionView alloc] initWithFrame:NSMakeRect(0, 0, 674, 520)];
    self.collection.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.collection.collectionViewLayout = layout;
    self.collection.dataSource = self;
    self.collection.delegate = self;
    self.collection.selectable = YES;
    self.collection.allowsMultipleSelection = NO;
    self.collection.backgroundColors = @[NSColor.clearColor];
    [self.collection registerClass:[RLPArtistItem class] forItemWithIdentifier:kArtistItemID];

    // 与 web 版同语义：**单击**进艺术家详情（web 的卡片 onclick 就是单击）。
    NSClickGestureRecognizer *dbl = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(onDoubleClick:)];
    dbl.numberOfClicksRequired = 1;
    [self.collection addGestureRecognizer:dbl];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSNoBorder;
    scroll.documentView = self.collection;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:scroll];
    self.scrollView = scroll;
    if (scroll.contentView) {
        scroll.contentView.postsFrameChangedNotifications = YES;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(clipViewFrameDidChange:)
                                                     name:NSViewFrameDidChangeNotification
                                                   object:scroll.contentView];
    }

    // ---- 空态卡 ----
    self.emptyCard = [[NSView alloc] initWithFrame:NSZeroRect];
    self.emptyCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyCard.wantsLayer = YES;
    self.emptyCard.layer.cornerRadius = 12;
    self.emptyCard.layer.borderWidth = 1;
    self.emptyCard.layer.borderColor = t.line.CGColor;
    self.emptyCard.layer.backgroundColor = t.bg2.CGColor;
    self.emptyCard.hidden = YES;
    [container addSubview:self.emptyCard];

    NSStackView *emptyStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    emptyStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    emptyStack.alignment = NSLayoutAttributeCenterX;
    emptyStack.spacing = 10;
    emptyStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.emptyCard addSubview:emptyStack];

    self.emptyTitleLabel = RLPLabel(RLPTr(@"曲库为空"),
                                    [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], t.text);
    self.emptyTitleLabel.alignment = NSTextAlignmentCenter;
    self.emptyTitleLabel.maximumNumberOfLines = 2;
    self.emptyTitleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [emptyStack addArrangedSubview:self.emptyTitleLabel];

    self.emptyClearBtn = [NSButton buttonWithTitle:RLPTr(@"清空搜索词") target:self action:@selector(onClearSearch:)];
    self.emptyClearBtn.bezelStyle = NSBezelStyleRounded;
    self.emptyClearBtn.hidden = YES;
    [emptyStack addArrangedSubview:self.emptyClearBtn];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:container.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [self.emptyCard.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [self.emptyCard.topAnchor constraintEqualToAnchor:container.topAnchor constant:44],
        [self.emptyCard.widthAnchor constraintLessThanOrEqualToConstant:440],
        [emptyStack.leadingAnchor constraintEqualToAnchor:self.emptyCard.leadingAnchor constant:28],
        [emptyStack.trailingAnchor constraintEqualToAnchor:self.emptyCard.trailingAnchor constant:-28],
        [emptyStack.topAnchor constraintEqualToAnchor:self.emptyCard.topAnchor constant:24],
        [emptyStack.bottomAnchor constraintEqualToAnchor:self.emptyCard.bottomAnchor constant:-24],
    ]];
}

- (CGFloat)effectiveGridWidth {
    if (self.scrollView && self.scrollView.contentView &&
        self.scrollView.contentView.bounds.size.width > 1.0) {
        return self.scrollView.contentView.bounds.size.width;
    }
    const CGFloat viewW = NSWidth(self.view.bounds);
    if (viewW > 1.0) return viewW;
    if (self.view.superview && NSWidth(self.view.superview.bounds) > 1.0) {
        return NSWidth(self.view.superview.bounds);
    }
    return 0.0;
}

- (void)clipViewFrameDidChange:(NSNotification *)note {
    (void)note;
    if (_relayouting) return;
    NSScrollView *scroll = self.scrollView ?: self.collection.enclosingScrollView;
    if (!scroll || scroll.hidden || !scroll.contentView) return;
    const CGFloat w = scroll.contentView.bounds.size.width;
    if (w <= 1.0) return;
    NSCollectionViewFlowLayout *l = [self.collection.collectionViewLayout isKindOfClass:[NSCollectionViewFlowLayout class]]
        ? (NSCollectionViewFlowLayout *)self.collection.collectionViewLayout : nil;
    const CGFloat avail = MAX(80.0, w - 36.0);
    const CGFloat minW = 150.0, gap = 16.0;
    NSInteger cols = (avail >= minW) ? (NSInteger)floor((avail + gap) / (minW + gap)) : 1;
    if (cols < 1) cols = 1;
    const CGFloat expectedItemW = (avail >= minW) ? floor((avail - gap * (cols - 1)) / cols) : floor(avail);
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

/// CSS repeat(auto-fill,minmax(150px,1fr)) 的等价算法（与专辑页同款，列下限 150）。
- (void)applyTheme {
    // 视图未加载时直接返回：测试会在未加载状态下调用，触发 loadView 会破坏离线判据。
    if (!self.isViewLoaded) return;
    RLPTheme *t = [RLPTheme current];
    self.view.wantsLayer = YES;
    self.view.layer.backgroundColor = t.bg.CGColor;
    self.artistsTitleLabel.textColor = t.text;
    self.countLabel.textColor = t.mut;
    if (self.emptyCard) {
        self.emptyCard.layer.borderColor = t.line.CGColor;
        self.emptyCard.layer.backgroundColor = t.bg2.CGColor;
    }
    if (self.emptyTitleLabel) self.emptyTitleLabel.textColor = t.text;
    NSSet<NSIndexPath *> *sel = [self.collection.selectionIndexPaths copy];
    NSScrollView *scroll = self.scrollView ?: self.collection.enclosingScrollView;
    NSPoint origin = scroll ? scroll.contentView.bounds.origin : NSZeroPoint;
    [self.collection reloadData];
    if (sel.count) self.collection.selectionIndexPaths = sel;
    if (scroll) {
        [scroll.contentView scrollToPoint:origin];
        [scroll reflectScrolledClipView:scroll.contentView];
    }
}

- (void)relayoutGridForWidth:(CGFloat)w {
    if (w <= 1.0 || ![self.collection.collectionViewLayout isKindOfClass:[NSCollectionViewFlowLayout class]]) return;
    NSCollectionViewFlowLayout *l = (NSCollectionViewFlowLayout *)self.collection.collectionViewLayout;
    const CGFloat pad = 18.0, gap = 16.0, minW = 150.0;
    const CGFloat avail = MAX(80.0, w - pad * 2.0);
    NSInteger cols = (avail >= minW) ? (NSInteger)floor((avail + gap) / (minW + gap)) : 1;
    if (cols < 1) cols = 1;
    const CGFloat itemW = (avail >= minW) ? floor((avail - gap * (cols - 1)) / cols) : floor(avail);
    const CGFloat itemH = itemW + 46.0;
    const BOOL widthChanged = fabs(_lastLayoutWidth - w) >= 0.5;
    const BOOL itemChanged = fabs(l.itemSize.width - itemW) >= 0.5 || fabs(l.itemSize.height - itemH) >= 0.5;
    const BOOL colWidthMismatch = fabs(self.collection.frame.size.width - w) >= 0.5;
    if (!widthChanged && !itemChanged && !colWidthMismatch) return;
    _lastLayoutWidth = w;
    l.itemSize = NSMakeSize(itemW, itemH);
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
        NSScrollView *scroll = self.scrollView ?: self.collection.enclosingScrollView;
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

- (void)activate {
    const CGFloat w = [self effectiveGridWidth];
    if (w > 1.0) [self relayoutGridForWidth:w];
    [self.view setNeedsLayout:YES];
    if (self.hasLoaded) {
        [self updateFilter];
    } else {
        [self reloadData];
    }
}

- (void)reloadData {
    if (![RLPCoreClient shared].started) {
        self.lastLoadFailed = NO;
        self.hasLoaded = NO;
        self.countLabel.stringValue = RLPTr(@"核心未启动");
        [self.allArtists removeAllObjects];
        [self.filteredArtists removeAllObjects];
        if (self.emptyCard) self.emptyCard.hidden = YES;
        [self.collection reloadData];
        return;
    }

    self.lastLoadFailed = NO;
    const NSUInteger seq = ++self.reloadSeq;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/lib/albums" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.reloadSeq) return;
        if (!json || ![json[@"ok"] boolValue]) {
            self_.lastLoadFailed = YES;
            self_.countLabel.stringValue = RLPTr(@"读取失败");
            RLPToast(RLPTr(@"读取失败"));
            return;
        }
        NSArray<RLPAlbum *> *albums = [RLPAlbum albumsFromJSON:json];
        NSArray<RLPArtist *> *artists = [RLPArtist artistsFromAlbums:albums];
        self_.lastLoadFailed = NO;
        self_.hasLoaded = YES;
        
        [self_.allArtists setArray:[artists sortedArrayUsingComparator:^NSComparisonResult(RLPArtist *a, RLPArtist *b) {
            return [a.name localizedCaseInsensitiveCompare:b.name];
        }]];
        
        [self_ updateFilter];
    }];
}

- (void)updateFilter {
    NSString *query = self.searchField.stringValue ?: @"";
    [self.filteredArtists removeAllObjects];
    if (query.length == 0) {
        [self.filteredArtists addObjectsFromArray:self.allArtists];
    } else {
        for (RLPArtist *a in self.allArtists) {
            if ([a.name localizedCaseInsensitiveContainsString:query]) {
                [self.filteredArtists addObject:a];
            }
        }
    }
    
    NSString *cnt = nil;
    if (self.filteredArtists.count == 0) {
        cnt = (query.length > 0 && self.allArtists.count > 0)
            ? [NSString stringWithFormat:RLPTr(@"%ld 位艺术家"), 0L]
            : RLPTr(@"曲库为空");
        self.countLabel.stringValue = cnt;
    } else {
        cnt = [NSString stringWithFormat:RLPTr(@"%ld 位艺术家"), (long)self.filteredArtists.count];
        self.countLabel.stringValue = cnt;
    }
    if (self.hasLoaded && self.filteredArtists.count == 0) {
        self.emptyCard.hidden = NO;
        if (query.length > 0) {
            self.emptyTitleLabel.stringValue = [NSString stringWithFormat:@"%@%@%@",
                RLPTr(@"未找到与 “"), query, RLPTr(@"” 相关的艺术家")];
            self.emptyClearBtn.hidden = NO;
        } else {
            self.emptyTitleLabel.stringValue = RLPTr(@"曲库为空");
            self.emptyClearBtn.hidden = YES;
        }
    } else if (self.emptyCard) {
        self.emptyCard.hidden = YES;
    }
    [self relayoutGridForWidth:[self effectiveGridWidth]];
    [self.collection reloadData];
    if (self.hasLoaded && cnt.length && self.view.window) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPPageCountNotification" object:cnt];
    }
}

- (void)onClearSearch:(id)sender {
    (void)sender;
    [self searchWithQuery:@""];
}

- (void)onSearch:(NSSearchField *)sender {
    (void)sender;
    [self updateFilter];
}

- (void)searchWithQuery:(NSString *)query {
    self.searchField.stringValue = query ?: @"";
    [self updateFilter];
}

- (void)onDoubleClick:(NSClickGestureRecognizer *)g {
    NSPoint p = [g locationInView:self.collection];
    NSIndexPath *ip = [self.collection indexPathForItemAtPoint:p];
    if (!ip || ip.item >= (NSInteger)self.filteredArtists.count) return;
    RLPArtist *a = self.filteredArtists[(NSUInteger)ip.item];
    RLPRequestOpenArtist(a.name);
}

- (NSInteger)collectionView:(NSCollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)self.filteredArtists.count;
}

- (NSCollectionViewItem *)collectionView:(NSCollectionView *)collectionView itemForRepresentedObjectAtIndexPath:(NSIndexPath *)indexPath {
    RLPArtistItem *item = (RLPArtistItem *)[collectionView makeItemWithIdentifier:kArtistItemID forIndexPath:indexPath];
    if (indexPath.item < (NSInteger)self.filteredArtists.count) {
        [item setArtist:self.filteredArtists[(NSUInteger)indexPath.item]];
    }
    return item;
}

- (void)applyLanguage {
    self.pageTitle = RLPTr(@"艺术家");
    if (!self.isViewLoaded) return;
    self.artistsTitleLabel.stringValue = RLPTr(@"艺术家");
    self.searchField.placeholderString = RLPTr(@"搜索艺术家...");
    if (self.emptyClearBtn) self.emptyClearBtn.title = RLPTr(@"清空搜索词");
    NSSet<NSIndexPath *> *sel = [self.collection.selectionIndexPaths copy];
    NSScrollView *scroll = self.scrollView ?: self.collection.enclosingScrollView;
    NSPoint origin = scroll ? scroll.contentView.bounds.origin : NSZeroPoint;
    if (self.hasLoaded) {
        [self updateFilter];
    } else if (self.lastLoadFailed) {
        self.countLabel.stringValue = RLPTr(@"读取失败");
        if (self.emptyTitleLabel && !self.emptyCard.hidden) {
            self.emptyTitleLabel.stringValue = RLPTr(@"读取失败");
        }
        [self.collection reloadData];
    } else if (![RLPCoreClient shared].started && self.countLabel.stringValue.length) {
        self.countLabel.stringValue = RLPTr(@"核心未启动");
        if (self.emptyTitleLabel && !self.emptyCard.hidden) {
            self.emptyTitleLabel.stringValue = RLPTr(@"曲库为空");
        }
        [self.collection reloadData];
    } else {
        if (self.emptyTitleLabel && !self.emptyCard.hidden) {
            self.emptyTitleLabel.stringValue = RLPTr(@"曲库为空");
        }
        [self.collection reloadData];
    }
    if (sel.count) self.collection.selectionIndexPaths = sel;
    if (scroll) {
        [scroll.contentView scrollToPoint:origin];
        [scroll reflectScrolledClipView:scroll.contentView];
    }
}

@end