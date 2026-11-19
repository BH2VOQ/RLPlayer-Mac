// SPDX-FileCopyrightText: 2026 rainlain <https://github.com/okhuoyanyan>
// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// resampler.h — 多相 sinc 重采样引擎（任意有理比率 L/M）
//
// 设计要点：
//  * 原型 FIR 在"内插域"设计，长度为 L 的整数倍，按相位拆分以获得 O(T) 每输出样本开销
//  * 内部全程 double；关键路径可再升级为 double-double（128bit 精度）以杜绝累积误差
//  * 支持任意 inRate/outRate（自动约分为最简 L/M），支持多声道
//  * inRate == outRate 时按位透传（比特完美）
#pragma once
#include "fp_strict.h"   // 261030-01 审计：DSP 路径严格 IEEE
#include "gpu_pref.h"
#include "filter_design.h"
#include "filter_families.h"
#include "platform/dynlib.h"   // GPU 升频按需加载 rtagpu.dll —— 本目录不再直接碰平台 API
#include <array>
#include <vector>
#include <cmath>
#include <cstdint>
#include <cstddef>
#include <numeric>
#include <algorithm>
#include <memory>
#include <limits>
#include <climits>
#include <stdexcept>
#include <string>

namespace rta::dsp {

struct ResamplerConfig {
    uint32_t inRate   = 44100;
    uint32_t outRate  = 384000;
    int      channels = 2;

    // 原型总抽头数（内插域），会向上取整到 L 的整数倍。
    // 默认使用 262144 抽头；命名滤波器的抽头配置见 filter_families.h。
    int      totalTaps  = 262144;
    double   attenDb    = 180.0;   // 目标阻带衰减
    // 过渡带占比：截止点相对理想 Nyquist 回退的比例（0 = 砖墙理想，越大地越平缓）
    double   transition = 0.04;

    // ---- 命名滤波器（Round 56）----
    WindowKind window       = WindowKind::Kaiser;   // Kaiser = 原有行为，完全等价
    PhaseKind  phase        = PhaseKind::Linear;

    // ---- 切趾滤波（Apodizing）----
    bool   apodizing   = false;
    double apodF1      = 0.0;   // 滚降起始相对输入 Nyquist 比例（例如 18.4k / 22.05k）
    double apodF2      = 0.0;   // 滚降终止相对输入 Nyquist 比例（例如 21.8k / 22.05k）

    // ---- 两段式升频 ----
    bool twoStage   = false;
    bool allowAutomaticCascade = false;
    bool autoTaps = false;
    bool highPrecisionDesign = false;
    double designPhaseMix = -1.0;
    int  stage2Taps = 64;      // 第二级每相位抽头数（过渡带很宽，不需要长）

