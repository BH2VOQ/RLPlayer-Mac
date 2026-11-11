// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPNowPlayingViewController.mm — 正在播放（纯 AppKit）
//
// 只读展示 + 少量动作（播放/暂停、收藏、体检）。歌词来自 /api/lyrics?file=…，
// 音质体检来自 /api/health?file=…（都是既有端点，UI 不重复实现分析）。
#import "RLPNowPlayingViewController.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPSupport.h"
#import "RLPTheme.h"
#import "RLPKnowledgeView.h"
#import "RLPAnalysisSummary.h"

@interface RLPNowPlayingViewController ()
@property (nonatomic, strong) NSTimer *poll;
@property (nonatomic) BOOL polling;
@property (nonatomic, copy) NSString *currentPath;
@property (nonatomic, strong) NSImageView *cover;
@property (nonatomic, strong) NSTextField *titleLabel2;
@property (nonatomic, strong) NSTextField *artistLabel2;
@property (nonatomic, strong) NSTextField *metaLabel;
@property (nonatomic, strong) NSTextView *lyricsView;
@property (nonatomic, strong) NSTextField *lyricsEmpty;
// ---- 音频分析：一行四元素（动态 / 音质 / 假无损 / 展开）----
@property (nonatomic, strong) NSView *anlRow;
@property (nonatomic, strong) NSButton *anlDyn;
@property (nonatomic, strong) NSButton *anlQual;
@property (nonatomic, strong) NSButton *anlFake;
@property (nonatomic, strong) NSButton *anlExpand;
@property (nonatomic, strong) NSScrollView *anlDetailScroll;
@property (nonatomic, strong) NSTextView *anlDetail;
@property (nonatomic, strong) NSButton *anlReanalyze;      // 只在展开后可见
@property (nonatomic, assign) RLPAnlLevel anlLevel;
@property (nonatomic, copy) NSDictionary *anlHealth;       // 后端给的原始结果（唯一真相）
@property (nonatomic, copy) NSString *anlPath;             // 结果对应的曲目
@property (nonatomic, copy) NSString *anlAutoDonePath;     // 每曲一次去重
@property (nonatomic, assign) BOOL anlBusy;
@property (nonatomic, assign) BOOL anlCached;              // 上次结果是缓存命中（只影响文案）
@property (nonatomic, copy) NSString *anlError;            // 上次失败原因（如实显示）
@property (nonatomic, assign) BOOL anlAutoEnabled;         // 来自 settings.autoanl
@property (nonatomic, assign) NSUInteger anlSeq;           // 丢弃过期回调
@property (nonatomic, strong) NSLayoutConstraint *anlDetailHeight;
/// 封面请求序号：快速切歌时用它丢弃过期回调（慢请求回来不能盖掉新封面）。
@property (nonatomic, assign) NSUInteger coverSeq;
@property (nonatomic, strong) RLPKnowledgeView *knowledge;
@end

@implementation RLPNowPlayingViewController

- (instancetype)init {
    self = [super initWithTitle:@"正在播放"];
    return self;
}

