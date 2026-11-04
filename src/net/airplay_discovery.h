// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// airplay_discovery.h — 局域网 AirPlay(RAOP) 接收器发现（Bonjour/mDNS，只读）
//
// 契约与实现要点：
//   1) DNSServiceBrowse(_raop._tcp) + 逐个 DNSServiceResolve + DNSServiceGetAddrInfo；
//   2) 全部 socket 通过 poll() 统一轮询驱动，严禁阻塞式回调；
//   3) 目标主机地址同时支持 IPv4 与 IPv6，基于本地接口真实子网掩码确定性优选可达地址；
//   4) 同一设备 id（稳定 id）自动去重，只留一条；
//   5) 严格遵守 timeoutMs 超时语义，绝不无限阻塞；
//   6) 纯函数 parse_raop_txt、parse_service_instance 与 address selection 供离线全面测试。
#pragma once

#include <arpa/inet.h>
#include <dns_sd.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netdb.h>
#include <poll.h>
#include <unistd.h>

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <map>
#include <memory>
#include <algorithm>
#include <cctype>

namespace rta::net {

namespace airplay_detail {

struct LocalIpv4Subnet {
    std::string ifName;
    uint32_t ip = 0;       // host byte order
    uint32_t mask = 0;     // host byte order
    uint32_t subnet = 0;   // host byte order (ip & mask)
    bool isLoopback = false;
};

// 解析点分十进制 IPv4 到主机字节序 uint32_t，带严格数字校验
inline bool parse_ipv4_host(const std::string& ipStr, uint32_t& outHostOrder) {
    struct in_addr in;
    if (::inet_pton(AF_INET, ipStr.c_str(), &in) != 1) return false;
    outHostOrder = ntohl(in.s_addr);
    return true;
}

// 本机各 IPv4 接口的真实网络配置（IP + Netmask）
inline std::vector<LocalIpv4Subnet> local_ipv4_subnets() {
    std::vector<LocalIpv4Subnet> out;
    struct ifaddrs* ifs = nullptr;
    if (::getifaddrs(&ifs) != 0 || !ifs) return out;
    for (struct ifaddrs* p = ifs; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET) continue;
        auto* sin = reinterpret_cast<struct sockaddr_in*>(p->ifa_addr);
        if (!(p->ifa_flags & IFF_UP) || !(p->ifa_flags & IFF_RUNNING)) continue;
        if (!p->ifa_netmask || p->ifa_netmask->sa_family != AF_INET) continue;
        uint32_t ip = ntohl(sin->sin_addr.s_addr);
        auto* sinMask = reinterpret_cast<struct sockaddr_in*>(p->ifa_netmask);
        const uint32_t mask = ntohl(sinMask->sin_addr.s_addr);
        if (mask == 0) continue; // Unknown mask is not evidence of a directly connected subnet.
        LocalIpv4Subnet sub;
        sub.ifName = p->ifa_name ? p->ifa_name : "";
        sub.ip = ip;
        sub.mask = mask;
        sub.subnet = ip & mask;
        sub.isLoopback = ((ip >> 24) == 127) || ((p->ifa_flags & IFF_LOOPBACK) != 0);
        out.push_back(sub);
    }
    ::freeifaddrs(ifs);
    return out;
}

// 判断目标 IP 是否属于指定子网列表中的非回环子网
inline bool is_ip_in_local_subnets(const std::string& ipStr, const std::vector<LocalIpv4Subnet>& subnets) {
    uint32_t ip = 0;
    if (!parse_ipv4_host(ipStr, ip)) return false;
    for (const auto& sub : subnets) {
        if (sub.isLoopback) continue;
        if ((ip & sub.mask) == sub.subnet) return true;
    }
    return false;
}

// 候选地址评分（数值越小优先级越高）
// Tier 0: 处于本机活动非回环接口真实掩码子网内的 IPv4
// Tier 1: 其他常规 IPv4 单播地址（非 link-local，非 127/8）
// Tier 2: 全局或 ULA IPv6 地址（非 link-local，非 ::1）
// Tier 3: 带作用域的 link-local IPv6 地址
// Tier 4: 不带作用域的 link-local IPv6 地址（缺 scope 难路由）
// Tier 5: IPv4 link-local (169.254.0.0/16)
// Tier 6: 本机回环地址 (127.0.0.1 或 ::1)
// Tier 9: 无效 / 无法解析地址
inline int score_candidate_address(const std::string& addr, const std::vector<LocalIpv4Subnet>& subnets) {
    if (addr.empty()) return 999;

    uint32_t ip4 = 0;
    if (parse_ipv4_host(addr, ip4)) {
        if ((ip4 >> 24) == 127) return 600; // Loopback
        if ((ip4 >> 16) == 0xA9FE) return 500; // 169.254.x.x link-local
        for (const auto& sub : subnets) {
            if (sub.isLoopback) continue;
            if ((ip4 & sub.mask) == sub.subnet) {
                // Tier 0: 同网段，根据掩码长度微调（掩码越精确越优先）
                int maskBits = 0;
                uint32_t m = sub.mask;
                while (m) { maskBits += (m & 1); m >>= 1; }
                return 100 - maskBits; // 典型 /24 为 100 - 24 = 76
            }
        }
        return 150; // 其他普通 IPv4
    }

    struct in6_addr in6;
    std::string v6base = addr;
    bool hasScope = false;
    const size_t pct = addr.find('%');
    if (pct != std::string::npos) {
        v6base = addr.substr(0, pct);
        hasScope = (pct + 1 < addr.size());
    }

    if (::inet_pton(AF_INET6, v6base.c_str(), &in6) == 1) {
        if (IN6_IS_ADDR_LOOPBACK(&in6)) return 650;
        if (IN6_IS_ADDR_LINKLOCAL(&in6)) {
            return hasScope ? 300 : 400;
        }
        return 200; // 全局或 ULA IPv6
    }

    return 999;
}

// 确定性比对两个候选地址，若 a 优于 b 则返回 true
inline bool compare_addresses_deterministic(const std::string& a, const std::string& b,
                                           const std::vector<LocalIpv4Subnet>& subnets) {
    int scoreA = score_candidate_address(a, subnets);
    int scoreB = score_candidate_address(b, subnets);
    if (scoreA != scoreB) return scoreA < scoreB;
    return a < b; // 分数相同时采用字典序以确保确定性
}

// 格式化 IPv6 地址：若为 link-local 且提供了有效 interfaceIndex，则追加 "%ifname"
inline std::string format_ipv6_scoped(const struct sockaddr_in6* sin6, uint32_t interfaceIndex) {
    if (!sin6) return "";
    char buf[INET6_ADDRSTRLEN] = {0};
    if (!::inet_ntop(AF_INET6, &sin6->sin6_addr, buf, sizeof(buf))) return "";
    std::string out = buf;

    if (IN6_IS_ADDR_LINKLOCAL(&sin6->sin6_addr)) {
        uint32_t scope = sin6->sin6_scope_id;
        if (scope == 0 && interfaceIndex != 0) {
            scope = interfaceIndex;
        }
        if (scope != 0) {
            char ifname[IF_NAMESIZE] = {0};
            if (::if_indextoname(scope, ifname)) {
                out += "%";
                out += ifname;
            } else {
                out += "%";
                out += std::to_string(scope);
            }
        }
    }
    return out;
}

}  // namespace airplay_detail

