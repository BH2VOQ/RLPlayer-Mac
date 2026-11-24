// SPDX-FileCopyrightText: 2026 rainlain <https://github.com/okhuoyanyan>
// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// convolution.h — 均匀分块 FFT 卷积（uniformly-partitioned overlap-add）
//
// 用途：卷积引擎（房间校正 / 任意 FIR EQ）与 Matrix 的 WAV 卷积插件。
// 百万抽头的室内校正 IR 用直接卷积不可实时，必须分块 FFT。
//
// 结构：把 IR 切成 P 段、每段 B 个样本；每来一个 B 样本的输入块，
//   1) 补零到 2B 后 FFT
//   2) 存入输入谱环形缓冲
//   3) 累加 Σ_p H[p] · ring[head − p]
//   4) IFFT 得 2B 个样本；前 B 个与上一块的溢出相加后输出，后 B 个存为溢出
//
// 关键性质：**零延迟**。H[0] 与"当前"输入块相乘，其贡献立刻出现在本块输出的
// 前 B 个样本里，尾巴进溢出缓冲。不需要额外的一整块缓冲延迟。
#pragma once
#include "fft.h"
#include <vector>
#include <cmath>
#include <cstddef>
#include <algorithm>
#if defined(__APPLE__) && !defined(RL_NO_ACCELERATE) && (defined(__aarch64__) || defined(__arm64__))
#include <arm_neon.h>
#endif

namespace rta::dsp {

class PartitionedConvolver {
public:
    // ir 可为任意长度；block 必须是 2 的幂（推荐 256~4096）
    PartitionedConvolver(const std::vector<double>& ir, size_t block = 512) : B_(block) {
        if (B_ == 0 || (B_ & (B_ - 1)) != 0) B_ = 512;      // 强制 2 的幂
        fftN_ = B_ * 2;
        P_ = (ir.size() + B_ - 1) / B_;
        if (P_ == 0) P_ = 1;

#if defined(__APPLE__) && !defined(RL_NO_ACCELERATE)
        if (B_ >= 8) {
            log2N_ = detail::vdsp_log2_exact(fftN_);
            setup_ = detail::vdsp_fft_setup(log2N_);
        }
        if (setup_) {
            useAccel_ = true;
            HRe_.assign(P_ * B_, 0.0);
            HIm_.assign(P_ * B_, 0.0);
            ringRe_.assign(P_ * B_, 0.0);
            ringIm_.assign(P_ * B_, 0.0);
            accRe_.assign(B_, 0.0);
            accIm_.assign(B_, 0.0);
            tmp_.assign(fftN_, 0.0);
            ola_.assign(B_, 0.0);
            for (size_t p = 0; p < P_; ++p) {
                std::fill(tmp_.begin(), tmp_.end(), 0.0);
                const size_t start = p * B_;
                if (start < ir.size()) {
                    const size_t cnt = std::min(B_, ir.size() - start);
                    std::copy_n(ir.data() + start, cnt, tmp_.data());
                }
                DSPDoubleSplitComplex Hp{HRe_.data() + p * B_, HIm_.data() + p * B_};
                vDSP_ctozD(reinterpret_cast<const DSPDoubleComplex*>(tmp_.data()), 2, &Hp, 1, B_);
                vDSP_fft_zripD(setup_, &Hp, 1, log2N_, FFT_FORWARD);
            }
            head_ = 0;
            return;
        }
#endif

        H_.assign(P_, std::vector<cplx>(fftN_, cplx(0.0, 0.0)));
        for (size_t p = 0; p < P_; ++p) {
            for (size_t i = 0; i < B_; ++i) {
                const size_t k = p * B_ + i;
                if (k < ir.size()) H_[p][i] = cplx(ir[k], 0.0);
            }
            fft(H_[p]);
        }
        ring_.assign(P_, std::vector<cplx>(fftN_, cplx(0.0, 0.0)));
        acc_.assign(fftN_, cplx(0.0, 0.0));
        ola_.assign(B_, 0.0);
        head_ = 0;
    }

    size_t block_size() const { return B_; }
    size_t partitions() const { return P_; }
    size_t ir_length() const { return irLen_; }
    void set_ir_length(size_t n) { irLen_ = n; }
    size_t latency() const { return 0; }   // 均匀分块 overlap-add 为零延迟

