// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// webui.h — 极简本地 HTTP 控制面（状态查询 + 配置下发）
//
// 设计取舍：
//   * 阻塞式 accept 循环跑在后台线程，**每条连接再交给独立工作线程** ——
//     旧版把 handle() 直接放在 accept 循环里同步跑，一个慢请求（专辑聚合 / 端点探活 /
//     资料检索）会把后面所有请求排住：前端 400ms 一次的 /api/status 一起卡住，
//     用户看到的就是「Failed to fetch」+「点播放几分钟才出声」。见 2026-10-25 修复说明。
//   * 只监听 127.0.0.1（默认）—— 控制面不该默认暴露到网络
//   * API 用 JSON，界面用一个自包含 HTML（无外部资源）
//   * 显式声明 UTF-8，避免中文乱码
#pragma once
// 跨平台 socket 薄层（2026-10-25 mac 移植）：winsock 与 BSD socket 的差异收敛在
// 类型/关闭/初始化三点；语义（阻塞 accept 循环、SO_REUSEADDR、回环监听）完全一致。
// ⚠️ POSIX 的 stop()：close() 不保证唤醒阻塞中的 accept（Linux/mac 均无此承诺），
//    必须先 shutdown(SHUT_RDWR) 让 accept 返回错误，再 close + join，否则退出挂死。
// ⚠️ 并发化之后 stop() 还多一层要求：正在跑 handler 的连接线程必须能被唤醒并等它收尾，
//    否则 stop() 返回后 handler 还在访问已析构的 WebUi / 业务单例 = 悬垂线程。
//    做法：① shutdown 每条活跃连接（阻塞中的 recv/send 立刻返回）；
//         ② 等工作线程全部摘表退出。工作线程只持有 shared_ptr 的连接表 + handler 副本，
//            不持有 this —— 即使线程比对象活得久也不会踩到已析构成员。
  #include <sys/socket.h>
  #include <sys/types.h>
  #include <netinet/in.h>
  #include <unistd.h>
  using socket_t = int;
  #define RL_SOCK_INVALID (-1)
  inline int   sock_close(socket_t s) { return ::close(s); }
  inline void  sock_shutdown(socket_t s) { ::shutdown(s, SHUT_RDWR); }
  inline bool  sock_init() { return true; }
  inline void  sock_cleanup() {}
  using socklen_t_ = socklen_t;
#include <string>
#include <functional>
#include <thread>
#include <atomic>
#include <mutex>
#include <condition_variable>
#include <map>
#include <memory>
#include <sstream>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cctype>

namespace rta::net {

struct HttpRequest {
    std::string method, path, body;
    std::string host;     // Host 头（DNS rebinding 校验用；空 = 客户端没发，按不通过处理）
};

class WebUi {
public:
    using Handler = std::function<std::string(const HttpRequest&, std::string& contentType)>;
    ~WebUi() { stop(); }
    bool start(uint16_t port, Handler h, bool loopbackOnly = true);
    uint16_t port() const { return port_; }
    void stop();

