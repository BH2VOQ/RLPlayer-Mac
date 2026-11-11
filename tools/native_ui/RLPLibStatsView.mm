// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPLibStatsView.mm — 本地音乐库统计卡（契约见 .h）
//
// 纪律：数字全部来自 /api/lib/stats，UI 只排版，不自己算、不编造。
// 失败/空响应保留上一次的真实数据（web loadLibStats 对 _err 的处理同口径），
// 绝不把「读取失败」显示成 0。
#import "RLPLibStatsView.h"
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

@interface RLPLibStatsView ()
@property (nonatomic, strong) NSStackView *grid;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) NSUInteger seq;
@property (nonatomic, assign) BOOL hasData;
@property (nonatomic, strong) NSMutableArray<NSTextField *> *valueLabels;
@end

@implementation RLPLibStatsView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _valueLabels = [NSMutableArray array];
        [self buildUI];
    }
    return self;
}

- (void)buildUI {
    RLPTheme *t = [RLPTheme current];
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.wantsLayer = YES;
    self.layer.cornerRadius = 10;
    self.layer.borderWidth = 1;
    self.layer.borderColor = t.line.CGColor;
    self.layer.backgroundColor = t.field.CGColor;

    self.grid = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.grid.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.grid.alignment = NSLayoutAttributeLeading;
    self.grid.spacing = 4;
    self.grid.edgeInsets = NSEdgeInsetsMake(10, 14, 10, 14);
    self.grid.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:self.grid];
    [NSLayoutConstraint activateConstraints:@[
        [self.grid.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.grid.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.grid.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.grid.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
    [self renderRows:@[]];
}

/// 行 = 标签（等宽）+ 值。行结构固定，后续只改值文案，避免整块重建抖动。
- (void)renderRows:(NSArray<NSArray<NSString *> *> *)pairs {
    for (NSView *v in [self.grid.arrangedSubviews copy]) {
        [self.grid removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [self.valueLabels removeAllObjects];
    RLPTheme *t = [RLPTheme current];
    NSArray<NSArray<NSString *> *> *rows = pairs.count ? pairs : @[
        @[RLPTr(@"曲目"), @"—"], @[RLPTr(@"专辑"), @"—"],
        @[RLPTr(@"扫描线程（生效）"), @"—"], @[RLPTr(@"上次扫描"), @"—"],
    ];
    for (NSArray<NSString *> *pair in rows) {
        NSStackView *row = [[NSStackView alloc] init];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.alignment = NSLayoutAttributeCenterY;
        row.spacing = 10;
        NSTextField *label = RLPLabel(pair[0], t.small, t.mut);
        [label.widthAnchor constraintEqualToConstant:150].active = YES;
        NSTextField *val = RLPLabel(pair[1], t.body, t.text);
        [row addArrangedSubview:label];
        [row addArrangedSubview:val];
        [self.grid addArrangedSubview:row];
        [self.valueLabels addObject:val];
    }
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.layer.borderColor = t.line.CGColor;
    self.layer.backgroundColor = t.field.CGColor;
    for (NSView *row in self.grid.arrangedSubviews) {
        for (NSView *v in row.subviews) {
            if ([v isKindOfClass:[NSTextField class]]) {
                NSTextField *tf = (NSTextField *)v;
                // 第一个是标签（灰）、第二个是值（主色）——顺序由 renderRows 保证。
                tf.textColor = (v == row.subviews.firstObject) ? t.mut : t.text;
            }
        }
    }
}

- (void)stopPolling {
    [self.timer invalidate];
    self.timer = nil;
}

- (void)dealloc { [self stopPolling]; }

- (void)reload {
    if (![RLPCoreClient shared].started) return;
    const NSUInteger seq = ++self.seq;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/lib/stats" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.seq) return;
        // 兜底失败对象没有 tracks 字段：保留上一次真值，不把失败显示成 0。
        if (!json || ![json[@"ok"] boolValue] || ![json[@"tracks"] respondsToSelector:@selector(integerValue)]) {
            if (!self_.hasData) [self_ renderRows:@[]];
            return;
        }
        self_.hasData = YES;
        const NSInteger tracks = [json[@"tracks"] integerValue];
        const NSInteger albums = [json[@"albums"] respondsToSelector:@selector(integerValue)] ? [json[@"albums"] integerValue] : 0;
        const NSInteger th = [json[@"scanThreads"] respondsToSelector:@selector(integerValue)] ? [json[@"scanThreads"] integerValue] : 0;
        const double ms = [json[@"lastScanMs"] respondsToSelector:@selector(doubleValue)] ? [json[@"lastScanMs"] doubleValue] : 0.0;
        const BOOL scanning = [json[@"scanning"] respondsToSelector:@selector(boolValue)] && [json[@"scanning"] boolValue];

        NSMutableArray<NSArray<NSString *> *> *pairs = [NSMutableArray array];
        [pairs addObject:@[RLPTr(@"曲目"), [NSString stringWithFormat:@"%ld", (long)tracks]]];
        [pairs addObject:@[RLPTr(@"专辑"), [NSString stringWithFormat:@"%ld", (long)albums]]];
        // 0 = 自动；显示「自动」而非 0（web 同口径）。
        [pairs addObject:@[RLPTr(@"扫描线程（生效）"), th > 0 ? [NSString stringWithFormat:@"%ld", (long)th] : RLPTr(@"自动")]];
        [pairs addObject:@[RLPTr(@"上次扫描"), ms > 0 ? [NSString stringWithFormat:@"%.1f s", ms / 1000.0] : @"—"]];
        if (scanning) {
            const NSInteger scanned = [json[@"scanned"] respondsToSelector:@selector(integerValue)] ? [json[@"scanned"] integerValue] : 0;
            const NSInteger total = [json[@"total"] respondsToSelector:@selector(integerValue)] ? [json[@"total"] integerValue] : 0;
            [pairs addObject:@[RLPTr(@"进度"), [NSString stringWithFormat:@"%ld / %ld", (long)scanned, (long)total]]];
        }
        [self_ renderRows:pairs];
        [self_ applyTheme];

        // 扫描中 1.5s 轮询；停下来即停表（web pollSchedule 同口径）。
        if (scanning) {
            [self_ stopPolling];
            __weak __typeof__(self_) weak2 = self_;
            self_.timer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *tm) {
                __typeof__(self_) s2 = weak2;
                if (!s2) { [tm invalidate]; return; }
                [s2 reload];
            }];
        } else {
            [self_ stopPolling];
        }
    }];
}

@end