# rail 面板内容内缩按 border-box 起算（1.1.7.78）

> 收口《已知偏差》台账里「chipwrap / rail 1pt 级差」的最后 1pt。

## 1. 上游真值

```css
.nprailcard{ padding:10px; border:1px solid rgba(255,255,255,.08); border-radius:14px;
             box-sizing:border-box; }
```

`box-sizing:border-box` 下，**边框算在 padding 之内**：内容内缘 = `padding 10 + border 1 = 11`。
于是 web 的几何是：

| 项 | web |
|---|---|
| 左内边距（卡片左缘到面板左缘） | **11** |
| 右内边距（不溢出） | **11** |
| 右内边距（溢出，滚动条占位 11） | **22** |
| 卡宽（溢出） | railW − 22 − 11 |

## 2. 原生缺口

原生面板**已经有** 1pt 边框（`applyTheme` 里 `layer.borderWidth = 1`、`cornerRadius = 14`、同色系背景），
但内容内缩常量 `kRailHeadPadX / kRailHeadPadTop` 是 **10**（照的是 CSS 的 `padding:10`，漏掉了边框那 1pt）。
AppKit 的 `layer.borderWidth` 是**向内**描边，因此卡片实际压在边框内缘上，且右端与 web 差 1pt ——
偏差台账里那条「web 22 / native 21」就是这么来的。

## 3. 实现

```diff
-static const CGFloat kRailHeadPadTop = 10.0;
-static const CGFloat kRailHeadPadX   = 10.0;
+// 11 = web 的 padding:10 + border:1（box-sizing:border-box ⟹ 内容从边框内缘起算）。
+// 原生 layer.borderWidth=1 是向内描边，所以内容也必须从 11 起算。
+static const CGFloat kRailHeadPadTop = 11.0;
+static const CGFloat kRailHeadPadX   = 11.0;
```

栏头、卡片、chipwrap 全部走这两个常量，因此**一处改动同时修正**：左内边距、右内边距、卡宽、栏头起始位置。

## 4. 判据

| 判据 | 旧期望 | 新期望（web 精确值） |
|---|---|---|
| `rail.padX.left` | 10（自造基准） | **11** |
| `rail.padX.right` | 21（溢出）/ 10 | **22（溢出）/ 11** |
| `rail.card.width` | railW − 20 − (溢出 ? 11 : 0) | **railW − 22 − (溢出 ? 11 : 0)** |

这些期望值此前是「原生侧观测值 + 2pt 容差」自造的，属于**判据向实现低头**；本轮按 CSS 语义算出真值，
并把容差仍在（几何量测本身有 ±1 的像素取整空间）。

## 5. 结果

- `test_native_rail_cards: 52 passed / 0 failed`（三条 rail 判据全部 `diff = +0.00`）；
- `np web: 231 checks / 0 failures`（栏头与卡片布局未受连带影响）。

## 6. 如实挂账

1. `railHide` 收起键仍按 `side - 8 - 22` 定位（8pt 边距是早期实测值，未随本轮常量一起复核）——
   它与本条 1pt 议题无关，留在偏差台账。
2. 边框颜色取 `t.line`（主题色），web 是 `rgba(255,255,255,.08)` 的独立值；暗色下近似，亮色下有细微差别。
3. 未做真机像素比对（离屏判据只量 frame 距离，不量实际描边像素）。