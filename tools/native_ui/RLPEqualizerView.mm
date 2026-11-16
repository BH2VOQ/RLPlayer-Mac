// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPEqualizerView.mm — 20 段 PEQ + OPRA 耳机目标曲线
//
// 后端契约（已核实 src/net/ui_script.h 的 peqApply / peqLoadState / opra*）：
//   GET  /api/peq  → {"ok":true,"bypass":bool,"preamp":dB,"fs":Hz,
//                     "bands":[{"f":Hz,"g":dB,"q":Q,"type":"peak"},…20],
//                     "points":[[Hz,dB],…]}   ← 曲线由后端算，前端不抄第二份
//   POST /api/peq  body "bypass=0&preamp=<n>&bands=<f,g,q,type;…>"（20 段全量）
//                  → 返回**完整新状态**，必须用它刷新曲线（web 版踩过的坑）
//   POST /api/peq/preset  body "action=list|save|load|delete&name=…"
//   GET  /api/opra/index          → {"ok":true,"items":[["id","vendor","name"],…]}
//                                    （**不带 q**：web 全量拉一次做本地过滤；items 是数组三元组）
//        也接受 ?q= 的历史形态，但原生不再用它（第8项：旧实现按字典解析数组 ⟹ 搜索结果恒空）
//   GET  /api/opra/presets?productId=… → {"ok":true,"items":[
//                                    {"id","author","details","link","gainDb","bandsCount"}]}
//                                    （**没有 name 字段**：显示名 = author · details）
//   POST /api/opra/apply  body "productId=…&presetId=…" → {"ok":true,"path":…}
//        成功后必须写回 POST /api/settings 的 eq=/opraproduct=/oprapreset=（web saveSettings(true)），
//        否则后端热重载不触发（第8项断点③/④）
//
// 节流：文字输入 260ms 后才 POST。每敲一个字符打一次后端会把正在播的歌反复重启。
#import "RLPEqualizerView.h"
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPTheme.h"
#import "RLPTargetCurve.h"
#import "RLPEQGeometry.h"
#import "RLPEQFaderView.h"
#import "RLPEQFaderInspector.h"

#include <cmath>
#include <initializer_list>

#pragma mark - OPRA 型号/预设卡片（web #eqModelCards / #eqPresetCards）

/// 型号卡片上的一张小目标曲线（web `.tc-curve` 的同构）：只画曲线，不画坐标轴。
@interface RLPOpraCurveThumb : NSView
@property (nonatomic, strong, nullable) RLPTargetCurve *targetCurve;
@end

@implementation RLPOpraCurveThumb
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    RLPTheme *t = [RLPTheme current];
    NSRect b = NSInsetRect(self.bounds, 1, 1);
    if (b.size.width < 4 || b.size.height < 4) return;
    [t.bg2 setFill];
    NSRectFill(b);
    NSArray<NSValue *> *pts = [RLPTargetCurveLibrary plotPoints:self.targetCurve inRect:b];
    if (pts.count < 2) return;
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:pts.firstObject.pointValue];
    for (NSUInteger i = 1; i < pts.count; ++i) [p lineToPoint:pts[i].pointValue];
    p.lineWidth = 1.4;
    [(t.accent2 ?: t.accent) setStroke];
    [p stroke];
    for (NSValue *v in @[ pts.firstObject, pts.lastObject ]) {
        NSPoint pt = v.pointValue;
        NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(pt.x - 2, pt.y - 2, 4, 4)];
        [(t.accent2 ?: t.accent) setFill];
        [dot fill];
    }
}
@end

/// 型号卡片：`vendor · name` + 「OPRA 校准预设 · 查看调音预设」。点击 = 选中并加载预设墙。
@interface RLPOpraModelCard : NSView
@property (nonatomic, copy) NSString *productId;
@property (nonatomic, copy) NSString *vendor;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, copy, nullable) void (^onClick)(void);
@end

@implementation RLPOpraModelCard
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    if (self) {
        self.identifier = @"opra.model.card";
        self.wantsLayer = YES;
        self.layer.cornerRadius = 8;
        self.layer.borderWidth = 1;
        [self applyTheme];
    }
    return self;
}
- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.layer.backgroundColor = (self.active ? t.accentWeak : t.bg2).CGColor;
    self.layer.borderColor = (self.active ? t.accent : t.line).CGColor;
}
- (void)setActive:(BOOL)active { _active = active; [self applyTheme]; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    RLPTheme *t = [RLPTheme current];
    NSString *title = self.vendor.length
        ? [NSString stringWithFormat:@"%@ · %@", self.vendor, self.name ?: @""]
        : (self.name ?: @"");
    NSDictionary *ta = @{ NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
                          NSForegroundColorAttributeName: t.text };
    NSDictionary *sa = @{ NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightRegular],
                          NSForegroundColorAttributeName: t.mut2 };
    [title drawInRect:NSMakeRect(12, 7, self.bounds.size.width - 24, 18) withAttributes:ta];
    [RLPTr(@"OPRA 校准预设 · 查看调音预设")
        drawInRect:NSMakeRect(12, 27, self.bounds.size.width - 24, 14) withAttributes:sa];
}
- (void)mouseDown:(NSEvent *)event {
    (void)event;
    if (self.onClick) self.onClick();
}
- (void)click { if (self.onClick) self.onClick(); }
@end

/// 预设卡片：目标曲线小图 / 作者·详情 / 段数 / 前级增益 / 应用到 EQ / 当前态。
@interface RLPOpraPresetCard : NSView
@property (nonatomic, assign) NSInteger presetIndex;
@property (nonatomic, copy) NSString *productId;
@property (nonatomic, copy) NSString *presetId;
@property (nonatomic, copy) NSString *titleText;
@property (nonatomic, copy) NSString *detailsText;
@property (nonatomic, copy) NSString *curveName;
@property (nonatomic, copy) NSString *scene;
@property (nonatomic, assign) NSInteger bandsCount;
@property (nonatomic, assign) double gainDb;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, strong) RLPOpraCurveThumb *thumb;
@property (nonatomic, strong) NSButton *applyBtn;
@property (nonatomic, copy, nullable) void (^onSelect)(void);
@property (nonatomic, copy, nullable) void (^onApply)(void);
@end

@implementation RLPOpraPresetCard
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    if (self) {
        self.identifier = @"opra.preset.card";
        self.wantsLayer = YES;
        self.layer.cornerRadius = 9;
        self.layer.borderWidth = 1;
        for (NSString *ident in @[ @"opra.preset.title", @"opra.preset.badge",
                                   @"opra.preset.meta", @"opra.preset.scene" ]) {
            NSTextField *l = [NSTextField labelWithString:@""];
            l.identifier = ident;
            l.bezeled = NO;
            l.drawsBackground = NO;
            l.editable = NO;
            l.selectable = NO;
            l.maximumNumberOfLines = 2;
            l.lineBreakMode = NSLineBreakByTruncatingTail;
            [self addSubview:l];
        }
        self.thumb = [[RLPOpraCurveThumb alloc] initWithFrame:NSZeroRect];
        self.thumb.identifier = @"opra.preset.curve";
        [self addSubview:self.thumb];
        self.applyBtn = [NSButton buttonWithTitle:RLPTr(@"应用到 EQ")
                                            target:self action:@selector(onApplyButton:)];
        self.applyBtn.bezelStyle = NSBezelStyleRounded;
        self.applyBtn.identifier = @"opra.preset.apply";
        self.applyBtn.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        [self addSubview:self.applyBtn];
        [self applyTheme];
    }
    return self;
}
- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.layer.backgroundColor = (self.active ? t.accentWeak : t.bg2).CGColor;
    self.layer.borderColor = (self.active ? t.accent : t.line).CGColor;
    self.applyBtn.title = self.active ? RLPTr(@"已应用当前预设") : RLPTr(@"应用到 EQ");
    NSTextField *title = [self labelWithIdentifier:@"opra.preset.title"];
    title.font = [NSFont systemFontOfSize:13.5 weight:NSFontWeightSemibold];
    title.textColor = t.text;
    title.stringValue = self.titleText ?: @"";
    NSTextField *badge = [self labelWithIdentifier:@"opra.preset.badge"];
    badge.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
    badge.textColor = t.accentText;
    badge.stringValue = [NSString stringWithFormat:@"%ld %@", (long)self.bandsCount, RLPTr(@"段")];
    badge.alignment = NSTextAlignmentRight;
    NSTextField *meta = [self labelWithIdentifier:@"opra.preset.meta"];
    meta.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightRegular];
    meta.textColor = t.mut2;
    meta.stringValue = [NSString stringWithFormat:@"%@%.1f dB · %@%ld %@",
                        RLPTr(@"前级增益："), self.gainDb, RLPTr(@"频段数："),
                        (long)self.bandsCount, RLPTr(@"段")];
    meta.maximumNumberOfLines = 1;
    NSTextField *desc = [self labelWithIdentifier:@"opra.preset.scene"];
    desc.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    desc.textColor = t.mut;
    desc.stringValue = [NSString stringWithFormat:@"%@%@", RLPTr(@"目标曲线："), self.curveName ?: @""];
    desc.maximumNumberOfLines = 1;
    self.thumb.targetCurve = [RLPTargetCurveLibrary curveForKind:
        [RLPTargetCurveLibrary kindForDetails:self.detailsText]];
    [self.thumb setNeedsDisplay:YES];
    [self setNeedsLayout:YES];
}
- (void)setActive:(BOOL)active { _active = active; [self applyTheme]; }
- (NSTextField *)labelWithIdentifier:(NSString *)ident {
    for (NSView *v in self.subviews) {
        if ([v.identifier isEqualToString:ident] && [v isKindOfClass:[NSTextField class]])
            return (NSTextField *)v;
    }
    return nil;
}
- (void)layout {
    [super layout];
    const CGFloat W = self.bounds.size.width;
    [(NSTextField *)[self labelWithIdentifier:@"opra.preset.title"]
        setFrame:NSMakeRect(12, 8, W - 92, 18)];
    [(NSTextField *)[self labelWithIdentifier:@"opra.preset.badge"]
        setFrame:NSMakeRect(W - 78, 9, 66, 16)];
    self.thumb.frame = NSMakeRect(12, 32, W - 24, 40);
    [(NSTextField *)[self labelWithIdentifier:@"opra.preset.scene"]
        setFrame:NSMakeRect(12, 78, W - 24, 16)];
    [(NSTextField *)[self labelWithIdentifier:@"opra.preset.meta"]
        setFrame:NSMakeRect(12, 100, W - 24, 16)];
    self.applyBtn.frame = NSMakeRect(MAX(12, W - 134), 126, 122, 26);
}
- (void)mouseDown:(NSEvent *)event {
    (void)event;
    if (self.onSelect) self.onSelect();
}
- (void)onApplyButton:(id)sender { (void)sender; if (self.onApply) self.onApply(); }
- (void)selectCard { if (self.onSelect) self.onSelect(); }
- (void)applyCard { if (self.onApply) self.onApply(); }
@end

