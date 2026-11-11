# RLPlayer UI 与交互层重做方案

> **定位**：可进入开发的 UI/交互重做设计稿。竞品（QQ音乐 macOS 11.11.0）逆向资料只用于提炼机制与规避陷阱，**不照搬界面、资源与历史债**；一切接口、类名、字段以 RLPlayer 现有代码为准，新抽象显式标注「新增」。
>
> - 项目基线：RLPlayer **1.1.6**（已发布，`v1.1.6` = `31eec70`）→ 当前内容在 `main` 上直接更新为 **1.1.7**（`src/version.h:10`）。**1.1.6 已合入更新通道实现**（含 PS256 验签/JWS 解析/公钥头），故本方案的「现状」指 1.1.6+；1.1.7 起在其上做 UI 重做。
> - 工作方式：**不用分支**，直接在 `main` 上做（用户 2026-11-11 明确）；不再新建 feat/ui-redo 分支
> - 输入资料快照：`<QQMUSIC_ANALYSIS>/`（本机竞品资料目录，2026-11-11 02:47 版）；`<QQMUSIC_ANALYSIS>` 与 `$RLPLAYER_REPO` 为占位符，避免把本机绝对路径写进可能公开的文档
> - 约束来源：`PROMPT_UI_REDESIGN.md`（下称「任务书」）+ 用户后续指令（2026-11-11）：「先只考虑 arm」「基线用新发布的 1.1.6」「用纯 AppKit」「不用分支，当前内容的版本更新为 1.1.7」「开始做吧」
> - 证据标记：**【事实】/【推断】/【不确定】/【决策】**。竞品证据用 `文件:行号` 或 selector/IMP 地址；项目证据用 `文件:行号`。
> - 全文中文；不写「显著提升」「极致体验」类无判据表述；没有实测的数字不写。

---

## 0. 设计摘要（一页）

### 0.1 决策清单

| # | 决策 | 一句话理由 | 落地阶段 |
|---|---|---|---|
| D0 | **目标 UI 栈 = 纯 AppKit（Objective-C++，ARC），不用 Swift / SwiftUI，主内容区不再使用 WKWebView** | 用户 2026-11-11 明确「用 AppKit」「Swift 主要是多平台迁移需求才搞的」；单 macOS 产品无跨平台需求，ObjC++ 贴合现有壳与 Unix Makefiles 构建链（CMake 的 Swift 语言在 Makefiles generator 下不支持，已实测） | P1–P4 |
| D1 | **双 UI 并行迁移**：CMake 新增 `RLPLAYER_UI=web\|native` 开关，P1–P3 默认 `web` 不变，P4 起默认 `native`，对等验收后才从发布包移除 web | 功能不能删除（项目铁律 1）；旧 UI 是唯一已验证的完整实现，必须能随时回退 | P0–P4 |
| D2 | **播放状态真相源留在 C++ 核心**（`QueueState`/播放线程，`tools/rtaweb.cpp:4790-4845`），Swift 只做**只读快照 + 意图**；禁止在 Swift 里复制一份模式/队列真相 | 现有核心同时被 web UI、`rtaweb` CLI、UPnP/Cast、ctest 使用；搬到 Swift 会造成多真相 | P2 |
| D3 | **播放模式保持项目现有 4 态**（0 顺序 / 1 列表循环 / 2 单曲循环 / 3 随机），不退回竞品的 3 态；模式是**全局会话状态**，持久化在 `rlplayer-playlist.txt` 的 `mode=`；保存队列（saved queue）不存模式 | 4 态是已上线语义（`tools/rtaweb.cpp:4796-4817`）；竞品的 3 态是它自身产品形态的产物，照抄会**删除既有功能** | P2 |
| D4 | **不引入第二套「默认模式」**：不存在「设置里的默认值」与「本次播放模式」两套真相；显式 `mode` 参数直接写会话模式，优先级 = 显式请求 > 持久化会话模式 | 竞品 `listPlayMode` 与 `QMPlayModeManager` 不同源且取值集合未定论（`report_playmode_merged.md:35,44`）；两套真相必然打架 | P2 |
| D5 | **随机 = 整表 Fisher–Yates + 游标 + 一轮走完重洗 + 切模式保当前曲**；**用系统 CSPRNG 播种**（竞品的 `arc4random()%remaining` 有模偏置；本项目 `std::shuffle` 本身无模偏置，但种子熵不足且不可注入）；**跨轮避免立刻重复同一首**（现状已实现，补测试固化）；**上一首 = 全局播放历史**，不是游标回退 | 竞品机制证据见 `report_playmode_merged.md:28-33` / `LESSONS_FOR_MY_APP.md:30-72`；竞品上一首语义在随机域没有用户可感知的完整定义 | P2 |
| D6 | **播放调度收敛为 `PlaybackRequest` + `PlayOptions`**（P2 新增 `src/native/` 门面）；场景入口只组装 options | 竞品 9 个 `playList:Index:listPlayMode:` 变体（`report_playmode_merged.md:31`）说明入口族会失控；项目当前 `/api/play`、`/api/lib/play`、`/api/add` 也各有语义（`tools/rtaweb.cpp:9117,9409`） | P2 |
| D7 | **「下一首播放」= 独立 FIFO 插播队列（新增）**，优先于模式推进，消耗完回到主队列；不持久化，替换主队列时清空 | 竞品插播队列优先（`report_playmode_merged.md:35-37`，部分分支未闭环）；这是明确的用户价值，且必须与模式分离 | P2 |
| D8 | **错误统一为 `PlaybackError{code, message, recoveryActions[]}`**，UI 统一渲染主/次按钮；连续错误自动跳歌 ≤3 次后暂停并保留「重试/诊断」入口 | 竞品「报错必给下一步」并列例证 `LESSONS_FOR_MY_APP.md:102-110`；项目当前 `ps.error` + toast 是字符串，缺少可执行出口 | P2 |
| D9 | **淡入淡出默认关闭（0 s）**，仅在可混音的 PCM 路径启用；开启即退出 bit-perfect 并在 UI 如实标注；异常结束（错误/用户强跳）跳过淡出；**DSD/DoP 不支持 crossfade**（明确限制）。预加载沿用现有 `prefetch_start` 并参数化阈值 | 竞品 `fade` 166 处 + `isError:`（`report_friendly_merged.md:14`、`LESSONS_FOR_MY_APP.md:86-100`）；bit-perfect 是本项目核心承诺（README:77-85），混音与逐位直通不可同时成立 | P3 |
| D10 | **更新 = 一个原生窗口 + 信息态/下载态两视图 + 5 个出口**；复用 1.1.6 已落地的 global 与 cn 双通道（含 PS256 验签/JWS 解析/公钥头，`tools/mac_update.mm:406`、`src/net/update_channel.h:315`）及安装链（`tools/mac_update.h:122-160`）；忽略与稍后都持久化；不引入任何提权 API | 竞品 `Update.nib` 一窗两视图 5 通道（`report_lead_update.md:6-19`）+ 更新主控更正后的触发/门槛（`report_lead_update.md:67-83`）；项目已有完整下载/校验/安装流水线 | P3 |
| D11 | **设置改为独立窗口**（⌘,），保留现有 **10 个页签**与页内分组；淡入淡出/预加载/队列行为放进现有「通用 → 播放」分组，**不新增页签**；主窗口不再承载设置页 | macOS 惯例；主区专注资料库/播放；现有页签与顺序保持，降低学习成本；任务书禁止「为了对齐竞品增加入口」，新设置项应归入既有「播放」分组（`src/net/ui_script.h:9987-9993`） | P1（外壳）/P3（全部页签） |
| D12 | **资源从第一天用一套规范**：SF Symbols 优先、Asset Catalog 语义色、模板着色表达 hover/pressed/selected；不再为状态出位图矩阵，不再用文件名编码明暗/倍率 | 竞品三代图标命名并存（`report_ui.md:197-209`）+ 687 个散装资源（`report_ui.md:170`）是明确反例；本项目三主题/双语必须靠语义 token | P1–P3 |
| D13 | **所有入口只发 Command**：菜单、快捷键、播放条、Now Playing、Dock 菜单、媒体键/Now Playing Info（`MPRemoteCommandCenter`）共用一张命令表 | 竞品多入口各自的变体（`LESSONS_FOR_MY_APP.md:157-164`）；本项目现状只有 App/Edit 两级原生菜单（`tools/mac_host.mm:1002-1050`），播放控制全在 Web 内 | P2–P3 |
| D14 | **明确不做**：迷你播放器、桌面歌词、横屏/写真全屏、简洁模式、第 4 个播放模式、强制更新、Touch Bar、Siri/App Intents、跨设备续听（本版本范围）；理由逐项见 §0.3 | 任务书禁止「为了对齐竞品而增加没有用户价值的模式或窗口」；这些在竞品资料里证据不足或属移动端遗留 | — |

### 0.2 阶段总览

```text
P0 契约冻结      P1 原生外壳         P2 播放核心与交互      P3 设置/更新/系统集成     P4 视觉与默认切换
1–2 天           1–2 周              2–3 周                  2–3 周                    1–2 周
───────────────► ───────────────► ─────────────────────► ──────────────────────► ────────────────────►
文档+矩阵+探针    侧栏/主区/播放条     模式/随机/调度/队列       设置 10 页/更新窗口        GPU 特效/性能/
                 只读状态+桥                错误恢复/插播队列         菜单/媒体键/无障碍         默认 native + 1.1.7
```

每个阶段都满足：`build 0 error` + `ctest` 全绿 + 本阶段实机清单通过 + web 版回归不红。判据见 §10 与 §11。

### 0.3 明确不做什么（逐条给理由）

| 不做 | 理由（证据） |
|---|---|
| 第 4 个播放模式 / 按竞品把模式改 3 态 | 4 个 SVG 图标 vs 3 个枚举在竞品那里是**未定论疑点**（`report_playmode_merged.md:26,45`）；本项目已有 4 态且已上线（`tools/rtaweb.cpp:4796-4817`），照抄 = 删功能 |
| 横屏 / 歌手写真全屏 / 简洁模式 | 文案来自 iOS 共享本地化表，macOS 端无 selector / 无入口证据（`report_ui.md:145-156`；`report_ui_lessons.md:288-310`） |
| 桌面歌词窗口、迷你播放器 | 竞品有实现（`report_ui.md:57-58`），但本项目当前无对应功能（`tools/mac_host.mm` 单窗口），新增属范围外；列为后续评估，不在 1.2 |
| 强制更新 / 自动静默安装 | 竞品有强制升级分支（`report_lead_update.md:67-83`），桌面端只建议用于安全/协议不兼容场景；本项目无此需求，默认「普通弹窗」 |
| 提权删除旧包（`privilegedRemove:` 一类） | 竞品实现且 API 废弃风险高；本项目改用「用户可写路径直接安装 / 不可写时引导拖拽」的现代方案（§8.6） |
| 多份 nib 载荷按 IB/系统版本分发 | 竞品 10 个 NIBArchive v1 载荷不可 `plutil` 解析，维护成本高（`report_ui.md:16-46`、`report_ui_lessons.md:41-49`）；本项目单部署目标（macOS 13+）无必要 |
| 三代图标命名 / 687 个散装资源 | 反例见 `report_ui.md:197-209`；用 SF Symbols + 语义 Asset Catalog 替代（§9） |
| 照抄竞品的文案与百分比 | `%d` 是模板占位符不是实测数据（`report_friendly_merged.md:20`）；`zh_Hans.strings` 是跨端共享表（`report_friendly_merged.md:28`） |
| Web 主内容区（含「用网页做新的 UI」） | 任务书 `PROMPT_UI_REDESIGN.md:37` 明确排除；迁移期仅作为回退保留，不作为目标方案 |
| 1.1.7 范围内的 Universal 二进制 | 用户已定「先只考虑 arm」：`CMakeLists.txt:32-36` 维持 arm64 硬门禁、第三方切片不动。**本轮不做 Universal，不列为待决策** |
| 睡眠定时关闭 / 耳机拔出暂停 / 系统中断自动恢复 | 竞品有（`report_friendly_merged.md:13`；`report_ui_lessons.md:251-287`），本项目当前**完全没有**（grep `定时关闭|sleepTimer|耳机拔出|pauseOnHeadPhoneOut` 0 命中，调研笔记 C §5）；属新增功能而非 UI 重做，列 1.3 评估，不在 1.2 范围 |

---

## 1. 约束、现状基线与迁移策略（适配项目自身）

### 1.1 任务书约束 vs 项目现实的冲突表

| 约束（任务书） | 项目现实（证据） | 本方案处理 | 状态 |
|---|---|---|---|
| 平台 macOS，原生、不做 Web 主内容区（`PROMPT_UI_REDESIGN.md:37`） | 现状 `NSWindow + WKWebView`，主内容区是内嵌 HTML/JS（`tools/mac_host.mm:911-965`；`src/net/ui_page.h:1463-1764`） | 目标栈 = **纯 AppKit/ObjC++**；P1–P3 双 UI 并行；P4 原生默认 | **采纳** |
| Apple Silicon + Intel 通用 | `CMakeLists.txt:32-36` 对非 arm64 直接 `FATAL_ERROR`；包脚本强制纯 arm64；`third_party/lame-arm64`、ffmpeg-lite 只有 arm64 | **只做 arm64**（用户已定）；Universal 本轮不做 | **已定** |
| 不引入无头浏览器、不运行竞品 app、不做鼠标/键盘自动化 | 项目铁律与工作区守则（`AGENTS.md` §1 界面验收；铁律 1/2） | 全部 UI 验收改为「单测 + 构建门禁 + 用户实机清单」；不新增自动化输入 | **采纳** |
| 功能不能删除，只做全量移植 | 项目铁律 1（`RLPlayer/AGENTS.md`） | 附录 A 功能对齐矩阵：每个用户可见功能在 native UI 有落点；每阶段验收含矩阵行 | **采纳** |
| 基线与分支 | 基线 = 已发布 1.1.6（`v1.1.6`）；用户要求「不用分支，当前内容版本更新为 1.1.7」 | 直接在 `main` 上做；`src/version.h` = 1.1.7 | **采纳** |

> **口径说明（重要）**：任务书第 37 行要求「原生」。这与项目当前网页 UI 的现状直接冲突。本方案按任务书执行，同时把冲突显式记录为 D0/D1：迁移期保留 web 回退，P4 做对等验收后才切换默认。这是「适配项目自身」在工程上的最小风险路径，不是对任务书打折扣。

### 1.2 现状基线（只列与本方案相关的部分）

| 事实 | 证据 |
|---|---|
| 单进程 `.app`：`NSWindow` + `WKWebView`，自定义 `rlplayer://app/` scheme 由进程内核心处理，主进程不监听端口 | `README.md:88`；`tools/mac_host.mm:911-965` |
| 窗口：初始 1180×760，`NSWindowStyleMaskFullSizeContentView`，隐藏标题、透明标题栏、空 `NSToolbar`（Unified），Appearance 固定 DarkAqua | `tools/mac_host.mm:911-965` |
| 原生菜单只有 App（关于/许可证/退出）与 Edit（撤销/重做/剪切/拷贝/粘贴/全选） | `tools/mac_host.mm:1002-1050` |
| 页面骨架：侧栏（资料库/播放列表/音频引擎三组）+ 顶栏 + 主区 + 右侧栏（队列/歌词）+ 底部播放条 + Now Playing 覆盖页 + modal/toast | `src/net/ui_page.h:1468-1512`、`:1569-1616`、`:1621-1752`、`:1754` |
| 页面导航 10 个入口：专辑/艺术家/曲目/文件夹/流媒体/播放队列/最近播放/我的最爱/快速开始/设置 | `src/net/ui_page.h:1470-1491` |
| 设置 10 个页签：通用/输入/输出/PCM/SDM/EQ/声音校准/元数据/流媒体/诊断 | `src/net/ui_script.h:9717-9730` |
| 播放模式 4 态单一真相源 `mode ∈ {0,1,2,3}`；`repeat`/`shuffle` 只作派生兼容写入口 | 1.1.6 起 `tools/rtaweb.cpp:4790-4845`（行号为 1.1.5.1 基线，1.1.6 在此文件未改动播放模式逻辑） |
| 队列/模式持久化：`rlplayer-playlist.txt`，`index=`/`mode=`/`repeat=`/`shuffle=`/`item=` 行；旧文件无 `mode=` 时按 `repeat`/`shuffle` 单向迁移 | `tools/rtaweb.cpp:6260-6315` |
| 随机：切到 mode=3 时整表 `std::shuffle`（`std::mt19937` 播种 `std::random_device ^ 高精度时钟`，`thread_local`），关掉随机时恢复 `base` 并重新定位当前曲；追加曲目时同步维护 `base`/`items` | `tools/rtaweb.cpp:4849-4869`、`:8392-8395`、`:8830`、`:9026` |
| 播放线程：曲间自动推进由 C++ 线程完成；起播前 `prefetch_start(nextPath)` 预解码下一首；结束回调 `queue_advance_locked` | `tools/rtaweb.cpp:6444-6492` |
| 播放调度：`/api/play`（追加并定位，不删除既有队列）、`/api/lib/play`（整列替换）、`/api/add`（入队）、`/api/qdel`、`/api/qmove`、`/api/playmode`、`/api/repeat`、`/api/shuffle` | `tools/rtaweb.cpp:9084-9114`、`:9117-9270`、`:9409`、`:10460-10503` |
| 更新：**1.1.6 已发布双通道**：global 端到端可用；cn 通道已接后台（PS256 验签 / JWS 解析 / 公钥头 / 全量包 DMG 直链），`kDefaultChannel=Global` | `tools/mac_update.mm:406`（`SecKeyVerifySignature`）、`:680`（`parse_china_manifest`）、`src/net/update_channel.h:315`、`src/net/macos_update_pubkey.h`；`src/version.h:10` = 1.1.6 → 1.1.7 |
| 更新 UI 现状：设置→诊断页的更新卡片（检查/下载/安装按钮与进度）+ 底栏 `updateBadge`；宿主消息 `update:check`/`update:install` 与 `update:status:<JSON>` 回传 | `src/net/ui_script.h:380-480`；`tools/mac_host.mm:1237`；`src/net/ui_page.h:1608` |
| i18n：`docs/i18n/chunk-*.tsv` → `tools/gen_i18n_table.py` → `src/net/i18n_table.h`（生成物，词表 **1753 对**）；中英双语；页面侧用 DOM 后处理翻译（不是 key 查表） | `tools/gen_i18n_table.py`；`src/net/i18n_table.h`；`README.md:89`；`report`/调研笔记 A §5.3 |
| 测试/自检：ctest 注册 **152 条**（1.1.6 基线 `ctest -N` 实测）；web 页面内自检 21 条（`selftestAdd(` 计数） | `CMakeLists.txt`；`src/net/ui_script.h` |
| 构建链：CMake 3.31.6 + Unix Makefiles；CLT Swift 6.4.2 存在但 **Makefiles generator 不支持 Swift**（本机实测），故不用 Swift；纯 ObjC++ 直接 `enable_language(OBJCXX)` | 本机实测（2026-11-11） |

### 1.3 迁移策略（双 UI 并行，核心不动）

1. **核心不动**：音频引擎/DSP/库/元数据/更新/诊断全部保留在 C++（`src/**`、`tools/rtaweb.cpp` 业务部分）。UI 重做不是重写播放器。
2. **一层桥**：新增纯 C++ 门面 `src/native/core_bridge.{h,cpp}`（已落地），通过 `rlapp::dispatch()` 复用现有 `/api/*` handler；纯 AppKit UI（`tools/native/native_host.mm`，ObjC++/ARC）只调这个门面。不引入 Swift、不改 `rtaweb.cpp`。
3. **双构建**：CMake 选项 `RLPLAYER_UI`（已落地，`web|native`）。`web` 构建 = 当前实现零行为变化；`native` 构建 = 同一 `rlplayer_mac` 宿主在 `RLPLAYER_UI_NATIVE` 下起纯 AppKit 界面（`rlnative_start()`），不创建 WKWebView 主内容。两个构建共用 `rlapp_core`。
4. **切换条件**：只有附录 A 的对等矩阵全部通过、P4 实机清单全绿，才把发布默认切成 `native`；此前发布包仍是 web。
5. **回退**：任一处对等失败 = 该阶段不算完成；native 构建标记为未就绪，不进入发布。

### 1.4 分支与版本策略

| 项 | 决策 |
|---|---|
| 基线 | 已发布 1.1.6（`v1.1.6`/`31eec70`）；开发在 `main` 上直接做 |
| 实施分支 | **不用分支**（用户明确）；直接在 `main` 提交，每次提交前跑全量门禁 |
| 版本号 | 用户明确「当前内容的版本更新为 1.1.7」：`src/version.h` = **1.1.7**；本轮 P1 即首个原生 UI 交付，不再另设 1.2.0-beta1 |
| 发布纪律 | 仍遵守「默认只提交本地、推送需用户明说」；是否发版由用户决定 |
| 文档位置 | `docs/ui-redo/UI_REDESIGN_PLAN.md`（本文件）；`/docs/*.md` 的 ignore 规则只匹配该目录直属文件，本路径可入库；是否随分支合并进公开库由用户决定 |

### 1.5 本方案与 A–H 的对应关系

| 任务目标（任务书第 5–11 行） | 本文章节 |
|---|---|
| 1. 信息架构与窗口/视图层级 | §2 |
| 2. 播放状态与模式的状态管理模型 | §3（A） |
| 3. 关键交互链路 | §6（D，含 5 条状态机）；随机与调度分别见 §4（B）、§5（C） |
| 4. 组件与资源规范 | §9（G） |
| 5. 分阶段落地计划 + 可验收判据 | §10（H）+ §11 实机清单 |
| 证据等级与已定事项 | §12 |
| 功能对等矩阵（适配项目自身功能） | 附录 A |

> **命名约定（1.1.7 P1 已落地部分）**：`src/native/core_bridge.{h,cpp}`、`tools/native/native_host.mm`、`tests/test_native_bridge.cpp`、`RLPLAYER_UI` CMake 选项、`rlnative::` 命名空间皆**已实现**（纯 C++/ObjC++，非 Swift）。文中其余 `PlaybackRequest/PlayOptions`、`PlaybackError/RecoveryAction`、`PlaybackHistory`、`UpNextQueue`、`UpdateCoordinator` 等是 **P2/P3 计划中的新增抽象**，尚未落地，不把计划伪装成既有 API。

---

## 2. 信息架构与窗口/视图层级（任务目标 1）

### 2.1 决策

| # | 决策 |
|---|---|
| IA-1 | **保留「以专辑为一等公民」的信息架构**：侧栏三组导航、主区路由、右侧队列/歌词栏、底部播放条、Now Playing 覆盖页，全部保留现有心智模型，不做 QQ音乐式的歌单/发现/电台扩张 |
| IA-2 | **单主窗口 + 独立设置窗口 + 独立更新窗口**；不新增迷你窗/桌面歌词窗 |
| IA-3 | 主窗口用 `NSSplitViewController`：侧栏（可折叠）+ 主区 + 右侧栏（可折叠）；底部播放条是主窗口的常驻子视图，不属于任何 split item |
| IA-4 | Now Playing 仍是主窗口内的全窗覆盖层（不是新窗口），Esc 返回，保留「左音频分析 / 中歌词 / 右 AI 整理」三列结构 |
| IA-5 | 视图路由保留现有 10 个入口与视图键（`albums/artists/tracks/files/remote/queue/recent/favs/station/settings`），设置移到独立窗口后主区不再有 `settings` 路由 |
| IA-6 | 新增 **前进/后退导航栈**（每窗口一份 `NavigationStore`）：任何一次点击都不让用户失去上下文（沿用现有代码注释里的产品原则，`src/net/ui_script.h:11`） |
| IA-7 | 窗口状态恢复：`NSWindow.setFrameAutosaveName`；侧栏/右栏折叠状态、上次视图、滚动位置写入 `UserDefaults`（按窗口/视图分键），启动时恢复 |

### 2.2 依据

- 现状 IA 与实现：侧栏/顶栏/主区/右栏/播放条骨架 `src/net/ui_page.h:1468-1512`、`:1519-1529`、`:1569-1616`；Now Playing 四行布局 `src/net/ui_page.h:1621-1752`；设置页签 `src/net/ui_script.h:9717-9730`；导航键与标题 `src/net/ui_page.h:1470-1491`。
- 竞品教训：nib 只做窗口壳、动态内容用代码建构是合理分工（`report_ui.md:52-66`、`report_ui_lessons.md:17-49`），但 629/291 方法的巨型控制器是反例（`report_ui.md:117-118`）；多窗口形态应共用同一会话（`report_ui_lessons.md:119-155`），但本项目当前没有这些窗口，本版本不新增。
- 任务书要求「窗口/视图层级」与「最小改动原则」`PROMPT_UI_REDESIGN.md:5-11,25-31`。

### 2.3 目标窗口/视图层级（新增文件为建议名）

```text
NSApplication
└─ AppDelegate (ObjC++, 纯 AppKit)
   ├─ MainWindowController (ObjC++, 已落地：tools/native/native_host.mm)
   │  └─ NSWindow（FullSizeContentView，隐藏标题，透明标题栏，三主题 Appearance）
   │     └─ NSView (root)
   │        ├─ MainSplitViewController (NSSplitViewController)
   │        │  ├─ SidebarViewController (NSViewController, 232 pt, 可折叠)
   │        │  │  ├─ 资料库：专辑 / 艺术家 / 曲目 / 文件夹 / 流媒体
   │        │  │  ├─ 播放列表：播放队列 / 最近播放 / 我的最爱 / 已保存队列
   │        │  │  └─ 音频引擎：快速开始 / 设置（打开设置窗口）
   │        │  ├─ ContentViewController（路由容器，一次只挂一个子 VC）
   │        │  │  ├─ AlbumsGridViewController（NSCollectionView + diffable）
   │        │  │  ├─ AlbumDetailViewController（NSTableView）
   │        │  │  ├─ ArtistsViewController / ArtistDetailViewController
   │        │  │  ├─ TracksViewController / FilesViewController / RemoteViewController
   │        │  │  ├─ QueueViewController / RecentViewController / FavoritesViewController
   │        │  │  └─ QuickStartViewController
   │        │  └─ RightRailViewController（可选，队列/歌词两个 tab，280 pt，可折叠）
   │        ├─ PlayerBarViewController（常驻，68 pt，不属于 split）
   │        └─ NowPlayingViewController（全窗覆盖层，Presented）
   ├─ SettingsWindowController (ObjC++, P3)
   │  └─ NSToolbar/侧边列表 页签 + 内容 VC（纯 AppKit，10 页）
   ├─ UpdateWindowController (ObjC++, P3)
   │  └─ 内容容器：InfoView / DownloadView 两态切换
   └─ CommandRouter (ObjC++, P1 已落地：handleCmd:) → rlnative:: 桥 → C++ 核心
```

