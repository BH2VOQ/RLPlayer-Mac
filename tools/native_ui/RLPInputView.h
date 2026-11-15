// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 音频输入采集子界面，嵌进设置页「输入」页签。
@interface RLPInputView : NSView
/// 只显示「采集实时状态」区块（配置控件由设置页的卡片字段承载）。
/// 2026-11-14：设置页输入页出现「卡片内一套 + 卡片外又一套」的重复控件，
/// 根因就是本视图把**整套配置**和状态一起搬上了页面。用这个入口只留状态。
- (instancetype)initStatusOnlyWithFrame:(NSRect)frame;
@property (nonatomic, readonly) BOOL statusOnly;
- (void)reload;
- (void)applyTheme;
/// 嵌入一个**本身已经整页滚动**的宿主（设置页）时调用：去掉本视图自带的 NSScrollView，
/// 内容直接铺开，由宿主页面滚动（用户 2026-11-15：每个界面只允许整页滚动，禁止小页面滚动）。
- (void)setEmbeddedInPage:(BOOL)embedded;
/// 内容自然高度（embedded 模式下由宿主给高度约束；本视图没有 intrinsic 高度）。
- (CGFloat)preferredContentHeight;
@end

NS_ASSUME_NONNULL_END
