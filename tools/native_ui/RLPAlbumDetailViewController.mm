// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPAlbumDetailViewController.mm — 专辑详情（纯 AppKit）
//
// 数据来自 /api/lib/album?k=…；播放走 /api/lib/play（与 web 版同一条后端路径）。
// 空专辑/加载失败都必须如实显示，不假装"已加载"。
#import "RLPAlbumDetailViewController.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPSupport.h"
#import "RLPTrackActions.h"
#import "RLPTheme.h"

@interface RLPAlbumDetailViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, copy) NSString *albumKey;
@property (nonatomic, strong) RLPAlbum *album;
@property (nonatomic, strong) NSArray<RLPTrack *> *tracks;
@property (nonatomic) BOOL loaded;

@property (nonatomic, strong) NSImageView *cover;
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSTextField *artistLabel;
@property (nonatomic, strong) NSTextField *metaLabel;
@property (nonatomic, strong) NSTextField *kindLabel;
@property (nonatomic, strong) NSButton *playAllBtn;
@property (nonatomic, strong) NSTextField *tracksTitle;
@property (nonatomic, strong) NSTextField *tracksMeta;
@property (nonatomic, strong) NSTextField *emptyLabel;
@property (nonatomic, strong) NSTableView *table;
@property (nonatomic, strong) NSScrollView *scroll;
@end

@implementation RLPAlbumDetailViewController

- (instancetype)initWithAlbumKey:(NSString *)key {
    self = [super initWithTitle:RLPTr(@"专辑")];
    if (self) _albumKey = [key copy];
    return self;
}

