// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// run_marker.h — 1.1.1 D6：运行标记与 clean/unclean 判定
//
// ===========================================================================
// 核心规矩：**「没有正常退出」不等于「崩溃」**
//
//   上一次运行留下的标记只证明一件事：那个进程没有走到正常退出路径。可能是崩溃、
//   可能是被系统回收、可能是掉电、可能是用户从活动监视器里结束、也可能是被监管
//   进程用信号停掉。这些在证据上完全不同，混为一谈会让用户拿着"崩溃"去查一个
//   根本不存在的 bug（本项目已有多次"判据定义错误带偏排查"的前例，见铁律 3）。
//
//   所以本模块分三级：
//     clean            —— 标记是 clean，且退出原因可读
//     unclean_unknown  —— 标记停在 running / 损坏 / 自报 unclean，**没有**崩溃证据
//     unclean_crashed  —— 只有拿到崩溃转储（.ips/.crash）才允许这么说
//     unclean_killed   —— 只有监管进程记下信号（SIGTERM/SIGKILL/…）才允许这么说
//
//   * pid_alive 只是**事实**（kill(pid,0) 探测结果），不是崩溃证据；pid 会被系统复用，
//     所以它甚至不算"进程还活着"的强证据，只作为上下文记录。
//   * 面向用户的 zh_summary() 在 Unknown 分支里**不出现**「崩溃」「crash」字样；
//     tests/test_diag_run_marker.cpp 的 C/D 段逐字断言这一点。
//
// 写入是原子替换（写 .tmp → rename），避免半份标记被下一个进程读成"损坏"。
// 心跳有节流（默认 2 秒），长跑不会写爆磁盘，也不会让标记文件的 mtime 一直变。
// ===========================================================================
#pragma once

#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>

#include "diag/event.h"
#include "diag/redact_policy.h"

#if defined(_WIN32)
#include <process.h>
#define RTA_DIAG_GETPID _getpid
#else
#include <fcntl.h>
#include <signal.h>
#include <sys/file.h>
#include <unistd.h>
#define RTA_DIAG_GETPID getpid
#endif

namespace rta::diag {

enum class UncleanKind : int {
    Unknown = 0,   // 只知道"没正常退出"
    Crashed,       // 有崩溃转储证据
    Killed,        // 有监管进程记录的信号证据
};

// 外部证据（由主控/监管进程提供，本模块不自己猜）
struct CrashEvidence {
    bool crash_dump = false;
    std::string crash_dump_path;   // 会在进入结论前脱敏
    bool supervisor_signal = false;
    int signal_number = 0;
    std::string signal_name;       // 例如 "SIGTERM"
};

struct PreviousRun {
    bool found = false;
    bool clean = false;
    bool marker_corrupt = false;
    std::string sid;
    int64_t pid = 0;
    int64_t started_ms = 0;
    int64_t last_beat_ms = 0;
    std::string app_version;
    std::string exit_reason;
    UncleanKind kind = UncleanKind::Unknown;
    bool pid_alive = false;
    std::string evidence;   // 证据串（已脱敏）；无证据时为空

    // 机器可读结论：none / clean / unclean_unknown / unclean_crashed / unclean_killed
    std::string reason_class() const {
        if (!found) return "none";
        if (clean) return "clean";
        switch (kind) {
            case UncleanKind::Crashed: return "unclean_crashed";
            case UncleanKind::Killed: return "unclean_killed";
            case UncleanKind::Unknown: break;
        }
        return "unclean_unknown";
    }

