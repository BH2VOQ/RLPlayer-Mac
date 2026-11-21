// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPSettingsViewController.mm — 设置页（纯 AppKit）
//
// 页签 = web `data-g` 的同一份清单，**不随模式变化**。
// 聆听 / 专业共享全部页签，通用 / 音频处理只调整导航层级，不限制功能访问。
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
#include <cstdio>
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
#if __has_include("mac_update.h")
#include "mac_update.h"
#endif
#include "dsp/filter_family.h"   // U8：滤波器族标注（文案唯一出处，纯头）
#include "net/feedback_api.h"
#include "net/http_client.h"
#include "net/install_id.h"

#include <chrono>

@interface RLPEqualizerView (RLPPendingDraftState)
@property (nonatomic, readonly) BOOL hasPendingDraft;
@end

/// 宿主重建 EQ 视图时的**最小状态存取 API**（实现在 RLPEqualizerView.mm）。
/// 为什么需要它：普通页签草稿快照按 isEqOwnedView 把 EQ 的控件整块跳过（写值会绕过
/// peqDraftEpoch / peqSyncedDraftEpoch 的代次判断），但 EQ 自己的 hasPendingDraft 只覆盖
/// PEQ 代次与 preamp 编辑态，不包含 presetName / OPRA 查询框 / 单段 Q 这些还在 field
/// editor 里的文本；pane 被摘下窗口时这些文本会丢。快照只搬用户态，不搬后端真值；
/// draftEpoch / syncedDraftEpoch / reqSeq 随快照一起搬 —— 恢复后仍由代次守卫决定
/// 哪个 GET/POST 回包有资格落地。
@interface RLPEqualizerView (RLPDraftState)
- (NSDictionary<NSString *, id> *)rlp_captureDraftState;
- (void)rlp_restoreDraftState:(NSDictionary<NSString *, id> *)state;
@end

#pragma mark - 滤波器族标注（U8）

// ---- U8（2026-11-16）：滤波器下拉的族标注 ----
// 名字来自 /api/filters（后端预设表），族/相位/文案全部来自 src/dsp/filter_family.h。
// 纪律：**文案**可以带族名，**值**永远是原名（representedObject）—— 后端只认原名，
// 把「poly-sinc-lp（多相 sinc 线性相位）」当值发出去会被 /api/settings 拒绝。
static NSString *RLPFilterFamilyName(NSString *name) {
    if (!name.length) return @"";
    const auto fam = rta::dsp::filter_family(name.UTF8String);
    return RLPTr([NSString stringWithUTF8String:rta::dsp::filter_family_label(fam)]);
}

static NSString *RLPFilterPhaseName(NSString *name) {
    if (!name.length) return @"";
    const auto ph = rta::dsp::filter_phase_of_name(name.UTF8String);
    return RLPTr([NSString stringWithUTF8String:rta::dsp::filter_phase_label(ph)]);
}

/// 下拉项文案：`poly-sinc-lp（多相 sinc 线性相位）`；名字没写相位就只写族名。
static NSString *RLPFilterDecoratedTitle(NSString *name) {
    NSString *fam = RLPFilterFamilyName(name);
    if (!name.length || !fam.length) return name;
    NSString *ph = RLPFilterPhaseName(name);
    if (!ph.length) return [NSString stringWithFormat:@"%@（%@）", name, fam];
    return [NSString stringWithFormat:@"%@（%@ %@）", name, fam, ph];
}

/// 一行族说明：族性格 +（名字写明的）相位行为。文案出自 filter_family.h，不含数值承诺。
static NSString *RLPFilterFamilyNote(NSString *name) {
    if (!name.length) return @"";
    const auto fam = rta::dsp::filter_family(name.UTF8String);
    const auto ph = rta::dsp::filter_phase_of_name(name.UTF8String);
    NSString *fn = RLPTr([NSString stringWithUTF8String:rta::dsp::filter_family_note(fam)]);
    NSString *pn = RLPTr([NSString stringWithUTF8String:rta::dsp::filter_phase_note(ph)]);
    if (!pn.length) return fn;
    return [NSString stringWithFormat:@"%@ %@", fn, pn];
}

#pragma mark - 页签定义

// 页签**不随模式变化**：一份清单，与既有 `data-g` 深链对应。
// 页签是**索引 → key 的运行时表**（不再用编译期常量数组），重建只为保持选中页。
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

static NSArray<NSString *> *RLPSettingsGeneralTabKeys(void) {
    return @[ @"adv", @"out", @"in", @"meta", @"stream", @"diag" ];
}

static NSArray<NSString *> *RLPSettingsAudioTabKeys(void) {
    return @[ @"pcm", @"sdm", @"eq", @"cal" ];
}

static NSInteger RLPSettingsGroupForKey(NSString *key) {
    return [RLPSettingsAudioTabKeys() containsObject:key] ? 1 : 0;
}

static NSArray<NSString *> *RLPSettingsVisibleKeysForGroup(NSInteger group) {
    return (group == 1) ? RLPSettingsAudioTabKeys() : RLPSettingsGeneralTabKeys();
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
@property (nonatomic, strong) NSSegmentedControl *groupTabs;
@property (nonatomic, strong) NSButton *workbenchBtn;
@property (nonatomic, strong) NSTextField *modeHintLabel;
@property (nonatomic, assign) NSInteger activeGroup;
@property (nonatomic, strong) NSSegmentedControl *tabs;
@property (nonatomic, strong) NSView *paneHost;
@property (nonatomic, assign) RLPSTab tab;
/// 实际显示在 paneHost 里的页签（selectPane 会先把 self.tab 改成目标页再调 showTab，
/// 光看 self.tab 已无法判断“即将离开的是不是 EQ”）。
@property (nonatomic, assign) RLPSTab shownTab;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSView *> *paneCache;
/// 已经从后端读到真值的键：没读到之前不写回，避免用 UI 默认值覆盖用户真实设置。
@property (nonatomic, strong) NSMutableSet<NSString *> *loadedKeys;
@property (nonatomic, strong) NSTextField *statusLine;

// ---- 输出页（web data-g=out）----
@property (nonatomic, strong) NSPopUpButton *backendPopup;
@property (nonatomic, strong) NSButton *bpFixBtn;
@property (nonatomic, copy) NSString *savedUpnpDev;
@property (nonatomic, copy) NSArray *upnpDevices;
/// 读回（GET）与保存（POST）各用一套序号（2026-11-18 夜间评审 A2）。
/// 原来共用一个计数器：一次保存（例如主题切档）就会让**在途的设置读回整包作废**
/// （切主题重建时 GET 刚发出、POST 紧接着发出 ⟹ GET 回包因 seq 过期全被丢，
/// 开关/文本框停在上一次的值，用户看到的就是"设置页被重置"）。
@property (nonatomic, assign) NSUInteger settingsGetSeq;
@property (nonatomic, assign) NSUInteger settingsPostSeq;
/// key → 最近一次保存**发起**时刻（systemUptime）。读回回包据此只跳过"在它之后被保存过"的键，
/// 既不整包丢弃，也不会用旧快照盖掉用户刚保存的值。
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *settingsKeyPostAt;
@property (nonatomic, strong) NSView *upnpWrap;
/// 「目标渲染器」整行字段容器：后端不是 upnp 时连标签一起隐藏（web #sp_upnpwrap 的 display:none）。
@property (nonatomic, strong) NSView *upnpField;
@property (nonatomic, strong) NSPopUpButton *upnpPop;
@property (nonatomic, strong) NSButton *upnpScanBtn;
@property (nonatomic, strong) NSTextField *upnpMsg;
@property (nonatomic, strong) NSPopUpButton *devicePopup;
/// /api/settings 读回的落盘设备 id：设备列表异步到达后再按 id 回显（web option value=id）。
@property (nonatomic, copy) NSString *savedDeviceId;
/// /api/settings 读回的 filter / filterNx：清单异步到达后再按值回显（空串 = 跟随 1x）。
@property (nonatomic, copy) NSString *savedFilter;
@property (nonatomic, copy) NSString *savedFilterNx;
@property (nonatomic, copy) NSString *savedSdmFilter;
@property (nonatomic, copy) NSString *savedSdmFilterNx;
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
@property (nonatomic, strong) NSMutableArray<NSNumber *> *savedTrimValues;
/// web #sp_eq（cal 页「EQ 文件（REW / AutoEq 文本）」路径输入）：旧码只有映射表里的
/// 标识符、没有控件，本轮补成真控件并接 /api/settings 的 eq 键。
@property (nonatomic, strong) NSTextField *eqField;
@property (nonatomic, strong) NSTextField *trimChMsg;

// ---- PCM 页（web data-g=pcm）----
@property (nonatomic, strong) NSPopUpButton *ratePopup;
/// U5（v3.3.11）：采样率族策略下拉（web 无同名控件；原生设置页新增，键 = rateFamilyPolicy）。
@property (nonatomic, strong) NSPopUpButton *rateFamilyPopup;
@property (nonatomic, strong) NSPopUpButton *filt1xPopup;
@property (nonatomic, strong) NSPopUpButton *filtNxPopup;
/// U8：Nx 滤波器行下方的族说明（web 无此控件，原生新增；parity 扫描靠 identifier 取证）。
@property (nonatomic, strong) NSTextField *filtNxNote;
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
/// U12（2026-11-16）：1-bit SDM 拐点准入提示（原生新增控件；web 无）。
/// 文案由 GET /api/settings 的 sdm 对象驱动（admitted=false → sdm.note 原样显示），
/// 前端**不**写死 100000 Hz 阈值 —— 策略真相源是 src/dsp/sdm_output_policy.h。
@property (nonatomic, strong) NSTextField *sdmCornerNote;
/// SDM 卡片：提示显示/隐藏后要让网格重算卡体高度（否则留一条空白行 / 把提示裁掉）。
@property (nonatomic, strong) RLPSettingsGroup *sdmGroup;
/// 最近一次 GET 的 sdm 快照：SDM 页签是懒建的，先 reload 后建页签时用它补一次文案。
@property (nonatomic, copy) NSDictionary *sdmAdmission;
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
@property (nonatomic, strong) RLPSettingsGroup *diagGroup;
@property (nonatomic, strong) RLPSettingsGroup *fbGroup;
@property (nonatomic, strong) NSButton *diagZipBtn;
@property (nonatomic, strong) NSButton *diagJsonBtn;
@property (nonatomic, strong) NSButton *diagSummaryBtn;
@property (nonatomic, strong) NSTextField *diagMsg;
@property (nonatomic, strong) NSButton *diagChannelsBtn;
@property (nonatomic, strong) NSTextField *diagChannelsLabel;
@property (nonatomic, assign) BOOL diagChannelsChecking;
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
/// v3.3.11 `rlFbPreview`：提交前先看清「会发送什么」（纯前端，不发请求）。
@property (nonatomic, strong) NSButton *fbPreviewBtn;
@property (nonatomic, strong) NSTextField *fbPreviewBox;
/// v3.3.11 `rlFbResult`：持久结果区（结论留在页面上，不只刷一行状态）。
@property (nonatomic, strong) NSTextField *fbResultBox;

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
@property (nonatomic, copy, nullable) NSString *fbSystemVersionOverride;
/// 诊断摘要数据的测试接缝（生产路径仍走 /api/diag）。
@property (nonatomic, copy) void (^diagSummaryTransport)(void (^done)(NSDictionary * _Nullable json));
/// 通道连通性检查的测试接缝（生产路径走 /api/diag/channels）。
@property (nonatomic, copy) void (^diagChannelsTransport)(void (^done)(NSDictionary * _Nullable json));
@property (nonatomic, strong) NSSwitch *streamSwitch;

// ---- 共用子界面 ----
@property (nonatomic, strong, nullable) RLPSettingsGroup *srvGroup;
@property (nonatomic, strong, nullable) RLPSettingsGroup *castGroup;
@property (nonatomic, strong, nullable) RLPServersView *serversView;
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
@property (nonatomic, weak, nullable) NSStackView *metaHostStack;
@property (nonatomic, strong, nullable) RLPSettingsGroup *metaTopGroup;
@property (nonatomic, strong, nullable) RLPSettingsGroup *metaDataGroup;
@property (nonatomic, strong, nullable) RLPSettingsGroup *metaAiGroup;
@property (nonatomic, strong, nullable) RLPSettingsGroup *metaSearchGroup;
@property (nonatomic, strong, nullable) NSStackView *metaTwoColStack;
@property (nonatomic, strong, nullable) NSLayoutConstraint *metaAdvWidthConstraint;
@property (nonatomic, strong, nullable) NSLayoutConstraint *metaTwoColWidthConstraint;
@property (nonatomic, strong, nullable) NSLayoutConstraint *metaSearchWidthConstraint;
@property (nonatomic, copy, nullable) NSArray<NSLayoutConstraint *> *metaVerticalCardWidthConstraints;
@property (nonatomic, strong, nullable) NSView *metaModelContainer;
@property (nonatomic, strong, nullable) NSStackView *metaModelPrimaryRow;
@property (nonatomic, strong, nullable) NSStackView *metaModelSecondaryRow;
@property (nonatomic, strong, nullable) NSView *metaModelHiddenDock;
@property (nonatomic, copy, nullable) NSArray<NSLayoutConstraint *> *metaModelRowConstraints;
@property (nonatomic, strong, nullable) NSButton *llmSaveBtn;
@property (nonatomic, strong, nullable) NSButton *llmTestBtn;
@property (nonatomic, strong, nullable) NSButton *llmClearBtn;
@property (nonatomic, strong, nullable) NSView *metaAiBtnContainer;
@property (nonatomic, strong, nullable) NSStackView *metaAiBtnRow1;
@property (nonatomic, strong, nullable) NSStackView *metaAiBtnRow2;
@property (nonatomic, copy, nullable) NSArray<NSLayoutConstraint *> *metaAiBtnConstraints;
/// 响应式状态缓存：-1 未初始化，0 窄布局，1 宽布局，2 折叠/隐藏下拉等模式。
@property (nonatomic, assign) NSInteger metaResponsiveTwoColMode;
@property (nonatomic, assign) NSInteger metaResponsiveModelMode;
@property (nonatomic, assign) NSInteger metaResponsiveAiBtnMode;
@property (nonatomic, assign) BOOL metaResponsiveUpdating;
@property (nonatomic, strong) RLPEqualizerView *eqView;
/// EQ 子界面的未提交状态（切页签 / 切语言 / 切主题时由 showTab 收发，见 rlp_captureDraftState）。
@property (nonatomic, strong, nullable) NSDictionary<NSString *, id> *eqDraftState;
@property (nonatomic, strong) NSLayoutConstraint *eqHeightConstraint;
@property (nonatomic, strong) RLPSettingsGroup *outputGroup;
@property (nonatomic, strong) RLPSettingsGroup *updGroup;
@property (nonatomic, strong) RLPInputView *inputView;
@property (nonatomic, strong) RLPCastView *castView;
@property (nonatomic, strong) RLPCalibrationView *calView;
/// 校准卡高度下限（内容变化后按 preferredContentHeight 重新校正，避免卡内留大片空白）。
@property (nonatomic, strong, nullable) NSLayoutConstraint *calHeightConstraint;
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
@property (nonatomic, copy) NSString *lastAppliedLang;
/// 语言切换期间跨所有 cachedPane 保存的未提交草稿（tabKey -> @{ identifier: draftString }）。
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableDictionary<NSString *, NSString *> *> *pendingPaneDrafts;
/// 当前挂在 paneHost 里的那个页签的边贴边约束。换页签时先摘掉这一组，
/// 而不是「先把子视图全删掉再挂新的」—— 后者中间有一帧空容器（见 showTab 注释）。
@property (nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *activePaneConstraints;
/// 用户已修改但尚未保存成功的控件 identifier（防止延迟 /api/settings 与 /api/llm 回包覆盖）。
@property (nonatomic, strong) NSMutableSet<NSString *> *dirtyControlIds;
/// 最近一次从后端回填到各控件的值（用于识别未触发 textDidChange 的草稿改动）。
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *lastLoadedValues;
@property (nonatomic, assign) NSUInteger llmSeq;
@property (nonatomic, assign) BOOL llmModelMsgIsWarn;
@property (nonatomic, assign) BOOL hasCapturedLlmModelState;
@property (nonatomic, copy, nullable) NSArray<NSString *> *capturedLlmModelTitles;
@property (nonatomic, assign) NSInteger capturedLlmModelSelectedIndex;
@property (nonatomic, assign) BOOL capturedLlmModelHidden;
@property (nonatomic, copy, nullable) NSString *capturedLlmModelMsg;
@property (nonatomic, assign) BOOL capturedLlmModelMsgIsWarn;
@property (nonatomic, assign) BOOL suppressNextLlmAutoLoad;

- (void)reloadDataIncludingEqualizer:(BOOL)reloadEq;

#pragma mark - 私有方法声明（保存链路 + 页签草稿）

// 声明集中在这里的原因：postKey:value: 在实现里出现在 postKey:value:completion: 之前，
// 而回滚 / 答复落地方法又被多处调用，靠实现顺序"碰巧可见"迟早出隐性告警。
- (void)postKey:(NSString *)key value:(NSString *)value
      completion:(void (^_Nullable)(BOOL ok))completion;
- (void)postKeys:(NSDictionary<NSString *, NSString *> *)kv
       completion:(void (^_Nullable)(BOOL ok))completion;
- (void)applySettingsSaveSuccess:(NSDictionary<NSString *, NSString *> *)submitted seq:(NSUInteger)seq;
- (void)applySettingsSaveFailure:(NSDictionary<NSString *, NSString *> *)reverted text:(NSString *)text;
- (void)revertControlsForBackendKey:(NSString *)key submittedValue:(NSString *)value;
- (NSMutableArray<NSView *> *)cachedControlsForBackendKey:(NSString *)key;
- (void)applyKV:(NSDictionary *)kv toSwitch:(NSSwitch *)sw key:(NSString *)key;
- (void)applyKV:(NSDictionary *)kv toTextField:(NSTextField *)tf key:(NSString *)key;
- (void)applyKV:(NSDictionary *)kv toPopup:(NSPopUpButton *)pop key:(NSString *)key;
- (NSView *)findCachedControlWithIdentifier:(NSString *)ident;
- (void)clearDirtyControlId:(NSString *)ident expectedValue:(nullable NSString *)expectedValue;
- (void)clearDirtyForBackendKey:(NSString *)key submittedValue:(NSString *)value;

// 页签草稿（切页签 / 切语言 / 切主题）
- (void)snapshotPendingPaneDrafts;
- (void)snapshotPendingPaneDraftsForTab:(RLPSTab)tab;
- (void)snapshotDraftsOfOutgoingPaneIfNeededForTab:(RLPSTab)tab;
- (void)restorePendingDraftsForTab:(RLPSTab)tab inPane:(NSView *)pane;

// 元数据页响应式布局（折叠态脱离宽约束 + 窄窗回落单列）
- (void)resetMetaResponsiveState;
- (CGFloat)metaTargetHostWidthPreferringViewBounds:(BOOL)preferViewBounds;
- (void)updateMetaResponsiveLayoutForHostWidth:(CGFloat)hostW;
- (BOOL)updateMetaModelRowLayoutForBodyWidth:(CGFloat)bodyW;
- (BOOL)updateMetaAiBtnRowLayoutForBodyWidth:(CGFloat)bodyW;
- (void)captureLlmModelStateIfNeeded;
- (void)restoreLlmModelStateIfNeeded;

@end

/// 设置页滚动容器：当纵向滚动条随展开/折叠显隐、contentView 宽度发生 ±17pt 变化而
/// scroll 自身 frame 未变时，AppKit `-tile` 改了 clip frame 却不会触发 docView 重算，
/// 导致 stack 停留在旧宽（714>697 或 657<674）。在 layout/tile 后同步一次 docView 布局。
/// 设置页每个页签的文档视图（**翻转坐标**：原点左上、y 向下）。
///
/// 为什么必须是翻转的：
///   文档视图若沿用 AppKit 默认的**非翻转** NSStackView，坐标系原点在**内容底端**，
///   clip 的 bounds.origin.y=0 看到的是文档最下面一截。buildPane 又在栈尾放了一个
///   可伸展的空白 spacer（用来把真实内容压到顶部），于是新建页签第一次上屏时，
///   可见区正好落在 spacer 上 = **一整屏空白**；要等后续某一轮 runloop 把 clip
///   原点夹回文档顶，内容才「跳」回来。改成翻转文档视图后，「顶部」就是 origin.y=0，
///   新建/复用的页签天然从顶部开始画，不依赖任何异步补救。
///
/// 为什么可以安全翻转：栈内子视图由 Auto Layout 排布，坐标方向只影响「第 0 个元素在
/// 上还是下」；NSStackView 在 flipped 祖先里同样自上而下排列（已离屏实测）。
@interface RLPSettingsPaneDocView : NSStackView
@end

@implementation RLPSettingsPaneDocView
- (BOOL)isFlipped { return YES; }
@end

@interface RLPSettingsScrollView : NSScrollView
/// 同步把可见区钉到内容顶部（换页签首帧调用，见 showTab）。
- (void)pinToTopNow;
- (void)clampVerticalScrollIfNeeded;
@end

@implementation RLPSettingsScrollView {
    BOOL _rlpSyncingWidth;
}

- (void)clampVerticalScrollIfNeeded {
    NSClipView *clip = self.contentView;
    NSView *doc = self.documentView;
    if (!clip || !doc) return;
    const CGFloat clipH = clip.bounds.size.height;
    const CGFloat docH = doc.frame.size.height;
    if (clipH <= 1.0 || docH <= 1.0) return;
    // 「顶部」随坐标系不同：翻转文档是 0，非翻转文档是 docH-clipH。
    // 旧实现只按非翻转写了 docH-clipH；文档视图翻过来之后再用那个公式，
    // 会把「本来就在顶部」的页签**反向推到底部**，反而制造一次跳屏。
    const CGFloat topY = doc.isFlipped ? 0.0 : MAX(0.0, docH - clipH);
    const CGFloat maxY = MAX(topY, docH - clipH);
    NSPoint o = clip.bounds.origin;
    if (o.y > maxY + 0.5 || o.y < topY - 0.5) {
        o.y = MIN(maxY, MAX(topY, o.y));
        [clip scrollToPoint:o];
        [self reflectScrolledClipView:clip];
    }
}

/// 把可见区**同步**钉在内容顶部。
///
/// 为什么必须同步、不能等下一轮 runloop：异步补位的那一帧就是用户要看到的那块空白。
- (void)pinToTopNow {
    NSClipView *clip = self.contentView;
    NSView *doc = self.documentView;
    if (!clip || !doc) return;
    // 先让文档把 Auto Layout 解算完：否则此刻拿到的 docH 还是上一轮的旧值，
    // 夹回顶部会定在一个马上又变的位置上。
    [clip layoutSubtreeIfNeeded];
    [doc layoutSubtreeIfNeeded];
    const CGFloat clipH = clip.bounds.size.height;
    const CGFloat docH = doc.frame.size.height;
    const CGFloat topY = doc.isFlipped ? 0.0 : MAX(0.0, docH - clipH);
    if (fabs(clip.bounds.origin.y - topY) > 0.5) {
        [clip scrollToPoint:NSMakePoint(clip.bounds.origin.x, topY)];
        [self reflectScrolledClipView:clip];
    }
}

- (void)tile {
    const CGFloat prevClipW = self.contentView ? self.contentView.bounds.size.width : 0.0;
    [super tile];
    NSClipView *clip = self.contentView;
    NSView *doc = self.documentView;
    const CGFloat clipW = clip ? clip.bounds.size.width : 0.0;
    if (clip && doc && clipW > 1.0 &&
        (fabs(clipW - prevClipW) > 0.5 ||
         fabs(doc.frame.size.width - clipW) > 0.5 ||
         fabs(doc.bounds.size.width - clipW) > 0.5)) {
        [clip setNeedsLayout:YES];
        [doc setNeedsLayout:YES];
        [self setNeedsLayout:YES];
    }
    [self clampVerticalScrollIfNeeded];
}

- (void)layout {
    const CGFloat prevClipW = self.contentView ? self.contentView.bounds.size.width : 0.0;
    [super layout];
    if (_rlpSyncingWidth) return;
    NSClipView *clip = self.contentView;
    NSView *doc = self.documentView;
    const CGFloat clipW = clip ? clip.bounds.size.width : 0.0;
    if (!clip || !doc || clipW <= 1.0) {
        [self clampVerticalScrollIfNeeded];
        return;
    }
    if (fabs(clipW - prevClipW) > 0.5 ||
        fabs(doc.frame.size.width - clipW) > 0.5 ||
        fabs(doc.bounds.size.width - clipW) > 0.5) {
        _rlpSyncingWidth = YES;
        for (int pass = 0; pass < 2; ++pass) {
            const CGFloat curClipW = clip.bounds.size.width;
            if (curClipW <= 1.0) break;
            if (fabs(doc.frame.size.width - curClipW) <= 0.5 &&
                fabs(doc.bounds.size.width - curClipW) <= 0.5) {
                break;
            }
            [clip setNeedsLayout:YES];
            [doc setNeedsLayout:YES];
            [super layout];
        }
        _rlpSyncingWidth = NO;
    }
    [self clampVerticalScrollIfNeeded];
}

@end

@implementation RLPSettingsViewController

- (instancetype)init {
    self = [super initWithTitle:RLPTr(@"设置")];
    if (self) {
        _paneCache = [NSMutableDictionary dictionary];
        _loadedKeys = [NSMutableSet set];
        _pendingPaneDrafts = [NSMutableDictionary dictionary];
        _activePaneConstraints = [NSMutableArray array];
        _dirtyControlIds = [NSMutableSet set];
        _lastLoadedValues = [NSMutableDictionary dictionary];
        // 默认页签 = 「通用」，与 web 一致（2026-10-29 用户要求「通用」排第一并默认选中）。
        _tab = RLPSTabAdv;
        _uiMode = @"listen";
        _activeGroup = 0;
        _metaResponsiveTwoColMode = -1;
        _metaResponsiveModelMode = -1;
        _metaResponsiveAiBtnMode = -1;
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

    self.lastAppliedLang = RLPLanguage();
    // U16：工作台应用命名配置档后，设置页的读数必须跟着重读（同一进程内的另一份视图）。
    // 走既有通知机制，不让两个页面互相持有；observer 在 dealloc 统一移除（见上）。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onExternalSettingsChanged:)
                                                 name:RLPSettingsChangedNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onLanguageChanged:)
                                                 name:RLPLanguageDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onControlTextDidChange:)
                                                 name:NSControlTextDidChangeNotification
                                               object:nil];

    self.groupTabs = [NSSegmentedControl segmentedControlWithLabels:@[RLPTr(@"通用"), RLPTr(@"音频处理")]
                                                       trackingMode:NSSegmentSwitchTrackingSelectOne
                                                             target:self
                                                             action:@selector(onGroupChanged:)];
    self.groupTabs.identifier = @"settings.groups";
    self.groupTabs.selectedSegment = self.activeGroup;
    self.groupTabs.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.groupTabs];

    self.modeHintLabel = RLPLabel(RLPTr(@"音频处理主控位于专业模式「数字音乐台」，此处保留完整参数与深链入口"),
                                  t.small, t.mut);
    self.modeHintLabel.identifier = @"settings.modeHint";
    self.modeHintLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.modeHintLabel.maximumNumberOfLines = 1;
    self.modeHintLabel.toolTip = self.modeHintLabel.stringValue;
    self.modeHintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.modeHintLabel];

    self.workbenchBtn = [NSButton buttonWithTitle:RLPTr(@"打开专业工作台")
                                           target:self
                                           action:@selector(onOpenProWorkbench:)];
    self.workbenchBtn.bezelStyle = NSBezelStyleRounded;
    self.workbenchBtn.controlSize = NSControlSizeSmall;
    self.workbenchBtn.identifier = @"settings.openWorkbench";
    self.workbenchBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.workbenchBtn];

    self.tabs = [[NSSegmentedControl alloc] initWithFrame:NSZeroRect];
    self.tabs.identifier = @"settings.tabs";
    self.tabs.trackingMode = NSSegmentSwitchTrackingSelectOne;
    self.tabs.target = self;
    self.tabs.action = @selector(onTabChanged:);
    self.tabs.translatesAutoresizingMaskIntoConstraints = NO;
    [self.tabs setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                        forOrientation:NSLayoutConstraintOrientationHorizontal];
    [host addSubview:self.tabs];
    [self rebuildTabs];
    [self syncModeHintVisibility];

    self.paneHost = [[NSView alloc] initWithFrame:NSZeroRect];
    self.paneHost.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.paneHost];

    self.statusLine = RLPLabel(@"", t.small, t.mut);
    self.statusLine.lineBreakMode = NSLineBreakByTruncatingTail;
    self.statusLine.maximumNumberOfLines = 1;
    self.statusLine.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.statusLine];

    // fittingSize 按 NSLayoutPriorityFittingSizeCompression(50) 压缩；必须低于 50，
    // 否则隐藏的 modeHintLabel 也会把页根 fittingSize 顶到 755~945pt（超出 900 主窗可用宽 674）。
    [self.modeHintLabel setContentCompressionResistancePriority:1.0f
                                                 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.statusLine setContentCompressionResistancePriority:1.0f
                                              forOrientation:NSLayoutConstraintOrientationHorizontal];

    [NSLayoutConstraint activateConstraints:@[
        [self.groupTabs.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:24],
        [self.groupTabs.topAnchor constraintEqualToAnchor:host.topAnchor constant:10],
        [self.workbenchBtn.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-24],
        [self.workbenchBtn.centerYAnchor constraintEqualToAnchor:self.groupTabs.centerYAnchor],
        [self.modeHintLabel.leadingAnchor constraintEqualToAnchor:self.groupTabs.trailingAnchor constant:12],
        [self.modeHintLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.workbenchBtn.leadingAnchor constant:-10],
        [self.modeHintLabel.centerYAnchor constraintEqualToAnchor:self.groupTabs.centerYAnchor],
        [self.tabs.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:24],
        [self.tabs.trailingAnchor constraintLessThanOrEqualToAnchor:host.trailingAnchor constant:-24],
        [self.tabs.topAnchor constraintEqualToAnchor:self.groupTabs.bottomAnchor constant:8],
        [self.paneHost.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [self.paneHost.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [self.paneHost.topAnchor constraintEqualToAnchor:self.tabs.bottomAnchor constant:10],
        [self.paneHost.bottomAnchor constraintEqualToAnchor:self.statusLine.topAnchor constant:-6],
        [self.statusLine.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:24],
        [self.statusLine.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-24],
        // 底栏是**悬浮**的（Apple Music 式），页面容器一直延伸到窗口底部。
        // 状态行原先只离底 10pt ⟹ 整行被 66pt 高的播放条压住，只露出半截字
        // （离屏截图实测）。这里让出播放条高度 66 + 上下留白 14+10。
        [self.statusLine.bottomAnchor constraintEqualToAnchor:host.bottomAnchor constant:-90],
    ]];

    [self showTab:self.tab];
}

- (void)applyUiMode:(NSString *)mode {
    self.uiMode = [mode isEqualToString:@"pro"] ? @"pro" : @"listen";
    [self syncModeHintVisibility];
}

- (void)syncModeHintVisibility {
    if (!self.modeHintLabel) return;
    self.modeHintLabel.hidden = (self.activeGroup != 1);
}

- (void)onOpenProWorkbench:(id)sender {
    (void)sender;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPSwitchToProWorkbenchNotification"
                                                        object:nil];
}

