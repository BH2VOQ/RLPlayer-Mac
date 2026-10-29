// SPDX-FileCopyrightText: 2026 rainlain <https://github.com/okhuoyanyan>
// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// upnp.h — UPnP/DLNA 媒体渲染器发现与本地 HTTP WAV 供源（BSD socket 直连）
//
// 契约要点（ROADMAP P5a）：
//   1) SSDP M-SEARCH 发现 MediaRenderer 设备与解析 AVTransport / ConnectionManager 控制地址；
//   2) 本地 HTTP 供源（UpnpHttpServer）：绑定 0.0.0.0 的可配置端口（默认 8912）；
//      路由 /stream/<token>.wav，随机 token 防目录遍历；
//      支持 Range 请求（bytes=start-end / bytes=start-），渲染器普遍需要 seek；
//      记录访问日志（谁取、取了多少字节）。
//
// 平台（2026-10-25 补全 POSIX 分支）：
//   Windows 走 winsock2，macOS/POSIX 走 BSD socket。两平台差异全部收进下面的
//   upnp_os 别名层，实现体只有一份 —— 避免"双份逻辑各自漂移"这种老坑。
//   Windows 分支保留（铁律：功能不能删除），POSIX 分支与它语义等价。
#pragma once
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif
// 2026-10-26（mac 独立分支）：原 winsock2 include 块已删。
// POSIX / macOS：BSD socket 全套
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <ifaddrs.h>        // getifaddrs()：POSIX 枚举本机网卡的规范做法（见 upnp_local_ipv4）
#include <net/if.h>         // if_nametoindex()：IP → 网卡索引（IP_BOUND_IF 用）
#include <cerrno>
#include "platform/time.h"   // 单调毫秒（语义 = GetTickCount64）
#include "net/upnp_control.h"
#include <string>
#include <vector>
#include <map>
#include <thread>
#include <chrono>
#include <atomic>
#include <mutex>
#include <memory>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <cctype>       // std::tolower —— winsock2.h 在 Windows 上顺带引了，POSIX 必须显式
#include <sstream>      // std::istringstream —— 同上
#include <functional>   // std::function（accessCallback_）—— 同上
#include <cstdint>
#include <fstream>

