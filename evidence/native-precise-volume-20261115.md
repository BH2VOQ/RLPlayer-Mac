# v3.3.11 `npVolInput` 精确 dB 音量输入（1.1.7.62）

> 待移植清单第 1 组「音量旋钮 / 精确音量」的**第一部分**。
> 方向：骨架与语言不动，照 Windows v3.3.11 UI 补 AppKit UI；不新增后端端点、不新增 i18n 词条。

## 1. 上游真值（`/tmp/rlp2-v3311/`）

| 位置 | 内容 |
|---|---|
| `ui_page.h:1582` | `<input id=npVolInput type=number min=-120 max=20 step=0.1 value=0 disabled aria-label='精确音量（dB）'>`；同组还有 `npVolKnob`（SVG 圆弧滑块）、`npVolFloor`（静音/恢复）、`npRawVolumeNotice`（设备调音提示） |
| `ui_script.h:6381-6395` | `commitPreciseVolume(field)`：`trim` → `Number` → 校验 `-120..+20` + `isFinite` → `Math.round(v*10)/10` → `setVol(value,true)` → `commitVolumeGesture()`（写 `volume=` settings）；非法值 `aria-invalid=true` + toast；`change` / `Enter` 确认、`Escape` 恢复 |
| `ui_script.h:6365-6369` | `syncVolUi()` 同步 `barVolInput`/`npVolInput` 数值、`npVolLab` 标签、`npVolFloor` 的静音态 |

## 2. 本仓落地前的状态

- `RLPNPControlBar` 只有 `volume` 滑块（0..1000 **位置刻度**，曲线 `-55*(1-p)^1.6`）+
  `volLabel`（58pt 右对齐）；`onCommitVolume:` 下发 `/api/volume?db=%.1f`。
- 本仓后端 `/api/volume` 已存在（`tools/rtaweb.cpp:12298`），支持 `db=` 参数，
  **不需要新端点**；`RLPNPVolDbToPos` / `RLPNPVolDbLabel` 已是文件级纯函数。
- v3.3.11 的 `-120~+20 dB` 线性范围是新增能力；本仓滑块曲线只覆盖 `-55~0` + 静音档，
  两者不冲突（精确输入可直接下发任意 dB，滑块只被映射到端点）。

## 3. 实现（1.1.7.62）

| 项 | 做法 |
|---|---|
| 控件 | `RLPNPControlBar.volDbField`：`NSTextField`，identifier `npVolInput`，48pt，等宽 11pt 右对齐，tooltip 复用既有词条 `音量（dB）` |
| 布局 | 放在 `volIcon` **左侧**；宽窗口保持 web 的 104pt 滑块不动，窄窗口才按 `minIconX` 守卫收缩滑块（`RLPNPControlBar layout`） |
| action | `onCommitPreciseVolume:`：`trim` → `doubleValue` → 校验 `text.length && isfinite && -120<=v<=20` → `round(v*10)/10` → 下发 `/api/volume?db=%.1f` → 同步 `volLabel`（`RLPNPVolDbLabel`）、滑块（`RLPNPVolDbToPos`）、`preciseVolumeDb` |
| 非法值 | 按 web `aria-invalid` 等价：`layer.borderColor = --danger` + 1px 边 + 输入框恢复已确认值，**不发请求** |
| 状态同步 | `refresh` 读 `/api/status` 的 `volumeDb` 时同步 `volDbField` 与 `preciseVolumeDb`，避免轮询把精确值冲掉 |
| i18n | 复用 `音量（dB）` → `Volume (dB)`，**未改任何生成表**（`i18n_table_check` / `native_i18n_table_check` 保持绿） |

## 4. 红 → 绿（`test_native_nowplaying_web.mm` 新增 V1–V7）

| 判据 | 旧码 | 新码 |
|---|---|---|
| V1 `npVolInput` 控件存在且 identifier 正确 | FAIL | PASS |
| V2 有真实 target/action | 跳过 | PASS |
| V3 输入 `-12.5` 真下发 `/api/volume?db=-12.5` | 跳过 | PASS |
| V4 `volLabel` 同步为 `-12.5 dB` | 跳过 | PASS |
| V5 越界 `99` 不下发请求 | 跳过 | PASS |
| V6 越界后输入框恢复已确认值 `-12.5` | 跳过 | PASS |
| V7 `-120` 静音档真下发 `/api/volume?db=-120.0` | 跳过 | PASS |

| 轮次 | 结果 | 证据 |
|---|---|---|
| 旧码（仅判据） | build 0 error；**1 FAIL**（V1，其余因 `vf=nil` 跳过） | `evidence/native-precise-volume-red-20261115.log` |
| 新码（1.1.7.62） | build 0 error；4 项相关 ctest 全绿 | `evidence/native-precise-volume-green-20261115.log` |

## 5. 如实挂账（本组未做完的部分）

1. **未移植** `npVolKnob` SVG 圆弧旋钮、`npVolKnobArc/Ticks/Val`、
   `npRawVolumeNotice` 设备调音提示、`barVolInput`/`barVolDb`（底栏镜像）。
   `npVolFloor` 静音/恢复按钮**已于 1.1.7.64 补齐**，见 `evidence/native-volume-mute-20261115.md`。
2. **未移植** `PLAYBACK_SETTINGS.ready` / `isRawVolumeLocked()` 的锁定闸门与
   `persistVolumeGesture`（`volume=` settings 写回）；本包只做「输入 → 下发 → 同步」主链路。
3. **未复刻** web 非法值的 toast 文案（避免新增 i18n 词条），改用红边框 + 恢复值；
   `Escape` 取消未接（AppKit 需 `cancelOperation:` 拦截）。
4. **位置差异**：web 的 `npVolInput` 在滑块右侧的 `.rlVolumeValue` 里，原生放在图标左侧
   （控制条右端 58pt 标签 + 104pt 滑块已占满，加输入框会压到中键区）。如实披露。
5. 精确值超出滑块曲线范围（如 `+20` / `-120`）时，滑块只映射到端点，标签仍显示精确值。
