// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPArtistDetailViewController.mm — 艺术家详情实现（纯 AppKit）
//
// 数据来自 /api/lib/albums，根据 RLPSplitArtistNames 筛选匹配专辑并统计；
// 核心未启动时安全空转；封面走 RLPCoverLoader，无图显示音符占位；双击打开专辑。
#import "RLPArtistDetailViewController.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

static const NSUserInterfaceItemIdentifier kArtistAlbumItemID = @"RLPArtistAlbumItem";

#pragma mark - 专辑卡片（168x214）

@interface RLPArtistAlbumItem : NSCollectionViewItem
@property (nonatomic, strong) NSImageView *coverView;
@property (nonatomic, strong) NSTextField *placeholderLabel;
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSTextField *yearLabel;
@property (nonatomic, copy) NSString *albumKey;
- (void)setAlbum:(RLPAlbum *)album;
@end

@implementation RLPArtistAlbumItem

- (void)loadView {
    RLPTheme *t = [RLPTheme current];
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 168, 214)];
    v.wantsLayer = YES;
    self.view = v;

    _coverView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _coverView.wantsLayer = YES;
    _coverView.layer.cornerRadius = 8;
    _coverView.layer.masksToBounds = YES;
    _coverView.layer.backgroundColor = t.bg2.CGColor;
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

    _yearLabel = [NSTextField labelWithString:@""];
    _yearLabel.font = [NSFont systemFontOfSize:11.5];
    _yearLabel.textColor = t.mut;
    _yearLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _yearLabel.maximumNumberOfLines = 1;
    _yearLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_yearLabel];

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

        [_yearLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_yearLabel.trailingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor],
        [_yearLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],
    ]];
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    RLPTheme *t = [RLPTheme current];
    if (selected) {
        self.view.layer.backgroundColor = [t.accent colorWithAlphaComponent:0.15].CGColor;
        self.view.layer.cornerRadius = 8;
    } else {
        self.view.layer.backgroundColor = NSColor.clearColor.CGColor;
    }
}

- (void)setAlbum:(RLPAlbum *)album {
    RLPTheme *t = [RLPTheme current];
    self.albumKey = album.key ?: @"";
    self.nameLabel.stringValue = album.name.length ? album.name : RLPTr(@"未知专辑");
    self.yearLabel.stringValue = album.year > 0 ? [NSString stringWithFormat:@"%ld", (long)album.year] : @"—";
    self.coverView.layer.backgroundColor = t.bg2.CGColor;

    if (album.key.length == 0) {
        self.coverView.image = nil;
        self.placeholderLabel.hidden = NO;
        return;
    }

    NSImage *cached = [[RLPCoverLoader shared] cachedCoverForAlbumKey:album.key];
    if (cached) {
        self.coverView.image = cached;
        self.placeholderLabel.hidden = YES;
    } else {
        self.coverView.image = nil;
        self.placeholderLabel.hidden = NO;
        if (album.hasCover) {
            NSString *expectedKey = album.key;
            __weak __typeof__(self) weakSelf = self;
            [[RLPCoverLoader shared] coverForAlbumKey:album.key completion:^(NSImage * _Nullable img) {
                __typeof__(self) self_ = weakSelf;
                if (!self_) return;
                if ([self_.albumKey isEqualToString:expectedKey]) {
                    if (img) {
                        self_.coverView.image = img;
                        self_.placeholderLabel.hidden = YES;
                    } else {
                        self_.coverView.image = nil;
                        self_.placeholderLabel.hidden = NO;
                    }
                }
            }];
        }
    }
}

@end

#pragma mark - 艺术家详情控制器

@interface RLPArtistDetailViewController () <NSCollectionViewDataSource, NSCollectionViewDelegate>
@property (nonatomic, copy, readwrite) NSString *artistName;
@property (nonatomic, readwrite) NSInteger albumCount;
@property (nonatomic, readwrite) NSInteger totalTracks;
@property (nonatomic, readwrite) double totalDuration;
@property (nonatomic) BOOL loaded;

@property (nonatomic, strong) NSView *avatarView;
@property (nonatomic, strong) NSTextField *initialLabel;
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSTextField *statsLabel;
@property (nonatomic, strong) NSTextField *emptyLabel;
@property (nonatomic, strong) NSScrollView *scroll;
@property (nonatomic, strong) NSCollectionView *collection;
@property (nonatomic, strong) NSMutableArray<RLPAlbum *> *albums;
@end

@implementation RLPArtistDetailViewController

- (instancetype)initWithArtistName:(NSString *)name {
    NSString *title = name.length ? name : RLPTr(@"艺术家");
    self = [super initWithTitle:title];
    if (self) {
        _artistName = [name copy] ?: @"";
        _albums = [NSMutableArray array];
    }
    return self;
}