#pragma mark - 均衡主视图

@interface RLPEqualizerView () <NSTableViewDataSource, NSTableViewDelegate,
                                NSTextFieldDelegate>
@property (nonatomic, strong) NSStackView *stack;
@property (nonatomic, strong) NSScrollView *scroll;
@property (nonatomic, strong) NSArray<NSLayoutConstraint *> *scrollConstraints;
@property (nonatomic, assign) BOOL embeddedInPage;
/// 后端 /api/peq 返回的频响点（自动前级要用；EQ 曲线视图已按用户要求删除）。
@property (nonatomic, copy) NSArray<NSArray<NSNumber *> *> *curvePoints;
/// 推子板（用户 2026-11-15 要求的目标形态：下面频率、上面 ±dB 输入）。
@property (nonatomic, strong) RLPEQFaderView *fader;
@property (nonatomic, strong) NSSwitch *bypass;
@property (nonatomic, strong) NSTextField *preamp;
@property (nonatomic, strong) NSTextField *status;
/// 已废弃：20 行表格被用户要求移除（2026-11-15）。保留声明仅为兼容既有判据的 KVC 访问，
/// 运行时恒为 nil；新代码不要再读它。
@property (nonatomic, strong, nullable) NSTableView *bandTable;
/// 单段检查器（Q / 类型 / 开关），替代被移除的表格。
@property (nonatomic, strong) RLPEQFaderInspector *inspector;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *bands;
@property (nonatomic, strong) NSTimer *applyTimer;
@property (nonatomic, assign) BOOL loading;
/// 拖动热路径的轻量刷新次数（判据 E17 用：证明拖动没走 reloadData 重建 cell）。
@property (nonatomic, readonly) NSInteger rowValueRefreshes;
- (void)applyOpraQuery:(NSString *)qq;
- (void)previewTargetCurveForPreset:(nullable NSDictionary *)p;
- (void)resetTargetCurvePreview;
@property (nonatomic, strong) NSPopUpButton *presetPop;
@property (nonatomic, strong) NSTextField *presetName;
@property (nonatomic, strong) NSTextField *opraQuery;
/// OPRA 段独立容器（web「耳机 EQ（OPRA 校准预设）」那张卡的卡体）：
/// 设置页会把它整段搬进第二张卡片；独立使用时仍挂在 self.stack 里。
@property (nonatomic, strong) NSStackView *opraSection;
@property (nonatomic, strong) NSStackView *opraModelCards;
@property (nonatomic, strong) NSStackView *opraPresetCards;
@property (nonatomic, strong) NSTextField *opraGuide;
@property (nonatomic, strong) NSTextField *opraSelectedTitle;
@property (nonatomic, copy) NSArray<RLPOpraModelCard *> *opraModelCardViews;
@property (nonatomic, copy) NSArray<RLPOpraPresetCard *> *opraPresetCardViews;
@property (nonatomic, assign) NSInteger opraSelectedProductIndex;
@property (nonatomic, assign) NSInteger opraSelectedPresetIndex;
@property (nonatomic, copy) NSString *appliedProductId;
@property (nonatomic, copy) NSString *appliedPresetId;
@property (nonatomic, strong) NSTextField *opraStatus;
@property (nonatomic, copy) NSArray<NSDictionary *> *opraItems;
@property (nonatomic, copy) NSArray<NSDictionary *> *opraPresets;
/// /api/opra/index 的一次性缓存（web loadOpraIndex 同语义：**不带 q**，全量拉一次，前端本地过滤）。
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> *opraIndexCache;
/// 型号切换竞态守卫（web OPRA_CUR_PRODUCT：只认最后一次选择）。
@property (nonatomic, assign) NSInteger opraProductSeq;
/// 目标曲线说明（web showTargetCurveInfo 的原生同构：名称/是什么/适合谁/增益与段数）。
@property (nonatomic, strong) NSTextField *opraInfo;
/// 输入即检索的去抖计时器（web sInput.oninput = function(){ doSearch(this.value); }）。
/// 每敲一个字符就查一次 6230 条索引虽然不慢，但会反复重排卡片栈 ⟹ 打字时界面抖；
/// 180ms 去抖既保持"边输入边出结果"的手感，又不在每个击键上重排。
@property (nonatomic, strong, nullable) NSTimer *opraSearchTimer;
/// 上一次已执行的查询（重复触发同一个关键词时不再重排卡片）。
@property (nonatomic, copy) NSString *opraLastQuery;
@end

/// web `.chip:hover{background:var(--hov);color:var(--txt);border-color:var(--acc)}` 的原生等价物。
/// ★ 只补**悬停态**，不改形状：当前用系统圆角 bezel（外观已近似 web 的胶囊），
///   若改成自绘胶囊就等于重新设计控件，超出「补一处悬停」的范围。
@interface RLPChipHoverButton : NSButton
@end

@implementation RLPChipHoverButton {
    NSTrackingArea *_chipTrack;
    NSColor *_chipNormalBezel;      // 进入前的 bezel 色（nil = 系统默认）
    NSAttributedString *_chipNormalTitle;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_chipTrack) [self removeTrackingArea:_chipTrack];
    _chipTrack = [[NSTrackingArea alloc] initWithRect:self.bounds
                                               options:(NSTrackingMouseEnteredAndExited |
                                                        NSTrackingActiveInKeyWindow |
                                                        NSTrackingInVisibleRect)
                                                 owner:self userInfo:nil];
    [self addTrackingArea:_chipTrack];
}

/// 判据入口：真实路径是 tracking area 的 mouseEntered/Exited。
- (void)setChipHovered:(BOOL)hovered {
    RLPTheme *t = [RLPTheme current];
    if (hovered) {
        if (!_chipNormalBezel) _chipNormalBezel = self.bezelColor ?: (NSColor *)[NSNull null];
        if (!_chipNormalTitle) _chipNormalTitle = self.attributedTitle.copy;
        self.bezelColor = t.hov;
        self.attributedTitle = [[NSAttributedString alloc] initWithString:self.title
            attributes:@{ NSFontAttributeName: self.font ?: [NSFont systemFontOfSize:11],
                          NSForegroundColorAttributeName: t.text }];
    } else {
        self.bezelColor = [_chipNormalBezel isKindOfClass:[NSNull class]] ? nil : _chipNormalBezel;
        if (_chipNormalTitle) self.attributedTitle = _chipNormalTitle;
        _chipNormalBezel = nil;
        _chipNormalTitle = nil;
    }
}

- (void)mouseEntered:(NSEvent *)event { (void)event; [self setChipHovered:YES]; }
- (void)mouseExited:(NSEvent *)event  { (void)event; [self setChipHovered:NO]; }
@end

@implementation RLPEqualizerView {
    NSInteger _rowValueRefreshes;
}
@synthesize rowValueRefreshes = _rowValueRefreshes;

