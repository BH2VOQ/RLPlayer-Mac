#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 August Hu <BH2VOQ@163.com>
#
# 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
# 完整条款见仓库根目录的 LICENSE 文件。
#
# build_gpu_metal_mac.sh — 构建 macOS Metal 版 GPU 加速后端 librtagpu.dylib
#
# 用法：
#   bash tools/build_gpu_metal_mac.sh              # 构建到仓库根
#   bash tools/build_gpu_metal_mac.sh -o DIR       # 构建到指定目录
#
# 为什么不需要离线 metal 工具链：
#   本机 xcrun -f metal 找不到工具，所以 src/gpu/gpu_metal.mm 把 MSL 源码作为
#   C 字符串内嵌，运行时用 [device newLibraryWithSource:options:error:] 现场编译。
#   本脚本因此只需要 clang++（Command Line Tools 自带），不需要 Xcode 的 metal 命令。
#
# 产物只依赖系统框架（Metal + Foundation），不依赖 libc++ 之外的任何第三方库。
# 脚本会打印 otool -L 自证这一点。
#
# 幂等：重复运行覆盖旧产物。失败退出码非 0（不留下"看起来成功"的半成品）。
set -euo pipefail

# ---- 定位仓库根（脚本可能在 tools/ 下，也可能被从任意 cwd 调用）----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUT_DIR="$REPO_ROOT"
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--out) OUT_DIR="${2:?--out 需要一个目录参数}"; shift 2 ;;
        -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

SRC="$REPO_ROOT/src/gpu/gpu_metal.mm"
OUT="$OUT_DIR/librtagpu.dylib"

if [ ! -f "$SRC" ]; then
    echo "❌ 找不到源文件: $SRC" >&2
    exit 1
fi
mkdir -p "$OUT_DIR"

# 只支持 arm64（项目已放弃 x86_64：见工作区记忆 single-process-merge-plan.md）
if [ "$(uname -m)" != "arm64" ]; then
    echo "❌ 本脚本只支持 arm64（当前 uname -m = $(uname -m)）" >&2
    exit 1
fi

echo "== 构建 librtagpu.dylib =="
echo "  源文件 : $SRC"
echo "  产物   : $OUT"
echo "  编译器 : $(clang++ --version | head -1)"

# -fobjc-arc        : ObjC 引用计数，MTLBuffer 由 ARC 管理，避免手写 release 漏掉
# -dynamiclib       : 产出 .dylib
# -arch arm64       : 单架构
# -install_name     : @rpath 形式，方便 .app 包内定位
# -I src            : 为了 #include "dsp/fft.h"（复用项目 double 精度 FFT）
# -Wl,-dead_strip   : 去掉未引用符号，让 nm -gU 的清单就是真实导出的 4 个
clang++ -std=c++23 -O2 -fobjc-arc -dynamiclib -arch arm64 -mmacosx-version-min=13.0 \
    -I "$REPO_ROOT/src" \
    -framework Metal -framework Foundation \
    -install_name @rpath/librtagpu.dylib \
    -Wl,-dead_strip \
    -o "$OUT" "$SRC"

if [ ! -f "$OUT" ]; then
    echo "❌ 构建后没有产物: $OUT" >&2
    exit 1
fi

echo
echo "== 产物 =="
ls -l "$OUT"
echo
echo "== 依赖（应只有系统框架）=="
otool -L "$OUT"
echo
echo "== 导出符号（必须包含全部 4 个 rta_gpu_* ）=="
nm -gU "$OUT" | grep rta_gpu || { echo "❌ 没有找到 rta_gpu_* 导出符号" >&2; exit 1; }

# 硬校验：4 个符号一个都不能少。改名字不会报错，只会让桥接层静默退回 CPU
# （历史上 test_gpu_bridge 就是为这个坑写的）。
echo
MISSING=0
for sym in rta_gpu_available rta_gpu_convolve rta_gpu_resample rta_gpu_resample_invalidate; do
    if nm -gU "$OUT" | grep -qw "_$sym"; then
        echo "  ✅ $sym"
    else
        echo "  ❌ 缺少符号: $sym" >&2
        MISSING=1
    fi
done
if [ "$MISSING" -ne 0 ]; then
    echo "❌ 导出符号不全，桥接层会静默退回 CPU" >&2
    exit 1
fi

echo
echo "✅ 构建完成: $OUT"
