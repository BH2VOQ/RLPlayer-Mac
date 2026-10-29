// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_hog_exclusive.cpp — Hog 独占开关（方案 C）与系统音量可用性（2026-10-25）
//
// 用户诉求演进：
//   ① 「接管后最高音量被锁死」→ 我做成"接管硬件音量"，错了；
//   ② 「音量爆炸，能不能独占时让系统调音量」→ 查清机制：
//      **macOS Hog Mode 会阻断其它进程改硬件音量**（实测 /tmp/hogdiff），
//      「严格独占」与「系统音量可用」物理互斥。
//   ③ 用户拍板：**做成开关，让用户自己选**（方案 C）。
//
// 本测试钉住的契约：
//   1. set_hog_mode(dev,true)  真的抢到独占（owner == 本进程 pid）
//   2. 独占期间系统音量路径**被阻断**（这是 Hog 的语义，不是 bug）
//   3. set_hog_mode(dev,false) 真的释放（owner != 本进程）
//   4. 释放后系统音量**恢复可用**
//   5. OpenSpec::exclusive 默认 false（不抢 Hog ⟹ 开箱即用系统音量）
//
// ⚠️ 铁律 1：会短暂改动系统音量（最后恢复），但**不播放任何声音**。
//    默认只在 --allow-hw-touch 时执行真实 Hog 抢占；否则只做只读断言。
#include "platform/audio_out.h"
#include <CoreAudio/CoreAudio.h>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <string>
#include <unistd.h>

