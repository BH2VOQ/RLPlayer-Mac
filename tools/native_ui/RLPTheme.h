// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPTheme.h — web 版 CSS 自定义属性的**逐值移植**（不是"看起来差不多"）。
//
// 真相源：src/net/ui_page.h
//   :root                                  → dark（Apple Music 深色）
//   html[data-theme=light]                 → light（Apple Music 浅色）
//   html[data-uistyle=classic]             → classic × dark
//   html[data-uistyle=classic][data-theme=light] → classic × light
//
// 纪律（本轮定的，之前违反过）：
//   1. **不许自造色**。web 的 dark 是 #161618 近黑，不是墨绿青；
//      之前原生 dark 写成 #121a19（墨绿）是发明，导致两端观感对不上。
//   2. **不许自造字体**。web 全站 font-family 是
//      Inter,'Segoe UI Variable','Segoe UI',system-ui,sans-serif —— **没有任何衬线**。
//      之前原生用 Georgia/Georgia-Bold 做 display/heading/serif 是发明。
//      这三个属性名保留（调用点多），但返回的是 web 同字号的无衬线字重。
//   3. 每个值都要能被 tools/native_ui/theme_parity.py 机械核对。
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const RLPThemeDidChangeNotification;

@interface RLPTheme : NSObject
+ (instancetype)current;
/// 暴露给设置页的主题名。web 另有 blue，但用户 2026-11-11 明确「主题只留 light/dark」，
/// 故不暴露 blue（这是**用户的决定**，不是漏移植；见 docs/native-ui/PLAN.md §8）。
+ (NSArray<NSString *> *)themeNames;          // dark / light
+ (NSString *)themeName;
+ (void)setThemeName:(NSString *)name;

/// 界面风格（web html[data-uistyle]）：apple / classic。
/// web 的 classic 换的是**整套令牌**（强调色由珊瑚红变蓝、圆角 14/10/8 变 12/9/7），
/// 不是只存个偏好值。之前原生只 POST uistyle 到后端、界面毫无变化 —— 那是假实现。
+ (NSArray<NSString *> *)uiStyles;            // apple / classic
+ (NSString *)uiStyle;
+ (void)setUiStyle:(NSString *)style;

@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *style;   // apple / classic
@property (nonatomic, readonly) BOOL isLight;
@property (nonatomic, readonly) BOOL isClassic;

// ── 背景层（--bg / --bg2 / --bg3 / --card / --topbg / --barbg）──
@property (nonatomic, readonly) NSColor *bg;
@property (nonatomic, readonly) NSColor *bg2;
@property (nonatomic, readonly) NSColor *bg3;
@property (nonatomic, readonly) NSColor *barBg;
@property (nonatomic, readonly) NSColor *topBg;
@property (nonatomic, readonly) NSColor *crumb;        // --crumb
@property (nonatomic, readonly) NSColor *barBorder;    // --bar-border
// classic 的 --barbg / --nav-on 是 linear-gradient；NSColor 装不下渐变 ⟹
// 用「是否渐变 + 第二端 + 角度」表达，绘制侧按需画 CAGradientLayer。
@property (nonatomic, readonly) BOOL barBgIsGradient;
@property (nonatomic, readonly) NSColor *barBgTo;
@property (nonatomic, readonly) BOOL navOnIsGradient;
@property (nonatomic, readonly) NSColor *navOnTo;

// ── 文字四档（--txt / --txt2 / --mut / --mut2）──
@property (nonatomic, readonly) NSColor *text;
@property (nonatomic, readonly) NSColor *text2;
@property (nonatomic, readonly) NSColor *mut;
@property (nonatomic, readonly) NSColor *mut2;         // --mut2（之前缺）

// ── 线与交互态（--line / --line2 / --hov / --hov2 / --field）──
@property (nonatomic, readonly) NSColor *line;
@property (nonatomic, readonly) NSColor *line2;
@property (nonatomic, readonly) NSColor *hov;
@property (nonatomic, readonly) NSColor *hov2;
@property (nonatomic, readonly) NSColor *field;

// ── 强调（--acc / --acc2 / --acc-weak / --acc-text）──
@property (nonatomic, readonly) NSColor *accent;
@property (nonatomic, readonly) NSColor *accent2;      // --acc2（渐变按钮第二端，之前缺）
@property (nonatomic, readonly) NSColor *accentWeak;
@property (nonatomic, readonly) NSColor *accentText;
@property (nonatomic, readonly) NSColor *navOn;        // --nav-on
@property (nonatomic, readonly) NSColor *navOnText;    // --nav-on-text（之前缺）

