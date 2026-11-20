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

#pragma mark - 其他作品卡片（参考图一：同一艺人的其它专辑，横向封面卡）

/// 「其他作品」卡片：封面 + 标题 + 年份。整块可点（点击进那张专辑的详情页）。
@interface RLPOtherWorkCard : NSButton
@property (nonatomic, copy) NSString *albumKey;
@property (nonatomic, strong) NSImageView *cover;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *subLabel;
@end

@implementation RLPOtherWorkCard

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.bordered = NO;
        self.title = @"";
        self.wantsLayer = YES;
        _cover = [[RLPCoverImageView alloc] initWithFrame:NSZeroRect];
        _cover.imageScaling = NSImageScaleProportionallyUpOrDown;
        _cover.wantsLayer = YES;
        _cover.layer.cornerRadius = 8;
        _cover.layer.masksToBounds = YES;
        _cover.layer.borderWidth = 1;
        [self addSubview:_cover];
        _titleLabel = RLPLabel(@"", [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium], [RLPTheme current].text);
        _subLabel = RLPLabel(@"", [NSFont systemFontOfSize:11], [RLPTheme current].mut);
        [self addSubview:_titleLabel];
        [self addSubview:_subLabel];
    }
    return self;
}

- (void)layout {
    [super layout];
    // NSControl（含 NSButton）是**翻转**视图：y=0 在顶部、向下增长。
    // 图一的卡片顺序是 封面在上、名字在下、年份再下 —— 必须在翻转坐标里写，
    // 否则像本实现初版一样把文字排到封面上方（截图抓到的）。
    const CGFloat w = self.bounds.size.width;
    _cover.frame = NSMakeRect(0, 0, w, w);
    _titleLabel.frame = NSMakeRect(0, w + 8, w, 16);
    _subLabel.frame = NSMakeRect(0, w + 26, w, 14);
}

@end

// Dedicated Web-sized buttons: no native bezel metrics or implicit padding.
@interface RLPAlbumButton : NSButton
@property (nonatomic) BOOL primary;
/// 圆角：胶囊 8、圆形图标键 16（图一）。默认 8。
@property (nonatomic) CGFloat cornerRadius;
@end
@implementation RLPAlbumButton
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    RLPTheme *theme=[RLPTheme current];
    const CGFloat radius = self.cornerRadius > 0 ? self.cornerRadius : 8;
    NSBezierPath *shape=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,.5,.5) xRadius:radius yRadius:radius];
    if(self.primary) {
        NSGradient *gradient=[[NSGradient alloc] initWithStartingColor:theme.accent endingColor:theme.accent2];
        [gradient drawInBezierPath:shape angle:-90];
    } else { [(self.highlighted?theme.hov2:theme.hov) setFill];[shape fill];[theme.line setStroke];[shape stroke]; }
    NSColor *color=self.primary?NSColor.whiteColor:theme.text;
    NSDictionary *attrs=@{NSFontAttributeName:self.font,NSForegroundColorAttributeName:color};
    NSSize size=[self.title sizeWithAttributes:attrs];
    const BOOL clampIcon = self.image && ![self.image.name isEqualToString:NSImageNameTouchBarPlayPauseTemplate];
    CGFloat icon=self.image?14:0, x=(self.bounds.size.width-size.width-icon)/2;
    [self.title drawAtPoint:NSMakePoint(x+icon,(self.bounds.size.height-size.height)/2) withAttributes:attrs];
    // 图标：主按钮的 播放/暂停 用自绘三角（web 的 ▶/❚❚ 观感）；其余一律画**真的符号图**
    // （旧实现对所有带 image 的按钮都画三角 ⟹ 圆形随机键上出现一个播放三角，截图里能看到）。
    if(self.image) {
        CGFloat y=(self.bounds.size.height-10)/2;
        if(self.primary && icon>0) {
            [color setFill];
            if([self.title isEqual:RLPTr(@"暂停")]) { NSRectFill(NSMakeRect(x,y,3,10));NSRectFill(NSMakeRect(x+6,y,3,10)); }
            else { NSBezierPath *triangle=[NSBezierPath bezierPath];[triangle moveToPoint:NSMakePoint(x,y)];[triangle lineToPoint:NSMakePoint(x+9,y+5)];[triangle lineToPoint:NSMakePoint(x,y+10)];[triangle closePath];[triangle fill]; }
        } else {
            (void)clampIcon;
            NSRect iconRect = NSMakeRect((self.bounds.size.width-16)/2,(self.bounds.size.height-16)/2,16,16);
            [color set];
            [self.image drawInRect:iconRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                           fraction:1 respectFlipped:YES hints:nil];
        }
    }
}
@end

// All content shares the row center; NSTextField otherwise paints at its top
// while NSButton centers its image inside the full 38pt table cell.
@interface RLPAlbumTrackCell : NSTableCellView
@property (nonatomic, strong) NSControl *content;
@end
@implementation RLPAlbumTrackCell
- (void)layout {
    [super layout];
    CGFloat height=[self.content isKindOfClass:NSButton.class]?22:ceil(self.content.fittingSize.height);
    height=MIN(self.bounds.size.height,height);
    self.content.frame=NSMakeRect(0,round((self.bounds.size.height-height)/2),self.bounds.size.width,height);
}
@end

