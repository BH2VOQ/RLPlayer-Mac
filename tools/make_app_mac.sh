#!/bin/zsh
# make_app_mac.sh — 把 RLPlayer 封装成 macOS .app（单进程 arm64 原生整合）
#
# 用法：tools/make_app_mac.sh [构建目录=build-mac]
# 产物：dist-mac/RLPlayer.app
#
# 形态（单进程架构）：
#   * 主可执行 = rlplayer_mac（NSWindow + WKWebView 原生壳，嵌入核心业务逻辑）
#   * 不再启动或复制独立 rtaweb 服务进程（无端口占用、无独立后台服务）
#   * 退出 = 关窗 / Cmd+Q / Dock 右键退出
#   * 图标从 res/rlplayer-256.png 生成 icns
#   * ffmpeg/ffprobe：必须内置可用且为 arm64 架构的精简静态版，禁止缺失或回退破坏自包含
#   * 严格架构门禁：检查包内可执行文件（RLPlayer, ffmpeg, ffprobe）均为纯 arm64，
#     严禁出现 x86_64、Universal 胖二进制、或者 rtaweb 残留
#   * 严格部署目标一致性：检查 minos=13.0，不匹配直接失败
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-$ROOT/build-mac}"
OUT="$ROOT/dist-mac"
APP="$OUT/RLPlayer.app"

[[ -x "$BUILD/rlplayer_mac" ]] || { echo "!! rlplayer_mac 不存在，请先在 $BUILD 构建"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 1) 主可执行 = 原生单进程 App
cp "$BUILD/rlplayer_mac" "$APP/Contents/MacOS/RLPlayer"
chmod +x "$APP/Contents/MacOS/RLPlayer"

# 2) 数据（OPRA 耳机 EQ 索引；path_in_exe_dir 约定 = exe 同目录）
mkdir -p "$APP/Contents/MacOS/data"
cp "$ROOT/data/opra_index.json" "$APP/Contents/MacOS/data/"

# 2b) Metal GPU 后端（librtagpu.dylib）
#
# 2026-10-25（用户报「显示后端库未就位」）：这个库以前**从来没被打进 .app**。
# 后果：设置里 GPU 下拉永远显示「后端库未就位」，Metal 加速实际不可用 ——
# 而 src/dsp/gpu_pref.h 的搜索路径正是 @executable_path/librtagpu.dylib。
#
# 它由 tools/build_gpu_metal_mac.sh 生成（gitignore 掉了，属于构建产物），
# 所以这里做「有就打包、没有就明确警告」而不是静默跳过：
#   有库 → 复制到 Contents/MacOS/ 并校验 arm64
#   无库 → 打印 ⚠ 说明 GPU 加速不可用、怎么构建；**不中断打包**
#          （GPU 是可选加速，缺它 CPU 卷积照常工作，不该因此出不了包）
GPU_LIB=""
for cand in "$BUILD/librtagpu.dylib" "$ROOT/librtagpu.dylib"; do
    if [[ -f "$cand" ]]; then GPU_LIB="$cand"; break; fi
done
if [[ -n "$GPU_LIB" ]]; then
    cp "$GPU_LIB" "$APP/Contents/MacOS/librtagpu.dylib"
    chmod +x "$APP/Contents/MacOS/librtagpu.dylib"
    # 架构校验：必须含 arm64（发布版只留 arm64，见工作区记忆 single-process-merge-plan.md）
    if ! lipo -archs "$APP/Contents/MacOS/librtagpu.dylib" 2>/dev/null | grep -q arm64; then
        echo "⚠ librtagpu.dylib 不含 arm64 架构，GPU 加速可能不可用"
    else
        echo "✓ 已打包 Metal GPU 后端：librtagpu.dylib"
    fi
else
    echo "⚠ 未找到 librtagpu.dylib（GPU 加速不可用，CPU 卷积照常）"
    echo "  构建方法：bash tools/build_gpu_metal_mac.sh"
    echo "  搜索过：$BUILD/librtagpu.dylib 和 $ROOT/librtagpu.dylib"
fi

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
rm -rf "$ICONSET"

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
    <!-- 2026-10-25：必须与 CMakeLists.txt 的 CMAKE_OSX_DEPLOYMENT_TARGET 保持一致。 -->
    <key>LSMinimumSystemVersion</key>   <string>13.0</string>
    <key>NSHighResolutionCapable</key>  <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.music</string>
    <!-- 常规 Dock 应用：图标常驻、右键可退出。 -->
    <key>LSUIElement</key>              <false/>
    <!-- 单进程模式：本地网络用于局域网投送 / UPnP 等；保留网络能力 -->
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

