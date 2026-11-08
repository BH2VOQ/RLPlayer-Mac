// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// image_thumb.mm — platform/image_thumb.h 的 macOS 实现（ImageIO + CoreGraphics）
//
// 选型与踩坑（都是可复现的规则，不是偏好）：
//   1) 必须 kCGImageSourceCreateThumbnailFromImageAlways：默认（IfAbsent）会优先用
//      图片里内嵌的 EXIF 缩略图（常见 160x160），网格需要的 512 就永远拿不到 ——
//      表现为「缩略图糊」而不是「缩略图小」。
//   2) 必须 kCGImageSourceCreateThumbnailWithTransform=YES，否则 EXIF Orientation 被忽略。
//   3) kCGImageSourceThumbnailMaxPixelSize 是「长边」上限，ImageIO 保证不放大
//      （源图更小时按源尺寸返回）—— 正是本模块契约要求的语义，不需要自己再算比例。
//   4) 编码用 CGImageDestination + UTTypeJPEG。macOS 11+ 的 UniformTypeIdentifiers 里
//      UTTypeJPEG 与旧 kUTTypeJPEG 是同一个 UTI（public.jpeg）；用新 API 避免
//      MobileCoreServices 的弃用告警。CFSTR("public.jpeg") 兜底，兼容旧 SDK。
//   5) 全程不碰 NSImage/AppKit：本 TU 要能进 rtaweb / rlapp_core（CLI 无窗口依赖）。
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <algorithm>
#include <cstddef>
#include <vector>

#include "platform/image_thumb.h"

namespace rta::platform {
namespace {
// 源图字节上限：与 net/local_cover_cache.h 的 kMaxImageBytes 同量级（32 MB）；
// 这里的平台层放宽到 64 MB 只是为了不把「能解的大图」提前判死，产物另有 4 MB 上限。
constexpr size_t kMaxSourceBytes = 64 * 1024 * 1024;
constexpr size_t kMaxJpegBytes = 4 * 1024 * 1024;
} // namespace

bool make_jpeg_thumb(const unsigned char* data, size_t size, int max_edge, int quality,
                     std::vector<unsigned char>& out) {
    out.clear();
    // 防御：空指针 / 0 字节 / 超限 / 非法参数一律 false —— 绝不推测、绝不 crash。
    if (data == nullptr || size == 0 || size > kMaxSourceBytes || max_edge <= 0) return false;
    const int q = std::clamp(quality, 1, 100);

    @autoreleasepool {
        // freeWhenDone:NO —— 缓冲区归调用方所有，本 TU 绝不对它 free。
        NSData* src = [NSData dataWithBytesNoCopy:const_cast<unsigned char*>(data)
                                           length:(NSUInteger)size
                                     freeWhenDone:NO];
        if (src == nil) return false;
        CGImageSourceRef imageSource = CGImageSourceCreateWithData((__bridge CFDataRef)src, nullptr);
        if (imageSource == nullptr) return false;

        NSDictionary* readOptions = @{
            (__bridge NSString*)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
            (__bridge NSString*)kCGImageSourceCreateThumbnailWithTransform : @YES,
            (__bridge NSString*)kCGImageSourceThumbnailMaxPixelSize : @(max_edge),
            (__bridge NSString*)kCGImageSourceShouldCacheImmediately : @YES,
        };
        CGImageRef thumb =
            CGImageSourceCreateThumbnailAtIndex(imageSource, 0, (__bridge CFDictionaryRef)readOptions);
        CFRelease(imageSource);
        if (thumb == nullptr) return false;

        // 契约「永不放大」的兜底：ImageIO 文档保证长边 <= MaxPixelSize，但真出现
        // （系统行为变化 / 解码器怪例）就宁可 false，也不返回超限图。
        const size_t width = CGImageGetWidth(thumb);
        const size_t height = CGImageGetHeight(thumb);
        if (width == 0 || height == 0 || std::max(width, height) > (size_t)max_edge) {
            CGImageRelease(thumb);
            return false;
        }

        // 产物通常几十 KB，capacity 只做初始估计，不给大图预分配等量内存。
        NSMutableData* encoded = [NSMutableData dataWithCapacity:(NSUInteger)(256 * 1024)];
        CFStringRef uti = CFSTR("public.jpeg");
#if defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && __MAC_OS_X_VERSION_MAX_ALLOWED >= 110000
        if (@available(macOS 11.0, *)) uti = (__bridge CFStringRef)UTTypeJPEG.identifier;
#endif
        CGImageDestinationRef destination =
            CGImageDestinationCreateWithData((__bridge CFMutableDataRef)encoded, uti, 1, nullptr);
        if (destination == nullptr) {
            CGImageRelease(thumb);
            return false;
        }
        NSDictionary* writeOptions = @{
            (__bridge NSString*)kCGImageDestinationLossyCompressionQuality : @(q / 100.0),
        };
        CGImageDestinationAddImage(destination, thumb, (__bridge CFDictionaryRef)writeOptions);
        const bool finalized = CGImageDestinationFinalize(destination);
        CFRelease(destination);
        CGImageRelease(thumb);
        if (!finalized) return false;
        if (encoded.length < 3 || encoded.length > kMaxJpegBytes) return false;
        const unsigned char* raw = static_cast<const unsigned char*>(encoded.bytes);
        // 只接受真正的 JPEG 字节流（编码器行为异常时宁可 false，也不往缓存写坏图）。
        if (raw[0] != 0xFF || raw[1] != 0xD8 || raw[2] != 0xFF) return false;
        out.assign(raw, raw + encoded.length);
        return true;
    }
}

} // namespace rta::platform
