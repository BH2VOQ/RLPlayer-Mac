// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_filters.cpp — 滤波器家族客观验证（ROADMAP P2 门禁）
// 验证要点（铁律 3：判据要能证明对的东西，严格避开三个坑）：
//   1) 全家族变体的通带纹波 / 最差阻带衰减 / 抽头数可测性
//   2) 最小相位与线性相位的【幅频响应一致性】（倒谱分解正确性，避开坑 3 相对地板）
//   3) 前振铃判据：前/后能量比、峰值位置、能量重心（严格避开坑 2，不用对称天然约 0.25 的错误判据）
//   4) 抽头数与过渡带在家族内的单调性
//   5) 两段式（*-2s）与单段对应变体：可听带幅度一致性（差值 < 0.015 dB）、分块不变性、镜像抑制
//   6) 截止频率处于半带区间（避开坑 1，杜绝接近 Nyquist 的冲激退化）
//   7) 混合相位（Intermediate Phase）幅频与能量重心夹角
//   8) 1x / Nx 双路径正确匹配
#include "dsp/filter_families.h"
#include "dsp/resampler.h"
#include <cstdio>
#include <cstdint>
#include <climits>
#include <numeric>
#include <string>
#include <vector>
#include <cmath>
#include <algorithm>
#include <limits>

using namespace rta::dsp;

static int fails = 0;
static void check(bool ok, const std::string& what, const std::string& detail = "") {
    printf("  [%s] %s %s\n", ok ? "PASS" : "FAIL", what.c_str(), detail.c_str());
    if (!ok) ++fails;
}

static const double PI = 3.14159265358979323846;

static double tone_rms(ResamplerConfig cfg, double freqHz, size_t inFrames, double amp) {
    PolyphaseResampler rs(cfg);
    std::vector<double> x(inFrames), o(rs.maxOutFrames(inFrames) + 16);
    for (size_t n = 0; n < inFrames; ++n)
        x[n] = amp * std::sin(2.0 * PI * freqHz * (double)n / (double)cfg.inRate);
    const double* ip[1] = { x.data() };
    double* op[1] = { o.data() };
    const size_t n = rs.process(ip, inFrames, op);
    const size_t settle = std::min(n / 2, (size_t)20000);
    double acc = 0.0;
    for (size_t i = settle; i < n; ++i) acc += o[i] * o[i];
    return std::sqrt(acc / (double)(n - settle));
}

// Fit both quadratures at the ORIGINAL tone and image frequencies, over the
// ORIGINAL sample interval. No window or frequency-bin relocation is used.
// A single-bin DFT also measures the main tone's rectangular-record leakage.
static double fitted_image_db(const std::vector<double>& y, size_t settle, size_t n,
                              double toneHz, double imageHz, double rate) {
    double gram[4][5] = {};
    double rawRe = 0.0, rawIm = 0.0;
    for (size_t i = settle; i < n; ++i) {
        const double t = double(i - settle);
        const double u = 2.0 * PI * toneHz * t / rate, v = 2.0 * PI * imageHz * t / rate;
        const double x[4] = {std::cos(u), std::sin(u), std::cos(v), std::sin(v)};
        for (int r = 0; r < 4; ++r) {
            gram[r][4] += x[r] * y[i];
            for (int c = 0; c < 4; ++c) gram[r][c] += x[r] * x[c];
        }
        rawRe += y[i] * x[2]; rawIm += y[i] * x[3];
    }
    // The two distinct frequencies have a well-conditioned Gram matrix.
    for (int p = 0; p < 4; ++p) {
        const double pivot = gram[p][p];
        if (!(pivot > double(n - settle) * 0.1)) return 0.0;
        for (int c = p; c < 5; ++c) gram[p][c] /= pivot;
        for (int r = 0; r < 4; ++r) if (r != p) {
            const double factor = gram[r][p];
            for (int c = p; c < 5; ++c) gram[r][c] -= factor * gram[p][c];
        }
    }
    const double tone = std::hypot(gram[0][4], gram[1][4]);
    const double image = std::hypot(gram[2][4], gram[3][4]);
    // Conservative forward-error allowance for the four serial dot products,
    // their normal-equation solve and trigonometric argument rounding. This
    // is an amplitude UPPER bound, not a claimed measurement below precision.
    const double uncertainty = 32.0 * std::numeric_limits<double>::epsilon() * double(n - settle);
    const double upper = image / tone + uncertainty;
    const double raw = std::hypot(rawRe, rawIm) / (tone * double(n - settle) * 0.5);
    std::printf("    image: raw DFT %.6f dB, fitted %.6f dB, upper bound %.6f dB\n",
                20.0 * std::log10(raw + 1e-300), 20.0 * std::log10(image / tone + 1e-300),
                20.0 * std::log10(upper));
    return 20.0 * std::log10(upper);
}

static double image_db(ResamplerConfig cfg, double toneHz, double imageHz, size_t inFrames) {
    PolyphaseResampler rs(cfg);
    std::vector<double> x(inFrames), o(rs.maxOutFrames(inFrames) + 16);
    for (size_t n = 0; n < inFrames; ++n)
        x[n] = 0.5 * std::sin(2.0 * PI * toneHz * (double)n / (double)cfg.inRate);
    const double* ip[1] = { x.data() };
    double* op[1] = { o.data() };
    const size_t n = rs.process(ip, inFrames, op);
    const size_t settle = n / 3;
    return fitted_image_db(o, settle, n, toneHz, imageHz, double(cfg.outRate));
}

