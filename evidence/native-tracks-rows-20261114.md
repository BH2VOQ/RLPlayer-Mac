# 曲目页（tracks）行几何/内容 = web `.trow-track`（1.1.7.25 → 1.1.7.26）

日期：2026-11-14 · 仓库 `/Users/august/Downloads/DQ/RLPlayer` · 基线 `36ce2fa`（1.1.7.25，工作树仅 `?? website/`）
分支 main（仅本地提交，未推送）· 提交：`feat(native): tracks rows match web, 1.1.7.26`

## 0. 结论

| 项 | 结果 |
|---|---|
| 新判据 `native_tracks_rows` | 旧码 **20 passed / 70 failed** → 新码 **109 passed / 0 failed** |
| build | exit 0 |
| ctest | 待最终门禁回填（基线 188 + 本包 1 = 189） |
| audit | 待复跑（基线 246/0） |
| parity / behavior / i18n | 待复跑 |

## 1. web ↔ native 对照

| 维度 | web（`ui_script.h:3388-3401` + `ui_page.h:364-372`） | 原生旧码（1.1.7.25） | 原生新码 |
|---|---|---|---|
| 列 | 7 格：序号 / 心形 / 标题 / `artist — album` 合并格 / 规格 / 时长 / `+` | 7 列但第 4 列是独立「专辑」列；没有规格列 | 7 格一一对应；删除独立专辑列；新增规格格 |
| 列宽 | `28 24 minmax(120,1.6fr) minmax(0,1fr) 92 58 26`，gap 8 | 44 / 26 / 240 / 160 / 180 / 70 / 30 | 28 / 24 / 1.6:1 / 1fr / 92 / 58 / 26，gap 8 |
| 断点 | >1400 显示规格；≤1400 规格 0、1.8:1；≤1120 1:0.9 | 无断点 | 按表格内容宽 >1400 / 1121-1400 / ≤1120 三档重排；+ 列永不消失 |
| 行高 | 12.5px + 上下 8px padding ≈34 | 28 | 34 |
| 标题 | 12.5 | theme.body 13 | 12.5 |
| 序号/时长 | 11.5 右对齐 tabular | mono 11.5（右） | 11.5 右对齐 |
| 艺术家格 | `artist — album`（U+2014 两侧空格，单格 + tooltip） | artist、album 两列 | 同 web 单格 + tooltip；空字段不产生悬空「—」 |
| 规格 | `fmtTag(sr,bits)`：`96k/24`、`44.1k/16`，9.5 accent 右对齐 | 无 | 同 web；空 sr 空串 |
| 列头 | 无 thead | 有「标题/艺术家/专辑/时长」表头 | `headerView = nil` |
| 行动作 | 心形 + `+` 均保留 | 心形 + `+`（keep） | 保留（identifier `track.fav` / `track.add`） |

## 2. 红 → 绿（同一份判据）

```bash
# 红：把生产文件还原到 HEAD（1.1.7.25），保留新测试与 CMake 注册
git checkout -- tools/native_ui/RLPTracksViewController.mm
cmake --build build-mac -j8 --target test_native_tracks_rows
./build-mac/test_native_tracks_rows   # 20 passed / 70 failed, exit 1
git apply /tmp/tracks-prod.patch
./build-mac/test_native_tracks_rows   # 109 passed / 0 failed, exit 0
```

日志：`evidence/native-tracks-rows-red-20261114.log` / `-green-20261114.log`。
（判据总数红 90 / 绿 109：新码存在规格列/响应式后，条件分支里多跑了 19 条断言；不是丢断言。）

**审查发现的判据错误（已修正）**：旧版判据用 `table.bounds.width` 算标题+艺术家剩余宽，
但 AppKit plain style 在表尾多留 1 个 8pt gap（table.frame 1508 ↔ 内容宽 1500）⟹ 恒差 8。
改为用「列和 + 可见列间隙 = 内容宽」算，与 web 网格宽度同口径；修正后 109/0。

## 3. 判据覆盖（`tests/test_native_tracks_rows.mm`，桩客户端、离屏、不出声）

- 7 列 identifier 一一对应、无独立专辑列；固定列宽与 gap；行高 34；无列头。
- 1500 / 1300 / 1100 三个内容宽：比例 1.6 / 1.8 / 1:0.9、规格列显隐、+ 列始终 ≥24、标题 ≥120。
- 文本：`Aimer — Album Y`（U+2014）、`96k/24`、`44.1k/16`、时长 `3:45`、序号；空字段优雅降级。
- 行动作：心形点击 `/api/fav?file=…&on=1`、`+` 点击 `/api/add`（与 web addPathCue 同契约）。
- 既有功能：搜索框、排序 7 档、加载更多收起、行视图 `RLPHoverRowView` + `--hov` 悬停色。

## 4. 如实挂账

1. 本包在子代理中途中断后由 Lead 接手：修正了判据的 8pt 口径错误并完成红→绿；
   未改生产行为以迁就判据。
2. 规格列只在表格内容宽 >1400 时出现（与 web 媒体查询一致）；默认 1180 窗口下不可见，属预期。
3. 全部为离屏单测；实机观感由用户验收。