- (void)buildContent {
    RLPTheme *t = [RLPTheme current];
    NSView *host = self.contentView;

    self.cover = [[NSImageView alloc] initWithFrame:NSZeroRect];
    self.cover.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.cover.wantsLayer = YES;
    self.cover.layer.cornerRadius = 12;
    self.cover.layer.masksToBounds = YES;
    self.cover.layer.backgroundColor = t.bg2.CGColor;
    self.cover.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.cover];

    self.titleLabel2 = RLPLabel(@"", [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold], t.text);
    self.titleLabel2.maximumNumberOfLines = 2;
    self.titleLabel2.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.titleLabel2];

    self.artistLabel2 = RLPLabel(@"", [NSFont systemFontOfSize:14], t.mut);
    self.artistLabel2.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.artistLabel2];

    self.metaLabel = RLPLabel(@"", t.mono, t.mut);
    self.metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.metaLabel];

    NSButton *fav = [NSButton buttonWithTitle:RLPTr(@"收藏") target:self action:@selector(onFav:)];
    fav.bezelStyle = NSBezelStyleRounded;
    fav.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:fav];

    // 音频分析改为一行（1.1.7.1）：动态 / 音质 / 假无损 / 展开，四个元素同一行。
    // 「自动分析」开关已挪到设置·高级；「重新分析」只在展开后出现，不摆在面上。

    NSTextField *lyricsTitle = RLPLabel(@"歌词", [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], t.text);
    lyricsTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:lyricsTitle];

    self.lyricsView = [self makeTextView];
    NSScrollView *lyScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    lyScroll.drawsBackground = NO;
    lyScroll.hasVerticalScroller = YES;
    lyScroll.autohidesScrollers = YES;
    lyScroll.documentView = self.lyricsView;
    lyScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:lyScroll];

    self.lyricsEmpty = RLPLabel(@"", t.small, t.mut);
    self.lyricsEmpty.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.lyricsEmpty];

    // ---- 一行分析条 ----
    self.anlRow = [[NSView alloc] initWithFrame:NSZeroRect];
    self.anlRow.translatesAutoresizingMaskIntoConstraints = NO;
    self.anlRow.identifier = @"anl.row";
    [host addSubview:self.anlRow];

    self.anlDyn = [self anlChipWithIdentifier:@"anl.dyn" action:@selector(onAnlDyn:)];
    self.anlQual = [self anlChipWithIdentifier:@"anl.qual" action:@selector(onAnlQual:)];
    self.anlFake = [self anlChipWithIdentifier:@"anl.fake" action:@selector(onAnlFake:)];
    self.anlExpand = [NSButton buttonWithTitle:RLPTr(@"展开") target:self action:@selector(onAnlExpand:)];
    self.anlExpand.bezelStyle = NSBezelStyleRounded;
    self.anlExpand.identifier = @"anl.expand";
    self.anlExpand.translatesAutoresizingMaskIntoConstraints = NO;
    self.anlExpand.font = t.small;
    for (NSView *v in @[self.anlDyn, self.anlQual, self.anlFake, self.anlExpand])
        [self.anlRow addSubview:v];

    // ---- 展开后的详情（默认收起：高度 0 + hidden）----
    self.anlDetail = [self makeTextView];
    self.anlDetailScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.anlDetailScroll.drawsBackground = NO;
    self.anlDetailScroll.hasVerticalScroller = YES;
    self.anlDetailScroll.autohidesScrollers = YES;
    self.anlDetailScroll.documentView = self.anlDetail;
    self.anlDetailScroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.anlDetailScroll.hidden = YES;
    [host addSubview:self.anlDetailScroll];

    self.anlReanalyze = [NSButton buttonWithTitle:RLPTr(@"重新分析") target:self action:@selector(onAnlReanalyze:)];
    self.anlReanalyze.bezelStyle = NSBezelStyleRounded;
    self.anlReanalyze.font = t.small;
    self.anlReanalyze.translatesAutoresizingMaskIntoConstraints = NO;
    self.anlReanalyze.hidden = YES;   // 收起态不可见（用户要求不摆在面上）
    [host addSubview:self.anlReanalyze];

    self.anlDetailHeight = [self.anlDetailScroll.heightAnchor constraintEqualToConstant:0];

    // AI 资料层（知识卡 + 简介）：放在右栏下半，与音质体检分开
    self.knowledge = [[RLPKnowledgeView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    self.knowledge.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.knowledge];

    [NSLayoutConstraint activateConstraints:@[
        [self.cover.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:24],
        [self.cover.topAnchor constraintEqualToAnchor:host.topAnchor constant:8],
        [self.cover.widthAnchor constraintEqualToConstant:180],
        [self.cover.heightAnchor constraintEqualToConstant:180],

        [self.titleLabel2.leadingAnchor constraintEqualToAnchor:self.cover.trailingAnchor constant:20],
        [self.titleLabel2.topAnchor constraintEqualToAnchor:self.cover.topAnchor constant:6],
        [self.titleLabel2.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-24],
        [self.artistLabel2.leadingAnchor constraintEqualToAnchor:self.titleLabel2.leadingAnchor],
        [self.artistLabel2.topAnchor constraintEqualToAnchor:self.titleLabel2.bottomAnchor constant:8],
        [self.artistLabel2.trailingAnchor constraintEqualToAnchor:self.titleLabel2.trailingAnchor],
        [self.metaLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel2.leadingAnchor],
        [self.metaLabel.topAnchor constraintEqualToAnchor:self.artistLabel2.bottomAnchor constant:6],
        [self.metaLabel.trailingAnchor constraintEqualToAnchor:self.titleLabel2.trailingAnchor],
        [fav.leadingAnchor constraintEqualToAnchor:self.titleLabel2.leadingAnchor],
        [fav.topAnchor constraintEqualToAnchor:self.metaLabel.bottomAnchor constant:14],
        // 一行分析条：独占一行（收藏按钮下方），左对齐封面右缘、右到窗口边界。
        // 不与标题/收藏同行 —— 标题是可变长文本，会把这一行挤成 0 宽（判据 C2b 抓到的真缺陷）。
        [self.anlRow.leadingAnchor constraintEqualToAnchor:self.titleLabel2.leadingAnchor],
        [self.anlRow.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-24],
        [self.anlRow.topAnchor constraintEqualToAnchor:fav.bottomAnchor constant:10],
        [self.anlRow.heightAnchor constraintEqualToConstant:26],

        [self.anlDyn.leadingAnchor constraintEqualToAnchor:self.anlRow.leadingAnchor],
        [self.anlDyn.centerYAnchor constraintEqualToAnchor:self.anlRow.centerYAnchor],
        [self.anlQual.leadingAnchor constraintEqualToAnchor:self.anlDyn.trailingAnchor constant:8],
        [self.anlQual.centerYAnchor constraintEqualToAnchor:self.anlRow.centerYAnchor],
        [self.anlFake.leadingAnchor constraintEqualToAnchor:self.anlQual.trailingAnchor constant:8],
        [self.anlFake.centerYAnchor constraintEqualToAnchor:self.anlRow.centerYAnchor],
        [self.anlExpand.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.anlFake.trailingAnchor constant:8],
        [self.anlExpand.trailingAnchor constraintEqualToAnchor:self.anlRow.trailingAnchor],
        [self.anlExpand.centerYAnchor constraintEqualToAnchor:self.anlRow.centerYAnchor],
        // 摘要块等分剩余宽度；文字过长截断 + tooltip 全文（绝不换行成两行）。
        // 必须显式给宽度：无边框 NSButton 标题为空时内在宽度为 0，会整行塌成 0（判据 C2b 抓到的）。
        [self.anlQual.widthAnchor constraintEqualToAnchor:self.anlDyn.widthAnchor],
        [self.anlFake.widthAnchor constraintEqualToAnchor:self.anlDyn.widthAnchor],
        [self.anlExpand.widthAnchor constraintEqualToConstant:56],
        [self.anlDyn.widthAnchor constraintEqualToAnchor:self.anlRow.widthAnchor
                                             multiplier:(1.0 / 3.0) constant:-27],
        // 高度也必须显式给：无边框 NSButton 空标题时内在高度为 0 ⟹ 量得到宽度但看不见。
        [self.anlDyn.heightAnchor constraintEqualToConstant:22],
        [self.anlQual.heightAnchor constraintEqualToConstant:22],
        [self.anlFake.heightAnchor constraintEqualToConstant:22],

        [lyricsTitle.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:24],
        [lyricsTitle.topAnchor constraintEqualToAnchor:self.cover.bottomAnchor constant:18],
        [lyScroll.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:24],
        [lyScroll.topAnchor constraintEqualToAnchor:lyricsTitle.bottomAnchor constant:6],
        [lyScroll.bottomAnchor constraintEqualToAnchor:host.bottomAnchor constant:-12],
        [lyScroll.widthAnchor constraintEqualToAnchor:host.widthAnchor multiplier:0.5 constant:-36],
        [self.lyricsEmpty.leadingAnchor constraintEqualToAnchor:lyScroll.leadingAnchor],
        [self.lyricsEmpty.topAnchor constraintEqualToAnchor:lyScroll.topAnchor constant:4],

        // 右栏：展开的分析详情在上（收起时高度 0），AI 资料层在下
        [self.anlDetailScroll.leadingAnchor constraintEqualToAnchor:lyScroll.trailingAnchor constant:24],
        [self.anlDetailScroll.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-24],
        [self.anlDetailScroll.topAnchor constraintEqualToAnchor:lyricsTitle.topAnchor],
        self.anlDetailHeight,
        [self.anlReanalyze.leadingAnchor constraintEqualToAnchor:self.anlDetailScroll.leadingAnchor],
        [self.anlReanalyze.topAnchor constraintEqualToAnchor:self.anlDetailScroll.bottomAnchor constant:4],

        [self.knowledge.leadingAnchor constraintEqualToAnchor:self.anlDetailScroll.leadingAnchor],
        [self.knowledge.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-24],
        [self.knowledge.topAnchor constraintEqualToAnchor:self.anlDetailScroll.bottomAnchor constant:12],
        [self.knowledge.bottomAnchor constraintEqualToAnchor:lyScroll.bottomAnchor],
    ]];
}

