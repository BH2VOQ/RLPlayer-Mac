# P2 #npMeta 芯片图标：EQ / IR / 投放 / 加歌单（web 内联 SVG 同构）

- 日期：2026-11-14（P1 之后第四包）
- 基线：1.1.7.35（`3b02cf0`）→ 本包 1.1.7.36
- 范围：`tools/native_ui/RLPNowPlayingViewController.mm`（`styleMetaChip:` + 芯片宽度公式）、
  `tests/test_native_npmeta_chips.mm`（+3 条图标判据）
- 纪律：桩核心、不开核心、不出声。

## 1. web 真相 → 原生落点

| 芯片 | web（`src/net/ui_script.h`） | 原生旧码 | 本包 |
|---|---|---|---|
| EQ | `npEqChipsHtml`：11×11 inline SVG（三段滑杆），`vertical-align:-1px`（12755-12761） | 纯文字 `EQ` | SF Symbol `slider.horizontal.3`，11×11、`NSImageLeft` |
| IR | 同函数：11×11 波形 SVG（12762-12764） | 纯文字 `IR` | SF Symbol `waveform`，11×11 |
| 投放 | `npCastBtnHtml`：`castIconSvg()` + 文案（8918-8923） | 纯文字 | SF Symbol `airplayaudio`，11×11 |
| 加歌单 | 同函数：12×12 加号 SVG + `margin-right:4`（8924-8926） | 纯文字 | SF Symbol `plus`，11×11 |

## 2. 改了什么

1. `styleMetaChip:` 按 identifier 给四个芯片装 SF Symbol（模板图，`contentTintColor=t.text2` 自动跟随主题）；
   系统缺该符号时 `b.image=nil` 退回纯文字（绝不留下空白图位）。
2. `layoutMetaChipsInWidth:` 的芯片固有宽从 `ceil(text)+20` 改为 `+iconExtra(15)`（11px 图标 + 4px 间距），
   否则图标会压住文字/芯片互相重叠。徽标（badge）不走这条。

## 3. 红 → 绿（同一条测试，只换生产代码）

| 阶段 | 生产码 | 结果 | 日志（本机 evidence/，按 .gitignore 不入库） |
|---|---|---|---|
| RED | 1.1.7.35 原版（`git stash` 回旧芯片） | **84 passed / 2 failed**，exit 1 | `evidence/native-chip-icons-red-20261114.log` |
| GREEN | 本包 | **86 passed / 0 failed**，exit 0 | `evidence/native-chip-icons-green-20261114.log` |

红的两条：`EQ/IR 芯片带 SF Symbol 图标 — eq=nil ir=nil`、`投放/加歌单芯片带图标 — cast=nil add=nil`。
（芯片度量/文案/动作/换行判据在旧码与新码上都通过 —— 那是既有防线，不是本包新增的结论。）

## 4. 门禁（本包树 = 1.1.7.36）

| 门禁 | 结果 |
|---|---|
| build | `cmake --build build-mac -j8` **exit 0** |
| ctest | **197/197 passed, 0 failed**（393.19 s，exit 0；`evidence/native-chip-icons-ctest-197.log`） |
| audit | `rlplayer_native --audit`（隔离目录）**246 passed / 0 failed**，exit 0（`evidence/native-chip-icons-audit-20261114.log`） |
| parity | `parity_scan.py --check` exit 0（missing=0） |
| behavior | `behavior_scan.py --check` exit 0（actionable=0） |
| i18n | `gen_i18n_table.py --check` = OK（2318 pairs），exit 0 |

## 5. 如实挂账

1. 图标是 **SF Symbol 同构**，不是 web 的逐像素 SVG（形状相近、尺寸同为 11×11；不做像素级对照）。
2. 未在真机看四个芯片在 900/1180 宽度下的实际换行（离屏判据覆盖 1180/900/640；`native_npmeta_chips` 86/0 通过）。
3. 图标只加在这四个 `.chip`；其它芯片（如投放运行态文案变化）沿用同一按钮，图标不随文案变化而消失。
