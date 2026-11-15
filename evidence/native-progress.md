# 原生 UI 修复进度（跨轮次落盘，抗上下文中断）

> 上一轮（11/14 项完成，剩 5/12/8）曾在收尾阶段因**没有任何进度落盘**丢失现场。
> 本轮起每完成一项/一批立即写本文件：已完成项号、提交号、版本号、下一步从哪项开始、当前门禁数字。

## 轮次记录

### 2026-11-13 ~21:45 —— 现场确认轮

**仓库现场**
- HEAD = `af67b84 fix(native): centred badges, frosted bar, real random tokens, 1.1.7.21`
- `src/version.h` = `1.1.7.21`
- 工作树**不干净**，有上一轮中断时的半成品（第 8 项「耳机目标曲线」）：
  - `M CMakeLists.txt`（把 `RLPTargetCurve.mm` 加进 native 源列表）
  - `M tools/native_ui/RLPEqualizerView.mm`（新增 targetCurve 叠加绘制图层）
  - `?? tools/native_ui/RLPTargetCurve.h` / `.mm`（web `TARGET_CURVES` 11 条 + `curveKindOfDetails` / `getTargetCurveDescInfo` 移植）
  - `?? website/`（与本次任务无关的历史目录，**不提交**）
- 判定：**该半成品可以构建**（`cmake --build build-mac -j8` exit 0），不是红状态，
  因此**保留**、作为第 8 项的起点继续完成（已核对其 11 条曲线数据与 web `ui_script.h:10797-10820` 逐值一致，
  分支顺序与 `10823-10836` 一致，属真实移植，不是编造）。
- 该半成品**尚未接线**：`targetCurve` 属性没有任何地方赋值 ⟹ 目前是死代码；也没有测试。
  第 8 项剩余工作 = 桥层修正 + 接线 + 判据 + 证据（详见下）。

**门禁基线（2026-11-13 21:50 实测）**
| 门禁 | 数字 | 结论 |
|---|---|---|
| build | `cmake --build build-mac -j8` exit 0 | 绿 |
| ctest | 181/181 passed, 0 failed（serial，340.66s） | 绿 |
| audit | `rlplayer_native --audit` = **246 passed, 0 failed** | 绿 |
| parity | `parity_scan.py --check` missing=0, removed=1 (1 ok/0 bad), na=16 ok | 绿 |
| behavior | `behavior_scan.py --check` actionable=0（bindings 50） | 绿 |
| i18n | `gen_i18n_table.py --check` = OK (2316 pairs) | 绿 |

**本轮剩余三项的起点（按用户指定顺序）**
1. **第 5 项（未完成）**「AI 整理」栏三张卡片（歌曲/专辑/艺术家）间距与排版对齐 web。
   下次从：`tools/native_ui/RLPNowPlayingViewController.mm` 的 `railPanel` / `railCards`
   与 `src/net/ui_page.h:742-763`（`.nprailcard` / `.npchip*`）几何对照开始。
2. **第 12 项（未完成）** 元数据页「标签写回」并入卡片、整页排版对齐。
   下次从：`RLPSettingsViewController.mm:1745-1790`（当前是 `RLPSGroup` 空卡片 +
   页面并列的 desc/按钮）与 web `ui_script.h:10264-10272`（写在 AI 接入卡片体内）开始。
3. **第 8 项（进行中，半成品可构建）** 耳机目标曲线。
   下次从：`RLPEqualizerView.mm` 的 `onOpraSearch:` / `onOpraProduct:` / `onOpraApply:` 开始。
   已判定（待本轮用判据固定）：
   - ① 桥层**断**：`/api/opra/index` 的 `items` 是 `[id, vendor, name]` **数组三元组**
     （`tools/rtaweb.cpp:11285`），原生按 `NSDictionary` 过滤 ⟹ 搜索结果恒为空；
   - ② 绘制层**断**：半成品已补 targetCurve 图层，但未接线；
   - ③ 字段名**断**：`/api/opra/presets` 返回 `id/author/details/link/gainDb/bandsCount`（无 `name`），
     原生读 `x[@"name"]` ⟹ 预设下拉框恒为空；apply 后 web 还会 `saveSettings(true)` 写回 `eq=path`，原生没写；
   - ④ 时机**断**：选中/应用预设后 web 调 `showTargetCurveInfo(p)` 展示目标曲线说明，原生不展示。

**提交**：本轮暂无新提交（现场确认未改代码）。

**下一步**：完成第 5 项 → 提交 → 更新本文件；再第 12、8 项。

### 2026-11-13 ~23:08 —— 三项全部完成（提交前）

**第 5 项（AI 整理栏三张卡片间距与排版）—— 完成**
- 新判据 `tests/test_native_rail_cards.mm`（ctest `native_rail_cards`），离屏量真实视图树。
- 红：旧码 15 passed / **14 failed**（`native-item5-red-20261113.log`）；
  绿：新码 **56 passed / 0 failed**（`native-item5-green-20261113.log`）。
- 改动 `RLPNowPlayingViewController.mm`：新增 `RLPRailChipView`（dot/name/status/p1/p2 真实子视图），
  内边距 8/10/9、行距 2、圆点 5、圆角 11、栏头字距 1.5，栏内左右 10、栏头→首卡 8、卡片间 6（web .npchip/.nprailcard 逐值）。
- 证据：`evidence/native-item5-20261113.md`（含 web/原生/差值三列表）。
- 遗留（如实）：栏卡片内容仍是本地曲目事实 + 「点开查看」，未把 web 的 AI fields 预览接到栏上（不在几何验收范围）。

**第 12 项（标签写回并入卡片）—— 完成**
- 新判据 `tests/test_native_writeback_card.mm`（ctest `native_writeback_card`），真设置页 + 隔离目录。
- 红：旧码 **3 passed / 1 failed**（结构判据：按钮/说明是 sp_metaadv 页面并列）
  绿：新码 **19 passed / 0 failed**。
- 改动：`RLPSettingsLayout` 新增 `addSubHeader:`/`addNoteView:`；`RLPSettingsViewController` 把
  子标题/说明/两个按钮并回「AI 接入」卡体（web `.mh.sub` 同位置），按钮走卡片通用按钮行。
- 离屏前后对比图：`native-item12-before-20261113.png` / `native-item12-after-20261113.png`。
- **渲染图抓到一个几何判据没抓到的真缺陷**：状态标签塞进横向 stack 把按钮挤扁（已修，记入假绿清单 #9）。
- 证据：`evidence/native-item12-20261113.md`。

**第 8 项（耳机目标曲线）—— 完成**
- 新判据 `tests/test_native_target_curve.mm`（ctest `native_target_curve`），桩客户端驱动真实 UI 动作链。
- 红：旧码 **4 passed / 10 failed**；绿：新码 **22 passed / 0 failed**。
- 四层结论：① 数组三元组不解析（修）② 无 target curve 图层（修，虚线像素判据）
  ③ presets 无 name 字段（修，author·details）+ apply 后写回 settings eq/opraproduct/oprapreset（修）
  ④ 选中/应用后不展示曲线说明（修，opra.info）。
- 附带修两个运行期崩溃：`RLPMutableTargetCurve` 缺 setter、`targetCurve` 误用 `copy` 而曲线未实现 NSCopying。
- web vs 原生请求逐字段 diff：`evidence/native-item8-web-diff-20261113.txt`；
- 证据：`evidence/native-item8-20261113.md`。
- 注意：CMakeLists 给所有链接 `RLPEqualizerView.mm` 的 target 补了 `RLPTargetCurve.mm`（否则链接失败）。

**版本**：`src/version.h` = **1.1.7.22**（三项一批，patch +0.0.1）。

**当前门禁**（本轮最终，见下条提交后的复跑）：
- build：0 error
- ctest：`evidence/native-item5-12-8-ctest-184.log`（184 项；本次运行结果待回填）
- audit / parity / behavior / i18n：提交后复跑并回填。

**下一步**：等 ctest 184 全绿 → 本地提交 → 复跑 audit(246+)/parity/behavior/i18n → 更新本文件 → 出总报告。

### 2026-11-13 ~23:25 —— 提交与最终门禁（全部三项完成）

**提交**：`673f735 feat(native): rail chip geometry, inline writeback, headphone target curve, 1.1.7.22`
（本地提交，**未推送**；`website/` 与本次无关，未提交。）

**最终门禁（2026-11-13 23:20 实测）**
| 门禁 | 数字 | 证据 |
|---|---|---|
| build | `cmake --build build-mac -j8` = **0 error**（含全部 target 链接） | `evidence/native-final-audit.log` 同轮构建 |
| ctest | **184/184 passed, 0 failed**（357.05s，serial） | `evidence/native-item5-12-8-ctest-184.log` |
| audit | **246 passed, 0 failed**（exit 0） | `evidence/native-final-audit.log` |
| parity | ctrl done=180 **missing=0** removed=1；api done=96 missing=0 na=16（16 ok/0 bad；removed 1 ok/0 bad） | 终端输出 |
| behavior | actionable=0（bindings 50） | 终端输出 |
| i18n | OK (2316 pairs) | 终端输出 |

**收尾状态**：14 项中 11 项为上一轮完成、3 项（5/12/8）本轮完成并各自红→绿；
三项证据：`native-item5-20261113.md`、`native-item12-20261113.md`、`native-item8-20261113.md`；
假绿清单从 8 条增至 **11 条**（新增 #9 几何全绿≠渲染正确、#10 属性存在≠功能接入、#11 编译绿≠运行绿）。

**下一步（交用户/下一轮）**：实机验收清单见总报告 §5；第 1 项根因仍未定位（需用户导出诊断包）。

### 2026-11-14 00:0x —— task-3 开始（设置页卡片归位 + 反馈/诊断摘要）

**现场**：git main，`e40fde4`(docs) / `673f735`(feat)，工作树仅 `?? website/`；`src/version.h` = 1.1.7.22。
**基线门禁（本轮实测，全绿后才改）**
| 门禁 | 数字 | 证据 |
|---|---|---|
| build | `cmake --build build-mac -j8` exit 0 | 终端 |
| ctest | 184/184 passed, 0 failed（344.17s serial） | 终端 |
| audit | 246 passed, 0 failed | `evidence/native-3-baseline-audit.log` |
| parity | missing=0 / removed 1 ok / na 16 ok | `evidence/native-3-baseline-parity.log` |
| behavior | actionable=0（bindings 50） | `evidence/native-3-baseline-behavior.log` |
| i18n | OK (2316 pairs) | `evidence/native-3-baseline-i18n.log` |

**任务**：A 逐页卡片归位；B 元数据 AI 接入/联网检索归卡；C 反馈就地发送（不弹窗、真探活/真 POST）；
D 诊断摘要只复制+就地提示（去掉 JSON 面板；不恢复「随反馈上传诊断」）。

### 2026-11-14 00:55 —— task-3 A/B/C/D 完成（提交前）

**判据红→绿（同一份用例，旧码 HEAD `e40fde4` 跑红，新码跑绿）**
| 项 | 用例 | 旧码 | 新码 | 证据 |
|---|---|---|---|---|
| A/B | `test_native_settings_cards`（ctest `native_settings_cards`，80 checks） | **39 passed / 41 failed** | **80 passed / 0 failed** | `native-3-settings-cards-red.log` / `-green.log` |
| C/D | `test_native_feedback_inline`（ctest `native_feedback_inline`，40 checks） | **12 passed / 22 failed** | **40 passed / 0 failed** | `native-3-feedback-red.log` / `-green.log` |

旧码红的具体证据（截取）：输入页 `sp_instart` 出现 2 次（卡片内外各一套）、`采集实时状态` 空壳卡；
输出页 `sp_upnp_dev/sp_upnp_scan/sp_upnp_msg/sp_backendmsg/sp_trimchmsg` 全部页面并列、
`声道音量微调` 空壳且 2 声道控件 count=0；流媒体两张卡都是空壳（表单/按钮在页面级）；
元数据 `llm.modelpopup/modelrefresh/modelmsg/save/test/clear/status` + `search.save/clear/status` 页面并列；
EQ/校准页 cards=0；诊断 `sp_vercur/updcheck/updinstall/updmsg/updbar/updnote` 页面并列；
C：点发送后窗口 1→2（标题「反馈」）、无 POST、通道永远「正在检查…」、摘要 JSON 面板仍在。

**实现要点**
- `RLPSettingsViewController.mm`：10 个设置页全量把控件改走卡片 API（addField/addWideField/addButtonRow/
  addFullRow/addNoteView）；输出页 UPnP 整行（含标签）归「输出后端」卡、按后端显示/隐藏；「声道音量微调」
  按实际声道数生成 NSSlider（默认 2，改 6/8 重建，accent 色）；元数据 AI 卡（模型/刷新/状态/按钮）+ 联网检索卡；
  流媒体服务器/投放子视图、EQ/校准子视图均作卡片体整行；诊断页更新行全部归「软件更新」卡。
- `RLPInputView`：新增 **statusOnly** 模式（只保留「采集实时状态」），旧码卡片外那整套重复采集控件消失；
  输入页「刷新设备」移入卡片；开始采集请求体恢复 web 语义 `mode/dev(id)/seconds/out`（旧码空 body 丢功能）。
  旧视图独有的 `mode=null`「空跑（不开设备）」没有随重复控件删掉，用同卡开关 `sp_innull` 保留（铁律①）。
- C：`onSendFeedback:` 就地发送（`onOpenFeedback:` 弹窗路径从设置页移除，弹窗类保留在菜单入口不删功能）；
  `probeFeedbackChannel` 真探活（watchdog 200+ok、12s 兜底、失败显示原因+重试）；成功/失败/字数文案逐字对齐 web；
  计数 `0 / 16384 字节` 且上限从 web 源码 `FB_MAX_BYTES` 机器抽取比对。
- D：删除 `sp_diagsummarytext`/`sp_diagscroll`，`onDiagSummary:` 只复制+就地「摘要已复制」；
  `parity_removed.tsv` 登记 `ctrl sp_diagsummarytext`（removed 1→2，双向核验通过）。未恢复「随反馈上传诊断」。

**门禁（提交前，2026-11-14 00:55）**
| 门禁 | 数字 | 证据 |
|---|---|---|
| build | `cmake --build build-mac -j8` exit 0 | 终端 |
| ctest | **186/186 passed, 0 failed**（354.36s serial；含两条新用例） | `evidence/native-3-ctest.log` |
| audit | **246 passed, 0 failed** | `evidence/native-3-audit.log` |
| parity | missing=0 removed=2 na=16（removed 2 ok/0 bad） | `evidence/native-3-baseline-parity.log` 同命令 |
| behavior | actionable=0（bindings 50） | 同命令 |
| i18n | OK (2316 pairs) | 同命令 |

**证据文件**：`evidence/native-3-settings-cards-20261114.md`（含红→绿、web 结构对照、如实挂账）；
逐页对比图 `evidence/native-3-compare-*.png`；修复后离屏截图 `evidence/native-3-shots/`；旧码同页图 `-before/`。

**下一步**：本地提交 → 提交后复跑 audit/parity/behavior/i18n → 回填提交号 → 出总报告（不推送、不发版）。

### 2026-11-14 01:00 —— 提交与最终门禁（task-3 完成）

