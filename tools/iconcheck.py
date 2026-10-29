#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
# 完整条款见仓库根目录的 LICENSE 文件。
#
# iconcheck.py — macOS 图标几何独立验收（只读，不生成图标、不改任何文件）
#
# 为什么需要它（2026-10-28，待办 t-95b74bca「Dock 图标偏大」）：
#   「图标看起来大」不能靠眼睛当判据。这里用两条可复现的几何量：
#     1) 实体宽度 = alpha > 200 的像素 bbox 宽（透明边不算实体，这正是 Dock 里看到的轮廓）
#     2) 实体占比 = 实体宽 / 画布宽
#   校准基准是本机三个系统 App 的 icns 256 档（实测 206/256 = 80.5%）：
#     /System/Applications/{Music,Calculator,Notes}.app/Contents/Resources/AppIcon.icns
#   旧版 RLPlayer 打包出来是 233/256 = 91.0% ⟹ 比系统 App 大 13%，这就是用户看到的现象。
#   所以判据是：256 档实体 206±4 px 且 bbox 居中、全档 icns 齐全、四角 alpha=0。
#
# 依赖：Pillow（读 PNG alpha）+ 系统 iconutil（解包 icns）。
#   ⚠ 本机系统 python3 的 PIL 曾报 x86 加载错误，请用工作区自带 Python：
#     PY=/Users/august/.dsh/dsh-runtimes/dsh-next-primary-runtime/dependencies/python/bin/python3
#     "$PY" tools/iconcheck.py --icns dist-mac/RLPlayer.app/Contents/Resources/RLPlayer.icns
#
# 用法：
#   iconcheck.py --icns <路径.icns> [--expect-entity 206] [--tolerance 4]
#                [--apple-ref] [--json <输出.json>]
#   退出码 0 = 全部判据通过；1 = 有判据不通过（会逐条打印 ✗ 原因）。
#
# 已知局限（如实记录）：
#   * 只量几何与透明度，不判「好不好看」/配色/圆角风格。
#   * 16/32 小档像素太少（±1px = ±6%），占比判据放宽到 70~84%，只用于发现「满幅出血」。
#   * icns 里同一像素尺寸可能有多档命名（icon_256x256.png 与 icon_128x128@2x.png 都是 256），
#     判据按文件名逐条查，不合并。
import argparse
import json
import os
import subprocess
import sys
import tempfile

try:
    from PIL import Image
except Exception as exc:  # noqa: BLE001 - 需要把原因原样报给用户
    sys.stderr.write(
        "✗ 无法导入 Pillow（%s）。\n"
        "  请用工作区自带 Python 运行：\n"
        "  /Users/august/.dsh/dsh-runtimes/dsh-next-primary-runtime/dependencies/python/bin/python3 "
        "tools/iconcheck.py ...\n" % exc)
    sys.exit(2)

ALPHA_THRESHOLD = 200           # 与 tools/make_icon_mac.swift 的判据保持一致

# iconset 全档（文件名 → 期望像素边长）
EXPECTED_SLICES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

APPLE_APPS = ["Music", "Calculator", "Notes"]


def entity_bbox(alpha):
    """alpha > ALPHA_THRESHOLD 的像素 bbox；全透明返回 None。"""
    return alpha.point(lambda v: 255 if v > ALPHA_THRESHOLD else 0).getbbox()


def measure(png_path):
    im = Image.open(png_path).convert("RGBA")
    alpha = im.getchannel("A")
    w, h = im.size
    bbox = entity_bbox(alpha)
    corners = [alpha.getpixel(p) for p in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1))]
    return {
        "path": png_path,
        "size": (w, h),
        "bbox": bbox,
        "entity": None if bbox is None else (bbox[2] - bbox[0], bbox[3] - bbox[1]),
        "ratio": None if bbox is None else (bbox[2] - bbox[0]) / w,
        "corners": corners,
    }


