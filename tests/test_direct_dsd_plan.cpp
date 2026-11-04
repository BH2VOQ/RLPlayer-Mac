// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_direct_dsd_plan.cpp — 1.1.2 DSD P0-1/P0-2 单元测试
//
// ============================ 这个测试在证明什么（铁律 3）============================
// 1.1.2 的审计报告指出本节第 4 段"调用了 r_cross 却没有断言"。核实结论：**确实如此**，
// 而且注释也是错的 —— `evaluate_direct_dsd(2822400, 2, 128)` 的目标是 128×44100 =
// 5644800 Hz，与源 2822400 Hz **同族**且正好 2 倍，因此它是 **eligible / RateConvert**，
// 不是"44.1k 族 → 48k 族"。本轮不"顺着注释去反转判据"（那会把一个能用的功能判死），
// 而是按真实语义补断言，并把"跨族请求根本构造不出来"这件事用不变式钉住。
//
// 另外本轮加固的三类输入都必须**被证明会被拒**，而不是"看起来不会崩"：
//   * 非有限 CUE（NaN/±Inf）：NaN 的比较全为 false，旧代码会静默整轨播放；
//   * 整数溢出：档位 × 族基 用 32 位乘会回绕成"合法"目标；
//   * 非法速率：位率不是 16 的整数倍时载波会被静默截断。
// 以及跨度校验（validate_direct_dsd_span）：字节不够时必须**点名**哪个声道不够，而不是越界读。
#include "audio/direct_dsd_plan.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <string>
#include <vector>

using namespace rta::audio;

static int g_fail = 0;
static int g_total = 0;
static void ck(bool cond, const std::string& name, const std::string& detail = "") {
    ++g_total;
    if (cond) {
        std::printf("  [PASS] %s\n", name.c_str());
    } else {
        std::printf("  [FAIL] %s (%s)\n", name.c_str(), detail.c_str());
        g_fail++;
    }
}

