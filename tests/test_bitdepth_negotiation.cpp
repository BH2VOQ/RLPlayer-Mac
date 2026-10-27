// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_bitdepth_negotiation.cpp — PCM 格式与位深协商校验测试（纯离线判定，先红后绿）

#include "platform/macos/pcm_format_validation.h"
#include "platform/audio_out.h"
#include "platform/macos/audio_out_coreaudio.h"
#include <cstdio>
#include <string>

using namespace rta::platform::macos;

static int g_total = 0;
static int g_failed = 0;

static void check(bool ok, const std::string& name, const std::string& detail = "") {
    ++g_total;
    if (!ok) ++g_failed;
    std::printf("  [%s] %s%s%s\n", ok ? "PASS" : "FAIL", name.c_str(),
                detail.empty() ? "" : " -- ", detail.c_str());
}

static AudioStreamBasicDescription make_asbd(
    Float64 rate, UInt32 ch, UInt32 bits, UInt32 bytesPerFrame, UInt32 flags)
{
    AudioStreamBasicDescription d{};
    d.mSampleRate = rate;
    d.mFormatID = kAudioFormatLinearPCM;
    d.mFormatFlags = flags;
    d.mBytesPerPacket = bytesPerFrame;
    d.mFramesPerPacket = 1;
    d.mBytesPerFrame = bytesPerFrame;
    d.mChannelsPerFrame = ch;
    d.mBitsPerChannel = bits;
    return d;
}

