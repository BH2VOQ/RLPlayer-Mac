// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPTheme.h"

NSNotificationName const RLPThemeDidChangeNotification = @"RLPThemeDidChangeNotification";

static NSString *gThemeName = @"dark";

@implementation RLPTheme

+ (NSArray<NSString *> *)themeNames { return @[@"dark", @"light"]; }
+ (NSString *)themeName { return gThemeName; }

+ (void)setThemeName:(NSString *)name {
    NSString *n = [name lowercaseString];
    if (![[self themeNames] containsObject:n]) n = @"dark";
    if ([n isEqualToString:gThemeName]) return;
    gThemeName = [n copy];
    [[NSNotificationCenter defaultCenter] postNotificationName:RLPThemeDidChangeNotification object:nil];
}

+ (instancetype)current {
    RLPTheme *t = [[RLPTheme alloc] init];
    t->_name = [gThemeName copy];
    if ([gThemeName isEqualToString:@"light"]) {
        t->_isLight = YES;
        t->_bg = [NSColor colorWithSRGBRed:0.965 green:0.965 blue:0.973 alpha:1.0];
        t->_bg2 = [NSColor colorWithSRGBRed:1.0 green:1.0 blue:1.0 alpha:1.0];
        t->_barBg = [NSColor colorWithSRGBRed:1.0 green:1.0 blue:1.0 alpha:0.94];
        t->_text = [NSColor colorWithSRGBRed:0.11 green:0.11 blue:0.12 alpha:1.0];
        t->_mut = [NSColor colorWithSRGBRed:0.42 green:0.42 blue:0.45 alpha:1.0];
        t->_line = [NSColor colorWithSRGBRed:0.85 green:0.85 blue:0.88 alpha:1.0];
        t->_accent = [NSColor colorWithSRGBRed:0.04 green:0.52 blue:1.0 alpha:1.0];
    } else {
        t->_name = @"dark";
        t->_isLight = NO;
        t->_bg = [NSColor colorWithSRGBRed:0.07 green:0.07 blue:0.08 alpha:1.0];
        t->_bg2 = [NSColor colorWithSRGBRed:0.11 green:0.11 blue:0.12 alpha:1.0];
        t->_barBg = [NSColor colorWithSRGBRed:0.13 green:0.13 blue:0.14 alpha:0.92];
        t->_text = [NSColor colorWithSRGBRed:0.93 green:0.93 blue:0.94 alpha:1.0];
        t->_mut = [NSColor colorWithSRGBRed:0.62 green:0.62 blue:0.65 alpha:1.0];
        t->_line = [NSColor colorWithSRGBRed:0.21 green:0.21 blue:0.23 alpha:1.0];
        t->_accent = [NSColor colorWithSRGBRed:0.36 green:0.62 blue:1.0 alpha:1.0];
    }
    t->_danger = [NSColor colorWithSRGBRed:0.95 green:0.36 blue:0.36 alpha:1.0];
    t->_body = [NSFont systemFontOfSize:13];
    t->_small = [NSFont systemFontOfSize:11.5];
    t->_title = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
    t->_mono = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    return t;
}
@end
