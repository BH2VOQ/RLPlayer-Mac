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

/// 分析一行：空标题的无边框按钮 intrinsic 宽为 0，离屏渲染时约束不重算，
/// 所以每次 layout 后按文本 sizeToFit 重放宽度（保证任何渲染路径都画得出来）。
@interface RLPAnlRowView : NSView
@property (nonatomic, strong) NSArray<NSButton *> *chips;
@property (nonatomic, strong) NSButton *expand;
@end
@implementation RLPAnlRowView
- (void)layout {
    [super layout];
    const CGFloat W = self.bounds.size.width;
    if (W < 50 || !self.chips.count) return;
    const CGFloat expandW = 56, gap = 8;
    const CGFloat chipW = MAX(60, (W - expandW - gap * 3) / 3.0);
    CGFloat x = 0;
    for (NSButton *b in self.chips) {
        [b sizeToFit];
        CGRect f = b.frame;
        f.size.width = chipW; f.size.height = 22;
        f.origin = CGPointMake(x, (self.bounds.size.height - 22) / 2.0);
        b.frame = f;
        x += chipW + gap;
    }
    [self.expand sizeToFit];
    CGRect ef = self.expand.frame;
    ef.size.width = expandW; ef.size.height = 24;
    ef.origin = CGPointMake(W - expandW, (self.bounds.size.height - 24) / 2.0);
    self.expand.frame = ef;
}
@end

#pragma mark - 底部控制区（web #npPage .npctl2 的原生落点）

/// 拖动提交滑杆：拖动期间 0.8s 轮询**不得**回写（否则滑块被"橡皮筋"拉回去），
/// 松手只提交一次（进度 = /api/seek，音量 = /api/volume；每像素发一个请求会堆请求）。
/// 与底栏 RLPPlaybackBarView 的 RLPCommitSlider 同一手法。
@interface RLPNPSlider : NSSlider
@property (nonatomic, assign, readonly) BOOL dragging;
@property (nonatomic, copy, nullable) void (^onCommit)(void);
@end

@implementation RLPNPSlider
- (void)mouseDown:(NSEvent *)event {
    _dragging = YES;
    [super mouseDown:event];      // NSSlider 在这里跑完整个拖动循环
    _dragging = NO;
    if (self.onCommit) self.onCommit();
}
@end

/// 音量滑块是**位置刻度 0..1000**，不是 dB。曲线逐字对齐 web ui_script.h 的
/// volPosToDb / volDbToPos（-55·(1-p)^1.6；pos≤5 = -120 dB 真静音）。
/// 为什么不能用线性 dB：线性刻度中点 = -30 dB（约 3% 振幅），用户会以为"拖到中间就没声音"
/// —— 这正是 web 2026-10-25 修掉的事故，原生不能原样退回去。
static const double kNPVolMinDb = -55.0;      // 曲线 dB 下限（不是静音位）
static const double kNPVolSilentDb = -120.0;  // 真静音：后端把 ≤-120 dB 映射成增益 0
static const int kNPVolSilentPos = 5;         // 位置 ≤5（0.5% 行程）判定为静音档

static double RLPNPVolPosToDb(double pos) {
    if (!isfinite(pos)) return kNPVolSilentDb;
    const double p = fmax(0.0, fmin(1000.0, pos)) / 1000.0;
    if (pos <= kNPVolSilentPos) return kNPVolSilentDb;
    return -fabs(kNPVolMinDb) * pow(1.0 - p, 1.6);
}

static double RLPNPVolDbToPos(double db) {
    if (!isfinite(db) || db >= 0.0) return 1000.0;
    if (db <= kNPVolMinDb) return 0.0;    // ≤ -55 dB（含 -120 静音档）全部落在最左端
    return round(1000.0 * (1.0 - pow(-db / fabs(kNPVolMinDb), 1.0 / 1.6)));
}

