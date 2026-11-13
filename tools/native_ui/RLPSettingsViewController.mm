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
#import "RLPServersView.h"
#import "RLPMetaSourcesView.h"
#import "RLPLibStatsView.h"
#import "RLPSettingsLayout.h"
#include "version.h"
#include "net/feedback_api.h"
#include "net/http_client.h"
#include "net/install_id.h"

#include <chrono>

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
@interface RLPSettingsViewController () <NSTextViewDelegate>
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
/// 「目标渲染器」整行字段容器：后端不是 upnp 时连标签一起隐藏（web #sp_upnpwrap 的 display:none）。
@property (nonatomic, strong) NSView *upnpField;
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
/// 「声道音量微调」卡片：滑杆必须长在这张卡片的卡体里（按输出声道数重建）。
@property (nonatomic, strong) RLPSettingsGroup *trimGroup;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSSlider *> *trimFields;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSTextField *> *trimValueLabels;
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
/// 旧 RLPInputView 的「空跑（不开设备）」采集模式：按铁律①不能随重复控件一起删掉，
/// 用同卡的开关保留（不落盘，只影响下一次 /api/input/start 的 mode）。
@property (nonatomic, strong) NSSwitch *inNullSwitch;
@property (nonatomic, strong) NSTextField *inSecondsField;
@property (nonatomic, strong) NSTextField *inOutField;
@property (nonatomic, strong) NSButton *inStartBtn;
@property (nonatomic, strong) NSButton *inStopBtn;
@property (nonatomic, strong) NSButton *inRefreshBtn;
@property (nonatomic, strong) NSTextField *inMsg;
/// /api/input/devices 的真实设备（含 id/loopback）。开始采集时 dev 必须传 id，不能传显示名。
@property (nonatomic, copy) NSArray<NSDictionary *> *inDevices;
/// /api/settings 读回的去落盘设备 id（设备列表异步到达后再回显，避免按显示名错配）。
@property (nonatomic, copy) NSString *savedInDev;

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
@property (nonatomic, strong) RLPSettingsGroup *gpuGroup;
@property (nonatomic, strong) RLPSettingsGroup *libGroup;
@property (nonatomic, strong) RLPSettingsGroup *netGroup;

// ---- 诊断页（web data-g=diag）----
@property (nonatomic, strong) NSButton *diagZipBtn;
@property (nonatomic, strong) NSButton *diagJsonBtn;
@property (nonatomic, strong) NSButton *diagSummaryBtn;
@property (nonatomic, strong) NSTextField *diagMsg;
// 2026-11-13（第九/十/十一项）：诊断与反馈**不再用 NSPopover 承载**。
// 旧实现把真实控件搬进气泡，而 RLPCardController 只钉宽、没给 preferredContentSize，
// 搬进去的 620pt 宽 NSScrollView 又没有宽度约束 ⟹ 气泡塌成空框（用户截图：空白气泡）。
// 现在全部内联在设置页上、默认可见。fbBox 保留为 nil 只为不破坏既有引用点；
// 任何「又把它做回气泡」的改动都会被 audit 的 NSPopover 判据打红。
@property (nonatomic, strong) NSStackView *fbBox;
// 诊断摘要不再有 JSON 面板（用户 2026-11-13 明确要求：只复制 + 就地提示）。
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

// ---- 反馈通道（2026-11-14：按 web 版 fbWatchdog/fbSend 真实语义就地实现）----
/// 探活结果：-1 = 还没探完，0 = 不可用，1 = 可用（只有 1 才允许提交，与 web 同一条闸门）。
@property (nonatomic, assign) NSInteger fbServerOK;
@property (nonatomic, assign) BOOL fbChannelChecking;
@property (nonatomic, assign) BOOL fbSending;
@property (nonatomic, strong) NSTimer *fbProbeDeadline;
@property (nonatomic, strong) NSDate *fbLastChannelCheck;

// 测试接缝：网络层可注入。生产路径仍是 rta::net::http_get / http_post
// （端点/请求体来自 src/net/feedback_api.h 的代码常量，测试断言的就是它）。
@property (nonatomic, copy) void (^fbProbeTransport)(void (^done)(NSInteger status, NSData * _Nullable body, BOOL timedOut));
@property (nonatomic, copy) void (^fbUploadTransport)(NSString *url, NSString *body, void (^reply)(NSInteger status, NSData * _Nullable body));
/// 诊断摘要数据的测试接缝（生产路径仍走 /api/diag）。
@property (nonatomic, copy) void (^diagSummaryTransport)(void (^done)(NSDictionary * _Nullable json));
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
@property (nonatomic, strong) RLPSettingsGroup *outputGroup;
@property (nonatomic, strong) RLPSettingsGroup *updGroup;
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
    // 诊断页每次进入补一次通道探活（web bindFeedbackCard 同语义；30s 内不重复，见 probeFeedbackChannel）。
    if (tab == RLPSTabDiag) [self probeFeedbackChannel];
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
            @"sp_diagsummary": @"sp_diagsummary",
            @"sp_diagmsg": @"sp_diagmsg",
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
#pragma mark - 反馈通道（web fbWatchdog / fbSend 的真实语义）

/// 通道状态行（web fbChannel）：通道可用性与「这封反馈发没发出去」分开显示。
- (void)fbChannelText:(NSString *)text kind:(NSInteger)kind {
    if (!self.fbChan) return;
    self.fbChan.stringValue = text ?: @"";
    RLPTheme *t = [RLPTheme current];
    self.fbChan.textColor = (kind == 2) ? t.danger : (kind == 1) ? t.okText : t.mut2;
}

/// 发送结果行（web fbMsg）。
- (void)fbResultText:(NSString *)text kind:(NSInteger)kind {
    if (!self.fbMsg) return;
    self.fbMsg.stringValue = text ?: @"";
    RLPTheme *t = [RLPTheme current];
    self.fbMsg.textColor = (kind == 2) ? t.danger : (kind == 1) ? t.okText : t.mut2;
}

/// 提交按钮的唯一开关（web fbBusy）：忙 / 通道未确认可用（!= 1）时一律禁用。
- (void)fbUpdateSendEnabled {
    if (!self.fbSendBtn) return;
    self.fbSendBtn.enabled = !self.fbSending && self.fbServerOK == 1;
    self.fbSendBtn.title = self.fbSending ? RLPTr(@"正在发送…") : RLPTr(@"发送反馈");
    if (self.fbRetryBtn) self.fbRetryBtn.hidden = !(self.fbServerOK == 0 && !self.fbChannelChecking);
}