> 不引入 XIB/Storyboard。窗口骨架用代码建，符合「nib/xib 只放窗口骨架与静态布局，动态列表与播放条用代码建」原则（`LESSONS_FOR_MY_APP.md:139-155`），且本项目只有单一部署目标，没必要复刻竞品的多 nib 历史债。若将来确需 XIB，仅允许窗口骨架，禁止把列表/播放条放进 XIB。

### 2.4 视图路由表

| 路由键 | 侧栏标题 | 容器类型（新增） | 数据来源 | 现行对应 | 阶段 |
|---|---|---|---|---|---|
| `albums` | 专辑 | `AlbumsGridViewController`（NSCollectionView） | 现有库查询 | `data-v=albums` | P1 |
| `album` | —（详情） | `AlbumDetailViewController`（NSTableView） | 现有库查询 | 现行专辑详情 | P1 |
| `artists` | 艺术家 | `ArtistsGridViewController` | 现有库查询 | `data-v=artists` | P1 |
| `artist` | —（详情） | `ArtistDetailViewController` | 现有库查询 | 现行艺术家详情 | P2 |
| `tracks` | 曲目 | `TracksViewController`（NSTableView） | 现有库查询 | `data-v=tracks` | P1 |
| `files` | 文件夹 | `FilesViewController`（OutlineView） | 现有文件浏览 API | `data-v=files` | P2 |
| `remote` | 流媒体 | `RemoteViewController` | 现有 Subsonic/Emby API | `data-v=remote` | P2 |
| `queue` | 播放队列 | `QueueViewController`（TableView + 拖拽） | CoreBridge 队列快照 | `data-v=queue` | P2 |
| `recent` | 最近播放 | `RecentViewController` | 现有最近播放 API | `data-v=recent` | P2 |
| `favs` | 我的最爱 | `FavoritesViewController` | 现有收藏 API | `data-v=favs` | P2 |
| `station` | 快速开始 | `QuickStartViewController` | 设备能力/预设 API | `data-v=station` | P3 |
| `works` | —（古典作品版本，无导航） | `WorkVersionsViewController` | 现有实体 API | 曲目/单曲页「作品」区 | P3 |
| `sq` | 我的歌单（动态行） | `SavedQueueViewController` | 现有 saved queue API | 左栏 `#sqList` | P2 |
| `nowPlaying` | —（覆盖层） | `NowPlayingViewController` | CoreBridge + 分析/资料 API | `#npPage` | P3 |
| `settings` | 设置（窗口） | `SettingsWindowController`（10 页签） | 现有设置 API | `#setpage` | P1 外壳 / P3 全部 |

### 2.5 窗口与尺寸规格（决策值，不是实测值）

| 项 | 规格 | 说明 |
|---|---|---|
| 主窗口默认 | 1180×760 | 沿用现状初始尺寸（`tools/mac_host.mm:911`） |
| 主窗口最小 | 760×480 | 比现状 600×400 略大：侧栏 232 + 主区最小 320 + 播放条固定高度下不挤压控件；P1 实机确认 |
| 侧栏 | 232 pt，范围 200–320，可折叠（`⌃⌘S`） | 与现状 226 pt 接近（`src/net/ui_page.h:643` 的 `--sidew`） |
| 右侧栏 | 280 pt，范围 240–360，可折叠（显示队列 `⌥⌘2` / 歌词 `⌥⌘3`） | 队列/歌词；现行宽约 280 |
| 播放条 | 68 pt | 封面 48 + 两行文本 + 控制组 + 进度 + 音量；现行 66 px（`src/net/ui_page.h:1569` 注释） |
| Now Playing | 主窗口内容区全覆盖 | 不是独立窗口 |
| 全屏 | 标准 macOS 全屏（绿钮/⌃⌘F），不做竞品式沉浸/横屏 | 原生 NSWindow 自带；现状只有「最大化到 visibleFrame」没有真全屏（调研笔记 C §5） |
| 关主窗口 | 退出 App（现状行为，保留） | `applicationShouldTerminateAfterLastWindowClosed → YES`（`tools/mac_host.mm:1481-1483`）；本版本不改为后台常驻/菜单栏应用 |
| 设置窗口 | 760×560，最小 640×480 | **10 页签**（与现状一致），默认选中「通用」，左侧列表或顶部 toolbar tab；P3 定稿 |
| 更新窗口 | 480×320（信息态）/ 480×360（下载态） | 单窗口两视图（§8） |

### 2.6 与现状的差异（保留 / 调整 / 新增 / 移除）

| 项 | 处理 | 理由 |
|---|---|---|
| 侧栏三组导航与 10 个入口 | 保留 | 用户已形成的路径；`src/net/ui_page.h:1470-1491` |
| 设置页从主区移到独立窗口 | 调整 | macOS 惯例；主区专注资料库/播放；设置内容与页签顺序不变 |
| 顶栏自绘窗口按钮（min/max/close） | 移除 | 原生窗口应有原生红绿灯 + 标准菜单；自绘按钮在原生 UI 中重复且不可访问 |
| 原生 App/Edit 菜单 | 保留并扩展 | 新增「播放 / 显示 / 窗口 / 帮助」菜单（命令表 §9.8） |
| Now Playing 覆盖层 | 保留 | 现有功能与用户习惯；`src/net/ui_page.h:1621-1752` |
| 右侧队列/歌词栏 | 保留功能，布局从**悬浮卡**改为 **split 分栏** | 现状 `#right` 是 fixed 悬浮卡、从不占网格位（`src/net/ui_page.h:206,223,527`）；分栏可让队列与主区互不遮挡、可键盘导航、宽度可调 |
| 前进/后退导航栈 | 新增 | 弥补现有导航「进入详情后靠 Esc 返回」的上下文丢失问题 |
| Web 内 `#modal`/`#toast` | 用原生 sheet/banner/toast 替代 | 原生交互与可访问性 |
| 迷你播放器/桌面歌词/多窗口 | 不做 | §0.3 |

### 2.7 验收判据（本阶段 P1/P3 可执行）

1. **构建**：`RLPLAYER_UI=native` 构建 0 error；`RLPLAYER_UI=web` 构建 0 error 且 web 页面内自检保持当前基线（1.1.6 为 **21 条用例**；通过状态以 `<state>/selftest-last.json` 实测为准，命令见 §10.2）。
2. **层级断言**（P2 新增 ObjC++ 单测）：主窗口存在且含 `NSSplitViewController`（侧栏/主区/右栏）+ 常驻播放条；设置/更新窗口不在启动时创建（懒加载）。
3. **恢复**：关闭再启动后侧栏宽度 ±2 pt、折叠状态、上次视图一致（实机清单 R-01/R-02，用户执行）。
4. **无 Web 主内容**：`RLPLAYER_UI=native` 的二进制中不创建 `WKWebView`（单测断言 `MainWindowController` 不含 `WKWebView` 子视图；`rg -n "WKWebView" <native target 源>` 为空）。
5. **可访问性**：侧栏每项/播放条每键都有 `accessibilityLabel`（P2 单测遍历控件断言非空；实机 VoiceOver 抽查）。

### 2.8 风险

- **风险 R-IA1：双 UI 期间用户/开发者困惑**。缓解：native 构建标记为 `-beta`，默认仍是 web；README/发版说明明确。
- **风险 R-IA2：拆分控制器过多导致状态散落**。缓解：所有跨视图状态只经 Store；VC 之间不互相持有；命令走 CommandRouter。
- **风险 R-IA3：窗口最小尺寸与现有布局在 1024/1280 档的断点行为差异**。缓解：P1 用 1024/1280/1576 三档做布局单测（尺寸断言，不截图）。
- **风险 R-IA4：设置窗口迁移让用户找不到设置入口**。缓解：侧栏「设置」仍存在（打开窗口）、菜单 ⌘,、首次启动引导提示一次。


---

## 3. A. 播放状态与模式的状态管理模型

### 3.1 决策

| # | 决策 |
|---|---|
| A-1 | **状态所有权三层**：核心真相（C++，可持久化）→ UI 桥/Store（ObjC++/C++，镜像 + 意图）→ 视图局部（展开/滚动/选区）。任何跨视图可见的状态只允许存在于前两层 |
| A-2 | `rlnative::set_mode` / `snapshot()`（C++ 门面，P1 已落地）承担「模式在 UI 层的唯一读口与唯一写口」；去重、非法回落在本层，持久化仍由核心 `/api/playmode` 负责 |
| A-3 | 写入口收敛为 `setMode(_:source:)`；所有入口（播放条、Now Playing、设置、菜单、快捷键、媒体键、未来的 App Intents）只发 Command，不直接改控件状态 |
| A-4 | 去重判据：`new == current` 直接返回 `false`，不发请求、不写盘、不广播。核心侧再做一次 `want == mode` 的幂等保护，防止其他客户端重复写 |
| A-5 | 非法值回落：`rlnative::set_mode` 把 `want<0 || want>3` 钳到 0（顺序）；核心 `/api/playmode` 也有 `>3 → 0` 的第二道保护。P1 已用 `test_native_bridge` 覆盖 |
| A-6 | 持久化粒度：**全局会话模式**，写 `rlplayer-playlist.txt` 的 `mode=`（现有格式）；**不按歌单/专辑分别存**（用户已定维持现状），saved queue 不存模式 |
| A-7 | 不存在第二套「默认模式」：设置页里的模式控件 = 当前会话模式的镜像；显式 `mode` 参数 = 立即写入会话模式（并持久化），不是一次性 override |
| A-8 | 状态分发：纯 AppKit 用 `NSTimer` 10 Hz 轮询 `rlnative::snapshot()`；快照带单调 `revision`（仅状态变化才递增），UI 丢弃旧快照。P1 已落地；P2 可升级为 Notification 但保持单一真相源 |
| A-9 | 跨窗口/多入口只有一个 Store 实例（App 级注入）；菜单校验用 `validateMenuItem`/`NSUserInterfaceValidations` 读同一 Store，不各自维护 enabled 状态 |

### 3.2 依据

- 竞品：`QMPlayModeManager` 单例 + `setMode` 去重 + 通知广播 + 多视图各自渲染，证据见 `report_playmode_merged.md:13`、`:19-21`；设计提炼见 `LESSONS_FOR_MY_APP.md:9-28`、`report_ui_lessons.md:83-118`。竞品反向教训：三套文案源（枚举/CFString/本地化 key）与两条写入口（`allCircle:` 与 `*PlayMode:`）导致「是否去重取决于入口」，见 `LESSONS_FOR_MY_APP.md:26`、`report_ui_lessons.md:108-118`。
- 项目现状：模式已是单一真相源 `mode ∈ {0,1,2,3}`，`repeat`/`shuffle` 只是派生兼容写入口（`tools/rtaweb.cpp:4790-4845`）；`/api/playmode` 只接受 `POST` 与数字、`>3 → 0`（`:9084-9114`）；持久化在 `mode=` 行（`:6260-6315`）；`/api/queue` 与 `/api/status` 都回传 `mode`（`:10460-10503`、`:12298`）。
- 竞品的 `listPlayMode` 与持久化模式**不同源且取值集合未定**（`report_playmode_merged.md:35,44`），这是本方案 A-6/A-7 刻意消除的歧义。
- 现状缺失（本方案补齐）：`queue_set_mode_locked` 没有「同值直接返回」的显式判据（设置同值仍会重排/重存）；模式写失败没有 UI 反馈。**P1 已在 `rlnative::set_mode` 补齐去重与回落**（`tests/test_native_bridge.cpp`），核心侧幂等保护仍为 P2 待办。

### 3.3 方案

#### 3.3.1 状态所有权表

| 状态 | 真相源 | UI 镜像 | 生命周期 | 证据/说明 |
|---|---|---|---|---|
| 播放模式 mode | 核心 `g_q.mode` | `rlnative::snapshot().mode` | 持久（队列文件） | `tools/rtaweb.cpp:4813`、`:6266`；`src/native/core_bridge.cpp` |
| 队列 items / index / base | 核心 `g_q` | `QueueStore.items`（只读） | 持久（队列文件；base 跨重启为**新增**） | `tools/rtaweb.cpp:4811-4814`、`:6260` |
| 播放/暂停/当前曲/进度 | 核心 `ps` + 播放线程 | `PlaybackStateStore` | 会话 | `tools/rtaweb.cpp:6444-6492`、`:12298` |
| 插播队列 upNext | 核心（新增） | `QueueStore.upNext` | 会话（不持久） | 本方案 §6.4 |
| 播放历史 | 核心（新增 `PlaybackHistory`） | 不需要 | 会话（可选持久，默认不持久） | 本方案 §4.3 |
| 视图/侧栏/右栏展开、滚动 | `NSUserDefaults` / `setFrameAutosaveName` | 直接 | 持久（App 偏好） | 本方案 IA-7；P1 已落地窗口记忆 |
| 输出设置/主题/语言 | 现有 conf + `/api/settings` | `SettingsStore` | 持久 | `tools/rtaweb.cpp` 设置读写；不重塑 |
| 更新检查结果 | 核心 update 模块 | `UpdateCoordinator.state` | 会话 + 持久化忽略/稍后 | §8 |

#### 3.3.2 模式写入口（P1 已落地，`src/native/core_bridge.cpp`）

```cpp
// src/native/core_bridge.cpp（已实现；纯 C++，不是 Swift）
bool rlnative::set_mode(int want) {
    if (want < 0 || want > 3) want = 0;          // 非法值回落顺序（A-5）
    if (want == current_mode()) return false;     // 去重：不写盘、不广播（A-4）
    const std::string body = "mode=" + std::to_string(want);
    if (!response_ok(dispatch("POST", "/api/playmode", body))) return false;
    std::lock_guard<std::mutex> lk(g_stateMx);
    ++g_revision;                                 // 只在真实变更时递增
    g_last.mode = want;
    g_last.revision = g_revision;
    return true;
}

// 4 态映射（UI 层，ObjC++ 字符串函数，非 Swift enum）
static NSString* mode_title(int m) {
    switch (m) { case 0: return @"顺序播放"; case 1: return @"列表循环";
                 case 2: return @"单曲循环"; case 3: return @"随机播放";
                 default: return @"顺序播放"; }
}
```

> 单测：`tests/test_native_bridge.cpp` 11 条判据（同值去重 / revision 不变 / 9 与 -1 回落 / 进度不递增）已绿。

#### 3.3.3 快照与事件（C++ 门面与 ObjC++ UI 的契约）

> 现状 `/api/status` **不含** `mode/shuffle/repeat/index/队列长度`（`tools/rtaweb.cpp:12360-12500` 内 grep 0 命中），取模式必须另调 `/api/queue`（`:10469-10537`）。因此 native 桥的快照**直接读核心**并补上 `mode/index/count`，不复用 `/api/status` 的 JSON 字段集。

```cpp
// src/native/core_bridge.h（已实现）：状态变化才递增 revision；进度/音量不参与。
struct PlaybackSnapshot {
    std::uint64_t revision = 0;
    int mode = 0; bool playing = false, paused = false;
    std::string current;
    std::size_t index = 0, count = 0;
    double pos = 0.0, dur = 0.0, volDb = 0.0;
    std::string error;
};

// 采样：NSTimer 10 Hz 调 rlnative::snapshot()；只有「真实状态变化」才 ++revision。
// UI 层丢弃 revision 更旧的快照，避免乱序刷新。
```

```cpp
// 新增：tools/rlapp_playback.h（C++ 类型化门面；实现放 rtaweb.cpp 同 TU，避免搬 13k 行）
namespace rlapp {
struct PlaybackSnapshotC {
    unsigned long long revision;
    int mode;                 // 0..3
    bool playing, paused;
    std::string current;
    size_t index, count;
    double position, duration;
    std::string error_code, error_message;
};
PlaybackSnapshotC playback_snapshot();
bool set_play_mode(int mode);                  // 钳制、去重、持久化；返回是否真的变更
bool enqueue_up_next(const PlayItem&);         // §6.4（P2）
bool play_request(const PlayRequest&, std::string& err); // §5（P2）
}
```

- **采样策略**：`CoreBridge` 在后台队列以 **10 Hz** 调 `playback_snapshot()`，仅在 `revision` 或 `position` 变化超过阈值时向主线程推送状态；播放条进度用主线程 30 Hz 定时器在两次快照之间插值，并在快照到达时校正。**状态（模式/队列/错误）由 revision 去重**，进度不参与去重。
- **为何不用 `NSNotificationCenter`**：竞品的广播是「无回执、靠订阅者自觉」（`report_ui_lessons.md:108-118`）；Combine + revision 能在类型层面保证「谁读到的都是同一份快照」，也便于单测注入假桥。

#### 3.3.4 持久化粒度与优先级（回答任务书 A 的两个问题）

| 场景 | 输入 | 生效模式 | 是否写盘 |
|---|---|---|---|
| 冷启动 | 无 | 队列文件 `mode=`；文件缺失/非法 → 0 | 否 |
| 用户点播放条模式键 / Now Playing 模式键 / 设置模式控件 | 目标模式 | 目标模式 | 是（`mode=` + `repeat=`/`shuffle=` 兼容键） |
| 菜单「播放 → 模式」或快捷键 | 目标模式 | 目标模式 | 是 |
| 代码调用 `play(request.mode: X)` | 显式 X | X（成为新的会话模式） | 是 |
| 代码调用 `play(request.mode: nil)` | 无 | 当前会话模式 | 否 |
| 恢复 saved queue（无模式字段） | 无 | 当前会话模式 | 否 |
| 旧版队列文件（只有 `repeat`/`shuffle`） | 无 | 按 R-4 一次性迁移（`shuffle=1→3`、`repeat=2→2`、`repeat=1→1`、否则 0） | 否（下次写盘时落 `mode=`） |
| 非法值（如 9 / -1） | 任意 | 0 | 否 + 诊断事件 |

**结论（写死，不留给实现者自由发挥）**：模式只有一份会话状态；没有「默认模式」这一独立概念；`play(request.mode:)` 是写路径而不是临时覆盖。原因：本项目的队列是**一条全局播放队列**（`tools/rtaweb.cpp:4811`），不是竞品按歌单容器播放的模型；引入第二套来源会让 `/api/status`、播放线程、UPnP、CLI 与 Web/native 两个 UI 之间的语义分叉。

#### 3.3.5 视图渲染（单一映射表，图标/文案/无障碍同源）

| mode | 图标（SF Symbol） | 本地化标题（中/英） | Accessibility Label（中/英） | 附加视觉 |
|---|---|---|---|---|
| 0 顺序 | `arrow.right` | 顺序播放 / Play in Order | 播放模式：顺序播放 / Playback mode: order | 无 |
| 1 列表循环 | `repeat` | 列表循环 / Repeat All | 播放模式：列表循环 / Playback mode: repeat all | 图标高亮（accent） |
| 2 单曲循环 | `repeat.1` | 单曲循环 / Repeat One | 播放模式：单曲循环 / Playback mode: repeat one | 图标高亮 + 角标 1（系统 symbol 自带） |
| 3 随机 | `shuffle` | 随机播放 / Shuffle | 播放模式：随机 / Playback mode: shuffle | 图标高亮 |

- 上述表是**唯一**映射；菜单标题、按钮 tooltip、VoiceOver 标签全部从这里取。单测断言「表长度 == `PlaybackMode.allCases.count` == 4」。
- 切模式后 `revision` 变化 → 所有订阅视图重绘；视图不互相 set 图标。

### 3.4 验收判据

| 判据 | 执行方式 | 红→绿要求 |
|---|---|---|
| 同值设置去重 | C++ 单测 `PlayModeTest.same_value_is_noop`：连续两次 `set_play_mode(1)`，第二次返回 false 且不产生新的持久化写入（用临时 state 目录比对文件 mtime/hash） | 当前代码无显式去重 → **先红**；加幂等保护后转绿 |
| 非法值回落 | C++ 单测 `PlayModeTest.invalid_clamps_to_zero`：`-1`、`9`、`INT_MAX` 都得到 0 且写诊断事件 | 门面未实现 → 先红；实现后绿 |
| 持久化粒度 | C++ 单测：写入 mode=2 → 重建核心（新进程/新实例）→ 读回 2；saved queue 恢复后 mode 不变 | 现有读回已绿；saved queue 断言需新增 API → 先红后绿 |
| 优先级 | P2 单测（ObjC++/ctest）：显式 mode 参数写入会话模式；P1 已落地 `rlnative::set_mode` 去重/回落判据见 `tests/test_native_bridge.cpp` | P1 已绿；P2 补显式参数语义 |
| 旧快照丢弃 | `rlnative::snapshot()` 自带 revision；P1 已实现状态变化才递增（进度不递增），判据 `test_native_bridge` 第 4 条已绿 | 已落地 |
| 单真相源 | `rg -n "g_q\.mode\s*=" tools/rtaweb.cpp` 只允许出现在 `queue_set_mode_locked` 与 `queue_load`；`src/native/core_bridge.cpp` 只读快照不复制状态 | P1 已落地桥层 |
| 构建/回归 | `RLPLAYER_UI=web` 构建 + ctest 全绿；`RLPLAYER_UI=native` 构建 0 error + ctest 全绿（含 `native_bridge`） | 每阶段；1.1.7 P1 已实测 |

### 3.5 风险

- **R-A1：乐观更新与核心回显不一致**（例如写盘失败但内存已改）。缓解：核心 `set_play_mode` 成功才返回 true；失败时 Store 不改变；快照始终覆盖 UI。
- **R-A2：ObjC++ 视图里复制状态**（开发者图省事在 VC 里存 mode）。缓解：视图每次从 `rlnative::snapshot()` 读；代码审查 + 静态检查。
- **R-A3：两个 UI 并行期模式不一致**（web/native 同时开）。实际同一时刻只有一个 UI 进程；缓解：状态始终回读核心。
- **R-A4：revision 语义日后被进度污染**。缓解：快照结构把 `position` 与 `revision` 分字段；单测断言「仅进度变化不递增 revision」。

---

## 4. B. 随机播放

### 4.1 决策

| # | 决策 |
|---|---|
| B-1 | 随机仍是**整表洗牌**（不是每首独立 roll）：整列洗牌成不重复序列，游标前进；到队尾即「一轮走完」时重洗整列（现状已隐式实现，见 `tools/rtaweb.cpp:4950-4962`；本方案把它固化为显式组件与测试） |
| B-2 | 随机数：洗牌继续用 `std::shuffle`（标准库实现**无模偏置**，不需要像竞品那样手写 `% remaining`）；现状种子是 `std::random_device ^ 高精度时钟` 且 `thread_local`（`tools/rtaweb.cpp:4843-4852`），改为 **Apple CSPRNG `arc4random_buf` 填充 + 可注入种子**；测试用固定种子可复现 |
| B-3 | 切到随机**保留当前曲**：先记录当前项，洗牌后 `indexOf` 回填游标；切出随机恢复 `base` 原始顺序并同样回填当前曲（现状已如此，补测试固化） |
| B-4 | **跨轮立刻重复**：重洗后若第 1 位仍是上一轮最后一首，与后续某个不同项交换（现状已实现 `tools/rtaweb.cpp:4952-4958`，补测试固化）；队列只有 1 首时不处理。注意现状的「防止 A→B→A 立刻回头」是**改写 items 顺序**并随 `queue_save` 落盘（`:4930-4949`），本方案保留该行为并把它写进测试，不做语义改变 |
| B-5 | **上一首语义 = 全局播放历史**（新增 `PlaybackHistory`），不是随机游标回退：每次曲目真正开始播放时入栈（有界 200）；「上一首」在播放位置 >3 s 时先回到本曲开头，否则弹栈播放；若目标在当前随机序列中，把游标对齐到它的位置，使紧接着的「下一首」回到用户刚离开的曲目 |
| B-6 | **持久化 base 顺序**（新增 `baseitem=` 行，向后兼容）：现状重启后 `base` 丢失，导致随机模式下关掉随机无法恢复原顺序（`tools/rtaweb.cpp:6260-6315` 只写 `item=`）；这是可观察缺陷，本方案修复 |
| B-7 | 队列编辑（追加/删除/拖动/排序）在随机模式下的规则：追加进 `items` 尾与 `base` 尾；删除同时删两处并重定位当前；拖动/排序清空随机排列、回到顺序列表（并提示「已退出随机排序」）——规则写死并测试。现状 `/api/qmove` **不维护 `base`/`sortBase`**（`tools/rtaweb.cpp:9303-9322`，对比 `qdel` 的 `:9287-9294`），是随机态拖动后关随机丢序的根因 |
| B-8 | `ShuffleOrder` 算法组件放 **C++ 核心**（P2 新增），UI 只拿只读快照用于「接下来」展示；理由见 4.3.6 |

### 4.2 依据

- 竞品机制【事实】：整表 Fisher–Yates（`_arc4random` + 手工 `udiv/msub` 取模）与 `randomSongListArray`（`report_playmode_merged.md:28-33`、`report_playmode.md` §6）；`keepIndex` 切模式保当前曲（`report_playmode_merged.md:32`）；上一首不计数、一轮走完重洗（`:28-33`）；竞品**没有**跨轮防重复（`LESSONS_FOR_MY_APP.md:68-72`）；插播队列优先但完整分支未闭环（`report_playmode_merged.md:35-37`）。
- 竞品陷阱：`arc4random() % remaining` 有模偏置（`LESSONS_FOR_MY_APP.md:72`）；`getLiteralStrForPlayMode:` 的三套文案源与 4 图标/3 枚举不一致（`report_playmode_merged.md:19,26`）。
- 项目现状：整表 `std::shuffle`（`tools/rtaweb.cpp:4856-4861`、`:4950-4962` 跨轮重洗 + 防立刻重复 + 相邻去重）；`base` 恢复（`:4858-4866`）；`std::mt19937` 用 `std::random_device ^ 高精度时钟` 播种、且 `thread_local`（`:4843-4852`）；`base` 不落盘（`queue_save` 只写 `item=`，`:6259-6280`）；上一首 = `index-1` / 回绕，**没有历史栈**（`:10596-10602`）。
- 现有判据：`tools/check_playmode_behavior.py:62-105,228-234` 是**唯一**能证明四态推进/切模式保 index 的手动脚本（纯 HTTP + 日志、要求 `backend=null`），但它**没有进 ctest**，也未在别的脚本/文档里被引用；`CMakeLists.txt` 中播放/队列/模式 **0 条 ctest**。本方案 P2 把它移植成 ctest 用例（新增 `tests/test_playback_navigation.cpp` + `tests/test_shuffle_order.cpp`）。

