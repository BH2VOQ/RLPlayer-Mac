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
@end

NS_ASSUME_NONNULL_END
