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
