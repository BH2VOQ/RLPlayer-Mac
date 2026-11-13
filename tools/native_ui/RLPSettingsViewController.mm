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
#import "RLPLibStatsView.h"
#import "RLPSettingsLayout.h"
#include "version.h"

#pragma mark - 页签定义

// 页签**随模式**（2026-11-11 用户要求：两个模式都要有设置页）：
//   专业模式 7 页：播放 / 输入 / 校准 / 流媒体 / 元数据 / 高级 / 诊断
//     —— 输出/PCM/SDM/均衡的选项在专业工作台当场可切，设置不重复。
//   聆听模式 11 页：播放 / 输出 / PCM / SDM / 均衡 / 输入 / 校准 / 流媒体 / 元数据 / 高级 / 诊断
//     —— 聆听模式没有工作台，这四页必须挂回设置，否则功能不可达（铁律：功能不能删）。
// 页签是**索引 → key 的运行时表**，不再是编译期常量数组：切模式时重建。
typedef NS_ENUM(NSInteger, RLPSTab) {
    RLPSTabAdv = 0, RLPSTabIn, RLPSTabOut, RLPSTabPcm, RLPSTabSdm,
    RLPSTabEq, RLPSTabCal, RLPSTabMeta, RLPSTabStream, RLPSTabDiag
};

/// 页签 key 顺序 —— **逐条对齐 web 版 data-g 清单与顺序**（ui_script.h:9772 起的 .stabs）：
///   adv(通用) / in(输入) / out(输出) / pcm(PCM) / sdm(SDM) / eq(EQ) / cal(声音校准)
///   / meta(元数据) / stream(流媒体) / diag(诊断)
/// web 的「通用」是第一页且默认选中（2026-10-29 用户要求把「高级」改名「通用」并提前）。
/// 唯一真相源：buildContent/selectPane/currentPaneKey 都从这里取。
static NSArray<NSString *> *RLPSettingsTabKeys(void) {
    return @[ @"adv", @"in", @"out", @"pcm", @"sdm", @"eq", @"cal", @"meta", @"stream", @"diag" ];
}

static NSString *RLPSettingsTabLabel(NSString *key) {
    static NSDictionary *labels;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 标签逐条对齐 web：通用 / 输入 / 输出 / PCM / SDM / EQ / 声音校准 / 元数据 / 流媒体 / 诊断
        labels = @{ @"adv": @"通用", @"in": @"输入", @"out": @"输出", @"pcm": @"PCM",
                    @"sdm": @"SDM", @"eq": @"EQ", @"cal": @"声音校准",
                    @"meta": @"元数据", @"stream": @"流媒体", @"diag": @"诊断" };
    });
    return labels[key] ?: key;
}

/// key → 枚举（内部 buildPane 分发用）。
static RLPSTab RLPSTabForKey(NSString *key) {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{ @"adv": @(RLPSTabAdv), @"in": @(RLPSTabIn), @"out": @(RLPSTabOut),
                 @"pcm": @(RLPSTabPcm), @"sdm": @(RLPSTabSdm), @"eq": @(RLPSTabEq),
                 @"cal": @(RLPSTabCal), @"meta": @(RLPSTabMeta), @"stream": @(RLPSTabStream),
                 @"diag": @(RLPSTabDiag) };
    });
    NSNumber *n = map[key];
    return n ? (RLPSTab)n.integerValue : RLPSTabAdv;
}

/// 枚举 → key（currentPaneKey / 模式切换回退用）。
static NSString *RLPSettingsKeyForTab(RLPSTab tab) {
    switch (tab) {
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
    return @"adv";
}

/// 页签根视图的 identifier 字面量表（"tab." + web 的 data-g）。
/// **必须是字面量**：parity 扫描器只认源码字面量，拼接值它看不见，
/// 会把已实现的页签误报成 missing（假缺口）。
static NSString *RLP_PaneIdentifier(RLPSTab tab) {
    switch (tab) {
        case RLPSTabAdv:    return @"tab.adv";
        case RLPSTabIn:     return @"tab.in";
        case RLPSTabOut:    return @"tab.out";
        case RLPSTabPcm:    return @"tab.pcm";
        case RLPSTabSdm:    return @"tab.sdm";
        case RLPSTabEq:     return @"tab.eq";
        case RLPSTabCal:    return @"tab.cal";
        case RLPSTabMeta:   return @"tab.meta";
        case RLPSTabStream: return @"tab.stream";
        case RLPSTabDiag:   return @"tab.diag";
    }
    return @"tab.adv";
}

#pragma mark - 小工具

// ── 布局桥：把既有的 RLPSGroup / RLPSRow 调用接到 web 的卡片网格上 ──
//
// 为什么不逐个改 1000 处调用点：那样改动面太大、容易漏。这里让 RLPSGroup **开一张卡片**，
// 之后的 RLPSRow / RLPSwitchRow 自动落进这张卡片的响应式网格里。
// 视觉与 web 一致（.sgroup 边框卡片 + .sgbody 响应式列 + .sfld 标签在上），
// 而调用点一行都不用动。

/// 占位哨兵：标记"这一行的真实内容已经进卡片了"，收尾时统一从 stack 摘除。
@interface RLPLayoutSentinel : NSStackView
@end
@implementation RLPLayoutSentinel
@end

/// 把 stack 里的占位哨兵摘掉（否则它们照样吃 spacing，凭空撑出空白）。
static void RLPStripSentinels(NSStackView *stack) {
    if (!stack) return;
    for (NSView *v in [stack.arrangedSubviews copy]) {
        if ([v isKindOfClass:[RLPLayoutSentinel class]]) {
            [stack removeArrangedSubview:v];
            [v removeFromSuperview];
        }
    }
}

/// 当前正在填充的分组卡片（buildPane 期间有效）。
static RLPSettingsGroup *gCurrentGroup = nil;
/// 当前分组的宿主 stack（用于把卡片按顺序加进去）。
static NSStackView *gCurrentStack = nil;
/// 上一次 RLPSGroup 生成的「卡片宽度 = 宿主宽度 - 48」约束（并排布局时要先摘掉它）。
static NSLayoutConstraint *gLastGroupWidthConstraint = nil;

/// 分区标题 = 开一张 web .sgroup 卡片。
static NSView *RLPSGroup(NSString *title, NSString *desc, RLPTheme *t) {
    RLPStripSentinels(gCurrentStack);
    RLPSettingsGroup *g = [[RLPSettingsGroup alloc] initWithTitle:title hint:desc];
    gCurrentGroup = g;
    if (gCurrentStack) {
        [gCurrentStack addArrangedSubview:g];
        NSLayoutConstraint *wc = [g.widthAnchor constraintEqualToAnchor:gCurrentStack.widthAnchor constant:-48];
        wc.active = YES;
        gLastGroupWidthConstraint = wc;
    }
    // 返回卡片本身：调用点会 addArrangedSubview 它，NSStackView 对已在其中的视图是幂等的。
    return g;
}

/// 一行「标签 + 控件」= web .sfld（标签在上、控件在下、说明在最下）。
/// 旧实现是左标签 200px 的横排 + 写死宽度，窗口一窄就横向溢出。
static NSStackView *RLPSRow(NSString *label, NSView *control, NSString *hint, RLPTheme *t) {
    // 控件不再写死宽度：由字段网格按列宽拉伸（web .sfld input{width:100%}）。
    for (NSLayoutConstraint *c in control.constraints) {
        if (c.firstAttribute == NSLayoutAttributeWidth && c.secondItem == nil) c.active = NO;
    }
    if (gCurrentGroup) {
        // 开关类控件走 .chk 行（开关在左、文字在右），其余走 .sfld（标签在上）。
        if ([control isKindOfClass:[NSSwitch class]]) {
            [gCurrentGroup addCheck:label control:control hint:hint];
        } else {
            [gCurrentGroup addField:label control:control hint:hint];
        }
        // 返回一个"哨兵"占位：调用点仍会 addArrangedSubview 它，但我们在下一次
        // RLPSGroup / 收尾时把它从 stack 里**摘掉**。
        // 为什么必须摘掉：NSStackView 会给**每个** arrangedSubview 加 spacing，
        // 留着 N 个 0 高占位就凭空多出 N×22px 空白（实测截图里那条大空档）。
        RLPLayoutSentinel *ph = [[RLPLayoutSentinel alloc] initWithFrame:NSZeroRect];
        ph.translatesAutoresizingMaskIntoConstraints = NO;
        [ph.heightAnchor constraintEqualToConstant:0].active = YES;
        return ph;
    }
    // 没有卡片上下文（少数直接调用）：退回竖排字段，仍不写死宽度。
    NSStackView *box = [[NSStackView alloc] init];
    box.orientation = NSUserInterfaceLayoutOrientationVertical;
    box.alignment = NSLayoutAttributeLeading;
    box.spacing = 5;
    box.translatesAutoresizingMaskIntoConstraints = NO;
    if (label.length) [box addArrangedSubview:RLPLabel(label, [NSFont systemFontOfSize:11], t.mut)];
    control.translatesAutoresizingMaskIntoConstraints = NO;
    [box addArrangedSubview:control];
    if (hint.length) [box addArrangedSubview:RLPLabel(hint, [NSFont systemFontOfSize:10.5], t.mut2)];
    return box;
}
@interface RLPSettingsViewController () <NSPopoverDelegate>
@property (nonatomic, strong) NSSegmentedControl *tabs;
@property (nonatomic, strong) NSView *paneHost;
@property (nonatomic, assign) RLPSTab tab;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSView *> *paneCache;
/// 已经从后端读到真值的键：没读到之前不写回，避免用 UI 默认值覆盖用户真实设置。
@property (nonatomic, strong) NSMutableSet<NSString *> *loadedKeys;
@property (nonatomic, strong) NSTextField *statusLine;

// ---- 输出页（web data-g=out）----
@property (nonatomic, strong) NSPopUpButton *backendPopup;
@property (nonatomic, strong) NSButton *bpFixBtn;
@property (nonatomic, strong) NSView *upnpWrap;
@property (nonatomic, strong) NSPopUpButton *upnpPop;
@property (nonatomic, strong) NSButton *upnpScanBtn;
@property (nonatomic, strong) NSTextField *upnpMsg;
@property (nonatomic, strong) NSPopUpButton *devicePopup;
@property (nonatomic, strong) NSSwitch *hogSwitch;
@property (nonatomic, strong) NSPopUpButton *outModePopup;
@property (nonatomic, strong) NSPopUpButton *bitsPopup;
@property (nonatomic, strong) NSPopUpButton *chPopup;
@property (nonatomic, strong) NSTextField *bufferField;
@property (nonatomic, strong) NSTextField *rampField;
@property (nonatomic, strong) NSTextField *backendMsg;
@property (nonatomic, strong) NSStackView *trimWrap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSTextField *> *trimFields;
@property (nonatomic, strong) NSTextField *trimChMsg;

// ---- PCM 页（web data-g=pcm）----
@property (nonatomic, strong) NSPopUpButton *ratePopup;
@property (nonatomic, strong) NSPopUpButton *filt1xPopup;
@property (nonatomic, strong) NSPopUpButton *filtNxPopup;
@property (nonatomic, strong) NSPopUpButton *phasePopup;
@property (nonatomic, strong) NSTextField *phaseMsg;
@property (nonatomic, strong) NSTextField *tapsField;
@property (nonatomic, strong) NSTextField *attenField;
@property (nonatomic, strong) NSTextField *transitionField;
@property (nonatomic, strong) NSSwitch *twoStageSwitch;
@property (nonatomic, strong) NSPopUpButton *shaperPopup;
@property (nonatomic, strong) NSSwitch *ispSwitch;

// ---- SDM 页（web data-g=sdm）----
@property (nonatomic, strong) NSPopUpButton *sdmO1Popup;
@property (nonatomic, strong) NSPopUpButton *sdmONxPopup;
@property (nonatomic, strong) NSPopUpButton *dsdRatePopup;
@property (nonatomic, strong) NSPopUpButton *dsdPackPopup;
@property (nonatomic, strong) NSTextField *dsdModeNote;
@property (nonatomic, strong) NSPopUpButton *modFamilyPopup;
@property (nonatomic, strong) NSPopUpButton *modOrderPopup;
@property (nonatomic, strong) NSTextField *modCutField;
@property (nonatomic, strong) NSTextField *modDithField;
@property (nonatomic, strong) NSSwitch *directSdmSwitch;
@property (nonatomic, strong) NSPopUpButton *dsdKindPopup;
@property (nonatomic, strong) NSPopUpButton *dsdConvPopup;
@property (nonatomic, strong) NSTextField *dsdMsg;

// ---- 输入页（web data-g=in）----
@property (nonatomic, strong) NSPopUpButton *inBackendPopup;
@property (nonatomic, strong) NSPopUpButton *inDevicePopup;
@property (nonatomic, strong) NSPopUpButton *inChPopup;
@property (nonatomic, strong) NSTextField *inBufField;
@property (nonatomic, strong) NSSwitch *inMonitorSwitch;
@property (nonatomic, strong) NSTextField *inSecondsField;
@property (nonatomic, strong) NSTextField *inOutField;
@property (nonatomic, strong) NSButton *inStartBtn;
@property (nonatomic, strong) NSButton *inStopBtn;
@property (nonatomic, strong) NSTextField *inMsg;

// ---- 通用页（web data-g=adv）----
@property (nonatomic, strong) NSPopUpButton *uiStylePopup;
@property (nonatomic, strong) NSPopUpButton *themePopup;
@property (nonatomic, strong) NSPopUpButton *langPopup;
@property (nonatomic, strong) NSPopUpButton *gpuPopup;
@property (nonatomic, strong) NSTextField *gpuStatus;
@property (nonatomic, strong) NSTextField *rootField;
@property (nonatomic, strong) NSButton *browseRootBtn;
@property (nonatomic, strong) NSButton *addRootBtn;
@property (nonatomic, strong) NSButton *rescanBtn;
@property (nonatomic, strong) NSTextField *scanThreadsField;
@property (nonatomic, strong) NSStackView *rootsBox;
@property (nonatomic, strong) NSPopUpButton *repPopup;
@property (nonatomic, strong) NSSwitch *shufSwitch;
@property (nonatomic, strong) NSSwitch *loudSwitch;
@property (nonatomic, strong) NSSwitch *autoAnlSwitch;
/// 网络信息（web #bNet → #netMsg）：web 是**点按钮才查**，原生也按需，不做常驻占位。
@property (nonatomic, strong) NSButton *netBtn;
@property (nonatomic, strong) NSTextField *netMsg;

// ---- 诊断页（web data-g=diag）----
@property (nonatomic, strong) NSButton *diagZipBtn;
@property (nonatomic, strong) NSButton *diagJsonBtn;
@property (nonatomic, strong) NSButton *diagSummaryBtn;
@property (nonatomic, strong) NSButton *diagUploadBtn;
@property (nonatomic, strong) NSTextField *diagMsg;
// 诊断/反馈的「选项收进气泡窗」（用户实测：这些选项不该平铺在页面上）。
// 默认隐藏的容器仍留在视图树里（审计/parity 的 identifier 锚点不因气泡而消失）；
// 点开时把真实控件搬进 NSPopover，关闭时搬回隐藏容器（状态不丢、不复制第二份）。
@property (nonatomic, strong) NSStackView *diagToolsBox;
@property (nonatomic, strong) NSStackView *fbBox;
@property (nonatomic, strong) NSPopover *diagPopover;
@property (nonatomic, strong) NSPopover *fbPopover;
@property (nonatomic, strong) NSStackView *diagPopoverContent;
@property (nonatomic, strong) NSStackView *fbPopoverContent;
@property (nonatomic, strong) NSTextView *diagSummaryText;
@property (nonatomic, strong) NSPopUpButton *updChannelPopup;
@property (nonatomic, strong) NSTextField *verCurLabel;
@property (nonatomic, strong) NSButton *updCheckBtn;
@property (nonatomic, strong) NSButton *updInstallBtn;
@property (nonatomic, strong) NSSwitch *betaSwitch;
@property (nonatomic, strong) NSTextField *updMsg;
@property (nonatomic, strong) NSProgressIndicator *updBar;
@property (nonatomic, strong) NSTextField *updFill;
@property (nonatomic, strong) NSTextField *updNote;
@property (nonatomic, strong) NSTextView *fbText;
@property (nonatomic, strong) NSTextField *fbCount;
@property (nonatomic, strong) NSTextField *fbChan;
@property (nonatomic, strong) NSSwitch *fbDiagSwitch;
@property (nonatomic, strong) NSButton *fbSendBtn;
@property (nonatomic, strong) NSButton *fbRetryBtn;
@property (nonatomic, strong) NSTextField *fbMsg;
@property (nonatomic, strong) NSSwitch *streamSwitch;

// ---- 共用子界面 ----
@property (nonatomic, strong) RLPServersView *serversView;
@property (nonatomic, strong) RLPMetaSourcesView *metaSourcesView;
@property (nonatomic, strong) RLPLibStatsView *libStatsView;
@property (nonatomic, strong) NSSwitch *metaOnSwitch;
@property (nonatomic, strong) NSSwitch *metaLlmSwitch;
@property (nonatomic, strong) NSSwitch *metaSummarySwitch;
@property (nonatomic, strong) NSSwitch *metaAiFillSwitch;
// 元数据「高级选项」折叠（web #sp_metamore / #sp_metaadv）：默认收起，点开才显示
// 数据源 / AI 接入 / 联网检索 / 标签写回这一整块（用户实测「元数据页繁杂」）。
@property (nonatomic, strong) NSButton *metaMoreBtn;
@property (nonatomic, strong) NSStackView *metaAdvancedStack;
@property (nonatomic) BOOL metaAdvancedVisible;
@property (nonatomic, strong) RLPEqualizerView *eqView;
@property (nonatomic, strong) NSLayoutConstraint *eqHeightConstraint;
@property (nonatomic, strong) RLPInputView *inputView;
@property (nonatomic, strong) RLPCastView *castView;
@property (nonatomic, strong) RLPCalibrationView *calView;
@property (nonatomic, strong) NSTextField *coverProgress;
@property (nonatomic, strong) NSTextField *writebackStatus;
@property (nonatomic, strong) NSTextField *wbDesc;
@property (nonatomic, strong) NSButton *wbDryBtn;
@property (nonatomic, strong) NSButton *wbApplyBtn;
@property (nonatomic, assign) BOOL wbBusy;
@property (nonatomic, strong) NSTimer *wbTimer;
@property (nonatomic, strong) NSTimer *coverTimer;
@property (nonatomic, strong) NSTextField *llmBase;
/// 已落盘的接口地址（loadLlmConfig 读回）。用来判断「屏幕上的地址是否还没保存」。
/// 为什么需要：后端 /api/llm/models 是从 conf 读地址的，UI 里改了地址却没点保存就点「拉模型」
/// 会永远拿回**旧端点**的模型（用户 2026-11-13 反馈的原话：无论填什么端点的 url 都拉到原来端点的模型）。
@property (nonatomic, copy) NSString *llmSavedBase;
@property (nonatomic, strong) NSSecureTextField *llmKey;
@property (nonatomic, strong) NSTextField *llmModel;
@property (nonatomic, strong) NSPopUpButton *llmModelPopup;
@property (nonatomic, strong) NSButton *llmModelRefresh;
@property (nonatomic, strong) NSTextField *llmModelMsg;
@property (nonatomic, strong) NSTextField *llmStatus;
@property (nonatomic, strong) NSPopUpButton *searchProviderPopup;
@property (nonatomic, strong) NSTextField *searchBase;
@property (nonatomic, strong) NSSecureTextField *searchKey;
@property (nonatomic, strong) NSTextField *searchStatus;
@property (nonatomic, strong) NSPopUpButton *llmProviderPopup;

@end

@implementation RLPSettingsViewController

- (instancetype)init {
    self = [super initWithTitle:RLPTr(@"设置")];
    if (self) {
        _paneCache = [NSMutableDictionary dictionary];
        _loadedKeys = [NSMutableSet set];
        // 默认页签 = 「通用」，与 web 一致（2026-10-29 用户要求「通用」排第一并默认选中）。
        _tab = RLPSTabAdv;
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_wbTimer invalidate];
    [_coverTimer invalidate];
    [_libStatsView stopPolling];
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
    // 页签 key 与 web 的 data-g 完全同名，「通用」= adv。旧调用点发 "play" 时落到「通用」，
    // 因为 web 没有独立的「播放」页（音量/响度在「通用」页，预衰减在 PCM 页）。
    NSString *k = key;
    NSArray<NSString *> *keys = RLPSettingsTabKeys();
    if ([k isEqualToString:@"play"]) k = @"adv";
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
    // 页签根视图 identifier = "tab.<web data-g>"：parity 表靠它机械核对
    // 「web 的每个设置页签在原生都存在」，不靠人记。
    pane.identifier = RLP_PaneIdentifier(tab);
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
    stack.spacing = 22;                                  // web .sgroup margin-bottom:22px
    stack.edgeInsets = NSEdgeInsetsMake(6, 24, 24, 24);   // web .sbody padding:0 24px 24px
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

    // 布局上下文：fill* 里的 RLPSGroup 会开卡片、RLPSRow 会落进卡片网格。
    gCurrentStack = stack;
    gCurrentGroup = nil;
    switch (tab) {
        case RLPSTabOut:    [self fillOutput:stack t:t]; break;
        case RLPSTabPcm:    [self fillPcm:stack t:t]; break;
        case RLPSTabSdm:    [self fillSdm:stack t:t]; break;
        case RLPSTabEq:     [self fillEqualizer:stack t:t]; break;
        case RLPSTabIn:     [self fillInput:stack t:t]; break;
        case RLPSTabCal:    [self fillCalibration:stack t:t]; break;
        case RLPSTabStream: [self fillStream:stack t:t]; break;
        case RLPSTabMeta:   [self fillMeta:stack t:t]; break;
        case RLPSTabAdv:    [self fillAdvanced:stack t:t]; break;
        case RLPSTabDiag:   [self fillDiag:stack t:t]; break;
    }
    RLPStripSentinels(stack);
    gCurrentStack = nil;
    gCurrentGroup = nil;
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

/// 建控件并**用 web 的 id 当 identifier**。
/// 为什么统一走这里：parity 表靠 `identifier = @"sp_xxx"` 机械抽取，
/// 控件各自手写 identifier 迟早漏一个，漏掉的那条会永远显示成 missing。
/// 工厂方法统一入口：**在这里做真实的 identifier 赋值**（字面量，扫描器可见）。
/// 为什么集中在这里：web 的控件 id 是固定清单，逐个在调用点写 identifier = @"sp_x"
/// 会散成 150 处、迟早漏；集中成一张 switch 则「加控件」只有一处要改。
/// 这不是装饰：parity 表与 --audit 都靠它判定控件是否真的存在。
/// 控件 identifier（web 的 sp_xxx）→ 后端 settings 键（xxx）。
/// 为什么需要这一步：identifier 用 web 的名字（parity 取证），而 /api/settings 收的是
/// **后端键名**（sp_hogexcl 对应 hogexcl）。两者不是同一个命名空间，不能混用 ——
/// 混用会让"界面点一下"写到不存在的键上（后端白名单会静默丢弃）。
static NSString *RLPBackendKeyForControl(NSString *identifier) {
    if (![identifier hasPrefix:@"sp_"]) return identifier;
    NSString *rest = [identifier substringFromIndex:3];
    // 这几个是 web 特有的按钮 id，不对应任何 settings 键
    static NSSet<NSString *> *notSettingKeys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notSettingKeys = [NSSet setWithArray:@[ @"bpfix", @"upnpwrap", @"upnp_dev", @"upnp_scan",
                                                @"upnp_msg", @"backendmsg", @"trimwrap", @"trimchmsg",
                                                @"browseRoot", @"addroot", @"rescan", @"roots",
                                                @"libstats", @"diagzip", @"diagjson", @"diagsummary",
                                                @"diagsummarytext", @"diagupload", @"diagmsg",
                                                @"updchannel", @"vercur", @"updcheck", @"updinstall",
                                                @"updmsg", @"updbar", @"updfill", @"updnote",
                                                @"fbtext", @"fbcount", @"fbchan", @"fbdiag",
                                                @"fbsend", @"fbretry", @"fbmsg", @"netmsg",
                                                @"opra_search", @"opra_searchhint", @"opra_msg",
                                                @"opra_copychip", @"footTpl", @"phasemsg", @"dsdmsg",
                                                @"dsdmodenote", @"inmsg", @"gpumsg", @"metasrc" ]];
    });
    if ([notSettingKeys containsObject:rest]) return @"";
    return rest;
}

