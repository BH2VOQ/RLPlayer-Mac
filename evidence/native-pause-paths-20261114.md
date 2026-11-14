# P0-1 播放无法暂停：三入口请求契约（先红后绿）

- 日期：2026-11-14
- 仓库：`/Users/august/Downloads/DQ/RLPlayer`，branch `main`
- 基线 HEAD `d4b08af`（1.1.7.32）→ 本包 1.1.7.33
- 写者：single writer（本任务包）
- 范围：`tools/native_ui/RLPPlaybackBarView.mm` / `RLPNowPlayingViewController.mm` /
  `RLPAppDelegate.mm` / `RLPSupport.mm`（+ 新判据 `tests/test_native_pause_paths.mm`）
- 纪律：全程 `backend=null`、不启动核心的桩测试；没有向任何听音设备播过声音；没有打开可见窗口。

## 1. 三条入口的实际请求与回调（逐条列出）

| 入口 | 生产入口 | 冻结前的实际行为 | 本包之后 | 回调 / 状态落点 |
|---|---|---|---|---|
| 底栏播放/暂停键 | `RLPPlaybackBarView.playPause`（`playBtn` target/action） | 播放中：`/api/pause?on=1`；暂停中：`on=0`；**已停止：`on=0`（后端 no-op，看起来"按钮没反应"）** | 统一走 `RLPPlaybackToggle`：播放中 `on=1`、暂停中 `on=0`、**已停止 `/api/play` 重播当前曲目**（web `playOrPause` 同语义） | 下一次 `/api/status`（500 ms）→ `applyStatus` → 图标/进度/副标题 |
| 播放页暂停键 | `RLPNowPlayingViewController.onPause:`（`webControls.playBtn`） | 播放中 `on=1`、暂停中 `on=0`；**已停止 `on=0`（no-op）**；判定自己维护一份 | 同一 `RLPPlaybackToggle`（用页面自己的 `webStatus`），不再与底栏各写一套 | 页面自己的 `/api/status` 轮询（400 ms）→ `refresh` → 图标/进度 |
| 菜单「播放 / 暂停」 | `RLPAppDelegate.menuPlayPause:` → `bar.playPause` | 与底栏同一实现 | 与底栏同一实现（无分叉） | 底栏轮询回调 |
| 媒体键 pauseCommand | `MPRemoteCommandCenter.pauseCommand` handler | **先看 `playbackBar.isPlaying` 快照，快照为 false 时静默丢弃命令、仍返回 Success** | `[bar pausePlayback]`：**永远发 `/api/pause?on=1`**，不看快照 | 底栏轮询回调 → 图标回三角、进度冻结 |
| 媒体键 playCommand | `MPRemoteCommandCenter.playCommand` handler | `!isPlaying` 时调 `playPause`；停止态下发的是 `on=0` no-op | `[bar resumeOrReplay]`：已在播→空转；暂停中→`on=0`；已停止→`/api/play` 重播 | 同上 |
| 媒体键 togglePlayPause | `togglePlayPauseCommand` handler | `bar.playPause`（停止态 no-op） | `bar.playPause`（现在停止态会重播） | 同上 |
| 后端 | `/api/pause`（`tools/rtaweb.cpp:12349`） | 已正确：`ps.pauseReq.store(on)` → 播放线程 `sink->pause()` + `ps.paused=true`；`/api/status` 回 `playing=true, paused=true` | 未改后端（红证据证明缺口在 UI 请求侧，不在后端） | `ps.paused` / `ps.playing` |

> **不是"只改图标"**：本包改的是**请求生成**（三个入口 + 两个系统命令），图标仍由 `/api/status` 驱动，
> 判据断言的是"实际发出的请求路径"，而不是按钮图。

## 2. 为什么先跑红（旧码确实做不到的点）

实测旧码（1.1.7.32）在桩环境下：

| 判据 | 旧码结果 | 说明 |
|---|---|---|
| T1 已停止→底栏播放键 | **`/api/pause?on=0`** | 后端对停止态不起播 ⟹ 用户点"播放"没有任何反应 |
| T1 无当前曲目→不发无效请求 | **`/api/pause?on=0`** | 发了一个必然 no-op 的请求 |
| T2 已停止→播放页播放键 | **`/api/pause?on=0`** | 与 web `playOrPause`（停止→`playPath`）不一致 |
| T3 媒体键显式暂停入口 | **方法不存在**；旧 handler 依赖 `isPlaying` 快照 | 快照过期/降频时 pauseCommand 被静默丢弃 |
| T3 媒体键 play（已停止） | **方法不存在**；旧路径 `on=0` no-op | "系统播放键按了没反应"同型 |
| T3 媒体键 play（暂停中） | 方法不存在，旧路径会经 `playPause` 发 `on=0`（行为凑巧对） | 判据仍红在"入口不是同一个显式命令" |

