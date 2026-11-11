// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPTheme.h — 原生 UI 的语义色/字号（第一版只做暗色；亮色/蓝色后续按同一 token 扩展）
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface RLPTheme : NSObject
+ (instancetype)current;
@property (nonatomic, readonly) NSColor *bg;
@property (nonatomic, readonly) NSColor *bg2;
@property (nonatomic, readonly) NSColor *barBg;
@property (nonatomic, readonly) NSColor *text;
@property (nonatomic, readonly) NSColor *mut;
@property (nonatomic, readonly) NSColor *line;
@property (nonatomic, readonly) NSColor *accent;
@property (nonatomic, readonly) NSColor *danger;
@property (nonatomic, readonly) NSFont *body;
@property (nonatomic, readonly) NSFont *small;
@property (nonatomic, readonly) NSFont *title;
@property (nonatomic, readonly) NSFont *mono;
@end

NS_ASSUME_NONNULL_END
