// SPDX-FileCopyrightText: 2026 rainlain <https://github.com/okhuoyanyan>
// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// resampler_simd.h — 严格 IEEE-754 double 的 ARM64 NEON 多相卷积内核
//
// 数学与位一致性约定：
//  * 所有内核都在局部 `#pragma clang fp reassociate(off) contract(off) reciprocal(off)`
//    + `noinline` 作用域内使用 clang 原生向量 `Vec2d` 运算（禁用 FMA 收缩与加法重排），
//    确保与标量 `acc += ph[u] * hh[base - u]` 按位一致。
//  * resampler_phase_group<Groups>:   M==1 且连续 2*Groups 个相位在同一 base 处并行计算。
//  * resampler_temporal_group<Groups>: 同相位每隔 L 输出（输入跨步 M），跨时间并行计算 2*Groups 个输出。
//  * resampler_m1_interleaved8<LVal>:  M==1 且 L<=4（如 96k->192k L=2、48k->192k L=4），
//    每个 tap 仅加载一次 8 个连续历史样本并同时复用给全部 L 个相位，显著减少加载与循环开销。
#pragma once
#include "fp_strict.h"
#include <cstddef>

#if !defined(RTA_RESAMPLER_DISABLE_SIMD) && defined(__clang__) && \
    (defined(__aarch64__) || defined(__arm64__))
#  define RTA_RESAMPLER_NEON 1
#  define RTA_RESAMPLER_SIMD 1
#else
#  define RTA_RESAMPLER_NEON 0
#  define RTA_RESAMPLER_SIMD 0
#endif

