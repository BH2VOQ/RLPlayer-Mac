// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_room_transport_coreaudio.cpp — R-1（房间测量 mac 传输层）的可复跑判据
//
// 判据来源：debug/20261027-00-BUG与新增功能总清单.md §3 R-1
//   "⚠️ 开工前置门禁：PLATFORM.md §13.10.6 记录本机采集录到全零（疑 TCC 门控）
//    ⟹ 必须先真机验「物理输入设备能否拿到非零样本」，否则做出链路全通却拿不到数据的空壳"
//
// 本测试分三段，**默认只跑第 1 段**（不开任何音频设备）：
//   §1 算法链（虚拟传输，零设备）：证明 MeasurementSession 在我们的传输接口上端到端能跑通
//      —— 用「已知 IR 的虚拟房间」合成录音，反卷积必须还原出该 IR 的峰位。
//   §2 采集链路（**真开设备**，需 RTA_ROOM_HW=1）：证明物理输入真能拿到非零样本。
//      这一条就是前置门禁；不设环境变量时 SKIP（CI/无人值守不碰设备）。
//   §3 完整真机测量（**真开设备 + 真出声**，需 RTA_ROOM_HW=1 且 RTA_ROOM_AUDIBLE=1）：
//      按铁律 1 打印醒目横幅，且电平默认 −20 dBFS（测量扫频本质可闻，必须显式授权）。
//
// 铁律 1：§1 全程不开设备；§2 只开**采集**不开播放（不会出声）；
//         §3 才出声，且必须先看横幅、必须显式设两个环境变量。
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "dsp/room_measurement.h"
#include "platform/macos/audio_in_coreaudio.h"
#include "platform/macos/room_transport_coreaudio.h"

static int g_fail = 0;
static void ck(bool cond, const char* what, const std::string& detail = "") {
    if (cond) std::printf("  [PASS] %s\n", what);
    else { std::printf("  [FAIL] %s  %s\n", what, detail.c_str()); ++g_fail; }
}
static bool env_on(const char* k) {
    const char* v = std::getenv(k);
    return v && std::string(v) == "1";
}

// ---- 虚拟房间传输：把扫频喂进一个「已知 IR」的卷积，再作为录音返回 ----
// 这样能证明：会话层 + 反卷积 + 质检这条链在我们的传输契约上是通的。
// 它不证明 CoreAudio 接线（那是 §2/§3），但能把"算法链坏了"与"设备坏了"分开。
class VirtualRoomTransport : public rta::dsp::MeasurementTransport {
public:
    // 房间 IR：单峰延迟 delayMs（模拟直达声到达时间）
    VirtualRoomTransport(double fs, double delayMs, double gain = 0.5)
        : fs_(fs), delayMs_(delayMs), gain_(gain) {}

    std::vector<double> play_and_capture(const std::vector<double>& out, size_t samplesToCapture) override {
        lastPlayed_ = out;
        const size_t n = samplesToCapture + out.size() + 16;
        std::vector<double> rec(n, 0.0);
        // 简单线性卷积（够用：证明链路，不追求效率）
        const size_t d = (size_t)(delayMs_ * 0.001 * fs_);
        for (size_t i = 0; i < out.size(); ++i) {
            const size_t j = i + d;
            if (j < rec.size()) rec[j] += gain_ * out[i];
        }
        // 加一点点确定性噪声（避免 SNR 无穷大掩盖问题；不用 rand 保证可复跑）
        for (size_t i = 0; i < rec.size(); ++i)
            rec[i] += 1e-6 * std::sin((double)i * 0.37);
        return rec;
    }
    const std::vector<double>& lastPlayed() const { return lastPlayed_; }

private:
    double fs_, delayMs_, gain_;
    std::vector<double> lastPlayed_;
};

