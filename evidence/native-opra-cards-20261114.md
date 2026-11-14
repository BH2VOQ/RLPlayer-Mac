# P1 EQ/OPRA：型号卡片 + 预设卡片墙（对齐 web）

- 日期：2026-11-14（P0-1 / P0-2 之后第三包）
- 仓库：`/Users/august/Downloads/DQ/RLPlayer`，branch `main`
- 基线：1.1.7.34（`3419fa3`）→ 本包 1.1.7.35
- 写者：single writer
- 范围：`tools/native_ui/RLPEqualizerView.mm`（OPRA 区重做）、`tests/test_native_opra_cards.mm`（新判据）、`CMakeLists.txt`
- 纪律：桩核心、`backend=null` 语义（不启动播放核心、不开音频设备、不出声）；离屏窗口不显示。

## 1. web 真相 → 原生落点（用户「改都没改」的那一段）

| 项 | web（`src/net/ui_script.h:11936-12140`） | 原生旧码 | 本包 |
|---|---|---|---|
| 搜索结果 | `#eqModelCards`：型号卡片，`vendor · name` + 「OPRA 校准预设 / 查看调音预设」 | 一个 `NSPopUpButton`（型号下拉） | 型号卡片栈（`opra.model.card`），点击选中 |
| 预设 | `#eqPresetCards`：卡片墙；每条 = author·details、`N 段` 徽标、`.tc-curve` 目标曲线小图、目标曲线说明 | 第二个 `NSPopUpButton`（预设下拉）+ 一个「应用」按钮 | 预设卡片栈（`opra.preset.card`），每条含标题/徽标/曲线小图/说明/前级增益·段数/应用按钮 |
| 当前态 | `isActive = (ADV.opraproduct===productId && ADV.oprapreset===p.id)`；按钮文案 `已应用当前预设` / `应用到 EQ` | 只有下拉选中项；没有"当前态"文字 | 读 `/api/settings` 的 `opraproduct/oprapreset`；当前卡显示「已应用当前预设」，其余「应用到 EQ」 |
| 曲线小图 | `targetCurveSvg(kind)`，横轴归一化 0..1、纵轴 -2..+9 dB | 只在主 EQ 图上叠一条虚线 | 每张预设卡一张 `RLPOpraCurveThumb`（复用 `RLPTargetCurveLibrary plotPoints:`，同样 -2..+9） |
| 应用 | `POST /api/opra/apply` body `productId=&presetId=` → 成功后 `saveSettings(true)` 写回 `eq/opraproduct/oprapreset` | 已实现（第8项修过） | 保持同一请求体与写回；成功后卡片当前态立即翻转并 re-render |
| 空态 | 无输入→引导；无结果→「未找到匹配的耳机型号…」；无预设→「该型号暂无可用调音预设」 | 只有下拉空；文案不全 | 与 web 同文案（复用既有 i18n 词条，未新增词条） |

## 2. 改了什么（结构）

- 新增三个私有视图类（都在 `RLPEqualizerView.mm`）：
  - `RLPOpraCurveThumb`：只画曲线 + 首尾圆点，不画坐标轴（web `.tc-curve` 同构）；
  - `RLPOpraModelCard`：`vendor · name` + 「OPRA 校准预设 · 查看调音预设」，active 用 `accentWeak/accent`；
  - `RLPOpraPresetCard`：标题（author · details）、`N 段` 徽标、曲线小图、目标曲线名、`前级增益/频段数`、应用按钮；`mouseDown` 选中、按钮应用。
- `RLPEqualizerView` 的 OPRA 区改为 `opraModelCards` / `opraPresetCards` 两个 `NSStackView`；删除了两个 `NSPopUpButton` 与旧的 `onOpraProduct/onOpraPreset/onOpraApply`。
- `applyOpraQuery:` → 只渲染型号卡；点击型号卡才 `loadProductPresets:`（web 同语义，不再自动选第一个）。
- `loadProductPresets:` 保留原竞态守卫（`opraProductSeq`），拉到 presets 后按 `appliedPresetId` 决定"当前卡"，再逐条渲染。
- `applyOpraPreset:presetId:` 保留原 `/api/opra/apply` + `settings` 写回 + `reload`，并新增：成功后立即更新 `appliedProductId/appliedPresetId` 与卡片文案。
- `reload` 额外读一次 `/api/settings` 的 `kv.opraproduct/oprapreset`（与 web `ADV` 同源），卡片"当前态"不再靠猜。

## 3. 红 → 绿（同一条测试，只换 `RLPEqualizerView.mm`）

| 阶段 | 生产码 | 结果 | 日志（本机 evidence/，按 .gitignore 不入库） |
|---|---|---|---|
| RED | 1.1.7.34 原版（`git stash` 回旧 EQ 视图） | **1 passed / 6 failed**，exit 1 | `evidence/native-opra-cards-red-20261114.log` |
| GREEN | 本包 | **16 passed / 0 failed**，exit 0 | `evidence/native-opra-cards-green-20261114.log` |

