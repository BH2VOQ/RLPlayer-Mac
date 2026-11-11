// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPTheme.h — 原生 UI 的语义色 / 字号 / 圆角。
//
// 色值**逐一对照 web 版 src/net/ui_page.h 的 :root 与 html[data-theme=light]**，
// 不是"看起来差不多"：强调色是 Apple Music 的珊瑚红 #fa2d48（不是蓝），
// 背景分三层 bg / bg2 / bg3，分隔线是半透明白/黑而不是实色灰。
// 只有 dark 与 light 两套（用户 2026-11-11 要求）。
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const RLPThemeDidChangeNotification;

@interface RLPTheme : NSObject
+ (instancetype)current;
+ (NSArray<NSString *> *)themeNames;          // dark / light
+ (NSString *)themeName;
+ (void)setThemeName:(NSString *)name;

@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, readonly) BOOL isLight;

// 背景三层（对应 --bg / --bg2 / --bg3=--card）
@property (nonatomic, readonly) NSColor *bg;
@property (nonatomic, readonly) NSColor *bg2;
@property (nonatomic, readonly) NSColor *bg3;
@property (nonatomic, readonly) NSColor *barBg;
@property (nonatomic, readonly) NSColor *topBg;
// 文字三档（--txt / --txt2 / --mut）
@property (nonatomic, readonly) NSColor *text;
@property (nonatomic, readonly) NSColor *text2;
@property (nonatomic, readonly) NSColor *mut;
// 线与悬停（--line / --line2 / --hov / --hov2 / --field）
@property (nonatomic, readonly) NSColor *line;
@property (nonatomic, readonly) NSColor *line2;
@property (nonatomic, readonly) NSColor *hov;
@property (nonatomic, readonly) NSColor *hov2;
@property (nonatomic, readonly) NSColor *field;
// 强调与状态
@property (nonatomic, readonly) NSColor *accent;
@property (nonatomic, readonly) NSColor *accentWeak;
@property (nonatomic, readonly) NSColor *accentText;
@property (nonatomic, readonly) NSColor *navOn;
@property (nonatomic, readonly) NSColor *danger;
@property (nonatomic, readonly) NSColor *ok;
@property (nonatomic, readonly) NSColor *warn;
// 封面占位渐变两端
@property (nonatomic, readonly) NSColor *phFrom;
@property (nonatomic, readonly) NSColor *phTo;

@property (nonatomic, readonly) NSFont *body;
@property (nonatomic, readonly) NSFont *small;
@property (nonatomic, readonly) NSFont *title;
@property (nonatomic, readonly) NSFont *mono;

// 圆角（--r-lg / --r-md / --r-sm）
@property (nonatomic, readonly) CGFloat rLg;
@property (nonatomic, readonly) CGFloat rMd;
@property (nonatomic, readonly) CGFloat rSm;
@end

NS_ASSUME_NONNULL_END