/// 标签说结果而不是内部编码：静音档写「静音」（-120 dB 对用户没有意义），其余保留 1 位小数。
static NSString *RLPNPVolDbLabel(double db) {
    if (!isfinite(db) || db <= -59.5) return RLPTr(@"静音");
    if (fabs(db) < 0.05) db = 0.0;
    return [NSString stringWithFormat:@"%@%.1f dB", db > 0.0 ? @"+" : @"", db];
}

/// 收藏路径规范化：后端 /api/fav 的收藏键沿用了跨平台的 "\\" 分隔符
/// （实测 POST /api/fav?file=/a/b.flac 后 /api/fav/list 回 "\\a\\b.flac"），
/// 而 /api/status 的 current 是 "…/a/b.flac" ⟹ 逐字比较永远不相等、心形永远空心。
/// 两侧统一成 "/" 再比；不改后端语义，也不臆造第二个收藏存储。
static NSString *RLPNPFavKey(NSString *path) {
    if (![path isKindOfClass:[NSString class]]) return @"";
    return [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
}

/// 底部控制条：进度滑杆一行 + 「当前/总时长 · 循环/上一首/播放/下一首/停止 · 音量」一行，
/// 与 web #npPage 的 .npseek + .npctlrow 同结构。内部纯手动布局（固定高度，约束只有外层四条）。
@interface RLPNPControlBar : NSView
@property (nonatomic, strong) RLPNPSlider *seek;
@property (nonatomic, strong) RLPNPSlider *volume;
@property (nonatomic, strong) NSTextField *posLabel;
@property (nonatomic, strong) NSTextField *sepLabel;
@property (nonatomic, strong) NSTextField *durLabel;
@property (nonatomic, strong) NSTextField *volLabel;
@property (nonatomic, strong) NSButton *repBtn;
@property (nonatomic, strong) NSButton *prevBtn;
@property (nonatomic, strong) NSButton *playBtn;
@property (nonatomic, strong) NSButton *nextBtn;
@property (nonatomic, strong) NSButton *stopBtn;
@property (nonatomic, strong) NSImageView *volIcon;
- (void)applyTheme;
@end

@implementation RLPNPControlBar

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    RLPTheme *t = [RLPTheme current];
    self.wantsLayer = YES;
    self.layer.cornerRadius = 10;
    self.layer.backgroundColor = t.barBg.CGColor;
    self.layer.borderWidth = 1;
    self.layer.borderColor = t.hairline.CGColor;
    self.identifier = @"np.controls";

    self.seek = [[RLPNPSlider alloc] initWithFrame:NSZeroRect];
    self.seek.minValue = 0.0;
    self.seek.maxValue = 1.0;
    self.seek.doubleValue = 0.0;
    self.seek.continuous = YES;
    self.seek.controlSize = NSControlSizeSmall;
    self.seek.identifier = @"np.seek";
    self.seek.toolTip = RLPTr(@"进度");

    NSFont *timeFont = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.posLabel = RLPLabel(@"0:00", timeFont, t.mut);
    self.posLabel.identifier = @"np.pos";
    self.posLabel.alignment = NSTextAlignmentRight;
    self.sepLabel = RLPLabel(@"/", timeFont, t.mut);
    self.sepLabel.alignment = NSTextAlignmentCenter;
    self.durLabel = RLPLabel(@"0:00", timeFont, t.mut);
    self.durLabel.identifier = @"np.dur";

    self.repBtn = [NSButton buttonWithTitle:RLPTr(@"顺序") target:nil action:nil];
    self.repBtn.bezelStyle = NSBezelStyleRounded;
    self.repBtn.controlSize = NSControlSizeSmall;
    self.repBtn.font = t.small;
    self.repBtn.identifier = @"np.rep";
    self.repBtn.toolTip = RLPTr(@"循环方式");

    self.prevBtn = RLPSymbolButton(@"backward.fill", @"上一首", nil, nil);
    self.prevBtn.identifier = @"np.prev";
    self.playBtn = RLPSymbolButton(@"play.fill", @"播放 / 暂停", nil, nil);
    self.playBtn.identifier = @"np.play";
    self.nextBtn = RLPSymbolButton(@"forward.fill", @"下一首", nil, nil);
    self.nextBtn.identifier = @"np.next";
    self.stopBtn = RLPSymbolButton(@"stop.fill", @"停止", nil, nil);
    self.stopBtn.identifier = @"np.stop";

    self.volIcon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    self.volIcon.image = [NSImage imageWithSystemSymbolName:@"speaker.wave.2"
                                   accessibilityDescription:RLPTr(@"音量")];
    self.volIcon.contentTintColor = t.mut;

    self.volume = [[RLPNPSlider alloc] initWithFrame:NSZeroRect];
    self.volume.minValue = 0.0;
    self.volume.maxValue = 1000.0;      // 位置刻度，不是 dB
    self.volume.doubleValue = 1000.0;
    self.volume.continuous = YES;
    self.volume.controlSize = NSControlSizeSmall;
    self.volume.identifier = @"np.vol";
    self.volume.toolTip = RLPTr(@"音量");
    self.volLabel = RLPLabel(@"0.0 dB",
        [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightRegular], t.mut);
    self.volLabel.identifier = @"np.vollab";
    self.volLabel.alignment = NSTextAlignmentRight;

    for (NSView *v in @[self.seek, self.posLabel, self.sepLabel, self.durLabel, self.repBtn,
                        self.prevBtn, self.playBtn, self.nextBtn, self.stopBtn,
                        self.volIcon, self.volume, self.volLabel]) {
        [self addSubview:v];
    }
    return self;
}

