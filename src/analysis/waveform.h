// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// waveform.h — U2 包1：波形峰值包络 / RMS 的流式累加器（纯头，零框架依赖）
//
// 用途：把一段 PCM（float、交错、标称 [-1,1]）折成 N 个 bin 的峰值包络 + RMS，
//       供播放页波形绘制 / A/B 选段使用。本包**只做算法**：不解码、不读文件、
//       不写缓存、不接后端；解码接线与缓存分别属于后续包（不在本文件范围内）。
//
// 为什么是流式：整曲 PCM 铺在内存里对 DSD / 长文件不成立（同 health_stream.h 的
//   背景）。累加器只保留 bins × (float + double + uint64) 的累加状态，内存与曲长
//   无关；调用方按块喂 addBlock 即可（PCM 建议 65536 帧，DSD 走 health_stream 的
//   65536 帧/块）。
//
// 口径（与派单任务书一致，逐条可核对）：
//   1) bin 划分：bin(f) = floor(frameIndex × bins / totalFrames)，frameIndex 是
//      **全局**帧号（从 0 开始、跨块连续）。totalFrames 不被 bins 整除时按上式向
//      左取整，**不丢尾帧**（最后一帧总落在 bin ≤ bins−1）。
//   2) 不跳采样：每一帧都参与 —— 先对该帧所有声道取 |sample| 的最大值（多声道折叠
//      成单帧峰值），再归入 bin。不做降采样，瞬态不会因为"每 N 帧取一个"而漏掉。
//   3) 钳位：|sample| 钳到 [0,1]（>1 的超幅样本按 1.0 计）；NaN 按 0 计（不污染
//      max / 平方和）；±inf 按 1.0 计（先判 NaN，再判 >1）。
//   4) 峰值：peaks[bin] = 该 bin 内单帧峰值的最大值（不是均值、不做包络平滑）。
//   5) RMS：rms[bin] = sqrt( Σ 单帧峰值² / 帧数 )，即"内层均值平方根"，同样作用在
//      折叠后的单帧峰值上（多声道取 max 后求 RMS，不是先分声道求 RMS 再合并）。
//   6) maxPeak = 所有 bin 峰值的最大值（≤ 1.0，因为峰值已钳位）。
//
// 流式与整段的**逐位一致性**（硬约定，不是"接近"）：
//   addBlock 内部按**帧**顺序逐帧累加（每帧一次 max + 一次平方加），因此把同一组
//   样本按任意块大小喂进去，加法顺序完全相同 ⟹ peaks / rms / maxPeak 与整段一次性喂入**逐位相等**
//   （注意：项目全局编译选项含 -ffast-math；本实现依赖"按帧顺序累加"，若未来把内层
//   改成块内先求和再累加（或让编译器重结合跨帧的平方和），必须重新评估这条约定——
//   浮点加法不满足结合律。tests/test_waveform.cpp §2 用逐位 memcmp 钉住它。）
//
// 帧索引与边界：
//   * totalFrames 之外的帧（调用方给了多余样本）一律丢弃，不改变 bin 映射；但
//     frameIndex 仍按传入帧数前进（后续块继续被丢弃），防止重复计数。因此
//     totalFrames 应传文件的**声明帧数**；未知时传 0 ⟹ 结果全 0（不猜长度）。
//   * totalFrames=0：不崩，peaks/rms 仍按 bins 长度返回全 0、maxPeak=0、
//     durationSec=0（tests/test_waveform.cpp §3 钉住这个语义）。
//   * bins 钳 [16,4096]、默认 512：请求越界时按钳位后的值分配与返回，result.bins
//     即实际使用的 bin 数。
//   * sampleRate <= 0（未知）：durationSec=0，result.sampleRate 原样保留（0/负值）。
//   * 前置条件（现实范围）：totalFrames ≤ 2^52 帧（bin 映射用 uint64 乘法不溢出；
//     2^52 帧 @768 kHz ≈ 185 年，正常音频文件不可能接近）。
//
// 用法：
//   const std::size_t frames = static_cast<std::size_t>(durationSec * fs);
//   rta::analysis::WaveformAccumulator acc(frames, 512, fs, channels);
//   while (还有块) acc.addBlock(block, blockFrames, channels);
//   const rta::analysis::WaveformResult r = acc.finish();
// 整段便捷入口（不知道采样率时只拿包络，duration/rate 为 0）：
//   const WaveformResult r = rta::analysis::waveform_peaks_from_pcm(interleaved, ch, 512);
//
// 线程安全：无。每个累加器只归一个线程所有；不要并发 addBlock / finish。
// finish() 是只读快照，可重复调用（幂等，返回同样内容）。
#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <vector>

