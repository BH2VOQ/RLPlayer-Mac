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
#import "RLPLyrics.h"
#import "RLPTrackActions.h"
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>

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


@interface RLPNowPlayingViewController (CanvasLayout)
- (void)layoutWebPlayback;
- (NSMenu *)playbackContextMenu;
- (void)onClosePlayback:(id)sender;
@end
// Web #npPage uses top-left coordinates and covers the entire window content.
@interface RLPNPCanvas : NSView
@property(nonatomic,weak) RLPNowPlayingViewController *owner;
@property(nonatomic,strong) NSImage *blurredCover;
@end
@implementation RLPNPCanvas
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event { if(event.keyCode==53)[self.owner onClosePlayback:nil];else [super keyDown:event]; }
- (NSMenu *)menuForEvent:(NSEvent *)event { return [self.owner playbackContextMenu]; }
- (void)layout { [super layout]; [self.owner layoutWebPlayback]; }
- (void)drawRect:(NSRect)dirty {
    RLPTheme *t=[RLPTheme current]; [t.bg setFill]; NSRectFill(self.bounds);
    if(self.blurredCover){
        NSSize s=self.blurredCover.size; CGFloat k=MAX(self.bounds.size.width/s.width,self.bounds.size.height/s.height)*1.08;
        NSRect r=NSMakeRect((self.bounds.size.width-s.width*k)/2,(self.bounds.size.height-s.height*k)/2,s.width*k,s.height*k);
        [self.blurredCover drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    }
    // ui_page.h .npveil and light override; not a generated background picture.
    NSColor *a=t.isLight?[NSColor colorWithSRGBRed:244/255. green:246/255. blue:249/255. alpha:.62]:[NSColor colorWithSRGBRed:8/255. green:9/255. blue:12/255. alpha:.35];
    NSColor *b=t.isLight?[NSColor colorWithSRGBRed:244/255. green:246/255. blue:249/255. alpha:.95]:[NSColor colorWithSRGBRed:8/255. green:9/255. blue:12/255. alpha:.82];
    [[[NSGradient alloc] initWithStartingColor:a endingColor:b] drawInRect:self.bounds angle:90];
}
@end
@interface RLPNPLyricDocument : NSView
@end
@implementation RLPNPLyricDocument
- (BOOL)isFlipped { return YES; }
@end
@interface RLPNPAccentCell : NSSliderCell
@end
@implementation RLPNPAccentCell
- (void)drawBarInside:(NSRect)r flipped:(BOOL)flipped {
    CGFloat y=NSMidY(r)-2.5; NSRect track=NSMakeRect(r.origin.x,y,r.size.width,5);
    [[RLPTheme current].track setFill]; [[NSBezierPath bezierPathWithRoundedRect:track xRadius:2.5 yRadius:2.5] fill];
    double p=(self.doubleValue-self.minValue)/MAX(.001,self.maxValue-self.minValue);
    track.size.width*=MAX(0,MIN(1,p)); [[RLPTheme current].accent setFill]; [[NSBezierPath bezierPathWithRoundedRect:track xRadius:2.5 yRadius:2.5] fill];
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
    self.layer.backgroundColor = NSColor.clearColor.CGColor;
    self.layer.borderWidth = 0;
    self.layer.borderColor = NSColor.clearColor.CGColor;
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
    self.playBtn.wantsLayer=YES;self.playBtn.layer.cornerRadius=17;self.playBtn.layer.backgroundColor=t.accent.CGColor;self.playBtn.contentTintColor=NSColor.whiteColor;
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

    const CGFloat repW = 32.0, keyS = 32.0, playS = 34.0, keyGap = 14.0;
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
    self.layer.backgroundColor = NSColor.clearColor.CGColor;
    self.layer.borderColor = t.hairline.CGColor;
    for (NSTextField *l in @[self.posLabel, self.sepLabel, self.durLabel, self.volLabel])
        l.textColor = t.mut;
    for (NSButton *b in @[self.prevBtn, self.playBtn, self.nextBtn, self.stopBtn])
        b.contentTintColor = t.text;
    self.volIcon.contentTintColor = t.mut;
}

@end

@interface RLPNowPlayingViewController ()

@property(nonatomic,strong) RLPNPCanvas *webCanvas;
@property(nonatomic,strong) NSView *analysisPanel;
@property(nonatomic,strong) NSView *railPanel;
@property(nonatomic,strong) RLPNPControlBar *webControls;
@property(nonatomic,strong) NSScrollView *lyricScroll;
@property(nonatomic,strong) RLPNPLyricDocument *lyricDocument;
@property(nonatomic,copy) NSArray<RLPLyricLine *> *lyricLines;
@property(nonatomic,strong) NSMutableArray<NSButton *> *lyricRows;
@property(nonatomic) NSInteger lyricActiveIndex;
@property(nonatomic) NSTimeInterval lyricManualUntil;
@property(nonatomic) NSUInteger lyricSeq;
@property(nonatomic) NSInteger lyricRetry;
@property(nonatomic,strong) NSTimer *lyricRetryTimer;
@property(nonatomic,strong) NSTextField *kindLabel;
@property(nonatomic,strong) NSTextField *analysisStatus;
@property(nonatomic,strong) NSButton *anlAuto;
@property(nonatomic,strong) NSButton *anlRun;
@property(nonatomic,strong) NSButton *closeButton;
@property(nonatomic,strong) NSButton *analysisToggle;
@property(nonatomic,strong) NSButton *railToggle;
@property(nonatomic,strong) NSButton *favoriteButton;
@property(nonatomic,strong) NSButton *castButton;
@property(nonatomic,strong) NSButton *saveButton;
@property(nonatomic,strong) NSTextField *railTitle;
@property(nonatomic,strong) NSSegmentedControl *railDensity;
@property(nonatomic,strong) NSArray<NSButton *> *railCards;
@property(nonatomic,copy) NSDictionary *trackMetadata;
@property(nonatomic,strong) NSPopover *knowledgePopover;
@property(nonatomic,strong) RLPPlaybackStatus *webStatus;
@property(nonatomic) NSInteger playbackMode;
@property(nonatomic) BOOL statusInFlight;
@property(nonatomic) NSUInteger statusEpoch;
@property(nonatomic) BOOL favorite;

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


- (void)loadView {
    self.webCanvas=[[RLPNPCanvas alloc] initWithFrame:NSMakeRect(0,0,1180,760)];
    self.webCanvas.owner=self; self.webCanvas.identifier=@"npPage";
    self.webCanvas.wantsLayer=YES; self.view=self.webCanvas;
    [self buildContent];
}
- (NSView *)contentView { return self.webCanvas; }
- (void)setSubtitle:(NSString *)text { /* Full-window npPage has no ordinary page subtitle. */ }
- (NSButton *)webButton:(NSString *)title identifier:(NSString *)ident action:(SEL)action parent:(NSView *)parent {
    NSButton *b=[NSButton buttonWithTitle:RLPTr(title) target:self action:action];
    b.identifier=ident; b.font=[NSFont systemFontOfSize:10.5]; b.bezelStyle=NSBezelStyleRounded;
    [parent addSubview:b]; return b;
}
- (void)buildContent {
    RLPTheme *t=[RLPTheme current]; NSView *host=self.webCanvas;
    self.cover=[[NSImageView alloc] initWithFrame:NSZeroRect]; self.cover.identifier=@"npCover";
    self.cover.imageScaling=NSImageScaleAxesIndependently; self.cover.wantsLayer=YES;
    self.cover.layer.cornerRadius=14;self.cover.layer.masksToBounds=YES; [host addSubview:self.cover];
    self.kindLabel=RLPLabel(RLPTr(@"正在播放"),[NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],t.mut2); self.kindLabel.identifier=@"npKind";
    self.titleLabel2=RLPLabel(RLPTr(@"未播放"),[NSFont systemFontOfSize:20 weight:NSFontWeightBold],t.text); self.titleLabel2.identifier=@"npTitle";
    self.artistLabel2=RLPLabel(@"",[NSFont systemFontOfSize:13],t.mut); self.artistLabel2.identifier=@"npSub";
    self.metaLabel=RLPLabel(@"",[NSFont systemFontOfSize:12],t.mut2); self.metaLabel.identifier=@"npNextTrackHero";
    for(NSView *v in @[self.kindLabel,self.titleLabel2,self.artistLabel2,self.metaLabel]) [host addSubview:v];
    self.favoriteButton=[self webButton:@"♡" identifier:@"npFavBtn" action:@selector(onFav:) parent:host]; self.favoriteButton.bordered=NO;self.favoriteButton.font=[NSFont systemFontOfSize:22];
    self.castButton=[self webButton:@"推送到设备" identifier:@"npCastBtn" action:@selector(onCastCurrent:) parent:host];
    self.saveButton=[self webButton:@"＋ 添加到歌单" identifier:@"npAddSq" action:@selector(onSaveCurrent:) parent:host];
    // Existing compare/work functions remain accessible; they are not removed for appearance.
    self.compareBtn=[self webButton:@"对比版本" identifier:@"npCompare" action:@selector(onCompare:) parent:host];
    self.worksBtn=[self webButton:@"古典作品版本" identifier:@"np.works" action:@selector(onOpenWorks:) parent:host];
    self.closeButton=[self webButton:@"↙" identifier:@"npClose" action:@selector(onClosePlayback:) parent:host];self.closeButton.toolTip=RLPTr(@"返回（Esc）");
    self.analysisToggle=[self webButton:@"▥" identifier:@"npAnalToggle" action:@selector(onToggleAnalysis:) parent:host];self.analysisToggle.toolTip=RLPTr(@"显示 / 隐藏音频分析面板");
    self.railToggle=[self webButton:@"▤" identifier:@"npRailToggle" action:@selector(onToggleRail:) parent:host];self.railToggle.toolTip=RLPTr(@"显示 / 隐藏 AI 资料面板");
    self.analysisPanel=[[NSView alloc] initWithFrame:NSZeroRect];self.analysisPanel.identifier=@"npAnal";[host addSubview:self.analysisPanel];
    self.railPanel=[[NSView alloc] initWithFrame:NSZeroRect];self.railPanel.identifier=@"npRail";[host addSubview:self.railPanel];
    self.analysisStatus=RLPLabel(RLPTr(@"音频分析 · 未播放"),[NSFont systemFontOfSize:9.5],t.mut2);self.analysisStatus.identifier=@"npAnlStat";[self.analysisPanel addSubview:self.analysisStatus];
    self.anlAuto=[self webButton:@"自动" identifier:@"npAnlAuto" action:@selector(onToggleAuto:) parent:self.analysisPanel];
    self.anlExpand=[self webButton:@"详细" identifier:@"npAnlToggle" action:@selector(onAnlExpand:) parent:self.analysisPanel];
    self.anlRun=[self webButton:@"分析" identifier:@"npAnlRun" action:@selector(onAnlReanalyze:) parent:self.analysisPanel];
    self.anlDyn=[self anlChipWithIdentifier:@"anl.dyn" action:@selector(onAnlDyn:)];self.anlQual=[self anlChipWithIdentifier:@"anl.qual" action:@selector(onAnlQual:)];self.anlFake=[self anlChipWithIdentifier:@"anl.fake" action:@selector(onAnlFake:)];
    for(NSButton *b in @[self.anlDyn,self.anlQual,self.anlFake]) {b.translatesAutoresizingMaskIntoConstraints=YES;b.wantsLayer=YES;b.layer.cornerRadius=10;b.layer.borderWidth=1;b.layer.masksToBounds=YES;[(NSButtonCell *)b.cell setLineBreakMode:NSLineBreakByWordWrapping];b.cell.wraps=YES;[self.analysisPanel addSubview:b];}
    self.anlDetail=[self makeTextView]; self.anlDetailScroll=[[NSScrollView alloc] initWithFrame:NSZeroRect];self.anlDetailScroll.drawsBackground=NO;self.anlDetailScroll.hasVerticalScroller=YES;self.anlDetailScroll.documentView=self.anlDetail;self.anlDetailScroll.hidden=YES;[self.analysisPanel addSubview:self.anlDetailScroll];
    self.anlReanalyze=[self webButton:@"重新分析" identifier:@"npAnlRecalculate" action:@selector(onAnlReanalyze:) parent:self.analysisPanel];self.anlReanalyze.hidden=YES;
    self.lyricDocument=[[RLPNPLyricDocument alloc] initWithFrame:NSMakeRect(0,0,500,400)];
    self.lyricScroll=[[NSScrollView alloc] initWithFrame:NSZeroRect]; self.lyricScroll.identifier=@"npLyric";self.lyricScroll.drawsBackground=NO;self.lyricScroll.hasVerticalScroller=NO;self.lyricScroll.documentView=self.lyricDocument;[host addSubview:self.lyricScroll];
    self.lyricScroll.contentView.postsBoundsChangedNotifications=YES;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onLyricScrolled:) name:NSViewBoundsDidChangeNotification object:self.lyricScroll.contentView];
    self.lyricRows=[NSMutableArray array];self.lyricLines=@[];self.lyricActiveIndex=-1;
    self.lyricsEmpty=RLPLabel(RLPTr(@"还没有在播放"),[NSFont systemFontOfSize:14],t.mut2);self.lyricsEmpty.alignment=NSTextAlignmentCenter;[self.lyricDocument addSubview:self.lyricsEmpty];
    self.railTitle=RLPLabel(RLPTr(@"AI 整理"),[NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold],t.mut2);[self.railPanel addSubview:self.railTitle];
    self.railDensity=[NSSegmentedControl segmentedControlWithLabels:@[RLPTr(@"简略"),RLPTr(@"详细")] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(onRailDensity:)];self.railDensity.identifier=@"npRailSeg";self.railDensity.selectedSegment=0;[self.railPanel addSubview:self.railDensity];
    NSMutableArray *cards=[NSMutableArray array];for(NSString *name in @[@"歌曲",@"专辑",@"艺术家"]){NSButton *b=[self webButton:name identifier:[@"npChip." stringByAppendingString:name] action:@selector(onRailCard:) parent:self.railPanel]; b.tag=cards.count;b.bordered=NO;b.wantsLayer=YES;b.layer.cornerRadius=12;b.layer.borderWidth=1;[(NSButtonCell *)b.cell setLineBreakMode:NSLineBreakByWordWrapping];b.cell.wraps=YES;b.alignment=NSTextAlignmentLeft;[cards addObject:b];}self.railCards=cards;
    self.knowledge=[[RLPKnowledgeView alloc] initWithFrame:NSMakeRect(0,0,420,380)];
    self.webControls=[[RLPNPControlBar alloc] initWithFrame:NSZeroRect];[host addSubview:self.webControls];
    self.webControls.autoresizingMask=NSViewNotSizable;
    self.webControls.repBtn.target=self;self.webControls.repBtn.action=@selector(onCycleMode:);self.webControls.repBtn.bordered=NO;self.webControls.repBtn.image=[NSImage imageWithSystemSymbolName:@"repeat" accessibilityDescription:@"循环方式"];self.webControls.repBtn.title=@"";
    for(NSButton *b in @[self.webControls.prevBtn,self.webControls.playBtn,self.webControls.nextBtn,self.webControls.stopBtn])b.target=self;
    self.webControls.prevBtn.action=@selector(onPrevious:);self.webControls.playBtn.action=@selector(onPause:);self.webControls.nextBtn.action=@selector(onNext:);self.webControls.stopBtn.action=@selector(onStop:);
    self.webControls.seek.cell=[RLPNPAccentCell new];self.webControls.seek.minValue=0;self.webControls.seek.maxValue=1;
    self.webControls.volume.cell=[RLPNPAccentCell new];self.webControls.volume.minValue=0;self.webControls.volume.maxValue=1000;
    self.webControls.seek.target=self;self.webControls.seek.action=@selector(onCommitSeek:);self.webControls.volume.target=self;self.webControls.volume.action=@selector(onCommitVolume:);
    __weak __typeof__(self) ws=self;self.webControls.seek.onCommit=^{[ws onCommitSeek:nil];};self.webControls.volume.onCommit=^{[ws onCommitVolume:nil];};
    // Existing version actions remain reachable from the track context menu.
    self.compareBtn.hidden=YES;self.worksBtn.hidden=YES;
    NSArray *symbols=@[@"arrow.down.right.and.arrow.up.left",@"chart.bar.xaxis",@"text.bubble"];
    NSArray *roundButtons=@[self.closeButton,self.analysisToggle,self.railToggle];
    for(NSUInteger i=0;i<roundButtons.count;i++){NSButton *b=roundButtons[i];b.title=@"";b.bordered=NO;b.image=[NSImage imageWithSystemSymbolName:symbols[i] accessibilityDescription:b.toolTip?:@""];b.imagePosition=NSImageOnly;b.wantsLayer=YES;b.layer.cornerRadius=i==0?19:17;b.layer.borderWidth=1;b.layer.borderColor=t.line.CGColor;b.layer.backgroundColor=t.bg.CGColor;b.contentTintColor=t.mut;}
    self.analysisPanel.hidden=[[NSUserDefaults standardUserDefaults] boolForKey:@"RLPNPAnalysisHidden"];
    self.railPanel.hidden=[[NSUserDefaults standardUserDefaults] boolForKey:@"RLPNPRailHidden"];
    [self applyTheme];[self anlPaint];[self layoutWebPlayback];
}
- (void)layoutWebPlayback {
    CGFloat w=self.webCanvas.bounds.size.width,h=self.webCanvas.bounds.size.height;
    CGFloat c=MIN(236,MAX(132,h*.24)), gutter=16, top=44, by=top+c+18, bottom=MAX(by+60,h-86);
    self.cover.frame=NSMakeRect(gutter,top,c,c);
    CGFloat x=gutter+c+26, infoY=top+MAX(0,(c-130)/2), iw=MAX(80,w-x-24);
    self.kindLabel.frame=NSMakeRect(x,infoY,iw,16);self.titleLabel2.frame=NSMakeRect(x,infoY+25,MAX(50,MIN(iw-42,620)),30);
    [self.titleLabel2 sizeToFit];self.titleLabel2.frame=NSMakeRect(x,infoY+25,MIN(MAX(100,self.titleLabel2.frame.size.width),iw-44),30);
    self.favoriteButton.frame=NSMakeRect(NSMaxX(self.titleLabel2.frame)+8,infoY+24,28,30);
    self.artistLabel2.frame=NSMakeRect(x,infoY+63,iw,21);self.metaLabel.frame=NSMakeRect(x,infoY+88,iw,18);
    CGFloat bx=x;for(NSButton *b in @[self.castButton,self.saveButton,self.compareBtn,self.worksBtn]){CGFloat bw=b==self.worksBtn?100:(b==self.saveButton?112:94);b.frame=NSMakeRect(bx,infoY+113,bw,24);bx+=bw+6;}
    self.closeButton.frame=NSMakeRect(w-56,16,38,38);self.railToggle.frame=NSMakeRect(w-100,18,34,34);self.analysisToggle.frame=NSMakeRect(w-142,18,34,34);
    CGFloat col=(w-2*gutter-36)/4, side=MIN(340,col), bodyH=MAX(60,bottom-by);
    self.analysisPanel.frame=NSMakeRect(gutter,by,side,bodyH);self.railPanel.frame=NSMakeRect(w-gutter-side,by,side,bodyH);
    self.lyricScroll.frame=NSMakeRect(gutter+col+18,by,col*2,bodyH);
    if(self.analysisPanel.hidden&&self.railPanel.hidden)self.lyricScroll.frame=NSMakeRect(gutter,by,w-32,bodyH);
    self.analysisStatus.frame=NSMakeRect(12,bodyH-26,MAX(50,side-24),16);
    self.anlAuto.frame=NSMakeRect(MAX(8,side-156),bodyH-57,48,25);self.anlExpand.frame=NSMakeRect(MAX(56,side-108),bodyH-57,54,25);self.anlRun.frame=NSMakeRect(MAX(110,side-54),bodyH-57,46,25);
    CGFloat available=MAX(90,bodyH-96),firstCard=MIN(100,available*.4),otherCard=MIN(74,(available-firstCard)/2);
    CGFloat y=bodyH-68;for(NSButton *b in @[self.anlDyn,self.anlQual,self.anlFake]){CGFloat ch=b==self.anlDyn?firstCard:otherCard;b.frame=NSMakeRect(12,y-ch,MAX(40,side-24),ch);y-=ch+8;}
    self.anlDetailScroll.frame=NSMakeRect(12,12,MAX(40,side-24),MAX(40,bodyH-80));self.anlReanalyze.frame=NSMakeRect(12,bodyH-82,90,22);
    self.railTitle.frame=NSMakeRect(12,bodyH-30,72,15);
    self.railDensity.frame=NSMakeRect(MAX(80,side-130),bodyH-35,116,24);
    CGFloat ry=bodyH-46;for(NSButton *b in self.railCards){CGFloat ch=self.railDensity.selectedSegment?116:72;b.frame=NSMakeRect(10,ry-ch,MAX(40,side-20),ch);ry-=ch+8;}
    self.webControls.frame=NSMakeRect(MAX(16,(w-1160)/2),h-76,MIN(1160,w-32),58);[self.webControls layout];
    [self layoutLyricRows];
}
- (void)layoutLyricRows {
    CGFloat w=self.lyricScroll.contentSize.width, h=self.lyricScroll.contentSize.height;
    CGFloat pad=MAX(26,h/2-18),y=pad;for(NSButton *b in self.lyricRows){b.frame=NSMakeRect(6,y,MAX(40,w-12),30);y+=30;}
    self.lyricDocument.frame=NSMakeRect(0,0,w,MAX(h,y+pad));self.lyricsEmpty.frame=NSMakeRect(8,MAX(0,h/2-30),MAX(40,w-16),60);
}
- (void)applyLyricText:(NSString *)text forPath:(NSString *)path {
    if(![path isEqualToString:self.currentPath?:@""])return;
    self.lyricLines=[RLPLyrics parse:text];self.lyricActiveIndex=-1;
    for(NSView *v in [self.lyricRows copy])[v removeFromSuperview];[self.lyricRows removeAllObjects];
    self.lyricsEmpty.hidden=self.lyricLines.count>0;
    self.lyricsEmpty.stringValue=RLPTr(@"没有歌词 · 同名 LRC、内嵌歌词或在线补全");
    for(RLPLyricLine *line in self.lyricLines){NSButton *b=[NSButton buttonWithTitle:line.text target:self action:@selector(onLyricLine:)];b.tag=self.lyricRows.count;b.bordered=NO;b.font=[NSFont systemFontOfSize:14];[self.lyricDocument addSubview:b];[self.lyricRows addObject:b];}
    [self layoutLyricRows];[self updateLyricPosition:self.webStatus.position];
}
- (void)updateLyricPosition:(double)pos {
    NSInteger at=[RLPLyrics activeIndex:self.lyricLines position:pos];self.lyricActiveIndex=at;
    for(NSUInteger i=0;i<self.lyricRows.count;i++){BOOL on=(NSInteger)i==at;NSButton *b=self.lyricRows[i];b.attributedTitle=[[NSAttributedString alloc] initWithString:b.title attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:14 weight:on?NSFontWeightSemibold:NSFontWeightRegular],NSForegroundColorAttributeName:on?[RLPTheme current].text:[RLPTheme current].mut2}];}
    if(at<0||[NSDate timeIntervalSinceReferenceDate]<self.lyricManualUntil)return;
    if(at<(NSInteger)self.lyricRows.count){CGFloat y=NSMidY(self.lyricRows[at].frame)-self.lyricScroll.contentSize.height/2;
        self.lyricManualUntil=DBL_MAX;[self.lyricScroll.contentView scrollToPoint:NSMakePoint(0,MAX(0,y))];[self.lyricScroll reflectScrolledClipView:self.lyricScroll.contentView];self.lyricManualUntil=0;}
}
- (void)onLyricScrolled:(NSNotification *)n {if(self.lyricManualUntil!=DBL_MAX)self.lyricManualUntil=[NSDate timeIntervalSinceReferenceDate]+3;}
- (void)onLyricLine:(NSButton *)b {if(b.tag<0||b.tag>=(NSInteger)self.lyricLines.count)return;double t=self.lyricLines[b.tag].t;if(t<0||self.webStatus.duration<=0)return;self.lyricManualUntil=0;[[RLPCoreClient shared] postJSON:[NSString stringWithFormat:@"/api/seek?pos=%.6f",t/self.webStatus.duration] body:nil completion:nil];}
- (NSMenu *)playbackContextMenu {
    NSMenu *menu=[NSMenu new];
    NSMenuItem *compare=[[NSMenuItem alloc] initWithTitle:RLPTr(@"对比同目录版本") action:@selector(onCompare:) keyEquivalent:@""];compare.target=self;[menu addItem:compare];
    NSMenuItem *works=[[NSMenuItem alloc] initWithTitle:RLPTr(@"古典作品版本") action:@selector(onOpenWorks:) keyEquivalent:@""];works.target=self;[menu addItem:works];
    return menu;
}
- (void)onClosePlayback:(id)sender {[[NSNotificationCenter defaultCenter] postNotificationName:@"RLPCloseNowPlayingNotification" object:nil];}
- (void)cancelOperation:(id)sender {[self onClosePlayback:sender];}
- (void)onToggleAnalysis:(id)sender {self.analysisPanel.hidden=!self.analysisPanel.hidden;[[NSUserDefaults standardUserDefaults] setBool:self.analysisPanel.hidden forKey:@"RLPNPAnalysisHidden"];[self layoutWebPlayback];}
- (void)onToggleRail:(id)sender {self.railPanel.hidden=!self.railPanel.hidden;[[NSUserDefaults standardUserDefaults] setBool:self.railPanel.hidden forKey:@"RLPNPRailHidden"];[self layoutWebPlayback];}
- (void)onToggleAuto:(id)sender {self.anlAutoEnabled=!self.anlAutoEnabled;self.anlAutoSettingAt=[NSDate timeIntervalSinceReferenceDate];[[RLPCoreClient shared] postJSON:@"/api/settings" body:self.anlAutoEnabled?@"autoanl=1":@"autoanl=0" completion:nil];[self anlPaint];if(self.anlAutoEnabled)[self anlAutoTickForPath:self.currentPath playing:self.webStatus.playing paused:self.webStatus.paused];}
- (void)onPrevious:(id)s {[[RLPCoreClient shared] postJSON:@"/api/skip?dir=-1" body:nil completion:nil];}
- (void)onNext:(id)s {[[RLPCoreClient shared] postJSON:@"/api/skip?dir=1" body:nil completion:nil];}
- (void)onPause:(id)s {BOOL pause=self.webStatus.playing&&!self.webStatus.paused;[[RLPCoreClient shared] postJSON:pause?@"/api/pause?on=1":@"/api/pause?on=0" body:nil completion:nil];}
- (void)onStop:(id)s {[[RLPCoreClient shared] postJSON:@"/api/stop" body:nil completion:nil];}
- (void)onCycleMode:(id)s {self.playbackMode=(self.playbackMode+1)%4;[[RLPCoreClient shared] postJSON:[NSString stringWithFormat:@"/api/playmode?mode=%ld",(long)self.playbackMode] body:nil completion:nil];}
- (void)onCommitSeek:(id)s {if(self.webControls.seek.dragging)return;[[RLPCoreClient shared] postJSON:[NSString stringWithFormat:@"/api/seek?pos=%.6f",self.webControls.seek.doubleValue] body:nil completion:nil];self.lyricManualUntil=0;}
- (void)onCommitVolume:(id)s {if(self.webControls.volume.dragging)return;double db=RLPNPVolPosToDb(self.webControls.volume.doubleValue);self.webControls.volLabel.stringValue=RLPNPVolDbLabel(db);[[RLPCoreClient shared] postJSON:[NSString stringWithFormat:@"/api/volume?db=%.1f",db] body:nil completion:nil];}
- (void)onSaveCurrent:(id)s {if(self.currentPath.length)RLPShowSaveToPlaylist(self.currentPath,self.saveButton);}
// Device identity is location (UPnP description URL or airplay://), never display name.
- (NSString *)castBodyForDevice:(NSDictionary *)device {
    NSString *dev=[device[@"location"] isKindOfClass:NSString.class]?device[@"location"]:nil;
    if(!dev.length||!self.currentPath.length)return nil;
    NSMutableCharacterSet *allowed=[[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];[allowed removeCharactersInString:@"&=+?#"];
    NSString *deviceValue=[dev stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    NSString *fileValue=[self.currentPath stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    return [NSString stringWithFormat:@"dev=%@&file=%@&volume=%.1f",deviceValue,fileValue,self.webStatus?self.webStatus.volumeDb:-120.0];
}
- (void)onCastCurrent:(id)s {
    if(!self.currentPath.length)return;__weak __typeof__(self) ws=self;
    [[RLPCoreClient shared] getJSON:@"/api/cast/devices" completion:^(NSDictionary *j){__typeof__(self) s=ws;if(!s)return;NSArray *devs=[j[@"devices"] isKindOfClass:NSArray.class]?j[@"devices"]:@[];if(!devs.count){RLPToast(j[@"hint"]?:RLPTr(@"未发现可投放设备"));return;}
        NSAlert *a=[NSAlert new];a.messageText=RLPTr(@"推送当前曲目到设备");NSPopUpButton *p=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,0,320,28)];for(NSDictionary *d in devs)[p addItemWithTitle:d[@"name"]?:@"UPnP"];a.accessoryView=p;[a addButtonWithTitle:RLPTr(@"推送")];[a addButtonWithTitle:RLPTr(@"取消")];if([a runModal]!=NSAlertFirstButtonReturn)return;NSDictionary *d=devs[p.indexOfSelectedItem];NSString *body=[s castBodyForDevice:d];if(body.length)[[RLPCoreClient shared] postJSON:@"/api/cast/start" body:body completion:^(NSDictionary *r){if(![r[@"ok"] boolValue])RLPToast(r[@"error"]?:RLPTr(@"投放失败"));}];}];
}
- (void)onRailDensity:(id)s {[self renderRailMetadata];[self layoutWebPlayback];}
- (void)renderRailMetadata {
    NSDictionary *m=self.trackMetadata?:@{};NSArray *names=@[m[@"title"]?:@"",m[@"album"]?:@"",m[@"artist"]?:@""];NSArray *labels=@[RLPTr(@"歌曲"),RLPTr(@"专辑"),RLPTr(@"艺术家")];
    for(NSUInteger i=0;i<self.railCards.count;i++){NSString *name=[names[i] isKindOfClass:NSString.class]?names[i]:@"";NSString *value=name.length?name:RLPTr(@"暂无资料");NSString *detail=self.railDensity.selectedSegment?([NSString stringWithFormat:@"\n%@",m[@"genre"]?:@""]):@"";NSButton *b=self.railCards[i];b.title=[NSString stringWithFormat:@"%@\n%@%@",labels[i],value,detail];b.attributedTitle=[[NSAttributedString alloc] initWithString:b.title attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:11.5],NSForegroundColorAttributeName:[RLPTheme current].text2}];}
}
- (void)onRailCard:(NSButton *)b {NSArray *kinds=@[@"track",@"release",@"person"];NSArray *names=@[self.trackMetadata[@"title"]?:@"",self.trackMetadata[@"album"]?:@"",self.trackMetadata[@"artist"]?:@""];if(b.tag>=3||![(NSString *)names[b.tag] length])return;[self.knowledge loadKind:kinds[b.tag] name:names[b.tag] artist:self.trackMetadata[@"artist"]];[self.knowledgePopover close];self.knowledgePopover=RLPShowCardPopover(b,RLPCardController(self.knowledge,420,380),420);}

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

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self];[self.poll invalidate];[self.lyricRetryTimer invalidate]; }

