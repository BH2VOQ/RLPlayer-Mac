#!/bin/bash
# deploy.sh — 一键部署 RLPlayer 反馈 Worker
#
# ============================ 两种认证方式，任选其一 ============================
#
# 【方式 A · 推荐 · 不需要浏览器】
#   建一个 Cloudflare API Token（权限：Workers Scripts:Edit + R2:Edit），然后：
#       export CLOUDFLARE_API_TOKEN='你的token'
#       export CLOUDFLARE_ACCOUNT_ID='你的account id'
#       ./deploy.sh
#   Account ID 在 Cloudflare 控制台右侧栏，或 `npx wrangler whoami` 里能看到。
#
# 【方式 B · 浏览器授权】
#       npx wrangler login        # 必须先在**你自己的终端**里单独跑这一条
#       ./deploy.sh
#
#   ⚠️ 脚本不能替你跑 login —— 它要读你粘贴的 GitHub token，会把 stdin 变成管道，
#      wrangler 检测到「非交互环境」就直接拒绝登录。
#      （这是第一版脚本的真实事故：用户只看到 "non-interactive environment" 报错。）
#
# ============================ GITHUB_TOKEN 怎么传 ============================
#   支持环境变量 RLPLAYER_GH_TOKEN 直接给（适合自动化），
#   或者交互式粘贴（read -s，不显示、不进 shell 历史）。

set -euo pipefail
cd "$(dirname "$0")"

echo "=== RLPlayer 反馈 Worker 部署 ==="
echo

# ---------- 0. 前置检查 ----------
if ! command -v npx >/dev/null 2>&1; then
  echo "✗ 找不到 npx。请先装 Node.js（https://nodejs.org）"
  exit 1
fi