**提交**：`024918c feat(native): settings cards contain controls, inline feedback, copy-only diag summary, 1.1.7.23`
（本地提交，**未推送**；`website/` 与本次无关，仍未提交。）

**最终门禁（提交后实测）**
| 门禁 | 数字 | 证据 |
|---|---|---|
| build | `cmake --build build-mac -j8` exit 0 | 终端 |
| ctest | **186/186 passed, 0 failed**（353.46s serial） | `evidence/native-3-ctest.log` |
| audit | **246 passed, 0 failed** | `evidence/native-3-final-audit.log` |
| parity | missing=0 / removed=2（2 ok / 0 bad）/ na=16 ok | `evidence/native-3-final-parity.log` |
| behavior | actionable=0（bindings 50） | `evidence/native-3-final-behavior.log` |
| i18n | OK (2316 pairs) | `evidence/native-3-final-i18n.log` |

**收尾**：A/B/C/D 四项全部完成并各自红→绿（数字见 §00:55 表）；
证据汇总 `evidence/native-3-settings-cards-20261114.md`，逐页对比图 `native-3-compare-*.png`。
**下一步（交用户）**：实机验收（见报告 §5）；真实反馈 POST 未真发（测试接缝抓包验证端点/请求体/回包）。

### 2026-11-14 04:10 —— 轮次 1（1.1.7.24）：AI 整理右栏内容预览（web npRailPreview 移植）

**现场**：基线 `938d50f`（1.1.7.23）；门禁全绿后开改（ctest 186/186、audit 246/246、parity missing=0、behavior 0、i18n 2316）。
**任务**：右栏三卡 = web 的真实内容预览（不是本地事实占位）；点击卡打开正确实体（旧码 `b.tag` 恒 0，专辑/艺术家卡都打开歌曲）。

**红→绿**：新 ctest `native_rail_preview`（45 条，桩客户端）旧码 **8P/37F** → 新码 **45P/0F**；
日志 `evidence/native-rail-preview-red-20261114.log` / `-green-20261114.log`；Lead 独立复跑 45/0。

**实现**：取数闸门（meta.summaryEnabled+可用/key）、三实体目标、web 同形 summary URL、
pending 轮询（150-2000ms/120s）、URL 缓存+单飞、insufficient 终局态、五态状态短语、
track/release/person 预览逐分支（含本地兜底与 npLocalAlbum）、详细档（pick 4、简介不截断、
p1 5 行/p2 2 行、卡高实测）、档位持久化（`RLPNPRailDetail`）。

**门禁（提交前）**：build 0 error；ctest **187/187**（366s，`native-rail-preview-ctest-187.log`）；
audit **246/0**（`native-rail-preview-audit-246.log`）；parity missing=0 removed=2 na=16 ok；
behavior actionable=0；i18n **2318 pairs**。

**证据**：`evidence/native-rail-preview-20261114.md`；前后图 `native-rail-before/after-20261114.png`。
**如实挂账**：第 4 张「作品」卡、抽屉 vs 气泡、`npSummHint`/`nprailempty` 未做。

**下一步**：轮次 2 = 正在播放页「音频分析」面板对齐 web（单分段控件/卡片排版/展开后指标网格）。

### 2026-11-14 05:42 —— 轮次 2（1.1.7.25）：正在播放音频分析面板 = web #npAnal

**现场**：基线 `2b88e1d`（1.1.7.24）；全绿后开改。任务：头部独立小标题+单框分段控件+右对齐状态；
摘要卡 10.5/700 kern .8、摘要 11.5/1.45、内边距 7/9/8、按文本长高、多声道徽章；展开档保留三卡、
卡内 2 列标签-值指标网格（替代旧「藏卡+纯文本」）。

**红→绿**：新 ctest `native_analysis_panel`（129 条）旧码 **29P/37F** → 新码 **129P/0F**；
日志 `native-analysis-panel-red-20261114.log` / `-green-20261114.log`；Lead 独立复跑 129/0。

**实现**：`RLPAnalysisSummary` 新增 health→行模型 API（sec/row/warn/note，L0/L1/L2，复用既有 NA/-300 口径）；
`RLPNowPlayingViewController` 新 `RLPNPAnalBody` 卡区 + `RLPAnlCardView` 子视图卡 + 单框分段 + 卡内网格排版 + 滚轮滚动；
旧自绘 NSButton 卡与「展开藏卡换文本」路径移除；无 health 的等价文本解释保留。

**门禁（提交前，Lead 复跑）**：build 0 error（`native-analysis-panel-build.log`）；
ctest **188/188**（370.55s，`native-analysis-panel-lead-ctest-188.log`）；
audit **246/0**（`native-analysis-panel-audit-246.log`）；parity missing=0 removed=2 na=16 ok；
behavior actionable=0；i18n OK（2318）。

**证据**：`evidence/native-analysis-panel-20261114.md`。
**如实挂账**：卡区无可见滚动条；多声道徽章按 web channels>2（任务文字写 >1，取 web）；
i18n 存量缺「可用性/THD+N 方法/side-mid」；L1/L2 仅离屏几何（无 health 截图）；
audit 5 跑中 1 次在专辑详情导航处偶发段错误（未复现，其余 246/0）；实机未验。

**下一步**：轮次 3 = 曲目页行几何/格式列对齐 web `.trow-track`。

### 2026-11-14 06:07 —— 轮次 3（1.1.7.26）：曲目页行几何/内容 = web `.trow-track`

**现场**：基线 `36ce2fa`（1.1.7.25）；门禁全绿后开改。任务：7 格列（序号/心形/标题/`artist — album` 合并格/
规格/时长/+）、断点列宽、行高 34、去列头、规格 `fmtTag`。
**实现**：`RLPTracksViewController.mm` 7 列 + 三档响应式（>1400 / 1121-1400 / ≤1120）+ 行高 34 + 字号 12.5/11.5/9.5
+ 合并艺术家格（U+2014）+ 规格列（96k/24）+ `headerView=nil` + 心形/+ 行为保留。

**红→绿**：新 ctest `native_tracks_rows` 旧码 **20P/70F** → 新码 **109P/0F**；
日志 `native-tracks-rows-red-20261114.log` / `-green-20261114.log`。
**审查修正**：旧判据用 `table.bounds.width` 算剩余宽，但 plain style 尾部多 8pt gap ⟹ 恒差 8；
改为用「列和+可见列间隙=内容宽」计算（非改生产迁就判据）。

**门禁**：build 0 error；audit **246 passed / 0 failed**（`native-tracks-rows-audit-246.log`）；
ctest 结果回填中；parity/behavior/i18n 待回填。
**证据**：`evidence/native-tracks-rows-20261114.md`。
**如实挂账**：规格列仅表格宽 >1400 可见（web 媒体查询同口径）；离屏单测，实机未验。

**下一步**：轮次 4 = 正在播放 npMeta 芯片行（web badge 规格 + EQ/IR 芯片 + 推送/加歌单）。

### 2026-11-14 06:52 —— 轮次 4（1.1.7.27）：正在播放页 #npMeta 芯片行 = web

**现场**：基线 `b894c12`（1.1.7.26）；全绿后开改。
**任务**：徽标 `.badge` 逐值（9.5/600/kern.3/radius5/acc-weak/ok-*）、EQ/IR 芯片（settings.kv.eq/ir）、
投放/加歌单移入同一行、enriched=false 不再整行隐藏、flex-wrap（窄宽不重叠/行高增长/按钮行下移）。

**红→绿**：新 ctest `native_npmeta_chips`（83 条）旧码 **19P/16F** → 新码 **83P/0F**；
日志 `native-npmeta-chips-red-20261114.log` / `-green-20261114.log`；Lead 独立复跑 83/0。

**门禁（提交前，Lead 复跑）**：build 0 error（`native-npmeta-chips-build.log`）；
ctest **190/190**（362.58s，本轮 writer 日志；Lead 提交后复跑回填）；
audit **246/0**（`native-npmeta-chips-audit-20261114.log`）；parity missing=0 removed=2 na=16 ok；
behavior actionable=0；i18n OK（2318）。

**证据**：`evidence/native-npmeta-chips-20261114.md`。
**如实挂账**：投放运行态（已推送到 X/点击停止）未移植；芯片无 SVG 图标；<900px 不可达；
web max-height:720 的 margin 未移植；实机未验。

**下一步**：轮次 5 = 队列页排序 8 档（含 CUE 区间保真与行播放）。
（Lead 提交前复跑：ctest **190/190**，378.69s，`native-npmeta-chips-lead-ctest-190.log`；audit Lead 复跑 **246/0**。）

### 2026-11-14 07:18 —— 轮次 5（1.1.7.28）：队列页排序 8 档 + CUE 区间保真

**现场**：基线 `6d2d45d`（1.1.7.27）。原派发子代理在写文件前失败（工作树零残留），本包由 Lead 直接实现。
**任务**：web #qSort 8 档（默认/标题/艺术家/专辑/时长/年份/随机打乱/反转）语义 + 按钮文案
+ qorder 行保留 `\tcs\tce` + 行播放 `RLPPlayPathCue(path,cs,ce)` + cues 解析。

**红→绿**：新 ctest `native_queue_sort`（56 条）旧码 **21P/25F** → 新码 **56P/0F**；
日志 `native-queue-sort-red-20261114.log` / `-green-20261114.log`；Lead 本人跑红绿。

**门禁**：build 0 error；ctest / audit / parity / behavior / i18n 由最终门禁统一复跑回填。
**证据**：`evidence/native-queue-sort-20261114.md`。
**如实挂账**：队列行布局（.qrow 文件夹名/悬停×/行高 38/border-bottom）未移植，留作下一包；实机未验。

**下一步**：轮次 6 = 队列行布局（web `.qrow`）或最终门禁收口。

### 2026-11-14 07:29 —— 轮次 6（1.1.7.29）：队列页行布局 = web `.qrow`

**现场**：基线 `7fe9a65`（1.1.7.28）。本包由 Lead 直接实现。
**任务**：4 列（序号 26/标题 flex/父文件夹名 ≤38%/× 24）、行高 38、去列头、当前行 accent-weak+标题 accent、
× 仅行悬停可见、底部分隔线。

**红→绿**：新 ctest `native_queue_rows`（29 条）旧码 **4P/13F** → 新码 **29P/0F**；
日志 `native-queue-rows-red-20261114.log` / `-green-20261114.log`；Lead 本人跑红绿（含一次 hoveredRow 初值 -1 的修正）。

**门禁**：build 0 error；全量 ctest（192 项）/audit/parity/behavior/i18n 由最终门禁统一复跑。
**证据**：`evidence/native-queue-rows-20261114.md`。
**如实挂账**：底部分隔线为绘制实现、无像素判据；实机未验。

**下一步**：最终门禁收口 + 汇总报告（若时间仍足，再看剩余差异清单里的小包）。

### 2026-11-14 07:50 —— 轮次 7（1.1.7.30）：专辑页/文件夹页空态 = web

**现场**：基线 `924a03f`（1.1.7.29）。本包由 Lead 直接实现。
**任务**：0 张专辑时空态卡（无 roots / 有 roots 两套文案 + 三个入口：管理目录/扫描/快速开始）
+ 文件夹空目录「此目录没有音频文件」。
**红→绿**：新 ctest `native_empty_states`（17 条）旧码 **0P/14F** → 新码 **17P/0F**；
日志 `native-empty-states-red-20261114.log` / `-green-20261114.log`。
**门禁**：build 0 error；全量 ctest（193）/audit/parity/behavior/i18n 由最终门禁复跑。
**证据**：`evidence/native-empty-states-20261114.md`。
**如实挂账**：空态卡未走像素样式判据；窄窗 520 宽未自适应（主窗口最小 900，不可达）。

### 2026-11-14 08:08 —— 轮次 8（1.1.7.31）：AI 整理栏空态 + 状态行 = web

**现场**：基线 `f5e144c`（1.1.7.30）。本包由 Lead 直接实现。
**任务**：无 AI 栏目时 3 卡不显示 + `nprailempty` 整块说明；歌曲资料 `npSummHint`
（loading/insufficient/error 可点重试/ok 隐藏）。
**红→绿**：新 ctest `native_rail_states`（17 条）旧码 **2P/5F** → 新码 **17P/0F**；
日志 `native-rail-states-red-20261114.log` / `-green-20261114.log`。
**门禁**：build 0 error；全量 ctest（194）/audit/parity/behavior/i18n 由最终门禁复跑。
**证据**：`evidence/native-rail-states-20261114.md`。
**如实挂账**：状态行放栏底（web 流式在其后）；无像素判据；实机未验。

### 2026-11-14 08:30 —— 轮次 9（1.1.7.32）：投放芯片运行态 = web

**现场**：基线 `52a8428`（1.1.7.31）。本包由 Lead 直接实现。
**任务**：live 期 2s 读 `/api/cast/state`；running → chip「已推送到 host」+ ok 三令牌，
点击 = `/api/cast/stop` + toast；否则「推送到设备」+ 原设备列表。
**红→绿**：新 ctest `native_cast_chip`（10 条）旧码 **1P/1F** → 新码 **10P/0F**；
日志 `native-cast-chip-red-20261114.log` / `-green-20261114.log`。
**门禁**：build 0 error；全量 ctest（195）/audit/parity/behavior/i18n 由最终门禁复跑。
**证据**：`evidence/native-cast-chip-20261114.md`。
**如实挂账**：设备名仅 host 回落（未额外拉设备表）；轮询固定 2s；实机投放未验。

### 2026-11-14 08:41 —— 最终门禁（1.1.7.32，9 包收口）

| 门禁 | 数字 | 证据 |
|---|---|---|
| build | `cmake --build build-mac -j8` exit 0 | 终端 |
| ctest | **195/195 passed, 0 failed**（373.95s 串行） | `evidence/native-final-ctest-195.log` |
| audit | **246 passed / 0 failed**（隔离目录） | `evidence/native-final-audit-246-32.log` |
| parity | ctrl done=179 / api missing=0 / removed=2（2 ok）/ na=16（16 ok） | `/tmp/final-parity.log` |
| behavior | actionable=0（bindings 50） | `/tmp/final-behavior.log` |
| i18n | OK（2318 pairs） | `/tmp/final-i18n.log` |

**本轮 9 个包（1.1.7.24 → 1.1.7.32，每包 feat+docs 两本地提交，共 18 个提交；未推送/未发版）**：
① 右栏 AI 摘要与点击实体修正；② 音频分析 #npAnal；③ 曲目页 `.trow-track`；
④ #npMeta 芯片行；⑤ 队列排序 8 档 + CUE 保真；⑥ 队列 `.qrow` 行；
⑦ 专辑/文件夹空态；⑧ 右栏 `nprailempty`/`npSummHint`；⑨ 投放芯片运行态。
新增 9 个 ctest 全部旧码先红后绿；证据文件见 `evidence/native-*-20261114.md`。

**遗留风险（如实）**：离屏审计套件 `native_ui_functional` 在 5 次全量 ctest 中出现过 **2 次** bus error
（均在专辑详情导航处，单跑/换轮重跑均通过；未能复现，记为既有 open flake）。
**未做**：古典第 4 卡/抽屉 vs 气泡、OPRA 预设卡片墙、chip SVG 图标、默认渲染器切换、双模式层；
playback RENDERFAIL 根因仍需用户诊断包。实机验收由用户执行。