- (void)buildContent {
    RLPTheme *t = [RLPTheme current];
    NSView *host = self.contentView;

    // 返回按钮带文案（web 顶栏是「← 返回专辑」，不是裸箭头）
    NSButton *back = [NSButton buttonWithTitle:RLPTr(@"返回专辑") target:self action:@selector(onBack:)];
    back.bezelStyle = NSBezelStyleRounded;
    back.image = [NSImage imageWithSystemSymbolName:@"chevron.left" accessibilityDescription:RLPTr(@"返回专辑")];
    back.imagePosition = NSImageLeading;
    back.font = t.small;
    back.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:back];

    self.cover = [[NSImageView alloc] initWithFrame:NSZeroRect];
    self.cover.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.cover.wantsLayer = YES;
    self.cover.layer.cornerRadius = 10;
    self.cover.layer.masksToBounds = YES;
    self.cover.layer.backgroundColor = t.bg2.CGColor;
    self.cover.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.cover];

    // ALBUM 小标签（web 详情页专辑名上方的 eyebrow）
    self.kindLabel = RLPLabel(RLPTr(@"专辑"), [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold], t.mut);
    self.kindLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.kindLabel];

    self.nameLabel = RLPLabel(@"", [NSFont systemFontOfSize:24 weight:NSFontWeightBold], t.text);
    self.nameLabel.maximumNumberOfLines = 2;
    self.nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.nameLabel];

    // web 详情区只有一行元信息（艺术家 · 年份 · N 首 · 总时长），
    // 不再单独画一行艺术家（否则与 metaLabel 重复显示同一个名字）。
    self.artistLabel = RLPLabel(@"", [NSFont systemFontOfSize:14], t.mut);
    self.artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.artistLabel.hidden = YES;
    [host addSubview:self.artistLabel];

    self.metaLabel = RLPLabel(@"", [NSFont systemFontOfSize:12], t.mut);
    self.metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.metaLabel];

    NSButton *playAll = [NSButton buttonWithTitle:RLPTr(@"播放全部") target:self action:@selector(onPlayAll:)];
    playAll.bezelStyle = NSBezelStyleRounded;
    playAll.translatesAutoresizingMaskIntoConstraints = NO;
    // 主按钮：红色实心 + 白字 + 播放图标（web .btn.pri 同口径）
    playAll.wantsLayer = YES;
    playAll.layer.backgroundColor = t.accent.CGColor;
    playAll.layer.cornerRadius = 8;
    // 借鉴上游 .btn.pri 的柔和投影（颜色仍用 mac 的珊瑚红，不照抄 Windows 蓝紫）
    playAll.layer.shadowColor = t.accent.CGColor;
    playAll.layer.shadowOpacity = 0.28;
    playAll.layer.shadowRadius = 6;
    playAll.layer.shadowOffset = CGSizeMake(0, -2);
    playAll.layer.masksToBounds = NO;
    playAll.contentTintColor = NSColor.whiteColor;
    playAll.image = [NSImage imageWithSystemSymbolName:@"play.fill" accessibilityDescription:RLPTr(@"播放全部")];
    playAll.imagePosition = NSImageLeading;
    playAll.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    self.playAllBtn = playAll;
    [host addSubview:playAll];

    NSButton *shuffle = [NSButton buttonWithTitle:RLPTr(@"随机播放") target:self action:@selector(onShuffle:)];
    shuffle.bezelStyle = NSBezelStyleRounded;
    shuffle.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:shuffle];

    // 整张专辑入队（不打断当前播放）+ 人工换封面
    NSButton *enqueue = [NSButton buttonWithTitle:RLPTr(@"加入队列") target:self action:@selector(onEnqueueAlbum:)];
    enqueue.bezelStyle = NSBezelStyleRounded;
    enqueue.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:enqueue];

    NSButton *setCover = [NSButton buttonWithTitle:RLPTr(@"更换封面") target:self action:@selector(onSetCover:)];
    setCover.bezelStyle = NSBezelStyleRounded;
    setCover.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:setCover];

    // 曲目列表标题行（web：左「曲目列表」右「N 首 · 总时长 …」）
    self.tracksTitle = RLPLabel(RLPTr(@"曲目列表"), [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], t.text);
    self.tracksTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.tracksTitle];
    self.tracksMeta = RLPLabel(@"", t.small, t.mut);
    self.tracksMeta.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.tracksMeta];

    self.emptyLabel = RLPLabel(@"", t.body, t.mut);
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.emptyLabel];

    // 用共享曲目表格：右键得到与 web 一致的完整动作（含体检/对比/存歌单）
    self.table = [[RLPTrackActionTableView alloc] initWithFrame:NSZeroRect];
    self.table.backgroundColor = [NSColor clearColor];
    self.table.headerView = nil;
    self.table.rowHeight = 38;
    self.table.intercellSpacing = NSMakeSize(0, 1);
    self.table.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.target = self;
    // 与 web 版一致：**单击**即触发（web 的行 onclick 就是单击）。
    // 双击保留兼容；两者指向同一动作，重复触发幂等。
    self.table.action = @selector(onRowDoubleClick:);
    self.table.doubleAction = @selector(onRowDoubleClick:);
    // 列顺序与 web 一致：序号 → 收藏爱心 → 曲名 → 艺术家 → 时长 → 入队「+」
    for (NSString *ident in @[@"n", @"fav", @"title", @"artist", @"dur", @"add"]) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:ident];
        if ([ident isEqualToString:@"n"]) col.width = 34;
        else if ([ident isEqualToString:@"fav"]) col.width = 30;
        else if ([ident isEqualToString:@"title"]) col.width = 340;
        else if ([ident isEqualToString:@"artist"]) col.width = 190;
        else if ([ident isEqualToString:@"dur"]) col.width = 64;
        else col.width = 34;
        [self.table addTableColumn:col];
    }
    {
        __weak __typeof__(self) ws = self;
        RLPTrackActionTableView *tv = (RLPTrackActionTableView *)self.table;
        tv.pathForRow = ^NSString *(NSInteger row) {
            __typeof__(self) s = ws;
            if (!s || row < 0 || row >= (NSInteger)s.tracks.count) return nil;
            return s.tracks[(NSUInteger)row].path;
        };
    }
    self.scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.scroll.drawsBackground = NO;
    self.scroll.hasVerticalScroller = YES;
    self.scroll.autohidesScrollers = YES;
    self.scroll.documentView = self.table;
    self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.scroll];

    [NSLayoutConstraint activateConstraints:@[
        [back.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:16],
        [back.topAnchor constraintEqualToAnchor:host.topAnchor constant:6],
        [back.heightAnchor constraintEqualToConstant:26],

        [self.cover.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:24],
        [self.cover.topAnchor constraintEqualToAnchor:back.bottomAnchor constant:10],
        [self.cover.widthAnchor constraintEqualToConstant:175],
        [self.cover.heightAnchor constraintEqualToConstant:175],

        // ALBUM 小标签在专辑名上方（web eyebrow）
        [self.kindLabel.leadingAnchor constraintEqualToAnchor:self.cover.trailingAnchor constant:20],
        [self.kindLabel.topAnchor constraintEqualToAnchor:self.cover.topAnchor constant:2],
        [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.cover.trailingAnchor constant:20],
        [self.nameLabel.topAnchor constraintEqualToAnchor:self.kindLabel.bottomAnchor constant:4],
        [self.nameLabel.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-24],
        [self.artistLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [self.artistLabel.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:6],
        [self.artistLabel.trailingAnchor constraintEqualToAnchor:self.nameLabel.trailingAnchor],
        [self.metaLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [self.metaLabel.topAnchor constraintEqualToAnchor:self.artistLabel.bottomAnchor constant:4],
        [self.metaLabel.trailingAnchor constraintEqualToAnchor:self.nameLabel.trailingAnchor],

        [playAll.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [playAll.topAnchor constraintEqualToAnchor:self.metaLabel.bottomAnchor constant:12],
        [shuffle.leadingAnchor constraintEqualToAnchor:playAll.trailingAnchor constant:10],
        [shuffle.centerYAnchor constraintEqualToAnchor:playAll.centerYAnchor],
        [enqueue.leadingAnchor constraintEqualToAnchor:shuffle.trailingAnchor constant:10],
        [enqueue.centerYAnchor constraintEqualToAnchor:playAll.centerYAnchor],
        [setCover.leadingAnchor constraintEqualToAnchor:enqueue.trailingAnchor constant:10],
        [setCover.centerYAnchor constraintEqualToAnchor:playAll.centerYAnchor],

        [self.emptyLabel.leadingAnchor constraintEqualToAnchor:self.cover.leadingAnchor],
        [self.emptyLabel.topAnchor constraintEqualToAnchor:self.cover.bottomAnchor constant:18],

        [self.tracksTitle.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:24],
        [self.tracksTitle.topAnchor constraintEqualToAnchor:self.cover.bottomAnchor constant:16],
        [self.tracksMeta.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-24],
        [self.tracksMeta.firstBaselineAnchor constraintEqualToAnchor:self.tracksTitle.firstBaselineAnchor],
        [self.scroll.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:24],
        [self.scroll.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-24],
        [self.scroll.topAnchor constraintEqualToAnchor:self.tracksTitle.bottomAnchor constant:8],
        [self.scroll.bottomAnchor constraintEqualToAnchor:host.bottomAnchor constant:-12],
    ]];
}

- (void)activate {
    if (!self.loaded) [self reloadData];
}

- (void)reloadData {
    if (![RLPCoreClient shared].started) {
        [self setSubtitle:RLPTr(@"核心未启动")];
        self.emptyLabel.stringValue = RLPTr(RLPTr(@"核心未启动"));
        return;
    }
    if (!self.albumKey.length) {
        self.emptyLabel.stringValue = RLPTr(@"缺少专辑标识");
        return;
    }
    NSString *path = [NSString stringWithFormat:@"/api/lib/album?k=%@", RLPEnc(self.albumKey)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:path completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            self_.loaded = YES;
            [self_ setSubtitle:RLPTr(@"读取失败")];
            self_.emptyLabel.stringValue = RLPTr(RLPTr(@"读取失败"));
            RLPToast(RLPTr(@"专辑读取失败"));
            return;
        }
        RLPAlbum *album = [RLPAlbum albumFromJSON:json];
        self_.album = album;
        self_.tracks = [RLPTrack tracksFromJSON:json key:@"tracks"];
        self_.loaded = YES;

        self_.titleLabel.stringValue = album.name.length ? album.name : RLPTr(RLPTr(@"专辑"));
        self_.nameLabel.stringValue = album.name.length ? album.name : RLPTr(@"未知专辑");
        self_.artistLabel.stringValue = album.artist.length ? album.artist : RLPTr(@"未知艺术家");
        double totalDur = 0;
        for (RLPTrack *t in self_.tracks) totalDur += (t.duration > 0 ? t.duration : 0);
        // 与 web 同口径：艺术家 · 年份 · N 首 · 总时长
        NSMutableArray<NSString *> *mi = [NSMutableArray array];
        if (album.artist.length) [mi addObject:album.artist];
        if (album.year > 0) [mi addObject:[NSString stringWithFormat:@"%ld", (long)album.year]];
        [mi addObject:[NSString stringWithFormat:@"%ld %@", (long)self_.tracks.count, RLPTr(@"首")]];
        [mi addObject:RLPFmtDuration(totalDur)];
        self_.metaLabel.stringValue = [mi componentsJoinedByString:@" · "];
        self_.tracksMeta.stringValue = [NSString stringWithFormat:@"%ld %@ · %@ %@",
            (long)self_.tracks.count, RLPTr(@"首"), RLPTr(@"总时长"), RLPFmtDuration(totalDur)];
        [self_ setSubtitle:[NSString stringWithFormat:@"%ld %@", (long)self_.tracks.count, RLPTr(@"首")]];

        self_.emptyLabel.stringValue = self_.tracks.count ? @"" : RLPTr(@"没有曲目");
        [self_.table reloadData];

        if (album.hasCover) {
            [[RLPCoverLoader shared] coverForAlbumKey:album.key completion:^(NSImage * _Nullable img) {
                if (img) self_.cover.image = img;
            }];
        }
    }];
}

