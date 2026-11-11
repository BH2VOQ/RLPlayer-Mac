// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPTheme.h"

@implementation RLPTheme
+ (instancetype)current {
    static RLPTheme *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [[RLPTheme alloc] init]; });
    return t;
}
- (instancetype)init {
    if ((self = [super init])) {
        _bg = [NSColor colorWithSRGBRed:0.07 green:0.07 blue:0.08 alpha:1.0];
        _bg2 = [NSColor colorWithSRGBRed:0.11 green:0.11 blue:0.12 alpha:1.0];
        _barBg = [NSColor colorWithSRGBRed:0.13 green:0.13 blue:0.14 alpha:0.92];
        _text = [NSColor colorWithSRGBRed:0.93 green:0.93 blue:0.94 alpha:1.0];
        _mut = [NSColor colorWithSRGBRed:0.62 green:0.62 blue:0.65 alpha:1.0];
        _line = [NSColor colorWithSRGBRed:0.21 green:0.21 blue:0.23 alpha:1.0];
        _accent = [NSColor colorWithSRGBRed:0.36 green:0.62 blue:1.0 alpha:1.0];
        _danger = [NSColor colorWithSRGBRed:0.95 green:0.36 blue:0.36 alpha:1.0];
        _body = [NSFont systemFontOfSize:13];
        _small = [NSFont systemFontOfSize:11.5];
        _title = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
        _mono = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    }
    return self;
}
@end
