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
