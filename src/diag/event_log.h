// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// event_log.h — 1.1.1 D1：JSONL 事件落盘、按大小轮转（默认 8 MB × 3）、最近事件读取
//
// ===========================================================================
// 契约
//
//   * 一条事件一行，追加写；每行写完立即 flush —— 判据是"非正常退出后现场还在"。
//     掉电丢最后几行可以接受，丢"整个缓冲里的历史"不可接受。
//   * 轮转：文件超过 max_bytes 就滚动，保留 files 份（base + base.1 … base.(files-1)），
//     默认 8 MB × 3 = 约 24 MB 上限。超出部分丢弃最旧的整份文件（不做行级裁剪，
//     行级裁剪会让巡检脚本读到半条事件）。
//   * seq 由本类在锁内分配（从 1 开始单调递增），调用方自带的 seq 会被覆盖 ——
//     并发下"谁先到"只有写者知道。
//   * 落盘前统一过 redact_event()（redact_policy.h）；顺序必须是"先脱敏后序列化"，
//     反过来要二次转义，容易把转义符吃掉。
//   * 线程安全：单把互斥锁保护 打开/写/轮转；recent() 也在锁内读，避免读到半行。
//     写路径只做一次 fwrite + fflush，锁持有时间在微秒级。
//   * 失败不抛异常，返回 false + last_error()；诊断通道自身绝不能把播放链路带崩。
//
// 已知边界（如实写）：
//   - 没有 fsync，只有 fflush：整机掉电可能丢最后若干行（但对"进程被回收"已足够）。
//   - 不做跨进程互斥：同一目录只允许一个进程写（主控若需要多进程，应各自用不同 dir）。
// ===========================================================================
#pragma once

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <initializer_list>
#include <mutex>
#include <string>
#include <vector>

#include "diag/error_codes.h"
#include "diag/event.h"
#include "diag/redact_policy.h"

#if defined(_WIN32)
#include <process.h>
#define RTA_DIAG_EVENT_GETPID _getpid
#else
#include <unistd.h>
#define RTA_DIAG_EVENT_GETPID getpid
#endif

namespace rta::diag {

struct EventLogConfig {
    std::string dir;                            // 目标目录（不存在会创建）
    std::string file = "rlplayer-events.jsonl"; // 文件名
    uint64_t max_bytes = 8ull * 1024 * 1024;    // 单文件上限：默认 8 MB
    int files = 3;                              // 保留份数：默认 3（当前 + .1 + .2）
    bool enabled = true;
};

class EventLog {
public:
    EventLog() = default;
    explicit EventLog(EventLogConfig c) : cfg_(std::move(c)) {}
    ~EventLog() { close(); }

    EventLog(const EventLog&) = delete;
    EventLog& operator=(const EventLog&) = delete;

    const EventLogConfig& config() const { return cfg_; }
    void set_config(EventLogConfig c) {
        std::lock_guard<std::mutex> lk(mx_);
        cfg_ = std::move(c);
        open_attempted_ = false;
    }

    bool open(std::string* err = nullptr) {
        std::lock_guard<std::mutex> lk(mx_);
        open_attempted_ = true;
        return open_locked(err);
    }

    void close() {
        std::lock_guard<std::mutex> lk(mx_);
        close_locked();
    }

    bool is_open() const {
        std::lock_guard<std::mutex> lk(mx_);
        return fp_ != nullptr;
    }

    // 会话 id：open() 时若为空则自动生成；调用方可在 open 前 set_sid
    void set_sid(std::string sid) {
        std::lock_guard<std::mutex> lk(mx_);
        sid_ = std::move(sid);
    }
    std::string sid() const {
        std::lock_guard<std::mutex> lk(mx_);
        return sid_;
    }

    // 写入一条事件。ts/seq/sid 会被补齐（seq 总是由本类分配）。
    // 返回 false 时 last_error() 给出原因；诊断通道的失败绝不上抛。
    bool write(Event& e, RedactReport* rep = nullptr) {
        std::lock_guard<std::mutex> lk(mx_);
        if (!cfg_.enabled) return false;
        if (!fp_) {
            if (open_attempted_) {
                // 已显式 close() 或之前 open_locked 失败，不得在 write 内部隐式重新 open
                ++st_.dropped;
                last_error_ = "event log not open";
                return false;
            }
            open_attempted_ = true;
            if (!open_locked(nullptr)) {
                ++st_.dropped;
                return false;
            }
        }
        return write_locked(e, rep);
    }

