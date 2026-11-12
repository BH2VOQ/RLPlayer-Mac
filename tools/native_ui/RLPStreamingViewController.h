// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPPageViewController.h"

@interface RLPStreamingViewController : RLPPageViewController
/// 未配置服务器时的整页空态卡是否可见（运行时判据用）。
@property (nonatomic, readonly) BOOL emptyStateVisible;
@end
