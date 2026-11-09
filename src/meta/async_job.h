// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// async_job.h — 1.1.5-beta2 M-12：后台任务去重状态机（纯逻辑）
//
// 设计边界（PLAN §1.5）：rtaweb 只做接线，全部状态判据都在这里，可离线单测。
//   * 不起线程、不联网、不碰文件系统 —— 只维护 key → (generation, state, result) 的表。
//   * 同一个 key 同时只允许一个 running job：tryStart 首次返回 true，其余返回 false。
//   * 不同 key 互不合并。
//   * takeDone 一次性交付：取走结果后把记录从表里移除，之后同一 key 可重新 tryStart。
//   * shutdown 后拒绝新任务（tryStart=false），但已在跑的任务仍能 finish（协作收尾）。
//   * 迟到结果丢弃：finish 必须带 tryStart 返回的 generation；旧 generation 的 finish
//     一律拒绝（场景：job 完成后交付→同 key 重新开工→上一次的迟到结果回来）。
#pragma once

#include <chrono>
#include <cstdint>
#include <map>
#include <mutex>
#include <string>
#include <utility>

namespace rta::meta {

struct JobRecord {
    std::uint64_t generation = 0;
    bool running = false;
    bool done = false;
    std::string result;
    long long started_ms = 0;   // 单调时钟毫秒；给 retryAfterMs / elapsedMs 用
};

class JobRegistry {
public:
    static long long now_ms() {
        return (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
    }
    // 首次开工返回 true 并回传 generation；同 key 已有 running job → false；
    // shutdown 后一律 false。generation 单调递增且全 registry 唯一（跨 key 也不重复），
    // 这样「旧 job 的迟到 finish」不会被误判成当前 job 的结果。
    bool tryStart(const std::string& key, std::uint64_t& generation_out) {
        std::lock_guard<std::mutex> lk(mu_);
        if (shutdown_ || key.empty()) return false;
        std::map<std::string, JobRecord>::iterator it = jobs_.find(key);
        if (it != jobs_.end() && it->second.running) {
            generation_out = it->second.generation;
            return false;
        }
        const std::uint64_t gen = ++next_generation_;
        JobRecord rec;
        rec.generation = gen;
        rec.running = true;
        rec.done = false;
        rec.started_ms = now_ms();
        jobs_[key] = rec;
        generation_out = gen;
        return true;
    }

    bool tryStart(const std::string& key) {
        std::uint64_t gen = 0;
        return tryStart(key, gen);
    }

    // 完成：只有 (key, generation) 同时匹配且该 job 仍 running 才接受结果。
    // 返回 false = 迟到/孤儿结果被丢弃。shutdown 之后仍允许在途任务收尾（协作退出）。
    bool finish(const std::string& key, std::uint64_t generation, const std::string& result) {
        std::lock_guard<std::mutex> lk(mu_);
        std::map<std::string, JobRecord>::iterator it = jobs_.find(key);
        if (it == jobs_.end()) return false;
        JobRecord& rec = it->second;
        if (rec.generation != generation || !rec.running || rec.done) return false;
        rec.running = false;
        rec.done = true;
        rec.result = result;
        return true;
    }

    // 轮询：无 done 结果返回 false；有则把结果交给 out 并**从表里移除**（一次性交付）。
    bool takeDone(const std::string& key, std::string& result_out) {
        std::lock_guard<std::mutex> lk(mu_);
        std::map<std::string, JobRecord>::iterator it = jobs_.find(key);
        if (it == jobs_.end() || !it->second.done) return false;
        result_out = std::move(it->second.result);
        jobs_.erase(it);
        return true;
    }

    // 只读状态查询（诊断/日志用；不改变状态）。
    bool isRunning(const std::string& key) const {
        std::lock_guard<std::mutex> lk(mu_);
        std::map<std::string, JobRecord>::const_iterator it = jobs_.find(key);
        return it != jobs_.end() && it->second.running;
    }
    bool hasDone(const std::string& key) const {
        std::lock_guard<std::mutex> lk(mu_);
        std::map<std::string, JobRecord>::const_iterator it = jobs_.find(key);
        return it != jobs_.end() && it->second.done;
    }
    // 返回该 key 当前 job 已运行毫秒数；不存在返回 0。
    long long elapsedMs(const std::string& key) const {
        std::lock_guard<std::mutex> lk(mu_);
        std::map<std::string, JobRecord>::const_iterator it = jobs_.find(key);
        if (it == jobs_.end() || it->second.started_ms <= 0) return 0;
        const long long d = now_ms() - it->second.started_ms;
        return d > 0 ? d : 0;
    }
    // retryAfterMs：随运行时长增长的轮询退避，钳在 [250,1500]（PLAN §1.5）。
    long long retryAfterMs(const std::string& key) const {
        const long long e = elapsedMs(key);
        long long retry = 250;
        if (e > 8000) retry = 600;
        if (e > 20000) retry = 1000;
        if (retry < 250) retry = 250;
        if (retry > 1500) retry = 1500;
        return retry;
    }
    // 清掉超过 max_age_ms 的陈旧 done 记录（防止异常客户端永不取走导致表无限增长）。
    // 注意：清掉的是「已经完成」的记录，绝不动 running 的在途任务。
    void reapDone(long long max_age_ms) {
        std::lock_guard<std::mutex> lk(mu_);
        const long long now = now_ms();
        for (std::map<std::string, JobRecord>::iterator it = jobs_.begin(); it != jobs_.end();) {
            const JobRecord& r = it->second;
            if (r.done && !r.running && r.started_ms > 0 && now - r.started_ms > max_age_ms)
                it = jobs_.erase(it);
            else
                ++it;
        }
    }
    std::size_t size() const {
        std::lock_guard<std::mutex> lk(mu_);
        return jobs_.size();
    }

    // 停止派发新任务（退出时调用，绝不 force-kill 在途任务）。
    void shutdown() {
        std::lock_guard<std::mutex> lk(mu_);
        shutdown_ = true;
    }
    bool isShutdown() const {
        std::lock_guard<std::mutex> lk(mu_);
        return shutdown_;
    }

    // 只给测试/诊断用：清空表（生产路径不要调用，会丢在途任务）。
    void reset() {
        std::lock_guard<std::mutex> lk(mu_);
        jobs_.clear();
        shutdown_ = false;
        next_generation_ = 0;
    }

private:
    mutable std::mutex mu_;
    std::map<std::string, JobRecord> jobs_;
    bool shutdown_ = false;
    std::uint64_t next_generation_ = 0;
};

} // namespace rta::meta
