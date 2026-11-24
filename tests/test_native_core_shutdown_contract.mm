// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_core_shutdown_contract.mm — RLPCoreClient 退出关闸与重启恢复离线契约测试
//
// 链接真实 RLPCoreClient，mock rlapp::start_embedded / request_shutdown /
// stop_embedded / dispatch，不连真实 core、不碰网络/8899、不开音频设备。
//
// 覆盖 4 条契约：
//   S1 shutdown 后不再新增 dispatch（覆盖 getJSON / postJSON / getData / postData 入口关闸）
//   S2 写队列中已排队但未执行的 postData 在 shutdown 关闸后执行时跳过 dispatch（执行时检查）
//   S3 shutdown 前已排入主队列的 completion 在 shutdown 返回后不再执行（不再更新 UI）
//   S4 同实例 shutdown 后重新 startEmbedded，_shuttingDown 复位并恢复 dispatch 与 completion
#import <Foundation/Foundation.h>

#import "RLPCoreClient.h"
#import "rlapp_core.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#pragma mark - Gate & Mock rlapp::* 后端

namespace {

struct Gate {
    std::mutex mu;
    std::condition_variable cv;
    bool armed = false;
    bool entered = false;
    bool released = false;

    void arm() {
        std::lock_guard<std::mutex> lk(mu);
        armed = true;
        entered = false;
        released = false;
    }
    bool tryConsumeArmed() {
        std::lock_guard<std::mutex> lk(mu);
        if (!armed) return false;
        armed = false;
        entered = true;
        cv.notify_all();
        return true;
    }
    void waitReleased() {
        std::unique_lock<std::mutex> lk(mu);
        cv.wait(lk, [this] { return released; });
    }
    bool waitEntered(int timeoutMs = 2000) {
        std::unique_lock<std::mutex> lk(mu);
        return cv.wait_for(lk, std::chrono::milliseconds(timeoutMs), [this] { return entered; });
    }
    void release() {
        std::lock_guard<std::mutex> lk(mu);
        armed = false;
        released = true;
        cv.notify_all();
    }
};

std::mutex g_mu;
std::condition_variable g_dispatchCv;
std::vector<std::string> g_dispatchedPaths;
std::atomic<int> g_startCalls{0};
std::atomic<int> g_requestShutdownCalls{0};
std::atomic<int> g_stopCalls{0};
std::atomic<int> g_dispatchCalls{0};
std::atomic<int> g_dispatchFinished{0};

Gate g_blockerGate;
std::string g_blockerPath;

void ResetMock() {
    g_blockerGate.release();
    std::lock_guard<std::mutex> lk(g_mu);
    g_dispatchedPaths.clear();
    g_blockerPath.clear();
    g_startCalls = 0;
    g_requestShutdownCalls = 0;
    g_stopCalls = 0;
    g_dispatchCalls = 0;
    g_dispatchFinished = 0;
}

bool HasDispatchedPath(const std::string& path) {
    std::lock_guard<std::mutex> lk(g_mu);
    for (const auto& p : g_dispatchedPaths) {
        if (p == path) return true;
    }
    return false;
}

bool WaitForDispatchFinished(int target, int timeoutMs = 2000) {
    std::unique_lock<std::mutex> lk(g_mu);
    return g_dispatchCv.wait_for(lk, std::chrono::milliseconds(timeoutMs), [target] {
        return g_dispatchFinished.load() >= target;
    });
}

} // namespace

namespace rlapp {

bool start_embedded() {
    ++g_startCalls;
    return true;
}

void request_shutdown() {
    ++g_requestShutdownCalls;
}

void stop_embedded() {
    ++g_stopCalls;
}

bool exit_requested() { return false; }
std::string diag_json(std::size_t) { return "{}"; }
int max_concurrent_dispatches() { return 0; }
long long dispatch_count() { return g_dispatchCalls.load(); }
void reset_dispatch_probe() {}
int cli_main(int, char**) { return 0; }

std::string dispatch(const rta::net::HttpRequest& req, std::string& contentType) {
    contentType = "application/json";
    ++g_dispatchCalls;
    std::string gatePath;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        g_dispatchedPaths.push_back(req.path);
        gatePath = g_blockerPath;
    }
    if (!gatePath.empty() && req.path == gatePath) {
        if (g_blockerGate.tryConsumeArmed()) {
            g_blockerGate.waitReleased();
        }
    }
    {
        std::lock_guard<std::mutex> lk(g_mu);
        ++g_dispatchFinished;
        g_dispatchCv.notify_all();
    }
    return "{\"ok\":true}";
}

} // namespace rlapp