/// 探活（web fbWatchdog）：GET watchdog 200+ok 才允许提交；12s 内没有结论按不可用处理。
/// 绝不「一直显示正在检查」：网络层 10s 超时 + 本层 12s 兜底，两条路都会写出结论。
- (void)probeFeedbackChannel {
    // 30 秒内重复进入不重探（web bindFeedbackCard 同口径）。
    if (self.fbLastChannelCheck &&
        [[NSDate date] timeIntervalSinceDate:self.fbLastChannelCheck] < 30.0 && self.fbServerOK >= 0) {
        [self fbUpdateSendEnabled];
        return;
    }
    if (self.fbChannelChecking) return;
    self.fbChannelChecking = YES;
    self.fbServerOK = -1;
    [self fbChannelText:RLPTr(@"正在检查反馈通道…") kind:0];
    [self fbUpdateSendEnabled];

    __weak __typeof__(self) weakSelf = self;
    __block BOOL settled = NO;
    void (^done)(NSInteger, NSData *, BOOL) = ^(NSInteger status, NSData *body, BOOL timedOut) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __typeof__(self) self_ = weakSelf;
            if (!self_ || settled) return;
            settled = YES;
            if (self_.fbProbeDeadline) { [self_.fbProbeDeadline invalidate]; self_.fbProbeDeadline = nil; }
            self_.fbChannelChecking = NO;
            self_.fbLastChannelCheck = [NSDate date];
            std::string raw;
            if (body.length) raw.assign((const char *)body.bytes, (size_t)body.length);
            const auto wd = rta::feedback::parse_feedback_watchdog((int)status, raw);
            if (wd.reachable) {
                self_.fbServerOK = 1;
                NSString *line = RLPTr(@"反馈通道已连接");
                if (wd.rate_per_minute > 0) {
                    line = [NSString stringWithFormat:@"%@%@%ld%@", line, RLPTr(@"（每分钟最多 "),
                            (long)wd.rate_per_minute, RLPTr(@" 次）")];
                }
                [self_ fbChannelText:line kind:1];
            } else {
                self_.fbServerOK = 0;
                NSString *msg = [NSString stringWithUTF8String:wd.error.c_str()] ?: @"";
                if (timedOut) msg = RLPTr(@"反馈通道无响应，请稍后重试");
                if ([msg stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length == 0)
                    msg = RLPTr(@"反馈后台不可达");
                NSString *line = timedOut ? msg
                    : [RLPTr(@"反馈后台暂不可用：") stringByAppendingString:msg];
                [self_ fbChannelText:line kind:2];
            }
            [self_ fbUpdateSendEnabled];
        });
    };

    if (self.fbProbeTransport) {
        self.fbProbeTransport(done);
    } else {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            const auto r = rta::net::http_get(rta::feedback::kFeedbackWatchdogUrl, {},
                                             rta::feedback::kFeedbackWatchdogTimeoutMs);
            NSData *d = r.body.empty() ? nil
                                       : [NSData dataWithBytes:r.body.data() length:r.body.size()];
            done((NSInteger)r.status, d, r.timedOut);
        });
        // 12s 兜底（web fbWatchdog 的 12000ms）：网络层卡住也必须给用户结论。
        self.fbProbeDeadline = [NSTimer scheduledTimerWithTimeInterval:12.0 repeats:NO
                                                               block:^(NSTimer *tm) {
            __typeof__(self) self_ = weakSelf;
            if (!self_ || settled) return;
            settled = YES;
            self_.fbChannelChecking = NO;
            self_.fbServerOK = 0;
            self_.fbLastChannelCheck = [NSDate date];
            [self_ fbChannelText:RLPTr(@"反馈通道无响应，请稍后重试") kind:2];
            [self_ fbUpdateSendEnabled];
        }];
    }
}



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
    RLPSettingsGroup *outGroup = (RLPSettingsGroup *)RLPSGroup(RLPTr(@"输出后端"),
        RLPTr(@"独占 = bit-perfect；共享 = 兼容性最好（虚拟机 / 远程桌面）"), t);
    [stack addArrangedSubview:outGroup];
    self.outputGroup = outGroup;

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
    // web 是 sfld wide（下拉可缩、按钮 nowrap），普通列会把「切到 bit-perfect 直通」挤成「…」。
    [gCurrentGroup addWideField:RLPTr(@"后端") control:backendRow hint:nil];

    // ---- 目标渲染器（UPnP / DLNA）：web #sp_upnpwrap 是「输出后端」卡片体内的整行字段 ----
    // 旧原生把这一组直接 add 到页面 stack ⟹ 卡片只画了标题，控件跑到卡片外（用户截图二）。
    self.upnpWrap = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.upnpWrap.identifier = @"sp_upnpwrap";
    NSStackView *wrap = (NSStackView *)self.upnpWrap;
    wrap.orientation = NSUserInterfaceLayoutOrientationVertical;
    wrap.alignment = NSLayoutAttributeLeading;
    wrap.spacing = 6;
    wrap.translatesAutoresizingMaskIntoConstraints = NO;
    NSStackView *upnpRow = [[NSStackView alloc] init];
    upnpRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    upnpRow.alignment = NSLayoutAttributeCenterY;
    upnpRow.spacing = 8;
    self.upnpPop = [self popupForKey:@"sp_upnp_dev"
        items:@[ RLPTr(@"(正在发现…)") ] action:@selector(onUpnpDevice:)];
    self.upnpScanBtn = [NSButton buttonWithTitle:RLPTr(@"重新发现") target:self
                                         action:@selector(onUpnpScan:)];
    self.upnpScanBtn.bezelStyle = NSBezelStyleRounded;
    self.upnpScanBtn.identifier = @"sp_upnp_scan";
    [upnpRow addArrangedSubview:self.upnpPop];
    [upnpRow addArrangedSubview:self.upnpScanBtn];
    self.upnpMsg = RLPLabel(RLPTr(@"播放 / 切歌自动投放到该渲染器（与下方「投放」共用会话）"),
                            [NSFont systemFontOfSize:10.5], t.mut2);
    self.upnpMsg.identifier = @"sp_upnp_msg";
    self.upnpMsg.maximumNumberOfLines = 2;
    self.upnpMsg.lineBreakMode = NSLineBreakByWordWrapping;
    self.upnpMsg.translatesAutoresizingMaskIntoConstraints = NO;
    [wrap addArrangedSubview:upnpRow];
    [wrap addArrangedSubview:self.upnpMsg];
    [upnpRow.widthAnchor constraintEqualToAnchor:wrap.widthAnchor].active = YES;
    [self.upnpMsg.widthAnchor constraintEqualToAnchor:wrap.widthAnchor].active = YES;
    // web 同态：后端不是 upnp 时整块隐藏（#sp_upnpwrap display:none）。
    // 连**字段标签**一起隐藏（只藏容器会留下孤零零的「目标渲染器」标题 —— 实测截图抓到的假绿）。
    self.upnpField = (NSStackView *)[gCurrentGroup addWideField:RLPTr(@"目标渲染器（UPnP / DLNA）")
                                                       control:self.upnpWrap hint:nil];
    self.upnpField.hidden = YES;
    self.upnpWrap.hidden = YES;

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
    [gCurrentGroup addNoteView:self.backendMsg];   // 卡片内整行说明（旧码是页面并列）

    // ---- 声道音量微调（web sp_trimwrap）：按实际声道数生成真实控件，且必须长在卡片体内 ----
    // 旧实现两个缺陷（用户截图二的红框空灰块）：
    //   ① 字段被直接 add 到页面 stack ⟹ 卡片只剩标题条；② 只在用户手动改声道数时才生成 ⟹ 首次进入永远空。
    RLPSettingsGroup *trimGroup = (RLPSettingsGroup *)RLPSGroup(RLPTr(@"声道音量微调"),
        RLPTr(@"按声道名标注，0 dB = 不动"), t);
    [stack addArrangedSubview:trimGroup];
    self.trimGroup = trimGroup;
    self.trimWrap = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.trimWrap.identifier = @"sp_trimwrap";
    self.trimWrap.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.trimWrap.alignment = NSLayoutAttributeLeading;
    self.trimWrap.spacing = 6;
    self.trimWrap.translatesAutoresizingMaskIntoConstraints = NO;
    [trimGroup addFullRow:self.trimWrap];
    self.trimFields = [NSMutableDictionary dictionary];
    self.trimValueLabels = [NSMutableDictionary dictionary];
    self.trimChMsg = RLPLabel(@"", [NSFont systemFontOfSize:10.5], t.mut2);
    self.trimChMsg.identifier = @"sp_trimchmsg";
    self.trimChMsg.maximumNumberOfLines = 2;
    self.trimChMsg.lineBreakMode = NSLineBreakByWordWrapping;
    [trimGroup addNoteView:self.trimChMsg];
    [trimGroup addNote:RLPTr(@"显示的是「输出声道数」对应的实际声道。2 = 左/右；5.1 = 左/右/中置/低音/左环绕/右环绕；7.1 再加左后/右后")];
    // web trimFields(effectiveChannels())：首次渲染就按当前声道数生成（跟随源先按立体声）。
    [self rebuildTrimFields:2];
}

