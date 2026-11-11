// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPSettingsViewController.mm — 设置页（纯 AppKit，页签随模式）
//
// 2026-11-11 用户要求：**两个模式都要有设置页**。
//   专业模式 7 页：播放 / 输入 / 校准 / 流媒体 / 元数据 / 高级 / 诊断
//     （输出/PCM/SDM/均衡在专业工作台当场可切，设置不重复）。
//   聆听模式 11 页：播放 / 输出 / PCM / SDM / 均衡 / 输入 / 校准 / 流媒体 / 元数据 / 高级 / 诊断
//     （没有工作台 ⟹ 四页挂回设置，功能不因模式而不可达）。
//
// 设计取舍（照 web 版设置页的真实结构，不自己发明）：
//   * 页签划分与 web 完全一致（data-g）：输出 / PCM / SDM / 输入 / 高级 / 均衡 / 校准 / 流媒体 / 诊断 / 元数据。
//     外观（主题）按用户 2026-11-11 要求放进「高级」页顶部，**只留 light / dark**，
//     并且只在设置里改 —— 顶栏不再有显式切换按钮。
//   * 所有写入都走 POST /api/settings（后端是**合并写 + 白名单**，不会清空其它键）。
//     只提交用户刚改的那一个键，不整份重发 —— 整份重发会把还没读到的键当成"要清空"。
//   * 只读能力（设备/采样率/滤波/服务器）一律来自既有只读端点，不臆造选项：
//     读不到就显示"读取失败"，不填假数据。
//   * 主题变更走 RLPTheme（发通知，主窗口与所有页面一起重刷）。
#import "RLPSettingsViewController.h"
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPTheme.h"
#import "RLPUpdateWindowController.h"
#import "RLPEqualizerView.h"
#import "RLPInputView.h"
#import "RLPCastView.h"
#import "RLPCalibrationView.h"
#import "RLPFeedbackWindowController.h"
#import "RLPServersView.h"
#import "RLPMetaSourcesView.h"

#pragma mark - 页签定义

// 页签**随模式**（2026-11-11 用户要求：两个模式都要有设置页）：
//   专业模式 7 页：播放 / 输入 / 校准 / 流媒体 / 元数据 / 高级 / 诊断
//     —— 输出/PCM/SDM/均衡的选项在专业工作台当场可切，设置不重复。
//   聆听模式 11 页：播放 / 输出 / PCM / SDM / 均衡 / 输入 / 校准 / 流媒体 / 元数据 / 高级 / 诊断
//     —— 聆听模式没有工作台，这四页必须挂回设置，否则功能不可达（铁律：功能不能删）。
// 页签是**索引 → key 的运行时表**，不再是编译期常量数组：切模式时重建。
typedef NS_ENUM(NSInteger, RLPSTab) {
    RLPSTabPlay = 0, RLPSTabOut, RLPSTabPcm, RLPSTabSdm, RLPSTabEq,
    RLPSTabIn, RLPSTabCal, RLPSTabStream, RLPSTabMeta, RLPSTabAdv, RLPSTabDiag
};

/// 当前模式下的页签 key 顺序（唯一真相源；buildContent/selectPane/currentPaneKey 都从这里取）。
static NSArray<NSString *> *RLPSettingsTabKeys(void) {
    if (RLPCurrentAppMode() == RLPAppModePro)
        return @[ @"play", @"in", @"cal", @"stream", @"meta", @"adv", @"diag" ];
    return @[ @"play", @"out", @"pcm", @"sdm", @"eq", @"in", @"cal", @"stream", @"meta", @"adv", @"diag" ];
}

static NSString *RLPSettingsTabLabel(NSString *key) {
    static NSDictionary *labels;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        labels = @{ @"play": @"播放", @"out": @"输出", @"pcm": @"PCM", @"sdm": @"SDM",
                    @"eq": @"均衡", @"in": @"输入", @"cal": @"校准", @"stream": @"流媒体",
                    @"meta": @"元数据", @"adv": @"高级", @"diag": @"诊断" };
    });
    return labels[key] ?: key;
}

/// key → 枚举（内部 buildPane 分发用）。
static RLPSTab RLPSTabForKey(NSString *key) {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{ @"play": @(RLPSTabPlay), @"out": @(RLPSTabOut), @"pcm": @(RLPSTabPcm),
                 @"sdm": @(RLPSTabSdm), @"eq": @(RLPSTabEq), @"in": @(RLPSTabIn),
                 @"cal": @(RLPSTabCal), @"stream": @(RLPSTabStream), @"meta": @(RLPSTabMeta),
                 @"adv": @(RLPSTabAdv), @"diag": @(RLPSTabDiag) };
    });
    NSNumber *n = map[key];
    return n ? (RLPSTab)n.integerValue : RLPSTabPlay;
}

/// 枚举 → key（currentPaneKey / 模式切换回退用）。
static NSString *RLPSettingsKeyForTab(RLPSTab tab) {
    switch (tab) {
        case RLPSTabPlay:   return @"play";
        case RLPSTabOut:    return @"out";
        case RLPSTabPcm:    return @"pcm";
        case RLPSTabSdm:    return @"sdm";
        case RLPSTabEq:     return @"eq";
        case RLPSTabIn:     return @"in";
        case RLPSTabCal:    return @"cal";
        case RLPSTabStream: return @"stream";
        case RLPSTabMeta:   return @"meta";
        case RLPSTabAdv:    return @"adv";
        case RLPSTabDiag:   return @"diag";
    }
    return @"play";
}

#pragma mark - 小工具

/// 一行「标签 + 控件」，标签等宽（与 web 的 .sfld 同观感）。
static NSStackView *RLPSRow(NSString *label, NSView *control, NSString *hint, RLPTheme *t) {
    NSStackView *row = [[NSStackView alloc] init];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 10;
    row.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *l = RLPLabel(label, t.body, t.text);
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [[l.widthAnchor constraintEqualToConstant:200] setActive:YES];
    [row addArrangedSubview:l];
    [row addArrangedSubview:control];
    if (hint.length) [row addArrangedSubview:RLPLabel(hint, t.small, t.mut)];
    return row;
}

/// 分区标题 + 一句说明（对应 web 的 sgroup）。
static NSView *RLPSGroup(NSString *title, NSString *desc, RLPTheme *t) {
    NSStackView *box = [[NSStackView alloc] init];
    box.orientation = NSUserInterfaceLayoutOrientationVertical;
    box.alignment = NSLayoutAttributeLeading;
    box.spacing = 2;
    [box addArrangedSubview:RLPLabel(title, [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], t.text)];
    if (desc.length) [box addArrangedSubview:RLPLabel(desc, t.small, t.mut)];
    return box;
}

@interface RLPSettingsViewController ()
@property (nonatomic, strong) NSSegmentedControl *tabs;
@property (nonatomic, strong) NSView *paneHost;
@property (nonatomic, assign) RLPSTab tab;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSView *> *paneCache;
/// 已经从后端读到真值的键：没读到之前不写回，避免用 UI 默认值覆盖用户真实设置。
@property (nonatomic, strong) NSMutableSet<NSString *> *loadedKeys;
@property (nonatomic, strong) NSTextField *statusLine;

