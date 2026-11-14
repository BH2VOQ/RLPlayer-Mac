# `.npkind` 字距 1.6（1.1.7.51，表 #11；#24 一并补判据）

## web 值（`src/net/ui_page.h`）
- `.npkind{font-size:10px;letter-spacing:1.6px;color:var(--mut2);font-weight:600;margin-bottom:8px}`（行 820）
- `.anllab{font-size:9.5px;letter-spacing:1.5px;color:var(--mut2);font-weight:700;padding:0 2px}`（行 909）

## 原生 1.1.7.50
`npKind` 用 `stringValue` 赋值，**没有 kern**（`letter-spacing` 未接）。左栏 `anlLab` 之前已按 kern 1.5
实现（创建/主题两处都是 attributed），但对照表 #24 一直没更新、也没有判据兜住，属"已实现未取证"。

## 判据（`tests/test_native_nowplaying_web.mm` 追加 4 条）
1. `npKind` 首个字符的 `NSKernAttributeName == 1.6`（±0.05）；
2. `/api/status` 刷新重写文案后 kern **仍是 1.6**（旧码用 stringValue 会把 attributed 属性冲掉）；
3. `anlLab` kern == 1.5（web `.anllab`；本轮补判据，防回归）；
4. 判据都从 **attributedStringValue** 取，不从 `font`/常量自证。

## 红 → 绿
| 轮次 | 结果 |
|---|---|
| 旧码（1.1.7.50） | **2 FAIL**（npKind kern=0；刷新后仍 0） |
| 新码 | **149 passed / 0 failures**（147 既有 + 4 新 + 前提） |

## 实现
- 新 `RLPSetKernedText(label,text,kern)`：写整串 attributed（字体/颜色/kern/段落），
  因为 `stringValue` 赋值会丢 kern；主题切换时按当前文案重设（`applyTheme` 里同步）。
- `npKind` 创建、refresh 的两处文案（「正在播放」/「正在播放 · CODEC / kHz / bit」）都走该助手。

## 如实挂账
1. kern 单位按 1x 的 px≈pt 处理（web `letter-spacing` px；原生 kern 是 pt），与既有 `.anllab` 的做法一致；
   高分屏只影响像素密度，不改变相对字距。
2. #24 的 anlLab 实现早于本包，本包只补判据并把对照表改正（不是本轮新写）。
