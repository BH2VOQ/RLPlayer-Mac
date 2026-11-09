// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// phys_format.h —— 「能不能锁到源格式原样的硬件物理格式」的唯一判据（纯函数）
//
// 为什么需要它（2026-11-09，用户追问「HQPlayer 明明能做到 bit-perfect」）：
//   在此之前，独占路径写的是 kAudioDevicePropertyStreamFormat —— 那是 **HAL 虚拟/混音层**，
//   硬件真正跑的格式是 kAudioStreamPropertyPhysicalFormat。两层不一致时 HAL 会做一次转换
//   （采样率转换 或 int→float32），位流已被改动，但代码从未读过物理层，
//   于是 bit_perfect() 照样报 true。
//
//   本机只读实测（未播放任何声音）：
//     · Pocket Master (USB)   物理层只有 44100/16 整数  ← 整数直通可行
//     · M140F2 (DisplayPort)  物理层 21 档，全整数 24/20 ← 整数直通可行
//     · Mac mini 扬声器        物理层只有 float32        ← 无整数通路
//     · Oray 虚拟设备          物理层只有 float32        ← 无整数通路
//   四台设备物理层 settable 全为 YES ⟹ 锁定这条路是通的，只是此前没走。
//
// 判据（任何一条不满足 ⟹ 不能宣称逐位直通）：
//   1. 采样率必须**完全等于**源采样率 —— 不等就是让 HAL 重采样，采样点已不是原值
//   2. 位深不能低于源真实位深 —— 降位深是真实信息丢失
//   3. 端点必须提供**整数**物理格式。只有 float32 的端点一律判否：即使 24 bit 以内的
//      整数值在 IEEE-754 尾数里可精确表示，DAC 侧仍存在一次不可观测的转换，
//      「数值相等」不等于「送到转换器的是同一串位」。用户明确要求「不能是接近」。
// 允许：设备整数位深高于源位深（低位补零，数值逐个不变），但必须标记 zeroPad 以便如实告知。
#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace rta::audio {

// 一个设备物理格式候选（来自 kAudioStreamPropertyAvailablePhysicalFormats）
struct PhysFormat {
    uint32_t rate = 0;
    int      bits = 0;
    bool     isFloat = false;
};

struct PhysPick {
    bool       ok = false;        // 能否锁到「源格式原样」的整数物理格式
    PhysFormat pick{};            // 选中的物理格式（ok=true 时有效）
    bool       zeroPad = false;   // 设备位深 > 源位深（低位补零，数值不变）
    bool       floatOnly = false; // 该采样率下只有浮点格式（区分「没有这档率」与「只有浮点」）
    std::string why;              // ok=false 时是拒绝理由；ok=true 且有话要说时是说明
};

// 选择策略：
//   · 采样率必须精确相等（绝不重采样）
//   · 位深：优先精确相等；否则取「大于源位深且最小」的那一档（补零）
//   · 该采样率下没有整数格式（只有 float）⟹ 拒绝，floatOnly=true
//   · 该采样率下什么都没有 ⟹ 拒绝，floatOnly=false
inline PhysPick pick_physical_format(const std::vector<PhysFormat>& avail,
                                     uint32_t srcRate, int srcBits) {
    PhysPick r;
    if (srcRate == 0 || srcBits <= 0) {
        r.why = "源采样率或位深未知，无法确认设备物理格式";
        return r;
    }
    if (avail.empty()) {
        r.why = "读不到设备的可用物理格式列表";
        return r;
    }

    bool sawRate = false;
    bool sawIntAtRate = false;
    bool sawFloatAtRate = false;
    int  bestExact = -1;
    int  bestAbove = -1;

    for (const PhysFormat& f : avail) {
        if (f.rate != srcRate) continue;
        sawRate = true;
        if (f.isFloat) { sawFloatAtRate = true; continue; }
        if (f.bits <= 0) continue;
        sawIntAtRate = true;
        if (f.bits == srcBits) {
            if (bestExact < 0 || f.bits < bestExact) bestExact = f.bits;
        } else if (f.bits > srcBits) {
            if (bestAbove < 0 || f.bits < bestAbove) bestAbove = f.bits;
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
        r.ok = true;
        r.pick = PhysFormat{srcRate, bestExact, false};
        return r;
    }
    if (bestAbove > 0) {
        r.ok = true;
        r.pick = PhysFormat{srcRate, bestAbove, false};
        r.zeroPad = true;
        r.why = std::to_string(srcBits) + "→" + std::to_string(bestAbove) +
                " bit 低位补零，数值逐个不变";
        return r;
    }
    r.why = "设备在此采样率下的整数物理格式位深低于源位深（" +
            std::to_string(srcBits) + " bit），会丢有效位";
    return r;
}

}  // namespace rta::audio