- (void)onGroupChanged:(id)sender {
    (void)sender;
    self.activeGroup = self.groupTabs.selectedSegment;
    [self syncModeHintVisibility];
    NSArray<NSString *> *keys = RLPSettingsVisibleKeysForGroup(self.activeGroup);
    if (keys.count) {
        self.tab = RLPSTabForKey(keys[0]);
    }
    [self rebuildTabs];
    [self showTab:self.tab];
}

/// 按当前分类（通用 / 音频处理）重建二级页签分段控件，并保持当前页选中。
- (void)rebuildTabs {
    NSArray<NSString *> *keys = RLPSettingsVisibleKeysForGroup(self.activeGroup);
    self.tabs.segmentCount = (NSInteger)keys.count;
    for (NSInteger i = 0; i < (NSInteger)keys.count; ++i)
        [self.tabs setLabel:RLPTr(RLPSettingsTabLabel(keys[i])) forSegment:i];
    NSUInteger idx = [keys indexOfObject:RLPSettingsKeyForTab(self.tab)];
    self.tabs.selectedSegment = (idx == NSNotFound) ? 0 : (NSInteger)idx;
}

- (void)onTabChanged:(id)sender {
    NSArray<NSString *> *keys = RLPSettingsVisibleKeysForGroup(self.activeGroup);
    NSInteger sel = self.tabs.selectedSegment;
    if (sel < 0 || sel >= (NSInteger)keys.count) return;
    [self showTab:RLPSTabForKey(keys[sel])];
}

- (void)selectPane:(NSString *)key {
    // 页签 key 与 web 的 data-g 完全同名，「通用」= adv。旧调用点发 "play" 时落到「通用」，
    // 因为 web 没有独立的「播放」页（音量/响度在「通用」页，预衰减在 PCM 页）。
    NSString *k = key;
    NSArray<NSString *> *allKeys = RLPSettingsTabKeys();
    if ([k isEqualToString:@"play"]) k = @"adv";
    if (![allKeys containsObject:k]) return;
    self.activeGroup = RLPSettingsGroupForKey(k);
    self.groupTabs.selectedSegment = self.activeGroup;
    [self syncModeHintVisibility];
    self.tab = RLPSTabForKey(k);
    [self rebuildTabs];
    [self showTab:self.tab];
}

- (NSString *)currentPaneKey {
    return RLPSettingsKeyForTab(self.tab);
}

static void RLPSettingsCollectViews(NSView *v, NSMutableArray<NSView *> *out) {
    if (!v) return;
    [out addObject:v];
    for (NSView *s in v.subviews) RLPSettingsCollectViews(s, out);
}

- (BOOL)isEqOwnedView:(NSView *)v {
    if (!v || !self.eqView) return NO;
    if ([v isDescendantOf:self.eqView]) return YES;
    if (self.eqView.opraSectionView && [v isDescendantOf:self.eqView.opraSectionView]) return YES;
    return NO;
}

- (BOOL)isControlDirty:(NSView *)v {
    if (!v) return NO;
    if ([v isKindOfClass:[NSTextField class]] && RLPTextFieldIsEditing((NSTextField *)v)) return YES;
    if (v.identifier.length && [self.dirtyControlIds containsObject:v.identifier]) return YES;
    return NO;
}

- (void)onControlTextDidChange:(NSNotification *)note {
    NSView *v = [note.object isKindOfClass:[NSView class]] ? (NSView *)note.object : nil;
    if (!v || !v.identifier.length) return;
    if (![v isDescendantOf:self.paneHost]) return;
    if ([self isEqOwnedView:v]) return;
    [self.dirtyControlIds addObject:v.identifier];
}

- (void)restorePendingDraftsForTab:(RLPSTab)tab inPane:(NSView *)pane {
    NSMutableDictionary<NSString *, NSString *> *drafts = self.pendingPaneDrafts[@(tab)];
    if (!drafts.count || !pane) {
        [self.pendingPaneDrafts removeObjectForKey:@(tab)];
        return;
    }
    NSMutableArray<NSView *> *views = [NSMutableArray array];
    RLPSettingsCollectViews(pane, views);
    for (NSView *v in views) {
        if (!v.identifier.length || [self isEqOwnedView:v]) continue;
        NSString *draft = drafts[v.identifier];
        if (!draft) continue;
        // 只有**真正的未提交草稿**（dirtyControlIds 里那条）能无条件覆盖控件；
        // 非草稿的"回声"（snapshot 为了重建后回填而记下的旧值）只在控件还是空的时候回填。
        // 为什么：页签对象缓存在 paneCache 里，离开期间一次 /api/settings 读回可能已经把它刷新成
        // 更新的真值 —— 拿回声盖回去就是新的"显示旧值"。新建页签时字段是空的，回声照常回填。
        const BOOL pending = [self.dirtyControlIds containsObject:v.identifier];
        if ([v isKindOfClass:[NSTextField class]] && ((NSTextField *)v).isEditable) {
            NSTextField *tf = (NSTextField *)v;
            NSString *cur = tf.stringValue ?: @"";
            if (!pending && cur.length > 0) continue;   // 控件里已有值，且这不是待提交草稿
            if ([cur isEqualToString:draft]) continue;  // 值相同：不用写
            tf.stringValue = draft;
            // dirty 不在这里加：snapshotPendingPaneDraftsForTab 已经把真正的未提交草稿记进
            // dirtyControlIds 了（test_native_settings_draft_contract 3a / 3b 靠的就是它）。
        } else if ([v isKindOfClass:[NSTextView class]] && ((NSTextView *)v).isEditable) {
            NSTextView *tv = (NSTextView *)v;
            NSString *cur = tv.string ?: @"";
            if (!pending && cur.length > 0) continue;
            if ([cur isEqualToString:draft]) continue;
            tv.string = draft;
            if (v == self.fbText) [self updateFbCount];
        }
    }
    [self.pendingPaneDrafts removeObjectForKey:@(tab)];
}

- (void)showTab:(RLPSTab)tab {
    // ① 换页之前先把**即将离开视图树**的那一页里的未提交文本落到 pendingPaneDrafts。
    //    为什么必须在这里做：正在编辑的 NSTextField 的文本还在 field editor 里（没落到
    //    stringValue），摘掉它的父视图时编辑状态被弃掉 ⟹ 文字丢失；而 NSControlTextDidChange
    //    早把这个 identifier 记进 dirtyControlIds，后续读回永远跳过它 ⟹ 用户看到退回旧值、
    //    屏幕上却再也不会被后端真值纠正（"切页签草稿丢失"）。
    //    旧实现只在切语言 / 切主题时快照，普通点页签没有 —— 那就是漏口。
    //
    // ⓪ EQ 子界面被 isEqOwnedView 排除在普通快照之外，必须在这里先把自己的状态收下来。
    //    触发条件：即将离开视图树的那一页里含 eqView（即当前停在 EQ 页）。
    //    为什么不能按 paneCache 判：切语言 / 切主题时 paneCache 已先被清空，只剩视图树可判。
    NSView *outgoingPane = self.paneHost.subviews.firstObject;
    const BOOL outgoingShowsEq =
        (self.shownTab == RLPSTabEq) ||
        (outgoingPane != nil && [self.eqView isDescendantOf:outgoingPane]);
    if (self.eqView && outgoingShowsEq) {
        self.eqDraftState = [self.eqView rlp_captureDraftState];
    }
    [self snapshotDraftsOfOutgoingPaneIfNeededForTab:tab];
    self.tab = tab;
    NSView *pane = self.paneCache[@(tab)];
    BOOL freshlyBuilt = NO;
    const BOOL hadEqViewBefore = (self.eqView != nil);
    if (!pane) {
        pane = [self buildPane:tab];
        if (!pane) return;
        self.paneCache[@(tab)] = pane;
        freshlyBuilt = YES;
    }
    // 页签根视图 identifier = "tab.<web data-g>"：parity 表靠它机械核对
    // 「web 的每个设置页签在原生都存在」，不靠人记。
    pane.identifier = RLP_PaneIdentifier(tab);
    // 换页签必须**原子**：旧实现是「先把 paneHost 的子视图全摘掉，再挂新页签」，
    // 中间存在一个「paneHost 空着、新页签 frame 还是 (0,0,0,0)」的瞬间；
    // 只要这一瞬间被合成器抓到一次，用户看到的就是整块空白，等下一次 layout 才出内容。
    // 现在：先摘旧页签的边贴边约束（视图**仍留在树里**）→ 挂新页签并同步排版 →
    // 最后才把旧页签移出。全程没有任何一帧是空容器。
    if (self.activePaneConstraints.count) {
        [NSLayoutConstraint deactivateConstraints:self.activePaneConstraints];
        [self.activePaneConstraints removeAllObjects];
    }
    pane.translatesAutoresizingMaskIntoConstraints = NO;
    [self.paneHost addSubview:pane];
    NSArray<NSLayoutConstraint *> *fresh = @[
        [pane.leadingAnchor constraintEqualToAnchor:self.paneHost.leadingAnchor],
        [pane.trailingAnchor constraintEqualToAnchor:self.paneHost.trailingAnchor],
        [pane.topAnchor constraintEqualToAnchor:self.paneHost.topAnchor],
        [pane.bottomAnchor constraintEqualToAnchor:self.paneHost.bottomAnchor],
    ];
    [NSLayoutConstraint activateConstraints:fresh];
    [self.activePaneConstraints addObjectsFromArray:fresh];
    // 首帧顶对齐（2026-11-21 用户实测「先露空白、再跳回去」）：必须**同步**做完，
    // 不能留给主窗口 schedulePageInsetsSync 的下一轮 runloop。
    if ([pane isKindOfClass:[RLPSettingsScrollView class]]) {
        [(RLPSettingsScrollView *)pane pinToTopNow];
    } else {
        [self.paneHost layoutSubtreeIfNeeded];
    }
    for (NSView *v in [self.paneHost.subviews copy]) {
        if (v == pane) continue;
        [v removeFromSuperview];
    }
    // ② 草稿恢复**不再只限新建页签**（旧实现 if (freshlyBuilt)）：页签对象虽然还在缓存里，
    //    但它在被摘出视图树时同样可能丢掉 field editor 里的编辑中文本（stringValue 还是旧值）。
    //    恢复是幂等的（值相同就不写），每次显示都过一遍最稳。
    [self restorePendingDraftsForTab:tab inPane:pane];
    // ③ EQ 草稿灌回：同一条实例被重挂时恢复 field editor 文本；若宿主换了新实例，
    //    频段/预设/OPRA 选择以及 draftEpoch 代次也一起搬过去。必须在下面的 reload 之前：
    //    有未提交代次时 hasPendingDraft 会挡住读回，restore 之前发出的旧 GET 也会因
    //    sentDraftEpoch / reqSeq 不再相等而在 isLatest 处被丢弃。
    if (tab == RLPSTabEq && self.eqDraftState && self.eqView) {
        [self.eqView rlp_restoreDraftState:self.eqDraftState];
        self.eqDraftState = nil;
    }
    // 新建的页签控件还是 UI 默认值（设备/滤波下拉是空的、开关是默认态）。
    // activate 只在进页时跑一次，之后才点开的页签必须在这里补一次读回，
    // 否则输出/PCM/SDM 页会显示空下拉与默认值，而不是用户真实设置。
    // 切到未建非 EQ 页签（或首次建 EQ 已由 fillEqualizer 发起加载）时不再无条件 reload eqView。
    if (freshlyBuilt && [RLPCoreClient shared].started) {
        const BOOL shouldReloadEq = (tab == RLPSTabEq && hadEqViewBefore);
        [self reloadDataIncludingEqualizer:shouldReloadEq];
    }
    // 诊断页每次进入补一次通道探活（web bindFeedbackCard 同语义；30s 内不重复，见 probeFeedbackChannel）。
    if (tab == RLPSTabDiag) [self probeFeedbackChannel];
    if (outgoingPane != nil && tab != self.shownTab) {
        NSString *tabKey = RLPSettingsKeyForTab(tab) ?: @"adv";
        RLPDiagEvent(@"nav", @"settings_tab_switch",
                     [NSString stringWithFormat:@"settings:%@", tabKey], nil, 0, -1, nil);
    }
    self.shownTab = tab;
    if (tab == RLPSTabStream) {
        if (self.srvGroup) [self.srvGroup contentDidChange];
        if (self.castGroup) [self.castGroup contentDidChange];
        [pane setNeedsLayout:YES];
        if (!freshlyBuilt && [RLPCoreClient shared].started && self.serversView) {
            [self.serversView reload];
        }
    }
    if (tab == RLPSTabMeta) {
        const BOOL laidOut = (self.paneHost && self.paneHost.bounds.size.width > 1.0);
        [self updateMetaResponsiveLayoutForHostWidth:[self metaTargetHostWidthPreferringViewBounds:laidOut]];
    }
    // 校准页的卡片高度必须**每次显示时**按当前内容重算：
    // fillCalibration 只在首次建 pane 时跑一次，之后重进校准页用的是缓存 pane，
    // 向导分支的增删（生成计划 / 取消测量）都会让「内容实际高度」变化，
    // 而高度约束停在旧值 ⟹ 卡内留大片空白（实测 130pt）。
    if (tab == RLPSTabCal) {
        [self syncCalHeight];
        [self.calView.superview setNeedsLayout:YES];
        [self.paneHost layoutSubtreeIfNeeded];
    }
    // 上面这些分支（流媒体 contentDidChange、元数据响应式重排）都会改文档高度；
    // 改完再钉一次顶部，保证这一帧画出来的内容从顶部开始。
    if ([pane isKindOfClass:[RLPSettingsScrollView class]]) {
        [(RLPSettingsScrollView *)pane pinToTopNow];
    }
}

- (void)viewWillLayout {
    [super viewWillLayout];
    if (self.shownTab == RLPSTabMeta || self.tab == RLPSTabMeta) {
        [self updateMetaResponsiveLayoutForHostWidth:[self metaTargetHostWidthPreferringViewBounds:YES]];
    }
}

- (void)viewDidLayout {
    [super viewDidLayout];
    if (self.shownTab == RLPSTabMeta || self.tab == RLPSTabMeta) {
        [self updateMetaResponsiveLayoutForHostWidth:[self metaTargetHostWidthPreferringViewBounds:YES]];
    }
}

/// 每个页签 = 一个纵向滚动的 NSStackView。
- (NSView *)buildPane:(RLPSTab)tab {
    RLPTheme *t = [RLPTheme current];
    RLPSettingsScrollView *scroll = [[RLPSettingsScrollView alloc] initWithFrame:NSZeroRect];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.autohidesScrollers = YES;

    // 文档视图用**翻转坐标**的实现（RLPSettingsPaneDocView）—— 见类注释里的根因。
    RLPSettingsPaneDocView *stack = [[RLPSettingsPaneDocView alloc] initWithFrame:NSZeroRect];
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
                                                @"diagchannelsbtn", @"diagchannels",
                                                @"updchannel", @"vercur", @"updcheck", @"updinstall",
                                                @"updmsg", @"updbar", @"updfill", @"updnote",
                                                @"fbtext", @"fbcount", @"fbchan", @"fbdiag",
                                                @"fbsend", @"fbretry", @"fbmsg", @"netmsg",
                                                @"opra_search", @"opra_searchhint", @"opra_msg",
                                                @"opra_copychip", @"footTpl", @"phasemsg", @"dsdmsg",
                                                @"dsdmodenote", @"inmsg", @"gpumsg", @"metasrc" ]];
    });
    if ([notSettingKeys containsObject:rest]) return @"";
    // 少数控件的后端键名与 web id 不同（/api/settings 是白名单键）：
    // web SET_KEYS（ui_script.h:976-978）把 #s2s 落成 twostage、#sLoud 落成 loudness。
    static NSDictionary<NSString *, NSString *> *renamed;
    static dispatch_once_t onceRenamed;
    // U5（v3.3.11）：sp_ratefamily 的后端 settings 键是驼峰 rateFamilyPolicy
    //（/api/settings 白名单同名；web id 与后端键名在这里不是同一个命名空间）。
    dispatch_once(&onceRenamed, ^{ renamed = @{ @"2s": @"twostage", @"loud": @"loudness",
                                                @"ratefamily": @"rateFamilyPolicy" }; });
    NSString *mapped = renamed[rest];
    return mapped ?: rest;
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
            @"sp_rate": @"sp_rate", @"sp_ratefamily": @"sp_ratefamily",
            @"sp_bits": @"sp_bits", @"sp_ch": @"sp_ch",
            @"sp_buffer": @"sp_buffer", @"sp_ramp": @"sp_ramp",
            @"sp_backendmsg": @"sp_backendmsg", @"sp_trimchmsg": @"sp_trimchmsg",
            @"sp_trim": @"sp_trim", @"sp_trimwrap": @"sp_trimwrap",
            @"sp_upnpwrap": @"sp_upnpwrap", @"sp_footTpl": @"sp_footTpl",
            @"sp_filt": @"sp_filt", @"sp_filtNx": @"sp_filtNx", @"sp_phase": @"sp_phase",
            @"sp_filtNx_note": @"sp_filtNx_note",   // U8：Nx 行下的族说明（原生新增，parity 扫描取证）
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
            @"sp_sdmcorner_note": @"sp_sdmcorner_note",   // U12：拐点准入提示（原生新增，parity 扫描取证）
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
            @"sp_diagchannelsbtn": @"sp_diagchannelsbtn",
            @"sp_diagchannels": @"sp_diagchannels",
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
    // 2026-11-17（UI 缺口审计已证实）：AppKit 默认 sendsActionOnEndEditing=NO，
    // 用户输完值直接切页签而不按回车时，修改被静默丢弃（原生没有 Web 的「保存设置」按钮）。
    [(NSTextFieldCell *)f.cell setSendsActionOnEndEditing:YES];
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
    [(NSTextFieldCell *)f.cell setSendsActionOnEndEditing:YES];   // 失焦即提交（见 numberFieldForKey 的说明）
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
    [self postKey:key value:value completion:nil];
}

- (NSView *)findCachedControlWithIdentifier:(NSString *)ident {
    if (!ident.length) return nil;
    for (NSNumber *k in self.paneCache) {
        NSMutableArray<NSView *> *views = [NSMutableArray array];
        RLPSettingsCollectViews(self.paneCache[k], views);
        for (NSView *v in views) {
            if ([v.identifier isEqualToString:ident]) return v;
        }
    }
    return nil;
}

- (void)clearDirtyControlId:(NSString *)ident expectedValue:(nullable NSString *)expectedValue {
    if (!ident.length) return;
    NSView *v = [self findCachedControlWithIdentifier:ident];
    if ([v isKindOfClass:[NSTextField class]]) {
        NSString *cur = ((NSTextField *)v).stringValue ?: @"";
        if (expectedValue && ![cur isEqualToString:expectedValue]) {
            NSString *trimmed = [cur stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (![trimmed isEqualToString:expectedValue]) return;
        }
    }
    [self.dirtyControlIds removeObject:ident];
    if (expectedValue) self.lastLoadedValues[ident] = expectedValue;
}

- (void)clearDirtyForBackendKey:(NSString *)key submittedValue:(NSString *)value {
    if (!key.length) return;
    for (NSString *ident in [self.dirtyControlIds copy]) {
        NSString *mapped = RLPBackendKeyForControl(ident);
        if ([mapped isEqualToString:key] ||
            ([key isEqualToString:@"scanthreads"] && [mapped isEqualToString:@"scanThreads"])) {
            [self clearDirtyControlId:ident expectedValue:value];
        }
    }
}

/// completion(ok)：保存结果落定后回调。ok == YES 的含义是**确认落盘**：
/// 后端答复 ok，且答复里的 kv（合并后的真实内容）确实含提交的键。
/// 被后端拒绝 / 没拿到答复 / 核心没起 一律 ok == NO —— 调用方据此回滚自己乐观改过的界面。
/// 例：SDM 拐点被 422 拒时后端 conf 没写，读回的仍是旧值 —— 提示必须跟着真实状态走，
/// 不能拿输入框的值猜。
- (NSMutableDictionary<NSString *, NSNumber *> *)settingsKeyPostAt {
    if (!_settingsKeyPostAt) _settingsKeyPostAt = [NSMutableDictionary dictionary];
    return _settingsKeyPostAt;
}

#pragma mark - 保存（提交 / 答复落地 / 回滚）

/// 控件当前值 → 与**提交值**同口径的字符串（回滚时用它判断"用户有没有在这期间又改过"）。
/// 下拉：优先 representedObject（值 ≠ 文案的下拉只认它），没有就退回标题；
/// 开关：与 onSwitch 提交的 "1"/"0" 同一口径。
static NSString *RLPSettingsControlValueString(NSView *v) {
    if ([v isKindOfClass:[NSTextField class]]) return ((NSTextField *)v).stringValue ?: @"";
    if ([v isKindOfClass:[NSSwitch class]])
        return (((NSSwitch *)v).state == NSControlStateValueOn) ? @"1" : @"0";
    if ([v isKindOfClass:[NSPopUpButton class]]) {
        NSPopUpButton *pop = (NSPopUpButton *)v;
        id ro = pop.selectedItem.representedObject;
        if ([ro isKindOfClass:[NSString class]]) return (NSString *)ro;
        return pop.titleOfSelectedItem ?: @"";
    }
    return nil;
}

/// 一个后端键在**缓存页签**里对应的全部控件（identifier → 后端键的映射与提交同源）。
/// 为什么扫缓存而不是当前页签：回包到达时用户可能已经切走，要回的控件在原来那一页里
/// （页签对象仍在 paneCache 里，控件没有消失）。
- (NSMutableArray<NSView *> *)cachedControlsForBackendKey:(NSString *)key {
    NSMutableArray<NSView *> *out = [NSMutableArray array];
    if (!key.length) return out;
    for (NSNumber *tabKey in [self.paneCache allKeys]) {
        NSMutableArray<NSView *> *views = [NSMutableArray array];
        RLPSettingsCollectViews(self.paneCache[tabKey], views);
        for (NSView *v in views) {
            if (!v.identifier.length) continue;
            NSString *mapped = RLPBackendKeyForControl(v.identifier);
            if ([mapped isEqualToString:key] ||
                ([key isEqualToString:@"scanthreads"] && [mapped isEqualToString:@"scanThreads"])) {
                [out addObject:v];
            }
        }
    }
    return out;
}

/// 保存**没落盘**之后把控件退回「最近一次从后端读回的真值」。三条纪律：
///   ① 只回滚**当前值仍等于本次提交值**的控件 —— 回包前用户又改过的草稿保留原样，绝不回滚新输入；
///   ② 没有已知真值（lastLoadedValues 里没有）就不猜：留在原位，由状态行如实说明保存失败；
///   ③ 回滚完解除 dirty：屏幕上已是真值，再挡着读回只会让页面一直显示旧快照。
- (void)revertControlsForBackendKey:(NSString *)key submittedValue:(NSString *)value {
    if (!key.length) return;
    NSString *submitted = value ?: @"";
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *submittedTrimmed = [submitted stringByTrimmingCharactersInSet:ws];
    for (NSView *v in [self cachedControlsForBackendKey:key]) {
        NSString *cur = RLPSettingsControlValueString(v);
        if (!cur) continue;
        if (![cur isEqualToString:submitted] &&
            ![[cur stringByTrimmingCharactersInSet:ws] isEqualToString:submittedTrimmed]) continue;
        NSString *previous = self.lastLoadedValues[v.identifier];
        if (!previous) continue;
        if ([v isKindOfClass:[NSTextField class]]) {
            ((NSTextField *)v).stringValue = previous;
        } else if ([v isKindOfClass:[NSSwitch class]]) {
            ((NSSwitch *)v).state = previous.boolValue ? NSControlStateValueOn : NSControlStateValueOff;
        } else if ([v isKindOfClass:[NSPopUpButton class]]) {
            // 复用读回的回填口径（空串 = 「跟随」首项；值 ≠ 文案按 representedObject 匹配）。
            [self applyKV:@{ key : previous } toPopup:(NSPopUpButton *)v key:key];
        } else {
            continue;
        }
        [self.dirtyControlIds removeObject:v.identifier];
        self.lastLoadedValues[v.identifier] = previous;
    }
}

/// 保存成功：按「提交值 == 控件当前值」精确解除 dirty。
/// 为什么必须精确比对：同一个键可能已经又被改过一次（回包乱序），那张新草稿不能被旧成功抹掉
///（判据 test_native_settings_save_contract 的 1b / 2a）。
- (void)applySettingsSaveSuccess:(NSDictionary<NSString *, NSString *> *)submitted seq:(NSUInteger)seq {
    for (NSString *k in submitted) {
        [self clearDirtyForBackendKey:k submittedValue:submitted[k] ?: @""];
    }
    if (seq != self.settingsPostSeq) return;   // 只有**最新**一次提交能改状态行与发通知
    if (submitted.count == 1) {
        NSString *k = submitted.allKeys.firstObject;
        self.statusLine.stringValue = [NSString stringWithFormat:@"%@ %@ = %@",
                                       RLPTr(@"已保存"), k, submitted[k] ?: @""];
    } else {
        self.statusLine.stringValue = RLPTr(@"已保存");
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:RLPSettingsChangedNotification
                                                        object:self];
}

/// 保存失败（后端明确拒绝 / 根本没发出去）：先把 reverted 里的键回滚，再如实说明。
/// reverted 传**空字典** = 「没拿到可判定的答复」：不回滚，也不撤销该键的提交时间戳 ——
/// 结果未知时回滚等于把当前值换成猜的旧值，宁可留在原位并说清"服务没响应"。
- (void)applySettingsSaveFailure:(NSDictionary<NSString *, NSString *> *)reverted text:(NSString *)text {
    for (NSString *k in reverted) {
        [self revertControlsForBackendKey:k submittedValue:reverted[k] ?: @""];
        // 没落盘的键不能继续挂着「已提交」时间戳：挂着会让下一次读回按 per-key 过滤跳过它，
        // 屏幕上就一直是那个"以为存了、其实没存"的值（假成功的另一半成因）。
        [self.settingsKeyPostAt removeObjectForKey:k];
    }
    NSString *msg = text ?: @"";
    self.statusLine.stringValue = msg;
    RLPToast(msg);
    std::fprintf(stderr, "[DIAG] SETTINGS_SAVE_FAIL revert=%lu text=%s\n",
                 (unsigned long)reverted.count, [msg UTF8String]);
}

- (void)postKey:(NSString *)key value:(NSString *)value
      completion:(void (^_Nullable)(BOOL ok))completion {
    if (!key.length) return;
    [self postKeys:@{ key : value ?: @"" } completion:completion];
}

/// 一次提交多个键（后端合并写）。用于「bit-perfect 直通」与 DSD+dsdnative 等一组键同时改的场景。
- (void)postKeys:(NSDictionary<NSString *, NSString *> *)kv {
    [self postKeys:kv completion:nil];
}

- (void)postKeys:(NSDictionary<NSString *, NSString *> *)kv
      completion:(void (^_Nullable)(BOOL ok))completion {
    if (!kv.count) return;
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:kv.count];
    const NSTimeInterval postAt = [NSProcessInfo processInfo].systemUptime;
    for (NSString *k in kv) {
        [self.loadedKeys addObject:k];
        self.settingsKeyPostAt[k] = @(postAt);
        [parts addObject:[NSString stringWithFormat:@"%@=%@", k, RLPEnc(kv[k] ?: @"")]];
    }
    const NSUInteger seq = ++self.settingsPostSeq;
    std::fprintf(stderr, "[DIAG] POST %s seq=%lu\n",
                 [[kv.allKeys componentsJoinedByString:@","] UTF8String], (unsigned long)seq);

    // 一次提交只落一次地：答复 / 超时 / 根本没发出去，三者取先到的那一个。
    // 为什么必须有这条闸门：RLPCoreClient 在关闸（退出中 / 生成号变化）时会**直接丢掉回调**
    //（RLPCoreClient.mm 的 runAsync 提前 return），旧实现的 completion 因此永不回调、
    // 状态行永远停在上一次 —— 保存失败被吞成"什么也没发生"（用户以为已保存）。
    __block BOOL settled = NO;
    __weak __typeof__(self) weakSelf = self;
    void (^settle)(NSDictionary * _Nullable, BOOL, BOOL) =
        ^(NSDictionary * _Nullable json, BOOL timedOut, BOOL notSent) {
        if (settled) return;
        settled = YES;
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (notSent) {
            const double durMs = ([NSProcessInfo processInfo].systemUptime - postAt) * 1000.0;
            RLPDiagEvent(@"error", @"api_fail",
                         [NSString stringWithFormat:@"settings:%@", [self_ currentPaneKey] ?: @"adv"],
                         @"/api/settings", 503, durMs, @"core_not_started");
            [self_ applySettingsSaveFailure:kv
                                       text:[NSString stringWithFormat:@"%@%@",
                                             RLPTr(@"保存失败："), RLPTr(@"核心未启动")]];
            if (completion) completion(NO);
            return;
        }
        if (timedOut || !json) {
            const double durMs = ([NSProcessInfo processInfo].systemUptime - postAt) * 1000.0;
            RLPDiagEvent(@"error", @"api_fail",
                         [NSString stringWithFormat:@"settings:%@", [self_ currentPaneKey] ?: @"adv"],
                         @"/api/settings", timedOut ? 504 : 500, durMs,
                         timedOut ? @"timeout" : @"empty_response");
            [self_ applySettingsSaveFailure:@{} text:RLPTr(@"保存失败：服务没响应")];
            if (completion) completion(NO);
            return;
        }
        if (![json[@"ok"] boolValue]) {
            const double durMs = ([NSProcessInfo processInfo].systemUptime - postAt) * 1000.0;
            RLPDiagEvent(@"error", @"api_fail",
                         [NSString stringWithFormat:@"settings:%@", [self_ currentPaneKey] ?: @"adv"],
                         @"/api/settings", 400, durMs, @"rejected");
            NSString *err = ([json[@"error"] isKindOfClass:[NSString class]] && [json[@"error"] length])
                          ? json[@"error"] : RLPTr(@"保存失败");
            // 后端明确拒绝：控件会被退回最近一次读回的真值 ⟹ 文案要说明"原值还在"，
            // 否则用户看到输入框自己跳回去会以为界面出了错。
            [self_ applySettingsSaveFailure:kv
                                       text:[NSString stringWithFormat:@"%@：%@",
                                             RLPTr(@"保存失败，已保留原值"), err]];
            if (completion) completion(NO);
            return;
        }
        // ok:true 也不等于「写进去了」：/api/settings 是**白名单合并写**，名单外的键被 continue
        // 静默丢弃，答复仍是 {"ok":true,"merged":true}（tools/rtaweb.cpp:13935；同类事故见
        // 13899-13903 的 hogexcl 白名单漏键）。答复里的 kv 是**合并后真实落盘的内容** ⟹
        // 提交的键不在 kv 里就是没写进去，绝不能报「已保存」。
        NSDictionary *stored = [json[@"kv"] isKindOfClass:[NSDictionary class]] ? json[@"kv"] : nil;
        if (!stored) {   // 答复不带 kv（不是本端点的形状）：按成功处理，不臆断
            [self_ applySettingsSaveSuccess:kv seq:seq];
            if (completion) completion(YES);
            return;
        }
        NSMutableDictionary<NSString *, NSString *> *accepted = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSString *> *dropped = [NSMutableDictionary dictionary];
        for (NSString *k in kv) {
            if ([stored objectForKey:k] != nil) accepted[k] = kv[k];
            else dropped[k] = kv[k];
        }
        if (accepted.count) [self_ applySettingsSaveSuccess:accepted seq:seq];
        if (dropped.count) {
            const double durMs = ([NSProcessInfo processInfo].systemUptime - postAt) * 1000.0;
            RLPDiagEvent(@"error", @"api_fail",
                         [NSString stringWithFormat:@"settings:%@", [self_ currentPaneKey] ?: @"adv"],
                         @"/api/settings", 422, durMs, @"dropped_keys");
            // 只说"这些键没写进去"：不承诺"已保留原值"（这几个控件可能根本没有已知旧值可退）。
            [self_ applySettingsSaveFailure:dropped
                                       text:[NSString stringWithFormat:@"%@%@",
                                             RLPTr(@"保存失败："),
                                             [dropped.allKeys componentsJoinedByString:@"、"]]];
            if (completion) completion(NO);
        } else if (completion) {
            completion(YES);
        }
    };

    if (![[RLPCoreClient shared] started]) {   // 核心没起：postJSON 不回调，别装成已保存
        settle(nil, NO, YES);
        return;
    }
    [[RLPCoreClient shared] postJSON:@"/api/settings"
                                body:[parts componentsJoinedByString:@"&"]
                          completion:^(NSDictionary * _Nullable json) {
        settle(json, NO, NO);
    }];
    // 兜底超时：网络层卡住 / 关闸丢回调时也要给用户一句结论（15s，与其它页同一量级）。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ settle(nil, YES, NO); });
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
    if (self.fbGroup) [self.fbGroup contentDidChange];
}