### 4.3 方案

#### 4.3.1 核心数据结构（C++，新增）

```cpp
// 新增：src/playback/shuffle_order.h
namespace rta::playback {

// 生产环境用 Apple CSPRNG；测试注入固定种子。q 队列的“身份”由调用方用 QItem::same 判定。
class ShuffleSeeder {
public:
    static std::uint64_t secure_seed();      // arc4random_buf，失败回退 std::random_device
};

// 纯函数，便于单测：按给定种子生成 [0,n) 的 Fisher–Yates 排列
std::vector<size_t> shuffled_permutation(size_t n, std::uint64_t seed);

// 重洗时避免第一项等于 blocked（队列只有 1 项时原样返回）
void avoid_first(std::vector<size_t>& perm, size_t blocked);

class PlaybackHistory {                       // 新增（与随机/顺序模式无关，所有模式共用）
public:
    void push(std::string path, double cueStart, double cueEnd);
    bool pop_previous(PlayItem& out);         // 不返回“当前正在播的这首”
    void clear();
    static constexpr size_t kMaxDepth = 200;
};

} // namespace rta::playback
```

`QueueState` 内新增（不改变已有字段语义）：

```cpp
struct QueueState {
    // ... 现有 items / index / mode / base / sortBase 不变 ...
    std::deque<QItem> history;                // 新增：已成功开始的曲目（有界）
    std::uint64_t rngSeed = 0;                // 新增：调试/复现用；0 = 每次随机
    bool upNextDirty = false;                 // 新增：§6.4
};
```

#### 4.3.2 切模式与推进流程

```text
用户/命令 setMode(3) / play(mode:3)
  → queue_set_mode_locked(3)
      ├ 当前项 cur = items[index]
      ├ base = items（若 base 为空）
      ├ perm = shuffled_permutation(items.size, secure_seed())
      ├ avoid_first(perm, /*blocked=*/上一首? 无 → 不需要)
      ├ items = perm 映射后的新顺序
      ├ index = perm.firstIndex(of: cur位置)   // B-3 保当前曲
      └ mode = 3；queue_save()

自然结束 / 下一首（mode==3）
  → curIdx+1 < count ? 前移 : 重洗一轮
       ├ perm = shuffled_permutation(n, seed)
       ├ avoid_first(perm, blocked=上一轮最后一项)   // B-4
       ├ items = perm；index = 0
       └ 记 “新一轮随机”诊断事件（不弹 UI）
```

#### 4.3.3 上一首（B-5 的细化）

```text
上一首（任意模式）
  ├ 当前播放位置 > 3.0 s  → seek(0)（行业通行语义，先回到本曲开头）
  └ 否则
       ├ history.pop_previous(target)
       │    └ 栈空 → 保持在当前曲开头（不再“随机跳到某人”）
       ├ 若 mode == 3 且 target 在当前 items 中 → index = 该位置（对齐游标）
       ├ 播放 target（走统一调度入口 §5，options = 不写队列/不重置错误计数）
       └ 把 target 从 history 栈顶移除（避免来回抖动）
```

> 竞品的随机“上一首”是游标回退（`report_playmode_merged.md:32` 的 `indexOfSongByOffset` 取模回绕）。本项目采用历史栈：用户心智是「回到我刚听过的那首」，且能同时修正顺序/列表循环下的上一首语义。差异在附录 C 的「不采纳/改进」表登记。

#### 4.3.4 队列编辑规则（B-7，写死）

| 操作 | mode != 3 | mode == 3 |
|---|---|---|
| 追加曲目 `add` | `items.push_back`；`sortBase` 同步 | `items.push_back`；`base.push_back`（保持原始顺序快照一致） |
| 删除当前曲 `qdel(current)` | 删除后 index 前移/边界钳制 | 删除后 `base` 同步删除；重洗（保留新当前曲） |
| 删除非当前曲 | 删除并修正 index | `items` 与 `base` 同步删除；index 修正 |
| 拖动/排序 `qmove/qsort` | 正常 | **退出随机**（mode→0）并在 UI toast 说明；不允许“随机序列 + 手动排序”两个真相 |
| 清空队列 | 清空、停止、mode 保持 | 同左；`base`/`history` 清空 |

#### 4.3.5 UI 侧只读展示（P2 计划）

```cpp
// P2 计划：src/native/shuffle_snapshot.h（纯 C++，可进 ctest）
struct ShuffleSnapshot {
    std::vector<int> order;   // 队列下标按播放顺序
    int cursor = -1;          // 当前位置；-1 = 无
    int round = 0;            // 第几轮
    std::vector<int> upcoming(size_t n) const;  // 不跨轮；末尾返回空
};
```

- UI 侧**不实现洗牌算法**：算法在核心，UI 只展示核心给的顺序；P2 的 ctest 覆盖边界。这样 web UI、CLI、UPnP、ctest 与 native UI 共用同一随机序列。

#### 4.3.6 为什么算法不写在 Swift（对任务书 B 的解释）

任务书要求「给出 Swift 数据结构与单元测试用例」。本项目的情况是：播放队列、随机推进与自动切歌都发生在 C++ 播放线程（`tools/rtaweb.cpp:6444-6492`、`:4872-4961`），且被 web UI、`rtaweb` CLI、UPnP 投放与 ctest 共同使用。若把 `ShuffleQueue` 写成 Swift 唯一实现，native UI 与其它消费者会出现两套随机序列，违反 D2 单真相源。因此：

- **算法唯一实现 = C++**（`src/playback/shuffle_order.h`，新增；ctest 覆盖红→绿）；
- **UI 只读结构 + 测试**在 P2 以 ObjC++/ctest 给出；
- 附录 D 的 Swift 参考实现是教学对照，**不进入产品代码**（本项目已定纯 AppKit/ObjC++）。

### 4.4 验收判据（红→绿）

| 判据 | 执行方式 | 红→绿 |
|---|---|---|
| 一轮内不重复（50 首 × 1000 轮，唯一路径） | `ctest -R shuffle_no_repeat`（新 `tests/test_shuffle_order.cpp`） | 当前**没有**任何 ctest 覆盖播放/队列/模式（`CMakeLists.txt` grep 0 命中）；本测试为新增。现有整表洗牌应当直接通过 → 作为基线绿，不强制红→绿；但它必须能证明新组件与旧行为等价 |
| 一轮走完重洗，且第一首 != 上一轮最后一首 | `ctest -R shuffle_round_end` | 现有 `queue_advance_locked` 已实现（绿）；抽到 `shuffle_order` 后必须仍绿 |
| `base` 跨重启保留 | `ctest -R shuffle_base_persists`：写队列（mode=3，base 与 items 不同）→ 重新 `queue_load` → 关闭随机顺序恢复 | **先红**（现状不写 `baseitem=`）；实现后绿 |
| 上一首走历史 | `ctest -R shuffle_prev_history`：依次播 A、B、C（随机序列）→ prev 得 B（而不是“序列中的前一项”） | **先红**（现状 prev=index-1 不回历史）；实现后绿 |
| 切模式保当前曲 | `ctest -R shuffle_keep_current` | 现有已实现（绿），补回归 |
| 种子可注入/不依赖时间 | `ctest -R shuffle_seed_deterministic`：同种子两次排列一致；不同种子不同 | **先红**（现状 `queue_rng()` 用 `std::random_device ^ 高精度时钟` 且 `thread_local`，不可注入）；实现后绿 |
| UI 只读展示 | P2 的 ctest：cursor 边界、upcoming 不跨轮、count==0 | 新增 → 先红后绿 |
| 队列编辑规则 | `ctest -R shuffle_queue_edit_*`（追加/删除/拖动退出随机） | **先红**（拖动退出随机未实现）；实现后绿 |

> 红→绿纪律：上表标「先红」的判据必须在实现前跑出失败，并把失败输出贴进 `docs/ui-redo/evidence/`（新增目录，按项目规则证实测；不伪造）。

### 4.5 风险

- **R-B1：`base` 新增持久化行破坏旧版本回滚**。缓解：新行 `baseitem=` 旧版本会忽略（`queue_load` 只认已知前缀）；旧版本回滚后仍能播，只是丢失原始顺序（可接受，写入文档）。
- **R-B2：历史栈与随机游标对齐的边界**（目标已从 `items` 删除）。缓解：对齐失败时退化为「按历史播放且 index 保持」，并记诊断事件；单测覆盖。
- **R-B3：大队列重洗 O(n) 在播放线程**。缓解：当前队列规模（<10k）下 `std::shuffle` 是毫秒级；若未来支持 10 万级列表，改为后台预计算。
- **R-B4：队列包含重复曲目（同路径不同 CUE 区间）**。身份判定沿用 `QItem::same`（路径 + 区间），单测覆盖重复项场景。

---

## 5. C. 播放调度入口

### 5.1 决策

| # | 决策 |
|---|---|
| C-1 | **一个核心方法**：`PlayRequest`（P2 新增 `src/native/` 门面）。HTTP 的 `/api/play`、`/api/lib/play`、`/api/add`、`/api/queue/set` 改为薄适配器；P1 已先把它们收敛进 `rlnative::play_path/play_album` 等桥方法 |
| C-2 | `PlayOptions`（C++ 位掩码 / `OptionSet` 语义）：`autoPlay`、`replaceQueue`、`appendToQueue`、`locateExisting`、`filterUnplayable`、`resetErrorCount`、`reportAlbumLevelFailure`、`persistQueue`、`castTarget` |
| C-3 | 队列语义三选一（互斥）：`replaceQueue`（整列替换）/ `appendToQueue`（只入队不播）/ `locateExisting`（在现有队列中定位；不在则追加并定位——保持现有 `/api/play` 行为）。默认 `locateExisting` |
| C-4 | 不可播项过滤（`filterUnplayable`）：先做存在性/可读性/时长探测（不做完整解码），过滤掉的项逐项记录 `PlaybackError`；若全部不可播，返回 `albumLevelFailure` 而不是逐条 toast |
| C-5 | 错误计数：显式用户播放（`resetErrorCount`）清零连续失败计数；自动推进不清零；连续失败 ≥3 次 → 暂停并保留错误面板（§6.5） |
| C-6 | 场景入口表（5.3）写死每个入口的 options；新增入口只需在表中加一行，禁止在调用点手写队列操作 |
| C-7 | 兼容性：`/api/play`、`/api/lib/play`、`/api/add` 的**请求参数与响应 JSON 键保持不变**（web 版与 CLI 依赖），行为差异只允许出现在本方案声明的修复项里 |

### 5.2 依据

- 竞品「入口族」反例：9 个 `playList:Index:listPlayMode:` 变体 + `filterNoRightSong:` 等参数组合（`report_playmode_merged.md:31`；`LESSONS_FOR_MY_APP.md:74-84`）；参数语义（`autoPlay / doNotSavePlayList / filterNoRightSong / clearErrorCount / alertForAlbum`）正是 C-2 的映射来源。
- 项目现状语义（必须保留）：
  - `/api/play`：单曲点播 = **追加并定位**，不删除既有队列；`qAppended` 响应字段（`tools/rtaweb.cpp:9167-9245`）。
  - `/api/lib/play`：整张专辑/列表 = **替换整列**（`tools/rtaweb.cpp:8349`、`:9210` 注释）。
  - `/api/add`：只入队（`:9409`）。
  - `/api/queue/set`：整列替换（`:7124` 白名单；`:10452-10487`）。
  - `/api/playmode` 与播放线程的 mode 语义见 §3/§4。
- 现有不可播处理：`valid_utf8` 拒绝（`:9137-9140`）、CUE 边界校验（`:9142-9168`）、DSD Native 拒绝并给出下一步（`:9178-9185`）、解码失败写 `ps.error`（`play_one` 内）；本方案把它们统一成 `PlaybackError + RecoveryAction`，不改变拒绝条件本身。

### 5.3 场景入口与 options（写死）

| 场景 | 入口（现有/新增） | `replaceQueue` | `locateExisting` | `appendToQueue` | `autoPlay` | `filterUnplayable` | `resetErrorCount` | `persistQueue` | mode 参数 |
|---|---|---|---|---|---|---|---|---|---|
| 点专辑「播放全部」 | 现有专辑详情 / `/api/lib/play` | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | nil |
| 点专辑「随机播放」 | 现有专辑详情 | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | 3 |
| 双击单曲（队列内） | 现有曲目/专辑行 / `/api/play` | — | ✅ | — | ✅ | ✅ | ✅ | ✅ | nil |
| 双击单曲（队列外） | 同上 | — | — | ✅（追加并定位） | ✅ | ✅ | ✅ | ✅ | nil |
| 曲目行「+」入队 | 现有 add 按钮 / `/api/add` | — | — | ✅ | ❌ | ❌ | — | ✅ | nil |
| 「下一首播放」 | 新增（§6.4） | — | — | 插播队列 | ✅（若当前无播放则直接播） | ✅ | — | ❌ | nil |
| 艺术家「播放全部」 | 现有艺术家详情 | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | nil |
| 文件夹「播放此目录」 | 现有文件夹视图 | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | nil |
| 恢复 saved queue | 现有「保存队列」 | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | nil |
| 流媒体/远程曲目 | 现有 remote 视图 | — | ✅（命中缓存则定位） | ✅（未命中则追加） | ✅ | ✅ | ✅ | ✅ | nil |
| 投放（UPnP/AirPlay） | 现有投放入口 | 同本地 | 同本地 | 同本地 | ✅ | ✅ | ✅ | ✅ | nil（target=cast） |
| 媒体键/Now Playing「下一首」 | 新增 `MPRemoteCommandCenter` | —（不改变队列） | — | — | — | — | ❌ | — | — |
| 启动恢复上次会话 | 新增（P3，可选） | — | — | — | ❌（暂停态） | ❌ | ✅ | — | 上次 mode |

### 5.4 核心门面（新增，示意）

```cpp
// tools/rlapp_playback.h（新增；实现：rtaweb.cpp 同 TU）
namespace rlapp {
struct PlayItem { std::string path; double cueStart = -1.0, cueEnd = -1.0; };

enum PlayOptions : unsigned {
    kAutoPlay        = 1u << 0,
    kReplaceQueue    = 1u << 1,
    kLocateExisting  = 1u << 2,
    kAppendToQueue   = 1u << 3,
    kFilterUnplayable= 1u << 4,
    kResetErrorCount = 1u << 5,
    kAlbumLevelFailure = 1u << 6,
    kPersistQueue    = 1u << 7,
    kCastTarget      = 1u << 8,
};

struct PlayRequest {
    std::vector<PlayItem> items;
    size_t startIndex = 0;
    std::optional<int> mode;      // 显式即写会话模式（§3）
    unsigned options = kAutoPlay | kLocateExisting | kResetErrorCount | kPersistQueue;
    std::string castDevice;       // 仅 kCastTarget
};

struct PlayResult {
    bool ok = false;
    size_t count = 0, index = 0;
    bool appended = false;
    std::vector<PlaybackError> itemErrors;   // 过滤/失败的逐项错误
    std::string error;                       // 顶层失败
};

PlayResult play_request(const PlayRequest& req);
}
```

### 5.5 验收判据

| 判据 | 执行方式 | 判据说明 |
|---|---|---|
| HTTP 契约不变 | P2 新增 `tests/test_play_api_contract.cpp`：对 `/api/play`、`/api/lib/play`、`/api/add`、`/api/queue/set` 请求/响应键做快照断言（用隔离 `RLPLAYER_STATE_DIR`、`backend=null`、`volume=-120`） | 先按旧实现取基线（绿），重构后必须仍绿；任何键缺失/新增均失败 |
| 入口语义 | `ctest -R play_scene_*`：8 个场景各一条，断言队列替换/追加/定位与 index | 新增；先红（门面不存在）后绿 |
| 不可播过滤 | `ctest -R play_filter_unplayable`：3 首中 1 首不存在 → 播 2 首并返回 1 条 itemError；全部不可播 → `albumLevelFailure` 且不逐条 toast | 先红后绿 |
| 错误计数 | `ctest -R play_error_streak`：连续 3 次失败后停止推进；重置后重新计数 | 先红后绿 |
| Web 回归 | `RLPLAYER_UI=web` 下页面内自检 + `ctest` 全绿（1.1.6 基线 152/152） | 每阶段 |
| 单一实现 | 静态检查：`rg -n "g_q\.items\s*=" tools/rtaweb.cpp` 只允许出现在门面实现与队列编辑函数；HTTP handler 中不再出现队列写入 | 代码审查 + 侦察脚本 |

### 5.6 风险

- **R-C1：把 HTTP 语义当产品语义**（例如 `/api/play` 的“追加并定位”是 Web UI 迁就出来的行为）。缓解：C-3 用显式 options 表达，native UI 的场景表独立于 HTTP 参数名；HTTP 适配器注释保留历史原因。
- **R-C2：`filterUnplayable` 引入启动延迟**（探测 N 首）。缓解：只做 `stat` + 必要时 `probe_media`（已有缓存）；每批上限 200 首；失败不阻塞其余条目。
- **R-C3：门面与旧 handler 双实现漂移**。缓解：所有 handler 只调用门面；契约测试 + 静态检查；P2 完成时删除未走门面的旧分支（唯一例外：`/api/queue/set` 的批量解析可保留在适配器）。
- **R-C4：`PlayItem` 与内部 `QItem` 的字段漂移**（CUE 区间）。缓解：门面转换处集中，单测覆盖 CUE 项。


---

## 6. D. 关键交互链路（每条状态机）

### 6.0a 本节决策与依据

| # | 决策 | 依据 |
|---|---|---|
| D-1 | 所有入口只发 `AppCommand`，由 `CommandRouter` 统一校验/分发/埋点 | 竞品多入口各写变体（`LESSONS_FOR_MY_APP.md:157-164`）；本项目现状播放控制全在 Web 内，原生入口将增多（菜单/快捷键/媒体键），必须先收敛 |
| D-2 | 切模式 = 单写入口 `rlnative::set_mode` + 核心幂等 + 回显；6 个入口共用 | §3；竞品单例+广播+去重（`report_playmode_merged.md:13-21`） |
| D-3 | 切歌：自然结束与手动 next 共用目标解析；mode 0 末尾手动 no-op，mode 2 末尾显式回绕；随机手动 next 在末尾重洗 | 现状 `/api/skip` 与 `queue_advance_locked` 两套推进不一致（§6.2 现状） |
| D-4 | 「下一首播放」= 独立 FIFO upNext，优先于模式推进、不持久化、替换队列时清空 | 竞品插播优先（`report_playmode_merged.md:35-37`，部分推断）；本项目当前无此能力（grep 0 命中） |
| D-5 | 错误统一 `PlaybackError{code,message,recoveryActions[]}`；自动跳过 ≤3 次后暂停；UI 主/次按钮，无「只有确定」 | 竞品「报错必给下一步」并列例证（`LESSONS_FOR_MY_APP.md:102-110`）；本项目错误只写 `#nps` 且被隐藏（§6.4 现状缺口） |
| D-6 | 更新弹窗链路按 §8 状态机；本链路只定义入口与门槛前置关系 | §8；竞品一窗两视图 5 出口（`report_lead_update.md:6-19,67-83`） |
| D-7 | 每条链路至少 3 条单测 + 至少 1 条实机检查；无出口的错误路径视为未完成 | 项目铁律 3/4（判据先红后绿、如实挂账） |

### 6.0b 共同前提：Command 层

所有入口不直接改状态、不直接调 HTTP，只发 `AppCommand`（P1 已落地为 ObjC++ `Cmd` 枚举 + `handleCmd:`）：

```objc
// tools/native/native_host.mm（P1 已落地）：所有入口只发命令，不直接改状态
enum class Cmd : int {
    PlayPause = 1, Next, Previous, Stop, VolumeUp, VolumeDown,
    SeekForward, SeekBackward,
    ModeSequential, ModeListLoop, ModeSingleLoop, ModeShuffle, CycleMode,
    ToggleSidebar, ToggleQueueRail, FocusSearch, OpenSettings, CheckUpdate,
};
- (void)handleCmd:(Cmd)c {
    switch (c) {
        case Cmd::CycleMode: rlnative::set_mode((_snap.mode + 1) % 4); break;
        case Cmd::PlayPause: rlnative::toggle_pause(); break;
        // …其余命令全部只调 rlnative:: 桥方法
    }
    [self refreshSnapshot];
}
```

`CommandRouter`（新增）是唯一分发点：`handle(_:)` → 校验 enabled（读 Store）→ 调 CoreBridge/Store → 记录 `uiTrace` 诊断事件（`source` + `command`，不记录用户输入文本）。菜单项、快捷键、按钮全部走它。

> 依据：竞品多入口有各自变体（Touch Bar/状态栏/迷你窗/主窗都各自实现 `playNext*`，`LESSONS_FOR_MY_APP.md:157-164`；`report_ui_lessons.md:193-248`）。本方案用一张命令表消除分叉。

---

### 6.1 D1 切播放模式

#### 状态机

```text
状态：Synced（UI 与核心一致） / Committing（一次写入在途） / Rejected（写失败，回显旧值）

事件：command(mode, source) / coreEcho(snapshot) / persistFailure

Synced
 ├─ command(mode == current) ────────────────────────────────► Synced（去重：不写、不广播）
 ├─ command(mode != current) ──► Committing
 │      ├─ core.setPlayMode ok ──► coreEcho(new) ─────────────► Synced（图标/文案/a11y 重绘）
 │      └─ core.setPlayMode fail ─► Rejected（toast + 诊断；UI 保持旧值）──► Synced
 ├─ coreEcho(snapshot 来自 CLI/媒体键/恢复) ─────────────────► Synced（视图重绘，不回调写）
 └─ coreEcho(revision 更旧) ─────────────────────────────────► Synced（丢弃）

Committing 期间到达新 command：以最后一次为准（latest-wins），旧写入仍以核心回显为准；
若回显与最新意图不一致，Synced 后重试一次（只重试一次，失败即 Rejected）。
```

#### 入口与路由（写死）

| 入口 | 命令 | 说明 |
|---|---|---|
| 播放条循环键（单击） | `cycleMode` | 0→1→2→3→0；与现状 4 态循环一致（`src/net/ui_script.h:6090-6098`） |
| Now Playing 控制条循环键 | `cycleMode` | 同上 |
| 主菜单「播放 → 播放模式」 | `setModeX` ×4 | 菜单项带勾选态（`validateMenuItem` 读 Store） |
| 快捷键 | `cycleMode` `⌘⇧M` | 可配置？第一版固定 |
| 设置 → 播放 → 播放模式 | `setModeX` | 同一 Store 的镜像控件 |
| Dock 菜单 | `setModeX` | P3 可选（若实现 Dock 菜单） |
| 未来：媒体键/Now Playing 远程命令 | 不支持模式切换（系统无对应 command） | 不做假入口 |
| 未来：Shortcuts/App Intents | `setModeX` | 本版本不做，但命令表已预留 |

#### 顺序图（文字）

```text
用户点击循环键
 → PlayerBarViewController 发 AppCommand(.cycleMode, .playerBar)
 → handleCmd: → rlnative::set_mode(next)
 → CoreBridge.setPlayMode(raw) [进程内同步调用]
 → 核心 queue_set_mode_locked + queue_save
 → 核心 revision++
 → CoreBridge 下一次 10 Hz 轮询读到新 revision → 主线程 publish
 → rlnative::snapshot() 回显 → 播放条/菜单勾选重绘
```

#### 验收判据

| 判据 | 方式 |
|---|---|
| 6 个入口都到达同一存储 | ctest/ObjC++ 单测：对每个 `CommandSource` 派发 `cycleMode`，断言 CoreBridge 收到且只收到一次 `setPlayMode` |
| 去重 | 单测：连续两次同 mode，`setPlayMode` 调用计数为 1 |
| 乐观/回显一致性 | 单测：假桥返回失败 → Store.mode 不变、诊断事件 +1 |
| 菜单勾选 | ctest/ObjC++ 单测：`validateMenuItem` 对 4 个模式项的 state 与 Store.mode 一致 |
| 实机 | §11 R-03：四种模式各点一次，图标/文案/VoiceOver 同步；重启后保持 |

#### 风险

- **R-D1a**：`⌘⇧M` 与其他 App 冲突。缓解：可配置 + P3 实机确认；菜单项始终可用。
- **R-D1b**：设置页与播放条同时改模式（极快连点）导致 latest-wins 抖动。缓解：Committing 状态合并请求 + 单次重试。

---

### 6.2 D2 切歌（上一首 / 下一首）

#### 现状与问题

- 手动切歌走 `/api/skip?dir=±1`：停下线程 → `index ± 1` → 边界按 `mode != 0` 回绕（`tools/rtaweb.cpp:10578-10655`，`:10596-10601`）。注意 mode 2 在末尾也会回绕到 0（因为条件写的是 `mode != 0`），而不是「单曲循环里按下一首」的显式语义。
- 自然结束走播放线程的 `queue_advance_locked`：mode 3 在一轮末尾会重洗并防立刻重复（`tools/rtaweb.cpp:4950-4962`）。
- **两套推进逻辑不一致**：随机模式下，自然结束会重洗，手动「下一首」在末尾却只是回绕到第 1 首（不重洗）；「上一首」在所有模式下都是 `index-1`，随机模式无法回到「刚听的那首」。
- 单曲循环下手动下一首 = index+1（正确），但上一首也是 index-1，不是「上一首听过的」。

#### 决策（统一规则）

| 场景 | mode 0 顺序 | mode 1 列表循环 | mode 2 单曲循环 | mode 3 随机 |
|---|---|---|---|---|
| **自然结束** | 有下一首则播；末尾停 | 下一首；末尾回第 1 首 | 当前曲从头重播 | 序列中下一项；一轮末尾重洗（防立刻重复） |
| **手动「下一首」** | 有则前进；末尾 **no-op + toast「已是最后一首」**（不打断当前播放） | 下一首；末尾回第 1 首 | 前进到下一首；末尾回第 1 首（保持现有 `mode != 0` 回绕语义，但要有显式单测） | 与自然结束**同一实现**（末尾重洗） |
| **手动「上一首」· 位置 > 3 s** | 回到本曲开头 | 回到本曲开头 | 回到本曲开头 | 回到本曲开头 |
| **手动「上一首」· 位置 ≤ 3 s** | 播放历史上一首（栈空则停在开头） | 播放历史上一首（栈空则停在开头） | 播放历史上一首（重复本曲不重复入栈） | 播放历史上一首；若目标在当前随机序列中则对齐游标 |
| **自动推进失败（不可播/解码错）** | 跳过到下一可播；连续 3 次失败暂停 | 同左（循环回绕后最多再试一轮） | 重试当前 1 次后暂停 | 跳过到下一；连续 3 次失败暂停 |
| **错误计数** | 手动切歌清零；自动推进不清零 | 同左 | 同左 | 同左 |