// ---------------- 平台别名层（Windows winsock2 / POSIX BSD socket） ----------------
//
// 目标：实现体只有一份。下面每个名字在两平台上语义一致，
// 所以 http_get / upnp_discover / UpnpHttpServer 的代码不再出现 #if。
namespace rta::net::upnp_os {

// 2026-10-26（mac 独立分支）：原 winsock2 别名块已删（Windows 平台层移除，
// 且分支不再同步上游）。下面是唯一的 POSIX/macOS 实现。

using socket_t = int;
inline constexpr socket_t kInvalidSocket = -1;

// Windows 的 WSAStartup/WSACleanup 在 POSIX 上没有对应物：空操作，调用点不用改。
inline bool   wsa_init()   { return true; }
inline void   wsa_cleanup() {}
inline int    last_error() { return errno; }
inline bool   would_block(int e) { return e == EWOULDBLOCK || e == EAGAIN; }
inline void   close_socket(socket_t s) { ::close(s); }

inline bool set_nonblocking(socket_t s) {
    const int fl = ::fcntl(s, F_GETFL, 0);
    if (fl < 0) return false;
    return ::fcntl(s, F_SETFL, fl | O_NONBLOCK) == 0;
}

inline int set_opt(socket_t s, int level, int opt, const void* val, socklen_t len) {
    return ::setsockopt(s, level, opt, val, len);
}
inline int set_timeout(socket_t s, int opt, int ms) {
    struct timeval tv{};
    tv.tv_sec  = ms / 1000;
    tv.tv_usec = (ms % 1000) * 1000;
    return ::setsockopt(s, SOL_SOCKET, opt, &tv, sizeof(tv));
}

inline int  io_send(socket_t s, const char* p, int n) { return (int)::send(s, p, (size_t)n, 0); }
inline int  io_recv(socket_t s, char* p, int n)       { return (int)::recv(s, p, (size_t)n, 0); }
inline int  io_sendto(socket_t s, const char* p, int n, const sockaddr* to, int tolen) {
    return (int)::sendto(s, p, (size_t)n, 0, to, (socklen_t)tolen);
}
inline int  io_recvfrom(socket_t s, char* p, int n, sockaddr* from, int* fromlen) {
    socklen_t sl = fromlen ? (socklen_t)*fromlen : 0;
    const int r = (int)::recvfrom(s, p, (size_t)n, 0, from, fromlen ? &sl : nullptr);
    if (fromlen) *fromlen = (int)sl;
    return r;
}
inline int  io_accept(socket_t s, sockaddr* a, int* alen) {
    socklen_t sl = alen ? (socklen_t)*alen : 0;
    const int r = (int)::accept(s, a, alen ? &sl : nullptr);
    if (alen) *alen = (int)sl;
    return r;
}
inline int  io_bind(socket_t s, const sockaddr* a, int alen)    { return ::bind(s, a, (socklen_t)alen); }
inline int  io_connect(socket_t s, const sockaddr* a, int alen) { return ::connect(s, a, (socklen_t)alen); }
inline int  io_listen(socket_t s, int backlog) { return ::listen(s, backlog); }
inline int  io_getsockname(socket_t s, sockaddr* a, int* alen) {
    socklen_t sl = alen ? (socklen_t)*alen : 0;
    const int r = ::getsockname(s, a, alen ? &sl : nullptr);
    if (alen) *alen = (int)sl;
    return r;
}

// 加入 SSDP 组播组 239.255.255.250。ifaddr 为 nullptr 表示让内核选接口。
// macOS/POSIX 上这是收到"回给组播地址的应答"的必要条件（Linux 的默认行为更宽松，
// 但显式加入在两平台都正确且无害）。
// 把 socket 钉到指定本地地址所在的网卡（IP_BOUND_IF）。
// 为什么需要：本机若有同网段的虚拟/共享接口（如 macOS「Internet 共享」的 bridge100，
// 路由标志带 REJECT），内核会优先选它，导致 sendto 直接 EHOSTUNREACH —— SSDP 一台都搜不到。
// IP_MULTICAST_IF 只改组播出口，改不了内核的单播路由选择，所以必须用 IP_BOUND_IF。
// 非 macOS/BSD 平台没有 IP_BOUND_IF，退化为 no-op（Windows 由已有分支处理）。
// 把 socket 钉到指定网卡（IP_BOUND_IF，macOS/BSD 专有）。
// 为什么需要：本机若有同网段的虚拟/共享接口（如 macOS「Internet 共享」的 bridge100，
// 路由标志带 REJECT），内核会优先选它，导致 sendto/connect 直接 EHOSTUNREACH ——
// SSDP 一台都搜不到、设备描述也抓不到。IP_MULTICAST_IF 只改组播出口，
// 改不了内核的单播路由选择，所以必须用 IP_BOUND_IF。
// 2026-10-28 真机补记：**不要**再额外 bind(本机 IP)。本机 IP 落在被 REJECT 抢走的
// 那个网段里时，源地址选择会重新走一遍路由表，bind 过的 socket 反而 EHOSTUNREACH
//（实测同一目标：bind+pin 失败、只 pin 成功）。所以全链路只用 IP_BOUND_IF，不 bind。
inline bool pin_to_interface(socket_t s, int ifindex) {
#if defined(__APPLE__) || defined(__FreeBSD__)
    if (ifindex <= 0) return false;
    return ::setsockopt(s, IPPROTO_IP, IP_BOUND_IF, &ifindex, sizeof(ifindex)) == 0;
#else
    (void)s; (void)ifindex;
    return false;
#endif
}

// 本机 IPv4 网卡（只保留可用的物理网卡；虚拟/桥接/回环一律剔掉）
struct UpnpIface {
    std::string name;      // en1
    std::string ip;        // 192.168.3.163
    std::string mask;      // 255.255.255.0
    std::string net;       // 192.168.3.0
    std::string bcast;     // 192.168.3.255（无广播地址时为空）
    int         ifindex = 0;
};

inline int mask_prefix_len(const std::string& mask) {
    struct in_addr a{};
    if (::inet_aton(mask.c_str(), &a) == 0) return 0;
    uint32_t v = ntohl(a.s_addr);
    int n = 0;
    while (v & 0x80000000u) { ++n; v <<= 1; }
    return n;
}

inline bool ip_in_subnet(const std::string& hostIp, const std::string& net, const std::string& mask) {
    struct in_addr h{}, n{}, m{};
    if (::inet_aton(hostIp.c_str(), &h) == 0) return false;
    if (::inet_aton(net.c_str(), &n) == 0) return false;
    if (::inet_aton(mask.c_str(), &m) == 0) return false;
    return (h.s_addr & m.s_addr) == (n.s_addr & m.s_addr);
}

// 枚举本机 IPv4 网卡。
// 为什么不用 gethostname()+getaddrinfo：macOS 返回 "Mac.local"，AF_INET 查询通常只回
// 127.0.0.1（甚至失败），结果就是"只剩回环、全部被过滤" → 组播只从默认路由出去。
// getifaddrs() 直接遍历内核的网卡地址表，才是 POSIX 的等价做法。
// 剔除规则（2026-10-28 真机）：bridge*（Internet 共享/桥接）、utun*/awdl*/llw*/anpi*/ap*
// 不参与发现 —— 它们要么没有真实链路，要么把 192.168.3.0/24 抢成了 REJECT 路由；
// 198.18/198.19（Clash 等代理 TUN 的 fake-IP 段）记录到 skipped 后跳过。
inline std::vector<UpnpIface> upnp_ifaces(std::vector<std::string>* skipped = nullptr) {
    std::vector<UpnpIface> out;
    struct ifaddrs* ifs = nullptr;
    if (::getifaddrs(&ifs) != 0) return out;
    for (struct ifaddrs* p = ifs; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET) continue;
        char ipbuf[64] = {0};
        const sockaddr_in* sa = (const sockaddr_in*)p->ifa_addr;
        if (::inet_ntop(AF_INET, &sa->sin_addr, ipbuf, sizeof(ipbuf)) == nullptr) continue;
        const std::string sip(ipbuf);
        if (sip.rfind("127.", 0) == 0 || sip.rfind("169.254.", 0) == 0) continue;
        const std::string nm = p->ifa_name ? p->ifa_name : "";
        const bool virtual_name =
            nm.rfind("bridge", 0) == 0 || nm.rfind("utun", 0) == 0 ||
            nm.rfind("awdl", 0) == 0 || nm.rfind("llw", 0) == 0 ||
            nm.rfind("anpi", 0) == 0 || nm.rfind("ap", 0) == 0 ||
            nm.rfind("gif", 0) == 0 || nm.rfind("stf", 0) == 0 ||
            nm.rfind("vmenet", 0) == 0;
        const bool proxy_tun = (sip.rfind("198.18.", 0) == 0 || sip.rfind("198.19.", 0) == 0);
        if (virtual_name || proxy_tun) {
            if (skipped) skipped->push_back(nm + " " + sip + (proxy_tun ? "(代理 TUN)" : "(虚拟/桥接)"));
            continue;
        }
        bool dup = false;
        for (const auto& e : out) if (e.ip == sip) dup = true;
        if (dup) continue;

        UpnpIface f;
        f.name    = nm;
        f.ip      = sip;
        f.ifindex = (int)::if_nametoindex(nm.c_str());

        const sockaddr_in* mk = (const sockaddr_in*)p->ifa_netmask;
        char mkbuf[64] = {0};
        if (mk) ::inet_ntop(AF_INET, &mk->sin_addr, mkbuf, sizeof(mkbuf));
        f.mask = mkbuf;
        const uint32_t ipn = ntohl(sa->sin_addr.s_addr);
        const uint32_t mkn = mk ? ntohl(mk->sin_addr.s_addr) : 0xffffff00u;
        struct in_addr a{};
        a.s_addr = htonl(ipn & mkn);
        char netbuf[64] = {0};
        ::inet_ntop(AF_INET, &a, netbuf, sizeof(netbuf));
        f.net = netbuf;
        // 广播地址：优先用内核给的（只有 IFF_BROADCAST 才填 ifa_dstaddr），否则按掩码算
        char bbuf[64] = {0};
        if ((p->ifa_flags & IFF_BROADCAST) && p->ifa_dstaddr && p->ifa_dstaddr->sa_family == AF_INET) {
            ::inet_ntop(AF_INET, &((const sockaddr_in*)p->ifa_dstaddr)->sin_addr, bbuf, sizeof(bbuf));
        } else if (mkn) {
            a.s_addr = htonl((ipn & mkn) | ~mkn);
            ::inet_ntop(AF_INET, &a, bbuf, sizeof(bbuf));
        }
        f.bcast = bbuf;
        out.push_back(f);
    }
    ::freeifaddrs(ifs);
    return out;
}

inline bool join_multicast(socket_t s, const in_addr* ifaddr) {
    ip_mreq mreq{};
    mreq.imr_multiaddr.s_addr = ::inet_addr("239.255.255.250");
    mreq.imr_interface = ifaddr ? *ifaddr : in_addr{ htonl(INADDR_ANY) };
    return ::setsockopt(s, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof(mreq)) == 0;
}

