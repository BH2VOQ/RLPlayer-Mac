// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPTargetCurve.h — 耳机目标曲线：数据表 + 归类 + 叠加绘制（web 同构）
//
// ============================ 为什么要有这个文件 ============================
// 用户反馈（2026-11-13，第 8 项）：「耳机目标曲线仍未能像 web 版那样接入」。
//
// 逐层判定结论（详见 evidence/native-target-curve-20261113.md）：
//   ① 桥层取数据：**通**。原生已接 /api/opra/index、/api/opra/presets、/api/opra/apply，
//      字段（id/name/vendor、id/name、ok/path）与 web 逐个对得上。
//   ② 画到图上：**断**。web 有 `TARGET_CURVES`（11 条目标曲线示意）+ `targetCurveSvg()`，
//      原生**一条都没有** —— 既没有数据表，也没有把曲线叠加到 EQ 图上的图层。
//      这就是用户说"没接入"的直接原因：能选、能应用，但图上什么也看不见。
//   ③ 字段名：**通**（无差异）。
//   ④ 加载时机：**部分断**。web 在选中预设后立刻 `showTargetCurveInfo(curP)` 展示目标曲线，
//      原生选中预设后只更新下拉框，**从不展示对应目标曲线**。
//
// 所以本文件补的是 ② 与 ④：把 web 的 TARGET_CURVES / curveKindOfDetails /
// getTargetCurveDescInfo 全量移植过来（铁律①：功能不能删除只做全量移植），
// 并给 EQ 曲线视图加一个 targetPoints 图层。
//
// 注意：web 的 pts 横轴是 **归一化 0..1 的对数频率位置**（不是 Hz），
// 竖向范围是 [-2, +9] dB（不是 ±18）。这两点必须照抄，否则曲线形状会变形。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 一条目标曲线的示意（web TARGET_CURVES 的一条）。
@interface RLPTargetCurve : NSObject
@property (nonatomic, copy, readonly) NSString *kind;
@property (nonatomic, copy, readonly) NSString *label;
/// 横轴归一化 0..1（对数频率位置），纵轴 dB。每项是 @[x, db]。
@property (nonatomic, copy, readonly) NSArray<NSArray<NSNumber *> *> *points;
@end

@interface RLPTargetCurveLibrary : NSObject

/// web `curveKindOfDetails(details)`：按预设 details 挑选曲线种类。
+ (NSString *)kindForDetails:(nullable NSString *)details;

/// web `TARGET_CURVES[kind]`；未知 kind 回落到 autoeq（与 web 一致）。
+ (nullable RLPTargetCurve *)curveForKind:(nullable NSString *)kind;

/// 全部内置曲线（顺序 = web 表顺序，供判据枚举）。
+ (NSArray<RLPTargetCurve *> *)allCurves;

/// web `getTargetCurveDescInfo(details, author).name`：
/// 选中预设后要展示的那个目标曲线中文名（同判据、同分支、同文案）。
+ (NSString *)targetCurveNameForDetails:(nullable NSString *)details
                                 author:(nullable NSString *)author;

/// 同上，但给出"适合谁 / 是什么"两段说明（web showTargetCurveInfo 的两行）。
+ (NSString *)targetCurveSceneForDetails:(nullable NSString *)details
                                  author:(nullable NSString *)author;
+ (NSString *)targetCurveTechForDetails:(nullable NSString *)details
                                 author:(nullable NSString *)author;

/// 把归一化 pts 映射到给定绘图矩形（统一到这里，避免各处各算一套）。
/// 返回 NSValue 包住的 NSPoint，可直接 drawRect 用。
+ (NSArray<NSValue *> *)plotPoints:(RLPTargetCurve *)curve inRect:(NSRect)plot;

@end

NS_ASSUME_NONNULL_END