    // ---- 每输入样本内核长度（tapsPerInput）----
    int minTapsPerInput = 0;
    bool applyTapFloor = true;
    // 内核长度 × L 的上限（防御：L 很大时系数表会膨胀）。0 = 不限制。
    // 对齐 Windows v3.3.11：2^24（16.8M 抽头），支持 tight-lp T=1600 @ 44.1->384k (2.05M) 等。
    int maxPrototypeTaps = 1 << 24;
};

// 把 FilterPreset 的全部参数应用到 ResamplerConfig
inline void apply_preset(ResamplerConfig& cfg, const FilterPreset& fp) {
    cfg.totalTaps  = fp.taps;
    cfg.transition = fp.transition;
    cfg.attenDb    = std::max(fp.attenDb, preset_ceiling_db(fp.window));
    cfg.window     = fp.window;
    cfg.phase      = fp.phase;
    cfg.twoStage   = fp.twoStage;
    cfg.apodizing  = fp.apodizing;
    cfg.apodF1     = fp.apodF1;
    cfg.apodF2     = fp.apodF2;
    cfg.minTapsPerInput = fp.apodizing
        ? apod_quality_taps(fp.apodF1, fp.apodF2, fp.window == WindowKind::Gaussian,
                            cfg.attenDb, fp.tapsPerInput)
        : fp.tapsPerInput;
    if (fp.twoStage && fp.stage2Taps > 0) cfg.stage2Taps = fp.stage2Taps;
}

enum class ResamplePurpose { Pcm, Dsd };
inline void apply_resample_purpose(ResamplerConfig& cfg, ResamplePurpose purpose) {
    if (purpose == ResamplePurpose::Dsd) cfg.twoStage = true;
}

struct ResamplerStagePlan {
    ResamplerConfig config;
    int L = 1, M = 1, T = 0;
    uint64_t coefficientCount = 0;
};

struct ResamplerPlan {
    std::array<ResamplerStagePlan, 2> stages;
    size_t stageCount = 0;
    int L = 1, M = 1;
    uint64_t coefficientCount = 0, cachePayloadBytes = 0, designPeakBytes = 0;
};

inline void validate_resampler_config(const ResamplerConfig& c) {
    if (!c.inRate || !c.outRate)
        throw std::invalid_argument("Resampler sample rates must be positive: inRate=" +
            std::to_string(c.inRate) + " outRate=" + std::to_string(c.outRate));
    if (c.channels < 1 || c.channels > 64)
        throw std::invalid_argument("Resampler supports 1 to 64 channels");
    if (c.totalTaps < 1 || c.stage2Taps < 1 || c.minTapsPerInput < 0 || c.maxPrototypeTaps < 0)
        throw std::invalid_argument("Resampler tap counts and budgets are invalid");
    if (!std::isfinite(c.transition) || c.transition < 0.0 || c.transition >= 1.0)
        throw std::invalid_argument("Resampler transition must be finite and in [0,1)");
    if (!std::isfinite(c.attenDb) || c.attenDb < 0.0 || c.attenDb > 1000.0)
        throw std::invalid_argument("Resampler attenuation must be finite and in [0,1000] dB");
    if (int(c.window) < 0 || int(c.window) > int(WindowKind::Hann) ||
        int(c.phase) < 0 || int(c.phase) > int(PhaseKind::Intermediate))
        throw std::invalid_argument("Unknown resampler window or phase");
    if (!std::isfinite(c.designPhaseMix) ||
        (c.designPhaseMix != -1.0 && (c.designPhaseMix < 0.0 || c.designPhaseMix > 1.0)))
        throw std::invalid_argument("Invalid resampler phase mix");
    if (!std::isfinite(c.apodF1) || !std::isfinite(c.apodF2) ||
        (c.apodizing && !(c.apodF1 >= 0.0 && c.apodF1 < c.apodF2 && c.apodF2 <= 1.0)))
        throw std::invalid_argument("Invalid resampler apodization edges");
    const auto g = std::gcd(c.inRate, c.outRate);
    if (c.inRate / g > uint32_t(INT_MAX) || c.outRate / g > uint32_t(INT_MAX))
        throw std::length_error("Reduced resampler ratio exceeds the supported integer range");
}

inline int resampler_tap_product(int t, int l) {
    if (t < 1 || l < 1 || int64_t(t) * l > INT_MAX)
        throw std::length_error("Resampler coefficient count overflow");
    return t * l;
}

inline ResamplerConfig resolve_auto_taps(const ResamplerConfig& requested) {
    validate_resampler_config(requested);
    ResamplerConfig c = requested;
    if (c.designPhaseMix < 0.0) c.designPhaseMix = phase_mix();
    if (!c.autoTaps) return c;
    c.autoTaps = false;
    if (c.inRate == c.outRate) return c;
    if (c.transition == 0.0 && !c.apodizing && c.minTapsPerInput == 0)
        throw std::invalid_argument("Automatic tap design requires a positive transition");
    const uint32_t bandRate = std::min(c.inRate, c.outRate);
    int sourceT = c.minTapsPerInput > 0 ? c.minTapsPerInput :
        solve_taps_per_phase(c.window, c.transition, c.apodizing,
            c.apodF1, c.apodF2, c.totalTaps, 0, double(bandRate));
    if (c.outRate < c.inRate && c.phase == PhaseKind::Linear && !c.apodizing &&
        (c.window == WindowKind::Kaiser || (c.window == WindowKind::BlackmanHarris && c.attenDb > 100.0))) {
        const double oldAttenuation = c.attenDb;
        const auto m = c.inRate / std::gcd(c.inRate, c.outRate);
        c.attenDb = std::ceil(oldAttenuation + 20.0 * std::log10(double(m)) + 6.0);
        const int nominal = solve_taps_per_phase(c.window, c.transition, false, 0, 0, c.totalTaps, 0, double(bandRate));
        const double required = std::ceil(double(nominal) * (c.attenDb - 8.0) / std::max(1.0, oldAttenuation - 8.0));
        if (!std::isfinite(required) || required > INT_MAX)
            throw std::length_error("Automatic alias rejection requires too many taps");
        sourceT = std::max(sourceT, int(required));
        c.highPrecisionDesign = true;
    }
    const uint64_t count = (uint64_t(sourceT) * std::max(c.inRate, c.outRate) + c.outRate - 1) / c.outRate;
    if (count > uint64_t(INT_MAX))
        throw std::length_error("Automatic source support exceeds the tap integer range");
    c.minTapsPerInput = int(count);
    return c;
}

inline ResamplerStagePlan plan_resampler_stage(const ResamplerConfig& c) {
    validate_resampler_config(c);
    ResamplerStagePlan p;
    p.config = c;
    const auto g = std::gcd(c.inRate, c.outRate);
    p.L = int(c.outRate / g);
    p.M = int(c.inRate / g);
    int t = c.totalTaps / p.L;
    if (c.minTapsPerInput > 0) t = c.minTapsPerInput;
    else if (c.transition > 0.0) {
        const double low = 21.13 / c.transition + 0.5, high = 2.0 * 21.13 / c.transition + 0.5;
        if (!std::isfinite(high) || high > INT_MAX)
            throw std::length_error("Transition requires an unrepresentable tap count");
        const int tMin = std::max(4, int(low)), tMax = std::max(tMin, int(high));
        if (c.phase == PhaseKind::Linear && t > tMax) t = tMax;
        if (c.applyTapFloor && t < tMin) t = tMin;
    }
    p.T = std::max(4, t);
    p.coefficientCount = uint64_t(resampler_tap_product(p.T, p.L));
    if (c.maxPrototypeTaps > 0 && p.coefficientCount > uint64_t(c.maxPrototypeTaps))
        throw std::runtime_error("Requested FIR exceeds the coefficient budget; quality was not reduced. inRate=" +
            std::to_string(c.inRate) + " outRate=" + std::to_string(c.outRate) + " L=" + std::to_string(p.L) +
            " M=" + std::to_string(p.M) + " T=" + std::to_string(p.T) + " taps=" + std::to_string(p.coefficientCount) +
            " budget=" + std::to_string(c.maxPrototypeTaps) + ". Use a cascade or explicitly change the filter configuration.");
    return p;
}

inline ResamplerPlan plan_resampler(const ResamplerConfig& requested) {
    const auto cfg = resolve_auto_taps(requested);
    ResamplerPlan p;
    const auto g = std::gcd(cfg.inRate, cfg.outRate);
    p.L = int(cfg.outRate / g);
    p.M = int(cfg.inRate / g);
    if (p.L == 1 && p.M == 1) return p;
    const bool rational = p.M != 1 && uint64_t(cfg.outRate) >= uint64_t(cfg.inRate) * 2;
    int f = 1;
    if ((cfg.twoStage || (cfg.allowAutomaticCascade && rational)) && ((p.M == 1 && p.L >= 8) || rational))
        for (int candidate : {4, 3, 2})
            if (p.L % candidate == 0 && p.L / candidate >= (rational ? 1 : 2)) { f = candidate; break; }
    if (f > 1) {
        const uint64_t mid = uint64_t(cfg.inRate) * f;
        if (mid > UINT32_MAX) throw std::length_error("Cascade intermediate sample rate overflow");
        const int t1 = cfg.minTapsPerInput > 0 ? cfg.minTapsPerInput : std::max(4, cfg.totalTaps / p.L);
        ResamplerConfig a = cfg, b = cfg;
        a.twoStage = b.twoStage = false;
        a.allowAutomaticCascade = b.allowAutomaticCascade = false;
        a.applyTapFloor = b.applyTapFloor = true;
        a.outRate = uint32_t(mid);
        a.totalTaps = resampler_tap_product(t1, f);
        b.inRate = uint32_t(mid);
        b.minTapsPerInput = cfg.stage2Taps;
        b.transition = .30;
        b.apodizing = false;
        b.apodF1 = b.apodF2 = 0.0;
        const int l2 = p.L / f;
        if (rational) {
            b.window = WindowKind::Kaiser;
            b.attenDb = std::max(286.0, cfg.attenDb + 6.0);
            const double width = .5 * b.transition / double(std::max(l2, p.M));
            const int prototype = kaiser_taps_for(b.attenDb, width);
            const double count = std::ceil(1.2 * double(prototype) / double(l2));
            if (count > INT_MAX) throw std::length_error("Cascade transition requires too many taps");
            b.minTapsPerInput = std::max(cfg.stage2Taps, int(count));
        }
        b.totalTaps = resampler_tap_product(b.minTapsPerInput, l2);
        p.stages[0] = plan_resampler_stage(a);
        p.stages[1] = plan_resampler_stage(b);
        p.stageCount = 2;
    } else {
        p.stages[0] = plan_resampler_stage(cfg);
        p.stageCount = 1;
    }
    p.coefficientCount = 0;
    for (size_t i = 0; i < p.stageCount; ++i)
        p.coefficientCount += p.stages[i].coefficientCount;
    p.cachePayloadBytes = p.coefficientCount * sizeof(double);
    return p;
}

class PolyphaseResampler {
public:
    explicit PolyphaseResampler(const ResamplerConfig& requested) : cfg_(resolve_auto_taps(requested)) {
        check_design_cancel();
        const ResamplerConfig& cfg = cfg_;
        const auto plan = plan_resampler(cfg);
        L_ = plan.L;
        M_ = plan.M;
        ch_ = cfg.channels > 0 ? cfg.channels : 2;
        if (plan.stageCount == 0) { passthrough_ = true; return; }
        if (plan.stageCount == 2) {
            stage1_ = std::make_unique<PolyphaseResampler>(plan.stages[0].config);
            stage2_ = std::make_unique<PolyphaseResampler>(plan.stages[1].config);
            const int64_t t1 = stage1_->tapsPerPhase();
            const int64_t t2 = stage2_->tapsPerPhase();
            const int64_t f1 = std::max(1, stage1_->upFactor());
            const int64_t eff = t1 + (t2 + f1 - 1) / f1;
            T_ = (eff > INT_MAX) ? INT_MAX : int(eff);
            tmp_.clear();
            tmpP_.assign((size_t)ch_, nullptr);
            return;
        }

        // 内插域中：输入 Nyquist 位于 1/L，输出 Nyquist 位于 1/M，取较小者
        const double idealCutoff = std::min(1.0 / (double)L_, 1.0 / (double)M_);
        // 截止点（-6 dB 点）放在过渡带中点，避免通带边缘下垂
        const double cutoff = idealCutoff * (1.0 - cfg.transition * 0.5);

        T_ = plan.stages[0].T;
        const int total = int(plan.stages[0].coefficientCount);
        const double designPhaseMix = cfg.designPhaseMix;

        std::vector<double> proto;
        if (cfg.window == WindowKind::Kaiser && cfg.phase == PhaseKind::Linear && !cfg.apodizing) {
            // 原有路径：参数化 Kaiser sinc
            LowpassSpec spec;
            spec.taps    = total;
            spec.cutoff  = cutoff;
            spec.attenDb = cfg.attenDb;
            proto = design_lowpass(spec);
        } else {
            // 命名滤波器路径：使用有限支撑级联相位 + DD 精度卷积 + 切趾透传
            FirSpec fs;
            fs.taps       = total;
            fs.cutoff     = cutoff;
            fs.attenDb    = cfg.attenDb;
            fs.window     = cfg.window;
            fs.apodizing  = cfg.apodizing;
            if (cfg.apodizing) {
                fs.apodF1 = cfg.apodF1 * idealCutoff;
                fs.apodF2 = cfg.apodF2 * idealCutoff;
            }
            const double t = (cfg.transition > 0.0) ? cfg.transition : 0.0;
            const double passEdge = (t > 0.0 && t < 1.0)
                                  ? cutoff * (1.0 - t) / (1.0 - t * 0.5) : 0.0;
            proto = design_phased_fir(fs.taps, fs.cutoff, fs.attenDb, fs.window,
                                      fs.apodizing, fs.apodF1, fs.apodF2,
                                      cfg.phase, designPhaseMix, passEdge);
            if ((int)proto.size() != total) proto.resize((size_t)total, 0.0);
        }
        check_design_cancel();

        // 关键：有理 L/M 转换中，原型在内插域的直流增益为 L
        const double phaseGain = (double)L_;
        for (auto& v : proto) v *= phaseGain;

        // 相位主序布局：phases_[p][u] = h[p + u*L]
        phases_.assign((size_t)L_, std::vector<double>((size_t)T_));
        for (int p = 0; p < L_; ++p)
            for (int u = 0; u < T_; ++u)
                phases_[(size_t)p][(size_t)u] = proto[(size_t)(p + u * L_)];

        // GPU 需要连续的 [L][T] 相位表
        phases_flat_.resize((size_t)L_ * (size_t)T_);
        for (int pp = 0; pp < L_; ++pp)
            std::copy(phases_[(size_t)pp].begin(), phases_[(size_t)pp].end(),
                      phases_flat_.begin() + (ptrdiff_t)((size_t)pp * (size_t)T_));
        if (gpu_invalidate_) gpu_invalidate_();   // 换了滤波器 -> 显存里的相位表作废
        hist_.assign((size_t)ch_, std::vector<double>());
        for (auto& hh : hist_) hh.reserve((size_t)T_ * 2);
        outIdx_ = 0;
        inAbs_  = 0;                           // 下一个待接收输入样本的绝对序号
    }

