// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// room_transport_coreaudio.h — 房间测量的 mac 传输实现（对应上游 room_transport_wasapi.h）
//
// 为什么需要这一层：`room_measurement.h` 定义的是**接口**（MeasurementTransport），
// 只依赖它就能用虚拟传输端到端测算法（tests/test_room_measurement.cpp 的既有判据）。
// 真实实现要碰 CoreAudio 播放与采集，放进 dsp/ 会污染算法层 ⟹ 放 platform/macos/，由 rtaweb 接线。
//
// ★ 铁律 1：扫频本质可闻。调用方（/api/roomcorr/measure）必须先在 UI 把
//   「设备名 / 时长 / 电平 / 会静音系统声音」四项摊开、用户点确认后，才允许带 confirm=1 调用。
//   本类**不做任何电平放大**，用 MeasurementSession 给的电平（缺省 −20 dBFS）。
//
// mac 与上游 WASAPI 版的**本质差异**（不是照抄，是重新设计）：
//   · 播放：`CoreAudioOutput`（共享模式，不抢 Hog ⟹ 系统其它声音不会被静音，
//     但共享模式下系统混音器在路径上，其它程序的声音会混进录音 —— 正式测量请静音其它程序）
//   · 采集：`CoreAudioInput`（AUHAL 输入）。**不走 loopback tap**：
//     loopback 抓的是「系统正在播放的声音」，测量要的是**物理麦克风听到的房间声**，
//     这两者在原理上就是不同的信号（见 PLATFORM.md §13.10.6）。
//   · 时序：与上游同为「开采集 → 预录 → 边播边录 → 再录尾巴」，
//     且播放与采集**严格 1:1 推进**（上游 2026-10-26 实机踩过 0.5 帧/帧的错位坑，这里照抄正确做法）。
//
// ⚠️ 本机实测前置（2026-10-27，已验通）：
//   物理输入 USB Camera 麦克风 `record-input` 抓到 48128 帧，非零样本占 **99.44%**、
//   峰值 −42.04 dBFS ⟹ 采集链路**能拿到真实信号**，不是 PLATFORM.md §13.10.6 记录的全零。
//   若换机器后采集全零，请先重跑 tools/rtaloop record-input 排除 TCC/无音源，再怀疑本实现。
#pragma once

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <functional>
#include <memory>
#include <numeric>
#include <string>
#include <thread>
#include <vector>

#include "../audio_out_factory.h"
#include "../audio_out.h"
#include "audio_in_coreaudio.h"
#include "dsp/resampler.h"
#include "dsp/room_measurement.h"

