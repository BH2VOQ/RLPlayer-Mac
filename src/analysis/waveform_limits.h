// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// waveform_limits.h — /api/waveform「整段回退」的内存上限（纯逻辑，可离线单测）
//
// 背景（2026-11-16 评审 P0）：整段回退（read_any）必须先给出 PCM 上界，否则
// 「探测失败 + 32 MiB 文件」这种组合可以解出 ~281 MB PCM；内存不足时 audio_loader 会把
// bad_alloc 包成 runtime_error ⟹ 落到 422 waveform.decode_failed（假结论：重试也白搭）。
//
// 本头只做两件事（不碰解码器、不碰 ffprobe）：
//   ① 探测失败时按 codec 估算最坏 PCM 字节（文件字节 × 膨胀倍数）；
//   ② 统一的「解码前就该 413」判定 —— 有界用精确估计，无界用「文件上限 + 估算」双闸门。
// 真正的兜底仍是解码异常分支（bad_alloc → 413）；这里只是把**能提前判的**提前判。
#pragma once

#include <cstdint>
#include <string>

namespace rta {
namespace analysis {
namespace waveform_limits {

// 整段回退的硬上限：已解码 PCM（int32 × frames × channels）。256 MiB 覆盖常见
// 10 分钟级有损/无损文件；再大就拒绝（waveform.too_large）。
inline constexpr std::uint64_t kMaxWholePcmBytes = 256ull * 1024ull * 1024ull;

// 探测拿不到 duration/rate/channels 时的**文件**兜底上限（历史值，保留）。
inline constexpr std::uint64_t kMaxUnboundedFileBytes = 32ull * 1024ull * 1024ull;

// 探测失败时按 codec 估算「最坏 PCM 膨胀倍数」（文件字节 → int32 PCM 字节）。
// 依据是同一批容器在常见码率下的压缩比，而不是精确解码：
//   * 无损（flac/alac/ape/wv/tak）：正常 1.2~3×；取 4× 留余量（32 MiB 文件 → 128 MiB，
//     不会误杀正常无损文件）；
//   * 有损（mp3/aac/m4a/ogg/opus/wma）：128~320 kbps 对 44.1 kHz/16 bit 是 3.5~11×；
//     取 12×（32 MiB → 384 MiB ⟹ 直接 413，这正是评审举的那类「32 MiB 解出 ~281 MB」）；
//   * 未知容器：取 6×（收紧兜底，又不至于把常见格式误判成超限）。
inline std::uint32_t expansion_factor(const std::string& lower_ext) {
    auto is = [&](const char* e) { return lower_ext == e; };
    if (is(".flac") || is(".alac") || is(".ape") || is(".wv") || is(".wavpack") ||
        is(".tak") || is(".tta"))
        return 4u;
    if (is(".mp3") || is(".aac") || is(".m4a") || is(".mp4") || is(".ogg") || is(".oga") ||
        is(".opus") || is(".wma") || is(".mpc") || is(".ac3") || is(".dts"))
        return 12u;
    return 6u;
}

// 文件字节 → 估算 PCM 字节（溢出时饱和到 ~0ull）。
inline std::uint64_t unbounded_est_pcm_bytes(std::uint64_t file_bytes,
                                             const std::string& lower_ext) {
    const std::uint64_t f = expansion_factor(lower_ext);
    if (file_bytes > (~0ull) / f) return ~0ull;
    return file_bytes * f;
}

// 解码前判定：true = 直接回 413 waveform.too_large（不必也不该再尝试整段解码）。
//   * 有界（ffprobe 给出 rate/channels/duration）：按精确估计判；
//   * 无界：文件上限与「按 codec 估算」两道闸门，任一超标就拒绝。
inline bool whole_decode_too_large(bool bounded, std::uint64_t file_bytes,
                                   std::uint64_t est_pcm_bytes) {
    if (!bounded && file_bytes > kMaxUnboundedFileBytes) return true;
    return est_pcm_bytes > kMaxWholePcmBytes;
}

} // namespace waveform_limits
} // namespace analysis
} // namespace rta
