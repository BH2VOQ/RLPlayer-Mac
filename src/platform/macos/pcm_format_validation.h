// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// platform/macos/pcm_format_validation.h — CoreAudio ASBD 格式与位深协商校验纯逻辑

#pragma once

#include <CoreAudio/CoreAudioTypes.h>
#include <cstdint>
#include <string>

namespace rta::platform::macos {

// 容器布局类型
enum class ContainerPacking {
    Invalid = 0,
    Packed16,       // 16 位紧凑整数 (2 bytes/sample)
    Packed24,       // 24 位紧凑整数 (3 bytes/sample)
    In32Bit24,      // 24 位有效数据置于 32 位容器 (4 bytes/sample, 24-in-32)
    Float32,        // 32 位浮点 (4 bytes/sample, 24 位有效尾数)
    Int32           // 32 位整型容器 (4 bytes/sample, 32 位有效精度)
};

// 格式验证与解析结果
struct PcmFormatAnalysis {
    bool valid = false;
    bool isLinearPcm = false;
    bool isInterleaved = false;
    bool isFloat = false;
    bool isSignedInt = false;
    bool isPacked = false;

    uint32_t sampleRate = 0;
    uint32_t channels = 0;
    uint32_t bitsPerChannel = 0;
    uint32_t bytesPerFrame = 0;
    uint32_t bytesPerPacket = 0;
    uint32_t framesPerPacket = 0;
    uint32_t bytesPerSample = 0;     // bytesPerFrame / channels

    ContainerPacking packing = ContainerPacking::Invalid;
    uint32_t containerBits = 0;       // 容器宽度（位，如 16, 24, 32）
    uint32_t effectiveBits = 0;       // 实际有效精度位数（如 Float32 为 24，In32Bit24 为 24）