/// 重建声道微调格子（web trimFields(effectiveChannels())）。
/// 后端的 trim 键是一串逗号分隔值（trim=0,0,0,…），按声道序号对应。
- (void)rebuildTrimFields:(NSInteger)channels {
    NSStackView *wrap = self.trimWrap;
    if (!wrap) return;
    for (NSView *v in [wrap.arrangedSubviews copy]) {
        [wrap removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [self.trimFields removeAllObjects];
    [self.trimValueLabels removeAllObjects];
    static NSArray<NSString *> *names1, *names2, *names4, *names6, *names8;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names1 = @[ @"单声道" ];
        names2 = @[ @"左", @"右" ];
        names4 = @[ @"左", @"右", @"左后", @"右后" ];
        names6 = @[ @"左", @"右", @"中置", @"低音", @"左环绕", @"右环绕" ];
        names8 = @[ @"左", @"右", @"中置", @"低音", @"左环绕", @"右环绕", @"左后", @"右后" ];
    });
    if (channels <= 0) channels = 2;   // 跟随源时先按立体声显示（web 同口径）
    NSArray<NSString *> *names = (channels <= 1) ? names1 : (channels == 2) ? names2
                                  : (channels == 4) ? names4 : (channels == 6) ? names6
                                  : names8;
    RLPTheme *t = [RLPTheme current];
    for (NSUInteger i = 0; i < names.count && i < 8; ++i) {
        NSString *key = [NSString stringWithFormat:@"sp_trim%lu", (unsigned long)i];
        NSTextField *lab = RLPLabel([NSString stringWithFormat:RLPTr(@"%@（声道 %lu，dB）"),
                                     names[i], (unsigned long)(i + 1)],
                                    [NSFont systemFontOfSize:11], t.mut);
        lab.translatesAutoresizingMaskIntoConstraints = NO;
        [[lab.widthAnchor constraintEqualToConstant:170] setActive:YES];
        NSSlider *s = [NSSlider sliderWithValue:0 minValue:-24 maxValue:12
                                        target:self action:@selector(onTrimSlider:)];
        s.identifier = key;
        s.tag = (NSInteger)i;
        s.continuous = NO;            // 松开鼠标才提交：避免拖动时向后端灌请求
        s.trackFillColor = [RLPTheme current].accent;   // web 滑杆是 accent 色，不要系统默认亮蓝
        s.translatesAutoresizingMaskIntoConstraints = NO;
        [[s.widthAnchor constraintEqualToConstant:220] setActive:YES];
        NSTextField *val = RLPLabel(@"0.0 dB", [NSFont systemFontOfSize:10.5], t.mut2);
        val.identifier = [key stringByAppendingString:@".val"];
        val.translatesAutoresizingMaskIntoConstraints = NO;
        [[val.widthAnchor constraintEqualToConstant:70] setActive:YES];
        NSStackView *row = [[NSStackView alloc] init];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.alignment = NSLayoutAttributeCenterY;
        row.spacing = 8;
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [row addArrangedSubview:lab];
        [row addArrangedSubview:s];
        [row addArrangedSubview:val];
        [wrap addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:wrap.widthAnchor].active = YES;
        [self.trimFields setObject:s forKey:key];
        [self.trimValueLabels setObject:val forKey:key];
    }
    self.trimChMsg.stringValue = [NSString stringWithFormat:RLPTr(@"按 %ld 声道显示"), (long)names.count];
    if (self.trimGroup) [self.trimGroup contentDidChange];
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
    [gCurrentGroup addNoteView:self.phaseMsg];

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
    [gCurrentGroup addNoteView:self.dsdModeNote];

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
    [gCurrentGroup addNoteView:self.dsdMsg];
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

    // 输入设备 + 「刷新」：刷新能力原来藏在旧 RLPInputView 里（另一套重复控件）。
    // 现在移进卡片本体，设备列表仍来自 /api/input/devices（带 id，开始采集时用 id 而不是显示名）。
    self.inDevicePopup = [self popupForKey:@"sp_indev"
        items:@[ RLPTr(@"（未选择 / 默认设备）") ] action:@selector(onInDevice:)];
    self.inRefreshBtn = [NSButton buttonWithTitle:RLPTr(@"刷新设备") target:self
                                           action:@selector(onInRefreshDevices:)];
    self.inRefreshBtn.bezelStyle = NSBezelStyleRounded;
    self.inRefreshBtn.identifier = @"sp_inrefresh";
    NSStackView *devRow = [[NSStackView alloc] init];
    devRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    devRow.alignment = NSLayoutAttributeCenterY;
    devRow.spacing = 8;
    [devRow addArrangedSubview:self.inDevicePopup];
    [devRow addArrangedSubview:self.inRefreshBtn];
    // 整行：下拉 240 + 「刷新设备」在普通 260pt 列里会把按钮压成「刷…」（实测截图）。
    [gCurrentGroup addWideField:RLPTr(@"输入设备") control:devRow
                            hint:RLPTr(@"包含物理采集设备与系统混音回环端点（标注「回环」的那一项）")];

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

    // 旧 RLPInputView 的第三种采集模式（mode=null，模拟源、不打开真实设备）。
    // 删除重复控件时不能把能力一起删掉（铁律①）：保留为本卡内的开关，只影响下一次开始采集。
    self.inNullSwitch = [self switchWithAction:@selector(onNullSourceToggle:) key:@"sp_innull"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"模拟源（空跑，不开设备）"), self.inNullSwitch,
        RLPTr(@"只产生模拟信号用于调试；不打开真实输入设备，也不向输出设备送声音"), t)];

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
    btnRow.alignment = NSLayoutAttributeCenterY;
    btnRow.spacing = 10;
    [btnRow addArrangedSubview:self.inStartBtn];
    [btnRow addArrangedSubview:self.inStopBtn];
    [btnRow addArrangedSubview:self.inMsg];
    [gCurrentGroup addFullRow:btnRow];      // 旧码直接 add 到页面 ⟹ 按钮跑到卡片外

    // 采集实时状态：只嵌**状态区块**（RLPInputView 的配置控件已全部由上面卡片承载，
    // 旧实现整套配置又重复出现一次 —— 用户截图一红框就是那套重复控件）。
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"采集实时状态"), RLPTr(@"1 秒自动轮询"), t)];
    self.inputView = [[RLPInputView alloc] initStatusOnlyWithFrame:NSMakeRect(0, 0, 620, 240)];
    self.inputView.translatesAutoresizingMaskIntoConstraints = NO;
    [gCurrentGroup addFullRow:self.inputView];
    [[self.inputView.heightAnchor constraintGreaterThanOrEqualToConstant:260] setActive:YES];
    [self.inputView reload];
    [self loadInputDevices];
}

/// 拉取 /api/input/devices（真实 id + loopback 标记），填「输入设备」下拉。
/// 为什么不能只列名字：开始采集的 dev 键必须是设备 id（传名字是子串匹配的兜底，
/// 有歧义时会开错设备）。
- (void)loadInputDevices {
    if (![RLPCoreClient shared].started || !self.inDevicePopup) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/input/devices" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *arr = [json[@"devices"] isKindOfClass:[NSArray class]] ? json[@"devices"] : @[];
        NSMutableArray<NSDictionary *> *good = [NSMutableArray array];
        for (id x in arr) if ([x isKindOfClass:[NSDictionary class]]) [good addObject:x];
        self_.inDevices = good;
        NSString *keep = self_.inDevicePopup.titleOfSelectedItem;
        [self_.inDevicePopup removeAllItems];
        [self_.inDevicePopup addItemWithTitle:RLPTr(@"（未选择 / 默认设备）")];
        for (NSDictionary *d in good) {
            NSString *nm = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : @"";
            if (!nm.length) continue;
            const BOOL lb = [d[@"loopback"] respondsToSelector:@selector(boolValue)] && [d[@"loopback"] boolValue];
            NSString *title = lb ? [nm stringByAppendingString:RLPTr(@"（系统混音·本机不支持）")] : nm;
            [self_.inDevicePopup addItemWithTitle:title];
            if (lb) [[self_.inDevicePopup itemAtIndex:self_.inDevicePopup.numberOfItems - 1] setEnabled:NO];
        }
        if (keep.length && [self_.inDevicePopup itemWithTitle:keep])
            [self_.inDevicePopup selectItemWithTitle:keep];
        // 回显落盘值：优先按设备 id 匹配内部 inDevices，其次按显示名。
        NSString *want = self_.savedInDev;
        if (want.length) {
            NSInteger idx = NSNotFound;
            for (NSInteger i = 0; i < (NSInteger)good.count; ++i) {
                NSDictionary *d = good[i];
                NSString *did = [d[@"id"] isKindOfClass:[NSString class]] ? d[@"id"] : @"";
                if (did.length && [did isEqualToString:want]) { idx = i; break; }
            }
            if (idx != NSNotFound) [self_.inDevicePopup selectItemAtIndex:idx + 1];
        }
    }];
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
    self.gpuGroup = (RLPSettingsGroup *)RLPSGroup(RLPTr(@"GPU"),
        RLPTr(@"自动 = 优先 Apple Metal，不可用时自动退回纯 CPU（NEON 向量）分块 FFT，输出逐位相同"), t);
    [stack addArrangedSubview:self.gpuGroup];
    self.gpuPopup = [self popupForKey:@"sp_gpu" items:@[ @"auto", @"metal", @"off" ]
                               action:@selector(onGpuVendor:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"GPU 后端"), self.gpuPopup, nil, t)];
    self.gpuStatus = [self hintForKey:@"sp_gpumsg" width:560];
    [gCurrentGroup addNoteView:self.gpuStatus];
    [self loadGpuStatus];

    // ---- 本地音乐库：统计 / 目录 / 扫描 / 线程数 ----
    self.libGroup = (RLPSettingsGroup *)RLPSGroup(RLPTr(@"本地音乐库"),
        RLPTr(@"本地目录扫描入索引；DLNA / UPnP 在「流媒体」页"), t);
    [stack addArrangedSubview:self.libGroup];

    self.libStatsView = [[RLPLibStatsView alloc] initWithFrame:NSMakeRect(0, 0, 560, 120)];
    self.libStatsView.identifier = @"sp_libstats";
    self.libStatsView.translatesAutoresizingMaskIntoConstraints = NO;
    [gCurrentGroup addFullRow:self.libStatsView];   // 统计块属于这张卡片（旧码是页面并列）
    [[self.libStatsView.heightAnchor constraintGreaterThanOrEqualToConstant:120] setActive:YES];
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
    [gCurrentGroup addButtonRow:@[ self.browseRootBtn, self.addRootBtn, self.rescanBtn ]];



    self.scanThreadsField = [self numberFieldForKey:@"sp_scanthreads" action:@selector(onScanThreads:)
                                         placeholder:@"0 = 自动"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"扫描线程数"), self.scanThreadsField,
        RLPTr(@"0 = 自动（默认 min(CPU, 8)）"), t)];

    self.rootsBox = [NSStackView stackViewWithViews:@[]];
    self.rootsBox.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.rootsBox.alignment = NSLayoutAttributeLeading;
    self.rootsBox.spacing = 2;
    self.rootsBox.identifier = @"sp_roots";
    [gCurrentGroup addFullRow:self.rootsBox];

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
    self.netGroup = (RLPSettingsGroup *)RLPSGroup(RLPTr(@"网络信息"),
        RLPTr(@"点按钮查询本机地址与局域网访问状态"), t);
    [stack addArrangedSubview:self.netGroup];
    self.netBtn = [NSButton buttonWithTitle:RLPTr(@"查询网络信息") target:self
                                     action:@selector(onNetInfo:)];
    self.netBtn.bezelStyle = NSBezelStyleRounded;
    self.netBtn.identifier = @"sp_netbtn";
    [gCurrentGroup addButtonRow:@[ self.netBtn ]];
    self.netMsg = [self hintForKey:@"sp_netmsg" width:560];
    self.netMsg.hidden = YES;   // 未点击前不占视觉，与 web #netMsg 初始空态一致
    [gCurrentGroup addNoteView:self.netMsg];
}

#pragma mark - 流媒体