namespace rta::dsp {

// 辅助单声道多相 Sinc 重采样（带群延迟对齐与样本截断，保证直达声峰位与时长守恒）
inline std::vector<double> resample_mono_aligned(const std::vector<double>& in, uint32_t inRate, uint32_t outRate) {
    if (in.empty() || inRate == 0 || outRate == 0) return {};
    if (inRate == outRate) return in;

    rta::dsp::ResamplerConfig rcfg;
    rcfg.inRate = inRate;
    rcfg.outRate = outRate;
    rcfg.channels = 1;
    rcfg.totalTaps = 3072;
    rcfg.transition = 0.05;
    rcfg.attenDb = 120.0;

    const uint32_t g = std::gcd(inRate, outRate);
    const int L = (int)(outRate / g);
    if (L > 0) {
        int T = 3072 / L;
        if (T < 31) T = 31;
        if ((T % 2) == 0) ++T; // 选奇数抽头，使群延迟在整倍数
        rcfg.minTapsPerInput = T;
    }

    rta::dsp::PolyphaseResampler rs(rcfg);
    const double delayOut = rs.latencyInputSamples() * (double)outRate / (double)inRate;
    const size_t discardOut = (size_t)std::llround(delayOut);

    const size_t targetFrames = (size_t)std::llround((double)in.size() * (double)outRate / (double)inRate);
    const size_t flushIn = (size_t)rs.tapsPerPhase() + 64;

    std::vector<double> paddedIn = in;
    paddedIn.resize(in.size() + flushIn, 0.0);

    const size_t maxOut = rs.maxOutFrames(paddedIn.size());
    std::vector<double> rawOut(maxOut, 0.0);
    const double* inP = paddedIn.data();
    double* outP = rawOut.data();
    const size_t produced = rs.process(&inP, paddedIn.size(), &outP);

    std::vector<double> out;
    out.reserve(targetFrames);
    for (size_t i = 0; i < targetFrames; ++i) {
        const size_t srcIdx = discardOut + i;
        if (srcIdx < produced) {
            out.push_back(rawOut[srcIdx]);
        } else {
            out.push_back(0.0);
        }
    }
    return out;
}

struct RoomTxConfig {
    std::string playDeviceId;      // 空 = 默认输出端点
    std::string captureDeviceId;   // 空 = 默认采集端点
    int         channels = 2;      // 参与测量的声道数
    int         captureChannel = 0;// 测量麦克风声道（默认 0，即第一声道单声道麦；多扬声器共用同一个测量麦）
    double      tailMs = 800.0;    // 播放结束后继续录多久（房间混响）
    double      preRollMs = 300.0; // 播放前先录多久（本底噪声，质检用）
    // 停滞上限（照抄上游教训：设备被占用时不能无限等，否则整条测量链挂死）
    double      writeStallMs = 3000.0;
    double      captureStallMs = 5000.0;
    uint32_t    rate = 48000;      // 目标采样率；设备不支持时按实际混音率工作
};

// 抽象音频输入接口（供生产 CoreAudioInput 与离线测试 seam 统一实现）
class RoomAudioInput {
public:
    virtual ~RoomAudioInput() = default;
    virtual bool open(const rta::platform::MacCaptureConfig& cfg) = 0;
    virtual bool start() = 0;
    virtual bool stop() = 0;
    virtual void close() = 0;
    virtual size_t read_available(float* dst, size_t maxFrames) = 0;
    virtual uint32_t rate() const = 0;
    virtual int channels() const = 0;
    virtual const std::string& last_error() const = 0;
};

// 生产默认适配器：委托给真实的 CoreAudioInput
class DefaultCoreAudioInput : public RoomAudioInput {
public:
    bool open(const rta::platform::MacCaptureConfig& cfg) override { return cap_.open(cfg); }
    bool start() override { return cap_.start(); }
    bool stop() override { return cap_.stop(); }
    void close() override { cap_.close(); }
    size_t read_available(float* dst, size_t maxFrames) override { return cap_.read_available(dst, maxFrames); }
    uint32_t rate() const override { return cap_.rate(); }
    int channels() const override { return cap_.channels(); }
    const std::string& last_error() const override { return cap_.last_error(); }
private:
    rta::platform::CoreAudioInput cap_;
};

// IO Seam 注入结构体：允许测试注入 Mock 音频输入/输出以及时钟控制
struct RoomIoSeam {
    std::function<std::unique_ptr<rta::platform::AudioOutput>()> createOutput;
    std::function<std::unique_ptr<RoomAudioInput>()> createInput;
    std::function<std::chrono::steady_clock::time_point()> now;
    std::function<void(std::chrono::milliseconds)> sleepFor;
};

class CoreAudioRoomTransport : public MeasurementTransport {
public:
    explicit CoreAudioRoomTransport(RoomTxConfig cfg, RoomIoSeam seam = {})
        : cfg_(std::move(cfg)), seam_(std::move(seam)) {}
    ~CoreAudioRoomTransport() override = default;

    bool lastOk() const { return ok_; }
    const std::string& lastError() const { return err_; }
    // 日志注入（dsp 层不依赖 rtaweb 的 play_log；由调用方接 rlplayer-playback.log）
    std::function<void(const std::string&)> log;
    size_t capturedSamples() const { return captured_; }
    double captureRate() const { return rate_; }
    const std::string& playName() const { return playName_; }
    const std::string& capName() const { return capName_; }