    // 同时在线连接数上限：控制面只在本地回环，正常只有「界面轮询 + 几个一次性请求」。
    // 上限的意义是别让异常客户端把线程数堆爆；超限的连接直接关掉（前端会重试）。
    static constexpr size_t kMaxConnections = 64;

private:
    // 活跃连接表：单独放堆上、由 shared_ptr 持有，工作线程捕获它而不是 this。
    struct ConnTable {
        std::mutex mtx;
        std::condition_variable cv;
        std::map<unsigned long long, socket_t> conns;   // id → socket（正在跑 handler）
        unsigned long long next = 1;
    };
    void loop();
    static std::string trim(std::string s) {
        while (!s.empty() && (s.back() == '\r' || s.back() == '\n' || s.back() == ' ')) s.pop_back();
        size_t i = 0; while (i < s.size() && s[i] == ' ') ++i;
        return s.substr(i);
    }
    // 单连接处理：只依赖 socket + handler 副本，与 WebUi 对象无关（可在任意线程跑）
    static void handle(socket_t c, const Handler& h, bool lan, const std::string& allowedHost);
    socket_t listen_ = RL_SOCK_INVALID;
    uint16_t port_ = 0;
    std::atomic<bool> stop_{true};
    std::thread thread_;
    std::shared_ptr<Handler> handler_;
    std::shared_ptr<ConnTable> conns_;
    bool cleaned_ = false;
    bool lan_ = false;
    std::string allowedHost_;
};

// 慢客户端超时：500ms 对一个本机控制面绰绰有余。
static constexpr int kRecvTimeoutMs = 500;
// 上限：URL 超过 64KB 返回 431，body 超过 16MB 返回 413
static constexpr size_t kMaxHeadBytes = 64 * 1024;     // 请求行 + 头（含 URL）
static constexpr size_t kMaxBodyBytes = 16 * 1024 * 1024;

// 2026-10-26（debug/20261026-02 B-5）：**/api/upload 必须单独放宽** ——
// 拖一首无损进队列（30~200 MB 的 FLAC/DSD）走的就是这条上传通道；16 MB 的全局上限
// 会让它直接失败，而且客户端拿到的是**断连**而不是可读的 413（服务端在读 body 之前
// 就 fail 早退，客户端还在写，于是 send 侧看到 EPIPE）⟹ 前端 dropFiles 连准确提示
// 都给不出。
// ★ 刻意**不**把 kMaxBodyBytes 调大：那会让所有端点（/api/add、/api/settings …）
//   都能收 2 GB，是实打实的安全退化。上限必须**按路径**给。
// ★ 前缀匹配的坑（上游 1df66ac 的教训）：这里只认 "/api/upload"，且要求前缀后紧跟
//   '/'、'?' 或串尾，否则 "/api/uploads" 之类的兄弟端点会被顺带放宽。
//   （mac 现有路径里没有 /api/upload* 的兄弟端点，但口径必须先立住，见 B-6。）
static constexpr size_t kMaxUploadBytes = (size_t)2 * 1024 * 1024 * 1024;   // 2 GB（上游口径）

// 某条请求路径的 body 上限：只有上传端点放宽，其余一律 16 MB。
// 单独抽成 inline 函数是为了让「Content-Length 预检」与「413 文案」两处用**同一个**
// 判定（两处各写一遍前缀匹配，迟早会漂移）。
inline size_t webui_body_cap_for(const std::string& path) {
    static constexpr const char* kUpload = "/api/upload";
    const size_t n = std::strlen(kUpload);
    if (path.compare(0, n, kUpload) == 0) {
        // 整段命中：串尾、或后面紧跟 / ? &（不能把 /api/uploads 也吃进来）
        if (path.size() == n) return kMaxUploadBytes;
        const char c = path[n];
        if (c == '/' || c == '?' || c == '&') return kMaxUploadBytes;
    }
    return kMaxBodyBytes;
}

inline std::string http_status_text(int code) {
    switch (code) {
        case 200: return "OK";
        case 400: return "Bad Request";
        case 403: return "Forbidden";
        case 405: return "Method Not Allowed";
        case 413: return "Payload Too Large";
        case 431: return "Request Header Fields Too Large";
        case 500: return "Internal Server Error";
        default:  return "OK";
    }
}

// HTTP 头名大小写不敏感匹配（ASCII 大小写折叠，RFC 7230 §3.2）
inline bool webui_header_is(const std::string& name, const char* expected) {
    if (!expected) return false;
    size_t i = 0;
    for (; i < name.size(); ++i) {
        if (expected[i] == '\0') return false;
        if (std::tolower((unsigned char)name[i]) != std::tolower((unsigned char)expected[i])) {
            return false;
        }
    }
    return expected[i] == '\0';
}

// Host 头是否属于本机（allowedHost 是逗号分隔的白名单：127.0.0.1,<port>,localhost,<port>,<计算机名>）
inline bool webui_host_allowed_impl(const std::string& host, const std::string& allowed) {
    std::string h = host;
    for (auto& ch : h) ch = (char)std::tolower((unsigned char)ch);
    // 去掉端口（IPv6 的 [::1]:port 这里不做支持：控制面只绑 IPv4）
    const size_t colon = h.find(':');
    if (colon != std::string::npos) h = h.substr(0, colon);
    if (h.empty()) return false;
    std::istringstream is(allowed);
    std::string tok;
    while (std::getline(is, tok, ',')) {
        std::string t = tok;
        for (auto& ch : t) ch = (char)std::tolower((unsigned char)ch);
        if (!t.empty() && t == h) return true;
    }
    return false;
}

// handler 想把状态行写成 405/4xx 时调它（默认一律 200）。
// 用 inline 函数 + 函数内 static（C++11 起线程安全初始化）比暴露 extern WebUi* 更省心。
inline std::atomic<int>* webui_status_slot() {
    static std::atomic<int> s{200};
    return &s;
}
inline void webui_set_status(int code) { webui_status_slot()->store(code); }

inline bool WebUi::start(uint16_t port, Handler h, bool loopbackOnly) {
    handler_ = std::make_shared<Handler>(std::move(h));
    conns_ = std::make_shared<ConnTable>();
    cleaned_ = false;
    lan_ = !loopbackOnly;
    if (!sock_init()) return false;
    listen_ = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listen_ == RL_SOCK_INVALID) return false;
    int yes = 1;
    ::setsockopt(listen_, SOL_SOCKET, SO_REUSEADDR, (const char*)&yes, sizeof(yes));
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = loopbackOnly ? htonl(INADDR_LOOPBACK) : htonl(INADDR_ANY);
    if (::bind(listen_, (sockaddr*)&a, sizeof(a)) != 0) { sock_close(listen_); listen_ = RL_SOCK_INVALID; return false; }
    // backlog 8 → 64：并发化后同一瞬间可能有多条连接在三次握手，backlog 太小会被内核丢掉，
    // 客户端看到的就是 connection reset —— 正好是这次要消掉的「Failed to fetch」。
    if (::listen(listen_, 64) != 0) { sock_close(listen_); listen_ = RL_SOCK_INVALID; return false; }
    sockaddr_in got{}; socklen_t_ gl = sizeof(got);
    ::getsockname(listen_, (sockaddr*)&got, &gl);
    port_ = ntohs(got.sin_port);
    // Host 白名单（--lan 时的最小防线，见 handle() 的注释）
    allowedHost_ = "127.0.0.1," + std::to_string((unsigned)port_) +
                   ",localhost," + std::to_string((unsigned)port_);
    {
        char nb[256] = {0};
        if (::gethostname(nb, sizeof(nb)) == 0 && nb[0] != '\0') {
            allowedHost_ += std::string(",") + nb;
        }
    }
    stop_.store(false);
    thread_ = std::thread([this] { loop(); });
    return true;
}

