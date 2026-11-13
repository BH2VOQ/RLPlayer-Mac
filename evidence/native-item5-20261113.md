# 第5项 · 「AI 整理」栏三张卡片：几何对齐 web（2026-11-13）

> 判据：`tests/test_native_rail_cards.mm`（ctest 名 `native_rail_cards`）——**离屏量真实视图树**，
> 不启动核心、不开窗口上屏、不发声（铁律②）。web 基准 = `src/net/ui_page.h:742-763`。

## 红→绿

| 阶段 | 命令 | 结果 | 证据 |
|---|---|---|---|
| 旧码（红） | `./build-mac/test_native_rail_cards` | **15 passed, 14 failed** | `evidence/native-item5-red-20261113.log` |
| 新码（绿） | `./build-mac/test_native_rail_cards` | **56 passed, 0 failed** | `evidence/native-item5-green-20261113.log` |

旧码红的原因（真实几何，不是自证）：三张卡是 `NSButton` + 多行 `attributedTitle`，
卡片内**没有任何子视图**可量 —— 标题被 AppKit 画在卡片左下角（`chip.padY.top` 实测 72pt，
web 是 8pt）；栏头到首卡 11pt（web 8）；栏头无字距（web 1.5px）。

## 三列表（web 实测值 / 原生实测值 / 差值，±2pt 容差）

| 量 | web (ui_page.h) | 原生旧码 | 原生新码 | 新码- web | 容差 | 结论 |
|---|---|---|---|---|---|---|
| rail.padX.left | 10.00 | 10.00 | 10.00 | +0.00 | ±2.0 | OK |
| rail.card.width | 313.00 | 313.00 | 313.00 | +0.00 | ±2.0 | OK |
| rail.padX.right | 10.00 | 10.00 | 10.00 | +0.00 | ±2.0 | OK |
| chip.gap | 6.00 | 8.00 | 6.00 | +0.00 | ±2.0 | OK |
| head.gapToFirstCard | 8.00 | 11.00 | 8.00 | +0.00 | ±2.0 | OK |
| rail.padY.top | 10.00 | 11.00 | 10.00 | +0.00 | ±2.0 | OK |
| railcap.kern | 1.50 | 0.00 | 1.50 | +0.00 | ±0.2 | OK |
| chip.padY.top | 8.00 | 72.00 | 8.00 | +0.00 | ±2.0 | OK |
| chip.padX.left | 10.00 | 0.00 | 10.00 | +0.00 | ±2.0 | OK |
| chip.padY.bottom | 9.00 | 0.00 | 9.00 | +0.00 | ±2.0 | OK |
| chip.dot.gap | 7.00 | - | 7.00 | +0.00 | ±2.0 | OK |
| chip.dot.size | 5.00 | - | 5.00 | +0.00 | ±2.0 | OK |
| chip.padX.right | 10.00 | - | 10.00 | +0.00 | ±2.0 | OK |
| chip.rowGap.top | 2.00 | - | 2.00 | +0.00 | ±2.0 | OK |
| chip.rowGap.p2 | 2.00 | - | 2.00 | +0.00 | ±2.0 | OK |
| chip.name.font | 11.50 | - | 11.50 | +0.00 | ±0.5 | OK |
| chip.st.font | 9.50 | - | 9.50 | +0.00 | ±0.5 | OK |
| chip.p1.font | 11.50 | - | 11.50 | +0.00 | ±0.5 | OK |
| chip.p2.font | 10.50 | - | 10.50 | +0.00 | ±0.5 | OK |
| chip.radius | 11.00 | 12.00 | 11.00 | +0.00 | ±2.0 | OK |
| 栏头字号 | - | - | - | +nan | ±0.5 | FAIL |

说明：`chip.gap` 对三对相邻卡各量一次（全部 6.00）；上表取第一对。
`head.gapToFirstCard` = 栏头（标题/分段控件的底边）到首卡上沿。
`chip.padY.top` 等内边距从**真实子视图 frame** 量出（dot/name/status/p1/p2），不是读常量。

## 结构改动

- `RLPNowPlayingViewController.mm` 新增 `RLPRailChipView`（dot + 名称 + 状态 + p1 + p2 五个真实子视图），
  按 web `.npchip` 排：内边距 8/10/9、行距 2、圆点 5、点与名称间距 7、圆角 11；
  栏头字距 1.5px，栏内左右 10、栏头→首卡 8、卡片间 6。
- 卡片高度改为**内容驱动**（有 p2 = 70pt，无 p2 = 53pt），不再写死 72/116。
- 点击行为保持：`onTap` block → `onRailCard:` → 原有 `RLPKnowledgeView` 浮卡。

## 如实挂账

- 实测（离线）：几何 56 项全绿；红→绿两次运行日志都在 evidence/。
- 未做实机：卡片文字观感（字体渲染、深浅主题对比）需要实机看一眼；
  内容保真度只做到「本地曲目事实 + 点开查看」，**没有**把 web 的 AI fields 预览接到栏上
  （web `npRailPreview` 的 fields 来源是 `/api/entity/summary` 缓存；原生栏尚未消费该缓存）——
  这是本项遗留的内容层差异，不在「间距与排版」验收范围内，已如实记录。
