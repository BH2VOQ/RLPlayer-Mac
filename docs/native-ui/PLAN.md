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

端点覆盖（可机械核对，口径 = web 版 ui_script.h 里出现的 /api 路径）：
**77 / 98**（本轮起点 40/98）。剩余 21 项见 §2.3。

### 2.1 已完成

| 模块 | 说明 |
|---|---|
| 窗口/侧栏/播放条 | 11 导航项（web 10 项 + 歌单入口）、品牌区、底部播放条 |
| 专辑网格 / 艺术家 / 曲目 / 文件夹 | 真实数据 + 异步封面；曲目防抖搜索 + 右键菜单 |
| 专辑详情 | 封面 + 曲目表 + 播放全部 / 随机 / 整张入队 / 人工换封面 |
| 艺术家详情 | 真头像（/api/artist/image，失败回落首字母）+ 专辑网格 |
| 播放队列 | 右键移除、拖动排序、按标题/艺术家排序、恢复默认、存为歌单、清空 |
| 歌单 | 列表 + 曲目表 + 新建/重命名/删除/存当前队列；CUE 分轨 cs/ce 不丢 |
| 最近 / 最爱 | 表格 + 双击播放 + 右键菜单 |
| 流媒体 | 服务器下拉 + 面包屑 + 目录浏览 + 双击播放 + 测试连接 |
| 快速开始 | 三张能力卡 + 官方推荐预设（?profile=）+ 四个快捷入口 |
| 设置 · 输出/PCM/SDM/高级/元数据 | 设备/采样率/滤波/独占/音量/主题/语言/更新/流式解码/元数据开关 |
| 设置 · 均衡 | 20 段可编辑 PEQ + 后端算出的频响曲线 + 260ms 节流 + 预设增删改 + OPRA 耳机曲线 |
| 设置 · 校准 | 房间测量向导（plan → 确认 → measure）+ 取消 + IR WAV + GPU 卷积 |
| 设置 · 输入 | CoreAudio 采集：后端/设备/模式/时长/输出/直通监听（二次确认） |
| 设置 · 流媒体 | 服务器列表 + 投放面板（AirPlay / UPnP，1s 轮询 cast/state） |
| 设置 · 诊断 | 诊断包导出 + 反馈窗口入口 |
| 设置 · 元数据 | 四个开关 + AI 模型端点（密钥留空不改、存完即清） |
| 设置 · 高级（续） | 联网补齐封面 + 进度、标签写回（预览 → 执行） |
| 正在播放 | 封面 + 歌词 + 收藏 + 19 项音质体检 + AI 资料层（知识卡 + 简介，pending 轮询） |
| 更新窗口 | 一窗两视图 + 5 出口；忽略落盘 |
| 播放模式 | 随机/循环双按钮 + 停止键；单一真相源 /api/playmode |
| 菜单 / 媒体键 | App/编辑/播放/帮助（反馈）+ Cmd-, + MPRemoteCommandCenter |
| 锁屏正在播放 | MPNowPlayingInfoCenter 上报标题/时长/进度/播放态 |
| 反馈窗口 | 正文 + 附诊断包 → 后台；复用 feedback_api.h（脱敏/幂等/成功只看 body.ok） |
| i18n / 主题 | 双生成器同源；只有 dark / light，仅在设置内切换 |

### 2.2 未完成（如实挂账）

| 项 | 状态 | 说明 |
|---|---|---|
| 设置 · 流媒体增删改 | 只读 | 新增/编辑服务器（含密码）仍需 web 版 |
| 原生默认 | 未切换 | parity 未全绿前 rlplayer_mac（web）仍是默认 |

### 2.3 未接的 21 个端点（逐条说明，不含糊）

