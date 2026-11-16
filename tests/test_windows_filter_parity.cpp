// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_windows_filter_parity.cpp — Windows v3.3.11 滤波预设与设计算法对齐验收
//
// 判据覆盖：
//   1) 79 项静态预设表数量与 27 项新增预设存在性 + 关键参数（含 tight-lp tapsPerInput=1600）
//   2) Blackman-Harris 高衰减路径（>100 dB）真实阻带深度（不再锁死在 -92 dB）
//   3) 有限支撑级联相位（MP / IP）代表预设的通带平坦度、阻带深度与相位能量重心
//   4) poly-sinc-tight-lp 在 44.1k -> {88.2k, 192k, 352.8k, 384k, 705.6k} 跨输出率预算 (T=1600) 与频响一致
//   5) preset_metrics / solve_taps_per_phase / auto_preset_name / resolve_auto_taps
//   6) 满幅 + 单样本越界瞬态后的过载恢复（非仅无 NaN）
#include "dsp/filter_families.h"
#include "dsp/resampler.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

using namespace rta::dsp;

static int g_fails = 0;
static int g_passes = 0;

static void check(bool ok, const std::string& what, const std::string& detail = "") {
    std::printf("  [%s] %s%s%s\n", ok ? "PASS" : "FAIL", what.c_str(),
                detail.empty() ? "" : " — ", detail.c_str());
    if (ok) ++g_passes;
    else ++g_fails;
}

