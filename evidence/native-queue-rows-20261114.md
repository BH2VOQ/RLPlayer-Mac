# 播放队列页行布局 = web `.qrow`（1.1.7.28 → 1.1.7.29）

日期：2026-11-14 · 仓库 `/Users/august/Downloads/DQ/RLPlayer` · 基线 `7fe9a65`（1.1.7.28，工作树仅 `?? website/`）
分支 main（仅本地提交，未推送）· 提交：`feat(native): queue rows match web qrow, 1.1.7.29`

## 0. 结论

| 项 | 结果 |
|---|---|
| 新判据 `native_queue_rows` | 旧码 **4 passed / 13 failed** → 新码 **29 passed / 0 failed** |
| build | exit 0 |
| ctest / audit | 最终门禁统一复跑回填 |

## 1. web ↔ native 对照

| 维度 | web（`ui_page.h:506-513` + `ui_script.h:12556-12585`） | 原生旧码（1.1.7.28） | 原生新码 |
|---|---|---|---|
| 列 | 4 个子元素：序号 / 标题 / 父文件夹名 / × | 6 列：# / 标题 / 艺术家 / 专辑 / 时长 / × | 4 列：`q.n` 26 / `q.t` flex / `q.f` ≤38% / `q.del` 24 |
| 行高 | padding 9 18 + 12.5 正文 ≈38 | 26 | 38 |
| 列头 | 无（页面自带排序栏） | 有 #/标题/艺术家/专辑/时长 表头 | `headerView = nil` |
| 标题 | 12.5 nowrap ellipsis，tooltip 全路径 | 12.5（无全路径 tooltip 约定） | 12.5 + tooltip 全路径 |
| 文件夹 | 父目录 basename，11px `--mut2`，max 38%，tooltip 全路径 | 艺术家/专辑两列（不是文件夹） | `q.f` = 父目录 basename + 全路径 tooltip |
| 当前行 | `.qrow.on` bg `--acc-weak`，`.qt` `--acc-text` 650 | 标题 accent（无行背景） | 行视图填 `accentWeak` + 标题 accent + semibold |
| × | 24×24 radius 6，opacity 0；`.qrow:hover` → 1 | 28 列常显 | 24×24 radius 6，`alphaValue` 0，行悬停 → 1（只刷该行该列） |
| 底部分隔 | `border-bottom:1px solid var(--line)` | 无 | 行视图底部 1px `--line` |
| 悬停 | `:hover {background:var(--hov)}` | `RLPHoverRowView`（保留） | 保留 + 行悬停驱动的 × 可见性 |
| 排序/按钮 | 排序 8 档 + 保存为歌单/清空队列（上一包已做） | 已对齐 | 不变 |

## 2. 红 → 绿（同一份判据）

```
git checkout -- tools/native_ui/RLPQueueViewController.mm
cmake --build build-mac -j8 --target test_native_queue_rows
./build-mac/test_native_queue_rows          # 4 passed / 13 failed, exit 1
git apply /tmp/qrows-prod.patch
./build-mac/test_native_queue_rows          # 29 passed / 0 failed, exit 0
```

日志：`evidence/native-queue-rows-red-20261114.log` / `-green-20261114.log`。

**红阶段判据提前收窄**：旧码没有 `q.t/q.f/q.del` 列与 `RLPQueueRowView`，部分断言按条件跳过
（4 passed 而不是 0），失败项已覆盖全部本包目标（列数/行高/文件夹/悬停 ×/当前行/行视图）。

## 3. 判据覆盖（桩客户端、离屏、不出声）

- 恰好 4 列（q.n/q.t/q.f/q.del），无艺术家/专辑/时长旧列；行高 38；无列头。
- 序号文本、标题文本、父文件夹名（A / Sub）与全路径 tooltip。
- 当前行标题 = accentText、非当前行 = text；行视图 = `RLPQueueRowView`。
- × 默认 alpha 0；`setHoveredForAudit:YES` 后 alpha 1；离开恢复 0；点 × 发 `/api/qdel` 且不触发 `/api/play`。
- 拖拽 pasteboard `RLPQueueRowDrag` 仍注册。

## 4. 如实挂账

1. 本包由 Lead 直接实现（前一个派发子代理在开始写文件前失败，工作树零残留）。
2. 行视图底部分隔线是绘制实现，判据只断言行视图类与目标字段，不做像素级分隔线采样。
3. 行高/字号为 web 值推导（8+8 padding + 行高），未逐个截图比对；实机观感由用户验收。