// 等待一组 socket 中任意一个可读，返回可读者的下标；超时单位微秒。
// POSIX 上用 poll()：不受 FD_SETSIZE(1024) 限制，也不要求"最大 fd + 1"。
inline std::vector<size_t> wait_readable(const std::vector<socket_t>& socks, int timeoutUs) {
    std::vector<size_t> ready;
    if (socks.empty()) return ready;
    std::vector<struct pollfd> pfds(socks.size());
    for (size_t i = 0; i < socks.size(); ++i) {
        pfds[i].fd = socks[i];
        pfds[i].events = POLLIN;
        pfds[i].revents = 0;
    }
    const int rc = ::poll(pfds.data(), (nfds_t)pfds.size(), timeoutUs / 1000);
    if (rc <= 0) return ready;
    for (size_t i = 0; i < pfds.size(); ++i) if (pfds[i].revents & POLLIN) ready.push_back(i);
    return ready;
}

// POSIX 上 64 位偏移就是 fseeko/ftello（macOS 的 off_t 已是 64 位）
inline int    file_seek(FILE* f, int64_t off) { return ::fseeko(f, (off_t)off, SEEK_SET); }
inline int64_t file_tell(FILE* f)            { return (int64_t)::ftello(f); }
inline int64_t file_size(FILE* f) {
    if (!f) return 0;
    if (::fseeko(f, 0, SEEK_END) != 0) return 0;
    const int64_t n = (int64_t)::ftello(f);
    ::fseeko(f, 0, SEEK_SET);
    return n;
}

// 用平台层的单调时钟（platform/macos/time_posix.h），语义 = GetTickCount64()：
// 开机以来毫秒、单调、不回退。不偷换 std::chrono::steady_clock（epoch 由实现定义）。
inline uint64_t monotonic_ms() { return rta::platform::monotonic_ms(); }


} // namespace rta::net::upnp_os

namespace rta::net {

struct UpnpDevice {
    std::string name;              // friendlyName
    std::string model;             // modelName
    std::string udn;
    std::string location;          // 设备描述 URL
    std::string host;
    int         port = 0;
    std::string control;           // AVTransport 控制地址（相对或绝对）
    std::string controlConnection; // ConnectionManager 控制地址（相对或绝对）
    std::string controlRendering;  // RenderingControl 控制地址（相对或绝对）
    // 设备是从哪张网卡发现的：后续抓描述/发 SOAP 都钉回这张卡。
    // 2026-10-28 真机：本机路由把局域网段交给同网段的 bridge100（REJECT），
    // 不钉网卡的 connect 会 EHOSTUNREACH —— "找到了设备却控制不了"就是这来的。
    std::string ifname;
    int         ifindex = 0;

    std::string av_transport_url() const {
        return resolve_url(location, control);
    }
    std::string connection_manager_url() const {
        return resolve_url(location, controlConnection);
    }
    std::string rendering_control_url() const {
        if (controlRendering.empty()) return "";
        return resolve_url(location, controlRendering);
    }
};

namespace upnp_detail {
inline std::string lower(std::string s) { for (auto& c : s) c = (char)std::tolower((unsigned char)c); return s; }
inline std::string trim2(const std::string& s) {
    const size_t a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) return "";
    const size_t b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
}
inline std::string header_of(const std::string& msg, const char* key) {
    const std::string l = lower(msg), k = lower(std::string(key) + ":");
    size_t p = l.find(k);
    if (p == std::string::npos) return "";
    p += k.size();
    const size_t e = msg.find('\n', p);
    return trim2(msg.substr(p, (e == std::string::npos ? msg.size() : e) - p));
}
inline std::string xml_tag(const std::string& xml, const char* tag) {
    const std::string open = std::string("<") + tag + ">";
    const std::string close = std::string("</") + tag + ">";
    size_t p = xml.find(open);
    if (p == std::string::npos) return "";
    p += open.size();
    const size_t e = xml.find(close, p);
    if (e == std::string::npos) return "";
    return trim2(xml.substr(p, e - p));
}

// 在 XML 的 <serviceList> 中查找指定 serviceType 对应的 <controlURL>
inline std::string extract_service_control_url(const std::string& xml, const char* serviceSubstr) {
    size_t p = xml.find(serviceSubstr);
    if (p == std::string::npos) return "";
    size_t c2 = xml.find("<controlURL>", p);
    if (c2 == std::string::npos) return "";
    size_t e2 = xml.find("</controlURL>", c2);
    if (e2 == std::string::npos) return "";
    return trim2(xml.substr(c2 + 12, e2 - c2 - 12));
}

// ifindex>0 时把连接钉在该网卡上（macOS 上同网段虚拟网卡会把单播路由抢走，
// 不钉的话"设备明明在线却抓不到描述"）。ifindex=0 表示交给内核选路。
inline bool http_get(const std::string& host, int port, const std::string& path, std::string& out,
                     int ifindex = 0, int connectTimeoutMs = 800) {
    // 回环目标不钉网卡：把 socket 钉在 en1 上去连 127.0.0.1 会失败（本机自测会走到这条）。
    if (host.rfind("127.", 0) == 0 || host == "localhost") ifindex = 0;
    const bool wsaInit = upnp_os::wsa_init();
    upnp_os::socket_t s = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s != upnp_os::kInvalidSocket) upnp_os::pin_to_interface(s, ifindex);
    if (s == upnp_os::kInvalidSocket) {
        if (wsaInit) upnp_os::wsa_cleanup();
        return false;
    }
    // ★ 2026-10-28 真机事故（界面永远停在「正在发现渲染器…」，一台设备都不出现）：
    //   Rygel（`MR4 音响 [DLNA/UPnP]`）同时从 **192.168.3.29** 和 **192.168.5.29** 两个地址
    //   应答 SSDP，而本机没有到 192.168.5.0/24 的路由 ⟹ 对后者的**阻塞 connect** 会卡满
    //   内核 SYN 重传预算（数十秒），期间 CastManager 的 devMutex_ 一直被占着，
    //   下一次 /api/cast/devices 直接挂在锁上 ⟹ 界面永远"正在发现"，超时后也不报错。
    //   修法：非阻塞 connect + poll 超时（默认 800ms）；连不上就只放弃这一台。
    if (!upnp_os::set_nonblocking(s)) {
        upnp_os::close_socket(s);
        if (wsaInit) upnp_os::wsa_cleanup();
        return false;
    }
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons((u_short)port);
    a.sin_addr.s_addr = ::inet_addr(host.c_str());
    bool connected = false;
    const int rc = upnp_os::io_connect(s, (sockaddr*)&a, sizeof(a));
    if (rc == 0) {
        connected = true;
    } else if (errno == EINPROGRESS || errno == EWOULDBLOCK) {
        struct pollfd pfd{};
        pfd.fd = s;
        pfd.events = POLLOUT;
        const int pr = ::poll(&pfd, 1, connectTimeoutMs);
        if (pr > 0) {
            int soErr = 0;
            socklen_t el = sizeof(soErr);
            if (::getsockopt(s, SOL_SOCKET, SO_ERROR, &soErr, &el) == 0 && soErr == 0) connected = true;
        }
    }
    if (!connected) {
        upnp_os::close_socket(s);
        if (wsaInit) upnp_os::wsa_cleanup();
        return false;
    }
    // 连上后恢复阻塞模式，用 SO_RCVTIMEO/SO_SNDTIMEO 兜住读写
    {
        const int fl = ::fcntl(s, F_GETFL, 0);
        if (fl >= 0) (void)::fcntl(s, F_SETFL, fl & ~O_NONBLOCK);
    }
    upnp_os::set_timeout(s, SO_RCVTIMEO, 1500);
    upnp_os::set_timeout(s, SO_SNDTIMEO, 1500);
    char req[512];
    std::snprintf(req, sizeof(req),
                  "GET %s HTTP/1.1\r\nHost: %s:%d\r\nConnection: close\r\nUser-Agent: RLPlayer/1\r\n\r\n",
                  path.c_str(), host.c_str(), port);
    if (upnp_os::io_send(s, req, (int)std::strlen(req)) <= 0) {
        upnp_os::close_socket(s);
        if (wsaInit) upnp_os::wsa_cleanup();
        return false;
    }
    char buf[8192];
    int r;
    out.clear();
    while ((r = upnp_os::io_recv(s, buf, sizeof(buf))) > 0) {
        out.append(buf, (size_t)r);
        if (out.size() > 524288) break;
    }
    upnp_os::close_socket(s);
    if (wsaInit) upnp_os::wsa_cleanup();
    return !out.empty();
}

