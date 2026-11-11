// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// install_id.h — 反馈后台用来区分「这台机器是谁」的安装 ID（纯逻辑、零依赖、可离线单测）
//
// ===========================================================================
// 为什么单独一个头（而不是塞进 feedback_api.h）
//
//   安装 ID 的**形态**是有约束的协议事实：后台把它当主键做频率限制、工单归属与
//   「安装 ID 不匹配」的 403 判定。所以校验必须是**严格**的 —— 允许大写或多余字符，
//   等于允许同一台机器变成两台（频率限制被绕过），或者两台机器被算成一台（工单串号）。
//
//   生成与校验放在同一个头里，是为了让「生成的东西一定过校验」成为编译期相邻的事实，
//   而不是两处各写一遍 hex 编码、某天改一处忘另一处。
//
//   ⚠️ 本层**不产生熵**：entropy 由宿主（系统随机源 / libcurl / CommonCrypto 均可）
//      提供，这里只做「16 字节 → 32 位小写 hex」的确定性编码。这样单测能固定向量，
//      也不必为了测试去注入随机源。
// ===========================================================================
#pragma once

#include <cstddef>
#include <string>

namespace rta::feedback {

// 前缀固定 "rlmac-"（见契约）。写死成常量，宿主与后台都引用同一个字面量。
inline constexpr const char* kInstallIdPrefix = "rlmac-";

// 规范形态：kInstallIdPrefix(7) + 16 字节熵的 32 位小写十六进制 = 总长 38
inline constexpr std::size_t kInstallIdPrefixLength = 6;   // "rlmac-" 是 6 字节（不是 7）
inline constexpr std::size_t kInstallIdHexDigits = 32;
inline constexpr std::size_t kInstallIdLength = kInstallIdPrefixLength + kInstallIdHexDigits;  // = 38

// 严格校验：前缀逐字匹配 + 后 32 位**只允许小写** 0-9a-f。
// 不做 trim、不忽略大小写 —— "看起来差不多"的串在后台是另一台机器。
inline bool install_id_valid(const std::string& s) {
    if (s.size() != kInstallIdLength) return false;
    if (s.compare(0, kInstallIdPrefixLength, kInstallIdPrefix) != 0) return false;
    for (std::size_t i = kInstallIdPrefixLength; i < s.size(); ++i) {
        const char c = s[i];
        const bool lower_hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
        if (!lower_hex) return false;
    }
    return true;
}

// 确定性编码：同输入必然同输出（单测靠这条固定向量）。
// entropy 为 nullptr 时退化为全 0（契约没规定，但绝不允许空指针崩在反馈路径上）。
inline std::string install_id_new(const unsigned char entropy[16]) {
    static const char kHex[] = "0123456789abcdef";
    std::string out(kInstallIdPrefix);
    out.reserve(kInstallIdLength);
    for (std::size_t i = 0; i < 16; ++i) {
        const unsigned char b = entropy ? entropy[i] : 0;
        out += kHex[(b >> 4) & 0x0F];
        out += kHex[b & 0x0F];
    }
    return out;
}

}  // namespace rta::feedback