int main() {
    // Metrology negative controls: both are genuine tones at 29.1 kHz.
    // -50 dB must fail the original -60 dB bound; -100 dB must fail the
    // stronger -140 dB bound, despite passing the old leakage-limited test.
    for (double injectedDb : {-50.0, -100.0}) {
        const size_t n = 262144, settle = n / 3;
        std::vector<double> signal(n);
        for (size_t i = 0; i < n; ++i)
            signal[i] = 0.5 * std::sin(2.0 * PI * 15000.0 * double(i) / 705600.0 + 0.37) +
                        0.5 * std::pow(10.0, injectedDb / 20.0) *
                        std::sin(2.0 * PI * 29100.0 * double(i) / 705600.0 + 1.1);
        const double measured = fitted_image_db(signal, settle, n, 15000.0, 29100.0, 705600.0);
        check(std::fabs(measured - injectedDb) < 0.01 && measured > -140.0 &&
              (injectedDb < -60.0 || measured > -60.0),
              "负向对照：真实镜像保留且正确判红", std::to_string(injectedDb) + " -> " + std::to_string(measured));
    }

    printf("=== 1. 滤波器家族变体对比（全部 %zu 个预设）===\n", filter_presets().size());
    {
        printf("  %-26s %8s %4s %4s %10s %10s %10s %9s %9s\n",
               "预设", "抽头", "相位", "结构", "通带纹波", "阻带最大", "前/后能量", "峰值位置", "能量重心");
        for (const auto& p : filter_presets()) {
            FirSpec s;
            s.taps = p.taps; s.cutoff = 0.5 * (1.0 - p.transition);
            s.attenDb = p.attenDb; s.window = p.window;
            s.apodizing = p.apodizing;
            if (p.apodizing) {
                s.apodF1 = p.apodF1 * 0.5;
                s.apodF2 = p.apodF2 * 0.5;
            }
            auto h = design_fir(s);
            if (p.phase == PhaseKind::Minimum) h = to_minimum_phase(h);
            else if (p.phase == PhaseKind::Intermediate) h = to_intermediate_phase(h);

            const double fc = s.cutoff * 0.5;
            const double fPassTop = fc * 0.9 * 2.0;
            const double fStopBot = std::min(fc * 1.1 * 2.0, 1.0);

            double pmin = 1e9, pmax = -1e9;
            for (int i = 0; i <= 20; ++i) {
                const double d = magnitude_db(h, fPassTop * (double)i / 20.0);
                pmin = std::min(pmin, d); pmax = std::max(pmax, d);
            }
            double worst = -1e9;
            for (int i = 0; i <= 40; ++i)
                worst = std::max(worst, magnitude_db(h, fStopBot + (1.0 - fStopBot) * (double)i / 40.0));

            const double ripple = std::max(0.0, pmax - pmin);
            const double r = pre_post_ratio(h);
            const double pos = peak_position(h);
            const double cen = energy_centroid(h);

            printf("  %-26s %8d %4s %4s %10.4f %10.1f %10.4f %9.4f %9.1f\n",
                   p.name, (int)h.size(), phase_name(p.phase),
                   p.twoStage ? "2s" : "1s",
                   ripple, worst, r, pos, cen);

            // 通带纹波门禁：所有滤波器通带纹波应 < 0.1 dB
            check(ripple < 0.10, std::string(p.name) + " 通带平坦 (纹波 < 0.1 dB)",
                  std::to_string(ripple) + " dB");
            // 阻带衰减门禁：所有滤波器阻带衰减应 <= -80 dB
            check(worst <= -80.0, std::string(p.name) + " 阻带抑制达标",
                  std::to_string(worst) + " dB");
        }
    }

    printf("\n=== 2. 最小相位与线性相位的幅频响应一致性（避开坑 3）===\n");
    {
        const char* pairs[][2] = {
            { "poly-sinc-lp",             "poly-sinc-mp" },
            { "poly-sinc-gauss-long",     "poly-sinc-gauss-mp" },
            { "poly-sinc-gauss-hires-lp", "poly-sinc-gauss-hires-mp" },
            { "poly-sinc-short-lp",       "poly-sinc-short-mp" },
            { "poly-sinc-long-lp",        "poly-sinc-long-mp" },
            { "minringFIR",               "minringFIR-mp" }
        };
        for (auto& pr : pairs) {
            int tl = 0, tm = 0;
            auto hl = make_filter(pr[0], true, &tl);
            if (hl.empty()) hl = make_filter(pr[0], false, &tl);
            auto hm = make_filter(pr[1], true, &tm);
            if (hm.empty()) hm = make_filter(pr[1], false, &tm);
            if (hl.empty() || hm.empty()) { check(false, std::string(pr[0]) + " 生成失败"); continue; }
            double maxDiff = 0.0;
            for (int i = 1; i <= 40; ++i) {
                const double f = (double)i / 40.0;
                const double dl = magnitude_db(hl, f);
                const double dm = magnitude_db(hm, f);
                if (dl < -120.0 || dm < -120.0) continue;
                maxDiff = std::max(maxDiff, std::fabs(dl - dm));
            }
            char buf[200];
            std::snprintf(buf, sizeof(buf),
                          "(%d 抽头, -120 dB 以上最大偏差 %.4f dB)",
                          tl, maxDiff);
            printf("  %-26s vs %-26s %s\n", pr[0], pr[1], buf);
            const double tol = (tl <= 1024) ? 0.30 : 0.20;
            check(maxDiff < tol, std::string(pr[0]) + " 与 " + pr[1] + " 幅频一致 (偏差 " + std::to_string(maxDiff) + " dB < " + std::to_string(tol) + " dB)");
        }
    }

    printf("\n=== 3. 相位类型严格判据（前/后振铃能量比，避开坑 2）===\n");
    {
        // 1) 线性相位：前/后能量严格对称（≈1.0），峰值精确位于中心（0.5）
        for (const auto& name : { "poly-sinc-lp", "poly-sinc-gauss-hires-lp", "poly-sinc-ext2", "sinc-S" }) {
            auto h = make_filter(name, true);
            if (h.empty()) h = make_filter(name, false);
            const double r = pre_post_ratio(h);
            const double p = peak_position(h);
            printf("  线性相位 [%s]: 前/后能量比 %.4f, 峰值位置 %.4f\n", name, r, p);
            check(r > 0.90 && r < 1.10, std::string(name) + " 线性相位前/后能量对称 (≈1.0)");
            check(std::fabs(p - 0.5000) < 0.005, std::string(name) + " 线性相位峰值位于中心 (≈0.5)");
        }

        // 2) 最小相位：无预振铃，能量集中于开头，峰值在起始点 (<0.01)，前/后能量比 < 1.0
        for (const auto& name : { "poly-sinc-mp", "poly-sinc-gauss-hires-mp", "poly-sinc-short-mp" }) {
            auto h = make_filter(name, true);
            if (h.empty()) h = make_filter(name, false);
            const double r = pre_post_ratio(h);
            const double p = peak_position(h);
            const double c = energy_centroid(h);
            printf("  最小相位 [%s]: 前/后能量比 %.4f, 峰值位置 %.4f, 重心 %.1f / %zu\n",
                   name, r, p, c, h.size());
            check(r < 1.0, std::string(name) + " 最小相位前振铃严格不大于后振铃");
            check(p < 0.01, std::string(name) + " 最小相位峰值位于脉冲起始 (<0.01)");
            check(c < (double)h.size() * 0.02, std::string(name) + " 最小相位能量重心大幅靠前");
        }
    }

    printf("\n=== 4. 抽头数与过渡带单调性 ===\n");
    {
        // poly-sinc 梯级
        const auto* pShort = find_preset("poly-sinc-short-lp");
        const auto* pBase  = find_preset("poly-sinc-lp");
        const auto* pLong  = find_preset("poly-sinc-long-lp");
        const auto* pXl    = find_preset("poly-sinc-xl");
        if (pShort && pBase && pLong && pXl) {
            check(pShort->taps < pBase->taps && pBase->taps < pLong->taps && pLong->taps < pXl->taps,
                  "poly-sinc 抽头数单调递增 (short < base < long < xl)");
            check(pShort->transition > pBase->transition && pBase->transition > pLong->transition && pLong->transition > pXl->transition,
                  "poly-sinc 过渡带宽度单调收窄 (short > base > long > xl)");
        }

        // sinc 梯级
        const auto* pSincS  = find_preset("sinc-S");
        const auto* pSincM  = find_preset("sinc-M");
        const auto* pSincL  = find_preset("sinc-L");
        const auto* pSincLL = find_preset("sinc-LL");
        if (pSincS && pSincM && pSincL && pSincLL) {
            check(pSincS->taps < pSincM->taps && pSincM->taps < pSincL->taps && pSincL->taps < pSincLL->taps,
                  "sinc 族抽头数单调递增 (sinc-S < sinc-M < sinc-L < sinc-LL)");
            check(pSincS->transition > pSincM->transition && pSincM->transition > pSincL->transition && pSincL->transition > pSincLL->transition,
                  "sinc 族过渡带单调收窄");
        }

        // closed-form 梯级
        const auto* pCfFast = find_preset("closed-form-fast");
        const auto* pCfBase = find_preset("closed-form");
        const auto* pCfM    = find_preset("closed-form-M");
        const auto* pCf16M  = find_preset("closed-form-16M");
        if (pCfFast && pCfBase && pCfM && pCf16M) {
            check(pCfFast->taps < pCfBase->taps && pCfBase->taps < pCfM->taps && pCfM->taps < pCf16M->taps,
                  "closed-form 抽头数单调递增 (fast < base < M < 16M)");
            check(pCfFast->transition > pCfBase->transition && pCfBase->transition > pCfM->transition && pCfM->transition > pCf16M->transition,
                  "closed-form 过渡带单调收窄");
        }

        // halfband 梯级
        const auto* pHbS = find_preset("poly-sinc-hb-s");
        const auto* pHb  = find_preset("poly-sinc-hb");
        const auto* pHbM = find_preset("poly-sinc-hb-m");
        const auto* pHbL = find_preset("poly-sinc-hb-l");
        if (pHbS && pHb && pHbM && pHbL) {
            check(pHbS->taps < pHb->taps && pHb->taps < pHbM->taps && pHbM->taps < pHbL->taps,
                  "half-band 族抽头数单调递增 (hb-s < hb < hb-m < hb-l)");
            check(pHbS->transition > pHb->transition && pHb->transition > pHbM->transition && pHbM->transition > pHbL->transition,
                  "half-band 族过渡带单调收窄");
        }
    }

    printf("\n=== 5. 两段式（*-2s）与单段对应变体一致性 ===\n");
    {
        struct TestPair {
            const char* name;
            const char* s1;
            const char* s2;
        };
        TestPair pairs[] = {
            { "poly-sinc",      "poly-sinc-lp",         "poly-sinc-2s" },
            { "poly-sinc-short","poly-sinc-short-lp",   "poly-sinc-short-2s" },
            { "poly-sinc-gauss","poly-sinc-gauss-long", "poly-sinc-gauss-2s" },
            { "poly-sinc-ext2", "poly-sinc-ext2",       "poly-sinc-ext2-2s" },
            { "poly-sinc-hb",   "poly-sinc-hb",         "poly-sinc-hb-2s" }
        };

        for (const auto& pr : pairs) {
            const auto* p2 = find_preset(pr.s2, true);
            if (!p2) { check(false, std::string(pr.name) + " 预设缺失"); continue; }

            // c2 为两段式变体，c1 为其对应的单段版本（保持抽头/过渡带/窗函数完全一致）
            ResamplerConfig c2;
            c2.inRate = 44100; c2.outRate = 705600; c2.channels = 1;
            apply_preset(c2, *p2);

            ResamplerConfig c1 = c2;
            c1.twoStage = false;

            PolyphaseResampler r1(c1), r2(c2);
            check(!r1.two_stage(), std::string(pr.s1) + " 单段基准未启用两段式");
            check(r2.two_stage(),  std::string(pr.s2) + " 正确启用两段式");

            // 1) 可听带幅度一致性 (< 0.015 dB)
            double maxDiff = 0.0;
            for (double f : { 100.0, 1000.0, 10000.0, 19000.0 }) {
                const double rms1 = tone_rms(c1, f, 8192, 0.5);
                const double rms2 = tone_rms(c2, f, 8192, 0.5);
                const double diffDb = 20.0 * std::log10((rms2 + 1e-300) / (rms1 + 1e-300));
                maxDiff = std::max(maxDiff, std::fabs(diffDb));
            }
            printf("  %s: 可听带单级 vs 两段式最大幅度差 %.5f dB\n", pr.name, maxDiff);
            check(maxDiff < 0.015, std::string(pr.name) + " 单级与两段式可听带幅度一致 (< 0.015 dB)");

            // 2) 镜像抑制 (15 kHz -> 29.1 kHz)
            const double i1 = image_db(c1, 15000.0, 29100.0, 16384);
            const double i2 = image_db(c2, 15000.0, 29100.0, 16384);
            printf("  %s 镜像抑制: 单级 %.1f dB, 两段式 %.1f dB (差 %.2f dB)\n",
                   pr.name, i1, i2, std::fabs(i2 - i1));
            check(i1 < -140.0 && i2 < -140.0, std::string(pr.name) + " 真实镜像幅度上界优于 -140 dB");
            check(i1 < -60.0 && i2 < -60.0, std::string(pr.name) + " 镜像幅度上界深于 -60 dB (同频点双正弦拟合)");
            check(std::fabs(i2 - i1) < 6.0,  std::string(pr.name) + " 两段式镜像抑制与单级相当 (差 < 6 dB)");

            // 3) 分块与整块一致性 (333 / 777 / 1024 帧)
            const size_t N = 4096;
            std::vector<double> x(N);
            for (size_t n = 0; n < N; ++n) x[n] = 0.4 * std::sin(2.0 * PI * 997.0 * (double)n / 44100.0);
            PolyphaseResampler whole(c2);
            std::vector<double> ref(whole.maxOutFrames(N) + 16);
            const double* ip[1] = { x.data() };
            double* op[1] = { ref.data() };
            const size_t wholeGot = whole.process(ip, N, op);

            for (size_t chunk : { (size_t)777, (size_t)333, (size_t)1024 }) {
                PolyphaseResampler rs(c2);
                std::vector<double> out;
                size_t pos = 0;
                while (pos < N) {
                    const size_t n = std::min(chunk, N - pos);
                    std::vector<double> o(rs.maxOutFrames(n) + 16);
                    const double* cip[1] = { x.data() + pos };
                    double* cop[1] = { o.data() };
                    const size_t got = rs.process(cip, n, cop);
                    out.insert(out.end(), o.begin(), o.begin() + got);
                    pos += n;
                }
                size_t diff = 0;
                const size_t m = std::min(out.size(), wholeGot);
                for (size_t i = 0; i < m; ++i) if (out[i] != ref[i]) ++diff;
                check(diff == 0, std::string(pr.s2) + " 分块 (" + std::to_string(chunk) + " 帧) 与整块输出逐位一致");
            }
        }
    }

    printf("\n=== 6. 避开坑 1：截止频率半带区间物理校验 ===\n");
    {
        for (const auto& p : filter_presets()) {
            const double cutoff = 0.5 * (1.0 - p.transition);
            check(cutoff >= 0.35 && cutoff <= 0.499,
                  std::string(p.name) + " 截止位于半带真实区间 (0.35..0.499)",
                  "fc=" + std::to_string(cutoff));
        }
    }

    printf("\n=== 7. 混合相位（Intermediate Phase）特性 ===\n");
    {
        FirSpec s;
        s.taps = 4095; s.cutoff = 0.45; s.attenDb = 120; s.window = WindowKind::Kaiser;
        auto hl = design_fir(s);
        auto hm = to_minimum_phase(hl);
        auto hx = to_intermediate_phase(hl, 0.5);

        double worst = 0.0;
        for (int i = 0; i <= 40; ++i) {
            const double f = 0.45 * 0.8 * (double)i / 40.0;
            worst = std::max(worst, std::fabs(magnitude_db(hx, f) - magnitude_db(hl, f)));
        }
        check(worst < 0.05, "混合相位幅频与线性相位一致", "最大偏差 " + std::to_string(worst) + " dB");

        const double cl = energy_centroid(hl), cm = energy_centroid(hm), cx = energy_centroid(hx);
        printf("  能量重心  线性 %.1f  混合 %.1f  最小 %.1f\n", cl, cx, cm);
        check(cx > cm && cx < cl, "混合相位能量重心落在两者之间");

        auto h0 = to_intermediate_phase(hl, 0.0);
        auto h1 = to_intermediate_phase(hl, 1.0);
        double d0 = 0.0, d1 = 0.0;
        for (size_t i = 0; i < hl.size(); ++i) {
            d0 = std::max(d0, std::fabs(h0[i] - hm[i]));
            d1 = std::max(d1, std::fabs(h1[i] - hl[i]));
        }
        check(d0 < 1e-12, "a=0 退化为最小相位");
        check(d1 < 1e-12, "a=1 退化为线性相位");
    }

    printf("\n=== 8. 1x / Nx 双路径选择 ===\n");
    {
        int t1x = 0, tNx = 0;
        auto h1 = make_filter("poly-sinc-long-lp", false, &t1x);
        auto hN = make_filter("poly-sinc-long-lp", true,  &tNx);
        printf("  1x 路径抽头 %d，Nx 路径抽头 %d\n", t1x, tNx);
        check(t1x > 0 && tNx > 0, "两条路径都能生成");

        const auto* pGaussHires = find_preset("poly-sinc-gauss-hires-lp", true);
        check(pGaussHires && pGaussHires->forNx, "poly-sinc-gauss-hires-lp 正确标记为 Nx 专用");
    }

    // =================================================================
    // 9. 抽头预算与输出采样率解耦（tapsPerInput 家族）+ 既有预设逐位回归
    // =================================================================
    // 背景（实测见 docs/PCM回放质量-实测与改进.md）：
    //   原型在内插域设计，每相位抽头 T = totalTaps / L。同一个 4095 抽头预设，
    //   44.1k->705.6k（L=16）有 255 抽头/相位，44.1k->384k（L=1280）只剩 4 个：
    //   通带 20 kHz 处 -5.1 dB、1 kHz 单音镜像只压到 -29 dB。
    //   新家族直接指定"每输入样本内核长度"，令 T 与 L 无关，频响因此与输出率无关。
    printf("\n=== 9. 抽头预算与输出采样率解耦（tapsPerInput）与既有预设回归 ===\n");
    {
        auto proto_of = [](const FilterPreset& fp, uint32_t inR, uint32_t outR, int* Lp, int* Tp) {
            ResamplerConfig c; c.inRate = inR; c.outRate = outR; c.channels = 1;
            apply_preset(c, fp);
            PolyphaseResampler rs(c);
            std::vector<double> h; rs.prototype_into(h);
            if (Lp) *Lp = rs.upFactor();
            if (Tp) *Tp = rs.tapsPerPhase();
            return h;
        };
        // 9.1 家族构成：老式预设必须全部 tapsPerInput==0（否则等于悄悄改历史输出）
        size_t legacyN = 0, newN = 0;
        for (const auto& fp : filter_presets()) { if (fp.tapsPerInput == 0) ++legacyN; else ++newN; }
        printf("  预设构成：老式 %zu 个，内核长度家族 %zu 个\n", legacyN, newN);
        check(newN >= 2, "存在 tapsPerInput 家族预设", std::to_string(newN) + " 个");

        // 9.2 Disabling the new floor must retain the legacy tap-budget path.
        // The v3.3.11 table/phase changes are intentional: an old aggregate hash
        // would lock the old design. Instead compare every coefficient against
        // an explicitly supplied, independently computed legacy support.
        int checkedCount = 0;
        double worstCoefficient = 0.0;
        bool legacyBudgetUnchanged = true;
        for (const auto& fp : filter_presets()) {
            if (fp.tapsPerInput != 0 || fp.taps >= 2000000) continue;
            for (uint32_t outputRate : {88200u, 384000u}) {
            // Cover high-L starvation without designing every multi-million-tap
            // prototype twice. These cover LP/MP/IP and Kaiser/Gaussian/BH.
            const std::string name = fp.name;
            if (outputRate == 384000 && name != "poly-sinc-short-lp" &&
                name != "poly-sinc-short-mp" && name != "poly-sinc-gauss-long" &&
                name != "poly-sinc-ext2-hires-ip" && name != "minringFIR") continue;
            ResamplerConfig c; c.inRate = 44100; c.outRate = outputRate; c.channels = 1;
            apply_preset(c, fp);
            c.twoStage = false; c.allowAutomaticCascade = false; c.applyTapFloor = false;
            int expectedT = c.minTapsPerInput > 0 ? c.minTapsPerInput : std::max(4, c.totalTaps / int(c.outRate / std::gcd(c.inRate, c.outRate)));
            if (c.minTapsPerInput == 0 && c.phase == PhaseKind::Linear && c.transition > 0.0)
                expectedT = std::min(expectedT, std::max(4, int(2.0 * 21.13 / c.transition + 0.5)));
            PolyphaseResampler actual(c);
            ResamplerConfig explicitSupport = c; explicitSupport.minTapsPerInput = expectedT;
            PolyphaseResampler reference(explicitSupport);
            std::vector<double> h, ref; actual.prototype_into(h); reference.prototype_into(ref);
            legacyBudgetUnchanged &= actual.tapsPerPhase() == expectedT && h.size() == ref.size();
            if (h.size() == ref.size()) for (size_t i = 0; i < h.size(); ++i) {
                const double error = std::fabs(h[i] - ref[i]);
                worstCoefficient = std::max(worstCoefficient, error);
                legacyBudgetUnchanged &= std::isfinite(h[i]) && error <= 1e-6 * std::max(1.0, std::fabs(ref[i]));
            }
            ++checkedCount;
            }
        }
        check(legacyBudgetUnchanged && checkedCount >= 70,
              "关闭 floor 与显式旧式抽头预算逐系数一致（相对容差 1e-6）",
              "count=" + std::to_string(checkedCount) + " max_error=" + std::to_string(worstCoefficient));
        // Negative control: the floor must measurably change an undersized FIR.
        ResamplerConfig undersized; undersized.inRate = 44100; undersized.outRate = 705600;
        undersized.channels = 1; undersized.totalTaps = 64; undersized.transition = 0.1;
        undersized.applyTapFloor = false;
        PolyphaseResampler noFloor(undersized);
        undersized.applyTapFloor = true; PolyphaseResampler withFloor(undersized);
        std::vector<double> hf, hn; noFloor.prototype_into(hn); withFloor.prototype_into(hf);
        const double stopDifference = std::fabs(magnitude_db(hf, 2.0 * 29100.0 / 705600.0) -
                                                magnitude_db(hn, 2.0 * 29100.0 / 705600.0));
        check(noFloor.tapsPerPhase() == 4 && withFloor.tapsPerPhase() > 4 && stopDifference > 20.0,
              "负向对照：误启用 floor 会改变抽头预算和真实镜像频响 (>20 dB)", std::to_string(stopDifference));

        // 9.3 新家族：频响与输出采样率无关 + CPU 代价可预测
        for (const char* nm : { "poly-sinc-tight-lp", "apod-20k-tight" }) {
            const FilterPreset* fp = find_preset(nm, false);
            check(fp != nullptr, std::string(nm) + " 预设存在");
            if (!fp) continue;
            check(fp->tapsPerInput > 0, std::string(nm) + " 使用内核长度制式",
                  "tapsPerInput=" + std::to_string(fp->tapsPerInput));
            double f01min = 1e18, f01max = -1e18, d20min = 1e9, d20max = -1e9, worstSt = -1e9;
            int Tfirst = 0, Tspread = 0;
            for (uint32_t ov : { 88200u, 192000u, 352800u, 384000u, 705600u }) {
                int L = 0, T = 0;
                auto h = proto_of(*fp, 44100, ov, &L, &T);
                if (Tfirst == 0) Tfirst = T; else Tspread = std::max(Tspread, std::abs(T - Tfirst));
                const double gain = 20.0 * std::log10((double)L);
                auto rel = [&](double f) { return magnitude_db(h, 2.0 * f / (44100.0 * (double)L)) - gain; };
                double lo = 20.0, hi = 0.499 * 44100.0;
                for (int i = 0; i < 60; ++i) { const double m = 0.5 * (lo + hi); if (rel(m) > -0.1) lo = m; else hi = m; }
                const double f01 = 0.5 * (lo + hi);
                f01min = std::min(f01min, f01); f01max = std::max(f01max, f01);
                const double d20 = rel(20000.0);
                d20min = std::min(d20min, d20); d20max = std::max(d20max, d20);
                const double fMax = 44100.0 * (double)L * 0.5;      // 内插域 Nyquist（超过它频率轴会镜像回来）
                for (int i = 1; i <= 120; ++i) {
                    const double f = 22050.0 * (1.0 + 3.0 * (double)i / 120.0);
                    if (f >= fMax) break;
                    worstSt = std::max(worstSt, rel(f));
                }
            }
            char buf[200];
            std::snprintf(buf, sizeof(buf), "-0.1dB 点 %.0f..%.0f Hz, 20 kHz %.3f..%.3f dB, 最差阻带 %.1f dB",
                          f01min, f01max, d20min, d20max, worstSt);
            printf("  %-22s %s\n", nm, buf);
            check(f01max - f01min < 20.0, std::string(nm) + " 频响与输出采样率无关（-0.1dB 跨 5 个速率一致）");
            check(d20max - d20min < 0.005, std::string(nm) + " 20 kHz 处幅度跨速率一致 (<0.005 dB)");
            check(worstSt <= -130.0, std::string(nm) + " 阻带 >=130 dB");
            const int expectedT = fp->apodizing
                ? apod_quality_taps(fp->apodF1, fp->apodF2, fp->window == WindowKind::Gaussian,
                                    std::max(fp->attenDb, preset_ceiling_db(fp->window)), fp->tapsPerInput)
                : fp->tapsPerInput;
            check(Tspread == 0 && Tfirst == expectedT,
                  std::string(nm) + " 每相位抽头数跨速率恒定（CPU 代价可预测）",
                  "T=" + std::to_string(Tfirst));
        }

        // 9.4 抽头地板生效验证（applyTapFloor=true 修复高 L 下 20 kHz 塌陷）
        {
            const FilterPreset* fp = find_preset("poly-sinc-short-lp", false);
            int L = 0, T = 0;
            auto h = proto_of(*fp, 44100, 384000, &L, &T);
            const double gain = 20.0 * std::log10((double)L);
            const double d20 = magnitude_db(h, 2.0 * 20000.0 / (44100.0 * (double)L)) - gain;
            printf("  [抽头地板] poly-sinc-short-lp @44.1k->384k: T=%d, 20 kHz = %.4f dB\n", T, d20);
            check(T >= 211, "既有短预设在高 L 下启用抽头地板 (T >= 211)");
            check(d20 > -0.1, "既有短预设在 384k 下 20 kHz 不再塌陷 (> -0.1 dB)", std::to_string(d20) + " dB");
        }
    }

    // =================================================================
    // 10. 全滤波器 × 全升频倍率(1x/2x/4x/8x/16x)与设计参数抽头数审计
    // =================================================================
    printf("\n=== 10. 全滤波器与升频参数抽头数审计表（共 %zu 个预设）===\n", filter_presets().size());
    {
        auto effective_plan_T = [](const ResamplerPlan& pl) -> int {
            if (pl.stageCount == 0) return 0;
            if (pl.stageCount == 1) return pl.stages[0].T;
            const int64_t t1 = pl.stages[0].T;
            const int64_t t2 = pl.stages[1].T;
            const int64_t f1 = std::max(1, pl.stages[0].L);
            const int64_t eff = t1 + (t2 + f1 - 1) / f1;
            return (eff > INT_MAX) ? INT_MAX : int(eff);
        };

        auto format_stage_cell = [&](const ResamplerPlan& pl, char* buf, size_t sz) {
            if (pl.stageCount == 2) {
                std::snprintf(buf, sz, "%d+%d(%llu)",
                              pl.stages[0].T, pl.stages[1].T,
                              (unsigned long long)pl.coefficientCount);
            } else {
                std::snprintf(buf, sz, "%d(%llu)",
                              pl.stages[0].T,
                              (unsigned long long)pl.coefficientCount);
            }
        };

        printf("  %-26s %-3s %-3s %-2s %-7s %-11s %-9s %-14s %-14s %-18s %-18s %-18s %s\n",
               "name", "pth", "ph", "2s", "cutoff", "qual(raw/ef)", "1x_taps",
               "2x(T/tot)", "4x(T/tot)", "8x(T/tot)", "16x(T/tot)", "384k(T/tot)", "ui_vs_dsp");

        bool all1xValid = true;
        bool allPlansValid = true;
        bool allTwoStageNonZero = true;
        bool allDesignRelValid = true;
        bool allLiveValid = true;
        size_t uiMismatchCount = 0;
        size_t tMaxClampedCount = 0;
        size_t tapsPerInputCount = 0;
        size_t twoStageCount = 0;

        for (const auto& fp : filter_presets()) {
            const double cutoff = 0.5 * (1.0 - fp.transition);
            const double effAtten = std::max(fp.attenDb, preset_ceiling_db(fp.window));

            // 1x prototype via make_filter + 1x passthrough via PolyphaseResampler
            int t1x = 0;
            auto h1x = make_filter(fp.name, fp.forNx, &t1x);
            bool coeffsFinite = !h1x.empty() && t1x == fp.taps && t1x > 0 && (int)h1x.size() == fp.taps;
            for (double v : h1x) {
                if (!std::isfinite(v)) { coeffsFinite = false; break; }
            }
            if (!coeffsFinite) all1xValid = false;

            ResamplerConfig c1x;
            c1x.inRate = 44100; c1x.outRate = 44100; c1x.channels = 1;
            apply_preset(c1x, fp);
            const auto p1x = plan_resampler(c1x);
            PolyphaseResampler r1x(c1x);
            if (p1x.stageCount != 0 || p1x.coefficientCount != 0 || !r1x.passthrough() ||
                r1x.tapsPerPhase() != 0 || r1x.coefficient_count() != 0) {
                allPlansValid = false;
            }

            const uint32_t outRates[5] = { 88200u, 176400u, 352800u, 705600u, 384000u };
            ResamplerPlan plans[5];
            int effT[5] = {};
            for (int ri = 0; ri < 5; ++ri) {
                ResamplerConfig cfg;
                cfg.inRate = 44100; cfg.outRate = outRates[ri]; cfg.channels = 1;
                apply_preset(cfg, fp);
                plans[ri] = plan_resampler(cfg);
                const auto& pl = plans[ri];

                uint64_t sumStage = 0;
                for (size_t s = 0; s < pl.stageCount; ++s) {
                    sumStage += pl.stages[s].coefficientCount;
                    if (pl.stages[s].T < 4 || pl.stages[s].L < 2 ||
                        pl.stages[s].coefficientCount != uint64_t(pl.stages[s].T) * uint64_t(pl.stages[s].L)) {
                        allPlansValid = false;
                    }
                }
                if (pl.stageCount == 0 || pl.coefficientCount == 0 ||
                    pl.coefficientCount != sumStage ||
                    pl.cachePayloadBytes != pl.coefficientCount * sizeof(double)) {
                    allPlansValid = false;
                }
                effT[ri] = effective_plan_T(pl);
                if (effT[ri] <= 0) allPlansValid = false;

                // Old-red preservation for two-stage presets (ri=2,3,4 => 8x, 16x, 384k)
                if (fp.twoStage && ri >= 2) {
                    if (pl.stageCount != 2 || pl.stages[0].L != 4 || pl.stages[1].T < fp.stage2Taps) {
                        allDesignRelValid = false;
                    }
                }

                // Live PolyphaseResampler verification:
                // - All 79 presets at 16x (705600)
                // - All two-stage presets at all 5 rates
                // - All Linear or <= 65535 presets at all 4 integer rates (2x/4x/8x/16x)
                const bool runLive = (ri == 3) || fp.twoStage ||
                    (ri < 4 && (fp.phase == PhaseKind::Linear || fp.taps <= 65535));
                if (runLive) {
                    PolyphaseResampler rs(cfg);
                    if (rs.tapsPerPhase() <= 0 || rs.tapsPerPhase() != effT[ri] ||
                        rs.coefficient_count() != pl.coefficientCount ||
                        rs.coefficient_count() == 0 ||
                        rs.tapsPerPhase() < (int)std::ceil(rs.tailInputSamples())) {
                        allLiveValid = false;
                    }
                    if (rs.two_stage()) {
                        if (rs.tapsPerPhase() <= 0 || rs.stage1_taps_per_phase() <= 0 ||
                            rs.stage2_taps_per_phase() <= 0 ||
                            rs.tapsPerPhase() != rs.stage1_taps_per_phase() +
                                (rs.stage2_taps_per_phase() + rs.stage1_factor() - 1) / rs.stage1_factor()) {
                            allTwoStageNonZero = false;
                        }
                    }
                }
            }

            // Check 48k base integer upsampling (96k/192k/384k/768k) plan consistency
            for (uint32_t out48 : { 96000u, 192000u, 384000u, 768000u }) {
                ResamplerConfig c48;
                c48.inRate = 48000; c48.outRate = out48; c48.channels = 1;
                apply_preset(c48, fp);
                const auto p48 = plan_resampler(c48);
                if (p48.stageCount == 0 || p48.coefficientCount == 0 || effective_plan_T(p48) <= 0) {
                    allPlansValid = false;
                }
            }

            // Check design relationships across 2x -> 4x -> 8x -> 16x
            if (fp.tapsPerInput > 0) {
                ++tapsPerInputCount;
                const int expT = fp.apodizing
                    ? apod_quality_taps(fp.apodF1, fp.apodF2, fp.window == WindowKind::Gaussian, effAtten, fp.tapsPerInput)
                    : fp.tapsPerInput;
                for (int ri = 0; ri < 4; ++ri) {
                    if (plans[ri].stages[0].T != expT) allDesignRelValid = false;
                }
                if (!fp.twoStage) {
                    if (plans[1].coefficientCount != plans[0].coefficientCount * 2 ||
                        plans[2].coefficientCount != plans[0].coefficientCount * 4 ||
                        plans[3].coefficientCount != plans[0].coefficientCount * 8) {
                        allDesignRelValid = false;
                    }
                }
            } else if (!fp.twoStage && !fp.apodizing) {
                for (int ri = 0; ri < 3; ++ri) {
                    if (effT[ri] < effT[ri + 1]) allDesignRelValid = false;
                }
                if (fp.phase == PhaseKind::Linear) {
                    const int tMin = std::max(4, int(21.13 / fp.transition + 0.5));
                    const int tMax = std::max(tMin, int(2.0 * 21.13 / fp.transition + 0.5));
                    for (int ri = 0; ri < 4; ++ri) {
                        if (effT[ri] < tMin || effT[ri] > tMax) allDesignRelValid = false;
                    }
                    for (int ri = 0; ri < 3; ++ri) {
                        if (plans[ri].coefficientCount > plans[ri + 1].coefficientCount) allDesignRelValid = false;
                    }
                }
            }

            // Classify UI nominal fp.taps vs DSP PolyphaseResampler discrepancy
            std::string note = "ok";
            if (fp.tapsPerInput > 0) {
                note = "tapsPerInput(T=" + std::to_string(effT[0]) + ")";
                ++uiMismatchCount;
            } else if (fp.twoStage) {
                ++twoStageCount;
                note = "2s_cascade";
                if (plans[0].coefficientCount != (uint64_t)fp.taps) ++uiMismatchCount;
            } else if (fp.apodizing) {
                note = "apod_quality(T=" + std::to_string(effT[0]) + ")";
                ++uiMismatchCount;
            } else if (fp.phase == PhaseKind::Linear) {
                const int tMax = std::max(4, int(2.0 * 21.13 / fp.transition + 0.5));
                if (fp.taps / 2 > tMax) {
                    ++tMaxClampedCount;
                    ++uiMismatchCount;
                    note = "tMax_cap(" + std::to_string(tMax) + ")";
                }
            }

            char c2x[32], c4x[32], c8x[32], c16x[32], c384[32], qbuf[24];
            format_stage_cell(plans[0], c2x, sizeof(c2x));
            format_stage_cell(plans[1], c4x, sizeof(c4x));
            format_stage_cell(plans[2], c8x, sizeof(c8x));
            format_stage_cell(plans[3], c16x, sizeof(c16x));
            format_stage_cell(plans[4], c384, sizeof(c384));
            std::snprintf(qbuf, sizeof(qbuf), "%.0f/%.0f", fp.attenDb, effAtten);
            printf("  %-26s %-3s %-3s %-2s %-7.4f %-11s %-9d %-14s %-14s %-18s %-18s %-18s %s\n",
                   fp.name, fp.forNx ? "Nx" : "1x", phase_name(fp.phase), fp.twoStage ? "2s" : "1s",
                   cutoff, qbuf, t1x, c2x, c4x, c8x, c16x, c384, note.c_str());
        }

        printf("  统计: 预设=%zu, tapsPerInput=%zu, 2s=%zu, tMax截断=%zu, UI标称与Nx实际抽头差异=%zu\n",
               filter_presets().size(), tapsPerInputCount, twoStageCount, tMaxClampedCount, uiMismatchCount);

        check(all1xValid, "全79个预设 1x make_filter 抽头数有限且 > 0 (精确等于 fp.taps)");
        check(allPlansValid, "全79个预设在 1x/2x/4x/8x/16x/384k 与 48k系 倍率下 plan_resampler 抽头有限且 > 0");
        check(allTwoStageNonZero, "旧红修复：全部 11 个 *-2s 两段式预设在 8x/16x/384k 下 tapsPerPhase() > 0 且 >= ceil(tail)");
        check(allDesignRelValid, "全部预设满足抽头设计关系 (tapsPerInput恒定 / Linear单调+tMax / 2s分段结构)");
        check(allLiveValid, "实实例化 PolyphaseResampler 抽头数与 plan_resampler 完全一致且 > 0");

        // 参数扫描 1: 升频质量(attenDb)对抽头数的影响
        {
            const double qs[] = { 90.0, 120.0, 180.0, 240.0, 280.0, 340.0 };
            int prevApodT = 0, prevStage2T = 0;
            bool qMonotonic = true;
            for (double q : qs) {
                const int ta = apod_quality_taps(18400.0 / 22050.0, 21800.0 / 22050.0, false, q, 0);
                if (ta <= 0 || ta < prevApodT) qMonotonic = false;
                prevApodT = ta;

                ResamplerConfig ds;
                ds.inRate = 192000; ds.outRate = 44100; ds.channels = 1;
                ds.totalTaps = 32767; ds.transition = 0.04; ds.attenDb = q; ds.autoTaps = true;
                const auto pds = plan_resampler(ds);
                const int nominalT = solve_taps_per_phase(ds.window, ds.transition, false, 0.0, 0.0, ds.totalTaps, 0, 44100.0);
                if (pds.stageCount == 0 || pds.stages[0].T <= nominalT ||
                    pds.stages[0].config.attenDb < q) {
                    qMonotonic = false;
                }

                ResamplerConfig r2s;
                r2s.inRate = 44100; r2s.outRate = 384000; r2s.channels = 1;
                r2s.totalTaps = 32767; r2s.transition = 0.04; r2s.attenDb = q; r2s.twoStage = true;
                const auto pr2s = plan_resampler(r2s);
                if (pr2s.stageCount != 2 || pr2s.stages[1].T <= 0 || pr2s.stages[1].T < prevStage2T) qMonotonic = false;
                prevStage2T = pr2s.stages[1].T;
            }
            check(qMonotonic, "质量参数(attenDb=90..340) 对应 apod / 2s二段抽头单调非降且 autoTaps 降采样附加抗混叠余量 > 0");
        }

        // 参数扫描 2: cutoff / transition 对抽头数的影响
        {
            const double trs[] = { 0.25, 0.10, 0.04, 0.015 };
            int prevAutoT = 0, prevFloorT = 0;
            bool trMonotonic = true;
            for (double tr : trs) {
                ResamplerConfig ca;
                ca.inRate = 44100; ca.outRate = 705600; ca.channels = 1;
                ca.totalTaps = 4095; ca.transition = tr; ca.attenDb = 200.0; ca.autoTaps = true;
                const auto pa = plan_resampler(ca);
                if (pa.stageCount == 0 || pa.stages[0].T <= prevAutoT) trMonotonic = false;
                prevAutoT = pa.stages[0].T;

                ResamplerConfig cf = ca;
                cf.autoTaps = false; cf.applyTapFloor = true;
                const auto pf = plan_resampler(cf);
                if (pf.stageCount == 0 || pf.stages[0].T <= prevFloorT) trMonotonic = false;
                prevFloorT = pf.stages[0].T;
            }
            check(trMonotonic, "过渡带收窄(cutoff 0.375->0.4925) 使 autoTaps 与 tapFloor 抽头数严格单调递增");
        }

        // 参数扫描 3: phase (Linear / Minimum / Intermediate) 对抽头数的影响
        {
            const int tMaxExpected = int(2.0 * 21.13 / 0.04 + 0.5); // 1057
            bool phaseValid = true;
            for (PhaseKind ph : { PhaseKind::Linear, PhaseKind::Minimum, PhaseKind::Intermediate }) {
                for (uint32_t outR : { 88200u, 176400u, 352800u, 705600u }) {
                    ResamplerConfig cp;
                    cp.inRate = 44100; cp.outRate = outR; cp.channels = 1;
                    cp.totalTaps = 32767; cp.transition = 0.04; cp.attenDb = 180.0; cp.phase = ph;
                    const auto pp = plan_resampler(cp);
                    const int L = int(outR / 44100u);
                    if (pp.stageCount != 1 || pp.stages[0].T <= 0 || pp.coefficientCount == 0) phaseValid = false;
                    if (ph == PhaseKind::Linear && pp.stages[0].T != tMaxExpected) phaseValid = false;
                    if (ph != PhaseKind::Linear && pp.stages[0].T != 32767 / L) phaseValid = false;
                }
            }
            check(phaseValid, "相位参数(Linear/Minimum/Intermediate) 抽头规划全部 > 0 且符合 tMax/预算规则");
        }

        // 旧红回归 4: ResamplePurpose::Dsd + apod-20k 在 16x 下 Stage 2 必须清除 apodizing
        {
            const FilterPreset* ap = find_preset("apod-20k", false);
            check(ap != nullptr, "apod-20k 预设存在");
            if (ap) {
                ResamplerConfig dc;
                dc.inRate = 44100; dc.outRate = 705600; dc.channels = 1;
                apply_preset(dc, *ap);
                apply_resample_purpose(dc, ResamplePurpose::Dsd);
                const auto dp = plan_resampler(dc);
                PolyphaseResampler drs(dc);
                check(dp.stageCount == 2 && !dp.stages[1].config.apodizing &&
                      dp.stages[1].config.apodF1 == 0.0 && dp.stages[1].config.apodF2 == 0.0,
                      "旧红修复：DSD 两段式 + apod 预设在 Stage 2 不继承输入域 apodizing");
                check(drs.two_stage() && drs.tapsPerPhase() > 0 &&
                      drs.tapsPerPhase() == effective_plan_T(dp) &&
                      drs.coefficient_count() == dp.coefficientCount,
                      "DSD 两段式 + apod 预设 tapsPerPhase() 与 coefficient_count() 一致且 > 0");
            }
        }
    }

    printf("\n%s (失败项 %d)\n", fails == 0 ? "全部通过" : "存在失败", fails);
    return fails == 0 ? 0 : 1;
}