**稳定性复跑（1.1.7.32 同树）**：ctest **195/195**（361.65s，`final-ctest-195-rerun`）；audit **246/0**（第二次）；
即最终树连续两次全量 ctest 与两次 audit 全绿。此前 1.1.7.29 阶段 5 次全量 ctest 有 2 次
`native_ui_functional` bus error（专辑详情导航处；单跑与换轮重跑均通过，未复现，按 open flake 记录）。

### 2026-11-14 12:xx —— 本轮 P0/P1/P2 四包（1.1.7.33 → 1.1.7.36）

| 包 | 版本/提交 | 内容 | 判据（旧码红 → 新码绿） |
|---|---|---|---|
| P0-1 | 1.1.7.33 `5a7b950` | 播放/暂停三入口统一判定；媒体键显式 pause/resume；停止态重播 | `native_pause_paths` 8/8 → 16/0 |
| P0-2 | 1.1.7.34 `3419fa3` | 诊断包默认预算 12→7.5 MiB；真实 ZIP 7,605,710 B ≤ 8 MiB；原生导出校验 PK/大小并显示真实 MB | `test_diag_bundle` 103/3 → 106/0 |
| P1 | 1.1.7.35 `201235b` | OPRA 型号卡片 + 预设卡片墙（曲线小图/作者·详情/段数/前级/应用/当前态） | `native_opra_cards` 1/6 → 16/0；`native_target_curve` 21/0（更新为新入口） |
| P2 | 1.1.7.36 本包 | EQ/IR/投放/加歌单芯片图标（SF Symbol 11×11，宽度补 15pt） | `native_npmeta_chips` 84/2 → 86/0 |

**门禁（最终树 1.1.7.36，串行/machine idle）**：见 `evidence/native-chip-icons-20261114.md` 与各包证据。
**open flake**：1.1.7.35 第一次全量 ctest 中 `native_ui_functional` bus error 一次（专辑详情导航处），
单跑 `--audit` 246/0、第二次全量 ctest 通过；历史上同类 2/5。未修。
**未做**：古典第 4 张「作品」卡、抽屉 vs 气泡、默认渲染器切换、双模式薄表现层；
playback RENDERFAIL 根因仍需用户诊断包。实机验收由用户执行（清单见 `evidence/native-loop-gaps-20261114.md`）。
**工作树说明**：本轮收尾时工作树另有**别的写者**留下的 ego 通道注释/文档改动（`src/net/ui_page.h`、
`src/net/ui_script.h`、`tools/rtaweb.cpp`、`tools/check_b10_*.js`、`tools/README.md`、`docs/native-ui/PLAN.md`、
`evidence/native-3-settings-cards-20261114.md`），全是注释/文档、未进本轮任何提交，也不改变构建行为。

### 2026-11-14 14:20 —— 轮次 10（1.1.7.37）：原生文案进 i18n 词表

**现场**：基线 `371883b`（1.1.7.36）。全量 ctest 197/197、audit 246/0（4 轮里 1 轮 SIGBUS，见下）为基线。
**任务**（task-4 · 设置页已知差异④）：新增短文案走 `RLPTr` 回退、未进 i18n 表。
**红→绿**：新判据 `tools/check_native_i18n_coverage.py`（ctest `native_i18n_coverage`）
旧码 **101 条**中文文案无英文译文 → 新码 **0 条**（1599 处字面量全覆盖）。
另一条既存红：`gen_native_i18n.py --check` 旧码 FAIL（2 条漂移）→ 新码 OK。
**门禁**：build 0 error；全量 ctest **199/199**（409.14s，197 基线 + 本包 2 条新门禁）。
**证据**：`evidence/native-task4-i18n-20261114.md`、`native-i18n-coverage-red-20261114.log`。
**如实挂账**：判据只覆盖字面量；97 条英译新译未母语校对；英文界面未实机验证。

**同轮基线发现（挂账，下一包修）**：`rlplayer_native --audit` 本轮第 1 次运行
**EXIT=138 SIGBUS**（4 次里 1 次），崩溃报告存 `evidence/native-audit-sigbus-140145.ips`：
栈在 `_platform_memmove ← std::string::assign ← rta::update::CheckResult::operator= ←
-[RLPUpdateWindowController handleCheckResult:manually:]`。**不是**此前记的"专辑详情导航处"。
根因（已用最小探针证实）：done 回调参数是 `const CheckResult&`，窗口控制器直接把它
`dispatch_async` 到主队列 —— block 捕获 `const T&` 参数是**引用捕获**，
回调返回后生产者对象已析构 ⟹ 主线程读已释放堆缓冲。下一包修。

### 2026-11-14 14:40 —— 轮次 11（1.1.7.38）：audit 偶发 SIGBUS = 更新结果跨线程所有权

**根因**：`begin_check` 的 done 回调参数是 `const CheckResult&`，窗口控制器直接
`dispatch_async` 到主队列 —— block 捕获 `const T&` 参数是**引用捕获**（最小探针实测段错误），
回调返回后生产者已析构 ⟹ 主线程读已释放堆缓冲（notes 长串）。崩溃报告栈落在
`CheckResult::operator=` → `std::string::assign` → `memmove`。**不是**此前挂账的"专辑详情导航处"。
**修复**：跳线程前 `make_shared<CheckResult>(r)` 深拷贝，block 持 shared_ptr。
**红→绿**：新 ctest `native_update_result_lifetime` 旧实现 **3P/2F** → 新实现 **5P/0F**。
**稳定性**：修复后**连续 4 轮** `--audit` 全绿（246/0 ×4）；修复前基线 4 轮崩 1 轮。
**如实挂账**：4 轮是小样本，不宣称"概率归零"；ProgressFn 同形但用法安全，未加判据。
**本包门禁（1.1.7.38 树）**：build 0 error；串行全量 ctest **200/200 passed（386.04s）**；
audit 修复后连续 4 轮 246/0；parity missing=0；behavior actionable=0；i18n OK。
**提交**：`524ae0e` fix(native): own the update check result before hopping to main thread，1.1.7.38。
**下一步**：`native_settings_granularity`（EQ 两卡 / cal 三卡 + sp_eq/sp_ir/sp_irgpu 真控件）红→绿 → 1.1.7.39。

### 2026-11-14 15:25 —— 轮次 12（1.1.7.39）：设置页卡片粒度（EQ 两卡 / cal 三卡 + `sp_eq`/`sp_ir`/`sp_irgpu` 真控件）

**现场**：基线 `61d2470`（1.1.7.38 文档提交，代码树 = `524ae0e`）。工作树里另有别人留下的 ego 通道注释/文档改动，
本轮**一个都没 stage**（`src/net/ui_page.h`、`src/net/ui_script.h`、`tools/rtaweb.cpp`、`tools/check_b10_*.js`、
`tools/README.md`、`docs/native-ui/PLAN.md`、`evidence/native-3-settings-cards-20261114.md`，及未使用的
`RLPSettingsLayout` 列宽参数 WIP）。
**任务**（task-4）：EQ 页拆 web 的两卡（参数均衡 / 耳机 EQ）；cal 页拆三卡；`sp_ir`/`sp_irgpu` 必须是真控件
（旧码只有 identifier 字面量 ⟹ parity 假绿）；新增 `sp_eq` 路径输入并落 `/api/settings` 的 `eq` 字段。
**判据**：新 ctest `native_settings_granularity`（`tests/test_native_settings_granularity.mm`，23 条断言）：
两卡/三卡结构与标题逐字、控件归属卡体、`sp_eq` 宽度>20、`sp_irgpu` 是 `NSSwitch`、
改 `sp_eq` 后 `kv.eq` 真的变、`irgpu` 打开后 `kv.irgpu=1`、页签内无第二条可见滚动条。
**红→绿**：旧码（1.1.7.38 二进制）**6 passed / 15 failed**（2 条行为判据因控件缺失跳过）→ 新码 **23 passed / 0 failed**。
证据 `evidence/native-settings-granularity-red-20261114.log` / `-green-…log`、报告 `evidence/native-settings-granularity-20261114.md`。
**过程中修掉一个真崩溃**：`buildOpraSection` 在 `opraInfo` 尚未入 hierarchy 时激活「宽=容器宽」约束 ⟹
AppKit `NSGenericException: no common ancestor`（离屏测试第一次跑直接 abort），已改为先 `addArrangedSubview` 再激活。
**如实挂账**：①判据「单层滚动」最初把页签根（它自己就是整页滚动容器）和 20 段表的固定高度 NSTableView
包装也算成嵌套 ⟹ EQ 半条是**假红**，已改定义（只数 `hasVerticalScroller/hasHorizontalScroller` 为真的嵌套滚动容器，
排除页签根）；cal 半条是真差异（旧 cal 视图自带 `hasVerticalScroller=YES`）。②`sp_ir` 的 `ir` 字段写回未单独立断言
（`sp_eq`/`sp_irgpu` 有行为判据）。③声道音量微调仍是 `NSSlider`（web 是 number 输入），本轮未动。
**i18n**：新控件占位文案 1 条新翻译进 `docs/i18n/chunk-native117.en.tsv` 并重生成两张表（2416 pairs）。
**门禁（1.1.7.39 树）**：build 0 error；串行全量 ctest **201/201 passed（403.47s）**；audit **246/0**；
`parity_scan --check` missing=0；`behavior_scan --check` actionable=0；`gen_i18n_table --check` / `gen_native_i18n --check` OK。
**提交**：`feat(native): split settings EQ/cal into web card granularity`，1.1.7.39（仅本地）。
**下一步**：播放页 `#np` 对照表（`evidence/native-4-playback-diff.md`，69 条）→ 按表逐项红→绿。

### 2026-11-14 15:3x —— 轮次 12b（1.1.7.40）：播放页 `#npKind` 停止/切曲状态机

**任务**（task-4 · 播放页差异表 #12/#60）：`#npKind` 文案 = web `npPlayingKindText(curMeta)`，
停止/切曲必须复位，不许挂上一首的 `正在播放 · FLAC / 48 kHz / 24 bit`。
**判据**：`tests/test_native_nowplaying_web.mm` 追加 3 条，走真实 `/api/status → refresh → 渲染`
（替身 `RLPCoreClient` 新增 fixture 表 + `getData:` 应答；缺后者时测试直接 SIGABRT，属工装缺陷已修）。
**红→绿**：旧码 **18P/2F**（新 3 条里 2 条红：停止复位、切曲复位）→ 新码 **21P/0F**。
**实现**：`refresh` 切曲分支先复位 `kindLabel`；meta 格式串改「有字段才拼 ` · `」（旧码无效时挂尾 ` · `）。
**证据**：`evidence/native-playback-states-20261114.md`、`native-playback-state-{red,green}-20261114.log`；
对照表状态列已把 #12/#60 标为「已修（1.1.7.40）」。
**门禁（1.1.7.40 树）**：build 0 error；串行全量 ctest **201/201 passed（398.09s）**；audit **246/0**；parity missing=0；behavior actionable=0；i18n OK。

### 2026-11-14 15:5x —— 轮次 12c（1.1.7.41）：播放模式图标随档位 + `#npRepOne` 角标

**任务**（task-4 · 播放页差异表 #51/#52）：web `applyRep(v)` 四档换图标（`REP_ICON[0..3]`）+ 单曲循环显示
`#npRepOne` 的「1」角标；web 注释明写「只改颜色不改图标是明令禁止的假修」。原生整页循环键固定 `repeat`、
无档位指示（用户看不出当前模式）。
**判据**：`tests/test_native_nowplaying_web.mm` 追加 12 条：4 档 `playModeSymbol` 映射
（`arrow.right`/`repeat`/`repeat.1`/`shuffle`）、4 档角标可见性（只有单曲循环可见）、四档图标互异、角标文字=1。
**红→绿**：旧码（1.1.7.40）12 条里 **10 F**（只有「`np.rep` 存在」「mode=2 时不可见」两条碰巧成立）→
新码 **33 passed / 0 failures**（21 条既有 + 12 条新）。
**实现**：`RLPNPControlBar` 新增 `repBadge`（identifier `npRepOne`，10pt/700，默认 hidden，布局在循环键右上角）；
`RLPNowPlayingViewController -applyPlayModeUI` 按 `playbackMode` 选 SF Symbol + web `REP_META[].aria` tooltip +
单曲循环才显角标；`onCycleMode`、`/api/queue` 读回（`refreshQueueContext`）、`buildContent` 末尾三处调用。
**如实挂账**：原生用 SF Symbol（`arrow.right`/`repeat`/`repeat.1`/`shuffle`），不是 web 的四条 SVG 路径
（造型非 1:1，档位/语义对齐）；底部播放条的独立随机/循环键未动。
**证据**：`evidence/native-playback-states-20261114.md`、`native-playback-mode-{red,green}-20261114.log`；
对照表 #51/#52 标「已修（1.1.7.41）」。
**门禁（1.1.7.41 树）**：build 0 error；串行全量 ctest **201/201 passed（392.91s）**；audit **246/0**；parity missing=0；behavior actionable=0；i18n OK。

### 2026-11-14 16:0x —— 轮次 12d（1.1.7.42）：面板内置收起键 `#npAnalHide` / `#npRailHide`

**任务**（task-4 · 播放页差异表 #27/#34）：web 的 `#npAnal` 面板头右上有一枚 `.anlhide`
（`position:absolute;top:7;right:8`、22×22 圆形、`‹`），`#npRail` 栏头有 `.nprailhide`（22×22、`›`）；
两枚键与右上角 `#npAnalToggle`/`#npRailToggle` 写**同一份**隐藏状态。原生 1.1.7.41 只有右上角总开关，
面板头部没有这两枚键（元素缺失）。
**判据**：`tests/test_native_nowplaying_web.mm` 追加 9 条：两枚键存在、各 22×22、分析面板这枚是圆形
（cornerRadius≥10.5）、点 `npAnalHide` 后 `analysisPanel.hidden` 且 `RLPNPAnalysisHidden=YES`、
点 `npRailHide` 后 `railPanel.hidden` 且 `RLPNPRailHidden=YES`；测后复位。
**红→绿**：旧码（1.1.7.41）**2 F**（两枚键都不存在，其余 7 条因控件缺失跳过）→ 新码 **42 passed / 0 failures**
（33 条既有 + 9 条新）。
**判据修正（如实披露）**：补上 `.anlhide` 后既存 `test_native_analysis_panel` 两处期望值 **13** 变红
（实测 37，diff +24）。核对 web：`.anlheadtop{padding-right:26px}`（1.1.4-beta6 起就有，正是给 `.anlhide` 留位）
+ `#npAnlStat{padding-right:2}` + 面板内边距 11 ⟹ 应为 **37**；旧值 13 是原生还没有收起键时的近似（漏算 26）。
本包把两处期望改为 37 并注明来源，另新增「收起键不压住状态文字」断言。首次全量 ctest 因此只有
`native_analysis_panel` 一项红（200/201），修正判据后复跑 **201/201**。
**实现**：两个面板头部各建一枚 22×22 圆形 `NSButton`（identifier 用 web 的 `npAnalHide`/`npRailHide`，
SF Symbol `chevron.left`/`chevron.right`）；动作 = 隐藏 + 写同一 `NSUserDefaults` 键 + 重新布局（不切换，
重新显示仍走右上角总开关，与 web 语义一致）；分析面板状态文字让出 26pt，栏头分段控件为收起键让出 30pt。
**证据**：`evidence/native-playback-states-20261114.md`、`native-playback-hidekeys-{red,green}-20261114.log`、
`evidence/native-42-ctest.log`、`native-42-audit.log`；对照表 #27/#34 标「已修（1.1.7.42）」。
**门禁（1.1.7.42 树）**：build 0 error；串行全量 ctest **201/201 passed（377.01s）**；audit **246/0**；
parity missing=0；behavior actionable=0；i18n OK（2416 pairs）。