    bool passthrough() const { return passthrough_; }
    int  tapsPerPhase() const { return T_; }
    int  stage1_taps_per_phase() const { return stage1_ ? stage1_->tapsPerPhase() : T_; }
    int  stage2_taps_per_phase() const { return stage2_ ? stage2_->tapsPerPhase() : 0; }
    size_t coefficient_count() const {
        return stage1_ ? stage1_->coefficient_count() + stage2_->coefficient_count()
                       : size_t(T_) * size_t(L_);
    }

    // 量测/回归钩子：把相位表还原成【内插域原型】(含 ×L 直流增益)
    void prototype_into(std::vector<double>& out) const {
        if (stage1_) {
            ResamplerConfig mono = cfg_; mono.channels = 1;
            PolyphaseResampler probe(mono);
            probe.M_ = 1;
            probe.stage2_->M_ = 1;
            const size_t frames = (size_t)std::ceil(tailInputSamples()) + 1;
            std::vector<double> impulse(frames, 0.0);
            impulse[0] = 1.0;
            out.resize(probe.maxOutFrames(frames));
            const double* in[] = { impulse.data() };
            double* dst[] = { out.data() };
            probe.process(in, frames, dst);
            out.resize((size_t)std::llround(tailInputSamples() * (double)L_) + 1);
            return;
        }
        out.assign((size_t)T_ * (size_t)L_, 0.0);
        for (int p = 0; p < L_; ++p)
            for (int u = 0; u < T_; ++u)
                out[(size_t)(p + u * L_)] = phases_[(size_t)p][(size_t)u];
    }