**红/绿数字**：旧码 **8 passed / 8 failed**（`evidence/native-pause-paths-red-20261114.log`）；
新码 **16 passed / 0 failed**（`evidence/native-pause-paths-green-20261114.log`）。
同一份测试文件、同一个 CMake 目标，只换生产代码。

## 3. 改了什么

| 文件 | 改动 |
|---|---|
| `tools/native_ui/RLPSupport.h/.mm` | 新增唯一判定 `RLPPlaybackToggle` / `RLPPlaybackPauseExplicit` / `RLPPlaybackResumeOrReplay`；空队列提示复用既有 i18n 词条「队列是空的」 |
| `tools/native_ui/RLPPlaybackBarView.h/.mm` | `playPause` 改为走统一判定；新增媒体键显式入口 `pausePlayback` / `resumeOrReplay` |
| `tools/native_ui/RLPNowPlayingViewController.mm` | `onPause:` 改走统一判定（删掉页面自己那份 `playing&&!paused`） |
| `tools/native_ui/RLPAppDelegate.mm` | play/pause/toggle 回调改调显式入口（不再用 `isPlaying` 快照决定发不发） |
| `tests/test_native_pause_paths.mm` | 新增 ctest `native_pause_paths`（16 断言；桩核心记录请求路径，不启动播放） |
| `CMakeLists.txt` | 注册测试目标 |

## 4. 门禁（串行，机器空闲；本包树 = 1.1.7.33）

| 门禁 | 命令 | 结果 |
|---|---|---|
| 构建 | `cmake --build build-mac -j8` | **exit 0** |
| 全量单测 | `ctest --test-dir build-mac -j1 --output-on-failure` | **196/196 passed, 0 failed**（397.39 s，exit 0；`evidence/native-pause-paths-ctest-196.log`） |
| 功能审计 | 隔离 `RLPLAYER_STATE_DIR/LIBRARY_DIR/HOME` → `rlplayer_native --audit <tmp>/shots` | **246 passed, 0 failed**，exit 0（`evidence/native-pause-paths-audit-20261114.log`） |
| 移植扫描 | `python3 tools/native_ui/parity_scan.py --check` | `api done=96 missing=0 removed=0 na=16`；na 16 ok/0 bad、removed 2 ok/0 bad，exit 0 |
| 行为扫描 | `python3 tools/native_ui/behavior_scan.py --check` | `total bindings=50 actionable=0`，exit 0 |
| i18n | `python3 tools/gen_i18n_table.py --check` | `OK: i18n table up to date (2318 pairs)`，exit 0 |

## 5. 如实挂账（哪些只是回归防线 / 没证到的）

1. **用户"播放中按暂停没反应"的原始现象，在自动化环境没有复现**：我另外用一次性探针
   （`rlplayer_native` 同款真实 embedded 核心 + 真实 `performClick`，`backend=null`、`volume=-120`）
   跑过底栏与播放页：播放中点击 → `/api/status` 变 `paused=true` → 再点 → `paused=false`，两入口都正确。
   该探针未进仓库（P0-2 的构建里已删），故这里只作为排查记录，不作为判据。
   本包修复的是**可复现的红**（停止态 no-op、媒体键依赖过期快照、三处判定分叉）；
   用户实机的原现象需要在 1.1.7.33 上复测，不能声称已由本包直接消除。
2. **媒体键的真实回调无法离屏合成**：`MPRemoteCommandCenter` 的 handler 不能被测试进程调用。
   本包判据覆盖的是 handler **直接调用的生产方法**（`pausePlayback`/`resumeOrReplay`）
   及底栏/播放页的真实按钮点击；"系统按下 F8 后由 macOS 派发到 handler"这一步只能实机验证。
3. 播放页 `onPause:` 仍用页面自己的 400 ms 状态快照（与底栏 500 ms 一拍不同源，但同一判定函数）。
   当页面刚打开、首拍还没回来时点击，会按"已停止→重播"处理；这是与 web 一致的语义，不是丢命令。
4. 未在真实音频设备上验证"暂停后设备真的停声"：本轮所有自动化都不开设备。
   `/api/pause` 的后端路径未改，历史真机记录（STATUS.md）显示暂停冻结 pos、恢复继续。

## 6. 实机复测清单（由用户执行）

1. 用 `./build-mac/rlplayer_native` 启动，左下角应为 **v1.1.7.33**。
2. 播放一首，分别点：底栏播放键（暂停）、播放页暂停键（暂停）、键盘媒体键 / 菜单「播放 / 暂停」。
   预期：每一条都真的停住（进度冻结），再操作一次恢复。
3. 停止播放（底栏停止键）后再点播放键：预期**重新起播当前曲目**（旧版这里无反应）。
4. 若仍出现"播放中暂停无效"，请在该次运行里导出诊断包（设置·诊断→导出 zip）发回。
