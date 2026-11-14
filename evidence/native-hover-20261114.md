# web hover 态统一（1.1.7.46，按对照表 #65/#66/#67）

## web 真相（`src/net/ui_page.h`）
| 选择器 | hover 视觉 |
|---|---|
| `.k` | `background:var(--hov2);color:var(--txt)` |
| `.k.big` | `filter:brightness(1.08)`（accent 圆键提亮） |
| `.npclose` | `background:#fff;transform:scale(1.04)`（深色 `rgba(48,50,58,.96)`） |
| `.nptoggle` | `background:#fff;color:var(--txt);transform:scale(1.04)`（深色同上） |
| `.nprailhide` / `.anlhide` | `background:var(--hov2);color:var(--txt)` |
| `.chip` / `.npcast` | `background:var(--hov);color:var(--txt);border-color:var(--acc)` |
| `.npchip` | `background:rgba(255,255,255,.09);border-color:rgba(255,255,255,.14)`（浅色 `rgba(15,23,42,.06)/.14`） |
| `.npseek` | `height:5px → 7px`（1.1.7.44 已做，本轮回归断言守住） |

静态态一并核对（顺带修正）：
`.npclose/.nptoggle` 的底是 `rgba(255,255,255,.92)`（深色 `rgba(30,32,38,.92)`），
旧码用的是**不透明** `--bg` ⟹  hover 前后肉眼无差。本轮改成 web 的 .92 半透明底，
hover 时才可见 `.92 → 1.0` 的提亮 + 1.04 缩放。

## 判据（`tests/test_native_nowplaying_web.mm` 追加 35 条）
每条都量**实际视觉值**（`CALayer.backgroundColor`/`borderColor` 逐分量、`transform.m11`、
`contentTintColor`），并验证 `trackingAreas.count ≥ 1`（证明鼠标真能触发），**不是"有跟踪区就算过"**：
- `npclose`：静态底 `.92 白` → hover `#fff`（alpha .92→1）+ `scale 1.04` → 退出恢复静态底与 identity；
- `nptoggle`：同款 + 字色 `--mut → --txt`；
- `np.rep`：无底色 → hover `--hov2` + 字色 `--txt`，圆角 9（web `.k`）；
- `np.prev`：hover `--hov2`；
- `np.play`（`.k.big`）：accent 底不变为透明，hover 底色**变化**（brightness 等价提亮）；
- `npEqChip`：边 `--line → --acc`、底 `--bg3 → --hov`、退出恢复；
- `npCastBtn`：边 `--acc` / 底 `--hov`；
- `npChip.歌曲`（右栏卡片）：底/边改为 web 的半透明 hover 值，退出恢复 `applyTheme` 静态值；
- `npSeek`：5→7pt 回归断言。

## 红 → 绿
| 轮次 | 结果 |
|---|---|
| 旧码（1.1.7.45） | **10 FAIL**（8 个控件没有 hover 状态机、`npclose` 静态底不是 .92、`npRep` 圆角不是 9） |
| 新码 | **121 passed / 0 failures**（86 既有 + 35 新） |

证据：`evidence/native-hover-red-20261114.log` / `-green-…log`。

## 实现
- 新 `RLPHoverButton : NSButton`：`NSTrackingMouseEnteredAndExited|ActiveInKeyWindow|InVisibleRect` 跟踪区
  + `hovered` 状态 + `hoverApplier` 视觉回调；`setHovered:` 是鼠标事件与判据共用的唯一入口。
- `.k` 键改用 `NPCreateKeyButton`（`RLPHoverButton` + web 圆角 9/17），`.k` 与 `.k.big` 分别注入回调；
  `play` 的 brightness 用「accent 混 10% 白」等价（AppKit 无 CSS filter）。
- `webButton:` 统一返回 `RLPHoverButton`（无 hover 语义的按钮不注入回调，视觉不变）。
- `npclose`/`nptoggle` 静态底改 web 的 .92 半透明，hover 提亮到不透明 + `CATransform3DMakeScale(1.04)`；
- `.chip/.npcast` 通过 `applyChipHover:hovered:`（hover 时重写 attributedTitle 前景色——只改
  `contentTintColor` 不会改 attributedTitle 自带颜色）；投放芯片退出时走 `applyCastChipStyle` 恢复绿样式。
- 面板收起键 `.anlhide/.nprailhide`：hover `--hov2` + `--txt`。
- 右栏 `.npchip`：`RLPRailChipView` 加跟踪区 + `setHovered:`（hover 改底/边，退出 `applyTheme`）。

## 如实挂账
1. **范围**：本轮只覆盖**正在播放页**的 hover；设置页的 `.chip` 仍只有 AppKit 默认按下高亮（不在本轮 np 页差异表范围内）。
   > **2026-11-14 更新（1.1.7.56）**：底部播放条 `#bRep/#bPause/#bPrev/#bNext/#bStop` 的 `.k / .k.big`
   > hover 已补齐（`RLPBarKeyButton`，见 `evidence/native-bar-hover-20261114.md`，
   > `test_native_bar_web` 315→346 条、红 5F→绿 0F）。此条挂账**只剩设置页 `.chip`**。
2. `.k.big` 的 `brightness(1.08)` 用「混 10% 白」近似，不是 CSS filter 的像素级复刻（无 filter API）。
3. hover 判据走 `setHovered:`（与 `mouseEntered/Exited` 同一入口），未做真实鼠标注入（遵守「不做键鼠自动化」）。
4. `.npchip.on`（选中卡）hover 优先级未做区分：现在 hover 会覆盖选中底/边；web 里 `.npchip.on` 规则在
   `.npchip:hover` 之后，选中卡 hover 不应变色。若实机观感被选中态困扰，下一轮补。
