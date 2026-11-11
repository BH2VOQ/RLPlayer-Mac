// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPKnowledgeView.mm — AI 资料层（知识卡 + 简介）
//
// 后端契约（src/net/ui_script.h 已核实）：
//   GET /api/entity/knowledge?kind=<track|release|person|work>&name=…[&refresh=1]
//   GET /api/entity/summary?kind=…&name=…[&artist=…]&lang=zh[&refresh=1]
//   两者返回：{ ok, kind, fields:{标签:值,…}, pending:bool, retryAfterMs:N, … }
//
// 两条硬纪律（web 版明确记过）：
//   ① **AI 不知道的标签根本不出现** —— 不许用"未知/—"占位冒充有数据；
//   ② pending 是后端异步 job，按 retryAfterMs 轮询（夹 150..2000），不是失败。
//   ③ 切曲目/切实体后，旧响应必须丢弃（序号守卫），否则会把上一首的资料贴到这一首。
#import "RLPKnowledgeView.h"
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

@interface RLPKnowledgeView ()
@property (nonatomic, strong) NSStackView *stack;
@property (nonatomic, strong) NSTextField *title;
@property (nonatomic, strong) NSStackView *fieldStack;
@property (nonatomic, strong) NSTextView *summaryView;
@property (nonatomic, strong) NSTextField *status;
@property (nonatomic, strong) NSButton *refreshBtn;
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, assign) NSUInteger seq;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, assign) NSInteger pollCount;
@end

@implementation RLPKnowledgeView

- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    if (self) [self build];
    return self;
}

- (void)dealloc { [self cancelLoading]; }

- (void)build {
    RLPTheme *t = [RLPTheme current];
    self.stack = [[NSStackView alloc] initWithFrame:self.bounds];
    self.stack.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.stack.alignment = NSLayoutAttributeLeading;
    self.stack.spacing = 8;
    [self addSubview:self.stack];

    NSStackView *hdr = [[NSStackView alloc] init];
    hdr.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    hdr.spacing = 8;
    self.title = RLPLabel(RLPTr(@"AI 资料"),
        [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], t.text);
    [hdr addArrangedSubview:self.title];
    self.refreshBtn = [NSButton buttonWithTitle:RLPTr(@"重新整理") target:self action:@selector(onRefresh:)];
    self.refreshBtn.bezelStyle = NSBezelStyleRounded;
    self.refreshBtn.enabled = NO;
    [hdr addArrangedSubview:self.refreshBtn];
    [self.stack addArrangedSubview:hdr];

    self.status = RLPLabel(RLPTr(@"未在播放"), t.small, t.mut);
    self.status.maximumNumberOfLines = 2;
    self.status.lineBreakMode = NSLineBreakByWordWrapping;
    [self.stack addArrangedSubview:self.status];

    self.fieldStack = [[NSStackView alloc] init];
    self.fieldStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.fieldStack.alignment = NSLayoutAttributeLeading;
    self.fieldStack.spacing = 3;
    [self.stack addArrangedSubview:self.fieldStack];

    NSScrollView *sc = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    sc.hasVerticalScroller = YES;
    sc.borderType = NSBezelBorder;
    sc.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    self.summaryView.editable = NO;
    self.summaryView.font = t.body;
    self.summaryView.textColor = t.text;
    self.summaryView.backgroundColor = t.bg2;
    sc.documentView = self.summaryView;
    [self.stack addArrangedSubview:sc];
    [NSLayoutConstraint activateConstraints:@[
        [sc.heightAnchor constraintEqualToConstant:150],
        [sc.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor],
    ]];
}

#pragma mark - 加载

- (void)loadKind:(NSString *)kind name:(NSString *)name artist:(NSString *)artist {
    [self cancelLoading];
    self.kind = kind ?: @"track";
    self.name = name ?: @"";
    self.artist = artist ?: @"";
    [self clearFields];
    self.summaryView.string = @"";
    if (!self.name.length) {
        self.status.stringValue = RLPTr(@"未在播放");
        self.refreshBtn.enabled = NO;
        return;
    }
    if (![RLPCoreClient shared].started) {
        self.status.stringValue = RLPTr(@"核心未启动");
        return;
    }
    self.refreshBtn.enabled = YES;
    self.pollCount = 0;
    [self fetchKnowledgeRefresh:NO];
    [self fetchSummaryRefresh:NO];
}

- (void)onRefresh:(id)sender {
    if (!self.name.length) return;
    [self cancelLoading];
    self.pollCount = 0;
    [self clearFields];
    self.summaryView.string = @"";
    [self fetchKnowledgeRefresh:YES];
    [self fetchSummaryRefresh:YES];
}

- (NSString *)urlFor:(NSString *)endpoint refresh:(BOOL)refresh withArtist:(BOOL)withArtist {
    NSMutableString *u = [NSMutableString stringWithFormat:@"%@?kind=%@&name=%@",
                          endpoint, RLPEnc(self.kind), RLPEnc(self.name)];
    if (withArtist) {
        if (self.artist.length) [u appendFormat:@"&artist=%@", RLPEnc(self.artist)];
        [u appendString:@"&lang=zh"];
    }
    if (refresh) [u appendString:@"&refresh=1"];
    return u;
}