- (NSTextView *)makeTextView {
    RLPTheme *t = [RLPTheme current];
    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 480, 240)];
    tv.editable = NO;
    tv.selectable = YES;
    tv.drawsBackground = NO;
    tv.font = t.body;
    tv.textColor = t.text;
    tv.textContainerInset = NSMakeSize(2, 6);
    tv.string = @"";
    return tv;
}

- (void)activate {
    [self startPolling];
}

- (void)viewDidDisappear {
    [self.knowledge cancelLoading];
    [super viewDidDisappear];
    [self stopPolling];
}

- (void)startPolling {
    if (self.polling) return;
    if (![RLPCoreClient shared].started) {
        [self setSubtitle:@"核心未启动"];
        return;
    }
    self.polling = YES;
    // 自动分析开关的真相源是 settings.autoanl（开关本身在设置·高级页签）。
    // 这里只读一次并缓存，避免每 0.8s 都拉一遍设置。
    {
        __weak __typeof__(self) ws = self;
        [[RLPCoreClient shared] getJSON:@"/api/settings" completion:^(NSDictionary * _Nullable json) {
            __typeof__(self) s = ws;
            if (!s) return;
            // 值在 kv 子对象里（读顶层会永远读成"关"）。
            NSDictionary *kv = [json[@"kv"] isKindOfClass:[NSDictionary class]] ? json[@"kv"] : json;
            id v = kv[@"autoanl"];
            s.anlAutoEnabled = [v isKindOfClass:[NSString class]] ? [v isEqualToString:@"1"]
                              : ([v isKindOfClass:[NSNumber class]] ? [v boolValue] : NO);
        }];
    }
    __weak __typeof__(self) weakSelf = self;
    self.poll = [NSTimer scheduledTimerWithTimeInterval:0.8 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf refresh];
    }];
    [self refresh];
}

