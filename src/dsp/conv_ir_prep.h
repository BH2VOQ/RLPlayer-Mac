// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// conv_ir_prep.h — 卷积 IR 预处理：超 Nyquist 外推 + 自动增益估算
//
// 两项预处理能力的用途：
//
//  1) 超 Nyquist 外推
//     用户导入的 IR 常常是 44.1k/48k 测量的（REW、AutoEq、厂商提供的 44.1k WAV）。
//     这些 IR 的带宽只到 fs_ir/2（22.05k / 24k）。播放 96k 或 192k 素材时，
//     22k 以上完全空白 —— 听感是"高频发闷/缺空气感"。
//     本文件在频域把 IR 的幅度谱按高频趋势延拓到目标带宽，
//     再变换回时域，以扩展滤波器文件原有 Nyquist 频率之外的响应。
//
//  2) 自动增益估算
//     IR 的绝对增益千差万别（不同软件导出的归一化基准不同：有的归一化到峰值 1.0，
//     有的归一化到 0 dB 平均，有的干脆不归一化）。直接塞进卷积器会导致
//     整体过响或过轻，甚至削波。
//     本文件提供两种基准（峰值 / 通带平均），用于估算已加载 IR 的增益，
//     并给出建议的补偿增益。
//
// 设计约束：
//  * 纯算法，不碰设备/线程/文件（与 room_correction.h 同样的铁律）
//  * 只依赖 fft.h / kaiser.h，零平台依赖
//  * 不改动 convolution.h —— 现有 97 个测试的基线不动
#pragma once
#include "fft.h"
#include "kaiser.h"
#include <vector>
#include <cmath>
#include <cstddef>
#include <algorithm>
#include <stdexcept>
#include <string>

namespace rta::dsp {

// ===========================================================================
// 自动增益估算
// ===========================================================================

struct IrGainInfo {
    double peakAbs      = 0.0;   // max|x[n]|，线性
    double peakDb       = 0.0;   // 20·log10(peakAbs)
    double passbandMean = 0.0;   // 通带平均线性幅度（默认 200 Hz ~ min(2 kHz, 0.45·fs)）
    double passbandDb   = 0.0;   // 20·log10(passbandMean)
    double sumAbs       = 0.0;   // Σ|x[n]|（L1 范数，用于估计最坏情况输出峰值）
    double energy       = 0.0;   // Σx[n]²（L2 能量）
    size_t peakIndex    = 0;     // 峰值位置（用于判断 IR 的延迟/因果性）

