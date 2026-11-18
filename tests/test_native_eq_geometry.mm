// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
// 离线判据：EQ 曲线拖拽的几何映射（与 drawRect 同一套坐标）。
#import <AppKit/AppKit.h>
#import "RLPEQGeometry.h"
#include <cmath>
#include <cstdio>

// The target only links RLPEQGeometry.mm. Include the real views without
// linking the workbench or localization service (only the tooltip uses RLPTr).
#import "RLPEQFaderView.mm"
#import "RLPTheme.mm"
NSString *RLPTr(NSString *zh) { return zh; }

static int failures;
static void check(bool ok, const char *name) {
    printf("[%s] %s\n", ok ? "PASS" : "FAIL", name);
    if (!ok) ++failures;
}
static bool near(double a, double b, double tol) { return std::fabs(a - b) <= tol; }

static void checkFaderFields(RLPEQFaderView *fader, CGFloat width, const char *phase) {
    [fader setFrameSize:NSMakeSize(width, 200)];
    [fader setNeedsLayout:YES];
    [fader layoutSubtreeIfNeeded];

    NSUInteger visible = 0;
    NSTextField *previous = nil;
    for (NSUInteger i = 0; i < 20; ++i) {
        NSTextField *field = [fader valueFieldForBand:i];
        if (field && field.superview == fader && ![field isHiddenOrHasHiddenAncestor] &&
            NSWidth(field.frame) > 0 && NSHeight(field.frame) > 0 &&
            NSContainsRect(fader.bounds, field.frame)) {
            ++visible;
        }
        if (previous && field && NSMaxX(previous.frame) > NSMinX(field.frame)) {
            printf("[FAIL] %s: fields %lu/%lu overlap by %.2f pt\n", phase,
                   (unsigned long)i, (unsigned long)(i + 1),
                   NSMaxX(previous.frame) - NSMinX(field.frame));
            ++failures;
        }
        previous = field;
    }
    char label[192];
    snprintf(label, sizeof(label), "%s (%.0f pt): %lu/20 visible, positive-width value fields",
             phase, width, (unsigned long)visible);
    check(visible == 20 && ![fader valueFieldForBand:20], label);
}

int main() { @autoreleasepool {
    [NSApplication sharedApplication];

    check(near(RLPEQFrequencyForPlotFraction(0.0), 20.0, 0.05), "E1 左端 = 20 Hz");
    check(near(RLPEQFrequencyForPlotFraction(1.0), 20000.0, 5.0), "E2 右端 = 20 kHz");
    check(near(RLPEQPlotFractionForFrequency(1000.0), 0.5663, 0.01), "E3 1 kHz 落在 x≈0.566（20Hz..20kHz 三个十倍频程，不是线性轴）");
    check(near(RLPEQFrequencyForPlotFraction(RLPEQPlotFractionForFrequency(2400.0)), 2400.0, 1.0), "E4 频率-x-频率 往返一致");
    check(near(RLPEQDbForPlotFraction(0.5), 0.0, 1e-6), "E5 竖直中点 = 0 dB");
    // 用户 2026-11-15 明确：EQ 调整幅度 = ±24 dB（与后端钳位 / web 表格 min/max 同一口径）。
    check(near(RLPEQDbForPlotFraction(1.0), 24.0, 1e-6), "E6 顶部 = +24 dB（用户明确的量程）");
    check(near(RLPEQDbForPlotFraction(0.0), -24.0, 1e-6), "E7 底部 = -24 dB");
    check(near(RLPEQDbForPlotFraction(2.0), 24.0, 1e-6), "E8 越界 y 被夹在 +24");
    check(near(RLPEQDbForPlotFraction(-1.0), -24.0, 1e-6), "E9 越界 y 被夹在 -24");

    NSArray<NSNumber *> *freqs = @[ @20, @50, @100, @200, @500, @1000, @2000, @4000, @8000, @16000 ];
    check(RLPEQNearestBandIndex(freqs, 0.0) == 0, "E10 最左端选中第 1 段");
    check(RLPEQNearestBandIndex(freqs, RLPEQPlotFractionForFrequency(1000.0)) == 5, "E11 1 kHz 处选中该段（不是邻段）");
    check(RLPEQNearestBandIndex(@[], 0.5) == -1, "E12 没有频段时返回 -1（不崩、不乱选）");
    check(near(RLPEQDbForPlotFraction(0.75), 12.0, 1e-6), "E13 y=0.75 对应 +12 dB（±24 量程的 3/4 高度）");

    RLPEQFaderView *fader = [[RLPEQFaderView alloc] initWithFrame:NSMakeRect(0, 0, 1000, 200)];
    fader.bandFreqs = @[ @20, @31.5, @50, @80, @125, @200, @315, @500, @630, @800,
                         @1000, @1250, @1600, @2000, @3150, @5000, @6300, @8000, @12500, @20000 ];
    checkFaderFields(fader, 1000, "E14 wide baseline");
    // A 900 pt main window leaves about 602 pt for the Pro workbench fader.
    checkFaderFields(fader, 602, "E15 Pro workbench at 900 pt");
    checkFaderFields(fader, 1000, "E16 wide recovery");

    printf("eq geometry: %d failures\n", failures);
    return failures ? 1 : 0;
} }