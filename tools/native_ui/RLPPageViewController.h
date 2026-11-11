// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 所有原生内容页的基类：
///   * 统一背景/标题/副标题与内容容器；
///   * 页面被切到前台时调用 activate（默认 reloadData）；
///   * 主题切换时调用 applyTheme（子类若自建颜色需覆盖）。
@interface RLPPageViewController : NSViewController

- (instancetype)initWithTitle:(NSString *)title;

@property (nonatomic, copy, readonly) NSString *pageTitle;
@property (nonatomic, strong, readonly) NSTextField *titleLabel;
@property (nonatomic, strong, readonly) NSTextField *subtitleLabel;
/// 子类把内容加到这里（已铺满标题下方）。
@property (nonatomic, strong, readonly) NSView *contentView;

/// 子类在这里搭内容（loadView 期间调用一次）。
- (void)buildContent;
/// 页面激活时刷新（默认空实现；子类按需覆盖）。
- (void)reloadData;
/// 切到前台。
- (void)activate;
/// 主题切换后刷新自建颜色（默认刷新背景/标题；子类覆盖时先调 super）。
- (void)applyTheme;

/// 便捷：设置标题右侧的计数/状态文字。
- (void)setSubtitle:(NSString *)text;

@end

NS_ASSUME_NONNULL_END
