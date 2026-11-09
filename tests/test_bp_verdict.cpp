// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_bp_verdict.cpp — bit-perfect 结论（src/audio/bp_verdict.h）判据门禁
//
// 为什么必须有这个测试（2026-11-09 用户反馈）：
//   「共享模式声音必然走系统 DSP，完全做不到 bit-perfect，但程序会显示 bit-perfect」。
//   旧判定式（tools/rtaweb.cpp 里那两份复制）**没有**「经系统混音」这一项，
//   而平台层 CoreAudioOutput::bit_perfect() 一直据此报 false。两份判断各说各话。
//
// 本测试的形态是「先跑红，再改绿」写进同一次运行：
//   [1] 把**旧判据**逐字复刻成一个函数，断言它在共享场景下返回 yes（= 复现 BUG）；
//       同一段里断言新判据 bp_verdict() 在同样输入下返回 no。红绿并存，
//       证明这条判据真的能抓住那个错误，而不是"看起来更严"。
//
// 铁律 1：纯函数测试，不打开任何音频设备、不发声。
#include "audio/bp_verdict.h"

#include <cmath>
#include <cstdio>
#include <string>

using rta::audio::BpInputs;
using rta::audio::BpVerdict;
using rta::audio::RateDirection;
using rta::audio::bp_verdict;
using rta::audio::rate_direction;

static int g_total = 0, g_fail = 0;

static void ck(bool cond, const char* what, const std::string& extra = std::string()) {
    ++g_total;
    if (cond) {
        std::printf("  [PASS] %s\n", what);
        return;
    }
    ++g_fail;
    std::printf("  [FAIL] %s %s\n", what, extra.c_str());
}

// 旧判据的**逐字复刻**（2026-11-09 修改前的 tools/rtaweb.cpp:4132-4148）。
// 保留它只为了证明 bug 真实存在 —— 生产代码已经不再有这段。
static std::string legacy_verdict(const BpInputs& x) {
    if (x.directSdmOk) return "direct";
    if (x.viaAirPlay) return "no";
    if (x.inRate != x.outRate) return "no";
    if (std::fabs(x.volumeDb) > 1e-9) return "no";
    if (x.shaperOn) return "no";
    if (x.preAttenDb > 1e-9) return "no";          // 恒为 false：preAtten 永远是 <= 0
    if (x.eqOn || x.convOn || x.dopCarrier) return "no";
    if (x.srcBits > 0 && x.outBits > 0 && x.outBits < x.srcBits) return "no";
    if (std::fabs(x.replayGainDb) > 1e-9) return "no";
    return "yes";
}

// 干净的独占直通基线：44.1k/16 源 -> 44.1k/16 输出、0 dB、无任何处理
static BpInputs clean_bitperfect() {
    BpInputs x;
    x.inRate = 44100; x.outRate = 44100;
    x.volumeDb = 0.0;
    x.srcBits = 16; x.outBits = 16;
    return x;
}

