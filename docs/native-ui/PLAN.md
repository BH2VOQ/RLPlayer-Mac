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
**本轮起点 40/98 → 1.1.7.1 达 77/98**；2026-11-12 又补齐 /api/src/config（写）、
/api/src/cover、/api/providers、/api/writeback/status、/api/src/ping（见 §2.3 逐条状态）。
§2.3 是"剩余项 + 已补项"的合并清单，未迁移项如实标注，不假装全绿。

### 2.1 已完成

| 模块 | 说明 |
|---|---|
| 窗口/侧栏/播放条 | 两模式各 11 导航项（首页不同：聆听室/工作台；**两模式都有设置**，2026-11-11 用户要求）、品牌区、底部播放条 |
| 专辑网格 / 艺术家 / 曲目 / 文件夹 | 真实数据 + 异步封面；曲目防抖搜索 + 右键菜单 |
| 专辑详情 | 封面 + 曲目表 + 播放全部 / 随机 / 整张入队 / 人工换封面 |
| 艺术家详情 | 真头像（/api/artist/image，失败回落首字母）+ 专辑网格 |
| 播放队列 | 右键移除、拖动排序、按标题/艺术家排序、恢复默认、存为歌单、清空 |
| 歌单 | 列表 + 曲目表 + 新建/重命名/删除/存当前队列；CUE 分轨 cs/ce 不丢 |
| 最近 / 最爱 | 表格 + 双击播放 + 右键菜单 |
| 流媒体 | 服务器下拉 + 面包屑 + 封面网格/列表两档（remoteview 偏好）+ 单击进入/播放 + 测试连接 |
| 快速开始 | 三张能力卡 + 官方推荐预设（?profile=）+ 四个快捷入口 |
| 设置 · 输出/PCM/SDM/高级/元数据 | 设备/采样率/滤波/独占/音量/主题/语言/更新/流式解码/元数据开关 |
| 设置 · 均衡 | 20 段可编辑 PEQ + 后端算出的频响曲线 + 260ms 节流 + 预设增删改 + OPRA 耳机曲线 |
| 设置 · 校准 | 房间测量向导（plan → 确认 → measure）+ 取消 + IR WAV + GPU 卷积 |
| 设置 · 输入 | CoreAudio 采集：后端/设备/模式/时长/输出/直通监听（二次确认） |
| 设置 · 流媒体 | 服务器增删改/启用/测试（RLPServersView，密码留空=不改）+ 投放面板（AirPlay / UPnP，1s 轮询 cast/state） |
| 设置 · 诊断 | 诊断包导出 + 反馈窗口入口 |
| 设置 · 元数据 | 四个开关 + 数据源逐源开关/优先级排序/恢复默认（RLPMetaSourcesView）+ AI 模型端点（模型下拉 /api/llm/models 选中即保存、密钥留空不改、存完即清） |
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
| 原生默认 | 未切换 | parity 未全绿前 rlplayer_mac（web）仍是默认 |

> 2026-11-12：设置·流媒体增删改已补齐（RLPServersView：add/update(keepPass)/active/remove/测试，
> 密码红线与 web 同口径），判据 servers_view 真核心写后读回。原"只读"挂账关闭。

### 2.3 端点逐条状态（未接的如实标注，不含糊）

> 2026-11-12 循环优化后：web ui_script.h 里出现的 /api 端点，绝大多数已接。
> 下表逐条列出「已接 / 未接及原因」；未接的只剩破坏性目录删除、古典版本推荐、
> 旧诊断上传通道、两个只读能力查询面板，均如实标注，不假装全绿。

| 端点 | 为什么没接 |
|---|---|
| /api/lib/stats | 已接（2026-11-12：设置·高级页本地音乐库统计卡，曲目/专辑/扫描线程/上次扫描/扫描进度轮询） |
| /api/rates、/api/gpu | 已接（rates → 工作台采样率下拉；gpu → 设置·高级 GPU 后端下拉 + metal/metalUsable 真实状态，2026-11-12）；/api/net 只读网络信息，原生单进程不走端口，该面板无意义 |
| /api/signal | 已接（2026-11-12：RLPSignalChain 纯函数 + 工作台「本次播放路径」弹层，真实播放路径逐节点 + bit-perfect 结论，对齐 web showChain） |
| /api/providers、/api/llm/models | 已接（2026-11-12：providers → RLPMetaSourcesView 逐源开关+优先级；llm/models → 设置·元数据模型下拉，拉不到降级手填） |
| /api/lib/rmdir、/api/lib/rmdirinfo | 目录删除（破坏性），未迁移 |
| /api/queue/set | 已接（2026-11-12：RLPPlayWholeListFrom 整列顺序播放，我的最爱页双击从该曲起播整个收藏列表，单曲循环自动切回列表循环） |
| /api/compare、/api/entity/versions | 已接（compare → RLPShowCompareSheet / 单曲页版本对比；entity/versions → 古典作品页 RLPWorksViewController，单曲页「古典作品版本」入口，2026-11-12） |
| /api/anl/cancel | 已接（单曲页 viewDidDisappear 取消在跑的分析，与 web anlCancelServer 同语义） |
| /api/diag/upload、/api/upload | 旧诊断上传通道；原生反馈走 feedback_api 直连后台 |
| /api/src/cover | 已接（2026-11-12：流媒体网格/列表封面卡片，coverForSourceId 共享缓存） |
| /api/selftest/report、/api/ui/events | web 专用自检回传 / SSE 事件流，原生不需要 |
| /api/writeback/status | 已接（2026-11-12：wbPoll 800ms 轮询 + wbSyncBusy 进页恢复忙态） |
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

