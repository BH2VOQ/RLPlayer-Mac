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
#include <cstring>
#include <string>
#include <vector>

#include <curl/curl.h>

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

} // namespace detail

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

    // 代理：归一化后 "host:port"
    const std::string hp = normalize_proxy(req.proxy);
    if (!hp.empty()) ::curl_easy_setopt(curl, CURLOPT_PROXY, hp.c_str());

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