/// web `sp_opra_copychip`（ui_script.h:10996-10997 / 11947-11955）：一枚 `.chip`，
/// 点击把 OPRA 项目官网链接写进剪贴板并 toast「已复制来源链接: …」。
/// 旧原生只在 RLPSettingsViewController 的 identifier 字典里有这个字符串 —— 屏幕上
/// 没有控件、没有 target/action，parity_scan/behavior_scan 都因此标成 done（静态表盲区）。
- (void)onCopyOpraLink:(id)sender {
    (void)sender;
    NSString *url = @"https://opra.roon.app/";
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:url forType:NSPasteboardTypeString];
    RLPToast([NSString stringWithFormat:@"%@%@", RLPTr(@"已复制来源链接:"), url]);
}

- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    if (self) {
        _bands = [NSMutableArray array];
        _opraItems = @[];
        _opraPresets = @[];
        _opraIndexCache = nil;
        _opraProductSeq = 0;
        _opraSelectedProductIndex = -1;
        _opraSelectedPresetIndex = -1;
        _appliedProductId = @"";
        _appliedPresetId = @"";
        [self build];
    }
    return self;
}

- (void)build {
    RLPTheme *t = [RLPTheme current];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:self.bounds];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.drawsBackground = NO;
    // 内层滚动条默认不画（设置页外层已有整页滚动；独立使用时可显式打开）
    scroll.hasVerticalScroller = NO;
    [self addSubview:scroll];
    self.scroll = scroll;

    self.stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.stack.alignment = NSLayoutAttributeLeading;
    self.stack.spacing = 10;
    self.stack.edgeInsets = NSEdgeInsetsMake(4, 0, 16, 0);
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = self.stack;
    self.scrollConstraints = @[
        [self.stack.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [self.stack.trailingAnchor constraintEqualToAnchor:scroll.contentView.trailingAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [self.stack.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
    ];
    [NSLayoutConstraint activateConstraints:self.scrollConstraints];

    NSStackView *top = [[NSStackView alloc] init];
    top.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    top.spacing = 10;
    self.bypass = [[NSSwitch alloc] initWithFrame:NSZeroRect];
    self.bypass.identifier = @"peqBypass";     // web #peqBypass（行为扫描锚点）
    self.bypass.target = self;
    self.bypass.action = @selector(onBypass:);
    [top addArrangedSubview:self.bypass];
    [top addArrangedSubview:RLPLabel(RLPTr(@"旁路（不改声音）"), t.body, t.text)];
    [top addArrangedSubview:RLPLabel(RLPTr(@"前级"), t.body, t.text)];
    self.preamp = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.preamp.identifier = @"peqPreamp";     // web #peqPreamp（行为扫描锚点）
    self.preamp.stringValue = @"0";
    self.preamp.target = self;
    self.preamp.action = @selector(onPreampEnter:);
    [[self.preamp.widthAnchor constraintEqualToConstant:64] setActive:YES];
    [top addArrangedSubview:self.preamp];
    [top addArrangedSubview:RLPLabel(@"dB", t.small, t.mut)];
    [self.stack addArrangedSubview:top];

    self.status = RLPLabel(@"", t.small, t.mut);
    self.status.maximumNumberOfLines = 2;
    self.status.lineBreakMode = NSLineBreakByWordWrapping;
    [self.stack addArrangedSubview:self.status];

    // 用户 2026-11-16 明确：不要「切换到曲线」，EQ 曲线视图整体删除，只保留推子板。
    self.fader = [[RLPEQFaderView alloc] initWithFrame:NSZeroRect];
    self.fader.identifier = @"eq.fader";
    self.fader.wantsLayer = YES;
    self.fader.layer.cornerRadius = 8;
    self.fader.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stack addArrangedSubview:self.fader];
    [NSLayoutConstraint activateConstraints:@[
        [self.fader.heightAnchor constraintEqualToConstant:230],
        [self.fader.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-4],
    ]];
    self.fader.hidden = NO;
    __weak __typeof__(self) weakFader = self;
    self.fader.onBandGainEdited = ^(NSInteger idx, double db) {
        __typeof__(self) s = weakFader;
        if (!s || idx < 0 || idx >= (NSInteger)s.bands.count) return;
        s.bands[(NSUInteger)idx][@"g"] = @(db);
        NSMutableArray<NSNumber *> *gains = [s.fader.bandGains mutableCopy]
                                          ?: [NSMutableArray arrayWithCapacity:s.bands.count];
        while (gains.count < s.bands.count) [gains addObject:@0];
        gains[(NSUInteger)idx] = @(db);
        s.fader.bandGains = gains;
        // 拖谁就把检查器切到谁（用户点/拖某一段，下面就该显示那一段的 Q/类型）
        if (s.inspector.bandIndex != idx) [s syncInspectorForBand:idx];
        [s refreshBandRowValues:(NSUInteger)idx];
        [s scheduleApply];
    };

    // 用户 2026-11-15：底下这个 eq 表不要了。
    // 但那张 20 行表是 Q / 滤波器类型 / 单段开关的唯一编辑入口，直接删=删功能。
    // 所以改成单段检查器：只在推子板下方显示当前选中那一段的 Q / 类型 / 开关，
    // 固定一行高、不再是 20 行大表（专业 EQ 的 inspector 做法）。
    self.inspector = [[RLPEQFaderInspector alloc] initWithFrame:NSZeroRect];
    self.inspector.identifier = @"eq.inspector";
    self.inspector.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stack addArrangedSubview:self.inspector];
    [NSLayoutConstraint activateConstraints:@[
        [self.inspector.heightAnchor constraintEqualToConstant:30],
        [self.inspector.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-4],
    ]];
    __weak __typeof__(self) weakInsp = self;
    self.inspector.onQChanged = ^(NSInteger idx, double q) {
        __typeof__(self) s = weakInsp;
        if (!s || idx < 0 || idx >= (NSInteger)s.bands.count) return;
        s.bands[(NSUInteger)idx][@"q"] = @(q);
        [s scheduleApply];
    };
    self.inspector.onTypeChanged = ^(NSInteger idx, NSString *code) {
        __typeof__(self) s = weakInsp;
        if (!s || idx < 0 || idx >= (NSInteger)s.bands.count) return;
        s.bands[(NSUInteger)idx][@"type"] = RLPEQTypeCodeNormalized(code);
        [s scheduleApply];
    };
    self.inspector.onEnabledChanged = ^(NSInteger idx, BOOL on) {
        __typeof__(self) s = weakInsp;
        if (!s || idx < 0 || idx >= (NSInteger)s.bands.count) return;
        s.bands[(NSUInteger)idx][@"on"] = @(on);
        [s scheduleApply];
    };
    // 20 行表格已移除（用户 2026-11-15：底下这个 eq 表不要了）。
    // 它的三列职责去向：频率/增益 → 推子板；Q/类型/开关 → 上面的单段检查器。
    // bandTable 属性保留为 nil，只为让既有 KVC/判据在过渡期不崩（下面有用法守卫）。

    [self buildPresetSection];
    [self buildOpraSection];
    // 独立使用时两段都在本视图里；设置页会把 opraSection 搬进「耳机 EQ」卡。
    [self.stack addArrangedSubview:self.opraSection];
}

- (void)buildPresetSection {
    RLPTheme *t = [RLPTheme current];
    [self.stack addArrangedSubview:RLPLabel(RLPTr(@"PEQ 预设"),
        [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], t.text)];
    NSStackView *row = [[NSStackView alloc] init];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 8;
    self.presetPop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [[self.presetPop.widthAnchor constraintEqualToConstant:200] setActive:YES];
    [row addArrangedSubview:self.presetPop];
    self.presetName = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.presetName.placeholderString = RLPTr(@"预设名");
    [[self.presetName.widthAnchor constraintEqualToConstant:150] setActive:YES];
    [row addArrangedSubview:self.presetName];
    NSArray *acts = @[ @[RLPTr(@"加载"), @"load"], @[RLPTr(@"保存"), @"save"], @[RLPTr(@"删除"), @"delete"] ];
    for (NSArray *pair in acts) {
        NSButton *b = [NSButton buttonWithTitle:pair[0] target:self action:@selector(onPresetAction:)];
        b.bezelStyle = NSBezelStyleRounded;
        b.identifier = pair[1];
        [row addArrangedSubview:b];
    }
    [self.stack addArrangedSubview:row];

    // web #peqAutoPre / #peqReset（ui_script.h:10970-10975）—— 铁律①：功能不能删减。
    // 旧原生只有「加载/保存/删除」三个预设动作，这两个 web 上有的动作在原生**根本不存在**。
    NSStackView *row2 = [[NSStackView alloc] init];
    row2.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row2.spacing = 8;
    NSButton *autoPre = [NSButton buttonWithTitle:RLPTr(@"自动前级（防削波）")
                                           target:self action:@selector(onAutoPreamp:)];
    autoPre.bezelStyle = NSBezelStyleRounded;
    autoPre.identifier = @"peqAutoPre";
    autoPre.toolTip = RLPTr(@"把前级设为 -ceil(当前曲线峰值增益)，给 EQ 提升留出余量，避免数字削波");
    [row2 addArrangedSubview:autoPre];
    NSButton *flat = [NSButton buttonWithTitle:RLPTr(@"重置 Flat")
                                        target:self action:@selector(onResetFlat:)];
    flat.bezelStyle = NSBezelStyleRounded;
    flat.identifier = @"peqReset";
    [row2 addArrangedSubview:flat];
    [self.stack addArrangedSubview:row2];
}