// ---------------- 供源发送：整块发完（2026-10-25，外部评审 P0-B）----------------
// 现场形态（本文件旧 792-795 行）：文件分支把 fread 的【一整块】交给一次 send，
// 返回值 nSend < nRead 时块尾直接丢弃，下一轮 fread 读的却是文件的【下一块】。
// 阻塞 socket 也会部分发送（内核发送缓冲满 / SO_SNDTIMEO），于是：
//   丢掉的字节数 = 块尾那几十 KB 里的任意几个 ⟹ 之后的流从那里开始整体错位。
// 对 WAV 这种"按字节解释采样"的格式，错位 = 从错位点起整条流变成噪声，
// 而且 Content-Length 依然对得上（对端不会报错），是最难从日志看出来的形态。
// 缓冲分支（旧 801-805 行）当年写对了，但它在 nSend<=0 时同样直接 break，
// EWOULDBLOCK 一出现就截断 —— 所以两条分支现在共用下面这一份实现。
//
// 约定（调用方负责把平台错误码映射成这三态）：
//   > 0 本次实际发出的字节数（可能远小于请求量）
//     0 暂时发不出去（EWOULDBLOCK / EAGAIN / EINTR 之类），可短暂等待后重试
//    -1 永久错误（对端关闭 / 其它 socket 错误），放弃这一块
// 用模板而不是 std::function：供源每个 64KB 块要调用上千次，且测试要能塞桩。
template <class SendOnce, class SleepMs>
inline size_t send_block_all(SendOnce&& sendOnce, const char* buf, size_t len,
                             SleepMs&& sleepMs, const std::atomic<bool>* stop,
                             int stallBudgetMs = 5000) {
    size_t done = 0;
    int stalledMs = 0;
    while (done < len) {
        if (stop && stop->load()) break;
        const size_t left = len - done;
        const int ask = (int)std::min<size_t>(left, (size_t)1u << 20);   // 单次最多 1 MiB
        const int r = sendOnce(buf + done, ask);
        if (r > 0) {
            done += (size_t)r;
            stalledMs = 0;
            continue;
        }
        if (r < 0) break;                       // 永久错误：这一块发不完了
        if (++stalledMs > stallBudgetMs) break; // 1ms/次 ⟹ 迭代次数 ≈ 毫秒预算
        sleepMs(1);
    }
    return done;
}

// ★ 文件供源主循环（生产 handle_client 的 isFile 分支直接调用它，不是测试另抄一份）：
// 读一块 → 整块发完 → 下一块。返回实际发出的字节数。
// 关键不变量：某块没发完就【立刻停止】，绝不再读下一块 —— 否则又是旧实现那种块间丢字节。
template <class SendOnce, class SleepMs>
inline int64_t pump_file(std::FILE* f, int64_t toSend, size_t chunkBytes,
                         SendOnce&& sendOnce, SleepMs&& sleepMs,
                         const std::atomic<bool>* stop, int stallBudgetMs = 5000) {
    if (!f || toSend <= 0) return 0;
    if (chunkBytes == 0) chunkBytes = 65536;
    std::vector<unsigned char> chunk(chunkBytes);
    int64_t sent = 0;
    while (toSend > 0) {
        if (stop && stop->load()) break;
        const size_t want = (size_t)std::min<int64_t>(toSend, (int64_t)chunk.size());
        const size_t got = std::fread(chunk.data(), 1, want, f);
        if (got == 0) break;                    // EOF / 读错误
        const size_t ok = send_block_all(sendOnce, (const char*)chunk.data(), got,
                                        sleepMs, stop, stallBudgetMs);
        sent += (int64_t)ok;
        toSend -= (int64_t)ok;
        if (ok < got) break;                    // ★ 本块没发完 = 连接已废，不能再读下一块
    }
    return sent;
}

// 内存缓冲供源：同一套"整块发完"语义（不分块读，只分次 send）。
template <class SendOnce, class SleepMs>
inline int64_t pump_buffer(const unsigned char* data, int64_t toSend,
                           SendOnce&& sendOnce, SleepMs&& sleepMs,
                           const std::atomic<bool>* stop, int stallBudgetMs = 5000) {
    if (!data || toSend <= 0) return 0;
    return (int64_t)send_block_all(sendOnce, (const char*)data, (size_t)toSend,
                                   sleepMs, stop, stallBudgetMs);
}
} // namespace upnp_detail