struct AirPlayDevice {
    std::string id;          // 稳定 id：优先 "<mac>@<name>"，缺失时用 service instance name
    std::string name;        // 去掉 "MAC@" 前缀、去掉尾部 " [AirPlay]"
    std::string host;        // 解析出的目标主机（确定性优选后的 IP 或 DNS 主机名）
    uint16_t    port = 5000;
    uint32_t    sampleRate = 44100;
    int         channels = 2;
    int         sampleSize = 16;
    bool        password = false;
    bool        needsEncryption = false;  // Explicit et list lacks the cleartext type 0.
    bool        hasPublicKey = false;     // Public key presence alone does not require encryption.
    bool        supportsPlaintext = true; // et contains 0, or encryption capabilities are unspecified.
    bool        supportsAlac = true;      // cn contains 1, or codec capabilities are unspecified.
    std::string model;       // am=
    std::string txt;         // 原始 TXT 串（诊断用）
};

namespace airplay_detail {

inline std::string trim(const std::string& s) {
    size_t start = s.find_first_not_of(" \t\r\n\0");
    if (start == std::string::npos) return "";
    size_t end = s.find_last_not_of(" \t\r\n\0");
    return s.substr(start, end - start + 1);
}

inline bool is_valid_key_name(const std::string& s) {
    if (s.empty()) return false;
    for (char c : s) {
        if (!std::isalnum(static_cast<unsigned char>(c)) && c != '_' && c != '-') return false;
    }
    return true;
}

inline bool is_mac_prefix(const std::string& s) {
    if (s.empty()) return false;
    std::string clean;
    for (char c : s) {
        if (c != ':' && c != '-') clean += c;
    }
    if (clean.size() == 12) {
        for (char c : clean) {
            if (!std::isxdigit(static_cast<unsigned char>(c))) return false;
        }
        return true;
    }
    return false;
}

inline std::string strip_airplay_suffix(std::string name) {
    name = trim(name);
    const std::string suffix1 = " [AirPlay]";
    const std::string suffix2 = "[AirPlay]";
    if (name.size() >= suffix1.size() && name.compare(name.size() - suffix1.size(), suffix1.size(), suffix1) == 0) {
        name = trim(name.substr(0, name.size() - suffix1.size()));
    } else if (name.size() >= suffix2.size() && name.compare(name.size() - suffix2.size(), suffix2.size(), suffix2) == 0) {
        name = trim(name.substr(0, name.size() - suffix2.size()));
    }
    return name;
}

// 严格无垃圾解析无符号整数
inline bool parse_uint32_strict(const std::string& s, uint32_t& out) {
    if (s.empty()) return false;
    uint64_t val = 0;
    for (char c : s) {
        if (!std::isdigit(static_cast<unsigned char>(c))) return false;
        val = val * 10 + (c - '0');
        if (val > 0xFFFFFFFFULL) return false;
    }
    out = static_cast<uint32_t>(val);
    return true;
}

inline bool parse_int_strict(const std::string& s, int& out) {
    if (s.empty()) return false;
    int sign = 1;
    size_t i = 0;
    if (s[0] == '-') {
        sign = -1;
        i = 1;
    } else if (s[0] == '+') {
        i = 1;
    }
    if (i >= s.size()) return false;
    int64_t val = 0;
    for (; i < s.size(); ++i) {
        if (!std::isdigit(static_cast<unsigned char>(s[i]))) return false;
        val = val * 10 + (s[i] - '0');
        if (val > 0x7FFFFFFFLL) return false;
    }
    out = static_cast<int>(val * sign);
    return true;
}

// 逗号分隔的数值集合解析（例如 "0,1" -> {0, 1}）
inline std::vector<int> parse_comma_int_list(const std::string& s) {
    std::vector<int> out;
    size_t start = 0;
    while (start < s.size()) {
        size_t comma = s.find(',', start);
        std::string token = (comma == std::string::npos) ? s.substr(start) : s.substr(start, comma - start);
        std::string trimmed = trim(token);
        int v = 0;
        if (parse_int_strict(trimmed, v)) {
            out.push_back(v);
        }
        if (comma == std::string::npos) break;
        start = comma + 1;
    }
    return out;
}

} // namespace airplay_detail

