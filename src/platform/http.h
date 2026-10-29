// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// http.h — HTTP(S) 传输（平台层契约，跨平台）
//
// 为什么它是平台层而不是 net/ 的一部分：TLS 不可能自己实现（net/http_client.h 的头注已写明）。
// Windows 用 WinHTTP（系统组件、零依赖、自动重定向/chunked/代理），Mac 必须用
// NSURLSession 或 libcurl —— 这是真正的平台差异，因此放在这里。
//
// 只支持 GET/POST：流媒体接入只需要"把原始文件拉下来"和几个 JSON API。
// 本层不做 JSON、不做 URL 语义、不做重试 —— 那些是 net/、meta/ 的事。
//
// 契约要点（Mac 组必须一致）：
//   * 阻塞调用（在调用线程同步跑完整个请求），不回调、不后台线程
//   * 只跟随平台默认重定向策略（WinHTTP 默认跟随；Mac 用 NSURLSession 默认策略）
//   * 超时 timeoutMs 同时作用于连接/发送/接收（WinHTTP 四个超时同值）
//   * 非 2xx 不算异常：照常返回 body，ok=false，error 里有 "HTTP <码>"
//   * 任何失败都要在 error 里留下非空、可读的中文原因（不许静默返回空 body）
#pragma once
#include <atomic>
#include <cstddef>
#include <cstdio>
#include <string>
#include <vector>

