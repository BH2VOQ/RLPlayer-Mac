# 上游 UI 源码核实与对照（2026-11-14 23:xx）

> 触发：用户消息「上游代码更新了，把上游代码拉下来，ui 参考上游代码重新开发」。
> 纪律：本机 200+ 个未推送提交是**唯一成果**；只做 `git fetch` 与只读下载，
> **未 merge / rebase / reset / checkout**，工作树与本地分支零改动。

## 1. fetch 前后基线

| 项 | 值 |
|---|---|
| fetch 前 HEAD | `1bfa64ef0912b8f5b39672feade0ae72fcaf6beb`（1.1.7.57） |
| fetch 后 HEAD | 同上，未变 |
| 分支 | `main`，未变 |
| 本地 vs `origin/main` | `0 105`（本地领先 105 提交，无落后） |

## 2. 三个 remote 的真实状态

| remote | 地址 | main tip | 结论 |
|---|---|---|---|
| `github` | `BH2VOQ/RLPlayer-Mac` | `eae8d68` 2026-11-11 09:26 `release: point latest.json at 1.1.6` | 本项目公开镜像，停在 1.1.6；本次 fetch 因本机代理端口 7897 未监听而失败 |
| `origin` | `ssh://git@153.75.233.149:2222/August/RLPlayer-Mac.git` | 同上 `eae8d68` | 本次 fetch 成功（仅新增 tag `v1.1.5-beta3`），无新提交 |
| `upstream` | `okhuoyanyan/RLPlayer2` | `5ca77f6` 2026-11-02 `docs: README 补全官网主页内容…` | 本次 fetch 因直连 GitHub 超时失败；`ssh usa` 读 GitHub API 复核 **最新提交仍是 11-02 的 5ca77f6**，与本地已有 remote-tracking ref 一致 |

**⟹ 本机可见的三个 remote 都没有「上游刚更新」的 UI 代码。**
`RLPlayer2` 最近一次提交是 11-02 的 README 文档，比本工单基线（11-14 1.1.7.57）还早 12 天。

## 3. 上游 UI 源码已只读下载（仓库外）

`ssh usa 'curl -sSL raw.githubusercontent.com/.../main/src/net/{ui_page.h,ui_script.h}'`
→ `/tmp/rlp2-ui/`（共 831907 字节，未进仓库、未入 git）。

上游确实有这两个文件（首次 grep 因管道提前关闭漏判，第二次用落盘 JSON 复核确认）：
`src/net/ui_page.h` / `src/net/ui_script.h` / `src/net/webui.h` / `website/index.html`。

## 4. 逐行对照统计（上游 vs 本仓 web 版）

| 量 | 上游 RLPlayer2 | 本仓 macOS 分支 |
|---|---|---|
| `ui_page.h` | 1465 行 / 130075 B | 1767 行 / 148846 B |
| `ui_script.h` | 12065 行 / 547482 B | 14414 行 / 650767 B |
| `id=` 控件 | 396（上游独有 84） | 405（本仓独有 93） |
| `D('id')` 引用 | 427（上游独有 86） | 438（本仓独有 97） |
| `setView()` 视图 | 8（独有 `pl`） | 11（独有 `files/queue/remote/station`） |
| `/api/` 端点 | 138（独有 36） | 139（独有 37） |
| `function` | 504（独有 171） | 608（独有 275） |
| `diff -u` | `ui_page.h` +787 / -1089 行 | `ui_script.h` +6877 / -9226 行 |

上游独有的代表性能力：`micCal*`（麦克风校准）、`rc*`（房间校正向导）、`update/*`、`sq/*`+`pl*`（歌单）、
`/api/asio`、`/api/feedback`、`/api/i18n`、`/api/lyrics/ai`、`anlL0Card/anlDeepHtml/anlSkeletonHtml`（另套分析卡）。
本仓独有的代表性能力：`opra/*`、`/api/gpu`、`/api/providers`、`/api/anl/cancel`、
`/api/lib/rmdir*`、`/api/naa/discover`、`amCard*`（Apple Music 风格首页）、`cast_up*`。

## 5. 结论与风险（必须先确认，不要直接「重新开发」）

