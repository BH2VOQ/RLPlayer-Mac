// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// dop_padding.h — DoP (DSD over PCM) v1.1 尾块与欠载静音帧填充纯函数（1.1.2 P0-3）
//
// ============================ 为什么需要这个文件 ============================
// DoP v1.1 将 16-bit DSD 流封装进 24-bit PCM 容器（高 8 位放 0x05 / 0xFA 交替标记）。
// 接收端 DAC 严格依赖高 8 位标记在相邻帧之间严格交替来识别 DoP 流并维持 DSD 解码锁。
//
// 缺陷事实（P0-3）：
//   在 render_loop.h 的 EOS / 尾块处理中：
//     if (eos && pendFrames > 0 && pendFrames < period && !padded) {
//         pend.resize(period * outCh, 0);
//     }
//   当 h.dop = true 时，直接 resize 补全 0 会让 24-bit 容器的高 8 位标记全部变为 0x00。
//   接收端 DAC 检测到 0x00 标记判定为非法 DoP，导致每首歌结尾发生继电器频繁动作、
//   突发静音甚至爆音/白噪声。
//
// 本文件提供无副作用的纯函数：
//   1. 标记严格交替：0x05 / 0xFA 逐帧交替，禁止连续两个相同标记；
//   2. payload 合法：DSD 50% 密度静音位型（0x5555 / 0xAAAA 交替）；
//   3. 声道一致：同一帧内各声道 marker 与 payload 完全对齐；
//   4. 相位可继续：输入输出相位引用，跨块跨调用无缝接力。
//
// =========================================================================
// rtaweb.cpp 接线示例（供主控集成参考，本任务不改动 rtaweb.cpp）：
// =========================================================================
// 在 tools/rtaweb.cpp 的 play_one() 中配置 RenderHost h 时：
//
//   // 保持流的 DoP 填充相位（初始为 true = 0x05；若已有 packSt.phaseA[0]，也可直接对齐）：
//   bool dopPhaseA = packSt.phaseA.empty() ? true : (packSt.phaseA[0] != 0);
//   h.dopPadFrames = [&dopPhaseA](std::vector<int32_t>& pend, size_t outCh, size_t needFrames) {
//       rta::audio::append_dop_silence_frames(pend, outCh, needFrames, dopPhaseA);
//   };
//
// 这样在 render_loop 的 EOS 尾块不足一个周期时，会自动调用该钩子追加合法 DoP 静音，
// 而不是用裸零破坏 DoP 标记。
// =========================================================================

#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace rta::audio {

// DoP v1.1 标记常量
inline constexpr uint8_t kDopMarkerA = 0x05;
inline constexpr uint8_t kDopMarkerB = 0xFA;

// DSD 静音位型（1-bit 01010101 与 10101010 互为反相，均对应 50% 密度的模拟零电平）
inline constexpr uint16_t kDopSilencePayloadA = 0x5555;
inline constexpr uint16_t kDopSilencePayloadB = 0xAAAA;

// 计算下一个 DoP 标记（严格反相，输入非法标记时保守重置为 A，绝不产生 0x00）
inline uint8_t dop_next_marker(uint8_t marker) {
    return (marker == kDopMarkerA) ? kDopMarkerB : kDopMarkerA;
}

// 构造单个 24-bit DoP 静音样本并进行 32-bit 符号扩展
// phaseA 为 true 时：marker = 0x05, payload = 0x5555 -> 0x00055555
// phaseA 为 false 时：marker = 0xFA, payload = 0xAAAA -> 0xFFFAAAAA（bit 23 符号扩展）
inline int32_t make_dop_silence_sample(bool phaseA) {
    const uint32_t marker = (uint32_t)(phaseA ? kDopMarkerA : kDopMarkerB) << 16;
    const uint32_t payload = (uint32_t)(phaseA ? kDopSilencePayloadA : kDopSilencePayloadB);
    int32_t v = (int32_t)(marker | payload);
    if (v & 0x800000) {
        v |= (int32_t)0xFF000000; // 24-bit 符号扩展至 32-bit int
    }
    return v;
}

// 从 24-bit / 32-bit 样本中提取 8-bit DoP marker
inline uint8_t extract_dop_marker(int32_t sample) {
    return (uint8_t)(((uint32_t)sample >> 16) & 0xFFu);
}

// 从 24-bit / 32-bit 样本中提取 16-bit DSD payload
inline uint16_t extract_dop_payload(int32_t sample) {
    return (uint16_t)((uint32_t)sample & 0xFFFFu);
}

// 纯函数：向 dst 指针写入 frames 帧交错的合法 DoP 静音数据
// dst 必须至少容纳 frames * channels 个 int32_t 元素
// phaseA_inout: 输入起始相位（true=0x05, false=0xFA），返回下一帧的起始相位
inline void generate_dop_silence_frames(int32_t* dst, size_t channels, size_t frames, bool& phaseA_inout) {
    if (!dst || channels == 0 || frames == 0) return;
    bool curPhase = phaseA_inout;
    for (size_t f = 0; f < frames; ++f) {
        const int32_t sample = make_dop_silence_sample(curPhase);
        for (size_t c = 0; c < channels; ++c) {
            dst[f * channels + c] = sample;
        }
        curPhase = !curPhase;
    }
    phaseA_inout = curPhase;
}

// 纯函数：向 vector 追加 frames 帧交错的合法 DoP 静音数据
// phaseA_inout: 输入起始相位，返回下一帧的起始相位（实现跨块接力，禁止连续两个相同标记）
inline void append_dop_silence_frames(std::vector<int32_t>& pend, size_t channels, size_t frames, bool& phaseA_inout) {
    if (channels == 0 || frames == 0) return;
    const size_t oldSize = pend.size();
    pend.resize(oldSize + frames * channels);
    generate_dop_silence_frames(pend.data() + oldSize, channels, frames, phaseA_inout);
}

// 以 uint8_t marker 作为状态的重载（marker 为 0x05 或 0xFA）
inline void append_dop_silence_frames(std::vector<int32_t>& pend, size_t channels, size_t frames, uint8_t& marker_inout) {
    bool phaseA = (marker_inout != kDopMarkerB);
    append_dop_silence_frames(pend, channels, frames, phaseA);
    marker_inout = phaseA ? kDopMarkerA : kDopMarkerB;
}

} // namespace rta::audio
