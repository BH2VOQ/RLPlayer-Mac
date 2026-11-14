// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import "RLPPageViewController.h"

NS_ASSUME_NONNULL_BEGIN

/// 快速开始（原生首页）：三张能力卡 + 官方推荐预设 + 四个快捷入口。
@interface RLPQuickStartViewController : RLPPageViewController

/// 纯函数：`/api/preset/caps` 响应 → @{known, pcmReady, dsdReady}（v3.3.11 `quickStartModel` 移植）。
/// 「播放方式」弹层按这三个值置灰；判据直接测它，不靠布局时机。
+ (NSDictionary<NSString *, NSNumber *> *)gatingForCapsJSON:(NSDictionary * _Nullable)json;

@end

NS_ASSUME_NONNULL_END