红的 6 条：无卡片栈（`opraModelCardViews`/`opraPresetCardViews` 取不到 ⟹ 0 张）、
无当前态（settings 未读 ⟹ applied 为空）、点应用卡没有请求/没有 settings 写回。
（旧码是下拉框，UI 上根本没有"卡片"这个对象，所以断言在结构层就红。）

绿覆盖的场景（`tests/test_native_opra_cards.mm`）：

1. `reload` 从 `/api/settings` 读到 `opraproduct=p1 / oprapreset=e1`；
2. 搜索 "HD" → **1 张型号卡**（vendor · name = Sennheiser · HD 650；identifier 统一）；
3. 点型号卡 → **2 张预设卡**：标题 = `author · details`（不是后端没有的 `name`）、`10 段` 徽标、
   曲线小图有真实曲线像素（背景除外 >20 px）、前级增益/段数、`应用到 EQ`；
4. 当前态：settings 的 e1 卡显示「已应用当前预设」，e2 显示「应用到 EQ」；
5. 点 e2 的「应用到 EQ」→ 真发 `/api/opra/apply`（`productId=p1&presetId=e2`）→
   写回 `/api/settings`（`eq=&opraproduct=p1&oprapreset=e2`）→ 卡片当前态翻到 e2。

## 4. before / after（同一夹具、同一视口、同一主题）

- `evidence/native-opra-before-20261114.png`（1.1.7.34 旧码：型号下拉 + 预设下拉 + 一行说明）
- `evidence/native-opra-after-20261114.png`（1.1.7.35：型号卡片 + 预设卡片墙 + 当前态）
- 两图都由 `tests/test_native_opra_cards.mm` 的 `RLP_OPRA_SHOT=<path>` 一次性离屏渲染产生
  （`RLPEqualizerView` 的整页文档视图，980 pt 宽；不显示窗口、不启动核心；探针代码在测试里，
  不额外新增可执行文件）。
- before 截图里旧码仍会显示下拉框（这正是用户说「改都没改」的形态）；after 截图是卡片墙。

## 5. 门禁（串行，机器空闲；本包树 = 1.1.7.35）

| 门禁 | 命令 | 结果 |
|---|---|---|
| 构建 | `cmake --build build-mac -j8` | **exit 0** |
| 全量单测 | `ctest --test-dir build-mac -j1 --output-on-failure` | **197/197 passed, 0 failed**（395.78 s，exit 0；`evidence/native-opra-cards-ctest-197.log`） |
| 功能审计 | 隔离目录 → `rlplayer_native --audit` | **246 passed, 0 failed**，exit 0（`evidence/native-opra-cards-audit-20261114.log`） |
| 移植扫描 | `python3 tools/native_ui/parity_scan.py --check` | exit 0（missing=0） |
| 行为扫描 | `python3 tools/native_ui/behavior_scan.py --check` | exit 0（actionable=0） |
| i18n | `python3 tools/gen_i18n_table.py --check` | `OK: i18n table up to date (2318 pairs)`，exit 0 |

**两次失败/假红的如实记录**：
1. 第一次全量 ctest（本包树）：`native_target_curve` 真实失败（旧用例断言"型号/预设两个下拉框"，
   本包已按用户要求删除下拉改成卡片）⟹ 该用例**更新**为新入口（型号卡 `click` → 预设卡 `selectCard`
   → 卡片 `applyBtn`）；更新后单跑 21/0，第二次全量 197/197。
2. 同一次全量 ctest 还有 `native_ui_functional` bus error（既有 open flake，见 gap 文档）；
   单独重跑 `rlplayer_native --audit` **246/0** 通过；第二次全量 ctest 该用例通过。

## 6. 如实挂账

1. 卡片布局是**固定高度**（型号卡 48 pt、预设卡 164 pt）+ 文本单/两行截断；长 details
   会被截断而不是自动增高（web 卡片是自适应高度）。本轮判据只固定"内容存在/文案/当前态/请求"，
   没有断言与 web 的逐像素间距一致；如后续要逐像素对齐，需要再做一轮文本实测布局。
2. 型号卡副标题把 web 的两段（「OPRA 校准预设」+ 右侧「查看调音预设」徽标）合成了
   一行「OPRA 校准预设 · 查看调音预设」。语义一致，样式不是逐像素一致。
3. 选卡后**重渲染整墙**（简单可靠；代价是每次点选会重建卡片视图）。不涉及数据请求浪费。
4. 未做真实耳机索引/真实预设的实机点选（需要用户实机；测试用桩夹具 2 型号/2 预设）。
5. 目标曲线小图只示意，摘用库里的 11 条目标曲线（与 web 同一份），不画真实测量频响。
