# v3.3.11 M3U 导入 UI 接缝（1.1.7.66）

> 待移植清单「M3U 播放列表导入」组**第二部分：队列页按钮 + 导入通道**。
> 第一部分（POSIX 解析纯函数）见 `evidence/native-m3u-parser-20261115.md`（1.1.7.65）。

## 1. 上游真值（`/tmp/rlp2-v3311/ui_script.h:12717-12846`）

- `qImportM3u` 按钮 → `qM3uFile.value=''; qM3uFile.click()` → `onchange` 调 `importTransportM3u(file)`。
- `importTransportM3u`：扩展名 `.m3u/.m3u8` 校验 → `file.size > 16*1024*1024` 拒绝（`歌单过大`）
  → 解析（失败 `歌单包含不支持的路径或格式`）→ `needsFolder && !folder` 时 `askText` 追问 →
  `body = 'require_stopped=1&files=' + encodeURIComponent(items.join('\n'))`
  → 超 16 MiB 拒绝 → `askConfirm('将按歌单顺序替换当前队列，共 N 首。…')` →
  `S.playing` 时 `请先停止播放，再替换队列。` → POST `/api/queue/set` → `loadQ()`。

## 2. macOS 落地（与 web 的对应与差异）

| web | 本仓 |
|---|---|
| 隐藏 `<input type=file accept=".m3u,.m3u8">` | `NSOpenPanel`（`allowedFileTypes=@[@"m3u",@"m3u8"]`，`message=选择 M3U 歌单`） |
| `importTransportM3u(file)` | 生产接缝 `-importM3UAtPath:playing:`（判据可直接调用，绕过系统面板） |
| `require_stopped=1` 由后端校验 | 同：body 真带 `require_stopped=1`，且前端先拦 `playing` |
| `askConfirm` 确认替换 | **未做**（见挂账；macOS 上先由用户在文件面板里选中，语义已足够明确） |
| `needsFolder` 追问文件夹 | **未做**：macOS 上 M3U 相对路径以**文件所在目录**为 folder 传入，无需追问；`needsFolder` 仍由解析器返回，留待将来 |
| 播放态来源 | 复用 `/api/status`（与页面同一份轮询口径），`isPlayingNow = playing && !paused` |

## 3. 实现

| 文件 | 改动 |
|---|---|
| `tools/native_ui/RLPQueueViewController.mm` | ① 工具栏加 `导入 M3U 到队列` 按钮（identifier `qImportM3u`）；② `onAction:` 分派；③ `promptImportM3U`（`NSOpenPanel`）；④ 生产接缝 `importM3UAtPath:playing:`（扩展名 → 16 MiB → `RLPParseM3U`（folder=文件目录）→ `n ≤ 16 MiB` → `require_stopped=1&files=` POST `/api/queue/set` → `reloadData`）；⑤ `isPlayingNow` 由 `reloadData` 里的 `/api/status` 更新 |
| `docs/i18n/chunk-native119-m3u.en.tsv`（新） | 6 条词条（按钮 / 面板提示 / 播放中拒绝 / 过大 / 失败 / 格式不支持），全部逐字取 web 同文案 |
| 生成物 | `src/net/i18n_table.h`（2444 行 / 2427 对）、`tools/native_ui/RLPNativeI18n.mm`（2427 对）重生成 |
| `src/version.h` | `1.1.7.65 → 1.1.7.66` |

## 4. 红 → 绿（`test_native_queue_sort.mm` 新增 Q0–Q8）

| 判据 | 旧码 | 新码 |
|---|---|---|
| Q0 夹具 `.m3u` 写入 | PASS | PASS |
| Q1 `qImportM3u` 按钮存在 | FAIL | PASS |
| Q2 按钮有 target/action | FAIL | PASS |
| Q2b 生产接缝 `importM3UAtPath:playing:` 存在 | FAIL | PASS |
| Q3 真发 `/api/queue/set` | FAIL | PASS |
| Q4 body 含两首路径 | FAIL | PASS |
| Q5 body 带 `require_stopped=1` | FAIL | PASS |
| Q6 POST 真的追加 | FAIL | PASS |
| Q7 播放中导入被拒绝（不发请求） | PASS（无接缝时恒真） | PASS |
| Q8 >16 MiB 被拒绝 | FAIL | PASS |

| 轮次 | 结果 | 证据 |
|---|---|---|
| 旧码（仅判据） | build 0 error；**7 FAIL**（Q1–Q6、Q8；Q7 因无接缝恒真） | `native-m3u-import-red-20261115.log` |
| 新码（1.1.7.66） | build 0 error；`native_queue_sort` **全绿** | `native-m3u-import-green-20261115.log` |

## 5. 判据自身修掉的两处假红（必须如实记录）

1. **`q.del` 时红时绿**：原判据直接扫视图树找行尾 ×，而 AppKit 行视图是**懒创建**的，
   离屏时 `viewAtColumn:` 不一定被调用 ⟹ 同一次构建两次运行结果不同（实测一次 FAIL 一次 PASS）。
   修法：先 `reloadData` + `viewAtColumn:3 row:0 makeIfNecessary:YES` 强制物化再扫描。
   这是**判据不确定**，不是产品缺陷。
2. **Q8 假红**：原夹具 400000 行 ≈ 7.6 MB，**根本没到 16 MiB 闸门**，判据必然红。
   修法：加长目录名并增到 220000 行 ≈ 17.6 MB（脚本核算 16,000,019 B→现 >16 MiB），
   闸门真被触发。
3. 首版判据把汇总 `printf` 放在所有断言之前，导致中途崩溃时结果行缺失/错位；已移到末尾。

## 6. 如实挂账

1. **未做** `askConfirm` 的「替换队列」确认对话框（web 有；本包直接替换）。
2. **未做** `needsFolder` 的追问文件夹对话框（macOS 语义上不需要，`needsFolder` 标记保留）。
3. 导入走 `/api/queue/set` 后只 `reloadData`，**未**在导入成功后跳转队列页（当前就在队列页）。
4. `qImportM3u` 未做 hover 态（web `.chip` 风格按钮无 hover 语义，`.btn` 默认无 hover）。
5. 页面级判据（真实点按钮 → 系统面板）**未跑**（离屏环境会弹真面板）；接缝覆盖了同一段生产逻辑。
6. i18n 6 条全部英文已译；`i18n_table_check` / `native_i18n_table_check` / `native_i18n_coverage` 三门禁绿。