// 发一次 SSDP M-SEARCH，收集 MediaRenderer。timeoutMs 建议 1500~2500。
//
// 2026-10-23（用户 261023-04 #11「UPnP 搜不到我的设备，现在应该还开着」）：
//   旧实现只在"默认路由"上发一次组播。本机装了 Clash Verge TUN（198.18.0.0/15 fake-IP）后，
//   默认路由指向 TUN 虚拟网卡，组播包进了隧道 → 局域网设备永远收不到 M-SEARCH（这正是我们复现到的
//   /api/upnp → n=0）。修法：枚举所有本机 IPv4，逐个网卡设置 IP_MULTICAST_IF 并发送 2 次，
//   再一起收响应；同时给出诊断信息（找到几个网卡、哪些被跳过），供 UI 如实显示。
// 发 M-SEARCH 并收集 MediaRenderer。timeoutMs 建议 1500~2500。
//
// 2026-10-28 真机事故（用户「UPnP 搜不到设备」，macOS 27 / Apple M4）：
//   本机开着「Internet 共享」，系统里多出一个同网段的 bridge100（192.168.3.1/24），
//   路由表因此变成：
//       192.168.3    link#20  UC    bridge100  !     ← 整个局域网被抢走（REJECT）
//       224.0.0/4    link#16  UmCS  en1        !     ← 组播也被标 REJECT
//   实测：向 192.168.3.x 的 connect 是 EHOSTUNREACH —— 只有把 socket 用 IP_BOUND_IF
//   钉到 en1 才通；同一环境里向 239.255.255.250 的 sendto 也报 EHOSTUNREACH。
//   ⚠️ 后续复核（同一天）：组播那条**只在被沙箱约束的 shell 进程里复现**，
//   普通用户进程（su 直启）组播/广播都正常；路由劫持那条（192.168.3.0/24 → bridge100）
//   是真实且系统级的。两个成因都要按"可能发生"处理，但别混为一谈。
//   修法（三件，全部实测过）：
//     ① 逐张物理网卡 pin（IP_BOUND_IF），不 bind 本机 IP；
//     ② 组播之外**同时发子网广播**（<broadcast>:1900）—— 广播走同网段直连，
//        不受 224/4 的 REJECT 影响。实测 192.168.3.255:1900 能收到路由器 IGD 的应答；
//     ③ 诊断如实写清：哪张卡、发了几包、失败的 errno。
struct UpnpDiscoverDiag {
    int ifaces_tried = 0;
    int msgs_sent = 0;        // 成功发出的 M-SEARCH 包数（组播 + 广播）
    int multicast_sent = 0;
    int broadcast_sent = 0;
    int extra_sent = 0;       // 额外单播目标（测试/诊断用）发出的包数
    int send_failed = 0;      // sendto 返回错误的次数
    int replies = 0;          // 收到的 SSDP 应答数（含重复）
    int describe_failed = 0;  // 应答里的 LOCATION 抓不到设备描述
    std::string note;         // 人话诊断（UI 直接显示）
};

// 兼容旧调用：只回本机 IPv4 列表（发现流程已改用 upnp_ifaces()）
inline std::vector<std::string> upnp_local_ipv4(std::vector<std::string>* skipped = nullptr) {
    std::vector<std::string> out;
    std::vector<std::string> sk;
    for (const auto& f : upnp_os::upnp_ifaces(&sk)) out.push_back(f.ip);
    if (skipped) *skipped = sk;
    return out;
}

