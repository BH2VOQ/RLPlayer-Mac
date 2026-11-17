// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPNowPlayingViewController.mm — 正在播放（纯 AppKit）
//
// 只读展示 + 少量动作（播放/暂停、收藏、体检）。歌词来自 /api/lyrics?file=…，
// 音质体检来自 /api/health?file=…（都是既有端点，UI 不重复实现分析）。
#import "RLPNowPlayingViewController.h"
#import "RLPVolumeKnobView.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPSupport.h"
#import "RLPTheme.h"
#import "RLPKnowledgeView.h"
#import "RLPAnalysisSummary.h"
#import "RLPLyrics.h"
#import "RLPTrackActions.h"
#import "RLPWaveformView.h"   // U2 包3：控制条上方的波形条（identifier np.waveform）
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
/// U2 包3：波形取数（只在切曲/首次进入调用；/api/status 轮询只搬播放头，绝不再取数）。
- (void)loadWaveformForPath:(NSString *)path;
/// 波形点击 → POST /api/seek?pos=（守卫与 onCommitSeek 同一口径）。
- (void)seekFromWaveformAtFraction:(double)fraction;
/// 每轮 /api/status 只把播放头搬到新位置（不重算波形）。
- (void)updateWaveformPlayheadForStatus:(RLPPlaybackStatus *)status;
/// web buildNpMetaHtml 的同构投影（补全芯片行）。审计用它喂合成 meta 验渲染，
/// 真实路径由 /api/meta 异步驱动。
- (void)renderMetaChipsFromMeta:(NSDictionary *)json;
- (NSMenu *)playbackContextMenu;
- (void)onClosePlayback:(id)sender;
/// web applyRep：循环键图标/配色/tooltip 随四档模式变化 + #npRepOne 角标只在单曲循环显示。
- (void)applyPlayModeUI;
/// 从队列快照取 mode 并刷新循环/随机芯片（web applyRep）。
- (void)applyPlayModeFromJSON:(NSDictionary *)json;
/// 只同步播放模式、不依赖当前曲：页面重新打开时用（refresh 只在换曲分支拉队列）。
- (void)refreshPlayMode;
/// 投放「推送」落库：/api/cast/start 成功后立刻刷芯片（不等 2s 轮询）。
- (void)castStartToDevice:(NSDictionary *)device;
/// web updateNextTrackInfo 的原生同构：按队列快照刷新 `#npNextTrackHero`（停止/无队列 → 隐藏）。
- (void)applyQueueSnapshot:(nullable NSDictionary *)json;
/// web `.chip:hover` 的视觉：底 --hov / 边 --acc / 字 --txt；退出回到 `.chip` 静态样式。
- (void)applyChipHover:(NSButton *)button hovered:(BOOL)hovered;
/// 歌词空态/加载态的两行文案（web `#npLyric` 空态与抽屉加载态），判据直接驱动这条路径。
- (void)setLyricsPlaceholder:(NSString *)main detail:(NSString *)detail;
/// web `.nplyric2{-webkit-mask-image:linear-gradient(180deg,transparent 0,#000 26px,#000 calc(100% - 26px),transparent 100%)}`
/// 的原生等价：给歌词滚动视图挂 CAGradientLayer 遮罩（首/末行渐隐，26pt 全不透明区）。
- (void)updateLyricFadeMask;
/// `.npchipwrap` 的卡片排版（contentOffset 只影响卡片，栏头/分段/收起键不动）。
- (void)railLayoutChips;
/// web `#npDrawer`：页内抽屉浮卡（frame/圆角/阴影/遮罩点击关闭；不动底层滚动）。
- (void)openDataDrawer;
- (void)closeDataDrawer;
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
/// web `.npseek{height:5px}` / `.npseek:hover{height:7px}`：悬停时轨道加粗到 7pt。
@property (nonatomic, assign) BOOL hovered;
- (CGFloat)barThickness;
@end
@implementation RLPNPAccentCell
- (CGFloat)barThickness { return self.hovered ? 7.0 : 5.0; }
- (void)drawBarInside:(NSRect)r flipped:(BOOL)flipped {
    const CGFloat th=[self barThickness];
    CGFloat y=NSMidY(r)-th/2; NSRect track=NSMakeRect(r.origin.x,y,r.size.width,th);
    [[RLPTheme current].track setFill]; [[NSBezierPath bezierPathWithRoundedRect:track xRadius:th/2 yRadius:th/2] fill];
    double p=(self.doubleValue-self.minValue)/MAX(.001,self.maxValue-self.minValue);
    track.size.width*=MAX(0,MIN(1,p)); [[RLPTheme current].accent setFill]; [[NSBezierPath bezierPathWithRoundedRect:track xRadius:th/2 yRadius:th/2] fill];
}
@end

#pragma mark - 底部控制区（web #npPage .npctl2 的原生落点）

/// 拖动提交滑杆：拖动期间 0.8s 轮询**不得**回写（否则滑块被"橡皮筋"拉回去），
/// 松手只提交一次（进度 = /api/seek，音量 = /api/volume；每像素发一个请求会堆请求）。
/// 与底栏 RLPPlaybackBarView 的 RLPCommitSlider 同一手法。
@interface RLPNPSlider : NSSlider
@property (nonatomic, assign, readonly) BOOL dragging;
@property (nonatomic, copy, nullable) void (^onCommit)(void);
/// 只有 #npSeek 打开（web `.npseek:hover{height:7px}`）；音量条保持 5pt（web `input[type=range]` 默认外观）。
@property (nonatomic, assign) BOOL hoverGrow;
@end

@implementation RLPNPSlider
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (!self.hoverGrow) return;
    for (NSTrackingArea *a in self.trackingAreas)
        if (a.owner == self) [self removeTrackingArea:a];
    NSTrackingArea *hover = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect)
               owner:self userInfo:nil];
    [self addTrackingArea:hover];
}
- (void)mouseDown:(NSEvent *)event {
    _dragging = YES;
    [super mouseDown:event];      // NSSlider 在这里跑完整个拖动循环
    _dragging = NO;
    if (self.onCommit) self.onCommit();
}
- (void)mouseEntered:(NSEvent *)event {
    if (!self.hoverGrow || ![self.cell isKindOfClass:[RLPNPAccentCell class]]) return;
    ((RLPNPAccentCell *)self.cell).hovered = YES;
    [self setNeedsDisplay:YES];
}
- (void)mouseExited:(NSEvent *)event {
    if (!self.hoverGrow || ![self.cell isKindOfClass:[RLPNPAccentCell class]]) return;
    ((RLPNPAccentCell *)self.cell).hovered = NO;
    [self setNeedsDisplay:YES];
}
@end

#pragma mark - web hover 态（.k / .npclose / .nptoggle / .chip / .npcast / .npchip / .anlhide / .nprailhide）

/// 统一 hover 载体：跟踪区 + `hovered` 状态 + 由使用方注入的视觉回调。
/// 为什么不用 NSButton 的默认高亮：web 的 hover 是**颜色/描边/缩放**变化，
/// AppKit 默认只有按下高亮，用户悬停时看不到任何反馈（审计里就是"点了才知道能点"）。
@interface RLPHoverButton : NSButton
@property (nonatomic, assign, readonly) BOOL hovered;
/// 视觉回调：hovered=true/false 时按 web 的 hover 值改颜色/描边/transform。
@property (nonatomic, copy, nullable) void (^hoverApplier)(RLPHoverButton *button, BOOL hovered);
- (void)setHovered:(BOOL)hovered;
@end

@implementation RLPHoverButton
// readonly 属性 + 自实现 setter ⟹ Clang 不再自动合成 ivar/getter，必须显式合成。
@synthesize hovered = _hovered;
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (!self.wantsLayer) return;
    for (NSTrackingArea *a in self.trackingAreas)
        if (a.owner == self) return;       // 已经装过
    NSTrackingArea *hover = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect)
               owner:self userInfo:nil];
    [self addTrackingArea:hover];
}
- (void)mouseEntered:(NSEvent *)event { self.hovered = YES; }
- (void)mouseExited:(NSEvent *)event { self.hovered = NO; }
- (void)setHovered:(BOOL)hovered {
    if (self.hovered == hovered) return;
    _hovered = hovered;
    if (self.hoverApplier) self.hoverApplier(self, hovered);
    self.needsDisplay = YES;
}
@end

/// `.k` 键（32×32 / radius 9；play 是 `.k.big` 34×34 圆）：图标 + 圆角，圆角由 web 值给。
static NSButton *NPCreateKeyButton(NSString *symbol, NSString *tooltip, CGFloat radius) {
    RLPHoverButton *b = [[RLPHoverButton alloc] initWithFrame:NSZeroRect];
    b.bordered = NO;
    b.imagePosition = NSImageOnly;
    b.imageScaling = NSImageScaleProportionallyDown;
    b.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:RLPTr(tooltip)];
    b.contentTintColor = [RLPTheme current].text;
    b.toolTip = RLPTr(tooltip);
    b.wantsLayer = YES;
    b.layer.cornerRadius = radius;
    return b;
}

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

/// web 响应式字号的三个 clamp（`ui_page.h`）：
///   `#npTitle{font-size:clamp(19px,2.6vh,27px);line-height:1.3}`
///   `.npline{font-size:clamp(13px,1.9vh,17px);line-height:2.05}`
/// 1vh = 页面视口高的 1%；原生等价 = #npPage 覆盖层（webCanvas）bounds 高度。
/// 旧码标题固定 20、歌词固定 14 + 行盒 30 ⟹ 大窗口显小、小窗口行距错。
static CGFloat RLPNPClamp(CGFloat v, CGFloat lo, CGFloat hi) { return fmin(hi, fmax(lo, v)); }
static CGFloat RLPNPTitlePointSize(CGFloat viewportH) { return RLPNPClamp(viewportH * 0.026, 19.0, 27.0); }
static CGFloat RLPNPLyricPointSize(CGFloat viewportH) { return RLPNPClamp(viewportH * 0.019, 13.0, 17.0); }
/// web `.npline{line-height:2.05}`：行盒 = 字号×2.05（不是固定 30pt）。
static CGFloat RLPNPLyricLineStep(CGFloat pointSize) { return pointSize * 2.05; }

/// 收藏路径规范化：后端 /api/fav 的收藏键沿用了跨平台的 "\\" 分隔符
/// （实测 POST /api/fav?file=/a/b.flac 后 /api/fav/list 回 "\\a\\b.flac"），
/// 而 /api/status 的 current 是 "…/a/b.flac" ⟹ 逐字比较永远不相等、心形永远空心。
/// 两侧统一成 "/" 再比；不改后端语义，也不臆造第二个收藏存储。
static NSString *RLPNPFavKey(NSString *path) {
    if (![path isKindOfClass:[NSString class]]) return @"";
    return [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
}

/// 队列条目 → 路径：web 的 /api/queue items 是路径字符串；老配置/扩展可能给 {path|file} 字典。
/// 只做形状兼容，不改后端语义。
static NSString *RLPQueueItemPath(id item) {
    if ([item isKindOfClass:[NSString class]]) return (NSString *)item;
    if ([item isKindOfClass:[NSDictionary class]]) {
        id p = ((NSDictionary *)item)[@"path"] ?: ((NSDictionary *)item)[@"file"];
        return [p isKindOfClass:[NSString class]] ? p : @"";
    }
    return @"";
}

/// web `letter-spacing` 的 AppKit 等价：kern（单位 pt，与 1x px 等价）。
/// 为什么要重写整串 attributed 值：`stringValue` 会丢掉 kern，而 `.npkind`/`.anllab` 的 kern 是
/// web 版式的一部分（`.npkind{letter-spacing:1.6}`、`.anllab{letter-spacing:1.5}`）。
static void RLPSetKernedText(NSTextField *label, NSString *text, CGFloat kern) {
    if (!label) return;
    RLPTheme *t = [RLPTheme current];
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = label.alignment;
    ps.lineBreakMode = label.lineBreakMode;
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:(text ?: @"")
        attributes:@{NSFontAttributeName: (label.font ?: [NSFont systemFontOfSize:10]),
                     NSForegroundColorAttributeName: (label.textColor ?: t.mut2),
                     NSKernAttributeName: @(kern),
                     NSParagraphStyleAttributeName: ps}];
    label.attributedStringValue = as;
}

static BOOL RLPNPTextFieldIsEditing(NSTextField *field) {
    if (!field || !field.window) return NO;
    NSResponder *fr = field.window.firstResponder;
    if (!fr) return NO;
    if (fr == field) return YES;
    NSText *editor = field.currentEditor;
    if (editor && fr == editor) return YES;
    if ([fr isKindOfClass:[NSTextView class]] && ((NSTextView *)fr).delegate == (id)field) return YES;
    return NO;
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
/// v3.3.11 `npVolInput`：精确 dB 输入（-120~+20，Enter 确认）。
@property (nonatomic, strong) NSTextField *volDbField;
@property (nonatomic, assign) double preciseVolumeDb;
/// v3.3.11 `npVolFloor`：静音/恢复按钮；NAN = web 的 `volumeRestore === null`。
@property (nonatomic, strong) NSButton *volMuteBtn;
/// v3.3.11 npVolKnob：音量旋钮本体（web 用 64x64 SVG 圆盘；原生自绘同构控件）。
@property (nonatomic, strong) RLPVolumeKnobView *volKnob;
@property (nonatomic, assign) double volumeRestoreDb;
@property (nonatomic, strong) NSButton *repBtn;
/// web #npRepOne：单曲循环时叠在循环键上的「1」角标（10px/700）。
@property (nonatomic, strong) NSTextField *repBadge;
@property (nonatomic, strong) NSButton *prevBtn;
@property (nonatomic, strong) NSButton *playBtn;
@property (nonatomic, strong) NSButton *nextBtn;
@property (nonatomic, strong) NSButton *stopBtn;
@property (nonatomic, strong) NSImageView *volIcon;
@property (nonatomic, assign) NSUInteger volumeWriteSeq;
@property (nonatomic, assign) BOOL volumeWritePending;
@property (nonatomic, assign) double confirmedVolumeDb;
@property (nonatomic, assign) BOOL hasConfirmedVolume;
@property (nonatomic, assign) BOOL rawVolumeLocked;
@property (nonatomic, copy, nullable) void (^onVolumeWriteStarted)(void);
@property (nonatomic, copy, nullable) void (^onVolumeWriteFailed)(void);
- (void)applyVolumeLockedState:(BOOL)locked;
- (void)applyTheme;
@end

@implementation RLPNPControlBar

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)applyLanguage {
    self.seek.toolTip = RLPTr(@"进度");
    self.repBtn.toolTip = RLPTr(@"循环方式");
    [self applyVolumeLockedState:self.rawVolumeLocked];
}

- (void)applyVolumeLockedState:(BOOL)locked {
    self.rawVolumeLocked = locked;
    self.volKnob.locked = locked;
    self.volMuteBtn.enabled = !locked;
    self.volDbField.enabled = !locked;
    NSString *rawMsg = RLPTr(@"原始 DSD 音量由设备控制。请使用设备音量，或切回 PCM / 可处理的 DoP 路径。");
    self.volKnob.toolTip = locked ? rawMsg : RLPTr(@"音量");
    self.volDbField.toolTip = locked ? rawMsg : RLPTr(@"音量（dB）");
    self.volMuteBtn.toolTip = locked ? rawMsg : RLPTr(@"静音");
}

- (void)onVolumeDidChangeNotification:(NSNotification *)note {
    NSDictionary *info = note.userInfo;
    if (!info || info[@"source"] == self) return;
    if ([info[@"locked"] respondsToSelector:@selector(boolValue)]) {
        [self applyVolumeLockedState:[info[@"locked"] boolValue]];
    }
    if (self.volKnob.dragging || self.volume.dragging || self.volumeWritePending) return;
    // Reuse the owner's status barrier for confirmed writes from the other UI.
    if (self.onVolumeWriteStarted) self.onVolumeWriteStarted();
    if ([info[@"db"] respondsToSelector:@selector(doubleValue)]) {
        const double db = RLPVolClampDb([info[@"db"] doubleValue]);
        self.confirmedVolumeDb = db;
        self.hasConfirmedVolume = YES;
        [self updateVolumeUiForDb:db];
    }
}

/// v3.3.11 `setVol` 的公共落地：下发 /api/volume 并同步精确输入/标签/滑块。
/// 拖动中只同步界面（标签 / 精确输入 / 滑块 / 旋钮），不下发请求 —— 松开才 applyVolumeDb:。
- (void)updateVolumeUiForDb:(double)db {
    db = RLPVolClampDb(db);
    self.preciseVolumeDb = db;
    self.volDbField.layer.borderWidth = 0;
    if (!RLPNPTextFieldIsEditing(self.volDbField)) {
        self.volDbField.stringValue = [NSString stringWithFormat:@"%.1f", db];
    }
    self.volLabel.stringValue = RLPNPVolDbLabel(db);
    self.volume.doubleValue = RLPNPVolDbToPos(db);
    if (self.volKnob.db != db) self.volKnob.db = db;
}

- (void)applyVolumeDb:(double)db {
    if (self.rawVolumeLocked) return;
    db = RLPVolClampDb(db);
    if (!self.hasConfirmedVolume) {
        self.confirmedVolumeDb = RLPVolClampDb(self.preciseVolumeDb);
        self.hasConfirmedVolume = YES;
    }
    [self updateVolumeUiForDb:db];
    const NSUInteger seq = ++self.volumeWriteSeq;
    self.volumeWritePending = YES;
    if (self.onVolumeWriteStarted) self.onVolumeWriteStarted();
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:[NSString stringWithFormat:@"/api/volume?db=%.1f", db]
                                body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.volumeWriteSeq) return;
        self_.volumeWritePending = NO;
        const BOOL ok = [json isKindOfClass:[NSDictionary class]] && [json[@"ok"] boolValue];
        if (ok) {
            double confirmed = db;
            id dbVal = json[@"db"];
            if ([dbVal respondsToSelector:@selector(doubleValue)] && isfinite([dbVal doubleValue])) {
                confirmed = RLPVolClampDb([dbVal doubleValue]);
            }
            self_.confirmedVolumeDb = confirmed;
            self_.hasConfirmedVolume = YES;
            if (self_.onVolumeWriteStarted) self_.onVolumeWriteStarted();
            if (!self_.volKnob.dragging) {
                [self_ updateVolumeUiForDb:confirmed];
            }
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPVolumeDidChangeNotification"
                                                                object:nil
                                                              userInfo:@{ @"db": @(confirmed),
                                                                          @"locked": @(self_.rawVolumeLocked),
                                                                          @"source": self_ }];
        } else {
            const double fallback = self_.hasConfirmedVolume ? self_.confirmedVolumeDb : 0.0;
            if (!self_.volKnob.dragging) {
                [self_ updateVolumeUiForDb:fallback];
            }
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPVolumeDidChangeNotification"
                                                                object:nil
                                                              userInfo:@{ @"db": @(fallback),
                                                                          @"locked": @(self_.rawVolumeLocked),
                                                                          @"source": self_ }];
            RLPToast(RLPTr(@"音量更改未生效，已重新读取实际音量。"));
            if (self_.onVolumeWriteFailed) self_.onVolumeWriteFailed();
        }
    }];
}

/// v3.3.11 `toggleVolumeMute`（ui_script.h:6372-6379）：
/// 当前 <= -120 且无恢复值时直接返回；否则记住当前值并静音 / 恢复先前值。
- (void)onToggleVolumeMute:(id)sender {
    (void)sender;
    if (self.rawVolumeLocked) return;
    // 记忆值改为全局共享（v3.3.11 volumeRestore 唯一），播放页与底栏同一份。
    const double next = RLPVolumeMuteNextDb(self.preciseVolumeDb);
    if (isnan(next)) return;   // 上游：当前 -120 且无恢复值 ⟹ 什么都不做
    [self applyVolumeDb:next];
}

/// v3.3.11 `commitPreciseVolume` 的 AppKit 等价：-120~+20 dB，Enter 确认。
/// 非法值按 web `aria-invalid` 的等价处理：标红边框 + 恢复已确认值，**不发请求**。
- (void)onCommitPreciseVolume:(id)sender {
    (void)sender;
    if (self.rawVolumeLocked) return;
    NSString *text = [self.volDbField.stringValue stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // ★ 不能用 text.doubleValue 判合法性：非数字文本它会返回 0，而 0 dB 是**合法值**，
    //   于是 abc 会被当成 0 dB 下发（判据「非数字不下发」抓到的真缺陷）。
    //   必须要求整个字符串被扫描器完整消费。
    NSScanner *scan = [NSScanner scannerWithString:text];
    double db0 = 0.0;
    const BOOL numeric = [scan scanDouble:&db0] && scan.isAtEnd;
    const BOOL valid = numeric && text.length > 0 && isfinite(db0) && db0 >= -120.0 && db0 <= 20.0;
    if (!valid) {
        self.volDbField.layer.borderWidth = 1;
        self.volDbField.layer.borderColor = [RLPTheme current].danger.CGColor;
        self.volDbField.stringValue = [NSString stringWithFormat:@"%.1f", self.preciseVolumeDb];
        return;
    }
    [self applyVolumeDb:db0];
}

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
    self.seek.hoverGrow = YES;                 // web `.npseek:hover{height:7px}`

    // web `.nptime{font-size:12px}`（值用 tabular-nums，等宽数字）
    NSFont *timeFont = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.posLabel = RLPLabel(@"0:00", timeFont, t.mut);
    self.posLabel.identifier = @"np.pos";
    self.posLabel.alignment = NSTextAlignmentCenter;   // web `.tval{text-align:center}`
    self.sepLabel = RLPLabel(@"/", timeFont, t.mut);
    self.sepLabel.alignment = NSTextAlignmentCenter;
    self.durLabel = RLPLabel(@"0:00", timeFont, t.mut);
    self.durLabel.identifier = @"np.dur";
    self.durLabel.alignment = NSTextAlignmentCenter;   // web `.tval{text-align:center}`

    // `.k` 键统一 hover 载体（RLPHoverButton）：NSButton 便利构造器不会返回子类实例，
    // 直接 alloc，否则后面注入 hoverApplier 会 send unrecognized selector。
    RLPHoverButton *rep = [[RLPHoverButton alloc] initWithFrame:NSZeroRect];
    rep.title = RLPTr(@"顺序");
    rep.bezelStyle = NSBezelStyleRounded;
    rep.controlSize = NSControlSizeSmall;
    rep.font = t.small;
    self.repBtn = rep;
    self.repBtn.identifier = @"np.rep";
    self.repBtn.toolTip = RLPTr(@"循环方式");
    self.repBtn.wantsLayer = YES;
    self.repBtn.layer.cornerRadius = 9;         // web `.k{border-radius:9px}`

    // web #npRepOne：单曲循环时才显示的「1」角标（web 默认 display:none，applyRep 按档位开关）。
    // 旧码只有固定 repeat 图标、没有档位指示 ⟹ 用户看不出当前是顺序/列表/单曲/随机。
    self.repBadge = RLPLabel(@"1", [NSFont systemFontOfSize:10 weight:NSFontWeightBold], t.accentText);
    self.repBadge.identifier = @"npRepOne";
    self.repBadge.alignment = NSTextAlignmentCenter;
    self.repBadge.hidden = YES;

    // web `.k{32×32;border-radius:9}` / `.k.big{34×34;圆形;--acc}`，hover 分别是
    // `.k:hover{background:var(--hov2);color:var(--txt)}` 与 `.k.big:hover{filter:brightness(1.08)}`。
    self.prevBtn = NPCreateKeyButton(@"backward.fill", @"上一首", 9.0);
    self.prevBtn.identifier = @"np.prev";
    self.playBtn = NPCreateKeyButton(@"play.fill", @"播放 / 暂停", 17.0);
    self.playBtn.identifier = @"np.play";
    self.playBtn.layer.backgroundColor=t.accent.CGColor;self.playBtn.contentTintColor=NSColor.whiteColor;
    self.nextBtn = NPCreateKeyButton(@"forward.fill", @"下一首", 9.0);
    self.nextBtn.identifier = @"np.next";
    self.stopBtn = NPCreateKeyButton(@"stop.fill", @"停止", 9.0);
    self.stopBtn.identifier = @"np.stop";
    for (NSButton *b in @[self.prevBtn, self.nextBtn, self.stopBtn]) {
        ((RLPHoverButton *)b).hoverApplier = ^(RLPHoverButton *btn, BOOL hovered) {
            RLPTheme *t2 = [RLPTheme current];
            btn.layer.backgroundColor = (hovered ? t2.hov2 : NSColor.clearColor).CGColor;
            btn.contentTintColor = t2.text;
        };
    }
    ((RLPHoverButton *)self.playBtn).hoverApplier = ^(RLPHoverButton *btn, BOOL hovered) {
        RLPTheme *t2 = [RLPTheme current];
        // web `filter:brightness(1.08)` = 对 sRGB 每个分量 ×1.08 并夹到 1（**不是混白**）。
        // 旧实现混 10% 白会把高饱和 --acc 去饱和（#fa2d48 → 250,66,90），
        // 与浏览器逐像素结果（255,49,78）不一致；这里按通道相乘，才是真·亮度混合。
        NSColor *bg = t2.accent;
        if (hovered) {
            NSColor *srgb = [bg colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: bg;
            CGFloat r=0,g=0,b=0,a=0; [srgb getRed:&r green:&g blue:&b alpha:&a];
            bg = [NSColor colorWithSRGBRed:MIN((CGFloat)1.0, r*1.08)
                                     green:MIN((CGFloat)1.0, g*1.08)
                                      blue:MIN((CGFloat)1.0, b*1.08) alpha:a];
        }
        btn.layer.backgroundColor = bg.CGColor;
        btn.contentTintColor = NSColor.whiteColor;
    };

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
    self.volume.toolTip = RLPTr(@"音量");   // 旧控制条遗留；真播放页走 webControls
    // web `.npvol .vlab{font-size:11px;min-width:58px;text-align:right}`
    self.volLabel = RLPLabel(@"0.0 dB",
        [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular], t.mut);
    self.volLabel.identifier = @"np.vollab";
    self.volLabel.alignment = NSTextAlignmentRight;

    // v3.3.11 `npVolInput` / `commitPreciseVolume`：精确 dB 输入（Enter 确认）。
    // tooltip 复用既有词条「音量（dB）」，不新增 i18n 键。
    self.volDbField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.volDbField.identifier = @"npVolInput";
    self.volDbField.placeholderString = @"0.0";
    self.volDbField.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.volDbField.alignment = NSTextAlignmentRight;
    self.volDbField.toolTip = RLPTr(@"音量（dB）");
    self.volDbField.target = self;
    self.volDbField.action = @selector(onCommitPreciseVolume:);
    self.volDbField.wantsLayer = YES;

    // v3.3.11 `npVolFloor` / `toggleVolumeMute`：静音（-120 dB）与恢复先前音量。
    self.volMuteBtn = [[NSButton alloc] initWithFrame:NSZeroRect];
    self.volMuteBtn.identifier = @"npVolFloor";
    self.volMuteBtn.bordered = NO;
    self.volMuteBtn.imagePosition = NSImageOnly;
    self.volMuteBtn.image = [NSImage imageWithSystemSymbolName:@"speaker.slash.fill"
                                     accessibilityDescription:RLPTr(@"静音")];
    self.volMuteBtn.toolTip = RLPTr(@"静音");
    self.volMuteBtn.target = self;
    self.volMuteBtn.action = @selector(onToggleVolumeMute:);
    self.volumeRestoreDb = NAN;   // web 的 volumeRestore === null

    // v3.3.11 npVolKnob：音量旋钮。拖动中只更新界面（与原生既有滑块「松开才提交」同纪律），
    // 松开才下发 /api/volume。web 是每帧下发，差异如实挂账。
    self.volKnob = [[RLPVolumeKnobView alloc] initWithFrame:NSZeroRect];
    self.volKnob.identifier = @"npVolKnob";
    self.volKnob.toolTip = RLPTr(@"音量");
    __weak __typeof__(self) kws = self;
    self.volKnob.onLiveChange = ^(double db) { [kws updateVolumeUiForDb:db]; };
    self.volKnob.onCommit = ^(double db) { [kws applyVolumeDb:db]; };

    for (NSView *v in @[self.seek, self.posLabel, self.sepLabel, self.durLabel, self.repBtn,
                        self.prevBtn, self.playBtn, self.nextBtn, self.stopBtn,
                        self.volIcon, self.volume, self.volLabel, self.volDbField,
                        self.volKnob, self.volMuteBtn, self.repBadge]) {
        [self addSubview:v];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onVolumeDidChangeNotification:)
                                                 name:@"RLPVolumeDidChangeNotification"
                                               object:nil];
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
    // web `.nptime .tval{min-width:42px;text-align:center}` + `.tsep{margin:0 1px;min-width:10px}`
    const CGFloat timeW = 42.0, sepW = 10.0;
    CGFloat x = pad;
    self.posLabel.frame = NSMakeRect(x, rowCY - 8, timeW, 16); x += timeW + 1;
    self.sepLabel.frame = NSMakeRect(x, rowCY - 8, sepW, 16); x += sepW + 1;
    self.durLabel.frame = NSMakeRect(x, rowCY - 8, timeW, 16);

    const CGFloat repW = 32.0, keyS = 32.0, playS = 34.0, keyGap = 14.0;
    const CGFloat keysW = repW + keyGap + keyS + keyGap + playS + keyGap + keyS + keyGap + keyS;
    CGFloat kx = (W - keysW) / 2.0;
    const CGFloat repX = kx;
    self.repBtn.frame = NSMakeRect(kx, rowCY - 12, repW, 24); kx += repW + keyGap;
    self.prevBtn.frame = NSMakeRect(kx, rowCY - keyS / 2.0, keyS, keyS); kx += keyS + keyGap;
    self.playBtn.frame = NSMakeRect(kx, rowCY - playS / 2.0, playS, playS); kx += playS + keyGap;
    self.nextBtn.frame = NSMakeRect(kx, rowCY - keyS / 2.0, keyS, keyS); kx += keyS + keyGap;
    self.stopBtn.frame = NSMakeRect(kx, rowCY - keyS / 2.0, keyS, keyS);
    // web #npRepOne：margin-left 22 / margin-top -18 ⟹ 按钮右上角的 10px「1」。
    self.repBadge.frame = NSMakeRect(repX + 18, rowCY + 1, 13, 13);

    // web `.npvol{display:flex;gap:8px}` + `input[type=range]{width:104px}` + `.vlab{min-width:58px}`
    const CGFloat volLabW = 58.0, iconW = 14.0, volGap = 8.0;
    CGFloat sliderW = 104.0;
    const CGFloat minIconX = kx + 12.0;                 // 绝不压住中键区
    const CGFloat labelX = W - pad - volLabW;
    CGFloat sliderX = labelX - volGap - sliderW;
    CGFloat iconX = sliderX - volGap - iconW;
    if (iconX < minIconX) {
        sliderW = MAX(56.0, sliderW - (minIconX - iconX));
        sliderX = labelX - volGap - sliderW;
        iconX = sliderX - volGap - iconW;
    }
    // v3.3.11 `npVolInput`：精确 dB 输入放在音量图标左侧；宽窗口保持 web 的 104pt 滑块，
    // 窄窗口才按剩余空间收缩滑块（与上面 minIconX 同一套守卫）。
    // v3.3.11 npVolKnob：旋钮取代可见滑块（web 的 npVol range 是 sr-only）。
    // 尺寸受控制栏行高限制（web 64px，原生行高 ~40pt ⟹ 取 40pt 并在证据里挂账差异）。
    const CGFloat knobS = MAX(28.0, MIN(40.0, H - 22.0));
    const CGFloat preciseW = 48.0, muteW = 22.0;
    CGFloat preciseX = iconX - volGap - preciseW;
    CGFloat muteX = preciseX - volGap - muteW;
    // 新排布（左→右）：图标 · 旋钮 · 精确 dB 输入 · 读数；静音键居中叠在旋钮圆盖上。
    CGFloat knobX = preciseX - volGap - knobS;
    iconX = knobX - volGap - iconW;
    if (iconX < minIconX) {
        knobX = minIconX + volGap + iconW;
        iconX = minIconX;
    }
    muteX = knobX + (knobS - muteW) / 2.0;
    self.volIcon.frame = NSMakeRect(iconX, rowCY - 7, iconW, 14);
    self.volume.frame = NSMakeRect(sliderX, rowCY - 9, sliderW, 18);   // 仅作状态载体，不再可见
    self.volume.hidden = YES;
    self.volKnob.frame = NSMakeRect(knobX, rowCY - knobS / 2.0, knobS, knobS);
    self.volLabel.frame = NSMakeRect(labelX, rowCY - 8, volLabW, 16);
    self.volDbField.frame = NSMakeRect(preciseX, rowCY - 8, preciseW, 16);
    self.volMuteBtn.frame = NSMakeRect(muteX, rowCY - muteW / 2.0, muteW, muteW);
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
    self.volDbField.textColor = t.text;
    self.volMuteBtn.contentTintColor = t.mut;
    self.volKnob.needsDisplay = YES;
    self.repBadge.textColor = t.accentText;
}

