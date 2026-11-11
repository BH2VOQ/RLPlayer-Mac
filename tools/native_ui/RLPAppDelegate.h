// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface RLPAppDelegate : NSObject <NSApplicationDelegate>
@end

/// 离线自检（不启动播放核心、不弹窗）：构建完整视图树并断言关键契约。
/// 返回 0 = 全过，非 0 = 失败项数。供 `rlplayer_native --selftest` 与 ctest 调用。
int RLPAppDelegateRunSelfTest(void);

NS_ASSUME_NONNULL_END
