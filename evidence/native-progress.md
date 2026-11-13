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
