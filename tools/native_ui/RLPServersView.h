// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPServersView.h — 流媒体服务器的增删改 + 启用 + 测试（设置·流媒体页内嵌）
//
// 对齐 web 版设置→流媒体的服务器管理（ui_script.h 的 SRC / srcShowForm / renderSrcList）：
//   GET  /api/src/config  → {servers:[{id,name,kind,base,user,hasPass,active}], active}
//   POST /api/src/config   action=add|update|remove|active（update 时 pass 留空 = 保持原密码）
//   POST /api/src/ping     表单里未保存的配置也能先测；?id=… 测已保存的某台
// 密码红线：GET 不回明文，界面也不回填；编辑时留空即不改。
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface RLPServersView : NSView
/// 从后端拉服务器列表并重建行（核心未启动时显示如实提示，不填假数据）。
- (void)reload;
- (void)applyTheme;
- (void)applyLanguage;
@end

NS_ASSUME_NONNULL_END