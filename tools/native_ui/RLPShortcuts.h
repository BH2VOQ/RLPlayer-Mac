// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 全局快捷键动作（逐条对齐 web `document.addEventListener('keydown')`，`ui_script.h:12428-12485`）。
typedef NS_ENUM(NSInteger, RLPShortcutAction) {
    RLPShortcutNone = 0,
    RLPShortcutFocusSearch,      ///< Cmd/Ctrl+F → 聚焦搜索框
    RLPShortcutPlayPause,        ///< Space
    RLPShortcutNext,             ///< → （无 Shift）
    RLPShortcutSeekForward5,     ///< Shift+→
    RLPShortcutPrev,             ///< ← （无 Shift）
    RLPShortcutSeekBack5,        ///< Shift+←
    RLPShortcutVolumeUpCoarse,   ///< ↑（0.5 dB）
    RLPShortcutVolumeUpFine,     ///< Shift+↑（0.1 dB）
    RLPShortcutVolumeDownCoarse, ///< ↓（0.5 dB）
    RLPShortcutVolumeDownFine,   ///< Shift+↓（0.1 dB）
    RLPShortcutStop,             ///< s
    RLPShortcutLyrics,           ///< l（打开单曲页/歌词）
    RLPShortcutEscapeBack,       ///< Esc（层级返回）
};

/// 纯映射：按键 + 修饰键 → 动作。web 的判定顺序也在里面（Cmd+F 最先、输入框内的字母键不触发）。
/// `editingText` 为 YES 时（焦点在输入框/文本视图里）只保留 Cmd+F 与 Esc，其余返回 None ——
/// 否则用户打歌词/搜专辑时按 n/p/s/l 会误触播放控制。
RLPShortcutAction RLPShortcutActionForKey(NSString * _Nullable key,
                                          BOOL command, BOOL shift, BOOL control,
                                          BOOL editingText);

/// web `volNudge` 的逐字等价：静音档处理、0.5/0.1 dB 栅格、越界夹取、1 位小数收尾。
/// `changed` 返回是否真的变了（web 里 next === cur 时不发请求）。
double RLPVolumeNudgeDb(double currentDb, double stepDb, BOOL * _Nullable changed);

/// web 的档位常量（判据与实现共用同一份，避免两处写死）。
extern const double RLPVolumeStepCoarseDb;   // 0.5
extern const double RLPVolumeStepFineDb;     // 0.1
extern const double RLPVolumeSilentDb;       // -120（后端 ≤-120 映射成增益 0）
extern const double RLPVolumeAudibleDb;      // -54.5（从静音往上第一档）

NS_ASSUME_NONNULL_END