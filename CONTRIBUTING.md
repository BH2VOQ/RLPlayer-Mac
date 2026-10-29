# 贡献指南

感谢愿意帮忙。这个项目的判定标准只有一条：**每一步都要有可复现的实测数字**，不接受「我觉得更好听」这类结论。

## 开发环境

- macOS 13.0+ / Apple Silicon（arm64）
- CMake ≥ 3.20、Xcode Command Line Tools
- 不需要额外运行库：`.app` 自带 ffmpeg / ffprobe / Metal 内核

```bash
cmake -S . -B build-mac -DCMAKE_BUILD_TYPE=Release
cmake --build build-mac -j8
ctest --test-dir build-mac --output-on-failure
```

## 提交前必须过的门禁

| 门禁 | 命令 | 期望 |
|---|---|---|
| 构建 | `cmake --build build-mac -j8` | 0 error |
| 测试 | `ctest --test-dir build-mac --output-on-failure` | 100/100 passed |
| 出包 | `bash tools/make_app_mac.sh` | 架构 / 部署目标 / 签名门禁全过 |

**看退出码，不要只看尾行。** 历史上有过「尾行像成功、退出码非 0」的合并事故。

`ctest` 请在本机空闲时串行跑：并行跑重型构建会让个别用例假红。

## 提交信息格式（中英双语，英文在前）

标题用英文；正文先英文、后中文，中间用 `---` 分隔。中文标题放在中文正文第一行。

```text
feat(scope): one-line English summary

What changed / why / evidence (English).

---
feat(scope): 一句话中文摘要

改了什么、为什么、判据（实测数字贴进来）。
```

- 前缀沿用 `feat` / `fix` / `docs` / `chore` / `test` / `release`。
- 标题与正文都不能只有一种语言；数字、版本号、文件名两边必须一致。
- 正文写清三件事：**根因、改法、判据**（实测数字贴进来）；涉及取舍的地方写明为什么这样选。

## 不接受什么

1. **为了让测试变绿而改阈值**。判据错了就修判据，不许调参凑绿。
2. **没有实测的「已修复」**。只做了代码审查就写「仅代码审查」。
3. **把可听声音当测试手段**。测试音默认 ≤ −60 dBFS，优先走离线分析与 Null 后端。

## 报告问题

优先用 [Issue 模板](https://github.com/BH2VOQ/RLPlayer-Mac/issues/new/choose)。
更方便的方式是 App 内 **设置 → 诊断 → 发送反馈**：可勾选附带诊断包（已脱敏），省去手工收集日志。

安全问题请**不要**开公开 issue，见 [SECURITY.md](SECURITY.md)。