// 纯函数、可离线测：解析 "k=v k=v" 形式的 RAOP TXT 到 AirPlayDevice
inline bool parse_raop_txt(const std::string& txt, AirPlayDevice& dev) {
    dev.txt = txt;
    dev.sampleRate = 44100;
    dev.channels = 2;
    dev.sampleSize = 16;
    dev.password = false;
    dev.needsEncryption = false;
    dev.hasPublicKey = false;
    dev.supportsPlaintext = true;
    dev.supportsAlac = true;
    dev.model.clear();

    if (txt.empty()) return true;

    std::vector<std::string> rawTokens;
    std::string current;
    for (size_t i = 0; i < txt.size(); ++i) {
        char c = txt[i];
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\0') {
            if (!current.empty()) {
                rawTokens.push_back(current);
                current.clear();
            }
        } else {
            current += c;
        }
    }
    if (!current.empty()) {
        rawTokens.push_back(current);
    }

    std::map<std::string, std::string> kvs;
    std::string currentKey;

    for (const auto& token : rawTokens) {
        size_t eq = token.find('=');
        if (eq != std::string::npos) {
            std::string possibleKey = token.substr(0, eq);
            if (airplay_detail::is_valid_key_name(possibleKey)) {
                currentKey = possibleKey;
                kvs[currentKey] = token.substr(eq + 1);
                continue;
            }
        }
        if (!currentKey.empty()) {
            if (!kvs[currentKey].empty()) {
                kvs[currentKey] += " ";
            }
            kvs[currentKey] += token;
        }
    }

    bool hasPk = false;
    bool etAllowsPlain = true;

    for (const auto& kv : kvs) {
        const std::string& k = kv.first;
        std::string val = airplay_detail::trim(kv.second);
        if (val.size() >= 2 && val.front() == '"' && val.back() == '"') {
            val = val.substr(1, val.size() - 2);
        }

        if (k == "sr") {
            uint32_t r = 0;
            if (airplay_detail::parse_uint32_strict(val, r) && r > 0 && r <= 768000) {
                dev.sampleRate = r;
            }
        } else if (k == "ss") {
            int s = 0;
            if (airplay_detail::parse_int_strict(val, s)) {
                if (s == 16 || s == 24 || s == 32) dev.sampleSize = s;
            }
        } else if (k == "ch") {
            int c = 0;
            if (airplay_detail::parse_int_strict(val, c)) {
                if (c >= 1 && c <= 8) dev.channels = c;
            }
        } else if (k == "pw") {
            std::string lowerVal = val;
            for (char& ch : lowerVal) ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
            dev.password = (lowerVal == "true" || lowerVal == "1" || lowerVal == "yes");
        } else if (k == "pk") {
            hasPk = !val.empty();
        } else if (k == "et") {
            auto types = airplay_detail::parse_comma_int_list(val);
            // et: 0 = none/clear, 1 = RSA/AES, 2 = FairPlay, 3 = MFi/SAP, 4 = FairPlay2.5
            etAllowsPlain = std::find(types.begin(), types.end(), 0) != types.end();
            dev.supportsPlaintext = etAllowsPlain;
        } else if (k == "cn") {
            auto codecs = airplay_detail::parse_comma_int_list(val);
            // cn: 0 = PCM, 1 = ALAC, 2 = AAC, 3 = AAC-ELD
            bool hasAlac = std::find(codecs.begin(), codecs.end(), 1) != codecs.end();
            dev.supportsAlac = hasAlac;
        } else if (k == "am") {
            dev.model = val;
        }
    }

    dev.hasPublicKey = hasPk;
    dev.needsEncryption = !dev.supportsPlaintext;

    return true;
}

