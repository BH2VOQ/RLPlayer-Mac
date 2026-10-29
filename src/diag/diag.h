// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// diag.h — 1.1.1 D1/D6 的接入面（主控只需要记住这 6 个符号）
//
// ===========================================================================
// 最小接入（主控/CLI 侧）
//
//     rta::diag::DiagConfig cfg;
//     cfg.dir = <日志目录>;              // 例如 exe 同目录，或 ~/Library/Logs/RLPlayer
//     cfg.app_version = RLPLAYER_VERSION;
//     auto st = rta::diag::diag_start(cfg);
//     // st.ok / st.sid / st.previous（上次是否正常退出，见 run_marker.h）
//
//     {
//         rta::diag::ScopedRid rid(new_request_id());     // 一次用户动作一个 rid
//         rta::diag::diag_emit("play.start", rta::diag::Stage::Io, nullptr,
//                              {{"rate", "44100", rta::diag::KvKind::Num}});
//     }
//     rta::diag::diag_emit("play.open.failed", rta::diag::Stage::Io,
//                          rta::diag::find_code("io.open_failed"),
//                          {{"retry", "0", rta::diag::KvKind::Num}});
//
//     rta::diag::diag_stop("user_quit");                  // 写 session.end + clean 标记
//
// ===========================================================================
// 线程安全
//
//   * diag_start / diag_stop 应在主线程调用（内部会关掉旧日志再重开）；
//   * diag_emit / diag_beat 可在任意线程调用（EventLog 内部一把锁）；
//   * ScopedRid 是 **thread_local**：多个线程各自的 rid 互不覆盖，
//     不需要锁，也不会因为一个请求结束就把别的线程的 rid 清空；
//   * 任何失败都返回 false / 写 last_error()，绝不抛异常 —— 诊断通道不能把
//     播放链路带崩（这条是 D1 的硬要求）。
//
// 与既有日志的关系（D1「保留既有播放日志前缀」）
//
//   * 本模块写的是**新**文件 rlplayer-events.jsonl，不动 rlplayer-playback.log；
//   * 想把事件镜像进既有播放日志时，用 legacy_prefix_line() —— 它产生与
//     tools/rtaweb.cpp 的 play_log() 完全一致的前缀
//     `YYYY-MM-DD HH:MM:SS.mmm `，后面接 `EVT stage=… code=… k=v …`，
//     这样既有 grep / 用户习惯都不变。
// ===========================================================================
#pragma once

#include <cstdio>
#include <ctime>
#include <filesystem>
#include <initializer_list>
#include <mutex>
#include <string>
#include <system_error>

#if defined(_WIN32)
#include <process.h>
#else
#include <cerrno>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>
#endif

#include "diag/error_codes.h"
#include "diag/event.h"
#include "diag/event_log.h"
#include "diag/redact_policy.h"
#include "diag/run_marker.h"

