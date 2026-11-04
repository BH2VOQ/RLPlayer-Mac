// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// cast_pcm_convert.h — AirPlay/Cast 音频转换纯函数工具
//
// 职责与铁律：
//   1. 44.1k/16bit 双声道（最常见 CD 音源）：逐样本（bit-exact）无损直通，绝不经过重采样或浮点缩放。
//   2. 其它位深（24bit/32bit/float）：按标度转换为 int16，带有 TPDF 抖动 / 安全舍入与饱和钳位（[-32768, 32767]）。
//   3. 声道处理：单声道复制为双声道；双声道保持原样；>2 声道**按已知信息诚实处理**：
//        · 3..5 声道：只取前两声道，明确警告未下混；
//        · 6 声道：按 WAV 默认 5.1 顺序（FL/FR/FC/LFE/BL/BR）近似下混，警告写清这是**假设**，
//          且 AudioBuffer 不携带声道布局 ⟹ **不宣称** ITU-R BS.775 一致性；
//        · 7/8 声道及以上：只取前两声道，并明确写出被忽略的声道范围（绝不静默丢弃、绝不假装下混）。
//   4. 任意采样率重采样到 44100 Hz：使用 PolyphaseResampler，补偿滤波器群延迟（delay compensation），
//      并通过补足零输入尾部（zero-tail drain）提取完整滤波拖尾，确保输出时长与理论精确帧数严格一致。
//   5. 纯函数、无全局状态，完全可在离线单测中复现。
//   6. 目标格式只有一种（44100 Hz / 2 声道 / 16 bit）：CastAudioSpec 的其它取值在入口直接拒绝。
//      历史问题：两条输出路径都按 2ch/16bit 分配缓冲、却用 spec.targetRate 算时长，
//      于是 spec=48000/32bit 会得到「自称 48 kHz 的 16-bit 立体声」——格式与声明不符且无人报错。
#pragma once

#include "audio/wav.h"
#include "dsp/resampler.h"
#include "dsp/dither.h"
#include <vector>
#include <string>
#include <cmath>
#include <cstdint>
#include <algorithm>
#include <stdexcept>