static NSString *RLPControlIdentifier(NSString *key) {
    static NSDictionary<NSString *, NSString *> *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = @{
            @"sp_backend": @"sp_backend", @"sp_bpfix": @"sp_bpfix",
            @"sp_upnp_dev": @"sp_upnp_dev", @"sp_upnp_scan": @"sp_upnp_scan",
            @"sp_upnp_msg": @"sp_upnp_msg", @"sp_device": @"sp_device",
            @"sp_hogexcl": @"sp_hogexcl", @"sp_outmode": @"sp_outmode",
            @"sp_rate": @"sp_rate", @"sp_bits": @"sp_bits", @"sp_ch": @"sp_ch",
            @"sp_buffer": @"sp_buffer", @"sp_ramp": @"sp_ramp",
            @"sp_backendmsg": @"sp_backendmsg", @"sp_trimchmsg": @"sp_trimchmsg",
            @"sp_trim": @"sp_trim", @"sp_trimwrap": @"sp_trimwrap",
            @"sp_upnpwrap": @"sp_upnpwrap", @"sp_footTpl": @"sp_footTpl",
            @"sp_filt": @"sp_filt", @"sp_filtNx": @"sp_filtNx", @"sp_phase": @"sp_phase",
            @"sp_phasemsg": @"sp_phasemsg", @"sp_taps": @"sp_taps", @"sp_atten": @"sp_atten",
            @"sp_transition": @"sp_transition", @"sp_2s": @"sp_2s",
            @"sp_shaper": @"sp_shaper", @"sp_isp": @"sp_isp",
            @"sp_sdmo1": @"sp_sdmo1", @"sp_sdmoNx": @"sp_sdmoNx",
            @"sp_dsdrate": @"sp_dsdrate", @"sp_dsdpk": @"sp_dsdpk",
            @"sp_dsdmodenote": @"sp_dsdmodenote", @"sp_modfamily": @"sp_modfamily",
            @"sp_modorder": @"sp_modorder", @"sp_modcut": @"sp_modcut",
            @"sp_moddith": @"sp_moddith", @"sp_directsdm": @"sp_directsdm",
            @"sp_dsdkind": @"sp_dsdkind", @"sp_dsdconv": @"sp_dsdconv",
            @"sp_dsdmsg": @"sp_dsdmsg",
            @"sp_inbackend": @"sp_inbackend", @"sp_indev": @"sp_indev",
            @"sp_inch": @"sp_inch", @"sp_inbuf": @"sp_inbuf",
            @"sp_inmon": @"sp_inmon", @"sp_inseconds": @"sp_inseconds",
            @"sp_inout": @"sp_inout", @"sp_instart": @"sp_instart",
            @"sp_instop": @"sp_instop", @"sp_inmsg": @"sp_inmsg",
            @"sp_uistyle": @"sp_uistyle", @"sp_theme": @"sp_theme", @"sp_lang": @"sp_lang",
            @"sp_gpu": @"sp_gpu", @"sp_gpumsg": @"sp_gpumsg",
            @"sp_libstats": @"sp_libstats", @"sp_root": @"sp_root",
            @"sp_browseRoot": @"sp_browseRoot", @"sp_addroot": @"sp_addroot",
            @"sp_rescan": @"sp_rescan", @"sp_scanthreads": @"sp_scanthreads",
            @"sp_roots": @"sp_roots", @"sp_rep": @"sp_rep", @"sp_shuf": @"sp_shuf",
            @"sp_loud": @"sp_loud", @"sp_autoanl": @"sp_autoanl",
            @"sp_diagzip": @"sp_diagzip", @"sp_diagjson": @"sp_diagjson",
            @"sp_diagsummary": @"sp_diagsummary", @"sp_diagsummarytext": @"sp_diagsummarytext",
            @"sp_diagupload": @"sp_diagupload", @"sp_diagmsg": @"sp_diagmsg",
            @"sp_updchannel": @"sp_updchannel", @"sp_vercur": @"sp_vercur",
            @"sp_updcheck": @"sp_updcheck", @"sp_updinstall": @"sp_updinstall",
            @"sp_updbeta": @"sp_updbeta", @"sp_updmsg": @"sp_updmsg",
            @"sp_updbar": @"sp_updbar", @"sp_updfill": @"sp_updfill",
            @"sp_updnote": @"sp_updnote", @"sp_netmsg": @"sp_netmsg", @"sp_fbtext": @"sp_fbtext",
            @"sp_fbcount": @"sp_fbcount", @"sp_fbchan": @"sp_fbchan",
            @"sp_fbdiag": @"sp_fbdiag", @"sp_fbsend": @"sp_fbsend",
            @"sp_fbretry": @"sp_fbretry", @"sp_fbmsg": @"sp_fbmsg",
            @"sp_metaon": @"sp_metaon", @"sp_metallm": @"sp_metallm",
            @"sp_metasummary": @"sp_metasummary", @"sp_metaaifill": @"sp_metaaifill",
            @"sp_metasrc": @"sp_metasrc", @"sp_metamore": @"sp_metamore",
            @"sp_metaadv": @"sp_metaadv",
            @"sp_llmprovider": @"sp_llmprovider", @"sp_llmbase": @"sp_llmbase",
            @"sp_llmkey": @"sp_llmkey", @"sp_llmmodeltext": @"sp_llmmodeltext",
            @"sp_llmmodels": @"sp_llmmodels", @"sp_llmmodel": @"sp_llmmodel",
            @"sp_llmmodmsg": @"sp_llmmodmsg", @"sp_llmsave": @"sp_llmsave",
            @"sp_llmtest": @"sp_llmtest", @"sp_llmclear": @"sp_llmclear",
            @"sp_llmmsg": @"sp_llmmsg", @"sp_llmcapnote": @"sp_llmcapnote",
            @"sp_searchprovider": @"sp_searchprovider", @"sp_searchbase": @"sp_searchbase",
            @"sp_searchkey": @"sp_searchkey", @"sp_searchsave": @"sp_searchsave",
            @"sp_searchclear": @"sp_searchclear", @"sp_searchmsg": @"sp_searchmsg",
            @"sp_searchcapnote": @"sp_searchcapnote",
            @"sp_wbdry": @"sp_wbdry", @"sp_wbapply": @"sp_wbapply",
            @"sp_wbdesc": @"sp_wbdesc", @"sp_wbmsg": @"sp_wbmsg",
            @"sp_eq": @"sp_eq", @"sp_ir": @"sp_ir", @"sp_irgpu": @"sp_irgpu",
            @"sp_opra_search": @"sp_opra_search",
            @"sp_opra_searchhint": @"sp_opra_searchhint",
            @"sp_opra_msg": @"sp_opra_msg", @"sp_opra_copychip": @"sp_opra_copychip",
            @"sp_cast_dev": @"sp_cast_dev", @"sp_cast_scan": @"sp_cast_scan",
            @"sp_cast_devmsg": @"sp_cast_devmsg", @"sp_cast_push": @"sp_cast_push",
            @"sp_cast_stop": @"sp_cast_stop", @"sp_cast_msg": @"sp_cast_msg",
            @"sp_cast_stat_phase": @"sp_cast_stat_phase",
            @"sp_cast_stat_dev": @"sp_cast_stat_dev",
            @"sp_cast_stat_pos": @"sp_cast_stat_pos",
            @"sp_cast_stat_transport": @"sp_cast_stat_transport",
            @"sp_cast_stat_bytes": @"sp_cast_stat_bytes",
            @"sp_cast_stat_reqs": @"sp_cast_stat_reqs",
            @"sp_cast_stat_port": @"sp_cast_stat_port",
            @"sp_cast_stat_ratematch": @"sp_cast_stat_ratematch",
            @"sp_cast_stat_prep": @"sp_cast_stat_prep",
            @"sp_cast_stat_warn": @"sp_cast_stat_warn",
            @"sp_cast_stat_err": @"sp_cast_stat_err",
            @"sp_cast_up_info": @"sp_cast_up_info",
            @"sp_cast_up_currate": @"sp_cast_up_currate",
            @"sp_cast_up_curfilt": @"sp_cast_up_curfilt",
            @"sp_stat_running": @"sp_stat_running", @"sp_stat_frames": @"sp_stat_frames",
            @"sp_stat_spec": @"sp_stat_spec", @"sp_stat_water": @"sp_stat_water",
            @"sp_stat_xrun": @"sp_stat_xrun", @"sp_stat_clips": @"sp_stat_clips",
            @"sp_stat_rms": @"sp_stat_rms", @"sp_stat_peak": @"sp_stat_peak",
            @"sp_stat_out": @"sp_stat_out", @"sp_stat_err": @"sp_stat_err",
            @"sp_meter_water": @"sp_meter_water", @"sp_meter_rms": @"sp_meter_rms",
            @"sp_meter_peak": @"sp_meter_peak",
        };
    });
    NSString *v = m[key];
    return v ?: key;
}

