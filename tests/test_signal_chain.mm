// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_signal_chain.mm — 信号链节点生成判据（对齐 web showChain 的 /api/signal 语义）
//
// 触发原因：web 有 Roon 式信号链弹窗（真实播放路径逐节点），原生工作台只有按设置推导的静态节点，
// 点开看不到"这次实际走了哪条路"。把 JSON→节点做成纯函数后，判据能逐分支钉住，不用起核心。
// 纪律：数字全来自响应，缺字段显 –，绝不编造；降采样绝不给"升频"章（web 2026-11-09 修过）。
#import <Foundation/Foundation.h>
#import "RLPSignalChain.h"

#include <cstdio>

static int gFail = 0, gPass = 0;
static void CK(BOOL ok, const char *what, NSString *detail) {
    if (ok) { ++gPass; std::printf("  [PASS] %s\n", what); }
    else { ++gFail; std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); }
}
static RLPSignalNode *Find(NSArray<RLPSignalNode *> *nodes, NSString *key) {
    for (RLPSignalNode *n in nodes) if ([n.key isEqualToString:key]) return n;
    return nil;
}

int main() {
    @autoreleasepool {
        std::printf("=== test_signal_chain（/api/signal 真实路径 → 节点）===\n");

        // ---- C0 空/未播放响应：不填假节点 ----
        CK([RLPSignalChain nodesForResponse:@{@"ok": @NO}].count == 0,
           "C0a ok:false ⟹ 0 节点（显示「还没有开始播放」）", @"");
        CK([RLPSignalChain nodesForResponse:@{@"ok": @YES}].count == 0,
           "C0b 无 path ⟹ 0 节点", @"");
        NSString *why = nil;
        CK([[RLPSignalChain heroTitleForResponse:@{@"ok": @NO} why:&why] isEqualToString:@"还没有开始播放"],
           "C0c 未播放 hero 标题如实", @"");

        // 一份"标准 PCM 无损路径"夹具
        NSDictionary *base = @{
            @"ok": @YES, @"path": @{
                @"src": @"/music/a.flac", @"codec": @"flac",
                @"inRate": @44100, @"inBits": @16, @"inCh": @2,
                @"outRate": @44100, @"outBits": @16, @"outCh": @2,
                @"device": @"DAC-1", @"transport": @"coreaudio",
                @"sharedOnly": @NO, @"volume": @0,
                @"bitPerfect": @"yes", @"bitPerfectWhy": @"全链路逐位一致",
                @"resample": @NO, @"eq": @NO, @"conv": @NO, @"dsd": @NO,
                @"shaper": @"none", @"preAtten": @0, @"loudness": @NO,
                @"latencyKnown": @YES, @"latencyMs": @12, @"latencySource": @"CoreAudio",
                @"buffer": @256, @"decodeMs": @12.5, @"scanMs": @320,
            }
        };

        // ---- C1 bit-perfect 结论 ----
        CK([[RLPSignalChain heroTitleForResponse:base why:&why] rangeOfString:@"全链路逐位无损"].location != NSNotFound,
           "C1a yes ⟹ 全链路逐位无损", @"");
        CK([why isEqualToString:@"全链路逐位一致"], "C1b why 回填 bitPerfectWhy", why ?: @"nil");
        NSMutableDictionary *bpDirect = [base mutableCopy];
        bpDirect[@"path"] = [@{@"bitPerfect": @"direct"} mutableCopy];
        CK([[RLPSignalChain heroTitleForResponse:bpDirect why:nil] rangeOfString:@"DSD 直通"].location != NSNotFound,
           "C1c direct ⟹ 1-bit DSD 直通", @"");

        // ---- C2 标准无损路径节点 ----
        NSArray *ns = [RLPSignalChain nodesForResponse:base];
        CK([Find(ns, @"源文件").value containsString:@"a.flac"] &&
           [Find(ns, @"源文件").value containsString:@"FLAC"],
           "C2a 源文件 = 文件名 + 大写 codec", Find(ns, @"源文件").value ?: @"nil");
        CK([Find(ns, @"解码").badge isEqualToString:@"无损解码"], "C2c 解码徽标", @"");
        RLPSignalNode *rs = Find(ns, @"采样率转换");
        CK([rs.badge isEqualToString:@"逐位旁路"] && rs.kind == RLPSignalNodeLossless,
           "C2d 不重采样 ⟹ 逐位旁路（无损）", rs.badge ?: @"nil");
        CK(Find(ns, @"EQ / 卷积") == nil, "C2e 无 EQ/IR 不摆节点", @"");
        CK([Find(ns, @"抖动 / 噪声整形").badge isEqualToString:@"逐位直通"], "C2f 无抖动 ⟹ 逐位直通", @"");
        CK([Find(ns, @"音量").badge isEqualToString:@"逐位无损"], "C2g 0 dB ⟹ 逐位无损", @"");
        CK([Find(ns, @"输出").value containsString:@"独占模式"], "C2h 独占输出", @"");
        CK([Find(ns, @"输出").value containsString:@"系统属性延迟 12 ms"], "C2i 延迟如实", @"");
        CK([Find(ns, @"输出").value containsString:@"缓冲 256 ms"], "C2j 缓冲如实", @"");
        CK(Find(ns, @"耗时统计").kind == RLPSignalNodeTel, "C2k 耗时统计是遥测节点", @"");
        CK([Find(ns, @"耗时统计").value containsString:@"12.5 ms"], "C2l 解码耗时来自响应", @"");
        CK([Find(ns, @"耗时统计").value containsString:@"–"], "C2m 缺失耗时显 –（不显示 undefined）", @"");

        // ---- C3 升频 / 降采样方向（web 2026-11-09 真 bug）----
        NSMutableDictionary *up = [base mutableCopy];
        NSMutableDictionary *upP = [base[@"path"] mutableCopy];
        upP[@"resample"] = @YES; upP[@"outRate"] = @176400;
        upP[@"filter"] = @"poly-sinc-long"; upP[@"phase"] = @"线性"; upP[@"taps"] = @16383;
        up[@"path"] = upP;
        RLPSignalNode *upR = Find([RLPSignalChain nodesForResponse:up], @"采样率转换");
        CK([upR.value containsString:@"升频"] && [upR.badge isEqualToString:@"64-Bit 升频"],
           "C3a 44100→176400 ⟹ 升频", upR.badge ?: @"nil");
        NSMutableDictionary *down = [base mutableCopy];
        NSMutableDictionary *downP = [base[@"path"] mutableCopy];
        downP[@"resample"] = @YES; downP[@"outRate"] = @22050;
        down[@"path"] = downP;
        RLPSignalNode *downR = Find([RLPSignalChain nodesForResponse:down], @"采样率转换");
        CK([downR.value containsString:@"降采样"] && [downR.badge isEqualToString:@"64-Bit 降采样"],
           "C3b 44100→22050 ⟹ 降采样（绝不盖章升频）", downR.badge ?: @"nil");
        CK(downR.kind == RLPSignalNodeDsp, "C3c 降采样是 DSP 蓝点（不是绿点/GPU）", @"");
        // 后端显式 rateDir 优先
        NSMutableDictionary *dirP = [upP mutableCopy];
        dirP[@"rateDir"] = @"down";
        NSMutableDictionary *dirResp = [up mutableCopy]; dirResp[@"path"] = dirP;
        CK([Find([RLPSignalChain nodesForResponse:dirResp], @"采样率转换").value containsString:@"降采样"],
           "C3d rateDir 优先于两端速率", @"");
        // GPU 参与
        NSMutableDictionary *gpuP = [upP mutableCopy]; gpuP[@"gpuUsed"] = @YES;
        NSMutableDictionary *gpuResp = [up mutableCopy]; gpuResp[@"path"] = gpuP;
        RLPSignalNode *gpuR = Find([RLPSignalChain nodesForResponse:gpuResp], @"采样率转换");
        CK([gpuR.badge isEqualToString:@"GPU 升频"] && gpuR.kind == RLPSignalNodeGpu,
           "C3e GPU 参与 ⟹ GPU 升频", gpuR.badge ?: @"nil");

        // ---- C4 DSD / DoP ----
        NSMutableDictionary *dsdP = [base[@"path"] mutableCopy];
        dsdP[@"dsd"] = @256; dsdP[@"dsdRate"] = @11289600; dsdP[@"modOrder"] = @7;
        NSMutableDictionary *dsdResp = [base mutableCopy]; dsdResp[@"path"] = dsdP;
        NSArray *dns = [RLPSignalChain nodesForResponse:dsdResp];
        CK(Find(dns, @"DSD 调制") != nil && [Find(dns, @"DSD 调制").value containsString:@"7 阶 SDM"],
           "C4a DSD 调制节点（阶数来自响应）", Find(dns, @"DSD 调制").value ?: @"nil");
        CK([Find(dns, @"DoP 封装").badge isEqualToString:@"DoP 1.1"], "C4b DoP 封装", @"");
        CK(Find(dns, @"抖动 / 噪声整形") == nil, "C4c DSD 路径不摆抖动节点", @"");

        // ---- C5 EQ / ISP / 响度 / 音量衰减 ----
        NSMutableDictionary *dspP = [base[@"path"] mutableCopy];
        dspP[@"eq"] = @YES; dspP[@"conv"] = @YES; dspP[@"convGpu"] = @YES;
        dspP[@"preAtten"] = @-3.0; dspP[@"ispPeak"] = @1.02; dspP[@"ispOver"] = @7;
        dspP[@"loudness"] = @YES; dspP[@"volume"] = @-6.0;
        NSMutableDictionary *dspResp = [base mutableCopy]; dspResp[@"path"] = dspP;
        NSArray *pns = [RLPSignalChain nodesForResponse:dspResp];
        CK([Find(pns, @"EQ / 卷积").badge isEqualToString:@"GPU 卷积"], "C5a GPU 卷积徽标", @"");
        CK(Find(pns, @"EQ / 卷积").kind == RLPSignalNodeGpu, "C5b GPU 卷积节点种类", @"");
        CK([Find(pns, @"峰值保护").value containsString:@"-3.0 dB"], "C5c ISP 预衰减如实", @"");
        CK([Find(pns, @"等响度补偿").badge isEqualToString:@"DSP 响度"], "C5d 响度节点", @"");
        CK([Find(pns, @"音量").badge isEqualToString:@"数字衰减"] &&
           Find(pns, @"音量").kind == RLPSignalNodeDsp, "C5e -6 dB ⟹ 数字衰减", @"");

        // ---- C6 AirPlay / 投放：非 bit-perfect 归因传输本身 ----
        NSMutableDictionary *apP = [base[@"path"] mutableCopy];
        apP[@"transport"] = @"airplay"; apP[@"bitPerfect"] = @"no";
        apP[@"bitPerfectWhy"] = @"Remote output has not been verified bit-for-bit";
        apP[@"sharedOnly"] = @YES; apP[@"latencyKnown"] = @NO;
        NSMutableDictionary *apResp = [base mutableCopy]; apResp[@"path"] = apP;
        CK([[RLPSignalChain heroTitleForResponse:apResp why:nil] containsString:@"AirPlay 传输"],
           "C6a AirPlay 非 bit-perfect 归因传输（不是 DSP）", @"");
        RLPSignalNode *apOut = Find([RLPSignalChain nodesForResponse:apResp], @"输出");
        CK([apOut.badge isEqualToString:@"AirPlay"] && [apOut.value containsString:@"延迟未知"],
           "C6b AirPlay 输出 + 延迟未知如实", apOut.value ?: @"nil");
        NSMutableDictionary *castP = [base[@"path"] mutableCopy];
        castP[@"castDspBypass"] = @YES; castP[@"upsampleApplied"] = @YES;
        castP[@"servedRate"] = @192000; castP[@"servedFilter"] = @"poly-sinc-short";
        NSMutableDictionary *castResp = [base mutableCopy]; castResp[@"path"] = castP;
        RLPSignalNode *castR = Find([RLPSignalChain nodesForResponse:castResp], @"采样率转换");
        CK([castR.badge isEqualToString:@"投放旁路"] && [castR.value containsString:@"poly-sinc-short"],
           "C6c 投放升频显示实际 servedFilter（不显示没用上的用户设置）", castR.value ?: @"nil");
        NSMutableDictionary *castGpuP = [castP mutableCopy];
        castGpuP[@"gpuUsed"] = @YES;
        NSMutableDictionary *castGpuResp = [base mutableCopy];
        castGpuResp[@"path"] = castGpuP;
        RLPSignalNode *castGpuR = Find([RLPSignalChain nodesForResponse:castGpuResp], @"采样率转换");
        CK([castGpuR.badge isEqualToString:@"GPU 升频"] &&
           castGpuR.kind == RLPSignalNodeGpu &&
           [castGpuR.value containsString:@"GPU"],
           "C6d 投放升频实际走 GPU ⟹ GPU 升频 + RLPSignalNodeGpu",
           castGpuR.badge ?: @"nil");

        // ---- C7 bit-perfect 其它态 ----
        NSMutableDictionary *noP = [base[@"path"] mutableCopy]; noP[@"bitPerfect"] = @"no";
        NSMutableDictionary *noResp = [base mutableCopy]; noResp[@"path"] = noP;
        CK([[RLPSignalChain heroTitleForResponse:noResp why:nil] containsString:@"DSP"],
           "C7a no + 非 AirPlay ⟹ 信号经过 DSP", @"");
        NSMutableDictionary *unkP = [base[@"path"] mutableCopy]; unkP[@"bitPerfect"] = @"";
        NSMutableDictionary *unkResp = [base mutableCopy]; unkResp[@"path"] = unkP;
        CK([[RLPSignalChain heroTitleForResponse:unkResp why:nil] containsString:@"未知"],
           "C7b 缺结论 ⟹ 状态未知", @"");

        std::printf("\n%s（%d 项失败）\n", gFail == 0 ? "signal_chain 全部通过" : "signal_chain 有失败", gFail);
        return gFail == 0 ? 0 : 1;
    }
}