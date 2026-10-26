# 安全策略

## 支持版本

只有**最新发布版**接受安全修复。预发布版（`-beta`）同样接受，但会根据严重程度决定是否回移到稳定版。

| 版本 | 是否支持 |
|---|---|
| 1.1.x（含 beta） | ✅ |
| 1.0.x 及更早 | ❌ |

## 私下报告

**请不要在公开 issue 里贴安全细节。**

推荐方式（按优先级）：

1. GitHub 的 [Private vulnerability reporting](https://github.com/BH2VOQ/RLPlayer-Mac/security/advisories/new)
2. 邮件 `BH2VOQ@163.com`，标题前缀 `[SECURITY]`

请包含：受影响版本、复现步骤、影响面（能读到什么 / 能改到什么）、以及你希望的披露时间。

## 已知的设计边界（不是漏洞）

以下行为是**有意的设计取舍**，不用报告：

- 应用内更新只从 GitHub 公开仓库拉清单与安装包，并且强制校验 `sha256` + 文件大小；校验不过一律丢弃。
- 反馈通道走 Cloudflare Worker 转发到 GitHub Issue，客户端**不含任何 token**。
- 本地状态与音乐库都在 `~/Library/Application Support/RLPlayer/`，不向任何第三方上传曲目内容。
- `APP` 为 ad-hoc 签名、未做 Apple 公证；首次打开需要右键「打开」。

## 响应预期

个人项目，尽力在 **7 天内**给出首次回复。修复会随下次版本发布，并在 release notes 里注明。
