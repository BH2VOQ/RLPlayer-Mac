// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_dsd_settings_snapshot — 并发写 DSD 抽取设置时，读侧按值快照必须永远拿到
// 「自洽三元组」（kind / conversion / twoStage 属于同一次写入）。
//
// 红（旧实现）：dsd_pcm_settings() 返回引用，读侧与写侧共享同一结构且三字段非原子，
// 读到 (Fir, Wide, true) 这类拼不成一组的组合（本轮跑出 torn>0）。
// 绿（新实现）：读侧按值拷贝，且写侧只有唯一整组入口 set_dsd_pcm_settings()。

#include <atomic>
#include <cstdio>
#include <thread>
#include <type_traits>

#include "audio/audio_loader.h"

static int g_pass = 0;
static int g_fail = 0;

static void ck(bool ok, const char* name, const char* detail = "") {
    if (ok) { g_pass++; std::printf("  [PASS] %s\n", name); }
    else { g_fail++; std::printf("  [FAIL] %s  %s\n", name, detail); }
}

static bool is_combo_a(const rta::audio::DsdPcmSettings& s) {
    return s.kind == rta::dsp::IntegratorKind::Fir
        && s.conversion == rta::dsp::DsdConversion::Narrow
        && s.twoStage == true;
}

static bool is_combo_b(const rta::audio::DsdPcmSettings& s) {
    return s.kind == rta::dsp::IntegratorKind::Iir
        && s.conversion == rta::dsp::DsdConversion::Wide
        && s.twoStage == false;
}

int main() {
    using rta::audio::DsdPcmSettings;
    using rta::audio::dsd_pcm_settings;
    using rta::audio::set_dsd_pcm_settings;

    // 读侧必须拿到「值」而不是共享引用：编译期判据，防止被改回引用实现。
    static_assert(std::is_same<decltype(dsd_pcm_settings()), DsdPcmSettings>::value,
                  "dsd_pcm_settings() 必须按值返回快照");

    DsdPcmSettings a;
    a.kind = rta::dsp::IntegratorKind::Fir;
    a.conversion = rta::dsp::DsdConversion::Narrow;
    a.twoStage = true;

    DsdPcmSettings b;
    b.kind = rta::dsp::IntegratorKind::Iir;
    b.conversion = rta::dsp::DsdConversion::Wide;
    b.twoStage = false;

    // 单线程往返：写什么读什么
    set_dsd_pcm_settings(a);
    ck(is_combo_a(dsd_pcm_settings()), "单线程写 A 后读回 A");
    set_dsd_pcm_settings(b);
    ck(is_combo_b(dsd_pcm_settings()), "单线程写 B 后读回 B");

    // 并发：三写一读，读到的每一次都必须是 A 或 B 的完整组合
    const int kRounds = 200000;
    std::atomic<int> torn{0};
    std::atomic<int> reads{0};

    std::thread w0([&] { for (int i = 0; i < kRounds; ++i) set_dsd_pcm_settings(a); });
    std::thread w1([&] { for (int i = 0; i < kRounds; ++i) set_dsd_pcm_settings(b); });
    std::thread w2([&] {
        for (int i = 0; i < kRounds; ++i) set_dsd_pcm_settings((i % 2) ? a : b);
    });
    std::thread rd([&] {
        for (int i = 0; i < kRounds; ++i) {
            const DsdPcmSettings s = dsd_pcm_settings();
            if (!is_combo_a(s) && !is_combo_b(s)) torn.fetch_add(1);
            reads.fetch_add(1);
        }
    });

    w0.join();
    w1.join();
    w2.join();
    rd.join();

    char detail[128];
    std::snprintf(detail, sizeof(detail), "torn=%d / reads=%d", torn.load(), reads.load());
    ck(torn.load() == 0, "并发读写：快照永远是自洽三元组（无撕裂）", detail);
    ck(reads.load() == kRounds, "读线程真的跑满（判据不是空转）", detail);

    std::printf("\n----------------------------------------\n");
    std::printf("PASS %d / FAIL %d\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