    // 便捷版：不需要 kv 的最小事件
    bool emit(std::string_view evt, Stage stage, const ErrorCode* code = nullptr) {
        Event e;
        e.evt = std::string(evt);
        e.stage = stage_name(stage);
        if (code) e.set_code(code);
        return write(e);
    }

    bool emit(std::string_view evt, Stage stage, const ErrorCode* code,
              std::initializer_list<Kv> kv) {
        Event e;
        e.evt = std::string(evt);
        e.stage = stage_name(stage);
        if (code) e.set_code(code);
        e.kv.assign(kv.begin(), kv.end());
        return write(e);
    }

    // Atomic read under the writer lock; all retained rotations, oldest first.
    // Packaging sees the original retained byte count and can truthfully mark truncation.
    std::string snapshot_text() const {
        std::lock_guard<std::mutex> lk(mx_);
        std::string text;
        for (int i = std::max(1, cfg_.files) - 1; i >= 0; --i) {
            std::ifstream in(i ? path_ + "." + std::to_string(i) : path_, std::ios::binary);
            if (in) text.append(std::istreambuf_iterator<char>(in), {});
        }
        return text;
    }

    // 最近 n 条事件（按时间升序，最后一条最新）。跨轮转读取。
    // skipped_lines 返回扫描到但解析失败的行数（损坏行不能静默消失）。
    std::vector<Event> recent(std::size_t n, std::size_t* skipped_lines = nullptr) const;

    struct Stats {
        uint64_t lines = 0;       // 本实例成功写入的行数
        uint64_t bytes = 0;       // 本实例写入的字节数
        uint64_t rotations = 0;   // 轮转次数
        uint64_t dropped = 0;     // 由于日志不可用而丢弃的事件数
    };
    Stats stats() const {
        std::lock_guard<std::mutex> lk(mx_);
        return st_;
    }
    std::string last_error() const {
        std::lock_guard<std::mutex> lk(mx_);
        return last_error_;
    }
    std::string path() const {
        std::lock_guard<std::mutex> lk(mx_);
        return path_;
    }

    // 会话 id 生成器：pid + 启动时刻 + 单调计数，16 位十六进制。
    // 不做密码学随机（sid 不是凭据，只需在本机文件里唯一、可肉眼区分）。
    static std::string new_sid() {
        static std::mutex m;
        static uint64_t counter = 0;
        std::lock_guard<std::mutex> lk(m);
        const uint64_t t = (uint64_t)now_epoch_ms();
        const uint64_t pid = (uint64_t)RTA_DIAG_EVENT_GETPID();
        const uint64_t n = ++counter;
        char buf[32];
        std::snprintf(buf, sizeof(buf), "%08x%04x%04x", (unsigned)(t & 0xFFFFFFFFu),
                      (unsigned)(pid & 0xFFFFu), (unsigned)(n & 0xFFFFu));
        return std::string(buf);
    }

private:
    bool open_locked(std::string* err) {
        if (!cfg_.enabled) {
            last_error_ = "event log disabled";
            return false;
        }
        if (fp_) return true;
        if (cfg_.dir.empty()) {
            last_error_ = "event log dir empty";
            if (err) *err = last_error_;
            return false;
        }
        std::error_code ec;
        std::filesystem::create_directories(cfg_.dir, ec);
        if (ec) {
            last_error_ = "mkdir failed: " + ec.message();
            if (err) *err = last_error_;
            return false;
        }
        std::string dir = cfg_.dir;
        while (!dir.empty() && (dir.back() == '/' || dir.back() == '\\')) dir.pop_back();
        path_ = dir + "/" + cfg_.file;
        if (sid_.empty()) sid_ = new_sid();
        uint64_t size = 0;
        const auto sz = std::filesystem::file_size(path_, ec);
        if (!ec) size = (uint64_t)sz;
        bytes_ = size;
        if (!reopen_locked()) {
            if (err) *err = last_error_;
            return false;
        }
        // 上次运行留下了超过上限的文件（例如崩溃前猛写），先滚出去，
        // 否则新事件会一直写进一个已经超限的文件。
        if (cfg_.max_bytes > 0 && bytes_ >= cfg_.max_bytes) {
            if (!rotate_locked()) {
                if (err) *err = last_error_;
                return false;
            }
        }
        return true;
    }

    bool reopen_locked() {
        fp_ = std::fopen(path_.c_str(), "ab");
        if (!fp_) {
            last_error_ = "open failed: " + path_;
            return false;
        }
        std::setvbuf(fp_, nullptr, _IOFBF, 1 << 16);
        return true;
    }

    void close_locked() {
        if (fp_) {
            std::fflush(fp_);
            std::fclose(fp_);
            fp_ = nullptr;
        }
    }

