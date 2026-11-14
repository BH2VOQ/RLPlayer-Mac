# 歌词空态 / 加载态两行文案（1.1.7.47，按对照表 #44/#46）

## web 真相
- `#npLyric` 空态（`renderNpLyric()`）：
  `<div class=npline>没有歌词<br><span style="font-size:12px;color:var(--mut2)">同名 .lrc 文件、内嵌歌词，或播放时自动在线补全（可在设置-元数据补全关闭）</span></div>`
  ⟹ **两行**：主行字号 = `.npline` 的 clamp(13px,1.9vh,17px)，副行固定 12px + `--mut2`。
- `#lyricbox`（右侧抽屉）加载态：`歌词加载中…` + 副行 `正在等后台补全（首次播放新曲目时可能要几秒）`。
- web 整页对「无曲目 / 网络曲目」没有单独文案（都是同一段「没有歌词」两行；`网络曲目暂无歌词` 只在抽屉）。

## 原生 1.1.7.46 及以前
`lyricsEmpty` 是单行 `RLPLabel`（`maximumNumberOfLines=1`）：空态显示 `没有歌词 · 同名 LRC、内嵌歌词或在线补全`
（没有副行、没有 12px 层级），无曲目显示 `还没有播放曲目`，网络曲目显示 `网络曲目暂无歌词`（把抽屉文案搬进整页），
加载态是单行 `歌词加载中… 正在等后台补全`。

## 判据（`tests/test_native_nowplaying_web.mm` 追加 7 条）
1. 空态允许两行（`maximumNumberOfLines==0`）且居中；
2. `applyLyricText:@""` 后 attributed 文案**逐字**等于 web 两行文本；
3. 文本含换行（主行+副行）；
4. 主行字号 = 歌词 clamp（760pt 窗口下 14.44pt，±0.6）；
5. 副行字号 = 12pt（±0.3）；
6. 两行文案 API 存在（加载态走同一入口）；
7. 加载态文案逐字 = `歌词加载中…\n正在等后台补全（首次播放新曲目时可能要几秒）`；
8. 无曲目也走 web 整页空态（不再显示 `还没有播放曲目`）。

## 红 → 绿
| 轮次 | 结果 |
|---|---|
| 旧码（1.1.7.46） | **6 FAIL**（单行截断、文案不符、无副行、副行字号不适用、API 缺失、无曲目文案错位） |
| 新码 | **131 passed / 0 failures**（121 既有 + 7 新 + 前提） |

证据：`evidence/native-lyrictext-red-20261114.log` / `-green-…log`。

## 实现
- `lyricsEmpty` 改为多行居中（`maximumNumberOfLines=0`、`NSLineBreakByWordWrapping`）；
- 新 `setLyricsPlaceholder:detail:`：主行字号跟歌词 clamp、颜色 `--mut`，副行 12pt `--mut2`，段落居中；
- 空态、无曲目、网络曲目统一走 web 整页两行空态（抽屉文案保留在原处，不再搬到整页）；
- 加载态改 web 抽屉的两行文案（主行 `歌词加载中…` + 副行说明）；
- 失败态保留 `歌词加载失败`（web 整页无对应文案，原生已有的超集）。

## 如实挂账
1. 加载态在 web **整页**并不存在（web 整页靠 400ms 轮询，空歌词就直接显示「没有歌词」）；
   原生的加载态是超集，文案取自 web 抽屉（同词条），不是整页逐像素对齐。
2. `歌词加载失败` 在 web 整页也没有；保留原生既有提示，未另造 web 文案。