namespace {
int g_fail = 0;
void ck(bool ok, const char* what, const std::string& d = "") {
    std::printf("  [%s] %s %s\n", ok ? "PASS" : "FAIL", what, d.c_str());
    if (!ok) ++g_fail;
}
AudioDeviceID defOut() {
    AudioObjectPropertyAddress a{kAudioHardwarePropertyDefaultOutputDevice,
                                 kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioDeviceID d = kAudioObjectUnknown; UInt32 s = sizeof(d);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &s, &d);
    return d;
}
pid_t hogOwner(AudioDeviceID d) {
    AudioObjectPropertyAddress ha{kAudioDevicePropertyHogMode,
                                  kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    pid_t o = -999; UInt32 s = sizeof(o);
    if (AudioObjectGetPropertyData(d, &ha, 0, nullptr, &s, &o) != noErr) return -888;
    return o;
}
// 与生产代码同构（audio_out_coreaudio.h 的 set_hog_mode）
void setHog(AudioDeviceID d, bool on) {
    pid_t val = on ? 0 : ::getpid();          // ← 关键：写 0 = 抢，写 pid = 放
    AudioObjectPropertyAddress ha{kAudioDevicePropertyHogMode,
                                  kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectSetPropertyData(d, &ha, 0, nullptr, sizeof(val), &val);
}
float getVol(AudioDeviceID d) {
    AudioObjectPropertyAddress va{kAudioDevicePropertyVolumeScalar,
                                  kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
    Float32 x = -1; UInt32 s = sizeof(x);
    AudioObjectGetPropertyData(d, &va, 0, nullptr, &s, &x);
    return x;
}
float sysSetVolume(AudioDeviceID d, int pct) {
    char c[160];
    std::snprintf(c, sizeof(c), "osascript -e 'set volume output volume %d' 2>/dev/null", pct);
    std::fflush(stdout);
    if (std::system(c) != 0) return -1.0f;
    float v = 0;
    for (int i = 0; i < 20; ++i) { ::usleep(150000); v = getVol(d); if (std::fabs(v - pct / 100.0f) < 0.02f) break; }
    return v;
}
} // namespace

int main(int argc, char** argv) {
    const bool touch = (argc > 1 && std::string(argv[1]) == "--allow-hw-touch");
    std::printf("=== test_hog_exclusive: Hog 独占开关与系统音量可用性 ===\n");
    std::printf("模式：%s\n\n", touch ? "真实抢占（会短暂改系统音量，不播放声音）" : "只读断言（零副作用）");

    // ---- 1) OpenSpec::exclusive 默认必须是 false ----
    std::printf("-- 1. OpenSpec::exclusive 默认值 --\n");
    {
        rta::platform::OpenSpec sp;
        ck(sp.exclusive == false, "默认 exclusive=false（不抢 Hog ⟹ 系统音量可用）");
        ck(sp.shared == false, "默认 shared=false（不经系统混音器）");
    }

    const AudioDeviceID dev = defOut();
    if (dev == kAudioObjectUnknown) { std::printf("\n[SKIP] 无默认输出设备\n"); return 0; }
    std::printf("\n默认输出设备 id=%u，当前 Hog owner=%d（me=%d）\n",
                (unsigned)dev, (int)hogOwner(dev), (int)::getpid());

    if (!touch) {
        std::printf("\n[INFO] 只读模式：未抢 Hog、未改音量。\n");
        std::printf("       真实抢占请跑：test_hog_exclusive --allow-hw-touch\n");
        std::printf("\n=== %s（%d 失败）===\n", g_fail ? "FAIL" : "PASS", g_fail);
        return g_fail ? 1 : 0;
    }

    const float orig = getVol(dev);
    std::printf("原始系统音量 = %.4f\n", (double)orig);

    // ---- 2) 不抢 Hog：系统音量应可用 ----
    std::printf("\n-- 2. 不抢 Hog（exclusive=false）→ 系统音量应可用 --\n");
    if (hogOwner(dev) == ::getpid()) setHog(dev, false);
    ::usleep(300000);
    ck(hogOwner(dev) != ::getpid(), "已确保未持有 Hog");
    {
        const float v = sysSetVolume(dev, 60);
        ck(std::fabs((double)v - 0.60) < 0.06, "系统音量设为 60 → 生效（系统能调音量）",
           "实测=" + std::to_string((double)v));
    }

    // ---- 3) 抢 Hog：系统音量应被阻断 ----
    std::printf("\n-- 3. 抢 Hog（exclusive=true）→ 系统音量应被阻断 --\n");
    setHog(dev, true);
    ::usleep(400000);
    {
        const bool held = (hogOwner(dev) == ::getpid());
        ck(held, "set_hog_mode(true) 真的抢到独占（写 0 的语义）",
           "owner=" + std::to_string((int)hogOwner(dev)) + " me=" + std::to_string((int)::getpid()));
        if (held) {
            const float before = getVol(dev);
            const float after = sysSetVolume(dev, 15);
            ck(std::fabs((double)after - (double)before) < 0.03,
               "独占期间系统音量被阻断（Hog 语义，不是 bug）",
               "前=" + std::to_string((double)before) + " 后=" + std::to_string((double)after));
        }
    }

    // ---- 4) 释放：系统音量应恢复 ----
    std::printf("\n-- 4. 释放 Hog（exclusive=false）→ 系统音量应恢复 --\n");
    setHog(dev, false);
    ::usleep(400000);
    {
        const bool released = (hogOwner(dev) != ::getpid());
        ck(released, "set_hog_mode(false) 真的释放（写 pid 的语义）",
           "owner=" + std::to_string((int)hogOwner(dev)));
        if (released) {
            const float v = sysSetVolume(dev, 45);
            ck(std::fabs((double)v - 0.45) < 0.06, "释放后系统音量恢复可用",
               "实测=" + std::to_string((double)v));
        }
    }

    // 恢复原始音量
    {
        char c[160];
        std::snprintf(c, sizeof(c), "osascript -e 'set volume output volume %d' 2>/dev/null",
                      (int)std::lround((double)orig * 100));
        std::system(c);
        std::printf("\n已恢复原始音量 %.2f\n", (double)orig);
    }

    std::printf("\n=== %s（%d 失败）===\n", g_fail ? "FAIL" : "PASS", g_fail);
    return g_fail ? 1 : 0;
}
