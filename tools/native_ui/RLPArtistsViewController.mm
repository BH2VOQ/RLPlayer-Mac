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

#pragma mark - 艺术家卡片

@interface RLPArtistItem : NSCollectionViewItem
@property (nonatomic, strong) NSView *avatarView;
@property (nonatomic, strong) NSTextField *initialLabel;
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSTextField *countLabel;
@property (nonatomic, copy) NSString *artistName;
@end

@implementation RLPArtistItem

- (void)loadView {
    RLPTheme *t = [RLPTheme current];
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 168, 74)];
    v.wantsLayer = YES;
    self.view = v;

    _avatarView = [[NSView alloc] initWithFrame:NSMakeRect(10, 13, 48, 48)];
    _avatarView.wantsLayer = YES;
    _avatarView.layer.cornerRadius = 24;
    _avatarView.layer.backgroundColor = t.bg2.CGColor;
    [v addSubview:_avatarView];

    _initialLabel = [NSTextField labelWithString:@""];
    _initialLabel.font = [NSFont systemFontOfSize:20 weight:NSFontWeightMedium];
    _initialLabel.textColor = t.text;
    _initialLabel.alignment = NSTextAlignmentCenter;
    _initialLabel.frame = NSMakeRect(0, 8, 48, 32);
    [_avatarView addSubview:_initialLabel];

    _nameLabel = [NSTextField labelWithString:@""];
    _nameLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    _nameLabel.textColor = t.text;
    _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _nameLabel.frame = NSMakeRect(68, 38, 90, 20);
    [v addSubview:_nameLabel];

    _countLabel = [NSTextField labelWithString:@""];
    _countLabel.font = [NSFont systemFontOfSize:11.5];
    _countLabel.textColor = t.mut;
    _countLabel.frame = NSMakeRect(68, 18, 90, 20);
    [v addSubview:_countLabel];
}

- (void)setArtist:(RLPArtist *)artist {
    self.artistName = artist.name;
    self.nameLabel.stringValue = artist.name;
    self.countLabel.stringValue = [NSString stringWithFormat:RLPTr(@"%ld 张专辑"), (long)artist.albumCount];
    self.initialLabel.stringValue = artist.name.length ? [artist.name substringToIndex:1].uppercaseString : @"?";
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
    layout.itemSize = NSMakeSize(168, 74);
    layout.sectionInset = NSEdgeInsetsMake(20, 24, 24, 24);
    layout.minimumInteritemSpacing = 10;
    layout.minimumLineSpacing = 10;

    self.collection = [[NSCollectionView alloc] initWithFrame:NSZeroRect];
    self.collection.collectionViewLayout = layout;
    self.collection.dataSource = self;
    self.collection.delegate = self;
    self.collection.selectable = YES;
    [self.collection registerClass:[RLPArtistItem class] forItemWithIdentifier:kArtistItemID];

    NSClickGestureRecognizer *dbl = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(onDoubleClick:)];
    dbl.numberOfClicksRequired = 2;
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
