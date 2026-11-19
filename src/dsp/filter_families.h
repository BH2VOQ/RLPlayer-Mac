// SPDX-FileCopyrightText: 2026 rainlain <https://github.com/okhuoyanyan>
// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// filter_families.h — 滤波器家族：窗函数、相位类型、预设表
//
// 滤波器家族的三个设计维度：
//   * 窗函数决定"家族性格"：Kaiser（poly-sinc 系）、Gaussian（gauss 系）、
//     Blackman-Harris（closed-form / sinc 系高衰减）、Hann（温和）
//   * 相位类型决定"时间行为"：线性相位（对称振铃，前后都有）vs
//     最小相位（无前振铃，能量集中在脉冲起始处）—— 即 -lp / -mp 后缀
//   * 抽头数与过渡带决定"陡峭度"：short / medium / long / xl / sinc-M（百万抽头）
//
// 最小相位实现采用**倒谱法（cepstral / homomorphic）**：
//   线性相位原型 H → 实倒谱 c[n] → 折叠（因果部分加倍、反因果置零）→ 指数还原 → IFFT
//   这是严格的最小相位分解，不是"把脉冲右移"之类的近似。
#pragma once
#include <atomic>
#include "apod_quality.h"
#include "fp_strict.h"   // 261030-01 审计：DSP 路径严格 IEEE（输出进入音频样本）
#include "kaiser.h"
#include "fft.h"
#include "phase_design_precision.h"
#include "filter_design.h"   // magnitude_db
#include <vector>
#include <cmath>
#include <string>
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <climits>
#include <limits>
#include <stdexcept>

