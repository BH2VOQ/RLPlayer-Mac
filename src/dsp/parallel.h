// SPDX-FileCopyrightText: 2026 rainlain <https://github.com/okhuoyanyan>
// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// parallel.h — 极简并行 for（有界常驻线程池）
//
// 用途：把"每个声道/分区互相独立"的重活（多相重采样、SDM 调制、卷积、EQ）分到多核。
// 为什么不直接用 std::async / 每次调用现建线程：每次创建线程开销 50~100 µs，
// 对流式分块占比太高；这里按需扩容并常驻最多 7 个 helper（连同调用线程共 8 核）。
#pragma once
#include <exception>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <functional>
#include <vector>
#include <atomic>
#include <cstddef>
#include <algorithm>
#include <system_error>
#include <utility>

namespace rta::dsp {

class ParallelFor {
public:
    static ParallelFor& instance() { static ParallelFor p; return p; }

    using ThreadFactory = std::function<std::thread(std::function<void()>)>;
    explicit ParallelFor(ThreadFactory factory = {})
        : threadFactory_(std::move(factory)) {
        helpers_.reserve(7);
    }
    ParallelFor(const ParallelFor&) = delete;
    ParallelFor& operator=(const ParallelFor&) = delete;
    ~ParallelFor() {
        std::unique_lock<std::mutex> serial(runMutex_);
        {
            std::lock_guard<std::mutex> lock(stateMutex_);
            stopping_ = true;
        }
        workCv_.notify_all();
        for (auto& t : helpers_) {
            if (t.joinable()) t.join();
        }
    }

    // 把 [0, n) 分配到 min(n, 硬件线程数, 8) 个常驻线程（含当前调用线程）。
    // 嵌套调用或外部并发调用都会安全串行/顺序回退，绝不丢任务或死锁。
    void run(size_t n, const std::function<void(size_t)>& fn) {
        if (n == 0) return;
        if (executing_) { sequential(n, fn); return; }
        std::unique_lock<std::mutex> serial(runMutex_);
        if (n == 1) { ExecutionScope scope; sequential(n, fn); return; }

        const unsigned hw = std::thread::hardware_concurrency();
        const size_t workers = std::min<size_t>(n, hw ? std::min<unsigned>(hw, 8u) : 4u);

        while (helpers_.size() + 1 < workers) {
            try {
                const size_t epoch = generation_;
                if (threadFactory_) {
                    helpers_.emplace_back(threadFactory_([this, epoch] { workerLoop(epoch); }));
                } else {
                    helpers_.emplace_back([this, epoch] { workerLoop(epoch); });
                }
            } catch (const std::system_error&) {
                break;
            }
        }
        if (helpers_.empty()) { ExecutionScope scope; sequential(n, fn); return; }

        {
            std::lock_guard<std::mutex> lock(stateMutex_);
            fn_ = &fn;
            n_ = n;
            next_.store(1, std::memory_order_relaxed);
            error_ = nullptr;
            remaining_ = helpers_.size();
            ++generation_;
        }
        workCv_.notify_all();
        {
            ExecutionScope scope;
            invoke(0);
            consume();
        }
        std::exception_ptr error;
        {
            std::unique_lock<std::mutex> lock(stateMutex_);
            doneCv_.wait(lock, [this] { return remaining_ == 0; });
            fn_ = nullptr;
            error = error_;
            error_ = nullptr;
        }
        if (error) std::rethrow_exception(error);
    }

    std::vector<std::thread::id> helper_thread_ids() const {
        std::lock_guard<std::mutex> lock(runMutex_);
        std::vector<std::thread::id> ids;
        ids.reserve(helpers_.size());
        for (const auto& t : helpers_) ids.push_back(t.get_id());
        return ids;
    }

    size_t helper_count() const {
        std::lock_guard<std::mutex> lock(runMutex_);
        return helpers_.size();
    }

private:
    inline static thread_local bool executing_ = false;
    struct ExecutionScope {
        bool prior = executing_;
        ExecutionScope() { executing_ = true; }
        ~ExecutionScope() { executing_ = prior; }
    };

    static void sequential(size_t n, const std::function<void(size_t)>& fn) {
        std::exception_ptr error;
        for (size_t i = 0; i < n; ++i) {
            try {
                fn(i);
            } catch (...) {
                if (!error) error = std::current_exception();
            }
        }
        if (error) std::rethrow_exception(error);
    }

    void invoke(size_t i) noexcept {
        try {
            (*fn_)(i);
        } catch (...) {
            std::lock_guard<std::mutex> lock(stateMutex_);
            if (!error_) error_ = std::current_exception();
        }
    }

    void consume() noexcept {
        for (;;) {
            const size_t i = next_.fetch_add(1, std::memory_order_relaxed);
            if (i >= n_) break;
            invoke(i);
        }
    }

    void workerLoop(size_t seen) {
        std::unique_lock<std::mutex> lock(stateMutex_);
        for (;;) {
            workCv_.wait(lock, [&] { return stopping_ || generation_ != seen; });
            if (stopping_) return;
            seen = generation_;
            lock.unlock();
            {
                ExecutionScope scope;
                consume();
            }
            lock.lock();
            if (--remaining_ == 0) doneCv_.notify_one();
        }
    }

    mutable std::mutex runMutex_;
    ThreadFactory threadFactory_;
    std::mutex stateMutex_;
    std::condition_variable workCv_, doneCv_;
    std::vector<std::thread> helpers_;
    std::atomic<size_t> next_{0};
    size_t n_ = 0, generation_ = 0, remaining_ = 0;
    bool stopping_ = false;
    const std::function<void(size_t)>* fn_ = nullptr;
    std::exception_ptr error_;
};

inline size_t hardware_threads() {
    const unsigned hw = std::thread::hardware_concurrency();
    return hw ? (size_t)hw : 1u;
}

} // namespace rta::dsp
