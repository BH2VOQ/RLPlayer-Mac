// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_remove_dir.mm — 删除磁盘目录的安全判据（2026-11-12 用户授权移植）
//
// 破坏性操作**绝不在这条测试里真删磁盘**：
//   ① 纯函数：确认文案必须含路径原文 / 文件数 / 不可恢复 / 不进废纸篓 / 移出库提示；
//   ② 真核心：库外目录 /api/lib/rmdirinfo 返回 ok:false（后端安全校验），
//      证明"拿不到数字就不弹确认、不删"的防线有效；
//   ③ 后端契约：rmdirinfo 与 rmdir 共用同一套 checkRemovableDirLocked（源码静态核对）。
#import <Foundation/Foundation.h>
#import "RLPRemoveDir.h"
#import "RLPCoreClient.h"
#import "RLPSupport.h"

#include <cstdio>
#include <cstdlib>
#include <unistd.h>

static int gFail = 0, gPass = 0;
static void CK(BOOL ok, const char *what, NSString *detail) {
    if (ok) { ++gPass; std::printf("  [PASS] %s\n", what); }
    else { ++gFail; std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); }
}
static void Pump(NSTimeInterval s) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:s];
    while ([until timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        std::printf("=== test_remove_dir（确认文案 + 后端安全防线，绝不真删磁盘）===\n");

        // ---- R1 确认文案（纯函数）----
        NSString *dir = @"/Volumes/Music/Jazz/Kind of Blue";
        NSString *body = RLPRemoveDirAlertBody(dir, 12, 3);
        CK([body containsString:dir], "R1a 确认框含目录路径原文", body ?: @"nil");
        CK([body containsString:@"12"], "R1b 确认框含文件数", @"");
        CK([body containsString:@"3"], "R1c 确认框含子目录数", @"");
        CK([body containsString:RLPTr(@"此操作不可恢复（不进废纸篓）。")],
           "R1d 确认框写明不可恢复/不进废纸篓", @"");
        CK([body containsString:RLPTr(@"只想让它不出现在曲库里？用设置里的「移除」即可，那个不碰磁盘。")],
           "R1e 确认框提示「只想移出库用移除」", @"");
        NSString *title = RLPRemoveDirAlertTitle();
        CK([title containsString:RLPTr(@"不可恢复")], "R1f 标题含不可恢复", title ?: @"nil");
        NSString *btn = RLPRemoveDirConfirmButtonTitle(12);
        CK([btn containsString:@"12"] && [btn containsString:RLPTr(@"删除")],
           "R1g 确认按钮写明删几个文件", btn ?: @"nil");
        // 无子目录时不含"个子目录"（不拼空段）。
        NSString *bodyNoDirs = RLPRemoveDirAlertBody(dir, 5, 0);
        CK(![bodyNoDirs containsString:RLPTr(@"个子目录")], "R1h 无子目录不拼空段", @"");
        // 成功提示含索引清理数
        NSString *succ = RLPRemoveDirSuccessText(12, 7);
        CK([succ containsString:@"12"] && [succ containsString:@"7"],
           "R1i 成功提示含删除数与索引清理数", succ ?: @"nil");

        // ---- R2 真核心：库外目录必须被 rmdirinfo 拒绝（不弹确认、不删）----
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"rlp-rmdir-%d", (int)getpid()]];
        NSString *state = [root stringByAppendingPathComponent:@"state"];
        NSString *lib = [root stringByAppendingPathComponent:@"lib"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:lib withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("RLPLAYER_STATE_DIR", state.fileSystemRepresentation, 1);
        setenv("RLPLAYER_LIBRARY_DIR", lib.fileSystemRepresentation, 1);
        RLPCoreClient *core = [RLPCoreClient shared];
        if (![core startEmbedded]) { std::printf("  [FAIL] 核心启动失败\n"); return 1; }
        [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"backend=null&volume=-120"];

        // 一个肯定不在库根之下的路径（临时目录下的假目录），后端安全校验应拒绝。
        NSString *outside = [root stringByAppendingPathComponent:@"not-a-root"];
        NSString *infoBody = [NSString stringWithFormat:@"dir=%@", RLPEnc(outside)];
        NSDictionary *info = [core jsonWithMethod:@"POST" path:@"/api/lib/rmdirinfo" body:infoBody];
        CK(info != nil && ![info[@"ok"] boolValue],
           "R2a 库外目录 rmdirinfo 返回 ok:false（后端安全校验拒绝）", info.description ?: @"nil");
        CK([info[@"error"] isKindOfClass:[NSString class]] && [info[@"error"] length] > 0,
           "R2b 拒绝时给出明确原因（UI 要如实转达，不吞掉）", [info[@"error"] description] ?: @"nil");
        // 真删端点同样拒绝（防线在后端，不是只在 UI）。
        NSDictionary *del = [core jsonWithMethod:@"POST" path:@"/api/lib/rmdir" body:infoBody];
        CK(del != nil && ![del[@"ok"] boolValue],
           "R2c 库外目录 rmdir 同样被拒（真删不落盘）", del.description ?: @"nil");

        // ---- R3 后端契约静态核对：info 与真删共用同一套安全判据 ----
        NSString *src = [NSString stringWithContentsOfFile:
            @"/Users/august/Downloads/DQ/RLPlayer/src/net/library.h"
            encoding:NSUTF8StringEncoding error:nil];
        CK([src containsString:@"checkRemovableDirLocked"] &&
           [src containsString:@"scanDirForRemoval"] &&
           [src containsString:@"removeDirFromDisk"],
           "R3 后端 info/删除共用 checkRemovableDirLocked（源码核对）", @"");

        [core shutdown];
        [fm removeItemAtPath:root error:nil];
        std::printf("\n%s（%d 项失败）\n", gFail == 0 ? "remove_dir 全部通过" : "remove_dir 有失败", gFail);
        return gFail == 0 ? 0 : 1;
    }
}