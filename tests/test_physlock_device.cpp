// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_physlock_device.cpp — 真机验证「物理格式锁定」是否真的生效
//
// 为什么必须有它（铁律 3：测试通过 ≠ 测对了东西）：
//   phys_format.h 的纯函数测试只能证明"给定能力列表时选择逻辑对"，
//   不能证明"真的锁到了硬件"。而本轮修的正是"只设 HAL 虚拟层、物理层不受控"这个缺陷 ——
//   判据必须是**设备读回值**，不是我们的意图。
//
// 🔴 铁律 1：全程**不启动 IOProc、不写任何样本**。只做 open()（它内部锁物理格式）
//   → 读回 → close()。open 本身不发声，也不改变系统音量。
//   open 会短暂抢 Hog（若 exclusive=true），close 立刻释放。
//
// 判据：
//   1. 独占开流后 physical_format_ok() == true（物理层锁到源格式）
//   2. physical_rate() == 请求采样率（不是设备原本默认的率）
//   3. physical_bits() >= 请求位深 且 非浮点
//   4. 若端点物理层只有浮点（如内置扬声器）：physical_format_ok() == false，
//      且 bits_fallback_note() 非空 —— 这是"如实降级"，不是失败
#include "platform/audio_out_factory.h"
#include "platform/macos/audio_out_coreaudio.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static int g_fail = 0;
static int g_total = 0;
static void ck(bool ok, const std::string& what, const std::string& detail = "") {
    ++g_total;
    if (!ok) ++g_fail;
    std::printf("  [%s] %s%s%s\n", ok ? "PASS" : "FAIL", what.c_str(),
                detail.empty() ? "" : "  ", detail.c_str());
}

// 只读：拿某设备的物理格式能力列表（不 open、不抢 Hog）
static std::vector<rta::audio::PhysFormat> phys_caps(const std::string& deviceId) {
    const auto dev = rta::platform::macos_probe::resolve_audio_device(deviceId);
    if (dev == 0) return {};
    const auto sid = rta::platform::macos_probe::first_output_stream(dev);
    return rta::platform::macos_probe::available_physical_formats(sid);
}

int main(int argc, char** argv) {
    std::string device;
    uint32_t rate = 44100;
    int bits = 16;
    for (int i = 1; i < argc; ++i) {
        if (!std::strcmp(argv[i], "--device") && i + 1 < argc) device = argv[++i];
        else if (!std::strcmp(argv[i], "--rate") && i + 1 < argc) rate = (uint32_t)std::atoi(argv[++i]);
        else if (!std::strcmp(argv[i], "--bits") && i + 1 < argc) bits = std::atoi(argv[++i]);
    }

    std::printf("== 物理格式锁定真机验证 ==\n");
    std::printf("   设备: %s   请求: %u Hz / %d bit\n",
                device.empty() ? "(系统默认)" : device.c_str(), rate, bits);
    std::printf("   （全程不启动 IOProc、不写样本，open 后立即 close）\n\n");

    // ---------- [1] 只读能力 ----------
    std::printf("[1] 物理层能力（只读，不碰设备）\n");
    const auto avail = phys_caps(device);
    ck(!avail.empty(), "能读到物理格式列表", std::to_string(avail.size()) + " 项");
    if (avail.empty()) { std::printf("\nFAILED\n"); return 1; }
    bool anyInt = false, anyFloat = false;
    for (const auto& f : avail) { if (f.isFloat) anyFloat = true; else anyInt = true; }
    std::printf("   含整数格式: %s   含浮点格式: %s\n", anyInt ? "是" : "否", anyFloat ? "是" : "否");

    // ---------- [2] 用纯函数预测 ----------
    std::printf("\n[2] 纯函数预测（与 [3] 的实测对照）\n");
    const auto pred = rta::audio::pick_physical_format(avail, rate, bits);
    std::printf("   预测: ok=%d rate=%u bits=%d zeroPad=%d  理由=%s\n",
                (int)pred.ok, pred.pick.rate, pred.pick.bits, (int)pred.zeroPad, pred.why.c_str());

    // ---------- [3] 真机开流（不出声）----------
    std::printf("\n[3] 真机开流并读回物理格式\n");
    auto out = rta::platform::create_audio_output();
    ck(out != nullptr, "create_audio_output() 有效");
    if (!out) { std::printf("\nFAILED\n"); return 1; }

    rta::platform::OpenSpec sp;
    sp.deviceId = device;
    sp.rate = rate;
    sp.bits = bits;
    sp.channels = 2;
    sp.bufferMs = 100.0;
    sp.shared = false;        // 独占路径才锁物理格式
    sp.exclusive = true;      // 与默认设置一致（用户要求独占默认开）

    const bool opened = out->open(sp);
    if (!opened) {
        // 设备被占用是合法结果（我们的设计就是明确拒绝、不静默降级）
        std::printf("   open 失败: %s\n", out->last_error().c_str());
        ck(out->last_error_class() == rta::platform::OutputError::DeviceBusy,
           "开流失败时错误分类是 DeviceBusy（被占用属预期）",
           rta::platform::output_error_text(out->last_error_class()));
        std::printf("\n跳过后续（设备被占用，未做任何写操作）\n");
        return g_fail == 0 ? 0 : 1;
    }
    ck(true, "独占开流成功");

    auto* ca = dynamic_cast<rta::platform::CoreAudioOutput*>(out.get());
    ck(ca != nullptr, "后端是可查询物理格式的 CoreAudioOutput");
    if (ca) {
        const bool ok = ca->physical_format_ok();
        const uint32_t pr = ca->physical_rate();
        const int pb = ca->physical_bits();
        const bool pf = ca->physical_is_float();
        std::printf("   读回: ok=%d rate=%u bits=%d float=%d\n", (int)ok, pr, pb, (int)pf);
        std::printf("   说明: %s\n", ca->physical_note().empty() ? "(无)" : ca->physical_note().c_str());

        if (pred.ok) {
            // 预测能锁 ⟹ 实测必须真的锁上。这条是红绿判据的核心。
            ck(ok, "预测可锁 ⟹ 实测 physical_format_ok() == true");
            ck(pr == rate, "物理采样率 == 请求采样率",
               std::to_string(pr) + " vs " + std::to_string(rate));
            ck(pb >= bits, "物理位深 >= 请求位深",
               std::to_string(pb) + " vs " + std::to_string(bits));
            ck(!pf, "物理格式是整数（不是浮点）");
            ck(ca->bit_perfect(), "后端 bit_perfect() 为 true");
        } else {
            // 预测锁不上（例如端点只有浮点）⟹ 必须如实报 false，且理由非空
            ck(!ok, "预测不可锁 ⟹ 实测 physical_format_ok() == false（不谎报）");
            ck(!ca->bit_perfect(), "后端 bit_perfect() 为 false");
            ck(!ca->bits_fallback_note().empty(), "必须给出说明（不是静默失败）");
        }
        ck(!ca->device_shared_with_others() || true, "设备占用状态可查询（仅信息）");
    }

    out->close();
    std::printf("\n已 close（Hog 已释放，未播放任何声音）\n");

    // ---------- [4] close 后状态归位 ----------
    std::printf("\n[4] close 后物理锁定状态归位\n");
    if (ca) ck(!ca->physical_format_ok(), "close 后 physical_format_ok() == false");

    std::printf("\n========== %d/%d passed ==========\n", g_total - g_fail, g_total);
    return g_fail == 0 ? 0 : 1;
}
