// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// Standalone transport regression: no core, user state, or audio device access.
#include "net/webui.h"
#include <condition_variable>
#include <mutex>
#include <thread>

static int failures = 0;
static void check(bool ok, const char* label) {
    std::printf("[%s] %s\n", ok ? "PASS" : "FAIL", label);
    if (!ok) ++failures;
}

static std::string request(uint16_t port, const char* path) {
    const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return {};
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(port);
    timeval timeout{3, 0};
    ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    if (::connect(fd, (sockaddr*)&addr, sizeof(addr)) != 0) {
        ::close(fd);
        return {};
    }
    const std::string wire = std::string("GET ") + path +
        " HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    size_t sent = 0;
    while (sent < wire.size()) {
        const ssize_t n = ::send(fd, wire.data() + sent, wire.size() - sent, 0);
        if (n <= 0) { ::close(fd); return {}; }
        sent += (size_t)n;
    }
    std::string result;
    char buf[1024];
    for (;;) {
        const ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
        if (n <= 0) break;
        result.append(buf, (size_t)n);
    }
    ::close(fd);
    return result;
}

int main() {
    // Deterministic overlap: A sets 503, B checks its initial state and sets 404,
    // then A consumes its response before B consumes its own. A global atomic
    // reliably produces 404/200 here; merely hammering requests can miss the race.
    std::mutex mutex;
    std::condition_variable cv;
    int phase = 0, aStatus = 0, bInitial = 0, bStatus = 0;
    rta::net::webui_status_slot()->store(200);
    std::thread a([&] {
        rta::net::webui_set_status(503);
        std::unique_lock<std::mutex> lock(mutex);
        phase = 1; cv.notify_all();
        cv.wait(lock, [&] { return phase == 2; });
        aStatus = rta::net::webui_status_slot()->exchange(200);
        phase = 3; cv.notify_all();
    });
    std::thread b([&] {
        std::unique_lock<std::mutex> lock(mutex);
        cv.wait(lock, [&] { return phase == 1; });
        bInitial = rta::net::webui_status_slot()->load();
        rta::net::webui_set_status(404);
        phase = 2; cv.notify_all();
        cv.wait(lock, [&] { return phase == 3; });
        bStatus = rta::net::webui_status_slot()->exchange(200);
    });
    a.join(); b.join();
    check(bInitial == 200, "new request thread starts at 200, not another thread's 503");
    check(aStatus == 503 && bStatus == 404, "overlapping threads retain their own 503 and 404");
    check(rta::net::webui_status_slot()->load() == 200, "worker states do not contaminate caller");

    rta::net::WebUi server;
    bool started = false;
    for (uint16_t port = 19141; port < 19150 && !started; ++port) {
        started = server.start(port, [](const rta::net::HttpRequest& req, std::string& ct) {
            ct = "application/json; charset=utf-8";
            if (req.path == "/busy") {
                rta::net::webui_set_status(503);
                return std::string("{\"ok\":false,\"error\":\"cover busy\"}");
            }
            if (req.path == "/missing") {
                rta::net::webui_set_status(404);
                return std::string("{\"ok\":false,\"error\":\"not found\"}");
            }
            return std::string("{\"ok\":true}");
        });
    }
    check(started, "isolated HTTP listener starts on 19141-19149");
    if (started) {
        const auto busy = request(server.port(), "/busy");
        check(busy.rfind("HTTP/1.1 503 Service Unavailable\r\n", 0) == 0, "wire preserves HTTP503 and reason");
        check(busy.find("\r\nRetry-After: 2\r\n") != std::string::npos, "wire HTTP503 carries Retry-After: 2");
        check(busy.find("\r\nContent-Type: application/json; charset=utf-8\r\n") != std::string::npos &&
              busy.find("\r\n\r\n{\"ok\":false,\"error\":\"cover busy\"}") != std::string::npos,
              "wire HTTP503 preserves JSON content type and body");
        const auto missing = request(server.port(), "/missing");
        check(missing.rfind("HTTP/1.1 404 Not Found\r\n", 0) == 0, "wire preserves real HTTP404 and reason");
        check(missing.find("Retry-After:") == std::string::npos, "HTTP404 has no busy retry header");
        const auto ok = request(server.port(), "/ok");
        check(ok.rfind("HTTP/1.1 200 OK\r\n", 0) == 0 && ok.find("Retry-After:") == std::string::npos,
              "HTTP200 after errors has no leaked state or retry header");
        server.stop();
    }
    std::printf("%d failures\n", failures);
    return failures ? 1 : 0;
}
