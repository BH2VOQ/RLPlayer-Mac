// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_window_frame.mm — 启动窗口 frame 必须收敛在屏幕可见区
// 背景：autosave 会把换屏/拖拽后的 2975×1003 frame 永久保存；在 1920×1050 屏上恢复后
// 右半截在屏外，聆听室卡片与专辑被屏幕边缘裁掉（用户 2026-11-17 截图）。

#include <cstdio>
#import <AppKit/AppKit.h>
#import "RLPSupport.h"

static int g_fail = 0;
static void ck(BOOL cond, const char *what, NSString *detail = @"") {
    if (cond) {
        std::printf("  [PASS] %s\n", what);
    } else {
        std::printf("  [FAIL] %s %s\n", what, detail.UTF8String ?: "");
        ++g_fail;
    }
}
static BOOL same(NSRect a, NSRect b) {
    return fabs(a.origin.x - b.origin.x) < 0.5 && fabs(a.origin.y - b.origin.y) < 0.5 &&
           fabs(a.size.width - b.size.width) < 0.5 && fabs(a.size.height - b.size.height) < 0.5;
}
static NSString *str(NSRect r) {
    return [NSString stringWithFormat:@"%.0f,%.0f %.0fx%.0f", r.origin.x, r.origin.y, r.size.width, r.size.height];
}

