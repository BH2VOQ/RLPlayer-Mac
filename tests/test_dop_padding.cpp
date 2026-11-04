// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_dop_padding.cpp — 1.1.2 P0-3：DoP 输出在 EOS/尾块时的静音补全验证
//
// 测试覆盖：
//   ① 纯函数 dop_padding.h：
//      - 标记严格逐帧交替（0x05 / 0xFA），禁止连续两个相同标记
//      - payload 合法交替（0x5555 / 0xAAAA）
//      - 多声道每声道一致
//      - 帧数与相位接力精确无误
//   ② 真实 rta::render::render_loop 驱动测试（参考 test_render_loop_dry.cpp 架构）：
//      - h.dop = true，EOS 产生尾块（不足一个周期）
//      - 验证在未修复 baseline 行为（未挂载钩子或默认 resize(0)）下暴露缺陷（红）
//      - 挂载 dopPadFrames 钩子后，写入 sink 的所有帧均为合法 DoP（无 0x00 标记，且标记交替）
//      - 最后一帧仍是合法 DoP（无 0x00 标记）
//      - 填充总帧数与旧行为相同（只换填充内容，不改变时长）
//   ③ 对照组 h.dop = false（PCM 分支）：
//      - 尾块补全仍为全零（0），PCM 语义与旧测试完全一致
//   ④ 钩子缺失对照组 (h.dop = true 且 dopPadFrames == nullptr)：
//      - 保守保留旧行为（补全为 0 填满周期），同时打出明确 WARN 日志且置位 h.dopPadMissing
//
// 🔴 铁律 1：纯 mock sink 驱动，不打开任何音频设备，不出声。

#include "audio/dop_padding.h"
#include "audio/render_loop.h"
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

static int g_fails = 0;
static void ck(bool ok, const char* what, const std::string& detail = "") {
    std::printf("  [%s] %s %s\n", ok ? "PASS" : "FAIL", what, detail.c_str());
    if (!ok) ++g_fails;
}

// 记录所有写入帧的 mock sink
struct SpySink : rta::render::OutSink {
    size_t periodFrames = 1024;
    std::vector<int32_t> recorded; // 记录所有 write_available 写入的样本
    size_t totalWrittenFrames = 0;

    bool open(const rta::render::SinkOpenOpts&, uint32_t, int, int) override { return true; }
    bool start() override { return true; }
    size_t buffer_frames() const override { return periodFrames; }
    long long device_period_frames() const override { return (long long)periodFrames; }
    const std::string& last_error() const override { static std::string s; return s; }
    long long last_pad() const override { return 0; } // 永远有空间写入
    bool wait_event(int) override { return true; }

    size_t write_one_period(const int32_t* pcm, size_t n) override { return write_available(pcm, n); }
    size_t write_available(const int32_t* pcm, size_t n) override {
        if (!pcm || n == 0) return 0;
        const size_t toWrite = std::min(n, periodFrames);
        recorded.insert(recorded.end(), pcm, pcm + toWrite * 2); // 假设 2 声道
        totalWrittenFrames += toWrite;
        return toWrite;
    }
};

// 辅助运行 render_loop 直至 EOS 正常结束
static void run_render_loop_eos(SpySink& sink, rta::render::RenderHost& h, size_t inputFrames, int channels,
                                std::vector<std::string>* capturedLogs = nullptr) {
    rta::render::RenderQ rq;
    rq.abort.store(false);

    // 生产单个 AudioBuffer，包含 inputFrames 帧
    {
        rta::audio::AudioBuffer b;
        b.rate = 176400;
        b.channels = channels;
        b.bits = 24;
        b.raw.resize(inputFrames * (size_t)channels);
        // 如果是 DoP，用合法 DoP 填充前面这部分输入数据
        if (h.dop) {
            bool ph = true;
            rta::audio::generate_dop_silence_frames(b.raw.data(), channels, inputFrames, ph);
        } else {
            // PCM 数据：填入非零特征值，如 0x123456
            for (size_t i = 0; i < b.raw.size(); ++i) b.raw[i] = 0x123456;
        }
        rq.q.emplace_back(std::move(b), rq.epoch.load());
    }

    std::atomic<bool> stop{false}, pauseReq{false}, paused{false};
    std::atomic<double> seekReq{-1.0};
    std::atomic<size_t> played{0};
    std::atomic<double> vol{0.0}, start{0.0};
    std::atomic<long long> dbgPad{0};
    bool gpuOut = false;
    std::atomic<long long> w0{0}, wr{0}, pulls{0}, clip{0}, dry{0}, dryMs{0}, ev{0}, evInt{0}, prod{0};
    std::atomic<double> peak{0.0};
    double clock = 0.0;

    h.stop = &stop; h.pauseReq = &pauseReq; h.paused = &paused;
    h.seekReq = &seekReq; h.played = &played;
    h.volDb = &vol; h.startDb = &start;
    h.dbgPad = &dbgPad; h.gpuOut = &gpuOut;
    h.rq = &rq;
    h.deviceRate = 176400; h.outBits = 24; h.outCh = channels;
    h.inRate = 176400; h.inFrames = inputFrames; h.totalOut = inputFrames;
    h.dbgW0 = &w0; h.dbgWr = &wr; h.dbgPulls = &pulls; h.dbgClip = &clip; h.dbgPeak = &peak;
    h.dbgDry = &dry; h.dbgDryMs = &dryMs; h.dbgEv = &ev; h.dbgEvInt = &evInt; h.dbgProd = &prod;
    h.onShared = false;
    h.starveEnabled = false;
    h.statPeriodSec = 1000.0;
    h.deviceLabel = "mock";
    h.deviceIdDesc = "mock";
    h.log = [capturedLogs](const std::string& msg) {
        if (capturedLogs) capturedLogs->push_back(msg);
    };

    h.nowSec = [&clock, &stop]() {
        clock += 0.001;
        if (clock > 5.0) stop.store(true); // 保护看门狗
        return clock;
    };

    // 标为 done，让队列在读完这批帧后触发 EOS
    {
        std::lock_guard<std::mutex> lk(rq.mtx);
        rq.done = true;
    }

    rta::render::render_loop(sink, h);
}

