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

/// 纯函数：按 caps + settings + 播放态 计算四档（bitperfect/pcm/dsd/pcm2dsd）的
/// @{ enabled: @(BOOL), reason: NSString, result: NSString }。
+ (NSDictionary<NSString *, NSDictionary *> *)presetStatusForCapsJSON:(NSDictionary * _Nullable)json
                                                           settings:(NSDictionary * _Nullable)kv
                                                            playing:(BOOL)playing
                                                             paused:(BOOL)paused;

/// 响应式布局入口（viewDidLayout 自动调用，也可在离线单测中以指定宽度触发）。
- (void)updateResponsiveLayoutForWidth:(CGFloat)availWidth;
- (void)applyLanguage;
- (void)stopPolling;

@end

NS_ASSUME_NONNULL_END