/// 发送结果行（web fbMsg）+ 持久结果区（web `rlFbResult` / `sp_fbresult`）。
/// 为什么两者都写：状态行会被下一次操作覆盖，用户回头想「刚才到底成没成」就没了；
/// 结果区留在页面上，直到下一次发送才更新。
- (void)fbResultText:(NSString *)text kind:(NSInteger)kind {
    RLPTheme *t = [RLPTheme current];
    if (self.fbMsg) {
        self.fbMsg.stringValue = text ?: @"";
        self.fbMsg.textColor = (kind == 2) ? t.danger : (kind == 1) ? t.okText : t.mut2;
    }
    if (self.fbResultBox) {
        self.fbResultBox.stringValue = text ?: @"";
        self.fbResultBox.textColor = (kind == 2) ? t.danger : (kind == 1) ? t.okText : t.mut2;
        self.fbResultBox.hidden = (text.length == 0);   // web 空结果不占位
    }
    if (self.fbGroup) [self.fbGroup contentDidChange];
}

#pragma mark - v3.3.11 反馈预览（rlFbPreview：先看会发送什么）

/// 预览文案**从真实请求参数派生**，不另写一份口径 —— 否则「预览说发了 A、实际发了 B」，
/// 比没有预览更糟。字段/端点/上限全部取 src/net/feedback_api.h 里的常量。
- (NSString *)fbPreviewSummary {
    NSString *text = self.fbText.string ?: @"";
    NSString *trimmed = [text stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    const NSUInteger bytes = [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    const BOOL attach = self.fbDiagSwitch.state == NSControlStateValueOn;
    NSProcessInfo *pi = [NSProcessInfo processInfo];
    NSString *osVer = self.fbSystemVersionOverride.length
        ? self.fbSystemVersionOverride
        : (pi.operatingSystemVersionString ?: @"");
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:RLPTr(@"将提交到：%@"),
                      [NSString stringWithUTF8String:rta::feedback::kFeedbackUploadUrl]]];
    [lines addObject:[NSString stringWithFormat:RLPTr(@"版本：%@"),
                      [NSString stringWithUTF8String:RLPLAYER_VERSION]]];
    [lines addObject:[NSString stringWithFormat:RLPTr(@"系统：macOS %@"),
                      osVer]];
    [lines addObject:[NSString stringWithFormat:RLPTr(@"正文：%@ 字 / %lu 字节（上限 16384 字节）"),
                      @(trimmed.length), (unsigned long)bytes]];
    [lines addObject:attach ? RLPTr(@"诊断包：附带（已脱敏，与「导出诊断包」同一份）")
                            : RLPTr(@"诊断包：不附带")];
    return [lines componentsJoinedByString:@"\n"];
}

