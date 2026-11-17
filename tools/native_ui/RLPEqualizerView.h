// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 均衡子界面（20 段 PEQ + OPRA 耳机曲线），嵌进设置页「均衡」页签。
/// 曲线点由后端 /api/peq 的 points 给出 —— UI 不自己算第二份频响。
@interface RLPEqualizerView : NSView
- (void)reload;
- (void)applyTheme;
- (void)applyLanguage;
/// 嵌入设置页（页面本身已有一个整页滚动容器）时调用：去掉本视图自己的滚动条，
/// 内容直接铺开、由外层页面滚动。用户实测「EQ 页三个滚动条，只要外面那个」。
- (void)setEmbeddedInPage:(BOOL)embedded;
/// 内容自然高度（embedded 模式下由设置页用它给高度约束）。
- (CGFloat)preferredContentHeight;
/// 内容高度变了（OPRA 卡片异步到达 / 预设墙展开 / 表格行数变化）时的通知。
/// 宿主必须据此**双向**更新高度约束 —— 只放大不缩小会留一片空白，
/// 不通知则卡片高度停在"0 行"时的值、内容溢出卡片边框。
@property (nonatomic, copy, nullable) void (^onContentSizeChanged)(void);
/// OPRA 段（web「耳机 EQ（OPRA 校准预设）」卡体）。设置页把它整段搬进第二张卡片；
/// 同一份视图、同一份交互，不复制第二套控件。
@property (nonatomic, readonly, nullable) NSView *opraSectionView;
@end

NS_ASSUME_NONNULL_END