# ---------- 1. 认证状态 ----------
echo "① 检查 Cloudflare 认证…"
AUTH_OK=0
if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
  echo "   检测到 CLOUDFLARE_API_TOKEN ✓"
  if [ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
    echo
    echo "   ⚠️ 还缺 CLOUDFLARE_ACCOUNT_ID（控制台右侧栏可复制）："
    echo "      export CLOUDFLARE_ACCOUNT_ID='你的account id'"
    exit 1
  fi
  echo "   检测到 CLOUDFLARE_ACCOUNT_ID ✓"
  AUTH_OK=1
else
  # ⚠️ 判断条件不能只看 whoami 里有没有 "account" —— 未登录时它也会打印
  #    "To deploy without logging in, ... temporary preview account"，那个 account 是假阳性。
  #    必须显式排除 "not authenticated"，并且要求真的出现账号邮箱/ID。
  WHO=$(npx --yes wrangler@latest whoami 2>&1 || true)
  if echo "$WHO" | grep -qi "not authenticated"; then
    AUTH_OK=0
  elif echo "$WHO" | grep -qE "Associated Accounts|Account ID|[a-z0-9._%+-]+@[a-z0-9.-]+"; then
    echo "   已通过 wrangler login 登录 ✓"
    AUTH_OK=1
  fi
fi

if [ "$AUTH_OK" -eq 0 ]; then
  cat <<'EOF'
   ✗ 尚未认证。两种方式任选其一：

   【方式 A · 推荐，不需要浏览器】
     1. 建 API Token：https://dash.cloudflare.com/profile/api-tokens
        「Create Token」→ 自定义，权限给：
          Account → Workers Scripts → Edit
          Account → R2 → Edit（要存诊断包才需要）
     2. 然后：
          export CLOUDFLARE_API_TOKEN='粘贴token'
          export CLOUDFLARE_ACCOUNT_ID='你的account id'
          ./deploy.sh

   【方式 B · 浏览器授权】
     先单独跑：  npx wrangler login
     跑完再：    ./deploy.sh
EOF
  exit 1
fi
echo

# ---------- 2. GitHub token ----------
echo "② 配置 GitHub token（Worker 用它建 issue）"
if [ -n "${RLPLAYER_GH_TOKEN:-}" ]; then
  echo "   检测到 RLPLAYER_GH_TOKEN 环境变量 ✓"
  GH_TOKEN="$RLPLAYER_GH_TOKEN"
else
  echo
  echo "   fine-grained token，权限只勾："
  echo "     Repository access → 只选 BH2VOQ/RLPlayer-Feedback"
  echo "     Permissions      → Issues: Read and write （其它全部 None）"
  echo
  echo "   创建地址：https://github.com/settings/personal-access-tokens/new"
  echo
  echo "   ⚠️ 绝不要用有 repo 全权限的经典 token。"
  echo
  read -r -p "   粘贴 token 后回车（不会显示）: " -s GH_TOKEN
  echo
fi
if [ -z "${GH_TOKEN:-}" ]; then
  echo "✗ token 为空，退出"
  exit 1
fi

# 认证已在第 ① 步解决，所以这里 stdin 走管道不会触发"非交互环境"拒绝
printf '%s' "$GH_TOKEN" | npx --yes wrangler@latest secret put GITHUB_TOKEN
echo "   已写入 Worker Secrets ✓"
echo

# ---------- 3. 限流盐 ----------
echo "③ 配置限流盐（把 IP 哈希成限流键，不落盘真实 IP）"
SALT=$(openssl rand -hex 16 2>/dev/null || echo "rlplayer-$(date +%s)-$RANDOM")
printf '%s' "$SALT" | npx --yes wrangler@latest secret put SHARED_SALT
echo "   已写入（随机生成）✓"
echo

# ---------- 4. R2 桶（存诊断包，免费 10GB） ----------
echo "④ 创建 R2 桶（存诊断包）"
if npx --yes wrangler@latest r2 bucket create rlplayer-feedback > /tmp/rlplayer-r2.log 2>&1 \
   || grep -qiE "already|exists" /tmp/rlplayer-r2.log; then
  echo "   桶 rlplayer-feedback 就绪 ✓"
  if ! grep -q 'binding = "R2"' wrangler.toml; then
    cat >> wrangler.toml <<'TOML'

# 诊断包存储（由 deploy.sh 自动追加）
[[r2_buckets]]
binding = "R2"
bucket_name = "rlplayer-feedback"
TOML
    if ! grep -q 'R2_BUCKET_NAME' wrangler.toml; then
      sed -i '' 's|^REPO_NAME  = "RLPlayer-Feedback"|REPO_NAME  = "RLPlayer-Feedback"\nR2_BUCKET_NAME = "rlplayer-feedback"|' wrangler.toml 2>/dev/null \
        || sed -i 's|^REPO_NAME  = "RLPlayer-Feedback"|REPO_NAME  = "RLPlayer-Feedback"\nR2_BUCKET_NAME = "rlplayer-feedback"|' wrangler.toml
    fi
    echo "   已把 R2 binding 写入 wrangler.toml ✓"
  else
    echo "   R2 binding 已存在，跳过 ✓"
  fi
else
  echo "   ⚠️ R2 桶创建失败（可能没开通 R2，或 token 缺 R2:Edit）"
  echo "      不影响部署：诊断包会在 issue 里如实标注「附件未保存」。"
  echo "      日志：/tmp/rlplayer-r2.log"
fi
echo

# ---------- 5. 部署 ----------
echo "⑤ 部署…"
npx --yes wrangler@latest deploy 2>&1 | tee /tmp/rlplayer-worker-deploy.log
echo

# ---------- 6. 提取 URL ----------
URL=$(grep -oE 'https://[a-zA-Z0-9._-]+\.workers\.dev' /tmp/rlplayer-worker-deploy.log | head -1 || true)
echo "================================================"
if [ -n "$URL" ]; then
  echo "✓ 部署成功"
  echo
  echo "  Worker URL: $URL"
  echo
  echo "最后一步：把这个地址填进"
  echo "  RLPlayer/src/net/ui_script.h"
  echo "的："
  echo "  var FB_WORKER_URL = '$URL';"
  echo
  echo "（把 URL 发给我，我来改代码 + 重建 .app + 重传 GitHub）"
else
  echo "⚠️ 部署似乎完成，但没抓到 workers.dev 地址。"
  echo "   请到 Cloudflare 控制台 → Workers & Pages 查看，"
  echo "   或看 /tmp/rlplayer-worker-deploy.log"
fi
echo "================================================"