    std::vector<double> play_and_capture(const std::vector<double>& out, size_t samplesToCapture) override {
        ok_ = false; err_.clear(); captured_ = 0;
        if (out.empty()) { err_ = "扫频信号为空"; return {}; }

        auto now = [&]() {
            return seam_.now ? seam_.now() : std::chrono::steady_clock::now();
        };
        auto sleepFor = [&](std::chrono::milliseconds ms) {
            if (seam_.sleepFor) seam_.sleepFor(ms);
            else std::this_thread::sleep_for(ms);
        };

        // ---- 1) 播放端点（共享模式）----
        // 共享模式的理由：房间测量时用户要能听到扫频（这是刻意的、已确认的可闻信号），
        // 且独占会抢 Hog ⟹ 测量期间系统其它声音全没了，用户容易以为程序挂了。
        rta::platform::OpenSpec spec;
        spec.deviceId = cfg_.playDeviceId;
        spec.rate = cfg_.rate ? cfg_.rate : 48000;
        spec.bits = 32;
        spec.channels = (cfg_.channels > 0) ? cfg_.channels : 2;
        spec.bufferMs = 100.0;
        spec.shared = true;          // 共享：不抢 Hog
        spec.exclusive = false;      // 显式不抢 Hog（字段名是 exclusive，不是 hogExclusive）
        std::unique_ptr<rta::platform::AudioOutput> sink;
        if (seam_.createOutput) sink = seam_.createOutput();
        else sink = rta::platform::create_audio_output();
        if (!sink) { err_ = "无法创建 CoreAudio 输出后端"; return {}; }
        if (!sink->open(spec)) {
            err_ = "打开播放端点失败：" + sink->last_error();
            return {};
        }
        playName_ = spec.deviceId.empty() ? std::string("<default>") : spec.deviceId;
        if (!sink->start()) {
            err_ = "启动播放失败：" + sink->last_error();
            sink->close();
            return {};
        }

        // ---- 2) 采集端点 ----
        std::unique_ptr<RoomAudioInput> cap;
        if (seam_.createInput) cap = seam_.createInput();
        else cap = std::make_unique<DefaultCoreAudioInput>();
        rta::platform::MacCaptureConfig cc;
        cc.deviceId = cfg_.captureDeviceId;
        cc.bufferMs = 200.0;
        if (!cap->open(cc)) {
            err_ = "打开采集端点失败：" + cap->last_error();
            sink->close();
            return {};
        }
        const uint32_t capRateInt = cap->rate() ? cap->rate() : spec.rate;
        rate_ = (double)capRateInt;
        const int capCh = cap->channels() > 0 ? cap->channels() : 2;
        capName_ = cfg_.captureDeviceId.empty() ? std::string("<default>") : cfg_.captureDeviceId;
        if (!cap->start()) {
            err_ = "启动采集失败：" + cap->last_error();
            sink->close(); cap->close();
            return {};
        }

        const double playRate = (double)spec.rate;
        const double capRate = rate_;

        const size_t preN  = (size_t)std::llround(cfg_.preRollMs * 0.001 * capRate);
        const size_t tailN = (size_t)std::llround(cfg_.tailMs   * 0.001 * capRate);
        const size_t sweepCapN = (size_t)std::llround((double)out.size() * capRate / playRate);
        const size_t totalExpectedCap = preN + sweepCapN + tailN;

        std::vector<float> rec;
        rec.reserve((totalExpectedCap + 8192) * (size_t)capCh);

        auto drain = [&]() {
            std::vector<float> tmp((size_t)capCh * 2048);
            for (;;) {
                const size_t got = cap->read_available(tmp.data(), 2048);
                if (got == 0) break;
                rec.insert(rec.end(), tmp.begin(), tmp.begin() + (std::ptrdiff_t)(got * (size_t)capCh));
            }
        };
        auto frames = [&]() { return rec.size() / (size_t)capCh; };

        enum class WaitStatus {
            Reached,
            Timeout,
            Cancelled
        };
        auto waitUntil = [&](size_t want, double limitMs) -> WaitStatus {
            const int spins = (int)(limitMs / 2.0);
            for (int i = 0; i < spins && frames() < want; ++i) {
                drain();
                if (frames() >= want) return WaitStatus::Reached;
                if (cancelled && cancelled()) return WaitStatus::Cancelled;
                sleepFor(std::chrono::milliseconds(2));
            }
            if (cancelled && cancelled()) return WaitStatus::Cancelled;
            drain();
            return frames() >= want ? WaitStatus::Reached : WaitStatus::Timeout;
        };

        // ---- 3) 预录（吃本底噪声，质检的 SNR 要用）----
        WaitStatus ws = waitUntil(preN, cfg_.captureStallMs);
        if (ws == WaitStatus::Cancelled) {
            err_ = "测量已由用户取消";
            if (log) log("ROOMTX " + err_);
            sink->close(); cap->close();
            return {};
        }
        if (ws != WaitStatus::Reached) {
            err_ = "采集端点无数据（预录阶段），检查采集设备是否可用 / 是否被 TCC 门控";
            if (log) log("ROOMTX " + err_);
            sink->close(); cap->close();
            captured_ = 0;
            return {};
        }

        // ---- 4) 边播边录：严格 1:1 推进（解决跨采样率混时基缺陷）----
        const int playCh = spec.channels > 0 ? spec.channels : 2;
        const int activeCh = (playCh > 0) ? (curCh_ % playCh) : 0;
        if (log) log("ROOMTX play dev=" + playName_ + " ch=" + std::to_string(playCh) +
                     " active=" + std::to_string(activeCh));
        ++curCh_;

        // int32 交错缓冲：把 double 单声道铺到 activeCh 一路，其余声道补 0
        std::vector<int32_t> blk((size_t)playCh * 480);
        size_t written = 0;
        bool writeStalled = false;
        bool userCancelled = false;
        auto lastProgress = now(); // 从最后成功写入计时（解决整段 t0 假超时缺陷）

        while (written < out.size()) {
            if (cancelled && cancelled()) { userCancelled = true; break; }
            const size_t n = std::min<size_t>(480, out.size() - written);
            for (size_t i = 0; i < n; ++i) {
                const double v = std::max(-1.0, std::min(1.0, out[written + i]));
                const int32_t s = (int32_t)std::llround(v * 2147483647.0);
                for (int c = 0; c < playCh; ++c)
                    blk[(size_t)i * (size_t)playCh + (size_t)c] = (c == activeCh) ? s : 0;
            }
            size_t off = 0;
            while (off < n) {
                if (cancelled && cancelled()) { userCancelled = true; break; }
                const size_t w = sink->write(blk.data() + off * (size_t)playCh, n - off);
                if (w == 0) {
                    // 写不进：按最后一次成功写入之后的连续停滞时长判断
                    const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                        now() - lastProgress).count();
                    if ((double)ms > cfg_.writeStallMs) { writeStalled = true; break; }
                    sleepFor(std::chrono::milliseconds(1));
                    continue;
                }
                off += w;
                lastProgress = now(); // 成功写入，重置停滞计时器
            }
            if (userCancelled || writeStalled) break;
            written += n;

            // ★ 1:1：等采集也推进到对应时间帧数（按 capRate/playRate 严格换算时基）
            const size_t targetCap = preN + (size_t)std::llround((double)written * capRate / playRate);
            ws = waitUntil(targetCap, cfg_.captureStallMs);
            if (ws == WaitStatus::Cancelled) { userCancelled = true; break; }
            if (ws != WaitStatus::Reached) {
                err_ = "采集端点停滞（边播边录阶段），录音与播放已错位，中止以免给出错误 IR";
                if (log) log("ROOMTX " + err_);
                sink->close(); cap->close();
                captured_ = frames();
                return {};
            }
        }