#### 状态机

```text
状态：Playing / Advancing / Ended(no-op) / ErrorPaused

Playing
 ├─ 自然结束（endReason=natural）→ Advancing(mode 规则)
 │      ├─ 有目标 → Playing(目标)
 │      ├─ mode 0 且无下一首 → Ended（停止，UI 显示“已到末尾”）
 │      └─ 目标失败 → ErrorPaused（§6.5）
 ├─ command(next) ─► Advancing(manual: 优先 upNext §6.3 → mode 规则)
 │      ├─ mode 0 末尾 → Ended(no-op)：不停止当前播放，toast 1.5 s
 │      └─ 目标成功 → Playing
 ├─ command(previous) ─► 位置 >3s ? seek(0) : 历史回退
 │      ├─ 历史空 → 停在开头（toast「已是第一首」仅在顺序模式显示）
 │      └─ 目标成功 → Playing
 └─ command(stop) ─► Stopped
```

#### 核心改动（新增）

- `queue_advance_locked` 与 `/api/skip` 的 dir>0 分支共用同一 `advance_next(reason:)`（新增内部函数）；自然结束传 `endReason=natural`，手动传 `manual`（差异仅：mode 0 末尾前者停止、后者 no-op + toast）。
- 新增 `queue_previous_locked`：`PlaybackHistory` + `seek(0)` 规则（§4.3.3）。
- 历史入栈规则：曲目**开始播放**时入栈；同一曲连续重播（单曲循环）不重复入栈；`seek` 不改变历史。
- 自动推进与手动推进共享目标解析，`resetErrorCount` 只由手动命令携带。

#### 验收判据

| 判据 | 方式 |
|---|---|
| 12 格规则表逐格验证 | `tests/test_playback_navigation.cpp`（新增）：4 mode × {自然结束/手动next/手动prev(>3s)/手动prev(≤3s)} 的 index/是否重洗/是否 no-op 断言；先按现状取证红格（随机手动 next 末尾不重洗、prev 非历史）。当前 `CMakeLists.txt` 里播放/队列/模式 ctest **0 条**，本文件全部为新增判据 |
| 随机自然结束末尾重洗 | `ctest -R nav_shuffle_round_end` |
| 单曲循环 | `ctest -R nav_single_loop`：自然结束 index 不变且重播；手动 next index+1 |
| 历史回退 | `ctest -R nav_history_prev` |
| 实机 | §11 R-04/R-05：随机模式连按下一首超过队列长度，观察一轮内不重复、跨轮不立刻重复；上一首回到刚听曲 |

#### 风险

- **R-D2a：历史栈语义与用户对「上一首」的预期不一致**（有人期望顺序模式回上一曲、随机模式回上一轮）。缓解：上一首在 ≤3 s 时走历史，历史就是「刚听过的」；>3 s 先回本曲开头（主流播放器行为）。写入 README 快捷键说明。
- **R-D2b：自动推进的「跳过」改变现有播放日志/行为**。缓解：日志增加 `ADVANCE reason=... target=...`；保留现有 `END` 行字段。
- **R-D2c：UPnP 投放的切歌路径独立**（`upnp_queue_thread`）。缓解：切歌统一通过一个目标解析函数，投放分支只负责「把目标交给 CastManager」；单测覆盖投放路径的 index 决策（不真连设备）。

---

### 6.3 D3 「下一首播放」插播队列（新增）

#### 决策

- 独立 FIFO `upNext`（核心新增）：条目带来源（用户手动），上限 100 条，**不持久化**。
- 优先级：**upNext > 当前播放模式**。自然结束或手动「下一首」先消费 upNext；消费完才按 mode 规则推进主队列。
- 单曲循环与 upNext 同时存在时，自然结束**先消费 upNext**（用户的显式意图优先于循环模式的自动行为）。
- 「上一首」**不**遍历 upNext（upNext 是「接下来要放的」，不是历史）；上一首只走播放历史。
- 主队列被替换（`replaceQueue`）时清空 upNext，并在非空时给一次 toast「插播队列已清空」。
- 删除主队列中的曲目不影响 upNext；删除 upNext 中的曲目只影响 upNext。
- UI：队列面板新增「接下来播放」分区（顶部，可删除单项/全部清除）；播放条队列按钮显示 badge 数量。

#### 状态机

```text
UpNext: [a, b, c]   Main: [m0, m1, m2]  current=m0

事件：
 ├─ command(playNext, item=x)  → upNext.append(x)（不自动开始；若当前 Stopped，则直接播放 x）
 ├─ command(next) / 自然结束   → upNext.pop_front() 存在？
 │        ├─ 是 → 播放该曲（不改变主队列 index；该曲不入主队列）
 │        └─ 否 → 按 mode 规则推进主队列（§6.2）
 ├─ command(prev)              → 忽略 upNext，走历史（§6.2）
 ├─ 主队列 replaceQueue        → upNext.clear() + toast（若原非空）
 └─ upNext 项播放失败          → 记录错误 + 继续下一个 upNext / 回主队列（连续 3 次错误暂停）

不变量：
 · upNext 与主队列是两套容器；upNext 项不写进 items/base，不占主队列 index
 · upNext 只在会话内存在；重启后为空
 · 自然结束/手动 next/自动推进三条路径共用「取下一首」函数，禁止各自 pop
```

#### UI 交互

| 入口 | 行为 |
|---|---|
| 曲目行右键「下一首播放」 | `playNext` 入队尾；toast「已加入接下来播放」 |
| 曲目行悬停按钮 | 与右键同义（可见入口，避免只有右键） |
| 队列面板「接下来播放」分区 | 显示顺序、删除单项、清空插播；拖拽不支持（保持 FIFO 语义） |
| 主菜单「播放 → 下一首播放」 | 对当前选中曲目执行 |

#### 验收判据

| 判据 | 方式 |
|---|---|
| 优先级 | `ctest -R upnext_priority`：主队列 3 首 + upNext 2 首，连续 next：先播 upNext 两首，再回主队列 mode 规则 |
| 单曲循环 | `ctest -R upnext_single_loop`：mode 2 + upNext 有项，自然结束先播 upNext |
| 不持久化 | `ctest -R upnext_not_persisted`：写 upNext 后重建核心（新实例）→ upNext 为空 |
| 替换清空 | `ctest -R upnext_cleared_on_replace` |
| 上一首不碰 upNext | `ctest -R upnext_prev_ignores` |
| 实机 | §11 R-06：加入 2 首「下一首播放」，观察队列面板分区与播放顺序 |

#### 风险

- **R-D3a：用户以为「下一首播放」会插到主列表当前项之后并可见**。缓解：队列面板用独立分区明确展示；文案「接下来播放（插播）」。
- **R-D3b：upNext 与 Cast 的交互**（投放时插播）。缓解：upNext 同样适用于投放队列，投放线程从同一「取下一首」函数取；单测覆盖不真连设备。
- **R-D3c：错误恢复与 upNext 双重跳过**。缓解：连续错误计数由核心统一维护，upNext 与主队列共用。

---

### 6.4 D4 播放失败与恢复

#### 决策

- 核心错误统一为：

```cpp
// P2 计划：结构化错误（C++/ObjC++ 共用；与核心错误码镜像）
struct PlaybackError {
    std::string domain;        // decode / output / library / network / cast / update
    std::string code;          // 稳定码，进诊断事件
    std::string message_key;   // 本地化 key
    std::vector<RecoveryAction> recovery;  // retry / skipNext / openSettings / …
};
enum class RecoveryAction { Retry, SkipNext, ChooseOutputDevice, OpenSettings,
                            RevealInFinder, SwitchToLocal, OpenDiagnostics };
```

- UI 统一渲染：**主按钮 = recovery[0]**，其余为次按钮；关闭按钮永远存在；不允许只有「确定」。
- 错误分级：
  - **可继续**（单曲失败，队列还有下一首）：非阻塞 banner（播放条/Now Playing 顶部），自动跳过按 §6.2 规则；banner 带「重试 / 跳过 / 详情」。
  - **会话级**（输出设备丢失、独占被抢占）：模态 sheet，主按钮「选择输出设备」/「重试」，次按钮「诊断」。
  - **列表级**（整批不可播）：只弹一次「N 首无法播放」sheet，列出前 5 个原因与「在 Finder 中显示」/「跳过继续」。
- 连续失败计数：核心维护 `consecutiveFailures`；自动推进路径 ≥3 → 暂停并弹「播放连续失败」sheet；手动播放清零；手动 next/prev 清零。
- 所有错误写诊断事件（code/domain/stage，不含文件路径与用户输入），供反馈诊断包使用。

#### 现状缺口（必须在本节修复）

1. **UI 拿不到稳定错误码**：`src/diag/error_codes.h` 已有冻结码表（`decode.*` 10-15、`negotiate.*` 20-24、`io.*` 40-45、`upnp.*` 70-72、`ui.*` 110-112），但这些码只进诊断事件流；`/api/status.error` 是**自由文本**（`tools/rtaweb.cpp:12383`），UI 无法按码给恢复动作。→ 新增 `PlaybackErrorC{code,domain,message_key}` 进快照。
2. **错误在底栏不可见**：`#nps` 带 `class='t2 boring'`，而 CSS `.np .boring{display:none!important}`（`src/net/ui_page.h:593,1587`），所以播放失败时若用户不打开 Now Playing，只能看到一次 2 秒 toast（`src/net/ui_script.h:279-283,4617-4618`）。→ 新 UI 用可停留的 banner + 错误面板。
3. **失败即停**：`queue_thread` 在 `play_one` 返回 false 时直接 `break`（`tools/rtaweb.cpp:6490`），不会跳过坏曲；唯一的自动恢复是「独占流无响应→共享后端从原位续播」（`:4715-4759`）。→ 新增连续失败计数与跳过（C-5/D4）。
4. **字符串错误无法本地化/无法断言**：现有错误文本直接拼中文（如 `已到队列边界`、`解码结果为空…`）→ 统一为稳定 code + 本地化 key，文本只在 UI 层生成。

#### 错误码映射（现有错误 → 新模型，不改变拒绝条件）

| 现有来源（证据） | 新 code | 默认 recovery |
|---|---|---|
| `/api/play` 未指定文件（`tools/rtaweb.cpp:9134`） | `PLAY_BAD_PATH` | revealInFinder, openDiagnostics |
| `valid_utf8` 拒绝（`:9137-9140`） | `PLAY_BAD_PATH_ENCODING` | revealInFinder, openDiagnostics |
| CUE 区间非法/越界（`:9142-9168`） | `CUE_RANGE_INVALID` | skipNext, openDiagnostics |
| DSD Native 未实现（`:9178-9185`） | `DSD_NATIVE_UNSUPPORTED` | openSettings(.output), skipNext |
| 远程曲目获取失败（`:9127-9133`） | `REMOTE_FETCH_FAILED` | retry, switchToLocal |
| 解码/输出失败（`ps.error`，`play_one` 内） | `DECODE_FAILED` / `OUTPUT_FAILED` | retry, skipNext, openDiagnostics |
| 设备被占用/Hog 抢占失败（README:77；`ps` 状态） | `DEVICE_BUSY` | chooseOutputDevice, openSettings(.output) |
| 投放失败（`upnp_mark_player_state` / CastState.error） | `CAST_FAILED` | switchToLocal, retry |
| 更新下载/校验/安装失败（§8） | `UPDATE_*` | retry, openDownloadPage, openDiagnostics |

#### 状态机

```text
状态：Playing / Recovering / PausedError / Stopped

Playing
 ├─ 单曲失败（可继续）→ Recovering
 │     ├─ 有下一首 && consecutiveFailures < 3 → 记录错误 + 播下一首 → Playing
 │     └─ 无下一首 / 达到 3 次 → PausedError（sheet：重试 / 选择下一首 / 诊断）
 ├─ 会话级失败 → PausedError（模态 sheet；主按钮因错误而定）
 └─ 用户关闭 sheet（非破坏性）→ PausedError(静默) 或 Stopped

PausedError
 ├─ 用户点主按钮（retry / 选择设备 / …）→ Playing
 ├─ 用户点 skipNext → 下一首 → Playing
 └─ 用户点停止 → Stopped

任意状态：用户手动播放/下一首/上一首 → consecutiveFailures = 0（C-5）
```

#### 验收判据

| 判据 | 方式 |
|---|---|
| 每个错误至少一个 recovery | ctest/ObjC++ 单测：遍历 9 个 code 的冻结表，断言 `recovery.count >= 1` 且 `recovery[0] != nil` |
| 连续失败暂停 | `ctest -R error_streak_pause`：构造 3 个不可播项，断言停在第 3 次且返回 `PausedError` |
| 手动清零 | `ctest -R error_manual_reset` |
| 列表级只弹一次 | `ctest -R error_album_level_once`：5 首不可播 → 1 条 album-level 结果，而非 5 条 toast |
| 无「只有确定」 | ctest/ObjC++ 单测：`ErrorPresenter.present` 对每个 code 生成的按钮数 ≥ 2 |
| 实机 | §11 R-07/R-08：删掉正在播的文件、拔掉输出设备（投放/独占）、观察 banner/sheet 与恢复动作 |

#### 风险

- **R-D4a：错误路径让用户误以为「文件坏了」**。缓解：文案区分「文件不存在 / 解码失败 / 设备忙」，并把主按钮做成可执行的下一步。
- **R-D4b：自动跳过掩盖真实问题**。缓解：连续 3 次即停 + 诊断事件 + `PlaybackError` 明细可从诊断页导出。
- **R-D4c：C++ 字符串错误与 Swift 结构化错误的转换遗漏**。缓解：转换函数集中（`PlaybackError.from(core:)`），未知 code 映射到 `UNKNOWN` 并保留原始 message；单测覆盖。

---

### 6.5 D5 自动更新弹窗（链路摘要；完整状态机见 §8）

```text
启动/手动/菜单
 → EnvironmentGate(osVersion, diskSpace, network, channel)
      ├ 不满足 → BlockedSheet（具体下一步：升级 macOS / 清理磁盘 / 重试网络）
      └ 通过 → Check(channel)
            ├ UpToDate → 静默（手动触发时 toast「已是最新版本」）
            ├ Available(v, notes, size, sha256) → InfoView（立即更新/以后提醒/忽略此版本/关闭）
            │      ├ 立即更新 → DownloadView（进度/取消）
            │      │      ├ 取消 → 确认 → 清理临时文件 → InfoView
            │      │      ├ 失败 → ErrorSheet（重试/打开下载页/诊断）
            │      │      ├ 校验失败 → ErrorSheet（重试/打开下载页）
            │      │      └ 完成 → ReadyToInstall → 安装 → RestartPrompt（重启/稍后）
            │      ├ 以后提醒 → 写 remindAt → 关闭
            │       └ 忽略此版本 → 写 skippedVersion → 关闭
            └ Failed → ErrorSheet（重试/打开下载页/诊断）
```

- 入口：启动 5 s 后自动检查（可关，设置→播放/通用）、菜单「检查更新」、关于窗口、底栏 `updateBadge` 点击。
- 竞品证据：一窗两视图、5 按钮（`report_lead_update.md:6-19`）；忽略/稍后持久化（`report_lead_update.md:99-107`）；启动门槛先于请求（`report_lead_update.md:34-65`，已由 §3.1 修正为启动 `enterMainUI→initMainUI` 懒加载检查 + `isAutoUpdateAction` 语义）；埋点漏斗（`:113-116`）。
- 本项目差异：不实现强制更新/静默自动安装（D14）；状态机与持久化细节见 §8。

---

### 6.6 D 节汇总验收与风险

| 判据 | 方式 |
|---|---|
| 5 条链路均可单测 | 每条链路至少有 3 条 Swift/C++ 单测（见各小节表）；合计 ≥15 条新判据 |
| 命令入口一致 | ctest/ObjC++ 单测枚举 `CommandSource × playback command`，断言全部经 `CommandRouter` 且只调一次桥 |
| 无死路 | 所有错误/边界至少有一个可执行出口（单测扫描 `RecoveryAction` 表 + 实机清单） |

**风险（跨链路）**：命令层成为新 God Object——缓解：`CommandRouter` 只做「校验 + 分发 + 埋点」，业务规则仍在 Store/核心；单文件行数上限 ~300 行，超出即拆。


---

## 7. E. 淡入淡出与无缝续播

### 7.1 决策

| # | 决策 |
|---|---|
| E-1 | 两个配置项（新增）：`crossfade_ms`（0–12000，默认 **0 = 关闭**）与 `preload_threshold_sec`（2–30，默认 10）。约束：`preload_threshold_sec >= crossfade_ms/1000 + 2`，否则 UI 钳制并说明原因 |
| E-2 | **淡入淡出 = 曲目间交叉淡化**：只在当前曲与下一曲都走可混音的 PCM 路径时启用；重叠期间**不是 bit-perfect**，`/api/status` 的 `bitPerfect=false` 必须带 `bitPerfectWhy=淡入淡出` |
| E-3 | **DSD / DoP 输出不支持 crossfade**（无法在 1-bit/DoP 载波上做重叠混音）；设置页在 DSD 输出态禁用开关并给出原因；运行中切到 DSD 时自动关闭并提示一次 |
| E-4 | **异常结束跳过 crossfade**：`EndReason ∈ {natural, error, userSkip, stop, seek}`；只有 `natural` 允许重叠；错误/用户强跳/停止一律硬切（等价竞品 `isError:` 参数，`LESSONS_FOR_MY_APP.md:86-100`） |
| E-5 | **无缝续播（gapless）本版本不承诺**：现状每曲 `make_sink()+open()`，曲末 `ActiveSinkGuard` 关设备（`tools/rtaweb.cpp:4494,4504,1757-1774`），物理上不可能无缝；真正的 gapless 需要「跨曲保持 sink 打开」的引擎重构，列为 1.3 候选（见 §12 Q4） |
| E-6 | 预加载沿用并参数化现有**预解码**机制（`PreSlot`/`prefetch_start`/`prefetch_take`，`tools/rtaweb.cpp:6385-6433,6460-6462`），但明确它只省解码耗时、不消除曲间静音；`preload_threshold_sec` 与 crossfade 的启动时点绑定 |
| E-7 | 设置文案如实：关闭时说明「与 bit-perfect 兼容、无重叠混音、CPU 开销更低」，**不写百分比**（无实测）；开启时说明「重叠期间非逐位直通，DSD/DoP 不支持」 |
| E-8 | 混音实现与业务 UI 解耦：`CrossfadePlanner`（纯逻辑，新增 `src/playback/crossfade_plan.h`）+ 渲染层挂点（新增 `TransitionGain` 接入 `src/audio/render_loop.h` 的 gain 应用处）；UI 只读写配置与展示状态 |

### 7.2 依据

- 竞品机制【事实】：`fade` 相关 selector **166 处**；`SettingController` 有开关 + 滑杆（`fadePlayConfigChanged 0x100049f48`、`fadePlayCheckBoxClick: 0x10004d86c`、`fadePlayBSSlider 0x100053a20`）；`QCloudEffectConfig` 有 `EnableStartFadein/StartFadeinTime/EnableEndFadeout/EndFadeoutTime`；`qmAudioPlayer:enableAutoMix:isFadeIn:inSong:outSong:isError:` 带 `isError:`；结尾预加载 `prepareNextPlay` / `tryPrepareNextPlayWithDuration:progress:`（`report_friendly_merged.md:14`、`LESSONS_FOR_MY_APP.md:86-100`）。
- 竞品陷阱：`FMMVC_DTS_%d_1 = 关闭后，播放流畅度将提高%d%%` 的 `%d` 是模板占位符，**不是实测数据**（`report_friendly_merged.md:20`、`LESSONS_FOR_MY_APP.md:100`）。
- 项目现状（【事实】）：`tools/rtaweb.cpp` 中 `fade`/`crossfade`/`gapless` **0 命中**；`src/` 里的 `fade` 全是 DSP/PEQ/房间校正参数淡变与 CSS 淡入；每曲独立 open/close 设备；`prefetch_*` 只预解码下一曲（单槽，busy 丢弃；大 DSD 文件跳过）；音量 ramp 存在于 `src/dsp/volume.h:27-46` 且 `src/engine/pipeline.h:587` 有接线，但 `cfg.volumeEnabled=false`（`tools/rtaweb.cpp:3536-3537`），所以**曲目切换没有包络**。
- 渲染挂点（【事实】）：`src/audio/render_loop.h:146-187` 的 `RenderHost` + `:418` 每 tick 写 `volDb - startDb` 到 `sink.set_live_gain_db()`；`src/dsp/volume.h` 的 `set_ramp_ms()/set_gain_db()/snap()` 是现成能力，但语义是「用户音量增量」，不是「曲目间包络」。

### 7.3 方案

#### 7.3.1 纯逻辑：`CrossfadePlanner`（新增，可单测）

```cpp
// 新增：src/playback/crossfade_plan.h
namespace rta::playback {

enum class EndReason { natural, error, userSkip, stop, seek };

struct CrossfadePolicy {
    int crossfadeMs = 0;          // 0 = 关闭
    int preloadThresholdSec = 10; // 约束见 E-1
    bool outputCanMix = false;    // PCM（coreaudio/coreaudio-shared/null）且非 DoP/DSD
    bool sameOutputFormat = true; // 下一曲输出格式（率/位深/声道）是否一致
};

struct CrossfadePlan {
    bool enabled = false;
    bool shouldPreload = false;   // 到达预加载阈值
    bool shouldStartNext = false; // 到达重叠起点
    int  fadeOutMs = 0;
    int  fadeInMs = 0;
    const char* skipReason = "";  // "disabled" / "dsd" / "error_end" / "format_change" / ...
};

CrossfadePlan plan_for_tick(const CrossfadePolicy&, double remainingSec, EndReason);
}
```

规则（写死）：

| 条件 | 结果 |
|---|---|
| `crossfadeMs == 0` | `enabled=false, skipReason="disabled"`；`shouldPreload` 仍可为 true（沿用现有预解码） |
| `EndReason != natural` | `enabled=false, skipReason="error_end"`；不启动重叠 |
| `!outputCanMix`（DoP/DSD） | `enabled=false, skipReason="dsd"` |
| 下一曲输出格式与当前不同（率/位深/声道） | `enabled=false, skipReason="format_change"`；硬切（格式切换本身需要重开设备） |
| `remaining <= preloadThresholdSec` 且尚未预载 | `shouldPreload=true` |
| `remaining <= crossfadeMs/1000` | `shouldStartNext=true, fadeOutMs=fadeInMs=crossfadeMs` |
| `preloadThresholdSec < crossfadeMs/1000 + 2` | 在策略构造处钳制 `preloadThresholdSec = crossfadeMs/1000 + 2`，并记诊断 |

#### 7.3.2 渲染层接入（新增，P3；允许降级）

- 现状：`play_one_impl` 每曲 `make_sink()` + `sink->open()`，曲末 guard 关设备。交叉淡化需要**在一个 sink 会话内**同时渲染两条解码流：
  1. `queue_thread` 在 `plan.shouldPreload` 时启动下一曲解码（复用/扩展 `PreSlot`，允许 >1 个预载槽）；
  2. `plan.shouldStartNext` 时不清空 `RenderQ`，把下一曲 PCM 追加进同一渲染队列，按 `fadeOutMs/fadeInMs` 生成两段包络；
  3. 包络通过新增 `TransitionGain` 乘到当前 `sink.set_live_gain_db()` 的值上（不改用户音量语义）；重叠结束后切换 `ps.current` 到下一曲，释放旧解码器。
- 若 P3 实现超期：**整块特性降级为 1.3**，配置项先不暴露（避免「设置存在但不生效」）。SUBPLAN：E-8 允许 `crossfade_ms` 永远为 0，UI 不显示滑块。这条明确写进 P3 风险。

#### 7.3.3 设置页（新增「播放」页签内）

```text
[开关] 交叉淡入淡出        (默认关)
[滑杆] 重叠时长  0–12 s   (仅开关打开时可调；显示当前值)
[滑杆] 提前准备下一首  2–30 s (自动钳制 >= 重叠时长 + 2)
[说明] 关闭（默认）：切歌不重叠，播放链保持逐位直通（bit-perfect 不受影响）。
       开启：切歌更平滑；重叠期间不是 bit-perfect；DSD / DoP 输出不支持。
       说明：本机尚未测量开启/关闭的 CPU 差异，故不提供百分比。
```

- 输出为 DSD/DoP 时：开关禁用 + 行内提示「当前输出为 DSD/DoP，不支持交叉淡化；切回 PCM 后可用」。
- 与 bit-perfect 徽标联动：重叠期间徽标显示「非逐位（淡入淡出）」；`bitPerfectWhy` 由核心提供（新增文案 key）。

#### 7.3.4 异常结束/强跳的判定点

- `play_one` 返回时由调用方给出 `EndReason`：
  - `play_one` 正常播完 → `natural`；
  - `ps.error` 非空 / 解码失败 / 输出失败 → `error`；
  - `/api/skip`、`/api/play`（切别的曲）、用户点停止 → `userSkip` / `stop`；
  - `seek` 不结束曲目，不参与。
- **只有 `natural` 进交叉淡化**；其余走现有「关 sink → 开 sink」硬切。比较点只有一个：`play_one` 的返回值 + `ps.stop` 标志（不要在每个调用点各判一套）。

### 7.4 验收判据（红→绿）

| 判据 | 方式 | 红→绿 |
|---|---|---|
| 关闭时零行为变化 | `ctest -R crossfade_disabled_noop`：策略 disabled，渲染路径与无特性时逐样本一致（null backend 离线渲染比对） | 新增 → 先红后绿 |
| 错误结束跳过 | `ctest -R crossfade_skip_on_error`：`EndReason=error` → `enabled=false` | **先红**（组件不存在）后绿 |
| DSD 不支持 | `ctest -R crossfade_dsd_rejected` | 先红后绿 |
| 阈值边界 | `ctest -R crossfade_threshold`：remaining = threshold+ε 不触发；= threshold 触发；= crossfade 启动 | 先红后绿 |
| 钳制 | `ctest -R crossfade_clamp_preload` | 先红后绿 |
| 设置写读 | C++/ctest/ObjC++ 单测：写 `crossfade_ms=3000` → 读回 3000；越界 13000 → 12000；负值 → 0 | 先红（键不存在）后绿 |
| B it-perfect 标注 | C++ 单测：重叠态 `/api/status.bitPerfect==false` 且 `bitPerfectWhy` 非空 | 先红后绿 |
| 实机 | §11 R-09：开启 3 s，手动切歌（应重叠）、强跳下一首（应硬切）、切 DSD 输出（开关禁用） | 用户执行 |

