// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPTheme.mm — web CSS 自定义属性的逐值移植。
//
// 真相源 src/net/ui_page.h：
//   :root                                       (131-152)  dark
//   html[data-theme=light]                      (153-168)  light
//   html[data-uistyle=classic]                  (643)      classic x dark
//   html[data-uistyle=classic][data-theme=light](644)      classic x light
//
// 本轮修掉的两个发明（用户反馈「效果跟功能比不上 web」的根因之一）：
//   1. dark 之前是墨绿青 #121a19 —— web 的 dark 是近黑 #161618。整屏底色都不对。
//   2. display/heading/serif 之前是 Georgia 衬线 —— web 全站无衬线
//      (Inter / Segoe UI / system-ui)。字体气质完全跑偏。
// 现在每个值都能被 theme_parity.py 从 web 源码里找出来。
#import "RLPTheme.h"

NSNotificationName const RLPThemeDidChangeNotification = @"RLPThemeDidChangeNotification";

// 默认 light（用户 2026-11-11 明确）。web 默认 dark，但用户指定了 light，属用户决定。
static NSString *gThemeName = @"light";
static NSString *gUiStyle   = @"apple";

// #RRGGBB(+alpha) → NSColor(sRGB)。web 的 hex 就是 sRGB，必须用 sRGB 构造否则偏色。
static NSColor *Hex(uint32_t rgb, CGFloat a) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xFF) / 255.0
                               green:((rgb >>  8) & 0xFF) / 255.0
                                blue:( rgb        & 0xFF) / 255.0
                               alpha:a];
}
// web 的 rgba(r,g,b,a) 直接照抄（保留 alpha：分层靠它，换实色会显脏）。
static NSColor *RGBA(int r, int g, int b, CGFloat a) {
    return [NSColor colorWithSRGBRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}

// ── web 无衬线字体栈：Inter → Segoe UI → system-ui。macOS 上落到 system-ui ──
// 关键：**不引入任何衬线**。web 里 grep 不到 georgia/serif（除 monospace 的数字列）。
static NSFont *Sans(CGFloat size, NSFontWeight w) {
    // Inter 若已安装则优先（与 web 完全同字形）；否则系统字（= web 的 system-ui 回退）。
    NSString *face = nil;
    if (w == NSFontWeightBold || w == NSFontWeightHeavy) face = @"Inter-Bold";
    else if (w == NSFontWeightSemibold || w == NSFontWeightMedium) face = @"Inter-SemiBold";
    else if (w >= NSFontWeightRegular) face = @"Inter-Regular";
    NSFont *f = face ? [NSFont fontWithName:face size:size] : nil;
    return f ?: [NSFont systemFontOfSize:size weight:w];
}

@implementation RLPTheme

+ (NSArray<NSString *> *)themeNames { return @[@"dark", @"light"]; }
+ (NSString *)themeName { return gThemeName; }
+ (NSArray<NSString *> *)uiStyles { return @[@"apple", @"classic"]; }
+ (NSString *)uiStyle { return gUiStyle; }

+ (void)setThemeName:(NSString *)name {
    NSString *n = [name lowercaseString];
    if (![[self themeNames] containsObject:n]) n = @"light";
    if ([n isEqualToString:gThemeName]) return;
    gThemeName = [n copy];
    [[NSNotificationCenter defaultCenter] postNotificationName:RLPThemeDidChangeNotification object:nil];
}

+ (void)setUiStyle:(NSString *)style {
    NSString *s = [style lowercaseString];
    if (![[self uiStyles] containsObject:s]) s = @"apple";
    if ([s isEqualToString:gUiStyle]) return;
    gUiStyle = [s copy];
    // 与主题切换共用一个通知：所有页面都要重刷（classic 换的是整套令牌）。
    [[NSNotificationCenter defaultCenter] postNotificationName:RLPThemeDidChangeNotification object:nil];
}

+ (instancetype)current {
    RLPTheme *t = [[RLPTheme alloc] init];
    t->_name  = [gThemeName copy];
    t->_style = [gUiStyle copy];
    t->_isLight   = [gThemeName isEqualToString:@"light"];
    t->_isClassic = [gUiStyle isEqualToString:@"classic"];

    // 先铺 apple 的 base（:root = dark，light 覆盖颜色），再按 classic 覆盖。
    if (t->_isLight) {
        // ---- html[data-theme=light] (ui_page.h:153-168) ----
        t->_bg      = Hex(0xffffff, 1);            // --bg:#ffffff
        t->_bg2     = Hex(0xf2f2f6, 1);            // --bg2:#f2f2f6
        t->_bg3     = Hex(0xf7f7fa, 1);            // --bg3:#f7f7fa
        t->_peqHd   = Hex(0xeef0f5, 1);            // --peq-hd:#eef0f5
        t->_peqR1   = Hex(0xffffff, 1);            // --peq-r1:#ffffff
        t->_peqR2   = Hex(0xf6f7fa, 1);            // --peq-r2:#f6f7fa
        t->_topBg   = RGBA(255,255,255, .85);      // --topbg:rgba(255,255,255,.85)
        t->_barBg   = RGBA(246,246,249, .84);      // --barbg:rgba(246,246,249,.84)
        t->_barBorder = RGBA(0,0,0, .085);         // --bar-border:rgba(0,0,0,.085)
        t->_line    = RGBA(0,0,0, .08);            // --line
        t->_line2   = RGBA(0,0,0, .13);            // --line2
        t->_hov     = RGBA(0,0,0, .045);           // --hov
        t->_hov2    = RGBA(0,0,0, .08);            // --hov2
        t->_field   = RGBA(0,0,0, .05);            // --field
        t->_crumb   = RGBA(255,255,255, .92);      // --crumb
        t->_text    = Hex(0x1d1d1f, 1);            // --txt
        t->_text2   = Hex(0x3a3a3c, 1);            // --txt2
        t->_mut     = Hex(0x6e6e73, 1);            // --mut
        t->_mut2    = Hex(0x86868b, 1);            // --mut2
        t->_accent  = Hex(0xfa2d48, 1);            // --acc:#fa2d48
        t->_accent2 = Hex(0xff375f, 1);            // --acc2:#ff375f
        t->_accentWeak = RGBA(250,45,72, .11);     // --acc-weak
        t->_accentText = Hex(0xd71935, 1);         // --acc-text:#d71935
        t->_navOn   = RGBA(0,0,0, .068);           // --nav-on:rgba(0,0,0,.068)
        t->_navOnText = Hex(0x1d1d1f, 1);          // --nav-on-text:#1d1d1f
        t->_cvBg    = Hex(0xededf2, 1);            // --cvbg:#ededf2
        t->_phFrom  = Hex(0xf2f2f7, 1);            // --phbg 135deg #f2f2f7
        t->_phTo    = Hex(0xe5e5ea, 1);            //              → #e5e5ea
        t->_phText  = RGBA(0,0,0, .18);            // --ph-txt
        t->_shadow  = RGBA(0,0,0, .10);            // --shadow
        t->_track   = RGBA(0,0,0, .10);            // --track
        t->_toast   = RGBA(255,255,255, .96);      // --toast
        t->_ok      = Hex(0x248a3d, 1);            // --ok
        t->_okBg    = RGBA(36,138,61, .10);        // --ok-bg
        t->_okLine  = RGBA(36,138,61, .25);        // --ok-line
        t->_okText  = Hex(0x1e7033, 1);            // --ok-text
        t->_warn    = Hex(0xb25000, 1);            // --warn:#b25000
        t->_danger  = Hex(0xd70015, 1);            // --danger:#d70015
        t->_bpDirect= Hex(0x8944ab, 1);            // --bp-direct:#8944ab
    } else {
        // ---- :root (ui_page.h:131-152) = dark ----
        t->_bg      = Hex(0x161618, 1);            // --bg:#161618  ← 之前错成 #121a19
        t->_bg2     = Hex(0x1e1e22, 1);            // --bg2:#1e1e22
        t->_bg3     = Hex(0x26262b, 1);            // --bg3:#26262b
        t->_peqHd   = Hex(0x26262b, 1);
        t->_peqR1   = Hex(0x1c1c20, 1);
        t->_peqR2   = Hex(0x1e1e22, 1);
        t->_topBg   = RGBA(22,22,24, .82);         // --topbg:rgba(22,22,24,.82)
        t->_barBg   = RGBA(40,40,46, .78);         // --barbg:rgba(40,40,46,.78)
        t->_barBorder = RGBA(255,255,255, .12);
        t->_line    = RGBA(255,255,255, .08);
        t->_line2   = RGBA(255,255,255, .13);
        t->_hov     = RGBA(255,255,255, .06);
        t->_hov2    = RGBA(255,255,255, .11);
        t->_field   = RGBA(255,255,255, .07);
        t->_crumb   = RGBA(22,22,24, .92);
        t->_text    = Hex(0xf5f5f7, 1);            // --txt:#f5f5f7 ← 之前错成暖白 #f2f0e9
        t->_text2   = Hex(0xd2d2d7, 1);
        t->_mut     = Hex(0x86868b, 1);
        t->_mut2    = Hex(0x6e6e73, 1);
        t->_accent  = Hex(0xfa2d48, 1);
        t->_accent2 = Hex(0xff375f, 1);
        t->_accentWeak = RGBA(250,45,72, .16);
        t->_accentText = Hex(0xff697d, 1);
        t->_navOn   = RGBA(255,255,255, .10);      // --nav-on:rgba(255,255,255,.10)
        t->_navOnText = Hex(0xffffff, 1);          // --nav-on-text:#ffffff
        t->_cvBg    = Hex(0x242429, 1);
        t->_phFrom  = Hex(0x2a2a30, 1);
        t->_phTo    = Hex(0x1c1c20, 1);
        t->_phText  = RGBA(255,255,255, .16);
        t->_shadow  = RGBA(0,0,0, .42);
        t->_track   = RGBA(255,255,255, .12);
        t->_toast   = RGBA(32,32,36, .96);
        t->_ok      = Hex(0x30d158, 1);
        t->_okBg    = RGBA(48,209,88, .14);
        t->_okLine  = RGBA(48,209,88, .32);
        t->_okText  = Hex(0x66e384, 1);
        t->_warn    = Hex(0xffd60a, 1);            // --warn:#ffd60a
        t->_danger  = Hex(0xff453a, 1);            // --danger:#ff453a
        t->_bpDirect= Hex(0xbf5af2, 1);
    }

    // web 的 --card 只在 :root 与 html[data-theme=light] 里定义；
    // classic 覆盖了 --bg3 但**没有**覆盖 --card ⟹ classic 下 --card 仍是基础主题的值。
    // 这看着像 web 的疏漏，但 web 已冻结、是只读参考 ⟹ 原生必须照抄真实层叠结果，
    // 不能"顺手修正"，否则两端观感又分叉。（theme_parity.py 抓到的正是这一条。）
    NSColor *baseCard = t->_bg3;

    // ── classic 覆盖（ui_page.h:643 / :644）：强调色由珊瑚红变蓝，圆角收紧 ──
    if (t->_isClassic) {
        t->_barBgIsGradient = YES;
        t->_navOnIsGradient = YES;
        if (t->_isLight) {
            // html[data-uistyle=classic][data-theme=light]
            t->_bg = Hex(0xf4f6f9,1); t->_bg2 = Hex(0xffffff,1); t->_bg3 = Hex(0xeef1f6,1);
            t->_peqHd = Hex(0xeef1f6,1); t->_peqR1 = Hex(0xf4f6f9,1); t->_peqR2 = Hex(0xffffff,1);
            t->_topBg = Hex(0xf4f6f9,1);
            t->_barBg = Hex(0xffffff,1); t->_barBgTo = Hex(0xf0f3f8,1);   // 180deg
            t->_barBorder = RGBA(15,23,42,.10);
            t->_line = RGBA(15,23,42,.10); t->_line2 = RGBA(15,23,42,.16);
            t->_hov = RGBA(15,23,42,.04);  t->_hov2 = RGBA(15,23,42,.08);
            t->_field = RGBA(15,23,42,.035); t->_crumb = RGBA(244,246,249,.96);
            t->_text = Hex(0x111827,1); t->_text2 = Hex(0x374151,1);
            t->_mut = Hex(0x6b7280,1);  t->_mut2 = Hex(0x9ca3af,1);
            t->_accent = Hex(0x2563eb,1); t->_accent2 = Hex(0x7c3aed,1);
            t->_accentWeak = RGBA(37,99,235,.12); t->_accentText = Hex(0x1d4ed8,1);
            t->_navOn = RGBA(37,99,235,.13); t->_navOnTo = RGBA(37,99,235,.02);
            t->_navOnText = Hex(0x1e40af,1);
            t->_cvBg = Hex(0xe8ecf2,1); t->_phFrom = Hex(0xe6ebf3,1); t->_phTo = Hex(0xd3dae5,1);
            t->_phText = RGBA(15,23,42,.14);
            t->_shadow = RGBA(15,23,42,.14); t->_track = RGBA(15,23,42,.10);
            t->_toast = RGBA(255,255,255,.98);
            t->_ok = Hex(0x16a34a,1); t->_okBg = RGBA(22,163,74,.12);
            t->_okLine = RGBA(22,163,74,.28); t->_okText = Hex(0x15803d,1);
            t->_warn = Hex(0xd97706,1); t->_danger = Hex(0xdc2626,1); t->_bpDirect = Hex(0x7c3aed,1);
        } else {
            // html[data-uistyle=classic]  (dark)
            t->_bg = Hex(0x08090c,1); t->_bg2 = Hex(0x0c0e13,1); t->_bg3 = Hex(0x11141b,1);
            t->_peqHd = Hex(0x11141b,1); t->_peqR1 = Hex(0x08090c,1); t->_peqR2 = Hex(0x0c0e13,1);
            t->_topBg = Hex(0x08090c,1);
            t->_barBg = Hex(0x11141b,1); t->_barBgTo = Hex(0x0a0c10,1);
            t->_barBorder = RGBA(255,255,255,.09);
            t->_line = RGBA(255,255,255,.07); t->_line2 = RGBA(255,255,255,.12);
            t->_hov = RGBA(255,255,255,.05);  t->_hov2 = RGBA(255,255,255,.10);
            t->_field = RGBA(255,255,255,.06); t->_crumb = RGBA(8,9,12,.94);
            t->_text = Hex(0xe8ecf4,1); t->_text2 = Hex(0xc3cad6,1);
            t->_mut = Hex(0x8b94a3,1);  t->_mut2 = Hex(0x6b7482,1);
            t->_accent = Hex(0x3b82f6,1); t->_accent2 = Hex(0x8b5cf6,1);
            t->_accentWeak = RGBA(59,130,246,.16); t->_accentText = Hex(0x9dc0ff,1);
            t->_navOn = RGBA(59,130,246,.24); t->_navOnTo = RGBA(59,130,246,.04);
            t->_navOnText = Hex(0xcfe0ff,1);
            t->_cvBg = Hex(0x141821,1); t->_phFrom = Hex(0x1a2030,1); t->_phTo = Hex(0x0d111a,1);
            t->_phText = RGBA(255,255,255,.14);
            t->_shadow = RGBA(0,0,0,.55); t->_track = RGBA(255,255,255,.10);
            t->_toast = RGBA(14,17,24,.97);
            t->_ok = Hex(0x22c55e,1); t->_okBg = RGBA(34,197,94,.14);
            t->_okLine = RGBA(34,197,94,.30); t->_okText = Hex(0x4ade80,1);
            t->_warn = Hex(0xf59e0b,1); t->_danger = Hex(0xef4444,1); t->_bpDirect = Hex(0xa78bfa,1);
        }
    }

    // ── 兼容别名：全部指回 web 的令牌，不再有发明色 ──
    t->_hero     = t->_text;        // web 大标题就是 --txt
    t->_card     = baseCard;        // web --card：classic 不覆盖它，故用基础主题值
    t->_cardAlt  = t->_bg2;
    t->_hairline = t->_line;
    t->_chip     = t->_accentWeak;

    // ── 字体：web 全站无衬线。字号取自对应 CSS 规则 ──
    t->_display   = Sans(26, NSFontWeightBold);        // .ahead h1 26px/750
    t->_heading   = Sans(19, NSFontWeightSemibold);    // 次级分区标题
    t->_serif     = Sans(20, NSFontWeightSemibold);    // 名字是历史遗留，实为无衬线
    t->_pageTitle = Sans(24, NSFontWeightBold);        // .ptitle 24px/750
    t->_cardTitle = Sans(28, NSFontWeightHeavy);       // .am-card-title 28px/800
    t->_navFont   = Sans(13, NSFontWeightRegular);     // .nav 13px/450
    t->_navFontOn = Sans(13, NSFontWeightSemibold);    // .nav.on 13px/600
    t->_secFont   = Sans(11, NSFontWeightSemibold);    // .sec 11px/600
    t->_caption   = Sans(11, NSFontWeightRegular);
    t->_body      = Sans(13, NSFontWeightRegular);     // body font:13px
    t->_small     = Sans(11.5, NSFontWeightRegular);
    t->_title     = Sans(17, NSFontWeightSemibold);
    t->_mono      = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightRegular];

    // ── 几何 ──
    t->_rLg = t->_isClassic ? 12 : 14;   // --r-lg
    t->_rMd = t->_isClassic ?  9 : 10;   // --r-md
    t->_rSm = t->_isClassic ?  7 :  8;   // --r-sm
    t->_sideW = 226;                     // --sidew:226px（之前原生 232，错）
    t->_topH  = t->_isClassic ? 52 : 60; // .top height:60；classic #app rows 52px
    t->_barH  = 66;                      // .bar height:66（之前原生 76，错）
    t->_barRadius = 16;                  // .bar border-radius:16
    t->_barMaxW = 1120;                  // .bar max-width:1120
    t->_cardMinW = 152;                  // .grid minmax(152px,1fr)
    t->_gridGap = 16;                    // .grid gap:16
    t->_gridPad = 18;                    // .grid padding:18
    return t;
}

