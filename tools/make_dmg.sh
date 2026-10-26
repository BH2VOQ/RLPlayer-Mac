#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 August Hu <BH2VOQ@163.com>
#
# 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
# 完整条款见仓库根目录的 LICENSE 文件。
#
# make_dmg.sh — 生成「拖拽安装」样式的 DMG
#
# 用法：
#   tools/make_dmg.sh [构建目录=build-mac] [版本号]
#
# 产出：
#   dist-mac/RLPlayer-<版本>-macOS-arm64.dmg
#
# ============================ 为什么用 dmgbuild ============================
# 前面用 AppleScript / create-dmg 折腾了十几轮，背景图始终不生效。查资料后才明白两件事：
#
#   ① **Finder 直到卷被卸载时才把图标视图配置 flush 到 .DS_Store**。
#      挂载状态下读取永远是 6148 字节的空壳 ⟹ 看起来像"没生效"，
#      实际只是没 flush。（参见 https://github.com/vinzdg/codenotch/issues/386）
#
#   ② 更要紧的是：AppleScript 方案依赖 GUI 会话、依赖 Finder 的卷索引、
#      依赖 macOS 版本行为（-1728 / -10006 / -1700 全是这类）。
#      在 CI / 无 GUI 环境根本跑不了。
#
#   所以改用 **dmgbuild**（https://github.com/dmgbuild/dmgbuild）：
#   它直接按规范生成 .DS_Store 二进制（bwsp / icvp / Iloc 全字段），
#   **不需要 Finder、不需要 GUI、不依赖时序**，结果确定可复现。
#
# 前置：pip install dmgbuild

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

BUILD="${1:-build-mac}"
APP="$ROOT/dist-mac/RLPlayer.app"
DMG_DIR="$ROOT/dist-mac"
BG="$ROOT/tools/dmg/background.tiff"

# ---------- 版本 ----------
if [ -n "${2:-}" ]; then
  VER="$2"
else
  VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"
fi
DMG="$DMG_DIR/RLPlayer-${VER}-macOS-arm64.dmg"

# ---------- 前置检查 ----------
[ -d "$APP" ] || { echo "✗ 找不到 $APP（先跑 tools/make_app_mac.sh）"; exit 1; }
[ -f "$BG" ]  || { echo "✗ 找不到背景图 $BG"; exit 1; }
command -v dmgbuild >/dev/null || {
  echo "✗ 需要 dmgbuild：pip install dmgbuild"
  exit 1
}

echo "=== 制作 DMG：RLPlayer $VER ==="

# ---------- 清理残留挂载 ----------
for v in /Volumes/RLPlayer*; do
  [ -d "$v" ] && hdiutil detach "$v" -quiet 2>/dev/null || true
done

# ---------- 写 dmgbuild 配置 ----------
SETTINGS="$(mktemp /tmp/rlplayer-dmgsettings.XXXXXX.py)"
trap 'rm -f "$SETTINGS"' EXIT

cat > "$SETTINGS" <<'PYEOF'
# dmgbuild 配置（由 tools/make_dmg.sh 生成；app / bg 通过 -D 传入）
import os.path

app_path = defines.get('app')
bg_path  = defines.get('bg')

# ⚠️ 必须显式列 files —— dmgbuild 不会自动把任何东西放进去。
#   第一版漏了这段，生成的 dmg 只有 .DS_Store 和背景图，30KB（没有 .app）。
files = [app_path]

# Applications 软链（拖拽目标）
symlinks = {'Applications': '/Applications'}

# 窗口尺寸（点）。背景图 1128x684 px 是 2x ⟹ 显示为 564x342 pt
# 窗口高度多给一点（370），避免标题栏遮住背景图底部
window_rect = ((400, 300), (660, 420))

icon_size = 110
text_size = 12

background      = bg_path
show_status_bar = False
show_tab_view   = False
show_toolbar    = False
show_pathbar    = False
show_sidebar    = False

# 图标位置（点，相对窗口内容区左上角）
icon_locations = {
    'RLPlayer.app': (200, 232),
    'Applications': (460, 232),
}

default_view = 'icon-view'
PYEOF

# ---------- 构建 ----------
rm -f "$DMG"
echo "① 生成镜像（dmgbuild）…"
dmgbuild \
  -s "$SETTINGS" \
  -D "app=$APP" \
  -D "bg=$BG" \
  "RLPlayer" \
  "$DMG" 2>&1 | tail -10

[ -f "$DMG" ] || { echo "✗ DMG 未生成"; exit 1; }

# ---------- 校验 ----------
echo "② 校验…"
hdiutil verify "$DMG" >/dev/null && echo "   镜像校验通过 ✓"

# 关键验证：.DS_Store 必须同时含 bwsp（窗口）/ icvp（视图）/ Iloc（图标位置）
# 以及 backgroundImageAlias（背景图）。缺任一项都说明样式没写进去。
MNT="$(mktemp -d /tmp/rlplayer-verify.XXXXXX)"
hdiutil attach "$DMG" -readonly -noverify -nobrowse -mountpoint "$MNT" >/dev/null 2>&1
DS="$MNT/.DS_Store"
if [ ! -f "$DS" ]; then
  echo "   ✗ .DS_Store 缺失"
else
  echo "   .DS_Store: $(stat -f%z "$DS") 字节"
  for key in bwsp icvp Iloc backgroundImageAlias; do
    if LC_ALL=C strings -a "$DS" | grep -q "$key"; then
      echo "     ✓ $key"
    else
      echo "     ✗ $key 缺失"
    fi
  done
fi
hdiutil detach "$MNT" -quiet 2>/dev/null || true
rmdir "$MNT" 2>/dev/null || true

SIZE_BYTES=$(stat -f%z "$DMG")
SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
echo
echo "================================================"
echo "✓ $DMG"
echo "  sha256  $SHA"
echo "  size    $SIZE_BYTES"
echo "================================================"