// 纯函数、可离线测：从 service instance name 提取 id/name
inline bool parse_service_instance(const std::string& instance, AirPlayDevice& dev) {
    if (instance.empty()) {
        dev.id.clear();
        dev.name.clear();
        return false;
    }
    dev.id = instance;

    size_t atPos = instance.find('@');
    if (atPos != std::string::npos) {
        std::string prefix = instance.substr(0, atPos);
        std::string rest = instance.substr(atPos + 1);
        if (airplay_detail::is_mac_prefix(prefix) || prefix.empty()) {
            dev.name = airplay_detail::strip_airplay_suffix(rest);
        } else {
            dev.name = airplay_detail::strip_airplay_suffix(instance);
        }
    } else {
        dev.name = airplay_detail::strip_airplay_suffix(instance);
    }
    if (dev.name.empty()) {
        dev.name = dev.id;
    }
    return true;
}

namespace airplay_detail {

struct ResolveOp {
    DNSServiceRef resolveRef = nullptr;
    DNSServiceRef addrRef = nullptr;
    std::string serviceName;
    std::string regtype;
    std::string domain;
    uint32_t interfaceIndex = 0;
    AirPlayDevice dev;
    bool resolved = false;
    bool addrDone = false;
    std::string ipv4;
    std::vector<std::string> ipv4All;   // 同名主机的全部 IPv4
    std::vector<std::string> ipv6All;   // 同名主机的全部 IPv6
    std::string hosttarget;
};

// 在已有地址列表中加入新候选并根据本地网段排序选出最佳地址
inline void update_best_host(AirPlayDevice& dev,
                             const std::vector<std::string>& candidates,
                             const std::vector<LocalIpv4Subnet>& subnets,
                             const std::string& hosttargetFallback) {
    if (candidates.empty()) {
        if (dev.host.empty() && !hosttargetFallback.empty()) {
            dev.host = hosttargetFallback;
        }
        return;
    }
    std::string best = candidates[0];
    for (size_t i = 1; i < candidates.size(); ++i) {
        if (compare_addresses_deterministic(candidates[i], best, subnets)) {
            best = candidates[i];
        }
    }
    dev.host = best;
}

} // namespace airplay_detail