@end

#pragma mark - 音频分析卡片（web .anlcard：标题左上 / 摘要 / 展开后 2 列指标网格）

// web 的真实几何（src/net/ui_page.h:930-950），逐条照抄：
//   .anlcard   padding:7px 9px 8px；gap:4px；radius:10；border:1px
//   .anlct     10.5px / 700 / letter-spacing:.8
//   .anlcs     11.5px / line-height:1.45
//   .anlbadge  9.5px / radius 5 / padding 1px 5px
//   .anlgrid   2 列 / gap:1px 10px
//   .anllb     10px；.anlv 11px / tabular / 右对齐；.anlv.na 灰字 10.5px 可换行；
//              .anlv.warn 琥珀 600
//   .anlsec    10px / 700 / letter-spacing:.7 / border-top:1px
//   .anlwarn   10.5px / rgba(234,179,8,.10) 底 + rgba(234,179,8,.24) 边 / radius 7
//
// 为什么不用 NSButton 自绘：AppKit 多行标题画在卡片左下角、且固定高度把长摘要截断
// （旧实现就是 11pt 单行 + 100/74 固定高）。子视图化后才能量真实几何、才能按文本生长。
static const CGFloat kAnlCardPadTop    = 7.0;
static const CGFloat kAnlCardPadX      = 9.0;
static const CGFloat kAnlCardPadBottom = 8.0;
static const CGFloat kAnlCardGap       = 4.0;
static const CGFloat kAnlCardRadius    = 10.0;
static const CGFloat kAnlTitleH        = 13.0;
static const CGFloat kAnlBadgeH        = 15.0;
static const CGFloat kAnlSumLineH      = 11.5 * 1.45;   // web line-height:1.45
static const CGFloat kAnlRowH          = 16.0;
static const CGFloat kAnlColGap        = 10.0;
static const CGFloat kAnlSecH          = 17.0;

/// 卡片区容器：web #npAnlBody。**不翻转**（底部为原点）——这样卡片自下而上排，
/// 既保持「动态/音质/假无损」从上到下的视觉顺序，也让离屏判据能按 NSMaxY 验证堆叠。
/// 卡片高度超过可见高度时用滚轮滚动（内容被 masksToBounds 裁在面板内的卡片区）。
@interface RLPNPAnalBody : NSView
@property (nonatomic, copy, nullable) void (^onScroll)(CGFloat deltaY);
/// 内容总高 / 当前滚动偏移：拇指位置由这两个值算出（与 web `#npAnlBody` 的滚动状态同源）。
@property (nonatomic, assign) CGFloat contentHeight;
@property (nonatomic, assign) CGFloat scrollOffset;
/// 6px 拇指的矩形（**自绘**，不新增 NSScrollView）；不溢出时返回 NSZeroRect。
- (NSRect)scrollThumbRect;
@end
@implementation RLPNPAnalBody
- (BOOL)isFlipped { return NO; }
- (void)scrollWheel:(NSEvent *)event {
    if (self.onScroll) { self.onScroll(event.scrollingDeltaY); return; }
    [super scrollWheel:event];
}
- (NSRect)scrollThumbRect {
    const CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    if (W < 20 || H < 10 || self.contentHeight <= H + 1.0) return NSZeroRect;
    const CGFloat thumbH = MAX(18.0, H * (H / self.contentHeight));
    const CGFloat maxOff = MAX(1.0, self.contentHeight - H);
    const CGFloat t = MAX(0.0, MIN(1.0, self.scrollOffset / maxOff)) * MAX(0.0, H - thumbH);
    // web：滚动条画在**右侧沟槽**里、永远不压卡片圆角（卡片右缘到沟槽还有 13pt 留白）。
    return NSMakeRect(W - 8.0, H - thumbH - t, 6.0, thumbH);
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect r = [self scrollThumbRect];
    if (NSIsEmptyRect(r) || r.size.height <= 0) return;
    [[RLPTheme current].line setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:3.0 yRadius:3.0] fill];
}
@end

@interface RLPAnlCardView : NSView {
    NSTextField *_titleLab;
    NSTextField *_badgeLab;
    NSTextField *_sumLab;
    NSMutableArray<NSDictionary *> *_built;
    NSMutableArray<NSValue *> *_hairlines;
}
@property (nonatomic, copy) NSString *cardKey;
@property (nonatomic, assign) NSInteger anlLevel;
@property (nonatomic, copy) NSArray<NSDictionary *> *rows;
@property (nonatomic, copy) NSString *titleText;
@property (nonatomic, copy) NSString *summaryText;
@property (nonatomic, copy) NSString *badgeText;
@property (nonatomic, copy, nullable) void (^onTap)(void);
- (void)applyTitle:(NSString *)title summary:(NSString *)summary badge:(nullable NSString *)badge;
- (void)applyRows:(NSArray<NSDictionary *> *)rows level:(NSInteger)level;
- (CGFloat)preferredHeightForWidth:(CGFloat)width;
- (void)relayout;
- (void)applyTheme;
@end

@implementation RLPAnlCardView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    self.wantsLayer = YES;
    self.layer.cornerRadius = kAnlCardRadius;
    self.layer.borderWidth = 1;
    _built = [NSMutableArray array];
    _hairlines = [NSMutableArray array];

    _titleLab = [NSTextField labelWithString:@""];
    _titleLab.identifier = @"anl.title";
    _titleLab.maximumNumberOfLines = 1;
    _titleLab.usesSingleLineMode = YES;
    _titleLab.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_titleLab];

    _sumLab = [NSTextField labelWithString:@""];
    _sumLab.identifier = @"anl.sum";
    _sumLab.maximumNumberOfLines = 0;
    _sumLab.usesSingleLineMode = NO;
    _sumLab.lineBreakMode = NSLineBreakByWordWrapping;
    _sumLab.cell.wraps = YES;
    [self addSubview:_sumLab];

    _badgeLab = [NSTextField labelWithString:@""];
    _badgeLab.identifier = @"anl.badge";
    _badgeLab.font = [NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold];
    _badgeLab.alignment = NSTextAlignmentCenter;
    _badgeLab.maximumNumberOfLines = 1;
    _badgeLab.wantsLayer = YES;
    _badgeLab.layer.cornerRadius = 5;
    _badgeLab.layer.borderWidth = 1;
    _badgeLab.hidden = YES;
    [self addSubview:_badgeLab];
    [self applyTheme];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setCardKey:(NSString *)cardKey {
    _cardKey = [cardKey copy];
    _titleLab.identifier = [cardKey stringByAppendingString:@".title"];
    _sumLab.identifier = [cardKey stringByAppendingString:@".sum"];
    _badgeLab.identifier = [cardKey stringByAppendingString:@".badge"];
}

/// 同一份文本在不同主题下重新上色（字距/行距属于 web 的排版常量，不随主题变）。
- (NSAttributedString *)attrText:(NSString *)text font:(NSFont *)font color:(NSColor *)color
                            kern:(CGFloat)kern lineHeight:(CGFloat)lineHeight wrap:(BOOL)wrap {
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.lineBreakMode = wrap ? NSLineBreakByWordWrapping : NSLineBreakByTruncatingTail;
    if (lineHeight > 0) { ps.minimumLineHeight = lineHeight; ps.maximumLineHeight = lineHeight; }
    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    attrs[NSFontAttributeName] = font;
    attrs[NSForegroundColorAttributeName] = color;
    attrs[NSParagraphStyleAttributeName] = ps;
    if (kern > 0) attrs[NSKernAttributeName] = @(kern);
    return [[NSAttributedString alloc] initWithString:(text ?: @"") attributes:attrs];
}

- (void)refreshLabels {
    RLPTheme *t = [RLPTheme current];
    NSFont *tf = [NSFont systemFontOfSize:10.5 weight:NSFontWeightBold];
    _titleLab.font = tf;
    _titleLab.attributedStringValue = [self attrText:self.titleText font:tf color:t.mut2
                                                kern:0.8 lineHeight:0 wrap:NO];
    NSFont *sf = [NSFont systemFontOfSize:11.5];
    _sumLab.font = sf;
    _sumLab.attributedStringValue = [self attrText:self.summaryText font:sf color:t.text
                                              kern:0 lineHeight:kAnlSumLineH wrap:YES];
    _badgeLab.stringValue = self.badgeText ?: @"";
    _badgeLab.font = [NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold];
    _badgeLab.textColor = t.accentText;
    _badgeLab.layer.backgroundColor = t.accentWeak.CGColor;
    _badgeLab.layer.borderColor = t.accentWeak.CGColor;
    _badgeLab.hidden = !self.badgeText.length;
}

- (void)applyTitle:(NSString *)title summary:(NSString *)summary badge:(NSString *)badge {
    self.titleText = [title copy];
    self.summaryText = [summary copy];
    self.badgeText = [badge copy];
    [self refreshLabels];
    [self relayout];
}

- (void)applyRows:(NSArray<NSDictionary *> *)rows level:(NSInteger)level {
    self.rows = rows ?: @[];
    self.anlLevel = level;
    [self rebuildRows];
    [self relayout];
}

- (NSTextField *)makeLabel:(NSString *)ident font:(NSFont *)font color:(NSColor *)color
                      wrap:(BOOL)wrap {
    NSTextField *l = [NSTextField labelWithString:@""];
    l.identifier = ident;
    l.font = font;
    l.textColor = color;
    l.maximumNumberOfLines = wrap ? 0 : 1;
    l.usesSingleLineMode = !wrap;
    l.lineBreakMode = wrap ? NSLineBreakByWordWrapping : NSLineBreakByTruncatingTail;
    if (wrap) l.cell.wraps = YES;
    [self addSubview:l];
    return l;
}

/// 行视图重建：sec/row/warn/note 都是真实子视图（判据量的是它们，不是 drawRect 里的常量）。
- (void)rebuildRows {

    const NSUInteger subBefore = self.subviews.count;
    for (NSDictionary *r in _built) {
        for (NSString *k in @[@"lab", @"lb", @"v", @"rule", @"box", @"main", @"hint"])
            if ([r[k] isKindOfClass:[NSView class]]) [(NSView *)r[k] removeFromSuperview];
    }
    (void)subBefore;
    [_built removeAllObjects];
    [_hairlines removeAllObjects];
    RLPTheme *t = [RLPTheme current];
    NSColor *amberBg = [NSColor colorWithSRGBRed:234/255. green:179/255. blue:8/255. alpha:0.10];
    NSColor *amberLine = [NSColor colorWithSRGBRed:234/255. green:179/255. blue:8/255. alpha:0.24];

    for (NSDictionary *r in self.rows) {
        NSString *kind = [r[@"k"] isKindOfClass:[NSString class]] ? r[@"k"] : @"row";
        if ([kind isEqualToString:@"sec"]) {
            NSView *rule = [[NSView alloc] initWithFrame:NSZeroRect];
            rule.identifier = @"anl.sec.rule";
            rule.wantsLayer = YES;
            rule.layer.backgroundColor = t.line.CGColor;
            [self addSubview:rule];
            NSTextField *lab = [self makeLabel:@"anl.sec"
                                          font:[NSFont systemFontOfSize:10 weight:NSFontWeightBold]
                                         color:t.accentText wrap:NO];
            NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
            ps.lineBreakMode = NSLineBreakByTruncatingTail;
            lab.attributedStringValue = [[NSAttributedString alloc]
                initWithString:(r[@"t"] ?: @"")
                attributes:@{ NSFontAttributeName: lab.font, NSForegroundColorAttributeName: t.accentText,
                              NSKernAttributeName: @0.7, NSParagraphStyleAttributeName: ps }];
            [_built addObject:@{ @"k": @"sec", @"lab": lab, @"rule": rule }];
        } else if ([kind isEqualToString:@"row"]) {
            const BOOL na = [r[@"na"] boolValue];
            const BOOL hot = [r[@"warn"] boolValue];
            NSTextField *lb = [self makeLabel:@"anl.lb"
                                         font:[NSFont systemFontOfSize:10]
                                        color:t.mut2 wrap:NO];
            lb.stringValue = r[@"l"] ?: @"";
            NSFont *vf = na ? [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightRegular]
                            : [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
            NSTextField *val = [self makeLabel:@"anl.v" font:vf
                                        color:(hot ? t.warn : (na ? t.mut2 : t.text)) wrap:na];
            val.stringValue = r[@"v"] ?: @"NA";
            val.alignment = NSTextAlignmentRight;
            BOOL wide = [r[@"wide"] isKindOfClass:[NSNumber class]] ? [r[@"wide"] boolValue]
                                                                   : (na && [(r[@"v"] ?: @"") length] > 8);
            [_built addObject:@{ @"k": @"row", @"lb": lb, @"v": val,
                                 @"na": @(na), @"warn": @(hot), @"wide": @(wide) }];
        } else if ([kind isEqualToString:@"warn"]) {
            NSView *box = [[NSView alloc] initWithFrame:NSZeroRect];
            box.identifier = [NSString stringWithFormat:@"%@.warn", self.cardKey ?: @"anl.dyn"];
            box.wantsLayer = YES;
            box.layer.cornerRadius = 7;
            box.layer.borderWidth = 1;
            box.layer.backgroundColor = amberBg.CGColor;
            box.layer.borderColor = amberLine.CGColor;
            [self addSubview:box];
            NSTextField *main = [self makeLabel:@"anl.warn.txt"
                                          font:[NSFont systemFontOfSize:10.5]
                                         color:t.warn wrap:YES];
            main.stringValue = r[@"t"] ?: @"";
            NSTextField *hint = [self makeLabel:@"anl.warn.hint"
                                           font:[NSFont systemFontOfSize:9.5]
                                          color:t.mut2 wrap:YES];
            hint.stringValue = r[@"h"] ?: @"";
            [main removeFromSuperview];
            [hint removeFromSuperview];
            [box addSubview:main];
            [box addSubview:hint];
            [_built addObject:@{ @"k": @"warn", @"box": box, @"main": main, @"hint": hint }];
        } else {
            NSTextField *note = [self makeLabel:@"anl.note"
                                           font:[NSFont systemFontOfSize:10]
                                          color:t.mut2 wrap:YES];
            note.stringValue = r[@"t"] ?: @"";
            [_built addObject:@{ @"k": @"note", @"lab": note }];
        }
    }
    [self applyTheme];
}

- (CGFloat)measuredHeight:(NSTextField *)label lineHeight:(CGFloat)lh width:(CGFloat)width {
    NSString *s = label.stringValue;
    // NSTextField 的文字区比 frame 窄左右各 2pt：不扣掉这 4pt，边界行会被裁掉一行。
    width = MAX(10, width - 4.0);
    if (!s.length || width < 10) return 0;
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.lineBreakMode = NSLineBreakByWordWrapping;
    ps.minimumLineHeight = lh;
    ps.maximumLineHeight = lh;
    NSRect r = [s boundingRectWithSize:NSMakeSize(width, CGFLOAT_MAX)
                               options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                            attributes:@{ NSFontAttributeName: label.font, NSParagraphStyleAttributeName: ps }];
    return MAX(lh, ceil(r.size.height));
}

- (CGFloat)titleWidth {
    // 标题带 letter-spacing .8：徽标位置必须按「含字距」的宽度算，否则徽标压住标题末尾。
    NSString *t = self.titleText ?: @"";
    if (!t.length) return 0;
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    return ceil([t sizeWithAttributes:@{ NSFontAttributeName: _titleLab.font,
                                         NSKernAttributeName: @0.8,
                                         NSParagraphStyleAttributeName: ps }].width);
}

- (CGFloat)headerHeight {
    return self.badgeText.length ? kAnlBadgeH : kAnlTitleH;
}

/// 行区排版（翻转坐标，从 y0 往下排）。apply=NO 时只量高度，不写 frame。
- (CGFloat)layoutBodyAtY:(CGFloat)y0 width:(CGFloat)contentW apply:(BOOL)apply {
    if (contentW < 20) return 0;
    const CGFloat x0 = kAnlCardPadX;
    const CGFloat cellW = (contentW - kAnlColGap) / 2.0;
    CGFloat y = y0;
    NSUInteger col = 0;
    if (apply) [_hairlines removeAllObjects];
    for (NSDictionary *r in _built) {
        NSString *kind = r[@"k"];
        if ([kind isEqualToString:@"sec"]) {
            if (col) { col = 0; y += kAnlRowH; }
            if (apply) {
                ((NSView *)r[@"rule"]).frame = NSMakeRect(x0, y, contentW, 1);
                ((NSTextField *)r[@"lab"]).frame = NSMakeRect(x0, y + 4, contentW, 12);
            }
            y += kAnlSecH;
        } else if ([kind isEqualToString:@"row"]) {
            NSTextField *lb = r[@"lb"], *val = r[@"v"];
            if ([r[@"wide"] boolValue]) {
                if (col) { col = 0; y += kAnlRowH; }
                const CGFloat labW = MIN(ceil([lb.stringValue sizeWithAttributes:
                                              @{ NSFontAttributeName: lb.font }].width), contentW * 0.55);
                const CGFloat valW = MAX(20, contentW - labW - 8);
                const CGFloat valH = [self measuredHeight:val lineHeight:val.font.pointSize * 1.35 width:valW];
                const CGFloat h = MAX(kAnlRowH, valH + 2);
                if (apply) {
                    lb.frame = NSMakeRect(x0, y, labW, h);
                    val.frame = NSMakeRect(x0 + labW + 8, y, valW, MAX(valH, h));
                    [_hairlines addObject:[NSValue valueWithRect:
                                           NSMakeRect(x0, y + h - 1, contentW, 1)]];
                }
                y += h;
            } else {
                const CGFloat x = x0 + (col ? (cellW + kAnlColGap) : 0);
                if (apply) {
                    lb.frame = NSMakeRect(x, y, cellW, kAnlRowH);
                    val.frame = NSMakeRect(x, y, cellW, kAnlRowH);
                    [_hairlines addObject:[NSValue valueWithRect:
                                           NSMakeRect(x, y + kAnlRowH - 1, cellW, 1)]];
                }
                if (col == 1) { col = 0; y += kAnlRowH; } else { col = 1; }
            }
        } else if ([kind isEqualToString:@"warn"]) {
            if (col) { col = 0; y += kAnlRowH; }
            NSTextField *main = r[@"main"], *hint = r[@"hint"];
            const CGFloat innerW = contentW - 14;
            const CGFloat mainH = [self measuredHeight:main lineHeight:10.5 * 1.5 width:innerW];
            const CGFloat hintH = hint.stringValue.length
                ? [self measuredHeight:hint lineHeight:9.5 * 1.45 width:innerW] : 0;
            const CGFloat boxH = 3 + mainH + (hintH ? 2 + hintH : 0) + 3;
            if (apply) {
                ((NSView *)r[@"box"]).frame = NSMakeRect(x0, y, contentW, boxH);
                main.frame = NSMakeRect(7, 3, innerW, mainH);
                if (hintH) hint.frame = NSMakeRect(7, 3 + mainH + 2, innerW, hintH);
            }
            y += boxH + 1;      // web .anlgrid 行间距 1px
        } else {
            if (col) { col = 0; y += kAnlRowH; }
            NSTextField *note = r[@"lab"];
            const CGFloat h = [self measuredHeight:note lineHeight:10 * 1.45 width:contentW];
            if (apply) note.frame = NSMakeRect(x0, y, contentW, h);
            y += h + 1;
        }
    }
    if (col) y += kAnlRowH;
    return y - y0;
}

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    const CGFloat contentW = MAX(10, width - kAnlCardPadX * 2);
    const CGFloat sumH = [self measuredHeight:_sumLab lineHeight:kAnlSumLineH width:contentW];
    const CGFloat bodyH = self.rows.count ? [self layoutBodyAtY:0 width:contentW apply:NO] : 0;
    CGFloat h = kAnlCardPadTop + [self headerHeight] + kAnlCardGap + sumH;
    if (self.rows.count) h += kAnlCardGap + bodyH;
    return h + kAnlCardPadBottom;
}

- (void)relayout {
    const CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    if (W < 20 || H < 20) return;
    const CGFloat contentW = MAX(10, W - kAnlCardPadX * 2);
    _titleLab.frame = NSMakeRect(kAnlCardPadX, kAnlCardPadTop, contentW, kAnlTitleH);
    if (self.badgeText.length) {
        const CGFloat badgeW = ceil([self.badgeText sizeWithAttributes:
                                    @{ NSFontAttributeName: _badgeLab.font }].width) + 10;
        _badgeLab.frame = NSMakeRect(kAnlCardPadX + [self titleWidth] + 6, kAnlCardPadTop,
                                     MIN(MAX(18, badgeW), contentW * 0.7), kAnlBadgeH);
    }
    const CGFloat sumY = kAnlCardPadTop + [self headerHeight] + kAnlCardGap;
    const CGFloat sumH = [self measuredHeight:_sumLab lineHeight:kAnlSumLineH width:contentW];
    _sumLab.frame = NSMakeRect(kAnlCardPadX, sumY, contentW, sumH);
    const CGFloat bodyY = sumY + sumH + (self.rows.count ? kAnlCardGap : 0);
    [self layoutBodyAtY:bodyY width:contentW apply:YES];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if (!_hairlines.count) return;
    [[RLPTheme current].line setFill];
    for (NSValue *v in _hairlines) NSRectFill([v rectValue]);
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.layer.backgroundColor = t.bg2.CGColor;
    self.layer.borderColor = t.line.CGColor;
    [self refreshLabels];
    for (NSDictionary *r in _built) {
        NSString *kind = r[@"k"];
        if ([kind isEqualToString:@"sec"]) {
            ((NSTextField *)r[@"lab"]).textColor = t.accentText;
            ((NSView *)r[@"rule"]).layer.backgroundColor = t.line.CGColor;
        } else if ([kind isEqualToString:@"row"]) {
            ((NSTextField *)r[@"lb"]).textColor = t.mut2;
            NSTextField *v = r[@"v"];
            v.textColor = [r[@"warn"] boolValue] ? t.warn : ([r[@"na"] boolValue] ? t.mut2 : t.text);
        } else if ([kind isEqualToString:@"warn"]) {
            ((NSTextField *)r[@"main"]).textColor = t.warn;
            ((NSTextField *)r[@"hint"]).textColor = t.mut2;
        } else if ([kind isEqualToString:@"note"]) {
            ((NSTextField *)r[@"lab"]).textColor = t.mut2;
        }
    }
    self.needsDisplay = YES;
}

/// 文字子视图覆盖卡片：hitTest 不劫持的话点击落到 NSTextField 上，卡片收不到 mouseDown。
- (NSView *)hitTest:(NSPoint)point {
    NSPoint p = [self convertPoint:point fromView:self.superview];
    return NSPointInRect(p, self.bounds) ? self : nil;
}
- (void)mouseDown:(NSEvent *)event {
    (void)event;
    if (self.onTap) self.onTap();
}
@end

#pragma mark - 「AI 整理」栏卡片（第5项：几何与排版对齐 web .npchip）

// web 的真实几何（src/net/ui_page.h:742-763），逐条照抄：
//   .nprailcard padding:10px, gap:8px   → 栏内左右 10、栏头→首卡 8
//   .npchipwrap  gap:6px                → 卡片之间 6
//   .npchip      padding:8px 10px 9px, border-radius:11px, gap:2px
//   .npchip-top  gap:7px / .dot 5px     → 圆点 5、点与名称间距 7
//   name 11.5/700、.npchip-st 9.5、p1 11.5、p2 10.5、line-height:1.45
// ★ 11 = web 的 padding:10 **+ border:1**（CSS 是 box-sizing:border-box ⟹ 内容从边框内缘起算）。
//   原生面板的 layer.borderWidth=1 是**向内**描边（见 applyTheme），所以内容也必须从 11 起算，
//   否则卡片会压在边框上、且右端与 web 差 1pt（偏差台账里那条 rail 1pt 差就是这么来的）。
static const CGFloat kRailHeadPadTop = 11.0;
static const CGFloat kRailHeadPadX   = 11.0;
static const CGFloat kRailHeadGap    = 8.0;
static const CGFloat kRailChipGap    = 6.0;
static const CGFloat kRailChipPadTop = 8.0;
static const CGFloat kRailChipPadX   = 10.0;
static const CGFloat kRailChipPadBottom = 9.0;
static const CGFloat kRailChipRadius = 11.0;
static const CGFloat kRailRowGap     = 2.0;
static const CGFloat kRailDotSize    = 5.0;
static const CGFloat kRailDotGap     = 7.0;
static const CGFloat kRailRow1H      = 17.0;   // 11.5 × 1.45 ≈ 16.7
static const CGFloat kRailP1H        = 17.0;
static const CGFloat kRailP2H        = 15.0;   // 10.5 × 1.45 ≈ 15.2

/// 为什么不用 NSButton（旧实现就是 NSButton + 多行 attributedTitle）：
/// AppKit 把 NSButton 的多行标题画在**卡片左下角**，卡片上半部全空 ——
/// 左栏音频分析卡（d717ef0）踩过同一个坑。web 的 chip 是「标题在左上、
/// 正文在下、四周内边距 8/10/9」的结构，只能自己排子视图。
/// 子视图化还有一个好处：判据能**量真实几何**（inset / 行距 / 字号），
/// 而不是对着 drawRect 里的常量自证。
@interface RLPRailChipView : NSView {
    NSView *_dot;
    NSTextField *_nameLabel;
    NSTextField *_statusLabel;
    NSTextField *_p1Label;
    NSTextField *_p2Label;
}
@property (nonatomic, assign) NSInteger chipIndex;
/// 详细档：p1 最多 5 行、p2 最多 2 行（web `.npchipwrap[data-detail=1]` 的 line-clamp），
/// 简介不再按 40 字截断；高度由文本实测撑开。默认（简略）保持既有的单行几何。
@property (nonatomic, assign) BOOL detailMode;
@property (nonatomic, copy, nullable) void (^onTap)(RLPRailChipView *chip);
/// web `.npchip:hover`：底 rgba(255,255,255,.09)/浅色 rgba(15,23,42,.06)、
/// 边 rgba(255,255,255,.14)/浅色 rgba(15,23,42,.14)。
@property (nonatomic, assign, readonly) BOOL hovered;
- (void)setHovered:(BOOL)hovered;
- (void)setNameText:(NSString *)name status:(NSString *)status
                  p1:(NSString *)p1 p2:(NSString *)p2;
- (CGFloat)preferredHeight;
/// 详细档要按真实卡宽量文本；layout 里先知道宽度再定卡片高度。
- (CGFloat)preferredHeightForWidth:(CGFloat)width;
- (void)applyTheme;
@end

@implementation RLPRailChipView
@synthesize hovered = _hovered;

- (NSTextField *)labelWithFont:(NSFont *)font color:(NSColor *)color ident:(NSString *)ident {
    NSTextField *l = [NSTextField labelWithString:@""];
    l.font = font;
    l.textColor = color;
    l.identifier = ident;
    l.alignment = NSTextAlignmentLeft;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    l.usesSingleLineMode = YES;
    l.maximumNumberOfLines = 1;
    l.translatesAutoresizingMaskIntoConstraints = YES;
    [self addSubview:l];
    return l;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    RLPTheme *t = [RLPTheme current];
    self.wantsLayer = YES;
    self.layer.cornerRadius = kRailChipRadius;
    self.layer.borderWidth = 1;

    _dot = [[NSView alloc] initWithFrame:NSZeroRect];
    _dot.identifier = @"npChip.dot";
    _dot.wantsLayer = YES;
    _dot.layer.cornerRadius = kRailDotSize / 2.0;
    [self addSubview:_dot];

    _nameLabel = [self labelWithFont:[NSFont systemFontOfSize:11.5 weight:NSFontWeightBold]
                               color:t.text2 ident:@"npChip.name"];
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    _nameLabel.attributedStringValue = [[NSAttributedString alloc]
        initWithString:@"" attributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:11.5 weight:NSFontWeightBold],
                                         NSForegroundColorAttributeName: t.text2,
                                         NSKernAttributeName: @0.4,
                                         NSParagraphStyleAttributeName: ps }];
    _statusLabel = [self labelWithFont:[NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold]
                                 color:t.mut2 ident:@"npChip.st"];
    _statusLabel.alignment = NSTextAlignmentRight;
    _p1Label = [self labelWithFont:[NSFont systemFontOfSize:11.5] color:t.text2 ident:@"npChip.p1"];
    _p2Label = [self labelWithFont:[NSFont systemFontOfSize:10.5] color:t.mut2 ident:@"npChip.p2"];
    [self applyTheme];
    return self;
}

- (BOOL)isFlipped { return NO; }

- (void)setNameText:(NSString *)name status:(NSString *)status p1:(NSString *)p1 p2:(NSString *)p2 {
    _nameLabel.stringValue = name ?: @"";
    _statusLabel.stringValue = status ?: @"";
    _p1Label.stringValue = p1 ?: @"";
    _p2Label.stringValue = p2 ?: @"";
    // 空 p2 = web 不渲染 `<span class=npchip-p2>`，卡片高度也不留那 15px 空行。
    // 从视图树里摘掉而不是只 hidden：离屏几何判据按 identifier 找子视图，
    // hidden 的 p2 会让它继续按「有第二行」量（旧的单行卡就靠这一点区分）。
    if (_p2Label.stringValue.length) {
        if (_p2Label.superview != self) [self addSubview:_p2Label];
        _p2Label.hidden = NO;
    } else {
        if (_p2Label.superview == self) [_p2Label removeFromSuperview];
        _p2Label.hidden = YES;
    }
    [self relayout];
}

/// 详细档的行高：web `line-height:1.35`。简略档仍用既有常量 17/15（11.5×1.45 / 10.5×1.45）。
static const CGFloat kRailDetailLineHeight = 1.35;

- (CGFloat)measuredTextHeight:(NSTextField *)label cap:(NSInteger)cap width:(CGFloat)width {
    NSString *s = label.stringValue;
    if (!s.length || width < 10) return 0;
    const CGFloat lh = label.font.pointSize * kRailDetailLineHeight;
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.lineBreakMode = NSLineBreakByWordWrapping;
    ps.minimumLineHeight = lh;
    ps.maximumLineHeight = lh;
    NSDictionary *attrs = @{ NSFontAttributeName: label.font, NSParagraphStyleAttributeName: ps };
    NSRect r = [s boundingRectWithSize:NSMakeSize(width, CGFLOAT_MAX)
                               options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                            attributes:attrs];
    const CGFloat h = ceil(r.size.height);
    return MAX(lh, MIN(h, lh * (CGFloat)cap));
}

