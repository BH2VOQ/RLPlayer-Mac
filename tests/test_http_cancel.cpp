// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// tests/test_http_cancel.cpp — HTTP 层可取消阻塞请求验证
//
// 验证契约：
//   1. platform::HttpRequest 增加 const std::atomic<bool>* cancel = nullptr;
//   2. 预取消 (pre-canceled)：若 cancel 已为 true，http_request 立刻返回，不发起网络请求，
//      返回非空明确取消错误、status = 0、ok = false。
//   3. 传输中取消 (in-flight / downloading)：在下载过程中置位 cancel，libcurl 进度/写回调检测并中断，
//      返回非空明确取消错误、status = 0、ok = false，不把取消当成功。
//   4. 正常请求：未取消时正常获取响应、status = 200、ok = true。
//   5. 作用域隔离与嵌套：net 层 HttpCancellationScope 仅在当前线程生效，支持嵌套 restore，
//      且不影响其他并发工作线程。
//
// 纪律：
//   * 真实 loopback HTTP server，记录实际延迟与真正 worker join 耗时。
//   * 不得靠极短 timeoutMs 冒充取消（测试使用的 timeout 设为 10000ms+）。
//   * libcurl 进度回调通常以 ~1s 间隔触发，测试中实测毫秒数如实打印，不硬编码欺骗。

#include "net/http_client.h"
#include <arpa/inet.h>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <netinet/in.h>
#include <string>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
#include <vector>

static int g_failed = 0;

static void ck(bool cond, const char* name, const std::string& detail = "") {
    if (cond) {
        std::printf("  [PASS] %s\n", name);
    } else {
        std::printf("  [FAIL] %s %s\n", name, detail.c_str());
        g_failed++;
    }
}

// ---------------- 极简测试用 Loopback HTTP Server ----------------
// 支持慢速响应头、慢速持续数据流、正常响应
class SlowHttpServer {
public:
    enum class Mode {
        Normal,
        DelayHeaders, // 接收请求后延迟 N ms 才发响应头
        SlowStream    // 先发响应头，然后每隔 delayChunkMs 发送一部分 body，持续流
    };

    SlowHttpServer(Mode mode, int delayMs = 3000)
        : mode_(mode), delayMs_(delayMs) {}

    ~SlowHttpServer() {
        stop();
    }

