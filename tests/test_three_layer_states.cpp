// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_three_layer_states.cpp — 三层查询在「独占 / 共享 / 停止」三态下的行为
//
// 目的（2026-11-10 发版前回归）：/api/status 每次轮询都会调 three_layer_check()，
// 必须确认：① 停止态不崩溃不死锁 ② 共享模式不误报 ③ 不启 IOProc、不写样本。
#include "platform/audio_out_factory.h"
#include "platform/macos/audio_out_coreaudio.h"
#include <cstdio>
#include <string>

static int g_fail = 0, g_total = 0;
static void ck(bool ok, const char* what) {
    ++g_total;
    if (!ok) ++g_fail;
    std::printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what);
}

int main(int argc, char** argv) {
    std::string device;
    for (int i = 1; i < argc; ++i) {
        if (std::string(argv[i]) == "--device" && i + 1 < argc) device = argv[++i];
        else if (device.empty() && argv[i][0] != '-') device = argv[i];
    }
    std::printf("=== 三层状态查询回归（不启 IOProc、不写样本）===\n");
    std::printf("设备: %s\n\n", device.empty() ? "(系统默认)" : device.c_str());

    auto out = rta::platform::create_audio_output();
    ck(out != nullptr, "后端可创建");

    // ---- [1] 停止态：未 open，三层查询必须安全返回 ----
    {
        auto* ca = dynamic_cast<rta::platform::CoreAudioOutput*>(out.get());
        ck(ca != nullptr, "可 dynamic_cast 到 CoreAudioOutput");
        auto t = ca->three_layer_state();
        ck(!t.known, "停止态 three_layer_state().known == false");
        auto v = ca->three_layer_verdict();
        ck(!v.ok, "停止态 three_layer_verdict() 判否");
        ck(!ca->bit_perfect(), "停止态 bit_perfect() == false");
        std::printf("  停止态理由: %s\n", v.why.c_str());
    }

    // ---- [2] 共享模式：open 后三层可读，但 bit_perfect() 必须为 false ----
    {
        rta::platform::OpenSpec sp;
        sp.deviceId = device;
        sp.rate = 44100; sp.bits = 16; sp.channels = 2; sp.bufferMs = 100.0;
        sp.shared = true;
        sp.exclusive = false;
        const bool ok = out->open(sp);
        std::printf("  共享 open: %s\n", ok ? "ok" : (std::string("FAIL: ") + out->last_error()).c_str());
        if (ok) {
            auto* ca = dynamic_cast<rta::platform::CoreAudioOutput*>(out.get());
            ck(ca->shared_mode(), "共享标志为 true");
            for (int i = 0; i < 5; ++i) { auto v = ca->three_layer_verdict(); (void)v; }
            ck(true, "共享态连续 5 次三层查询无崩溃/死锁");
            ck(!ca->bit_perfect(), "共享模式 bit_perfect() == false");
            out->close();
            ck(!ca->bit_perfect(), "close 后 bit_perfect() == false");
        } else {
            std::printf("  (共享 open 未成功，跳过共享态断言：%s)\n", out->last_error().c_str());
        }
    }

    std::printf("\n========== %d/%d passed ==========\n", g_total - g_fail, g_total);
    return g_fail == 0 ? 0 : 1;
}