- (CGFloat)preferredHeight { return [self preferredHeightForWidth:self.bounds.size.width]; }

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    const CGFloat contentW = MAX(10, width - kRailChipPadX * 2);
    CGFloat p1H = kRailP1H, p2H = kRailP2H;
    if (_detailMode) {
        p1H = [self measuredTextHeight:_p1Label cap:5 width:contentW];
        p2H = [self measuredTextHeight:_p2Label cap:2 width:contentW];
    }
    CGFloat h = kRailChipPadTop + kRailRow1H + kRailRowGap + p1H;
    if (_p2Label.stringValue.length) h += kRailRowGap + p2H;
    return h + kRailChipPadBottom;
}

/// 非翻转坐标（origin 在左下）：所有 y 都由「卡片高度 - 从顶部算的 offset」求出，
/// 这样卡片高度变化时 inset 永远还是 8/10/9。
/// 详细档把 p1/p2 的行高换成实测值（同一处量、同一处排，避免两档各写一份公式漂移）。
- (void)relayout {
    const CGFloat H = self.bounds.size.height, W = self.bounds.size.width;
    if (W < 20 || H < 20) return;
    const CGFloat contentW = MAX(10, W - kRailChipPadX * 2);
    CGFloat p1H = kRailP1H, p2H = kRailP2H;
    if (_detailMode) {
        p1H = [self measuredTextHeight:_p1Label cap:5 width:contentW];
        p2H = [self measuredTextHeight:_p2Label cap:2 width:contentW];
    }
    const CGFloat row1Y = H - kRailChipPadTop - kRailRow1H;
    const CGFloat statusW = MIN(W * 0.5,
        ceil([_statusLabel.stringValue sizeWithAttributes:@{ NSFontAttributeName: _statusLabel.font }].width));
    const CGFloat statusX = W - kRailChipPadX - statusW;
    const CGFloat nameX = kRailChipPadX + kRailDotSize + kRailDotGap;
    _dot.frame = NSMakeRect(kRailChipPadX, row1Y + (kRailRow1H - kRailDotSize) / 2.0,
                            kRailDotSize, kRailDotSize);
    _nameLabel.frame = NSMakeRect(nameX, row1Y, MAX(10, statusX - 6 - nameX), kRailRow1H);
    _statusLabel.frame = NSMakeRect(statusX, row1Y, statusW, kRailRow1H);
    const CGFloat p1Y = row1Y - kRailRowGap - p1H;
    _p1Label.frame = NSMakeRect(kRailChipPadX, p1Y, contentW, p1H);
    if (_p2Label.superview == self) {
        const CGFloat p2Y = p1Y - kRailRowGap - p2H;
        _p2Label.frame = NSMakeRect(kRailChipPadX, p2Y, contentW, p2H);
    }
}

- (void)setDetailMode:(BOOL)detail {
    if (_detailMode == detail) {
        [self relayout];
        return;
    }
    _detailMode = detail;
    _p1Label.maximumNumberOfLines = detail ? 5 : 1;
    _p2Label.maximumNumberOfLines = detail ? 2 : 1;
    _p1Label.usesSingleLineMode = !detail;
    _p2Label.usesSingleLineMode = !detail;
    _p1Label.lineBreakMode = detail ? NSLineBreakByWordWrapping : NSLineBreakByTruncatingTail;
    _p2Label.lineBreakMode = detail ? NSLineBreakByWordWrapping : NSLineBreakByTruncatingTail;
    [self relayout];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self relayout];
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    // 对齐 web .npchip 的半透明底 + 细描边（浅色主题改深色低透明度，见 ui_page.h:766）。
    self.layer.backgroundColor = (t.isLight
        ? [NSColor colorWithSRGBRed:15/255. green:23/255. blue:42/255. alpha:.03]
        : [NSColor colorWithWhite:1 alpha:.03]).CGColor;
    self.layer.borderColor = (t.isLight
        ? [NSColor colorWithSRGBRed:15/255. green:23/255. blue:42/255. alpha:.08]
        : [NSColor colorWithWhite:1 alpha:.06]).CGColor;
    _dot.layer.backgroundColor = t.mut2.CGColor;
    _nameLabel.textColor = t.text2;
    _statusLabel.textColor = t.mut2;
    _p1Label.textColor = t.text2;
    _p2Label.textColor = t.mut2;
    [self relayout];
}

/// 名称/正文标签盖在卡片上：不做 hitTest 劫持的话，点击会落到 NSTextField 上，
/// 卡片自己的 mouseDown 收不到（或先冒泡到别处）。
- (NSView *)hitTest:(NSPoint)point {
    NSPoint p = [self convertPoint:point fromView:self.superview];
    return NSPointInRect(p, self.bounds) ? self : nil;
}
- (void)mouseDown:(NSEvent *)event {
    (void)event;
    if (self.onTap) self.onTap(self);
}
// web `.npchip:hover{background:rgba(255,255,255,.09);border-color:rgba(255,255,255,.14)}`
// （浅色主题 rgba(15,23,42,.06)/.14）；enter 改底/边，exit 回到 applyTheme 的静态值。
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *a in self.trackingAreas)
        if (a.owner == self) return;
    NSTrackingArea *hover = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect)
               owner:self userInfo:nil];
    [self addTrackingArea:hover];
}
- (void)mouseEntered:(NSEvent *)event { self.hovered = YES; }
- (void)mouseExited:(NSEvent *)event { self.hovered = NO; }
- (void)setHovered:(BOOL)hovered {
    if (self.hovered == hovered) return;
    _hovered = hovered;
    RLPTheme *t = [RLPTheme current];
    if (hovered) {
        self.layer.backgroundColor = (t.isLight
            ? [NSColor colorWithSRGBRed:15/255. green:23/255. blue:42/255. alpha:.06]
            : [NSColor colorWithWhite:1 alpha:.09]).CGColor;
        self.layer.borderColor = (t.isLight
            ? [NSColor colorWithSRGBRed:15/255. green:23/255. blue:42/255. alpha:.14]
            : [NSColor colorWithWhite:1 alpha:.14]).CGColor;
    } else {
        [self applyTheme];
    }
}

@end

#pragma mark - `.npdrawerbg` 遮罩（点遮罩关闭）

/// web `#npDrawerBg`：整页半透明遮罩（`background:rgba(0,0,0,.30)`），点它 = `npDrawerClose()`。
/// `backdrop-filter:blur(2px)` 的 AppKit 等价：只负责模糊窗口内内容；
/// 30% 黑遮罩仍由 RLPOverlayBackdrop 的 layer 背景承担。hitTest 返回 nil 让点击穿透。
@interface RLPBlurView : NSVisualEffectView
@end
@implementation RLPBlurView
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
@end

@interface RLPOverlayBackdrop : NSView
@property (nonatomic, copy, nullable) void (^onClick)(void);
@end
@implementation RLPOverlayBackdrop
- (instancetype)initWithFrame:(NSRect)frameRect {
    if ((self = [super initWithFrame:frameRect])) {
        RLPBlurView *blur = [[RLPBlurView alloc] initWithFrame:self.bounds];
        blur.identifier = @"npDrawerBlur";
        blur.material = NSVisualEffectMaterialHUDWindow;
        blur.blendingMode = NSVisualEffectBlendingModeWithinWindow;
        blur.state = NSVisualEffectStateActive;
        blur.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:blur];
    }
    return self;
}
- (void)mouseDown:(NSEvent *)event {
    (void)event;
    if (self.onClick) self.onClick();
}
@end

#pragma mark - `.npchipwrap` 自绘滚动容器（不新增 NSScrollView）

/// web `.npchipwrap{overflow:auto;scrollbar-width:thin}` 的原生等价：
/// 用普通 NSView + contentOffset + drawRect 拇指，**不引入第二个 NSScrollView**
/// （「单层滚动」判据要求可见 NSScrollView 数量不增加；嵌套滚动会让滚轮事件在两层之间打架）。
/// 惯性滚动的单帧衰减（纯函数，可离屏判据）：速度每帧 ×0.90，<8pt/s 收敛到 0 停止；
/// 返回本帧位移（pt），衰减后的速度写回 outVelocity。web `overflow:auto` 自带惯性，
/// 自绘容器不引入 NSScrollView，所以由这里补同语义的阻尼滚动。
static CGFloat RLPRailMomentumStep(CGFloat velocity, CGFloat *outVelocity) {
    CGFloat v = velocity * 0.90;
    if (fabs(v) < 8.0) v = 0.0;
    if (outVelocity) *outVelocity = v;
    return v / 60.0;   // 1/60s 帧
}

@interface RLPRailWrapView : NSView
@property (nonatomic, assign) CGFloat contentHeight;
@property (nonatomic, assign) CGFloat contentOffset;
@property (nonatomic, copy, nullable) void (^onScrollDelta)(CGFloat deltaY);
@property (nonatomic, copy, nullable) void (^onOffsetChanged)(CGFloat offset);
/// 惯性状态：判据可直接驱动 momentumTick:，不依赖真实 runloop/timer。
@property (nonatomic, assign) CGFloat momentumVelocity;
@property (nonatomic, strong, nullable) NSTimer *momentumTimer;
- (void)beginMomentumWithVelocity:(CGFloat)velocity;
- (void)momentumTick:(id)sender;
- (void)stopMomentum;
- (NSRect)scrollThumbRect;
@end
@implementation RLPRailWrapView
- (BOOL)isFlipped { return NO; }
- (void)scrollWheel:(NSEvent *)event {
    const CGFloat dy = event.scrollingDeltaY;
    // 触摸板/系统惯性阶段由 AppKit 继续发 wheel 事件：按普通位移处理，不叠加自绘惯性。
    if (event.momentumPhase != NSEventPhaseNone) {
        [self stopMomentum];
        if (self.onScrollDelta) self.onScrollDelta(dy);
        return;
    }
    [self stopMomentum];
    if (self.onScrollDelta) self.onScrollDelta(dy);
    // 离散滚轮 / 无系统惯性的手势：按本次 dy 估速度，补一段阻尼惯性。
    if (fabs(dy) > 0.5) [self beginMomentumWithVelocity:-dy * 12.0];
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) [self stopMomentum];   // 离屏即停，别让惯性继续跑
}
- (void)beginMomentumWithVelocity:(CGFloat)velocity {
    self.momentumVelocity = velocity;
    // 只有真在窗口里才挂 timer；离屏判据直接调 momentumTick: 驱动。
    if (self.window) {
        [self.momentumTimer invalidate];
        // 2026-11-17（并发审计）：target:self 的重复 timer 会**强持有** self ⟹ 离屏后
        // dealloc 被推迟、惯性还在跑。改成 block 版 + 弱引用，并在离开窗口时停表。
        __weak __typeof__(self) weakSelf = self;
        self.momentumTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/60.0 repeats:YES block:^(NSTimer *t) {
            __typeof__(self) self_ = weakSelf;
            if (!self_) { [t invalidate]; return; }
            [self_ momentumTick:t];
        }];
    }
}
- (void)momentumTick:(id)sender {
    (void)sender;
    CGFloat v = 0;
    const CGFloat delta = RLPRailMomentumStep(self.momentumVelocity, &v);
    self.momentumVelocity = v;
    if (fabs(delta) > 0.001) self.contentOffset = self.contentOffset + delta;
    if (v == 0.0) [self stopMomentum];
}
- (void)stopMomentum {
    [self.momentumTimer invalidate];
    self.momentumTimer = nil;
    self.momentumVelocity = 0.0;
}
- (void)dealloc {
    [_momentumTimer invalidate];
}
- (void)setContentOffset:(CGFloat)contentOffset {
    const CGFloat maxOff = MAX(0.0, self.contentHeight - self.bounds.size.height);
    const CGFloat clamped = MAX(0.0, MIN(maxOff, contentOffset));
    if (fabs(clamped - _contentOffset) < 0.01) return;
    _contentOffset = clamped;
    self.needsDisplay = YES;
    if (self.onOffsetChanged) self.onOffsetChanged(clamped);
}
- (NSRect)scrollThumbRect {
    const CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    if (W < 20 || H < 10 || self.contentHeight <= H + 1.0) return NSZeroRect;
    const CGFloat thumbH = MAX(18.0, H * (H / self.contentHeight));
    const CGFloat maxOff = MAX(1.0, self.contentHeight - H);
    const CGFloat t = MAX(0.0, MIN(1.0, self.contentOffset / maxOff)) * MAX(0.0, H - thumbH);
    // web 实测（ego/Chromium，2026-11-14）：`.npchipwrap` 内容溢出时滚动条占位 **11pt**
    // （CSS 写 `::-webkit-scrollbar{width:6px}`，实测 offsetWidth-clientWidth=11），
    // 首张 `.npchip` 宽 = wrapW-11；不溢出时占位 0、卡宽 = wrapW。原生沿用「常驻占位」
    // 取舍（与 #npAnlBody 同），6pt 拇指画在 11pt 占位内 x∈[W-8,W-2]，与卡片右缘留 3pt。
    return NSMakeRect(W - 8.0, H - thumbH - t, 6.0, thumbH);
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect r = [self scrollThumbRect];
    if (NSIsEmptyRect(r)) return;
    [[RLPTheme current].line setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:3.0 yRadius:3.0] fill];
}
@end

#pragma mark - web npRailPreview / npSummUrl 的同构投影（内容唯一真相源）

/// web efValueText：字符串原样、数字/布尔转字符串、数组按行拼接（简介段落有时是数组）。
static NSString *RLPRailValueText(id v) {
    if (!v || [v isKindOfClass:[NSNull class]]) return @"";
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
    if ([v isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id e in (NSArray *)v) {
            NSString *s = RLPRailValueText(e);
            if (s.length) [out addObject:s];
        }
        return [out componentsJoinedByString:@"\n"];
    }
    if ([v isKindOfClass:[NSDictionary class]]) {
        // 字段值正常只有字符串/数组；对象极少见，退回 description（与 web JSON.stringify 同为兜底）。
        return [v description] ?: @"";
    }
    return [v description] ?: @"";
}

/// web `npRailShort(v,n).replace(/\s+/g,' ').trim()`：折叠空白。
static NSString *RLPRailCollapse(id value) {
    NSString *s = RLPRailValueText(value);
    if (!s.length) return @"";
    NSArray *parts = [s componentsSeparatedByCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray *keep = [NSMutableArray array];
    for (NSString *p in parts) if (p.length) [keep addObject:p];
    return [keep componentsJoinedByString:@" "];
}

/// web npRailShort：截到 n 字（先切 n-1，再剥末尾标点/空白，补 …）。
static NSString *RLPRailShort(id value, NSInteger n) {
    NSString *s = RLPRailCollapse(value);
    if (!s.length) return @"";
    if (n > 0 && (NSInteger)s.length > n) {
        NSString *head = [s substringToIndex:(NSUInteger)(n - 1)];
        NSMutableCharacterSet *trim = [[NSCharacterSet whitespaceAndNewlineCharacterSet] mutableCopy];
        [trim addCharactersInString:@"，,、;；。"];
        NSInteger end = (NSInteger)head.length;
        while (end > 0 && [trim characterIsMember:[head characterAtIndex:(NSUInteger)(end - 1)]]) --end;
        s = [[head substringToIndex:(NSUInteger)end] stringByAppendingString:@"…"];
    }
    return s;
}

/// web npRailPick：按 key 顺序拼「标签 值」，` · ` 分隔，最多 limit 项，单值 24 字。
static NSString *RLPRailPick(NSDictionary *fields, NSArray<NSString *> *keys, NSInteger limit) {
    if (![fields isKindOfClass:[NSDictionary class]] || !keys.count) return @"";
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *k in keys) {
        if ((NSInteger)out.count >= limit) break;
        NSString *v = RLPRailShort(fields[k], 24);
        if (v.length) [out addObject:[NSString stringWithFormat:@"%@ %@", RLPTr(k), v]];
    }
    return [out componentsJoinedByString:@" · "];
}

/// web `String(x || '')` 的只取字符串版：非字符串一律当空（元数据字段类型不信任）。
static NSString *RLPRailStr(id v) {
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : @"";
}

/// web npRailLocalTrack 的采样率写法：采样率整数千 → "96k"，否则一位小数 "44.1k"。
static NSString *RLPRailSampleRateText(id srValue) {
    const double sr = [srValue respondsToSelector:@selector(doubleValue)] ? [srValue doubleValue] : 0;
    if (!(sr > 0)) return @"";
    if (fmod(sr, 1000.0) == 0)
        return [NSString stringWithFormat:@"%ldk", (long)lround(sr / 1000.0)];
    return [NSString stringWithFormat:@"%.1fk", round(sr / 100.0) / 10.0];
}

/// web fmtTag：`sr/bits`（专辑卡 p2 在 AI 字段全空时的格式兜底）。
static NSString *RLPRailTagText(id srValue, id bitsValue) {
    NSString *sr = RLPRailSampleRateText(srValue);
    if (!sr.length) return @"";
    const NSInteger bits = [bitsValue respondsToSelector:@selector(integerValue)]
                         ? [bitsValue integerValue] : 0;
    if (bits <= 0) return sr;
    return [NSString stringWithFormat:@"%@/%ld", sr, (long)bits];
}

@interface RLPNowPlayingViewController () <NSMenuDelegate>

@property(nonatomic,strong) RLPNPCanvas *webCanvas;
@property(nonatomic,strong) NSView *analysisPanel;
@property(nonatomic,strong) NSView *railPanel;
/// web `.npchipwrap`：栏头之下、栏底之上的独立滚动区（卡片滚动时栏头不动）。
@property(nonatomic,strong) NSView *railChipWrap;
@property(nonatomic,strong) RLPNPControlBar *webControls;
@property(nonatomic,strong) NSScrollView *lyricScroll;
@property(nonatomic,strong) RLPNPLyricDocument *lyricDocument;
@property(nonatomic,copy) NSArray<RLPLyricLine *> *lyricLines;
@property(nonatomic,strong) NSMutableArray<NSButton *> *lyricRows;
@property(nonatomic) NSInteger lyricActiveIndex;
/// 当前歌词字号（按视口高度换算；只用于检测窗口高度变化后重排，不参与业务状态）。
@property(nonatomic) CGFloat lyricPointSize;
@property(nonatomic) NSTimeInterval lyricManualUntil;
@property(nonatomic) NSUInteger lyricSeq;
@property(nonatomic) NSInteger lyricRetry;
@property(nonatomic,strong) NSTimer *lyricRetryTimer;
@property(nonatomic,copy,nullable) NSArray<RLPLyricLine *> *originalLyricLines;
@property(nonatomic,assign) BOOL lyricAiApplied;
@property(nonatomic,assign) BOOL lyricAiBusy;
@property(nonatomic,assign) NSUInteger lyricAiSeq;
@property(nonatomic,strong,nullable) NSMenu *lyricAiMenu;
@property(nonatomic,strong) NSTextField *kindLabel;
@property(nonatomic,strong) NSTextField *analysisStatus;
/// web #npAnalHide / #npRailHide：面板头部右上的 22px 圆形收起键（与顶栏开关同源状态）。
@property(nonatomic,strong) NSButton *anlHide;
@property(nonatomic,strong) NSButton *railHide;
@property(nonatomic,strong) NSTextField *anlLab;       // web .anllab（独立 9.5/700/kern1.5）
@property(nonatomic,strong) NSView *anlSeg;            // web .npseg（一个外框 + 发丝分隔）
@property(nonatomic,strong) NSView *anlSep1, *anlSep2;
@property(nonatomic,strong) RLPNPAnalBody *anlBody;    // web #npAnlBody（卡片区）
@property(nonatomic,assign) CGFloat anlScrollOffset;   // 卡片区滚动位移（内容高于面板时）
@property(nonatomic,assign) CGFloat anlContentH;       // 卡片内容总高（用于夹住滚动位移）
@property(nonatomic,strong) NSButton *anlAuto;
@property(nonatomic,strong) NSButton *anlRun;
@property(nonatomic,strong) NSButton *closeButton;
@property(nonatomic,strong) NSButton *analysisToggle;
@property(nonatomic,strong) NSButton *railToggle;
@property(nonatomic,strong) NSButton *favoriteButton;
@property(nonatomic,strong) NSButton *castButton;
// web #npMeta 一行：补全徽标（.badge）+ EQ/IR + 投放/加歌单（.chip）。
// 行是否显示只取决于「有没有任何一个可见芯片」——不再是「仅补全后」。
@property(nonatomic,strong) NSView *metaChipsRow;
@property(nonatomic,strong) NSArray<NSButton *> *metaChips;
@property(nonatomic,strong) NSButton *eqChip;    // web #npEqChip（.chip）
@property(nonatomic,strong) NSButton *irChip;    // web #npIrChip（.chip）
@property(nonatomic,copy) NSString *eqPath;      // settings.kv.eq（web ADV.eq）
@property(nonatomic,copy) NSString *irPath;      // settings.kv.ir（web ADV.ir）
@property(nonatomic,strong) NSButton *saveButton;
@property(nonatomic,strong) NSTextField *railTitle;
@property(nonatomic,strong) NSSegmentedControl *railDensity;
@property(nonatomic,strong) NSArray<RLPRailChipView *> *railCards;
@property(nonatomic,strong,nullable) NSTextField *railEmptyLabel;
@property(nonatomic,strong,nullable) NSButton *railHintBtn;
@property(nonatomic,assign) BOOL castRunningState;
@property(nonatomic,copy) NSString *castDeviceName;
@property(nonatomic,strong,nullable) NSTimer *castPoll;
@property(nonatomic,copy) NSDictionary *trackMetadata;
@property(nonatomic,strong) NSPopover *knowledgePopover;
/// web `#npDrawerBg` / `#npDrawer`：页内遮罩 + 抽屉浮卡（不再用系统 NSPopover）。
@property(nonatomic,strong) RLPOverlayBackdrop *dataBackdrop;
@property(nonatomic,strong) NSView *dataDrawer;
@property(nonatomic) BOOL dataDrawerOpen;
// ---- AI 整理栏（web NP_DATA / SUMC / NPLIB 的原生落点）----
// railStates[kind] = {state:idle|loading|ok|error|insufficient, data:摘要JSON, fp:实体指纹}
@property(nonatomic,strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *railStates;
// 每个栏目当前指向的实体：{kind, name, artist, album}
@property(nonatomic,strong) NSMutableDictionary<NSString *, NSDictionary *> *railTargets;
// 页面级 summary 缓存（key=完整 URL，与 web SUMC.cache 同语义：成功/失败都缓存、insufficient 不缓存）
@property(nonatomic,strong) NSMutableDictionary<NSString *, id> *railSummaryCache;
// 同一实体指纹在飞时只发一次（web NP_DATA.inflight[fp]）
@property(nonatomic,strong) NSMutableSet<NSString *> *railSummaryInflight;
// 专辑本地曲库（web NPLIB.album）：按「专辑名|艺术家」缓存 /api/lib/album 详情
@property(nonatomic,strong) NSMutableDictionary<NSString *, NSDictionary *> *railAlbumCache;
@property(nonatomic,strong) NSMutableSet<NSString *> *railAlbumInflight;
// 世代号：切歌/换 meta 单调递增，旧世代回调一律丢弃（web NP_DATA.req）
@property(nonatomic) NSUInteger railSeq;
@property(nonatomic) BOOL railDetail;   // web NP_RAILDETAIL；持久化到 NSUserDefaults RLPNPRailDetail
@property(nonatomic,strong) RLPPlaybackStatus *webStatus;
@property(nonatomic) NSInteger playbackMode;
@property(nonatomic) BOOL statusInFlight;
@property(nonatomic) NSUInteger statusEpoch;
@property(nonatomic) BOOL favorite;
/// 最近一次已经弹过 toast 的后端错误串（每次轮询同一错误只提示一次）。
@property(nonatomic,copy) NSString *lastStatusError;
/// web `#npNextTrackHero` 当前是否占位（`.npmline` 的 Y 依赖它；默认隐藏 ⟹ 为 NO）。
@property(nonatomic) BOOL nextTrackVisible;
/// 当前循环档位用的 SF Symbol 名（web REP_ICON[0..3] 的原生等价；判据据此核对映射）。
@property(nonatomic,copy) NSString *playModeSymbol;

@property (nonatomic, strong) NSTimer *poll;
@property (nonatomic) BOOL polling;
@property (nonatomic, copy) NSString *currentPath;
// ---- U2 包3：波形（np.waveform）----
@property (nonatomic, strong) RLPWaveformView *waveformView;
/// 当前包络对应的曲目路径（nil = 尚未取/不支持）。同曲绝不重复请求。
@property (nonatomic, copy) NSString *waveformPath;
/// 波形请求序号：切曲后迟到的响应一律丢弃（与封面/歌词同一套纪律）。
@property (nonatomic, assign) NSUInteger waveformSeq;
/// 最近一次拖选（start/end 是 0..1 比例，seconds 是换算后的秒数）。
/// A/B 段端点后端尚未实现 ⟹ 本轮只留痕 + 高亮，不设循环点（挂账见 evidence）。
@property (nonatomic, copy) NSDictionary *waveformSelection;
/// v3.3.11 `npSetCover` / `npResetCover`：逐曲封面手动设置与恢复自动。
@property (nonatomic, strong) NSButton *coverSetBtn;
@property (nonatomic, strong) NSButton *coverResetBtn;
@property (nonatomic, strong) NSImageView *cover;
@property (nonatomic, strong) NSTextField *titleLabel2;
@property (nonatomic, strong) NSTextField *artistLabel2;
@property (nonatomic, strong) NSTextField *metaLabel;
@property (nonatomic, strong) NSTextView *lyricsView;
@property (nonatomic, strong) NSTextField *lyricsEmpty;
// ---- 音频分析：一行四元素（动态 / 音质 / 假无损 / 展开）----
@property (nonatomic, strong) NSView *anlRow;
@property (nonatomic, strong) RLPAnlCardView *anlDyn;
@property (nonatomic, strong) RLPAnlCardView *anlQual;
@property (nonatomic, strong) RLPAnlCardView *anlFake;
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
    if (!self) return nil;
    // web localStorage('rta-np-raildetail') 的原生等价：档位是纯展示偏好，重启后保持。
    _railDetail = [[NSUserDefaults standardUserDefaults] boolForKey:@"RLPNPRailDetail"];
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
    // 统一用 RLPHoverButton：没有 hover 语义的按钮不注入 hoverApplier（视觉保持原样）。
    RLPHoverButton *b=[[RLPHoverButton alloc] initWithFrame:NSZeroRect];
    b.title=RLPTr(title); b.target=self; b.action=action;
    b.identifier=ident; b.font=[NSFont systemFontOfSize:10.5]; b.bezelStyle=NSBezelStyleRounded;
    [parent addSubview:b]; return b;
}

#pragma mark - #npMeta 芯片（web .badge / .chip 的逐值移植）

/// web `.badge`：9.5px/600、letter-spacing .3px、padding 2 7、radius 5、1px 边框。
/// 背景/描边/文字三件套由 `styleMetaBadge:green:` 按 `--acc-weak/--acc-text`（或绿）写。
/// web `.chip:hover{background:var(--hov);color:var(--txt);border-color:var(--acc)}`。
/// 属性文字必须重写：`attributedTitle` 自带前景色，只改 contentTintColor 不会变字色。
- (void)applyChipHover:(NSButton *)button hovered:(BOOL)hovered {
    if (hovered) {
        RLPTheme *t = [RLPTheme current];
        NSString *text = button.title.length ? button.title : (button.attributedTitle.string ?: @"");
        button.title = text;
        button.attributedTitle = [[NSAttributedString alloc] initWithString:text attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:11],
            NSForegroundColorAttributeName: t.text}];
        button.font = [NSFont systemFontOfSize:11];
        button.layer.backgroundColor = t.hov.CGColor;
        button.layer.borderColor = t.accent.CGColor;
        button.contentTintColor = t.text;
    } else {
        [self styleMetaChip:button];
    }
}

