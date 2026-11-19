// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPWorksViewController.mm — 古典作品 · 演绎版本（对齐 web loadWorksView）
//
// 后端契约：GET /api/entity/versions?kind=work&name=…[&composer=…][&refresh=1]
//   → { ok, performances:[{title,year,label,format,conductor,orchestra,ensemble,
//                          soloists,performers,other,url,dedup}],
//       distinctCount, releaseCount, from_cache, generated_at, offline, errors[] }
//
// 两道过期守卫（web 261023-01 #4 / 261023-03 第4条的真凶）：
//   ① 页面已切走（self.isActive==NO）⟹ 丢弃回调，绝不写 UI；
//   ② 同一页内连点 ⟹ 请求序号只认最后一次。
// 数字全部来自后端，不足 5 条如实提示「未做臆造」，绝不编造版本。
#import "RLPWorksViewController.h"
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

@interface RLPWorksViewController ()
@property (nonatomic, strong) NSTextField *titleField;
@property (nonatomic, strong) NSTextField *composerField;
@property (nonatomic, strong) NSButton *backNpBtn;
@property (nonatomic, strong) NSStackView *resultStack;
@property (nonatomic, strong) NSTextField *headTitle;
@property (nonatomic, strong) NSTextField *headSub;
@property (nonatomic, assign) NSUInteger reqSeq;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, copy) NSString *lastTitle;
@property (nonatomic, copy) NSString *lastComposer;
@property (nonatomic, strong) NSMutableArray<NSTextField *> *dynamicLabels;
@property (nonatomic, copy) NSArray<NSArray<NSString *> *> *sampleData;
@property (nonatomic, strong) NSTextField *bigTitleLabel;
@property (nonatomic, strong) NSTextField *descLabel;
@property (nonatomic, strong) NSTextField *workTitleCaption;
@property (nonatomic, strong) NSTextField *composerCaption;
@property (nonatomic, strong) NSButton *searchBtn;
@property (nonatomic, strong) NSButton *refreshBtn;
@property (nonatomic, strong) NSTextField *chipLabel;
@property (nonatomic, strong) NSMutableArray<NSButton *> *sampleButtons;
@property (nonatomic, copy, nullable) NSDictionary *lastJSON;
@end

@implementation RLPWorksViewController

- (instancetype)init {
    self = [super initWithTitle:RLPTr(@"古典作品 · 演绎版本")];
    if (self) {
        _dynamicLabels = [NSMutableArray array];
        _lastTitle = @"";
        _lastComposer = @"";
    }
    return self;
}