// 输出
@property (nonatomic, strong) NSPopUpButton *backendPopup;
@property (nonatomic, strong) NSPopUpButton *devicePopup;
@property (nonatomic, strong) NSSwitch *hogSwitch;
@property (nonatomic, strong) NSSlider *volumeSlider;
@property (nonatomic, strong) NSSwitch *loudSwitch;
@property (nonatomic, strong) NSPopUpButton *bitsPopup;
// PCM
@property (nonatomic, strong) NSPopUpButton *ratePopup;
@property (nonatomic, strong) NSPopUpButton *filt1xPopup;
@property (nonatomic, strong) NSPopUpButton *filtNxPopup;
@property (nonatomic, strong) NSSwitch *ispSwitch;
// SDM
@property (nonatomic, strong) NSPopUpButton *dsdRatePopup;
@property (nonatomic, strong) NSPopUpButton *modFamilyPopup;
@property (nonatomic, strong) NSPopUpButton *modOrderPopup;
@property (nonatomic, strong) NSSwitch *directSdmSwitch;
// 输入
@property (nonatomic, strong) NSPopUpButton *inBackendPopup;
@property (nonatomic, strong) NSPopUpButton *inDevicePopup;
@property (nonatomic, strong) NSSwitch *inMonitorSwitch;
// 高级
@property (nonatomic, strong) NSPopUpButton *themePopup;
@property (nonatomic, strong) NSPopUpButton *langPopup;
@property (nonatomic, strong) NSTextField *rootField;
@property (nonatomic, strong) NSSwitch *betaSwitch;
/// 播放时自动分析（autoanl）。1.1.7.1：开关从播放页挪到这里，播放页只留一行分析结果。
@property (nonatomic, strong) NSSwitch *autoAnlSwitch;
@property (nonatomic, strong) NSTextField *attenField;
@property (nonatomic, strong) NSSwitch *streamSwitch;
// 流媒体
@property (nonatomic, strong) RLPServersView *serversView;
// 元数据数据源（动态注册表 + 优先级）
@property (nonatomic, strong) RLPMetaSourcesView *metaSourcesView;
// 元数据
@property (nonatomic, strong) NSSwitch *metaOnSwitch;
@property (nonatomic, strong) NSSwitch *metaLlmSwitch;
@property (nonatomic, strong) NSSwitch *metaSummarySwitch;
@property (nonatomic, strong) NSSwitch *metaAiFillSwitch;
// 已迁移的子界面（均衡 / 输入 / 投放）
@property (nonatomic, strong) RLPEqualizerView *eqView;
@property (nonatomic, strong) RLPInputView *inputView;
@property (nonatomic, strong) RLPCastView *castView;
@property (nonatomic, strong) RLPCalibrationView *calView;
@property (nonatomic, strong) NSTextField *coverProgress;
@property (nonatomic, strong) NSTextField *writebackStatus;
@property (nonatomic, strong) NSButton *wbDryBtn;
@property (nonatomic, strong) NSButton *wbApplyBtn;
/// 写回批次的忙态与轮询（对齐 web WB_BUSY/wbPoll：执行期间禁按钮、800ms 轮询到 done）。
@property (nonatomic, assign) BOOL wbBusy;
@property (nonatomic, strong) NSTimer *wbTimer;
@property (nonatomic, strong) NSTimer *coverTimer;
// LLM（AI 资料层用的模型端点）
@property (nonatomic, strong) NSTextField *llmBase;
@property (nonatomic, strong) NSSecureTextField *llmKey;
@property (nonatomic, strong) NSTextField *llmModel;
/// /api/llm/models 拉到列表时显示下拉（选中即保存）；拉不到时隐藏，保留手填框。
@property (nonatomic, strong) NSPopUpButton *llmModelPopup;
@property (nonatomic, strong) NSButton *llmModelRefresh;
@property (nonatomic, strong) NSTextField *llmModelMsg;
@property (nonatomic, strong) NSTextField *llmStatus;
@end

@implementation RLPSettingsViewController

- (instancetype)init {
    self = [super initWithTitle:RLPTr(@"设置")];
    if (self) {
        _paneCache = [NSMutableDictionary dictionary];
        _loadedKeys = [NSMutableSet set];
        _tab = RLPSTabPlay;
        // 模式切换时页签集合会变（聆听 11 页 / 专业 7 页）。设置页是缓存页，
        // 不监听的话切模式后页签还停在旧集合上。
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onAppModeChanged:)
                                                     name:RLPAppModeDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_wbTimer invalidate];
    [_coverTimer invalidate];
}

- (void)onAppModeChanged:(NSNotification *)note {
    (void)note;
    if (!self.tabs) return;   // 视图还没建：buildContent 自会按当前模式建
    // 当前页在新模式里没有（专业模式下的 out/pcm/sdm/eq）⟹ 回「播放」。
    NSString *curKey = RLPSettingsKeyForTab(self.tab);
    if (![RLPSettingsTabKeys() containsObject:curKey]) _tab = RLPSTabPlay;
    [self rebuildTabs];
    [self reloadData];
}

#pragma mark - 骨架

- (void)buildContent {
    RLPTheme *t = [RLPTheme current];
    NSView *host = self.contentView;

    self.tabs = [[NSSegmentedControl alloc] initWithFrame:NSZeroRect];
    self.tabs.trackingMode = NSSegmentSwitchTrackingSelectOne;
    self.tabs.target = self;
    self.tabs.action = @selector(onTabChanged:);
    self.tabs.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.tabs];
    [self rebuildTabs];

    self.paneHost = [[NSView alloc] initWithFrame:NSZeroRect];
    self.paneHost.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.paneHost];

    self.statusLine = RLPLabel(@"", t.small, t.mut);
    self.statusLine.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.statusLine];

    [NSLayoutConstraint activateConstraints:@[
        [self.tabs.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:24],
        [self.tabs.trailingAnchor constraintLessThanOrEqualToAnchor:host.trailingAnchor constant:-24],
        [self.tabs.topAnchor constraintEqualToAnchor:host.topAnchor constant:10],
        [self.paneHost.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [self.paneHost.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [self.paneHost.topAnchor constraintEqualToAnchor:self.tabs.bottomAnchor constant:12],
        [self.paneHost.bottomAnchor constraintEqualToAnchor:self.statusLine.topAnchor constant:-6],
        [self.statusLine.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:24],
        [self.statusLine.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-24],
        [self.statusLine.bottomAnchor constraintEqualToAnchor:host.bottomAnchor constant:-10],
    ]];

    [self showTab:self.tab];
}

/// 按当前模式重建页签集合（聆听 11 页 / 专业 7 页），并保持当前页选中。
- (void)rebuildTabs {
    NSArray<NSString *> *keys = RLPSettingsTabKeys();
    self.tabs.segmentCount = (NSInteger)keys.count;
    for (NSInteger i = 0; i < (NSInteger)keys.count; ++i)
        [self.tabs setLabel:RLPTr(RLPSettingsTabLabel(keys[i])) forSegment:i];
    NSUInteger idx = [keys indexOfObject:RLPSettingsKeyForTab(self.tab)];
    self.tabs.selectedSegment = (idx == NSNotFound) ? 0 : (NSInteger)idx;
}

- (void)onTabChanged:(id)sender {
    NSArray<NSString *> *keys = RLPSettingsTabKeys();
    NSInteger sel = self.tabs.selectedSegment;
    if (sel < 0 || sel >= (NSInteger)keys.count) return;
    [self showTab:RLPSTabForKey(keys[sel])];
}

- (void)selectPane:(NSString *)key {
    NSString *k = key;
    NSArray<NSString *> *keys = RLPSettingsTabKeys();
    // 专业模式：out/pcm/sdm/eq 的选项在工作台，老入口发这些 key 时映射到「播放」。
    // 聆听模式：四页就在设置里，直接切过去（不再映射）。
    if (![keys containsObject:k] &&
        ([k isEqualToString:@"out"] || [k isEqualToString:@"pcm"] ||
         [k isEqualToString:@"sdm"] || [k isEqualToString:@"eq"])) k = @"play";
    NSUInteger idx = [keys indexOfObject:k];
    if (idx == NSNotFound) return;
    self.tabs.selectedSegment = (NSInteger)idx;
    [self showTab:RLPSTabForKey(k)];
}

- (NSString *)currentPaneKey {
    return RLPSettingsKeyForTab(self.tab);
}

- (void)showTab:(RLPSTab)tab {
    self.tab = tab;
    NSView *pane = self.paneCache[@(tab)];
    BOOL freshlyBuilt = NO;
    if (!pane) {
        pane = [self buildPane:tab];
        if (!pane) return;
        self.paneCache[@(tab)] = pane;
        freshlyBuilt = YES;
    }
    for (NSView *v in self.paneHost.subviews) [v removeFromSuperview];
    pane.translatesAutoresizingMaskIntoConstraints = NO;
    [self.paneHost addSubview:pane];
    [NSLayoutConstraint activateConstraints:@[
        [pane.leadingAnchor constraintEqualToAnchor:self.paneHost.leadingAnchor],
        [pane.trailingAnchor constraintEqualToAnchor:self.paneHost.trailingAnchor],
        [pane.topAnchor constraintEqualToAnchor:self.paneHost.topAnchor],
        [pane.bottomAnchor constraintEqualToAnchor:self.paneHost.bottomAnchor],
    ]];
    // 新建的页签控件还是 UI 默认值（设备/滤波下拉是空的、开关是默认态）。
    // activate 只在进页时跑一次，之后才点开的页签必须在这里补一次读回，
    // 否则输出/PCM/SDM 页会显示空下拉与默认值，而不是用户真实设置。
    if (freshlyBuilt && [RLPCoreClient shared].started) [self reloadData];
}

/// 每个页签 = 一个纵向滚动的 NSStackView。
- (NSView *)buildPane:(RLPSTab)tab {
    RLPTheme *t = [RLPTheme current];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;

    NSStackView *stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 14;
    stack.edgeInsets = NSEdgeInsetsMake(6, 24, 24, 24);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    NSView *spacer = [[NSView alloc] initWithFrame:NSZeroRect];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
    [spacer setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
    scroll.documentView = stack;
    // contentView 默认与可视区同高，内容少时 stack 会被垂直居中（离屏截图实测：
    // 播放页只有三行，结果整块被推到窗口底部）。让 stack 至少撑满可视高度即可顶对齐。
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentView.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
        [stack.heightAnchor constraintGreaterThanOrEqualToAnchor:scroll.contentView.heightAnchor],
        // NSStackView 在"被拉高但内容少"时会把行间距均分（实测：三行控件被推到窗口底）。
        // 末尾加一个可伸展的空白占位，把真实内容压在顶部。
        [spacer.heightAnchor constraintGreaterThanOrEqualToConstant:0],
    ]];

    switch (tab) {
        case RLPSTabPlay:   [self fillPlayback:stack t:t]; break;
        case RLPSTabOut:    [self fillOutput:stack t:t]; break;
        case RLPSTabPcm:    [self fillPcm:stack t:t]; break;
        case RLPSTabSdm:    [self fillSdm:stack t:t]; break;
        case RLPSTabEq:     [self fillEqualizer:stack t:t]; break;
        case RLPSTabIn:     [self fillInputReal:stack t:t]; break;
        case RLPSTabCal:    [self fillCalibration:stack t:t]; break;
        case RLPSTabStream: [self fillStream:stack t:t]; break;
        case RLPSTabMeta:   [self fillMeta:stack t:t]; break;
        case RLPSTabAdv:    [self fillAdvanced:stack t:t]; break;
        case RLPSTabDiag:   [self fillDiag:stack t:t]; break;
    }
    // 占位放在**所有真实内容之后**，才能把内容压到顶部（放前面会占住顶部）。
    [stack addArrangedSubview:spacer];
    return scroll;
}

