// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// tests/test_preset_profiles.cpp — 「官方推荐预设」决策纯函数的离线单测（2026-10-26 起四档）
//
// 判据（铁律 3）：这里只测**决策**，不测设备。探测（CoreAudio caps / DoP 载波推算）
// 在 rtaweb 里，验证靠 GET /api/preset/caps 的实测输出。
// 因此本文件不需要声卡、不开流、不出声，任何机器都能跑。
//
// 覆盖的硬要求（用户 2026-10-25 / 2026-10-26）：
//   1) 无 DSD 能力的设备选 dsd 档必须**降级并给 note**（不是静默假装支持）；
//   2) maxRate 只有 96k 时 pcm 档**不许写 384**；
//   3) 源 DSD 与目标同速率 ⟹ directSdm=1（不同速率必须 0）；
//   4) bitperfect 档在任何设备上都必须满足 bit-perfect 七条件（且负向对照能证明判据不是摆设）；
//   5) 【2026-10-26 第 4 档 pcm2dsd】mac 口径 = **只走 DoP**：
//      · notes 里**绝不许**出现「原生 / 1-bit 直送」这种本平台不存在的通路（A-5 事故教训）；
//      · 无 DoP 能力必须明确降级为 PCM 升频并说明原因；
//      · 既有三档的 plan 结果必须**逐字段不变**（Case 24 是回归底线）。
#include "engine/preset_profiles.h"
#include <cstdio>
#include <string>
#include <vector>

#ifdef _WIN32
extern "C" __declspec(dllimport) int __stdcall SetConsoleOutputCP(unsigned int);
#endif
#ifndef CP_UTF8
#define CP_UTF8 65001
#endif

using namespace rta::engine;

static int g_fails = 0;
static void ck(bool cond, const char* desc, const std::string& detail = "") {
    if (cond) {
        std::printf("  [PASS] %s\n", desc);
    } else {
        std::printf("  [FAIL] %s %s\n", desc, detail.c_str());
        ++g_fails;
    }
}

// ---------------- 构造器 ----------------
static DeviceCaps wasapi_caps(std::vector<uint32_t> rates, int bits = 24, int ch = 2) {
    DeviceCaps c;
    c.backend = "wasapi";
    c.rates = std::move(rates);
    c.maxRate = c.rates.empty() ? 0u : c.rates.back();
    c.exclusive = !c.rates.empty();
    c.bits = bits;
    c.channels = ch;
    c.deviceName = "USB DAC (mock)";
    c.dopMax = preset_dop_max_from_rates(c.rates);
    c.dop = !c.dopMax.empty();
    return c;
}
static DeviceCaps asio_caps(std::vector<uint32_t> rates, const std::string& nativeMax,
                            int bits = 24, int ch = 2) {
    DeviceCaps c = wasapi_caps(std::move(rates), bits, ch);
    c.backend = "asio";
    c.exclusive = true;
    c.dsdNative = !nativeMax.empty();
    c.dsdNativeMax = nativeMax;
    c.deviceName = "AudioByte ASIO (mock)";
    return c;
}
static SourceInfo pcm_src(uint32_t rate, int bits) {
    SourceInfo s;
    s.isDsd = false;
    s.srcRate = rate;
    s.srcBits = bits;
    return s;
}
static SourceInfo dsd_src(int level) {
    SourceInfo s;
    s.isDsd = true;
    s.srcRate = (uint32_t)(44100 * level);
    s.srcBits = 1;
    return s;
}
static bool has_note(const PresetSettings& s, const char* needle) {
    for (const auto& n : s.notes) if (n.find(needle) != std::string::npos) return true;
    return false;
}

// ---- 「虚构通路」判据（2026-10-26 A-5 事故的护栏）----
// 为什么不能用 has_note(s, "原生") 这种粗词表：
//   mac 的 note 里**必须**写「mac 无原生 DSD 通路」——这是给用户的诚实说明（否定句），
//   粗词表会把它判红 ⟹ 要么删掉诚实说明（更糟），要么把断言放宽成摆设（最糟）。
// 所以判据要区分「声称有原生通路」与「声明没有原生通路」：
//   · 出现「原生支持 / 1-bit 直送 / 直送 ASIO / 封装选「原生」」⟹ 声称，红；
//   · 出现「原生」但**带否定词**（无原生 / 没有原生 / 非原生 …）⟹ 声明没有，绿；
//   · 出现「原生」却没有任何否定词 ⟹ 按声称处理，红。
// 判据本身是否有效已单独用 7 条样例验证（上游原文判红、mac 实文判绿），
// 并在 Case 19 里以自检断言固化 —— 不是"看起来严"，是真的能抓住上游那种写法。
static bool note_claims_native_pathway(const std::string& n) {
    static const char* kClaim[] = { "原生支持", "1-bit 直送", "1bit 直送", "直送 ASIO",
                                    "封装选「原生」", "封装选\"原生\"" };
    for (const char* c : kClaim) if (n.find(c) != std::string::npos) return true;
    if (n.find("原生") != std::string::npos) {
        static const char* kNeg[] = { "无原生", "没有原生", "不是原生", "非原生", "不采信原生" };
        for (const char* g : kNeg) if (n.find(g) != std::string::npos) return false;
        return true;
    }
    return false;
}
static bool settings_claim_native_pathway(const PresetSettings& s) {
    for (const auto& n : s.notes) if (note_claims_native_pathway(n)) return true;
    return false;
}
// 失败时打印第一条"声称了原生通路"的 note 作为证据
static std::string first_native_claim(const PresetSettings& s) {
    for (const auto& n : s.notes) if (note_claims_native_pathway(n)) return n;
    return std::string();
}
static uint32_t rate_num(const std::string& r) {
    if (r.empty()) return 0;
    uint32_t v = 0;
    for (char c : r) {
        if (c < '0' || c > '9') return 0;
        v = v * 10 + (uint32_t)(c - '0');
    }
    return v;
}

