// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_room_transport_coreaudio.cpp — CoreAudioRoomTransport 传输层离线 IO Seam 判据
//
// 判据设计原则（铁律 3：测试「通过」≠「测对了东西」，判据要能证明真东西）：
//   1. 必须针对 CoreAudioRoomTransport 真实生产类，通过注入 IO seam 推进其状态机，
//      绝不能测试另一个 VirtualRoomTransport 再声称测到了 CoreAudio 类。
//   2. 必须覆盖已审计的全部核心缺陷：
//      - 缺陷 1 & 2 & 3: 16k 采集 vs 48k 播放的跨率时基换算、边播边录推进与重采样回到 session rate 保真验证；
//      - 缺陷 4: writeStallMs 计时基准（从最后成功写入计时 vs 从 t0 计时）；已运行 >3s 后短暂背压不假超时；
//      - 缺陷 4b: 连续真实停滞超限确能真超时；
//      - 缺陷 5: 取消时立即中止，返回已取消错误，不进入混响尾巴，lastOk()==false；
//      - 缺陷 6: 混响尾巴 wait 失败显式报错，播放硬件渲染排空未确认/超时显式报错；
//      - 缺陷 7: 麦克风物理声道与输出 activeCh 解耦，多扬声器测量共用同一单声道麦。
//   3. 铁律 1 绝不默认打开物理输出设备，离线测试纯走 IO seam，零硬件依赖。

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "dsp/room_measurement.h"
#include "platform/audio_out.h"
#include "platform/macos/audio_in_coreaudio.h"
#include "platform/macos/room_transport_coreaudio.h"

static int g_fail = 0;
static void ck(bool cond, const char* what, const std::string& detail = "") {
    if (cond) {
        std::printf("  [PASS] %s\n", what);
    } else {
        std::printf("  [FAIL] %s  %s\n", what, detail.c_str());
        ++g_fail;
    }
}

static bool env_on(const char* k) {
    const char* v = std::getenv(k);
    return v && std::string(v) == "1";
}

// ---------------------------------------------------------------------------
// 离线测试 Mock IO 实现
// ---------------------------------------------------------------------------

class MockAudioOutput : public rta::platform::AudioOutput {
public:
    rta::platform::DeviceCaps caps(const std::string&) override {
        rta::platform::DeviceCaps c;
        c.rates = {16000, 44100, 48000, 96000};
        c.bitDepths = {16, 24, 32};
        c.exclusiveMode = true;
        c.bitPerfectCapable = true;
        return c;
    }
    bool open(const rta::platform::OpenSpec& spec) override {
        opened_ = true;
        spec_ = spec;
        return true;
    }
    bool start() override {
        running_ = true;
        return true;
    }
    size_t write(const int32_t* interleaved, size_t frames) override {
        if (!running_) return 0;
        if (writeHook) return writeHook(interleaved, frames);
        frames_written_ += frames;
        if (autoRender) frames_rendered_ += frames;
        return frames;
    }
    void pause() override { running_ = false; }
    void resume() override { running_ = true; }
    void close() override { running_ = false; opened_ = false; }
    size_t buffer_frames() const override { return 4800; }
    size_t frames_written() const override { return frames_written_; }
    size_t frames_rendered() const override { return frames_rendered_; }
    bool bit_perfect() const override { return true; }
    rta::platform::OutputError last_error_class() const override { return rta::platform::OutputError::None; }
    const std::string& last_error() const override { return err_; }

    std::function<size_t(const int32_t* interleaved, size_t frames)> writeHook;
    bool autoRender = true;
    size_t frames_written_ = 0;
    size_t frames_rendered_ = 0;
    bool opened_ = false;
    bool running_ = false;
    std::string err_;
    rta::platform::OpenSpec spec_;
};

class MockAudioInput : public rta::dsp::RoomAudioInput {
public:
    bool open(const rta::platform::MacCaptureConfig& cfg) override {
        opened_ = true;
        cfg_ = cfg;
        return true;
    }
    bool start() override { running_ = true; return true; }
    bool stop() override { running_ = false; return true; }
    void close() override { running_ = false; opened_ = false; }
    size_t read_available(float* dst, size_t maxFrames) override {
        if (!running_) return 0;
        if (readHook) return readHook(dst, maxFrames);
        const size_t ch = (size_t)channels_;
        const size_t avail = (buffer_.size() - readPos_) / ch;
        const size_t n = std::min(maxFrames, avail);
        if (n > 0) {
            std::memcpy(dst, buffer_.data() + readPos_, n * ch * sizeof(float));
            readPos_ += n * ch;
        }
        return n;
    }
    uint32_t rate() const override { return rate_; }
    int channels() const override { return channels_; }
    const std::string& last_error() const override { return err_; }

