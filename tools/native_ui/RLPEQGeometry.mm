// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPEQGeometry.h"
#include <math.h>

const double RLPEQLogFMin = 1.3010299956639813;   // log10(20)
const double RLPEQLogFMax = 4.301029995663981;    // log10(20000)
const double RLPEQDbRange = 18.0;

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