// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// cast_url_parser.h — AirPlay 设备 URL 与标识解析纯函数及音量换算
#pragma once

#include <string>
#include <cstdint>
#include <cctype>
#include <cstdlib>
#include <cmath>
#include <algorithm>

namespace rta::net {

inline bool is_airplay_dev(const std::string& dev) {
    return dev.rfind("airplay://", 0) == 0;
}

inline bool parse_airplay_dev(const std::string& dev, std::string& host, uint16_t& port) {
    if (!is_airplay_dev(dev)) return false;
    std::string rest = dev.substr(10); // length of "airplay://"
    if (rest.empty()) return false;

    // Strip trailing path / identifier: /<id>
    const size_t slash = rest.find('/');
    if (slash != std::string::npos) {
        rest = rest.substr(0, slash);
    }
    if (rest.empty()) return false;

    // Check for IPv6 bracket notation: [ipv6]:port or [ipv6]
    if (rest.front() == '[') {
        const size_t rbracket = rest.find(']');
        if (rbracket == std::string::npos || rbracket == 1) {
            return false; // unclosed bracket or empty []
        }
        host = rest.substr(1, rbracket - 1);
        if (host.empty()) return false;

        std::string afterBracket = rest.substr(rbracket + 1);
        if (afterBracket.empty()) {
            port = 5000;
            return true;
        }
        if (afterBracket.front() != ':') {
            return false; // must have colon before port
        }
        std::string portStr = afterBracket.substr(1);
        if (portStr.empty()) return false;
        for (char c : portStr) {
            if (!std::isdigit(static_cast<unsigned char>(c))) return false;
        }
        unsigned long p = std::strtoul(portStr.c_str(), nullptr, 10);
        if (p == 0 || p > 65535) return false;
        port = static_cast<uint16_t>(p);
        return true;
    }

    // No brackets. Count colons.
    size_t colonCount = 0;
    size_t lastColon = std::string::npos;
    for (size_t i = 0; i < rest.size(); ++i) {
        if (rest[i] == ':') {
            colonCount++;
            lastColon = i;
        }
    }

    if (colonCount > 1) {
        // Unbracketed raw IPv6 without port: host contains colons
        host = rest;
        port = 5000;
        return true;
    }

    if (colonCount == 1) {
        host = rest.substr(0, lastColon);
        if (host.empty()) return false;
        std::string portStr = rest.substr(lastColon + 1);
        if (portStr.empty()) return false;
        for (char c : portStr) {
            if (!std::isdigit(static_cast<unsigned char>(c))) return false;
        }
        unsigned long p = std::strtoul(portStr.c_str(), nullptr, 10);
        if (p == 0 || p > 65535) return false;
        port = static_cast<uint16_t>(p);
        return true;
    }

    // No colon at all: host only
    host = rest;
    port = 5000;
    return true;
}

// AirPlay dB 换算为 0..100% 整数音量：
// 标准 RAOP 接收端衰减标度为 [-30.0, 0.0] dB，其中 -30 dB 为最小可听声，0 dB 为满幅。
// 对低于 -30 dB 的扩展输入（如 -120 dB 静音），平滑映射至 0%。
inline int airplay_db_to_percent(double db) {
    if (!std::isfinite(db) || db <= -120.0) return 0;
    if (db >= 0.0) return 100;
    if (db <= -30.0) {
        if (db <= -60.0) return 0;
        return static_cast<int>(std::lround((db + 60.0) / 30.0 * 5.0)); // 0..5%
    }
    int p = static_cast<int>(std::lround(5.0 + (db + 30.0) / 30.0 * 95.0));
    if (p < 0) p = 0;
    if (p > 100) p = 100;
    return p;
}

// ── 投放初始/运行音量的合法化（纯函数，可离线单测）──────────────────────────
// 为什么要在这里做：音量是「会在用户耳边立刻生效」的唯一参数（铁律 1）。
//   · NaN / ±Inf：不可用 ⟹ 回落保守默认 -20 dB（历史问题：非有限值被协议层拒绝，
//     但调用方仍把 currentVolume 写成 0%，界面显示静音而实际接收端音量未知）。
//   · > 0 dB：RAOP 标度上限是 0 dB（满幅），不做任何放大 —— 直接夹到 0。
//   · < -144 dB：夹到 -144（低于此值无意义，等价静音）。
constexpr double kCastVolumeDefaultDb = -20.0;   // 保守默认：明显可听但绝不是满幅
constexpr double kCastVolumeMaxDb     = 0.0;     // 满幅上限
constexpr double kCastVolumeMinDb     = -144.0;  // 静音下限

inline double sanitize_cast_volume_db(double db) {
    if (!std::isfinite(db)) return kCastVolumeDefaultDb;
    if (db > kCastVolumeMaxDb) return kCastVolumeMaxDb;
    if (db < kCastVolumeMinDb) return kCastVolumeMinDb;
    return db;
}

// 设备标识查询串里的布尔开关（例：`airplay://192.0.2.10:5000/spk?pw=1&enc=1`）。
// 判据故意严格：**键名精确匹配**（避免 `cpw=1` / `xenc=1` 误命中），值接受
// 1/true/yes（大小写不敏感）；裸键（`?pw`）视为真；其余值一律为假。
// 只看查询串，不碰 path/id —— id 里出现 "enc=1" 这类字样不该改变安全判定。
inline bool airplay_dev_query_flag(const std::string& dev, const std::string& key) {
    const size_t q = dev.find('?');
    if (q == std::string::npos) return false;
    std::string qs = dev.substr(q + 1);
    const size_t hash = qs.find('#');
    if (hash != std::string::npos) qs = qs.substr(0, hash);

    std::string want = key;
    for (char& c : want) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));

    size_t pos = 0;
    while (pos <= qs.size()) {
        const size_t amp = qs.find('&', pos);
        std::string seg = qs.substr(pos, (amp == std::string::npos ? qs.size() : amp) - pos);
        pos = (amp == std::string::npos) ? qs.size() + 1 : amp + 1;

        const size_t eq = seg.find('=');
        std::string k = (eq == std::string::npos) ? seg : seg.substr(0, eq);
        std::string v = (eq == std::string::npos) ? std::string() : seg.substr(eq + 1);
        for (char& c : k) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        for (char& c : v) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        if (k != want) continue;
        if (eq == std::string::npos) return true;   // 裸键
        return v == "1" || v == "true" || v == "yes";
    }
    return false;
}

} // namespace rta::net
