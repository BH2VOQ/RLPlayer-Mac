// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// dop_silence_fill.h — DoP 平台层安全辅助（纯函数，实时安全，可离线测）
//
// ============================ 为什么需要这个文件 ============================
// DoP v1.1 把 16 个 DSD 位装进一个 24-bit PCM 容器，并靠**高 8 位的 0x05 / 0xFA
// 逐样本交替标记**让接收端认出"这是 DSD，不是 PCM"。
//
// 只要有一段填充是"裸零"，那段的标记就是 0x00 ⟹ 接收端判非法 DoP ⟹ 掉锁、
// 继电器动作、爆音，甚至退回 PCM 播放（刺耳白噪）。而这个填充**一定会发生**：
//   * 设备拉数据比供料快（USB 抖动 / 系统负载 / 网络端点）⟹ 欠载补静音；
//   * 曲末不足一个设备周期 ⟹ 尾部补静音。
// 基线 227de23 两处都用 memset(0)：平台层 CoreAudio 的欠载分支、引擎层 render_loop 的尾块。
//
// ============================ 判据（铁律 3）============================
// 有效 DoP 静音的充要条件，逐帧检查：
//   1. 每声道高字节（bit16..23）只能是 0x05 或 0xFA；
//   2. 相邻帧的标记必须**不同**（A,B,A,B…），重复会被判非法；
//   3. 同一帧内各声道标记必须**一致**（DoP 要求声道对齐）；
//   4. 低 16 位是 DSD 静音位型（本项目统一 0x5555，与 DirectSDM 的 append_silence 同源）。
// 只断言"没崩"或"非零"都证明不了这些 —— 必须逐条打。
//
// ==================== 1.1.2 增补：渲染相位与增益闸（P0-3 后续） ====================
// 相位（marker phase）曾经由**生产者**（write 回调）记："最后一帧入队的是 0x05 ⟹ 下一帧用 0xFA"。
// 只要环里还留着**更旧的未渲染帧**，这个推断就是错的（部分渲染/欠载后的真实场景）：
//   已渲染到 0xFA，环里还剩 0x05…，生产者却按"已入队的最后一帧"算出下一帧 = 0xFA
//   ⟹ 欠载填充的第一帧与刚渲染出去的最后一帧**同标记** ⟹ 接收端判非法。
// 正确来源只有一个：**本端真正渲染出去的最后一帧**。相位因此归渲染线程独占
// （DopPhase::next），生产者线程不再参与读写，跨线程的可写相位字节消失。
//
// 另外两条纵深防御（同样纯函数、可离线测）：
//   * 增益：DoP 下任何非 1.0 的数字增益都会改写 24-bit 字（包括承载标记的高 8 位）
//     ⟹ 渲染路径无条件按 1.0 输出，并把这次请求如实计数（DopPeriodStats::gainIgnored）。
//   * 标记校正：每帧输出的 marker 字节按**本端相位**写死，输入标记只用于
//     "相位未知时接管"与异常计数。低 16 位（真正的 DSD 数据）一个 bit 都不动。
//
// 🔴 实时安全：无分配、无锁、无系统调用、无异常；可在 CoreAudio 渲染回调里直接调用。
//    诊断计数器是 relaxed 原子，且只在**异常帧**上自增，正常路径零额外开销。
#pragma once
#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>

namespace rta::platform::macos {

inline constexpr uint8_t kDopMarkerA = 0x05;
inline constexpr uint8_t kDopMarkerB = 0xFA;
// DSD 静音位型：0x55 字节 = 01010101，是 DSD 侧最常用的静音/极低电平图样。
// 注意：0x5555 的**位模式本身就逐位交替**，所以它已经是零直流；反相的 0xAAAA 同样零直流。
// 因此"恒 0x5555 会产生直流偏移"这个说法是错的（见 .agents/112-release-dop-safe.md 的证伪清单）。
inline constexpr uint16_t kDopSilencePayload = 0x5555;

// 一个标记是否合法（0x05 / 0xFA）。0x00 及其它值一律非法。
inline bool dop_marker_legal(uint8_t marker) {
    return marker == kDopMarkerA || marker == kDopMarkerB;
}

// 把一个标记翻到另一个（输入非法值时回到 A，绝不产生 0x00）。
inline uint8_t dop_next_marker(uint8_t marker) {
    return (marker == kDopMarkerA) ? kDopMarkerB : kDopMarkerA;
}

// ---------------------------------------------------------------------------
// DoP 渲染相位（**渲染线程独占**；生产者线程绝不读写）
// ---------------------------------------------------------------------------
// next == 0 表示"本端还没输出过任何帧"：此时第一帧**接管**输入标记（直通时与上游逐字节
// 一致），输入标记非法则从 A 起。
struct DopPhase {
    uint8_t next = 0;
    // 诊断计数（只在异常帧上自增；relaxed 原子，读侧无需加锁）
    std::atomic<uint64_t> rephased{0};      // 相位不连续 ⟹ 标记字节被改写的帧数
    std::atomic<uint64_t> invalidMarker{0}; // 输入标记既非 0x05 也非 0xFA 的帧数
    std::atomic<uint64_t> channelFixed{0};  // 同帧各声道标记不一致、被对齐的帧数