- (void)layout {
    [super layout];
    const CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    if (W < 280 || H < 56) return;
    const CGFloat pad = 14.0;

    // 上排：进度滑杆铺满（web #npSeek 占满整行）
    const CGFloat seekH = 16.0;
    const CGFloat seekY = H - 9.0 - seekH;
    self.seek.frame = NSMakeRect(pad, seekY, MAX(80.0, W - pad * 2), seekH);

    // 下排：时间（左）· 控制键（中，恒居中）· 音量（右）
    const CGFloat rowCY = seekY / 2.0;
    const CGFloat timeW = 46.0, sepW = 10.0;
    CGFloat x = pad;
    self.posLabel.frame = NSMakeRect(x, rowCY - 8, timeW, 16); x += timeW + 2;
    self.sepLabel.frame = NSMakeRect(x, rowCY - 8, sepW, 16); x += sepW + 2;
    self.durLabel.frame = NSMakeRect(x, rowCY - 8, timeW, 16);

    const CGFloat repW = 68.0, keyS = 28.0, playS = 32.0, keyGap = 8.0;
    const CGFloat keysW = repW + keyGap + keyS + keyGap + playS + keyGap + keyS + keyGap + keyS;
    CGFloat kx = (W - keysW) / 2.0;
    self.repBtn.frame = NSMakeRect(kx, rowCY - 12, repW, 24); kx += repW + keyGap;
    self.prevBtn.frame = NSMakeRect(kx, rowCY - keyS / 2.0, keyS, keyS); kx += keyS + keyGap;
    self.playBtn.frame = NSMakeRect(kx, rowCY - playS / 2.0, playS, playS); kx += playS + keyGap;
    self.nextBtn.frame = NSMakeRect(kx, rowCY - keyS / 2.0, keyS, keyS); kx += keyS + keyGap;
    self.stopBtn.frame = NSMakeRect(kx, rowCY - keyS / 2.0, keyS, keyS);

    const CGFloat volLabW = 56.0, iconW = 14.0, volGap = 6.0;
    CGFloat sliderW = 118.0;
    const CGFloat minIconX = kx + 12.0;                 // 绝不压住中键区
    const CGFloat labelX = W - pad - volLabW;
    CGFloat sliderX = labelX - volGap - sliderW;
    CGFloat iconX = sliderX - volGap - iconW;
    if (iconX < minIconX) {
        sliderW = MAX(56.0, sliderW - (minIconX - iconX));
        sliderX = labelX - volGap - sliderW;
        iconX = sliderX - volGap - iconW;
    }
    self.volIcon.frame = NSMakeRect(iconX, rowCY - 7, iconW, 14);
    self.volume.frame = NSMakeRect(sliderX, rowCY - 9, sliderW, 18);
    self.volLabel.frame = NSMakeRect(labelX, rowCY - 8, volLabW, 16);
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.layer.backgroundColor = t.barBg.CGColor;
    self.layer.borderColor = t.hairline.CGColor;
    for (NSTextField *l in @[self.posLabel, self.sepLabel, self.durLabel, self.volLabel])
        l.textColor = t.mut;
    for (NSButton *b in @[self.prevBtn, self.playBtn, self.nextBtn, self.stopBtn])
        b.contentTintColor = t.text;
    self.volIcon.contentTintColor = t.mut;
}