// extraHosts：额外单播探测的主机（**只给测试/诊断用**；生产流程不用）。
// 为什么需要它：macOS 上把 socket 钉到 en1 之后，发往"本机自己的局域网地址"或子网广播的
// 包不会再回送给本机其它进程（实测：跨进程收不到，同进程才收得到）。这意味着
// "本机假渲染器 + 广播" 无法作为自动化判据，只能用 127.0.0.1 单播验证
// "收包 → 解析 LOCATION → 抓描述" 这一段。真实广播发送另有真机证据（见 docs/）。
inline std::vector<UpnpDevice> upnp_discover(int timeoutMs = 1800, UpnpDiscoverDiag* diag = nullptr,
                                             int ssdpPort = 1900,
                                             const std::vector<std::string>* extraHosts = nullptr) {
    using namespace upnp_detail;
    std::vector<UpnpDevice> out;
    if (diag) *diag = UpnpDiscoverDiag{};

    std::vector<std::string> skipped;
    std::vector<upnp_os::UpnpIface> ifaces = upnp_os::upnp_ifaces(&skipped);

    const char* msg =
        "M-SEARCH * HTTP/1.1\r\n"
        "HOST: 239.255.255.250:1900\r\n"
        "MAN: \"ssdp:discover\"\r\n"
        "MX: 1\r\n"
        "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n";

    sockaddr_in toM{};
    toM.sin_family = AF_INET;
    toM.sin_port = htons((unsigned short)ssdpPort);
    toM.sin_addr.s_addr = ::inet_addr("239.255.255.250");

    struct Chan { upnp_os::socket_t s; upnp_os::UpnpIface f; };
    std::vector<Chan> chans;
    std::vector<std::string> sendErrs;

    auto note_err = [&](const std::string& tag) {
        const std::string e = std::string(tag) + " " + std::string(std::strerror(errno));
        for (const auto& x : sendErrs) if (x == e) return;
        sendErrs.push_back(e);
    };

    if (ifaces.empty()) {
        // 一张物理网卡都没有（拔网线/只剩回环）：退回"让内核选路"的老行为，至少不崩
        upnp_os::UpnpIface f;
        f.name = "(默认路由)";
        f.ifindex = 0;
        ifaces.push_back(f);
    }

    for (const auto& f : ifaces) {
        upnp_os::socket_t s = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (s == upnp_os::kInvalidSocket) {
            if (diag) diag->send_failed++;
            continue;
        }
        const int one = 1;
        upnp_os::set_opt(s, SOL_SOCKET, SO_BROADCAST, &one, sizeof(one));
        if (!f.ip.empty()) {
            upnp_os::pin_to_interface(s, f.ifindex);
            in_addr ifaddr{};
            ifaddr.s_addr = ::inet_addr(f.ip.c_str());
            upnp_os::set_opt(s, IPPROTO_IP, IP_MULTICAST_IF, &ifaddr, sizeof(ifaddr));
            // 加入 SSDP 组播组：POSIX/macOS 上必须显式 IP_ADD_MEMBERSHIP，
            // 否则收不到渲染器回给 239.255.255.250:1900 的应答。
            upnp_os::join_multicast(s, &ifaddr);
        } else {
            upnp_os::join_multicast(s, nullptr);
        }

        const int len = (int)std::strlen(msg);
        for (int rep = 0; rep < 3; ++rep) {
            if (upnp_os::io_sendto(s, msg, len, (sockaddr*)&toM, sizeof(toM)) > 0) {
                if (diag) { diag->msgs_sent++; diag->multicast_sent++; }
            } else if (diag) {
                diag->send_failed++;
                note_err("组播");
            }
            if (!f.bcast.empty()) {
                sockaddr_in toB = toM;
                toB.sin_addr.s_addr = ::inet_addr(f.bcast.c_str());
                if (upnp_os::io_sendto(s, msg, len, (sockaddr*)&toB, sizeof(toB)) > 0) {
                    if (diag) { diag->msgs_sent++; diag->broadcast_sent++; }
                } else if (diag) {
                    diag->send_failed++;
                    note_err("广播");
                }
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(60));
        }
        chans.push_back(Chan{s, f});
        if (diag) diag->ifaces_tried++;
    }

    // 额外单播目标（测试/诊断）：不钉网卡 —— 钉了就到不了 127.0.0.1
    if (extraHosts && !extraHosts->empty()) {
        upnp_os::socket_t s = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (s != upnp_os::kInvalidSocket) {
            upnp_os::UpnpIface f;
            f.name = "(单播目标)";
            for (const auto& host : *extraHosts) {
                sockaddr_in to = toM;
                to.sin_addr.s_addr = ::inet_addr(host.c_str());
                for (int rep = 0; rep < 2; ++rep) {
                    if (upnp_os::io_sendto(s, msg, (int)std::strlen(msg), (sockaddr*)&to, sizeof(to)) > 0) {
                        if (diag) { diag->msgs_sent++; diag->extra_sent++; }
                    } else if (diag) {
                        diag->send_failed++;
                    }
                    std::this_thread::sleep_for(std::chrono::milliseconds(20));
                }
            }
            chans.push_back(Chan{s, f});
        }
    }

    const uint64_t t0 = upnp_os::monotonic_ms();
    std::vector<upnp_os::socket_t> socks;
    for (const auto& c : chans) socks.push_back(c.s);

    while (upnp_os::monotonic_ms() - t0 < (uint64_t)timeoutMs && !socks.empty()) {
        const std::vector<size_t> ready = upnp_os::wait_readable(socks, 150000);
        if (ready.empty()) continue;
        for (size_t si : ready) {
            if (si >= chans.size()) continue;
            char buf[8192];
            sockaddr_in from{};
            int fl = sizeof(from);
            const int n = upnp_os::io_recvfrom(socks[si], buf, sizeof(buf), (sockaddr*)&from, &fl);
            if (n <= 0) continue;
            if (diag) diag->replies++;
            const std::string resp(buf, (size_t)n);
            const std::string loc = header_of(resp, "LOCATION");
            if (loc.empty()) continue;

            const std::string lowerLoc = lower(loc);
            if (lowerLoc.rfind("http://", 0) != 0) continue;
            const size_t hs = 7;
            const size_t slash = loc.find('/', hs);
            const std::string hostport = loc.substr(hs, (slash == std::string::npos ? loc.size() : slash) - hs);
            const std::string path = (slash == std::string::npos) ? "/" : loc.substr(slash);
            std::string host = hostport;
            int port = 80;
            const size_t colon = hostport.find(':');
            if (colon != std::string::npos) {
                host = hostport.substr(0, colon);
                port = atoi(hostport.c_str() + colon + 1);
            }

            bool dup = false;
            for (auto& d : out) if (d.location == loc) { dup = true; break; }
            if (dup) continue;

            UpnpDevice dev;
            dev.location = loc;
            dev.host = host;
            dev.port = port;
            dev.ifname = chans[si].f.name;
            dev.ifindex = chans[si].f.ifindex;

            std::string xml;
            // 描述抓取同样要钉在同一张网卡上：本机路由把 192.168.3.0/24 交给 bridge100
            // 时，不钉的 connect 直接 EHOSTUNREACH（"找到了但名字是 IP"的老现象）。
            // 总预算保护：发现是"快照"，不能因为某台设备不可达把整个请求拖住
            const uint64_t spent = upnp_os::monotonic_ms() - t0;
            const int remainMs = (int)((uint64_t)timeoutMs > spent ? (uint64_t)timeoutMs - spent : 0);
            bool got = false;
            if (remainMs > 150) {
                const int budget = std::min(remainMs - 100, 1500);
                got = http_get(host, port, path, xml, dev.ifindex, std::min(budget, 800));
                if (!got && dev.ifindex > 0) got = http_get(host, port, path, xml, 0, std::min(budget, 800));
            }
            if (got) {
                dev.name    = xml_tag(xml, "friendlyName");
                dev.model   = xml_tag(xml, "modelName");
                dev.udn     = xml_tag(xml, "UDN");
                dev.control = extract_service_control_url(xml, "AVTransport");
                if (dev.control.empty()) dev.control = xml_tag(xml, "controlURL");
                dev.controlConnection = extract_service_control_url(xml, "ConnectionManager");
                dev.controlRendering  = extract_service_control_url(xml, "RenderingControl");
            } else if (diag) {
                diag->describe_failed++;
            }
            if (dev.name.empty()) dev.name = host;
            out.push_back(dev);
        }
    }
    for (auto& c : chans) upnp_os::close_socket(c.s);

    if (diag) {
        std::ostringstream os;
        if (ifaces.empty()) {
            os << "没有可用的 IPv4 网卡";
        } else {
            os << "网卡 ";
            for (size_t i = 0; i < ifaces.size(); ++i) {
                if (i) os << "、";
                os << ifaces[i].name << " " << ifaces[i].ip;
                const int pl = upnp_os::mask_prefix_len(ifaces[i].mask);
                if (pl > 0) os << "/" << pl;
            }
        }
        if (!skipped.empty()) {
            os << "；已跳过 ";
            for (size_t i = 0; i < skipped.size(); ++i) { if (i) os << "、"; os << skipped[i]; }
        }
        os << "；发出 " << diag->msgs_sent << " 包(组播 " << diag->multicast_sent
           << "、广播 " << diag->broadcast_sent << ")";
        if (diag->extra_sent) os << "、单播目标 " << diag->extra_sent;
        if (diag->send_failed) {
            os << "；发送失败 " << diag->send_failed << " 次(";
            for (size_t i = 0; i < sendErrs.size(); ++i) { if (i) os << "，"; os << sendErrs[i]; }
            os << ")";
        }
        os << "；收到 " << diag->replies << " 个应答";
        if (diag->describe_failed) os << "，其中 " << diag->describe_failed << " 个抓不到描述";
        bool mcast_rejected = false;
        for (const auto& e : sendErrs) if (e.find("No route to host") != std::string::npos) mcast_rejected = true;
        if (mcast_rejected) {
            os << "。组播发不出去(No route to host)：常见于「Internet 共享」把同一网段抢成虚拟网桥、"
                  "代理 TUN 抢了优先路由、或进程被沙箱限制；已用子网广播兜底";
        }
        if (out.empty()) os << "。没有设备应答 M-SEARCH";
        diag->note = os.str();
    }
    return out;
}