- (void)buildContent {
    RLPTheme *t = [RLPTheme current];
    NSView *host = self.contentView;

    // 1. 顶部返回按钮
    NSButton *back = RLPSymbolButton(@"chevron.left", RLPTr(@"返回"), self, @selector(onBack:));
    back.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:back];

    // 2. 圆形头像占位（96x96，名字首字符）
    _avatarView = [[NSView alloc] initWithFrame:NSZeroRect];
    _avatarView.wantsLayer = YES;
    _avatarView.layer.cornerRadius = 48;
    _avatarView.layer.masksToBounds = YES;
    _avatarView.layer.backgroundColor = t.bg2.CGColor;
    _avatarView.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:_avatarView];

    NSString *trimmed = [_artistName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *initial = trimmed.length ? [trimmed substringToIndex:1].uppercaseString : @"?";
    _initialLabel = RLPLabel(initial, [NSFont systemFontOfSize:40 weight:NSFontWeightMedium], t.text);
    _initialLabel.alignment = NSTextAlignmentCenter;
    _initialLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_avatarView addSubview:_initialLabel];

    // 3. 名字（24 semibold）
    _nameLabel = RLPLabel(_artistName.length ? _artistName : RLPTr(@"未知艺术家"),
                          [NSFont systemFontOfSize:24 weight:NSFontWeightSemibold],
                          t.text);
    _nameLabel.maximumNumberOfLines = 1;
    _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:_nameLabel];

    // 4. "N 张专辑 · M 首"（12 mut）
    _statsLabel = RLPLabel(@"", [NSFont systemFontOfSize:12], t.mut);
    _statsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:_statsLabel];

    // 5. 专辑网格
    NSCollectionViewFlowLayout *layout = [[NSCollectionViewFlowLayout alloc] init];
    layout.itemSize = NSMakeSize(168, 214);
    layout.sectionInset = NSEdgeInsetsMake(20, 24, 24, 24);
    layout.minimumInteritemSpacing = 18;
    layout.minimumLineSpacing = 22;

    _collection = [[NSCollectionView alloc] initWithFrame:NSZeroRect];
    _collection.collectionViewLayout = layout;
    _collection.dataSource = self;
    _collection.delegate = self;
    _collection.selectable = YES;
    _collection.allowsMultipleSelection = NO;
    _collection.backgroundColors = @[NSColor.clearColor];
    [_collection registerClass:[RLPArtistAlbumItem class] forItemWithIdentifier:kArtistAlbumItemID];

    NSClickGestureRecognizer *dbl = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(onDoubleClick:)];
    dbl.numberOfClicksRequired = 2;
    [_collection addGestureRecognizer:dbl];

    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.documentView = _collection;
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:_scroll];

    // 6. 空状态
    _emptyLabel = RLPLabel(@"", t.body, t.mut);
    _emptyLabel.alignment = NSTextAlignmentCenter;
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyLabel.hidden = YES;
    [host addSubview:_emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [back.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:16],
        [back.topAnchor constraintEqualToAnchor:host.topAnchor constant:6],
        [back.widthAnchor constraintEqualToConstant:24],
        [back.heightAnchor constraintEqualToConstant:24],

        [_avatarView.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:24],
        [_avatarView.topAnchor constraintEqualToAnchor:back.bottomAnchor constant:10],
        [_avatarView.widthAnchor constraintEqualToConstant:96],
        [_avatarView.heightAnchor constraintEqualToConstant:96],

        [_initialLabel.centerXAnchor constraintEqualToAnchor:_avatarView.centerXAnchor],
        [_initialLabel.centerYAnchor constraintEqualToAnchor:_avatarView.centerYAnchor],

        [_nameLabel.leadingAnchor constraintEqualToAnchor:_avatarView.trailingAnchor constant:20],
        [_nameLabel.topAnchor constraintEqualToAnchor:_avatarView.topAnchor constant:18],
        [_nameLabel.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-24],

        [_statsLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_statsLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:8],
        [_statsLabel.trailingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor],

        [_scroll.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [_scroll.topAnchor constraintEqualToAnchor:_avatarView.bottomAnchor constant:16],
        [_scroll.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],

        [_emptyLabel.centerXAnchor constraintEqualToAnchor:_scroll.centerXAnchor],
        [_emptyLabel.centerYAnchor constraintEqualToAnchor:_scroll.centerYAnchor],
    ]];
}

- (void)activate {
    if (!self.loaded) {
        [self reloadData];
    }
}