@interface RLPAlbumDocumentView : NSView
@end
@implementation RLPAlbumDocumentView
- (BOOL)isFlipped { return YES; }
@end

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
@property (nonatomic, strong) NSScrollView *pageScroll;
@property (nonatomic, strong) NSView *albumDocument;
@property (nonatomic, strong) NSArray<NSButton *> *heroButtons;
@property (nonatomic, strong) NSTextField *coverPlaceholder;
@property (nonatomic, strong) NSView *listRule;
@property (nonatomic, strong) NSTextField *progressLabel;
@property (nonatomic, strong) NSView *summaryCard;
@property (nonatomic, strong) NSTextField *summaryLabel;
@property (nonatomic) NSUInteger metadataGeneration;
@property (nonatomic) NSUInteger prefetchNext, prefetchDone, prefetchActive;
@property (nonatomic, strong) NSMutableSet<NSString *> *favoritePaths;
@property (nonatomic, strong) RLPPlaybackStatus *playbackStatus;
@property (nonatomic, strong) NSArray<RLPTrack *> *prefetchTracks;
// 2026-11-13：按用户参考图一（Apple Music 专辑页）补三块 web 版没有的信息层。
// 数据全部来自现有 /api（不新增后端路径）：曲目数/时长已在 album，其他作品走 /api/lib/albums。
@property (nonatomic, strong) NSTextField *footerCount;      // "N 首歌曲，X 分钟"
@property (nonatomic, strong) NSTextField *footerCopyright;  // "℗ 年份"（后端没有厂牌字段，不编造）
@property (nonatomic, strong) NSTextField *otherWorksTitle;  // "「艺人」的其他作品 ›"
@property (nonatomic, strong) NSScrollView *otherWorksScroll;// 横向滚动的封面卡片行
@property (nonatomic, strong) NSView *otherWorksRow;
@property (nonatomic, strong) NSMutableArray<NSButton *> *otherWorksCards;
@property (nonatomic) BOOL otherWorksLoaded;
- (void)layoutColumns;
- (void)layoutAlbum;
- (void)loadAlbumSummary;
- (void)loadOtherWorks;
- (void)renderOtherWorks:(NSArray<RLPAlbum *> *)works;
- (void)onOpenOtherWork:(NSButton *)sender;
@end

@implementation RLPAlbumDetailViewController

- (instancetype)initWithAlbumKey:(NSString *)key {
    self = [super initWithTitle:RLPTr(@"专辑")];
    if (self) _albumKey = [key copy];
    return self;
}

- (BOOL)usesPageHeaderSpacing { return NO; }

- (void)buildContent {
    RLPTheme *t = [RLPTheme current];
    self.pageScroll = [[NSScrollView alloc] initWithFrame:self.contentView.bounds];
    self.pageScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.pageScroll.drawsBackground = NO;
    self.pageScroll.hasVerticalScroller = YES;
    self.pageScroll.autohidesScrollers = YES;
    self.albumDocument = [[RLPAlbumDocumentView alloc] initWithFrame:NSMakeRect(0,0,954,620)];
    self.pageScroll.documentView = self.albumDocument;
    [self.contentView addSubview:self.pageScroll];
    NSView *host = self.albumDocument;
    self.cover = [[RLPCoverImageView alloc] initWithFrame:NSZeroRect];
    self.cover.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.cover.wantsLayer = YES;
    self.cover.layer.cornerRadius = 12;
    self.cover.layer.masksToBounds = YES;
    self.cover.layer.borderWidth = 1;
    [host addSubview:self.cover];
    self.coverPlaceholder = RLPLabel(@"?", [NSFont systemFontOfSize:46 weight:NSFontWeightHeavy],t.phText);
    self.coverPlaceholder.alignment = NSTextAlignmentCenter;
    [self.cover addSubview:self.coverPlaceholder];
    self.kindLabel = RLPLabel(@"ALBUM", [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold], t.mut2);
    self.kindLabel.attributedStringValue = [[NSAttributedString alloc] initWithString:@"ALBUM" attributes:@{NSFontAttributeName:self.kindLabel.font, NSForegroundColorAttributeName:t.mut2, NSKernAttributeName:@1.4}];
    self.nameLabel = RLPLabel(@"", [NSFont systemFontOfSize:26 weight:NSFontWeightBold], t.text);
    self.nameLabel.maximumNumberOfLines = 1;
    self.nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.artistLabel = RLPLabel(@"",t.small,t.mut);
    self.artistLabel.hidden = YES;
    self.metaLabel = RLPLabel(@"",[NSFont systemFontOfSize:12.5],t.mut);
    for(NSView *v in @[self.kindLabel,self.nameLabel,self.artistLabel,self.metaLabel]) [host addSubview:v];
    NSArray *titles = @[RLPTr(@"播放整张"),RLPTr(@"加入队列"),RLPTr(@"设置封面"),RLPTr(@"随机播放")];
    SEL actions[] = {@selector(onPlayAll:),@selector(onEnqueueAlbum:),@selector(onSetCover:),@selector(onShuffle:)};
    NSMutableArray *buttons = [NSMutableArray array];
    for(NSUInteger i=0;i<4;i++) {
        // 图一：随机是**圆形图标键**（不是胶囊文字键），播放是深色胶囊主键，其余是描边胶囊。
        const BOOL circular = (i==3);
        RLPAlbumButton *b = [RLPAlbumButton buttonWithTitle:circular?@"":titles[i]
                                                     target:self action:actions[i]];
        b.primary=i==0;
        b.bordered = NO;
        b.font = [NSFont systemFontOfSize:12 weight:i==0?NSFontWeightSemibold:NSFontWeightRegular];
        b.wantsLayer = YES;
        b.layer.cornerRadius = circular?16:8;
        b.cornerRadius = circular?16:8;
        b.layer.borderWidth = i==0?0:1;
        if (circular) {
            b.image = [NSImage imageWithSystemSymbolName:@"shuffle" accessibilityDescription:titles[i]];
            b.imagePosition = NSImageOnly;
            b.imageScaling = NSImageScaleProportionallyDown;
            b.toolTip = titles[i];          // 文字没了，语义进 tooltip（判据仍认得这个键）
            b.identifier = @"album.shuffle";
        }
        [host addSubview:b]; [buttons addObject:b];
    }
    self.heroButtons = buttons;
    self.playAllBtn = buttons[0];
    self.playAllBtn.image = [NSImage imageWithSystemSymbolName:@"play.fill" accessibilityDescription:RLPTr(@"播放整张")];
    self.playAllBtn.imagePosition = NSImageLeading;
    self.tracksTitle = RLPLabel(RLPTr(@"曲目列表"),[NSFont systemFontOfSize:11 weight:NSFontWeightBold],t.mut2);
    self.tracksMeta = RLPLabel(@"",[NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightRegular],t.mut);
    self.tracksMeta.alignment = NSTextAlignmentRight;
    self.emptyLabel = RLPLabel(@"",t.body,t.mut);
    self.progressLabel = RLPLabel(@"",[NSFont systemFontOfSize:11],t.mut2);
    self.progressLabel.hidden = YES;
    self.listRule = [[NSView alloc] init]; self.listRule.wantsLayer = YES;
    for(NSView *v in @[self.tracksTitle,self.tracksMeta,self.emptyLabel,self.progressLabel,self.listRule]) [host addSubview:v];
    self.table = [[RLPTrackActionTableView alloc] initWithFrame:NSZeroRect];
    self.table.backgroundColor = NSColor.clearColor;
    self.table.headerView = nil;
    self.table.rowHeight = 38;
    self.table.intercellSpacing = NSMakeSize(8,0);
    self.table.dataSource = self; self.table.delegate = self;
    self.table.target = self;
    self.table.action = @selector(onRowDoubleClick:);
    self.table.doubleAction = @selector(onRowDoubleClick:);
    for(NSString *ident in @[@"n",@"fav",@"title",@"artist",@"format",@"dur",@"add"]) {
        NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:ident];
        c.minWidth=0; c.maxWidth=10000; c.resizingMask=NSTableColumnNoResizing;
        [self.table addTableColumn:c];
    }
    self.table.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
    __weak __typeof__(self) weakSelf = self;
    ((RLPTrackActionTableView *)self.table).pathForRow = ^NSString *(NSInteger row) {
        __typeof__(self) owner=weakSelf;
        return row>=0 && row<(NSInteger)owner.tracks.count ? owner.tracks[row].path:nil;
    };
    self.scroll = [[RLPForwardingScrollView alloc] initWithFrame:NSZeroRect];
    self.scroll.drawsBackground = NO;
    self.scroll.hasVerticalScroller = NO;
    self.scroll.documentView = self.table;
    [host addSubview:self.scroll];
    self.summaryCard = [[NSView alloc] init]; self.summaryCard.wantsLayer = YES;
    self.summaryCard.layer.cornerRadius = 12; self.summaryCard.layer.borderWidth=1;
    self.summaryCard.hidden = YES;
    self.summaryLabel = RLPLabel(@"",[NSFont systemFontOfSize:12.5],t.mut2);
    self.summaryLabel.maximumNumberOfLines=0;
    self.summaryLabel.lineBreakMode=NSLineBreakByWordWrapping;
    self.summaryLabel.selectable=YES;
    [self.summaryCard addSubview:self.summaryLabel]; [host addSubview:self.summaryCard];
    self.favoritePaths=[NSMutableSet set];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onExternalFavoritesChanged:)
                                                 name:RLPFavoritesChangedNotification
                                               object:nil];
    [self.summaryCard addGestureRecognizer:[[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(onSummaryRetry:)]];

    // ---- 图一信息层（发布信息 + 其他作品）----
    // 曲目表下方先给"N 首歌曲，X 分钟"，再给版权行（℗）。后端 /api/lib/album 没有厂牌字段，
    // 所以只写 ℗ 年份 —— 不编造一个不存在的厂牌（如实挂账：厂牌缺失是数据层缺口，不是排版缺口）。
    self.footerCount = RLPLabel(@"", t.small, t.mut2);
    self.footerCopyright = RLPLabel(@"", t.small, t.mut2);
    self.otherWorksTitle = RLPLabel(@"", [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold], t.text);
    self.otherWorksTitle.identifier = @"album.otherworks.title";
    self.otherWorksScroll = [[RLPForwardingScrollView alloc] initWithFrame:NSZeroRect];
    self.otherWorksScroll.drawsBackground = NO;
    self.otherWorksScroll.hasHorizontalScroller = NO;
    self.otherWorksScroll.hasVerticalScroller = NO;
    self.otherWorksScroll.identifier = @"album.otherworks";
    self.otherWorksRow = [[NSView alloc] initWithFrame:NSZeroRect];
    self.otherWorksScroll.documentView = self.otherWorksRow;
    self.otherWorksCards = [NSMutableArray array];
    self.footerCount.identifier = @"album.footer.count";
    self.footerCopyright.identifier = @"album.footer.copyright";
    for (NSView *v in @[self.footerCount, self.footerCopyright, self.otherWorksTitle, self.otherWorksScroll])
        [host addSubview:v];
    [self applyTheme]; [self layoutAlbum];
}