int main() {
    @autoreleasepool {
        std::printf("=== test_native_window_frame（离线纯函数）===\n");
        const NSRect vis = NSMakeRect(0, 0, 1920, 1050);
        const NSSize minSize = NSMakeSize(900, 600);

        // 真实脏记录：2975 宽存于 1920 屏，右半截在屏外。
        NSRect dirty = NSMakeRect(572, -42, 2975, 1003);
        NSRect got = RLPClampWindowFrameToVisible(dirty, vis, minSize);
        ck(same(got, NSMakeRect(0, 0, 1920, 1003)),
           "2975×1003 @572,-42 收敛到 1920×1003 @0,0", str(got));

        NSRect huge = NSMakeRect(100, 100, 2500, 1200);
        got = RLPClampWindowFrameToVisible(huge, vis, minSize);
        ck(same(got, NSMakeRect(0, 0, 1920, 1050)),
           "超宽超高 frame 收敛为可见区全尺寸", str(got));

        NSRect small = NSMakeRect(50, 50, 800, 500);
        got = RLPClampWindowFrameToVisible(small, vis, minSize);
        ck(same(got, NSMakeRect(50, 50, 900, 600)),
           "低于最小尺寸的 frame 放大到 minSize 且位置不变", str(got));

        NSRect ok = NSMakeRect(300, 200, 1180, 760);
        got = RLPClampWindowFrameToVisible(ok, vis, minSize);
        ck(same(got, ok), "合法 frame 原样保留", str(got));

        NSRect negative = NSMakeRect(-200, -100, 1180, 760);
        got = RLPClampWindowFrameToVisible(negative, vis, minSize);
        ck(same(got, NSMakeRect(0, 0, 1180, 760)),
           "负坐标 frame 拉回可见区原点", str(got));

        const NSRect tinyScreen = NSMakeRect(0, 0, 800, 500);
        NSRect over = NSMakeRect(0, 0, 1000, 700);
        got = RLPClampWindowFrameToVisible(over, tinyScreen, minSize);
        ck(same(got, NSMakeRect(0, 0, 800, 500)),
           "可见区小于 minSize 时以可见区为准", str(got));

        // ---- 多屏：跨屏窗口不许被单屏可见区压窄（2026-11-18 夜间评审 B1）----
        {
            const NSRect dual[2] = { NSMakeRect(-1920, 0, 1920, 1080), NSMakeRect(0, 0, 1920, 1080) };
            const NSRect onRight = NSMakeRect(100, 100, 1180, 760);
            NSRect usableRight = RLPWindowUsableScreenRect(onRight, dual, 2);
            ck(same(usableRight, dual[1]), "窗口完全落在右屏时用右屏可用区", str(usableRight));

            const NSRect spanning = NSMakeRect(-1000, 100, 2400, 600);
            NSRect usable = RLPWindowUsableScreenRect(spanning, dual, 2);
            ck(same(usable, NSMakeRect(-1920, 0, 3840, 1080)),
               "跨屏窗口用多屏并集包围盒（不是单屏）", str(usable));
            NSRect spanningClamped = RLPClampWindowFrameToVisible(spanning, usable, minSize);
            ck(same(spanningClamped, spanning),
               "跨屏 2400 宽窗口不被收敛挤窄（旧实现会压成 1920 宽）", str(spanningClamped));

            const NSRect offLeft = NSMakeRect(-5000, 100, 1180, 760);
            NSRect offLeftClamped = RLPClampWindowFrameToVisible(offLeft, usable, minSize);
            ck(same(offLeftClamped, NSMakeRect(-1920, 100, 1180, 760)),
               "完全在屏外的窗口仍被拉回并集左缘", str(offLeftClamped));
        }

        // ---- 启动 frame 决策：有保存值就回放且不居中（2026-11-18 夜间评审 B2）----
        {
            const NSRect single[1] = { vis };
            const NSRect def = NSMakeRect(0, 0, 1180, 760);

            RLPWindowStartupFrame st =
                RLPWindowStartupFrameForSavedState("300 200 1180 760 ", def, single, 1, minSize);
            ck(!st.center && same(st.frame, NSMakeRect(300, 200, 1180, 760)),
               "有合法保存值时回放原 frame 且不居中（旧实现每次启动都回主屏中心）", str(st.frame));

            st = RLPWindowStartupFrameForSavedState("", def, single, 1, minSize);
            ck(st.center && same(st.frame, def), "没有保存值时用默认尺寸并居中", str(st.frame));

            st = RLPWindowStartupFrameForSavedState("2975 -42 2975 1003 ", def, single, 1, minSize);
            ck(!st.center && same(st.frame, NSMakeRect(0, 0, 1920, 1003)),
               "保存值越界时收敛到可见区（仍不居中）", str(st.frame));

            st = RLPWindowStartupFrameForSavedState("garbage", def, single, 1, minSize);
            ck(st.center && same(st.frame, def), "保存值损坏时按首启处理（默认 + 居中）", str(st.frame));
            ck(st.converged, "合法单屏下启动收敛标志为 YES");
        }

        // ---- S1：双屏等高、水平并排（跨屏允许且不被压窄）----
        {
            const NSRect dual[2] = { NSMakeRect(-1920, 0, 1920, 1080), NSMakeRect(0, 0, 1920, 1080) };
            const NSRect def = NSMakeRect(0, 0, 1180, 760);
            const NSRect spanning2 = NSMakeRect(-1000, -100, 2800, 760);
            NSRect usable = RLPWindowUsableScreenRect(spanning2, dual, 2);
            ck(same(usable, NSMakeRect(-1920, 0, 3840, 1080)),
               "S1 等高双屏跨屏窗口可用区为无缝并集", str(usable));
            NSRect clamped = RLPClampWindowFrameToVisible(spanning2, usable, minSize);
            ck(same(clamped, NSMakeRect(-1000, 0, 2800, 760)) &&
               RLPRectCoveredByScreens(clamped, dual, 2),
               "S1 2800宽跨屏窗口仅拉回下缘、不被压窄且完全落屏内", str(clamped));
            RLPWindowStartupFrame st =
                RLPWindowStartupFrameForSavedState("-1000 -100 2800 760 ", def, dual, 2, minSize);
            ck(st.converged && !st.center && same(st.frame, NSMakeRect(-1000, 0, 2800, 760)),
               "S1 启动回放跨屏保存值不居中且保持 2800 宽", str(st.frame));
        }

        // ---- S2：双屏不同高 / 错位（不含死区，必要时收敛到最近单屏）----
        {
            // S2a：底对齐，左 1920×1080，右 1920×900 (origin y=0)，右上方 [0,1920]×[900,1080] 为死区
            const NSRect s2a[2] = { NSMakeRect(-1920, 0, 1920, 1080), NSMakeRect(0, 0, 1920, 900) };

            const NSRect spanDead = NSMakeRect(-1000, 300, 2400, 700);
            NSRect usableA1 = RLPWindowUsableScreenRect(spanDead, s2a, 2);
            NSRect clampedA1 = RLPClampWindowFrameToVisible(spanDead, usableA1, minSize);
            ck(same(usableA1, NSMakeRect(-1920, 0, 3840, 900)) &&
               same(clampedA1, NSMakeRect(-1000, 200, 2400, 700)) &&
               RLPRectCoveredByScreens(clampedA1, s2a, 2),
               "S2a 跨屏窗口侵入竖向死区时收敛到公共高度带且保持 2400 宽", str(clampedA1));

            const NSRect seamDead = NSMakeRect(-400, 300, 1180, 760);
            NSRect usableA2 = RLPWindowUsableScreenRect(seamDead, s2a, 2);
            NSRect clampedA2 = RLPClampWindowFrameToVisible(seamDead, usableA2, minSize);
            ck(same(clampedA2, NSMakeRect(-400, 140, 1180, 760)) &&
               RLPRectCoveredByScreens(clampedA2, s2a, 2),
               "S2a 交界窗口侵入右屏上方死区时下移至两屏公共可见区", str(clampedA2));

            const NSRect mostlyLeftHigh = NSMakeRect(-600, 880, 1000, 200);
            NSRect usableA3 = RLPWindowUsableScreenRect(mostlyLeftHigh, s2a, 2);
            NSRect clampedA3 = RLPClampWindowFrameToVisible(mostlyLeftHigh, usableA3, NSZeroSize);
            ck(same(usableA3, s2a[0]) &&
               same(clampedA3, NSMakeRect(-1000, 880, 1000, 200)) &&
               NSContainsRect(s2a[0], clampedA3) &&
               RLPRectCoveredByScreens(clampedA3, s2a, 2),
               "S2a 主要在左屏高位仅轻触右屏时收敛到左屏且完整可见", str(clampedA3));

            const NSRect pureDead = NSMakeRect(200, 920, 1180, 760);
            NSRect usableA4 = RLPWindowUsableScreenRect(pureDead, s2a, 2);
            NSRect clampedA4 = RLPClampWindowFrameToVisible(pureDead, usableA4, minSize);
            ck(same(usableA4, s2a[1]) &&
               same(clampedA4, NSMakeRect(200, 140, 1180, 760)) &&
               NSContainsRect(s2a[1], clampedA4) &&
               RLPRectCoveredByScreens(clampedA4, s2a, 2),
               "S2a 完全落入右屏上方死区时拉回最近单屏 s2a[1]", str(clampedA4));

            // S2b：顶对齐，左 1920×1080 (y=0)，右 1920×900 (origin y=180)，右下方 [0,1920]×[0,180] 为死区
            const NSRect s2b[2] = { NSMakeRect(-1920, 0, 1920, 1080), NSMakeRect(0, 180, 1920, 900) };

            const NSRect spanBotDead = NSMakeRect(-1000, 50, 2400, 760);
            NSRect usableB1 = RLPWindowUsableScreenRect(spanBotDead, s2b, 2);
            NSRect clampedB1 = RLPClampWindowFrameToVisible(spanBotDead, usableB1, minSize);
            ck(same(usableB1, NSMakeRect(-1920, 180, 3840, 900)) &&
               same(clampedB1, NSMakeRect(-1000, 180, 2400, 760)) &&
               RLPRectCoveredByScreens(clampedB1, s2b, 2),
               "S2b 右屏 origin y=180 时跨屏窗口上移脱离底部死区", str(clampedB1));

            const NSRect seamBotDead = NSMakeRect(-200, 20, 1000, 180);
            NSRect usableB2 = RLPWindowUsableScreenRect(seamBotDead, s2b, 2);
            NSRect clampedB2 = RLPClampWindowFrameToVisible(seamBotDead, usableB2, minSize);
            ck(same(usableB2, s2b[0]) &&
               same(clampedB2, NSMakeRect(-1000, 20, 1000, 600)) &&
               NSContainsRect(s2b[0], clampedB2) &&
               RLPRectCoveredByScreens(clampedB2, s2b, 2),
               "S2b 交界窗口多在下方死区时收敛到最近主屏 s2b[0]", str(clampedB2));

            // S2c：大幅垂直错位（左 y=0..1080，右 y=600..1500，公共高度 480 < 窗口高 760）
            const NSRect s2c[2] = { NSMakeRect(-1920, 0, 1920, 1080), NSMakeRect(0, 600, 1920, 900) };
            const NSRect stagWin = NSMakeRect(-400, 400, 1180, 760);
            NSRect usableC = RLPWindowUsableScreenRect(stagWin, s2c, 2);
            NSRect clampedC = RLPClampWindowFrameToVisible(stagWin, usableC, minSize);
            ck(same(usableC, s2c[1]) &&
               same(clampedC, NSMakeRect(0, 600, 1180, 760)) &&
               NSContainsRect(s2c[1], clampedC) &&
               RLPRectCoveredByScreens(clampedC, s2c, 2),
               "S2c 公共纵带不足以容纳窗口时退化到交集最大单屏且不压扁高度", str(clampedC));
        }

        // ---- S3：屏间水平空隙（左 x=-1920..0，右 x=100..2020 留 100pt 空隙）----
        {
            const NSRect s3[2] = { NSMakeRect(-1920, 0, 1920, 1080), NSMakeRect(100, 0, 1920, 1080) };

            const NSRect crossGapR = NSMakeRect(-400, 100, 1200, 760);
            NSRect usable1 = RLPWindowUsableScreenRect(crossGapR, s3, 2);
            NSRect clamped1 = RLPClampWindowFrameToVisible(crossGapR, usable1, minSize);
            ck(same(usable1, s3[1]) &&
               same(clamped1, NSMakeRect(100, 100, 1200, 760)) &&
               NSContainsRect(s3[1], clamped1) &&
               RLPRectCoveredByScreens(clamped1, s3, 2),
               "S3 跨 100pt 空隙窗口不得将空隙当可用区，收敛到右屏", str(clamped1));

            const NSRect wideCrossGap = NSMakeRect(-1000, 100, 2400, 600);
            NSRect usable2 = RLPWindowUsableScreenRect(wideCrossGap, s3, 2);
            NSRect clamped2 = RLPClampWindowFrameToVisible(wideCrossGap, usable2, minSize);
            ck(same(usable2, s3[1]) &&
               same(clamped2, NSMakeRect(100, 100, 1920, 600)) &&
               NSContainsRect(s3[1], clamped2) &&
               RLPRectCoveredByScreens(clamped2, s3, 2),
               "S3 超宽窗口跨空隙时压回单屏右屏且不跨越空隙", str(clamped2));

            const NSRect crossGapL = NSMakeRect(-1000, 100, 1400, 760);
            NSRect usable3 = RLPWindowUsableScreenRect(crossGapL, s3, 2);
            NSRect clamped3 = RLPClampWindowFrameToVisible(crossGapL, usable3, minSize);
            ck(same(usable3, s3[0]) &&
               same(clamped3, NSMakeRect(-1400, 100, 1400, 760)) &&
               NSContainsRect(s3[0], clamped3) &&
               RLPRectCoveredByScreens(clamped3, s3, 2),
               "S3 跨空隙但主要在左屏时收敛到左屏", str(clamped3));

            const NSRect inGap = NSMakeRect(10, 100, 60, 760);
            NSRect usable4 = RLPWindowUsableScreenRect(inGap, s3, 2);
            NSRect clamped4 = RLPClampWindowFrameToVisible(inGap, usable4, minSize);
            ck(same(usable4, s3[0]) &&
               same(clamped4, NSMakeRect(-900, 100, 900, 760)) &&
               NSContainsRect(s3[0], clamped4) &&
               RLPRectCoveredByScreens(clamped4, s3, 2),
               "S3 完全落在空隙中时拉回最近左屏", str(clamped4));

            const NSRect s3Triple[3] = {
                NSMakeRect(-1920, 0, 1920, 1080),
                NSMakeRect(0, 0, 1920, 1080),
                NSMakeRect(2020, 0, 1920, 1080)
            };
            const NSRect triSpan = NSMakeRect(-500, 100, 2800, 700);
            NSRect usable5 = RLPWindowUsableScreenRect(triSpan, s3Triple, 3);
            NSRect clamped5 = RLPClampWindowFrameToVisible(triSpan, usable5, minSize);
            ck(same(usable5, NSMakeRect(-1920, 0, 3840, 1080)) &&
               same(clamped5, NSMakeRect(-880, 100, 2800, 700)) &&
               RLPRectCoveredByScreens(clamped5, s3Triple, 3),
               "S3 三屏仅右侧有空隙时保留左中两屏无缝跨屏、剔除右侧空隙", str(clamped5));
        }

        // ---- S4：可用区 <= 1pt（0.5pt 高度 / 宽度 / 边界 1.0pt）----
        {
            const NSRect tinyH = NSMakeRect(0, 0, 1920, 0.5);
            const NSRect tinyW = NSMakeRect(0, 0, 0.5, 1080);
            const NSRect tinyBoth = NSMakeRect(0, 0, 0.5, 0.5);
            const NSRect exact1 = NSMakeRect(0, 0, 1.0, 1080);
            const NSRect def = NSMakeRect(0, 0, 1180, 760);

            ck(NSIsEmptyRect(RLPWindowUsableScreenRect(ok, &tinyH, 1)) &&
               NSIsEmptyRect(RLPWindowUsableScreenRect(ok, &tinyW, 1)) &&
               NSIsEmptyRect(RLPWindowUsableScreenRect(ok, &tinyBoth, 1)) &&
               NSIsEmptyRect(RLPWindowUsableScreenRect(ok, &exact1, 1)),
               "S4 所有可用区 <=1pt 时 RLPWindowUsableScreenRect 明确返回 NSZeroRect（不收敛）");

            const NSRect mixed[2] = { tinyBoth, NSMakeRect(0, 0, 1920, 1080) };
            NSRect usableMixed = RLPWindowUsableScreenRect(ok, mixed, 2);
            ck(same(usableMixed, mixed[1]),
               "S4 混合退化屏与正常屏时跳过 <=1pt 屏并选用正常屏", str(usableMixed));

            RLPWindowClampResult rH = RLPClampWindowFrameToVisibleChecked(ok, tinyH, minSize);
            RLPWindowClampResult rW = RLPClampWindowFrameToVisibleChecked(ok, tinyW, minSize);
            RLPWindowClampResult rB = RLPClampWindowFrameToVisibleChecked(ok, tinyBoth, minSize);
            ck(!rH.converged && same(rH.frame, ok) &&
               !rW.converged && same(rW.frame, ok) &&
               !rB.converged && same(rB.frame, ok),
               "S4 <=1pt 下 RLPClampWindowFrameToVisibleChecked 明确返回 converged=NO 且原 frame 不被破坏",
               str(rB.frame));

            const NSRect zeroSize = NSMakeRect(50, 50, 0, 0);
            const NSRect negSize = NSMakeRect(50, 50, -100, -50);
            RLPWindowClampResult rZero = RLPClampWindowFrameToVisibleChecked(zeroSize, tinyBoth, minSize);
            RLPWindowClampResult rNeg = RLPClampWindowFrameToVisibleChecked(negSize, tinyBoth, NSZeroSize);
            ck(!rZero.converged && same(rZero.frame, NSMakeRect(50, 50, 900, 600)) &&
               !rNeg.converged && rNeg.frame.size.width > 0 && rNeg.frame.size.height > 0 &&
               same(rNeg.frame, NSMakeRect(50, 50, 2, 2)),
               "S4 <=1pt 且输入 frame 为 0/负尺寸时安全兜底为正尺寸、绝不输出 0 或负宽高",
               str(rZero.frame));

            RLPWindowStartupFrame stEmpty = RLPWindowStartupFrameForSavedState("", def, &tinyH, 1, minSize);
            RLPWindowStartupFrame stSaved = RLPWindowStartupFrameForSavedState("300 200 1180 760 ", def, &tinyBoth, 1, minSize);
            ck(!stEmpty.converged && stEmpty.center && same(stEmpty.frame, def) &&
               !stSaved.converged && !stSaved.center && same(stSaved.frame, ok),
               "S4 <=1pt 时启动函数明确 converged=NO 且保留安全正尺寸 frame", str(stSaved.frame));
        }

        // ---- S5：单屏 / 负坐标 / minSize<=0 / 垂直堆叠等不回归 ----
        {
            const NSRect toolWin = NSMakeRect(-50, 100, 300, 200);
            NSRect got0 = RLPClampWindowFrameToVisible(toolWin, vis, NSZeroSize);
            NSRect gotNeg = RLPClampWindowFrameToVisible(toolWin, vis, NSMakeSize(-10, -5));
            NSRect gotNaN = RLPClampWindowFrameToVisible(toolWin, vis, NSMakeSize(NAN, 0));
            ck(same(got0, NSMakeRect(0, 100, 300, 200)) &&
               same(gotNeg, NSMakeRect(0, 100, 300, 200)) &&
               same(gotNaN, NSMakeRect(0, 100, 300, 200)),
               "S5 minSize<=0/NaN 表示无下限，只改 origin 不撑大 300×200 窗口", str(got0));

            const NSRect negScreen = NSMakeRect(-1920, -1080, 1920, 1080);
            NSRect negClamp1 = RLPClampWindowFrameToVisible(NSMakeRect(-2200, -1200, 1180, 760), negScreen, minSize);
            NSRect negClamp2 = RLPClampWindowFrameToVisible(NSMakeRect(-500, 100, 1180, 760), negScreen, minSize);
            ck(same(negClamp1, NSMakeRect(-1920, -1080, 1180, 760)) &&
               same(negClamp2, NSMakeRect(-1180, -760, 1180, 760)),
               "S5 负坐标单屏收敛不回归", str(negClamp2));

            const NSRect stacked[2] = { NSMakeRect(0, 0, 1440, 900), NSMakeRect(-240, 900, 1920, 1080) };
            const NSRect tallCross = NSMakeRect(-100, 500, 1000, 1200);
            NSRect usableStack = RLPWindowUsableScreenRect(tallCross, stacked, 2);
            NSRect clampedStack = RLPClampWindowFrameToVisible(tallCross, usableStack, minSize);
            ck(same(usableStack, NSMakeRect(0, 0, 1440, 1980)) &&
               same(clampedStack, NSMakeRect(0, 500, 1000, 1200)) &&
               RLPRectCoveredByScreens(clampedStack, stacked, 2),
               "S5 垂直堆叠双屏跨屏窗口剔除左侧死区且保持跨屏高度", str(clampedStack));
        }

        std::printf("\n结果：%d failed\n", g_fail);
    }
    return g_fail == 0 ? 0 : 1;
}
