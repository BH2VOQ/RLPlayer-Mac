# web↔native 循环：本轮收尾与差距清单（2026-11-14 12:xx）

> 截止：用户指定 **14:00**。本文件是当时差距清单（未完成项、只做到一半的项、需要用户实机配合的项）。

## 本轮已落地（本地提交，未推送/未发版/未打 tag）

| 版本 | 提交 | 内容 | 判据（旧码红 → 新码绿） |
|---|---|---|---|
| 1.1.7.33 | `5a7b950` | P0-1 播放/暂停三入口：底栏、播放页、菜单/媒体键；停止态重播（web `playOrPause` 同语义） | `native_pause_paths` 8/8 红 → 16/0 绿 |
| 1.1.7.34 | `3419fa3` | P0-2 诊断包：默认预算 12→7.5 MiB（STORE ZIP 实际 7,605,710 B ≤ 8 MiB）；原生导出校验 PK 头/大小、提示写真实 MB | `test_diag_bundle` 103/3 红 → 106/0 绿 |
| 1.1.7.35 | `201235b` | P1 EQ/OPRA：型号卡片 + 预设卡片墙（曲线小图/作者·详情/段数/前级/应用按钮/当前态），读 settings 的 opraproduct/oprapreset | `native_opra_cards` 1/6 红 → 16/0 绿；`native_target_curve` 更新为卡片入口 21/0 |
| 1.1.7.36 | 本包 | P2 chip 图标：EQ/IR/投放/加歌单芯片装 SF Symbol（web 内联 SVG 同构），芯片固有宽补 15pt | `native_npmeta_chips` 84/2 红 → 86/0 绿 |

**证据**：`evidence/native-pause-paths-20261114.md`、`evidence/native-diag-8mib-20261114.md`、
`evidence/native-opra-cards-20261114.md`（含 before/after PNG 与红/绿日志落盘说明）。

## 仍未做 / 只做了一半（按优先级）

1. **P2 古典曲目第 4 张「作品」卡**（未开始）
   - web：`npDataTargets` 在 `npIsClassical(m)` 时追加 `{k:'work',label:'作品',name:w.title,composer}`（`src/net/ui_script.h:12818-12845`）；
   - 原生：`renderRailMetadata` / `onRailCard` / `railTargets` 仍硬编码 3 种 `track/release/person`（`RLPNowPlayingViewController.mm:2137`、`2195`）；
   - 需移植 `npIsClassical`/`npWorkTarget` 的判定与 composer/work title 提取，并改 4 张卡的布局、点击实体与判据（`native_rail_preview` 要扩）。
   - 目前「作品」入口仍在单曲页右键菜单/`openWorks`，功能没删，只是右栏少一张卡。
2. **抽屉 vs 气泡**（未开始）：web 播放页资料是右抽屉（`npDrawer`），原生点卡片用 `RLPShowCardPopover`
   气泡（`RLPNowPlayingViewController.mm:2229` 附近）。两种形态的用户心智不同，需统一；涉及交互/键盘关闭/布局，非小改。
3. **chip SVG 图标**（本轮已完成，1.1.7.36）：四个芯片装 SF Symbol（11×11），宽度公式补 15pt；
   判据 `native_npmeta_chips` 86/0。残余：图标是符号同构、不是 web 的逐像素 SVG。
4. **默认渲染器切换**（未开始）：需要先定位 web 的入口与设置键（`ADV` 里的 renderer/default 相关），原生设置页尚未接。
5. **双模式薄表现层**（未开始）：web `classic/apple` 两套表现层中，"薄"的校准/EQ 浮层在原生是设置页内联，形态未对齐。
6. **播放 RENDERFAIL 根因**（挂账，需用户诊断包）：本轮未改引擎；用户若再遇到"播不出/播放中断"，
   请用 1.1.7.35 的「设置·诊断→导出诊断包」发回（包内 `rlplayer-playback.log` 的 `RENDERFAIL` 行自带归因）。
7. **`native_ui_functional` 偶发 bus error**（既有 open flake，本轮出现 1 次）：
   本轮 1.1.7.35 第一次全量 ctest 在 #23 `native_ui_functional`（专辑详情导航处）bus error；
   同一二进制单跑 `rlplayer_native --audit` **246/0 通过**；第二次全量 ctest 通过。历史上 5 次全量出现 2 次，
   单跑/换轮均不复现。按 open flake 记录，未在本轮改它。

## 需要用户实机确认（agent 不代做）

1. `open dist-mac/RLPlayer-Native.app`（或 `./build-mac/rlplayer_native`），左下角应为 **v1.1.7.35**。
2. 播放中分别试：底栏暂停键 / 播放页暂停键 / 键盘媒体键 / 菜单「播放 / 暂停」；
   期望都真的停住（进度冻结），再操作恢复；停止后再点播放键应**重播当前曲目**（旧版这里无反应）。
   - 若"播放中暂停无效"仍出现，请在**那一次运行**里导出诊断包发回（不要事后重启再导）。
3. 设置·诊断→「导出诊断包（.zip）」：文件应 ≤ 8 MiB（本轮判据实测 7.6 MB 的大日志夹具）；
   设置·反馈勾选「附带诊断包」发送也应通过 8 MiB 闸门。
4. 设置·均衡→OPRA：搜索型号应出**型号卡片**（点选）→ **预设卡片墙**（曲线小图/作者·详情/段数/前级/应用到 EQ/已应用当前预设）；
   点「应用到 EQ」后当前态应翻到该卡，EQ 曲线随之更新。

## 本轮没改的东西（避免误读）

- 没有推送任何 remote、没有发版、没有打 tag、没有改 latest.json。
- 没有在真实音频设备上播过任何声音（所有自动化均不启动播放核心或 `volume=-120/backend=null` 语义）。
- 没有改 `src/net/ui_script.h` / `ui_page.h` 的 web 侧行为；P0/P1 都是原生侧 + `src/diag/bundle.h`。