> **不允许**用「听起来更顺」作为唯一判据；必须有 `plan_for_tick` 的数值断言 + 实机现有清单。

### 7.5 风险

- **R-E1：交叉淡化与 bit-perfect 承诺冲突**。缓解：默认关闭；开启时 UI 明确标注；核心状态如实报告；文档写明「重叠期间非 bit-perfect」。
- **R-E2：引擎改造超期**（跨曲保持 sink 打开涉及 `play_one` 生命周期、`RenderQ` 所有权、错误恢复）。缓解：特性开关允许 P3 末尾降级为 1.3；降级时设置页不出现滑块（不做假开关）。
- **R-E3：DSD/DoP 用户开启后切输出导致状态不一致**。缓解：切换输出时策略重算并提示一次；单测覆盖。
- **R-E4：预加载槽从 1 扩到 2 增加内存/IO**。缓解：仅 crossfade>0 时启用第二槽；大 DSD 文件沿用跳过规则；记录峰值内存到诊断（现有 `wsPeakMb`）。
- **R-E5：没有实测数据却写收益**。缓解：文案模板强制不含百分比；代码评审检查 `%`。

---

## 8. F. 更新弹窗

### 8.1 决策

| # | 决策 |
|---|---|
| F-1 | **一个原生更新窗口 + 两套内容视图**（信息态 / 下载态），5 个按钮按状态显隐：`立即更新` / `以后提醒` / `忽略此版本` / `取消下载` / `重启应用` |
| F-2 | **复用 1.1.6 已发布能力（global + cn 双通道）**：`kDefaultChannel=Global` 与通道枚举/解析（`src/net/update_channel.h:41-51,97-110`）、清单白名单与 sha256+size 校验（`src/net/update_check.h:502-563,709-729`）、下载→校验→挂载→备份→ditto 替换→重启的安装流水线（`tools/mac_update.h:122-160,293-310`）。cn 通道 1.1.6 已含 PS256 验签/JWS 解析（`tools/mac_update.mm:406,680`），UI 不重新实现下载/校验逻辑 |
| F-3 | **前置门槛先于请求**：系统版本、磁盘空间、网络、通道可用性；任一不满足则给**具体下一步**（升级 macOS / 清理磁盘 / 重试网络 / 等待通道就绪），而不是只报失败 |
| F-4 | 用户选择持久化：「以后提醒」写 `remind_after` + `remind_launch_count`；「忽略此版本」写 `skipped_version`；两者保存到现有 `update.conf`（0600，原子写）。手动检查不受 `skipped_version` 静默屏蔽（用户主动点就必须有回执） |
| F-5 | **不做强制更新/静默自动安装**（D14）：竞品 `upgradeType` 的强制/静默分支（`report_lead_update.md:67-83`）不采纳；桌面端仅保留普通弹窗 + 可选「启动时检查」开关 |
| F-6 | **不使用任何提权 API**：安装到当前 `.app` 所在位置；目标不可写时引导「打开 DMG 手动拖入 /Applications」，而不是 shell 提权删除。现有 `install_from_local_dmg` 已实现「校验→挂载→备份→替换→卸载」（`tools/mac_update.h:293-310`），继续复用 |
| F-7 | **埋点走本地诊断事件**（`src/diag/diag.h` + `error_codes.h`），不引入第三方统计 SDK；事件不含 URL token、用户路径与可识别信息 |
| F-8 | 更新检查触发：启动后延迟 5 s 自动检查（现状是 4 s、每次启动必查；新方案改为**可在设置关闭 + 24 h 节流**）+ 菜单「检查更新」+ 关于窗口 + 底栏 `updateBadge`；不做定时轮询（竞品也无定时检查 selector，`report_lead_update.md:67-83`） |
| F-9 | 渠道状态如实：cn 通道若后台暂不可用，UI 显示「中国大陆通道准备中」并提供「使用全球通道」切换，不假装可用 |

### 8.2 依据

- 竞品【事实】（以 2026-11-11 02:47 修正版为准）：
  - `Update.nib` 一个窗口、`baseView`/`progressView` 两视图、12 outlet + 5 action、5 按钮（`report_lead_update.md:6-19`）；
  - 触发链：启动 `enterMainUI → initMainUI` 懒加载 `[checkUpdate:YES]`；手动经主菜单/设置页 `NSNotification(updateQQMusic)` → `[checkUpdate:NO]`；**未发现定时检查 selector**（`report_lead_update.md:67-83`）；
  - OS 门槛 `getOSFloatVersion >= 101100`（10.11 编码值），先过门槛再发请求（`report_lead_update.md:67-83`，初版「三档 1/2/3」是误读）；
  - `upgradeType` 实际语义：`==5` 静默下载/自动安装、`==2` 强制窗口、`==3 && isAutoUpdateAction` 直接返回、其余普通弹窗（`report_lead_update.md:67-83`）；
  - 下载/安装链路：`NSURLSession` → `ditto --rsrc` 解压 → 删旧包 → `reopenApp:`；下载完成自动安装但**不自动重启**，`reopenApp:` 才 `setShouldRelaunch:YES`（`report_lead_update.md:85-97`）；
  - 用户选择：「忽略」写 `lastVersion`；「稍后」写 `nextUpdateTime`/`laucherNumberNextUpdateTime`（`report_lead_update.md:99-107`、`report_lead_update_addendum.md:5-31`）；
  - 埋点：曝光→点击→下载耗时→CDN→错误码（`report_lead_update.md:113-116`）。
- 本项目【事实】：现有更新 UI 是设置→诊断页的卡片 + 底栏徽标（`src/net/ui_script.h:380-480`、`src/net/ui_page.h:1608`），宿主消息 `update:check`/`update:install` 与 `update:status:<JSON>`（`tools/mac_host.mm:1237`）。
- 现状缺口【事实】（调研笔记 C §2/§3/§4）：
  1. **没有独立更新窗口**；更新入口藏在「设置→诊断」页签，底栏徽标点击的 onclick 只在 `renderSettingsPage()` 里绑定——**没进过设置页时徽标不可点**（已确认 bug，主仓未提交版本在修）。
  2. **release notes 后端会下发但前端从不展示**（`tools/mac_host.mm:1463-1464` 下发；`grep info.notes/obj.notes` 0 命中）。
  3. **没有取消下载按钮**（宿主 `CancelToken` 已完备，`tools/mac_update.h:49-58`，但页面不构造、`HostAction` 无 cancel 项）；**没有重启按钮**（现状自动重启 + 文案兜底）。
  4. **没有「忽略此版本/稍后提醒」持久化**（grep `skip/ignore/later/remind/nextUpdate` 0 命中），也没有启动次数/时间间隔节流（每次启动 4 s 后必查一次，`src/net/ui_script.h:14280-14286`）。
  5. **没有运行时磁盘空间/系统版本门槛**（`statvfs` 只在投放临时文件用；系统版本只有打包期 `LSMinimumSystemVersion=13.0`，`tools/make_app_mac.sh:142`）；磁盘不足会在下载/替换阶段以系统错误串失败。
  6. **没有 `min_os` 清单字段**；没有 codesign/spctl 二次校验（只有 sha256+size）。
  7. cn 通道在 1.1.6 已接后台（PS256 验签 + 全量包 DMG 直链），本方案 P3 只重做更新 UI，不重写通道。
- 安全顺序【事实】：`verify_downloaded_file`（sha256+size）**必须先于挂载/安装**，顺序即安全边界（`tools/mac_update.h:152`、`tools/mac_update.mm:301-314`）。

### 8.3 状态机

```text
状态：Idle → Checking → Gated? → Available → Downloading → Verifying → Installing → RestartPrompt
                              ↘ UpToDate            ↘ Cancelled
                              ↘ Blocked(reason, actions)
                              ↘ Failed(stage, code, actions)
                              ↘ Dismissed(reason: later | skipped)

Idle
 ├─ 启动定时器到点 / 菜单 / 徽标点击 / 关于窗口 → Checking
Checking
 ├─ gate(os, disk, network, channel) 不通过 → Blocked
 ├─ 无更新 → UpToDate（自动触发时静默；手动触发 toast「已是最新版本」）
 └─ 有更新 → Available
Available
 ├─ 立即更新 → Downloading
 ├─ 以后提醒 → Dismissed(.later)（写 remind_after / remind_launch_count）
 ├─ 忽略此版本 → Dismissed(.skipped)（写 skipped_version）
 └─ 关闭窗口 → Dismissed(.later)（同「以后提醒」，但提醒间隔更短：1 天/3 次启动）
Downloading
 ├─ 取消下载 → 确认 sheet → Cancelled（清理临时文件）
 ├─ 进度回调 → 更新下载态（百分比/速度/剩余时间；只显示真实数值）
 ├─ 失败 → Failed(.download, code)（重试/打开下载页/诊断）
 └─ 完成 → Verifying（sha256+size；失败 → Failed(.verify)）
Verifying → Installing（复用 install_from_local_dmg）
Installing
 ├─ 成功 → RestartPrompt（重启 / 稍后）
 └─ 失败 → Failed(.install)（打开 DMG 手动安装 / 诊断）
RestartPrompt
 ├─ 重启应用 → 结束当前进程并重新打开（NSWorkspace）
 └─ 稍后 → 关闭窗口；下次启动提示「更新已就绪」
```

| 状态 | 信息视图 | 下载视图 | 立即更新 | 以后提醒 | 忽略此版本 | 取消下载 | 重启应用 |
|---|---|---|---|---|---|---|---|
| Checking | ✅（「正在检查…」） | — | 禁用 | 禁用 | 禁用 | — | — |
| Blocked | ✅（原因 + 下一步） | — | — | ✅ | ✅ | — | — |
| UpToDate | ✅（「已是最新」） | — | — | 关闭 | — | — | — |
| Available | ✅（版本/说明/大小） | — | ✅ | ✅ | ✅ | — | — |
| Downloading | — | ✅（进度） | — | — | — | ✅ | — |
| Verifying/Installing | — | ✅（阶段文字） | — | — | — | 禁用（已校验） | — |
| RestartPrompt | ✅（「已安装，需重启」） | — | — | ✅（稍后） | — | — | ✅ |
| Failed | ✅（错误 + 动作） | — | 重试 | ✅ | ✅ | — | — |

### 8.4 门槛与文案（写死，均需中英双语 key）

| 门槛 | 判定 | 不足时的下一步 |
|---|---|---|
| 系统版本 | 当前 macOS >= 清单 `min_os`（若清单缺省则 >= 13.0，项目部署目标 `CMakeLists.txt:22-23`） | 「此版本需要 macOS X 或更新版本」+ 按钮「打开软件更新」 |
| 磁盘空间 | `required = packageSize * 2 + 100 MiB`（决策值；2 倍容纳下载包+解压/替换备份，100 MiB 为系统余量） | 显示「需要 X，可用 Y」+ 按钮「打开存储管理」；不开始下载 |
| 网络 | 清单请求 8 s 超时；失败重试 2 次（指数退避） | 「无法连接更新服务器」+「重试」/「打开下载页」/「诊断」 |
| 通道 | global 可用；cn 仅当 `ChannelManifest::ready()` 为真 | 显示通道状态；引导切全球通道（设置→通用/更新） |
| 目标路径可写 | `.app` 所在目录可写（`FileManager.isWritableFile`） | 「无法自动安装」+「打开 DMG」+「拖入应用程序」说明 |

文案规则：只说事实 + 下一步；**不写「立即体验新功能」类营销空话**；下载大小/耗时只显示真实值（无数据则不显示）。

### 8.5 持久化（`update.conf` 扩展；现有键保留，新增键 0600 + 原子写）

| 键 | 类型 | 语义 | 新增? |
|---|---|---|---|
| `token` / `manifest_url` / `channel` | 现有键 | 保持现状语义不动（token 只在本机、0600） | 否 |
| `auto_check` | 0/1 | 启动自动检查开关（默认 1） | 新增 |
| `skipped_version` | string | 用户忽略的版本；自动检查跳过，手动检查仍提示 | 新增 |
| `remind_after` | epoch 秒 | 「以后提醒」的绝对时间 | 新增 |
| `remind_launch_count` | int | 启动次数兜底（时间未到但启动 N 次后提醒） | 新增 |
| `last_check_at` | epoch 秒 | 上次检查时间（节流用；启动检查 24 h 内不重复自动弹） | 新增 |

- 手动检查：不受 `skipped_version` / `remind_after` 静默拦截；用户主动点必须有结果（Available 或 UpToDate 或失败）。
- 自动检查：`skipped_version` 相等或 `now < remind_after` 且启动次数未到 → 静默不弹。
- 写入方式：新增键复用现有 `update.conf` 的 0600 权限；新增/修改采用 `tmp + rename` 原子写（现状 `update.conf` 已 0600；队列文件仍是非原子写，属于另一处已知问题，不在本节范围）。
- 读取失败/损坏：按默认值处理并记诊断；**不阻塞启动**。
- 测试隔离坑：`update.conf` 用 `config_dir_utf8()`（`tools/mac_update.mm:246-250`），**不读** `RLPLAYER_STATE_DIR`；用 `RLPLAYER_STATE_DIR` 做隔离的测试必须同时设 `HOME`，否则会写真实用户目录（现状 `tests/test_mac_update.mm:361` 用 `HOME` 隔离）。

### 8.6 安装（复用现有流水线，不新增提权）

```text
available(plan) → begin_install(plan)
  → NSURLSessionDownloadTask 流式下载（现状实际实现：0.2 s/1% 节流、写 <dst>.part 后 rename、失败 unlink）
  → verify_downloaded_file(sha256+size)  ← 必须在 mount 之前（tools/mac_update.h:152）
  → hdiutil attach -readonly -nobrowse（只读，防回写卷头改变 sha）
  → 取镜像内第一个 *.app → ditto 备份 target.old-<epoch> → ditto 替换（失败回滚）
  → hdiutil detach ×5 退避 / diskutil unmount → 仅自家临时挂载点才 -force
  → 重启：独立 bash 脚本 sleep 1.5 s → open -n <新 .app>（现状自动执行；新方案改为用户点「重启应用」）
  → 失败：清理临时文件；保留旧 .app；返回稳定错误码
```

> 现状执行层已经具备：下载原子落盘、失败清理、先校验后挂载、只读挂载、备份/回滚、卸载退避、脚本重启（`tools/mac_update.h:122-160,293-310`；`tools/mac_update.mm:1120-1263,1327-1439`）。**新增的是 UI 状态机、门槛、取消/重启按钮、忽略/稍后持久化、埋点**；不是重写安装器。

- 目标路径：优先当前 `.app` 所在位置，否则 `/Applications/RLPlayer.app`（`tools/mac_update.mm:441-463`）；当前无提权实现（`/Applications` 属 admin:2775 可写，写不进就报错）。
- 目标路径不可写时：不尝试提权；打开 DMG + 系统「拖拽到应用程序」提示；用户手动完成后重启。
- 现状**没有 codesign / spctl / 公证二次校验**（只有 sha256+size）；本方案把「签名校验」列为 P3 的待定增强（需要先定签名策略），不假装已有。
- 不使用 `AuthorizationExecuteWithPrivileges`（已废弃）；不使用 `SMAppService` 特权 helper（需要独立 helper 目标/签名，超出 1.2 范围，登记为 1.3 候选）。
- 自动重启：只在用户点「重启应用」时执行；不静默重启。

### 8.7 埋点（本地诊断事件，漏斗）

| 事件 | 字段（不含隐私） | 用途 |
|---|---|---|
| `update.check` | channel, trigger(auto/manual), gate_result | 触发与门槛漏斗 |
| `update.available` | version, channel, size | 曝光 |
| `update.click` | action(install/later/skip/cancel), version | 点击 |
| `update.download.start/complete` | version, bytes, durationMs, host（仅域名） | 下载耗时/CDN 排障 |
| `update.verify` | ok, reason | 校验失败率 |
| `update.install` | ok, stage, code | 安装失败定位 |
| `update.error` | stage, code（`src/diag/error_codes.h` 冻结码） | 失败错误码 |

- 落点：现有 `rta::diag::diag_emit` 通道（诊断页/反馈诊断包可导出）；如后续要远端统计，另立需求，不在本方案假设。

### 8.8 验收判据（可执行）

| 判据 | 方式 |
|---|---|
| 状态机全分支 | ctest/ObjC++ 单测 `UpdateCoordinatorTests`（假桥）：17 条迁移逐个断言（Checking→Blocked/UpToDate/Available、Available→4 出口、Downloading→取消/失败/完成、Verify 失败、Install 成功/失败、RestartPrompt 两出口） |
| 门槛 | ctest/ObjC++ 单测：OS 低/磁盘不足/网络失败/通道未就绪分别得到 Blocked 且带正确 recovery；磁盘公式边界（=required、required-1） |
| 按钮显隐 | ctest/ObjC++ 单测：按状态机表生成按钮集合，断言与 §8.3 表一致 |
| 持久化 | C++ 单测（复用 `tests/test_update_channel.cpp` 风格）：写 skipped/remind → 读回；损坏文件回默认；权限 0600 |
| 安全顺序 | 现有 `tests/test_mac_update.mm` + `tests/test_update_check.cpp` 必须全绿；新增一条断言「verify 失败时 mount 从未被调用」 |
| 假清单端到端 | 新增测试钩子 `RLPLAYER_UPDATE_FEED`（环境变量，仅 Debug/测试构建或开发菜单启用）：指向本地 `http://127.0.0.1:19153/latest.json`（端口 19153，**绝不使用 8899**），实机走完 Available→忽略→稍后→再检查；用户按 §11 R-10 执行 |
| 无提权 | 静态检查：`rg -n "AuthorizationExecuteWithPrivileges|SMJobBless|runModal.*密码" app/ tools/` 0 命中（新增代码范围） |
| 埋点 | 单测/诊断日志断言事件字段齐全且不含 `http` URL token、用户路径；实机反馈诊断包中可见 |
| 既有回归 | `ctest -R update` 全绿；`RLPLAYER_UI=web` 下更新卡片行为不变 |

### 8.9 风险

- **R-F1：更新包/清单被篡改**。缓解：沿用主机白名单 + sha256+size 校验；cn 通道 1.1.6 已实现 PS256 验签且必须在解析/下载/安装前（`tools/mac_update.mm:406`）。任何顺序调整即评审拒绝。
- **R-F2：安装权限不足让用户卡住**。缓解：明确「打开 DMG 手动拖入」路径 + 文档；不静默失败。
- **R-F3：自动检查打扰**。缓解：24 h 节流 + 忽略/稍后持久化 + 设置开关；手动检查始终响应。
- **R-F4：cn 通道未就绪导致用户困惑**。缓解：状态如实显示 + 一键切全球通道；不显示不可用按钮。
- **R-F5：更新窗口与主窗口焦点/生命周期的冲突**（模态 vs 非模态）。缓解：非模态独立窗口（可关闭、可重开）；下载中关闭窗口不取消下载（后台继续），重新打开显示进度；明确写入单测。


---

## 9. G. 组件与资源规范

### 9.1 决策

| # | 决策 |
|---|---|
| G-1 | **视觉语言沿用 RLPlayer 现有身份**：HiFi / 以专辑为中心 / 深色为默认 / 三套配色（dark / light / blue）；不从竞品抄任何截图、图标或布局。竞品只提供机制证据（见各节引用） |
| G-2 | **原生资源一套命名**：`语义名`（PascalCase）进入 Asset Catalog；**文件名不编码状态、倍率、明暗**（由 Asset Catalog 的 scale/appearance 与控件状态负责）；矢量（SF Symbols / 自定义 symbol）优先，位图只用于复杂插画 |
| G-3 | **完整状态枚举只有一套**：`normal / hover / pressed / selected / disabled / focused / on / off / loading`。其中 hover/pressed/disabled/focused 由 AppKit 控件状态与 tint/opacity 表达，**不各出一张图**；selected/on 用 accent tint 或 filled symbol；loading 用进度控件，不是图标状态 |
| G-4 | **三套配色用语义 token**：`Theme`（新增）提供 `ColorToken` 枚举 → `NSColor`；纯 AppKit 用 `ThemedView` 基类 + `-[applyTheme:]`（P1 已落地三套 `Theme` 结构）。禁止在视图里写 `NSColor(red:...)`（lint 强制） |
| G-5 | **Command 层一张表**：每个命令含 `id / 标题(中英) / accessibilityLabel / 默认快捷键 / 菜单位置 / 可用条件`；菜单、按钮、快捷键、媒体键全部走同一路由（§6.0） |
| G-6 | **零 XIB/Storyboard**：窗口骨架、静态布局、列表、播放条全部代码构建；动态列表用 `NSTableViewDiffableDataSource` / `NSCollectionViewDiffableDataSource`。若未来引入 XIB，仅允许窗口骨架，禁止列表/播放条进 XIB（`LESSONS_FOR_MY_APP.md:139-155`） |
| G-7 | **i18n**：P1 菜单先复用现有中文串；P3 从 `docs/i18n/*.tsv`（1753 对）生成 `Localizable.strings`，新文案进 TSV，切语言重建菜单 |
| G-8 | **GPU 视觉与业务 UI 解耦**：频谱/封面旋转等实时视觉作为独立 `VisualRenderer`（新增），由渲染循环驱动；P4 才做；默认关闭；没有关闭开关就不上线 |
| G-9 | **无障碍与视觉状态同源**：图标、tooltip、a11y label 从同一映射表生成；所有图标按钮必须有 label；键盘可完成全部播放操作 |
| G-10 | **拖放与右键菜单是一等交互**：文件拖入窗口入队、曲目行右键菜单（播放/下一首播放/加入队列/收藏/在 Finder 显示/音质体检/同目录版本对比）在原生 UI 中保留（现状入口见 `src/net/ui_script.h:7936-7999`、`:13583-13652`） |

### 9.2 依据

- 竞品反例【事实】：三代图标命名并存（`_h`/`hover`/`Hover`，normal 32 vs hover 99，`report_ui.md:197-209`）；687 个散装 png/svg/tiff（`report_ui.md:170`）；19 个 nib 载荷中 10 个 NIBArchive v1 不可 `plutil` 解析（`report_ui.md:16-46`）；巨型控制器 629/291 方法（`report_ui.md:117-118`）。
- 竞品正例【事实】：图标 + 无障碍标签 + tooltip 在同一处一起设置（`updatePlayModeButtonsState`，`report_playmode_merged.md:15`、`report_ui_lessons.md:83-118`）；矢量 SVG 按状态着色而不是为每状态出位图（`report_ui.md:211-218`）。
- 本项目现状【事实】：全部图标是内联 SVG（`viewBox='0 0 24 24'`、`stroke=currentColor`，`src/net/ui_page.h:1471-1733`；`REP_ICON` 在 `src/net/ui_script.h:6084-6089`）；三套主题是 CSS 变量块（`src/net/ui_page.h:131-185`）；`classic` 界面风格是第二套布局（`src/net/ui_page.h:643-655`）；i18n 是 DOM 后处理（`src/net/i18n.h:72-259`，1753 对）；菜单语言要重启（`tools/mac_host.mm:1010-1012`）。
- 任务书要求：资源命名从第一天定一套、矢量优先、Command 带 `localizedTitle/accessibilityLabel/keyEquivalent`、GPU 放最后阶段、nib 只放骨架（`PROMPT_UI_REDESIGN.md:76-84`）。

### 9.3 资源目录与命名

```text
tools/native/Resources/
├─ Assets.xcassets/
│  ├─ AppIcon.appiconset/                 # 复用现有品牌图标（res/rlplayer-256.png 等，来源 res/）
│  ├─ Colors/                             # 语义色（asset name = token 名）
│  │  ├─ TextPrimary.colorset
│  │  ├─ TextSecondary.colorset
│  │  ├─ BackgroundBase.colorset
│  │  ├─ SurfaceRaised.colorset
│  │  ├─ Separator.colorset
│  │  ├─ Accent.colorset
│  │  ├─ AccentSubtle.colorset
│  │  ├─ Danger.colorset
│  │  └─ …（约 18 个 token）
│  ├─ Icons/                              # 模板图（Template Image），tint 由控件决定
│  │  ├─ PlayerPlay.imageset
│  │  ├─ PlayerPause.imageset
│  │  ├─ PlayerNext.imageset
│  │  ├─ PlayerPrevious.imageset
│  │  ├─ PlayerStop.imageset
│  │  ├─ ModeOrder.imageset
│  │  ├─ ModeListLoop.imageset
│  │  ├─ ModeSingleLoop.imageset
│  │  ├─ ModeShuffle.imageset
│  │  ├─ LikeOutline.imageset
│  │  ├─ LikeFilled.imageset
│  │  ├─ Queue.imageset
│  │  ├─ Lyrics.imageset
│  │  ├─ SignalChain.imageset
│  │  └─ …
│  └─ Illustrations/                      # 复杂插画（可选，位图/多尺寸）
└─ zh-Hans.lproj/Localizable.strings
└─ en.lproj/Localizable.strings
```

命名规则（lint 强制）：

| 规则 | 反例（竞品） | 正例 |
|---|---|---|
| 文件名不含状态 | `playhover.tiff`、`cellLove_hover@2x.png` | `PlayerPlay` |
| 文件名不含倍率 | `@2x` / `@3x` 后缀 | Asset Catalog 自动处理 |
| 文件名不含明暗 | `*_dark.png` / `*_light.tiff` | `Colors/*` + Appearance |
| 语义而非外观 | `redFavoriteButton@2x.png` | `LikeFilled`（颜色由 tint 决定） |
| 一个语义一个名字 | `playModeLoop` / `playModeLoophover` / `playModeLoopSelected` | `ModeListLoop`（状态由控件表达） |

### 9.4 完整状态枚举与表达方式（G-3）

| 状态 | 表达方式 | 是否独立资源 |
|---|---|---|
| `normal` | 模板图原样 + `TextPrimary` tint | 否 |
| `hover` | AppKit 控件 hover 高亮：tint 提亮 + 8% accent 背景（自定义 `HoverButton`） | 否 |
| `pressed` | 控件 pressed：tint 压暗 12% + 0.98 缩放（Core Animation 100 ms） | 否 |
| `selected` | accent tint / 选中背景 `AccentSubtle` | 否 |
| `on` | filled symbol 变体（如 `heart.fill`）或 accent tint | 是（outline/filled 两个语义） |
| `off` | outline symbol / 默认 tint | 是（同上） |
| `disabled` | 40% opacity + 不接收事件（`isEnabled=false`） | 否 |
| `focused` | 2 pt accent focus ring（`focusRingType`） | 否 |
| `loading` | `NSProgressIndicator` / 旋转指示器，不是图标状态 | 否 |

