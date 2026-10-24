#!/bin/zsh
# make_app_mac.sh — 把 rtaweb 封装成 macOS .app（PLATFORM.md §13.12）
#
# 用法：tools/make_app_mac.sh [构建目录=build-mac]
# 产物：dist-mac/RLPlayer.app
#
# 形态（§9 第 9 条原生壳版，2026-10-25）：
#   * 主可执行 = rlplayer_mac（NSWindow + WKWebView 原生壳，§10 postMessage 契约）
#   * 服务 = rtaweb 子进程（壳 spawn，--no-browser；界面加载进 WKWebView）
#   * 退出 = 关窗 / Cmd+Q / Dock 右键退出（壳 SIGTERM 服务，优雅收尾）
#   * 图标从 res/rlplayer-256.png 生成 icns
#   * ffmpeg：若 PATH 上有可用 ffmpeg/ffprobe，拷进 bundle（与 exe 同目录，find_tool 先看这里）
#     ⚠️ 本机 Homebrew ffmpeg 8.1.2 链接损坏（libx265.216.dylib 缺失）——脚本会先跑 -version 验证
#   * 未签名/未公证：Gatekeeper 会拦首次双击，右键→打开 放行（无证书可用，如实告知用户）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-$ROOT/build-mac}"
OUT="$ROOT/dist-mac"
APP="$OUT/RLPlayer.app"

[[ -x "$BUILD/rtaweb" && -x "$BUILD/rlplayer_mac" ]] || { echo "!! rtaweb / rlplayer_mac 不存在，先构建"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 1) 主可执行 = 原生壳；服务 = rtaweb（同目录，壳按 bundle 布局 spawn）
cp "$BUILD/rlplayer_mac" "$APP/Contents/MacOS/RLPlayer"
cp "$BUILD/rtaweb"       "$APP/Contents/MacOS/rtaweb"
chmod +x "$APP/Contents/MacOS/RLPlayer" "$APP/Contents/MacOS/rtaweb"

# 2) 数据（OPRA 耳机 EQ 索引；path_in_exe_dir 约定 = exe 同目录）
mkdir -p "$APP/Contents/MacOS/data"
cp "$ROOT/data/opra_index.json" "$APP/Contents/MacOS/data/"

# 3) 图标（256 PNG → 全尺寸 iconset → icns）
ICONSET="$(mktemp -d)/RLPlayer.iconset"
mkdir -p "$ICONSET"
sips -z 16 16     "$ROOT/res/rlplayer-256.png" --out "$ICONSET/icon_16x16.png"     >/dev/null
sips -z 32 32     "$ROOT/res/rlplayer-256.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$ROOT/res/rlplayer-256.png" --out "$ICONSET/icon_32x32.png"     >/dev/null
sips -z 64 64     "$ROOT/res/rlplayer-256.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$ROOT/res/rlplayer-256.png" --out "$ICONSET/icon_128x128.png"   >/dev/null
sips -z 256 256   "$ROOT/res/rlplayer-256.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$ROOT/res/rlplayer-256.png" --out "$ICONSET/icon_256x256.png"   >/dev/null
sips -z 512 512   "$ROOT/res/rlplayer-256.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/RLPlayer.icns"

# 4) Info.plist
VER="$(grep -m1 RLPLAYER_VERSION "$ROOT/src/version.h" 2>/dev/null | sed 's/[^0-9.]*\([0-9.]*\).*/\1/' || true)"
[[ -n "$VER" ]] || VER="1.3.15"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>             <string>RLPlayer</string>
    <key>CFBundleDisplayName</key>      <string>RLPlayer</string>
    <key>CFBundleExecutable</key>       <string>RLPlayer</string>
    <key>CFBundleIdentifier</key>       <string>com.rta.rlplayer</string>
    <key>CFBundleVersion</key>          <string>${VER}</string>
    <key>CFBundleShortVersionString</key> <string>${VER}</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleIconFile</key>         <string>RLPlayer</string>
    <key>LSMinimumSystemVersion</key>   <string>13.0</string>
    <key>NSHighResolutionCapable</key>  <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.music</string>
    <!-- 常规 Dock 应用：图标常驻、右键可退出（SIGTERM 优雅收尾）。界面在默认浏览器。 -->
    <key>LSUIElement</key>              <false/>
    <!-- 界面是 http://127.0.0.1 本地服务：显式放行 loopback（ATS 默认应允许，明确写出防 SDK 行为漂移） -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key> <true/>
    </dict>
    <!-- 输入采集（§13.13）：CoreAudio 输入设备采集需要 TCC 授权 -->
    <key>NSMicrophoneUsageDescription</key>
    <string>RLPlayer 的输入采集功能用于录音与电平监测，仅在您于设置页显式开启时访问麦克风。</string>
</dict>
</plist>
PLIST

# 5) ffmpeg / ffprobe：优先自建精简静态版（tools/build_ffmpeg_lite_mac.sh，无任何外部
#    依赖——Homebrew 版曾因 x265 soname 断裂 dyld 崩溃，退出码 134）；其次 PATH（验证后收）
for tool in ffmpeg ffprobe; do
    if [[ -x "$ROOT/build-mac/ffmpeg-lite/$tool" ]] && "$ROOT/build-mac/ffmpeg-lite/$tool" -version >/dev/null 2>&1; then
        cp "$ROOT/build-mac/ffmpeg-lite/$tool" "$APP/Contents/MacOS/"
        echo "已内置 $tool：自建精简静态版（$(du -h "$ROOT/build-mac/ffmpeg-lite/$tool" | cut -f1)）"
        continue
    fi
    p="$(command -v $tool 2>/dev/null || true)"
    if [[ -n "$p" ]] && "$p" -version >/dev/null 2>&1; then
        cp "$p" "$APP/Contents/MacOS/"
        echo "已内置 $tool：$p（系统版）"
    else
        echo "⚠ $tool 不可用——FLAC/MP3 等非 WAV/DSD 格式无法解码；可运行 tools/build_ffmpeg_lite_mac.sh 自建"
    fi
done

echo "✓ $APP"
echo "  双击运行（首次 Gatekeeper 拦截时：右键 → 打开）"
echo "  独立 App 窗口（WKWebView 内嵌界面）；退出：关窗 / Cmd+Q / Dock 右键"
