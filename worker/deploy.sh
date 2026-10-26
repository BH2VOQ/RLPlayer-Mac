#!/bin/bash
# deploy.sh — 一键部署 RLPlayer 反馈 Worker（需要你的 Cloudflare 账号）
#
# 用法：
#   cd RLPlayer/worker
#   ./deploy.sh
#
# 它会做三件事：
#   ① 检查 wrangler 是否已登录（没登录会让你在浏览器里授权，只需一次）
#   ② 把 GITHUB_TOKEN / SHARED_SALT 写进 Worker Secrets（**只存在 Cloudflare，不进代码**）
#   ③ 部署，并打印最终的 Worker URL
#
# 部署完成后，脚本会提示你把 URL 填进 src/net/ui_script.h 的 FB_WORKER_URL。

set -euo pipefail
cd "$(dirname "$0")"

echo "=== RLPlayer 反馈 Worker 部署 ==="
echo

# ---------- 0. 前置检查 ----------
if ! command -v npx >/dev/null 2>&1; then
  echo "✗ 找不到 npx。请先装 Node.js（https://nodejs.org）"
  exit 1
fi

echo "① 检查 Cloudflare 登录状态…"
if ! npx --yes wrangler@latest whoami 2>/dev/null | grep -qi "account"; then
  echo "   未登录，正在打开浏览器授权（只需一次）…"
  npx --yes wrangler@latest login
else
  echo "   已登录 ✓"
fi
echo

# ---------- 1. GitHub token ----------
echo "② 配置 GitHub token（Worker 用它建 issue）"
echo
echo "   需要一个 **fine-grained** token，权限只勾："
echo "     Repository access → 只选 BH2VOQ/RLPlayer-Feedback"
echo "     Permissions      → Issues: Read and write   （其它全部 None）"
echo
echo "   去这里创建："
echo "   https://github.com/settings/personal-access-tokens/new"
echo
echo "   ⚠️ 绝不要用有 repo 全权限的经典 token —— 这个 token 一旦泄露等于"
echo "      别人能往你仓库写东西。只授权一个仓库 + 只勾 Issues 就够了。"
echo
read -r -p "   粘贴 token 后回车（输入不会显示）: " -s GH_TOKEN
echo
if [ -z "${GH_TOKEN:-}" ]; then
  echo "✗ token 为空，退出"
  exit 1
fi
echo "$GH_TOKEN" | npx --yes wrangler@latest secret put GITHUB_TOKEN
echo

# ---------- 2. 限流盐 ----------
echo "③ 配置限流盐（用于把 IP 哈希成限流键，不落盘真实 IP）"
SALT=$(openssl rand -hex 16 2>/dev/null || echo "rlplayer-$(date +%s)-$RANDOM")
echo "$SALT" | npx --yes wrangler@latest secret put SHARED_SALT
echo "   已写入（随机生成）✓"
echo

# ---------- 3. 部署 ----------
echo "④ 部署…"
npx --yes wrangler@latest deploy 2>&1 | tee /tmp/rlplayer-worker-deploy.log
echo

# ---------- 4. 提取 URL ----------
URL=$(grep -oE 'https://[a-zA-Z0-9._-]+\.workers\.dev' /tmp/rlplayer-worker-deploy.log | head -1 || true)
echo "================================================"
if [ -n "$URL" ]; then
  echo "✓ 部署成功"
  echo
  echo "  Worker URL: $URL"
  echo
  echo "下一步（最后一步）：把这个地址填进"
  echo "  RLPlayer/src/net/ui_script.h"
  echo "里的这一行："
  echo "  var FB_WORKER_URL = '$URL';"
  echo
  echo "然后重新构建 .app 即可。"
else
  echo "⚠️ 部署似乎完成，但没抓到 workers.dev 地址。"
  echo "   请到 Cloudflare 控制台 → Workers & Pages 查看，"
  echo "   或看 /tmp/rlplayer-worker-deploy.log"
fi
echo "================================================"