- (void)onFbPreview:(id)sender {
    (void)sender;
    if (!self.fbPreviewBox) return;
    self.fbPreviewBox.stringValue = [self fbPreviewSummary];
    self.fbPreviewBox.hidden = NO;
    if (self.fbGroup) [self.fbGroup contentDidChange];
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
    const NSTimeInterval t0 = [NSProcessInfo processInfo].systemUptime;
    RLPDiagEvent(@"action", @"diag_channels_check", @"settings:diag", nil, 0, -1, @"start");

    __weak __typeof__(self) weakSelf = self;
    __block BOOL settled = NO;
    void (^done)(NSInteger, NSData *, BOOL) = ^(NSInteger status, NSData *body, BOOL timedOut) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __typeof__(self) self_ = weakSelf;
            if (!self_ || settled) return;
            settled = YES;
            const double durMs = ([NSProcessInfo processInfo].systemUptime - t0) * 1000.0;
            if (self_.fbProbeDeadline) { [self_.fbProbeDeadline invalidate]; self_.fbProbeDeadline = nil; }
            self_.fbChannelChecking = NO;
            self_.fbLastChannelCheck = [NSDate date];
            std::string raw;
            if (body.length) raw.assign((const char *)body.bytes, (size_t)body.length);
            const auto wd = rta::feedback::parse_feedback_watchdog((int)status, raw);
            if (wd.reachable) {
                self_.fbServerOK = 1;
                RLPDiagEvent(@"action", @"diag_channels_check", @"settings:diag", nil,
                             status > 0 ? status : 200, durMs, @"ok");
                NSString *line = RLPTr(@"反馈通道已连接");
                if (wd.rate_per_minute > 0) {
                    line = [NSString stringWithFormat:@"%@%@%ld%@", line, RLPTr(@"（每分钟最多 "),
                            (long)wd.rate_per_minute, RLPTr(@" 次）")];
                }
                [self_ fbChannelText:line kind:1];
            } else {
                self_.fbServerOK = 0;
                RLPDiagEvent(@"error", @"diag_channels_check", @"settings:diag", nil,
                             status > 0 ? status : (timedOut ? 504 : 503), durMs,
                             timedOut ? @"timeout" : @"unreachable");
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
            RLPDiagEvent(@"error", @"diag_channels_check", @"settings:diag", nil, 504, 12000.0, @"timeout");
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
    const BOOL laidOut = (self.paneHost && self.paneHost.bounds.size.width > 1.0);
    [self updateMetaResponsiveLayoutForHostWidth:[self metaTargetHostWidthPreferringViewBounds:laidOut]];
    if (self.metaAdvancedVisible) {
        [self.metaDataGroup contentDidChange];
        [self.metaAiGroup contentDidChange];
        [self.metaSearchGroup contentDidChange];
    }
    [self.metaAdvancedStack setNeedsLayout:YES];
    [self.metaHostStack setNeedsLayout:YES];
}

- (void)applyKV:(NSDictionary *)kv toSwitch:(NSSwitch *)sw key:(NSString *)key {
    if (!sw) return;
    id v = kv[key];
    if (![v respondsToSelector:@selector(boolValue)]) return;
    const BOOL on = [v boolValue];
    sw.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    // 记下"最近一次从后端读回的真值"：保存失败时控件要按它回滚（见 revertControlsForBackendKey）。
    if (sw.identifier.length) self.lastLoadedValues[sw.identifier] = on ? @"1" : @"0";
    [self.loadedKeys addObject:key];
}

- (void)applyKV:(NSDictionary *)kv toTextField:(NSTextField *)tf key:(NSString *)key {
    if (!tf) return;
    if ([self isControlDirty:tf]) return;
    id v = kv[key];
    NSString *s = nil;
    if ([v isKindOfClass:[NSString class]]) {
        s = v;
    } else if ([v respondsToSelector:@selector(stringValue)]) {
        s = [v stringValue];
    }
    if (s) {
        tf.stringValue = s;
        if (tf.identifier.length) self.lastLoadedValues[tf.identifier] = s;
        [self.loadedKeys addObject:key];
    }
}

- (void)applyKV:(NSDictionary *)kv toPopup:(NSPopUpButton *)pop key:(NSString *)key {
    if (!pop) return;
    id v = kv[key];
    if (![v isKindOfClass:[NSString class]]) return;
    NSString *s = v;
    if (!s.length) {
        // 空串是合法值（filterNx / phase 的「跟随」首项）：选中值为空串的项，没有就回退首项。
        BOOL matchedEmpty = NO;
        for (NSMenuItem *it in pop.itemArray) {
            if ([it.representedObject isKindOfClass:[NSString class]] &&
                [(NSString *)it.representedObject isEqualToString:@""]) {
                [pop selectItemAtIndex:[pop indexOfItem:it]];
                matchedEmpty = YES;
                break;
            }
        }
        if (!matchedEmpty && pop.numberOfItems > 0) [pop selectItemAtIndex:0];
        if (pop.identifier.length) self.lastLoadedValues[pop.identifier] = @"";
        [self.loadedKeys addObject:key];
        return;
    }
    // 值 ≠ 文案的下拉（采样率 / 位深）：先按 representedObject 精确匹配，再退回按标题匹配。
    BOOL matched = NO;
    for (NSMenuItem *it in pop.itemArray) {
        if ([it.representedObject isKindOfClass:[NSString class]] &&
            [(NSString *)it.representedObject isEqualToString:s]) {
            [pop selectItemAtIndex:[pop indexOfItem:it]];
            matched = YES;
            break;
        }
    }
    if (!matched && [pop itemWithTitle:s]) [pop selectItemWithTitle:s];
    // 同上：记下读回真值，保存失败时下拉能退回这一项（下拉本身没有被 dirty 机制保护）。
    if (pop.identifier.length) self.lastLoadedValues[pop.identifier] = s;
    [self.loadedKeys addObject:key];
}

/// 按落盘 id 回显设备。设备列表与 /api/settings 是两个并发来源，两边都要调用一次，
/// 否则先到的一方会被后到的一方按位置覆盖（旧实现根本没有按 id 的回显路径）。
- (void)selectSavedDevice {
    NSString *want = self.savedDeviceId;
    if (!want.length || !self.devicePopup) return;
    for (NSInteger i = 0; i < (NSInteger)self.devicePopup.numberOfItems; ++i) {
        id ro = [self.devicePopup itemAtIndex:i].representedObject;
        if ([ro isKindOfClass:[NSString class]] && [(NSString *)ro isEqualToString:want]) {
            [self.devicePopup selectItemAtIndex:i];
            return;
        }
    }
}

/// 反解 kv.dsd 回三个控件（支持纯数字 0/64/128/256/512/1024 及 legacy 前缀 dopNN/natNN/nativeNN）。
/// macOS 只提供 DoP，不提供 Native。
- (void)applyDsdPersistValue:(id)raw {
    const NSInteger rate = RLPParseDsdRate(raw);
    const BOOL isDsd = (rate > 0);
    NSString *mode = isDsd ? @"dsd" : @"pcm";
    if ([self.outModePopup itemWithTitle:mode]) [self.outModePopup selectItemWithTitle:mode];

    if ([self.dsdPackPopup itemWithTitle:@"dop"]) [self.dsdPackPopup selectItemWithTitle:@"dop"];

    NSString *tail = isDsd ? [NSString stringWithFormat:@"%ld", (long)rate] : @"256";
    if (![self.dsdRatePopup itemWithTitle:tail]) tail = @"256";
    if ([self.dsdRatePopup itemWithTitle:tail]) [self.dsdRatePopup selectItemWithTitle:tail];

    [self updateDsdModeNote];
}

- (void)selectSavedUpnpDevice {
    NSString *want = self.savedUpnpDev;
    if (!want.length || !self.upnpPop) return;
    for (NSInteger i = 0; i < (NSInteger)self.upnpPop.numberOfItems; ++i) {
        id ro = [self.upnpPop itemAtIndex:i].representedObject;
        if ([ro isKindOfClass:[NSString class]] && [(NSString *)ro isEqualToString:want]) {
            [self.upnpPop selectItemAtIndex:i];
            return;
        }
    }
}

- (void)applyUpnpDevicesPayload:(NSDictionary *)json {
    RLPSettingsViewController *self_ = self;
        NSArray *list = [json[@"devices"] isKindOfClass:[NSArray class]] ? json[@"devices"] : @[];
        self_.upnpDevices = list;
        if (self_.upnpPop) {
            [self_.upnpPop removeAllItems];
            NSMutableSet<NSString *> *seenIds = [NSMutableSet set];
            for (id it in list) {
                if (![it isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *d = (NSDictionary *)it;
                NSString *devId = [d[@"id"] isKindOfClass:NSString.class] ? d[@"id"] : @"";
                if (!devId.length || [seenIds containsObject:devId]) continue;
                NSString *name = [d[@"friendlyName"] isKindOfClass:[NSString class]] && [d[@"friendlyName"] length] ? d[@"friendlyName"]
                               : ([d[@"name"] isKindOfClass:[NSString class]] && [d[@"name"] length] ? d[@"name"]
                               : ([d[@"host"] isKindOfClass:[NSString class]] && [d[@"host"] length] ? d[@"host"] : devId));
                NSString *kind = [d[@"kind"] isKindOfClass:[NSString class]] ? d[@"kind"] : @"";
                NSString *label = kind.length ? [NSString stringWithFormat:@"[%@] %@", [kind isEqualToString:@"airplay"] ? @"AirPlay" : @"UPnP", name] : name;
                if ([self_.upnpPop itemWithTitle:label]) label = [label stringByAppendingFormat:@" · %@", devId];
                [self_.upnpPop addItemWithTitle:label];
                [[self_.upnpPop lastItem] setRepresentedObject:devId];
                [seenIds addObject:devId];
            }
            NSString *saved = self_.savedUpnpDev ?: @"";
            if (saved.length && ![seenIds containsObject:saved]) {
                [self_.upnpPop addItemWithTitle:[NSString stringWithFormat:@"%@%@", RLPTr(@"（上次选择 · 离线/需刷新）"), saved]];
                [[self_.upnpPop lastItem] setRepresentedObject:saved];
            }
            if (self_.upnpPop.numberOfItems == 0) {
                [self_.upnpPop addItemWithTitle:RLPTr(@"（未发现 UPnP 渲染器）")];
                [[self_.upnpPop lastItem] setRepresentedObject:@""];
            }
            [self_ selectSavedUpnpDevice];
        }
        if (self_.upnpMsg) {
            if (list.count) {
                self_.upnpMsg.stringValue = [NSString stringWithFormat:RLPTr(@"共发现 %lu 个渲染器"), (unsigned long)list.count];
            } else {
                NSString *hint = [json[@"hint"] isKindOfClass:[NSString class]] ? json[@"hint"] : @"";
                self_.upnpMsg.stringValue = hint.length ? hint : RLPTr(@"播放 / 切歌自动投放到该渲染器（与下方「投放」共用会话）");
            }
        }
}

- (void)loadUpnpDevicesForce:(BOOL)force {
    if (![RLPCoreClient shared].started) return;
    NSString *url = force ? @"/api/cast/devices?scan=1" : @"/api/cast/devices";
    if (force && self.upnpMsg) self.upnpMsg.stringValue = RLPTr(@"正在发现渲染器…");
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || ![json isKindOfClass:[NSDictionary class]]) return;
        [self_ applyUpnpDevicesPayload:json];
    }];
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
    [self.backendPopup setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                forOrientation:NSLayoutConstraintOrientationHorizontal];
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
        items:@[ RLPTr(@"（未发现 UPnP 渲染器）") ] action:@selector(onUpnpDevice:)];
    [[self.upnpPop itemAtIndex:0] setRepresentedObject:@""];
    [self.upnpPop setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                           forOrientation:NSLayoutConstraintOrientationHorizontal];
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
    // web #sp_device 首项 value=""（默认设备），设备项 value=稳定 id（ui_script.h:5318/5337）。
    // 旧实现整列只有显示名，选中后 POST 的也是显示名 —— 后端按 id 解析，名字匹配不可靠。
    [[self.devicePopup itemAtIndex:0] setRepresentedObject:@""];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"输出设备"), self.devicePopup,
        RLPTr(@"独占模式会接管这个设备；共享模式经系统混音，不接管"), t)];

    self.hogSwitch = [self switchForKey:@"sp_hogexcl" action:@selector(onSwitch:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"严格独占（抢 Hog Mode）"), self.hogSwitch,
        RLPTr(@"勾选后系统音量条失效，音量只能用本程序调；默认开启"), t)];

    self.outModePopup = [self popupForKey:@"sp_outmode" items:@[ @"pcm", @"dsd" ]
                                   action:@selector(onOutMode:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"输出模式"), self.outModePopup,
        RLPTr(@"DSD 的比特率与封装（DoP / Native）在 SDM 页设置"), t)];

    // web #sRate 的 option value 是 follow / max / src + Hz（ui_page.h:1547）。
    // 中文文案只用于显示，**值**放在 representedObject —— 旧实现把标题当值发给后端，
    // 于是 rate=自动、bits=跟随源（按文件位深）这种非法值被后端丢弃或写坏。
    self.ratePopup = [self popupForKey:@"sp_rate"
        items:@[ RLPTr(@"跟随系统"), RLPTr(@"自动（设备最高）"), RLPTr(@"源采样率"),
                 @"44100", @"48000", @"88200", @"96000", @"176400", @"192000",
                 @"352800", @"384000", @"705600", @"768000" ]
        action:@selector(onRate:)];
    {
        NSArray<NSString *> *vals = @[ @"follow", @"max", @"src",
            @"44100", @"48000", @"88200", @"96000", @"176400", @"192000",
            @"352800", @"384000", @"705600", @"768000" ];
        for (NSUInteger i = 0; i < vals.count && i < (NSUInteger)self.ratePopup.numberOfItems; ++i)
            [self.ratePopup itemAtIndex:(NSInteger)i].representedObject = vals[i];
    }
    [stack addArrangedSubview:RLPSRow(RLPTr(@"输出采样率"), self.ratePopup,
        RLPTr(@"自动 = 所选设备的最高采样率"), t)];

    // ---- U5（Windows v3.3.11 移植）：PCM 采样率族策略（紧跟采样率行）----
    // 值（representedObject）必须是后端白名单的 prefer / strict / compatible；
    // 显示文案只用中文，复用 RLPTr（英文由 docs/i18n 词表生成）。
    self.rateFamilyPopup = [self popupForKey:@"sp_ratefamily"
        items:@[ RLPTr(@"自动（prefer）"), RLPTr(@"严格同族（strict）"), RLPTr(@"兼容转换（compatible）") ]
        action:@selector(onRateFamily:)];
    {
        NSArray<NSString *> *vals = @[ @"prefer", @"strict", @"compatible" ];
        for (NSUInteger i = 0; i < vals.count && i < (NSUInteger)self.rateFamilyPopup.numberOfItems; ++i)
            [self.rateFamilyPopup itemAtIndex:(NSInteger)i].representedObject = vals[i];
    }
    [stack addArrangedSubview:RLPSRow(RLPTr(@"采样率族策略"), self.rateFamilyPopup,
        RLPTr(@"自动 = 优先源采样率同族（拒绝跨族）；严格 = 禁止跨族；兼容 = 允许跨族转换（非 bit-perfect）"), t)];

    // web #sp_bits 的 option value 是 -1 / 0 / 16 / 32（ui_script.h:9855-9858）。
    self.bitsPopup = [self popupForKey:@"sp_bits"
        items:@[ RLPTr(@"跟随源（按文件位深）"), @"24 bit", @"16 bit", @"32 bit" ]
        action:@selector(onBits:)];
    {
        NSArray<NSString *> *vals = @[ @"-1", @"0", @"16", @"32" ];
        for (NSUInteger i = 0; i < vals.count && i < (NSUInteger)self.bitsPopup.numberOfItems; ++i)
            [self.bitsPopup itemAtIndex:(NSInteger)i].representedObject = vals[i];
    }
    [stack addArrangedSubview:RLPSRow(RLPTr(@"输出位深（PCM）"), self.bitsPopup,
        RLPTr(@"跟随源 = 按文件真实位深请求；DSD 输出恒为 1 bit"), t)];

    self.chPopup = [self popupForKey:@"sp_ch"
        items:@[ RLPTr(@"跟随源声道数"), @"2", @"6", @"8" ] action:@selector(onChannels:)];
    {
        NSArray<NSString *> *vals = @[ @"0", @"2", @"6", @"8" ];
        for (NSUInteger i = 0; i < vals.count && i < (NSUInteger)self.chPopup.numberOfItems; ++i)
            [self.chPopup itemAtIndex:(NSInteger)i].representedObject = vals[i];
    }
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
        double initVal = (self.savedTrimValues && i < self.savedTrimValues.count)
                       ? [self.savedTrimValues[i] doubleValue] : 0.0;
        if (initVal < -24.0) initVal = -24.0;
        if (initVal > 12.0) initVal = 12.0;
        NSTextField *lab = RLPLabel([NSString stringWithFormat:RLPTr(@"%@（声道 %lu，dB）"),
                                     names[i], (unsigned long)(i + 1)],
                                    [NSFont systemFontOfSize:11], t.mut);
        lab.translatesAutoresizingMaskIntoConstraints = NO;
        [[lab.widthAnchor constraintEqualToConstant:170] setActive:YES];
        NSSlider *s = [NSSlider sliderWithValue:initVal minValue:-24 maxValue:12
                                        target:self action:@selector(onTrimSlider:)];
        s.identifier = key;
        s.tag = (NSInteger)i;
        s.continuous = NO;            // 松开鼠标才提交：避免拖动时向后端灌请求
        s.trackFillColor = [RLPTheme current].accent;   // web 滑杆是 accent 色，不要系统默认亮蓝
        s.translatesAutoresizingMaskIntoConstraints = NO;
        [[s.widthAnchor constraintEqualToConstant:220] setActive:YES];
        NSTextField *val = RLPLabel([NSString stringWithFormat:@"%.1f dB", initVal],
                                    [NSFont systemFontOfSize:10.5], t.mut2);
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

    // U8（2026-11-16）：紧跟 Nx 行下方的「族说明」。文案取自 src/dsp/filter_family.h
    // （纪要的族划分 + 名字后缀相位），**不写任何 dB / 抽头承诺**；选中项一变就重算。
    self.filtNxNote = [self hintForKey:@"sp_filtNx_note" width:560];
    self.filtNxNote.identifier = @"sp_filtNx_note";   // 机械扫描可见（parity / --audit 取证）
    self.filtNxNote.hidden = YES;
    [gCurrentGroup addNoteView:self.filtNxNote];

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

    // ⚠️ 选项必须**当场给全**，不能只放一个"读取中…"占位再等别处填。
    // 用户 2026-11-15 实测：这个下拉永远显示「读取中…」。
    // 根因：后端把 SHAPER_OPTS 只塞进 **web 页面的 <select id=sShap>**（rtaweb.cpp:12706
    // 的 fill_all），原生端没有任何 /api/... 会返回这份清单，
    // 而 reloadData 里也只给滤波器下拉填了项（/api/filters），漏了这一个。
    // 清单与后端逐字一致（rtaweb.cpp:12692 的 so 循环），改一处必须改两处。
    NSArray<NSString *> *shapers = @[ @"auto", @"none", @"NS1", @"NS4", @"NS5", @"NS9",
                                      @"LNS15", @"RPDF", @"TPDF", @"Gauss1", @"Shaped" ];
    NSMutableArray<NSString *> *shaperItems = [NSMutableArray array];
    for (NSString *s in shapers) [shaperItems addObject:s];
    self.shaperPopup = [self popupForKey:@"sp_shaper" items:shaperItems
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
    RLPSettingsGroup *sdmGroup = (RLPSettingsGroup *)RLPSGroup(RLPTr(@"SDM 输出"),
                                                                RLPTr(@"只在输出 DSD 时生效"), t);
    [stack addArrangedSubview:sdmGroup];
    self.sdmGroup = sdmGroup;

    self.sdmO1Popup = [self popupForKey:@"sp_sdmo1"
        items:@[ RLPTr(@"跟随 PCM 页的 1x"), RLPTr(@"读取中…") ] action:@selector(onSdmO1:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"Oversampling 1x（44.1 / 48 kHz 音源）"), self.sdmO1Popup,
        RLPTr(@"留空则沿用 PCM 页的 1x"), t)];

    self.sdmONxPopup = [self popupForKey:@"sp_sdmoNx"
        items:@[ RLPTr(@"跟随上面的 1x"), RLPTr(@"读取中…") ] action:@selector(onSdmONx:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"Oversampling Nx（88.2 kHz 及以上音源）"), self.sdmONxPopup, nil, t)];

    // 值用纯数字（64/128/256/512/1024），与 web 的 opt('64', …) 同口径。
    // 落盘时不是单独发它：三个控件合成一个 dsd 键（例如 dop256 / 0），见 dsdPersistValue。
    self.dsdRatePopup = [self popupForKey:@"sp_dsdrate"
        items:@[ @"64", @"128", @"256", @"512" ] action:@selector(onDsdRate:)];
    [stack addArrangedSubview:RLPSRow(RLPTr(@"比特率"), self.dsdRatePopup,
        RLPTr(@"最高支持 DSD512，实际可用倍率取决于设备 DoP 载波能力"), t)];

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

    // U12（2026-11-16）：拐点准入提示（紧跟「拐点」行、同卡整行）。
    // 只有后端判 admitted=false 才显示；显示内容**原样**用 sdm.note（阈值/出路都由后端写，
    // 前端不复制 100000 Hz —— 策略改了不用改 UI，也不会两处口径打架）。
    self.sdmCornerNote = [self hintForKey:@"sp_sdmcorner_note" width:560];
    self.sdmCornerNote.identifier = @"sp_sdmcorner_note";   // 机械扫描可见（parity / --audit 取证）
    self.sdmCornerNote.hidden = YES;
    [gCurrentGroup addNoteView:self.sdmCornerNote];
    [self applySdmAdmission:self.sdmAdmission];   // 页签晚建时用最近一次 GET 的快照补一次

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
    // 设置页本身就是整页滚动容器：状态区块不再套自己的滚动条。
    [self.inputView setEmbeddedInPage:YES];
    [gCurrentGroup addFullRow:self.inputView];
    [self.inputView reload];
    // 高度 = 状态区块的自然高度（拆掉内层滚动后必须由宿主给，否则本视图没有 intrinsic 高度）。
    [[self.inputView.heightAnchor
        constraintEqualToConstant:MAX(120.0, [self.inputView preferredContentHeight])] setActive:YES];
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
    NSString *curLang = RLPLanguage();
    if (!curLang.length) curLang = RLPLanguageFromConf() ?: @"zh";
    [self.langPopup selectItemAtIndex:[curLang isEqualToString:@"en"] ? 1 : 0];
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
    self.srvGroup = srvGroup;
    [stack addArrangedSubview:srvGroup];

    self.serversView = [[RLPServersView alloc] initWithFrame:NSMakeRect(0, 0, 620, 120)];
    self.serversView.translatesAutoresizingMaskIntoConstraints = NO;
    [srvGroup addFullRow:self.serversView];
    [[self.serversView.heightAnchor constraintGreaterThanOrEqualToConstant:64] setActive:YES];
    [self.serversView reload];

    // 投放面板（设备发现 / 推送 / 停止 / 升频选项 / 实时状态）与 web 同源 /api/cast/*
    RLPSettingsGroup *castGroup = (RLPSettingsGroup *)RLPSGroup(RLPTr(@"推送到设备（UPnP / DLNA）"),
        RLPTr(@"一键把当前曲目推送到局域网渲染器；之后的切歌 / 暂停 / 进度都作用在它上面"), t);
    self.castGroup = castGroup;
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
    self.diagGroup = diagGroup;

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

    self.diagChannelsBtn = [self secondaryButton:@"检查反馈/更新通道"
                                           ident:@"sp_diagchannelsbtn"
                                          action:@selector(onCheckDiagChannels:)];
    [self.diagChannelsBtn setContentHuggingPriority:NSLayoutPriorityRequired
                                     forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.diagChannelsBtn setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                                   forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.diagChannelsLabel = RLPLabel(@"", t.small, t.mut2);
    self.diagChannelsLabel.identifier = @"sp_diagchannels";
    self.diagChannelsLabel.maximumNumberOfLines = 4;
    self.diagChannelsLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.diagChannelsLabel.selectable = YES;
    [self.diagChannelsLabel setContentHuggingPriority:NSLayoutPriorityDefaultLow
                                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.diagChannelsLabel setContentCompressionResistancePriority:1.0f
                                                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.diagChannelsLabel setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                                       forOrientation:NSLayoutConstraintOrientationVertical];
    [[self.diagChannelsLabel.widthAnchor constraintLessThanOrEqualToConstant:380] setActive:YES];

    NSStackView *chanRow = [[NSStackView alloc] init];
    chanRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    chanRow.alignment = NSLayoutAttributeCenterY;
    chanRow.spacing = 10;
    [chanRow addArrangedSubview:self.diagChannelsBtn];
    [chanRow addArrangedSubview:self.diagChannelsLabel];
    [diagGroup addFullRow:chanRow];

    // 两行说明（web 原文，逐字）：第一行主文案，第二行补「已脱敏」。
    [diagGroup addNote:RLPTr(@"一个 zip 打包全部日志 / 系统信息 / 设置摘要")];
    [diagGroup addNote:RLPTr(@"（已脱敏），不用再到处找日志文件")];

    // ---- 软件更新（整块控件都必须在卡片体内；旧码把版本/按钮/说明铺在页面层级）----
    RLPSettingsGroup *updGroup = (RLPSettingsGroup *)RLPSGroup(RLPTr(@"软件更新"),
        RLPTr(@"检查新版本，一键更新"), t);
    [stack addArrangedSubview:updGroup];
    self.updGroup = updGroup;

    // 列表里显示**可读文案**，不显示内部 key：
    // 旧实现直接摆 `global` / `cn`，用户在设置页看到的是技术标识（截图实测）。
    // 读回与提交都按**索引**（read_update_channel_value + indexOfSelectedItem），
    // 所以只换显示标题不会影响落盘值。
    // 显示可读文案，但**把内部 key 挂在 representedObject 上**：
    // 这样界面不再暴露 `global` / `cn`，而程序侧（判据、回读、提交）仍拿到稳定值，
    // 不依赖"标题恰好等于 key"这种脆弱假设。
    self.updChannelPopup = [self popupForKey:@"sp_updchannel"
                                       items:@[ RLPTr(@"全球（GitHub）"), RLPTr(@"中国大陆（国内后台）") ]
                                      action:@selector(onUpdateChannel:)];
    {
        NSArray<NSString *> *keys = @[ @"global", @"cn" ];
        for (NSInteger i = 0; i < (NSInteger)keys.count && i < self.updChannelPopup.numberOfItems; ++i) {
            self.updChannelPopup.itemArray[i].representedObject = keys[i];
        }
    }
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
    self.fbGroup = fbGroup;
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

    self.fbCount = RLPLabel(@"", t.small, t.mut);
    self.fbCount.identifier = RLPControlIdentifier(@"sp_fbcount");
    self.fbCount.maximumNumberOfLines = 0;
    self.fbCount.lineBreakMode = NSLineBreakByWordWrapping;
    self.fbCount.stringValue = RLPTr(@"0 / 16384 字节");
    [fbGroup addFullRow:self.fbCount];

    self.fbChan = RLPLabel(@"", t.small, t.mut);
    self.fbChan.identifier = RLPControlIdentifier(@"sp_fbchan");
    self.fbChan.maximumNumberOfLines = 0;
    self.fbChan.lineBreakMode = NSLineBreakByWordWrapping;
    self.fbChan.selectable = YES;
    self.fbChan.stringValue = RLPTr(@"正在检查反馈通道…");
    [fbGroup addFullRow:self.fbChan];

    // 底部选项与操作行拆行：开关单独占一行，按钮 + 单行状态紧随其下；
    // 否则窄窗（900×600）/ 英文按钮较长时，300pt 写死宽的 fbMsg 会把整行撑爆。
    self.fbDiagSwitch = [self switchForKey:@"sp_fbdiag" action:@selector(onFbDiagToggle:)];
    self.fbDiagSwitch.state = NSControlStateValueOn;
    [self.fbDiagSwitch setContentHuggingPriority:NSLayoutPriorityRequired
                                  forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.fbDiagSwitch setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                                  forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSTextField *fbDiagLabel = RLPLabel(RLPTr(@"附带诊断包"), t.small, t.mut);
    fbDiagLabel.maximumNumberOfLines = 2;
    fbDiagLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [fbDiagLabel setContentHuggingPriority:NSLayoutPriorityDefaultLow
                            forOrientation:NSLayoutConstraintOrientationHorizontal];
    [fbDiagLabel setContentCompressionResistancePriority:1.0f
                                          forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *fbDiagRow = [[NSStackView alloc] init];
    fbDiagRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    fbDiagRow.alignment = NSLayoutAttributeCenterY;
    fbDiagRow.spacing = 8;
    fbDiagRow.translatesAutoresizingMaskIntoConstraints = NO;
    [fbDiagRow setContentHuggingPriority:NSLayoutPriorityDefaultLow
                          forOrientation:NSLayoutConstraintOrientationHorizontal];
    [fbDiagRow addArrangedSubview:self.fbDiagSwitch];
    [fbDiagRow addArrangedSubview:fbDiagLabel];

    self.fbSendBtn = [self primaryButton:@"发送反馈" ident:@"sp_fbsend"
                                  action:@selector(onSendFeedback:)];
    self.fbRetryBtn = [self secondaryButton:@"重试探活" ident:@"sp_fbretry"
                                     action:@selector(onFeedbackRetry:)];
    self.fbRetryBtn.hidden = YES;
    self.fbMsg = RLPLabel(@"", t.small, t.mut);
    self.fbMsg.identifier = RLPControlIdentifier(@"sp_fbmsg");
    self.fbMsg.maximumNumberOfLines = 1;
    self.fbMsg.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.fbMsg setContentHuggingPriority:NSLayoutPriorityDefaultLow
                           forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.fbMsg setContentCompressionResistancePriority:1.0f
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];
    // v3.3.11 `rlFbPreview`：先看会发送什么（纯前端，不发请求、不改任何状态）。
    self.fbPreviewBtn = [self secondaryButton:@"先看会发送什么" ident:@"sp_fbpreview"
                                       action:@selector(onFbPreview:)];
    for (NSButton *b in @[ self.fbPreviewBtn, self.fbSendBtn, self.fbRetryBtn ]) {
        [b setContentHuggingPriority:NSLayoutPriorityRequired
                      forOrientation:NSLayoutConstraintOrientationHorizontal];
        [b setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    }

    auto configureMultilineFbBox = ^(NSTextField *box, NSString *ident) {
        box.identifier = ident;
        box.maximumNumberOfLines = 0;
        box.lineBreakMode = NSLineBreakByWordWrapping;
        box.selectable = YES;
        box.hidden = YES;
        if ([box.cell isKindOfClass:[NSTextFieldCell class]]) {
            NSTextFieldCell *cell = (NSTextFieldCell *)box.cell;
            cell.wraps = YES;
            cell.scrollable = NO;
            cell.usesSingleLineMode = NO;
        }
        [box setContentHuggingPriority:NSLayoutPriorityDefaultLow
                        forOrientation:NSLayoutConstraintOrientationHorizontal];
        [box setContentCompressionResistancePriority:1.0f
                                      forOrientation:NSLayoutConstraintOrientationHorizontal];
        [box setContentHuggingPriority:NSLayoutPriorityRequired
                        forOrientation:NSLayoutConstraintOrientationVertical];
        [box setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh
                                      forOrientation:NSLayoutConstraintOrientationVertical];
    };
    self.fbPreviewBox = RLPLabel(@"", t.small, t.mut2);
    configureMultilineFbBox(self.fbPreviewBox, @"sp_fbpreviewbox");   // web `#rlFbPreviewbox{display:none}`
    self.fbResultBox = RLPLabel(@"", t.small, t.mut2);
    configureMultilineFbBox(self.fbResultBox, @"sp_fbresult");

    NSStackView *fbRow = [[NSStackView alloc] init];
    fbRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    fbRow.alignment = NSLayoutAttributeCenterY;
    fbRow.spacing = 10;
    fbRow.detachesHiddenViews = YES;
    fbRow.translatesAutoresizingMaskIntoConstraints = NO;
    [fbRow setContentHuggingPriority:NSLayoutPriorityDefaultLow
                      forOrientation:NSLayoutConstraintOrientationHorizontal];
    for (NSView *v in @[ self.fbPreviewBtn, self.fbSendBtn, self.fbRetryBtn, self.fbMsg ])
        [fbRow addArrangedSubview:v];
    [fbGroup addFullRow:fbDiagRow];
    [fbGroup addFullRow:fbRow];
    [fbGroup addFullRow:self.fbPreviewBox];
    [fbGroup addFullRow:self.fbResultBox];

    [fbGroup addNote:RLPTr(@"提交前会先探活；通道不可用时按钮保持禁用，绝不假装发送成功。")];
    [fbGroup addNote:RLPTr(@"诊断包已脱敏，不会上传你的音乐文件。")];

    // 进页面即探活一次（web bindFeedbackCard 同语义）；之后 30 秒内不重复探。
    [self probeFeedbackChannel];
}

#pragma mark - 元数据

/// 把卡片标题条的说明文字压缩阻力降到 < NSLayoutPriorityFittingSizeCompression(50)，
/// 避免 ~600-950pt 说明把 card/_head 的 fittingSize 顶宽，悬停保留完整 tooltip。
static void RLPTuneMetaGroup(RLPSettingsGroup *group) {
    if (!group) return;
    for (NSView *sub in group.subviews) {
        if (![sub.identifier isEqualToString:@"set.group.head"]) continue;
        NSMutableArray<NSTextField *> *fields = [NSMutableArray array];
        for (NSView *hv in sub.subviews) {
            if ([hv isKindOfClass:[NSTextField class]]) [fields addObject:(NSTextField *)hv];
        }
        if (fields.count >= 1) {
            NSTextField *titleLabel = fields[0];
            titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
            titleLabel.maximumNumberOfLines = 1;
            [titleLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                 forOrientation:NSLayoutConstraintOrientationHorizontal];
        }
        if (fields.count >= 2) {
            NSTextField *hintLabel = fields[1];
            hintLabel.lineBreakMode = NSLineBreakByTruncatingTail;
            hintLabel.maximumNumberOfLines = 1;
            if (hintLabel.stringValue.length) hintLabel.toolTip = hintLabel.stringValue;
            [hintLabel setContentHuggingPriority:NSLayoutPriorityDefaultLow
                                  forOrientation:NSLayoutConstraintOrientationHorizontal];
            [hintLabel setContentCompressionResistancePriority:1.0f
                                                forOrientation:NSLayoutConstraintOrientationHorizontal];
        }
        break;
    }
}

static void RLPTuneMetaTextField(NSTextField *tf) {
    if (!tf) return;
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    [tf setContentHuggingPriority:NSLayoutPriorityDefaultLow
                   forOrientation:NSLayoutConstraintOrientationHorizontal];
    [tf setContentCompressionResistancePriority:1.0f
                                 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSTextFieldCell *cell = [tf.cell isKindOfClass:[NSTextFieldCell class]]
        ? (NSTextFieldCell *)tf.cell : nil;
    if (cell) {
        cell.scrollable = YES;
        cell.wraps = NO;
        cell.usesSingleLineMode = YES;
    }
}

static void RLPTuneMetaPopup(NSPopUpButton *pop) {
    if (!pop) return;
    pop.translatesAutoresizingMaskIntoConstraints = NO;
    [pop setContentHuggingPriority:NSLayoutPriorityDefaultLow
                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    [pop setContentCompressionResistancePriority:1.0f
                                  forOrientation:NSLayoutConstraintOrientationHorizontal];
    if ([pop.cell isKindOfClass:[NSPopUpButtonCell class]]) {
        NSPopUpButtonCell *cell = (NSPopUpButtonCell *)pop.cell;
        cell.lineBreakMode = NSLineBreakByTruncatingTail;
        cell.usesSingleLineMode = YES;
    }
}

static void RLPTuneMetaDescendantLabel(NSView *root, NSString *ident) {
    if (!root || !ident.length) return;
    if ([root.identifier isEqualToString:ident]) {
        [root setContentCompressionResistancePriority:1.0f
                                       forOrientation:NSLayoutConstraintOrientationHorizontal];
        return;
    }
    for (NSView *sub in root.subviews) {
        RLPTuneMetaDescendantLabel(sub, ident);
    }
}

static void RLPMetaClearStackRow(NSStackView *row) {
    if (!row) return;
    for (NSView *v in [row.arrangedSubviews copy]) {
        [row removeArrangedSubview:v];
        [v removeFromSuperview];
    }
}

- (void)resetMetaResponsiveState {
    self.metaHostStack = nil;
    self.metaTopGroup = nil;
    self.metaDataGroup = nil;
    self.metaAiGroup = nil;
    self.metaSearchGroup = nil;
    self.metaTwoColStack = nil;
    self.metaAdvWidthConstraint = nil;
    self.metaTwoColWidthConstraint = nil;
    self.metaSearchWidthConstraint = nil;
    self.metaVerticalCardWidthConstraints = nil;
    self.metaModelContainer = nil;
    self.metaModelPrimaryRow = nil;
    self.metaModelSecondaryRow = nil;
    self.metaModelHiddenDock = nil;
    self.metaModelRowConstraints = nil;
    self.llmSaveBtn = nil;
    self.llmTestBtn = nil;
    self.llmClearBtn = nil;
    self.metaAiBtnContainer = nil;
    self.metaAiBtnRow1 = nil;
    self.metaAiBtnRow2 = nil;
    self.metaAiBtnConstraints = nil;
    self.metaResponsiveTwoColMode = -1;
    self.metaResponsiveModelMode = -1;
    self.metaResponsiveAiBtnMode = -1;
}

- (CGFloat)metaTargetHostWidthPreferringViewBounds:(BOOL)preferViewBounds {
    if (preferViewBounds && self.view.superview && self.view.bounds.size.width > 1.0) {
        return self.view.bounds.size.width;
    }
    if (self.paneHost && self.paneHost.bounds.size.width > 1.0) {
        return self.paneHost.bounds.size.width;
    }
    if (self.view.superview && self.view.superview.bounds.size.width > 1.0) {
        return self.view.superview.bounds.size.width;
    }
    if (self.view.window) {
        NSView *content = self.view.window.contentView;
        if (content && content.bounds.size.width > 1.0) {
            if (self.view.superview == content) return content.bounds.size.width;
            return MAX(0.0, content.bounds.size.width - 226.0);
        }
    }
    return self.view.bounds.size.width;
}

- (BOOL)updateMetaModelRowLayoutForBodyWidth:(CGFloat)bodyW {
    if (!self.metaModelContainer || !self.metaModelPrimaryRow || !self.metaModelSecondaryRow ||
        !self.metaModelHiddenDock || !self.llmModelPopup || !self.llmModel || !self.llmModelRefresh) {
        return NO;
    }
    const NSInteger targetMode = self.llmModelPopup.hidden ? 0 : (bodyW >= 460.0 ? 1 : 2);
    if (targetMode == self.metaResponsiveModelMode) return NO;

    if (self.metaModelRowConstraints.count) {
        [NSLayoutConstraint deactivateConstraints:self.metaModelRowConstraints];
        self.metaModelRowConstraints = nil;
    }
    RLPMetaClearStackRow(self.metaModelPrimaryRow);
    RLPMetaClearStackRow(self.metaModelSecondaryRow);
    [self.metaModelSecondaryRow removeFromSuperview];
    [self.llmModelPopup removeFromSuperview];
    [self.llmModel removeFromSuperview];
    [self.llmModelRefresh removeFromSuperview];

    [self.llmModel setContentHuggingPriority:NSLayoutPriorityDefaultLow
                              forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.llmModel setContentCompressionResistancePriority:1.0f
                                            forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.llmModelPopup setContentHuggingPriority:NSLayoutPriorityDefaultLow
                                   forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.llmModelPopup setContentCompressionResistancePriority:1.0f
                                                 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.llmModelRefresh setContentHuggingPriority:NSLayoutPriorityDefaultHigh
                                     forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.llmModelRefresh setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh
                                                   forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSMutableArray<NSLayoutConstraint *> *cs = [NSMutableArray array];
    if (targetMode == 0) {
        [self.metaModelHiddenDock addSubview:self.llmModelPopup];
        self.llmModelPopup.frame = NSZeroRect;
        [self.metaModelPrimaryRow addArrangedSubview:self.llmModel];
        [self.metaModelPrimaryRow addArrangedSubview:self.llmModelRefresh];
        [cs addObject:[self.metaModelPrimaryRow.bottomAnchor
            constraintEqualToAnchor:self.metaModelContainer.bottomAnchor]];
    } else if (targetMode == 1) {
        [self.metaModelPrimaryRow addArrangedSubview:self.llmModelPopup];
        [self.metaModelPrimaryRow addArrangedSubview:self.llmModel];
        [self.metaModelPrimaryRow addArrangedSubview:self.llmModelRefresh];
        NSLayoutConstraint *eq =
            [self.llmModelPopup.widthAnchor constraintEqualToAnchor:self.llmModel.widthAnchor];
        eq.priority = NSLayoutPriorityDefaultLow + 100;
        [cs addObjectsFromArray:@[
            [self.metaModelPrimaryRow.bottomAnchor
                constraintEqualToAnchor:self.metaModelContainer.bottomAnchor],
            eq,
        ]];
    } else {
        [self.metaModelContainer addSubview:self.metaModelSecondaryRow];
        [self.metaModelPrimaryRow addArrangedSubview:self.llmModelPopup];
        [self.metaModelSecondaryRow addArrangedSubview:self.llmModel];
        [self.metaModelSecondaryRow addArrangedSubview:self.llmModelRefresh];
        NSLayoutConstraint *fillPop =
            [self.llmModelPopup.widthAnchor constraintEqualToAnchor:self.metaModelPrimaryRow.widthAnchor];
        fillPop.priority = NSLayoutPriorityDefaultHigh;
        [cs addObjectsFromArray:@[
            [self.metaModelSecondaryRow.leadingAnchor
                constraintEqualToAnchor:self.metaModelContainer.leadingAnchor],
            [self.metaModelSecondaryRow.trailingAnchor
                constraintEqualToAnchor:self.metaModelContainer.trailingAnchor],
            [self.metaModelSecondaryRow.topAnchor
                constraintEqualToAnchor:self.metaModelPrimaryRow.bottomAnchor constant:8],
            [self.metaModelSecondaryRow.bottomAnchor
                constraintEqualToAnchor:self.metaModelContainer.bottomAnchor],
            fillPop,
        ]];
    }
    [NSLayoutConstraint activateConstraints:cs];
    self.metaModelRowConstraints = cs;
    self.metaResponsiveModelMode = targetMode;
    return YES;
}

- (BOOL)updateMetaAiBtnRowLayoutForBodyWidth:(CGFloat)bodyW {
    if (!self.metaAiBtnContainer || !self.metaAiBtnRow1 || !self.metaAiBtnRow2 ||
        !self.llmSaveBtn || !self.llmTestBtn || !self.llmClearBtn) {
        return NO;
    }
    const NSInteger targetMode = (bodyW >= 450.0) ? 0 : 1;
    if (targetMode == self.metaResponsiveAiBtnMode) return NO;

    if (self.metaAiBtnConstraints.count) {
        [NSLayoutConstraint deactivateConstraints:self.metaAiBtnConstraints];
        self.metaAiBtnConstraints = nil;
    }
    RLPMetaClearStackRow(self.metaAiBtnRow1);
    RLPMetaClearStackRow(self.metaAiBtnRow2);
    [self.metaAiBtnRow2 removeFromSuperview];
    [self.llmSaveBtn removeFromSuperview];
    [self.llmTestBtn removeFromSuperview];
    [self.llmClearBtn removeFromSuperview];

    NSMutableArray<NSLayoutConstraint *> *cs = [NSMutableArray array];
    if (targetMode == 0) {
        [self.metaAiBtnRow1 addArrangedSubview:self.llmSaveBtn];
        [self.metaAiBtnRow1 addArrangedSubview:self.llmTestBtn];
        [self.metaAiBtnRow1 addArrangedSubview:self.llmClearBtn];
        [cs addObject:[self.metaAiBtnRow1.bottomAnchor
            constraintEqualToAnchor:self.metaAiBtnContainer.bottomAnchor]];
    } else {
        [self.metaAiBtnContainer addSubview:self.metaAiBtnRow2];
        [self.metaAiBtnRow1 addArrangedSubview:self.llmSaveBtn];
        [self.metaAiBtnRow1 addArrangedSubview:self.llmTestBtn];
        [self.metaAiBtnRow2 addArrangedSubview:self.llmClearBtn];
        [cs addObjectsFromArray:@[
            [self.metaAiBtnRow2.leadingAnchor
                constraintEqualToAnchor:self.metaAiBtnContainer.leadingAnchor],
            [self.metaAiBtnRow2.trailingAnchor
                constraintLessThanOrEqualToAnchor:self.metaAiBtnContainer.trailingAnchor],
            [self.metaAiBtnRow2.topAnchor
                constraintEqualToAnchor:self.metaAiBtnRow1.bottomAnchor constant:8],
            [self.metaAiBtnRow2.bottomAnchor
                constraintEqualToAnchor:self.metaAiBtnContainer.bottomAnchor],
        ]];
    }
    [NSLayoutConstraint activateConstraints:cs];
    self.metaAiBtnConstraints = cs;
    self.metaResponsiveAiBtnMode = targetMode;
    return YES;
}

- (void)updateMetaResponsiveLayoutForHostWidth:(CGFloat)hostW {
    if (self.metaResponsiveUpdating) return;
    if (!self.metaAdvancedStack || !self.metaTwoColStack ||
        !self.metaDataGroup || !self.metaAiGroup || !self.metaSearchGroup) {
        return;
    }
    self.metaResponsiveUpdating = YES;
    const CGFloat avail = MAX(0.0, hostW - 48.0);
    // 0 = 折叠收起态（adv 隐藏，断开与 stack 等宽链）；1 = 展开单列堆叠；2 = 展开两列并排（>=840pt 内容区）
    const NSInteger targetTwoColMode = !self.metaAdvancedVisible ? 0 : (avail >= 840.0 ? 2 : 1);
    BOOL needsAllRelayout = NO;
    BOOL needsAiRelayout = NO;

    if (targetTwoColMode != self.metaResponsiveTwoColMode) {
        const BOOL wasExpanded = (self.metaResponsiveTwoColMode > 0);
        self.metaResponsiveTwoColMode = targetTwoColMode;
        const BOOL expanded = (targetTwoColMode > 0);
        const BOOL twoCol = (targetTwoColMode == 2);

        self.metaAdvWidthConstraint.active = expanded;
        self.metaTwoColWidthConstraint.active = expanded;
        self.metaSearchWidthConstraint.active = expanded;
        for (NSLayoutConstraint *c in self.metaVerticalCardWidthConstraints) {
            c.active = (expanded && !twoCol);
        }
        if (twoCol) {
            self.metaTwoColStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
            self.metaTwoColStack.distribution = NSStackViewDistributionFillEqually;
            self.metaTwoColStack.alignment = NSLayoutAttributeTop;
            self.metaTwoColStack.spacing = 16;
        } else {
            self.metaTwoColStack.orientation = NSUserInterfaceLayoutOrientationVertical;
            self.metaTwoColStack.distribution = NSStackViewDistributionFill;
            self.metaTwoColStack.alignment = NSLayoutAttributeLeading;
            self.metaTwoColStack.spacing = 22;
        }
        if (expanded || wasExpanded) needsAllRelayout = YES;
    }

    const CGFloat aiCardW = (targetTwoColMode == 2) ? MAX(0.0, (avail - 16.0) * 0.5) : avail;
    const CGFloat aiBodyW = MAX(0.0, aiCardW - 32.0);
    if ([self updateMetaAiBtnRowLayoutForBodyWidth:aiBodyW]) needsAiRelayout = YES;
    if ([self updateMetaModelRowLayoutForBodyWidth:aiBodyW]) needsAiRelayout = YES;

    if (needsAllRelayout) {
        [self.metaDataGroup contentDidChange];
        [self.metaAiGroup contentDidChange];
        [self.metaSearchGroup contentDidChange];
        [self.metaTwoColStack setNeedsUpdateConstraints:YES];
        [self.metaTwoColStack setNeedsLayout:YES];
        [self.metaAdvancedStack setNeedsLayout:YES];
        [self.metaHostStack setNeedsLayout:YES];
    } else if (needsAiRelayout) {
        [self.metaAiGroup contentDidChange];
        [self.metaTwoColStack setNeedsLayout:YES];
        [self.metaAdvancedStack setNeedsLayout:YES];
        [self.metaHostStack setNeedsLayout:YES];
    }
    self.metaResponsiveUpdating = NO;
}

- (void)fillMeta:(NSStackView *)stack t:(RLPTheme *)t {
    [self resetMetaResponsiveState];
    self.metaHostStack = stack;

    // ── 基础选项（对齐 web：默认只显示三个开关 + 「高级选项 ▾」）──
    RLPSettingsGroup *topGroup = (RLPSettingsGroup *)RLPSGroup(RLPTr(@"元数据补全"),
        RLPTr(@"播放时后台补全标签 / 封面 / 歌词，结果落在本地库"), t);
    RLPTuneMetaGroup(topGroup);
    self.metaTopGroup = topGroup;
    [stack addArrangedSubview:topGroup];
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
    NSButton *moreBtn = [NSButton buttonWithTitle:(self.metaAdvancedVisible ? RLPTr(@"高级选项 ▴") : RLPTr(@"高级选项 ▾"))
                                           target:self
                                           action:@selector(onToggleMetaAdvanced:)];
    moreBtn.bezelStyle = NSBezelStyleRounded;
    moreBtn.identifier = @"sp_metamore";
    self.metaMoreBtn = moreBtn;
    if (gCurrentGroup) [gCurrentGroup addButtonRow:@[moreBtn]];

    // 高级内容容器：默认 hidden（折叠态与 stack 等宽链保持断开，避免 fitting 撑大主窗）。
    NSStackView *adv = [[NSStackView alloc] init];
    adv.orientation = NSUserInterfaceLayoutOrientationVertical;
    adv.alignment = NSLayoutAttributeLeading;
    adv.spacing = 22;
    adv.translatesAutoresizingMaskIntoConstraints = NO;
    adv.hidden = !self.metaAdvancedVisible;
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
    RLPTuneMetaGroup(dataGroup);
    if (gLastGroupWidthConstraint) {
        gLastGroupWidthConstraint.active = NO;
        gLastGroupWidthConstraint = nil;
    }
    self.metaDataGroup = dataGroup;
    [adv addArrangedSubview:dataGroup];
    self.metaSourcesView = [[RLPMetaSourcesView alloc] initWithFrame:NSMakeRect(0, 0, 580, 200)];
    self.metaSourcesView.translatesAutoresizingMaskIntoConstraints = NO;
    RLPTuneMetaDescendantLabel(self.metaSourcesView, @"metasrc.msg");
    [dataGroup addFullRow:self.metaSourcesView];
    [[self.metaSourcesView heightAnchor] constraintGreaterThanOrEqualToConstant:200].active = YES;
    [self.metaSourcesView reload];

    // AI 接入卡片（web 高级区右列 .meta-card）：密钥红线 —— GET 只回掩码，输入框留空 = 不改已存的 key
    RLPSettingsGroup *aiGroup = (RLPSettingsGroup *)RLPSGroup(RLPTr(@"AI 接入（OpenAI 兼容）"),
        RLPTr(@"任何兼容 OpenAI 的服务都能用。密钥只在本机保存，界面永不回显明文；留空表示不修改。"), t);
    RLPTuneMetaGroup(aiGroup);
    if (gLastGroupWidthConstraint) {
        gLastGroupWidthConstraint.active = NO;
        gLastGroupWidthConstraint = nil;
    }
    self.metaAiGroup = aiGroup;
    [adv addArrangedSubview:aiGroup];

    // ① 接口预设（对齐 web LLM_PROVIDERS / sp_llmprovider）——只负责「填地址」，不做连通性判断。
    self.llmProviderPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSString *n in @[ @"DeepSeek", @"OpenAI", @"OpenRouter",
                           RLPTr(@"SiliconFlow（硅基流动）"), RLPTr(@"Ollama（本机）"), RLPTr(@"自定义") ])
        [self.llmProviderPopup addItemWithTitle:n];
    self.llmProviderPopup.identifier = @"llm.provider";
    self.llmProviderPopup.target = self;
    self.llmProviderPopup.action = @selector(onLlmProviderPicked:);
    RLPTuneMetaPopup(self.llmProviderPopup);
    [aiGroup addField:RLPTr(@"接口预设") control:self.llmProviderPopup hint:nil];

    // ② 接口地址
    self.llmBase = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.llmBase.placeholderString = @"https://api.deepseek.com";
    self.llmBase.identifier = @"llm.base";
    RLPTuneMetaTextField(self.llmBase);
    [aiGroup addField:RLPTr(@"接口地址") control:self.llmBase hint:nil];

    // ③ 密钥（web 顺序：Key 在保存/测试/清除之前）
    self.llmKey = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    self.llmKey.placeholderString = RLPTr(@"留空 = 保持已保存的密钥");
    self.llmKey.identifier = @"llm.key";
    RLPTuneMetaTextField(self.llmKey);
    [aiGroup addField:RLPTr(@"API Key") control:self.llmKey hint:nil];

    self.llmStatus = RLPLabel(@"", t.small, t.mut);
    self.llmStatus.maximumNumberOfLines = 2;
    self.llmStatus.lineBreakMode = NSLineBreakByWordWrapping;
    self.llmStatus.identifier = @"llm.status";
    [self.llmStatus setContentCompressionResistancePriority:1.0f
                                             forOrientation:NSLayoutConstraintOrientationHorizontal];
    [aiGroup addNoteView:self.llmStatus];

    // ④ 动作按钮（web 顺序：保存并连接 / 测试连接 / 清除 Key；窄卡自动折两行）
    NSButton *save = [NSButton buttonWithTitle:RLPTr(@"保存端点") target:self action:@selector(onLlmSave:)];
    save.bezelStyle = NSBezelStyleRounded;
    save.identifier = @"llm.save";
    NSButton *test = [NSButton buttonWithTitle:RLPTr(@"测试连通") target:self action:@selector(onLlmTest:)];
    test.bezelStyle = NSBezelStyleRounded;
    test.identifier = @"llm.test";
    NSButton *clearKey = [NSButton buttonWithTitle:RLPTr(@"清除密钥") target:self action:@selector(onLlmClearKey:)];
    clearKey.bezelStyle = NSBezelStyleRounded;
    clearKey.identifier = @"llm.clear";
    for (NSButton *b in @[ save, test, clearKey ]) {
        [b setContentHuggingPriority:NSLayoutPriorityDefaultHigh
                      forOrientation:NSLayoutConstraintOrientationHorizontal];
        [b setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    self.llmSaveBtn = save;
    self.llmTestBtn = test;
    self.llmClearBtn = clearKey;

    NSView *btnBox = [[NSView alloc] initWithFrame:NSZeroRect];
    btnBox.translatesAutoresizingMaskIntoConstraints = NO;
    NSStackView *btnRow1 = [[NSStackView alloc] initWithFrame:NSZeroRect];
    btnRow1.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    btnRow1.alignment = NSLayoutAttributeCenterY;
    btnRow1.spacing = 8;
    btnRow1.translatesAutoresizingMaskIntoConstraints = NO;
    [btnBox addSubview:btnRow1];
    [NSLayoutConstraint activateConstraints:@[
        [btnRow1.leadingAnchor constraintEqualToAnchor:btnBox.leadingAnchor],
        [btnRow1.trailingAnchor constraintLessThanOrEqualToAnchor:btnBox.trailingAnchor],
        [btnRow1.topAnchor constraintEqualToAnchor:btnBox.topAnchor],
    ]];
    NSStackView *btnRow2 = [[NSStackView alloc] initWithFrame:NSZeroRect];
    btnRow2.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    btnRow2.alignment = NSLayoutAttributeCenterY;
    btnRow2.spacing = 8;
    btnRow2.translatesAutoresizingMaskIntoConstraints = NO;
    self.metaAiBtnContainer = btnBox;
    self.metaAiBtnRow1 = btnRow1;
    self.metaAiBtnRow2 = btnRow2;
    [aiGroup addFullRow:btnBox];

    // ⑤ 模型：手填 + 下拉 + 刷新列表（窄卡或下拉显示时自动折行，隐藏下拉零占位但保留视图归卡）
    self.llmModel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.llmModel.placeholderString = @"deepseek-chat";
    self.llmModel.identifier = @"llm.modeltext";
    self.llmModel.target = self;
    self.llmModel.action = @selector(onLlmModelTyped:);
    RLPTuneMetaTextField(self.llmModel);
    self.llmModelPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.llmModelPopup.target = self;
    self.llmModelPopup.action = @selector(onLlmModelPicked:);
    self.llmModelPopup.identifier = @"llm.modelpopup";
    self.llmModelPopup.hidden = YES;
    RLPTuneMetaPopup(self.llmModelPopup);
    self.llmModelRefresh = [NSButton buttonWithTitle:RLPTr(@"刷新模型列表")
        target:self action:@selector(onLlmModelRefresh:)];
    self.llmModelRefresh.bezelStyle = NSBezelStyleRounded;
    self.llmModelRefresh.identifier = @"llm.modelrefresh";

    NSView *modelBox = [[NSView alloc] initWithFrame:NSZeroRect];
    modelBox.translatesAutoresizingMaskIntoConstraints = NO;
    NSView *modelDock = [[NSView alloc] initWithFrame:NSZeroRect];
    modelDock.translatesAutoresizingMaskIntoConstraints = NO;
    modelDock.hidden = YES;
    [modelBox addSubview:modelDock];
    NSStackView *modelRow1 = [[NSStackView alloc] initWithFrame:NSZeroRect];
    modelRow1.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    modelRow1.alignment = NSLayoutAttributeCenterY;
    modelRow1.spacing = 8;
    modelRow1.translatesAutoresizingMaskIntoConstraints = NO;
    [modelBox addSubview:modelRow1];
    [NSLayoutConstraint activateConstraints:@[
        [modelDock.leadingAnchor constraintEqualToAnchor:modelBox.leadingAnchor],
        [modelDock.topAnchor constraintEqualToAnchor:modelBox.topAnchor],
        [modelDock.widthAnchor constraintEqualToConstant:0],
        [modelDock.heightAnchor constraintEqualToConstant:0],
        [modelRow1.leadingAnchor constraintEqualToAnchor:modelBox.leadingAnchor],
        [modelRow1.trailingAnchor constraintEqualToAnchor:modelBox.trailingAnchor],
        [modelRow1.topAnchor constraintEqualToAnchor:modelBox.topAnchor],
    ]];
    NSStackView *modelRow2 = [[NSStackView alloc] initWithFrame:NSZeroRect];
    modelRow2.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    modelRow2.alignment = NSLayoutAttributeCenterY;
    modelRow2.spacing = 8;
    modelRow2.translatesAutoresizingMaskIntoConstraints = NO;
    self.metaModelContainer = modelBox;
    self.metaModelPrimaryRow = modelRow1;
    self.metaModelSecondaryRow = modelRow2;
    self.metaModelHiddenDock = modelDock;
    [aiGroup addWideField:RLPTr(@"LLM 模型") control:modelBox
                     hint:RLPTr(@"选择用于资料补全与增强的模型；读不到列表也可以直接手填")];

    self.llmModelMsg = RLPLabel(RLPTr(@"模型列表读取中"), t.small, t.mut);
    self.llmModelMsgIsWarn = NO;
    self.llmModelMsg.maximumNumberOfLines = 2;
    self.llmModelMsg.lineBreakMode = NSLineBreakByWordWrapping;
    self.llmModelMsg.identifier = @"llm.modelmsg";
    [self.llmModelMsg setContentCompressionResistancePriority:1.0f
                                               forOrientation:NSLayoutConstraintOrientationHorizontal];
    [aiGroup addNoteView:self.llmModelMsg];

    // ---- 标签写回（web sp_wbdesc / sp_wbdry / sp_wbapply / sp_wbmsg）----
    // web 把这块放在「元数据 · AI 接入」**同一张卡体内**（.mh.sub 子段，ui_script.h:10264-10272）。
    [aiGroup addSubHeader:RLPTr(@"标签写回") hint:RLPTr(@"默认开启")];

    self.wbDesc = RLPLabel(@"", t.small, t.mut);
    self.wbDesc.identifier = @"sp_wbdesc";
    self.wbDesc.maximumNumberOfLines = 4;
    self.wbDesc.lineBreakMode = NSLineBreakByWordWrapping;
    self.wbDesc.stringValue = RLPTr(@"补全到的标签 / 封面写回音频文件本身；写前校验音频数据逐位不变，原文件备份到备份目录");
    [self.wbDesc setContentCompressionResistancePriority:1.0f
                                          forOrientation:NSLayoutConstraintOrientationHorizontal];
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
    [self.writebackStatus setContentCompressionResistancePriority:1.0f
                                                   forOrientation:NSLayoutConstraintOrientationHorizontal];
    [aiGroup addNoteView:self.writebackStatus];

    // ── 联网检索端点（search / fetch 一起切换，对齐 web SEARCH 区块）──
    RLPSettingsGroup *searchGroup = (RLPSettingsGroup *)RLPSGroup(RLPTr(@"联网检索端点"),
        RLPTr(@"「AI 增强」整理资料时用的 search / fetch 端点。DeepSeek 为默认；切到 AnySearch / Tavily 后，非 DeepSeek 的 AI 接口也能联网检索。"), t);
    RLPTuneMetaGroup(searchGroup);
    if (gLastGroupWidthConstraint) {
        gLastGroupWidthConstraint.active = NO;
        gLastGroupWidthConstraint = nil;
    }
    self.metaSearchGroup = searchGroup;
    [adv addArrangedSubview:searchGroup];

    self.searchProviderPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.searchProviderPopup addItemWithTitle:RLPTr(@"DeepSeek（默认）")];
    [self.searchProviderPopup addItemWithTitle:@"AnySearch"];
    [self.searchProviderPopup addItemWithTitle:@"Tavily"];
    self.searchProviderPopup.identifier = @"search.provider";
    self.searchProviderPopup.target = self;
    self.searchProviderPopup.action = @selector(onSearchProviderChanged:);
    RLPTuneMetaPopup(self.searchProviderPopup);
    [searchGroup addField:RLPTr(@"检索端点") control:self.searchProviderPopup hint:nil];

    self.searchBase = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.searchBase.placeholderString = RLPTr(@"留空 = 用该厂商默认地址");
    self.searchBase.identifier = @"search.base";
    RLPTuneMetaTextField(self.searchBase);
    [searchGroup addField:RLPTr(@"检索地址") control:self.searchBase hint:nil];

    self.searchKey = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    self.searchKey.placeholderString = RLPTr(@"留空 = 保持已保存的检索 Key");
    self.searchKey.identifier = @"search.key";
    RLPTuneMetaTextField(self.searchKey);
    [searchGroup addField:RLPTr(@"检索 Key") control:self.searchKey hint:nil];

    self.searchStatus = RLPLabel(@"", t.small, t.mut);
    self.searchStatus.maximumNumberOfLines = 2;
    self.searchStatus.lineBreakMode = NSLineBreakByWordWrapping;
    self.searchStatus.identifier = @"search.status";
    [self.searchStatus setContentCompressionResistancePriority:1.0f
                                                forOrientation:NSLayoutConstraintOrientationHorizontal];
    [searchGroup addNoteView:self.searchStatus];

    NSButton *sSave = [NSButton buttonWithTitle:RLPTr(@"保存端点") target:self action:@selector(onSearchSave:)];
    sSave.bezelStyle = NSBezelStyleRounded;
    sSave.identifier = @"search.save";
    NSButton *sClear = [NSButton buttonWithTitle:RLPTr(@"清除检索 Key") target:self action:@selector(onSearchClearKey:)];
    sClear.bezelStyle = NSBezelStyleRounded;
    sClear.identifier = @"search.clear";
    [searchGroup addButtonRow:@[ sSave, sClear ]];

    // web `.meta-adv-grid`：始终装进 twoCol 容器，宽窗横向两列，窄窗/折叠态纵向单列。
    NSStackView *twoCol = [[NSStackView alloc] init];
    twoCol.orientation = NSUserInterfaceLayoutOrientationVertical;
    twoCol.distribution = NSStackViewDistributionFill;
    twoCol.alignment = NSLayoutAttributeLeading;
    twoCol.spacing = 22;
    twoCol.translatesAutoresizingMaskIntoConstraints = NO;
    twoCol.identifier = @"sp_metatwocol";
    [adv removeArrangedSubview:dataGroup];
    [adv removeArrangedSubview:aiGroup];
    [twoCol addArrangedSubview:dataGroup];
    [twoCol addArrangedSubview:aiGroup];
    [adv insertArrangedSubview:twoCol atIndex:0];
    self.metaTwoColStack = twoCol;

    gCurrentStack = savedStack;
    gCurrentGroup = savedGroup;
    [stack addArrangedSubview:adv];

    self.metaAdvWidthConstraint =
        [adv.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-48];
    self.metaTwoColWidthConstraint =
        [twoCol.widthAnchor constraintEqualToAnchor:adv.widthAnchor];
    self.metaSearchWidthConstraint =
        [searchGroup.widthAnchor constraintEqualToAnchor:adv.widthAnchor];
    self.metaVerticalCardWidthConstraints = @[
        [dataGroup.widthAnchor constraintEqualToAnchor:twoCol.widthAnchor],
        [aiGroup.widthAnchor constraintEqualToAnchor:twoCol.widthAnchor],
    ];

    [self restoreLlmModelStateIfNeeded];
    const BOOL laidOut = (self.paneHost && self.paneHost.bounds.size.width > 1.0);
    [self updateMetaResponsiveLayoutForHostWidth:[self metaTargetHostWidthPreferringViewBounds:laidOut]];
}

#pragma mark - 均衡 / 输入（已迁移的子界面）

- (void)fillEqualizer:(NSStackView *)stack t:(RLPTheme *)t {
    // web eqSettingsHtml() 是**两张** sgroup（卡片粒度逐条对齐）：
    //   ① 「参数均衡 PEQ（20 段 · HIFI）」
    //   ② 「耳机 EQ（OPRA 校准预设）」
    // 原生 1.1.7.38 及以前把两段塞进同一张卡（用户看到的是"一张卡里三块"）。
    // 现在：RLPEqualizerView 仍持同一份数据与交互，只是把 OPRA 段整段搬进第二张卡
    //（不复制控件、不复制请求）。
    RLPSettingsGroup *peqGroup = (RLPSettingsGroup *)RLPSGroup(
        RLPTr(@"参数均衡 PEQ（20 段 · HIFI）"),
        RLPTr(@"RBJ 双二阶 · 20 段 ISO 1/3 倍频程中心频率（20Hz~20kHz）· 采样率相关重建 · 参数热更新交叉淡入"), t);
    [stack addArrangedSubview:peqGroup];
    const BOOL reusingEq = (self.eqView != nil);
    if (!reusingEq) {
        self.eqView = [[RLPEqualizerView alloc] initWithFrame:NSMakeRect(0, 0, 620, 720)];
        self.eqView.translatesAutoresizingMaskIntoConstraints = NO;
        // 设置页本身就是整页滚动容器：EQ 不再套自己的滚动条（用户实测「只要外面那个滚动条」）。
        [self.eqView setEmbeddedInPage:YES];
    } else {
        if (self.eqHeightConstraint) {
            self.eqHeightConstraint.active = NO;
            self.eqHeightConstraint = nil;
        }
        [self.eqView removeFromSuperview];
        [self.eqView.opraSectionView removeFromSuperview];
        [self.eqView applyLanguage];
    }
    [peqGroup addFullRow:self.eqView];
    // 高度 = PEQ 段内容自然高度；reload 之后再校正一次（20 段参数文本就位后才准确）。
    self.eqHeightConstraint = [self.eqView.heightAnchor
        constraintEqualToConstant:MAX(420.0, [self.eqView preferredContentHeight])];
    [self.eqHeightConstraint setActive:YES];
    if (!reusingEq) {
        [self.eqView reload];
    }

    RLPSettingsGroup *opraGroup = (RLPSettingsGroup *)RLPSGroup(
        RLPTr(@"耳机 EQ（OPRA 校准预设）"), RLPTr(@"收录 6,230 款耳机专业校准滤波 · CC BY-SA 4.0"), t);
    [stack addArrangedSubview:opraGroup];
    // 把 OPRA 段从 EQ 视图里整段搬进第二张卡片（AppKit 重挂父视图，控件不复制）。
    [opraGroup addFullRow:self.eqView.opraSectionView];

    // ⚠️ 高度必须**双向**跟随内容，而且要在 OPRA 段被搬走之后重算一次。
    // 旧实现两个错：
    //   ① 只在 h > constant 时放大 ⟹ 内容变矮（OPRA 段整段搬去第二张卡）后
    //      旧的富余高度永远留着 ⟹ 卡片底部一大片空白（用户 2026-11-15 截图红框）；
    //   ② OPRA 卡片异步到达的型号/预设卡片从不通知父卡片重新量高 ⟹ 卡片高度还是
    //      "0 行"时算出的值，内容溢出卡片边框（同一张截图下半部分被遮挡）。
    __weak __typeof__(self) weakEq = self;
    self.eqView.onContentSizeChanged = ^{
        __typeof__(self) self2 = weakEq;
        if (!self2 || !self2.eqHeightConstraint || !self2.eqView) return;
        CGFloat h = MAX(420.0, [self2.eqView preferredContentHeight]);
        if (fabs(h - self2.eqHeightConstraint.constant) > 0.5) {
            self2.eqHeightConstraint.constant = h;
            [peqGroup contentDidChange];
        }
        [opraGroup contentDidChange];
    };
    self.eqView.onContentSizeChanged();
    dispatch_async(dispatch_get_main_queue(), ^{
        __typeof__(self) self3 = weakEq;
        if (!self3 || !self3.eqView) return;
        self3.eqView.onContentSizeChanged();
    });
}

/// 让校准卡高度回到「内容真正需要的高度」。
///
/// 为什么需要：校准视图的内容随向导步骤增删（生成计划 / 测量 / IR 段），
/// 高度约束如果只在建卡时定一次，后续内容变少时卡片不会回缩，就留下大片空白
/// （实测「房间校正」卡内约 187pt 纯空白，是用户在设置页能直接看到的空块）。
/// 这里只在**偏小时**抬高，绝不把卡片压得比内容还矮。
- (void)syncCalHeight {
    if (!self.calView || !self.calHeightConstraint) return;
    const CGFloat need = MAX(240.0, [self.calView preferredContentHeight]);
    // 双向校正：内容变多要抬高，内容变少（向导分支收起）也要收回来，
    // 否则卡片底部会留一大块空白（实测 130pt）。
    if (fabs(self.calHeightConstraint.constant - need) > 0.5) {
        self.calHeightConstraint.constant = need;
        [self.calView invalidateIntrinsicContentSize];
        [self.calView.superview setNeedsLayout:YES];
    }
}

- (void)fillCalibration:(NSStackView *)stack t:(RLPTheme *)t {
    // web calSettingsHtml() 是**三张** sgroup：
    //   ① 房间校正（测量向导） ② EQ 文件（REW / AutoEq 文本） ③ 房间校正 IR（WAV 脉冲响应）
    // 旧原生只有一张「声音校准」卡，且 web 的 sp_eq / sp_ir / sp_irgpu 在原生**只有
    // identifier 映射表里的字符串、屏幕上没有控件**（parity_scan 只认字面量 ⟹ 假绿）。
    // 本轮：三张卡 + 三个真控件（同一份视图，不复制逻辑）。
    RLPSettingsGroup *wizGroup = (RLPSettingsGroup *)RLPSGroup(
        RLPTr(@"房间校正（测量向导）"),
        RLPTr(@"Farina 对数扫频 → 反卷积 → 心理声学平滑 → 目标曲线 → 最小相位校正 FIR · 多声道 2.0~7.1.4"), t);
    [stack addArrangedSubview:wizGroup];
    self.calView = [[RLPCalibrationView alloc] initWithFrame:NSMakeRect(0, 0, 620, 620)];
    self.calView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.calView setEmbeddedInPage:YES];
    [wizGroup addFullRow:self.calView];
    // 高度必须跟着**当前实际内容**走，而不是建卡那一刻算出的常量。
    // 实测缺陷：常量在建卡时把当时所有分支（含未展开的向导步骤）都算进去，
    // 之后分支隐藏卡片却不回缩 ⟹ 「房间校正」卡里留下约 187pt 纯空白（截图量得）。
    // 这里用 >= 内容高度的下限 + 由内容驱动的 hugging，
    // 并在内容变化后（reloadData / 切换页签）重新校正一次。
    // 高度**等于**内容高度（不再是 >= 一个可能偏大的常量）：
    // 实测缺陷：常量在建卡时算成 450，而内容只需 320 ⟹ 卡内 130pt 纯空白。
    // >= 约束解决不了这个问题，因为常量本身就是错的；必须由内容反推。
    self.calHeightConstraint = [self.calView.heightAnchor
        constraintEqualToConstant:MAX(240.0, [self.calView preferredContentHeight])];
    [self.calHeightConstraint setActive:YES];
    // 内容变化后重新校正（见 syncCalHeight 注释）。
    [self syncCalHeight];

    // ② EQ 文件（REW / AutoEq 文本）：web 的 sp_eq 路径输入 + tip 说明。
    RLPSettingsGroup *eqFileGroup = (RLPSettingsGroup *)RLPSGroup(
        RLPTr(@"EQ 文件（REW / AutoEq 文本）"), RLPTr(@"按文件里的 Filter 行生成双二阶滤波器组"), t);
    [stack addArrangedSubview:eqFileGroup];
    // 不写死宽度：由卡片字段网格按列宽拉伸（web .sfld input{width:100%}）。
    NSTextField *eqPath = [[NSTextField alloc] initWithFrame:NSZeroRect];
    eqPath.identifier = @"sp_eq";
    eqPath.placeholderString = RLPTr(@"例如 /Users/你的用户名/Music/headphone-eq.txt");
    eqPath.target = self;
    eqPath.action = @selector(onEqPath:);
    [(NSTextFieldCell *)eqPath.cell setSendsActionOnEndEditing:YES];
    eqPath.translatesAutoresizingMaskIntoConstraints = NO;
    self.eqField = eqPath;
    [eqFileGroup addField:RLPTr(@"EQ 文件路径") control:self.eqField
                      hint:RLPTr(@"每行形如 Filter 1: ON PK Fc 1000 Hz Gain -3.0 dB Q 1.41")];

    // ③ 房间校正 IR（WAV 脉冲响应）：sp_ir 路径 + sp_irgpu 开关（都在 IR 段视图里）。
    RLPSettingsGroup *irGroup = (RLPSettingsGroup *)RLPSGroup(
        RLPTr(@"房间校正 IR（WAV 脉冲响应）"),
        RLPTr(@"把房间 / 耳机脉冲响应用 FIR 卷积叠进播放链路"), t);
    [stack addArrangedSubview:irGroup];
    [irGroup addFullRow:self.calView.irSectionView];

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
    NSString *previous = [RLPTheme themeName];
    [RLPTheme setThemeName:name];      // 乐观应用：点了立即生效（不闪一下再变）
    __weak __typeof__(self) weakSelf = self;
    [self postKey:@"theme" value:name completion:^(BOOL ok) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || ok) return;
        // 保存没落盘就不许留在界面上：主题只有**内存 + conf** 两份状态
        //（RLPTheme.mm:22 的 gThemeName 是内存态；/api/settings 的 theme 键是落盘的那一份），
        // POST 失败 ⟹ 这次切换没有任何一份被写下，界面上却已经换好了 = 假成功。
        // 退回原主题，RLPThemeDidChangeNotification 会把下拉也同步回 previous。
        [RLPTheme setThemeName:previous];
    }];
}

- (void)onLanguage:(id)sender {
    NSString *lang = (self.langPopup.indexOfSelectedItem == 1) ? @"en" : @"zh";
    __weak __typeof__(self) weakSelf = self;
    [self postKey:@"lang" value:lang completion:^(BOOL ok) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!ok) {
            // 语言没落盘就不能切界面（RLPSetLanguage 只改内存，真相源是 conf 的 lang）；
            // 同时把下拉退回**当前实际生效**的语言，否则下拉显示 en、界面还是中文 = 假成功。
            if (self_.langPopup)
                [self_.langPopup selectItemAtIndex:[RLPLanguage() isEqualToString:@"en"] ? 1 : 0];
            return;
        }
        RLPSetLanguage(lang);
        [[NSNotificationCenter defaultCenter] postNotificationName:RLPLanguageDidChangeNotification object:self_];
        RLPToast(RLPTr(@"已保存"));
    }];
}

