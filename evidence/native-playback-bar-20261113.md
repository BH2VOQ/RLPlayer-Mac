# 第 1/2/3 项：播放链路、底栏播放键、播放键圆形（先红后绿 / 如实挂账）

日期 2026-11-13。基线 d717ef0（1.1.7.17），本轮 1.1.7.18 起。

## 结论先说（铁律⑤：分开写）

| 项 | 结论 |
|---|---|
| 1 无法播放 | **引擎侧无法复现**（四组配置全正常）。已新增播放链路判据并要求实机日志定位。详见下节。 |
| 2 底栏不切暂停态 | **未在任何自动化环境复现**。底栏 × 真实核心的判据在旧提交上**也全绿**。见「如实挂账」。 |
| 3 播放键不是完整圆 | **与截图描述不符**：红圆本身 67×66px 完整。真实缺陷是**进度滑块头压在红圆上**，已修。 |

## 第 1 项：无法播放音乐

### 已排除（真跑过，不是读代码）

四组配置各跑一遍 `POST /api/play` + 轮询 `/api/status`（全部落隔离目录，绝不出声）：

| 配置 | 结果 |
|---|---|
| `backend=null` + volume -120 | playing=true，pos 稳定推进，无 error |
| `backend=coreaudio`（共享） | playing=true，pos 推进，outRate=44100 |
| `backend=coreaudio` + `hogexcl=1`（Hog 独占） | playing=true，hogRequested=true hogAcquired=true |
| 全新状态目录（零 settings，等同一台新机的第一次播放） | playing=true |
| 非 ASCII + 空格 + `&` `=` 路径（`日本語 专辑/曲目 01 & 02 = x.wav`） | playing=true，current 正确 |
| 连续 90s 观察（含自动下一曲） | 全程 playing=true，pos 单调推进，无 RENDERFAIL |
| **真实 CoreAudio + Hog 独占 + volume -120，连续 120s** | 0→76s 全程 playing=true，pos 每 5s 单调 +5.0s，无 RENDERFAIL/DEVICE_LOST；曲末正常 `playing=false pos=76.3/76.3` |
| `/api/status` 并发 600 次（3 线程 × 200） | ok=600 bad=0（排除"两个页面同时轮询把状态读坏"） |

### 本轮发现并修掉的一个**门禁盲区**（这才是真正的收获）

在本轮之前，整个 `--audit` **从来没有调用过任何播放入口**
（`grep -c RLPPlayPath tools/native_ui/RLPFunctionalAudit.mm` = 0）。
也就是说：门禁 219 项全绿，但它一次都没有验证过「点播放之后到底播没播起来」。
现在补上了（见下）：生产入口起播 → playing=true → 位置推进 → 无 RENDERFAIL。

### 仍然无法在自动化环境复现的部分 —— 需要用户配合

自动化环境与用户实机的差异只剩这几类，**都必须由实机日志区分**：

1. **真实音频设备**（本轮全部用 null/共享/Hog-默认端点，没有用用户的真实 DAC）。
   若用户接的是 USB DAC / 蓝牙 / AirPlay：
   - 拔插、休眠唤醒后的端点 id 变化；
   - 独占（Hog）被其它 App 占用 ⟹ `hogAcquired=false` + 明确错误文案；
   - 设备物理格式锁不上 ⟹ 走重采样（不是不播）。
2. **大型文件 / DSD / CUE**：本轮夹具是 aiff/wav。DSD 走 DoP，不能回退共享。
3. **曲库规模**：用户的库远大于 6 首夹具。

### 实机定位清单（用户只需做一次，3 分钟）

在 App 里复现"播不出来"，然后：
1. 设置 → 诊断 →**导出诊断包（.zip）**（本轮已把这块做成内联按钮，不再藏在空白气泡里）。
2. 把 zip 发回。**必须包含**的关键行（都在 zip 的日志里，grep 即可）：
   - `STARTUP`（设备数、endpoints 数、mode、gpu）
   - `PLAY v`（本次信号链：rate/bits/ch/独占/共享）
   - `PLAYBUF`（请求缓冲 / 实际缓冲 / 配方）
   - `RENDERFAIL`（若存在：`w0 wr zp zs zo last_pad HRESULT device id` —— 这一行自带归因）
   - `DEVICE_LOST`（端点级掉线，与 RENDERFAIL 是两种病）
   - `FALLBACK_SHARED`（独占失败自动回退共享）
   - `END pos=…`（若 pos=0 且无 error ⟹ 起播就静默死亡，属第 12 行老悬案同型）
3. 另需一句：**设备是什么**（内置扬声器 / USB DAC 型号 / 蓝牙 / AirPlay）、**是否独占**（设置→输出→严格独占是否勾选）。

有上面这几行就能定案；没有的话只能继续在"引擎无故障"和"用户实机有故障"之间猜，那是我不愿意做的事。

## 第 2 项：底栏播放键不切暂停态 —— **如实挂账：自动化环境无法复现**