### 2026-11-14 16:2x —— 轮次 13（1.1.7.43）：播放页响应式字号/行距（P1，表 #13/#41）

**任务**（Lead 定序 P1）：web `#npTitle{clamp(19px,2.6vh,27px);line-height:1.3}`、
`.npline{clamp(13px,1.9vh,17px);line-height:2.05}`；原生固定 20pt/30pt 行 + 歌词 14pt/30pt ⟹ 小窗标题偏大、
大窗偏小、行距僵。
**判据**：`tests/test_native_nowplaying_web.mm` 追加 18 条，按**真实窗口高度** 640/800/1080 三档改 `vc.view`
尺寸与 `layoutSubtreeIfNeeded`，断言标题字号=clamp(19,2.6vh,27)、歌词字号=clamp(13,1.9vh,17)、
行盒=字号×2.05、相邻行贴合（±0.5~0.6pt）。
**红→绿**：旧码（1.1.7.42）**9 F**（标题 20/20/20 vs 19/20.8/27；歌词 14 vs 13/15.2/17；行盒 30 vs 26.65/31.16/34.85）
→ 新码 **60 passed / 0 failures**（42 既有 + 18 新）。
**实现**：新增 `RLPNPTitlePointSize`/`RLPNPLyricPointSize`/`RLPNPLyricLineStep`（1vh=webCanvas 高度 1%）；
`layoutWebPlayback` 每帧换算标题字号与行盒，并把副标题/下一首/芯片行的 Y 从标题行底推导；
歌词行盒 = 2.05×字号，窗口高度变化时 `restyleLyricRows` 只重设字体不改控件/滚动状态。
**如实挂账**：`.npline.on` 的 `transform:scale(1.03)` active 缩放未做（候补）；只验证 640/800/1080 三档；
标题省略号沿用 NSTextField 截断。
**门禁（1.1.7.43 树）**：build 0 error；串行全量 ctest **201/201 passed（380.47s）**；audit **246/0**；
parity missing=0；behavior actionable=0；i18n OK（2416 pairs）。
**如实记录（flake）**：第一次全量 ctest 200/201，唯一红 `diag_bundle_json`（与本包无关的诊断包 JSON 用例）；
单跑该用例 **62/0** 通过，随后**无并发**复跑全量 **201/201**。判为并发审计（同时跑 --audit）带来的环境抖动，
按 open flake 记，不加工代码。
**证据**：`evidence/native-responsive-type-20261114.md`、`native-responsive-type-{red,green}-20261114.log`、
`native-43-ctest.log`、`native-43-audit.log`；对照表 #13/#41 标「已修（1.1.7.43）」（#41 的 active scale 仍挂未修）。

### 2026-11-14 16:5x —— 轮次 13b（1.1.7.44）：控制区逐值（P2，表 #48/#49/#56）

**任务**（Lead 定序 P2）：`#npSeek:hover{5→7}`、`.nptime{12px}` + `.tval{min-width:42;居中}`、
`.npvol{input 104 / vlab 11px / min-w58}`；判据量实际尺寸 ±1pt。
**判据**：`tests/test_native_nowplaying_web.mm` 追加 15 条：seek cell `barThickness` 5→7 + hover 跟踪区存在、
pos/dur 字号12/宽42/居中、vol 滑杆104、vlab 字号11/宽58/右对齐。
**红→绿**：旧码（1.1.7.43）**10 F**（15 条里；`barThickness` 不存在导致 3 条 hover 子判据跳过）
→ 新码 **75 passed / 0 failures**（60 既有 + 15 新）。
**实现**：`RLPNPAccentCell` 加 `hovered`/`barThickness`（5/7pt，圆角随厚度）并用于 `drawBarInside`；
`RLPNPSlider` 加 `hoverGrow` 与 `NSTrackingMouseEnteredAndExited|ActiveInKeyWindow|InVisibleRect` 跟踪区
（只 seek 开，音量条保持 5pt 原生 range 外观）；时间字体 monospacedDigit 12、`.tval` 宽 42 居中、sep 10+1pt；
音量滑杆 104、标签 58/11pt、图标间距 8（窄窗保留收缩兜底）。
**如实挂账**：hover 响应只对 seek；跟踪区用 `ActiveInKeyWindow`，离屏判据以 `hoverGrow`+`trackingAreas` 证明
「有响应装置」，未做真实鼠标注入（遵守「不做键鼠自动化」铁律）；极小窗口下音量条仍会收缩（兜底）。
**证据**：`evidence/native-controlrow-20261114.md`、`native-controlrow-{red,green}-20261114.log`；
对照表 #48/#49/#56 标「已修（1.1.7.44）」。
**门禁（1.1.7.44 树）**：build 0 error；串行全量 ctest **201/201 passed（395.13s）**；audit **246/0**；
parity missing=0；behavior actionable=0；i18n OK（2416 pairs）。

### 2026-11-14 17:0x —— 轮次 13c（1.1.7.45）：`#npNextTrackHero` 状态机（P3，表 #15）

**任务**（Lead 定序 P3）：停止/暂停隐藏、队列末尾显示「队列末尾 · 共 N 首」、有下一首才写文案、换歌清空。
**先核对 web**：`updateNextTrackInfo()` 的隐藏条件是 `!S.playing || !qLen` —— **暂停不隐藏**（`playing` 是会话态，
暂停时仍为 true）。本包按 web 实现；Lead 任务书写的「暂停隐藏」与 web 不一致，已在证据里标注待人确认。
**判据**：`tests/test_native_nowplaying_web.mm` 追加 6 条（有下一首/末尾/单曲循环/停止清空隐藏/换歌立即清空），
走真实 `refreshQueueContext` + 队列 fixture；红跑用**最终测试版本**（临时还原 HEAD 实现→跑红→恢复实现→跑绿）。
**红→绿**：旧码（1.1.7.44）**5 F**（全角冒号、无末尾分支、不识别 mode=2、停止不清不隐、换歌后仍可见）
→ 新码 **82 passed / 0 failures**（75 既有 + 6 新 + 1 前提）。
**实现**：`applyQueueSnapshot:` 逐条移植 web 规则（mode==2/越界回绕/remain/半角「: 」）；
`refreshQueueContext` 响应为空也走清理路径；切曲分支清空+隐藏；可见时 `.npmline` 下移 22pt（web 多一行）。
i18n：新增 3 个格式串词条（`下一首: %@ · 剩 %ld 首` / `下一首: %@` / `队列末尾 · 共 %ld 首`），重生成两表（2419 pairs）。
**如实挂账**：①暂停时仍显示（按 web，待确认）；②tooltip 未逐字复刻 web 的「队列共 N 首，剩余 N 首」；
③队列只在切歌/激活时拉取（web 同），队列内增删不会即时改文案。
**证据**：`evidence/native-nexttrack-20261114.md`、`native-nexttrack-{red,green}-20261114.log`；
对照表 #15 标「已修（1.1.7.45）」。
**门禁（1.1.7.45 树）**：build 0 error；串行全量 ctest **201/201 passed（405.75s）**；audit **246/0**；
parity missing=0；behavior actionable=0；i18n OK（2419 pairs）。

### 2026-11-14 17:3x —— 轮次 14（1.1.7.46）：web hover 态统一（表 #65/#66/#67）

**任务**（Lead 定序 1）：`.k/.npclose/.nptoggle/.chip/.npcast/.npchip/.npseek` 的 hover 要按 web 视觉值对齐，
判据必须量**实际视觉变化**（颜色/描边/缩放），不能只断言有 tracking area。
**先核对 web**：`.k:hover{background:var(--hov2);color:var(--txt)}`、`.k.big:hover{brightness(1.08)}`、
`.npclose:hover{background:#fff;scale1.04}`（深色 rgba(48,50,58,.96)）、`.nptoggle:hover` 同款、
`.chip:hover/.npcast:hover{background:var(--hov);color:var(--txt);border-color:var(--acc)}`、
`.npchip:hover` 半透明底/边、`.npseek:hover{height:7px}`（1.1.7.44 已做，本轮回归断言）。
顺带核对：`.npclose/.nptoggle` 静态底应是 `rgba(255,255,255,.92)`，旧码用了不透明 `--bg` ⟹ hover 前后肉眼无差。
**判据**：`tests/test_native_nowplaying_web` 追加 35 条，逐条量 `CALayer.backgroundColor/borderColor` 逐分量、
`transform.m11`、`contentTintColor`，并验证 `trackingAreas≥1`；hover 进入/退出都断言（退出必须恢复静态值）。
**红→绿**：旧码（1.1.7.45）**10 F**（8 个控件无 hover 状态机、npclose 静态底非 .92、npRep 圆角非 9）
→ 新码 **121 passed / 0 failures**（86 既有 + 35 新）。
**实现**：新增 `RLPHoverButton`（跟踪区 + hovered + hoverApplier，`setHovered:` 是鼠标与判据共用入口）；
`NPCreateKeyButton` 造 `.k` 键（圆角 9/17）、`.k` 注入 hov2、`.k.big` 用 accent 混 10% 白近似 brightness；
`webButton:` 统一返回 hover 载体；close/toggle 静态底改 .92 + hover 不透明 + `scale1.04`；
`.chip/.npcast` 走 `applyChipHover:hovered:`（必须重写 attributedTitle 前景色）；投放退出走 `applyCastChipStyle`；
面板收起键 hover `--hov2/--txt`；右栏卡片 `setHovered:` 改底/边、退出 `applyTheme`。
**如实挂账**：①只覆盖正在播放页，底部播放条 `.k` 与设置页 `.chip` 未含；②brightness 用混白近似；
③`.npchip.on`（选中卡）hover 优先级未区分，hover 会覆盖选中态（web 选中规则在后）；④hover 判据走
`setHovered:`（与 mouseEntered/Exited 同一入口），未做真实鼠标注入（遵守不做键鼠自动化）。
**另（裁决落档）**：Lead 已确认 `#npNextTrackHero` **保持 web 行为（暂停不隐藏）**——「停止/暂停隐藏」是
任务书措辞错误，不是需求变更；已在 `evidence/native-nexttrack-20261114.md` 写明差异来源，不算未完成项。
**证据**：`evidence/native-hover-20261114.md`、`native-hover-{red,green}-20261114.log`；对照表 #65/#66/#67 标已修。
**门禁（1.1.7.46 树）**：build 0 error；串行全量 ctest **201/201 passed（403.59s）**；audit **246/0**；
parity missing=0；behavior actionable=0；i18n OK（2419 pairs）。

### 2026-11-14 18:0x —— 轮次 14b（1.1.7.47）：歌词空态/加载态两行文案（表 #44/#46）

**任务**（Lead 定序 2）：歌词空态与加载态文案逐字对齐 web，含两行副文案。
**先核对 web**：`#npLyric` 空态 = 主行 `没有歌词`（字号跟 `.npline` clamp 13~17）+ 副行 12px `--mut2`
「同名 .lrc 文件、内嵌歌词，或播放时自动在线补全（可在设置-元数据补全关闭）」；抽屉 `#lyricbox` 加载态 =
`歌词加载中…` + 副行「正在等后台补全（首次播放新曲目时可能要几秒）」。web 整页对「无曲目/网络曲目」没有
单独文案（都是同一段空态；`网络曲目暂无歌词` 只在抽屉）。
**判据**：`test_native_nowplaying_web` 追加 8 条：空态两行逐字、允许两行且居中、主行字号=clamp、副行=12px、
加载态两行逐字、无曲目也走整页空态。
**红→绿**：旧码（1.1.7.46）**6 F**（单行截断、文案不符、无副行、副行字号不适用、API 缺失、无曲目文案错位）
→ 新码 **131 passed / 0 failures**（121 既有 + 8 新 + 前提）。
**实现**：`lyricsEmpty` 多行居中；新增 `setLyricsPlaceholder:detail:`（主行 clamp 字号/`--mut`，副行 12px/`--mut2`，居中）；
空态/无曲目/网络曲目统一 web 整页两行空态；加载态改 web 抽屉两行文案；失败态保留 `歌词加载失败`。
**如实挂账**：①加载态在 web 整页并不存在（web 空歌词直接显示「没有歌词」），原生加载态是超集、文案取自抽屉；
②`歌词加载失败` web 整页也没有，保留原生既有提示。
**证据**：`evidence/native-lyric-text-20261114.md`、`native-lyrictext-{red,green}-20261114.log`；
对照表 #44/#46 标已修。
**门禁（1.1.7.47 树）**：build 0 error；串行全量 ctest **201/201 passed（390.94s）**；audit **246/0**；
parity missing=0；behavior actionable=0；i18n OK（2419 pairs）。

### 2026-11-14 18:0x —— 轮次 14c（1.1.7.48）：`.npline.on` active 缩放 + 放大不裁字（表 #41）

**任务**（Lead 定序 3）：补齐 `.npline.on{transform:scale(1.03)}`，数值以 web 为准；Lead 追加要求：
判据还要断言"缩放后相邻行/首尾行不被裁切"。
**判据**：`test_native_nowplaying_web` 追加 8 条：当前行 m11=1.03、非当前行两行=1.0、高亮切换后新行放大/
旧行复位；并用 1.03 缩放后的可见矩形断言**当前行仍在歌词文档内、首行不越上/左、末行不越下/右**
（doc=556×489 下旧码水平溢出约 2pt）。
**红→绿**：旧码（1.1.7.47）**8 F**（5 条无缩放 + 3 条越界）→ 新码 **140 passed / 0 failures**
（131 既有 + 8 新 + 前提）。
**实现**：`updateLyricPosition` 当前行 `CATransform3DMakeScale(1.03,...)`、其余 identity（行按钮 wantsLayer）；
`layoutLyricRows` 行左右 inset 从 6pt 改为 `max(6, ceil((w-12)*0.015)+1)`，给 1.03 绘制留 ≥1.5% 余量，
避免"放大即裁字"；行盒（clamp×2.05）与滚动几何不变。
**如实挂账**：①缩放不参与布局（web 同），当前行视觉略宽 ~3%；②无 :active/过渡（web .npline 也无 transition）。
**证据**：`evidence/native-lyric-scale-20261114.md`、`native-lyricscale-{red,green}-20261114.log`；
对照表 #41 从「部分已修」改「已修（1.1.7.48）」。
**门禁（1.1.7.48 树）**：build 0 error；串行全量 ctest **201/201 passed（395.83s）**；audit **246/0**；
parity missing=0；behavior actionable=0；i18n OK（2419 pairs）。

### 2026-11-14 18:2x —— 轮次 15（1.1.7.49）：`#npAnlBody` 13px 沟槽 + 自绘拇指（表 #28）