- (void)stopPolling {
    [self.poll invalidate];
    self.poll = nil;
    self.polling = NO;
}

- (void)refresh {
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/status" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        RLPPlaybackStatus *st = [RLPPlaybackStatus statusFromJSON:json];
        if (!st) return;
        NSString *path = st.currentPath ?: @"";
        self_.titleLabel2.stringValue = path.length ? path.lastPathComponent.stringByDeletingPathExtension : RLPTr(@"未播放");
        self_.artistLabel2.stringValue = st.error.length ? st.error
            : (st.bitPerfect.length ? [NSString stringWithFormat:@"bit-perfect: %@", st.bitPerfect] : @"");
        self_.artistLabel2.textColor = st.error.length ? [RLPTheme current].danger : [RLPTheme current].mut;
        self_.metaLabel.stringValue = [NSString stringWithFormat:@"%@ / %@",
            RLPFmtDuration(st.position), RLPFmtDuration(st.duration)];
        if (![path isEqualToString:self_.currentPath ?: @""]) {
            self_.currentPath = path;
            [self_ loadLyricsForPath:path];
            [self_ loadCoverForPath:path];
            [self_ loadMetaAndKnowledgeForPath:path];
            // 切歌：清掉上一首的结果与层级，并按 settings.autoanl 自动分析一次（每曲一次）。
            self_.anlHealth = nil;
            self_.anlPath = nil;
            self_.anlSeq++;                 // 让上一首的在途回调作废
            self_.anlBusy = NO;
            [self_ anlOpenLevel:RLPAnlLevelCollapsed];
            const BOOL playing = st.playing && !st.paused;
            if (RLPAnlShouldAutoAnalyze(path, playing, self_.anlAutoEnabled,
                                        self_.anlAutoDonePath, NO, NO)) {
                self_.anlAutoDonePath = path;
                [self_ anlAnalyzePath:path force:NO];
            }
        }
    }];
}

