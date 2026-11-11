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
//   GET  /api/opra/index?q=…      → {"ok":true,"items":[{"id","name","vendor"}]}
//   GET  /api/opra/presets?productId=… → {"ok":true,"items":[{"id","name"}]}
//   POST /api/opra/apply  body "productId=…&presetId=…" → {"ok":true,"path":…}
//
// 节流：文字输入 260ms 后才 POST。每敲一个字符打一次后端会把正在播的歌反复重启。
#import "RLPEqualizerView.h"
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

#include <cmath>
#include <initializer_list>

#pragma mark - 频响曲线（自绘）

@interface RLPEQCurveView : NSView
@property (nonatomic, copy) NSArray<NSArray<NSNumber *> *> *points;
@end

@implementation RLPEQCurveView

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    RLPTheme *t = [RLPTheme current];
    NSRect b = self.bounds;
    [t.bg2 setFill];
    NSRectFill(b);

    const CGFloat padL = 34, padR = 8, padT = 8, padB = 18;
    NSRect plot = NSMakeRect(b.origin.x + padL, b.origin.y + padB,
                             b.size.width - padL - padR, b.size.height - padT - padB);
    if (plot.size.width <= 4 || plot.size.height <= 4) return;

    // x 轴对数 20Hz..20kHz；y 轴 ±18dB
    const double fMin = 20.0, fMax = 20000.0, dbMax = 18.0;
    const double lfMin = log10(fMin), lfMax = log10(fMax);
    CGFloat (^X)(double) = ^CGFloat(double f) {
        double c = MAX(fMin, MIN(fMax, f));
        return plot.origin.x + (CGFloat)((log10(c) - lfMin) / (lfMax - lfMin)) * plot.size.width;
    };
    CGFloat (^Y)(double) = ^CGFloat(double db) {
        double c = MAX(-dbMax, MIN(dbMax, db));
        return plot.origin.y + (CGFloat)((c + dbMax) / (2 * dbMax)) * plot.size.height;
    };

    // 网格：十倍频程 + 每 6dB 一条
    [t.line setStroke];
    for (double f : { 100.0, 1000.0, 10000.0 }) {
        NSBezierPath *g = [NSBezierPath bezierPath];
        [g moveToPoint:NSMakePoint(X(f), plot.origin.y)];
        [g lineToPoint:NSMakePoint(X(f), NSMaxY(plot))];
        g.lineWidth = 0.5;
        [g stroke];
    }
    for (double db = -12.0; db <= 12.0; db += 6.0) {
        if (fabs(db) < 0.001) continue;
        NSBezierPath *g = [NSBezierPath bezierPath];
        [g moveToPoint:NSMakePoint(plot.origin.x, Y(db))];
        [g lineToPoint:NSMakePoint(NSMaxX(plot), Y(db))];
        g.lineWidth = 0.5;
        [g stroke];
    }
    // 0dB 基准线画粗一点
    NSBezierPath *zero = [NSBezierPath bezierPath];
    [zero moveToPoint:NSMakePoint(plot.origin.x, Y(0))];
    [zero lineToPoint:NSMakePoint(NSMaxX(plot), Y(0))];
    zero.lineWidth = 1.0;
    [t.mut setStroke];
    [zero stroke];

    // 轴标注
    NSDictionary *attrs = @{ NSFontAttributeName: t.small, NSForegroundColorAttributeName: t.mut };
    [@"+18" drawAtPoint:NSMakePoint(2, NSMaxY(plot) - 12) withAttributes:attrs];
    [@"0" drawAtPoint:NSMakePoint(2, Y(0) - 6) withAttributes:attrs];
    [@"-18" drawAtPoint:NSMakePoint(2, plot.origin.y) withAttributes:attrs];
    [@"20" drawAtPoint:NSMakePoint(plot.origin.x, 2) withAttributes:attrs];
    [@"1k" drawAtPoint:NSMakePoint(X(1000) - 6, 2) withAttributes:attrs];
    [@"20k" drawAtPoint:NSMakePoint(NSMaxX(plot) - 22, 2) withAttributes:attrs];

    if (!self.points.count) {
        // 没数据就如实说，不画一条假装是"平直响应"的线
        NSString *msg = RLPTr(@"无曲线数据");
        NSSize sz = [msg sizeWithAttributes:attrs];
        [msg drawAtPoint:NSMakePoint(NSMidX(plot) - sz.width / 2, NSMidY(plot) - sz.height / 2)
          withAttributes:attrs];
        return;
    }

    NSBezierPath *curve = [NSBezierPath bezierPath];
    BOOL started = NO;
    for (NSArray<NSNumber *> *pt in self.points) {
        if (pt.count < 2) continue;
        const double f = pt[0].doubleValue, db = pt[1].doubleValue;
        if (!isfinite(f) || !isfinite(db) || f <= 0) continue;
        NSPoint p = NSMakePoint(X(f), Y(db));
        if (!started) { [curve moveToPoint:p]; started = YES; }
        else [curve lineToPoint:p];
    }
    if (started) {
        curve.lineWidth = 1.8;
        [t.accent setStroke];
        [curve stroke];
    }
}

