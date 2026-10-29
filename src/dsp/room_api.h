// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// room_api.h — R-1 房间测量的**生产端点层**（与 DSP 会话解耦，便于离线判据）
//
// 为什么单独抽出来（铁律 3）：测量扫频本质可闻，铁律 1 要求"必须用户显式授权"。
// 把"授权校验 / 设备与电平披露 / 并发保护 / 取消"这些**决定是否出声**的逻辑
// 放进 HTTP handler 里，就只能靠人工点按钮验证；抽到这里可以用假传输层跑真判据。
//
// 端点契约（rtaweb.cpp 接线）：
//   GET  /api/roomcorr/layouts   → 可选布局（2.0/2.1/5.1/7.1/5.1.2/7.1.4）与说明
//   GET  /api/roomcorr/plan      → **只读**：这次测量会用到哪些设备、多长、多响（供 UI 展示）
//   POST /api/roomcorr/measure   → 真正开始测量。**必须带 confirm=1**，否则 428 拒绝
//   POST /api/roomcorr/cancel    → 请求取消（会话在下一个声道边界退出）
//   GET  /api/roomcorr/status    → 进度/结果
//
// 铁律 1 的落地点（缺一不可）：
//   1. 没有 confirm=1 ⟹ 不开任何设备（返回 428 + 完整的"将发生什么"说明）；
//   2. confirm=1 也必须先过 plan：扫频时长、电平、目标设备名都要能报给用户；
//   3. 电平上限 −20 dBFS（测量扫频本质可闻，这是"已授权"的最小档，不是随便放大）；
//   4. 共享模式，绝不抢 Hog（测量时用户还要能听到别的声音、能随时喊停）。
#pragma once

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "dsp/room_measurement.h"

namespace rta::dsp {

struct RoomPlan {
    bool ok = false;
    std::string error;
    std::string layout;          // "2.0"
    int chCount = 0;
    double sweepSeconds = 0;     // 每声道扫频时长
    double totalSeconds = 0;     // 全部声道（含尾巴）
    double levelDbfs = -20.0;    // 固定上限，不接受客户端放大
    double fs = 48000;
    std::string playDevice;      // 给用户看的目标设备名
    std::string captureDevice;
    std::string warning;         // 铁律 1 的横幅正文
};

// 只读地算出"这次测量会发生什么"。**不打开任何设备**。
inline RoomPlan room_make_plan(const std::string& layoutName,
                               double sweepSeconds = 6.0,
                               double tailMs = 800.0,
                               const std::string& playDev = std::string(),
                               const std::string& capDev = std::string()) {
    RoomPlan plan;
    plan.layout = layoutName.empty() ? std::string("2.0") : layoutName;
    const std::vector<RoomLayout> all = room_layouts();
    const RoomLayout* chosen = nullptr;
    for (const auto& l : all) if (plan.layout == (l.name ? l.name : "")) { chosen = &l; break; }
    if (!chosen) {
        plan.error = "未知的声道布局：" + plan.layout;
        return plan;
    }
    if (!(sweepSeconds > 0.2 && sweepSeconds <= 30.0)) {
        plan.error = "扫频时长必须在 0.2~30 秒之间（收到 " + std::to_string(sweepSeconds) + "）";
        return plan;
    }
    if (!(tailMs >= 0.0 && tailMs <= 5000.0)) {
        plan.error = "尾巴时长必须在 0~5000 ms 之间";
        return plan;
    }
    plan.chCount = chosen->chCount;
    plan.sweepSeconds = sweepSeconds;
    // 每声道 = 预录(0.3s) + 扫频 + 尾巴 + 多录 1s（会话层固定多录 1 秒）
    plan.totalSeconds = (double)plan.chCount * (0.3 + sweepSeconds + tailMs / 1000.0 + 1.0);
    plan.levelDbfs = -20.0;
    plan.playDevice = playDev.empty() ? std::string("系统默认输出") : playDev;
    plan.captureDevice = capDev.empty() ? std::string("系统默认输入") : capDev;
    plan.warning =
        "即将向【" + plan.playDevice + "】播放可听扫频（房间测量）：" +
        std::to_string(plan.chCount) + " 个声道 × " +
        std::to_string((int)(sweepSeconds * 1000)) + " ms，电平 " +
        std::to_string((int)plan.levelDbfs) + " dBFS，共约 " +
        std::to_string((int)(plan.totalSeconds + 0.5)) + " 秒；共享模式（不会静音系统其它声音）；"
        "麦克风用【" + plan.captureDevice + "】。测量期间请保持环境安静，可随时取消。";
    plan.ok = true;
    return plan;
}

// 测量会话的**单实例**状态机：同一时刻只允许一个测量在跑（两个扫频同时播会互相污染录音）。
class RoomMeasureController {
public:
    enum class Phase { Idle, Running, Done, Failed, Cancelled };

