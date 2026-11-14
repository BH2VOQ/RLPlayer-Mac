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

## 已知 1px 偏差（**1.1.7.57 已关闭**，勿再当新 bug 反复查）
原偏差：`#npAnlBody` 卡片左缘 原生 11pt vs web 12pt（web 面板 1px 边框使内容从 border+padding 起算）。
**1.1.7.57 起原生内边距直接取 12**（面板无边框也按 web 外缘对齐），左缘差已消除；详见下方 §1.1.7.57。

**仍留 1pt（本包未动，勿当回归）**：右上角收起键 `.anlhide` 仍是 `x = side-8-22`，web 因 1px 边框应为
`side-9-22`（`right:8px` 相对 padding box）。它不影响本次左缘/卡宽/状态右缘三条判据；若要改，需单独一包
（会牵动「收起键不压状态文字」的既有断言 `NSMinX(anlHide) >= NSMaxX(stat) - 1`）。

## 如实挂账
1. **web 与原生仍差 1pt**：web 面板 1px 边框使内容从 12 开始；原生无边框（历史实现），
   `anlcard.left` 仍是 11。本轮只对齐「右缘 25 + 卡宽 panelW-36」；若要把左缘也改成 12，
   会连带影响头部状态/收起键的既有判据，需单独一包。
2. 滚动条**轨道**非常驻（web `overflow-y:scroll` 恒显轨道；原生只在溢出时画拇指）。
3. 拇指宽度 6pt（web CSS 6，但实测滚动条占位 11）；本轮把 11 作为「拇指条」总占位的一部分来算卡宽。
4. 未做触摸板惯性/分页滚动（沿用既有滚轮位移）。

---

## 1.1.7.57 —— 左缘 11→12（关闭本文件挂账 1）

### web 真值（不变，重述便于对照）
| 量 | web | 依据 |
|---|---|---|
| 内容左缘距面板外缘 | **12** | `#npAnal{padding:8px 11px 9px}` + 1px border |
| 状态右缘距面板外缘 | **38** | `.anlheadtop{padding-right:26px}` + `#npAnlStat{padding-right:2px}` + 11 padding + 1px border |
| 卡宽 | **panelW−37** | 实测 panelW=301 ⟹ 264（= 12 左 + 264 卡 + 25 右） |
| `#npAnlBody` 宽 | panelW−13 | 内容 277 + `margin-right:-11`，右缘距面板右 1（= border） |

原生面板**无 1px 边框**，旧实现取 `anlPadX=11` 自洽成「左 11 / 状态右 37 / 卡宽 panelW−36 / body panelW−11」，
四条期望把这 1pt 差**烘进了判据**（与上次 `rightGap 13→37` 同一类：不是随手改数字，是原生缺边框的显式披露）。
本包把原生内边距直接取 **12**（= web 的 padding 11 + border 1），一处修正连带四条归位：
body 左缘 12、body 右缘仍撑满面板、状态右缘 38、卡宽 panelW−37；卡右缘距面板右仍是 **25**（13 留白 + 12 拇指条）。

### 判据改动（`tests/test_native_analysis_panel.mm`，5 条 + tolerance 收严）
| 判据 | 旧期望 | 新期望 | 依据 |
|---|---|---|---|
| `anslab.left` | 11 (tol 1.5) | **12 (tol 0.5)** | web 12；tol 1.5 会把 1pt 差放过（等于没判） |
| `stat.rightGap` | 37 (tol 1.0) | **38 (tol 0.5)** | 26 + 11 + 1 |
| `anlcard.left` | 11 (tol 1.5) | **12 (tol 0.5)** | 同上（三张卡各一条） |
| `anlcard.width` | `panelW-36` (tol 1.5) | **`panelW-37` (tol 0.5)** | web 实测 264@301 |
| `npAnlBody` 宽 | `panelW-11` (tol 1.5) | **`panelW-12` (tol 0.5)** | 左 12、右缘撑满面板（web 因边框是 panelW-13） |

### 红 → 绿（旧码跑红，同判据同 tolerance）
| 轮次 | 结果 | 具体失败项 |
|---|---|---|
| 旧码（1.1.7.56，仅改判据） | **131 passed / 9 failed** | `anslab.left` 11 vs 12；`stat.rightGap` 37 vs 38；`anlcard.left` ×3 11 vs 12；`anlcard.width` ×3 297 vs 296；`npAnlBody` 宽 322 vs 321 |
| 新码（1.1.7.57，`anlPadX=12`） | **140 passed / 0 failed** | — |

日志：`evidence/native-anlpad-red-20261114.log`（EXIT=1，9 FAIL 明细）、`evidence/native-anlpad-green-20261114.log`（EXIT=0）。

### 实现
- `tools/native_ui/RLPNowPlayingViewController.mm`：`anlPadX 11.0 → 12.0`（注释写明 11+1 的由来与「旧期望把 1pt 差烘进去」）。
  其余取值全部**派生**（`statRight = side-(anlPadX+26)`、`cardsW = side-anlPadX`、`anlSeg` 右缘、`anlReanalyze` x），
  没有第二处硬编码，所以一处改动即可自洽。

### 如实挂账
1. `.anlhide` 仍 `side-8-22`（web 应为 `side-9-22`）：本包未动，见上方「仍留 1pt」。
2. 本包只跑判据 + 全量门禁（离屏），**未做实机肉眼验收**；实机由用户执行。