- (void)loadLyricsForPath:(NSString *)path {
    if (!path.length) {
        self.lyricsView.string = @"";
        self.lyricsEmpty.stringValue = RLPTr(@"未在播放");
        return;
    }
    self.lyricsEmpty.stringValue = RLPTr(@"正在读取歌词…");
    NSString *url = [NSString stringWithFormat:@"/api/lyrics?file=%@", RLPEnc(path)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSString *lrc = [json[@"lrc"] isKindOfClass:[NSString class]] ? json[@"lrc"] : @"";
        BOOL ok = json && [json[@"ok"] boolValue];
        if (ok && lrc.length) {
            self_.lyricsView.string = lrc;
            self_.lyricsEmpty.stringValue = @"";
        } else {
            self_.lyricsView.string = @"";
            self_.lyricsEmpty.stringValue = RLPTr(@"这首曲目没有歌词");
        }
    }];
}

/// 按**文件路径**取封面：/api/cover?file=… 是既有端点（与 web 版单曲页同一个），
/// 内部走「内嵌图 → 同目录图 → 所属专辑封面」三级兜底，因此不需要先解析专辑 key。
/// 用单调递增的请求序号丢弃过期结果：快速切歌时慢请求回来不能盖掉新封面。
- (void)loadCoverForPath:(NSString *)path {
    if (!path.length) {
        self.cover.image = nil;
        return;
    }
    const NSUInteger seq = ++self.coverSeq;
    NSString *url = [NSString stringWithFormat:@"/api/cover?file=%@", RLPEnc(path)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getData:url completion:^(NSData * _Nullable data) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.coverSeq) return;   // 过期结果直接丢
        self_.cover.image = data.length ? [[NSImage alloc] initWithData:data] : nil;
    }];
}

/// 取当前曲的标题/艺术家，再据此拉 AI 资料层。
/// 为什么要先 /api/meta：/api/status 只给路径，资料层要的是"实体名"。
- (void)loadMetaAndKnowledgeForPath:(NSString *)path {
    if (!path.length) {
        [self.knowledge loadKind:@"track" name:@"" artist:nil];
        return;
    }
    NSString *url = [NSString stringWithFormat:@"/api/meta?file=%@", RLPEnc(path)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        // 异步回来时可能已切歌：路径不一致就丢弃
        if (![path isEqualToString:self_.currentPath ?: @""]) return;
        NSString *title = [json[@"title"] isKindOfClass:[NSString class]] ? json[@"title"] : @"";
        NSString *artist = [json[@"artist"] isKindOfClass:[NSString class]] ? json[@"artist"] : @"";
        if (!title.length) title = path.lastPathComponent.stringByDeletingPathExtension;
        if (title.length) self_.titleLabel2.stringValue = title;
        if (artist.length) self_.artistLabel2.stringValue = artist;
        [self_.knowledge loadKind:@"track" name:title artist:artist];
    }];
}