**任务**（Lead 定序 1）：先在同一 panelW 用 web 页面 C8 实测 → 再落地「沟槽常驻 13px + 拇指不压卡片圆角 +
单层滚动仍成立」→ 更新 311 期望值并披露差因。
**web 实测**（ego 打开 `rtaweb --port 19091/index.html`，页面内 `selftestRun()`；只碰 19091）：
C8 `PASS w=264/264/264 spread=0 右缘留白=13/13/13 L1溢出=0 L2溢出=567`；DOM：panelW=301、
bodyW=288、`padding-right:13`、滚动条占位 11、cardW=264、卡片右缘距面板右 25、clear=13。
**差因披露**：web `cardW = panelW-37`（左 12 = padding11+border1，右 25 = 13+11+1）；
原生面板无 1px 边框、左内边距 11 ⟹ `cardW = panelW-36`（右缘仍 25）。故 `anlcard.width` 期望
**311 → 297**（panelW 333），与上次 rightGap 13→37 同属「原生无边框/内边距」的显式差。
**判据**：`test_native_analysis_panel` 改 1 条 + 新增 7 条：body 右缘撑到面板右缘、bodyW=panelW-11、
卡片右缘到盒子右缘=25（同坐标系量）、暴露 `scrollThumbRect`、L2 溢出拇指非空、拇指与卡片右缘≥13、
拇指在沟槽内、卡片区不是 NSScrollView（单层滚动）。
**红→绿**：旧码（1.1.7.48）**7 F**（3×卡宽 311 vs 297、body 未撑右缘、bodyW 311 vs 322、gap=0、无拇指 API）
→ 新码 **140 passed / 0 failures**（analysis panel 全绿）。
**实现**：`anlBody` 盒子 `x=11 / width=panelW-11`（等价 `margin-right:-11`）；卡片 `width=bodyW-25`
（13 留白 + 12 拇指条，常驻，三档恒定）；`RLPNPAnalBody` 自绘 6px 拇指（`x∈[bodyW-8, bodyW-2]`，
按 contentH/H 与 offset 定位，不溢出不画），**不新增 NSScrollView**。
**如实挂账**：①左缘仍是 11（web 内容从 12 起，因 1px 边框）——只对齐右缘/卡宽，改左缘会牵动头部判据；
②滚动条轨道非常驻（web 恒显，原生只在溢出时画拇指）；③拇指 6pt（web CSS 6，实测滚动条占位 11）。
**证据**：`evidence/native-anl-gutter-20261114.md`（含 web 实测表）、`native-gutter-{red,green}-20261114.log`；
对照表 #28 标已修。
**门禁（1.1.7.49 树）**：build 0 error；串行全量 ctest **201/201 passed（397.21s）**；audit **246/0**；
parity missing=0；behavior actionable=0；i18n OK（2419 pairs）。

### 2026-11-14 18:4x —— 轮次 16（1.1.7.50）：后端错误态改 toast（表 #63）

**任务**（Lead 定序 2）：错误态不再写副标题、改 toast；判据断言「错误不写副标题 + toast 出现 + 自动消失」。
**先核对 web**：web 整页 `renderNp()` 不展示后端 error 字段；原生旧码把 `status.error` 写进 `#npSub`
（艺术家信息被顶掉，成为假信息）。
**判据**：`test_native_nowplaying_web` 追加 4 条，在真实 NSWindow 里跑：副标题≠错误串、出现
`rlp.toast`、toast 文案=错误原文、真跑 2.6s runloop 后 toast 自动消失。
**红→绿**：旧码（1.1.7.49）**2 F**（副标题写成错误串、无 toast）→ 新码 **144 passed / 0 failures**（140 既有 + 4 新）。
**实现**：status 分支不再写 `artistLabel2`，改 `RLPToast(st.error)`；新增 `lastStatusError` 去重
（同一错误只弹一次、错误消失即清）；`RLPToast` 容器加 `identifier=rlp.toast` 便于判据/审计定位。
**如实挂账**：①web 无 toast 组件（失败提示走另一套通道），原生用既有 1.8s 轻提示、文案为后端原文，
属可见反馈的超集；②不同错误串会重新弹，暂无合并窗口；③副标题在无 metadata 时保持空/艺术家。
**证据**：`evidence/native-error-toast-20261114.md`、`native-toast-{red,green}-20261114.log`；
对照表 #63 标已修。
**门禁（1.1.7.50 树）**：build 0 error；串行全量 ctest **201/201 passed（408.63s）**；audit **246/0**；
parity missing=0；behavior actionable=0；i18n OK（2419 pairs）。

### 2026-11-14 18:5x —— 轮次 17（1.1.7.51）：`.npkind` 字距 1.6（表 #11；#24 补判据）

**任务**（Lead 定序 1）：清掉 `#11/#24` 字距。
**先核对 web**：`.npkind{letter-spacing:1.6px}`、`.anllab{letter-spacing:1.5px}`；原生 `npKind` 用 stringValue
赋值（无 kern），左栏 `anlLab` 已接 kern 1.5 但对照表未更新、也没判据。
**判据**：`test_native_nowplaying_web` 追加 4 条：npKind kern=1.6、状态刷新后仍 1.6（旧码 stringValue 会冲掉）、
anlLab kern=1.5 防回归；全部从 attributedStringValue 取。
**红→绿**：旧码（1.1.7.50）**2 F**（npKind kern=0、刷新后仍 0）→ 新码 **149 passed / 0 failures**
（147 既有 + 4 新 + 前提）。
**实现**：新增 `RLPSetKernedText`（整串 attributed：字体/颜色/kern/段落）；`npKind` 创建 + refresh 两处文案
+ 主题切换都走它；`stringValue` 不再用于该标签。
**如实挂账**：①kern 按 1x px≈pt（与既有 anllab 一致，高分屏只影响密度）；②#24 的 anlLab 实现在本包之前，
本包只补判据并改正对照表。
**证据**：`evidence/native-kern-20261114.md`、`native-kern-{red,green}-20261114.log`；对照表 #11 标已修、
#24 改正为已修。
**门禁（1.1.7.51 树）**：build 0 error；串行全量 ctest **201/201 passed（404.38s）**；audit **246/0**；
parity missing=0；behavior actionable=0；i18n OK（2419 pairs）。

### 2026-11-14 19:0x —— 轮次 18（1.1.7.52）：歌词视口 26pt 渐隐遮罩（表 #40）

**任务**（Lead 定序 2）：`#40` 歌词 mask 渐隐。
**先核对 web**：`.nplyric2{mask-image:linear-gradient(180deg,transparent 0,#000 26px,#000 calc(100% - 26px),transparent 100%)}`
——视口顶/底各 26px 渐隐、中间全显；原生旧码无遮罩，长歌词首/末行硬切。
**判据**：`test_native_nowplaying_web` 追加 8 条：遮罩是 CAGradientLayer、四色标 alpha、locations 0→1、
26/H 与 1-26/H、frame=bounds、窗口变矮后重算、复位。
**红→绿**：旧码（1.1.7.51）**1 F**（遮罩缺失，后续判据跳过）→ 新码 **158 passed / 0 failures**（150 既有 + 8 遮罩判据）。
**实现**：`updateLyricFadeMask`（透明/黑/黑/透明四色标，startPoint 上→endPoint 下，locations=[0,26/H,1-26/H,1]）；
遮罩挂在**滚动视图**（不是 document），滚动时渐隐固定视口边缘；布局末尾调用，高度变化重算；不新增 NSScrollView。
**如实挂账**：①26pt 固定像素（web 同，不随字号缩放）；②原生仍 hasVerticalScroller=NO（与 web 隐藏滚动条等价）；
③遮罩不参与行盒/滚动几何。
**证据**：`evidence/native-lyric-mask-20261114.md`、`native-mask-{red,green}-20261114.log`；对照表 #40 标已修。
**门禁（1.1.7.52 树）**：build 0 error；串行全量 ctest **201/201 passed（412.68s）**；audit **246/0**；
parity missing=0；behavior actionable=0；i18n OK（2419 pairs）。

### 2026-11-14 19:5x —— 轮次 19a（1.1.7.53）：`.npchipwrap` 自绘滚动（表 #69）

**任务**（Lead 定序 1）：按自写方案做 chipwrap：自绘 contentOffset + 拇指、**不新增嵌套 NSScrollView**；
判据先锁「可见 NSScrollView 数量不变 + 栏头不随滚动移动 + 单层滚动仍绿」。
**先核对 web**：`.npchipwrap{overflow:auto;scrollbar-width:thin;gap:6}`、滚动条 6px；
芯片区独立滚动（栏头/分段固定）。
**判据**：`test_native_nowplaying_web` 追加 11 条：wrap 非 NSScrollView、railPanel 子树 NSScrollView=0、
chip 挂在 wrap、卡宽 wrapW-19、offset 150 后卡片真实上移、栏头 y 不变、拇指出现/与卡片右缘≥13/在沟槽内。
**红→绿**：旧码（1.1.7.52）**1 F**（无 npChipWrap）→ 新码 **173 passed / 0 failures**（158 既有 + 11 新）。
**实现**：新 `RLPRailWrapView : NSView`（contentHeight/contentOffset、scrollWheel 回调、drawRect 6pt 拇指）；
三张 chip 挂进 wrap；`layoutWebPlayback` 排 wrap；`railLayoutChips` 卡宽=wrapW-19、按 offset 排。
**同步修既有判据**：`native_rail_cards`/`native_rail_states` 从「railPanel 直接子视图」改为递归找卡
（卡片在 wrap 内）、几何 convertRect 到 rail 坐标；`rail.card.width` railW-20→**railW-39**、
`rail.padX.right` 10→**29**——差因是右侧常驻 19pt（13 留白+6 拇指条；web ~11px 滚动条），
属与 web 的**已知宽度偏差**（比 web 窄 8pt），已在证据披露。
**如实挂账**：①拇指只在溢出时画（无经典滚动条轨道）；②滚轮位移（无惯性/分页）；
③内容高不足时 offset 自动回 0；④`contentOffset` 判据用 KVC 驱动（生产入口是 scrollWheel 回调同一 setter）。
**证据**：`evidence/native-chipwrap-20261114.md`、`native-chipwrap-{red,green}-20261114.log`；
对照表 #69 标已修。
**门禁（1.1.7.53 树）**：build 0 error；串行全量 ctest **201/201 passed（385.30s）**；audit **246/0**；
parity missing=0；behavior actionable=0；i18n OK（2419 pairs）。

### 2026-11-14 19:4x —— 轮次 19（1.1.7.54）：`#npDrawer` 页内抽屉浮卡（表 #39）

**任务**（Lead 定序 2）：单独一包；判据覆盖 frame/圆角/阴影/遮罩点击关闭 + 打开时不影响底层滚动。
**先核对 web**：`.npdrawer{top/right/bottom:14;width:min(430,44vw);radius:18;border:1px;box-shadow:0 28px 80px rgba(0,0,0,.42)}`；
`.npdrawerbg{inset:0;background:rgba(0,0,0,.30)}`；点遮罩/Esc 关闭。原生旧码用 NSPopover 系统浮卡，
宽度/圆角/阴影/动效非 1:1，离屏或无窗口时直接不弹。
**判据**：`test_native_nowplaying_web` 追加 13 条（width/上下右 14/圆角 18/1px 边/阴影 opacity+radius+offset/
遮罩 inset0/不新增 NSScrollView/歌词滚动位置不动/点遮罩关闭/Esc 关闭）。
**红→绿**：旧码（1.1.7.53）**2 F**（无 npDrawer / npDrawerBg）→ 新码 **191 passed / 0 failures**（173 既有 + 13 新 + 前提）。
**实现**：`RLPOverlayBackdrop` 遮罩 + `npDrawer` 页内视图（加在 webCanvas 最上层）；`knowledge` 嵌入；
`layoutWebPlayback` 按页面尺寸排；`openDataDrawer/closeDataDrawer`；`onRailCard` 不再弹 NSPopover；
停止/切歌自动关；`cancelOperation:` 处理 Esc。
**如实挂账**：①遮罩无 backdrop blur（web 有 blur 2px），抽屉直接到终点、只做 alpha 淡入（避免动画与判据抢跑）；
②`masksToBounds=NO` 才能显示阴影（CSS overflow:hidden 不裁 box-shadow），内容圆角交给 knowledge；
③抽屉不进入滚动链路，打开/关闭不动底层滚动。
**证据**：`evidence/native-drawer-20261114.md`、`native-drawer-{red,green}-20261114.log`；对照表 #39 标已修。
**门禁（1.1.7.54 树）**：build 0 error；串行全量 ctest **201/201 passed（404.80s）**；audit **246/0**；
parity missing=0；behavior actionable=0；i18n OK（2419 pairs）。

### 2026-11-14 20:4x —— 轮次 20（1.1.7.55）：古典第 4 张「作品」卡 + 作品抽屉

**任务**（接手 `native-loop-gaps-20261114.md` §19 第 1 项 P2「未开始」）：把 web `npDataTargets` 的
work tab、`npDataEnsure('work')`、`npDataWorkBody` 逐行移植到原生右栏与页内抽屉。
**先核对 web**：`ui_script.h:12720-12751`（npIsClassical / npGuessComposer / npWorkTarget）、
`:12818`（npDataTargets）、`:13123`（npDataWorkBody）；旧原生右栏硬编码 3 种实体，且
`onOpenWorks:` 把「艺术家」当作曲家传，Discogs 检索必然 0 条。
**判据**：`test_native_rail_preview` 追加场景 5/6（4 卡 / versions URL 形状 / 点击实体 / 抽屉加载态·空态·缓存态·版本行·打开整页）；
同步把 `test_native_rail_cards`（3 张→4 槽、非古典可见 3、隐藏卡 frame 归零）与
`test_native_nowplaying_web`（先喂 meta 再量 chipwrap）两条既有判据跟着结构更新，不删红判据。
**红→绿**：旧码（1.1.7.54）**46P / 3F**（cards=3、无 npChip.作品、无 loadWorkName:composer:）
→ 新码 **78P / 0F**；`native_nowplaying_web` 0 failures。
**实现**：`RLPSupport` 新增三个公共判定函数（4 处入口共用一套真源）；`RLPKnowledgeView` 新增
`loadWorkName:composer:` 全套（versions URL / pending 轮询 / 来源行 / npdwork 行 / 空态 / 打开整页）；
`RLPNowPlayingViewController` 右栏 4 卡、work URL、成功判据、预览、点击实体、指纹含 composer、
`onOpenWorks:` 改取作品名+作曲家。
**收口（接力本工单在途 WIP）**：首次全量 ctest **200/201**，唯一红 `native_i18n_coverage`
（新 `RLPTr(@"不同演绎")` / `RLPTr(@"发行版本")` 两个独立字面量未进词表）；现场只补了 TSV 与 web 表头，
漏了原生表 ⟹ `native_i18n_table_check` 亦红。本轮新增 `chunk-native118-work.en.tsv`（Performances / Releases）
并重生成两份生成表，三条 i18n 门禁同时绿；顺手修同包内「注释与实现矛盾」「两语句挤一行」两处一致性。
**如实挂账**：①离线夹具，未真连 Discogs；②`.npdwork` 是 NSStackView 三列近似、未移植「复制版本链接」按钮；
③缓存日期只到 `yyyy-MM-dd`（web fmtDate 未逐字复刻）；④抽屉沿用 1.1.7.54 形态（无 blur / 无滑入）；
⑤work tab 仍受右栏 summary 闸门约束（与 web npDataCan 同口径）。既有挂账不因本包关闭：
底部播放条 `.k` / 设置页 `.chip` hover、`#npAnlBody` 左缘 1pt、默认渲染器切换、双模式薄表现层、
RENDERFAIL 根因（需用户诊断包）、`native_ui_functional` 偶发 bus error。
**证据**：`evidence/native-work-card-20261114.md`、`native-work-card-{red,green,npweb-green}-20261114.log`、
`native-55-{build,ctest,ctest-final,audit,build-rerun,ctest-rerun,audit-rerun}.log`。
**门禁（1.1.7.55 树）**：build 0 error；串行全量 ctest **201/201 passed（400.76s）**；audit **246/0**；
parity missing=0（view 14 / tab 10 / ctrl 179 / api 96，na 16 全可复核、removed 2 双向核验）；
behavior actionable=0（50 bindings）；i18n 三项 OK（2421 pairs）。