namespace rta::platform {

struct HttpRequest {
    std::string method = "GET";                    // "GET" / "POST"
    std::string url;                               // http(s)://host[:port]/path
    std::vector<std::string> headers;              // 每项形如 "名: 值"
    std::string body;                              // 仅 POST
    std::string contentType = "application/json";  // 仅 POST，作为 Content-Type 头
    int timeoutMs = 20000;
    std::string proxy;                             // 空 = 直连；"host:port" 或 "http://host:port"
                                                   // 空时**自动回退系统代理**（见下方 SystemProxySettings）
    std::string noProxy;                           // CURLOPT_NOPROXY（系统代理的例外表）；空 = 不过滤
    // 钉住出站网卡（形如 "en1"；空 = 交给系统选路）。
    // 为什么需要（2026-10-28 真机）：本机「Internet 共享」造出一个同网段的虚拟网桥，
    // 路由表把 192.168.3.0/24 整段交给它并标 REJECT ⟹ 不钉网卡时连 192.168.3.x 直接
    // EHOSTUNREACH，表现就是"设备找到了却控制不了/抓不到描述"。
    // macOS 实现用 CURLOPT_INTERFACE("if!en1")；没有该能力的平台忽略此字段。
    std::string interface;
    const std::atomic<bool>* cancel = nullptr;     // 取消标志（空 = 不支持外部取消；非空且为 true 时中断请求）
};

struct HttpResult {
    bool timedOut = false;             // actual transport timeout, not a configured budget
    bool ok = false;                  // 2xx
    int status = 0;
    std::string contentType;
    std::string error;
    std::vector<unsigned char> body;
    size_t size() const { return body.size(); }
};

HttpResult http_request(const HttpRequest& req);

// ---------------- 纯函数（跨平台，可离线测）----------------

// 代理串归一化：剥 scheme 与路径，只留 host:port
//  "http://127.0.0.1:7897" -> "127.0.0.1:7897"；"" -> ""
inline std::string normalize_proxy(const std::string& proxy) {
    std::string hp = proxy;
    if (hp.rfind("http://", 0) == 0) hp = hp.substr(7);
    else if (hp.rfind("https://", 0) == 0) hp = hp.substr(8);
    const size_t slash = hp.find('/');
    if (slash != std::string::npos) hp = hp.substr(0, slash);
    return hp;
}

// ---------------- 系统代理（2026-10-26 修「检查更新永远是网络不可用」）----------------
//
// 背景（真机实测，不是猜测）：
//   macOS 上 libcurl **不读系统代理**，它只认 CURLOPT_PROXY / http_proxy 等环境变量。
//   用户机器上 GitHub 必须走系统代理（scutil --proxy: HTTPSProxy=127.0.0.1:7897）才通，
//   而 .app 双击启动时环境里没有任何 proxy 变量 ⟹ 更新检查必然超时，
//   界面还只说「网络不可用」，连是 DNS、TLS 还是超时都看不到。
//
// 语义（用户 2026-10-26 明确）：**有代理走代理，没代理直连**，不需要用户手工配任何东西。
//   * 显式 req.proxy 非空 ⟹ 用它（rlplayer-llm.conf 的 proxy= 仍然有效，优先级最高）
//   * 否则读系统代理：https 请求看 HTTPSProxy/HTTPSPort，http 请求看 HTTPProxy/HTTPPort
//   * 系统里没开代理（或端口非法）⟹ 返回空串 ⟹ 直连（行为与以前完全一致）
//   * 系统 ExceptionsList（127.0.0.1 / 10/8 / 192.168/16 / 172.16/12 / *.local …）
//     原样交给 libcurl 的 CURLOPT_NOPROXY ⟹ **局域网 Navidrome/Emby/UPnP 不会被绕进代理**
//     （CIDR 匹配 libcurl 7.86+ 原生支持，本机 8.7.1 实测可用）
//
// 下面这个结构体是**纯数据**，pick_proxy_for_url 是**纯函数**，
// 所以「选不选代理、用哪个端口」这件事可以离线单测，不依赖本机是否真的开着代理。
struct SystemProxySettings {
    bool        httpEnabled  = false;
    std::string httpHost;
    int         httpPort     = 0;
    bool        httpsEnabled = false;
    std::string httpsHost;
    int         httpsPort    = 0;
    std::string exceptions;        // 逗号分隔，直接喂 CURLOPT_NOPROXY
};

// 按 URL 的 scheme 选出该用的代理，返回 "host:port"；空串 = 直连。
// 端口必须落在 1..65535，否则视为「配了但不完整」⟹ 直连（不猜默认端口，猜错更糟）。
inline std::string pick_proxy_for_url(const SystemProxySettings& s, const std::string& url) {
    auto starts_ci = [&](const char* pre) {
        const size_t n = std::char_traits<char>::length(pre);
        if (url.size() < n) return false;
        for (size_t i = 0; i < n; ++i) {
            const char a = (char)((url[i] >= 'A' && url[i] <= 'Z') ? url[i] + 32 : url[i]);
            if (a != pre[i]) return false;
        }
        return true;
    };
    const bool isHttps = starts_ci("https://");
    const bool isHttp  = starts_ci("http://");
    if (!isHttps && !isHttp) return std::string();      // 其它 scheme 不代理
    const bool    enabled = isHttps ? s.httpsEnabled : s.httpEnabled;
    const std::string& host = isHttps ? s.httpsHost : s.httpHost;
    const int     port    = isHttps ? s.httpsPort : s.httpPort;
    if (!enabled || host.empty() || port <= 0 || port > 65535) return std::string();
    return host + ":" + std::to_string(port);
}

// URL 里非 ASCII 的路径/查询部分做百分号编码（已编码的 % 不再编 —— 防双重编码）
inline std::string percent_encode_path(const std::string& s) {
    std::string o;
    for (unsigned char c : s) {
        if (c <= 0x20 || c >= 0x7F || c == '"' || c == '<' || c == '>' || c == '#' ||
            c == '\\' || c == '^' || c == '|') {
            char b[8];
            std::snprintf(b, sizeof(b), "%%%02X", c);
            o += b;
        } else {
            o += (char)c;
        }
    }
    return o;
}

} // namespace rta::platform

// macOS 实现（PLATFORM.md §9）。2026-10-25 项目转 macOS 单平台：Windows 分派支与 #else/#error 兜底已删除。
#include "platform/macos/http_posix.h"