> 这张表是「完整状态枚举」的唯一来源；新增控件不得引入第 10 个状态名。若某控件确实需要独立视觉（例如播放/暂停是两个语义而不是一个状态），按**两个语义资源**处理，而不是两个状态文件。

### 9.5 图标语义表（SF Symbols 优先，macOS 13 可用性需在 P1 校验）

| 语义 | SF Symbol | 自定义 asset | 备注 |
|---|---|---|---|
| 播放 | `play.fill` | — | 播放/暂停是「语义切换」，用两个 symbol |
| 暂停 | `pause.fill` | — | |
| 下一首 | `forward.fill` | — | 现有图标为实心三角+竖线 |
| 上一首 | `backward.fill` | — | |
| 停止 | `stop.fill` | — | |
| 顺序播放 | `arrow.right` | `ModeOrder`（如需 4 态统一风格） | 现有是直线箭头 |
| 列表循环 | `repeat` | `ModeListLoop` | 现有是环形箭头 |
| 单曲循环 | `repeat.1` | `ModeSingleLoop` | 现有是环形+1 |
| 随机 | `shuffle` | `ModeShuffle` | 现有是交叉箭头 |
| 收藏（未） | `heart` | — | 现有心形 SVG |
| 收藏（已） | `heart.fill` | — | accent 红 |
| 队列 | `list.bullet` | — | |
| 歌词 | `quote.bubble` | — | |
| 信号链 | `point.3.connected.trianglepath.dotted` | `SignalChain` | 若 macOS 13 无此 symbol 用自定义 |
| 设置 | `gearshape` | — | |
| 搜索 | `magnifyingglass` | — | |
| 更新 | `arrow.down.circle` | — | |
| 音量 | `speaker.wave.2.fill` | — | |
| 音频分析 | `waveform` | — | 单曲页左栏 |
| AI 整理 | `sparkles` | — | 单曲页右栏 |

- 自定义图标必须是 **template image**（`renderingMode = .template`），颜色一律由 tint 控制；不允许彩色图标（品牌 AppIcon 除外）。
- 若 SF Symbol 在 macOS 13 不可用：用 `if #available` 降级到自定义 asset；P1 在 macOS 13 环境做一次 symbol 可用性检查（新增脚本 `tools/check_symbols.swift`）。

### 9.6 主题与颜色 token（G-4）

- `Theme`（新增，Swift）：
```objc
// tools/native/native_host.mm（P1 已落地）：三套配色 × 语义 token
struct Theme {
    __unsafe_unretained NSColor *bg, *surface, *text, *muted, *accent, *separator;
};
static Theme theme_dark(void);  // theme_light / theme_blue 同构
// 视图禁止写死 NSColor(red:…)：统一从 [self currentTheme] 取。
```
- `Theme`（P1 已落地，`tools/native/native_host.mm`）持有三套配色的语义 token；切换主题调 `applyTheme`，不重建窗口。
- `NSAppearance` 只负责系统控件（菜单、sheet、文本框）的明暗；三套配色由 `Theme` 决定，不依赖 `NSColor` 的 dynamic provider（因为 blue 不是系统 appearance）。
- 硬编码颜色 lint：`rg -n "NSColor colorWith" tools/native/native_host.mm`（仅 Theme 构造允许）必须为空；例外清单写进 lint 配置并附理由。

### 9.7 字体与排版

| Token | 值 | 用途 |
|---|---|---|
| `titleLarge` | `.systemFont(ofSize: 22, weight: .semibold)` | 视图标题 |
| `title` | 17 / semibold | 卡片标题、设置分组标题 |
| `body` | 13 / regular | 列表正文、设置项 |
| `caption` | 11 / regular | 辅助信息、徽标 |
| `monoNumeric` | 13 / monospacedDigit | 时间、采样率、dB 值（`Font.monospacedDigit()`） |

- 不打包自定义字体（现状也未打包，`font-face` 0 命中）；若未来要打包需单独评估授权与体积。
- 行高/间距 token：4/8/12/16/24；圆角 8/12；不引入竞品式重阴影。

### 9.8 Command 表（G-5，写死）

| Command ID | 中文 / English | Accessibility label | 默认快捷键 | 菜单位置 | 可用条件 |
|---|---|---|---|---|---|
| `playPause` | 播放/暂停 · Play/Pause | 播放或暂停 / Play or pause | `Space` | 播放菜单 | 队列非空 |
| `next` | 下一首 · Next | 下一首 / Next track | `→`、`N` | 播放菜单 | 队列非空 |
| `previous` | 上一首 · Previous | 上一首 / Previous track | `←`、`P` | 播放菜单 | 队列非空 |
| `stop` | 停止 · Stop | 停止播放 / Stop | `S` | 播放菜单 | 正在播放 |
| `seekForward` | 快进 5 秒 · Forward 5s | 快进 5 秒 / Forward 5 seconds | `⇧→` | 播放菜单 | 正在播放 |
| `seekBackward` | 后退 5 秒 · Back 5s | 后退 5 秒 / Back 5 seconds | `⇧←` | 播放菜单 | 正在播放 |
| `volumeUp` | 音量 +0.5 dB · Volume Up | 音量增加 / Volume up | `↑` | 播放菜单 | 始终 |
| `volumeDown` | 音量 −0.5 dB · Volume Down | 音量降低 / Volume down | `↓` | 播放菜单 | 始终 |
| `cycleMode` | 切换播放模式 · Cycle Play Mode | 播放模式：<当前> / Playback mode: <current> | `⌘⇧M` | 播放菜单 | 队列非空 |
| `setModeOrder/ListLoop/SingleLoop/Shuffle` | 顺序/列表循环/单曲循环/随机 | 同上 | — | 播放 → 播放模式（勾选） | 队列非空 |
| `toggleLike` | 收藏 · Love | 收藏或取消收藏 / Love or unlike | `⌘L` | 播放菜单 | 有当前曲 |
| `playNext` | 下一首播放 · Play Next | 下一首播放 / Play next | — | 播放菜单/右键 | 有选中曲 |
| `toggleQueueRail` | 显示队列 · Show Queue | 显示或隐藏播放队列 / Show or hide queue | `⌥⌘2` | 显示菜单 | 始终 |
| `toggleLyricsRail` | 显示歌词 · Show Lyrics | 显示或隐藏歌词 / Show or hide lyrics | `⌥⌘3` | 显示菜单 | 始终 |
| `toggleSidebar` | 显示侧栏 · Show Sidebar | 显示或隐藏侧边栏 / Show or hide sidebar | `⌃⌘S` | 显示菜单 | 始终 |
| `toggleNowPlaying` | 正在播放 · Now Playing | 打开正在播放 / Open now playing | `⌘⇧P` | 显示菜单 | 有当前曲 |
| `focusSearch` | 搜索 · Search | 搜索资料库 / Search library | `⌘F` | 编辑菜单 | 始终 |
| `openSettings` | 设置… · Settings… | 打开设置 / Open settings | `⌘,` | App 菜单 | 始终 |
| `checkUpdate` | 检查更新… · Check for Updates… | 检查更新 / Check for updates | — | App 菜单 | 始终 |
| `clearQueue` | 清空队列 · Clear Queue | 清空播放队列 / Clear queue | — | 播放菜单（需确认） | 队列非空 |

- 裸键（Space、方向键、字母）由 `CommandRouter` 的 `NSEvent.addLocalMonitorForEvents` 处理：**第一响应者是文本编辑控件（搜索框/输入框）时全部放行**，避免打断输入；带 ⌘/⌥ 的组合作为菜单 `keyEquivalent`。
- 菜单项 enabled 状态由 `validateMenuItem` 读 Store（不各存一份）；勾选项（模式、侧栏显隐）同源。
- 媒体键与系统 Now Playing：`MPRemoteCommandCenter` 注册 `play/pause/next/previous/changePlaybackPosition/like`；`MPNowPlayingInfoCenter` 填标题/艺术家/专辑/时长/进度/封面；**这些系统入口不引入第二套状态**，全部转成 `AppCommand`。
- 现有 README 快捷键（`README.md:148-162`）全部保留；新增的 ⌘⇧M / ⌥⌘2 / ⌥⌘3 / ⌘⇧P 不与系统保留快捷键冲突（P1 实机确认）。

### 9.9 视图构建规则（G-6）

- 列表：`NSTableView` + `NSTableViewDiffableDataSource`；单元格复用；行高由 Auto Layout；不允许 `reloadData()` 全表刷新（用 diffable snapshot）。
- 网格：`NSCollectionView` + diffable；封面异步加载走现有缓存 API（不新增网络层）。
- 播放条：固定 68 pt，Auto Layout；进度条自绘 `NSSlider` 子类或 `NSView` + layer；拖动时暂停进度更新、松手后 commit（与现状 seek 拖动语义一致，`src/net/ui_script.h:6389`）。
- 空态/加载态/错误态：三件套统一 `StateView`（新增）：`loading`（spinner+文案）、`empty`（图标+说明+主按钮）、`error`（§6.4 的 banner/sheet）。每个列表必须实现三态，单测遍历。
- 右键菜单：`NSMenu` + `validateMenuItem`；现状有**两套右键菜单实现**（`QMENU`（`src/net/ui_script.h:4051`）与内联 `#__tmenu`（`:7926`）），原生统一成一套；保留现状功能：播放、下一首播放、加入队列、收藏、在 Finder 显示、音质体检、同目录版本对比（`:7936-7999`）。
- 拖放：`NSView.registerForDraggedTypes([.fileURL])`；拖入主窗口 = 入队（现状 `dropFiles`，`src/net/ui_script.h:13583-13652`）；拖到播放条 = 立即播放（新增，需产品确认；默认只入队）。
- 窗口/面板：`NSWindowController` 生命周期清晰；设置/更新窗口懒加载；关闭不销毁下载任务（§8.9 R-F5）。

### 9.9b 设置写入语义（不得破坏）

- `/api/settings` 是**合并写**：先读全量 kv，只覆盖白名单里本次提交的键，再整体写回；文件不可读按空处理。**不能改成整文件覆盖**——2026-10-23 事故：只 POST 一个键把 `backend/volume` 抹掉，回落出声（违反铁律 1）。证据：`tools/rtaweb.cpp:11290-11298,11388-11397`；键白名单 `:11324-11348`。
- 原生设置 Store 必须按「读-改-写」调用同一端点/同一 C++ 写函数；每个页签的保存只提交本页字段，但**写盘语义仍是合并写**。

### 9.10 i18n 管线（G-7）

```text
docs/i18n/chunk-*.tsv（现有 1753 对）
+ docs/i18n/chunk-native-*.tsv（新增：原生专属文案，格式同现有 中文<TAB>English）
        │
        ├─ tools/gen_i18n_table.py（现有）→ src/net/i18n_table.h（web 用，不变）
        └─ tools/gen_native_i18n.py（新增）→ tools/native/Resources/{zh-Hans,en}.lproj/Localizable.strings
                └─ 生成物进仓库；`ctest -R i18n_swift_check` 校验「源 TSV 变则生成物必须变」
```

- 静态文案 key = 中文源串（`Localizable.strings` 的 key），调用取词函数；动态文案用格式串（`"共 %d 首" = "%d tracks";`）。
- 禁止在 native UI 源码里写死中英文混排：文案统一进词表（日志/诊断除外）；P3 加 lint。
- 语言切换：写 conf → 通知所有视图刷新 + **重建原生菜单**（修复现状「菜单要重启」`tools/mac_host.mm:1010-1012`）；不整页重载（原生不需要）。
- 现有缺口：更新「通道/全球/中国大陆/准备中」与「正在下载/校验/安装」等进度文案**不在词表里**（调研笔记 C §7.5）→ P3 必须补齐并在英文界面验证，不能出现英文界面中英混排。
- 英文文案复用现有 1753 对中的英文；术语遵循 README 固定译法（升频=upsampling、噪声整形=noise shaping、抖动=dither、位完美=bit-perfect、独占(Hog)=exclusive (Hog)、分块卷积=partitioned convolution、共享输出=shared output、音质体检=audio health check、资料检索=library lookup、封面安全写回=safe cover write-back）。

### 9.11 GPU 视觉（G-8，P4）

- 只做**频谱**（若做）：`SpectrumRenderer` 协议（新增）：`update(samples: [Float]) / start() / stop() / setStyle(_:) / isEnabled`；实现用 `CAMetalLayer`；输入来自现有分析/FFT 数据，不反向读播放器状态。
- 默认关闭；设置→通用→播放提供开关；关闭时 `renderer = nil`，无空转定时器。
- 封面旋转（黑胶）**不做**：竞品的唱臂/底座/光晕/阴影多套贴图与 129 方法控制器是成本证据（`report_ui.md:246-253`），本项目没有黑胶产品语义。
- 若 P4 时间不足：整个 GPU 章节延后到 1.3，不影响 native UI 默认切换（P4 的「默认切换」判据不依赖频谱）。

### 9.12 验收判据

| 判据 | 方式 |
|---|---|
| 资源命名 lint | 新增 `tools/check_ui_assets.py`：文件名不含 `hover/pressed/selected/disabled/_dark/_light/@2x/@3x`；所有 `Icons/*` 声明 template；asset 名与代码引用一一对应（无死资源/缺资源） |
| 颜色 lint | `rg -n "NSColor colorWith" tools/native/native_host.mm`（仅 Theme 构造允许）为空；例外清单显式登记 |
| 状态枚举 | ctest/ObjC++ 单测：`ControlState` 枚举固定 9 项；任何视图不得新增状态名（用反射/枚举断言） |
| 图标映射 | ctest/ObjC++ 单测：`IconMap` 表每项都有 symbol 名或 asset 名；4 个模式图标与 `PlaybackMode.allCases.count` 相等（防竞品 4 vs 3 问题） |
| Command 表 | ctest/ObjC++ 单测：每个 `AppCommandID` 都有标题/a11y/菜单项；菜单项 target/action 全部指向 `CommandRouter`；裸键在文本编辑焦点下不被拦截（用假 firstResponder 断言） |
| 三主题 | ctest/ObjC++ 单测：每个 `ColorToken` 在 3 个 `Palette` 下都有值且非空；切换主题不重建窗口 |
| i18n | `ctest -R i18n_swift_check`：生成物与 TSV 一致；`zh-Hans`/`en` 键集合相等；无中文硬编码 lint 为空 |
| 无障碍 | ctest/ObjC++ 单测遍历主窗口/播放条/设置窗口视图树：每个 `NSButton` 有非空 `accessibilityLabel`；键盘 Tab 顺序覆盖全部控件（实机 R-15 复核） |
| 构建 | `RLPLAYER_UI=native` 0 error、0 新增 warning（`-Wall -Wextra` 现有级别）；`RLPLAYER_UI=web` 不受影响 |
| 实机 | §11 R-14/R-15/R-16（菜单/媒体键/语言/无障碍） |

### 9.13 风险

- **R-G1：SF Symbols 在 macOS 13 上缺失**。缓解：P1 用 `tools/check_symbols.swift` 逐符号校验，缺失则回退自定义 template asset；不依赖仅 macOS 14+ 的符号。
- **R-G2：`classic` 界面风格**（用户已定保留）。P1–P3 只实现三套配色，classic 作为 P4 的密度变体（同一套视图 + 间距 token），不复制两套 UI 代码。
- **R-G3：中文源串作 key 的 i18n 在文案修改时破坏翻译**。缓解：TSV 中「中文源串」改动必须同时改英文；`i18n_swift_check` 检测键集合变化并在 CI 输出 diff；长期迁移到语义 key 另行立项。
- **R-G4：裸键快捷键与文本输入冲突**。缓解：本地 key monitor 明确放行文本编辑；单测 + 实机 R-15。
- **R-G5：原生资源与 web 资源并存导致体积/维护双份**。缓解：P4 移除 web 构建前，两套资源各自独立；原生资源只放 UI 需要的（约 20 个 symbol + 插画），不迁移 687 个旧资源。

---

## 10. H. 分阶段落地计划（每阶段可独立验收）

### 10.1 决策与依据

| # | 决策 | 依据 |
|---|---|---|
| H-1 | 先做原生外壳+桥（P1），再按最小清单做状态/随机/调度/错误（P2），设置/更新/系统集成（P3），视觉与默认切换（P4） | 没有外壳则组件无处落地；最小清单排序见 `LESSONS_FOR_MY_APP.md:165-178` |
| H-2 | 每阶段独立可验收：两构建 0 error + ctest + 实机清单 + 功能矩阵行；web 版回归不红 | 功能不删除（铁律 1）；双 UI 并行（D1） |
| H-3 | 允许降级而不是假开关：crossfade 超期则整块延到 1.3，设置页不出现滑块 | 任务书禁止无判据空话；项目铁律 4 如实挂账 |
| H-4 | 资源规范 P1 就生效（从第一天定一套），不等到最后统一改 | 竞品三代命名是后期改不动的反例（`report_ui.md:197-209`、`LESSONS_FOR_MY_APP.md:176`） |

**排序说明**：任务书要求按 `LESSONS_FOR_MY_APP.md:165-178` 的「最小可落地清单」性价比排序：**PlaybackModeStore → ShuffleQueue → 错误 RecoveryAction → 调度单一入口 → crossfade/预加载 → Command 层 → 更新弹窗 → 资源体系**。
- 本项目还多一个前置：**原生 UI 外壳与核心桥**（否则上述组件无处落地）；以及**双 UI 并行**（功能不删除）。
- 因此排序为：P0 契约 → P1 外壳+桥 → P2 状态/随机/调度/错误/Command → P3 设置/更新/系统集成/crossfade → P4 视觉/默认切换。资源规范在 P1 就生效（从第一天定一套，`LESSONS_FOR_MY_APP.md:176`）。

### 10.2 门禁命令（每阶段通用）

```bash
# 构建（两个 UI 都要过；CMake 路径按本机 skill rlplayer-dev §2，二选一实测）
CM=~/tools/cmake-3.31.6-macos-universal/CMake.app/Contents/bin
cd "$RLPLAYER_REPO"   # 项目仓库根；本方案工作树亦可
$CM/cmake -S . -B build-mac -DCMAKE_BUILD_TYPE=Release -DRLPLAYER_UI=web
$CM/cmake --build build-mac -j8            # 0 error
$CM/ctest --test-dir build-mac -j1 --output-on-failure   # 全绿；串行跑

$CM/cmake -S . -B build-mac-native -DCMAKE_BUILD_TYPE=Release -DRLPLAYER_UI=native
$CM/cmake --build build-mac-native -j8     # 0 error

# web 页面内自检（仅 web 构建；backend=null，volume=-120，端口 19152）
RLPLAYER_STATE_DIR=<tmp>/state RLPLAYER_LIBRARY_DIR=<tmp>/lib HOME=<tmp>/home \
  build-mac/rtaweb --port 19152 --music-dir <tmp>/music
curl -X POST http://127.0.0.1:19152/api/selftest/request
# 用 DSH 侧边栏打开 http://127.0.0.1:19152/（禁止无头浏览器）
cat <tmp>/state/selftest-last.json        # 期望 20/20 PASS（基线以实测为准）

# 原生 UI 构建产物
# 由 tools/make_app_mac.sh 生成 dist-mac/RLPlayer.app（native 构建下不创建 WKWebView）
```

- **不碰 8899**（用户正在用）；测试端口 19091+/19152；不 force-kill（只 `kill -TERM` 且先核验属主）。
- 所有「红→绿」证据落 `docs/ui-redo/evidence/<phase>/`（新增目录，文本日志/命令输出，不进构建产物）。

### 10.3 阶段表（P0 为前置契约阶段；可独立验收的**交付阶段为 P1–P4，共 4 个**）

#### P0 契约冻结与可行性探针（1–2 天）

| 项 | 内容 |
|---|---|
| 交付物 | ① 本方案文档（已按最终决策改定）；② 附录 A 功能对齐矩阵定稿；③ 决策记录 D0–D14（全部已定，不列待决策）；④ 构建链确认（纯 ObjC++，无需 Swift/Ninja）；⑤ 基线记录：`ctest -N`、web selftest 结论、构建耗时（只记录，不承诺） |
| 可验收判据 | 文档按最终决策改定；`ctest -N`=152（1.1.6 基线）；两构建 0 error |
| 依赖 | 无（直接在 main 上做） |
| 风险 | 无待决策项（用户已全部拍板） |

#### P1 原生外壳与只读桥（1–2 周）

| 项 | 内容 |
|---|---|
| 交付物 | ① CMake `RLPLAYER_UI=web|native` + `RLPlayerUI` Swift 目标；② `NSWindow` + `NSSplitViewController`（侧栏/主区/右栏/播放条）；③ `tools/RLPlayerCoreBridge.mm` + `tools/rlapp_playback.h`（只读快照 + 基础控制）；④ 资料库四视图（专辑/专辑详情/艺术家/曲目）与搜索；⑤ 播放条（播放/暂停/上一首/下一首/进度/音量）；⑥ `CommandRouter` 基础命令；⑦ Asset Catalog + 三主题 token；⑧ i18n 生成器与 `Localizable.strings`；⑨ 窗口状态恢复 |
| 可验收判据 | 两构建 0 error；ctest 全绿（web 行为不变）；原生 App 可启动、浏览、播放、暂停、切歌；`MainWindowController` 无 `WKWebView`；ctest/ObjC++ 单测（桥映射/Store 基础/命令路由）≥10 条；实机 R-01..R-05 |
| 依赖 | P0（已定纯 AppKit） |
| 风险 | 桥线程安全、双 UI 分叉；缓解见 §3.5/§9.13（构建链风险已消除） |

#### P2 播放状态、随机、调度与交互链路（2–3 周）

| 项 | 内容 |
|---|---|
| 交付物 | ① `PlaybackModeStore`（Swift）+ 模式 4 态多入口；② `ShuffleOrder`/`PlaybackHistory`（C++ 新增）+ base 持久化 + 注入种子；③ `PlaybackRequest/PlayOptions` 门面 + 场景表；④ upNext 插播队列；⑤ 错误模型 `PlaybackError/RecoveryAction` + banner/sheet；⑥ 队列面板（右栏）与队列页（排序/拖拽/保存歌单）；⑦ 播放历史上一首；⑧ 新增 ctest 与 ctest/ObjC++ 单测；⑨ 把 `tools/check_playmode_behavior.py` 的判据移植进 ctest |
| 可验收判据 | 新增 ctest（§4.4/§5.5/§6.2/§6.3/§6.4）全绿；标注「先红」的判据有红→绿证据；web 回归全绿；实机 R-06..R-10；功能矩阵相关行全部勾选 |
| 依赖 | P1；`rlapp_playback` 门面 |
| 风险 | 门面与旧 handler 双实现漂移；随机/历史语义边界；缓解见 §4.5/§5.6 |

#### P3 设置、更新、系统集成与淡入淡出（2–3 周）

| 项 | 内容 |
|---|---|
| 交付物 | ① 设置窗口 10 页签（全部现有控件）+ 保存/恢复默认语义；② 新增「通用→播放」分组：淡入淡出/预加载（若引擎按计划落地）；③ 更新窗口 + `UpdateCoordinator` 状态机 + 忽略/稍后持久化 + 本地埋点 + `RLPLAYER_UPDATE_FEED` 测试钩子；④ 菜单（App/文件/编辑/播放/显示/窗口/帮助）+ 快捷键 + `MPRemoteCommandCenter`/`MPNowPlayingInfoCenter`；⑤ 单曲页（歌词/分析/AI 整理）；⑥ 快速开始页；⑦ 流媒体/文件夹/最近/收藏/歌单；⑧ 无障碍审计；⑨ 语言切换重建菜单 |
| 可验收判据 | 设置页每个页签与 web 版控件逐项对齐（矩阵）；更新状态机单测 17 分支；门槛/持久化/安全顺序测试；跨淡 planner 测试（若落地）；`ctest -R update` 全绿；实机 R-11..R-16；web 回归全绿 |
| 依赖 | P2；更新引擎现有能力（`src/net/update_*`、`tools/mac_update.*`） |
| 风险 | 跨淡引擎改造超期 → 降级 1.3（§7.5）；更新安装权限 → 用户协助路径；设置页工作量大 |

#### P4 视觉收尾、GPU 与默认切换（1–2 周）

| 项 | 内容 |
|---|---|
| 交付物 | ① 频谱（可选）与最终视觉打磨；② 性能基线对比（冷启动/内存/空闲 CPU；只记录，不编数字）；③ 原生默认：发布构建 `RLPLAYER_UI=native`，web 构建仅保留在源码开关中；④ 移除发布包里的 WKWebView 主内容路径；⑤ README/发版说明更新；⑥ 1.1.7 打包与实机清单 |
| 可验收判据 | 附录 A 矩阵**全部行**为 native 已验证（或用户书面接受的例外）；实机 R-17..R-20；两构建仍可编译；无功能删除；`ctest` 全绿；发布包自包含（现有 `make_app_mac.sh` 门禁） |
| 依赖 | P3；Q8 确认移除 web 的时机 |
| 风险 | 视觉收尾无限扩张 → 以矩阵与清单封顶；GPU 可整段延后 |

### 10.4 阶段与「最小清单」的对应

| LESSONS 清单项 | 本方案阶段 | 本方案章节 |
|---|---|---|
| PlaybackModeStore 单例 + 通知 + 去重 + 持久化 | P2 | §3 |
| ShuffleQueue 整表洗牌 + 游标 + 保当前曲 + 一轮重洗 | P2 | §4 |
| 错误类型带 RecoveryAction | P2 | §6.4 |
| 播放调度单一入口 + OptionSet | P2 | §5 |
| crossfade + 结尾预加载 | P3（可降级） | §7 |
| Command 层统一多入口 + 无障碍 | P1–P3 | §6.0/§9.8 |
| 更新弹窗状态机 + 门槛 + 持久化 + 埋点 | P3 | §8 |
| 资源命名与矢量图标体系 | P1 起 | §9 |

### 10.5 工期与关键路径（决策值，不是承诺）

- 合计约 **6–10 周**（单人、不含用户实机验收等待）；关键路径：P1 桥/外壳 → P2 状态与调度 → P3 设置/更新 → P4 默认切换。
- 可并行的点：P2 的随机/历史（C++）与 Swift Store/队列 UI；P3 的更新窗口与设置页；但**共享文件（`CMakeLists.txt`、`tools/rtaweb.cpp`、`tools/mac_host.mm`）同一时刻只能一个写者**（工作区守则 §2.2）。
- 若只能做一件事：先 P2 的 PlaybackModeStore + 错误恢复（性价比最高，且可独立于原生外壳先以 web 侧改造验证）；但本方案的目标是 native，故顺序仍以 P1 前置。

### 10.6 阶段级风险登记