/// 尚未迁移的子界面：如实说明，不假装已实现（PLAN.md §0 的硬约束）。
- (void)fillPlaceholder:(NSStackView *)stack t:(RLPTheme *)t reason:(NSString *)reason {
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"迁移中"), reason, t)];
}

#pragma mark - 通用控件构造

- (NSPopUpButton *)popupWithItems:(NSArray<NSString *> *)items action:(SEL)action {
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSString *s in items) [p addItemWithTitle:s];
    p.target = self;
    p.action = action;
    p.translatesAutoresizingMaskIntoConstraints = NO;
    [[p.widthAnchor constraintEqualToConstant:240] setActive:YES];
    return p;
}

- (NSSwitch *)switchWithAction:(SEL)action key:(NSString *)key {
    NSSwitch *s = [[NSSwitch alloc] initWithFrame:NSZeroRect];
    s.target = self;
    s.action = action;
    s.identifier = key;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    return s;
}

/// 提交单个键。**只提交这一个** —— 后端合并写，未提交的键保持原值。
- (void)postKey:(NSString *)key value:(NSString *)value {
    if (!key.length) return;
    [self.loadedKeys addObject:key];
    NSString *body = [NSString stringWithFormat:@"%@=%@", key, RLPEnc(value ?: @"")];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/settings" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            self_.statusLine.stringValue = [NSString stringWithFormat:@"%@ %@ = %@", RLPTr(@"已保存"), key, value];
        } else {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"保存失败");
            self_.statusLine.stringValue = err;
            RLPToast(err);
        }
    }];
}

- (void)onAtten:(NSTextField *)sender {
    [self postKey:@"atten" value:sender.stringValue];
}

- (void)onSwitch:(NSSwitch *)sender {
    NSString *key = sender.identifier;
    if (!key.length) return;
    [self postKey:key value:(sender.state == NSControlStateValueOn ? @"1" : @"0")];
}

- (void)applyKV:(NSDictionary *)kv toSwitch:(NSSwitch *)sw key:(NSString *)key {
    if (!sw) return;
    id v = kv[key];
    if (![v respondsToSelector:@selector(boolValue)]) return;
    sw.state = [v boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    [self.loadedKeys addObject:key];
}

- (void)applyKV:(NSDictionary *)kv toPopup:(NSPopUpButton *)pop key:(NSString *)key {
    if (!pop) return;
    id v = kv[key];
    if (![v isKindOfClass:[NSString class]]) return;
    NSString *s = v;
    if (!s.length) return;
    if ([pop itemWithTitle:s]) [pop selectItemWithTitle:s];
    [self.loadedKeys addObject:key];
}

#pragma mark - 输出

/// 播放：听感项（音量/响度补偿/预衰减）。
/// 专业模式下输出/升频/滤波/DSD/EQ 在工作台当场可切，这里不重复；
/// 聆听模式下它们在设置的其余页签里（说明文案随模式，不误导用户去找不存在的工作台）。
- (void)fillPlayback:(NSStackView *)stack t:(RLPTheme *)t {
    NSString *desc = (RLPCurrentAppMode() == RLPAppModePro)
        ? RLPTr(@"输出设备 / 独占 / 升频 / 滤波 / DSD / 均衡都在「专业工作台」当场切换，这里只放它没有的项。")
        : RLPTr(@"音量 / 响度补偿 / 预衰减；输出、升频、滤波、DSD 与均衡在上方页签里切换。");
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"播放"), desc, t)];

    self.volumeSlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    self.volumeSlider.minValue = -60;
    self.volumeSlider.maxValue = 0;
    self.volumeSlider.doubleValue = -12;
    self.volumeSlider.continuous = NO;
    self.volumeSlider.target = self;
    self.volumeSlider.action = @selector(onVolume:);
    self.volumeSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [[self.volumeSlider.widthAnchor constraintEqualToConstant:240] setActive:YES];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"音量 (dB)"), self.volumeSlider, nil, t)];

    self.loudSwitch = [self switchWithAction:@selector(onSwitch:) key:@"loudness"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"响度补偿"), self.loudSwitch,
        RLPTr(@"按等响曲线补偿小音量下的低频与高频"), t)];

    self.attenField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.attenField.placeholderString = RLPTr(@"例如 -3");
    self.attenField.translatesAutoresizingMaskIntoConstraints = NO;
    [[self.attenField.widthAnchor constraintEqualToConstant:120] setActive:YES];
    self.attenField.target = self;
    self.attenField.action = @selector(onAtten:);
    [stack addArrangedSubview:RLPSRow(RLPTr(@"预衰减 (dB)"), self.attenField,
        RLPTr(@"整体降一点电平，给 EQ 提升留余量"), t)];
}

/// 输出页：聆听模式挂页签；专业模式不挂（选项在工作台当场可切），实现保留共用。
- (void)fillOutput:(NSStackView *)stack t:(RLPTheme *)t {
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"输出后端"),
        RLPTr(@"独占 = bit-perfect；共享 = 兼容性最好（虚拟机 / 远程桌面）"), t)];

    self.backendPopup = [self popupWithItems:@[ @"coreaudio", @"coreaudio-shared" ] action:@selector(onBackend:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"后端"), self.backendPopup, nil, t)];

    self.devicePopup = [self popupWithItems:@[ RLPTr(@"默认音频设备") ] action:@selector(onDevice:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"输出设备"), self.devicePopup, nil, t)];

    self.hogSwitch = [self switchWithAction:@selector(onSwitch:) key:@"hogexcl"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"严格独占"), self.hogSwitch,
        RLPTr(@"勾选后系统音量条失效，请用本程序音量条"), t)];

    self.volumeSlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    self.volumeSlider.minValue = -60;
    self.volumeSlider.maxValue = 0;
    self.volumeSlider.doubleValue = -12;
    self.volumeSlider.continuous = NO;
    self.volumeSlider.target = self;
    self.volumeSlider.action = @selector(onVolume:);
    self.volumeSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [[self.volumeSlider.widthAnchor constraintEqualToConstant:240] setActive:YES];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"音量 (dB)"), self.volumeSlider, nil, t)];

    self.loudSwitch = [self switchWithAction:@selector(onSwitch:) key:@"loudness"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"响度补偿"), self.loudSwitch, nil, t)];

    self.bitsPopup = [self popupWithItems:@[ RLPTr(@"自动"), @"16", @"24", @"32" ] action:@selector(onBits:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"位深"), self.bitsPopup, RLPTr(@"自动 = 跟随源文件"), t)];
}

#pragma mark - PCM

