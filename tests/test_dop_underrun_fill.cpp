// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_dop_underrun_fill.cpp — 1.1.2 P0-3：欠载/尾块补全必须是**合法 DoP 静音**
//
// ============================ 这个测试在证明什么 ============================
// 基线 227de23 的 CoreAudio 渲染回调在欠载时执行 std::memset(out, 0, …)。
// DoP 的 24-bit 容器高 8 位是 0x05/0xFA 交替标记，裸零把标记变成 0x00 ⟹
// 接收端判非法 DoP：掉锁、继电器动作、爆音，甚至退回 PCM 出白噪。
//
// 旧判据为什么抓不到：既没有测试覆盖"欠载补什么内容"，也没有离线可调用的实现
// （补零写在 CoreAudio 实时回调里，只能真开设备才能触发 —— 而铁律 1 不允许）。
// 本轮把填充抽成纯函数 dop_silence_fill.h，于是可以逐帧断言：
//   1. 标记只可能是 0x05 / 0xFA（**绝不能**是 0x00）
//   2. 相邻帧标记严格交替（A,B,A,B…），重复即非法
//   3. 同帧各声道标记一致
//   4. payload 为约定的 0x5555
//   5. 跨段接力：第二段接着第一段的相位，不重置、不重复
// 这些是 DoP 合法性的定义本身，不是"看起来非零"这种弱判据。
//
// 🔴 铁律 1：纯内存运算，不开设备、不出声、不读用户文件。
#include "platform/macos/dop_silence_fill.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using namespace rta::platform::macos;

static int g_fail = 0;
static int g_total = 0;

static void ck(bool ok, const std::string& what, const std::string& detail = "") {
    ++g_total;
    if (!ok) ++g_fail;
    std::printf("  [%s] %s%s%s\n", ok ? "PASS" : "FAIL", what.c_str(),
                detail.empty() ? "" : "  ", detail.c_str());
}

// ---------------- 真实 DoP 数据构造（用于驱动生产渲染 helper）----------------
// 与生产端（src/dsp/dop.h::dop_pack）同构：
//   * 每帧每声道 = 24-bit 字：高 8 位标记（0x05/0xFA 交替）+ 低 16 位 DSD 数据；
//   * 标记相位按**帧号**交替（同帧各声道一致），payload 逐帧逐声道不同；
//   * 24-bit 语义按生产端做符号扩展（0xFAxxxx 是负数），用来顺带验证 helper 的 `& 0xFFFFFF`。
static uint8_t marker_of(size_t frameIdx) {
    return (frameIdx % 2 == 0) ? kDopMarkerA : kDopMarkerB;
}

static uint16_t payload_of(size_t frameIdx, size_t channel) {
    return (uint16_t)((0x1234u + (uint32_t)frameIdx * 37u + (uint32_t)channel * 0x0101u) & 0xFFFFu);
}

static int32_t make_dop_sample(size_t frameIdx, uint16_t payload) {
    uint32_t v = ((uint32_t)marker_of(frameIdx) << 16) | (uint32_t)payload;
    if (v & 0x800000u) v |= 0xFF000000u;   // 24-bit 符号扩展（与 dop_pack 一致）
    return (int32_t)v;
}