inline void WebUi::stop() {
    stop_.store(true);
    if (listen_ != RL_SOCK_INVALID) { sock_shutdown(listen_); sock_close(listen_); listen_ = RL_SOCK_INVALID; }
    if (thread_.joinable()) thread_.join();   // accept 循环退出（shutdown 已把它唤醒）
    // 再把正在跑 handler 的连接一并唤醒并等它们收尾。
    //   * 先 shutdown 每条连接 —— 卡在 recv/send 的工作线程立刻返回，不用等 TCP 超时；
    //   * 再等表清空 —— 之后不会有线程访问已析构的成员。
    // socket 的 close 由工作线程自己做，这里只 shutdown，避免 fd 被复用后误关。
    if (conns_) {
        {
            std::unique_lock<std::mutex> lk(conns_->mtx);
            for (auto& kv : conns_->conns) sock_shutdown(kv.second);
            conns_->cv.wait(lk, [this] { return conns_->conns.empty(); });
        }
        conns_.reset();
    }
    if (!cleaned_) { cleaned_ = true; sock_cleanup(); }
}

inline void WebUi::loop() {
    while (!stop_.load()) {
        socket_t c = ::accept(listen_, nullptr, nullptr);
        if (c == RL_SOCK_INVALID) { if (stop_.load()) break; continue; }
        std::shared_ptr<ConnTable> tbl = conns_;      // 线程里只捕获它（不捕获 this）
        std::shared_ptr<Handler> h = handler_;
        if (!tbl || !h) { sock_close(c); continue; }
        unsigned long long id = 0;
        {
            std::lock_guard<std::mutex> lk(tbl->mtx);
            if (tbl->conns.size() >= kMaxConnections) {
                // 超限：不排队、不阻塞 accept，直接关掉这条（前端会重试）。
                sock_close(c);
                continue;
            }
            id = tbl->next++;
            tbl->conns[id] = c;
        }
        bool lan = lan_;
        std::string allowedHost = allowedHost_;
        // detached：连接自己跑完自己退出，accept 线程绝不等待单个请求。
        // 生命周期由「工作线程只持有 shared_ptr + stop() 的 shutdown/等空表」兜住。
        std::thread([tbl, h, c, id, lan, allowedHost] {
            struct Guard {                          // RAII：任何路径（含 handler 抛异常）都摘表 + 关 fd
                std::shared_ptr<ConnTable> tbl; socket_t c; unsigned long long id;
                ~Guard() {
                    sock_close(c);                  // 本线程关，accept 线程不再持有它
                    {
                        std::lock_guard<std::mutex> lk(tbl->mtx);
                        tbl->conns.erase(id);
                        tbl->cv.notify_all();       // 锁内通知：stop() 不可能在通知返回前就往下走
                    }
                }
            } guard{tbl, c, id};
            try {
                handle(c, *h, lan, allowedHost);
            } catch (...) {
                // handler 抛异常不能让进程退出（旧版没有兜底：一次异常 = 整个服务消失）。
                // 吞掉并正常关连接：前端这次请求失败，后续请求照常。
            }
        }).detach();
    }
}

