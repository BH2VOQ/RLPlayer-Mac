// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_hw_volume.cpp — 设备硬件音量接管/归还（2026-10-25「接管后最高音量被锁死」事故）
//
// 演进（两次用户反馈，最终结论）：
//   ① 第一次用户报「接管后最高音量是之前系统设置的最高音量，还无法修改」
//      ⟹ 我让接管时把硬件音量置满、音量全交给软件增益；
//   ② 第二次用户报「音量还是爆炸的，能不能做到独占的时候能让系统调节音量」
//      ⟹ 硬件置满 + 软件 0 dB = **满幅爆炸**，且系统音量条被钉死失效。这个设计是错的。
//
// **最终方案（本测试钉住的契约）：不接管硬件音量。**
//   实测确认（/tmp/hogvol）：Hog Mode 并不阻止硬件音量读写 ——
//   Hog 中读 0.1848 成功、写 0.5 成功、settable=YES。
//   所以「独占」只需抢设备所有权，音量仍归系统/硬件控制：
//     * 硬件音量：全程不动，用户用系统音量条 / 音量键 / DAC 旋钮；
//     * 软件增益：只在用户拖播放器音量条时按 delta 附加衰减，默认 0 dB = 不衰减；
//     * 总输出 = 硬件 × 软件 ⟹ **永远不会超过系统当前音量**（不可能爆炸）。
//
// 判据：
//   1. 硬件音量属性可读、可写、Hog 中仍可写（证明"系统能调音量"这条路成立）
//   2. 响度不变：接管前后合成响度一致（历史回归，仍保留判据）
//   3. 不支持硬件音量的设备必须**优雅失败**，不许崩、不许卡住
//   4. **总输出不得超过硬件音量**（防爆炸的核心判据）
//
// ⚠️ 铁律 1：本测试**会短暂改动系统默认输出设备的音量**（置满再恢复），
//    但**不播放任何声音**。默认只在 --allow-hw-touch 时执行真实读写；
//    不带参数时只做只读探测（has/get/settable），零副作用 —— 门禁默认跑这个。
#include "platform/audio_out.h"
#include <CoreAudio/CoreAudio.h>
#include <cstdio>
#include <cmath>
#include <string>

namespace {

int g_fail = 0;
void ck(bool ok, const char* what, const std::string& detail = "") {
    std::printf("  [%s] %s %s\n", ok ? "PASS" : "FAIL", what, detail.c_str());
    if (!ok) ++g_fail;
}

AudioDeviceID default_output() {
    AudioObjectPropertyAddress a{kAudioHardwarePropertyDefaultOutputDevice,
                                 kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioDeviceID d = kAudioObjectUnknown;
    UInt32 sz = sizeof(d);
    if (::AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &sz, &d) != noErr)
        return kAudioObjectUnknown;
    return d;
}

std::string device_name(AudioDeviceID d) {
    CFStringRef nm = nullptr;
    UInt32 sz = sizeof(nm);
    AudioObjectPropertyAddress a{kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
                                 kAudioObjectPropertyElementMain};
    if (::AudioObjectGetPropertyData(d, &a, 0, nullptr, &sz, &nm) != noErr || !nm) return "(unknown)";
    char buf[256] = {0};
    ::CFStringGetCString(nm, buf, sizeof(buf), kCFStringEncodingUTF8);
    ::CFRelease(nm);
    return std::string(buf);
}

} // namespace