    bool rotate_locked() {
        close_locked();
        std::error_code ec;
        const int files = cfg_.files < 1 ? 1 : cfg_.files;
        if (files > 1) {
            std::filesystem::remove(path_ + "." + std::to_string(files - 1), ec);
            for (int i = files - 2; i >= 1; --i) {
                const std::string from = path_ + "." + std::to_string(i);
                const std::string to = path_ + "." + std::to_string(i + 1);
                std::filesystem::rename(from, to, ec);   // 不存在则忽略
                ec.clear();
            }
            std::filesystem::rename(path_, path_ + ".1", ec);
            ec.clear();
        } else {
            std::filesystem::remove(path_, ec);   // 只留 1 份 = 直接清空
        }
        bytes_ = 0;
        ++st_.rotations;
        if (!reopen_locked()) return false;
        return true;
    }

    bool write_locked(Event& e, RedactReport* rep) {
        if (e.ts == 0) e.ts = now_epoch_ms();
        e.seq = ++seq_;
        if (e.sid.empty()) e.sid = sid_;
        redact_event(e, rep);
        std::string line = event_to_json(e);
        line.push_back('\n');
        if (cfg_.max_bytes > 0 && line.size() > cfg_.max_bytes) {
            ++st_.dropped; last_error_ = "event exceeds log size limit"; return false;
        }
        if (cfg_.max_bytes > 0 && bytes_ > 0 && bytes_ + line.size() > cfg_.max_bytes) {
            if (!rotate_locked()) {
                ++st_.dropped;
                return false;
            }
        }
        const size_t w = std::fwrite(line.data(), 1, line.size(), fp_);
        const int flushed = std::fflush(fp_);
        if (w != line.size() || flushed != 0) {
            ++st_.dropped;
            last_error_ = "short write";
            return false;
        }
        bytes_ += line.size();
        ++st_.lines;
        st_.bytes += line.size();
        return true;
    }

    // 读文件尾部最多 maxBytes，返回完整行（丢弃被截断的首行）
    static std::vector<std::string> tail_lines(const std::string& path, uint64_t maxBytes) {
        std::vector<std::string> out;
        std::ifstream f(path, std::ios::binary);
        if (!f) return out;
        f.seekg(0, std::ios::end);
        const std::streamoff len = f.tellg();
        if (len <= 0) return out;
        const std::streamoff take =
            (uint64_t)len > maxBytes ? (std::streamoff)maxBytes : len;
        const std::streamoff start = len - take;
        f.seekg(start, std::ios::beg);
        std::string buf((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        size_t pos = 0;
        if (start > 0) pos = buf.find('\n');   // 丢掉被截断的首行
        if (pos == std::string::npos) return out;
        if (start == 0) pos = 0;
        else ++pos;
        while (pos < buf.size()) {
            const size_t nl = buf.find('\n', pos);
            if (nl == std::string::npos) break;
            if (nl > pos) out.push_back(buf.substr(pos, nl - pos));
            pos = nl + 1;
        }
        return out;
    }

    EventLogConfig cfg_;
    mutable std::mutex mx_;
    std::FILE* fp_ = nullptr;
    std::string path_;
    std::string sid_;
    std::string last_error_;
    uint64_t seq_ = 0;
    uint64_t bytes_ = 0;
    bool open_attempted_ = false;
    Stats st_{};
};

inline std::vector<Event> EventLog::recent(std::size_t n, std::size_t* skipped_lines) const {
    std::vector<Event> newest_first;
    std::size_t skipped = 0;
    if (n > 0) {
        std::lock_guard<std::mutex> lk(mx_);
        const std::size_t files = (std::size_t)(cfg_.files < 1 ? 1 : cfg_.files);
        // 从最新的一份往回读；每份只取尾部 256 KB（事件很小，够几百条）
        for (std::size_t i = 0; i < files; ++i) {
            const std::string p = (i == 0) ? path_ : path_ + "." + std::to_string(i);
            std::error_code ec;
            if (!std::filesystem::exists(p, ec)) continue;
            auto lines = tail_lines(p, 256ull * 1024);
            for (auto it = lines.rbegin(); it != lines.rend(); ++it) {
                Event e;
                std::string err;
                if (!event_from_json(*it, &e, &err)) {
                    ++skipped;
                    continue;
                }
                newest_first.push_back(std::move(e));
                if (newest_first.size() >= n) break;
            }
            if (newest_first.size() >= n) break;
        }
    }
    std::vector<Event> out(newest_first.rbegin(), newest_first.rend());
    if (skipped_lines) *skipped_lines = skipped;
    return out;
}

}  // namespace rta::diag