- (void)fetchKnowledgeRefresh:(BOOL)refresh {
    const NSUInteger seq = ++self.seq;
    NSString *url = [self urlFor:@"/api/entity/knowledge" refresh:refresh withArtist:NO];
    self.status.stringValue = RLPTr(@"正在整理资料…");
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.seq) return;   // 已切实体 → 丢弃
        if (!json) { self_.status.stringValue = RLPTr(@"资料读取失败"); return; }
        // pending 是后端异步 job，不是失败：按建议间隔轮询（有上限，不无限转）
        if ([json[@"pending"] respondsToSelector:@selector(boolValue)] && [json[@"pending"] boolValue]) {
            [self_ schedulePollForKnowledge];
            return;
        }
        if (![json[@"ok"] boolValue]) {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"资料读取失败");
            self_.status.stringValue = err;
            return;
        }
        [self_ renderFields:json[@"fields"]];
    }];
}

- (void)schedulePollForKnowledge {
    // 上限 40 次（约 16 秒）：后端 job 卡住时不能让用户界面永远转圈
    if (++self.pollCount > 40) {
        self.status.stringValue = RLPTr(@"资料整理超时，可点「重新整理」重试");
        return;
    }
    self.status.stringValue = RLPTr(@"资料整理中…");
    const NSUInteger seq = self.seq;
    __weak __typeof__(self) weakSelf = self;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:NO block:^(NSTimer *tm) {
        (void)tm;
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.seq) return;
        [self_ fetchKnowledgeRefresh:NO];
    }];
}

- (void)fetchSummaryRefresh:(BOOL)refresh {
    NSString *url = [self urlFor:@"/api/entity/summary" refresh:refresh withArtist:YES];
    const NSUInteger seq = self.seq;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.seq) return;
        if (!json || ![json[@"ok"] boolValue]) return;   // 简介是可选增强，失败不覆盖知识卡
        NSString *text = @"";
        if ([json[@"summary"] isKindOfClass:[NSString class]]) text = json[@"summary"];
        else if ([json[@"text"] isKindOfClass:[NSString class]]) text = json[@"text"];
        else if ([json[@"fields"] isKindOfClass:[NSDictionary class]]) {
            // 有些实现把简介放在 fields 里：按"简介/概述"取，取不到就不显示
            NSDictionary *f = json[@"fields"];
            for (NSString *k in @[ RLPTr(@"简介"), RLPTr(@"概述"), @"Summary" ]) {
                if ([f[k] isKindOfClass:[NSString class]]) { text = f[k]; break; }
            }
        }
        self_.summaryView.string = text;
    }];
}

#pragma mark - 渲染

- (void)clearFields {
    for (NSView *v in [self.fieldStack.arrangedSubviews copy]) {
        [self.fieldStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
}

/// 只渲染后端**真的给了**的标签。AI 不知道的标签根本不出现 ——
/// 不许用"未知 / —"占位，那会让用户以为查过了但没查到。
- (void)renderFields:(id)fields {
    [self clearFields];
    if (![fields isKindOfClass:[NSDictionary class]]) {
        self.status.stringValue = RLPTr(@"暂无可确认的资料");
        return;
    }
    NSDictionary *f = (NSDictionary *)fields;
    RLPTheme *t = [RLPTheme current];
    NSArray *keys = [f.allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    NSInteger shown = 0;
    for (NSString *k in keys) {
        id v = f[k];
        NSString *s = nil;
        if ([v isKindOfClass:[NSString class]]) s = v;
        else if ([v isKindOfClass:[NSNumber class]]) s = [v stringValue];
        if (!s.length) continue;   // 空值等于没这条
        NSStackView *row = [[NSStackView alloc] init];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.spacing = 8;
        NSTextField *kl = RLPLabel(k, t.small, t.mut);
        [[kl.widthAnchor constraintEqualToConstant:110] setActive:YES];
        NSTextField *vl = RLPLabel(s, t.small, t.text);
        vl.maximumNumberOfLines = 3;
        vl.lineBreakMode = NSLineBreakByWordWrapping;
        [[vl.widthAnchor constraintLessThanOrEqualToConstant:420] setActive:YES];
        [row addArrangedSubview:kl];
        [row addArrangedSubview:vl];
        [self.fieldStack addArrangedSubview:row];
        ++shown;
    }
    self.status.stringValue = shown
        ? [NSString stringWithFormat:RLPTr(@"%ld 项已确认资料"), (long)shown]
        : RLPTr(@"暂无可确认的资料");
}

- (void)cancelLoading {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    ++self.seq;   // 让在途回调失效
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.title.textColor = t.text;
    self.status.textColor = t.mut;
    self.summaryView.textColor = t.text;
    self.summaryView.backgroundColor = t.bg2;
}

@end