inline void WebUi::handle(socket_t c, const Handler& h, bool lan, const std::string& allowedHost) {
    int status = 200;
    std::string ctype = "application/json; charset=utf-8";
    std::string payload;

    // 统一的"早退"出口：任何解析失败都必须回一个带状态行的 JSON，而不是静默关连接
    auto fail = [&](int code, const std::string& msg) {
        status = code;
        ctype = "application/json; charset=utf-8";
        payload = std::string("{\"ok\":false,\"error\":\"") + msg + "\"}";
    };

    {
        struct timeval tv;
        tv.tv_sec = kRecvTimeoutMs / 1000;
        tv.tv_usec = (kRecvTimeoutMs % 1000) * 1000;
        ::setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        struct timeval stv;
        stv.tv_sec = 5;
        stv.tv_usec = 0;
        ::setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &stv, sizeof(stv));
    }

    std::string buf; char tmp[4096];
    bool tooBig = false;
    auto findHead = [&]() {
        size_t e = buf.find("\r\n\r\n");
        if (e != std::string::npos) return e;
        e = buf.find("\n\n");           // 宽容：有的脚本只发 \n
        return e;
    };
    size_t hdrEnd = std::string::npos;
    while ((hdrEnd = findHead()) == std::string::npos) {
        if (buf.size() > kMaxHeadBytes) { tooBig = true; break; }
        const int r = ::recv(c, tmp, sizeof(tmp), 0);
        if (r <= 0) break;
        buf.append(tmp, (size_t)r);
    }
    if (tooBig) {
        fail(431, "请求头过大（>64KB）：URL 或头部超限");
    } else if (hdrEnd == std::string::npos) {
        fail(400, "请求头不完整（超时 500ms 或客户端提前关闭）");
    } else {
        const size_t sep = (buf.compare(hdrEnd, 4, "\r\n\r\n") == 0) ? 4 : 2;
        const std::string head = buf.substr(0, hdrEnd);
        std::string body = buf.substr(hdrEnd + sep);

        HttpRequest req;
        {
            std::istringstream is(head); std::string line;
            std::getline(is, line);
            if (!line.empty() && line.back() == '\r') line.pop_back();
            std::istringstream ls(trim(line));
            ls >> req.method >> req.path;
        }
        // ---- Host 头（DNS rebinding 的最小防线）----
        {
            std::istringstream hs(head); std::string line; bool first = true;
            while (std::getline(hs, line)) {
                if (first) { first = false; continue; }
                if (!line.empty() && line.back() == '\r') line.pop_back();
                const size_t colon = line.find(':');
                if (colon == std::string::npos) continue;
                if (webui_header_is(trim(line.substr(0, colon)), "Host")) { req.host = trim(line.substr(colon + 1)); break; }
            }
        }
        // ---- Expect: 100-continue ----
        // 2026-10-26（debug/20261026-02 实测发现的既有缺陷，不是本轮引入）：
        //   curl / Invoke-WebRequest 对 >1MB 的请求体默认带 `Expect: 100-continue`，然后**先等
        //   服务器回 `100 Continue`（等 1s）再发 body**。本服务器从不回这个状态行，于是它空等
        //   1s；而下面的 body 读循环用 SO_RCVTIMEO=500ms（kRecvTimeoutMs），**先超时**，读到 0
        //   字节 ⟹ 稳定回 400「请求体不完整」。
        //   实测（同一份 40MB 文件）：
        //     curl --data-binary（默认 Expect）  → 400
        //     curl -H "Expect:"（不发 Expect）   → 200，落盘 41943040 字节逐字节一致
        //   基线二进制在 2MB/8MB 上就已经 400，只是以前上限 16MB、大文件本来就过不去，没人注意。
        //   现在 /api/upload 放宽到 2GB，这条路**必须**通，否则命令行/脚本上传全废（浏览器不
        //   发 Expect，所以 UI 拖拽一直是好的 —— 这正是它一直没被发现的原因）。
        //   修法：解析到 Expect: 100-continue 且确有 body 要收时，先回一个空的 `100 Continue`。
        //   注意必须是「整行 HTTP/1.1 100 Continue\r\n\r\n」，且必须在读 body **之前**发。
        bool wants100 = false;
        {
            std::istringstream hs(head); std::string line; bool first = true;
            while (std::getline(hs, line)) {
                if (first) { first = false; continue; }
                if (!line.empty() && line.back() == '\r') line.pop_back();
                const size_t colon = line.find(':');
                if (colon == std::string::npos) continue;
                if (!webui_header_is(trim(line.substr(0, colon)), "Expect")) continue;
                std::string v;
                for (char ch : line.substr(colon + 1)) v.push_back((char)std::tolower((unsigned char)ch));
                if (v.find("100-continue") != std::string::npos) wants100 = true;
                break;
            }
        }
        // ---- Content-Length：先判上限再分配 ----
        size_t want = 0;
        bool clBad = false;
        {
            std::istringstream hs(head); std::string line; bool first = true;
            while (std::getline(hs, line)) {
                if (first) { first = false; continue; }
                if (!line.empty() && line.back() == '\r') line.pop_back();
                const size_t colon = line.find(':');
                if (colon == std::string::npos) continue;
                if (!webui_header_is(trim(line.substr(0, colon)), "Content-Length")) continue;
                const std::string v = trim(line.substr(colon + 1));
                if (v.empty() || v.find_first_not_of("0123456789") != std::string::npos) { clBad = true; break; }
                want = (size_t)strtoull(v.c_str(), nullptr, 10);
                // 按路径取上限（见 webui_body_cap_for 注释）：/api/upload 2GB，其余 16MB
                if (want > webui_body_cap_for(req.path)) { clBad = true; break; }
            }
        }
        if (req.method.empty() || req.path.empty()) {
            fail(400, "请求行无法解析");
        } else if (clBad && want > webui_body_cap_for(req.path)) {
            // 文案必须区分两条路径：用户看到「上限 16MB」却在上传 40MB 的歌，会去查错地方
            fail(413, webui_body_cap_for(req.path) > kMaxBodyBytes
                        ? "请求体过大（上传上限 2GB）"
                        : "请求体过大（上限 16MB）");
        } else if (clBad) {
            fail(400, "Content-Length 非法");
        } else if (lan && !webui_host_allowed_impl(req.host, allowedHost)) {
            // ---- Host 白名单 ----
            // --lan 会把控制面绑到 0.0.0.0 且没有鉴权，一个恶意网页可以让受害者浏览器去
            // http://<公网域名指向 127.0.0.1>/api/... 做副作用请求（DNS rebinding）。最小防线：
            // Host 必须是我们自己的名字/地址之一。curl/PowerShell 默认都带 Host，本机 UI 也不受影响。
            fail(403, "Host 不被允许：--lan 只接受 127.0.0.1 / localhost / 本机名");
        } else {
            // 客户端在等 `100 Continue` 才肯发 body（见上方 Expect 注释）：先把状态行发出去，
            // 否则它会空等 1s、我们先超时。只在**确有 body** 要收时发（want==0 时客户端不会等）。
            if (wants100 && want > 0) {
                static const char kContinue[] = "HTTP/1.1 100 Continue\r\n\r\n";
                size_t csent = 0;
                while (csent < sizeof(kContinue) - 1) {
                    const int n = ::send(c, kContinue + csent, (int)(sizeof(kContinue) - 1 - csent), 0);
                    if (n <= 0) break;              // 对端已关：下面的读循环自然会读到 0 并回 400
                    csent += (size_t)n;
                }
            }
            while (body.size() < want) {
                const int r = ::recv(c, tmp, sizeof(tmp), 0);
                if (r <= 0) break;
                body.append(tmp, (size_t)r);
            }
            if (body.size() < want) {
                fail(400, "请求体不完整（Content-Length 与实际收到的字节不符）");
            } else {
                body.resize(want);
                req.body.swap(body);
                webui_status_slot()->store(200);      // 每次请求前复位（handler 可能提前 return）
                payload = h ? h(req, ctype) : std::string("{}");
                status = webui_status_slot()->exchange(200);
            }
        }
    }

    std::ostringstream resp;
    resp << "HTTP/1.1 " << status << " " << http_status_text(status) << "\r\n"
         << "Content-Type: " << ctype << "\r\n"
         << "Content-Length: " << payload.size() << "\r\n"
         << "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
         << payload;
    const std::string s = resp.str();
    // 整包发送：send() 可能只写出一部分（大响应 + 并发时发送缓冲更容易满）。
    // 保持主库现状循环写完。
    size_t sent = 0;
    while (sent < s.size()) {
        const int n = ::send(c, s.c_str() + sent, (int)(s.size() - sent), 0);
        if (n <= 0) break;                       // 对端已关（stop() 的 shutdown 也会走到这里）
        sent += (size_t)n;
    }
}