1. **不是「上游更新、本地落后」**：两条线早已分叉，各自有 80~270 个对方没有的 id/函数。
   上游 `ui_script.h` 比本仓**少 2349 行**，直接拿它当模板重做会**丢掉本仓大量功能**，
   违反项目铁律①「功能不能删除，只做全量移植」。
2. **与既定决策冲突**：`AGENTS.md` / skill `rlplayer-dev` §1.5 明确
   「macOS 是独立分支，不再同步上游；上游参考以 `okhuoyanyan/RLPlayer2` 为准（只做参考）」。
   「参考上游重新开发 UI」若指整体替换骨架，需用户明确覆盖该决策。
3. **可执行且安全的做法**：把上游**独有的功能点**逐条当「待移植清单」，
   比对本仓 web 版 → 补进 web 版 → 再同步进原生版（本工单原有的逐行对照循环），
   而不是替换 UI 骨架。

## 6. 待用户确认（已阻塞「重新开发」方向）

- 「上游」具体指哪个仓库/分支？是 `okhuoyanyan/RLPlayer2`（11-02 无新提交），
  还是另有新版本/新仓库/某个 PR 或附件？若是后者请给地址或提交 SHA。
- 「重新开发 UI」是要**替换骨架**，还是仅**移植上游独有的功能**？
  前者会与「macOS 独立分支不同步上游」冲突且有删功能风险，建议后者。

## 7. 更正（同日 00:xx）：新版本在 release tag，**不在 main**

§2 的结论「没有上游刚更新的 UI 代码」**不成立** —— 原因是当时只查了 `main` 分支。
用户指出 RLPlayer2 GitHub 有新版本后，改用 `git ls-remote --heads/--tags` 复核：

| ref | commit | 说明 |
|---|---|---|
| `refs/heads/main` | `5ca77f6` | 11-02，未变 |
| `refs/heads/codex/release-3.3.1` | `05fdd44` | |
| `refs/heads/codex/release-3.3.11` | `4ab338e` | **新版本分支** |
| `refs/tags/v3.3.11` | `4ab338e` | Release「RLPlayer 3.3.11（Windows 64 位正式发布版）」，`published_at=2026-11-14T15:34:13Z` |
| `refs/tags/v3.3.1` / `v3.2.2` | `05fdd44` / `5ca77f6` | 历史版本 |

本机 `gh api`（dsh-superagent 账号）对 `okhuoyanyan/RLPlayer2` 和 `BH2VOQ/RLPlayer2`
均返回 404；权威数据来自 `ssh usa` 的 `git ls-remote` 与 GitHub releases API。
**教训**：查上游是否更新必须同时看 heads / tags / releases，只看默认分支会漏掉 release 分支。

v3.3.11 的 `ui_page.h` / `ui_script.h` 已按 tag 只读下载到 `/tmp/rlp2-v3311/`：

| 量 | v3.3.11 | 旧 main(5ca77f6) | 相对 main |
|---|---|---|---|
| `ui_page.h` | 1617 行 | 1465 行 | +192 / -40 |
| `ui_script.h` | 14438 行 | 12065 行 | +3082 / -709 |
| `id=` | 463 | 396 | 新增 71 |
| `/api/` | 150 | 138 | 新增 14 |
| `function` | 650 | 504 | 新增 148 |

新增代表（相对本仓 web 版也独有）：音量旋钮 `npVolKnob*`/`npVolInput`/`npVolFloor`、
封面设置 `npSetCover`/`npResetCover`/`npCoverFile`、M3U 导入 `qImportM3u`/`qM3uFile`、
快速启动 `qs*`/`rlDailyMenu`/`rlFolderList`、反馈结果 `rlFb*`、
播放设置 `playbackSettings*`/`ensurePlaybackSettings`、
`/api/cover/{lookup,set,reset}`、`/api/qa/{next,done,text}`、`/api/sq/*`、`/api/i18n/miss`、
`/api/feedback/status?job=`、`/api/update/manual`。

**结论修订**：上游确实有刚发布的新版本；但与本仓 macOS 分支仍是分叉实现
（`ui_script.h` 相对本仓 +8637/-8613 行），整体替换骨架会丢本仓约 275 个独有函数。
按 §5 第 3 条执行：**逐条移植 v3.3.11 新增功能点**，不替换骨架。
