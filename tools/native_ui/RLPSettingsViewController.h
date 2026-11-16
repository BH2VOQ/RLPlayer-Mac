// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import "RLPPageViewController.h"

NS_ASSUME_NONNULL_BEGIN

/// 设置页（原生）：页签 = web `data-g` 的同一份清单，**不随模式变化**。
///
/// 聆听 / 专业模式共享同一份完整设置清单，只按通用 / 音频处理分组。
/// 确切页签清单以 `RLPSettingsTabKeys()` 为准（parity 判据比对 web `data-g`）。
///
/// station 随界面模式进入聆听室或专业工作台；设置里的音频处理深链始终可用。
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

/// 同步当前界面模式（"listen" / "pro"）。两种模式均可打开全部 10 个设置页签，不强制切 pro。
@property (nonatomic, copy) NSString *uiMode;
- (void)applyUiMode:(NSString *)mode;

@end

NS_ASSUME_NONNULL_END
