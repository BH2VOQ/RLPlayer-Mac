// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
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
#include <string>
#include <thread>
#include <vector>

#include "../audio_out_factory.h"
#include "../audio_out.h"
#include "audio_in_coreaudio.h"
#include "dsp/room_measurement.h"

namespace rta::dsp {

struct RoomTxConfig {
    std::string playDeviceId;      // 空 = 默认输出端点
    std::string captureDeviceId;   // 空 = 默认采集端点
    int         channels = 2;      // 参与测量的声道数
    double      tailMs = 800.0;    // 播放结束后继续录多久（房间混响）
    double      preRollMs = 300.0; // 播放前先录多久（本底噪声，质检用）
    // 停滞上限（照抄上游教训：设备被占用时不能无限等，否则整条测量链挂死）
    double      writeStallMs = 3000.0;
    double      captureStallMs = 5000.0;
    uint32_t    rate = 48000;      // 目标采样率；设备不支持时按实际混音率工作
};

class CoreAudioRoomTransport : public MeasurementTransport {
public:
    explicit CoreAudioRoomTransport(RoomTxConfig cfg) : cfg_(std::move(cfg)) {}
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
        auto sink = rta::platform::create_audio_output();
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
        rta::platform::CoreAudioInput cap;
        rta::platform::MacCaptureConfig cc;
        cc.deviceId = cfg_.captureDeviceId;
        cc.bufferMs = 200.0;
        if (!cap.open(cc)) {
            err_ = "打开采集端点失败：" + cap.last_error();
            sink->close();
            return {};
        }
        rate_ = (double)(cap.rate() ? cap.rate() : spec.rate);
        const int capCh = cap.channels() > 0 ? cap.channels() : 2;
        capName_ = cfg_.captureDeviceId.empty() ? std::string("<default>") : cfg_.captureDeviceId;
        if (!cap.start()) {
            err_ = "启动采集失败：" + cap.last_error();
            sink->close(); cap.close();
            return {};
        }

        const size_t preN  = (size_t)(cfg_.preRollMs * 0.001 * rate_);
        const size_t tailN = (size_t)(cfg_.tailMs   * 0.001 * rate_);
        std::vector<float> rec;
        rec.reserve((preN + out.size() + tailN + 8192) * (size_t)capCh);

        auto drain = [&]() {
            std::vector<float> tmp((size_t)capCh * 2048);
            for (;;) {
                const size_t got = cap.read_available(tmp.data(), 2048);
                if (got == 0) break;
                rec.insert(rec.end(), tmp.begin(), tmp.begin() + (std::ptrdiff_t)(got * (size_t)capCh));
            }
        };
        auto frames = [&]() { return rec.size() / (size_t)capCh; };
        // 返回 false = 超时（采集端没有推进），调用方必须中止而不是继续等
        auto waitUntil = [&](size_t want, double limitMs) -> bool {
            const int spins = (int)(limitMs / 2.0);
            for (int i = 0; i < spins && frames() < want; ++i) {
                drain();
                if (frames() >= want) return true;
                if (cancelled && cancelled()) return true;
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            }
            return frames() >= want;
        };

        // ---- 3) 预录（吃本底噪声，质检的 SNR 要用）----
        if (!waitUntil(preN, cfg_.captureStallMs)) {
            err_ = "采集端点无数据（预录阶段），检查采集设备是否可用 / 是否被 TCC 门控";
            if (log) log("ROOMTX " + err_);
            sink->close(); cap.close();
            captured_ = 0;
            return {};
        }

        // ---- 4) 边播边录：严格 1:1 推进 ----
        // 上游 2026-10-26 的教训（照抄正确做法）：写完多少帧就等采集也到多少帧。
        // 旧写法 waitUntil(preN + written/2) 让播放快于实时、录音按实时走 ⟹ 两者错位，
        // 3 秒扫频却在 peakMs=10049 处出峰。
        const int playCh = spec.channels > 0 ? spec.channels : 2;
        const int activeCh = (playCh > 0) ? (curCh_ % playCh) : 0;
        if (log) log("ROOMTX play dev=" + playName_ + " ch=" + std::to_string(playCh) +
                     " active=" + std::to_string(activeCh));
        ++curCh_;

        // int32 交错缓冲：把 double 单声道铺到 activeCh 一路，其余声道补 0
        std::vector<int32_t> blk((size_t)playCh * 480);
        size_t written = 0;
        bool writeStalled = false;
        const auto t0 = std::chrono::steady_clock::now();
        while (written < out.size()) {
            if (cancelled && cancelled()) break;
            const size_t n = std::min<size_t>(480, out.size() - written);
            for (size_t i = 0; i < n; ++i) {
                const double v = std::max(-1.0, std::min(1.0, out[written + i]));
                const int32_t s = (int32_t)std::llround(v * 2147483647.0);
                for (int c = 0; c < playCh; ++c)
                    blk[(size_t)i * (size_t)playCh + (size_t)c] = (c == activeCh) ? s : 0;
            }
            size_t off = 0;
            while (off < n) {
                const size_t w = sink->write(blk.data() + off * (size_t)playCh, n - off);
                if (w == 0) {
                    // 写不进：可能是设备阻塞。按停滞上限中止，绝不无限等。
                    const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                        std::chrono::steady_clock::now() - t0).count();
                    if ((double)ms > cfg_.writeStallMs) { writeStalled = true; break; }
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                    continue;
                }
                off += w;
            }
            if (writeStalled) break;
            written += n;
            // ★ 1:1：等采集也推进到 written 帧（保证扫频与录音不错位）
            if (!waitUntil(preN + written, cfg_.captureStallMs)) {
                err_ = "采集端点停滞（边播边录阶段），录音与播放已错位，中止以免给出错误 IR";
                if (log) log("ROOMTX " + err_);
                sink->close(); cap.close();
                captured_ = frames();
                return {};
            }
        }
        if (writeStalled) {
            err_ = "播放端点连续写不进（设备被占用？），已中止";
            if (log) log("ROOMTX " + err_);
            sink->close(); cap.close();
            captured_ = frames();
            return {};
        }

        // ---- 5) 尾巴（房间混响）----
        waitUntil(preN + out.size() + tailN, cfg_.captureStallMs);
        drain();

        sink->close();
        cap.close();
        captured_ = frames();
        rate_ = rate_ > 0 ? rate_ : 48000.0;

        if (captured_ < samplesToCapture) {
            err_ = "录得样本不足（" + std::to_string(captured_) + " < " +
                   std::to_string(samplesToCapture) + "），检查采集设备或提高 tailMs";
            if (log) log("ROOMTX " + err_);
            return {};
        }

        // 采集是多声道交错 ⟹ 取 activeCh 那一路转 double（与上游一致：逐声道顺序调用）
        std::vector<double> mono;
        mono.reserve(captured_);
        const int srcCh = (activeCh < capCh) ? activeCh : 0;
        for (size_t f = 0; f < captured_; ++f)
            mono.push_back((double)rec[f * (size_t)capCh + (size_t)srcCh]);

        ok_ = true;
        return mono;
    }

private:
    RoomTxConfig cfg_;
    bool ok_ = false;
    std::string err_;
    size_t captured_ = 0;
    double rate_ = 0.0;
    std::string playName_, capName_;
    int curCh_ = 0;    // 逐声道轮转（会话层顺序调用本函数）
};

} // namespace rta::dsp
