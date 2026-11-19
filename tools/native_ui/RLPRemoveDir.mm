// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPRemoveDir.mm — 删除磁盘目录确认文案（纯函数，契约见 .h）
//
// 文案逐条对齐 web ui_script.h confirmRemoveDir：
//   "即将从磁盘永久删除下面这个目录：" + 路径原文 + "将删除 N 个文件、M 个子目录。"
//   + "此操作不可恢复（不进废纸篓）。" + "只想让它不出现在曲库里？用设置里的「移除」即可，那个不碰磁盘。"
// 数字完全来自调用方（/api/lib/rmdirinfo），这里不臆造。
#import "RLPRemoveDir.h"
#import "RLPSupport.h"

NSString *RLPRemoveDirAlertTitle(void) {
    return RLPTr(@"删除磁盘目录（不可恢复）");
}

NSString *RLPRemoveDirAlertBody(NSString *dir, NSInteger files, NSInteger dirs) {
    NSString *count = dirs > 0
        ? [NSString stringWithFormat:RLPTr(@"将删除 %ld 个文件、%ld 个子目录。"), (long)files, (long)dirs]
        : [NSString stringWithFormat:RLPTr(@"将删除 %ld 个文件。"), (long)files];
    return [NSString stringWithFormat:@"%@\n%@\n%@\n%@\n%@",
            RLPTr(@"即将从磁盘永久删除下面这个目录："),
            dir ?: @"",
            count,
            RLPTr(@"此操作不可恢复（不进废纸篓）。"),
            RLPTr(@"只想让它不出现在曲库里？用设置里的「移除」即可，那个不碰磁盘。")];
}

NSString *RLPRemoveDirConfirmButtonTitle(NSInteger files) {
    return [NSString stringWithFormat:RLPTr(@"删除 %ld 个文件"), (long)files];
}

NSString *RLPRemoveDirSuccessText(NSInteger files, NSInteger removedTracks) {
    NSString *base = [NSString stringWithFormat:RLPTr(@"已删除 %ld 个文件"), (long)files];
    if (removedTracks > 0)
        return [base stringByAppendingFormat:@"，%@",
                [NSString stringWithFormat:RLPTr(@"同时清掉 %ld 首索引记录"), (long)removedTracks]];
    return base;
}
