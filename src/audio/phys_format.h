// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// phys_format.h —— 「能不能锁到源格式原样的硬件物理格式」的唯一判据（纯函数）
//
// 2026-11-10 吸收 HQPlayer 5.13 反编译结论：HQPlayer 把 nsrt/sfmt/pft 三层全锁到
// 与源一致的整数 PCM，带 SignedInteger(0x4) 与 NonMixable(0x40)。本机只读实测：
// Pocket Master 物理层同时有 44100/16 int 的 0x0c（可混音）与 0x4c（NonMixable）两档，
// 旧 make_int_asbd 写死 0x0c，正好选中可混音档。
//
// 边界（受控探针实测，未启 IOProc、未写样本、已还原）：0x40 是 HAL 在启动 IOProc 时
// 隐式进入的模式状态，不是应用能持久写入/必须读回的属性位。五种写法读回全是
// 0x09/0x0c，0x40 被清掉，Hog owner 恒 -1。所以只做「优先选带标志的 available 档」，
// 绝不把「读回必须带 0x40」做成硬判据 —— 那会假红且语义错误。
#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace rta::audio {

struct PhysFormat {
    uint32_t rate = 0;
    int      bits = 0;
    bool     isFloat = false;
    bool     nonMixable = false;   // 该档 available ASBD 是否带 0x40（只用于优先选取）
    uint32_t flags = 0;            // 原始 mFormatFlags（用于原样写回）
};

struct PhysPick {
    bool       ok = false;
    PhysFormat pick{};
    bool       zeroPad = false;
    bool       floatOnly = false;
    bool       nonMixable = false;
    std::string why;
};

struct ThreeLayer {
    bool     known = false;
    uint32_t nominalRate = 0;
    uint32_t virtualRate = 0;
    uint32_t physicalRate = 0;
    bool     virtualInt = false;
    bool     physicalInt = false;
    int      physicalBits = 0;
    uint32_t srcRate = 0;
    int      srcBits = 0;
    // true = 裸 IOProc / HQPlayer 语义（sfmt 必须整数）；
    // false = AUHAL 语义：HAL 虚拟层恒为 float32 是架构而非降级，
    //         仍严格核对三层同率 + 物理层整数 + 物理位深。
    bool     requireVirtualInt = true;
};

struct LayerVerdict {
    bool        ok = false;
    std::string why;
};

// 三层同率 + 整数自证。每次查询重读 nominal rate，播放中被改回去可发现。
inline LayerVerdict three_layer_verdict(const ThreeLayer& x) {
    LayerVerdict v;
    if (!x.known) { v.why = "设备三层格式读数未知（无法确认同率与整数容器）"; return v; }
    if (x.srcRate == 0 || x.srcBits <= 0) { v.why = "源采样率或位深未知"; return v; }
    if (x.nominalRate != x.srcRate || x.virtualRate != x.srcRate || x.physicalRate != x.srcRate) {
        v.why = "三层采样率不一致（nominal=" + std::to_string(x.nominalRate) +
                " virtual=" + std::to_string(x.virtualRate) +
                " physical=" + std::to_string(x.physicalRate) +
                " src=" + std::to_string(x.srcRate) + " Hz）：HAL 会重采样，不能逐位直通";
        return v;
    }
    if (x.requireVirtualInt && !x.virtualInt) {
        v.why = "HAL 虚拟层为浮点格式（经混音域），不是整数逐位通路"; return v;
    }
    if (!x.physicalInt) { v.why = "设备物理层为浮点格式，不存在整数逐位直通通路"; return v; }
    if (x.physicalBits < x.srcBits) {
        v.why = "物理位深 " + std::to_string(x.physicalBits) + " bit 低于源 " +
                std::to_string(x.srcBits) + " bit，会丢有效位";
        return v;
    }
    v.ok = true;
    return v;
}

inline PhysPick pick_physical_format(const std::vector<PhysFormat>& avail,
                                     uint32_t srcRate, int srcBits) {
    PhysPick r;
    if (srcRate == 0 || srcBits <= 0) { r.why = "源采样率或位深未知，无法确认设备物理格式"; return r; }
    if (avail.empty()) { r.why = "读不到设备的可用物理格式列表"; return r; }
    bool sawRate = false, sawIntAtRate = false, sawFloatAtRate = false;
    int  bestExact = -1, bestAbove = -1;
    PhysFormat exactPick{}, abovePick{};
    for (const PhysFormat& f : avail) {
        if (f.rate != srcRate) continue;
        sawRate = true;
        if (f.isFloat) { sawFloatAtRate = true; continue; }
        if (f.bits <= 0) continue;
        sawIntAtRate = true;
        if (f.bits == srcBits) {
            if (bestExact < 0 || f.bits < bestExact ||
                (f.bits == bestExact && f.nonMixable && !exactPick.nonMixable)) {
                bestExact = f.bits; exactPick = f;
            }
        } else if (f.bits > srcBits) {
            if (bestAbove < 0 || f.bits < bestAbove) { bestAbove = f.bits; abovePick = f; }
        }
    }
    if (!sawRate) {
        r.why = "设备物理层没有 " + std::to_string(srcRate) +
                " Hz 这一档（锁物理格式才能避免 HAL 重采样，此处不做静默转换）";
        return r;
    }
    if (!sawIntAtRate) {
        r.floatOnly = sawFloatAtRate;
        r.why = "端点物理层只有浮点格式（float32），不存在整数逐位直通通路";
        return r;
    }
    if (bestExact > 0) {
        r.ok = true; r.pick = exactPick; r.nonMixable = exactPick.nonMixable;
        return r;
    }
    if (bestAbove > 0) {
        r.ok = true; r.pick = abovePick; r.nonMixable = abovePick.nonMixable;
        r.zeroPad = true;
        r.why = std::to_string(srcBits) + "→" + std::to_string(bestAbove) + " bit 低位补零，数值逐个不变";
        return r;
    }
    r.why = "设备在此采样率下的整数物理格式位深低于源位深（" +
            std::to_string(srcBits) + " bit），会丢有效位";
    return r;
}

}  // namespace rta::audio