- (void)onFav:(id)sender {
    if (!self.currentPath.length) { RLPToast(RLPTr(@"没有正在播放的曲目")); return; }
    NSString *url = [NSString stringWithFormat:@"/api/fav?file=%@&on=1", RLPEnc(self.currentPath)];
    [[RLPCoreClient shared] postJSON:url body:@"" completion:^(NSDictionary * _Nullable json) {
        if (json && [json[@"ok"] boolValue]) RLPToast(RLPTr(@"已收藏"));
        else RLPToast(RLPTr(@"收藏失败"));
    }];
}

#pragma mark - 音频分析（一行四元素）

/// 摘要块：无边框、单行、过长截断 + tooltip 全文。
/// 为什么不许换行：用户明确要求「改成 1 行显示」，换行就是没做到。
- (NSButton *)anlChipWithIdentifier:(NSString *)ident action:(SEL)action {
    NSButton *b = [NSButton buttonWithTitle:@"" target:self action:action];
    b.bordered = NO;
    b.identifier = ident;
    b.font = [RLPTheme current].small;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.alignment = NSTextAlignmentLeft;
    [(NSButtonCell *)b.cell setLineBreakMode:NSLineBreakByTruncatingTail];
    b.contentTintColor = [RLPTheme current].text2;
    return b;
}

- (void)onAnlDyn:(id)sender { [self anlOpenLevel:RLPAnlLevelMetrics]; }
- (void)onAnlQual:(id)sender { [self anlOpenLevel:RLPAnlLevelMetrics]; }
- (void)onAnlFake:(id)sender { [self anlOpenLevel:RLPAnlLevelMetrics]; }

/// 「展开」循环三档：收起 → 指标 → 全量 → 收起（与 web 版 anlSetLvl 同口径）。
- (void)onAnlExpand:(id)sender {
    RLPAnlLevel next = (self.anlLevel == RLPAnlLevelCollapsed) ? RLPAnlLevelMetrics
                     : (self.anlLevel == RLPAnlLevelMetrics ? RLPAnlLevelFull : RLPAnlLevelCollapsed);
    [self anlOpenLevel:next];
}

- (void)anlOpenLevel:(RLPAnlLevel)level {
    self.anlLevel = level;
    const BOOL open = (level != RLPAnlLevelCollapsed);
    self.anlDetailScroll.hidden = !open;
    self.anlReanalyze.hidden = !open;      // 重新分析只在展开后出现
    self.anlDetailHeight.constant = open ? 200 : 0;
    [self.anlExpand setTitle:(level == RLPAnlLevelCollapsed ? RLPTr(@"展开")
                             : (level == RLPAnlLevelMetrics ? RLPTr(@"更多") : RLPTr(@"收起")))];
    [self anlPaint];
}

/// 只刷文案，不重新取数（0.8s 轮询会调它，绝不能在这里发分析请求）。
- (void)anlPaint {
    NSDictionary *h = self.anlHealth;
    NSString *dyn = RLPAnlSumDyn(h), *qual = RLPAnlSumQual(h), *fake = RLPAnlSumFake(h);
    if (!self.currentPath.length) {
        dyn = qual = fake = RLPTr(@"未播放");
    } else if (!RLPAnlIsLocalPath(self.currentPath)) {
        dyn = qual = fake = RLPTr(@"仅本地文件可分析");
    } else if (self.anlBusy) {
        dyn = qual = fake = RLPTr(@"正在分析…");
    } else if (self.anlError.length) {
        dyn = qual = fake = [NSString stringWithFormat:@"%@：%@", RLPTr(@"分析失败"), self.anlError];
    } else if (!h) {
        dyn = qual = fake = RLPTr(@"未分析");
    }
    [self.anlDyn setTitle:[NSString stringWithFormat:@"%@ %@", RLPTr(@"动态"), dyn]];
    [self.anlQual setTitle:[NSString stringWithFormat:@"%@ %@", RLPTr(@"音质"), qual]];
    [self.anlFake setTitle:[NSString stringWithFormat:@"%@ %@", RLPTr(@"假无损"), fake]];
    self.anlDyn.toolTip = dyn; self.anlQual.toolTip = qual; self.anlFake.toolTip = fake;

    if (self.anlLevel == RLPAnlLevelCollapsed) { self.anlDetail.string = @""; return; }
    // 详情文本是纯函数（RLPAnalysisSummary）：同一份 health 永远同一份输出，可离线单测。
    self.anlDetail.string = RLPAnlDetailText(h, (NSInteger)self.anlLevel, self.anlCached,
                                             self.anlError, self.currentPath);
}