namespace rta::dsp {

enum class ResamplerCpuKernel { Auto, Scalar, Simd, Avx2 = Simd, Neon = Simd };

inline bool resampler_simd_available() {
#if RTA_RESAMPLER_SIMD
    return true;
#else
    return false;
#endif
}

inline bool resampler_neon_available() {
#if RTA_RESAMPLER_NEON
    return true;
#else
    return false;
#endif
}

inline bool resampler_avx2_available() {
    return false;
}

#if RTA_RESAMPLER_NEON

namespace detail {
using Vec2d = double __attribute__((vector_size(16)));
using Vec2dU = double __attribute__((vector_size(16), aligned(1)));
} // namespace detail

// 连续 2*Groups 个相位共享同一输入样本历史位置 base，逐 tap 独立累加，不做跨通道归约。
template <int Groups>
__attribute__((noinline))
inline void resampler_phase_group(const double* coeff, size_t stride,
                                  const double* history, size_t base,
                                  int taps, double* out) {
#pragma clang fp reassociate(off) contract(off) reciprocal(off)
    static_assert(Groups == 1 || Groups == 2 || Groups == 4 || Groups == 8);
    using detail::Vec2d;
    using detail::Vec2dU;
    Vec2d a0 = {0.0, 0.0};
    Vec2d a1 = a0, a2 = a0, a3 = a0, a4 = a0, a5 = a0, a6 = a0, a7 = a0;
    for (int u = 0; u < taps; ++u) {
        const double hScalar = history[base - (size_t)u];
        const Vec2d h = {hScalar, hScalar};
        const double* row = coeff + (size_t)u * stride;
        a0 = a0 + (*(const Vec2dU*)(row)) * h;
        if constexpr (Groups >= 2) a1 = a1 + (*(const Vec2dU*)(row + 2)) * h;
        if constexpr (Groups >= 4) {
            a2 = a2 + (*(const Vec2dU*)(row + 4)) * h;
            a3 = a3 + (*(const Vec2dU*)(row + 6)) * h;
        }
        if constexpr (Groups >= 8) {
            a4 = a4 + (*(const Vec2dU*)(row + 8)) * h;
            a5 = a5 + (*(const Vec2dU*)(row + 10)) * h;
            a6 = a6 + (*(const Vec2dU*)(row + 12)) * h;
            a7 = a7 + (*(const Vec2dU*)(row + 14)) * h;
        }
    }
    *(Vec2dU*)(out) = a0;
    if constexpr (Groups >= 2) *(Vec2dU*)(out + 2) = a1;
    if constexpr (Groups >= 4) {
        *(Vec2dU*)(out + 4) = a2;
        *(Vec2dU*)(out + 6) = a3;
    }
    if constexpr (Groups >= 8) {
        *(Vec2dU*)(out + 8) = a4;
        *(Vec2dU*)(out + 10) = a5;
        *(Vec2dU*)(out + 12) = a6;
        *(Vec2dU*)(out + 14) = a7;
    }
}

// 同一相位 p 每隔 outputStride (=L) 个输出复用同一组系数 coeff[0..taps-1]，
// 输入每次步进 step (=M)。当 step==1 时连续加载 Vec2dU（arm64 上编译为 ldp q + ld1r + fmul/fadd）。
template <int Groups>
__attribute__((noinline))
inline void resampler_temporal_group(const double* coeff, const double* history,
                                     size_t base, int taps, size_t step,
                                     double* out, size_t outputStride) {
#pragma clang fp reassociate(off) contract(off) reciprocal(off)
    static_assert(Groups == 1 || Groups == 2 || Groups == 4);
    using detail::Vec2d;
    using detail::Vec2dU;
    Vec2d acc[Groups];
    for (int g = 0; g < Groups; ++g) acc[g] = Vec2d{0.0, 0.0};
    for (int u = 0; u < taps; ++u) {
        const double cs = coeff[u];
        const Vec2d c = {cs, cs};
        const double* hb = history + (base - (size_t)u);
        for (int g = 0; g < Groups; ++g) {
            const double* h = hb + size_t(g) * 2 * step;
            const Vec2d x = (step == 1) ? *(const Vec2dU*)(h) : Vec2d{h[0], h[step]};
            acc[g] = acc[g] + c * x;
        }
    }
    for (int g = 0; g < Groups; ++g) {
        out[size_t(g * 2) * outputStride] = acc[g][0];
        out[size_t(g * 2 + 1) * outputStride] = acc[g][1];
    }
}

// M == 1 且 2 <= L <= 4（例如 96k->192k L=2，48k->192k L=4）：
// 前提：当前输出位于相位 p=0，对应输入样本下标 base >= T-1，且剩余 >= 8*L 个输出。
// 每个 tap 仅加载 8 个连续历史样本一次，同时为所有 L 个相位各算 8 个输出（共 8*L 个连续输出）。
template <int LVal>
__attribute__((noinline))
inline void resampler_m1_interleaved8(const double* phasesFlat, int taps,
                                      const double* history, size_t base, double* out) {
#pragma clang fp reassociate(off) contract(off) reciprocal(off)
    static_assert(LVal >= 2 && LVal <= 4);
    using detail::Vec2d;
    using detail::Vec2dU;
    Vec2d acc[LVal][4];
    for (int p = 0; p < LVal; ++p)
        for (int g = 0; g < 4; ++g)
            acc[p][g] = Vec2d{0.0, 0.0};

    const double* hBase = history + base;
    for (int u = 0; u < taps; ++u) {
        const double* hu = hBase - (size_t)u;
        const Vec2d x0 = *(const Vec2dU*)(hu + 0);
        const Vec2d x1 = *(const Vec2dU*)(hu + 2);
        const Vec2d x2 = *(const Vec2dU*)(hu + 4);
        const Vec2d x3 = *(const Vec2dU*)(hu + 6);
        for (int p = 0; p < LVal; ++p) {
            const double cs = phasesFlat[(size_t)p * (size_t)taps + (size_t)u];
            const Vec2d c = {cs, cs};
            acc[p][0] = acc[p][0] + c * x0;
            acc[p][1] = acc[p][1] + c * x1;
            acc[p][2] = acc[p][2] + c * x2;
            acc[p][3] = acc[p][3] + c * x3;
        }
    }

    if constexpr (LVal == 2) {
        for (int g = 0; g < 4; ++g) {
            const Vec2d lo = __builtin_shufflevector(acc[0][g], acc[1][g], 0, 2);
            const Vec2d hi = __builtin_shufflevector(acc[0][g], acc[1][g], 1, 3);
            *(Vec2dU*)(out + size_t(g) * 4) = lo;
            *(Vec2dU*)(out + size_t(g) * 4 + 2) = hi;
        }
    } else {
        for (int g = 0; g < 4; ++g) {
            for (int lane = 0; lane < 2; ++lane) {
                const size_t k = size_t(g) * 2 + size_t(lane);
                for (int p = 0; p < LVal; ++p)
                    out[k * size_t(LVal) + size_t(p)] = acc[p][g][lane];
            }
        }
    }
}

inline void resampler_phase4(const double* coeff, size_t stride,
                             const double* history, size_t base,
                             int taps, double* out) {
    resampler_phase_group<2>(coeff, stride, history, base, taps, out);
}

#endif // RTA_RESAMPLER_NEON

} // namespace rta::dsp