- (void)styleMetaBadge:(NSButton *)b green:(BOOL)green {
    RLPTheme *t=[RLPTheme current];
    NSString *text=b.title.length?b.title:b.attributedTitle.string;
    if (!text) text=@"";
    b.title=text;
    b.attributedTitle=[[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName:[NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName:green?t.okText:t.accentText,
        NSKernAttributeName:@0.3}];
    b.font=[NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold];
    b.wantsLayer=YES;
    b.layer.cornerRadius=5;
    b.layer.borderWidth=1;
    b.layer.backgroundColor=(green?t.okBg:t.accentWeak).CGColor;
    b.layer.borderColor=(green?t.okLine:t.accentWeak).CGColor;
    b.contentTintColor=green?t.okText:t.accentText;
}

/// web `.chip`：11px、padding 3 9、radius 12、bg `--bg3`、border `--line`、文字 `--txt2`。
- (void)styleMetaChip:(NSButton *)b {
    RLPTheme *t=[RLPTheme current];
    NSString *text=b.title.length?b.title:b.attributedTitle.string;
    if (!text) text=@"";
    b.title=text;
    b.attributedTitle=[[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName:[NSFont systemFontOfSize:11],
        NSForegroundColorAttributeName:t.text2}];
    b.font=[NSFont systemFontOfSize:11];
    b.bordered=NO;
    b.bezelStyle=NSBezelStyleSmallSquare;
    b.wantsLayer=YES;
    b.layer.cornerRadius=12;
    b.layer.borderWidth=1;
    b.layer.backgroundColor=t.bg3.CGColor;
    b.layer.borderColor=t.line.CGColor;
    b.contentTintColor=t.text2;
    // web 的 EQ/IR/投放/加歌单 `.chip` 各带 11–12px 内联 SVG（用户「chip SVG 图标」挂账项）。
    // 用 SF Symbol 做同构图标：EQ=三段滑杆、IR=波形、投放=AirPlay 音频、加歌单=加号。
    NSString *sym = nil;
    if ([b.identifier isEqualToString:@"npEqChip"]) sym = @"slider.horizontal.3";
    else if ([b.identifier isEqualToString:@"npIrChip"]) sym = @"waveform";
    else if ([b.identifier isEqualToString:@"npCastBtn"]) sym = @"airplayaudio";
    else if ([b.identifier isEqualToString:@"npAddSq"]) sym = @"plus";
    if (sym) {
        NSImage *img = [NSImage imageWithSystemSymbolName:sym accessibilityDescription:nil];
        if (img) {
            img.size = NSMakeSize(11, 11);
            b.image = img;
            b.imagePosition = NSImageLeft;
            b.imageScaling = NSImageScaleProportionallyDown;
        } else {
            b.image = nil;   // 系统缺这个符号：退回纯文字，绝不留空白图位
        }
    }
}

/// 主题切换后重刷（徽标文字在 b.title 里，chips 的文案是固定的）。
- (void)restyleMetaChipsForTheme {
    for (NSUInteger i=0;i<self.metaChips.count;i++)
        [self styleMetaBadge:self.metaChips[i] green:(i==self.metaChips.count-1)];
    for (NSButton *b in @[self.eqChip,self.irChip,self.castButton,self.saveButton]) [self styleMetaChip:b];
}

- (void)buildContent {
    RLPTheme *t=[RLPTheme current]; NSView *host=self.webCanvas;
    self.cover=[[NSImageView alloc] initWithFrame:NSZeroRect]; self.cover.identifier=@"npCover";
    self.cover.imageScaling=NSImageScaleAxesIndependently; self.cover.wantsLayer=YES;
    self.cover.layer.cornerRadius=14;self.cover.layer.masksToBounds=YES; [host addSubview:self.cover];
    // v3.3.11 `npSetCover` / `npResetCover`（web 在封面下方一行小按钮）。
    // 为什么必须有真实控件：只加后端路由等于「设置成功但没人能点」，parity 也会漏记。
    self.coverSetBtn=[NSButton buttonWithTitle:RLPTr(@"设置歌曲封面") target:self action:@selector(onSetCover:)];
    self.coverSetBtn.identifier=@"npSetCover";self.coverSetBtn.bezelStyle=NSBezelStyleRounded;
    self.coverSetBtn.controlSize=NSControlSizeMini;
    self.coverSetBtn.toolTip=RLPTr(@"仅设置当前歌曲封面，不修改专辑和音乐文件");
    [host addSubview:self.coverSetBtn];
    self.coverResetBtn=[NSButton buttonWithTitle:RLPTr(@"自动") target:self action:@selector(onResetCover:)];
    // v3.3.11：只有「当前生效的是手动封面」才显示「自动」按钮（web 依 /api/meta 的 coverSource）。
    // 旧实现没有该字段 ⟹ 按钮常显，点了也没东西可恢复（偏差台账那条）。
    self.coverResetBtn.hidden = YES;
    self.coverResetBtn.identifier=@"npResetCover";self.coverResetBtn.bezelStyle=NSBezelStyleRounded;
    self.coverResetBtn.controlSize=NSControlSizeMini;self.coverResetBtn.toolTip=RLPTr(@"恢复自动封面");
    [host addSubview:self.coverResetBtn];
    self.kindLabel=RLPLabel(RLPTr(@"正在播放"),[NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],t.mut2); self.kindLabel.identifier=@"npKind";
    RLPSetKernedText(self.kindLabel, RLPTr(@"正在播放"), 1.6);   // web .npkind{letter-spacing:1.6px}
    self.titleLabel2=RLPLabel(RLPTr(@"未播放"),[NSFont systemFontOfSize:20 weight:NSFontWeightBold],t.text); self.titleLabel2.identifier=@"npTitle";
    self.artistLabel2=RLPLabel(@"",[NSFont systemFontOfSize:13],t.mut); self.artistLabel2.identifier=@"npSub";
    self.metaLabel=RLPLabel(@"",[NSFont systemFontOfSize:12],t.mut2); self.metaLabel.identifier=@"npNextTrackHero";
    self.metaLabel.hidden=YES;   // web #npNextTrackHero 默认 display:none，只有「播放中 + 有队列」才显示
    for(NSView *v in @[self.kindLabel,self.titleLabel2,self.artistLabel2,self.metaLabel]) [host addSubview:v];
    // 补全徽标行 + 当前 EQ/IR + 投放/加歌单（web #npMeta 的同一行，flex-wrap 由 layoutMetaChips 算）。
    self.metaChipsRow=[[NSView alloc] initWithFrame:NSZeroRect]; self.metaChipsRow.identifier=@"npMeta";
    self.metaChipsRow.hidden=YES; [host addSubview:self.metaChipsRow];
    NSMutableArray *mc=[NSMutableArray array];
    for(NSString *ident in @[@"npMeta.year",@"npMeta.genre",@"npMeta.albumArtist",@"npMeta.enriched"]) {
        NSButton *b=[NSButton buttonWithTitle:@"" target:nil action:nil];
        b.identifier=ident; b.bordered=NO; b.wantsLayer=YES; b.layer.cornerRadius=5; b.layer.borderWidth=1;
        b.font=[NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold]; b.hidden=YES;
        [self.metaChipsRow addSubview:b]; [mc addObject:b];
    }
    self.metaChips=mc;
    self.favoriteButton=[self webButton:@"♡" identifier:@"npFavBtn" action:@selector(onFav:) parent:host]; self.favoriteButton.bordered=NO;self.favoriteButton.font=[NSFont systemFontOfSize:22];
    // 261024-02 #5：投放 / 加歌单在 web 里也是 #npMeta 里的 .chip（不是下面独立按钮行）。
    self.castButton=[self webButton:@"推送到设备" identifier:@"npCastBtn" action:@selector(onCastCurrent:) parent:self.metaChipsRow];
    self.saveButton=[self webButton:@"添加到歌单" identifier:@"npAddSq" action:@selector(onSaveCurrent:) parent:self.metaChipsRow];
    self.castButton.toolTip=RLPTr(@"把当前曲目推送到 UPnP / DLNA 设备");
    self.saveButton.toolTip=RLPTr(@"把当前曲目添加到指定歌单");
    self.eqChip=[self webButton:@"EQ" identifier:@"npEqChip" action:@selector(onEqChip:) parent:self.metaChipsRow];
    self.irChip=[self webButton:@"IR" identifier:@"npIrChip" action:@selector(onIrChip:) parent:self.metaChipsRow];
    for(NSButton *b in @[self.eqChip,self.irChip,self.castButton,self.saveButton]) {
        b.hidden=YES; [self styleMetaChip:b];
    }
    // web `.chip:hover{background:var(--hov);color:var(--txt);border-color:var(--acc)}`；
    // 投放芯片投放中态是绿样式，hover 退出要回到 applyCastChipStyle 而不是基础 chip。
    for (NSButton *b in @[self.eqChip,self.irChip,self.saveButton]) {
        ((RLPHoverButton *)b).hoverApplier = ^(RLPHoverButton *btn, BOOL hovered) {
            [self applyChipHover:btn hovered:hovered];
        };
    }
    ((RLPHoverButton *)self.castButton).hoverApplier = ^(RLPHoverButton *btn, BOOL hovered) {
        [self applyChipHover:btn hovered:hovered];
        if (!hovered) [self applyCastChipStyle];
    };
    // Existing compare/work functions remain accessible; they are not removed for appearance.
    self.compareBtn=[self webButton:@"对比版本" identifier:@"npCompare" action:@selector(onCompare:) parent:host];
    self.worksBtn=[self webButton:@"古典作品版本" identifier:@"np.works" action:@selector(onOpenWorks:) parent:host];
    self.closeButton=[self webButton:@"↙" identifier:@"npClose" action:@selector(onClosePlayback:) parent:host];self.closeButton.toolTip=RLPTr(@"返回（Esc）");
    self.analysisToggle=[self webButton:@"▥" identifier:@"npAnalToggle" action:@selector(onToggleAnalysis:) parent:host];self.analysisToggle.toolTip=RLPTr(@"显示 / 隐藏音频分析面板");
    self.railToggle=[self webButton:@"▤" identifier:@"npRailToggle" action:@selector(onToggleRail:) parent:host];self.railToggle.toolTip=RLPTr(@"显示 / 隐藏 AI 资料面板");
    self.analysisPanel=[[NSView alloc] initWithFrame:NSZeroRect];self.analysisPanel.identifier=@"npAnal";[host addSubview:self.analysisPanel];
    self.railPanel=[[NSView alloc] initWithFrame:NSZeroRect];self.railPanel.identifier=@"npRail";[host addSubview:self.railPanel];
    // 头部：独立的 9.5/700/kern1.5 标题（web .anllab）+ 右端状态（web #npAnlStat）
    self.anlLab=RLPLabel(RLPTr(@"音频分析"),[NSFont systemFontOfSize:9.5 weight:NSFontWeightBold],t.mut2);
    self.anlLab.identifier=@"npAnlLab";[self.analysisPanel addSubview:self.anlLab];
    self.analysisStatus=RLPLabel(RLPTr(@"未播放"),[NSFont systemFontOfSize:10],t.mut2);
    self.analysisStatus.identifier=@"npAnlStat";self.analysisStatus.alignment=NSTextAlignmentRight;
    [self.analysisPanel addSubview:self.analysisStatus];
    // web #npAnalHide（.anlhide{position:absolute;top:7;right:8;22x22;圆形;收起箭头}）：
    // 面板头部自己的收起键，和右上角 #npAnalToggle 是**同一份**隐藏状态（web 两个入口写同一 localStorage）。
    self.anlHide=[self webButton:@"" identifier:@"npAnalHide" action:@selector(onHideAnalysis:) parent:self.analysisPanel];
    self.anlHide.title=@"";self.anlHide.bordered=NO;self.anlHide.imagePosition=NSImageOnly;
    self.anlHide.image=[NSImage imageWithSystemSymbolName:@"chevron.left"
                                  accessibilityDescription:RLPTr(@"隐藏音频分析面板")];
    self.anlHide.contentTintColor=t.mut2;self.anlHide.wantsLayer=YES;self.anlHide.layer.cornerRadius=11;
    self.anlHide.toolTip=RLPTr(@"隐藏音频分析面板，可在右上角重新显示");
    ((RLPHoverButton *)self.anlHide).hoverApplier = ^(RLPHoverButton *btn, BOOL hovered) {
        RLPTheme *t2=[RLPTheme current];
        btn.layer.backgroundColor = (hovered ? t2.hov2 : NSColor.clearColor).CGColor;
        btn.contentTintColor = hovered ? t2.text : t2.mut2;
    };
    // 三个动作装进**一个**带外框的分段控件（web .npseg：radius 9、10.5/600、padding 3 11、发丝分隔）
    self.anlSeg=[[NSView alloc] initWithFrame:NSZeroRect];self.anlSeg.identifier=@"npAnlSeg";
    self.anlSeg.wantsLayer=YES;self.anlSeg.layer.cornerRadius=9;self.anlSeg.layer.borderWidth=1;
    self.anlSeg.layer.masksToBounds=YES;[self.analysisPanel addSubview:self.anlSeg];
    self.anlSep1=[[NSView alloc] initWithFrame:NSZeroRect];self.anlSep1.wantsLayer=YES;[self.anlSeg addSubview:self.anlSep1];
    self.anlSep2=[[NSView alloc] initWithFrame:NSZeroRect];self.anlSep2.wantsLayer=YES;[self.anlSeg addSubview:self.anlSep2];
    self.anlAuto=[self webButton:@"自动" identifier:@"npAnlAuto" action:@selector(onToggleAuto:) parent:self.anlSeg];
    self.anlExpand=[self webButton:@"详细" identifier:@"npAnlToggle" action:@selector(onAnlExpand:) parent:self.anlSeg];
    self.anlRun=[self webButton:@"分析" identifier:@"npAnlRun" action:@selector(onAnlReanalyze:) parent:self.anlSeg];
    for(NSButton *b in @[self.anlAuto,self.anlExpand,self.anlRun]) {
        b.bordered=NO;b.bezelStyle=NSBezelStyleSmallSquare;
        b.font=[NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold];
        b.wantsLayer=YES;b.layer.backgroundColor=NSColor.clearColor.CGColor;
    }
    // 卡片区（web #npAnlBody）：三张摘要卡始终在视图树里，展开档在卡内长指标，不再换成文本 blob。
    self.anlBody=[[RLPNPAnalBody alloc] initWithFrame:NSZeroRect];self.anlBody.identifier=@"npAnlBody";
    self.anlBody.wantsLayer=YES;self.anlBody.layer.masksToBounds=YES;[self.analysisPanel addSubview:self.anlBody];
    self.anlDyn=[self anlCardWithIdentifier:@"anl.dyn"];self.anlQual=[self anlCardWithIdentifier:@"anl.qual"];self.anlFake=[self anlCardWithIdentifier:@"anl.fake"];
    __weak __typeof__(self) wsAnl=self;
    self.anlBody.onScroll=^(CGFloat deltaY){ __typeof__(self) s=wsAnl; if(s)[s onAnlBodyScroll:deltaY]; };
    self.anlDetail=[self makeTextView]; self.anlDetailScroll=[[NSScrollView alloc] initWithFrame:NSZeroRect];self.anlDetailScroll.drawsBackground=NO;self.anlDetailScroll.hasVerticalScroller=YES;self.anlDetailScroll.documentView=self.anlDetail;self.anlDetailScroll.hidden=YES;[self.analysisPanel addSubview:self.anlDetailScroll];
    self.anlReanalyze=[self webButton:@"重新分析" identifier:@"npAnlRecalculate" action:@selector(onAnlReanalyze:) parent:self.analysisPanel];self.anlReanalyze.hidden=YES;self.anlReanalyze.font=[NSFont systemFontOfSize:10.5];
    self.lyricDocument=[[RLPNPLyricDocument alloc] initWithFrame:NSMakeRect(0,0,500,400)];
    self.lyricScroll=[[NSScrollView alloc] initWithFrame:NSZeroRect]; self.lyricScroll.identifier=@"npLyric";self.lyricScroll.drawsBackground=NO;self.lyricScroll.hasVerticalScroller=NO;self.lyricScroll.documentView=self.lyricDocument;[host addSubview:self.lyricScroll];
    self.lyricScroll.contentView.postsBoundsChangedNotifications=YES;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onLyricScrolled:) name:NSViewBoundsDidChangeNotification object:self.lyricScroll.contentView];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onExternalFavoritesChanged:) name:RLPFavoritesChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onNowPlayingEscape:)
                                                 name:@"RLPNowPlayingEscapeNotification" object:nil];
    self.lyricRows=[NSMutableArray array];self.lyricLines=@[];self.lyricActiveIndex=-1;
    // web `#npLyric` 空态是**两行**：主行 14pt(clamp) `没有歌词` + 副行 12px `--mut2` 说明。
    // 旧码单行 `没有歌词 · 同名 LRC…` + maximumNumberOfLines=1 ⟹ 副文案被截断、字号也不对。
    self.lyricsEmpty=RLPLabel(RLPTr(@"没有歌词"),[NSFont systemFontOfSize:14],t.mut2);
    self.lyricsEmpty.alignment=NSTextAlignmentCenter;
    self.lyricsEmpty.maximumNumberOfLines=0;
    self.lyricsEmpty.lineBreakMode=NSLineBreakByWordWrapping;
    [self.lyricDocument addSubview:self.lyricsEmpty];
    self.lyricDocument.menu=[self lyricAiMenu];
    self.lyricScroll.menu=[self lyricAiMenu];
    self.lyricsEmpty.menu=[self lyricAiMenu];
    [self setLyricsPlaceholder:@"没有歌词"
                        detail:@"同名 .lrc 文件、内嵌歌词，或播放时自动在线补全（可在设置-元数据补全关闭）"];
    self.railTitle=RLPLabel(RLPTr(@"AI 整理"),[NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold],t.mut2);
    self.railTitle.identifier=@"npRailCap";
    // web .nprailcap：font-size:9.5px; letter-spacing:1.5px（大写小标题的疏排感，判据要量）
    {
        NSMutableParagraphStyle *ps=[[NSMutableParagraphStyle alloc] init];ps.lineBreakMode=NSLineBreakByTruncatingTail;
        self.railTitle.attributedStringValue=[[NSAttributedString alloc] initWithString:RLPTr(@"AI 整理")
            attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold],
                         NSForegroundColorAttributeName:t.mut2,
                         NSKernAttributeName:@1.5,
                         NSParagraphStyleAttributeName:ps}];
    }
    [self.railPanel addSubview:self.railTitle];
    self.railDensity=[NSSegmentedControl segmentedControlWithLabels:@[RLPTr(@"简略"),RLPTr(@"详细")] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(onRailDensity:)];self.railDensity.identifier=@"npRailSeg";self.railDensity.selectedSegment=self.railDetail?1:0;[self.railPanel addSubview:self.railDensity];
    // web #npRailHide（.nprailhide{22x22;圆形;收起箭头}）：与右上角 #npRailToggle 共用同一隐藏状态。
    self.railHide=[self webButton:@"" identifier:@"npRailHide" action:@selector(onHideRail:) parent:self.railPanel];
    self.railHide.title=@"";self.railHide.bordered=NO;self.railHide.imagePosition=NSImageOnly;
    self.railHide.image=[NSImage imageWithSystemSymbolName:@"chevron.right"
                                accessibilityDescription:RLPTr(@"隐藏 AI 资料面板")];
    self.railHide.contentTintColor=t.mut2;self.railHide.wantsLayer=YES;self.railHide.layer.cornerRadius=11;
    self.railHide.toolTip=RLPTr(@"隐藏 AI 资料面板，可在右上角重新显示");
    ((RLPHoverButton *)self.railHide).hoverApplier = ^(RLPHoverButton *btn, BOOL hovered) {
        RLPTheme *t2=[RLPTheme current];
        btn.layer.backgroundColor = (hovered ? t2.hov2 : NSColor.clearColor).CGColor;
        btn.contentTintColor = hovered ? t2.text : t2.mut2;
    };
    // 三张卡（歌曲/专辑/艺术家）= web `.npchip`。旧实现是 NSButton 多行标题，
    // AppKit 把文字画在卡片左下角（上半部全空）⟹ 用户报「排版散」。
    RLPRailWrapView *wrap=[[RLPRailWrapView alloc] initWithFrame:NSZeroRect];
    wrap.identifier=@"npChipWrap";
    wrap.wantsLayer=YES;
    wrap.layer.masksToBounds=YES;   // web overflow:auto：卡片裁在 chipwrap 内
    self.railChipWrap=wrap;
    [self.railPanel addSubview:wrap];
    __weak __typeof__(self) wsWrap=self;
    wrap.onScrollDelta=^(CGFloat deltaY){
        __typeof__(self) s=wsWrap; if(!s) return;
        RLPRailWrapView *w=(RLPRailWrapView *)s.railChipWrap;
        w.contentOffset = w.contentOffset - deltaY;
    };
    wrap.onOffsetChanged=^(CGFloat off){
        __typeof__(self) s=wsWrap; if(s) [s railLayoutChips];
    };
    NSMutableArray<RLPRailChipView *> *cards=[NSMutableArray array];
    __weak __typeof__(self) wsRail=self;
    NSUInteger railIdx=0;
    // 第 4 张 = web npDataTargets 的 work tab「作品」：只在古典曲目出现（可见性在 render 里判定，
    // 结构恒在 ⟹ 切曲时不必重建视图树，卡片隐藏即可）。
    for(NSString *name in @[@"歌曲",@"专辑",@"艺术家",@"作品"]){
        RLPRailChipView *c=[[RLPRailChipView alloc] initWithFrame:NSZeroRect];
        c.identifier=[@"npChip." stringByAppendingString:name];
        c.chipIndex=(NSInteger)railIdx++;
        c.detailMode=self.railDetail;   // 恢复上次的「简略/详细」档位
        c.onTap=^(RLPRailChipView *chip){ __typeof__(self) s=wsRail; if(s)[s onRailCard:chip]; };
        [wrap addSubview:c];
        [cards addObject:c];
    }
    self.railCards=cards;

    // web `.nprailempty`：没有任何栏目（没有可整理的实体）时的整块说明。
    self.railEmptyLabel=RLPLabel(
        RLPTr(@"播放后在右侧显示歌曲、专辑、艺术家（古典作品还会多一栏演绎版本）的精简整理资料。"),
        [NSFont systemFontOfSize:10.5], t.mut2);
    self.railEmptyLabel.identifier=@"npRailEmpty";
    self.railEmptyLabel.maximumNumberOfLines=0;
    self.railEmptyLabel.lineBreakMode=NSLineBreakByWordWrapping;
    self.railEmptyLabel.hidden=YES;
    [self.railPanel addSubview:self.railEmptyLabel];

    // web `.nprailhint`：只有「加载中 / 失败可重试 / 资料不足」三种才出现。
    self.railHintBtn=[NSButton buttonWithTitle:@"" target:self action:@selector(onRailHintRetry:)];
    self.railHintBtn.bordered=NO;
    self.railHintBtn.alignment=NSTextAlignmentLeft;
    self.railHintBtn.identifier=@"npSummHint";
    self.railHintBtn.hidden=YES;
    [self.railPanel addSubview:self.railHintBtn];
    self.knowledge=[[RLPKnowledgeView alloc] initWithFrame:NSMakeRect(0,0,420,380)];
    self.webControls=[[RLPNPControlBar alloc] initWithFrame:NSZeroRect];[host addSubview:self.webControls];
    self.webControls.autoresizingMask=NSViewNotSizable;
    self.webControls.repBtn.target=self;self.webControls.repBtn.action=@selector(onCycleMode:);
    // web `.k:hover{background:var(--hov2);color:var(--txt)}`；退出时按当前档位恢复图标色。
    ((RLPHoverButton *)self.webControls.repBtn).hoverApplier = ^(RLPHoverButton *btn, BOOL hovered) {
        RLPTheme *t2=[RLPTheme current];
        btn.layer.backgroundColor = (hovered ? t2.hov2 : NSColor.clearColor).CGColor;
        if (hovered) btn.contentTintColor = t2.text;
        else [self applyPlayModeUI];   // 档位色（顺序=mut / 其余=accentText）
    };self.webControls.repBtn.bordered=NO;self.webControls.repBtn.image=[NSImage imageWithSystemSymbolName:@"repeat" accessibilityDescription:@"循环方式"];self.webControls.repBtn.title=@"";
    for(NSButton *b in @[self.webControls.prevBtn,self.webControls.playBtn,self.webControls.nextBtn,self.webControls.stopBtn])b.target=self;
    self.webControls.prevBtn.action=@selector(onPrevious:);self.webControls.playBtn.action=@selector(onPause:);self.webControls.nextBtn.action=@selector(onNext:);self.webControls.stopBtn.action=@selector(onStop:);
    self.webControls.seek.cell=[RLPNPAccentCell new];self.webControls.seek.minValue=0;self.webControls.seek.maxValue=1;
    self.webControls.volume.cell=[RLPNPAccentCell new];self.webControls.volume.minValue=0;self.webControls.volume.maxValue=1000;
    self.webControls.volume.identifier=@"np.vol";   // 功能实现落在这个滑块（web #npVol）
    self.webControls.seek.target=self;self.webControls.seek.action=@selector(onSeekPreview:);self.webControls.volume.target=self;self.webControls.volume.action=@selector(onCommitVolume:);
    __weak __typeof__(self) ws=self;self.webControls.seek.onCommit=^{[ws onCommitSeek:nil];};self.webControls.volume.onCommit=^{[ws onCommitVolume:nil];};
    self.webControls.onVolumeWriteStarted = ^{
        __typeof__(self) s = ws;
        if (!s) return;
        ++s.statusEpoch;
        s.statusInFlight = NO;
    };
    self.webControls.onVolumeWriteFailed = ^{
        __typeof__(self) s = ws;
        if (s && s.polling) [s refresh];
    };
    // U2 包3：波形条挂在控制条正上方（几何在 layoutWebPlayback 给出：高 50pt）。
    // 视图只负责画；取数在 loadWaveformForPath（切曲/首次进入一次），播放头只跟 /api/status。
    self.waveformView=[[RLPWaveformView alloc] initWithFrame:NSZeroRect];
    self.waveformView.identifier=@"np.waveform";
    __weak __typeof__(self) wsWave=self;
    self.waveformView.onSeek=^(double fraction){
        __typeof__(self) s=wsWave;
        if(s)[s seekFromWaveformAtFraction:fraction];
    };
    self.waveformView.onSelect=^(double start,double end,double seconds){
        __typeof__(self) s=wsWave;
        if(!s)return;
        s.waveformSelection=@{@"start":@(start),@"end":@(end),@"seconds":@(seconds)};
    };
    [host addSubview:self.waveformView];
    // Existing version actions remain reachable from the track context menu.
    self.compareBtn.hidden=YES;self.worksBtn.hidden=YES;
    NSArray *symbols=@[@"arrow.down.right.and.arrow.up.left",@"chart.bar.xaxis",@"text.bubble"];
    NSArray *roundButtons=@[self.closeButton,self.analysisToggle,self.railToggle];
    for(NSUInteger i=0;i<roundButtons.count;i++){NSButton *b=roundButtons[i];b.title=@"";b.bordered=NO;b.image=[NSImage imageWithSystemSymbolName:symbols[i] accessibilityDescription:b.toolTip?:@""];b.imagePosition=NSImageOnly;b.wantsLayer=YES;b.layer.cornerRadius=i==0?19:17;b.layer.borderWidth=1;
        // web `.npclose{background:rgba(255,255,255,.92);border:1px solid rgba(15,23,42,.14)}`，
        // 深色 `rgba(30,32,38,.92)/rgba(255,255,255,.16)`；旧码用 --bg 不透明白，hover 前后肉眼无差。
        b.layer.borderColor=(t.isLight?[NSColor colorWithSRGBRed:15/255. green:23/255. blue:42/255. alpha:.14]:[NSColor colorWithWhite:1 alpha:.16]).CGColor;
        b.layer.backgroundColor=(t.isLight?[NSColor colorWithWhite:1 alpha:.92]:[NSColor colorWithSRGBRed:30/255. green:32/255. blue:38/255. alpha:.92]).CGColor;
        b.contentTintColor=t.mut;}
    // web `.npclose:hover{background:#fff;transform:scale(1.04)}`、`.nptoggle:hover` 同款（深色改 rgba(48,50,58,.96)）
    for (NSButton *b in roundButtons) {
        ((RLPHoverButton *)b).hoverApplier = ^(RLPHoverButton *btn, BOOL hovered) {
            RLPTheme *t2 = [RLPTheme current];
            btn.layer.backgroundColor = (hovered
                ? (t2.isLight ? NSColor.whiteColor
                   : [NSColor colorWithSRGBRed:48/255. green:50/255. blue:58/255. alpha:.96])
                : (t2.isLight ? [NSColor colorWithWhite:1 alpha:.92]
                   : [NSColor colorWithSRGBRed:30/255. green:32/255. blue:38/255. alpha:.92])).CGColor;
            btn.contentTintColor = hovered ? t2.text : t2.mut;
            btn.layer.transform = hovered ? CATransform3DMakeScale(1.04, 1.04, 1) : CATransform3DIdentity;
            btn.layer.zPosition = hovered ? 1.0 : 0.0;
        };
    }
    self.analysisPanel.hidden=[[NSUserDefaults standardUserDefaults] boolForKey:@"RLPNPAnalysisHidden"];
    self.railPanel.hidden=[[NSUserDefaults standardUserDefaults] boolForKey:@"RLPNPRailHidden"];
    // web #npDrawerBg / #npDrawer：页内浮层（不是系统弹窗）——遮罩铺满页面、抽屉贴右。
    // 加在 webCanvas 末尾（z 序最上），点遮罩关闭；不动底层滚动视图。
    self.dataBackdrop=[[RLPOverlayBackdrop alloc] initWithFrame:NSZeroRect];
    self.dataBackdrop.identifier=@"npDrawerBg";
    self.dataBackdrop.wantsLayer=YES;
    self.dataBackdrop.layer.backgroundColor=[NSColor colorWithWhite:0 alpha:.30].CGColor;
    self.dataBackdrop.hidden=YES;
    __weak __typeof__(self) wsDrawer=self;
    self.dataBackdrop.onClick=^{ __typeof__(self) s=wsDrawer; if(s)[s closeDataDrawer]; };
    [self.webCanvas addSubview:self.dataBackdrop];
    self.dataDrawer=[[NSView alloc] initWithFrame:NSZeroRect];
    self.dataDrawer.identifier=@"npDrawer";
    self.dataDrawer.wantsLayer=YES;
    self.dataDrawer.layer.cornerRadius=18;
    self.dataDrawer.layer.borderWidth=1;
    // 注意：masksToBounds=NO 才能看到 box-shadow（CSS 的 overflow:hidden 不裁 box-shadow）；
    // 内容的圆角裁切交给 knowledge 自身的圆角/背景（windows 侧本来也不透明）。
    self.dataDrawer.layer.shadowOpacity=0.42;
    self.dataDrawer.layer.shadowRadius=40.0;    // CSS blur 80px ≈ CALayer radius 40
    self.dataDrawer.layer.shadowOffset=CGSizeMake(0,-28.0);
    self.dataDrawer.layer.shadowColor=NSColor.blackColor.CGColor;
    self.dataDrawer.hidden=YES;
    self.knowledge.frame=self.dataDrawer.bounds;
    self.knowledge.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    [self.dataDrawer addSubview:self.knowledge];
    [self.webCanvas addSubview:self.dataDrawer];
    [self applyTheme];[self applyPlayModeUI];[self anlPaint];[self layoutWebPlayback];
}
/// web buildNpMetaHtml 的原生同构：`meta.enriched === true` 才出**徽标**；
/// 年份/流派/专辑艺术家取 /api/meta 的同名字段，值后面跟来源提示（meta.sources）。
/// 注意：徽标只占 #npMeta 一行的**前一组**；EQ/IR（settings.kv）与投放/加歌单（.chip）
/// 是同一行的后两组，各自按自己的数据出现（web 的 innerHTML 也是三段拼接）。
- (void)renderMetaChipsFromMeta:(NSDictionary *)json {
    NSDictionary *meta = [json[@"meta"] isKindOfClass:[NSDictionary class]] ? json[@"meta"] : nil;
    const BOOL enriched = [meta[@"enriched"] respondsToSelector:@selector(boolValue)] &&
                          [meta[@"enriched"] boolValue];
    NSDictionary *sources=[meta[@"sources"] isKindOfClass:[NSDictionary class]]?meta[@"sources"]:@{};
    NSArray *specs=@[@[@"year",RLPTr(@"年份")],@[@"genre",RLPTr(@"流派")],@[@"albumArtist",RLPTr(@"专辑艺术家")]];
    // 先复位四个徽标：文字/提示/配色都回默认，由下面的 enriched 分支决定谁出现。
    for(NSUInteger i=0;i<self.metaChips.count;i++) {
        NSButton *b=self.metaChips[i];
        b.hidden=YES; b.title=@""; b.toolTip=nil;
        [self styleMetaBadge:b green:(i==self.metaChips.count-1)];
    }
    if(enriched) {
        for(NSUInteger i=0;i<specs.count;i++) {
            NSString *key=specs[i][0], *label=specs[i][1];
            id v=json[key];
            if(![v respondsToSelector:@selector(description)]) continue;
            NSString *text=[v description]; if(!text.length) continue;
            NSButton *b=self.metaChips[i];
            // web 是 `label + '  ' + v` —— **两个**空格，不是排版近似。
            b.title=[NSString stringWithFormat:@"%@  %@",label,text];
            b.toolTip=[NSString stringWithFormat:@"%@: %@",RLPTr(@"来源"),
                       ([sources[key] isKindOfClass:[NSString class]] && [sources[key] length])?sources[key]:RLPTr(@"本地标签")];
            [self styleMetaBadge:b green:NO]; b.hidden=NO;
        }
        // 「已补全」徽标（web .badge.g 绿色）：标签/封面/歌词已由在线来源补全。
        NSButton *en=self.metaChips.lastObject;
        en.title=RLPTr(@"已补全");
        en.toolTip=RLPTr(@"标签/封面/歌词已由在线来源补全，可在设置-元数据补全关闭");
        [self styleMetaBadge:en green:YES]; en.hidden=NO;
    }
    // 徽标只是这一行的成员之一：整行是否显示交给统一判定（EQ/IR、投放/加歌单也在这一行）。
    [self applyMetaChipVisibility];
}