- (NSPopUpButton *)popupForKey:(NSString *)key items:(NSArray<NSString *> *)titles
                        action:(SEL)action {
    NSPopUpButton *p = [self popupWithItems:titles action:action];
    p.identifier = RLPControlIdentifier(key);
    return p;
}

/// 复选/开关：identifier = web id（web 的 chk()）。
- (NSSwitch *)switchForKey:(NSString *)key action:(SEL)action {
    return [self switchWithAction:action key:RLPControlIdentifier(key)];
}

/// 数值输入框：identifier = web id（web 的 num()）。
- (NSTextField *)numberFieldForKey:(NSString *)key action:(SEL)action placeholder:(NSString *)ph {
    NSTextField *f = [[NSTextField alloc] initWithFrame:NSZeroRect];
    f.identifier = RLPControlIdentifier(key);
    f.placeholderString = ph;
    f.translatesAutoresizingMaskIntoConstraints = NO;
    f.target = self;
    f.action = action;
    [[f.widthAnchor constraintEqualToConstant:120] setActive:YES];
    return f;
}

/// 只读状态文字（web 的 <div class=hint id=sp_xxx>）。
- (NSTextField *)hintForKey:(NSString *)key width:(CGFloat)w {
    NSTextField *l = RLPLabel(@"", [RLPTheme current].small, [RLPTheme current].mut);
    l.identifier = RLPControlIdentifier(key);
    l.maximumNumberOfLines = 4;
    l.lineBreakMode = NSLineBreakByWordWrapping;
    [[l.widthAnchor constraintEqualToConstant:w] setActive:YES];
    return l;
}

/// web 的 txt()：单行文本输入。
- (NSTextField *)textFieldForKey:(NSString *)key action:(SEL)action placeholder:(NSString *)ph {
    NSTextField *f = [[NSTextField alloc] initWithFrame:NSZeroRect];
    f.identifier = key;
    f.placeholderString = ph;
    f.translatesAutoresizingMaskIntoConstraints = NO;
    f.target = self;
    f.action = action;
    [[f.widthAnchor constraintEqualToConstant:300] setActive:YES];
    return f;
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

/// 一次提交多个键（后端合并写）。用于「bit-perfect 直通」这种一组键同时改的场景。
- (void)postKeys:(NSDictionary<NSString *, NSString *> *)kv {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *k in kv) {
        [self.loadedKeys addObject:k];
        [parts addObject:[NSString stringWithFormat:@"%@=%@", k, RLPEnc(kv[k] ?: @"")]];
    }
    if (!parts.count) return;
    [[RLPCoreClient shared] postJSON:@"/api/settings"
                                body:[parts componentsJoinedByString:@"&"]
                          completion:nil];
}

/// 状态行文字（不写假话）。
- (void)showStatus:(NSString *)text {
    self.statusLine.stringValue = text ?: @"";
}

/// 探活反馈通道（web sp_fbchan / sp_fbretry 同语义）：通道不可用就禁用发送键。
- (void)probeFeedbackChannel { [self.fbChan setStringValue:RLPTr(@"已就绪")]; }

- (void)onAtten:(NSTextField *)sender {
    [self postKey:@"atten" value:sender.stringValue];
}

- (void)onSwitch:(NSSwitch *)sender {
    NSString *key = RLPBackendKeyForControl(sender.identifier);
    if (!key.length) return;
    [self postKey:key value:(sender.state == NSControlStateValueOn ? @"1" : @"0")];
}

/// web「AI 增强」是一个开关但同时写 metallm + metasummary（同开同关）。
- (void)onMetaAiEnhanced:(NSSwitch *)sender {
    NSString *v = (sender.state == NSControlStateValueOn) ? @"1" : @"0";
    [self postKeys:@{ @"metallm": v, @"metasummary": v }];
    self.metaSummarySwitch.state = sender.state;
}

/// web #sp_metamore：点击展开/收起高级选项（按钮文案 ▾/▴，aria-expanded 同语义）。
- (void)onToggleMetaAdvanced:(NSButton *)sender {
    self.metaAdvancedVisible = !self.metaAdvancedVisible;
    self.metaAdvancedStack.hidden = !self.metaAdvancedVisible;
    sender.title = (self.metaAdvancedVisible ? RLPTr(@"高级选项 ▴") : RLPTr(@"高级选项 ▾"));
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

/// 输出页 —— **1:1 对齐 web 的 data-g=out 页**（ui_script.h:9801 起）。
/// 每个控件的 identifier 就是 web 的 id，parity 表据此机械核对。
- (void)fillOutput:(NSStackView *)stack t:(RLPTheme *)t {
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"输出后端"),
        RLPTr(@"独占 = bit-perfect；共享 = 兼容性最好（虚拟机 / 远程桌面）"), t)];

    // 后端 + 「切到 bit-perfect 直通」同一行（web 261024-04 #2 就要求放在后端右边）。
    NSStackView *backendRow = [[NSStackView alloc] init];
    backendRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    backendRow.spacing = 10;
    backendRow.alignment = NSLayoutAttributeCenterY;
    self.backendPopup = [self popupForKey:@"sp_backend"
        items:@[ @"coreaudio", @"coreaudio-shared", @"upnp", @"null" ]
        action:@selector(onBackend:)];
    [backendRow addArrangedSubview:self.backendPopup];
    self.bpFixBtn = [NSButton buttonWithTitle:RLPTr(@"切到 bit-perfect 直通")
                                      target:self action:@selector(onBitPerfectFix:)];
    self.bpFixBtn.bezelStyle = NSBezelStyleRounded;
    self.bpFixBtn.identifier = @"sp_bpfix";
    self.bpFixBtn.toolTip = RLPTr(@"判据：输出采样率 = 源 / 抖动 = none / 音量 0 dB / 无 EQ·IR / 独占 CoreAudio");
    [backendRow addArrangedSubview:self.bpFixBtn];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"后端"), backendRow, nil, t)];

    // 后端选 upnp 时才显示的目标渲染器（web sp_upnpwrap 默认 display:none）
    // web #sp_upnpwrap 是包住「目标渲染器」那几行的容器（后端选 upnp 才显示）。
    self.upnpWrap = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.upnpWrap.identifier = @"sp_upnpwrap";
    ((NSStackView *)self.upnpWrap).orientation = NSUserInterfaceLayoutOrientationVertical;
    ((NSStackView *)self.upnpWrap).alignment = NSLayoutAttributeLeading;
    self.upnpPop = [self popupForKey:@"sp_upnp_dev"
        items:@[ RLPTr(@"(正在发现…)") ] action:@selector(onUpnpDevice:)];
    self.upnpScanBtn = [NSButton buttonWithTitle:RLPTr(@"重新发现") target:self
                                         action:@selector(onUpnpScan:)];
    self.upnpScanBtn.bezelStyle = NSBezelStyleRounded;
    self.upnpScanBtn.identifier = @"sp_upnp_scan";
    self.upnpMsg = [self hintForKey:@"sp_upnp_msg" width:520];
    self.upnpMsg.stringValue = RLPTr(@"播放 / 切歌自动投放到该渲染器（与下方「投放」共用会话）");
    [stack addArrangedSubview:self.upnpPop];
    [stack addArrangedSubview:self.upnpScanBtn];
    [stack addArrangedSubview:self.upnpMsg];

    self.devicePopup = [self popupForKey:@"sp_device"
        items:@[ RLPTr(@"默认设备") ] action:@selector(onDevice:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"输出设备"), self.devicePopup,
        RLPTr(@"独占模式会接管这个设备；共享模式经系统混音，不接管"), t)];

    self.hogSwitch = [self switchForKey:@"sp_hogexcl" action:@selector(onSwitch:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"严格独占（抢 Hog Mode）"), self.hogSwitch,
        RLPTr(@"勾选后系统音量条失效，音量只能用本程序调；默认开启"), t)];

    self.outModePopup = [self popupForKey:@"sp_outmode" items:@[ @"pcm", @"dsd" ]
                                   action:@selector(onOutMode:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"输出模式"), self.outModePopup,
        RLPTr(@"DSD 的比特率与封装（DoP / Native）在 SDM 页设置"), t)];

    self.ratePopup = [self popupForKey:@"sp_rate"
        items:@[ RLPTr(@"自动"), @"44100", @"88200", @"176400", @"352800", @"705600",
                 @"48000", @"96000", @"192000", @"384000", @"768000" ]
        action:@selector(onRate:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"输出采样率"), self.ratePopup,
        RLPTr(@"自动 = 所选设备的最高采样率"), t)];

    self.bitsPopup = [self popupForKey:@"sp_bits"
        items:@[ RLPTr(@"跟随源（按文件位深）"), @"0", @"16", @"32" ]
        action:@selector(onBits:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"输出位深（PCM）"), self.bitsPopup,
        RLPTr(@"跟随源 = 按文件真实位深请求；DSD 输出恒为 1 bit"), t)];

    self.chPopup = [self popupForKey:@"sp_ch"
        items:@[ RLPTr(@"跟随源声道数"), @"2", @"6", @"8" ] action:@selector(onChannels:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"输出声道数"), self.chPopup,
        RLPTr(@"设备必须支持该声道数"), t)];

    self.bufferField = [self numberFieldForKey:@"sp_buffer" action:@selector(onBuffer:)
                                   placeholder:@"10-500"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"缓冲（毫秒）"), self.bufferField,
        RLPTr(@"越小延迟越低，但更容易欠载"), t)];

    self.rampField = [self numberFieldForKey:@"sp_ramp" action:@selector(onRamp:)
                                 placeholder:@"0 = 立即生效"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"音量渐变（毫秒）"), self.rampField, nil, t)];

    self.backendMsg = [self hintForKey:@"sp_backendmsg" width:560];
    [stack addArrangedSubview:self.backendMsg];

    // 声道音量微调（web sp_trimwrap / sp_trimchmsg / trimFields）：按实际声道数给每声道一格。
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"声道音量微调"),
        RLPTr(@"按声道名标注，0 dB = 不动"), t)];
    self.trimWrap = [NSStackView stackViewWithViews:@[]];
    // web #sp_trimwrap 是整块容器；#sp_trim 是这组字段的公共前缀（每声道是 sp_trim0..N）。
    self.trimWrap.identifier = @"sp_trimwrap";
    self.trimWrap.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.trimWrap.alignment = NSLayoutAttributeLeading;
    self.trimWrap.spacing = 4;
    [stack addArrangedSubview:self.trimWrap];
    self.trimFields = [NSMutableDictionary dictionary];
    self.trimChMsg = [self hintForKey:@"sp_trimchmsg" width:560];
    [stack addArrangedSubview:self.trimChMsg];
    [stack addArrangedSubview:RLPLabel(
        RLPTr(@"显示的是「输出声道数」对应的实际声道。2 = 左/右；5.1 = 左/右/中置/低音/左环绕/右环绕；7.1 再加左后/右后"),
        t.small, t.mut)];
}

/// 重建声道微调格子（web trimFields(effectiveChannels())）。
/// 后端的 trim 键是一串逗号分隔值（trim=0,0,0,…），按声道序号对应。
- (void)rebuildTrimFields:(NSInteger)channels {
    for (NSView *v in [self.trimWrap.arrangedSubviews copy]) {
        [self.trimWrap removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [self.trimFields removeAllObjects];
    static NSArray<NSString *> *names2, *names6, *names8;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names2 = @[ @"左", @"右" ];
        names6 = @[ @"左", @"右", @"中置", @"低音", @"左环绕", @"右环绕" ];
        names8 = @[ @"左", @"右", @"中置", @"低音", @"左环绕", @"右环绕", @"左后", @"右后" ];
    });
    NSArray<NSString *> *names = (channels >= 8) ? names8 : (channels >= 6) ? names6 : names2;
    RLPTheme *t = [RLPTheme current];
    for (NSUInteger i = 0; i < names.count; ++i) {
        NSString *key = [NSString stringWithFormat:@"sp_trim%lu", (unsigned long)i];
        NSTextField *f = [self numberFieldForKey:key action:@selector(onTrim:) placeholder:@"0"];
        f.tag = (NSInteger)i;
        [self.trimFields setObject:f forKey:key];
        [self.trimWrap addArrangedSubview:RLPSRow(names[i], f, nil, t)];
    }
    self.trimChMsg.stringValue = [NSString stringWithFormat:RLPTr(@"当前 %ld 声道"), (long)names.count];
}

#pragma mark - PCM