    // 是否用 GPU 做多相相乘加（需要 rtagpu.dll；不可用则自动回退 CPU）
    void set_use_gpu(bool on) {
        useGpu_ = on;
        if (stage1_) stage1_->set_use_gpu(on);
        if (stage2_) stage2_->set_use_gpu(on);
        if (on) load_gpu();
    }
    bool gpu_active() const {
        if (stage1_ || stage2_)
            return (stage1_ && stage1_->gpu_active()) || (stage2_ && stage2_->gpu_active());
        return useGpu_ && gpu_resample_ != nullptr;
    }
    bool two_stage() const { return stage1_ != nullptr; }
    const ResamplerConfig& config() const { return cfg_; }
    const PolyphaseResampler* first_stage() const { return stage1_.get(); }
    const PolyphaseResampler* second_stage() const { return stage2_.get(); }
    int  stage1_factor() const { return stage1_ ? stage1_->upFactor() : L_; }
    int  upFactor() const { return L_; }
    int  downFactor() const { return M_; }

    double latencyInputSamples() const {
        if (stage1_) {
            const double l1 = stage1_->latencyInputSamples();
            const double l2mid = stage2_->latencyInputSamples();
            const double midRate = (double)stage1_->cfg_.inRate * (double)stage1_->upFactor();
            const double inRate  = (double)cfg_.inRate;
            return l1 + (midRate > 0.0 ? l2mid * inRate / midRate : 0.0);
        }
        if (passthrough_ || cfg_.phase != PhaseKind::Linear) return 0.0;
        return ((double)T_ * (double)L_ - 1.0) / (2.0 * (double)L_);
    }

