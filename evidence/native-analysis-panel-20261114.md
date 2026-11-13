# 正在播放 · 音频分析面板 = web `#npAnal`（1.1.7.24 → 下一版）

日期：2026-11-14
范围：`src/net/ui_page.h:874-950`（web 真源）↔ `tools/native_ui/RLPNowPlayingViewController.mm`
基线：`2b88e1d`（1.1.7.24），工作树另有未跟踪的 `website/`（未触碰）

## 0. 结论

| 项 | 结果 |
|---|---|
| 新判据 `native_analysis_panel` | 红 **29 passed / 37 failed** → 绿 **129 passed / 0 failed** |
| 全量构建 | exit 0 |
| 全量 ctest | **188/188**（基线 187 + 本包新增 1），exit 0 |
| `rlplayer_native --audit` | **246 passed / 0 failed**（隔离目录；见 §5 的 1 次偶发段错误挂账） |
| parity_scan --check | `done=299 missing=0 removed=2 na=16` |
| behavior_scan --check | `actionable=0` |
| gen_i18n_table.py --check | `OK（2318 pairs）` |

## 1. web ↔ native 对照（逐项，全部来自真实视图树 / 真源 CSS）

| 维度 | web（ui_page.h） | native 旧码 | native 新码 | 判据 |
|---|---|---|---|---|
| 头部标题 | `.anllab` 9.5/700，`letter-spacing:1.5`，左 11（面板 padding） | 与状态合成「音频分析 · 未播放」9.5 常规，左 12 | 独立 `#npAnlLab`，9.5/700 kern 1.5，左 11 | `anslab.font=9.5`、`kern=1.5`、`left=11` |
| 状态 | `#npAnlStat` 10px 右对齐、tabular | 左对齐、9.5、含「音频分析 · 」前缀 | `#npAnlStat` 10px 右对齐，框右缘距面板右 13 | `stat.rightGap=13.00/13.00`，alignment=right |
| 动作容器 | `.npseg` 1px 外框、radius 9、内部发丝分隔 | 三枚各自带边框的药丸 48/54/46×25 | **一个** `#npAnlSeg` 外框 radius 9，3 段直接子视图 | 恰 1 个带边框容器包住三段；`radius=9` |
| 分段 | `.npseg>b` 10.5/600，padding 3 11 | 10.5 常规、各自 bezel | 10.5/600、padding 3 11、发丝 1px | `npseg.font=10.5` + 600；邻段 gap=1 |
| 卡片 | `.anlcard` padding 7 9 8、gap 4、radius 10、border 1，高度随内容 | 自绘 NSButton：标题 11 无字距、摘要 11 单行截断、固定高 100/74 | 子视图卡：标题 10.5/700 kern .8、摘要 11.5/1.45、动态高度 | `anlct.font=10.5`、`kern=.8`、`padTop=7`、`padLeft=9`、`padBottom=8~9`（行发丝 1px 计入） |
| 摘要 | `.anlcs` 11.5 / line-height 1.45 | 11、裁到 34pt | 11.5，行高 16.675pt（1.45），按文本实测长高 | `anlcs.font=11.5`、`lineHeight=16.68`；长摘要把卡撑高 |
| 多声道徽标 | `.anlbadge` 9.5 radius 5，「多声道 N ch」（channels>2） | 无 | `#anl.dyn.badge` 9.5/radius 5 / 文案「多声道 6 ch」 | fixture channels=6 |
| 展开档 | 三卡**保留**，每卡长出 `.anlgrid` 2 列 | 三卡 `hidden` + 一块纯文本 NSTextView | 三卡保留，卡内 2 列行模型（L1/L2） | 展开后 3 卡可见；L1 ≥12 对、L2 更多 |
| 行 | `.anllb` 10 / `.anlv` 11 tabular 右对齐；`.anlv.na` 灰 10.5 换行；`.anlv.warn` 琥珀 600 | 无 | label 10 / value 11（非 NA）、NA 10.5 灰、warn 琥珀 | 右缘贴列右缘；NA 全灰、无 `-300` |
| 分组 | `.anlsec` 10/700 kern .7 + 顶部 1px 规则 | 纯文本里只有「动态/音质/假无损」段落 | `#anl.sec` 10/700 kern .7 + `anl.sec.rule` 1px | `anlsec.font=10`、`kern=.7`、rule 存在 |
| 过载框 | `.anlwarn` 10.5，琥珀 rgba(234,179,8,.10) 底 + .24 边 radius 7 | 无 | `#anl.dyn.warn` 同样底色/边/radius，含「母带要修 +1.80 dBTP」+ 提示 | border/background/radius 均量到 |
| 空态 | `anlEmptyBody`/`#npAnlStat` 文案 | 展开档纯文本解释 | 无 health 时仍显示等价纯文本解释（`RLPAnlDetailText`），cards 不丢 | 保留旧信息路径 |

