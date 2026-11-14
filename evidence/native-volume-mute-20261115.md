# v3.3.11 `npVolFloor` 静音 / 恢复（1.1.7.64）

> 待移植清单「音量旋钮 / 精确音量」组的第二部分（第一部分见 `native-precise-volume-20261115.md`）。

## 1. 上游真值（`/tmp/rlp2-v3311/ui_script.h:6372-6380`）

```js
function toggleVolumeMute(){
  if(!ensurePlaybackSettings())return;
  if(isRawVolumeLocked()){syncVolUi();return;}
  var db=Number(D('vol').value);
  if(db<=-120){if(volumeRestore===null)return;var restored=volumeRestore;setVol(restored);}
  else{volumeRestore=db;setVol(-120);}
  commitVolumeGesture();
}
['volFloor','npVolFloor'].forEach(function(id){if(D(id))D(id).onclick=toggleVolumeMute;});
```

语义：当前 `<= -120 dB` 且**没有**恢复值时**不做任何事**；否则记住当前值并静音 / 恢复先前值。

## 2. 实现

| 项 | 做法 |
|---|---|
| 控件 | `RLPNPControlBar.volMuteBtn`：`NSButton`，identifier `npVolFloor`，SF Symbol `speaker.slash.fill`，tooltip 复用既有词条 `静音` |
| 布局 | 放在 `npVolInput` 左侧 22pt；`minIconX` 守卫同时覆盖静音键 + 精确输入 + 图标，宽窗口仍保持 104pt 滑块 |
| 状态 | `volumeRestoreDb`（`NAN` = web 的 `volumeRestore === null`），`initWithFrame:` 显式初始化 |
| 公共落地 | 把 1.1.7.62 里 `onCommitPreciseVolume:` 的「下发 + 同步」抽成 `applyVolumeDb:`，精确输入与静音共用**同一条** `/api/volume?db=` 下发路径（不复制第二份逻辑） |
| action | `onToggleVolumeMute:` 逐行照 `toggleVolumeMute`：`preciseVolumeDb <= -120 && isnan(volumeRestoreDb)` → return；否则记住/恢复并 `applyVolumeDb:` |
| i18n | 复用 `静音`（`RLPNPVolDbLabel` 已用、词表已有），**未改生成表** |

## 3. 红 → 绿（`test_native_nowplaying_web.mm` 新增 M1–M7）

| 判据 | 旧码 | 新码 |
|---|---|---|
| M1 `npVolFloor` 控件存在 | FAIL | PASS |
| M2 有真实 target/action | 跳过 | PASS |
| M3 点静音真下发 `/api/volume?db=-120.0` | 跳过 | PASS |
| M4 静音后精确输入框同步 `-120.0` | 跳过 | PASS |
| M5 静音后标签为「静音」 | 跳过 | PASS |
| M6 再点恢复先前 `-12.5 dB` | 跳过 | PASS |
| M7 恢复后精确输入框同步 `-12.5` | 跳过 | PASS |

| 轮次 | 结果 | 证据 |
|---|---|---|
| 旧码（仅判据） | build 0 error；**1 FAIL**（M1，其余因 `mute=nil` 跳过） | `evidence/native-volume-mute-red-20261115.log` |
| 新码（1.1.7.64） | build 0 error；4 项相关 ctest 全绿 | `evidence/native-volume-mute-green-20261115.log` |

## 4. 如实挂账

1. 本组仍未做：`npVolKnob` SVG 圆弧旋钮、`npVolKnobArc/Ticks/Val`、`barVolInput`/`barVolDb`
   底栏镜像、`npRawVolumeNotice` 设备调音提示。
2. **未移植** `PLAYBACK_SETTINGS.ready` / `isRawVolumeLocked()` 锁定闸门与
   `commitVolumeGesture` 的 `volume=` settings 写回；本包只复用现有 `/api/volume?db=` 主链路。
3. 静音键按下态（`aria-pressed` 等价）未做：AppKit 侧只用图标 + tooltip，未随静音态换图/高亮。
4. `npVolFloor` 在 web 是 disabled 态受 `ready`/`locked` 控制；原生按钮始终可点，
   但 `volumeRestoreDb=NAN` 且当前 -120 时按上游语义直接 return，不会误恢复。