- (void)buildContent {
    RLPTheme *t = [RLPTheme current];
    NSView *host = self.contentView;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:scroll];

    NSStackView *stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    stack.edgeInsets = NSEdgeInsetsMake(4, 24, 20, 24);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = stack;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:host.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentView.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
    ]];

    // 页内大标题 + 说明（web head() 同口径）
    NSTextField *big = RLPLabel(RLPTr(@"古典作品 · 演绎版本"), t.display, t.hero);
    big.translatesAutoresizingMaskIntoConstraints = NO; big.tag = 0;
    self.bigTitleLabel = big;
    [self.dynamicLabels addObject:big];
    [stack addArrangedSubview:big];
    NSTextField *desc = RLPLabel(RLPTr(@"按作品名查不同指挥/乐团/年代的录音版本"), t.body, t.mut);
    desc.translatesAutoresizingMaskIntoConstraints = NO; desc.tag = 1;
    self.descLabel = desc;
    [self.dynamicLabels addObject:desc];
    [stack addArrangedSubview:desc];

    self.backNpBtn = [NSButton buttonWithTitle:RLPTr(@"← 返回正在播放")
        target:self action:@selector(onBackNp:)];
    self.backNpBtn.bezelStyle = NSBezelStyleRounded;
    self.backNpBtn.identifier = @"works.backnp";
    self.backNpBtn.hidden = YES;
    [stack addArrangedSubview:self.backNpBtn];

    // 搜索卡：作品名 + 作曲家 + 查询/刷新
    NSView *card = [[NSView alloc] initWithFrame:NSZeroRect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.wantsLayer = YES;
    card.layer.cornerRadius = t.rMd;
    card.layer.backgroundColor = t.card.CGColor;
    card.layer.borderWidth = 1;
    card.layer.borderColor = t.hairline.CGColor;
    card.identifier = @"works.searchcard";
    [stack addArrangedSubview:card];
    [NSLayoutConstraint activateConstraints:@[
        [card.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-48],
        [card.heightAnchor constraintEqualToConstant:132],
    ]];

    NSTextField *tl = RLPLabel(RLPTr(@"作品名称"), t.caption, t.mut);
    tl.translatesAutoresizingMaskIntoConstraints = NO; tl.tag = 1;
    self.workTitleCaption = tl;
    NSTextField *cl = RLPLabel(RLPTr(@"作曲家（可选）"), t.caption, t.mut);
    cl.translatesAutoresizingMaskIntoConstraints = NO; cl.tag = 1;
    self.composerCaption = cl;
    [self.dynamicLabels addObjectsFromArray:@[tl, cl]];
    self.titleField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.titleField.placeholderString = RLPTr(@"例如 Boléro / Symphony No. 5");
    self.titleField.identifier = @"works.title";
    self.titleField.target = self;
    self.titleField.action = @selector(onQuery:);
    self.titleField.translatesAutoresizingMaskIntoConstraints = NO;
    self.composerField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.composerField.placeholderString = RLPTr(@"例如 Maurice Ravel / Beethoven");
    self.composerField.identifier = @"works.composer";
    self.composerField.target = self;
    self.composerField.action = @selector(onQuery:);
    self.composerField.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *search = [NSButton buttonWithTitle:RLPTr(@"查询版本") target:self action:@selector(onQuery:)];
    search.bezelStyle = NSBezelStyleRounded;
    search.identifier = @"works.search";
    search.wantsLayer = YES;
    search.layer.backgroundColor = t.accent.CGColor;
    search.layer.cornerRadius = t.rSm;
    search.contentTintColor = NSColor.whiteColor;
    self.searchBtn = search;
    NSButton *refresh = [NSButton buttonWithTitle:RLPTr(@"刷新") target:self action:@selector(onRefreshQuery:)];
    refresh.bezelStyle = NSBezelStyleRounded;
    refresh.identifier = @"works.refresh";
    self.refreshBtn = refresh;
    for (NSView *v in @[tl, cl, self.titleField, self.composerField, search, refresh])
        [card addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [tl.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [tl.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [self.titleField.leadingAnchor constraintEqualToAnchor:tl.leadingAnchor],
        [self.titleField.topAnchor constraintEqualToAnchor:tl.bottomAnchor constant:4],
        [self.titleField.widthAnchor constraintEqualToConstant:260],
        [cl.leadingAnchor constraintEqualToAnchor:self.titleField.trailingAnchor constant:16],
        [cl.topAnchor constraintEqualToAnchor:tl.topAnchor],
        [self.composerField.leadingAnchor constraintEqualToAnchor:cl.leadingAnchor],
        [self.composerField.topAnchor constraintEqualToAnchor:self.titleField.topAnchor],
        [self.composerField.widthAnchor constraintEqualToConstant:240],
        [search.leadingAnchor constraintEqualToAnchor:tl.leadingAnchor],
        [search.topAnchor constraintEqualToAnchor:self.titleField.bottomAnchor constant:12],
        [refresh.leadingAnchor constraintEqualToAnchor:search.trailingAnchor constant:8],
        [refresh.centerYAnchor constraintEqualToAnchor:search.centerYAnchor],
    ]];

    // 示例作品芯片（web chip-work：点了直接检索）
    NSStackView *chips = [[NSStackView alloc] init];
    chips.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    chips.spacing = 8;
    chips.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *chipLabel = RLPLabel(RLPTr(@"示例作品："), t.small, t.mut);
    chipLabel.tag = 1;
    self.chipLabel = chipLabel;
    [self.dynamicLabels addObject:chipLabel];
    [chips addArrangedSubview:chipLabel];
    NSArray<NSArray<NSString *> *> *samples = @[
        @[@"Boléro", @"Maurice Ravel", RLPTr(@"Boléro（拉威尔）")],
        @[@"Symphony No. 5", @"Ludwig van Beethoven", RLPTr(@"贝多芬第五交响曲")],
        @[@"Brandenburg Concerto No. 3", @"Johann Sebastian Bach", RLPTr(@"勃兰登堡协奏曲")],
        @[@"The Four Seasons", @"Antonio Vivaldi", RLPTr(@"四季（维瓦尔第）")],
        @[@"Symphony No. 5", @"Gustav Mahler", RLPTr(@"马勒第五交响曲")],
    ];
    self.sampleButtons = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)samples.count; ++i) {
        NSButton *b = [NSButton buttonWithTitle:samples[i][2] target:self action:@selector(onSampleChip:)];
        b.bezelStyle = NSBezelStyleRounded;
        b.font = t.small;
        b.tag = i;
        b.identifier = [NSString stringWithFormat:@"works.chip.%ld", (long)i];
        [chips addArrangedSubview:b];
        [self.sampleButtons addObject:b];
    }
    [stack addArrangedSubview:chips];
    [chips.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-48].active = YES;
    self.sampleData = samples;

    // 概要头 + 结果容器
    self.headTitle = RLPLabel(@"", t.heading, t.hero);
    self.headTitle.translatesAutoresizingMaskIntoConstraints = NO; self.headTitle.tag = 0;
    self.headSub = RLPLabel(@"", t.small, t.mut);
    self.headSub.translatesAutoresizingMaskIntoConstraints = NO; self.headSub.tag = 1;
    self.headSub.maximumNumberOfLines = 2;
    self.headSub.lineBreakMode = NSLineBreakByWordWrapping;
    [self.dynamicLabels addObjectsFromArray:@[self.headTitle, self.headSub]];
    [stack addArrangedSubview:self.headTitle];
    [stack addArrangedSubview:self.headSub];
    [self.headSub.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-48].active = YES;

    self.resultStack = [[NSStackView alloc] init];
    self.resultStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.resultStack.alignment = NSLayoutAttributeLeading;
    self.resultStack.spacing = 6;
    self.resultStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.resultStack.identifier = @"works.result";
    [stack addArrangedSubview:self.resultStack];
    [self.resultStack.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-48].active = YES;
}

