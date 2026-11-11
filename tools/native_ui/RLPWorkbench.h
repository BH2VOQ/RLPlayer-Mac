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

/// 信号链节点在给定设置下是否适用（不适用要灰掉并说明原因）。
/// node ∈ src/resample/eq/ir/shaper/sdm/out
BOOL RLPChainNodeApplies(NSString *node, NSDictionary *_Nullable settings);
/// 不适用时的原因（人话）；适用时返回 nil。
NSString *_Nullable RLPChainNodeDisabledReason(NSString *node, NSDictionary *_Nullable settings);

NS_ASSUME_NONNULL_END
