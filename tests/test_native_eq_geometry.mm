// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
// 离线判据：EQ 曲线拖拽的几何映射（与 drawRect 同一套坐标）。
#import <AppKit/AppKit.h>
#import "RLPEQGeometry.h"
#include <cmath>
#include <cstdio>

static int failures;
static void check(bool ok, const char *name) {
    printf("[%s] %s\n", ok ? "PASS" : "FAIL", name);
    if (!ok) ++failures;
}
static bool near(double a, double b, double tol) { return std::fabs(a - b) <= tol; }

int main() { @autoreleasepool {
    [NSApplication sharedApplication];

    check(near(RLPEQFrequencyForPlotFraction(0.0), 20.0, 0.05), "E1 左端 = 20 Hz");
    check(near(RLPEQFrequencyForPlotFraction(1.0), 20000.0, 5.0), "E2 右端 = 20 kHz");
    check(near(RLPEQPlotFractionForFrequency(1000.0), 0.5663, 0.01), "E3 1 kHz 落在 x≈0.566（20Hz..20kHz 三个十倍频程，不是线性轴）");
    check(near(RLPEQFrequencyForPlotFraction(RLPEQPlotFractionForFrequency(2400.0)), 2400.0, 1.0), "E4 频率-x-频率 往返一致");
    check(near(RLPEQDbForPlotFraction(0.5), 0.0, 1e-6), "E5 竖直中点 = 0 dB");
    check(near(RLPEQDbForPlotFraction(1.0), 18.0, 1e-6), "E6 顶部 = +18 dB");
    check(near(RLPEQDbForPlotFraction(0.0), -18.0, 1e-6), "E7 底部 = -18 dB");
    check(near(RLPEQDbForPlotFraction(2.0), 18.0, 1e-6), "E8 越界 y 被夹在 +18");
    check(near(RLPEQDbForPlotFraction(-1.0), -18.0, 1e-6), "E9 越界 y 被夹在 -18");

    NSArray<NSNumber *> *freqs = @[ @20, @50, @100, @200, @500, @1000, @2000, @4000, @8000, @16000 ];
    check(RLPEQNearestBandIndex(freqs, 0.0) == 0, "E10 最左端选中第 1 段");
    check(RLPEQNearestBandIndex(freqs, RLPEQPlotFractionForFrequency(1000.0)) == 5, "E11 1 kHz 处选中该段（不是邻段）");
    check(RLPEQNearestBandIndex(@[], 0.5) == -1, "E12 没有频段时返回 -1（不崩、不乱选）");
    check(near(RLPEQDbForPlotFraction(0.75), 9.0, 1e-6), "E13 y=0.75 对应 +9 dB（拖动手柄的实测量程）");

    printf("eq geometry: %d failures\n", failures);
    return failures ? 1 : 0;
} }