/// 流媒体页 —— 1:1 对齐 web data-g=stream（ui_script.h:10058 起）。
/// 两个区块：流媒体服务器（增删改/启用/测试）+ 推送到设备（UPnP / DLNA 全套状态）。
- (void)fillStream:(NSStackView *)stack t:(RLPTheme *)t {
    // 用户截图四：服务器/投放两块的控件原本全在卡片外（卡片只画了标题条）。
    // 这里把两个子视图分别放进对应卡片体（addFullRow ⟹ 是卡片的共同后代，不再是页面并列）。
    RLPSettingsGroup *srvGroup = (RLPSettingsGroup *)RLPSGroup(RLPTr(@"流媒体服务器"),
        RLPTr(@"可保存多台，同一时刻启用一台；只取原始文件，不转码"), t);
    [stack addArrangedSubview:srvGroup];

    self.serversView = [[RLPServersView alloc] initWithFrame:NSMakeRect(0, 0, 620, 240)];
    self.serversView.translatesAutoresizingMaskIntoConstraints = NO;
    [srvGroup addFullRow:self.serversView];
    [[self.serversView.heightAnchor constraintGreaterThanOrEqualToConstant:120] setActive:YES];
    [self.serversView reload];

    // 投放面板（设备发现 / 推送 / 停止 / 升频选项 / 实时状态）与 web 同源 /api/cast/*
    RLPSettingsGroup *castGroup = (RLPSettingsGroup *)RLPSGroup(RLPTr(@"推送到设备（UPnP / DLNA）"),
        RLPTr(@"一键把当前曲目推送到局域网渲染器；之后的切歌 / 暂停 / 进度都作用在它上面"), t);
    [stack addArrangedSubview:castGroup];

    self.castView = [[RLPCastView alloc] initWithFrame:NSMakeRect(0, 0, 620, 420)];
    self.castView.translatesAutoresizingMaskIntoConstraints = NO;
    [castGroup addFullRow:self.castView];
    [[self.castView.heightAnchor constraintGreaterThanOrEqualToConstant:380] setActive:YES];
    [self.castView reload];
}

#pragma mark - 诊断

/// 诊断页 —— 1:1 对齐 web data-g=diag（ui_script.h:10127 起）。
/// 三块：诊断包导出 / 软件更新 / 反馈问题。
- (NSButton *)primaryButton:(NSString *)title
                     ident:(NSString *)ident
                    action:(SEL)action {
    // web .btn.pri：红底白字（--acc 渐变到 --acc2）。原生用实心 accent + 白字，
    // 与专辑详情页 playAllBtn / 底栏播放键同一个视觉规范，不另立一套。
    RLPTheme *t = [RLPTheme current];
    NSButton *b = [NSButton buttonWithTitle:RLPTr(title) target:self action:action];
    b.bezelStyle = NSBezelStyleRounded;
    b.bordered = NO;
    b.identifier = ident;
    b.wantsLayer = YES;
    b.layer.cornerRadius = 7;              // web .btn{border-radius:7px}
    b.layer.backgroundColor = t.accent.CGColor;
    b.contentTintColor = NSColor.whiteColor;
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = NSTextAlignmentCenter;
    b.attributedTitle = [[NSAttributedString alloc] initWithString:RLPTr(title)
        attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold],
                     NSForegroundColorAttributeName:NSColor.whiteColor,
                     NSParagraphStyleAttributeName:ps}];
    [[b.widthAnchor constraintGreaterThanOrEqualToConstant:132] setActive:YES];
    [[b.heightAnchor constraintEqualToConstant:30] setActive:YES];
    return b;
}

- (NSButton *)secondaryButton:(NSString *)title
                        ident:(NSString *)ident
                       action:(SEL)action {
    RLPTheme *t = [RLPTheme current];
    NSButton *b = [NSButton buttonWithTitle:RLPTr(title) target:self action:action];
    b.bezelStyle = NSBezelStyleRounded;
    b.identifier = ident;
    b.wantsLayer = YES;
    b.layer.cornerRadius = 7;
    b.layer.backgroundColor = t.hov.CGColor;      // web .btn{background:var(--hov)}
    b.layer.borderWidth = 1;
    b.layer.borderColor = t.line.CGColor;
    b.contentTintColor = t.text;
    return b;
}

/// 小标题（web .sfld label：11px / --mut）。
- (NSTextField *)fieldLabel:(NSString *)text {
    NSTextField *l = RLPLabel(text, [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
                              [RLPTheme current].mut);
    l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}

- (void)fillDiag:(NSStackView *)stack t:(RLPTheme *)t {
    // ---- 导出诊断包（web 形态：标题行 + 三个按钮 + 说明；按钮内联在卡片体里）----
    RLPSettingsGroup *diagGroup = (RLPSettingsGroup *)RLPSGroup(RLPTr(@"导出诊断包"), nil, t);
    diagGroup.identifier = @"sp_diaggroup";
    [stack addArrangedSubview:diagGroup];

    self.diagZipBtn = [self primaryButton:@"导出诊断包（.zip）" ident:@"sp_diagzip"
                                   action:@selector(onExportDiagZip:)];
    self.diagJsonBtn = [self secondaryButton:@"只要 JSON" ident:@"sp_diagjson"
                                      action:@selector(onExportDiagJson:)];
    self.diagSummaryBtn = [self secondaryButton:@"查看 / 复制诊断摘要" ident:@"sp_diagsummary"
                                         action:@selector(onDiagSummary:)];
    // ⛔ 「随反馈上传诊断」（web sp_diagupload）已按用户明确要求删除（parity_removed.tsv 双向核验）。
    // ⛔ 诊断摘要的 JSON 面板（web sp_diagsummarytext 的 <pre>）按用户 2026-11-13 要求删除：
    //    该按钮只做「复制摘要 + 就地提示」，不显示 JSON 面板、不弹窗、不出现第二个容器。

    NSStackView *diagRow = [[NSStackView alloc] init];
    diagRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    diagRow.alignment = NSLayoutAttributeCenterY;
    diagRow.spacing = 10;
    for (NSView *v in @[ self.diagZipBtn, self.diagJsonBtn, self.diagSummaryBtn ])
        [diagRow addArrangedSubview:v];
    self.diagMsg = [self hintForKey:@"sp_diagmsg" width:300];
    [diagRow addArrangedSubview:self.diagMsg];
    [diagGroup addFullRow:diagRow];

    // 两行说明（web 原文，逐字）：第一行主文案，第二行补「已脱敏」。
    [diagGroup addNote:RLPTr(@"一个 zip 打包全部日志 / 系统信息 / 设置摘要")];
    [diagGroup addNote:RLPTr(@"（已脱敏），不用再到处找日志文件")];

    // ---- 软件更新（整块控件都必须在卡片体内；旧码把版本/按钮/说明铺在页面层级）----
    RLPSettingsGroup *updGroup = (RLPSettingsGroup *)RLPSGroup(RLPTr(@"软件更新"),
        RLPTr(@"检查新版本，一键更新"), t);
    [stack addArrangedSubview:updGroup];
    self.updGroup = updGroup;

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
    updRow.alignment = NSLayoutAttributeCenterY;
    updRow.spacing = 10;
    [updRow addArrangedSubview:self.verCurLabel];
    [updRow addArrangedSubview:self.updCheckBtn];
    [updRow addArrangedSubview:self.updInstallBtn];
    [updRow addArrangedSubview:self.betaSwitch];
    // web 的开关文案是「接收测试版（Beta）」，旧码只画了开关没画字。
    [updRow addArrangedSubview:RLPLabel(RLPTr(@"接收测试版（Beta）"), t.small, t.mut)];
    [updRow addArrangedSubview:self.updMsg];
    [updGroup addFullRow:updRow];

    self.updBar = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.updBar.identifier = @"sp_updbar";
    self.updBar.style = NSProgressIndicatorStyleBar;
    self.updBar.indeterminate = NO;
    self.updBar.minValue = 0;
    self.updBar.maxValue = 100;
    self.updBar.hidden = YES;
    self.updBar.translatesAutoresizingMaskIntoConstraints = NO;
    [updGroup addFullRow:self.updBar];
    [[self.updBar.heightAnchor constraintEqualToConstant:8] setActive:YES];

    // web #sp_updfill 是进度条里的填充块（图形）；原生进度条不需要单独的子控件，
    // 但 parity 表按 web id 核对，这里保留一个隐藏的说明位承载同名 identifier（不占视觉）。
    self.updFill = [self hintForKey:@"sp_updfill" width:620];
    self.updFill.hidden = YES;
    [updGroup addNoteView:self.updFill];

    self.updNote = [self hintForKey:@"sp_updnote" width:620];
    self.updNote.stringValue = RLPTr(@"更新会下载安装包并校验 sha256；校验不通过一律丢弃，绝不安装被篡改的内容。安装完成后会自动重启。");
    [updGroup addNoteView:self.updNote];

    // ---- 反馈问题（web 形态：内联填写窗，默认展开，不再用气泡）----
    RLPSettingsGroup *fbGroup = (RLPSettingsGroup *)RLPSGroup(RLPTr(@"反馈问题"),
        RLPTr(@"直接发送给开发者，可附诊断包"), t);
    fbGroup.identifier = @"sp_fbgroup";
    [stack addArrangedSubview:fbGroup];

    NSTextField *fbLabel = [self fieldLabel:RLPTr(@"问题描述")];
    fbLabel.identifier = @"sp_fblabel";
    [fbGroup addFullRow:fbLabel];

    self.fbText = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 620, 150)];
    self.fbText.identifier = @"sp_fbtext";
    self.fbText.font = [NSFont systemFontOfSize:12.5];
    self.fbText.editable = YES;
    self.fbText.selectable = YES;
    self.fbText.richText = NO;
    self.fbText.allowsUndo = YES;
    // web <textarea rows=5 min-height:88px> 高度按约 8 行给（用户要求「约 8 行」）。
    self.fbText.translatesAutoresizingMaskIntoConstraints = NO;
    self.fbText.delegate = self;
    NSScrollView *fbScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 620, 150)];
    fbScroll.identifier = @"sp_fbscroll";
    fbScroll.hasVerticalScroller = YES;
    fbScroll.autohidesScrollers = YES;
    fbScroll.drawsBackground = YES;
    fbScroll.backgroundColor = t.field;
    fbScroll.wantsLayer = YES;
    fbScroll.layer.cornerRadius = 7;
    fbScroll.layer.borderWidth = 1;
    fbScroll.layer.borderColor = t.line.CGColor;
    fbScroll.documentView = self.fbText;
    fbScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [fbGroup addFullRow:fbScroll];   // 宽度由卡片网格给（web textarea width:100%）
    [[fbScroll.heightAnchor constraintEqualToConstant:150] setActive:YES];

    self.fbCount = [self hintForKey:@"sp_fbcount" width:300];
    self.fbCount.stringValue = RLPTr(@"0 / 16384 字节");
    [fbGroup addFullRow:self.fbCount];

    self.fbChan = [self hintForKey:@"sp_fbchan" width:520];
    self.fbChan.stringValue = RLPTr(@"正在检查反馈通道…");
    [fbGroup addFullRow:self.fbChan];

    // 底部操作行：☑ 附带诊断包（默认勾选，web checked）+ 红底「发送反馈」+ 重试探活
    self.fbDiagSwitch = [self switchForKey:@"sp_fbdiag" action:@selector(onFbDiagToggle:)];
    self.fbDiagSwitch.state = NSControlStateValueOn;
    self.fbSendBtn = [self primaryButton:@"发送反馈" ident:@"sp_fbsend"
                                  action:@selector(onSendFeedback:)];
    self.fbRetryBtn = [self secondaryButton:@"重试探活" ident:@"sp_fbretry"
                                     action:@selector(onFeedbackRetry:)];
    self.fbRetryBtn.hidden = YES;
    self.fbMsg = [self hintForKey:@"sp_fbmsg" width:300];

    NSStackView *fbRow = [[NSStackView alloc] init];
    fbRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    fbRow.alignment = NSLayoutAttributeCenterY;
    fbRow.spacing = 10;
    [fbRow addArrangedSubview:self.fbDiagSwitch];
    [fbRow addArrangedSubview:RLPLabel(RLPTr(@"附带诊断包"), t.small, t.mut)];
    for (NSView *v in @[ self.fbSendBtn, self.fbRetryBtn, self.fbMsg ])
        [fbRow addArrangedSubview:v];
    [fbGroup addFullRow:fbRow];

    [fbGroup addNote:RLPTr(@"提交前会先探活；通道不可用时按钮保持禁用，绝不假装发送成功。")];
    [fbGroup addNote:RLPTr(@"诊断包已脱敏，不会上传你的音乐文件。")];

    // 进页面即探活一次（web bindFeedbackCard 同语义）；之后 30 秒内不重复探。
    [self probeFeedbackChannel];
}