### 2026-11-14 21:0x —— 轮次 21（1.1.7.56）：底部播放条 `.k` hover 态

**任务**（关闭 `native-hover-20261114.md` 挂账 1 / 已知偏差 #9 的底栏部分）：web 底栏 5 个 `.k` 键
有 hover 反馈，原生此前只有 AppKit 默认按下高亮。
**先核对 web**：`ui_page.h:1081-1085`（`.k` / `.k:hover{--hov2/--txt}` / `.k.big` / `.k.big:hover{brightness 1.08}`）、
`:276-277`（`.ibtn` 同值）、`:1594-1600`（底栏 5 键）。
**判据**：`test_native_bar_web` 追加 hover 段，量 4 个 `.k` 键与 `.k.big` 的
`respondsToSelector(setHovered:)` / trackingAreas / 静态底 / hover 底 `--hov2` / hover 图标色 `--txt` /
退出恢复透明底与 hover 前 tint（不抹播放模式强调色）；`pb.play` 另锁 `--acc` 静态底、hover 变化、退出恢复。
**红→绿**：旧码（1.1.7.55）**315P / 5F**（5 键无 hover 状态机）→ 新码 **346P / 0F**。
**实现**：`RLPPlaybackBarView.mm` 本地新增 `RLPBarKeyButton`（跟踪区 + hovered + hoverApplier，
`viewDidMoveToSuperview` 主动建区保证离屏判据不假绿）；`symbolButton:` 工厂改返回它并注入 `.k:hover`
语义（退出恢复进入前 tint）；`pb.play` 覆盖为 accent 混 10% 白（同 np.play 取舍）。
**如实挂账**：①设置页 `.chip` 仍未做（已知偏差 #9 已改为只挂设置页）；②`brightness(1.08)` 用混白近似；
③走 `setHovered:` 未做真实鼠标注入（不做键鼠自动化）；④底栏与 np 页各一份同构载体，
未合并公共层（避免牵动 191 条判据）；⑤其余既有挂账不因本包关闭。
**证据**：`evidence/native-bar-hover-20261114.md`、`native-bar-hover-{red,green}-20261114.log`、
`native-56-{build,ctest,audit}.log`。
**门禁（1.1.7.56 树）**：build 0 error；audit **246/0**；parity missing=0；behavior actionable=0；
i18n 三项 OK（2421 pairs，本包无新增中文文案）。串行全量 ctest 首次 **200/201**
（唯一红 `library` 的时间敏感断言 [7.3]，首次冷启动 2352ms；纯 C++ 用例、与本包 UI 零关联，
单跑 5/5 绿）→ 另起干净全量复跑 **201/201**（不改判据、如实挂账该 flake，见
`evidence/native-bar-hover-20261114.md` §6.6）。

### 2026-11-14 21:5x —— 轮次 22（1.1.7.57）：音频分析栏左缘 11→12

**任务**（关闭 `native-anl-gutter-20261114.md` 挂账 1 / 已知偏差 #1）：web 面板有 1px 边框，
内容从 border+padding 起算 12；原生面板无边框、历史取 11，四条期望把这 1pt 差烘进了判据。
**先核对 web**：`ui_page.h:874` `#npAnal{padding:8px 11px 9px}` + 1px border ⟹ 内容左缘 **12**；
`.anlheadtop{padding-right:26px}` + `#npAnlStat{padding-right:2px}` ⟹ 状态右缘 **38**；
web 实测（panelW=301）卡宽 **264 = panelW-37**、卡右缘距面板右 25（13 留白 + 12 拇指条）。
**判据**（`test_native_analysis_panel` 5 条 + tolerance 收严）：`anslab.left 11→12`、`stat.rightGap 37→38`、
`anlcard.left 11→12`、`anlcard.width panelW-36→panelW-37`、`npAnlBody 宽 panelW-11→panelW-12`；
tolerance 1.5/1.0 → **0.5**（原 1.5 会把 1pt 差放过 ⟹ 等于没判）。
**红→绿**：旧码（1.1.7.56，仅改判据）**131P / 9F**（`anslab.left` 11 vs 12、`stat.rightGap` 37 vs 38、
`anlcard.left`×3 11 vs 12、`anlcard.width`×3 297 vs 296、`npAnlBody` 322 vs 321）→ 新码 **140P / 0F**。
**实现**：`RLPNowPlayingViewController.mm` 只改 `anlPadX 11→12`；其余取值全是派生
（`statRight=side-(anlPadX+26)`、`cardsW=side-anlPadX`、分段右缘、`anlReanalyze` x），无第二处硬编码。
**如实挂账**：①`.anlhide` 仍 `side-8-22`（web 应 `side-9-22`，`right:8px` 相对 padding box）——本包未动，
改它会牵动「收起键不压状态文字」断言，需单独包；②本包只跑离屏判据 + 门禁，**未做实机肉眼验收**（由用户执行）。
**证据**：`native-anlpad-red-20261114.log` / `native-anlpad-green-20261114.log`、
`native-anl-gutter-20261114.md` §1.1.7.57、`native-4-playback-diff.md` #23（改「已修（1.1.7.57）」）。
**门禁（1.1.7.57 树）**：build 0 error；串行全量 ctest **201/201（405.48s）**；`--audit` **246/0**；
parity missing=0（view 14 / tab 10 / ctrl done=179 / api done=96，na 16 全可复核、removed 2 双向核验）；
behavior actionable=0（50 bindings）；i18n 三项 OK（2421 pairs）。


### 2026-11-14 23:xx —— 轮次 23（1.1.7.58）：`.npchipwrap` 卡宽对齐实测 + `.anlhide` 8→9

**任务**（用户清单前 5 项 + 文档 #10/#11）：芯片区卡宽 `wrapW-19` → web 实测值、
同步两个测试期望、更新 `RLPRailWrapView` 注释、`.anlhide` 收起键 8→9、
更正 `known-deviations` #1/#4/#9、记录 `sp_opra_copychip` 现状。

**先实测**：ego 浏览器打开 19091 的 `index.html`（未碰 8899、未改
`build-mac/rlplayer-settings.conf`），注入 8 张 `.npchip` 造溢出。
`offsetWidth 279 - clientWidth 268 = 11`（CSS 写 `::-webkit-scrollbar{width:6px}`），
首卡宽 268 = `wrapW-11`；不溢出时占位 0、卡宽 279。`.anlhide` 实测 `right=9`。

**红→绿**：仅改判据时 `native_nowplaying_web` / `native_rail_cards` /
`native_analysis_panel` **3 个 ctest 全红**（`239 vs 247`、拇指间隙 13、
`anlhide.rightGap 8`）→ 改实现后 6 项相关 ctest **全绿**，build 0 error。

**实现**：`RLPNowPlayingViewController.mm` 卡宽 `W-19→W-11`、拇指 `W-6→W-8`、
`.anlhide` `side-8-22→side-9-22`；`test_native_nowplaying_web` /
`test_native_rail_cards` 几何期望同步；`test_native_analysis_panel` 新增
`anlhide.rightGap` 判据。`RLPRailWrapView` 的「13pt 留白」注释改为 web 实测口径。

**文档**：新建 `evidence/native-chipwrap-width-20261114.md`（实测表 + 红绿 + 挂账）；
`evidence/native-known-deviations-20261114.md` #1/#4 改「已关闭」、#9 澄清只剩设置页
`.chip`、新增 **#12 记录 `sp_opra_copychip` 假绿**（web 有 1 个可点 .chip 复制官网链接，
原生只有 `RLPControlIdentifier` 字典里的 id 字符串，`parity_scan` 因此标 `done`——
静态表的盲区）；`native-4-playback-diff.md` #69 行与本轮节同步。

**上游核实（`git fetch` 只读）**：fetch 前后 HEAD 均 `1bfa64e`、分支 `main` 未变，
本地领先 `origin/main` **105** 提交。`RLPlayer2` 上游最新提交仍是 11-02 的
`5ca77f6`（ssh usa 读 GitHub API 复核），`github/origin` 均停在 11-11 的 1.1.6
⟹ 本机可见的三个 remote **都没有「上游刚更新」的 UI 代码**；未 merge/rebase/reset，
工作树与本地提交零改动。用户所说「上游」待澄清。

**如实挂账**：①web 不溢出时卡宽 = wrapW，原生常驻 11pt 占位；②web 卡右缘 22 vs
原生 21（面板 1px border）；③抽屉 blur/滑入、brightness 真混合、chipwrap 惯性、
默认界面切换、双模式薄表现层仍未做；④RENDERFAIL 需用户诊断包（本机日志已见
`Pocket Master Audio` / `hogexcl=1` / 独占流 201 轮未接受数据，但缺用户侧完整诊断包）。


### 2026-11-15 00:xx —— 轮次 24（1.1.7.59）：brightness 真混合 + 更新进度 UAF + 上游新版本核实

**任务**：清单 #7（混白近似 → 真实逐通道混合）、#9 剩余同源 UAF；并核实用户所说「上游新版本」。

**brightness 红→绿**：`np.play` / `pb.play` 两处 hover 从 `accent 混 10% 白` 改为
sRGB 分量 ×1.08 夹到 1（web `filter:brightness(1.08)` 的真实结果）。
新增 4 条精确判据（等于逐通道值、不等于混白值）。第一次编译因判据误用已 `#undef` 的
`HOVERABLE` 宏失败、导致假绿，已改为 `respondsToSelector:` 后重跑：
旧实现 build 0 error / **2 个测试 4 条判据全红** → 新实现 build 0 error / **5 个相关测试全绿**。

**UAF**：`RLPUpdateWindowController` 的 `begin_install` 进度回调同样按引用捕获
`const NativeProgress&`，回调返回后主线程读 `p.detail.c_str()` 是悬垂（与 1.1.7.38 的
CheckResult SIGBUS 同源）。已在跳线程前同步拷出 `percent` 与 `NSString *detail`。
如实挂账：该条**未加独立判据**，仅代码审查 + 全量门禁。

**上游核实更正**：`main` 无更新，但 **Release v3.3.11 于 2026-11-14 15:34 UTC 发布**
（tag/分支 `codex/release-3.3.11` → `4ab338e3`）；v3.3.11 相对 main 的
`ui_script.h` +3082/-709 行、新增 71 id / 14 端点 / 148 函数。
详见 `evidence/native-upstream-ui-compare-20261114.md` §7。

**门禁**：串行 ctest 201/201、`--audit` 246/0、parity missing=0、behavior actionable=0。


### 2026-11-15 00:xx —— 轮次 25（1.1.7.60）：补 `sp_opra_copychip` 真实控件

**任务**：用户清单 #11 记录的静态表假绿；方向按用户确认「骨架/语言不动，照 Windows v3.3.11
UI 继续做 AppKit UI」，本项先把本仓 web 版已有、原生缺失的能力补齐。

**红→绿**：`test_native_opra_cards` 新增 C1–C5（真实控件 / NSButton / target+action /
标题含 URL / 点击后剪贴板 == `https://opra.roon.app/`）。
只加判据时 build 0 error、**2 FAIL**（C1/C2，其余因 btn=nil 跳过）→ 补实现后 build 0 error、
5 项相关 ctest 全绿。证据 `native-opra-copychip-{red,green}-20261115.log`。

**实现**：`RLPEqualizerView.mm` OPRA 搜索行追加 `NSButton`，identifier 与 web 一致，
SF Symbol `doc.on.doc` 代替内联 SVG，action 写 `NSPasteboard` + `RLPToast`。
i18n 复用既有词条 `已复制来源链接:` / `复制 OPRA 项目官网链接`，未改生成表。

**文档**：新建 `evidence/native-opra-copychip-20261115.md`；`known-deviations` #12 改「已关闭」。

**门禁**：串行 ctest 201/201、`--audit` 246/0、parity missing=0、behavior actionable=0。


### 2026-11-15 01:xx —— 轮次 26（1.1.7.61）：抽屉 blur + 滑入 / chipwrap 惯性

**任务**：关闭用户清单 #6 / #8 与 `known-deviations` #5 / #11。

**红→绿**：`test_native_nowplaying_web` 新增 5 条判据。仅判据时 build 0 error、
**3 FAIL**（惯性入口缺失、`npDrawerBlur` 模糊层缺失、0.26s 滑入动画缺失）→ 补实现后
build 0 error、5 项相关 ctest 全绿。首轮绿阶段惯性位移得 0，根因是 `momentumTick`
触发 `railLayoutChips` 重算 `contentHeight` 为不溢出值、`contentOffset` 被夹回 0；
按既有 chipwrap 判据同口径每帧恢复 `contentHeight=1200` 后转绿（修判据前置条件，非改阈值）。

**实现**：`RLPBlurView : NSVisualEffectView`（`HUDWindow`/`WithinWindow`，`hitTest:nil` 点击穿透）
作为遮罩子视图；`CABasicAnimation(transform.translation.x, 0.26s, cubic-bezier(.2,.8,.2,1))`
只动 presentation layer，`frame` 恒为终态；`RLPRailMomentumStep` 纯函数（每帧 ×0.90、
<8pt/s 收敛）+ `momentumTick:` 阻尼惯性，系统 `momentumPhase` 阶段不叠加，`timer` 仅在
`self.window != nil` 时挂、`dealloc` invalidate。

**门禁**：串行 ctest 201/201、`--audit` 246/0、parity missing=0、behavior actionable=0。


### 2026-11-15 01:xx —— 轮次 27（1.1.7.62）：v3.3.11 `npVolInput` 精确 dB 音量输入

**任务**：按用户确认方向，照 Windows v3.3.11 UI 补 AppKit UI；本包做待移植清单第 1 组的
「精确音量」部分（不新增后端端点、不新增 i18n 词条）。

**红→绿**：`test_native_nowplaying_web` 新增 V1–V7（控件存在 / target+action /
`-12.5` 真下发 `/api/volume?db=-12.5` / 标签同步 / 越界不发请求 / 越界恢复已确认值 /
`-120` 静音档下发）。仅判据时 build 0 error、**1 FAIL**（V1，其余跳过）→ 补实现后
build 0 error、4 项相关 ctest 全绿。中途判据曾因 `ck` 只有 2 参数多传 detail 编译失败，
已修正后重跑（假绿已排除）。