- (void)layoutAlbum {
    CGFloat w = MAX(0,self.pageScroll.contentSize.width), right = MAX(0,w-44);
    self.cover.frame=NSMakeRect(22,22,168,168);
    self.coverPlaceholder.frame=NSMakeRect(0,56,168,56);
    CGFloat x=210, infoWidth=MAX(0,w-x-22);
    self.kindLabel.frame=NSMakeRect(x,64,infoWidth,13);
    self.nameLabel.frame=NSMakeRect(x,82,infoWidth,32);
    self.metaLabel.frame=NSMakeRect(x,121,infoWidth,17);
    CGFloat bx=x;
    for(NSButton *b in self.heroButtons) {
        // 圆形图标键固定 32x32（图一）；文字键按标题宽度算。
        CGFloat bw;
        if ([b.identifier isEqualToString:@"album.shuffle"]) bw=32;
        else bw=ceil([b.title sizeWithAttributes:@{NSFontAttributeName:b.font}].width)+26+(b.image?15:0);
        b.frame=NSMakeRect(bx,153,bw,32); bx+=bw+(bw==32?8:4);
    }
    CGFloat progressHeight=self.progressLabel.hidden?0:29;
    self.progressLabel.frame=NSMakeRect(22,212,right,17);
    CGFloat listTop=210+progressHeight;
    self.tracksTitle.frame=NSMakeRect(26,listTop+2,160,16);
    self.tracksMeta.frame=NSMakeRect(MAX(190,w-330),listTop+2,304,16);
    self.listRule.frame=NSMakeRect(22,listTop+25,right,1);
    CGFloat tableHeight=self.tracks.count*38;
    self.scroll.frame=NSMakeRect(52,listTop+30,MAX(0,w-104),tableHeight);
    self.table.frame=NSMakeRect(0,0,self.scroll.contentSize.width,tableHeight);
    self.emptyLabel.frame=NSMakeRect(26,listTop+38,right,22);
    CGFloat summaryTop=listTop+30+tableHeight+32;
    CGFloat summaryHeight=0;
    if(!self.summaryCard.hidden) {
        NSRect text=[self.summaryLabel.stringValue boundingRectWithSize:NSMakeSize(MAX(1,right-36),CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin attributes:@{NSFontAttributeName:self.summaryLabel.font}];
        summaryHeight=MAX(48,ceil(text.size.height)+28);
    }
    self.summaryCard.frame=NSMakeRect(22,summaryTop,right,summaryHeight);
    self.summaryLabel.frame=NSMakeRect(18,14,MAX(0,right-36),MAX(0,summaryHeight-28));
    // ---- 图一信息层：曲目表下方 发布信息 → 其他作品 ----
    // 顺序按参考图一：先是 "N 首歌曲，X 分钟"，再一行 "℗ 年份"，然后是"其他作品"横排。
    CGFloat footerTop=summaryTop+summaryHeight+(summaryHeight>0?18:0);
    self.footerCount.frame=NSMakeRect(22,footerTop,right,17);
    self.footerCopyright.frame=NSMakeRect(22,footerTop+19,right,17);
    CGFloat otherTop=footerTop+40;
    const CGFloat cardW=132, cardH=cardW+46, rowH=cardH+8;
    if (self.otherWorksTitle.hidden) {
        self.otherWorksTitle.frame=NSZeroRect;
        self.otherWorksScroll.frame=NSZeroRect;
    } else {
        self.otherWorksTitle.frame=NSMakeRect(22,otherTop,right,20);
        self.otherWorksScroll.frame=NSMakeRect(22,otherTop+26,right,rowH);
        const CGFloat x0=0, step=cardW+14;
        for (NSUInteger i=0;i<self.otherWorksCards.count;i++) {
            NSButton *card=self.otherWorksCards[i];
            card.frame=NSMakeRect(x0+i*step,0,cardW,cardH);
        }
        self.otherWorksRow.frame=NSMakeRect(0,0,MAX(right,self.otherWorksCards.count*step),rowH);
        otherTop+=26+rowH+10;
    }
    self.albumDocument.frame=NSMakeRect(0,0,w,MAX(self.pageScroll.contentSize.height,otherTop+24));
    [self layoutColumns];
}

- (void)activate {
    if (!self.loaded) [self reloadData];
    [self refreshPlaybackStatus];
    [self layoutAlbum];
}

- (void)layoutColumns {
    NSTableView *tv=self.table;
    CGFloat viewport=self.view.window?self.view.window.contentView.bounds.size.width:self.view.bounds.size.width+226;
    CGFloat ratio=viewport<=1120?1/.9:(viewport<=1400?1.8:1.6);
    CGFloat format=viewport<=1400?0:92;
    // A column mutation can grow NSTableView itself. Never feed that width back.
    CGFloat available=self.scroll.contentSize.width;
    // The web track track is a CSS grid, so it spends gaps as well as tracks.
    // Body has seven tracks and six 8pt intercell gaps; forgetting the gaps
    // pushed the duration/add tracks 8pt past the scroll clip at 1180.
    CGFloat gaps=(CGFloat)(tv.numberOfColumns>1?tv.numberOfColumns-1:0)*tv.intercellSpacing.width;
    CGFloat flex=MAX(0,available-28-24-58-26-format-56-gaps);
    NSArray *widths=@[@28,@24,@(flex*ratio/(ratio+1)),@(flex/(ratio+1)),@(format),@58,@26];
    for(NSUInteger i=0;i<MIN(widths.count,tv.tableColumns.count);i++) {
        NSTableColumn *c=tv.tableColumns[i]; c.minWidth=0; c.maxWidth=10000;
        c.width=[widths[i] doubleValue];
    }
    tv.frame=NSMakeRect(0,0,available,tv.frame.size.height);
}
- (void)viewDidLayout { [super viewDidLayout]; [self layoutAlbum]; }

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
        if(totalDur<=0)totalDur=album.duration;
        album.duration=totalDur;
        // 与 web 同口径：艺术家 · 年份 · N 首 · 总时长
        NSMutableArray<NSString *> *mi = [NSMutableArray array];
        if (album.artist.length) [mi addObject:album.artist];
        if (album.year > 0) [mi addObject:[NSString stringWithFormat:@"%ld", (long)album.year]];
        [mi addObject:[NSString stringWithFormat:@"%ld %@", (long)self_.tracks.count, RLPTr(@"首")]];
        [mi addObject:RLPFmtDuration(totalDur)];
        self_.metaLabel.stringValue = [mi componentsJoinedByString:@" · "];
        self_.tracksMeta.stringValue = [NSString stringWithFormat:@"%ld %@ · %@ %@",
            (long)self_.tracks.count, RLPTr(@"首"), RLPTr(@"总时长"), RLPFmtDuration(totalDur)];
        [self_ refreshPlaybackStatus];
        [self_ setSubtitle:[NSString stringWithFormat:@"%ld %@", (long)self_.tracks.count, RLPTr(@"首")]];

        self_.emptyLabel.stringValue = self_.tracks.count ? @"" : RLPTr(@"没有曲目");
        // ---- 图一信息层：曲目数/时长 + ℗ 年份（后端无厂牌字段，只写年份，不编造）----
        self_.footerCount.stringValue = [NSString stringWithFormat:@"%ld %@，%@",
            (long)self_.tracks.count, RLPTr(@"首歌曲"), RLPFmtDuration(totalDur)];
        // 后端 /api/lib/album 没有厂牌/发行日期字段 ⟹ copyright 只由年份构成；
        // 年份也没有时整行隐藏，而不是写一个 "℗" 孤零零挂着。
        if (album.year > 0) {
            self_.footerCopyright.stringValue = [NSString stringWithFormat:@"\u2117 %ld", (long)album.year];
            self_.footerCopyright.hidden = NO;
        } else {
            self_.footerCopyright.stringValue = @"";
            self_.footerCopyright.hidden = YES;
        }
        [self_.table reloadData];
        self_.coverPlaceholder.stringValue = album.name.length ? [[album.name substringToIndex:1] uppercaseString] : @"?";
        [self_ layoutAlbum];
        [self_ loadAlbumSummary];
        [self_ loadOtherWorks];

        if (album.hasCover) {
            [[RLPCoverLoader shared] coverForAlbumKey:album.key completion:^(NSImage * _Nullable img) {
                if (img) { self_.cover.image = img; self_.coverPlaceholder.hidden=YES; }
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
    RLPAlbumTrackCell *cell=[tableView makeViewWithIdentifier:ident owner:self];
    if(!cell) { cell=[[RLPAlbumTrackCell alloc] initWithFrame:NSMakeRect(0,0,col.width,tableView.rowHeight)];cell.identifier=ident; }
    // 收藏 / 入队是**按钮**列（web 每行都有空心爱心与「+」）
    if ([ident isEqualToString:@"fav"] || [ident isEqualToString:@"add"]) {
        NSButton *b = (NSButton *)cell.content;
        if (!b) {
            b = [NSButton buttonWithTitle:@"" target:self
                        action:[ident isEqualToString:@"fav"] ? @selector(onRowFav:) : @selector(onRowAdd:)];
            cell.content=b; [cell addSubview:b];
            b.bordered = NO;
            b.imagePosition = NSImageOnly;
            b.imageScaling = NSImageScaleProportionallyDown;
        }
        b.tag = row;
        // web 行内图标是 13px 量级（.add-btn / 爱心 svg）；默认符号尺寸偏大，
        // 会与 12.5px 的曲名在视觉上"不齐"。
        if ([ident isEqualToString:@"fav"]) {
            NSImageSymbolConfiguration *cfg =
                [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightRegular];
            const BOOL isFav = [self.favoritePaths containsObject:RLPFavNormalizePath(tr.path)];
            b.image = [[NSImage imageWithSystemSymbolName:isFav?@"heart.fill":@"heart" accessibilityDescription:RLPTr(@"收藏")]
                       imageWithSymbolConfiguration:cfg];
            b.contentTintColor = isFav?t.accent:t.mut2;
            b.toolTip = RLPTr(@"收藏");
        } else {
            NSImageSymbolConfiguration *cfg =
                [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightRegular];
            b.image = [[NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:RLPTr(@"加入队列")]
                       imageWithSymbolConfiguration:cfg];
            b.contentTintColor = t.mut;
            b.toolTip = RLPTr(@"加入队列");
        }
        [cell setNeedsLayout:YES]; [cell layoutSubtreeIfNeeded];
        return cell;
    }
    NSTextField *label = (NSTextField *)cell.content;
    if (!label) {
        label = RLPLabel(@"", [NSFont systemFontOfSize:12.5], t.text);
        label.translatesAutoresizingMaskIntoConstraints=YES;
        cell.content=label;cell.textField=label; [cell addSubview:label];
    }
    // 字体/对齐逐项照 web：曲名 12.5、艺术家/时长 11.5、序号右对齐、时长右对齐。
    if ([ident isEqualToString:@"n"]) {
        label.font = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightRegular];
        label.alignment = NSTextAlignmentRight;
        label.stringValue = [NSString stringWithFormat:@"%ld", (long)(tr.number > 0 ? tr.number : row + 1)];
        label.textColor = t.mut;
    } else if ([ident isEqualToString:@"title"]) {
        label.font = [NSFont systemFontOfSize:12.5];
        label.alignment = NSTextAlignmentLeft;
        label.stringValue = tr.title.length ? tr.title : RLPTr(@"未命名曲目");
        label.textColor = t.text;
    } else if ([ident isEqualToString:@"artist"]) {
        label.font = [NSFont systemFontOfSize:11.5];
        label.alignment = NSTextAlignmentLeft;
        label.stringValue = tr.artist.length ? tr.artist : (self.album.artist ?: @"");
        label.textColor = t.mut;
    } else if ([ident isEqualToString:@"format"]) {
        label.font=[NSFont systemFontOfSize:9.5]; label.alignment=NSTextAlignmentRight;
        label.stringValue=(tr.sampleRate>0 ? [NSString stringWithFormat:@"%g kHz / %ld bit",tr.sampleRate/1000.0,(long)tr.bits] : @""); label.textColor=t.accentText;
    } else {
        label.font = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightRegular];
        label.alignment = NSTextAlignmentRight;
        label.stringValue = RLPFmtDuration(tr.duration);
        label.textColor = t.mut;
    }
    [cell setNeedsLayout:YES]; [cell layoutSubtreeIfNeeded];
    return cell;
}

/// 共享右键菜单的动作入口。
- (void)rlp_trackMenuAction:(NSMenuItem *)sender {
    RLPHandleTrackAction(sender, self.view);
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)onExternalFavoritesChanged:(NSNotification *)note {
    if (note.object == self) return;
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/fav/list" completion:^(NSDictionary *json) {
        __typeof__(self) owner = weakSelf;
        if (!owner) return;
        [owner.favoritePaths removeAllObjects];
        if ([json[@"files"] isKindOfClass:NSArray.class]) {
            for (id path in json[@"files"]) {
                if ([path isKindOfClass:NSString.class]) [owner.favoritePaths addObject:RLPFavNormalizePath(path)];
                else if ([path isKindOfClass:NSDictionary.class] && [path[@"file"] isKindOfClass:NSString.class])
                    [owner.favoritePaths addObject:RLPFavNormalizePath(path[@"file"])];
            }
        }
        [owner.table reloadData];
    }];
}

