# `#npAnlBody` 13px 滚动沟槽 —— 设计（**未实现**，交下一轮单独提交）

> 本文件是设计，不是已修项。本轮先写清「沟槽常驻 13px」与既有 `native_analysis_panel`
> 311pt 卡宽判据、以及「单层滚动」判据的关系；**代码未改**，避免在 hover/歌词/缩放三个包之后
> 再叠一个未验证的几何变更。

## web 真相（`src/net/ui_page.h:926-929`，行内注释就是设计意图）
```
#npAnlBody{overflow-y:scroll;padding-right:13px;margin-right:-11px;scrollbar-width:thin;
           display:grid;grid-template-columns:minmax(0,1fr);gap:8px;align-content:start}
#npAnlBody::-webkit-scrollbar{width:6px}
#npAnlBody::-webkit-scrollbar-thumb{background:var(--line);border-radius:3px}
```
注释原文：`卡片右缘因此仍与左缘对称（≈12px），滚动条只画在沟槽上、永远不压圆角。
判据见页面内自检 C8（width(L0)==width(L1)==width(L2) 且卡片右缘距滚动条 ≥8px）`。

## 几何推导（待运行时实测确认）
设面板宽 W、面板内边距 11：
| 量 | web（式） | 原生现值 | 改后 |
|---|---|---|---|
| 卡片区盒子宽 | `W-22+11 = W-11`（margin-right -11 撑进右内边距） | `W-22` | `W-11` |
| 卡片内容宽 | 盒子宽 - `padding-right:13`（再扣滚动条占位 6） | `W-22` | 需实测 |
| 卡片左缘（面板坐标） | 11 | 11 | 11 |
| 卡片右缘（面板坐标） | `W-13`（含 padding 时） | `W-11` | `W-13` |
| 滚动条 | 6px，画在右缘沟槽里 | 无可见滚动条（只有滚轮） | 自绘 6px 拇指 |

⚠️ **311pt 判据必须先实测再动**：`tests/test_native_analysis_panel.mm:368` 现在断言
`anlcard.width == panelW - 22`（panelW=333 → 311），依据是 web。按上面的 CSS 算式 web 可能是
`W-24`（309）或 `W-30`（含经典滚动条占位 6）。**不改期望值，除非先用 web 页面 C8 在同一 panelW
下量到真实 card 宽度**；量到后按真实值更新期望并像 `rightGap 13→37` 那样在证据里披露差因。

## 「沟槽常驻」与「滚动条不压卡片圆角」如何同时成立
1. 卡片区盒子**始终**比卡片宽 13pt（`padding-right` 的等价），所以三档（L0/L1/L2）卡片宽度
   与是否有滚动条无关 ⟹ `width(L0)==width(L1)==width(L2)`。
2. 拇指**只在 13pt 沟槽内**自绘（`x ∈ [bodyW-6, bodyW]`，`bodyW = panelW-11`），
   卡片右缘止于 `bodyW-13` ⟹ 拇指与卡片矩形**不交叠**，圆角永远不被压。
3. 拇指用 `RLPNPAnalBody.drawRect` 自绘，**不新增 NSScrollView** ⟹ 「单层滚动」判据
   （可见 NSScrollView 计数）不变；滚轮仍走 `onScroll` 自定义路径。
4. 内容不溢出时拇指不画（web `overflow-y:scroll` 会保留轨道；原生无轨道，视觉更干净，
   若要求轨道常驻再加 6px 半透明轨道，属可选）。

## 计划判据（下一轮实施时先跑红）
- `anlcard.width`：按 web 实测值（候选 309/311），三档相等；
- `npAnlBody.right == panelW`（盒子撑进右内边距，等价 `margin-right:-11`）；
- 卡片右缘到 `npAnlBody` 右缘 = 13pt（沟槽常驻）；
- 溢出时 `scrollThumbRect` 存在，且 `x ∈ [bodyW-6, bodyW]`、不与任一卡片矩形相交；
- 不溢出时 `scrollThumbRect` 为空；
- 可见 `NSScrollView` 数量不增加（单层滚动判据）；
- `native_analysis_panel` 的 `rightGap`（头部状态，37）不变。

## 实施顺序（下一轮）
1. 先在 web 侧同一 panelW 下量 C8 的真实 card 宽度与右缘距离（用页面内自检或 DOM 读数）；
2. 改 `cardsW`/`anlLayoutCards`/`RLPNPAnalBody` 自绘拇指 + 暴露 `scrollThumbRect` 判据接口；
3. 更新 `native_analysis_panel` 期望值并在证据披露差因；
4. 单独提交（+0.0.1），全量门禁 + audit 截图复核。