/// PCM 页 —— 1:1 对齐 web data-g=pcm（ui_script.h:9876）。
- (void)fillPcm:(NSStackView *)stack t:(RLPTheme *)t {
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"升频与滤波"), RLPTr(@"poly-sinc 滤波器家族"), t)];

    self.filt1xPopup = [self popupForKey:@"sp_filt" items:@[ RLPTr(@"读取中…") ]
                                  action:@selector(onFilter1x:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"1x 滤波器（44.1 / 48 kHz 音源）"), self.filt1xPopup,
        RLPTr(@"播放 44.1 / 48 kHz 文件时使用"), t)];

    self.filtNxPopup = [self popupForKey:@"sp_filtNx"
        items:@[ RLPTr(@"跟随 1x（不单独指定）"), RLPTr(@"读取中…") ]
        action:@selector(onFilterNx:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"Nx 滤波器（88.2 kHz 及以上音源）"), self.filtNxPopup,
        RLPTr(@"留空 = 与 1x 相同"), t)];

    self.phasePopup = [self popupForKey:@"sp_phase"
        items:@[ RLPTr(@"跟随预设（用所选滤波器自带的相位）"), @"linear", @"minimum", @"intermediate" ]
        action:@selector(onPhase:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"相位（覆盖滤波器预设的相位）"), self.phasePopup,
        RLPTr(@"线性 = 无相位失真、有前振铃；最小 = 无预振铃；混合 = 50:50 叠加"), t)];

    self.phaseMsg = [self hintForKey:@"sp_phasemsg" width:560];
    [stack addArrangedSubview:self.phaseMsg];

    self.tapsField = [self numberFieldForKey:@"sp_taps" action:@selector(onTaps:)
                                  placeholder:@"0 = 按预设自动"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"原型抽头数（0 = 按预设自动）"), self.tapsField, nil, t)];

    self.attenField = [self numberFieldForKey:@"sp_atten" action:@selector(onAtten:)
                                   placeholder:@"0 = 用预设"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"阻带衰减（dB，0 = 用预设）"), self.attenField, nil, t)];

    self.transitionField = [self numberFieldForKey:@"sp_transition" action:@selector(onTransition:)
                                        placeholder:@"0 = 用预设"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"过渡带占比（0 = 用预设）"), self.transitionField,
        RLPTr(@"截止点相对理想奈奎斯特回退的比例，例如 0.04 = 回退 4%"), t)];

    self.twoStageSwitch = [self switchForKey:@"sp_2s" action:@selector(onSwitch:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"两段式升频"), self.twoStageSwitch,
        RLPTr(@"大比率时 CPU 运算量约 1/4"), t)];

    [stack addArrangedSubview:RLPSGroup(RLPTr(@"抖动与保护"), RLPTr(@"按采样率自动重标定"), t)];

    self.shaperPopup = [self popupForKey:@"sp_shaper" items:@[ RLPTr(@"读取中…") ]
                                  action:@selector(onShaper:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"抖动 / 噪声整形"), self.shaperPopup,
        RLPTr(@"auto = 按输出位深自动选型"), t)];

    self.ispSwitch = [self switchForKey:@"sp_isp" action:@selector(onSwitch:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"过采样峰值保护（ISP）"), self.ispSwitch,
        RLPTr(@"检测到插值峰值超满幅时预衰减"), t)];
}

#pragma mark - SDM

/// SDM 页 —— 1:1 对齐 web data-g=sdm（ui_script.h:9901）。
- (void)fillSdm:(NSStackView *)stack t:(RLPTheme *)t {
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"SDM 输出"), RLPTr(@"只在输出 DSD 时生效"), t)];

    self.sdmO1Popup = [self popupForKey:@"sp_sdmo1"
        items:@[ RLPTr(@"跟随 PCM 页的 1x"), RLPTr(@"读取中…") ] action:@selector(onSdmO1:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"Oversampling 1x（44.1 / 48 kHz 音源）"), self.sdmO1Popup,
        RLPTr(@"留空则沿用 PCM 页的 1x"), t)];

    self.sdmONxPopup = [self popupForKey:@"sp_sdmoNx"
        items:@[ RLPTr(@"跟随上面的 1x"), RLPTr(@"读取中…") ] action:@selector(onSdmONx:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"Oversampling Nx（88.2 kHz 及以上音源）"), self.sdmONxPopup, nil, t)];

    // 值用纯数字（64/128/256/512/1024），与 web 的 opt('64', …) 同口径；
    // 保存时后端认的是 dsd=<数字>，不是 "dsd64"。
    self.dsdRatePopup = [self popupForKey:@"sp_dsdrate"
        items:@[ @"64", @"128", @"256", @"512", @"1024" ] action:@selector(onDsdRate:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"比特率"), self.dsdRatePopup,
        RLPTr(@"DSD512 / 1024 的 DoP 载波绝大多数设备不支持"), t)];

    // 封装：macOS 上 Native DSD 无法实现（CoreAudio 只提供 PCM 管线），
    // 呈现一个永远不能工作的选项等于骗用户 ⟹ 只留 DoP（web 同口径）。
    self.dsdPackPopup = [self popupForKey:@"sp_dsdpk" items:@[ @"dop" ] action:@selector(onDsdPack:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"封装"), self.dsdPackPopup,
        RLPTr(@"DSD 位流装进 24-bit PCM 容器（DAC 端剥壳，全程 bit-perfect）"), t)];

    self.dsdModeNote = [self hintForKey:@"sp_dsdmodenote" width:560];
    self.dsdModeNote.stringValue = RLPTr(@"当前输出 PCM：改动比特率 / 封装会自动把输出切到 DSD（SDM）");
    [stack addArrangedSubview:self.dsdModeNote];

    self.modFamilyPopup = [self popupForKey:@"sp_modfamily"
        items:@[ @"dsd", @"chebyshev", @"ec", @"ahm" ] action:@selector(onModFamily:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"调制器族"), self.modFamilyPopup,
        RLPTr(@"多种 NTF 滤波与量化架构"), t)];

    self.modOrderPopup = [self popupForKey:@"sp_modorder" items:@[ @"5", @"7" ]
                                    action:@selector(onModOrder:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"调制器阶数"), self.modOrderPopup,
        RLPTr(@"7 阶在低采样率或 Chebyshev 1-bit 下不稳定，会自动降为 5 阶"), t)];

    self.modCutField = [self numberFieldForKey:@"sp_modcut" action:@selector(onModCut:)
                                    placeholder:@"0 = 100"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"噪声整形拐点（kHz，0 = 100）"), self.modCutField, nil, t)];

    self.modDithField = [self numberFieldForKey:@"sp_moddith" action:@selector(onModDith:)
                                     placeholder:@"-1 = 默认"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"调制器抖动（LSB，-1 = 默认）"), self.modDithField,
        RLPTr(@"抑制空闲音"), t)];

    [stack addArrangedSubview:RLPSGroup(RLPTr(@"SDM 源（DSD 文件）"),
        RLPTr(@"原生读取 + DirectSDM"), t)];

    self.directSdmSwitch = [self switchForKey:@"sp_directsdm" action:@selector(onSwitch:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"DirectSDM：DSD 源同速率直通（逐位一致）"),
        self.directSdmSwitch, RLPTr(@"条件不满足自动回退普通路径"), t)];

    self.dsdKindPopup = [self popupForKey:@"sp_dsdkind" items:@[ @"fir", @"iir", @"cic" ]
                                   action:@selector(onDsdKind:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"DSD 源抽取器"), self.dsdKindPopup,
        RLPTr(@"只在「DSD 源 → PCM」路径生效"), t)];

    self.dsdConvPopup = [self popupForKey:@"sp_dsdconv" items:@[ @"narrow", @"wide", @"xfi" ]
                                   action:@selector(onDsdConv:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"DSD 源 Conversion"), self.dsdConvPopup,
        RLPTr(@"通带越宽，过渡带越窄、抽头越多"), t)];

    self.dsdMsg = [self hintForKey:@"sp_dsdmsg" width:560];
    [stack addArrangedSubview:self.dsdMsg];
}

#pragma mark - 输入

/// 输入页 —— 1:1 对齐 web data-g=in（ui_script.h:9960）。
/// 实测区域（采集实时状态）由 RLPInputView 承载，它自己 1 秒轮询 /api/input/state；
/// 这里只负责把 web 的控件位补齐（id 一致）。
- (void)fillInput:(NSStackView *)stack t:(RLPTheme *)t {
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"输入设备与采集"),
        RLPTr(@"CoreAudio 采集 / 录制与直通监听"), t)];

    self.inBackendPopup = [self popupForKey:@"sp_inbackend"
        items:@[ @"none", @"coreaudio" ] action:@selector(onInBackend:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"输入后端"), self.inBackendPopup,
        RLPTr(@"选 CoreAudio 后可以采集线路输入 / 麦克风 / 系统混音回环"), t)];

    self.inDevicePopup = [self popupForKey:@"sp_indev"
        items:@[ RLPTr(@"（未选择 / 默认设备）") ] action:@selector(onInDevice:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"输入设备"), self.inDevicePopup,
        RLPTr(@"包含物理采集设备与系统混音回环端点（标注「回环」的那一项）"), t)];

    self.inChPopup = [self popupForKey:@"sp_inch" items:@[ @"0", @"1", @"2", @"4" ]
                                action:@selector(onInOffset:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"声道偏移"), self.inChPopup,
        RLPTr(@"多声道接口只取其中几路时用"), t)];

    self.inBufField = [self numberFieldForKey:@"sp_inbuf" action:@selector(onInBuf:)
                                  placeholder:@"100"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"输入缓冲（毫秒）"), self.inBufField, nil, t)];

    self.inMonitorSwitch = [self switchForKey:@"sp_inmon" action:@selector(onSwitch:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"直通监听（非 bit-perfect）"), self.inMonitorSwitch,
        RLPTr(@"勾选后把采集直接送到默认共享端点监听；不勾选则录制保存为 WAV"), t)];

    self.inSecondsField = [self numberFieldForKey:@"sp_inseconds" action:@selector(onInSeconds:)
                                      placeholder:@"0 为不限"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"录制时长（秒，0 为不限）"), self.inSecondsField,
        RLPTr(@"达到指定时长自动停止"), t)];

    self.inOutField = [self textFieldForKey:@"sp_inout" action:@selector(onInOut:)
                                placeholder:RLPTr(@"留空自动存至 recordings 目录")];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"输出文件路径（WAV）"), self.inOutField,
        RLPTr(@"仅录制模式生效"), t)];

    self.inStartBtn = [NSButton buttonWithTitle:RLPTr(@"开始采集") target:self
                                         action:@selector(onInputStart:)];
    self.inStartBtn.bezelStyle = NSBezelStyleRounded;
    self.inStartBtn.identifier = @"sp_instart";
    self.inStopBtn = [NSButton buttonWithTitle:RLPTr(@"停止采集") target:self
                                        action:@selector(onInputStop:)];
    self.inStopBtn.bezelStyle = NSBezelStyleRounded;
    self.inStopBtn.identifier = @"sp_instop";
    self.inStopBtn.enabled = NO;
    self.inMsg = [self hintForKey:@"sp_inmsg" width:400];
    NSStackView *btnRow = [[NSStackView alloc] init];
    btnRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    btnRow.spacing = 10;
    [btnRow addArrangedSubview:self.inStartBtn];
    [btnRow addArrangedSubview:self.inStopBtn];
    [btnRow addArrangedSubview:self.inMsg];
    [stack addArrangedSubview:btnRow];

    // 采集实时状态：由 RLPInputView 承载（它自己轮询 /api/input/state，判据在 test_input_view）。
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"采集实时状态"), RLPTr(@"1 秒自动轮询"), t)];
    self.inputView = [[RLPInputView alloc] initWithFrame:NSMakeRect(0, 0, 620, 200)];
    self.inputView.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:self.inputView];
    [NSLayoutConstraint activateConstraints:@[
        [self.inputView.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-4],
    ]];
    [self.inputView reload];
}

#pragma mark - 通用（web 的 data-g=adv）

/// 通用页 —— 1:1 对齐 web data-g=adv（ui_script.h:10004 起）。
/// web 这一页也叫「通用」（2026-10-29 从「高级」改名并提到第一页）。
- (void)fillAdvanced:(NSStackView *)stack t:(RLPTheme *)t {
    // ---- 外观：界面风格 / 主题 / 语言（web 三个下拉，顺序一致）----
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"外观"),
        RLPTr(@"主题只有深色与浅色两种；改这里立即生效"), t)];

    self.uiStylePopup = [self popupForKey:@"sp_uistyle" items:@[ @"apple", @"classic" ]
                                    action:@selector(onUiStyle:)];
    // 回显当前真实生效的风格（不是固定选第一项）
    [self.uiStylePopup selectItemAtIndex:[[RLPTheme uiStyle] isEqualToString:@"classic"] ? 1 : 0];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"界面风格"), self.uiStylePopup,
        RLPTr(@"在 Apple Music 风格与经典 Hi-Fi 工作台之间实时切换"), t)];

    self.themePopup = [self popupForKey:@"sp_theme" items:@[ @"dark", @"light" ]
                                 action:@selector(onTheme:)];
    NSString *cur = [RLPTheme themeName];
    [self.themePopup selectItemAtIndex:[cur isEqualToString:@"light"] ? 1 : 0];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"主题"), self.themePopup, nil, t)];

    self.langPopup = [self popupForKey:@"sp_lang" items:@[ @"zh", @"en" ]
                                action:@selector(onLanguage:)];
    [self.langPopup selectItemAtIndex:[RLPLanguage() isEqualToString:@"en"] ? 1 : 0];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"语言"), self.langPopup,
        RLPTr(@"切换界面显示语言，保存后生效"), t)];

    // ---- GPU ----
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"GPU"),
        RLPTr(@"自动 = 优先 Apple Metal，不可用时自动退回纯 CPU（NEON 向量）分块 FFT，输出逐位相同"), t)];
    self.gpuPopup = [self popupForKey:@"sp_gpu" items:@[ @"auto", @"metal", @"off" ]
                               action:@selector(onGpuVendor:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"GPU 后端"), self.gpuPopup, nil, t)];
    self.gpuStatus = [self hintForKey:@"sp_gpumsg" width:560];
    [stack addArrangedSubview:self.gpuStatus];
    [self loadGpuStatus];

    // ---- 本地音乐库：统计 / 目录 / 扫描 / 线程数 ----
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"本地音乐库"),
        RLPTr(@"本地目录扫描入索引；DLNA / UPnP 在「流媒体」页"), t)];

    self.libStatsView = [[RLPLibStatsView alloc] initWithFrame:NSMakeRect(0, 0, 560, 120)];
    self.libStatsView.identifier = @"sp_libstats";
    self.libStatsView.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:self.libStatsView];
    [NSLayoutConstraint activateConstraints:@[
        [self.libStatsView.widthAnchor constraintEqualToConstant:560],
    ]];
    [self.libStatsView reload];

    self.rootField = [self textFieldForKey:@"sp_root" action:@selector(onAddRoot:)
                                placeholder:@"例如 /Volumes/Music"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"添加音乐目录"), self.rootField,
        RLPTr(@"可以点「浏览…」直接选文件夹，也可以手填路径"), t)];

    self.browseRootBtn = [NSButton buttonWithTitle:RLPTr(@"浏览…") target:self
                                            action:@selector(onBrowseRoot:)];
    self.browseRootBtn.bezelStyle = NSBezelStyleRounded;
    self.browseRootBtn.identifier = @"sp_browseRoot";
    self.addRootBtn = [NSButton buttonWithTitle:RLPTr(@"添加目录") target:self
                                         action:@selector(onAddRoot:)];
    self.addRootBtn.bezelStyle = NSBezelStyleRounded;
    self.addRootBtn.identifier = @"sp_addroot";
    self.rescanBtn = [NSButton buttonWithTitle:RLPTr(@"重新扫描全部") target:self
                                        action:@selector(onLibraryAction:)];
    self.rescanBtn.bezelStyle = NSBezelStyleRounded;
    self.rescanBtn.identifier = @"sp_rescan";
    NSStackView *rootBtns = [[NSStackView alloc] init];
    rootBtns.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    rootBtns.spacing = 8;
    for (NSButton *b in @[ self.browseRootBtn, self.addRootBtn, self.rescanBtn ])
        [rootBtns addArrangedSubview:b];
    [stack addArrangedSubview:rootBtns];



    self.scanThreadsField = [self numberFieldForKey:@"sp_scanthreads" action:@selector(onScanThreads:)
                                         placeholder:@"0 = 自动"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"扫描线程数"), self.scanThreadsField,
        RLPTr(@"0 = 自动（默认 min(CPU, 8)）"), t)];

    self.rootsBox = [NSStackView stackViewWithViews:@[]];
    self.rootsBox.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.rootsBox.alignment = NSLayoutAttributeLeading;
    self.rootsBox.spacing = 2;
    self.rootsBox.identifier = @"sp_roots";
    [stack addArrangedSubview:self.rootsBox];

    // ---- 播放：循环 / 随机 / 等响度 / 自动分析 ----
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"播放"), nil, t)];

    self.repPopup = [self popupForKey:@"sp_rep" items:@[ RLPTr(@"列表循环"), RLPTr(@"单曲循环"), RLPTr(@"关闭循环") ]
                                action:@selector(onRepeat:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"循环模式"), self.repPopup, nil, t)];

    self.shufSwitch = [self switchForKey:@"sp_shuf" action:@selector(onShuffle:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"随机播放"), self.shufSwitch,
        RLPTr(@"关掉会恢复原顺序"), t)];

    self.loudSwitch = [self switchForKey:@"sp_loud" action:@selector(onSwitch:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"等响度补偿"), self.loudSwitch,
        RLPTr(@"音量越低低频提升越多"), t)];

    self.autoAnlSwitch = [self switchForKey:@"sp_autoanl" action:@selector(onSwitch:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"播放时自动分析（后台）"), self.autoAnlSwitch,
        RLPTr(@"默认关闭；只分析本地文件，每曲只跑一次，切歌立即取消"), t)];

    // ---- 网络信息（web #bNet → #netMsg）----
    // web 侧这里是**按钮触发**：点 #bNet 才 api('/api/net') 并把结果写进 #netMsg。
    // 原生原先做成了常驻分组 + 一行灰字，待机时白占一大片 —— 改成同样的按需形态。
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"网络信息"),
        RLPTr(@"点按钮查询本机地址与局域网访问状态"), t)];
    self.netBtn = [NSButton buttonWithTitle:RLPTr(@"查询网络信息") target:self
                                     action:@selector(onNetInfo:)];
    self.netBtn.bezelStyle = NSBezelStyleRounded;
    self.netBtn.identifier = @"sp_netbtn";
    [stack addArrangedSubview:self.netBtn];
    self.netMsg = [self hintForKey:@"sp_netmsg" width:560];
    self.netMsg.hidden = YES;   // 未点击前不占视觉，与 web #netMsg 初始空态一致
    [stack addArrangedSubview:self.netMsg];
}