- (void)activate {
    [self startPolling];
    if(self.polling&&self.currentPath.length)[self loadLyricsForPath:self.currentPath];
}

- (void)viewDidDisappear {
    [self.knowledge cancelLoading];
    [super viewDidDisappear];
    [self stopPolling];self.lyricSeq++;[self.knowledgePopover close];
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
    self.poll = [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf refresh];
    }];
    [self refresh];
}

- (void)stopPolling {
    self.statusEpoch++;self.statusInFlight=NO;[self.lyricRetryTimer invalidate];self.lyricRetryTimer=nil;
    [self.poll invalidate];
    self.poll = nil;
    self.polling = NO;
}

- (void)refresh {
    if(self.statusInFlight)return;self.statusInFlight=YES;const NSUInteger epoch=self.statusEpoch;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/status" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || epoch!=self_.statusEpoch) return;
        self_.statusInFlight=NO;
        RLPPlaybackStatus *st = [RLPPlaybackStatus statusFromJSON:json];
        if (!st) return;
        NSString *path = st.currentPath ?: @"";
        self_.webStatus=st;
        self_.webControls.posLabel.stringValue=RLPFmtDuration(st.position);self_.webControls.durLabel.stringValue=RLPFmtDuration(st.duration);
        if(!self_.webControls.seek.dragging)self_.webControls.seek.doubleValue=st.duration>0?st.position/st.duration:0;
        if(!self_.webControls.volume.dragging)self_.webControls.volume.doubleValue=RLPNPVolDbToPos(st.volumeDb);
        self_.webControls.volLabel.stringValue=RLPNPVolDbLabel(st.volumeDb);
        self_.webControls.playBtn.image=[NSImage imageWithSystemSymbolName:st.playing&&!st.paused?@"pause.fill":@"play.fill" accessibilityDescription:@"播放 / 暂停"];
        self_.webControls.playBtn.contentTintColor=NSColor.whiteColor;
        [self_ updateLyricPosition:st.position];
        if(!self_.trackMetadata.count || ![path isEqualToString:self_.currentPath?:@""])self_.titleLabel2.stringValue=path.length?path.lastPathComponent.stringByDeletingPathExtension:RLPTr(@"未播放");
        if(st.error.length)self_.artistLabel2.stringValue=st.error;
        if (![path isEqualToString:self_.currentPath ?: @""]) {
            BOOL cancelPrevious=self_.anlBusy;
            self_.currentPath = path;self_.trackMetadata=@{};self_.artistLabel2.stringValue=@"";self_.metaLabel.stringValue=@"";[self_ refreshQueueContext];[self_ refreshFavorite];
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
            if (cancelPrevious) {
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
    const NSUInteger seq=++self.lyricSeq;[self.lyricRetryTimer invalidate];self.lyricRetryTimer=nil;
    if(!path.length||[path hasPrefix:@"http://"]||[path hasPrefix:@"https://"]){[self applyLyricText:@"" forPath:path];self.lyricsEmpty.stringValue=path.length?RLPTr(@"网络曲目暂无歌词"):RLPTr(@"还没有播放曲目");return;}
    self.lyricRetry=0;[self fetchLyricPath:path sequence:seq];
}
- (void)fetchLyricPath:(NSString *)path sequence:(NSUInteger)seq {
    __weak __typeof__(self) ws=self;
    [[RLPCoreClient shared] getJSON:[@"/api/lyrics?file=" stringByAppendingString:RLPEnc(path)] completion:^(NSDictionary *j){__typeof__(self) s=ws;if(!s||seq!=s.lyricSeq||![s.currentPath isEqual:path])return;
        NSString *lrc=[j[@"lrc"] isKindOfClass:NSString.class]?j[@"lrc"]:@"";[s applyLyricText:lrc forPath:path];
        if(!j){s.lyricsEmpty.stringValue=RLPTr(@"歌词加载失败");return;}
        const NSInteger waits[]={1,2,3,5,8,13};
        if(!s.lyricLines.count&&s.lyricRetry<6){s.lyricsEmpty.stringValue=RLPTr(@"歌词加载中… 正在等后台补全");NSInteger delay=waits[s.lyricRetry++];s.lyricRetryTimer=[NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer *t){__typeof__(self) n=ws;if(n&&seq==n.lyricSeq&&n.polling)[n fetchLyricPath:path sequence:seq];}];}
    }];
}

/// 按**文件路径**取封面：/api/cover?file=… 是既有端点（与 web 版单曲页同一个），
/// 内部走「内嵌图 → 同目录图 → 所属专辑封面」三级兜底，因此不需要先解析专辑 key。
/// 用单调递增的请求序号丢弃过期结果：快速切歌时慢请求回来不能盖掉新封面。
- (void)loadCoverForPath:(NSString *)path {
    if (!path.length) {
        self.coverSeq++;self.cover.image = nil;self.webCanvas.blurredCover=nil;self.webCanvas.needsDisplay=YES;
        return;
    }
    const NSUInteger seq = ++self.coverSeq;
    NSString *url = [NSString stringWithFormat:@"/api/cover?file=%@", RLPEnc(path)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getData:url completion:^(NSData * _Nullable data) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.coverSeq) return;   // 过期结果直接丢
        self_.cover.image = data.length ? [[NSImage alloc] initWithData:data] : nil;
        [self_ updateBlurredCover];
    }];
}