@end

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
@property (nonatomic, assign) NSTimeInterval anlAutoSettingAt;  // 上次读 settings 的时刻（节流）
@property (nonatomic, assign) NSUInteger anlSeq;           // 丢弃过期回调
@property (nonatomic, strong) NSLayoutConstraint *anlDetailHeight;
/// 封面请求序号：快速切歌时用它丢弃过期回调（慢请求回来不能盖掉新封面）。
@property (nonatomic, assign) NSUInteger coverSeq;
@property (nonatomic, strong) RLPKnowledgeView *knowledge;
@property (nonatomic, strong) NSButton *compareBtn;
@property (nonatomic, strong) NSButton *worksBtn;
@property (nonatomic, strong) NSPopover *comparePopover;
@property (nonatomic, strong) NSStackView *compareList;
@property (nonatomic, strong) NSTextView *compareOut;
@property (nonatomic, strong) NSMutableArray<NSString *> *comparePaths;
@property (nonatomic, strong) NSMutableArray<NSButton *> *compareChecks;
@end

@implementation RLPNowPlayingViewController

- (instancetype)init {
    self = [super initWithTitle:RLPTr(@"正在播放")];
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

    // 版本对比（web 单曲页「对比同目录版本」同款能力，POST /api/compare）
    self.compareBtn = [NSButton buttonWithTitle:RLPTr(@"对比版本") target:self action:@selector(onCompare:)];
    self.compareBtn.bezelStyle = NSBezelStyleRounded;
    self.compareBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.compareBtn];

    // 古典作品 · 演绎版本入口（web 单曲页「作品」tab 的原生落点）。
    // 不假装自动判定古典：点了就带当前曲名/艺术家去作品页检索，结果由后端说话。
    self.worksBtn = [NSButton buttonWithTitle:RLPTr(@"古典作品版本") target:self action:@selector(onOpenWorks:)];
    self.worksBtn.bezelStyle = NSBezelStyleRounded;
    self.worksBtn.identifier = @"np.works";
    self.worksBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.worksBtn];

    // 音频分析改为一行（1.1.7.1）：动态 / 音质 / 假无损 / 展开，四个元素同一行。
    // 「自动分析」开关已挪到设置·高级；「重新分析」只在展开后出现，不摆在面上。

    NSTextField *lyricsTitle = RLPLabel(RLPTr(@"歌词"), [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], t.text);
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
    self.anlRow = [[RLPAnlRowView alloc] initWithFrame:NSZeroRect];
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
    ((RLPAnlRowView *)self.anlRow).chips = @[self.anlDyn, self.anlQual, self.anlFake];
    ((RLPAnlRowView *)self.anlRow).expand = self.anlExpand;
    for (NSView *v in @[self.anlDyn, self.anlQual, self.anlFake, self.anlExpand])
        v.translatesAutoresizingMaskIntoConstraints = YES;   // 纯手动 frame（行视图 layout 摆放）
    [self anlPaint];   // 空态也要有文案（未播放），否则空标题按钮不画

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
        [self.compareBtn.leadingAnchor constraintEqualToAnchor:fav.trailingAnchor constant:8],
        [self.compareBtn.centerYAnchor constraintEqualToAnchor:fav.centerYAnchor],
        [self.worksBtn.leadingAnchor constraintEqualToAnchor:self.compareBtn.trailingAnchor constant:8],
        [self.worksBtn.centerYAnchor constraintEqualToAnchor:fav.centerYAnchor],
        // 一行分析条：独占一行（收藏按钮下方），左对齐封面右缘、右到窗口边界。
        // 不与标题/收藏同行 —— 标题是可变长文本，会把这一行挤成 0 宽（判据 C2b 抓到的真缺陷）。
        [self.anlRow.leadingAnchor constraintEqualToAnchor:self.titleLabel2.leadingAnchor],
        [self.anlRow.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-24],
        [self.anlRow.topAnchor constraintEqualToAnchor:fav.bottomAnchor constant:10],
        [self.anlRow.heightAnchor constraintEqualToConstant:26],

        

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
    // 离开单曲页：让服务器也停下在跑的分析（与 web 版离开页面时的 anlCancelServer 同语义）。
    if (self.anlBusy) {
        [[RLPCoreClient shared] postJSON:@"/api/anl/cancel" body:@""
                              completion:^(NSDictionary * _Nullable r) { (void)r; }];
        self.anlBusy = NO;
        self.anlSeq++;                  // 在途回调作废
    }
}

