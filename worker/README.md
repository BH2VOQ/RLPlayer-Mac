# 反馈 Worker 部署（最后一步，需要你的 Cloudflare 账号）

> **当前状态（2026-10-26）**：代码、测试、GitHub 仓库全部就绪；
> **Worker 尚未部署** ⟹ 客户端 `FB_WORKER_URL` 为空 ⟹ 点「发送反馈」会如实显示
> 「反馈通道未配置（开发者尚未部署 Worker 地址）」。
> 这不是 bug，是**故意不假装成功**（铁律 3）。

---

## 已经替你做完的

| 项 | 状态 |
|---|---|
| Worker 代码 `feedback-worker.js` | ✅ 245 行，`wrangler deploy --dry-run` 通过（7.50 KiB / gzip 2.55 KiB） |
| 离线测试 `test_worker.mjs` | ✅ **30 条断言全绿**（含限流、注入中和、token 不外泄） |
| 部署配置 `wrangler.toml` | ✅ 已指向 `BH2VOQ/RLPlayer-Feedback` |
| 一键部署脚本 `deploy.sh` | ✅ 语法校验通过 |
| 接收反馈的 GitHub 仓库 | ✅ **已创建** `BH2VOQ/RLPlayer-Feedback`（**私有**） |
| 客户端页面接线 | ✅ 已接完并实测（真发请求、真收工单号） |

## 你需要做的（约 5 分钟）

### 1. 建一个 fine-grained token

https://github.com/settings/personal-access-tokens/new

- **Repository access** → Only select repositories → 只勾 `BH2VOQ/RLPlayer-Feedback`
- **Permissions** → `Issues: Read and write`（其余全部保持 None）
- 有效期按需（建议 1 年，到期换一个）

> ⚠️ **绝不要**用有 repo 全权限的经典 token。这个 token 泄露 = 别人能往你仓库写东西。
> 只授权一个仓库 + 只勾 Issues，泄露面就只剩"往这个私有仓库塞垃圾 issue"。

### 2. 跑部署脚本

```bash
cd /Users/august/Downloads/DQ/RLPlayer/worker
./deploy.sh
```

脚本会：
1. 检查/打开 Cloudflare 登录（浏览器授权一次）
2. 让你粘贴上面那个 token → 写进 Worker Secrets（**只存在 Cloudflare，不进代码、不进 git**）
3. 自动生成随机限流盐并写入
4. 部署，并打印 `https://xxx.workers.dev`

### 3. 把 URL 填进代码（一行）

`src/net/ui_script.h`：

```js
var FB_WORKER_URL = '';                    // ← 改成你的 URL
```

然后重新构建 `.app`。我也可以帮你改 + 重建 + 重传，部署完把 URL 给我就行。

---

## 部署后怎么验证（我会做）

| 判据 | 期望 |
|---|---|
| 空正文点发送 | 拦住，提示「请先写下反馈内容」 |
| 有正文点发送 | 显示「已发送，工单号 FB-...」 |
| 你的 GitHub | `RLPlayer-Feedback` 仓库里出现对应 issue |
| 带诊断包 | issue 里出现「诊断包已附带」或「未配置 R2」的如实说明 |

---

## 架构与安全（供你自己复核）

```
用户点「发送反馈」
   ↓ POST JSON（正文 + 可选诊断包 base64）
Cloudflare Worker（公开 URL，客户端无任何凭据）
   ↓ Bearer token（只在 Worker Secrets 里）
GitHub Issue（BH2VOQ/RLPlayer-Feedback，私有）
```

**为什么这样能抗 DDoS**（你明确担心的点）：
- Cloudflare 边缘吸收 L3-L7 洪水，Worker 没有可直连的源站 IP
- 只接受 POST + `application/json`，其它一律 405/415（当不了开放代理）
- 正文上限 16KB、诊断包上限 8MB，超限直接 413，不进内存
- 同 IP 每分钟最多 5 条（Cache API 计数，**不落盘真实 IP**，只存盐化哈希）
- 免费额度：10 万请求/天，个人反馈场景绰绰有余

**客户端为什么零凭据**：`strings RLPlayer.app/Contents/MacOS/RLPlayer | grep token` 找不到任何东西 ——
token 从来没离开过 Cloudflare。Worker URL 本身是公开的，被反编译也无所谓。

---

## ⚠️ 一个待定项：诊断包存储

诊断包通常几 MB，**塞不进 issue body**（GitHub 上限 64KB）。
默认实现（未配 R2）会在 issue 里留一条评论**如实说明「附件未保存」**，不会静默丢弃。

要真正存下附件，需开通 R2（免费额度 10GB）：

```toml
# wrangler.toml 里取消注释
[[r2_buckets]]
binding = "R2"
bucket_name = "rlplayer-feedback"
```
```toml
[vars]
R2_BUCKET_NAME = "rlplayer-feedback"
```

**这个要不要做，你定**：不做的话用户反馈照样能收到（正文 + 环境信息完整），
只是没有日志附件；做了的话排查问题会方便很多。
