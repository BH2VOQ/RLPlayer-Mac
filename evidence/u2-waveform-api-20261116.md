# U2 包2：/api/waveform 后端 + 黑盒测试（2026-11-16）

> 分支 `feat/u2-backend`（worktree `.agents/wt-pages`）。本包只做**后端端点 + 黑盒测试**：
> 不含原生 AppKit 视图、不含前端 UI 串（i18n 本包无新增串）。

## 交付

| 文件 | 内容 |
|---|---|
| `tools/rtaweb.cpp` | 新增 `GET /api/waveform`：解析 `file` / `bins` / `cs` / `ce` / `force`；复用 `analysis::detail::HealthSource` 流式解码（WAV/DSF/DFF）+ `WaveformAccumulator` 分块累加；进程内 LRU（≤32）、串行化与取消、稳定错误码 |
| `tests/test_waveform_api.cpp` | 新增。直接调 `rlapp::dispatch` 的黑盒判据：波形本体 / LRU 命中 / mtime 失效 / bins 钳位 / CUE 区间 / 路径错误 / 解码失败 / 缺省 file |
| `CMakeLists.txt` | 只加一处：`test_waveform_api` 可执行 + `add_test(NAME waveform_api ...)` |
| `evidence/u2-waveform-api-20261116.md` | 本文件 |

## 端点契约

`GET /api/waveform?file=<URL 编码绝对路径>[&bins=512][&cs=<秒>][&ce=<秒>][&force=1]`

- `file` 缺省 = 当前播放曲（`ps.current` → 最近一次播放参数）；两者都空 ⟹ 400 `waveform.path_missing`。
- `bins` 默认 512，钳 [16,4096]；返回的 `bins` / `peaks` / `rms` 长度都用钳位后的值。
- `cs`/`ce`：只算该区间（CUE 分轨），缺省 0..duration；返回的 `duration` 是**区间长度**。
- 成功：`{"ok":true,"cached":<bool>,"file":...,"rate":...,"channels":...,"duration":...,"bins":N,"peak":...,"peaks":[...],"rms":[...]}`。
- 稳定错误码：400 `waveform.path_missing` / 422 `waveform.decode_failed` /
  413 `waveform.too_large` / 409 `analysis.cancelled`（与 `/api/health` 同码）。
- 只读：不改文件、不打开音频设备、不监听端口。

## 解码 / 缓存 / 并发口径

- **有界流式优先**：与 `/api/health` 同一条 `HealthSource`（65536 帧/块），内存与曲长无关；
  WAV/DSF/DFF 正常文件一律走这条，绝不整曲铺 PCM。
- **整段回退有硬上限**：流式源判定「不能安全分块读」的格式才回退 `read_any`；
  解码前必须给出上界（原生格式用 `4 × 文件字节`，压缩格式问 `probe_media`），
  超过 `256 MiB` 已解码 PCM（或探测不到上界且文件 > 32 MiB）直接 413 `waveform.too_large`
  —— 宁可没波形，也不赌进程内存。解码后再核一次实际 `raw` 字节数（防线不减）。
- **缓存键** = 规范路径 + `FileIdentity(mtime,size)` + `cs`/`ce` + `bins`，命中还要求完整强身份
  `matches()`（mtime/size 相同但 inode/ctime 变了也不冒充）；LRU ≤ 32，`force=1` 跳过读缓存。
- **串行 / 取消**：`g_wfRunMtx` 保证同一时刻只算一个；新请求把旧请求的取消标志置真，
  旧请求在下一个分块边界退出（不写缓存）。计算只在 dispatch 线程，不碰播放线程。

## 红 → 绿

| 轮次 | 命令 | 结果 |
|---|---|---|
| 红 | 端点未接线时 `./build-mac/test_waveform_api` | **exit 1**：`13 passed, 33 failed`；失败响应全是 `{"ok":false,"error":"not found"}`（路由不存在；status 仍是默认 200） |
| 绿 | 端点接线后同一命令 | **exit 0**：`51 passed, 0 failed`，`/api/waveform 黑盒判据全部通过` |
| 绿（ctest） | `ctest --test-dir build-mac -R waveform_api --output-on-failure` | `1/1 Test #220: waveform_api ... Passed`、`100% tests passed` |

关键判据实测（30 s / 48 kHz / float32 WAV，10.0 s 唯一满幅脉冲，其余 −60 dBFS）：

- `bins=300`：peaks/rms 长度 300，argmax = **100**（∈ [99,101]），`peaks[100] = 1.0`、
  `peak ≈ 1.0`，底噪 bin ≈ 0.001；`rate=48000`、`channels=2`、`duration=30.0`。
- 同请求第二次：`cached:true`（LRU 命中，波形 argmax 不变）；`force=1`：`cached:false` 重算。
- 只推后 mtime 10 s：`cached:false` 重算（键含 FileIdentity）。
- `bins=1` → 返回 `bins=16`、peaks/rms 长度 16，脉冲落在 bin 5。
- `cs=9.5&ce=10.5` → `duration=1.0`、peaks 长度 16、脉冲落在区间 bin 8。
- 不存在路径 / 相对路径 → 400 + `waveform.path_missing`；损坏 WAV → 422 + `waveform.decode_failed`；
  没有在播曲目且缺 `file` → 400 + `waveform.path_missing`。

原始日志（`*.log` 不入库，见 `.gitignore:37`，仅本地留档）：
`evidence/u2-waveform-api-red-20261116.log`（首次运行的失败尾部）、
`evidence/u2-waveform-api-green-20261116.log`（绿轮直跑 + ctest）。

## 未做（按任务边界）

- 不碰 `tools/native_ui/*.mm`、不碰 8899、不发声（测试 `backend=null` + `volume=-120`，只调进程内
  `rlapp::dispatch`）。
- 本包不加 UI 串（i18n 无改动）；未跑全量 ctest，只跑 `waveform_api` 这一条。
- `waveform.too_large` / 取消分支未在黑盒测试里造大文件触发（需要 >256 MiB 解码上界的素材，
  不适合作为常规单测夹具）；判据代码路径已实现并有注释，未声称已实测。
