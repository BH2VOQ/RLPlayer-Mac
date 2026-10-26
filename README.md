# RLPlayer

**macOS 上的高保真播放引擎 + 播放器**（RLPlayer 同类）。核心目标只有一个：**不计代价提升本地播放音质**，并且把每一步都变成可测量的数字。

- 输出链路完全自研：升频 → 抖动/噪声整形 → SDM/DSD 调制 → 卷积 → 20 段 PEQ → **CoreAudio 独占（Hog）/ 共享 / UPnP / 网络端点**
- **不追求"听起来更好"，追求"能测出来好"**：升频阻带 −189 dB、DSD 源抽取 THD+N 99.2 dB、网络传输端到端逐位相同
- **单进程原生应用**：`.app` 内嵌 WKWebView 渲染界面，业务逻辑**静态链进同一进程**——不占端口、不起子进程、不需要任何浏览器
- 单包自包含：内置 ffmpeg/ffprobe、Metal GPU 内核，用户机上**不需要装任何运行库**

> 当前版本 **1.0.4**（2026-10-26）。逐轮实测数字与已知限制见 [STATUS.md](STATUS.md)。

---

## 这是独立分支

本仓库是 **macOS 独立产品线**，与上游 `github.com/okhuoyanyan/RLPlayer`（Windows）**不再合并**。

| | 上游 | 本仓库 |
|---|---|---|
| 平台 | Windows x64 | macOS 13.0+ / arm64 |
| 输出 | WASAPI 独占/共享、ASIO | **CoreAudio 独占（Hog）/ 共享** |
| GPU | HIP（AMD）/ CUDA（NVIDIA） | **Metal** |
| 界面 | WebView2 + 托盘 | **WKWebView + 原生 NSWindow** |
| 进程 | 独立 HTTP 服务 + 客户端 | **单进程**（`WKURLSchemeHandler` 桥接内置核心） |
| DSD 输出 | Native DSD（ASIO）+ DoP | **仅 DoP**（macOS 无 ASIO 原生 DSD 驱动通路） |

> 因此 `#ifdef _WIN32` 分支在本仓库是死代码，Windows 平台层（WASAPI / ASIO / WebView2 / WinHTTP / MMCSS / dbghelp / CUDA / HIP）**已全部删除**。

---

## 最近更新（1.0.4）

对比上游 v1.5.2，本轮修了 6 个 mac 可复现 BUG，并在 mac 架构上重做了 7 组功能：

| 项 | 内容 |
|---|---|
| **专辑封面** | 只问首曲 + 1x1 占位图当封面缓存 ⟹ 首曲无图时整张专辑空白。改为 cv=1 曲目优先（≤3）+ 其余（≤3）、`<1KB` 或 1x1 继续试、占位写负缓存 |
| **WAV 占位标题** | RIFF `INFO` 的字面 `0x3F`（`???`）压过 ID3 真名。新增 `tag_is_placeholder()`，**只限 WAV 跨块合并**（MP3/OGG 套上会让 A/B 变红） |
| **单曲入队** | 专辑页曲目行**零入口**（连右键都没绑）。加可见「+」按钮 + 行右键，列表页同步 |
| **底栏徽标** | 两态 → **六态**（直通 / PCM-PCM / PCM-DSD / DSD-DSD × bit-perfect 与否），带降级原因 `title` |
| **上传上限** | `/api/upload` 被 16MB 全局 body 上限挡死。按路径给上限（上传 2GB，其余 16MB） |
| **`Expect: 100-continue`** | curl 对 >1MB 请求体默认带该头并等 `100 Continue`（等 1s），而服务器从不回、body 读循环 500ms 先超时 ⟹ 稳定 400。**基线 2MB 就失败**，被 16MB 上限掩盖至今 |
| **在线封面** | 新增抓取 + 进度。断网 `fail` 不写负缓存（只有服务器明确说没有才写）；Dice 系数比对拒绝「名字都不像就拿第一张」 |
| **音频体检** | DR / BS.1770 LUFS / LRA + 假无损检测（频谱截止 + 陡沿 + 24bit LSB），新增 `rtahealth` CLI |
| **房间校正** | Farina 扫频 / 正则化反卷积 / 心理声学平滑 / 最小相位校正 IR / 超低对齐 / 多声道布局 |
| **第 4 档预设** | PCM→DSD（`pcm2dsd`，EC-7 + tight + 512 抽头）。**mac 口径：只走 DoP**，无 DoP 能力时明确降级并说明原因 |
| **status 自证字段** | 新增 `outMode`/`dsd`/`dsdRate`/`carrierRate`/`modFamily`/`modOrder`/`fallbackWhy` |
| **GPU 精度实测** | 卷积最差 −126.5 dB、升频 max\|Δ\|/峰 8.3e-06（Apple GPU 无 double，与 CUDA 差 9~10 个数量级） |
| **GPU 卷积真 BUG** | 逐块调用无状态 API ⟹ **IR 拖尾丢失**（实测 65410/65536 样点错、−1.63 dB）。改 overlap-save 后 0/65536、−150.12 dB |

