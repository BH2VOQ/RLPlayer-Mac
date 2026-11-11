// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 音频输入采集子界面，嵌进设置页「输入」页签。
@interface RLPInputView : NSView
- (void)reload;
- (void)applyTheme;
@end

NS_ASSUME_NONNULL_END