/// 单曲收藏（/api/fav?file=…&on=1，与 web 行内爱心同一端点）。
- (void)onRowFav:(NSButton *)sender {
    const NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)self.tracks.count) return;
    RLPTrack *tr = self.tracks[(NSUInteger)row];
    NSString *normPath = RLPFavNormalizePath(tr.path);
    BOOL wasFavorite=[self.favoritePaths containsObject:normPath];
    NSString *url = [NSString stringWithFormat:@"/api/fav?file=%@&on=%d", RLPEnc(tr.path),wasFavorite?0:1];
    [[RLPCoreClient shared] postJSON:url body:@"" completion:^(NSDictionary * _Nullable json) {
        if (json && [json[@"ok"] boolValue]) {
            if(wasFavorite)[self.favoritePaths removeObject:normPath];else [self.favoritePaths addObject:normPath];
            [self.table reloadData];
            RLPToast(wasFavorite ? RLPTr(@"已取消收藏") : RLPTr(@"已收藏"));
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPFavoritesChangedNotification object:self];
        } else RLPToast(RLPTr(@"收藏失败"));
    }];
}

/// 单曲入队（/api/add，不打断当前播放）。CUE 分轨携带 cue_start/cue_end。
- (void)onRowAdd:(NSButton *)sender {
    const NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)self.tracks.count) return;
    RLPTrack *tr = self.tracks[(NSUInteger)row];
    if (tr.cueStart >= 0) RLPEnqueuePathCue(tr.path, tr.cueStart, tr.cueEnd);
    else RLPEnqueuePath(tr.path);
}