- (void)fillPcm:(NSStackView *)stack t:(RLPTheme *)t {
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"升频与滤波"), RLPTr(@"poly-sinc 滤波器家族"), t)];
    self.ratePopup = [self popupWithItems:@[ RLPTr(@"跟随源"), @"44100", @"88200", @"176400",
                                             @"352800", @"705600", @"48000", @"96000", @"192000",
                                             @"384000", @"768000" ] action:@selector(onRate:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"目标采样率"), self.ratePopup, nil, t)];

    self.filt1xPopup = [self popupWithItems:@[ RLPTr(@"读取中…") ] action:@selector(onFilter1x:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"1x 滤波器"), self.filt1xPopup,
        RLPTr(@"44.1 / 48 kHz 音源使用"), t)];
    self.filtNxPopup = [self popupWithItems:@[ RLPTr(@"读取中…") ] action:@selector(onFilterNx:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"Nx 滤波器"), self.filtNxPopup,
        RLPTr(@"88.2 kHz 及以上音源使用"), t)];

    self.ispSwitch = [self switchWithAction:@selector(onSwitch:) key:@"isp"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"ISP 扫描"), self.ispSwitch,
        RLPTr(@"过采样峰值预衰减，防止升频后削波"), t)];
}

#pragma mark - SDM

- (void)fillSdm:(NSStackView *)stack t:(RLPTheme *)t {
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"SDM 输出"), RLPTr(@"只在输出 DSD 时生效"), t)];
    self.dsdRatePopup = [self popupWithItems:@[ RLPTr(@"不升频"), @"dsd64", @"dsd128", @"dsd256", @"dsd512" ]
                                      action:@selector(onDsdRate:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"DSD 目标"), self.dsdRatePopup, nil, t)];

    self.modFamilyPopup = [self popupWithItems:@[ @"dsd", @"pcm" ] action:@selector(onModFamily:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"调制器族"), self.modFamilyPopup, nil, t)];

    self.modOrderPopup = [self popupWithItems:@[ @"5", @"7" ] action:@selector(onModOrder:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"调制器阶数"), self.modOrderPopup, nil, t)];

    self.directSdmSwitch = [self switchWithAction:@selector(onSwitch:) key:@"directsdm"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"直接 SDM"), self.directSdmSwitch, nil, t)];
}

#pragma mark - 输入

- (void)fillInput:(NSStackView *)stack t:(RLPTheme *)t {
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"输入设备与采集"),
        RLPTr(@"CoreAudio 采集 / 录制与直通监听"), t)];
    self.inBackendPopup = [self popupWithItems:@[ @"none", @"coreaudio", @"coreaudio-shared" ]
                                        action:@selector(onInBackend:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"输入后端"), self.inBackendPopup, nil, t)];

    self.inDevicePopup = [self popupWithItems:@[ RLPTr(@"默认输入设备") ] action:@selector(onInDevice:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"输入设备"), self.inDevicePopup, nil, t)];

    self.inMonitorSwitch = [self switchWithAction:@selector(onSwitch:) key:@"inmon"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"直通监听"), self.inMonitorSwitch,
        RLPTr(@"开启后输入会被送到输出设备，请注意电平和回声"), t)];
}

#pragma mark - 高级（外观 + 音乐库 + 更新 + 流式解码）

- (void)fillAdvanced:(NSStackView *)stack t:(RLPTheme *)t {
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"外观"),
        RLPTr(@"主题只有深色与浅色两种；改这里立即生效"), t)];

    self.themePopup = [self popupWithItems:@[ RLPTr(@"深色"), RLPTr(@"浅色") ] action:@selector(onTheme:)];
    NSString *cur = [RLPTheme themeName];
    [self.themePopup selectItemAtIndex:[cur isEqualToString:@"light"] ? 1 : 0];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"主题"), self.themePopup, nil, t)];

    self.langPopup = [self popupWithItems:@[ RLPTr(@"中文"), @"English" ] action:@selector(onLanguage:)];
    [self.langPopup selectItemAtIndex:[RLPLanguage() isEqualToString:@"en"] ? 1 : 0];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"语言"), self.langPopup,
        RLPTr(@"切换后需重开窗口生效"), t)];

    // 分析（1.1.7.1）：播放页不再摆开关，真相源在这里（键 autoanl，与 web 版同一个）。
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"音频分析"),
        RLPTr(@"开启后每首本地曲目播放时自动分析一次（动态 / 音质 / 假无损）。分析是整曲解码，较吃 CPU。"), t)];
    self.autoAnlSwitch = [self switchWithAction:@selector(onSwitch:) key:@"autoanl"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"播放时自动分析"), self.autoAnlSwitch,
        RLPTr(@"关闭时可在播放页展开分析详情后手动分析"), t)];

    [stack addArrangedSubview:RLPSGroup(RLPTr(@"音乐库"), nil, t)];
    self.rootField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.rootField.placeholderString = RLPTr(@"例如 /Volumes/Music");
    self.rootField.translatesAutoresizingMaskIntoConstraints = NO;
    [[self.rootField.widthAnchor constraintEqualToConstant:360] setActive:YES];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"音乐目录"), self.rootField, nil, t)];

    NSStackView *btns = [[NSStackView alloc] init];
    btns.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    btns.spacing = 8;
    NSArray<NSArray<NSString *> *> *acts = @[ @[ RLPTr(@"增量扫描"), @"scan0" ],
                                              @[ RLPTr(@"全量重扫"), @"scan1" ],
                                              @[ RLPTr(@"清理缺失"), @"prune" ] ];
    for (NSArray<NSString *> *pair in acts) {
        NSButton *b = [NSButton buttonWithTitle:pair[0] target:self action:@selector(onLibraryAction:)];
        b.bezelStyle = NSBezelStyleRounded;
        b.identifier = pair[1];
        [btns addArrangedSubview:b];
    }
    [stack addArrangedSubview:btns];

    // 封面补齐：后端立即返回、网络在后台跑，所以必须给进度，否则用户以为卡死
    NSStackView *covRow = [[NSStackView alloc] init];
    covRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    covRow.spacing = 8;
    NSButton *covBtn = [NSButton buttonWithTitle:RLPTr(@"联网补齐封面") target:self
                                          action:@selector(onCoverPrefetch:)];
    covBtn.bezelStyle = NSBezelStyleRounded;
    [covRow addArrangedSubview:covBtn];
    self.coverProgress = RLPLabel(@"", t.small, t.mut);
    [covRow addArrangedSubview:self.coverProgress];
    [stack addArrangedSubview:covRow];

    // 标签写回：先 dry 预览再执行（后端有 PCM 逐位门禁，不能跳过预览直接写）
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"标签写回"),
        RLPTr(@"把补全到的标签写回文件。先看预览，确认后再执行。"), t)];
    NSStackView *wbRow = [[NSStackView alloc] init];
    wbRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    wbRow.spacing = 8;
    NSButton *wbDry = [NSButton buttonWithTitle:RLPTr(@"预览") target:self action:@selector(onWritebackDry:)];
    wbDry.bezelStyle = NSBezelStyleRounded;
    wbDry.identifier = @"wb.dry";
    NSButton *wbApply = [NSButton buttonWithTitle:RLPTr(@"执行写回") target:self action:@selector(onWritebackApply:)];
    wbApply.bezelStyle = NSBezelStyleRounded;
    wbApply.identifier = @"wb.apply";
    self.wbDryBtn = wbDry;
    self.wbApplyBtn = wbApply;
    [wbRow addArrangedSubview:wbDry];
    [wbRow addArrangedSubview:wbApply];
    [stack addArrangedSubview:wbRow];
    self.writebackStatus = RLPLabel(@"", t.small, t.mut);
    self.writebackStatus.maximumNumberOfLines = 3;
    self.writebackStatus.lineBreakMode = NSLineBreakByWordWrapping;
    [[self.writebackStatus.widthAnchor constraintEqualToConstant:560] setActive:YES];
    [stack addArrangedSubview:self.writebackStatus];

    [stack addArrangedSubview:RLPSGroup(RLPTr(@"软件更新"), nil, t)];
    NSStackView *upRow = [[NSStackView alloc] init];
    upRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    upRow.spacing = 8;
    NSButton *check = [NSButton buttonWithTitle:RLPTr(@"检查更新") target:self action:@selector(onCheckUpdate:)];
    check.bezelStyle = NSBezelStyleRounded;
    [upRow addArrangedSubview:check];
    self.betaSwitch = [self switchWithAction:@selector(onSwitch:) key:@"updbeta"];
    [upRow addArrangedSubview:self.betaSwitch];
    [upRow addArrangedSubview:RLPLabel(RLPTr(@"接收测试版"), t.small, t.mut)];
    [stack addArrangedSubview:upRow];

    [stack addArrangedSubview:RLPSGroup(RLPTr(@"流式解码"),
        RLPTr(@"超大文件边下边解，避免先整份读入内存"), t)];
    self.streamSwitch = [self switchWithAction:@selector(onSwitch:) key:@"streamdecode"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"启用流式解码"), self.streamSwitch, nil, t)];
}

