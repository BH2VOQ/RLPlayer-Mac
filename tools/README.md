# tools/ —— 命令行工具与验收脚本

本目录有两类东西：

1. **随发布包分发的 CLI**（`tools/make_app_mac.sh` 会把可执行文件打进 `RLPlayer.app/Contents/MacOS/`）——用户可直接用；
2. **开发/验收脚本**（`.js` / `.py` / `.sh`）——只在源码仓库里，用于构建、门禁与界面验收。

> **2026-10-25 平台变更**：项目已从「Windows + macOS 双平台」转为 **macOS 单平台**。
> 所有 `.ps1` 脚本、Windows 专属工具（`launcher` / `wasapi_probe` / `wasapi_ex_probe` /
> `asio_probe` / `wv2_probe` / `pxprobe` / `gpu_resample_test`）与 WebView2 SDK 已删除。
> 删的是**平台实现**，不是能力：Windows 上存在过的功能已在 macOS 侧有等价实现
> （详见 `PLATFORM.md` §13.15）。仍未移植的项在那里如实挂账。

> 所有会出声的工具默认电平 ≤ −60 dBFS；链路验证优先 `--analyze`（不打开设备）。
> 见项目开发铁律第 1 条。

---

## 一、随包 CLI

### 播放 / 转换

| 工具 | 作用 | 常用 |
|---|---|---|
| `rtaplay.exe` | 离线转换 / 分析 / 播放（管线与 GUI 完全相同） | `rtaplay music.flac --analyze`<br>`rtaplay music.flac --rate 705600 --taps 262144 --shaper NS9`<br>`rtaplay music.flac --ir room.wav --eq autoeq.txt --gpu` |
| `aidecode.exe` | 走统一解码路径并写出 WAV（便于逐位比对） | `aidecode in.flac out.wav` |
| `wavcmp.exe` | 逐位比较两个 WAV | `wavcmp a.wav b.wav` |
| `dsdconv.exe` | DSD 查看 / 抽取 / DirectSDM | `dsdconv --info x.dsf`<br>`dsdconv --direct in.dsf out.wav` |
| `make_dsd.exe` | 生成 DSD 测试素材 | `make_dsd tone.dsf 5 2822400` |
| `dopinfo.exe` | 检查 DoP 标记是否合法 | `dopinfo out.wav` |
| `filter_report.exe` | 滤波器频响/阻带报告 | `filter_report --taps 262144` |

### 设备与协议探针

| 工具 | 作用 |
|---|---|
| `upnp_scan.exe` | UPnP/DLNA 渲染器发现 |
| `naa_scan.exe` | NAA 端点发现（只发现，握手未实现） |
| `naa_probe.exe` | NAA 控制通道只读探测 |
| `rtanet_rx.exe` | 另一端接收 RTANet 网络音频 |
| `rtacast.exe` | UPnP 投放（命令行） |
| `rtacapture.exe` | WASAPI 采集 / 录制 |
| `gpubench_conv.exe` | GPU 卷积基准（会先验算平凡 kernel） |

### 元数据

| 工具 | 作用 |
|---|---|
| `rtatag.exe` | `parse` 文件名解析 / `enrich` 手动补全 / `store show|set` 查看或手改补全结果 / `llm-smoke` DeepSeek 连通自检 |

---

## 二、构建 / 打包脚本（仓库内）

| 脚本 | 作用 |
|---|---|

---

## 三、界面与验收脚本（仓库内）

| 脚本 | 作用 | 用法 |
|---|---|---|
| `uicheck.js` | 用 headless Edge + CDP 真跑一遍界面（点专辑、看曲目、收集 JS 异常） | `node tools/uicheck.js http://127.0.0.1:8911/ build/uicheck_out` |
| `t25check.js` | 单曲页/歌词/外链/UPnP 投放/时长等成套验收（含 893×587 真机档） | `node tools/t25check.js http://127.0.0.1:8931/ D:/shots` |
| `npcheck.js` | 单曲页专项验收 | `node tools/npcheck.js <url> <out>` |
| `lyr_dpr.js` | 歌词跟随两档视口验收（893×587 / 1340×880，DPR 1.5） | `node tools/lyr_dpr.js <url> <out> 893 587 1.5` |
| `peqcheck.js` | PEQ 对齐 + 拖拽/键盘/自动前级验收 | `node tools/peqcheck.js <url> <out>` |
| `uishots.js` / `uiprobe.js` | 批量截图 / 页面探针 | — |
| `mock_t25.js` / `mock_upnp_renderer.js` | 页面契约 mock / 假 UPnP 渲染器（不出声、不碰真设备） | — |

**这些脚本的共同前提**：测试实例必须无声（`backend=null`、`volume=-60`），
脚本会在起播前断言；不通过就拒绝继续。

---

## 四、几条硬规矩

- 不要用 `taskkill /IM` 或 `Stop-Process -Name` 停进程 —— 只停自己启动的 pid（铁律 2）。
- 测试音默认 −60 dBFS；需要可闻必须显式确认（铁律 1）。
- 验收脚本要能区分「真问题」与「夹具/环境问题」：判据先 FAIL 再 PASS（铁律 3）。
