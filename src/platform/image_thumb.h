// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// image_thumb.h — 图片缩略图编码（平台层契约，macOS 单平台）
//
// 为什么放在 platform 层：解码任意图片格式（JPEG/PNG/WebP/HEIC/BMP……）并缩放、
// 应用 EXIF 方向，只有系统 ImageIO 能做（项目零第三方图像解码依赖）。纯 C++ 的
// 调用方（net/local_cover_cache.h、net/library.h）只依赖这一个窄接口，不碰
// CoreGraphics/ImageIO 类型 —— 与 http.h / path.h 的分层口径一致。
//
// 契约（调用方据此编码，实现不得放宽）：
//   * 只做「解码 + 等比缩放 + JPEG 编码」一件事，不落盘、不缓存、不读环境变量。
//   * 返回 false 表示输入无法解码 / 参数非法 / 编码失败；**绝不抛异常、绝不对垃圾字节崩溃**。
//   * 永不放大：输出长边 <= max_edge（源图本身更小时保持源尺寸）。
//   * 应用 EXIF 方向（kCGImageSourceCreateThumbnailWithTransform）—— 手机/相机拍的
//     JPEG 常带 Orientation=6，网格里歪着显示会被当成缺陷。
//   * max_edge <= 0 视为非法参数返回 false；quality 落在 1..100（实现可 clamp）。
//   * out 只在成功时被写入；失败时由实现清空。
#pragma once
#include <cstddef>
#include <vector>

namespace rta::platform {

// 把内存里的图片字节编码成长边 <= max_edge 的 JPEG。
//   data/size : 输入图片（任意 ImageIO 能解的格式；空指针/0 字节 -> false）
//   max_edge  : 输出长边上限（像素，> 0）
//   quality   : JPEG 质量 1..100（80 是网格卡片的既有口径）
//   out       : 成功时写入 JPEG 字节；失败时清空
bool make_jpeg_thumb(const unsigned char* data, size_t size, int max_edge, int quality,
                     std::vector<unsigned char>& out);

} // namespace rta::platform