// 查找本机面向指定目标主机的首选局域网 IP。
// 不能再用"UDP connect 让内核选路"：本机若存在同网段虚拟网卡（bridge100），
// 内核会选它，getsockname() 拿到的是 192.168.3.1 —— 供源 URL 会指向桥接址，
// 设备根本连不上（2026-10-28 真机实测）。
// 现在的规则：优先"同网段物理网卡"的地址；否则逐卡 pin 后 connect 取源地址。
inline std::string upnp_local_ip_for(const std::string& targetHost, uint16_t targetPort = 80) {
    const auto ifaces = upnp_os::upnp_ifaces(nullptr);
    for (const auto& f : ifaces) {
        if (upnp_os::ip_in_subnet(targetHost, f.net, f.mask)) return f.ip;
    }
    for (const auto& f : ifaces) {
        upnp_os::socket_t s = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (s == upnp_os::kInvalidSocket) continue;
        upnp_os::pin_to_interface(s, f.ifindex);
        sockaddr_in dst{};
        dst.sin_family = AF_INET;
        dst.sin_port = htons(targetPort ? targetPort : 80);
        dst.sin_addr.s_addr = ::inet_addr(targetHost.c_str());
        std::string got;
        if (upnp_os::io_connect(s, (sockaddr*)&dst, sizeof(dst)) == 0) {
            sockaddr_in local{};
            int len = sizeof(local);
            char b[64] = {0};
            if (upnp_os::io_getsockname(s, (sockaddr*)&local, &len) == 0 &&
                ::inet_ntop(AF_INET, &local.sin_addr, b, sizeof(b)) != nullptr &&
                std::strcmp(b, "0.0.0.0") != 0) {
                got = b;
            }
        }
        upnp_os::close_socket(s);
        if (!got.empty()) return got;
    }
    return "127.0.0.1";
}

// ---------------- 本地 HTTP 供源服务器（WAV 流） ----------------

struct HttpAccessLog {
    std::string clientIp;
    uint16_t    clientPort = 0;
    std::string method;
    std::string path;
    std::string range;
    int         statusCode = 0;
    int64_t     bytesSent = 0;
};

class UpnpHttpServer {
public:
    UpnpHttpServer() = default;
    ~UpnpHttpServer() { stop(); }