| 风险 | 影响 | 缓解 |
|---|---|---|
| 构建链不支持 Swift | P1 | 已按用户决定改用纯 ObjC++/AppKit，Makefiles generator 原生支持，风险消除 |
| 双 UI 期间回归责任不清 | 质量下降 | 每阶段「web 回归」判据写死；CI 两构建都跑 |
| 功能矩阵漏项 | 违反铁律 1 | 矩阵按 §附录 A 逐项勾选；P4 全量复核；用户实机抽查 |
| 设置页 10 页签迁移量被低估 | P3 延期 | P3 前先做控件盘点（P1 产出清单）；允许分两次交付（P3a 通用/输出/PCM/SDM/EQ，P3b 其余） |
| 更新安装路径与用户环境差异 | 更新失败 | 用户协助安装路径 + 明确文案 + 测试钩子覆盖失败分支 |


---

## 11. 实机验证清单（由用户执行）

> 分工：单元测试/构建/lint/静态检查由开发方（本分支实现者）自跑；**装进 `/Applications`、真点按钮、真看/真听结果由用户执行**。本方案只给命令与预期，不代替实机结论。
>
> 通用规则：测试实例 `backend=null`、`volume=-120`（不向听音设备出声）；端口只用 19091+/19152，**8899 绝不碰**；停服务只 `kill -TERM` 且先核验属主；不 force-kill。
>
> 记录方式：每条填 `PASS / FAIL / 未做`，FAIL 附截图与日志；清单整体落 `docs/ui-redo/evidence/real-machine/<date>.md`（新增，按项目习惯可复核）。

### 11.1 P0 基线确认（现在就能跑，用于对照）

| ID | 操作 | 预期 | 要看什么 |
|---|---|---|---|
| B-00 | 用隔离目录启动 web 测试实例：`RLPLAYER_STATE_DIR=<tmp>/state RLPLAYER_LIBRARY_DIR=<tmp>/lib HOME=<tmp>/home build-mac/rtaweb --port 19152 --music-dir <tmp>/music` → `curl -X POST http://127.0.0.1:19152/api/selftest/request` → DSH 侧边栏打开 `http://127.0.0.1:19152/` | 页面加载；`<tmp>/state/selftest-last.json` 出现且 `20/20 PASS` | 结论文件 `want/got` 逐条；若失败先按现有判据修，不进入 P1 |
| B-01 | 同一实例：依次点四种播放模式（底栏循环键），观察图标/文案；重启 rtaweb 再打开 | 0→1→2→3→0；重启后保持上次模式；队列文件 `<tmp>/state/rlplayer-playlist.txt` 的 `mode=` 同步 | 记录当前行为（这是 P2 对照基线）；已知现状：随机模式手动「下一首」在末尾只回绕不重洗（`tools/rtaweb.cpp:10596-10601`） |
| B-02 | 记录当前 `ctest -N` 数量与 `--build` 耗时 | 仅记录，不作通过判据 | 写入 P0 evidence；README 的 113/113 已过期（`README.md:205`） |

### 11.2 P1 原生外壳

