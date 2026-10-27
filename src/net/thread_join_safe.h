// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// thread_join_safe.h — 「把 worker 线程安全取出来再 join」的可单测实现
//
// 为什么单独抽出来（2026-10-28 真机事故）：
//   投放的 `/api/cast/stop` 反复在日志里打「DISPATCH 异常已拦截（请求 /api/cast/stop）」，
//   前端表现为「停止投放失败」。根因是 stop() 里直接 workerThread_.join()，下列三种情况
//   都会抛 std::system_error 并把整个 HTTP 请求打成 500：
//     ① 在 worker 线程内部调用（自己 join 自己 → "Resource deadlock avoided"）；
//     ② 两个请求并发调用（同一个 std::thread 被 join 两次）；
//     ③ thread 已失效/已被取走。
//   「我改好了」这句话必须有可复跑的判据，而这三条都**不需要真的投放/播放**就能测，
//   所以把这段逻辑抽成纯工具 + 离线单测（tests/test_thread_join_safe.cpp）。
//
// 约定：调用方自己负责“先置停止标志、再调本函数”，本函数只负责线程对象的收尾。
#pragma once

#include <mutex>
#include <thread>
#include <utility>

namespace rta::net {

// 在锁内把 t 「取出来」（移走所有权），再在锁外 join。
//   * 若是当前线程自己 → detach（自 join 必然抛 "Resource deadlock avoided"）；
//   * 取出后立即把 t 置空，因此第二个并发调用看到的是 non-joinable，不会重复 join；
//   * join 本身再包一层 catch：线程收尾失败也绝不把调用方（HTTP 请求）打成 500。
inline void join_thread_safely(std::thread& t, std::mutex& mx) {
    std::thread toJoin;
    {
        std::lock_guard<std::mutex> lk(mx);
        if (!t.joinable()) return;
        if (t.get_id() == std::this_thread::get_id()) {
            t.detach();
            return;
        }
        toJoin = std::move(t);          // t 变 non-joinable ⟹ 并发调用不会重复 join
    }
    if (toJoin.joinable()) {
        try {
            toJoin.join();
        } catch (...) {
            // 故意吞掉：join 失败不是调用方的错，更不能让上层把请求判成失败
        }
    }
}

} // namespace rta::net
