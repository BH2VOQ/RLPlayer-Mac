// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later

#import "RLPFavoritesViewController.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPTheme.h"
#import "RLPSupport.h"
#import "RLPTrackActions.h"

static const NSUserInterfaceItemIdentifier kFavTableID = @"RLPFavTable";
// web .favhead 第 5 列：行尾心形（实心 ⟹ 点一下取消收藏）。
static NSString * const kFavColHeart = @"ColFavHeart";
// web .favhead 网格（ui_script.h:3703-3721）：34px # / 1fr 标题 / 180px 艺术家 / 200px 专辑 / 34px 心。
// **没有时长列**——旧原生多出的「时长」列在 web 列集里不存在（P12）。
static const CGFloat kFavIndexW = 34.0;
static const CGFloat kFavArtistW = 180.0;
static const CGFloat kFavAlbumW = 200.0;
static const CGFloat kFavHeartW = 34.0;
static const CGFloat kFavTitleMinW = 120.0;

@interface RLPFavoritesViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSMutableArray<RLPTrack *> *tracks;
@property (nonatomic, strong) NSTextField *hintLabel;    // web .favhint：双击顺序播放整个最爱列表
@property (nonatomic, strong) NSTextField *emptyLabel;   // web 空态：还没有收藏 + 怎么做
@end

@implementation RLPFavoritesViewController

- (instancetype)init {
    self = [super initWithTitle:RLPTr(@"我的最爱")];
    if (self) {
        _tracks = [NSMutableArray array];
    }
    return self;
}

- (void)buildContent {

    
    _tableView = [[RLPTrackActionTableView alloc] initWithFrame:self.contentView.bounds];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    // 右键 = 与 web 一致的完整曲目动作（播放/入队/收藏/存歌单/体检/对比）
    {
        __weak __typeof__(self) ws = self;
        ((RLPTrackActionTableView *)_tableView).pathForRow = ^NSString *(NSInteger row) {
            __typeof__(self) s = ws;
            NSArray<RLPTrack *> *ts = self.tracks;
            if (!s || row < 0 || row >= (NSInteger)ts.count) return nil;
            return ts[(NSUInteger)row].path;
        };
    }
    _tableView.headerView = [[NSTableHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 0, 24)];
    // 同队列页：web 无斑马底；空表时交替色会在空白区域铺出条带。
    _tableView.usesAlternatingRowBackgroundColors = NO;
    
    // P12：web .favhead 是 5 列（34px # / 1fr 标题 / 180px 艺术家 / 200px 专辑 / 34px 心），
    // 旧原生的第 5 列「时长」是 web 不存在的多余列（网格模板里没有 dur）。
    NSArray *cols = @[@"#", RLPTr(@"标题"), RLPTr(@"艺术家"), RLPTr(@"专辑"), @""];
    for (NSInteger i = 0; i < (NSInteger)cols.count; i++) {
        NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"col%ld", (long)i]];
        c.title = cols[i];
        c.resizingMask = NSTableColumnNoResizing;
        switch (i) {
            case 0:
                c.width = kFavIndexW; c.minWidth = kFavIndexW; c.maxWidth = kFavIndexW;
                break;
            case 1:
                c.width = 420; c.minWidth = kFavTitleMinW; c.maxWidth = 10000;
                break;
            case 2:
                c.width = kFavArtistW; c.minWidth = kFavArtistW; c.maxWidth = kFavArtistW;
                break;
            case 3:
                c.width = kFavAlbumW; c.minWidth = kFavAlbumW; c.maxWidth = kFavAlbumW;
                break;
            default:
                c.identifier = kFavColHeart;
                c.width = kFavHeartW; c.minWidth = kFavHeartW; c.maxWidth = kFavHeartW;
                break;
        }
        [_tableView addTableColumn:c];
    }
    // 不交给 AppKit 均匀拉伸：标题列按 web 的 1fr 自己吃剩余宽度（见 -viewDidLayout）。
    _tableView.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
    
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:self.contentView.bounds];
    scroll.documentView = _tableView;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    [self.contentView addSubview:scroll];
    
    // 双击播放（P1）：单击**只选中**，绝不整列开播。
    // web 真源 ui_script.h:3725-3737：.favrow 的 onclick 只切换 .fsel 选中态，
    // 整列顺序播放挂在 ondblclick（playWholeListFrom）上。旧原生把 action（单击）
    // 也指向 onDoubleClick: ⟹ 点一下行就把整个收藏列表建成队列并起播，与 web 相悖。
    _tableView.action = NULL;
    _tableView.doubleAction = @selector(onDoubleClick:);
    _tableView.target = self;
    
    // 右键菜单 = RLPTrackActionTableView 的共享菜单（menuForEvent 按被点行构造完整动作集）。
    // 旧实现在这里另建了一份静态菜单并挂到 tableView.menu，但 menuForEvent 永远优先返回共享菜单，
    // 这份静态菜单**从未生效**（P11 死代码，删除）。
    // web .favhint：列表顶部一句"双击 = 从这个开始顺序播放整个最爱列表（N 首）"。
    // 用**约束**而不是 frame：本页 contentView 由外层 pageHost 给尺寸，
    // frame 布局时算出来的 y 会落到页面下沿（实测空态文字被压到播放条上）。
    _hintLabel = RLPLabel(@"", [NSFont systemFontOfSize:12], [RLPTheme current].text2);
    _hintLabel.identifier = @"fav.hint";
    _hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_hintLabel];
    // web 空态：还没有收藏 / 在曲目行或单曲页点心形，就会出现在这里
    _emptyLabel = RLPLabel([RLPTr(@"还没有收藏") stringByAppendingFormat:@"\n%@", RLPTr(@"在曲目行或单曲页点心形，就会出现在这里")],
                           [NSFont systemFontOfSize:13], [RLPTheme current].mut);
    _emptyLabel.identifier = @"fav.empty";
    _emptyLabel.alignment = NSTextAlignmentCenter;
    _emptyLabel.maximumNumberOfLines = 2;
    _emptyLabel.hidden = YES;
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_emptyLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_hintLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_hintLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [_hintLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [_emptyLabel.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [_emptyLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_emptyLabel.widthAnchor constraintLessThanOrEqualToAnchor:self.contentView.widthAnchor constant:-40],
    ]];
}

