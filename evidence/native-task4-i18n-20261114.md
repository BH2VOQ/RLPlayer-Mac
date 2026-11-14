# 1.1.7.37 — 原生 UI 文案进 i18n 词表（task-4 / 设置页已知差异④）

## 背景（已知差异原文）
> 「新增短文案走 `RLPTr` 回退、未进 i18n 表」

原生版从 1.1.7.24 起一路加控件（右栏、分析栏、设置页各卡、OPRA 卡片墙…），新增文案
只用 `RLPTr()` 包了一层，但**没有**进 `docs/i18n/chunk-*.en.tsv`。后果：英文界面下这些
文案整串匹配失败、回落到中文 ⟹ 中英混排。此前没人发现，因为门禁里只有
`gen_i18n_table.py --check`（它只校验**表本身**自洽，看不见源码里新加的字符串）。

## 判据（先红后绿）

新判据 `tools/check_native_i18n_coverage.py`（已接进 ctest：`native_i18n_coverage`）：
扫 `tools/native_ui/*.mm` 里每一个 `RLPTr(@"…")` 中文字面量，逐字比对
`docs/i18n/chunk-*.en.tsv` 的中文键；缺任何一条即 FAIL + 打印缺哪条/在哪个文件。

| 时点 | 结果 | 证据 |
|---|---|---|
| 旧码（1.1.7.36 同树） | **101 条**中文文案无英文译文（另有 5 条含 `\n` 的文字根本不可能是单行键） | `evidence/native-i18n-coverage-red-20261114.log` |
| 旧码：原生词表本身也已漂移 | `gen_native_i18n.py --check` **FAIL**（`资料不足` / `资料不足：缺少艺术家与曲名` 两条） | 同上 |
| 新码 | **0 条**（1599 处中文字面量全部有译文；词表 2315→2412 键） | 本文件 §验证 |

## 做了什么

1. 新增 `docs/i18n/chunk-native117.en.tsv`（97 条中→英，含格式化占位符 `%ld/%lu/%@/%.1fs`
   逐字保留，避免格式化崩）。**不新增"已有中文的第二种译法"**，生成器的「一稿两译」校验仍绿。
2. 5 处**含 `\n` 的多行文案**拆成两段，各走自己的 `RLPTr`（web 版本来就是两个元素：
   主行 + 小字副行）：
   - `还没收藏` / `在曲目行或单曲页点心形…`（收藏空态）
   - `队列为空` / `右键专辑或曲目可加入`（右栏队列空态）
   - `队列是空的` / `把文件拖进窗口，或右键专辑/曲目「加入队列」`（队列页空态）
   - `歌词加载中…` / `正在等后台补全（首次播放新曲目时可能要几秒）`
   - `没有歌词` / `同名 .lrc 文件、内嵌歌词，或播放时自动在线补全`
   为什么必须拆：TSV 是行式格式，键里不可能含真换行；而词表引擎是整串匹配，
   含换行的串在英文界面永远回落中文。拆开后每段都是既有的 web 键或本轮新增键。
3. 重新生成两张表：`src/net/i18n_table.h`（web，2412 对）与
   `tools/native_ui/RLPNativeI18n.mm`（原生，2412 对）——顺带修掉 2 条既存漂移。
4. 两个新门禁进 ctest：`native_i18n_coverage`（本条判据）、`native_i18n_table_check`
   （原生表与 TSV 同步）。后者此前**不在门禁里**，这正是漂移能悄悄存在的原因。

## 验证

```
python3 tools/check_native_i18n_coverage.py     → 0 条缺失（1599 处字面量）
python3 tools/gen_native_i18n.py --check        → OK (2412 pairs)
python3 tools/gen_i18n_table.py --check         → OK (2412 pairs)
cmake --build build-mac -j8                     → exit 0
ctest --test-dir build-mac -j1                  → 199/199 passed（403.90s → 409.14s）
```
全量 ctest 日志：`/tmp/p1-ctest.log`（197 基线 + 本包 2 条新门禁 = 199）。

## 如实挂账

- 判据只覆盖**字面量** `RLPTr(@"…")`。动态拼接（`stringWithFormat` 拼出来的键、
  `RLPTr(变量)`）静态不可判定，不在范围内。
- 97 条英译是**本轮新译**，未经母语者校对；术语按 `docs/i18n-glossary.md` 口径
  （Bands/Preamp/Cast/Target curve 等沿用表里既有译法）。
- 未实机验证英文界面：实机由用户执行（清单在轮次报告里）。