#pragma mark - 元数据

- (void)fillMeta:(NSStackView *)stack t:(RLPTheme *)t {
    // ── 基础选项（对齐 web：默认只显示三个开关 + 「高级选项 ▾」）──
    [stack addArrangedSubview:RLPSGroup(RLPTr(@"元数据补全"),
        RLPTr(@"播放时后台补全标签 / 封面 / 歌词，结果落在本地库"), t)];
    self.metaOnSwitch = [self switchWithAction:@selector(onSwitch:) key:@"sp_metaon"];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"自动补全（不用 AI）"), self.metaOnSwitch,
        RLPTr(@"只用公开数据源（QQ音乐 / 网易云 / iTunes / dizzylab / lrclib）补全标签、封面、歌词；全程不调用 AI，不产生费用"), t)];
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

    // 数据源卡片（web 高级区左列 .meta-card）：逐源开关 + 优先级
    RLPSettingsGroup *dataGroup = (RLPSettingsGroup *)RLPSGroup(RLPTr(@"数据源"),
        RLPTr(@"越靠上优先级越高；拖动把手或点 ▲▼ 调整顺序，关掉的源完全不参与补全"), t);
    [adv addArrangedSubview:dataGroup];
    NSLayoutConstraint *dataWidthConstraint = gLastGroupWidthConstraint;
    self.metaSourcesView = [[RLPMetaSourcesView alloc] initWithFrame:NSMakeRect(0, 0, 620, 200)];
    self.metaSourcesView.translatesAutoresizingMaskIntoConstraints = NO;
    [dataGroup addFullRow:self.metaSourcesView];
    [[self.metaSourcesView heightAnchor] constraintGreaterThanOrEqualToConstant:200].active = YES;
    [self.metaSourcesView reload];

    // AI 接入卡片（web 高级区右列 .meta-card）：密钥红线 —— GET 只回掩码，输入框留空 = 不改已存的 key
    // 用户截图三：模型下拉 / 刷新 / 「已拉到 9 个模型」/ 保存端点 / 测试连通 / 清除密钥
    // 原本全是页面并列散块 ⟹ 全部经 addField/addNoteView/addButtonRow 落进这张卡。
    RLPSettingsGroup *aiGroup = (RLPSettingsGroup *)RLPSGroup(RLPTr(@"AI 接入（OpenAI 兼容）"),
        RLPTr(@"任何兼容 OpenAI 的服务都能用。密钥只在本机保存，界面永不回显明文；留空表示不修改。"), t);
    [adv addArrangedSubview:aiGroup];
    NSLayoutConstraint *aiWidthConstraint = gLastGroupWidthConstraint;

    // ① 接口预设（对齐 web LLM_PROVIDERS / sp_llmprovider）——只负责「填地址」，不做连通性判断。
    self.llmProviderPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSString *n in @[ @"DeepSeek", @"OpenAI", @"OpenRouter",
                           RLPTr(@"SiliconFlow（硅基流动）"), RLPTr(@"Ollama（本机）"), RLPTr(@"自定义") ])
        [self.llmProviderPopup addItemWithTitle:n];
    self.llmProviderPopup.identifier = @"llm.provider";
    self.llmProviderPopup.target = self;
    self.llmProviderPopup.action = @selector(onLlmProviderPicked:);
    [self.llmProviderPopup.widthAnchor constraintEqualToConstant:240].active = YES;
    [aiGroup addField:RLPTr(@"接口预设") control:self.llmProviderPopup hint:nil];

    // ② 接口地址
    self.llmBase = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.llmBase.placeholderString = @"https://api.deepseek.com";
    self.llmBase.identifier = @"llm.base";
    [[self.llmBase.widthAnchor constraintEqualToConstant:320] setActive:YES];
    [aiGroup addField:RLPTr(@"接口地址") control:self.llmBase hint:nil];

    // ③ 密钥（web 顺序：Key 在保存/测试/清除之前）
    self.llmKey = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    self.llmKey.placeholderString = RLPTr(@"留空 = 保持已保存的密钥");
    self.llmKey.identifier = @"llm.key";
    [[self.llmKey.widthAnchor constraintEqualToConstant:320] setActive:YES];
    [aiGroup addField:RLPTr(@"API Key") control:self.llmKey hint:nil];

    self.llmStatus = RLPLabel(@"", t.small, t.mut);
    self.llmStatus.maximumNumberOfLines = 2;
    self.llmStatus.lineBreakMode = NSLineBreakByWordWrapping;
    self.llmStatus.identifier = @"llm.status";
    [aiGroup addNoteView:self.llmStatus];

    // ④ 动作按钮（web 顺序：保存并连接 / 测试连接 / 清除 Key）
    NSButton *save = [NSButton buttonWithTitle:RLPTr(@"保存端点") target:self action:@selector(onLlmSave:)];
    save.bezelStyle = NSBezelStyleRounded;
    save.identifier = @"llm.save";
    NSButton *test = [NSButton buttonWithTitle:RLPTr(@"测试连通") target:self action:@selector(onLlmTest:)];
    test.bezelStyle = NSBezelStyleRounded;
    test.identifier = @"llm.test";
    NSButton *clearKey = [NSButton buttonWithTitle:RLPTr(@"清除密钥") target:self action:@selector(onLlmClearKey:)];
    clearKey.bezelStyle = NSBezelStyleRounded;
    clearKey.identifier = @"llm.clear";
    [aiGroup addButtonRow:@[ save, test, clearKey ]];

    // ⑤ 模型：手填 + 下拉 + 刷新列表（web 同一行）
    self.llmModel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.llmModel.placeholderString = @"deepseek-chat";
    self.llmModel.identifier = @"llm.modeltext";
    self.llmModel.target = self;
    self.llmModel.action = @selector(onLlmModelTyped:);
    [[self.llmModel.widthAnchor constraintEqualToConstant:220] setActive:YES];
    self.llmModelPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.llmModelPopup.target = self;
    self.llmModelPopup.action = @selector(onLlmModelPicked:);
    self.llmModelPopup.identifier = @"llm.modelpopup";
    self.llmModelPopup.hidden = YES;
    [self.llmModelPopup.widthAnchor constraintEqualToConstant:240].active = YES;
    self.llmModelRefresh = [NSButton buttonWithTitle:RLPTr(@"刷新模型列表")
        target:self action:@selector(onLlmModelRefresh:)];
    self.llmModelRefresh.bezelStyle = NSBezelStyleRounded;
    self.llmModelRefresh.identifier = @"llm.modelrefresh";
    NSStackView *modelRow = [[NSStackView alloc] init];
    modelRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    modelRow.alignment = NSLayoutAttributeCenterY;
    modelRow.spacing = 8;
    [modelRow addArrangedSubview:self.llmModelPopup];
    [modelRow addArrangedSubview:self.llmModel];
    [modelRow addArrangedSubview:self.llmModelRefresh];
    [aiGroup addWideField:RLPTr(@"LLM 模型") control:modelRow
                     hint:RLPTr(@"选择用于资料补全与增强的模型；读不到列表也可以直接手填")];

    self.llmModelMsg = RLPLabel(RLPTr(@"模型列表读取中"), t.small, t.mut);
    self.llmModelMsg.maximumNumberOfLines = 2;
    self.llmModelMsg.lineBreakMode = NSLineBreakByWordWrapping;
    self.llmModelMsg.identifier = @"llm.modelmsg";
    [aiGroup addNoteView:self.llmModelMsg];

    // ---- 标签写回（web sp_wbdesc / sp_wbdry / sp_wbapply / sp_wbmsg）----
    // web 把这块放在「元数据 · AI 接入」**同一张卡体内**（.mh.sub 子段，ui_script.h:10264-10272）。
    [aiGroup addSubHeader:RLPTr(@"标签写回") hint:RLPTr(@"默认开启")];

    self.wbDesc = RLPLabel(@"", t.small, t.mut);
    self.wbDesc.identifier = @"sp_wbdesc";
    self.wbDesc.maximumNumberOfLines = 4;
    self.wbDesc.lineBreakMode = NSLineBreakByWordWrapping;
    self.wbDesc.stringValue = RLPTr(@"补全到的标签 / 封面写回音频文件本身；写前校验音频数据逐位不变，原文件备份到备份目录");
    [aiGroup addNoteView:self.wbDesc];

    self.wbDryBtn = [NSButton buttonWithTitle:RLPTr(@"预览写回") target:self
                                       action:@selector(onWritebackDry:)];
    self.wbDryBtn.bezelStyle = NSBezelStyleRounded;
    self.wbDryBtn.identifier = @"sp_wbdry";
    self.wbApplyBtn = [NSButton buttonWithTitle:RLPTr(@"执行写回") target:self
                                         action:@selector(onWritebackApply:)];
    self.wbApplyBtn.bezelStyle = NSBezelStyleRounded;
    self.wbApplyBtn.identifier = @"sp_wbapply";
    [aiGroup addButtonRow:@[ self.wbDryBtn, self.wbApplyBtn ]];

    self.writebackStatus = RLPLabel(@"", t.small, t.mut);
    self.writebackStatus.identifier = @"sp_wbmsg";
    self.writebackStatus.maximumNumberOfLines = 3;
    self.writebackStatus.lineBreakMode = NSLineBreakByWordWrapping;
    [aiGroup addNoteView:self.writebackStatus];

    // ── 联网检索端点（search / fetch 一起切换，对齐 web SEARCH 区块）──
    // 用户截图三：保存端点 / 清除检索 Key / AnySearch · Key as_****e834 散在卡片外 ⟹ 全部归卡。
    RLPSettingsGroup *searchGroup = (RLPSettingsGroup *)RLPSGroup(RLPTr(@"联网检索端点"),
        RLPTr(@"「AI 增强」整理资料时用的 search / fetch 端点。DeepSeek 为默认；切到 AnySearch / Tavily 后，非 DeepSeek 的 AI 接口也能联网检索。"), t);
    [adv addArrangedSubview:searchGroup];

    self.searchProviderPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.searchProviderPopup addItemWithTitle:RLPTr(@"DeepSeek（默认）")];
    [self.searchProviderPopup addItemWithTitle:@"AnySearch"];
    [self.searchProviderPopup addItemWithTitle:@"Tavily"];
    self.searchProviderPopup.identifier = @"search.provider";
    self.searchProviderPopup.target = self;
    self.searchProviderPopup.action = @selector(onSearchProviderChanged:);
    [self.searchProviderPopup.widthAnchor constraintEqualToConstant:240].active = YES;
    [searchGroup addField:RLPTr(@"检索端点") control:self.searchProviderPopup hint:nil];

    self.searchBase = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.searchBase.placeholderString = RLPTr(@"留空 = 用该厂商默认地址");
    self.searchBase.identifier = @"search.base";
    [[self.searchBase.widthAnchor constraintEqualToConstant:320] setActive:YES];
    [searchGroup addField:RLPTr(@"检索地址") control:self.searchBase hint:nil];

    self.searchKey = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    self.searchKey.placeholderString = RLPTr(@"留空 = 保持已保存的检索 Key");
    self.searchKey.identifier = @"search.key";
    [[self.searchKey.widthAnchor constraintEqualToConstant:320] setActive:YES];
    [searchGroup addField:RLPTr(@"检索 Key") control:self.searchKey hint:nil];

    self.searchStatus = RLPLabel(@"", t.small, t.mut);
    self.searchStatus.maximumNumberOfLines = 2;
    self.searchStatus.lineBreakMode = NSLineBreakByWordWrapping;
    self.searchStatus.identifier = @"search.status";
    [searchGroup addNoteView:self.searchStatus];

    NSButton *sSave = [NSButton buttonWithTitle:RLPTr(@"保存端点") target:self action:@selector(onSearchSave:)];
    sSave.bezelStyle = NSBezelStyleRounded;
    sSave.identifier = @"search.save";
    NSButton *sClear = [NSButton buttonWithTitle:RLPTr(@"清除检索 Key") target:self action:@selector(onSearchClearKey:)];
    sClear.bezelStyle = NSBezelStyleRounded;
    sClear.identifier = @"search.clear";
    [searchGroup addButtonRow:@[ sSave, sClear ]];

    // web `.meta-adv-grid`：数据源 / AI 接入 **左右两列**（>=1100px 时两列，窄屏回落单列）。
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
    // 用户要求「所有设置页的每个分组都必须在卡片容器里」：旧 EQ 页把一整套控件直接铺在页面层级。
    // web 这里分两张 sgroup（参数均衡 / 耳机 EQ），原生用一张卡片承载整个均衡器子界面
    // （子界面内部按「20 段参数」「OPRA 耳机目标曲线」自然分段），仍是同一卡片后代。
    RLPSettingsGroup *eqGroup = (RLPSettingsGroup *)RLPSGroup(RLPTr(@"均衡器（PEQ / 耳机 EQ）"),
        RLPTr(@"20 段参数均衡 + OPRA 耳机目标曲线校准"), t);
    [stack addArrangedSubview:eqGroup];
    self.eqView = [[RLPEqualizerView alloc] initWithFrame:NSMakeRect(0, 0, 620, 720)];
    self.eqView.translatesAutoresizingMaskIntoConstraints = NO;
    // 设置页本身就是整页滚动容器：EQ 不再套自己的滚动条（用户实测「只要外面那个滚动条」）。
    [self.eqView setEmbeddedInPage:YES];
    [eqGroup addFullRow:self.eqView];
    // 高度 = 内容自然高度；reload 之后再校正一次（20 段参数/OPRA 文本就位后高度才准确）。
    self.eqHeightConstraint = [self.eqView.heightAnchor
        constraintEqualToConstant:MAX(900.0, [self.eqView preferredContentHeight])];
    [self.eqHeightConstraint setActive:YES];
    [self.eqView reload];
    __weak __typeof__(self) weakEq = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __typeof__(self) self_ = weakEq;
        if (!self_ || !self_.eqHeightConstraint) return;
        CGFloat h = [self_.eqView preferredContentHeight];
        if (h > self_.eqHeightConstraint.constant) {
            self_.eqHeightConstraint.constant = MAX(900.0, h);
            [eqGroup contentDidChange];
        }
    });
}

