// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_airplay_discovery.cpp — AirPlay (RAOP) mDNS 发现与 TXT/实例名/掩码选路回归测试
#include "net/airplay_discovery.h"
#include <iostream>
#include <string>
#include <vector>
#include <cstdlib>
#include <algorithm>

static int g_fail = 0;
static void ck(bool cond, const std::string& what, const std::string& detail = "") {
    if (cond) {
        std::cout << "  [PASS] " << what << std::endl;
    } else {
        std::cout << "  [FAIL] " << what << "  " << detail << std::endl;
        ++g_fail;
    }
}

int main() {
    std::cout << "=== Running test_airplay_discovery ===" << std::endl;

    // 1. parse_raop_txt 合成标准 TXT 断言（使用 RFC5737 通用安全示例，无个人私有信息）
    {
        std::cout << "[Test 1: Synthetic Generic RAOP TXT Parsing (ShairportSync)]" << std::endl;
        const std::string synthTxt = "sf=0x4 fv=76400.10 am=ShairportSync vs=105.1 tp=TCP,UDP vn=65537 "
                                     "md=0,1,2 ss=16 sr=44100 da=true sv=false et=0,1 ek=1 cn=0,1 ch=2 "
                                     "txtvers=1 pw=false";
        rta::net::AirPlayDevice dev;
        bool ok = rta::net::parse_raop_txt(synthTxt, dev);
        ck(ok, "parse_raop_txt returns true for valid TXT");
        ck(dev.sampleRate == 44100, "sampleRate == 44100", std::to_string(dev.sampleRate));
        ck(dev.sampleSize == 16, "sampleSize == 16", std::to_string(dev.sampleSize));
        ck(dev.channels == 2, "channels == 2", std::to_string(dev.channels));
        ck(dev.password == false, "password == false");
        ck(dev.hasPublicKey == false, "hasPublicKey == false (no pk=)");
        ck(dev.needsEncryption == false, "needsEncryption == false (no pk=)");
        ck(dev.supportsPlaintext == true, "supportsPlaintext == true (et=0,1)");
        ck(dev.supportsAlac == true, "supportsAlac == true (cn=0,1)");
        ck(dev.model == "ShairportSync", "model == ShairportSync", dev.model);
        ck(dev.txt == synthTxt, "txt preserved verbatim");
    }

    // 2. 严格数字与尾随垃圾对抗用例
    {
        std::cout << "[Test 2: Strict Numeric & Trailing Garbage Parsing]" << std::endl;

        // 2.1 尾随字母或垃圾字符必须拒绝并回落到默认值
        {
            rta::net::AirPlayDevice dev;
            const std::string txtGarbage = "sr=44100xyz ss=16extra ch=2garbage";
            rta::net::parse_raop_txt(txtGarbage, dev);
            ck(dev.sampleRate == 44100, "Trailing letters on sr rejected, defaults to 44100");
            ck(dev.sampleSize == 16, "Trailing letters on ss rejected, defaults to 16");
            ck(dev.channels == 2, "Trailing letters on ch rejected, defaults to 2");
        }

        // 2.2 负数与非法采样率/位深/通道
        {
            rta::net::AirPlayDevice devBogus;
            const std::string txtBogus = "sr=-44100 ss=999 ch=-1";
            rta::net::parse_raop_txt(txtBogus, devBogus);
            ck(devBogus.sampleRate == 44100, "Negative sr rejected, defaults to 44100");
            ck(devBogus.sampleSize == 16, "Bogus ss 999 rejected, defaults to 16");
            ck(devBogus.channels == 2, "Negative ch rejected, defaults to 2");
        }

        // 2.3 有效非默认值解析：sr=48000, ss=24, ch=6
        {
            rta::net::AirPlayDevice devValid;
            const std::string txt = "sr=48000 ss=24 ch=6 am=GenericReceiver";
            rta::net::parse_raop_txt(txt, devValid);
            ck(devValid.sampleRate == 48000, "Valid sr 48000 accepted");
            ck(devValid.sampleSize == 24, "Valid ss 24 accepted");
            ck(devValid.channels == 6, "Valid ch 6 accepted");
            ck(devValid.model == "GenericReceiver", "model parsed as GenericReceiver");
        }

        // 2.4 pw 布尔值严格解析（true/1/yes vs false/0/no）
        {
            rta::net::AirPlayDevice dev1, dev2, dev3, dev4;
            rta::net::parse_raop_txt("pw=true", dev1);
            ck(dev1.password == true, "pw=true sets password = true");
            rta::net::parse_raop_txt("pw=1", dev2);
            ck(dev2.password == true, "pw=1 sets password = true");
            rta::net::parse_raop_txt("pw=YES", dev3);
            ck(dev3.password == true, "pw=YES (case-insensitive) sets password = true");
            rta::net::parse_raop_txt("pw=false", dev4);
            ck(dev4.password == false, "pw=false sets password = false");
        }

        // 2.5 空 TXT 回退
        {
            rta::net::AirPlayDevice devEmpty;
            bool ok = rta::net::parse_raop_txt("", devEmpty);
            ck(ok, "parse_raop_txt on empty string returns true");
            ck(devEmpty.sampleRate == 44100, "Empty TXT defaults sampleRate to 44100");
            ck(devEmpty.sampleSize == 16, "Empty TXT defaults sampleSize to 16");
            ck(devEmpty.channels == 2, "Empty TXT defaults channels to 2");
            ck(devEmpty.password == false, "Empty TXT defaults password to false");
            ck(devEmpty.needsEncryption == false, "Empty TXT defaults needsEncryption to false");
            ck(devEmpty.hasPublicKey == false, "Empty TXT defaults hasPublicKey to false");
            ck(devEmpty.supportsPlaintext == true, "Empty TXT defaults supportsPlaintext to true");
            ck(devEmpty.supportsAlac == true, "Empty TXT defaults supportsAlac to true");
            ck(devEmpty.model.empty(), "Empty TXT defaults model to empty");
        }
    }

    // 3. 加密与编解码能力解析（pk, et, cn）
    {
        std::cout << "[Test 3: Encryption & Codec Capabilities (pk, et, cn)]" << std::endl;

        // 3.1 pk=存在：hasPublicKey = true，needsEncryption = true（旧语义兼容）
        {
            rta::net::AirPlayDevice dev;
            const std::string txt = "pk=a1b2c3d4e5f6 am=AppleDevice";
            rta::net::parse_raop_txt(txt, dev);
            ck(dev.hasPublicKey == true, "pk present sets hasPublicKey = true");
            ck(dev.needsEncryption == false, "pk alone does not require encryption");
            ck(dev.supportsPlaintext == true, "default plaintext supported when et omitted");
        }

        {
            rta::net::AirPlayDevice encryptedOnly;
            rta::net::parse_raop_txt("pk=example et=1 cn=1", encryptedOnly);
            ck(encryptedOnly.hasPublicKey && encryptedOnly.needsEncryption && !encryptedOnly.supportsPlaintext,
               "et=1 is RSA encryption, not plaintext");
            rta::net::AirPlayDevice pcmOnly;
            rta::net::parse_raop_txt("et=0 cn=0", pcmOnly);
            ck(!pcmOnly.supportsAlac, "cn=0 means PCM, not ALAC");
        }
        // 3.2 pk 存在且 et=0,1：支持明文
        {
            rta::net::AirPlayDevice dev;
            const std::string txt = "pk=a1b2c3d4e5f6 et=0,1 am=ModernDevice";
            rta::net::parse_raop_txt(txt, dev);
            ck(dev.hasPublicKey == true, "pk present sets hasPublicKey = true");
            ck(dev.needsEncryption == false, "pk alone does not require encryption");
            ck(dev.supportsPlaintext == true, "et=0,1 sets supportsPlaintext = true");
        }

        // 3.3 et=2 (仅 FairPlay，无 0 或 1)：不支持明文
        {
            rta::net::AirPlayDevice dev;
            const std::string txt = "pk=a1b2c3d4e5f6 et=2 am=LockedDevice";
            rta::net::parse_raop_txt(txt, dev);
            ck(dev.hasPublicKey == true, "pk present sets hasPublicKey = true");
            ck(dev.needsEncryption == true, "pk present sets needsEncryption = true");
            ck(dev.supportsPlaintext == false, "et=2 sets supportsPlaintext = false");
        }

        // 3.4 cn 编解码能力：cn=0,1（PCM+ALAC）vs cn=2,3（仅 AAC）
        {
            rta::net::AirPlayDevice devAlac, devNoAlac;
            rta::net::parse_raop_txt("cn=0,1", devAlac);
            ck(devAlac.supportsAlac == true, "cn=0,1 sets supportsAlac = true");

            rta::net::parse_raop_txt("cn=2,3", devNoAlac);
            ck(devNoAlac.supportsAlac == false, "cn=2,3 sets supportsAlac = false");
        }
    }

    // 4. parse_service_instance 纯函数覆盖（脱敏为通用测试实例名）
    {
        std::cout << "[Test 4: parse_service_instance Synthetic Edge Cases]" << std::endl;

        // 4.1 通用 12 位十六进制 MAC 前缀
        {
            rta::net::AirPlayDevice dev;
            bool ok = rta::net::parse_service_instance("001122334455@Living Room Speaker [AirPlay]", dev);
            ck(ok, "parse_service_instance succeeded");
            ck(dev.id == "001122334455@Living Room Speaker [AirPlay]", "id matches full instance name");
            ck(dev.name == "Living Room Speaker", "name stripped MAC and [AirPlay]: " + dev.name);
        }

        // 4.2 冒号分隔 MAC 前缀
        {
            rta::net::AirPlayDevice dev;
            rta::net::parse_service_instance("00:11:22:33:44:55@Living Room [AirPlay]", dev);
            ck(dev.name == "Living Room", "Colon-separated MAC prefix stripped correctly: " + dev.name);
        }

        // 4.3 无 MAC 前缀
        {
            rta::net::AirPlayDevice dev;
            rta::net::parse_service_instance("Living Room [AirPlay]", dev);
            ck(dev.name == "Living Room", "No MAC prefix stripped [AirPlay] correctly: " + dev.name);
        }

        // 4.4 纯名字无后缀
        {
            rta::net::AirPlayDevice dev;
            rta::net::parse_service_instance("Simple Speaker", dev);
            ck(dev.name == "Simple Speaker", "Plain name without suffix preserved: " + dev.name);
        }

        // 4.5 名字包含 '@'
        {
            rta::net::AirPlayDevice dev;
            rta::net::parse_service_instance("001122334455@Studio @ Office [AirPlay]", dev);
            ck(dev.name == "Studio @ Office", "Name containing '@' preserved after MAC prefix stripped: " + dev.name);
        }

        // 4.6 AirPlay 2 变体
        {
            rta::net::AirPlayDevice dev1, dev2;
            rta::net::parse_service_instance("@1984", dev1);
            ck(dev1.name == "1984", "AirPlay 2 '@1984' parsed as '1984'");
            rta::net::parse_service_instance("@1984 [AirPlay]", dev2);
            ck(dev2.name == "1984", "AirPlay 2 '@1984 [AirPlay]' parsed as '1984'");
        }

        // 4.7 空输入
        {
            rta::net::AirPlayDevice devEmpty;
            bool ok = rta::net::parse_service_instance("", devEmpty);
            ck(!ok, "Empty instance name returns false");
        }
    }

    // 5. 真实子网掩码选路（非简单的 /24 字符串匹配，使用 RFC5737 测试地址）
    {
        std::cout << "[Test 5: Actual Netmask-Aware Address Preference vs Flawed /24 Prefix]" << std::endl;

        // 构造本地测试子网环境：
        // 接口 en0: 198.51.100.50，掩码 /25 (255.255.255.128) -> 子网 198.51.100.0/25 (范围 .1 ~ .126)
        // 接口 en1: 192.0.2.10，掩码 /24 (255.255.255.0) -> 子网 192.0.2.0/24 (范围 .1 ~ .254)
        // 接口 lo0: 127.0.0.1，掩码 /8 (回环)
        std::vector<rta::net::airplay_detail::LocalIpv4Subnet> mockSubnets;

        rta::net::airplay_detail::LocalIpv4Subnet s1;
        s1.ifName = "en0";
        rta::net::airplay_detail::parse_ipv4_host("198.51.100.50", s1.ip);
        rta::net::airplay_detail::parse_ipv4_host("255.255.255.128", s1.mask); // /25
        s1.subnet = s1.ip & s1.mask;
        s1.isLoopback = false;
        mockSubnets.push_back(s1);

        rta::net::airplay_detail::LocalIpv4Subnet s2;
        s2.ifName = "en1";
        rta::net::airplay_detail::parse_ipv4_host("192.0.2.10", s2.ip);
        rta::net::airplay_detail::parse_ipv4_host("255.255.255.0", s2.mask); // /24
        s2.subnet = s2.ip & s2.mask;
        s2.isLoopback = false;
        mockSubnets.push_back(s2);

        rta::net::airplay_detail::LocalIpv4Subnet s3;
        s3.ifName = "lo0";
        rta::net::airplay_detail::parse_ipv4_host("127.0.0.1", s3.ip);
        rta::net::airplay_detail::parse_ipv4_host("255.0.0.0", s3.mask);
        s3.subnet = s3.ip & s3.mask;
        s3.isLoopback = true;
        mockSubnets.push_back(s3);

        // 验证 is_ip_in_local_subnets 在 /25 下的行为：
        // 198.51.100.60 属于 198.51.100.0/25 -> true
        // 198.51.100.200 属于 198.51.100.128/25，不属于本地接口子网 -> false
        // （如果是旧的 "198.51.100." /24 前缀字符串匹配，这两者都会误判为同网段！）
        bool inSubnet60 = rta::net::airplay_detail::is_ip_in_local_subnets("198.51.100.60", mockSubnets);
        bool inSubnet200 = rta::net::airplay_detail::is_ip_in_local_subnets("198.51.100.200", mockSubnets);
        ck(inSubnet60 == true, "198.51.100.60 is inside 198.51.100.0/25 subnet");
        ck(inSubnet200 == false, "198.51.100.200 is outside 198.51.100.0/25 (proves real netmask math)");

        // 验证确定性优选：同子网 198.51.100.60 优于跨子网 198.51.100.200
        bool prefSubnet = rta::net::airplay_detail::compare_addresses_deterministic("198.51.100.60", "198.51.100.200", mockSubnets);
        ck(prefSubnet == true, "compare_addresses_deterministic prefers 198.51.100.60 over 198.51.100.200");

        // 跨子网但属于普通单播 IPv4 (198.51.100.200) 优于远端 IPv4 (203.0.113.10)
        bool prefLocalSubnetOverForeign = rta::net::airplay_detail::compare_addresses_deterministic("192.0.2.80", "203.0.113.10", mockSubnets);
        ck(prefLocalSubnetOverForeign == true, "192.0.2.80 (local /24) preferred over 203.0.113.10 (foreign)");
    }

    // 6. 多接口 DNS 应答聚合与确定性选路
    {
        std::cout << "[Test 6: Multi-Interface DNS Replies Aggregation & Determinism]" << std::endl;

        std::vector<rta::net::airplay_detail::LocalIpv4Subnet> mockSubnets;
        rta::net::airplay_detail::LocalIpv4Subnet s;
        s.ifName = "en0";
        rta::net::airplay_detail::parse_ipv4_host("192.0.2.15", s.ip);
        rta::net::airplay_detail::parse_ipv4_host("255.255.255.0", s.mask);
        s.subnet = s.ip & s.mask;
        s.isLoopback = false;
        mockSubnets.push_back(s);

        // 模拟同一个设备在多网卡上收到的候选地址列表（顺序不同）：
        std::vector<std::string> candidates1 = {"203.0.113.1", "192.0.2.88", "198.51.100.9"};
        std::vector<std::string> candidates2 = {"198.51.100.9", "203.0.113.1", "192.0.2.88"};
        std::vector<std::string> candidates3 = {"192.0.2.88", "198.51.100.9", "203.0.113.1"};

        rta::net::AirPlayDevice dev1, dev2, dev3;
        rta::net::airplay_detail::update_best_host(dev1, candidates1, mockSubnets, "speaker.local");
        rta::net::airplay_detail::update_best_host(dev2, candidates2, mockSubnets, "speaker.local");
        rta::net::airplay_detail::update_best_host(dev3, candidates3, mockSubnets, "speaker.local");

        ck(dev1.host == "192.0.2.88", "update_best_host picks reachable 192.0.2.88 for order 1");
        ck(dev2.host == "192.0.2.88", "update_best_host picks reachable 192.0.2.88 for order 2");
        ck(dev3.host == "192.0.2.88", "update_best_host picks reachable 192.0.2.88 for order 3");
    }

    // 7. IPv6 作用域格式化与分层优先级
    {
        std::cout << "[Test 7: IPv6 Scope Formatting & Address Tiering]" << std::endl;

        // 7.1 link-local IPv6 格式化追加 %scope
        struct sockaddr_in6 sin6;
        std::memset(&sin6, 0, sizeof(sin6));
        sin6.sin6_family = AF_INET6;
        inet_pton(AF_INET6, "fe80::1", &sin6.sin6_addr);
        sin6.sin6_scope_id = 1;

        std::string scoped = rta::net::airplay_detail::format_ipv6_scoped(&sin6, 1);
        ck(!scoped.empty(), "format_ipv6_scoped produces non-empty output");
        ck(scoped.find("%") != std::string::npos, "format_ipv6_scoped appends % scope for link-local: " + scoped);

        // 7.2 全局 IPv6 地址不加 scope
        struct sockaddr_in6 sin6Global;
        std::memset(&sin6Global, 0, sizeof(sin6Global));
        sin6Global.sin6_family = AF_INET6;
        inet_pton(AF_INET6, "2001:db8::1", &sin6Global.sin6_addr);
        std::string globalV6 = rta::net::airplay_detail::format_ipv6_scoped(&sin6Global, 1);
        ck(globalV6 == "2001:db8::1", "format_ipv6_scoped preserves global IPv6 without scope: " + globalV6);

        // 7.3 分层优先级：同网段 IPv4 > 其他普通 IPv4 > 全局 IPv6 > 带作用域 link-local IPv6 > 不带作用域 link-local IPv6 > 169.254 > 回环
        std::vector<rta::net::airplay_detail::LocalIpv4Subnet> mockSubnets;
        rta::net::airplay_detail::LocalIpv4Subnet s;
        rta::net::airplay_detail::parse_ipv4_host("192.0.2.1", s.ip);
        rta::net::airplay_detail::parse_ipv4_host("255.255.255.0", s.mask);
        s.subnet = s.ip & s.mask;
        s.isLoopback = false;
        mockSubnets.push_back(s);

        int scoreSameIpv4 = rta::net::airplay_detail::score_candidate_address("192.0.2.100", mockSubnets);
        int scoreOtherIpv4 = rta::net::airplay_detail::score_candidate_address("203.0.113.5", mockSubnets);
        int scoreGlobalV6 = rta::net::airplay_detail::score_candidate_address("2001:db8::1", mockSubnets);
        int scoreScopedV6 = rta::net::airplay_detail::score_candidate_address("fe80::1%en0", mockSubnets);
        int scoreUnscopedV6 = rta::net::airplay_detail::score_candidate_address("fe80::1", mockSubnets);
        int scoreLinkLocal4 = rta::net::airplay_detail::score_candidate_address("169.254.10.20", mockSubnets);
        int scoreLoopback = rta::net::airplay_detail::score_candidate_address("127.0.0.1", mockSubnets);

        ck(scoreSameIpv4 < scoreOtherIpv4, "Same-subnet IPv4 < Other IPv4", std::to_string(scoreSameIpv4) + " vs " + std::to_string(scoreOtherIpv4));
        ck(scoreOtherIpv4 < scoreGlobalV6, "Other IPv4 < Global IPv6", std::to_string(scoreOtherIpv4) + " vs " + std::to_string(scoreGlobalV6));
        ck(scoreGlobalV6 < scoreScopedV6, "Global IPv6 < Scoped link-local IPv6", std::to_string(scoreGlobalV6) + " vs " + std::to_string(scoreScopedV6));
        ck(scoreScopedV6 < scoreUnscopedV6, "Scoped link-local < Unscoped link-local", std::to_string(scoreScopedV6) + " vs " + std::to_string(scoreUnscopedV6));
        ck(scoreUnscopedV6 < scoreLinkLocal4, "Unscoped link-local < 169.254 link-local", std::to_string(scoreUnscopedV6) + " vs " + std::to_string(scoreLinkLocal4));
        ck(scoreLinkLocal4 < scoreLoopback, "169.254 link-local < Loopback", std::to_string(scoreLinkLocal4) + " vs " + std::to_string(scoreLoopback));
    }

    // 8. DNS 错误处理：无畸形空 host 设备
    {
        std::cout << "[Test 8: DNS Error Handling without Bogus Empty Host]" << std::endl;

        std::vector<rta::net::airplay_detail::LocalIpv4Subnet> mockSubnets;
        rta::net::AirPlayDevice devWithFallback;
        devWithFallback.host = "";
        std::vector<std::string> emptyCandidates;

        // 当 DNS 地址解析全部失败但有 hosttarget（如 speaker.local）时，安全回退到 hosttarget
        rta::net::airplay_detail::update_best_host(devWithFallback, emptyCandidates, mockSubnets, "speaker.local");
        ck(devWithFallback.host == "speaker.local", "update_best_host falls back to hosttarget when candidate IPs empty");

        // 当连 hosttarget 也为空时，保持为空（airplay_discover 会过滤掉 host 为空的无效项）
        rta::net::AirPlayDevice devTotallyBroken;
        rta::net::airplay_detail::update_best_host(devTotallyBroken, emptyCandidates, mockSubnets, "");
        ck(devTotallyBroken.host.empty(), "update_best_host leaves host empty when both candidates and fallback are empty");
    }

    // 9. 真实发现测试默认 SKIP（离线测试硬约束）
    {
        std::cout << "[Test 9: Live mDNS Discovery (RTA_AIRPLAY_LIVE=1)]" << std::endl;
        const char* liveEnv = std::getenv("RTA_AIRPLAY_LIVE");
        if (!liveEnv || std::string(liveEnv) != "1") {
            std::cout << "  [SKIP] Live discovery skipped (set RTA_AIRPLAY_LIVE=1 to enable read-only mDNS probe)" << std::endl;
        } else {
            std::cout << "  Executing live discovery probe with timeout 1500 ms..." << std::endl;
            std::string diag;
            auto devs = rta::net::airplay_discover(1500, &diag);
            std::cout << "  Live diag: " << diag << std::endl;
            std::cout << "  Found devices count: " << devs.size() << std::endl;
            for (size_t i = 0; i < devs.size(); ++i) {
                const auto& d = devs[i];
                std::cout << "    [" << i << "] ID: " << d.id
                          << ", Name: " << d.name
                          << ", Host: " << d.host << ":" << d.port
                          << ", Model: " << d.model
                          << ", PW: " << d.password
                          << ", NeedsEnc: " << d.needsEncryption << std::endl;
            }
            ck(true, "Live discovery executed without crash and returned structured diagnostic");
        }
    }

    std::cout << "=== test_airplay_discovery complete, total failures: " << g_fail << " ===" << std::endl;
    return g_fail > 0 ? 1 : 0;
}
