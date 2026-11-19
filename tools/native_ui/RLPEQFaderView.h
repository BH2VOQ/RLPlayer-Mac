// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 20 段图形 EQ 推子板（用户 2026-11-15 提供的目标形态）。
//
// 形态（按用户截图）：每段一根竖直粗推子 + 白色圆形把手；
// 左边是 dB 刻度，**下面显示频率**，**上面是 ±dB 数值输入框**（与推子一一对齐）。
//
// 为什么单独一个视图、而不是继续在 RLPEQCurveView 里加分支：
//   曲线模式的坐标是"对数频率 × 增益"（x 由频率决定）；
//   推子模式是"等宽槽位 × 增益"（x 由段号决定，硬件 EQ 的做法）。
//   两套几何混在一个 drawRect 里，拖拽命中与判据会互相污染。
//
// 量程 = ±24 dB（用户 2026-11-15 明确；与后端钳位、web 表格 min/max 同口径）。

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface RLPEQFaderView : NSView

/// 20 个段中心频率（Hz）。为空时不画推子，只画空板。
@property (nonatomic, copy) NSArray<NSNumber *> *bandFreqs;
/// 20 个段的增益（dB，±24）。长度不足按 0 处理。
@property (nonatomic, copy) NSArray<NSNumber *> *bandGains;
/// 当前高亮的段（-1 = 无）。
@property (nonatomic, assign) NSInteger activeBand;
/// 用户拖推子 / 改数值框 → 请求把第 idx 段设为 db（已按 ±24 夹好）。
@property (nonatomic, copy, nullable) void (^onBandGainEdited)(NSInteger idx, double db);

/// 绘图区（不含上方数值行、不含下方频率标签行）。
@property (nonatomic, readonly) NSRect plotRect;
/// 当前段数（= bandFreqs.count）。
@property (nonatomic, readonly) NSUInteger bandCount;
/// 把输入框的内容提交给 onBandGainEdited（回车/失焦会自动走这里；判据也直接调它）。
- (void)onValueFieldCommitted:(NSTextField *)f;
/// 第 i 段的横向中心（等宽槽位）。
- (CGFloat)xForBand:(NSUInteger)i;
/// 增益 → 竖直坐标（+24 在顶、-24 在底、0 居中）。
- (CGFloat)yForDb:(double)db;
/// 第 i 段推子的轨道矩形（把手沿它滑动）。
- (NSRect)trackRectForBand:(NSUInteger)i;
/// 第 i 段上方的数值输入框（判据用；也用于让用户直接键入）。
- (nullable NSTextField *)valueFieldForBand:(NSUInteger)i;
/// 第 i 段下方显示的频率文本（判据用）。
- (NSString *)freqLabelForBand:(NSUInteger)i;

/// 绘制自证：drawRect 次数 + 最近一次画出来的把手位置（判据区分"数据变了"与"变了没重绘"）。
@property (nonatomic, readonly) NSInteger drawCount;
@property (nonatomic, readonly) CGFloat lastDrawnKnobYForBand0;

@end

NS_ASSUME_NONNULL_END