#pragma mark - 令牌导出（机械核对）

static NSString *ColorStr(NSColor *c) {
    if (!c) return @"nil";
    NSColor *s = [c colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: c;
    return [NSString stringWithFormat:@"%d,%d,%d,%.3f",
            (int)lround(s.redComponent   * 255.0),
            (int)lround(s.greenComponent * 255.0),
            (int)lround(s.blueComponent  * 255.0),
            s.alphaComponent];
}

- (NSDictionary<NSString *, NSString *> *)tokenDump {
    NSString *bar = self.barBgIsGradient
        ? [NSString stringWithFormat:@"grad:180;%@;%@", ColorStr(self.barBg), ColorStr(self.barBgTo)]
        : ColorStr(self.barBg);
    NSString *nav = self.navOnIsGradient
        ? [NSString stringWithFormat:@"grad:90;%@;%@", ColorStr(self.navOn), ColorStr(self.navOnTo)]
        : ColorStr(self.navOn);
    return @{
        @"bg": ColorStr(self.bg), @"bg2": ColorStr(self.bg2), @"bg3": ColorStr(self.bg3),
        @"card": ColorStr(self.card),
        @"topbg": ColorStr(self.topBg), @"barbg": bar, @"bar-border": ColorStr(self.barBorder),
        @"line": ColorStr(self.line), @"line2": ColorStr(self.line2),
        @"hov": ColorStr(self.hov), @"hov2": ColorStr(self.hov2),
        @"field": ColorStr(self.field), @"crumb": ColorStr(self.crumb),
        @"txt": ColorStr(self.text), @"txt2": ColorStr(self.text2),
        @"mut": ColorStr(self.mut), @"mut2": ColorStr(self.mut2),
        @"acc": ColorStr(self.accent), @"acc2": ColorStr(self.accent2),
        @"acc-weak": ColorStr(self.accentWeak), @"acc-text": ColorStr(self.accentText),
        @"nav-on": nav, @"nav-on-text": ColorStr(self.navOnText),
        @"cvbg": ColorStr(self.cvBg),
        @"phbg": [NSString stringWithFormat:@"grad:135;%@;%@", ColorStr(self.phFrom), ColorStr(self.phTo)],
        @"ph-txt": ColorStr(self.phText),
        @"shadow": ColorStr(self.shadow), @"track": ColorStr(self.track), @"toast": ColorStr(self.toast),
        @"ok": ColorStr(self.ok), @"ok-bg": ColorStr(self.okBg),
        @"ok-line": ColorStr(self.okLine), @"ok-text": ColorStr(self.okText),
        @"warn": ColorStr(self.warn), @"danger": ColorStr(self.danger),
        @"bp-direct": ColorStr(self.bpDirect),
        @"peq-hd": ColorStr(self.peqHd), @"peq-r1": ColorStr(self.peqR1), @"peq-r2": ColorStr(self.peqR2),
        @"r-lg": [NSString stringWithFormat:@"%g", self.rLg],
        @"r-md": [NSString stringWithFormat:@"%g", self.rMd],
        @"r-sm": [NSString stringWithFormat:@"%g", self.rSm],
        @"sidew": [NSString stringWithFormat:@"%g", self.sideW],
    };
}

@end