/// #npMeta 行可见 = 至少一个芯片可见。三组芯片各自的数据源：
///   徽标     ← /api/meta（meta.enriched + 字段 + sources）
///   EQ/IR    ← /api/settings 的 kv.eq / kv.ir（web loadSettings → ADV.eq/ADV.ir）
///   投放/加歌单 ← 当前播放状态（web 恒显示，因为 CAST.state 在启动时就读了；原生没有全局
///               cast 状态缓存，用「拿到过播放状态快照或页面在轮询」作为「当前曲目可操作」的等价条件，
///               没拿到状态时这两个按钮点了也没有对象，不摆一个空壳）。
- (void)applyMetaChipVisibility {
    self.eqChip.hidden=(self.eqPath.length==0);
    if(!self.eqChip.hidden)
        self.eqChip.toolTip=[NSString stringWithFormat:@"%@%@%@",RLPTr(@"当前 EQ："),
                             self.eqPath.lastPathComponent,RLPTr(@"（点击打开 EQ 与房间校正）")];
    else self.eqChip.toolTip=nil;
    self.irChip.hidden=(self.irPath.length==0);
    if(!self.irChip.hidden)
        self.irChip.toolTip=[NSString stringWithFormat:@"%@%@%@",RLPTr(@"当前 IR："),
                             self.irPath.lastPathComponent,RLPTr(@"（点击打开 EQ 与房间校正）")];
    else self.irChip.toolTip=nil;
    const BOOL live=(self.polling || self.webStatus!=nil);
    self.castButton.hidden=!live;
    self.saveButton.hidden=!live;
    BOOL any=NO;
    for(NSButton *b in self.metaChips) if(!b.hidden) any=YES;
    for(NSButton *b in @[self.eqChip,self.irChip,self.castButton,self.saveButton]) if(!b.hidden) any=YES;
    self.metaChipsRow.hidden=!any;
    [self layoutWebPlayback];
}

/// web `.npmline` 的 flex-wrap：gap 6（横竖同值）、align-items:center、每行一致行高、
/// min-height 22、margin-top 10。徽标固有高 22（9.5px 文字 + 2×7 横向 padding + 2×1 边框），
/// chip 固有高 24（11px + 3×2 + 2×1）。返回整行高度（≥ 22）；芯片放在行内坐标系（y 从 0 起）。
- (CGFloat)layoutMetaChipsInWidth:(CGFloat)iw {
    NSMutableArray<NSButton *> *items=[NSMutableArray array];
    for(NSButton *b in self.metaChips) if(!b.hidden) [items addObject:b];
    for(NSButton *b in @[self.eqChip,self.irChip,self.castButton,self.saveButton]) if(b&&!b.hidden) [items addObject:b];
    if(!items.count) return 22.0;
    NSMutableArray<NSMutableArray<NSButton *> *> *lines=[NSMutableArray array];
    NSMutableArray<NSMutableArray<NSNumber *> *> *widths=[NSMutableArray array];
    NSMutableArray<NSButton *> *line=nil; NSMutableArray<NSNumber *> *lineW=nil; CGFloat cx=0;
    for(NSButton *b in items) {
        const BOOL badge=[b.identifier hasPrefix:@"npMeta."];
        NSAttributedString *as=b.attributedTitle;
        CGFloat tw=as.length?as.size.width:[b.title sizeWithAttributes:@{NSFontAttributeName:b.font}].width;
        const CGFloat iconExtra = b.image ? 15.0 : 0.0;   // 11px 图标 + 4px 间距（web chip 的内联 SVG 同构）
        const CGFloat bw=ceil(tw)+(badge?16.0:20.0)+iconExtra;   // padding 2×7 或 2×9 + 边框 2×1
        if(!line || (cx>0 && cx+bw>iw)) { line=[NSMutableArray array]; lineW=[NSMutableArray array]; [lines addObject:line]; [widths addObject:lineW]; cx=0; }
        [line addObject:b]; [lineW addObject:@(bw)]; cx+=bw+6;
    }
    CGFloat total=0;
    for(NSUInteger i=0;i<lines.count;i++) {
        CGFloat lh=0; for(NSButton *b in lines[i]) lh=MAX(lh,[b.identifier hasPrefix:@"npMeta."]?22.0:24.0);
        if(i>0) total+=6;
        total+=lh;
    }
    CGFloat top=total;
    for(NSUInteger i=0;i<lines.count;i++) {
        NSMutableArray<NSButton *> *ln=lines[i]; NSMutableArray<NSNumber *> *lw=widths[i];
        CGFloat lh=0; for(NSButton *b in ln) lh=MAX(lh,[b.identifier hasPrefix:@"npMeta."]?22.0:24.0);
        top-=lh; CGFloat x=0;
        for(NSUInteger j=0;j<ln.count;j++) {
            NSButton *b=ln[j]; const CGFloat bh=[b.identifier hasPrefix:@"npMeta."]?22.0:24.0; const CGFloat bw=lw[j].doubleValue;
            b.frame=NSMakeRect(x,top+(lh-bh)/2,bw,bh); x+=bw+6;
        }
        if(i+1<lines.count) top-=6;
    }
    return total;
}

- (void)layoutWebPlayback {
    CGFloat w=self.webCanvas.bounds.size.width,h=self.webCanvas.bounds.size.height;
    // U2 包3：波形条占控制条上方 50pt + 上下各 8pt 间距；三栏底边要让开，不能压到波形上。
    const CGFloat waveformH=50.0, waveformGap=8.0, waveformBodyGap=8.0;
    CGFloat c=MIN(236,MAX(132,h*.24)), gutter=16, top=44, by=top+c+18,
            bottom=MAX(by+60,h-76-waveformGap-waveformH-waveformBodyGap);
    self.cover.frame=NSMakeRect(gutter,top,c,c);
    {
        // 两个小按钮排在封面图正下方；封面窄于 150 时按钮可能溢出到信息列，故限宽并右对齐到封面右缘。
        [self.coverSetBtn sizeToFit];[self.coverResetBtn sizeToFit];
        const CGFloat bw1=self.coverSetBtn.frame.size.width,bw2=self.coverResetBtn.frame.size.width;
        const CGFloat gap=6, total=bw1+gap+bw2;
        const CGFloat bx=gutter+c-total<gutter?gutter:gutter+c-total;
        self.coverSetBtn.frame=NSMakeRect(bx,top+c+8,bw1,20);
        self.coverResetBtn.frame=NSMakeRect(bx+bw1+gap,top+c+8,bw2,20);
        // web `#npResetCover` 仅在 `curMeta.coverSource === 'track_manual'` 时显示。
        // 本仓 /api/meta 还没有 coverSource 字段（见 evidence 挂账），故始终可见：
        // 无手动封面时点「自动」只会写 reset 标记，读侧本来就走自动链 ⟹ 语义无害。
        self.coverSetBtn.enabled=self.currentPath.length>0;
        self.coverResetBtn.enabled=self.currentPath.length>0;
    }
    CGFloat x=gutter+c+26, infoY=top+MAX(0,(c-130)/2), iw=MAX(80,w-x-24);
    // web `#npTitle{font-size:clamp(19px,2.6vh,27px);line-height:1.3}`：
    // 字号/行盒按视口高度换算（旧码固定 20pt/30pt 行，大窗偏小、小窗字距挤）。
    const CGFloat titleSize=RLPNPTitlePointSize(h);
    const CGFloat titleH=ceil(titleSize*1.3);
    self.titleLabel2.font=[NSFont systemFontOfSize:titleSize weight:NSFontWeightBold];
    self.kindLabel.frame=NSMakeRect(x,infoY,iw,16);self.titleLabel2.frame=NSMakeRect(x,infoY+25,MAX(50,MIN(iw-42,620)),titleH);
    [self.titleLabel2 sizeToFit];self.titleLabel2.frame=NSMakeRect(x,infoY+25,MIN(MAX(100,self.titleLabel2.frame.size.width),iw-44),titleH);
    self.favoriteButton.frame=NSMakeRect(NSMaxX(self.titleLabel2.frame)+8,infoY+25+MAX(0,(titleH-30)/2),28,30);
    // web `.npsub{margin-top:8}` ⟹ 副标题顶 = 标题行底 + 8；`#npNextTrackHero{margin-top:4}`。
    const CGFloat subY=infoY+25+titleH+8;
    self.artistLabel2.frame=NSMakeRect(x,subY,iw,21);self.metaLabel.frame=NSMakeRect(x,subY+21+4,iw,18);
    // web `.npmline` 是副标题之后的独立一行：margin-top:10 ⟹ 行顶 = 副标题行底 + 10。
    // 行高由 flex-wrap 的实际行数算出，旧的按钮行（隐藏的对比/作品入口）顺势下移，不再固定 infoY+113。
    {
        // web `#npNextTrackHero{margin-top:4;font-size:12}`：可见时多一行（12pt 行 ≈18pt），`.npmline` 随之下移。
        const CGFloat metaTop=subY+21+10+(self.nextTrackVisible?22.0:0);
        const CGFloat metaH=[self layoutMetaChipsInWidth:iw];
        self.metaChipsRow.frame=NSMakeRect(x,metaTop,iw,MAX(22,metaH));
        const CGFloat btnY=NSMaxY(self.metaChipsRow.frame)+6;
        CGFloat bx=x;
        for(NSButton *b in @[self.compareBtn,self.worksBtn]) {
            CGFloat bw=b==self.worksBtn?100:94;
            b.frame=NSMakeRect(bx,btnY,bw,24); bx+=bw+6;
        }
    }
    self.closeButton.frame=NSMakeRect(w-56,16,38,38);self.railToggle.frame=NSMakeRect(w-100,18,34,34);self.analysisToggle.frame=NSMakeRect(w-142,18,34,34);
    CGFloat col=(w-2*gutter-36)/4, side=MIN(340,col), bodyH=MAX(60,bottom-by);
    self.analysisPanel.frame=NSMakeRect(gutter,by,side,bodyH);self.railPanel.frame=NSMakeRect(w-gutter-side,by,side,bodyH);
        self.lyricScroll.frame=NSMakeRect(gutter+col+18,by,col*2,bodyH);
        if(self.analysisPanel.hidden&&self.railPanel.hidden)self.lyricScroll.frame=NSMakeRect(gutter,by,w-32,bodyH);
        [self updateLyricFadeMask];   // 视口高度变了要重算 26pt 渐隐位置
    // ---- 音频分析面板：web #npAnal（padding:8px 11px 9px、.anlhead gap:8、面板 gap:6）----
    {
        // web `#npAnal{padding:8px 11px 9px}` + 1px border ⟹ 内容左缘距面板外缘 12pt。
        // 原生面板无边框，直接把 12 当内边距，左缘/状态右缘/卡片宽同时回到 web 真值
        // （1.1.7.57 之前是 11，把 1pt 差烘进了判据期望，见 evidence/native-anl-gutter-20261114.md）。
        const CGFloat anlPadX = 12.0, anlPadTop = 8.0, anlPadBottom = 9.0;
        const CGFloat anlLabelH = 13.0, anlSegH = 21.0, anlHeadGap = 8.0, anlBodyGap = 6.0;
        NSFont *labFont = self.anlLab.font;
        // 必须量 attributedStringValue：kern 1.5 会把 4 个字的显示宽度再撑宽 ~4.5pt，
        // 用 stringValue+font 量会窄 4.5pt ⟹ 标题「音频分析」被截成「音频…」。
        const CGFloat labW = ceil(self.anlLab.attributedStringValue.length
                                  ? self.anlLab.attributedStringValue.size.width
                                  : [self.anlLab.stringValue sizeWithAttributes:
                                     @{ NSFontAttributeName: labFont }].width) + 4.0;  // NSTextField 左右各 2pt 内缩
        const CGFloat headY = bodyH - anlPadTop - anlLabelH;
        self.anlLab.frame = NSMakeRect(anlPadX, headY, MIN(MAX(20, labW), MAX(20, side - anlPadX * 2)), anlLabelH);
        // 状态贴右：面板右缘 → 13pt（web 面板内边距 11 + #npAnlStat 右内边距 2）
        {
            // web .anlheadtop{padding-right:26px}：状态文字给右上角的收起键让出 26pt。
            const CGFloat statRight = side - (anlPadX + 26);
            const CGFloat statAvail = MAX(20, statRight - (anlPadX + labW + 8));
            const CGFloat statW = MIN(statAvail, ceil([self.analysisStatus.stringValue sizeWithAttributes:
                                                      @{ NSFontAttributeName: self.analysisStatus.font }].width) + 4.0);
            self.analysisStatus.frame = NSMakeRect(statRight - statW, headY, statW, anlLabelH);
        }
        const CGFloat segTop = anlPadTop + anlLabelH + anlHeadGap;
        const CGFloat segY = bodyH - segTop - anlSegH;
        [self anlLayoutSegmentAtY:segY right:side - anlPadX];
        const CGFloat cardsTop = segTop + anlSegH + anlBodyGap;
        const CGFloat cardsH = MAX(1, bodyH - cardsTop - anlPadBottom);
        // web `#npAnlBody{margin-right:-11px}`：盒子撑进面板右内边距，右缘到面板右缘；
        // 卡片宽度再扣右侧沟槽（13pt 留白 + 12pt 拇指条），所以滚轮/溢出都不改变卡宽。
        const CGFloat cardsW = MAX(20, side - anlPadX);
        self.anlBody.frame = NSMakeRect(anlPadX, anlPadBottom, cardsW, cardsH);
        self.anlDetailScroll.frame = self.anlBody.frame;
        self.anlReanalyze.frame = NSMakeRect(anlPadX, segY, 62, anlSegH);
        // 窄面板放不下「重新分析」时让它让位（「分析」分段本来就是同一动作）。
        if (NSMinX(self.anlSeg.frame) < NSMaxX(self.anlReanalyze.frame) + 8) self.anlReanalyze.hidden = YES;
        // web `.anlhide{top:7;right:8}` 相对 padding box，`#npAnal` 另有 1px 边框 ⟹
        // 从面板外缘量右距 9pt（ego 实测 right=9）。1.1.7.57 起 anlPadX 已取 12（=11+1），
        // 这里把收起键从 8 同步归位到 9，与状态文字右缘 38 的 1pt 差一并消除。
        // web `.anlhide{position:absolute;top:7px;right:8px}` 的定位框是 **padding box**（不含边框），
        // 而 `#npAnal` 有 border:1px ⟹ 距面板**外缘**应为 右 9 / 顶 8；旧码顶部写 7（少算边框那 1pt）。
        self.anlHide.frame = NSMakeRect(side - 9.0 - 22.0, bodyH - 8.0 - 22.0, 22.0, 22.0);
        [self anlLayoutCards];
    }
    // ---- AI 整理栏几何（web .nprailcard padding:10 / gap:8，.npchipwrap gap:6）----
    const CGFloat railSegH=24;
    self.railTitle.frame=NSMakeRect(kRailHeadPadX,bodyH-kRailHeadPadTop-13,72,13);
    // 栏头右侧：简略/详细分段 + 收起键（web .nprailhide 与分段同处栏头一行）。
    self.railDensity.frame=NSMakeRect(MAX(80,side-kRailHeadPadX-116-30),bodyH-kRailHeadPadTop-railSegH,116,railSegH);
    // web `.nprailhead` 是 `.nprailcard`（padding:10 + border:1，border-box）里的一行 flex，
    // `.nprailhide` 是 flex:none 的最后一个子项 ⟹ 其右缘 = 内容内缘 = 11，不是 8（旧值）。
    // 竖直方向：web `.nprailhead{align-items:center}` ⟹ 22pt 的收起键在 24pt 行里**居中**
    // （顶距 = 内缩 11 + (24-22)/2 = 12），不是与行顶齐平（13）。
    const CGFloat railHideY = bodyH - kRailHeadPadTop - railSegH + (railSegH - 22.0) / 2.0;
    self.railHide.frame=NSMakeRect(side-kRailHeadPadX-22.0,railHideY,22.0,22.0);
    CGFloat ry=bodyH-kRailHeadPadTop-railSegH-kRailHeadGap;   // 栏头底部再空 8
    const CGFloat railCardW=MAX(40,side-kRailHeadPadX*2);
    if (self.railEmptyLabel && !self.railEmptyLabel.hidden) {
        // web .nprailempty：无栏目时卡片不显示，说明文字紧跟栏头（10.5/1.6 行高）。
        NSString *txt = self.railEmptyLabel.stringValue ?: @"";
        NSRect br = [txt boundingRectWithSize:NSMakeSize(railCardW, CGFLOAT_MAX)
                                      options:NSStringDrawingUsesLineFragmentOrigin
                                   attributes:@{ NSFontAttributeName: self.railEmptyLabel.font }
                                      context:nil];
        CGFloat eh = MAX(30.0, ceil(br.size.height) + 8.0);
        self.railEmptyLabel.frame = NSMakeRect(kRailHeadPadX, ry - eh, railCardW, eh);
        ry -= eh;
    }
    // web `.npchipwrap`：栏头之下独立滚动区；卡片滚动时栏头/分段/收起键不动。
    {
        const CGFloat wrapBottom = (self.railHintBtn && !self.railHintBtn.hidden) ? 34.0 : 10.0;
        const CGFloat wrapTop = bodyH - kRailHeadPadTop - railSegH - kRailHeadGap;
        self.railChipWrap.frame = NSMakeRect(kRailHeadPadX, wrapBottom,
                                             MAX(20, side - kRailHeadPadX * 2),
                                             MAX(20, wrapTop - wrapBottom));
        self.railChipWrap.hidden = (self.railEmptyLabel && !self.railEmptyLabel.hidden);
        [self railLayoutChips];
        (void)railCardW; (void)ry;
    }
    if (self.railHintBtn && !self.railHintBtn.hidden) {
        // web .nprailhint 在卡片区之后；原生放在栏底（卡片较少时视觉同区，且不遮卡片）。
        self.railHintBtn.frame = NSMakeRect(kRailHeadPadX, 10, railCardW, 18);
    }
    self.webControls.frame=NSMakeRect(MAX(16,(w-1160)/2),h-76,MIN(1160,w-32),58);[self.webControls layout];
    // U2 包3：波形与控制条同一宽度、贴在其正上方（top-left 坐标：控制条顶 = h-76）。
    self.waveformView.frame=NSMakeRect(NSMinX(self.webControls.frame),
                                       NSMinY(self.webControls.frame)-waveformGap-waveformH,
                                       NSWidth(self.webControls.frame),waveformH);
    [self layoutLyricRows];
    // web #npDrawerBg inset 0 / #npDrawer top/right/bottom 14、width:min(430,44vw)
    {
        const CGFloat dw = MIN(430.0, 0.44 * w);
        self.dataBackdrop.frame = NSMakeRect(0, 0, w, h);
        self.dataDrawer.frame = NSMakeRect(w - 14.0 - dw, 14.0, dw, MAX(60.0, h - 28.0));
        self.knowledge.frame = self.dataDrawer.bounds;
    }
}

/// web `#npDrawer`：`top/right/bottom:14px`、`width:min(430px,44vw)`、radius 18、border `--line2`、
/// `box-shadow:0 28px 80px rgba(0,0,0,.42)`；`#npDrawerBg` 是 rgba(0,0,0,.30) 遮罩，点遮罩关闭。
- (void)openDataDrawer {
    [self layoutWebPlayback];            // 先按当前页面尺寸算出抽屉 frame
    self.dataDrawerOpen=YES;
    self.dataBackdrop.hidden=NO;
    self.dataDrawer.hidden=NO;
    // 透明度过渡（滑入在 web 是 transform .26s；原生直接把 frame 放到终点，避免离屏判据等动画）。
    self.dataDrawer.alphaValue=0;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx){
        ctx.duration=0.18;
        self.dataDrawer.animator.alphaValue=1;
    } completionHandler:nil];
    // web `.npdrawer{transform:translateX(calc(100% + 26px)); transition:transform .26s …}`：
    // frame 始终在终点（离屏判据量确定性 frame），滑入只动 presentation layer 的
    // transform.translation.x；model 值保持 identity，既有几何判据不受动画影响。
    const CGFloat slideFrom = self.dataDrawer.frame.size.width + 26.0;
    CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
    slide.fromValue = @(slideFrom);
    slide.toValue = @0;
    slide.duration = 0.26;
    slide.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.2 :0.8 :0.2 :1.0];
    [self.dataDrawer.layer removeAnimationForKey:@"npDrawerSlide"];
    [self.dataDrawer.layer addAnimation:slide forKey:@"npDrawerSlide"];
    self.dataDrawer.layer.zPosition=6;
    self.dataBackdrop.layer.zPosition=5;
}

- (void)closeDataDrawer {
    if (!self.dataDrawerOpen) return;
    self.dataDrawerOpen=NO;
    self.dataDrawer.hidden=YES;
    self.dataBackdrop.hidden=YES;
    [self.dataDrawer.layer removeAnimationForKey:@"npDrawerSlide"];
    [self.knowledge cancelLoading];
}

/// `.npchipwrap` 卡片排版：卡片宽度 = wrap 宽 - 11（web 实测滚动条占位 11pt），
/// 从顶部往下排、偏移只改卡片 y；栏头等其它子视图坐标完全不动。
/// 按给定卡片宽度排一次版，返回总内容高度（不写 contentHeight）。
- (CGFloat)railLayoutChipsWithWidth:(CGFloat)cardW height:(CGFloat)H {
    RLPRailWrapView *rw = (RLPRailWrapView *)self.railChipWrap;
    NSArray<RLPRailChipView *> *cards = self.railCards ?: @[];
    CGFloat contentH = 0;
    NSUInteger shown = 0;
    for (RLPRailChipView *c in cards) {
        if (c.hidden) continue;
        if (shown > 0) contentH += kRailChipGap;
        contentH += [c preferredHeightForWidth:cardW];
        ++shown;
    }
    rw.contentHeight = contentH;
    CGFloat top = H - rw.contentOffset;
    NSUInteger laid = 0;
    for (RLPRailChipView *c in cards) {
        if (c.hidden) { c.frame = NSZeroRect; continue; }
        if (laid > 0) top -= kRailChipGap;
        CGFloat ch = [c preferredHeightForWidth:cardW];
        c.frame = NSMakeRect(0, top - ch, cardW, ch);
        [c relayout];
        top -= ch;
        ++laid;
    }
    rw.needsDisplay = YES;
    return contentH;
}

/// `.npchipwrap` 卡片排版。
/// ★ 滚动条占位与 web 对齐（2026-11-15 收口已知偏差）：web 实测是「内容溢出才占 11pt」——
///   不溢出时卡片宽度就是 wrap 宽度 W；旧码无条件 W-11，于是短列表也会空出一条 11pt 的槽，
///   与 web 截图差 1pt 级差（这就是偏差台账里那条 chipwrap 宽度差）。
///   因此这里两遍排：先按 W 排一次，若放得下就用 W；放不下才按 W-11 重排（与浏览器同序）。
- (void)railLayoutChips {
    NSView *wrap = self.railChipWrap;
    if (!wrap || wrap.hidden) return;
    const CGFloat W = wrap.bounds.size.width, H = wrap.bounds.size.height;
    if (W < 20 || H < 10) return;
    RLPRailWrapView *rw = (RLPRailWrapView *)wrap;
    NSArray<RLPRailChipView *> *cards = self.railCards ?: @[];
    if (cards.count == 0) { rw.contentHeight = 0; return; }
    const CGFloat wideW = MAX(40, W);
    const CGFloat narrowW = MAX(40, W - 11);
    const CGFloat hWide = [self railLayoutChipsWithWidth:wideW height:H];
    if (hWide <= H + 0.5) return;   // 放得下 ⟹ 不占滚动条，宽度保持 W
    [self railLayoutChipsWithWidth:narrowW height:H];
}
/// web `#npLyric` 空态 / `#lyricbox` 加载态的两行文案：
/// 主行字号跟歌词 clamp（13~17），副行固定 12px + `--mut2`，居中、可换行（`maximumNumberOfLines=0`）。
- (void)setLyricsPlaceholder:(NSString *)main detail:(NSString *)detail {
    const CGFloat size=(self.lyricPointSize>0.01)?self.lyricPointSize
        :RLPNPLyricPointSize(self.webCanvas.bounds.size.height);
    RLPTheme *t=[RLPTheme current];
    NSMutableParagraphStyle *ps=[[NSMutableParagraphStyle alloc] init];
    ps.alignment=NSTextAlignmentCenter;
    ps.lineBreakMode=NSLineBreakByWordWrapping;
    NSMutableAttributedString *as=[[NSMutableAttributedString alloc] initWithString:
        [NSString stringWithFormat:@"%@\n", RLPTr(main ?: @"")]
        attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:size],
                     NSForegroundColorAttributeName:t.mut,
                     NSParagraphStyleAttributeName:ps}];
    if (detail.length)
        [as appendAttributedString:[[NSAttributedString alloc] initWithString:RLPTr(detail)
            attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12],
                         NSForegroundColorAttributeName:t.mut2,
                         NSParagraphStyleAttributeName:ps}]];
    self.lyricsEmpty.attributedStringValue=as;
    self.lyricsEmpty.hidden=NO;
}

/// web 歌词视口的 26pt 上下渐隐遮罩（`mask-image:linear-gradient(180deg,transparent 0,#000 26px,#000 calc(100% - 26px),transparent 100%)`）。
/// 遮罩挂在**滚动视图**上（不是 document）：滚动时渐隐区固定在视口边缘，首/末行不会"硬切"。
- (void)updateLyricFadeMask {
    const CGFloat H = self.lyricScroll.bounds.size.height;
    if (H < 10) return;
    self.lyricScroll.wantsLayer = YES;
    CAGradientLayer *m = (CAGradientLayer *)self.lyricScroll.layer.mask;
    if (![m isKindOfClass:[CAGradientLayer class]]) {
        m = [CAGradientLayer layer];
        m.colors = @[(__bridge id)NSColor.clearColor.CGColor,
                     (__bridge id)NSColor.blackColor.CGColor,
                     (__bridge id)NSColor.blackColor.CGColor,
                     (__bridge id)NSColor.clearColor.CGColor];
        // 非翻转坐标（原点左下）：startPoint 在上、endPoint 在下，locations 从顶部开始数。
        m.startPoint = CGPointMake(0.5, 1.0);
        m.endPoint = CGPointMake(0.5, 0.0);
        self.lyricScroll.layer.mask = m;
    }
    const CGFloat fade = 26.0;
    m.frame = self.lyricScroll.bounds;
    m.locations = @[@0.0, @(MIN(0.5, fade / H)), @(MAX(0.5, 1.0 - fade / H)), @1.0];
}

/// 按当前字号重建每行的字体/颜色（窗口高度变了要跟着换；内容/高亮状态不变）。
- (void)restyleLyricRows {
    const CGFloat size=(self.lyricPointSize>0.01)?self.lyricPointSize
        :RLPNPLyricPointSize(self.webCanvas.bounds.size.height);
    for(NSUInteger i=0;i<self.lyricRows.count;i++){
        const BOOL on=(NSInteger)i==self.lyricActiveIndex;
        NSButton *b=self.lyricRows[i];
        b.font=[NSFont systemFontOfSize:size];
        b.attributedTitle=[[NSAttributedString alloc] initWithString:b.title attributes:@{
            NSFontAttributeName:[NSFont systemFontOfSize:size weight:on?NSFontWeightSemibold:NSFontWeightRegular],
            NSForegroundColorAttributeName:on?[RLPTheme current].text:[RLPTheme current].mut2}];
    }
}
- (void)layoutLyricRows {
    CGFloat w=self.lyricScroll.contentSize.width, h=self.lyricScroll.contentSize.height;
    // web `.npline{clamp(13,1.9vh,17);line-height:2.05}`：字号与行盒都随视口高度变。
    const CGFloat size=RLPNPLyricPointSize(self.webCanvas.bounds.size.height);
    const CGFloat step=RLPNPLyricLineStep(size);
    if(fabs(size-self.lyricPointSize)>0.01){ self.lyricPointSize=size; [self restyleLyricRows]; }
    // web `.npline.on{transform:scale(1.03)}`：缩放是绘制变换，行左右必须预留 ≥1.5% 宽度余量，
    // 否则放大后越过 `#npLyric` 剪裁边界（"放大即裁字"）。旧码只留 6pt，556pt 文档下会溢出约 2pt。
    const CGFloat scaledPad=ceil(MAX(40.0,w-12.0)*0.015)+1.0;
    const CGFloat inset=MAX(6.0,scaledPad);
    CGFloat pad=MAX(26,h/2-step/2),y=pad;
    for(NSButton *b in self.lyricRows){b.frame=NSMakeRect(inset,y,MAX(40,w-inset*2),step);y+=step;}
    self.lyricDocument.frame=NSMakeRect(0,0,w,MAX(h,y+pad));self.lyricsEmpty.frame=NSMakeRect(8,MAX(0,h/2-30),MAX(40,w-16),60);
}
- (void)rebuildLyricRows {
    self.lyricActiveIndex=-1;
    for(NSView *v in [self.lyricRows copy])[v removeFromSuperview];[self.lyricRows removeAllObjects];
    self.lyricsEmpty.hidden=self.lyricLines.count>0;
    if(self.lyricLines.count==0)
        [self setLyricsPlaceholder:@"没有歌词"
                            detail:@"同名 .lrc 文件、内嵌歌词，或播放时自动在线补全（可在设置-元数据补全关闭）"];
    self.lyricPointSize=RLPNPLyricPointSize(self.webCanvas.bounds.size.height);
    for(RLPLyricLine *line in self.lyricLines){
        NSButton *b=[NSButton buttonWithTitle:line.text target:self action:@selector(onLyricLine:)];
        b.tag=self.lyricRows.count;
        b.bordered=NO;
        b.font=[NSFont systemFontOfSize:self.lyricPointSize];
        b.menu=[self lyricAiMenu];
        [self.lyricDocument addSubview:b];
        [self.lyricRows addObject:b];
    }
    [self layoutLyricRows];[self updateLyricPosition:self.webStatus.position];
}
- (void)applyLyricText:(NSString *)text forPath:(NSString *)path {
    if(![path isEqualToString:self.currentPath?:@""])return;
    self.originalLyricLines=nil;
    self.lyricAiApplied=NO;
    self.lyricAiBusy=NO;
    ++self.lyricAiSeq;
    self.lyricLines=[RLPLyrics parse:text];
    [self rebuildLyricRows];
}
- (void)updateLyricPosition:(double)pos {
    NSInteger at=[RLPLyrics activeIndex:self.lyricLines position:pos];self.lyricActiveIndex=at;
    const CGFloat size=(self.lyricPointSize>0.01)?self.lyricPointSize:RLPNPLyricPointSize(self.webCanvas.bounds.size.height);
    for(NSUInteger i=0;i<self.lyricRows.count;i++){
        BOOL on=(NSInteger)i==at;
        NSButton *b=self.lyricRows[i];
        b.font=[NSFont systemFontOfSize:size];
        b.attributedTitle=[[NSAttributedString alloc] initWithString:b.title attributes:@{
            NSFontAttributeName:[NSFont systemFontOfSize:size weight:on?NSFontWeightSemibold:NSFontWeightRegular],
            NSForegroundColorAttributeName:on?[RLPTheme current].text:[RLPTheme current].mut2}];
        // web `.npline.on{transform:scale(1.03)}`：只缩放当前行（视觉放大，不影响行盒/滚动几何）。
        b.wantsLayer=YES;
        b.layer.transform = on ? CATransform3DMakeScale(1.03,1.03,1) : CATransform3DIdentity;
    }
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

#pragma mark - 歌词 AI（翻译 / 音译 / 日语假名 / 简转繁）

- (NSMenu *)lyricAiMenu {
    if (_lyricAiMenu) return _lyricAiMenu;
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"lyrics-ai"];
    m.autoenablesItems = NO;
    m.delegate = self;

    NSMenuItem *tr = [[NSMenuItem alloc] initWithTitle:RLPTr(@"翻译…") action:nil keyEquivalent:@""];
    NSMenu *langs = [[NSMenu alloc] initWithTitle:@"lyrics-ai-lang"];
    NSArray<NSArray<NSString *> *> *pairs = @[
        @[ @"zh", RLPTr(@"中文") ], @[ @"en", RLPTr(@"英文") ],
        @[ @"ja", RLPTr(@"日语") ], @[ @"ko", RLPTr(@"韩语") ],
        @[ @"fr", RLPTr(@"法语") ], @[ @"de", RLPTr(@"德语") ],
        @[ @"ru", RLPTr(@"俄语") ], @[ @"es", RLPTr(@"西班牙语") ],
    ];
    for (NSArray<NSString *> *p in pairs) {
        NSMenuItem *it = [self lyricAiItem:p[1] action:@selector(lyricAiTranslateLang:)];
        it.representedObject = p[0];
        [langs addItem:it];
    }
    tr.submenu = langs;
    [m addItem:tr];

    [m addItem:[self lyricAiItem:RLPTr(@"音译") action:@selector(lyricAiTransliterate:)]];
    [m addItem:[self lyricAiItem:RLPTr(@"日语假名") action:@selector(lyricAiFurigana:)]];
    [m addItem:[self lyricAiItem:RLPTr(@"转繁体") action:@selector(lyricAiTradChinese:)]];

    [m addItem:[NSMenuItem separatorItem]];

    [m addItem:[self lyricAiItem:RLPTr(@"恢复原文") action:@selector(lyricRestoreOriginal:)]];
    [m addItem:[self lyricAiItem:RLPTr(@"复制歌词") action:@selector(lyricCopyAll:)]];

    _lyricAiMenu = m;
    return m;
}