- native_ui_selftest：除视图树契约（导航项数随模式、窗口尺寸、webviews=0）外，
  **每个迁移页面各一条「可离线构建」**（有新页面没 import 就编不过，这本身也是判据），
  外加更新窗口 >=5 出口按钮、播放条 >=2 个模式按钮。
  **2026-11-11 用户要求两模式都有设置页**：聆听/专业侧栏都必须能 selectKey:settings；
  设置页签随模式 —— 专业 7 页（输出/PCM/SDM/均衡在工作台）、聆听 11 页（四页挂回设置，
  功能不因模式而不可达）。旧"聆听无设置"判据已按新要求翻转（先红后绿）。
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
## 7. 2026-11-12 地基轮：parity 收口到 0 缺口

本轮的判据与上一轮不同：**不再靠人列清单**，而是机器从两侧源码抽事实。

### 7.1 双模式已移除

「聆听模式 / 专业模式」是 web 没有的发明，会让「web 有的我是否都有」无法机械验证。
本轮把它整层拆掉（枚举 / 顶栏切换 / 侧栏分叉 / 设置页签随模式 / 工作台首页），
留档在 `dualmode-baseline-1.1.7.5`（tag）与 `archive/dualmode-1.1.7.5`（分支）。
双模式留到 parity 全绿之后，作为**薄表现层**回归（不改变页面与控件集合）。

侧栏与设置页签现在是 web 的 1:1 副本：

| 结构 | web（只读参考） | 原生 |
|---|---|---|
| 左导航 | `.nav` 11 项 + 3 个 `.sec` | 11 项 + 3 个分组，key 用 web 的 data-v |
| 设置页签 | `data-g` 10 页 | 10 页，顺序一致（adv/in/out/pcm/sdm/eq/cal/meta/stream/diag） |

### 7.2 对照表（本轮的交付物）

| 文件 | 谁维护 | 作用 |
|---|---|---|
| `tools/native_ui/parity_scan.py` | 人写一次，机器执行 | 从源码抽两侧事实，生成 parity.tsv；`--check` 是门禁 |
| `docs/native-ui/parity.tsv` | **生成物，勿手改** | 317 行：view / tab / ctrl / api 各 done/missing/na |
| `docs/native-ui/parity_map.tsv` | 人 | 命名消歧（web_id -> native_identifier），逐条带证据 |
| `docs/native-ui/parity_na.tsv` | 人 | 每行一个具体理由，**脚本会复核** |

当前结果：**done=301 / missing=0 / na=16**。

### 7.3 na 不是免罪符

`na` 的语义是"web 有这个字符串，但原生按设计不需要"，它同样是**一种断言**。
所以扫描器对每条 na 做源码复核：把 web 前端（ui_script.h + ui_page.h，剥注释）
里该路径的**精确词元**出现次数数出来，>0 就判定 na 不成立、直接失败。

这条机制本轮抓到过我自己的 2 条错判（`/api/selftest/report`、`/api/ui/events`：
web 确实调用了），已改为真实现而不是 na。另有 1 条子串误报（`/api/pl` 撞 `/api/play`），
改用精确词元后消失 —— 说明"能复核"这件事本身也要写对。

### 7.4 本轮补的缺口（按任务书顺序）

1. **视图**：11 个导航视图 + 3 个详情视图（album / artist / works）都有 `page.<key>` 锚点。
2. **设置页签与键位**：10 页 181 个控件，identifier 就是 web 的 `sp_*`。
   任务书点名的 19 个已知缺口（opraproduct / oprapreset / scanthreads / upnpdev / dsdkind /
   dsdconv / sdmfilt / sdmfiltnx / modcut / moddith / ramp / transition / trim / uistyle /
   naahost / inbuf / inseconds / inoffset / inout）全部落地，
   并有真核心判据 `native_settings_keys` 逐个写→读回。