- (void)activate { self.active = YES; [super activate]; }
- (void)viewDidDisappear { self.active = NO; [super viewDidDisappear]; }

- (void)loadWork:(NSString *)title composer:(NSString *)composer fromNowPlaying:(BOOL)fromNp {
    self.titleField.stringValue = title ?: @"";
    self.composerField.stringValue = composer ?: @"";
    self.backNpBtn.hidden = !fromNp;
    self.active = YES;
    if (title.length) [self queryTitle:title composer:composer refresh:NO];
}

- (void)onBackNp:(id)sender {
    (void)sender;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenNowPlayingNotification" object:nil];
}

- (void)onQuery:(id)sender { (void)sender; [self doQueryRefresh:NO]; }
- (void)onRefreshQuery:(id)sender { (void)sender; [self doQueryRefresh:YES]; }

- (void)onSampleChip:(NSButton *)sender {
    NSArray<NSString *> *s = self.sampleData[(NSUInteger)sender.tag];
    self.titleField.stringValue = s[0];
    self.composerField.stringValue = s[1];
    [self queryTitle:s[0] composer:s[1] refresh:NO];
}

- (void)doQueryRefresh:(BOOL)refresh {
    NSString *t = [self.titleField.stringValue stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *c = [self.composerField.stringValue stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!t.length) { RLPToast(RLPTr(@"请输入作品名称")); return; }
    [self queryTitle:t composer:c refresh:refresh];
}

- (void)clearResult {
    for (NSView *v in [self.resultStack.arrangedSubviews copy]) {
        [self.resultStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
}

- (void)showMessage:(NSString *)text {
    [self clearResult];
    RLPTheme *t = [RLPTheme current];
    NSTextField *l = RLPLabel(text, t.body, t.mut);
    l.maximumNumberOfLines = 0;
    l.lineBreakMode = NSLineBreakByWordWrapping;
    [l.widthAnchor constraintEqualToConstant:560].active = YES;
    [self.resultStack addArrangedSubview:l];
}

/// 检索版本。两道守卫：页面已切走 / 请求已过期 ⟹ 整段丢弃（web stillWorks + req 同口径）。
- (void)queryTitle:(NSString *)title composer:(NSString *)composer refresh:(BOOL)refresh {
    if (![RLPCoreClient shared].started) { [self showMessage:RLPTr(@"核心未启动")]; return; }
    self.lastTitle = title;
    self.lastComposer = composer ?: @"";
    const NSUInteger req = ++self.reqSeq;
    [self showMessage:RLPTr(@"正在从 Discogs 检索版本…")];
    NSMutableString *u = [NSMutableString stringWithFormat:@"/api/entity/versions?kind=work&name=%@",
                          RLPEnc(title)];
    if (composer.length) [u appendFormat:@"&composer=%@", RLPEnc(composer)];
    if (refresh) [u appendString:@"&refresh=1"];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:u completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || !self_.active || req != self_.reqSeq) return;   // 双守卫
        [self_ renderResult:json];
    }];
}

