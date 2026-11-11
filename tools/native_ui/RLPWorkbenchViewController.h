// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import "RLPPageViewController.h"

NS_ASSUME_NONNULL_BEGIN

/// 专业工作台（专业模式首页）：信号链 + 快速滤波/升频/输出/EQ 切换 + A/B 配置槽。
/// 面向发烧友：凡是会反复调的东西都摆在这里，当场切换，不用进设置。
@interface RLPWorkbenchViewController : RLPPageViewController
@end

NS_ASSUME_NONNULL_END