---

## 特性

### DSP 链路

| 能力 | 说明 |
|---|---|
| **多相 sinc 升频** | 任意有理比率；阻带 **−189 dB**，通带纹波 **0.0000 dB** |
| **滤波器家族** | 16 个预设 + 倒谱法最小相位、混合相位；可指定抽头数；tight 变体（512 抽头/相位） |
| **抖动 / 噪声整形** | 10 项：NS1/NS4/NS5/NS9/LNS15 + RPDF/TPDF/Gauss1/shaped |
| **SDM 调制器** | DSD5 / DSD7、多电平 AHM、EC 族（H∞ 受控 NTF）；1-bit 带内 SNR 86.2 dB，8-bit 118.8 dB |
| **DSD 原生读取** | DSF/DFF 直接读；抽取器 FIR/IIR/CIC；**DirectSDM 逐位直通**；大 DSD 流式解码（首帧 4.3×、内存 17.5×） |
| **卷积引擎** | 零延迟均匀分块 FFT；支持 Metal GPU（**注意：mac 上 GPU 卷积比 CPU 慢，见下方「GPU」**） |
| **20 段参数均衡 PEQ** | RBJ 双二阶（PK/LS/HS）、1/3 倍频程、曲线可拖拽节点、自动前级（防削波）、预设 |
| **房间校正** | IR 卷积 + 测量编排（扫频/反卷积/校正集导出） |
| **音频体检** | TT DR / LUFS / LRA / 假无损检测，可缓存 |
| **Matrix / EQ** | 声道路由 + 双二阶 IIR EQ + 延迟插件 + REW/AutoEq 文本解析 + OPRA 耳机预设 |
| **多声道** | 5.1 / 7.1（WAVEFORMATEXTENSIBLE 声道掩码）+ 每声道增益微调 |
| **保护** | 过采样峰值检测（ISP）自动预衰减、音量渐变、响度补偿；满幅/瞬态/恢复都有回归测试 |

### 输出后端

| 后端 | 用途 |
|---|---|
| **CoreAudio 独占（Hog）** | bit-perfect 直通；Hog Mode 抢设备避免系统混音器重采样；自动协商采样率/位深，设备不支持时**如实报错不静默替换** |
| **CoreAudio 共享** | 独占不可用时的兜底（非 bit-perfect，会明确告知；不支持 DoP/DSD） |
| **DoP（DSD over PCM）** | 24-bit 载波封装 DSD；**mac 唯一的 DSD 输出路径** |
| **UPnP / DLNA** | 一键推送到局域网渲染器 |
| **NAA / RTANet** | 两机网络音频：RTANet 端到端逐位相同 + 时钟漂移检测；标准 NAA 只做发现 |
| **Null** | 离线/自动化测试，不开任何设备 |

> **Native DSD**：macOS 没有 ASIO 原生 DSD 驱动通路，`/api/play` 收到 `dsdnative=1` 会**明确报错**而不是静默降级。

### 界面

WKWebView 内嵌、**单进程**、完全无边框（四边可拉伸，6px 边缘热区）：
专辑网格 / 艺术家 / 曲目 / 文件夹 / 流媒体 / 单曲整页（歌词跟随 + 资料抽屉 + 推送）/ 播放队列 / 设置页（输出·PCM·SDM·高级·EQ·元数据·流媒体·诊断）。
三套主题（深 / 浅 / 浅蓝），标题栏与窗口边随主题即时切换。

### 元数据与 AI

- 播放时自动补全标签/封面/歌词：QQ 音乐 / 网易云 / iTunes / lrclib / Discogs；
- 在线封面抓取（内嵌图 → 网图 → 负缓存 7 天），请求线程**零网络**；
- DeepSeek 负责疑难文件名解析、歧义裁决与「资料整理」（**防幻觉**：无来源时标注「AI 整理」，有来源时强制引用）；
- 实体级缓存（person/release/track），命中即秒回；单曲页与艺术家页**共用同一份 person 缓存**；
- 可选写回文件标签（`rtatag`），失败不动原文件。

