// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_webui_hardening.cpp — WebUi 安全加固验证
//
// 判据覆盖：
//   ① 状态行：GET 存在的路径 → 首行 HTTP/1.1 200 OK；handler 调 webui_set_status(405) → HTTP/1.1 405 Method Not Allowed
//   ② 头超时：发送半截请求（不发空行）→ 收到 400 JSON 而不是连接裸断
//   ③ Content-Length 非法（Content-Length: abc）→ 400
//   ④ body 超限（Content-Length 声明 > 16MB）→ 413
//   ⑤ 超长 URL（> 64KB 请求行）→ 431
//   ⑥ --lan 模式 + Host: evil.com → 403；Host: localhost → 200
//   ⑦ 正常路径不受影响：POST body 往返 + GET 页面 200
#include "net/webui.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <chrono>
#include <vector>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

using namespace rta::net;

static int g_fail = 0;
static void ck(bool cond, const std::string& what, const std::string& detail = "") {
    if (cond) {
        std::printf("  [PASS] %s\n", what.c_str());
    } else {
        std::printf("  [FAIL] %s  %s\n", what.c_str(), detail.c_str());
        ++g_fail;
    }
}

// 辅助函数：通过原始 socket 发送请求并读取全部响应
static std::string raw_http_exchange(uint16_t port, const std::string& reqData, int timeoutSec = 2) {
    int s = ::socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return "";
    struct timeval tv;
    tv.tv_sec = timeoutSec;
    tv.tv_usec = 0;
    ::setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    ::setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (::connect(s, (sockaddr*)&a, sizeof(a)) != 0) {
        ::close(s);
        return "";
    }
    if (!reqData.empty()) {
        ::send(s, reqData.data(), reqData.size(), 0);
    }
    std::string resp;
    char buf[4096];
    while (true) {
        int r = ::recv(s, buf, sizeof(buf), 0);
        if (r <= 0) break;
        resp.append(buf, (size_t)r);
    }
    ::close(s);
    return resp;
}