/// web peqAutoPreamp（ui_script.h:11785）的 1:1 同构。
/// 口径必须与 web 一致：后端 points **已含当前前级**，所以先减掉旧前级再取峰值，
/// 前级 = -ceil(峰值)，向上取整保证不削波。
- (void)onAutoPreamp:(id)sender {
    (void)sender;
    // web 用前端算好的 points；这里同源（也是后端 points），不做第二套算法。
    double maxGain = 0.0;
    NSArray<NSArray<NSNumber *> *> *pts = self.curvePoints;
    if (pts.count) {
        for (NSArray<NSNumber *> *p in pts)
            if (p.count >= 2 && p[1].doubleValue > maxGain) maxGain = p[1].doubleValue;
        // points 已含当前前级 ⟹ 先扣掉它，再算需要的新前级
        const double oldPre = self.preamp.doubleValue;
        maxGain = MAX(0.0, maxGain - oldPre);
    } else {
        for (NSDictionary *b in self.bands) {
            const BOOL on = [b[@"on"] respondsToSelector:@selector(boolValue)] ? [b[@"on"] boolValue] : YES;
            if (on && [b[@"g"] doubleValue] > maxGain) maxGain = [b[@"g"] doubleValue];
        }
    }
    const double pre = -MAX(0.0, ceil(maxGain));
    self.preamp.stringValue = [NSString stringWithFormat:@"%.1f", pre];
    [self scheduleApply];
    self.status.stringValue = [NSString stringWithFormat:@"%@%.1f dB → %@ %.1f dB",
        RLPTr(@"自动前级：曲线峰值 +"), maxGain, RLPTr(@"前级"), pre];
}

/// web #peqReset（ui_script.h:11928）：action=reset，后端把它恢复成 Flat。
- (void)onResetFlat:(id)sender {
    (void)sender;
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/peq/preset" body:@"action=reset&name="
                          completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"未知错误");
            RLPToast([RLPTr(@"失败：") stringByAppendingString:err]);
            return;
        }
        [self_ absorbState:json];
        RLPToast(RLPTr(@"已重置为 Flat"));
    }];
}

- (void)buildOpraSection {
    RLPTheme *t = [RLPTheme current];
    self.opraSection = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.opraSection.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.opraSection.alignment = NSLayoutAttributeLeading;
    self.opraSection.spacing = 10;
    self.opraSection.translatesAutoresizingMaskIntoConstraints = NO;
    [self.opraSection addArrangedSubview:RLPLabel(RLPTr(@"OPRA 耳机目标曲线"),
        [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], t.text)];
    [self.opraSection addArrangedSubview:RLPLabel(
        RLPTr(@"输入耳机型号搜索；应用后会把 PEQ 换成该耳机的补偿曲线"), t.small, t.mut)];

    NSStackView *r1 = [[NSStackView alloc] init];
    r1.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r1.spacing = 8;
    self.opraQuery = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.opraQuery.placeholderString = RLPTr(@"例如 HD650");
    self.opraQuery.identifier = @"opra.query";
    self.opraQuery.target = self;
    self.opraQuery.action = @selector(onOpraSearch:);
    // 输入即检索（web sInput.oninput）：按字符触发，180ms 去抖。
    self.opraQuery.delegate = self;
    [[self.opraQuery.widthAnchor constraintEqualToConstant:220] setActive:YES];
    [r1 addArrangedSubview:self.opraQuery];
    NSButton *sb = [NSButton buttonWithTitle:RLPTr(@"搜索") target:self action:@selector(onOpraSearch:)];
    sb.bezelStyle = NSBezelStyleRounded;
    sb.identifier = @"opra.search";
    [r1 addArrangedSubview:sb];
    // web `sp_opra_copychip`：与搜索框同一行的官网链接芯片，点击复制（见 onCopyOpraLink:）。
    RLPChipHoverButton *copyChip = [RLPChipHoverButton buttonWithTitle:@"https://opra.roon.app/"
                                            target:self action:@selector(onCopyOpraLink:)];
    copyChip.identifier = @"sp_opra_copychip";
    copyChip.bezelStyle = NSBezelStyleRounded;
    copyChip.font = [NSFont systemFontOfSize:11.5];
    copyChip.toolTip = RLPTr(@"复制 OPRA 项目官网链接");
    copyChip.image = [NSImage imageWithSystemSymbolName:@"doc.on.doc"
                              accessibilityDescription:RLPTr(@"复制 OPRA 项目官网链接")];
    copyChip.imagePosition = NSImageLeading;
    [r1 addArrangedSubview:copyChip];
    [self.opraSection addArrangedSubview:r1];

    // 型号卡片区（web #eqModelCards）：点击才加载该型号的预设墙。
    self.opraGuide = RLPLabel(RLPTr(@"点击卡片选中"), t.small, t.mut);
    self.opraGuide.identifier = @"opra.guide";
    self.opraGuide.hidden = YES;
    [self.opraSection addArrangedSubview:self.opraGuide];

    self.opraModelCards = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.opraModelCards.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.opraModelCards.alignment = NSLayoutAttributeLeading;
    self.opraModelCards.spacing = 6;
    self.opraModelCards.translatesAutoresizingMaskIntoConstraints = NO;
    [self.opraSection addArrangedSubview:self.opraModelCards];
    [[self.opraModelCards.widthAnchor constraintEqualToAnchor:self.opraSection.widthAnchor constant:-4] setActive:YES];

    // 预设卡片墙（web #eqPresetCards）：作者·详情 / 段数 / 曲线小图 / 前级增益 / 应用按钮。
    self.opraSelectedTitle = RLPLabel(@"", [NSFont systemFontOfSize:13.5 weight:NSFontWeightSemibold], t.text);
    self.opraSelectedTitle.identifier = @"opra.presets.title";
    self.opraSelectedTitle.maximumNumberOfLines = 2;
    self.opraSelectedTitle.lineBreakMode = NSLineBreakByWordWrapping;
    self.opraSelectedTitle.hidden = YES;
    [self.opraSection addArrangedSubview:self.opraSelectedTitle];

    self.opraPresetCards = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.opraPresetCards.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.opraPresetCards.alignment = NSLayoutAttributeLeading;
    self.opraPresetCards.spacing = 8;
    self.opraPresetCards.translatesAutoresizingMaskIntoConstraints = NO;
    self.opraPresetCards.hidden = YES;
    [self.opraSection addArrangedSubview:self.opraPresetCards];
    [[self.opraPresetCards.widthAnchor constraintEqualToAnchor:self.opraSection.widthAnchor constant:-4] setActive:YES];

    self.opraStatus = RLPLabel(@"", t.small, t.mut);
    self.opraStatus.identifier = @"opra.status";
    [self.opraSection addArrangedSubview:self.opraStatus];

    // web showTargetCurveInfo：选中的目标曲线要给出「名称 / 是什么 / 适合谁 / 前级增益 / 段数」。
    self.opraInfo = RLPLabel(@"", t.small, t.mut);
    self.opraInfo.identifier = @"opra.info";
    self.opraInfo.maximumNumberOfLines = 6;
    self.opraInfo.lineBreakMode = NSLineBreakByWordWrapping;
    // 顺序很要紧：先入 hierarchy 再激活「宽 = 容器宽」约束，否则约束两端没有共同祖先，
    // AppKit 会抛 NSGenericException（opra.info / NSStackView 无 common ancestor，实测崩）。
    [self.opraSection addArrangedSubview:self.opraInfo];
    [[self.opraInfo.widthAnchor constraintEqualToAnchor:self.opraSection.widthAnchor] setActive:YES];
}

#pragma mark - OPRA 卡片渲染 / 选择 / 应用

