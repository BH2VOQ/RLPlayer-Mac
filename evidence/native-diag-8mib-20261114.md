# P0-2 诊断包 ≤ 8 MiB：预算 / 真实 ZIP / UI 大小提示

- 日期：2026-11-14（P0-1 之后第二包）
- 仓库：`/Users/august/Downloads/DQ/RLPlayer`，branch `main`
- 基线：1.1.7.33（P0-1 提交 `5a7b950`）→ 本包 1.1.7.34
- 写者：single writer
- 范围：`src/diag/bundle.h`（默认预算/注释）、`tools/native_ui/RLPSettingsViewController.mm`
  （导出 ZIP 的字节校验与提示）、`tests/test_diag_bundle.cpp`（新增真实 ZIP 判据）
- 纪律：不启动核心、不联网、不碰用户曲库；测试在 mkdtemp 隔离目录里跑并删除。

## 1. 根因（为什么用户会在实机上看到"诊断包过大：上限 8 MiB"）

| 层 | 冻结前 | 后果 |
|---|---|---|
| 预算 | `src/diag/bundle.h` 的 `kDefaultBudgetBytes = 12 MiB`（ROADMAP D6 的旧目标） | `/api/diagzip` 与 `/api/diagjson` 默认按 12 MiB 裁剪 |
| 封装 | 诊断包 ZIP 用 **STORE（不压缩）**（`src/net/zipstore.h`，注释里明确"不压缩"） | 12 MiB 的条目 ⟹ **真实 ZIP ≈12 MiB**，越过反馈通道的 8 MiB 硬闸门 |
| 闸门 | `src/net/feedback_api.h`：`diag_json` 原串 > 8 MiB 直接拒绝，提示"诊断包过大：上限 8 MiB" | 用户实机日志大（本机 `uievents.jsonl` 7.6 MB + `rlplayer-playback.log` 2.5 MB）时必然触发 |
| 原生导出 UI | 端子取 `/api/diagzip` 后**只判 `data.length`**，不判 ZIP 头；超预算时服务端回的是 JSON 错误报文 → 会被存成 `.zip` | "导出成功"实际上是个坏包；且提示从不显示真实大小 |
| Web 导出 UI | `exportDiagZip` 已校验 PK 头并在 `diagMsg` 显示 `blob.size/1024 KB` | 这一路原本就是真大小，无需改 |

**红线不变**：打包只挑**已知文件名**（`diag.json`/`events.jsonl`/`uievents.jsonl`/
`rlplayer-playback.log*`/`launcher.log`），不整目录打包 —— 二进制/dylib、构建产物、
封面/波形缓存、截图本来就不会进包（`diag_bundle_items()` 的白名单，未改）。

## 2. 改了什么

| 文件 | 改动 |
|---|---|
| `src/diag/bundle.h` | `kDefaultBudgetBytes` **12 MiB → 7.5 MiB（7,864,320 B）**；注释写明"STORE ZIP 要给 manifest/checksums/报告/目录留余量，否则越过反馈通道 8 MiB" |
| `tools/native_ui/RLPSettingsViewController.mm` | 导出 ZIP 前校验 **PK\x03\x04** 头 + `≤8 MiB`（否则提示"诊断包导出失败"，不再把 JSON 错误存成 .zip）；成功提示追加**真实大小**（`nbytes / 1 MiB` 两位小数） |
| `tests/test_diag_bundle.cpp` | 新增判据段：~20 MiB 大日志夹具（events/uievents 各 3 MiB + 4 份历史日志各 3 MiB，含首/尾哨兵）→ 用**生产默认 spec** 组装 → `zip_of` 出**真实 ZIP**；断言 ≤8 MiB、必需条目齐全、日志按**尾部**裁剪、装不下的条目被丢弃并记账 |

大日志裁剪本来就是 `bundle.h` 的既有能力（`keep_tail` + `line_head_align`，按 priority 先保
diag/events/uievents，再保最新日志、丢旧头部）；本包改的是**默认预算**，让真实产物落回 8 MiB 内。