---

## 快速开始

### 用 DMG 安装包

1. 下载 `RLPlayer-v<版本>-macOS-arm64.dmg`
2. 双击挂载，把 `RLPlayer` 拖进 `Applications`
3. 首次打开若提示「无法验证开发者」：右键 →「打开」，或 `系统设置 → 隐私与安全性 → 仍要打开`

> ad-hoc 签名，未做 Apple 公证（notarization）。自用/内部分发没有问题。

**系统要求**：macOS 13.0+ / Apple Silicon（arm64）。**不支持 Intel Mac。**

### 从源码构建

```bash
# 前置：CMake ≥ 3.20、Xcode Command Line Tools
cd RLPlayer

cmake -S . -B build-mac -DCMAKE_BUILD_TYPE=Release
cmake --build build-mac -j8
ctest --test-dir build-mac --output-on-failure     # 82/82

# 出 .app（会自动做架构/部署目标/签名门禁）
bash tools/make_app_mac.sh
# → dist-mac/RLPlayer.app

# 出 DMG
hdiutil create -volname "RLPlayer" -srcfolder <staging> -format UDZO RLPlayer.dmg
```

> **本机 CMake 不在 PATH**：`/private/tmp/cmake-3.31.6-macos-universal/CMake.app/Contents/bin`

### 用 CLI（开发/调试用）

`rtaweb` 是**开发/测试用 HTTP CLI**（`.app` 不打包它，`make_app_mac.sh` 有门禁：出现即致命错误）。
它的端点与产品内部 `handle()` 是**同一份代码**，所以适合验证端点语义：

```bash
# 完全隔离的测试实例（绝不碰用户配置）
RLPLAYER_STATE_DIR=/tmp/xxx RLPLAYER_LIBRARY_DIR=/tmp/xxx/lib \
  ./build-mac/rtaweb --port 8960

# 音频体检
./build-mac/rtahealth 曲目.flac --json

# GPU 精度实测（纯离线，不开设备）
./build-mac/gpu_precision
```

> ⚠️ **端口 8899 是用户实例，绝不碰**。测试用 8960+，用完 `kill -TERM`（不 force-kill）。

---

## GPU

mac 用 `librtagpu.dylib`（Metal，运行时编译 MSL），**动态加载**：dlopen 不到就自动退回 CPU。

### ⚠️ 卷积：mac 上不建议开 GPU

实测（Apple M4，`docs/GPU卷积与升频效率细查.md`）：

| IR | 每块 n | GPU | CPU | 结论 |
|---:|---:|---:|---:|---|
| 16384 | 4096（**生产**） | 0.891 ms | 0.264 ms | **慢 3.37×** |
| 16384 | 65536 | 4.108 | 4.332 | 快 5% |
| 65536 | 4096（**生产**） | 2.088 | 0.520 | **慢 4.02×** |
| 65536 | 32768 | 3.351 | 4.487 | 快 25% |

**根因**：mac 的 GPU 后端把 FFT 留在 CPU、只做逐点复数乘加；生产每块只有 4096 样，
远低于 GPU 的盈亏平衡点（实测需 **n ≥ 32768** 才翻盘）。
即使缓存 IR 频谱（目前每块重算，IR=262144 时占 91.3%）仍慢 3.7~8.3×。

⟹ **`irgpu` 默认关闭，UI 已标注不建议开启**。功能保留可用（数值正确），但 mac 上是净亏。

### ✅ 升频：值得开 GPU

| 转换 | CPU | GPU | 加速 |
|---|---:|---:|---:|
| 44.1k → 352800 | 597.9 ms | 16.8 ms | **29×** |
| 44.1k → 384000 | 21.2 ms | 4.1 ms | **5.5×** |

升频每输出样要做 512~32768 次乘加，是纯算力活，块小也不怕。

### 精度

| 项 | 实测 |
|---|---|
| 卷积（最差格） | **−126.5 dB** 相对 RMS |
| 卷积（最好格） | −148.4 dB |
| 升频 | max\|Δ\|/峰 **8.3e-06**（Apple GPU 无 double，与 CUDA 的 ≤8e-16 差 9~10 个数量级） |

---

## 客观指标

全部由 `ctest` 自动验证（**82 套**），不是估算：

