// SPDX-License-Identifier: GPL-3.0-or-later
// 物理格式选择判据的单测（先跑红：此时 phys_format.h 还不存在）
#include "audio/phys_format.h"
#include <cstdio>
#include <vector>

using rta::audio::PhysFormat;
using rta::audio::pick_physical_format;

static int fails = 0;
static void ck(bool cond, const char* what) {
    if (!cond) { std::printf("FAIL: %s\n", what); ++fails; }
    else       { std::printf("ok  : %s\n", what); }
}

int main() {
    const std::vector<PhysFormat> pocket = { {44100, 16, false} };

    {
        auto p = pick_physical_format(pocket, 44100, 16);
        ck(p.ok, "pocket 44k/16 可锁");
        ck(p.pick.rate == 44100 && p.pick.bits == 16 && !p.pick.isFloat, "pocket 44k/16 选中项正确");
        ck(!p.zeroPad, "pocket 44k/16 不是补零");
    }
    {
        auto p = pick_physical_format(pocket, 44100, 24);
        ck(!p.ok, "pocket 44k/24 必须拒绝（设备只有 16-bit）");
        ck(!p.why.empty(), "拒绝时必须有理由");
    }
    {
        auto p = pick_physical_format(pocket, 48000, 16);
        ck(!p.ok, "pocket 48k/16 必须拒绝（设备只有 44.1k）");
    }
    {
        const std::vector<PhysFormat> spk = { {44100, 32, true}, {48000, 32, true}, {96000, 32, true} };
        auto p = pick_physical_format(spk, 44100, 32);
        ck(!p.ok, "内置扬声器 44k/32 必须拒绝（端点只有浮点）");
        ck(p.why.find("浮点") != std::string::npos, "理由里要点明浮点");
    }
    {
        const std::vector<PhysFormat> dp = { {44100, 24, false}, {44100, 20, false}, {48000, 24, false} };
        auto p = pick_physical_format(dp, 44100, 24);
        ck(p.ok && p.pick.bits == 24, "24-bit 设备选中 24 而非 20");
    }
    {
        const std::vector<PhysFormat> both = { {44100, 24, false}, {44100, 16, false} };
        auto p = pick_physical_format(both, 44100, 16);
        ck(p.ok && p.pick.bits == 16 && !p.zeroPad, "有 16 就选 16，不无谓补零");
    }
    {
        const std::vector<PhysFormat> only24 = { {44100, 24, false} };
        auto p = pick_physical_format(only24, 44100, 16);
        ck(p.ok && p.pick.bits == 24, "只有 24 时允许补零");
        ck(p.zeroPad, "补零必须标记出来");
    }
    {
        ck(!pick_physical_format({}, 44100, 16).ok, "空能力列表必须拒绝");
        auto p = pick_physical_format(pocket, 0, 16);
        ck(!p.ok, "源采样率未知必须拒绝");
    }

    std::printf("\n%s (%d failures)\n", fails ? "RED" : "GREEN", fails);
    return fails ? 1 : 0;
}