## 3. 红 → 绿（同一份测试，只换生产代码）

| 阶段 | 生产码 | 结果 | 日志（本机 evidence/，按 .gitignore 不入库） |
|---|---|---|---|
| RED | `kDefaultBudgetBytes=12 MiB`（`git stash` 回旧 bundle.h） | **103 passed / 3 failed**，exit 1 | `evidence/native-diag-8mib-red-20261114.log` |
| GREEN | 本包（7.5 MiB + UI 校验） | **106 passed / 0 failed**，exit 0 | `evidence/native-diag-8mib-green-20261114.log` |

红的 3 条（旧码真的做不到，不是判据错）：

1. `真实 ZIP ≤ 8 MiB` ← 旧预算下 ZIP 越过上限；
2. `launcher.log 被裁剪` ← 旧预算够大，3 MiB 日志原样全带；
3. `裁剪丢弃头部` ← 同上，头部哨兵还在包里。

绿的实测数字（夹具 = 与用户实机同形的大日志）：

```
entries = 7,604,990 bytes, budget = 7,864,320, ZIP = 7,605,710 bytes
```

ZIP 7,605,710 ≤ **8,388,608**（8 MiB），且必需条目 `diag.json` / `events.jsonl` /
`uievents.jsonl` / `report.txt` 全部在包内。

## 4. UI 提示与真实大小一致

- Web 导出：`exportDiagZip` 原来就把 `blob.size` 写进 `diagMsg`（"已导出 xxx.zip（N KB）"）
  —— 这是**下载后真实字节数**，本包未改。
- 原生导出：成功提示改为 `已导出 <文件名>  <nbytes / 1 MiB> MB`，数字来自刚落盘的 `NSData.length`；
  超预算/非 ZIP 一律报"诊断包导出失败"，不再出现"提示成功、文件是 JSON"的假绿。
- 反馈附带的诊断 JSON：`tools/mac_host.mm` 一直用 **6 MiB 预算**（给 base64 4/3 膨胀与
  JSON 包装留余量），落在 8 MiB 闸门内；本包没有改这条（避免把两个边界混成一个）。

## 5. 门禁（串行，机器空闲；本包树 = 1.1.7.34）

| 门禁 | 命令 | 结果 |
|---|---|---|
| 构建 | `cmake --build build-mac -j8` | **exit 0** |
| 全量单测 | `ctest --test-dir build-mac -j1 --output-on-failure` | **196/196 passed, 0 failed**（exit 0；见下"一次假红"说明） |
| 功能审计 | 隔离目录 → `rlplayer_native --audit` | **246 passed, 0 failed**，exit 0 |
| 移植扫描 | `python3 tools/native_ui/parity_scan.py --check` | exit 0（missing=0） |
| 行为扫描 | `python3 tools/native_ui/behavior_scan.py --check` | exit 0（actionable=0） |
| i18n | `python3 tools/gen_i18n_table.py --check` | `OK: i18n table up to date (2318 pairs)`，exit 0 |

**一次假红（如实记录）**：第一次全量 ctest 时 `diag_bundle_json` 在第 43 位报
「调用前后 r.manifest_json 未被改动」失败（195/196）；单独跑该用例 62/0 通过，
第二次全量 ctest 196/196 全绿。两次全量之间生产代码/测试代码均未改动，
属该用例的**偶发/环境相关**，不是本包引入的确定性回归。

## 6. 如实挂账

1. 判据是"生产同款组装 + `zip_of` 的真实 ZIP 字节数"，不是对**用户真实状态目录**跑一次导出；
   用户目录里的日志规模更大时仍受同一预算约束（尾部裁剪），不会越界。
2. 未在真实反馈后台上传验证（需要网络与令牌；按项目纪律不碰生产后台上传）。
3. 8 MiB 是**解码后**的通道上限；ZIP 与反馈 JSON 是两种封装，本包只保证 ZIP ≤ 8 MiB 且
   反馈 JSON 路径沿用既有 6 MiB 预算。