#pragma mark - 流媒体

- (void)fillStream:(NSStackView *)stack t:(RLPTheme *)t {
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"流媒体服务器"),
        RLPTr(@"可保存多台，同一时刻启用一台；只取原始文件，不转码"), t)];
    // 2026-11-12：增删改/启用/测试补齐（对齐 web SRC 区块），不再只读。
    self.serversView = [[RLPServersView alloc] initWithFrame:NSMakeRect(0, 0, 620, 240)];
    self.serversView.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:self.serversView];
    [NSLayoutConstraint activateConstraints:@[
        [self.serversView.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-4],
    ]];
    [self.serversView reload];

    // 投放（AirPlay / UPnP）：与 web 版设置→流媒体页的推送区块同源
    self.castView = [[RLPCastView alloc] initWithFrame:NSMakeRect(0, 0, 560, 200)];
    self.castView.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:self.castView];
    [NSLayoutConstraint activateConstraints:@[
        [self.castView.heightAnchor constraintEqualToConstant:200],
        [self.castView.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-4],
    ]];
    [self.castView reload];
}

#pragma mark - 诊断

- (void)fillDiag:(NSStackView *)stack t:(RLPTheme *)t {
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"诊断包"),
        RLPTr(@"一个 zip 打包全部日志 / 系统信息 / 设置摘要（已脱敏）"), t)];
    NSButton *zip = [NSButton buttonWithTitle:RLPTr(@"导出诊断包（.zip）") target:self
                                       action:@selector(onExportDiagZip:)];
    zip.bezelStyle = NSBezelStyleRounded;
    [stack addArrangedSubview:zip];
    [stack addArrangedSubview:RLPLabel(
        RLPTr(@"包内：rlplayer-diag.json、rlplayer-playback.log、launcher.log、"
              @"settings-summary.txt；api_key / token / password 一律脱敏。"), t.small, t.mut)];

    [stack addArrangedSubview:RLPSGroup(RLPTr(@"反馈"), nil, t)];
    NSButton *fb = [NSButton buttonWithTitle:RLPTr(@"打开反馈窗口") target:self
                                      action:@selector(onOpenFeedback:)];
    fb.bezelStyle = NSBezelStyleRounded;
    [stack addArrangedSubview:fb];
    [stack addArrangedSubview:RLPLabel(
        RLPTr(@"反馈会连同版本与系统信息提交到后台；附诊断包时内容已脱敏。"), t.small, t.mut)];
}

#pragma mark - 元数据

- (void)fillMeta:(NSStackView *)stack t:(RLPTheme *)t {
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"元数据补全"),
        RLPTr(@"播放时后台补全标签 / 封面 / 歌词，结果落在本地库"), t)];
    self.metaOnSwitch = [self switchWithAction:@selector(onSwitch:) key:@"metaon"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"自动补全"), self.metaOnSwitch,
        RLPTr(@"只用公开数据源，不调用 AI，不产生费用"), t)];
    self.metaLlmSwitch = [self switchWithAction:@selector(onSwitch:) key:@"metallm"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"允许 AI 辅助"), self.metaLlmSwitch, nil, t)];
    self.metaSummarySwitch = [self switchWithAction:@selector(onSwitch:) key:@"metasummary"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"AI 综合简介"), self.metaSummarySwitch, nil, t)];
    self.metaAiFillSwitch = [self switchWithAction:@selector(onSwitch:) key:@"metaaifill"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"AI 补封面歌词"), self.metaAiFillSwitch, nil, t)];

    // 数据源开关 + 优先级（对齐 web sp_metasrc：按注册表动态渲染，新增源前端零改动）。
    self.metaSourcesView = [[RLPMetaSourcesView alloc] initWithFrame:NSMakeRect(0, 0, 620, 200)];
    self.metaSourcesView.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:self.metaSourcesView];
    [NSLayoutConstraint activateConstraints:@[
        [self.metaSourcesView.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-4],
    ]];
    [self.metaSourcesView reload];

    // AI 模型端点：密钥红线 —— GET 只回掩码，输入框留空 = 不改已存的 key
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"AI 模型端点"),
        RLPTr(@"用于资料整理与简介。密钥只在本机保存，界面永不回显明文；留空表示不修改。"), t)];

    self.llmBase = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.llmBase.placeholderString = @"https://api.deepseek.com";
    [[self.llmBase.widthAnchor constraintEqualToConstant:320] setActive:YES];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"接口地址"), self.llmBase, nil, t)];

    self.llmModel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.llmModel.placeholderString = @"deepseek-chat";
    [[self.llmModel.widthAnchor constraintEqualToConstant:220] setActive:YES];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"模型"), self.llmModel, nil, t)];

    // 模型下拉（对齐 web llmModelRender）：拉到 /api/llm/models 就显示动态列表并「选中即保存」；
    // 拉不到自动降级到上面的手填框 + 如实写出原因，绝不因网关缺 /models 而崩。
    self.llmModelPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.llmModelPopup.target = self;
    self.llmModelPopup.action = @selector(onLlmModelPicked:);
    self.llmModelPopup.identifier = @"llm.modelpopup";
    self.llmModelPopup.hidden = YES;
    [self.llmModelPopup.widthAnchor constraintEqualToConstant:320].active = YES;
    self.llmModelRefresh = [NSButton buttonWithTitle:RLPTr(@"刷新模型列表")
        target:self action:@selector(onLlmModelRefresh:)];
    self.llmModelRefresh.bezelStyle = NSBezelStyleRounded;
    self.llmModelRefresh.identifier = @"llm.modelrefresh";
    NSStackView *modelRow = [[NSStackView alloc] init];
    modelRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    modelRow.spacing = 8;
    [modelRow addArrangedSubview:self.llmModelPopup];
    [modelRow addArrangedSubview:self.llmModelRefresh];
    [stack addArrangedSubview:modelRow];

    self.llmModelMsg = RLPLabel(RLPTr(@"模型列表读取中"), t.small, t.mut);
    self.llmModelMsg.maximumNumberOfLines = 2;
    self.llmModelMsg.lineBreakMode = NSLineBreakByWordWrapping;
    self.llmModelMsg.identifier = @"llm.modelmsg";
    [[self.llmModelMsg.widthAnchor constraintEqualToConstant:560] setActive:YES];
    [stack addArrangedSubview:self.llmModelMsg];

    self.llmKey = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    self.llmKey.placeholderString = RLPTr(@"留空 = 保持已保存的密钥");
    [[self.llmKey.widthAnchor constraintEqualToConstant:320] setActive:YES];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"密钥"), self.llmKey, nil, t)];

    NSStackView *llmBtns = [[NSStackView alloc] init];
    llmBtns.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    llmBtns.spacing = 8;
    NSButton *save = [NSButton buttonWithTitle:RLPTr(@"保存端点") target:self action:@selector(onLlmSave:)];
    save.bezelStyle = NSBezelStyleRounded;
    NSButton *test = [NSButton buttonWithTitle:RLPTr(@"测试连通") target:self action:@selector(onLlmTest:)];
    test.bezelStyle = NSBezelStyleRounded;
    [llmBtns addArrangedSubview:save];
    [llmBtns addArrangedSubview:test];
    [stack addArrangedSubview:llmBtns];

    self.llmStatus = RLPLabel(@"", t.small, t.mut);
    self.llmStatus.maximumNumberOfLines = 2;
    self.llmStatus.lineBreakMode = NSLineBreakByWordWrapping;
    [[self.llmStatus.widthAnchor constraintEqualToConstant:560] setActive:YES];
    [stack addArrangedSubview:self.llmStatus];
}

#pragma mark - 均衡 / 输入（已迁移的子界面）

- (void)fillEqualizer:(NSStackView *)stack t:(RLPTheme *)t {
    self.eqView = [[RLPEqualizerView alloc] initWithFrame:NSMakeRect(0, 0, 620, 720)];
    self.eqView.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:self.eqView];
    [NSLayoutConstraint activateConstraints:@[
        [self.eqView.heightAnchor constraintEqualToConstant:720],
        [self.eqView.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-4],
    ]];
    [self.eqView reload];
}