@end

#pragma mark - 均衡主视图

@interface RLPEqualizerView () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSStackView *stack;
@property (nonatomic, strong) RLPEQCurveView *curve;
@property (nonatomic, strong) NSSwitch *bypass;
@property (nonatomic, strong) NSTextField *preamp;
@property (nonatomic, strong) NSTextField *status;
@property (nonatomic, strong) NSTableView *bandTable;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *bands;
@property (nonatomic, strong) NSTimer *applyTimer;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, strong) NSPopUpButton *presetPop;
@property (nonatomic, strong) NSTextField *presetName;
@property (nonatomic, strong) NSTextField *opraQuery;
@property (nonatomic, strong) NSPopUpButton *opraProduct;
@property (nonatomic, strong) NSPopUpButton *opraPreset;
@property (nonatomic, strong) NSTextField *opraStatus;
@property (nonatomic, copy) NSArray<NSDictionary *> *opraItems;
@property (nonatomic, copy) NSArray<NSDictionary *> *opraPresets;
@end

@implementation RLPEqualizerView

- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    if (self) {
        _bands = [NSMutableArray array];
        _opraItems = @[];
        _opraPresets = @[];
        [self build];
    }
    return self;
}

- (void)build {
    RLPTheme *t = [RLPTheme current];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:self.bounds];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    [self addSubview:scroll];

    self.stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.stack.alignment = NSLayoutAttributeLeading;
    self.stack.spacing = 10;
    self.stack.edgeInsets = NSEdgeInsetsMake(4, 0, 16, 0);
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = self.stack;
    [NSLayoutConstraint activateConstraints:@[
        [self.stack.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [self.stack.trailingAnchor constraintEqualToAnchor:scroll.contentView.trailingAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [self.stack.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
    ]];

    NSStackView *top = [[NSStackView alloc] init];
    top.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    top.spacing = 10;
    self.bypass = [[NSSwitch alloc] initWithFrame:NSZeroRect];
    self.bypass.target = self;
    self.bypass.action = @selector(onBypass:);
    [top addArrangedSubview:self.bypass];
    [top addArrangedSubview:RLPLabel(RLPTr(@"旁路（不改声音）"), t.body, t.text)];
    [top addArrangedSubview:RLPLabel(RLPTr(@"前级"), t.body, t.text)];
    self.preamp = [[NSTextField alloc] initWithFrame:NSZeroRect];
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

    self.curve = [[RLPEQCurveView alloc] initWithFrame:NSZeroRect];
    self.curve.wantsLayer = YES;
    self.curve.layer.cornerRadius = 8;
    self.curve.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stack addArrangedSubview:self.curve];
    [NSLayoutConstraint activateConstraints:@[
        [self.curve.heightAnchor constraintEqualToConstant:170],
        [self.curve.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-4],
    ]];

    [self.stack addArrangedSubview:RLPLabel(RLPTr(@"20 段参数"),
        [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], t.text)];
    self.bandTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.bandTable.dataSource = self;
    self.bandTable.delegate = self;
    self.bandTable.rowHeight = 26;
    self.bandTable.backgroundColor = t.bg;
    NSArray *titles = @[ @"#", RLPTr(@"频率 Hz"), RLPTr(@"增益 dB"), @"Q", RLPTr(@"类型") ];
    NSArray *ids = @[ @"n", @"f", @"g", @"q", @"type" ];
    NSArray *ws = @[ @34, @90, @90, @70, @130 ];
    for (NSInteger i = 0; i < (NSInteger)titles.count; ++i) {
        NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:ids[i]];
        c.title = titles[i];
        c.width = [ws[i] doubleValue];
        [self.bandTable addTableColumn:c];
    }
    NSScrollView *bs = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    bs.documentView = self.bandTable;
    bs.hasVerticalScroller = YES;
    bs.drawsBackground = NO;
    bs.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stack addArrangedSubview:bs];
    [NSLayoutConstraint activateConstraints:@[
        [bs.heightAnchor constraintEqualToConstant:300],
        [bs.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-4],
    ]];

    [self buildPresetSection];
    [self buildOpraSection];
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
}

