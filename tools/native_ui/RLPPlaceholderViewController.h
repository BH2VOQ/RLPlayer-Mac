// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 尚未迁移到原生 UI 的页面：如实显示“仍在 web 版”，绝不假装功能已存在。
@interface RLPPlaceholderViewController : NSViewController
- (instancetype)initWithTitle:(NSString *)title;
@end

NS_ASSUME_NONNULL_END