- (void)onBackend:(id)sender {
    NSString *bk = self.backendPopup.titleOfSelectedItem ?: @"coreaudio";
    [self syncOutputBackendVisibility:bk];   // 乐观联显隐：选 upnp 就先把目标渲染器一行露出来
    __weak __typeof__(self) weakSelf = self;
    [self postKey:@"backend" value:bk completion:^(BOOL ok) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || ok) return;
        // 回滚已把下拉退回真值（applySettingsSaveFailure → revertControlsForBackendKey）；
        // 联动显隐必须跟着退回，否则 upnp 那一整行还停在"已切到 upnp"的样子。
        [self_ syncOutputBackendVisibility:self_.backendPopup.titleOfSelectedItem ?: @"coreaudio"];
    }];
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
    if (!self.devicePopup.selectedItem) return;
    // 发设备 id（web option value=id）；空串 = 默认设备。显示名只用于界面。
    id ro = self.devicePopup.selectedItem.representedObject;
    NSString *value = [ro isKindOfClass:[NSString class]] ? (NSString *)ro : @"";
    [self postKey:@"device" value:value];
}

- (void)onBits:(id)sender {
    NSString *v = self.bitsPopup.selectedItem.representedObject ?: self.bitsPopup.titleOfSelectedItem;
    if (v.length) [self postKey:@"bits" value:v];
}