    void reset() {
#if defined(__APPLE__) && !defined(RL_NO_ACCELERATE)
        if (useAccel_) {
            std::fill(ringRe_.begin(), ringRe_.end(), 0.0);
            std::fill(ringIm_.begin(), ringIm_.end(), 0.0);
            std::fill(ola_.begin(), ola_.end(), 0.0);
            head_ = 0;
            return;
        }
#endif
        for (auto& r : ring_) std::fill(r.begin(), r.end(), cplx(0.0, 0.0));
        std::fill(ola_.begin(), ola_.end(), 0.0);
        head_ = 0;
    }

    // 处理一个输入块（恰好 B_ 个样本），输出 B_ 个样本
    void process_block(const double* in, double* out) {
#if defined(__APPLE__) && !defined(RL_NO_ACCELERATE)
        if (useAccel_) {
            std::copy_n(in, B_, tmp_.data());
            std::fill_n(tmp_.data() + B_, B_, 0.0);
            DSPDoubleSplitComplex Rs{ringRe_.data() + head_ * B_, ringIm_.data() + head_ * B_};
            vDSP_ctozD(reinterpret_cast<const DSPDoubleComplex*>(tmp_.data()), 2, &Rs, 1, B_);
            vDSP_fft_zripD(setup_, &Rs, 1, log2N_, FFT_FORWARD);

            std::fill_n(accRe_.data(), B_, 0.0);
            std::fill_n(accIm_.data(), B_, 0.0);
            double accDc = 0.0, accNyq = 0.0;
            accumulate_segment(0, head_, head_ + 1, accDc, accNyq);
            if (head_ + 1 < P_) {
                accumulate_segment(head_ + 1, P_ - 1, P_ - 1 - head_, accDc, accNyq);
            }
            accRe_[0] = accDc;
            accIm_[0] = accNyq;

            DSPDoubleSplitComplex Ys{accRe_.data(), accIm_.data()};
            vDSP_fft_zripD(setup_, &Ys, 1, log2N_, FFT_INVERSE);
            vDSP_ztocD(&Ys, 1, reinterpret_cast<DSPDoubleComplex*>(tmp_.data()), 2, B_);

            const double scale = 1.0 / (4.0 * static_cast<double>(fftN_));
            vDSP_vsmaD(tmp_.data(), 1, &scale, ola_.data(), 1, out, 1, B_);
            vDSP_vsmulD(tmp_.data() + B_, 1, &scale, ola_.data(), 1, B_);
            head_ = (head_ + 1 == P_) ? 0 : (head_ + 1);
            return;
        }
#endif
        auto& X = ring_[head_];
        for (size_t i = 0; i < B_; ++i) X[i] = cplx(in[i], 0.0);
        std::fill(X.begin() + B_, X.end(), cplx(0.0, 0.0));
        fft(X);

        std::fill(acc_.begin(), acc_.end(), cplx(0.0, 0.0));
        for (size_t p = 0; p < P_; ++p) {
            const size_t idx = (head_ + P_ - (p % P_)) % P_;
            const auto& Xp = ring_[idx];
            const auto& Hp = H_[p];
            for (size_t k = 0; k < fftN_; ++k) acc_[k] += Xp[k] * Hp[k];
        }
        fft(acc_, /*inverse=*/true);

        for (size_t i = 0; i < B_; ++i) {
            out[i] = acc_[i].real() + ola_[i];
            ola_[i] = acc_[B_ + i].real();
        }
        head_ = (head_ + 1) % P_;
    }

private:
#if defined(__APPLE__) && !defined(RL_NO_ACCELERATE)
    void accumulate_segment(size_t p, size_t rIdx, size_t count, double& accDc, double& accNyq) {
        double* __restrict yr = accRe_.data();
        double* __restrict yi = accIm_.data();
        const size_t B = B_;
#if defined(__aarch64__) || defined(__arm64__)
        while (count >= 4) {
            const double* __restrict xr0 = ringRe_.data() + rIdx * B;
            const double* __restrict xr1 = xr0 - B;
            const double* __restrict xr2 = xr0 - 2 * B;
            const double* __restrict xr3 = xr0 - 3 * B;
            const double* __restrict xi0 = ringIm_.data() + rIdx * B;
            const double* __restrict xi1 = xi0 - B;
            const double* __restrict xi2 = xi0 - 2 * B;
            const double* __restrict xi3 = xi0 - 3 * B;
            const double* __restrict hr0 = HRe_.data() + p * B;
            const double* __restrict hr1 = hr0 + B;
            const double* __restrict hr2 = hr0 + 2 * B;
            const double* __restrict hr3 = hr0 + 3 * B;
            const double* __restrict hi0 = HIm_.data() + p * B;
            const double* __restrict hi1 = hi0 + B;
            const double* __restrict hi2 = hi0 + 2 * B;
            const double* __restrict hi3 = hi0 + 3 * B;
            accDc += xr0[0] * hr0[0] + xr1[0] * hr1[0] + xr2[0] * hr2[0] + xr3[0] * hr3[0];
            accNyq += xi0[0] * hi0[0] + xi1[0] * hi1[0] + xi2[0] * hi2[0] + xi3[0] * hi3[0];
            for (size_t k = 0; k < B; k += 2) {
                float64x2_t ar = vld1q_f64(yr + k);
                float64x2_t ai = vld1q_f64(yi + k);
                float64x2_t x0r = vld1q_f64(xr0 + k), x0i = vld1q_f64(xi0 + k);
                float64x2_t h0r = vld1q_f64(hr0 + k), h0i = vld1q_f64(hi0 + k);
                ar = vfmaq_f64(ar, x0r, h0r); ar = vfmsq_f64(ar, x0i, h0i);
                ai = vfmaq_f64(ai, x0r, h0i); ai = vfmaq_f64(ai, x0i, h0r);

                float64x2_t x1r = vld1q_f64(xr1 + k), x1i = vld1q_f64(xi1 + k);
                float64x2_t h1r = vld1q_f64(hr1 + k), h1i = vld1q_f64(hi1 + k);
                ar = vfmaq_f64(ar, x1r, h1r); ar = vfmsq_f64(ar, x1i, h1i);
                ai = vfmaq_f64(ai, x1r, h1i); ai = vfmaq_f64(ai, x1i, h1r);

                float64x2_t x2r = vld1q_f64(xr2 + k), x2i = vld1q_f64(xi2 + k);
                float64x2_t h2r = vld1q_f64(hr2 + k), h2i = vld1q_f64(hi2 + k);
                ar = vfmaq_f64(ar, x2r, h2r); ar = vfmsq_f64(ar, x2i, h2i);
                ai = vfmaq_f64(ai, x2r, h2i); ai = vfmaq_f64(ai, x2i, h2r);

                float64x2_t x3r = vld1q_f64(xr3 + k), x3i = vld1q_f64(xi3 + k);
                float64x2_t h3r = vld1q_f64(hr3 + k), h3i = vld1q_f64(hi3 + k);
                ar = vfmaq_f64(ar, x3r, h3r); ar = vfmsq_f64(ar, x3i, h3i);
                ai = vfmaq_f64(ai, x3r, h3i); ai = vfmaq_f64(ai, x3i, h3r);

                vst1q_f64(yr + k, ar);
                vst1q_f64(yi + k, ai);
            }
            count -= 4;
            if (count == 0) return;
            p += 4;
            rIdx -= 4;
        }
        while (count > 0) {
            const double* __restrict xr = ringRe_.data() + rIdx * B;
            const double* __restrict xi = ringIm_.data() + rIdx * B;
            const double* __restrict hr = HRe_.data() + p * B;
            const double* __restrict hi = HIm_.data() + p * B;
            accDc += xr[0] * hr[0];
            accNyq += xi[0] * hi[0];
            for (size_t k = 0; k < B; k += 2) {
                float64x2_t ar = vld1q_f64(yr + k);
                float64x2_t ai = vld1q_f64(yi + k);
                float64x2_t x0r = vld1q_f64(xr + k), x0i = vld1q_f64(xi + k);
                float64x2_t h0r = vld1q_f64(hr + k), h0i = vld1q_f64(hi + k);
                ar = vfmaq_f64(ar, x0r, h0r); ar = vfmsq_f64(ar, x0i, h0i);
                ai = vfmaq_f64(ai, x0r, h0i); ai = vfmaq_f64(ai, x0i, h0r);
                vst1q_f64(yr + k, ar);
                vst1q_f64(yi + k, ai);
            }
            if (--count == 0) break;
            ++p;
            --rIdx;
        }
#else
        DSPDoubleSplitComplex Ys{yr, yi};
        while (count > 0) {
            DSPDoubleSplitComplex Xp{ringRe_.data() + rIdx * B, ringIm_.data() + rIdx * B};
            DSPDoubleSplitComplex Hp{HRe_.data() + p * B, HIm_.data() + p * B};
            accDc += Xp.realp[0] * Hp.realp[0];
            accNyq += Xp.imagp[0] * Hp.imagp[0];
            vDSP_zvmaD(&Xp, 1, &Hp, 1, &Ys, 1, &Ys, 1, B);
            if (--count == 0) break;
            ++p;
            --rIdx;
        }
#endif
    }
#endif

