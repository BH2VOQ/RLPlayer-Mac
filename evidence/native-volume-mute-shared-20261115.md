# v3.3.11 底栏静音键 `volFloor` + 静音状态全局唯一（1.1.7.74）

> 待移植清单「音量」组：底栏静音键，以及把两处静音记忆值合并为一份。

## 1. 上游真值

| 元素 | 内容 |
|---|---|
| `ui_page.h:1501` | 底栏旋钮中心叠一个 `volFloor` 静音键（28×28，`aria-pressed` 表达静音态） |
| `ui_page.h:1581` | 播放页旋钮中心叠一个 `npVolFloor`（同构） |
| `ui_script.h:6372-6380` | `toggleVolumeMute`：**`volumeRestore` 是全局单例** —— `db<=-120` 时若有记忆值则恢复，否则直接 return；否则记住当前值并静音 |

**关键点**：上游两个静音键共用**同一个** `volumeRestore`。若各自记一份，就会出现
「在播放页静音 −12.5，到底栏点恢复」→ 恢复成底栏自己记的另一个值（或没有值直接不动）。

## 2. 实现（含一次状态收敛）

| 项 | 做法 |
|---|---|
| 共享状态 | `RLPSupport` 新增 `RLPVolumeMuteNextDb(double)` / `RLPVolumeMuteHasRestore(void)` / `RLPVolumeMuteReset(void)`，静态存储 `gVolumeRestoreDb`（`NAN` = web `volumeRestore === null`） |
| 播放页 | `onToggleVolumeMute:` 改为调用共享函数（**行为不变**，只是把记忆值搬到公共层）；1.1.7.64 的本地 `volumeRestoreDb` 属性不再参与判定 |
| 底栏 | 新增 `volMuteBtn`（identifier **`volFloor`**），作为**覆盖层**叠在旋钮圆盖中心（22×22），布局里不占簇宽度（与 web absolute 定位同语义） |
| 下发 | 底栏点击后与精确输入共用 `commitVolumeDb:` + `updateVolumeUiForDb:` |

## 3. 判据（`test_native_bar_web` 新增 6 条，累计 368 项全绿）

| 判据 | 钉住什么 |
|---|---|
| `volFloor` 存在 + identifier | 控件真的叫 `volFloor`（parity 命名一致） |
| 有真实 target/action | 不是摆设 |
| 静音键中心落在旋钮 frame 内 | 是**覆盖层**而不是占位控件（web 也是 absolute 居中） |
| 初始无恢复值 | `volumeRestore === null` 语义 |
| 点静音 → 下发 `-120.0` 且有了恢复值 | 静音路径 |
| 再点一次 → 恢复成 **-12.5**（不是默认值） | 恢复的是「静音前的值」而不是任何常量 |
| 恢复后清空记忆值 | 上游恢复后置 null |
| 已 -120 且无恢复值时点击**不发请求** | 上游 `if (volumeRestore === null) return` |

## 4. 红 → 绿

接线前 5 条判据 FAIL（控件不存在 / 无恢复值 / 不发请求等）；接线后 368 checks / 0 failures。
播放页 `np web: 0 failures` —— 状态收敛后原有 M1–M7（静音/恢复）判据仍全绿，证明重构未改变行为。

过程中被既有判据抓到的两处（真缺陷，非调阈值）：
1. 「静音键叠在旋钮内」首跑时静音键还在簇里占位（会挤压布局）⟹ 改为覆盖层并从簇宽累计中剔除；
2. 判据首次插在 `startPolling` 之前，`commitVolumeDb:` 因未轮询而不发请求 ⟹ 判据位置修正
   （这是**判据放置错误**，不是实现缺陷，如实记录）。

## 5. 如实挂账

1. **静音态的视觉表达未做**：web 用 `aria-pressed` + 图标切换（`volSound`/`volQuiet` 两条 path 交替）；
   原生底栏静音键固定用 `speaker.slash.fill`，不随状态换图标。
2. 播放页的 `npVolFloor` 与底栏 `volFloor` 都未接 NSAccessibility（`aria-pressed` 无对应物）。
3. `RLPVolumeMuteReset()` 已提供但当前无调用点（上游「重置」路径本轮未移植）。