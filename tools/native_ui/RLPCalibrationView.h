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
- (void)applyLanguage;
/// 嵌入设置页时调用：去掉本视图自己的滚动条，由外层页面统一滚动。
- (void)setEmbeddedInPage:(BOOL)embedded;
/// 房间校正 IR 段（web cal 页第三张 sgroup 的卡体）。设置页整段搬进那张卡片；
/// 同一份视图、同一份交互，不复制第二套控件。
@property (nonatomic, readonly, nullable) NSView *irSectionView;
/// 内容自然高度（嵌入设置页时由设置页用它给高度约束）。
- (CGFloat)preferredContentHeight;
@end

NS_ASSUME_NONNULL_END
