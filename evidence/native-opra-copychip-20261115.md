# `sp_opra_copychip` 补齐真实控件（1.1.7.60）

## 1. 假绿是怎么来的

`evidence/native-known-deviations-20261114.md` #12 记录了这个问题：

- web 侧（`src/net/ui_script.h:10996-10997`）有 **1 个 `.chip`**：
  `<span class=chip id=sp_opra_copychip title="复制 OPRA 项目官网链接">` + 12×12 复制 SVG +
  `https://opra.roon.app/`；`:11947-11955` 绑定 `copyChip.onclick` →
  `navigator.clipboard.writeText('https://opra.roon.app/')` + `toast('已复制来源链接: …')`。
- 原生旧版**只有字符串**：`RLPSettingsViewController.mm:702` 的 `RLPControlIdentifier`
  字典里 `@"sp_opra_copychip": @"sp_opra_copychip"`，`:628` 的 `notSettingKeys` 里也有一条。
  屏幕上没有控件、没有 target/action、没有 NSPasteboard 写入。
- `tools/native_ui/parity_scan.py` 只从源码抽 `identifier = @"…"` 字面量，
  所以 `docs/native-ui/parity.tsv:135` 把它标成 `done`；`behavior_scan.py` 只抽
  `D('id').on<event>` 的 50 条绑定，而 web 用的是 `var copyChip = D(...)` + 变量 `.onclick`，
  同样漏掉。**静态存在性 ≠ 功能存在**，这一条正好把两类扫描器的盲区一起暴露。

## 2. 实现（对齐 web）

`tools/native_ui/RLPEqualizerView.mm` 的 OPRA 段「搜索输入 + 搜索按钮」同一行追加：

| 项 | 值 |
|---|---|
| identifier | `sp_opra_copychip`（与 web/parity 表一致） |
| 控件 | `NSButton`（`NSBezelStyleRounded`、11.5pt、SF Symbol `doc.on.doc` 代替 web 内联 SVG） |
| 文案 | `https://opra.roon.app/` |
| tooltip | `RLPTr(@"复制 OPRA 项目官网链接")` |
| action | `onCopyOpraLink:` → `NSPasteboard.generalPasteboard` 写 URL + `RLPToast(已复制来源链接: + URL)` |

i18n 复用词表现有词条 `已复制来源链接:`（`Source link copied: `）与
`复制 OPRA 项目官网链接`，**未改任何生成表**（`native_i18n_coverage` 门禁保持绿）。

## 3. 红 → 绿

`tests/test_native_opra_cards.mm` 新增 C1–C5 五条判据（真实视图树、是 NSButton、
有 target/action、标题含 URL、点击后剪贴板 == URL）。

| 轮次 | 结果 | 证据 |
|---|---|---|
| 旧码（仅加判据，实现未加） | build 0 error；`native_opra_cards` **2 FAIL**（C1 控件不存在、C2 不是按钮；C3–C5 因 `btn=nil` 跳过） | `evidence/native-opra-copychip-red-20261115.log` |
| 新码（1.1.7.60） | build 0 error；5 项相关 ctest **全绿**（`native_opra_cards` / `native_settings_cards` / `native_settings_granularity` / `native_target_curve` / `native_npmeta_chips`） | `evidence/native-opra-copychip-green-20261115.log` |

## 4. 挂账

- AppKit 用 `NSButton` + SF Symbol 近似 web 的 `.chip` + 内联 SVG，造型非逐像素复刻；
  行为（点击复制链接 + toast）逐字对齐。
- 本项属本仓 web 版已有的能力补齐；v3.3.11 新增功能点另见
  `evidence/native-upstream-v3311-port-list-20261114.md`。
