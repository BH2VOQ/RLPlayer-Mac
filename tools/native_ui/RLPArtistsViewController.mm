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
static const CGFloat kCardH = 207;
static const CGFloat kAvatar = 168;

#pragma mark - 艺术家卡片

/// 卡片根视图：圆角半径要跟着列宽走（web border-radius:50%），
/// 放在 NSView 的 -layout 里做（NSCollectionViewItem 本身没有 layout 回调）。
@interface RLPArtistCardView : NSView
@property (nonatomic, weak) NSView *avatarView;
@property (nonatomic, weak) NSView *coverView;
@end
@implementation RLPArtistCardView
- (void)layout {
    [super layout];
    CGFloat side = NSWidth(self.bounds);
    if (side > 0) {
        self.avatarView.layer.cornerRadius = side / 2.0;
        self.coverView.layer.cornerRadius = side / 2.0;
    }
}
@end

@interface RLPArtistItem : NSCollectionViewItem
@property (nonatomic, strong) NSView *avatarView;
@property (nonatomic, strong) NSImageView *coverView;
@property (nonatomic, strong) NSTextField *initialLabel;
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSTextField *countLabel;
@property (nonatomic, copy) NSString *artistName;
@end

@implementation RLPArtistItem

/// 卡片尺寸：图一（web 艺术家页）= 大圆头像 + 下方两行文字。
/// 头像 116pt 圆形、整卡 168×196；原来 48pt 小头像挤在左侧一行里，
/// 与 web 观感差太远（用户实测「希望是图一的效果」）。

- (void)loadView {
    RLPTheme *t = [RLPTheme current];
    RLPArtistCardView *v = [[RLPArtistCardView alloc] initWithFrame:NSMakeRect(0, 0, kCardW, kCardH)];
    v.wantsLayer = YES;
    self.view = v;

    // 圆形头像容器：宽度 = 卡片列宽（web .card .cv{aspect-ratio:1;border-radius:50%}），
    // 不用固定 116 —— 旧实现头像比列宽小一圈，五列之间空隙明显，用户实测「不如 web 好看」。
    _avatarView = [[NSView alloc] initWithFrame:NSZeroRect];
    _avatarView.wantsLayer = YES;
    _avatarView.layer.masksToBounds = YES;
    _avatarView.layer.backgroundColor = t.bg2.CGColor;
    _avatarView.layer.borderWidth = 1;
    _avatarView.layer.borderColor = t.hairline.CGColor;
    _avatarView.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_avatarView];

    _initialLabel = [NSTextField labelWithString:@""];
    _initialLabel.font = [NSFont systemFontOfSize:40 weight:NSFontWeightMedium];
    _initialLabel.textColor = t.mut;
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
    _countLabel.textColor = t.mut;
    _countLabel.alignment = NSTextAlignmentLeft;
    _countLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _countLabel.maximumNumberOfLines = 1;
    _countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_countLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_avatarView.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [_avatarView.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [_avatarView.topAnchor constraintEqualToAnchor:v.topAnchor],
        [_avatarView.heightAnchor constraintEqualToAnchor:_avatarView.widthAnchor],
        [_coverView.leadingAnchor constraintEqualToAnchor:_avatarView.leadingAnchor],
        [_coverView.trailingAnchor constraintEqualToAnchor:_avatarView.trailingAnchor],
        [_coverView.topAnchor constraintEqualToAnchor:_avatarView.topAnchor],
        [_coverView.bottomAnchor constraintEqualToAnchor:_avatarView.bottomAnchor],
        [_initialLabel.centerXAnchor constraintEqualToAnchor:_avatarView.centerXAnchor],
        [_initialLabel.centerYAnchor constraintEqualToAnchor:_avatarView.centerYAnchor],
        [_nameLabel.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [_nameLabel.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [_nameLabel.topAnchor constraintEqualToAnchor:_avatarView.bottomAnchor constant:9],
        [_countLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_countLabel.trailingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor],
        [_countLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],
    ]];
    ((RLPArtistCardView *)v).avatarView = _avatarView;
    ((RLPArtistCardView *)v).coverView = _coverView;
}

// 圆半径在 RLPArtistCardView -layout 里算（见上）。
- (void)setArtist:(RLPArtist *)artist {
    self.artistName = artist.name;
    self.nameLabel.stringValue = artist.name;
    self.countLabel.stringValue = [NSString stringWithFormat:RLPTr(@"%ld 张专辑"), (long)artist.albumCount];
    self.initialLabel.stringValue = artist.name.length ? [artist.name substringToIndex:1].uppercaseString : @"?";
    self.coverView.image = nil;
    self.initialLabel.hidden = NO;
    // 三层降级与 web 同款：① /api/artist/image（真头像）→ ② /api/lib/cover（该艺术家第一张
    // 有封面专辑的图）→ ③ 首字母占位。旧原生只做①，真实库里大量艺人永远停在首字母圆，
    // 这正是用户截图里「澤 / D / K」那些灰圆与 web 观感的差距。
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
@property (nonatomic, strong) NSCollectionView *collection;
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, strong) NSTextField *countLabel;
@property (nonatomic, strong) NSMutableArray<RLPArtist *> *allArtists;
@property (nonatomic, strong) NSMutableArray<RLPArtist *> *filteredArtists;
@end