- (void)fillCalibration:(NSStackView *)stack t:(RLPTheme *)t {
    RLPSettingsGroup *calGroup = (RLPSettingsGroup *)RLPSGroup(RLPTr(@"声音校准"),
        RLPTr(@"房间测量向导 / REW、AutoEq 文本 / 房间校正 IR"), t);
    [stack addArrangedSubview:calGroup];
    self.calView = [[RLPCalibrationView alloc] initWithFrame:NSMakeRect(0, 0, 620, 620)];
    self.calView.translatesAutoresizingMaskIntoConstraints = NO;
    [calGroup addFullRow:self.calView];
    [[self.calView.heightAnchor constraintEqualToConstant:620] setActive:YES];
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
    NSString *bk = self.backendPopup.titleOfSelectedItem ?: @"coreaudio";
    [self postKey:@"backend" value:bk];
    [self syncOutputBackendVisibility:bk];
}

/// 后端联动（web 同语义）：
///   * upnp ⟹ 显示「目标渲染器」整行字段（#sp_upnpwrap display:none 的反向）；
///   * 其余 ⟹ 隐藏它，并让声道音量微调卡片可见（web 在 upnp 时把 #sp_trimwrap 隐藏）。
/// 隐藏/显示改变格子内高度 ⟹ 调一次卡片 contentDidChange，避免高度停留在旧值。
- (void)syncOutputBackendVisibility:(NSString *)bk {
    const BOOL upnp = [bk isEqualToString:@"upnp"];
    if (self.upnpWrap) {
        self.upnpWrap.hidden = !upnp;
        self.upnpField.hidden = !upnp;
        [self.outputGroup contentDidChange];
    }
    if (self.trimGroup) {
        self.trimGroup.hidden = upnp;
        [self.outputGroup contentDidChange];
    }
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
- (void)onInBackend:(id)sender {
    NSString *bk = self.inBackendPopup.titleOfSelectedItem ?: @"none";
    [self postKey:@"inbackend" value:bk];
    if ([bk isEqualToString:@"coreaudio"]) [self loadInputDevices];
}
- (void)onInDevice:(id)sender {
    NSString *n = self.inDevicePopup.titleOfSelectedItem;
    if (!n.length) return;
    // web sp_indev 的 option value 是设备 id；原生下拉显示 name，保存时必须归一成 id。
    NSString *value = n;
    for (NSDictionary *d in self.inDevices) {
        NSString *nm = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : @"";
        NSString *did = [d[@"id"] isKindOfClass:[NSString class]] ? d[@"id"] : @"";
        if (did.length && (nm == n || [nm isEqualToString:n])) { value = did; break; }
    }
    [self postKey:@"indev" value:value];
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

#pragma mark - 反馈发送（就地提交，不弹窗）

static BOOL RLPFeedbackTextBlank(NSString *s) {
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length == 0;
}

/// 安装 ID（服务端约定的客户端标识；只存本机，页面/用户都无从指定）。
- (NSString *)feedbackInstallId {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                         NSUserDomainMask, YES) firstObject];
    NSString *path = [[dir stringByAppendingPathComponent:@"RLPlayer"]
                      stringByAppendingPathComponent:@"rlplayer-feedback-client-id"];
    NSString *existing = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (existing.length) {
        NSString *trimmed = [existing stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (rta::feedback::install_id_valid(trimmed.UTF8String ?: "")) return trimmed;
    }
    unsigned char entropy[16];
    arc4random_buf(entropy, sizeof entropy);
    const std::string nid = rta::feedback::install_id_new(entropy);
    NSString *s = [NSString stringWithUTF8String:nid.c_str()] ?: @"";
    if (!s.length) return @"";
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                               withIntermediateDirectories:YES attributes:nil error:nil];
    [s writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return s;
}

/// 点「发送反馈」：就地提交上方文本域 + 可选诊断包。
/// 不许弹任何新窗口（旧实现直接打开 RLPFeedbackWindowController —— 用户截图五的缺陷）。
- (void)onSendFeedback:(id)sender {
    if (self.fbSending) return;
    NSString *text = self.fbText.string ?: @"";
    if (RLPFeedbackTextBlank(text)) {
        [self fbResultText:RLPTr(@"请先写下反馈内容再发送") kind:2];
        [self.fbText.window makeFirstResponder:self.fbText];
        return;
    }
    const NSUInteger bytes = [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (bytes > rta::feedback::kFeedbackMaxTextBytes) {
        NSString *line = [NSString stringWithFormat:@"%@%llu%@%lu%@",
                          RLPTr(@"内容超过 "), (unsigned long long)rta::feedback::kFeedbackMaxTextBytes,
                          RLPTr(@" 字节（当前 "), (unsigned long)bytes, RLPTr(@"），请精简后再发")];
        [self fbResultText:line kind:2];
        return;
    }
    // web 同一道闸门：只有**探活成功**（==1）才发，null/失败一律拒。
    if (self.fbServerOK != 1) {
        [self fbResultText:RLPTr(@"反馈后台当前不可用，请稍后再试") kind:2];
        return;
    }
    const BOOL wantDiag = (self.fbDiagSwitch.state == NSControlStateValueOn);
    self.fbSending = YES;
    [self fbResultText:(wantDiag ? RLPTr(@"正在打包诊断包并上传…") : RLPTr(@"正在上传…")) kind:0];
    [self fbUpdateSendEnabled];

    if (!wantDiag) { [self fbUploadText:text diagJson:@"" attach:NO]; return; }
    __weak __typeof__(self) weakSelf = self;
    // 诊断包走 /api/diagjson（与「导出诊断包」同一份组装 + 脱敏），不自己拼现场。
    [[RLPCoreClient shared] getData:@"/api/diagjson" completion:^(NSData * _Nullable data) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSString *diag = data.length
            ? ([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"") : @"";
        if (!diag.length)
            [self_ fbResultText:RLPTr(@"诊断包读取失败，将只提交正文") kind:0];
        [self_ fbUploadText:text diagJson:diag attach:(diag.length > 0)];
    }];
}

/// 真正上传：请求体校验/JSON/base64/幂等键全部走 src/net/feedback_api.h（有离线单测）。
/// 成功判定**只看 body.ok**，绝不把 HTTP 200 当成功（后台 200 也用于幂等重放）。
- (void)fbUploadText:(NSString *)text diagJson:(NSString *)diag attach:(BOOL)attach {
    NSString *client = [self feedbackInstallId];
    if (!client.length) {
        self.fbSending = NO;
        [self fbResultText:RLPTr(@"安装 ID 无效：本机安装标识缺失或格式不对，请重新启动应用后再试。") kind:2];
        [self fbUpdateSendEnabled];
        return;
    }
    rta::feedback::FeedbackUploadInput in;
    in.text = text.UTF8String ?: "";
    in.version = RLPLAYER_VERSION;
    in.os = [NSString stringWithFormat:@"macOS %@",
             [NSProcessInfo processInfo].operatingSystemVersionString].UTF8String ?: "";
    in.client = client.UTF8String ?: "";
    in.diag_json = diag.UTF8String ?: "";
    in.attach_diag = attach;
    unsigned int rnd = 0;
    arc4random_buf(&rnd, sizeof rnd);
    const long long epoch = (long long)std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    in.idempotency_key = rta::feedback::make_feedback_idempotency_key(epoch, rnd);

    const auto built = rta::feedback::build_feedback_upload(in);
    if (!built.ok) {
        self.fbSending = NO;
        NSString *err = [NSString stringWithUTF8String:built.error.c_str()] ?: RLPTr(@"反馈内容不合法");
        [self fbResultText:err kind:2];
        [self fbUpdateSendEnabled];
        return;
    }

    const std::string bodyCpp = built.json;
    NSString *bodyStr = [NSString stringWithUTF8String:bodyCpp.c_str()] ?: @"";
    NSString *url = [NSString stringWithUTF8String:rta::feedback::kFeedbackUploadUrl] ?: @"";

    __weak __typeof__(self) weakSelf = self;
    void (^reply)(NSInteger, NSData *) = ^(NSInteger status, NSData *body) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __typeof__(self) self_ = weakSelf;
            if (!self_) return;
            NSString *rawStr = body.length
                ? ([[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @"") : @"";
            const std::string raw = rawStr.UTF8String ?: "";
            const auto r = rta::feedback::parse_feedback_upload_reply((int)status, raw);
            self_.fbSending = NO;
            if (r.ok) {
                NSString *ticket = [NSString stringWithUTF8String:r.id.c_str()] ?: @"";
                NSString *line = [NSString stringWithFormat:@"%@%@%@",
                                  RLPTr(@"已收到，工单号 "),
                                  ticket.length ? ticket : RLPTr(@"(无)"),
                                  RLPTr(@"。感谢反馈！")];
                if (attach && !r.diag_stored)
                    line = [line stringByAppendingString:RLPTr(@"（诊断包未被后台保存）")];
                [self_ fbResultText:line kind:1];
                self_.fbText.string = @"";
                [self_ updateFbCount];
            } else {
                NSString *m = [NSString stringWithUTF8String:r.error.c_str()] ?: @"";
                if (!m.length) m = [NSString stringWithFormat:RLPTr(@"提交失败（HTTP %d）"), (int)status];
                NSString *hint = @"";
                if (r.code == "request_too_large") hint = RLPTr(@"（可取消勾选「附带诊断包」只发正文）");
                else if (r.code == "rate_limited") hint = RLPTr(@"（稍等一会儿再试）");
                [self_ fbResultText:[NSString stringWithFormat:@"%@%@%@",
                                     RLPTr(@"发送失败："), m, hint] kind:2];
            }
            [self_ fbUpdateSendEnabled];
        });
    };

    if (self.fbUploadTransport) {
        self.fbUploadTransport(url, bodyStr, reply);
        return;
    }
    const std::string urlCpp = rta::feedback::kFeedbackUploadUrl;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        const auto resp = rta::net::http_post(urlCpp, bodyCpp, {}, "application/json",
                                              rta::feedback::kFeedbackUploadTimeoutMs);
        NSData *d = resp.body.empty() ? nil
                                      : [NSData dataWithBytes:resp.body.data() length:resp.body.size()];
        reply((NSInteger)resp.status, d);
    });
}



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
        // 后端联动（web 同语义）：upnp 才显示目标渲染器、隐藏声道微调；其它后端反过来。
        [self_ syncOutputBackendVisibility:self_.backendPopup.titleOfSelectedItem ?: @"coreaudio"];
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
        // 输入设备：落盘值可能是设备 id（web option value），设备列表异步到了再按 id 回显。
        if ([kv[@"indev"] isKindOfClass:[NSString class]]) {
            self_.savedInDev = kv[@"indev"];
            [self_ loadInputDevices];
        }

        id dsd = kv[@"dsd"];
        if ([dsd respondsToSelector:@selector(integerValue)]) {
            NSInteger n = [dsd integerValue];
            NSString *title = (n <= 0) ? RLPTr(@"不升频") : [NSString stringWithFormat:@"dsd%ld", (long)n];
            if ([self_.dsdRatePopup itemWithTitle:title]) [self_.dsdRatePopup selectItemWithTitle:title];
        }
        id root = kv[@"root"];
        if ([root isKindOfClass:[NSString class]] && [root length])
            self_.rootField.stringValue = root;
        // 声道音量微调按真实「输出声道数」重建（0 = 跟随源 → 先按立体声，web 同口径）。
        NSInteger trimCh = 2;
        id chv = kv[@"ch"];
        if ([chv respondsToSelector:@selector(integerValue)]) {
            trimCh = [chv integerValue];
        }
        [self_ rebuildTrimFields:trimCh];
        // 下拉回显「输出声道数」本身（按渠道值选对应项）。
        if (self_.chPopup) {
            const NSInteger idx = (trimCh == 6) ? 2 : (trimCh == 8) ? 3 : (trimCh == 2) ? 1 : 0;
            if (idx >= 0 && idx < self_.chPopup.numberOfItems) [self_.chPopup selectItemAtIndex:idx];
        }
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
    const NSInteger ch = [vals[(i >= 0 && i < (NSInteger)vals.count) ? i : 0] integerValue];
    [self rebuildTrimFields:ch];
}