- (NSMenuItem *)lyricAiItem:(NSString *)title action:(SEL)sel {
    NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:(title ?: @"") action:sel keyEquivalent:@""];
    it.target = self;
    return it;
}

- (void)menuWillOpen:(NSMenu *)menu {
    if (menu != _lyricAiMenu) return;
    const BOOL has = self.lyricLines.count > 0;
    for (NSMenuItem *it in menu.itemArray) {
        if (it.isSeparatorItem) continue;
        if (it.action == @selector(lyricRestoreOriginal:)) it.enabled = self.lyricAiApplied;
        else it.enabled = has;
    }
}

- (void)lyricAiTranslateLang:(NSMenuItem *)item {
    NSString *code = [item.representedObject isKindOfClass:[NSString class]] ? (NSString *)item.representedObject : @"zh";
    [self runLyricAiTask:@"translate" lang:code];
}
- (void)lyricAiTransliterate:(id)sender { (void)sender; [self runLyricAiTask:@"translit" lang:nil]; }
- (void)lyricAiFurigana:(id)sender      { (void)sender; [self runLyricAiTask:@"furigana" lang:nil]; }
- (void)lyricAiTradChinese:(id)sender    { (void)sender; [self runLyricAiTask:@"trad" lang:nil]; }

- (void)runLyricAiTask:(NSString *)task lang:(nullable NSString *)lang {
    if (self.lyricAiBusy) return;
    if (![RLPCoreClient shared].started) { RLPToast(RLPTr(@"核心未启动，稍后再试")); return; }
    NSArray<RLPLyricLine *> *base = self.lyricAiApplied ? self.originalLyricLines : self.lyricLines;
    if (!base.count) { RLPToast(RLPTr(@"这首曲目没有歌词")); return; }

    NSMutableArray<NSString *> *texts = [NSMutableArray arrayWithCapacity:base.count];
    for (RLPLyricLine *l in base) [texts addObject:(l.text ?: @"")];
    NSString *body = [RLPLyrics aiRequestBodyTask:task lang:lang sourceLang:nil lines:texts];

    NSString *reqPath = [self.currentPath copy];
    const NSUInteger aiSeq = ++self.lyricAiSeq;
    self.lyricAiBusy = YES;
    RLPToast([task isEqualToString:@"translate"] ? RLPTr(@"正在翻译歌词…") : RLPTr(@"正在处理歌词…"));
    __weak __typeof__(self) w = self;
    [[RLPCoreClient shared] postJSON:@"/api/lyrics/ai" body:body completion:^(NSDictionary * _Nullable j) {
        __typeof__(self) s = w;
        if (!s) return;
        if (aiSeq != s.lyricAiSeq || !reqPath.length || ![s.currentPath isEqualToString:reqPath]) return;
        s.lyricAiBusy = NO;
        NSString *err = nil;
        NSArray<RLPLyricLine *> *applied = [RLPLyrics linesFromAiResponse:j appliedTo:base error:&err];
        if (!applied) {
            RLPToast([RLPTr(@"歌词处理失败") stringByAppendingFormat:@"：%@", (err ?: RLPTr(@"未知错误"))]);
            return;
        }
        if (!s.lyricAiApplied) { s.originalLyricLines = base; s.lyricAiApplied = YES; }
        s.lyricLines = applied;
        [s rebuildLyricRows];
        const BOOL cached = [j[@"fromCache"] respondsToSelector:@selector(boolValue)] && [j[@"fromCache"] boolValue];
        RLPToast(cached ? RLPTr(@"已载入（缓存）") : RLPTr(@"完成"));
    }];
}

- (void)lyricRestoreOriginal:(id)sender {
    (void)sender;
    if (!self.lyricAiApplied || !self.originalLyricLines.count) return;
    self.lyricLines = self.originalLyricLines;
    self.originalLyricLines = nil;
    self.lyricAiApplied = NO;
    [self rebuildLyricRows];
    RLPToast(RLPTr(@"已恢复原文"));
}

- (void)lyricCopyAll:(id)sender {
    (void)sender;
    if (!self.lyricLines.count) return;
    NSMutableArray<NSString *> *rows = [NSMutableArray arrayWithCapacity:self.lyricLines.count];
    for (RLPLyricLine *l in self.lyricLines) [rows addObject:(l.text ?: @"")];
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:[rows componentsJoinedByString:@"\n"] forType:NSPasteboardTypeString];
    RLPToast(RLPTr(@"歌词已复制"));
}
/// web 抽屉的 Esc 关闭（`npDrawerClose`）；没有抽屉时走默认行为。
- (void)cancelOperation:(id)sender {
    // 先关抽屉（web 的 Esc = npDrawerClose）；没有抽屉时保持原有「Esc 关闭播放页」。
    if (self.dataDrawerOpen) { [self closeDataDrawer]; return; }
    [self onClosePlayback:sender];
}

- (void)onClosePlayback:(id)sender {[[NSNotificationCenter defaultCenter] postNotificationName:@"RLPCloseNowPlayingNotification" object:nil];}

/// 2026-11-17（UI 缺口审计已证实）：拖动播放页进度条时**实时预览**目标时间
/// （web 的 pointermove 会更新 #npPos）；旧实现拖动中直接 return，时间显示冻结。
- (void)onSeekPreview:(NSSlider *)s {
    // 2026-11-17（UI 回归评审已证实）：action 改成预览后，键盘/辅助功能调滑杆
    // 只更新标签、不提交（AppKit 不走 mouseDown 的 onCommit）。非拖动路径直接提交。
    if (!((RLPNPSlider *)s).dragging) { [self onCommitSeek:s]; return; }
    const double frac = s.doubleValue;
    const double dur = self.webStatus.duration;
    if (!(dur > 0) || !isfinite(frac)) return;   // 未播放/时长未知时不预览（与 onCommitSeek 同一守卫）
    self.webControls.posLabel.stringValue = RLPFmtDuration(frac * dur);
}

/// 播放页可见时的 Esc：抽屉优先（web 的 modal → drawer → page 层级）。
- (void)onNowPlayingEscape:(NSNotification *)note {
    (void)note;
    [self cancelOperation:nil];
}
- (void)onToggleAnalysis:(id)sender {self.analysisPanel.hidden=!self.analysisPanel.hidden;[[NSUserDefaults standardUserDefaults] setBool:self.analysisPanel.hidden forKey:@"RLPNPAnalysisHidden"];[self layoutWebPlayback];}
- (void)onHideAnalysis:(id)sender {
    self.analysisPanel.hidden=YES;
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"RLPNPAnalysisHidden"];
    [self layoutWebPlayback];
}
- (void)onHideRail:(id)sender {
    self.railPanel.hidden=YES;
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"RLPNPRailHidden"];
    [self layoutWebPlayback];
}
- (void)onToggleRail:(id)sender {self.railPanel.hidden=!self.railPanel.hidden;[[NSUserDefaults standardUserDefaults] setBool:self.railPanel.hidden forKey:@"RLPNPRailHidden"];[self layoutWebPlayback];}
#pragma mark - v3.3.11 逐曲封面

/// POST /api/cover/set?file=<曲目> body = 图片字节（上游同契约）。
/// 生产接缝：判据直接调它，绕过系统文件面板。
- (void)setCoverAtPath:(NSString *)coverPath forTrack:(NSString *)track {
    if (!coverPath.length || !track.length) return;
    NSData *data=[NSData dataWithContentsOfFile:coverPath];
    if (!data.length) { RLPToast(RLPTr(@"图片读取失败")); return; }
    NSString *url=[NSString stringWithFormat:@"/api/cover/set?file=%@", RLPEnc(track)];
    __weak __typeof__(self) ws=self;
    [[RLPCoreClient shared] postData:url body:data contentType:@"image/jpeg"
                          completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) s2=ws; if(!s2) return;
        if (json && [json[@"ok"] boolValue]) {
            RLPToast(RLPTr(@"歌曲封面已设置"));
            if ([s2.currentPath isEqualToString:track]) [s2 loadCoverForPath:track];
        } else {
            NSString *err=[json[@"error"] isKindOfClass:[NSString class]]?json[@"error"]:RLPTr(@"设置失败");
            RLPToast([NSString stringWithFormat:@"%@：%@", RLPTr(@"设置失败"), err]);
        }
    }];
}

/// POST /api/cover/reset?file=<曲目>：写 reset 标记，读侧回落自动封面。
- (void)resetCoverForTrack:(NSString *)track {
    if (!track.length) return;
    NSString *url=[NSString stringWithFormat:@"/api/cover/reset?file=%@", RLPEnc(track)];
    __weak __typeof__(self) ws=self;
    [[RLPCoreClient shared] postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) s2=ws; if(!s2) return;
        if (json && [json[@"ok"] boolValue]) {
            RLPToast(RLPTr(@"已恢复自动封面"));
            if ([s2.currentPath isEqualToString:track]) [s2 loadCoverForPath:track];
        } else {
            NSString *err=[json[@"error"] isKindOfClass:[NSString class]]?json[@"error"]:RLPTr(@"设置失败");
            RLPToast([NSString stringWithFormat:@"%@：%@", RLPTr(@"设置失败"), err]);
        }
    }];
}

- (void)onSetCover:(id)sender {
    (void)sender;
    if (!self.currentPath.length) return;
    NSOpenPanel *p=[NSOpenPanel openPanel];
    p.canChooseFiles=YES;p.canChooseDirectories=NO;p.allowsMultipleSelection=NO;
    p.message=RLPTr(@"选择一张图片作为歌曲封面");
    p.allowedFileTypes=@[ @"jpg", @"jpeg", @"png", @"webp", @"gif" ];
    if ([p runModal]!=NSModalResponseOK || !p.URL) return;
    [self setCoverAtPath:p.URL.path forTrack:self.currentPath];
}

- (void)onResetCover:(id)sender {
    (void)sender;
    if (!self.currentPath.length) return;
    [self resetCoverForTrack:self.currentPath];
}

- (void)onToggleAuto:(id)sender {self.anlAutoEnabled=!self.anlAutoEnabled;self.anlAutoSettingAt=[NSDate timeIntervalSinceReferenceDate];[[RLPCoreClient shared] postJSON:@"/api/settings" body:self.anlAutoEnabled?@"autoanl=1":@"autoanl=0" completion:nil];[self anlPaint];if(self.anlAutoEnabled)[self anlAutoTickForPath:self.currentPath playing:self.webStatus.playing paused:self.webStatus.paused];}
- (void)onPrevious:(id)s {
    (void)s;
    const uint64_t epoch = RLPBeginPlaybackAction();
    [[RLPCoreClient shared] postJSON:@"/api/skip?dir=-1" body:nil completion:^(NSDictionary * _Nullable json) {
        if (epoch != RLPPlaybackActionEpoch()) return;
        RLPHandlePlaybackActionResponse(json, @"播放失败");
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPPlaybackActionCompletedNotification" object:nil];
    }];
}
- (void)onNext:(id)s {
    (void)s;
    const uint64_t epoch = RLPBeginPlaybackAction();
    [[RLPCoreClient shared] postJSON:@"/api/skip?dir=1" body:nil completion:^(NSDictionary * _Nullable json) {
        if (epoch != RLPPlaybackActionEpoch()) return;
        RLPHandlePlaybackActionResponse(json, @"播放失败");
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPPlaybackActionCompletedNotification" object:nil];
    }];
}
- (void)onPause:(id)s {
    // 与底栏/菜单同一条决策（RLPSupport::RLPPlaybackToggle）：播放页以前在「已停止」时
    // 只发 /api/pause?on=0（no-op），与 web playOrPause 的"重播"行为不一致。
    RLPPlaybackToggle(self.webStatus.playing, self.webStatus.paused, self.webStatus.currentPath);
}
- (void)onStop:(id)s {[[RLPCoreClient shared] postJSON:@"/api/stop" body:nil completion:nil];}
- (void)onCycleMode:(id)s {self.playbackMode=(self.playbackMode+1)%4;[[RLPCoreClient shared] postJSON:[NSString stringWithFormat:@"/api/playmode?mode=%ld",(long)self.playbackMode] body:nil completion:nil];[self applyPlayModeUI];}

/// web applyRep(v)：0 顺序 / 1 列表循环 / 2 单曲循环 / 3 随机。
/// 图标**随档位换**（web REP_ICON 四条路径）：只改颜色不改图标是明令禁止的假修；
/// 「1」角标只在 2（单曲循环）显示（web #npRepOne 的 display 开关）。
- (void)applyPlayModeUI {
    NSInteger m = self.playbackMode;
    if (m < 0 || m > 3) m = 0;
    static NSString *const kSymbols[4] = { @"arrow.right", @"repeat", @"repeat.1", @"shuffle" };
    // tooltip 逐字用 web REP_META[].aria（同一份中文进词表，英文界面自动跟随）。
    static NSString *const kTips[4] = {
        @"顺序播放（播到末尾停止）", @"列表循环（播到末尾回到第一首）",
        @"单曲循环（重复当前这首）", @"随机播放（不重复当前曲）"
    };
    NSString *symbol = kSymbols[m];
    self.playModeSymbol = symbol;
    NSImage *img = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:RLPTr(kTips[m])];
    if (self.webControls.repBtn) {
        self.webControls.repBtn.image = img;
        self.webControls.repBtn.imagePosition = NSImageOnly;
        self.webControls.repBtn.title = @"";
        self.webControls.repBtn.toolTip = RLPTr(kTips[m]);
        self.webControls.repBtn.contentTintColor = (m == 0) ? [RLPTheme current].mut : [RLPTheme current].accentText;
    }
    if (self.webControls.repBadge) self.webControls.repBadge.hidden = (m != 2);
}
- (void)onCommitSeek:(id)s {
    if(self.webControls.seek.dragging)return;
    // v3.3.11 doSeek（ui_script.h:6572-6575）逐条移植：
    //   if (!S.playing || !(S.dur > 0) || !Number.isFinite(frac)) return;
    //   var f = Math.max(0, Math.min(0.9999, frac));  api('/api/seek?pos=' + f.toFixed(4));
    // 为什么要这三条守卫：未播放或时长未知时发 /api/seek 只会得到后端拒绝；
    // 而 pos 传 1.0 会让后端精确跳到文件末尾（上游因此把上界钉在 0.9999）。
    RLPPlaybackStatus *st = self.webStatus;
    const double raw = self.webControls.seek.doubleValue;
    if (!st || !st.playing || !(st.duration > 0) || !isfinite(raw)) return;
    const double f = fmin(0.9999, fmax(0.0, raw));
    [[RLPCoreClient shared] postJSON:[NSString stringWithFormat:@"/api/seek?pos=%.4f", f] body:nil completion:nil];
    self.lyricManualUntil = 0;
}
- (void)onCommitVolume:(id)s {if(self.webControls.volume.dragging)return;double db=RLPNPVolPosToDb(self.webControls.volume.doubleValue);self.webControls.volLabel.stringValue=RLPNPVolDbLabel(db);[[RLPCoreClient shared] postJSON:[NSString stringWithFormat:@"/api/volume?db=%.1f",db] body:nil completion:nil];}
- (void)onSaveCurrent:(id)s {
    if(!self.currentPath.length)return;
    // 无窗口时（离屏判据 / 审计）NSPopover 会抛异常：锚点交 nil 让保存弹层跳过，
    // **请求路径照旧**走（与 onRailCard 的离屏守卫同一套纪律；真机上 saveButton 在窗口里，行为不变）。
    RLPShowSaveToPlaylist(self.currentPath,self.saveButton.window?self.saveButton:nil);
}
/// web npBindEqChips：`closeNowPlaying(); openSettingsTab('eq')`。EQ 与 IR 两个芯片都落同一页
/// （IR 也在「EQ 与房间校正」里配置，和 web 完全一致）。
- (void)onEqChip:(id)s {[self openEqRoomCorrection];}
- (void)onIrChip:(id)s {[self openEqRoomCorrection];}
- (void)openEqRoomCorrection {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPCloseNowPlayingNotification" object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenSettingsPaneNotification" object:@"eq"];
}
// Device identity is location (UPnP description URL or airplay://), never display name.
- (NSString *)castBodyForDevice:(NSDictionary *)device {
    NSString *dev=[device[@"location"] isKindOfClass:NSString.class]?device[@"location"]:nil;
    if(!dev.length||!self.currentPath.length)return nil;
    NSMutableCharacterSet *allowed=[[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];[allowed removeCharactersInString:@"&=+?#"];
    NSString *deviceValue=[dev stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    NSString *fileValue=[self.currentPath stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    return [NSString stringWithFormat:@"dev=%@&file=%@&volume=%.1f",deviceValue,fileValue,([self.webControls hasConfirmedVolume] && isfinite([self.webControls confirmedVolumeDb]))
        ? [self.webControls confirmedVolumeDb]
        : ((self.webStatus && isfinite(self.webStatus.volumeDb)) ? self.webStatus.volumeDb : -120.0)];
}
/// 投放芯片的运行态（web npCastBtnHtml：`npcast.on` 绿底 + 「已推送到 <device>」，点击停止）。
/// 后端契约 `/api/cast/state` → {ok, running, device, phase, ...}（RLPCastView 已在读同一接口）。
- (void)startCastStatePoll {
    [self.castPoll invalidate];
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) ws = self;
    self.castPoll = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
        (void)t;
        [ws refreshCastChipState];
    }];
    [self refreshCastChipState];
}

/// web castDevNameOf：优先设备列表里的标签；没有列表时取 URL host，最后回落「设备」。
static NSString *RLPNowPlayingCastDeviceLabel(NSString *device) {
    NSString *loc = device ?: @"";
    if (!loc.length) return RLPTr(@"设备");
    NSRange scheme = [loc rangeOfString:@"://"];
    if (scheme.location != NSNotFound) {
        NSString *rest = [loc substringFromIndex:NSMaxRange(scheme)];
        NSString *hostPart = [rest componentsSeparatedByString:@"/"][0];
        hostPart = [hostPart componentsSeparatedByString:@"?"][0];
        if (hostPart.length) return hostPart;
    }
    NSString *last = loc.lastPathComponent;
    return last.length ? last : loc;
}

- (void)refreshCastChipState {
    if (!self.metaChipsRow) return;
    __weak __typeof__(self) ws = self;
    [[RLPCoreClient shared] getJSON:@"/api/cast/state" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) s = ws;
        if (!s) return;
        const BOOL running = [json[@"running"] respondsToSelector:@selector(boolValue)] &&
                             [json[@"running"] boolValue];
        NSString *device = [json[@"device"] isKindOfClass:[NSString class]] ? json[@"device"] : @"";
        s.castRunningState = running;
        s.castDeviceName = running ? RLPNowPlayingCastDeviceLabel(device) : @"";
        [s applyCastChipStyle];
        [s layoutWebPlayback];
    }];
}

- (void)applyCastChipStyle {
    if (!self.castButton) return;
    RLPTheme *t = [RLPTheme current];
    if (self.castRunningState) {
        NSString *title = [NSString stringWithFormat:@"%@ %@", RLPTr(@"已推送到"), self.castDeviceName ?: RLPTr(@"设备")];
        self.castButton.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName: t.okText,
        }];
        self.castButton.title = title;
        self.castButton.layer.backgroundColor = t.okBg.CGColor;
        self.castButton.layer.borderColor = t.okLine.CGColor;
        self.castButton.contentTintColor = t.okText;
        self.castButton.toolTip = RLPTr(@"点击停止投放并恢复本机输出");
    } else {
        [self styleMetaChip:self.castButton];
        self.castButton.title = RLPTr(@"推送到设备");
        self.castButton.toolTip = RLPTr(@"把当前曲目推送到 UPnP / DLNA 设备");
    }
}

/// 投放「推送」落库（web castPush(file, dev) → /api/cast/start）。
/// 成功**立刻**刷一次芯片（不等 2s 的 /api/cast/state 轮询）：否则用户点完推送后
/// 按钮还是「推送到设备」，要等下一格轮询才变「已推送到 <设备>」（审计 C 项）。
- (void)castStartToDevice:(NSDictionary *)device {
    NSString *body = [self castBodyForDevice:device];
    if (!body.length) return;
    __weak __typeof__(self) ws = self;
    [[RLPCoreClient shared] postJSON:@"/api/cast/start" body:body
                          completion:^(NSDictionary * _Nullable r) {
        __typeof__(self) s = ws;
        if (!s) return;
        if (![r[@"ok"] boolValue]) {
            NSString *err = [r[@"error"] isKindOfClass:[NSString class]]
                ? (NSString *)r[@"error"] : RLPTr(@"投放失败");
            RLPToast(err);
            return;
        }
        NSString *label = [device[@"name"] isKindOfClass:[NSString class]] ? device[@"name"] : nil;
        if (!label.length) {
            NSString *loc = [device[@"location"] isKindOfClass:[NSString class]] ? device[@"location"] : @"";
            label = RLPNowPlayingCastDeviceLabel(loc);
        }
        RLPToast([NSString stringWithFormat:@"%@ %@", RLPTr(@"已推送到"), label]);
        [s refreshCastChipState];   // 芯片立刻变成 on 态（不等轮询）
    }];
}

- (void)onCastCurrent:(id)s {
    if (self.castRunningState) {
        // web castToggle：投放中点按钮 = 停止（不弹设备列表）。
        __weak __typeof__(self) ws = self;
        [[RLPCoreClient shared] postJSON:@"/api/cast/stop" body:@""
                              completion:^(NSDictionary * _Nullable r) {
            __typeof__(self) s = ws;
            if (!s) return;
            if (![r[@"ok"] boolValue] && [r[@"error"] isKindOfClass:[NSString class]])
                RLPToast((NSString *)r[@"error"]);
            else
                RLPToast(RLPTr(@"已停止投放，输出回到本机"));
            [s refreshCastChipState];
        }];
        return;
    }
    if(!self.currentPath.length)return;__weak __typeof__(self) ws=self;
    [[RLPCoreClient shared] getJSON:@"/api/cast/devices" completion:^(NSDictionary *j){__typeof__(self) s=ws;if(!s)return;NSArray *devs=[j[@"devices"] isKindOfClass:NSArray.class]?j[@"devices"]:@[];if(!devs.count){RLPToast(j[@"hint"]?:RLPTr(@"未发现可投放设备"));return;}
        NSAlert *a=[NSAlert new];a.messageText=RLPTr(@"推送当前曲目到设备");NSPopUpButton *p=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,0,320,28)];for(NSDictionary *d in devs)[p addItemWithTitle:d[@"name"]?:@"UPnP"];a.accessoryView=p;[a addButtonWithTitle:RLPTr(@"推送")];[a addButtonWithTitle:RLPTr(@"取消")];if([a runModal]!=NSAlertFirstButtonReturn)return;NSDictionary *d=devs[p.indexOfSelectedItem];[s castStartToDevice:d];}];
}
- (void)onRailDensity:(id)s {
    const BOOL detail = (self.railDensity.selectedSegment == 1);
    if (detail != self.railDetail) {
        self.railDetail = detail;
        // web localStorage('rta-np-raildetail') 的等价持久化；恢复在 init。
        [[NSUserDefaults standardUserDefaults] setBool:detail forKey:@"RLPNPRailDetail"];
        for (RLPRailChipView *c in self.railCards) c.detailMode = detail;
    }
    // 纯展示档位：只重算预览 + 重排，**绝不重建 railStates / 重发 summary**
    // （web npRailDetailSet：只把 tabSig 作废，NP_DATA.cache 引用都不动）。
    [self renderRailMetadata];
    [self layoutWebPlayback];
}

#pragma mark - AI 整理栏数据层（web NP_DATA / SUMC / NPLIB 的原生同构）

- (void)railEnsureContainers {
    if (!self.railStates) self.railStates = [NSMutableDictionary dictionary];
    if (!self.railTargets) self.railTargets = [NSMutableDictionary dictionary];
    if (!self.railSummaryCache) self.railSummaryCache = [NSMutableDictionary dictionary];
    if (!self.railSummaryInflight) self.railSummaryInflight = [NSMutableSet set];
    if (!self.railAlbumCache) self.railAlbumCache = [NSMutableDictionary dictionary];
    if (!self.railAlbumInflight) self.railAlbumInflight = [NSMutableSet set];
}

/// 切歌/离页：世代号前进让所有在飞回调作废；页面级 URL 缓存（railSummaryCache）保留 ——
/// 与 web SUMC 同语义（同一实体跨歌复用，例如同一艺术家的 person）。
- (void)railInvalidateForTrackChange {
    [self railEnsureContainers];
    self.railSeq += 1;
    [self.railStates removeAllObjects];
    [self.railTargets removeAllObjects];
    [self.railSummaryInflight removeAllObjects];
}

/// web npDataCan 的**取数闸门**：meta.summaryEnabled 且（可用/已缓存/可离线缓存/有 key）。
/// 关时零 summary 请求，只留本地事实兜底 —— 不拿"没资料"去冒充"整理过的资料"。
- (BOOL)railSummariesEnabled {
    NSDictionary *m = self.trackMetadata ?: @{};
    id en = m[@"summaryEnabled"];
    if (![en respondsToSelector:@selector(boolValue)] || ![en boolValue]) return NO;
    for (NSString *k in @[@"summaryAvailable", @"summaryCached", @"summaryCacheOk", @"hasLlmKey"]) {
        id v = m[k];
        if ([v respondsToSelector:@selector(boolValue)] && [v boolValue]) return YES;
    }
    return NO;
}

- (NSString *)railFpForKind:(NSString *)kind {
    NSDictionary *t = self.railTargets[kind];
    if (!t) return @"";
    // web npDataFp：kind|name|artist|(composer)|album（work 实体的鉴别键必须含 composer）。
    return [NSString stringWithFormat:@"%@|%@|%@|%@|%@", kind, RLPRailStr(t[@"name"]),
            RLPRailStr(t[@"artist"]), RLPRailStr(t[@"composer"]), RLPRailStr(t[@"album"])];
}

/// web npSummUrl 的逐字形状（参数顺序也一致；encodeURIComponent = RLPEnc）。
/// track 额外 album/file/genre；artist 非空才带；最后固定 lang=zh。
- (NSString *)railUrlForTarget:(NSDictionary *)t {
    NSString *kind = RLPRailStr(t[@"kind"]);
    // web npDataEnsure 的 work 分支：Discogs 版本推荐走独立端点（不是 summary）。
    if ([kind isEqualToString:@"work"]) {
        NSMutableString *wu = [NSMutableString stringWithFormat:
            @"/api/entity/versions?kind=work&name=%@", RLPEnc(RLPRailStr(t[@"name"]))];
        NSString *composer = RLPRailStr(t[@"composer"]);
        if (composer.length) [wu appendFormat:@"&composer=%@", RLPEnc(composer)];
        return wu;
    }
    NSMutableString *u = [NSMutableString stringWithFormat:
        @"/api/entity/summary?kind=%@&name=%@", kind, RLPEnc(RLPRailStr(t[@"name"]))];
    NSString *artist = RLPRailStr(t[@"artist"]);
    if (artist.length) [u appendFormat:@"&artist=%@", RLPEnc(artist)];
    if ([kind isEqualToString:@"track"]) {
        NSString *album = RLPRailStr(t[@"album"]);
        NSString *file = RLPRailStr(t[@"file"]);
        NSString *genre = RLPRailStr(t[@"genre"]);
        if (album.length) [u appendFormat:@"&album=%@", RLPEnc(album)];
        if (file.length) [u appendFormat:@"&file=%@", RLPEnc(file)];
        if (genre.length) [u appendFormat:@"&genre=%@", RLPEnc(genre)];
    }
    [u appendString:@"&lang=zh"];
    return u;
}

- (void)railBeginSummariesForMeta:(NSDictionary *)json {
    [self railEnsureContainers];
    // 新世代：旧世代在飞/迟到的响应全部作废（web npDataReset 的 req 单调递增）。
    self.railSeq += 1;
    [self.railStates removeAllObjects];
    [self.railTargets removeAllObjects];
    [self.railSummaryInflight removeAllObjects];
    NSDictionary *m = json ?: self.trackMetadata ?: @{};
    if (![self railSummariesEnabled]) {
        // 闸门关闭：targets/states 都空 ⟹ renderRailMetadata 只出本地事实。
        [self renderRailMetadata];
        [self layoutWebPlayback];
        return;
    }
    NSString *title = RLPRailStr(m[@"title"]);
    if (!title.length) title = self.titleLabel2.stringValue ?: @"";
    if (!title.length && self.currentPath.length)
        title = self.currentPath.lastPathComponent.stringByDeletingPathExtension;
    NSString *artist = RLPRailStr(m[@"artist"]);
    NSString *album = RLPRailStr(m[@"album"]);
    NSString *albumArtist = RLPRailStr(m[@"albumArtist"]);
    NSString *summaryArtist = RLPRailStr(m[@"summaryArtist"]);
    NSString *genre = RLPRailStr(m[@"genre"]);
    if (title.length) {
        // web npDataTargets：track 的实体键带 album；file/genre 在 npSummUrl 里补。
        self.railTargets[@"track"] = @{ @"kind": @"track", @"name": title,
            @"artist": artist, @"album": album, @"file": self.currentPath ?: @"",
            @"genre": genre };
    }
    // web 只在 album 非空且不等于 title 时出「专辑」卡。
    if (album.length && ![album isEqualToString:title]) {
        NSString *relArtist = summaryArtist.length ? summaryArtist
            : (albumArtist.length ? albumArtist : artist);
        self.railTargets[@"release"] = @{ @"kind": @"release", @"name": album,
            @"artist": relArtist, @"album": @"" };
    }
    NSString *personName = albumArtist.length ? albumArtist : artist;
    if (personName.length) {
        // web 的 person target 不带 artist（npSummUrl 因此没有 &artist=）。
        self.railTargets[@"person"] = @{ @"kind": @"person", @"name": personName,
            @"artist": @"", @"album": @"" };
    }
    // web npDataTargets：「作品」只在古典曲目出现，检索键是「去译名后的曲名 + 猜出的作曲家」。
    if (RLPNPIsClassical(m)) {
        NSDictionary *wt = RLPNPWorkTarget(m);
        NSString *workTitle = RLPRailStr(wt[@"title"]);
        if (workTitle.length) {
            self.railTargets[@"work"] = @{ @"kind": @"work", @"name": workTitle,
                @"artist": @"", @"album": @"", @"composer": RLPRailStr(wt[@"composer"]) };
        }
    }
    for (NSString *kind in @[@"track", @"release", @"person", @"work"]) {
        if (!self.railTargets[kind]) continue;
        NSMutableDictionary *idle = [NSMutableDictionary dictionary];
        idle[@"state"] = @"idle";
        self.railStates[kind] = idle;
    }
    for (NSString *kind in @[@"track", @"release", @"person", @"work"])
        if (self.railTargets[kind]) [self railEnsureKind:kind];
    [self renderRailMetadata];
    [self layoutWebPlayback];
}