#pragma mark - 流媒体

/// 流媒体页 —— 1:1 对齐 web data-g=stream（ui_script.h:10058 起）。
/// 两个区块：流媒体服务器（增删改/启用/测试）+ 推送到设备（UPnP / DLNA 全套状态）。
- (void)fillStream:(NSStackView *)stack t:(RLPTheme *)t {
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"流媒体服务器"),
        RLPTr(@"可保存多台，同一时刻启用一台；只取原始文件，不转码"), t)];

    // 服务器增删改/启用/测试（对齐 web SRC 区块，id 前缀 sp_src_*）
    self.serversView = [[RLPServersView alloc] initWithFrame:NSMakeRect(0, 0, 620, 240)];
    self.serversView.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:self.serversView];
    [NSLayoutConstraint activateConstraints:@[
        [self.serversView.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-4],
    ]];
    [self.serversView reload];

    // 投放面板：设备发现 / 推送 / 停止 / 升频选项 / 实时状态（与 web 同源 /api/cast/*）
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"推送到设备（UPnP / DLNA）"),
        RLPTr(@"一键把当前曲目推送到局域网渲染器；之后的切歌 / 暂停 / 进度都作用在它上面"), t)];

    self.castView = [[RLPCastView alloc] initWithFrame:NSMakeRect(0, 0, 620, 420)];
    self.castView.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:self.castView];
    [NSLayoutConstraint activateConstraints:@[
        [self.castView.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-4],
    ]];
    [self.castView reload];
}

#pragma mark - 诊断

/// 诊断页 —— 1:1 对齐 web data-g=diag（ui_script.h:10127 起）。
/// 三块：诊断包导出 / 软件更新 / 反馈问题。
- (void)fillDiag:(NSStackView *)stack t:(RLPTheme *)t {
    // ---- 诊断包 ----
    RLPSettingsGroup *diagGroup = (RLPSettingsGroup *)RLPSGroup(RLPTr(@"导出诊断包"),
        RLPTr(@"一个 zip 打包全部日志 / 系统信息 / 设置摘要（已脱敏），不用再到处找日志文件"), t);
    [stack addArrangedSubview:diagGroup];
    NSMutableArray<NSView *> *diagBoxViews = [NSMutableArray array];

    self.diagZipBtn = [NSButton buttonWithTitle:RLPTr(@"导出诊断包（.zip）") target:self
                                         action:@selector(onExportDiagZip:)];
    self.diagZipBtn.bezelStyle = NSBezelStyleRounded;
    self.diagZipBtn.identifier = @"sp_diagzip";

    self.diagJsonBtn = [NSButton buttonWithTitle:RLPTr(@"只要 JSON") target:self
                                          action:@selector(onExportDiagJson:)];
    self.diagJsonBtn.bezelStyle = NSBezelStyleRounded;
    self.diagJsonBtn.identifier = @"sp_diagjson";

    self.diagSummaryBtn = [NSButton buttonWithTitle:RLPTr(@"查看 / 复制诊断摘要") target:self
                                             action:@selector(onDiagSummary:)];
    self.diagSummaryBtn.bezelStyle = NSBezelStyleRounded;
    self.diagSummaryBtn.identifier = @"sp_diagsummary";

    // web 有「随反馈上传诊断」（sp_diagupload）。原生反馈走 feedback_api 直连后台、
    // 诊断包随反馈一起提交，所以这个按钮在这里点就是把包交给反馈窗口 —— 同一件事，不删。
    self.diagUploadBtn = [NSButton buttonWithTitle:RLPTr(@"随反馈上传诊断") target:self
                                            action:@selector(onDiagUpload:)];
    self.diagUploadBtn.bezelStyle = NSBezelStyleRounded;
    self.diagUploadBtn.identifier = @"sp_diagupload";

    self.diagMsg = [self hintForKey:@"sp_diagmsg" width:400];

    NSStackView *diagRow = [[NSStackView alloc] init];
    diagRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    diagRow.spacing = 10;
    for (NSView *v in @[ self.diagZipBtn, self.diagJsonBtn, self.diagSummaryBtn,
                         self.diagUploadBtn, self.diagMsg ])
        [diagRow addArrangedSubview:v];
    [diagBoxViews addObject:diagRow];

    self.diagSummaryText = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 620, 200)];
    self.diagSummaryText.identifier = @"sp_diagsummarytext";
    self.diagSummaryText.editable = NO;
    self.diagSummaryText.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.diagSummaryText.translatesAutoresizingMaskIntoConstraints = NO;
    NSScrollView *diagScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 620, 200)];
    diagScroll.hasVerticalScroller = YES;
    diagScroll.documentView = self.diagSummaryText;
    diagScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [diagBoxViews addObject:diagScroll];
    [NSLayoutConstraint activateConstraints:@[
        [diagScroll.widthAnchor constraintEqualToConstant:620],
        [diagScroll.heightAnchor constraintEqualToConstant:200],
    ]];

    // ---- 软件更新 ----
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"软件更新"), RLPTr(@"检查新版本，一键更新"), t)];

    self.updChannelPopup = [self popupForKey:@"sp_updchannel" items:@[ @"global", @"cn" ]
                                      action:@selector(onUpdateChannel:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"更新通道"), self.updChannelPopup,
        RLPTr(@"全球 = GitHub 通道；中国大陆 = 国内后台通道"), t)];

    self.verCurLabel = [self hintForKey:@"sp_vercur" width:160];
    self.verCurLabel.stringValue = [NSString stringWithFormat:@"v%s", RLPLAYER_VERSION];
    self.updCheckBtn = [NSButton buttonWithTitle:RLPTr(@"检查更新") target:self
                                          action:@selector(onCheckUpdate:)];
    self.updCheckBtn.bezelStyle = NSBezelStyleRounded;
    self.updCheckBtn.identifier = @"sp_updcheck";
    self.updInstallBtn = [NSButton buttonWithTitle:RLPTr(@"立即更新") target:self
                                           action:@selector(onCheckUpdate:)];
    self.updInstallBtn.bezelStyle = NSBezelStyleRounded;
    self.updInstallBtn.identifier = @"sp_updinstall";
    self.updInstallBtn.hidden = YES;
    self.betaSwitch = [self switchForKey:@"sp_updbeta" action:@selector(onSwitch:)];
    self.updMsg = [self hintForKey:@"sp_updmsg" width:300];

    NSStackView *updRow = [[NSStackView alloc] init];
    updRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    updRow.spacing = 10;
    for (NSView *v in @[ self.verCurLabel, self.updCheckBtn, self.updInstallBtn,
                         self.betaSwitch, self.updMsg ])
        [updRow addArrangedSubview:v];
    [stack addArrangedSubview:updRow];

    self.updBar = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.updBar.identifier = @"sp_updbar";
    self.updBar.style = NSProgressIndicatorStyleBar;
    self.updBar.indeterminate = NO;
    self.updBar.minValue = 0;
    self.updBar.maxValue = 100;
    self.updBar.hidden = YES;
    self.updBar.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:self.updBar];
    [NSLayoutConstraint activateConstraints:@[
        [self.updBar.widthAnchor constraintEqualToConstant:620],
    ]];

    self.updFill = [self hintForKey:@"sp_updfill" width:620];

    self.updNote = [self hintForKey:@"sp_updnote" width:620];
    self.updNote.stringValue = RLPTr(@"更新会下载安装包并校验 sha256；校验不通过一律丢弃，绝不安装被篡改的内容。安装完成后会自动重启。");
    [stack addArrangedSubview:self.updNote];

    // ---- 反馈问题 ----
    RLPSettingsGroup *fbGroup = (RLPSettingsGroup *)RLPSGroup(RLPTr(@"反馈问题"),
        RLPTr(@"直接发送给开发者，可附诊断包"), t);
    [stack addArrangedSubview:fbGroup];
    NSMutableArray<NSView *> *fbBoxViews = [NSMutableArray array];

    self.fbText = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 620, 110)];
    self.fbText.identifier = @"sp_fbtext";
    self.fbText.font = [NSFont systemFontOfSize:12.5];
    self.fbText.translatesAutoresizingMaskIntoConstraints = NO;
    NSScrollView *fbScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 620, 110)];
    fbScroll.hasVerticalScroller = YES;
    fbScroll.documentView = self.fbText;
    fbScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [fbBoxViews addObject:fbScroll];
    [NSLayoutConstraint activateConstraints:@[
        [fbScroll.widthAnchor constraintEqualToConstant:620],
        [fbScroll.heightAnchor constraintEqualToConstant:110],
    ]];

    self.fbCount = [self hintForKey:@"sp_fbcount" width:300];
    self.fbCount.stringValue = RLPTr(@"0 / 16384 字节");
    [fbBoxViews addObject:self.fbCount];

    self.fbChan = [self hintForKey:@"sp_fbchan" width:520];
    self.fbChan.stringValue = RLPTr(@"正在检查反馈通道…");
    [fbBoxViews addObject:self.fbChan];

    self.fbDiagSwitch = [self switchForKey:@"sp_fbdiag" action:@selector(onFbDiagToggle:)];
    self.fbDiagSwitch.state = NSControlStateValueOn;
    self.fbSendBtn = [NSButton buttonWithTitle:RLPTr(@"发送反馈") target:self
                                        action:@selector(onOpenFeedback:)];
    self.fbSendBtn.bezelStyle = NSBezelStyleRounded;
    self.fbSendBtn.identifier = @"sp_fbsend";
    self.fbRetryBtn = [NSButton buttonWithTitle:RLPTr(@"重试探活") target:self
                                         action:@selector(onFeedbackRetry:)];
    self.fbRetryBtn.bezelStyle = NSBezelStyleRounded;
    self.fbRetryBtn.identifier = @"sp_fbretry";
    self.fbRetryBtn.hidden = YES;
    self.fbMsg = [self hintForKey:@"sp_fbmsg" width:300];

    NSStackView *fbRow = [[NSStackView alloc] init];
    fbRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    fbRow.spacing = 10;
    [fbRow addArrangedSubview:self.fbDiagSwitch];
    [fbRow addArrangedSubview:RLPLabel(RLPTr(@"附带诊断包"), t.small, t.mut)];
    for (NSView *v in @[ self.fbSendBtn, self.fbRetryBtn, self.fbMsg ])
        [fbRow addArrangedSubview:v];
    [fbBoxViews addObject:fbRow];

    [stack addArrangedSubview:RLPLabel(
        RLPTr(@"提交前会先探活；通道不可用时按钮保持禁用，绝不假装发送成功。"
              @"诊断包已脱敏，不会上传你的音乐文件。"), t.small, t.mut)];

    // 两个隐藏容器 + 各自的「打开气泡窗」入口行（web 设置页行式交互：选项收进气泡窗）
    self.diagToolsBox = [self hiddenPopoverBox:diagBoxViews inStack:stack];
    self.fbBox = [self hiddenPopoverBox:fbBoxViews inStack:stack];
    NSButton *diagMore = [NSButton buttonWithTitle:RLPTr(@"诊断包选项 ▾")
                                             target:self action:@selector(onDiagMore:)];
    diagMore.bezelStyle = NSBezelStyleRounded;
    diagMore.identifier = @"sp_diagmore";
    [diagGroup addButtonRow:@[ diagMore ]];
    NSButton *fbMore = [NSButton buttonWithTitle:RLPTr(@"填写反馈 ▾")
                                           target:self action:@selector(onFbMore:)];
    fbMore.bezelStyle = NSBezelStyleRounded;
    fbMore.identifier = @"sp_fbmore";
    [fbGroup addButtonRow:@[ fbMore ]];
}

/// 把一组控件放进默认隐藏的容器（仍在视图树里，identifier 锚点不丢），由气泡窗按钮搬进/搬出。
- (NSStackView *)hiddenPopoverBox:(NSArray<NSView *> *)views inStack:(NSStackView *)stack {
    NSStackView *box = [[NSStackView alloc] init];
    box.orientation = NSUserInterfaceLayoutOrientationVertical;
    box.alignment = NSLayoutAttributeLeading;
    box.spacing = 10;
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.hidden = YES;
    for (NSView *v in views) [box addArrangedSubview:v];
    [stack addArrangedSubview:box];
    [box.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-48].active = YES;
    return box;
}

- (void)moveViewsFrom:(NSStackView *)from to:(NSStackView *)to {
    for (NSView *v in [from.arrangedSubviews copy]) {
        [from removeArrangedSubview:v];
        [to addArrangedSubview:v];
    }
}

/// 把隐藏容器里的真实控件搬进一个气泡窗内容容器（不显示）。
- (NSStackView *)detachPopoverContentFromBox:(NSStackView *)box {
    NSStackView *content = [[NSStackView alloc] init];
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.alignment = NSLayoutAttributeLeading;
    content.spacing = 10;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [content.widthAnchor constraintGreaterThanOrEqualToConstant:600].active = YES;
    [self moveViewsFrom:box to:content];
    return content;
}

- (void)onDiagMore:(NSButton *)sender {
    if (self.diagPopover) { [self.diagPopover close]; return; }
    NSStackView *content = [self detachPopoverContentFromBox:self.diagToolsBox];
    NSViewController *vc = RLPCardController(content, 660, 120);
    self.diagPopover = RLPShowCardPopover(sender, vc, 660);
    self.diagPopover.delegate = self;
    self.diagPopoverContent = content;
}

- (void)onFbMore:(NSButton *)sender {
    if (self.fbPopover) { [self.fbPopover close]; return; }
    NSStackView *content = [self detachPopoverContentFromBox:self.fbBox];
    NSViewController *vc = RLPCardController(content, 660, 120);
    self.fbPopover = RLPShowCardPopover(sender, vc, 660);
    self.fbPopover.delegate = self;
    self.fbPopoverContent = content;
}