- (void)fillCalibration:(NSStackView *)stack t:(RLPTheme *)t {
    self.calView = [[RLPCalibrationView alloc] initWithFrame:NSMakeRect(0, 0, 620, 620)];
    self.calView.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:self.calView];
    [NSLayoutConstraint activateConstraints:@[
        [self.calView.heightAnchor constraintEqualToConstant:620],
        [self.calView.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-4],
    ]];
    [self.calView reload];
}

- (void)fillInputReal:(NSStackView *)stack t:(RLPTheme *)t {
    self.inputView = [[RLPInputView alloc] initWithFrame:NSMakeRect(0, 0, 620, 460)];
    self.inputView.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:self.inputView];
    [NSLayoutConstraint activateConstraints:@[
        [self.inputView.heightAnchor constraintEqualToConstant:460],
        [self.inputView.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-4],
    ]];
    [self.inputView reload];
}

#pragma mark - 动作

- (void)onTheme:(id)sender {
    NSString *name = (self.themePopup.indexOfSelectedItem == 1) ? @"light" : @"dark";
    [RLPTheme setThemeName:name];
    [self postKey:@"theme" value:name];
}

- (void)onLanguage:(id)sender {
    NSString *lang = (self.langPopup.indexOfSelectedItem == 1) ? @"en" : @"zh";
    [self postKey:@"lang" value:lang];
}

- (void)onBackend:(id)sender {
    [self postKey:@"backend" value:self.backendPopup.titleOfSelectedItem];
}

- (void)onDevice:(id)sender {
    NSString *name = self.devicePopup.titleOfSelectedItem;
    if (name.length) [self postKey:@"device" value:name];
}

- (void)onVolume:(id)sender {
    [self postKey:@"volume" value:[NSString stringWithFormat:@"%.1f", self.volumeSlider.doubleValue]];
}

- (void)onBits:(id)sender {
    NSString *s = self.bitsPopup.titleOfSelectedItem;
    [self postKey:@"bits" value:[s isEqualToString:RLPTr(@"自动")] ? @"0" : s];
}

- (void)onRate:(id)sender {
    NSString *s = self.ratePopup.titleOfSelectedItem;
    [self postKey:@"rate" value:[s isEqualToString:RLPTr(@"跟随源")] ? @"follow" : s];
}

- (void)onFilter1x:(id)sender { [self postKey:@"filter" value:self.filt1xPopup.titleOfSelectedItem]; }
- (void)onFilterNx:(id)sender { [self postKey:@"filterNx" value:self.filtNxPopup.titleOfSelectedItem]; }
- (void)onDsdRate:(id)sender {
    NSString *s = self.dsdRatePopup.titleOfSelectedItem;
    [self postKey:@"dsd" value:[s isEqualToString:RLPTr(@"不升频")] ? @"0"
                : [s stringByReplacingOccurrencesOfString:@"dsd" withString:@""]];
}
- (void)onModFamily:(id)sender { [self postKey:@"modfamily" value:self.modFamilyPopup.titleOfSelectedItem]; }
- (void)onModOrder:(id)sender { [self postKey:@"modorder" value:self.modOrderPopup.titleOfSelectedItem]; }
- (void)onInBackend:(id)sender { [self postKey:@"inbackend" value:self.inBackendPopup.titleOfSelectedItem]; }
- (void)onInDevice:(id)sender {
    NSString *n = self.inDevicePopup.titleOfSelectedItem;
    if (n.length) [self postKey:@"indev" value:n];
}

- (void)onLibraryAction:(NSButton *)sender {
    NSString *action = sender.identifier;
    if ([action isEqualToString:@"scan1"]) {
        RLPPostJSON(@"/api/lib/scan?full=1", nil);
        RLPToast(RLPTr(@"已开始全量重扫"));
    } else if ([action isEqualToString:@"scan0"]) {
        RLPPostJSON(@"/api/lib/scan?full=0", nil);
        RLPToast(RLPTr(@"已开始增量扫描"));
    } else {
        RLPPostJSON(@"/api/lib/prune", nil);
        RLPToast(RLPTr(@"已清理缺失曲目"));
    }
}

#pragma mark - AI 模型端点

#pragma mark - AI 模型列表（/api/llm/models，对齐 web llmModelsLoad）

/// 拉取模型列表。纪律与 web 一致：拉不到降级手填、不擅自改用户当前 model、选中即保存。
- (void)loadLlmModels:(BOOL)force {
    if (![RLPCoreClient shared].started || !self.llmModelPopup) return;
    if (force) self.llmModelMsg.stringValue = RLPTr(@"正在重新拉取模型列表…");
    NSString *url = force ? @"/api/llm/models?refresh=1" : @"/api/llm/models";
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *models = [json[@"models"] isKindOfClass:[NSArray class]] ? json[@"models"] : @[];
        const BOOL ok = json && [json[@"ok"] boolValue] && models.count > 0;
        NSString *cur = [json[@"current"] isKindOfClass:[NSString class]] ? json[@"current"]
                        : (self_.llmModel.stringValue ?: @"");
        if (!ok) {
            // 降级：隐藏下拉、保留手填（值填当前 model，用户可改可留空）。
            self_.llmModelPopup.hidden = YES;
            if (!self_.llmModel.stringValue.length) self_.llmModel.stringValue = cur;
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : @"";
            self_.llmModelMsg.stringValue = err.length
                ? [RLPTr(@"拉取模型列表失败") stringByAppendingFormat:@"：%@", err]
                : RLPTr(@"服务端没有返回任何模型，可直接手填模型 id");
            self_.llmModelMsg.textColor = [RLPTheme current].warn;
            return;
        }
        // 动态列表：按 id 建项；当前 model 不在列表里时额外插一条（不改配置，提示重选）。
        [self_.llmModelPopup removeAllItems];
        BOOL hasCurrent = NO;
        NSMutableArray<NSString *> *ids = [NSMutableArray array];
        for (id m in models) {
            NSString *mid = [m isKindOfClass:[NSDictionary class]] && [m[@"id"] isKindOfClass:[NSString class]]
                            ? m[@"id"] : nil;
            if (!mid.length) continue;
            [ids addObject:mid];
            if ([mid isEqualToString:cur]) hasCurrent = YES;
            [self_.llmModelPopup addItemWithTitle:
                [mid isEqualToString:cur] ? [mid stringByAppendingFormat:@" %@", RLPTr(@"（当前）")] : mid];
        }
        if (!hasCurrent && cur.length)
            [self_.llmModelPopup addItemWithTitle:[cur stringByAppendingFormat:@" %@",
                                                   RLPTr(@"当前值，不在列表中")]];
        if (cur.length && [self_.llmModelPopup itemWithTitle:cur])
            [self_.llmModelPopup selectItemWithTitle:cur];
        else if (cur.length)
            [self_.llmModelPopup selectItemAtIndex:self_.llmModelPopup.numberOfItems - 1];
        self_.llmModel.stringValue = cur;
        self_.llmModelPopup.hidden = NO;
        const NSInteger n = (NSInteger)ids.count;
        if (cur.length && !hasCurrent) {
            self_.llmModelMsg.stringValue = [NSString stringWithFormat:
                RLPTr(@"已拉到 %ld 个模型，但当前模型不在列表里，建议重新选择（不会自动改配置）"), (long)n];
            self_.llmModelMsg.textColor = [RLPTheme current].warn;
        } else {
            self_.llmModelMsg.stringValue = [NSString stringWithFormat:
                RLPTr(@"已拉到 %ld 个模型"), (long)n];
            self_.llmModelMsg.textColor = [RLPTheme current].mut;
        }
    }];
}

- (void)onLlmModelRefresh:(id)sender { (void)sender; [self loadLlmModels:YES]; }

/// 下拉选中即保存（web llmModelRender 同语义）：POST /api/llm model=…
- (void)onLlmModelPicked:(NSPopUpButton *)sender {
    NSString *title = sender.titleOfSelectedItem;
    // 去掉「（当前）」「当前值，不在列表中」后缀，拿到纯 model id。
    for (NSString *suffix in @[RLPTr(@"（当前）"), RLPTr(@"当前值，不在列表中")])
        title = [title stringByReplacingOccurrencesOfString:[@" " stringByAppendingString:suffix]
                                                withString:@""];
    if (!title.length) return;
    self.llmModel.stringValue = title;
    NSString *body = [NSString stringWithFormat:@"model=%@", RLPEnc(title)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/llm" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        self_.llmStatus.stringValue = (json && [json[@"ok"] boolValue])
            ? RLPTr(@"已保存") : (([json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"保存失败")));
    }];
}