/// web npDataEnsure 的 work 分支：`(j && j.ok && (j.performances||[]).length) ? j : null`。
- (BOOL)railHasWorkData:(NSDictionary *)j {
    if (![j[@"ok"] respondsToSelector:@selector(boolValue)] || ![j[@"ok"] boolValue]) return NO;
    NSArray *p = [j[@"performances"] isKindOfClass:[NSArray class]] ? j[@"performances"] : @[];
    return p.count > 0;
}

/// web npDataEnsure：同一实体已有 loading/ok/insufficient 就不重发；
/// 同 URL 命中页面级缓存直接写回；同一指纹在飞时合并（不重复发请求）。
- (void)railEnsureKind:(NSString *)kind {
    NSDictionary *t = self.railTargets[kind];
    if (!t) return;
    NSString *fp = [self railFpForKind:kind];
    NSDictionary *st = self.railStates[kind];
    NSString *state = RLPRailStr(st[@"state"]);
    if ([RLPRailStr(st[@"fp"]) isEqualToString:fp] &&
        ([state isEqualToString:@"loading"] || [state isEqualToString:@"ok"] ||
         [state isEqualToString:@"insufficient"])) return;
    NSString *url = [self railUrlForTarget:t];
    id cached = self.railSummaryCache[url];
    if (cached) {
        // web summaryOnce 缓存命中走异步回调；这里直接写回（同一 runloop 内 UI 立刻有内容），
        // 期间不产生任何请求。
        [self railApplySummary:cached kind:kind fp:fp url:url gen:self.railSeq];
        return;
    }
    if ([self.railSummaryInflight containsObject:fp]) return;
    [self.railSummaryInflight addObject:fp];
    NSMutableDictionary *loading = [NSMutableDictionary dictionary];
    loading[@"state"] = @"loading";
    loading[@"fp"] = fp;
    self.railStates[kind] = loading;
    [self renderRailMetadata];
    [self layoutWebPlayback];
    const NSTimeInterval startedAt = [NSDate timeIntervalSinceReferenceDate];
    [self railFetchSummaryUrl:url kind:kind fp:fp gen:self.railSeq startedAt:startedAt];
}

/// web fetchJsonPendingOnce：pending 按 retryAfterMs（夹 150..2000，默认 400ms）轮询，
/// 120s 墙钟预算；每次回来都复核世代号 + 实体指纹，杜绝切歌后旧实体串台。
- (void)railFetchSummaryUrl:(NSString *)url kind:(NSString *)kind fp:(NSString *)fp
                        gen:(NSUInteger)gen startedAt:(NSTimeInterval)startedAt {
    // 定时器/轮询再次进入前先核世代：切歌后不再为旧实体白发一次请求
    // （web 的 setTimeout 也会再打一次、只靠回调守卫丢弃；这里少花一次）。
    if (gen != self.railSeq) return;
    __weak __typeof__(self) ws = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable j) {
        __typeof__(self) s = ws;
        if (!s || gen != s.railSeq) return;                       // 已切歌/换 meta → 丢弃
        if (![[s railFpForKind:kind] isEqualToString:fp]) return;  // 实体已换 → 丢弃
        if ([j[@"pending"] respondsToSelector:@selector(boolValue)] && [j[@"pending"] boolValue]) {
            const NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
            if (now - startedAt > 120.0) {
                [s.railSummaryInflight removeObject:fp];
                NSMutableDictionary *err = [NSMutableDictionary dictionary];
                err[@"state"] = @"error";
                err[@"error"] = RLPTr(@"资料获取超时");
                err[@"fp"] = fp;
                s.railStates[kind] = err;
                [s renderRailMetadata];
                [s layoutWebPlayback];
                return;
            }
            id ra = j[@"retryAfterMs"];
            double delay = 400;
            if ([ra respondsToSelector:@selector(doubleValue)] &&
                [ra doubleValue] >= 150 && [ra doubleValue] <= 2000)
                delay = [ra doubleValue];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_MSEC)),
                           dispatch_get_main_queue(), ^{
                __typeof__(self) s2 = ws;
                if (!s2) return;
                [s2 railFetchSummaryUrl:url kind:kind fp:fp gen:gen startedAt:startedAt];
            });
            return;
        }
        [s railApplySummary:j kind:kind fp:fp url:url gen:gen];
    }];
}

- (BOOL)railHasSummary:(NSDictionary *)j {
    // web summHas：有结构化 fields，或 ok 且有 sections（旧缓存只有段落）。
    id f = j[@"fields"];
    BOOL hasFields = [f isKindOfClass:[NSDictionary class]] && ((NSDictionary *)f).count > 0;
    id sec = j[@"sections"];
    BOOL hasSections = [j[@"ok"] respondsToSelector:@selector(boolValue)] && [j[@"ok"] boolValue] &&
                       [sec isKindOfClass:[NSArray class]] && ((NSArray *)sec).count > 0;
    return hasFields || hasSections;
}

- (void)railApplySummary:(NSDictionary *)j kind:(NSString *)kind fp:(NSString *)fp
                      url:(NSString *)url gen:(NSUInteger)gen {
    if (![j isKindOfClass:[NSDictionary class]]) j = @{};
    if (gen != self.railSeq) return;
    if (![[self railFpForKind:kind] isEqualToString:fp]) return;
    [self.railSummaryInflight removeObject:fp];
    const BOOL insufficient = [j[@"insufficient"] respondsToSelector:@selector(boolValue)] &&
                              [j[@"insufficient"] boolValue];
    // web summaryOnce：insufficient 是终局结论，不写缓存（避免下次点开复用成自动重试死循环）。
    if (!insufficient) self.railSummaryCache[url] = j;
    NSMutableDictionary *st = [NSMutableDictionary dictionary];
    st[@"fp"] = fp;
    if (insufficient) {
        st[@"state"] = @"insufficient";
        st[@"data"] = j;
    } else if ([kind isEqualToString:@"work"] ? [self railHasWorkData:j] : [self railHasSummary:j]) {
        // web npDataEnsure 的 work 分支成功判据是 `ok && performances.length`（不是 fields/sections）。
        st[@"state"] = @"ok";
        st[@"data"] = [j mutableCopy];
    } else {
        st[@"state"] = @"error";
        st[@"error"] = RLPRailStr(j[@"error"]);
    }
    self.railStates[kind] = st;
    if ([st[@"state"] isEqualToString:@"ok"] && [kind isEqualToString:@"release"])
        [self railLoadAlbumForTarget:self.railTargets[kind] fp:fp gen:gen];
    [self renderRailMetadata];
    [self layoutWebPlayback];
}

/// web npLocalAlbum：/api/lib/albums?q= 找一个同名（优先同艺术家）的专辑，再取详情
/// （曲目数 / 总时长 / 年份）。只为「专辑」卡的本地事实服务，不改变 AI 字段。
- (void)railLoadAlbumForTarget:(NSDictionary *)t fp:(NSString *)fp gen:(NSUInteger)gen {
    NSString *name = RLPRailStr(t[@"name"]);
    if (!name.length) return;
    NSString *artist = RLPRailStr(t[@"artist"]);
    NSString *key = [NSString stringWithFormat:@"%@|%@", name, artist];
    NSDictionary *cached = self.railAlbumCache[key];
    if (cached) {
        [self railAttachAlbum:cached kind:@"release" fp:fp gen:self.railSeq];
        return;
    }
    if ([self.railAlbumInflight containsObject:key]) return;
    [self.railAlbumInflight addObject:key];
    __weak __typeof__(self) ws = self;
    NSString *listUrl = [NSString stringWithFormat:@"/api/lib/albums?q=%@", RLPEnc(name)];
    [[RLPCoreClient shared] getJSON:listUrl completion:^(NSDictionary * _Nullable j) {
        __typeof__(self) s = ws;
        if (!s || gen != s.railSeq) { [s.railAlbumInflight removeObject:key]; return; }
        NSArray *list = [j[@"albums"] isKindOfClass:[NSArray class]] ? j[@"albums"] : @[];
        NSDictionary *hit = nil;
        for (NSDictionary *a in list) {
            if (![a isKindOfClass:[NSDictionary class]]) continue;
            if (![RLPRailStr(a[@"name"]) isEqualToString:name]) continue;
            NSString *ha = RLPRailStr(a[@"artist"]);
            if (!artist.length || !ha.length || [ha isEqualToString:artist]) { hit = a; break; }
        }
        if (!hit) {
            for (NSDictionary *a in list) {
                if (![a isKindOfClass:[NSDictionary class]]) continue;
                if ([RLPRailStr(a[@"name"]) isEqualToString:name]) { hit = a; break; }
            }
        }
        NSString *albumKey = hit ? RLPRailStr(hit[@"k"]) : @"";
        if (!albumKey.length) { [s.railAlbumInflight removeObject:key]; return; }
        NSString *detailUrl = [NSString stringWithFormat:@"/api/lib/album?k=%@", RLPEnc(albumKey)];
        [[RLPCoreClient shared] getJSON:detailUrl completion:^(NSDictionary * _Nullable a) {
            __typeof__(self) s2 = ws;
            if (!s2) return;
            [s2.railAlbumInflight removeObject:key];
            if (gen != s2.railSeq) return;
            if (![a isKindOfClass:[NSDictionary class]] || ![a[@"ok"] boolValue]) return;
            s2.railAlbumCache[key] = a;
            [s2 railAttachAlbum:a kind:@"release" fp:fp gen:gen];
        }];
    }];
}

- (void)railAttachAlbum:(NSDictionary *)album kind:(NSString *)kind fp:(NSString *)fp gen:(NSUInteger)gen {
    if (gen != self.railSeq) return;
    if (![[self railFpForKind:kind] isEqualToString:fp]) return;
    NSDictionary *st = self.railStates[kind];
    if (![RLPRailStr(st[@"state"]) isEqualToString:@"ok"]) return;
    NSDictionary *data = [st[@"data"] isKindOfClass:[NSDictionary class]] ? st[@"data"] : nil;
    if (!data) return;
    NSMutableDictionary *mdata = [data mutableCopy];
    mdata[@"__album"] = album;   // web npDataEnsure 里 `s.__album = alb` 的同义
    NSMutableDictionary *mst = [st mutableCopy];
    mst[@"data"] = mdata;
    self.railStates[kind] = mst;
    [self renderRailMetadata];
    [self layoutWebPlayback];
}

/// web npRailLocalTrack：本地曲目事实只兜底，绝不覆盖 AI 字段。
- (NSDictionary *)railLocalTrackPreview {
    NSDictionary *m = self.trackMetadata ?: @{};
    NSMutableArray *a = [NSMutableArray array];
    NSString *artist = RLPRailStr(m[@"artist"]);
    NSString *album = RLPRailStr(m[@"album"]);
    if (artist.length) [a addObject:artist];
    if (album.length) [a addObject:album];
    NSMutableArray *fmt = [NSMutableArray array];
    NSString *codec = RLPRailStr(m[@"codec"]);
    if (codec.length) [fmt addObject:[codec uppercaseString]];
    NSString *sr = RLPRailSampleRateText(m[@"sampleRate"]);
    if (sr.length) [fmt addObject:sr];
    id bits = m[@"bits"];
    if ([bits respondsToSelector:@selector(integerValue)] && [bits integerValue] > 0)
        [fmt addObject:[NSString stringWithFormat:@"%ldbit", (long)[bits integerValue]]];
    const double dur = self.webStatus.duration;
    if (dur > 0) [fmt addObject:RLPFmtDuration(dur)];
    return @{ @"p1": [a componentsJoinedByString:@" · "],
              @"p2": [fmt componentsJoinedByString:@" · "] };
}

/// web npRailBio：fields['简介'] → sections 首段 → 只留名字；名字已开头则不重复「X：」。
/// 简略档 limit=40（截断补 …）；详细档 limit=0（整段交给 5 行 clamp）。
- (NSString *)railBioFromData:(NSDictionary *)d who:(NSString *)who limit:(NSInteger)limit {
    NSString *v = @"";
    NSDictionary *fields = [d[@"fields"] isKindOfClass:[NSDictionary class]] ? d[@"fields"] : nil;
    if (fields[@"简介"] != nil) v = RLPRailValueText(fields[@"简介"]);
    if (!v.length) {
        NSArray *sections = [d[@"sections"] isKindOfClass:[NSArray class]] ? d[@"sections"] : @[];
        for (NSDictionary *sec in sections) {
            if (![sec isKindOfClass:[NSDictionary class]]) continue;
            NSArray *paras = [sec[@"paragraphs"] isKindOfClass:[NSArray class]] ? sec[@"paragraphs"] : @[];
            for (id p in paras) {
                NSString *t = RLPRailValueText([p isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)p)[@"text"] : nil);
                if (t.length) { v = t; break; }
            }
            if (v.length) break;
        }
    }
    v = RLPRailCollapse(v);
    NSString *who2 = RLPRailCollapse(who);
    if (v.length && who2.length && ![v hasPrefix:who2]) v = [who2 stringByAppendingFormat:@"：%@", v];
    if (v.length) {
        if (limit > 0 && (NSInteger)v.length > limit) v = RLPRailShort(v, limit);
        return v;
    }
    return who2;
}

/// web npRailPreview(kind, st) 的逐分支同构。返回 {p1,p2,st}。
- (NSDictionary *)railPreviewForKind:(NSString *)kind state:(NSDictionary *)st {
    NSDictionary *m = self.trackMetadata ?: @{};
    NSDictionary *d = [st[@"data"] isKindOfClass:[NSDictionary class]] ? st[@"data"] : nil;
    NSDictionary *fields = [d[@"fields"] isKindOfClass:[NSDictionary class]] ? d[@"fields"] : nil;
    const NSString *state = RLPRailStr(st[@"state"]);
    if (!state.length) state = @"idle";
    // 资料不足是终局结论：写清缺什么，p2 留空，不显示本地兜底假装"有资料"。
    if ([state isEqualToString:@"insufficient"]) {
        NSString *msg = RLPRailStr(d[@"error"]);
        if (!msg.length) msg = @"资料不足：缺少艺术家与曲名";
        return @{ @"p1": msg, @"p2": @"", @"st": RLPTr(@"资料不足") };
    }
    const NSInteger pickLimit = self.railDetail ? 4 : 2;
    NSString *p1 = @"", *p2 = @"";
    if ([kind isEqualToString:@"track"]) {
        NSDictionary *loc = [self railLocalTrackPreview];
        p1 = RLPRailPick(fields, @[@"演唱", @"作曲", @"作词", @"编曲"], pickLimit);
        p2 = RLPRailPick(fields, @[@"歌曲风格", @"发行时间", @"所属专辑", @"衍生作品"], pickLimit);
        if (!p1.length) p1 = RLPRailStr(loc[@"p1"]).length ? RLPRailStr(loc[@"p1"]) : RLPRailStr(m[@"title"]);
        if (!p2.length) p2 = RLPRailStr(loc[@"p2"]);
    } else if ([kind isEqualToString:@"release"]) {
        NSDictionary *alb = [d[@"__album"] isKindOfClass:[NSDictionary class]] ? d[@"__album"] : nil;
        NSMutableArray *lp = [NSMutableArray array];
        NSString *relArtist = RLPRailStr(m[@"albumArtist"]);
        if (!relArtist.length) relArtist = RLPRailStr(m[@"artist"]);
        if (relArtist.length) [lp addObject:relArtist];
        if ([alb[@"year"] respondsToSelector:@selector(integerValue)] && [alb[@"year"] integerValue] > 0)
            [lp addObject:[NSString stringWithFormat:@"%ld", (long)[alb[@"year"] integerValue]]];
        NSArray *tracks = [alb[@"tracks"] isKindOfClass:[NSArray class]] ? alb[@"tracks"] : @[];
        if (tracks.count) {
            double total = 0;
            for (NSDictionary *t in tracks)
                if ([t isKindOfClass:[NSDictionary class]] && [t[@"dur"] respondsToSelector:@selector(doubleValue)])
                    total += [t[@"dur"] doubleValue];
            [lp addObject:[NSString stringWithFormat:@"%lu %@", (unsigned long)tracks.count, RLPTr(@"首")]];
            if (total > 0) [lp addObject:RLPFmtDuration(total)];
        } else if (self.webStatus.duration > 0) {
            [lp addObject:RLPFmtDuration(self.webStatus.duration)];
        }
        p1 = [lp componentsJoinedByString:@" · "];
        p2 = RLPRailPick(fields, @[@"出版方", @"专辑类型", @"语种", @"发行时间"], pickLimit);
        if (!p2.length) p2 = RLPRailTagText(alb[@"sr"], alb[@"bits"]);
    } else if ([kind isEqualToString:@"person"]) {
        NSString *who = RLPRailStr(self.railTargets[@"person"][@"name"]);
        if (!who.length) who = RLPRailStr(m[@"albumArtist"]);
        if (!who.length) who = RLPRailStr(m[@"artist"]);
        p1 = [self railBioFromData:d who:who limit:(self.railDetail ? 0 : 40)];
        if (!p1.length) p1 = RLPRailPick(fields, @[@"活跃年代"], pickLimit);
        p2 = RLPRailPick(fields, @[@"风格", @"代表作品"], pickLimit);
        if (!p1.length) p1 = who;
    } else if ([kind isEqualToString:@"work"]) {
        // web：p1 = fields['作曲家','创作年代']，没有就退回猜出的作曲家；p2 = fields['体裁']。
        p1 = RLPRailPick(fields, @[@"作曲家", @"创作年代"], pickLimit);
        if (!p1.length) p1 = RLPRailStr(RLPNPWorkTarget(m)[@"composer"]);
        p2 = RLPRailPick(fields, @[@"体裁"], pickLimit);
    }
    NSString *stText = @"";
    if ([state isEqualToString:@"loading"]) stText = RLPTr(@"整理中…");
    else if ([state isEqualToString:@"error"]) stText = RLPTr(@"暂无资料");
    else if ([state isEqualToString:@"ok"])
        stText = ([d[@"from_cache"] respondsToSelector:@selector(boolValue)] && [d[@"from_cache"] boolValue])
               ? RLPTr(@"已缓存") : RLPTr(@"已整理");
    return @{ @"p1": p1 ?: @"", @"p2": p2 ?: @"", @"st": stText };
}

/// 只重绘卡片，不取数（轮询/主题/切档都会调）。
- (void)renderRailMetadata {
    [self railEnsureContainers];
    NSArray<NSString *> *kinds = @[@"track", @"release", @"person", @"work"];
    NSArray<NSString *> *labels = @[RLPTr(@"歌曲"), RLPTr(@"专辑"), RLPTr(@"艺术家"), RLPTr(@"作品")];
    for (NSUInteger i = 0; i < self.railCards.count && i < kinds.count; ++i) {
        NSString *kind = kinds[i];
        NSDictionary *st = self.railStates[kind] ?: @{ @"state": @"idle" };
        NSDictionary *pv = [self railPreviewForKind:kind state:st];
        [self.railCards[i] setNameText:labels[i]
                               status:RLPRailStr(pv[@"st"])
                                   p1:RLPRailStr(pv[@"p1"])
                                   p2:RLPRailStr(pv[@"p2"])];
    }
    // 栏目有无：web 的 tab 列表 = npDataTargets，卡片逐张对应；「作品」只对古典曲目存在。
    NSDictionary *m = self.trackMetadata ?: @{};
    NSString *title = RLPRailStr(m[@"title"]);
    NSString *album = RLPRailStr(m[@"album"]);
    NSString *who = RLPRailStr(m[@"albumArtist"]);
    if (!who.length) who = RLPRailStr(m[@"artist"]);
    const BOOL hasCards = (title.length || album.length || who.length);
    for (NSUInteger i = 0; i < self.railCards.count; ++i) {
        NSString *kind = (i < kinds.count) ? kinds[i] : @"";
        BOOL visible = NO;
        if ([kind isEqualToString:@"work"]) visible = (self.railTargets[@"work"] != nil);
        else if (hasCards) visible = YES;   // 三张基础卡按 meta 兜底（与既有行为一致）
        self.railCards[i].hidden = !visible;
    }
    if (self.railEmptyLabel) self.railEmptyLabel.hidden = hasCards;

    // 歌曲资料状态行（web npRailHint）：只认当前实体且只在三种状态下出现。
    NSDictionary *tst = self.railStates[@"track"] ?: @{};
    NSString *tstate = RLPRailStr(tst[@"state"]);
    NSString *hint = nil;
    NSColor *hintColor = [RLPTheme current].mut2;
    if ([tstate isEqualToString:@"insufficient"]) {
        hint = RLPTr(@"资料不足：缺少艺术家与曲名");
        hintColor = [RLPTheme current].warn ?: [RLPTheme current].mut2;
    } else if ([tstate isEqualToString:@"error"]) {
        hint = RLPTr(@"歌曲资料未能取到 · 点击重试");
        hintColor = [RLPTheme current].warn ?: [RLPTheme current].mut2;
    } else if ([tstate isEqualToString:@"loading"]) {
        hint = RLPTr(@"正在后台整理歌曲资料…");
    }
    if (self.railHintBtn) {
        self.railHintBtn.hidden = (hint == nil);
        if (hint) {
            NSMutableParagraphStyle *ps=[[NSMutableParagraphStyle alloc] init];
            ps.lineBreakMode=NSLineBreakByWordWrapping;
            self.railHintBtn.attributedTitle=[[NSAttributedString alloc] initWithString:hint attributes:@{
                NSFontAttributeName:[NSFont systemFontOfSize:10.5],
                NSForegroundColorAttributeName:hintColor,
                NSParagraphStyleAttributeName:ps}];
            self.railHintBtn.toolTip = [tstate isEqualToString:@"error"] ? RLPTr(@"重新请求这首歌的 AI 整理") : nil;
        }
    }
}

/// web npSummRetry：失败后点状态行 = 强制重新请求这首歌的 summary（refresh 语义）。
- (void)onRailHintRetry:(id)sender {
    (void)sender;
    NSDictionary *t = self.railTargets[@"track"];
    if (!t) return;
    NSString *url = [self railUrlForTarget:t];
    if (url.length) [self.railSummaryCache removeObjectForKey:url];
    NSMutableDictionary *idle = [NSMutableDictionary dictionary];
    idle[@"state"] = @"idle";
    self.railStates[@"track"] = idle;
    [self renderRailMetadata];
    [self layoutWebPlayback];
    [self railEnsureKind:@"track"];
}

- (void)onRailCard:(RLPRailChipView *)b {
    NSArray<NSString *> *kinds = @[@"track", @"release", @"person", @"work"];
    NSInteger idx = b.chipIndex;
    if (idx < 0 || idx >= (NSInteger)kinds.count) return;
    NSString *kind = kinds[(NSUInteger)idx];
    NSDictionary *t = self.railTargets[kind];
    NSString *name = RLPRailStr(t[@"name"]);
    if ([kind isEqualToString:@"work"]) {
        // web npDataActivate('work')：作品实体没有 summary，抽屉正文走 /api/entity/versions。
        NSString *composer = RLPRailStr(t[@"composer"]);
        if (!name.length) {
            NSDictionary *wt = RLPNPWorkTarget(self.trackMetadata ?: @{});
            name = RLPRailStr(wt[@"title"]);
            if (!composer.length) composer = RLPRailStr(wt[@"composer"]);
        }
        if (!name.length) return;
        [self.knowledge loadWorkName:name composer:composer];
        [self.knowledgePopover close];
        [self closeDataDrawer];
        [self openDataDrawer];
        return;
    }
    if (!name.length) {
        // 没取 summary 的路径（闸门关 / meta 未回）也要能点开：名字取原生既有字段。
        NSDictionary *m = self.trackMetadata ?: @{};
        if (idx == 0) name = RLPRailStr(m[@"title"]);
        else if (idx == 1) name = RLPRailStr(m[@"album"]);
        else { name = RLPRailStr(m[@"albumArtist"]); if (!name.length) name = RLPRailStr(m[@"artist"]); }
    }
    if (!name.length) return;
    NSString *artist = RLPRailStr(t[@"artist"]);
    if (idx == 2) artist = @"";   // 艺术家实体不需要 track 的 artist 参数
    [self.knowledge loadKind:kind name:name artist:artist.length ? artist : nil];
    [self.knowledgePopover close];[self closeDataDrawer];
    // web #npDrawer：页内浮卡（不是系统弹窗，也不再需要窗口才可打开）。
    [self openDataDrawer];
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

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self];[self.poll invalidate];[self.castPoll invalidate];[self.lyricRetryTimer invalidate]; }

- (void)activate {
    [self startPolling];
    // 模式（循环/随机）是**全局**状态：页面重新打开时必须重读一次。
    // refresh 只在「换曲」分支里拉 /api/queue，所以「关掉正在播放页 → 在别处改成单曲循环
    // → 再打开」以前显示的还是旧档位（审计 C 项）。首次进入（还没有 currentPath）由
    // refresh 的换曲分支负责，这里不重复发请求。
    if(self.currentPath.length)[self refreshPlayMode];
    // 重新进入页面：同曲已有包络时不重复请求（loadWaveformForPath 内部幂等）。
    if(self.currentPath.length)[self loadWaveformForPath:self.currentPath];
    if(self.polling&&self.currentPath.length)[self loadLyricsForPath:self.currentPath];
}

- (void)viewDidDisappear {
    [self.knowledge cancelLoading];
    [super viewDidDisappear];
    [self stopPolling];self.lyricSeq++;self.railSeq++;[self.railSummaryInflight removeAllObjects];[self.knowledgePopover close];
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
    // 页面进入「live」态：投放/加歌单芯片此时才有可操作对象（web 靠启动即读的 CAST.state）。
    [self applyMetaChipVisibility];
    [self startCastStatePoll];
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
    [self.castPoll invalidate];
    self.castPoll = nil;
    self.polling = NO;
    [self applyMetaChipVisibility];   // 芯片可见性跟着 live 态重算（行高随之收缩）
}

- (void)refresh {
    if(self.statusInFlight)return;self.statusInFlight=YES;const NSUInteger epoch=self.statusEpoch;const uint64_t actionEpoch=RLPPlaybackActionEpoch();
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/status" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (epoch==self_.statusEpoch) self_.statusInFlight=NO;
        if (epoch!=self_.statusEpoch || actionEpoch!=RLPPlaybackActionEpoch()) return;
        RLPPlaybackStatus *st = [RLPPlaybackStatus statusFromJSON:json];
        if (!st) return;
        NSString *path = st.currentPath ?: @"";
        self_.webStatus=st;
        // 既有 0.4 s 的 /api/status 轮询只把播放头搬过去：波形只在切曲时取，这里绝不重发 /api/waveform。
        [self_ updateWaveformPlayheadForStatus:st];
        self_.webControls.posLabel.stringValue=RLPFmtDuration(st.position);self_.webControls.durLabel.stringValue=RLPFmtDuration(st.duration);
        if(!self_.webControls.seek.dragging)self_.webControls.seek.doubleValue=st.duration>0?st.position/st.duration:0;
        const BOOL rawLocked = ([json[@"rawVolumeLocked"] respondsToSelector:@selector(boolValue)] && [json[@"rawVolumeLocked"] boolValue]) ||
                               ([json[@"volumeWritable"] respondsToSelector:@selector(boolValue)] && ![json[@"volumeWritable"] boolValue]);
        [self_.webControls applyVolumeLockedState:rawLocked];
        if (rawLocked) {
            self_.webControls.volumeWritePending = NO;
            ++self_.webControls.volumeWriteSeq;
            self_.webControls.confirmedVolumeDb = 0.0;
            self_.webControls.hasConfirmedVolume = YES;
            [self_.webControls updateVolumeUiForDb:0.0];
        } else if (!self_.webControls.volKnob.dragging && !self_.webControls.volume.dragging && !self_.webControls.volumeWritePending && isfinite(st.volumeDb)) {
            const double clamped = RLPVolClampDb(st.volumeDb);
            self_.webControls.confirmedVolumeDb = clamped;
            self_.webControls.hasConfirmedVolume = YES;
            [self_.webControls updateVolumeUiForDb:clamped];
        }
        self_.webControls.playBtn.image=[NSImage imageWithSystemSymbolName:st.playing&&!st.paused?@"pause.fill":@"play.fill" accessibilityDescription:@"播放 / 暂停"];
        self_.webControls.playBtn.contentTintColor=NSColor.whiteColor;
        [self_ updateLyricPosition:st.position];
        if(!self_.trackMetadata.count || ![path isEqualToString:self_.currentPath?:@""])self_.titleLabel2.stringValue=path.length?path.lastPathComponent.stringByDeletingPathExtension:RLPTr(@"未播放");
        // web 整页**不把后端 error 写进副标题**（那会把艺术家信息顶掉，变成"艺术家=解码失败"）。
        // 原生保留可见反馈：走全局去重 toast（与底栏/同步播放动作共用同一状态）。
        self_.lastStatusError = st.error;
        RLPReportPlaybackStatusErrorForTrack(st.error, st.currentPath);
        if (![path isEqualToString:self_.currentPath ?: @""]) {
            BOOL cancelPrevious=self_.anlBusy;
            self_.currentPath = path;self_.trackMetadata=@{};self_.artistLabel2.stringValue=@"";self_.metaLabel.stringValue=@"";
            self_.nextTrackVisible=NO;self_.metaLabel.hidden=YES;   // 换歌先清「下一首」，不等新队列返回
            [self_ refreshQueueContext];[self_ refreshFavorite];
            // 切曲/停止先把「正在播放 · CODEC / kHz / bit」复位成纯「正在播放」：
            // web renderNp 每帧都用 curMeta 重算（curMeta 清空 ⟹ 只剩「正在播放」）；
            // 旧码只在 /api/meta 回来时覆盖 ⟹ 停止后仍挂着上一首的格式串（用户可见的假信息）。
            if (!self_.kindLabel.attributedStringValue.length || ![self_.kindLabel.attributedStringValue.string isEqualToString:RLPTr(@"正在播放")])
                RLPSetKernedText(self_.kindLabel, RLPTr(@"正在播放"), 1.6);
            // 切歌：旧世代在飞的 summary 必须作废（迟到响应不能贴到新曲/新专辑的卡上）。
            [self_ railInvalidateForTrackChange];
            [self_ loadLyricsForPath:path];
            [self_ loadCoverForPath:path];
            [self_ loadMetaAndKnowledgeForPath:path];
            // U2 包3：切曲/首次进入取一次波形（GET /api/waveform?file=…&bins=512）。
            [self_ loadWaveformForPath:path];
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

#pragma mark - U2 包3：波形（/api/waveform 取数 + /api/status 搬播放头 + 点击 seek）

/// 取一次波形（**只在切曲/首次进入时调**）。同曲已有包络就直接返回：
/// 400 ms 的 /api/status 轮询只走 updateWaveformPlayheadForStatus，绝不重算波形。
/// 失败/不支持（网络曲目、非 WAV/DSF/DFF、超限）只留中心基线，不摆假包络。
- (void)loadWaveformForPath:(NSString *)path {
    if (!self.waveformView) return;
    if (!path.length || [path hasPrefix:@"http://"] || [path hasPrefix:@"https://"]) {
        self.waveformSeq++;                 // 在途响应作废
        self.waveformPath = nil;
        self.waveformSelection = nil;
        [self.waveformView clearWaveform];
        return;
    }
    if ([path isEqualToString:self.waveformPath ?: @""] && self.waveformView.peaks.count) return;
    const NSUInteger seq = ++self.waveformSeq;
    self.waveformPath = path;
    self.waveformSelection = nil;
    [self.waveformView clearWaveform];       // 旧曲包络不能留在新曲上（新数据回来前只画基线）
    NSString *url = [NSString stringWithFormat:@"/api/waveform?file=%@&bins=512", RLPEnc(path)];
    __weak __typeof__(self) ws = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) s = ws;
        if (!s || seq != s.waveformSeq || ![path isEqualToString:s.waveformPath ?: @""]) return;
        NSArray *peaks = [json[@"peaks"] isKindOfClass:[NSArray class]] ? json[@"peaks"] : nil;
        if (!peaks.count) return;            // 解码失败/超限：保持空态，同一首不再打后端
        NSArray *rms = [json[@"rms"] isKindOfClass:[NSArray class]] ? json[@"rms"] : nil;
        [s.waveformView setPeaks:peaks rms:rms duration:[json[@"duration"] doubleValue]];
    }];
}