int main() {
    std::printf("=== test_webui_hardening: WebUi 传输层安全加固测试 ===\n\n");

    const uint16_t port1 = 8912;
    const uint16_t port2 = 8913;

    // 实例 1：loopbackOnly = true (默认)
    WebUi ui1;
    bool ok1 = ui1.start(port1, [](const HttpRequest& req, std::string& ct) -> std::string {
        if (req.path == "/test_405") {
            webui_set_status(405);
            ct = "application/json; charset=utf-8";
            return "{\"ok\":false,\"error\":\"Method Not Allowed\"}";
        }
        if (req.path == "/echo_body") {
            ct = "text/plain";
            return req.body;
        }
        ct = "application/json; charset=utf-8";
        return "{\"ok\":true}";
    }, true);
    if (!ok1) {
        std::printf("无法启动 WebUi 实例 1，端口 %d\n", port1);
        return 1;
    }

    // -------------------------------------------------------------
    // 判据 ①：状态行（200 与 405）
    // -------------------------------------------------------------
    std::printf("-- 判据 ①：真状态行 (200 / 405) --\n");
    {
        std::string resp200 = raw_http_exchange(port1, "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
        ck(resp200.rfind("HTTP/1.1 200 OK", 0) == 0, "GET / 返回 HTTP/1.1 200 OK", resp200.substr(0, 30));

        std::string resp405 = raw_http_exchange(port1, "GET /test_405 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
        ck(resp405.rfind("HTTP/1.1 405 Method Not Allowed", 0) == 0, "GET /test_405 返回 HTTP/1.1 405 Method Not Allowed", resp405.substr(0, 35));
        ck(resp405.find("Method Not Allowed") != std::string::npos, "405 响应内容携带错误描述");
    }

    // -------------------------------------------------------------
    // 判据 ②：头超时（半截请求，等 500ms 超时）
    // -------------------------------------------------------------
    std::printf("\n-- 判据 ②：头超时 (半截请求 -> 400 Bad Request JSON) --\n");
    {
        // 只发请求行，不发空行，让服务端在 500ms 超时后 fail(400)
        auto t0 = std::chrono::steady_clock::now();
        std::string respTimeout = raw_http_exchange(port1, "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n", 2);
        auto dur = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
        ck(respTimeout.rfind("HTTP/1.1 400 Bad Request", 0) == 0, "半截请求返回 HTTP/1.1 400 Bad Request", respTimeout.substr(0, 30));
        ck(respTimeout.find("\"ok\":false") != std::string::npos && respTimeout.find("请求头不完整") != std::string::npos,
           "头超时返回完整 JSON 错误", respTimeout);
        ck(dur >= 400 && dur <= 1500, "头超时时间符合 ~500ms 预期 (" + std::to_string(dur) + " ms)");
    }

    // -------------------------------------------------------------
    // 判据 ③：Content-Length 非法
    // -------------------------------------------------------------
    std::printf("\n-- 判据 ③：Content-Length 非法 (-> 400 Bad Request) --\n");
    {
        std::string req = "POST /api/test HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: abc\r\nConnection: close\r\n\r\n";
        std::string resp = raw_http_exchange(port1, req);
        ck(resp.rfind("HTTP/1.1 400 Bad Request", 0) == 0, "Content-Length: abc 返回 HTTP/1.1 400 Bad Request", resp.substr(0, 30));
        ck(resp.find("Content-Length 非法") != std::string::npos, "返回错误提示 'Content-Length 非法'");
    }

    // -------------------------------------------------------------
    // 判据 ④：body 超限（Content-Length > 16MB）
    // -------------------------------------------------------------
    std::printf("\n-- 判据 ④：body 超限 (Content-Length > 16MB -> 413 Payload Too Large) --\n");
    {
        std::string req = "POST /api/test HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 20000000\r\nConnection: close\r\n\r\n";
        std::string resp = raw_http_exchange(port1, req);
        ck(resp.rfind("HTTP/1.1 413 Payload Too Large", 0) == 0, "Content-Length: 20MB 返回 HTTP/1.1 413 Payload Too Large", resp.substr(0, 35));
        ck(resp.find("请求体过大") != std::string::npos, "返回错误提示 '请求体过大（上限 16MB）'");
    }

    // -------------------------------------------------------------
    // 判据 ⑤：超长 URL（> 64KB 请求行 -> 431 Request Header Fields Too Large）
    // -------------------------------------------------------------
    std::printf("\n-- 判据 ⑤：超长 URL (> 64KB -> 431 Request Header Fields Too Large) --\n");
    {
        std::string longPath(70 * 1024, 'a');
        std::string req = "GET /" + longPath + " HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
        std::string resp = raw_http_exchange(port1, req);
        ck(resp.rfind("HTTP/1.1 431 Request Header Fields Too Large", 0) == 0, "超长 URL 返回 431", resp.substr(0, 45));
        ck(resp.find("请求头过大") != std::string::npos, "返回错误提示 '请求头过大（>64KB）'");
    }

    // -------------------------------------------------------------
    // 判据 ⑥：--lan 模式 Host 白名单 (evil.com -> 403, localhost -> 200)
    // -------------------------------------------------------------
    std::printf("\n-- 判据 ⑥：--lan 模式 Host 白名单 (Host: evil.com -> 403, localhost -> 200) --\n");
    {
        WebUi ui2;
        bool ok2 = ui2.start(port2, [](const HttpRequest&, std::string& ct) -> std::string {
            ct = "application/json; charset=utf-8";
            return "{\"ok\":true}";
        }, false); // loopbackOnly = false, 即 lan_ = true
        ck(ok2, "WebUi 实例 2 (lan 模式) 启动成功");

        if (ok2) {
            std::string reqEvil = "GET / HTTP/1.1\r\nHost: evil.com\r\nConnection: close\r\n\r\n";
            std::string respEvil = raw_http_exchange(port2, reqEvil);
            ck(respEvil.rfind("HTTP/1.1 403 Forbidden", 0) == 0, "Host: evil.com 返回 HTTP/1.1 403 Forbidden", respEvil.substr(0, 30));
            ck(respEvil.find("Host 不被允许") != std::string::npos, "返回错误提示 'Host 不被允许'");

            std::string reqLocal = "GET / HTTP/1.1\r\nHost: localhost:" + std::to_string(port2) + "\r\nConnection: close\r\n\r\n";
            std::string respLocal = raw_http_exchange(port2, reqLocal);
            ck(respLocal.rfind("HTTP/1.1 200 OK", 0) == 0, "Host: localhost:PORT 返回 HTTP/1.1 200 OK", respLocal.substr(0, 25));

            std::string reqIp = "GET / HTTP/1.1\r\nHost: 127.0.0.1:" + std::to_string(port2) + "\r\nConnection: close\r\n\r\n";
            std::string respIp = raw_http_exchange(port2, reqIp);
            ck(respIp.rfind("HTTP/1.1 200 OK", 0) == 0, "Host: 127.0.0.1:PORT 返回 HTTP/1.1 200 OK", respIp.substr(0, 25));
            ui2.stop();
        }
    }

    // -------------------------------------------------------------
    // 判据 ⑦：正常路径不受影响（POST body 往返 + GET 页面 200）
    // -------------------------------------------------------------
    std::printf("\n-- 判据 ⑦：正常路径不受影响 (POST body 往返 + GET 页面 200) --\n");
    {
        std::string bodyPayload = "hello world payload 1234567890";
        std::string reqPost = "POST /echo_body HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: " +
                              std::to_string(bodyPayload.size()) + "\r\nConnection: close\r\n\r\n" + bodyPayload;
        std::string respPost = raw_http_exchange(port1, reqPost);
        ck(respPost.rfind("HTTP/1.1 200 OK", 0) == 0, "POST /echo_body 返回 200 OK");
        ck(respPost.find(bodyPayload) != std::string::npos, "POST body 往返一致");

        std::string reqGet = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
        std::string respGet = raw_http_exchange(port1, reqGet);
        ck(respGet.rfind("HTTP/1.1 200 OK", 0) == 0, "GET / 正常返回 200 OK");
        ck(respGet.find("{\"ok\":true}") != std::string::npos, "GET / 返回正常 JSON");
    }

    ui1.stop();

    std::printf("\n======================================================\n");
    if (g_fail == 0) {
        std::printf("test_webui_hardening ALL TESTS PASSED!\n");
        return 0;
    } else {
        std::printf("test_webui_hardening FAILED: %d failures\n", g_fail);
        return 1;
    }
}