3. **投放面板**：`RLPCastView` 重写为 web 的 sp_cast_* 全套
   （设备下拉 / 重新发现 / 推送 / 停止 / 升频三件套 / 11 项实时状态 + 3 个容器）。
4. **端点**：/api/net、/api/cast/devices、/api/upnp、/api/naa/discover、/api/preset/caps、
   /api/track/health、/api/upload、/api/shuffle、/api/repeat、/api/rescan 等接入。
5. **页面观感**：三处真 bug 由运行时判据抓出（见 7.5）。

### 7.5 判据抓到的真故障（不是"没做完"，是"做错了"）

| 现象 | 根因 | 判据 |
|---|---|---|
| 输入页缺 `sp_inbuf` / `sp_inout` | 页签分派到旧的 `fillInputReal`（只嵌 RLPInputView），新写的 `fillInput` 从未被调用 | `--audit` 的运行时 identifier 探针（静态表全绿也能抓到） |
| 写回按钮 / GPU 下拉判据红 | identifier 改成 web 名后，既有测试按旧名找控件 | servers_view S8c / llm_endpoint L5a 先红后绿 |
| 每源开关找不到 | identifier 同时承担"动作分派"与"parity 取证"两个职责 | S9e 按 id 定位，动作改走 `sourceIdByControl` 映射 |

**教训**：静态表（源码里有没有赋值）与运行时探针（跑起来挂没挂上）缺一不可。
本轮 181 个控件的静态表全绿时，输入页仍然是坏的 —— 只有运行时那条抓到了。

### 7.6 扫描器自身修掉的两个缺陷

1. **块注释吞换行**：剥注释后行号与真实文件错位，表里的 `file:line` 证据指不到东西。
   修法：块注释里的换行照抄进输出。
2. **`num({ id: 'sp_x' })` 形态漏抓**：web 有 10 个数值控件用的是对象字面量调用，
   只认 `num('sp_x')` 会漏掉它们（atten/buffer/inbuf/inseconds/modcut/moddith/ramp/
   scanthreads/taps/transition）——这批会永远显示成 missing，是**假缺口**。

### 7.7 门禁

```
native_ui_selftest   视图树契约（含 web 的 11 导航项 / 10 页签 / 每页签可切换）
native_ui_smoke      ObjC 桥 -> C++ 核心真链路
native_ui_functional --audit：77 项（含运行时 identifier 探针 + 像素级主题判定）
native_ui_parity     parity_scan.py --check（missing=0 且 na 全部可复核）
native_settings_keys 设置键逐个写->读回（白名单外的键必须被丢弃，证明判据不是恒真）
```

## 8. 2026-11-13 第二轮：用户反馈清单 A–E 落地

基准：`src/version.h = 1.1.7.9`，上一轮 179/179 ctest 全绿；本轮继续 179/179，
`native_ui_functional --audit` 从 97 → **146 项**（新增的每一条都能在旧实现上跑红）。

| # | 项 | 落地 | 判据（新增，都是运行时） |
|---|---|---|---|
| A | 侧栏「我的歌单」动态列表（web #sqList） | 歌单行 + ✎/× + 空态整行「＋ 新建歌单」+ 点行进页；删除静态「保存的队列」一行 | 造 2 个歌单 → 侧栏 2 行且名字顺序一致；✎ 改名后行文本变且后端同步；× 删除后消失；点行进歌单页且 `selectedName` 是那一份 |
| B | 播放条封面可点进播放页 | `RLPBarCoverView`：mouseDown → `RLPOpenNowPlayingNotification`；悬停手指 + 淡色覆盖 | 合成左键按下事件投给 `pb.cover` → `nowPlayingOverlayVisible=YES` 且页面真被创建 |
| C | 专辑页图一信息层 | 曲目表下方「N 首歌曲，X 分钟」+「℗ 年份」；「同艺人其他作品」横向封面卡（点击进详情）；随机键改圆形图标键 | 发布信息在曲目表**下方**（flipped 坐标比较）；其他作品 ≥1 张可点卡；版权行含 ℗ |
| D | 元数据源排版（图三） | 修复真故障：异步行到达后面板高度不重算 ⟹ 第 2 行起与「越靠上优先级越高」被裁 | 面板 frame 高度 ≥ intrinsicContentSize；底部提示有真实高度且不隐藏 |
| E | 新建歌单对话框 + toast | 共用 `RLPAskText`（标题/主按钮/占位符/提示小字，与 web askText 同构）；toast 带歌单名 | 走生产入口新建 → toast 文本含「已新建歌单：<名字>」且后端真落库 |

