// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 投放（AirPlay / UPnP）子界面，嵌进设置页「流媒体」页签。
/// /api/cast/state 是投放状态的唯一真相源。
@interface RLPCastView : NSView
- (void)reload;
- (void)startPolling;
- (void)stopPolling;
- (void)applyTheme;
- (void)applyLanguage;
@property (nonatomic, readonly) BOOL polling;
@end

NS_ASSUME_NONNULL_END
