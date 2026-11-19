// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPMetaSourcesView.h — 元数据数据源开关 + 优先级排序（设置·元数据页内嵌）
//
// 对齐 web 设置·元数据的 sp_metasrc 区块（ui_script.h renderMetaSrcRows）：
//   GET /api/providers → {items:[{id,name,on,canSearch,canLyric}], order, defaultOrder}
//   逐源开关写 metasrc_<id>=0|1；顺序写 metasrcorder=id1,id2,…（顺序即优先级）。
//   「恢复默认」复位到后端 defaultOrder（出厂顺序，不是本次打开时的顺序）。
// 新增数据源前端零改动（按注册表动态渲染，与 web 同口径）。
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface RLPMetaSourcesView : NSView
/// 从后端拉注册表并重建行（核心未启动时如实提示，不填假数据）。
- (void)reload;
- (void)applyTheme;
@end

NS_ASSUME_NONNULL_END