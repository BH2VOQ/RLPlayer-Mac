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
      ├─ RLPAppDelegate / RLPMainWindowController       窗口、菜单、媒体键、生命周期
      ├─ RLPSidebarViewController                       10 入口导航
      ├─ 内容视图（专辑/艺术家/曲目/文件夹/详情/…）
      ├─ RLPPlaybackBarView                             底部播放条（轮询 /api/status + /api/playmode）
      ├─ RLPUpdateWindowController                      更新窗口（一窗两视图 + 5 出口）
      └─ RLPCoreClient (ObjC++ 桥) ──► rlapp::dispatch(同一进程) ──► C++ 核心
                                       └─ 只做 JSON↔Foundation、线程、超时

- 桥的线程契约：dispatch 允许任意线程并发；UI 回调统一回主线程；阻塞调用不在主线程。
- 不监听端口、不起子进程：与 web 版走同一条进程内路径（只是渲染层不同）。

## 2. 迁移清单（parity matrix）

### 2.1 已完成

| 模块 | 原生状态 | 说明 |
|---|---|---|
| 窗口/侧栏/播放条 | 已实现 | 10 导航项、品牌区、底部播放条 |
| 专辑网格 | 已实现 | 真实数据 + 异步封面 + 双击播放整张 |
| 艺术家 / 曲目 / 文件夹 | 已实现 | 艺术家网格（168x74）、曲目搜索（防抖 0.35 s + 右键菜单）、文件夹浏览 |
| 专辑详情 / 艺术家详情 | 已实现 | 封面 + 曲目表 + 播放全部 / 随机播放；详情压栈、返回回原列表页 |
| 队列 / 最近 / 最爱 | 已实现 | 表格页 + 双击播放 + 右键菜单 |
| 流媒体 | 已实现 | 服务器下拉 + 面包屑 + 目录浏览 + 双击播放 |
| 快速开始 | 已实现 | 三张能力卡 + 官方推荐预设（真实端点 /api/preset/apply?profile=）+ 四个快捷入口 |
| 设置（10 页签） | 已实现 | 页签与 web 版一一对应；外观（light/dark）按用户要求在设置内改 |
| 更新窗口 | 已实现 | 一窗两视图 + 5 出口（立即更新/稍后/忽略此版本/手动下载/取消下载），忽略落盘 |
| 正在播放 | 部分 | 封面/歌词/收藏/音质体检已接真实端点；AI 分析与资料层未迁移 |
| 播放模式 | 已实现 | 随机/循环双按钮，单一真相源 /api/playmode?mode=（0/1/2/3） |
| 菜单/媒体键 | 已实现 | App/编辑/播放菜单 + Cmd-, + MPRemoteCommandCenter（播放/暂停/上下曲/拖进度） |
| 诊断导出 | 已实现 | /api/diagzip 原始字节 -> NSSavePanel（不假装成功） |
| i18n | 已实现 | tools/gen_native_i18n.py 由 docs/i18n/*.tsv 生成，--check 进门禁 |
| 主题 | 已实现 | **只有 dark / light**，仅在设置页切换（顶栏无显式按钮） |

### 2.2 未完成（如实挂账）

| 模块 | 状态 | 阻塞原因 / 下一步 |
|---|---|---|
| 设置 · 均衡页签 | 占位 | 20 段 PEQ + OPRA 图形化编辑需要完整控件组；当前如实提示去 web 版 |
| 设置 · 校准页签 | 占位 | 房间测量向导 / IR WAV 是多步流程，未迁移 |
| 设置 · 流媒体增删改 | 只读 | 只显示已存服务器；新增/编辑（含密码）仍需 web 版 |
| 反馈窗口 | 未迁移 | 后端协议已在 feedback_api.h（纯逻辑可测），缺原生表单 UI |
| 单曲页 AI 分析/资料层 | 未迁移 | 依赖 /api/anl、/api/entity/*，界面形态未定 |
| 锁屏「正在播放」信息 | 骨架 | MPNowPlayingInfoCenter 已接但未上报曲名/封面/进度 |
| 原生默认 | 未切换 | parity 未全绿前 rlplayer_mac（web）仍是默认 |

## 3. 判据

- native_ui_selftest：28 条断言。除视图树契约（10 导航项、窗口尺寸、webviews=0）外，
  **每个迁移页面各一条「可离线构建」**（有新页面没 import 就编不过，这本身也是判据），
  外加更新窗口 >=5 出口按钮、播放条 >=2 个模式按钮。
  > 这条断言在 2026-11-11 真抓到一个崩溃：RLPArtistsViewController / RLPQueueViewController
  > 走 initWithNibName:bundle: 绕过了 initWithTitle:，_pageTitle 为 nil ⟹ labelWithString:nil
  > 抛异常。修法是基类兜底 + RLPLabel 归零 nil，不是给某个页面打补丁。
- native_ui_smoke：隔离 state/library 下启动核心，/api/ping、/api/lib/albums、/api/status 均 ok。
- 随机播放：shuffle_order（排列合法性、CSPRNG 可注入、重洗规避、均匀性）。
- 设置持久化：settings_persist（回显 / 读回 / conf 原文三连）。

## 4. 更新窗口（借鉴 QQ 音乐结构，不照搬资源）

- 一个 NSWindow，两种内容视图：**信息态**（版本/说明）与**下载态**（进度/说明）。
- 5 个出口：立即更新 / 稍后 / 忽略此版本 / 手动下载 / 取消下载（完成后变重启）。
- 忽略落盘（NSUserDefaults 键 RLPIgnoredUpdateVersion），同一版本不再提示。
- 版本说明按**纯文本等宽**显示：清单 notes 是发布者写的外部文本，不按富文本解释（安全边界）。
- 复用 tools/mac_update.mm 的检查/下载/校验/安装链；UI 只做状态机与出口，不自己拼 URL。

## 5. 借鉴 QQ 音乐的部分（只借机制，不借资源）

| 机制 | 落地 |
|---|---|
| 更新弹窗「一窗两视图五出口」 | RLPUpdateWindowController（见 §4） |
| 随机播放=整表 Fisher-Yates + 游标 + 绕回重洗 | src/net/shuffle_order.h + rtaweb.cpp 的 queue_shuffle_locked(avoid)（CSPRNG 播种） |
| 单一播放入口 play(list, index, mode, options) | 队列 mode 为唯一真相源（0/1/2/3），/api/repeat 与 /api/shuffle 降级为派生写入口 |
| 切模式保留当前曲 | 随机进出不打断当前曲（avoid 参数规避当前索引重排） |

## 6. 分阶段

1. **P1**：外壳 + 桥 + 专辑网格 + 播放条 + 随机播放核心改进；selftest/smoke 门禁。完成。
2. **P2**：艺术家/曲目/文件夹 + 队列 + 播放模式按钮 + 菜单/媒体键。完成。
3. **P3**：Now Playing + 设置 10 页签 + 更新窗口 + 诊断导出。部分（均衡/校准/反馈窗口未迁移）。
4. **P4**：流媒体/快速开始 + i18n/主题 + parity 全量验收 -> 原生默认。页面已通，parity 待收口。
