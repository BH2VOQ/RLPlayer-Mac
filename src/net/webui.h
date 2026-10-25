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

namespace rta::net {

struct HttpRequest { std::string method, path, body; };

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
    static void handle(socket_t c, const Handler& h);
    socket_t listen_ = RL_SOCK_INVALID;
    uint16_t port_ = 0;
    std::atomic<bool> stop_{true};
    std::thread thread_;
    std::shared_ptr<Handler> handler_;
    std::shared_ptr<ConnTable> conns_;
    bool cleaned_ = false;
};

inline bool WebUi::start(uint16_t port, Handler h, bool loopbackOnly) {
    handler_ = std::make_shared<Handler>(std::move(h));
    conns_ = std::make_shared<ConnTable>();
    cleaned_ = false;
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
        // detached：连接自己跑完自己退出，accept 线程绝不等待单个请求。
        // 生命周期由「工作线程只持有 shared_ptr + stop() 的 shutdown/等空表」兜住。
        std::thread([tbl, h, c, id] {
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
                handle(c, *h);
            } catch (...) {
                // handler 抛异常不能让进程退出（旧版没有兜底：一次异常 = 整个服务消失）。
                // 吞掉并正常关连接：前端这次请求失败，后续请求照常。
            }
        }).detach();
    }
}

inline void WebUi::handle(socket_t c, const Handler& h) {
    std::string buf; char tmp[4096];
    while (buf.find("\r\n\r\n") == std::string::npos && buf.size() < 65536) {
        const int r = ::recv(c, tmp, sizeof(tmp), 0);
        if (r <= 0) break;
        buf.append(tmp, (size_t)r);
    }
    const size_t hdrEnd = buf.find("\r\n\r\n");
    if (hdrEnd == std::string::npos) return;
    const std::string head = buf.substr(0, hdrEnd);
    std::string body = buf.substr(hdrEnd + 4);

    HttpRequest req;
    {
        std::istringstream is(head); std::string line;
        std::getline(is, line);
        std::istringstream ls(trim(line));
        ls >> req.method >> req.path;
    }
    size_t p = head.find("Content-Length:");
    if (p == std::string::npos) p = head.find("content-length:");
    if (p != std::string::npos) {
        const size_t n = (size_t)atoi(head.c_str() + p + 15);
        while (body.size() < n) {
            const int r = ::recv(c, tmp, sizeof(tmp), 0);
            if (r <= 0) break;
            body.append(tmp, (size_t)r);
        }
    }
    req.body = body;

    std::string ctype = "application/json; charset=utf-8";
    std::string payload = h ? h(req, ctype) : std::string("{}");

    std::ostringstream resp;
    resp << "HTTP/1.1 200 OK\r\n"
         << "Content-Type: " << ctype << "\r\n"
         << "Content-Length: " << payload.size() << "\r\n"
         << "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
         << payload;
    const std::string s = resp.str();
    // 整包发送：send() 可能只写出一部分（大响应 + 并发时发送缓冲更容易满）。
    // 旧版单线程几乎不触发；并发后必须循环写完，否则前端拿到半截 JSON。
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
