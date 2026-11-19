// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_mode_settings_readback.mm — 双模式页面的「设置读回」真链路判据（1.1.7.1）
//
// 触发原因是一个**真 BUG**（本轮自查抓到，离线判据抓不到）：
//   /api/settings 的值在 **kv 子对象**里，而聆听室/工作台/播放页最初读的是顶层
//   ⟹ 所有值静默回落默认：界面显示与真实设置脱节，A/B 快照还会抓成空。
//   三条离线测试（listening_room / workbench / analysis_row）都不启动核心，
//   所以它们全绿也证明不了"读回对不对" —— 必须有一条**真核心**判据。
//
// 判据：写一个非默认值 → 读回 → 断言页面真的拿到了它（而不是默认值）。
// 纪律：隔离 state/library，backend=null、volume=-120，绝不打开音频设备、绝不出声。
#import <AppKit/AppKit.h>
#import "RLPCoreClient.h"
#import "RLPWorkbench.h"
#import "RLPListeningRoom.h"

#include <cstdio>
#include <cstdlib>
#include <unistd.h>

static int gFail = 0, gPass = 0;
static void CK(BOOL ok, const char *what, NSString *detail) {
    if (ok) { ++gPass; std::printf("  [PASS] %s\n", what); }
    else { ++gFail; std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); }
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        std::printf("=== test_mode_settings_readback（真核心 · 隔离目录 · 不出声）===\n");

        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"rlp-readback-%d", (int)getpid()]];
        NSString *state = [root stringByAppendingPathComponent:@"state"];
        NSString *lib = [root stringByAppendingPathComponent:@"lib"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:lib withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("RLPLAYER_STATE_DIR", state.fileSystemRepresentation, 1);
        setenv("RLPLAYER_LIBRARY_DIR", lib.fileSystemRepresentation, 1);

        RLPCoreClient *core = [RLPCoreClient shared];
        if (![core startEmbedded]) { std::printf("  [FAIL] 核心启动失败\n"); return 1; }

        // 绝不出声：null 后端 + 极低音量
        [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"backend=null&volume=-120"];

        // ---- ① /api/settings 的形状：值必须在 kv 里（这是本轮 BUG 的根源）----
        NSDictionary *got = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil];
        NSDictionary *kv = [got[@"kv"] isKindOfClass:[NSDictionary class]] ? got[@"kv"] : nil;
        CK(kv != nil, "R1 /api/settings 的值在 kv 子对象里", got.description ?: @"nil");
        CK([kv[@"backend"] isEqualToString:@"null"], "R2 写入 backend=null 后读回一致",
           kv[@"backend"] ?: @"nil");

        // ---- ② 写非默认值 → 读回（模拟聆听室/工作台的读法）----
        [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"hogexcl=0&rate=176400&dsd=0&eq=1"];
        NSDictionary *kv2 = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil][@"kv"];
        CK([kv2[@"hogexcl"] isEqualToString:@"0"], "R3 hogexcl=0 读回（顶层读法会拿到默认 1）",
           kv2[@"hogexcl"] ?: @"nil");
        CK([kv2[@"rate"] isEqualToString:@"176400"], "R4 rate=176400 读回", kv2[@"rate"] ?: @"nil");
        CK([kv2[@"eq"] isEqualToString:@"1"], "R5 eq=1 读回", kv2[@"eq"] ?: @"nil");
        // 顶层确实没有这些键 —— 证明"读顶层"必然错
        CK(got[@"hogexcl"] == nil, "R6 顶层没有 hogexcl（所以读顶层必错）", @"");

        // ---- ③ A/B 快照必须从 kv 抓，且不含危险键 ----
        NSDictionary *snap = RLPABSnapshotFromSettings(kv2);
        CK(snap.count > 0, "R7 从 kv 抓到的 A/B 快照非空（读顶层会抓成空）",
           [NSString stringWithFormat:@"count=%lu", (unsigned long)snap.count]);
        CK([snap[@"rate"] isEqualToString:@"176400"], "R8 快照含真实 rate", snap[@"rate"] ?: @"nil");
        for (NSString *k in @[@"device", @"backend", @"hogexcl"])
            CK(snap[k] == nil, [[NSString stringWithFormat:@"R9 快照不含危险键 %@", k] UTF8String], snap[k] ?: @"");

        // ---- ④ 切槽真的落盘（A/B 的核心动作）----
        NSString *body = RLPABFormBody(snap);
        [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"rate=96000"];
        NSDictionary *mid = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil][@"kv"];
        CK([mid[@"rate"] isEqualToString:@"96000"], "R10 先改成别的值", mid[@"rate"] ?: @"nil");
        [core jsonWithMethod:@"POST" path:@"/api/settings" body:body];
        NSDictionary *back = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil][@"kv"];
        CK([back[@"rate"] isEqualToString:@"176400"], "R11 应用槽后 rate 回到快照值", back[@"rate"] ?: @"nil");
        CK(RLPABMatchSlot(back, @[snap]) == 0, "R12 应用槽后命中该槽", @"");

        // ---- ⑤ 滤波名单是真的，听音风格映射落在名单内 ----
        NSDictionary *fj = [core jsonWithMethod:@"GET" path:@"/api/filters" body:nil];
        NSArray *items = [fj[@"items"] isKindOfClass:[NSArray class]] ? fj[@"items"] : @[];
        CK(items.count > 0, "R13 /api/filters 返回真实滤波表",
           [NSString stringWithFormat:@"count=%lu", (unsigned long)items.count]);
        NSString *warm = RLPFilterForToneStyle(RLPToneStyleWarm, items);
        NSString *sharp = RLPFilterForToneStyle(RLPToneStyleSharp, items);
        BOOL warmExists = NO, sharpExists = NO;
        for (NSDictionary *it in items) {
            if ([it[@"name"] isEqualToString:warm]) warmExists = YES;
            if ([it[@"name"] isEqualToString:sharp]) sharpExists = YES;
        }
        CK(warmExists, "R14 温和档选出的滤波真实存在", warm ?: @"nil");
        CK(sharpExists, "R15 锐利档选出的滤波真实存在", sharp ?: @"nil");
        // 写进去能落盘（证明键选对了：filter vs filterNx）
        if (warm.length) {
            BOOL nx = RLPFilterUsesNxKey(warm, items);
            NSString *k = nx ? @"filterNx" : @"filter";
            [core jsonWithMethod:@"POST" path:@"/api/settings"
                body:[NSString stringWithFormat:@"%@=%@", k, warm]];
            NSDictionary *kv3 = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil][@"kv"];
            CK([kv3[k] isEqualToString:warm], "R16 听音风格写入后读回一致（键选对）",
               [NSString stringWithFormat:@"%@=%@", k, kv3[k] ?: @"nil"]);
        }

        // ---- ⑥ 队列契约：键是 items（不是 queue），meta=1 给 metas ----
        NSDictionary *qj = [core jsonWithMethod:@"GET" path:@"/api/queue?meta=1" body:nil];
        CK([qj[@"items"] isKindOfClass:[NSArray class]],
           "R17 /api/queue 的键是 items（读 queue 会永远显示空）", qj.description ?: @"nil");
        CK(qj[@"queue"] == nil, "R18 顶层没有 queue 键（所以读 queue 必错）", @"");

        // ---- ⑦ 专辑契约：名字字段是 name（不是 al）----
        NSDictionary *aj = [core jsonWithMethod:@"GET" path:@"/api/lib/albums" body:nil];
        CK([aj[@"albums"] isKindOfClass:[NSArray class]], "R19 /api/lib/albums 返回 albums 数组", @"");

        // ---- ⑧ 暂停/继续契约：/api/pause?on= 存在且接受 on 参数 ----
        // 不实际播放（backend=null），只验证端点不会把 on 当未知参数拒掉。
        NSDictionary *pj = [core jsonWithMethod:@"POST" path:@"/api/pause?on=1" body:nil];
        CK(pj != nil && [pj[@"ok"] boolValue], "R20 /api/pause?on=1 被接受（继续用 on=0，不是 /api/play）",
           pj.description ?: @"nil");

        [core shutdown];
        [fm removeItemAtPath:root error:nil];
        std::printf("\n%s（%d 项失败）\n", gFail == 0 ? "mode_settings_readback 全部通过" : "mode_settings_readback 有失败", gFail);
        return gFail == 0 ? 0 : 1;
    }
}
