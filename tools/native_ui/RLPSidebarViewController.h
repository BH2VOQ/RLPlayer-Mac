// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 左侧导航（10 个入口，与 web 版信息架构一一对应）。
@interface RLPSidebarViewController : NSViewController

/// 选中回调（row 即导航项下标；0 = 专辑）。
@property (nonatomic, copy, nullable) void (^onSelect)(NSInteger row);

/// 当前导航项数（selftest/自检用）。
@property (nonatomic, readonly) NSInteger rowCount;

/// 当前选中的导航行（-1 = 未选中）。详情页返回时用它对回原列表页。
@property (nonatomic, readonly) NSInteger selectedRow;

/// 当前悬停行（-1 = 无）。侧栏表格把鼠标位置转进来，用于画悬停底色。
@property (nonatomic, readonly) NSInteger hoverRow;
- (void)sidebarHoverAtPoint:(NSPoint)point;

/// 以代码方式选中某一行（不触发 onSelect 以外的副作用由实现保证幂等）。
- (void)selectRow:(NSInteger)row;

/// 主题切换后刷新自建颜色（背景/文字/选中态）。
- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END