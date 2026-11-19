// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_resampler.cpp — 多相 sinc 重采样引擎的客观验证
// 测量方法：Blackman-Harris 窗 + FFT，直接读谱（不用逐点相关法，避免 O(N*F) 爆炸）
#include "dsp/resampler.h"
#include "dsp/filter_design.h"
#include "dsp/filter_families.h"
#include "dsp/dsd_integrator.h"
#include "dsp/dsd_rate_convert.h"
#include "dsp/fft.h"
#include "audio/rate_pick.h"
#include "audio/phys_format.h"
#include "audio/render_loop.h"
#include "engine/preset_profiles.h"
#include <cstdio>
#include <vector>
#include <cmath>
#include <algorithm>
#include <string>
#include <atomic>

using namespace rta::dsp;

static int fails = 0;
static void check(bool ok, const char* what, const char* detail = "") {
    printf("  [%s] %s %s\n", ok ? "PASS" : "FAIL", what, detail);
    if (!ok) ++fails;
}

// 返回幅度谱(dB, 相对满幅)，长度 N/2
static std::vector<double> spectrum_db(const std::vector<double>& x, double fs) {
    const size_t N = x.size();
    std::vector<cplx> b(N);
    double wsum = 0.0;
    // Blackman-Harris 窗（-92 dB 旁瓣）
    for (size_t i = 0; i < N; ++i) {
        double t = 2.0 * kPi * (double)i / (double)N;
        double w = 0.35875 - 0.48829 * std::cos(t) + 0.14128 * std::cos(2 * t) - 0.01168 * std::cos(3 * t);
        b[i] = cplx(x[i] * w, 0.0);
        wsum += w;
    }
    fft(b);
    std::vector<double> m(N / 2);
    for (size_t k = 0; k < N / 2; ++k) {
        double mag = 2.0 * std::abs(b[k]) / wsum;
        m[k] = 20.0 * std::log10(mag > 1e-300 ? mag : 1e-300);
    }
    (void)fs;
    return m;
}

static double peak_in_range(const std::vector<double>& m, double fs, size_t N,
                            double f0, double f1, int excludeBin = -1, int excl = 0) {
    size_t k0 = (size_t)(f0 / fs * (double)N);
    size_t k1 = (size_t)(f1 / fs * (double)N);
    if (k1 >= m.size()) k1 = m.size() - 1;
    double best = -999.0;
    for (size_t k = k0; k <= k1; ++k) {
        if (excludeBin >= 0 && std::abs((int)k - excludeBin) <= excl) continue;
        best = std::max(best, m[k]);
    }
    return best;
}