- (void)buildOpraSection {
    RLPTheme *t = [RLPTheme current];
    [self.stack addArrangedSubview:RLPLabel(RLPTr(@"OPRA 耳机目标曲线"),
        [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], t.text)];
    [self.stack addArrangedSubview:RLPLabel(
        RLPTr(@"输入耳机型号搜索；应用后会把 PEQ 换成该耳机的补偿曲线"), t.small, t.mut)];

    NSStackView *r1 = [[NSStackView alloc] init];
    r1.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r1.spacing = 8;
    self.opraQuery = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.opraQuery.placeholderString = RLPTr(@"例如 HD650");
    self.opraQuery.target = self;
    self.opraQuery.action = @selector(onOpraSearch:);
    [[self.opraQuery.widthAnchor constraintEqualToConstant:220] setActive:YES];
    [r1 addArrangedSubview:self.opraQuery];
    NSButton *sb = [NSButton buttonWithTitle:RLPTr(@"搜索") target:self action:@selector(onOpraSearch:)];
    sb.bezelStyle = NSBezelStyleRounded;
    [r1 addArrangedSubview:sb];
    [self.stack addArrangedSubview:r1];

    NSStackView *r2 = [[NSStackView alloc] init];
    r2.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r2.spacing = 8;
    self.opraProduct = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.opraProduct.target = self;
    self.opraProduct.action = @selector(onOpraProduct:);
    [[self.opraProduct.widthAnchor constraintEqualToConstant:260] setActive:YES];
    [r2 addArrangedSubview:self.opraProduct];
    self.opraPreset = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [[self.opraPreset.widthAnchor constraintEqualToConstant:200] setActive:YES];
    [r2 addArrangedSubview:self.opraPreset];
    NSButton *ab = [NSButton buttonWithTitle:RLPTr(@"应用") target:self action:@selector(onOpraApply:)];
    ab.bezelStyle = NSBezelStyleRounded;
    [r2 addArrangedSubview:ab];
    [self.stack addArrangedSubview:r2];

    self.opraStatus = RLPLabel(@"", t.small, t.mut);
    [self.stack addArrangedSubview:self.opraStatus];
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
            [p addItemsWithTitles:@[ @"peak", @"lowshelf", @"highshelf" ]];
            p.identifier = key;
            p.target = self;
            p.action = @selector(onBandType:);
            p.font = t.small;
        }
        p.tag = row;
        NSString *ty = [band[@"type"] isKindOfClass:[NSString class]] ? band[@"type"] : @"peak";
        if ([p itemWithTitle:ty]) [p selectItemWithTitle:ty];
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
    self.bands[row][@"type"] = sender.titleOfSelectedItem ?: @"peak";
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

- (NSString *)bandsParam {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSDictionary *b in self.bands) {
        [parts addObject:[NSString stringWithFormat:@"%.4f,%.4f,%.4f,%@",
                          [b[@"f"] doubleValue], [b[@"g"] doubleValue],
                          [b[@"q"] doubleValue],
                          [b[@"type"] isKindOfClass:[NSString class]] ? b[@"type"] : @"peak"]];
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
    }];
}