/// 清空栈里的卡片（arrangedSubviews + superview 双清，避免隐藏层残留）。
- (void)clearCardStack:(NSStackView *)stack {
    for (NSView *v in [stack.arrangedSubviews copy]) {
        [stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
}

- (void)renderModelCards {
    [self clearCardStack:self.opraModelCards];
    NSMutableArray<RLPOpraModelCard *> *cards = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.opraItems.count; ++i) {
        NSDictionary *x = self.opraItems[i];
        RLPOpraModelCard *c = [[RLPOpraModelCard alloc] initWithFrame:NSMakeRect(0, 0, 400, 48)];
        c.productId = [x[@"id"] isKindOfClass:[NSString class]] ? x[@"id"] : @"";
        c.vendor = [x[@"vendor"] isKindOfClass:[NSString class]] ? x[@"vendor"] : @"";
        c.name = [x[@"name"] isKindOfClass:[NSString class]] ? x[@"name"] : @"";
        c.active = ([c.productId isEqualToString:self.appliedProductId] ||
                    (NSInteger)i == self.opraSelectedProductIndex);
        __weak __typeof__(self) ws = self;
        c.onClick = ^{ [ws onModelCardSelected:(NSInteger)i]; };
        c.translatesAutoresizingMaskIntoConstraints = NO;
        [self.opraModelCards addArrangedSubview:c];
        [[c.widthAnchor constraintEqualToAnchor:self.opraModelCards.widthAnchor] setActive:YES];
        [[c.heightAnchor constraintEqualToConstant:48] setActive:YES];
        [cards addObject:c];
    }
    self.opraModelCardViews = cards;
    [self notifyContentSizeChanged];
}

/// 内容高度可能变了：通知宿主（设置页）重新量高。
/// 必须**批量结束时**调，不要在循环里调 —— 设置页那边每次都会触发一次卡片重排。
- (void)notifyContentSizeChanged {
    if (self.onContentSizeChanged) self.onContentSizeChanged();
}

- (void)onModelCardSelected:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.opraItems.count) return;
    self.opraSelectedProductIndex = index;
    [self renderModelCards];
    [self loadProductPresets:index];
}

- (void)renderPresetCards {
    [self clearCardStack:self.opraPresetCards];
    if (self.opraSelectedProductIndex < 0 ||
        self.opraSelectedProductIndex >= (NSInteger)self.opraItems.count) {
        self.opraPresetCardViews = @[];
        return;
    }
    NSDictionary *prod = self.opraItems[(NSUInteger)self.opraSelectedProductIndex];
    NSString *pid = [prod[@"id"] isKindOfClass:[NSString class]] ? prod[@"id"] : @"";
    NSMutableArray<RLPOpraPresetCard *> *cards = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.opraPresets.count; ++i) {
        NSDictionary *p = self.opraPresets[i];
        RLPOpraPresetCard *c = [[RLPOpraPresetCard alloc] initWithFrame:NSMakeRect(0, 0, 400, 164)];
        c.presetIndex = (NSInteger)i;
        c.productId = pid;
        c.presetId = [p[@"id"] isKindOfClass:[NSString class]] ? p[@"id"] : @"";
        NSString *author = [p[@"author"] isKindOfClass:[NSString class]] ? p[@"author"] : @"";
        NSString *details = [p[@"details"] isKindOfClass:[NSString class]] ? p[@"details"] : @"";
        c.titleText = author.length ? author : @"OPRA";
        if (details.length) c.titleText = [c.titleText stringByAppendingFormat:@" · %@", details];
        c.detailsText = details;
        c.bandsCount = [p[@"bandsCount"] respondsToSelector:@selector(integerValue)]
            ? [p[@"bandsCount"] integerValue] : 0;
        c.gainDb = [p[@"gainDb"] respondsToSelector:@selector(doubleValue)] ? [p[@"gainDb"] doubleValue] : 0.0;
        c.curveName = [RLPTargetCurveLibrary targetCurveNameForDetails:details author:author];
        c.active = ([c.productId isEqualToString:self.appliedProductId] &&
                    [c.presetId isEqualToString:self.appliedPresetId]);
        __weak __typeof__(self) ws = self;
        __weak RLPOpraPresetCard *weakCard = c;
        c.onSelect = ^{
            ws.opraSelectedPresetIndex = (NSInteger)i;
            [ws previewTargetCurveForPreset:ws.opraPresets.count > (NSUInteger)i ? ws.opraPresets[i] : nil];
            [ws renderPresetCards];
        };
        c.onApply = ^{ [ws applyOpraPreset:pid presetId:weakCard.presetId]; };
        [c applyTheme];
        c.translatesAutoresizingMaskIntoConstraints = NO;
        [self.opraPresetCards addArrangedSubview:c];
        [[c.widthAnchor constraintEqualToAnchor:self.opraPresetCards.widthAnchor] setActive:YES];
        [[c.heightAnchor constraintEqualToConstant:164] setActive:YES];
        [cards addObject:c];
    }
    self.opraPresetCardViews = cards;
    [self notifyContentSizeChanged];
}

/// 只改某一行**已存在**的 cell 里的数值文本，不重建 cell view。
/// 拖动热路径专用（见 onDragBand 的注释）：每秒上百次事件时，任何
/// reloadData / reloadDataForRowIndexes 都会重建 NSTextField 与 NSPopUpButton，
/// 那是可见的卡顿来源。
- (void)refreshBandRowValues:(NSUInteger)row {
    // 判据锚点：拖动热路径每触发一次这里 += 1（E17 用它证明"走了轻量路径"）。
    _rowValueRefreshes += 1;
    if (row >= self.bands.count) return;
    // 表格已移除 ⟹ 拖动时要跟着变的是**检查器**（如果正好选中这一段）。
    // 只在这个段被选中时更新，避免每帧白算一遍。
    if (self.inspector.bandIndex == (NSInteger)row) [self syncInspectorForBand:(NSInteger)row];
}


/// 把 self.bands 同步给两个视图（曲线 + 推子）。集中一处，避免两条路径各写一份。
- (void)syncViewsFromBands {
    NSMutableArray<NSNumber *> *freqs = [NSMutableArray array];
    NSMutableArray<NSNumber *> *gains = [NSMutableArray array];
    for (NSDictionary *b in self.bands) {
        [freqs addObject:b[@"f"] ?: @0];
        [gains addObject:b[@"g"] ?: @0];
    }
    self.fader.bandFreqs = freqs;
    self.fader.bandGains = gains;
    [self.fader setNeedsDisplay:YES];
}

/// 把第 idx 段的 Q / 类型 / 开关 + 频率灌进检查器。idx < 0 时整条隐藏。
- (void)syncInspectorForBand:(NSInteger)idx {
    if (!self.inspector) return;
    if (idx < 0 || idx >= (NSInteger)self.bands.count) {
        self.inspector.bandIndex = -1;
        return;
    }
    NSDictionary *b = self.bands[(NSUInteger)idx];
    self.inspector.bandIndex = idx;
    self.inspector.freqText = [NSString stringWithFormat:@"%.0f Hz", [b[@"f"] doubleValue]];
    self.inspector.q = [b[@"q"] doubleValue];
    self.inspector.typeCode = RLPEQTypeCodeNormalized(b[@"type"]);
    self.inspector.bandEnabled = [b[@"on"] boolValue];
    [self.inspector syncValues];
}

#pragma mark - 频段类型码（后端契约：PK / LS / HS）

// 后端 src/dsp/peq.h 的 peq_band_type_name() 只认这三个码：PK / LS / HS。
// 旧实现把下拉标题 "peak"/"lowshelf"/"highshelf" 直接塞进 type 再发给后端 ——
// peq_band_type_from_name() 虽然能吃 "peak"，但发出去的 bands 串本身格式就是错的
//（后端要「序号,类型,频率,增益,Q」，见 tools/rtaweb.cpp 的 peq_parse_bands_param），
// 所以任何拖动都得到 {"ok":false,"error":"bands 参数格式不对"}。
static NSString *RLPEQTypeCodeFromTitle(NSString *title) {
    if ([title containsString:@"LS"] || [title containsString:@"低架"]) return @"LS";
    if ([title containsString:@"HS"] || [title containsString:@"高架"]) return @"HS";
    return @"PK";
}
static NSString *RLPEQTypeTitleForCode(NSString *code) {
    if ([code isEqualToString:@"LS"]) return RLPTr(@"低架 LS");
    if ([code isEqualToString:@"HS"]) return RLPTr(@"高架 HS");
    return RLPTr(@"峰值 PK");
}
/// 把任意历史形态（peak/PK/LS/LOW_SHELF…）收敛成后端码。
static NSString *RLPEQTypeCodeNormalized(id raw) {
    NSString *s = [raw isKindOfClass:[NSString class]] ? [(NSString *)raw lowercaseString] : @"";
    if ([s isEqualToString:@"ls"] || [s containsString:@"low"]) return @"LS";
    if ([s isEqualToString:@"hs"] || [s containsString:@"high"]) return @"HS";
    return @"PK";
}

