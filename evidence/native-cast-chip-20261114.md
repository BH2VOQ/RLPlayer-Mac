# 投放芯片运行态 = web `npCastBtnHtml`（1.1.7.31 → 1.1.7.32）

日期：2026-11-14 · 仓库 `/Users/august/Downloads/DQ/RLPlayer` · 基线 `52a8428`（1.1.7.31，工作树仅 `?? website/`）
分支 main（仅本地提交，未推送）· 提交：`feat(native): cast chip running state, 1.1.7.32`

## 0. 结论

| 项 | 结果 |
|---|---|
| 新判据 `native_cast_chip` | 旧码 **1 passed / 1 failed**（无 refresh 方法后按条件收窄）→ 新码 **10 passed / 0 failed** |
| build | exit 0 |
| ctest / audit | 最终门禁统一复跑回填 |

## 1. web ↔ native 对照

| 维度 | web（`ui_script.h:8918-8927`、`13518`；`ui_page.h:770-772`） | 原生旧码（1.1.7.31） | 原生新码 |
|---|---|---|---|
| 状态源 | `CAST.state` ← `/api/cast/state`，`castRunning()` | 从不读 cast 状态 | 页面 live 期 2s 轮询 `/api/cast/state`（`startCastStatePoll`），离开页面停表 |
| 运行态 chip | `npcast.on`：`已推送到 <device>`、ok-bg/ok-text/ok-line、font-weight:600、tooltip「点击停止投放并恢复本机输出」 | 永远「推送到设备」 | 同 web；设备名取 `/api/cast/state.device` 的 host（web castDevNameOf 的 URL 分支） |
| 停止态 chip | `.npcast`：`推送到设备`、bg3/line/txt2、tooltip「把当前曲目推送到 UPnP / DLNA 设备」 | 同文案（无状态样式） | 同 web |
| 点击 | `castToggle`：running → POST `/api/cast/stop` + toast「已停止投放，输出回到本机」；否则弹设备列表 | 永远弹设备列表（投放中无法停） | running → stop + toast；否则原设备列表 |

## 2. 红 → 绿（同一份判据）

```
git checkout -- tools/native_ui/RLPNowPlayingViewController.mm
cmake --build build-mac -j8 --target test_native_cast_chip
./build-mac/test_native_cast_chip   # 1 passed / 1 failed, exit 1（旧码无 refreshCastChipState，守卫后干净退出）
git apply /tmp/castchip-prod.patch
./build-mac/test_native_cast_chip   # 10 passed / 0 failed, exit 0
```

日志：`evidence/native-cast-chip-red-20261114.log` / `-green-20261114.log`。

## 3. 判据覆盖（桩客户端、离屏、不出声）

- 调用生产入口后真的 GET `/api/cast/state`。
- running：chip 文案含「已推送到」+ 设备 host（192.168.1.10）、背景 = `--ok-bg`、字号 11。
- 投放中点击 → POST `/api/cast/stop`（**不**触发 NSAlert 设备列表）。
- 后端改为 not running 后刷新：文案「推送到设备」、背景 `--bg3`。

## 4. 如实挂账

1. 本包由 Lead 直接实现。
2. 设备名只用 `/api/cast/state.device` 的 host 回落（web 优先用 `/api/cast/devices` 的 label；原生未额外拉设备表，避免每次轮询两请求）。有设备列表时可再对齐。
3. 轮询固定 2s（web 由 CAST 轮询节奏驱动），未做可见性细粒度暂停（页面离开时停表）。
4. 实机投放未验，由用户实机验收。
