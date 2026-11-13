# task-3 —— 设置页卡片归位 + 反馈就地发送 + 诊断摘要只复制（1.1.7.23）

日期：2026-11-14 · 仓库 `/Users/august/Downloads/DQ/RLPlayer` · 基线 `e40fde4`（1.1.7.22，工作树干净）
分支：main（仅本地提交，未推送）

## 0. 现场与基线（改前实测，全绿）

| 门禁 | 数字 | 证据 |
|---|---|---|
| build | `cmake --build build-mac -j8` exit 0 | 终端 |
| ctest | 184/184 passed | 终端 |
| audit | 246 passed, 0 failed | `native-3-baseline-audit.log` |
| parity | missing=0 / removed=1 / na=16 | `native-3-baseline-parity.log` |
| behavior | actionable=0（bindings 50） | `native-3-baseline-behavior.log` |
| i18n | OK (2316 pairs) | `native-3-baseline-i18n.log` |

## 1. 判据红 → 绿（同一份判据，旧码 vs 新码）

| 判据 | 旧码（HEAD `e40fde4`） | 新码（本提交） | 证据 |
|---|---|---|---|
| A/B 设置页结构（逐页 10 页签） | **39 passed / 41 failed** | **80 passed / 0 failed** | `native-3-settings-cards-red.log` / `-green.log` |
| C/D 反馈发送 + 诊断摘要（行为） | **12 passed / 22 failed**（旧码点发送打开新窗口、无 POST、摘要面板还在） | **40 passed / 0 failed** | `native-3-feedback-red.log` / `-green.log` |

旧码红判据的原文摘录（全部来自 `native-3-settings-cards-red.log`）：

- `【adv】页面层不存在孤立控件 — leaks=12: NSTextField(sp_gpumsg) … NSButton(sp_browseRoot)`
- `【in】页面层不存在孤立控件 — leaks=12: NSButton(sp_instart,"开始采集") … NSPopUpButton("录制到文件")`（**卡片内外各一套**）
- `【in】每张卡片都有真实卡体内容 — 空壳卡片：采集实时状态`
- `【out】页面层不存在孤立控件 — leaks=6: NSPopUpButton(sp_upnp_dev,"(正在发现…)") | NSButton(sp_upnp_scan,"重新发现") | NSTextField(sp_backendmsg) | NSTextField(sp_trimchmsg)`
- `【out】每张卡片都有真实卡体内容 — 空壳卡片：声道音量微调`；`声道音量微调按 2 声道生成真实控件 — count=0`
- `【pcm】leaks=1: NSTextField(sp_phasemsg)`；`【sdm】leaks=2: sp_dsdmodenote | sp_dsdmsg`
- `【eq】leaks=12 + 页面至少有卡片容器 — cards=0`；`【cal】leaks=12 + cards=0`
- `【meta】leaks=10: llm.modelpopup/modelrefresh/modelmsg/save/test/clear/status + search.save/clear/status`
- `【stream】leaks=12（srv.add / 整张表单）+ 空壳卡片：流媒体服务器 | 推送到设备`
- `【diag】leaks=6: sp_vercur/updcheck/updinstall/updmsg/updbar/updnote`；`【D】旧面板还在`

新码行为判据的要点（`native-3-feedback-green.log`，40/0）：

- 点「发送反馈」前后 `NSApp.windows` 数量与标题指纹完全不变（旧码 `before=1: after=2:|反馈`）。
- 抓到的请求 URL == `https://rlplayer.rainlain.com/api/v1/feedback/macos`（`feedback_api.h` 代码常量），
  请求体恰好六个协议字段 `text/version/os/client/diag/idempotency_key`；`diag` 是 base64，解码后是 JSON 对象。
- 成功文案逐字 `已收到，工单号 FB-TEST-1。感谢反馈！`；失败 `发送失败：请求过于频繁（稍等一会儿再试）`；
  通道不可用时按钮禁用 + 程序化触发也被拒（`反馈后台当前不可用，请稍后再试`）。