    // 给人看的一句话。★ Unknown 分支不得出现"崩溃"（文件头规矩）
    std::string zh_summary() const {
        if (!found) return "上次运行没有留下运行标记（首次运行，或标记已被清理）";
        if (clean) {
            return "上次运行正常退出（clean）" +
                   (exit_reason.empty() ? std::string() : "，原因：" + exit_reason);
        }
        if (marker_corrupt) {
            return "上次运行没有正常退出（unclean）；运行标记损坏，现有证据不足以判断原因";
        }
        switch (kind) {
            case UncleanKind::Crashed:
                return "上次运行没有正常退出（unclean），但存在崩溃转储证据（" + evidence +
                       "），可判定为崩溃";
            case UncleanKind::Killed:
                return "上次运行没有正常退出（unclean），且监管进程记录到终止信号（" + evidence +
                       "），属于被终止，不是崩溃";
            case UncleanKind::Unknown: break;
        }
        // ★ 这里刻意不出现「崩溃」二字：没有证据时，把"未正常退出"和"崩溃"并列
        //   本身就会把用户引导到错误的排查方向（1.1.1 D6 的硬要求）。
        return "上次运行没有正常退出（unclean）；现有证据不足以判断原因"
               "（可能是被系统结束、掉电或用户强制退出）";
    }
};

namespace detail {

struct MarkerFields {
    std::string state;
    std::string sid;
    std::string app_version;
    std::string exit_reason;
    int64_t pid = 0;
    int64_t started_ms = 0;
    int64_t last_beat_ms = 0;
};

// 标记文件是扁平对象（无嵌套），复用 event.h 的 JSON 游标即可
inline bool parse_marker(std::string_view text, MarkerFields* out) {
    std::string err;
    Cursor c{text, 0, &err};
    c.ws();
    if (!c.eat('{')) return false;
    c.ws();
    if (c.eat('}')) return false;
    for (;;) {
        std::string k;
        if (!c.parse_string(&k)) return false;
        c.ws();
        if (c.i >= c.s.size() || c.s[c.i] != ':') return false;
        ++c.i;
        c.ws();
        if (k == "pid" || k == "started_ms" || k == "last_beat_ms") {
            std::string n;
            if (!c.parse_number_text(&n)) return false;
            const long long v = std::atoll(n.c_str());
            if (k == "pid") out->pid = (int64_t)v;
            else if (k == "started_ms") out->started_ms = (int64_t)v;
            else out->last_beat_ms = (int64_t)v;
        } else if (k == "state" || k == "sid" || k == "app_version" || k == "exit_reason") {
            std::string v;
            if (!c.parse_string(&v)) return false;
            if (k == "state") out->state = v;
            else if (k == "sid") out->sid = v;
            else if (k == "app_version") out->app_version = v;
            else out->exit_reason = v;
        } else {
            if (!c.skip_value()) return false;
        }
        c.ws();
        if (c.i < c.s.size() && c.s[c.i] == ',') { ++c.i; continue; }
        if (c.i < c.s.size() && c.s[c.i] == '}') { ++c.i; break; }
        return false;
    }
    c.ws();
    return c.i == c.s.size() && !out->state.empty();
}

inline std::string json_str(const std::string& s) {
    std::string o;
    append_json_string(o, s);
    return o;
}

}  // namespace detail

// 从标记文本 + 外部证据得出上一轮结论。纯函数，便于单测与"同一输入换证据"对照。
inline PreviousRun classify_marker(std::string_view marker_json, const CrashEvidence& ev = {},
                                   bool pid_alive = false) {
    PreviousRun r;
    if (marker_json.empty()) return r;   // 没找到标记 = None，不是 unclean
    r.found = true;
    r.pid_alive = pid_alive;

    detail::MarkerFields f;
    if (!detail::parse_marker(marker_json, &f)) {
        r.marker_corrupt = true;
        r.kind = UncleanKind::Unknown;
        r.evidence = "marker_corrupt";
        return r;
    }
    r.sid = f.sid;
    r.pid = f.pid;
    r.started_ms = f.started_ms;
    r.last_beat_ms = f.last_beat_ms;
    r.app_version = f.app_version;
    r.exit_reason = f.exit_reason;

    if (f.state == "clean") {
        r.clean = true;
        return r;
    }
    if (f.state != "running" && f.state != "unclean") {
        r.marker_corrupt = true;
        r.kind = UncleanKind::Unknown;
        r.evidence = "marker_corrupt";
        return r;
    }

    // 非 clean：只有**举证**才细分。顺序：崩溃转储 > 监管信号 > 未知
    if (ev.crash_dump) {
        r.kind = UncleanKind::Crashed;
        r.evidence = "crash_dump:" + redact_text(ev.crash_dump_path);
    } else if (ev.supervisor_signal) {
        r.kind = UncleanKind::Killed;
        const std::string name = ev.signal_name.empty() ? "signal" : ev.signal_name;
        r.evidence = "signal:" + name + "(" + std::to_string(ev.signal_number) + ")";
    } else {
        r.kind = UncleanKind::Unknown;
        // pid 活着只是上下文，写进 evidence 也不改结论（见文件头）
        r.evidence = pid_alive ? "pid_alive" : "";
    }
    return r;
}

// 运行标记：每次会话开始写 state=running，正常退出改写 state=clean。
// 写失败不抛异常（诊断通道不能把主流程带崩），通过 stats()/last_error() 暴露。
class RunMarker {
public:
    struct Config {
        std::string dir;
        std::string file = "rlplayer-run.json";
        bool enabled = true;
        int64_t heartbeat_ms = 2000;   // 心跳节流
    };

