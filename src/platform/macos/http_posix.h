// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// platform/macos/http_posix.h — http.h 的 POSIX/macOS 实现（libcurl）
//
// 为什么选 libcurl 而不是 NSURLSession（PLATFORM.md §9 第 7 条给的是 NSURLSession）：
//   1. 本层契约要求【阻塞、同步、返回 std::vector<unsigned char>】。NSURLSession 是
//      异步回调模型，同步包装要自己造信号量 + runloop，还必须在主线程之外跑 runloop，
//      反而引入"哪个线程有 runloop"这种隐形前提。
//   2. libcurl 随 macOS 系统提供（/usr/lib/libcurl.tbd，SDK 头齐全），零第三方依赖，
//      与"单包自包含"的要求一致（铁律 6）。Windows 侧用的 WinHTTP 也是系统组件，
//      语义上正好对应。
//   3. 超时/代理/重定向语义与 WinHTTP 几乎一一对应，便于保持"逐位等价"。
//
// 与 Windows 实现的语义对齐（PLATFORM.md §3.5）：
//   * 阻塞调用，跑完整个请求
//   * timeoutMs 同时作用于连接与传输（CURLOPT_CONNECTTIMEOUT_MS + CURLOPT_TIMEOUT_MS）
//   * 非 2xx 不算异常：照常返回 body，ok=false，error="HTTP <码>"
//   * proxy 空=直连；非空="host:port"，归一化用共享纯函数 normalize_proxy
//   * 跟随平台默认重定向策略（WinHTTP 默认跟随 ⟹ 这里 CURLOPT_FOLLOWLOCATION=1）
//
// 2026-10-26（用户实测「检查更新永远是网络不可用」的根因修复）：
//   macOS 的 libcurl **不读系统代理**，只认 CURLOPT_PROXY / http_proxy 环境变量；
//   而 .app 双击启动时环境里没有这些变量 ⟹ 系统代理开着也照样直连 ⟹ 必然超时。
//   现在：req.proxy 为空时向 SystemConfiguration 问系统代理，
//   **有就走、没有就直连**（用户明确要求的行为），并把 ExceptionsList 交给 CURLOPT_NOPROXY，
//   保证 127.0.0.1 / 10/8 / 192.168/16 / 172.16/12 / *.local 这类局域网地址不被绕进代理。
#include <cstring>
#include <string>
#include <vector>

#include <curl/curl.h>

#include <CoreFoundation/CoreFoundation.h>
#include <SystemConfiguration/SystemConfiguration.h>