- 计数初值 `0 / 16384 字节`（不再是用户截图里的 `1 / 16384`），6 个汉字 = 18 字节；
  上限数字**从 web 源码 `var FB_MAX_BYTES = <n>` 机器抽取**后比对（不手抄）。
- 超过上限点击被拦下且不发请求（文案前缀 `内容超过 `，与 web 同构）。
- `查看 / 复制诊断摘要`：点前后窗口数不变、剪贴板 == 生产代码对固定摘要样例的 pretty JSON（逐字节）、
  页面提示 `摘要已复制`、导出卡内无任何非空 NSTextView（JSON 面板已删）。

## 2. 改了什么（对应 A/B/C/D）

### A/B 设置页（`tools/native_ui/RLPSettingsViewController.mm` 为主）

统一根因：大量 `[stack addArrangedSubview:...]` 把控件直接挂到**页面级 stack**，而卡片（`RLPSettingsGroup`）
只建了标题条。修法是把每个分组的内容改为卡片 API（`addField/addWideField/addButtonRow/addFullRow/addNoteView`），
并让子界面（输入状态 / 服务器 / 投放 / EQ / 校准）作为卡片体整行嵌入。

| 页 | 修法 |
|---|---|
| 通用 | GPU 状态行、库统计块、目录按钮行、目录列表、网络查询按钮/结果 → 各自卡片体 |
| 输入 | 删掉第二套采集控件：`RLPInputView` 新增 **statusOnly** 模式只保留实时状态区块（配置控件由卡片承载）；「刷新设备」按钮移入卡片；开始采集请求体按 web：`mode/dev(id)/seconds/out`（旧码空 body = 丢功能）。旧视图独有的 **mode=null「空跑（不开设备）」** 用同卡开关保留（铁律①不删功能） |
| 输出 | UPnP 目标渲染器整行（含标签）归「输出后端」卡，按 web 在非 upnp 后端时整块隐藏；后端行改整行（不再被挤成「…」）；「声道音量微调」**按实际声道数生成 NSSlider**（默认跟随源=2，改 6/8 重建，滑杆 accent 色），说明行同卡 |
| PCM/SDM | 相位说明 / DSD 模式提示 / DSD 说明 → 卡片体注记 |
| EQ / 声音校准 | 子界面整块作为卡片体（旧码整页无卡片） |
| 元数据 | 模型下拉+刷新+模型状态+保存端点/测试连通/清除密钥 → 「AI 接入」卡；检索端点/地址/Key/保存/清除/掩码状态 → 「联网检索端点」卡；标签写回继续留在 AI 卡（不回退） |
| 流媒体 | 服务器管理子视图 → 「流媒体服务器」卡；投放子视图 → 「推送到设备」卡 |
| 诊断 | 更新通道/版本/检查更新/Beta/进度/说明 → 「软件更新」卡；反馈表单全部在「反馈问题」卡；导出三按钮+提示在「导出诊断包」卡 |

### C 反馈发送（就地）

- 点「发送反馈」= `onSendFeedback:`：校验（空 / 超 16384 字节 / 通道未确认）→ 需要时拉 `/api/diagjson` →
  `feedback_api.h` 组装六字段 → 生产路径 `rta::net::http_post(kFeedbackUploadUrl, …, 120s)`。
- 探活 `probeFeedbackChannel`：`parse_feedback_watchdog`（200+ok 才算可用），12s 兜底、失败显示原因 + 「重试探活」；
  进诊断页探活一次，30s 内不重复（web bindFeedbackCard 同口径）。
- **不再**打开 `RLPFeedbackWindowController`（弹窗代码保留在菜单入口，未删除功能；设置页发送改走就地路径）。
- 计数：`0 / 16384 字节`，UTF-8 字节（与当前 web 源码一致）。

### D 诊断摘要