        if (userCancelled) {
            err_ = "测量已由用户取消";
            if (log) log("ROOMTX " + err_);
            sink->close(); cap->close();
            captured_ = 0;
            return {};
        }
        if (writeStalled) {
            err_ = "播放端点连续写不进（设备被占用？），已中止";
            if (log) log("ROOMTX " + err_);
            sink->close(); cap->close();
            captured_ = frames();
            return {};
        }

        // ---- 5) 尾巴（房间混响）：检查返回值，绝不静默忽略 ----
        ws = waitUntil(totalExpectedCap, cfg_.captureStallMs);
        if (ws == WaitStatus::Cancelled) {
            err_ = "测量已由用户取消";
            if (log) log("ROOMTX " + err_);
            sink->close(); cap->close();
            return {};
        }
        if (ws != WaitStatus::Reached) {
            err_ = "采集端点停滞（尾部混响阶段），录音不完整，已中止";
            if (log) log("ROOMTX " + err_);
            sink->close(); cap->close();
            return {};
        }
        drain();

        // ---- 6) 播放硬件渲染排空确认 ----
        if (written > 0) {
            const double drainTimeoutMs = (cfg_.writeStallMs > 0 ? cfg_.writeStallMs : 3000.0);
            bool drainTimedOut = false;
            size_t lastRendered = sink->frames_rendered();
            auto lastRenderProgress = now();

            while (sink->frames_rendered() < written) {
                if (cancelled && cancelled()) {
                    err_ = "测量已由用户取消";
                    if (log) log("ROOMTX " + err_);
                    sink->close(); cap->close();
                    return {};
                }
                const size_t cur = sink->frames_rendered();
                if (cur > lastRendered) {
                    lastRendered = cur;
                    lastRenderProgress = now();
                } else {
                    const auto stall = std::chrono::duration_cast<std::chrono::milliseconds>(
                        now() - lastRenderProgress).count();
                    if ((double)stall > drainTimeoutMs) {
                        drainTimedOut = true;
                        break;
                    }
                }
                sleepFor(std::chrono::milliseconds(2));
            }
            if (drainTimedOut) {
                err_ = "播放端点排空超时（硬件渲染停滞），已中止";
                if (log) log("ROOMTX " + err_);
                sink->close(); cap->close();
                return {};
            }
        }

