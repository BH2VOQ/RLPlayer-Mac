# U2 包3：原生波形视图接入（2026-11-16）

> 分支 `feat/u2-ui`（worktree `.agents/wt-pages`）。本轮只接原生视图与判据：
> 不改后端、不碰播放条/EQ、不碰 8899、测试不启核心/不开设备/不出声。

## 交付

| 文件 | 内容 |
| `tools/native_ui/RLPWaveformView.h/.mm` | 新增。NSView 自绘：对称包络（中心基线、按数组最大峰值归一化）；已播 `--acc` / 未播 `--acc-weak` 双色；中心基线 `--line`；播放头竖线；拖选半透明高亮 + 两端竖线。点击 → `onSeek`；拖选 ≥0.5 s → 保留选区并回调 `onSelect`；<0.5 s 自动清掉。 |
| `tools/native_ui/RLPNowPlayingViewController.mm` | 切曲/首次进入发一次 `GET /api/waveform?file=…&bins=512`（:3521），把 `peaks/rms/duration` 写进视图属性；`/api/status` 每轮（既有 0.4 s）只写 `playheadFraction`（:3441 / :3534），同曲绝不重发；视图挂 `npPage`、identifier `np.waveform`（:2017）、高 50 pt、控制条正上方（:2329）；点击走 `POST /api/seek?pos=`（:3543，守卫与 `onCommitSeek` 同一口径）。切曲清空旧包络/选区，迟到响应用 `waveformSeq` 丢弃。 |
| `tests/test_native_waveform.mm` | 新增：24 条断言（23 条判据 + 1 条前置）。 |
| `CMakeLists.txt` | 新目标 `test_native_waveform`（ctest `native_waveform`）；`RLPWaveformView.mm` 加进所有编译 NP VC 的目标（13 个，含 `rlplayer_native`）。 |
| `docs/i18n/chunk-native126-waveform.en.tsv` | 新增词条「波形 → Waveform」。 |
| `src/net/i18n_table.h`、`tools/native_ui/RLPNativeI18n.mm` | 两个生成器重生成（2493 pairs，`--check` 均 OK）。 |
| `docs/native-ui/parity.tsv` | 重生成：`api /api/waveform` 由 missing → done（total 438 / done 364 / missing 0）。实际状态变化只有这一行，其余 176 行是既有证据行号漂移（生成物落后于最近合并的提交）。 |
| `evidence/u2-waveform-native-{red,green}-20261116.log` | 本地留档（`*.log` 按 .gitignore:37 不入库）。 |
| `evidence/u2-waveform-native-{light,dark}-20261116.png` | 视图离屏渲染（1160×50 @2x）：对称包络 / 双色 / 播放头 0.38 / 拖选 0.22–0.55 高亮。 |

## 判据与红 → 绿

| 轮次 | 命令 | 结果 |
|---|---|---|
| 红（旧实现） | `cmake --build build-mac --target test_native_waveform` 后直接跑 | build 0；**run exit 1**：W1 视图树无 `np.waveform`（nil）、W3 `/api/waveform` 请求 0 次、W7d/W11 同理，共 **4 failures** |
| 绿（本包） | 同上 | **exit 0**：24 PASS / 0 fail（`waveform: 0 failures`） |
| 绿（ctest 目标测试） | `ctest -j1 -R "native_waveform\|native_nowplaying_web\|analysis_row\|native_rail_cards\|native_npmeta_chips\|native_np_refresh\|native_pages_p812\|i18n_table_check\|native_i18n_table_check\|native_i18n_coverage"` | **10/10 passed**（12.7 s） |
| 构建 | `cmake --build build-mac -j8 --target rlplayer_native` | exit 0（链接通过） |

关键判据（`native_waveform`，注入 512 bin 合成 peaks：bin0=1.0 / bin1=0.5 / 其余 0.1）：

- W1/W1b/W2/W2b：`np.waveform` 存在、在 `npPage` 内、高 50 pt ∈ [44,56]、底边 676 ≤ 控制条顶 684。
- W3/W3b/W3c：切曲只发 1 次 `/api/waveform?file=…&bins=512`，file 按 encodeURIComponent 编码（含空格的路径可回读）。
- W4/W4b/W4c：`peaks`/`rms` 长度 512，`duration=10.0` 来自响应（不是自己编）。
- W5/W5b：包络围绕中心基线对称，`bin1/bin0` 高度 = 0.50（按最大峰值归一化）。
- W6/W7/W7b/W7c：播放头 0 时整条未播色；`pos=4.0/dur=10` 后播放头 0.400，已播段取 `--acc`、未播段另一色。
- W7d：同一曲第二次 `/api/status` 轮询**没有**新波形请求（总请求仍 1 次）。
- W8：真实窗口鼠标 down/up 点击 40% 处 → `POST /api/seek?pos=0.4000`。
- W9/W9b/W9c：拖选 0.20→0.70（5.0 s）保留选区、端点相符、不发任何请求。
- W10：拖选 3%（0.3 s）< 0.5 s，选区被清掉。
- W11：切到第二首 → 第二次波形请求（切曲重算、同曲不重算）。

## 未做 / 挂账

- **A/B 段端点没有实现**（后端无 A/B 段端点，web 也没有）：拖选只做高亮 + `waveformSelection` 留痕，
  不设循环点、不发请求；W9c 把「不发请求」钉成判据。
- `/api/status` 轮询沿用既有 **0.4 s**（任务里的 500 ms 是量级约定）；只更新播放头，未改周期
  （改周期会波及播放条/其它页面，超出本包范围）。
- 波形对网络曲目与非 WAV/DSF/DFF/超限素材不取数，只留中心基线（`/api/waveform` 契约如此），
  不是假包络；同一首失败后同曲不再重复打后端。
- 只跑目标测试（上表 10 条）与 `rlplayer_native` 构建，**未跑全量 ctest**；
  受影响的原生测试全部保留原判据且为绿。
- 观感只做离屏渲染核对（两张 PNG），**未在真机 .app 里点过**；实机验收按惯例由用户执行。
- i18n 生成器本轮提示仍有 18 条未译（既有条目；本包新增的「波形」已译，未新增未译条目）。
