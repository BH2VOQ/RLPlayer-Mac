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

    // 0. 回归判据（2026-10-28 真机事故）：**设备层**是 Float32 / 24-in-32 时，
    //    协商结果允许 requiresRepack=true（这是如实报告"设备层与客户端打包不同"），
    //    但**开流绝不允许因此被拒**。beta2 曾把 requiresRepack 当成拒绝条件，导致用户
    //    所有歌都报「打开输出后端失败: 设备要求 24-in-32 或浮点容器重打包」，全部无法播放。
    //    这里把"设备层 Float32 是可接受的上报结果"钉死，防止再犯。
    {
        auto devFloat = make_asbd(44100, 2, 32, 8, kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked);
        auto r = validate_and_negotiate_format(44100, 24, 2, devFloat);
        check(r.accepted, "设备层 Float32 + 请求 24bit：协商必须 accepted（AUHAL 负责转换）",
              r.rejectReason);
        check(r.requiresRepack, "设备层 Float32 如实报告 requiresRepack（不等于拒绝）", r.fallbackNote);
        check(r.effectiveBits == 24, "Float32 有效精度报 24（不谎报 32）",
              std::to_string(r.effectiveBits));
    }
    {
        // 真正的 24-in-32 是「24 位有效、4 字节容器」：bytesPerFrame=8(2ch*4)，且**不是** Packed
        // （Packed 意味着有效位填满容器）。beta2 事故里 8 bytes/frame + Packed 属于自相矛盾的 ASBD，
        // 被 analyze 判无效是正确的，这里用合法形态验证「设备层 24-in-32 也不该拒播」。
        auto dev24in32 = make_asbd(44100, 2, 24, 8,
                                   kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsAlignedHigh);
        auto r = validate_and_negotiate_format(44100, 24, 2, dev24in32);
        check(r.accepted, "设备层 24-in-32 + 请求 24bit：协商必须 accepted", r.rejectReason);
    }

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

    // 9. 拒绝大端 (Big-Endian) 格式
    {
        auto asbd = make_asbd(44100, 2, 16, 4,
                              kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsBigEndian);
        auto a = analyze_pcm_asbd(asbd);
        check(!a.valid && a.description.find("大端") != std::string::npos,
              "大端格式拒绝：analyze_pcm_asbd 明确拒绝");

        auto res = validate_and_negotiate_format(44100, 16, 2, asbd);
        check(!res.accepted && res.rejectReason.find("大端") != std::string::npos,
              "大端格式协商直接拒绝");
    }

    // 10. 拒绝标志冲突：Float 与 SignedInteger 矛盾
    {
        auto asbd = make_asbd(44100, 2, 32, 8,
                              kAudioFormatFlagIsFloat | kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked);
        auto a = analyze_pcm_asbd(asbd);
        check(!a.valid && a.description.find("冲突") != std::string::npos,
              "Float + SignedInteger 矛盾标志拒绝");

        auto res = validate_and_negotiate_format(44100, 32, 2, asbd);
        check(!res.accepted && !res.rejectReason.empty(),
              "Float + SignedInteger 冲突协商直接拒绝");
    }

    // 11. 拒绝标志冲突：Packed 与 AlignedHigh 矛盾
    {
        auto asbd = make_asbd(44100, 2, 24, 8,
                              kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsAlignedHigh);
        auto a = analyze_pcm_asbd(asbd);
        check(!a.valid && a.description.find("冲突") != std::string::npos,
              "Packed + AlignedHigh 矛盾标志拒绝");

        auto res = validate_and_negotiate_format(44100, 24, 2, asbd);
        check(!res.accepted && !res.rejectReason.empty(),
              "Packed + AlignedHigh 冲突协商直接拒绝");
    }

    // 12. 拒绝非正常采样率：NaN / Inf / 小数 / 负数，避免 double->uint 溢出 UB
    {
        auto asbdNaN = make_asbd(NAN, 2, 16, 4, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked);
        auto aNaN = analyze_pcm_asbd(asbdNaN);
        check(!aNaN.valid, "NaN 采样率明确拒绝");

        auto asbdInf = make_asbd(INFINITY, 2, 16, 4, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked);
        auto aInf = analyze_pcm_asbd(asbdInf);
        check(!aInf.valid, "Inf 采样率明确拒绝");

        auto asbdFrac = make_asbd(44100.5, 2, 16, 4, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked);
        auto aFrac = analyze_pcm_asbd(asbdFrac);
        check(!aFrac.valid && aFrac.description.find("非整数") != std::string::npos,
              "小数采样率 (44100.5 Hz) 明确拒绝");

        auto asbdNeg = make_asbd(-48000.0, 2, 16, 4, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked);
        auto aNeg = analyze_pcm_asbd(asbdNeg);
        check(!aNeg.valid, "负数采样率明确拒绝");
    }

    // 13. CoreAudioOutput getters (client_format / device_format / actual_format) 与状态清理验证
    {
        rta::platform::CoreAudioOutput out;
        auto clientFmt = out.client_format();
        check(clientFmt.sampleRate == 0 && clientFmt.bits == 0 &&
              clientFmt.packing == ContainerPacking::Invalid,
              "未 open 时 client_format 返回默认空状态");

        auto devFmt = out.device_format();
        check(devFmt.sampleRate == 0 && devFmt.bits == 0 && devFmt.fallbackNote.empty() &&
              devFmt.packing == ContainerPacking::Invalid,
              "未 open 时 device_format 返回默认空状态");

        auto actualFmt = out.actual_format();
        check(actualFmt.sampleRate == 0 && actualFmt.bits == 0 && actualFmt.fallbackNote.empty(),
              "未 open 时 actual_format 返回默认空状态");
        check(out.bits_fallback_note().empty(),
              "未 open 时 bits_fallback_note 返回空");

        // const 对象调用测试：验证锁 mutex 使用 mutable 而非 const_cast
        const rta::platform::CoreAudioOutput& constRef = out;
        auto constClient = constRef.client_format();
        auto constDev = constRef.device_format();
        auto constActual = constRef.actual_format();
        check(constClient.bits == 0 && constDev.bits == 0 && constActual.bits == 0,
              "const 引用下调用 getters 正确（基于 mutable std::mutex）");

        // 验证失败 open 会清空所有状态 (close_locked)
        rta::platform::OpenSpec badSpec{};
        badSpec.deviceId = "nonexistent_device_id_999999";
        badSpec.rate = 44100;
        badSpec.bits = 16;
        badSpec.channels = 2;
        bool openOk = out.open(badSpec);
        check(!openOk, "非法设备 ID open 失败");
        check(out.client_format().bits == 0 && out.device_format().bits == 0 &&
              out.actual_format().bits == 0 && out.bits_fallback_note().empty(),
              "open 失败后状态被彻底清空归位 (close_locked)");
    }

    std::printf("=========================================\n");
    std::printf("测试结果: %d / %d 通过 (%d 失败)\n", g_total - g_failed, g_total, g_failed);
    return g_failed == 0 ? 0 : 1;
}