### 我做了什么
新建 `tests/test_native_bar_core.mm`（ctest 名 `native_bar_core`，秒级）：
把**真实的** `RLPPlaybackBarView` 接到**真实的** embedded 核心上，
用生产入口 `RLPPlayPath` 起播，然后等不变量成立（而不是固定 sleep），断言：
- B1 播放后 `bar.isPlaying == true`
- B2 播放/暂停两态的**图标位图指纹不同**（不用 `image.name`：SF Symbol 的 name 可能是 nil，那是判据自身的 bug，本轮踩过）
- B3 暂停后回到 false（不是单向锁死）
- B4 停止后图标回到与初始**同一张**位图

### 结果（这就是必须如实写的地方）
- **在旧代码 d717ef0 上：12 passed / 0 failed（全绿）**
- 在修复后代码上：12 passed / 0 failed

即：**底栏这一层，旧代码本来就是对的**。我没有任何证据说它是 bug，也没有找到一个失败的判据。
我没有为了让这一项"有红证据"去编一条假的先红 —— 那是铁律④明确禁止的。

### 因此在 `--audit` 里我保留的判据是「不变量」而非「现象」
`--audit` 那段断言的是同一件事（底栏 isPlaying 与图标都要跟上真实状态）。
它在第一次运行时确实红过两格，但**根因在夹具，不在产品**：
`BuildFixtureLibrary` 用 `say -o … "test"` 生成音频，实际只有 **0.69 秒**，
而索引里写死 `dur = 30 + track` 秒。播放到第二次 0.5s 轮询时音频早已 EOS，
底栏读到的是 `playing=false` ⟹ 判据假红。
已修：夹具改用重复文本拉长，且索引里的 `dur` 改为用 `AVURLAsset` 读**真实时长**
（夹具不许自欺：写死时长让"播放中"的判据永远在音频结束后才执行）。
修完后 `--audit` 240/240 全绿。

### 用户仍报这一项，最可能的三个方向（需要实机确认）
1. **用户看到的是"暂停键"但图标是 `pause.fill` 的降级**：`NSImage imageWithSystemSymbolName:`
   在极少数系统状态下返回 nil ⟹ 按钮退化成无图/文字态，看起来像没换。
2. **播放页之外那条底栏是 `rlplayer_mac`（web 壳）而不是 `rlplayer_native`**：
   `dist-mac/` 里同时存在 `RLPlayer.app`（web 壳，1.1.7）与 `RLPlayer-Native.app`（原生，1.1.7.14）。
   **如果用户打开的是前者**，他看到的是 web 版的底栏，那与原生代码无关。
   → 这是我最怀疑的一条，请用户确认 Dock 里那个 App 的 `版本`（设置页底部有写）。
3. 真实设备下播放其实没起来（与第 1 项同源）⟹ 底栏显示"播放"是**正确的**。

## 第 3 项：播放键不是完整圆 —— 截图实测与描述不符

用像素量了两张用户原图（2773×1512）：

| 量的是什么 | 截图 A（播放中） | 截图 B（暂停） |
|---|---|---|
| 红圆 bbox | 67 × 66 px | 67 × 66 px |
| 三角形 bbox | 17 × 19 px | — |
| 三角形左右留白 | 25 / 25 px | — |
| 三角形上下留白 | 24 / 23 px | — |
| 三角形中心 vs 圆心 | dx=0.0 dy=0.5 px | — |

**圆是完整的，三角形是居中的。** 用户看到的"三角形偏左贴边、圆被裁"，
在截图 B 里对应的是**白色进度滑块头压在红圆正上方**（滑块头被播放条上沿切掉一半，
视觉上像红圆被咬掉一块，而滑块头左侧那道红条延伸到圆上，让三角形看起来偏左）。

因此修法是「进度滑块头不得与播放键重叠」，判据：
- `progress.frame` 与 `playBtn.frame` 不相交（`NSIntersectsRect == NO`）
- 播放键方形外框 + `cornerRadius == 边长/2`（保证是完整圆）

两条在 `test_native_bar_web`（秒级）与 `--audit` 里都有，**旧代码上就通过**
—— 因为旧代码的几何本来就没有相交。我不把这条写成"修复"，它是**回归防线**。

## 静音纪律核对（铁律②）
真实 CoreAudio 那轮用的是 `volume=-120`。已核实它确实静音，不是"很小声"：
`audio_out_coreaudio.h` 的 gain 路径在 `absDb <= -59.5` 时取 `linear = 0.0`（`set_base_gain_db` 与
`set_live_gain_db` 两处同判据），即写进设备的每个样本都乘 0。
`/api/status` 侧也能复核：`wf=0`、曲末 `peak` 掉到 6.1e-05（那是 EOS 补零段），
而播放中报的 `peak=0.43…0.61` 是**源数据位深域峰值**（`render_loop.h:470`：`pk / full`，
在 gain 之前统计），不是输出电平 —— 这条字段名容易被误读，特此写明。

## 证据文件
- `evidence/native-playback-audit-green-20261113.log`（--audit 240/240）
- `evidence/probe_concurrent_status.mm`（并发 status 探针源码，600/600 ok）
- `evidence/red-native-bar-core-d717ef0.log`（旧代码上同样 12/12 PASS —— 如实挂账）