        sink->close();
        cap->close();
        captured_ = frames();

        // 采集是多声道交错 ⟹ 取指定的测量麦克风声道（不随输出 activeCh 轮换）
        std::vector<double> rawMono;
        rawMono.reserve(captured_);
        const int micCh = (cfg_.captureChannel >= 0 && cfg_.captureChannel < capCh) ? cfg_.captureChannel : 0;
        for (size_t f = 0; f < captured_; ++f)
            rawMono.push_back((double)rec[f * (size_t)capCh + (size_t)micCh]);

        // ---- 7) 重采样回到 session rate（若采集采样率与播放会话率不同）----
        std::vector<double> sessionMono;
        if (capRateInt != spec.rate) {
            sessionMono = resample_mono_aligned(rawMono, capRateInt, spec.rate);
        } else {
            sessionMono = std::move(rawMono);
        }

        captured_ = sessionMono.size();
        rate_ = (double)spec.rate; // 交付给算法层的样本率与会话一致

        if (captured_ < samplesToCapture) {
            err_ = "录得样本不足（" + std::to_string(captured_) + " < " +
                   std::to_string(samplesToCapture) + "），检查采集设备或提高 tailMs";
            if (log) log("ROOMTX " + err_);
            return {};
        }

        ok_ = true;
        return sessionMono;
    }

private:
    RoomTxConfig cfg_;
    RoomIoSeam seam_;
    bool ok_ = false;
    std::string err_;
    size_t captured_ = 0;
    double rate_ = 0.0;
    std::string playName_, capName_;
    int curCh_ = 0;    // 逐输出声道轮转（会话层顺序调用本函数）
};

} // namespace rta::dsp