- (void)onRate:(id)sender {
    NSString *v = self.ratePopup.selectedItem.representedObject ?: self.ratePopup.titleOfSelectedItem;
    if (v.length) [self postKey:@"rate" value:v];
}

/// U5（v3.3.11）：采样率族策略。发 representedObject（prefer/strict/compatible），
/// 绝不发中文标题 —— 后端只认这三个值，非法值会被 /api/settings 直接拒绝（不是静默回落）。
- (void)onRateFamily:(id)sender {
    NSString *v = self.rateFamilyPopup.selectedItem.representedObject
                  ?: self.rateFamilyPopup.titleOfSelectedItem;
    if (v.length) [self postKey:@"rateFamilyPolicy" value:v];
}

/// 1x 滤波器：**发 representedObject（原名）**。U8 起下拉文案带了「（族名）」，
/// 标题不再是值；旧实现发标题，改文案后会把「poly-sinc-lp（多相 sinc 线性相位）」发给后端。
- (void)onFilter1x:(id)sender {
    id ro = self.filt1xPopup.selectedItem.representedObject;
    NSString *value = [ro isKindOfClass:[NSString class]] ? (NSString *)ro
                     : (self.filt1xPopup.titleOfSelectedItem ?: @"");
    if (value.length) [self postKey:@"filter" value:value];
    [self refreshFilterFamilyNote];   // Nx 选中「跟随 1x」时，说明跟着 1x 走
}
/// Nx 滤波器：首项「跟随 1x」的值是空串（web filterNx 的 option value=""）。
/// 旧实现发中文标题，后端把「跟随 1x（不单独指定）」当成滤波器名。
- (void)onFilterNx:(id)sender {
    if (!self.filtNxPopup.selectedItem) return;
    id ro = self.filtNxPopup.selectedItem.representedObject;
    NSString *value = [ro isKindOfClass:[NSString class]] ? (NSString *)ro
                     : (self.filtNxPopup.indexOfSelectedItem == 0 ? @""
                        : (self.filtNxPopup.titleOfSelectedItem ?: @""));
    [self postKey:@"filterNx" value:value];
    [self refreshFilterFamilyNote];
}

/// 族说明以「实际生效的 Nx 滤波」为准：Nx 选中具体项就用它，选中「跟随 1x」就回落到 1x。
- (NSString *)effectiveFilterNameForNote {
    id nx = self.filtNxPopup.selectedItem.representedObject;
    if ([nx isKindOfClass:[NSString class]] && [(NSString *)nx length]) return nx;
    id ones = self.filt1xPopup.selectedItem.representedObject;
    return [ones isKindOfClass:[NSString class]] ? (NSString *)ones : @"";
}

/// U8：把 sp_filtNx_note 更新成当前生效滤波器的族说明（族 + 名字写明的相位）。
/// 没有可用的滤波器名（清单还没到）就隐藏 —— 不显示空白占位，也不猜一个族。
- (void)refreshFilterFamilyNote {
    if (!self.filtNxNote) return;
    NSString *name = [self effectiveFilterNameForNote];
    NSString *note = name.length ? RLPFilterFamilyNote(name) : @"";
    self.filtNxNote.stringValue = note ?: @"";
    self.filtNxNote.hidden = note.length == 0;
}

/// 后端纯数字契约：PCM ⟹ dsd=0；DSD ⟹ dsd=<rt>（64/128/256/512/1024）且 dsdnative=0（macOS 只 DoP）。
- (NSString *)dsdPersistValue {
    const BOOL isDsd = [self.outModePopup.titleOfSelectedItem isEqualToString:@"dsd"];
    if (!isDsd) return @"0";
    NSString *rt = self.dsdRatePopup.titleOfSelectedItem ?: @"";
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if (!rt.length || [rt rangeOfCharacterFromSet:nonDigits].location != NSNotFound) rt = @"256";
    return rt;
}

/// 在 PCM 下改比特率 / 封装 = 用户明确想要 DSD：把输出模式联动过去
/// （web onchange，ui_script.h:10465；旧原生不联动，界面会与落盘值互相打架）。
- (void)syncOutModeToDsd {
    if ([self.outModePopup.titleOfSelectedItem isEqualToString:@"dsd"]) return;
    if ([self.outModePopup itemWithTitle:@"dsd"]) {
        [self.outModePopup selectItemWithTitle:@"dsd"];
        RLPToast(RLPTr(@"输出模式已切到 DSD（SDM）"));
    }
}

/// 常驻说明只在 PCM 时显示（web applyDsdState 对 #sp_dsdmodenote 的 display:none）。
- (void)updateDsdModeNote {
    if (self.dsdModeNote)
        self.dsdModeNote.hidden = [self.outModePopup.titleOfSelectedItem isEqualToString:@"dsd"];
}

- (void)onDsdRate:(NSPopUpButton *)s {
    [self syncOutModeToDsd];
    [self updateDsdModeNote];
    [self postKeys:@{ @"dsd": [self dsdPersistValue], @"dsdnative": @"0" }];
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
        [self updateMetaResponsiveLayoutForHostWidth:[self metaTargetHostWidthPreferringViewBounds:(self.paneHost && self.paneHost.bounds.size.width > 1.0)]];
        self.llmModelMsg.stringValue = RLPTr(@"正在重新拉取模型列表…");
        self.llmModelMsg.textColor = [RLPTheme current].mut;
        self.llmModelMsgIsWarn = NO;
    }
    NSString *url = force ? @"/api/llm/models?refresh=1" : @"/api/llm/models";
    const NSTimeInterval t0 = [NSProcessInfo processInfo].systemUptime;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *models = [json[@"models"] isKindOfClass:[NSArray class]] ? json[@"models"] : @[];
        const BOOL ok = json && [json[@"ok"] boolValue] && models.count > 0;
        NSString *cur = [json[@"current"] isKindOfClass:[NSString class]] ? json[@"current"]
                        : (self_.llmModel.stringValue ?: @"");
        if (!ok) {
            const double durMs = ([NSProcessInfo processInfo].systemUptime - t0) * 1000.0;
            RLPDiagEvent(@"error", @"api_fail", @"settings:meta", @"/api/llm/models",
                         json ? 400 : 500, durMs, @"models_failed");
            // 降级：隐藏下拉、保留手填（值填当前 model，用户可改可留空）。
            self_.llmModelPopup.hidden = YES;
            [self_ updateMetaResponsiveLayoutForHostWidth:[self_ metaTargetHostWidthPreferringViewBounds:(self_.paneHost && self_.paneHost.bounds.size.width > 1.0)]];
            if (!self_.llmModel.stringValue.length && ![self_ isControlDirty:self_.llmModel]) {
                self_.llmModel.stringValue = cur;
            }
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : @"";
            self_.llmModelMsg.stringValue = err.length
                ? [RLPTr(@"拉取模型列表失败") stringByAppendingFormat:@"：%@", err]
                : RLPTr(@"服务端没有返回任何模型，可直接手填模型 id");
            self_.llmModelMsg.textColor = [RLPTheme current].warn;
            self_.llmModelMsgIsWarn = YES;
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
        if (![self_ isControlDirty:self_.llmModel]) {
            self_.llmModel.stringValue = cur;
            self_.lastLoadedValues[@"llm.modeltext"] = cur;
        }
        self_.llmModelPopup.hidden = NO;
        [self_ updateMetaResponsiveLayoutForHostWidth:[self_ metaTargetHostWidthPreferringViewBounds:(self_.paneHost && self_.paneHost.bounds.size.width > 1.0)]];
        const NSInteger n = (NSInteger)ids.count;
        if (cur.length && !hasCurrent) {
            self_.llmModelMsg.stringValue = [NSString stringWithFormat:
                RLPTr(@"已拉到 %ld 个模型，但当前模型不在列表里，建议重新选择（不会自动改配置）"), (long)n];
            self_.llmModelMsg.textColor = [RLPTheme current].warn;
            self_.llmModelMsgIsWarn = YES;
        } else {
            self_.llmModelMsg.stringValue = [NSString stringWithFormat:
                RLPTr(@"已拉到 %ld 个模型"), (long)n];
            self_.llmModelMsg.textColor = [RLPTheme current].mut;
            self_.llmModelMsgIsWarn = NO;
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
    ++self.llmSeq;
    NSString *body = [NSString stringWithFormat:@"model=%@", RLPEnc(m)];
    const NSTimeInterval t0 = [NSProcessInfo processInfo].systemUptime;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/llm" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        const BOOL ok = (json && [json[@"ok"] boolValue]);
        if (ok) {
            [self_ clearDirtyControlId:@"llm.modeltext" expectedValue:m];
        } else {
            const double durMs = ([NSProcessInfo processInfo].systemUptime - t0) * 1000.0;
            RLPDiagEvent(@"error", @"api_fail", @"settings:meta", @"/api/llm",
                         json ? 400 : 500, durMs, @"model_save_failed");
        }
        self_.llmStatus.stringValue = ok
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
    [self.dirtyControlIds addObject:@"llm.modeltext"];
    ++self.llmSeq;
    NSString *body = [NSString stringWithFormat:@"model=%@", RLPEnc(title)];
    const NSTimeInterval t0 = [NSProcessInfo processInfo].systemUptime;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/llm" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        const BOOL ok = (json && [json[@"ok"] boolValue]);
        if (ok) {
            [self_ clearDirtyControlId:@"llm.modeltext" expectedValue:title];
        } else {
            const double durMs = ([NSProcessInfo processInfo].systemUptime - t0) * 1000.0;
            RLPDiagEvent(@"error", @"api_fail", @"settings:meta", @"/api/llm",
                         json ? 400 : 500, durMs, @"model_pick_failed");
        }
        self_.llmStatus.stringValue = ok
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
    ++self.llmSeq;
    self.llmStatus.stringValue = RLPTr(@"保存中…");
    const NSTimeInterval t0 = [NSProcessInfo processInfo].systemUptime;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/llm" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            NSString *curKey = [self_.llmKey.stringValue stringByTrimmingCharactersInSet:
                                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([curKey isEqualToString:key]) {
                self_.llmKey.stringValue = @"";   // 存完立刻清掉输入框，不留明文在界面上
                [self_.dirtyControlIds removeObject:@"llm.key"];
                self_.lastLoadedValues[@"llm.key"] = @"";
            }
            if (base.length) {
                self_.llmSavedBase = base;
                [self_ clearDirtyControlId:@"llm.base" expectedValue:base];
            }
            self_.llmStatus.stringValue = key.length ? RLPTr(@"API Key 已保存（界面只显示掩码）")
                                                     : RLPTr(@"API 地址已保存");
            // 端点可能换了 ⟹ 模型清单必然过期，强制重拉；再顺手测一次连通（web llmSave 同口径）。
            [self_ loadLlmConfig];
            [self_ loadLlmModels:YES];
            [self_ runLlmTestSilently];
        } else {
            const double durMs = ([NSProcessInfo processInfo].systemUptime - t0) * 1000.0;
            RLPDiagEvent(@"error", @"api_fail", @"settings:meta", @"/api/llm",
                         json ? 400 : 500, durMs, @"llm_save_failed");
            self_.llmStatus.stringValue = [json[@"error"] isKindOfClass:[NSString class]]
                ? json[@"error"] : RLPTr(@"保存失败");
        }
    }];
}

/// 清除 API Key（web llmClear：POST clear=1）。
- (void)onLlmClearKey:(id)sender {
    (void)sender;
    if (![RLPCoreClient shared].started) return;
    NSString *submittedKey = [self.llmKey.stringValue stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    ++self.llmSeq;
    const NSTimeInterval t0 = [NSProcessInfo processInfo].systemUptime;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/llm" body:@"clear=1" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            NSString *curKey = [self_.llmKey.stringValue stringByTrimmingCharactersInSet:
                                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([curKey isEqualToString:submittedKey]) {
                [self_.dirtyControlIds removeObject:@"llm.key"];
                if (!curKey.length) self_.lastLoadedValues[@"llm.key"] = @"";
            }
        } else {
            const double durMs = ([NSProcessInfo processInfo].systemUptime - t0) * 1000.0;
            RLPDiagEvent(@"error", @"api_fail", @"settings:meta", @"/api/llm",
                         json ? 400 : 500, durMs, @"llm_clear_failed");
        }
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

static NSString *RLPLlmHostOf(NSString *u) {
    NSString *s = [(u ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!s.length) return @"";
    NSRange scheme = [s rangeOfString:@"://"];
    if (scheme.location != NSNotFound) {
        s = [s substringFromIndex:NSMaxRange(scheme)];
    }
    NSCharacterSet *stops = [NSCharacterSet characterSetWithCharactersInString:@"/?#"];
    NSRange cut = [s rangeOfCharacterFromSet:stops];
    if (cut.location != NSNotFound) {
        s = [s substringToIndex:cut.location];
    }
    return s.lowercaseString;
}

static NSInteger RLPLlmProviderIndexForBaseUrl(NSString *baseUrl) {
    NSString *h = RLPLlmHostOf(baseUrl);
    if (!h.length) return 0;   // 留空 = 走默认端点（DeepSeek）
    for (NSInteger i = 0; i < 5; ++i) {
        if ([RLPLlmHostOf(RLPLlmPresetUrlAtIndex(i)) isEqualToString:h]) return i;
    }
    return 5;   // 自定义
}

/// 选中预设只填地址，不保存、不测连通（web llmApplyProvider 同口径）。
- (void)onLlmProviderPicked:(NSPopUpButton *)sender {
    NSString *url = RLPLlmPresetUrlAtIndex(sender.indexOfSelectedItem);
    if (!url.length) return;   // 自定义：绝不覆盖用户已填的地址
    self.llmBase.stringValue = url;
    if (self.llmBase.identifier.length) [self.dirtyControlIds addObject:self.llmBase.identifier];
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
    ++self.llmSeq;
    self.searchStatus.stringValue = RLPTr(@"保存中…");
    const NSTimeInterval t0 = [NSProcessInfo processInfo].systemUptime;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/llm" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            NSString *curKey = [self_.searchKey.stringValue stringByTrimmingCharactersInSet:
                                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([curKey isEqualToString:key]) {
                self_.searchKey.stringValue = @"";   // 明文绝不留在界面上
                [self_.dirtyControlIds removeObject:@"search.key"];
                self_.lastLoadedValues[@"search.key"] = @"";
            }
            [self_ clearDirtyControlId:@"search.base" expectedValue:base];
            self_.searchStatus.stringValue = RLPTr(@"检索端点已保存");
            [self_ loadLlmConfig];
        } else {
            const double durMs = ([NSProcessInfo processInfo].systemUptime - t0) * 1000.0;
            RLPDiagEvent(@"error", @"api_fail", @"settings:meta", @"/api/llm",
                         json ? 400 : 500, durMs, @"search_save_failed");
            self_.searchStatus.stringValue = [json[@"error"] isKindOfClass:[NSString class]]
                ? json[@"error"] : RLPTr(@"保存失败");
        }
    }];
}

/// 清除检索 Key（web searchClear：POST search_key_clear=1，与清 LLM key 分开）。
- (void)onSearchClearKey:(id)sender {
    (void)sender;
    if (![RLPCoreClient shared].started) return;
    NSString *submittedKey = [self.searchKey.stringValue stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    ++self.llmSeq;
    const NSTimeInterval t0 = [NSProcessInfo processInfo].systemUptime;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/llm" body:@"search_key_clear=1"
                          completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            NSString *curKey = [self_.searchKey.stringValue stringByTrimmingCharactersInSet:
                                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([curKey isEqualToString:submittedKey]) {
                [self_.dirtyControlIds removeObject:@"search.key"];
                if (!curKey.length) self_.lastLoadedValues[@"search.key"] = @"";
            }
        } else {
            const double durMs = ([NSProcessInfo processInfo].systemUptime - t0) * 1000.0;
            RLPDiagEvent(@"error", @"api_fail", @"settings:meta", @"/api/llm",
                         json ? 400 : 500, durMs, @"search_clear_failed");
        }
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
    const NSTimeInterval t0 = [NSProcessInfo processInfo].systemUptime;
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
            const double durMs = ([NSProcessInfo processInfo].systemUptime - t0) * 1000.0;
            RLPDiagEvent(@"error", @"api_fail", @"settings:meta", @"/api/llm/test",
                         json ? 400 : 500, durMs, @"llm_test_failed");
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"未知错误");
            self_.llmStatus.stringValue = [RLPTr(@"连接失败：") stringByAppendingString:err];
        }
    }];
}