    void pushFrames(const std::vector<float>& interleaved) {
        buffer_.insert(buffer_.end(), interleaved.begin(), interleaved.end());
    }

    uint32_t rate_ = 48000;
    int channels_ = 2;
    bool opened_ = false;
    bool running_ = false;
    std::string err_;
    rta::platform::MacCaptureConfig cfg_;
    std::vector<float> buffer_;
    size_t readPos_ = 0;
    std::function<size_t(float* dst, size_t maxFrames)> readHook;
};

// 代理包装器：供 seam 返回 unique_ptr，同时避免重复释放外部 Mock 实例
class ProxyAudioOutput : public rta::platform::AudioOutput {
public:
    explicit ProxyAudioOutput(MockAudioOutput* t) : t_(t) {}
    rta::platform::DeviceCaps caps(const std::string& d) override { return t_->caps(d); }
    bool open(const rta::platform::OpenSpec& s) override { return t_->open(s); }
    bool start() override { return t_->start(); }
    size_t write(const int32_t* p, size_t f) override { return t_->write(p, f); }
    void pause() override { t_->pause(); }
    void resume() override { t_->resume(); }
    void close() override { t_->close(); }
    size_t buffer_frames() const override { return t_->buffer_frames(); }
    size_t frames_written() const override { return t_->frames_written(); }
    size_t frames_rendered() const override { return t_->frames_rendered(); }
    bool bit_perfect() const override { return t_->bit_perfect(); }
    rta::platform::OutputError last_error_class() const override { return t_->last_error_class(); }
    const std::string& last_error() const override { return t_->last_error(); }
private:
    MockAudioOutput* t_;
};

class ProxyAudioInput : public rta::dsp::RoomAudioInput {
public:
    explicit ProxyAudioInput(MockAudioInput* t) : t_(t) {}
    bool open(const rta::platform::MacCaptureConfig& c) override { return t_->open(c); }
    bool start() override { return t_->start(); }
    bool stop() override { return t_->stop(); }
    void close() override { t_->close(); }
    size_t read_available(float* d, size_t m) override { return t_->read_available(d, m); }
    uint32_t rate() const override { return t_->rate(); }
    int channels() const override { return t_->channels(); }
    const std::string& last_error() const override { return t_->last_error(); }
private:
    MockAudioInput* t_;
};

// ---------------------------------------------------------------------------
// 主测试入口
// ---------------------------------------------------------------------------

