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
@property (nonatomic, copy) NSString *composer;
@property (nonatomic, assign) BOOL workMode;          // 当前是「作品」模式（走 /api/entity/versions）
@property (nonatomic, strong) NSTextField *workHintSub; // web npDataWorkBody 的第二行「作品：名 · 作曲家」
@property (nonatomic, strong) NSButton *openWorksBtn;   // web npWorkOpen「查看 Discogs 版本推荐 →」
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
    // 用约束铺满，不用 autoresizingMask：本视图自身是被 Auto Layout 定位的，
    // 混用两者会让内容按"初始 bounds"缩放而错位（艺术家页实测：按钮压到统计行上）。
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    self.stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.stack.alignment = NSLayoutAttributeLeading;
    self.stack.spacing = 8;
    [self addSubview:self.stack];
    [NSLayoutConstraint activateConstraints:@[
        [self.stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor],
    ]];

    NSStackView *hdr = [[NSStackView alloc] init];
    // 作为 arrangedSubview 必须关掉 autoresizing 翻译，否则与 stack 的约束打架
    // （实测：按钮被挤到统计行上）。
    hdr.translatesAutoresizingMaskIntoConstraints = NO;
    hdr.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    hdr.alignment = NSLayoutAttributeCenterY;
    hdr.spacing = 8;
    self.title = RLPLabel(RLPTr(@"AI 资料"),
        [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], t.text);
    [hdr addArrangedSubview:self.title];
    self.refreshBtn = [NSButton buttonWithTitle:RLPTr(@"重新整理") target:self action:@selector(onRefresh:)];
    self.refreshBtn.bezelStyle = NSBezelStyleRounded;
    self.refreshBtn.identifier = @"knowledgeRefresh";
    self.refreshBtn.enabled = NO;
    [hdr addArrangedSubview:self.refreshBtn];
    [self.stack addArrangedSubview:hdr];

    self.status = RLPLabel(RLPTr(@"未在播放"), t.small, t.mut);
    self.status.identifier = @"knowledgeStatus";
    self.status.maximumNumberOfLines = 2;
    self.status.lineBreakMode = NSLineBreakByWordWrapping;
    [self.stack addArrangedSubview:self.status];

    // web npDataWorkBody 第二行（「作品：名 · 作曲家」）与整页入口；只在作品模式出现，其它模式隐藏。
    self.workHintSub = RLPLabel(@"", t.small, t.mut2);
    self.workHintSub.identifier = @"npWorkHintSub";
    self.workHintSub.maximumNumberOfLines = 2;
    self.workHintSub.lineBreakMode = NSLineBreakByWordWrapping;
    self.workHintSub.hidden = YES;
    [self.stack addArrangedSubview:self.workHintSub];

    self.fieldStack = [[NSStackView alloc] init];
    self.fieldStack.translatesAutoresizingMaskIntoConstraints = NO;
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
    // web npWorkOpen：「查看 Discogs 版本推荐 →」（原生 = 既有古典作品整页）
    self.openWorksBtn = [NSButton buttonWithTitle:RLPTr(@"查看 Discogs 版本推荐 →")
                                           target:self action:@selector(onOpenWorksPage:)];
    self.openWorksBtn.bezelStyle = NSBezelStyleRounded;
    self.openWorksBtn.identifier = @"npWorkOpen";
    self.openWorksBtn.hidden = YES;
    [self.stack addArrangedSubview:self.openWorksBtn];
    [NSLayoutConstraint activateConstraints:@[
        [sc.heightAnchor constraintEqualToConstant:150],
        [sc.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor],
    ]];
}

#pragma mark - 加载

