// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 声音校准子界面（房间测量向导 + 校正 IR），嵌进设置页「校准」页签。
/// 铁律 1：测量会真的出声 ⟹ 必须先取 /api/roomcorr/plan 把设备/时长/电平
/// 摆给用户确认，用户点了才发 measure。绝不自动开始。
@interface RLPCalibrationView : NSView
- (void)reload;
- (void)applyTheme;
@end

NS_ASSUME_NONNULL_END