- (void)onLlmSave:(id)sender {
    if (![RLPCoreClient shared].started) return;
    NSMutableString *body = [NSMutableString stringWithFormat:@"base_url=%@&model=%@",
        RLPEnc(self.llmBase.stringValue ?: @""), RLPEnc(self.llmModel.stringValue ?: @"")];
    // 密钥留空就不带这个键 —— 后端据此保持已存的 key（改端点不清密钥）
    NSString *key = self.llmKey.stringValue ?: @"";
    if (key.length) [body appendFormat:@"&api_key=%@", RLPEnc(key)];
    self.llmStatus.stringValue = RLPTr(@"保存中…");
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/llm" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            self_.llmKey.stringValue = @"";   // 存完立刻清掉输入框，不留明文在界面上
            self_.llmStatus.stringValue = RLPTr(@"已保存");
            [self_ loadLlmConfig];
        } else {
            self_.llmStatus.stringValue = [json[@"error"] isKindOfClass:[NSString class]]
                ? json[@"error"] : RLPTr(@"保存失败");
        }
    }];
}

- (void)onLlmTest:(id)sender {
    if (![RLPCoreClient shared].started) return;
    self.llmStatus.stringValue = RLPTr(@"正在测试…");
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/llm/test" body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            NSString *note = [json[@"note"] isKindOfClass:[NSString class]] ? json[@"note"] : @"";
            self_.llmStatus.stringValue = note.length ? note : RLPTr(@"连通正常");
        } else {
            self_.llmStatus.stringValue = [json[@"error"] isKindOfClass:[NSString class]]
                ? json[@"error"] : RLPTr(@"测试失败");
        }
    }];
}

- (void)loadLlmConfig {
    if (![RLPCoreClient shared].started || !self.llmStatus) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/llm" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || !json) return;
        // 只覆盖响应里真有的字段（POST 回包与 GET 未必同形，缺字段不当成清空）
        if ([json[@"baseUrl"] isKindOfClass:[NSString class]]) self_.llmBase.stringValue = json[@"baseUrl"];
        if ([json[@"model"] isKindOfClass:[NSString class]]) self_.llmModel.stringValue = json[@"model"];
        NSString *masked = [json[@"masked"] isKindOfClass:[NSString class]] ? json[@"masked"] : @"";
        const BOOL configured = [json[@"configured"] respondsToSelector:@selector(boolValue)] && [json[@"configured"] boolValue];
        self_.llmStatus.stringValue = configured
            ? [NSString stringWithFormat:@"%@ %@", RLPTr(@"已配置密钥"), masked]
            : RLPTr(@"尚未配置密钥");
        // 进页顺带拉一次模型列表（web llmModelsLoad(false) 同口径）。
        [self_ loadLlmModels:NO];
    }];
}

#pragma mark - 封面补齐 / 标签写回

- (void)onCoverPrefetch:(id)sender {
    if (![RLPCoreClient shared].started) { RLPToast(RLPTr(@"核心未启动")); return; }
    RLPPostJSON(@"/api/lib/cover/prefetch", nil);
    self.coverProgress.stringValue = RLPTr(@"已开始补齐…");
    [self.coverTimer invalidate];
    __weak __typeof__(self) weakSelf = self;
    self.coverTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *tm) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) { [tm invalidate]; return; }
        [[RLPCoreClient shared] getJSON:@"/api/lib/cover/progress" completion:^(NSDictionary * _Nullable json) {
            __typeof__(self) s2 = weakSelf;
            if (!s2) return;
            const BOOL running = [json[@"running"] respondsToSelector:@selector(boolValue)] && [json[@"running"] boolValue];
            const NSInteger done = [json[@"done"] respondsToSelector:@selector(integerValue)] ? [json[@"done"] integerValue] : 0;
            const NSInteger total = [json[@"total"] respondsToSelector:@selector(integerValue)] ? [json[@"total"] integerValue] : 0;
            const NSInteger hit = [json[@"hit"] respondsToSelector:@selector(integerValue)] ? [json[@"hit"] integerValue] : 0;
            const NSInteger fail = [json[@"fail"] respondsToSelector:@selector(integerValue)] ? [json[@"fail"] integerValue] : 0;
            s2.coverProgress.stringValue = [NSString stringWithFormat:@"%ld/%ld · %@ %ld · %@ %ld",
                (long)done, (long)total, RLPTr(@"命中"), (long)hit, RLPTr(@"失败"), (long)fail];
            if (!running) {
                [s2.coverTimer invalidate];
                s2.coverTimer = nil;
                RLPToast(RLPTr(@"封面补齐结束"));
            }
        }];
    }];
}

#pragma mark - 标签写回（对齐 web：忙态禁按钮 + 800ms 轮询 status 到 done）

- (void)wbSetBusy:(BOOL)busy {
    self.wbBusy = busy;
    self.wbDryBtn.enabled = !busy;
    self.wbApplyBtn.enabled = !busy;
    if (!busy) { [self.wbTimer invalidate]; self.wbTimer = nil; }
}

/// 轮询 /api/writeback/status：running 时显示 done/total 并续轮；结束时报 写入/跳过/失败。
- (void)wbPoll {
    if (![RLPCoreClient shared].started) { [self wbSetBusy:NO]; return; }
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/writeback/status" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) { [self_ wbSetBusy:NO]; self_.writebackStatus.stringValue = @""; return; }
        const BOOL running = [json[@"running"] respondsToSelector:@selector(boolValue)] && [json[@"running"] boolValue];
        if (running) {
            const NSInteger done = [json[@"done"] respondsToSelector:@selector(integerValue)] ? [json[@"done"] integerValue] : 0;
            const NSInteger total = [json[@"total"] respondsToSelector:@selector(integerValue)] ? [json[@"total"] integerValue] : 0;
            self_.writebackStatus.stringValue = [NSString stringWithFormat:RLPTr(@"写回进行中 %ld/%ld…"), (long)done, (long)total];
            return;   // 定时器下一轮继续
        }
        [self_ wbSetBusy:NO];
        NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : @"";
        if (err.length) {
            self_.writebackStatus.stringValue = [RLPTr(@"写回未执行：") stringByAppendingString:err];
            RLPToast([RLPTr(@"写回未执行：") stringByAppendingString:err]);
            return;
        }
        const NSInteger written = [json[@"written"] respondsToSelector:@selector(integerValue)] ? [json[@"written"] integerValue] : 0;
        const NSInteger skipped = [json[@"skipped"] respondsToSelector:@selector(integerValue)] ? [json[@"skipped"] integerValue] : 0;
        const NSInteger failed = [json[@"failed"] respondsToSelector:@selector(integerValue)] ? [json[@"failed"] integerValue] : 0;
        NSString *summary = [NSString stringWithFormat:RLPTr(@"写入 %ld，跳过 %ld，失败 %ld"),
                             (long)written, (long)skipped, (long)failed];
        self_.writebackStatus.stringValue = summary;
        RLPToast(summary);
    }];
}

- (void)wbStartPolling {
    [self.wbTimer invalidate];
    __weak __typeof__(self) weakSelf = self;
    self.wbTimer = [NSTimer scheduledTimerWithTimeInterval:0.8 repeats:YES block:^(NSTimer *tm) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || !self_.wbBusy) { [tm invalidate]; return; }
        [self_ wbPoll];
    }];
    [self wbPoll];
}

/// 页面（重）打开时同步一次在跑状态：中途切走再回来也能接上轮询（web wbSyncBusy 同口径）。
- (void)wbSyncBusy {
    if (![RLPCoreClient shared].started || self.wbBusy) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/writeback/status" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || self_.wbBusy) return;
        if (!json || ![json[@"ok"] boolValue]) return;
        const BOOL running = [json[@"running"] respondsToSelector:@selector(boolValue)] && [json[@"running"] boolValue];
        if (!running) return;
        [self_ wbSetBusy:YES];
        self_.writebackStatus.stringValue = RLPTr(@"写回批次进行中…");
        [self_ wbStartPolling];
    }];
}

- (void)onWritebackDry:(id)sender {
    (void)sender;
    if (![RLPCoreClient shared].started || self.wbBusy) return;
    [self wbSetBusy:YES];
    self.writebackStatus.stringValue = RLPTr(@"正在扫描 MetaBase…");
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/writeback?dry=1" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        [self_ wbSetBusy:NO];
        if (!json || ![json[@"ok"] boolValue]) {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"未知错误");
            self_.writebackStatus.stringValue = @"";
            RLPToast([RLPTr(@"预览失败：") stringByAppendingString:err]);
            return;
        }
        const NSInteger writable = [json[@"writable"] respondsToSelector:@selector(integerValue)] ? [json[@"writable"] integerValue] : 0;
        const NSInteger skipped = [json[@"skipped"] respondsToSelector:@selector(integerValue)] ? [json[@"skipped"] integerValue] : 0;
        NSString *msg = [NSString stringWithFormat:RLPTr(@"%ld 首可写，%ld 首跳过"), (long)writable, (long)skipped];
        self_.writebackStatus.stringValue = msg;
        RLPToast(msg);
    }];
}