- (nullable NSDictionary<NSString *, NSNumber *> *)rlp_cueRangeForRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.tracks.count) return nil;
    RLPTrack *tr = self.tracks[(NSUInteger)row];
    if (tr.cueStart < 0) return nil;
    return @{ @"cs": @(tr.cueStart), @"ce": @(tr.cueEnd) };
}

- (void)onRowDoubleClick:(id)sender {
    (void)sender;
    NSInteger row = self.table.clickedRow;
    if (row < 0) row = self.table.selectedRow;
    if (row < 0 || row >= (NSInteger)self.tracks.count) return;
    RLPTrack *tr = self.tracks[(NSUInteger)row];
    if (tr.cueStart >= 0) RLPPlayAlbumCue(self.albumKey, row, tr.cueStart, tr.cueEnd);
    else RLPPlayAlbum(self.albumKey, row);
}

- (void)onPlayAll:(id)sender {
    if(![RLPCoreClient shared].started)return;
    __weak __typeof__(self) weakSelf=self;
    [[RLPCoreClient shared] getJSON:@"/api/status" completion:^(NSDictionary *json){
        __typeof__(self) owner=weakSelf; if(!owner)return;
        RLPPlaybackStatus *status=[RLPPlaybackStatus statusFromJSON:json];
        BOOL same=NO; for(RLPTrack *track in owner.tracks)if([track.path isEqual:status.currentPath])same=YES;
        if(same && (status.playing||status.paused)) RLPPostJSON(status.paused?@"/api/pause?on=0":@"/api/pause?on=1",nil);
        else RLPPlayAlbum(owner.albumKey,0);
        [owner refreshPlaybackStatus];
    }];
}