namespace rta::analysis {

// 波形包络结果：peaks/rms 长度 = bins（钳位后的实际 bin 数），值域 [0,1]。
// 注：sampleRate/channels 仅供调用方对齐数据用；durationSec 由 totalFrames/rate 得出，
//      不知道采样率时（sampleRate<=0）为 0，绝不按 0 冒充有效时长。
struct WaveformResult {
    int bins = 0;
    std::vector<float> peaks;
    std::vector<float> rms;
    float maxPeak = 0.0f;
    double durationSec = 0.0;
    int sampleRate = 0;
    int channels = 0;
};

// 流式波形包络累加器（header-only，零框架依赖）。
//   * 构造：totalFrames（或 duration*rate 换算后的帧数）+ bins（钳 [16,4096]，默认 512）
//            + 可选 sampleRate/channels（只影响结果字段与 durationSec，不影响包络）
//   * 喂块：addBlock(交错 float*, frames, channels)，跨块连续按全局帧号归 bin
//   * 取结果：finish()（只读快照，幂等）
class WaveformAccumulator {
public:
    static constexpr std::size_t kMinBins = 16;
    static constexpr std::size_t kMaxBins = 4096;
    static constexpr std::size_t kDefaultBins = 512;

    // 请求 bins 钳到 [16,4096]；result.bins 与实际 peaks/rms 长度都用这个值。
    static std::size_t clamp_bins(std::size_t bins) {
        return bins < kMinBins ? kMinBins : (bins > kMaxBins ? kMaxBins : bins);
    }

    WaveformAccumulator(std::size_t totalFrames, std::size_t bins = kDefaultBins,
                        int sampleRate = 0, int channels = 0)
        : totalFrames_(static_cast<std::uint64_t>(totalFrames)),
          bins_(clamp_bins(bins)),
          sampleRate_(sampleRate),
          channels_(channels > 0 ? channels : 0),
          peaks_(bins_, 0.0f),
          sumSq_(bins_, 0.0),
          counts_(bins_, 0) {}

    WaveformAccumulator(const WaveformAccumulator&) = delete;
    WaveformAccumulator& operator=(const WaveformAccumulator&) = delete;
    WaveformAccumulator(WaveformAccumulator&&) = default;
    WaveformAccumulator& operator=(WaveformAccumulator&&) = default;