namespace rta::diag {

struct DiagConfig {
    std::string dir;                            // 事件与运行标记的目录（不存在会创建）
    uint64_t max_bytes = 8ull * 1024 * 1024;    // 与 EventLogConfig 默认一致：8 MB
    int files = 3;                              // 默认 3 份
    std::string app_version;                    // 写进运行标记与 session.start
    bool enabled = true;
};

struct DiagStartResult {
    bool ok = false;
    std::string sid;
    PreviousRun previous;
    std::string error;
    bool secondary = false;   // true = 本进程是副实例（另一个进程已持有目录锁）
    std::string dir;          // 本实例事件日志的**实际**目录：主实例 = cfg.dir；副实例 = cfg.dir/instances/<sid>
    std::string code;         // 失败码；成功必须是空串（不是 "ok"）
};

// ---- 进程级单例（首次调用时构造；函数内 static 的初始化是线程安全的） ----
inline EventLog& event_log() {
    static EventLog log;
    return log;
}

inline RunMarker& run_marker() {
    static RunMarker marker;
    return marker;
}

// ---- 请求上下文：thread_local，可嵌套 ----
inline thread_local std::string tl_rid;

inline std::string current_rid() { return tl_rid; }

struct ScopedRid {
    explicit ScopedRid(std::string rid) : prev_(std::move(tl_rid)) { tl_rid = std::move(rid); }
    ~ScopedRid() { tl_rid = std::move(prev_); }
    ScopedRid(const ScopedRid&) = delete;
    ScopedRid& operator=(const ScopedRid&) = delete;

private:
    std::string prev_;
};

namespace detail {
inline std::mutex& lifecycle_mx() {
    static std::mutex m;
    return m;
}
inline std::atomic<bool>& active_flag() {
    static std::atomic<bool> b{false};
    return b;
}
inline int& primary_lock_fd() {
    static int fd = -1;
    return fd;
}
inline int64_t& primary_lock_pid() {
    static int64_t pid = 0;
    return pid;
}
inline std::string& primary_lock_dir() {
    static std::string dir;
    return dir;
}
}  // namespace detail

// 开始一次诊断会话。可重复调用（先关旧日志再开新会话），便于"重启诊断"与单测。
inline DiagStartResult diag_start(const DiagConfig& cfg) {
    DiagStartResult r;
    std::lock_guard<std::mutex> lk(detail::lifecycle_mx());
    EventLog& el = event_log();
    el.close();
    if (!cfg.enabled) {
        run_marker().set_config({cfg.dir, "rlplayer-run.json", false, 2000});
        detail::active_flag() = false;
        r.ok = true;
        r.dir = cfg.dir;
        r.secondary = false;
        r.code = "";
        return r;
    }

    r.sid = EventLog::new_sid();

    std::string norm_dir = cfg.dir;
    while (!norm_dir.empty() && (norm_dir.back() == '/' || norm_dir.back() == '\\')) {
        norm_dir.pop_back();
    }

#if defined(_WIN32)
    const int64_t cur_pid = (int64_t)_getpid();
#else
    const int64_t cur_pid = (int64_t)::getpid();
#endif

    // 子进程检测：若当前 pid 与记录的持有者 pid 不一致，说明本进程是 fork 出来的子进程
    if (detail::primary_lock_pid() != 0 && detail::primary_lock_pid() != cur_pid) {
        detail::primary_lock_fd() = -1;
        detail::primary_lock_pid() = 0;
        detail::primary_lock_dir().clear();
    }

    bool is_secondary = false;
    bool lock_unwritable = false;

    if (detail::primary_lock_fd() >= 0 && detail::primary_lock_pid() == cur_pid) {
        if (detail::primary_lock_dir() == norm_dir) {
            // 同一进程在同一目录重复调用 diag_start：复用现有目录锁，视为主实例（重入）
            is_secondary = false;
        } else {
            // 同一进程切换了目录：释放旧目录锁，稍后尝试加锁新目录
#if !defined(_WIN32)
            ::flock(detail::primary_lock_fd(), LOCK_UN);
            ::close(detail::primary_lock_fd());
#endif
            detail::primary_lock_fd() = -1;
            detail::primary_lock_pid() = 0;
            detail::primary_lock_dir().clear();
        }
    }

#if !defined(_WIN32)
    if (detail::primary_lock_fd() < 0 && !norm_dir.empty()) {
        std::error_code ec;
        std::filesystem::create_directories(norm_dir, ec);
        const std::string lock_path = norm_dir + "/diag-primary.lock";
        int fd = ::open(lock_path.c_str(), O_RDWR | O_CREAT, 0644);
        if (fd < 0) {
            // 目录锁文件无法创建
            lock_unwritable = true;
            is_secondary = false;
        } else {
            int fr = ::flock(fd, LOCK_EX | LOCK_NB);
            if (fr == 0) {
                // 成功获得目录锁，为主实例
                detail::primary_lock_fd() = fd;
                detail::primary_lock_pid() = cur_pid;
                detail::primary_lock_dir() = norm_dir;
                is_secondary = false;
            } else {
                if (errno == EWOULDBLOCK || errno == EAGAIN) {
                    // 拿不到锁：另一个进程已持有目录锁 → 判定为副实例
                    is_secondary = true;
                } else {
                    // 无法加锁（其他系统错误）
                    lock_unwritable = true;
                    is_secondary = false;
                }
                ::close(fd);
            }
        }
    }
#endif

    r.secondary = is_secondary;
    if (is_secondary) {
        r.dir = norm_dir + "/instances/" + r.sid;
        std::error_code ec_inst;
        std::filesystem::create_directories(r.dir, ec_inst);
    } else {
        r.dir = cfg.dir;
    }

    EventLogConfig lc;
    lc.dir = r.dir;
    lc.max_bytes = cfg.max_bytes;
    lc.files = cfg.files;
    lc.enabled = true;
    el.set_config(lc);
    el.set_sid(r.sid);

    std::string logErr;
    const bool logOk = el.open(&logErr);
    if (!logOk) r.error = logErr.empty() ? el.last_error() : logErr;

    RunMarker::Config mc;
    mc.dir = cfg.dir;
    mc.enabled = true;
    run_marker().set_config(mc);
    std::string markerErr;
    const uint64_t fail_before = run_marker().stats().write_failures;
    r.previous = run_marker().begin(r.sid, cfg.app_version, &markerErr);
    const bool markerOk = (run_marker().stats().write_failures == fail_before);
    if (!markerOk && r.error.empty()) {
        r.error = markerErr.empty() ? run_marker().last_error() : markerErr;
        if (r.error.empty()) r.error = "run marker write failed";
    }

    // 会话起点事件：把"上一轮怎么结束的"写进现场，诊断包拿到就能回答 Q9
    if (logOk) {
        Event e;
        e.evt = "session.start";
        e.stage = stage_name(Stage::Init);
        e.str("version", cfg.app_version);
        e.str("prev", r.previous.reason_class());
        e.str("prev_sid", r.previous.sid);
        if (!r.previous.clean && r.previous.found) e.str("prev_evidence", r.previous.evidence);
        el.write(e);
    }

    if (!logOk) {
        r.ok = false;
        r.code = "diag.event_log_unwritable";
    } else if (!markerOk) {
        r.ok = false;
        r.code = "diag.run_marker_unwritable";
    } else if (lock_unwritable) {
        r.ok = true;
        r.code = "diag.dir_lock_unwritable";
    } else {
        r.ok = true;
        r.code = "";
    }

    detail::active_flag() = r.ok;
    return r;
}

// 正常收尾：先写 session.end（保证事件不丢），再写 clean 标记。
inline void diag_stop(const std::string& reason = "quit") {
    std::lock_guard<std::mutex> lk(detail::lifecycle_mx());
    EventLog& el = event_log();
    if (detail::active_flag()) {
        Event e;
        e.evt = "session.end";
        e.stage = stage_name(Stage::Init);
        e.str("reason", reason);
        el.write(e);
    }
    run_marker().end_clean(reason, nullptr);
    el.close();
    detail::active_flag() = false;

#if !defined(_WIN32)
    if (detail::primary_lock_fd() >= 0) {
        ::flock(detail::primary_lock_fd(), LOCK_UN);
        ::close(detail::primary_lock_fd());
        detail::primary_lock_fd() = -1;
    }
#endif
    detail::primary_lock_pid() = 0;
    detail::primary_lock_dir().clear();
}

inline bool diag_active() { return detail::active_flag(); }

// 上报一条事件（任意线程）。返回 false 表示没落盘（日志不可用），调用方据此决定
// 是否降级到既有播放日志 —— 但**不要**因为诊断失败中断播放。
inline bool diag_emit(const Event& src) {
    try {
        if (!detail::active_flag()) return false;
        Event e = src;
        if (e.rid.empty()) e.rid = tl_rid;
        return event_log().write(e);
    } catch (...) { return false; }
}

inline bool diag_emit(std::string_view evt, Stage stage, const ErrorCode* code = nullptr,
                      std::initializer_list<Kv> kv = {}) {
    Event e;
    e.evt = std::string(evt);
    e.stage = stage_name(stage);
    if (code) e.set_code(code);
    e.kv.assign(kv.begin(), kv.end());
    return diag_emit(e);
}

// 心跳：由主循环按秒调用即可（内部按 heartbeat_ms 节流）
inline void diag_beat(int64_t now_ms = 0) { run_marker().beat(now_ms); }

// 把事件转成"既有播放日志前缀"格式：`YYYY-MM-DD HH:MM:SS.mmm ` + EVT stage=… code=… k=v
// 只给需要镜像到 rlplayer-playback.log 的调用方用；写文件仍由既有 play_log() 负责。
inline std::string legacy_prefix_line(const Event& e, int64_t ts_ms = 0) {
    const int64_t ms = ts_ms ? ts_ms : (e.ts ? e.ts : now_epoch_ms());
    const std::time_t sec = (std::time_t)(ms / 1000);
    std::tm lt{};
#if defined(_WIN32)
    localtime_s(&lt, &sec);
#else
    localtime_r(&sec, &lt);
#endif
    char ts[64];
    std::snprintf(ts, sizeof(ts), "%04d-%02d-%02d %02d:%02d:%02d.%03d ", lt.tm_year + 1900,
                  lt.tm_mon + 1, lt.tm_mday, lt.tm_hour, lt.tm_min, lt.tm_sec,
                  (int)(ms % 1000));
    std::string o = ts;
    o += e.evt;
    if (!e.stage.empty()) {
        o += " stage=";
        o += e.stage;
    }
    if (!e.code.empty()) {
        o += " code=";
        o += e.code;
    }
    if (!e.rid.empty()) {
        o += " rid=";
        o += e.rid;
    }
    for (const auto& p : e.kv) {
        o += " ";
        o += p.k;
        o += "=";
        o += p.v;
    }
    return o;
}

}  // namespace rta::diag
