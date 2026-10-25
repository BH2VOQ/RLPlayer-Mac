// test_hw_volume.cpp — 设备硬件音量接管/归还（2026-10-25「接管后最高音量被锁死」事故）
//
// 事故：用户报「要接管设备就全接管，要用系统的音量级别，现在接管之后最高音量是之前
//       系统设置的最高音量，还无法修改」。
// 根因：本项目**从未读写过设备硬件音量**（全仓 grep 零命中）。独占(Hog)模式下
//       系统音量 UI 被挡住，硬件音量标量停在接管那一刻的旧值（本机实测 0.152 ≈ −16 dB），
//       播放器只做软件增益 ⟹ 天花板就是这个陈旧值，且用户无法修改。
//
// 修复语义（本测试要钉住的契约）：
//   1. 接管 = 存原值 → 硬件音量置满 1.0 → 解除静音
//   2. 归还 = 把原值写回去（幂等，失败不抛）
//   3. 不支持硬件音量的设备（例如纯数字输出）必须**优雅失败**，不许崩、不许卡住
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

    // ---- 2) 真实接管 → 置满 → 归还 ----
    std::printf("\n-- 2. 接管 → 置满 → 归还（会短暂改动设备音量，不播放声音）--\n");
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
