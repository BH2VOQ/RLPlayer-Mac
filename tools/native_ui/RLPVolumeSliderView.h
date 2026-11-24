// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPVolumeSliderView.h — 音量控件（横向滑杆，替代原先的 270° 旋钮）
//
// 为什么改（用户 2026-11-15：「音量旋钮调整音量的方式很别扭，可以去网上找一找有没有更好的音量方案」）：
//
//   ① Apple HIG《Sliders》明确写：Don't use a slider to adjust audio volume.
//      If you need to provide volume control in your app, use a volume view,
//      which is customizable and includes a volume-level slider and a control for
//      changing the active audio output device.
//      ⟹ 旋钮（knob）比 slider 更偏离规范：它把"一维的连续量"藏进"角度"，必须先瞄准再拖。
//
//   ② macOS 27.2 起系统自己的音量提示也改成了**分段横条滑杆**
//      （左端一个喇叭图标 + 分段横条），说明"横向、可一眼读出比例"是当前方向。
//
//   ③ 原实现的实际毛病（代码级）：RLPVolumeKnobView 用**绝对角度映射**
//      （RLPVolKnobDbFromAngleDegrees），按下瞬间音量就跳到指针所在角度对应的值，
//      松手前无法"先按住再微调"；也没有滚轮/键盘通路。
//
// 因此这里提供的是：
//   · 横向滑杆主体（点按可跳、但拖动是**增量累加**，不会因为指针抖动而乱跳）
//   · 滚轮调音量（macOS 上最常见的细调方式）
//   · 双击 = 回到 0 dB；右键/⌥ 拖动 = 精细模式（灵敏度 1/4）
//   · 左侧喇叭图标可点击静音，右侧显示 dB 数值
//
// 语义仍与后端/ web 完全一致：范围 -120 .. +20 dB，0 dB 在中心偏右的等分位置，
// 数值一律走 RLPVolClampDb（四舍五入到 0.1 dB）—— 不另造一套换算。
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 范围与后端 / web 同值。用 slider 自己的名字导出，避免对旋钮那个 .mm 产生链接依赖
/// （旋钮视图已被底栏弃用，但仍在播放页使用，两者不该互相拖依赖）。
extern const double RLPVolSliderMinDb;    // -120
extern const double RLPVolSliderMaxDb;    // +20

/// dB 换算。**语义与旋钮完全一致**（web ui_script.h:6221-6231 的对称指数曲线：
/// 0 dB 在正中、负半弧与正半弧各自铺满、两端 -120/+20），
/// 但实现在本文件内自带一份，避免对已弃用的旋钮视图产生链接依赖。
/// 两处若将来要改，必须同时改 —— 所以这里有一条判据专门断言两边数值一致。
double RLPVolSliderClampDb(double db);
double RLPVolSliderDbToNorm(double db);
double RLPVolSliderNormToDb(double norm);

/// 音量滑杆。数值语义与旧旋钮共用同一组换算函数，避免出现两套 dB 口径。
@interface RLPVolumeSliderView : NSView

/// 当前音量（dB）。setter 会夹到 [-120, +20] 并四舍五入到 0.1。
@property (nonatomic, assign) double db;
/// 是否锁定（例如未播放/无设备时禁用交互）。
@property (nonatomic, assign) BOOL isLocked;
/// 拖动中（判据用：区分"在拖"与"已提交"）。
@property (nonatomic, readonly) BOOL dragging;

/// 拖动过程中实时回调（用于边拖边听/边更新其他显示）。
@property (nonatomic, copy, nullable) void (^onLiveChange)(double db);
/// 松手/滚轮停止后提交。
@property (nonatomic, copy, nullable) void (^onCommit)(double db);
/// 拖动途中被锁定（原始 DSD 等）：取消本次拖动并让宿主把界面退回已确认值。
@property (nonatomic, copy, nullable) void (^onDragCancel)(void);

/// 几何（判据直接测，不靠看）：
/// 归一化位置 0..1 → 视图内 x 坐标（含左右留白）。
- (CGFloat)xForNorm:(double)norm;
/// 视图内 x 坐标 → 归一化 0..1（已夹紧）。
- (double)normForX:(CGFloat)x;
/// 滑杆轨道矩形。
@property (nonatomic, readonly) NSRect trackRect;
/// 是否在滑杆内部自带"喇叭 + dB 数值"。
/// 默认 YES（独立使用时自足）；**放在底栏时必须关掉** ——
/// 底栏已经有 volIconView（喇叭）与 volDbField（dB 输入框），
/// 再带一套就是同一条上重复三个信息，而且会把轨道挤到 20pt 宽（实测踩到）。
@property (nonatomic, assign) BOOL showsAccessories;

/// 左侧喇叭按钮 / 右侧数值文本（showsAccessories=NO 时为 nil）。
- (nullable NSButton *)muteButton;
- (nullable NSTextField *)valueLabel;
- (void)applyTheme;
- (void)applyLanguage;

@end

NS_ASSUME_NONNULL_END