- (void)refreshPlaybackStatus {
    if(![RLPCoreClient shared].started)return;
    __weak __typeof__(self) weakSelf=self;
    [[RLPCoreClient shared] getJSON:@"/api/status" completion:^(NSDictionary *json){
        __typeof__(self) owner=weakSelf; if(!owner)return;
        owner.playbackStatus=[RLPPlaybackStatus statusFromJSON:json];
        BOOL same=NO;for(RLPTrack *track in owner.tracks)if([track.path isEqual:owner.playbackStatus.currentPath])same=YES;
        BOOL active=same&&(owner.playbackStatus.playing||owner.playbackStatus.paused);
        BOOL pause=active&&!owner.playbackStatus.paused;
        owner.playAllBtn.title=RLPTr(active?(pause?@"暂停":@"继续播放"):@"播放整张");
        owner.playAllBtn.image=[NSImage imageWithSystemSymbolName:pause?@"pause.fill":@"play.fill" accessibilityDescription:owner.playAllBtn.title];
        [owner layoutAlbum];
    }];
    [[RLPCoreClient shared] getJSON:@"/api/fav/list" completion:^(NSDictionary *json){
        __typeof__(self) owner=weakSelf;if(!owner)return;
        [owner.favoritePaths removeAllObjects];
        if([json[@"files"] isKindOfClass:NSArray.class]) for(id path in json[@"files"]) {
            if([path isKindOfClass:NSString.class]) [owner.favoritePaths addObject:RLPFavNormalizePath(path)];
            else if([path isKindOfClass:NSDictionary.class] && [path[@"file"] isKindOfClass:NSString.class])
                [owner.favoritePaths addObject:RLPFavNormalizePath(path[@"file"])];
        }
        [owner.table reloadData];
    }];
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
    if(!self.tracks.count || ![RLPCoreClient shared].started)return;
    __weak __typeof__(self) weakSelf=self;
    const uint64_t actionEpoch = RLPBeginPlaybackAction();
    NSString *albumKey = [self.albumKey copy];
    const NSUInteger start = arc4random_uniform((uint32_t)self.tracks.count);
    [[RLPCoreClient shared] postJSON:@"/api/playmode?mode=3" body:nil completion:^(NSDictionary *json){
        __typeof__(self) owner=weakSelf;
        if (!owner || actionEpoch != RLPPlaybackActionEpoch()) return;
        if (!json || ![json[@"ok"] boolValue]) {
            NSString *err = [json[@"error"] isKindOfClass:NSString.class] ? json[@"error"] : nil;
            RLPToast(err.length ? err : RLPTr(@"切换随机播放失败"));
            return;
        }
        RLPPlayAlbum(albumKey, (NSInteger)start);
    }];
}

- (void)onBack:(id)sender {
    RLPRequestBack();
}


// Optional release summary and track prefetch use the same backend endpoints as openAlbum.
- (void)fetchSummaryURL:(NSString *)url generation:(NSUInteger)generation attempt:(NSUInteger)attempt completion:(void (^)(NSDictionary *))completion {
    __weak __typeof__(self) weakSelf=self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary *json) {
        __typeof__(self) owner=weakSelf;
        if(!owner || owner.metadataGeneration!=generation) return;
        if([json[@"pending"] boolValue] && attempt<120) {
            double wait=[json[@"retryAfterMs"] doubleValue]/1000.0;
            wait=MAX(.15,MIN(2,wait>0?wait:2));
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(wait*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                [weakSelf fetchSummaryURL:url generation:generation attempt:attempt+1 completion:completion];
            });
        } else completion(json ?: @{});
    }];
}
- (void)loadAlbumSummary {
    NSUInteger generation=++self.metadataGeneration;
    __weak __typeof__(self) weakSelf=self;
    [[RLPCoreClient shared] getJSON:@"/api/settings" completion:^(NSDictionary *settings) {
        __typeof__(self) owner=weakSelf;
        if(!owner || owner.metadataGeneration!=generation) return;
        NSDictionary *kv=[settings[@"kv"] isKindOfClass:NSDictionary.class]?settings[@"kv"]:settings;
        if(![kv[@"metasummary"] boolValue]) { owner.summaryCard.hidden=YES; owner.progressLabel.hidden=YES; [owner layoutAlbum]; return; }
        owner.summaryCard.hidden=NO;
        owner.summaryLabel.stringValue=RLPTr(@"正在整理资料…");
        [owner layoutAlbum];
        NSString *url=[NSString stringWithFormat:@"/api/entity/summary?kind=release&name=%@&artist=%@&lang=zh",RLPEnc(owner.album.name),RLPEnc(owner.album.artist ?: @"")];
        [owner fetchSummaryURL:url generation:generation attempt:0 completion:^(NSDictionary *json) {
            [weakSelf renderAlbumSummary:json];
        }];
        [[RLPCoreClient shared] getJSON:@"/api/status" completion:^(NSDictionary *status) {
            __typeof__(self) current=weakSelf;
            if(!current || current.metadataGeneration!=generation || !([status[@"hasLlmKey"] boolValue] || [status[@"summaryEnabled"] boolValue])) return;
            NSPredicate *hasTitle=[NSPredicate predicateWithBlock:^BOOL(RLPTrack *track,NSDictionary *bindings){return track.title.length>0;}];
            current.prefetchTracks=[current.tracks filteredArrayUsingPredicate:hasTitle];
            current.prefetchNext=0; current.prefetchDone=0; current.prefetchActive=0;
            [current pumpAlbumPrefetch:generation];
        }];
    }];
}
- (void)onSummaryRetry:(id)sender {
    if([self.summaryLabel.stringValue containsString:RLPTr(@"点击重试")]) [self loadAlbumSummary];
}
- (void)loadOtherWorks {
    if (!self.album || ![RLPCoreClient shared].started) return;
    // 与艺术家页同一份数据源（/api/lib/albums），按 RLPSplitArtistNames 匹配，
    // 排除当前专辑自己 —— 不新增后端端点，也不在 UI 里复制一份曲库。
    NSString *artist = self.album.artist ?: @"";
    NSString *selfKey = self.album.key ?: @"";
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/lib/albums" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray<RLPAlbum *> *all = [RLPAlbum albumsFromJSON:json];
        NSArray<NSString *> *want = RLPSplitArtistNames(artist);
        NSMutableArray<RLPAlbum *> *works = [NSMutableArray array];
        for (RLPAlbum *a in all) {
            if (!a.key.length || [a.key isEqualToString:selfKey]) continue;
            NSArray<NSString *> *have = RLPSplitArtistNames(a.artist);
            BOOL hit = NO;
            for (NSString *w in want) for (NSString *h in have)
                if ([w caseInsensitiveCompare:h] == NSOrderedSame) { hit = YES; break; }
            if (hit) [works addObject:a];
            if (works.count >= 12) break;
        }
        [self_ renderOtherWorks:works];
    }];
}

