// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// make_icon_mac.swift — 由 res/rlplayer-256.png 生成 macOS 全档 .iconset（供 iconutil 打包）
//
// 为什么需要这个工具（2026-10-28，待办 t-95b74bca：用户反馈「Dock 图标偏大」）：
//   * 旧的打包脚本直接 `sips -z N N res/rlplayer-256.png` 缩放原图，原图是**满幅出血**的
//     圆角方块（alpha>200 实体横跨 233/256 = 91.0% 画布宽），于是 Dock 里/启动台里
//     这个图标比系统 App 大一圈：本机 Music / Calculator / Notes 的 256 档同样量法是
//     206/256 = 80.5%（实测，见 tools/iconcheck.py 输出的对照表）。
//   * macOS 图标规范里「图形本体」要留出视觉边距（透明），由画布承担这部分留白。
//     原图本身没有这条留白，所以**不是原图错了、也不是要重画**，而是打包时该把原图
//     整体缩小到 206/233 ≈ 0.884、居中绘制到透明画布上。
//   * 为什么不用 `sips --padToHeightWidth`：sips 的补边只支持不透明底色
//     （`--padColor` 是 RGB，没有 alpha 通道），补出来是黑/白边框，不是透明边。
//     必须用能直接画 alpha 画布的图形栈 —— 这里用 AppKit/CoreGraphics。
//
// 用法：
//   swift tools/make_icon_mac.swift <源PNG> <输出 .iconset 目录> [--entity-px 206]
//
// 输出：16/32/64/128/256/512/1024 共 10 个 iconset 条目
//        （16/32/128/256/512 各含 @1x 与 @2x，@2x 覆盖到 1024）
//
// 判据（tools/iconcheck.py 会独立复测）：
//   256×256 档 alpha>200 实体宽高 = 206±4 px（80.5% 画布宽），四角 alpha = 0。

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// iconset 条目（名称 → 像素边长）。@2x 条目与 @1x 同名尺寸也要各自出文件，
// iconutil 靠文件名（而不是像素尺寸）决定写进 icns 的哪个档位。
let slices: [(name: String, pixels: Int)] = [
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

let alphaThreshold = 200   // 「实体」判据：alpha > 200 才算不透明本体（与 iconcheck.py 一致）
let masterPixels = 1024    // 统一先画一张 1024 主图，再降采样到各档，保证各档观感一致

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(("✗ make_icon_mac: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - 画布

func makeContext(_ pixels: Int) -> CGContext {
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil,
                             width: pixels,
                             height: pixels,
                             bitsPerComponent: 8,
                             bytesPerRow: pixels * 4,
                             space: cs,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        die("无法创建 \(pixels)×\(pixels) RGBA 画布")
    }
    ctx.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))   // 全透明，不是黑底
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    return ctx
}

func drawInto(_ ctx: CGContext, _ image: CGImage, rect: CGRect) {
    ctx.saveGState()
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.draw(image, in: rect)
    ctx.restoreGState()
}

// 逐级对半降采样，避免一次 1024→16 这种大比例缩放在 CoreGraphics 里出现锯齿/丢细节。
func resample(_ image: CGImage, to pixels: Int) -> CGImage {
    var cur = image
    while cur.width / 2 >= pixels * 2 {
        let next = cur.width / 2
        let ctx = makeContext(next)
        drawInto(ctx, cur, rect: CGRect(x: 0, y: 0, width: next, height: next))
        guard let out = ctx.makeImage() else { die("降采样到 \(next)px 失败") }
        cur = out
    }
    let ctx = makeContext(pixels)
    drawInto(ctx, cur, rect: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    guard let out = ctx.makeImage() else { die("缩放到 \(pixels)px 失败") }
    return out
}

// MARK: - 实体测量（决定缩放系数）

func alphaBBoxWidth(_ image: CGImage) -> Int {
    let w = image.width, h = image.height
    let ctx = makeContext(w)
    // makeContext 会清成透明，这里只画一次拿原始像素
    drawInto(ctx, image, rect: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data else { die("读不到像素缓冲") }
    let buf = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
    var minX = w, maxX = -1
    for y in 0..<h {
        let row = y * w * 4
        for x in 0..<w where Int(buf[row + x * 4 + 3]) > alphaThreshold {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
        }
    }
    if maxX < minX { die("源图没有任何 alpha > \(alphaThreshold) 的实体像素") }
    return maxX - minX + 1
}

// MARK: - PNG 写出

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                    UTType.png.identifier as CFString,
                                                    1, nil) else {
        die("无法写出 \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { die("PNG 编码失败：\(url.path)") }
}

// MARK: - main

var args = Array(CommandLine.arguments.dropFirst())
var entityPx = 206
if let i = args.firstIndex(of: "--entity-px") {
    guard i + 1 < args.count, let v = Int(args[i + 1]) else { die("--entity-px 需要一个整数") }
    entityPx = v
    args.removeSubrange(i...(i + 1))
}
guard args.count == 2 else {
    die("用法：swift tools/make_icon_mac.swift <源PNG> <输出.iconset> [--entity-px 206]")
}
let sourcePath = (args[0] as NSString).expandingTildeInPath
let outPath = (args[1] as NSString).expandingTildeInPath

guard let nsImage = NSImage(contentsOfFile: sourcePath) else { die("读不到源图：\(sourcePath)") }
var proposed = CGRect(x: 0, y: 0, width: nsImage.size.width, height: nsImage.size.height)
guard let sourceCG = nsImage.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
    die("源图无法转成 CGImage：\(sourcePath)")
}
if sourceCG.width != sourceCG.height { die("源图必须是正方形，实际 \(sourceCG.width)×\(sourceCG.height)") }

let sourceEntity = alphaBBoxWidth(sourceCG)
let ratio = Double(entityPx) / Double(sourceEntity)          // 233 → 206 时约 0.884
let side = Double(masterPixels) * ratio

// 主图：原图整体缩放后**居中**画到透明画布上（源图本体本身居中，缩放到画布中心即可）
let masterCtx = makeContext(masterPixels)
drawInto(masterCtx, sourceCG,
         rect: CGRect(x: (Double(masterPixels) - side) / 2,
                      y: (Double(masterPixels) - side) / 2,
                      width: side, height: side))
guard let master = masterCtx.makeImage() else { die("主图渲染失败") }

try? FileManager.default.createDirectory(atPath: outPath, withIntermediateDirectories: true)
for slice in slices {
    let image = slice.pixels == masterPixels ? master : resample(master, to: slice.pixels)
    writePNG(image, to: URL(fileURLWithPath: outPath).appendingPathComponent(slice.name))
}

print("✓ iconset 已生成：\(outPath)")
print("  源图 \(sourceCG.width)×\(sourceCG.height) 实体 alpha>\(alphaThreshold) = \(sourceEntity)px")
print("  缩放 \(String(format: "%.4f", ratio))（目标实体 \(entityPx)px / 画布 256px = "
      + String(format: "%.1f", Double(entityPx) / 256.0 * 100) + "%）")
print("  条目 \(slices.count) 个：" + slices.map { "\($0.pixels)" }.joined(separator: "/"))