- (void)loadLlmConfig {
    if (![RLPCoreClient shared].started || !self.llmStatus) return;
    const NSUInteger seq = ++self.llmSeq;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/llm" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || !json || seq != self_.llmSeq) return;
        // 只覆盖响应里真有的字段（POST 回包与 GET 未必同形，缺字段不当成清空）
        if ([json[@"baseUrl"] isKindOfClass:[NSString class]]) {
            NSString *baseUrl = json[@"baseUrl"];
            self_.llmSavedBase = baseUrl;   // 「拉模型」要能判断屏幕上的地址是否已落盘
            if (![self_ isControlDirty:self_.llmBase]) {
                self_.llmBase.stringValue = baseUrl;
                self_.lastLoadedValues[@"llm.base"] = baseUrl;
                if (self_.llmProviderPopup) {
                    [self_.llmProviderPopup selectItemAtIndex:RLPLlmProviderIndexForBaseUrl(baseUrl)];
                }
            }
        }
        if ([json[@"model"] isKindOfClass:[NSString class]] && ![self_ isControlDirty:self_.llmModel]) {
            self_.llmModel.stringValue = json[@"model"];
            self_.lastLoadedValues[@"llm.modeltext"] = json[@"model"];
        }
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
            !self_.searchBase.stringValue.length &&
            ![self_ isControlDirty:self_.searchBase]) {
            self_.searchBase.stringValue = json[@"searchBaseUrl"];
            self_.lastLoadedValues[@"search.base"] = json[@"searchBaseUrl"];
        }
        NSString *sMasked = [json[@"searchMasked"] isKindOfClass:[NSString class]] ? json[@"searchMasked"] : @"";
        NSString *provName = self_.searchProviderPopup.titleOfSelectedItem ?: @"DeepSeek";
        self_.searchStatus.stringValue = sMasked.length
            ? [NSString stringWithFormat:@"%@ · Key %@", provName, sMasked]
            : provName;
        // 进页顺带拉一次模型列表（web llmModelsLoad(false) 同口径）。
        // 主题切换重建设置页后保留已捕获的下拉快照，并在 meta 进页自动拉取前消费一次抑制标志。
        if (self_.tab == RLPSTabMeta || self_.paneCache[@(RLPSTabMeta)] != nil) {
            if (self_.suppressNextLlmAutoLoad) {
                self_.suppressNextLlmAutoLoad = NO;
            } else {
                [self_ loadLlmModels:NO];
            }
        }
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
    const NSTimeInterval t0 = [NSProcessInfo processInfo].systemUptime;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/writeback?dry=1" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        [self_ wbSetBusy:NO];
        if (!json || ![json[@"ok"] boolValue]) {
            const double durMs = ([NSProcessInfo processInfo].systemUptime - t0) * 1000.0;
            RLPDiagEvent(@"error", @"api_fail", @"settings:meta", @"/api/writeback",
                         json ? 400 : 500, durMs, @"writeback_dry_failed");
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
    const NSTimeInterval t0 = [NSProcessInfo processInfo].systemUptime;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/writeback" body:@"{\"apply\":true}"
                          completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        const BOOL started = json && [json[@"ok"] boolValue] && [json[@"started"] boolValue];
        if (!started) {
            const double durMs = ([NSProcessInfo processInfo].systemUptime - t0) * 1000.0;
            RLPDiagEvent(@"error", @"api_fail", @"settings:meta", @"/api/writeback",
                         json ? 400 : 500, durMs, @"writeback_apply_failed");
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
    RLPDiagEvent(@"action", @"update_check", @"settings:diag", nil, 0, -1, @"manual");
    [[RLPUpdateWindowController shared] checkManually:YES];
}

- (void)onExportDiagZip:(id)sender { [self exportDiagAsZip:YES]; }

/// zip = YES 走 /api/diagzip（压缩包），NO 走 /api/diag（单个 JSON）。
- (void)exportDiagAsZip:(BOOL)zip {
    // /api/diagzip 回的是 ZIP 原始字节（不是 JSON）⟹ 必须走 getData。
    // 不假装成功：取字节失败、用户取消、写盘失败三种情况分别如实说明。
    const NSTimeInterval t0 = [NSProcessInfo processInfo].systemUptime;
    __weak __typeof__(self) weakSelf = self;
    if (!zip) {
        RLPDiagEvent(@"action", @"diag_json", @"settings:diag", @"/api/diag", 0, -1, @"start");
        __weak __typeof__(self) weakSelf2 = self;
        [[RLPCoreClient shared] getJSON:@"/api/diag" completion:^(NSDictionary * _Nullable json) {
            __typeof__(self) self2 = weakSelf2;
            if (!self2) return;
            const double durMs = ([NSProcessInfo processInfo].systemUptime - t0) * 1000.0;
            if (!json) {
                RLPDiagEvent(@"error", @"api_fail", @"settings:diag", @"/api/diag", 500, durMs, @"empty_response");
                RLPToast(RLPTr(@"诊断 JSON 导出失败"));
                return;
            }
            NSData *d = [NSJSONSerialization dataWithJSONObject:json
                options:NSJSONWritingPrettyPrinted error:nil];
            NSSavePanel *panel = [NSSavePanel savePanel];
            panel.nameFieldStringValue = @"rlplayer-diag.json";
            if ([panel runModal] != NSModalResponseOK || !panel.URL) {
                RLPDiagEvent(@"action", @"diag_json", @"settings:diag", @"/api/diag", 0, durMs, @"cancelled");
                return;
            }
            if (![d writeToURL:panel.URL options:NSDataWritingAtomic error:nil]) {
                RLPDiagEvent(@"error", @"diag_json", @"settings:diag", @"/api/diag", 0, durMs, @"write_failed");
                RLPToast(RLPTr(@"写入失败"));
                return;
            }
            RLPDiagEvent(@"action", @"diag_json", @"settings:diag", @"/api/diag", 200, durMs, @"ok");
            RLPToast([NSString stringWithFormat:RLPTr(@"已导出 %@"), panel.URL.lastPathComponent]);
        }];
        return;
    }
    RLPDiagEvent(@"action", @"diag_export", @"settings:diag", @"/api/diagzip", 0, -1, @"start");
    [[RLPCoreClient shared] getData:@"/api/diagzip" completion:^(NSData * _Nullable data) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        const double durMs = ([NSProcessInfo processInfo].systemUptime - t0) * 1000.0;
        if (!data.length) {
            RLPDiagEvent(@"error", @"api_fail", @"settings:diag", @"/api/diagzip", 500, durMs, @"empty_response");
            RLPToast(RLPTr(@"诊断包导出失败"));
            return;
        }
        // 服务端超预算时回的是 JSON 错误报文（不是 ZIP）。不能把它存成 .zip 假装成功；
        // 也顺手兜住 8 MiB 上限（与反馈通道同一闸门，P0-2）。
        const NSUInteger nbytes = data.length;
        const unsigned char *pb = (const unsigned char *)data.bytes;
        const bool isZip = nbytes >= 4 && pb[0] == 'P' && pb[1] == 'K' && pb[2] == 3 && pb[3] == 4;
        if (!isZip || nbytes > 8u * 1024u * 1024u) {
            RLPDiagEvent(@"error", @"diag_export", @"settings:diag", @"/api/diagzip",
                         422, durMs, !isZip ? @"invalid_zip" : @"too_large");
            RLPToast(RLPTr(@"诊断包导出失败"));
            return;
        }
        NSSavePanel *panel = [NSSavePanel savePanel];
        panel.nameFieldStringValue = @"rlplayer-diag.zip";
        if ([panel runModal] != NSModalResponseOK || !panel.URL) {
            RLPDiagEvent(@"action", @"diag_export", @"settings:diag", @"/api/diagzip", 0, durMs, @"cancelled");
            return;
        }
        NSError *err = nil;
        if (![data writeToURL:panel.URL options:NSDataWritingAtomic error:&err]) {
            RLPDiagEvent(@"error", @"diag_export", @"settings:diag", @"/api/diagzip", 0, durMs, @"write_failed");
            RLPToast(err.localizedDescription ?: RLPTr(@"写入失败"));
            return;
        }
        RLPDiagEvent(@"action", @"diag_export", @"settings:diag", @"/api/diagzip", 200, durMs, @"ok");
        // 提示里写**真实字节数**（UI 文案必须与落盘大小一致；MB 只是人类可读换算）。
        NSString *name = panel.URL.lastPathComponent;
        RLPToast([NSString stringWithFormat:@"%@  %.2f MB",
                  [NSString stringWithFormat:RLPTr(@"已导出 %@"), name],
                  (double)nbytes / (1024.0 * 1024.0)]);
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
        RLPDiagEvent(@"action", @"fb_send", @"settings:diag", nil, 0, -1, @"blank");
        [self fbResultText:RLPTr(@"请先写下反馈内容再发送") kind:2];
        [self.fbText.window makeFirstResponder:self.fbText];
        return;
    }
    const NSUInteger bytes = [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (bytes > rta::feedback::kFeedbackMaxTextBytes) {
        RLPDiagEvent(@"action", @"fb_send", @"settings:diag", nil, 0, -1, @"too_large");
        NSString *line = [NSString stringWithFormat:@"%@%llu%@%lu%@",
                          RLPTr(@"内容超过 "), (unsigned long long)rta::feedback::kFeedbackMaxTextBytes,
                          RLPTr(@" 字节（当前 "), (unsigned long)bytes, RLPTr(@"），请精简后再发")];
        [self fbResultText:line kind:2];
        return;
    }
    // web 同一道闸门：只有**探活成功**（==1）才发，null/失败一律拒。
    if (self.fbServerOK != 1) {
        RLPDiagEvent(@"action", @"fb_send", @"settings:diag", nil, 0, -1, @"channel_unavailable");
        [self fbResultText:RLPTr(@"反馈后台当前不可用，请稍后再试") kind:2];
        return;
    }
    const BOOL wantDiag = (self.fbDiagSwitch.state == NSControlStateValueOn);
    RLPDiagEvent(@"action", @"fb_send", @"settings:diag", nil, 0, -1, wantDiag ? @"start_diag" : @"start");
    self.fbSending = YES;
    [self fbResultText:(wantDiag ? RLPTr(@"正在打包诊断包并上传…") : RLPTr(@"正在上传…")) kind:0];
    [self fbUpdateSendEnabled];

    if (!wantDiag) { [self fbUploadText:text diagJson:@"" attach:NO]; return; }
    const NSTimeInterval diagT0 = [NSProcessInfo processInfo].systemUptime;
    __weak __typeof__(self) weakSelf = self;
    // 诊断包走 /api/diagjson（与「导出诊断包」同一份组装 + 脱敏），不自己拼现场。
    [[RLPCoreClient shared] getData:@"/api/diagjson" completion:^(NSData * _Nullable data) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSString *diag = data.length
            ? ([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"") : @"";
        if (!diag.length) {
            const double durMs = ([NSProcessInfo processInfo].systemUptime - diagT0) * 1000.0;
            RLPDiagEvent(@"error", @"api_fail", @"settings:diag", @"/api/diagjson", 500, durMs, @"empty_response");
            [self_ fbResultText:RLPTr(@"诊断包读取失败，将只提交正文") kind:0];
        }
        [self_ fbUploadText:text diagJson:diag attach:(diag.length > 0)];
    }];
}

/// 真正上传：请求体校验/JSON/base64/幂等键全部走 src/net/feedback_api.h（有离线单测）。
/// 成功判定**只看 body.ok**，绝不把 HTTP 200 当成功（后台 200 也用于幂等重放）。
- (void)fbUploadText:(NSString *)text diagJson:(NSString *)diag attach:(BOOL)attach {
    NSString *client = [self feedbackInstallId];
    if (!client.length) {
        RLPDiagEvent(@"error", @"fb_send", @"settings:diag", nil, 0, -1, @"install_id_invalid");
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
        RLPDiagEvent(@"error", @"fb_send", @"settings:diag", nil, 0, -1, @"build_failed");
        self.fbSending = NO;
        NSString *err = [NSString stringWithUTF8String:built.error.c_str()] ?: RLPTr(@"反馈内容不合法");
        [self fbResultText:err kind:2];
        [self fbUpdateSendEnabled];
        return;
    }

    const std::string bodyCpp = built.json;
    NSString *bodyStr = [NSString stringWithUTF8String:bodyCpp.c_str()] ?: @"";
    NSString *url = [NSString stringWithUTF8String:rta::feedback::kFeedbackUploadUrl] ?: @"";
    const NSTimeInterval t0 = [NSProcessInfo processInfo].systemUptime;

    __weak __typeof__(self) weakSelf = self;
    void (^reply)(NSInteger, NSData *) = ^(NSInteger status, NSData *body) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __typeof__(self) self_ = weakSelf;
            if (!self_) return;
            const double durMs = ([NSProcessInfo processInfo].systemUptime - t0) * 1000.0;
            NSString *rawStr = body.length
                ? ([[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @"") : @"";
            const std::string raw = rawStr.UTF8String ?: "";
            const auto r = rta::feedback::parse_feedback_upload_reply((int)status, raw);
            self_.fbSending = NO;
            if (r.ok) {
                RLPDiagEvent(@"action", @"fb_send", @"settings:diag", nil,
                             status > 0 ? status : 200, durMs, @"ok");
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
                NSString *errCode = !r.code.empty()
                    ? ([NSString stringWithUTF8String:r.code.c_str()] ?: @"upload_failed")
                    : [NSString stringWithFormat:@"http_%ld", (long)status];
                RLPDiagEvent(@"error", @"fb_send", @"settings:diag", nil, status, durMs, errCode);
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

/// 跨页面设置/配置档保存后重读设置（忽略自己与 eqView 发出的通知防环）。
- (void)onExternalSettingsChanged:(NSNotification *)note {
    if (note.object == self || (self.eqView && note.object == self.eqView)) return;
    if (![RLPCoreClient shared].started) return;
    [self reloadData];
}

- (void)activate {
    NSString *paneKey = [self currentPaneKey] ?: @"adv";
    RLPDiagEvent(@"action", @"settings_open",
                 [NSString stringWithFormat:@"settings:%@", paneKey], nil, 0, -1, nil);
    [self reloadData];
    [self wbSyncBusy];
}

- (void)reloadData {
    [self reloadDataIncludingEqualizer:YES];
}

- (void)reloadDataIncludingEqualizer:(BOOL)reloadEq {
    if (![RLPCoreClient shared].started) {
        self.statusLine.stringValue = RLPTr(@"核心未启动");
        return;
    }
    const NSTimeInterval t0 = [NSProcessInfo processInfo].systemUptime;
    __weak __typeof__(self) weakSelf = self;

    [[RLPCoreClient shared] getJSON:@"/api/devices" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        id devs = json[@"devices"];
        if (![devs isKindOfClass:[NSArray class]]) {
            const double durMs = ([NSProcessInfo processInfo].systemUptime - t0) * 1000.0;
            RLPDiagEvent(@"error", @"api_fail",
                         [NSString stringWithFormat:@"settings:%@", [self_ currentPaneKey] ?: @"adv"],
                         @"/api/devices", json ? 400 : 500, durMs, @"devices_failed");
            return;
        }
        [self_.devicePopup removeAllItems];
        [self_.inDevicePopup removeAllItems];
        // web #sp_device：首项 value="" 的「默认设备」，设备项 value = 稳定 id
        //（ui_script.h:5318 / 5337）。旧实现只填显示名 ⟹ 选中后 POST 的也是显示名，
        // 后端按 id 解析（rtaweb.cpp:2764），名字匹配只能算兜底。
        [self_.devicePopup addItemWithTitle:RLPTr(@"默认设备")];
        [[self_.devicePopup itemAtIndex:0] setRepresentedObject:@""];
        for (id d in (NSArray *)devs) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            NSString *name = d[@"name"];
            if (!name.length) continue;
            NSString *did = [d[@"id"] isKindOfClass:[NSString class]] ? d[@"id"] : @"";
            [self_.devicePopup addItemWithTitle:name];
            if (did.length)
                [[self_.devicePopup itemAtIndex:self_.devicePopup.numberOfItems - 1]
                    setRepresentedObject:did];
            [self_.inDevicePopup addItemWithTitle:name];
        }
        if (!self_.inDevicePopup.numberOfItems) [self_.inDevicePopup addItemWithTitle:RLPTr(@"默认输入设备")];
        // settings 的 GET 可能比设备列表先到：按记下的 id 再回显一次。
        [self_ selectSavedDevice];
    }];

    [[RLPCoreClient shared] getJSON:@"/api/filters" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json) {
            const double durMs = ([NSProcessInfo processInfo].systemUptime - t0) * 1000.0;
            RLPDiagEvent(@"error", @"api_fail",
                         [NSString stringWithFormat:@"settings:%@", [self_ currentPaneKey] ?: @"adv"],
                         @"/api/filters", 500, durMs, @"filters_failed");
            return;
        }
        NSArray *items = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : nil;
        if (!items.count) return;
        [self_.filt1xPopup removeAllItems];
        [self_.filtNxPopup removeAllItems];
        // Nx 的「跟随 1x」是**空值首项**（web sel('sp_filtNx', ..., 空 option)）。
        // 旧实现 removeAllItems 后只塞滤波器名 ⟹ 首项变成某个滤波器，「跟随 1x」凭空消失，
        // 用户以为它还在选中，实际 POST 的是某个滤波器名。
        [self_.filtNxPopup addItemWithTitle:RLPTr(@"跟随 1x（不单独指定）")];
        [[self_.filtNxPopup itemAtIndex:0] setRepresentedObject:@""];
        // SDM 页的 Oversampling 1x / Nx 用的是同一份滤波器清单
        //（web：sel('sp_sdmo1', ...) 与 1x/Nx 共用 FILTER_OPTS）。
        // 旧原生只填了 PCM 页那两个，SDM 页两个永远停在「读取中…」。
        [self_.sdmO1Popup removeAllItems];
        [self_.sdmONxPopup removeAllItems];
        [self_.sdmO1Popup addItemWithTitle:RLPTr(@"跟随 PCM 页的 1x")];
        [[self_.sdmO1Popup itemAtIndex:0] setRepresentedObject:@""];
        [self_.sdmONxPopup addItemWithTitle:RLPTr(@"跟随上面的 1x")];
        [[self_.sdmONxPopup itemAtIndex:0] setRepresentedObject:@""];
        for (id it in items) {
            NSString *name = [it isKindOfClass:[NSDictionary class]] ? it[@"name"]
                             : ([it isKindOfClass:[NSString class]] ? it : nil);
            if (!name.length) continue;
            // U8（2026-11-16）：文案 = 原名（族名[ 相位名]），**值仍是原名**。
            // 族名由 filter_family.h 按名字前缀判（后端 /api/filters 的 familyLabel 同源），
            // 这里本地再算一次是为了让英文界面能按词条翻译括号里的族名。
            NSString *title = RLPFilterDecoratedTitle(name);
            [self_.filt1xPopup addItemWithTitle:title];
            [[self_.filt1xPopup itemAtIndex:self_.filt1xPopup.numberOfItems - 1]
                setRepresentedObject:name];
            [self_.filtNxPopup addItemWithTitle:title];
            [[self_.filtNxPopup itemAtIndex:self_.filtNxPopup.numberOfItems - 1]
                setRepresentedObject:name];
            [self_.sdmO1Popup addItemWithTitle:title];
            [[self_.sdmO1Popup itemAtIndex:self_.sdmO1Popup.numberOfItems - 1]
                setRepresentedObject:name];
            [self_.sdmONxPopup addItemWithTitle:title];
            [[self_.sdmONxPopup itemAtIndex:self_.sdmONxPopup.numberOfItems - 1]
                setRepresentedObject:name];
        }
        // /api/settings 与 /api/filters 是两个并发 GET：清单后到时按记下的 kv 值重选，
        // 否则回显会被刚重建的列表冲回第一项（旧实现只填项、不回显）。
        if (self_.savedFilterNx)
            [self_ applyKV:@{ @"filterNx": self_.savedFilterNx }
                  toPopup:self_.filtNxPopup key:@"filterNx"];
        if (self_.savedFilter.length)
            [self_ applyKV:@{ @"filter": self_.savedFilter }
                  toPopup:self_.filt1xPopup key:@"filter"];
        if (self_.savedSdmFilter)
            [self_ applyKV:@{ @"sdmfilt": self_.savedSdmFilter }
                  toPopup:self_.sdmO1Popup key:@"sdmfilt"];
        if (self_.savedSdmFilterNx)
            [self_ applyKV:@{ @"sdmfiltnx": self_.savedSdmFilterNx }
                  toPopup:self_.sdmONxPopup key:@"sdmfiltnx"];
        // 回填之后族说明要跟上（否则第一个选中项有说明、回填后的没有）。
        [self_ refreshFilterFamilyNote];
    }];

    // 设置：以 kv 为准回填。读不到就不回填 —— 绝不把 UI 默认值写回去覆盖用户设置。
    // 只与其它读回比较序号（保存另有 settingsPostSeq），并按「发出时刻之后是否被保存过」逐键过滤。
    const NSUInteger seq = ++self.settingsGetSeq;
    const NSTimeInterval getIssueAt = [NSProcessInfo processInfo].systemUptime;
    [[RLPCoreClient shared] getJSON:@"/api/settings" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        std::fprintf(stderr, "[DIAG] GET completion seq=%lu cur=%lu\n", (unsigned long)seq, (unsigned long)self_.settingsGetSeq);
        if (!self_ || seq != self_.settingsGetSeq) return;
        NSDictionary *rawKV = [json[@"kv"] isKindOfClass:[NSDictionary class]] ? json[@"kv"] : nil;
        if (!rawKV) {
            const double durMs = ([NSProcessInfo processInfo].systemUptime - getIssueAt) * 1000.0;
            RLPDiagEvent(@"error", @"api_fail",
                         [NSString stringWithFormat:@"settings:%@", [self_ currentPaneKey] ?: @"adv"],
                         @"/api/settings", json ? 400 : 500, durMs, @"settings_read_failed");
            self_.statusLine.stringValue = RLPTr(@"设置读取失败");
            return;
        }
        // 只跳过「本次读回发出之后又被保存过」的键（那些值由保存本身负责刷新），
        // 而不是因为期间有过保存就把整包丢掉（2026-11-18 夜间评审 A2）。
        NSMutableDictionary *kvFiltered = [rawKV mutableCopy];
        for (NSString *k in rawKV) {
            NSNumber *postedAt = self_.settingsKeyPostAt[k];
            if (postedAt && postedAt.doubleValue > getIssueAt) [kvFiltered removeObjectForKey:k];
        }
        NSDictionary *kv = kvFiltered;
        // U12（2026-11-16）：拐点准入提示由同一份 GET 的顶层 sdm 对象驱动；
        // 读不到就隐藏（不回落到"猜一个阈值"，那会让 UI 与后端策略分叉）。
        NSDictionary *sdm = [json[@"sdm"] isKindOfClass:[NSDictionary class]] ? json[@"sdm"] : nil;
        self_.sdmAdmission = sdm;
        [self_ applySdmAdmission:sdm];
        [self_ applyKV:kv toSwitch:self_.hogSwitch key:@"hogexcl"];
        [self_ applyKV:kv toSwitch:self_.loudSwitch key:@"loudness"];
        [self_ applyKV:kv toSwitch:self_.ispSwitch key:@"isp"];
        [self_ applyKV:kv toSwitch:self_.twoStageSwitch key:@"twostage"];
        [self_ applyKV:kv toSwitch:self_.directSdmSwitch key:@"directsdm"];
        [self_ applyKV:kv toSwitch:self_.inMonitorSwitch key:@"inmon"];
        [self_ applyKV:kv toSwitch:self_.betaSwitch key:@"updbeta"];
        // channel 不在 /api/settings 白名单里，回读必须读 update.conf（见 mac_update.h）。
        {
            const std::string chv = rta::update::read_update_channel_value();
            const NSInteger idx = (chv == "cn" || chv == "china") ? 1 : 0;
            if (idx < self_.updChannelPopup.numberOfItems) [self_.updChannelPopup selectItemAtIndex:idx];
        }
        [self_ applyKV:kv toSwitch:self_.autoAnlSwitch key:@"autoanl"];
        [self_ applyKV:kv toTextField:self_.attenField key:@"atten"];
        [self_ applyKV:kv toTextField:self_.bufferField key:@"buffer"];
        [self_ applyKV:kv toTextField:self_.rampField key:@"ramp"];
        [self_ applyKV:kv toTextField:self_.tapsField key:@"taps"];
        [self_ applyKV:kv toTextField:self_.transitionField key:@"transition"];
        [self_ applyKV:kv toTextField:self_.modCutField key:@"modcut"];
        [self_ applyKV:kv toTextField:self_.modDithField key:@"moddith"];
        if (kv[@"scanthreads"]) [self_ applyKV:kv toTextField:self_.scanThreadsField key:@"scanthreads"];
        else if (kv[@"scanThreads"]) [self_ applyKV:kv toTextField:self_.scanThreadsField key:@"scanThreads"];
        [self_ applyKV:kv toSwitch:self_.streamSwitch key:@"streamdecode"];
        [self_ applyKV:kv toSwitch:self_.metaOnSwitch key:@"metaon"];
        if (self_.metaLlmSwitch &&
            [kv[@"metallm"] respondsToSelector:@selector(boolValue)]) {
            const BOOL llmOn = [kv[@"metallm"] boolValue];
            const BOOL sumOn = [kv[@"metasummary"] respondsToSelector:@selector(boolValue)] &&
                               [kv[@"metasummary"] boolValue];
            self_.metaLlmSwitch.state = (llmOn && sumOn) ? NSControlStateValueOn : NSControlStateValueOff;
            [self_.loadedKeys addObject:@"metallm"];
        }
        [self_ applyKV:kv toSwitch:self_.metaSummarySwitch key:@"metasummary"];
        [self_ applyKV:kv toSwitch:self_.metaAiFillSwitch key:@"metaaifill"];

        [self_ applyKV:kv toPopup:self_.backendPopup key:@"backend"];
        // 后端联动（web 同语义）：upnp 才显示目标渲染器、隐藏声道微调；其它后端反过来。
        [self_ syncOutputBackendVisibility:self_.backendPopup.titleOfSelectedItem ?: @"coreaudio"];
        // 设备落盘值是 id（web option value）：列表异步到达后再按 id 回显（selectSavedDevice）。
        self_.savedDeviceId = [kv[@"device"] isKindOfClass:[NSString class]] ? kv[@"device"] : @"";
        [self_ selectSavedDevice];
        [self_ applyKV:kv toPopup:self_.ratePopup key:@"rate"];
        // U5：族策略回显（GET 缺省注入 compatible；值 prefer/strict/compatible）。
        [self_ applyKV:kv toPopup:self_.rateFamilyPopup key:@"rateFamilyPolicy"];
        // 位深与采样率一样是「值 ≠ 文案」的下拉（web value=-1/0/16/32）；
        // 旧实现根本没把 kv.bits 回填到下拉，于是重开设置页永远显示第一项。
        [self_ applyKV:kv toPopup:self_.bitsPopup key:@"bits"];
        // filter / filterNx / sdmfilt / sdmfiltnx 清单是异步到的：先记值，/api/filters 完成块再按值重选。
        // filterNx / sdmfilt / sdmfiltnx 的空串是合法值（「跟随」首项），applyKV 必须能选中它。
        self_.savedFilter = [kv[@"filter"] isKindOfClass:[NSString class]] ? kv[@"filter"] : @"";
        self_.savedFilterNx = [kv[@"filterNx"] isKindOfClass:[NSString class]] ? kv[@"filterNx"] : @"";
        self_.savedSdmFilter = [kv[@"sdmfilt"] isKindOfClass:[NSString class]] ? kv[@"sdmfilt"] : @"";
        self_.savedSdmFilterNx = [kv[@"sdmfiltnx"] isKindOfClass:[NSString class]] ? kv[@"sdmfiltnx"] : @"";
        [self_ applyKV:kv toPopup:self_.filt1xPopup key:@"filter"];
        [self_ applyKV:kv toPopup:self_.filtNxPopup key:@"filterNx"];
        [self_ refreshFilterFamilyNote];
        [self_ applyKV:kv toPopup:self_.sdmO1Popup key:@"sdmfilt"];
        [self_ applyKV:kv toPopup:self_.sdmONxPopup key:@"sdmfiltnx"];
        [self_ applyKV:kv toPopup:self_.phasePopup key:@"phase"];
        [self_ applyKV:kv toPopup:self_.shaperPopup key:@"shaper"];
        [self_ applyKV:kv toPopup:self_.modFamilyPopup key:@"modfamily"];
        [self_ applyKV:kv toPopup:self_.modOrderPopup key:@"modorder"];
        [self_ applyKV:kv toPopup:self_.dsdKindPopup key:@"dsdkind"];
        [self_ applyKV:kv toPopup:self_.dsdConvPopup key:@"dsdconv"];
        [self_ applyKV:kv toPopup:self_.inBackendPopup key:@"inbackend"];
        // GPU 后端偏好回填（值 auto/metal/off → 下拉下标）。
        if ([kv[@"gpuvendor"] isKindOfClass:[NSString class]])
            [self_.gpuPopup selectItemAtIndex:RLPGpuIndexForVendor(kv[@"gpuvendor"])];
        // 输入设备：落盘值可能是设备 id（web option value），设备列表异步到了再按 id 回显。
        if ([kv[@"indev"] isKindOfClass:[NSString class]]) {
            self_.savedInDev = kv[@"indev"];
            [self_ loadInputDevices];
        }

        // kv.dsd 是三个控件的合成值（0=PCM；64..1024 或旧 dopNN/natNN=DSD）。
        [self_ applyDsdPersistValue:kv[@"dsd"]];
        self_.savedUpnpDev = [kv[@"upnpdev"] isKindOfClass:[NSString class]] ? kv[@"upnpdev"] : @"";
        [self_ selectSavedUpnpDevice];
        id root = kv[@"root"];
        if ([root isKindOfClass:[NSString class]] && [root length] && ![self_ isControlDirty:self_.rootField]) {
            self_.rootField.stringValue = root;
            if (self_.rootField.identifier.length) self_.lastLoadedValues[self_.rootField.identifier] = root;
        }
        if (self_.eqField && [kv[@"eq"] isKindOfClass:[NSString class]] && ![self_ isControlDirty:self_.eqField]) {
            self_.eqField.stringValue = kv[@"eq"];
            if (self_.eqField.identifier.length) self_.lastLoadedValues[self_.eqField.identifier] = kv[@"eq"];
        }
        // 声道音量微调按真实「输出声道数」重建（0 = 跟随源 → 先按立体声，web 同口径）。
        [self_ parseAndStoreTrimString:kv[@"trim"]];
        NSInteger trimCh = 0;
        id chv = kv[@"channels"];
        if ([chv respondsToSelector:@selector(integerValue)]) {
            trimCh = [chv integerValue];
        }
        [self_ rebuildTrimFields:trimCh];
        // 下拉回显「输出声道数」本身（0 跟随源原样回显为第 0 项）。
        if (self_.chPopup) {
            const NSInteger idx = (trimCh == 6) ? 2 : (trimCh == 8) ? 3 : (trimCh == 2) ? 1 : 0;
            if (idx >= 0 && idx < self_.chPopup.numberOfItems) [self_.chPopup selectItemAtIndex:idx];
        }
        self_.statusLine.stringValue = RLPTr(@"设置已加载");
    }];

    [self reloadPlaymode];

    // 2026-11-20 用户反馈「设置页面加载很慢」。
    // 旧实现不论当前停在哪个页签，都会把 UPnP 设备发现（缓存空时 SSDP 约 1.2s）、
    // 音乐库统计、服务器/元数据/校准/LLM 全部拉一遍；在真实曲库与网络设备上，
    // 这些后台请求会互相排队，用户看到的就是“设置页打开后控件慢慢才填上”。
    // 现在只刷新当前页签真正需要的只读数据；切到对应页签时 showTab 的
    // freshlyBuilt 分支会再走一次这里，自然补齐。页签缓存不清空，回看不丢。
    const RLPSTab visibleTab = self.tab;
    if (visibleTab == RLPSTabOut || visibleTab == RLPSTabStream) {
        [self loadUpnpDevicesForce:NO];
    }
    if (visibleTab == RLPSTabAdv) {
        [self reloadRoots];
        [self.libStatsView reload];
    }
    if (visibleTab == RLPSTabStream) {
        [self.serversView reload];
    }
    if (visibleTab == RLPSTabMeta) {
        [self.metaSourcesView reload];
        [self loadLlmConfig];
    }
    // ⚠️ EQ 视图也必须在这一串里。旧实现漏了它：eqView 只在 fillEqualizer 建立时
    // reload 一次，此后再没人刷新 ⟹ 用户在 EQ 页做任何"外部改变"（重置 Flat、
    // 从工作台改预设、OPRA 应用）之后回到设置页，曲线仍停在旧数据上
    //（"重置之后曲线不随动"）。判据见 test_native_eq_contract 的 E12。
    // 若 eqView 仍有未提交草稿或在途写请求，跳过覆盖以免回跳/打断编辑。
    if (reloadEq && self.eqView && ![self.eqView hasPendingDraft]) {
        [self.eqView reload];
    }
    // 直通按钮会清空 ir/irgpu：校准视图也必须跟着刷新，否则仍显示旧 IR 路径。
    if (visibleTab == RLPSTabCal) {
        [self.calView reload];
    }
}

#pragma mark - 输出页动作

/// 直通按钮的确认策略：真机默认弹确认；无界面测试可关掉，避免模态框把测试主线程卡死。
static BOOL sRLPConfirmBitPerfectFix = YES;

- (void)parseAndStoreTrimString:(id)raw {
    if (!self.savedTrimValues) {
        self.savedTrimValues = [NSMutableArray arrayWithCapacity:8];
    }
    [self.savedTrimValues removeAllObjects];
    NSArray<NSString *> *parts = nil;
    if ([raw isKindOfClass:[NSString class]]) {
        parts = [(NSString *)raw componentsSeparatedByString:@","];
    }
    for (NSUInteger i = 0; i < 8; ++i) {
        double v = 0.0;
        if (parts && i < parts.count) {
            v = [parts[i] doubleValue];
            if (v < -24.0) v = -24.0;
            if (v > 12.0) v = 12.0;
        }
        [self.savedTrimValues addObject:@(v)];
    }
}

/// bit-perfect 直通：web 的判据是「输出采样率 = 源 / 抖动 = none / 音量 0 dB / 无 EQ·IR / 独占」。
/// 这里一次提交这组键（后端合并写，其它键不受影响）。
+ (BOOL)rlp_confirmsBitPerfectFix { return sRLPConfirmBitPerfectFix; }
+ (void)setRlp_confirmsBitPerfectFix:(BOOL)v { sRLPConfirmBitPerfectFix = v; }

- (void)onBitPerfectFix:(id)sender {
    (void)sender;
    // 2026-11-17（UI 缺口审计已证实）：旧实现**未经确认**就把音量改成 0 dB（满幅），
    // 在非 0 dB 状态下点一下会直接满幅输出；且 rate 写成 "follow"、漏了 backend/dsd/isp，
    // 从共享/DSD/ISP 状态点下去仍进不了直通。按 Web 的 sp_bpfix 语义修正。
    if ([[self class] rlp_confirmsBitPerfectFix] && self.view.window) {
        NSAlert *a = [NSAlert new];
        a.alertStyle = NSAlertStyleWarning;
        a.messageText = RLPTr(@"切到 bit-perfect 直通");
        a.informativeText = RLPTr(@"会把输出音量设为 0 dB（满幅），采样率改为跟随源，关闭抖动/EQ/IR，并切回 CoreAudio 独占。确定继续？");
        [a addButtonWithTitle:RLPTr(@"切到直通")];
        [a addButtonWithTitle:RLPTr(@"取消")];
        if ([a runModal] != NSAlertFirstButtonReturn) return;
    }

    __weak __typeof__(self) weakSelf = self;
    [self postKeys:@{
        @"backend": @"coreaudio", @"rate": @"src", @"dsd": @"0", @"isp": @"0",
        @"shaper": @"none", @"volume": @"0",
        @"eq": @"", @"ir": @"", @"irgpu": @"0", @"hogexcl": @"1", @"bits": @"-1",
    } completion:^(BOOL ok) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || !ok) return;
        [self_ reloadData];
        [self_ showStatus:RLPTr(@"已切到 bit-perfect 直通")];
    }];
}

- (void)onOutMode:(NSPopUpButton *)s {
    [self updateDsdModeNote];
    [self postKeys:@{ @"dsd": [self dsdPersistValue], @"dsdnative": @"0" }];
}

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
    if (!self.savedTrimValues) [self parseAndStoreTrimString:nil];
    if (s.tag >= 0 && s.tag < (NSInteger)self.savedTrimValues.count) {
        self.savedTrimValues[(NSUInteger)s.tag] = @(s.doubleValue);
    }
    [self onTrim:nil];
}

- (void)onBuffer:(NSTextField *)s { [self postKey:@"buffer" value:s.stringValue]; }
- (void)onRamp:(NSTextField *)s { [self postKey:@"ramp" value:s.stringValue]; }
- (void)onEqPath:(NSTextField *)s {
    NSString *path = [s.stringValue stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [self postKey:@"eq" value:path];
}

- (void)onTrim:(id)sender {
    // 一次提交整串 trim（后端只认逗号分隔的 8 个值）；没生成的声道位沿用已保存值（或 0）。
    NSMutableArray<NSString *> *vals = [NSMutableArray array];
    for (NSInteger i = 0; i < 8; ++i) {
        NSSlider *sl = self.trimFields[[NSString stringWithFormat:@"sp_trim%ld", (long)i]];
        double v = sl ? sl.doubleValue
                      : ((self.savedTrimValues && (NSUInteger)i < self.savedTrimValues.count)
                         ? [self.savedTrimValues[(NSUInteger)i] doubleValue] : 0.0);
        [vals addObject:[NSString stringWithFormat:@"%.1f", v]];
    }
    [self postKey:@"trim" value:[vals componentsJoinedByString:@","]];
}
- (void)onUpnpDevice:(NSPopUpButton *)s {
    id ro = s.selectedItem.representedObject;
    NSString *val = [ro isKindOfClass:[NSString class]] ? (NSString *)ro : @"";
    self.savedUpnpDev = val;
    [self postKey:@"upnpdev" value:val];
}
- (void)onUpnpScan:(id)sender {
    [self loadUpnpDevicesForce:YES];
    [self.castView reload];
}

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

/// SDM 页 Oversampling：与 PCM 页共用同一份滤波器清单，因此同 U8 口径 ——
/// 首项是空串（跟随），其余**发 representedObject（原名）**，绝不发带族名的标题。
- (void)onSdmO1:(NSPopUpButton *)s {
    id ro = s.selectedItem.representedObject;
    NSString *value = [ro isKindOfClass:[NSString class]] ? (NSString *)ro
                     : (s.indexOfSelectedItem == 0 ? @"" : @"");
    [self postKey:@"sdmfilt" value:value];
}
- (void)onSdmONx:(NSPopUpButton *)s {
    id ro = s.selectedItem.representedObject;
    NSString *value = [ro isKindOfClass:[NSString class]] ? (NSString *)ro
                     : (s.indexOfSelectedItem == 0 ? @"" : @"");
    [self postKey:@"sdmfiltnx" value:value];
}
- (void)onDsdPack:(NSPopUpButton *)s {
    [self syncOutModeToDsd];
    [self updateDsdModeNote];
    [self postKeys:@{ @"dsd": [self dsdPersistValue], @"dsdnative": @"0" }];
}
- (void)onDsdKind:(NSPopUpButton *)s { [self postKey:@"dsdkind" value:s.titleOfSelectedItem ?: @"fir"]; }
- (void)onDsdConv:(NSPopUpButton *)s { [self postKey:@"dsdconv" value:s.titleOfSelectedItem ?: @"narrow"]; }
/// 改拐点：保存 + 落定后刷新准入提示（后端合并写：成功则新值生效，被 422 拒则旧值仍生效）。
- (void)onModCut:(NSTextField *)s {
    __weak __typeof__(self) weakSelf = self;
    [self postKey:@"modcut" value:s.stringValue completion:^(BOOL ok) {
        (void)ok;
        __typeof__(self) self_ = weakSelf;
        [self_ reloadSdmAdmission];
    }];
}

#pragma mark - 拐点准入提示（U12）

/// U12（2026-11-16）：拐点准入提示 —— 文案完全由 /api/settings 的 `sdm` 对象驱动。
/// 为什么不在前端写阈值：100 kHz（100000 Hz）是后端策略（policy=sdm-corner-v1），
/// 前端复制一份就会在策略调整后显示错误提示。这里只做「admitted==false → 显示 note」。
/// 为什么要 contentDidChange：字段网格按行高缓存，只改 hidden 会留一条空白或把提示裁掉。
- (void)applySdmAdmission:(NSDictionary *)sdm {
    NSTextField *note = self.sdmCornerNote;
    if (!note) return;
    NSString *text = [sdm[@"note"] isKindOfClass:[NSString class]] ? sdm[@"note"] : @"";
    const BOOL rejected = [sdm[@"admitted"] isKindOfClass:[NSNumber class]] &&
                          ![sdm[@"admitted"] boolValue];
    const BOOL show = rejected && text.length > 0;
    const BOOL wasShown = !note.hidden;
    if (show) {
        note.stringValue = text;
        note.textColor = [RLPTheme current].danger;
        note.hidden = NO;
    } else {
        note.stringValue = @"";
        note.hidden = YES;
    }
    if (wasShown != show && self.sdmGroup) [self.sdmGroup contentDidChange];
}

/// 只刷新 sdm 快照：仍以后端读回为准，不拿输入框的值猜判定。
- (void)reloadSdmAdmission {
    if (![RLPCoreClient shared].started) return;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/settings" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSDictionary *sdm = [json[@"sdm"] isKindOfClass:[NSDictionary class]] ? json[@"sdm"] : nil;
        self_.sdmAdmission = sdm;
        [self_ applySdmAdmission:sdm];
    }];
}
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
    const NSTimeInterval t0 = [NSProcessInfo processInfo].systemUptime;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/input/start" body:body
                          completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        const BOOL ok = json && [json[@"ok"] boolValue];
        if (!ok) {
            const double durMs = ([NSProcessInfo processInfo].systemUptime - t0) * 1000.0;
            RLPDiagEvent(@"error", @"api_fail", @"settings:in", @"/api/input/start",
                         json ? 400 : 500, durMs, @"input_start_failed");
        }
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
    const NSTimeInterval t0 = [NSProcessInfo processInfo].systemUptime;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/input/stop" body:nil
                          completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        const BOOL ok = json && [json[@"ok"] boolValue];
        if (!ok) {
            const double durMs = ([NSProcessInfo processInfo].systemUptime - t0) * 1000.0;
            RLPDiagEvent(@"error", @"api_fail", @"settings:in", @"/api/input/stop",
                         json ? 400 : 500, durMs, @"input_stop_failed");
        }
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
- (void)reloadPlaymode {
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/playmode" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (![json[@"ok"] boolValue] && !json[@"mode"]) return;
        const NSInteger mode = [json[@"mode"] respondsToSelector:@selector(integerValue)]
                             ? [json[@"mode"] integerValue] : 0;
        if (self_.repPopup) {
            const NSInteger repIdx = (mode == 1) ? 0 : (mode == 2) ? 1 : 2;
            if (repIdx >= 0 && repIdx < self_.repPopup.numberOfItems)
                [self_.repPopup selectItemAtIndex:repIdx];
        }
        if (self_.shufSwitch) {
            self_.shufSwitch.state = (mode == 3) ? NSControlStateValueOn : NSControlStateValueOff;
        }
    }];
}

