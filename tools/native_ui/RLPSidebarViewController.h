// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 左侧导航。**结构 1:1 对齐 web 版**（ui_page.h 的 .side）：
///   资料库   : 专辑 / 艺术家 / 曲目 / 文件夹 / 流媒体
///   播放列表 : 播放队列 / 最近播放 / 我的最爱 / 保存的队列
///   音频引擎 : 快速开始 / 设置
/// 路由用**符号 key**（见 -selectKey:），不用裸行号 —— 顺序变化后行号会错位。
@interface RLPSidebarViewController : NSViewController

/// 选中回调（row 即导航项下标）。
@property (nonatomic, copy, nullable) void (^onSelect)(NSInteger row);

/// 选中回调（符号 key，主窗口按 key 路由；与 onSelect 同时发）。
@property (nonatomic, copy, nullable) void (^onSelectKey)(NSString *key);

/// 第 row 项的符号 key（越界返回 nil）。
- (nullable NSString *)keyForRow:(NSInteger)row;
/// 按符号 key 选中（不存在则忽略，返回 NO）。
- (BOOL)selectKey:(NSString *)key;
/// 当前选中项的符号 key（未选中返回 nil）。
@property (nonatomic, copy, readonly, nullable) NSString *selectedKey;
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