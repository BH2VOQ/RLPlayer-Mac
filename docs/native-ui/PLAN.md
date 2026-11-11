# 纯 AppKit 客户端（1.1.7.1 起）

> 目标：把 macOS 客户端的主内容区从 WKWebView 换成**纯 AppKit**（NSView/NSViewController），
> **原有功能不删不减**。web 版在 parity 全绿前保持默认/回退；原生版并行构建、逐阶段验收。

## 0. 硬约束

- 功能对等是切换默认的前置条件；任何未迁移的页面在原生版里必须**如实标注**，不许假装已实现。
- 业务真相源留在 C++ 核心（rlapp_core 的 /api dispatch）：曲库、播放、队列、设置、更新、诊断
  都不在 UI 里复制第二份。
- 界面验收唯一通道 = DSH 侧边栏（web 版）/ 用户实机（原生窗口）；禁止无头浏览器与自动化键鼠。
- 门禁：build 0 error + 串行 ctest 全绿 + native_ui_selftest/smoke 全绿 + web 版回归不红。

## 1. 架构

    rlplayer_native (AppKit, ObjC++ .mm)
      ├─ RLPAppDelegate / RLPMainWindowController       窗口、菜单、生命周期
      ├─ RLPSidebarViewController                       10 入口导航
      ├─ 内容视图（专辑/艺术家/…，逐步迁移）
      ├─ RLPPlaybackBarView                             底部播放条（轮询 /api/status）
      └─ RLPCoreClient (ObjC++ 桥) ──► rlapp::dispatch(同一进程) ──► C++ 核心
                                       └─ 只做 JSON↔Foundation、线程、超时

- 桥的线程契约：dispatch 可任意线程并发；UI 回调统一回主线程；阻塞调用不在主线程。
- 不监听端口、不起子进程：与 web 版走同一条进程内路径（只是渲染层不同）。

## 2. 迁移清单（parity matrix）

| 模块 | 原生状态 | 说明 |
|---|---|---|
| 窗口/侧栏/播放条 | ✅ 已实现 | 10 导航项、品牌区、底部播放条 |
| 专辑网格 | ✅ 已实现 | 真实数据 + 异步封面 + 双击播放整张 |
| 播放条 | ✅ 已实现 | 播放/暂停、上/下一首、进度、音量、状态轮询 |
| 艺术家 / 曲目 / 文件夹 | ⏳ 待迁移 | 当前显示占位说明 |
| 流媒体 / 队列 / 最近 / 最爱 / 快速开始 | ⏳ 待迁移 | 同上 |
| Now Playing 单曲页（歌词/分析/AI） | ⏳ 待迁移 | 依赖 /api/lyrics、/api/anl、/api/entity/* |
| 设置（10 页签） | ⏳ 待迁移 | 依赖 /api/settings、/api/devices、/api/rates… |
| 更新窗口 | ⏳ 待迁移 | 目标：一窗两视图 + 5 出口（见 §4） |
| 诊断包 / 反馈 | ⏳ 待迁移 | 复用现有宿主实现（/api/diagzip、feedback_api） |
| 菜单/快捷键/媒体键 | ⏳ 部分 | 已有 App/编辑/播放菜单；媒体键待接 MPRemoteCommandCenter |
| i18n | ⏳ 待迁移 | 原生文案需与 docs/i18n 同源生成 |
| 主题 | ⏳ 只做暗色 | 亮色/蓝色按同一 token 扩展 |

## 3. 判据

- native_ui_selftest：视图树契约（10 导航项、窗口尺寸、webviews=0）。
- native_ui_smoke：隔离 state/library 下启动核心，/api/ping、/api/lib/albums、/api/status 均 ok。
- 每个迁移页面新增一个 selftest 断言（视图存在 + 关键控件存在 + 不依赖核心时安全空转）。
- 随机播放：shuffle_order（排列合法性、CSPRNG 可注入、重洗规避、均匀性）。

## 4. 更新窗口（借鉴 QQ 音乐结构，不照搬资源）

- 一个 NSWindow，两种内容视图：**信息态**（版本/说明/下载大小）与**下载态**（进度/速度/剩余）。
- 5 个出口：立即更新 / 稍后 / 忽略此版本 / 手动下载 / 取消下载（完成后变重启）。
- 忽略与稍后都要落盘（同一版本不再打扰）；错误态必须给人话 + 下一步（重试/手动下载）。
- 复用 tools/mac_update.mm 的检查/下载/校验/安装链；UI 只做状态机与出口，不自己拼 URL。

## 5. 分阶段

1. **P1（本轮）**：外壳 + 桥 + 专辑网格 + 播放条 + 随机播放核心改进；selftest/smoke 门禁。
2. **P2**：艺术家/曲目/文件夹 + 队列面板 + 播放模式按钮 + 菜单/媒体键。
3. **P3**：Now Playing（歌词/分析/AI）+ 设置 10 页签 + 更新窗口 + 诊断/反馈。
4. **P4**：流媒体/投放/快速开始 + i18n/主题 + parity 全量验收 → 原生默认。