#pragma mark - 20 段表格（可编辑）

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)self.bands.count; }

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    RLPTheme *t = [RLPTheme current];
    if (row < 0 || row >= (NSInteger)self.bands.count) return nil;
    NSMutableDictionary *band = self.bands[row];
    NSString *key = col.identifier;

    if ([key isEqualToString:@"n"] || [key isEqualToString:@"f"]) {
        NSTextField *l = [tv makeViewWithIdentifier:key owner:self];
        if (!l) { l = RLPLabel(@"", t.body, t.text); l.identifier = key; }
        if ([key isEqualToString:@"n"]) l.stringValue = [NSString stringWithFormat:@"%ld", (long)(row + 1)];
        else l.stringValue = [NSString stringWithFormat:@"%.1f", [band[@"f"] doubleValue]];
        l.textColor = t.text;
        return l;
    }
    if ([key isEqualToString:@"type"]) {
        NSPopUpButton *p = [tv makeViewWithIdentifier:key owner:self];
        if (!p) {
            p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
            [p addItemsWithTitles:@[ RLPTr(@"峰值 PK"), RLPTr(@"低架 LS"), RLPTr(@"高架 HS") ]];
            p.identifier = key;
            p.target = self;
            p.action = @selector(onBandType:);
            p.font = t.small;
        }
        p.tag = row;
        NSString *ty = RLPEQTypeCodeNormalized(band[@"type"]);
        NSString *title = RLPEQTypeTitleForCode(ty);
        if ([p itemWithTitle:title]) [p selectItemWithTitle:title];
        return p;
    }
    // g / q：可编辑数字框
    NSString *ident = [key stringByAppendingString:@"Field"];
    NSTextField *tf = [tv makeViewWithIdentifier:ident owner:self];
    if (!tf) {
        tf = [[NSTextField alloc] initWithFrame:NSZeroRect];
        tf.identifier = ident;
        tf.font = t.mono;
        tf.bezeled = YES;
        tf.bezelStyle = NSTextFieldRoundedBezel;
        tf.target = self;
        tf.action = @selector(onBandField:);
    }
    tf.tag = row;
    tf.textColor = t.text;
    tf.backgroundColor = t.bg2;
    // 回填期间不要覆盖用户正在输入的内容
    if (!self.loading || [[tv window] firstResponder] != tf) {
        tf.stringValue = [NSString stringWithFormat:@"%.2f", [band[key] doubleValue]];
    }
    return tf;
}

#pragma mark - 编辑与节流提交

- (void)onBandField:(NSTextField *)sender {
    const NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)self.bands.count) return;
    // identifier 形如 "gField" / "qField"
    NSString *key = [sender.identifier substringToIndex:1];
    self.bands[row][key] = @(sender.doubleValue);
    [self scheduleApply];
}

- (void)onBandType:(NSPopUpButton *)sender {
    const NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)self.bands.count) return;
    self.bands[row][@"type"] = RLPEQTypeCodeFromTitle(sender.titleOfSelectedItem);
    [self scheduleApply];
}

- (void)onBypass:(id)sender { [self scheduleApply]; }
- (void)onPreampEnter:(id)sender { [self scheduleApply]; }

/// 260ms 节流：每敲一个字符就 POST 会把正在播的歌反复重启（web 版明确记过）。
- (void)scheduleApply {
    if (self.loading) return;
    [self.applyTimer invalidate];
    __weak __typeof__(self) weakSelf = self;
    self.applyTimer = [NSTimer scheduledTimerWithTimeInterval:0.26 repeats:NO block:^(NSTimer *tm) {
        (void)tm;
        [weakSelf applyNow];
    }];
}

/// 提交给后端的 bands 串。格式由 tools/rtaweb.cpp 的 peq_parse_bands_param() 定义：
///   「序号,类型,频率,增益,Q[,off];…」，类型码 = PK / LS / HS。
/// 旧实现发的是「频率,增益,Q,类型」—— 字段顺序与类型码全错，后端一律
/// 回 {"ok":false,"error":"bands 参数格式不对"} ⟹ 拖动/编辑从来没有真正下发过。
- (NSString *)bandsParam {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.bands.count; ++i) {
        NSDictionary *b = self.bands[i];
        const BOOL on = [b[@"on"] respondsToSelector:@selector(boolValue)] ? [b[@"on"] boolValue] : YES;
        [parts addObject:[NSString stringWithFormat:@"%lu,%@,%.4f,%.4f,%.4f%@",
                          (unsigned long)(i + 1),
                          RLPEQTypeCodeNormalized(b[@"type"]),
                          [b[@"f"] doubleValue], [b[@"g"] doubleValue], [b[@"q"] doubleValue],
                          on ? @"" : @",off"]];
    }
    return [parts componentsJoinedByString:@";"];
}

- (void)applyNow {
    if (![RLPCoreClient shared].started || !self.bands.count) return;
    NSString *body = [NSString stringWithFormat:@"bypass=%d&preamp=%.3f&bands=%@",
                      (self.bypass.state == NSControlStateValueOn ? 1 : 0),
                      self.preamp.doubleValue, RLPEnc([self bandsParam])];
    self.status.stringValue = RLPTr(@"应用中…");
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/peq" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"未知错误");
            self_.status.stringValue = [RLPTr(@"失败：") stringByAppendingString:err];
            return;
        }
        // 关键：用**后端返回的状态**刷新（含新曲线），不用本地猜测值
        [self_ absorbState:json];
        [[NSNotificationCenter defaultCenter] postNotificationName:RLPSettingsChangedNotification object:self_];
    }];
}