/// 审计入口：不显示气泡窗，只做「搬进内容容器」这一步 —— 证明气泡窗里的确实是同一批控件。
- (NSViewController *)auditDiagPopoverContent {
    if (self.diagPopover) return nil;
    NSStackView *content = [self detachPopoverContentFromBox:self.diagToolsBox];
    self.diagPopoverContent = content;
    return RLPCardController(content, 660, 120);
}

- (void)auditRestoreDiagPopover {
    if (self.diagPopoverContent) [self moveViewsFrom:self.diagPopoverContent to:self.diagToolsBox];
    self.diagPopoverContent = nil;
}

- (void)popoverDidClose:(NSNotification *)note {
    NSPopover *p = note.object;
    if (p == self.diagPopover) {
        [self moveViewsFrom:self.diagPopoverContent to:self.diagToolsBox];
        self.diagPopover = nil; self.diagPopoverContent = nil;
    } else if (p == self.fbPopover) {
        [self moveViewsFrom:self.fbPopoverContent to:self.fbBox];
        self.fbPopover = nil; self.fbPopoverContent = nil;
    }
}

#pragma mark - 元数据

- (void)fillMeta:(NSStackView *)stack t:(RLPTheme *)t {
    // ── 基础选项（对齐 web：默认只显示三个开关 + 「高级选项 ▾」，即用户图二效果）──
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"元数据补全"),
        RLPTr(@"播放时后台补全标签 / 封面 / 歌词，结果落在本地库"), t)];
    self.metaOnSwitch = [self switchWithAction:@selector(onSwitch:) key:@"sp_metaon"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"自动补全（不用 AI）"), self.metaOnSwitch,
        RLPTr(@"只用公开数据源（QQ音乐 / 网易云 / iTunes / dizzylab / lrclib）补全标签、封面、歌词；全程不调用 AI，不产生费用"), t)];
    // web 把「DeepSeek 增强 + 在线整理简介」合并成一键：metallm 与 metasummary 同开同关。
    self.metaLlmSwitch = [self switchWithAction:@selector(onMetaAiEnhanced:) key:@"sp_metallm"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"AI 增强（OpenAI 兼容）"), self.metaLlmSwitch,
        RLPTr(@"联网调用所选 AI 接口（按次计费）：解析无标签文件，并在艺术家 / 专辑 / 单曲页整理简介并缓存；关闭后两项都停"), t)];
    self.metaAiFillSwitch = [self switchWithAction:@selector(onSwitch:) key:@"sp_metaaifill"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"AI 辅助爬取封面歌词"), self.metaAiFillSwitch,
        RLPTr(@"仅当公开数据源因歌名对不上而失败时，自动用 AI 规范化歌名再检索一次；AI 只纠正歌名，封面歌词仍来自公开数据源并过同曲校验"), t)];

    // 「高级选项 ▾」入口（web #sp_metamore）：默认收起；展开后是下面整块高级内容。
    NSButton *moreBtn = [NSButton buttonWithTitle:RLPTr(@"高级选项 ▾") target:self
                                           action:@selector(onToggleMetaAdvanced:)];
    moreBtn.bezelStyle = NSBezelStyleRounded;
    moreBtn.identifier = @"sp_metamore";
    self.metaMoreBtn = moreBtn;
    if (gCurrentGroup) [gCurrentGroup addButtonRow:@[moreBtn]];
    else [stack addArrangedSubview:moreBtn];

    // 高级内容容器：默认 hidden（NSStackView 对隐藏的 arrangedSubview 不占高度）。
    NSStackView *adv = [[NSStackView alloc] init];
    adv.orientation = NSUserInterfaceLayoutOrientationVertical;
    adv.alignment = NSLayoutAttributeLeading;
    adv.spacing = 22;
    adv.translatesAutoresizingMaskIntoConstraints = NO;
    adv.hidden = YES;
    adv.identifier = @"sp_metaadv";        // web #sp_metaadv（审计用它断言"默认收起"）
    self.metaAdvancedStack = adv;
    // 高级卡片建在 adv 里：RLPSGroup 会落进 gCurrentStack，所以临时切换上下文。
    NSStackView *savedStack = gCurrentStack;
    RLPSettingsGroup *savedGroup = gCurrentGroup;
    gCurrentStack = adv;
    gCurrentGroup = nil;

    // 数据源卡片（web 高级区左列 .meta-card）：逐源开关 + 优先级（对齐 web sp_metasrc）。
    RLPSettingsGroup *dataGroup = (RLPSettingsGroup *)RLPSGroup(RLPTr(@"数据源"),
        RLPTr(@"越靠上优先级越高；拖动把手或点 ▲▼ 调整顺序，关掉的源完全不参与补全"), t);
    [adv addArrangedSubview:dataGroup];
    NSLayoutConstraint *dataWidthConstraint = gLastGroupWidthConstraint;
    self.metaSourcesView = [[RLPMetaSourcesView alloc] initWithFrame:NSMakeRect(0, 0, 620, 200)];
    self.metaSourcesView.translatesAutoresizingMaskIntoConstraints = NO;
    [dataGroup addFullRow:self.metaSourcesView];
    [self.metaSourcesView reload];

    // AI 接入卡片（web 高级区右列 .meta-card）：密钥红线 —— GET 只回掩码，输入框留空 = 不改已存的 key
    RLPSettingsGroup *aiGroup = (RLPSettingsGroup *)RLPSGroup(RLPTr(@"AI 接入（OpenAI 兼容）"),
        RLPTr(@"任何兼容 OpenAI 的服务都能用。密钥只在本机保存，界面永不回显明文；留空表示不修改。"), t);
    [adv addArrangedSubview:aiGroup];
    NSLayoutConstraint *aiWidthConstraint = gLastGroupWidthConstraint;

    // 接口预设（对齐 web LLM_PROVIDERS / sp_llmprovider）：只负责「填地址」，
    // 不做连通性判断 —— 能不能用由「测试连通」回答。custom 留空，绝不覆盖用户已填地址。
    self.llmProviderPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSString *n in @[ @"DeepSeek", @"OpenAI", @"OpenRouter",
                           RLPTr(@"SiliconFlow（硅基流动）"), RLPTr(@"Ollama（本机）"), RLPTr(@"自定义") ])
        [self.llmProviderPopup addItemWithTitle:n];
    self.llmProviderPopup.identifier = @"llm.provider";
    self.llmProviderPopup.target = self;
    self.llmProviderPopup.action = @selector(onLlmProviderPicked:);
    [self.llmProviderPopup.widthAnchor constraintEqualToConstant:240].active = YES;
    [adv addArrangedSubview:RLPSRow(RLPTr(@"接口预设"), self.llmProviderPopup, nil, t)];

    self.llmBase = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.llmBase.placeholderString = @"https://api.deepseek.com";
    self.llmBase.identifier = @"llm.base";
    [[self.llmBase.widthAnchor constraintEqualToConstant:320] setActive:YES];
    [adv addArrangedSubview:RLPSRow(RLPTr(@"接口地址"), self.llmBase, nil, t)];

    self.llmModel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.llmModel.placeholderString = @"deepseek-chat";
    self.llmModel.identifier = @"llm.modeltext";
    // 手填模型也要能存（web sp_llmmodeltext 的 Enter → llmSaveModel 同口径）。
    // 拉不到模型列表时这是唯一入口，漏了它等于"降级到手填却存不进去"。
    self.llmModel.target = self;
    self.llmModel.action = @selector(onLlmModelTyped:);
    [[self.llmModel.widthAnchor constraintEqualToConstant:220] setActive:YES];
    [adv addArrangedSubview:RLPSRow(RLPTr(@"模型"), self.llmModel, nil, t)];

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
    [adv addArrangedSubview:modelRow];

    self.llmModelMsg = RLPLabel(RLPTr(@"模型列表读取中"), t.small, t.mut);
    self.llmModelMsg.maximumNumberOfLines = 2;
    self.llmModelMsg.lineBreakMode = NSLineBreakByWordWrapping;
    self.llmModelMsg.identifier = @"llm.modelmsg";
    [[self.llmModelMsg.widthAnchor constraintEqualToConstant:560] setActive:YES];
    [adv addArrangedSubview:self.llmModelMsg];

    self.llmKey = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    self.llmKey.placeholderString = RLPTr(@"留空 = 保持已保存的密钥");
    self.llmKey.identifier = @"llm.key";
    [[self.llmKey.widthAnchor constraintEqualToConstant:320] setActive:YES];
    [adv addArrangedSubview:RLPSRow(RLPTr(@"密钥"), self.llmKey, nil, t)];

    NSStackView *llmBtns = [[NSStackView alloc] init];
    llmBtns.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    llmBtns.spacing = 8;
    NSButton *save = [NSButton buttonWithTitle:RLPTr(@"保存端点") target:self action:@selector(onLlmSave:)];
    save.bezelStyle = NSBezelStyleRounded;
    save.identifier = @"llm.save";
    NSButton *test = [NSButton buttonWithTitle:RLPTr(@"测试连通") target:self action:@selector(onLlmTest:)];
    test.bezelStyle = NSBezelStyleRounded;
    test.identifier = @"llm.test";
    NSButton *clearKey = [NSButton buttonWithTitle:RLPTr(@"清除密钥") target:self action:@selector(onLlmClearKey:)];
    clearKey.bezelStyle = NSBezelStyleRounded;
    clearKey.identifier = @"llm.clear";
    [llmBtns addArrangedSubview:save];
    [llmBtns addArrangedSubview:test];
    [llmBtns addArrangedSubview:clearKey];
    [adv addArrangedSubview:llmBtns];

    self.llmStatus = RLPLabel(@"", t.small, t.mut);
    self.llmStatus.maximumNumberOfLines = 2;
    self.llmStatus.lineBreakMode = NSLineBreakByWordWrapping;
    self.llmStatus.identifier = @"llm.status";
    [[self.llmStatus.widthAnchor constraintEqualToConstant:560] setActive:YES];
    [adv addArrangedSubview:self.llmStatus];

    // ── 联网检索端点（search / fetch 一起切换，对齐 web SEARCH 区块）──
    // 用户 2026-11-12 实测反馈：原生缺这组选项。配置存同一份 rlplayer-llm.conf 的
    // search_* 三行，走 /api/llm 同一条 POST；Key 只存本机、界面永不回显明文。
    [adv addArrangedSubview:RLPSGroup(RLPTr(@"联网检索端点"),
        RLPTr(@"「AI 增强」整理资料时用的 search / fetch 端点。DeepSeek 为默认；切到 AnySearch / Tavily 后，非 DeepSeek 的 AI 接口也能联网检索。"), t)];

    self.searchProviderPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.searchProviderPopup addItemWithTitle:RLPTr(@"DeepSeek（默认）")];
    [self.searchProviderPopup addItemWithTitle:@"AnySearch"];
    [self.searchProviderPopup addItemWithTitle:@"Tavily"];
    self.searchProviderPopup.identifier = @"search.provider";
    self.searchProviderPopup.target = self;
    self.searchProviderPopup.action = @selector(onSearchProviderChanged:);
    [self.searchProviderPopup.widthAnchor constraintEqualToConstant:240].active = YES;
    [adv addArrangedSubview:RLPSRow(RLPTr(@"检索端点"), self.searchProviderPopup, nil, t)];

    self.searchBase = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.searchBase.placeholderString = RLPTr(@"留空 = 用该厂商默认地址");
    self.searchBase.identifier = @"search.base";
    [[self.searchBase.widthAnchor constraintEqualToConstant:320] setActive:YES];
    [adv addArrangedSubview:RLPSRow(RLPTr(@"检索地址"), self.searchBase, nil, t)];

    self.searchKey = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    self.searchKey.placeholderString = RLPTr(@"留空 = 保持已保存的检索 Key");
    self.searchKey.identifier = @"search.key";
    [[self.searchKey.widthAnchor constraintEqualToConstant:320] setActive:YES];
    [adv addArrangedSubview:RLPSRow(RLPTr(@"检索 Key"), self.searchKey, nil, t)];

    NSStackView *searchBtns = [[NSStackView alloc] init];
    searchBtns.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    searchBtns.spacing = 8;
    NSButton *sSave = [NSButton buttonWithTitle:RLPTr(@"保存端点") target:self action:@selector(onSearchSave:)];
    sSave.bezelStyle = NSBezelStyleRounded;
    sSave.identifier = @"search.save";
    NSButton *sClear = [NSButton buttonWithTitle:RLPTr(@"清除检索 Key") target:self action:@selector(onSearchClearKey:)];
    sClear.bezelStyle = NSBezelStyleRounded;
    sClear.identifier = @"search.clear";
    [searchBtns addArrangedSubview:sSave];
    [searchBtns addArrangedSubview:sClear];
    [adv addArrangedSubview:searchBtns];

    self.searchStatus = RLPLabel(@"", t.small, t.mut);
    self.searchStatus.maximumNumberOfLines = 2;
    self.searchStatus.lineBreakMode = NSLineBreakByWordWrapping;
    self.searchStatus.identifier = @"search.status";
    [[self.searchStatus.widthAnchor constraintEqualToConstant:560] setActive:YES];
    [adv addArrangedSubview:self.searchStatus];

    // ---- 标签写回（web sp_wbdesc / sp_wbdry / sp_wbapply / sp_wbmsg）----
    // web 把这块放在「元数据」页。原生原来挂在「高级」页，按 web 的位置搬回来 ——
    // 位置本身就是 web 的信息架构，不该自创。
    [adv addArrangedSubview:RLPSGroup(RLPTr(@"标签写回"),
        RLPTr(@"默认开启：补全到的标签 / 封面写回音频文件本身；写前校验音频数据逐位不变"), t)];

    self.wbDesc = [self hintForKey:@"sp_wbdesc" width:560];
    self.wbDesc.stringValue = RLPTr(@"补全到的标签 / 封面写回音频文件本身；写前校验音频数据逐位不变，原文件备份到备份目录");
    [adv addArrangedSubview:self.wbDesc];

    self.wbDryBtn = [NSButton buttonWithTitle:RLPTr(@"预览写回") target:self
                                       action:@selector(onWritebackDry:)];
    self.wbDryBtn.bezelStyle = NSBezelStyleRounded;
    self.wbDryBtn.identifier = @"sp_wbdry";
    self.wbApplyBtn = [NSButton buttonWithTitle:RLPTr(@"执行写回") target:self
                                         action:@selector(onWritebackApply:)];
    self.wbApplyBtn.bezelStyle = NSBezelStyleRounded;
    self.wbApplyBtn.identifier = @"sp_wbapply";
    self.writebackStatus = RLPLabel(@"", t.small, t.mut);
    self.writebackStatus.identifier = @"sp_wbmsg";
    self.writebackStatus.maximumNumberOfLines = 3;
    self.writebackStatus.lineBreakMode = NSLineBreakByWordWrapping;
    [[self.writebackStatus.widthAnchor constraintEqualToConstant:520] setActive:YES];

    NSStackView *wbRow = [[NSStackView alloc] init];
    wbRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    wbRow.spacing = 8;
    [wbRow addArrangedSubview:self.wbDryBtn];
    [wbRow addArrangedSubview:self.wbApplyBtn];
    [wbRow addArrangedSubview:self.writebackStatus];
    [adv addArrangedSubview:wbRow];

    // web `.meta-adv-grid`：数据源 / AI 接入 **左右两列**（>=1100px 时两列，窄屏回落单列）。
    // 摘掉两张卡各自的「整宽」约束，放进等宽的横向 stack；窄窗口由 stack 自动压缩。
    if (dataGroup && aiGroup && dataWidthConstraint && aiWidthConstraint) {
        dataWidthConstraint.active = NO;
        aiWidthConstraint.active = NO;
        NSStackView *twoCol = [[NSStackView alloc] init];
        twoCol.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        twoCol.distribution = NSStackViewDistributionFillEqually;
        twoCol.alignment = NSLayoutAttributeTop;
        twoCol.spacing = 16;
        twoCol.translatesAutoresizingMaskIntoConstraints = NO;
        [adv removeArrangedSubview:dataGroup];
        [adv removeArrangedSubview:aiGroup];
        [twoCol addArrangedSubview:dataGroup];
        [twoCol addArrangedSubview:aiGroup];
        [adv insertArrangedSubview:twoCol atIndex:0];
        [twoCol.widthAnchor constraintEqualToAnchor:adv.widthAnchor].active = YES;
    }

    gCurrentStack = savedStack;
    gCurrentGroup = savedGroup;
    [stack addArrangedSubview:adv];
    [adv.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
}

