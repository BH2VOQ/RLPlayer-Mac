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

static const NSUserInterfaceItemIdentifier kAlbumItemID = @"RLPAlbumItem";

#pragma mark - 专辑卡片

@interface RLPAlbumItem : NSCollectionViewItem
@property (nonatomic, strong) NSImageView *coverView;
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSTextField *artistLabel;
@property (nonatomic, strong) NSTextField *placeholderLabel;
@property (nonatomic, copy) NSString *albumKey;
@end

@implementation RLPAlbumItem

- (void)loadView {
    RLPTheme *t = [RLPTheme current];
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 168, 214)];
    v.wantsLayer = YES;
    self.view = v;

    _coverView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _coverView.wantsLayer = YES;
    _coverView.layer.cornerRadius = 8;
    _coverView.layer.masksToBounds = YES;
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
    _nameLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    _nameLabel.textColor = t.text;
    _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _nameLabel.maximumNumberOfLines = 1;
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_nameLabel];

    _artistLabel = [NSTextField labelWithString:@""];
    _artistLabel.font = [NSFont systemFontOfSize:11.5];
    _artistLabel.textColor = t.mut;
    _artistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _artistLabel.maximumNumberOfLines = 1;
    _artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_artistLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_coverView.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [_coverView.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [_coverView.topAnchor constraintEqualToAnchor:v.topAnchor],
        [_coverView.heightAnchor constraintEqualToConstant:168],
        [_placeholderLabel.centerXAnchor constraintEqualToAnchor:_coverView.centerXAnchor],
        [_placeholderLabel.centerYAnchor constraintEqualToAnchor:_coverView.centerYAnchor],
        [_nameLabel.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:2],
        [_nameLabel.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-2],
        [_nameLabel.topAnchor constraintEqualToAnchor:_coverView.bottomAnchor constant:8],
        [_artistLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_artistLabel.trailingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor],
        [_artistLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],
    ]];
}

- (void)setAlbum:(RLPAlbum *)album cover:(NSImage *)cover {
    RLPTheme *t = [RLPTheme current];
    self.albumKey = album.key;
    self.nameLabel.stringValue = album.name.length ? album.name : @"未知专辑";
    self.artistLabel.stringValue = album.artist.length ? album.artist : @"未知艺术家";
    self.coverView.image = cover;
    self.coverView.layer.backgroundColor = t.bg2.CGColor;
    self.placeholderLabel.hidden = (cover != nil);
    self.placeholderLabel.stringValue = album.name.length ? [album.name substringToIndex:1] : @"♪";
}

@end

#pragma mark - 专辑网格

@interface RLPAlbumsViewController () <NSCollectionViewDataSource, NSCollectionViewDelegate>
@property (nonatomic, strong) NSCollectionView *collection;
@property (nonatomic, strong) NSTextField *countLabel;
@property (nonatomic, strong) NSMutableArray<RLPAlbum *> *albums;
@property (nonatomic, strong) NSCache<NSString *, NSImage *> *coverCache;
@end

@implementation RLPAlbumsViewController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _albums = [NSMutableArray array];
        _coverCache = [[NSCache alloc] init];
        _coverCache.countLimit = 400;
    }
    return self;
}

- (NSInteger)albumCount { return (NSInteger)self.albums.count; }

- (void)loadView {
    RLPTheme *t = [RLPTheme current];
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 900, 640)];
    root.wantsLayer = YES;
    root.layer.backgroundColor = t.bg.CGColor;
    self.view = root;

    NSTextField *title = [NSTextField labelWithString:@"专辑"];
    title.font = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
    title.textColor = t.text;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:title];

    self.countLabel = [NSTextField labelWithString:@"—"];
    self.countLabel.font = t.small;
    self.countLabel.textColor = t.mut;
    self.countLabel.alignment = NSTextAlignmentRight;
    self.countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:self.countLabel];

    NSCollectionViewFlowLayout *layout = [[NSCollectionViewFlowLayout alloc] init];
    layout.itemSize = NSMakeSize(168, 214);
    layout.sectionInset = NSEdgeInsetsMake(20, 24, 24, 24);
    layout.minimumInteritemSpacing = 18;
    layout.minimumLineSpacing = 22;

    self.collection = [[NSCollectionView alloc] initWithFrame:NSZeroRect];
    self.collection.collectionViewLayout = layout;
    self.collection.dataSource = self;
    self.collection.delegate = self;
    self.collection.selectable = YES;
    self.collection.allowsMultipleSelection = NO;
    self.collection.backgroundColors = @[NSColor.clearColor];
    [self.collection registerClass:[RLPAlbumItem class] forItemWithIdentifier:kAlbumItemID];

    NSClickGestureRecognizer *dbl = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(onDoubleClick:)];
    dbl.numberOfClicksRequired = 2;
    [self.collection addGestureRecognizer:dbl];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.documentView = self.collection;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:scroll];

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

- (void)reload {
    if (![RLPCoreClient shared].started) {
        [self.albums removeAllObjects];
        self.countLabel.stringValue = @"核心未启动";
        [self.collection reloadData];
        return;
    }
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/lib/albums" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            self_.countLabel.stringValue = @"加载失败";
            return;
        }
        NSArray<RLPAlbum *> *list = [RLPAlbum albumsFromJSON:json];
        [self_.albums setArray:list];
        [self_.collection reloadData];
        self_.countLabel.stringValue = [NSString stringWithFormat:@"%ld 张专辑", (long)list.count];
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

- (void)onDoubleClick:(NSClickGestureRecognizer *)g {
    NSPoint p = [g locationInView:self.collection];
    NSIndexPath *ip = [self.collection indexPathForItemAtPoint:p];
    if (!ip || ip.item >= (NSInteger)self.albums.count) return;
    RLPAlbum *album = self.albums[(NSUInteger)ip.item];
    if (album.key.length && self.onPlayAlbum) self.onPlayAlbum(album.key);
}

@end