int main() {
    std::printf("== R-1 房间测量 mac 传输层 ==\n");
    std::printf("   （§1 零设备；§2/§3 需 RTA_ROOM_HW=1，§3 还需 RTA_ROOM_AUDIBLE=1）\n");

    // ================= §1 算法链（虚拟传输，零设备）=================
    std::printf("\n-- §1 算法链（虚拟房间，不开任何音频设备）--\n");
    {
        // SweepSpec 真实字段是 fs/f0/f1/durSec（不是 f2/seconds）
        rta::dsp::SweepSpec spec;
        spec.fs = 48000;
        spec.f0 = 40.0;
        spec.f1 = 18000.0;
        spec.durSec = 1.0;

        // RoomLayout 的 chName 是**固定数组** chName[12]，不能整体赋值
        rta::dsp::RoomLayout layout{};
        layout.name = "2.0";
        layout.chCount = 2;
        layout.sub = false;
        layout.crossoverHz = 80.0;
        layout.chName[0] = "L";
        layout.chName[1] = "R";

        const double kDelayMs = 12.0;
        VirtualRoomTransport vtx(spec.fs, kDelayMs);
        rta::dsp::MeasurementSession session(spec, layout, -20.0);
        const rta::dsp::MeasurementSessionResult res = session.run(vtx);

        ck(res.channels.size() == 2, "会话产出 2 个声道的测量结果",
           std::to_string(res.channels.size()));
        ck(!res.aborted, "会话未中止（aborted=false）");

        bool allValid = true, peakOk = true;
        for (const auto& ch : res.channels) {
            if (!ch.valid) allValid = false;
            // 反卷积应还原出约 12 ms 的峰（容差 ±3 ms：扫频带宽与窗函数会带来少许偏移）
            if (std::fabs(ch.peakMs - kDelayMs) > 3.0) {
                peakOk = false;
                std::printf("      声道 %s peakMs=%.2f（期望约 %.0f）\n",
                            ch.channelName.c_str(), ch.peakMs, kDelayMs);
            }
        }
        ck(allValid, "所有声道 valid=true（反卷积与质检都通过）");
        ck(peakOk, "反卷积还原出已知直达声峰位（约 12 ms，容差 ±3 ms）");
        ck(!vtx.lastPlayed().empty(), "传输层确实收到了要播放的扫频（不是空跑）");
    }

    // ================= §2 采集链路前置门禁（真开设备，只采集不出声）=================
    std::printf("\n-- §2 采集链路前置门禁（只开采集，不出声）--\n");
    if (!env_on("RTA_ROOM_HW")) {
        std::printf("  [SKIP] 未设 RTA_ROOM_HW=1（默认不碰音频设备）\n");
        std::printf("         这一条是 R-1 的**开工前置门禁**：物理输入必须能拿到非零样本。\n");
    } else {
        // 直接开采集 1 秒，统计非零占比与峰值 —— 与 tools/rtaloop record-input 同口径
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

    // ================= §3 完整真机测量（真出声，需双重授权）=================
    std::printf("\n-- §3 完整真机测量（真出声，铁律 1 需双重授权）--\n");
    if (!(env_on("RTA_ROOM_HW") && env_on("RTA_ROOM_AUDIBLE"))) {
        std::printf("  [SKIP] 需同时设 RTA_ROOM_HW=1 且 RTA_ROOM_AUDIBLE=1 才会真出声\n");
        std::printf("         铁律 1：扫频本质可闻，必须由用户显式授权，绝不默认播。\n");
    } else {
        std::printf("\n");
        std::printf("  ##############################################################\n");
        std::printf("  #  ⚠️  即将向【默认输出设备】播放可听扫频（房间测量）        #\n");
        std::printf("  #  设备：系统默认输出    时长：约 1 秒 × 声道数              #\n");
        std::printf("  #  电平：-20 dBFS（测量扫频本质可闻，这不是测试音）          #\n");
        std::printf("  #  共享模式：不会静音系统其它声音                            #\n");
        std::printf("  ##############################################################\n\n");
        rta::dsp::RoomTxConfig cfg;
        cfg.channels = 2;
        rta::dsp::CoreAudioRoomTransport tx(cfg);
        tx.log = [](const std::string& s) { std::printf("      ROOMTX %s\n", s.c_str()); };

        rta::dsp::SweepSpec spec;
        spec.fs = 48000;
        spec.f0 = 40.0;
        spec.f1 = 18000.0;
        spec.durSec = 1.0;
        rta::dsp::RoomLayout layout{};
        layout.name = "2.0";
        layout.chCount = 2;
        layout.sub = false;
        layout.crossoverHz = 80.0;
        layout.chName[0] = "L";
        layout.chName[1] = "R";

        rta::dsp::MeasurementSession session(spec, layout, -20.0);
        const auto res = session.run(tx);
        if (!tx.lastOk()) {
            std::printf("      传输层错误：%s\n", tx.lastError().c_str());
        }
        ck(res.channels.size() == 2, "真机测量产出 2 声道结果", std::to_string(res.channels.size()));
        for (const auto& ch : res.channels) {
            std::printf("      %s valid=%d peakMs=%.2f snr=%.1f dB\n",
                        ch.channelName.c_str(), (int)ch.valid, ch.peakMs, ch.snrDb);
        }
        bool anyValid = false;
        for (const auto& ch : res.channels) if (ch.valid) anyValid = true;
        ck(anyValid, "真机测量至少一个声道有效（采集链路端到端打通）");
    }

    std::printf("\n=======================================================\n");
    std::printf("%s（失败项 %d）\n", g_fail == 0 ? "全部通过" : "存在失败项", g_fail);
    return g_fail == 0 ? 0 : 1;
}