#pragma mark - 表格

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.tracks.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.tracks.count) return nil;
    RLPTheme *t = [RLPTheme current];
    RLPTrack *tr = self.tracks[(NSUInteger)row];
    NSString *ident = col.identifier;
    // 收藏 / 入队是**按钮**列（web 每行都有空心爱心与「+」）
    if ([ident isEqualToString:@"fav"] || [ident isEqualToString:@"add"]) {
        NSButton *b = [tableView makeViewWithIdentifier:ident owner:self];
        if (!b) {
            b = [NSButton buttonWithTitle:@"" target:self
                        action:[ident isEqualToString:@"fav"] ? @selector(onRowFav:) : @selector(onRowAdd:)];
            b.identifier = ident;
            b.bordered = NO;
            b.imagePosition = NSImageOnly;
            b.imageScaling = NSImageScaleProportionallyDown;
        }
        b.tag = row;
        if ([ident isEqualToString:@"fav"]) {
            b.image = [NSImage imageWithSystemSymbolName:@"heart" accessibilityDescription:RLPTr(@"收藏")];
            b.contentTintColor = t.mut;
            b.toolTip = RLPTr(@"收藏");
        } else {
            b.image = [NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:RLPTr(@"加入队列")];
            b.contentTintColor = t.mut;
            b.toolTip = RLPTr(@"加入队列");
        }
        return b;
    }
    NSTextField *label = [tableView makeViewWithIdentifier:ident owner:self];
    if (!label) {
        label = RLPLabel(@"", t.body, t.text);
        label.identifier = ident;
        label.font = [ident isEqualToString:@"dur"] ? t.mono : t.body;
    }
    if ([ident isEqualToString:@"n"]) {
        label.stringValue = [NSString stringWithFormat:@"%ld", (long)(tr.number > 0 ? tr.number : row + 1)];
        label.textColor = t.mut;
    } else if ([ident isEqualToString:@"title"]) {
        label.stringValue = tr.title.length ? tr.title : RLPTr(@"未命名曲目");
        label.textColor = t.text;
    } else if ([ident isEqualToString:@"artist"]) {
        label.stringValue = tr.artist.length ? tr.artist : (self.album.artist ?: @"");
        label.textColor = t.mut;
    } else {
        label.stringValue = RLPFmtDuration(tr.duration);
        label.textColor = t.mut;
    }
    return label;
}

