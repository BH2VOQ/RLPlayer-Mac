# 全局快捷键（1.1.7.85）

用户 2026-11-15 指示：「整个程序的基底是 mac 的 web 版 … 优先修复当前程序已有的 bug，比如说未实现的快捷键功能」。

## web 基线（`src/net/ui_script.h:12428-12485`）

| 键 | 动作 | 出处 |
|---|---|---|
| Cmd/Ctrl+F | 聚焦搜索框并 select | `12429-12433` |
| Space | 播放/暂停 | `12442` |
| → / Shift+→ | 下一首 / +5 秒 | `12444-12449` |
| ← / Shift+← | 上一首 / −5 秒 | `12450-12455` |
| ↑ / Shift+↑ | 音量 +0.5 / +0.1 dB | `12458` |
| ↓ / Shift+↓ | 音量 −0.5 / −0.1 dB | `12459` |
| n / p / s / l | 下一首 / 上一首 / 停止 / 歌词 | `12461-12464` |
| Esc | 层级返回 | `12467+` |
| 输入框内 | 除 Cmd+F 与 Esc 外一律不触发 | `12436-12441` |

音量走 `volNudge`（`6258-6276`）：静音档按 ↑ 直接到可闻第一档 −54.5；档位栅格 0.5/0.1；>0 夹 0；低于 −54.5 落 −120；`next === cur` 不发请求。

## 原生实现

新模块 `tools/native_ui/RLPShortcuts.h/.mm`（纯函数，可离线判定）：
- `RLPShortcutActionForKey(key, cmd, shift, ctrl, editingText)` —— 判定顺序与 web 一致（Cmd+F 最先、输入框内只剩 Esc）。
- `RLPVolumeNudgeDb(currentDb, stepDb, &changed)` —— web `volNudge` 的逐字等价（静音档 / 栅格 / 夹取 / 1 位小数收尾 / 无变化不发请求）。
- 四个常量（0.5 / 0.1 / −120 / −54.5）单点定义，判据与实现共用，防两处写死后漂移。

接线（`RLPAppDelegate.mm`）：`applicationDidFinishLaunching` 末尾装 `NSEvent addLocalMonitorForEventsMatchingMask:NSKeyDownMask`，
只在本窗口生效；命中动作后 `handleShortcut:` → 复用已有入口（`playPause` / `nextTrack` / `previousTrack` / `stopPlayback:` / `seekToSeconds:` /
`/api/volume` + `updateVolumeUiForDb:`），歌词 → `RLPOpenNowPlayingNotification`，Esc → `RLPCloseNowPlayingNotification`，Cmd+F → `RLPFocusSearchNotification`。

**为什么用本地监视器而不是菜单 keyEquivalent**：菜单不接收「裸字母/裸空格」这类等价键（会抢输入），而且菜单项无法表达「输入框里不触发」这条 web 语义。

## 判据（`tests/test_native_shortcuts.mm`，35 条，先红后绿）

- S1–S22：按键 → 动作 22 条（含 Cmd+N 不吃、Shift+S 不触发、输入框里 n 不切歌、输入框里 Cmd+F/Esc 仍生效）。
- V1–V9：音量微调 9 条（静音档双向、0.5/0.1 栅格、0 dB 夹取、跌破 −54.5 落静音、边界 −55、0 dB 再按不变）。
- C1–C4：四个常量与 web 一致。

**红证据**：首轮 V3/V4 两条 FAIL，查证是**测试期望值算错**（−12.34+0.5 = −11.84 → `round(-23.68)*0.5 = -12.0`，不是 −12.5），
改正期望后 35/35 通过 —— 记为「判据自身先被修」，不是「实现向判据低头」。

## 门禁

- `ctest`：**204/204**（新增 `native_shortcuts`，原 203）。
- `rlplayer_native --audit`：246/0（未新增项，保持基线）。
- `parity_scan --check` missing=0；`behavior_scan --check` actionable=0；i18n 覆盖 0 缺失。

## ⚠️ 未验证

- **未真机按键验证**：本地监视器只在真实窗口里生效，本轮判据是离屏纯函数 + 构建/门禁；
  真机需你按 Space/←/→/↑/↓/n/p/s/l/Esc/Cmd+F 各试一次（见回报里的实机清单）。
- Cmd+F 的落点依赖专辑页对 `RLPFocusSearchNotification` 的响应，本轮**尚未接该通知**（见「下一步」）。