- (void)renderResult:(NSDictionary *)json {
    self.lastJSON = json;
    NSArray *perfs = [json[@"performances"] isKindOfClass:[NSArray class]] ? json[@"performances"] : @[];
    const BOOL ok = json && [json[@"ok"] boolValue] && perfs.count > 0;
    RLPTheme *t = [RLPTheme current];
    if (!ok) {
        self.headTitle.stringValue = @"";
        self.headSub.stringValue = @"";
        NSString *err = nil;
        NSArray *errs = [json[@"errors"] isKindOfClass:[NSArray class]] ? json[@"errors"] : nil;
        if (errs.count && [errs[0] isKindOfClass:[NSString class]]) err = errs[0];
        else if ([json[@"error"] isKindOfClass:[NSString class]]) err = json[@"error"];
        if (!err.length) err = RLPTr(@"未在 Discogs 检索到该作品的演绎版本，或当前网络不可达。");
        [self clearResult];
        NSTextField *title = RLPLabel(RLPTr(@"未找到版本或检索失败"), t.body, t.text);
        [self.resultStack addArrangedSubview:title];
        NSTextField *msg = RLPLabel(err, t.small, t.mut);
        msg.maximumNumberOfLines = 0;
        msg.lineBreakMode = NSLineBreakByWordWrapping;
        [msg.widthAnchor constraintEqualToConstant:560].active = YES;
        [self.resultStack addArrangedSubview:msg];
        NSButton *retry = [NSButton buttonWithTitle:RLPTr(@"重试查询") target:self action:@selector(onRefreshQuery:)];
        retry.bezelStyle = NSBezelStyleRounded;
        retry.identifier = @"works.retry";
        [self.resultStack addArrangedSubview:retry];
        return;
    }
    const NSInteger distinct = [json[@"distinctCount"] respondsToSelector:@selector(integerValue)]
        ? [json[@"distinctCount"] integerValue] : (NSInteger)perfs.count;
    const NSInteger releases = [json[@"releaseCount"] respondsToSelector:@selector(integerValue)]
        ? [json[@"releaseCount"] integerValue] : (NSInteger)perfs.count;
    self.headTitle.stringValue = self.lastTitle;
    NSMutableArray<NSString *> *sub = [NSMutableArray array];
    if (self.lastComposer.length)
        [sub addObject:[NSString stringWithFormat:@"%@ %@", RLPTr(@"作曲家:"), self.lastComposer]];
    [sub addObject:([json[@"from_cache"] boolValue] ? RLPTr(@"缓存") : RLPTr(@"Discogs 实时"))];
    [sub addObject:[NSString stringWithFormat:RLPTr(@"不同演绎 %ld / 发行版本 %ld"),
                    (long)distinct, (long)releases]];
    self.headSub.stringValue = [sub componentsJoinedByString:@" · "];

    [self clearResult];
    // 不足 5 条如实提示（web：目标 ≥5，未做臆造）
    if (distinct < 5) {
        NSTextField *hint = RLPLabel([NSString stringWithFormat:
            RLPTr(@"不同演绎仅 %ld 个（目标 ≥5，未做臆造）"), (long)distinct], t.small, t.warn);
        [self.resultStack addArrangedSubview:hint];
    }
    for (id p in perfs) {
        if (![p isKindOfClass:[NSDictionary class]]) continue;
        NSView *row = [[NSView alloc] initWithFrame:NSZeroRect];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        row.wantsLayer = YES;
        row.layer.cornerRadius = t.rSm;
        row.layer.backgroundColor = t.card.CGColor;
        row.layer.borderWidth = 1;
        row.layer.borderColor = t.hairline.CGColor;
        [self.resultStack addArrangedSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.widthAnchor constraintEqualToAnchor:self.resultStack.widthAnchor],
            [row.heightAnchor constraintEqualToConstant:74],
        ]];
        NSString *title = [p[@"title"] isKindOfClass:[NSString class]] ? p[@"title"] : @"";
        NSString *year = [p[@"year"] respondsToSelector:@selector(integerValue)] && [p[@"year"] integerValue] > 0
            ? [NSString stringWithFormat:@"%ld", (long)[p[@"year"] integerValue]] : @"";
        NSString *label = [p[@"label"] isKindOfClass:[NSString class]] ? p[@"label"] : @"";
        NSString *format = [p[@"format"] isKindOfClass:[NSString class]] ? p[@"format"] : @"";
        NSMutableArray<NSString *> *line1 = [NSMutableArray array];
        if (year.length) [line1 addObject:year];
        if (label.length) [line1 addObject:label];
        if (format.length) [line1 addObject:format];
        NSMutableArray<NSString *> *line2 = [NSMutableArray array];
        for (NSString *k in @[@"conductor", @"orchestra", @"ensemble", @"soloists", @"performers", @"other"]) {
            NSString *v = [p[k] isKindOfClass:[NSString class]] ? p[k] : @"";
            if (v.length) [line2 addObject:v];
        }
        NSTextField *l1 = RLPLabel(title.length ? title : RLPTr(@"（未命名版本）"), t.body, t.text);
        l1.translatesAutoresizingMaskIntoConstraints = NO;
        l1.lineBreakMode = NSLineBreakByTruncatingTail;
        NSTextField *l2 = RLPLabel([line1 componentsJoinedByString:@" · "], t.small, t.accentText);
        l2.translatesAutoresizingMaskIntoConstraints = NO;
        l2.lineBreakMode = NSLineBreakByTruncatingTail;
        NSTextField *l3 = RLPLabel([line2 componentsJoinedByString:@" · "], t.small, t.mut);
        l3.translatesAutoresizingMaskIntoConstraints = NO;
        l3.lineBreakMode = NSLineBreakByTruncatingTail;
        for (NSView *v in @[l1, l2, l3]) [row addSubview:v];
        [NSLayoutConstraint activateConstraints:@[
            [l1.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:12],
            [l1.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12],
            [l1.topAnchor constraintEqualToAnchor:row.topAnchor constant:8],
            [l2.leadingAnchor constraintEqualToAnchor:l1.leadingAnchor],
            [l2.trailingAnchor constraintEqualToAnchor:l1.trailingAnchor],
            [l2.topAnchor constraintEqualToAnchor:l1.bottomAnchor constant:2],
            [l3.leadingAnchor constraintEqualToAnchor:l1.leadingAnchor],
            [l3.trailingAnchor constraintEqualToAnchor:l1.trailingAnchor],
            [l3.topAnchor constraintEqualToAnchor:l2.bottomAnchor constant:2],
        ]];
    }
}