/// 共享右键菜单的动作入口。
- (void)rlp_trackMenuAction:(NSMenuItem *)sender {
    RLPHandleTrackAction(sender, self.view);
}

/// 单曲收藏（/api/fav?file=…&on=1，与 web 行内爱心同一端点）。
- (void)onRowFav:(NSButton *)sender {
    const NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)self.tracks.count) return;
    RLPTrack *tr = self.tracks[(NSUInteger)row];
    NSString *url = [NSString stringWithFormat:@"/api/fav?file=%@&on=1", RLPEnc(tr.path)];
    [[RLPCoreClient shared] postJSON:url body:@"" completion:^(NSDictionary * _Nullable json) {
        if (json && [json[@"ok"] boolValue]) {
            sender.image = [NSImage imageWithSystemSymbolName:@"heart.fill" accessibilityDescription:RLPTr(@"已收藏")];
            sender.contentTintColor = [RLPTheme current].accent;
            RLPToast(RLPTr(@"已收藏"));
        } else RLPToast(RLPTr(@"收藏失败"));
    }];
}

/// 单曲入队（/api/add，不打断当前播放）。
- (void)onRowAdd:(NSButton *)sender {
    const NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)self.tracks.count) return;
    RLPEnqueuePath(self.tracks[(NSUInteger)row].path);
    RLPToast(RLPTr(@"已加入队列"));
}