## 2. 红 → 绿

新判据文件：`tests/test_native_analysis_panel.mm`（714 行，ctest 名 `native_analysis_panel`，TIMEOUT 120）。

```bash
# 红：先把生产码还原到 1.1.7.24
git diff tools/native_ui/RLPNowPlayingViewController.mm \
         tools/native_ui/RLPAnalysisSummary.h tools/native_ui/RLPAnalysisSummary.mm > /tmp/anl_prod.patch
git checkout -- tools/native_ui/RLPNowPlayingViewController.mm \
                tools/native_ui/RLPAnalysisSummary.h tools/native_ui/RLPAnalysisSummary.mm
$CM/cmake --build build-mac -j8 --target test_native_analysis_panel
./build-mac/test_native_analysis_panel          # 29 passed / 37 failed, exit 1
git apply /tmp/anl_prod.patch
```

- 红日志：`evidence/native-analysis-panel-red-20261114.log`（**29 passed / 37 failed**，exit 1）
- 绿日志：`evidence/native-analysis-panel-green-20261114.log`（**129 passed / 0 failed**，exit 0）
- 还原/重放的生产 diff `sha256` 一致（`a9fcb802…97`），红绿跑的是同一份生产码。

红判据里能直接看到旧病：`npAnlLab 缺失`、`恰好一个带边框容器 found=0`、`卡片标题/摘要都是真实子视图 title=0 sum=0`、`多声道徽标缺失`、`展开档三张卡全部可见 visible=0`、`指标网格 labels=0 values=0`、`分组标题 rules=0`、`真峰过载警告框缺失`。

## 3. 关键几何（绿日志原值，web/native/差）

见 §1 表格；代表性的逐条输出：

```
anslab.font   web=9.50  native=9.50   +0.00
anslab.kern   web=1.50  native=1.50   +0.00
stat.rightGap web=13.00 native=13.00  +0.00
npseg.radius  web=9.00  native=9.00   +0.00
npseg.gap     web=1.00  native=1.00   +0.00
anlcard.left  web=11.00 native=11.00  +0.00
anlct.font    web=10.50 native=10.50  +0.00
anlct.kern    web=0.80  native=0.80   +0.00
anlcs.lineH   web=16.68 native=16.68  +0.00
anlcard.padBottom web=8.00 native=8.00 +0.00（音质/假无损；动态卡含 1px 行发丝时为 9）
```

数据夹具（真实后端 JSON 形状 `{ok,cached,health}`）：`channels=6`、`true_peak_dbtp=+1.8`、`dr_available=false`、`lra_available=false`、`quality.hf_ratio_10k_available=false`、`quality.stereo=true`。
→ L1 断言到 `-14.20 LUFS`、`6 ch`、两个 `NA（素材过短）`、`NA（采样率 ≤20 kHz）`、`NA（多声道）`、`+1.80 dBTP`；整格**不出现 `-300` 哨兵**。L2 断言到 `48000 Hz`、更多分组（采样规格/原始证据等）。