- (void)renderOtherWorks:(NSArray<RLPAlbum *> *)works {
    for (NSButton *c in self.otherWorksCards) [c removeFromSuperview];
    [self.otherWorksCards removeAllObjects];
    self.otherWorksLoaded = YES;
    if (!works.count) {
        // 没有同艺人其它专辑时就整块隐藏 —— 不留一个空标题 + 空白条（图一里这块是有内容才出现）。
        self.otherWorksTitle.hidden = YES;
        self.otherWorksScroll.hidden = YES;
        [self layoutAlbum];
        return;
    }
    self.otherWorksTitle.hidden = NO;
    self.otherWorksScroll.hidden = NO;
    NSString *artist = self.album.artist.length ? self.album.artist : RLPTr(@"未知艺术家");
    // 图一的标题形如「HOYO-MIX のその他の作品 ›」：艺人名 + 其他作品 + 箭头。
    self.otherWorksTitle.stringValue = [NSString stringWithFormat:@"%@ %@ ›", artist, RLPTr(@"的其他作品")];
    for (RLPAlbum *a in works) {
        RLPOtherWorkCard *card = [[RLPOtherWorkCard alloc] initWithFrame:NSZeroRect];
        card.albumKey = a.key;
        card.identifier = @"album.workcard";
        // 占位底色必须在**建卡时**就上，不能等 applyTheme：
        // 卡片是异步数据回来后新建的，applyTheme 早已跑过 ⟹ 无封面的那张
        // 在页面停留期间一直是纯白块、连边框都没有（离屏截图实测）。
        {
            RLPTheme *t = [RLPTheme current];
            card.cover.layer.borderColor = t.line.CGColor;
            card.cover.layer.backgroundColor = t.cvBg.CGColor;
        }
        card.target = self;
        card.action = @selector(onOpenOtherWork:);
        card.toolTip = a.name;
        card.titleLabel.stringValue = a.name.length ? a.name : RLPTr(@"未知专辑");
        card.titleLabel.toolTip = a.name;
        NSMutableArray *sub = [NSMutableArray array];
        if (a.artist.length) [sub addObject:a.artist];
        if (a.year > 0) [sub addObject:[NSString stringWithFormat:@"%ld", (long)a.year]];
        card.subLabel.stringValue = [sub componentsJoinedByString:@" · "];
        if (a.hasCover) {
            __weak RLPOtherWorkCard *weakCard = card;
            NSString *key = a.key;
            [[RLPCoverLoader shared] coverForAlbumKey:key completion:^(NSImage * _Nullable img) {
                RLPOtherWorkCard *cc = weakCard;
                if (cc && img) cc.cover.image = img;
            }];
        }
        [self.otherWorksRow addSubview:card];
        [self.otherWorksCards addObject:card];
    }
    [self layoutAlbum];
}

- (void)onOpenOtherWork:(NSButton *)sender {
    NSString *key = [(RLPOtherWorkCard *)sender albumKey];
    if (!key.length) return;
    RLPRequestOpenAlbum(key);   // 与首页点专辑卡同一条路由（进详情页并压返回栈）
}