/// 把后端状态吸收进 UI。loading 期间禁止触发新的 POST，避免回填→提交→回填的死循环。
- (void)absorbState:(NSDictionary *)json {
    self.loading = YES;
    if ([json[@"bypass"] respondsToSelector:@selector(boolValue)])
        self.bypass.state = [json[@"bypass"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    if ([json[@"preamp"] respondsToSelector:@selector(doubleValue)])
        self.preamp.stringValue = [NSString stringWithFormat:@"%.2f", [json[@"preamp"] doubleValue]];

    NSArray *bs = [json[@"bands"] isKindOfClass:[NSArray class]] ? json[@"bands"] : nil;
    if (bs.count) {
        [self.bands removeAllObjects];
        for (id x in bs) {
            if (![x isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *m = [NSMutableDictionary dictionary];
            m[@"f"] = @([x[@"f"] respondsToSelector:@selector(doubleValue)] ? [x[@"f"] doubleValue] : 0);
            m[@"g"] = @([x[@"g"] respondsToSelector:@selector(doubleValue)] ? [x[@"g"] doubleValue] : 0);
            m[@"q"] = @([x[@"q"] respondsToSelector:@selector(doubleValue)] ? [x[@"q"] doubleValue] : 1);
            m[@"type"] = [x[@"type"] isKindOfClass:[NSString class]] ? x[@"type"] : @"peak";
            [self.bands addObject:m];
        }
        [self.bandTable reloadData];
    }

    NSArray *pts = [json[@"points"] isKindOfClass:[NSArray class]] ? json[@"points"] : nil;
    NSMutableArray<NSArray<NSNumber *> *> *clean = [NSMutableArray array];
    for (id p in pts) {
        if (![p isKindOfClass:[NSArray class]] || [(NSArray *)p count] < 2) continue;
        NSArray *a = (NSArray *)p;
        if (![a[0] respondsToSelector:@selector(doubleValue)] || ![a[1] respondsToSelector:@selector(doubleValue)]) continue;
        [clean addObject:@[ @([a[0] doubleValue]), @([a[1] doubleValue]) ]];
    }
    self.curve.points = clean;
    [self.curve setNeedsDisplay:YES];

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

#pragma mark - OPRA

- (void)onOpraSearch:(id)sender {
    NSString *qq = [self.opraQuery.stringValue stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // 空关键词不发请求（web 版明确纪律：避免一进页面就拉整个索引）
    if (!qq.length) { self.opraStatus.stringValue = RLPTr(@"请输入耳机型号"); return; }
    if (![RLPCoreClient shared].started) return;
    self.opraStatus.stringValue = RLPTr(@"搜索中…");
    NSString *url = [NSString stringWithFormat:@"/api/opra/index?q=%@", RLPEnc(qq)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *items = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[];
        NSMutableArray<NSDictionary *> *good = [NSMutableArray array];
        for (id x in items) if ([x isKindOfClass:[NSDictionary class]]) [good addObject:x];
        self_.opraItems = good;
        [self_.opraProduct removeAllItems];
        [self_.opraPreset removeAllItems];
        for (NSDictionary *x in good) {
            NSString *nm = [x[@"name"] isKindOfClass:[NSString class]] ? x[@"name"] : @"";
            NSString *vd = [x[@"vendor"] isKindOfClass:[NSString class]] ? x[@"vendor"] : @"";
            NSString *title = vd.length ? [NSString stringWithFormat:@"%@ · %@", vd, nm] : nm;
            if (title.length) [self_.opraProduct addItemWithTitle:title];
        }
        self_.opraStatus.stringValue = good.count
            ? [NSString stringWithFormat:RLPTr(@"%ld 个结果"), (long)good.count]
            : RLPTr(@"没有匹配的耳机");
        if (good.count) [self_ onOpraProduct:nil];
    }];
}

- (void)onOpraProduct:(id)sender {
    const NSInteger idx = self.opraProduct.indexOfSelectedItem;
    if (idx < 0 || idx >= (NSInteger)self.opraItems.count) return;
    NSString *pid = self.opraItems[idx][@"id"];
    if (![pid isKindOfClass:[NSString class]] || !pid.length) return;
    NSString *url = [NSString stringWithFormat:@"/api/opra/presets?productId=%@", RLPEnc(pid)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *items = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[];
        NSMutableArray<NSDictionary *> *good = [NSMutableArray array];
        for (id x in items) if ([x isKindOfClass:[NSDictionary class]]) [good addObject:x];
        self_.opraPresets = good;
        [self_.opraPreset removeAllItems];
        for (NSDictionary *x in good) {
            NSString *nm = [x[@"name"] isKindOfClass:[NSString class]] ? x[@"name"] : @"";
            if (nm.length) [self_.opraPreset addItemWithTitle:nm];
        }
        if (!good.count) self_.opraStatus.stringValue = RLPTr(@"这款耳机没有可用曲线");
    }];
}

- (void)onOpraApply:(id)sender {
    const NSInteger pi = self.opraProduct.indexOfSelectedItem;
    const NSInteger ei = self.opraPreset.indexOfSelectedItem;
    if (pi < 0 || pi >= (NSInteger)self.opraItems.count ||
        ei < 0 || ei >= (NSInteger)self.opraPresets.count) {
        RLPToast(RLPTr(@"请先选择耳机与曲线"));
        return;
    }
    NSString *pid = self.opraItems[pi][@"id"];
    NSString *eid = self.opraPresets[ei][@"id"];
    if (![pid isKindOfClass:[NSString class]] || ![eid isKindOfClass:[NSString class]]) return;
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
        self_.opraStatus.stringValue = RLPTr(@"已应用耳机曲线");
        RLPToast(RLPTr(@"已应用耳机曲线"));
        // EQ 已被换成耳机曲线 ⟹ 必须重新拉 /api/peq 才能看到真实新状态
        [self_ reload];
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
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.bandTable.backgroundColor = t.bg;
    self.status.textColor = t.mut;
    self.opraStatus.textColor = t.mut;
    [self.bandTable reloadData];
    [self.curve setNeedsDisplay:YES];
}

@end
