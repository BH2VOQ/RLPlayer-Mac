# v3.3.11 反馈结果视图 + 提交前预览（1.1.7.68）

> 待移植清单「反馈结果」组。
> **重要结论**：上游 `/api/feedback/status` 在本仓架构里**没有对应物**，不能移植；
> 本包只移植两个**纯前端**能力（预览、持久结果），并如实记录契约差异。

## 1. 上游真值（`/tmp/rlp2-v3311/ui_script.h`）

| 前端 | 语义 |
|---|---|
| `rlFbTitle` / `rlFbBody` / `rlFbSteps` | 反馈三字段（`type/title/body/steps` payload） |
| `rlFbPreview` | 「先看会发送什么」——纯前端，不发请求 |
| `rlFbPreviewbox` | 预览框，`display:none` → 点了才出现 |
| `rlFbResult` | 持久结果区（`⚠️ 未能自动上传…` / `✅ 已提交成功…` / `❌ 提交失败…` + 技术细节） |
| `fbSubmit` → `POST /api/feedback` → `{accepted, job}` → 轮询 `GET /api/feedback/status?job=` → `fbShowResult` |
| 结果语义 | `uploaded` / `local`（保存到本地文件）/ 失败三种，且给「编号」供回访 |

## 2. 为什么 `/api/feedback/status` 不能移植（架构差异，非遗漏）

| 维度 | 上游（Web 版） | 本仓（macOS 原生） |
|---|---|---|
| 提交 | 前端 POST `/api/feedback`，后端**起后台 job** 打包上传 | 客户端进程内直接 `POST https://rlplayer.rainlain.com/api/v1/feedback/macos` |
| 打包 | 后端组装诊断 zip | `/api/diagjson`（与「导出诊断包」同一份已脱敏 JSON） |
| 结果 | 轮询 `/api/feedback/status?job=` | `rta::feedback::parse_feedback_upload_reply`（**成功只看 body.ok**） |
| 契约字段 | `type/title/body/steps` | `text/version/os/client/diag/idempotency_key`（六字段，有离线单测） |
| 失败兜底 | `local`：存本地文件让用户发群 | 无本地落盘（服务端不可达时只报错并保留正文） |

本仓**没有** `/api/feedback` 与 `/api/feedback/status`（`grep` = 0），且后端不承担反馈上传。
把 Web 版的后台 job 队列照搬过来属于**新增一套并行机制**，与现有直传路径重复，
不在「小范围本地改动」内 —— 故不移植，如实挂账。

## 3. 本包移植的两个前端能力

| 项 | 做法 |
|---|---|
| 预览 `sp_fbpreview` | `secondaryButton`，`onFbPreview:` 填充 `sp_fbpreviewbox`；文案**从真实请求参数派生**（端点取 `kFeedbackUploadUrl`、版本取 `RLPLAYER_VERSION`、系统取 `NSProcessInfo`、字节数取 `lengthOfBytesUsingEncoding:`、诊断包取开关状态），**不另写一份口径** |
| 预览框 `sp_fbpreviewbox` | 默认 `hidden = YES`（对齐 web `display:none`），可选中复制 |
| 结果区 `sp_fbresult` | 由 `fbResultText:kind:` **同时**写状态行与结果区；结果区留到下一次发送才更新（web `rlFbResult` 同语义）；空结果时隐藏不占位 |

为什么结果区必须存在：状态行会被下一次操作覆盖，用户回头想「刚才到底成没成」就没了 ——
这正是 web 版专门加了 `rlFbResult` 的原因。

## 4. 红 → 绿（`test_native_feedback_inline.mm` 新增 P1–P9 / G1–G3）

| 判据 | 红（控件缺失） | 绿 |
|---|---|---|
| G1 结果区存在 | FAIL | PASS |
| G2 成功后结果区可见 | **PASS（假阳性）** | PASS |
| G3 结果区保留工单号 `FB-TEST-1` | FAIL | PASS |
| P1 预览按钮存在 | FAIL | PASS |
| P2 有真实 target/action | FAIL | PASS |
| P3 预览框默认隐藏 | FAIL | PASS |
| P4 点击后出现预览框 | **PASS（假阳性）** | PASS |
| P5 预览含真实端点 | FAIL | PASS |
| P6 预览含真实正文字数（5 字） | FAIL | PASS |
| P7 预览反映「附诊断包」开 | FAIL | PASS |
| P8 关掉后改为「不附带」 | FAIL | PASS |
| P9 预览不发请求 | PASS（nil 控件自然不发） | PASS |

| 轮次 | 结果 | 证据 |
|---|---|---|
| 红（控件标识缺失） | build 0 error；**9 FAIL** | `evidence/native-feedback-preview-red-20261115.log` |
| 绿（1.1.7.68） | build 0 error；**52 passed / 0 failed** | `evidence/native-feedback-preview-green-20261115.log` |

**如实记录两处假阳性**：红阶段 G2 与 P4 「通过」了，因为 Objective-C 里 `nil.hidden == NO`
恒为「可见」。已把两条判据改成 `ctrl != nil && ctrl.hidden == NO`，绿阶段才是有意义的通过。

## 5. 如实挂账

1. **`/api/feedback/status` 不移植**（架构差异，见第 2 节），故上游的「后台打包 + 轮询」体验
   在本仓是「进程内后台队列上传」，无 job 号可轮询。
2. **无 `local` 兜底**：服务端不可达时本仓只报错并保留正文，不像 web 会存成本地文件。
3. **无 `rlFbTitle` / `rlFbSteps`**：本仓反馈契约只有 `text` 一个正文字段（六字段里没有 title），
   加标题框会变成「填了但没发出去」的假控件，故不加。
4. 预览文案是**人类可读摘要**（端点/版本/系统/字数/是否附诊断），不是原始 JSON 全文；
   web 版预览展示的是结论 + 技术细节，两者取向相同但格式不同。
