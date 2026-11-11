// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 均衡子界面（20 段 PEQ + OPRA 耳机曲线），嵌进设置页「均衡」页签。
/// 曲线点由后端 /api/peq 的 points 给出 —— UI 不自己算第二份频响。
@interface RLPEqualizerView : NSView
- (void)reload;
- (void)applyTheme;
@end

NS_ASSUME_NONNULL_END
