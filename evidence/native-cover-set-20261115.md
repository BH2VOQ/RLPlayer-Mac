# v3.3.11 单曲封面手动设置 / 恢复自动（1.1.7.67）

> 待移植清单「封面手动设置 / 重置」组。上游是 web 前端按钮 + 后端 `/api/cover/set|reset`；
> 本仓**后端此前没有这两个路由**（`grep api/cover/set tools/rtaweb.cpp` = 0），
> 所以本包先补后端，再补前端按钮（下一包）。

## 1. 上游真值（tag v3.3.11）

| 层 | 内容 |
|---|---|
| 前端 `ui_script.h:14354-14372` | `npSetCover` → 置 `S.coverEditFile` → 点 `npCoverFile`（`<input type=file accept=image/*>`）→ `saveTrackCover(file, image)`；`npResetCover` 仅在 `curMeta.coverSource === 'track_manual'` 时显示 → `resetTrackCover(file)`；成功 toast「歌曲封面已设置」/「已恢复自动封面」，失败 `设置失败：{0}` |
| 前端 `:4153-4180` | `saveTrackCover` = `POST /api/cover/set?file=` + 二进制 body；`resetTrackCover` = `POST /api/cover/reset?file=`；成功后 `loadMeta(file)` 重拉 |
| 后端 `rtaweb.cpp:14370-14415`（v3.3.11） | 两条都校验「曲库中真实存在且是音频」；reset 写 `.source.json`（`source:"reset"`）；set 要求 `1KB ≤ body ≤ 24MB` 且 `cover_image_present`，写缓存 `source:"manual"`；返回 `{ok, hasCover, coverSource, coverUrl}` |
| 后端读侧 `resolve_cover` | 先读 `track:<hash>` 手动封面（`source=track_manual`）；若存在 `.source.json` 且 `source != "reset"` 则视为「已声明但无图」直接返回空 |

## 2. 本仓落地（1.1.7.67，后端）