namespace rta::platform {
namespace detail {

// 一次请求的写回调上下文
struct CurlSink {
    std::vector<unsigned char>* body = nullptr;
    std::string contentType;
};

inline size_t curl_write_cb(char* ptr, size_t size, size_t nmemb, void* userdata) {
    auto* sink = static_cast<CurlSink*>(userdata);
    const size_t n = size * nmemb;
    if (sink && sink->body) sink->body->insert(sink->body->end(), ptr, ptr + n);
    return n;
}

inline size_t curl_header_cb(char* buffer, size_t size, size_t nitems, void* userdata) {
    auto* sink = static_cast<CurlSink*>(userdata);
    const size_t n = size * nitems;
    if (!sink) return n;
    // 只关心 Content-Type（大小写不敏感），其余头忽略
    static const char kKey[] = "content-type:";
    const size_t klen = sizeof(kKey) - 1;
    if (n > klen) {
        bool match = true;
        for (size_t i = 0; i < klen; ++i) {
            const char a = (char)((buffer[i] >= 'A' && buffer[i] <= 'Z') ? buffer[i] + 32 : buffer[i]);
            if (a != kKey[i]) { match = false; break; }
        }
        if (match) {
            std::string v(buffer + klen, n - klen);
            while (!v.empty() && (v.back() == '\r' || v.back() == '\n' || v.back() == ' ')) v.pop_back();
            while (!v.empty() && v.front() == ' ') v.erase(v.begin());
            sink->contentType = v;
        }
    }
    return n;
}

// curl 全局只需初始化一次；用函数内静态量保证线程安全的懒初始化（C++11 起有保证）
inline bool curl_global_ready() {
    static const bool ok = (::curl_global_init(CURL_GLOBAL_DEFAULT) == CURLE_OK);
    return ok;
}

// ---------------- 系统代理读取（2026-10-26）----------------
// 从 SystemConfiguration 取当前生效的代理设置。**任何失败都返回"无代理"**，
// 绝不抛、绝不报错 —— "读不到系统代理"的语义就是直连，与改造前完全一致。
//
// 为什么不用 CFNetworkCopySystemProxySettings()：那个只给全局设置，
// SCDynamicStoreCopyProxies() 给的是**当前生效值**（含按接口的 scoped 覆盖），
// 与 Safari/curl --proxy 自动探测看到的一致。
inline SystemProxySettings read_system_proxy() {
    SystemProxySettings s;
    CFDictionaryRef dict = ::SCDynamicStoreCopyProxies(nullptr);
    if (!dict) return s;

    // ⚠️ 2026-10-26 实测坑：HTTPEnable / HTTPSEnable 在 macOS 上是 **CFNumber(1)**，
    // 不是 CFBoolean！只判 CFBoolean 会把"开着"读成"关着"，功能静默失效
    // （我第一版就踩了这个：单测全绿、真机却仍然直连）。两种类型都认，数值非 0 即真。
    auto get_bool = [&](CFStringRef key) -> bool {
        CFTypeRef v = ::CFDictionaryGetValue(dict, key);
        if (!v) return false;
        if (::CFGetTypeID(v) == ::CFBooleanGetTypeID()) return ::CFBooleanGetValue((CFBooleanRef)v);
        if (::CFGetTypeID(v) == ::CFNumberGetTypeID()) {
            int out = 0;
            return ::CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &out) && out != 0;
        }
        return false;
    };
    auto get_int = [&](CFStringRef key) -> int {
        CFTypeRef v = ::CFDictionaryGetValue(dict, key);
        if (!v || ::CFGetTypeID(v) != ::CFNumberGetTypeID()) return 0;
        int out = 0;
        return ::CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &out) ? out : 0;
    };
    auto get_str = [&](CFStringRef key) -> std::string {
        CFTypeRef v = ::CFDictionaryGetValue(dict, key);
        if (!v || ::CFGetTypeID(v) != ::CFStringGetTypeID()) return std::string();
        char buf[512] = {0};
        if (!::CFStringGetCString((CFStringRef)v, buf, sizeof(buf) - 1, kCFStringEncodingUTF8))
            return std::string();
        return std::string(buf);
    };

    s.httpEnabled  = get_bool(kSCPropNetProxiesHTTPEnable);
    s.httpHost     = get_str(kSCPropNetProxiesHTTPProxy);
    s.httpPort     = get_int(kSCPropNetProxiesHTTPPort);
    s.httpsEnabled = get_bool(kSCPropNetProxiesHTTPSEnable);
    s.httpsHost    = get_str(kSCPropNetProxiesHTTPSProxy);
    s.httpsPort    = get_int(kSCPropNetProxiesHTTPSPort);

    // ExceptionsList 是 CFArray<CFString>，拼成 libcurl 的逗号分隔形式。
    // 这一步很关键：用户系统里本来就有 127.0.0.1 / 10/8 / 192.168/16 / 172.16/12 / *.local，
    // 交给 CURLOPT_NOPROXY 后，局域网 Navidrome/Emby/UPnP 一律直连，不会被代理吞掉。
    CFTypeRef ex = ::CFDictionaryGetValue(dict, kSCPropNetProxiesExceptionsList);
    if (ex && ::CFGetTypeID(ex) == ::CFArrayGetTypeID()) {
        CFArrayRef arr = (CFArrayRef)ex;
        const CFIndex n = ::CFArrayGetCount(arr);
        for (CFIndex i = 0; i < n; ++i) {
            CFTypeRef it = ::CFArrayGetValueAtIndex(arr, i);
            if (!it || ::CFGetTypeID(it) != ::CFStringGetTypeID()) continue;
            char buf[512] = {0};
            if (!::CFStringGetCString((CFStringRef)it, buf, sizeof(buf) - 1, kCFStringEncodingUTF8)) continue;
            if (!s.exceptions.empty()) s.exceptions += ",";
            s.exceptions += buf;
        }
    }