- (void)startPolling {
    if (self.polling) return;
    if (![RLPCoreClient shared].started) {
        [self setSubtitle:RLPTr(@"核心未启动")];
        return;
    }
    self.polling = YES;
    // 自动分析开关的真相源是 settings.autoanl（开关本身在设置·高级页签，播放页不再显示）。
    [self anlRefreshAutoSettingIfStale];
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
            // 切歌：清掉上一首的结果与层级。
            self_.anlHealth = nil;
            self_.anlPath = nil;
            self_.anlError = nil;
            self_.anlCached = NO;
            self_.anlSeq++;                 // 让上一首的在途回调作废
            self_.anlBusy = NO;
            self_.anlAutoDonePath = nil;
            [self_ anlOpenLevel:RLPAnlLevelCollapsed];
            // 切歌要让**服务器**也停下上一首的分析（/api/anl/cancel，与 web 版 anlTick 同语义：
            // 否则 CPU 继续烧在没人看的结果上）。
            if (path.length) {
                [[RLPCoreClient shared] postJSON:@"/api/anl/cancel" body:@""
                                      completion:^(NSDictionary * _Nullable r) { (void)r; }];
            }
        }
        // 每轮都跑一次"该不该自动分析"的判定（与 web 版 anlTick 同口径）。
        // ⚠️ 这里绝不无条件发 /api/health：那是整曲解码 + FFT 的重活。
        // 只有「autoanl=1 且正在播放 且 本地文件 且 无缓存 且 没在跑 且 本曲还没自动跑过」才发一次。
        [self_ anlAutoTickForPath:path playing:st.playing paused:st.paused];
    }];
}

/// settings.autoanl 的读取节流：它不是热路径（用户在设置页偶尔改一次），
/// 但读一次就永久缓存会让"刚勾上却要等到切歌才生效"。10 s 一次足够，且绝不进 0.8 s 的忙碌路径。
- (void)anlRefreshAutoSettingIfStale {
    const NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (self.anlAutoSettingAt > 0 && (now - self.anlAutoSettingAt) < 10.0) return;
    self.anlAutoSettingAt = now;
    __weak __typeof__(self) ws = self;
    [[RLPCoreClient shared] getJSON:@"/api/settings" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) s = ws;
        if (!s) return;
        // 值在 kv 子对象里（读顶层会永远读成"关"）。
        NSDictionary *kv = [json[@"kv"] isKindOfClass:[NSDictionary class]] ? json[@"kv"] : nil;
        if (!kv) return;
        id v = kv[@"autoanl"];
        if ([v isKindOfClass:[NSString class]]) s.anlAutoEnabled = [(NSString *)v isEqualToString:@"1"];
        else if ([v isKindOfClass:[NSNumber class]]) s.anlAutoEnabled = [(NSNumber *)v boolValue];
    }];
}

