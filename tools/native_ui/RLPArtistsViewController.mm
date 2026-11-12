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

/// 艺术家卡片尺寸（图一：大圆头像 + 下方名称/专辑数）。
static const CGFloat kCardW = 168;
static const CGFloat kCardH = 196;
static const CGFloat kAvatar = 116;


#pragma mark - 艺术家卡片

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
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kCardW, kCardH)];
    v.wantsLayer = YES;
    self.view = v;

    const CGFloat ax = (kCardW - kAvatar) / 2.0;
    _avatarView = [[NSView alloc] initWithFrame:NSMakeRect(ax, kCardH - kAvatar - 8, kAvatar, kAvatar)];
    _avatarView.wantsLayer = YES;
    _avatarView.layer.cornerRadius = kAvatar / 2.0;
    _avatarView.layer.masksToBounds = YES;
    _avatarView.layer.backgroundColor = t.bg2.CGColor;
    _avatarView.layer.borderWidth = 1;
    _avatarView.layer.borderColor = t.hairline.CGColor;
    [v addSubview:_avatarView];

    // 真封面（/api/artist/cover）盖在圆形占位上；没有封面时露出首字母。
    _coverView = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, kAvatar, kAvatar)];
    _coverView.imageScaling = NSImageScaleProportionallyUpOrDown;
    _coverView.wantsLayer = YES;
    _coverView.layer.cornerRadius = kAvatar / 2.0;
    _coverView.layer.masksToBounds = YES;
    [_avatarView addSubview:_coverView];

    _initialLabel = [NSTextField labelWithString:@""];
    _initialLabel.font = [NSFont systemFontOfSize:40 weight:NSFontWeightMedium];
    _initialLabel.textColor = t.mut;
    _initialLabel.alignment = NSTextAlignmentCenter;
    _initialLabel.frame = NSMakeRect(0, (kAvatar - 44) / 2.0, kAvatar, 44);
    [_avatarView addSubview:_initialLabel];

    _nameLabel = [NSTextField labelWithString:@""];
    _nameLabel.font = [NSFont systemFontOfSize:13.5 weight:NSFontWeightSemibold];
    _nameLabel.textColor = t.text;
    _nameLabel.alignment = NSTextAlignmentCenter;
    _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _nameLabel.frame = NSMakeRect(4, 36, kCardW - 8, 18);
    [v addSubview:_nameLabel];

    _countLabel = [NSTextField labelWithString:@""];
    _countLabel.font = [NSFont systemFontOfSize:11.5];
    _countLabel.textColor = t.mut;
    _countLabel.alignment = NSTextAlignmentCenter;
    _countLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _countLabel.frame = NSMakeRect(4, 16, kCardW - 8, 16);
    [v addSubview:_countLabel];
}

- (void)setArtist:(RLPArtist *)artist {
    self.artistName = artist.name;
    self.nameLabel.stringValue = artist.name;
    self.countLabel.stringValue = [NSString stringWithFormat:RLPTr(@"%ld 张专辑"), (long)artist.albumCount];
    self.initialLabel.stringValue = artist.name.length ? [artist.name substringToIndex:1].uppercaseString : @"?";
    self.coverView.image = nil;
    // 真封面（/api/artist/image?who=…，与 web 艺术家卡片同端点）。取不到就保留首字母占位，
    // 这不是错误状态、也不报 toast —— 大量本地曲库本来就没有艺术家图。
    if (!artist.name.length) return;
    NSString *who = artist.name;
    NSString *url = [NSString stringWithFormat:@"/api/artist/image?who=%@", RLPEnc(who)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getData:url completion:^(NSData * _Nullable data) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || data.length == 0) return;
        // 复用回来的 item 可能已被换给别的艺术家：名字不一致就丢弃。
        if (![self_.artistName isEqualToString:who]) return;
        NSImage *img = [[NSImage alloc] initWithData:data];
        if (img) self_.coverView.image = img;
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
    // 大圆头像网格（图一）：168×196 卡，间距 18/22，与 web minmax(150px,1fr)+gap16 同观感。
    layout.itemSize = NSMakeSize(kCardW, kCardH);
    layout.sectionInset = NSEdgeInsetsMake(18, 24, 28, 24);
    layout.minimumInteritemSpacing = 18;
    layout.minimumLineSpacing = 22;

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