int main() {
    std::printf("== bp_verdict 判据测试（纯函数，全程无声）==\n\n");

    // ---------------- [1] 先跑红：旧判据在共享模式下会谎报 yes ----------------
    std::printf("[1] 红：旧判据（复刻）在共享模式下谎报 bit-perfect\n");
    {
        BpInputs x = clean_bitperfect();
        x.sharedMixer = true;                 // 用户报的场景：共享输出，其它条件都"干净"
        ck(legacy_verdict(x) == "yes",
           "旧判据确实会返回 yes（= 用户截图里的假 BIT-PERFECT，BUG 复现）",
           legacy_verdict(x));

        // 绿：新判据必须一票否决
        const BpVerdict v = bp_verdict(x);
        ck(v.state == "no", "新判据：共享输出必须判 no", v.state);
        ck(v.why.find("共享") != std::string::npos, "新判据：理由必须点明「共享」", v.why);

        BpInputs y = clean_bitperfect();
        y.sharedMixer = true;
        y.inRate = y.outRate = 48000;
        y.srcBits = y.outBits = 24;
        ck(bp_verdict(y).state == "no", "共享 + 48000/24 + 0 dB 仍必须 no", bp_verdict(y).state);
    }

    // ---------------- [2] 降采样绝不能被叫成升频 ----------------
    std::printf("\n[2] 方向判定：48000 -> 44100 必须是 Downsample\n");
    {
        ck(rate_direction(48000, 44100) == RateDirection::Downsample, "48000->44100 = 降采样");
        ck(rate_direction(44100, 48000) == RateDirection::Upsample, "44100->48000 = 升采样");
        ck(rate_direction(44100, 44100) == RateDirection::Same, "同率 = Same");
        ck(rate_direction(0, 44100) == RateDirection::Unknown, "源率未知 = Unknown（不猜方向）");
        ck(rate_direction(44100, 0) == RateDirection::Unknown, "输出率未知 = Unknown");

        BpInputs x = clean_bitperfect();
        x.inRate = 48000; x.outRate = 44100;   // 用户截图里的那条链路
        const BpVerdict v = bp_verdict(x);
        ck(v.state == "no", "降采样必须 no", v.state);
        ck(v.why.find("48000") != std::string::npos && v.why.find("44100") != std::string::npos,
           "理由必须写出两端真实速率", v.why);
        ck(v.why.find("升频") == std::string::npos,
           "理由里不许出现「升频」（降采样被标成升频就是原 BUG）", v.why);
    }

    // ---------------- [3] 真直通仍然是 yes（不能为了修 bug 把功能判死） ----------------
    std::printf("\n[3] 绿：真正的独占直通仍是 yes（负向对照）\n");
    {
        const BpVerdict v = bp_verdict(clean_bitperfect());
        ck(v.state == "yes", "44.1k/16 独占 + 0 dB + 无处理 = yes", v.state);
        ck(v.violations.empty(), "yes 时不得有任何 violations");
    }

    // ---------------- [4] 逐条判据（每条单独触发，证明判据不是摆设） ----------------
    std::printf("\n[4] 逐条判据：每一项都能单独把结论打成 no\n");
    {
        auto expect_no = [](const char* what, void (*mut)(BpInputs&)) {
            BpInputs x = clean_bitperfect();
            mut(x);
            const BpVerdict v = bp_verdict(x);
            ck(v.state == "no" && !v.violations.empty(), what, v.state + " / " + v.why);
        };
        expect_no("经系统混音", [](BpInputs& x) { x.sharedMixer = true; });
        expect_no("AirPlay 传输", [](BpInputs& x) { x.viaAirPlay = true; x.sharedMixer = true; });
        expect_no("重采样 44.1k->96k", [](BpInputs& x) { x.outRate = 96000; });
        expect_no("音量 -6 dB", [](BpInputs& x) { x.volumeDb = -6.0; });
        expect_no("抖动/整形", [](BpInputs& x) { x.shaperOn = true; });
        // 这条是旧判据的死角：preAtten 恒 <= 0，旧式 preAttenDb > 1e-9 永远不成立
        expect_no("预衰减 -0.7 dB", [](BpInputs& x) { x.preAttenDb = -0.7; });
        expect_no("EQ", [](BpInputs& x) { x.eqOn = true; });
        expect_no("IR 卷积", [](BpInputs& x) { x.convOn = true; });
        expect_no("DoP 载波", [](BpInputs& x) { x.dopCarrier = true; });
        expect_no("位深降低 24->16", [](BpInputs& x) { x.srcBits = 24; x.outBits = 16; });
        expect_no("ReplayGain", [](BpInputs& x) { x.replayGainDb = -3.2; });
        expect_no("等响度补偿实际生效", [](BpInputs& x) { x.loudnessOn = true; });
        expect_no("声道上混 2->6", [](BpInputs& x) { x.channelMix = true; });
        expect_no("浮点解码容器", [](BpInputs& x) { x.floatSource = true; });
        expect_no("设备层容器转换", [](BpInputs& x) { x.formatFallback = true; });
        expect_no("输出级增益非 1.0", [](BpInputs& x) { x.gainNotUnity = true; });
    }

    // ---------------- [5] DirectSDM 优先于 yes ----------------
    std::printf("\n[5] DirectSDM：比 yes 更严格的一档\n");
    {
        BpInputs x = clean_bitperfect();
        x.directSdmOk = true;
        x.outRate = 352800;                 // DoP 载波，必然"重采样"口径
        x.dopCarrier = true;
        const BpVerdict v = bp_verdict(x);
        ck(v.state == "direct", "DirectSDM 必须最先返回 direct", v.state);
        ck(v.violations.empty(), "direct 不列违规项");
    }

    // ---------------- [6] 位深展宽：不算违规，但必须说明 ----------------
    std::printf("\n[6] 16 -> 24 bit 低位补零：数值不变，允许 yes 但要说明\n");
    {
        BpInputs x = clean_bitperfect();
        x.outBits = 24;
        const BpVerdict v = bp_verdict(x);
        ck(v.state == "yes", "低位补零不算违规", v.state);
        ck(v.why.find("补零") != std::string::npos, "说明里要点明补零", v.why);
    }

    std::printf("\n========== %d/%d passed ==========\n", g_total - g_fail, g_total);
    return g_fail == 0 ? 0 : 1;
}