    RunMarker() = default;
    ~RunMarker() {
        release_lock();
    }
    explicit RunMarker(Config c) : cfg_(std::move(c)) {}

    RunMarker(const RunMarker&) = delete;
    RunMarker& operator=(const RunMarker&) = delete;

    // 供进程级单例在 diag_start 时重新配置（未 begin 前调用）
    void set_config(Config c) {
        std::lock_guard<std::mutex> lk(mx_);
        cfg_ = std::move(c);
    }
    const Config& config() const { return cfg_; }

    struct Stats {
        uint64_t writes = 0;          // 标记文件写入次数
        uint64_t beats_written = 0;   // 心跳真写次数
        uint64_t beats_skipped = 0;   // 被节流掉的心跳
        uint64_t write_failures = 0;
    };

    // 开始会话：读上一份标记 → 分类 → 写本会话的 running 标记。
    PreviousRun begin(const std::string& sid, const std::string& app_version = "",
                      std::string* err = nullptr) {
        std::lock_guard<std::mutex> lk(mx_);
        if (!cfg_.enabled) return PreviousRun{};
        release_lock();
        std::error_code ec;
        std::filesystem::create_directories(cfg_.dir, ec);
        path_ = dir_join(cfg_.dir, cfg_.file);

        PreviousRun prev;
        bool found_prev = false;

        // 1. 先检查活跃实例标记文件 (run-active-*.json)
        std::vector<std::pair<int64_t, std::string>> active_candidates;
        for (const auto& entry : std::filesystem::directory_iterator(cfg_.dir, ec)) {
            const std::string fn = entry.path().filename().string();
            if (fn.rfind("run-active-", 0) == 0 && fn.size() > 16 && fn.substr(fn.size() - 5) == ".json") {
                const std::string candidate_sid = fn.substr(11, fn.size() - 16);
                if (candidate_sid == sid) continue;
                const std::string lk_path = dir_join(cfg_.dir, "run-active-" + candidate_sid + ".lock");
                if (is_file_locked(lk_path)) {
                    continue; // 其它活跃进程仍然持有锁，该实例仍在正常运行
                }
                const std::string c_raw = read_all(entry.path().string());
                if (!c_raw.empty()) {
                    detail::MarkerFields probe;
                    if (detail::parse_marker(c_raw, &probe)) {
                        if (probe.pid > 0 && probe.pid != (int64_t)RTA_DIAG_GETPID() && pid_is_alive(probe.pid)) {
                            continue; // 进程仍在运行
                        }
                        if (probe.state == "running") {
                            active_candidates.push_back({probe.last_beat_ms > 0 ? probe.last_beat_ms : probe.started_ms, c_raw});
                        }
                    }
                }
            }
        }
        if (!active_candidates.empty()) {
            std::sort(active_candidates.begin(), active_candidates.end(),
                      [](const auto& a, const auto& b) { return a.first > b.first; });
            const std::string& newest_unclean = active_candidates.front().second;
            prev = classify_marker(newest_unclean, CrashEvidence{}, false);
            found_prev = true;
        }

        // 2. 如果没有死亡遗留的 active 标记，则回退读取默认单实例文件 path_
        if (!found_prev) {
            const std::string raw = read_all(path_);
            if (!raw.empty()) {
                detail::MarkerFields probe;
                bool is_probe_valid = detail::parse_marker(raw, &probe);
                bool alive = false;
                if (is_probe_valid && probe.pid > 0 && probe.pid != (int64_t)RTA_DIAG_GETPID()) {
                    alive = pid_is_alive(probe.pid);
                }
                const std::string lk_path = dir_join(cfg_.dir, "run-active-" + probe.sid + ".lock");
                bool sid_active_lock = (!probe.sid.empty() && is_file_locked(lk_path));
                if (probe.state == "running" && (alive || sid_active_lock)) {
                    // 第一个实例还在跑（alive 或持有文件锁），本实例是第二实例并发启动
                    // 必须视为首次无已结束的上一轮 (none)，不得把第一实例的 running 当成"上次崩溃未正常退出"
                    prev = PreviousRun{};
                } else {
                    const PreviousRun first = classify_marker(raw, CrashEvidence{}, false);
                    prev = alive ? classify_marker(raw, CrashEvidence{}, true) : first;
                }
                found_prev = true;
            }
        }
        previous_ = prev;

        sid_ = sid;
        app_version_ = app_version;
        pid_ = (int64_t)RTA_DIAG_GETPID();
        started_ms_ = now_epoch_ms();
        last_beat_ = started_ms_;
        clean_written_ = false;
        active_ = true;

        acquire_lock();
        write_active_marker("running", "");

        if (!write_locked("running", "", err)) {
            ++st_.write_failures;
        }
        return prev;
    }