namespace rta::dsp {

enum class WindowKind { Kaiser, Gaussian, BlackmanHarris, Hann };
// Linear = 线性相位（对称、有前振铃）；Minimum = 最小相位（能量靠前、无预振铃）；
// Intermediate = 混合相位：生产设计级联有限长 LP 与 MP 因子；相位非线性，延迟位于两端之间。
// 不能将两个相位不同的冲激响应直接相加：这会产生幅度相消。
enum class PhaseKind  { Linear, Minimum, Intermediate };

inline const char* window_name(WindowKind w) {
    switch (w) {
        case WindowKind::Kaiser:         return "kaiser";
        case WindowKind::Gaussian:       return "gauss";
        case WindowKind::BlackmanHarris: return "bharris";
        case WindowKind::Hann:           return "hann";
    }
    return "?";
}
inline const char* phase_name(PhaseKind p) {
    return p == PhaseKind::Linear ? "lp" : (p == PhaseKind::Minimum ? "mp" : "mix");
}

// 混合相位的默认比例：0 = 全最小相位，1 = 全线性相位
inline std::atomic<double>& phase_mix_ref() { static std::atomic<double> v{0.5}; return v; }
inline void set_phase_mix(double v) {
    if (!std::isfinite(v)) return;
    phase_mix_ref().store(std::clamp(v, 0.0, 1.0), std::memory_order_relaxed);
}
inline double phase_mix() { return phase_mix_ref().load(std::memory_order_relaxed); }

// ---------------- 窗函数 ----------------

inline std::vector<double> make_window(WindowKind kind, int n, double attenDb) {
    check_design_cancel();
    if (n < 0 || !std::isfinite(attenDb) || attenDb < 0.0 ||
        kind < WindowKind::Kaiser || kind > WindowKind::Hann)
        throw std::invalid_argument("Invalid FIR window size, attenuation or kind");
    std::vector<double> w((size_t)n, 1.0);
    if (n <= 1) return w;
    const double m = (double)(n - 1);
    switch (kind) {
        case WindowKind::Kaiser:
            return kaiser_window(n, kaiser_beta_for_attenuation(attenDb));

        case WindowKind::Gaussian: {
            // 高斯窗无旁瓣结构、单调滚降；alpha 越大衰减越深、过渡带越宽。
            const double alpha = 3.0 + 0.011 * std::max(0.0, attenDb - 60.0);
            for (int i = 0; i < n; ++i) {
                if ((i & 4095) == 0) check_design_cancel();
                const double r = (2.0 * i - m) / m;
                w[(size_t)i] = std::exp(-0.5 * (alpha * r) * (alpha * r));
            }
            return w;
        }
        case WindowKind::BlackmanHarris: {
            // 固定 4 项 Blackman-Harris 旁瓣峰值仅 -92 dB；attenDb > 100 时退到 Kaiser
            // （同 beta，参数化、可达任意深度），低衰减档保留原 BH 音色。
            if (attenDb > 100.0) return kaiser_window(n, kaiser_beta_for_attenuation(attenDb));
            for (int i = 0; i < n; ++i) {
                const double t = 2.0 * kPi * i / m;
                w[(size_t)i] = 0.35875 - 0.48829 * std::cos(t) + 0.14128 * std::cos(2 * t) - 0.01168 * std::cos(3 * t);
            }
            return w;
        }
        case WindowKind::Hann:
            for (int i = 0; i < n; ++i) w[(size_t)i] = 0.5 - 0.5 * std::cos(2.0 * kPi * i / m);
            return w;
    }
    return w;
}

// ---------------- 原型设计（线性相位）----------------
struct FirSpec {
    int        taps       = 4095;
    double     cutoff     = 0.5;      // 归一化：1.0 = Nyquist
    double     attenDb    = 180.0;
    WindowKind window     = WindowKind::Kaiser;
    bool       apodizing  = false;
    double     apodF1     = 0.0;      // 归一化滚降起点（1.0 = Nyquist）
    double     apodF2     = 0.0;      // 归一化滚降终点（1.0 = Nyquist）
};

inline std::vector<double> design_fir(const FirSpec& s) {
    check_design_cancel();
    // Respect the requested support: even-length Type-II lowpasses are legal.
    // Growing to N+1 then cropping a nonzero endpoint breaks DC and symmetry.
    int n = s.taps; if (n < 3) n = 3;
    const auto w = make_window(s.window, n, s.attenDb);
    const double m  = (double)(n - 1) * 0.5;
    std::vector<double> h((size_t)n);
    double sum = 0.0;
    if (!s.apodizing) {
        const double fc = s.cutoff * 0.5;
        for (int i = 0; i < n; ++i) {
            if ((i & 4095) == 0) check_design_cancel();
            const double x = (double)i - m;
            const double sc = (x == 0.0) ? 2.0 * fc : std::sin(2.0 * kPi * fc * x) / (kPi * x);
            h[(size_t)i] = sc * w[(size_t)i];
            sum += h[(size_t)i];
        }
    } else {
        // Apodizing 切趾：在通带高频加入平滑滚降（Raised-Cosine 频域过渡带），大幅压低 20 kHz 附近的预振铃
        double f1 = (s.apodF1 > 0.0) ? s.apodF1 : (s.cutoff * 0.85);
        double f2 = (s.apodF2 > 0.0) ? s.apodF2 : (s.cutoff * 1.05);
        if (f1 > f2) std::swap(f1, f2);
        const double fc = 0.5 * (f1 + f2) * 0.5;
        const double df = 0.5 * (f2 - f1) * 0.5;
        for (int i = 0; i < n; ++i) {
            if ((i & 4095) == 0) check_design_cancel();
            const double x = (double)i - m;
            const double sinc_val = (x == 0.0) ? 2.0 * fc : std::sin(2.0 * kPi * fc * x) / (kPi * x);
            const double denom = 1.0 - 16.0 * df * df * x * x;
            double factor;
            if (std::abs(denom) < 1e-7) {
                factor = kPi / 4.0;
            } else {
                factor = std::cos(2.0 * kPi * df * x) / denom;
            }
            h[(size_t)i] = sinc_val * factor * w[(size_t)i];
            sum += h[(size_t)i];
        }
    }
    if (sum != 0.0) for (auto& v : h) v /= sum;
    return h;
}

// ---------------- 最小相位变换（倒谱法）----------------
// 输入线性相位 FIR，输出同长度的最小相位 FIR（因果，能量集中在起始处）。
inline std::vector<double> to_minimum_phase(const std::vector<double>& h, size_t fftOversample = 8, bool enforceReal = false) {
    check_design_cancel();
    const size_t L = h.size();
    if (!fftOversample) throw std::invalid_argument("Minimum-phase FFT padding must be positive");
    if (!L) return {};
    const size_t maximum = std::vector<cplx>().max_size();
    if (L > maximum / fftOversample)
        throw std::length_error("Minimum-phase FFT target exceeds addressable storage");
    const size_t target = L * fftOversample;
    size_t N = 1;
    while (N < target) {
        if (N > maximum / 2)
            throw std::length_error("Minimum-phase FFT power-of-two exceeds addressable storage");
        N <<= 1;
    }

    std::vector<cplx> H(N, cplx(0.0, 0.0));
    for (size_t i = 0; i < L; ++i) H[i] = cplx(h[i], 0.0);
    fft(H);

    // 1) 对数幅度谱。地板必须取【相对峰值】的值而不是绝对值
    double peakMag = 0.0;
    for (size_t k = 0; k < N; ++k) peakMag = std::max(peakMag, std::abs(H[k]));
    const double floorMag = std::max(peakMag * 1e-15, 1e-300);
    for (size_t k = 0; k < N; ++k) {
        if ((k & 4095u) == 0) check_design_cancel();
        const double mag = std::max(std::abs(H[k]), floorMag);
        H[k] = cplx(std::log(mag), 0.0);
    }

    if (enforceReal) for (size_t k = 1; k < N / 2; ++k) H[N - k] = H[k];

    // 2) 实倒谱
    fft(H, /*inverse=*/true);

    // 3) 折叠：n=0 保留；1..N/2-1 加倍；N/2 保留；其余置零
    H[0] = enforceReal ? cplx(H[0].real(), 0.0) : H[0];
    for (size_t n = 1; n < N / 2; ++n) H[n] = enforceReal ? cplx(H[n].real() * 2.0, 0.0) : H[n] * 2.0;
    H[N / 2] = enforceReal ? cplx(H[N / 2].real(), 0.0) : H[N / 2];
    std::fill(H.begin() + N / 2 + 1, H.end(), cplx(0.0, 0.0));

    // 4) 指数还原 -> 最小相位频谱
    fft(H);
    for (size_t k = 0; k < H.size(); ++k) {
        if ((k & 4095u) == 0) check_design_cancel();
        H[k] = std::exp(H[k]);
    }

    // 5) 回到时域，取前 L 点（因果）
    fft(H, /*inverse=*/true);
    std::vector<double> out(L);
    for (size_t i = 0; i < L; ++i) out[i] = H[i].real();

    // 归一化到单位直流增益
    double sum = 0.0; for (auto v : out) sum += v;
    if (std::fabs(sum) > 1e-300) for (auto& v : out) v /= sum;
    return out;
}

// Legacy arbitrary-prototype utility: a delayed minimum-phase approximation.
inline std::vector<double> to_intermediate_phase(const std::vector<double>& h, double a = -1.0, size_t fftOversample = 8, bool enforceReal = false) {
    if (a < 0.0) a = phase_mix();
    if (a <= 0.0) return to_minimum_phase(h, fftOversample, enforceReal);
    if (a >= 1.0) return h;

    const size_t L = h.size();
    size_t N = 1; while (N < L * 8) N <<= 1;
    std::vector<double> hmin = to_minimum_phase(h, fftOversample, enforceReal);

    std::vector<cplx> B(N, cplx(0.0, 0.0));
    for (size_t i = 0; i < hmin.size() && i < L; ++i) B[i] = cplx(hmin[i], 0.0);
    fft(B);

    const double tau = a * (double)(L - 1) * 0.5;      // 分数延迟（样本）
    for (size_t k = 0; k < N; ++k) {
        const double df = (k <= N / 2) ? (double)k : (double)k - (double)N;
        const double w = -2.0 * kPi * df * tau / (double)N;
        B[k] *= std::polar(1.0, w);
    }
    fft(B, /*inverse=*/true);

    std::vector<double> out(L);
    for (size_t i = 0; i < L; ++i) out[i] = B[i].real();
    double sum = 0.0; for (auto v : out) sum += v;
    if (std::fabs(sum) > 1e-300) for (auto& v : out) v /= sum;
    return out;
}

// ---------------- Finite-support phase-factor cascade ----------------
inline std::vector<double> fft_convolve(const std::vector<double>& a, const std::vector<double>& b) {
    return phase_detail::convolve(a, b);
}

inline int phase_cascade_stages(PhaseKind) { return 2; }

inline double phase_cascade_cutoff_boost(PhaseKind p, int taps, double attenDb) {
    const double dfNorm = 2.0 * (attenDb - 7.95) / (14.36 * (double)taps);
    const double k = (p == PhaseKind::Minimum) ? 0.15 : 0.22;
    return k * dfNorm;
}

inline std::vector<double> design_phased_fir(int taps, double cutoff, double attenDb,
                                             WindowKind window, bool apodizing,
                                             double apodF1, double apodF2,
                                             PhaseKind phase, double mix,
                                             double passEdge = 0.0) {
    if (taps < 3) taps = 3;
    if (phase == PhaseKind::Linear) {
        FirSpec s; s.taps = taps; s.cutoff = cutoff; s.attenDb = attenDb; s.window = window;
        s.apodizing = apodizing; s.apodF1 = apodF1; s.apodF2 = apodF2;
        return design_fir(s);
    }
    // A phase conversion must preserve the prototype magnitude. Redesigning two
    // half-order / half-attenuation factors is only needed beyond the reliable
    // single-factor precision range; at ordinary attenuation it moves the
    // transition and changes measurable sidelobes (e.g. short-mp by 1.27 dB).
    if (phase == PhaseKind::Minimum && attenDb < 250.0) {
        FirSpec s; s.taps = taps; s.cutoff = cutoff; s.attenDb = attenDb; s.window = window;
        s.apodizing = apodizing; s.apodF1 = apodF1; s.apodF2 = apodF2;
        // 32x cepstral padding is only affordable on short prototypes: a single
        // 8k-tap factor turns it into a multi-million-point FFT (measured 17 s of
        // prepare time at 44.1k->384k). Long single-stage factors keep the 8x
        // padding the previous implementation used, which still lands the passband
        // within the same tolerance the regression asserts.
        const size_t mpPad = (taps > 4096) ? 8 : 32;
        return to_minimum_phase(design_fir(s), mpPad, true);
    }
    int stages = phase_cascade_stages(phase);
    int sub = 2 * ((taps - 1) / (2 * stages)) + 1;
    if (taps < 5 || (taps < 2048 && attenDb < 250.0)) { stages = 1; sub = taps; }
    double boost = (stages == 1) ? 0.0 : phase_cascade_cutoff_boost(PhaseKind::Minimum, sub, attenDb / (double)stages);
    if (sub < 3) sub = 3;
    auto build = [&](double b) {
        FirSpec s; s.taps = sub; s.cutoff = cutoff + b;
        s.attenDb = attenDb / (double)stages;
        s.window = window; s.apodizing = apodizing; s.apodF1 = apodF1; s.apodF2 = apodF2;
        const bool improvedCepstrum = stages > 1;
        const size_t padding = improvedCepstrum ? ((window == WindowKind::Gaussian) ? 64 : 32) : 8;
        if (phase == PhaseKind::Intermediate && stages > 1 && mix > 0.0 && mix < 1.0) {
            const int order = 2 * ((taps - 1) / 2);
            int lpOrder = 2 * (int)std::round(mix * order * 0.5);
            lpOrder = std::clamp(lpOrder, 2, order - 2);
            FirSpec lpSpec = s, mpSpec = s;
            lpSpec.taps = lpOrder + 1; mpSpec.taps = order - lpOrder + 1;
            lpSpec.attenDb = attenDb * (double)lpOrder / order;
            mpSpec.attenDb = attenDb - lpSpec.attenDb;
            auto lp = design_fir(lpSpec);
            auto mp = to_minimum_phase(design_fir(mpSpec), padding, true);
            return fft_convolve(lp, mp);
        }
        auto one = design_fir(s);
        if (phase == PhaseKind::Minimum || mix <= 0.0) one = to_minimum_phase(one, padding, improvedCepstrum);
        else if (mix < 1.0) one = to_intermediate_phase(one, mix, padding, improvedCepstrum);
        std::vector<double> a = one;
        for (int k = 1; k < stages; ++k) a = fft_convolve(a, one);
        return a;
    };
    std::vector<double> acc = build(boost);
    if (passEdge > 0.0 && passEdge < 0.5) {
        const double dfNorm = 2.0 * (attenDb - 7.95) / (14.36 * (double)sub);
        auto worstAt = [&](const std::vector<double>& h) {
            double w = 0.0;
            for (int k = 0; k <= 64; ++k) {
                const double v = magnitude_db(h, passEdge * (double)k / 64.0);
                if (std::fabs(v) > std::fabs(w)) w = v;
            }
            return w;
        };
        // Evaluate the band-edge error on the filter that actually ships. Rebuilding
        // inside every secant step repeats the full 32x minimum-phase transform
        // (seconds for 8k+ taps) for a cutoff tweak that does not change the phase.
        // Perturbing the already-built prototype keeps the search meaningful and bounded.
        const size_t nPert = acc.size();
        auto perturbed = [&](double d) {
            std::vector<double> h = acc;
            if (nPert < 2 || !(d > 0.0)) return h;
            const double df = 2.0 * (attenDb - 7.95) / (14.36 * std::max(3, sub));
            const double tau = d / (df > 0.0 ? df : 1.0) * (double)sub;
            for (size_t i = 0; i < nPert; ++i) {
                const double x = (double)i - (double)(nPert - 1) * 0.5 - tau;
                const double s = (x == 0.0) ? 1.0 : std::sin(kPi * x * std::max(1e-12, d)) / (kPi * x);
                h[i] *= s;
            }
            return h;
        };
        auto errAt = [&](double d) { return worstAt(perturbed(d)); };
        double d0 = boost;
        double e0 = worstAt(acc);
        double bestE = e0;
        std::vector<double> bestAcc = acc;
        if (std::fabs(e0) > 0.002) {
            double d1 = boost + dfNorm * 0.02;
            double e1 = errAt(d1);
            for (int it = 0; it < 5; ++it) {
                if (std::fabs(e1) < std::fabs(bestE)) { bestE = e1; bestAcc = perturbed(d1); }
                if (std::fabs(e1) < 0.002) break;
                const double den = e1 - e0;
                double d2 = (std::fabs(den) < 1e-12) ? (d1 + dfNorm * 0.02)
                                                     : (d1 - e1 * (d1 - d0) / den);
                if (d2 < 0.0) d2 = 0.0;
                if (d2 > dfNorm) d2 = dfNorm;
                if (std::fabs(d2 - d1) < 1e-9) break;
                d0 = d1; e0 = e1; d1 = d2;
                e1 = errAt(d1);
            }
            acc = bestAcc;
        }
    }
    double sum = 0.0; for (auto v : acc) sum += v;
    if (std::fabs(sum) > 1e-300) for (auto& v : acc) v /= sum;
    if ((int)acc.size() > taps) acc.resize((size_t)taps);
    else if ((int)acc.size() < taps) acc.resize((size_t)taps, 0.0);
    return acc;
}

// ---------------- 预设表（家族命名与变体，对齐 Windows v3.3.11 共 79 项）----------------
struct FilterPreset {
    const char* name;
    int         taps;        // 抽头数（对应 -short/-medium/-long/-xl/sinc-M 等）
    double      transition;  // 过渡带占比（相对理想截止）
    double      attenDb;
    WindowKind  window;
    PhaseKind   phase;
    bool        forNx       = false; // true = 用于 Nx（高码率）路径
    bool        twoStage    = false; // true = 两段式升频（*-2s）
    int         stage2Taps  = 64;    // 第二级每相位抽头数
    bool        apodizing   = false; // true = 切趾（通带高频平滑渐进衰减）
    double      apodF1      = 0.0;   // 滚降起始相对输入 Nyquist 比例（例如 18.4k / 22.05k）
    double      apodF2      = 0.0;   // 滚降终止相对输入 Nyquist 比例（例如 21.8k / 22.05k）
    int         tapsPerInput = 0;
};

// 预设抽头数量级：short≈4k, medium≈32k, long≈256k, xl≈1M, sinc-M≈1M, 16M≈16M
inline const std::vector<FilterPreset>& filter_presets() {
    static const std::vector<FilterPreset> p = {
        // ---- 1. 经典 poly-sinc 家族（Kaiser 窗）----
        { "poly-sinc-short-lp",        4095,    0.10,  120, WindowKind::Kaiser,         PhaseKind::Linear,       false, false, 64 },
        { "poly-sinc-short-mp",        4095,    0.10,  120, WindowKind::Kaiser,         PhaseKind::Minimum,      false, false, 64 },
        { "poly-sinc-short-2s",        4095,    0.10,  120, WindowKind::Kaiser,         PhaseKind::Linear,       true,  true,  64 },
        { "poly-sinc-lp",             32767,    0.04,  180, WindowKind::Kaiser,         PhaseKind::Linear,       false, false, 64 },
        { "poly-sinc-mp",             32767,    0.04,  180, WindowKind::Kaiser,         PhaseKind::Minimum,      false, false, 64 },
        { "poly-sinc-2s",             32767,    0.04,  180, WindowKind::Kaiser,         PhaseKind::Linear,       true,  true,  64 },
        { "poly-sinc-mp-2s",          32767,    0.04,  180, WindowKind::Kaiser,         PhaseKind::Minimum,      true,  true,  64 },
        { "poly-sinc-long-lp",       262143,    0.015, 200, WindowKind::Kaiser,         PhaseKind::Linear,       true,  false, 64 },
        { "poly-sinc-long-mp",       262143,    0.015, 200, WindowKind::Kaiser,         PhaseKind::Minimum,      true,  false, 64 },
        { "poly-sinc-long-ip",       262143,    0.015, 200, WindowKind::Kaiser,         PhaseKind::Intermediate, true,  false, 64 },
        { "poly-sinc-long-2s",       262143,    0.015, 200, WindowKind::Kaiser,         PhaseKind::Linear,       true,  true,  64 },
        { "poly-sinc-xl",           1048575,    0.008, 230, WindowKind::Kaiser,         PhaseKind::Linear,       true,  false, 64 },
        { "poly-sinc-xla",          1048575,    0.010, 220, WindowKind::Kaiser,         PhaseKind::Linear,       true,  false, 64 },
        { "poly-sinc-xtr",          1048575,    0.008, 230, WindowKind::Kaiser,         PhaseKind::Linear,       true,  false, 64 },

        // ---- 补齐其余家族变体（27 项，对齐 Windows v3.3.11）----
        { "poly-sinc-ext2-short",      32767,  0.06,  180, WindowKind::BlackmanHarris, PhaseKind::Linear,       false, false, 64, false, 0.0,  0.0,  0 },
        { "poly-sinc-ext2-medium",    131071,  0.03,  200, WindowKind::BlackmanHarris, PhaseKind::Linear,       false, false, 64, false, 0.0,  0.0,  0 },
        { "poly-sinc-ext2-long",      524287,  0.015, 220, WindowKind::BlackmanHarris, PhaseKind::Linear,       true,  false, 64, false, 0.0,  0.0,  0 },
        { "poly-sinc-ext2-hires-lp",   32767,  0.08,  160, WindowKind::BlackmanHarris, PhaseKind::Linear,       false, false, 64, false, 0.0,  0.0,  0 },
        { "poly-sinc-ext2-hires-ip",   32767,  0.08,  160, WindowKind::BlackmanHarris, PhaseKind::Intermediate, false, false, 64, false, 0.0,  0.0,  0 },
        { "poly-sinc-ext2-hires-mp",   32767,  0.08,  160, WindowKind::BlackmanHarris, PhaseKind::Minimum,      false, false, 64, false, 0.0,  0.0,  0 },
        { "poly-sinc-xtr-lp",         524287,  0.008, 230, WindowKind::Kaiser,         PhaseKind::Linear,       true,  false, 64, false, 0.0,  0.0,  0 },
        { "poly-sinc-xtr-mp",         262143,  0.05,  220, WindowKind::Kaiser,         PhaseKind::Minimum,      true,  false, 64, false, 0.0,  0.0,  0 },
        { "poly-sinc-xtr-short-lp",    16383,  0.10,  140, WindowKind::Kaiser,         PhaseKind::Linear,       false, false, 64, false, 0.0,  0.0,  0 },
        { "poly-sinc-xtr-short-mp",    16383,  0.10,  140, WindowKind::Kaiser,         PhaseKind::Minimum,      false, false, 64, false, 0.0,  0.0,  0 },
        { "poly-sinc-gauss-medium",    16383,  0.08,  150, WindowKind::Gaussian,       PhaseKind::Linear,       false, false, 64, false, 0.0,  0.0,  0 },
        { "poly-sinc-gauss-halfband",   8191,  0.10,  120, WindowKind::Gaussian,       PhaseKind::Linear,       false, false, 64, true,  18400.0 / 22050.0, 21800.0 / 22050.0, 0 },
        { "poly-sinc-gauss-halfband-s", 4095,  0.10,  120, WindowKind::Gaussian,       PhaseKind::Linear,       false, false, 64, true,  17800.0 / 22050.0, 21700.0 / 22050.0, 0 },
        { "poly-sinc-hb-xs",            2047,  0.16,  100, WindowKind::Kaiser,         PhaseKind::Linear,       false, false, 64, false, 0.0,  0.0,  0 },
        { "poly-sinc-ext",             65535,  0.025, 190, WindowKind::Kaiser,         PhaseKind::Linear,       false, false, 64, false, 0.0,  0.0,  0 },
        { "poly-sinc-mqa/mp3-lp",       8191,  0.14,  110, WindowKind::Kaiser,         PhaseKind::Linear,       false, false, 64, false, 0.0,  0.0,  0 },
        { "poly-sinc-mqa/mp3-mp",       8191,  0.14,  110, WindowKind::Kaiser,         PhaseKind::Minimum,      false, false, 64, false, 0.0,  0.0,  0 },
        { "sinc-short",                 8191,  0.10,  150, WindowKind::BlackmanHarris, PhaseKind::Linear,       false, false, 64, false, 0.0,  0.0,  0 },
        { "sinc-medium",               32767,  0.05,  180, WindowKind::BlackmanHarris, PhaseKind::Linear,       false, false, 64, false, 0.0,  0.0,  0 },
        { "sinc-long",                131071,  0.02,  210, WindowKind::BlackmanHarris, PhaseKind::Linear,       true,  false, 64, false, 0.0,  0.0,  0 },
        { "sinc-long-h",              131071,  0.10,  210, WindowKind::BlackmanHarris, PhaseKind::Linear,       true,  false, 64, true,  18400.0 / 22050.0, 21800.0 / 22050.0, 0 },
        { "sinc-Mx",                  524287,  0.012, 220, WindowKind::BlackmanHarris, PhaseKind::Linear,       true,  false, 64, false, 0.0,  0.0,  0 },
        { "sinc-MGa",                 524287,  0.015, 215, WindowKind::Gaussian,       PhaseKind::Linear,       true,  false, 64, false, 0.0,  0.0,  0 },
        { "sinc-Ls",                  262143,  0.03,  200, WindowKind::BlackmanHarris, PhaseKind::Linear,       true,  false, 64, false, 0.0,  0.0,  0 },
        { "sinc-Lm",                  262143,  0.03,  200, WindowKind::BlackmanHarris, PhaseKind::Minimum,      true,  false, 64, false, 0.0,  0.0,  0 },
        { "sinc-Lh",                  262143,  0.10,  200, WindowKind::BlackmanHarris, PhaseKind::Linear,       true,  false, 64, true,  18000.0 / 22050.0, 21400.0 / 22050.0, 0 },
        { "minringFIR-lp",              4095,  0.12,  120, WindowKind::Kaiser,         PhaseKind::Linear,       false, false, 64, false, 0.0,  0.0,  0 },

        // ---- 2. 高斯高分辨率与变体（poly-sinc-gauss 家族，高斯窗）----
        { "poly-sinc-gauss-short",     4095,    0.12,  120, WindowKind::Gaussian,       PhaseKind::Linear,       false, false, 64 },
        { "poly-sinc-gauss-long",     32767,    0.05,  180, WindowKind::Gaussian,       PhaseKind::Linear,       false, false, 64 },
        { "poly-sinc-gauss-mp",       32767,    0.05,  180, WindowKind::Gaussian,       PhaseKind::Minimum,      false, false, 64 },
        { "poly-sinc-gauss-2s",       32767,    0.05,  180, WindowKind::Gaussian,       PhaseKind::Linear,       true,  true,  64 },
        { "poly-sinc-gauss-long-2s",  65535,    0.035, 200, WindowKind::Gaussian,       PhaseKind::Linear,       true,  true,  64 },
        { "poly-sinc-gauss-hires-lp", 65535,    0.035, 200, WindowKind::Gaussian,       PhaseKind::Linear,       true,  false, 64 },
        { "poly-sinc-gauss-hires-mp", 65535,    0.035, 200, WindowKind::Gaussian,       PhaseKind::Minimum,      true,  false, 64 },
        { "poly-sinc-gauss-hires-ip", 65535,    0.035, 200, WindowKind::Gaussian,       PhaseKind::Intermediate, true,  false, 64 },
        { "poly-sinc-gauss-xl",      524287,    0.025, 210, WindowKind::Gaussian,       PhaseKind::Linear,       true,  false, 64 },
        { "poly-sinc-gauss-xla",     524287,    0.030, 200, WindowKind::Gaussian,       PhaseKind::Linear,       true,  false, 64 },

        // ---- 3. ext2 扩展频响变体（Blackman-Harris 窗）----
        { "poly-sinc-ext2",           65535,    0.03,  200, WindowKind::BlackmanHarris, PhaseKind::Linear,       false, false, 64 },
        { "poly-sinc-ext2-2s",        65535,    0.03,  200, WindowKind::BlackmanHarris, PhaseKind::Linear,       true,  true,  64 },
        { "poly-sinc-ext2-xl",       524287,    0.015, 230, WindowKind::BlackmanHarris, PhaseKind::Linear,       true,  false, 64 },
        { "poly-sinc-ext2-xla",      524287,    0.018, 220, WindowKind::BlackmanHarris, PhaseKind::Linear,       true,  false, 64 },

        // ---- 4. 半带（half-band）家族及 hb-*-2s 两段式 ----
        { "poly-sinc-hb",              1023,    0.20,  100, WindowKind::Kaiser,         PhaseKind::Linear,       false, false, 64 },
        { "poly-sinc-hb-s",             511,    0.25,   95, WindowKind::Kaiser,         PhaseKind::Linear,       false, false, 64 },
        { "poly-sinc-hb-m",            2047,    0.15,  115, WindowKind::Kaiser,         PhaseKind::Linear,       false, false, 64 },
        { "poly-sinc-hb-l",            4095,    0.10,  130, WindowKind::Kaiser,         PhaseKind::Linear,       false, false, 64 },
        { "poly-sinc-hb-2s",           2047,    0.16,  110, WindowKind::Kaiser,         PhaseKind::Linear,       true,  true,  64 },
        { "poly-sinc-hb-s-2s",         1023,    0.22,  100, WindowKind::Kaiser,         PhaseKind::Linear,       true,  true,  64 },
        { "poly-sinc-hb-m-2s",         4095,    0.14,  120, WindowKind::Kaiser,         PhaseKind::Linear,       true,  true,  64 },
        { "poly-sinc-hb-l-2s",         8191,    0.08,  135, WindowKind::Kaiser,         PhaseKind::Linear,       true,  true,  64 },

        // ---- 5. sinc 恒定时间与超长系列（sinc-{S,M,MG,L,LL}）----
        { "sinc-S",                   65535,    0.025, 200, WindowKind::Kaiser,         PhaseKind::Linear,       false, false, 64 },
        { "sinc-M",                  524287,    0.010, 220, WindowKind::Kaiser,         PhaseKind::Linear,       true,  false, 64 },
        { "sinc-MG",                 524287,    0.020, 210, WindowKind::Gaussian,       PhaseKind::Linear,       true,  false, 64 },
        { "sinc-L",                 1048575,    0.006, 160, WindowKind::Kaiser,         PhaseKind::Linear,       true,  false, 64 },
        { "sinc-LL",                2097151,    0.004, 190, WindowKind::Kaiser,         PhaseKind::Linear,       true,  false, 64 },

        // ---- 6. 闭式插值家族（closed-form-{fast,base,M,16M}）----
        { "closed-form-fast",          4095,    0.10,  144, WindowKind::BlackmanHarris, PhaseKind::Linear,       false, false, 64 },
        { "closed-form",              16383,    0.06,  150, WindowKind::BlackmanHarris, PhaseKind::Linear,       false, false, 64 },
        { "closed-form-M",          1048575,    0.008, 200, WindowKind::BlackmanHarris, PhaseKind::Linear,       true,  false, 64 },
        { "closed-form-16M",       16777215,    0.003, 240, WindowKind::BlackmanHarris, PhaseKind::Linear,       true,  false, 64 },

        // ---- 7. 最小振铃特殊类型 ----
        { "minringFIR",                 511,    0.28,   90, WindowKind::BlackmanHarris, PhaseKind::Linear,       false, false, 64 },
        { "minringFIR-mp",              511,    0.28,   90, WindowKind::BlackmanHarris, PhaseKind::Minimum,      false, false, 64 },

        // ---- 8. 切趾（Apodizing）家族（通带渐进平滑滚降，压低 20 kHz 预振铃与 MQA/有损编码失真）----
        { "apod-20k",                  4095,    0.10,  120, WindowKind::Kaiser,         PhaseKind::Linear,       false, false, 64, true, 18400.0 / 22050.0, 21800.0 / 22050.0 },
        { "apod-19k-short",            4095,    0.10,  120, WindowKind::Kaiser,         PhaseKind::Linear,       false, false, 64, true, 18000.0 / 22050.0, 21400.0 / 22050.0 },
        { "apod-wide",                 4095,    0.10,  120, WindowKind::Kaiser,         PhaseKind::Linear,       false, false, 64, true, 17800.0 / 22050.0, 21700.0 / 22050.0 },

        // ---- 9. 「内核长度」家族（tapsPerInput）：抽头预算与输出采样率解耦 ----
        { "poly-sinc-tight-lp",       32767,    0.020, 140, WindowKind::Kaiser, PhaseKind::Linear, false, false, 64, false, 0.0, 0.0, 1600 },
        { "apod-20k-tight",           32767,    0.100, 140, WindowKind::Kaiser, PhaseKind::Linear, false, false, 64, true, 18400.0 / 22050.0, 21800.0 / 22050.0, 512 },
    };
    return p;
}

// ---------------- 规格 v2.1：可感知参数与排除规则 ----------------
struct PresetMetrics {
    double passHz    = 0.0;   // 通带边缘（Hz）
    double dfHz      = 0.0;   // 物理允许的过渡带（Hz）
    int    T         = 0;     // 每相抽头（按家族天花板反解）
    double ringMs    = 0.0;   // Legacy length estimate; never a measured ringing certificate
    double ceilingDb = 0.0;   // 家族天花板
    bool   excluded  = false; // 对给定内容边缘是否应排除（D-15 判据 1）
};

inline double preset_ceiling_db(WindowKind w) {
    return (w == WindowKind::Gaussian) ? 100.0 : 280.0;
}

inline PresetMetrics preset_metrics(const FilterPreset& fp, double fsIn, double contentHz, double tolHz = 1000.0) {
    if (!std::isfinite(fsIn) || fsIn <= 0.0 || fsIn > double(UINT32_MAX) ||
        !std::isfinite(contentHz) || contentHz < 0.0 ||
        !std::isfinite(tolHz) || tolHz < 0.0 ||
        !std::isfinite(fp.transition) || fp.transition < 0.0 || fp.transition >= 1.0 ||
        !std::isfinite(fp.attenDb) || fp.attenDb < 0.0 ||
        fp.taps < 0 || fp.tapsPerInput < 0 ||
        fp.window < WindowKind::Kaiser || fp.window > WindowKind::Hann ||
        (fp.apodizing && (!std::isfinite(fp.apodF1) || !std::isfinite(fp.apodF2) ||
                          fp.apodF1 <= 0.0 || fp.apodF2 <= fp.apodF1 || fp.apodF2 > 1.0)))
        throw std::invalid_argument("Invalid filter metrics rate, bandwidth or preset parameters");
    PresetMetrics m;
    m.ceilingDb = preset_ceiling_db(fp.window);
    const double half = fsIn * 0.5;
    if (fp.apodizing && fp.apodF1 > 0.0) {
        m.passHz = fp.apodF1 * half;
        m.dfHz   = (fp.apodF2 > fp.apodF1 ? (fp.apodF2 - fp.apodF1) : 0.02) * half;
    } else {
        m.passHz = (1.0 - fp.transition) * half;
        m.dfHz   = fsIn - 2.0 * m.passHz;
    }
    if (m.dfHz < 1.0) m.dfHz = 1.0;
    if (fp.window == WindowKind::Gaussian) {
        m.T = (fp.tapsPerInput > 0) ? fp.tapsPerInput : (int)(fp.taps / 16);
    } else {
        const double requestedT = 21.13 * fsIn / m.dfHz + 0.5;
        if (!std::isfinite(requestedT) || requestedT > double(INT_MAX))
            throw std::length_error("Filter metrics tap count exceeds supported range");
        m.T = (int)requestedT;
        if (m.dfHz < 500.0 && m.T < 2877) m.T = 2877;
    }
    if (m.T < 8) m.T = 8;
    if (fp.apodizing)
        m.T = apod_quality_taps(fp.apodF1, fp.apodF2, fp.window == WindowKind::Gaussian,
                               std::max(fp.attenDb, m.ceilingDb), m.T);
    double tActual = (double)m.T;
    if (fp.tapsPerInput > 0) {
        tActual = (double)fp.tapsPerInput;
    } else if (fp.taps > 0) {
        const double tByLen = (double)fp.taps / 16.0;
        const double tCap   = 2.0 * (double)m.T;
        tActual = (tByLen < tCap) ? tByLen : tCap;
    }
    m.ringMs = (fp.phase == PhaseKind::Minimum) ? 0.0
                                               : 0.42 * (tActual * 0.5) / fsIn * 1000.0;
    m.excluded = (!fp.apodizing) && (m.passHz < contentHz - tolHz);
    return m;
}

inline const char* auto_preset_name() { return "poly-sinc-short-lp"; }
inline bool is_auto_preset(const std::string& n) { return n.empty() || n == "auto"; }

inline double content_hz_for_rate(uint32_t fs) {
    if (fs <= 48000u) return 20000.0;      // 44.1 / 48
    if (fs <= 96000u) return 40000.0;      // 88.2 / 96
    return 80000.0;                        // 176.4 / 192
}

inline int solve_taps_per_phase(WindowKind w, double transition, bool apodizing,
                                double apodF1, double apodF2, int taps,
                                int tapsPerInput, double fsIn) {
    if (!std::isfinite(fsIn) || fsIn <= 0.0 || fsIn > double(UINT32_MAX))
        throw std::invalid_argument("Filter source rate must be finite and representable");
    if (tapsPerInput > 0 && !apodizing) return tapsPerInput;
    FilterPreset fp{};
    fp.name = "auto"; fp.taps = taps; fp.transition = transition;
    fp.tapsPerInput = tapsPerInput;
    fp.attenDb = (w == WindowKind::Gaussian) ? 120.0 : 280.0;
    fp.window = w; fp.apodizing = apodizing; fp.apodF1 = apodF1; fp.apodF2 = apodF2;
    return preset_metrics(fp, fsIn, content_hz_for_rate((uint32_t)(fsIn + 0.5))).T;
}

// 按名字查找预设（优先匹配当前路径 Nx/1x）
inline const FilterPreset* find_preset(const std::string& name, bool nxPath = false) {
    const auto& all = filter_presets();
    const FilterPreset* best = nullptr;
    int bestScore = -1;
    for (const auto& p : all) {
        if (name != p.name) continue;
        const int score = (p.forNx == nxPath) ? 2 : 1;
        if (score > bestScore) { bestScore = score; best = &p; }
    }
    return best;
}

// 按名字查找并生成系数
inline std::vector<double> make_filter(const std::string& name, bool nxPath, int* tapsOut = nullptr) {
    const FilterPreset* best = find_preset(name, nxPath);
    if (!best) return {};
    const double cutoff = 0.5 * (1.0 - best->transition);
    FirSpec s;
    const double designAtten = best->attenDb;
    s.taps = best->taps; s.cutoff = cutoff; s.attenDb = designAtten; s.window = best->window;
    s.apodizing = best->apodizing;
    if (best->apodizing) {
        s.apodF1 = best->apodF1 * 0.5;
        s.apodF2 = best->apodF2 * 0.5;
    }
    auto h = design_phased_fir(best->taps, cutoff, designAtten, best->window,
                               best->apodizing,
                               best->apodizing ? s.apodF1 : 0.0,
                               best->apodizing ? s.apodF2 : 0.0,
                               best->phase, phase_mix());
    if (tapsOut) *tapsOut = (int)h.size();
    return h;
}

namespace detail { inline size_t argmax_abs(const std::vector<double>& h) {
    size_t peak = 0; double best = -1.0;
    for (size_t i = 0; i < h.size(); ++i) { const double a = std::fabs(h[i]); if (a > best) { best = a; peak = i; } }
    return peak; } }

// 前振铃 / 后振铃 能量比（以脉冲响应峰值样本为分界）。
//   线性相位（对称）⟹ 前 = 后 ⟹ 比值 ≈ 1.0
//   最小相位       ⟹ 前 ≪ 后 ⟹ 比值 ≪ 1.0
// 注意：不要用「峰值前能量 / 总能量」判定对称性——峰值样本自身往往占近半能量，
// 对称滤波器该比值天然只有 ~0.25，极易误判。
inline double pre_post_ratio(const std::vector<double>& h) {
    const size_t peak = detail::argmax_abs(h);
    double pre = 0.0, post = 0.0;
    for (size_t i = 0; i < h.size(); ++i) {
        const double e = h[i] * h[i];
        if (i < peak) pre += e; else if (i > peak) post += e;
    }
    return post > 0.0 ? pre / post : 0.0;
}

// 峰值样本在脉冲响应中的相对位置（0 = 起始，1 = 末尾）
inline double peak_position(const std::vector<double>& h) {
    if (h.size() < 2) return 0.0;
    return (double)detail::argmax_abs(h) / (double)(h.size() - 1);
}

// 群延迟估计（样本数）：能量的重心
inline double energy_centroid(const std::vector<double>& h) {
    double num = 0.0, den = 0.0;
    for (size_t i = 0; i < h.size(); ++i) { const double e = h[i] * h[i]; num += e * (double)i; den += e; }
    return den > 0.0 ? num / den : 0.0;
}

} // namespace rta::dsp