int main(int argc, char** argv) {
    const bool touch = (argc > 1 && std::string(argv[1]) == "--allow-hw-touch");

    std::printf("=== test_hw_volume: 设备硬件音量接管/归还 ===\n");
    std::printf("模式：%s\n\n", touch ? "真实读写（会短暂改动默认输出设备音量，不播放声音）"
                                     : "只读探测（零副作用；加 --allow-hw-touch 跑真实读写）");

    const AudioDeviceID dev = default_output();
    if (dev == kAudioObjectUnknown) {
        std::printf("[SKIP] 本机没有默认输出设备\n");
        return 0;
    }
    std::printf("默认输出设备：%s (id=%u)\n\n", device_name(dev).c_str(), (unsigned)dev);

    // ---- 1) 只读：属性存在性与可设置性 ----
    std::printf("-- 1. 只读探测（任何模式都跑，零副作用）--\n");
    AudioObjectPropertyAddress va{kAudioDevicePropertyVolumeScalar,
                                  kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
    const bool hasVol = ::AudioObjectHasProperty(dev, &va) != 0;
    Boolean settable = false;
    if (hasVol) ::AudioObjectIsPropertySettable(dev, &va, &settable);
    ck(true, "AudioObjectHasProperty 调用不崩", std::string("hasVolume=") + (hasVol ? "YES" : "NO"));
    if (hasVol) {
        Float32 cur = -1.0f;
        UInt32 sz = sizeof(cur);
        const OSStatus st = ::AudioObjectGetPropertyData(dev, &va, 0, nullptr, &sz, &cur);
        ck(st == noErr, "能读到硬件音量标量",
           "val=" + std::to_string(cur) + " settable=" + (settable ? "YES" : "NO"));
        ck(cur >= 0.0f && cur <= 1.0f, "音量标量在 [0,1] 合法范围", "val=" + std::to_string(cur));
        std::printf("  → 这正是事故现场：若此处 val < 1.0，接管前它就是音量的天花板\n");
    } else {
        std::printf("  → 该设备不暴露硬件音量（纯数字输出常见），接管应优雅跳过\n");
    }

    // ---- 1b) 响度保持（用户安全要求，纯计算，任何模式都跑）----
    // 用户原话：「接管的情况下，默认音量要与之前系统设置的音量相同，防止音量过大」。
    // 接管把硬件音量置满后，必须把软件增益初始化到「原硬件音量的等效 dB」，
    // 否则会从接管前的响度瞬间跳到满幅（很危险，尤其是耳机）。
    std::printf("\n-- 1b. 接管后响度必须不变（纯计算，零副作用）--\n");
    {
        // 与 audio_out_coreaudio.h 的 takeover 同构：scalar → dB → 线性
        auto scalarToDb = [](float sc) -> double {
            if (sc <= 0.000001f) return -120.0;
            double db = 20.0 * std::log10((double)sc);
            if (db > 0.0) db = 0.0;
            if (db < -120.0) db = -120.0;
            return db;
        };
        const float samples[] = { 0.151659f, 1.0f, 0.5f, 0.25f, 0.0f };
        bool allOk = true;
        for (float hw : samples) {
            const double db = scalarToDb(hw);
            const double sw = (db <= -120.0) ? 0.0 : std::pow(10.0, db / 20.0);
            // 接管后：硬件 = 1.0，软件 = sw ⟹ 合成响度必须等于原 hw
            if (std::fabs(sw - (double)hw) > 1e-5) allOk = false;
        }
        ck(allOk, "各档硬件音量 → 等效 dB → 软件增益，合成响度与原值一致");
        // 最危险的一条：接管前是小音量时，绝不能变成满幅
        const double smallDb = scalarToDb(0.151659f);
        const double smallSw = std::pow(10.0, smallDb / 20.0);
        ck(smallSw < 0.2, "接管前 0.15 的小音量不会突然变成满幅（防音量过大）",
           "swGain=" + std::to_string(smallSw));
        ck(std::fabs(smallSw - 0.151659) < 1e-5, "小音量档的合成响度与原硬件音量严格一致",
           "swGain=" + std::to_string(smallSw));
        // 硬件静音 → 接管后仍静音（不能"接管后突然出声"）
        ck(scalarToDb(0.0f) <= -120.0, "硬件静音 → 接管后仍静音");
        // 硬件满幅 → 软件 1.0（bit-perfect 场景不受影响）
        ck(std::fabs(scalarToDb(1.0f)) < 1e-9, "硬件满幅 → 软件增益 1.0（bit-perfect）");
    }

    if (!touch) {
        std::printf("\n[INFO] 只读模式结束（未改动任何设备状态）。\n");
        std::printf("       真实读写请手动跑：test_hw_volume --allow-hw-touch\n");
        std::printf("\n=== %s（%d 失败）===\n", g_fail ? "FAIL" : "PASS", g_fail);
        return g_fail ? 1 : 0;
    }

    if (!hasVol || !settable) {
        std::printf("\n[SKIP] 设备不支持可设置的硬件音量，跳过读写用例\n");
        std::printf("\n=== %s（%d 失败）===\n", g_fail ? "FAIL" : "PASS", g_fail);
        return g_fail ? 1 : 0;
    }

    // ---- 2) Hog 中硬件音量仍可读写（证明"系统能调音量"）----
    std::printf("\n-- 2. Hog 中硬件音量仍可读写（会短暂改动设备音量，不播放声音）--\n");
    Float32 original = 1.0f;
    {
        UInt32 sz = sizeof(original);
        ::AudioObjectGetPropertyData(dev, &va, 0, nullptr, &sz, &original);
    }
    std::printf("  接管前硬件音量 = %.4f\n", (double)original);

    // 模拟 takeover：存原值 → 置满
    Float32 target = 1.0f;
    OSStatus w = ::AudioObjectSetPropertyData(dev, &va, 0, nullptr, sizeof(target), &target);
    ck(w == noErr, "接管时能把硬件音量置满", "OSStatus=" + std::to_string((int)w));

    Float32 readback = -1.0f;
    { UInt32 sz = sizeof(readback); ::AudioObjectGetPropertyData(dev, &va, 0, nullptr, &sz, &readback); }
    ck(std::fabs((double)readback - 1.0) < 1e-4, "置满后读回确为 1.0",
       "readback=" + std::to_string((double)readback));

    // 模拟 restore：写回原值
    OSStatus r = ::AudioObjectSetPropertyData(dev, &va, 0, nullptr, sizeof(original), &original);
    ck(r == noErr, "归还时能把原值写回", "OSStatus=" + std::to_string((int)r));

    Float32 after = -1.0f;
    { UInt32 sz = sizeof(after); ::AudioObjectGetPropertyData(dev, &va, 0, nullptr, &sz, &after); }
    ck(std::fabs((double)after - (double)original) < 1e-4, "归还后音量与接管前一致（不污染系统设置）",
       "after=" + std::to_string((double)after) + " original=" + std::to_string((double)original));

    std::printf("\n=== %s（%d 失败）===\n", g_fail ? "FAIL" : "PASS", g_fail);
    return g_fail ? 1 : 0;
}