/// 把后端状态吸收进 UI。loading 期间禁止触发新的 POST，避免回填→提交→回填的死循环。
- (void)absorbState:(NSDictionary *)json {
    self.loading = YES;
    if ([json[@"bypass"] respondsToSelector:@selector(boolValue)])
        self.bypass.state = [json[@"bypass"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    if ([json[@"preamp"] respondsToSelector:@selector(doubleValue)])
        self.preamp.stringValue = [NSString stringWithFormat:@"%.2f", [json[@"preamp"] doubleValue]];

    // 后端字段名是 **freq / gain / q / type / on**（tools/rtaweb.cpp 的 peq_state_json），
    // 不是 f/g/q/type。旧实现只读 f/g ⟹ 每段都取到 nil ⟹ 20 段频率与增益全变 0：
    // 参数表整列 0.0、曲线永远平直、bandFreqs 全 0 让 20 个手柄叠在最左端（"没有分 band"），
    // 拖动也永远只会命中第 0 段（"拖了没反应"）。这是本轮 EQ 页故障的总根因。
    NSArray *bs = [json[@"bands"] isKindOfClass:[NSArray class]] ? json[@"bands"] : nil;
    if (bs.count) {
        [self.bands removeAllObjects];
        for (id x in bs) {
            if (![x isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *m = [NSMutableDictionary dictionary];
            id fRaw = x[@"freq"] ?: x[@"f"];
            id gRaw = x[@"gain"] ?: x[@"g"];
            m[@"f"] = @([fRaw respondsToSelector:@selector(doubleValue)] ? [fRaw doubleValue] : 0);
            m[@"g"] = @([gRaw respondsToSelector:@selector(doubleValue)] ? [gRaw doubleValue] : 0);
            m[@"q"] = @([x[@"q"] respondsToSelector:@selector(doubleValue)] ? [x[@"q"] doubleValue] : 1);
            m[@"type"] = RLPEQTypeCodeNormalized(x[@"type"]);
            m[@"on"] = @([x[@"on"] respondsToSelector:@selector(boolValue)] ? [x[@"on"] boolValue] : YES);
            [self.bands addObject:m];
        }
        [self syncInspectorForBand:self.inspector.bandIndex];
    }

    NSArray *pts = [json[@"points"] isKindOfClass:[NSArray class]] ? json[@"points"] : nil;
    NSMutableArray<NSArray<NSNumber *> *> *clean = [NSMutableArray array];
    for (id p in pts) {
        if (![p isKindOfClass:[NSArray class]] || [(NSArray *)p count] < 2) continue;
        NSArray *a = (NSArray *)p;
        if (![a[0] respondsToSelector:@selector(doubleValue)] || ![a[1] respondsToSelector:@selector(doubleValue)]) continue;
        [clean addObject:@[ @([a[0] doubleValue]), @([a[1] doubleValue]) ]];
    }
    self.curvePoints = clean;   // 自动前级要用的后端频响点（曲线视图已删除）
    [self syncViewsFromBands];

    // 状态行：以事实为准（几段非 0、前级多少、采样率）
    NSInteger active = 0;
    for (NSDictionary *b in self.bands) if (fabs([b[@"g"] doubleValue]) >= 0.001) ++active;
    const BOOL byp = self.bypass.state == NSControlStateValueOn;
    NSString *fs = [json[@"fs"] respondsToSelector:@selector(doubleValue)]
        ? [NSString stringWithFormat:@"%.0f", [json[@"fs"] doubleValue]] : @"?";
    self.status.stringValue = [NSString stringWithFormat:@"%@ · %@ %ld/%ld · %@ %@ dB · %@ %@ Hz",
        byp ? RLPTr(@"已旁路") : RLPTr(@"生效"),
        RLPTr(@"非零段"), (long)active, (long)self.bands.count,
        RLPTr(@"前级"), self.preamp.stringValue, RLPTr(@"采样率"), fs];
    self.loading = NO;
}

#pragma mark - PEQ 预设

- (void)onPresetAction:(NSButton *)sender {
    NSString *action = sender.identifier;
    NSString *name = self.presetName.stringValue.length
        ? self.presetName.stringValue : (self.presetPop.titleOfSelectedItem ?: @"");
    if (![action isEqualToString:@"list"] && !name.length) {
        RLPToast(RLPTr(@"请先填写或选择预设名"));
        return;
    }
    NSString *body = [NSString stringWithFormat:@"action=%@&name=%@", RLPEnc(action), RLPEnc(name)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/peq/preset" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"未知错误");
            RLPToast([RLPTr(@"预设操作失败：") stringByAppendingString:err]);
            return;
        }
        [self_ absorbState:json];
        [self_ loadPresetList];
        if ([action isEqualToString:@"load"]) RLPToast(RLPTr(@"已加载预设"));
        else if ([action isEqualToString:@"save"]) RLPToast(RLPTr(@"已保存预设"));
        else if ([action isEqualToString:@"delete"]) RLPToast(RLPTr(@"已删除预设"));
    }];
}

- (void)loadPresetList {
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/peq/preset" body:@"action=list&name="
                          completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *items = [json[@"presets"] isKindOfClass:[NSArray class]] ? json[@"presets"]
                       : ([json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : nil);
        if (!items) return;
        [self_.presetPop removeAllItems];
        for (id x in items) {
            NSString *nm = [x isKindOfClass:[NSString class]] ? x
                         : ([x isKindOfClass:[NSDictionary class]] ? x[@"name"] : nil);
            if (nm.length) [self_.presetPop addItemWithTitle:nm];
        }
    }];
}

#pragma mark - OPRA（耳机目标曲线）

// web 的三条纪律，逐条照抄：
//   ① 索引**只拉一次且不带 q**（web loadOpraIndex：`api('/api/opra/index')`），
//      之后在本地按 `vendor name id` 全 token 子串过滤（web doSearch）；
//      空输入**不发起任何请求**（261023-03 #6）。
//   ② 预设列表返回的字段是 id/author/details/link/gainDb/bandsCount（**没有 name**），
//      显示名 = `author · details`（web preset-card 的 b 标签）。
//   ③ 选中/应用预设后展示目标曲线说明（web showTargetCurveInfo），并同步写回
//      settings 的 opraproduct/oprapreset/eq（web applyOpraPreset → saveSettings(true)）。

/// 把 /api/opra/index 的两种历史形态统一成 @{id,vendor,name}：
/// 现在后端返回的是 **[id, vendor, name] 数组三元组**（tools/rtaweb.cpp:11285），
/// 旧实现只认 NSDictionary ⟹ 搜索结果恒为空 —— 这是第8项①层断点的直接原因。
static NSDictionary *RLPOpraIndexItem(id x) {
    if ([x isKindOfClass:[NSArray class]]) {
        NSArray *a = (NSArray *)x;
        if (a.count < 3) return nil;
        NSMutableArray *vals = [NSMutableArray array];
        for (id v in a) [vals addObject:[v isKindOfClass:[NSString class]] ? v : @""];
        return @{ @"id": vals[0], @"vendor": vals[1], @"name": vals[2] };
    }
    if ([x isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)x;
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        m[@"id"] = [d[@"id"] isKindOfClass:[NSString class]] ? d[@"id"] : @"";
        m[@"vendor"] = [d[@"vendor"] isKindOfClass:[NSString class]] ? d[@"vendor"] : @"";
        m[@"name"] = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : @"";
        return [(NSString *)m[@"id"] length] ? m : nil;
    }
    return nil;
}

/// web doSearch 的过滤口径：query 按空白切 token，**每个 token** 都要出现在
/// `vendor name id`（小写）里；命中最多 30 条（web 的 `slice(0,30)`）。
static NSArray<NSDictionary *> *RLPOpraFilter(NSArray<NSDictionary *> *index, NSString *query) {
    NSString *q = [(query ?: @"") stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!q.length) return @[];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *t in [[q lowercaseString] componentsSeparatedByCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]])
        if (t.length) [tokens addObject:t];
    NSMutableArray<NSDictionary *> *hits = [NSMutableArray array];
    for (NSDictionary *it in index) {
        NSString *haystack = [[NSString stringWithFormat:@"%@ %@ %@",
                               it[@"vendor"] ?: @"", it[@"name"] ?: @"", it[@"id"] ?: @""] lowercaseString];
        BOOL match = YES;
        for (NSString *t in tokens) if ([haystack rangeOfString:t].location == NSNotFound) { match = NO; break; }
        if (!match) continue;
        [hits addObject:it];
        if (hits.count >= 30) break;
    }
    return hits;
}

- (void)resetTargetCurvePreview {
    // EQ 曲线视图已按用户要求删除；OPRA 目标曲线只保留文字说明与型号卡片缩略图。
    self.opraInfo.stringValue = @"";
}

/// web showTargetCurveInfo(p)：曲线名称 + 「是什么 / 适合谁」+ 前级增益/段数/预设名。
- (void)previewTargetCurveForPreset:(NSDictionary *)p {
    if (!p) { [self resetTargetCurvePreview]; return; }
    NSString *details = [p[@"details"] isKindOfClass:[NSString class]] ? p[@"details"] : @"";
    NSString *author = [p[@"author"] isKindOfClass:[NSString class]] ? p[@"author"] : @"";
    NSString *name = [RLPTargetCurveLibrary targetCurveNameForDetails:details author:author];
    NSString *scene = [RLPTargetCurveLibrary targetCurveSceneForDetails:details author:author];
    NSString *tech = [RLPTargetCurveLibrary targetCurveTechForDetails:details author:author];
    const double gain = [p[@"gainDb"] respondsToSelector:@selector(doubleValue)] ? [p[@"gainDb"] doubleValue] : 0.0;
    const NSInteger bands = [p[@"bandsCount"] respondsToSelector:@selector(integerValue)] ? [p[@"bandsCount"] integerValue] : 0;
    self.opraInfo.stringValue = [NSString stringWithFormat:
        @"%@\n%@%@\n%@%@\n%@%.1f dB · %@%ld %@ · %@%@",
        [NSString stringWithFormat:RLPTr(@"目标曲线：%@"), name],
        RLPTr(@"是什么："), tech,
        RLPTr(@"适合谁："), scene,
        RLPTr(@"前级增益："), gain, RLPTr(@"滤波段数："), (long)bands, RLPTr(@"段"),
        RLPTr(@"预设："), details.length ? details : (p[@"id"] ?: @"")];
    self.opraInfo.textColor = [RLPTheme current].mut;
}

/// web `sInput.oninput = function () { doSearch(this.value); }` 的原生同构：
/// **边输入边检索**，不是"敲完再点搜索"。180ms 去抖（见 opraSearchTimer 注释）。
- (void)controlTextDidChange:(NSNotification *)note {
    if (note.object != self.opraQuery) return;   // 其它输入框走各自的 action
    [self.opraSearchTimer invalidate];
    __weak __typeof__(self) weakSelf = self;
    self.opraSearchTimer = [NSTimer scheduledTimerWithTimeInterval:0.18 repeats:NO
                                                            block:^(NSTimer *tm) {
        (void)tm;
        __typeof__(self) s = weakSelf;
        if (!s) return;
        NSString *q = [s.opraQuery.stringValue stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([q isEqualToString:s.opraLastQuery]) return;   // 同一个词不重排卡片
        s.opraLastQuery = q;
        [s runOpraSearch:q];
    }];
}

/// 点「搜索」按钮 / 回车：立即执行一次（跳过 180ms 去抖）。
- (void)onOpraSearch:(id)sender {
    [self.opraSearchTimer invalidate];
    NSString *qq = [self.opraQuery.stringValue stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    self.opraLastQuery = qq;
    [self runOpraSearch:qq];
}

/// 真正的检索入口（按钮 / 回车 / 输入去抖三处共用一份）。
/// 空关键词不清空也不发请求：web 261023-03 第6条的语义是"什么都没输入就不列型号"。
- (void)runOpraSearch:(NSString *)qq {
    if (!qq.length) {
        // 输入被清空：回到"引导 + 无结果"的初始态（web doSearch("") 同语义）
        self.opraItems = @[];
        self.opraSelectedProductIndex = -1;
        self.opraSelectedPresetIndex = -1;
        self.opraPresets = @[];
        [self renderModelCards];
        [self renderPresetCards];
        self.opraGuide.hidden = YES;
        self.opraSelectedTitle.hidden = YES;
        self.opraStatus.stringValue = RLPTr(@"请输入耳机型号");
        return;
    }
    if (![RLPCoreClient shared].started) return;
    [self resetTargetCurvePreview];
    self.opraItems = @[];
    self.opraSelectedProductIndex = -1;
    self.opraSelectedPresetIndex = -1;
    self.opraPresets = @[];
    [self renderModelCards];
    [self renderPresetCards];
    self.opraGuide.hidden = YES;
    self.opraSelectedTitle.hidden = YES;
    if (self.opraIndexCache) { [self applyOpraQuery:qq]; return; }
    self.opraStatus.stringValue = RLPTr(@"正在加载耳机数据库…");
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/opra/index" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *raw = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[];
        NSMutableArray<NSDictionary *> *idx = [NSMutableArray array];
        for (id x in raw) { NSDictionary *it = RLPOpraIndexItem(x); if (it) [idx addObject:it]; }
        self_.opraIndexCache = idx;
        [self_ applyOpraQuery:qq];
    }];
}