    double tailInputSamples() const {
        if (stage1_)
            return stage1_->tailInputSamples() +
                   stage2_->tailInputSamples() / (double)stage1_->upFactor();
        if (passthrough_) return 0.0;
        return ((double)T_ * (double)L_ - 1.0) / (double)L_;
    }

    // 处理一块输入。out 必须至少有 maxOutFrames(inFrames) 容量。
    // in/out 为每声道指针数组。
    size_t process(const double* const* in, size_t inFrames,
                   double* const* out) {
        // ---- 两段式：第一级 -> 中间缓冲 -> 第二级 ----
        if (stage1_) {
            if (inFrames == 0) return 0;
            const size_t cap = stage1_->maxOutFrames(inFrames);
            if (tmp_.size() < cap * (size_t)ch_) {
                tmp_.assign(cap * (size_t)ch_, 0.0);
                for (int c = 0; c < ch_; ++c) tmpP_[(size_t)c] = tmp_.data() + (size_t)c * cap;
            }
            const size_t n1 = stage1_->process(in, inFrames, tmpP_.data());
            return stage2_->process(tmpP_.data(), n1, out);
        }
        if (passthrough_) {
            for (int c = 0; c < ch_; ++c)
                std::copy(in[c], in[c] + inFrames, out[c]);
            return inFrames;
        }
        if (inFrames == 0) return 0;

        // 历史缓冲中第一个样本的绝对序号（追加新输入之前计算）
        const int64_t firstAbs = inAbs_ - (int64_t)hist_[0].size();

        for (int c = 0; c < ch_; ++c) {
            auto& hh = hist_[(size_t)c];
            hh.insert(hh.end(), in[c], in[c] + inFrames);
        }
        const int64_t lastAbs = inAbs_ + (int64_t)inFrames - 1;
        inAbs_ += (int64_t)inFrames;

        // ---- 1) 先收集本块所有输出样本的 (base, phase) ----
        bases_.clear(); phs_.clear();
        for (;;) {
            const int64_t num = outIdx_ * (int64_t)M_;
            const int64_t i   = num / L_;
            if (i > lastAbs) break;
            bases_.push_back((int)(i - firstAbs));
            phs_.push_back((int)(num % L_));
            ++outIdx_;
        }
        const size_t produced = bases_.size();
        if (produced == 0) return 0;

        // ---- 2) 计算 ----
        bool gpuDone = false;
        if (useGpu_ && gpu_resample_) {
            const size_t hl = hist_[0].size();
            if (hl > 0) {
                flat_.resize((size_t)ch_ * hl);
                for (int c = 0; c < ch_; ++c)
                    std::copy(hist_[(size_t)c].begin(), hist_[(size_t)c].end(),
                              flat_.begin() + (ptrdiff_t)((size_t)c * hl));
                inter_.resize(produced * (size_t)ch_);
                const int rc = gpu_resample_(flat_.data(), ch_, (long long)hl,
                                             phases_flat_.data(), L_, T_,
                                             bases_.data(), phs_.data(),
                                             (long long)produced, inter_.data());
                if (rc == (int)produced) {
                    for (size_t n = 0; n < produced; ++n)
                        for (int c = 0; c < ch_; ++c)
                            out[c][n] = inter_[n * (size_t)ch_ + (size_t)c];
                    gpuDone = true;
                }
            }
        }

        // CPU 路径（也是 GPU 不可用时的回退）
        if (!gpuDone) {
            for (size_t n = 0; n < produced; ++n) {
                const size_t base = (size_t)bases_[n];
                const int p = phs_[n];
                const int uEnd = (base + 1 < (size_t)T_) ? (int)(base + 1) : T_;
                for (int c = 0; c < ch_; ++c) {
                    const auto& hh = hist_[(size_t)c];
                    const auto& ph = phases_[(size_t)p];
                    double acc = 0.0;
                    for (int u = 0; u < uEnd; ++u)
                        acc += ph[(size_t)u] * hh[base - (size_t)u];
                    out[c][n] = acc;
                }
            }
        }

        // ---- 3) 裁剪历史 ----
        for (int c = 0; c < ch_; ++c) {
            auto& hh = hist_[(size_t)c];
            if (hh.size() > (size_t)T_)
                hh.erase(hh.begin(), hh.end() - (ptrdiff_t)T_);
        }
        return produced;
    }