- (void)renderAlbumSummary:(NSDictionary *)json {
    self.summaryCard.hidden=NO;
    NSMutableArray<NSString *> *lines=[NSMutableArray array];
    NSDictionary *fields=[json[@"fields"] isKindOfClass:NSDictionary.class]?json[@"fields"]:@{};
    for(NSString *key in fields) {
        if([key isEqual:@"曲目列表"]) continue;
        id value=fields[key];
        if([value isKindOfClass:NSDictionary.class]) value=value[@"value"] ?: value[@"text"];
        if([value isKindOfClass:NSArray.class]) value=[value componentsJoinedByString:@" · "];
        if([value isKindOfClass:NSString.class] && [value length])
            [lines addObject:[NSString stringWithFormat:@"%@  %@",key,[key isEqual:@"时长"]?RLPFmtDuration(self.album.duration):value]];
    }
    if(!lines.count && [json[@"sections"] isKindOfClass:NSArray.class]) {
        for(NSDictionary *section in json[@"sections"]) {
            if(![section isKindOfClass:NSDictionary.class] || [section[@"heading"] isEqual:@"曲目列表"])continue;
            if([section[@"heading"] isKindOfClass:NSString.class]) [lines addObject:section[@"heading"]];
            if([section[@"paragraphs"] isKindOfClass:NSArray.class]) for(id p in section[@"paragraphs"]) {
                NSString *text=[p isKindOfClass:NSDictionary.class]?p[@"text"]:p;
                if([text isKindOfClass:NSString.class]) [lines addObject:text];
            }
        }
    }
    if(lines.count) {
        [lines insertObject:RLPTr(@"AI 整理") atIndex:0];
        self.summaryLabel.stringValue=[lines componentsJoinedByString:@"\n"];
    } else if([json[@"insufficient"] boolValue]) self.summaryLabel.stringValue=RLPTr(@"资料不足");
    else if(json[@"error"] || [json[@"pending"] boolValue]) self.summaryLabel.stringValue=RLPTr(@"资料整理失败 · 点击重试");
    else self.summaryCard.hidden=YES;
    [self layoutAlbum];
}
- (void)pumpAlbumPrefetch:(NSUInteger)generation {
    NSUInteger total=self.prefetchTracks.count;
    if(!total || generation!=self.metadataGeneration)return;
    self.progressLabel.hidden=NO;
    self.progressLabel.stringValue=self.prefetchDone==total?[NSString stringWithFormat:@"曲目资料已后台整理 %lu 首",(unsigned long)total]:[NSString stringWithFormat:@"正在后台整理曲目资料 %lu / %lu",(unsigned long)self.prefetchDone,(unsigned long)total];
    [self layoutAlbum];
    __weak __typeof__(self) weakSelf=self;
    while(self.prefetchActive<2 && self.prefetchNext<total) {
        RLPTrack *track=self.prefetchTracks[self.prefetchNext++]; self.prefetchActive++;
        NSString *url=[NSString stringWithFormat:@"/api/entity/summary?kind=track&name=%@&artist=%@&album=%@&file=%@&lang=zh",RLPEnc(track.title),RLPEnc(track.artist.length?track.artist:self.album.artist),RLPEnc(self.album.name),RLPEnc(track.path)];
        [self fetchSummaryURL:url generation:generation attempt:0 completion:^(NSDictionary *json){
            __typeof__(self) owner=weakSelf; if(!owner || owner.metadataGeneration!=generation)return;
            owner.prefetchDone++; owner.prefetchActive--; [owner pumpAlbumPrefetch:generation];
        }];
    }
    if(self.prefetchDone==total) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.6*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        __typeof__(self) owner=weakSelf; if(owner.metadataGeneration==generation){owner.progressLabel.hidden=YES;[owner layoutAlbum];}
    });
}

- (void)applyTheme {
    [super applyTheme];
    RLPTheme *t = [RLPTheme current];
    self.cover.layer.backgroundColor = t.cvBg.CGColor;
    self.cover.layer.borderColor = t.line.CGColor;
    self.coverPlaceholder.textColor=t.phText;
    self.listRule.layer.backgroundColor=t.line.CGColor;
    self.progressLabel.textColor=t.mut2;
    self.summaryCard.layer.backgroundColor=t.bg2.CGColor;
    self.summaryCard.layer.borderColor=t.line.CGColor;
    self.summaryLabel.textColor=t.mut2;
    for(NSButton *b in self.heroButtons) {
        b.layer.backgroundColor=(b==self.playAllBtn?t.accent:t.hov).CGColor;
        b.layer.borderColor=t.line.CGColor;
        b.contentTintColor=b==self.playAllBtn?NSColor.whiteColor:t.text;
    }
    self.nameLabel.textColor = t.text;
    self.kindLabel.textColor = t.mut2;
    self.tracksTitle.textColor = t.mut2;
    self.tracksMeta.textColor = t.mut;
    self.playAllBtn.layer.backgroundColor = t.accent.CGColor;
    self.playAllBtn.contentTintColor = NSColor.whiteColor;
    self.artistLabel.textColor = t.mut;
    self.metaLabel.textColor = t.mut;
    self.emptyLabel.textColor = t.mut;
    self.footerCount.textColor = t.mut2;
    self.footerCopyright.textColor = t.mut2;
    self.otherWorksTitle.textColor = t.text;
    for (RLPOtherWorkCard *c in self.otherWorksCards) {
        c.cover.layer.borderColor = t.line.CGColor;
        c.cover.layer.backgroundColor = t.cvBg.CGColor;
        c.titleLabel.textColor = t.text;
        c.subLabel.textColor = t.mut;
    }
    [self.table reloadData];
}

- (void)applyLanguage {
    NSArray *titles = @[@"播放整张", @"加入队列", @"设置封面", @"随机播放"];
    for (NSUInteger i = 0; i < self.heroButtons.count && i < titles.count; ++i) {
        self.heroButtons[i].title = RLPTr(titles[i]);
    }
    self.tracksTitle.stringValue = RLPTr(@"曲目列表");
    self.kindLabel.stringValue = RLPTr(@"专辑");
    if (self.album) {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        if (self.album.artist.length) [parts addObject:self.album.artist];
        if (self.album.year > 0) [parts addObject:[NSString stringWithFormat:@"%ld", (long)self.album.year]];
        [parts addObject:[NSString stringWithFormat:@"%ld %@", (long)self.tracks.count, RLPTr(@"首")]];
        [parts addObject:RLPFmtDuration(self.album.duration)];
        self.metaLabel.stringValue = [parts componentsJoinedByString:@" · "];
        self.tracksMeta.stringValue = [NSString stringWithFormat:@"%ld %@ · %@ %@",
            (long)self.tracks.count, RLPTr(@"首"), RLPTr(@"总时长"), RLPFmtDuration(self.album.duration)];
        self.footerCount.stringValue = [NSString stringWithFormat:@"%ld %@，%@",
            (long)self.tracks.count, RLPTr(@"首歌曲"), RLPFmtDuration(self.album.duration)];
        [self setSubtitle:[NSString stringWithFormat:@"%ld %@", (long)self.tracks.count, RLPTr(@"首")]];
        NSString *artist = self.album.artist.length ? self.album.artist : RLPTr(@"未知艺术家");
        self.otherWorksTitle.stringValue = [NSString stringWithFormat:@"%@ %@ ›", artist, RLPTr(@"的其他作品")];
        if (!self.tracks.count) self.emptyLabel.stringValue = RLPTr(@"没有曲目");
    }
    [self refreshPlaybackStatus];
}

@end