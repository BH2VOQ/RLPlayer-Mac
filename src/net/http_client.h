// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// http_client.h — 极简 HTTP(S) 客户端（与平台无关的外壳；传输实现在 platform/http.h）
//
// 为什么传输在平台层：Navidrome / Emby 常常跑在 HTTPS 上，自己实现 TLS 不现实。
// Windows 用 WinHTTP（系统组件，零额外依赖，自动处理重定向、chunked、代理），
// Mac 必须用 NSURLSession/libcurl —— 这是真正的平台差异，因此
// src/platform/windows/http_winhttp.h 里放 WinHTTP，本文件只保留跨平台部分。
//
// 本文件保留 rta::net::HttpResponse / http_get / http_post 这些名字，是因为
// net/、meta/、tools/、tests/ 里已有 20+ 个调用点；换命名空间是纯风险零收益。
//
// 只实现 GET/POST —— 流媒体接入只需要"把原始文件拉下来"和几个 JSON API。
#pragma once
#include "platform/http.h"
#include <mutex>
#include <string>
#include <utility>
#include <vector>

namespace rta::net {

struct HttpResponse {
    bool         ok = false;
    int          status = 0;
    std::string  contentType;
    std::string  error;
    std::vector<unsigned char> body;
    size_t       size() const { return body.size(); }
};

// 把 URL 里非 ASCII 的路径/查询部分做百分号编码。
// 实现在 platform/http.h（纯函数、跨平台）；这里只是转发 ——
// 名字留在 net 命名空间是因为 meta/provider.h 与两个测试都在用。
inline std::string percent_encode_path(const std::string& s) {
    return rta::platform::percent_encode_path(s);
}

namespace http_detail {
inline HttpResponse from_platform(rta::platform::HttpResult&& p) {
    HttpResponse r;
    r.ok          = p.ok;
    r.status      = p.status;
    r.contentType = std::move(p.contentType);
    r.error       = std::move(p.error);
    r.body        = std::move(p.body);
    return r;
}
} // namespace http_detail

// 可选全局代理（P1.5）：默认空 = 直连（现状行为不变）。rtaweb 启动时若
// rlplayer-llm.conf 有 proxy=host:port 行则 set_http_proxy —— 对之后所有
// http_get/http_post 生效；emby/subsonic 等既有调用不配置时代理为空，不受影响。
inline std::string& http_proxy_slot() { static std::string p; return p; }
inline std::mutex&  http_proxy_mtx()  { static std::mutex m; return m; }

// 设置全局代理（hostPort 形如 "127.0.0.1:7897"，也容忍 "http://host:port"）；空串 = 直连。
inline void set_http_proxy(const std::string& hostPort) {
    std::lock_guard<std::mutex> lk(http_proxy_mtx());
    http_proxy_slot() = hostPort;
}
// 读当前代理（空 = 直连）。
inline std::string http_proxy() {
    std::lock_guard<std::mutex> lk(http_proxy_mtx());
    return http_proxy_slot();
}

// 纯函数（可离线测）：归一化代理串 —— 剥掉 scheme 与路径，只留 host:port 形态。
// "http://127.0.0.1:7897" → "127.0.0.1:7897"；"" → ""。实现在 platform/http.h。
inline std::string http_proxy_normalize(const std::string& proxy) {
    return rta::platform::normalize_proxy(proxy);
}

// ---------------- 线程局部的取消作用域（P1.6 / i8-http）----------------
//
// 契约：
//   * HttpCancellationScope(const std::atomic<bool>* token) 进入作用域，在当前线程绑定取消 token。
//   * RAII 析构时恢复进入前的 token，支持任意嵌套。
//   * 仅影响当前线程的 http_get / http_post 调用，不影响其他线程（如 UPnP / 播放等）。
//   * token 为 nullptr 时表示该作用域内取消未激活（可用于临时恢复为无取消）。
//   * token 的生命周期由调用者保证有效至作用域结束（或所有下游阻塞请求完成）。
namespace http_detail {
inline const std::atomic<bool>*& current_cancellation_token() {
    static thread_local const std::atomic<bool>* s_token = nullptr;
    return s_token;
}
} // namespace http_detail

class HttpCancellationScope {
public:
    explicit HttpCancellationScope(const std::atomic<bool>* token)
        : prev_(http_detail::current_cancellation_token()) {
        http_detail::current_cancellation_token() = token;
    }
    ~HttpCancellationScope() {
        http_detail::current_cancellation_token() = prev_;
    }
    HttpCancellationScope(const HttpCancellationScope&) = delete;
    HttpCancellationScope& operator=(const HttpCancellationScope&) = delete;

private:
    const std::atomic<bool>* prev_ = nullptr;
};

// POST（Emby 认证、LLM、元数据源需要）
inline HttpResponse http_post(const std::string& url, const std::string& body,
                              const std::vector<std::string>& headers = {},
                              const char* contentType = "application/json",
                              int timeoutMs = 20000) {
    rta::platform::HttpRequest req;
    req.method      = "POST";
    req.url         = url;
    req.headers     = headers;
    req.body        = body;
    req.contentType = contentType ? contentType : "application/json";
    req.timeoutMs   = timeoutMs;
    req.proxy       = http_proxy();
    req.cancel      = http_detail::current_cancellation_token();
    return http_detail::from_platform(rta::platform::http_request(req));
}

// GET，可选附加请求头（每项形如 "名: 值"）
inline HttpResponse http_get(const std::string& url,
                             const std::vector<std::string>& headers = {},
                             int timeoutMs = 20000) {
    rta::platform::HttpRequest req;
    req.method    = "GET";
    req.url       = url;
    req.headers   = headers;
    req.timeoutMs = timeoutMs;
    req.proxy     = http_proxy();
    req.cancel    = http_detail::current_cancellation_token();
    return http_detail::from_platform(rta::platform::http_request(req));
}

inline std::string http_get_text(const std::string& url,
                                 const std::vector<std::string>& headers = {},
                                 int timeoutMs = 20000) {
    auto r = http_get(url, headers, timeoutMs);
    return std::string(r.body.begin(), r.body.end());
}

} // namespace rta::net