| 端点 | 为什么没接 |
|---|---|
| /api/lib/stats、/api/rates、/api/gpu、/api/net、/api/signal | 只读诊断/能力查询，原生页当前不展示这些面板 |
| /api/providers、/api/llm/models | 数据源注册表 / 模型列表下拉，原生用固定项 + 手填 |
| /api/lib/rmdir、/api/lib/rmdirinfo | 目录删除（破坏性），未迁移 |
| /api/queue/set | 整体替换队列（拖动排序已用 qmove 覆盖主要场景） |
| /api/compare、/api/entity/versions | 版本对比 / Discogs 版本推荐，未迁移 |
| /api/anl/cancel | 取消后台分析（原生未做自动分析触发） |
| /api/diag/upload、/api/upload | 旧诊断上传通道；原生反馈走 feedback_api 直连后台 |
| /api/src/cover | 流媒体封面（原生流媒体页本轮不做封面） |
| /api/selftest/report、/api/ui/events | web 专用自检回传 / SSE 事件流，原生不需要 |
| /api/writeback/status | 写回进度轮询（原生用预览查看剩余） |
| /api/v1、/api/v1/feedback/macos | 后台路径前缀，原生由 feedback_api.h 常量直接持有 |
## 2.4 本轮（用户实测反馈后）修掉的真故障

用户反馈：「专辑页进不去」「大部分功能失灵」「默认要 light，切 light 主页还是黑的」「布局不够美观」。
这些都不是"没做完"，是**做错了**。逐条根因：

| 现象 | 根因 | 修法 |
|---|---|---|
| 专辑页点不进去 | 双击直接调 onPlayAlbum，**从不发打开详情的通知** | 单击进详情（web 同语义），播放/入队移到右键 |
| 大部分功能"失灵" | 8 个列表页都只接 doubleAction，而 web 版是**单击**触发 | 全部补 action=单击，双击保留兼容 |
| 切 light 主页还是黑的 | ① 默认 dark ② 专辑页**没有 applyTheme** ③ 主窗口只刷当前页、缓存页不刷 | 默认 light + 无条件同步 NSApp.appearance + 卡片/页面 applyTheme + 刷所有缓存页 |
| 侧栏永远没有高亮 | NSTableView 在非 key window 下 selectRowIndexes **静默失败**（实测调用后 selectedRow 仍 -1） | 选中态改为业务自持，不托付控件焦点行为 |
| 右键菜单有时不生效 | 依赖 selectedRow（同样可能 -1） | 优先 clickedRow |
| 强调色不对 | 原生用蓝色，web 是 Apple Music 珊瑚红 #fa2d48 | 主题令牌逐值对照 web 的 :root / light 重写 |
| 观感偏硬 | 选中底铺满整行、无悬停反馈 | 内缩圆角胶囊 + 悬停底色 + 卡片强调边与阴影 |

**为什么旧门禁没抓到**：旧 selftest 只问"页面能不能构造出来"。
上面每一条都是"构造成功但行为错"，它一条都抓不到。
所以新增 native_ui_functional（见 §3），判据改成问"点了之后发生了什么""渲染出来是什么颜色"。

## 3. 判据

- native_ui_selftest：28 条断言。除视图树契约（10 导航项、窗口尺寸、webviews=0）外，
  **每个迁移页面各一条「可离线构建」**（有新页面没 import 就编不过，这本身也是判据），
  外加更新窗口 >=5 出口按钮、播放条 >=2 个模式按钮。
  > 这条断言在 2026-11-11 真抓到一个崩溃：RLPArtistsViewController / RLPQueueViewController
  > 走 initWithNibName:bundle: 绕过了 initWithTitle:，_pageTitle 为 nil ⟹ labelWithString:nil
  > 抛异常。修法是基类兜底 + RLPLabel 归零 nil，不是给某个页面打补丁。
- native_ui_smoke：隔离 state/library 下启动核心，/api/ping、/api/lib/albums、/api/status 均 ok。
- **native_ui_functional（新）**：38 条断言。造隔离夹具曲库（3 专辑 6 曲）→ 真的发通知/切导航 →
  断言 currentContent 变成期望类型、页面有实际内容、返回能回到原页；
  并把每页离屏渲染成 PNG，用**像素**判定明暗与强调色是否真的画出来。
  产物在 build-mac/native-audit-shots/，可人眼复核布局。
  运行：`./build-mac/rlplayer_native --audit <目录>`（不弹窗、不出声）。
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