    struct Snapshot {
        Phase phase = Phase::Idle;
        std::string layout;
        int channelsTotal = 0;
        int channelsDone = 0;
        std::string currentChannel;
        std::string error;
        std::string warning;
        bool aborted = false;
        std::vector<ChannelMeasurement> channels;
        std::vector<std::string> warnings;
        double subDelaySamples = 0.0;
        double subGainDb = 0.0;
    };

    // 铁律 1：没有 confirmed 就**不碰设备**，只回一份"将会发生什么"。
    // 返回值 false 时 snap.error 给出原因（HTTP 层映射成 428）。
    bool start(const RoomPlan& plan, bool confirmed, std::string& err) {
        if (!confirmed) {
            err = "房间测量会向听音设备播放可听扫频，必须显式确认（confirm=1）。" + plan.warning;
            return false;
        }
        if (!plan.ok) { err = plan.error.empty() ? "测量计划无效" : plan.error; return false; }
        {
            std::lock_guard<std::mutex> lk(m_);
            if (snap_.phase == Phase::Running) { err = "已有测量在进行中"; return false; }
            snap_ = Snapshot{};
            snap_.phase = Phase::Running;
            snap_.layout = plan.layout;
            snap_.channelsTotal = plan.chCount;
            snap_.warning = plan.warning;
        }
        return true;
    }

    // 由测量线程调用：把会话结果写回。
    void finish(const MeasurementSessionResult& r) {
        std::lock_guard<std::mutex> lk(m_);
        snap_.channels = r.channels;
        snap_.warnings = r.warnings;
        snap_.aborted = r.aborted;
        snap_.subDelaySamples = r.subAlign.delaySamples;
        snap_.subGainDb = r.subAlign.gainDb;
        snap_.channelsDone = (int)r.channels.size();
        if (r.aborted) {
            snap_.phase = cancelled_.load() ? Phase::Cancelled : Phase::Failed;
            if (snap_.error.empty()) snap_.error = cancelled_.load() ? "测量已取消" : "测量被中止";
        } else {
            snap_.phase = Phase::Done;
        }
        cancelled_.store(false);
    }

    void fail(const std::string& why) {
        std::lock_guard<std::mutex> lk(m_);
        snap_.phase = cancelled_.load() ? Phase::Cancelled : Phase::Failed;
        snap_.error = why;
        cancelled_.store(false);
    }

    void progress(int done, int total, const std::string& name) {
        std::lock_guard<std::mutex> lk(m_);
        snap_.channelsDone = done > 0 ? done - 1 : 0;
        snap_.channelsTotal = total;
        snap_.currentChannel = name;
    }

    void cancel() { cancelled_.store(true); }
    bool cancelled() const { return cancelled_.load(); }

    Snapshot snapshot() const {
        std::lock_guard<std::mutex> lk(m_);
        return snap_;
    }

private:

    mutable std::mutex m_;
    Snapshot snap_{};
    std::atomic<bool> cancelled_{false};
};

} // namespace rta::dsp