def extract_icns(icns_path, workdir):
    """iconutil 解包 icns → iconset 目录（解出来什么就是 icns 里真有的）。"""
    out = os.path.join(workdir, "slices.iconset")
    proc = subprocess.run(["iconutil", "-c", "iconset", icns_path, "-o", out],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError("iconutil 解包失败：%s\n%s" % (icns_path, proc.stderr.strip()))
    return out


def check_iconset(iconset_dir, expect_entity, tolerance):
    """返回 (rows, failures)。rows 是逐档测量结果。"""
    rows, failures = [], []
    for name, want in EXPECTED_SLICES:
        path = os.path.join(iconset_dir, name)
        if not os.path.isfile(path):
            failures.append("缺少 %s（icns 不含 %dpx 档）" % (name, want))
            continue
        m = measure(path)
        rows.append((name, want, m))
        if m["size"] != (want, want):
            failures.append("%s 实际 %dx%d，期望 %dx%d" %
                            (name, m["size"][0], m["size"][1], want, want))
        if any(c != 0 for c in m["corners"]):
            failures.append("%s 四角不是全透明：%s" % (name, m["corners"]))
        if m["entity"] is None:
            failures.append("%s 没有任何实体像素（整张透明）" % name)
            continue
        # 占比下限拦住「满幅出血」，上限拦住「缩太小」；小档像素少，放宽下限
        lo = 0.70 if want <= 32 else 0.76
        if not (lo <= m["ratio"] <= 0.84):
            failures.append("%s 实体占比 %.1f%%，超出 %.0f%%~84%%（实体 %d/%d）" %
                            (name, m["ratio"] * 100, lo * 100, m["entity"][0], want))

    # 主判据：256 档（Dock/启动台实际取用的档位之一，也是用户报的「偏大」所在）
    main = [r for r in rows if r[0] == "icon_256x256.png"]
    if main:
        m = main[0][2]
        if m["entity"] is None:
            failures.append("256 档无实体，无法判定尺寸")
        else:
            ew, eh = m["entity"]
            if abs(ew - expect_entity) > tolerance:
                failures.append("256 档实体宽 %dpx，期望 %d±%d px（占比 %.1f%%，基准 %.1f%%）" %
                                (ew, expect_entity, tolerance, m["ratio"] * 100,
                                 expect_entity / 256 * 100))
            if ew != eh:
                failures.append("256 档实体不是正方形：%dx%d" % (ew, eh))
            left, _, right, _ = m["bbox"]
            w = m["size"][0]
            if abs(left - (w - right)) > 2:
                failures.append("256 档实体未居中：左留白 %dpx / 右留白 %dpx" % (left, w - right))
    else:
        failures.append("没有 icon_256x256.png，无法判定 Dock 档几何")
    return rows, failures


def apple_reference():
    """只读量系统 App 的 icns 256 档，作为「Dock 里多大算正常」的基准。"""
    out = []
    for app in APPLE_APPS:
        icns = "/System/Applications/%s.app/Contents/Resources/AppIcon.icns" % app
        if not os.path.isfile(icns):
            continue
        try:
            with tempfile.TemporaryDirectory() as td:
                ico = extract_icns(icns, td)
                p = os.path.join(ico, "icon_128x128@2x.png")
                if not os.path.isfile(p):
                    p = os.path.join(ico, "icon_256x256.png")
                m = measure(p)
        except Exception as exc:  # noqa: BLE001 - 基准缺失不算失败，只提示
            out.append((app, None, str(exc)))
            continue
        out.append((app, m, None))
    return out


def main():
    ap = argparse.ArgumentParser(description="RLPlayer macOS 图标几何验收（只读）")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--icns", help="要检查的 .icns")
    src.add_argument("--iconset", help="要检查的 .iconset 目录（免 iconutil）")
    ap.add_argument("--expect-entity", type=int, default=206,
                    help="256 档期望实体宽（px），默认 206 = 系统 App 基准")
    ap.add_argument("--tolerance", type=int, default=4, help="实体宽容差（px），默认 4")
    ap.add_argument("--apple-ref", action="store_true", help="同时打印系统 App 基准（只读）")
    ap.add_argument("--json", help="把结果写成 JSON（证据存档用）")
    args = ap.parse_args()

    if args.icns and not os.path.isfile(args.icns):
        sys.stderr.write("✗ 找不到 icns：%s\n" % args.icns)
        return 2

    with tempfile.TemporaryDirectory() as td:
        iconset = args.iconset or extract_icns(args.icns, td)
        rows, failures = check_iconset(iconset, args.expect_entity, args.tolerance)

    print("源：%s" % (args.icns or args.iconset))
    print("%-22s %5s %8s %8s  %-22s %s" %
          ("file", "size", "entity", "ratio", "bbox(alpha>%d)" % ALPHA_THRESHOLD, "corners"))
    for name, want, m in rows:
        ent = "—" if m["entity"] is None else "%dx%d" % m["entity"]
        ratio = "—" if m["ratio"] is None else "%.1f%%" % (m["ratio"] * 100)
        print("%-22s %5d %8s %8s  %-22s %s" %
              (name, want, ent, ratio, str(m["bbox"]), ",".join(str(c) for c in m["corners"])))

    if args.apple_ref:
        print("\n系统 App 基准（同一量法，只读）：")
        for app, m, err in apple_reference():
            if m is None:
                print("  %-12s 不可读：%s" % (app, err))
            else:
                print("  %-12s 256 档实体 %dx%d / %d = %.1f%%"
                      % (app, m["entity"][0], m["entity"][1], m["size"][0], m["ratio"] * 100))

    print()
    if failures:
        for f in failures:
            print("✗ %s" % f)
        print("判据：256 档实体 %d±%d px、四角透明、全档 16→1024 齐全 ⟹ FAIL"
              % (args.expect_entity, args.tolerance))
        status = 1
    else:
        print("✓ 判据全部通过：256 档实体 %d±%d px、四角透明、全档 16→1024 齐全（10 档）"
              % (args.expect_entity, args.tolerance))
        status = 0

    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump({
                "source": args.icns or args.iconset,
                "alpha_threshold": ALPHA_THRESHOLD,
                "expect_entity_256": args.expect_entity,
                "tolerance": args.tolerance,
                "status": "pass" if status == 0 else "fail",
                "slices": [{
                    "file": name,
                    "expected_size": want,
                    "size": m["size"],
                    "bbox": m["bbox"],
                    "entity": m["entity"],
                    "ratio": m["ratio"],
                    "corners": m["corners"],
                } for name, want, m in rows],
                "failures": failures,
            }, fh, ensure_ascii=False, indent=2)
        print("（JSON 证据：%s）" % args.json)
    return status


if __name__ == "__main__":
    sys.exit(main())
