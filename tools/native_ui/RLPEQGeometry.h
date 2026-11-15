// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
// EQ 曲线拖拽的纯几何映射（与绘制共用同一套坐标，见 RLPEqualizerView 的 drawRect）。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 20 Hz..20 kHz 的对数频率轴下限/上限（log10）。
extern const double RLPEQLogFMin;
extern const double RLPEQLogFMax;
/// 增益轴范围（±dB）。
extern const double RLPEQDbRange;

/// 水平位置（0..1 的 plot 归一化 x）→ 频率 Hz。
double RLPEQFrequencyForPlotFraction(double xFraction);

/// 频率 Hz → plot 归一化 x（0..1）。
double RLPEQPlotFractionForFrequency(double freq);

/// 竖直位置（0..1，0 = 底部）→ 增益 dB（范围 ±RLPEQDbRange）。
double RLPEQDbForPlotFraction(double yFraction);

/// 归一化 x → 最近频段的索引（没有频段时返回 -1）。
NSInteger RLPEQNearestBandIndex(NSArray<NSNumber *> *freqs, double xFraction);

NS_ASSUME_NONNULL_END