# tools/ —— 命令行工具与验收脚本

本目录有两类东西：

1. **随发布包分发的 CLI**（`tools/make_app_mac.sh` 会把可执行文件打进 `RLPlayer.app/Contents/MacOS/`）——用户可直接用；
2. **开发/验收脚本**（`.js` / `.py` / `.sh`）——只在源码仓库里，用于构建、门禁与界面验收。

> **2026-10-25 平台变更**：项目已从「Windows + macOS 双平台」转为 **macOS 单平台**。
> 所有 `.ps1` 脚本、Windows 专属工具（`launcher` / `wasapi_probe` / `wasapi_ex_probe` /
> `asio_probe` / `wv2_probe` / `pxprobe` / `gpu_resample_test`）与 WebView2 SDK 已删除。
> 当前支持范围与未完成功能以根目录 README 和开发路线图为准；历史平台实现不代表当前 macOS 已通过验收。

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
| `tipcheck.js` | 设置页 (?) 气泡几何验收：真实 CDP 鼠标 + 真实 Tab，::after 变换后矩形与全部裁剪祖先求交 | `node tools/tipcheck.js --url http://127.0.0.1:19093 --out /tmp/tipcheck --tab-sweep` |
| `iconcheck.py` | .icns 图标几何验收（256 档实体 206±4px、四角透明、10 档齐全），需 bundled Python + Pillow | `"$PY" tools/iconcheck.py --icns dist-mac/RLPlayer.app/Contents/Resources/RLPlayer.icns --apple-ref` |
| `make_icon_mac.swift` | 由 `res/rlplayer-256.png` 生成带透明留白的全档 iconset（打包脚本调用） | `swift tools/make_icon_mac.swift res/rlplayer-256.png /tmp/RLPlayer.iconset` |
| `check_seekdrag.js` | 进度条拖动验收：按下即预览 / 1:1 跟手 / 拖动中零请求 / 不被轮询回拉 / 松手单次提交 / 真跳转 / 无 0.18 s 补间 / rAF 推进 / 整页同套 / 相对跳转基准；`--red` 用旧实现证明判据有效 | `node tools/check_seekdrag.js http://127.0.0.1:19099 debug/20261028-03-进度条拖动/shots [--red]` |
| `check_volume_db.js` | 音量 dB 验收：0.5 dB 固定档位 / 静音逃逸 / 顶端夹紧 / 0.1 dB 细档 / 滚轮 / 双击归零 / 下发一致 / 标签一致 / 全档位换算互逆；`--red` 跑旧公式证明判据有效 | `node tools/check_volume_db.js http://127.0.0.1:19099 debug/20261028-04-音量dB/shots [--red]` |

**2026-10-28 新增的三个工具**都在 `make_app_mac.sh` 的打包链上或与之配套：
`make_icon_mac.swift` 出图、`iconcheck.py` 判几何、`tipcheck.js` 判气泡不越界。
同一天另加的两个**交互**验收脚本（进度条拖动 / 音量 dB）见上表，均自带 `--red` 反证模式。

**这些脚本的共同前提**：测试实例必须无声（`backend=null`、`volume=-60`），
脚本会在起播前断言；不通过就拒绝继续。

---

## 四、几条硬规矩

- 不要用 `taskkill /IM` 或 `Stop-Process -Name` 停进程 —— 只停自己启动的 pid（铁律 2）。
- 测试音默认 −60 dBFS；需要可闻必须显式确认（铁律 1）。
- 验收脚本要能区分「真问题」与「夹具/环境问题」：判据先 FAIL 再 PASS（铁律 3）。
