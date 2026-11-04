// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_raop_session.cpp — AirPlay (RAOP) RTSP/RTP 会话层测试 (1.1.2)
//
// 测试原则（针对历史“假通过”的整改）：
//   * 只连 127.0.0.1 的临时端口假服务端，绝不连真实接收端、绝不打开音频设备；
//   * 线格式由测试自己独立解码（不调用被测代码的解析器），避免“编码与解码同时错”互相抵消；
//   * 断言内容而不只是“收到包”：sync 字段语义、timing 应答字段、NACK 重传必须逐字节相同；
//   * 所有可能阻塞的路径都有时限断言（不许挂死）。
//
// 假服务端并发模型（修掉旧夹具的 accept/close 竞态）：
//   * 监听 socket 非阻塞 + poll(20ms)，stop 时不从别的线程 close 正在 accept 的 fd；
//   * 每条连接由自己的线程持有 fd，线程只用自己的 poll 判断退出，stop 只置标志后 join；
//   * 任何线程都不会去 close 另一个线程正在 recv 的 fd。

#include "audio/alac_encoder.h"
#include "net/raop_session.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <limits>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

namespace {

int g_fail = 0;
int g_pass = 0;

void ck(bool cond, const char* what, const std::string& detail = std::string()) {
    if (cond) {
        std::printf("  [PASS] %s\n", what);
        ++g_pass;
    } else {
        std::printf("  [FAIL] %s  %s\n", what, detail.c_str());
        ++g_fail;
    }
}

void section(const char* name) { std::printf("\n-- %s\n", name); }

// 计数由其它线程异步 +1，断言前要等它到点，而不是“刚发完就比相等”。
template <typename Fn>
bool wait_until(Fn fn, int timeoutMs = 800) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
    while (std::chrono::steady_clock::now() < deadline) {
        if (fn()) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(3));
    }
    return fn();
}

// ── 测试自己的字节读写（与被测代码的实现无关）──────────────────────────────
uint16_t rd16(const uint8_t* p) { return static_cast<uint16_t>((p[0] << 8) | p[1]); }
uint32_t rd32(const uint8_t* p) {
    return (static_cast<uint32_t>(p[0]) << 24) | (static_cast<uint32_t>(p[1]) << 16) |
           (static_cast<uint32_t>(p[2]) << 8) | static_cast<uint32_t>(p[3]);
}
uint64_t rd64(const uint8_t* p) { return (static_cast<uint64_t>(rd32(p)) << 32) | rd32(p + 4); }
void wr16(uint8_t* p, uint16_t v) { p[0] = static_cast<uint8_t>(v >> 8); p[1] = static_cast<uint8_t>(v & 0xFF); }
void wr64(uint8_t* p, uint64_t v) {
    for (int i = 0; i < 8; ++i) p[i] = static_cast<uint8_t>((v >> (56 - 8 * i)) & 0xFF);
}

int64_t ms_between(std::chrono::steady_clock::time_point a, std::chrono::steady_clock::time_point b) {
    return std::chrono::duration_cast<std::chrono::milliseconds>(b - a).count();
}

std::string trim(std::string s) {
    size_t a = 0, b = s.size();
    while (a < b && (s[a] == ' ' || s[a] == '\t' || s[a] == '\r' || s[a] == '\n')) ++a;
    while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\r' || s[b - 1] == '\n')) --b;
    return s.substr(a, b - a);
}

std::string lower(std::string s) {
    for (char& c : s) {
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    }
    return s;
}

struct RtspRequest {
    std::string method;
    std::string uri;
    std::vector<std::pair<std::string, std::string>> headers;
    std::string body;