## 4. 新增测试判据（`tests/test_native_analysis_panel.mm`）

1. 头部：独立 `#npAnlLab`（文案/9.5/700/kern1.5/左 11）；`#npAnlStat` 10px、右对齐、框右缘距面板右 13±1、不含「音频分析」；标题不被字距撑破（frame ≥ attributed 宽）。
2. 动作：三段仍在同一行；**恰好一个**带边框容器同时包住 `npAnlAuto/npAnlToggle/npAnlRun`；半径 9；三段是它的直接子视图；邻段 gap ≤1；10.5/600。
3. L0 卡片：3 卡可见、radius 10、左 11、宽 `panel−22`；标题 10.5/700/kern.8（inset 7/9）、摘要 11.5/1.45（attributed 段落行高）、头部→摘要 gap 4、底部内边距 8；把摘要改成 60+ 字后卡片必须长高且 label/frame 容得下；徽标「多声道 6 ch」9.5/radius 5；卡片暴露生产 tap 入口（`onTap`）。
4. L1：生产入口（点「详细」= `onAnlExpand:`）后 **3 卡仍可见**；≥12 对 label/value；label 10、非 NA 值 11、NA 10.5；值右对齐且右缘贴所在列右缘；≥1 分组标题（10/700/kern.7 + 顶部规则）；过载框有边框+底色+radius 7 且主文「母带要修 +1.80 dBTP」；NA 灰字、无 `-300`、真实值来自 fixture。
5. L2：指标/分组比 L1 多，三卡仍可见；`48000 Hz` 只在 L2 采样规格出现。
6. 收起：同一批卡片对象身份不变、指标行归零、比 L1 矮、分段标题回到「详细」。
7. 既有行为：`onToggleAuto` 仍 POST `autoanl=1`；`onAnlReanalyze` 仍发 `/api/track/health?file=…&force=1`。
8. 默认窗口 1180×760：标题完整、状态贴右（13）、分段右端贴内容右缘（11）。

## 5. 门禁（最终树，串行、机器空闲）

```bash
$CM/cmake --build build-mac -j8                                  # exit 0
$CM/ctest --test-dir build-mac -j1 --output-on-failure           # 188/188，377.63s，exit 0
RLPLAYER_STATE_DIR=<tmp>/state RLPLAYER_LIBRARY_DIR=<tmp>/lib HOME=<tmp>/home \
  ./build-mac/rlplayer_native --audit <tmp>                      # 246 passed / 0 failed，exit 0
python3 tools/native_ui/parity_scan.py --check                   # missing=0
python3 tools/native_ui/behavior_scan.py --check                 # actionable=0
python3 tools/gen_i18n_table.py --check                          # OK (2318 pairs)
```

保留的相关用例全绿：`native_rail_cards`、`native_rail_preview`、`native_nowplaying_web`、`analysis_row`（ctest 输出逐条核对）。

**挂账（诚实）**：audit 一共跑了 4 次，其中 **1 次**在 `RLPRequestOpenAlbum()` 进入专辑详情、`Pump(1.0)` 的过程中段错误（exit 139；位置在**专辑详情页导航**，早于任何「正在播放」页面构建，不是本轮新增的分析面板路径），其余 **3 次**均 246/0。该现象未能复现，暂记在账上，后续需要时单独排查。

## 6. 改动的文件（行数）