/// 对齐 web 版 anlTick：每曲只自动跑一次；暂停/继续/拖动进度都不重新触发。
- (void)anlAutoTickForPath:(NSString *)path playing:(BOOL)playing paused:(BOOL)paused {
    [self anlRefreshAutoSettingIfStale];
    const BOOL active = playing && !paused;
    if (RLPAnlShouldAutoAnalyze(path, active, self.anlAutoEnabled,
                                self.anlAutoDonePath, self.anlBusy,
                                self.anlHealth.count > 0 && [path isEqualToString:self.anlPath ?: @""])) {
        self.anlAutoDonePath = path;
        [self anlAnalyzePath:path force:NO];
    }
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

#pragma mark - 版本对比（/api/compare，与 web 同口径）

/// 打开弹层：列同目录音频文件（/api/files?dir=），当前曲目默认勾选。
/// 打开古典作品页：带当前曲名与艺术家（作曲家可空，后端按作品名检索）。
/// web 的「作品」tab 只在古典曲目出现；原生不假装自动判定，入口常在、结果由后端说话。
- (void)onOpenWorks:(id)sender {
    (void)sender;
    NSString *title = self.titleLabel2.stringValue ?: @"";
    NSString *artist = self.artistLabel2.stringValue ?: @"";
    if (!title.length && self.currentPath.length)
        title = self.currentPath.lastPathComponent.stringByDeletingPathExtension;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenWorksNotification"
        object:@{@"title": title, @"composer": artist}];
}

- (void)onCompare:(id)sender {
    NSString *path = self.currentPath;
    if (!path.length) { RLPToast(RLPTr(@"没有正在播放的曲目")); return; }
    NSString *dir = path.stringByDeletingLastPathComponent;
    RLPTheme *t = [RLPTheme current];
    NSStackView *s = [[NSStackView alloc] init];
    s.orientation = NSUserInterfaceLayoutOrientationVertical;
    s.alignment = NSLayoutAttributeLeading;
    s.spacing = 6;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *ti = RLPLabel(RLPTr(@"对比同目录版本"), [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], t.text);
    [s addArrangedSubview:ti];
    NSTextField *hint = RLPLabel(RLPTr(@"勾选 2–8 个版本，分数与排名由后端算出。"), t.small, t.mut);
    [s addArrangedSubview:hint];
    self.compareList = [[NSStackView alloc] init];
    self.compareList.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.compareList.alignment = NSLayoutAttributeLeading;
    self.compareList.spacing = 4;
    self.compareList.translatesAutoresizingMaskIntoConstraints = NO;
    [s addArrangedSubview:self.compareList];
    self.compareOut = [self makeTextView];
    NSScrollView *outScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    outScroll.drawsBackground = NO; outScroll.hasVerticalScroller = YES;
    outScroll.documentView = self.compareOut;
    outScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [[outScroll.heightAnchor constraintEqualToConstant:180] setActive:YES];
    [[outScroll.widthAnchor constraintEqualToConstant:420] setActive:YES];
    [s addArrangedSubview:outScroll];
    NSButton *go = [NSButton buttonWithTitle:RLPTr(@"开始对比") target:self action:@selector(onCompareRun:)];
    go.bezelStyle = NSBezelStyleRounded;
    [s addArrangedSubview:go];

    self.comparePaths = [NSMutableArray array];
    self.compareChecks = [NSMutableArray array];
    [[RLPCoreClient shared] getJSON:[NSString stringWithFormat:@"/api/files?dir=%@", RLPEnc(dir)]
        completion:^(NSDictionary * _Nullable json) {
        NSArray *names = [json[@"files"] isKindOfClass:[NSArray class]] ? json[@"files"] : @[];
        NSString *base = path.lastPathComponent;
        for (id n in names) {
            if (![n isKindOfClass:[NSString class]]) continue;
            NSString *full = [dir stringByAppendingPathComponent:n];
            NSButton *chk = [NSButton checkboxWithTitle:n target:nil action:nil];
            chk.state = [n isEqualToString:base] ? NSControlStateValueOn : NSControlStateValueOff;
            chk.font = t.small;
            [self.compareList addArrangedSubview:chk];
            [self.comparePaths addObject:full];
            [self.compareChecks addObject:chk];
        }
        if (!names.count) self.compareOut.string = RLPTr(@"该目录下没有可对比的音频文件");
    }];
    [self.comparePopover close];
    self.comparePopover = RLPShowCardPopover(self.compareBtn, RLPCardController(s, 450, 320), 450);
}