/// web .favhead 的标题列是 1fr：随页面宽度伸缩，其余四列固定（34 / 180 / 200 / 34）。
/// 旧原生把宽度交给 AppKit 均匀拉伸 ⟹ 5 列都摊成 100pt，和 web 的列宽完全不是一回事。
- (void)viewDidLayout {
    [super viewDidLayout];
    const CGFloat width = NSWidth(self.contentView.bounds);
    if (!_tableView || !(width > 1.0)) return;
    NSTableColumn *title = nil;
    for (NSTableColumn *c in _tableView.tableColumns)
        if ([c.identifier isEqualToString:@"col1"]) { title = c; break; }
    if (!title) return;
    const CGFloat rest = width - (kFavIndexW + kFavArtistW + kFavAlbumW + kFavHeartW);
    title.width = MAX(kFavTitleMinW, rest);
}

- (void)reloadData {
    if (![RLPCoreClient shared].started) {
        [self.tracks removeAllObjects];
        [self setSubtitle:RLPTr(@"核心未启动")];
        [_tableView reloadData];
        return;
    }
    
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/fav/list?meta=1" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || !json || ![json[@"ok"] boolValue]) {
            [self_ setSubtitle:RLPTr(@"加载失败")];
            return;
        }
        
        NSArray *files = json[@"files"];
        NSMutableArray *tracks = [NSMutableArray array];
        for (id item in files) {
            RLPTrack *t = [RLPTrack trackFromJSON:item];
            if (t) [tracks addObject:t];
        }
        self_.tracks = tracks;
        [self_ setSubtitle:[NSString stringWithFormat:RLPTr(@"%ld 首"), (long)tracks.count]];
        [self_.tableView reloadData];
        const NSInteger n = (NSInteger)tracks.count;
        self_.hintLabel.stringValue = n ? [NSString stringWithFormat:RLPTr(@"双击任意一首，从这首开始顺序播放整个最爱列表（%ld 首）"), (long)n] : @"";
        self_.emptyLabel.hidden = n > 0;
    }];
}