- (void)loadKind:(NSString *)kind name:(NSString *)name artist:(NSString *)artist {
    [self cancelLoading];
    self.workMode = NO;
    self.composer = @"";
    self.workHintSub.stringValue = @"";
    self.workHintSub.hidden = YES;
    self.openWorksBtn.hidden = YES;
    self.refreshBtn.title = RLPTr(@"重新整理");
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
    if (self.workMode) { [self fetchWorkRefresh:YES]; return; }
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
        if (self_.workMode) [self_ fetchWorkRefresh:NO];
        else [self_ fetchKnowledgeRefresh:NO];
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

/// 版本行的文字允许被压缩（web `.wt/.wp` 都是 `min-width:0;overflow:hidden;text-overflow:ellipsis`）。
static void RLPAllowCompress(NSTextField *tf) {
    [tf setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                  forOrientation:NSLayoutConstraintOrientationHorizontal];
}

#pragma mark - 作品（古典曲目）· 演绎版本

/// web `npDataActivate('work')`：作品实体没有 summary，数据源是 Discogs 版本推荐。
- (void)loadWorkName:(NSString *)name composer:(NSString *)composer {
    [self cancelLoading];
    self.workMode = YES;
    self.kind = @"work";
    self.name = name ?: @"";
    self.composer = composer ?: @"";
    [self clearFields];
    self.summaryView.string = @"";
    self.workHintSub.stringValue = @"";
    self.workHintSub.hidden = YES;
    self.openWorksBtn.hidden = YES;
    self.refreshBtn.title = RLPTr(@"重新查询");
    if (!self.name.length) {
        self.status.stringValue = RLPTr(@"未在播放");
        self.refreshBtn.enabled = NO;
        return;
    }
    [self fetchWorkRefresh:NO];
}

/// web `npDataEnsure('work')` 的 URL 形状：`/api/entity/versions?kind=work&name=…[&composer=…][&refresh=1]`。
- (NSString *)workUrlWithRefresh:(BOOL)refresh {
    NSMutableString *u = [NSMutableString stringWithFormat:@"/api/entity/versions?kind=work&name=%@",
                          RLPEnc(self.name)];
    if (self.composer.length) [u appendFormat:@"&composer=%@", RLPEnc(self.composer)];
    if (refresh) [u appendString:@"&refresh=1"];
    return u;
}

- (void)fetchWorkRefresh:(BOOL)refresh {
    if (![[RLPCoreClient shared] started]) {
        self.status.stringValue = RLPTr(@"核心未启动");
        self.refreshBtn.enabled = NO;
        return;
    }
    self.refreshBtn.enabled = YES;
    const NSUInteger seq = ++self.seq;
    NSString *url = [self workUrlWithRefresh:refresh];
    self.status.stringValue = RLPTr(@"正在整理资料…");   // web npDataSkeleton 的 npdhint
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.seq) return;       // 已换实体/关页 → 丢弃过期结果
        if (!json) { self_.status.stringValue = RLPTr(@"资料读取失败"); return; }
        // pending 是后端异步 job（Discogs 检索可能要几秒），按建议间隔轮询，不是失败。
        if ([json[@"pending"] respondsToSelector:@selector(boolValue)] && [json[@"pending"] boolValue]) {
            [self_ schedulePollForKnowledge];
            return;
        }
        NSArray *perfs = [json[@"performances"] isKindOfClass:[NSArray class]]
                       ? json[@"performances"] : @[];
        const BOOL ok = [json[@"ok"] respondsToSelector:@selector(boolValue)] && [json[@"ok"] boolValue];
        if (!ok || perfs.count == 0) { [self_ renderWorkEmpty:json]; return; }
        [self_ renderWorkRows:json performances:perfs];
    }];
}

/// web `npDataStatHtml('work')` 的正文：`Discogs 实时` / `缓存 · <日期>` + `· 不同演绎 N / 发行版本 M`。
- (NSString *)workSourceLine:(NSDictionary *)json {
    NSString *src;
    if ([json[@"from_cache"] respondsToSelector:@selector(boolValue)] && [json[@"from_cache"] boolValue]) {
        NSString *date = @"";
        id gen = json[@"generated_at"];
        if ([gen respondsToSelector:@selector(doubleValue)] && [gen doubleValue] > 0) {
            NSDateFormatter *df = [[NSDateFormatter alloc] init];
            df.dateFormat = @"yyyy-MM-dd";
            date = [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:[gen doubleValue]]];
        }
        src = date.length ? [NSString stringWithFormat:@"%@ · %@", RLPTr(@"缓存"), date] : RLPTr(@"缓存");
    } else {
        src = RLPTr(@"Discogs 实时");
    }
    NSInteger distinct = [json[@"distinctCount"] respondsToSelector:@selector(integerValue)]
                       ? [json[@"distinctCount"] integerValue] : 0;
    NSInteger releases = [json[@"releaseCount"] respondsToSelector:@selector(integerValue)]
                       ? [json[@"releaseCount"] integerValue] : 0;
    return [NSString stringWithFormat:@"%@ · %@ %ld / %@ %ld", src, RLPTr(@"不同演绎"),
            (long)distinct, RLPTr(@"发行版本"), (long)releases];
}