/// 声道微调滑杆：更新读数并立即提交整串 trim（后端只认逗号分隔的 8 个值）。
- (void)onTrimSlider:(NSSlider *)s {
    NSString *key = [NSString stringWithFormat:@"sp_trim%ld", (long)s.tag];
    NSTextField *val = self.trimValueLabels[key];
    if (val) val.stringValue = [NSString stringWithFormat:@"%.1f dB", s.doubleValue];
    [self onTrim:nil];
}

- (void)onBuffer:(NSTextField *)s { [self postKey:@"buffer" value:s.stringValue]; }
- (void)onRamp:(NSTextField *)s { [self postKey:@"ramp" value:s.stringValue]; }
- (void)onTrim:(id)sender {
    // 一次提交整串 trim（后端只认逗号分隔的 8 个值）；没生成的声道位按 0。
    NSMutableArray<NSString *> *vals = [NSMutableArray array];
    for (NSInteger i = 0; i < 8; ++i) {
        NSSlider *sl = self.trimFields[[NSString stringWithFormat:@"sp_trim%ld", (long)i]];
        [vals addObject:sl ? [NSString stringWithFormat:@"%.1f", sl.doubleValue] : @"0"];
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
- (void)onInRefreshDevices:(id)sender { [self loadInputDevices]; }
/// 「模拟源」开关只改下一次开始采集的 mode，不写设置（旧 RLPInputView 同语义）。
- (void)onNullSourceToggle:(NSSwitch *)s {
    if (self.inMsg) self.inMsg.stringValue = (s.state == NSControlStateValueOn)
        ? RLPTr(@"下次开始采集将使用模拟源（不打开真实设备）") : @"";
}
- (void)onInOffset:(NSPopUpButton *)s { [self postKey:@"inoffset" value:s.titleOfSelectedItem ?: @"0"]; }
- (void)onInSeconds:(NSTextField *)s { [self postKey:@"inseconds" value:s.stringValue]; }
- (void)onInOut:(NSTextField *)s { [self postKey:@"inout" value:s.stringValue]; }

/// 开始采集：**只由用户点按钮触发**（铁律 1：绝不自动打开输入设备）。
/// 请求体与 web startInputCapture 一致：mode / dev(id) / seconds / out；
/// 直通监听会向默认输出送声音 ⟹ 仍然二次确认，绝不静默开始。
- (void)onInputStart:(id)sender {
    if (![RLPCoreClient shared].started) { RLPToast(RLPTr(@"核心未启动")); return; }
    const BOOL wantNull = (self.inNullSwitch.state == NSControlStateValueOn);
    const BOOL wantMonitor = (self.inMonitorSwitch.state == NSControlStateValueOn) && !wantNull;
    if (wantMonitor) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = RLPTr(@"开启直通监听？");
        a.informativeText = RLPTr(@"采集信号会被直接送到当前输出设备。请先确认音量，注意啸叫与回声。");
        a.alertStyle = NSAlertStyleWarning;
        [a addButtonWithTitle:RLPTr(@"确认开启")];
        [a addButtonWithTitle:RLPTr(@"取消")];
        if ([a runModal] != NSAlertFirstButtonReturn) return;
    }
    NSMutableString *body = [NSMutableString stringWithFormat:@"mode=%@",
                             wantNull ? @"null" : (wantMonitor ? @"monitor" : @"record")];
    const NSInteger di = self.inDevicePopup.indexOfSelectedItem;
    NSString *devId = @"";
    if (di > 0 && di - 1 < (NSInteger)self.inDevices.count) {
        id d = self.inDevices[di - 1][@"id"];
        if ([d isKindOfClass:[NSString class]]) devId = d;
    }
    if (devId.length) [body appendFormat:@"&dev=%@", RLPEnc(devId)];
    const double secs = self.inSecondsField.doubleValue;
    if (secs > 0) [body appendFormat:@"&seconds=%.3f", secs];
    NSString *out = [self.inOutField.stringValue stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (out.length) [body appendFormat:@"&out=%@", RLPEnc(out)];

    self.inStartBtn.enabled = NO;
    self.inStopBtn.enabled = NO;
    self.inMsg.stringValue = RLPTr(@"正在启动采集…");
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/input/start" body:body
                          completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        const BOOL ok = json && [json[@"ok"] boolValue];
        self_.inStartBtn.enabled = !ok;
        self_.inStopBtn.enabled = ok;
        self_.inMsg.stringValue = ok
            ? (wantMonitor ? RLPTr(@"直通监听已启动") : RLPTr(@"录制采集已启动"))
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
    // 「查看 / 复制诊断摘要」按用户 2026-11-13 的要求：**只做复制 + 就地提示**。
    // 不显示 JSON 面板、不弹窗、不出现第二个容器（旧实现把摘要渲染进 sp_diagsummarytext 面板，
    // 用户截图六看到的整块 JSON 就是它）。摘要是空的就不假装「已复制」。
    if (![RLPCoreClient shared].started) { self.diagMsg.stringValue = RLPTr(@"核心未启动"); return; }
    __weak __typeof__(self) weakSelf = self;
    void (^done)(NSDictionary * _Nullable) = ^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSString *text = json ? [[NSString alloc] initWithData:
            [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil]
            encoding:NSUTF8StringEncoding] : nil;
        if (text.length) {
            [[NSPasteboard generalPasteboard] clearContents];
            [[NSPasteboard generalPasteboard] setString:text forType:NSPasteboardTypeString];
            self_.diagMsg.stringValue = RLPTr(@"摘要已复制");
        } else {
            self_.diagMsg.stringValue = RLPTr(@"诊断摘要读取失败");
        }
    };
    if (self.diagSummaryTransport) { self.diagSummaryTransport(done); return; }
    [[RLPCoreClient shared] getJSON:@"/api/diag" completion:done];
}

/// web #bNet 同语义：**点击才查询** /api/net，结果写进 sp_netmsg。
/// 单进程形态下 http=false，据此如实显示，不编一个能点的地址（那是误导，比空白更糟）。
- (void)onNetInfo:(id)sender {
    self.netMsg.hidden = NO;
    [self.netGroup contentDidChange];
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

#pragma mark - 反馈字数（web fbCount 同口径：按 UTF-8 **字节**计，上限 16384）

static NSUInteger RLPUTF8Bytes(NSString *s) {
    return [s lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
}

- (void)updateFbCount {
    const NSUInteger n = RLPUTF8Bytes(self.fbText.string ?: @"");
    self.fbCount.stringValue = [NSString stringWithFormat:@"%lu / 16384 字节", (unsigned long)n];
    // 超限立刻标红（web fbCount 同一行为），不悄悄截断。
    self.fbCount.textColor = (n > 16384) ? [RLPTheme current].warn : [RLPTheme current].mut2;
}

- (void)textDidChange:(NSNotification *)note {
    if (note.object == self.fbText) [self updateFbCount];
}

- (void)onFeedbackRetry:(id)sender { self.fbLastChannelCheck = nil; [self probeFeedbackChannel]; }

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
    // 2026-11-13：诊断/反馈区内联化后新增的主/次按钮要跟着主题走
    // （否则切浅色后红底主按钮仍是深色主题的 accent 快照）。
    if (self.diagZipBtn) {
        self.diagZipBtn.layer.backgroundColor = t.accent.CGColor;
        self.diagZipBtn.contentTintColor = NSColor.whiteColor;
    }
    if (self.fbSendBtn) {
        self.fbSendBtn.layer.backgroundColor = t.accent.CGColor;
        self.fbSendBtn.contentTintColor = NSColor.whiteColor;
    }
    for (NSButton *b in @[self.diagJsonBtn, self.diagSummaryBtn, self.fbRetryBtn]) {
        if (!b) continue;
        b.layer.backgroundColor = t.hov.CGColor;
        b.layer.borderColor = t.line.CGColor;
        b.contentTintColor = t.text;
    }
    if (self.fbCount) [self updateFbCount];
    [self.eqView applyTheme];
    [self.inputView applyTheme];
    [self.castView applyTheme];
    [self.calView applyTheme];
    [self.serversView applyTheme];
    [self.metaSourcesView applyTheme];
    [self.libStatsView applyTheme];
}

@end