#pragma mark - Actions

/// 共享右键菜单的动作入口。
- (void)rlp_trackMenuAction:(NSMenuItem *)sender {
    RLPHandleTrackAction(sender, self.view);
}

- (void)onDoubleClick:(id)sender {
    NSInteger row = [_tableView clickedRow];
    if (row < 0 || row >= (NSInteger)_tracks.count) return;
    [self playRowAtIndex:row];
}

/// 整列起播（双击的真实落点；判据直接调这里，不依赖鼠标事件）。
- (void)playRowAtIndex:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_tracks.count) return;
    // 与 web 我的最爱页同语义：双击不是只播这一首，而是把整个收藏列表建成队列、
    // 从被点那首开始顺序播放（/api/queue/set → playPath）。单曲循环模式会被切回列表循环。
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (RLPTrack *t in _tracks) if (t.path.length) [paths addObject:t.path];
    // start 要用"在过滤后列表里的位置"；_tracks 全有 path 时与 row 一致。
    RLPPlayWholeListFrom(paths, row);
}

#pragma mark - NSTableView

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_tracks.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_tracks.count) return nil;
    // 行尾心形（web .fav-btn）：最爱页里的心永远是实心，点一下 = 取消收藏。
    if ([tableColumn.identifier isEqualToString:kFavColHeart]) {
        NSTableCellView *cell = [tableView makeViewWithIdentifier:kFavColHeart owner:self];
        if (!cell) {
            cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 30, 24)];
            cell.identifier = kFavColHeart;
            NSButton *b = [NSButton buttonWithTitle:@"" target:self action:@selector(onRowUnfav:)];
            b.bordered = NO; b.imagePosition = NSImageOnly; b.imageScaling = NSImageScaleProportionallyDown;
            b.identifier = @"fav.heart";
            b.frame = NSMakeRect(2, 1, 26, 22);
            b.autoresizingMask = NSViewWidthSizable;
            [cell addSubview:b];
            cell.textField = nil;
        }
        NSButton *btn = nil;
        for (NSView *v in cell.subviews) if ([v isKindOfClass:[NSButton class]]) btn = (NSButton *)v;
        btn.tag = row;
        btn.image = [NSImage imageWithSystemSymbolName:@"heart.fill" accessibilityDescription:RLPTr(@"取消收藏")];
        btn.contentTintColor = [RLPTheme current].accent;
        btn.toolTip = RLPTr(@"取消收藏");
        return cell;
    }
    RLPTrack *t = _tracks[row];
    NSString *cid = tableColumn.identifier;
    NSString *val = @"";
    if ([cid isEqualToString:@"col0"]) val = [NSString stringWithFormat:@"%ld", (long)row + 1];
    else if ([cid isEqualToString:@"col1"]) val = t.title;
    else if ([cid isEqualToString:@"col2"]) val = t.artist;
    else if ([cid isEqualToString:@"col3"]) val = t.album;
    
    NSTextField *tf = RLPLabel(val, [RLPTheme current].body, [RLPTheme current].text);
    return tf;
}

/// 行尾心形：取消收藏（web unfavFromFavs 同端点）。
- (void)onRowUnfav:(NSButton *)sender {
    const NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)_tracks.count) return;
    RLPTrack *t = _tracks[(NSUInteger)row];
    NSString *url = [NSString stringWithFormat:@"/api/fav?file=%@&on=0", RLPEnc(t.path)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:url body:@"" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            RLPToast(RLPTr(@"已取消收藏"));
            [self_ reloadData];
        } else {
            RLPToast(RLPTr(@"取消收藏失败"));
        }
    }];
}

@end