int main() {
    std::printf("== R-1 房间测量 mac 传输层 (CoreAudioRoomTransport) ==\n");
    std::printf("   （§1 生产传输状态机离线 IO Seam；§2/§3 需真实设备环境变量）\n\n");

    // =========================================================================
    // §1 CoreAudioRoomTransport 状态机离线 IO Seam 测试
    // =========================================================================

    // -------------------------------------------------------------------------
    // Test 1A: 16k 采集率 vs 48k 播放率（时基换算、重采样与反卷积直达声还原）
    // -------------------------------------------------------------------------
    std::printf("-- Test 1A: 16k 采集 vs 48k 播放（时基换算、重采样保真与峰位还原）--\n");
    {
        rta::dsp::SweepSpec spec;
        spec.fs = 48000;
        spec.f0 = 40.0;
        spec.f1 = 7000.0; // 16k 采样 Nyquist 为 8k，扫频上限 7k
        spec.durSec = 1.0;
        const std::vector<double> sweep = rta::dsp::generate_sweep(spec);
        const double kDelayMs = 12.0;

        auto mockOut = std::make_shared<MockAudioOutput>();
        auto mockIn = std::make_shared<MockAudioInput>();
        mockIn->rate_ = 16000;
        mockIn->channels_ = 2;

        // 预生成 16k 采样的房间响应：
        // 前导 300ms（4800 帧）本底噪声 + 1s 扫频（16000 帧，单峰延迟 12ms）+ 尾部 800ms（12800 帧）
        const size_t preFrames16k = 4800;
        const size_t sweepFrames16k = 16000;
        const size_t tailFrames16k = 12800;
        const size_t totalFrames16k = preFrames16k + sweepFrames16k + tailFrames16k;

        std::vector<float> roomSignal16k(totalFrames16k * 2, 0.0f);
        // 填入微弱本底噪声
        for (size_t i = 0; i < totalFrames16k; ++i) {
            roomSignal16k[i * 2 + 0] = (float)(1e-6 * std::sin((double)i * 0.37));
            roomSignal16k[i * 2 + 1] = 0.0f;
        }
        // 填入经过 12ms 延迟的扫频（麦克风在声道 0）
        for (size_t n = 0; n < sweepFrames16k; ++n) {
            const double t = (double)n / 16000.0;
            const double tSrc = t - (kDelayMs * 0.001);
            if (tSrc >= 0.0 && tSrc < 1.0) {
                const size_t idx48k = (size_t)std::llround(tSrc * 48000.0);
                if (idx48k < sweep.size()) {
                    roomSignal16k[(preFrames16k + n) * 2 + 0] += (float)(0.5 * sweep[idx48k]);
                }
            }
        }

        // 模拟边播边录推进：
        // 预录阶段先放行 preFrames16k 帧
        mockIn->pushFrames(std::vector<float>(roomSignal16k.begin(), roomSignal16k.begin() + preFrames16k * 2));

        // 边播边录阶段：每向 48k 输出写入 frames48k 帧，产生 frames48k * 16k / 48k 的 16k 采集帧
        size_t pushed16k = preFrames16k;
        mockOut->writeHook = [&](const int32_t*, size_t frames) -> size_t {
            mockOut->frames_written_ += frames;
            mockOut->frames_rendered_ += frames;
            // 换算到 16k 帧数
            const size_t shouldPush16k = preFrames16k + (mockOut->frames_written_ * 16000) / 48000;
            if (shouldPush16k > pushed16k && shouldPush16k <= preFrames16k + sweepFrames16k) {
                const size_t count = shouldPush16k - pushed16k;
                mockIn->pushFrames(std::vector<float>(roomSignal16k.begin() + pushed16k * 2,
                                                      roomSignal16k.begin() + (pushed16k + count) * 2));
                pushed16k += count;
            }
            return frames;
        };

        // 虚拟时钟与 sleep 控制
        auto virtNow = std::chrono::steady_clock::now();
        rta::dsp::RoomIoSeam seam;
        seam.createOutput = [mockOut]() { return std::make_unique<ProxyAudioOutput>(mockOut.get()); };
        seam.createInput = [mockIn]() { return std::make_unique<ProxyAudioInput>(mockIn.get()); };
        seam.now = [&virtNow]() { return virtNow; };
        seam.sleepFor = [&](std::chrono::milliseconds ms) {
            virtNow += ms;
            // 如果处于尾巴阶段且尾巴尚未推入，推入尾巴帧
            if (pushed16k < totalFrames16k && mockOut->frames_written_ >= sweep.size()) {
                const size_t remaining = totalFrames16k - pushed16k;
                const size_t step = std::min(remaining, (size_t)(ms.count() * 16));
                if (step > 0) {
                    mockIn->pushFrames(std::vector<float>(roomSignal16k.begin() + pushed16k * 2,
                                                          roomSignal16k.begin() + (pushed16k + step) * 2));
                    pushed16k += step;
                }
            }
        };

        rta::dsp::RoomTxConfig cfg;
        cfg.channels = 2;
        cfg.captureChannel = 0;
        cfg.rate = 48000;
        cfg.writeStallMs = 3000.0;
        cfg.captureStallMs = 5000.0;
        cfg.preRollMs = 300.0;
        cfg.tailMs = 800.0;

        rta::dsp::CoreAudioRoomTransport tx(cfg, seam);
        const size_t captureN = sweep.size() + 48000; // 48k 下期望 ≥ 96000 样本
        const std::vector<double> rec = tx.play_and_capture(sweep, captureN);

        ck(tx.lastOk(), "16k采集/48k播放：传输层成功返回（lastOk==true）", tx.lastError());
        ck(rec.size() >= captureN, "16k采集/48k播放：返回样本时长对齐到 48k 会话率（≥ samplesToCapture）",
           "实际样本数=" + std::to_string(rec.size()) + " 期望≥" + std::to_string(captureN));

        bool peakOk = false;
        double peakMs = 0.0;
        const double expectedPeakMs = cfg.preRollMs + kDelayMs; // 300ms 预录 + 12ms 房间延迟 = 312ms
        if (!rec.empty()) {
            const std::vector<double> ir = rta::dsp::deconvolve_ir(rec, sweep, 48000.0);
            if (!ir.empty()) {
                const size_t peakIdx = rta::dsp::ir_peak_index(ir);
                peakMs = (double)peakIdx / 48000.0 * 1000.0;
                // 16k 带限重采样保真：还原峰位误差应在 ±2.0 ms 内（设计峰位 = 预录 300ms + 延迟 12ms = 312ms）
                if (std::fabs(peakMs - expectedPeakMs) <= 2.0) peakOk = true;
            }
        }
        ck(peakOk, "16k采集/48k播放：反卷积直达声峰位准确还原（期望 312 ms = 预录 300ms + 延迟 12ms）",
           "实际 peakMs=" + std::to_string(peakMs));
    }

    // -------------------------------------------------------------------------
    // Test 1B: 播放运行 > 3s 后短暂背压（不假超时）
    // -------------------------------------------------------------------------
    std::printf("\n-- Test 1B: 播放 > 3s 后的短暂背压不会假超时 --\n");
    {
        rta::dsp::SweepSpec spec;
        spec.fs = 48000;
        spec.f0 = 40.0;
        spec.f1 = 18000.0;
        spec.durSec = 3.5; // 3.5 秒扫频 > writeStallMs (3.0s)
        const std::vector<double> sweep = rta::dsp::generate_sweep(spec);

        auto mockOut = std::make_shared<MockAudioOutput>();
        auto mockIn = std::make_shared<MockAudioInput>();
        mockIn->rate_ = 48000;
        mockIn->channels_ = 2;

        auto virtNow = std::chrono::steady_clock::now();
        int backpressureCalls = 0;

        mockOut->writeHook = [&](const int32_t*, size_t frames) -> size_t {
            // 在写入超过 3.2 秒（153600 帧）时，模拟一次持续 5 次轮询（每次 sleep 1ms，共 5ms）的短暂设备背压写满
            if (mockOut->frames_written_ >= 153600 && backpressureCalls < 5) {
                ++backpressureCalls;
                return 0; // 短暂写不进
            }
            mockOut->frames_written_ += frames;
            mockOut->frames_rendered_ += frames;
            // 真实物理时间推进：写入 48k 帧对应真实时长
            virtNow += std::chrono::milliseconds((frames * 1000) / 48000);
            // 实时生成采集帧，保证采集不超时
            std::vector<float> chunk(frames * 2, 0.001f);
            mockIn->pushFrames(chunk);
            return frames;
        };

        // 预录 300ms
        mockIn->pushFrames(std::vector<float>((size_t)(0.3 * 48000.0 * 2), 0.001f));

        rta::dsp::RoomIoSeam seam;
        seam.createOutput = [mockOut]() { return std::make_unique<ProxyAudioOutput>(mockOut.get()); };
        seam.createInput = [mockIn]() { return std::make_unique<ProxyAudioInput>(mockIn.get()); };
        seam.now = [&virtNow]() { return virtNow; };
        seam.sleepFor = [&](std::chrono::milliseconds ms) {
            virtNow += ms;
            // 尾巴阶段补充采集帧
            if (mockOut->frames_written_ >= sweep.size()) {
                mockIn->pushFrames(std::vector<float>((size_t)(ms.count() * 48 * 2), 0.001f));
            }
        };

        rta::dsp::RoomTxConfig cfg;
        cfg.channels = 2;
        cfg.rate = 48000;
        cfg.writeStallMs = 3000.0; // 停滞上限 3s
        cfg.captureStallMs = 5000.0;

        rta::dsp::CoreAudioRoomTransport tx(cfg, seam);
        const std::vector<double> rec = tx.play_and_capture(sweep, sweep.size() + 48000);

        ck(tx.lastOk(), "播放 > 3s 后的短暂背压（5ms）不假超时，正常完成测量", tx.lastError());
        ck(backpressureCalls >= 5, "确实注入了短暂背压写不进（backpressureCalls >= 5）",
           "实际次数=" + std::to_string(backpressureCalls));
    }

    // -------------------------------------------------------------------------
    // Test 1C: 连续真实停滞超时
    // -------------------------------------------------------------------------
    std::printf("\n-- Test 1C: 连续停滞超过 writeStallMs 确能超时报错 --\n");
    {
        rta::dsp::SweepSpec spec;
        spec.fs = 48000;
        spec.f0 = 40.0;
        spec.f1 = 18000.0;
        spec.durSec = 1.0;
        const std::vector<double> sweep = rta::dsp::generate_sweep(spec);

        auto mockOut = std::make_shared<MockAudioOutput>();
        auto mockIn = std::make_shared<MockAudioInput>();
        mockIn->rate_ = 48000;
        mockIn->channels_ = 2;
        // 预录帧
        mockIn->pushFrames(std::vector<float>((size_t)(0.3 * 48000.0 * 2), 0.001f));

        auto virtNow = std::chrono::steady_clock::now();
        mockOut->writeHook = [&](const int32_t*, size_t) -> size_t {
            return 0; // 永久写不进
        };

        rta::dsp::RoomIoSeam seam;
        seam.createOutput = [mockOut]() { return std::make_unique<ProxyAudioOutput>(mockOut.get()); };
        seam.createInput = [mockIn]() { return std::make_unique<ProxyAudioInput>(mockIn.get()); };
        seam.now = [&virtNow]() { return virtNow; };
        seam.sleepFor = [&](std::chrono::milliseconds ms) { virtNow += ms; };

        rta::dsp::RoomTxConfig cfg;
        cfg.channels = 2;
        cfg.rate = 48000;
        cfg.writeStallMs = 200.0; // 停滞上限 200ms
        cfg.captureStallMs = 1000.0;

        rta::dsp::CoreAudioRoomTransport tx(cfg, seam);
        const std::vector<double> rec = tx.play_and_capture(sweep, sweep.size() + 48000);

        ck(!tx.lastOk(), "连续停滞时正确判定失败（lastOk==false）");
        ck(tx.lastError().find("连续写不进") != std::string::npos ||
           tx.lastError().find("停滞") != std::string::npos,
           "停滞错误文案明确指出写入停滞", tx.lastError());
    }

    // -------------------------------------------------------------------------
    // Test 1D: 取消立即中止，不进入尾巴且 lastOk() == false
    // -------------------------------------------------------------------------
    std::printf("\n-- Test 1D: 取消操作立即中止，不进尾巴，lastOk()==false --\n");
    {
        rta::dsp::SweepSpec spec;
        spec.fs = 48000;
        spec.durSec = 1.0;
        const std::vector<double> sweep = rta::dsp::generate_sweep(spec);

        auto mockOut = std::make_shared<MockAudioOutput>();
        auto mockIn = std::make_shared<MockAudioInput>();
        mockIn->rate_ = 48000;
        mockIn->channels_ = 2;
        mockIn->pushFrames(std::vector<float>((size_t)(0.3 * 48000.0 * 2), 0.001f));

        auto virtNow = std::chrono::steady_clock::now();
        bool cancelTriggered = false;

        mockOut->writeHook = [&](const int32_t*, size_t frames) -> size_t {
            mockOut->frames_written_ += frames;
            mockOut->frames_rendered_ += frames;
            mockIn->pushFrames(std::vector<float>(frames * 2, 0.001f));
            return frames;
        };

        rta::dsp::RoomIoSeam seam;
        seam.createOutput = [mockOut]() { return std::make_unique<ProxyAudioOutput>(mockOut.get()); };
        seam.createInput = [mockIn]() { return std::make_unique<ProxyAudioInput>(mockIn.get()); };
        seam.now = [&virtNow]() { return virtNow; };
        seam.sleepFor = [&](std::chrono::milliseconds ms) { virtNow += ms; };

        rta::dsp::RoomTxConfig cfg;
        cfg.channels = 2;
        cfg.rate = 48000;

        rta::dsp::CoreAudioRoomTransport tx(cfg, seam);
        // 在写入约 10000 帧时触发取消
        tx.cancelled = [&]() -> bool {
            if (mockOut->frames_written_ >= 10000) {
                cancelTriggered = true;
                return true;
            }
            return false;
        };

        const std::vector<double> rec = tx.play_and_capture(sweep, sweep.size() + 48000);

        ck(cancelTriggered, "在播放中途成功触发了取消回调");
        ck(!tx.lastOk(), "取消后 lastOk() 必须为 false（不可误报 ok）");
        ck(rec.empty(), "取消后返回数据必须为空");
        ck(tx.lastError().find("取消") != std::string::npos,
           "取消后 lastError 包含取消说明", tx.lastError());
        ck(mockOut->frames_written_ < sweep.size(), "取消后未继续向输出端点写入整段扫频",
           "written=" + std::to_string(mockOut->frames_written_) + " total=" + std::to_string(sweep.size()));
    }

    // -------------------------------------------------------------------------
    // Test 1E: 尾巴 wait 失败显式报错
    // -------------------------------------------------------------------------
    std::printf("\n-- Test 1E: 混响尾巴 wait 失败显式报错 --\n");
    {
        rta::dsp::SweepSpec spec;
        spec.fs = 48000;
        spec.durSec = 0.5;
        const std::vector<double> sweep = rta::dsp::generate_sweep(spec);

        auto mockOut = std::make_shared<MockAudioOutput>();
        auto mockIn = std::make_shared<MockAudioInput>();
        mockIn->rate_ = 48000;
        mockIn->channels_ = 2;
        // 预录帧
        mockIn->pushFrames(std::vector<float>((size_t)(0.3 * 48000.0 * 2), 0.001f));

        auto virtNow = std::chrono::steady_clock::now();
        mockOut->writeHook = [&](const int32_t*, size_t frames) -> size_t {
            mockOut->frames_written_ += frames;
            mockOut->frames_rendered_ += frames;
            mockIn->pushFrames(std::vector<float>(frames * 2, 0.001f));
            return frames;
        };

        rta::dsp::RoomIoSeam seam;
        seam.createOutput = [mockOut]() { return std::make_unique<ProxyAudioOutput>(mockOut.get()); };
        seam.createInput = [mockIn]() { return std::make_unique<ProxyAudioInput>(mockIn.get()); };
        seam.now = [&virtNow]() { return virtNow; };
        seam.sleepFor = [&](std::chrono::milliseconds ms) {
            virtNow += ms;
            // 尾巴阶段拒绝提供更多采集数据，模拟采集硬件在此阶段挂死
        };

        rta::dsp::RoomTxConfig cfg;
        cfg.channels = 2;
        cfg.rate = 48000;
        cfg.captureStallMs = 200.0; // 快速超时

        rta::dsp::CoreAudioRoomTransport tx(cfg, seam);
        const std::vector<double> rec = tx.play_and_capture(sweep, 1000);

        ck(!tx.lastOk(), "尾巴采集停滞时必须判定失败（lastOk==false，不忽略返回值）");
        ck(tx.lastError().find("尾") != std::string::npos ||
           tx.lastError().find("采集端点停滞") != std::string::npos,
           "尾巴超时错误说明包含尾部停滞", tx.lastError());
    }

    // -------------------------------------------------------------------------
    // Test 1F: 播放硬件渲染排空超时未完成显式报错
    // -------------------------------------------------------------------------
    std::printf("\n-- Test 1F: 播放硬件渲染排空超时显式报错 --\n");
    {
        rta::dsp::SweepSpec spec;
        spec.fs = 48000;
        spec.durSec = 0.5;
        const std::vector<double> sweep = rta::dsp::generate_sweep(spec);

        auto mockOut = std::make_shared<MockAudioOutput>();
        auto mockIn = std::make_shared<MockAudioInput>();
        mockIn->rate_ = 48000;
        mockIn->channels_ = 2;
        mockIn->pushFrames(std::vector<float>((size_t)(0.3 * 48000.0 * 2), 0.001f));

        auto virtNow = std::chrono::steady_clock::now();
        mockOut->autoRender = false; // 手动控制渲染进度

        mockOut->writeHook = [&](const int32_t*, size_t frames) -> size_t {
            mockOut->frames_written_ += frames;
            // 模拟硬件渲染卡住：只渲染到写入的一半，便不再增加
            if (mockOut->frames_rendered_ < 10000) {
                mockOut->frames_rendered_ += frames / 2;
            }
            mockIn->pushFrames(std::vector<float>(frames * 2, 0.001f));
            return frames;
        };

        rta::dsp::RoomIoSeam seam;
        seam.createOutput = [mockOut]() { return std::make_unique<ProxyAudioOutput>(mockOut.get()); };
        seam.createInput = [mockIn]() { return std::make_unique<ProxyAudioInput>(mockIn.get()); };
        seam.now = [&virtNow]() { return virtNow; };
        seam.sleepFor = [&](std::chrono::milliseconds ms) {
            virtNow += ms;
            // 补充尾巴采集数据，让采集本身不报错，纯测排空
            mockIn->pushFrames(std::vector<float>((size_t)(ms.count() * 48 * 2), 0.001f));
        };

        rta::dsp::RoomTxConfig cfg;
        cfg.channels = 2;
        cfg.rate = 48000;
        cfg.writeStallMs = 200.0;
        cfg.captureStallMs = 1000.0;

        rta::dsp::CoreAudioRoomTransport tx(cfg, seam);
        const std::vector<double> rec = tx.play_and_capture(sweep, sweep.size() + 48000);

        ck(!tx.lastOk(), "硬件排空未完成且超时停滞必须报错（lastOk==false）");
        ck(tx.lastError().find("排空") != std::string::npos,
           "排空错误说明指明排空超时", tx.lastError());
    }

    // -------------------------------------------------------------------------
    // Test 1G: 多扬声器测量麦克风通道契约（不跟输出 activeCh 轮换）
    // -------------------------------------------------------------------------
    std::printf("\n-- Test 1G: 麦克风通道契约（多扬声器测量共用单声道测量麦）--\n");
    {
        rta::dsp::SweepSpec spec;
        spec.fs = 48000;
        spec.f0 = 40.0;
        spec.f1 = 18000.0;
        spec.durSec = 0.5;
        const std::vector<double> sweep = rta::dsp::generate_sweep(spec);

        rta::dsp::RoomLayout layout{};
        layout.name = "2.0";
        layout.chCount = 2;
        layout.chName[0] = "L";
        layout.chName[1] = "R";

        auto mockOut = std::make_shared<MockAudioOutput>();
        auto mockIn = std::make_shared<MockAudioInput>();
        mockIn->rate_ = 48000;
        mockIn->channels_ = 2;

        auto virtNow = std::chrono::steady_clock::now();

        auto feedPreRoll = [&]() {
            std::vector<float> preBlk((size_t)(0.3 * 48000.0 * 2), 0.0f);
            for (size_t i = 0; i < (size_t)(0.3 * 48000.0); ++i) {
                preBlk[i * 2 + 0] = (float)(1e-5 * std::sin((double)i * 0.2));
                preBlk[i * 2 + 1] = 0.0f;
            }
            mockIn->pushFrames(preBlk);
        };

        // 麦克风硬件接入在输入设备通道 0。输入设备通道 1 为空闲（全零）。
        mockOut->writeHook = [&](const int32_t*, size_t frames) -> size_t {
            mockOut->frames_written_ += frames;
            mockOut->frames_rendered_ += frames;
            std::vector<float> blk(frames * 2, 0.0f);
            for (size_t i = 0; i < frames; ++i) {
                // 通道 0 产生有效信号；通道 1 恒为 0（无麦克风）
                blk[i * 2 + 0] = (float)(0.2 * std::sin((double)i * 0.1) + 1e-4);
                blk[i * 2 + 1] = 0.0f;
            }
            mockIn->pushFrames(blk);
            return frames;
        };

        rta::dsp::RoomIoSeam seam;
        seam.createOutput = [mockOut]() {
            mockOut->frames_written_ = 0;
            mockOut->frames_rendered_ = 0;
            return std::make_unique<ProxyAudioOutput>(mockOut.get());
        };
        seam.createInput = [mockIn, feedPreRoll]() {
            mockIn->buffer_.clear();
            mockIn->readPos_ = 0;
            feedPreRoll();
            return std::make_unique<ProxyAudioInput>(mockIn.get());
        };
        seam.now = [&virtNow]() { return virtNow; };
        seam.sleepFor = [&](std::chrono::milliseconds ms) {
            virtNow += ms;
            std::vector<float> tailBlk((size_t)(ms.count() * 48 * 2), 0.0f);
            for (size_t i = 0; i < (size_t)(ms.count() * 48); ++i) {
                tailBlk[i * 2 + 0] = (float)(1e-5 * std::sin((double)i * 0.2));
                tailBlk[i * 2 + 1] = 0.0f;
            }
            mockIn->pushFrames(tailBlk);
        };

        rta::dsp::RoomTxConfig cfg;
        cfg.channels = 2;
        cfg.captureChannel = 0; // 测量麦克风接在输入通道 0
        cfg.rate = 48000;

        rta::dsp::CoreAudioRoomTransport tx(cfg, seam);
        rta::dsp::MeasurementSession session(spec, layout, -20.0);
        const rta::dsp::MeasurementSessionResult res = session.run(tx);

        ck(res.channels.size() == 2, "会话测量了 2 个声道");
        double peakAmpCh0 = 0.0;
        if (res.channels.size() > 0) {
            for (double v : res.channels[0].roomIr) peakAmpCh0 = std::max(peakAmpCh0, std::fabs(v));
        }
        double peakAmpCh1 = 0.0;
        if (res.channels.size() > 1) {
            for (double v : res.channels[1].roomIr) peakAmpCh1 = std::max(peakAmpCh1, std::fabs(v));
        }
        ck(peakAmpCh0 > 0.001, "声道 0 (L 扬声器) 脉冲响应幅度正常（非零）",
           "实际 peakAmpCh0=" + std::to_string(peakAmpCh0));
        ck(peakAmpCh1 > 0.001, "声道 1 (R 扬声器) 脉冲响应幅度正常（非零，未因声道轮转采到全零静音）",
           "实际 peakAmpCh1=" + std::to_string(peakAmpCh1));
    }

    // =========================================================================
    // §2 采集链路前置门禁（真开设备，需 RTA_ROOM_HW=1，CI/离线默认 SKIP）
    // =========================================================================
    std::printf("\n-- §2 采集链路前置门禁（物理输入真机校验）--\n");
    if (!env_on("RTA_ROOM_HW")) {
        std::printf("  [SKIP] 未设 RTA_ROOM_HW=1（离线任务绝不开物理设备）\n");
    } else {
        rta::platform::CoreAudioInput cap;
        rta::platform::MacCaptureConfig cc;
        cc.bufferMs = 200.0;
        if (!cap.open(cc)) {
            ck(false, "打开默认采集端点", cap.last_error());
        } else {
            ck(true, "打开默认采集端点", "rate=" + std::to_string(cap.rate()) +
                                        " ch=" + std::to_string(cap.channels()));
            if (!cap.start()) {
                ck(false, "启动采集", cap.last_error());
            } else {
                const int ch = cap.channels() > 0 ? cap.channels() : 2;
                std::vector<float> buf((size_t)ch * 4096);
                size_t total = 0, nonzero = 0;
                double peak = 0.0;
                const auto t0 = std::chrono::steady_clock::now();
                while (std::chrono::duration_cast<std::chrono::milliseconds>(
                           std::chrono::steady_clock::now() - t0).count() < 1200) {
                    const size_t got = cap.read_available(buf.data(), 4096);
                    if (!got) { std::this_thread::sleep_for(std::chrono::milliseconds(5)); continue; }
                    for (size_t i = 0; i < got * (size_t)ch; ++i) {
                        ++total;
                        if (buf[i] != 0.0f) ++nonzero;
                        const double a = std::fabs((double)buf[i]);
                        if (a > peak) peak = a;
                    }
                }
                cap.close();
                const double pct = total ? 100.0 * (double)nonzero / (double)total : 0.0;
                const double dbfs = peak > 0.0 ? 20.0 * std::log10(peak) : -999.0;
                std::printf("      采到 %zu 样本，非零占比 %.2f%%，峰值 %.2f dBFS\n", total, pct, dbfs);
                ck(total > 0, "采集有数据（不是零帧）", std::to_string(total) + " 样本");
                ck(pct > 1.0, "**前置门禁**：物理输入拿到非零样本（不是全零）",
                   "非零占比 " + std::to_string(pct) + "%");
            }
        }
    }

    // =========================================================================
    // §3 完整真机测量（需 RTA_ROOM_HW=1 且 RTA_ROOM_AUDIBLE=1，本任务禁止运行）
    // =========================================================================
    std::printf("\n-- §3 完整真机测量（需双重授权，本任务禁止运行）--\n");
    if (!(env_on("RTA_ROOM_HW") && env_on("RTA_ROOM_AUDIBLE"))) {
        std::printf("  [SKIP] 需同时设 RTA_ROOM_HW=1 且 RTA_ROOM_AUDIBLE=1 才会真出声\n");
        std::printf("         铁律 1：本任务严禁打开物理可听输出。\n");
    }

    std::printf("\n=======================================================\n");
    std::printf("%s（失败项 %d）\n", g_fail == 0 ? "全部通过" : "存在失败项", g_fail);
    return g_fail == 0 ? 0 : 1;
}