    size_t B_ = 512, fftN_ = 1024, P_ = 1, head_ = 0, irLen_ = 0;
#if defined(__APPLE__) && !defined(RL_NO_ACCELERATE)
    bool useAccel_ = false;
    vDSP_Length log2N_ = 0;
    FFTSetupD setup_ = nullptr;
    std::vector<double> HRe_, HIm_, ringRe_, ringIm_, accRe_, accIm_, tmp_;
#endif
    std::vector<std::vector<cplx>> H_, ring_;
    std::vector<cplx> acc_;
    std::vector<double> ola_;
};

// ---- 流式卷积器：接受任意长度输入，输出同长度样本 ----
//
// 均匀分块 FFT 卷积要求【固定块长】，无法直接接受任意分块。做法：
//   * 输入进 FIFO，攒满 B 个才交一块给 PartitionedConvolver
//   * 输出 FIFO 预置 B 个零 —— 这代表 B 帧的算法延迟
//   * 每次调用弹出与输入等量的输出
// 于是"整块喂"与"分块喂"产生【完全相同】的输出序列（同样延迟 B 帧）。
// 代价：B 帧延迟（1024 帧 @44.1k ≈ 23 ms，对房间校正动辄数十万抽头可忽略）。
class StreamingConvolver {
public:
    explicit StreamingConvolver(const std::vector<double>& ir, size_t block = 1024)
        : pc_(ir, (block == 0 || (block & (block - 1)) != 0) ? size_t(1024) : block),
          B_((block == 0 || (block & (block - 1)) != 0) ? size_t(1024) : block),
          blk_(B_, 0.0),
          oblk_(B_, 0.0) {
        inFifo_.reserve(B_ * 2);
        outFifo_.assign(B_, 0.0);        // ★ 预置 B 帧延迟，保证 FIFO 永不为空
    }

