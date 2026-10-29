// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
#pragma once
#include "dsp/resampler.h"
#include <stdexcept>
#include <cmath>
#include <vector>

namespace rta::dsp {
// IR is convolved before main program resampling, so target is the input material rate.
// Compensate the resampler's own delay, preserve physical IR delay, and scale by
// src/dst to preserve transfer-function DC gain (IR coefficients, not audio amplitude).
// For short IRs (< 200 taps), the resampler's impulse response tail is preserved
// to prevent DC gain (sum of coefficients) deviation from truncation.
inline std::vector<double> resample_ir(const std::vector<double>& ir, uint32_t src, uint32_t dst) {
    if (!src || !dst) throw std::invalid_argument("IR sample rate is zero");
    if (ir.empty() || src == dst) return ir;
    ResamplerConfig cfg; cfg.inRate=src;cfg.outRate=dst;cfg.channels=1;
    cfg.minTapsPerInput=128;cfg.totalTaps=128;cfg.attenDb=120;cfg.transition=.02;
    PolyphaseResampler rs(cfg);
    const double ratio=(double)dst/src;
    const size_t delay=(size_t)std::llround(rs.latencyInputSamples()*ratio);
    const size_t baseLen=(size_t)std::ceil(ir.size()*ratio);
    const size_t tail=(ir.size() < 200) ? (size_t)std::ceil(rs.latencyInputSamples()*ratio) : 0;
    const size_t outLen=baseLen + tail;

    std::vector<double> input=ir;
    input.resize(ir.size() + (size_t)std::ceil(rs.latencyInputSamples()*2) + 4 + (size_t)std::ceil((double)tail / ratio) + 10, 0.0);
    std::vector<double> output(rs.maxOutFrames(input.size()));
    const double* ip=input.data();double* op=output.data();
    const size_t got=rs.process(&ip,input.size(),&op);
    if(got<delay+outLen) throw std::runtime_error("IR resampling produced too few samples");
    std::vector<double> result(outLen);
    for(size_t i=0;i<outLen;++i) result[i]=output[i+delay]/ratio;
    return result;
}
} // namespace rta::dsp
