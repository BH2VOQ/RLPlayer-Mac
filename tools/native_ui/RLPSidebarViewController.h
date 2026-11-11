// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 左侧导航。**导航项随模式变化**（1.1.7.1）：
///   聆听模式：聆听室 + 曲库浏览 + 播放相关，**没有「设置」入口**（要动设置去专业模式）。
///   专业模式：专业工作台 + 全部曲库浏览 + 设置。
/// 路由用**符号 key**（见 -selectKey:），不用裸行号 —— 模式切换后行号会错位。
@interface RLPSidebarViewController : NSViewController

/// 选中回调（row 即当前模式下的导航项下标）。
@property (nonatomic, copy, nullable) void (^onSelect)(NSInteger row);

/// 选中回调（符号 key，主窗口按 key 路由；与 onSelect 同时发）。
@property (nonatomic, copy, nullable) void (^onSelectKey)(NSString *key);

/// 当前模式下第 row 项的符号 key（越界返回 nil）。
- (nullable NSString *)keyForRow:(NSInteger)row;
/// 按符号 key 选中（不存在于当前模式则忽略，返回 NO）。
- (BOOL)selectKey:(NSString *)key;
/// 当前选中项的符号 key（未选中返回 nil）。
@property (nonatomic, copy, readonly, nullable) NSString *selectedKey;
/// 模式变化后重建导航项（保留仍存在的选中项，否则回到该模式首项）。
- (void)reloadForModeChange;

/// 当前导航项数（selftest/自检用）。
@property (nonatomic, readonly) NSInteger rowCount;
/// 只数导航行（不含分组标题行）。
@property (nonatomic, readonly) NSInteger navRowCount;

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