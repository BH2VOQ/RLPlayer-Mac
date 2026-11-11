// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import "RLPPageViewController.h"

NS_ASSUME_NONNULL_BEGIN

/// 设置页（原生）：页签随模式。
///
/// 专业模式 7 页：play / in / cal / stream / meta / adv / diag
/// （输出/PCM/SDM/均衡在专业工作台当场切换，设置不重复）。
/// 聆听模式 11 页：play / out / pcm / sdm / eq / in / cal / stream / meta / adv / diag
/// （没有工作台 ⟹ 设置必须挂全，功能不因模式而不可达）。
/// 外观（主题 light/dark）按用户要求只在**这里**改，顶栏不再放切换按钮。
@interface RLPSettingsViewController : RLPPageViewController

/// 打开设置并切到指定页签（"play"/"out"/"pcm"/"sdm"/"eq"/"in"/"adv"/"cal"/"stream"/"diag"/"meta"）。
/// 供其他页面「去设置里配置」使用；未知 key 时停在当前页签。
/// 专业模式下 out/pcm/sdm/eq 映射到 play（那四页在工作台）。
- (void)selectPane:(NSString *)key;

/// 当前页签的符号 key（判据用：证明 selectPane 真的切到位，不是静默映射走）。
- (NSString *)currentPaneKey;

/// 拉取 /api/llm/models 刷新模型下拉；力刷走 ?refresh=1。进页自动调一次（判据也可显式触发）。
- (void)loadLlmModels:(BOOL)force;

@end

NS_ASSUME_NONNULL_END