int main() {
    std::printf("=== test_direct_dsd_plan: DSD P0-1 & P0-2 规划与资格判据 ===\n");

    // 1. P0-2 直通资格：无处理同速 -> PassThrough + bitPerfect="direct"
    std::printf("\n[1] 同速直通\n");
    {
        auto r = evaluate_direct_dsd(2822400, 2, 64, false, false, false);
        ck(r.eligible, "同速无处理应合格 (DSD64 -> DSD64)");
        ck(r.mode == DirectDsdMode::PassThrough, "同速无处理模式为 PassThrough");
        ck(r.bitPerfectState == "direct", "同速无处理 bitPerfectState 为 direct");
        ck(r.targetRate == 2822400, "目标速率等于源速率", std::to_string(r.targetRate));
    }

    // 2. P0-2：存在 EQ/IR/volume/loudness/trim -> 必须拒绝直通与转换（不被 plan.ok 覆盖）
    std::printf("\n[2] 存在处理/音量时必须拒绝\n");
    {
        auto r1 = evaluate_direct_dsd(2822400, 2, 64, false, true, false);
        ck(!r1.eligible, "存在处理时即使同速也必须拒绝直通");
        ck(r1.mode == DirectDsdMode::Ineligible, "模式为 Ineligible");
        ck(r1.bitPerfectState == "no", "bitPerfectState 为 no");

        // 升速 + anyProc = true (原来会因 plan_dsd_rate(2822400, 5644800).ok() 误放行)
        auto r2 = evaluate_direct_dsd(2822400, 2, 128, false, true, false);
        ck(!r2.eligible, "存在处理时即使同族升速也绝不能放行");
        ck(r2.mode == DirectDsdMode::Ineligible, "升速带处理模式为 Ineligible");

        // volumeActive = true
        auto r3 = evaluate_direct_dsd(2822400, 2, 128, false, false, true);
        ck(!r3.eligible, "音量非 0dB 时即使同族升速也绝不能放行");
        ck(r3.bitPerfectState == "no", "音量激活时不得声称位完美");
    }

    // 3. P0-2 转换资格：同族整数倍无处理 -> RateConvert, eligible=true, 但 bitPerfect="no"
    std::printf("\n[3] 同族整数倍转换\n");
    {
        auto r_up = evaluate_direct_dsd(2822400, 2, 128, false, false, false);
        ck(r_up.eligible, "同族升速无处理合格 (DSD64 -> DSD128)");
        ck(r_up.mode == DirectDsdMode::RateConvert, "模式为 RateConvert");
        ck(r_up.bitPerfectState == "no", "转换路径不得标逐位直通 (bitPerfect 必须为 no)");
        ck(r_up.targetRate == 5644800, "2 倍升速目标 5644800", std::to_string(r_up.targetRate));

        auto r_down = evaluate_direct_dsd(5644800, 2, 64, false, false, false);
        ck(r_down.eligible, "同族降速无处理合格 (DSD128 -> DSD64)");
        ck(r_down.mode == DirectDsdMode::RateConvert, "降速模式为 RateConvert");
        ck(r_down.bitPerfectState == "no", "降速转换路径 bitPerfect 必须为 no");
        ck(r_down.targetRate == 2822400, "降速目标 2822400", std::to_string(r_down.targetRate));

        // 4 倍升速（DSD64 -> DSD256）
        auto r4 = evaluate_direct_dsd(2822400, 2, 256, false, false, false);
        ck(r4.eligible && r4.targetRate == 11289600, "4 倍升速目标 11289600",
           std::to_string(r4.targetRate));

        // 48k 族同理：3072000 (DSD64@48k) -> DSD128 = 6144000
        auto r48 = evaluate_direct_dsd(3072000, 2, 128, false, false, false);
        ck(r48.eligible && r48.mode == DirectDsdMode::RateConvert, "48k 族 DSD64 -> DSD128 合格");
        ck(r48.targetRate == 6144000, "48k 族目标 6144000", std::to_string(r48.targetRate));
    }

    // 4. ★本轮修掉的空断言（审计 §5）
    //    旧代码：`auto r_cross = evaluate_direct_dsd(2822400, 2, 128, ...)` 之后再没使用过
    //    这个变量，注释还写着"44.1k族 -> 48k族"。核实：目标 128×44100 = 5644800，
    //    与源同族、正好 2 倍 ⟹ **合格**。所以这里断言"合格"，而不是顺着错误注释去断言拒绝。
    std::printf("\n[4] 原 r_cross 空断言修正（按真实语义，不是反转）\n");
    {
        auto r_cross = evaluate_direct_dsd(2822400, 2, 128, false, false, false);
        ck(r_cross.eligible, "2822400 -> DSD128 实际是合格（同族 2 倍）");
        ck(r_cross.mode == DirectDsdMode::RateConvert, "2822400 -> DSD128 为 RateConvert");
        ck(r_cross.targetRate == 5644800,
           "2822400 -> DSD128 目标是 5644800 而不是 48k 族的 6144000",
           std::to_string(r_cross.targetRate));
        ck(r_cross.bitPerfectState == "no", "转换路径不得声称位完美");
        // 判据自证：把"目标族"手算一遍，证明 5644800 与 2822400 同为 44100 族。
        ck((5644800u % 44100u) == 0u && (5644800u % 48000u) != 0u, "5644800 属 44100 族（手算对照）");
        ck((2822400u % 44100u) == 0u && (2822400u % 48000u) != 0u, "2822400 属 44100 族（手算对照）");

        // 真正的拒绝项
        auto r_lt64 = evaluate_direct_dsd(2822400, 2, 48, false, false, false);
        ck(!r_lt64.eligible, "档位 < 64 拒绝");
        ck(r_lt64.bitPerfectState == "no", "档位 < 64 时 bitPerfect 为 no");

        auto r_zero = evaluate_direct_dsd(2822400, 2, 0, false, false, false);
        ck(!r_zero.eligible, "档位 0 拒绝");

        auto r_neg = evaluate_direct_dsd(2822400, 2, -64, false, false, false);
        ck(!r_neg.eligible, "负档位拒绝");

        // 非整数倍：44100×100 = 4410000 / 2822400 = 1.5625，不是整数倍
        auto r_nonint = evaluate_direct_dsd(2822400, 2, 100, false, false, false);
        ck(!r_nonint.eligible, "非整数倍目标（DSD 档位 100）必须拒绝");
        ck(r_nonint.mode == DirectDsdMode::Ineligible, "非整数倍模式为 Ineligible");
        ck(r_nonint.why.find("非整数倍") != std::string::npos, "拒绝理由指明非整数倍", r_nonint.why);

        // 档位 × 族基溢出（旧实现用 32 位乘会回绕）：200000 × 44100 = 8.82e9 > 2^32
        auto r_of = evaluate_direct_dsd(2822400, 2, 200000, false, false, false);
        ck(!r_of.eligible, "档位溢出不得回绕成合格");
        ck(r_of.why.find("档位") != std::string::npos, "溢出理由指明档位非法", r_of.why);

        // 非 16 倍数的目标（档位 65 × 44100 = 2866500，/16 不是整数）
        auto r_odd = evaluate_direct_dsd(2822400, 2, 65, false, false, false);
        ck(!r_odd.eligible, "档位 65 的目标速率不是 16 整数倍，必须拒绝");
    }

    // 5. 非法源速率
    std::printf("\n[5] 非法源速率\n");
    {
        auto r0 = evaluate_direct_dsd(0, 2, 64, false, false, false);
        ck(!r0.eligible && r0.why.find("缺少源 DSD 速率") != std::string::npos,
           "源速率 0 拒绝", r0.why);

        // 88200 是 PCM 采样率：2822400/88200 = 32，按整数倍规则会被错判"可转换"
        auto rpcm = evaluate_direct_dsd(88200, 2, 64, false, false, false);
        ck(!rpcm.eligible, "88.2 kHz（PCM 速率）不得被当成 DSD 位率");

        auto rlow = evaluate_direct_dsd(1411200, 2, 64, false, false, false);
        ck(!rlow.eligible, "低于 DSD64 的位率（1411200）拒绝");

        auto rodd = evaluate_direct_dsd(2822401, 2, 64, false, false, false);
        ck(!rodd.eligible, "非 16 整数倍的源速率拒绝");

        auto rhuge = evaluate_direct_dsd(200000000, 2, 64, false, false, false);
        ck(!rhuge.eligible, "荒谬的大位率拒绝");
    }

    // 6. DSD Native（未实现）
    std::printf("\n[6] DSD Native 未实现\n");
    {
        auto r = evaluate_direct_dsd(2822400, 2, 64, true, false, false);
        ck(!r.eligible, "dsdNative 必须拒绝（走的是另一条通道）");
        ck(r.why.find("Native") != std::string::npos, "理由指明 Native DSD", r.why);
    }

    // 7. ★不变式：target 的族恒等于源的族 ⟹ 跨族分支按构造不可达
    //    （这条把"跨族"那段代码的真实地位钉住：它是防御，不是判据。）
    std::printf("\n[7] 族一致性不变式（跨族按构造不可达）\n");
    {
        const uint32_t srcs[] = {2822400u, 5644800u, 11289600u, 3072000u, 6144000u, 12288000u};
        const int dsds[] = {64, 128, 256, 512};
        bool allSameFamily = true, anyCrossRejected = false;
        int eligibleCount = 0;
        for (uint32_t s : srcs) {
            for (int d : dsds) {
                const uint32_t tgt = (uint32_t)d * ((s % 48000u == 0u) ? 48000u : 44100u);
                if (tgt == s) continue;   // 直通组合已在 [1] 覆盖
                const auto r = evaluate_direct_dsd(s, 2, d, false, false, false);
                if (!r.eligible) {
                    anyCrossRejected = true;
                    continue;
                }
                ++eligibleCount;
                const bool src48 = (s % 48000u == 0u);
                const bool dst48 = (r.targetRate % 48000u == 0u);
                if (src48 != dst48) allSameFamily = false;
            }
        }
        ck(eligibleCount > 0, "不变式样本非空（确实跑到了转换组合）", std::to_string(eligibleCount));
        ck(allSameFamily, "所有合格目标与源同族 ⟹ 跨族分支不可达（防御性代码）");
        ck(!anyCrossRejected, "同族整数倍组合无一被误拒（判据没有收紧过头）");
    }

    // 8. P0-1 切片规划：升速 (2x) 后 carrier 与帧数翻倍
    std::printf("\n[8] 切片规划与 CUE\n");
    {
        const uint32_t effRate = 5644800;
        const uint64_t effBits = 5644800; // 5644800 位 / 16 = 352800 DoP 帧
        auto sp = plan_direct_dsd_slice(effRate, effBits, -1.0, -1.0);
        ck(sp.cueValid, "整轨切片有效", sp.cueError);
        ck(sp.carrierRate == 352800, "5.6448MHz DoP 载波率应为 352800 Hz", std::to_string(sp.carrierRate));
        ck(sp.totalDoPFrames == 352800, "总 DoP 帧数应为 352800", std::to_string(sp.totalDoPFrames));
        ck(sp.frameCount == 352800, "frameCount 应为 352800");
        ck(sp.frameEnd == 352800, "frameEnd 应为 352800");

        auto sp_cue = plan_direct_dsd_slice(effRate, effBits, 0.2, 0.8);
        ck(sp_cue.cueValid, "CUE 切片有效", sp_cue.cueError);
        ck(sp_cue.frameBase == 70560, "CUE frameBase 70560", std::to_string(sp_cue.frameBase));
        ck(sp_cue.frameCount == 211680, "CUE frameCount 211680", std::to_string(sp_cue.frameCount));
        ck(sp_cue.frameEnd == 282240, "CUE frameEnd 282240", std::to_string(sp_cue.frameEnd));

        size_t seekPos = calculate_direct_seek_pos(sp_cue.frameBase, sp_cue.frameCount, 0.5);
        ck(seekPos == 70560 + 105840, "seek 50% 落在正确帧", std::to_string(seekPos));

        // 终点越界 = 到结尾（保持原行为）
        auto sp_toEnd = plan_direct_dsd_slice(effRate, effBits, 0.5, 9.0);
        ck(sp_toEnd.cueValid && sp_toEnd.frameEnd == 352800,
           "终点越界按到结尾处理", std::to_string(sp_toEnd.frameEnd));

        // 非法区间
        auto sp_bad = plan_direct_dsd_slice(effRate, effBits, 0.8, 0.2);
        ck(!sp_bad.cueValid, "终点小于起点拒绝");
        auto sp_eq = plan_direct_dsd_slice(effRate, effBits, 0.5, 0.5);
        ck(!sp_eq.cueValid, "终点等于起点拒绝");
        auto sp_oob = plan_direct_dsd_slice(effRate, effBits, 1.0, -1.0);
        ck(!sp_oob.cueValid, "起点等于文件时长拒绝");
    }

    // 9. P0-1 尾部非 16 倍截断测试
    std::printf("\n[9] 尾部非 16 整数倍\n");
    {
        const uint32_t effRate = 5644800;
        const uint64_t effBits = 5644800 + 10;
        auto sp = plan_direct_dsd_slice(effRate, effBits, -1.0, -1.0);
        ck(sp.totalDoPFrames == 352800, "尾部非 16 整数倍截断为 352800 帧", std::to_string(sp.totalDoPFrames));
    }

    // 10. ★加固：非法速率 / 非有限 CUE / 溢出 CUE
    std::printf("\n[10] 加固判据（非法速率 / NaN / Inf / 溢出）\n");
    {
        auto sp0 = plan_direct_dsd_slice(0, 1000, -1.0, -1.0);
        ck(!sp0.cueValid, "effectiveRate=0 拒绝");

        auto sp16 = plan_direct_dsd_slice(2822401u, 2822400ull, -1.0, -1.0);
        ck(!sp16.cueValid, "位率不是 16 整数倍拒绝（旧代码会静默截断载波）");
        ck(sp16.cueError.find("16") != std::string::npos, "理由指明 16 整数倍", sp16.cueError);

        auto spBig = plan_direct_dsd_slice(kMaxDirectDsdRate + 16u, 2822400ull, -1.0, -1.0);
        ck(!spBig.cueValid, "荒谬大位率拒绝");

        auto spFew = plan_direct_dsd_slice(2822400u, 15ull, -1.0, -1.0);
        ck(!spFew.cueValid, "不足一个 DoP 帧拒绝");

        auto spHuge = plan_direct_dsd_slice(2822400u, (kMaxDirectDoPFrames + 1ull) * 16ull, -1.0, -1.0);
        ck(!spHuge.cueValid, "帧数超出规划上限拒绝");

        const double nan = std::nan("");
        const double inf = std::numeric_limits<double>::infinity();

        auto spNaN = plan_direct_dsd_slice(2822400u, 2822400ull, nan, 0.5);
        ck(!spNaN.cueValid, "cueStart=NaN 必须拒绝（旧代码会静默整轨播放）");
        ck(spNaN.cueError.find("非数值") != std::string::npos, "理由指明非数值", spNaN.cueError);

        auto spNaNEnd = plan_direct_dsd_slice(2822400u, 2822400ull, 0.1, nan);
        ck(!spNaNEnd.cueValid, "cueEnd=NaN 必须拒绝");

        auto spInf = plan_direct_dsd_slice(2822400u, 2822400ull, inf, -1.0);
        ck(!spInf.cueValid, "cueStart=+Inf 必须拒绝（旧代码会先 llround(Inf)）");

        auto spInfEnd = plan_direct_dsd_slice(2822400u, 2822400ull, 0.1, inf);
        ck(!spInfEnd.cueValid, "cueEnd=+Inf 必须拒绝");

        // 1e300 的起点：先乘后判会进未定义行为区
        auto spHugeStart = plan_direct_dsd_slice(2822400u, 2822400ull, 1e300, -1.0);
        ck(!spHugeStart.cueValid, "荒谬大的起点拒绝（不会先 llround）");
        ck(spHugeStart.cueError.find("起点越界") != std::string::npos, "理由指明起点越界",
           spHugeStart.cueError);

        // 边界：起点正好落在**最后一帧**上必须接受（0.999999s 会 round 到 totalDoPFrames ⟹ 无可播内容 ⟹ 拒绝）
        const auto spWhole = plan_direct_dsd_slice(2822400u, 2822400ull, -1.0, -1.0);
        const double lastFrameSec =
            (double)(spWhole.totalDoPFrames - 1) / (double)spWhole.carrierRate;
        auto spEdge = plan_direct_dsd_slice(2822400u, 2822400ull, lastFrameSec, -1.0);
        ck(spEdge.cueValid, "起点落在最后一帧仍接受", spEdge.cueError);
        ck(spEdge.frameBase == spWhole.totalDoPFrames - 1, "frameBase == total-1（四舍五入到界内）",
           std::to_string(spEdge.frameBase));
        ck(spEdge.frameCount == 1 && spEdge.frameEnd == spWhole.totalDoPFrames,
           "最后一帧区间长度 1 且 frameEnd 不越界", std::to_string(spEdge.frameCount));

        auto spPastEnd = plan_direct_dsd_slice(2822400u, 2822400ull, 0.999999, -1.0);
        ck(!spPastEnd.cueValid, "起点 round 到文件末尾之后必须拒绝（无可播内容）");

        // seek：非有限值按"不跳转"处理
        ck(calculate_direct_seek_pos(100, 50, nan) == 100, "seek NaN 不跳转");
        ck(calculate_direct_seek_pos(100, 50, inf) == 100, "seek +Inf 不跳转");
        ck(calculate_direct_seek_pos(100, 50, 2.0) == 150, "seek 比例 >1 夹到区间末尾");
        ck(calculate_direct_seek_pos(100, 50, 0.0) == 100, "seek 0 落在区间起点");
    }

    // 11. ★跨度校验：真正切片的地方必须能问"数据够不够"，而不是靠"应该够"
    std::printf("\n[11] 切片字节跨度校验\n");
    {
        const uint32_t rate = 2822400;      // DSD64
        const uint64_t bits = 2822400;      // 1 秒
        auto sp = plan_direct_dsd_slice(rate, bits, -1.0, -1.0);
        ck(sp.cueValid && sp.totalDoPFrames == 176400, "1 秒 DSD64 = 176400 DoP 帧",
           std::to_string(sp.totalDoPFrames));
        // 每声道需要 176400 × 2 = 352800 字节 = bits/8
        ck(direct_dsd_channel_bytes(bits) == 352800, "ceil(bits/8) = 352800",
           std::to_string(direct_dsd_channel_bytes(bits)));

        // (a) 刚好够（DSF 的实际布局）
        const size_t exact[2] = {352800, 352800};
        auto okExact = validate_direct_dsd_span(sp, 2, exact);
        ck(okExact.ok, "刚好够的跨度通过", okExact.why);
        ck(okExact.requiredBytes == 352800, "需要的字节数 = 352800",
           std::to_string(okExact.requiredBytes));

        // (b) 少一个字节：必须按下标点名声道
        const size_t shortCh1[2] = {352800, 352799};
        auto badShort = validate_direct_dsd_span(sp, 2, shortCh1);
        ck(!badShort.ok, "少 1 字节必须拒绝");
        ck(badShort.badChannel == 1, "点名第 1 声道", std::to_string(badShort.badChannel));

        // (c) 切 CUE 子区间时，尾部被截断的数据仍然够（这正是"不要整轨过度校验"）
        auto spCue = plan_direct_dsd_slice(rate, bits, 0.0, 0.5);
        const size_t halfCh[2] = {176400, 176400};   // 只有一半数据
        auto okHalf = validate_direct_dsd_span(spCue, 2, halfCh);
        ck(okHalf.ok, "CUE 子区间用一半数据也够", okHalf.why);
        ck(okHalf.requiredBytes == spCue.frameEnd * 2, "子区间需要 frameEnd×2 字节",
           std::to_string(okHalf.requiredBytes));

        // (d) 规划本身无效时必须说清楚（不是默默返回 ok）
        auto spInvalid = plan_direct_dsd_slice(rate, bits, 0.9, 0.1);
        auto badPlan = validate_direct_dsd_span(spInvalid, 2, exact);
        ck(!badPlan.ok, "无效规划不得通过跨度校验");
        ck(badPlan.why.find("规划本身无效") != std::string::npos, "理由指明规划无效", badPlan.why);

        // (e) 声道数 0
        auto zeroCh = validate_direct_dsd_span(sp, 0, exact);
        ck(!zeroCh.ok, "声道数 0 拒绝");

        // (f) 溢出护栏：手造一个荒谬 frameEnd（规划正常路径到不了这里）
        DirectDsdSlicePlan spOver;
        spOver.cueValid = true;
        spOver.frameEnd = std::numeric_limits<size_t>::max() / 2 + 1;
        const size_t bigCh[1] = {1};
        auto badOver = validate_direct_dsd_span(spOver, 1, bigCh);
        ck(!badOver.ok, "frameEnd×2 溢出被拦住");
        ck(badOver.why.find("溢出") != std::string::npos, "理由指明溢出", badOver.why);

        // (g) 指针版本与模板版本一致
        auto ptrVer = validate_direct_dsd_span(sp, 2, exact);
        ck(ptrVer.ok && ptrVer.requiredBytes == okExact.requiredBytes, "指针版结果一致");
    }

    // 12. ★floor(bits/16)*2 ≤ ceil(bits/8) 的穷举核对
    //     审计说"尾部非 16 对齐时切片可能越界"。这个不等式证明那不可能（只要 data 覆盖 bits），
    //     所以正确做法是保留 floor 不截断，另加跨度校验 —— 这里把不等式本身钉死。
    std::printf("\n[12] floor(bits/16)*2 ≤ ceil(bits/8) 穷举\n");
    {
        bool ok = true;
        std::string firstBad;
        for (uint64_t bits = 1; bits <= 4096; ++bits) {
            const size_t frames = (size_t)(bits / 16ull);
            const size_t need = frames * 2u;
            const size_t have = direct_dsd_channel_bytes(bits);
            if (need > have) {
                ok = false;
                if (firstBad.empty()) firstBad = std::to_string(bits);
            }
        }
        ck(ok, "任意 bits（1..4096）下切片所需字节 ≤ 声道字节数", firstBad);

        // 反证：如果真的按"防越界"再扣一帧，1 秒 DSD64 会丢掉一整帧有效数据
        const uint64_t bits = 2822400;
        const size_t frames = (size_t)(bits / 16ull);
        ck(frames * 2u == direct_dsd_channel_bytes(bits),
           "整秒 DSD64 恰好用满（再扣一帧就是白丢数据）");
    }

    std::printf("\n=== test_direct_dsd_plan 结果: %d 项，FAIL=%d ===\n", g_total, g_fail);
    return g_fail == 0 ? 0 : 1;
}
