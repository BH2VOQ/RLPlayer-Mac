// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// 推子板的**单段检查器**：只显示"当前选中的那一段"的频率 / Q / 类型 / 开关。
///
/// 为什么是"单段"而不是"20 行"：
/// 用户 2026-11-15 要求「底下这个 eq 表不要了」。那张 20 行表是 Q 与滤波器类型
/// 的唯一编辑入口，直接删=删功能（铁律 1）；但照搬成 20 行控件等于把表换个壳，
/// 既没变好看，也没解决"占一大块"的问题。
/// 专业 EQ（Pro-Q / FabFilter / Ableton EQ8）都是"选中一段 → 下方一个 inspector"，
/// 占地固定、只显示当下要调的那一段。这里照此实现。
@interface RLPEQFaderInspector : NSView <NSTextFieldDelegate>

/// 当前显示的段（-1 = 没有选中，整个视图隐藏）。
@property (nonatomic, assign) NSInteger bandIndex;
@property (nonatomic, copy, nullable) NSString *freqText;   // 例 "1000 Hz"
@property (nonatomic, assign) double q;
@property (nonatomic, copy, nullable) NSString *typeCode;   // PK / LS / HS
@property (nonatomic, assign) BOOL bandEnabled;

/// 改 Q / 类型 / 开关 → 回传（增益仍由推子管）。
@property (nonatomic, copy, nullable) void (^onQChanged)(NSInteger idx, double q);
@property (nonatomic, copy, nullable) void (^onTypeChanged)(NSInteger idx, NSString *code);
@property (nonatomic, copy, nullable) void (^onEnabledChanged)(NSInteger idx, BOOL on);

/// 把上面几个属性写进控件（不触发回调）。
- (void)syncValues;
- (void)applyTheme;
- (void)applyLanguage;

/// 判据锚点。
- (nullable NSTextField *)qField;
- (nullable NSPopUpButton *)typePopup;
- (nullable NSButton *)enableSwitch;

@end

NS_ASSUME_NONNULL_END
