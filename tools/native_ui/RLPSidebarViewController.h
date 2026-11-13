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
/// 最后一次「已新建歌单：<name>」提示文案。
/// 为什么要有这个出口：toast 只活 ~1.8s，自动化判据在忙时会整段错过那个窗口（实测偶发假红）；
/// 而"新建歌单的提示带上歌单名"是**产品行为**，不该因为窗口短暂就无法断言。
@property (nonatomic, copy, readonly, nullable) NSString *lastSavedQueueToast;

/// 当前悬停行（-1 = 无）。侧栏表格把鼠标位置转进来，用于画悬停底色。
@property (nonatomic, readonly) NSInteger hoverRow;
- (void)sidebarHoverAtPoint:(NSPoint)point;

/// 以代码方式选中某一行（不触发 onSelect 以外的副作用由实现保证幂等）。
- (void)selectRow:(NSInteger)row;

/// 判据负向对照（只给 --audit 用）：YES 时忽略 /api/sq/list，等价于
/// 2026-11-13 之前的「静态一行保存的队列」旧实现。用来证明侧栏动态列表的判据
/// 在这份实现上**确实是红的**，而不是恒真的摆设。
@property (nonatomic, assign) BOOL ignoreSavedQueues;

/// 重新拉取「我的歌单」（GET /api/sq/list）并重建导航行。
/// 核心启动后由主窗口调一次；歌单变更时由 RLPSavedQueuesChangedNotification 触发。
- (void)reloadSavedQueues;

/// 已渲染的歌单行数（不含分组标题与空态行）。运行时判据用。
@property (nonatomic, readonly) NSInteger savedQueueRowCount;
/// 已渲染的歌单名（顺序与侧栏一致）。运行时判据用。
@property (nonatomic, copy, readonly) NSArray<NSString *> *savedQueueNames;
/// 按歌单下标重命名（✎ 按钮走同一实现）。完成后重建行并广播变更通知。
- (void)renameSavedQueueAtIndex:(NSInteger)index to:(NSString *)newName;
/// 按歌单下标删除（× 按钮走同一实现）。
- (void)deleteSavedQueueAtIndex:(NSInteger)index;

/// 新建歌单（对话框与判据共用同一条落库路径：POST /api/sq/add → toast 带名字 → 进该歌单页）。
- (void)createSavedQueueNamed:(NSString *)name;

/// 点选某份歌单（侧栏行点击 / 新建成功后沿用 web 的 renderSavedQueuePage(name) 语义）。
- (void)openSavedQueueNamed:(NSString *)name;

/// 主题切换后刷新自建颜色（背景/文字/选中态）。
- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END