- (void)onWritebackApply:(id)sender {
    (void)sender;
    if (![RLPCoreClient shared].started || self.wbBusy) return;
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = RLPTr(@"执行标签写回？");
    a.informativeText = RLPTr(@"会改写音乐文件的标签。建议先点「预览」确认范围。");
    [a addButtonWithTitle:RLPTr(@"执行")];
    [a addButtonWithTitle:RLPTr(@"取消")];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    [self wbSetBusy:YES];
    self.writebackStatus.stringValue = RLPTr(@"写回批次已启动…");
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/writeback" body:@"{\"apply\":true}"
                          completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        const BOOL started = json && [json[@"ok"] boolValue] && [json[@"started"] boolValue];
        if (!started) {
            [self_ wbSetBusy:NO];
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"未知错误");
            self_.writebackStatus.stringValue = @"";
            RLPToast([RLPTr(@"无法启动写回：") stringByAppendingString:err]);
            return;
        }
        [self_ wbStartPolling];
    }];
}

- (void)onCheckUpdate:(id)sender {
    [[RLPUpdateWindowController shared] checkManually:YES];
}

- (void)onExportDiagZip:(id)sender {
    // /api/diagzip 回的是 ZIP 原始字节（不是 JSON）⟹ 必须走 getData。
    // 不假装成功：取字节失败、用户取消、写盘失败三种情况分别如实说明。
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getData:@"/api/diagzip" completion:^(NSData * _Nullable data) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!data.length) { RLPToast(RLPTr(@"诊断包导出失败")); return; }
        NSSavePanel *panel = [NSSavePanel savePanel];
        panel.nameFieldStringValue = @"rlplayer-diag.zip";
        if ([panel runModal] != NSModalResponseOK || !panel.URL) return;
        NSError *err = nil;
        if (![data writeToURL:panel.URL options:NSDataWritingAtomic error:&err]) {
            RLPToast(err.localizedDescription ?: RLPTr(@"写入失败"));
            return;
        }
        RLPToast([NSString stringWithFormat:RLPTr(@"已导出 %@"), panel.URL.lastPathComponent]);
    }];
}

- (void)onOpenFeedback:(id)sender { [[RLPFeedbackWindowController shared] showAndFocus]; }

#pragma mark - 数据

- (void)activate { [self reloadData]; [self wbSyncBusy]; }

- (void)reloadData {
    if (![RLPCoreClient shared].started) {
        self.statusLine.stringValue = RLPTr(@"核心未启动");
        return;
    }
    __weak __typeof__(self) weakSelf = self;

    [[RLPCoreClient shared] getJSON:@"/api/devices" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        id devs = json[@"devices"];
        if (![devs isKindOfClass:[NSArray class]]) return;
        [self_.devicePopup removeAllItems];
        [self_.inDevicePopup removeAllItems];
        for (id d in (NSArray *)devs) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            NSString *name = d[@"name"];
            if (!name.length) continue;
            [self_.devicePopup addItemWithTitle:name];
            [self_.inDevicePopup addItemWithTitle:name];
        }
        if (!self_.devicePopup.numberOfItems) [self_.devicePopup addItemWithTitle:RLPTr(@"默认音频设备")];
        if (!self_.inDevicePopup.numberOfItems) [self_.inDevicePopup addItemWithTitle:RLPTr(@"默认输入设备")];
    }];

    [[RLPCoreClient shared] getJSON:@"/api/filters" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *items = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : nil;
        if (!items.count) return;
        [self_.filt1xPopup removeAllItems];
        [self_.filtNxPopup removeAllItems];
        for (id it in items) {
            NSString *name = [it isKindOfClass:[NSDictionary class]] ? it[@"name"]
                             : ([it isKindOfClass:[NSString class]] ? it : nil);
            if (!name.length) continue;
            [self_.filt1xPopup addItemWithTitle:name];
            [self_.filtNxPopup addItemWithTitle:name];
        }
    }];

    // 设置：以 kv 为准回填。读不到就不回填 —— 绝不把 UI 默认值写回去覆盖用户设置。
    [[RLPCoreClient shared] getJSON:@"/api/settings" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSDictionary *kv = [json[@"kv"] isKindOfClass:[NSDictionary class]] ? json[@"kv"] : nil;
        if (!kv) { self_.statusLine.stringValue = RLPTr(@"设置读取失败"); return; }
        [self_ applyKV:kv toSwitch:self_.hogSwitch key:@"hogexcl"];
        [self_ applyKV:kv toSwitch:self_.loudSwitch key:@"loudness"];
        [self_ applyKV:kv toSwitch:self_.ispSwitch key:@"isp"];
        [self_ applyKV:kv toSwitch:self_.directSdmSwitch key:@"directsdm"];
        [self_ applyKV:kv toSwitch:self_.inMonitorSwitch key:@"inmon"];
        [self_ applyKV:kv toSwitch:self_.betaSwitch key:@"updbeta"];
        [self_ applyKV:kv toSwitch:self_.autoAnlSwitch key:@"autoanl"];
        if (self_.attenField && [kv[@"atten"] isKindOfClass:[NSString class]])
            self_.attenField.stringValue = kv[@"atten"];
        [self_ applyKV:kv toSwitch:self_.streamSwitch key:@"streamdecode"];
        [self_ applyKV:kv toSwitch:self_.metaOnSwitch key:@"metaon"];
        [self_ applyKV:kv toSwitch:self_.metaLlmSwitch key:@"metallm"];
        [self_ applyKV:kv toSwitch:self_.metaSummarySwitch key:@"metasummary"];
        [self_ applyKV:kv toSwitch:self_.metaAiFillSwitch key:@"metaaifill"];

        [self_ applyKV:kv toPopup:self_.backendPopup key:@"backend"];
        [self_ applyKV:kv toPopup:self_.devicePopup key:@"device"];
        [self_ applyKV:kv toPopup:self_.ratePopup key:@"rate"];
        [self_ applyKV:kv toPopup:self_.filt1xPopup key:@"filter"];
        [self_ applyKV:kv toPopup:self_.filtNxPopup key:@"filterNx"];
        [self_ applyKV:kv toPopup:self_.modFamilyPopup key:@"modfamily"];
        [self_ applyKV:kv toPopup:self_.modOrderPopup key:@"modorder"];
        [self_ applyKV:kv toPopup:self_.inBackendPopup key:@"inbackend"];
        [self_ applyKV:kv toPopup:self_.inDevicePopup key:@"indev"];

        id vol = kv[@"volume"];
        if ([vol respondsToSelector:@selector(doubleValue)])
            self_.volumeSlider.doubleValue = MAX(-60.0, MIN(0.0, [vol doubleValue]));
        id dsd = kv[@"dsd"];
        if ([dsd respondsToSelector:@selector(integerValue)]) {
            NSInteger n = [dsd integerValue];
            NSString *title = (n <= 0) ? RLPTr(@"不升频") : [NSString stringWithFormat:@"dsd%ld", (long)n];
            if ([self_.dsdRatePopup itemWithTitle:title]) [self_.dsdRatePopup selectItemWithTitle:title];
        }
        id root = kv[@"root"];
        if ([root isKindOfClass:[NSString class]] && [root length])
            self_.rootField.stringValue = root;
        self_.statusLine.stringValue = RLPTr(@"设置已加载");
    }];

    [self.serversView reload];
    [self.metaSourcesView reload];
    [self loadLlmConfig];
}

#pragma mark - 主题

- (void)applyTheme {
    [super applyTheme];
    RLPTheme *t = [RLPTheme current];
    // 主题切换后已建页签里的控件颜色全部过时：清缓存，下次进入时按新主题重建。
    // 比逐控件改色更不容易漏，而页签切换本来就是低频操作。
    [self.paneCache removeAllObjects];
    [self rebuildTabs];
    [self showTab:self.tab];
    if (self.themePopup) {
        [self.themePopup selectItemAtIndex:[[RLPTheme themeName] isEqualToString:@"light"] ? 1 : 0];
    }
    self.statusLine.textColor = t.mut;
    [self.eqView applyTheme];
    [self.inputView applyTheme];
    [self.castView applyTheme];
    [self.calView applyTheme];
    [self.serversView applyTheme];
    [self.metaSourcesView applyTheme];
}

@end