@implementation RLPArtistsViewController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _allArtists = [NSMutableArray array];
        _filteredArtists = [NSMutableArray array];
    }
    return self;
}

- (void)buildContent {
    RLPTheme *t = [RLPTheme current];
    NSView *root = self.view;
    root.wantsLayer = YES;
    root.layer.backgroundColor = t.bg.CGColor;

    NSTextField *title = [NSTextField labelWithString:RLPTr(@"艺术家")];
    title.font = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
    title.textColor = t.text;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:title];

    self.searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    self.searchField.placeholderString = RLPTr(@"搜索艺术家...");
    self.searchField.target = self;
    self.searchField.action = @selector(onSearch:);
    self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:self.searchField];

    self.countLabel = [NSTextField labelWithString:@""];
    self.countLabel.font = t.small;
    self.countLabel.textColor = t.mut;
    self.countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:self.countLabel];

    NSCollectionViewFlowLayout *layout = [[NSCollectionViewFlowLayout alloc] init];
    // web：`.grid{grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:16px;padding:18px}`
    // 头像 = 列宽正方形 + 文字区 39；列数随窗口宽度重算（viewDidLayout → relayout）。
    layout.itemSize = NSMakeSize(150, 189);
    layout.sectionInset = NSEdgeInsetsMake(18, 18, 18, 18);
    layout.minimumInteritemSpacing = 16;
    layout.minimumLineSpacing = 16;

    self.collection = [[NSCollectionView alloc] initWithFrame:NSZeroRect];
    self.collection.collectionViewLayout = layout;
    self.collection.dataSource = self;
    self.collection.delegate = self;
    self.collection.selectable = YES;
    [self.collection registerClass:[RLPArtistItem class] forItemWithIdentifier:kArtistItemID];

    // 与 web 版同语义：**单击**进艺术家详情（web 的卡片 onclick 就是单击）。
    // 原来要双击，用户点一下没反应会以为坏了。
    NSClickGestureRecognizer *dbl = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(onDoubleClick:)];
    dbl.numberOfClicksRequired = 1;
    [self.collection addGestureRecognizer:dbl];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.documentView = self.collection;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:scroll];

    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:24],
        [title.topAnchor constraintEqualToAnchor:root.topAnchor constant:18],
        [self.searchField.leadingAnchor constraintEqualToAnchor:title.trailingAnchor constant:24],
        [self.searchField.widthAnchor constraintEqualToConstant:260],
        [self.searchField.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [self.countLabel.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-24],
        [self.countLabel.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12],
        [scroll.bottomAnchor constraintEqualToAnchor:root.bottomAnchor]
    ]];
}

/// CSS repeat(auto-fill,minmax(150px,1fr)) 的等价算法（与专辑页同款，列下限 150）。
- (void)relayoutGridForWidth:(CGFloat)w {
    if (![self.collection.collectionViewLayout isKindOfClass:[NSCollectionViewFlowLayout class]]) return;
    NSCollectionViewFlowLayout *l = (NSCollectionViewFlowLayout *)self.collection.collectionViewLayout;
    const CGFloat pad = 18, gap = 16, minW = 150;
    const CGFloat avail = w - pad * 2;
    if (avail < minW) return;
    NSInteger cols = (NSInteger)floor((avail + gap) / (minW + gap));
    if (cols < 1) cols = 1;
    const CGFloat itemW = floor((avail - gap * (cols - 1)) / cols);
    if (fabs(l.itemSize.width - itemW) < 0.5) return;
    l.itemSize = NSMakeSize(itemW, itemW + 39);
    [l invalidateLayout];
}

- (void)viewDidLayout {
    [super viewDidLayout];
    [self relayoutGridForWidth:self.view.bounds.size.width];
}

- (void)reloadData {
    if (![RLPCoreClient shared].started) {
        self.countLabel.stringValue = RLPTr(@"核心未启动");
        [self.allArtists removeAllObjects];
        [self.filteredArtists removeAllObjects];
        [self.collection reloadData];
        return;
    }

    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/lib/albums" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            RLPToast(RLPTr(@"读取失败"));
            return;
        }
        NSArray<RLPAlbum *> *albums = [RLPAlbum albumsFromJSON:json];
        NSArray<RLPArtist *> *artists = [RLPArtist artistsFromAlbums:albums];
        
        [self_.allArtists setArray:[artists sortedArrayUsingComparator:^NSComparisonResult(RLPArtist *a, RLPArtist *b) {
            return [a.name localizedCaseInsensitiveCompare:b.name];
        }]];
        
        [self_ updateFilter];
    }];
}

- (void)updateFilter {
    NSString *query = self.searchField.stringValue;
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
    
    if (self.filteredArtists.count == 0) {
        self.countLabel.stringValue = RLPTr(@"曲库为空");
    } else {
        self.countLabel.stringValue = [NSString stringWithFormat:RLPTr(@"%ld 位艺术家"), (long)self.filteredArtists.count];
    }
    [self.collection reloadData];
}

- (void)onSearch:(NSSearchField *)sender {
    (void)sender;
    [self updateFilter];
}

- (void)searchWithQuery:(NSString *)query {
    self.searchField.stringValue = query;
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

@end