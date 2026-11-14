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
