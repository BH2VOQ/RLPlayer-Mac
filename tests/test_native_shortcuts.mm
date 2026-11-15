// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
// Offline judgement only: never opens a device, never starts the core.
#import <AppKit/AppKit.h>
#import "RLPShortcuts.h"
#include <math.h>
#include <stdio.h>

static int failures;
static void check(bool ok, const char *name) {
    printf("[%s] %s\n", ok ? "PASS" : "FAIL", name);
    if (!ok) ++failures;
}
static bool near(double a, double b, double tol) { return fabs(a - b) <= tol; }

int main() { @autoreleasepool {
    [NSApplication sharedApplication];

    // ---- S1–S8：按键 → 动作（逐条对齐 web document keydown）----
    struct { const char *key; BOOL cmd, shift, ctrl, editing; RLPShortcutAction want; const char *name; } cases[] = {
        { "f", YES, NO,  NO,  NO, RLPShortcutFocusSearch,     "S1 Cmd+F 聚焦搜索" },
        { "f", NO,  NO,  YES, NO, RLPShortcutFocusSearch,     "S2 Ctrl+F 也聚焦（web 同判）" },
        { " ", NO,  NO,  NO,  NO, RLPShortcutPlayPause,       "S3 Space 播放/暂停" },
        { "\uf703", NO, NO,  NO,  NO, RLPShortcutNext,        "S4 右箭头切下一首" },
        { "\uf703", NO, YES, NO,  NO, RLPShortcutSeekForward5,"S5 Shift+右箭头 = +5 秒" },
        { "\uf702", NO, NO,  NO,  NO, RLPShortcutPrev,        "S6 左箭头切上一首" },
        { "\uf702", NO, YES, NO,  NO, RLPShortcutSeekBack5,   "S7 Shift+左箭头 = -5 秒" },
        { "\uf700", NO, NO,  NO,  NO, RLPShortcutVolumeUpCoarse,  "S8 上箭头 +0.5 dB" },
        { "\uf700", NO, YES, NO,  NO, RLPShortcutVolumeUpFine,    "S9 Shift+上箭头 +0.1 dB" },
        { "\uf701", NO, NO,  NO,  NO, RLPShortcutVolumeDownCoarse,"S10 下箭头 -0.5 dB" },
        { "\uf701", NO, YES, NO,  NO, RLPShortcutVolumeDownFine,  "S11 Shift+下箭头 -0.1 dB" },
        { "n", NO, NO, NO, NO, RLPShortcutNext,   "S12 n = 下一首" },
        { "p", NO, NO, NO, NO, RLPShortcutPrev,   "S13 p = 上一首" },
        { "s", NO, NO, NO, NO, RLPShortcutStop,   "S14 s = 停止" },
        { "l", NO, NO, NO, NO, RLPShortcutLyrics, "S15 l = 歌词/单曲页" },
        { "\u001b", NO, NO, NO, NO, RLPShortcutEscapeBack, "S16 Esc 层级返回" },
        { "k", NO, NO, NO, NO, RLPShortcutNone,   "S17 无关按键不触发" },
        { "n", YES, NO, NO, NO, RLPShortcutNone,  "S18 Cmd+N 不被吃掉" },
        { "s", NO, YES, NO, NO, RLPShortcutNone,  "S19 Shift+S 不触发停止" },
        { "n", NO, NO, NO, YES, RLPShortcutNone,  "S20 输入框里打 n 不切歌" },
        { "f", YES, NO, NO, YES, RLPShortcutFocusSearch, "S21 输入框里 Cmd+F 仍聚焦搜索" },
        { "\u001b", NO, NO, NO, YES, RLPShortcutEscapeBack, "S22 输入框里 Esc 仍可返回" },
    };
    for (auto &c : cases) {
        RLPShortcutAction got = RLPShortcutActionForKey([NSString stringWithUTF8String:c.key],
                                                       c.cmd, c.shift, c.ctrl, c.editing);
        check(got == c.want, c.name);
        if (got != c.want) printf("    key=%s got=%ld want=%ld\n", c.key, (long)got, (long)c.want);
    }

    // ---- V1–V6：音量微调语义（web volNudge 逐条）----
    {
        BOOL ch = NO; double got = RLPVolumeNudgeDb(-120.0, 0.5, &ch);
        check(near(got, -54.5, 1e-6) && ch, "V1 静音档按 ↑ 直接到可闻第一档 -54.5");
        got = RLPVolumeNudgeDb(-120.0, -0.5, &ch);
        check(near(got, -120.0, 1e-6) && !ch, "V2 静音档再按 ↓ 仍是静音且无变化（不发请求）");
        got = RLPVolumeNudgeDb(-12.34, 0.5, &ch);
        check(near(got, -12.0, 1e-6) && ch, "V3 粗档落到 0.5 栅格（-12.34+0.5=-11.84 → round(-23.68)*0.5 = -12.0）");
        got = RLPVolumeNudgeDb(-12.34, 0.1, &ch);
        check(near(got, -12.2, 1e-6) && ch, "V4 细档落到 0.1 栅格（-12.34+0.1=-12.24 → round(-122.4)*0.1 = -12.2）");
        got = RLPVolumeNudgeDb(-0.2, 0.5, &ch);
        check(near(got, 0.0, 1e-6) && ch, "V5 越过 0 dB 夹到 0（不削波）");
        got = RLPVolumeNudgeDb(-54.5, -0.5, &ch);
        check(near(got, -120.0, 1e-6) && ch, "V6 跌破可闻下限落静音档 -120");
        got = RLPVolumeNudgeDb(-55.0, 0.5, &ch);
        check(near(got, -54.5, 1e-6), "V7 -55（静音档边界）按 ↑ 到 -54.5");
        got = RLPVolumeNudgeDb(-54.6, 0.1, &ch);
        check(near(got, -54.5, 1e-6), "V8 -54.6 按 ↑0.1 回到可闻下限 -54.5");
        got = RLPVolumeNudgeDb(0.0, 0.5, &ch);
        check(near(got, 0.0, 1e-6) && !ch, "V9 已在 0 dB 再按 ↑ 不变（不越界成正增益）");
    }

    // ---- 常量与 web 一致（防止两处写死后漂移）----
    check(near(RLPVolumeStepCoarseDb, 0.5, 1e-9), "C1 粗档 = 0.5 dB（web VOL_STEP_DB）");
    check(near(RLPVolumeStepFineDb, 0.1, 1e-9), "C2 细档 = 0.1 dB（web VOL_FINE_DB）");
    check(near(RLPVolumeSilentDb, -120.0, 1e-9), "C3 静音 = -120 dB（web VOL_SILENT_DB）");
    check(near(RLPVolumeAudibleDb, -54.5, 1e-9), "C4 可闻第一档 = -54.5 dB（web VOL_AUDIBLE_DB）");

    printf("shortcuts: %d failures\n", failures);
    return failures ? 1 : 0;
} }