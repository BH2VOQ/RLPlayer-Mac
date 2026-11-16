// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPShortcuts.h"
#include <math.h>

const double RLPVolumeStepCoarseDb = 0.5;
const double RLPVolumeStepFineDb   = 0.1;
const double RLPVolumeSilentDb     = -120.0;
const double RLPVolumeAudibleDb    = -54.5;
const double RLPVolumeMaxDb        = 20.0;

/// web `volDbToPos(db) <= VOL_SILENT_POS` 的等价判定：-55 以下（含 -120）都算静音档。
/// 直接用阈值比跨整条曲线更稳（曲线本身会把 -55..-120 全压到 0）。
static BOOL RLPIsSilentDb(double db) {
    return !isfinite(db) || db <= -55.0;
}

RLPShortcutAction RLPShortcutActionForKey(NSString * _Nullable key,
                                          BOOL command, BOOL shift, BOOL control,
                                          BOOL editingText) {
    if (!key.length) return RLPShortcutNone;
    // Cmd/Ctrl+F 最优先（web 同样放在最前，输入框里也生效）。
    if ((command || control) && [key caseInsensitiveCompare:@"f"] == NSOrderedSame)
        return RLPShortcutFocusSearch;
    if (editingText) {
        // 输入框内：只留 Esc（web 只对 #q 做 blur，其余输入框直接 return）。
        return [key isEqualToString:@"\u001b"] ? RLPShortcutEscapeBack : RLPShortcutNone;
    }
    if ([key isEqualToString:@" "]) return RLPShortcutPlayPause;
    if ([key isEqualToString:@"\u001b"]) return RLPShortcutEscapeBack;
    if ([key isEqualToString:@"\uf703"] || [key isEqualToString:@"NSRightArrowFunctionKey"]) {
        // 右箭头：Shift 才是 ±5 秒，否则切下一首（web 同序）。
        return shift ? RLPShortcutSeekForward5 : RLPShortcutNext;
    }
    if ([key isEqualToString:@"\uf702"] || [key isEqualToString:@"NSLeftArrowFunctionKey"])
        return shift ? RLPShortcutSeekBack5 : RLPShortcutPrev;
    if ([key isEqualToString:@"\uf700"] || [key isEqualToString:@"NSUpArrowFunctionKey"])
        return shift ? RLPShortcutVolumeUpFine : RLPShortcutVolumeUpCoarse;
    if ([key isEqualToString:@"\uf701"] || [key isEqualToString:@"NSDownArrowFunctionKey"])
        return shift ? RLPShortcutVolumeDownFine : RLPShortcutVolumeDownCoarse;
    // 单字母：只有不带任何修饰键时才算（Cmd+S 之类不能被吃掉）。
    if (command || control || shift) return RLPShortcutNone;
    if ([key isEqualToString:@"n"]) return RLPShortcutNext;
    if ([key isEqualToString:@"p"]) return RLPShortcutPrev;
    if ([key isEqualToString:@"s"]) return RLPShortcutStop;
    if ([key isEqualToString:@"l"]) return RLPShortcutLyrics;
    if ([key isEqualToString:@"i"]) return RLPShortcutSignalChain;   // web: showChain()
    return RLPShortcutNone;
}

double RLPVolumeNudgeDb(double currentDb, double stepDb, BOOL *changed) {
    if (changed) *changed = NO;
    if (!isfinite(stepDb) || stepDb == 0.0) return currentDb;
    const double cur = isfinite(currentDb) ? currentDb : 0.0;
    double next;
    if (RLPIsSilentDb(cur)) {
        // 静音档：往上一步直接到「可闻第一档」，往下仍是静音（web 同语义）。
        next = (stepDb > 0) ? RLPVolumeAudibleDb : RLPVolumeSilentDb;
    } else {
        const double grid = (fabs(stepDb) >= RLPVolumeStepCoarseDb - 1e-9) ? RLPVolumeStepCoarseDb
                                                                          : RLPVolumeStepFineDb;
        next = round((cur + stepDb) / grid) * grid;
        if (next > 0.0) next = 0.0;
        if (next < RLPVolumeAudibleDb - 1e-6)
            next = (stepDb < 0) ? RLPVolumeSilentDb : RLPVolumeAudibleDb;
    }
    next = round(next * 10.0) / 10.0;   // 浮点残留按 1 位小数收（标签与下发必须同一个数）
    if (changed) *changed = (next != cur);
    return next;
}

double RLPVolumeStepDb(double currentDb, double stepDb, BOOL *changed) {
    if (changed) *changed = NO;
    if (!isfinite(stepDb) || stepDb == 0.0) return currentDb;
    double cur = isfinite(currentDb) ? currentDb : 0.0;
    cur = round(fmin(RLPVolumeMaxDb, fmax(RLPVolumeSilentDb, cur)) * 10.0) / 10.0;
    const double grid = (fabs(stepDb) >= RLPVolumeStepCoarseDb - 1e-9) ? RLPVolumeStepCoarseDb
                                                                      : RLPVolumeStepFineDb;
    double next = round((cur + stepDb) / grid) * grid;
    next = round(fmin(RLPVolumeMaxDb, fmax(RLPVolumeSilentDb, next)) * 10.0) / 10.0;
    if (changed) *changed = (fabs(next - cur) > 1e-9);
    return next;
}