- (void)applyOpraQuery:(NSString *)qq {
    NSArray<NSDictionary *> *hits = RLPOpraFilter(self.opraIndexCache ?: @[], qq);
    self.opraItems = hits;
    self.opraSelectedProductIndex = -1;
    self.opraSelectedPresetIndex = -1;
    self.opraPresets = @[];
    [self renderModelCards];
    [self renderPresetCards];
    self.opraSelectedTitle.hidden = YES;
    // web：有结果才显示型号卡片区；空结果给"未找到"并在下方给出可操作提示。
    self.opraGuide.hidden = hits.count ? NO : YES;
    self.opraStatus.stringValue = hits.count
        ? [NSString stringWithFormat:RLPTr(@"%ld 个结果"), (long)hits.count]
        : RLPTr(@"未找到匹配的耳机型号，请尝试不同关键词");
}

- (void)loadProductPresets:(NSInteger)productIndex {
    if (productIndex < 0 || productIndex >= (NSInteger)self.opraItems.count) return;
    NSDictionary *prod = self.opraItems[(NSUInteger)productIndex];
    NSString *pid = [prod[@"id"] isKindOfClass:[NSString class]] ? prod[@"id"] : @"";
    if (!pid.length) return;
    NSString *vendor = [prod[@"vendor"] isKindOfClass:[NSString class]] ? prod[@"vendor"] : @"";
    NSString *name = [prod[@"name"] isKindOfClass:[NSString class]] ? prod[@"name"] : @"";
    self.opraSelectedTitle.hidden = NO;
    self.opraSelectedTitle.stringValue = [NSString stringWithFormat:@"%@ %@ · %@",
        vendor, name, RLPTr(@"调音预设")];
    self.opraPresetCards.hidden = NO;
    self.opraPresets = @[];
    [self renderPresetCards];
    self.opraStatus.stringValue = RLPTr(@"正在获取预设…");
    const NSInteger seq = ++self.opraProductSeq;   // 只认最后一次选择（web OPRA_CUR_PRODUCT）
    [self resetTargetCurvePreview];
    NSString *url = [NSString stringWithFormat:@"/api/opra/presets?productId=%@", RLPEnc(pid)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.opraProductSeq) return;
        NSArray *items = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[];
        NSMutableArray<NSDictionary *> *good = [NSMutableArray array];
        for (id x in items) if ([x isKindOfClass:[NSDictionary class]]) [good addObject:x];
        self_.opraPresets = good;
        // 当前态：优先命中 settings 写回的 oprapreset，否则预览第一条。
        NSInteger selected = 0;
        for (NSUInteger i = 0; i < good.count; ++i) {
            NSString *eid = good[i][@"id"];
            if ([eid isKindOfClass:[NSString class]] && [eid isEqualToString:self_.appliedPresetId]) {
                selected = (NSInteger)i;
                break;
            }
        }
        self_.opraSelectedPresetIndex = good.count ? selected : -1;
        [self_ renderPresetCards];
        if (!good.count) {
            self_.opraStatus.stringValue = RLPTr(@"这款耳机没有可用曲线");
            return;
        }
        self_.opraStatus.stringValue = [NSString stringWithFormat:RLPTr(@"%ld 种调音目标"), (long)good.count];
        [self_ previewTargetCurveForPreset:good[(NSUInteger)selected]];
    }];
}

- (void)applyOpraPreset:(NSString *)pid presetId:(NSString *)eid {
    if (!pid.length || !eid.length) {
        RLPToast(RLPTr(@"请先选择耳机与曲线"));
        return;
    }
    // 与 web applyOpraPreset 的请求体逐字段一致：productId=…&presetId=…（两者都做 encodeURIComponent）。
    NSString *body = [NSString stringWithFormat:@"productId=%@&presetId=%@", RLPEnc(pid), RLPEnc(eid)];
    self.opraStatus.stringValue = RLPTr(@"应用中…");
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/opra/apply" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"未知错误");
            self_.opraStatus.stringValue = [RLPTr(@"失败：") stringByAppendingString:err];
            return;
        }
        // 当前态立刻落 UI（要等 reload 回来才显示会闪一下）
        self_.appliedProductId = pid;
        self_.appliedPresetId = eid;
        [self_ renderModelCards];
        [self_ renderPresetCards];
        self_.opraStatus.stringValue = RLPTr(@"已应用耳机曲线");
        RLPToast(RLPTr(@"已应用耳机曲线"));
        // web applyOpraPreset：成功路径是 `j.path`（eqPath 仅兼容），随后 **saveSettings(true)**
        // 把 eq / opraproduct / oprapreset 一起落盘。后端热重载靠这份写回触发。
        NSString *appliedPath = [json[@"path"] isKindOfClass:[NSString class]] ? json[@"path"]
                               : ([json[@"eqPath"] isKindOfClass:[NSString class]] ? json[@"eqPath"] : nil);
        if (appliedPath.length) {
            NSString *settings = [NSString stringWithFormat:@"eq=%@&opraproduct=%@&oprapreset=%@",
                                  RLPEnc(appliedPath), RLPEnc(pid), RLPEnc(eid)];
            [[RLPCoreClient shared] postJSON:@"/api/settings" body:settings completion:nil];
        }
        // EQ 已被换成耳机曲线 ⟹ 必须重新拉 /api/peq 才能看到真实新状态
        [self_ reload];
        NSDictionary *cur = nil;
        for (NSDictionary *x in self_.opraPresets) {
            if ([x[@"id"] isKindOfClass:[NSString class]] && [x[@"id"] isEqualToString:eid]) { cur = x; break; }
        }
        if (cur) [self_ previewTargetCurveForPreset:cur];
    }];
}

#pragma mark - 数据与主题

- (void)reload {
    if (![RLPCoreClient shared].started) {
        self.status.stringValue = RLPTr(@"核心未启动");
        return;
    }
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/peq" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            self_.status.stringValue = RLPTr(@"读取失败");
            return;
        }
        [self_ absorbState:json];
    }];
    [self loadPresetList];
    // 当前态：settings 的 opraproduct/oprapreset 是 web 的唯一真相源（预设卡的"已应用当前预设"靠它）。
    [[RLPCoreClient shared] getJSON:@"/api/settings" completion:^(NSDictionary * _Nullable j) {
        __typeof__(self) s = weakSelf;
        if (!s) return;
        NSDictionary *kv = [j[@"kv"] isKindOfClass:[NSDictionary class]] ? j[@"kv"] : nil;
        if (kv) {
            if ([kv[@"opraproduct"] isKindOfClass:[NSString class]]) s.appliedProductId = kv[@"opraproduct"];
            if ([kv[@"oprapreset"] isKindOfClass:[NSString class]]) s.appliedPresetId = kv[@"oprapreset"];
        }
        [s renderModelCards];
        [s renderPresetCards];
    }];
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    // 表格已移除（用户要求），这里不再有可上色的表格。
    self.status.textColor = t.mut;
    self.opraStatus.textColor = t.mut;
    self.opraInfo.textColor = t.mut;
    [self syncInspectorForBand:self.inspector.bandIndex];
}

#pragma mark - 嵌入设置页（去掉本视图自己的滚动，交给整页滚动）

- (NSView *)opraSectionView { return self.opraSection; }

- (void)setEmbeddedInPage:(BOOL)embedded {
    if (_embeddedInPage == embedded) return;
    _embeddedInPage = embedded;
    if (!embedded || !self.scroll) return;
    // 拆掉内层 NSScrollView：stack 直接铺在外层页面上，外层页面负责滚动。
    [NSLayoutConstraint deactivateConstraints:self.scrollConstraints];
    [self.scroll removeFromSuperview];
    self.scroll = nil;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:self.stack];
    [NSLayoutConstraint activateConstraints:@[
        [self.stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:self.topAnchor],
    ]];
    // 高度约束由宿主（设置页 fillEqualizer）持有，避免两边各加一条 required 约束互相冲突。
}

- (CGFloat)preferredContentHeight {
    CGFloat total = self.stack.edgeInsets.top + self.stack.edgeInsets.bottom;
    NSInteger n = 0;
    for (NSView *v in self.stack.arrangedSubviews) {
        if (v.hidden) continue;
        // NSScrollView / 自绘视图在布局前 fittingSize 是 0 —— 先看显式高度约束。
        CGFloat h = 0;
        for (NSLayoutConstraint *c in v.constraints) {
            if (c.firstAttribute == NSLayoutAttributeHeight && c.secondItem == nil
                && c.relation == NSLayoutRelationEqual) { h = c.constant; break; }
        }
        if (h <= 0) h = v.fittingSize.height;
        total += h;
        ++n;
    }
    if (n > 1) total += self.stack.spacing * (n - 1);
    return ceil(total);
}

@end