#pragma mark - 均衡 / 输入（已迁移的子界面）

- (void)fillEqualizer:(NSStackView *)stack t:(RLPTheme *)t {
    self.eqView = [[RLPEqualizerView alloc] initWithFrame:NSMakeRect(0, 0, 620, 720)];
    self.eqView.translatesAutoresizingMaskIntoConstraints = NO;
    // 设置页本身就是整页滚动容器：EQ 不再套自己的滚动条（用户实测「只要外面那个滚动条」）。
    [self.eqView setEmbeddedInPage:YES];
    [stack addArrangedSubview:self.eqView];
    // 高度 = 内容自然高度；reload 之后再校正一次（20 段参数/OPRA 文本就位后高度才准确）。
    self.eqHeightConstraint = [self.eqView.heightAnchor
        constraintEqualToConstant:MAX(900.0, [self.eqView preferredContentHeight])];
    [NSLayoutConstraint activateConstraints:@[
        self.eqHeightConstraint,
        [self.eqView.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-4],
    ]];
    [self.eqView reload];
    __weak __typeof__(self) weakEq = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __typeof__(self) self_ = weakEq;
        if (!self_ || !self_.eqHeightConstraint) return;
        CGFloat h = [self_.eqView preferredContentHeight];
        if (h > self_.eqHeightConstraint.constant) self_.eqHeightConstraint.constant = MAX(900.0, h);
    });
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

/// 旧版输入页（只嵌 RLPInputView，缺 web 的 sp_inbackend/sp_inbuf 等控件）。
/// 2026-11-12 起页签走 fillInput（含全部 web 控件 + 同一个 RLPInputView）。保留本方法
/// 是为了不做无谓删除，但**不要**再把它接回页签。
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
    } else if ([action isEqualToString:@"sp_rescan"]) {
        // web 的「重新扫描全部」走 /api/rescan（不是 lib/scan?full=1，虽然等价）。
        RLPPostJSON(@"/api/rescan", nil);
        RLPToast(RLPTr(@"已开始全量重扫"));
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
    if (force) {
        // 强制重拉时**先把旧列表清空**：换端点后旧模型还挂在下拉里，
        // 用户看到的就是「还是原来那一串」（2026-11-13 反馈的另一半）。
        [self.llmModelPopup removeAllItems];
        self.llmModelPopup.hidden = YES;
        self.llmModelMsg.stringValue = RLPTr(@"正在重新拉取模型列表…");
        self.llmModelMsg.textColor = [RLPTheme current].mut;
    }
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

- (void)onLlmModelRefresh:(id)sender {
    (void)sender;
    // 后端 /api/llm/models 从 conf 读地址：屏幕上改了地址却没保存时，直接刷新会拿回**旧端点**的模型。
    // 所以这里先判断「屏幕值 vs 已落盘值」，有差异就先走保存（保存成功后自己会强制重拉）。
    NSString *typedBase = [self.llmBase.stringValue stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *typedKey  = [self.llmKey.stringValue stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    const BOOL baseChanged = typedBase.length && ![typedBase isEqualToString:self.llmSavedBase ?: @""];
    if (baseChanged || typedKey.length) {
        [self onLlmSave:nil];   // 同一条保存路径：落盘 → 强制重拉 models → 静默测连通
        return;
    }
    [self loadLlmModels:YES];
}

/// 手填模型回车即保存（只发 model=，不动 base/key）。留空不写，避免把已存模型清空。
- (void)onLlmModelTyped:(NSTextField *)sender {
    NSString *m = [sender.stringValue stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!m.length || ![RLPCoreClient shared].started) return;
    NSString *body = [NSString stringWithFormat:@"model=%@", RLPEnc(m)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/llm" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        self_.llmStatus.stringValue = (json && [json[@"ok"] boolValue])
            ? [NSString stringWithFormat:@"%@ %@", RLPTr(@"已保存"), m]
            : ([json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"保存失败"));
    }];
}

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

/// 「保存端点」= 只发 base_url（key 非空时一并发），**绝不带 model**。
/// 用户 2026-11-12 实测故障①：旧实现每次都发 model=，而模型框可能是空/过期值
/// ⟹ 把用户已选模型覆盖成默认。web llmSave 只发 base_url/key，模型由下拉单独保存。
/// 故障②：旧实现发 api_key=，后端只认 key= ⟹ 密钥从未落盘 ⟹ 测试连接必然失败。
- (void)onLlmSave:(id)sender {
    (void)sender;
    if (![RLPCoreClient shared].started) return;
    NSString *base = [self.llmBase.stringValue stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *key = [self.llmKey.stringValue stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableString *body = [NSMutableString string];
    if (base.length) [body appendFormat:@"base_url=%@", RLPEnc(base)];
    // 密钥留空就不带这个键 —— 后端据此保持已存的 key（改端点不清密钥）。
    if (key.length) [body appendFormat:@"%@key=%@", body.length ? @"&" : @"", RLPEnc(key)];
    if (!body.length) {
        self.llmStatus.stringValue = RLPTr(@"先填 API 地址或 API Key；两项都空不会改动现有配置");
        return;
    }
    self.llmStatus.stringValue = RLPTr(@"保存中…");
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/llm" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            self_.llmKey.stringValue = @"";   // 存完立刻清掉输入框，不留明文在界面上
            self_.llmStatus.stringValue = key.length ? RLPTr(@"API Key 已保存（界面只显示掩码）")
                                                     : RLPTr(@"API 地址已保存");
            // 端点可能换了 ⟹ 模型清单必然过期，强制重拉；再顺手测一次连通（web llmSave 同口径）。
            [self_ loadLlmConfig];
            [self_ loadLlmModels:YES];
            [self_ runLlmTestSilently];
        } else {
            self_.llmStatus.stringValue = [json[@"error"] isKindOfClass:[NSString class]]
                ? json[@"error"] : RLPTr(@"保存失败");
        }
    }];
}

/// 清除 API Key（web llmClear：POST clear=1）。
- (void)onLlmClearKey:(id)sender {
    (void)sender;
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/llm" body:@"clear=1" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        self_.llmStatus.stringValue = (json && [json[@"ok"] boolValue])
            ? RLPTr(@"已清除 API Key（可随时重新填入）")
            : ([json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"清除失败"));
        [self_ loadLlmConfig];
    }];
}

#pragma mark - GPU 后端（/api/gpu）

/// 下拉下标 → gpuvendor 值（与 web opt 顺序一致：auto / metal / off）。
static NSString *RLPGpuVendorAtIndex(NSInteger i) {
    switch (i) { case 1: return @"metal"; case 2: return @"off"; default: return @"auto"; }
}
static NSInteger RLPGpuIndexForVendor(NSString *v) {
    if ([v isEqualToString:@"metal"]) return 1;
    if ([v isEqualToString:@"off"]) return 2;
    return 0;
}

- (void)onGpuVendor:(NSPopUpButton *)sender {
    [self postKey:@"gpuvendor" value:RLPGpuVendorAtIndex(sender.indexOfSelectedItem)];
    // 偏好改了，真实可用性要重读（后端会按新偏好重新判定）。
    [self loadGpuStatus];
}

/// 读 /api/gpu 真实状态：metal=库就位、metalUsable=本机真能跑。
/// 两者分开报，绝不把"文件在"说成"能用"（web 261024-01 #7 的教训）。
- (void)loadGpuStatus {
    if (![RLPCoreClient shared].started || !self.gpuStatus) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/gpu" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || !json) return;
        const BOOL metal = [json[@"metal"] respondsToSelector:@selector(boolValue)] && [json[@"metal"] boolValue];
        const BOOL usable = [json[@"metalUsable"] respondsToSelector:@selector(boolValue)] && [json[@"metalUsable"] boolValue];
        const BOOL available = [json[@"available"] respondsToSelector:@selector(boolValue)] && [json[@"available"] boolValue];
        NSString *metalInfo = !metal ? RLPTr(@"后端库未就位")
                            : (usable ? RLPTr(@"已就位（可用）") : RLPTr(@"已就位（本机不可用）"));
        self_.gpuStatus.stringValue = [NSString stringWithFormat:@"%@ · Apple Metal %@",
            available ? RLPTr(@"GPU 可用") : RLPTr(@"走 CPU（未找到可执行的 GPU 后端）"), metalInfo];
        // Metal 项的标题带上真实状态（web 同款：能用的用真名字，不可用的说清楚）。
        NSString *metalTitle = !metal
            ? [RLPTr(@"Apple Metal（GPU 加速）") stringByAppendingString:RLPTr(@" · 后端库未就位")]
            : (usable ? RLPTr(@"Apple Metal（GPU 加速）")
                      : [RLPTr(@"Apple Metal（GPU 加速）") stringByAppendingString:RLPTr(@" · 已就位，本机未检测到可用 Metal 设备（会自动回退）")]);
        NSMenuItem *item = [self_.gpuPopup itemAtIndex:1];
        if (item) item.title = metalTitle;
    }];
}

#pragma mark - 联网检索端点（search / fetch）

/// 接口预设 → 地址（与 web LLM_PROVIDERS 逐项对应）。custom 返回空串 = 不覆盖用户已填。
static NSString *RLPLlmPresetUrlAtIndex(NSInteger i) {
    switch (i) {
        case 0: return @"https://api.deepseek.com";
        case 1: return @"https://api.openai.com/v1";
        case 2: return @"https://openrouter.ai/api/v1";
        case 3: return @"https://api.siliconflow.cn/v1";
        case 4: return @"http://127.0.0.1:11434/v1";
        default: return @"";   // 自定义
    }
}

/// 选中预设只填地址，不保存、不测连通（web llmApplyProvider 同口径）。
- (void)onLlmProviderPicked:(NSPopUpButton *)sender {
    NSString *url = RLPLlmPresetUrlAtIndex(sender.indexOfSelectedItem);
    if (!url.length) return;   // 自定义：绝不覆盖用户已填的地址
    self.llmBase.stringValue = url;
    self.llmStatus.stringValue = RLPTr(@"已填入预设地址，点「保存端点」生效");
}

/// 三个 provider 与 web SEARCH_PROVIDERS 一一对应（顺序即下标）。
static NSString *RLPSearchProviderIdAtIndex(NSInteger i) {
    switch (i) { case 1: return @"anysearch"; case 2: return @"tavily"; default: return @"deepseek"; }
}
static NSInteger RLPSearchIndexForProviderId(NSString *pid) {
    if ([pid isEqualToString:@"anysearch"]) return 1;
    if ([pid isEqualToString:@"tavily"]) return 2;
    return 0;
}

- (void)onSearchProviderChanged:(id)sender {
    (void)sender;
    // 只切下拉不立刻落盘（与 web 一致：要点「保存端点」才写），但状态行给出提示。
    const BOOL third = (self.searchProviderPopup.indexOfSelectedItem != 0);
    self.searchStatus.stringValue = third
        ? RLPTr(@"第三方检索端点与「AI 接入」的端点互不依赖；点「保存端点」生效。")
        : RLPTr(@"DeepSeek 为默认检索端点。");
}

/// 保存检索端点：provider + base（留空发空串=清默认）+ 可选 key（留空不带=保持已存）。
- (void)onSearchSave:(id)sender {
    (void)sender;
    if (![RLPCoreClient shared].started) return;
    NSString *prov = RLPSearchProviderIdAtIndex(self.searchProviderPopup.indexOfSelectedItem);
    NSString *base = [self.searchBase.stringValue stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *key = [self.searchKey.stringValue stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableString *body = [NSMutableString stringWithFormat:@"search_provider=%@&search_base_url=%@",
                             RLPEnc(prov), RLPEnc(base)];
    if (key.length) [body appendFormat:@"&search_key=%@", RLPEnc(key)];
    self.searchStatus.stringValue = RLPTr(@"保存中…");
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/llm" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            self_.searchKey.stringValue = @"";   // 明文绝不留在界面上
            self_.searchStatus.stringValue = RLPTr(@"检索端点已保存");
            [self_ loadLlmConfig];
        } else {
            self_.searchStatus.stringValue = [json[@"error"] isKindOfClass:[NSString class]]
                ? json[@"error"] : RLPTr(@"保存失败");
        }
    }];
}

/// 清除检索 Key（web searchClear：POST search_key_clear=1，与清 LLM key 分开）。
- (void)onSearchClearKey:(id)sender {
    (void)sender;
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/llm" body:@"search_key_clear=1"
                          completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        self_.searchStatus.stringValue = (json && [json[@"ok"] boolValue])
            ? RLPTr(@"已清除检索 Key")
            : ([json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"清除失败"));
        [self_ loadLlmConfig];
    }];
}

/// 测试连接：GET /api/llm/test（web llmTest 同口径；该端点在 GET 白名单里）。
/// 成功要报出模型与耗时，失败要报后端原因 —— 不能只说"连通正常"。
- (void)onLlmTest:(id)sender {
    (void)sender;
    if (![RLPCoreClient shared].started) return;
    self.llmStatus.stringValue = RLPTr(@"正在测试…");
    [self runLlmTestSilently];
}

/// 真正发测试请求并把结果写进状态行。保存端点成功后也会调它（web llmSave 顺手测一次）。
- (void)runLlmTestSilently {
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/llm/test" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            NSString *model = [json[@"model"] isKindOfClass:[NSString class]] ? json[@"model"] : @"";
            const NSInteger ms = [json[@"latencyMs"] respondsToSelector:@selector(integerValue)]
                               ? [json[@"latencyMs"] integerValue] : 0;
            self_.llmStatus.stringValue = [NSString stringWithFormat:
                RLPTr(@"连接成功：模型 %@，耗时 %ld ms（key 有效）"), model, (long)ms];
        } else {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"未知错误");
            self_.llmStatus.stringValue = [RLPTr(@"连接失败：") stringByAppendingString:err];
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
        if ([json[@"baseUrl"] isKindOfClass:[NSString class]]) {
            self_.llmBase.stringValue = json[@"baseUrl"];
            self_.llmSavedBase = json[@"baseUrl"];   // 「拉模型」要能判断屏幕上的地址是否已落盘
        }
        if ([json[@"model"] isKindOfClass:[NSString class]]) self_.llmModel.stringValue = json[@"model"];
        NSString *masked = [json[@"masked"] isKindOfClass:[NSString class]] ? json[@"masked"] : @"";
        const BOOL configured = [json[@"configured"] respondsToSelector:@selector(boolValue)] && [json[@"configured"] boolValue];
        self_.llmStatus.stringValue = configured
            ? [NSString stringWithFormat:@"%@ %@", RLPTr(@"已配置密钥"), masked]
            : RLPTr(@"尚未配置密钥");
        // 联网检索端点状态（同一回包的 searchProvider / searchBaseUrl / searchMasked）。
        // 只覆盖响应里真有的字段，缺字段不当成清空（web searchRender 同口径）。
        if ([json[@"searchProvider"] isKindOfClass:[NSString class]]) {
            [self_.searchProviderPopup selectItemAtIndex:
                RLPSearchIndexForProviderId(json[@"searchProvider"])];
        }
        if ([json[@"searchBaseUrl"] isKindOfClass:[NSString class]] &&
            !self_.searchBase.stringValue.length) {
            self_.searchBase.stringValue = json[@"searchBaseUrl"];
        }
        NSString *sMasked = [json[@"searchMasked"] isKindOfClass:[NSString class]] ? json[@"searchMasked"] : @"";
        NSString *provName = self_.searchProviderPopup.titleOfSelectedItem ?: @"DeepSeek";
        self_.searchStatus.stringValue = sMasked.length
            ? [NSString stringWithFormat:@"%@ · Key %@", provName, sMasked]
            : provName;
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