    // 心跳：间隔不足 heartbeat_ms 直接跳过（计数可见，便于证明节流真的生效）
    void beat(int64_t now_ms = 0) {
        std::lock_guard<std::mutex> lk(mx_);
        if (!cfg_.enabled || !active_ || clean_written_) return;
        const int64_t now = now_ms ? now_ms : now_epoch_ms();
        if (now - last_beat_ < cfg_.heartbeat_ms) {
            ++st_.beats_skipped;
            return;
        }
        last_beat_ = now;
        write_active_marker("running", "");
        if (write_locked("running", "", nullptr)) ++st_.beats_written;
        else ++st_.write_failures;
    }

    // 正常退出：state=clean + 原因。调用后 beat() 不再复活 running 状态。
    bool end_clean(const std::string& reason = "quit", std::string* err = nullptr) {
        std::lock_guard<std::mutex> lk(mx_);
        if (!cfg_.enabled || !active_) return false;
        last_beat_ = now_epoch_ms();
        write_active_marker("clean", reason);
        append_history("clean", reason);
        const bool ok = write_locked("clean", reason, err);
        if (ok) ++st_.beats_written;   // 退出也算一次时间戳前进
        else ++st_.write_failures;
        clean_written_ = true;
        active_ = false;
        release_lock();
        return ok;
    }

    // 自报 unclean（主控捕获到致命错误、主动放弃会话时用）。
    // 注意：这是"我知道自己没正常收尾"，**不是**崩溃断言；下一轮仍按 unclean_unknown 处理。
    bool abandon(const std::string& reason, std::string* err = nullptr) {
        std::lock_guard<std::mutex> lk(mx_);
        if (!cfg_.enabled || !active_) return false;
        write_active_marker("unclean", reason);
        append_history("unclean", reason);
        const bool ok = write_locked("unclean", reason, err);
        if (!ok) ++st_.write_failures;
        active_ = false;
        clean_written_ = false;
        release_lock();
        return ok;
    }

