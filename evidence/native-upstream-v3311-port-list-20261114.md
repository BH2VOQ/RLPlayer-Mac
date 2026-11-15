# RLPlayer2 v3.3.11 → 本仓 待移植候选清单（2026-11-15）

> 依据：`/tmp/rlp2-v3311/{ui_page.h,ui_script.h}`（tag v3.3.11 / 4ab338e3）与本仓
> `src/net/ui_{page,script}.h`、`tools/native_ui/*.mm` 的**关键词命中数**（机器可复核）。
> 命中数为 0 = 该能力在本仓对应层没有出现；不代表功能完全等价，仅作逐行对照的入口。

| 分组 | 关键词 | 上游 | 本仓 web | 原生 |
|---|---|---:|---:|---:|
| 音量旋钮 / 精确音量 | npVolKnob, npVolInput, npVolFloor, npRawVolumeNotice… | 27 | 0 | 0 |
| 封面手动设置 / 重置 | npSetCover, npResetCover, npCoverFile, /api/cover/set… | 23 | 0 | 0 |
| M3U 播放列表导入 | qImportM3u, qM3uFile, parseTransportM3u, importTransportM3u… | 14 | 0 | 0 |
| 快速启动 / 每日菜单 | qsApply, qsPreview, qsRefresh, rlDailyMenu… | 18 | 0 | 0 |
| 反馈结果展示 | rlFbBody, rlFbPreviewbox, rlFbResult, rlFbTitle… | 12 | 0 | 0 |
| 播放设置面板 | playbackSettingsMsg, playbackSettingsNotice, playbackSettingsRetry, ensurePlaybackSettings… | 41 | 0 | 0 |
| QA 引导流程 | /api/qa/next, /api/qa/done, /api/qa/text | 3 | 0 | 0 |
| 歌单 sq 写入 | /api/sq/add, /api/sq/create, addTrackToPlaylist, createPlaylistDialog | 8 | 3 | 8 |
| i18n 缺失上报 | /api/i18n/miss, i18nGet | 6 | 0 | 0 |
| 波形 / 传输进度 | npWaveform, npTransportSeek, paintTransportTime, pageVeil | 27 | 0 | 0 |
| 分析卡新实现 | anlL0Card, anlSkeletonHtml, anlCtlBar, anlDeepHtml… | 14 | 0 | 0 |

## 本仓 web 版完全未出现（w=0）的分组 —— 优先逐行对照

- **音量旋钮 / 精确音量**：上游关键词 npVolKnob, npVolInput, npVolFloor, npRawVolumeNotice, commitPreciseVolume, persistVolumeGesture, barVolDb；原生层命中 0
- **封面手动设置 / 重置**：上游关键词 npSetCover, npResetCover, npCoverFile, /api/cover/set, /api/cover/reset, /api/cover/lookup, bindAlbumArtwork, covRetry；原生层命中 0
- **M3U 播放列表导入**：上游关键词 qImportM3u, qM3uFile, parseTransportM3u, importTransportM3u, m3uWindowsPath；原生层命中 0
- **快速启动 / 每日菜单**：上游关键词 qsApply, qsPreview, qsRefresh, rlDailyMenu, rlHomeNavLabel, applyQuickStartPreference, paintQuickStart；原生层命中 0
- **反馈结果展示**：上游关键词 rlFbBody, rlFbPreviewbox, rlFbResult, rlFbTitle, fbShowResult, /api/feedback/status；原生层命中 0
- **播放设置面板**：上游关键词 playbackSettingsMsg, playbackSettingsNotice, playbackSettingsRetry, ensurePlaybackSettings, persistSettings, playbackErrorText；原生层命中 0
- **QA 引导流程**：上游关键词 /api/qa/next, /api/qa/done, /api/qa/text；原生层命中 0
- **i18n 缺失上报**：上游关键词 /api/i18n/miss, i18nGet；原生层命中 0
- **波形 / 传输进度**：上游关键词 npWaveform, npTransportSeek, paintTransportTime, pageVeil；原生层命中 0
- **分析卡新实现**：上游关键词 anlL0Card, anlSkeletonHtml, anlCtlBar, anlDeepHtml, anlStatusText, npAnlCtl；原生层命中 0

## 说明

- 本表只做「字符串存在性」初筛，不证明功能等价；每项移植前需读上游实现、写判据跑红再改绿。
- 与铁律①一致：**只增不删**，不替换 UI 骨架（上游 `ui_script.h` 相对本仓 +8637/-8613 行）。
- 原生版还需再过一遍 `tools/native_ui/parity_scan.py` / `behavior_scan.py` 的静态盲区（见 known-deviations #12）。

## 进度（1.1.7.62）

- **音量旋钮 / 精确音量**：已落地 `npVolInput` 精确 dB 输入（V1–V7 判据，红→绿），
  见 `evidence/native-precise-volume-20261115.md`；旋钮本体 / 静音按钮 / 锁定闸门仍未做。
- 其余 9 组待继续逐条对照。

## 进度（1.1.7.64）

- **音量旋钮 / 精确音量**：`npVolInput` 精确 dB 输入（1.1.7.62）+ `npVolFloor` 静音/恢复
  （1.1.7.64）已落地；旋钮本体 / 底栏镜像 / 锁定闸门 / settings 写回仍未做。