    // 输出缓冲上界
    size_t maxOutFrames(size_t inFrames) const {
        if (stage1_) return stage2_->maxOutFrames(stage1_->maxOutFrames(inFrames));
        if (passthrough_) return inFrames;
        return (size_t)(((double)inFrames * (double)L_) / (double)M_) + (size_t)L_ + 8;
    }

    void reset() {
        if (stage1_) { stage1_->reset(); stage2_->reset(); return; }
        for (auto& hh : hist_) hh.clear();
        outIdx_ = 0; inAbs_ = 0; histHeld_ = 0;
        if (gpu_invalidate_) gpu_invalidate_();   // 设备侧也要清，否则跳转后拖尾
    }

private:
    ResamplerConfig cfg_;
    int L_ = 1, M_ = 1, T_ = 0, ch_ = 2;
    bool passthrough_ = false;
    // ---- GPU 做多相乘加的桥接 ----
    using GpuResampleFn = int (*)(const double*, int, long long, const double*, int, int,
                                  const int*, const int*, long long, double*);
    using GpuVoidFn = void (*)();
    bool            useGpu_ = false;
    GpuResampleFn   gpu_resample_ = nullptr;
    GpuVoidFn       gpu_invalidate_ = nullptr;
    bool            gpuTried_ = false;
    std::vector<double> phases_flat_, flat_, inter_;
    std::vector<int>    bases_, phs_;