    std::string header(const std::string& name) const {
        const std::string want = lower(name);
        for (const auto& h : headers) {
            if (lower(h.first) == want) return h.second;
        }
        return std::string();
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 假 RAOP 接收端（只监听 127.0.0.1 的临时端口）
// ─────────────────────────────────────────────────────────────────────────────
struct FakeReceiver {
    // 配置旋钮
    int announceStatus = 200;
    std::string announceStatusText = "Forbidden";
    int announce453Times = 0;                   // 前 N 次 ANNOUNCE 回 453
    bool hangOnOptions = false;                 // 永不应答 OPTIONS
    bool hangOnTeardown = false;                // 永不应答 TEARDOWN
    bool interleavedTcp = false;                // SETUP 回 RTP/AVP/TCP
    bool echoInterleaved = true;                // UDP 回包也带 interleaved=0-1（真机行为）
    bool injectInterleavedBeforeSetup = false;  // SETUP 响应前插一个 0x24 帧
    bool dropConnectionAfterRecord = false;     // RECORD 应答后立刻断开 RTSP 连接（SIGPIPE 场景）
    int audioLatencyHeader = 11025;

    // 记录
    mutable std::mutex mtx;
    std::vector<RtspRequest> requests;
    std::vector<std::vector<uint8_t>> audioPackets;
    std::vector<std::vector<uint8_t>> controlPackets;
    std::vector<std::vector<uint8_t>> tcpChannel0;
    std::vector<std::vector<uint8_t>> tcpChannel1;
    int otherInterleavedChannels = 0;
    int connections = 0;
    int announceCount = 0;

    uint16_t tcpPort = 0;
    uint16_t audioPort = 0;
    uint16_t controlPort = 0;
    uint16_t timingPort = 0;

    bool start() {
        listenFd_ = ::socket(AF_INET, SOCK_STREAM, 0);
        if (listenFd_ < 0) return false;
        int one = 1;
        ::setsockopt(listenFd_, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        struct sockaddr_in a {};
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        a.sin_port = 0;
        if (::bind(listenFd_, reinterpret_cast<struct sockaddr*>(&a), sizeof(a)) < 0) return false;
        socklen_t al = sizeof(a);
        if (::getsockname(listenFd_, reinterpret_cast<struct sockaddr*>(&a), &al) != 0) return false;
        tcpPort = ntohs(a.sin_port);
        if (::listen(listenFd_, 8) < 0) return false;
        const int flags = ::fcntl(listenFd_, F_GETFL, 0);
        ::fcntl(listenFd_, F_SETFL, flags | O_NONBLOCK);

        audioFd_ = bind_udp(audioPort);
        controlFd_ = bind_udp(controlPort);
        timingFd_ = bind_udp(timingPort);
        if (audioFd_ < 0 || controlFd_ < 0 || timingFd_ < 0) return false;

        struct timeval tv {};
        tv.tv_sec = 0;
        tv.tv_usec = 500000;
        ::setsockopt(timingFd_, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        acceptThread_ = std::thread([this]() { accept_loop(); });
        udpThread_ = std::thread([this]() { udp_loop(); });
        return true;
    }

    void stop() {
        stop_.store(true);
        if (acceptThread_.joinable()) acceptThread_.join();
        {
            std::lock_guard<std::mutex> lk(connMtx_);
            for (auto& t : connThreads_) {
                if (t.joinable()) t.join();
            }
            connThreads_.clear();
        }
        if (udpThread_.joinable()) udpThread_.join();
        if (listenFd_ >= 0) { ::close(listenFd_); listenFd_ = -1; }
        if (audioFd_ >= 0) { ::close(audioFd_); audioFd_ = -1; }
        if (controlFd_ >= 0) { ::close(controlFd_); controlFd_ = -1; }
        if (timingFd_ >= 0) { ::close(timingFd_); timingFd_ = -1; }
    }

    ~FakeReceiver() { stop(); }

    bool wait_audio_packets(size_t n, int timeoutMs = 1500) {
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
        while (std::chrono::steady_clock::now() < deadline) {
            {
                std::lock_guard<std::mutex> lk(mtx);
                if (audioPackets.size() >= n) return true;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(3));
        }
        std::lock_guard<std::mutex> lk(mtx);
        return audioPackets.size() >= n;
    }

    bool wait_tcp_channel(size_t channel, size_t n, int timeoutMs = 1500) {
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
        while (std::chrono::steady_clock::now() < deadline) {
            {
                std::lock_guard<std::mutex> lk(mtx);
                const auto& v = (channel == 0) ? tcpChannel0 : tcpChannel1;
                if (v.size() >= n) return true;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(3));
        }
        return false;
    }

    // 等音频包数量稳定（用于“不应该再有任何包”的否定断言）
    void wait_audio_quiet(int quietMs = 250, int maxWaitMs = 1500) {
        const auto start = std::chrono::steady_clock::now();
        size_t last = 0;
        auto lastChange = start;
        for (;;) {
            size_t now = 0;
            {
                std::lock_guard<std::mutex> lk(mtx);
                now = audioPackets.size();
            }
            const auto t = std::chrono::steady_clock::now();
            if (now != last) {
                last = now;
                lastChange = t;
            }
            if (ms_between(lastChange, t) >= quietMs) return;
            if (ms_between(start, t) >= maxWaitMs) return;
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
    }

    size_t audio_count() const {
        std::lock_guard<std::mutex> lk(mtx);
        return audioPackets.size();
    }

    std::vector<std::vector<uint8_t>> audio_snapshot() const {
        std::lock_guard<std::mutex> lk(mtx);
        return audioPackets;
    }

    std::vector<RtspRequest> request_snapshot() const {
        std::lock_guard<std::mutex> lk(mtx);
        return requests;
    }

    int count_method(const std::string& m) const {
        std::lock_guard<std::mutex> lk(mtx);
        int n = 0;
        for (const auto& r : requests) {
            if (r.method == m) ++n;
        }
        return n;
    }

    // 从 SETUP 请求的 Transport 里取出会话本地端口（走真实握手，无测试钩子）
    bool session_ports(uint16_t& localControl, uint16_t& localTiming) const {
        std::lock_guard<std::mutex> lk(mtx);
        for (const auto& r : requests) {
            if (r.method != "SETUP") continue;
            const std::string t = r.header("Transport");
            const std::string keyC = "control_port=";
            const std::string keyT = "timing_port=";
            const size_t pc = t.find(keyC);
            const size_t pt = t.find(keyT);
            if (pc == std::string::npos || pt == std::string::npos) return false;
            localControl = static_cast<uint16_t>(std::atoi(t.c_str() + pc + keyC.size()));
            localTiming = static_cast<uint16_t>(std::atoi(t.c_str() + pt + keyT.size()));
            return localControl != 0 && localTiming != 0;
        }
        return false;
    }

    std::string last_announce_uri() const {
        std::lock_guard<std::mutex> lk(mtx);
        std::string uri;
        for (const auto& r : requests) {
            if (r.method == "ANNOUNCE") uri = r.uri;
        }
        return uri;
    }

    // 最近一次 RECORD（重开会话时用；record_rtp_info 取第一个）
    bool last_record_rtp_info(uint16_t& seq, uint32_t& rtptime) const {
        std::lock_guard<std::mutex> lk(mtx);
        bool found = false;
        for (const auto& r : requests) {
            if (r.method != "RECORD") continue;
            const std::string v = r.header("RTP-Info");
            const size_t ps = v.find("seq=");
            const size_t pt = v.find("rtptime=");
            if (ps == std::string::npos || pt == std::string::npos) continue;
            seq = static_cast<uint16_t>(std::atoi(v.c_str() + ps + 4));
            rtptime = static_cast<uint32_t>(std::strtoul(v.c_str() + pt + 8, nullptr, 10));
            found = true;
        }
        return found;
    }

    bool record_rtp_info(uint16_t& seq, uint32_t& rtptime) const {
        std::lock_guard<std::mutex> lk(mtx);
        for (const auto& r : requests) {
            if (r.method != "RECORD") continue;
            const std::string v = r.header("RTP-Info");
            const size_t ps = v.find("seq=");
            const size_t pt = v.find("rtptime=");
            if (ps == std::string::npos || pt == std::string::npos) return false;
            seq = static_cast<uint16_t>(std::atoi(v.c_str() + ps + 4));
            rtptime = static_cast<uint32_t>(std::strtoul(v.c_str() + pt + 8, nullptr, 10));
            return true;
        }
        return false;
    }

    bool send_nack(uint16_t localControlPort, uint16_t first, uint16_t count, uint8_t type = 0xD5) {
        uint8_t pkt[8];
        pkt[0] = 0x80;
        pkt[1] = type;
        wr16(pkt + 2, 1);
        wr16(pkt + 4, first);
        wr16(pkt + 6, count);
        struct sockaddr_in to {};
        to.sin_family = AF_INET;
        to.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        to.sin_port = htons(localControlPort);
        const ssize_t n = ::sendto(controlFd_, pkt, sizeof(pkt), 0,
                                   reinterpret_cast<struct sockaddr*>(&to), sizeof(to));
        return n == static_cast<ssize_t>(sizeof(pkt));
    }

    bool send_raw_control(uint16_t localControlPort, const uint8_t* data, size_t len) {
        struct sockaddr_in to {};
        to.sin_family = AF_INET;
        to.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        to.sin_port = htons(localControlPort);
        const ssize_t n = ::sendto(controlFd_, data, len, 0,
                                   reinterpret_cast<struct sockaddr*>(&to), sizeof(to));
        return n == static_cast<ssize_t>(len);
    }

    // 从一个**临时 UDP 端口**发 NACK：源端口不是 SETUP 里公布的 audio/control/timing，
    // 用于验证来源校验会拒绝它（真实接收端是从自己的 control socket 发的）。
    bool send_nack_from_ephemeral_port(uint16_t localControlPort, uint16_t first, uint16_t count) {
        const int fd = ::socket(AF_INET, SOCK_DGRAM, 0);
        if (fd < 0) return false;
        struct sockaddr_in bindAddr {};
        bindAddr.sin_family = AF_INET;
        bindAddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        bindAddr.sin_port = 0;
        if (::bind(fd, reinterpret_cast<struct sockaddr*>(&bindAddr), sizeof(bindAddr)) < 0) {
            ::close(fd);
            return false;
        }
        uint8_t pkt[8];
        pkt[0] = 0x80;
        pkt[1] = 0xD5;
        wr16(pkt + 2, 9);
        wr16(pkt + 4, first);
        wr16(pkt + 6, count);
        struct sockaddr_in to {};
        to.sin_family = AF_INET;
        to.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        to.sin_port = htons(localControlPort);
        const ssize_t n = ::sendto(fd, pkt, sizeof(pkt), 0,
                                   reinterpret_cast<struct sockaddr*>(&to), sizeof(to));
        ::close(fd);
        return n == static_cast<ssize_t>(sizeof(pkt));
    }

    // control 端口上按类型筛选的包（0xD4 = sync，0xD6 = 重传应答，0xD5 = 对端 NACK 请求）
    std::vector<std::vector<uint8_t>> control_by_type(uint8_t type) const {
        std::lock_guard<std::mutex> lk(mtx);
        std::vector<std::vector<uint8_t>> out;
        for (const auto& p : controlPackets) {
            if (p.size() >= 2 && p[1] == type) out.push_back(p);
        }
        return out;
    }

    size_t control_count_type(uint8_t type) const { return control_by_type(type).size(); }

    bool wait_control_type(uint8_t type, size_t n, int timeoutMs = 1500) {
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
        while (std::chrono::steady_clock::now() < deadline) {
            if (control_count_type(type) >= n) return true;
            std::this_thread::sleep_for(std::chrono::milliseconds(3));
        }
        return control_count_type(type) >= n;
    }

    // 最近一次某方法的 RTSP 请求（用于检查 FLUSH 的 RTP-Info 等）
    bool last_request(const std::string& method, RtspRequest& out) const {
        std::lock_guard<std::mutex> lk(mtx);
        bool found = false;
        for (const auto& r : requests) {
            if (r.method == method) {
                out = r;
                found = true;
            }
        }
        return found;
    }

    bool timing_exchange(uint16_t localTimingPort, const uint8_t req[32], std::vector<uint8_t>& reply,
                         int timeoutMs = 800) {
        struct sockaddr_in to {};
        to.sin_family = AF_INET;
        to.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        to.sin_port = htons(localTimingPort);
        if (::sendto(timingFd_, req, 32, 0, reinterpret_cast<struct sockaddr*>(&to), sizeof(to)) != 32) {
            return false;
        }
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
        for (;;) {
            const auto now = std::chrono::steady_clock::now();
            if (now >= deadline) return false;
            const auto remain =
                std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count();
            struct pollfd pfd {};
            pfd.fd = timingFd_;
            pfd.events = POLLIN;
            const int prc = ::poll(&pfd, 1, static_cast<int>(std::max<int64_t>(1, remain)));
            if (prc <= 0) continue;
            uint8_t buf[128];
            const ssize_t n = ::recv(timingFd_, buf, sizeof(buf), 0);
            if (n <= 0) continue;
            reply.assign(buf, buf + n);
            return true;
        }
    }

private:
    static int bind_udp(uint16_t& port) {
        const int fd = ::socket(AF_INET, SOCK_DGRAM, 0);
        if (fd < 0) return -1;
        struct sockaddr_in u {};
        u.sin_family = AF_INET;
        u.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        u.sin_port = 0;
        if (::bind(fd, reinterpret_cast<struct sockaddr*>(&u), sizeof(u)) < 0) {
            ::close(fd);
            return -1;
        }
        socklen_t ul = sizeof(u);
        if (::getsockname(fd, reinterpret_cast<struct sockaddr*>(&u), &ul) != 0) {
            ::close(fd);
            return -1;
        }
        port = ntohs(u.sin_port);
        return fd;
    }

    void accept_loop() {
        while (!stop_.load()) {
            struct pollfd pfd {};
            pfd.fd = listenFd_;
            pfd.events = POLLIN;
            const int prc = ::poll(&pfd, 1, 20);
            if (prc <= 0) continue;
            struct sockaddr_in ca {};
            socklen_t cl = sizeof(ca);
            const int cfd = ::accept(listenFd_, reinterpret_cast<struct sockaddr*>(&ca), &cl);
            if (cfd < 0) continue;
            {
                std::lock_guard<std::mutex> lk(mtx);
                ++connections;
            }
            std::lock_guard<std::mutex> lk(connMtx_);
            connThreads_.emplace_back([this, cfd]() { serve_connection(cfd); });
        }
    }

    void udp_loop() {
        while (!stop_.load()) {
            struct pollfd pfds[2] {};
            pfds[0].fd = audioFd_;
            pfds[0].events = POLLIN;
            pfds[1].fd = controlFd_;
            pfds[1].events = POLLIN;
            const int prc = ::poll(pfds, 2, 20);
            if (prc <= 0) continue;
            for (int i = 0; i < 2; ++i) {
                if ((pfds[i].revents & POLLIN) == 0) continue;
                uint8_t buf[4096];
                // 一次把该 socket 上排队的都取完，避免 200+ 包的突发把内核缓冲挤爆
                for (int burst = 0; burst < 512; ++burst) {
                    const ssize_t n = ::recv(pfds[i].fd, buf, sizeof(buf), MSG_DONTWAIT);
                    if (n <= 0) break;
                    std::lock_guard<std::mutex> lk(mtx);
                    if (i == 0) audioPackets.emplace_back(buf, buf + n);
                    else controlPackets.emplace_back(buf, buf + n);
                }
            }
        }
    }

    void serve_connection(int fd) {
        std::string buffer;
        while (!stop_.load()) {
            struct pollfd pfd {};
            pfd.fd = fd;
            pfd.events = POLLIN;
            const int prc = ::poll(&pfd, 1, 20);
            if (prc == 0) continue;
            if (prc < 0) break;
            char tmp[4096];
            const ssize_t n = ::recv(fd, tmp, sizeof(tmp), 0);
            if (n <= 0) break;
            buffer.append(tmp, static_cast<size_t>(n));

            bool progress = true;
            while (progress) {
                progress = false;
                if (!buffer.empty() && static_cast<uint8_t>(buffer[0]) == 0x24) {
                    if (buffer.size() < 4) break;
                    const size_t len = (static_cast<size_t>(static_cast<uint8_t>(buffer[2])) << 8) |
                                       static_cast<uint8_t>(buffer[3]);
                    if (buffer.size() < 4 + len) break;
                    const uint8_t ch = static_cast<uint8_t>(buffer[1]);
                    const std::vector<uint8_t> payload(buffer.begin() + 4,
                                                       buffer.begin() + 4 + static_cast<long>(len));
                    {
                        std::lock_guard<std::mutex> lk(mtx);
                        if (ch == 0) tcpChannel0.push_back(payload);
                        else if (ch == 1) tcpChannel1.push_back(payload);
                        else ++otherInterleavedChannels;
                    }
                    buffer.erase(0, 4 + len);
                    progress = true;
                    continue;
                }
                const size_t headerEnd = buffer.find("\r\n\r\n");
                if (headerEnd == std::string::npos) {
                    if (buffer.size() > 64 * 1024) break;   // 夹具同样有界
                    break;
                }
                RtspRequest req;
                size_t contentLength = 0;
                {
                    const std::string head = buffer.substr(0, headerEnd);
                    size_t pos = 0;
                    bool firstLine = true;
                    while (pos <= head.size()) {
                        size_t nl = head.find('\n', pos);
                        if (nl == std::string::npos) nl = head.size();
                        std::string line = head.substr(pos, nl - pos);
                        pos = nl + 1;
                        if (!line.empty() && line.back() == '\r') line.pop_back();
                        if (line.empty()) continue;
                        if (firstLine) {
                            firstLine = false;
                            std::istringstream ls(line);
                            std::string ver;
                            ls >> req.method >> req.uri >> ver;
                            continue;
                        }
                        const size_t colon = line.find(':');
                        if (colon == std::string::npos) continue;
                        const std::string k = trim(line.substr(0, colon));
                        const std::string v = trim(line.substr(colon + 1));
                        req.headers.push_back({k, v});
                        if (lower(k) == "content-length") {
                            contentLength = static_cast<size_t>(std::strtoul(v.c_str(), nullptr, 10));
                        }
                    }
                }
                if (contentLength > 1024 * 1024) break;
                if (buffer.size() < headerEnd + 4 + contentLength) break;
                req.body = buffer.substr(headerEnd + 4, contentLength);
                buffer.erase(0, headerEnd + 4 + contentLength);
                if (!handle_request(fd, req)) {
                    ::shutdown(fd, SHUT_RDWR);
                    ::close(fd);
                    return;
                }
                progress = true;
            }
        }
        ::shutdown(fd, SHUT_RDWR);
        ::close(fd);
    }

    void send_all_on(int fd, const std::string& s) {
        size_t off = 0;
        while (off < s.size()) {
            const ssize_t n = ::send(fd, s.data() + off, s.size() - off, 0);
            if (n <= 0) return;
            off += static_cast<size_t>(n);
        }
    }

    // 返回 false 表示这条连接必须立刻断开（用于模拟接收端中途消失）
    bool handle_request(int fd, const RtspRequest& req) {
        const int cseq = std::atoi(req.header("CSeq").c_str());
        int seenAnnounce = 0;
        {
            std::lock_guard<std::mutex> lk(mtx);
            requests.push_back(req);
            if (req.method == "ANNOUNCE") seenAnnounce = ++announceCount;
        }

        if (req.method == "OPTIONS" && hangOnOptions) return true;     // 故意不回
        if (req.method == "TEARDOWN" && hangOnTeardown) return true;   // 故意不回

        std::ostringstream resp;
        auto ok = [&](const std::string& extra = std::string()) {
            resp << "RTSP/1.0 200 OK\r\nCSeq: " << cseq << "\r\n" << extra << "\r\n";
        };

        if (req.method == "OPTIONS") {
            ok("Public: OPTIONS, ANNOUNCE, SETUP, RECORD, TEARDOWN, FLUSH, SET_PARAMETER\r\n");
        } else if (req.method == "ANNOUNCE") {
            if (announce453Times > 0 && seenAnnounce <= announce453Times) {
                resp << "RTSP/1.0 453 Not Enough Bandwidth\r\nCSeq: " << cseq << "\r\n\r\n";
            } else if (announceStatus != 200) {
                resp << "RTSP/1.0 " << announceStatus << " " << announceStatusText
                     << "\r\nCSeq: " << cseq << "\r\n\r\n";
            } else {
                ok();
            }
        } else if (req.method == "SETUP") {
            if (injectInterleavedBeforeSetup) {
                uint8_t frame[9] = {0x24, 0x07, 0x00, 0x05, 'J', 'U', 'N', 'K', '!'};
                send_all_on(fd, std::string(reinterpret_cast<char*>(frame), sizeof(frame)));
            }
            std::ostringstream tr;
            if (interleavedTcp) {
                tr << "RTP/AVP/TCP;unicast;interleaved=0-1;mode=record";
            } else {
                tr << "RTP/AVP/UDP;unicast;";
                if (echoInterleaved) tr << "interleaved=0-1;";
                tr << "mode=record;server_port=" << audioPort
                   << ";control_port=" << controlPort
                   << ";timing_port=" << timingPort;
            }
            std::ostringstream extra;
            extra << "Session: 12345678\r\nTransport: " << tr.str() << "\r\n";
            ok(extra.str());
        } else if (req.method == "RECORD") {
            std::ostringstream extra;
            extra << "Session: 12345678\r\n";
            if (audioLatencyHeader > 0) extra << "Audio-Latency: " << audioLatencyHeader << "\r\n";
            ok(extra.str());
        } else if (req.method == "FLUSH" || req.method == "TEARDOWN" || req.method == "SET_PARAMETER") {
            ok("Session: 12345678\r\n");
        } else {
            ok();
        }
        send_all_on(fd, resp.str());
        if (req.method == "RECORD" && dropConnectionAfterRecord) return false;
        return true;
    }

    int listenFd_ = -1;
    int audioFd_ = -1;
    int controlFd_ = -1;
    int timingFd_ = -1;
    std::atomic<bool> stop_{false};
    std::thread acceptThread_;
    std::thread udpThread_;
    std::vector<std::thread> connThreads_;
    std::mutex connMtx_;
};

rta::net::RaopConfig loopback_cfg(const FakeReceiver& srv) {
    rta::net::RaopConfig cfg;
    cfg.host = "127.0.0.1";
    cfg.port = srv.tcpPort;
    cfg.sampleRate = 44100;
    cfg.channels = 2;
    cfg.bits = 16;
    cfg.prebufferSeconds = 0.02;   // 测试要快：时间轴几乎立即开始
    cfg.rtspTimeoutMs = 800;
    return cfg;
}

std::vector<int16_t> make_pcm(size_t frames, size_t channels, int16_t base) {
    std::vector<int16_t> pcm(frames * channels);
    for (size_t i = 0; i < frames; ++i) {
        const int16_t v = static_cast<int16_t>(base + static_cast<int16_t>(i % 251));
        for (size_t c = 0; c < channels; ++c) pcm[i * channels + c] = v;
    }
    return pcm;
}

// ─────────────────────────────────────────────────────────────────────────────
// 纯函数：线格式
// ─────────────────────────────────────────────────────────────────────────────
void test_protocol_codec() {
    section("protocol codec (pure)");
    using namespace rta::net::raop;

    uint8_t b[8] = {0};
    put_be16(b, 0x1234);
    put_be32(b + 2, 0xDEADBEEF);
    ck(rd16(b) == 0x1234 && rd32(b + 2) == 0xDEADBEEF, "be16/be32 round-trip");
    uint8_t w[8] = {0};
    put_be64(w, 0x0123456789ABCDEFull);
    ck(rd64(w) == 0x0123456789ABCDEFull, "be64 round-trip");
    ck(get_be16(w) == 0x0123 && get_be32(w + 4) == 0x89ABCDEF, "be64 splits into two be32");

    ck(ntp_from_unix_ns(0) == (kNtpUnixEpochOffset << 32), "NTP epoch conversion");
    ck(ntp_from_unix_ns(1000000000ull) == ((kNtpUnixEpochOffset + 1) << 32), "NTP +1s exact");
    ck(ntp_from_unix_ns(500000000ull) == ((kNtpUnixEpochOffset << 32) | 0x80000000ull),
       "NTP half-second fraction");
    ck(ntp_delta_ns((kNtpUnixEpochOffset + 2) << 32, kNtpUnixEpochOffset << 32) == 2000000000ll,
       "ntp_delta_ns positive");
    ck(ntp_delta_ns(kNtpUnixEpochOffset << 32, (kNtpUnixEpochOffset + 2) << 32) == -2000000000ll,
       "ntp_delta_ns negative");

    ck(frames_for_elapsed_ns(1000000000ull, 44100) == 44100, "1 s @44100 = 44100 frames");
    ck(frames_for_elapsed_ns(2500000000ull, 44100) == 110250, "2.5 s @44100 = 110250 frames");
    ck(frames_for_elapsed_ns(999ull, 44100) == 0, "sub-frame elapsed truncates to 0");
    ck(frames_for_elapsed_ns(1000ull, 44100) == 0, "1 us @44100 is still below one frame");
    ck(frames_for_elapsed_ns(1000000ull, 44100) == 44, "1 ms @44100 = 44 frames");
    ck(frames_for_elapsed_ns(1000000000ull, 0) == 0, "zero rate safe");

    // sync 包：参考实现的字节布局（测试独立断言，不靠被测解析器自证）
    SyncFields f;
    f.current_rtp = 1000000;
    f.latency_frames = 88200;
    f.ntp = 0x0000000A00000000ull;
    const std::vector<uint8_t> p = build_sync_packet(f);
    ck(p.size() == 20, "sync packet is 20 bytes");
    ck(p[0] == 0x80 && p[1] == 0xD4, "sync leader/type 0x80/0xD4");
    ck(rd16(p.data() + 2) == 4, "sync flags = 4 (AirPlay)");
    ck(rd32(p.data() + 4) == 1000000u - 88200u, "sync [4..7] = current - latency");
    ck(rd64(p.data() + 8) == 0x0000000A00000000ull, "sync [8..15] = NTP");
    ck(rd32(p.data() + 16) == 1000000u, "sync [16..19] = current RTP");
    ck(rd32(p.data() + 4) != rd32(p.data() + 16), "sync [4..7] != [16..19] when latency > 0");

    SyncFields wrap;
    wrap.current_rtp = 10;
    wrap.latency_frames = 100;
    const std::vector<uint8_t> pw = build_sync_packet(wrap);
    ck(rd32(pw.data() + 4) == static_cast<uint32_t>(10u - 100u), "sync delayed wraps modulo 2^32");

    // timing
    uint8_t tq[32] = {0};
    tq[0] = 0x80;
    tq[1] = 0xD2;
    tq[2] = 0x12;
    tq[3] = 0x34;
    put_be64(tq + 8, 0x1111111111111111ull);
    put_be64(tq + 16, 0x2222222222222222ull);
    put_be64(tq + 24, 0x3333333333333333ull);
    TimingRequest tr;
    ck(parse_timing_request(tq, 32, tr) && tr.seq == 0x1234, "timing request parse seq");
    ck(tr.origin == 0x1111111111111111ull && tr.receive == 0x2222222222222222ull &&
           tr.transmit == 0x3333333333333333ull,
       "timing request parse three timestamps");
    ck(!parse_timing_request(tq, 31, tr), "timing request rejects short packet");
    uint8_t wrongType[32] = {0};
    wrongType[0] = 0x80;
    wrongType[1] = 0xD4;
    ck(!parse_timing_request(wrongType, 32, tr), "timing request rejects wrong type");
    ck(!tr.valid && tr.seq == 0, "failed parse leaves the out-param cleared (valid=false)");
    // 负例会把 out-param 清空：重新解析，让后面的应答断言基于真实请求
    ck(parse_timing_request(tq, 32, tr) && tr.seq == 0x1234 && tr.transmit == 0x3333333333333333ull,
       "timing request re-parses for the reply assertions");

    const std::vector<uint8_t> reply = build_timing_reply(tr, 0xAAAAAAAAAAAAAAAAull, 0xBBBBBBBBBBBBBBBBull);
    ck(reply.size() == 32 && reply[0] == 0x80 && reply[1] == 0xD3, "timing reply 32B 0x80/0xD3");
    ck(rd16(reply.data() + 2) == 0x1234, "timing reply echoes request seq");
    ck(rd64(reply.data() + 8) == 0x3333333333333333ull,
       "timing reply origin = request TRANSMIT (NTP semantics)");
    ck(rd64(reply.data() + 16) == 0xAAAAAAAAAAAAAAAAull, "timing reply receive field");
    ck(rd64(reply.data() + 24) == 0xBBBBBBBBBBBBBBBBull, "timing reply transmit field");

    TimingRequest noTransmit;
    noTransmit.valid = true;
    noTransmit.seq = 1;
    noTransmit.origin = 0x0102030405060708ull;
    const std::vector<uint8_t> reply2 = build_timing_reply(noTransmit, 1, 2);
    ck(rd64(reply2.data() + 8) == 0x0102030405060708ull,
       "timing reply falls back to request origin when transmit is 0");

    // NACK
    uint8_t nk[8] = {0x80, 0xD5, 0x00, 0x01, 0xAB, 0xCD, 0x00, 0x02};
    NackRequest nr;
    ck(parse_nack(nk, 8, nr) && nr.first == 0xABCD && nr.count == 2, "NACK parse first/count");
    nk[1] = 0x55;
    ck(parse_nack(nk, 8, nr) && nr.first == 0xABCD, "NACK accepts bare 0x55 (no leader bit)");
    ck(!parse_nack(nk, 7, nr), "NACK rejects short packet");
    uint8_t nk0[8] = {0x80, 0xD5, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00};
    ck(!parse_nack(nk0, 8, nr), "NACK rejects count=0");
    uint8_t nkBig[8] = {0x80, 0xD5, 0x00, 0x01, 0x00, 0x02, 0x10, 0x00};
    ck(parse_nack(nkBig, 8, nr) && nr.count == kMaxNackCount, "NACK count clamped to bound");
    uint8_t nkWrap[8] = {0x80, 0xD5, 0x00, 0x01, 0xFF, 0xFF, 0x00, 0x03};
    ck(parse_nack(nkWrap, 8, nr) && nr.first == 0xFFFF, "NACK parse seq 0xFFFF (wrap start)");

    // Transport
    TransportInfo ti;
    std::string terr;
    ck(parse_transport("RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;server_port=6000;"
                       "control_port=6001;timing_port=6002",
                       ti, &terr),
       "transport UDP parse", terr);
    ck(!ti.interleaved && ti.server_port == 6000 && ti.control_port == 6001 && ti.timing_port == 6002,
       "transport UDP: echoed interleaved= does NOT mean TCP");
    ck(parse_transport("RTP/AVP/TCP;unicast;interleaved=0-1;mode=record", ti, &terr),
       "transport TCP parse", terr);
    ck(ti.interleaved && ti.server_port == 0, "transport TCP: interleaved, no server_port");
    ck(parse_transport("RTP/AVP/UDP;unicast;server_port=6000-6001;timing_port=6002", ti, &terr),
       "transport range parse", terr);
    ck(ti.server_port == 6000 && ti.control_port == 6001 && ti.timing_port == 6002,
       "transport server_port=a-b -> audio=a control=b");
    ck(parse_transport("RTP/AVP/UDP;Unicast;Server_Port=7000;Mode=record", ti, &terr),
       "transport case-insensitive keys", terr);
    ck(ti.server_port == 7000 && ti.control_port == 7001 && ti.timing_port == 7002,
       "transport derives control/timing when absent");
    ck(!parse_transport("RTP/AVP/UDP;unicast;server_port=0", ti, &terr), "transport rejects port 0");
    ck(!parse_transport("RTP/AVP/UDP;unicast;server_port=70000", ti, &terr), "transport rejects port >65535");
    ck(!parse_transport("RTP/AVP/UDP;unicast;server_port=60x0", ti, &terr), "transport rejects junk port");
    ck(!parse_transport("RTP/AVP/UDP;unicast;server_port=7000-6999", ti, &terr),
       "transport rejects reversed range");
    ck(!parse_transport("RTP/AVP/UDP;unicast", ti, &terr), "transport rejects missing server_port");
    ck(!parse_transport("", ti, &terr), "transport rejects empty header");

    // RTP 头
    uint8_t rtp[12] = {0};
    put_rtp_header(rtp, 0x1234, 0xDEADBEEFu, 0x01020304u);
    RtpHeader rh;
    ck(parse_rtp_header(rtp, 12, rh) && rh.valid, "rtp header parses");
    ck(rh.sequence == 0x1234 && rh.timestamp == 0xDEADBEEFu && rh.ssrc == 0x01020304u &&
           rh.payload_type == 96 && !rh.marker,
       "rtp header fields");
    uint8_t badVersion[12] = {0x40, 0x60, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    ck(!parse_rtp_header(badVersion, 12, rh), "rtp header rejects V=1");

    // 重传应答 0xD6：4 字节头 + 完整原 RTP 头 + 原载荷（逐字节，独立于被测实现核对）
    {
        const uint8_t payload[5] = {0x11, 0x22, 0x33, 0x44, 0x55};
        const std::vector<uint8_t> r = build_resend_packet(0xBEEF, 0x0BADF00Du, 0x01020304u,
                                                           payload, sizeof(payload));
        ck(r.size() == 4 + 12 + sizeof(payload), "resend packet length = 4 + RTP header + payload",
           std::to_string(r.size()));
        ck(r[0] == 0x80 && r[1] == 0xD6, "resend leader/type 0x80/0xD6");
        ck(rd16(r.data() + 2) == 0xBEEF, "resend header carries the sequence");
        ck(rd16(r.data() + 6) == 0xBEEF, "inner RTP seq == original seq");
        ck(rd32(r.data() + 8) == 0x0BADF00Du, "inner RTP timestamp == original timestamp");
        ck(rd32(r.data() + 12) == 0x01020304u, "inner RTP ssrc preserved");
        ck(r[4] == 0x80 && r[5] == 0x60, "inner RTP header V=2 PT=96 (0x60)");
        ck(std::memcmp(r.data() + 16, payload, sizeof(payload)) == 0,
           "inner ALAC payload is bit-exact");
    }

    // RTSP 响应解析：有界 + 增量
    RtspResponse resp;
    size_t consumed = 0;
    std::string perr;
    const std::string okResp =
        "RTSP/1.0 200 OK\r\nCSeq: 7\r\nSession: ABCD;timeout=60\r\n"
        "Transport: RTP/AVP/UDP;server_port=6000\r\nAudio-Latency: 11025\r\nContent-Length: 5\r\n\r\nHELLO";
    ck(parse_rtsp_response(okResp, resp, consumed, &perr) == ParseState::Complete,
       "rtsp response complete", perr);
    ck(consumed == okResp.size(), "rtsp response consumed all bytes");
    ck(resp.status_code == 200 && resp.cseq == 7 && resp.session == "ABCD", "rtsp status/cseq/session");
    ck(resp.transport == "RTP/AVP/UDP;server_port=6000" && resp.audio_latency == "11025",
       "rtsp transport + Audio-Latency headers");
    ck(resp.body == "HELLO", "rtsp body by Content-Length");

    ck(parse_rtsp_response(okResp.substr(0, 20), resp, consumed, &perr) == ParseState::NeedMore,
       "rtsp response partial -> NeedMore");

    std::string hugeHeader = "RTSP/1.0 200 OK\r\n";
    while (hugeHeader.size() < 20000) hugeHeader += "X-Pad: 0123456789012345678901234567890123456789\r\n";
    ck(parse_rtsp_response(hugeHeader, resp, consumed, &perr) == ParseState::Error,
       "rtsp oversized header rejected");

    const std::string hugeBody = "RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: 999999999\r\n\r\n";
    ck(parse_rtsp_response(hugeBody, resp, consumed, &perr) == ParseState::Error,
       "rtsp oversized Content-Length rejected");

    ck(parse_rtsp_response("HTTP/1.1 200 OK\r\nCSeq: 1\r\n\r\n", resp, consumed, &perr) ==
           ParseState::Error,
       "rtsp wrong protocol name rejected");

    ck(parse_rtsp_response("RTSP/1.0 200 OK\r\nCSeq 1\r\n\r\n", resp, consumed, &perr) ==
           ParseState::Error,
       "rtsp header line without colon rejected");

    // 畸形头部字段必须有界拒绝，不能当成 0 或负数继续缓冲/匹配
    ck(parse_rtsp_response("RTSP/1.0 200 OK\r\nContent-Length: -5\r\n\r\n", resp, consumed,
                           &perr) == ParseState::Error,
       "rtsp negative Content-Length rejected");
    ck(parse_rtsp_response("RTSP/1.0 200 OK\r\nContent-Length: 12x\r\n\r\n", resp, consumed,
                           &perr) == ParseState::Error,
       "rtsp non-numeric Content-Length rejected");
    ck(parse_rtsp_response("RTSP/1.0 200 OK\r\nContent-Length: 99999999999999999999\r\n\r\n",
                           resp, consumed, &perr) == ParseState::Error,
       "rtsp overflowed Content-Length rejected");
    ck(parse_rtsp_response("RTSP/1.0 200 OK\r\nCSeq: -1\r\n\r\n", resp, consumed, &perr) ==
           ParseState::Error,
       "rtsp negative CSeq rejected");
    ck(parse_rtsp_response("RTSP/1.0 200 OK\r\nCSeq: 99999999999999\r\n\r\n", resp, consumed,
                           &perr) == ParseState::Error,
       "rtsp overflowed CSeq rejected");
    ck(parse_rtsp_response("RTSP/1.0 200 OK\r\nCSeq: 0x10\r\n\r\n", resp, consumed, &perr) ==
           ParseState::Error,
       "rtsp hex-ish CSeq rejected");

    ck(parse_rtsp_response("RTSP/1.0 200 OK\r\nServer: X\r\n\r\n", resp, consumed, &perr) ==
               ParseState::Complete &&
           resp.cseq == -1,
       "rtsp missing CSeq reports -1 (caller decides)");

    const std::string folded = "RTSP/1.0 200 OK\r\nCSeq: 3\r\nX-Long: abc\r\n  def\r\n\r\n";
    ck(parse_rtsp_response(folded, resp, consumed, &perr) == ParseState::Complete &&
           resp.get_header("X-Long") == "abc def",
       "rtsp folded header continuation");

    // 交织帧跳过
    std::string withFrame;
    withFrame.push_back(0x24);
    withFrame.push_back(0x07);
    withFrame.push_back(0x00);
    withFrame.push_back(0x03);
    withFrame += "abc";
    withFrame += okResp;
    ck(skip_interleaved_frames(withFrame) == InterleavedSkip::Skipped, "interleaved frame skipped");
    ck(withFrame == okResp, "buffer after interleaved skip is the RTSP response");
    std::string partialFrame;
    partialFrame.push_back(0x24);
    partialFrame.push_back(0x01);
    partialFrame.push_back(0x00);
    partialFrame.push_back(0x10);
    partialFrame += "xy";
    ck(skip_interleaved_frames(partialFrame) == InterleavedSkip::NeedMore,
       "partial interleaved frame -> NeedMore");
    std::string hugeFrame;
    hugeFrame.push_back(0x24);
    hugeFrame.push_back(0x01);
    hugeFrame.push_back(0xFF);
    hugeFrame.push_back(0xFF);
    ck(skip_interleaved_frames(hugeFrame) == InterleavedSkip::Invalid,
       "interleaved frame with 64KB length rejected");
}

// ─────────────────────────────────────────────────────────────────────────────
// 纯函数：重传缓存（含序号召回绕）
// ─────────────────────────────────────────────────────────────────────────────
void test_packet_cache() {
    section("retransmit cache (pure)");
    using namespace rta::net::raop;

    RtpPacketCache cache(8);
    std::vector<uint8_t> payload(4, 0xAA);
    cache.store(0xFFFE, 1000, payload.data(), payload.size());
    payload[0] = 0xBB;
    cache.store(0xFFFF, 1352, payload.data(), payload.size());
    payload[0] = 0xCC;
    cache.store(0x0000, 1704, payload.data(), payload.size());   // 回绕
    payload[0] = 0xDD;
    cache.store(0x0001, 2056, payload.data(), payload.size());

    CachedRtpPacket out;
    ck(cache.find(0xFFFE, out) && out.payload.size() == 4 && out.payload[0] == 0xAA,
       "cache finds 0xFFFE across wrap");
    ck(cache.find(0x0000, out) && out.timestamp == 1704 && out.payload[0] == 0xCC,
       "cache finds wrapped sequence 0x0000");
    ck(cache.find(0x0001, out) && out.timestamp == 2056, "cache finds 0x0001");
    ck(!cache.find(0x0002, out), "cache miss for never-stored seq");

    for (uint16_t i = 0; i < 20; ++i) {
        uint8_t bb[3] = {static_cast<uint8_t>(i), 1, 2};
        cache.store(static_cast<uint16_t>(0x1000 + i), static_cast<uint32_t>(i), bb, sizeof(bb));
    }
    ck(cache.size() == 8 && cache.capacity() == 8, "cache bounded at capacity");
    ck(!cache.find(0x1000, out), "evicted old sequence is a miss (never returns wrong packet)");
    ck(cache.find(0x1013, out) && out.payload[0] == 19, "newest sequence present");
    ck(cache.evicted_total() == 16, "eviction counter counts only overflow",
       std::to_string(cache.evicted_total()));

    cache.reset(0);
    ck(cache.size() == 0 && !cache.find(0x1013, out), "reset clears the cache");

    RtpPacketCache tiny(1);
    ck(tiny.capacity() == RtpPacketCache::kMinCapacity, "capacity clamped to minimum");
    RtpPacketCache big(1u << 20);
    ck(big.capacity() == RtpPacketCache::kMaxCapacity, "capacity clamped to maximum");

    // 默认容量必须覆盖一整个暂停窗口（≥ 默认 latency 2 s 的包数，即 88200/352 = 251 包）
    {
        RtpPacketCache def;
        ck(def.capacity() == RtpPacketCache::kDefaultCapacity, "default capacity is the documented one");
        ck(def.capacity() >= 2u * (88200u / 352u), "default capacity covers a full 2 s latency window",
           std::to_string(def.capacity()));
    }

    // 有序快照：暂停恢复重放按发送顺序遍历
    {
        RtpPacketCache c(16);
        for (uint16_t i = 0; i < 5; ++i) {
            uint8_t bb[2] = {static_cast<uint8_t>(0x40 + i), 0};
            c.store(static_cast<uint16_t>(0x2000 + i), 100u + i, bb, sizeof(bb));
        }
        std::vector<CachedRtpPacket> snap;
        c.snapshot_in_order(snap);
        bool ordered = snap.size() == 5;
        for (size_t i = 0; ordered && i < snap.size(); ++i) {
            ordered = snap[i].sequence == static_cast<uint16_t>(0x2000 + i) &&
                      snap[i].timestamp == 100u + static_cast<uint32_t>(i) &&
                      !snap[i].payload.empty() && snap[i].payload[0] == static_cast<uint8_t>(0x40 + i);
        }
        ck(ordered, "snapshot_in_order returns entries in send order", std::to_string(snap.size()));
        ck(c.size() == 5, "snapshot does not disturb the cache");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 预检
// ─────────────────────────────────────────────────────────────────────────────
void test_preflight() {
    section("preflight");
    using namespace rta::net;
    RaopPreflightInput in;
    in.hasPublicKey = true;      // 只说明设备支持 RSA 配对
    RaopPreflightResult r = preflight_raop(in);
    ck(r.ok && !r.requiresEncryption, "pk= alone does NOT block casting");
    ck(!r.note.empty(), "pk= alone produces an explanatory note");

    in.passwordRequired = true;
    r = preflight_raop(in);
    ck(!r.ok && r.requiresPassword && !r.reason.empty(), "password requirement blocks with reason");

    in = RaopPreflightInput{};
    in.explicitEncryptionRequired = true;
    r = preflight_raop(in);
    ck(!r.ok && r.requiresEncryption, "explicit encryption requirement blocks");

    in = RaopPreflightInput{};
    in.receiverNeedsAirPlay2 = true;
    r = preflight_raop(in);
    ck(!r.ok && !r.reasonEn.empty() && !r.reason.empty(),
       "AirPlay2-only receiver blocks (bi-lingual reason)");

    in = RaopPreflightInput{};
    ck(preflight_raop(in).ok, "plain AirPlay1 device passes preflight");
}

// ─────────────────────────────────────────────────────────────────────────────
// 握手 + RTP 线格式 + sync 字段 + timing 应答
// ─────────────────────────────────────────────────────────────────────────────
void test_handshake_and_wire() {
    using namespace rta::net;
    section("handshake, RTP wire, sync fields, timing reply");

    FakeReceiver srv;
    ck(srv.start(), "fake receiver start");
    RaopConfig cfg = loopback_cfg(srv);
    cfg.latencyFrames = 44100;   // 1 s：便于逐位断言 current - latency

    RaopSession session;
    std::string err;
    const bool opened = session.open(cfg, &err);
    ck(opened, "open() succeeds", err);
    if (!opened) return;
    ck(session.is_open(), "is_open() true");
    ck(wait_until([&]() {
           const RaopHealth h = session.health();
           return h.timing_thread && h.control_thread;
       }),
       "health reports both worker threads actually running");

    const std::string summary = session.last_handshake_summary();
    ck(summary.find("OPTIONS 200") != std::string::npos &&
           summary.find("ANNOUNCE 200") != std::string::npos &&
           summary.find("SETUP 200") != std::string::npos &&
           summary.find("RECORD 200") != std::string::npos,
       "handshake summary has all four 200s", summary);

    const auto reqs = srv.request_snapshot();
    ck(reqs.size() >= 4 && reqs[0].method == "OPTIONS" && reqs[1].method == "ANNOUNCE" &&
           reqs[2].method == "SETUP" && reqs[3].method == "RECORD",
       "strict method order OPTIONS/ANNOUNCE/SETUP/RECORD");
    bool cseqOk = reqs.size() >= 4;
    for (size_t i = 0; i < 4 && cseqOk; ++i) cseqOk = reqs[i].header("CSeq") == std::to_string(i + 1);
    ck(cseqOk, "CSeq increments from 1");

    ck(reqs.size() >= 2 && reqs[1].body.find("m=audio 0 RTP/AVP 96") != std::string::npos,
       "SDP m=audio 0 RTP/AVP 96");
    ck(reqs.size() >= 2 && reqs[1].body.find("a=rtpmap:96 AppleLossless") != std::string::npos,
       "SDP rtpmap AppleLossless");
    ck(reqs.size() >= 2 &&
           reqs[1].body.find("a=fmtp:96 352 0 16 40 10 14 2 255 0 0 44100") != std::string::npos,
       "SDP fmtp 352/44100");
    ck(reqs.size() >= 2 && reqs[1].body.find("rsaaeskey") == std::string::npos,
       "SDP has no rsaaeskey when unencrypted");

    const std::string setupTransport = reqs.size() >= 3 ? reqs[2].header("Transport") : "";
    ck(setupTransport.find("mode=record") != std::string::npos, "SETUP has mode=record");
    ck(setupTransport.find("control_port=") != std::string::npos, "SETUP asks for control_port");
    ck(setupTransport.find("timing_port=") != std::string::npos, "SETUP asks for timing_port");
    ck(session.local_rtp_port() > 0, "local RTP port bound");
    ck(session.server_audio_port() == srv.audioPort, "server audio port parsed from Transport");
    ck(session.server_control_port() == srv.controlPort, "server control port parsed");
    ck(session.server_timing_port() == srv.timingPort, "server timing port parsed");
    ck(!session.interleaved(), "echoed interleaved=0-1 does NOT switch to TCP");
    ck(session.device_audio_latency_frames() == 11025, "Audio-Latency header recorded");

    uint16_t recSeq = 0;
    uint32_t recRtptime = 0;
    ck(srv.record_rtp_info(recSeq, recRtptime), "RECORD carries RTP-Info");
    ck(session.anchor_rtp() == recRtptime, "timeline anchor RTP == RECORD rtptime (no off-by-one)");

    // 时间映射：精确值（不靠任何墙钟容差）
    const auto t0 = session.anchor_time();
    const uint32_t base = session.anchor_rtp();
    const raop::SyncFields atStart = session.sync_fields_at(t0, 12345);
    ck(atStart.current_rtp == base, "sync at anchor time: current == anchor rtp");
    ck(atStart.latency_delayed_timestamp() == static_cast<uint32_t>(base - 44100),
       "sync at anchor time: delayed == current - latency");
    const raop::SyncFields at300ms = session.sync_fields_at(t0 + std::chrono::milliseconds(300), 1);
    ck(at300ms.current_rtp == static_cast<uint32_t>(base + 13230),
       "sync at anchor+300ms: +13230 frames exactly (no flat hold)");
    const raop::SyncFields at600ms = session.sync_fields_at(t0 + std::chrono::milliseconds(600), 1);
    ck(at600ms.current_rtp == static_cast<uint32_t>(base + 26460),
       "sync at anchor+600ms: +26460 frames exactly (no hold-then-jump)");
    const raop::SyncFields at1s = session.sync_fields_at(t0 + std::chrono::seconds(1), 1);
    ck(at1s.current_rtp == static_cast<uint32_t>(base + 44100), "sync at anchor+1s: +44100 frames exactly");
    const raop::SyncFields at2500ms = session.sync_fields_at(t0 + std::chrono::milliseconds(2500), 1);
    ck(at2500ms.current_rtp == static_cast<uint32_t>(base + 110250),
       "sync at anchor+2.5s: +110250 frames exactly");
    ck(session.current_rtp_at(t0 - std::chrono::seconds(5)) == base,
       "before anchor: mapping holds at start (no negative wrap)");
    ck(session.current_rtp_at(t0 + std::chrono::hours(1)) ==
           static_cast<uint32_t>(base + 44100u * 3600u),
       "one hour later: strictly linear (no hidden clamp)");

    // 音频
    auto pcm = make_pcm(704, 2, 1000);
    const bool wr = session.write_pcm(pcm.data(), 704, &err);
    ck(wr, "write_pcm(704) succeeds", err);
    ck(session.packets_sent() == 2, "two RTP packets sent");
    ck(srv.wait_audio_packets(2), "receiver got two UDP audio packets");

    const auto pkts = srv.audio_snapshot();
    ck(pkts.size() == 2, "exactly two audio packets (no stray UDP traffic)", std::to_string(pkts.size()));
    if (pkts.size() == 2) {
        const auto& p1 = pkts[0];
        const auto& p2 = pkts[1];
        ck(p1.size() > 12 && p2.size() > 12, "packets carry payload");
        ck(p1[0] == 0x80 && p1[1] == 0x60, "packet 1 V=2 PT=96");
        ck(rd16(p1.data() + 2) == recSeq, "first packet seq == RECORD seq");
        ck(rd32(p1.data() + 4) == recRtptime, "first packet timestamp == RECORD rtptime");
        ck(rd16(p2.data() + 2) == static_cast<uint16_t>(recSeq + 1), "sequence +1");
        ck(rd32(p2.data() + 4) == recRtptime + 352u, "timestamp +352");
        ck(rd32(p1.data() + 8) == rd32(p2.data() + 8) && rd32(p1.data() + 8) != 0,
           "same non-zero SSRC on both packets");
        ck(p1.size() != p2.size() ||
               std::memcmp(p1.data() + 12, p2.data() + 12, p1.size() - 12) != 0,
           "payloads differ (real ALAC encoding, not a fixed stub)");
    }
    {
        std::lock_guard<std::mutex> lk(srv.mtx);
        ck(srv.tcpChannel0.empty() && srv.tcpChannel1.empty() && srv.otherInterleavedChannels == 0,
           "UDP mode: no interleaved frames on the RTSP connection");
    }

    uint16_t localControl = 0, localTiming = 0;
    ck(srv.session_ports(localControl, localTiming), "session local control/timing ports known");

    // sync 包（一）：显式 emit → 用「生成时刻区间」精确夹逼 current_rtp
    auto control_count = [&]() -> size_t {
        std::lock_guard<std::mutex> lk(srv.mtx);
        return srv.controlPackets.size();
    };
    auto control_at = [&](size_t i) -> std::vector<uint8_t> {
        std::lock_guard<std::mutex> lk(srv.mtx);
        return srv.controlPackets[i];
    };
    auto wait_control_count = [&](size_t n, int timeoutMs) -> bool {
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
        while (std::chrono::steady_clock::now() < deadline) {
            if (control_count() >= n) return true;
            std::this_thread::sleep_for(std::chrono::milliseconds(3));
        }
        return control_count() >= n;
    };

    std::vector<uint8_t> explicitSync;
    std::chrono::steady_clock::time_point tb{}, ta{};
    bool gotExplicit = false;
    for (int attempt = 0; attempt < 300 && !gotExplicit; ++attempt) {
        const size_t base = control_count();
        const uint64_t ntpBefore = raop::ntp_now();
        tb = std::chrono::steady_clock::now();
        const bool ok = session.emit_sync_now(&err);
        ta = std::chrono::steady_clock::now();
        const uint64_t ntpAfter = raop::ntp_now();
        if (!ok) {
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
            continue;
        }
        if (!wait_control_count(base + 1, 500)) break;
        // 按包内 NTP 正向识别“这一条是本次 emit 产生的”（避免和周期 sync 混淆）
        for (size_t i = base; i < control_count(); ++i) {
            const std::vector<uint8_t> cand = control_at(i);
            if (cand.size() != 20) continue;
            const uint64_t ntp = rd64(cand.data() + 8);
            if (ntp >= ntpBefore && ntp <= ntpAfter) {
                explicitSync = cand;
                gotExplicit = true;
                break;
            }
        }
    }
    ck(gotExplicit, "emit_sync_now() sends a sync identified by its NTP", err);
    if (gotExplicit) {
        ck(explicitSync[0] == 0x80 && explicitSync[1] == 0xD4, "explicit sync type 0x80/0xD4");
        ck(rd16(explicitSync.data() + 2) == 4, "explicit sync flags 4");
        const uint32_t current = rd32(explicitSync.data() + 16);
        const uint32_t delayed = rd32(explicitSync.data() + 4);
        const uint64_t ntp = rd64(explicitSync.data() + 8);
        ck(static_cast<uint32_t>(current - delayed) == 44100u,
           "wire sync: current - delayed == configured latency (not zero!)",
           std::to_string(static_cast<uint32_t>(current - delayed)));
        ck(delayed != current, "wire sync: the two timestamp fields are NOT identical");
        const uint32_t lo = session.sync_fields_at(tb, ntp).current_rtp;
        const uint32_t hi = session.sync_fields_at(ta, ntp).current_rtp;
        const bool inRange =
            static_cast<int32_t>(lo - current) <= 0 && static_cast<int32_t>(current - hi) <= 0;
        ck(inRange, "wire sync current RTP equals the anchored mapping at the emit instant",
           "cur=" + std::to_string(current) + " lo=" + std::to_string(lo) +
               " hi=" + std::to_string(hi));
        const int64_t ageNs = raop::ntp_delta_ns(raop::ntp_now(), ntp);
        ck(ageNs > -1000000000ll && ageNs < 1000000000ll,
           "wire sync NTP is the sender clock at send time", std::to_string(ageNs));
    }

    // sync 包（二）：周期 sync 的斜率必须 ≈ 采样率（防止夹死/跳变导致的假速率）
    {
        const size_t base = control_count();
        ck(wait_control_count(base + 2, 2000), "two periodic sync packets arrive on control port");
        if (control_count() >= base + 2) {
            const std::vector<uint8_t> s0 = control_at(base);
            const std::vector<uint8_t> s1 = control_at(base + 1);
            ck(s0.size() == 20 && s1.size() == 20, "periodic sync packets are 20 bytes");
            if (s0.size() == 20 && s1.size() == 20) {
                const int32_t dframes = static_cast<int32_t>(rd32(s1.data() + 16) - rd32(s0.data() + 16));
                const int64_t dns = raop::ntp_delta_ns(rd64(s1.data() + 8), rd64(s0.data() + 8));
                ck(dframes > 0 && dns > 0, "sync progression is monotonic",
                   std::to_string(dframes) + " frames / " + std::to_string(dns) + " ns");
                if (dns > 0) {
                    const double rate = static_cast<double>(dframes) * 1e9 / static_cast<double>(dns);
                    ck(std::fabs(rate - 44100.0) < 22.0,   // 500 ppm：斜率健全性
                       "sync progression rate ~= 44100 frames/s", std::to_string(rate));
                }
                ck(static_cast<uint32_t>(rd32(s1.data() + 16) - rd32(s1.data() + 4)) == 44100u &&
                       static_cast<uint32_t>(rd32(s0.data() + 16) - rd32(s0.data() + 4)) == 44100u,
                   "both periodic syncs advertise the configured latency");
            }
        }
    }

    // timing：请求 → 应答字段
    ck(localTiming != 0, "timing port from SETUP usable");
    {
        uint8_t tq[32] = {0};
        tq[0] = 0x80;
        tq[1] = 0xD2;
        wr16(tq + 2, 0x2A);
        const uint64_t reqOrigin = raop::ntp_now();
        const uint64_t reqTransmit = reqOrigin + 100;
        wr64(tq + 8, reqOrigin);        // 请求里也填 origin：应答**不能**回显它
        wr64(tq + 24, reqTransmit);
        std::vector<uint8_t> reply;
        ck(srv.timing_exchange(localTiming, tq, reply), "timing request answered");
        if (reply.size() == 32) {
            ck(reply[0] == 0x80 && reply[1] == 0xD3, "timing reply 0x80/0xD3");
            ck(rd16(reply.data() + 2) == 0x2A, "timing reply echoes seq");
            ck(rd64(reply.data() + 8) == reqTransmit,
               "timing reply origin == request TRANSMIT (not the origin field)");
            ck(rd64(reply.data() + 8) != reqOrigin, "timing reply does NOT echo the origin field");
            ck(rd64(reply.data() + 16) != 0 && rd64(reply.data() + 24) != 0,
               "timing reply has receive/transmit timestamps");
            ck(raop::ntp_delta_ns(rd64(reply.data() + 16), rd64(reply.data() + 24)) <= 0,
               "timing reply receive <= transmit");
            const int64_t replyAge = raop::ntp_delta_ns(raop::ntp_now(), rd64(reply.data() + 24));
            ck(replyAge > -500000000ll && replyAge < 500000000ll, "timing reply transmit is fresh NTP");
        } else {
            ck(false, "timing reply is 32 bytes", std::to_string(reply.size()));
        }
        ck(session.timing_replies() >= 1, "timing reply counter");
    }

    // 音量 / 进度 / FLUSH
    ck(session.set_volume_db(-20.0, &err), "set_volume_db(-20)", err);
    ck(session.set_progress(1000, 2000, &err), "set_progress(1000,2000)", err);
    {
        bool vol = false, prog = false;
        for (const auto& r : srv.request_snapshot()) {
            if (r.method != "SET_PARAMETER") continue;
            if (r.body.find("volume: -20.00") != std::string::npos) vol = true;
            if (r.body.find("progress: 1000/2000") != std::string::npos) prog = true;
        }
        ck(vol, "SET_PARAMETER volume body");
        ck(prog, "SET_PARAMETER progress body");
    }
    session.flush();
    ck(srv.count_method("FLUSH") == 1, "flush() sent FLUSH");
    ck(session.pending_frames() == 0, "flush() dropped buffered frames");

    const auto closeT0 = std::chrono::steady_clock::now();
    session.close();
    const auto closeMs = ms_between(closeT0, std::chrono::steady_clock::now());
    ck(!session.is_open(), "is_open() false after close");
    ck(srv.count_method("TEARDOWN") == 1, "close() sent TEARDOWN");
    ck(closeMs < 800, "close() bounded", std::to_string(closeMs) + "ms");
    {
        const RaopHealth h = session.health();
        ck(!h.timing_thread && !h.control_thread, "health reports both worker threads stopped");
        ck(!h.open, "health reports closed");
    }
    const auto close2T0 = std::chrono::steady_clock::now();
    session.close();
    ck(ms_between(close2T0, std::chrono::steady_clock::now()) < 50, "second close() is instant");
}

// ─────────────────────────────────────────────────────────────────────────────
// NACK 重传：线格式（0xD6 封装）、路由（control 端口）、来源校验、有界
// ─────────────────────────────────────────────────────────────────────────────
void test_nack_retransmit() {
    using namespace rta::net;
    section("control NACK retransmission (0xD6 wrapper routed to control)");

    FakeReceiver srv;
    ck(srv.start(), "fake receiver start (nack)");
    RaopSession session;
    std::string err;
    ck(session.open(loopback_cfg(srv), &err), "open() for NACK test", err);

    uint16_t localControl = 0, localTiming = 0;
    ck(srv.session_ports(localControl, localTiming), "local control port known");

    auto pcm = make_pcm(352 * 3, 2, 3000);
    ck(session.write_pcm(pcm.data(), 352 * 3, &err), "write 3 packets", err);
    ck(srv.wait_audio_packets(3), "receiver got 3 packets");
    const auto before = srv.audio_snapshot();
    ck(before.size() == 3, "exactly 3 audio packets recorded", std::to_string(before.size()));
    if (before.size() != 3) return;
    {
        bool allPlain = true;
        for (const auto& p : before) allPlain = allPlain && p.size() > 12 && p[0] == 0x80 && p[1] == 0x60;
        ck(allPlain, "original audio packets are plain RTP (0x60) on the audio port");
    }

    // (1) 命中：control 端口上的 0xD6 = 4 字节重传头 + 原样 RTP 包（参考实现只认这个）
    const uint16_t seq1 = rd16(before[1].data() + 2);
    const size_t d6Before = srv.control_count_type(0xD6);
    const size_t audioBefore = srv.audio_count();
    ck(srv.send_nack(localControl, seq1, 1), "send NACK for packet #2");
    ck(srv.wait_control_type(0xD6, d6Before + 1), "0xD6 retransmission arrives on the control port");
    {
        const auto resent = srv.control_by_type(0xD6);
        ck(resent.size() == d6Before + 1, "exactly one 0xD6 packet", std::to_string(resent.size()));
        if (resent.size() == d6Before + 1) {
            const auto& r = resent.back();
            ck(r.size() == 4 + before[1].size(), "resend = 4-byte wrapper + original RTP packet",
               std::to_string(r.size()) + " vs " + std::to_string(4 + before[1].size()));
            ck(r[0] == 0x80 && r[1] == 0xD6, "resend leader/type is 0x80/0xD6");
            ck(rd16(r.data() + 2) == seq1, "resend wrapper carries the requested sequence");
            ck(std::equal(r.begin() + 4, r.end(), before[1].begin(), before[1].end()),
               "inner RTP header + ALAC payload are byte-identical to the original packet");
            if (r.size() == 4 + before[1].size()) {
                ck(rd16(r.data() + 6) == seq1, "inner RTP sequence == requested sequence");
                ck(rd32(r.data() + 8) == rd32(before[1].data() + 4),
                   "inner RTP timestamp == original timestamp");
                ck(std::memcmp(r.data() + 16, before[1].data() + 12, before[1].size() - 12) == 0,
                   "inner ALAC payload is bit-exact");
            }
        }
    }
    ck(srv.audio_count() == audioBefore, "nothing is retransmitted on the audio port");
    ck(wait_until([&]() { return session.nack_requests() == 1; }), "NACK counter == 1");
    ck(wait_until([&]() { return session.retransmits() == 1; }), "retransmit counter == 1");
    ck(session.packets_sent() == 3, "retransmission does not count as new audio");
    ck(session.health().send_errors == 0, "retransmission produced no send error");

    // (2) 多包请求：只有缓存里还在的才补
    const uint16_t seq2 = rd16(before[2].data() + 2);
    const size_t d6BeforeMulti = srv.control_count_type(0xD6);
    ck(srv.send_nack(localControl, seq2, 3), "send NACK count=3 from the last packet");
    ck(srv.wait_control_type(0xD6, d6BeforeMulti + 1), "retransmission for the known seq arrives");
    {
        const auto resent = srv.control_by_type(0xD6);
        ck(resent.size() == d6BeforeMulti + 1, "only the existing packet is retransmitted",
           std::to_string(resent.size() - d6BeforeMulti));
        if (resent.size() == d6BeforeMulti + 1) {
            ck(std::equal(resent.back().begin() + 4, resent.back().end(), before[2].begin(),
                          before[2].end()),
               "multi-count retransmit payload identical");
        }
    }
    ck(wait_until([&]() { return session.retransmits() == 2; }), "retransmit counter == 2");
    ck(wait_until([&]() { return session.nack_misses() == 2; }), "two misses for the non-existent tail",
       std::to_string(session.nack_misses()));

    // (3) 来源校验：源端口不是对端公布的 audio/control/timing → 拒绝，不补发、不计数
    {
        const size_t d6BeforeBad = srv.control_count_type(0xD6);
        const uint64_t rejectedBefore = session.nack_rejected();
        const uint64_t acceptedBefore = session.nack_requests();
        ck(srv.send_nack_from_ephemeral_port(localControl, seq1, 1),
           "send NACK from a socket whose source port is not the receiver's control port");
        ck(wait_until([&]() { return session.nack_rejected() > rejectedBefore; }),
           "NACK from an unexpected source port is rejected");
        std::this_thread::sleep_for(std::chrono::milliseconds(150));
        ck(srv.control_count_type(0xD6) == d6BeforeBad, "rejected NACK causes no retransmission");
        ck(session.nack_requests() == acceptedBefore, "rejected NACK is not counted as accepted");
        ck(session.health().nack_rejected == session.nack_rejected(),
           "health.nack_rejected matches the getter (fact, not intent)");
    }

    // (4) 畸形/否定请求：不崩、不补、不误发
    srv.wait_audio_quiet(200, 1000);
    const size_t quietD6 = srv.control_count_type(0xD6);
    uint8_t junk[3] = {0x80, 0xD5, 0x00};
    ck(srv.send_raw_control(localControl, junk, sizeof(junk)), "send truncated NACK");
    uint8_t notNack[20] = {0x80, 0xD4};
    ck(srv.send_raw_control(localControl, notNack, sizeof(notNack)), "send non-NACK control packet");
    ck(srv.send_nack(localControl, 0, 0), "send NACK with count=0");
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    ck(srv.control_count_type(0xD6) == quietD6, "malformed NACKs produce no retransmission");

    // (5) 过老请求：缓存之外 → Miss，不补
    // 缓存容量是固定的（>= 512 包）：必须写过一整个容量，最早的包才会被淘汰
    const size_t evictPackets = 600;
    auto big = make_pcm(352 * evictPackets, 2, 7);
    ck(session.write_pcm(big.data(), 352 * evictPackets, &err), "write 600 more packets", err);
    srv.wait_audio_quiet(250, 2000);
    const size_t d6BeforeOld = srv.control_count_type(0xD6);
    const uint32_t firstSeq = rd16(before[0].data() + 2);
    const uint64_t missesBefore = session.nack_misses();   // 必须在发请求之前读
    ck(srv.send_nack(localControl, static_cast<uint16_t>(firstSeq), 1), "NACK for an evicted seq");
    ck(wait_until([&]() { return session.nack_misses() >= missesBefore + 1; }),
       "evicted seq counted as a miss");
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    ck(srv.control_count_type(0xD6) == d6BeforeOld, "evicted seq is NOT retransmitted");

    // (6) 序号召回绕：只补请求范围内的序号，绝不越界补别的包
    {
        const size_t d6BeforeWrap = srv.control_count_type(0xD6);
        ck(srv.send_nack(localControl, 0xFFFE, 4), "NACK across sequence wrap boundary");
        std::this_thread::sleep_for(std::chrono::milliseconds(250));
        const auto resent = srv.control_by_type(0xD6);
        const size_t extra = resent.size() - d6BeforeWrap;
        bool onlyRequested = true;
        for (size_t i = d6BeforeWrap; i < resent.size(); ++i) {
            const uint16_t seq = rd16(resent[i].data() + 2);
            if (!(seq == 0xFFFE || seq == 0xFFFF || seq == 0x0000 || seq == 0x0001)) {
                onlyRequested = false;
            }
        }
        ck(extra <= 4, "wrap-boundary NACK never sends more than requested", std::to_string(extra));
        ck(onlyRequested, "wrap-boundary NACK only ever retransmits the requested sequences");
    }

    // (7) 请求本身有界：一次 NACK 最多触发 kMaxNackCount 个补发尝试
    {
        const auto refreshed = srv.audio_snapshot();
        const uint16_t lastSeq = rd16(refreshed.back().data() + 2);
        const size_t d6BeforeBig = srv.control_count_type(0xD6);
        const uint64_t missesBeforeBig = session.nack_misses();
        const auto t0 = std::chrono::steady_clock::now();
        ck(srv.send_nack(localControl, lastSeq, 5000), "NACK asking for 5000 packets");
        ck(wait_until([&]() { return session.nack_misses() > missesBeforeBig; }, 2000),
           "oversized NACK is processed");
        const auto ms = ms_between(t0, std::chrono::steady_clock::now());
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        const size_t extra = srv.control_count_type(0xD6) - d6BeforeBig;
        const uint64_t missDelta = session.nack_misses() - missesBeforeBig;
        ck(extra <= 1, "oversized NACK retransmits at most the one cached packet",
           std::to_string(extra));
        ck(missDelta <= 128, "oversized NACK is clamped to the documented bound",
           std::to_string(missDelta));
        ck(ms < 1500, "oversized NACK stays bounded in time", std::to_string(ms) + "ms");
    }

    session.close();
}

// ─────────────────────────────────────────────────────────────────────────────
// 单包 ALAC 解码（测试独立实现）：用于证明发出的载荷**内容**正确，
// 而不是只证明它“非空”。ALAC 编码器有跨包状态，字节比对不可靠，必须解码后比 PCM。
// ─────────────────────────────────────────────────────────────────────────────
bool decode_alac_single(uint32_t sampleRate, int channels, int fpp,
                        const std::vector<uint8_t>& cookie,
                        const std::vector<uint8_t>& payload,
                        std::vector<int16_t>& outPcm, std::string* err) {
    outPcm.clear();
    AudioStreamBasicDescription pcmDesc{};
    pcmDesc.mFormatID = kAudioFormatLinearPCM;
    pcmDesc.mSampleRate = static_cast<Float64>(sampleRate);
    pcmDesc.mChannelsPerFrame = static_cast<UInt32>(channels);
    pcmDesc.mBitsPerChannel = 16;
    pcmDesc.mBytesPerFrame = static_cast<UInt32>(channels * sizeof(int16_t));
    pcmDesc.mFramesPerPacket = 1;
    pcmDesc.mBytesPerPacket = pcmDesc.mBytesPerFrame;
    pcmDesc.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;

    AudioStreamBasicDescription alacDesc{};
    alacDesc.mFormatID = kAudioFormatAppleLossless;
    alacDesc.mSampleRate = static_cast<Float64>(sampleRate);
    alacDesc.mChannelsPerFrame = static_cast<UInt32>(channels);
    alacDesc.mBitsPerChannel = 16;
    alacDesc.mFramesPerPacket = static_cast<UInt32>(fpp);

    AudioConverterRef dec = nullptr;
    OSStatus st = ::AudioConverterNew(&alacDesc, &pcmDesc, &dec);
    if (st != noErr || !dec) {
        if (err) *err = "AudioConverterNew(dec) failed: " + std::to_string(static_cast<int>(st));
        return false;
    }
    if (!cookie.empty()) {
        st = ::AudioConverterSetProperty(dec, kAudioConverterDecompressionMagicCookie,
                                         static_cast<UInt32>(cookie.size()), cookie.data());
        if (st != noErr) {
            ::AudioConverterDispose(dec);
            if (err) *err = "set decompression cookie failed: " + std::to_string(static_cast<int>(st));
            return false;
        }
    }

    struct DecCtx {
        const uint8_t* data;
        size_t size;
        bool done;
    };
    auto cb = [](AudioConverterRef, UInt32* ioPackets, AudioBufferList* ioData,
                 AudioStreamPacketDescription** outDesc, void* userData) -> OSStatus {
        auto* ctx = static_cast<DecCtx*>(userData);
        if (ctx->done) {
            *ioPackets = 0;
            return noErr;
        }
        static AudioStreamPacketDescription asp{};
        asp.mStartOffset = 0;
        asp.mVariableFramesInPacket = 0;
        asp.mDataByteSize = static_cast<UInt32>(ctx->size);
        ioData->mNumberBuffers = 1;
        ioData->mBuffers[0].mNumberChannels = 1;
        ioData->mBuffers[0].mDataByteSize = asp.mDataByteSize;
        ioData->mBuffers[0].mData = const_cast<uint8_t*>(ctx->data);
        *ioPackets = 1;
        if (outDesc) *outDesc = &asp;
        ctx->done = true;
        return noErr;
    };

    std::vector<int16_t> buf(static_cast<size_t>(fpp) * static_cast<size_t>(channels));
    DecCtx dctx{payload.data(), payload.size(), false};
    UInt32 outFrames = static_cast<UInt32>(fpp);
    AudioBufferList abl{};
    abl.mNumberBuffers = 1;
    abl.mBuffers[0].mNumberChannels = static_cast<UInt32>(channels);
    abl.mBuffers[0].mDataByteSize = static_cast<UInt32>(buf.size() * sizeof(int16_t));
    abl.mBuffers[0].mData = buf.data();
    st = ::AudioConverterFillComplexBuffer(dec, cb, &dctx, &outFrames, &abl, nullptr);
    if (st != noErr) {
        ::AudioConverterDispose(dec);
        if (err) *err = "ALAC decode failed: " + std::to_string(static_cast<int>(st));
        return false;
    }
    outPcm.assign(buf.data(), buf.data() + outFrames * static_cast<UInt32>(channels));
    ::AudioConverterDispose(dec);
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// EOS：尾部不足一包用静音补齐
// ─────────────────────────────────────────────────────────────────────────────
void test_eos_partial() {
    using namespace rta::net;
    section("EOS partial packet (finish)");

    FakeReceiver srv;
    ck(srv.start(), "fake receiver start (eos)");
    RaopSession session;
    std::string err;
    ck(session.open(loopback_cfg(srv), &err), "open() for EOS test", err);

    uint16_t recSeq = 0;
    uint32_t recRtptime = 0;
    ck(srv.record_rtp_info(recSeq, recRtptime), "RECORD RTP-Info (eos)");

    // 704 + 100 帧：2 个整包 + 100 帧余量（余量不应自己发出去）
    auto pcm = make_pcm(804, 2, 1234);
    ck(session.write_pcm(pcm.data(), 804, &err), "write 804 frames", err);
    ck(srv.wait_audio_packets(2), "exactly the 2 full packets were sent");
    std::this_thread::sleep_for(std::chrono::milliseconds(150));
    ck(srv.audio_count() == 2, "partial tail is NOT sent before finish()", std::to_string(srv.audio_count()));
    ck(session.pending_frames() == 100, "100 frames still pending", std::to_string(session.pending_frames()));

    ck(session.finish(&err), "finish() sends the padded tail", err);
    ck(srv.wait_audio_packets(3), "tail packet arrives");
    const auto pkts = srv.audio_snapshot();
    ck(pkts.size() == 3, "exactly 3 packets after finish()", std::to_string(pkts.size()));
    if (pkts.size() == 3) {
        ck(rd32(pkts[2].data() + 4) == recRtptime + 2 * 352u, "tail timestamp continues the timeline");
        ck(rd16(pkts[2].data() + 2) == static_cast<uint16_t>(recSeq + 2), "tail sequence continues");

        // 期望内容：最后 100 帧 + 252 帧静音。ALAC 编码器有跨包状态，
        // 所以判据是「解码回来的 PCM 逐样本相等」，不是「字节与另一台编码器相同」。
        std::vector<int16_t> expected(352 * 2, 0);
        std::memcpy(expected.data(), pcm.data() + 704 * 2, 100 * 2 * sizeof(int16_t));

        rta::audio::AlacEncoder ref;
        std::string e2;
        ck(ref.init(44100, 2, 16, 352, &e2), "reference encoder init (cookie)", e2);
        const std::vector<uint8_t> payload(pkts[2].begin() + 12, pkts[2].end());
        ck(payload != std::vector<uint8_t>(pkts[1].begin() + 12, pkts[1].end()),
           "tail payload is not a duplicate of the previous packet");
        std::vector<int16_t> decoded;
        ck(decode_alac_single(44100, 2, 352, ref.magic_cookie(), payload, decoded, &e2),
           "tail packet decodes as ALAC", e2);
        ck(decoded.size() == expected.size(), "tail decodes to exactly 352 frames",
           std::to_string(decoded.size()) + " samples");
        ck(decoded == expected, "tail PCM == 100 real frames followed by 252 silent frames");
        if (decoded != expected) {
            size_t firstDiff = 0;
            while (firstDiff < decoded.size() && firstDiff < expected.size() &&
                   decoded[firstDiff] == expected[firstDiff]) {
                ++firstDiff;
            }
            std::printf("    first difference at sample %zu: got %d want %d\n", firstDiff,
                        firstDiff < decoded.size() ? decoded[firstDiff] : 0,
                        firstDiff < expected.size() ? expected[firstDiff] : 0);
        }
    }
    ck(session.finish(&err), "finish() with nothing pending is a no-op", err);
    ck(srv.audio_count() == 3, "no extra packet from the second finish()");

    // 跨调用分帧：100 + 252 必须拼成**同一包**且内容逐样本正确（不丢样、不重排）
    {
        FakeReceiver srv2;
        ck(srv2.start(), "fake receiver start (cross-call framing)");
        RaopSession s2;
        ck(s2.open(loopback_cfg(srv2), &err), "open() for cross-call framing", err);
        auto part = make_pcm(352, 2, 4321);
        ck(s2.write_pcm(part.data(), 100, &err), "write 100 frames", err);
        std::this_thread::sleep_for(std::chrono::milliseconds(60));
        ck(srv2.audio_count() == 0, "no packet before the first frame group is complete",
           std::to_string(srv2.audio_count()));
        ck(s2.pending_frames() == 100, "100 frames buffered across calls");
        ck(s2.write_pcm(part.data() + 100 * 2, 252, &err), "write the remaining 252 frames", err);
        ck(srv2.wait_audio_packets(1), "one packet after 100+252 frames");
        std::this_thread::sleep_for(std::chrono::milliseconds(60));
        ck(srv2.audio_count() == 1, "exactly one packet (no split, no duplicate)",
           std::to_string(srv2.audio_count()));
        const auto got = srv2.audio_snapshot();
        if (got.size() == 1) {
            rta::audio::AlacEncoder ref;
            std::string e3;
            ck(ref.init(44100, 2, 16, 352, &e3), "reference encoder init (framing)", e3);
            std::vector<int16_t> decoded;
            const std::vector<uint8_t> payload(got[0].begin() + 12, got[0].end());
            ck(decode_alac_single(44100, 2, 352, ref.magic_cookie(), payload, decoded, &e3),
               "cross-call packet decodes", e3);
            ck(decoded.size() == 352u * 2u, "cross-call packet has 352 frames", std::to_string(decoded.size()));
            ck(std::memcmp(decoded.data(), part.data(), 352u * 2u * sizeof(int16_t)) == 0,
               "100+252 frames are contiguous and lossless in the packet");
        }
        s2.close();
    }
    session.close();
}

// ─────────────────────────────────────────────────────────────────────────────
// 交织（RTP over RTSP/TCP）路由
// ─────────────────────────────────────────────────────────────────────────────
void test_interleaved_tcp() {
    using namespace rta::net;
    section("interleaved RTP/AVP/TCP routing");

    FakeReceiver srv;
    srv.interleavedTcp = true;
    ck(srv.start(), "fake receiver start (tcp)");
    RaopSession session;
    std::string err;
    ck(session.open(loopback_cfg(srv), &err), "open() in interleaved mode", err);
    ck(session.interleaved(), "session chose interleaved transport");

    uint16_t recSeq = 0;
    uint32_t recRtptime = 0;
    ck(srv.record_rtp_info(recSeq, recRtptime), "RECORD RTP-Info (tcp)");

    auto pcm = make_pcm(352, 2, 55);
    ck(session.write_pcm(pcm.data(), 352, &err), "write one packet over TCP", err);
    ck(srv.wait_tcp_channel(0, 1), "audio frame on interleaved channel 0");
    {
        std::lock_guard<std::mutex> lk(srv.mtx);
        ck(srv.audioPackets.empty(), "no UDP audio packets in interleaved mode");
        if (!srv.tcpChannel0.empty()) {
            const auto& f = srv.tcpChannel0[0];
            ck(f.size() > 12 && f[0] == 0x80 && f[1] == 0x60, "interleaved frame has RTP header");
            ck(rd16(f.data() + 2) == recSeq, "interleaved seq == RECORD seq");
            ck(rd32(f.data() + 4) == recRtptime, "interleaved timestamp == RECORD rtptime");
        }
    }
    ck(srv.wait_tcp_channel(1, 1, 1500), "sync frame on interleaved channel 1");
    {
        std::lock_guard<std::mutex> lk(srv.mtx);
        if (!srv.tcpChannel1.empty()) {
            const auto& s = srv.tcpChannel1[0];
            ck(s.size() == 20 && s[0] == 0x80 && s[1] == 0xD4, "channel 1 carries the 0xD4 sync packet");
            if (s.size() == 20) {
                ck(rd32(s.data() + 16) - rd32(s.data() + 4) == session.latency_frames(),
                   "interleaved sync advertises the configured latency");
            }
        }
        ck(srv.otherInterleavedChannels == 0, "no frames on unexpected channels");
    }
    session.close();
}

// ─────────────────────────────────────────────────────────────────────────────
// 453 重试：结构化状态码 + 有界
// ─────────────────────────────────────────────────────────────────────────────
void test_retry_453() {
    using namespace rta::net;
    section("453 stale-session retry (structured, bounded)");

    // (a) 前两次 453，第三次成功
    {
        FakeReceiver srv;
        srv.announce453Times = 2;
        ck(srv.start(), "fake receiver start (453 x2)");
        RaopConfig cfg = loopback_cfg(srv);
        RaopSession session;
        std::string err;
        const auto t0 = std::chrono::steady_clock::now();
        const bool ok = session.open(cfg, &err);
        const auto ms = ms_between(t0, std::chrono::steady_clock::now());
        ck(ok, "open() succeeds after two 453s", err);
        ck(srv.count_method("ANNOUNCE") == 3, "exactly 3 ANNOUNCE attempts", std::to_string(srv.count_method("ANNOUNCE")));
        ck(ms >= 200 && ms < 4000, "retry backoff bounded", std::to_string(ms) + "ms");
        ck(session.is_open(), "session usable after retry");
        auto pcm = make_pcm(352, 2, 9);
        ck(session.write_pcm(pcm.data(), 352, &err), "audio flows after retry", err);
        ck(srv.wait_audio_packets(1), "receiver got audio after retry");
        session.close();
    }

    // (b) 一直 453：重试次数与总时长都有上限
    {
        FakeReceiver srv;
        srv.announce453Times = 1000;
        ck(srv.start(), "fake receiver start (453 forever)");
        RaopSession session;
        std::string err;
        const auto t0 = std::chrono::steady_clock::now();
        const bool ok = session.open(loopback_cfg(srv), &err);
        const auto ms = ms_between(t0, std::chrono::steady_clock::now());
        ck(!ok, "open() fails when the receiver keeps returning 453");
        ck(srv.count_method("ANNOUNCE") == 3, "stops after 3 attempts", std::to_string(srv.count_method("ANNOUNCE")));
        ck(ms < 4000, "总时长有界（不许阻塞）", std::to_string(ms) + "ms");
        ck(err.find("453") != std::string::npos && err.find("3 次") != std::string::npos,
           "error explains 453 and the attempt count", err);
        ck(!session.is_open(), "session closed after failure");
    }

    // (c) 状态码 403 但状态文本里含 "453"：旧实现会按子串重试，新实现必须只尝试一次
    {
        FakeReceiver srv;
        srv.announceStatus = 403;
        srv.announceStatusText = "453 Forbidden";
        ck(srv.start(), "fake receiver start (403 with 453 text)");
        RaopSession session;
        std::string err;
        ck(!session.open(loopback_cfg(srv), &err), "open() fails on 403");
        ck(srv.count_method("ANNOUNCE") == 1,
           "no retry when 453 only appears in the status TEXT (structured code is 403)",
           std::to_string(srv.count_method("ANNOUNCE")));
        ck(err.find("403") != std::string::npos, "error carries the real status code", err);
    }

    // (d) 非 453 的 5xx 不重试
    {
        FakeReceiver srv;
        srv.announceStatus = 503;
        srv.announceStatusText = "Service Unavailable";
        ck(srv.start(), "fake receiver start (503)");
        RaopSession session;
        std::string err;
        ck(!session.open(loopback_cfg(srv), &err), "open() fails on 503");
        ck(srv.count_method("ANNOUNCE") == 1, "503 is not retried", std::to_string(srv.count_method("ANNOUNCE")));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 失败路径：超时、TEARDOWN 悬挂、加密、未打开
// ─────────────────────────────────────────────────────────────────────────────
void test_failures_bounded() {
    using namespace rta::net;
    section("bounded failures");

    // (a) 对端完全不应答 OPTIONS
    {
        FakeReceiver srv;
        srv.hangOnOptions = true;
        ck(srv.start(), "fake receiver start (no OPTIONS answer)");
        RaopConfig cfg = loopback_cfg(srv);
        cfg.rtspTimeoutMs = 400;
        RaopSession session;
        std::string err;
        const auto t0 = std::chrono::steady_clock::now();
        const bool ok = session.open(cfg, &err);
        const auto ms = ms_between(t0, std::chrono::steady_clock::now());
        ck(!ok, "open() fails on RTSP timeout");
        ck(ms >= 300 && ms < 1800, "timeout is honoured, no hang", std::to_string(ms) + "ms");
        ck(err.find("超时") != std::string::npos, "error says timeout", err);
        ck(!session.is_open(), "session not open after timeout");
    }

    // (b) 对端不应答 TEARDOWN：close() 仍必须有界
    {
        FakeReceiver srv;
        srv.hangOnTeardown = true;
        ck(srv.start(), "fake receiver start (no TEARDOWN answer)");
        RaopSession session;
        std::string err;
        ck(session.open(loopback_cfg(srv), &err), "open() for teardown-hang test", err);
        const auto t0 = std::chrono::steady_clock::now();
        session.close();
        const auto ms = ms_between(t0, std::chrono::steady_clock::now());
        ck(ms < 800, "close() bounded even if TEARDOWN is never answered", std::to_string(ms) + "ms");
        ck(!session.is_open(), "session closed");
    }

    // (c) 加密：立刻拒绝，不建连
    {
        RaopConfig cfg;
        cfg.host = "127.0.0.1";
        cfg.port = 5000;
        cfg.needsEncryption = true;
        RaopSession session;
        std::string err;
        const auto t0 = std::chrono::steady_clock::now();
        const bool ok = session.open(cfg, &err);
        ck(!ok, "open() rejects needsEncryption");
        ck(err.find("RSA") != std::string::npos, "error explains RSA is unsupported", err);
        ck(ms_between(t0, std::chrono::steady_clock::now()) < 100, "rejected before any network I/O");
    }

    // (d) 未打开时 write_pcm / finish 必须失败
    {
        RaopSession session;
        std::string err;
        int16_t buf[8] = {0};
        ck(!session.write_pcm(buf, 4, &err), "write_pcm fails when not open");
        ck(!err.empty(), "write_pcm error text present", err);
        ck(!session.finish(&err), "finish fails when not open");
    }

    // (e) 连接到关闭的端口：有界失败
    {
        RaopConfig cfg;
        cfg.host = "127.0.0.1";
        cfg.port = 1;                 // 无监听
        cfg.rtspTimeoutMs = 400;
        RaopSession session;
        std::string err;
        const auto t0 = std::chrono::steady_clock::now();
        ck(!session.open(cfg, &err), "open() fails to a closed port");
        ck(ms_between(t0, std::chrono::steady_clock::now()) < 1500, "connect failure bounded");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 重开：状态彻底复位
// ─────────────────────────────────────────────────────────────────────────────
void test_reopen_reset() {
    using namespace rta::net;
    section("reopen state reset");

    FakeReceiver srv;
    ck(srv.start(), "fake receiver start (reopen)");
    RaopSession session;
    std::string err;
    ck(session.open(loopback_cfg(srv), &err), "first open", err);

    uint16_t seq1 = 0;
    uint32_t rtp1 = 0;
    ck(srv.record_rtp_info(seq1, rtp1), "first RECORD RTP-Info");
    const std::string uri1 = srv.last_announce_uri();
    auto pcm = make_pcm(704, 2, 1);
    ck(session.write_pcm(pcm.data(), 704, &err), "write in first session", err);
    ck(srv.wait_audio_packets(2), "first session audio delivered");
    ck(session.packets_sent() == 2, "first session packet counter");
    session.close();

    // 重开：时间轴/计数器/RTP 随机数必须全部复位
    ck(session.open(loopback_cfg(srv), &err), "second open on the same receiver", err);
    uint16_t seq2 = 0;
    uint32_t rtp2 = 0;
    ck(srv.last_record_rtp_info(seq2, rtp2), "second RECORD RTP-Info");
    const std::string uri2 = srv.last_announce_uri();
    ck(!uri1.empty() && !uri2.empty() && uri1 != uri2, "new session id on reopen", uri1 + " vs " + uri2);
    ck(rtp2 != rtp1, "new RTP base timestamp on reopen");
    ck(session.packets_sent() == 0, "packet counter reset on reopen");
    ck(session.sync_packets_sent() == 0, "sync counter reset on reopen");
    ck(session.nack_requests() == 0 && session.retransmits() == 0, "NACK counters reset");
    ck(session.anchor_rtp() == rtp2, "anchor re-based to the new RTP base (no stale anchor)");
    ck(session.current_rtp_at(session.anchor_time()) == rtp2,
       "mapping origin is the new anchor, not the old one");
    const RaopHealth h = session.health();
    ck(h.open && h.send_errors == 0, "health reset on reopen");

    const size_t baseCount = srv.audio_count();
    ck(session.write_pcm(pcm.data(), 352, &err), "write in second session", err);
    ck(srv.wait_audio_packets(baseCount + 1), "second session audio delivered");
    {
        const auto all = srv.audio_snapshot();
        if (all.size() > baseCount) {
            const auto& p = all[baseCount];
            ck(rd16(p.data() + 2) == seq2, "first packet of session 2 uses the new seq");
            ck(rd32(p.data() + 4) == rtp2, "first packet of session 2 uses the new timestamp");
            ck(!(rd16(p.data() + 2) == static_cast<uint16_t>(seq1 + 2)),
               "no continuation of the old sequence state");
        }
    }
    session.close();
}

// ─────────────────────────────────────────────────────────────────────────────
// 暂停/恢复：timing 线程常驻（暂停仍回 0xD2）、未发输入不丢、在途窗口按原 seq 补回
// ─────────────────────────────────────────────────────────────────────────────
void test_pause_reanchor() {
    using namespace rta::net;
    section("pause / resume (timing stays alive, no source frames lost)");

    FakeReceiver srv;
    ck(srv.start(), "fake receiver start (pause)");
    RaopSession session;
    std::string err;
    ck(session.open(loopback_cfg(srv), &err), "open() for pause test", err);

    uint16_t localControl = 0, localTiming = 0;
    ck(srv.session_ports(localControl, localTiming), "session local control/timing ports known");
    uint16_t recSeq = 0;
    uint32_t recRtp = 0;
    ck(srv.record_rtp_info(recSeq, recRtp), "RECORD RTP-Info (pause)");

    // 一个连续源：2 个整包 + 100 帧（不足一包，暂停时必须原样保留）
    auto src = make_pcm(352 * 2 + 100 + 252, 2, 4321);
    ck(session.write_pcm(src.data(), 352 * 2 + 100, &err), "write 2 packets + 100 partial frames", err);
    ck(srv.wait_audio_packets(2), "two packets were sent before the pause");
    const auto before = srv.audio_snapshot();
    ck(before.size() == 2, "exactly 2 audio packets before pause", std::to_string(before.size()));
    if (before.size() != 2) return;
    ck(session.pending_frames() == 100, "100 frames are still pending", std::to_string(session.pending_frames()));
    ck(wait_until([&]() { return session.health().timing_thread; }), "timing thread runs before pause");

    const auto frozenAtPause = session.current_rtp_at(std::chrono::steady_clock::now());
    ck(session.set_paused(true, &err), "set_paused(true)", err);
    ck(session.paused(), "paused() true");

    // FLUSH：让对端立即静音，并且 RTP-Info 落在包边界上
    {
        RtspRequest flush;
        ck(srv.last_request("FLUSH", flush), "pause issues RTSP FLUSH (receiver goes silent now)");
        const std::string info = flush.header("RTP-Info");
        const size_t ps = info.find("seq=");
        const size_t pt = info.find("rtptime=");
        ck(ps != std::string::npos && pt != std::string::npos, "FLUSH carries RTP-Info", info);
        if (ps != std::string::npos && pt != std::string::npos) {
            const uint16_t fseq = static_cast<uint16_t>(std::atoi(info.c_str() + ps + 4));
            const uint32_t frtp =
                static_cast<uint32_t>(std::strtoul(info.c_str() + pt + 8, nullptr, 10));
            ck((frtp - recRtp) % 352u == 0, "FLUSH rtptime sits on a packet boundary",
               std::to_string(frtp));
            ck(static_cast<int32_t>(frtp - frozenAtPause) >= 0,
               "FLUSH never discards audio the receiver already played",
               "frozen=" + std::to_string(frozenAtPause) + " flush=" + std::to_string(frtp));
            ck(static_cast<int32_t>(frtp - frozenAtPause) < 352,
               "FLUSH is at most one packet after the paused position",
               "frozen=" + std::to_string(frozenAtPause) + " flush=" + std::to_string(frtp));
            ck(static_cast<int32_t>(frtp - recRtp - 704) <= 0,
               "FLUSH never points past the next-to-send packet", std::to_string(frtp));
            const uint32_t packets = (frtp - recRtp) / 352u;
            ck(fseq == static_cast<uint16_t>(recSeq + packets),
               "FLUSH seq matches that timestamp", std::to_string(fseq));
        }
    }
    ck(session.pending_frames() == 100,
       "pause keeps the unsent partial input (no encoder/source sample loss)",
       std::to_string(session.pending_frames()));
    ck(srv.count_method("FLUSH") == 1, "exactly one FLUSH on pause");

    // 暂停期间：timing 线程必须还活着并应答 NTP 0xD2（旧实现会 join 掉它 → 对端失锁）
    ck(session.health().timing_thread, "health reports the timing thread alive while paused");
    {
        const uint64_t repliesBefore = session.timing_replies();
        uint8_t tq[32] = {0};
        tq[0] = 0x80;
        tq[1] = 0xD2;
        wr16(tq + 2, 0x4242);
        const uint64_t transmit = 0x1111222233334444ull;
        wr64(tq + 24, transmit);
        std::vector<uint8_t> reply;
        ck(srv.timing_exchange(localTiming, tq, reply, 1200),
           "paused session still answers an NTP 0xD2 request");
        if (reply.size() == 32) {
            ck(reply[0] == 0x80 && reply[1] == 0xD3, "paused timing reply is 0x80/0xD3");
            ck(rd16(reply.data() + 2) == 0x4242, "paused timing reply echoes the request seq");
            ck(rd64(reply.data() + 8) == transmit, "paused timing reply origin == request transmit");
        }
        ck(session.timing_replies() > repliesBefore, "paused reply is counted");
    }

    // 暂停期间：不发 sync
    {
        std::this_thread::sleep_for(std::chrono::milliseconds(150));
        const size_t syncBase = srv.control_count_type(0xD4);
        std::this_thread::sleep_for(std::chrono::milliseconds(750));   // > kRaopSyncIntervalMs
        ck(srv.control_count_type(0xD4) == syncBase, "no sync packets while paused",
           std::to_string(srv.control_count_type(0xD4) - syncBase));
        ck(!session.emit_sync_now(&err), "emit_sync_now refuses while paused");
    }

    // 暂停期间：时间轴冻结
    {
        const uint32_t frozen = session.current_rtp_at(std::chrono::steady_clock::now());
        std::this_thread::sleep_for(std::chrono::milliseconds(120));
        ck(session.current_rtp_at(std::chrono::steady_clock::now()) == frozen,
           "paused timeline does not advance");
        ck(static_cast<uint32_t>(frozen - frozenAtPause) < 4410u,
           "pause freezes at the play position captured a moment earlier (<=100 ms drift)",
           std::to_string(static_cast<uint32_t>(frozen - frozenAtPause)) + " frames");
    }

    // 恢复：时间轴前移，并把“已发未播”的在途窗口按原 seq/rtptime/载荷补发
    const auto anchorBeforeResume = session.anchor_time();
    ck(session.set_paused(false, &err), "set_paused(false)", err);
    ck(!session.paused(), "paused() false");
    ck(session.anchor_time() > anchorBeforeResume,
       "resume re-anchors forward (prebuffer), so fresh audio is not late");
    ck(session.anchor_time() > std::chrono::steady_clock::now(),
       "resume anchor sits in the future");
    ck(session.current_rtp_at(session.anchor_time()) == session.anchor_rtp(),
       "resumed mapping starts exactly at the next-to-send timestamp");

    const size_t replayed = static_cast<size_t>(session.resume_replays());
    ck(replayed >= 1 && replayed <= before.size(),
       "the in-flight window is replayed on resume", std::to_string(replayed));
    ck(srv.wait_audio_packets(before.size() + replayed), "replayed packets reach the receiver");
    {
        const auto after = srv.audio_snapshot();
        ck(after.size() == before.size() + replayed, "only the window was replayed",
           std::to_string(after.size()));
        bool identical = true;
        for (size_t i = 0; i < replayed && after.size() == before.size() + replayed; ++i) {
            const auto& orig = before[before.size() - replayed + i];
            const auto& again = after[before.size() + i];
            identical = identical && (again == orig);
        }
        ck(identical, "replayed packets keep their original seq / rtptime / ALAC payload");
        if (replayed > 0 && after.size() == before.size() + replayed) {
            ck(session.anchor_rtp() == rd32(after[before.size()].data() + 4),
               "resume anchors the timeline at the first replayed packet (replays are not 'late')",
               std::to_string(session.anchor_rtp()));
            ck(static_cast<int32_t>(session.anchor_rtp() - frozenAtPause) <= 0,
               "resume anchor is at or before the paused position");
        }
    }

    // 未发出的 100 帧必须与新写的 252 帧拼成**同一包**，且内容连续（不重复、不丢样）
    ck(session.pending_frames() == 100, "100 pending frames survived pause+resume",
       std::to_string(session.pending_frames()));
    const size_t audioBeforeTail = srv.audio_count();
    ck(session.write_pcm(src.data() + (352 * 2 + 100) * 2, 252, &err), "write the remaining 252 frames", err);
    ck(srv.wait_audio_packets(audioBeforeTail + 1), "the combined packet is sent");
    std::this_thread::sleep_for(std::chrono::milliseconds(60));
    ck(srv.audio_count() == audioBeforeTail + 1, "exactly one packet from 100 + 252 frames",
       std::to_string(srv.audio_count()));
    {
        const auto all = srv.audio_snapshot();
        const auto& tail = all.back();
        ck(rd16(tail.data() + 2) == static_cast<uint16_t>(recSeq + 2),
           "combined packet continues the sequence");
        ck(rd32(tail.data() + 4) == recRtp + 2 * 352u, "combined packet continues the timeline");
        rta::audio::AlacEncoder ref;
        std::string e2;
        ck(ref.init(44100, 2, 16, 352, &e2), "reference encoder init (pause tail)", e2);
        std::vector<int16_t> decoded;
        const std::vector<uint8_t> payload(tail.begin() + 12, tail.end());
        ck(decode_alac_single(44100, 2, 352, ref.magic_cookie(), payload, decoded, &e2),
           "pause tail decodes as ALAC", e2);
        std::vector<int16_t> expected(src.begin() + 352 * 2 * 2, src.begin() + 352 * 2 * 2 + 352 * 2);
        ck(decoded == expected,
           "pause tail == frames [704,1056) of the source (no loss, no duplication)");
    }

    // 恢复后 sync 重新开始
    {
        const size_t syncBase = srv.control_count_type(0xD4);
        ck(session.emit_sync_now(&err) || wait_until([&]() { return srv.control_count_type(0xD4) > syncBase; }, 1500),
           "sync resumes after the pause");
    }

    // reanchor()：seek 语义的时间轴重锚（不动缓冲，也不停 timing 线程）
    {
        const auto t0 = std::chrono::steady_clock::now();
        session.reanchor();
        ck(session.anchor_time() >= t0, "reanchor() moves the timeline origin forward");
        ck(session.current_rtp_at(session.anchor_time()) == session.anchor_rtp(),
           "reanchor() has no ±1 frame offset");
        ck(!session.paused(), "reanchor() clears the paused state");
        ck(session.health().timing_thread, "timing thread still runs after reanchor()");
    }

    // 暂停 → reanchor（不经过 set_paused(false)）也必须能继续发 sync
    {
        ck(session.set_paused(true, &err), "pause again for reanchor check", err);
        ck(session.health().timing_thread, "timing thread survives a second pause");
        const size_t syncBase = srv.control_count_type(0xD4);
        session.reanchor();
        ck(wait_until([&]() { return srv.control_count_type(0xD4) > syncBase; }, 1500),
           "a sync packet is emitted again after reanchor() from a paused state");
    }
    session.close();

    // 发送落后于时间轴（欠载）时暂停：在途窗口为空，FLUSH 的 RTP-Info 不能算出回绕垃圾
    {
        FakeReceiver srv2;
        ck(srv2.start(), "fake receiver start (pause while behind)");
        RaopSession s2;
        std::string e2;
        ck(s2.open(loopback_cfg(srv2), &e2), "open() for the behind-the-timeline case", e2);
        uint16_t recSeq2 = 0;
        uint32_t recRtp2 = 0;
        ck(srv2.record_rtp_info(recSeq2, recRtp2), "RECORD RTP-Info (behind)");
        auto pcm2 = make_pcm(352, 2, 11);
        ck(s2.write_pcm(pcm2.data(), 352, &e2), "only one packet was ever sent", e2);
        std::this_thread::sleep_for(std::chrono::milliseconds(250));   // 时间轴已越过已发包
        ck(s2.set_paused(true, &e2), "pause while the timeline is ahead of the sender", e2);
        RtspRequest flush2;
        ck(srv2.last_request("FLUSH", flush2), "FLUSH captured (behind)");
        const std::string info2 = flush2.header("RTP-Info");
        const size_t pt2 = info2.find("rtptime=");
        ck(pt2 != std::string::npos, "FLUSH carries rtptime (behind)", info2);
        if (pt2 != std::string::npos) {
            const uint32_t frtp2 =
                static_cast<uint32_t>(std::strtoul(info2.c_str() + pt2 + 8, nullptr, 10));
            ck(frtp2 == recRtp2 + 352u,
               "empty in-flight window flushes exactly at the next-to-send timestamp",
               std::to_string(frtp2));
        }
        ck(s2.pending_frames() == 0, "no pending frames in this case");
        ck(s2.set_paused(false, &e2), "resume after the behind-the-timeline pause", e2);
        ck(s2.resume_replays() == 0, "nothing is replayed when the window is empty",
           std::to_string(s2.resume_replays()));
        std::this_thread::sleep_for(std::chrono::milliseconds(80));
        ck(srv2.audio_count() == 1, "resume does not duplicate audio",
           std::to_string(srv2.audio_count()));
        s2.close();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// CastManager 集成路径：open() 之后再 set_playback_lead_seconds(0.6) 必须重定锚点
// ─────────────────────────────────────────────────────────────────────────────
void test_lead_setter_after_open() {
    using namespace rta::net;
    section("set_playback_lead_seconds() after open (CastManager path)");

    FakeReceiver srv;
    ck(srv.start(), "fake receiver start (lead setter)");
    RaopSession session;
    std::string err;
    ck(session.open(loopback_cfg(srv), &err), "open() before lead setter", err);

    const auto anchorBefore = session.anchor_time();
    const auto t0 = std::chrono::steady_clock::now();
    session.set_playback_lead_seconds(0.6);          // CastManager 在 open() 之后调用
    const auto anchorAfter = session.anchor_time();
    const auto leadMs = std::chrono::duration_cast<std::chrono::milliseconds>(anchorAfter - t0).count();
    ck(anchorAfter >= anchorBefore + std::chrono::milliseconds(500),
       "lead setter re-bases the anchor forward (before any audio was written)");
    ck(leadMs > 450 && leadMs < 800, "anchor sits prebuffer seconds in the future",
       std::to_string(leadMs) + "ms");
    ck(session.prebuffer_seconds() > 0.59 && session.prebuffer_seconds() < 0.61,
       "prebuffer_seconds() reports the new lead");

    // 立刻写包：发送领先量必须是正的（不是“到场即迟到”）
    auto pcm = make_pcm(352, 2, 77);
    ck(session.write_pcm(pcm.data(), 352, &err), "write right after the lead setter", err);
    const RaopHealth h = session.health();
    ck(h.last_ahead_frames > 0, "write is ahead of the play position",
       std::to_string(h.last_ahead_frames));
    ck(h.late_packets == 0, "no late packet at startup");

    // 时间轴还没开始就不该发 sync（否则接收端会把起点排早）
    ck(!session.emit_sync_now(&err), "emit_sync_now refuses before the timeline starts");
    ck(err.find("prebuffer") != std::string::npos, "refusal explains the prebuffer window", err);
    {
        std::this_thread::sleep_for(std::chrono::milliseconds(150));
        std::lock_guard<std::mutex> lk(srv.mtx);
        ck(srv.controlPackets.empty(),
           "no spontaneous sync is sent before the timeline starts (would schedule playback early)",
           std::to_string(srv.controlPackets.size()));
    }
    session.close();
}

// ─────────────────────────────────────────────────────────────────────────────
// 对端中途消失：SIGPIPE 必须被抑制（进程活着），错误必须如实上报
// ─────────────────────────────────────────────────────────────────────────────
void test_peer_disappears_sigpipe() {
    using namespace rta::net;
    section("receiver disappears: no SIGPIPE, honest error");

    // (a) UDP 播放中 RTSP 连接被对端关掉：后续控制请求必须失败而不是杀进程
    {
        FakeReceiver srv;
        srv.dropConnectionAfterRecord = true;
        ck(srv.start(), "fake receiver start (drop after RECORD)");
        RaopSession session;
        std::string err;
        ck(session.open(loopback_cfg(srv), &err), "open() succeeds, then the peer vanishes", err);

        // 对端已 close：等它真正消失，再连续尝试写控制请求。
        bool sawError = false;
        std::string lastErr;
        for (int i = 0; i < 40 && !sawError; ++i) {
            std::string e;
            if (!session.set_volume_db(-12.0, &e)) {
                sawError = true;
                lastErr = e;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        ck(sawError, "a control request on a dead connection fails (EPIPE/timeout)", lastErr);
        ck(!lastErr.empty(), "the failure carries an error text", lastErr);
        ck(wait_until([&] { return !session.check_connection(&err); }),
           "UDP sender notices a closed control socket without another volume request", err);
        ck(session.health().transport_failed, "closed UDP control channel latches failure");
        // 走到这里就说明没有收到 SIGPIPE（否则进程已经被信号杀掉）
        ck(true, "process survived writing to a peer that closed the socket");

        const auto t0 = std::chrono::steady_clock::now();
        session.close();
        ck(ms_between(t0, std::chrono::steady_clock::now()) < 900,
           "close() after the peer vanished stays bounded");
    }

    // (b) 交织模式（音频走 TCP）：对端消失后写音频必须报错并锁死传输，而不是无声失败
    {
        FakeReceiver srv;
        srv.interleavedTcp = true;
        srv.dropConnectionAfterRecord = true;
        ck(srv.start(), "fake receiver start (interleaved, drop after RECORD)");
        RaopSession session;
        std::string err;
        ck(session.open(loopback_cfg(srv), &err), "open() in interleaved mode", err);

        auto pcm = make_pcm(352, 2, 5);
        bool failed = false;
        std::string lastErr;
        for (int i = 0; i < 60 && !failed; ++i) {
            std::string e;
            if (!session.write_pcm(pcm.data(), 352, &e)) {
                failed = true;
                lastErr = e;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        ck(failed, "interleaved write fails once the TCP peer is gone", lastErr);
        const RaopHealth h = session.health();
        ck(h.transport_failed, "health reports transport_failed (no silent failure)");
        ck(h.send_errors > 0, "health counts the send errors", std::to_string(h.send_errors));
        ck(!h.last_error.empty(), "health keeps the last transport error", h.last_error);
        ck(!session.write_pcm(pcm.data(), 352, &err) &&
               err.find("失败") != std::string::npos,
           "subsequent writes fail fast with the latched error", err);
        session.close();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 解析与 open 预算：数字 IP 不解析、域名走解析钩子、失败/超时有界
// ─────────────────────────────────────────────────────────────────────────────
void test_resolution_and_open_deadline() {
    using namespace rta::net;
    section("host resolution + open deadline (bounded, no blocking DNS)");

    // (a) 数字 IP：完全不碰解析器
    {
        FakeReceiver srv;
        ck(srv.start(), "fake receiver start (numeric host)");
        RaopSession session;
        std::string err;
        ck(session.open(loopback_cfg(srv), &err), "open() with a numeric IPv4 host", err);
        ck(session.resolver_calls() == 0, "numeric host never invokes the resolver",
           std::to_string(session.resolver_calls()));
        ck(wait_until([&]() { return session.health().timing_thread; }), "session usable");
        session.close();
    }

    // (b) 域名路径：解析钩子把 .local 名字映射到假接收端，证明名字可用且 UDP 目标来自解析结果
    {
        FakeReceiver srv;
        ck(srv.start(), "fake receiver start (named host)");
        RaopSession session;
        std::string err;
        session.set_resolve_hook([](const std::string& host, uint16_t port,
                                    std::vector<RaopEndpoint>& out, std::string* e) {
            if (host != "synthetic-receiver.local") {
                if (e) *e = "stub resolver: unexpected host " + host;
                return false;
            }
            RaopEndpoint ep;
            struct sockaddr_in a {};
            a.sin_family = AF_INET;
            a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            a.sin_port = htons(port);
            std::memcpy(&ep.addr, &a, sizeof(a));
            ep.len = sizeof(a);
            ep.family = AF_INET;
            out.push_back(ep);
            return true;
        });
        RaopConfig cfg = loopback_cfg(srv);
        cfg.host = "synthetic-receiver.local";
        ck(session.open(cfg, &err), "open() resolves a hostname through the resolver hook", err);
        ck(session.resolver_calls() == 1, "hostname path invoked the resolver exactly once",
           std::to_string(session.resolver_calls()));
        auto pcm = make_pcm(352, 2, 21);
        ck(session.write_pcm(pcm.data(), 352, &err), "audio flows to a resolved endpoint", err);
        ck(srv.wait_audio_packets(1), "resolved endpoint receives audio on its UDP port");
        session.close();
    }

    // (c) 解析失败：错误清楚、有界、不建连
    {
        RaopSession session;
        std::string err;
        session.set_resolve_hook([](const std::string& host, uint16_t,
                                    std::vector<RaopEndpoint>&, std::string* e) {
            if (e) *e = "解析主机失败 (" + host + "): 合成的无记录响应";
            return false;
        });
        RaopConfig cfg;
        cfg.host = "no-such-receiver.invalid";
        cfg.port = 5000;
        cfg.openDeadlineMs = 500;
        const auto t0 = std::chrono::steady_clock::now();
        ck(!session.open(cfg, &err), "open() fails when the name does not resolve");
        const auto ms = ms_between(t0, std::chrono::steady_clock::now());
        ck(err.find("解析主机失败") != std::string::npos, "resolution failure is explained", err);
        ck(ms < 500, "resolution failure is bounded", std::to_string(ms) + "ms");
        ck(!session.is_open(), "session closed after a resolution failure");
    }

    // (b2) 真正的解析器路径（dns_sd / mDNSResponder）：localhost 不出网，但确实走了一次解析
    {
        FakeReceiver srv;
        ck(srv.start(), "fake receiver start (resolver path)");
        RaopConfig cfg = loopback_cfg(srv);
        cfg.host = "localhost";
        cfg.openDeadlineMs = 3000;
        RaopSession session;
        std::string err;
        const bool opened = session.open(cfg, &err);
        ck(opened, "open() resolves \"localhost\" through the system resolver", err);
        if (opened) {
            ck(session.resolver_calls() >= 1, "the resolver was actually used",
               std::to_string(session.resolver_calls()));
            auto pcm = make_pcm(352, 2, 31);
            ck(session.write_pcm(pcm.data(), 352, &err), "audio flows to the resolved loopback", err);
            ck(srv.wait_audio_packets(1), "resolved endpoint receives audio");
            session.close();
        }
    }

    // (d) openDeadlineMs 必须钳制每条 RTSP 请求：单请求配置 800 ms，总预算 60 ms
    {
        FakeReceiver srv;
        srv.hangOnOptions = true;
        ck(srv.start(), "fake receiver start (silent OPTIONS)");
        RaopSession session;
        std::string err;
        RaopConfig cfg = loopback_cfg(srv);
        cfg.rtspTimeoutMs = 800;
        cfg.openDeadlineMs = 60;
        const auto t0 = std::chrono::steady_clock::now();
        ck(!session.open(cfg, &err), "open() fails when the receiver never answers");
        const auto ms = ms_between(t0, std::chrono::steady_clock::now());
        ck(ms < 400, "open() honours the total deadline, not the per-request timeout",
           std::to_string(ms) + "ms");
        ck(!session.is_open(), "session not open after the deadline");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 配置标量：只接受有限值，范围内的夹取要反映到 getter/health
// ─────────────────────────────────────────────────────────────────────────────
void test_config_scalars() {
    using namespace rta::net;
    section("config scalars (finite, clamped, effective)");

    // (a) NaN prebuffer：建连之前就拒绝
    {
        RaopConfig cfg;
        cfg.host = "127.0.0.1";
        cfg.port = 1;
        cfg.prebufferSeconds = std::numeric_limits<double>::quiet_NaN();
        RaopSession session;
        std::string err;
        const auto t0 = std::chrono::steady_clock::now();
        ck(!session.open(cfg, &err), "NaN prebuffer is rejected");
        ck(err.find("有限数") != std::string::npos, "error says the value must be finite", err);
        ck(ms_between(t0, std::chrono::steady_clock::now()) < 100, "rejected before any network I/O");
        ck(!session.is_open(), "session not opened");
    }

    // (b) 采样率范围
    {
        RaopConfig cfg;
        cfg.host = "127.0.0.1";
        cfg.port = 1;
        cfg.sampleRate = 4000;
        RaopSession session;
        std::string err;
        ck(!session.open(cfg, &err), "out-of-range sample rate is rejected");
        ck(err.find("8000") != std::string::npos, "error states the supported range", err);
    }

    // (c) 运行期 setter：NaN/inf 忽略，latency 有上限，getter/health 报的是生效值
    {
        FakeReceiver srv;
        ck(srv.start(), "fake receiver start (config scalars)");
        RaopSession session;
        std::string err;
        ck(session.open(loopback_cfg(srv), &err), "open() for setter checks", err);

        const double preBefore = session.prebuffer_seconds();
        session.set_prebuffer_seconds(std::numeric_limits<double>::quiet_NaN());
        session.set_playback_lead_seconds(std::numeric_limits<double>::infinity());
        ck(session.prebuffer_seconds() == preBefore, "NaN/inf prebuffer setters are ignored",
           std::to_string(session.prebuffer_seconds()));

        const uint32_t latBefore = session.latency_frames();
        session.set_latency_seconds(std::numeric_limits<double>::quiet_NaN());
        ck(session.latency_frames() == latBefore, "NaN latency setter is ignored");
        session.set_latency_frames(0xFFFFFFFFu);
        ck(session.latency_frames() == 441000u, "latency is clamped to 10 s", std::to_string(session.latency_frames()));
        ck(session.health().latency_frames == session.latency_frames(),
           "health.latency_frames is the effective value");

        const int spBefore = srv.count_method("SET_PARAMETER");
        ck(!session.set_volume_db(std::numeric_limits<double>::quiet_NaN(), &err), "NaN volume rejected");
        ck(srv.count_method("SET_PARAMETER") == spBefore, "no SET_PARAMETER is sent for a NaN volume");
        session.close();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 瞬时 UDP 错误重试 / 永久错误如实上报
// ─────────────────────────────────────────────────────────────────────────────
void test_transient_send_retry() {
    using namespace rta::net;
    section("transient send errors retried, permanent errors honest");

    // (a) ENOBUFS x2：同一包在预算内重试成功，序号/时间戳不前进，不丢包
    {
        FakeReceiver srv;
        ck(srv.start(), "fake receiver start (transient send errors)");
        std::atomic<int> transientLeft{2};
        RaopSession session;
        std::string err;
        session.set_udp_send_hook([&transientLeft](int fd, const void* data, size_t len,
                                                   const struct sockaddr* to, socklen_t tolen,
                                                   int* e) -> ssize_t {
            if (transientLeft.load() > 0) {
                transientLeft.fetch_sub(1);
                if (e) *e = ENOBUFS;
                return -1;
            }
            const ssize_t n = ::sendto(fd, data, len, 0, to, tolen);
            if (n < 0 && e) *e = errno;
            return n;
        });
        ck(session.open(loopback_cfg(srv), &err), "open() with a send hook", err);
        uint16_t recSeq = 0;
        uint32_t recRtp = 0;
        ck(srv.record_rtp_info(recSeq, recRtp), "RECORD RTP-Info (transient)");
        auto pcm = make_pcm(352 * 3, 2, 555);
        ck(session.write_pcm(pcm.data(), 352 * 3, &err), "write 3 packets through the failing hook", err);
        ck(srv.wait_audio_packets(3), "all 3 packets eventually arrive");
        const auto got = srv.audio_snapshot();
        ck(got.size() == 3, "no packet is lost to a transient error", std::to_string(got.size()));
        bool contiguous = got.size() == 3;
        for (size_t i = 0; i < got.size() && contiguous; ++i) {
            contiguous = rd16(got[i].data() + 2) == static_cast<uint16_t>(recSeq + i) &&
                         rd32(got[i].data() + 4) == recRtp + 352u * static_cast<uint32_t>(i);
        }
        ck(contiguous, "transient retry never advances the sequence / timestamp");
        ck(session.send_retries() >= 2, "retries are counted", std::to_string(session.send_retries()));
        const RaopHealth h = session.health();
        ck(h.send_errors == 0, "a transient error that later succeeded is not an error",
           std::to_string(h.send_errors));
        ck(!h.transport_failed, "transient errors do not latch transport_failed");
        ck(h.packets_sent == 3, "packets_sent counts only delivered packets");
        session.close();
    }

    // (b) 永久错误：立刻失败、不重试、序号不前进；连续三次才锁会话
    {
        FakeReceiver srv;
        ck(srv.start(), "fake receiver start (permanent send error)");
        RaopSession session;
        std::string err;
        session.set_udp_send_hook([](int, const void*, size_t, const struct sockaddr*, socklen_t,
                                     int* e) -> ssize_t {
            if (e) *e = EPERM;
            return -1;
        });
        ck(session.open(loopback_cfg(srv), &err), "open() for the permanent-error case", err);
        auto pcm = make_pcm(352, 2, 7);
        std::string e1;
        const auto t0 = std::chrono::steady_clock::now();
        ck(!session.write_pcm(pcm.data(), 352, &e1), "a permanent send error fails the write");
        const auto ms = ms_between(t0, std::chrono::steady_clock::now());
        ck(ms < 300, "permanent errors fail fast (no retry storm)", std::to_string(ms) + "ms");
        ck(e1.find("失败") != std::string::npos, "error text explains the failure", e1);
        ck(session.health().packets_sent == 0, "a failed send never advances packets_sent");
        ck(session.health().last_errno == EPERM, "errno is reported honestly",
           std::to_string(session.health().last_errno));
        ck(!session.health().transport_failed, "one failure does not kill the session");
        ck(session.send_retries() == 0, "permanent errors are not retried",
           std::to_string(session.send_retries()));
        std::string e2, e3;
        ck(!session.write_pcm(pcm.data(), 352, &e2), "second consecutive hard failure");
        ck(!session.write_pcm(pcm.data(), 352, &e3), "third consecutive hard failure");
        ck(session.health().transport_failed, "three consecutive hard failures latch transport_failed");
        std::string e4;
        ck(!session.write_pcm(pcm.data(), 352, &e4) && e4.find("失败") != std::string::npos,
           "subsequent writes fail fast with the latched reason", e4);
        session.close();
    }

    // (c) 极端入参：frames*channels 溢出必须被拒绝，不能算出一个小 buffer 写出去
    {
        FakeReceiver srv;
        ck(srv.start(), "fake receiver start (overflow guard)");
        RaopSession session;
        std::string err;
        ck(session.open(loopback_cfg(srv), &err), "open() for the overflow guard", err);
        int16_t sample[2] = {1, 2};
        std::string e;
        ck(!session.write_pcm(sample, std::numeric_limits<size_t>::max() / 2 + 1, &e),
           "overflowing frame count is rejected");
        ck(e.find("溢出") != std::string::npos || e.find("过大") != std::string::npos,
           "error explains the overflow", e);
        // 单独的超上限路径：帧数本身合法，但累计待发超过 30 s
        std::string e5;
        const size_t tooMany = 44100u * 31u;   // > 30 s 的立体声帧数
        std::vector<int16_t> bigBlock(tooMany * 2, 0);
        ck(!session.write_pcm(bigBlock.data(), tooMany, &e5), "over-30-s pending buffer is rejected");
        ck(e5.find("上限") != std::string::npos, "error explains the pending cap", e5);
        ck(session.packets_sent() == 0, "nothing was sent for an invalid write");
        session.close();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 单声道：SDP 的 ALAC 声道字段必须跟随配置（以前写死 2）
// ─────────────────────────────────────────────────────────────────────────────
void test_mono_sdp_and_encoding() {
    using namespace rta::net;
    section("mono SDP + mono ALAC encoding");

    {
        FakeReceiver srv;
        ck(srv.start(), "fake receiver start (mono)");
        RaopConfig cfg = loopback_cfg(srv);
        cfg.channels = 1;
        RaopSession session;
        std::string err;
        ck(session.open(cfg, &err), "open() with channels=1", err);
        RtspRequest announce;
        ck(srv.last_request("ANNOUNCE", announce), "ANNOUNCE captured (mono)");
        ck(announce.body.find("a=fmtp:96 352 0 16 40 10 14 1 255 0 0 44100") != std::string::npos,
           "SDP advertises 1 channel (no hardcoded 2)", announce.body);

        auto pcm = make_pcm(352, 1, 900);
        ck(session.write_pcm(pcm.data(), 352, &err), "write 352 mono frames", err);
        ck(srv.wait_audio_packets(1), "mono packet arrives");
        const auto got = srv.audio_snapshot();
        ck(got.size() == 1, "exactly one mono packet", std::to_string(got.size()));
        if (got.size() == 1) {
            rta::audio::AlacEncoder ref;
            std::string e2;
            ck(ref.init(44100, 1, 16, 352, &e2), "reference mono encoder init", e2);
            std::vector<int16_t> decoded;
            const std::vector<uint8_t> payload(got[0].begin() + 12, got[0].end());
            ck(decode_alac_single(44100, 1, 352, ref.magic_cookie(), payload, decoded, &e2),
               "mono packet decodes as 1-channel ALAC", e2);
            ck(decoded == pcm, "mono packet is sample-exact with the source frames");
        }
        session.close();
    }

    // 立体声对照：同一字段必须是 2（防止把修复做成写死 1）
    {
        FakeReceiver srv;
        ck(srv.start(), "fake receiver start (stereo control)");
        RaopSession session;
        std::string err;
        ck(session.open(loopback_cfg(srv), &err), "open() with channels=2", err);
        RtspRequest announce;
        ck(srv.last_request("ANNOUNCE", announce), "ANNOUNCE captured (stereo)");
        ck(announce.body.find("a=fmtp:96 352 0 16 40 10 14 2 255 0 0 44100") != std::string::npos,
           "stereo SDP still advertises 2 channels", announce.body);
        session.close();
    }
}

}  // namespace

int main() {
    std::printf("=== test_raop_session (1.1.2) ===\n");
    test_protocol_codec();
    test_packet_cache();
    test_preflight();
    test_handshake_and_wire();
    test_nack_retransmit();
    test_eos_partial();
    test_interleaved_tcp();
    test_retry_453();
    test_failures_bounded();
    test_reopen_reset();
    test_pause_reanchor();
    test_lead_setter_after_open();
    test_peer_disappears_sigpipe();
    test_resolution_and_open_deadline();
    test_config_scalars();
    test_transient_send_retry();
    test_mono_sdp_and_encoding();
    std::printf("\nResult: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