    bool start() {
        listenFd_ = ::socket(AF_INET, SOCK_STREAM, 0);
        if (listenFd_ < 0) return false;

        int opt = 1;
        ::setsockopt(listenFd_, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = 0; // 随机端口

        if (::bind(listenFd_, (sockaddr*)&addr, sizeof(addr)) != 0) {
            ::close(listenFd_);
            listenFd_ = -1;
            return false;
        }

        socklen_t len = sizeof(addr);
        if (::getsockname(listenFd_, (sockaddr*)&addr, &len) != 0) {
            ::close(listenFd_);
            listenFd_ = -1;
            return false;
        }
        port_ = ntohs(addr.sin_port);

        if (::listen(listenFd_, 16) != 0) {
            ::close(listenFd_);
            listenFd_ = -1;
            return false;
        }

        running_ = true;
        thread_ = std::thread([this]() { run(); });
        return true;
    }

    uint16_t port() const { return port_; }
    std::string url(const std::string& path = "/test") const {
        return "http://127.0.0.1:" + std::to_string(port_) + path;
    }

    void stop() {
        if (!running_.exchange(false)) return;
        if (listenFd_ >= 0) {
            ::shutdown(listenFd_, SHUT_RDWR);
            ::close(listenFd_);
        }
        if (thread_.joinable()) {
            thread_.join();
        }
        listenFd_ = -1; // 只在 accept 线程退出后写，避免并发读取产生数据竞争。
        {
            std::lock_guard<std::mutex> lk(clientMtx_);
            // fd 由对应 worker 唯一 close；这里仅 shutdown 唤醒，不能双重 close。
            for (int fd : clientFds_) ::shutdown(fd, SHUT_RDWR);
        }
        // 等待所有 client worker 退出
        std::unique_lock<std::mutex> lk(workerMtx_);
        workerCv_.wait(lk, [this]() { return activeWorkers_ == 0; });
    }

    int requestCount() const { return requestCount_.load(); }

private:
    void run() {
        while (running_) {
            sockaddr_in caddr{};
            socklen_t clen = sizeof(caddr);
            int cfd = ::accept(listenFd_, (sockaddr*)&caddr, &clen);
            if (cfd < 0) break;

            requestCount_++;
            {
                std::lock_guard<std::mutex> lk(clientMtx_);
                clientFds_.push_back(cfd);
            }
            {
                std::lock_guard<std::mutex> lk(workerMtx_);
                activeWorkers_++;
            }

            std::thread([this, cfd]() {
                handleClient(cfd);
                {
                    std::lock_guard<std::mutex> lk(clientMtx_);
                    for (auto it = clientFds_.begin(); it != clientFds_.end(); ++it) {
                        if (*it == cfd) {
                            clientFds_.erase(it);
                            break;
                        }
                    }
                }
                ::close(cfd);
                {
                    std::lock_guard<std::mutex> lk(workerMtx_);
                    activeWorkers_--;
                }
                workerCv_.notify_all();
            }).detach();
        }
    }

    void handleClient(int cfd) {
        // 读取请求直到 \r\n\r\n
        int noSigPipe = 1;
        ::setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
        std::string reqBuf;
        char buf[1024];
        while (running_) {
            ssize_t n = ::recv(cfd, buf, sizeof(buf), 0);
            if (n <= 0) return;
            reqBuf.append(buf, n);
            if (reqBuf.find("\r\n\r\n") != std::string::npos) break;
        }

        if (mode_ == Mode::Normal) {
            std::string body = "Hello, Cancel Test!";
            std::string resp = "HTTP/1.1 200 OK\r\n"
                               "Content-Type: text/plain\r\n"
                               "Content-Length: " + std::to_string(body.size()) + "\r\n"
                               "Connection: close\r\n\r\n" + body;
            ::send(cfd, resp.data(), resp.size(), 0);
        } else if (mode_ == Mode::DelayHeaders) {
            // 睡眠 delayMs_ 后发送响应头
            int slept = 0;
            while (running_ && slept < delayMs_) {
                int step = std::min(50, delayMs_ - slept);
                std::this_thread::sleep_for(std::chrono::milliseconds(step));
                slept += step;
            }
            if (running_) {
                std::string body = "Delayed response";
                std::string resp = "HTTP/1.1 200 OK\r\n"
                                   "Content-Type: text/plain\r\n"
                                   "Content-Length: " + std::to_string(body.size()) + "\r\n"
                                   "Connection: close\r\n\r\n" + body;
                ::send(cfd, resp.data(), resp.size(), 0);
            }
        } else if (mode_ == Mode::SlowStream) {
            // 立即发头，然后缓慢持续发送 chunk，持续 10 秒
            std::string hdr = "HTTP/1.1 200 OK\r\n"
                              "Content-Type: application/octet-stream\r\n"
                              "Connection: close\r\n\r\n";
            if (::send(cfd, hdr.data(), hdr.size(), 0) <= 0) return;

            std::string chunk(4096, 'A');
            for (int i = 0; i < 100 && running_; ++i) {
                ssize_t ret = ::send(cfd, chunk.data(), chunk.size(), 0);
                if (ret <= 0) break; // 客户端主动断开
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
            }
        }
    }

    Mode mode_;
    int delayMs_ = 0;
    int listenFd_ = -1;
    uint16_t port_ = 0;
    std::atomic<bool> running_{false};
    std::atomic<int> requestCount_{0};
    std::thread thread_;
    std::mutex clientMtx_;
    std::vector<int> clientFds_;
    std::mutex workerMtx_;
    std::condition_variable workerCv_;
    int activeWorkers_ = 0;
};

int main() {
    std::printf("====================================================\n");
    std::printf("  HTTP 可取消阻塞请求验证 (test_http_cancel)\n");
    std::printf("====================================================\n");

    // ----------------------------------------------------
    // 1. 正常请求验证（基线：未设置取消，正常返回 200 OK）
    // ----------------------------------------------------
    std::printf("\n=== 1. 正常请求（未取消，验证 baseline）===\n");
    {
        SlowHttpServer srv(SlowHttpServer::Mode::Normal);
        ck(srv.start(), "启动 Loopback HTTP Server");

        auto t0 = std::chrono::steady_clock::now();
        rta::net::HttpResponse resp = rta::net::http_get(srv.url(), {}, 10000);
        auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - t0).count();

        ck(resp.ok, "正常请求 resp.ok == true");
        ck(resp.status == 200, "正常请求 status == 200");
        ck(resp.error.empty(), "正常请求 error 为空");
        std::string text(resp.body.begin(), resp.body.end());
        ck(text == "Hello, Cancel Test!", "返回 body 内容正确");
        std::printf("  [INFO] 正常请求耗时: %lld ms\n", (long long)ms);
    }