    void load_gpu() {
        if (gpuTried_) return;
        gpuTried_ = true;
        // 按 GPU 后端偏好找 DLL：AMD=rtagpu.dll，NVIDIA=rtagpu_cuda.dll，自动两个都试
        // 逐个候选尝试：HIP → D3D12 → CUDA（macOS 上只有一个 Metal 候选）。
        // 某个库存在但 kernel 不可执行时必须继续试下一个。
        // 候选名是 std::string（平台文件名映射的结果，见 gpu_pref.h）。
        for (const auto& nm : gpu_dll_candidates()) {
            rta::platform::SharedLib lib;
            if (!lib.open(nm.c_str())) continue;
            auto avail = (int (*)())lib.symbol("rta_gpu_available");
            if (avail && avail() != 1) { lib.close(); continue; }
            auto res = (GpuResampleFn)lib.symbol("rta_gpu_resample");
            auto inv = (GpuVoidFn)lib.symbol("rta_gpu_resample_invalidate");
            if (!res) { lib.close(); continue; }
            gpu_resample_ = res; gpu_invalidate_ = inv;
            // 与迁移前一致：模块永久保持加载。多个重采样器实例各自持有取到的函数指针，
            // 一旦卸载（FreeLibrary）就会变成野指针 —— 所以这里放弃所有权而不是留着析构。
            lib.detach();
            return;
        }
    }
    // 两段式下的两级（本级不再自己滤波）
    std::unique_ptr<PolyphaseResampler> stage1_, stage2_;
    std::vector<double>  tmp_;
    std::vector<double*> tmpP_;

    std::vector<std::vector<double>> phases_;
    std::vector<std::vector<double>> hist_;
    int64_t outIdx_ = 0;
    int64_t inAbs_  = 0;
    int     histHeld_ = 0;
};

} // namespace rta::dsp