**实现**：`RLPNPControlBar` 加 `volDbField`（identifier `npVolInput`、48pt、图标左侧，
宽窗口不动 104pt 滑块）；`onCommitPreciseVolume:` 校验 -120~+20、round 0.1、下发
`/api/volume?db=`、同步 `volLabel`/滑块；非法值红边框 + 恢复值不发请求；`refresh`
从 `/api/status` 的 `volumeDb` 同步精确值。tooltip 复用既有词条 `音量（dB）`。

**挂账**：旋钮 SVG / 静音恢复按钮 / `PLAYBACK_SETTINGS.ready` 锁定 / `rawVolumeLocked` /
settings 写回 / Esc 取消未移植；位置与 web 不同（原生在图标左侧）。见
`evidence/native-precise-volume-20261115.md`。

**门禁**：串行 ctest 201/201、`--audit` 246/0、parity missing=0、behavior actionable=0。


### 2026-11-15 01:xx —— 轮次 28（1.1.7.63）：默认 packaging 切到原生版

**任务**：用户答复 #12「默认开原生版 原生版是要替代 web 版的」——不做双向切换键，
原生为默认与最终形态，web 仅留对照/回退。

**红→绿**：新增 `tests/check_native_default_app.cmake` + ctest `native_default_app`，
真跑 `zsh tools/make_app_mac.sh --print-default-bin`（只读自省入口）。
旧码默认 `rlplayer_mac` → **1 FAIL**（`实际 'rlplayer_mac'`）→ 改默认后 **PASS**，
同时校验 `RL_WEB_APP=1 → rlplayer_mac`、`RL_NATIVE_APP=1 → rlplayer_native`。

**实现**：`make_app_mac.sh` 默认 `rlplayer_native` / `RLPlayer.app`；`RL_WEB_APP=1` 出
`RLPlayer-Web.app`；旧 `RL_NATIVE_APP=1` 兼容出 `RLPlayer-Native.app`。不删 web 可执行。

**挂账**：PLAN.md §2.2 的旧状态未改（该文件有外来 WIP，绝不 stage）；未发版/未推送；
真实出包未重跑，实机验收由用户执行。

**门禁**：串行 ctest 201/201、`--audit` 246/0、parity missing=0、behavior actionable=0。


### 2026-11-15 02:xx —— #14 RENDERFAIL 挂账状态（文档，无代码改动）

**用户决定**：诊断包已无法取得、出错版本不可考，「先当不存在吧」。
按编排口径如实记为 **用户放弃提供诊断包、暂挂账、停止追查**；
**不写成已修、不写成不存在、不写成根因已定位**。

**动作**：新建 `evidence/native-renderfail-status-20261115.md`（保留本机日志观察：
`Pocket Master Audio` / `hogexcl=1` / 独占流 201 轮未接受数据 → 回退共享同样失败，
但明确这些来自历史多版本、无法对应当前 1.1.7.63）；`known-deviations` 末尾加
「非偏差类挂账」说明，不把 #14 塞进偏差表。

**边界**：播放引擎零改动，未改 `hogexcl` 与独占/共享回退逻辑；`test_renderfail` 绿只证明
归因分类逻辑，不证明故障消失。若将来有可复现的当期失败 + 当次诊断包，再重新开包。
本条为纯文档记录，按项目惯例**不升版本号**。


### 2026-11-15 02:xx —— 轮次 29（1.1.7.64）：v3.3.11 `npVolFloor` 静音 / 恢复

**任务**：待移植清单「音量旋钮 / 精确音量」组第二部分，照 `ui_script.h:6372-6380` 的
`toggleVolumeMute` 语义。

**红→绿**：`test_native_nowplaying_web` 新增 M1–M7（控件存在 / target+action / 静音下发
-120 dB / 输入框同步 / 标签「静音」/ 恢复先前 -12.5 dB / 输入框同步）。
仅判据时 build 0 error、**1 FAIL**（M1）→ 补实现后 build 0 error、4 项相关 ctest 全绿。

**实现**：`RLPNPControlBar` 加 `volMuteBtn`（identifier `npVolFloor`、SF Symbol、复用词条
`静音`）与 `volumeRestoreDb`（NAN = web `volumeRestore===null`）；把 1.1.7.62 的下发逻辑
抽成 `applyVolumeDb:` 供精确输入与静音共用；`onToggleVolumeMute:` 逐行对齐上游
（当前 -120 且无恢复值直接 return）。布局把静音键纳入 `minIconX` 守卫，宽窗口不动 104pt 滑块。

**门禁**：串行 ctest 202/202、`--audit` 246/0、parity missing=0、behavior actionable=0。


### 2026-11-15 02:xx —— 轮次 30（1.1.7.65）：v3.3.11 M3U 解析纯函数

**任务**：待移植清单「M3U 导入」组第一部分，先落地与判据共用的解析真源。

**红→绿**：`test_native_queue_sort` 新增 U1–U10（BOM/CRLF/注释、绝对路径、相对路径+folder、
needsFolder、CUE 区间、HLS/孤立 CUE/空歌单/控制字符拒绝）。占位实现下 build 0 error、
**9 FAIL**（U5 因占位恰好返回 needsFolder=YES 碰巧 PASS，已如实记录）→ 真实现后
build 0 error、3 项相关 ctest 全绿。

**实现**：`RLPSupport.h/.mm` 加 `RLPParseM3U(text, folder)`；照搬上游
`parseTransportM3u` 的 BOM/注释/CUE/拒绝规则，把 Windows `m3uWindowsPath` 适配为 POSIX
（`/` 绝对根、`stringByAppendingPathComponent`、`stringByStandardizingPath`、`NSURL.path`）。
纯函数不读文件/不弹面板/不发请求。

**挂账**：队列页 `qImportM3u` 按钮、文件选择、`/api/queue/set` 下发、16 MiB 闸门、
`require_stopped`、替换确认、相对路径追问文件夹均未做（下一包）。

**门禁**：串行 ctest 202/202、`--audit` 246/0、parity missing=0、behavior actionable=0。


### 2026-11-15 03:xx —— 轮次 31（1.1.7.66）：v3.3.11 M3U 导入 UI 接缝

**任务**：待移植清单「M3U 导入」组第二部分：队列页 `qImportM3u` + 文件面板 + 生产接缝 +
`/api/queue/set` 下发 + 16 MiB/播放中闸门。

**红→绿**：`test_native_queue_sort` 新增 Q0–Q8。旧码 build 0 error、**7 FAIL**
（Q1–Q6、Q8；Q7 因无接缝恒真）→ 新码 build 0 error、`native_queue_sort` 全绿。

**实现**：`RLPQueueViewController` 工具栏加 `导入 M3U 到队列`（identifier `qImportM3u`）、
`NSOpenPanel`（`.m3u/.m3u8`）、生产接缝 `importM3UAtPath:playing:`（扩展名 → 16 MiB →
`RLPParseM3U`(folder=文件目录) → `require_stopped=1&files=` → `/api/queue/set` → 刷新）、
`isPlayingNow` 复用 `/api/status`；新增 6 条 i18n（chunk-native119-m3u.en.tsv）并重生成
两份生成表（2427 对）。

**修掉两处判据假红**（如实记录）：① `q.del` 判据依赖 AppKit 行视图懒创建，同树两次运行
时红时绿 → 先 `viewAtColumn:3 row:0 makeIfNecessary:YES` 物化再扫；② Q8 夹具只有 7.6 MB、
到不了 16 MiB 闸门 → 加长路径并增到 ~17.6 MB。③ 汇总 printf 原本在所有断言之前，已移到末尾。

**挂账**：`askConfirm` 替换确认、`needsFolder` 追问（macOS 用文件目录，不需要）、
导入后不跳页、未做页面级真点按钮（离屏会弹真面板）。

**门禁**：串行 ctest 202/202、`--audit` 246/0、parity missing=0、behavior actionable=0。


### 2026-11-15 03:xx —— 轮次 32（1.1.7.67）：v3.3.11 单曲封面 set/reset（后端）

**任务**：待移植清单「封面手动设置 / 重置」组。先核对发现本仓后端**没有**
`/api/cover/set|reset`（grep = 0），故本包先补后端与读侧。

**红→绿**：`test_embedded_api` 新增 K0–K6。把读侧人为回退后跑出**真实红**
（K2 `len=67 magic=1`，读到的是占位图），补读侧后 **0 失败 7 条全绿**。

**关键发现（真缺陷）**：只加写路由时「设置成功」是空操作 —— `/api/cover` 读取链
不查逐曲手动封面。必须同时补读侧（`manual/<track:hash>.jpg` + reset 标记短路）才真正生效。
这是「接口存在 ≠ 功能生效」的又一实例，已写进证据第 3 节。

**实现**：POST 白名单两条；`is_side_effect_exempt` 显式排除这两个子路径（防 `<img src>` 改封面）；
路由插在 `/api/cover` 读取分支之前；set 校验 1KB~24MiB + 图片魔数 + 原子写；reset 写
`source:"reset"` 标记；读侧命中手动封面时 `max-age=3600`。

**同包补齐前端按钮**：`npSetCover`/`npResetCover`（`NSOpenPanel` + 生产接缝
`setCoverAtPath:forTrack:` / `resetCoverForTrack:`，set 走二进制 `postData`、reset 走 `postJSON`，
成功后 `loadCoverForPath:` 重拉），判据 C1–C10 全绿；i18n 新增 8 条并按既有译法复用
（避免一稿两译），coverage 0 缺失。

**UI 接线的红证据来自门禁**：补按钮前 `native_ui_parity` FAIL（`api missing=2`），
补后 `api done=97 missing=0`。

**挂账**：`/api/meta` 的 `coverSource` 字段（导致「自动」按钮始终可见，与上游有可见差异）、
reset 只标记不删图（与上游一致）、夹具为构造 PNG 不解码。

**门禁**：串行 ctest 202/202、`--audit` 246/0、parity missing=0、behavior actionable=0。


### 2026-11-15 04:xx —— 轮次 33（1.1.7.68）：v3.3.11 反馈结果 + 预览

**任务**：待移植清单「反馈结果」组。核对上游后发现 `/api/feedback/status` 依赖 Web 版的
**后端 job 队列**，而本仓是客户端进程内直传远端服务 —— 照搬会成为第二套并行机制，不移植，
如实挂账（证据第 2 节给了六项契约对照）。

**实际移植**：`sp_fbpreview`（「先看会发送什么」，文案从真实请求参数派生：端点取
`kFeedbackUploadUrl`、版本取 `RLPLAYER_VERSION`、字节数取真实 UTF-8 长度、诊断包取开关）
+ `sp_fbpreviewbox`（默认隐藏）+ `sp_fbresult`（持久结果区，`fbResultText:kind:` 同时写
状态行与结果区，空结果不占位）。

**红→绿**：新增 P1–P9 / G1–G3。红阶段（控件标识缺失）build 0 error、**9 FAIL** →
绿阶段 build 0 error、**52 passed / 0 failed**。

**如实记录**：红阶段 G2/P4 出现**假阳性**（`nil.hidden == NO` 恒为真），已改成
`ctrl != nil && ctrl.hidden == NO` 后重跑。

**i18n**：新增 6 条（chunk-native121-fbpreview），coverage 0 缺失。

**门禁**：串行 ctest 202/202、`--audit` 246/0、parity missing=0、behavior actionable=0。


### 2026-11-15 04:xx —— 轮次 34（文档）：v3.3.11 播放设置闸门判定为 N/A

**结论**：`PLAYBACK_SETTINGS` / `ensurePlaybackSettings` **不移植**。原生版
`applicationDidFinishLaunching` 第 73 行同步 `startEmbedded()`（设置在其中读完），
第 75–77 行才建窗口 ⟹ 「UI 已可用但设置未读」的窗口不存在，`ready=false` 永远不可达。
照搬会得到永远为 true 的死代码与一排永不显示的控件。

**替代关系**（不是空着）：核心启动失败有 `started` + 「核心未启动」；音量垃圾值有后端
`isfinite + clamp(-144,0)` 防护（`rtaweb.cpp:2012`）。

**如实挂账**：唯一真实差异是「非法保存音量静默 clamp、不提示用户」（上游会拒绝播放并提示改正），
已追加到 `native-known-deviations-20261114.md`；做成上游那样需跨后端契约改动，不在小范围移植内。


### 2026-11-15 04:xx —— 轮次 35（1.1.7.69）：v3.3.11 快速启动能力门控

**先核对了上游再动手**：`quickStartHtml()` 在 v3.3.11 **没有任何调用点**，导航项被
`syncQuickStartVisibility()` 永久隐藏 ⟹ 「快速开始页面」是死代码，照搬等于移植一个不渲染的页面。
真正活着的是 `quickStartModel()`，唯一消费点是 `rlPaintPreset()`（播放方式三档能否点）。

**本仓旧码的真实缺陷**：`loadPresetCaps:` 把 `/api/preset/caps` 拉回来就 `(void)json` 丢掉 ⟹
能力探测是装饰品，三档永远可点，用户只能事后在后端 notes 里看到降级说明。

**实现**：把判定抽成纯函数 `+gatingForCapsJSON:`（逐条照 offline/remote/shared/known/dsdNative/dop），
`applyPresetCaps:` 写进状态；`onOpenPlay:` 按档置灰 + tooltip + 界面说明行（`quickstart.presetGate`）；
新增 `pausedNow` —— 旧实现只有 `playing = st.playing && !st.paused`，**暂停会被误判成可应用**。

**红→绿**：新增 Q1–Q5。红（门控恒 true）build 0 error、**6 FAIL** → 绿 build 0 error、0 失败。

**挂账**：快速开始页面不移植（死代码）、`quickstart` 偏好未移植、弹层未做页面级真点击判据
（用纯函数覆盖同一决策）、`preset/apply` 未加本仓后端不认的参数。

**门禁**：串行 ctest 202/202、`--audit` 246/0、parity missing=0、behavior actionable=0。


### 2026-11-15 05:xx —— 轮次 36（文档）：v3.3.11 QA 引导 / i18n 上报判定为 N/A

**核对结果**：两项都是 Web 前端的**自动化验收设施**，不是用户功能，故不移植。

- **QA 引导**：上游代码自带说明「仅 RLPLAYER_QA=1 时由 tick 启动」，靠 `/api/qa/next` 下发
  DOM 指令（`scroll:#npDataBody`、展开折叠块）、回传 `qaPanelsText()`、`/api/qa/done` 收尾 ——
  是给自动化截图脚本用的驱动端。AppKit 无 DOM，无对应物。本仓等价物是
  `rlplayer_native --audit`（246 项）+ 202 项 ctest，且不需要生产期开关。
- **i18n 上报**：扫 DOM 文本节点与 `title/placeholder/aria-label` 找含 CJK 且未译的串，
  `POST /api/i18n/miss` 聚合（本仓后端无此端点）。原生每条文案都是编译期可见的
  `RLPTr`，由 `native_i18n_coverage` 穷举校验（当前 1672 处、0 缺失）——
  编译期拦住比运行期上报更硬。

**挂账**：两项不新增代码、不升版本、无新词条；原生确实没有「运行期回传漏译」通道，
若将来需要应扩编译期检查覆盖面而不是再造网络遥测。

### 2026-11-15 05:xx —— 轮次 37（1.1.7.70）：v3.3.11 doSeek 守卫 + 精度