| 文件 | 变更 |
|---|---|
| `tools/native_ui/RLPNowPlayingViewController.mm` | **+652 / −70**：旧自绘 NSButton 卡 +「藏卡换纯文本」路径 → 子视图卡（`RLPAnlCardView`）、卡片区 `RLPNPAnalBody`、单框分段控件、L1/L2 行排版、滚轮滚动、主题/`hitTest` |
| `tools/native_ui/RLPAnalysisSummary.h` | **+21**：新增 `RLPAnlRowsForCard(health, cardKey, level)` 行模型 API（`sec/row/warn/note` 四类） |
| `tools/native_ui/RLPAnalysisSummary.mm` | **+371**：health→行模型的唯一出口（动态/音质/假无损三卡，L0/L1/L2；含多用例 NA 原因、真峰警告、原始证据；复用既有 `RLPAnlVal/ValFlag/Count` 与 -300 哨兵口径） |
| `tests/test_native_analysis_panel.mm` | **新增 714 行**：红→绿判据（见 §4） |
| `CMakeLists.txt` | **+17**：注册 `native_analysis_panel`（TIMEOUT 120） |
| `evidence/native-analysis-panel-red-20261114.log` | 红日志（29/37） |
| `evidence/native-analysis-panel-green-20261114.log` | 绿日志（129/0） |

**未改**：`src/net/ui_script.h`、`src/net/ui_page.h`（web 侧未动，本轮只对齐 native）、`docs/i18n/*`、`src/net/i18n_table.h`（未新增用户可见文案，全部复用既有键：动态/音质/假无损/判定/采样规格/分析记录/原始证据/判定依据/母带要修/…）、刚提交的 rail 代码、`website/`。

## 7. 剩余 / 风险（如实）

1. **滚动条**：卡片区用 `RLPNPAnalBody` 自绘裁剪 + 滚轮位移（web `#npAnlBody` 是 `overflow-y:scroll` 带覆盖式滚动条）。内容超过面板高度时**可滚动但没有可见滚动条/拖拽**；键盘与触控板都走滚轮事件。若要求「滚条可见」，需下一轮补一个 6px 轨道。
2. **多声道阈值**：按 web `anlCardDyn` 的 `channels>2` 出徽标（本轮任务文字写「channels>1」）。夹具 channels=6，两者都覆盖；channels=2 时不显示「多声道 2 ch」——与 web 一致，但与任务文字的字面口径有 1 处差异，等 Lead 定夺。
3. **卡头点击语义**：与 web 一致为三档循环（收起→指标→全部→收起）；旧 native 是「点卡 = 打开 L1」。行为集合只增不减，判据固定了「从收起点卡 → L1」。
4. **i18n 存量缺口**：`可用性`/`THD+N 方法`/`side/mid` 三个新出现在 native 卡里的标签在 TSV 里没有译文（web 侧同样缺，英文界面回落中文）。本轮按「不新增用户可见文案」处理，未改 i18n 表；要补是独立一轮。
5. **纯视觉未截图的部分**：展开档 L1/L2 只有离屏几何判据（audit 夹具没有 health 数据，`30-nowplaying.png` 只能看到 L0）。L0 截图已人工核对（标题不再截断、状态贴右、分段单框、卡片圆角/内边距正常）；L1/L2 若要做像素级确认，需要造一个带 health 的 audit 夹具或实机点「详细」。
6. **实机未验**：本包内全部是离屏单测 + audit 截图，未在真机 .app 里点过；按项目分工，实机清单留给用户。
7. **audit 偶发段错误**：见 §5 挂账，4 跑 1 崩，未复现。

## 8. Lead 独立复跑（提交前，1.1.7.25）

| 项 | 结果 | 日志 |
|---|---|---|
| `test_native_analysis_panel` | 129 passed / 0 failed（exit 0） | `native-analysis-panel-lead-verify.log` |
| build（version.h 升 1.1.7.25 后全量重编） | exit 0 | `native-analysis-panel-build.log` |
| `—audit`（隔离目录，Lead 跑） | 246 passed / 0 failed（exit 0） | `native-analysis-panel-audit-246.log` |
| 全量 ctest 串行 | **188/188 passed**（370.55s，exit 0） | `native-analysis-panel-lead-ctest-188.log` |
| `native_rail_preview` 回归 | 45/0 | 终端 |

**结论**：本包在 Lead 复跑下绿；audit 段错误未在 Lead 这轮复现（5 跑 1 崩，继续作为 open flake 观察）。