    ::CFRelease(dict);
    return s;
}

} // namespace detail

// 公开探测入口（供测试与诊断打印本机实际代理；纯只读，无副作用）
inline SystemProxySettings system_proxy_snapshot() { return detail::read_system_proxy(); }

inline HttpResult http_request(const HttpRequest& req) {
    HttpResult r;
    if (!detail::curl_global_ready()) { r.error = "libcurl 初始化失败"; return r; }

    CURL* curl = ::curl_easy_init();
    if (!curl) { r.error = "创建 HTTP 句柄失败"; return r; }

    detail::CurlSink sink;
    sink.body = &r.body;

    const bool isPost = (req.method == "POST");
    const std::string url = req.url;   // curl 自己处理 URL 编码，不再过 percent_encode_path

    ::curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    ::curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);          // 与 WinHTTP 默认一致
    ::curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);                // 多线程下必须
    ::curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, (long)req.timeoutMs);
    ::curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, (long)req.timeoutMs);
    ::curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, detail::curl_write_cb);
    ::curl_easy_setopt(curl, CURLOPT_WRITEDATA, &sink);
    ::curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, detail::curl_header_cb);
    ::curl_easy_setopt(curl, CURLOPT_HEADERDATA, &sink);
    ::curl_easy_setopt(curl, CURLOPT_USERAGENT, "RLPlayer/1.0");
    ::curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");         // 自动解压

    // 代理（2026-10-26）：**有代理走代理，没代理直连**
    //   ① req.proxy 显式给了 ⟹ 用它（rlplayer-llm.conf 的 proxy= 优先级最高，行为不变）
    //   ② 否则问系统代理；系统开着就自动用，没开就是空串 ⟹ 直连
    // 注意：只在这里读一次，不缓存 —— 用户中途开关代理应立即生效，代价是一次
    // CFDictionary 查询（微秒级，远小于任何网络请求）。
    const std::string hp = normalize_proxy(req.proxy);
    if (!hp.empty()) {
        ::curl_easy_setopt(curl, CURLOPT_PROXY, hp.c_str());
        if (!req.noProxy.empty()) ::curl_easy_setopt(curl, CURLOPT_NOPROXY, req.noProxy.c_str());
    } else {
        const SystemProxySettings sys = detail::read_system_proxy();
        const std::string autoProxy = pick_proxy_for_url(sys, url);
        if (!autoProxy.empty()) {
            ::curl_easy_setopt(curl, CURLOPT_PROXY, autoProxy.c_str());
            if (!sys.exceptions.empty())
                ::curl_easy_setopt(curl, CURLOPT_NOPROXY, sys.exceptions.c_str());
        }
        // autoProxy 为空 ⟹ 什么都不设 ⟹ libcurl 直连（改造前的行为）
    }

    // 请求头
    struct curl_slist* headers = nullptr;
    if (isPost && !req.contentType.empty())
        headers = ::curl_slist_append(headers, (std::string("Content-Type: ") + req.contentType).c_str());
    for (const auto& h : req.headers) headers = ::curl_slist_append(headers, h.c_str());
    if (headers) ::curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);

    if (isPost) {
        ::curl_easy_setopt(curl, CURLOPT_POST, 1L);
        ::curl_easy_setopt(curl, CURLOPT_POSTFIELDS, req.body.data());
        ::curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)req.body.size());
    }

    const CURLcode rc = ::curl_easy_perform(curl);

    if (rc != CURLE_OK) {
        // 与 Windows 侧"请求失败"文案对齐，但带上 curl 的具体原因（§7 纪律：文案要可诊断）
        r.error = std::string("请求失败: ") + ::curl_easy_strerror(rc);
        r.status = 0;
        r.ok = false;
        if (headers) ::curl_slist_free_all(headers);
        ::curl_easy_cleanup(curl);
        return r;
    }

    long code = 0;
    ::curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &code);
    r.status = (int)code;
    r.contentType = sink.contentType;

    if (headers) ::curl_slist_free_all(headers);
    ::curl_easy_cleanup(curl);

    r.ok = (r.status >= 200 && r.status < 300);
    if (!r.ok && r.error.empty()) r.error = "HTTP " + std::to_string(r.status);
    return r;
}

} // namespace rta::platform