/// /api/status 每轮调一次：只改播放头浮点值并重绘（不重算波形、不发请求）。
- (void)updateWaveformPlayheadForStatus:(RLPPlaybackStatus *)status {
    if (!self.waveformView || !status) return;
    const double duration = status.duration;
    const double fraction = duration > 0.0 ? status.position / duration : 0.0;
    self.waveformView.playheadFraction = fraction;   // setter 自己 clamp 到 [0,1]
}

/// 波形点击 → 跳转。守卫与 onCommitSeek 完全同口径（web doSeek：playing / dur>0 / finite），
/// pos 上界 0.9999、四位小数。
- (void)seekFromWaveformAtFraction:(double)fraction {
    RLPPlaybackStatus *st = self.webStatus;
    if (!st || !st.playing || !(st.duration > 0.0) || !isfinite(fraction)) return;
    const double f = fmin(0.9999, fmax(0.0, fraction));
    [[RLPCoreClient shared] postJSON:[NSString stringWithFormat:@"/api/seek?pos=%.4f", f]
                                body:nil completion:nil];
    self.lyricManualUntil = 0;
}

/// settings.autoanl / settings.eq / settings.ir 的**同一份**读取节流：
/// 它不是热路径（用户在设置页偶尔改一次），但读一次就永久缓存会让"刚勾上却要等到切歌才生效"。
/// 10 s 一次足够，且绝不进 0.8 s 的忙碌路径（EQ/IR 芯片复用这一次响应，不另开轮询）。
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
        // web loadSettings：`if (kv.eq !== undefined) ADV.eq = kv.eq;` 同理 ir。
        // 芯片读的就是这两个值，所以必须在这一刻更新（否则要等到用户进设置页才显示）。
        s.eqPath=[kv[@"eq"] isKindOfClass:[NSString class]]?(NSString *)kv[@"eq"]:@"";
        s.irPath=[kv[@"ir"] isKindOfClass:[NSString class]]?(NSString *)kv[@"ir"]:@"";
        [s applyMetaChipVisibility];
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
    self.originalLyricLines=nil;
    self.lyricAiApplied=NO;
    self.lyricAiBusy=NO;
    ++self.lyricAiSeq;
    if(!path.length||[path hasPrefix:@"http://"]||[path hasPrefix:@"https://"]){
        [self applyLyricText:@"" forPath:path];
        // web `renderNpLyric()` 对"无歌词"只有一种两行空态（网络曲目也一样）；右侧抽屉才另有
        // 「网络曲目暂无歌词」。旧码把抽屉文案搬到整页，属于超集/错位。
        [self setLyricsPlaceholder:@"没有歌词"
                            detail:@"同名 .lrc 文件、内嵌歌词，或播放时自动在线补全（可在设置-元数据补全关闭）"];
        return;
    }
    self.lyricRetry=0;[self fetchLyricPath:path sequence:seq];
}
- (void)fetchLyricPath:(NSString *)path sequence:(NSUInteger)seq {
    __weak __typeof__(self) ws=self;
    [[RLPCoreClient shared] getJSON:[@"/api/lyrics?file=" stringByAppendingString:RLPEnc(path)] completion:^(NSDictionary *j){__typeof__(self) s=ws;if(!s||seq!=s.lyricSeq||![s.currentPath isEqual:path])return;
        NSString *lrc=[j[@"lrc"] isKindOfClass:NSString.class]?j[@"lrc"]:@"";[s applyLyricText:lrc forPath:path];
        if(!j){s.lyricsEmpty.stringValue=RLPTr(@"歌词加载失败");return;}
        const NSInteger waits[]={1,2,3,5,8,13};
        if(!s.lyricLines.count&&s.lyricRetry<6){
            [s setLyricsPlaceholder:@"歌词加载中…"
                             detail:@"正在等后台补全（首次播放新曲目时可能要几秒）"];
            NSInteger delay=waits[s.lyricRetry++];s.lyricRetryTimer=[NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer *t){__typeof__(self) n=ws;if(n&&seq==n.lyricSeq&&n.polling)[n fetchLyricPath:path sequence:seq];}];}
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
/// v3.3.11 coverSource 闸门：只有手动封面当前生效时才显示「自动」按钮。
/// 单独成方法是为了可被判据直接调用（不必等 /api/meta 的网络回调）。
- (void)applyCoverSourceGate {
    NSString *cs = [self.trackMetadata[@"coverSource"] isKindOfClass:NSString.class]
        ? self.trackMetadata[@"coverSource"] : @"";
    self.coverResetBtn.hidden = ![cs isEqualToString:@"manual"];
}

- (void)loadMetaAndKnowledgeForPath:(NSString *)path {
    if (!path.length) {
        self.trackMetadata=@{};[self railInvalidateForTrackChange];[self renderMetaChipsFromMeta:nil];[self renderRailMetadata];
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
        [self_ renderMetaChipsFromMeta:json];
        // v3.3.11：只有 coverSource == manual 才显示「自动」封面按钮（否则无东西可恢复）。
        [self_ applyCoverSourceGate];
        NSString *album=[json[@"album"] isKindOfClass:NSString.class]?json[@"album"]:@"";
        self_.artistLabel2.stringValue=[NSString stringWithFormat:@"%@%@%@",artist,album.length?@" · ":@"",album];
        NSMutableArray *format=[NSMutableArray array];if([json[@"codec"] isKindOfClass:NSString.class])[format addObject:[json[@"codec"] uppercaseString]];
        if([json[@"sampleRate"] doubleValue]>0)[format addObject:[NSString stringWithFormat:@"%g kHz",[json[@"sampleRate"] doubleValue]/1000]];
        if([json[@"bits"] integerValue]>0)[format addObject:[NSString stringWithFormat:@"%ld bit",(long)[json[@"bits"] integerValue]]];
        // web npPlayingKindText：**有格式字段才拼** " · CODEC / kHz / bit"，一个都没有就只回「正在播放」。
        // 旧码无条件拼分隔符 ⟹ /api/meta 缺 codec/sampleRate/bits 时显示「正在播放 · 」（尾部悬挂）。
        RLPSetKernedText(self_.kindLabel,
            format.count
                ? [NSString stringWithFormat:@"%@ · %@", RLPTr(@"正在播放"), [format componentsJoinedByString:@" / "]]
                : RLPTr(@"正在播放"), 1.6);
        // 三张卡的 summary 预览从这里起步（闸门在 railBeginSummariesForMeta 内判定，
        // 关时零请求、只留本地事实）。
        [self_ railBeginSummariesForMeta:json];
    }];
}

#pragma mark - 版本对比（/api/compare，与 web 同口径）

/// 打开弹层：列同目录音频文件（/api/files?dir=），当前曲目默认勾选。
/// 打开古典作品页：带当前曲名与艺术家（作曲家可空，后端按作品名检索）。
/// 右键菜单的「古典作品」入口：作品名/作曲家按 web npWorkTarget 抽取，与右栏第 4 张卡共用
/// 同一套判定（web npDataTargets 只在古典曲目追加 work tab）。结果由后端 versions 说话。
- (void)onOpenWorks:(id)sender {
    (void)sender;
    // web npOpenWorks：作品名/作曲家都从 npWorkTarget(curMeta) 取（去掉译名括号、猜作曲家），
    // 旧实现把"艺术家"当作曲家传，Discogs 检索几乎必然 0 条。
    NSDictionary *wt = RLPNPWorkTarget(self.trackMetadata ?: @{});
    NSString *title = RLPRailStr(wt[@"title"]);
    if (!title.length) title = self.titleLabel2.stringValue ?: @"";
    if (!title.length && self.currentPath.length)
        title = self.currentPath.lastPathComponent.stringByDeletingPathExtension;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenWorksNotification"
        object:@{@"title": title, @"composer": RLPRailStr(wt[@"composer"])}];
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
        if (json && [json[@"ok"] boolValue]) {self.favorite=on;self.favoriteButton.title=on?@"♥":@"♡";RLPToast(RLPTr(on?@"已收藏":@"已取消收藏"));[[NSNotificationCenter defaultCenter] postNotificationName:RLPFavoritesChangedNotification object:self];}
        else RLPToast(RLPTr(@"收藏失败"));
    }];
}

#pragma mark - 音频分析面板（web #npAnal：头部两行 + 三张摘要卡 + 展开档卡内指标）

/// 卡片区是 web #npAnlBody：三张摘要卡**始终存在**，展开档只是让每张卡长出指标网格。
/// 旧实现展开时把三张卡 hidden 掉、换一块纯文本 NSTextView —— 那条路径已删除；
/// 没有 health 数据（未播放/未分析/分析失败）时仍保留纯文本解释，信息不丢。
- (RLPAnlCardView *)anlCardWithIdentifier:(NSString *)ident {
    RLPAnlCardView *c = [[RLPAnlCardView alloc] initWithFrame:NSZeroRect];
    c.identifier = ident;
    c.cardKey = ident;
    __weak __typeof__(self) ws = self;
    // 点卡片 = 与「详细」分段同一动作（web：点 .anlchd 走 anlSetLvl 的同一个循环）。
    c.onTap = ^{ __typeof__(self) s = ws; if (s) [s onAnlExpand:nil]; };
    [self.anlBody addSubview:c];
    return c;
}

- (void)onAnlDyn:(id)sender { [self anlOpenLevel:RLPAnlLevelMetrics]; }
- (void)onAnlQual:(id)sender { [self anlOpenLevel:RLPAnlLevelMetrics]; }
- (void)onAnlFake:(id)sender { [self anlOpenLevel:RLPAnlLevelMetrics]; }

/// 卡片区滚轮：内容高于面板时按位移滚动（卡片区 masksToBounds 已经裁在面板内）。
- (void)onAnlBodyScroll:(CGFloat)deltaY {
    const CGFloat maxOffset = MAX(0.0, self.anlContentH - self.anlBody.bounds.size.height);
    self.anlScrollOffset = MAX(0.0, MIN(maxOffset, self.anlScrollOffset - deltaY));
    [self anlLayoutCards];
}

/// 分段文字：10.5/600（web .npseg>b）。自动态带实心点（web .npseg>b.auto.on::before）。
- (void)anlUpdateSegmentTitles {
    RLPTheme *t = [RLPTheme current];
    NSFont *f = [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold];
    NSString *autoTitle = self.anlAutoEnabled
        ? [NSString stringWithFormat:@"● %@", RLPTr(@"自动")] : RLPTr(@"自动");
    NSString *toggleTitle = self.anlLevel == RLPAnlLevelCollapsed ? RLPTr(@"详细")
                         : (self.anlLevel == RLPAnlLevelMetrics ? RLPTr(@"全部指标") : RLPTr(@"收起"));
    NSArray<NSButton *> *btns = @[self.anlAuto, self.anlExpand, self.anlRun];
    NSArray<NSString *> *titles = @[autoTitle, toggleTitle, RLPTr(@"分析")];
    NSArray<NSColor *> *colors = @[self.anlAutoEnabled ? t.okText : t.text2, t.text2, t.accentText];
    for (NSUInteger i = 0; i < btns.count; ++i) {
        NSButton *b = btns[i];
        b.font = f;
        NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
        ps.alignment = NSTextAlignmentCenter;
        [b setAttributedTitle:[[NSAttributedString alloc]
            initWithString:titles[i]
                attributes:@{ NSFontAttributeName: f, NSForegroundColorAttributeName: colors[i],
                              NSParagraphStyleAttributeName: ps }]];
    }
}

/// 每一段宽度 = 文字宽 + 左右 padding 11（web .npseg>b padding:3px 11px）。
- (CGFloat)anlSegmentWidth {
    NSFont *f = [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold];
    CGFloat total = 2.0;   // 外框左右各 1px
    NSArray<NSButton *> *btns = @[self.anlAuto, self.anlExpand, self.anlRun];
    for (NSUInteger i = 0; i < btns.count; ++i) {
        NSString *label = btns[i].attributedTitle.string.length
            ? btns[i].attributedTitle.string : (btns[i].title ?: @"");
        total += ceil([label sizeWithAttributes:@{ NSFontAttributeName: f }].width) + 22.0;
        if (i + 1 < btns.count) total += 1.0;   // 段间发丝（border-left）
    }
    return total;
}

/// 分段控件右端贴齐面板内容右缘（web .anlacts justify-content:flex-end）。
- (void)anlLayoutSegmentAtY:(CGFloat)y right:(CGFloat)right {
    NSFont *f = [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold];
    NSArray<NSButton *> *btns = @[self.anlAuto, self.anlExpand, self.anlRun];
    NSArray<NSView *> *seps = @[self.anlSep1, self.anlSep2];
    const CGFloat total = [self anlSegmentWidth];
    self.anlSeg.frame = NSMakeRect(right - total, y, total, 21.0);
    CGFloat cx = 1.0;   // 外框 1px
    for (NSUInteger i = 0; i < btns.count; ++i) {
        NSString *label = btns[i].attributedTitle.string.length
            ? btns[i].attributedTitle.string : (btns[i].title ?: @"");
        const CGFloat w = ceil([label sizeWithAttributes:@{ NSFontAttributeName: f }].width) + 22.0;
        btns[i].frame = NSMakeRect(cx, 1.0, w, 19.0);
        cx += w;
        if (i < seps.count) {
            seps[i].frame = NSMakeRect(cx, 1.0, 1.0, 19.0);
            cx += 1.0;
        }
    }
}

/// 卡片区排版：高度由每张卡的**文本实测**决定（不再有 100/74 固定上限）；
/// 内容高于面板时允许滚动，滚动位移夹在 [0, contentH - 可见高]。
- (void)anlLayoutCards {
    const CGFloat W = self.anlBody.bounds.size.width;
    const CGFloat H = self.anlBody.bounds.size.height;
    if (W < 20 || H < 10) return;
    // web `#npAnlBody{padding-right:13px}` + 6px 滚动条：卡片右缘与拇指之间始终留 13pt，
    // 拇指条再占 12pt（拇指 6pt 居中），总右侧占位 25pt。整条右侧**常驻**，
    // 与内容多少/是否滚动无关 ⟹ 三档（L0/L1/L2）卡宽恒定、滚动条永不压卡片圆角。
    const CGFloat kGutter = 25.0;
    const CGFloat cardW = MAX(20.0, W - kGutter);
    NSArray<RLPAnlCardView *> *cards = @[self.anlDyn, self.anlQual, self.anlFake];
    CGFloat hs[3] = {0, 0, 0};
    CGFloat contentH = 0;
    for (NSUInteger i = 0; i < cards.count; ++i) {
        hs[i] = [cards[i] preferredHeightForWidth:cardW];
        contentH += hs[i];
    }
    contentH += 8.0 * 2;   // web #npAnlBody gap:8px
    self.anlContentH = contentH;
    const CGFloat maxOffset = MAX(0.0, contentH - H);
    if (self.anlScrollOffset > maxOffset) self.anlScrollOffset = maxOffset;
    if (self.anlScrollOffset < 0) self.anlScrollOffset = 0;
    CGFloat top = H + self.anlScrollOffset;
    for (NSUInteger i = 0; i < cards.count; ++i) {
        RLPAnlCardView *c = cards[i];
        c.frame = NSMakeRect(0, top - hs[i], cardW, hs[i]);
        [c relayout];
        top -= hs[i] + 8.0;
    }
    self.anlBody.contentHeight = contentH;
    self.anlBody.scrollOffset = self.anlScrollOffset;
    self.anlBody.needsDisplay = YES;
}

/// 「展开」循环三档：收起 → 指标 → 全量 → 收起（与 web 版 anlSetLvl 同口径）。
- (void)onAnlExpand:(id)sender {
    RLPAnlLevel next = (self.anlLevel == RLPAnlLevelCollapsed) ? RLPAnlLevelMetrics
                     : (self.anlLevel == RLPAnlLevelMetrics ? RLPAnlLevelFull : RLPAnlLevelCollapsed);
    [self anlOpenLevel:next];
}

- (void)anlOpenLevel:(RLPAnlLevel)level {
    self.anlLevel = level;
    [self anlPaint];
}

/// 只刷文案，不重新取数（0.8s 轮询会调它，绝不能在这里发分析请求）。
/// 展开档的数据全部来自 RLPAnlRowsForCard（health → 行），UI 只排版、不算指标。
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
    // 徽标：web anlCardDyn 在 channels>2 出「多声道 N ch」，anlCardFake 在 fake24 出「24bit 可疑」。
    NSString *dynBadge = nil;
    if (h && RLPAnlAvail(h[@"channels"]) && [h[@"channels"] doubleValue] > 2.0)
        dynBadge = [NSString stringWithFormat:@"%@ %@ ch", RLPTr(@"多声道"), RLPAnlCount(h[@"channels"])];
    NSString *fakeBadge = nil;
    if (h && [h[@"fake24"] isKindOfClass:[NSNumber class]] && [h[@"fake24"] boolValue])
        fakeBadge = RLPTr(@"24bit 可疑");

    const NSInteger lvl = (NSInteger)self.anlLevel;
    NSArray<NSDictionary *> *dynRows = h ? RLPAnlRowsForCard(h, @"dyn", lvl) : @[];
    NSArray<NSDictionary *> *qualRows = h ? RLPAnlRowsForCard(h, @"qual", lvl) : @[];
    NSArray<NSDictionary *> *fakeRows = h ? RLPAnlRowsForCard(h, @"fake", lvl) : @[];

    [self.anlDyn applyTitle:RLPTr(@"动态") summary:dyn badge:dynBadge];
    [self.anlQual applyTitle:RLPTr(@"音质") summary:qual badge:nil];
    [self.anlFake applyTitle:RLPTr(@"假无损") summary:fake badge:fakeBadge];
    [self.anlDyn applyRows:dynRows level:lvl];
    [self.anlQual applyRows:qualRows level:lvl];
    [self.anlFake applyRows:fakeRows level:lvl];
    self.anlDyn.toolTip = dyn; self.anlQual.toolTip = qual; self.anlFake.toolTip = fake;

    // 状态：标题已独立成「音频分析」，这里只说状态（web #npAnlStat 的语义）。
    NSString *stat;
    if (self.anlBusy) stat = RLPTr(@"分析中…");
    else if (self.anlError.length) stat = [NSString stringWithFormat:@"%@：%@", RLPTr(@"分析失败"), self.anlError];
    else if (!self.currentPath.length) stat = RLPTr(@"未播放");
    else if (!RLPAnlIsLocalPath(self.currentPath)) stat = RLPTr(@"仅本地文件可分析");
    else if (!h) stat = RLPTr(@"未分析");
    // U10：后端判「文件可能不完整」时，状态串直接说出来（后端 note 在展开档首行原样展示）。
    // 不写"分析失败"也不写"已分析"：分析**成功**了，只是结论只覆盖已存在的那一部分。
    else if (RLPAnlIncomplete(h)) stat = RLPTr(@"文件可能不完整");
    else stat = self.anlCached ? RLPTr(@"缓存命中") : RLPTr(@"已分析");
    self.analysisStatus.stringValue = stat;
    self.anlAuto.state = self.anlAutoEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self anlUpdateSegmentTitles];

    // 有 health ⟹ 三卡可见 + 卡内指标（不再藏卡换文本）；
    // 无 health（未播放/未分析/失败）⟹ 等价信息仍以纯文本解释呈现，信息不丢。
    const BOOL showBlob = (self.anlLevel != RLPAnlLevelCollapsed && !h);
    self.anlBody.hidden = showBlob;
    self.anlDetailScroll.hidden = !showBlob;
    self.anlReanalyze.hidden = (self.anlLevel == RLPAnlLevelCollapsed);
    if (showBlob)
        self.anlDetail.string = RLPAnlDetailText(h, lvl, self.anlCached, self.anlError, self.currentPath);
    else
        self.anlDetail.string = @"";
    [self layoutWebPlayback];
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
    self.titleLabel2.textColor=t.text;self.artistLabel2.textColor=t.mut;self.metaLabel.textColor=t.mut2;
    {
        NSString *k=self.kindLabel.attributedStringValue.string ?: self.kindLabel.stringValue ?: RLPTr(@"正在播放");
        self.kindLabel.textColor=t.mut2;
        RLPSetKernedText(self.kindLabel, k, 1.6);
    }
    self.railTitle.textColor=t.mut2;self.analysisStatus.textColor=t.mut2;self.lyricsEmpty.textColor=t.mut2;
    self.anlHide.contentTintColor=t.mut2;self.railHide.contentTintColor=t.mut2;
    for(NSView *p in @[self.analysisPanel,self.railPanel]){p.wantsLayer=YES;p.layer.cornerRadius=14;p.layer.borderWidth=1;p.layer.borderColor=t.line.CGColor;p.layer.backgroundColor=[t.isLight?[NSColor colorWithSRGBRed:15/255. green:23/255. blue:42/255. alpha:.04]:[NSColor colorWithWhite:1 alpha:.045] CGColor];}
    // 头部：独立 9.5/700/kern1.5 标题（web .anllab）；分段控件一个外框 + 内部发丝分隔。
    {
        NSMutableParagraphStyle *ps=[[NSMutableParagraphStyle alloc] init];ps.lineBreakMode=NSLineBreakByTruncatingTail;
        self.anlLab.attributedStringValue=[[NSAttributedString alloc] initWithString:RLPTr(@"音频分析")
            attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:9.5 weight:NSFontWeightBold],
                         NSForegroundColorAttributeName:t.mut2,
                         NSKernAttributeName:@1.5,
                         NSParagraphStyleAttributeName:ps}];
    }
    self.anlLab.font=[NSFont systemFontOfSize:9.5 weight:NSFontWeightBold];
    self.anlSeg.layer.backgroundColor=t.hov.CGColor;
    self.anlSeg.layer.borderColor=t.line.CGColor;
    self.anlSep1.layer.backgroundColor=t.line.CGColor;
    self.anlSep2.layer.backgroundColor=t.line.CGColor;
    [self anlUpdateSegmentTitles];
    for(RLPAnlCardView *c in @[self.anlDyn,self.anlQual,self.anlFake])[c applyTheme];
    for(RLPRailChipView *b in self.railCards){[b applyTheme];b.layer.borderColor=t.line.CGColor;}
    // #npMeta 的徽标/芯片颜色来自层的 CGColor + attributedTitle，切主题必须重刷（否则停在旧主题）。
    [self restyleMetaChipsForTheme];
    // 只刷图标色：右上三键的静态底/边框是 web 设计值（npclose 期望 rgba(255,255,255,.92)），
    // 不能在主题切换时覆盖（2026-11-17 首次尝试就是覆盖了它导致 native_nowplaying_web 失败）。
    for(NSButton *b in @[self.closeButton,self.analysisToggle,self.railToggle]) b.contentTintColor=t.text;
    self.anlDetail.textColor=t.text;[self.webControls applyTheme];self.webControls.playBtn.layer.backgroundColor=t.accent.CGColor;self.webControls.playBtn.contentTintColor=NSColor.whiteColor;
    [self.knowledge applyTheme];[self renderRailMetadata];[self updateLyricPosition:self.webStatus.position];[self updateBlurredCover];
}

- (void)applyLanguage {
    self.pageTitle = RLPTr(@"正在播放");
    self.railTitle.stringValue = RLPTr(@"AI 整理");
    if (!self.currentPath.length) {
        self.titleLabel2.stringValue = RLPTr(@"未播放");
    }
    if (!self.trackMetadata.count) {
        RLPSetKernedText(self.kindLabel, RLPTr(@"正在播放"), 1.6);
    }
    {
        NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
        ps.lineBreakMode = NSLineBreakByTruncatingTail;
        self.anlLab.attributedStringValue = [[NSAttributedString alloc] initWithString:RLPTr(@"音频分析")
            attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:9.5 weight:NSFontWeightBold],
                         NSForegroundColorAttributeName:[RLPTheme current].mut2,
                         NSKernAttributeName:@1.5,
                         NSParagraphStyleAttributeName:ps}];
    }
    [self anlUpdateSegmentTitles];
    [self anlPaint];
    [self applyPlayModeUI];
    // 这些提示在构图时才写一次 RLPTr；切语言必须原地重算，否则英文界面仍是中文提示。
    self.saveButton.toolTip = RLPTr(@"把当前曲目添加到指定歌单");
    self.closeButton.toolTip = RLPTr(@"返回（Esc）");
    self.analysisToggle.toolTip = RLPTr(@"显示 / 隐藏音频分析面板");
    self.railToggle.toolTip = RLPTr(@"显示 / 隐藏 AI 资料面板");
    self.anlHide.toolTip = RLPTr(@"隐藏音频分析面板，可在右上角重新显示");
    self.railHide.toolTip = RLPTr(@"隐藏 AI 资料面板，可在右上角重新显示");
    self.coverSetBtn.toolTip = RLPTr(@"仅设置当前歌曲封面，不修改专辑和音乐文件");
    self.coverResetBtn.toolTip = RLPTr(@"恢复自动封面");
    [self applyCastChipStyle];
    [self.webControls applyLanguage];
    if (!self.lyricLines.count) {
        self.lyricsEmpty.stringValue = RLPTr(@"没有歌词");
    }
    [self renderRailMetadata];
    [self.knowledge applyLanguage];
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
- (void)onExternalFavoritesChanged:(NSNotification *)note {
    if (note.object == self) return;
    if (![RLPCoreClient shared].started) return;
    [self refreshFavorite];
}

- (void)refreshFavorite {
    NSString *path=self.currentPath;if(!path.length)return;__weak __typeof__(self) ws=self;
    [[RLPCoreClient shared] getJSON:@"/api/fav/list" completion:^(NSDictionary *j){__typeof__(self) s=ws;if(!s||![path isEqual:s.currentPath])return;NSArray *items=[j[@"files"] isKindOfClass:NSArray.class]?j[@"files"]:([j[@"items"] isKindOfClass:NSArray.class]?j[@"items"]:@[]);s.favorite=NO;for(id item in items){NSString *p=[item isKindOfClass:NSString.class]?item:([item isKindOfClass:NSDictionary.class]?item[@"file"]:nil);if([RLPNPFavKey(p) isEqual:RLPNPFavKey(path)])s.favorite=YES;}s.favoriteButton.title=s.favorite?@"♥":@"♡";}];
}
/// 从 /api/queue 快照里取 mode 并刷新循环/随机芯片（web applyRep(v)）。
- (void)applyPlayModeFromJSON:(NSDictionary *)j {
    self.playbackMode = ([j[@"mode"] respondsToSelector:@selector(integerValue)]) ? [j[@"mode"] integerValue] : 0;
    [self applyPlayModeUI];
}

/// 只同步「播放模式」（不依赖当前曲）：页面重新打开时把模式拉回最新。
/// 与 refreshQueueContext 共用 /api/queue?meta=1，但**不**用 currentPath 守卫
/// （模式不是某一首的属性，换曲守卫会把它丢掉）。
- (void)refreshPlayMode {
    __weak __typeof__(self) ws = self;
    [[RLPCoreClient shared] getJSON:@"/api/queue?meta=1" completion:^(NSDictionary *j){__typeof__(self) s=ws;
        if(!s||![j isKindOfClass:[NSDictionary class]])return;
        [s applyPlayModeFromJSON:j];
    }];
}

- (void)refreshQueueContext {
    NSString *path=self.currentPath;__weak __typeof__(self) ws=self;
    [[RLPCoreClient shared] getJSON:@"/api/queue?meta=1" completion:^(NSDictionary *j){__typeof__(self) s=ws;
        if(!s||![path isEqual:s.currentPath])return;
        if(![j isKindOfClass:[NSDictionary class]]){[s applyQueueSnapshot:nil];return;}
        [s applyPlayModeFromJSON:j];
        [s applyQueueSnapshot:j];
    }];
}

/// web `updateNextTrackInfo()` 的逐条移植（`ui_script.h`）：
///   ① `if (!S.playing || !qLen) { display:none; return; }`
///   ② 单曲循环（mode 2）的「下一首」= 当前曲；顺序/列表/随机按 (cur+1)，越界时的回绕规则：
///      mode 1/3 回绕到第 1 首，mode 0 = hasNext:false ⟹ 「队列末尾」。
///   ③ 文案：`下一首: <名> · 剩 N 首`（remain 0 时不带后缀）/ `队列末尾 · 共 N 首`。
/// 原生 metaLabel 就是 `#npNextTrackHero`（font 12 / mut2 / margin-top 4）。
- (void)applyQueueSnapshot:(NSDictionary *)json {
    NSArray *items=[json[@"items"] isKindOfClass:[NSArray class]]?json[@"items"]:@[];
    const NSInteger qLen=(NSInteger)items.count;
    const NSInteger idx=([json[@"index"] respondsToSelector:@selector(integerValue)])?[json[@"index"] integerValue]:-1;
    const NSInteger mode=([json[@"mode"] respondsToSelector:@selector(integerValue)])?[json[@"mode"] integerValue]:0;
    if(!self.webStatus.playing||qLen<=0){
        self.metaLabel.stringValue=@"";
        self.metaLabel.toolTip=nil;
        self.metaLabel.hidden=YES;
        self.nextTrackVisible=NO;
        [self layoutWebPlayback];
        return;
    }
    NSInteger cur=idx;
    if(cur<0&&self.currentPath.length){
        for(NSInteger i=0;i<qLen;++i)
            if([RLPQueueItemPath(items[(NSUInteger)i]) isEqualToString:self.currentPath]){cur=i;break;}
    }
    NSInteger nextIdx=cur+1;
    BOOL hasNext=YES;
    if(mode==2){nextIdx=(cur>=0&&cur<qLen)?cur:0;hasNext=(qLen>0);}
    else if(nextIdx>=qLen){
        if(mode==1||mode==3){nextIdx=0;hasNext=(qLen>0);}
        else hasNext=NO;
    }
    const NSInteger remain=MAX(0,qLen-1-(cur>=0?cur:0));
    NSString *text;
    if(hasNext&&qLen>0){
        NSString *name=RLPQueueItemPath(items[(NSUInteger)(nextIdx<0?0:nextIdx)]).lastPathComponent;
        text=remain>0
            ?[NSString stringWithFormat:RLPTr(@"下一首: %@ · 剩 %ld 首"),name,(long)remain]
            :[NSString stringWithFormat:RLPTr(@"下一首: %@"),name];
    } else {
        text=[NSString stringWithFormat:RLPTr(@"队列末尾 · 共 %ld 首"),(long)qLen];
    }
    self.metaLabel.stringValue=text;
    self.metaLabel.toolTip=text;
    self.metaLabel.hidden=NO;
    self.nextTrackVisible=YES;
    [self layoutWebPlayback];
}
@end
