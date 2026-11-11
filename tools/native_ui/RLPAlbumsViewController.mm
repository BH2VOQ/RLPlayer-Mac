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
        [_coverView.heightAnchor constraintEqualToConstant:180],
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
    self.artistLabel.stringValue = sub.count ? [sub componentsJoinedByString:@" · "] : @"未知艺术家";
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

- (void)cardHoverChanged:(BOOL)on { _hovered = on; [self refreshHighlight]; }

@end

#pragma mark - 专辑网格

@interface RLPAlbumsViewController () <NSCollectionViewDataSource, NSCollectionViewDelegate>
@property (nonatomic, strong) NSCollectionView *collection;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *countLabel;
@property (nonatomic, strong) NSMutableArray<RLPAlbum *> *albums;
@property (nonatomic, strong) NSCache<NSString *, NSImage *> *coverCache;
@end

@implementation RLPAlbumsViewController

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

- (NSInteger)albumCount { return (NSInteger)self.albums.count; }

- (void)loadView {
    RLPTheme *t = [RLPTheme current];
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 900, 640)];
    root.wantsLayer = YES;
    root.layer.backgroundColor = t.bg.CGColor;
    self.view = root;

    self.titleLabel = [NSTextField labelWithString:RLPTr(@"专辑")];
    self.titleLabel.font = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
    self.titleLabel.textColor = t.text;
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    // 标题与计数统一由主窗口顶栏承载（web #pth/#cnt 同口径），页内不再画。
    self.titleLabel.hidden = YES;
    [root addSubview:self.titleLabel];
    NSTextField *title = self.titleLabel;

    self.countLabel = [NSTextField labelWithString:@"—"];
    self.countLabel.font = t.small;
    self.countLabel.textColor = t.mut;
    self.countLabel.alignment = NSTextAlignmentRight;
    self.countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.countLabel.hidden = YES;   // 计数走顶栏 RLPPageCountNotification
    [root addSubview:self.countLabel];

    NSCollectionViewFlowLayout *layout = [[NSCollectionViewFlowLayout alloc] init];
    layout.itemSize = NSMakeSize(180, 230);
    layout.sectionInset = NSEdgeInsetsMake(20, 24, 24, 24);
    layout.minimumInteritemSpacing = 16;
    layout.minimumLineSpacing = 20;

    self.collection = [[NSCollectionView alloc] initWithFrame:NSZeroRect];
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
        // 顶栏计数（web #cnt 同口径）：页加载完上报，主窗口显示在页标题旁。
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPPageCountNotification"
            object:[NSString stringWithFormat:@"%ld 张专辑", (long)list.count]];
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

@end