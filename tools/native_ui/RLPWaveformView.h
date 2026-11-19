// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// RLPWaveformView.h — 正在播放页的原生波形视图（U2 包3）。
//
// 数据只来自 GET /api/waveform（U2 包2，bins=512）：peaks/rms/duration 由上层写入，
// 本视图**从不自己取数**。播放头由 /api/status 轮询写入（500 ms 级），只改这一个
// 浮点属性并重绘，绝不重算波形（重算会打落后端并白烧 CPU）。
//
// 画什么：
//   * 对称包络：竖直中线为基线，peaks 按数组最大值归一化后按比例画上下；
//   * 已播/未播双色：播放头左侧 = --acc，右侧 = --acc-weak；中线 = --line；
//   * 播放头竖线；
//   * 拖选高亮：选区 ≥0.5 s 才保留（A/B 段端点后端未实现时只做高亮，见 evidence）。
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface RLPWaveformView : NSView

/// /api/waveform 的 peaks（0..1 振幅；绘制时再按数组最大值归一化）。
@property (nonatomic, copy, nullable) NSArray<NSNumber *> *peaks;
/// /api/waveform 的 rms（与 peaks 同长度；保留为视图属性）。
@property (nonatomic, copy, nullable) NSArray<NSNumber *> *rms;
/// 波形覆盖时长（秒；CUE 分轨时是区间长度，不是全曲时长）。
@property (nonatomic) double duration;

/// 播放头 0..1（= /api/status 的 pos/dur，clamp 到 [0,1]）。只重绘，不发请求。
@property (nonatomic) double playheadFraction;

/// 是否有选区（拖选完成且 ≥0.5 s 才为 YES）。
@property (nonatomic, readonly, getter=isSelecting) BOOL selecting;
@property (nonatomic, readonly) double selectionStart;
@property (nonatomic, readonly) double selectionEnd;

/// 点击（未拖选）→ 上层换算成 POST /api/seek?pos=。
@property (nonatomic, copy, nullable) void (^onSeek)(double fraction);
/// 拖选 ≥0.5 s 才回调（本包只做高亮/留痕，不设 A/B 段端点）。
@property (nonatomic, copy, nullable) void (^onSelect)(double startFraction, double endFraction, double seconds);

- (void)setPeaks:(nullable NSArray<NSNumber *> *)peaks
              rms:(nullable NSArray<NSNumber *> *)rms
         duration:(double)duration;
- (void)clearWaveform;
- (void)clearSelection;

// ---- 判据接缝：绘制实现用的同一批函数（测试直接量几何/取色，不做像素取样）----
/// 第 bin 根包络柱的矩形：围绕中线对称、按最大峰值归一化、列宽 ≥1pt。
- (NSRect)envelopeRectForBin:(NSInteger)bin;
/// 第 bin 根的填充色：bin 中心在播放头左侧 = --acc，右侧 = --acc-weak。
- (NSColor *)envelopeColorForBin:(NSInteger)bin;

@end

NS_ASSUME_NONNULL_END
