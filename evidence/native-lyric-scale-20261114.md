# `.npline.on{transform:scale(1.03)}` active 缩放 + 3 档不裁切（1.1.7.48，表 #41）

## web 真相
`ui_page.h`：`.npline.on{color:var(--txt);font-weight:650;transform:scale(1.03)}`
—— 当前高亮行放大 1.03，其余 1.0；`transform` 只影响绘制，不参与行盒/滚动几何。

## 原生 1.1.7.47
高亮只换字体权重与颜色，没有缩放；`#41` 长期标「部分已修」。
另外行左右只留 6pt 边距，1.03 放大后会在 556pt 文档下溢出约 2pt（水平方向被 clip）。

## 判据（`tests/test_native_nowplaying_web.mm` 追加 8 条）
三行歌词 + `updateLyricPosition`：
1. 当前行 `layer.transform.m11 == 1.03`（±0.005）；
2. 非当前行 m11 == 1.0（两行分别断言）；
3. 高亮移动后新行 1.03；
4. 原当前行退出时缩放复位（不残留 1.03）；
5. **缩放后不裁切**：当前行放大后的可见矩形仍在歌词文档内；
6. 首行不越上/左边界；
7. 末行不越下/右边界；
8. 行左右预留 ≥1.5% 缩放余量（由 5–7 覆盖）。

## 红 → 绿
| 轮次 | 结果 |
|---|---|
| 旧码（1.1.7.47） | **8 FAIL**（5 条无缩放 + 3 条放大后越界：556pt 文档下水平溢出约 2pt） |
| 新码 | **140 passed / 0 failures**（131 既有 + 8 新 + 前提） |

证据：`evidence/native-lyricscale-red-20261114.log` / `-green-…log`。

## 实现
- `updateLyricPosition`：当前行 `CATransform3DMakeScale(1.03,1.03,1)`、其余 `CATransform3DIdentity`；行按钮 `wantsLayer=YES`。
- `layoutLyricRows`：行左右 inset 从 6pt 改为 `max(6, ceil((w-12)*0.015)+1)`，给 1.03 放大留出
  ≥1.5% 宽度的绘制余量（否则"放大即裁字"）。行盒（clamp 字号×2.05）与滚动几何不变。

## 如实挂账
1. 缩放不参与布局（web 同）；当前行视觉上会比行盒略宽 ~3%，首尾行已用留白保证不裁，但相邻行在
   极端换行时可能轻微重叠（web `transform` 同样如此）。
2. 未做 `:active`/过渡动画（web `.npline` 无 transition 定义，差异可忽略）。