- (void)applyTheme {
    [super applyTheme];
    RLPTheme *t = [RLPTheme current];
    for (NSTextField *l in self.dynamicLabels)
        l.textColor = (l.tag == 1) ? t.mut : t.hero;
    // 结果行只重刷颜色，**不重建**（重建会丢掉已检索到的版本数据）。
    for (NSView *row in self.resultStack.arrangedSubviews) {
        if (row.wantsLayer && row.layer.cornerRadius > 0) {
            row.layer.backgroundColor = t.card.CGColor;
            row.layer.borderColor = t.hairline.CGColor;
        }
        NSInteger i = 0;
        for (NSView *v in row.subviews) {
            if (![v isKindOfClass:[NSTextField class]]) continue;
            NSTextField *tf = (NSTextField *)v;
            tf.textColor = (i == 0) ? t.text : (i == 1 ? t.accentText : t.mut);
            ++i;
        }
    }
}

- (void)applyLanguage {
    self.pageTitle = RLPTr(@"古典作品 · 演绎版本");
    if (!self.isViewLoaded) return;
    self.bigTitleLabel.stringValue = RLPTr(@"古典作品 · 演绎版本");
    self.descLabel.stringValue = RLPTr(@"按作品名查不同指挥/乐团/年代的录音版本");
    self.backNpBtn.title = RLPTr(@"← 返回正在播放");
    self.workTitleCaption.stringValue = RLPTr(@"作品名称");
    self.composerCaption.stringValue = RLPTr(@"作曲家（可选）");
    self.titleField.placeholderString = RLPTr(@"例如 Boléro / Symphony No. 5");
    self.composerField.placeholderString = RLPTr(@"例如 Maurice Ravel / Beethoven");
    self.searchBtn.title = RLPTr(@"查询版本");
    self.refreshBtn.title = RLPTr(@"刷新");
    self.chipLabel.stringValue = RLPTr(@"示例作品：");
    NSArray<NSString *> *chipTitles = @[
        @"Boléro（拉威尔）", @"贝多芬第五交响曲", @"勃兰登堡协奏曲", @"四季（维瓦尔第）", @"马勒第五交响曲"
    ];
    for (NSUInteger i = 0; i < self.sampleButtons.count && i < chipTitles.count; ++i) {
        self.sampleButtons[i].title = RLPTr(chipTitles[i]);
    }
    if (self.lastJSON) {
        [self renderResult:self.lastJSON];
    }
}

@end