/// 跑对比：表单重复 file=…（2–8 个），结果只排版不重算（铁律 3）。
- (void)onCompareRun:(id)sender {
    NSMutableArray *sel = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.compareChecks.count; ++i)
        if (self.compareChecks[i].state == NSControlStateValueOn) [sel addObject:self.comparePaths[i]];
    if (sel.count < 2) { RLPToast(RLPTr(@"至少勾选 2 个版本")); return; }
    if (sel.count > 8) { RLPToast(RLPTr(@"一次最多 8 个版本")); return; }
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *p in sel) [parts addObject:[NSString stringWithFormat:@"file=%@", RLPEnc(p)]];
    self.compareOut.string = RLPTr(@"正在对齐并分析…");
    [[RLPCoreClient shared] postJSON:@"/api/compare" body:[parts componentsJoinedByString:@"&"]
        completion:^(NSDictionary * _Nullable r) {
        if (!r || ![r[@"ok"] boolValue]) {
            self.compareOut.string = [r[@"error"] isKindOfClass:[NSString class]] ? r[@"error"] : RLPTr(@"对比失败");
            return;
        }
        NSMutableString *out = [NSMutableString string];
        if ([r[@"sameTrack"] boolValue] == NO)
            [out appendFormat:@"%@\n", RLPTr(@"⚠ 包络相关偏低，这些文件可能不是同一首曲子")];
        [out appendFormat:@"%@\n", RLPTr(@"排序（好 → 差）")];
        NSArray *vs = [r[@"versions"] isKindOfClass:[NSArray class]] ? r[@"versions"] : @[];
        NSArray *ranking = [r[@"ranking"] isKindOfClass:[NSArray class]] ? r[@"ranking"] : @[];
        for (id idx in ranking) {
            NSInteger i = [idx integerValue];
            if (i < 0 || i >= (NSInteger)vs.count) continue;
            NSDictionary *v = vs[i];
            [out appendFormat:@"  %@  %@  —  %@ 分\n",
                v[@"label"] ?: @"", [v[@"path"] lastPathComponent],
                [v[@"score"] isKindOfClass:[NSNumber class]] ? [NSString stringWithFormat:@"%.1f", [v[@"score"] doubleValue]] : @"NA"];
        }
        [out appendString:@"\n"];
        NSArray *rows = [r[@"rows"] isKindOfClass:[NSArray class]] ? r[@"rows"] : @[];
        for (NSDictionary *row in rows) {
            [out appendFormat:@"%@%@:", row[@"label"] ?: @"",
                [row[@"unit"] length] ? [NSString stringWithFormat:@" (%@)", row[@"unit"]] : @""];
            NSArray *vals = [row[@"values"] isKindOfClass:[NSArray class]] ? row[@"values"] : @[];
            for (NSUInteger j = 0; j < vals.count; ++j) {
                NSString *num = [vals[j] isKindOfClass:[NSNumber class]] ? [NSString stringWithFormat:@"%.2f", [vals[j] doubleValue]] : @"NA";
                const BOOL best = ([row[@"bestIndex"] integerValue] == (NSInteger)j) && [row[@"comparable"] boolValue];
                [out appendFormat:@"  %@%@", num, best ? @"*" : @""];
            }
            [out appendString:@"\n"];
        }
        if ([r[@"explanation"] length]) [out appendFormat:@"\n%@\n", r[@"explanation"]];
        self.compareOut.string = out;
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