namespace rta::audio {

struct CastAudioSpec {
    uint32_t targetRate = 44100;   // 只支持 44100（RAOP/ALAC 会话固定）
    int      targetChannels = 2;   // 只支持 2
    int      targetBits = 16;      // 只支持 16
};

// 目标格式白名单校验：不在白名单就抛 std::invalid_argument（调用方 catch 后按错误上报）。
// 为什么不「尽力转换」：ALAC 发送端按 44100/16/2 组包，产出别的格式只会静默错位/变速。
inline void validate_cast_spec(const CastAudioSpec& spec) {
    if (spec.targetRate != 44100 || spec.targetChannels != 2 || spec.targetBits != 16) {
        throw std::invalid_argument(
            "CastAudioSpec only supports 44100 Hz / 2 channels / 16 bit (got " +
            std::to_string(spec.targetRate) + " Hz / " + std::to_string(spec.targetChannels) +
            " ch / " + std::to_string(spec.targetBits) + " bit)");
    }
}

struct CastAudioConversionResult {
    std::vector<int16_t> pcm;           // 交错的 44.1k / 16-bit / 2ch PCM 样本
    size_t               frames = 0;    // 总帧数 = pcm.size() / targetChannels
    double               durationSec = 0.0;
    std::string          warningZh;     // 中文警告（如有降级或下混）
    std::string          warningEn;     // 英文警告
    bool                 bitExactDirect = false; // 是否触发了 44.1k/16bit 逐位直接映射
};

// 诚实下混与通道提取
//
// ⚠️ 关键限制：AudioBuffer **不携带声道布局/声道掩码**（只有 channels 计数）。
// 因此这里能确定的只有「第 0/1 路是前左/前右」这一条通用约定，其余只能按假设处理：
//   · 6 声道 → 假设 WAV 默认 5.1 顺序 (FL/FR/FC/LFE/BL/BR)，按 BS.775 的**权重形式**近似下混
//     （L' = (L + 0.7071·C + 0.7071·BL)/1.7071，R' 对称，LFE 丢弃），
//     但**不宣称**这是一致性验证过的 ITU-R BS.775 结果 —— 源若实际是 5.1(side) 或别的顺序，
//     结果就是错的，所以警告必须把假设写出来。
//   · 7/8 声道及以上 → 不假装能下混（多出来的后置/侧置/高度声道没有可映射的位置）：
//     只取前两声道，并明确写出「第 3..N 声道不会出现在输出中」。
//   · 3..5 声道 → 只取前两声道（没有足够信息判断中心/环绕语义）。
inline void extract_or_downmix_channels(const AudioBuffer& src,
                                        std::vector<std::vector<double>>& planarOut,
                                        std::string& warnZh,
                                        std::string& warnEn) {
    const int inCh = src.channels;
    const size_t nFrames = src.frames();
    planarOut.resize(2);
    planarOut[0].resize(nFrames);
    planarOut[1].resize(nFrames);

    if (inCh == 1) {
        // 单声道复制到双声道
        for (size_t i = 0; i < nFrames; ++i) {
            double s = src.sample(i, 0);
            planarOut[0][i] = s;
            planarOut[1][i] = s;
        }
        warnZh = "单声道音源已复制为双声道输出";
        warnEn = "Mono source replicated to stereo channels";
    } else if (inCh == 2) {
        for (size_t i = 0; i < nFrames; ++i) {
            planarOut[0][i] = src.sample(i, 0);
            planarOut[1][i] = src.sample(i, 1);
        }
    } else if (inCh == 6) {
        // 6 声道：按 WAV 默认 5.1 顺序假设 (0:L, 1:R, 2:C, 3:LFE 丢弃, 4:BL, 5:BR) 近似下混。
        // 归一化 1/(1+0.7071+0.7071) 防峰值过载；LFE 不带入（避免低频能量叠加到立体声）。
        const double kC = 0.7071067811865475;
        const double kNorm = 1.0 / (1.0 + kC + kC);
        for (size_t i = 0; i < nFrames; ++i) {
            double l  = src.sample(i, 0);
            double r  = src.sample(i, 1);
            double c  = src.sample(i, 2);
            double ls = src.sample(i, 4);
            double rs = src.sample(i, 5);
            planarOut[0][i] = (l + kC * c + kC * ls) * kNorm;
            planarOut[1][i] = (r + kC * c + kC * rs) * kNorm;
        }
        warnZh = "源为 6 声道，按 WAV 默认 5.1 顺序（FL/FR/FC/LFE/BL/BR）近似下混为立体声，LFE 丢弃；"
                 "源未携带声道布局信息，不宣称 ITU-R BS.775 一致性";
        warnEn = "Source has 6 channels; approximated 5.1-to-stereo downmix assuming the WAV default "
                 "order (FL/FR/FC/LFE/BL/BR), LFE dropped; the source carries no channel layout, "
                 "so this is not claimed to be an ITU-R BS.775-conformant downmix";
    } else {
        // 3..5 声道（无布局信息）或 7 声道及以上（无处安放的额外声道）：只取前两声道，如实说明。
        for (size_t i = 0; i < nFrames; ++i) {
            planarOut[0][i] = src.sample(i, 0);
            planarOut[1][i] = src.sample(i, 1);
        }
        const std::string chStr = std::to_string(inCh);
        if (inCh > 6) {
            warnZh = "源为 " + chStr + " 声道，投放仅提取前两声道；第 3.." + chStr +
                     " 声道（含环绕/高度声道）不会出现在输出中（未下混）";
            warnEn = "Source has " + chStr + " channels; only the first two channels are cast. "
                     "Channels 3.." + chStr + " (surround/height) are absent from the output (no downmix)";
        } else {
            warnZh = "源为 " + chStr + " 声道非标布局，投放仅提取前两声道（未做下混）";
            warnEn = "Source has " + chStr + " channels with an unknown layout; only the front two "
                     "channels are cast (no downmix)";
        }
    }
}

// 整数 sample 从 AudioBuffer 的 raw 中直接提取（避免 double 往返转换损失最后 1 bit）
inline int16_t sample_to_int16_exact(int32_t rawVal, int bits, bool isFloat) {
    if (isFloat) {
        float f;
        std::memcpy(&f, &rawVal, 4);
        if (std::isnan(f)) return 0;
        if (f >= 1.0f) return 32767;
        if (f <= -1.0f) return -32768;
        return static_cast<int16_t>(std::lround(f * 32767.0f));
    }
    if (bits == 16) {
        return static_cast<int16_t>(rawVal);
    }
    if (bits == 8) {
        // rawVal is [-128, 127]（WAV 8-bit PCM 减 128 后的有符号值）。
        // ⚠️ 历史 BUG：这里写的是 `rawVal << 8` —— 有符号负数左移在 C++ 里是 UB
        // （UBSan 直接报 "left shift of negative value"）。乘法同样精确且定义良好。
        return static_cast<int16_t>(rawVal * 256);
    }
    if (bits == 24) {
        // rawVal is 24-bit sign extended: [-8388608, 8388607]
        // 移位除以 256
        int32_t rounded = (rawVal + 128) >> 8;
        if (rounded > 32767) rounded = 32767;
        if (rounded < -32768) rounded = -32768;
        return static_cast<int16_t>(rounded);
    }
    if (bits == 32) {
        // rawVal is 32-bit: [-2147483648, 2147483647]
        int64_t rounded = (static_cast<int64_t>(rawVal) + 32768) >> 16;
        if (rounded > 32767) rounded = 32767;
        if (rounded < -32768) rounded = -32768;
        return static_cast<int16_t>(rounded);
    }
    return 0;
}

// 将平面 double 样本量化为 int16（带 TPDF dither 与安全钳位）
inline void quantize_planar_to_int16(const std::vector<std::vector<double>>& planar,
                                    std::vector<int16_t>& outPcm,
                                    bool applyDither = true) {
    const size_t nFrames = planar.empty() ? 0 : planar[0].size();
    const size_t outCh = 2;
    outPcm.resize(nFrames * outCh);

    // 使用确定性 Rng 生成 TPDF 抖动
    rta::dsp::Rng rng(0x112CA57);

    for (size_t i = 0; i < nFrames; ++i) {
        for (size_t c = 0; c < outCh; ++c) {
            double v = planar[c][i];
            if (!rta::dsp::finite_bits(v)) v = 0.0;
            // 归一化振幅缩放到 32768 满幅尺度
            double scaled = v * 32768.0;

            if (applyDither) {
                // TPDF: [-1.0, 1.0] LSB
                double d1 = rng.uniform();
                double d2 = rng.uniform();
                double tpdf = (d1 - d2); // 三角分布，峰值 1 LSB
                scaled += tpdf;
            }

            double rounded = std::floor(scaled + 0.5);
            if (rounded > 32767.0) rounded = 32767.0;
            if (rounded < -32768.0) rounded = -32768.0;
            outPcm[i * outCh + c] = static_cast<int16_t>(rounded);
        }
    }
}

// 重采样到目标 44100 Hz，补偿群延迟并补全滤波器零输入尾部
inline size_t resample_planar_with_drain(const std::vector<std::vector<double>>& inPlanar,
                                         uint32_t inRate,
                                         uint32_t outRate,
                                         std::vector<std::vector<double>>& outPlanar) {
    if (inRate == outRate) {
        outPlanar = inPlanar;
        return outPlanar.empty() ? 0 : outPlanar[0].size();
    }
    const int ch = 2;
    const size_t inFrames = inPlanar[0].size();
    if (inFrames == 0) {
        outPlanar.assign(ch, std::vector<double>());
        return 0;
    }

    rta::dsp::ResamplerConfig rc;
    rc.inRate = inRate;
    rc.outRate = outRate;
    rc.channels = ch;
    rc.totalTaps = 32768;
    rc.twoStage = false; // 单阶段保证群延迟严格线性且易于精确补偿

    rta::dsp::PolyphaseResampler rs(rc);
    const double ratio = static_cast<double>(outRate) / static_cast<double>(inRate);
    const double latencyIn = rs.latencyInputSamples();
    const size_t delayOut = static_cast<size_t>(std::llround(latencyIn * ratio));
    // 理论精确目标输出帧数
    const size_t targetOutFrames = static_cast<size_t>(std::llround(static_cast<double>(inFrames) * ratio));

    // 为充分排空滤波器的历史抽头，在末尾补充足够数量的零样本
    const size_t drainInFrames = static_cast<size_t>(std::ceil(latencyIn * 2.0)) + 64;
    const size_t totalInFrames = inFrames + drainInFrames;

    std::vector<std::vector<double>> paddedIn(ch, std::vector<double>(totalInFrames, 0.0));
    for (int c = 0; c < ch; ++c) {
        std::copy(inPlanar[c].begin(), inPlanar[c].end(), paddedIn[c].begin());
    }

    std::vector<const double*> inPtrs(ch);
    for (int c = 0; c < ch; ++c) inPtrs[c] = paddedIn[c].data();

    const size_t maxOut = rs.maxOutFrames(totalInFrames);
    std::vector<std::vector<double>> rawOut(ch, std::vector<double>(maxOut, 0.0));
    std::vector<double*> outPtrs(ch);
    for (int c = 0; c < ch; ++c) outPtrs[c] = rawOut[c].data();

    const size_t produced = rs.process(inPtrs.data(), totalInFrames, outPtrs.data());

    // 截取补偿群延迟后的 targetOutFrames
    outPlanar.assign(ch, std::vector<double>(targetOutFrames, 0.0));
    for (int c = 0; c < ch; ++c) {
        for (size_t i = 0; i < targetOutFrames; ++i) {
            size_t srcIdx = i + delayOut;
            if (srcIdx < produced) {
                outPlanar[c][i] = rawOut[c][srcIdx];
            } else {
                outPlanar[c][i] = 0.0;
            }
        }
    }
    return targetOutFrames;
}

// 统一的 Cast 音频转换核心函数
inline CastAudioConversionResult convert_audio_for_cast(const AudioBuffer& src,
                                                        const CastAudioSpec& spec = CastAudioSpec()) {
    CastAudioConversionResult res;
    // 先卡目标格式：下面两条路径都按 2ch/16bit 分配，不校验就会产出与 spec 声明不符的 PCM。
    validate_cast_spec(spec);
    if (src.raw.empty() || src.channels <= 0 || src.rate == 0) {
        return res;
    }

    const size_t inFrames = src.frames();

    // ─────────────────────────────────────────────────────────────────────────
    // 黄金路径（Bit-Exact Direct Pass-Through）：
    // 若源为 44.1k / 16-bit / 2声道 / 非浮点，逐样本无损拷贝，绝不乘 32767，绝不进重采样！
    // ─────────────────────────────────────────────────────────────────────────
    if (src.rate == spec.targetRate &&
        src.channels == spec.targetChannels &&
        src.bits == spec.targetBits &&
        !src.isFloat) {
        res.pcm.resize(inFrames * 2);
        for (size_t i = 0; i < inFrames * 2; ++i) {
            res.pcm[i] = static_cast<int16_t>(src.raw[i]);
        }
        res.frames = inFrames;
        res.durationSec = static_cast<double>(inFrames) / 44100.0;
        res.bitExactDirect = true;
        return res;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 通用转换路径：
    // 1. 声道规范化 / 诚实下混
    // ─────────────────────────────────────────────────────────────────────────
    std::vector<std::vector<double>> planar;
    extract_or_downmix_channels(src, planar, res.warningZh, res.warningEn);

    // 2. 采样率重采样与群延迟补偿
    std::vector<std::vector<double>> resampled;
    if (src.rate != spec.targetRate) {
        resample_planar_with_drain(planar, src.rate, spec.targetRate, resampled);
    } else {
        resampled = std::move(planar);
    }

    const size_t outFrames = resampled.empty() ? 0 : resampled[0].size();
    res.frames = outFrames;
    res.durationSec = static_cast<double>(outFrames) / static_cast<double>(spec.targetRate);

    // 3. 量化到目标 16-bit（当源位深 > 16 或浮点或重采样后时，应用 TPDF 抖动与安全舍入）
    const bool needDither = (src.bits > 16 || src.isFloat || src.rate != spec.targetRate);
    quantize_planar_to_int16(resampled, res.pcm, needDither);

    return res;
}

} // namespace rta::audio