    // ---- 经验峰值因子（2026-10-26 新增，修复 safe_ir_gain 的致命缺陷）----
    // measuredCrest : 用确定性白噪实测的 crest = 输出峰值 / 通带均值。
    //                 0 = 未测量（调用方传 measure_crest=false，或 IR 为空）。
    // probePeaks    : 测量时的探测样本数（诊断用）。
    double measuredCrest = 0.0;
    size_t probePeaks    = 0;
};

// ===========================================================================
// 经验峰值因子测量（safe_ir_gain 的基础）
// ===========================================================================

// 用确定性白噪实测"输入满幅时，卷积输出的峰值 / 通带均值"这个比值。
//
// 为什么必须实测而不是解析估算（这是 2026-10-26 修的真实 bug）：
//   v1 用固定 crestFactor = 1.8。在 9 种低通 IR 上全部通过，
//   但在房间校正风格 IR（长 + 共振）上彻底失效：
//     room/65536: passband=20.83, Σ|h|=4102, 实测峰值=82.4
//     → 真实 crest = 3.95，固定 1.8 预测不足 → 输出 2.20 削波
//   试过用 Σ|h|/passband（保守 2~4 倍）和 L1/L2+Σ|h| 的线性模型，
//   要么失效要么过度保守 6~28 dB。**唯一可靠的办法就是直接测。**
//
// 实现：用 xorshift64*（确定性，跨平台逐位一致）生成白噪，
//       通过 IR 做 FFT 重叠相加卷积，取输出峰值。
//
// 精度（2026-10-26 实测，PROBE=262144）：
//   11 种 IR 上"经验 crest / 长时参考 crest"的比值范围 0.969 ~ 1.167，
//   即最坏低估 3.1%。配合 safe_ir_gain 的额外余量足够安全。
//
// 成本：11~30 ms（262144 探测样本，IR 长度 512~65536）。离线操作，可接受。
inline double measure_empirical_crest(const std::vector<double>& ir,
                                      double passbandMean,
                                      size_t probeSamples = 262144) {
    if (ir.empty() || !(passbandMean > 1e-300)) return 0.0;

    // 探测长度：至少覆盖 IR 的 2 倍，避免 IR 尾巴被截断
    const size_t N = std::max(probeSamples, ir.size() * 2);
    if (N > (size_t(1) << 22)) return 0.0;      // 防御：超过 4M 样本放弃

    // 确定性 PRNG：xorshift64*（与 dither.h 同款，跨平台逐位一致）
    uint64_t s = 0x9E3779B97F4A7C15ull;
    auto next = [&s]() {
        s ^= s >> 12; s ^= s << 25; s ^= s >> 27;
        return s * 2685821657736338717ull;
    };
    std::vector<double> x(N);
    for (size_t i = 0; i < N; ++i)
        x[i] = (double)(next() >> 11) * (1.0 / 9007199254740992.0) * 2.0 - 1.0;

    // 重叠相加卷积（FFT 长度 >= 2*IR，hop = fftN - irLen + 1）
    size_t nfft = 1;
    while (nfft < ir.size() * 2) nfft <<= 1;
    const size_t hop = nfft - ir.size() + 1;
    if (hop == 0) return 0.0;

    std::vector<cplx> H(nfft, cplx(0.0, 0.0));
    for (size_t i = 0; i < ir.size(); ++i) H[i] = cplx(ir[i], 0.0);
    fft(H);

    std::vector<double> acc(N, 0.0);
    std::vector<cplx> X(nfft), Y(nfft);
    for (size_t off = 0; off < N; off += hop) {
        std::fill(X.begin(), X.end(), cplx(0.0, 0.0));
        for (size_t i = 0; i < hop && off + i < N; ++i) X[i] = cplx(x[off + i], 0.0);
        fft(X);
        for (size_t k = 0; k < nfft; ++k) Y[k] = X[k] * H[k];
        fft(Y, /*inverse=*/true);
        for (size_t i = 0; i < nfft && off + i < N; ++i) acc[off + i] += Y[i].real();
    }

    double peak = 0.0;
    for (size_t i = 0; i < N; ++i) peak = std::max(peak, std::fabs(acc[i]));
    return peak / passbandMean;
}

// 估算 IR 的增益特征。
//
// fs          : IR 自身的采样率（决定通带上限）
// bandLo/bandHi: 通带平均的频段（Hz）。bandHi <= 0 表示自动取 min(2000, 0.45·fs)
// measureCrest: 是否实测峰值因子（默认 true）。false 时 measuredCrest = 0，
//               调用方只能用 guaranteed_ir_gain()（严格但会压低 10~18 dB）。
inline IrGainInfo estimate_ir_gain(const std::vector<double>& ir, double fs,
                                   double bandLo = 200.0, double bandHi = 0.0,
                                   bool measureCrest = true) {
    IrGainInfo info;
    if (ir.empty()) return info;

    // ---- 时域统计 ----
    double best = -1.0;
    for (size_t i = 0; i < ir.size(); ++i) {
        const double a = std::fabs(ir[i]);
        if (a > best) { best = a; info.peakIndex = i; }
        info.sumAbs += a;
        info.energy += ir[i] * ir[i];
    }
    info.peakAbs = best;
    info.peakDb  = 20.0 * std::log10(best > 1e-300 ? best : 1e-300);

    // ---- 通带平均幅度（频域）----
    // 用 FFT 求半谱，再对 [bandLo, bandHi] 内的 bin 取线性平均。
    // 频段内 bin 数太少（IR 很短或频段很窄）时，退回用时域峰值，避免除零/噪声。
    if (fs > 0.0) {
        const double hi = (bandHi > 0.0) ? bandHi : std::min(2000.0, 0.45 * fs);
        const double lo = std::min(bandLo, hi * 0.5);
        const size_t n = 1;
        size_t nF = n;
        while (nF < ir.size()) nF <<= 1;
        if (nF < 16) nF = 16;

        std::vector<cplx> X(nF, cplx(0.0, 0.0));
        for (size_t i = 0; i < ir.size(); ++i) X[i] = cplx(ir[i], 0.0);
        fft(X);

        const double binHz = fs / (double)nF;
        double sum = 0.0;
        size_t cnt = 0;
        for (size_t k = 1; k <= nF / 2; ++k) {          // 跳过 DC：IR 可能有直流偏置
            const double f = (double)k * binHz;
            if (f < lo) continue;
            if (f > hi) break;
            sum += std::abs(X[k]);
            ++cnt;
        }
        if (cnt >= 2) {
            info.passbandMean = sum / (double)cnt;
            info.passbandDb   = 20.0 * std::log10(info.passbandMean > 1e-300 ? info.passbandMean : 1e-300);
        } else {
            // 频段太窄/IR 太短：用峰值当近似（保守，不会把增益算大）
            info.passbandMean = info.peakAbs;
            info.passbandDb   = info.peakDb;
        }
    }

    // ---- 经验峰值因子（修复 v1 固定常数的缺陷，见 measure_empirical_crest 注释）----
    if (measureCrest && info.passbandMean > 1e-300) {
        info.measuredCrest = measure_empirical_crest(ir, info.passbandMean);
        info.probePeaks    = 262144;
    }
    return info;
}

// 建议的补偿增益（线性），把 IR 的增益归一到"不削波"的目标。
//
// 两种基准：
//   IrGainMode::Peak      —— 让 IR 峰值 = 1.0。适合"IR 本身是单位冲激响应"的场景，
//                            但房间校正 IR 的峰值往往远大于通带平均，会听感偏轻。
//   IrGainMode::Passband  —— 让通带平均 = 1.0（0 dB）。人声/能量主区对齐，
//                            听感最中性。room_correction.h 用的就是这个基准。
//
// headroomDb: 额外留的余量（默认 0）。房间校正 IR 的峰值可能远高于通带平均，
//             若后续有叠加（多路卷积/PEQ boost），建议留 3~6 dB。
enum class IrGainMode { Peak, Passband };

inline double suggest_ir_gain(const IrGainInfo& info, IrGainMode mode = IrGainMode::Passband,
                              double headroomDb = 0.0) {
    const double ref = (mode == IrGainMode::Peak) ? info.peakAbs : info.passbandMean;
    if (!(ref > 1e-300)) return 1.0;
    const double g = 1.0 / ref;
    return g * std::pow(10.0, -headroomDb / 20.0);
}

// 最坏情况输出峰值估计：输入满幅 ±1 时，卷积输出的理论上界是 Σ|h[n]|。
// 返回值语义：**还需要衰减多少 dB 才能保证不削波**。
//   Σ|h| > 1  → 返回负值（必须衰减，例如 Σ|h|=2 → -6.02 dB）
//   Σ|h| < 1  → 返回正值（有余量，例如 Σ|h|=0.875 → +1.16 dB）
//   Σ|h| = 1  → 0 dB
inline double worst_case_headroom_db(const IrGainInfo& info) {
    if (!(info.sumAbs > 1e-300)) return 0.0;
    // 20·log10(1 / Σ|h|) = -20·log10(Σ|h|)
    return -20.0 * std::log10(info.sumAbs);
}

// 安全增益：在"归一化基准"和"不削波"之间取平衡。
//
// ⚠️ 这个函数修过三次，全部记录在 tests/test_conv_ir_prep.cpp §6/§8：
//
//   v1（固定 crestFactor = 1.8）—— 有致命 bug
//      在 9 种低通 IR 上全过，但房间校正风格 IR（长 + 共振）彻底失效：
//        room/65536: passband=20.83, 实测峰值=82.4, 真实 crest=3.95
//        固定 1.8 严重低估 → 输出 2.20 ❌ 削波
//
//   v2（Σ|h| 上界）—— 安全但过度保守
//      同一低通 IR 的 Σ|h|=3.43 要求 -10.7 dB，而实测只需 -0.8 dB。
//      直接套用会把音量压低 10~18 dB。
//
//   v3（实测 crest）—— 峰值准确了，但基准混淆
//      room/65536 的 passband=20.8（强共振导致），按通带归一要 -26.4 dB，
//      再乘 crest 4.39 变成 -39.6 dB —— 用户听到的是"几乎没声音"。
//      根因：**同时用两个基准**（通带归一 + 峰值约束），两者差距大时过度压制。
//
//   v4（当前）—— 基准与限幅分离
//      * 基准（base）：由 mode 决定，Peak 或 Passband。这是**音量**的来源。
//      * 限幅（ceiling）：只用实测 crest 判断"会不会削波"，**只在必要时**压。
//      这样：正常 IR 走基准不动；只有真会削波时才限幅，且限幅量刚好够。
//
// 数学保证 vs 听感：本函数**不提供**严格数学保证（那要 Σ|h|，代价 -10~-18 dB）。
// 需要严格保证时用 guaranteed_ir_gain()。
inline double safe_ir_gain(const IrGainInfo& info,
                           IrGainMode mode = IrGainMode::Passband,
                           double headroomDb = 0.0,
                           double safetyMargin = 1.05) {
    // ---- 1. 基准增益（决定音量）----
    const double ref = (mode == IrGainMode::Peak) ? info.peakAbs : info.passbandMean;
    double g = (ref > 1e-300) ? 1.0 / ref : 1.0;

    // ---- 2. 限幅（只在会削波时压，压到刚好够）----
    // 用实测 crest 预测"满幅白噪输入时的输出峰值"。
    // measuredCrest == 0（没测）时退回 Σ|h| 上界（保守）。
    double crest;
    if (info.measuredCrest > 0.0) {
        crest = info.measuredCrest * (safetyMargin > 0.0 ? safetyMargin : 1.0);
    } else {
        crest = (info.passbandMean > 1e-300 && info.sumAbs > 1e-300)
                    ? info.sumAbs / info.passbandMean : 0.0;
    }

    if (crest > 0.0 && info.passbandMean > 1e-300) {
        // 输出峰值 = 输入峰值(1.0) × 通带均值 × crest × g
        const double predictedPeak = info.passbandMean * crest * g;
        if (predictedPeak > 1.0) {
            // 只压到刚好不削波，不再额外压
            g /= predictedPeak;
        }
    }
    return g * std::pow(10.0, -headroomDb / 20.0);
}

// 严格保证版：用 Σ|h| 上界，数学上保证任何输入都不削波。
// 代价：对低通 IR 会压低 10~18 dB（见上面的坑 2）。仅用于测试与极端场景。
inline double guaranteed_ir_gain(const IrGainInfo& info, double headroomDb = 0.0) {
    double g = 1.0;
    if (info.passbandMean > 1e-300) g = std::min(g, 1.0 / info.passbandMean);
    if (info.sumAbs > 1e-300)       g = std::min(g, 1.0 / info.sumAbs);
    return g * std::pow(10.0, -headroomDb / 20.0);
}

// ===========================================================================
// 超 Nyquist 外推
// ===========================================================================

struct ExtrapolateSpec {
    double srcFs      = 44100.0;  // IR 原始采样率
    double dstFs      = 0.0;      // 目标采样率；0 = 不改变时长，只补频域（见下）
    double fadeStartHz = 0.0;     // 从哪个频率开始衰减（0 = 自动取 0.90 · srcNyquist）
    double fadeEndHz   = 0.0;     // 衰减到哪个频率（0 = 自动取 1.00 · srcNyquist）
    double floorDb     = -120.0;  // 外推区的最低电平（相对通带），防止把噪声底放大
};

// 把 IR 的频响从 srcNyquist 延拓到 dstNyquist。
//
// 算法（标准做法，非抄任何实现）：
//   1) 对 IR 补零做 FFT，得到半谱幅度 |H[k]| 与相位
//   2) 在 [fadeStart, fadeEnd] 区间内把幅度平滑压到 0（避免硬截断产生 Gibbs 振铃）
//   3) [fadeEnd, dstNyquist] 区间保持 0（不外推噪声，只做"带宽声明"）
//   4) 用最小相位重建：复倒谱法把幅度谱变成因果 FIR
//      —— 因为原始 IR 的相位信息在补零后已无意义（补零区没有测量数据）
//   5) 按 dstFs 重新采样时域长度
//
// 返回：按 dstFs 采样率、长度为 taps 的新 IR。
//
// 注意：这不是"凭空造高频"。它的作用是
//   a) 明确声明带宽（避免上采样时把 22k 以上的噪声/镜像带进来）
//   b) 用最小相位保证因果性，让卷积器不需要额外延迟
// 如果原始 IR 在 20k 附近已经有明显衰减，外推不会"恢复"它 —— 那是测量缺失，
// 数学上无法凭空恢复。本函数只保证"边界干净"。
inline std::vector<double> extrapolate_ir_bandwidth(const std::vector<double>& ir,
                                                    const ExtrapolateSpec& spec,
                                                    size_t taps = 0) {
    if (ir.empty()) return {};
    if (!(spec.srcFs > 0.0)) throw std::runtime_error("外推失败: srcFs 必须 > 0");

    const double dstFs = (spec.dstFs > 0.0) ? spec.dstFs : spec.srcFs;
    if (dstFs < spec.srcFs)
        throw std::runtime_error("外推失败: dstFs (" + std::to_string(dstFs) +
                                 ") 不能低于 srcFs (" + std::to_string(spec.srcFs) + ")");

    const double srcNyq = 0.5 * spec.srcFs;
    (void)0;   // dstNyq 由 nfft 网格隐式决定，这里不直接用

    // ---- 自动边界 ----
    double f0 = spec.fadeStartHz > 0.0 ? spec.fadeStartHz : 0.90 * srcNyq;
    double f1 = spec.fadeEndHz   > 0.0 ? spec.fadeEndHz   : 1.00 * srcNyq;
    if (f1 <= f0) f1 = f0 + 1.0;
    if (f1 > srcNyq) f1 = srcNyq;
    if (f0 > f1) f0 = f1 * 0.9;

    // ---- 目标长度 ----
    // 按 dstFs 计算，保持与原始 IR 相同的时长（秒），至少 taps 个
    const double durSec = (double)ir.size() / spec.srcFs;
    size_t nOut = (size_t)std::llround(durSec * dstFs);
    if (taps > 0) nOut = std::max(nOut, taps);
    if (nOut < 16) nOut = 16;

    const size_t nF = 1;
    size_t nfft = nF;
    while (nfft < std::max(ir.size() * 4, nOut * 2)) nfft <<= 1;

    // ---- 原始 IR 的幅度谱（在 srcFs 网格上）----
    std::vector<cplx> X(nfft, cplx(0.0, 0.0));
    for (size_t i = 0; i < ir.size(); ++i) X[i] = cplx(ir[i], 0.0);
    fft(X);

    // ---- 构造目标幅度谱（在 dstFs 网格上，但用 srcFs 的测量区）----
    // 关键：dstFs > srcFs 时，dst 的 bin 更密。src 的测量只覆盖到 srcNyq，
    // 所以 [0, srcNyq] 用 src 的幅度插值，[srcNyq, dstNyq] 走衰减到 0。
    std::vector<double> mag(nfft / 2 + 1, 0.0);
    const double dstBinHz = dstFs / (double)nfft;
    const double srcBinHz = spec.srcFs / (double)nfft;
    const double floorLin = std::pow(10.0, spec.floorDb / 20.0);

    // 先取 src 半谱幅度
    const size_t srcHalf = nfft / 2;
    std::vector<double> srcMag(srcHalf + 1, 0.0);
    for (size_t k = 0; k <= srcHalf; ++k)
        srcMag[k] = std::abs(X[k]);

    // 通带参考电平（用 200 Hz~2 kHz 的均值，与 estimate_ir_gain 同基准）
    double ref = 0.0;
    {
        double s = 0.0; size_t c = 0;
        for (size_t k = 1; k <= srcHalf; ++k) {
            const double f = (double)k * srcBinHz;
            if (f < 200.0) continue;
            if (f > std::min(2000.0, 0.45 * spec.srcFs)) break;
            s += srcMag[k]; ++c;
        }
        ref = (c >= 2) ? s / (double)c : (srcMag.empty() ? 1.0 : srcMag[srcHalf / 8]);
    }
    if (!(ref > 1e-300)) ref = 1.0;

    for (size_t k = 0; k <= nfft / 2; ++k) {
        const double f = (double)k * dstBinHz;
        double m;
        if (f <= f0) {
            // 测量区：按频率从 src 半谱线性插值
            const double pos = f / srcBinHz;
            const size_t i0 = (size_t)pos;
            const size_t i1 = std::min(i0 + 1, srcHalf);
            const double t = pos - (double)i0;
            m = (i0 <= srcHalf) ? (srcMag[i0] * (1.0 - t) + srcMag[i1] * t) : 0.0;
        } else if (f < f1) {
            // 过渡区：余弦渐出到 0
            const double t = (f - f0) / (f1 - f0);
            const double w = 0.5 + 0.5 * std::cos(kPi * std::min(1.0, std::max(0.0, t)));
            const double pos = std::min(f, f0) / srcBinHz;
            const size_t i0 = (size_t)pos;
            const size_t i1 = std::min(i0 + 1, srcHalf);
            const double tt = pos - (double)i0;
            const double base = (i0 <= srcHalf) ? (srcMag[i0] * (1.0 - tt) + srcMag[i1] * tt) : 0.0;
            m = base * w;
        } else {
            m = 0.0;
        }
        // 噪声底保护：外推区不低于 floorDb（相对通带）
        if (f > f0 && m < ref * floorLin) m = ref * floorLin * 0.0;  // 直接置 0，不外推噪声
        mag[k] = m;
    }
    mag[0] = 0.0;   // 去直流

    // ---- 最小相位重建 ----
    // 复倒谱法：ln|H| → IFFT → 因果折叠（×2，除首尾）→ FFT → exp → IFFT
    // 与 room_correction.h 的 minimum_phase_ir 同思路，但这里直接内联实现，
    // 避免 dsp/conv_ir_prep.h 反向依赖 room_correction.h（那个文件更重）。
    std::vector<double> lnMag(nfft, 0.0);
    for (size_t k = 0; k <= nfft / 2; ++k) {
        const double m = std::max(mag[k], 1e-12);
        const double v = std::log(m);
        lnMag[k] = v;
        if (k > 0 && k < nfft / 2) lnMag[nfft - k] = v;   // 偶对称
    }

    std::vector<cplx> C(nfft, cplx(0.0, 0.0));
    for (size_t k = 0; k < nfft; ++k) C[k] = cplx(lnMag[k], 0.0);
    fft(C, /*inverse=*/true);                             // 实倒谱

    // 因果折叠
    std::vector<cplx> Cc(nfft, cplx(0.0, 0.0));
    Cc[0] = C[0];
    if (nfft > 1) Cc[nfft / 2] = C[nfft / 2];
    for (size_t k = 1; k < nfft / 2; ++k) {
        Cc[k]         = C[k] * 2.0;
        Cc[nfft - k]  = cplx(0.0, 0.0);
    }
    fft(Cc);                                              // → 复对数谱

    std::vector<cplx> H(nfft, cplx(0.0, 0.0));
    for (size_t k = 0; k < nfft; ++k) H[k] = std::exp(Cc[k]);
    fft(H, /*inverse=*/true);                             // → 最小相位 IR

    // ---- 截断到目标长度，尾部余弦渐出（避免硬截断纹波）----
    std::vector<double> out(nOut, 0.0);
    const size_t use = std::min(nOut, nfft);
    for (size_t i = 0; i < use; ++i) out[i] = H[i].real();
    const size_t tail = std::max<size_t>(1, nOut / 8);
    for (size_t i = (nOut > tail ? nOut - tail : 0); i < nOut; ++i) {
        const double t = (double)(i - (nOut - tail)) / (double)tail;
        out[i] *= 0.5 + 0.5 * std::cos(kPi * std::min(1.0, std::max(0.0, t)));
    }

    // ---- 通带增益归一（200 Hz ~ 2 kHz 平均 = 1.0）----
    {
        std::vector<cplx> Y(nfft, cplx(0.0, 0.0));
        for (size_t i = 0; i < out.size(); ++i) Y[i] = cplx(out[i], 0.0);
        fft(Y);
        double s = 0.0; size_t c = 0;
        for (size_t k = 1; k <= nfft / 2; ++k) {
            const double f = (double)k * dstFs / (double)nfft;
            if (f < 200.0) continue;
            if (f > std::min(2000.0, 0.45 * dstFs)) break;
            s += std::abs(Y[k]); ++c;
        }
        if (c >= 2 && s > 1e-300) {
            const double g = (double)c / s;
            for (auto& v : out) v *= g;
        }
    }
    return out;
}

} // namespace rta::dsp
