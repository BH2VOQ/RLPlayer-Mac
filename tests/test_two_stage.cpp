// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_two_stage.cpp — 两段式升频（44.1k -> 705.6k）的正确性、收益与不变性
//
// 判据：
//   1) 可听带内的幅度必须与单级完全一致（差 < 0.01 dB）—— 两级不能改变"声音是什么"
//   2) 镜像抑制必须同样深（把 15 kHz 单音升频后，29.1 kHz 的镜像 < -140 dB）
//   3) 分块不变性（333/777/8192 帧与整块逐位一致）
//   4) 运算量必须真的下降（同参数下 CPU 时间应显著减少）
#include "dsp/resampler.h"
#include <cstdio>
#include <cmath>
#include <vector>
#include <string>
#include <chrono>
#include <algorithm>
#include <limits>

using namespace rta::dsp;

static int fails = 0;
static void check(bool ok, const std::string& what, const std::string& detail = "") {
    printf("  [%s] %s %s\n", ok ? "PASS" : "FAIL", what.c_str(), detail.c_str());
    if (!ok) ++fails;
}

static const double PI = 3.14159265358979323846;

// 用正弦测某频率处的输出幅度（去掉前 settle 个输出样本，取整数个周期算 RMS）
static double tone_rms(ResamplerConfig cfg, double freqHz, size_t inFrames, double amp) {
    PolyphaseResampler rs(cfg);
    std::vector<double> x(inFrames), o(rs.maxOutFrames(inFrames) + 16);
    for (size_t n = 0; n < inFrames; ++n) x[n] = amp * std::sin(2.0 * PI * freqHz * (double)n / (double)cfg.inRate);
    const double* ip[1] = { x.data() };
    double* op[1] = { o.data() };
    const size_t n = rs.process(ip, inFrames, op);
    const size_t settle = std::min(n / 2, (size_t)20000);
    double acc = 0.0;
    for (size_t i = settle; i < n; ++i) acc += o[i] * o[i];
    return std::sqrt(acc / (double)(n - settle));
}

// 测镜像抑制：15 kHz 单音升频后，29.1 kHz 处的功率（用 DFT 单点）
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
    for (size_t n = 0; n < inFrames; ++n) x[n] = 0.5 * std::sin(2.0 * PI * toneHz * (double)n / (double)cfg.inRate);
    const double* ip[1] = { x.data() };
    double* op[1] = { o.data() };
    const size_t n = rs.process(ip, inFrames, op);
    const size_t settle = n / 3;
    return fitted_image_db(o, settle, n, toneHz, imageHz, double(cfg.outRate));
}