int main() {
    std::printf("=== DoP 欠载/尾块填充合法性 ===\n");

    // ---- 1. 单段：标记只允许 0x05/0xFA，且严格交替 ----
    std::printf("\n[1] 单段 32 帧 / 2 声道\n");
    {
        const size_t frames = 32, ch = 2;
        std::vector<uint8_t> buf(frames * ch * 3, 0xEE);   // 预填非零脏值，能抓到"没写满"
        uint8_t marker = 0;
        fill_dop_silence_24le(buf.data(), frames, ch, marker);
        const size_t bad = dop_find_invalid_frame(buf.data(), frames, ch, kDopMarkerA);
        ck(bad == frames, "无非法帧（标记∈{0x05,0xFA} 且严格交替）",
           "first_bad=" + std::to_string(bad));
        bool anyZero = false, payloadBad = false;
        for (size_t f = 0; f < frames; ++f) {
            for (size_t c = 0; c < ch; ++c) {
                const uint8_t* s = &buf[(f * ch + c) * 3];
                if (s[2] == 0x00) anyZero = true;
                const uint16_t payload = (uint16_t)(s[0] | ((uint16_t)s[1] << 8));
                if (payload != kDopSilencePayload) payloadBad = true;
            }
        }
        ck(!anyZero, "不存在 0x00 标记（这正是旧 memset(0) 的缺陷）");
        ck(!payloadBad, "payload 全为 0x5555");
        ck(marker == ((frames % 2) ? kDopMarkerB : kDopMarkerA),
           "返回的下一帧标记与帧数奇偶一致", "next=" + std::to_string((int)marker));
        ck(buf[2] == kDopMarkerA, "首帧标记为 A(0x05)");
    }

    // ---- 2. 首帧从 B 开始也必须合法（接力场景）----
    std::printf("\n[2] 首帧从 B(0xFA) 开始\n");
    {
        const size_t frames = 8, ch = 1;
        std::vector<uint8_t> buf(frames * ch * 3, 0);
        uint8_t marker = kDopMarkerB;
        fill_dop_silence_24le(buf.data(), frames, ch, marker);
        ck(buf[2] == kDopMarkerB, "首帧标记为 B(0xFA)");
        ck(dop_find_invalid_frame(buf.data(), frames, ch, kDopMarkerB) == frames,
           "从 B 起算仍然严格交替");
    }

    // ---- 3. 跨段接力：两段拼起来必须仍然交替（不能每段都从 A 重来）----
    std::printf("\n[3] 跨段接力（3 段 × 5 帧，奇数帧长最容易暴露重置缺陷）\n");
    {
        const size_t ch = 2;
        std::vector<uint8_t> all;
        uint8_t marker = 0;
        for (int seg = 0; seg < 3; ++seg) {
            const size_t frames = 5;
            std::vector<uint8_t> part(frames * ch * 3, 0);
            fill_dop_silence_24le(part.data(), frames, ch, marker);
            all.insert(all.end(), part.begin(), part.end());
        }
        const size_t total = all.size() / (ch * 3);
        const size_t bad = dop_find_invalid_frame(all.data(), total, ch, kDopMarkerA);
        ck(bad == total, "三段拼接后整体仍严格交替", "first_bad=" + std::to_string(bad));
        // 反证：如果每段都重置相位，第 5 帧与第 6 帧会是同相 → 必被抓出
        ck(dop_find_invalid_frame(all.data(), total, ch, kDopMarkerB) != total,
           "反证：用错误的首相位去校验必须判非法（判据本身有分辨力）");
    }

    // ---- 4. 反例：模拟旧行为 memset(0)，校验器必须当场判红 ----
    // 这条是"判据能不能抓真问题"的自证：如果它也能过，那整个测试就没意义。
    std::printf("\n[4] 反例自证：裸零填充必须被判非法\n");
    {
        const size_t frames = 16, ch = 2;
        std::vector<uint8_t> zeros(frames * ch * 3, 0);
        const size_t bad = dop_find_invalid_frame(zeros.data(), frames, ch, kDopMarkerA);
        ck(bad == 0, "全零缓冲在第 0 帧就被判非法", "first_bad=" + std::to_string(bad));
    }

    // ---- 5. 多声道一致性：8 声道时同帧标记必须相同 ----
    std::printf("\n[5] 8 声道\n");
    {
        const size_t frames = 7, ch = 8;
        std::vector<uint8_t> buf(frames * ch * 3, 0);
        uint8_t marker = 0;
        fill_dop_silence_24le(buf.data(), frames, ch, marker);
        bool mismatch = false;
        const size_t bad = dop_find_invalid_frame(buf.data(), frames, ch, kDopMarkerA, nullptr, &mismatch);
        ck(bad == frames && !mismatch, "8 声道全部合法且同帧标记一致",
           "first_bad=" + std::to_string(bad));
    }

    // =====================================================================================
    // 6~11：生产渲染路径（dop_write_period_24le）
    //
    // 这几段测的是**生产代码本身**（CoreAudioOutput::render() 在 DoP 下逐行调用的就是它），
    // 不是另写一份"像生产"的模拟。判据全部落在**实际字节**上：
    //   标记字节逐帧、低 16 位 payload 逐声道、缓冲区边界（canary）、跨周期相位。
    // 只断言"written>0 / 没崩"是证明不了 DoP 合法性的（铁律 3）。
    // =====================================================================================
    std::printf("\n[6] 生产渲染 helper：真实 payload + 边界 canary\n");
    {
        const size_t cap = 64, ch = 2, outFrames = 32;
        std::vector<int32_t> ring(cap * ch);
        for (size_t i = 0; i < cap; ++i)
            for (size_t c = 0; c < ch; ++c) ring[i * ch + c] = make_dop_sample(i, payload_of(i, c));

        DopPhase ph;
        const size_t canaryFrames = 4;
        std::vector<uint8_t> out((outFrames + canaryFrames) * ch * 3, 0xEE);
        const auto st = dop_write_period_24le(out.data(), outFrames, ring.data(), cap, 0, cap, ch,
                                             1.0, ph);
        ck(st.written == outFrames, "写出帧数 == 设备请求帧数", std::to_string(st.written));
        ck(st.silenced == 0, "供料充足时不该补静音", std::to_string(st.silenced));
        ck(!st.gainIgnored, "增益 1.0 不应触发增益闸");

        bool payloadOk = true, markerOk = true, chOk = true;
        for (size_t i = 0; i < outFrames; ++i) {
            for (size_t c = 0; c < ch; ++c) {
                const uint8_t* f = &out[(i * ch + c) * 3];
                const uint16_t got = (uint16_t)(f[0] | ((uint16_t)f[1] << 8));
                if (got != payload_of(i, c)) payloadOk = false;
                if (!dop_marker_legal(f[2])) markerOk = false;
                if (f[2] != out[(i * ch) * 3 + 2]) chOk = false;
            }
        }
        ck(payloadOk, "低 16 位 payload 逐帧逐声道逐位一致（真实 DSD 数据未被改动）");
        ck(markerOk, "所有标记字节 ∈ {0x05,0xFA}（绝无 0x00）");
        ck(chOk, "同帧各声道标记一致");
        ck(dop_find_invalid_frame(out.data(), outFrames, ch, kDopMarkerA) == outFrames,
           "整段严格交替（首帧接管上游 0x05，与上游逐字节一致）");
        bool canaryOk = true;
        for (size_t i = outFrames; i < outFrames + canaryFrames; ++i)
            for (size_t b = 0; b < ch * 3; ++b)
                if (out[i * ch * 3 + b] != 0xEE) canaryOk = false;
        ck(canaryOk, "canary：请求帧数之外的字节一个没碰（无越界写）");
        ck(ph.next == kDopMarkerA, "32 帧（偶数）之后相位回到 A", std::to_string((int)ph.next));
    }

    // ---- 7. 部分渲染 + 生产者已入队更多帧：相位的真实竞争场景 ----
    //
    // 复现链路（这是旧实现的真缺陷，不是假想）：
    //   · 环里已经有 25 帧（生产者写在先），但设备本次只要 16 帧；
    //   · 实际只有前 10 帧可读（avail 快照早于生产者的追加）⟹ 写 10 帧 + 补 6 帧静音；
    //   · 生产者"最后入队"的是第 24 帧（even ⟹ 0x05），它的规则会算出"下一帧 0xFA"；
    //   · 而真正渲染出去的最后一帧是第 9 帧（odd ⟹ 0xFA）⟹ 正确的下一帧是 0x05。
    //   按生产者算 ⟹ 填充首帧 0xFA 与已渲染最后一帧 0xFA **重复** ⟹ 接收端判非法。
    std::printf("\n[7] 部分渲染：相位必须接最后一帧（旧规则会 A,A 重复）\n");
    {
        const size_t cap = 64, ch = 2, outFrames = 16, avail = 10;
        std::vector<int32_t> ring(cap * ch);
        for (size_t i = 0; i < 25; ++i)
            for (size_t c = 0; c < ch; ++c) ring[i * ch + c] = make_dop_sample(i, payload_of(i, c));

        // 生产者侧（旧实现）会算出的"下一帧"：最后一帧入队是 i=24（even ⟹ A）⟹ next=B
        const uint8_t producerNext = dop_next_marker(marker_of(24));
        // 渲染侧真实的"下一帧"：最后一帧渲染出去是 i=9（odd ⟹ B）⟹ next=A
        const uint8_t renderedNext = dop_next_marker(marker_of(9));
        ck(producerNext != renderedNext, "本场景下两者确实不同（否则这条测试证明不了东西）",
           std::string("producer=") + std::to_string((int)producerNext) +
               " rendered=" + std::to_string((int)renderedNext));

        DopPhase ph;
        std::vector<uint8_t> out(outFrames * ch * 3, 0);
        const auto st = dop_write_period_24le(out.data(), outFrames, ring.data(), cap, 0, avail,
                                             ch, 1.0, ph);
        ck(st.written == avail, "只写出可用帧数", std::to_string(st.written));
        ck(st.silenced == outFrames - avail, "其余补静音", std::to_string(st.silenced));
        ck(dop_find_invalid_frame(out.data(), outFrames, ch, kDopMarkerA) == outFrames,
           "真实帧 + 静音帧拼起来仍严格交替（相位接的是最后一帧）");

        // 反证：按旧规则（用生产者相位）拼出来的缓冲必须被判非法 —— 判据有分辨力。
        std::vector<uint8_t> oldStyle(outFrames * ch * 3, 0);
        for (size_t i = 0; i < avail; ++i)
            for (size_t c = 0; c < ch; ++c) {
                const uint32_t v = (uint32_t)ring[i * ch + c] & 0xFFFFFFu;
                oldStyle[(i * ch + c) * 3 + 0] = (uint8_t)(v & 0xFF);
                oldStyle[(i * ch + c) * 3 + 1] = (uint8_t)((v >> 8) & 0xFF);
                oldStyle[(i * ch + c) * 3 + 2] = (uint8_t)((v >> 16) & 0xFF);
            }
        uint8_t oldMarker = producerNext;   // ← 旧实现的相位来源
        fill_dop_silence_24le(oldStyle.data() + avail * ch * 3, outFrames - avail, ch, oldMarker);
        ck(dop_find_invalid_frame(oldStyle.data(), outFrames, ch, kDopMarkerA) != outFrames,
           "反证：按生产者相位填充会与已渲染帧重复 ⟹ 判非法");
        ck(ph.next == kDopMarkerA, "10 真实 + 6 静音 = 16 帧（偶数）⟹ 相位回到 A",
           std::to_string((int)ph.next));
    }

    // ---- 8. 奇数帧填充 + 源恢复：重同步必须只改标记、不动 DSD 数据 ----
    //
    // 欠载填充的帧数是设备周期决定的，可能是奇数 ⟹ 之后"恢复供应"的真实数据
    // 会与接收端当前的相位差一帧。DoP 的标记是**传输层标志**，不是音频数据：
    // 把它对齐回本端相位是合法的重同步，payload（低 16 位）必须一个 bit 都不变。
    std::printf("\n[8] 奇数帧填充 + 源恢复\n");
    {
        const size_t cap = 64, ch = 2;
        std::vector<int32_t> ring(cap * ch);
        for (size_t i = 0; i < cap; ++i)
            for (size_t c = 0; c < ch; ++c) ring[i * ch + c] = make_dop_sample(i, payload_of(i, c));

        DopPhase ph;
        // 第一段：10 真实 + 7 静音 = 17 帧（奇数）
        std::vector<uint8_t> seg1(17 * ch * 3, 0);
        const auto s1 = dop_write_period_24le(seg1.data(), 17, ring.data(), cap, 0, 10, ch, 1.0, ph);
        ck(s1.written == 10 && s1.silenced == 7, "第一段 10 真实 + 7 静音",
           std::to_string(s1.written) + "/" + std::to_string(s1.silenced));
        ck(dop_find_invalid_frame(seg1.data(), 17, ch, kDopMarkerA) == 17, "第一段内部严格交替");

        // 第二段：恢复供应，接第 10 帧起（上游自己的相位从 0x05 开始）
        std::vector<uint8_t> seg2(12 * ch * 3, 0);
        const auto s2 = dop_write_period_24le(seg2.data(), 12, ring.data(), cap, 10, 12, ch, 1.0, ph);
        ck(s2.written == 12 && s2.silenced == 0, "第二段全是真实帧");
        ck(dop_find_invalid_frame(seg2.data(), 12, ch, kDopMarkerB) == 12,
           "第二段整体仍严格交替（从 B 起算 —— 段间是连续的）");
        ck(ph.rephased.load() > 0, "确实发生了重同步（rephased>0）",
           std::to_string(ph.rephased.load()));

        // 关键：重同步只改第 3 字节，payload 必须逐位一致
        bool payloadKept = true;
        for (size_t i = 0; i < 12; ++i)
            for (size_t c = 0; c < ch; ++c) {
                const uint8_t* f = &seg2[(i * ch + c) * 3];
                const uint16_t got = (uint16_t)(f[0] | ((uint16_t)f[1] << 8));
                if (got != payload_of(10 + i, c)) payloadKept = false;
            }
        ck(payloadKept, "重同步后低 16 位 payload 逐帧逐声道不变（只改标记字节）");

        // 拼接后整体必须合法（两段之间没有 A,A / B,B）
        std::vector<uint8_t> whole = seg1;
        whole.insert(whole.end(), seg2.begin(), seg2.end());
        ck(dop_find_invalid_frame(whole.data(), 29, ch, kDopMarkerA) == 29,
           "两段拼接后 29 帧整体严格交替（跨段不重置、不重复）");
    }

    // ---- 9. 增益闸：DoP 下任何数字增益都必须被忽略（纵深防御）----
    std::printf("\n[9] 增益闸（DoP 非单位增益必须无效）\n");
    {
        const size_t cap = 32, ch = 2, outFrames = 8;
        std::vector<int32_t> ring(cap * ch);
        for (size_t i = 0; i < cap; ++i)
            for (size_t c = 0; c < ch; ++c) ring[i * ch + c] = make_dop_sample(i, payload_of(i, c));

        DopPhase phA, phB, phC;
        std::vector<uint8_t> unity(outFrames * ch * 3, 0), half(outFrames * ch * 3, 0),
            muted(outFrames * ch * 3, 0);
        const auto a = dop_write_period_24le(unity.data(), outFrames, ring.data(), cap, 0, cap, ch, 1.0, phA);
        const auto b = dop_write_period_24le(half.data(), outFrames, ring.data(), cap, 0, cap, ch, 0.5, phB);
        const auto c = dop_write_period_24le(muted.data(), outFrames, ring.data(), cap, 0, cap, ch, 0.0, phC);
        ck(!a.gainIgnored, "增益 1.0：闸不动作");
        ck(b.gainIgnored, "增益 0.5：闸动作（并计数）");
        ck(c.gainIgnored, "增益 0.0（真静音请求）：DoP 下也不许静音，否则标记全 0");
        ck(half == unity, "0.5 增益的输出与 1.0 **逐字节相同**（没有把 0x05XXXX 缩成 0x02XXXX）");
        ck(muted == unity, "0.0 增益的输出与 1.0 逐字节相同（DSD 不能被软件静音）");
        ck(dop_find_invalid_frame(half.data(), outFrames, ch, kDopMarkerA) == outFrames,
           "被要求增益的那一路仍然严格交替");
    }

    // ---- 10. 敌意输入：上游给 0x00 标记 / 声道不一致 ----
    std::printf("\n[10] 敌意输入（非法标记 / 声道不一致）\n");
    {
        const size_t cap = 16, ch = 2, outFrames = 6;
        // (a) 上游把 PCM 当 DoP 写：标记全是 0x00
        std::vector<int32_t> zeros(cap * ch, 0);
        DopPhase ph;
        std::vector<uint8_t> out(outFrames * ch * 3, 0xEE);
        const auto st = dop_write_period_24le(out.data(), outFrames, zeros.data(), cap, 0, cap, ch, 1.0, ph);
        ck(st.written == outFrames, "写了请求帧数");
        ck(dop_find_invalid_frame(out.data(), outFrames, ch, kDopMarkerA) == outFrames,
           "上游标记全 0x00 时，输出仍是合法 A,B,A,B…（绝不把 0x00 发出去）");
        ck(ph.invalidMarker.load() == outFrames, "非法标记逐帧计数",
           std::to_string(ph.invalidMarker.load()));

        // (b) 同帧内声道标记不一致：必须对齐（否则接收端判声道错位）
        std::vector<int32_t> ring2(cap * ch, 0);
        for (size_t i = 0; i < cap; ++i) {
            ring2[i * ch + 0] = make_dop_sample(i, 0x1234);
            const uint8_t flipped = dop_next_marker(marker_of(i));
            uint32_t v = ((uint32_t)flipped << 16) | 0x5678u;
            if (v & 0x800000u) v |= 0xFF000000u;
            ring2[i * ch + 1] = (int32_t)v;   // 第 1 声道故意反相
        }
        DopPhase ph2;
        std::vector<uint8_t> out2(outFrames * ch * 3, 0);
        const auto st2 = dop_write_period_24le(out2.data(), outFrames, ring2.data(), cap, 0, cap, ch, 1.0, ph2);
        (void)st2;
        bool aligned = true;
        for (size_t i = 0; i < outFrames; ++i)
            if (out2[(i * ch) * 3 + 2] != out2[(i * ch + 1) * 3 + 2]) aligned = false;
        ck(aligned, "同帧各声道标记被对齐");
        ck(ph2.channelFixed.load() > 0, "声道不一致被计数", std::to_string(ph2.channelFixed.load()));
        // payload 仍未被破坏（对齐只碰第 3 字节）
        ck((uint16_t)(out2[0] | ((uint16_t)out2[1] << 8)) == 0x1234, "第 0 声道 payload 不变");
        ck((uint16_t)(out2[3] | ((uint16_t)out2[4] << 8)) == 0x5678, "第 1 声道 payload 不变");
    }

    // ---- 11. 退化输入：容量 0 / 空指针 / available=0 ----
    std::printf("\n[11] 退化输入（不崩、不写越界）\n");
    {
        const size_t ch = 2;
        int32_t dummy[8] = {0};
        uint8_t out[64];
        std::memset(out, 0xEE, sizeof(out));

        DopPhase ph;
        auto r1 = dop_write_period_24le(nullptr, 4, dummy, 4, 0, 4, ch, 1.0, ph);
        ck(r1.written == 0 && r1.silenced == 0, "out=nullptr 时不写任何帧");
        auto r2 = dop_write_period_24le(out, 4, nullptr, 4, 0, 4, ch, 1.0, ph);
        ck(r2.written == 0 && r2.silenced == 0, "ring=nullptr 时不写任何帧");
        auto r3 = dop_write_period_24le(out, 4, dummy, 0, 0, 4, ch, 1.0, ph);
        ck(r3.written == 0 && r3.silenced == 0, "环容量 0 时不写任何帧（绝不除零）");
        auto r4 = dop_write_period_24le(out, 0, dummy, 4, 0, 4, ch, 1.0, ph);
        ck(r4.written == 0 && r4.silenced == 0, "outFrames=0 时不写任何帧");
        ck(out[0] == 0xEE, "上述退化调用一个字节都没写");

        // available=0（真欠载）：整周期都是合法静音
        DopPhase ph5;
        std::vector<uint8_t> out5(5 * ch * 3, 0);
        auto r5 = dop_write_period_24le(out5.data(), 5, dummy, 4, 0, 0, ch, 1.0, ph5);
        ck(r5.written == 0 && r5.silenced == 5, "available=0 时整周期补静音");
        ck(dop_find_invalid_frame(out5.data(), 5, ch, kDopMarkerA) == 5, "整周期静音仍严格交替");
        bool silentPayload = true;
        for (size_t i = 0; i < 5; ++i)
            for (size_t c = 0; c < ch; ++c)
                if ((uint16_t)(out5[(i * ch + c) * 3] | ((uint16_t)out5[(i * ch + c) * 3 + 1] << 8)) !=
                    kDopSilencePayload)
                    silentPayload = false;
        ck(silentPayload, "静音 payload 全为 0x5555");
        ck(ph5.next == kDopMarkerB, "5 帧（奇数）之后相位在 B", std::to_string((int)ph5.next));
    }

    std::printf("\n=== 结果：%d 项，%d 失败 ===\n", g_total, g_fail);
    return g_fail == 0 ? 0 : 1;
}
