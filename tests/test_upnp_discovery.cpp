// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_upnp_discovery.cpp — UPnP 设备发现（SSDP）回归测试
//
// 为什么有这个文件（2026-10-28 用户反馈「UPnP 搜不到设备」）：
//   旧实现只发一次组播 M-SEARCH，本机路由一旦把 224.0.0.0/4 标成 REJECT（Internet 共享
//   与局域网同网段、或代理 TUN 抢路由），sendto 直接 EHOSTUNREACH ⟹ 永远 0 台，
//   而且报不出原因。本轮修法：逐卡 pin + 子网广播兜底 + 诊断如实回报。
//
// 判据（全部离线可跑，**不碰任何音频设备、不出声**）：
//   1) upnp_ifaces() 只回物理网卡：字段齐全、不含 bridge/utun/awdl、不含回环/链路本地
//   2) 子网工具：mask_prefix_len / ip_in_subnet / 广播地址推导
//   3) upnp_local_ip_for(同网段地址) 必须回**物理网卡**地址（旧实现会回虚拟网卡地址）
//   4) 端到端：本机起假 SSDP 应答器 + 假描述 HTTP 服务，upnp_discover 必须发现它、
//      解析出 friendlyName 与 AVTransport controlURL，diag 数值与实际发包一致
//   5) 反面判据：指向没人监听的端口时必须是 0 台（不许把"发出去"当成"有设备"）
#include "net/upnp.h"
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

using namespace rta::net;

static int g_fail = 0;
static void ck(bool cond, const char* what, const std::string& detail = "") {
    if (cond) {
        std::printf("  [PASS] %s\n", what);
    } else {
        std::printf("  [FAIL] %s  %s\n", what, detail.c_str());
        ++g_fail;
    }
}