int main() {
#ifdef _WIN32
    SetConsoleOutputCP(CP_UTF8);
#endif
    setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("=== test_preset_profiles: 四档官方推荐预设的决策纯函数 ===\n");

    const std::vector<uint32_t> kFull = {44100, 48000, 88200, 96000, 176400, 192000,
                                         352800, 384000, 705600};
    const std::vector<uint32_t> k96k = {44100, 48000, 96000};
    const std::vector<uint32_t> k192k = {44100, 48000, 88200, 96000, 176400, 192000};

    // ---- ① 原音直通：PCM 源必须满足七条件 ----
    {
        const DeviceCaps c = wasapi_caps(kFull);
        const SourceInfo src = pcm_src(44100, 16);
        const PresetSettings s = plan_preset(PresetProfile::BitPerfect, c, src);
        ck(s.rate == "follow", "Case 1: bitperfect/PCM ⟹ rate=follow（不重采样）");
        ck(s.dsd == 0, "Case 1: bitperfect/PCM ⟹ dsd=0（不调制）");
        ck(s.volumeDb == 0.0, "Case 1: bitperfect/PCM ⟹ 音量 0 dB");
        ck(s.shaper == "none", "Case 1: bitperfect/PCM ⟹ shaper=none（无抖动/整形）");
        ck(s.clearEqIr, "Case 1: bitperfect/PCM ⟹ 清空 EQ/IR/预衰减");
        ck(s.directSdm == 0, "Case 1: bitperfect/PCM ⟹ directSdm=0");
        const BitPerfectCheck bp = check_bit_perfect(s, c, src);
        ck(bp.ok && bp.violations.empty(), "Case 1: bitperfect/PCM ⟹ 七条件全过",
           bp.violations.empty() ? std::string() : bp.violations[0]);
    }

    // ---- ② 原音直通：设备只有 96k 也照样满足七条件（follow 不需要支持列表） ----
    {
        const DeviceCaps c = wasapi_caps(k96k);
        const SourceInfo src = pcm_src(44100, 24);
        const PresetSettings s = plan_preset(PresetProfile::BitPerfect, c, src);
        const BitPerfectCheck bp = check_bit_perfect(s, c, src);
        ck(s.rate == "follow" && bp.ok, "Case 2: bitperfect/96k 设备 ⟹ 仍是 follow 且七条件全过");
    }

    // ---- ③ 负向对照：位深降低必须被判出来（证明七条件不是摆设） ----
    {
        const DeviceCaps c = wasapi_caps(kFull, 16);
        const SourceInfo src = pcm_src(96000, 24);
        const PresetSettings s = plan_preset(PresetProfile::BitPerfect, c, src);
        const BitPerfectCheck bp = check_bit_perfect(s, c, src);
        ck(!bp.ok, "Case 3: 24-bit 源 + 16-bit 输出 ⟹ 七条件判不过（负向对照）");
        ck(!bp.violations.empty() && bp.violations[0].find("⑦") != std::string::npos,
           "Case 3: 违例条目点名条件⑦（位深降低）",
           bp.violations.empty() ? std::string() : bp.violations[0]);
    }

    // ---- ④ 原音直通：DSD 源 + 原生能力 ⟹ 同速率 DirectSDM ----
    {
        const DeviceCaps c = asio_caps(kFull, "dsd256");
        const SourceInfo src = dsd_src(64);
        const PresetSettings s = plan_preset(PresetProfile::BitPerfect, c, src);
        ck(s.dsd == 64, "Case 4: bitperfect/DSD64 ⟹ dsd=64（目标是源位率本身）");
        ck(s.directSdm == 1, "Case 4: bitperfect/DSD64 ⟹ directSdm=1（同速率逐位直通）");
        ck(has_note(s, "DirectSDM"), "Case 4: note 写明 DirectSDM 1-bit 直通");
        ck(has_note(s, "原生"), "Case 4: note 写明设备原生支持（可 1-bit 直送）");
        const BitPerfectCheck bp = check_bit_perfect(s, c, src);
        ck(bp.ok, "Case 4: bitperfect/DSD64 ⟹ 七条件全过（⑥按 1-bit 直通判）");
    }

    // ---- ⑤ 原音直通：无原生但 DoP 够 ⟹ 仍按 1-bit 直通 ----
    {
        const DeviceCaps c = wasapi_caps(k192k);      // 176400 载波 ⟹ dopMax=dsd64
        const SourceInfo src = dsd_src(64);
        const PresetSettings s = plan_preset(PresetProfile::BitPerfect, c, src);
        ck(s.dsd == 64 && s.directSdm == 1, "Case 5: bitperfect/DSD64 + DoP ⟹ dsd=64 且 directSdm=1");
        ck(has_note(s, "DoP"), "Case 5: note 写明按 DoP 1-bit 直通");
    }

    // ---- ⑥ 原音直通：源位率超出设备承载 ⟹ 降级 + note，且必须不再声称 bit-perfect ----
    {
        const DeviceCaps c = wasapi_caps(k192k);      // DoP 只到 dsd64
        const SourceInfo src = dsd_src(256);
        const PresetSettings s = plan_preset(PresetProfile::BitPerfect, c, src);
        ck(s.dsd == 64, "Case 6: bitperfect/DSD256 超能力 ⟹ 降级到 DSD64");
        ck(s.directSdm == 0, "Case 6: 降级后 directSdm=0（不假装直通）");
        ck(has_note(s, "降级"), "Case 6: note 明确写「已降级」");
        const BitPerfectCheck bp = check_bit_perfect(s, c, src);
        ck(!bp.ok, "Case 6: 降级后七条件当然不成立（不许静默宣称 bit-perfect）");
    }

    // ---- ⑦ 原音直通：能力未知（探测为空）⟹ 保守不承诺直通 ----
    {
        const DeviceCaps c = wasapi_caps({});
        const SourceInfo src = dsd_src(64);
        const PresetSettings s = plan_preset(PresetProfile::BitPerfect, c, src);
        ck(s.dsd == 64 && s.directSdm == 0, "Case 7: bitperfect/能力未知 ⟹ dsd=64 但 directSdm=0（保守）");
        ck(has_note(s, "能力未知"), "Case 7: note 写明能力未知");
    }

    // ---- ⑧ PCM 升频：96k 设备不许写 384000 ----
    {
        const DeviceCaps c = wasapi_caps(k96k);
        const PresetSettings s = plan_preset(PresetProfile::Pcm, c, pcm_src(44100, 16));
        ck(s.rate == "96000", "Case 8: pcm/96k 设备 ⟹ rate=96000（不写 384000）", s.rate);
        ck(s.rate != "384000", "Case 8: pcm/96k 设备 ⟹ rate 不是 384000");
        ck(s.filter == "poly-sinc-tight-lp", "Case 8: pcm ⟹ filter=poly-sinc-tight-lp");
        ck(s.minTapsPerInput == 512, "Case 8: pcm ⟹ minTapsPerInput=512（高倍率下 20 kHz 的保命线）");
        ck(s.shaper == "auto", "Case 8: pcm ⟹ shaper=auto");
        ck(s.dsd == 0, "Case 8: pcm ⟹ dsd=0");
        ck(s.modFamily.empty() && s.modOrder == 0, "Case 8: pcm ⟹ 不动 modfamily/modorder");
        ck(s.directSdm == 0 && s.volumeDb == 0.0, "Case 8: pcm ⟹ directsdm=0、volume=0");
    }

    // ---- ⑨ PCM 升频：设备有 705.6k 也要按 384k 封顶并说明 ----
    {
        const DeviceCaps c = wasapi_caps(kFull);
        const PresetSettings s = plan_preset(PresetProfile::Pcm, c, pcm_src(44100, 16));
        ck(s.rate == "384000", "Case 9: pcm/705.6k 设备 ⟹ rate 封顶 384000", s.rate);
        ck(has_note(s, "封顶"), "Case 9: note 写明封顶（不是偷偷降档）");
        ck(rate_num(s.rate) <= kPresetRateCap, "Case 9: rate 数值 ≤ 384000");
    }

    // ---- ⑩ PCM 升频：探测为空 ⟹ follow + note（不假装支持） ----
    {
        const DeviceCaps c = wasapi_caps({});
        const PresetSettings s = plan_preset(PresetProfile::Pcm, c, pcm_src(44100, 16));
        ck(s.rate == "follow", "Case 10: pcm/探测为空 ⟹ rate=follow", s.rate);
        ck(has_note(s, "探测为空"), "Case 10: note 写明探测为空、已降级");
    }

    // ---- ⑪ 任何一组设备列表都不许把 rate 写成超过 384000 ----
    {
        bool allOk = true;
        std::string bad;
        const std::vector<std::vector<uint32_t>> sets = {
            kFull, k96k, k192k, {44100}, {48000, 96000}, {44100, 768000}, {768000}, {}
        };
        for (const auto& rs : sets) {
            const DeviceCaps c = wasapi_caps(rs);
            const PresetSettings s = plan_preset(PresetProfile::Pcm, c, pcm_src(44100, 16));
            const uint32_t v = rate_num(s.rate);
            if (v > kPresetRateCap) { allOk = false; bad = s.rate; }
        }
        ck(allOk, "Case 11: 8 组设备列表 ⟹ pcm 档 rate 从不超过 384000", bad);
    }

    // ---- ⑫ DSD 升频：设备没有 DSD 通路 ⟹ 降级为 PCM 升频 + note ----
    {
        DeviceCaps noDsd = wasapi_caps(k192k);
        noDsd.dop = false;
        noDsd.dopMax.clear();
        const PresetSettings s = plan_preset(PresetProfile::Dsd, noDsd, pcm_src(44100, 16));
        ck(s.dsd == 0, "Case 12: dsd/无 DSD 能力 ⟹ dsd=0（降级成 PCM）");
        ck(s.rate == "192000", "Case 12: dsd/无 DSD 能力 ⟹ rate=设备 PCM 最高档 192000", s.rate);
        ck(s.shaper == "auto", "Case 12: 降级后 shaper=auto（PCM 路径）");
        ck(s.modFamily.empty() && s.modOrder == 0, "Case 12: 降级后不动调制器");
        ck(has_note(s, "降级为 PCM"), "Case 12: note 写明已降级为 PCM 升频");
        ck(s.filter == "poly-sinc-tight-lp" && s.minTapsPerInput == 512,
           "Case 12: 降级后仍保留 poly-sinc-tight-lp + 512 taps");
    }

    // ---- ⑬ DSD 升频：原生最高档命中 + 调制器 ec/7 ----
    {
        const DeviceCaps c = asio_caps(kFull, "dsd256");
        const PresetSettings s = plan_preset(PresetProfile::Dsd, c, pcm_src(44100, 16));
        ck(s.dsd == 256, "Case 13: dsd/原生 dsd256 ⟹ 目标 DSD256");
        ck(s.modFamily == "ec" && s.modOrder == 7, "Case 13: dsd ⟹ modfamily=ec / modorder=7");
        ck(s.filter == "poly-sinc-tight-lp" && s.minTapsPerInput == 512,
           "Case 13: dsd ⟹ poly-sinc-tight-lp + 512 taps");
        ck(s.rate == "follow", "Case 13: dsd ⟹ rate=follow");
        ck(s.shaper == "none", "Case 13: dsd ⟹ shaper=none（DoP 强制无抖动）");
        ck(s.directSdm == 0, "Case 13: 源是 PCM ⟹ directSdm=0");
        ck(has_note(s, "原生"), "Case 13: note 写明走原生");
    }

    // ---- ⑭ DSD 升频：没有原生 ⟹ 退 DoP 最高档 ----
    {
        const DeviceCaps c = wasapi_caps(kFull);      // 705600 载波 ⟹ dopMax=dsd256
        const PresetSettings s = plan_preset(PresetProfile::Dsd, c, pcm_src(44100, 16));
        ck(s.dsd == 256, "Case 14: dsd/DoP ⟹ 目标 DSD256（705600/16）");
        ck(has_note(s, "DoP"), "Case 14: note 写明退 DoP");
    }

    // ---- ⑮ DSD 升频：源 DSD 与目标同速率 ⟹ directSdm=1；不同速率 ⟹ 0 ----
    {
        const DeviceCaps c = asio_caps(kFull, "dsd256");
        const PresetSettings same = plan_preset(PresetProfile::Dsd, c, dsd_src(256));
        ck(same.dsd == 256 && same.directSdm == 1,
           "Case 15: 源 DSD256 = 目标 DSD256 ⟹ directSdm=1");
        ck(has_note(same, "DirectSDM"), "Case 15: note 写明 DirectSDM 1-bit 直通");
        const PresetSettings diff = plan_preset(PresetProfile::Dsd, c, dsd_src(64));
        ck(diff.dsd == 256 && diff.directSdm == 0,
           "Case 15: 源 DSD64 ≠ 目标 DSD256 ⟹ directSdm=0（要重调制）");
        ck(has_note(diff, "重调制"), "Case 15: note 写明需要重调制");
    }

    // ---- ⑯ DSD 升频：驱动声称 DSD1024 ⟹ 封顶 DSD512 + note ----
    {
        const DeviceCaps c = asio_caps(kFull, "dsd1024");
        const PresetSettings s = plan_preset(PresetProfile::Dsd, c, pcm_src(44100, 16));
        ck(s.dsd == 512, "Case 16: 驱动声称 dsd1024 ⟹ 目标封顶 DSD512", std::to_string(s.dsd));
        ck(has_note(s, "封顶"), "Case 16: note 写明按 DSD512 封顶");
    }

    // ---- ⑰ bitperfect：多设备 × 多源矩阵都必须满足七条件（PCM 源） ----
    {
        struct Case { const char* name; DeviceCaps c; };
        std::vector<Case> cases;
        cases.push_back({ "wasapi-full", wasapi_caps(kFull) });
        cases.push_back({ "wasapi-96k", wasapi_caps(k96k) });
        cases.push_back({ "wasapi-192k", wasapi_caps(k192k) });
        cases.push_back({ "wasapi-empty", wasapi_caps({}) });
        cases.push_back({ "asio-native-dsd512", asio_caps(kFull, "dsd512") });
        DeviceCaps shared = wasapi_caps(kFull);
        shared.exclusive = false;
        cases.push_back({ "shared-non-exclusive", shared });
        std::vector<SourceInfo> srcs;
        srcs.push_back(pcm_src(44100, 16));
        srcs.push_back(pcm_src(44100, 24));
        srcs.push_back(pcm_src(96000, 24));
        srcs.push_back(pcm_src(192000, 32));
        int matrixFail = 0;
        std::string firstBad;
        for (const auto& cs : cases) {
            for (const auto& src : srcs) {
                DeviceCaps dc = cs.c;
                if (src.srcBits == 32) dc.bits = 32;    // 32-bit 源需要 32-bit 输出才不降位深
                const PresetSettings s = plan_preset(PresetProfile::BitPerfect, dc, src);
                const BitPerfectCheck bp = check_bit_perfect(s, dc, src);
                if (!bp.ok) {
                    ++matrixFail;
                    if (firstBad.empty()) firstBad = std::string(cs.name) + ": " + bp.violations[0];
                }
            }
        }
        ck(matrixFail == 0, "Case 17: 6 设备 × 4 源 ⟹ bitperfect 档七条件全部成立", firstBad);
    }

    // ---- ⑱ 档位名 / 解析 / DoP 载波换算 ----
    {
        PresetProfile p = PresetProfile::Pcm;
        ck(preset_profile_parse("bitperfect", p) && p == PresetProfile::BitPerfect,
           "Case 18: profile=bitperfect 解析正确");
        ck(preset_profile_parse("PCM", p) && p == PresetProfile::Pcm, "Case 18: profile=PCM 大小写不敏感");
        ck(preset_profile_parse("dsd", p) && p == PresetProfile::Dsd, "Case 18: profile=dsd 解析正确");
        ck(!preset_profile_parse("dsd128", p), "Case 18: 未知 profile ⟹ 解析失败（由 API 回 400）");
        ck(std::string(preset_profile_name(PresetProfile::BitPerfect)) == "bitperfect" &&
           std::string(preset_profile_name(PresetProfile::Dsd)) == "dsd",
           "Case 18: 规范名 bitperfect/dsd");
        ck(dop_carrier_for_level(64) == 176400 && dop_carrier_for_level(256) == 705600 &&
           dop_carrier_for_level(512) == 1411200,
           "Case 18: DoP 载波 64/256/512 = 176400/705600/1411200");
        ck(dsd_level_from_name("dsd128") == 128 && dsd_level_from_name("512") == 512 &&
           dsd_level_from_name("dsd999") == 0, "Case 18: 档位名解析（含非法值）");
        ck(dsd_level_of_bitrate(2822400) == 64 && dsd_level_of_bitrate(11289600) == 256 &&
           dsd_level_of_bitrate(3072000) == 64, "Case 18: 位率→档位（44.1k 与 48k 族）");
        ck(preset_dop_max_from_rates(kFull) == "dsd256" && preset_dop_max_from_rates(k96k).empty(),
           "Case 18: DoP 最高档由 PCM 载波率推得（96k 设备没有 DoP）");
    }

    // ========================================================================
    // 2026-10-26 第 4 档 PCM→DSD（pcm2dsd）—— **mac 口径：只走 DoP**
    // ========================================================================
    // 为什么这些判据必须写成"找关键词断言不许出现"，而不是"断言某条 note 存在"：
    //   2026-10-26 A-5 事故的形态是「子代理照上游 diff 移植出本平台不存在的通路，
    //   再写测试喂虚构值让它通过」。所以这里对**虚构通路**做负向断言：
    //   notes 里任何一处出现「原生」或「1-bit 直送」都算失败，而不只是"某条 note 写对了"。

    // ---- ⑲ pcm2dsd：有 DoP 能力 ⟹ dsd>0 + EC-7 + tight + 512 ----
    {
        const DeviceCaps c = wasapi_caps(kFull);     // 705600 载波 ⟹ dopMax=dsd256
        const SourceInfo src = pcm_src(44100, 16);
        const PresetSettings s = plan_preset(PresetProfile::PcmToDsd, c, src);
        ck(s.dsd > 0, "Case 19: pcm2dsd/有 DoP ⟹ dsd>0（真的输出 DSD）", std::to_string(s.dsd));
        ck(s.dsd == 256, "Case 19: pcm2dsd/DoP 最高 dsd256 ⟹ 目标 DSD256", std::to_string(s.dsd));
        ck(s.modFamily == "ec", "Case 19: pcm2dsd ⟹ modFamily=ec", s.modFamily);
        ck(s.modOrder == 7, "Case 19: pcm2dsd ⟹ modOrder=7", std::to_string(s.modOrder));
        ck(s.filter == "poly-sinc-tight-lp", "Case 19: pcm2dsd ⟹ filter=poly-sinc-tight-lp", s.filter);
        ck(s.minTapsPerInput == 512, "Case 19: pcm2dsd ⟹ minTapsPerInput=512",
           std::to_string(s.minTapsPerInput));
        ck(s.shaper == "none", "Case 19: pcm2dsd ⟹ shaper=none（抖动交给 1-bit 量化）", s.shaper);
        ck(s.rate == "follow", "Case 19: pcm2dsd ⟹ rate=follow（载波由 dsd 档决定，不由 rate）", s.rate);
        ck(s.directSdm == 0, "Case 19: pcm2dsd ⟹ directSdm=0（PCM 源没有直通）");
        ck(s.volumeDb == 0.0 && s.clearEqIr, "Case 19: pcm2dsd ⟹ 音量 0 dB + 清空 EQ/IR");
        ck(has_note(s, "DoP"), "Case 19: note 写明走 DoP");
        ck(has_note(s, "载波"), "Case 19: note 写明 DoP 载波率");
        ck(has_note(s, "705600"), "Case 19: note 的载波数字是 DSD256 的 705600 Hz");
        // ★ 负向断言（A-5 事故的护栏）：mac 没有原生 DSD 通路，notes 不许**声称**虚构通路。
        // 用 note_claims_native_pathway 而不是粗词表：诚实说明「mac 无原生 DSD 通路」必须能过。
        ck(!settings_claim_native_pathway(s),
           "Case 19[负向]: notes 未声称任何原生 1-bit 直送通路", first_native_claim(s));
        ck(has_note(s, "无原生 DSD 通路"),
           "Case 19[正向]: note 明确写「mac 无原生 DSD 通路」（诚实说明，不许省）");
        // 判据自检：喂上游那种原文必须判红（证明这个断言不是摆设）
        ck(note_claims_native_pathway("PCM → DSD256：设备原生支持 DSD（封装选「原生」可 1-bit 直送）"),
           "Case 19[判据自检]: 上游原文被 note_claims_native_pathway 判红");
        ck(!note_claims_native_pathway("PCM → DSD256：走 DoP，载波 705600 Hz（mac 无原生 DSD 通路）"),
           "Case 19[判据自检]: mac 的 DoP note 不被误判");
        ck(!note_claims_native_pathway("设备无原生 DSD，退 DoP，最高 dsd256"),
           "Case 19[判据自检]: 既有 dsd 档的否定句不被误判");
    }

    // ---- ⑳ pcm2dsd：即便上层把 dsdNative 填成 true 也不采信（mac 硬前提） ----
    // 这条是**最关键的防回归判据**：rtaweb 的 preset_probe_caps 把 dsdNative 硬编码 false，
    // 但只要 plan_preset 里还有一条 caps.dsdNative 分支，将来有人"顺手"改探测就会复活虚构通路。
    {
        DeviceCaps c = wasapi_caps(k192k);           // DoP 只到 dsd64
        c.dsdNative = true;                          // 故意注入本平台不存在的能力
        c.dsdNativeMax = "dsd256";
        const PresetSettings s = plan_preset(PresetProfile::PcmToDsd, c, pcm_src(44100, 16));
        ck(s.dsd == 64, "Case 20: 注入 dsdNative=dsd256 但 DoP 只到 dsd64 ⟹ 仍按 DoP 取 64",
           std::to_string(s.dsd));
        ck(!settings_claim_native_pathway(s),
           "Case 20[负向]: 注入原生能力后 notes 仍未声称原生通路", first_native_claim(s));
        // 连"没有 DoP、只有原生"的设备也必须降级 —— 证明原生分支真的不存在
        DeviceCaps onlyNative = wasapi_caps(k96k);
        onlyNative.dop = false;
        onlyNative.dopMax.clear();
        onlyNative.dsdNative = true;
        onlyNative.dsdNativeMax = "dsd512";
        const PresetSettings s2 = plan_preset(PresetProfile::PcmToDsd, onlyNative, pcm_src(44100, 16));
        ck(s2.dsd == 0, "Case 20: 只有「原生」没有 DoP ⟹ dsd=0（mac 不认原生）",
           std::to_string(s2.dsd));
        ck(has_note(s2, "降级为 PCM"), "Case 20: 只有原生 ⟹ 明确写降级为 PCM 升频");
    }

    // ---- ㉑ pcm2dsd：无 DSD 通路 ⟹ dsd=0 + 明确降级为 PCM 升频 ----
    {
        const DeviceCaps c = wasapi_caps(k96k);      // 96k 没有 DoP 载波
        const PresetSettings s = plan_preset(PresetProfile::PcmToDsd, c, pcm_src(44100, 16));
        ck(s.dsd == 0, "Case 21: pcm2dsd/无 DSD 通路 ⟹ dsd=0", std::to_string(s.dsd));
        ck(has_note(s, "降级为 PCM 升频"), "Case 21: note 明确写「降级为 PCM 升频」");
        ck(has_note(s, "DoP"), "Case 21: 降级原因点名 DoP（不是含糊的「不支持」）");
        ck(s.rate == "96000", "Case 21: 降级后升到设备最高 96000 Hz", s.rate);
        ck(s.shaper == "auto", "Case 21: 降级后 shaper=auto（PCM 路径）", s.shaper);
        ck(s.modFamily.empty() && s.modOrder == 0, "Case 21: 降级后不动调制器");
        ck(s.filter == "poly-sinc-tight-lp" && s.minTapsPerInput == 512,
           "Case 21: 降级后仍保留 poly-sinc-tight-lp + 512 taps");
    }

    // ---- ㉒ pcm2dsd：探测全空 ⟹ dsd=0 + follow + note（不假装支持） ----
    {
        const DeviceCaps c = wasapi_caps({});
        const PresetSettings s = plan_preset(PresetProfile::PcmToDsd, c, pcm_src(44100, 16));
        ck(s.dsd == 0 && s.rate == "follow", "Case 22: pcm2dsd/探测为空 ⟹ dsd=0 且 rate=follow",
           s.rate);
        ck(has_note(s, "降级为 PCM 升频"), "Case 22: note 写明已降级");
        ck(has_note(s, "探测为空"), "Case 22: note 点明探测为空（不假装支持）");
    }

    // ---- ㉓ 解析与规范名：pcm2dsd / pcm-dsd / pcm-to-dsd ----
    {
        PresetProfile p = PresetProfile::Pcm;
        ck(preset_profile_parse("pcm2dsd", p) && p == PresetProfile::PcmToDsd,
           "Case 23: profile=pcm2dsd 解析为 PcmToDsd");
        ck(preset_profile_parse("pcm-dsd", p) && p == PresetProfile::PcmToDsd,
           "Case 23: profile=pcm-dsd 解析为 PcmToDsd");
        ck(preset_profile_parse("pcm-to-dsd", p) && p == PresetProfile::PcmToDsd,
           "Case 23: profile=pcm-to-dsd 解析为 PcmToDsd");
        ck(preset_profile_parse("PCM2DSD", p) && p == PresetProfile::PcmToDsd,
           "Case 23: profile=PCM2DSD 大小写不敏感");
        ck(std::string(preset_profile_name(PresetProfile::PcmToDsd)) == "pcm2dsd",
           "Case 23: 规范名回 pcm2dsd", preset_profile_name(PresetProfile::PcmToDsd));
        // 负向：加了第 4 档不许把既有三档的解析吃掉（前缀吞噬的同款风险）
        ck(preset_profile_parse("dsd", p) && p == PresetProfile::Dsd,
           "Case 23[负向]: profile=dsd 仍解析为 Dsd（没被 pcm2dsd 抢走）");
        ck(preset_profile_parse("pcm", p) && p == PresetProfile::Pcm,
           "Case 23[负向]: profile=pcm 仍解析为 Pcm");
        ck(!preset_profile_parse("pcm2dsd128", p) && !preset_profile_parse("pcm2", p),
           "Case 23[负向]: 近似但非法的名字仍失败（全等比较，不是前缀匹配）");
    }

    // ---- ㉔ 回归底线：既有三档的 plan 结果**逐字段不变** ----
    // 判据怎么证明"没变"而不是"看起来没变"：把三档在「6 设备 × 3 源」下的全部输出字段
    // 序列化成一条签名，与**加第 4 档之前**用 git show HEAD:src/engine/preset_profiles.h
    // 单独编译出来 dump 的 54 条基线逐字节比对（基线不是事后补的，是先跑出来的）。
    // 签名含：档位名|rate|dsd|modFamily|modOrder|filter|minTapsPerInput|shaper|directSdm|
    //         clearEqIr|volumeDb(×1e6)。notes 不进口径比对 —— 措辞演进会把判据变成噪声源，
    //         字段值才是契约（notes 另有 Case 19~22 单独断言）。
    {
        struct Dev { const char* name; DeviceCaps c; };
        std::vector<Dev> devs;
        devs.push_back({ "full", wasapi_caps(kFull) });
        devs.push_back({ "96k", wasapi_caps(k96k) });
        devs.push_back({ "192k", wasapi_caps(k192k) });
        devs.push_back({ "empty", wasapi_caps({}) });
        devs.push_back({ "asio256", asio_caps(kFull, "dsd256") });
        devs.push_back({ "asio1024", asio_caps(kFull, "dsd1024") });
        std::vector<SourceInfo> srcs;
        srcs.push_back(pcm_src(44100, 16));
        srcs.push_back(pcm_src(96000, 24));
        srcs.push_back(dsd_src(64));
        const PresetProfile three[3] = { PresetProfile::BitPerfect, PresetProfile::Pcm, PresetProfile::Dsd };
        // 2026-10-26 加第 4 档**之前**的实测基线（54 条 = 6 设备 × 3 源 × 3 档，顺序固定）
        static const char* kBaseline[54] = {
        "bitperfect|follow|0||0||0|none|0|1|0",
        "pcm|384000|0||0|poly-sinc-tight-lp|512|auto|0|1|0",
        "dsd|follow|256|ec|7|poly-sinc-tight-lp|512|none|0|1|0",
        "bitperfect|follow|0||0||0|none|0|1|0",
        "pcm|384000|0||0|poly-sinc-tight-lp|512|auto|0|1|0",
        "dsd|follow|256|ec|7|poly-sinc-tight-lp|512|none|0|1|0",
        "bitperfect|follow|64||0||0|none|1|1|0",
        "pcm|384000|0||0|poly-sinc-tight-lp|512|auto|0|1|0",
        "dsd|follow|256|ec|7|poly-sinc-tight-lp|512|none|0|1|0",
        "bitperfect|follow|0||0||0|none|0|1|0",
        "pcm|96000|0||0|poly-sinc-tight-lp|512|auto|0|1|0",
        "dsd|96000|0||0|poly-sinc-tight-lp|512|auto|0|1|0",
        "bitperfect|follow|0||0||0|none|0|1|0",
        "pcm|96000|0||0|poly-sinc-tight-lp|512|auto|0|1|0",
        "dsd|96000|0||0|poly-sinc-tight-lp|512|auto|0|1|0",
        "bitperfect|follow|0||0||0|none|0|1|0",
        "pcm|96000|0||0|poly-sinc-tight-lp|512|auto|0|1|0",
        "dsd|96000|0||0|poly-sinc-tight-lp|512|auto|0|1|0",
        "bitperfect|follow|0||0||0|none|0|1|0",
        "pcm|192000|0||0|poly-sinc-tight-lp|512|auto|0|1|0",
        "dsd|follow|64|ec|7|poly-sinc-tight-lp|512|none|0|1|0",
        "bitperfect|follow|0||0||0|none|0|1|0",
        "pcm|192000|0||0|poly-sinc-tight-lp|512|auto|0|1|0",
        "dsd|follow|64|ec|7|poly-sinc-tight-lp|512|none|0|1|0",
        "bitperfect|follow|64||0||0|none|1|1|0",
        "pcm|192000|0||0|poly-sinc-tight-lp|512|auto|0|1|0",
        "dsd|follow|64|ec|7|poly-sinc-tight-lp|512|none|1|1|0",
        "bitperfect|follow|0||0||0|none|0|1|0",
        "pcm|follow|0||0|poly-sinc-tight-lp|512|auto|0|1|0",
        "dsd|follow|0||0|poly-sinc-tight-lp|512|none|0|1|0",
        "bitperfect|follow|0||0||0|none|0|1|0",
        "pcm|follow|0||0|poly-sinc-tight-lp|512|auto|0|1|0",
        "dsd|follow|0||0|poly-sinc-tight-lp|512|none|0|1|0",
        "bitperfect|follow|64||0||0|none|0|1|0",
        "pcm|follow|0||0|poly-sinc-tight-lp|512|auto|0|1|0",
        "dsd|follow|0||0|poly-sinc-tight-lp|512|none|0|1|0",
        "bitperfect|follow|0||0||0|none|0|1|0",
        "pcm|384000|0||0|poly-sinc-tight-lp|512|auto|0|1|0",
        "dsd|follow|256|ec|7|poly-sinc-tight-lp|512|none|0|1|0",
        "bitperfect|follow|0||0||0|none|0|1|0",
        "pcm|384000|0||0|poly-sinc-tight-lp|512|auto|0|1|0",
        "dsd|follow|256|ec|7|poly-sinc-tight-lp|512|none|0|1|0",
        "bitperfect|follow|64||0||0|none|1|1|0",
        "pcm|384000|0||0|poly-sinc-tight-lp|512|auto|0|1|0",
        "dsd|follow|256|ec|7|poly-sinc-tight-lp|512|none|0|1|0",
        "bitperfect|follow|0||0||0|none|0|1|0",
        "pcm|384000|0||0|poly-sinc-tight-lp|512|auto|0|1|0",
        "dsd|follow|512|ec|7|poly-sinc-tight-lp|512|none|0|1|0",
        "bitperfect|follow|0||0||0|none|0|1|0",
        "pcm|384000|0||0|poly-sinc-tight-lp|512|auto|0|1|0",
        "dsd|follow|512|ec|7|poly-sinc-tight-lp|512|none|0|1|0",
        "bitperfect|follow|64||0||0|none|1|1|0",
        "pcm|384000|0||0|poly-sinc-tight-lp|512|auto|0|1|0",
        "dsd|follow|512|ec|7|poly-sinc-tight-lp|512|none|0|1|0",
        };
        int idx = 0, mismatch = 0;
        std::string firstBad;
        for (const auto& d : devs) {
            for (const auto& src : srcs) {
                for (PresetProfile p : three) {
                    const PresetSettings s = plan_preset(p, d.c, src);
                    const std::string sig = std::string(preset_profile_name(p)) + "|" + s.rate + "|" +
                                            std::to_string(s.dsd) + "|" + s.modFamily + "|" +
                                            std::to_string(s.modOrder) + "|" + s.filter + "|" +
                                            std::to_string(s.minTapsPerInput) + "|" + s.shaper + "|" +
                                            std::to_string(s.directSdm) + "|" +
                                            std::to_string((int)s.clearEqIr) + "|" +
                                            std::to_string((long long)(s.volumeDb * 1000000.0));
                    if (idx >= 54) { ++mismatch; continue; }
                    if (sig != kBaseline[idx]) {
                        ++mismatch;
                        if (firstBad.empty())
                            firstBad = std::string(d.name) + "/" + preset_profile_name(p) +
                                       " got=[" + sig + "] want=[" + kBaseline[idx] + "]";
                    }
                    ++idx;
                }
            }
        }
        ck(idx == 54, "Case 24: 三档 × 6 设备 × 3 源 = 54 组全部取到（自检）", std::to_string(idx));
        ck(mismatch == 0, "Case 24: 三档 54 组签名与加第 4 档**之前**的基线逐字节一致", firstBad);
    }

    if (g_fails == 0) std::printf("\n[ALL PASS] 四档预设决策单测全部通过\n");
    else               std::printf("\n[FAILED] %d 项未通过\n", g_fails);
    return g_fails == 0 ? 0 : 1;
}
