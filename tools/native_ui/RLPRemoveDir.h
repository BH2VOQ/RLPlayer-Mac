// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPRemoveDir.h — 删除磁盘目录的确认文案（纯函数，可测）
//
// 对齐 web 设置页 confirmRemoveDir 的确认框内容：路径原文、文件/子目录数、
// 不可恢复（不进废纸篓）、"只想移出库用设置里的移除"提示。
// 破坏性操作的安全纪律：**先 /api/lib/rmdirinfo 统计成功（ok:true 且拿到数字）才弹确认**，
// UI 层不许跳过统计直接删。这里只负责"给什么数字就拼什么确认文案"，不碰磁盘、不碰网络。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 确认框的 messageText（标题）。
NSString *RLPRemoveDirAlertTitle(void);

/// 确认框的 informativeText（正文）。dir 原样写入，files/dirs 来自 rmdirinfo。
/// 会包含：路径原文、将删除 N 个文件（+ M 个子目录）、不可恢复、不进废纸篓、移出库提示。
NSString *RLPRemoveDirAlertBody(NSString *dir, NSInteger files, NSInteger dirs);

/// 确认按钮标题（写明删几个文件，让用户最后一眼看清范围）。
NSString *RLPRemoveDirConfirmButtonTitle(NSInteger files);

/// 成功后提示（含 removedTracks 时说明同时清掉索引记录）。
NSString *RLPRemoveDirSuccessText(NSInteger files, NSInteger removedTracks);

NS_ASSUME_NONNULL_END