int main() {
    std::printf("=== test_dop_padding: DoP EOS 尾块填充与合法性验证 ===\n");

    // =========================================================================
    // 阶段 1: 纯函数单元测试
    // =========================================================================
    std::printf("\n--- 1. dop_padding.h 纯函数断言 ---\n");
    {
        const size_t ch = 2;
        const size_t frames = 33; // 奇数帧
        std::vector<int32_t> buf;
        bool phase = true;

        rta::audio::append_dop_silence_frames(buf, ch, frames, phase);
        ck(buf.size() == frames * ch, "生成帧数与声道数精确符合", "size=" + std::to_string(buf.size()));
        ck(!phase, "输出相位正确翻转（33帧后为false）");

        // 验证每一帧
        bool markersOk = true;
        bool payloadsOk = true;
        bool channelsMatch = true;

        for (size_t f = 0; f < frames; ++f) {
            const uint8_t expMarker = (f % 2 == 0) ? rta::audio::kDopMarkerA : rta::audio::kDopMarkerB;
            const uint16_t expPayload = (f % 2 == 0) ? rta::audio::kDopSilencePayloadA : rta::audio::kDopSilencePayloadB;

            for (size_t c = 0; c < ch; ++c) {
                const int32_t s = buf[f * ch + c];
                const uint8_t m = rta::audio::extract_dop_marker(s);
                const uint16_t p = rta::audio::extract_dop_payload(s);

                if (m != expMarker) markersOk = false;
                if (p != expPayload) payloadsOk = false;
                if (c > 0) {
                    if (rta::audio::extract_dop_marker(buf[f * ch]) != m) channelsMatch = false;
                }
            }
        }
        ck(markersOk, "所有标记严格逐帧 0x05/0xFA 交替，无 0x00，且无连续相同标记");
        ck(payloadsOk, "所有 payload 严格合法交替（0x5555 / 0xAAAA）");
        ck(channelsMatch, "多声道（2ch）同帧内各声道标记与 payload 完全一致");

        // 测试接力继续追加
        rta::audio::append_dop_silence_frames(buf, ch, 10, phase);
        ck(buf.size() == (frames + 10) * ch, "接力追加帧数准确");
        // 第 33 帧索引为 33 (即第 34 帧，奇数索引，对应 B=0xFA)
        const uint8_t m33 = rta::audio::extract_dop_marker(buf[33 * ch]);
        ck(m33 == rta::audio::kDopMarkerB, "接力首帧标记与前段尾部严格交替（B=0xFA）");
    }

    // =========================================================================
    // 阶段 2: 驱动真实 render_loop，测试 DoP 尾块行为 (h.dop = true 带钩子)
    // =========================================================================
    std::printf("\n--- 2. 真实 render_loop EOS 尾块填充断言 (h.dop = true 带钩子) ---\n");
    {
        // 设 period = 1024 帧。我们灌入 1500 帧。
        // 第一个周期写 1024 帧，剩下 476 帧。
        // 触发 EOS，476 < 1024，render_loop 必须补到 1024 帧（需要补 1024 - 476 = 548 帧）。
        // 最终 sink 应该收到正好 2048 帧（2 个完整周期）。
        const size_t period = 1024;
        const size_t inputFrames = 1500;
        const size_t expectedTotalFrames = 2048;

        SpySink sink;
        sink.periodFrames = period;

        rta::render::RenderHost h;
        h.dop = true;

        // 设置 dopPadFrames 钩子
        bool dopPadPhase = true;
        h.dopPadFrames = [&dopPadPhase](std::vector<int32_t>& pend, size_t outCh, size_t needFrames) {
            rta::audio::append_dop_silence_frames(pend, outCh, needFrames, dopPadPhase);
        };

        run_render_loop_eos(sink, h, inputFrames, 2);

        ck(h.normalEnd, "render_loop 正常结束 (normalEnd=true)");
        ck(sink.totalWrittenFrames == expectedTotalFrames,
           "写入设备的总帧数必须补齐至整周期 (2048 帧)",
           "got=" + std::to_string(sink.totalWrittenFrames));

        // 重点检查尾部补全的 548 帧（即第 1500 到 2047 帧）：
        // 必须全部是合法 DoP（高 8 位不为 0x00，且交替）
        bool tailHasZeroMarker = false;
        bool tailMarkersAlternate = true;
        uint8_t prevMarker = rta::audio::extract_dop_marker(sink.recorded[(inputFrames - 1) * 2]);

        for (size_t f = inputFrames; f < expectedTotalFrames; ++f) {
            const int32_t s0 = sink.recorded[f * 2 + 0];
            const int32_t s1 = sink.recorded[f * 2 + 1];
            const uint8_t m0 = rta::audio::extract_dop_marker(s0);
            const uint8_t m1 = rta::audio::extract_dop_marker(s1);

            if (m0 == 0x00 || m1 == 0x00) {
                tailHasZeroMarker = true;
            }
            if (m0 != rta::audio::kDopMarkerA && m0 != rta::audio::kDopMarkerB) {
                tailMarkersAlternate = false;
            }
            if (m0 == prevMarker) {
                tailMarkersAlternate = false; // 出现了连续相同标记
            }
            prevMarker = m0;
        }

        ck(!tailHasZeroMarker, "尾块补全样本的高 8 位标记绝不能为 0x00（旧实现缺陷已被修复）");
        ck(tailMarkersAlternate, "尾块补全样本标记严格在 0x05 与 0xFA 之间交替且跨边界无缝接力");

        // 断言写入设备的最后一帧（第 2047 帧）仍是合法 DoP
        const int32_t lastSample = sink.recorded[(expectedTotalFrames - 1) * 2];
        const uint8_t lastMarker = rta::audio::extract_dop_marker(lastSample);
        char mBuf[32];
        std::snprintf(mBuf, sizeof(mBuf), "lastMarker=0x%02X", (unsigned)lastMarker);
        ck(lastMarker == rta::audio::kDopMarkerA || lastMarker == rta::audio::kDopMarkerB,
           "写入设备的最后一帧仍是合法 DoP（没有 0x00 标记）",
           mBuf);
    }

    // =========================================================================
    // 阶段 3: 对照组 (h.dop = false, PCM 分支)
    // =========================================================================
    std::printf("\n--- 3. 对照组验证: PCM (h.dop = false) 尾块必须仍为全零补齐 ---\n");
    {
        const size_t period = 1024;
        const size_t inputFrames = 1500;
        const size_t expectedTotalFrames = 2048;

        SpySink sink;
        sink.periodFrames = period;

        rta::render::RenderHost h;
        h.dop = false; // PCM 模式

        run_render_loop_eos(sink, h, inputFrames, 2);

        ck(h.normalEnd, "PCM render_loop 正常结束");
        ck(sink.totalWrittenFrames == expectedTotalFrames,
           "PCM 写入总帧数同样补齐至整周期 (2048 帧)",
           "got=" + std::to_string(sink.totalWrittenFrames));

        // 检查尾部的 548 帧（第 1500 到 2047 帧）必须全为 0
        bool allZero = true;
        for (size_t f = inputFrames; f < expectedTotalFrames; ++f) {
            if (sink.recorded[f * 2 + 0] != 0 || sink.recorded[f * 2 + 1] != 0) {
                allZero = false;
                break;
            }
        }
        ck(allZero, "PCM 尾块严格保持全零补齐语义（0 样本），不影响 PCM 行为与既有测试");
    }

    // =========================================================================
    // 阶段 4: 钩子缺失对照组 (h.dop = true 且 dopPadFrames == nullptr)
    // =========================================================================
    std::printf("\n--- 4. 钩子缺失保守回退与告警断言 (h.dop = true, dopPadFrames = nullptr) ---\n");
    {
        const size_t period = 1024;
        const size_t inputFrames = 1500;
        const size_t expectedTotalFrames = 2048;

        SpySink sink;
        sink.periodFrames = period;

        rta::render::RenderHost h;
        h.dop = true;
        h.dopPadFrames = nullptr; // 未提供钩子

        std::vector<std::string> logs;
        run_render_loop_eos(sink, h, inputFrames, 2, &logs);

        ck(h.normalEnd, "render_loop 正常结束");
        ck(sink.totalWrittenFrames == expectedTotalFrames,
           "钩子缺失时仍保守填满整周期 (2048 帧)",
           "got=" + std::to_string(sink.totalWrittenFrames));
        ck(h.dopPadMissing, "h.dopPadMissing 标志显式置为 true（拒绝静默假成功）");

        bool hasWarningLog = false;
        for (const auto& logMsg : logs) {
            if (logMsg.find("WARN: DoP output padded with zeros") != std::string::npos ||
                logMsg.find("missing dopPadFrames") != std::string::npos) {
                hasWarningLog = true;
                break;
            }
        }
        ck(hasWarningLog, "日志中输出了明确警告，表明未补合法 DoP 静音");
    }

    std::printf("\n=== 测试汇总: %s (失败数: %d) ===\n", g_fails == 0 ? "全部通过" : "存在失败", g_fails);
    return g_fails == 0 ? 0 : 1;
}