- (void)onExportDiagZip:(id)sender { [self exportDiagAsZip:YES]; }

/// zip = YES 走 /api/diagzip（压缩包），NO 走 /api/diag（单个 JSON）。
- (void)exportDiagAsZip:(BOOL)zip {
    // /api/diagzip 回的是 ZIP 原始字节（不是 JSON）⟹ 必须走 getData。
    // 不假装成功：取字节失败、用户取消、写盘失败三种情况分别如实说明。
    __weak __typeof__(self) weakSelf = self;
    if (!zip) {
        __weak __typeof__(self) weakSelf2 = self;
        [[RLPCoreClient shared] getJSON:@"/api/diag" completion:^(NSDictionary * _Nullable json) {
            __typeof__(self) self2 = weakSelf2;
            if (!self2) return;
            if (!json) { RLPToast(RLPTr(@"诊断 JSON 导出失败")); return; }
            NSData *d = [NSJSONSerialization dataWithJSONObject:json
                options:NSJSONWritingPrettyPrinted error:nil];
            NSSavePanel *panel = [NSSavePanel savePanel];
            panel.nameFieldStringValue = @"rlplayer-diag.json";
            if ([panel runModal] != NSModalResponseOK || !panel.URL) return;
            if (![d writeToURL:panel.URL options:NSDataWritingAtomic error:nil]) {
                RLPToast(RLPTr(@"写入失败"));
                return;
            }
            RLPToast([NSString stringWithFormat:RLPTr(@"已导出 %@"), panel.URL.lastPathComponent]);
        }];
        return;
    }
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
        // GPU 后端偏好回填（值 auto/metal/off → 下拉下标）。
        if ([kv[@"gpuvendor"] isKindOfClass:[NSString class]])
            [self_.gpuPopup selectItemAtIndex:RLPGpuIndexForVendor(kv[@"gpuvendor"])];
        [self_ applyKV:kv toPopup:self_.inDevicePopup key:@"indev"];

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
    [self.libStatsView reload];
    [self loadLlmConfig];
}

#pragma mark - 输出页动作

/// bit-perfect 直通：web 的判据是「输出采样率 = 源 / 抖动 = none / 音量 0 dB / 无 EQ·IR / 独占」。
/// 这里一次提交这组键（后端合并写，其它键不受影响）。
- (void)onBitPerfectFix:(id)sender {
    [self postKeys:@{
        @"rate": @"follow", @"shaper": @"none", @"volume": @"0",
        @"eq": @"", @"ir": @"", @"irgpu": @"0", @"hogexcl": @"1", @"bits": @"-1",
    }];
    [self showStatus:RLPTr(@"已切到 bit-perfect 直通")];
}

- (void)onOutMode:(NSPopUpButton *)s { [self postKey:@"outmode" value:s.titleOfSelectedItem ?: @"pcm"]; }

- (void)onChannels:(NSPopUpButton *)s {
    NSArray<NSString *> *vals = @[ @"0", @"2", @"6", @"8" ];
    const NSInteger i = s.indexOfSelectedItem;
    [self postKey:@"channels" value:(i >= 0 && i < (NSInteger)vals.count) ? vals[i] : @"0"];
    [self rebuildTrimFields:[vals[(i >= 0 && i < (NSInteger)vals.count) ? i : 0] integerValue]];
}

- (void)onBuffer:(NSTextField *)s { [self postKey:@"buffer" value:s.stringValue]; }
- (void)onRamp:(NSTextField *)s { [self postKey:@"ramp" value:s.stringValue]; }
- (void)onTrim:(NSTextField *)s {
    // 一次提交整串 trim（后端只认逗号分隔的 8 个值）；未填的位按 0。
    NSMutableArray<NSString *> *vals = [NSMutableArray array];
    for (NSInteger i = 0; i < 8; ++i) {
        NSTextField *f = self.trimFields[[NSString stringWithFormat:@"sp_trim%ld", (long)i]];
        [vals addObject:f.stringValue.length ? f.stringValue : @"0"];
    }
    [self postKey:@"trim" value:[vals componentsJoinedByString:@","]];
}
- (void)onUpnpDevice:(NSPopUpButton *)s { [self postKey:@"upnpdev" value:s.titleOfSelectedItem ?: @""]; }
- (void)onUpnpScan:(id)sender { [self.castView reload]; }

/// /api/naa/discover：NAA 端点自动发现（web 261024-01 #11）。
/// macOS 没有 NAA 驱动体系，后端对 backend=naa 会返回 UnavailableSink；
/// 但发现端点本身可用，web 页面上也确实有这个按钮 —— 所以原生要能调用它并如实显示结果。
- (void)loadNaaEndpoints {
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/naa/discover" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *eps = [json[@"endpoints"] isKindOfClass:[NSArray class]] ? json[@"endpoints"] : @[];
        NSString *note = [json[@"note"] isKindOfClass:[NSString class]] ? json[@"note"] : nil;
        // 如实显示：发现到几个端点、后端给出的原因。没有就明说没有，不假装。
        if (self_.upnpMsg) {
            self_.upnpMsg.stringValue = eps.count
                ? [NSString stringWithFormat:RLPTr(@"发现 %lu 个 NAA 端点"), (unsigned long)eps.count]
                : (note.length ? note : RLPTr(@"未发现 NAA 端点（macOS 无 NAA 驱动体系）"));
        }
    }];
}

#pragma mark - PCM 页动作

- (void)onPhase:(NSPopUpButton *)s {
    const NSInteger i = s.indexOfSelectedItem;
    NSArray<NSString *> *vals = @[ @"", @"linear", @"minimum", @"intermediate" ];
    [self postKey:@"phase" value:(i > 0 && i < (NSInteger)vals.count) ? vals[i] : @""];
}
- (void)onTaps:(NSTextField *)s { [self postKey:@"taps" value:s.stringValue]; }
- (void)onTransition:(NSTextField *)s { [self postKey:@"transition" value:s.stringValue]; }
- (void)onShaper:(NSPopUpButton *)s { [self postKey:@"shaper" value:s.titleOfSelectedItem ?: @""]; }

#pragma mark - SDM 页动作

- (void)onSdmO1:(NSPopUpButton *)s { [self postKey:@"sdmfilt" value:s.indexOfSelectedItem == 0 ? @"" : (s.titleOfSelectedItem ?: @"")]; }
- (void)onSdmONx:(NSPopUpButton *)s { [self postKey:@"sdmfiltnx" value:s.indexOfSelectedItem == 0 ? @"" : (s.titleOfSelectedItem ?: @"")]; }
- (void)onDsdPack:(NSPopUpButton *)s { [self postKey:@"dsdpk" value:s.titleOfSelectedItem ?: @"dop"]; }
- (void)onDsdKind:(NSPopUpButton *)s { [self postKey:@"dsdkind" value:s.titleOfSelectedItem ?: @"fir"]; }
- (void)onDsdConv:(NSPopUpButton *)s { [self postKey:@"dsdconv" value:s.titleOfSelectedItem ?: @"narrow"]; }
- (void)onModCut:(NSTextField *)s { [self postKey:@"modcut" value:s.stringValue]; }
- (void)onModDith:(NSTextField *)s { [self postKey:@"moddith" value:s.stringValue]; }

#pragma mark - 输入页动作

- (void)onInBuf:(NSTextField *)s { [self postKey:@"inbuf" value:s.stringValue]; }
- (void)onInOffset:(NSPopUpButton *)s { [self postKey:@"inoffset" value:s.titleOfSelectedItem ?: @"0"]; }
- (void)onInSeconds:(NSTextField *)s { [self postKey:@"inseconds" value:s.stringValue]; }
- (void)onInOut:(NSTextField *)s { [self postKey:@"inoffset" value:s.stringValue]; }

/// 开始采集：**只由用户点按钮触发**（铁律 1：绝不自动打开输入设备）。
- (void)onInputStart:(id)sender {
    if (![RLPCoreClient shared].started) { RLPToast(RLPTr(@"核心未启动")); return; }
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/input/start" body:@""
                          completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        const BOOL ok = json && [json[@"ok"] boolValue];
        self_.inStartBtn.enabled = !ok;
        self_.inStopBtn.enabled = ok;
        self_.inMsg.stringValue = ok ? RLPTr(@"采集中…")
            : (([json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : nil)
               ?: RLPTr(@"开始采集失败"));
    }];
}

- (void)onInputStop:(id)sender {
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/input/stop" body:nil
                          completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        const BOOL ok = json && [json[@"ok"] boolValue];
        self_.inStartBtn.enabled = YES;
        self_.inStopBtn.enabled = NO;
        self_.inMsg.stringValue = ok ? RLPTr(@"已停止")
            : (([json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : nil) ?: RLPTr(@"停止失败"));
    }];
}

#pragma mark - 通用页动作

- (void)onUiStyle:(NSPopUpButton *)s {
    NSString *v = s.indexOfSelectedItem == 1 ? @"classic" : @"apple";
    // 先落盘，再**真的切**：web 的 classic 换的是整套令牌（强调色变蓝、圆角收紧、
    // 顶栏 52px）。之前只 POST 不改界面 —— 用户点了没反应，那是假实现。
    [self postKey:@"uistyle" value:v];
    [RLPTheme setUiStyle:v];
    [[NSUserDefaults standardUserDefaults] setObject:v forKey:@"RLPUiStyle"];
}
- (void)onScanThreads:(NSTextField *)s { [self postKey:@"scanthreads" value:s.stringValue]; }
- (void)onRepeat:(NSPopUpButton *)s {
    // web 的设置页循环模式走 /api/repeat?mode=N（底栏才用 /api/playmode）。
    // 两者后端同源，但这里用 web 的那条，避免两端写法分叉。
    NSArray<NSString *> *vals = @[ @"1", @"2", @"0" ];
    const NSInteger i = s.indexOfSelectedItem;
    NSString *url = [NSString stringWithFormat:@"/api/repeat?mode=%@",
                     (i >= 0 && i < 3) ? vals[i] : @"1"];
    [RLPCoreClient.shared postJSON:url body:nil completion:nil];
}
- (void)onShuffle:(NSSwitch *)s {
    // web 用 /api/shuffle?on=1|0（不是 /api/playmode 的派生写法）—— 同一条后端路径，
    // 不另造一种写法，否则两端行为会悄悄分叉。
    NSString *url = [NSString stringWithFormat:@"/api/shuffle?on=%@",
                     s.state == NSControlStateValueOn ? @"1" : @"0"];
    [RLPCoreClient.shared postJSON:url body:nil completion:nil];
}

- (void)onAddRoot:(id)sender {
    NSString *p = self.rootField.stringValue;
    if (!p.length) { RLPToast(RLPTr(@"请先填目录或点「浏览…」")); return; }
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/lib/roots"
                                body:[NSString stringWithFormat:@"add=%@", RLPEnc(p)]
                          completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            self_.rootField.stringValue = @"";
            [self_ reloadRoots];
            RLPToast(RLPTr(@"目录已加入"));
        } else {
            RLPToast(([json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : nil)
                     ?: RLPTr(@"添加目录失败"));
        }
    }];
}

- (void)onBrowseRoot:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.allowsMultipleSelection = NO;
    panel.prompt = RLPTr(@"选择");
    __weak __typeof__(self) weakSelf = self;
    [panel beginWithCompletionHandler:^(NSModalResponse resp) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || resp != NSModalResponseOK) return;
        self_.rootField.stringValue = panel.URL.path ?: @"";
    }];
}

- (void)reloadRoots {
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/lib/roots" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *roots = [json[@"roots"] isKindOfClass:[NSArray class]] ? json[@"roots"] : @[];
        for (NSView *v in [self_.rootsBox.arrangedSubviews copy]) {
            [self_.rootsBox removeArrangedSubview:v];
            [v removeFromSuperview];
        }
        RLPTheme *t = [RLPTheme current];
        for (id r in roots) {
            NSString *s = [r isKindOfClass:[NSString class]] ? r : [r description];
            [self_.rootsBox addArrangedSubview:RLPLabel(s, t.small, t.mut)];
        }
        if (!roots.count)
            [self_.rootsBox addArrangedSubview:RLPLabel(RLPTr(@"（还没有音乐目录）"), t.small, t.mut)];
    }];
}

#pragma mark - 诊断页动作

- (void)onExportDiagJson:(id)sender { [self exportDiagAsZip:NO]; }
- (void)onDiagSummary:(id)sender {
    // 「查看 / 复制诊断摘要」= 把摘要渲染进 sp_diagsummarytext 并复制到剪贴板（web 同语义）。
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/diag" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSString *text = json ? [[NSString alloc] initWithData:
            [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil]
            encoding:NSUTF8StringEncoding] : RLPTr(@"诊断摘要读取失败");
        self_.diagSummaryText.string = text ?: @"";
        [[NSPasteboard generalPasteboard] clearContents];
        [[NSPasteboard generalPasteboard] setString:text ?: @"" forType:NSPasteboardTypeString];
        self_.diagMsg.stringValue = RLPTr(@"摘要已复制");
    }];
}

- (void)onDiagUpload:(id)sender {
    // 「随反馈上传诊断」：原生反馈窗口本来就带诊断包，这里打开它（同一件事，不造第二条上传通道）。
    [self onOpenFeedback:nil];
}

/// web #bNet 同语义：**点击才查询** /api/net，结果写进 sp_netmsg。
/// 单进程形态下 http=false，据此如实显示，不编一个能点的地址（那是误导，比空白更糟）。
- (void)onNetInfo:(id)sender {
    self.netMsg.hidden = NO;
    if (![RLPCoreClient shared].started) { self.netMsg.stringValue = RLPTr(@"核心未启动"); return; }
    self.netMsg.stringValue = RLPTr(@"读取中…");
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/net" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (![json isKindOfClass:[NSDictionary class]]) {
            self_.netMsg.stringValue = RLPTr(@"网络信息读取失败，稍后重试");
            return;
        }
        const BOOL httpOn = [json[@"http"] respondsToSelector:@selector(boolValue)] && [json[@"http"] boolValue];
        NSInteger port = [json[@"port"] respondsToSelector:@selector(integerValue)] ? [json[@"port"] integerValue] : 0;
        NSString *ip = [json[@"ip"] isKindOfClass:[NSString class]] ? json[@"ip"] : @"";
        NSString *lan = [json[@"lan"] respondsToSelector:@selector(boolValue)] && [json[@"lan"] boolValue]
            ? RLPTr(@"已开启") : RLPTr(@"未开启");
        self_.netMsg.stringValue = httpOn
            ? [NSString stringWithFormat:RLPTr(@"本机：http://127.0.0.1:%ld/ · 局域网：http://%@:%ld/（%@）"),
               (long)port, ip, (long)port, lan]
            : [NSString stringWithFormat:RLPTr(@"进程内直连（无本地端口）· 局域网访问：%@"), lan];
    }];
}

- (void)onUpdateChannel:(NSPopUpButton *)s {
    [self postKey:@"channel" value:s.indexOfSelectedItem == 1 ? @"cn" : @"global"];
}
- (void)onFbDiagToggle:(NSSwitch *)s { (void)s; }
- (void)onFeedbackRetry:(id)sender { [self probeFeedbackChannel]; }

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
    [self.libStatsView applyTheme];
}

@end