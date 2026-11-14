# #14 播放 RENDERFAIL：状态挂账（2026-11-15）

> 用户 2026-11-15 原话：「这个已经没办法拿诊断包了 已经不知道是哪个版本的 bug 了 就先当不存在吧」。
> 编排口径：**用户放弃提供诊断包、暂挂账、停止追查**；**不是已修、不是不存在、不是根因已定位**。

## 1. 已经观察到的（只读，来自本机日志，不是用户现场）

`~/Library/Application Support/RLPlayer/rlplayer-playback.log`（多个历史版本 1.1.5~1.1.7.x）：

- 设备 `Pocket Master Audio`（Sonicake，USB），`system_profiler SPAudioDataType` 显示
  当前 44100 Hz；`PRESET_CAPS` 记录 `rates=[44100] maxRate=44100 exclusive=1 ch=2 bits=24`。
- `rlplayer-settings.conf` 里 `hogexcl=1`（严格独占）、`rate=96000`、`backend=coreaudio`。
- 典型失败链：独占流 `RENDERFAIL 设备流 ~2.4x 秒未接受数据（连续 201 轮未写入）`
  → `FALLBACK_SHARED` 自动回退共享 → 共享模式同样 201 轮未接受数据 → `END error="RENDERFAIL …"`。
  伴随 `w0=402 wr=2 zp=402 zs=0 zo=0 zr=pad=full coreaudio_rendered=0 underruns=0`。
- `src/audio/render_loop.h` / `src/platform/macos/audio_out_coreaudio.h` 已有 RENDERFAIL
  遥测与超时 break；`test_renderfail` ctest 覆盖归因分类（一直绿）。

## 2. 为什么不能定为「已修」或「不存在」

- 上述日志来自**本机历史多个版本**，用户已明确「不知道是哪个版本的 bug」，
  无法把任何一条与当前 `1.1.7.63` 对应起来。
- 缺用户侧**那一次失败运行的当次诊断包**（`rlplayer-playback.log` 全量 + 设备列表 +
  严格独占状态 + 设置快照），无法区分设备/驱动/系统混音/独占流启停四类成因。
- 因此**未改任何播放引擎代码**，也没有可判据的根因；`test_renderfail` 绿只证明归因分类
  逻辑对，不证明故障消失。

## 3. 决定与边界

| 项 | 状态 |
|---|---|
| 追查 | **停止**（用户 2026-11-15 决定） |
| 挂账 | **暂挂账**：#14 从「待办」移到「用户放弃输入、暂不追」，**不销项、不写已修** |
| 代码 | 播放引擎零改动；不改 `hogexcl`、不改独占/共享回退逻辑 |
| 日志 | 已有观察记录保留，不删原文 |
| 复现条件 | 若将来出现**可复现**的当期失败并带当次诊断包，重新开包，先红后绿 |

## 4. 与「已知偏差清单」的关系

`evidence/native-known-deviations-20261114.md` 只收「已解释、有判据的有意偏差」。
#14 不属于该表（既非已解释偏差，也非已关闭项），所以单独记在本文件，不塞进偏差表。