**范围判断**：``npWaveform``（真波形）需要新分析模块 + 缓存/后台 worker + 新端点 + Canvas 绘制，
是跨三个模块的新子系统，超出小范围改动 ⟹ 只读评估记入证据第 5 节，本轮不做。
真正可聚焦的是 ``doSeek`` 的守卫与精度，本包做这部分。

**旧码缺陷**：``onCommitSeek:`` 是一条单行实现，三条守卫一条都没有 —— 未播放/时长未知照发 seek；
拖到最右发 ``pos=1.000000``（后端会精确跳到文件末尾）；精度 6 位与上游 ``toFixed(4)`` 不一致。

**实现**：按上游逐条加 ``!st.playing`` / ``!(st.duration > 0)`` / ``!isfinite(raw)`` 守卫，
``fmin(0.9999, fmax(0.0, raw))`` 后以 ``%.4f`` 下发；``lyricManualUntil = 0`` 保留（对应上游 lyricReposition）。

**红→绿**：新增 S1a/S1b/S2/S3/S4。红 build 0 error、**5 FAIL** → 绿 build 0 error、``np web: 0 failures``。
既有判据「seek uses real backend pos parameter」随之从 6 位改 4 位（精度本身即移植目标，不是放宽判据）。

**门禁**：串行 ctest 202/202、``--audit`` 246/0、parity missing=0、behavior actionable=0。

### 2026-11-15 12:xx —— 轮次 38（1.1.7.71）：v3.3.11 音量旋钮本体 npVolKnob

**上游真值**：ui_page.h:1581 的 #npVolKnob 是 64×64 圆盘（track 弧 r=24 + 刻度 + 值弧 + 中心 cap r=20 + 居中静音键 + 读数），
配套 #npVol range 是 sr-only；映射用 volDbToNorm/volNormToDb 的对称指数曲线（0 dB 在正上方）；大弧标志阈值是 2/3。

**实现**：新增 RLPVolumeKnobView.h/.mm（纯 C 几何函数 + 自绘视图 + 拖动），接入播放页控制栏取代可见滑块
（滑块 hidden 但保留为状态载体），静音键移到圆盖中心，拖动中走 updateVolumeUiForDb:（只同步界面）、
松开走 applyVolumeDb:（下发）。

**判据**：新建 test_native_volume_knob（已注册 ctest），K1–K10 共 26 条，钉住两点历史事故：
① 大弧阈值 2/3（旧码 norm>0.5 让 0 dB 附近弧线绕出圈外，3.3.10 用户实测反馈）；
② 0 dB 在正上方（线性 dB 会让中点变成 -30 dB、拖到中间就没声音，web 2026-10-25 事故）。
结果 26 passed / 0 failed；接入后 np web: 0 failures、native_bar_web: 348 checks, 0 failures。

**挂账**：底栏旋钮未做；原生圆盘 40pt（web 64pt，受控制栏行高约束）；拖动期间不下发请求
（沿用原生「松开才提交」纪律，web 是每帧下发）；未接 NSAccessibility。

### 2026-11-15 12:xx —— 轮次 39（1.1.7.72）：v3.3.11 底栏音量旋钮 volKnob

**关键发现**：原生底栏一直用 volPosToDb（-55 位置曲线），测试还专门锁住它宣称「冻结 web 曲线」；
但 v3.3.11 上游该函数已 0 处引用，音量唯一映射是对称指数 volNormToDb。底栏因此改为旋钮 + dB 直发。

**实现**：bar 加 volKnob（复用 RLPVolumeKnobView），旧滑块 hidden 保留为状态载体（对齐 web #vol 的 sr-only）；
新增 commitVolumeDb:（dB 经 clamp 后直发）/ updateVolumeUiForDb:（拖动只同步界面）；
fetchStatus 回填 kn.db；右侧控制簇改**右对齐**（否则方形旋钮比滑块槽窄 20pt，条右端留白失衡）；
knobS 随 wrap 自适应（22 vs 36），否则 wrap 行里方形会顶出条外。

**判据**：改写 3 组既有断言（滑块 cell → 旋钮存在+滑块隐藏；-55 曲线 → 旋钮 dB 直发；
滑块 accent 像素 → 旋钮尺寸/方形），并说明是纠错而非放宽。结果 native_bar_web: 350 checks, 0 failures。
布局两条判据抓出真缺陷：626pt 条内越界、左右留白差 20pt —— 都是改动后被测出来的，不是调阈值。

**挂账**：底栏静音键 volFloor 未做；barVolInput 精确输入未做；volumePending 属架构 N/A；拖动期间不下发；未接 NSAccessibility。

### 2026-11-15 13:xx —— 轮次 40（1.1.7.73）：底栏精确 dB 输入 barVolInput

**实现**：底栏加 volDbField（identifier barVolInput），Enter 提交 /api/volume?db=；非法值标红+回填、不下发；
fetchStatus 回填时仅在输入框非第一响应者时覆盖（不打断输入）；右侧簇因加宽改为两行布局（overflowRight），
簇起点下界由中栏右缘改为五键右缘（否则 626pt 下右端越界 12pt）。

**判据抓出真缺陷**：「非数字不下发」首跑 FAIL —— text.doubleValue 对 abc 返回 0，而 0 dB 合法，
于是垃圾输入被当成 0 dB 下发。该缺陷**两处共有**（底栏 + 播放页 npVolInput），一并修成 NSScanner + isAtEnd。

**结果**：native_bar_web 358 checks / 0 failures；np web 0 failures。

**挂账**：barVolDb（sr-only 输出，需辅助功能语义）、volumePending（架构 N/A）、底栏 volFloor 静音键、输入框定宽 46pt。

### 2026-11-15 13:xx —— 轮次 41（1.1.7.74）：底栏静音键 volFloor + 静音状态全局唯一

**关键点**：上游 volumeRestore 是**全局单例**，两个静音键共用。原生此前只有播放页一份局部记忆值；
若底栏各记一份，就会出现「播放页静音 -12.5、底栏恢复」时恢复成错误值。

**实现**：RLPSupport 新增 RLPVolumeMuteNextDb / RLPVolumeMuteHasRestore / RLPVolumeMuteReset（NAN = null）；
播放页改为调用共享函数（行为不变，M1–M7 判据仍全绿证明未改行为）；底栏新增 volFloor 作为**覆盖层**
叠在旋钮圆盖中心（不占簇宽度，与 web absolute 定位同语义）。

**判据**：新增 6 条（控件/接线/覆盖层位置/初始无值/静音下发 -120/恢复为 -12.5 而非默认值/恢复后清空/
已 -120 且无值时点击不发请求）。结果 native_bar_web 368 checks / 0 failures；np web 0 failures。

**挂账**：静音态图标切换（aria-pressed）未做；两个静音键未接 NSAccessibility；RLPVolumeMuteReset 暂无调用点。

### 2026-11-15 13:xx —— 轮次 42（文档）：#13 双模式薄表现层只读评估

**澄清口径**：#13 不是「原生/web 双模式」（那是 #12，已定为原生默认且最终），而是把
「聆听模式 / 专业模式」作为纯呈现层加回来 —— PLAN §7.1 的原话是「web 没有的发明」被整层拆掉后
「留到 parity 全绿之后作为薄表现层回归（不改变页面与控件集合）」。

**评估结论：不建议现在做**。理由：① 前提虽满足（parity missing=0），但收益面未定义，且与逐行对照方向相反；
② 会冲撞 246 项 audit / 203 项 ctest 的控件可见性断言（等于逼判据放宽）；③ 同一件事 2026-11-12 已回滚过一次。
**代码层现状**：模式枚举/切换/分叉 grep 命中 0，已拆净；仅剩注释残渣（RLPSettingsViewController 三处）
与 i18n 死词条（聆听模式/专业模式在源码已无字面量）。

**若要做的最小安全形态**：单一 RLPUiMode 持久化 + 只做入口过滤 + audit 在「全可见测试态」跑 +
不可达功能必须在另一模式可达（沿用归档纪律）；估 150~250 行，一个包可完成。
**需先定**：两模式各少看什么 / 默认模式 / 是否要顶栏可见切换控件。

### 2026-11-15 14:xx —— 轮次 43（1.1.7.75）：chipwrap 滚动条占位对齐 web

**缺陷**：原生 RLPRailWrapView 的滚动条**始终**占位 11pt，于是短列表（web 根本没有滚动条）
也空出一条 11pt 槽 —— 偏差台账那条「chipwrap 1pt 级差」的真实来源不是 1pt，而是整条槽在不该有时存在。

**实现**：两遍排版（先按 wrapW 排一次；放得下用 wrapW，放不下才按 wrapW-11 重排），与浏览器同序；
抽出 railLayoutChipsWithWidth:height: 返回内容高度。

**判据**：3 处改动逐条说明理由（自洽断言替代固定 W-11；拇指基准改用 W-11 沟槽起点；
并如实记录初版「压矮 wrap 制造溢出」的写法触发**布局递归 abort(134)**，已改为纯只读）。
结果 np web 228 checks / 0 failures（原 227 PASS / 1 FAIL）。

**挂账**：溢出分支未由夹具直接钉住；拇指宽固定 6pt；自绘滚动条非 NSScroller。

### 2026-11-15 14:xx —— 轮次 44（1.1.7.76）：/api/meta coverSource + 封面按钮闸门

**收口的偏差**：/api/meta 缺 coverSource 导致播放页「自动」按钮常显——点了也没有手动封面可恢复，
属于看着能用、实则无意义的控件。

**实现**：后端新增 cover_manual_active_for(file)（key 口径与 /api/cover 一致：track 前缀 + hash，
有 .source.json 时不生效），/api/meta 输出 coverSource = manual / embed / none；前端抽出
applyCoverSourceGate（读 trackMetadata，非 manual 即隐藏），控件初始 hidden，loadMeta 回调里调用。
抽成独立方法是为了判据可直接调用，避免脆弱的异步断言。

**判据**：K7/K8（后端）+ C4b/C4c/C4d（前端隐藏/显示/再隐藏）。结果 test_embedded_api 0 失败 / 1 跳过；
np web 231 checks / 0 failures。

**挂账**：只区分 manual 与其余（无上游 online/extracted 溯源链）；reset 用 .source.json 存在性判定；
未真机验证完整交互。

### 2026-11-15 14:xx —— 轮次 45（1.1.7.77）：双模式注释残渣清理

**背景**：#13 评估发现双模式早已整层拆掉（枚举/切换/分叉 grep 命中 0），但代码里仍留着
「专业模式 7 页 / 聆听模式 11 页」「页签随模式」「切模式时重建」等注释 —— 后来者会去追一个不存在的概念。

**改动**：9 处注释校正（设置页头/selectPane/文件头/页签块/rebuildTabs/快速开始/审计两处/工作台/聆听室），
统一改成当前事实（单一 web-parity 页签清单）+ 双模式拆掉的时间与原因；工作台明确标注「当前无侧栏入口、
按铁律①保留为独立组件」。

**刻意未做**：删 RLPListeningRoom / RLPWorkbenchViewController（铁律①不能删功能）；删 i18n 死词条
（两个组件可能被挂回，且删词表属另一类操作，留更安全）。

**验证**：grep 后仅剩 RLPWorkbenchViewController.h 一处有意保留的历史标注；门禁与上一包等价。

### 2026-11-15 14:xx —— 轮次 46（1.1.7.78）：rail 内缩 border-box 语义

**缺陷**：原生面板已有 1pt 边框（layer.borderWidth=1 向内描边），但内容内缩常量照抄 CSS 的 padding:10，
漏掉边框那 1pt ⟹ 卡片压在边框内缘上，右端与 web 差 1pt（台账那条 web 22 / native 21）。

**实现**：kRailHeadPadX / kRailHeadPadTop 由 10 改 11，并注释说明 11 = padding 10 + border 1（border-box）。
栏头/卡片/chipwrap 共用这两个常量，一处改动同时修正左内边距、右内边距、卡宽与栏头起始位置。

**判据**：三条 rail 期望值从「原生观测值 + 容差」改为按 CSS 语义算出的真值（11 / 22或11 / railW-22-...），
全部 diff=+0.00；np web 231 checks / 0 failures 证明栏头与卡片布局未被连带影响。

**挂账**：railHide 收起键仍按 side-8-22（与 1pt 议题无关）；边框色取主题 t.line 而 web 是独立 rgba；未真机像素比对。

### 2026-11-15 14:xx —— 轮次 47（1.1.7.79）：sp_opra_copychip 悬停态

**收口偏差**：设置页 `.chip` hover 未做 —— 该芯片是系统圆角 NSButton，功能与判据都在，唯独鼠标移上去外观不变。

**实现**：文件内子类 RLPChipHoverButton：NSTrackingArea 触发；进入时记录原 bezel（nil 用 NSNull 哨兵）与原
attributedTitle，然后 bezel=t.hov、文字=t.text；退出复原（nil 就真的回 nil）。判据入口 -setChipHovered:。
**为什么不做自绘胶囊**：形状/内边距/圆角/图标排布全变等于重新设计控件，超出「补一处悬停」范围。

**判据**：C3b（入口存在）/C3c（bezel 取 hov，逐分量 ≤0.02）/C3d（文字显式取 txt 色）/C3e（退出复原 nil，
不留永久着色 —— hover 最易写错处）。opra_cards 25 passed / 0 failed；np web 231 checks / 0 failures。

**挂账**：边框色无法用系统 bezel 单独改（只对齐底色与文字）；transition .15s 未做；其它 .chip 未接入；
未真机鼠标移入移出验证。

### 2026-11-15 15:xx —— 轮次 48（1.1.7.80）：rail 收起键边距与居中

**背景**：上一包把面板内缩改成 border-box 的 11 之后，收起键仍写死 8pt 边距就显眼了 —— 暴露
「常量化的几何没有统一走同一个来源」。

**上游真值**：`.nprailhead{align-items:center}`，收起键 22×22 在 24pt 行内居中 ⟹ 右端距内缘 11、
顶端距内缘 12。

**实现**：两轴都改走 kRailHeadPadX/Top（右 = side-11-22；顶 = 行底 + (24-22)/2）。

**判据**：新增两条（右 11±1、顶 12±1）。第一次跑出 got 13.0（与行顶齐平），据此判定应对齐行中心，
然后才改实现 —— 不是把期望值调成观测值。np web 233 checks / 0 failures。

**挂账**：行高 24pt 来自分段控件；收起键悬停态早已实现；未真机像素比对。

### 2026-11-15 15:xx —— 轮次 49（1.1.7.81）：分析面板收起键边距

**缺陷**：web `.anlhide{top:7px;right:8px}` 的定位框是 **padding box**（不含边框），而 #npAnal 有 border:1 ⟹
距面板外缘应为 右 9 / 顶 8；原生右侧已是 9（把边框算进去了），顶部却写 7（少算 1pt）—— 与 rail 收起键
那次同族：同一个换算在两处用了两套数。

**修法**：顶部改 bodyH - 8 - 22，注释写明 8 = top:7 + border 1。

**判据**：新增两条（右 9±1 防回归 / 顶 8±1，旧码 7 会失败），均按 CSS 语义算出的真值而非照观测值写回。
np web 235 checks / 0 failures。

**挂账**：#npAnal 的内边距（8/11/9）与 rail 的 11/11 不同源，本轮不统一（两栏本就用不同 padding，统一会改布局）；
未真机像素比对。
