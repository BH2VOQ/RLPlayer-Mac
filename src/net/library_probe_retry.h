// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <map>
#include <string>
#include <sstream>
#include <chrono>

namespace rta::net {
struct LibProbeRetry {
    long long due = 0;
    unsigned attempts = 0;
};
using LibProbeRetries = std::map<std::string, LibProbeRetry>;
inline long long lib_probe_retry_now() {
    return std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
}
inline std::string lib_probe_retry_hex(const std::string& s) {
    static constexpr char hex[] = "0123456789abcdef";
    std::string out; out.reserve(s.size() * 2);
    for (unsigned char c : s) { out += hex[c >> 4]; out += hex[c & 15]; }
    return out;
}
inline bool lib_probe_retry_unhex(const std::string& s, std::string& out) {
    out.clear();
    if (s.empty() || s.size() % 2) return false;
    auto value = [](char c) { return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1; };
    for (size_t i = 0; i < s.size(); i += 2) {
        const int a = value(s[i]), b = value(s[i + 1]);
        if (a < 0 || b < 0) return false;
        const char c = (char)((a << 4) | b);
        if (!c) return false;
        out += c;
    }
    return true;
}
inline std::string lib_probe_retries_text(const LibProbeRetries& retries) {
    std::string out;
    for (const auto& [path, retry] : retries)
        out += "#probeRetryV1\t" + std::to_string(retry.due) + "\t" + std::to_string(retry.attempts) + "\t" + lib_probe_retry_hex(path) + "\n";
    return out;
}
inline LibProbeRetries lib_probe_retries_parse(const std::string& text, bool* valid = nullptr) {
    if (valid) *valid = true;
    auto bad = [&] { if (valid) *valid = false; };
    LibProbeRetries out;
    std::istringstream in(text); std::string line;
    while (std::getline(in, line)) {
        if (line.rfind("#probeRetry", 0) != 0) continue;
        if (line.rfind("#probeRetryV1\t", 0) != 0) { bad(); continue; }
        std::istringstream fields(line.substr(14));
        std::string due, attempts, encoded, path;
        if (!std::getline(fields, due, '\t') || !std::getline(fields, attempts, '\t') ||
            !std::getline(fields, encoded) || !lib_probe_retry_unhex(encoded, path)) { bad(); continue; }
        try {
            size_t a = 0, b = 0;
            const auto d = std::stoll(due, &a), n = std::stoll(attempts, &b);
            if (a != due.size() || b != attempts.size() || d < 0 || n < 0 || n > 1000000 || out.count(path)) { bad(); continue; }
            out[path] = {d, (unsigned)n};
        } catch (...) { bad(); }
    }
    return out;
}
} // namespace rta::net