- (void)onRepeat:(NSPopUpButton *)s {
    NSArray<NSString *> *vals = @[ @"1", @"2", @"0" ];
    const NSInteger i = s.indexOfSelectedItem;
    NSString *modeVal = (i >= 0 && i < 3) ? vals[i] : @"1";
    NSString *url = [NSString stringWithFormat:@"/api/playmode?mode=%@", modeVal];
    const NSTimeInterval t0 = [NSProcessInfo processInfo].systemUptime;
    __weak __typeof__(self) weakSelf = self;
    [RLPCoreClient.shared postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            self_.statusLine.stringValue = RLPTr(@"已保存");
        } else {
            const double durMs = ([NSProcessInfo processInfo].systemUptime - t0) * 1000.0;
            RLPDiagEvent(@"error", @"api_fail", @"settings:adv", @"/api/playmode",
                         json ? 400 : 500, durMs, @"playmode_set_failed");
            NSString *err = ([json[@"error"] isKindOfClass:[NSString class]] && [json[@"error"] length])
                          ? json[@"error"] : RLPTr(@"保存失败");
            self_.statusLine.stringValue = err;
            RLPToast(err);
        }
        [self_ reloadPlaymode];
    }];
}
- (void)onShuffle:(NSSwitch *)s {
    // web 用 /api/shuffle?on=1|0（不是 /api/playmode 的派生写法）—— 同一条后端路径，
    // 不另造一种写法，否则两端行为会悄悄分叉。
    NSString *url = [NSString stringWithFormat:@"/api/shuffle?on=%@",
                     s.state == NSControlStateValueOn ? @"1" : @"0"];
    const NSTimeInterval t0 = [NSProcessInfo processInfo].systemUptime;
    __weak __typeof__(self) weakSelf = self;
    [RLPCoreClient.shared postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            self_.statusLine.stringValue = RLPTr(@"已保存");
        } else {
            const double durMs = ([NSProcessInfo processInfo].systemUptime - t0) * 1000.0;
            RLPDiagEvent(@"error", @"api_fail", @"settings:adv", @"/api/shuffle",
                         json ? 400 : 500, durMs, @"shuffle_set_failed");
            // 旧实现 completion:nil：开关已经勾上、后端却没写成（ok:false 或服务没响应）时，
            // 状态行一个字都不变、也没有提示 —— 保存失败被完全吞掉，用户以为已经开了随机。
            NSString *err = ([json[@"error"] isKindOfClass:[NSString class]] && [json[@"error"] length])
                          ? json[@"error"] : RLPTr(@"保存失败");
            self_.statusLine.stringValue = err;
            RLPToast(err);
        }
        // 成败都按后端真值回填：失败时等于把开关退回原位，成功时顺带同步 sp_rep（与 onRepeat 同口径）。
        [self_ reloadPlaymode];
    }];
}

- (void)onAddRoot:(id)sender {
    NSString *p = [self.rootField.stringValue copy] ?: @"";
    if (!p.length) { RLPToast(RLPTr(@"请先填目录或点「浏览…」")); return; }
    const NSTimeInterval t0 = [NSProcessInfo processInfo].systemUptime;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/lib/roots"
                                body:[NSString stringWithFormat:@"add=%@", RLPEnc(p)]
                          completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            NSString *cur = self_.rootField.stringValue ?: @"";
            if ([cur isEqualToString:p]) {
                self_.rootField.stringValue = @"";
                if (self_.rootField.identifier.length) {
                    [self_.dirtyControlIds removeObject:self_.rootField.identifier];
                    self_.lastLoadedValues[self_.rootField.identifier] = @"";
                }
            }
            [self_ reloadRoots];
            RLPToast(RLPTr(@"目录已加入"));
        } else {
            const double durMs = ([NSProcessInfo processInfo].systemUptime - t0) * 1000.0;
            RLPDiagEvent(@"error", @"api_fail", @"settings:adv", @"/api/lib/roots",
                         json ? 400 : 500, durMs, @"root_add_failed");
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
    [[RLPCoreClient shared] getJSON:@"/api/lib/stats" completion:^(NSDictionary * _Nullable json) {
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
    if (![RLPCoreClient shared].started) {
        RLPDiagEvent(@"error", @"diag_summary", @"settings:diag", @"/api/diag", 503, -1, @"core_not_started");
        self.diagMsg.stringValue = RLPTr(@"核心未启动");
        return;
    }
    const NSTimeInterval t0 = [NSProcessInfo processInfo].systemUptime;
    __weak __typeof__(self) weakSelf = self;
    void (^done)(NSDictionary * _Nullable) = ^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        const double durMs = ([NSProcessInfo processInfo].systemUptime - t0) * 1000.0;
        NSString *text = json ? [[NSString alloc] initWithData:
            [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil]
            encoding:NSUTF8StringEncoding] : nil;
        if (text.length) {
            [[NSPasteboard generalPasteboard] clearContents];
            [[NSPasteboard generalPasteboard] setString:text forType:NSPasteboardTypeString];
            self_.diagMsg.stringValue = RLPTr(@"摘要已复制");
            RLPDiagEvent(@"action", @"diag_summary", @"settings:diag", @"/api/diag", 200, durMs, @"ok");
        } else {
            self_.diagMsg.stringValue = RLPTr(@"诊断摘要读取失败");
            RLPDiagEvent(@"error", @"diag_summary", @"settings:diag", @"/api/diag",
                         json ? 422 : 500, durMs, json ? @"empty_summary" : @"empty_response");
        }
    };
    if (self.diagSummaryTransport) { self.diagSummaryTransport(done); return; }
    [[RLPCoreClient shared] getJSON:@"/api/diag" completion:done];
}

static NSString *RLPFormatSingleDiagChannel(NSString *label, id _Nullable rawCh, BOOL *outOk) {
    if (![rawCh isKindOfClass:[NSDictionary class]]) {
        if (outOk) *outOk = NO;
        return [NSString stringWithFormat:@"%@：%@", label, RLPTr(@"无结果")];
    }
    NSDictionary *ch = (NSDictionary *)rawCh;
    const BOOL ok = [ch[@"ok"] respondsToSelector:@selector(boolValue)] && [ch[@"ok"] boolValue];
    const NSInteger http = [ch[@"http"] respondsToSelector:@selector(integerValue)] ? [ch[@"http"] integerValue] : 0;
    const NSInteger latency = [ch[@"latency"] respondsToSelector:@selector(integerValue)] ? [ch[@"latency"] integerValue] : 0;
    const BOOL timedOut = [ch[@"timedOut"] respondsToSelector:@selector(boolValue)] && [ch[@"timedOut"] boolValue];
    NSString *err = [ch[@"error"] isKindOfClass:[NSString class]] ? ch[@"error"] : @"";
    err = [err stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (ok) {
        if (outOk) *outOk = YES;
        return [NSString stringWithFormat:@"%@：HTTP %ld %ldms", label, (long)http, (long)latency];
    }
    if (outOk) *outOk = NO;
    if (timedOut) {
        if (err.length > 0 && ![err isEqualToString:@"timeout"]) {
            return [NSString stringWithFormat:@"%@：超时（%@，%ldms）", label, err, (long)latency];
        }
        return [NSString stringWithFormat:@"%@：超时（%ldms）", label, (long)latency];
    }
    if (http > 0) {
        NSString *httpTag = [NSString stringWithFormat:@"HTTP %ld", (long)http];
        if (err.length > 0 && ![err isEqualToString:httpTag]) {
            return [NSString stringWithFormat:@"%@：失败 %@（%@）%ldms", label, httpTag, err, (long)latency];
        }
        return [NSString stringWithFormat:@"%@：失败 %@（%ldms）", label, httpTag, (long)latency];
    }
    NSString *reason = err.length ? err : RLPTr(@"连接失败");
    return [NSString stringWithFormat:@"%@：失败（%@）%ldms", label, reason, (long)latency];
}

- (void)onCheckDiagChannels:(id)sender {
    (void)sender;
    if (self.diagChannelsChecking) return;
    if (!self.diagChannelsTransport && ![RLPCoreClient shared].started) {
        self.diagChannelsLabel.stringValue = RLPTr(@"核心未启动");
        self.diagChannelsLabel.textColor = [RLPTheme current].danger;
        [self.diagGroup contentDidChange];
        return;
    }
    self.diagChannelsChecking = YES;
    self.diagChannelsBtn.enabled = NO;
    self.diagChannelsLabel.textColor = [RLPTheme current].mut2;
    self.diagChannelsLabel.stringValue = RLPTr(@"正在检查更新与反馈通道…");
    [self.diagGroup contentDidChange];

    __weak __typeof__(self) weakSelf = self;
    void (^done)(NSDictionary * _Nullable) = ^(NSDictionary * _Nullable json) {
        dispatch_block_t applyOnMain = ^{
            __typeof__(self) self_ = weakSelf;
            if (!self_) return;
            self_.diagChannelsChecking = NO;
            self_.diagChannelsBtn.enabled = YES;
            RLPTheme *t = [RLPTheme current];
            if (![json isKindOfClass:[NSDictionary class]]) {
                self_.diagChannelsLabel.stringValue = RLPTr(@"通道检查失败：核心未响应");
                self_.diagChannelsLabel.textColor = t.danger;
                [self_.diagGroup contentDidChange];
                return;
            }
            if (json[@"ok"] && ![json[@"ok"] boolValue]) {
                NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"未知错误");
                self_.diagChannelsLabel.stringValue = [NSString stringWithFormat:@"%@：%@", RLPTr(@"通道检查失败"), err];
                self_.diagChannelsLabel.textColor = t.danger;
                [self_.diagGroup contentDidChange];
                return;
            }
            BOOL updOk = NO;
            BOOL fbOk = NO;
            NSString *updStr = RLPFormatSingleDiagChannel(RLPTr(@"更新"), json[@"update"], &updOk);
            NSString *fbStr = RLPFormatSingleDiagChannel(RLPTr(@"反馈"), json[@"feedback"], &fbOk);
            self_.diagChannelsLabel.stringValue = [NSString stringWithFormat:@"%@ / %@", updStr, fbStr];
            self_.diagChannelsLabel.textColor = (updOk && fbOk) ? t.okText : t.danger;
            [self_.diagGroup contentDidChange];
        };
        if ([NSThread isMainThread]) applyOnMain();
        else dispatch_async(dispatch_get_main_queue(), applyOnMain);
    };

    if (self.diagChannelsTransport) {
        self.diagChannelsTransport(done);
        return;
    }
    [[RLPCoreClient shared] getJSON:@"/api/diag/channels" completion:done];
}

/// web #bNet 同语义：**点击才查询** /api/net，结果写进 sp_netmsg。
/// 单进程形态下 http=false，据此如实显示，不编一个能点的地址（那是误导，比空白更糟）。
- (void)onNetInfo:(id)sender {
    self.netMsg.hidden = NO;
    [self.netGroup contentDidChange];
    if (![RLPCoreClient shared].started) { self.netMsg.stringValue = RLPTr(@"核心未启动"); return; }
    self.netMsg.stringValue = RLPTr(@"读取中…");
    const NSTimeInterval t0 = [NSProcessInfo processInfo].systemUptime;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/net" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (![json isKindOfClass:[NSDictionary class]]) {
            const double durMs = ([NSProcessInfo processInfo].systemUptime - t0) * 1000.0;
            RLPDiagEvent(@"error", @"api_fail", @"settings:diag", @"/api/net", 500, durMs, @"net_info_failed");
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
    // 2026-11-17（UI 缺口审计已证实）：旧实现把 channel 发给 /api/settings，而后端
    // 白名单没有 channel ⟹ 静默丢弃，重开设置页就回退。这里直接写 update.conf，
    // 与 Web 版 wcmd('update:channel:*') 同一条落盘路径。
    const std::string want = s.indexOfSelectedItem == 1 ? "cn" : "global";
    std::string err;
    const bool ok = rta::update::set_update_channel(want, err);
    NSString *chanStr = [NSString stringWithUTF8String:want.c_str()] ?: @"global";
    RLPDiagEvent(ok ? @"action" : @"error", @"update_channel_switch", @"settings:diag", nil,
                 ok ? 200 : 500, -1, ok ? chanStr : @"save_failed");
    if (!ok) {
        [self showStatus:[NSString stringWithFormat:@"%@：%s", RLPTr(@"切换更新通道失败"),
                                                   err.empty() ? "unknown" : err.c_str()]];
        return;
    }
    [self showStatus:RLPTr(@"更新通道已保存")];
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

#pragma mark - 主题与草稿快照

- (NSDictionary *)capturePaneViewState {
    NSScrollView *oldScroll = nil;
    for (NSView *sub in self.paneHost.subviews) {
        if ([sub isKindOfClass:[NSScrollView class]]) { oldScroll = (NSScrollView *)sub; break; }
    }
    const NSPoint savedOrigin = oldScroll ? oldScroll.contentView.bounds.origin : NSZeroPoint;

    NSString *focusedId = nil;
    NSRange savedSelection = NSMakeRange(NSNotFound, 0);
    NSResponder *fr = self.view.window.firstResponder;
    if ([fr isKindOfClass:[NSTextView class]]) savedSelection = ((NSTextView *)fr).selectedRange;
    if ([fr isKindOfClass:[NSTextView class]] && [((NSTextView *)fr).delegate isKindOfClass:[NSView class]]) {
        NSView *owner = (NSView *)((NSTextView *)fr).delegate;
        if ([owner isDescendantOf:self.paneHost] && owner.identifier.length) focusedId = owner.identifier;
    } else if ([fr isKindOfClass:[NSView class]] && [(NSView *)fr isDescendantOf:self.paneHost]) {
        focusedId = ((NSView *)fr).identifier;
    }

    NSMutableDictionary *state = [@{
        @"hasScroll": @(oldScroll != nil),
        @"origin": [NSValue valueWithPoint:savedOrigin],
        @"selection": [NSValue valueWithRange:savedSelection],
    } mutableCopy];
    if (focusedId.length) state[@"focusId"] = focusedId;
    return state;
}

/// 把一个页签里未提交的草稿落到 pendingPaneDrafts（tabKey → identifier → 文本）。
/// 抽成单页版本的原因：切页签时只有"正在离开视图树的那一页"会丢掉编辑态，
/// 其余缓存页签的控件都还在（没必要每次切页全量扫 10 页）。
/// EQ 子界面自己有一套草稿口径（RLPEqualizerView.hasPendingDraft），这里按 isEqOwnedView
/// 整块跳过 —— 往它的字段里写值会绕过 peqDraftEpoch / peqSyncedDraftEpoch 的代次判断。
/// 它的 field editor 文本与 preset/OPRA 选择改由 showTab 调 RLPEqualizerView(RLPDraftState)
/// 的 rlp_captureDraftState / rlp_restoreDraftState 单独搬运（必须在摘除视图之前 capture）。
- (void)snapshotPendingPaneDraftsForTab:(RLPSTab)tab {
    NSNumber *tabKey = @(tab);
    NSView *cachedPane = self.paneCache[tabKey];
    if (!cachedPane) return;
    NSMutableArray<NSView *> *views = [NSMutableArray array];
    RLPSettingsCollectViews(cachedPane, views);
    NSMutableDictionary<NSString *, NSString *> *tabDrafts =
        self.pendingPaneDrafts[tabKey] ?: [NSMutableDictionary dictionary];
    for (NSView *v in views) {
        if (!v.identifier.length || [self isEqOwnedView:v]) continue;
        if ([v isKindOfClass:[NSTextField class]] && ((NSTextField *)v).isEditable) {
            NSTextField *tf = (NSTextField *)v;
            // 正在编辑的字段：文字还在 field editor 里，stringValue 是旧值 —— 必须读 currentEditor。
            NSString *curVal = tf.currentEditor ? (tf.currentEditor.string ?: @"")
                                                : (tf.stringValue ?: @"");
            NSString *loadedVal = self.lastLoadedValues[v.identifier];
            BOOL isDirty = [self.dirtyControlIds containsObject:v.identifier];
            // 这一页已经存过草稿、而控件里现在装的仍是「上次读回的真值」⟹ 说明摘出视图树时
            // field editor 的编辑态被弃掉了（stringValue 没跟上）：**已存的草稿才是新的那一份**，
            // 不能拿这份旧值把它覆盖掉（否则切语言 / 切主题二次快照时会把草稿冲掉）。
            NSString *existing = tabDrafts[v.identifier];
            if (existing.length && isDirty &&
                (loadedVal == nil ? (curVal.length == 0) : [curVal isEqualToString:loadedVal])) {
                continue;
            }
            if (!isDirty) {
                if (loadedVal != nil) {
                    isDirty = ![curVal isEqualToString:loadedVal];
                } else if (curVal.length > 0) {
                    isDirty = YES;
                }
                if (isDirty) [self.dirtyControlIds addObject:v.identifier];
            }
            if (isDirty || curVal.length > 0) {
                tabDrafts[v.identifier] = curVal;
            }
        } else if ([v isKindOfClass:[NSTextView class]] && ((NSTextView *)v).isEditable) {
            NSString *curVal = [((NSTextView *)v).string copy] ?: @"";
            if (curVal.length > 0 || [self.dirtyControlIds containsObject:v.identifier]) {
                tabDrafts[v.identifier] = curVal;
            }
        }
    }
    if (tabDrafts.count) {
        self.pendingPaneDrafts[tabKey] = tabDrafts;
    }
}

/// 跨所有缓存页签快照：切语言 / 切主题会清空 paneCache（非当前页签的页签对象随后被销毁），
/// 必须先把每一页的草稿都收下来。
- (void)snapshotPendingPaneDrafts {
    for (NSNumber *tabKey in [self.paneCache allKeys]) {
        [self snapshotPendingPaneDraftsForTab:(RLPSTab)tabKey.integerValue];
    }
}

/// 换页前：当前显示的那一页若不是即将显示的那一页（它马上会被摘出视图树），先快照它的草稿。
/// 为什么不能只看 self.tab：onGroupChanged / selectPane 会**先改 self.tab 再调 showTab**，
/// 拿 tab != self.tab 判"换页"会漏掉这些最常用的入口。
- (void)snapshotDraftsOfOutgoingPaneIfNeededForTab:(RLPSTab)tab {
    NSView *outgoing = self.paneHost.subviews.firstObject;
    if (!outgoing) return;                               // 还没显示过任何页签：没有东西会离开视图树
    if (self.paneCache[@(tab)] == outgoing) return;      // 同一页签原地重画：视图没离开视图树
    for (NSNumber *tabKey in [self.paneCache allKeys]) {
        if (self.paneCache[tabKey] != outgoing) continue;
        [self snapshotPendingPaneDraftsForTab:(RLPSTab)tabKey.integerValue];
        return;
    }
}

- (void)restorePaneViewState:(NSDictionary *)state {
    NSString *focusedId = [state[@"focusId"] isKindOfClass:[NSString class]] ? state[@"focusId"] : nil;
    const BOOL hasOldScroll = [state[@"hasScroll"] respondsToSelector:@selector(boolValue)]
        && [(NSNumber *)state[@"hasScroll"] boolValue];
    const NSPoint savedOrigin = [state[@"origin"] isKindOfClass:[NSValue class]]
        ? [(NSValue *)state[@"origin"] pointValue] : NSZeroPoint;
    const NSRange savedSelection = [state[@"selection"] isKindOfClass:[NSValue class]]
        ? [(NSValue *)state[@"selection"] rangeValue] : NSMakeRange(NSNotFound, 0);

    NSView *focusTarget = nil;
    if (focusedId.length) {
        NSMutableArray<NSView *> *newViews = [NSMutableArray array];
        RLPSettingsCollectViews(self.paneHost, newViews);
        for (NSView *v in newViews) {
            if (v.identifier.length && [v.identifier isEqualToString:focusedId]) {
                focusTarget = v;
                break;
            }
        }
    }

    [self.paneHost layoutSubtreeIfNeeded];
    NSScrollView *newScroll = nil;
    for (NSView *sub in self.paneHost.subviews) {
        if ([sub isKindOfClass:[NSScrollView class]]) { newScroll = (NSScrollView *)sub; break; }
    }
    if (newScroll && hasOldScroll) {
        [newScroll.contentView scrollToPoint:savedOrigin];
        [newScroll reflectScrolledClipView:newScroll.contentView];
    }
    if (focusTarget && self.view.window && [focusTarget acceptsFirstResponder]) {
        [self.view.window makeFirstResponder:focusTarget];
        if (savedSelection.location != NSNotFound &&
            [self.view.window.firstResponder isKindOfClass:[NSTextView class]]) {
            NSTextView *editor = (NSTextView *)self.view.window.firstResponder;
            NSUInteger start = MIN(savedSelection.location, editor.string.length);
            editor.selectedRange = NSMakeRange(start, MIN(savedSelection.length, editor.string.length - start));
        }
    }
}

- (void)captureLlmModelStateIfNeeded {
    NSPopUpButton *pop = self.llmModelPopup;
    const NSInteger count = pop ? pop.numberOfItems : 0;
    if (!pop || (self.tab != RLPSTabMeta && count <= 0)) return;
    NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithCapacity:(NSUInteger)MAX(0, count)];
    for (NSMenuItem *item in pop.itemArray) {
        [titles addObject:(item.title ?: @"")];
    }
    self.capturedLlmModelTitles = titles;
    self.capturedLlmModelSelectedIndex = pop.indexOfSelectedItem;
    self.capturedLlmModelHidden = pop.hidden;
    self.capturedLlmModelMsg = self.llmModelMsg ? (self.llmModelMsg.stringValue ?: @"") : @"";
    self.capturedLlmModelMsgIsWarn = self.llmModelMsgIsWarn;
    self.hasCapturedLlmModelState = YES;
    if ([RLPCoreClient shared].started) {
        self.suppressNextLlmAutoLoad = YES;
    }
}

- (void)restoreLlmModelStateIfNeeded {
    if (!self.hasCapturedLlmModelState || !self.llmModelPopup) return;
    NSArray<NSString *> *titles = self.capturedLlmModelTitles ?: @[];
    const NSInteger capturedIndex = self.capturedLlmModelSelectedIndex;
    const BOOL capturedHidden = self.capturedLlmModelHidden;
    NSString *capturedMsg = self.capturedLlmModelMsg ?: @"";
    const BOOL capturedWarn = self.capturedLlmModelMsgIsWarn;

    [self.llmModelPopup removeAllItems];
    for (NSString *title in titles) {
        [self.llmModelPopup addItemWithTitle:title ?: @""];
    }
    const NSInteger count = self.llmModelPopup.numberOfItems;
    if (count > 0) {
        NSInteger idx = capturedIndex;
        if (idx < 0 || idx >= count) idx = count - 1;
        [self.llmModelPopup selectItemAtIndex:idx];
    }
    self.llmModelPopup.hidden = capturedHidden;

    if (self.llmModelMsg) {
        RLPTheme *t = [RLPTheme current];
        self.llmModelMsg.stringValue = capturedMsg;
        self.llmModelMsgIsWarn = capturedWarn;
        self.llmModelMsg.textColor = capturedWarn ? t.warn : t.mut;
    }

    self.hasCapturedLlmModelState = NO;
    self.capturedLlmModelTitles = nil;
    self.capturedLlmModelMsg = nil;
}

- (void)applyTheme {
    [super applyTheme];
    RLPTheme *t = [RLPTheme current];
    // 主题切换后清缓存重建页签前，先快照 sp_eq 等各页未提交草稿与滚动/焦点状态。
    NSDictionary *paneState = [self capturePaneViewState];
    [self snapshotPendingPaneDrafts];
    // EQ 草稿的兜底：即使 showTab 因视图树状态异常没机会 capture（例如本页不在前台），
    // 也不能让 paneCache 清空前的那份用户态随页面对象一起消失。已有快照时保持不动
    //（那份可能含 field editor 文本，比现在再读一次更完整）。
    if (!self.eqDraftState && self.eqView) self.eqDraftState = [self.eqView rlp_captureDraftState];
    [self captureLlmModelStateIfNeeded];
    [self.paneCache removeAllObjects];
    self.diagGroup = nil;
    self.fbGroup = nil;
    self.srvGroup = nil;
    self.castGroup = nil;
    self.serversView = nil;
    [self resetMetaResponsiveState];
    [self rebuildTabs];
    [self showTab:self.tab];
    if (self.themePopup) {
        [self.themePopup selectItemAtIndex:[[RLPTheme themeName] isEqualToString:@"light"] ? 1 : 0];
    }
    self.statusLine.textColor = t.mut;
    self.modeHintLabel.textColor = t.mut;
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
    // 先收集非 nil 按钮再遍历，避免未打开过 diag 页时 @[nil...] 构造字面量数组直接抛 NSInvalidArgumentException。
    NSMutableArray<NSButton *> *diagSecondaryBtns = [NSMutableArray array];
    if (self.diagJsonBtn) [diagSecondaryBtns addObject:self.diagJsonBtn];
    if (self.diagSummaryBtn) [diagSecondaryBtns addObject:self.diagSummaryBtn];
    if (self.diagChannelsBtn) [diagSecondaryBtns addObject:self.diagChannelsBtn];
    if (self.fbPreviewBtn) [diagSecondaryBtns addObject:self.fbPreviewBtn];
    if (self.fbRetryBtn) [diagSecondaryBtns addObject:self.fbRetryBtn];
    for (NSButton *b in diagSecondaryBtns) {
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
    [self restorePaneViewState:paneState];
}

#pragma mark - 语言实时切换

- (void)onLanguageChanged:(NSNotification *)note {
    (void)note;
    [self applyLanguage];
}

- (void)applyLanguage {
    NSString *curLang = RLPLanguage();
    if ([self.lastAppliedLang isEqualToString:curLang]) return;
    self.lastAppliedLang = curLang;

    // 1. 保存当前页签滚动位置与焦点，并跨所有 cachedPane 快照未提交草稿
    NSDictionary *paneState = [self capturePaneViewState];
    [self snapshotPendingPaneDrafts];
    // EQ 草稿兜底（同 applyTheme：paneCache 清空前先留住用户态）。
    if (!self.eqDraftState && self.eqView) self.eqDraftState = [self.eqView rlp_captureDraftState];

    // 2. 原地刷新页头、复合子视图与页签；非当前页签清缓存待切回时重建并恢复草稿
    self.pageTitle = RLPTr(@"设置");
    [self.groupTabs setLabel:RLPTr(@"通用") forSegment:0];
    [self.groupTabs setLabel:RLPTr(@"音频处理") forSegment:1];
    self.modeHintLabel.stringValue = RLPTr(@"音频处理主控位于专业模式「数字音乐台」，此处保留完整参数与深链入口");
    self.modeHintLabel.toolTip = self.modeHintLabel.stringValue;
    self.workbenchBtn.title = RLPTr(@"打开专业工作台");

    if (self.eqView) {
        [self.eqView applyLanguage];
    }

    [self.paneCache removeAllObjects];
    self.diagGroup = nil;
    self.fbGroup = nil;
    self.srvGroup = nil;
    self.castGroup = nil;
    self.serversView = nil;
    [self resetMetaResponsiveState];
    [self rebuildTabs];
    [self showTab:self.tab];

    if (self.langPopup) {
        [self.langPopup selectItemAtIndex:[curLang isEqualToString:@"en"] ? 1 : 0];
    }

    // 3. 恢复当前页签滚动位置与焦点
    [self restorePaneViewState:paneState];
}

@end