// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPVolumeKnobView.h — v3.3.11 音量旋钮（web .rlVolKnob / #npVolKnob）
//
// 为什么单独抽一个视图 + 一组纯 C 几何函数：
//   ① 旋钮的几何与大弧标志是有历史事故的地方（见下），必须能被判据直接测，
//      而不是只能靠打开界面看弧线歪没歪；
//   ② 拖动映射（角度 → dB）是产品语义（0 dB 在正上方、两端 -120/+20 dB），
//      写错会让用户拖到中间就没声音，同样必须可测。
//
// 上游真值（/tmp/rlp2-v3311）：
//   ui_page.h:1305-1322   .rlVolKnob 64×64、轨道 stroke 4、弧 stroke 4 圆头、
//                         刻度 minor 1.2/.65、major 1.7/.95、cap r=20、静音键居中 28×28
//   ui_script.h:6218-6231 VOL_MIN=-120 VOL_MAX=20，volClamp 四舍五入到 0.1 dB
//   ui_script.h:6221-6231 volDbToNorm / volNormToDb（以 0 dB 为圆心的对称指数曲线）
//   ui_script.h:6235-6246 rlVolPoint / rlVolArcPath（大弧标志阈值是 2/3，不是 0.5）
//   ui_script.h:6247-6266 rlPaintVolumeKnob + RL_VOL_TICKS 刻度表
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// 与 web 同名同值：dB 范围与刻度表
extern const double RLPVolKnobMinDb;      // -120
extern const double RLPVolKnobMaxDb;      // +20

/// 上游 volClamp：四舍五入到 0.1 dB 并夹在 [-120, +20]；非有限值按 0 处理。
double RLPVolClampDb(double db);
/// 上游 volDbToNorm：0 dB → 0.5；负半弧/正半弧各自铺满（对称指数）。
double RLPVolDbToNorm(double db);
/// 上游 volNormToDb：0.5 → 0 dB；两端分别映射到 -120 / +20 dB。
double RLPVolNormToDb(double norm);

/// 上游 rlVolPoint：norm ∈ [0,1] 在半径 radius 上的点，**SVG 坐标系**（原点左上、y 向下）。
/// norm=0 → (-135°) 左下，norm=0.5 → 正上方，norm=1 → (+135°) 右下。
NSPoint RLPVolKnobPoint(double norm, double radius);

/// 上游 rlVolArcPath 的 large-arc-flag：扫角 270*norm 超过 180° 才为 1。
/// 历史事故（3.3.10 用户反馈「音量弧线仍然偏移」）：旧代码写 norm>0.5（扫角 135°）就置 1，
/// 0 dB 附近（norm≈0.53）被画成 216° 大弧、绕到左下角，看起来弧线跑到圈外。
/// 正确阈值是 180/270 = 2/3。
BOOL RLPVolKnobArcIsLarge(double norm);

/// 上游 rlVolArcPath：norm≈0 时返回空串（没有弧）；否则给出 SVG path 数据。
NSString *RLPVolKnobArcPath(double norm);

/// 刻度表（顺序即上游 RL_VOL_TICKS）
NSArray<NSNumber *> *RLPVolKnobTickDbs(void);
/// 某个刻度是否为 major（上游 major 判定：-120/-60/-12/0/6/12/20）
BOOL RLPVolKnobTickIsMajor(double db);

/// 拖动映射：以旋钮中心为原点、正上方为 0°，返回该角度对应的 dB。
/// 角度先夹到 [-135, +135]（超出即端点），再做 norm→dB 与 volClamp。
/// 上游 paint(ev)：deg = atan2(x - cx, cy - y)（注意 y 方向相反），norm=(clamp(deg)+135)/270。
double RLPVolKnobDbFromAngleDegrees(double degrees);

#pragma mark - 视图

/// 音量旋钮：64×64 逻辑空间（随视图缩放），可拖动改音量，松开提交。
@interface RLPVolumeKnobView : NSView
/// 当前值（dB）。设置会同时更新弧线与读数；拖动中通过 onLiveChange 回报。
@property (nonatomic, assign) double db;
/// 是否锁定（对应 web dataset.locked：未读设置/设备调音时置灰且不可拖）
@property (nonatomic, assign, getter=isLocked) BOOL locked;
/// 拖动过程中的实时回调（每帧最多一次，对齐上游 rAF 合并）。
@property (nonatomic, copy, nullable) void (^onLiveChange)(double db);
/// 松开鼠标时的提交回调（对应上游 commitVolumeGesture）。
@property (nonatomic, copy, nullable) void (^onCommit)(double db);
/// 判据入口：直接按逻辑坐标（0..64，y 向下）模拟一次拖动，返回是否改变了音量。
- (BOOL)dragToPointForAudit:(NSPoint)pointIn64;
@end

NS_ASSUME_NONNULL_END
