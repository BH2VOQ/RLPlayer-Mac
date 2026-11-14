# `.npchipwrap` 卡宽对齐 web 实测（1.1.7.58）

## 1. 实测方法（ego 浏览器，唯一 UI 验收通道）

`./build-mac/rtaweb --no-browser --port 19091`（**只碰 19091，未碰 8899**；未改
`build-mac/rlplayer-settings.conf`，不发声），`ego_navigate` 打开
`http://127.0.0.1:19091/index.html`，`openNowPlaying()` 后用 `ego_js` 在页面里注入
8 张 `.npchip` 造内容溢出，直接量 DOM。CSS 写的是
`.npchipwrap::-webkit-scrollbar{width:6px}`，但 `offsetWidth-clientWidth` 实测 **11**。

| 量（panelW=301） | 溢出时 | 不溢出时 |
|---|---|---|
| `.nprailcard` 宽 | 301 | 301 |
| `.npchipwrap` offsetWidth | 279 | 279 |
| `.npchipwrap` clientWidth | **268** | **279** |
| 滚动条占位 = offset-client | **11** | **0** |
| 首张 `.npchip` 宽 | **268** | **279** |
| 卡右缘距面板右 | **22**（10 padding + 1 border + 11） | **11**（10 + 1） |
| 首卡宽 / wrap 宽 | `wrapW-11` | `wrapW` |

结论：**溢出时 cardW = wrapW - 11**。1.1.7.53 起原生用 `wrapW-19`
（13pt 留白 + 6pt 拇指条），比 web 多留 8pt，卡片窄 8pt —— 这正是用户点的偏差。

同轮 `ego_js` 量 `#npAnal .anlhide`：`right=9px / top=8px / 22x22`
（CSS `right:8px` 相对 padding box，`#npAnal` 另有 1px 边框 ⟹ 从面板外缘量 9）。

## 2. 改了什么

| 文件 | 改动 |
|---|---|
| `tools/native_ui/RLPNowPlayingViewController.mm` | `railLayoutChips` 卡宽 `W-19 → W-11`；`RLPRailWrapView.scrollThumbRect` 拇指 `x=W-6 → W-8`（6pt 拇指画在 11pt 占位内，与卡右缘留 3pt）；两处「13pt 留白」注释改为 web 实测值；`.anlhide` `side-8-22 → side-9-22` |
| `tests/test_native_nowplaying_web.mm` | 卡宽期望 `W-19 → W-11`；拇指间隙期望 `>=13 → ~3pt` |
| `tests/test_native_rail_cards.mm` | `rail.padX.right 29 → 21`；`rail.card.width railW-39 → railW-31` |
| `tests/test_native_analysis_panel.mm` | 新增 `anlhide.rightGap = 9`（tol 0.5） |
| `src/version.h` | `1.1.7.57 → 1.1.7.58` |

## 3. 红 → 绿（同一份判据，旧码 vs 新码）

| 轮次 | 结果 | 证据 |
|---|---|---|
| 旧码（1.1.7.57，仅改判据） | **3 个 ctest 全红**：`卡宽 got 239 want 247`、`拇指间隙 got 13`、`rail.padX.right/card.width`、`anlhide.rightGap got 8` | `evidence/native-chipwrap-red-20261114.log` |
| 新码（1.1.7.58） | build 0 error；6 项相关 ctest **全绿**（`native_nowplaying_web` / `native_rail_cards` / `native_analysis_panel` / `native_rail_states` / `native_rail_preview` / `native_bar_web`） | `evidence/native-chipwrap-green-20261114.log` |

## 4. 如实挂账（本包未做，勿当回归）

1. **非常驻滚动条**：web `.npchipwrap{overflow:auto}`，不溢出时占位 0、卡宽 = wrapW；
   原生沿用「常驻 11pt 占位」取舍（与 `#npAnlBody` 同），不溢出时仍窄 11pt。
2. **1pt border 差**：web 溢出时卡右缘距面板右 22（10 padding + 1 border + 11），
   原生面板无边框 ⟹ 21。与 `#npAnal` 的历史 border 差异同类，本包未额外吸收。
3. `evidence/native-known-deviations-20261114.md` #5/#6/#11（抽屉 blur/滑入、
   brightness 真混合、chipwrap 惯性）仍未做，见该文件。
