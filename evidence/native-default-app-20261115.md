# 默认 packaging 切到原生版（1.1.7.63）

> 用户 2026-11-15 原话：「**2 的话 默认开原生版 原生版是要替代 web 版的**」。
> 结论：**不做双向切换键、不设共用 conf 键**；原生版是默认与最终形态，web 版只留作对照/回退。

## 1. 决策边界

- 原任务 #12 写的是「默认界面切换开关（原生 / web，共用同一设置键）」，
  用户答复把它收敛为「默认原生、原生取代 web」，因此**不实现运行时切换开关**，
  也不需要新增设置键。改动只落在**打包默认值**。
- 不删任何功能：`rlplayer_mac`（web 壳）与 `rlplayer_native`（AppKit）两个可执行都照旧构建，
  只是 `.app` 里 `Contents/MacOS/RLPlayer` 默认放哪一个变了。

## 2. 改了什么

| 文件 | 改动 |
|---|---|
| `tools/make_app_mac.sh` | 默认 `APP_BIN_NAME=rlplayer_native` / `APP_DIR_NAME=RLPlayer`；显式 `RL_WEB_APP=1` → `rlplayer_mac` / `RLPlayer-Web.app`；旧 `RL_NATIVE_APP=1` 兼容保留 → `rlplayer_native` / `RLPlayer-Native.app`。新增只读自省入口 `--print-default-bin`（在 `rm -rf` 之前 `echo` + `exit`，不打包、不写文件） |
| `tests/check_native_default_app.cmake`（新） | ctest 判据：真跑 `zsh tools/make_app_mac.sh --print-default-bin`，断言默认 `rlplayer_native`、`RL_WEB_APP=1` → `rlplayer_mac`、`RL_NATIVE_APP=1` → `rlplayer_native`，三条 rc 均 0 |
| `CMakeLists.txt` | 新增 `add_test(NAME native_default_app ...)` |
| `src/version.h` | `1.1.7.62 → 1.1.7.63` |

## 3. 红 → 绿

| 轮次 | 结果 | 证据 |
|---|---|---|
| 旧码（加判据 + 自省入口，默认仍 `rlplayer_mac`） | `native_default_app` **FAIL**：`默认主可执行应为 rlplayer_native，实际 'rlplayer_mac' rc=0` | `evidence/native-default-app-red-20261115.log` |
| 新码（1.1.7.63） | `native_default_app` **PASS**（默认 / web 对照 / 旧 flag 三条全对） | `evidence/native-default-app-green-20261115.log` |

判据走脚本的**行为输出**（`execute_process` 真跑 zsh），不是 grep 字符串，所以默认值被改回 web 会立刻红。

## 4. 如实挂账

1. `docs/native-ui/PLAN.md` §2.2 仍写「原生默认 | 未切换」，但该文件有**外来未提交 WIP**
   （ego 通道注释），本包按「绝不 stage 外来 WIP」纪律**不改它**；状态以本证据为准。
2. `tools/README.md` 里若还有「默认 web」说明同理未动（外来 WIP）。
3. 未改 `latest.json`、未发版、未打 tag、未推送；`RLPlayer.app` 产物名不变，
   但**内容从 WKWebView 壳变成 AppKit 原生**，用户实机安装/更新时需注意这是形态切换。
4. web 版仍可用 `RL_WEB_APP=1 zsh tools/make_app_mac.sh build-mac` 出对照包，功能未删。
5. 判据只覆盖「打包默认值」；真实出包（`.app` 内主可执行与架构门禁）未在本包重跑，
   由用户实机验收，`make_app_mac.sh` 的既有自检（arm64 / minos / 自包含）保持不变。
