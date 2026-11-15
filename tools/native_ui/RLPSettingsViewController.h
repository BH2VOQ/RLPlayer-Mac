// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import "RLPPageViewController.h"

NS_ASSUME_NONNULL_BEGIN

/// 设置页（原生）：页签 = web `data-g` 的同一份清单，**不随模式变化**。
///
/// 双模式（聆听 / 专业）已于 2026-11-12 整层拆掉（枚举 / 顶栏切换 / 侧栏分叉 /
/// 设置页签随模式 / 工作台首页），目的是让「web 有的我是否都有」可机械验证。
/// 确切页签清单以 `RLPSettingsTabKeys()` 为准（parity 判据比对 web `data-g`）。
///
/// 历史说明：聆听室（`RLPListeningRoom`）与专业工作台（`RLPWorkbenchViewController`）
/// 两个视图类按铁律①（功能不删）保留在仓里，但**当前无侧栏入口**，属保留组件；
/// 对应 i18n 词条同样保留（引擎侧生成物，不在此处裁剪）。
/// 外观（主题 light/dark）按用户要求只在**这里**改，顶栏不再放切换按钮。
@interface RLPSettingsViewController : RLPPageViewController

/// 打开设置并切到指定页签（"play"/"out"/"pcm"/"sdm"/"eq"/"in"/"adv"/"cal"/"stream"/"diag"/"meta"）。
/// 供其他页面「去设置里配置」使用；未知 key 时停在当前页签。
/// out/pcm/sdm/eq 等页签都真实存在；只有未知 key 才停在当前页签。
- (void)selectPane:(NSString *)key;

/// 当前页签的符号 key（判据用：证明 selectPane 真的切到位，不是静默映射走）。
- (NSString *)currentPaneKey;

/// 拉取 /api/llm/models 刷新模型下拉；力刷走 ?refresh=1。进页自动调一次（判据也可显式触发）。
- (void)loadLlmModels:(BOOL)force;

@end

NS_ASSUME_NONNULL_END
