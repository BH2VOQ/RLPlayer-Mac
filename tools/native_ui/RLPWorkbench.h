// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPWorkbench.h — 专业工作台的纯逻辑层（信号链 / 滤波分组 / A-B 槽位）
//
// 面向发烧友：他们喜欢折腾滤波、喜欢 A/B、喜欢纠结。所以这里的东西必须
// **当场可切**且**可单测**，不是装饰性 UI。
//
// A/B 槽位的设计纪律：
//   * 槽里只存**听感相关**的键（滤波/升频/抖动/调制器/位深/EQ/抽头）；
//     **绝不存 device / backend / hogexcl** —— A/B 时切输出设备会爆音、会抢独占，
//     那不是"对比听感"而是"制造事故"。
//   * 槽是 UI 偏好（NSUserDefaults），**生效值永远从 /api/settings 读回**，
//     不允许把槽当成当前状态的第二份真相。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A/B 槽位允许保存的键（顺序固定，便于序列化稳定）。
NSArray<NSString *> *RLPABSlotKeys(void);

/// 从 /api/settings 的全量字典里抓出一份槽快照（只取听感相关键）。
NSDictionary<NSString *, NSString *> *RLPABSnapshotFromSettings(NSDictionary *_Nullable settings);

/// 槽快照 → POST /api/settings 的表单串（一次请求带多个键）。
NSString *RLPABFormBody(NSDictionary<NSString *, NSString *> *snapshot);

/// 当前设置命中哪个槽（全等才算命中）。都不等返回 -1（UI 显示"自定义"）。
/// 空槽不参与匹配。
NSInteger RLPABMatchSlot(NSDictionary *_Nullable settings,
                         NSArray<NSDictionary<NSString *, NSString *> *> *_Nullable slots);

/// 槽摘要（人话）：滤波名 + 升频规格，让人一眼看出 A 和 B 差在哪。
NSString *RLPABSlotSummary(NSDictionary<NSString *, NSString *> *_Nullable snapshot);

/// 滤波分组：按家族前缀归类（gauss / poly-sinc / sinc / ext2 / 其它）。
/// 返回 [{@"group": 组名, @"items": [原始 item…]}]，**不丢项**（所有输入都出现在某组里）。
NSArray<NSDictionary *> *RLPFilterGroups(NSArray<NSDictionary *> *_Nullable items);

/// 该滤波项是否写 filterNx 键。
BOOL RLPWorkbenchFilterUsesNx(NSDictionary *_Nullable item);

/// 从设置里取当前正在编辑的滤波名（区分 1x 槽 filter 与 Nx 槽 filterNx）。
/// editingNx=YES 时优先读 filterNx（空则回退 filter）；editingNx=NO 时优先读 filter（空则回退 filterNx）。
/// outUsesNx 非空时返回实际命中的槽是否为 filterNx。
NSString *RLPWorkbenchEditingFilter(NSDictionary *_Nullable settings,
                                    BOOL editingNx,
                                    BOOL *_Nullable outUsesNx);

/// 从设置与播放状态推算当前实际播放生效的滤波名（用于信号链展示，绝不把编辑槽冒充实际播放）。
/// 按 status.inRate 和 PCM/SDM 槽的后端回退规则选值；均为空时返回 defaultName。
NSString *RLPWorkbenchActivePlaybackFilter(NSDictionary *_Nullable settings,
                                           NSDictionary *_Nullable status,
                                           NSString *_Nullable defaultName);

/// 相位快切：在**同家族**里找指定相位的对应项（发烧友常来回比线性/最小相位的瞬态）。
/// family 判定按名字去掉相位后缀后的前缀；找不到同家族同相位项时返回 nil（不跨家族乱切）。
/// wantPhase ∈ linear / minimum / intermediate。
NSString *_Nullable RLPFilterWithPhase(NSString *_Nullable currentName,
                                      NSString *wantPhase,
                                      NSArray<NSDictionary *> *_Nullable items);

/// 从滤波名推它的家族键（用于同家族匹配）。空名返回空串。
NSString *RLPFilterFamilyKey(NSString *_Nullable name);

/// 信号链节点在给定设置下是否适用（不适用要灰掉并说明原因）。
/// node ∈ src/resample/eq/ir/shaper/sdm/out
BOOL RLPChainNodeApplies(NSString *node, NSDictionary *_Nullable settings);
/// 不适用时的原因（人话）；适用时返回 nil。
NSString *_Nullable RLPChainNodeDisabledReason(NSString *node, NSDictionary *_Nullable settings);

/// U16 命名配置档（/api/profiles）的一句话摘要：滤波 + 升频/DSD + EQ 方案名。
/// profile 是 GET /api/profiles 返回的一条；空/缺键返回「未保存」（不臆造默认值）。
NSString *RLPProfileSummary(NSDictionary *_Nullable profile);

/// 手动滤波覆盖检测：返回当前生效的手动覆盖键（phase / taps / atten / transition）。
NSArray<NSString *> *RLPWorkbenchFilterOverrideKeys(NSDictionary *_Nullable settings);

/// 是否存在任意手动滤波覆盖（phase 非空，或 taps/atten/transition 非 0）。
BOOL RLPWorkbenchHasFilterOverride(NSDictionary *_Nullable settings);

/// 恢复预设值所需的清除载荷（精确清零 phase / taps / atten / transition）。
NSDictionary<NSString *, NSString *> *RLPWorkbenchClearFilterOverridePayload(void);

/// 手动覆盖的人话摘要；无覆盖时返回 nil。
NSString *_Nullable RLPWorkbenchFilterOverrideSummary(NSDictionary *_Nullable settings);

/// 音质监控行：仅映射实际 /api/status 字段，无值统一返回 @"N/A"（绝不臆造）。
/// 每项包含 @{@"group": ..., @"key": ..., @"label": ..., @"value": ...}。
NSArray<NSDictionary<NSString *, NSString *> *> *RLPWorkbenchMonitorRows(NSDictionary *_Nullable status);

/// 是否可分析的本地音频路径（排除空串、http/https/upnp/airplay 等流媒体路径）。
BOOL RLPWorkbenchIsLocalAudioPath(NSString *_Nullable path);

/// 解开 /api/health 外层（优先取 health 子字典，否则返回顶层）。
NSDictionary *_Nullable RLPWorkbenchUnwrapHealth(NSDictionary *_Nullable json);

/// 由 /api/health 结果推导「动态 / 音质 / 假无损」三摘要与 incomplete 标志。
/// 返回 @{@"dyn": ..., @"qual": ..., @"fake": ..., @"incomplete": @"1"|@"0"}。
NSDictionary<NSString *, NSString *> *RLPWorkbenchAnalysisSummaries(NSDictionary *_Nullable health);

/// 自动分析去重判定：仅在总开关与 autoanl 均开启、正在播放、本地文件、未缓存且本曲未跑过时返回 YES。
BOOL RLPWorkbenchShouldAutoAnalyze(NSString *_Nullable path,
                                   BOOL playing,
                                   BOOL masterEnabled,
                                   BOOL autoEnabled,
                                   NSString *_Nullable alreadyDonePath,
                                   BOOL busy,
                                   BOOL hasResult);

NS_ASSUME_NONNULL_END