    // 重新开流时归零（原子的存在使结构体不可拷贝/赋值 ⟹ 统一走 reset()）。
    void reset() {
        next = 0;
        rephased.store(0, std::memory_order_relaxed);
        invalidMarker.store(0, std::memory_order_relaxed);
        channelFixed.store(0, std::memory_order_relaxed);
    }
    // 诊断快照（可跨线程读，取的是某一瞬间的值，不保证原子一致性 —— 仅用于日志/自证）。
    struct Snapshot {
        uint8_t next = 0;
        uint64_t rephased = 0;
        uint64_t invalidMarker = 0;
        uint64_t channelFixed = 0;
    };
    Snapshot snapshot() const {
        Snapshot s;
        s.next = next;
        s.rephased = rephased.load(std::memory_order_relaxed);
        s.invalidMarker = invalidMarker.load(std::memory_order_relaxed);
        s.channelFixed = channelFixed.load(std::memory_order_relaxed);
        return s;
    }
};

// 一次 IO 周期的结果（供调用方推进环形缓冲读指针与统计）。
struct DopPeriodStats {
    size_t written = 0;       // 从环形缓冲消费并写出的真实帧数
    size_t silenced = 0;      // 补写的合法 DoP 静音帧数
    bool gainIgnored = false; // 本次是否有非 1.0 增益被 DoP 拒绝（纵深防御触发）
};

// 把一帧（24-bit 小端交错，channels 个样本）的 marker 字节对齐到本端相位。
// 🔴 只碰每声道第 3 个字节；低 16 位（DSD 数据）由调用方负责，这里绝不修改。
// 返回 true 表示本帧有字节被改写（只用于统计，不影响音频数据）。
inline bool dop_align_frame_markers(uint8_t* frame, size_t channels, DopPhase& phase) {
    if (!frame || channels == 0) return false;

    // 先记录**输入**（上游写的）标记，再统一改写 —— 顺序不能反，否则接管与分类都失真。
    const uint8_t in0 = frame[2];
    bool bad = false, disagreed = false;
    for (size_t c = 0; c < channels; ++c) {
        const uint8_t m = frame[c * 3 + 2];
        if (!dop_marker_legal(m)) bad = true;
        else if (c > 0 && m != in0) disagreed = true;
    }

    // 相位未知（本端还没输出过帧）：接管上游首声道标记；上游非法则从 A 起（绝不写 0x00）。
    const uint8_t want = dop_marker_legal(phase.next) ? phase.next
                                                      : (dop_marker_legal(in0) ? in0 : kDopMarkerA);

    bool changed = false;
    for (size_t c = 0; c < channels; ++c) {
        uint8_t& m = frame[c * 3 + 2];
        if (m != want) {
            m = want;
            changed = true;
        }
    }
    if (bad) phase.invalidMarker.fetch_add(1, std::memory_order_relaxed);
    else if (changed) {
        if (disagreed) phase.channelFixed.fetch_add(1, std::memory_order_relaxed);
        else phase.rephased.fetch_add(1, std::memory_order_relaxed);
    }
    phase.next = dop_next_marker(want);
    return changed;
}

// 按 24-bit 小端交错布局写 `frames` 帧合法 DoP 静音。
//   dst        目标缓冲（必须至少 frames * channels * 3 字节）
//   frames     帧数
//   channels   声道数
//   marker_io  输入：本段第一帧该用的标记（0 = 从 A 开始）；输出：下一帧该用的标记
// 调用方用同一个 marker_io 接力，就能保证跨段、跨欠载仍严格交替。
inline void fill_dop_silence_24le(uint8_t* dst, size_t frames, size_t channels,
                                  uint8_t& marker_io) {
    if (!dst || channels == 0) return;
    uint8_t marker = dop_marker_legal(marker_io) ? marker_io : kDopMarkerA;
    const uint8_t lo = (uint8_t)(kDopSilencePayload & 0xFFu);
    const uint8_t hi = (uint8_t)((kDopSilencePayload >> 8) & 0xFFu);
    for (size_t f = 0; f < frames; ++f) {
        uint8_t* frame = dst + f * channels * 3;
        for (size_t c = 0; c < channels; ++c) {
            frame[c * 3 + 0] = lo;
            frame[c * 3 + 1] = hi;
            frame[c * 3 + 2] = marker;
        }
        marker = dop_next_marker(marker);
    }
    marker_io = marker;
}

// ---------------------------------------------------------------------------
// 生产渲染路径的**唯一实现**（CoreAudioOutput::render() 直接调用；测试调用同一份）
// ---------------------------------------------------------------------------
// 写一个 IO 周期的 24-bit DoP 数据：
//   out          设备缓冲（24-bit 小端交错，outFrames * channels * 3 字节）
//   outFrames    设备本次请求的帧数（= mDataByteSize / 每帧字节数）
//   ring         环形缓冲（int32 交错，低位对齐到 24 bit）
//   ringCapacity 环容量（帧）；0 表示未初始化 ⟹ 一帧都不写（绝不除零、绝不越界）
//   ringStart    本次从环里第几帧开始读
//   available    环里当前可读帧数
//   channels     声道数
//   gain         调用方原本要施加的**线性**增益
//   phase        渲染相位（跨周期保持；只由渲染线程使用）
//
// 行为契约（逐条钉死在 tests/test_dop_underrun_fill.cpp [6]~[11]）：
//   1. 增益恒按 1.0：DoP 下非单位增益会改写承载标记的高 8 位 ⟹ 一律忽略并置 gainIgnored。
//   2. 真实帧只写 min(outFrames, available) 帧；低 16 位逐位取自环，绝不改动。
//   3. 每帧 marker 字节按本端相位写（严格 A,B,A,B…），相位跨周期、跨欠载连续。
//   4. 不足部分补**合法 DoP 静音**（payload 0x5555），绝不是裸零。
inline DopPeriodStats dop_write_period_24le(uint8_t* out, size_t outFrames,
                                            const int32_t* ring, size_t ringCapacity,
                                            size_t ringStart, size_t available,
                                            size_t channels, double gain,
                                            DopPhase& phase) {
    DopPeriodStats st;
    if (!out || outFrames == 0 || channels == 0) return st;
    if (!ring || ringCapacity == 0) return st;

    // ---- 纵深防御①：DoP 没有"小声一点"，只有"载波完好"与"彻底坏掉" ----
    if (gain != 1.0) st.gainIgnored = true;

    const size_t frameBytes = channels * 3;
    const size_t take = std::min(outFrames, available);
    for (size_t i = 0; i < take; ++i) {
        const int32_t* s = ring + ((ringStart + i) % ringCapacity) * channels;
        uint8_t* frame = out + i * frameBytes;
        for (size_t c = 0; c < channels; ++c) {
            const uint32_t v = (uint32_t)s[c] & 0xFFFFFFu;
            frame[c * 3 + 0] = (uint8_t)(v & 0xFFu);
            frame[c * 3 + 1] = (uint8_t)((v >> 8) & 0xFFu);
            frame[c * 3 + 2] = (uint8_t)((v >> 16) & 0xFFu); // 先照抄，下面统一校正到本端相位
        }
        dop_align_frame_markers(frame, channels, phase);
    }
    st.written = take;

    // ---- 纵深防御②：欠载/尾块补合法 DoP 静音，相位接着最后写出的真实帧 ----
    if (take < outFrames) {
        st.silenced = outFrames - take;
        fill_dop_silence_24le(out + take * frameBytes, st.silenced, channels, phase.next);
    }
    return st;
}

// 校验一段 24-bit 小端交错的 DoP 数据是否为合法标记序列（测试与诊断用）。
// 返回第一个不合法帧号，全部合法返回 frames。first_marker 指出首帧标记（可为 nullptr）。
inline size_t dop_find_invalid_frame(const uint8_t* src, size_t frames, size_t channels,
                                     uint8_t expected_first, uint8_t* first_marker = nullptr,
                                     bool* channel_mismatch = nullptr) {
    if (channel_mismatch) *channel_mismatch = false;
    if (!src || channels == 0) return frames;
    uint8_t marker = dop_marker_legal(expected_first) ? expected_first : kDopMarkerA;
    if (first_marker) *first_marker = marker;
    for (size_t f = 0; f < frames; ++f) {
        const uint8_t* frame = src + f * channels * 3;
        const uint8_t m0 = frame[2];
        if (!dop_marker_legal(m0)) return f;
        if (m0 != marker) return f;
        for (size_t c = 1; c < channels; ++c) {
            if (frame[c * 3 + 2] != m0) {
                if (channel_mismatch) *channel_mismatch = true;
                return f;
            }
        }
        marker = dop_next_marker(marker);
    }
    return frames;
}

} // namespace rta::platform::macos