int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IOLBF, 0);
    const bool auditOnly = (argc > 1 && std::string(argv[1]) == "--audit");
    if (!auditOnly) {
    printf("=== 1. 原型滤波器响应 ===\n");
    {
        ResamplerConfig cfg;
        cfg.inRate = 44100; cfg.outRate = 384000;
        cfg.totalTaps = 262144; cfg.attenDb = 180.0; cfg.transition = 0.04;
        PolyphaseResampler rs(cfg);
        printf("  44100->384000: L=%d M=%d  每相位抽头=%d  原型总抽头=%d  群延迟=%.1f 输入样本\n",
               rs.upFactor(), rs.downFactor(), rs.tapsPerPhase(),
               rs.tapsPerPhase() * rs.upFactor(), rs.latencyInputSamples());

        const double idealCutoff = std::min(1.0 / (double)rs.upFactor(), 1.0 / (double)rs.downFactor());
        LowpassSpec spec;
        spec.taps = rs.tapsPerPhase() * rs.upFactor();
        spec.cutoff = idealCutoff * (1.0 - cfg.transition);
        spec.attenDb = cfg.attenDb;
        auto proto = design_lowpass(spec);

        const double fsInterp = 44100.0 * rs.upFactor();
        auto dbAt = [&](double hz) { return magnitude_db(proto, hz / (fsInterp / 2.0)); };

        double pmin = 1e9, pmax = -1e9;
        for (double f = 100.0; f <= 20000.0; f += 500.0) { double d = dbAt(f); pmin = std::min(pmin, d); pmax = std::max(pmax, d); }
        printf("  通带 100Hz-20kHz: [%.4f, %.4f] dB  纹波 %.4f dB\n", pmin, pmax, pmax - pmin);
        check(pmax - pmin < 0.1, "通带纹波 < 0.1 dB");

        double worst = -1e9;
        for (double f = 25000.0; f <= fsInterp / 2.0; f += 500.0) worst = std::max(worst, dbAt(f));
        printf("  阻带 25kHz-%.0fHz 最大泄漏: %.2f dB\n", fsInterp / 2.0, worst);
        check(worst < -170.0, "阻带衰减 > 170 dB");
    }
    } // !auditOnly

    printf("\n=== 2. 44.1k -> 384k 重采样 1 kHz 正弦 ===\n");
    {
        ResamplerConfig cfg;
        cfg.inRate = 44100; cfg.outRate = 384000; cfg.channels = 2;
        cfg.totalTaps = 262144; cfg.attenDb = 180.0; cfg.transition = 0.04;
        PolyphaseResampler rs(cfg);

        const size_t inFrames = 44100;
        std::vector<double> ix(inFrames), iy(inFrames);
        for (size_t n = 0; n < inFrames; ++n) {
            double v = 0.5 * std::sin(2.0 * kPi * 1000.0 * (double)n / 44100.0);
            ix[n] = v; iy[n] = v;
        }
        const double* in[2] = { ix.data(), iy.data() };
        std::vector<double> ox(rs.maxOutFrames(inFrames)), oy(rs.maxOutFrames(inFrames));
        double* out[2] = { ox.data(), oy.data() };
        size_t produced = rs.process(in, inFrames, out);
        printf("  输入 %zu 帧 -> 输出 %zu 帧 (理论 %.0f)\n",
               inFrames, produced, (double)inFrames * 384000.0 / 44100.0);

        const double fs = 384000.0;
        const size_t N = 131072;
        const size_t skip = 40000;                 // 跳过启动瞬态与群延迟
        std::vector<double> seg(ox.begin() + skip, ox.begin() + skip + N);
        auto m = spectrum_db(seg, fs);

        const size_t kFund = (size_t)std::llround(1000.0 / fs * (double)N);
        double fundDb = -999.0;
        for (size_t k = kFund - 2; k <= kFund + 2; ++k) fundDb = std::max(fundDb, m[k]);
        printf("  基波峰值: %.3f dB (输入 -6.02 dB)\n", fundDb);

        double harmDb = -999.0;
        for (int h = 2; h <= 10; ++h) {
            size_t k = (size_t)std::llround((double)h * 1000.0 / fs * (double)N);
            for (size_t j = (k > 3 ? k - 3 : 0); j <= k + 3; ++j) harmDb = std::max(harmDb, m[j]);
        }
        // 带外：21 kHz 以上（含重采样镜像）到 180 kHz
        double imgDb = peak_in_range(m, fs, N, 21500.0, 180000.0, (int)kFund, 4);
        printf("  最大谐波(2-10次): %.2f dB  -> 相对基波 %.2f dBc\n", harmDb, harmDb - fundDb);
        printf("  带外峰值 21.5k-180kHz: %.2f dB  -> 相对基波 %.2f dBc\n", imgDb, imgDb - fundDb);
        check(harmDb - fundDb < -100.0, "谐波 < -100 dBc");
        check(imgDb - fundDb < -100.0, "带外镜像 < -100 dBc");
    }

    printf("\n=== 3. 直流增益与相位一致性（内插增益必须是 L） ===\n");
    {
        ResamplerConfig cfg;
        cfg.inRate = 44100; cfg.outRate = 384000; cfg.channels = 1;
        cfg.totalTaps = 262144; cfg.attenDb = 180.0; cfg.transition = 0.04;
        PolyphaseResampler rs(cfg);
        const size_t inFrames = 44100;
        std::vector<double> ix(inFrames, 0.5);          // 恒定直流 0.5
        const double* in[1] = { ix.data() };
        std::vector<double> ox(rs.maxOutFrames(inFrames));
        double* out[1] = { ox.data() };
        size_t p = rs.process(in, inFrames, out);
        double mn = 1e9, mx = -1e9;
        for (size_t n = 20000; n < p; ++n) { mn = std::min(mn, ox[n]); mx = std::max(mx, ox[n]); }
        printf("  直流 0.5 输入 -> 输出范围 [%.9f, %.9f]  纹波 %.3e\n", mn, mx, mx - mn);
        check(std::fabs(mx - 0.5) < 1e-6 && std::fabs(mn - 0.5) < 1e-6, "直流增益为 1（无 L 倍衰减）");
        check((mx - mn) < 1e-6, "相位间无直流纹波");
    }

    printf("\n=== 4. 比特完美透传 (44100 -> 44100) ===\n");
    {
        ResamplerConfig cfg;
        cfg.inRate = 44100; cfg.outRate = 44100; cfg.channels = 2;
        PolyphaseResampler rs(cfg);
        check(rs.passthrough(), "识别为透传模式");

        std::vector<double> ix(1000), iy(1000);
        for (size_t n = 0; n < 1000; ++n) { ix[n] = std::sin(0.01 * (double)n); iy[n] = ix[n]; }
        const double* in[2] = { ix.data(), iy.data() };
        std::vector<double> ox(2000), oy(2000);
        double* out[2] = { ox.data(), oy.data() };
        size_t p = rs.process(in, 1000, out);
        bool identical = (p == 1000);
        for (size_t n = 0; n < p && identical; ++n)
            if (ox[n] != ix[n] || oy[n] != iy[n]) identical = false;
        check(identical, "样本逐位相同");
    }

    // =========================================================================
    // 5. 升频 / 采样率 / 滤波器方案抽头数审计（离线纯算，无设备）
    // =========================================================================
    printf("\n=== 5. Resampler 方案 taps 审计（2x/4x/8x/16x, 44.1->48/96/192/384, PCM->DSD）===\n");
    {
        struct RateCase {
            const char* label;
            uint32_t inRate;
            uint32_t outRate;
            bool isDsd;
        };
        const RateCase kRates[] = {
            { "1x(44.1->44.1)",   44100,    44100, false },
            { "2x(44.1->88.2)",   44100,    88200, false },
            { "4x(44.1->176.4)",  44100,   176400, false },
            { "8x(44.1->352.8)",  44100,   352800, false },
            { "16x(44.1->705.6)", 44100,   705600, false },
            { "44.1->48",         44100,    48000, false },
            { "44.1->96",         44100,    96000, false },
            { "44.1->192",        44100,   192000, false },
            { "44.1->384",        44100,   384000, false },
            { "48->44.1",         48000,    44100, false },
            { "48->352.8",        48000,   352800, false },
            { "44.1->DSD64",      44100,  2822400, true  },
            { "44.1->DSD128",     44100,  5644800, true  },
            { "44.1->DSD256",     44100, 11289600, true  },
            { "44.1->DSD64_48k",  44100,  3072000, true  },
            { "44.1->DSD128_48k", 44100,  6144000, true  },
        };
        const char* kQualityPresets[] = {
            nullptr, // ResamplerConfig 默认 (totalTaps=262144, trans=0.04, Kaiser, Linear)
            "poly-sinc-short-lp",
            "poly-sinc-lp",
            "poly-sinc-mp",
            "poly-sinc-2s",
            "poly-sinc-long-lp",
            "poly-sinc-long-mp",
            "poly-sinc-xl",
            "poly-sinc-tight-lp",
            "poly-sinc-gauss-short",
            "poly-sinc-gauss-long",
            "poly-sinc-gauss-hires-lp",
            "poly-sinc-ext2",
            "poly-sinc-hb-s",
            "apod-20k",
            "apod-20k-tight",
            "sinc-M",
            "closed-form-16M",
        };

        printf("  %-24s | %-16s | %5s/%-3s | %3s | %6s | %6s | %10s | %9s | %5s | %s\n",
               "Preset/Scheme", "Rate", "L", "M", "Stg", "S1.T", "S2.T", "TotalCoeff", "UI_fpTaps", "T/In", "Status");
        printf("  %s\n", std::string(118, '-').c_str());

        bool allPlanPositiveAndFinite = true;
        int tightBudgetFailures = 0;

        for (const char* pName : kQualityPresets) {
            const FilterPreset* fp = pName ? find_preset(pName, true) : nullptr;
            const char* label = pName ? pName : "<default>";
            std::vector<uint64_t> multCoeffs; // 记录 2x/4x/8x/16x 总抽头数

            for (const auto& rc : kRates) {
                ResamplerConfig cfg;
                cfg.inRate = rc.inRate;
                cfg.outRate = rc.outRate;
                cfg.channels = 2;
                if (fp) apply_preset(cfg, *fp);

                try {
                    const ResamplerPlan plan = plan_resampler(cfg);
                    const int s1T = plan.stageCount >= 1 ? plan.stages[0].T : 0;
                    const int s2T = plan.stageCount >= 2 ? plan.stages[1].T : 0;
                    uint64_t totalCoeff = 0;
                    for (size_t si = 0; si < plan.stageCount; ++si)
                        totalCoeff += plan.stages[si].coefficientCount;

                    printf("  %-24s | %-16s | %5d/%-3d | %3zu | %6d | %6d | %10llu | %9d | %5d | OK\n",
                           label, rc.label, plan.L, plan.M, plan.stageCount, s1T, s2T,
                           (unsigned long long)totalCoeff,
                           fp ? fp->taps : cfg.totalTaps,
                           cfg.minTapsPerInput);

                    if (rc.inRate == rc.outRate) {
                        if (plan.stageCount != 0 || totalCoeff != 0) allPlanPositiveAndFinite = false;
                    } else {
                        if (plan.stageCount == 0 || s1T <= 0 || totalCoeff == 0 ||
                            (plan.stageCount == 2 && s2T <= 0)) {
                            allPlanPositiveAndFinite = false;
                        }
                        for (size_t si = 0; si < plan.stageCount; ++si) {
                            if (plan.stages[si].coefficientCount > uint64_t(cfg.maxPrototypeTaps))
                                allPlanPositiveAndFinite = false;
                        }
                    }
                    if (rc.outRate == rc.inRate * 2 || rc.outRate == rc.inRate * 4 ||
                        rc.outRate == rc.inRate * 8 || rc.outRate == rc.inRate * 16) {
                        multCoeffs.push_back(totalCoeff);
                    }
                } catch (const std::exception& ex) {
                    printf("  %-24s | %-16s | %5s/%-3s | ERR | %6s | %6s | %10s | %9d | %5d | EX: %s\n",
                           label, rc.label, "-", "-", "-", "-", "-",
                           fp ? fp->taps : cfg.totalTaps, cfg.minTapsPerInput, ex.what());
                    if (pName && std::string(pName) == "poly-sinc-tight-lp") ++tightBudgetFailures;
                }
            }
            if (multCoeffs.size() == 4) {
                bool notAllEqual = !(multCoeffs[0] == multCoeffs[1] &&
                                     multCoeffs[1] == multCoeffs[2] &&
                                     multCoeffs[2] == multCoeffs[3]);
                bool allPos = multCoeffs[0] > 0 && multCoeffs[1] > 0 &&
                              multCoeffs[2] > 0 && multCoeffs[3] > 0;
                if (!notAllEqual || !allPos) {
                    printf("  [WARN] %s 2x/4x/8x/16x totalCoeffs 未变化或含 0: %llu/%llu/%llu/%llu\n",
                           label, (unsigned long long)multCoeffs[0], (unsigned long long)multCoeffs[1],
                           (unsigned long long)multCoeffs[2], (unsigned long long)multCoeffs[3]);
                }
            }
        }
        check(allPlanPositiveAndFinite, "所有非直通 plan_resampler 组合 stage taps > 0 且有限且 <= maxPrototypeTaps");

        // 全量遍历 filter_presets()：确保 2x/4x/8x/16x 与 44.1->48/96/192 均 >0、有限、随倍率变化
        const auto& allPresets = filter_presets();
        bool allFamilyPlansValid = true;
        bool allFamilyVaryWithMult = true;
        for (const auto& fp : allPresets) {
            uint64_t c2 = 0, c4 = 0, c8 = 0, c16 = 0;
            const uint32_t outs[] = { 88200, 176400, 352800, 705600, 48000, 96000, 192000 };
            for (uint32_t outR : outs) {
                ResamplerConfig cfg;
                cfg.inRate = 44100; cfg.outRate = outR; cfg.channels = 2;
                apply_preset(cfg, fp);
                try {
                    const ResamplerPlan plan = plan_resampler(cfg);
                    uint64_t tot = 0;
                    for (size_t i = 0; i < plan.stageCount; ++i) tot += plan.stages[i].coefficientCount;
                    if (plan.stageCount == 0 || plan.stages[0].T <= 0 || tot == 0) allFamilyPlansValid = false;
                    if (outR == 88200) c2 = tot;
                    else if (outR == 176400) c4 = tot;
                    else if (outR == 352800) c8 = tot;
                    else if (outR == 705600) c16 = tot;
                } catch (...) {
                    allFamilyPlansValid = false;
                }
            }
            if (c2 == c4 && c4 == c8 && c8 == c16) {
                printf("  [WARN] preset %s 2x/4x/8x/16x totalCoeffs 完全相同 (%llu)\n",
                       fp.name, (unsigned long long)c2);
                allFamilyVaryWithMult = false;
            }
        }
        check(allFamilyPlansValid, "filter_presets() 全表在 2x..16x & 44.1->48/96/192 均规划出 >0 且有限的 taps");
        check(allFamilyVaryWithMult, "filter_presets() 全表在 2x/4x/8x/16x 间总抽头数非恒定不变");

        // 质量档位对比（44.1->192k 与 44.1->176.4k）：short < lp < long < xl
        auto planCoeffs = [](const char* nm, uint32_t inR, uint32_t outR) -> uint64_t {
            const FilterPreset* fp = find_preset(nm, inR >= 88200);
            ResamplerConfig cfg; cfg.inRate = inR; cfg.outRate = outR; cfg.channels = 2;
            if (fp) apply_preset(cfg, *fp);
            const auto pl = plan_resampler(cfg);
            uint64_t s = 0;
            for (size_t i = 0; i < pl.stageCount; ++i) s += pl.stages[i].coefficientCount;
            return s;
        };
        const uint64_t cShort4x = planCoeffs("poly-sinc-short-lp", 44100, 176400);
        const uint64_t cLp4x    = planCoeffs("poly-sinc-lp",       44100, 176400);
        const uint64_t cLong4x  = planCoeffs("poly-sinc-long-lp",  44100, 176400);
        const uint64_t cXl4x    = planCoeffs("poly-sinc-xl",       44100, 176400);
        printf("  4x 质量梯度 totalCoeffs: short=%llu < lp=%llu < long=%llu < xl=%llu\n",
               (unsigned long long)cShort4x, (unsigned long long)cLp4x,
               (unsigned long long)cLong4x,  (unsigned long long)cXl4x);
        check(cShort4x < cLp4x && cLp4x < cLong4x && cLong4x < cXl4x,
              "4x 质量梯度 totalCoeffs 满足 short < lp < long < xl");

        // 真实构造 PolyphaseResampler 实例（快路径代表集），核对 tapsPerPhase / latency / tail / 有限输出
        struct InstCase { const char* name; uint32_t inR; uint32_t outR; };
        const InstCase kInst[] = {
            { "poly-sinc-short-lp", 44100,  88200 },
            { "poly-sinc-short-lp", 44100, 176400 },
            { "poly-sinc-short-lp", 44100, 352800 },
            { "poly-sinc-short-lp", 44100, 705600 },
            { "poly-sinc-lp",       44100,  48000 },
            { "poly-sinc-lp",       44100,  96000 },
            { "poly-sinc-lp",       44100, 192000 },
            { "poly-sinc-2s",       44100, 352800 }, // two_stage() == true!
            { "poly-sinc-2s",       44100,  96000 }, // two_stage() == true (rational)!
            { "poly-sinc-tight-lp", 44100, 176400 },
            { "apod-20k",           44100,  88200 },
            { "apod-20k-tight",     44100, 176400 },
        };
        bool instFiniteOk = true;
        bool twoStageTapsPerPhasePositive = true;
        for (const auto& ic : kInst) {
            const FilterPreset* fp = find_preset(ic.name, false);
            ResamplerConfig cfg; cfg.inRate = ic.inR; cfg.outRate = ic.outR; cfg.channels = 1;
            apply_preset(cfg, *fp);
            PolyphaseResampler rs(cfg);
            double x[128];
            for (int i = 0; i < 128; ++i) x[i] = 0.25;
            std::vector<double> y(rs.maxOutFrames(128));
            const double* ip[1] = { x };
            double* op[1] = { y.data() };
            const size_t nOut = rs.process(ip, 128, op);
            bool valsFinite = (nOut > 0);
            for (size_t i = 0; i < nOut; ++i) if (!std::isfinite(y[i])) valsFinite = false;
            if (!valsFinite || rs.coefficient_count() == 0 ||
                !std::isfinite(rs.latencyInputSamples()) || !std::isfinite(rs.tailInputSamples())) {
                instFiniteOk = false;
            }
            if (rs.two_stage() && rs.tapsPerPhase() <= 0) {
                twoStageTapsPerPhasePositive = false;
                printf("  [AUDIT-DIFF] %s (%u->%u) two_stage=1: rs.tapsPerPhase()=%d (expect >0; s1=%d s2=%d coeff=%zu)\n",
                       ic.name, ic.inR, ic.outR, rs.tapsPerPhase(),
                       rs.stage1_taps_per_phase(), rs.stage2_taps_per_phase(), rs.coefficient_count());
            }
        }
        check(instFiniteOk, "真实 PolyphaseResampler 实例化: coefficient_count>0 且输出/延迟有限");
        // [差异 #1] src/dsp/resampler.h:258-264,328 + src/engine/pipeline.h:491,638:
        // two_stage()==true 时外层 T_ 未赋值保持 0，导致 pipeline.h st.tapsPerPhase=0 及 coeffBytes=0
        check(twoStageTapsPerPhasePositive,
              "[审计差异#1] two_stage() 模式下 PolyphaseResampler::tapsPerPhase() 应 >0 (实际返回 0)");

        // [差异 #2] src/dsp/resampler.h:187: tMax 钳位仅限 PhaseKind::Linear，导致 Minimum/Intermediate 同参抽头暴涨 15.5x
        {
            ResamplerConfig lpCfg, mpCfg;
            lpCfg.inRate = mpCfg.inRate = 44100;
            lpCfg.outRate = mpCfg.outRate = 88200;
            apply_preset(lpCfg, *find_preset("poly-sinc-lp", false));
            apply_preset(mpCfg, *find_preset("poly-sinc-mp", false));
            const auto lpPlan = plan_resampler(lpCfg);
            const auto mpPlan = plan_resampler(mpCfg);
            printf("  2x 线性 vs 最小相位对比: poly-sinc-lp T=%d (coeff=%llu) vs poly-sinc-mp T=%d (coeff=%llu)\n",
                   lpPlan.stages[0].T, (unsigned long long)lpPlan.stages[0].coefficientCount,
                   mpPlan.stages[0].T, (unsigned long long)mpPlan.stages[0].coefficientCount);
            check(lpPlan.stages[0].T == mpPlan.stages[0].T,
                  "[审计差异#2] 同参数 Linear vs Minimum 相位每相抽头应一致 (resampler.h:187 仅钳位 Linear)");
        }

        // [差异 #3] src/dsp/resampler.h:74-89 (apply_preset) vs tools/rtaweb.cpp:5209-5220 & src/net/cast_service.h:1694-1701
        {
            const FilterPreset* apod = find_preset("apod-20k", false);
            ResamplerConfig cApply, cManual;
            cApply.inRate = cManual.inRate = 44100;
            cApply.outRate = cManual.outRate = 88200;
            apply_preset(cApply, *apod);
            // 模拟 tools/rtaweb.cpp:5210-5220 的手工字段拷贝（绕过 preset_ceiling_db 与 apod_quality_taps）
            cManual.totalTaps = apod->taps;
            cManual.transition = apod->transition;
            cManual.attenDb = apod->attenDb;
            cManual.window = apod->window;
            cManual.phase = apod->phase;
            cManual.twoStage = apod->twoStage;
            cManual.apodizing = apod->apodizing;
            cManual.apodF1 = apod->apodF1;
            cManual.apodF2 = apod->apodF2;
            cManual.minTapsPerInput = apod->tapsPerInput;
            const auto pApply = plan_resampler(cApply);
            const auto pManual = plan_resampler(cManual);
            printf("  apod-20k 路径分歧: apply_preset T=%d (atten=%.0f) vs rtaweb手工拷贝 T=%d (atten=%.0f)\n",
                   pApply.stages[0].T, cApply.attenDb, pManual.stages[0].T, cManual.attenDb);
            check(pApply.stages[0].T == pManual.stages[0].T && cApply.attenDb == cManual.attenDb,
                  "[审计差异#3] apply_preset 与 rtaweb/cast_service 手工拷贝的 apod-20k 抽头/阻带衰减应一致");
        }

        // [差异 #4] poly-sinc-tight-lp (twoStage=false, tapsPerInput=1600) 跨族 PCM->DSD128_48k (44.1k->6.144M) 预算溢出抛异常
        check(tightBudgetFailures == 0,
              "[审计差异#4] poly-sinc-tight-lp 跨族升频至 48k 基 DSD128 (6.144M) 不应因单级预算溢出抛异常");

        // [差异 #4b] poly-sinc-mp-2s 在 2x->4x->8x->16x 随倍率升高抽头数反降 (32766->32764->16508->8444)
        {
            const FilterPreset* mp2s = find_preset("poly-sinc-mp-2s", false);
            auto coeffOf = [&](uint32_t outR) -> uint64_t {
                ResamplerConfig cfg; cfg.inRate = 44100; cfg.outRate = outR;
                apply_preset(cfg, *mp2s);
                const auto pl = plan_resampler(cfg);
                uint64_t s = 0;
                for (size_t i = 0; i < pl.stageCount; ++i) s += pl.stages[i].coefficientCount;
                return s;
            };
            const uint64_t m2 = coeffOf(88200), m4 = coeffOf(176400), m8 = coeffOf(352800), m16 = coeffOf(705600);
            printf("  poly-sinc-mp-2s 2x/4x/8x/16x totalCoeffs: %llu / %llu / %llu / %llu\n",
                   (unsigned long long)m2, (unsigned long long)m4,
                   (unsigned long long)m8, (unsigned long long)m16);
            check(m2 < m4 && m4 < m8 && m8 < m16,
                  "[审计差异#8] poly-sinc-mp-2s 原型总抽头应随升频倍率 2x<4x<8x<16x 合理变化而非随倍率腰斩");
        }
    }

    // =========================================================================
    // 6. rate_pick.h + phys_format.h + render_loop.h 采样率→物理格式→渲染链路审计
    // =========================================================================
    printf("\n=== 6. rate_pick + phys_format + render_loop 链路与抽头联动审计 ===\n");
    {
        using namespace rta::audio;
        const std::vector<uint32_t> devRates = { 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600 };
        const std::vector<PhysFormat> hwFormats = {
            {  44100, 24, false, true,  0x4c },
            {  48000, 24, false, true,  0x4c },
            {  88200, 24, false, true,  0x4c },
            {  96000, 24, false, true,  0x4c },
            { 176400, 24, false, true,  0x4c },
            { 192000, 24, false, true,  0x4c },
            { 352800, 24, false, true,  0x4c },
            { 384000, 24, false, true,  0x4c },
            { 705600, 24, false, true,  0x4c },
        };
        struct RateReqCase { const char* req; uint32_t sysRate; const char* note; };
        const RateReqCase reqs[] = {
            { "src",    48000, "跟随源(直通)" },
            { "follow", 48000, "跟随系统(48k)" },
            { "max",    48000, "设备最高(705.6k=16x)" },
            { "88200",  48000, "2x" },
            { "96000",  48000, "44.1->96" },
            { "176400", 48000, "4x" },
            { "192000", 48000, "44.1->192" },
            { "352800", 48000, "8x" },
            { "384000", 48000, "44.1->384" },
        };
        printf("  %-10s | %-20s | %7s | %5s | %6s | %10s | %10s\n",
               "reqRate", "Note", "pickHz", "phys", "3layer", "lp_Coeff", "tight_Coeff");
        printf("  %s\n", std::string(84, '-').c_str());

        const FilterPreset* lpFp    = find_preset("poly-sinc-lp", false);
        const FilterPreset* tightFp = find_preset("poly-sinc-tight-lp", false);
        bool rateChainOk = true;

        for (const auto& rr : reqs) {
            const RatePick pk = pick_output_rate(rr.req, 44100, devRates, rr.sysRate);
            const PhysPick pp = pick_physical_format(hwFormats, pk.rate, 24);
            ThreeLayer tl{};
            tl.known = true;
            tl.nominalRate = pk.rate; tl.virtualRate = pk.rate; tl.physicalRate = pp.pick.rate;
            tl.virtualInt = false; tl.physicalInt = !pp.pick.isFloat;
            tl.physicalBits = pp.pick.bits;
            tl.srcRate = pk.rate; tl.srcBits = 24;
            tl.requireVirtualInt = false; // AUHAL 语义
            const LayerVerdict lv = three_layer_verdict(tl);

            ResamplerConfig cLp, cTight;
            cLp.inRate = cTight.inRate = 44100;
            cLp.outRate = cTight.outRate = pk.rate;
            apply_preset(cLp, *lpFp);
            apply_preset(cTight, *tightFp);
            const auto plLp = plan_resampler(cLp);
            const auto plTight = plan_resampler(cTight);
            uint64_t kLp = 0, kTight = 0;
            for (size_t i = 0; i < plLp.stageCount; ++i) kLp += plLp.stages[i].coefficientCount;
            for (size_t i = 0; i < plTight.stageCount; ++i) kTight += plTight.stages[i].coefficientCount;

            printf("  %-10s | %-20s | %7u | %-5s | %-6s | %10llu | %10llu\n",
                   rr.req, rr.note, pk.rate,
                   pp.ok ? "OK" : "FAIL", lv.ok ? "OK" : "FAIL",
                   (unsigned long long)kLp, (unsigned long long)kTight);

            if (!pk.decided || !pp.ok || !lv.ok) rateChainOk = false;
            if (pk.rate == 44100 && (kLp != 0 || kTight != 0)) rateChainOk = false;
            if (pk.rate != 44100 && (kLp == 0 || kTight == 0)) rateChainOk = false;
        }
        check(rateChainOk, "rate_pick + phys_format + three_layer_verdict 与 resampler taps 联动正确");

        // 检查 rate=max 在 {44100,48000,176400,192000} 上会跨族选 192k 而非同族 176.4k
        const RatePick maxCross = pick_output_rate("max", 44100, { 44100, 48000, 176400, 192000 }, 48000);
        uint32_t capOut = 0;
        const CapDecision capSameFam = decide_capability_failure(
            true, 352800, { 44100, 48000, 176400, 192000 }, capOut, 44100, RateFamilyPolicy::Prefer);
        printf("  max({44.1,48,176.4,192})=%u Hz (L=640,M=147) vs cap_fallback(Prefer)=%u Hz (L=4,M=1)\n",
               maxCross.rate, capSameFam.outRate);
        check(maxCross.rate == 192000 && capSameFam.outRate == 176400,
              "rate_pick: max 取列表最大值(192k), Prefer 回退优先同族(176.4k)");

        // render_loop 离线验证（mock OutSink，无真实音频设备）：验证 PCM 升频及 DoP EOS 静音保护
        struct MockRenderSink : public rta::render::OutSink {
            uint32_t openRate = 0;
            int openBits = 0;
            size_t totalWritten = 0;
            std::string err;
            bool open(const rta::render::SinkOpenOpts&, uint32_t rate, int, int bits) override {
                openRate = rate; openBits = bits; return true;
            }
            bool start() override { return true; }
            size_t buffer_frames() const override { return 64; }
            size_t write_one_period(const int32_t*, size_t frames) override {
                totalWritten += frames; return frames;
            }
            const std::string& last_error() const override { return err; }
        };
        auto runRenderOnce = [](bool dop, bool withPadHook, bool& outDopPadMissing, size_t& outWritten) {
            MockRenderSink sink;
            rta::render::RenderQ rq;
            {
                std::lock_guard<std::mutex> lk(rq.mtx);
                AudioBuffer buf;
                buf.rate = dop ? 176400 : 192000;
                buf.bits = 24;
                buf.channels = 2;
                buf.raw.assign(40 * 2, 0x050000); // 40 帧（不足一个 64 帧周期，触发 EOS 补齐）
                rq.q.emplace_back(std::move(buf), 1ULL);
                rq.done = true;
            }
            std::atomic<bool> stop{false}, pauseReq{false}, paused{false};
            std::atomic<double> seekReq{-1.0}, volDb{0.0}, startDb{0.0}, dbgPeak{0.0};
            std::atomic<size_t> played{0};
            std::atomic<long long> dbgPad{0}, dbgW0{0}, dbgWr{0}, dbgPulls{0}, dbgClip{0};
            bool gpuOut = false;
            rta::render::RenderHost h;
            h.stop = &stop; h.pauseReq = &pauseReq; h.paused = &paused;
            h.seekReq = &seekReq; h.played = &played; h.volDb = &volDb; h.startDb = &startDb;
            h.dbgPad = &dbgPad; h.gpuOut = &gpuOut; h.rq = &rq;
            h.deviceRate = dop ? 176400 : 192000;
            h.outBits = 24; h.outCh = 2;
            h.inRate = 44100; h.inFrames = 40; h.totalOut = 64;
            h.dbgW0 = &dbgW0; h.dbgWr = &dbgWr; h.dbgPulls = &dbgPulls; h.dbgClip = &dbgClip; h.dbgPeak = &dbgPeak;
            h.dop = dop;
            h.starveEnabled = false;
            if (withPadHook) {
                h.dopPadFrames = [](std::vector<int32_t>& pend, size_t ch, size_t need) {
                    pend.resize(pend.size() + need * ch, 0x056969);
                };
            }
            sink.open({}, h.deviceRate, 2, 24);
            rta::render::render_loop(sink, h);
            outDopPadMissing = h.dopPadMissing;
            outWritten = sink.totalWritten;
            return h.normalEnd;
        };
        bool miss1 = false, miss2 = false;
        size_t wr1 = 0, wr2 = 0;
        const bool end1 = runRenderOnce(false, false, miss1, wr1);
        const bool end2 = runRenderOnce(true,  true,  miss2, wr2);
        check(end1 && !miss1 && wr1 == 64 && end2 && !miss2 && wr2 == 64,
              "render_loop 离线验证: PCM 192k 与 DoP 176.4k 载波均正常补齐周期并结束");
    }

    // =========================================================================
    // 7. DSD 相关抽头审计（DsdDecimator / DsdRateConverter / ResamplePurpose::Dsd）
    // =========================================================================
    printf("\n=== 7. DSD 相关抽头审计 (DsdDecimator / DsdRateConverter / ResamplePurpose::Dsd) ===\n");
    {
        struct DecCase { const char* label; uint32_t dsdRate; uint32_t outRate; IntegratorKind kind; DsdConversion conv; bool twoStage; };
        const DecCase kDecs[] = {
            { "DSD64->176.4k FIR 2s Narrow",  2822400, 176400, IntegratorKind::Fir, DsdConversion::Narrow, true  },
            { "DSD64->176.4k FIR 1s Narrow",  2822400, 176400, IntegratorKind::Fir, DsdConversion::Narrow, false },
            { "DSD64->176.4k FIR 2s Wide",    2822400, 176400, IntegratorKind::Fir, DsdConversion::Wide,   true  },
            { "DSD128->176.4k FIR 2s Narrow", 5644800, 176400, IntegratorKind::Fir, DsdConversion::Narrow, true  },
            { "DSD256->352.8k FIR 2s Narrow",11289600, 352800, IntegratorKind::Fir, DsdConversion::Narrow, true  },
            { "DSD64->176.4k IIR Narrow",     2822400, 176400, IntegratorKind::Iir, DsdConversion::Narrow, false },
            { "DSD64->176.4k CIC Narrow",     2822400, 176400, IntegratorKind::Cic, DsdConversion::Narrow, false },
        };
        printf("  %-30s | %4s | %4s | %8s | %8s\n", "DsdDecimator Case", "DecM", "2Stg", "FirTaps", "CompTaps");
        printf("  %s\n", std::string(66, '-').c_str());
        bool dsdDecOk = true;
        for (const auto& dc : kDecs) {
            const IntegratorConfig ic = conversion_integrator(dc.kind, dc.conv, dc.dsdRate, dc.outRate, 120.0, dc.twoStage);
            DsdDecimator dec(ic);
            printf("  %-30s | %4u | %4d | %8zu | %8zu\n",
                   dc.label, dec.decimation(), dec.isTwoStage() ? 1 : 0,
                   dec.firTaps().size(), dec.compTaps().size());
            if (dc.kind == IntegratorKind::Fir && dec.firTaps().empty()) dsdDecOk = false;
            if (dc.kind == IntegratorKind::Cic && dec.compTaps().empty()) dsdDecOk = false;
        }
        check(dsdDecOk, "DsdDecimator FIR/CIC 抽头数 > 0 且有限");

        struct ConvCase { const char* label; uint32_t src; uint32_t dst; };
        const ConvCase kConvs[] = {
            { "DSD64->DSD64(Direct)",    2822400,  2822400 },
            { "DSD64->DSD128(2x)",       2822400,  5644800 },
            { "DSD64->DSD256(4x)",       2822400, 11289600 },
            { "DSD64->DSD512(8x)",       2822400, 22579200 },
            { "DSD128->DSD256(2x)",      5644800, 11289600 },
            { "DSD128->DSD64(Down/2)",   5644800,  2822400 },
        };
        printf("\n  %-26s | %4s | %4s | %8s | %8s | %10s\n",
               "DsdRateConverter Case", "DecM", "IntL", "T/Phase", "DecTaps", "InterpTot");
        printf("  %s\n", std::string(72, '-').c_str());
        bool dsdConvOk = true;
        int prevUpInterp = 0;
        for (const auto& cc : kConvs) {
            const DsdRatePlan plan = plan_dsd_rate(cc.src, cc.dst);
            DsdRateConvertConfig cfg;
            cfg.modFamily = ModulatorFamily::Dsd; // 快速离线构造，不改变抽头规划
            cfg.modOrder = 5;
            DsdRateConverter conv(plan, cfg, 1);
            size_t decTaps = 0;
            if (plan.needs_dsp()) {
                const IntegratorConfig ic = conversion_integrator(cfg.decimator, cfg.conversion,
                                                                  plan.srcRate, plan.midRate,
                                                                  cfg.decimatorAttenDb, cfg.twoStageDecimator);
                DsdDecimator probe(ic);
                decTaps = probe.firTaps().size();
            }
            const size_t interpTot = size_t(conv.tapsPerPhase()) * size_t(plan.interpolation);
            printf("  %-26s | %4d | %4d | %8d | %8zu | %10zu\n",
                   cc.label, plan.decimation, plan.interpolation, conv.tapsPerPhase(), decTaps, interpTot);
            if (plan.mode == DsdRateMode::Upsample) {
                if (conv.tapsPerPhase() <= 0 || interpTot == 0) dsdConvOk = false;
                if (cc.src == 2822400) {
                    if (int(interpTot) <= prevUpInterp) dsdConvOk = false;
                    prevUpInterp = int(interpTot);
                }
            }
        }
        check(dsdConvOk, "DsdRateConverter 升速路径 tapsPerPhase > 0 且插值总抽头随 DSD64->128->256->512 递增");

        // ResamplePurpose::Dsd 强制 twoStage=true：核对 44.1k/48k -> DSD64/128/256/512
        bool purposeDsdOk = true;
        const uint32_t dsdTargets44[] = { 2822400, 5644800, 11289600, 22579200 };
        for (uint32_t dsdR : dsdTargets44) {
            ResamplerConfig rc;
            rc.inRate = 44100; rc.outRate = dsdR;
            apply_resample_purpose(rc, ResamplePurpose::Dsd);
            const auto pl = plan_resampler(rc);
            if (pl.stageCount != 2 || pl.stages[0].T <= 0 || pl.stages[1].T <= 0) purposeDsdOk = false;
        }
        check(purposeDsdOk, "ResamplePurpose::Dsd 在 44.1k->DSD64/128/256/512 上均启用 2-stage 且两级 T>0");
    }

    // =========================================================================
    // 8. UI 显示/配置与后端实际抽头数一致性审计（1x/Nx、PresetProfile、twoStage）
    // =========================================================================
    printf("\n=== 8. UI 显示/配置一致性审计 ===\n");
    {
        using namespace rta::engine;

        // 8A. PresetProfile ("minTapsPerInput=512") vs filter_families.h ("poly-sinc-tight-lp": 1600)
        DeviceCaps caps;
        caps.backend = "coreaudio";
        caps.exclusive = true;
        caps.dop = true;
        caps.dopMax = "dsd128";
        caps.rates = { 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000 };
        caps.maxRate = 384000;
        SourceInfo src; src.srcRate = 44100; src.srcBits = 16;
        const PresetSettings pcmSet = plan_preset(PresetProfile::Pcm, caps, src);
        const PresetSettings p2dSet = plan_preset(PresetProfile::PcmToDsd, caps, src);
        const FilterPreset* tightFp = find_preset(pcmSet.filter, false);
        printf("  [8A] PresetProfile::Pcm filter=%s preset.minTapsPerInput=%d vs filter_families.tapsPerInput=%d (UI fp.taps=%d)\n",
               pcmSet.filter.c_str(), pcmSet.minTapsPerInput,
               tightFp ? tightFp->tapsPerInput : -1,
               tightFp ? tightFp->taps : -1);
        printf("  [8A] PresetProfile::PcmToDsd filter=%s preset.minTapsPerInput=%d\n",
               p2dSet.filter.c_str(), p2dSet.minTapsPerInput);
        // [差异 #5] preset_profiles.h:300,344,398 & rtaweb.cpp:4137 声明 poly-sinc-tight-lp 自带 minTapsPerInput=512，
        // 但 filter_families.h:496 实际为 1600，且 rtaweb.cpp:4103 清零 gp.minTapsPerInput 后播放时实际落到 1600。
        check(tightFp && pcmSet.minTapsPerInput == tightFp->tapsPerInput &&
              p2dSet.minTapsPerInput == tightFp->tapsPerInput,
              "[审计差异#5] PresetProfile minTapsPerInput 与 poly-sinc-tight-lp 预设 tapsPerInput 应一致 (512 vs 1600)");

        // 8B. rtaweb.cpp:5488 状态上报 twoStage 判定 (cfg.twoStage && outRate >= inRate * 8) vs plan_resampler()
        const FilterPreset* lp2s = find_preset("poly-sinc-2s", false);
        struct TwoStageCase { uint32_t inR; uint32_t outR; const char* desc; };
        const TwoStageCase k2sCases[] = {
            { 44100,  48000, "44.1->48" },
            { 44100,  88200, "2x" },
            { 44100,  96000, "44.1->96" },
            { 44100, 176400, "4x" },
            { 44100, 192000, "44.1->192" },
            { 44100, 352800, "8x" },
            { 44100, 384000, "44.1->384" },
            { 44100, 485100, "11x(质数L=11)" },
            { 48000, 352800, "48->352.8(7.35x)" },
        };
        printf("\n  [8B] %-18s | %8s | %8s | %s\n", "Rate", "UI_2Stage", "Actual_2Stg", "Match");
        printf("  %s\n", std::string(52, '-').c_str());
        bool twoStageUiMatch = true;
        for (const auto& tc : k2sCases) {
            ResamplerConfig cfg;
            cfg.inRate = tc.inR; cfg.outRate = tc.outR;
            apply_preset(cfg, *lp2s);
            const auto pl = plan_resampler(cfg);
            const bool actual2s = (pl.stageCount == 2);
            // tools/rtaweb.cpp:5488 公式:
            const bool ui2s = (cfg.twoStage && uint64_t(tc.outR) >= uint64_t(tc.inR) * 8ULL);
            const bool ok = (actual2s == ui2s);
            if (!ok) twoStageUiMatch = false;
            printf("  %-18s | %-8s | %-11s | %s\n",
                   tc.desc, ui2s ? "true" : "false", actual2s ? "true" : "false", ok ? "OK" : "DIFF");
        }
        // [差异 #6] tools/rtaweb.cpp:5488 用 outRate >= in.rate * 8 推算 twoStage，与 resampler.h:209 实际分支不一致
        check(twoStageUiMatch,
              "[审计差异#6] rtaweb.cpp:5488 twoStage UI 状态判定应与 plan_resampler 实际 stageCount==2 一致");

        // 8C. UI 显示 taps (fp.taps / cfg.taps) vs 实际原型抽头数 (totalCoeffs)
        // tools/native_ui/RLPWorkbenchViewController.mm:3022 & tools/rtaweb.cpp:5489 固定显示 fp.taps
        ResamplerConfig cTight192;
        cTight192.inRate = 44100; cTight192.outRate = 192000;
        apply_preset(cTight192, *tightFp);
        const auto plTight192 = plan_resampler(cTight192);
        const uint64_t actualTight192 = plTight192.stages[0].coefficientCount;
        printf("\n  [8C] poly-sinc-tight-lp @ 44.1->192: UI显示 fp.taps=%d vs 实际原型=%llu (每相 T=%d, L=%d)\n",
               tightFp->taps, (unsigned long long)actualTight192,
               plTight192.stages[0].T, plTight192.stages[0].L);
        // [差异 #7] UI (RLPWorkbenchViewController.mm:3022, RLPSignalChain.mm:128, rtaweb.cpp:5489) 始终展示固定 fp.taps，
        // 既不反映 minTapsPerInput (1600*640=1,024,000)，也不反映 tMin/tMax 钳位或两段式真实总抽头。
        check(uint64_t(tightFp->taps) == actualTight192,
              "[审计差异#7] UI 显示的 fp.taps (32767) 应与实际生效抽头数 (1,024,000) 一致");

        // 8D. 1x / Nx 槽位统计（验证 filter_presets() 中 1x 与 Nx 数量分布）
        int cnt1x = 0, cntNx = 0;
        for (const auto& p : filter_presets()) {
            if (p.forNx) ++cntNx;
            else ++cnt1x;
        }
        printf("  [8D] filter_presets 统计: total=%zu (1x/基础=%d, forNx=%d)\n",
               filter_presets().size(), cnt1x, cntNx);
        check(cnt1x > 0 && cntNx > 0, "filter_presets() 同时包含 1x 与 forNx 滤波器预设");
    }

    printf("\n%s (失败项 %d)\n", fails == 0 ? "全部通过" : "存在失败", fails);
    return fails == 0 ? 0 : 1;
}