/// 取当前曲的标题/艺术家，再据此拉 AI 资料层。
/// 为什么要先 /api/meta：/api/status 只给路径，资料层要的是"实体名"。
- (void)loadMetaAndKnowledgeForPath:(NSString *)path {
    if (!path.length) {
        self.trackMetadata=@{};[self renderRailMetadata];
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
        self_.trackMetadata=json?:@{};
        NSString *album=[json[@"album"] isKindOfClass:NSString.class]?json[@"album"]:@"";
        self_.artistLabel2.stringValue=[NSString stringWithFormat:@"%@%@%@",artist,album.length?@" · ":@"",album];
        NSMutableArray *format=[NSMutableArray array];if([json[@"codec"] isKindOfClass:NSString.class])[format addObject:[json[@"codec"] uppercaseString]];
        if([json[@"sampleRate"] doubleValue]>0)[format addObject:[NSString stringWithFormat:@"%g kHz",[json[@"sampleRate"] doubleValue]/1000]];
        if([json[@"bits"] integerValue]>0)[format addObject:[NSString stringWithFormat:@"%ld bit",(long)[json[@"bits"] integerValue]]];
        self_.kindLabel.stringValue=[NSString stringWithFormat:@"%@ · %@",RLPTr(@"正在播放"),[format componentsJoinedByString:@" / "]];
        [self_ renderRailMetadata];[self_ layoutWebPlayback];
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
    self.comparePopover = RLPShowCardPopover(self.titleLabel2, RLPCardController(s, 450, 320), 450);
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
    BOOL on=!self.favorite;NSString *favoritePath=[self.currentPath copy];
    NSString *url = [NSString stringWithFormat:@"/api/fav?file=%@&on=%d", RLPEnc(self.currentPath),on?1:0];
    [[RLPCoreClient shared] postJSON:url body:@"" completion:^(NSDictionary * _Nullable json) {
        if(![favoritePath isEqualToString:self.currentPath])return;
        if (json && [json[@"ok"] boolValue]) {self.favorite=on;self.favoriteButton.title=on?@"♥":@"♡";RLPToast(RLPTr(on?@"已收藏":@"已取消收藏"));}
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
 self.anlLevel=level;BOOL open=level!=RLPAnlLevelCollapsed;
 self.anlDetailScroll.hidden=!open;self.anlReanalyze.hidden=!open;
 for(NSButton *button in @[self.anlDyn,self.anlQual,self.anlFake])button.hidden=open;
 self.anlExpand.title=level==RLPAnlLevelCollapsed?RLPTr(@"详细"):(level==RLPAnlLevelMetrics?RLPTr(@"全部指标"):RLPTr(@"收起"));[self anlPaint];
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
    [self.anlDyn setTitle:[NSString stringWithFormat:@"%@\n%@", RLPTr(@"动态"), dyn]];
    [self.anlQual setTitle:[NSString stringWithFormat:@"%@\n%@", RLPTr(@"音质"), qual]];
    [self.anlFake setTitle:[NSString stringWithFormat:@"%@\n%@", RLPTr(@"假无损"), fake]];
    self.anlDyn.toolTip = dyn; self.anlQual.toolTip = qual; self.anlFake.toolTip = fake;

    self.analysisStatus.stringValue=[NSString stringWithFormat:@"%@ · %@",RLPTr(@"音频分析"),self.anlBusy?RLPTr(@"分析中…"):(self.anlError?: (h?RLPTr(@"已分析"):RLPTr(@"未分析")))];
    self.anlAuto.state=self.anlAutoEnabled?NSControlStateValueOn:NSControlStateValueOff;
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
    // web 的右键「音质体检」用 /api/track/health，单曲页用 /api/health —— 后端是同一个
    // handler（rtaweb 的 aliasing），两个名字都真存在。这里按 web 的体检入口名走，
    // 让两端在日志/诊断里看到同一个路径。
    NSString *url = [NSString stringWithFormat:@"/api/track/health?file=%@%@", RLPEnc(path), force ? @"&force=1" : @""];
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
    RLPTheme *t=[RLPTheme current];self.webCanvas.needsDisplay=YES;self.cover.layer.backgroundColor=t.bg2.CGColor;
    self.titleLabel2.textColor=t.text;self.artistLabel2.textColor=t.mut;self.metaLabel.textColor=t.mut2;self.kindLabel.textColor=t.mut2;
    self.railTitle.textColor=t.mut2;self.analysisStatus.textColor=t.mut2;self.lyricsEmpty.textColor=t.mut2;
    for(NSView *p in @[self.analysisPanel,self.railPanel]){p.wantsLayer=YES;p.layer.cornerRadius=14;p.layer.borderWidth=1;p.layer.borderColor=t.line.CGColor;p.layer.backgroundColor=[t.isLight?[NSColor colorWithSRGBRed:15/255. green:23/255. blue:42/255. alpha:.04]:[NSColor colorWithWhite:1 alpha:.045] CGColor];}
    for(NSButton *b in @[self.anlDyn,self.anlQual,self.anlFake]){b.layer.backgroundColor=t.bg.CGColor;b.layer.borderColor=t.line.CGColor;b.contentTintColor=t.text2;}
    for(NSButton *b in self.railCards){b.layer.backgroundColor=t.hov.CGColor;b.layer.borderColor=t.line.CGColor;}
    self.anlDetail.textColor=t.text;[self.webControls applyTheme];self.webControls.playBtn.layer.backgroundColor=t.accent.CGColor;self.webControls.playBtn.contentTintColor=NSColor.whiteColor;
    [self.knowledge applyTheme];[self renderRailMetadata];[self updateLyricPosition:self.webStatus.position];[self updateBlurredCover];
}
- (void)updateBlurredCover {
    NSImage *image=self.cover.image;if(!image){self.webCanvas.blurredCover=nil;self.webCanvas.needsDisplay=YES;return;}
    NSData *data=image.TIFFRepresentation;if(!data)return;NSUInteger seq=self.coverSeq;BOOL light=[RLPTheme current].isLight;__weak __typeof__(self) ws=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{
        CIImage *ci=[CIImage imageWithData:data];if(!ci)return;CGRect rect=ci.extent;
        CIFilter *blur=[CIFilter filterWithName:@"CIGaussianBlur"];[blur setValue:[ci imageByClampingToExtent] forKey:kCIInputImageKey];[blur setValue:@64 forKey:kCIInputRadiusKey];
        CIFilter *color=[CIFilter filterWithName:@"CIColorControls"];[color setValue:[blur.outputImage imageByCroppingToRect:rect] forKey:kCIInputImageKey];[color setValue:light?@1.05:@1.15 forKey:kCIInputSaturationKey];
        CIFilter *exposure=[CIFilter filterWithName:@"CIExposureAdjust"];[exposure setValue:color.outputImage forKey:kCIInputImageKey];[exposure setValue:@(log2(light?1.12:.38)) forKey:kCIInputEVKey];
        CIContext *ctx=[CIContext contextWithOptions:nil];CGImageRef cg=[ctx createCGImage:exposure.outputImage fromRect:rect];if(!cg)return;NSImage *result=[[NSImage alloc] initWithCGImage:cg size:image.size];CGImageRelease(cg);
        dispatch_async(dispatch_get_main_queue(),^{__typeof__(self) s=ws;if(!s||seq!=s.coverSeq||light!=[RLPTheme current].isLight)return;s.webCanvas.blurredCover=result;s.webCanvas.needsDisplay=YES;});
    }});
}
- (void)refreshFavorite {
    NSString *path=self.currentPath;if(!path.length)return;__weak __typeof__(self) ws=self;
    [[RLPCoreClient shared] getJSON:@"/api/fav/list" completion:^(NSDictionary *j){__typeof__(self) s=ws;if(!s||![path isEqual:s.currentPath])return;NSArray *items=[j[@"files"] isKindOfClass:NSArray.class]?j[@"files"]:([j[@"items"] isKindOfClass:NSArray.class]?j[@"items"]:@[]);s.favorite=NO;for(id item in items){NSString *p=[item isKindOfClass:NSString.class]?item:([item isKindOfClass:NSDictionary.class]?item[@"file"]:nil);if([RLPNPFavKey(p) isEqual:RLPNPFavKey(path)])s.favorite=YES;}s.favoriteButton.title=s.favorite?@"♥":@"♡";}];
}
- (void)refreshQueueContext {
    NSString *path=self.currentPath;__weak __typeof__(self) ws=self;
    [[RLPCoreClient shared] getJSON:@"/api/queue?meta=1" completion:^(NSDictionary *j){__typeof__(self) s=ws;if(!s||![path isEqual:s.currentPath])return;s.playbackMode=[j[@"mode"] integerValue];NSArray *items=[j[@"items"] isKindOfClass:NSArray.class]?j[@"items"]:@[];NSInteger i=[j[@"index"] integerValue];if(i>=0&&i+1<(NSInteger)items.count){id next=items[i+1];s.metaLabel.stringValue=[NSString stringWithFormat:@"下一首：%@ · 剩 %ld 首",[next isKindOfClass:NSString.class]?[next lastPathComponent]:@"",(long)items.count-i-1];}}];
}
@end