    const PreviousRun& previous() const { return previous_; }
    std::string sid() const {
        std::lock_guard<std::mutex> lk(mx_);
        return sid_;
    }
    int64_t last_beat_ms() const {
        std::lock_guard<std::mutex> lk(mx_);
        return last_beat_;
    }
    Stats stats() const {
        std::lock_guard<std::mutex> lk(mx_);
        return st_;
    }
    std::string path() const {
        std::lock_guard<std::mutex> lk(mx_);
        return path_;
    }
    std::string last_error() const {
        std::lock_guard<std::mutex> lk(mx_);
        return last_error_;
    }

private:
    static std::string dir_join(const std::string& dir, const std::string& leaf) {
        std::string d = dir;
        while (!d.empty() && (d.back() == '/' || d.back() == '\\')) d.pop_back();
        if (d.empty()) return leaf;
        return d + "/" + leaf;
    }

    static bool pid_is_alive(int64_t pid) {
        if (pid <= 0) return false;
#if defined(_WIN32)
        return false;   // 本机为 macOS 单平台；Windows 分支不宣称能力
#else
        return ::kill((pid_t)pid, 0) == 0;   // 只读探测，不发信号
#endif
    }

    static std::string read_all(const std::string& p) {
        std::ifstream f(p, std::ios::binary);
        if (!f) return std::string();
        return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    }

    void acquire_lock() {
#if !defined(_WIN32)
        if (cfg_.dir.empty() || sid_.empty()) return;
        lock_path_ = dir_join(cfg_.dir, "run-active-" + sid_ + ".lock");
        lock_fd_ = ::open(lock_path_.c_str(), O_RDWR | O_CREAT, 0644);
        if (lock_fd_ >= 0) {
            ::flock(lock_fd_, LOCK_EX | LOCK_NB);
        }
#endif
    }

    void release_lock() {
#if !defined(_WIN32)
        if (lock_fd_ >= 0) {
            ::flock(lock_fd_, LOCK_UN);
            ::close(lock_fd_);
            lock_fd_ = -1;
        }
        if (!lock_path_.empty()) {
            std::error_code ec;
            std::filesystem::remove(lock_path_, ec);
            lock_path_.clear();
        }
#endif
    }

    static bool is_file_locked(const std::string& lk_path) {
#if !defined(_WIN32)
        if (lk_path.empty()) return false;
        std::error_code ec;
        if (!std::filesystem::exists(lk_path, ec)) return false;
        int fd = ::open(lk_path.c_str(), O_RDWR, 0644);
        if (fd < 0) return false;
        int r = ::flock(fd, LOCK_EX | LOCK_NB);
        if (r == 0) {
            ::flock(fd, LOCK_UN);
            ::close(fd);
            return false;
        }
        ::close(fd);
        return true;
#else
        return false;
#endif
    }

    void write_active_marker(const std::string& state, const std::string& reason) {
        if (cfg_.dir.empty() || sid_.empty()) return;
        const std::string active_path = dir_join(cfg_.dir, "run-active-" + sid_ + ".json");
        std::string body;
        body.reserve(256);
        body += "{\"v\":1,\"state\":";
        body += detail::json_str(state);
        body += ",\"sid\":";
        body += detail::json_str(sid_);
        body += ",\"pid\":";
        body += std::to_string((long long)pid_);
        body += ",\"started_ms\":";
        body += std::to_string((long long)started_ms_);
        body += ",\"last_beat_ms\":";
        body += std::to_string((long long)last_beat_);
        body += ",\"app_version\":";
        body += detail::json_str(app_version_);
        body += ",\"exit_reason\":";
        body += detail::json_str(reason);
        body += "}\n";

        static std::atomic<uint64_t> s_active_seq{0};
        const std::string tmp = active_path + ".tmp." + std::to_string((long long)pid_) + "." +
                                std::to_string(++s_active_seq);
        {
            std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
            if (out) {
                out.write(body.data(), (std::streamsize)body.size());
            }
        }
        std::error_code ec;
        std::filesystem::rename(tmp, active_path, ec);
        if (ec) {
            std::filesystem::remove(tmp, ec);
        }
    }

