// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import "RLPPageViewController.h"

NS_ASSUME_NONNULL_BEGIN

/// 设置页（原生）：10 个页签，与 web 版设置页一一对应。
///
/// 页签顺序与 web 版一致（data-g）：out / pcm / sdm / in / adv / eq / cal / stream / diag / meta。
/// 外观（主题 light/dark）按用户要求只在**这里**改，顶栏不再放切换按钮。
@interface RLPSettingsViewController : RLPPageViewController

/// 打开设置并切到指定页签（"out"/"pcm"/"sdm"/"in"/"adv"/"eq"/"cal"/"stream"/"diag"/"meta"）。
/// 供其他页面「去设置里配置」使用；未知 key 时停在当前页签。
- (void)selectPane:(NSString *)key;

@end

NS_ASSUME_NONNULL_END