    bool start(uint16_t port = 8912, const std::string& bindIp = "0.0.0.0") {
        stop();
        if (!upnp_os::wsa_init()) return false;
        wsaStarted_ = true;

        listen_ = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (listen_ == upnp_os::kInvalidSocket) { cleanup_wsa(); return false; }

        int yes = 1;
        upnp_os::set_opt(listen_, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

        sockaddr_in a{};
        a.sin_family = AF_INET;
        a.sin_port = htons(port);
        a.sin_addr.s_addr = (bindIp == "0.0.0.0" || bindIp.empty())
                            ? htonl(INADDR_ANY) : ::inet_addr(bindIp.c_str());

        if (upnp_os::io_bind(listen_, (sockaddr*)&a, sizeof(a)) != 0) {
            upnp_os::close_socket(listen_); listen_ = upnp_os::kInvalidSocket; cleanup_wsa(); return false;
        }
        if (upnp_os::io_listen(listen_, 16) != 0) {
            upnp_os::close_socket(listen_); listen_ = upnp_os::kInvalidSocket; cleanup_wsa(); return false;
        }

        sockaddr_in got{}; int gl = sizeof(got);
        upnp_os::io_getsockname(listen_, (sockaddr*)&got, &gl);
        port_ = ntohs(got.sin_port);

        stop_.store(false);
        acceptThread_ = std::thread([this] { loop(); });
        return true;
    }

    void stop() {
        stop_.store(true);
        if (listen_ != upnp_os::kInvalidSocket) {
            upnp_os::close_socket(listen_);
            listen_ = upnp_os::kInvalidSocket;
        }
        if (acceptThread_.joinable()) {
            acceptThread_.join();
        }
        // 等待所有正在传输的 worker 线程退出
        while (activeWorkers_.load() > 0) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        cleanup_wsa();
    }

    uint16_t port() const { return port_; }
    bool is_running() const { return !stop_.load(); }

    // 注册本地文件，返回路径 "/stream/<token>.wav"
    std::string register_file(const std::string& filePath, const std::string& mimeType = "audio/wav") {
        StreamEntry entry;
        entry.token = generate_random_token(16);
        entry.path = "/stream/" + entry.token + ".wav";
        entry.isFile = true;
        entry.filePath = filePath;
        entry.mimeType = mimeType;
        std::lock_guard<std::mutex> lk(streamMutex_);
        streams_[entry.path] = entry;
        return entry.path;
    }

    // 注册内存缓冲（用于单元测试），返回路径 "/stream/<token>.wav"
    std::string register_buffer(std::vector<uint8_t> data, const std::string& mimeType = "audio/wav") {
        StreamEntry entry;
        entry.token = generate_random_token(16);
        entry.path = "/stream/" + entry.token + ".wav";
        entry.isFile = false;
        entry.buffer = std::move(data);
        entry.mimeType = mimeType;
        std::lock_guard<std::mutex> lk(streamMutex_);
        streams_[entry.path] = entry;
        return entry.path;
    }

    void unregister_stream(const std::string& streamPath) {
        std::lock_guard<std::mutex> lk(streamMutex_);
        streams_.erase(streamPath);
    }

    int64_t total_bytes_served() const { return totalBytesServed_.load(); }
    size_t total_requests_served() const { return totalRequestsServed_.load(); }

    std::vector<HttpAccessLog> get_access_logs() const {
        std::lock_guard<std::mutex> lk(logMutex_);
        return accessLogs_;
    }

    void set_access_callback(std::function<void(const HttpAccessLog&)> cb) {
        std::lock_guard<std::mutex> lk(logMutex_);
        accessCallback_ = std::move(cb);
    }

private:
    struct StreamEntry {
        std::string token;
        std::string path;
        bool isFile = false;
        std::string filePath;
        std::vector<uint8_t> buffer;
        std::string mimeType = "audio/wav";
    };

    void cleanup_wsa() {
        if (wsaStarted_) {
            upnp_os::wsa_cleanup();
            wsaStarted_ = false;
        }
    }

    void loop() {
        while (!stop_.load()) {
            sockaddr_in clientAddr{};
            int addrLen = sizeof(clientAddr);
            upnp_os::socket_t c = upnp_os::io_accept(listen_, (sockaddr*)&clientAddr, &addrLen);
            if (c == upnp_os::kInvalidSocket) {
                if (stop_.load()) break;
                // 2026-10-25 POSIX 补丁：stop() 里 close(listen_) 会让阻塞中的 accept()
                // 立刻返回 EBADF/EINVAL（Windows 是 WSAENOTSOCK），这里同样直接退出，
                // 否则会变成一个"空转线程"，join() 永远等不到。
                const int e = upnp_os::last_error();
                if (e == EBADF || e == EINVAL || e == ENOTSOCK) break;
                continue;
            }
            char ipBuf[64]{};
            ::inet_ntop(AF_INET, &clientAddr.sin_addr, ipBuf, sizeof(ipBuf));
            std::string clientIp = ipBuf;
            uint16_t clientPort = ntohs(clientAddr.sin_port);

            activeWorkers_++;
            std::thread([this, c, clientIp, clientPort] {
                handle_client(c, clientIp, clientPort);
                activeWorkers_--;
            }).detach();
        }
    }

    void handle_client(upnp_os::socket_t c, const std::string& clientIp, uint16_t clientPort) {
        upnp_os::set_timeout(c, SO_RCVTIMEO, 4000);
        upnp_os::set_timeout(c, SO_SNDTIMEO, 4000);

        // 单次 send 的适配层（P0-B）：把平台网络错误码映射成 upnp_detail 的三态约定。
        //   EWOULDBLOCK / EAGAIN / EINTR → 0  ⟹ 短暂发不出去，等待后重试
        //   其余（含 ETIMEDOUT、对端 RST、对端正常关闭）→ -1 ⟹ 放弃，绝不装作发完了
        // 注：阻塞 socket + SO_SNDTIMEO 触发 ETIMEDOUT 时，内核实际已发出的字节数不确定，
        // 重试可能重复发送，因此按永久错误处理（宁可让对端看到短流，也不产出重复字节）。
        auto sendOnce = [c](const char* p, int n) -> int {
            const int r = upnp_os::io_send(c, p, n);
            if (r > 0) return r;
            if (r == 0) return -1;                                  // 对端已关闭
            const int e = upnp_os::last_error();
            if (upnp_os::would_block(e) || e == EINTR) return 0;   // 暂时发不出去
            return -1;
        };
        auto sleepMs = [](int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); };
        // 响应头也必须整块发完：头只发一半，对端直接解析失败
        auto sendAll = [&](const char* p, size_t n) {
            return upnp_detail::send_block_all(sendOnce, p, n, sleepMs, &stop_, 3000);
        };

        std::string reqBuf;
        char tmp[4096];
        while (reqBuf.find("\r\n\r\n") == std::string::npos && reqBuf.size() < 65536) {
            int r = upnp_os::io_recv(c, tmp, sizeof(tmp));
            if (r <= 0) break;
            reqBuf.append(tmp, (size_t)r);
        }
        if (reqBuf.empty()) {
            upnp_os::close_socket(c);
            return;
        }

        // 解析首行
        std::string method, path;
        {
            size_t firstLineEnd = reqBuf.find("\r\n");
            std::string firstLine = (firstLineEnd != std::string::npos) ? reqBuf.substr(0, firstLineEnd) : reqBuf;
            std::istringstream ls(firstLine);
            ls >> method >> path;
        }

        // 提取 Range 头
        std::string rangeHeader;
        {
            std::string lowerReq = upnp_detail::lower(reqBuf);
            size_t p = lowerReq.find("range:");
            if (p != std::string::npos) {
                size_t e = reqBuf.find('\n', p);
                rangeHeader = upnp_detail::trim2(reqBuf.substr(p + 6, (e == std::string::npos ? reqBuf.size() : e) - (p + 6)));
            }
        }

        // 查找对应 stream
        StreamEntry entry;
        bool found = false;
        {
            std::lock_guard<std::mutex> lk(streamMutex_);
            auto it = streams_.find(path);
            if (it != streams_.end()) {
                entry = it->second;
                found = true;
            }
        }

        // 校验 token 与防目录遍历
        if (!found || !validate_stream_token(path, entry.token)) {
            const char* notFoundResp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            sendAll(notFoundResp, std::strlen(notFoundResp));
            record_log(clientIp, clientPort, method, path, rangeHeader, 404, 0);
            upnp_os::close_socket(c);
            return;
        }

        int64_t totalSize = 0;
        FILE* fileHandle = nullptr;
        if (entry.isFile) {
            fileHandle = std::fopen(entry.filePath.c_str(), "rb");
            if (!fileHandle) {
                const char* notFoundResp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                sendAll(notFoundResp, std::strlen(notFoundResp));
                record_log(clientIp, clientPort, method, path, rangeHeader, 404, 0);
                upnp_os::close_socket(c);
                return;
            }
            totalSize = upnp_os::file_size(fileHandle);
            upnp_os::file_seek(fileHandle, 0);
        } else {
            totalSize = (int64_t)entry.buffer.size();
        }

        HttpRange range = parse_http_range(rangeHeader, totalSize);
        StreamResponseHeaders respHeaders = build_stream_response_headers(range, totalSize, entry.mimeType);

        sendAll(respHeaders.headerString.data(), respHeaders.headerString.size());

        int64_t sent = 0;
        if (method == "GET" && (respHeaders.statusCode == 200 || respHeaders.statusCode == 206)) {
            const int64_t toSend = respHeaders.contentLength;
            if (entry.isFile && fileHandle) {
                upnp_os::file_seek(fileHandle, respHeaders.rangeStart);
                // ★ P0-B：读一块 → **整块发完** → 再读下一块。
                // 旧实现每个块只 send 一次，部分发送时块尾字节被丢弃、下一轮读的是文件下一块
                // ⟹ 流从那里整体错位（长度还对得上，最难发现）。
                sent = upnp_detail::pump_file(fileHandle, toSend, 65536, sendOnce, sleepMs, &stop_);
            } else if (!entry.isFile) {
                sent = upnp_detail::pump_buffer(entry.buffer.data() + respHeaders.rangeStart,
                                                toSend, sendOnce, sleepMs, &stop_);
            }
        }
        if (fileHandle) std::fclose(fileHandle);

        totalBytesServed_ += sent;
        totalRequestsServed_++;
        record_log(clientIp, clientPort, method, path, rangeHeader, respHeaders.statusCode, sent);
        upnp_os::close_socket(c);
    }

    void record_log(const std::string& clientIp, uint16_t clientPort,
                    const std::string& method, const std::string& path,
                    const std::string& range, int status, int64_t sent) {
        HttpAccessLog entry;
        entry.clientIp = clientIp;
        entry.clientPort = clientPort;
        entry.method = method;
        entry.path = path;
        entry.range = range;
        entry.statusCode = status;
        entry.bytesSent = sent;
        std::lock_guard<std::mutex> lk(logMutex_);
        accessLogs_.push_back(entry);
        if (accessCallback_) accessCallback_(entry);
    }

    upnp_os::socket_t listen_ = upnp_os::kInvalidSocket;
    uint16_t port_ = 0;
    bool wsaStarted_ = false;
    std::atomic<bool> stop_{true};
    std::atomic<int> activeWorkers_{0};
    std::thread acceptThread_;

    std::map<std::string, StreamEntry> streams_;
    mutable std::mutex streamMutex_;

    std::atomic<int64_t> totalBytesServed_{0};
    std::atomic<size_t>  totalRequestsServed_{0};

    std::vector<HttpAccessLog> accessLogs_;
    std::function<void(const HttpAccessLog&)> accessCallback_;
    mutable std::mutex logMutex_;
};

} // namespace rta::net