- (void)reloadData {
    if (![RLPCoreClient shared].started) {
        [self.albums removeAllObjects];
        self.albumCount = 0;
        self.totalTracks = 0;
        self.totalDuration = 0;
        [self setSubtitle:RLPTr(@"核心未启动")];
        self.statsLabel.stringValue = RLPTr(@"核心未启动");
        self.emptyLabel.stringValue = RLPTr(@"核心未启动");
        self.emptyLabel.hidden = NO;
        self.scroll.hidden = YES;
        [self.collection reloadData];
        return;
    }

    NSString *target = [self.artistName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (target.length == 0) {
        target = @"未知艺术家";
    }

    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/lib/albums" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;

        if (!json || ![json[@"ok"] boolValue]) {
            self_.loaded = YES;
            [self_ setSubtitle:RLPTr(@"读取失败")];
            self_.statsLabel.stringValue = RLPTr(@"读取失败");
            self_.emptyLabel.stringValue = RLPTr(@"读取失败");
            self_.emptyLabel.hidden = NO;
            self_.scroll.hidden = YES;
            RLPToast(RLPTr(@"读取失败"));
            return;
        }

        self_.loaded = YES;
        NSArray<RLPAlbum *> *all = [RLPAlbum albumsFromJSON:json];
        NSMutableArray<RLPAlbum *> *filtered = [NSMutableArray array];
        NSInteger totalTracks = 0;
        double totalDuration = 0.0;

        for (RLPAlbum *a in all) {
            NSArray<NSString *> *artists = RLPSplitArtistNames(a.artist);
            BOOL contains = NO;
            for (NSString *art in artists) {
                if ([art localizedCaseInsensitiveCompare:target] == NSOrderedSame) {
                    contains = YES;
                    break;
                }
            }
            if (contains) {
                [filtered addObject:a];
                totalTracks += a.trackCount;
                totalDuration += a.duration;
            }
        }

        [filtered sortUsingComparator:^NSComparisonResult(RLPAlbum *a, RLPAlbum *b) {
            if (a.year != b.year) {
                return a.year > b.year ? NSOrderedAscending : NSOrderedDescending;
            }
            return [a.name localizedCaseInsensitiveCompare:b.name];
        }];

        [self_.albums setArray:filtered];
        self_.albumCount = (NSInteger)filtered.count;
        self_.totalTracks = totalTracks;
        self_.totalDuration = totalDuration;

        if (filtered.count == 0) {
            self_.statsLabel.stringValue = [NSString stringWithFormat:@"0 %@ · 0 %@", RLPTr(@"张专辑"), RLPTr(@"首")];
            [self_ setSubtitle:[NSString stringWithFormat:@"0 %@", RLPTr(@"张专辑")]];
            self_.emptyLabel.stringValue = RLPTr(@"这个艺术家还没有专辑");
            self_.emptyLabel.hidden = NO;
            self_.scroll.hidden = YES;
        } else {
            self_.statsLabel.stringValue = [NSString stringWithFormat:@"%ld %@ · %ld %@",
                                           (long)filtered.count, RLPTr(@"张专辑"),
                                           (long)totalTracks, RLPTr(@"首")];
            [self_ setSubtitle:[NSString stringWithFormat:@"%ld %@ · %ld %@",
                                (long)filtered.count, RLPTr(@"张专辑"),
                                (long)totalTracks, RLPTr(@"首")]];
            self_.emptyLabel.stringValue = @"";
            self_.emptyLabel.hidden = YES;
            self_.scroll.hidden = NO;
        }

        [self_.collection reloadData];
    }];
}

- (void)applyTheme {
    [super applyTheme];
    RLPTheme *t = [RLPTheme current];
    self.avatarView.layer.backgroundColor = t.bg2.CGColor;
    self.initialLabel.textColor = t.text;
    self.nameLabel.textColor = t.text;
    self.statsLabel.textColor = t.mut;
    self.emptyLabel.textColor = t.mut;
    [self.collection reloadData];
}

- (void)onDoubleClick:(NSClickGestureRecognizer *)g {
    NSPoint p = [g locationInView:self.collection];
    NSIndexPath *ip = [self.collection indexPathForItemAtPoint:p];
    if (!ip || ip.item < 0 || ip.item >= (NSInteger)self.albums.count) return;
    RLPAlbum *album = self.albums[(NSUInteger)ip.item];
    if (album.key.length) {
        RLPRequestOpenAlbum(album.key);
    }
}

- (void)onBack:(id)sender {
    (void)sender;
    RLPRequestBack();
}

#pragma mark - NSCollectionViewDataSource

- (NSInteger)collectionView:(NSCollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    (void)collectionView;
    (void)section;
    return (NSInteger)self.albums.count;
}

- (NSCollectionViewItem *)collectionView:(NSCollectionView *)collectionView itemForRepresentedObjectAtIndexPath:(NSIndexPath *)indexPath {
    RLPArtistAlbumItem *item = (RLPArtistAlbumItem *)[collectionView makeItemWithIdentifier:kArtistAlbumItemID forIndexPath:indexPath];
    if (indexPath.item >= 0 && indexPath.item < (NSInteger)self.albums.count) {
        [item setAlbum:self.albums[(NSUInteger)indexPath.item]];
    }
    return item;
}

@end
