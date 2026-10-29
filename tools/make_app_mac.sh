#!/bin/zsh
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
# 完整条款见仓库根目录的 LICENSE 文件。
#
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
# 2026-10-26（出产物修复）：数据放 Contents/Resources/，**不要**放 Contents/MacOS/ ——
# 后者只该放可执行文件，往里塞 json 会让 codesign -v 报 "code object is not signed at all"。
mkdir -p "$APP/Contents/Resources/data"
cp "$ROOT/data/opra_index.json" "$APP/Contents/Resources/data/"

# 2a) 许可证与第三方归属（GPLv3 要求随二进制分发完整条款文本）
#   * LICENSE       = GPL-3.0 全文（仓库根目录，唯一真相源）
#   * OPRA-NOTICE   = 内置 OPRA 耳机 EQ 数据的 CC BY-SA 4.0 归属说明
#   两处缺一，发行包即不合规 ⟹ 这里用致命错误而不是警告。
for doc in LICENSE OPRA-NOTICE.txt; do
    [[ -f "$ROOT/$doc" ]] || { echo "✗ 致命错误：缺少 $doc，无法满足 GPLv3 的分发义务"; exit 1; }
    cp "$ROOT/$doc" "$APP/Contents/Resources/"
done

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

# 3) 图标（256 PNG → 透明画布居中缩放 → 全档 iconset 16…1024 → icns）
#
# 2026-10-28（待办 t-95b74bca：用户反馈「底部 Dock 图标偏大」）：
#   旧做法 `sips -z N N res/rlplayer-256.png` 是**直接缩放原图**，而原图是满幅出血的
#   圆角方块（alpha>200 实体横跨 233/256 = 91.0% 画布宽）；系统 App 同一量法只有
#   206/256 = 80.5%（本机 Music / Calculator / Notes 实测，见 tools/iconcheck.py --apple-ref）。
#   差 27px / 13% ⟹ Dock 里 RLPlayer 的轮廓比邻居大一圈。
#   现在改为：把原图整体缩到 206/233 ≈ 0.884、居中绘制到**透明**画布，再出全档
#   （旧版还漏了 512x512@2x = 1024 档，这次一并补上）。
#   ⚠ 不要用 `sips --padToHeightWidth` 补边：它的补边色没有 alpha 通道，补出来是不透明黑框。
#   ⚠ 不改 res/rlplayer-256.png 本身、不重新设计品牌视觉，只补留白。
#   独立几何验收：tools/iconcheck.py（旧 icns 必须红、新 icns 必须绿）
command -v swift >/dev/null 2>&1 || {
    echo "✗ 致命错误：找不到 swift，无法生成图标（需要 Xcode Command Line Tools）"
    exit 1
}
ICON_TMP="$(mktemp -d)"
ICONSET="$ICON_TMP/RLPlayer.iconset"
swift "$ROOT/tools/make_icon_mac.swift" "$ROOT/res/rlplayer-256.png" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/RLPlayer.icns"
rm -rf "$ICON_TMP"