/// 真的取数。**只由切歌自动分析或用户点「重新分析」触发**，绝不进轮询。
- (void)anlAnalyzePath:(NSString *)path force:(BOOL)force {
    if (!RLPAnlIsLocalPath(path)) return;
    const NSUInteger seq = ++self.anlSeq;
    self.anlBusy = YES;
    self.anlError = nil;                 // 新一轮开始：清掉上一次的失败原因
    self.anlCached = NO;
    [self anlPaint];
    NSString *url = [NSString stringWithFormat:@"/api/health?file=%@%@", RLPEnc(path), force ? @"&force=1" : @""];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.anlSeq) return;    // 过期结果直接丢（切歌后不能盖掉新曲）
        self_.anlBusy = NO;
        if (json && [json[@"ok"] boolValue]) {
            // ⚠️ 后端返回的是**外层**：{ok, usable, cached, ms, stats, health:{…}}
            // （tools/rtaweb.cpp 的 handle_health_analysis，缓存命中与实算两条路径都这样）。
            // 摘要函数要的是 health 里面的扁平字段，直接存外层会让 dr_db/quality 全部读不到 ⟹
            // 一首 DR 14.2、零削波的歌被显示成「素材过短 · 动态不适用 / 不适用 · 样本不足」。
            // 内层缺失（异常响应）时退回外层，至少不丢已有字段。
            NSDictionary *inner = [json[@"health"] isKindOfClass:[NSDictionary class]] ? json[@"health"] : nil;
            self_.anlHealth = inner ?: json;
            self_.anlPath = path;
            // 缓存命中标记只用于状态文案（不影响任何指标）
            id cached = json[@"cached"];
            self_.anlCached = [cached isKindOfClass:[NSNumber class]] && [cached boolValue];
        } else {
            self_.anlHealth = nil;
            self_.anlCached = NO;
            // 如实报错，不要把失败显示成"未分析"让人以为还没跑
            id err = json[@"error"];
            self_.anlError = [err isKindOfClass:[NSString class]] ? err : nil;
            if (!self_.anlError.length) self_.anlError = RLPTr(@"分析失败");
        }
        [self_ anlPaint];
    }];
}

- (void)onAnlReanalyze:(id)sender {
    if (!self.currentPath.length) { RLPToast(RLPTr(@"没有正在播放的曲目")); return; }
    [self anlAnalyzePath:self.currentPath force:YES];
}

- (void)applyTheme {
    [super applyTheme];
    RLPTheme *t = [RLPTheme current];
    self.cover.layer.backgroundColor = t.bg2.CGColor;
    self.titleLabel2.textColor = t.text;
    self.artistLabel2.textColor = t.mut;
    self.metaLabel.textColor = t.mut;
    [self.knowledge applyTheme];
    for (NSButton *b in @[self.anlDyn, self.anlQual, self.anlFake]) b.contentTintColor = t.text2;
    for (NSTextView *tv in @[self.lyricsView, self.anlDetail]) {
        tv.textColor = t.text;
        tv.font = t.body;
    }
    self.lyricsEmpty.textColor = t.mut;
}

@end