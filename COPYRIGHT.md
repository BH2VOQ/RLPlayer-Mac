# Copyright & Provenance

RLPlayer (macOS branch) is free software: you can redistribute it and/or modify
it under the terms of the **GNU General Public License, version 3 or later**
(SPDX: `GPL-3.0-or-later`). The full license text is in [LICENSE](LICENSE).

## Copyright holders

| Scope | Copyright holder |
|---|---|
| Upstream RLPlayer2 (Windows edition) — original DSP, engine, metadata and network code this branch derives from | **Copyright (C) 2026 rainlain** — GitHub: [@okhuoyanyan](https://github.com/okhuoyanyan) |
| macOS branch — platform layer, macOS app shell, packaging, UI adaptation and every change made since the fork | **Copyright (C) 2026 BH2VOQ** — GitHub: [@BH2VOQ](https://github.com/BH2VOQ) |

The macOS branch is an independent branch of RLPlayer2. It no longer merges with
upstream, but it is a derivative work: files under `src/audio`, `src/dsp`,
`src/engine`, `src/meta`, `src/net`, `src/analysis` and parts of `src/platform`
originate from RLPlayer2 and remain under the upstream author's copyright. The
macOS-specific parts (`src/platform/macos/**`, the native window shell, the
packaging scripts, Metal integration and all subsequent modifications) are
Copyright (C) 2026 BH2VOQ. Per-file headers state which case applies.

## Third-party components

| Component | License | Relationship |
|---|---|---|
| FFmpeg / FFprobe 8.1.2 | LGPL-2.1-or-later | Separate executables bundled in the `.app`, invoked as subprocesses |
| LAME (libmp3lame) | LGPL-2.0-or-later | Statically linked into the bundled FFmpeg executable |
| OPRA headphone EQ data | CC BY-SA 4.0 | Data only; see [OPRA-NOTICE.txt](OPRA-NOTICE.txt) |

## Redistributing

If you redistribute this program or a modified version, you must:

1. keep `LICENSE`, this file and the per-file copyright notices;
2. license the whole combined work under GPL-3.0-or-later and provide the
   corresponding source code;
3. state what you changed;
4. keep the attribution of the upstream RLPlayer2 author and of the third-party
   components listed above.

There is no warranty, to the extent permitted by law.

---

# 版权与来源

RLPlayer（macOS 分支）是自由软件，按 **GNU 通用公共许可证第 3 版（或更新版本）**
（SPDX：`GPL-3.0-or-later`）发布，完整条款见 [LICENSE](LICENSE)。

## 版权归属

| 范围 | 版权所有者 |
|---|---|
| 上游 RLPlayer2（Windows 版）——本分支所衍生的原始 DSP、引擎、元数据与网络代码 | **Copyright (C) 2026 rainlain** —— GitHub：[okhuoyanyan](https://github.com/okhuoyanyan) |
| macOS 分支——平台层、macOS 应用外壳、打包、界面适配与分叉之后的全部改动 | **Copyright (C) 2026 BH2VOQ** —— GitHub：[BH2VOQ](https://github.com/BH2VOQ) |

本仓库是 RLPlayer2 的独立 macOS 分支，不再与上游合并，但属于**衍生作品**：
`src/audio`、`src/dsp`、`src/engine`、`src/meta`、`src/net`、`src/analysis`
以及 `src/platform` 的一部分来自 RLPlayer2，版权仍归上游作者；
macOS 专属部分（`src/platform/macos/**`、原生窗口壳、打包脚本、Metal 接入
以及此后所有修改）版权归 BH2VOQ。每个源文件头部会写明适用哪种情况。

## 第三方组件

| 组件 | 许可 | 与本程序的关系 |
|---|---|---|
| FFmpeg / FFprobe 8.1.2 | LGPL-2.1-or-later | 作为独立可执行文件随 `.app` 分发，以子进程方式调用 |
| LAME（libmp3lame） | LGPL-2.0-or-later | 静态链接进随包的 FFmpeg 可执行文件 |
| OPRA 耳机 EQ 数据 | CC BY-SA 4.0 | 仅数据本身；见 [OPRA-NOTICE.txt](OPRA-NOTICE.txt) |

## 再分发要求

再分发本程序或修改版时必须：

1. 保留 `LICENSE`、本文件与各源文件的版权声明；
2. 整体仍以 GPL-3.0-or-later 发布，并提供对应源码；
3. 说明你改了什么；
4. 保留上游 RLPlayer2 作者与上述第三方组件的署名。

在法律允许的范围内，本程序不提供任何担保。