## 进度（1.1.7.65）

- **M3U 播放列表导入**：解析纯函数 `RLPParseM3U`（POSIX 适配，U1–U10 判据）已落地，
  见 `evidence/native-m3u-parser-20261115.md`；队列页按钮 / 文件选择 / `/api/queue/set` 下仍未做。

## 进度（1.1.7.66）

- **M3U 播放列表导入**：**组完成** —— 解析纯函数（1.1.7.65）+ 队列页按钮 / 文件面板 /
  生产接缝 / `/api/queue/set` / 16 MiB 闸门 / `require_stopped`（1.1.7.66）。
  挂账：`askConfirm` 替换确认、`needsFolder` 追问（macOS 不需要）。
  见 `native-m3u-parser-20261115.md` / `native-m3u-import-20261115.md`。

## 进度（1.1.7.67）

- **封面手动设置 / 重置**：后端 `/api/cover/set|reset` + 读侧手动封面优先（K0–K6，红→绿）已落地，
  见 `evidence/native-cover-set-20261115.md`；前端 `npSetCover/npResetCover` 按钮与
  `/api/meta` 的 `coverSource` 仍未做（下一包）。

## 进度（1.1.7.68）

- **反馈结果**：预览 `sp_fbpreview` + 持久结果区 `sp_fbresult` 已落地（P1–P9 / G1–G3，红→绿）。
  `/api/feedback/status` **不移植**（本仓客户端直传远端服务，无后端 job），见
  `evidence/native-feedback-result-20261115.md` 第 2 节的契约对照。

## 结论（N/A）

- **播放设置闸门 `PLAYBACK_SETTINGS` / `ensurePlaybackSettings`**：本仓**不适用**（不移植）。
  原生版 `startEmbedded()` 同步读设置、之后才建窗口，`ready=false` 状态不可达；
  照搬会得到永远为 true 的死代码。详见 `evidence/native-playback-settings-na-20261115.md`。
  唯一真实差异（非法保存音量静默 clamp、不提示用户）已挂账到偏差台账。

## 进度（1.1.7.69）

- **快速启动**：上游「快速开始页面」在 v3.3.11 已是死代码（`quickStartHtml` 无调用点、导航永久隐藏），
  **页面不移植**；真正活着的能力模型 `quickStartModel` 已移植为纯函数
  `+gatingForCapsJSON:`，驱动「播放方式」三档置灰 + 停止播放闸门（Q1–Q5，红→绿）。
  见 `evidence/native-quickstart-gating-20261115.md`。

## 结论（N/A）

- **QA 引导 / i18n 上报**：两者都是 **Web 前端的自动化验收设施**，不是用户功能，**不移植**。
  QA 驱动依赖 DOM 指令（`document.querySelector`），原生无对应物；本仓等价物是
  `rlplayer_native --audit`（246 项）+ 202 项 ctest。i18n 运行时上报的原生等价物是
  **编译期** `native_i18n_coverage`（当前 0 缺失）—— 比「出事才知道」更硬。
  见 `evidence/native-qa-i18n-harness-na-20261115.md`。

## 进度（1.1.7.70）

- **波形 / 传输进度**：可聚焦部分（``doSeek`` 的三条守卫 + clamp 0.9999 + ``toFixed(4)`` 精度）已移植，
  S1–S4 红→绿，见 ``evidence/native-seek-guard-20261115.md``。
  **``npWaveform`` 真波形未做**：它是跨「分析模块 + 缓存/后台 worker + 新端点 + Canvas 绘制」的
  新子系统（上游 ``src/analysis/waveform.h`` + ``src/net/ui_waveform.h`` 18.7 KB），超出小范围改动，
  需独立排期；证据第 5 节给了完整只读评估。播放页进度**功能**已完整（波形是可视化增强）。

## 进度（1.1.7.71）

- **音量旋钮本体**：播放页 npVolKnob 已落地（纯几何函数 + 自绘 + 拖动 + 26 条判据 K1–K10），
  见 evidence/native-volume-knob-20261115.md。挂账：底栏旋钮未做、尺寸受行高约束（40pt vs web 64pt）、
  拖动期间不下发（原生「松开才提交」纪律）、未接 NSAccessibility。

## 进度（1.1.7.72）

- **底栏音量旋钮** `volKnob` 已落地（复用同组件，350 项判据全绿），见 evidence/native-bar-knob-20261115.md。
  **同时纠正一处真实偏差**：上游 v3.3.11 的 volPosToDb（-55 位置曲线）已 0 处引用，
  原生底栏此前仍在用它，同一个 dB 在两个界面会落在不同位置。
  挂账：底栏静音键 volFloor、barVolInput 精确输入、volumePending 提示（后者属架构 N/A）。

## 进度（1.1.7.73）

- **底栏精确 dB 输入** barVolInput 已落地，判据顺带抓出并修好一处**两处共有**的真缺陷：
  text.doubleValue 对非数字返回 0，而 0 dB 合法 ⟹ abc 被当 0 dB 下发。
  见 evidence/native-bar-voldb-20261115.md。挂账：barVolDb 输出（需辅助功能语义）、volFloor 底栏静音键。