    // 喂一个交错块（frames 帧、channels 声道）。
    // 语义：
    //   * frames==0 是合法空块（指针可为 nullptr），返回 true；
    //   * channels<=0、interleaved==nullptr 且 frames>0、块声道数与首次锁定值不一致
    //     ⟹ 返回 false，且不改变任何累加状态；
    //   * 构造时 channels>0 则以构造为准（后续块必须一致）；构造传 0 时由首个有效块
    //     确定声道数；
    //   * 超出 totalFrames 的帧被丢弃（见文件头注释），但帧号照常按 frames 前进。
    bool addBlock(const float* interleaved, std::size_t frames, int channels) {
        if (channels <= 0) return false;
        if (channels_ != 0 && channels != channels_) return false;
        if (frames == 0) return true;
        if (interleaved == nullptr) return false;

        const std::size_t ch = static_cast<std::size_t>(channels);
        if (frames > std::numeric_limits<std::size_t>::max() / ch) return false;
        if (channels_ == 0) channels_ = channels;

        const std::uint64_t total = totalFrames_;
        const std::uint64_t idx = frameIndex_;
        const std::uint64_t avail = total > idx ? total - idx : 0u;
        const std::uint64_t n =
            std::min<std::uint64_t>(static_cast<std::uint64_t>(frames), avail);
        const std::uint64_t b = static_cast<std::uint64_t>(bins_);

        for (std::uint64_t f = 0; f < n; ++f) {
            // 多声道折叠：逐声道 |sample| 取最大，同时钳位并吞掉 NaN（不跳采样）。
            const float* frame = interleaved + static_cast<std::size_t>(f) * ch;
            float peak = 0.0f;
            for (std::size_t c = 0; c < ch; ++c) {
                float s = std::fabs(frame[c]);
                if (!(s >= 0.0f)) {
                    s = 0.0f;  // NaN：按 0 计，不污染 max / 平方和
                } else if (s > 1.0f) {
                    s = 1.0f;  // >1 与 ±inf：钳到 1.0
                }
                if (s > peak) peak = s;
            }
            const std::size_t bin =
                static_cast<std::size_t>(((idx + f) * b) / total);
            if (peak > peaks_[bin]) peaks_[bin] = peak;
            const double p = static_cast<double>(peak);
            sumSq_[bin] += p * p;  // 必须按帧累加（块边界不得改变加法顺序）
            ++counts_[bin];
        }

        // 帧号按调用方给的实际块长前进（多给的帧被丢弃，但下一块不能再重复计入）。
        const std::uint64_t step = static_cast<std::uint64_t>(frames);
        frameIndex_ = (step > std::numeric_limits<std::uint64_t>::max() - frameIndex_)
                          ? std::numeric_limits<std::uint64_t>::max()
                          : frameIndex_ + step;
        return true;
    }

    // 只读快照；可重复调用。rms 在 finish 时按 bin 内帧数求均值平方根。
    WaveformResult finish() const {
        WaveformResult out;
        out.bins = static_cast<int>(bins_);
        out.peaks = peaks_;
        out.rms.assign(bins_, 0.0f);
        out.maxPeak = 0.0f;
        for (std::size_t i = 0; i < bins_; ++i) {
            const std::uint64_t n = counts_[i];
            if (n != 0) {
                out.rms[i] = static_cast<float>(std::sqrt(sumSq_[i] / static_cast<double>(n)));
            }
            if (peaks_[i] > out.maxPeak) out.maxPeak = peaks_[i];
        }
        out.durationSec = (sampleRate_ > 0 && totalFrames_ > 0)
                              ? static_cast<double>(totalFrames_) / static_cast<double>(sampleRate_)
                              : 0.0;
        out.sampleRate = sampleRate_;
        out.channels = channels_;
        return out;
    }

    std::size_t totalFrames() const { return static_cast<std::size_t>(totalFrames_); }
    std::size_t bins() const { return bins_; }
    int sampleRate() const { return sampleRate_; }
    int channels() const { return channels_; }

private:
    std::uint64_t totalFrames_ = 0;
    std::size_t bins_ = kDefaultBins;
    int sampleRate_ = 0;
    int channels_ = 0;
    std::uint64_t frameIndex_ = 0;
    std::vector<float> peaks_;
    std::vector<double> sumSq_;
    std::vector<std::uint64_t> counts_;
};

// 整段便捷入口：内部用 WaveformAccumulator 一次喂完，结果与累加器逐位相同。
//   * frames = interleaved.size() / channels（除不尽的尾样丢弃，按整帧计）；
//   * 没有采样率：result.sampleRate=0、result.durationSec=0（不猜）；
//   * channels<=0：不崩，返回 bins 钳位后的全零结果（不给假数据）。
inline WaveformResult waveform_peaks_from_pcm(const std::vector<float>& interleaved,
                                              int channels, std::size_t bins) {
    WaveformResult out;
    if (channels <= 0) {
        out.bins = static_cast<int>(WaveformAccumulator::clamp_bins(bins));
        out.peaks.assign(static_cast<std::size_t>(out.bins), 0.0f);
        out.rms.assign(static_cast<std::size_t>(out.bins), 0.0f);
        return out;
    }
    const std::size_t ch = static_cast<std::size_t>(channels);
    const std::size_t frames = interleaved.size() / ch;
    WaveformAccumulator acc(frames, bins, 0, channels);
    acc.addBlock(interleaved.data(), frames, channels);
    return acc.finish();
}

}  // namespace rta::analysis