| 项 | 做法 |
|---|---|
| POST 白名单 | `is_side_effect_path` 加 `/api/cover/set`、`/api/cover/reset` |
| GET 例外 | `is_side_effect_exempt` 里把这两个子路径显式 `return false`（前缀 `/api/cover` 本身是只读读图，否则 `<img src=.../api/cover/set>` 就能改用户封面） |
| 路由 | 在 `/api/cover` 读取分支**之前**插入（该分支用 `rfind("/api/cover",0)` 会吞掉子路径）；两条都校验 `valid_utf8` + `is_regular_file` + `lib_is_audio` + 曲库身份 |
| set | `body.size()` 在 [1024, 24MiB] 且 `cover_looks_like_image` 且 `cover_write_atomic(key, body, /*manual*/true)` 成功 → `{"ok":true}`；否则 `{"ok":false,"error":"封面及来源提交失败；原记录保留"}` |
| reset | 在 `cover_manual_dir()` 下写 `<key>.jpg.source.json`（`{"version":1,"key":…,"source":"reset"}`） |
| 读侧 | `/api/cover?file=` 先查 `manual/<track:hash>.jpg`；若存在 `source.json`（reset 标记）则跳过手动封面回落自动链。命中时 `Cache-Control: max-age=3600` |
| 键 | 与上游一致：`"track:" + MetaStore::hashOf(lib_path_key(file))`（大小写不敏感、`/`→`\` 归一后再哈希） |

## 3. 红 → 绿（`tests/test_embedded_api.cpp` 新增 K0–K6）

| 判据 | 旧码 | 新码 |
|---|---|---|
| K0 夹具音频文件真实存在 | PASS | PASS |
| K1 `/api/cover/set` 接受 ≥1KB 可识别 PNG | FAIL（路由不存在） | PASS |
| K2 `/api/cover` 读回的正是刚写入的 PNG（魔数 + ≥1100 字节） | FAIL（len=67 占位图） | PASS |
| K3 `/api/cover/reset` 写 reset 标记 | FAIL | PASS |
| K4 不存在的文件被拒绝 | PASS（恒真，无路由也返回非 ok） | PASS |
| K5 <1KB 载荷被拒绝 | PASS（同上恒真） | PASS |
| K6 GET `/api/cover/set` 不执行副作用 | PASS（同上恒真） | PASS |

| 轮次 | 结果 | 证据 |
|---|---|---|
| 写侧已在、读侧未接（人为回退读侧） | **1 失败**（K2 `len=67 magic=1`） | `evidence/native-cover-set-red-20261115.log` |
| 完整实现（1.1.7.67） | **0 失败**（7 条全绿） | `evidence/native-cover-set-green-20261115.log` |

**关键发现（真实缺陷，不是判据写错）**：只加 `/api/cover/set` 写路由时 K2 仍红 ——
`/api/cover` 的读取链**根本不查逐曲手动封面**，所以「设置成功」是个空操作。补读侧后才真正生效。
这正是「接口存在 ≠ 功能生效」的又一个实例。

## 4. 前端按钮（同包补齐，1.1.7.67）

| 项 | 做法 |
|---|---|
| `npSetCover` | `NSButton` identifier `npSetCover`，放封面图正下方一行（右对齐封面右缘）；`NSOpenPanel` 限 `jpg/jpeg/png/webp/gif` |
| `npResetCover` | `NSButton` identifier `npResetCover`，紧跟其后；始终可见（见挂账 2） |
| 生产接缝 | `-setCoverAtPath:forTrack:` / `-resetCoverForTrack:` —— 判据直接调用，绕过系统面板 |
| 下发 | set 走 `postData`（二进制 body，不是表单）；reset 走 `postJSON`；成功后 toast + `loadCoverForPath:` 重拉封面 |
| 启用条件 | 无当前曲目时两个按钮 `enabled=NO`（web 也是 `!S.lastCur` 时 disabled） |
| i18n | 新增 `chunk-native120-cover.en.tsv` 8 条；复用既有 `图片读取失败`/`设置失败` 译法，**不新造一稿两译** |

**判据 C1–C10**（`test_native_nowplaying_web.mm`）：控件存在 / target+action / 夹具 PNG 落盘 /
set 真发 `/api/cover/set?file=` / 下发 ≥1200B 图片字节（不是表单）/ 带目标曲目路径 /
reset 真发 `/api/cover/reset?file=` / 带目标曲目路径。

**UI 接线的红证据来自门禁本身**：补按钮前 `native_ui_parity` **FAIL**（`api missing=2`：
`/api/cover/set`、`/api/cover/reset` 只有后端没人调用）；补按钮后 `api done=97 missing=0`。
这条比手写断言更硬 —— 它证明的是「原生真的用上了这两个端点」。

## 5. 如实挂账

1. **`coverSource` 未回给 `/api/meta`**：web 用 `curMeta.coverSource === 'track_manual'` 决定
   「自动」按钮是否显示；本仓 `/api/meta` 无该字段（`grep coverSource` = 0），下一包需补。
3. 「自动」按钮**始终可见**（上游仅在 `curMeta.coverSource === 'track_manual'` 时显示）。
   本仓 `/api/meta` 无 `coverSource`，故不做隐藏；无手动封面时点它只写 reset 标记，读侧本就
   走自动链 ⟹ 语义无害但**与上游 UI 有可见差异**，如实记录。
4. **reset 语义是「标记」不是「删图」**：与上游一致（写 `source:"reset"` 而不删 jpg），
   所以重置后磁盘上仍留有旧手动封面文件；读侧靠标记跳过。
5. **未跑真网络 / 真图片**：夹具是 1200 字节的构造 PNG（含合法魔数），不验证真实解码。
6. 未改动 `cover_track_album_fallback`（专辑兜底）与 `/api/lib/cover/set`（专辑级手动封面）。