# 4) Info.plist
# 2026-10-26（测试版支持）：版本号现在可能是 `1.0.5-beta.1` 这种形式。
#   CFBundleShortVersionString 允许预发布后缀，但 CFBundleVersion（build number）
#   **必须是纯数字点号**，带 `-beta` 会被 codesign/系统拒绝。
#   旧正则 `sed 's/[^0-9.]*\([0-9.]*\).*/\1/'` 会把 `1.0.5-beta.1` 截成 `1.0.5`，
#   导致 plist 里**丢失 beta 标识**（用户看到的是稳定版号）。
#   ⟹ 拆成两个：VER 保留完整串给 ShortVersion，VERBUILD 只取数字段给 CFBundleVersion。
# ⚠️ 变量名**绝对不能叫 BUILD** —— 第 19 行的 BUILD 是**构建目录**（默认 $ROOT/build-mac）。
#   我第一版就叫 BUILD，结果把构建目录覆盖成 "1.0.5"，脚本随后去
#   `1.0.5/ffmpeg-lite/ffmpeg` 找 ffmpeg ⟹ 报「未找到 1.0.5/ffmpeg-lite/ffmpeg」。
#   教训：这个脚本里 BUILD 是保留名，新增变量一律加前缀（VERxxx）。
RAWVER="$(grep -m1 RLPLAYER_VERSION "$ROOT/src/version.h" 2>/dev/null | sed 's/.*"\(.*\)".*/\1/' || true)"
[[ -n "$RAWVER" ]] || RAWVER="1.0.1"
VER="$RAWVER"                                                          # 完整版号（可含 -beta.N）
VERBUILD="$(printf '%s' "$RAWVER" | sed 's/[^0-9.].*$//; s/\.$//')"    # 纯数字点号段
[[ -n "$VERBUILD" ]] || VERBUILD="1.0.1"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>             <string>RLPlayer</string>
    <key>CFBundleDisplayName</key>      <string>RLPlayer</string>
    <key>CFBundleExecutable</key>       <string>RLPlayer</string>
    <key>CFBundleIdentifier</key>       <string>com.rta.rlplayer</string>
    <key>CFBundleVersion</key>          <string>${VERBUILD}</string>
    <key>CFBundleShortVersionString</key> <string>${VER}</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleIconFile</key>         <string>RLPlayer</string>
    <!-- GPLv3：二进制分发必须可查到版权与许可（Finder 简介面板 / 关于本机都会显示） -->
    <key>NSHumanReadableCopyright</key>
    <string>Copyright (C) 2026 August Hu. Licensed under GNU GPL v3 or later.</string>
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
    <!-- 2026-10-28（用户「UPnP 搜不到设备」）：
         macOS 15+ 的「本地网络」隐私开关按 App 授权。**没有这个键，系统不会弹授权框，
         直接把 LAN 访问判成拒绝**（实测：ad-hoc 的 CLI 二进制向 192.168.3.x 的 connect 与
         SSDP 组播 sendto 都是 EHOSTUNREACH，而系统 curl 同一个地址 200；系统日志
         UserEventAgent/nehelper 明确记录 "LocalNetwork: found bundle id …"）。
         有它才会弹「RLPlayer 想要查找并连接本地网络上的设备」，用户点允许后 UPnP 发现才可用。 -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>RLPlayer 需要访问局域网来发现并投放音乐到 UPnP/DLNA 渲染器（设备搜索、读取设备描述、发送播放控制）。若不允许，将无法搜索与投放局域网设备。</string>
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

# Offline diagnosis is part of the self-contained diagnostic deliverable.
[[ -x "$BUILD/rtadiag" ]] || { echo "✗ 缺少 rtadiag，请先构建离线诊断工具"; exit 1; }
cp "$BUILD/rtadiag" "$APP/Contents/MacOS/rtadiag"
chmod +x "$APP/Contents/MacOS/rtadiag"

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
for bin in "$APP/Contents/MacOS/RLPlayer" "$APP/Contents/MacOS/ffmpeg" "$APP/Contents/MacOS/ffprobe" "$APP/Contents/MacOS/rtadiag"; do
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

# 7) 部署目标一致性校验：plist 声明的 LSMinimumSystemVersion 必须与【包内每一个二进制】的 minos 严格一致
#    2026-10-27 审计抓到真缺陷：旧门禁只查 RLPlayer 自己 ⟹ ffmpeg/ffprobe/librtagpu
#    全是 minos=27.0（编译机默认值）也照样绿灯。macOS 13~26 上 ffmpeg 子进程会被
#    dyld 直接拒绝 ⟹ 非 WAV/DSF/DFF 全部解不了码。现在四件套逐个查。
if command -v otool >/dev/null 2>&1; then
    PLIST_MINOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist" 2>/dev/null)"
    if [[ -z "$PLIST_MINOS" ]]; then
        echo "✗ 致命错误：无法读取 Info.plist 的 LSMinimumSystemVersion"
        exit 1
    fi
    MINOS_FAIL=0
    for bin in RLPlayer ffmpeg ffprobe librtagpu.dylib rtadiag; do
        BIN_MINOS="$(otool -l "$APP/Contents/MacOS/$bin" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f && /minos/{print $2; exit}')"
        if [[ -z "$BIN_MINOS" ]]; then
            echo "✗ 致命错误：无法读取 $bin 的 LC_BUILD_VERSION minos"
            exit 1
        fi
        if [[ "$BIN_MINOS" != "$PLIST_MINOS" ]]; then
            echo "✗ 致命错误：部署目标不一致：$bin minos=${BIN_MINOS}，Info.plist LSMinimumSystemVersion=$PLIST_MINOS"
            echo "  $bin 需要：重新执行 tools/build_ffmpeg_lite_mac.sh / tools/build_gpu_metal_mac.sh"
            echo "  （脚本已加 -mmacosx-version-min=13.0；旧产物是编译机系统版本，别再打进包里）"
            MINOS_FAIL=1
        fi
    done
    [[ "$MINOS_FAIL" == "1" ]] && exit 1
    echo "✓ 部署目标门禁通过：四件套 minos=$PLIST_MINOS / plist=$PLIST_MINOS"
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
