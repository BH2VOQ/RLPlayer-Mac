// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_settings_keys.mm — 设置键的「能读能写」判据（真核心）
//
// 为什么需要这一条：控件在界面上（identifier 对得上）**不等于**它的值能落盘。
// 后端的 /api/settings 是**白名单 + 合并写**：不在白名单里的键会被**静默丢弃**
// （返回 ok:true / merged:true，但 conf 里没有它）。这种失败无声无息 ——
// 用户点一下、界面显示已保存、重启后回到默认值。
//
// 判据口径：对 web 设置页真实使用的键，写一个非默认值 → 读回 → 断言一致。
// 只要有一个键被白名单吞掉，这条就红。
//
// 纪律：隔离 state/library；backend=null、volume=-120；绝不打开音频设备、绝不出声。
#import <AppKit/AppKit.h>
#import "RLPCoreClient.h"   // tools/native_ui 已在 include 路径里

#include <cstdio>
#include <cstdlib>
#include <unistd.h>

static int gFail = 0, gPass = 0;
static void CK(BOOL ok, const char *what, NSString *detail) {
    if (ok) { ++gPass; std::printf("  [PASS] %s\n", what); }
    else { ++gFail; std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); }
}

struct KeyCase {
    const char *key;
    const char *value;
    const char *why;
};

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        std::printf("=== test_native_settings_keys（真核心 · 隔离目录 · 不出声）===\n");

        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"rlp-keys-%d", (int)getpid()]];
        NSString *state = [root stringByAppendingPathComponent:@"state"];
        NSString *lib = [root stringByAppendingPathComponent:@"lib"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:lib withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("RLPLAYER_STATE_DIR", state.fileSystemRepresentation, 1);
        setenv("RLPLAYER_LIBRARY_DIR", lib.fileSystemRepresentation, 1);

        RLPCoreClient *core = [RLPCoreClient shared];
        if (![core startEmbedded]) { std::printf("  [FAIL] 核心启动失败\n"); return 1; }

        // 绝不出声
        [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"backend=null&volume=-120"];

        const KeyCase cases[] = {
            { "opraproduct",  "TestHeadphone-X",   "OPRA 耳机型号" },
            { "oprapreset",   "TestPreset-A",      "OPRA 预设" },
            { "scanthreads",  "4",                 "扫描线程数" },
            { "upnpdev",      "uuid:test-dev",     "UPnP 目标渲染器" },
            { "dsdkind",      "iir",               "DSD 源抽取器" },
            { "dsdconv",      "wide",              "DSD 源 Conversion" },
            { "sdmfilt",      "poly-sinc-lp",      "SDM Oversampling 1x" },
            { "sdmfiltnx",    "poly-sinc-nx",      "SDM Oversampling Nx" },
            { "modcut",       "120",               "噪声整形拐点" },
            { "moddith",      "0.5",               "调制器抖动" },
            { "ramp",         "120",               "音量渐变" },
            { "transition",   "0.04",              "过渡带占比" },
            { "trim",         "0,0,0,0,0,0,0,0",   "声道音量微调" },
            { "uistyle",      "classic",           "界面风格" },
            { "naahost",      "192.168.1.9:43210", "NAA 端点" },
            { "inbuf",        "150",               "输入缓冲" },
            { "inseconds",    "30",                "录制时长" },
            { "inoffset",     "2",                 "声道偏移" },
            { "inout",        "/tmp/out.wav",      "录制输出路径" },
            { "channels",     "2",                 "输出声道数" },
            { "phase",        "linear",            "相位覆盖" },
            { "modfamily",    "chebyshev",         "调制器族" },
            { "modorder",     "7",                 "调制器阶数" },
            { "atten",        "60",                "阻带衰减" },
            { "taps",         "16384",             "原型抽头数" },
            { "dsd",          "128",               "DSD 目标率" },
            { "buffer",       "100",               "输出缓冲" },
            { "bits",         "24",                "输出位深" },
            // U5（v3.3.11）：采样率族策略 —— 原生设置页 sp_ratefamily 下拉写的就是这个键。
            { "rateFamilyPolicy", "strict",          "采样率族策略" },
        };

        for (const KeyCase &c : cases) {
            NSString *key = [NSString stringWithUTF8String:c.key];
            NSString *val = [NSString stringWithUTF8String:c.value];
            NSString *body = [NSString stringWithFormat:@"%@=%@", key, val];
            [core jsonWithMethod:@"POST" path:@"/api/settings" body:body];

            NSDictionary *got = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil];
            NSDictionary *kv = [got[@"kv"] isKindOfClass:[NSDictionary class]] ? got[@"kv"] : @{};
            id back = kv[key];
            NSString *backStr = [back isKindOfClass:[NSString class]] ? back : [back description];
            BOOL ok = backStr != nil && ![backStr isEqualToString:@"(null)"];
            if (ok && ![backStr isEqualToString:val]) {
                // 数值键可能被后端规范化（"0.50" -> "0.5"），按数值再比一次
                ok = (backStr.doubleValue == val.doubleValue);
            }
            NSString *detail = [NSString stringWithFormat:@"%s -> 读回 %@", c.why, backStr ?: @"(无)"];
            CK(ok, [[NSString stringWithFormat:@"键 %s 能写能读（%s）", c.key, c.why] UTF8String], detail);
        }

        // ---- 负向判据：白名单外的键不许被当成"写成功" ----
        // 白名单机制的真相是"静默丢弃"；这条钉住它的可观测形式，
        // 免得以后有人以为"POST 回 ok 就代表落盘了"。
        [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"definitely_not_a_key=1"];
        NSDictionary *got2 = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil];
        NSDictionary *kv2 = [got2[@"kv"] isKindOfClass:[NSDictionary class]] ? got2[@"kv"] : @{};
        CK(kv2[@"definitely_not_a_key"] == nil,
           "白名单外的键被丢弃（证明上面的读回不是恒真）", kv2[@"definitely_not_a_key"]);

        [core shutdown];
        std::printf("\n%s（%d 项失败）\n", gFail == 0 ? "settings keys 全部通过" : "settings keys 有失败", gFail);
        return gFail == 0 ? 0 : 1;
    }
}
