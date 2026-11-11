// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPTheme.mm — 与 web 版同色值的主题令牌。
//
// 每个数字都能在 src/net/ui_page.h 里找到出处（注释里标了对应的 CSS 变量）。
// 半透明线/悬停色必须保留 alpha：web 版靠它做"分层但不画硬边框"的观感，
// 换成实色灰会让整个界面显得脏、边框生硬。
#import "RLPTheme.h"

NSNotificationName const RLPThemeDidChangeNotification = @"RLPThemeDidChangeNotification";

// 默认 light（用户 2026-11-11 明确：默认主题是浅色版）。
static NSString *gThemeName = @"light";

// #RRGGBB → NSColor（sRGB）。web 的 hex 就是 sRGB，直接用 sRGB 构造才不会偏色。
static NSColor *Hex(uint32_t rgb, CGFloat a) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xFF) / 255.0
                            green:((rgb >> 8) & 0xFF) / 255.0
                             blue:(rgb & 0xFF) / 255.0
                            alpha:a];
}

@implementation RLPTheme

+ (NSArray<NSString *> *)themeNames { return @[@"dark", @"light"]; }
+ (NSString *)themeName { return gThemeName; }

+ (void)setThemeName:(NSString *)name {
    NSString *n = [name lowercaseString];
    if (![[self themeNames] containsObject:n]) n = @"light";
    if ([n isEqualToString:gThemeName]) return;
    gThemeName = [n copy];
    [[NSNotificationCenter defaultCenter] postNotificationName:RLPThemeDidChangeNotification object:nil];
}

+ (instancetype)current {
    RLPTheme *t = [[RLPTheme alloc] init];
    t->_name = [gThemeName copy];
    if ([gThemeName isEqualToString:@"light"]) {
        t->_isLight = YES;
        t->_bg      = Hex(0xffffff, 1.0);   // --bg
        t->_bg2     = Hex(0xf2f2f6, 1.0);   // --bg2
        t->_bg3     = Hex(0xf7f7fa, 1.0);   // --bg3 / --card
        t->_barBg   = Hex(0xf6f6f9, 0.84);  // --barbg
        t->_topBg   = Hex(0xffffff, 0.85);  // --topbg
        t->_text    = Hex(0x1d1d1f, 1.0);   // --txt
        t->_text2   = Hex(0x3a3a3c, 1.0);   // --txt2
        t->_mut     = Hex(0x6e6e73, 1.0);   // --mut
        t->_line    = Hex(0x000000, 0.08);  // --line
        t->_line2   = Hex(0x000000, 0.13);  // --line2
        t->_hov     = Hex(0x000000, 0.045); // --hov
        t->_hov2    = Hex(0x000000, 0.08);  // --hov2
        t->_field   = Hex(0x000000, 0.05);  // --field
        t->_accent  = Hex(0xfa2d48, 1.0);   // --acc（Apple Music 珊瑚红）
        t->_accentWeak = Hex(0xfa2d48, 0.14);
        t->_accentText = Hex(0xd70015, 1.0);
        t->_navOn   = Hex(0x000000, 0.07);  // --nav-on
        t->_danger  = Hex(0xff3b30, 1.0);
        t->_ok      = Hex(0x248a3d, 1.0);
        t->_warn    = Hex(0xb25000, 1.0);
        t->_phFrom  = Hex(0xe8e8ed, 1.0);
        t->_phTo    = Hex(0xf7f7fa, 1.0);
    } else {
        t->_name = @"dark";
        t->_isLight = NO;
        t->_bg      = Hex(0x161618, 1.0);   // --bg
        t->_bg2     = Hex(0x1e1e22, 1.0);   // --bg2
        t->_bg3     = Hex(0x26262b, 1.0);   // --bg3 / --card
        t->_barBg   = Hex(0x28282e, 0.78);  // --barbg
        t->_topBg   = Hex(0x161618, 0.82);  // --topbg
        t->_text    = Hex(0xf5f5f7, 1.0);   // --txt
        t->_text2   = Hex(0xd2d2d7, 1.0);   // --txt2
        t->_mut     = Hex(0x86868b, 1.0);   // --mut
        t->_line    = Hex(0xffffff, 0.08);  // --line
        t->_line2   = Hex(0xffffff, 0.13);  // --line2
        t->_hov     = Hex(0xffffff, 0.06);  // --hov
        t->_hov2    = Hex(0xffffff, 0.11);  // --hov2
        t->_field   = Hex(0xffffff, 0.07);  // --field
        t->_accent  = Hex(0xfa2d48, 1.0);   // --acc
        t->_accentWeak = Hex(0xfa2d48, 0.16);
        t->_accentText = Hex(0xff697d, 1.0);
        t->_navOn   = Hex(0xffffff, 0.10);  // --nav-on
        t->_danger  = Hex(0xff453a, 1.0);
        t->_ok      = Hex(0x30d158, 1.0);
        t->_warn    = Hex(0xffd60a, 1.0);
        t->_phFrom  = Hex(0x2a2a30, 1.0);   // --phbg 渐变两端
        t->_phTo    = Hex(0x1c1c20, 1.0);
    }
    t->_body  = [NSFont systemFontOfSize:13];
    t->_small = [NSFont systemFontOfSize:11.5];
    t->_title = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
    t->_mono  = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    t->_rLg = 14; t->_rMd = 10; t->_rSm = 8;
    return t;
}
@end