int main() {
    std::printf("=== test_bitdepth_negotiation (离线判据，先红后绿) ===\n");

    // 1. 16-bit packed 成功 (2ch, 44100Hz, 16bit, 4 bytes/frame)
    {
        auto asbd = make_asbd(44100, 2, 16, 4, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked);
        auto a = analyze_pcm_asbd(asbd);
        check(a.valid && a.packing == ContainerPacking::Packed16 && a.effectiveBits == 16,
              "16-bit packed 分析正确");

        auto res = validate_and_negotiate_format(44100, 16, 2, asbd);
        check(res.accepted && res.acceptedPacking == ContainerPacking::Packed16 &&
              res.effectiveBits == 16 && res.containerBits == 16 && !res.isFloat &&
              !res.requiresRepack && res.fallbackNote.empty(),
              "16-bit packed 协商成功且无降级");
    }

    // 2. 24-bit packed 成功 (2ch, 96000Hz, 24bit, 6 bytes/frame, 3B/sample)
    {
        auto asbd = make_asbd(96000, 2, 24, 6, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked);
        auto a = analyze_pcm_asbd(asbd);
        check(a.valid && a.packing == ContainerPacking::Packed24 && a.effectiveBits == 24,
              "24-bit packed (3字节) 分析正确");

        auto res = validate_and_negotiate_format(96000, 24, 2, asbd);
        check(res.accepted && res.acceptedPacking == ContainerPacking::Packed24 &&
              res.effectiveBits == 24 && res.containerBits == 24 && !res.isFloat &&
              !res.requiresRepack && res.fallbackNote.empty(),
              "24-bit packed 协商成功且无降级");
    }

    // 3. 24-in-32 (24位装入32位容器，8 bytes/frame, 4B/sample)
    {
        // 非 packed 或 flags 没有 packed，mBitsPerChannel=24, bytesPerSample=4
        auto asbd = make_asbd(96000, 2, 24, 8, kAudioFormatFlagIsSignedInteger);
        auto a = analyze_pcm_asbd(asbd);
        check(a.valid && a.packing == ContainerPacking::In32Bit24 && a.effectiveBits == 24 && a.containerBits == 32,
              "24-in-32 (4字节容器) 分析正确");

        auto res = validate_and_negotiate_format(96000, 24, 2, asbd);
        check(res.accepted && res.acceptedPacking == ContainerPacking::In32Bit24 &&
              res.effectiveBits == 24 && res.containerBits == 32 && !res.isFloat &&
              res.requiresRepack && !res.fallbackNote.empty(),
              "24-in-32 请求24位时接受，但要求重新打包且上报说明");
    }

    // 4. Float32 (32位单精度浮点，有效精度 24 位)
    {
        auto asbd = make_asbd(48000, 2, 32, 8, kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked);
        auto a = analyze_pcm_asbd(asbd);
        check(a.valid && a.packing == ContainerPacking::Float32 && a.effectiveBits == 24 && a.containerBits == 32,
              "Float32 报告容器32位、有效精度24位（不能说整型32）");

        auto res24 = validate_and_negotiate_format(48000, 24, 2, asbd);
        check(res24.accepted && res24.acceptedPacking == ContainerPacking::Float32 &&
              res24.effectiveBits == 24 && res24.containerBits == 32 && res24.isFloat &&
              res24.requiresRepack && !res24.fallbackNote.empty(),
              "Float32 请求24位时接受，有效精度24位、需转换");

        // 请求 32 位整型遇到 Float32 必须拒绝（浮点单精度仅 24 位有效尾数，不得谎报 32 精度）
        auto res32 = validate_and_negotiate_format(48000, 32, 2, asbd);
        check(!res32.accepted && !res32.rejectReason.empty(),
              "Float32 请求32位整型时必须明确拒绝（不得谎报32位整型）");
    }

    // 5. 32 -> 24 降级拒绝：请求 32 位整型，设备只给 24-bit packed
    {
        auto asbd = make_asbd(192000, 2, 24, 6, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked);
        auto res = validate_and_negotiate_format(192000, 32, 2, asbd);
        check(!res.accepted && !res.rejectReason.empty(),
              "请求32位整型但设备仅给24位时明确拒绝，绝不静默谎报");
    }

    // 6. 字节数与声道不匹配 / Invalid Bytes / 损坏的 ASBD
    {
        // 2ch, 16bit, 却给了 5 bytes per frame (非整数倍)
        auto asbd = make_asbd(44100, 2, 16, 5, kAudioFormatFlagIsSignedInteger);
        auto a = analyze_pcm_asbd(asbd);
        check(!a.valid && a.packing == ContainerPacking::Invalid,
              "损坏的字节数 (5 bytes/frame 对于 2ch) 判定为无效");

        auto res = validate_and_negotiate_format(44100, 16, 2, asbd);
        check(!res.accepted && !res.rejectReason.empty(),
              "无效字节数协商直接拒绝");
    }

    // 7. 非交错格式 (Non-Interleaved) 拒绝
    {
        auto asbd = make_asbd(44100, 2, 16, 2, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsNonInterleaved);
        auto a = analyze_pcm_asbd(asbd);
        check(!a.valid && !a.isInterleaved,
              "非交错格式正确识别并被标记不支持");

        auto res = validate_and_negotiate_format(44100, 16, 2, asbd);
        check(!res.accepted && !res.rejectReason.empty(),
              "非交错格式协商直接拒绝");
    }

    // 8. 采样率或声道数不匹配拒绝
    {
        auto asbd = make_asbd(48000, 2, 16, 4, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked);
        auto resRate = validate_and_negotiate_format(44100, 16, 2, asbd);
        check(!resRate.accepted && resRate.rejectReason.find("采样率不匹配") != std::string::npos,
              "采样率不符时明确拒绝");

        auto resCh = validate_and_negotiate_format(48000, 16, 1, asbd);
        check(!resCh.accepted && resCh.rejectReason.find("声道数不匹配") != std::string::npos,
              "声道数不符时明确拒绝");
    }

    // 9. CoreAudioOutput getter 与回退说明接口静态契约验证
    {
        rta::platform::CoreAudioOutput out;
        auto fmt = out.actual_format();
        check(fmt.sampleRate == 0 && fmt.bits == 0 && fmt.fallbackNote.empty(),
              "未 open 时 actual_format 返回默认空状态");
        check(out.bits_fallback_note().empty(),
              "未 open 时 bits_fallback_note 返回空");
    }

    std::printf("=========================================\n");
    std::printf("测试结果: %d / %d 通过 (%d 失败)\n", g_total - g_failed, g_total, g_failed);
    return g_failed == 0 ? 0 : 1;
}