    size_t latency() const { return B_; }
    size_t max_ir() const { return pc_.partitions() * B_; }

    void reset(const std::vector<double>& ir) {
        pc_ = PartitionedConvolver(ir, B_);
        inFifo_.clear();
        outFifo_.assign(B_, 0.0);
    }

    void process(const double* in, double* out, size_t n) {
        inFifo_.insert(inFifo_.end(), in, in + n);
        size_t pos = 0;
        while (inFifo_.size() - pos >= B_) {
            std::copy_n(inFifo_.data() + pos, B_, blk_.data());
            pc_.process_block(blk_.data(), oblk_.data());
            outFifo_.insert(outFifo_.end(), oblk_.begin(), oblk_.end());
            pos += B_;
        }
        if (pos) inFifo_.erase(inFifo_.begin(), inFifo_.begin() + (ptrdiff_t)pos);
        // 取出 n 个；预置的延迟保证 FIFO 不会空
        for (size_t i = 0; i < n; ++i) {
            out[i] = (i < outFifo_.size()) ? outFifo_[i] : 0.0;
        }
        if (n <= outFifo_.size()) outFifo_.erase(outFifo_.begin(), outFifo_.begin() + (ptrdiff_t)n);
        else outFifo_.clear();
    }

private:
    PartitionedConvolver pc_;
    size_t B_;
    std::vector<double> inFifo_, outFifo_, blk_, oblk_;
};

// 直接线性卷积（仅用于验证，O(N·M)）
inline std::vector<double> direct_convolve(const std::vector<double>& x, const std::vector<double>& h) {
    std::vector<double> y(x.size() + h.size(), 0.0);
    for (size_t i = 0; i < x.size(); ++i) {
        if (x[i] == 0.0) continue;
        for (size_t j = 0; j < h.size(); ++j) y[i + j] += x[i] * h[j];
    }
    y.resize(x.size());
    return y;
}

} // namespace rta::dsp