/// web `npDataWorkBody`：每条 `.npdwork` = `年份 | 标题 | 指挥·乐团·厂牌·格式`。
- (void)renderWorkRows:(NSDictionary *)json performances:(NSArray *)perfs {
    [self clearFields];
    self.workHintSub.hidden = YES;
    self.workHintSub.stringValue = @"";
    self.openWorksBtn.hidden = NO;              // web npWorkOpen
    self.status.stringValue = [self workSourceLine:json];
    RLPTheme *t = [RLPTheme current];
    for (id item in perfs) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *p = (NSDictionary *)item;
        NSStackView *row = [[NSStackView alloc] init];
        row.identifier = @"npWorkRow";
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.alignment = NSLayoutAttributeCenterY;
        row.spacing = 10;

        NSString *year = @"—";
        if ([p[@"year"] respondsToSelector:@selector(integerValue)] && [p[@"year"] integerValue] > 0)
            year = [NSString stringWithFormat:@"%ld", (long)[p[@"year"] integerValue]];
        NSTextField *yl = RLPLabel(year, [NSFont monospacedDigitSystemFontOfSize:11.5
                                                                        weight:NSFontWeightRegular], t.mut);
        yl.identifier = @"npWorkYear";
        [[yl.widthAnchor constraintEqualToConstant:38] setActive:YES];
        RLPAllowCompress(yl);
        [row addArrangedSubview:yl];

        NSString *title = [p[@"title"] isKindOfClass:[NSString class]] ? p[@"title"] : @"—";
        NSTextField *tl = RLPLabel(title.length ? title : @"—", [NSFont systemFontOfSize:11.5], t.text2 ?: t.text);
        tl.identifier = @"npWorkTitle";
        tl.lineBreakMode = NSLineBreakByTruncatingTail;
        tl.maximumNumberOfLines = 1;
        tl.toolTip = title;
        [[tl.widthAnchor constraintGreaterThanOrEqualToConstant:60] setActive:YES];
        RLPAllowCompress(tl);
        [row addArrangedSubview:tl];

        NSString *ens = [p[@"ensemble"] isKindOfClass:[NSString class]] ? p[@"ensemble"] : nil;
        if (!ens.length) ens = [p[@"orchestra"] isKindOfClass:[NSString class]] ? p[@"orchestra"] : @"";
        NSMutableArray<NSString *> *meta = [NSMutableArray array];
        for (NSString *k in @[@"conductor", @"label", @"format"]) {
            if ([p[k] isKindOfClass:[NSString class]] && [p[k] length]) [meta addObject:p[k]];
        }
        // 顺序按 web：[conductor, ensemble||orchestra, label, format]
        NSMutableArray<NSString *> *ordered = [NSMutableArray array];
        if ([p[@"conductor"] isKindOfClass:[NSString class]] && [p[@"conductor"] length])
            [ordered addObject:p[@"conductor"]];
        if (ens.length) [ordered addObject:ens];
        for (NSString *k in @[@"label", @"format"])
            if ([p[k] isKindOfClass:[NSString class]] && [p[k] length]) [ordered addObject:p[k]];
        (void)meta;
        NSString *metaText = ordered.count ? [ordered componentsJoinedByString:@" · "] : @"—";
        NSTextField *ml = RLPLabel(metaText, [NSFont systemFontOfSize:10.5], t.mut2);
        ml.identifier = @"npWorkMeta";
        ml.lineBreakMode = NSLineBreakByTruncatingTail;
        ml.maximumNumberOfLines = 1;
        ml.toolTip = metaText;
        RLPAllowCompress(ml);
        [row addArrangedSubview:ml];
        [self.fieldStack addArrangedSubview:row];
    }
    // 底部「重新查询」在 hdr 的 refreshBtn 上（web 也有 npDataRefresh）；文案随状态切换。
    self.refreshBtn.title = RLPTr(@"重新查询");
}

/// web `npDataWorkBody` 空态：两行文案 + 「重试查询」。
- (void)renderWorkEmpty:(NSDictionary *)json {
    [self clearFields];
    self.openWorksBtn.hidden = YES;
    self.refreshBtn.title = RLPTr(@"重试查询");
    self.status.stringValue = RLPTr(@"未在 Discogs 检索到该作品的演绎版本（可能网络不可达或作品名不匹配）。");
    NSString *who = self.composer.length
        ? [NSString stringWithFormat:@"%@ · %@", self.name, self.composer] : self.name;
    self.workHintSub.stringValue = [NSString stringWithFormat:@"%@：%@", RLPTr(@"作品"), who];
    self.workHintSub.hidden = NO;
    // 后端给了错误串就一并显示，避免"什么都没说"（web 的 error 态也是原文展示）。
    NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : @"";
    if (err.length && ![err isEqualToString:@"no fixture"])
        self.status.toolTip = err;
}

- (void)onOpenWorksPage:(id)sender {
    (void)sender;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenWorksNotification"
        object:@{@"title": self.name ?: @"", @"composer": self.composer ?: @""}];
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
