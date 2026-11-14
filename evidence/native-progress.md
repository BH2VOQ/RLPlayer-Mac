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