    // ----------------------------------------------------
    // 2. 预取消 (pre-canceled)
    // ----------------------------------------------------
    std::printf("\n=== 2. 预取消 (Pre-canceled：进入前 cancel 已为 true) ===\n");
    {
        SlowHttpServer srv(SlowHttpServer::Mode::DelayHeaders, 5000);
        ck(srv.start(), "启动延迟响应 Server (5s delay)");

        std::atomic<bool> cancelToken{true}; // 预先置为 true

        // 2.1 平台层直接传入 HttpRequest
        {
            rta::platform::HttpRequest req;
            req.url = srv.url();
            req.timeoutMs = 15000;
            req.cancel = &cancelToken;

            auto t0 = std::chrono::steady_clock::now();
            auto res = rta::platform::http_request(req);
            auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - t0).count();

            ck(!res.ok, "预取消 platform::http_request 返回 !ok");
            ck(res.status == 0, "预取消 status == 0");
            ck(res.error == "请求已取消", "预取消 error 明确为 '请求已取消'");
            ck(ms < 100, "预取消几乎立即可返 (<100ms)", std::to_string(ms) + " ms");
            std::printf("  [INFO] 预取消耗时: %lld ms (Server 请求数: %d)\n",
                        (long long)ms, srv.requestCount());
        }

        // 2.2 net 层 HttpCancellationScope 注入
        {
            rta::net::HttpCancellationScope scope(&cancelToken);

            auto t0 = std::chrono::steady_clock::now();
            auto resp = rta::net::http_get(srv.url(), {}, 15000);
            auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - t0).count();