# 5) ffmpeg / ffprobe：铁律正式发布版必须自包含，禁止跳过或回退系统坏库
for tool in ffmpeg ffprobe; do
    src_tool="$BUILD/ffmpeg-lite/$tool"
    if [[ ! -x "$src_tool" ]]; then
        echo "✗ 致命错误：未找到 ${src_tool}。请先执行 tools/build_ffmpeg_lite_mac.sh 构建 arm64 精简静态版"
        exit 1
    fi
    if ! "$src_tool" -version >/dev/null 2>&1; then
        echo "✗ 致命错误：$src_tool 执行失败（无法执行或动态库损坏）"
        exit 1
    fi
    # 架构硬门禁：源文件必须是纯 arm64
    tool_arch="$(lipo -archs "$src_tool" 2>/dev/null || true)"
    if [[ "$tool_arch" != "arm64" ]]; then
        echo "✗ 致命错误：$src_tool 架构为 '$tool_arch'，必须为纯 arm64！"
        exit 1
    fi
    cp "$src_tool" "$APP/Contents/MacOS/$tool"
    chmod +x "$APP/Contents/MacOS/$tool"
    echo "✓ 已内置 ${tool}：自建 arm64 精简静态版（$(du -h "$src_tool" | cut -f1)）"
done

# 6) 单进程与纯 arm64 门禁校验
# 6a) 严禁 rtaweb 或 x86 产物进入 App
if [[ -e "$APP/Contents/MacOS/rtaweb" ]]; then
    echo "✗ 致命错误：检测到 $APP/Contents/MacOS/rtaweb！单进程合并要求不再打包独立 rtaweb 进程。"
    exit 1
fi
# 用 find 而不是裸通配符：zsh 在无匹配时会对 *.ext 报 "no matches found" 并使条件
# 走在错误路径上，门禁就变成随 shell 选项碰运气。find 无匹配时返回 0 且不输出。
if find "$APP/Contents/MacOS" -maxdepth 1 -name '*-x86_64' -print -quit | grep -q .; then
    echo "✗ 致命错误：包内存在 *-x86_64 文件！RLPlayer 仅支持 arm64。"
    exit 1
fi

# 6b) 架构硬校验：所有 Contents/MacOS 下的 Mach-O 可执行文件必须严格纯 arm64
for bin in "$APP/Contents/MacOS/RLPlayer" "$APP/Contents/MacOS/ffmpeg" "$APP/Contents/MacOS/ffprobe"; do
    if [[ ! -f "$bin" ]]; then
        echo "✗ 致命错误：缺少核心二进制 $bin"
        exit 1
    fi
    archs="$(lipo -archs "$bin" 2>/dev/null || true)"
    if [[ "$archs" != "arm64" ]]; then
        echo "✗ 致命架构错误：$bin 架构为 '$archs'，不符合纯 arm64 铁律！"
        exit 1
    fi
done
echo "✓ 架构门禁通过：所有二进制均为纯 arm64"

# 7) 部署目标一致性校验：plist 声明的 LSMinimumSystemVersion 必须与二进制 minos 严格一致
if command -v otool >/dev/null 2>&1; then
    BIN_MINOS="$(otool -l "$APP/Contents/MacOS/RLPlayer" 2>/dev/null | grep -m1 -A4 LC_BUILD_VERSION | grep -m1 minos | awk '{print $2}')"
    PLIST_MINOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist" 2>/dev/null)"
    if [[ -z "$BIN_MINOS" || -z "$PLIST_MINOS" ]]; then
        echo "✗ 致命错误：无法读取 RLPlayer 的 LC_BUILD_VERSION minos 或 Info.plist 的 LSMinimumSystemVersion"
        exit 1
    fi
    if [[ "$BIN_MINOS" != "$PLIST_MINOS" ]]; then
        echo "✗ 致命错误：部署目标不一致：二进制 minos=${BIN_MINOS}，Info.plist LSMinimumSystemVersion=$PLIST_MINOS"
        echo "  请检查 CMakeLists.txt 是否已设置 CMAKE_OSX_DEPLOYMENT_TARGET=13.0 并重新配置构建目录。"
        exit 1
    fi
    echo "✓ 部署目标门禁通过：minos=$BIN_MINOS / plist=$PLIST_MINOS"
fi

# 8) adhoc 签名
if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP" 2>/dev/null \
        && echo "✓ 已 adhoc 签名（codesign -s -）" \
        || { echo "✗ codesign 失败"; exit 1; }
    codesign --verify --verbose=1 "$APP" 2>&1 | tail -1
else
    echo "✗ 找不到 codesign（系统必须提供 codesign 工具）"
    exit 1
fi

echo "✓ 打包完成: $APP"
echo "  单进程 arm64 原生应用已生成"