// ── 语义状态（--ok / --ok-bg / --ok-line / --ok-text / --warn / --danger / --bp-direct）──
@property (nonatomic, readonly) NSColor *ok;
@property (nonatomic, readonly) NSColor *okBg;
@property (nonatomic, readonly) NSColor *okLine;
@property (nonatomic, readonly) NSColor *okText;
@property (nonatomic, readonly) NSColor *warn;
@property (nonatomic, readonly) NSColor *danger;
@property (nonatomic, readonly) NSColor *bpDirect;     // --bp-direct（bit-perfect 直通紫）

// ── 封面与占位（--cvbg / --phbg 两端 / --ph-txt）──
@property (nonatomic, readonly) NSColor *cvBg;
@property (nonatomic, readonly) NSColor *phFrom;
@property (nonatomic, readonly) NSColor *phTo;
@property (nonatomic, readonly) NSColor *phText;

// ── 阴影 / 进度轨 / toast（--shadow / --track / --toast）──
@property (nonatomic, readonly) NSColor *shadow;
@property (nonatomic, readonly) NSColor *track;
@property (nonatomic, readonly) NSColor *toast;

// ── PEQ 表格三层（--peq-hd / --peq-r1 / --peq-r2）──
@property (nonatomic, readonly) NSColor *peqHd;
@property (nonatomic, readonly) NSColor *peqR1;
@property (nonatomic, readonly) NSColor *peqR2;

// ── 兼容别名：旧调用点用的名字，值一律指回 web 的对应令牌 ──
// web 没有"墨绿 hero / 瓷白 cardAlt"这些概念，它们是上一轮的发明。
// 保留属性名以免大面积改调用点，但**值不再是发明的色**：
@property (nonatomic, readonly) NSColor *hero;      // = text（web 大标题用 --txt）
@property (nonatomic, readonly) NSColor *card;      // = bg3（web --card 就等于 --bg3）
@property (nonatomic, readonly) NSColor *cardAlt;   // = bg2
@property (nonatomic, readonly) NSColor *hairline;  // = line
@property (nonatomic, readonly) NSColor *chip;      // = accentWeak

// ── 字体：web 全站无衬线。字号/字重逐条对齐 ui_page.h ──
@property (nonatomic, readonly) NSFont *display;    // .ahead h1 26px/750
@property (nonatomic, readonly) NSFont *heading;    // .ptitle 24px/750 的次级：19px/650
@property (nonatomic, readonly) NSFont *serif;      // 名字是历史遗留；实为 .nptit 无衬线
@property (nonatomic, readonly) NSFont *pageTitle;  // .ptitle 24px/750 letter-spacing -0.5
@property (nonatomic, readonly) NSFont *cardTitle;  // .am-card-title 28px/800
@property (nonatomic, readonly) NSFont *navFont;    // .nav 13px/450
@property (nonatomic, readonly) NSFont *navFontOn;  // .nav.on 13px/600
@property (nonatomic, readonly) NSFont *secFont;    // .sec 11px/600 letter-spacing .5
@property (nonatomic, readonly) NSFont *caption;    // 11px
@property (nonatomic, readonly) NSFont *body;       // body 13px
@property (nonatomic, readonly) NSFont *small;      // 11.5px
@property (nonatomic, readonly) NSFont *title;      // 17px/600
@property (nonatomic, readonly) NSFont *mono;       // ui-monospace 11.5px tabular

// ── 几何：web 的确切像素值 ──
@property (nonatomic, readonly) CGFloat rLg;      // --r-lg  apple 14 / classic 12
@property (nonatomic, readonly) CGFloat rMd;      // --r-md  apple 10 / classic 9
@property (nonatomic, readonly) CGFloat rSm;      // --r-sm  apple 8  / classic 7
@property (nonatomic, readonly) CGFloat sideW;    // --sidew 226
@property (nonatomic, readonly) CGFloat topH;     // .top height 60（classic 52）
@property (nonatomic, readonly) CGFloat barH;     // .bar height 66
@property (nonatomic, readonly) CGFloat barRadius;// .bar border-radius 16
@property (nonatomic, readonly) CGFloat barMaxW;  // .bar max-width 1120
@property (nonatomic, readonly) CGFloat cardMinW; // .grid minmax(152px,1fr)
@property (nonatomic, readonly) CGFloat gridGap;  // .grid gap 16
@property (nonatomic, readonly) CGFloat gridPad;  // .grid padding 18

/// 令牌导出（tools/native_ui/theme_parity.py 机械核对用）。
/// 值统一为 "R,G,B,A"（0-255 整数 + 3 位小数 alpha）；渐变是
/// "grad:<deg>;R,G,B,A;R,G,B,A"。web 侧脚本从 ui_page.h 解析成同一形式。
/// 「色值对不对」由此不再靠人眼，而是逐 token 比对。
- (NSDictionary<NSString *, NSString *> *)tokenDump;
@end

NS_ASSUME_NONNULL_END