            ck(!resp.ok, "预取消 http_get 返回 !ok");
            ck(resp.status == 0, "预取消 status == 0");
            ck(resp.error == "请求已取消", "预取消 error 明确为 '请求已取消'");
            ck(ms < 100, "预取消几乎立即可返 (<100ms)", std::to_string(ms) + " ms");
            std::printf("  [INFO] HttpCancellationScope 预取消耗时: %lld ms\n", (long long)ms);
        }
    }

    // ----------------------------------------------------
    // 3. 等待响应头期间取消 (Cancel while waiting for server headers)
    // ----------------------------------------------------
    std::printf("\n=== 3. 等待响应头期间取消 (Waiting for headers) ===\n");
    {
        SlowHttpServer srv(SlowHttpServer::Mode::DelayHeaders, 8000); // 8s 响应
        ck(srv.start(), "启动延迟响应 Server (8s delay)");

        std::atomic<bool> cancelToken{false};
        rta::net::HttpResponse resp;
        std::atomic<bool> threadStarted{false};

        auto t0 = std::chrono::steady_clock::now();
        std::thread worker([&]() {
            rta::net::HttpCancellationScope scope(&cancelToken);
            threadStarted = true;
            // timeout 设置为 20000ms，证明绝非靠短 timeout 返回
            resp = rta::net::http_get(srv.url(), {}, 20000);
        });

        while (!threadStarted) {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
        // 以服务端实际接收为握手，不用 threadStarted + sleep 假定网络请求已发出。
        const auto acceptedDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
        while (srv.requestCount() == 0 && std::chrono::steady_clock::now() < acceptedDeadline)
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        ck(srv.requestCount() > 0, "取消前服务端已接受真实连接");
        std::this_thread::sleep_for(std::chrono::milliseconds(200));

        // 触发取消
        auto tCancel = std::chrono::steady_clock::now();
        cancelToken.store(true);

        // 等待 worker 真实 join
        worker.join();
        auto tJoin = std::chrono::steady_clock::now();

        auto cancelToJoinMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            tJoin - tCancel).count();
        auto totalMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            tJoin - t0).count();

        ck(!resp.ok, "等待响应头取消 resp.ok == false");
        ck(resp.status == 0, "等待响应头取消 status == 0");
        ck(resp.error == "请求已取消", "等待响应头取消 error 明确为 '请求已取消'");
        // 关键断言：绝对远小于 8000ms（Server 延迟）和 20000ms（timeout）
        ck(totalMs < 3000, "耗时远小于 Server 延迟 8s 和 timeout 20s", std::to_string(totalMs) + " ms");
        std::printf("  [INFO] 等待响应头期间取消: 取消触发至 worker join 耗时 %lld ms (总耗时 %lld ms)\n",
                    (long long)cancelToJoinMs, (long long)totalMs);
    }

    // ----------------------------------------------------
    // 4. 下载/传输中取消 (Cancel while receiving slow stream)
    // ----------------------------------------------------
    std::printf("\n=== 4. 传输中取消 (Downloading / In-flight cancel) ===\n");
    {
        SlowHttpServer srv(SlowHttpServer::Mode::SlowStream, 10000); // 持续发送流
        ck(srv.start(), "启动流式响应 Server");

        std::atomic<bool> cancelToken{false};
        rta::net::HttpResponse resp;
        std::atomic<bool> threadStarted{false};

        auto t0 = std::chrono::steady_clock::now();
        std::thread worker([&]() {
            rta::net::HttpCancellationScope scope(&cancelToken);
            threadStarted = true;
            resp = rta::net::http_get(srv.url(), {}, 20000);
        });

        while (!threadStarted) {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
        // 等待连接并收到部分数据
        std::this_thread::sleep_for(std::chrono::milliseconds(150));

        // 传输中置位取消
        auto tCancel = std::chrono::steady_clock::now();
        cancelToken.store(true);

        worker.join();
        auto tJoin = std::chrono::steady_clock::now();

        auto cancelToJoinMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            tJoin - tCancel).count();
        auto totalMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            tJoin - t0).count();

        ck(!resp.ok, "下载中取消 resp.ok == false");
        ck(resp.status == 0, "下载中取消 status == 0");
        ck(resp.error == "请求已取消", "下载中取消 error 明确为 '请求已取消'");
        ck(totalMs < 2000, "下载中取消快速返回", std::to_string(totalMs) + " ms");
        std::printf("  [INFO] 传输中取消: 取消触发至 worker join 耗时 %lld ms (总耗时 %lld ms)\n",
                    (long long)cancelToJoinMs, (long long)totalMs);
    }

    // ----------------------------------------------------
    // 5. 作用域隔离与嵌套还原 (Scope isolation & nesting)
    // ----------------------------------------------------
    std::printf("\n=== 5. 作用域隔离与嵌套还原 (Thread-local & Nesting) ===\n");
    {
        SlowHttpServer srv(SlowHttpServer::Mode::Normal);
        ck(srv.start(), "启动 Normal Server");

        std::atomic<bool> tokenActive{true};
        std::atomic<bool> tokenInactive{false};

        // 5.1 嵌套测试：外层取消，内层置空/未取消，内层析构后恢复外层取消
        {
            rta::net::HttpCancellationScope outer(&tokenActive);
            {
                // 内层传入 nullptr，恢复原行为（未取消）
                rta::net::HttpCancellationScope inner(nullptr);
                auto rInner = rta::net::http_get(srv.url(), {}, 5000);
                ck(rInner.ok, "内层 scope(nullptr) 临时还原未取消状态 ⟹ 请求成功");
                ck(rInner.status == 200, "内层 status == 200");
            }
            // 出了内层，外层 active token 重新生效
            auto rOuter = rta::net::http_get(srv.url(), {}, 5000);
            ck(!rOuter.ok, "退出内层后外层取消重新生效 ⟹ 请求失败");
            ck(rOuter.error == "请求已取消", "外层 error 为 '请求已取消'");
        }

        // 5.2 作用域只影响当前线程，不影响其他并发线程
        {
            std::atomic<bool> threadCancel{true};
            std::atomic<bool> bgSuccess{false};

            // 在主线程开启 cancel scope
            rta::net::HttpCancellationScope scope(&threadCancel);

            // 另起后台线程（模拟 UPnP / 播放等线程），后台线程未设 scope，应该不受主线程影响
            std::thread bgThread([&]() {
                auto r = rta::net::http_get(srv.url(), {}, 5000);
                if (r.ok && r.status == 200) {
                    bgSuccess = true;
                }
            });

            // 主线程调用应当被取消
            auto rMain = rta::net::http_get(srv.url(), {}, 5000);
            ck(!rMain.ok && rMain.error == "请求已取消", "主线程在 scope 内被正确取消");

            bgThread.join();
            ck(bgSuccess.load(), "并发后台线程不受主线程取消作用域影响，请求正常成功");
        }
    }

    // ----------------------------------------------------
    // 6. POST 请求取消验证
    // ----------------------------------------------------
    std::printf("\n=== 6. POST 请求取消验证 ===\n");
    {
        SlowHttpServer srv(SlowHttpServer::Mode::DelayHeaders, 5000);
        ck(srv.start(), "启动 POST 延迟 Server");

        std::atomic<bool> token{true};
        rta::net::HttpCancellationScope scope(&token);

        auto t0 = std::chrono::steady_clock::now();
        auto resp = rta::net::http_post(srv.url(), "{\"query\":\"test\"}", {}, "application/json", 15000);
        auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - t0).count();

        ck(!resp.ok, "POST 请求预取消 resp.ok == false");
        ck(resp.status == 0, "POST 请求预取消 status == 0");
        ck(resp.error == "请求已取消", "POST 请求预取消 error == '请求已取消'");
        ck(ms < 100, "POST 预取消立刻返回", std::to_string(ms) + " ms");
    }

    std::printf("\n====================================================\n");
    if (g_failed == 0) {
        std::printf("  全部用例通过 (ALL PASSED)\n");
    } else {
        std::printf("  失败用例数: %d\n", g_failed);
    }
    std::printf("====================================================\n");

    return g_failed == 0 ? 0 : 1;
}