- 删除 `sp_diagsummarytext` / `sp_diagscroll`（JSON 面板），`onDiagSummary:` 只做「取 /api/diag → 剪贴板 + 就地提示」。
- 已登记 `docs/native-ui/parity_removed.tsv`（ctrl `sp_diagsummarytext`，双向核验通过：web 有 / 原生无）。
- **没有恢复**「随反馈上传诊断」（仍只有 `sp_diagupload` 一条 removed 记录）。

## 3. 原生 vs web 同页对比

- 用户提供的 before 截图（原生故障现场）与修复后离屏截图逐页并排：
  `native-3-compare-input.png` / `-output.png` / `-meta.png` / `-stream.png` / `-feedback.png` / `-diag-summary.png`。
- 修复后逐页离屏截图（1400px 宽统一缩放前原始文件）：`evidence/native-3-shots/native-pane-*.png`；
  旧码同页截图：`evidence/native-3-shots-before/native-pane-*.png`。
- web 侧对照基准：本仓 `src/net/ui_script.h` 的 `sgroup()` 结构 + 用户提供的 web 截图（v1.1.6，图七）：
  `evidence/native-3-web-diag-reference.png`。web 的 `#sp_trimwrap` 内是 `sgroup('声道音量微调')` 数字输入；
  `#sp_upnpwrap` 在「输出后端」`sgroup` 内；`#sp_metaadv` 右列 meta-card 是 AI 接入、跨列 meta-card 是联网检索端点。
- **未能产出新的 web 运行截图**：按禁止无头浏览器/不得 shell 拉起 Chrome 的纪律，唯一浏览器通道是 DSH 侧边栏，
  其画面没有可导出的文件接口；因此 web 侧对比用「web 源码结构 + 用户图七」而不是 agent 自采截图。
  这是本项如实挂账的缺口（见 §5）。

## 4. 门禁（提交后复跑）

见 `evidence/native-progress.md` 末尾与本提交报告；ctest 由本提交新增两条用例：
`native_settings_cards`（80 checks）与 `native_feedback_inline`（40 checks），总数 184 → 186。

## 5. 如实挂账 / 仍未解决的差异

1. **真实网络 POST 未被实际发送**：C 的端点/请求体/回包判定用测试接缝（`fbUploadTransport`）抓包验证，
   生产路径与接缝共用同一个 `build_feedback_upload` 与 `parse_feedback_upload_reply`；但「真正打到远端」这条
   只有探活（真 GET）被实跑过，POST 未真发（避免给用户后台灌测试工单）。
2. **web 侧运行截图缺口**：见 §3（禁止无头浏览器，侧边栏画面不可导出）。
3. **EQ 页卡片粒度**：web 是两张卡片（参数均衡 / 耳机 EQ），原生用一张「均衡器（PEQ / 耳机 EQ）」卡承载整个
   子界面（满足「全部控件在同一卡片容器」的判据，但分组粒度比 web 粗）。
4. **流媒体/输入/投放子视图内部仍是旧布局**：它们已成为卡片后代（结构判据绿），但内部标签/宽度仍是旧的固定值，
   窄窗口下不如 web 的响应式列；这是本轮不动的范围。
5. **字数上限的历史差异**：用户图七的 web 是 v1.1.6（`0 / 8000`，按字符）；本仓当前 web 在 `b00247d` 已改成
   `0 / 16384 字节`（按 UTF-8 字节）。原生按要求对齐**当前 web 源码**（16384 字节 + 「字节」单位），
   并在测试里从 `ui_script.h` 机器抽取该常量比对。若用户要的是 v1.1.6 旧口径，需要另行指示。
6. **i18n**：新增的中文短文案（如「刷新设备」「按 N 声道显示」「均衡器（PEQ / 耳机 EQ）」等）走 `RLPTr` 回退，
   未新增 `docs/i18n` 词条（门禁 `i18n_table_check` 只校验 TSV → 生成表，不受影响；英文界面下这些新串仍是中文）。