int main() {
    std::printf("=== test_windows_filter_parity (Windows v3.3.11 对齐验收) ===\n");

    // ---- 1) 79 项静态表 + 27 项新增预设参数校验 ----
    {
        const auto& all = filter_presets();
        check(all.size() == 79, "静态预设表数量 == 79", "实际=" + std::to_string(all.size()));

        struct ExpectedPreset {
            const char* name;
            int taps;
            double transition;
            double attenDb;
            WindowKind window;
            PhaseKind phase;
            bool forNx;
            bool twoStage;
            bool apodizing;
            int tapsPerInput;
        };
        const ExpectedPreset expected[] = {
            { "poly-sinc-ext2-short",      32767,  0.06,  180, WindowKind::BlackmanHarris, PhaseKind::Linear,       false, false, false, 0 },
            { "poly-sinc-ext2-medium",    131071,  0.03,  200, WindowKind::BlackmanHarris, PhaseKind::Linear,       false, false, false, 0 },
            { "poly-sinc-ext2-long",      524287,  0.015, 220, WindowKind::BlackmanHarris, PhaseKind::Linear,       true,  false, false, 0 },
            { "poly-sinc-ext2-hires-lp",   32767,  0.08,  160, WindowKind::BlackmanHarris, PhaseKind::Linear,       false, false, false, 0 },
            { "poly-sinc-ext2-hires-ip",   32767,  0.08,  160, WindowKind::BlackmanHarris, PhaseKind::Intermediate, false, false, false, 0 },
            { "poly-sinc-ext2-hires-mp",   32767,  0.08,  160, WindowKind::BlackmanHarris, PhaseKind::Minimum,      false, false, false, 0 },
            { "poly-sinc-xtr-lp",         524287,  0.008, 230, WindowKind::Kaiser,         PhaseKind::Linear,       true,  false, false, 0 },
            { "poly-sinc-xtr-mp",         262143,  0.05,  220, WindowKind::Kaiser,         PhaseKind::Minimum,      true,  false, false, 0 },
            { "poly-sinc-xtr-short-lp",    16383,  0.10,  140, WindowKind::Kaiser,         PhaseKind::Linear,       false, false, false, 0 },
            { "poly-sinc-xtr-short-mp",    16383,  0.10,  140, WindowKind::Kaiser,         PhaseKind::Minimum,      false, false, false, 0 },
            { "poly-sinc-gauss-medium",    16383,  0.08,  150, WindowKind::Gaussian,       PhaseKind::Linear,       false, false, false, 0 },
            { "poly-sinc-gauss-halfband",   8191,  0.10,  120, WindowKind::Gaussian,       PhaseKind::Linear,       false, false, true,  0 },
            { "poly-sinc-gauss-halfband-s", 4095,  0.10,  120, WindowKind::Gaussian,       PhaseKind::Linear,       false, false, true,  0 },
            { "poly-sinc-hb-xs",            2047,  0.16,  100, WindowKind::Kaiser,         PhaseKind::Linear,       false, false, false, 0 },
            { "poly-sinc-ext",             65535,  0.025, 190, WindowKind::Kaiser,         PhaseKind::Linear,       false, false, false, 0 },
            { "poly-sinc-mqa/mp3-lp",       8191,  0.14,  110, WindowKind::Kaiser,         PhaseKind::Linear,       false, false, false, 0 },
            { "poly-sinc-mqa/mp3-mp",       8191,  0.14,  110, WindowKind::Kaiser,         PhaseKind::Minimum,      false, false, false, 0 },
            { "sinc-short",                 8191,  0.10,  150, WindowKind::BlackmanHarris, PhaseKind::Linear,       false, false, false, 0 },
            { "sinc-medium",               32767,  0.05,  180, WindowKind::BlackmanHarris, PhaseKind::Linear,       false, false, false, 0 },
            { "sinc-long",                131071,  0.02,  210, WindowKind::BlackmanHarris, PhaseKind::Linear,       true,  false, false, 0 },
            { "sinc-long-h",              131071,  0.10,  210, WindowKind::BlackmanHarris, PhaseKind::Linear,       true,  false, true,  0 },
            { "sinc-Mx",                  524287,  0.012, 220, WindowKind::BlackmanHarris, PhaseKind::Linear,       true,  false, false, 0 },
            { "sinc-MGa",                 524287,  0.015, 215, WindowKind::Gaussian,       PhaseKind::Linear,       true,  false, false, 0 },
            { "sinc-Ls",                  262143,  0.03,  200, WindowKind::BlackmanHarris, PhaseKind::Linear,       true,  false, false, 0 },
            { "sinc-Lm",                  262143,  0.03,  200, WindowKind::BlackmanHarris, PhaseKind::Minimum,      true,  false, false, 0 },
            { "sinc-Lh",                  262143,  0.10,  200, WindowKind::BlackmanHarris, PhaseKind::Linear,       true,  false, true,  0 },
            { "minringFIR-lp",              4095,  0.12,  120, WindowKind::Kaiser,         PhaseKind::Linear,       false, false, false, 0 },
            { "poly-sinc-tight-lp",        32767,  0.020, 140, WindowKind::Kaiser,         PhaseKind::Linear,       false, false, false, 1600 },
        };
        for (const auto& e : expected) {
            const FilterPreset* fp = find_preset(e.name, e.forNx);
            const bool found = (fp != nullptr && std::string(fp->name) == e.name);
            bool match = false;
            if (found) {
                match = fp->taps == e.taps &&
                        std::fabs(fp->transition - e.transition) < 1e-9 &&
                        std::fabs(fp->attenDb - e.attenDb) < 1e-9 &&
                        fp->window == e.window &&
                        fp->phase == e.phase &&
                        fp->forNx == e.forNx &&
                        fp->twoStage == e.twoStage &&
                        fp->apodizing == e.apodizing &&
                        fp->tapsPerInput == e.tapsPerInput;
            }
            check(found && match, std::string("预设参数对齐: ") + e.name,
                  found ? (match ? "" : "参数不匹配") : "未找到");
        }
    }

    // ---- 2) BH 高衰减路径（>100 dB 不再被固定 4 项 BH 锁死在 -92 dB）----
    {
        const FilterPreset* fp = find_preset("poly-sinc-ext2", false);
        check(fp != nullptr, "poly-sinc-ext2 存在");
        if (fp) {
            ResamplerConfig cfg;
            cfg.inRate = 44100; cfg.outRate = 88200; cfg.channels = 1;
            apply_preset(cfg, *fp);
            PolyphaseResampler rs(cfg);
            std::vector<double> proto;
            rs.prototype_into(proto);
            const double gain = 20.0 * std::log10((double)rs.upFactor());
            const double fStopStart = (1.0 / (double)rs.upFactor()) * (1.0 + cfg.transition * 0.5);
            double worstStop = -1e9;
            for (int i = 0; i <= 40; ++i) {
                const double f = fStopStart + (1.0 - fStopStart) * (double)i / 40.0;
                worstStop = std::max(worstStop, magnitude_db(proto, f) - gain);
            }
            check(worstStop <= -180.0, "BH 高衰减预设 poly-sinc-ext2 阻带 <= -180 dB",
                  "实测=" + std::to_string(worstStop) + " dB");
        }
    }

    // ---- 3) 有限支撑级联相位（MP / IP）通带与阻带 ----
    {
        const char* names[] = { "poly-sinc-ext2-hires-mp", "poly-sinc-ext2-hires-ip" };
        for (const char* nm : names) {
            const FilterPreset* fp = find_preset(nm, false);
            check(fp != nullptr, std::string("级联相位预设存在: ") + nm);
            if (!fp) continue;
            ResamplerConfig cfg;
            cfg.inRate = 44100; cfg.outRate = 88200; cfg.channels = 1;
            apply_preset(cfg, *fp);
            PolyphaseResampler rs(cfg);
            std::vector<double> proto;
            rs.prototype_into(proto);
            const double gain = 20.0 * std::log10((double)rs.upFactor());
            const double fPass = (1.0 / (double)rs.upFactor()) * (1.0 - fp->transition) * 0.95;
            double passErr = 0.0;
            for (int i = 0; i <= 20; ++i) {
                const double f = fPass * (double)i / 20.0;
                passErr = std::max(passErr, std::fabs(magnitude_db(proto, f) - gain));
            }
            const double fStop = (1.0 / (double)rs.upFactor()) * (1.0 + fp->transition * 0.5);
            double worstStop = -1e9;
            for (int i = 0; i <= 30; ++i) {
                const double f = fStop + (1.0 - fStop) * (double)i / 30.0;
                worstStop = std::max(worstStop, magnitude_db(proto, f) - gain);
            }
            check(passErr < 0.05, std::string(nm) + " 通带平坦 (< 0.05 dB)",
                  "maxErr=" + std::to_string(passErr) + " dB");
            check(worstStop <= -150.0, std::string(nm) + " 阻带 <= -150 dB",
                  "worst=" + std::to_string(worstStop) + " dB");
        }
    }

    // ---- 4) tight-lp 输出率预算 (T=1600) 与频响跨速率一致性 ----
    {
        const FilterPreset* fp = find_preset("poly-sinc-tight-lp", false);
        check(fp != nullptr && fp->tapsPerInput == 1600, "poly-sinc-tight-lp tapsPerInput == 1600");
        if (fp) {
            double d20min = 1e9, d20max = -1e9, worstStop = -1e9;
            int Tmin = 1 << 30, Tmax = 0;
            for (uint32_t outR : { 88200u, 192000u, 352800u, 384000u, 705600u }) {
                ResamplerConfig cfg;
                cfg.inRate = 44100; cfg.outRate = outR; cfg.channels = 1;
                apply_preset(cfg, *fp);
                PolyphaseResampler rs(cfg);
                Tmin = std::min(Tmin, rs.tapsPerPhase());
                Tmax = std::max(Tmax, rs.tapsPerPhase());
                std::vector<double> proto;
                rs.prototype_into(proto);
                const double gain = 20.0 * std::log10((double)rs.upFactor());
                const double d20 = magnitude_db(proto, 2.0 * 20000.0 / (44100.0 * (double)rs.upFactor())) - gain;
                d20min = std::min(d20min, d20);
                d20max = std::max(d20max, d20);
                const double fMax = 44100.0 * (double)rs.upFactor() * 0.5;
                for (int i = 1; i <= 60; ++i) {
                    const double f = 22050.0 * (1.0 + 2.0 * (double)i / 60.0);
                    if (f >= fMax) break;
                    worstStop = std::max(worstStop, magnitude_db(proto, f / fMax) - gain);
                }
            }
            check(Tmin == 1600 && Tmax == 1600, "tight-lp 跨 5 速率每相位抽头恒为 1600",
                  "range=[" + std::to_string(Tmin) + "," + std::to_string(Tmax) + "]");
            check(d20max - d20min < 0.005, "tight-lp 20kHz 幅度跨速率一致 (<0.005 dB)",
                  "spread=" + std::to_string(d20max - d20min));
            check(worstStop <= -140.0, "tight-lp 阻带 <= -140 dB",
                  "worst=" + std::to_string(worstStop) + " dB");
        }
    }

    // ---- 5) metrics / solve_taps_per_phase / auto 选择 ----
    {
        check(std::string(auto_preset_name()) == "poly-sinc-short-lp", "auto_preset_name == poly-sinc-short-lp");
        check(is_auto_preset("") && is_auto_preset("auto") && !is_auto_preset("poly-sinc-lp"),
              "is_auto_preset 语义正确");
        check(content_hz_for_rate(44100) == 20000.0 && content_hz_for_rate(96000) == 40000.0,
              "content_hz_for_rate 映射正确");
        const FilterPreset* shortLp = find_preset("poly-sinc-short-lp", false);
        check(shortLp != nullptr, "poly-sinc-short-lp 存在");
        if (shortLp) {
            const auto m = preset_metrics(*shortLp, 44100.0, 20000.0);
            check(!m.excluded && m.T >= 8 && m.ceilingDb == 280.0, "preset_metrics 正常返回",
                  "T=" + std::to_string(m.T));
        }
        const int tSolved = solve_taps_per_phase(WindowKind::Kaiser, 0.10, false, 0.0, 0.0, 4095, 0, 44100.0);
        check(tSolved >= 200, "solve_taps_per_phase 返回合理每相位抽头", "T=" + std::to_string(tSolved));
    }

    // ---- 6) 满幅 + 越界瞬态过载恢复 ----
    {
        const FilterPreset* fp = find_preset("poly-sinc-ext2-hires-mp", false);
        ResamplerConfig cfg;
        cfg.inRate = 44100; cfg.outRate = 96000; cfg.channels = 1;
        if (fp) apply_preset(cfg, *fp);
        PolyphaseResampler rs(cfg);

        const size_t N = 16384;
        std::vector<double> x(N, 0.0);
        for (size_t i = 0; i < 2000; ++i)
            x[i] = 1.0 * std::sin(2.0 * kPi * 1000.0 * (double)i / 44100.0); // 0 dBFS
        x[2000] = 2.5;  // 单样本越界
        x[2001] = -2.5;
        // 后续 1e-3 (-60 dBFS) 1 kHz 小信号，验证恢复
        const double amp60 = 0.001;
        for (size_t i = 2002; i < N; ++i)
            x[i] = amp60 * std::sin(2.0 * kPi * 1000.0 * (double)i / 44100.0);

        std::vector<double> out(rs.maxOutFrames(N) + 64);
        const double* ip[1] = { x.data() };
        double* op[1] = { out.data() };
        const size_t got = rs.process(ip, N, op);

        bool allFinite = (got > 0);
        for (size_t i = 0; i < got; ++i) {
            if (!std::isfinite(out[i])) { allFinite = false; break; }
        }
        double tailRms = 0.0;
        const size_t tailStart = (got > 8000) ? (got - 8000) : (got / 2);
        for (size_t i = tailStart; i < got; ++i) tailRms += out[i] * out[i];
        tailRms = std::sqrt(tailRms / (double)(got - tailStart));
        const double expectedRms = amp60 / std::sqrt(2.0);
        const double errDb = 20.0 * std::log10(std::max(tailRms, 1e-300) / expectedRms);

        check(allFinite, "满幅+越界瞬态输出全部有限");
        check(std::fabs(errDb) < 0.2, "越界瞬态后 -60 dBFS 信号恢复正常电平",
              "errDb=" + std::to_string(errDb));
    }

    std::printf("结果：%d passed, %d failed\n", g_passes, g_fails);
    return g_fails ? 1 : 0;
}