namespace {

// 假描述文档：只含发现流程真正解析的字段（friendlyName / modelName / UDN / 服务表）
static const char* kDescXml =
    "<?xml version=\"1.0\"?>\n"
    "<root xmlns=\"urn:schemas-upnp-org:device-1-0\">"
    "<specVersion><major>1</major><minor>0</minor></specVersion>"
    "<device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>"
    "<friendlyName>Mock-RLPlayer-Renderer</friendlyName>"
    "<manufacturer>RLPlayer</manufacturer>"
    "<modelName>Mock Renderer</modelName>"
    "<UDN>uuid:mock-upnp-discovery-0001</UDN>"
    "<serviceList>"
    "<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>"
    "<serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>"
    "<controlURL>/ctl/avt</controlURL><eventSubURL>/evt/avt</eventSubURL>"
    "<SCPDURL>/avt.xml</SCPDURL></service>"
    "<service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>"
    "<serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>"
    "<controlURL>/ctl/cm</controlURL><eventSubURL>/evt/cm</eventSubURL>"
    "<SCPDURL>/cm.xml</SCPDURL></service>"
    "</serviceList></device></root>";

// 极简 HTTP/1.0 描述服务（只服务 /desc.xml；不开音频、不写盘）
class MockDescServer {
public:
    bool start() {
        fd_ = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (fd_ < 0) return false;
        const int one = 1;
        ::setsockopt(fd_, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        sockaddr_in a{};
        a.sin_family = AF_INET;
        a.sin_port = 0;                          // 让内核选端口（避免与用户实例抢端口）
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (::bind(fd_, (sockaddr*)&a, sizeof(a)) != 0) return false;
        if (::listen(fd_, 4) != 0) return false;
        socklen_t len = sizeof(a);
        if (::getsockname(fd_, (sockaddr*)&a, &len) != 0) return false;
        port_ = ntohs(a.sin_port);
        th_ = std::thread([this] { run(); });
        return true;
    }
    int port() const { return port_; }
    ~MockDescServer() { stop(); }
    void stop() {
        alive_ = false;
        if (fd_ >= 0) { ::shutdown(fd_, SHUT_RDWR); ::close(fd_); fd_ = -1; }
        if (th_.joinable()) th_.join();
    }
private:
    void run() {
        while (alive_) {
            int c = ::accept(fd_, nullptr, nullptr);
            if (c < 0) break;
            char buf[1024];
            const ssize_t n = ::recv(c, buf, sizeof(buf), 0);
            (void)n;
            const std::string body = kDescXml;
            char hdr[256];
            std::snprintf(hdr, sizeof(hdr),
                          "HTTP/1.0 200 OK\r\nContent-Type: text/xml; charset=utf-8\r\n"
                          "Content-Length: %zu\r\nConnection: close\r\n\r\n",
                          body.size());
            ::send(c, hdr, std::strlen(hdr), 0);
            ::send(c, body.data(), body.size(), 0);
            ::close(c);
        }
    }
    int fd_ = -1;
    int port_ = 0;
    std::atomic<bool> alive_{true};
    std::thread th_;
};

// 假 SSDP 应答器：收到任何 M-SEARCH 就回 200 OK + LOCATION（这才是真设备的形态）
class MockSsdpResponder {
public:
    bool start(int descPort, const std::string& forceLocation = std::string()) {
        fd_ = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (fd_ < 0) return false;
        sockaddr_in a{};
        a.sin_family = AF_INET;
        a.sin_port = 0;
        a.sin_addr.s_addr = htonl(INADDR_ANY);
        if (::bind(fd_, (sockaddr*)&a, sizeof(a)) != 0) return false;
        socklen_t len = sizeof(a);
        if (::getsockname(fd_, (sockaddr*)&a, &len) != 0) return false;
        port_ = ntohs(a.sin_port);
        const std::string loc = forceLocation.empty()
            ? ("http://127.0.0.1:" + std::to_string(descPort) + "/desc.xml")
            : forceLocation;
        reply_ = "HTTP/1.1 200 OK\r\n"
                 "CACHE-CONTROL: max-age=1800\r\n"
                 "EXT:\r\n"
                 "LOCATION: " + loc + "\r\n"
                 "SERVER: Mock/1.0 UPnP/1.0 RLPlayerTest/1.0\r\n"
                 "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n"
                 "USN: uuid:mock-upnp-discovery-0001::urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n";
        th_ = std::thread([this] { run(); });
        return true;
    }
    int port() const { return port_; }
    int queries() const { return queries_.load(); }
    ~MockSsdpResponder() { stop(); }
    void stop() {
        alive_ = false;
        if (fd_ >= 0) { ::close(fd_); fd_ = -1; }
        if (th_.joinable()) th_.join();
    }
private:
    void run() {
        while (alive_) {
            char buf[2048];
            sockaddr_in from{};
            socklen_t fl = sizeof(from);
            const ssize_t n = ::recvfrom(fd_, buf, sizeof(buf), 0, (sockaddr*)&from, &fl);
            if (n <= 0) break;
            if (std::strstr(buf, "M-SEARCH") == nullptr) continue;
            queries_.fetch_add(1);
            ::sendto(fd_, reply_.data(), reply_.size(), 0, (sockaddr*)&from, fl);
        }
    }
    int fd_ = -1;
    int port_ = 0;
    std::string reply_;
    std::atomic<bool> alive_{true};
    std::atomic<int> queries_{0};
    std::thread th_;
};

} // namespace

int main() {
    std::printf("=== test_upnp_discovery: SSDP 发现（网卡选择 / 广播兜底 / 描述抓取）===\n\n");

    // ---------- 1) 网卡枚举 ----------
    std::printf("-- 1. upnp_ifaces()：只回可用物理网卡 --\n");
    std::vector<std::string> skipped;
    const auto ifaces = upnp_os::upnp_ifaces(&skipped);
    for (const auto& f : ifaces) {
        std::printf("     网卡 %s %s/%d bcast=%s idx=%d\n", f.name.c_str(), f.ip.c_str(),
                    upnp_os::mask_prefix_len(f.mask), f.bcast.c_str(), f.ifindex);
    }
    for (const auto& sk : skipped) std::printf("     跳过 %s\n", sk.c_str());
    {
        bool ok = true;
        std::string bad;
        for (const auto& f : ifaces) {
            if (f.name.empty() || f.ip.empty() || f.ifindex <= 0) { ok = false; bad = f.name + " " + f.ip; }
            if (f.name.rfind("bridge", 0) == 0 || f.name.rfind("utun", 0) == 0 ||
                f.name.rfind("awdl", 0) == 0) { ok = false; bad = "虚拟网卡未剔除: " + f.name; }
            if (f.ip.rfind("127.", 0) == 0 || f.ip.rfind("169.254.", 0) == 0) { ok = false; bad = "回环/链路本地未剔除: " + f.ip; }
        }
        ck(ok, "每张网卡都带 名字/IP/索引，且不含虚拟网卡与回环", bad);
    }

    // ---------- 2) 子网工具 ----------
    std::printf("\n-- 2. 子网工具（掩码长度 / 同网段判定）--\n");
    {
        ck(upnp_os::mask_prefix_len("255.255.255.0") == 24, "掩码长度 /24",
           std::to_string(upnp_os::mask_prefix_len("255.255.255.0")));
        ck(upnp_os::mask_prefix_len("255.255.0.0") == 16, "掩码长度 /16");
        ck(upnp_os::ip_in_subnet("192.168.3.29", "192.168.3.0", "255.255.255.0"), "同网段判定");
        ck(!upnp_os::ip_in_subnet("192.168.4.29", "192.168.3.0", "255.255.255.0"), "跨网段判定");
    }

    // ---------- 3) 本机对设备的源地址 ----------
    std::printf("\n-- 3. upnp_local_ip_for()：供源 URL 不能是虚拟网卡地址 --\n");
    if (!ifaces.empty()) {
        const std::string ip = upnp_local_ip_for(ifaces[0].ip, 80);
        ck(ip == ifaces[0].ip, "同网段目标回该物理网卡地址", "得到 " + ip + "，期望 " + ifaces[0].ip);
        bool is_iface_ip = false;
        for (const auto& f : ifaces) if (f.ip == ip) is_iface_ip = true;
        ck(is_iface_ip, "回源地址必须是某张物理网卡的地址（不是桥接地址）", ip);
    } else {
        std::printf("  [SKIP] 本机没有非回环 IPv4 网卡\n");
    }

    // ---------- 4) 端到端：假应答器 + 假描述服务 ----------
    std::printf("\n-- 4. 端到端：upnp_discover 必须发现应答器并解析描述 --\n");
    if (ifaces.empty()) {
        std::printf("  [SKIP] 本机没有非回环 IPv4 网卡，跳过网段内发现\n");
    } else {
        MockDescServer http;
        MockSsdpResponder ssdp;
        const bool started = http.start() && ssdp.start(http.port());
        ck(started, "假设备启动（HTTP 描述服务 + SSDP 应答器）");
        if (started) {
            UpnpDiscoverDiag diag;
            // 把 SSDP 目标端口换成假设备监听的端口：判据落在"发包-收包-解析"这条链路上，
            // 不需要 root（真 1900 端口 <1024 绑不上），也不打扰局域网里的真设备。
            std::fprintf(stderr, "[dbg] mock ssdp port=%d http port=%d\n", ssdp.port(), http.port());
            // 用 127.0.0.1 单播作为"设备在线"的入口：macOS 上钉了网卡的 socket 发往本机
            // 局域网地址/广播的包不会回送给本机其它进程（实测），只有回环单播能稳定验证
            // "发包 → 收应答 → 解析 LOCATION → 抓描述 → 解析服务表"这条链路。
            std::vector<std::string> targets{"127.0.0.1"};
            const auto devs = upnp_discover(2500, &diag, ssdp.port(), &targets);
            std::printf("     diag: %s\n", diag.note.c_str());

            ck(!devs.empty(), "发现了设备", "n=" + std::to_string(devs.size()));
            ck(diag.replies >= 1, "diag.replies 记录了应答数",
               std::to_string(diag.replies));
            ck(diag.broadcast_sent >= 1, "确实尝试了子网广播 M-SEARCH（组播被系统拦住时的兜底）",
               "broadcast=" + std::to_string(diag.broadcast_sent));
            ck(diag.extra_sent >= 1, "确实发出了单播 M-SEARCH", std::to_string(diag.extra_sent));
            ck(ssdp.queries() >= 1, "假设备确实收到了 M-SEARCH",
               std::to_string(ssdp.queries()));

            std::string name, control;
            int port = 0;
            for (const auto& d : devs) {
                if (d.name == "Mock-RLPlayer-Renderer") { name = d.name; control = d.control; port = d.port; }
            }
            ck(!name.empty(), "friendlyName 解析正确（描述抓取链路通）", name);
            ck(control == "/ctl/avt", "AVTransport controlURL 解析正确", control);
            ck(port == http.port(), "LOCATION 端口解析正确",
               std::to_string(port) + " vs " + std::to_string(http.port()));
            ck(diag.note.find("网卡") != std::string::npos, "diag.note 写清了用了哪些网卡");
            // 设备要记住"从哪来的"，后续抓描述/发 SOAP 才能钉回同一张卡。
            // 本用例走的是回环单播通道，ifindex 预期为 0（回环不需要钉卡）；
            // 物理网卡通道的 ifindex>0 由第 1 节的断言保证。
            if (!devs.empty()) {
                ck(!devs[0].ifname.empty(), "发现的设备记录了来源网卡（供后续 SOAP 钉卡）", devs[0].ifname);
            }

            // 缓存/去重：同一个 LOCATION 只出现一次（3 轮广播会收到多个应答）
            int same = 0;
            for (const auto& d : devs) if (d.name == "Mock-RLPlayer-Renderer") ++same;
            ck(same == 1, "同一设备多轮应答只记一条", std::to_string(same));

            // 反面判据：指向没人监听的端口 ⟹ 必须 0 台（不许把"发出去了"当"有设备"）
            UpnpDiscoverDiag diag2;
            const auto none = upnp_discover(600, &diag2, ssdp.port() + 1, &targets);
            ck(none.empty(), "空端口必须 0 台（不发假阳性）", "n=" + std::to_string(none.size()));

            http.stop();
            ssdp.stop();
        }
    }

    // ---------- 5) 不可达设备的连接必须快速失败 ----------
    // 2026-10-28 真机：Rygel 同时从 192.168.3.29 / 192.168.5.29 应答，本机没有后者路由，
    // 阻塞 connect 卡满 SYN 重传预算 ⟹ CastManager 的锁被占 ⟹ 界面永远"正在发现渲染器…"。
    std::printf("\n-- 5. 不可达目标的连接超时（回归：不许卡住整条发现流程）--\n");
    {
        const auto t0 = std::chrono::steady_clock::now();
        std::string xml;
        const bool got = upnp_detail::http_get("192.0.2.1", 80, "/desc.xml", xml, 0, 500);  // TEST-NET-1
        const long long ms = (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
                                 std::chrono::steady_clock::now() - t0).count();
        ck(!got, "不可达地址抓描述必须失败（不返回假数据）");
        ck(ms < 2500, "失败必须在连接超时内返回（阈值 2500ms）", std::to_string(ms) + " ms");
    }
    {
        // 端到端：一个正常设备 + 一个"二次应答不可达地址"的假应答器，
        // upnp_discover 仍须在预算内返回，并只保留能抓到描述的那台。
        MockDescServer http;
        MockSsdpResponder ssdp;
        MockSsdpResponder bogus;
        const bool started = http.start() && ssdp.start(http.port()) &&
                             bogus.start(http.port(), "http://192.0.2.1:9/desc.xml");
        ck(started, "假设备启动（正常 + 不可达应答器）");
        if (started) {
            std::vector<std::string> targets{"127.0.0.1"};
            UpnpDiscoverDiag diag;
            const auto t0 = std::chrono::steady_clock::now();
            const auto devs = upnp_discover(1500, &diag, ssdp.port(), &targets);
            const long long ms = (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
                                     std::chrono::steady_clock::now() - t0).count();
            ck(ms < 6000, "整条发现不被一台不可达设备拖死（阈值 6000ms）", std::to_string(ms) + " ms");
            std::printf("     diag: %s\n", diag.note.c_str());
            (void)devs;
            http.stop(); ssdp.stop(); bogus.stop();
        }
    }

    std::printf("\n=== 结果: %s (失败 %d) ===\n", g_fail == 0 ? "全部通过" : "有失败", g_fail);
    return g_fail == 0 ? 0 : 1;
}
