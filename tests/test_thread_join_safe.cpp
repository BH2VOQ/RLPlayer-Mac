// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_thread_join_safe.cpp — `/api/cast/stop` 打 500 的根因判据（离线、无网络、无声）
//
// 判据来源：用户全局待办「停止投放的回送api出错了」。
// 真机上表现为日志反复出现 `DISPATCH 异常已拦截（请求 /api/cast/stop）`。
//
// 为什么这样判（铁律 3）：
//   只断言「调了 stop() 没崩」证明不了东西 —— 没会话时 workerThread_ 根本 non-joinable，
//   压根不会走到 join。真正会抛的是下面三种**结构性**场景，它们都能离线构造：
//     ① 自己 join 自己   → std::system_error("Resource deadlock avoided")
//     ② 同一线程 join 两次 → std::system_error("Invalid argument")
//     ③ 并发 join        → 与 ② 同类（未定义/抛异常）
//   所以本判据直接对这三条做红→绿：
//     红：用裸 t.join() 复现，断言**确实抛异常**（证明这个坑真实存在，判据不是空转）；
//     绿：用 join_thread_safely()，断言**一次都不抛**，且线程确实收尾/被 detach。
//
// 铁律 1：不打开任何音频设备、不发任何网络请求、不播放（本文件只有线程）。

#include "net/thread_join_safe.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

static int g_fail = 0;
static void ck(bool cond, const std::string& what, const std::string& detail = "") {
    if (cond) {
        std::printf("  [PASS] %s\n", what.c_str());
    } else {
        std::printf("  [FAIL] %s  %s\n", what.c_str(), detail.c_str());
        ++g_fail;
    }
}

static long long ms_since(std::chrono::steady_clock::time_point t0) {
    return (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - t0).count();
}

int main() {
    std::printf("=== test_thread_join_safe（/api/cast/stop 500 的根因判据）===\n");

    // ---------------------------------------------------------------------
    // 红基线：证明「同一个 thread 被 join 两次」真的会抛
    //   —— 这就是用户连点「停止投放」时后端把它打成 500 的那条路径。
    //   注：本机实测「join 自己」不是抛异常而是**死锁**（sample 停在 _pthread_join →
    //   __ulock_wait），所以这里不复现自 join，改用重复 join 来证明坑真实存在。
    // ---------------------------------------------------------------------
    {
        std::thread t([] {});
        t.join();
        bool threw = false;
        std::string what;
        try {
            t.join();                       // 第二次 join：非 joinable
        } catch (const std::exception& e) {
            threw = true;
            what = e.what();
        }
        ck(threw, "红基线：裸 join 同一线程两次，第二次会抛异常（坑真实存在）",
           what.empty() ? "未抛出（则该判据说服力存疑）" : what);
    }

    // ---------------------------------------------------------------------
    // 绿①：在 worker 自己的线程里调用安全 join —— 必须**立刻返回**（走 detach）。
    //      若实现改成去 join 自己，本机会死锁，这条会挂住并由 ctest 的 TIMEOUT 判红。
    //
    //      ⚠️ 写法注意（本判据第一稿就踩了，记下来）：内部 detach 之后**不要**再从外面
    //      join 同一个 std::thread 对象 —— 一边 detach、一边 join 同一句柄是未定义行为，
    //      实测会卡死在 pthread_join 的 ulock 上（进程只剩 1 个线程却永不返回）。
    //      正确做法：用原子标志等它跑完，不碰那个已被 detach 的句柄。
    // ---------------------------------------------------------------------
    {
        std::thread worker;
        std::mutex mx;
        std::atomic<long long> elapsed{-1};
        std::atomic<bool> done{false};
        worker = std::thread([&] {
            std::this_thread::sleep_for(std::chrono::milliseconds(40));
            const auto t0 = std::chrono::steady_clock::now();
            rta::net::join_thread_safely(worker, mx);   // 自己调自己 → 必须立刻返回
            elapsed.store(ms_since(t0));
            done.store(true);
        });
        const auto wait0 = std::chrono::steady_clock::now();
        while (!done.load() && ms_since(wait0) < 2000) {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
        const long long e = elapsed.load();
        ck(done.load(), "绿①：自己线程里调用安全 join 后线程正常跑完（没被卡住）");
        ck(e >= 0 && e < 50, "绿①：该调用立刻返回（不死锁）", std::to_string(e) + "ms");
    }

    // ---------------------------------------------------------------------
    // 绿 ②：重复 join 同一线程不抛
    // ---------------------------------------------------------------------
    {
        std::mutex mx;
        std::atomic<int> ran{0};
        std::thread t([&] { ran.fetch_add(1); });
        bool threw = false;
        try {
            rta::net::join_thread_safely(t, mx);
            rta::net::join_thread_safely(t, mx);   // 第二次：已 non-joinable
            rta::net::join_thread_safely(t, mx);   // 第三次
        } catch (...) {
            threw = true;
        }
        ck(!threw, "绿②：同一个线程对象连续安全 join 三次不抛");
        ck(ran.load() == 1, "绿②：被 join 的线程确实执行到了（不是“跳过了就假装成功”）",
           std::to_string(ran.load()));
    }

    // ---------------------------------------------------------------------
    // 绿 ③：并发安全 join 同一线程不抛、且只收尾一次
    //      （真实场景：用户连点「停止投放」，或多个请求同时进来）
    // ---------------------------------------------------------------------
    {
        std::mutex mx;
        std::atomic<int> ran{0};
        std::thread t([&] {
            std::this_thread::sleep_for(std::chrono::milliseconds(120));
            ran.fetch_add(1);
        });
        std::atomic<int> threwCount{0};
        std::vector<std::thread> callers;
        for (int i = 0; i < 8; ++i) {
            callers.emplace_back([&] {
                try {
                    rta::net::join_thread_safely(t, mx);
                } catch (...) {
                    threwCount.fetch_add(1);
                }
            });
        }
        for (auto& c : callers) c.join();
        ck(threwCount.load() == 0, "绿③：8 个线程并发安全 join 同一个线程，0 次抛出",
           std::to_string(threwCount.load()) + " 次抛出");
        ck(ran.load() == 1, "绿③：worker 只执行一次（没有被重复 join 破坏）",
           std::to_string(ran.load()));
        ck(!t.joinable(), "绿③：调用结束后原 std::thread 已是 non-joinable（不会在析构时 terminate）");
    }

    // ---------------------------------------------------------------------
    // 绿 ④：正常 join 仍然要真的等线程跑完（别把“不抛”做成“不等”）
    //      真实场景：stop() 之后要确保 worker 不再访问核心状态，否则就是 UAF。
    // ---------------------------------------------------------------------
    {
        std::mutex mx;
        std::atomic<bool> finished{false};
        std::thread t([&] {
            std::this_thread::sleep_for(std::chrono::milliseconds(150));
            finished.store(true);
        });
        const auto t0 = std::chrono::steady_clock::now();
        rta::net::join_thread_safely(t, mx);
        const long long e = ms_since(t0);
        ck(finished.load(), "绿④：join_thread_safely 是真的等线程结束（返回时工作已完成）");
        ck(e >= 120, "绿④：确实等了约 150ms，不是立即返回", std::to_string(e) + "ms");
        ck(!t.joinable(), "绿④：返回后原线程对象已置空");
    }

    std::printf("\n=== 汇总：%s ===\n", g_fail == 0 ? "全部通过" : "存在失败");
    return g_fail == 0 ? 0 : 1;
}