- (void)onRowDoubleClick:(id)sender {
    NSInteger row = self.table.clickedRow;
    if (row < 0 || row >= (NSInteger)self.tracks.count) return;
    RLPPlayPath(self.tracks[(NSUInteger)row].path);
}

- (void)onPlayAll:(id)sender {
    RLPPlayAlbum(self.albumKey, 0);
}

/// 整张专辑加入队列（POST /api/lib/enqueue?k=…）：不打断当前播放。
- (void)onEnqueueAlbum:(id)sender {
    if (!self.albumKey.length || ![RLPCoreClient shared].started) return;
    NSString *url = [NSString stringWithFormat:@"/api/lib/enqueue?k=%@", RLPEnc(self.albumKey)];
    [[RLPCoreClient shared] postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
        if (json && [json[@"ok"] boolValue]) RLPToast(RLPTr(@"整张专辑已加入队列"));
        else RLPToast([json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"加入失败"));
    }];
}

/// 人工设置封面：POST /api/lib/cover/set?k=… body = 图片原始字节。
/// 走 setData（不是 postJSON）—— 这个端点收的是二进制，不是表单。
- (void)onSetCover:(id)sender {
    if (!self.albumKey.length || ![RLPCoreClient shared].started) return;
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseFiles = YES;
    p.canChooseDirectories = NO;
    p.allowsMultipleSelection = NO;
    p.message = RLPTr(@"选择一张图片作为专辑封面");
    if ([p runModal] != NSModalResponseOK || !p.URL) return;
    NSData *data = [NSData dataWithContentsOfURL:p.URL];
    if (!data.length) { RLPToast(RLPTr(@"图片读取失败")); return; }
    NSString *url = [NSString stringWithFormat:@"/api/lib/cover/set?k=%@", RLPEnc(self.albumKey)];
    [[RLPCoreClient shared] postData:url body:data contentType:@"image/jpeg"
                          completion:^(NSDictionary * _Nullable json) {
        if (json && [json[@"ok"] boolValue]) RLPToast(RLPTr(@"封面已设置"));
        else RLPToast([json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"设置失败"));
    }];
}

- (void)onShuffle:(id)sender {
    // 先切随机再播放：顺序不能反（播放会按当时的模式决定推进方式）
    RLPPostJSON(@"/api/playmode?mode=3", nil);
    RLPPlayAlbum(self.albumKey, 0);
    RLPToast(RLPTr(@"已切换到随机并开始播放"));
}

- (void)onBack:(id)sender {
    RLPRequestBack();
}

- (void)applyTheme {
    [super applyTheme];
    RLPTheme *t = [RLPTheme current];
    self.cover.layer.backgroundColor = t.bg2.CGColor;
    self.nameLabel.textColor = t.text;
    self.kindLabel.textColor = t.mut;
    self.tracksTitle.textColor = t.text;
    self.tracksMeta.textColor = t.mut;
    self.playAllBtn.layer.backgroundColor = t.accent.CGColor;
    self.playAllBtn.contentTintColor = NSColor.whiteColor;
    self.artistLabel.textColor = t.mut;
    self.metaLabel.textColor = t.mut;
    self.emptyLabel.textColor = t.mut;
    [self.table reloadData];
}

@end