static void run_bench(bool twoStage, double* msOut) {
    ResamplerConfig cfg;
    cfg.inRate = 44100; cfg.outRate = 705600; cfg.channels = 1;
    cfg.totalTaps = 32768; cfg.twoStage = twoStage;
    PolyphaseResampler rs(cfg);
    const size_t N = 4410;                 // 0.1 秒
    std::vector<double> x(N), o(rs.maxOutFrames(N) + 16);
    for (size_t n = 0; n < N; ++n) x[n] = 0.3 * std::sin(2.0 * PI * 997.0 * n / 44100.0);
    const double* ip[1] = { x.data() };
    double* op[1] = { o.data() };
    const auto t0 = std::chrono::steady_clock::now();
    rs.process(ip, N, op);
    const auto t1 = std::chrono::steady_clock::now();
    *msOut = std::chrono::duration<double, std::milli>(t1 - t0).count();
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

    printf("=== 两段式升频验证（44.1 kHz -> 705.6 kHz）===\n");

    ResamplerConfig base;
    base.inRate = 44100; base.outRate = 705600; base.channels = 1;
    base.totalTaps = 32768; base.attenDb = 180.0; base.transition = 0.04;

    ResamplerConfig one = base; one.twoStage = false;
    ResamplerConfig two = base; two.twoStage = true;

    {
        PolyphaseResampler a(one), b(two);
        printf("  单级: L=%d T=%d   |   两段: engaged=%d, 第一级倍数=%d\n",
               a.upFactor(), a.tapsPerPhase(), (int)b.two_stage(), b.stage1_factor());
        check(!a.two_stage(), "单级路径没有误启用两段式");
        check(b.two_stage(), "两段式已启用");
        check(b.stage1_factor() == 4, "第一级倍数为 4", std::to_string(b.stage1_factor()));
    }

    // 1) 可听带幅度一致性
    printf("\n--- 1. 可听带幅度一致性（单级 vs 两段）---\n");
    {
        const double freqs[] = { 100.0, 1000.0, 10000.0, 19000.0 };
        for (double f : freqs) {
            const double r1 = tone_rms(one, f, 8192, 0.5);
            const double r2 = tone_rms(two, f, 8192, 0.5);
            const double db = 20.0 * std::log10((r2 + 1e-300) / (r1 + 1e-300));
            printf("  %6.0f Hz: 单级 %.8f  两段 %.8f  差 %+.5f dB\n", f, r1, r2, db);
            check(std::fabs(db) < 0.01, "幅度一致", std::to_string(f) + " Hz");
        }
    }

    // 2) 镜像抑制（15 kHz 单音 -> 29.1 kHz 镜像）
    printf("\n--- 2. 镜像抑制（15 kHz -> 镜像 29.1 kHz）---\n");
    {
        const double i1 = image_db(one, 15000.0, 29100.0, 16384);
        const double i2 = image_db(two, 15000.0, 29100.0, 16384);
        printf("  单级 %.1f dB   两段 %.1f dB\n", i1, i2);
        // Compare conservative amplitude upper bounds at the original image
        // frequency. Values below roundoff resolution are not reported as
        // physically distinguishable; the absolute -140 dB check remains strong.
        check(i1 < -140.0 && i2 < -140.0, "两路径真实镜像幅度上界优于 -140 dB");
        check(i1 < -60.0, "单级镜像幅度上界优于 -60 dB", std::to_string(i1));
        check(std::fabs(i2 - i1) < 3.0, "两段式镜像抑制与单级相当（差 < 3 dB）",
              std::to_string(i2 - i1) + " dB");
    }

    // 3) 分块不变性
    printf("\n--- 3. 分块不变性 ---\n");
    {
        const size_t N = 4096;
        std::vector<double> x(N);
        for (size_t n = 0; n < N; ++n) x[n] = 0.4 * std::sin(2.0 * PI * 997.0 * n / 44100.0);

        PolyphaseResampler whole(two);
        std::vector<double> ref(whole.maxOutFrames(N) + 16);
        { const double* ip[1] = { x.data() }; double* op[1] = { ref.data() }; whole.process(ip, N, op[0] ? op : op); }

        for (size_t chunk : { (size_t)777, (size_t)333, (size_t)1024 }) {
            PolyphaseResampler rs(two);
            std::vector<double> out;
            size_t pos = 0;
            while (pos < N) {
                const size_t n = std::min(chunk, N - pos);
                std::vector<double> o(rs.maxOutFrames(n) + 16);
                const double* ip[1] = { x.data() + pos };
                double* op[1] = { o.data() };
                const size_t got = rs.process(ip, n, op);
                out.insert(out.end(), o.begin(), o.begin() + (long long)got);
                pos += n;
            }
            size_t diff = 0;
            const size_t m = std::min(out.size(), ref.size());
            for (size_t i = 0; i < m; ++i) if (out[i] != ref[i]) ++diff;
            // 分块结束时滤波器里还压着 T 个样本的尾巴（整块调用才能一次吐出来），
            // 所以只比对公共前缀 —— 这才是"不变性"该问的问题。
            printf("  分块 %zu 帧: 输出 %zu / 参考 %zu（尾部差 %zu 属正常）, 不同点 %zu\n",
                   chunk, out.size(), ref.size(), ref.size() - out.size(), diff);
            check(diff == 0, "分块与整块的公共前缀逐位一致", std::to_string(chunk) + " 帧");
        }
    }

    // 4) 运算量
    printf("\n--- 4. CPU 时间（0.1 秒音频 -> 705.6 kHz，单声道）---\n");
    {
        double ms1 = 0.0, ms2 = 0.0;
        run_bench(false, &ms1);
        run_bench(true,  &ms2);
        const double speedup = ms1 / std::max(1e-9, ms2);
        printf("  单级 %.1f ms   两段 %.1f ms   加速 %.2fx\n", ms1, ms2, speedup);
        check(speedup > 1.5, "两段式明显更快", std::to_string(speedup) + "x");
    }

    printf("\n%s (失败项 %d)\n", fails == 0 ? "全部通过" : "存在失败", fails);
    return fails == 0 ? 0 : 1;
}