顺手修掉两处**用户可见的假象**（都有像素判据）：
- NSTableView `usesAlternatingRowBackgroundColors` 在 0 行时把空表区域铺成一屏灰条
  （队列页截图里 8 条灰带）。web 没有斑马底 ⟹ 关掉，判据量右侧空白列亮度沿 y 是否跳变。
- 歌单页去掉页内左侧列表（web 列表就在左导航），空态从「一行小字」改成 web 的整块
  「这个歌单是空的」——**先前它被表格不透明背景盖住，等于没显示**。

### 负向对照（证明判据不是恒真）

`RLP_AUDIT_NEGATIVE_CONTROL=1 ./build-mac/rlplayer_native --audit <dir>` 会关掉侧栏动态歌单，
模拟旧静态实现 ⟹ 该段 8 条断言全部转红（实测：rows=0、ren=0/del=0、改名无效、进页失败）。

## 9. 2026-11-13 第三轮：行内动作、空态与收藏路径真 bug

基准 `1.1.7.9`；本轮 179/179 ctest，`--audit` 146 → **178 项**。

| 项 | 内容 | 判据 |
|---|---|---|
| 曲目页行内动作 | 收藏心形（实心/空心随 /api/fav/list）+ 入队「+」（web `.trow-track` 第 2/7 列） | 点心形后 `/api/fav/list` 真的有这条；点 + 后 `/api/queue` 真的有这首；按钮 tag = 行号 |
| 最爱页行尾心形 | web `.fav-btn`：点一下取消收藏 | 与上行共用 /api/fav 路径 |
| 队列页行尾 × | web `.qdel`：只删这一行，不触发播放 | 点 × 后队列少一首；按钮有真实尺寸且落在可见宽度内 |
| 空态补齐 | 收藏（还没有收藏 + 怎么做）、最近（还没有播放记录）、队列第二行提示、流媒体**整页空态卡**（标题 + 协议说明 + 去设置 + 重试） | 文案可见 + 按钮 action 在位 + 点「去设置」真的切到设置·流媒体页签 |
| 空表条带 | `usesAlternatingRowBackgroundColors` 在 0 行时铺满灰条（队列/收藏） | 像素：右侧空白列亮度沿 y 不得跳变（先红后绿） |
| 歌单页结构 | 页内左侧列表移除（列表在侧栏），空态整块「这个歌单是空的」 | 空态文字真实可见（旧实现被表格背景盖住） |

### 9.1 后端真 bug（影响 web 与原生）：收藏路径被换成反斜杠

`tools/rtaweb.cpp` 的 `normalize_fav_path` 是 Windows 时代的「`/` → `\`」，
Windows 平台层删除后没改回来。后果：

- 落盘成 `\var\folders\…`，曲库/前端一律 `/var/folders/…` ⟹ `FAV_SET.has(path)` 永远 false，
  行内心形恒空心、最爱页把整串路径当文件名显示；
- 本轮判据「点心形 → /api/fav/list 能对上」**在旧实现上直接红**，才把这条老 bug 翻出来。

修法：规范形改成 `/`（读回旧文件时 `\` → `/`，老用户收藏不丢）。判据两条：
① 点心形后列表能对上曲库路径；② **预置一份 `\` 分隔的历史 rlplayer-favs.json**，
启动后 `/api/fav/list` 必须返回 `/` 形式（迁移，不是只修新写入）。

### 9.2 仍未做

见 `NATIVE-vs-WEB-差异清单.md` §5.2：AI 接入 bug（**需用户给现象**）、曲目页排序下拉、
专辑/文件夹空态（夹具造不出、无判据）、卡片悬停角标、默认渲染器切换、双模式薄表现层。

## 10. 2026-11-13 第四轮：排序下拉与行悬停（1.1.7.12 → 1.1.7.13）

| 项 | 内容 | 判据 |
|---|---|---|
| 曲目排序 | `tracks.sort` 下拉（web track-sort 七档：默认/标题/艺术家/专辑/时长/年份/收藏优先），客户端排当前已加载片 | 切「标题」后相邻两行必须升序（真重排）；切回默认复位 |
| 专辑卡悬停角标 | `album.playbadge`：默认隐藏、悬停浮现、点击=播放整张 | 隐藏→`cardHoverChanged:YES`→可见且有尺寸且 action 非空 |
| 列表行悬停 | 新增 `RLPHoverRowView`（NSTableRowView 子类，自管 tracking area + 底色），曲目/队列/最爱/最近四页接入（web `.trow:hover`） | **像素判据**：同一行悬停前/后各渲染一张，行中部采样颜色必须真的变化（0 宽/类名相等这类弱判据不算） |

`native_ui_functional` 186 → **189 项**；179/179 ctest。