#pragma mark - 辅助工具

static int g_pass = 0;
static int g_fail = 0;

static void ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) {
        std::printf("  [PASS] %s\n", what);
        ++g_pass;
    } else {
        std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: "");
        ++g_fail;
    }
}

static void Pump(NSTimeInterval seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

static BOOL WaitUntil(NSTimeInterval timeout, BOOL (^pred)(void)) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([until timeIntervalSinceNow] > 0) {
        if (pred()) return YES;
        Pump(0.01);
    }
    return pred();
}

int main() {
    @autoreleasepool {
        std::printf("== RLPCoreClient 退出关闸与重启恢复契约测试（离线 mock）==\n");

        // ====================================================================
        // S1: shutdown 后不新增 dispatch（getJSON / postJSON / getData / postData）
        // ====================================================================
        {
            ResetMock();
            RLPCoreClient *c1 = [[RLPCoreClient alloc] init];
            BOOL started = [c1 startEmbedded];
            [c1 shutdown];

            ck(started && !c1.started && g_startCalls.load() == 1 &&
               g_requestShutdownCalls.load() == 1 && g_stopCalls.load() == 1,
               "S1 前置：startEmbedded 与 shutdown 生命周期计数正确",
               [NSString stringWithFormat:@"started=%d afterShutdown=%d start=%d req=%d stop=%d",
                started, c1.started, g_startCalls.load(),
                g_requestShutdownCalls.load(), g_stopCalls.load()]);

            auto jsonAfterComp = std::make_shared<std::atomic<int>>(0);
            auto getDataAfterComp = std::make_shared<std::atomic<int>>(0);
            auto postDataAfterComp = std::make_shared<std::atomic<int>>(0);

            [c1 getJSON:@"/api/test/s1-getjson" completion:^(NSDictionary *j) {
                (void)j; ++(*jsonAfterComp);
            }];
            [c1 postJSON:@"/api/test/s1-postjson" body:@"a=1" completion:^(NSDictionary *j) {
                (void)j; ++(*jsonAfterComp);
            }];
            [c1 getData:@"/api/test/s1-getdata" completion:^(NSData *d) {
                (void)d; ++(*getDataAfterComp);
            }];
            [c1 postData:@"/api/test/s1-postdata"
                    body:[@"img" dataUsingEncoding:NSUTF8StringEncoding]
             contentType:@"application/octet-stream"
              completion:^(NSDictionary *j) {
                (void)j; ++(*postDataAfterComp);
            }];

            Pump(0.15);

            ck(!HasDispatchedPath("/api/test/s1-getjson") &&
               !HasDispatchedPath("/api/test/s1-postjson") &&
               jsonAfterComp->load() == 0,
               "S1a shutdown 后 getJSON/postJSON 不新增 dispatch 且不触发 completion",
               [NSString stringWithFormat:@"dispatchCalls=%d jsonComp=%d",
                g_dispatchCalls.load(), jsonAfterComp->load()]);

            ck(!HasDispatchedPath("/api/test/s1-getdata") && getDataAfterComp->load() == 0,
               "S1b shutdown 后 getData 不新增 dispatch 且不触发 completion",
               [NSString stringWithFormat:@"dispatched=%d comp=%d",
                HasDispatchedPath("/api/test/s1-getdata"), getDataAfterComp->load()]);

            ck(!HasDispatchedPath("/api/test/s1-postdata") && postDataAfterComp->load() == 0,
               "S1c shutdown 后 postData 不新增 dispatch 且不触发 completion",
               [NSString stringWithFormat:@"dispatched=%d comp=%d",
                HasDispatchedPath("/api/test/s1-postdata"), postDataAfterComp->load()]);
        }

        // ====================================================================
        // S2: 写队列中已排队的 postData 在 shutdown 关闸后执行时跳过 dispatch
        // ====================================================================
        {
            ResetMock();
            RLPCoreClient *c2 = [[RLPCoreClient alloc] init];
            [c2 startEmbedded];

            {
                std::lock_guard<std::mutex> lk(g_mu);
                g_blockerPath = "/api/test/s2-blocker";
            }
            g_blockerGate.arm();

            [c2 postJSON:@"/api/test/s2-blocker" body:nil completion:nil];
            BOOL blockerEntered = g_blockerGate.waitEntered(2000);

            // 在 blocker 占住串行 _writeQueue 时排队 postData（此时 _shuttingDown 尚为 false）
            auto queuedPostDataComp = std::make_shared<std::atomic<int>>(0);
            [c2 postData:@"/api/test/s2-queued-postdata"
                    body:[@"raw" dataUsingEncoding:NSUTF8StringEncoding]
             contentType:@"application/octet-stream"
              completion:^(NSDictionary *j) {
                (void)j; ++(*queuedPostDataComp);
            }];

            // 后台发起 shutdown：先置 _shuttingDown=true，再等 _ioQueue 与 _writeQueue 排空
            std::atomic<bool> shutdownStarted{false};
            std::atomic<bool> shutdownFinished{false};
            std::thread shutdownThread([&] {
                shutdownStarted.store(true);
                [c2 shutdown];
                shutdownFinished.store(true);
            });
            while (!shutdownStarted.load()) {
                std::this_thread::yield();
            }
            // 给 shutdown 线程进入 _shuttingDown=true + _writeQueue 等待窗口的时间
            std::this_thread::sleep_for(std::chrono::milliseconds(30));

            // 放行 blocker，让排在其后的 postData 在 _writeQueue 上开始执行
            g_blockerGate.release();
            shutdownThread.join();
            Pump(0.1);

            ck(blockerEntered && shutdownFinished.load(),
               "S2 前置：blocker 进入 gate 且 shutdown 正常完成",
               [NSString stringWithFormat:@"blockerEntered=%d shutdownFinished=%d",
                blockerEntered, shutdownFinished.load()]);

            ck(!HasDispatchedPath("/api/test/s2-queued-postdata") && queuedPostDataComp->load() == 0,
               "S2 已排队 postData 在 shutdown 关闸后执行时跳过 dispatch 且不触发 completion",
               [NSString stringWithFormat:@"dispatched=%d comp=%d",
                HasDispatchedPath("/api/test/s2-queued-postdata"), queuedPostDataComp->load()]);
        }

        // ====================================================================
        // S3: shutdown 前已排入主队列的 completion 在 shutdown 后不再执行（不更新 UI）
        // ====================================================================
        {
            ResetMock();
            RLPCoreClient *c3 = [[RLPCoreClient alloc] init];
            [c3 startEmbedded];

            auto uiUpdateCount = std::make_shared<std::atomic<int>>(0);
            [c3 getJSON:@"/api/test/s3-getjson" completion:^(NSDictionary *j) {
                (void)j; ++(*uiUpdateCount);
            }];
            [c3 postJSON:@"/api/test/s3-postjson" body:nil completion:^(NSDictionary *j) {
                (void)j; ++(*uiUpdateCount);
            }];
            [c3 getData:@"/api/test/s3-getdata" completion:^(NSData *d) {
                (void)d; ++(*uiUpdateCount);
            }];
            [c3 postData:@"/api/test/s3-postdata"
                    body:[@"ui" dataUsingEncoding:NSUTF8StringEncoding]
             contentType:@"application/octet-stream"
              completion:^(NSDictionary *j) {
                (void)j; ++(*uiUpdateCount);
            }];

            // 在不 pump 主队列 runloop 的前提下，等待 4 个后台 dispatch 完成
            BOOL allDispatched = WaitForDispatchFinished(4, 2000);

            // 主线程调用 shutdown：barrier/sync 返回时，4 个 completion 已确定排在 main queue 上
            [c3 shutdown];
            int beforePump = uiUpdateCount->load();

            // 现在 pump 主队列，验证已排入的 completion 不再执行 UI 更新
            Pump(0.12);
            int afterPump = uiUpdateCount->load();

            ck(allDispatched && beforePump == 0,
               "S3 前置：4 个后台 dispatch 均已完成且 shutdown 前尚未泵主队列",
               [NSString stringWithFormat:@"allDispatched=%d beforePump=%d",
                allDispatched, beforePump]);

            ck(afterPump == 0,
               "S3 shutdown 前排入主队列的 completion 在 shutdown 后不再更新 UI",
               [NSString stringWithFormat:@"uiUpdateCount=%d (expected 0)", afterPump]);
        }

        // ====================================================================
        // S4: 同实例 shutdown 后重新 startEmbedded 恢复 dispatch 与 completion
        // ====================================================================
        {
            ResetMock();
            RLPCoreClient *shared = [RLPCoreClient shared];
            BOOL start1 = [shared startEmbedded];
            auto preDone = std::make_shared<std::atomic<int>>(0);
            [shared getJSON:@"/api/test/s4-before-shutdown" completion:^(NSDictionary *j) {
                if ([j[@"ok"] boolValue]) ++(*preDone);
            }];
            BOOL preOk = WaitUntil(2.0, ^BOOL { return preDone->load() == 1; });

            [shared shutdown];
            BOOL downOk = !shared.started;

            // 同实例重新 startEmbedded
            BOOL start2 = [shared startEmbedded];
            auto getDone = std::make_shared<std::atomic<int>>(0);
            auto postDone = std::make_shared<std::atomic<int>>(0);
            auto getDataDone = std::make_shared<std::atomic<int>>(0);
            auto postDataDone = std::make_shared<std::atomic<int>>(0);

            [shared getJSON:@"/api/test/s4-after-restart-get" completion:^(NSDictionary *j) {
                if ([j[@"ok"] boolValue]) ++(*getDone);
            }];
            [shared postJSON:@"/api/test/s4-after-restart-post" body:@"k=v" completion:^(NSDictionary *j) {
                if ([j[@"ok"] boolValue]) ++(*postDone);
            }];
            [shared getData:@"/api/test/s4-after-restart-getdata" completion:^(NSData *d) {
                if (d.length > 0) ++(*getDataDone);
            }];
            [shared postData:@"/api/test/s4-after-restart-postdata"
                        body:[@"r" dataUsingEncoding:NSUTF8StringEncoding]
                 contentType:@"application/octet-stream"
                  completion:^(NSDictionary *j) {
                if ([j[@"ok"] boolValue]) ++(*postDataDone);
            }];

            BOOL restartDone = WaitUntil(1.5, ^BOOL {
                return getDone->load() == 1 && postDone->load() == 1 &&
                       getDataDone->load() == 1 && postDataDone->load() == 1;
            });

            ck(start1 && preOk && downOk && start2 && shared.started && g_startCalls.load() == 2,
               "S4 前置：同实例首次运行、shutdown、重新 startEmbedded 成功",
               [NSString stringWithFormat:@"start1=%d preOk=%d downOk=%d start2=%d started=%d startCalls=%d",
                start1, preOk, downOk, start2, shared.started, g_startCalls.load()]);

            ck(HasDispatchedPath("/api/test/s4-after-restart-get") && getDone->load() == 1 &&
               HasDispatchedPath("/api/test/s4-after-restart-post") && postDone->load() == 1,
               "S4a 同实例重新 startEmbedded 后 getJSON/postJSON 恢复 dispatch 与 completion",
               [NSString stringWithFormat:@"getDisp=%d getDone=%d postDisp=%d postDone=%d",
                HasDispatchedPath("/api/test/s4-after-restart-get"), getDone->load(),
                HasDispatchedPath("/api/test/s4-after-restart-post"), postDone->load()]);

            ck(HasDispatchedPath("/api/test/s4-after-restart-getdata") && getDataDone->load() == 1 &&
               HasDispatchedPath("/api/test/s4-after-restart-postdata") && postDataDone->load() == 1 &&
               restartDone,
               "S4b 同实例重新 startEmbedded 后 getData/postData 恢复 dispatch 与 completion",
               [NSString stringWithFormat:@"getDataDisp=%d getDataDone=%d postDataDisp=%d postDataDone=%d",
                HasDispatchedPath("/api/test/s4-after-restart-getdata"), getDataDone->load(),
                HasDispatchedPath("/api/test/s4-after-restart-postdata"), postDataDone->load()]);

            [shared shutdown];
        }

        // Shutdown followed by immediate restart must not revive queued UI callbacks.
        {
            ResetMock();
            RLPCoreClient *c5 = [[RLPCoreClient alloc] init];
            [c5 startEmbedded];
            auto oldUpdates = std::make_shared<std::atomic<int>>(0);
            [c5 getJSON:@"/api/test/s5-old" completion:^(NSDictionary *j) { (void)j; ++(*oldUpdates); }];
            BOOL dispatched = WaitForDispatchFinished(1);
            [c5 shutdown];
            BOOL restarted = [c5 startEmbedded];
            Pump(0.1);
            ck(dispatched && restarted && oldUpdates->load() == 0,
               "S5 restart does not revive a queued callback from the previous lifecycle", @"");
            [c5 shutdown];
        }

        // ====================================================================
        // S6: request_shutdown() 必须先于快队列排空触发（防止主线程干等超时任务）
        // ====================================================================
        {
            ResetMock();
            RLPCoreClient *c6 = [[RLPCoreClient alloc] init];
            [c6 startEmbedded];
            {
                std::lock_guard<std::mutex> lk(g_mu);
                g_blockerPath = "/api/test/s6-io-blocker";
            }
            g_blockerGate.arm();
            [c6 getJSON:@"/api/test/s6-io-blocker" completion:nil];
            BOOL entered = g_blockerGate.waitEntered(2000);

            std::atomic<bool> shutdownReturned{false};
            std::thread shutdownThread([&] {
                [c6 shutdown];
                shutdownReturned.store(true);
            });

            // 若旧顺序（先 barrier_sync 再 request_shutdown），这里永远等不到 g_requestShutdownCalls > 0（必死锁）。
            BOOL reqObservedBeforeRelease = NO;
            for (int i = 0; i < 200; ++i) {
                if (g_requestShutdownCalls.load() > 0) {
                    reqObservedBeforeRelease = YES;
                    break;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
            BOOL stillWaitingDrain = !shutdownReturned.load();
            g_blockerGate.release();
            shutdownThread.join();

            ck(entered && reqObservedBeforeRelease && stillWaitingDrain && !c6.started,
               "S6 request_shutdown() triggers before _ioQueue finishes draining",
               [NSString stringWithFormat:@"entered=%d req=%d stillWaiting=%d started=%d",
                entered, reqObservedBeforeRelease, stillWaitingDrain, c6.started]);
        }

        // ====================================================================
        // S7: shutdownWithTimeoutMs: 卡住时有界返回 NO，释放后可完成收尾返回 YES
        // ====================================================================
        {
            ResetMock();
            RLPCoreClient *c7 = [[RLPCoreClient alloc] init];
            [c7 startEmbedded];
            {
                std::lock_guard<std::mutex> lk(g_mu);
                g_blockerPath = "/api/test/s7-timeout-blocker";
            }
            g_blockerGate.arm();
            [c7 getJSON:@"/api/test/s7-timeout-blocker" completion:nil];
            BOOL entered = g_blockerGate.waitEntered(2000);

            const auto t0 = std::chrono::steady_clock::now();
            BOOL drainedTimedOut = [c7 shutdownWithTimeoutMs:60];
            const long long elapsedMs = (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
                                            std::chrono::steady_clock::now() - t0).count();

            ck(entered && !drainedTimedOut && elapsedMs < 400 && g_stopCalls.load() == 0 && c7.started,
               "S7 shutdownWithTimeoutMs: returns NO promptly when worker is blocked",
               [NSString stringWithFormat:@"entered=%d drained=%d elapsed=%lldms stopCalls=%d started=%d",
                entered, drainedTimedOut, elapsedMs, g_stopCalls.load(), c7.started]);

            g_blockerGate.release();
            BOOL drainedAfterRelease = [c7 shutdownWithTimeoutMs:1500];
            ck(drainedAfterRelease && g_stopCalls.load() == 1 && !c7.started,
               "S7b shutdownWithTimeoutMs: completes cleanly after worker unblocks",
               [NSString stringWithFormat:@"drained=%d stopCalls=%d started=%d",
                drainedAfterRelease, g_stopCalls.load(), c7.started]);
        }

        std::printf("\n%s（%d passed, %d failed）\n",
                    g_fail == 0 ? "RLPCoreClient 退出关闸与重启恢复契约 全部通过"
                                : "RLPCoreClient 退出关闸与重启恢复契约 有失败",
                    g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