    void append_history(const std::string& state, const std::string& reason) {
        if (cfg_.dir.empty() || sid_.empty()) return;
        const std::string hist_path = dir_join(cfg_.dir, "run-history.log");
        std::string body;
        body.reserve(256);
        body += "{\"v\":1,\"state\":";
        body += detail::json_str(state);
        body += ",\"sid\":";
        body += detail::json_str(sid_);
        body += ",\"pid\":";
        body += std::to_string((long long)pid_);
        body += ",\"started_ms\":";
        body += std::to_string((long long)started_ms_);
        body += ",\"last_beat_ms\":";
        body += std::to_string((long long)last_beat_);
        body += ",\"app_version\":";
        body += detail::json_str(app_version_);
        body += ",\"exit_reason\":";
        body += detail::json_str(reason);
        body += "}\n";

        std::ofstream out(hist_path, std::ios::app | std::ios::binary);
        if (out) {
            out.write(body.data(), (std::streamsize)body.size());
        }
    }

    bool write_locked(const std::string& state, const std::string& reason, std::string* err) {
        if (cfg_.dir.empty()) {
            last_error_ = "run marker dir empty";
            if (err) *err = last_error_;
            return false;
        }

        // 所有权检查：若原主标记文件当前属于另一个仍然存活/运行中的实例，本实例不得覆盖
        const std::string raw = read_all(path_);
        if (!raw.empty()) {
            detail::MarkerFields existing;
            if (detail::parse_marker(raw, &existing)) {
                if (!existing.sid.empty() && existing.sid != sid_ && existing.state == "running") {
                    const std::string ex_lock = dir_join(cfg_.dir, "run-active-" + existing.sid + ".lock");
                    const bool ex_alive = (existing.pid > 0 && pid_is_alive(existing.pid));
                    const bool ex_locked = (existing.pid != pid_ && is_file_locked(ex_lock));
                    if (ex_alive || ex_locked) {
                        // 属于其它活跃运行实例，拒绝覆写共享的主标记文件
                        return true;
                    }
                }
            }
        }

        std::string body;
        body.reserve(256);
        body += "{\"v\":1,\"state\":";
        body += detail::json_str(state);
        body += ",\"sid\":";
        body += detail::json_str(sid_);
        body += ",\"pid\":";
        body += std::to_string((long long)pid_);
        body += ",\"started_ms\":";
        body += std::to_string((long long)started_ms_);
        body += ",\"last_beat_ms\":";
        body += std::to_string((long long)last_beat_);
        body += ",\"app_version\":";
        body += detail::json_str(app_version_);
        body += ",\"exit_reason\":";
        body += detail::json_str(reason);
        body += "}\n";

        // 原子替换：先写带 pid + nonce 的 .tmp 再 rename，避免跨实例冲突或半份标记
        static std::atomic<uint64_t> s_seq{0};
        const std::string tmp = path_ + ".tmp." + std::to_string((long long)pid_) + "." +
                                std::to_string(++s_seq);
        {
            std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
            if (!out) {
                last_error_ = "run marker open failed: " + tmp;
                if (err) *err = last_error_;
                std::error_code ec;
                std::filesystem::remove(tmp, ec);
                return false;
            }
            out.write(body.data(), (std::streamsize)body.size());
            out.flush();
            if (!out) {
                last_error_ = "run marker write failed";
                if (err) *err = last_error_;
                out.close();
                std::error_code ec;
                std::filesystem::remove(tmp, ec);
                return false;
            }
        }
        std::error_code ec;
        std::filesystem::rename(tmp, path_, ec);
        if (ec) {
            last_error_ = "run marker rename failed: " + ec.message();
            if (err) *err = last_error_;
            std::filesystem::remove(tmp, ec);
            return false;
        }
        ++st_.writes;
        return true;
    }

    Config cfg_;
    mutable std::mutex mx_;
    std::string path_;
    std::string sid_;
    std::string app_version_;
    int64_t pid_ = 0;
    int64_t started_ms_ = 0;
    int64_t last_beat_ = 0;
    bool active_ = false;
    bool clean_written_ = false;
    PreviousRun previous_{};
    Stats st_{};
    std::string last_error_;
    int lock_fd_ = -1;
    std::string lock_path_;
};

}  // namespace rta::diag
