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


    // ---------------- [8] 2026-11-10：三层同率 + NonMixable 选取（HQPlayer 反编译结论吸收）----------------
    // Pocket Master 物理层同时有 44100/16 int 的 0x0c（可混音）与 0x4c（NonMixable）两档；
    // 旧 make_int_asbd 写死 0x0c，正好选中可混音档。HQPlayer 是「整数 + 非混音格式」。
    // 边界：0x40 由 HAL 在启动 IOProc 时隐式进入，受控探针证明未启 IOProc 时写不进也读不回，
    // 所以只要求「优先选带标志的档」，不要求「读回必须带标志」（否则是假判据）。
    std::printf("\n[8] NonMixable 优先选取 + 三层同率自证\n");
    {
        const std::vector<PhysFormat> pk = { {44100, 16, false, false}, {44100, 16, false, true} };
        auto p = pick_physical_format(pk, 44100, 16);
        ck(p.ok, "两档同格式仍可锁");
        ck(p.pick.nonMixable, "应优先选带 NonMixable(0x40) 的那一档");
    }
    {
        rta::audio::ThreeLayer ok{};
        ok.known = true; ok.nominalRate = 44100; ok.virtualRate = 44100; ok.physicalRate = 44100;
        ok.virtualInt = true; ok.physicalInt = true; ok.physicalBits = 16; ok.srcRate = 44100; ok.srcBits = 16;
        auto v = rta::audio::three_layer_verdict(ok);
        ck(v.ok, "三层同率 + 整数 => ok");
        ck(v.why.empty(), "通过时无理由");
    }
    {
        rta::audio::ThreeLayer bad{};
        bad.known = true; bad.nominalRate = 48000; bad.virtualRate = 44100; bad.physicalRate = 44100;
        bad.virtualInt = true; bad.physicalInt = true; bad.physicalBits = 16; bad.srcRate = 44100; bad.srcBits = 16;
        auto v = rta::audio::three_layer_verdict(bad);
        ck(!v.ok, "nominal rate 被改回去 => 判否");
        ck(v.why.find("nominal") != std::string::npos || v.why.find("采样率") != std::string::npos,
           "理由要点明是采样率不一致");
    }
    {
        rta::audio::ThreeLayer bad{};
        bad.known = true; bad.nominalRate = 44100; bad.virtualRate = 44100; bad.physicalRate = 44100;
        bad.virtualInt = false; bad.physicalInt = true; bad.physicalBits = 16; bad.srcRate = 44100; bad.srcBits = 16;
        auto v = rta::audio::three_layer_verdict(bad);
        ck(!v.ok, "虚拟层是浮点 => 判否（经 HAL 混音域）");
    }
    {
        rta::audio::ThreeLayer unknown{};
        auto v = rta::audio::three_layer_verdict(unknown);
        ck(!v.ok, "三层读数未知 => 判否（不许拿未知当通过）");
    }
    {
        // AUHAL 语义：虚拟层 float32 是架构（真机 Pocket Master 实测），不应判否；
        // 但仍要求三层同率 + 物理层整数。
        rta::audio::ThreeLayer auhal{};
        auhal.known = true; auhal.nominalRate = 44100; auhal.virtualRate = 44100; auhal.physicalRate = 44100;
        auhal.virtualInt = false; auhal.physicalInt = true; auhal.physicalBits = 16;
        auhal.srcRate = 44100; auhal.srcBits = 16; auhal.requireVirtualInt = false;
        auto v = rta::audio::three_layer_verdict(auhal);
        ck(v.ok, "AUHAL 虚拟层 float32 是架构 => 仍通过（三层同率 + 物理整数）");
        auhal.nominalRate = 48000;
        auto v2 = rta::audio::three_layer_verdict(auhal);
        ck(!v2.ok, "AUHAL 语义下 nominal 被改回去仍必须判否");
    }
    std::printf("\n%s (%d failures)\n", fails ? "RED" : "GREEN", fails);
    return fails ? 1 : 0;
}
