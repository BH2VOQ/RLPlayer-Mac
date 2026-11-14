# `#npAnlBody` 13px 沟槽 + 自绘拇指（1.1.7.49，表 #28）

## web 实测（ego 浏览器，2026-11-14 18:0x）
服务：`./build-mac/rtaweb --no-browser --port 19091`（**只碰 19091，未碰 8899**）；
ego 打开 `http://127.0.0.1:19091/index.html`，在页面里直接调 `selftestRun()`，C8 结果：

```
C8 PASS: w=264/264/264px spread=0 右缘留白=13/13/13px L1溢出=0px L2溢出=567px
```

同一 panelW 下的 DOM 实测（`#npAnal` / `#npAnlBody` / 首张 `.anlcard`）：

| 量 | 实测值 |
|---|---|
| `#npAnal` 宽 panelW | **301** |
| 卡片左缘距面板左 | 12（面板 padding 11 + 1px border） |
| `#npAnlBody` 宽 | 288（= 面板内容 277 + `margin-right:-11`） |
| body 右缘距面板右 | 1 |
| `padding-right` | 13px |
| 滚动条占位（offsetWidth-clientWidth） | **11**（不是 CSS 里的 6） |
| `clientWidth` | 277（= 288 − 11） |
| `.anlcard` 宽 | **264**（= 301 − 37） |
| 卡片右缘距面板右 | **25**（= 13 + 11 + 1） |
| C8 的 clear（clientRight − cardRight） | **13** |

## 结论（改期望值的依据）
- web 的有效关系：**cardW = panelW − 37**（在 panelW=301 时 264），其中
  左 12（padding 11 + border 1）、右 25（留白 13 + 滚动条 11 + 右内边距 1）。
- 原生面板**没有 1px 边框**、左内边距 11 ⟹ 同结构下 **cardW = panelW − 36**，
  且卡片右缘距面板右仍是 **25**（13 留白 + 12pt 拇指条：拇指 6 + 居中留白）。
- 所以 `tests/test_native_analysis_panel.mm` 的 `anlcard.width: panelW - 22`（311 @333）
  **更新为 `panelW - 36`（297 @333）**。差因（-2pt）正是上面两处：web 的 1px 边框 + 右内边距 1；
  这与上次 `rightGap 13→37` 一样属于「原生没有边框/内边距差异」的显式披露，不是随手改数字。

## 实现
- `anlBody` 盒子：`x=11`、`width = panelW − 11`（撑到面板右缘，等价 web `margin-right:-11`）。
- 卡片：`width = bodyW − 25`（右侧常驻 25：13pt 留白 + 12pt 拇指条），三档 L0/L1/L2 恒定。
- 拇指：`RLPNPAnalBody` 自绘 6px 圆角矩形（`x∈[bodyW-8, bodyW-2]`、高度按 `contentH/H` 比例、
  位置按 `scrollOffset`），**不新增 NSScrollView** ⟹ 单层滚动判据不变；内容不溢出时不画。
- 卡片高度按新宽度实测（`preferredHeightForWidth:cardW`），文本换行随窄卡变化。

## 判据（`tests/test_native_analysis_panel.mm` 新增/修改 8 条）
1. `anlcard.width = panelW - 36`（web 实测依据，见上）；
2. `npAnlBody` 右缘 == 面板右缘（`margin-right:-11` 等价）；
3. `npAnlBody` 宽 == `panelW - 11`；
4. 卡片右缘到盒子右缘 == 25（常驻沟槽；同坐标系量）；
5. 暴露 `scrollThumbRect`（自绘，不靠 NSScrollView）；
6. L2 溢出时拇指非空（contentH > 可见高）；
7. 拇指与卡片右缘 ≥13pt（不压圆角）；拇指在 body 右缘沟槽内；
8. 卡片区不是 NSScrollView（单层滚动仍成立）。

## 红 → 绿
| 轮次 | 结果 |
|---|---|
| 旧码（1.1.7.48） | **7 FAIL**（3×卡宽 311 vs 297、body 未撑到右缘、body 宽 311 vs 322、卡片右缘 gap=0、无拇指 API） |
| 新码 | **140 passed / 0 failures**（test_native_analysis_panel 全绿） |

证据：`evidence/native-gutter-red-20261114.log` / `-green-…log`。

## 如实挂账
1. **web 与原生仍差 1pt**：web 面板 1px 边框使内容从 12 开始；原生无边框（历史实现），
   `anlcard.left` 仍是 11。本轮只对齐「右缘 25 + 卡宽 panelW-36」；若要把左缘也改成 12，
   会连带影响头部状态/收起键的既有判据，需单独一包。
2. 滚动条**轨道**非常驻（web `overflow-y:scroll` 恒显轨道；原生只在溢出时画拇指）。
3. 拇指宽度 6pt（web CSS 6，但实测滚动条占位 11）；本轮把 11 作为「拇指条」总占位的一部分来算卡宽。
4. 未做触摸板惯性/分页滚动（沿用既有滚轮位移）。