// 真实浏览：DNSServiceBrowse(_raop._tcp) + 逐个 resolve，超时后返回。失败/超时返回空并写 diagOut。
inline std::vector<AirPlayDevice> airplay_discover(int timeoutMs, std::string* diagOut = nullptr) {
    std::vector<AirPlayDevice> result;
    if (timeoutMs <= 0) timeoutMs = 1500;

    auto startTime = std::chrono::steady_clock::now();
    auto deadline = startTime + std::chrono::milliseconds(timeoutMs);

    const auto localSubnets = airplay_detail::local_ipv4_subnets();

    DNSServiceRef browseRef = nullptr;
    std::vector<std::shared_ptr<airplay_detail::ResolveOp>> resolveOps;

    auto browseCallback = [](DNSServiceRef /*sdRef*/, DNSServiceFlags flags, uint32_t interfaceIndex,
                             DNSServiceErrorType errorCode, const char* serviceName,
                             const char* regtype, const char* replyDomain, void* context) {
        if (errorCode != kDNSServiceErr_NoError || !serviceName) return;
        auto* ops = static_cast<std::vector<std::shared_ptr<airplay_detail::ResolveOp>>*>(context);

        if (!(flags & kDNSServiceFlagsAdd)) return;

        for (const auto& op : *ops) {
            if (op->serviceName == serviceName && op->interfaceIndex == interfaceIndex &&
                op->regtype == (regtype ? regtype : "_raop._tcp") &&
                op->domain == (replyDomain ? replyDomain : "local.")) return;
        }

        auto op = std::make_shared<airplay_detail::ResolveOp>();
        op->serviceName = serviceName;
        op->regtype = regtype ? regtype : "_raop._tcp";
        op->domain = replyDomain ? replyDomain : "local.";
        op->interfaceIndex = interfaceIndex;
        parse_service_instance(serviceName, op->dev);
        ops->push_back(op);
    };

    DNSServiceErrorType bErr = DNSServiceBrowse(&browseRef, 0, 0, "_raop._tcp", nullptr, browseCallback, &resolveOps);
    if (bErr != kDNSServiceErr_NoError || !browseRef) {
        if (diagOut) *diagOut = "DNSServiceBrowse failed with error: " + std::to_string(bErr);
        return result;
    }

    auto resolveCallback = [](DNSServiceRef /*sdRef*/, DNSServiceFlags /*flags*/, uint32_t /*interfaceIndex*/,
                              DNSServiceErrorType errorCode, const char* /*fullname*/,
                              const char* hosttarget, uint16_t port, uint16_t txtLen,
                              const unsigned char* txtRecord, void* context) {
        auto* op = static_cast<airplay_detail::ResolveOp*>(context);
        if (errorCode != kDNSServiceErr_NoError) {
            op->resolved = true;
            return;
        }
        op->dev.port = ntohs(port);
        if (hosttarget) {
            std::string ht = hosttarget;
            while (!ht.empty() && ht.back() == '.') ht.pop_back();
            if (!ht.empty()) {
                op->hosttarget = ht;
                if (op->dev.host.empty()) {
                    op->dev.host = ht;
                }
            }
        }

        // 重新拼接 TXT 字段
        std::string reconstructed;
        const unsigned char* p = txtRecord;
        const unsigned char* end = txtRecord + txtLen;
        while (p < end) {
            uint8_t len = *p++;
            if (p + len > end) break;
            std::string item(reinterpret_cast<const char*>(p), len);
            if (!reconstructed.empty()) reconstructed += " ";
            reconstructed += item;
            p += len;
        }
        parse_raop_txt(reconstructed, op->dev);
        op->resolved = true;
    };

    auto addrCallback = [](DNSServiceRef /*sdRef*/, DNSServiceFlags flags, uint32_t interfaceIndex,
                           DNSServiceErrorType errorCode, const char* /*hostname*/,
                           const struct sockaddr* address, uint32_t /*ttl*/, void* context) {
        auto* op = static_cast<airplay_detail::ResolveOp*>(context);
        if (errorCode == kDNSServiceErr_NoError && address) {
            if (address->sa_family == AF_INET) {
                char buf[INET_ADDRSTRLEN] = {0};
                if (inet_ntop(AF_INET, &((const struct sockaddr_in*)address)->sin_addr, buf, sizeof(buf))) {
                    const std::string a = buf;
                    if (std::find(op->ipv4All.begin(), op->ipv4All.end(), a) == op->ipv4All.end()) {
                        op->ipv4All.push_back(a);
                    }
                    if (op->ipv4.empty()) {
                        op->ipv4 = a;
                    }
                }
            } else if (address->sa_family == AF_INET6) {
                const auto* sin6 = reinterpret_cast<const struct sockaddr_in6*>(address);
                std::string a = airplay_detail::format_ipv6_scoped(sin6, interfaceIndex ? interfaceIndex : op->interfaceIndex);
                if (!a.empty()) {
                    if (std::find(op->ipv6All.begin(), op->ipv6All.end(), a) == op->ipv6All.end()) {
                        op->ipv6All.push_back(a);
                    }
                }
            }
        }
        if (!(flags & kDNSServiceFlagsMoreComing)) {
            op->addrDone = true;
        }
    };

    while (true) {
        auto now = std::chrono::steady_clock::now();
        if (now >= deadline) break;
        int remMs = static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count());
        if (remMs <= 0) break;

        // 为新加入的 op 发起 resolve
        for (auto& op : resolveOps) {
            if (!op->resolveRef && !op->resolved) {
                DNSServiceErrorType rErr = DNSServiceResolve(&op->resolveRef, 0, op->interfaceIndex,
                                                             op->serviceName.c_str(), op->regtype.c_str(),
                                                             op->domain.c_str(), resolveCallback, op.get());
                if (rErr != kDNSServiceErr_NoError) {
                    op->resolved = true;
                }
            }
            if (op->resolved && !op->addrRef && !op->addrDone && !op->hosttarget.empty()) {
                DNSServiceErrorType aErr = DNSServiceGetAddrInfo(&op->addrRef, 0, op->interfaceIndex,
                                                                 kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6,
                                                                 op->hosttarget.c_str(), addrCallback, op.get());
                if (aErr != kDNSServiceErr_NoError) {
                    op->addrDone = true;
                }
            }
        }

        std::vector<struct pollfd> pfds;
        std::vector<DNSServiceRef> pollRefs;

        if (browseRef) {
            int fd = DNSServiceRefSockFD(browseRef);
            if (fd >= 0) {
                pfds.push_back({fd, POLLIN, 0});
                pollRefs.push_back(browseRef);
            }
        }
        for (auto& op : resolveOps) {
            if (op->resolveRef && !op->resolved) {
                int fd = DNSServiceRefSockFD(op->resolveRef);
                if (fd >= 0) {
                    pfds.push_back({fd, POLLIN, 0});
                    pollRefs.push_back(op->resolveRef);
                }
            }
            if (op->addrRef && !op->addrDone) {
                int fd = DNSServiceRefSockFD(op->addrRef);
                if (fd >= 0) {
                    pfds.push_back({fd, POLLIN, 0});
                    pollRefs.push_back(op->addrRef);
                }
            }
        }

        if (pfds.empty()) {
            break;
        }

        int pollTimeout = std::min(remMs, 100);
        int pr = poll(pfds.data(), static_cast<nfds_t>(pfds.size()), pollTimeout);
        if (pr > 0) {
            for (size_t i = 0; i < pfds.size(); ++i) {
                if (pfds[i].revents & POLLIN) {
                    DNSServiceProcessResult(pollRefs[i]);
                }
            }
        }
    }

    if (browseRef) DNSServiceRefDeallocate(browseRef);
    for (auto& op : resolveOps) {
        if (op->resolveRef) DNSServiceRefDeallocate(op->resolveRef);
        if (op->addrRef) DNSServiceRefDeallocate(op->addrRef);
    }

    // 稳定去重：同 id 只留一条，并优选确定性最佳可达地址
    std::map<std::string, AirPlayDevice> dedupeMap;
    std::map<std::string, std::vector<std::string>> dedupeCandidates;

    for (auto& op : resolveOps) {
        if (!op->resolved) continue;

        std::vector<std::string> opCandidates;
        opCandidates.insert(opCandidates.end(), op->ipv4All.begin(), op->ipv4All.end());
        opCandidates.insert(opCandidates.end(), op->ipv6All.begin(), op->ipv6All.end());

        auto it = dedupeMap.find(op->dev.id);
        if (it == dedupeMap.end()) {
            dedupeMap[op->dev.id] = op->dev;
            dedupeCandidates[op->dev.id] = opCandidates;
        } else {
            auto& existing = it->second;
            auto& existingCandidates = dedupeCandidates[op->dev.id];
            for (const auto& c : opCandidates) {
                if (std::find(existingCandidates.begin(), existingCandidates.end(), c) == existingCandidates.end()) {
                    existingCandidates.push_back(c);
                }
            }
            if (!op->dev.txt.empty()) {
                existing.txt = op->dev.txt;
                existing.sampleRate = op->dev.sampleRate;
                existing.sampleSize = op->dev.sampleSize;
                existing.channels = op->dev.channels;
                existing.password = op->dev.password;
                existing.needsEncryption = op->dev.needsEncryption;
                existing.hasPublicKey = op->dev.hasPublicKey;
                existing.supportsPlaintext = op->dev.supportsPlaintext;
                existing.supportsAlac = op->dev.supportsAlac;
                existing.model = op->dev.model;
            }
        }
    }

    for (auto& kv : dedupeMap) {
        auto& dev = kv.second;
        const auto& candidates = dedupeCandidates[kv.first];
        airplay_detail::update_best_host(dev, candidates, localSubnets, dev.host);
        // 如果没有解析到有效 IP 或非空主机名，则不输出空 host 的畸形设备
        if (!dev.host.empty()) {
            result.push_back(dev);
        }
    }

    auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - startTime).count();
    if (diagOut) {
        *diagOut = "airplay_discover found " + std::to_string(result.size()) + " devices in " +
                   std::to_string(elapsed) + "ms";
        if (result.empty()) {
            *diagOut += " (timeout or no _raop._tcp services)";
        }
    }

    return result;
}

} // namespace rta::net
