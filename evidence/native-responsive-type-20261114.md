# 播放页响应式字号（1.1.7.43，按对照表 #13/#41）

## 差异（web `src/net/ui_page.h`）
- `#npTitle{font-size:clamp(19px,2.6vh,27px);font-weight:700;line-height:1.3}`
- `.npline{font-size:clamp(13px,1.9vh,17px);line-height:2.05}`；`.npline.on{font-weight:650;transform:scale(1.03)}`
- `.npsub{margin-top:8}`、`#npNextTrackHero{margin-top:4}`、`.npmline{margin-top:10}`（标题行高变化后，下方各行要跟着下移）
- 原生 1.1.7.42 及以前：`titleLabel2` **固定 20pt / 30pt 行**；歌词 **固定 14pt + 行盒 30pt**（行距比 30/14≈2.14，
  既不是 2.05 也不随窗口变）⟹ 小窗标题偏大、大窗标题/歌词偏小，行距僵。

## 判据（`tests/test_native_nowplaying_web.mm` 追加 18 条）
按**真实窗口高度**三档 640 / 800 / 1080 改 `vc.view` 尺寸并 `layoutSubtreeIfNeeded`，逐档断言：
1. `npTitle` 字号 = `clamp(19,2.6vh,27)`（±0.5pt）；
2. 歌词两行都建成；
3. 歌词字号 = `clamp(13,1.9vh,17)`（±0.5pt）；
4. 歌词行盒 = 字号×2.05（±0.6pt）；
5. 相邻行贴合行盒（gap≈0）。
三档期望值：标题 19 / 20.8 / 27；歌词 13 / 15.2 / 17；行盒对应 26.65 / 31.16 / 34.85。

## 红 → 绿
| 轮次 | 结果 |
|---|---|
| 旧码（1.1.7.42） | **9 FAIL**（标题 3 档：20/20/20 vs 19/20.8/27；歌词 3 档 14 vs 13/15.2/17；行盒 3 档 30 vs 26.65/31.16/34.85）；gap 3 档通过 |
| 新码 | **60 passed / 0 failures**（42 条既有 + 18 条新） |

证据：`evidence/native-responsive-type-red-20261114.log` / `-green-…log`。

## 实现
- 新增三个纯函数（`RLPNowPlayingViewController.mm` 顶部静态区）：
  `RLPNPTitlePointSize(vh)=clamp(0.026·vh,19,27)`、`RLPNPLyricPointSize(vh)=clamp(0.019·vh,13,17)`、
  `RLPNPLyricLineStep(ps)=ps·2.05`；`vh = webCanvas.bounds.height`（= `#npPage` 覆盖层视口高）。
- `layoutWebPlayback`：标题字号/行盒每帧按视口高度换算（`titleH=ceil(size·1.3)`），
  并把 `.npsub`（margin-top 8）/`#npNextTrackHero`（4）/`.npmline`（10）的 Y 坐标改为**从标题行底**推导，
  不再写死 `infoY+63/84`；收藏键垂直居中于标题行。
- 歌词：`applyLyricText` 建行时按当前视口字号；`layoutLyricRows` 每帧检测字号变化 →
  `restyleLyricRows` 重设字体/高亮（不重建控件、不动滚动状态），行盒 = 2.05×字号；
  `updateLyricPosition` 的高亮字体也走同一字号（不再写死 14）。
- 不改业务状态：字号只影响排版；切歌/滚动/拖动逻辑未动。

## 如实挂账
1. `.npline.on{transform:scale(1.03)}` 的 active 缩放未做（AppKit 文本控件缩放需要逐行变换/图层，
   本轮只做字号与行盒；列入候补）。
2. 极小/极大窗口未实机验证（判据只覆盖 640/800/1080 三档）。3. 标题过长时的省略号行为沿用 NSTextField 截断，
   与 web `white-space:nowrap;text-overflow:ellipsis` 近似而非逐像素。
