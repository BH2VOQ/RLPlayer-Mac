// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// output_bit_depth.h — 输出位深解析与决议（纯函数，零外部依赖，可离线单测）
//
// 规则：
// 1. setting == -1（跟随源 / Follow Source）：
//    - 若 sourceBits 为合法源位深（16、24、32），则解析为该源位深；
//    - 若 sourceBits 未知或无效（<= 0，如 probe 失败或缺失），fallback 如实默认 24。
// 2. setting == 0（默认）：固定 24-bit。
// 3. setting > 0（如 16, 24, 32）：返回设置值本身。
// 4. 其他非法负值：统一 fallback 默认 24。
//
// 关于 32-bit 源（整数 vs 浮点）在现有播放管线中的限制说明：
// - 32-bit int（pcm_s32le）：标准 32 位整型 PCM，动态范围 192 dB，Pipeline 能够通过
//   AudioBuffer (isFloat=false, bits=32) 完整承载并在必要时进行直通或重采样。
// - 32-bit float（IEEE 754 float32）：WAV fmtTag=3 或有损解码（MP3/AAC/OGG/Opus）
//   在解码器内部常为 float 表示，其有效精度尾数为 24 位（约 144 dB 动态范围）。
//   现有管线在 willBeBitPerfect 中对 in.isFloat 显式判定为 false（非 bit-perfect），
//   必须经过双精度 work 平面并在阶段 7 量化后输出为目标位深的整数 PCM。
#pragma once

namespace rta::audio {

inline int resolve_output_bits(int setting, int sourceBits) {
    if (setting == -1) {
        if (sourceBits == 16 || sourceBits == 24 || sourceBits == 32) {
            return sourceBits;
        }
        return 24;
    }
    if (setting == 0) {
        return 24;
    }
    if (setting > 0) {
        return setting;
    }
    return 24;
}

} // namespace rta::audio
