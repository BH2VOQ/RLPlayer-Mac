// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPEQGeometry.h"
#include <math.h>

const double RLPEQLogFMin = 1.3010299956639813;   // log10(20)
const double RLPEQLogFMax = 4.301029995663981;    // log10(20000)
// 用户 2026-11-15 明确：「eq 的调整幅度是 ±24db」。
// 这个值必须与后端/web 完全一致，否则曲线画到画布边缘只到 ±18、而参数表能填 ±24，
// 两者对不上（用户拖到底以为到极限了，实际表格里还能再往上填）。
//   后端解析钳位：tools/rtaweb.cpp peq_parse_bands_param  clamp(g, -24, 24)
//   后端起算：    src/dsp/peq.h peq_design_band           clamp(gainDb, -24, 24)
//   web 表格：    ui_script.h  <input class=peqG min=-24 max=24>
//   web 拖拽：    peqCurveGainAt()  Math.max(-24, Math.min(24, …))
// ±12 只是"请复核"的软提醒（web 那行小字），不是量程。
const double RLPEQDbRange = 24.0;

static double RLPClampedFraction(double f) {
    if (!isfinite(f)) return 0.0;
    return f < 0.0 ? 0.0 : (f > 1.0 ? 1.0 : f);
}

double RLPEQFrequencyForPlotFraction(double xFraction) {
    const double x = RLPClampedFraction(xFraction);
    return pow(10.0, RLPEQLogFMin + x * (RLPEQLogFMax - RLPEQLogFMin));
}

double RLPEQPlotFractionForFrequency(double freq) {
    if (!isfinite(freq) || freq <= 0) return 0.0;
    const double lf = log10(freq);
    return RLPClampedFraction((lf - RLPEQLogFMin) / (RLPEQLogFMax - RLPEQLogFMin));
}

double RLPEQDbForPlotFraction(double yFraction) {
    return -RLPEQDbRange + RLPClampedFraction(yFraction) * (2.0 * RLPEQDbRange);
}

NSInteger RLPEQNearestBandIndex(NSArray<NSNumber *> *freqs, double xFraction) {
    if (freqs.count == 0) return -1;
    const double x = RLPClampedFraction(xFraction);
    NSInteger best = -1;
    double bestDist = 0.0;
    for (NSUInteger i = 0; i < freqs.count; ++i) {
        const double fx = RLPEQPlotFractionForFrequency(freqs[i].doubleValue);
        const double d = fabs(fx - x);
        if (best < 0 || d < bestDist) { best = (NSInteger)i; bestDist = d; }
    }
    return best;
}