    std::string description;          // 人类可读格式描述
};

// 协商判定结论
struct FormatNegotiationResult {
    bool accepted = false;
    ContainerPacking acceptedPacking = ContainerPacking::Invalid;
    uint32_t effectiveBits = 0;
    uint32_t containerBits = 0;
    bool isFloat = false;
    bool requiresRepack = false;     // 是否需要重新打包（如 24-in-32 对比 packed24）
    std::string fallbackNote;        // 降级/回退说明（若完全一致则为空）
    std::string rejectReason;        // 拒绝原因（若 accepted=false 则非空）
};

// 从 ASBD 分析 PCM 格式（纯函数，无系统调用）
inline PcmFormatAnalysis analyze_pcm_asbd(const AudioStreamBasicDescription& asbd) {
    PcmFormatAnalysis a;
    a.sampleRate = (uint32_t)asbd.mSampleRate;
    a.channels = asbd.mChannelsPerFrame;
    a.bitsPerChannel = asbd.mBitsPerChannel;
    a.bytesPerFrame = asbd.mBytesPerFrame;
    a.bytesPerPacket = asbd.mBytesPerPacket;
    a.framesPerPacket = asbd.mFramesPerPacket;

    if (asbd.mFormatID != kAudioFormatLinearPCM) {
        a.description = "非线性 PCM 格式";
        return a;
    }
    a.isLinearPcm = true;

    if (a.channels == 0 || a.sampleRate == 0) {
        a.description = "无效的声道数或采样率";
        return a;
    }

    // 非交错格式判定：kAudioFormatFlagIsNonInterleaved 置位时为非交错
    a.isInterleaved = !(asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved);
    if (!a.isInterleaved) {
        a.description = "非交错格式（当前渲染流仅支持交错 PCM）";
        return a;
    }

    if (a.framesPerPacket != 1) {
        a.description = "每包帧数不为 1";
        return a;
    }

    a.bytesPerSample = a.bytesPerFrame / a.channels;
    if (a.bytesPerSample * a.channels != a.bytesPerFrame ||
        a.bytesPerPacket != a.bytesPerFrame) {
        a.description = "每帧/每包字节数与声道数不匹配（损坏的 ASBD）";
        return a;
    }

    a.isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    a.isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
    a.isPacked = (asbd.mFormatFlags & kAudioFormatFlagIsPacked) != 0;

    // 1) 32-bit Float
    if (a.isFloat) {
        if (a.bytesPerSample == 4 && a.bitsPerChannel == 32) {
            a.valid = true;
            a.packing = ContainerPacking::Float32;
            a.containerBits = 32;
            a.effectiveBits = 24; // 严格依据 IEEE 754 float32 单精度 24 位有效尾数
            a.description = "32-bit 浮点（容器 32 位，有效精度 24 位）";
            return a;
        } else {
            a.description = "不支持的浮点位深/字节数组合";
            return a;
        }
    }

    // 2) 整数 PCM
    if (a.isSignedInt) {
        // 16-bit packed
        if (a.bitsPerChannel == 16 && a.bytesPerSample == 2 && a.isPacked) {
            a.valid = true;
            a.packing = ContainerPacking::Packed16;
            a.containerBits = 16;
            a.effectiveBits = 16;
            a.description = "16-bit packed 整数（2 字节/样本）";
            return a;
        }
        // 24-bit packed (24/24, 3 字节)
        if (a.bitsPerChannel == 24 && a.bytesPerSample == 3 && a.isPacked) {
            a.valid = true;
            a.packing = ContainerPacking::Packed24;
            a.containerBits = 24;
            a.effectiveBits = 24;
            a.description = "24-bit packed 整数（3 字节/样本）";
            return a;
        }
        // 24-in-32 (24 位装入 32 位容器，4 字节)
        if (a.bitsPerChannel == 24 && a.bytesPerSample == 4) {
            a.valid = true;
            a.packing = ContainerPacking::In32Bit24;
            a.containerBits = 32;
            a.effectiveBits = 24;
            a.description = "24-in-32 整数（容器 32 位，有效精度 24 位）";
            return a;
        }
        // 32-bit packed 整数 (32/32, 4 字节)
        if (a.bitsPerChannel == 32 && a.bytesPerSample == 4 && a.isPacked) {
            a.valid = true;
            a.packing = ContainerPacking::Int32;
            a.containerBits = 32;
            a.effectiveBits = 32;
            a.description = "32-bit packed 整数（4 字节/样本）";
            return a;
        }
    }

    a.description = "未识别或不支持的 PCM 布局";
    return a;
}

// 协商校验函数：将请求格式与真实读回的 ASBD 做严格对比
// reqRate: 请求采样率
// reqBits: 请求位深 (16, 24, 32)
// reqChannels: 请求声道数
// actualAsbd: 读回的 ASBD
inline FormatNegotiationResult validate_and_negotiate_format(
    uint32_t reqRate,
    int reqBits,
    int reqChannels,
    const AudioStreamBasicDescription& actualAsbd)
{
    FormatNegotiationResult res;
    PcmFormatAnalysis a = analyze_pcm_asbd(actualAsbd);

    if (!a.valid) {
        res.accepted = false;
        res.rejectReason = "设备读回格式无效: " + a.description;
        return res;
    }

    // 检查采样率和声道必须严格一致
    if (a.sampleRate != reqRate) {
        res.accepted = false;
        res.rejectReason = "采样率不匹配: 请求 " + std::to_string(reqRate) +
                           " Hz，设备实际 " + std::to_string(a.sampleRate) + " Hz";
        return res;
    }

    if ((int)a.channels != reqChannels) {
        res.accepted = false;
        res.rejectReason = "声道数不匹配: 请求 " + std::to_string(reqChannels) +
                           " ch，设备实际 " + std::to_string(a.channels) + " ch";
        return res;
    }

    // 请求 16 位
    if (reqBits == 16) {
        if (a.packing == ContainerPacking::Packed16) {
            res.accepted = true;
            res.acceptedPacking = ContainerPacking::Packed16;
            res.effectiveBits = 16;
            res.containerBits = 16;
            res.isFloat = false;
            res.requiresRepack = false;
            res.fallbackNote = ""; // 完全一致
            return res;
        }
        // 拒绝被静默升格或降格（例如设备强行给 24/32/float）若不匹配直接明确拒绝以保证字节对齐安全
        res.accepted = false;
        res.rejectReason = "位深不匹配: 请求 16-bit，设备实际为 " + a.description;
        return res;
    }

    // 请求 24 位
    if (reqBits == 24) {
        if (a.packing == ContainerPacking::Packed24) {
            res.accepted = true;
            res.acceptedPacking = ContainerPacking::Packed24;
            res.effectiveBits = 24;
            res.containerBits = 24;
            res.isFloat = false;
            res.requiresRepack = false;
            res.fallbackNote = ""; // 完全一致
            return res;
        }
        if (a.packing == ContainerPacking::In32Bit24) {
            // 精度同为 24 位，但容器为 32 位（4 字节对齐）
            res.accepted = true;
            res.acceptedPacking = ContainerPacking::In32Bit24;
            res.effectiveBits = 24;
            res.containerBits = 32;
            res.isFloat = false;
            res.requiresRepack = true;
            res.fallbackNote = "设备采用 24-in-32 容器（有效精度 24 位，容器 32 位）";
            return res;
        }
        if (a.packing == ContainerPacking::Float32) {
            // float32 尾数 24 位，精度等价 24 位
            res.accepted = true;
            res.acceptedPacking = ContainerPacking::Float32;
            res.effectiveBits = 24;
            res.containerBits = 32;
            res.isFloat = true;
            res.requiresRepack = true;
            res.fallbackNote = "设备采用 Float32（32 位浮点容器，有效精度 24 位）";
            return res;
        }
        res.accepted = false;
        res.rejectReason = "位深不匹配: 请求 24-bit，设备实际为 " + a.description;
        return res;
    }

    // 请求 32 位
    if (reqBits == 32) {
        if (a.packing == ContainerPacking::Int32) {
            res.accepted = true;
            res.acceptedPacking = ContainerPacking::Int32;
            res.effectiveBits = 32;
            res.containerBits = 32;
            res.isFloat = false;
            res.requiresRepack = false;
            res.fallbackNote = ""; // 完全一致
            return res;
        }
        // 若设备只给 24 位精度（无论是 packed24, 24-in-32 还是 float32），必须拒绝 32 位请求！
        // 绝不能把 24 精度谎报为 32 整型！
        res.accepted = false;
        res.rejectReason = "精度损失拒绝: 请求整型 32-bit，但设备仅提供 " + a.description;
        return res;
    }

    res.accepted = false;
    res.rejectReason = "不支持的请求位深: " + std::to_string(reqBits);
    return res;
}

} // namespace rta::platform::macos