// 内置最小控制页面（自包含；内联脚本里的模板占位符已转义，避免与生成代码冲突）
inline std::string default_page() {
    return std::string(R"HTML(<!doctype html><html lang="zh"><head><meta charset="utf-8">
<title>RLPlayer 控制台</title><style>
body{font-family:system-ui,Segoe UI,sans-serif;background:#14161a;color:#e6e6e6;margin:0;padding:24px}
h1{font-size:18px;font-weight:600;margin:0 0 16px}
.card{background:#1d2026;border:1px solid #2b2f37;border-radius:10px;padding:16px;margin-bottom:14px}
table{border-collapse:collapse;width:100%;font-size:13px}
td{padding:5px 10px;border-bottom:1px solid #2b2f37}
td:first-child{color:#8b93a1;width:200px}
pre{background:#101216;padding:10px;border-radius:6px;overflow:auto;font-size:12px}
</style></head><body>
<h1>RLPlayer 控制台</h1>
<div class="card"><table id="st"></table></div>
<div class="card"><b>原始状态</b><pre id="raw">加载中…</pre></div>
<script>
async function tick(){
  try{
    const r = await fetch('/api/status'); const j = await r.json();
    const rows = [];
    for (const kv of Object.entries(j.status||{})) rows.push('<tr><td>'+kv[0]+'</td><td>'+kv[1]+'</td></tr>');
    document.getElementById('st').innerHTML = rows.join('');
    document.getElementById('raw').textContent = JSON.stringify(j, null, 2);
  }catch(e){ document.getElementById('raw').textContent = '无法连接: '+e; }
}
tick(); setInterval(tick, 1000);
</script></body></html>)HTML");
}

} // namespace rta::net