| 项 | 实测 |
|---|---|
| 升频阻带衰减 | **−189 dB** |
| 升频通带纹波 | **0.0000 dB** |
| NS9 带内噪声 vs TPDF | 低 **45.4 dB** |
| DSD5 1-bit 带内 SNR | **86.2 dB** |
| 8-bit SDM 带内 SNR | **118.8 dB** |
| DSD 源抽取 THD+N（DSD64→176.4k） | **99.2 dB** |
| 双二阶 10 种设计（解析 vs 实测） | 偏差 **0.0000 dB** |
| 20 段 PEQ 单段 +6 dB | **6.0000 dB**（44.1/48/96/192k） |
| 网络传输（回环 690 包） | **逐位相同** |
| GPU 卷积修 IR 拖尾后 | 0/65536 样点错、**−150.12 dB** |
| 专辑封面多曲重试 | 28/28 判据（修前 19 过 9 败） |
| WAV 占位标题 | 138/138（含 6 条负向对照） |

---

## 项目结构

```
src/
  dsp/         DSP 核心：升频/滤波器/量化器/调制器/卷积/EQ/PEQ/房间校正（头文件库）
  analysis/    音频体检：动态测量（DR/LUFS/LRA）/ 假无损检测 / 体检编排
  audio/       WAV 读写、DSD 原生读取、渲染循环、缓冲策略
  platform/    平台层（macos/ 下是 CoreAudio / path / process / http 的 POSIX 实现）
  net/         RTANet 协议、UPnP 投放、Web 界面（ui_page.h / ui_script.h）
  engine/      播放管线（信号链整合）、预设决策层
  gpu/         Metal 内核（卷积 / 重采样）——唯一 GPU 后端
  meta/        元数据补全（实体模型 / 数据源 / 缓存 / LLM 综合）
tools/         mac_host.mm（原生壳）、rtaweb（测试 CLI）、rtahealth、gpu_precision、打包脚本
tests/        ctest 门禁（82 套）
docs/         各模块实测纪要与调研
AGENTS.md     开发铁律（动手前必读）
STATUS.md     逐轮状态与实测数字（最新事实在这里）
```

---

## 测试与验证

```bash
CM=/private/tmp/cmake-3.31.6-macos-universal/CMake.app/Contents/bin

$CM/ctest --test-dir build-mac --output-on-failure     # 82/82
```

**验证不打开音频设备**：所有链路验证优先离线（`--analyze`）或 Null 后端。
需要出声的测试默认电平 ≤ −60 dBFS（见 [AGENTS.md](AGENTS.md) 铁律 1）。

**Windows 侧门禁**（`verify.ps1` / `check_compat.ps1`）本机跑不了 —— 本仓库已无 Windows 平台层，不再需要。

---

## 已知限制

- **Native DSD**：macOS 无 ASIO 原生 DSD 驱动通路，**只支持 DoP**；`dsdnative=1` 会明确报错
- **GPU 卷积**：任何 IR 长度下都比 CPU 慢（见上方「GPU」），默认关闭
- **输入采集**：设备枚举与设置页已有，采集→DSP→输出通路未实现
- **标准 NAA**：只做发现，握手未实现；两机方案请用 RTANet
- **DSD 域重采样**：同速率 DirectSDM 逐位直通可用；**速率不同时的 DSD→DSD 重采样未做**
- **7 阶 1-bit 调制器**：只在 DSD128 以上稳定
- **假无损检测**：AAC ≥128k 检不出（阈值「宁可漏报不可误报」的设计取舍）
- **AI 资料**：首次生成耗时主要来自 LLM（中位 ~12 s）；缓存命中 6~7 ms
- **Intel Mac**：不支持（只构建 arm64）

完整清单见 [STATUS.md](STATUS.md)。

---

## 文档

| 文件 | 内容 |
|---|---|
| [STATUS.md](STATUS.md) | **逐轮状态与实测数字 —— 最新事实以这里为准** |
| [AGENTS.md](AGENTS.md) | 开发铁律（8 条 + 反馈目录规范） |
| [docs/GPU卷积与升频效率细查.md](docs/GPU卷积与升频效率细查.md) | GPU 卷积/升频效率实测（拐点、根因、建议） |
| [docs/WIP-F1-封面抓取.md](docs/WIP-F1-封面抓取.md) | 在线封面抓取 + 专辑归并的 mac 实现与判据 |
| [docs/WIP-F6-GPU精度.md](docs/WIP-F6-GPU精度.md) | GPU 精度矩阵与门控建议 |
| [debug/](debug/) | 每轮 DEBUG 档案（根因、判据、挂账） |
| [docs/](docs/) | 各模块实测纪要、调研、踩坑记录 |

---

## 版权

私有项目，保留所有权利（All rights reserved）。未经作者书面许可，不得复制、分发或用于商业用途。

第三方组件（ffmpeg 等）遵循其各自许可证。