| ID | 操作 | 预期 | 要看什么 |
|---|---|---|---|
| R-01 | 启动 native 构建（P1 起由 `tools/make_app_mac.sh` 产出；具体路径由实现者在 P1 补充命令），拖动窗口四边、最大化、绿钮全屏、退出重开 | 默认 1180×760，最小 760×480；布局不挤压；重开后窗口位置/尺寸/侧栏折叠状态恢复 | 四档窗口尺寸（760/1024/1280/1576）；红绿灯与顶栏对齐 |
| R-02 | 折叠/展开侧栏、右栏；切换 10 个导航视图 | 主区切换无闪烁；右栏队列/歌词可独立显示；返回（Cmd+[ 或菜单）回到上一视图 | 导航栈是否正确；滚动位置是否保留 |
| R-03 | 顶栏/设置切换 dark/light/blue 三个主题；切换系统明暗 | 三套主题全部生效；无残留硬编码色块；原生菜单/sheet 跟随系统 appearance | 对话框、右键菜单、滚动条、空态是否同色系 |
| R-04 | 浏览专辑网格→专辑详情→艺术家→曲目→搜索；拖文件进窗口 | 各视图数据正确；搜索防抖与清空正常；拖入文件入队（默认不立即播放） | 封面加载、长列表滚动、空态/加载态 |
| R-05 | 键盘：Space、←/→、N/P/S、↑/↓、⇧←/⇧→、L、I、⌘F、Esc；在搜索框内重复输入 | 播放控制生效；**搜索框获得焦点时裸键不触发播放控制**；Esc 逐层返回 | 冲突与焦点丢失；菜单项 enabled 状态 |

### 11.3 P2 播放状态与交互链路

| ID | 操作 | 预期 | 要看什么 |
|---|---|---|---|
| R-06 | 播放条/Now Playing/设置/菜单/快捷键五个入口分别切模式；同值再点一次 | 五个入口同步；同值不闪、不写盘；重启保持 | 图标/文案/VoiceOver 一致；`mode=` 文件未变 |
| R-07 | 随机模式连续「下一首」超过队列长度 ×2；用「上一首」连续回退 | 一轮内不重复；跨轮第一首不等于上一轮最后一首；上一首回到刚听过的曲 | 记录实际顺序；对照 §6.2 表 |
| R-08 | 右键曲目「下一首播放」加 2 首；快到曲末时加入第 3 首；播放完插播后继续 | 队列面板「接下来播放」显示 2–3 项；先播插播再回主队列；单曲循环下同样先播插播；重启后插播为空 | 主队列 index 不被插播污染；badge 数量 |
| R-09 | 播放一首存在的歌，然后在 Finder 中删除它；再删输出设备（或切换设备） | 出现带「重试/跳过/详情」的 banner；连续 3 次失败后暂停并保留出口；不出现只有「确定」的对话框 | 错误码/文案是否可理解；诊断页可导出 |
| R-10 | 队列页拖动排序、删除、清空、保存歌单；随机模式下拖动 | 与 web 版行为一致；随机态拖动给出「已退出随机排序」提示（新规则）；保存歌单可恢复 | 队列文件与 UI 一致 |

### 11.4 P3 设置、更新、系统集成

| ID | 操作 | 预期 | 要看什么 |
|---|---|---|---|
| R-11 | 逐页打开设置 10 个页签，改一个值→保存→重启；逐页「恢复默认」 | 每页控件与 web 版一致；保存/恢复按页语义生效；诊断/流媒体页仍即时生效无保存栏 | 控件缺失/错位；值与配置文件一致 |
| R-12 | 若 P3 交付 crossfade：设置开 3 s → 播两首 → 手动强跳下一首 → 切 DSD 输出 | 自然切歌有重叠且 bit-perfect 徽标显示「非逐位」；强跳硬切；DSD 下开关禁用并说明 | 听感由用户判断；状态徽标/文案必须如实 |
| R-13 | 更新假清单：`mkdir -p <tmp>/feed`；放一个 `latest.json`（version 高于当前、download_url/sha256/size 指向本地测试 dmg 或伪值）→ `python3 -m http.server 19153 --directory <tmp>/feed` → 设 `RLPLAYER_UPDATE_FEED=http://127.0.0.1:19153/latest.json` 启动 → 依次点「以后提醒」「忽略此版本」「立即更新（可失败）」「取消」「重启」 | 每个按钮按 §8.3 表动作；忽略/稍后重启后仍生效；失败分支给重试/下载页；不出现提权弹窗 | 状态机无死状态；`update.conf` 的 skipped/remind 值；埋点事件 |
| R-14 | 菜单逐项点；按 ⌘, ⌘F ⌘L ⌘⇧M ⌥⌘2 ⌥⌘3 ⌃⌘S ⌘⇧P；接入耳机后按媒体键（若可用） | 菜单项全部有响应或正确禁用；快捷键不冲突；媒体键/系统 Now Playing 显示当前曲与进度 | 系统「控制中心→正在播放」；Dock 右键菜单（若实现） |
| R-15 | 键盘 Tab 遍历主窗/设置/更新；开启 VoiceOver 抽查 10 个控件；切换语言到 English 再切回 | 焦点顺序合理；每个图标按钮有可读标签；**菜单在切语言后立即变**（修复现状需重启的问题）；无中文残留 | 读屏文本；菜单标题；动态文案（「共 N 首」） |
| R-16 | 设备占用/Hog 失败场景：播放时用另一 App 抢输出设备（或切到不存在设备）；投放到 UPnP 渲染器后断开网络 | 错误 sheet/banner 给「选择输出设备/重试/切回本地」；投放失败不假装成功 | 恢复后能否继续；日志错误码 |

### 11.5 P4 默认切换与发布

| ID | 操作 | 预期 | 要看什么 |
|---|---|---|---|
| R-17 | 若交付频谱：设置开关关闭/打开；播放时切歌/暂停/停止 | 关闭时无空转定时器与 GPU 占用；打开时随音频更新；停止后停止渲染 | Activity Monitor CPU/GPU；无崩溃 |
| R-18 | 按附录 A 全表抽查（每类至少 2 项） | 全部功能在 native UI 有入口且行为与 web 版一致（或用户书面接受例外） | 漏项/入口埋错层级 |
| R-19 | 冷启动 5 次取中位数；空闲 5 分钟记录内存；播放一首 5 分钟记录 CPU | 只记录真实数值，与 web 基线对比；不编造阈值 | 冷启动时间、峰值内存、空闲 CPU |
| R-20 | 出 1.1.7 包（P4 完成时）；装进 /Applications，双击启动，走一遍播放/设置/更新检查 | 自包含（ffmpeg/ffprobe/librtagpu/LICENSE/OPRA），无 WKWebView 主内容，签名/架构门禁通过 | `make_app_mac.sh` 输出；`lipo -info`；首次启动引导 |

### 11.6 已知限制（实机前先读）

- 本方案是**设计文档**，上述 native 行为尚未实现；P0 可执行的只有 B-00/B-01/B-02。
- 竞品资料全部为静态分析，**未运行 QQMusic.app**，因此「竞品实际 UI 表现」不能作为验收对象；本清单只验 RLPlayer。
- 需要用户听感判断的项（crossfade、无缝感）没有自动化判据；以「可关闭 + 状态如实 + 不失真」为底线，不用「听起来更好」当唯一通过条件。

---

## 12. 证据等级与已定事项

### 12.1 证据等级表

| 结论 | 等级 | 出处 |
|---|---|---|
| 竞品播放模式 3 态、按列表持久化、`setMode` 去重、随机整表洗牌、一轮重洗、上一首不计数 | **【事实】**（静态） | `report_playmode_merged.md:13,19-21,28-33`；原始证据 IMP/反汇编见该文件 §2/§3 |
| 竞品 9 个 `playList:Index:listPlayMode:` 变体与 5 个选项参数 | **【事实】**（`objc_index.tsv` 实测） | `report_playmode_merged.md:31`；`LESSONS_FOR_MY_APP.md:74-84` |
| 竞品插播队列优先、`listPlayMode` 取值集合、4 SVG vs 3 枚举 | **【推断/不确定】** | `report_playmode_merged.md:35-37,44-45` |
| 竞品更新弹窗一窗两视图 5 按钮、启动触发、OS>=10.11 编码门槛、`upgradeType` 2/3/5 语义、忽略/稍后持久化、埋点漏斗 | **【事实】**（2026-11-11 02:47 修正版；主控已复跑） | `report_lead_update.md:6-19,67-83,85-97,99-107,113-116`；`report_lead_update_addendum.md:5-31` |
| 竞品 `privilegedRemove:` 提权方式、CGI 具体服务器、灰度规则 | **【不确定】** | `report_lead_update.md:117-124` |
| 竞品 9 容器/19 载荷、NIBArchive v1 不可 plutil、687 资源、三代命名、629/291 方法 | **【事实】**（静态） | `report_ui.md:16-46,117-118,170,197-209` |
| 竞品横屏/写真全屏/简洁模式在 macOS 是否存在 | **【不确定】**（iOS 共享文案；不可当设计依据） | `report_ui.md:145-156,279-285` |
| 竞品 `FMMVC_*_%d_1` 百分比 | **【事实】模板占位符，不是实测数据** | `report_friendly_merged.md:20` |
| 本项目 4 态模式、`repeat`/`shuffle` 派生、持久化格式、随机实现、`/api/skip` 语义 | **【事实】**（代码） | §1.2/§3/§4/§6.2 引用行号 |
| 本项目无交叉淡化/gapless、预解码单槽、底栏错误被 CSS 隐藏、无媒体键/Now Playing、无窗口记忆 | **【事实】**（代码 grep） | §1.2、§6.4、§7.2、§9.2 引用 |
| 本项目播放/队列/模式 **0 条 ctest**、页面自检 20 条但无播放用例 | **【事实】** | 调研笔记 B §8.1-8.3（`CMakeLists.txt` grep；`src/net/ui_script.h:13862-14209`） |
| 本项目更新 UI（1.1.6）仍是设置→诊断卡片 + 底栏徽标；无独立更新窗口 / 无 release notes 展示 / 无取消 / 无重启按钮 / 无忽略与稍后 / 无节流 / 无运行时磁盘门槛 | **【事实】**（1.1.6） | 调研笔记 C §2-§4；`src/net/ui_script.h:380-528,14280-14286` |
| 1.1.6 已合入更新通道实现（PS256 验签 / JWS 解析 / 398 B 公钥头 / 后台 DMG 直链），已随正式版发布 | **【事实】** | `tools/mac_update.mm:406,680`；`src/net/update_channel.h:315`；`src/net/macos_update_pubkey.h` |
| 现有 ctest 基线数量 | **【未知】**（README 113 已过期；`CMakeLists.txt` 140 处 `add_test`） | 以 `ctest -N` 实测为准 |
| 本方案中的行为改变（历史上一首、upNext、错误码、crossfade、设置窗口） | **【决策】**（未实现） | 本文件各节 |
| 本方案文档自身的构建/测试 | **未运行**（纯文档；未构建、未跑 ctest、未实机） | 如实挂账；P0 起才有实现与判据 |

### 12.2 已定事项（用户 2026-11-11 全部拍板，无待决策项）

| 原编号 | 事项 | **最终决定** |
|---|---|---|
| Q1 | Universal（Intel）支持 | **只做 arm64**；`CMakeLists.txt` arm64 硬门禁保持，1.1.7 不做 Universal |
| Q2 | 原生 vs Web | **纯 AppKit（Objective-C++/ARC）**；不用 Swift/SwiftUI；双 UI 并行迁移，web 保留回退 |
| Q3 | `classic` 界面风格 | **保留**，作为 P4 的密度变体，不删（功能不删除） |
| Q4 | 真 gapless | **1.1.7 只做 crossfade（可降级）**；gapless 延后，不做假开关 |
| Q5 | 模式按歌单记忆 | **维持全局会话模式**（现状），不按歌单另存 |
| Q6 | 更新安装策略 | **不做提权**；目标不可写时引导拖入 /Applications；复用现有安装链 |
| Q7 | 移除 web UI 时机 | P4 对等验收后切默认；web 源码开关保留作回退 |
| Q8 | `RLPLAYER_UPDATE_FEED` 测试钩子 | 仅 Debug/开发菜单启用，Release 不生效 |
| Q9 | 语言切换重建菜单 | **即时重建**（行为改进） |
| Q10 | 1.1.6 未提交验签实现 | **已随 1.1.6 发布合入**（PS256/JWS/公钥头在 1.1.6 中已存在），不再有归属问题 |
| 基线 | 1.1.6 → 1.1.7 | 基线 = 已发布 **1.1.6**（`v1.1.6`）；当前内容在 `main` 上更新为 **1.1.7** |
| 分支 | 是否新建分支 | **不用分支**，直接在 `main` 上做 |
| 构建软件 | Swift 需要 Ninja | 纯 AppKit/ObjC++，沿用 Unix Makefiles，**不需要装 Ninja/Swift 构建链** |

> 说明：此前文档的「待用户确认」表述是主控把技术项误列为产品决策，已按用户「我不是让你直接做吗」纠正；1.1.7 P1 起直接实现，不再抛决策项。

### 12.3 竞品行为：采纳 / 不采纳

| 竞品行为 | 本方案 | 理由 |
|---|---|---|
| 单一状态源 + 广播 + 多视图各自渲染 | **采纳机制，适配实现** | §3；用 Combine + revision 替代无回执 NSNotification，并保留「广播 state 而非指令」原则 |
| `setMode` 去重 | **采纳** | §3；放在核心 + Store 双层 |
| 按播放列表持久化模式 | **不采纳（改为全局）** | 本项目是全局队列模型；见 D3/A-6/Q5 |
| 整表 Fisher–Yates + 游标 + 一轮重洗 + 保当前曲 | **采纳** | §4；保留现有实现并固化测试 |
| 上一首 = 排列游标回退 | **不采纳（改为播放历史）** | 随机下更符合「回到刚听的」；见 B-5/D2 |
| 插播队列优先 | **采纳（新增）** | §6.3；竞品分支未完全闭环，按最简单 FIFO 实现 |
| 错误类型带 RecoveryAction、主/次按钮 | **采纳（新增）** | §6.4 |
| crossfade + `isError:` 跳过 | **采纳机制，限 PCM** | §7；DSD/bit-perfect 限制如实标注 |
| 效果可关 + 告知收益 | **采纳原则，不抄数字** | 文案无百分比（竞品 `%d` 是占位符） |
| 更新：一窗两视图 5 出口、门槛、忽略/稍后持久化、埋点 | **采纳机制，重做 UI** | §8；不抄 nib/强制更新/静默安装 |
| 多 nib 载荷、三代图标、687 散装资源 | **不采纳** | 历史债；§9 用 SF Symbols + Asset Catalog |
| 强制更新、静默自动安装 | **不采纳** | 桌面端风险；普通弹窗 + 用户选择 |
| `privilegedRemove:` / 废弃提权 API | **不采纳** | 用现有校验+替换流水线；不可写时用户协助 |
| 4 个 SVG 模式图标 / 3 个枚举 | **不采纳** | 本项目 4 态；用「表长度 == 枚举数」单测防再犯 |
| 横屏/写真全屏/简洁模式 | **不采纳** | iOS 共享文案；macOS 无入口证据 |
| 迷你窗/桌面歌词/Touch Bar/Siri | **本版本不做** | 非现有功能，避免为对齐竞品扩范围；列后续评估 |

### 12.4 本方案未做/未验证（如实挂账）

1. **未运行构建/测试/实机**：本文件是设计稿；所有「验收判据」是待实现后执行的判据，不是已通过的结果。
2. **未实现任何代码**（除文档）：P0 起才进入实现。
3. **构建链已验证**：纯 ObjC++/AppKit 在 CMake 3.31.6 + Unix Makefiles 下 `enable_language(OBJCXX)` 直接可编译；`RLPLAYER_UI=native` 全量构建 0 error。
4. **未验证 ctest 基线**：现有注册数待 `ctest -N` 实测；本文件不引用任何具体「全绿 N/N」数字。
5. **未验证 SF Symbols 在 macOS 13 的可用性**：P1 用 `check_symbols.swift` 逐项校验。
6. **未验证竞品实机行为**：全部竞品结论来自静态逆向；§12.1 已标事实/推断/不确定。
7. **未验证性能**：无冷启动/内存/CPU 数字；P4 只给「记录并与 web 基线对比」的方法，不给承诺值。
8. **决策已全部关闭**：见 §12.2。

### 12.5 风险登记（汇总）

| # | 风险 | 等级 | 缓解 |
|---|---|---|---|
| 1 | 方向已定：纯 AppKit | 低 | 用户 2026-11-11 已拍板，风险关闭 |
| 2 | Universal 范围 | 低 | 用户已定只做 arm64，风险关闭 |
| 3 | 构建链 | 低 | 已定纯 ObjC++/AppKit，Makefiles 原生支持，风险关闭 |
| 4 | 双 UI 期间回归漏检 | 中 | 每阶段 web 回归判据 + 两构建 CI |
| 5 | 设置页迁移量大导致 P3 延期 | 中 | P3a/P3b 拆分；控件盘点前置 |
| 6 | 功能矩阵漏项（违反铁律 1） | 高 | 附录 A 全表勾选；P4 用户抽查 |
| 7 | crossfade 引擎改造超期 | 中 | 可降级 1.3；不出现假开关 |
| 8 | 更新安装权限/环境差异 | 中 | 用户协助路径 + 失败分支测试 |
| 9 | i18n 中文作 key 的维护风险 | 低 | 生成器校验 + 键集合 diff |
| 10 | 性能/内存回归 | 低–中 | P4 基线记录与对比；不编数字 |


---

## 附录 A. 功能对齐矩阵（适配项目自身功能）

> 用途：证明「功能不能删除，只做全量移植」（项目铁律 1）。**每一行必须在 P4 前有 native 落点并验收**；标「用户接受例外」的行必须书面确认。
> 「当前入口」证据取自 1.1.6 发布基线（1.1.5.1 调研笔记的行号在 1.1.6 的 `src/net/ui_*.h` 上仍适用，1.1.6 未改这些 UI 文件）；「native 落点」为 §2/§9 定义的目标结构。

| # | 用户可见功能 | 当前入口（1.1.6） | native 落点 | 阶段 | 验收依据 |
|---|---|---|---|---|---|
| 1 | 本地曲库扫描/索引 | 顶栏扫描按钮；设置·通用·本地音乐库 | 设置·通用·本地音乐库 + 菜单「重新扫描」 | P3 | 功能矩阵抽查 |
| 2 | 专辑网格 | `albums` | `AlbumsGridViewController` | P1 | R-04 |
| 3 | 专辑详情（播放全部/入队/随机/设封面） | `album` | `AlbumDetailViewController` | P1 | R-04 |
| 4 | 艺术家网格与资料 | `artists` / `artist` | 对应 VC | P1/P2 | R-04 |
| 5 | 曲目列表（排序/加载更多） | `tracks` | `TracksViewController` | P1 | R-04 |
| 6 | 文件夹浏览 | `files` | `FilesViewController` | P2 | R-18 |
| 7 | 全局搜索（防抖、跨页） | 顶栏搜索 | `NSSearchField` + 路由 | P1 | R-04/R-05 |
| 8 | 流媒体服务器浏览 | `remote` | `RemoteViewController` | P2 | R-18 |
| 9 | 流媒体专辑详情 | `remote` 二级 | `StreamAlbumViewController` | P2 | R-18 |
| 10 | 播放队列（右侧抽屉） | `#right` | `RightRailViewController`（队列 tab） | P2 | R-10 |
| 11 | 播放队列整页（排序/拖拽/清空/存歌单） | `queue` | `QueueViewController` | P2 | R-10 |
| 12 | 保存歌单 CRUD | 左栏 `#sqList` | `SavedQueueViewController` + 侧栏动态行 | P2 | R-10 |
| 13 | 我的最爱 | `favs` + 行内心 + Now Playing 心 | `FavoritesViewController` + `toggleLike` | P2 | R-10 |
| 14 | 最近播放 | `recent` | `RecentViewController` | P2 | R-18 |
| 15 | 快速开始（3 卡/官方预设/快捷入口） | `station` | `QuickStartViewController` | P3 | R-18 |
| 16 | 古典作品/演绎版本 | 曲目页/单曲页「作品」 | `WorkVersionsViewController` | P3 | R-18 |
| 17 | 播放/暂停/上一首/下一首/停止 | 播放条、Now Playing、键盘 | PlayerBar + Command | P1 | R-05 |
| 18 | 进度拖动/点击跳转 | `#seek`/`#npSeek` | `PlayerBar` 进度条 | P1 | R-05 |
| 19 | 音量曲线 + 真静音位 | `#vol`/`#npVol`/↑↓ | PlayerBar 音量控件 | P1 | R-05 |
| 20 | 四态播放模式 | `#bRep`/`#npRep`/`sp_rep` | `PlaybackModeStore` + 4 入口 | P2 | R-06 |
| 21 | 0.1 dB 音量微调 | Shift+↑↓ | Command 修饰键 | P1 | R-05 |
| 22 | 6 态 bit-perfect 徽标 | `#bpBadge` | PlayerBar 徽标组件 | P1 | R-05 |
| 23 | 信号链可视化 | `#bChain` / `i` | 原生 sheet + 信号链视图 | P3 | R-18 |
| 24 | 歌词 | 右栏歌词 tab / Now Playing | RightRail 歌词 + Now Playing 中列 | P3 | R-18 |
| 25 | Now Playing 整页 | `#npPage` | `NowPlayingViewController` | P3 | R-18 |
| 26 | 音频分析 L0/L1/L2 | `#npAnal` | Now Playing 左栏 | P3 | R-18 |
| 27 | 分析三动作分段控件（自动/详细/分析） | `#npAnal .anlseg` | 分段控件（纯 AppKit） | P3 | R-18 |
| 28 | AI 整理四芯片/简略详细/资料浮层 | `#npRail`/`#npDrawer` | 右栏卡片 + 原生 sheet | P3 | R-18 |
| 29 | 左右竖栏可完全隐藏 | 右上开关 + 面板头隐藏键 | Now Playing 右上开关 | P3 | R-18 |
| 30 | 输出后端（CoreAudio 独占/共享/UPnP/Null） | 设置·输出 | 设置·输出 | P3 | R-11 |
| 31 | 严格独占 Hog（默认开） | 设置·输出 | 设置·输出 | P3 | R-11 |
| 32 | 一键 bit-perfect 直通 | 设置·输出按钮 | 设置·输出 | P3 | R-11 |
| 33 | 采样率/位深/声道/缓冲/渐变 | 设置·输出 | 设置·输出 | P3 | R-11 |
| 34 | 声道音量微调（2–8 ch） | 设置·输出 | 设置·输出 | P3 | R-11 |
| 35 | PCM 升频（1x/Nx/相位/抽头/阻带/过渡带/两段式） | 设置·PCM | 设置·PCM | P3 | R-11 |
| 36 | 抖动/噪声整形/ISP 保护 | 设置·PCM | 设置·PCM | P3 | R-11 |
| 37 | DSD/SDM 输出（速率/DoP/调制器/阶数/拐点/抖动） | 设置·SDM | 设置·SDM | P3 | R-11 |
| 38 | DirectSDM / DSD 源抽取/Convention | 设置·SDM | 设置·SDM | P3 | R-11 |
| 39 | 输入采集/直通监听/录制 + 实时仪表 | 设置·输入 | 设置·输入 | P3 | R-11 |
| 40 | 20 段 PEQ（曲线拖拽/表格/预设/自动前级） | 设置·EQ | 设置·EQ（纯 AppKit 图表 + 表格） | P3 | R-11 |
| 41 | OPRA 耳机 EQ（6230 条） | 设置·EQ | 设置·EQ | P3 | R-11 |
| 42 | EQ 文件（REW/AutoEq）/房间 IR | 设置·声音校准 | 设置·声音校准 | P3 | R-11 |
| 43 | 房间测量向导（**当前是占位**） | 设置·声音校准（显示重构中） | 保持占位，不新增承诺 | P3 | 保持现状 |
| 44 | 元数据补全（6 源/排序/写回） | 设置·元数据 | 设置·元数据 | P3 | R-11 |
| 45 | AI/LLM 接入 + 检索端点 | 设置·元数据·高级选项 | 设置·元数据 | P3 | R-11 |
| 46 | UPnP/DLNA 投放（含投放升频/强制目标率） | 设置·流媒体 + 单曲页 + 底栏徽标 | 设置·流媒体 + Now Playing | P3 | R-16 |
| 47 | AirPlay 投放（同一设备列表） | 设置·流媒体 | 设置·流媒体 | P3 | R-16 |
| 48 | 系统 AirPlay 输出（作为输出设备） | 设置·输出设备列表（后端上报） | 设置·输出 | P3 | R-11 |
| 49 | 音质体检 | 曲目右键 | 右键菜单 → 原生浮层 | P2 | R-10 |
| 50 | 同目录版本对比 | 曲目右键 | 右键菜单 → 原生浮层 | P3 | R-18 |
| 51 | 诊断包/摘要/上传 | 设置·诊断 | 设置·诊断 | P3 | R-11 |
| 52 | 软件更新（通道/检查/Beta/进度/徽标） | 设置·诊断 + 底栏徽标 | 更新窗口 + 设置·诊断 | P3 | R-13 |
| 53 | 反馈问题（邮件 + 诊断附件） | 设置·诊断 | 设置·诊断 | P3 | R-11 |
| 54 | 三套配色 + 语言切换 | 顶栏 + 设置·通用·外观 | Menu/设置 + `ThemeStore`/i18n | P1/P3 | R-03/R-15 |
| 55 | `classic` 界面风格 | 设置·通用·外观（`data-uistyle`） | **保留**（用户已定），P4 作为密度变体 | P4 | R-18 |
| 56 | GPU 后端（Metal/CPU） | 设置·通用·GPU + 底栏徽标 | 设置·通用·GPU + 徽标 | P3 | R-11 |
| 57 | 快捷键帮助 | 顶栏帮助按钮 | 菜单「帮助 → 键盘快捷键」 | P3 | R-14 |
| 58 | 拖文件进窗口入队 | 全窗口拖放 | `NSView` 拖放 + 入队 | P1 | R-04 |
| 59 | 等响度补偿 | 设置·通用·播放 | 设置·通用·播放 | P3 | R-11 |
| 60 | 窗口位置/尺寸/侧栏状态记忆（现状没有） | 无 | `setFrameAutosaveName` + 偏好 | P1 | R-01 |
| 61 | **新增**：下一首播放（插播队列） | 无 | §6.3 | P2 | R-08 |
| 62 | **新增**：交叉淡入淡出 | 无 | §7 | P3（可降级） | R-12 |
| 63 | **新增**：媒体键/系统 Now Playing | 无 | §9.8 | P3 | R-14 |
| 64 | **新增**：前进/后退导航栈与 Esc 层级 | 无（仅 Esc 链） | `NavigationStore` | P1 | R-02 |
| 65 | **新增**：窗口状态恢复 | 无 | P1 | R-01 |

> 说明：第 1–60 行是**现有功能**（必须保留，唯一例外是第 43 行现状本来就是占位、第 55 行用户已定保留）；第 61–65 行是本次重做的新增能力。若实现中发现遗漏，先补矩阵再动手，不允许「先删后说」。

---

## 附录 B. 接口映射（现有核心 → native 桥）

| 现有接口/端点（1.1.6） | 语义 | native 桥方法（P1 已落地 / P2 计划） | 阶段 |
|---|---|---|---|
| `GET /api/status`（400 ms 轮询；**无 mode/index**） | 播放/进度/输出/bit-perfect/错误文本 | `RLCoreBridge.playbackSnapshot()`（直接读核心，拼上 mode/index/count） | P1 |
| `GET /api/queue[?meta=1]` | 队列 + mode + 元数据 | `RLCoreBridge.queueSnapshot(includeMeta:)` | P1/P2 |
| `POST /api/play` | 单曲点播（追加并定位） | `play(request, options: [.locateExisting, .appendToQueue, .autoPlay, …])` | P2 |
| `POST /api/lib/play` | 整张专辑起播（替换整列） | `play(request, options: [.replaceQueue, .autoPlay, …])` | P2 |
| `POST /api/add` | 入队 | `play(request, options: [.appendToQueue])`（不自动播） | P2 |
| `POST /api/queue/set` | 整列替换 | `setQueue(items:)` | P2 |
| `POST /api/playmode` | 模式写 | `setPlayMode(_:)` | P2 |
| `POST /api/skip` | 下一首/上一首 | `next(reason:)` / `previous(reason:)`（新语义，§6.2） | P2 |
| `POST /api/pause` / `stop` / `seek` | 暂停/停止/跳转 | `pause(_:)` / `stop()` / `seek(fraction:)` | P1 |
| `POST /api/qdel` / `qmove` / `qsort` / `qorder` | 队列编辑 | `remove/move/sort/reorder` | P2 |
| `POST /api/clear` | 清空 | `clearQueue()` | P2 |
| `GET/POST /api/recent`、`/api/fav/*`、`/api/sq/*`、`/api/pl/*` | 最近/收藏/歌单/播放列表 | 同名桥方法（P2 前可先复用 `dispatch` JSON） | P2 |
| 库查询（`/api/lib/*`、`/api/files`、`/api/src/*`） | 资料库 | 过渡期复用 `rlapp::dispatch`；P3 再类型化 | P1–P3 |
| 分析/元数据（`/api/track/health`、`/api/meta`、`/api/entity`） | 分析/AI | 过渡期复用 `dispatch`；P3 类型化 | P3 |
| 投放（`/api/cast/*`） | UPnP/AirPlay | `cast*` 桥方法 | P3 |
| 设置（`/api/settings`） | 配置 | `settings` 桥方法（键白名单不变） | P1/P3 |
| 更新（`update:check` / `update:install` 宿主消息） | 更新 | `UpdateCoordinator` + C++ 更新引擎（`begin_check`/`begin_install`） | P3 |
| `POST /api/selftest/*`（web 专用） | 自检 | native 不适用；用 ctest/ObjC++ 单测替代 | — |

> 兼容红线：现有 HTTP 契约不变（web/CLI 仍可用）；native 桥是**新增层**，不替换 HTTP handler，直到 P4 后再评估是否收敛。

---

## 附录 C. 竞品行为明细：采纳 / 不采纳（含证据）

| # | 竞品做法 | 证据 | 本方案 | 备注 |
|---|---|---|---|---|
| 1 | 模式单例 + 按列表持久化 + NSNotification 广播 | `report_playmode_merged.md:13,15`；`LESSONS_FOR_MY_APP.md:9-28` | 采纳「单一状态源 + 广播后回读」；**不采纳按列表持久化**（本项目全局队列） | 用 Combine + revision 替代无回执通知 |
| 2 | `setNewPlayMode:` 去重 | `report_playmode_merged.md:21` | 采纳；去重放核心 + Store 两层 | |
| 3 | 3 种模式（1/2/3）、4 个 SVG | `report_playmode_merged.md:19,26` | **不采纳**：保留本项目 4 态（0–3） | 用「图标表长度 == 枚举数」单测防不一致 |
| 4 | 随机：整表 Fisher–Yates、游标、一轮重洗、上一首不计数 | `report_playmode_merged.md:28-33` | 采纳机制；**上一首改为播放历史** | 改进跨轮立刻重复（现有代码已做，补测试） |
| 5 | 9 个 `playList:Index:listPlayMode:` 变体 + 5 选项 | `report_playmode_merged.md:31` | 采纳「单入口 + OptionSet」；9 个变体不采纳 | §5 场景表 |
| 6 | 插播队列优先、消耗完回主列表 | `report_playmode_merged.md:35-37`（部分推断） | 采纳为显式 `upNext` FIFO（新增） | 竞品分支未闭环，按最简单一致语义 |
| 7 | `fade` 166 处 + 滑杆/开关 + `isError:` 跳过 | `report_friendly_merged.md:14`；`LESSONS_FOR_MY_APP.md:86-100` | 采纳机制；**只限 PCM**；DSD/bit-perfect 如实限制 | 默认关闭 |
| 8 | `FMMVC_*` 「关闭后提高 %d%」 | `report_friendly_merged.md:20` | **不采纳数字**；只写定性说明 | 没有实测不编百分比 |
| 9 | 错误带 RecoveryAction、主/次按钮 | `LESSONS_FOR_MY_APP.md:102-110` | 采纳（新增 `PlaybackError`） | §6.4 |
| 10 | 一窗两视图 5 按钮 + 门槛 + 忽略/稍后持久化 + 埋点 | `report_lead_update.md:6-19,67-83,99-107,113-116` | 采纳机制；UI 重做 | §8 |
| 11 | `upgradeType==5` 静默下载/自动安装、`==2` 强制更新 | `report_lead_update.md:67-83` | **不采纳** | 桌面端强制/静默风险 |
| 12 | `privilegedRemove:` 提权删除旧包 | `report_lead_update.md:85-97` | **不采纳**；用现有校验+替换 + 用户协助 | 不用废弃 API |
| 13 | 9 nib/19 载荷、三代图标命名、687 散装资源 | `report_ui.md:16-46,170,197-209` | **不采纳**；零 XIB + SF Symbols + Asset Catalog | §9 |
| 14 | 629/291 方法巨型控制器 | `report_ui.md:117-118` | **不采纳**；MVVM/Store 拆分 + 单文件行数约束 | §2.8/§3.5 |
| 15 | 横屏/写真全屏/简洁模式 | `report_ui.md:145-156`（iOS 共享文案） | **不采纳**（不设计没有 macOS 证据的形态） | |
| 16 | MiniPlayer/DesktopLyric/多窗口壳 | `report_ui.md:57-58,84-89` | **本版本不做** | 非现有功能，避免扩范围 |
| 17 | Touch Bar/状态栏/Dock 菜单/Siri | `report_ui_lessons.md:193-248`、`report_friendly_merged.md:11-13` | 本版本不做媒体键以外的入口；媒体键/Now Playing 做（用户日常需要） | §9.8 |

---

## 附录 D. Swift 参考实现：ShuffleQueue（纯教学对照；本项目已定纯 AppKit/ObjC++，此代码不进入仓库）

> 目的：满足任务书 B 的「Swift 数据结构与单元测试用例」。产品实现以 C++ `src/playback/shuffle_order.h` 为唯一真相（理由见 §4.3.6）；下面是逐行对应的 Swift 版本，供对照与评审，不编译进 App。
> 红→绿：本文件中的测试用例应先在「未实现/旧逻辑」的等价模拟上失败，再在 C++ 实现上通过（见 §4.4）。

```swift
// 参考实现（不进产品）：ShuffleQueue.swift
struct ShuffleQueue {
    private(set) var order: [Int]        // 原始下标排列
    private(set) var cursor: Int = -1
    let sourceCount: Int

    init(sourceCount: Int) {
        self.sourceCount = sourceCount
        self.order = Array(0..<sourceCount)
    }

    // keepingCurrentItem：切模式时保住正在播的歌
    // lastPlayed：上一轮最后一首，重洗后避免它出现在第 1 位
    mutating func reshuffle(keepingCurrentItem current: Int? = nil,
                            lastPlayed: Int? = nil,
                            rng: inout RandomNumberGenerator) {
        order = Array(0..<sourceCount)
        guard order.count > 1 else { cursor = current.map { _ in 0 } ?? -1; return }
        for i in 0..<(order.count - 1) {
            let j = Int.random(in: i..<order.count, using: &rng)
            order.swapAt(i, j)
        }
        if let last = lastPlayed, order[0] == last {
            if let k = (1..<order.count).first(where: { order[$0] != last }) {
                order.swapAt(0, k)
            }
        }
        cursor = current.flatMap { order.firstIndex(of: $0) } ?? -1
    }

    mutating func next(rng: inout RandomNumberGenerator,
                       lastPlayed: Int? = nil) -> Int? {
        guard sourceCount > 0 else { return nil }
        cursor += 1
        if cursor >= order.count {
            // 一轮走完：重洗；上一轮最后一首由调用方作为 lastPlayed 传入
            reshuffle(keepingCurrentItem: nil, lastPlayed: lastPlayed, rng: &rng)
            cursor = 0
        }
        guard cursor >= 0, cursor < order.count else { return nil }
        return order[cursor]
    }

    // 仅用于展示“接下来 N 首”；不跨轮（与 §4.3.5 的 ShuffleSnapshot 一致）
    func upcoming(_ n: Int) -> [Int] {
        guard cursor >= 0, cursor + 1 < order.count else { return [] }
        return Array(order[(cursor + 1)...].prefix(n))
    }
}
```

对照测试（Swift，教学版；产品测试在 C++ ctest）：

| # | 测试 | 期望 | 红→绿 |
|---|---|---|---|
| S-1 | `reshuffle` 后 `order.sorted() == Array(0..<n)` | 是 | 先红（无实现） |
| S-2 | `keepingCurrentItem=3` → `order[cursor] == 3` | 是 | 先红 |
| S-3 | `lastPlayed=7` 且 n>1 → `order[0] != 7` | 是 | 先红 |
| S-4 | 连续 `next` n 次（不重洗前）返回互不相同的值 | 是 | 先红 |
| S-5 | 第 n+1 次 `next` 触发重洗，`cursor == 0` 且 `order[0] != 上一轮最后` | 是 | 先红 |
| S-6 | `upcoming(n)` 在末尾返回 `[]`（不跨轮） | 是 | 先红 |
| S-7 | `sourceCount == 1`：`next` 永远返回 0，不崩溃 | 是 | 先红 |

---

## 附录 E. 参考与复跑线索

| 资料 | 用途 | 证据等级 |
|---|---|---|
| `<QQMUSIC_ANALYSIS>/LESSONS_FOR_MY_APP.md` | 主输入：9 个机制 + 最小落地清单 | 静态分析（事实/推断已标注） |
| `report_ui.md` | 竞品 UI 架构原始证据（nib/类/图标/Metal） | 【事实】为主，尾部列未验证 |
| `report_playmode_merged.md` / `report_playmode.md` | 播放模式/随机最终结论与原始证据 | 合并版为权威，IMP 需 ASLR slide |
| `report_friendly_merged.md` / `report_friendly.md` | 用户友好机制最终结论 | 合并版为权威 |
| `report_lead_update.md`（2026-11-11 02:47 修正版）+ `report_lead_update_addendum.md` | 更新弹窗机制（含 §3.1 实证修正） | 【事实】+【推断】 |
| `report_ui_lessons.md` | UI 机制学习笔记（窗口/图标/模式联动/GPU/失败路径） | 已验收（118 IMP 0 缺失） |
| `PROMPT_UI_REDESIGN.md` | 任务书 | — |
| 本项目 `README.md` / `ROADMAP-1.1.x.md` | 功能清单与版本计划 | 项目事实 |
| 本项目 `tools/check_playmode_behavior.py` | 现有四态推进判据（手动，未进 ctest） | 项目事实；P2 移植 |
| 内部调研笔记 A/B/C（`ui-redo-research/`，**未入库**） | 现状 UI/播放核心/更新平台的事实清单（每条带项目内 `文件:行号`） | 辅助材料；正文已尽量改引项目源码，笔记本身不是交付物 |

复跑线索（由实现者/主控执行，用户可抽查）：

```bash
# 竞品证据复跑（只读；不要运行竞品 App）
cd "$QQMUSIC_ANALYSIS"
rg -n $'QMPlayModeManager\t(shareInstance|setPlayMode:forPlayList:|getPlayMode:)' objc_index.tsv
rg -n 'kNotifyStatusPlayModeChanged|randomSongListArray' strings_all.txt

# 本项目证据复跑
cd "$RLPLAYER_REPO"
rg -n 'mode = 0|queue_set_mode_locked|queue_advance_locked' tools/rtaweb.cpp
rg -n 'crossfade|gapless|MPRemoteCommandCenter|MPNowPlayingInfoCenter' src tools tests
```

---

## 附录 F. 决策记录（ADR 摘要）

| ADR | 决策 | 备选 | 选择理由 | 撤销条件 |
|---|---|---|---|---|
| ADR-01 | **纯 AppKit（Objective-C++/ARC）** | Swift/SwiftUI / 继续 Web | 用户已定；单 macOS 无跨平台需求，ObjC++ 贴合现有壳与 Makefiles 构建链 | 撤销需用户明确改口 |
| ADR-02 | 双 UI 并行、构建开关 | 一次性替换 | 功能不删除；可回退 | P4 全绿 |
| ADR-03 | 状态真相源留在 C++ | UI 层复制一份状态 | 现有核心被多客户端共用；避免双真相 | 核心整体重写时 |
| ADR-04 | 模式全局持久化 | 按歌单持久化 | 现有一队列模型；避免第二真相 | 用户要 Q5 |
| ADR-05 | 上一首 = 历史栈 | 随机游标回退 | 用户心智「刚听的」；同时修正顺序模式 | 实机反馈强烈反对 |
| ADR-06 | crossfade 默认关、限 PCM | 默认开 / 全后端支持 | bit-perfect 承诺；DSD 无法混音 | 引擎能力变化 |
| ADR-07 | 更新不做强制/静默/提权 | 对齐竞品 | 桌面端风险与项目无此需求 | 用户明确要求 |
| ADR-08 | 零 XIB + 模板着色 + 语义色 | nib 壳 + 位图多态 | 竞品历史债反例；单一部署目标 | 需要复杂冻结布局时 |
| ADR-09 | 设置独立窗口、10 页签不变 | 主区内嵌 / 新增页签 | macOS 惯例；最小改动 | 用户要求保持内嵌 |

---

*文档结束。*

---

## 附录 G. 1.1.7 P1 落地状态（2026-11-11，如实挂账）

> 本附录区分「实测 / 单测 / 代码审查 / 未做」，不把设计当已实现，也不把单测当实机。

### G.1 已落地（代码 + 构建/单测实测）

| 项 | 文件 | 验证 |
|---|---|---|
| 版本 1.1.7 | `src/version.h:10` | 编译期 `RLPLAYER_VERSION_STR` 注入实测（configure 打印 1.1.7） |
| CMake 双 UI 开关 `RLPLAYER_UI=web\|native` | `CMakeLists.txt`（新增 option、`rlnative_bridge` 库、native 分支、桥层单测注册） | 两种 configure 均 exit 0 |
| 纯 C++ 核心桥（单真相源、去重、非法回落、revision） | `src/native/core_bridge.{h,cpp}` | `test_native_bridge` 11/11 PASS（同值去重 / 9、-1 回落 / 进度不递增） |
| 纯 AppKit 界面（ObjC++/ARC） | `tools/native/native_host.mm` | `rlplayer_mac`（native）编译 0 error；无 WKWebView 主内容 |
| 宿主入口切换 | `tools/mac_host.mm`（`RLPLAYER_UI_NATIVE` 时 `rlnative_start()`） | web 构建下该文件行为不变（`mac_transport` 契约测试通过） |
| 主窗口：`NSWindow` + `NSSplitViewController`（侧栏/主区/右栏）+ 常驻播放条 | `tools/native/native_host.mm` | 编译通过；**窗口真机外观未验证**（见 G.3） |
| 菜单与命令表（App/编辑/播放/显示；`handleCmd:` 单入口） | 同上 | 编译通过；菜单项点击行为未实机验证 |
| 播放状态 10 Hz 轮询、四态模式按钮/菜单勾选项、三套主题、专辑网格、队列视图、搜索框、音量/进度滑块 | 同上 | 编译通过；桥层读接口单测覆盖 |
| `ffmpeg_matrix` 在干净构建目录假红的修复（指向源树 `build-mac/ffmpeg-lite`，判据强度不变） | `CMakeLists.txt` | web/native 两条均 PASS |

### G.2 门禁实测（本机，2026-11-11）

| 构建 | configure | build | ctest |
|---|---|---|---|
| `RLPLAYER_UI=web`（默认，发布行为不变） | exit 0 | 0 error | **152/152 PASS**（`ctest -j1`，233 s） |
| `RLPLAYER_UI=native` | exit 0 | 0 error | **153/153 PASS**（含 `native_bridge`；`ffmpeg_matrix` 修环境后全绿，279 s） |

> 说明：native 首轮 ctest 曾因 `ffmpeg_matrix` 在 `build-native/` 找不到 `ffmpeg-lite` 而 1 红（152/153）。已定位为**构建目录差异导致的假红**，非 UI 回归；按仓库既有惯例补 `RTA_FFMPEG_LITE_DIR` 后两构建全绿。判据本身未改弱。

### G.3 未做 / 未验证（不谎报）

1. **实机未验证**：native App 双击启动、窗口外观、按钮点击、VoiceOver、媒体键、真实播放（用户执行；清单 §11 R-01..R-20）。
2. **P2 未做**：`ShuffleOrder`/`PlaybackHistory`、`PlaybackRequest/PlayOptions` 门面、upNext 插播队列、结构化 `PlaybackError/RecoveryAction`、连续错误计数、队列编辑规则、把 `check_playmode_behavior.py` 移植进 ctest。
3. **P3 未做**：设置 10 页签、独立更新窗口（状态机/门槛/取消/重启/忽略/稍后/埋点）、Now Playing 整页、分析/AI 整理、流媒体/文件夹/收藏/歌单页面、`MPNowPlayingInfoCenter`/`MPRemoteCommandCenter`、语言切换重建菜单、i18n 生成器。
4. **P4 未做**：`classic` 密度变体、频谱、默认切 native、发布包移除 web。
5. **构建软件**：为 Swift 方案装过 Ninja（`~/tools/bin/ninja`，官方 1.12.1 universal）；最终按用户决定走纯 ObjC++/AppKit，用不上，如实保留未删。
6. **未联网 / 未出声**：桥单测用 `rlapp::dispatch()` 进程内打现有端点，隔离 `/tmp` 状态目录、`backend=null`、未打开声音设备。

### G.4 下一步（继续直接做，不再抛决策项）

按 §10 的 P2 阶段表推进：先在核心侧补 `ShuffleOrder`/`PlaybackHistory` 与「同值幂等 + 显式 mode 优先级」ctest（红→绿），再做 upNext 插播队列与结构化错误恢复，最后收敛 `PlaybackRequest` 门面；每步两构建 + 全量 ctest。P3 起做设置页与更新窗口。

---

## 附录 H. 全量原生 UI 落地（2026-11-11，第二轮）

按用户「直接完成整个 UI 用 AppKit，尽可能学习 QQ 音乐 mac 版的界面设计」，在附录 G 的 P1 骨架上
把整个界面做成可用的原生 AppKit 应用。设计仍只取机制与信息架构，不复制 QQ 音乐素材/文案/图标。

### H.1 信息架构（对照 QQ 音乐 macOS）

| 区域 | 实现 |
|---|---|
| 左侧全高侧栏 | 品牌区（红绿灯让位）+ 资料库（专辑/艺术家/曲目/最近播放/我的最爱/文件夹/流媒体）+ 播放列表（播放队列/具名歌单）+ 音频引擎（设置/检查更新），选中态圆角主色底 |
| 顶部栏 | 返回、搜索框（实时搜索）、重新扫描、队列开关、设置、正在播放 |
| 主内容区 | 大标题 + 副标题 + 操作按钮；专辑网格（真实封面、圆角卡片）/ 艺术家网格 / 曲目表 / 最近 / 最爱 / 文件夹统计 / 流媒体配置 / 队列页 / 搜索页 / 专辑详情页 |
| 右侧队列栏 | 当前播放计数、清空、保存为歌单、可双击定位的队列列表（当前曲目高亮） |
| 底部播放条 | 封面 + 曲名/艺术家 + 收藏、主色圆形播放键、上/下一首、模式、进度（可拖动）、时间、音量、队列/正在播放 |
| 正在播放（沉浸页） | 封面作为弱化背景 + 大封面 + 标题/艺术家 + 滚动歌词（按进度高亮）+ 传输控制 |
| 菜单 | App/编辑/播放/显示/窗口，快捷键与原生一致；播放模式 4 项带勾选态 |
| 系统集成 | MPRemoteCommandCenter（播放/暂停/上一首/下一首/进度跳转）+ MPNowPlayingInfoCenter |
| 设置窗口 | 6 个页签：外观（主题色默认浅色）、输出、升频 PCM、DSD、资料库与 EQ、更新与关于；改动即时合并写 `/api/settings`，不覆盖其它键 |
| 更新窗口 | 复用 `rta::update::begin_check/begin_install`，显示检查/下载/校验/安装进度与结果；不做静默升级 |
| 主题 | 浅色（默认）/ 深色 / 浅蓝；**只在设置里切换**（顶栏/菜单不再有快速切换），写入 `rlplayer-settings.conf` |

### H.2 与 web UI 的关系

- 功能不删除：`RLPLAYER_UI=web` 仍是完整旧界面，`RLPLAYER_UI=native` 时宿主不创建 WKWebView。
- web 侧按同一指令调整：默认主题改为 light、去掉顶栏三个色点、设置页仍保留主题下拉；
  `i18n_table_check` 仍为 1753 对，全量 web ctest 152/152 通过。
- 原生设置只覆盖常用键；EQ 曲线编辑、AI 整理、房间校准、流媒体登录浏览等仍走网页端（原生页如实说明），
  不把「未移植」说成「已支持」。

### H.3 本轮实测

| 项 | 结果 |
|---|---|
| `RLPLAYER_UI=native` 构建 | 0 error |
| `RLPLAYER_UI=web` 构建 | 0 error |
| 桥层单测 `test_native_bridge` | 23/23 PASS（去重/revision/回落/主题/合并写 + PEQ/房间布局/数据源/健康分析只读判据） |
| web 全量 ctest | **152/152 PASS** |
| native 全量 ctest | 见执行记录（含 `native_bridge`） |
| 原生启动自检 `RLPLAYER_NATIVE_SELFTEST=1` | `pass 8/8`：10 个页面 + 15 个设置分区逐一构建 0 异常，`webviews=0`，235 张专辑 |
| 实机点击/听感/VoiceOver | **未做**（归用户；方案 §11 清单） |

> 自检只证明「界面与分区都能真实构建、没有 WKWebView」，不证明每个按钮的交互与视觉细节；后者必须实机。
> 1.1.6 逐项移植状态见 `docs/ui-redo/NATIVE_PARITY_1_1_6.md`。
