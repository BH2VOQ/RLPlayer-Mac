// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// health_store.h — 音频体检 B1b：按 (规范路径, mtime, size) 三元组为键的健康缓存
//
// 设计要点：
//  1) 键 = std::filesystem::weakly_canonical 规范化后的路径（generic 形式，'/' 分隔），
//     命中还须 mtime、size 逐字相等 —— 文件被改写/替换后自然失效，不需要 TTL。
//     mtime 取「自时钟纪元的毫秒数」而不是原生 count：JSON number 走 double（53 位尾数），
//     纳秒 count 约 1.8e18，超出 2^53 会失真导致缓存永不命中（mac 实测丢 8 ns，
//     见 tests/test_track_health.cpp §7 的负向对照）。毫秒级余量充足。
//  2) 序列化复用 track_health_json（单条体检的对象体），外层是数组，每条
//     {"path":..,"mtime":..,"size":..,"health":{..}}；解析用 src/net/json.h（只读解析器，
//     项目约定不引第三方 JSON 库）。
//  3) 损坏文件如实报错、绝不静默清空：构造时解析失败 → loadError() 非空，此时
//     save() 拒绝写盘（防止用一个空库把用户缓存覆盖掉），需要人工删掉/修复缓存文件。
//  4) save() 原子写：先写 <path>.tmp 再 rename，崩溃最多留下一个 tmp，不会写坏正身。
//
// ---------------- macOS 移植（2026-10-26，本文件是本工作包**唯一必须重写**的头）----------------
// 上游 68e628f 的 health_store.h 是三处 Windows 专属写法，mac 上**根本编不过**：
//
//   a) 宽字符版 fopen（`f`+`w` 前缀的那个 CRT 扩展，上游 :147 / :168）
//      —— 那是 MSVC CRT 的私有扩展，libc++/macOS 没有这个符号。
//   b) Win32 的文件属性探测 API 的宽字符变体（上游 :150）
//      —— Win32 API，mac 没有。
//   c) `std::filesystem::weakly_canonical(rta::audio::widen(path))`（上游 :30 / :118-119）
//      —— 语法能过，**但 mac 上会抛异常**。本机实测（clang 21 / libc++）：
//          fs::path(widen("/tmp/中文/x.json"))  →  throw std::runtime_error("locale not supported")
//          fs::path(widen("/tmp/ascii/x.json")) →  ok
//        根因：mac 的 `widen()` 是**字节保序恒等**（src/audio/audio_loader.h:52，
//        `std::wstring(s.begin(), s.end())`，UTF-8 字节直接塞进宽字符），而
//        `fs::path(const std::wstring&)` 在 libc++ 里要按 **宽字符语义转码**
//        （走 locale/codecvt，取不到 locale 就 throw），并不是"按字节搬运"。
//        ⟹ 上游注释「widen() UTF-8→UTF-16，中文缓存路径必需」在 mac 上是**双重错误**：
//           ① mac 不做 UTF-8→UTF-16 转码；② 拿它构造 fs::path 会在中文路径上直接抛。
//
// 本库改法（任务书口径）：全部走 `std::filesystem::u8path` 系（UTF-8 语义，mac 原生安全），
// 文件 IO 走 `std::fopen`。宽字符路径构造（`widen`/`narrow`）与任何 Win32 文件属性 API
// 在本文件一律不出现 —— 这也是平台边界门禁（判据 5）的 grep 口径。
//
// 关于 u8path 的形态：C++20 起 `fs::u8path(const char*)` 已被标记 deprecated
//（`-Wdeprecated-declarations`，因为 char8_t 出现后它退化成 "u8string 的便捷包装"）。
// `path_from_utf8()` 因此优先用**语义完全等价且不 deprecated** 的 `path(u8string)`，
// 只有在没有 char8_t 的旧标准库上才退回 `u8path`。两者对 UTF-8 输入逐字节等价
//（本机实测 match=1，含中文路径）。
#pragma once
#include "track_health.h"
#include "../net/json.h"             // rta::net::json_parse（只读解析）
#include <filesystem>
#include <map>
#include <string>
#include <cstdint>
#include <cstdio>
#include <cmath>

namespace rta::analysis {

// UTF-8 窄串 → 原生路径。**这是本文件唯一允许的路径构造入口**：
// 上游的 `widen()` 路线在 mac 上对非 ASCII 会抛 "locale not supported"（见文件头）。
inline std::filesystem::path path_from_utf8(const std::string& s) {
#if defined(__cpp_lib_char8_t)
    // C++20 + char8_t：与 u8path 语义等价，且不是 deprecated API
    return std::filesystem::path(
        std::u8string(reinterpret_cast<const char8_t*>(s.data()), s.size()));
#else
    return std::filesystem::u8path(s);
#endif
}

// 路径规范化：weakly_canonical 失败（如路径不存在且父级不可解析）时退回原串，绝不抛异常。
inline std::string normalize_path_key(const std::string& path) {
    try {
        return std::filesystem::weakly_canonical(path_from_utf8(path)).generic_string();
    } catch (...) {
        return path;
    }
}

class HealthStore {
public:
    // jsonPath 不存在 → 空库（不是错误）；存在但损坏/为空 → loadError() 非空且拒绝 save()。
    explicit HealthStore(const std::string& jsonPath) : jsonPath_(jsonPath) {
        if (jsonPath_.empty()) { loadError_ = "缓存路径为空"; return; }
        std::string text, readErr;
        if (!read_whole_file(jsonPath_, &text, &readErr)) {
            loadError_ = readErr;      // 文件不存在时 readErr 为空 → 空库，不算错误
            return;
        }
        const rta::net::Json root = rta::net::json_parse(text);
        if (root.type != rta::net::Json::Arr) {
            loadError_ = "缓存文件损坏（不是合法 JSON 或根不是数组），已按空库处理且不会回写: " + jsonPath_;
            return;
        }
        for (size_t i = 0; i < root.size(); ++i) {
            const rta::net::Json& e = root.at(i);
            if (e.type != rta::net::Json::Obj) { ++skipped_; continue; }
            const std::string p = e["path"].s();
            const rta::net::Json& hj = e["health"];
            if (p.empty() || hj.type != rta::net::Json::Obj || hj["status"].s().empty()) { ++skipped_; continue; }
            Entry en;
            en.mtime = (int64_t)std::llround(e["mtime"].n());
            en.size  = (int64_t)std::llround(e["size"].n());
            TrackHealth& h = en.health;
            h.drDb = hj["dr_db"].n();
            h.lufs = hj["lufs"].n();
            h.lra = hj["lra"].n();
            h.peakDbfs = hj["peak_dbfs"].n();
            h.losslessSuspected = hj["lossless_suspected"].b || hj["lossless_suspected"].n() != 0.0;
            h.cutoffHz = hj["cutoff_hz"].n();
            h.confidence = hj["confidence"].n();
            h.reason = hj["reason"].s();
            h.fake24bit = hj["fake24"].b || hj["fake24"].n() != 0.0;
            h.durationSec = hj["duration_sec"].n();
            h.fs = (uint32_t)std::llround(hj["fs"].n());
            h.channels = (int)std::llround(hj["channels"].n());
            h.bits = (int)std::llround(hj["bits"].n());
            h.status = hj["status"].s();
            h.error = hj["error"].s();
            h.analyzedAtMs = (int64_t)std::llround(hj["analyzed_at_ms"].n());
            entries_[normalize_path_key(p)] = std::move(en);
        }
    }

    // 命中 = 路径（规范化后）+ mtime + size 三者全等。返回 false 表示需重算。
    bool lookup(const std::string& path, int64_t mtime, int64_t size, TrackHealth& out) const {
        if (!loadError_.empty()) return false;
        const auto it = entries_.find(normalize_path_key(path));
        if (it == entries_.end()) return false;
        if (it->second.mtime != mtime || it->second.size != size) return false;
        out = it->second.health;
        return true;
    }

    void upsert(const std::string& path, int64_t mtime, int64_t size, const TrackHealth& h) {
        Entry en;
        en.mtime = mtime;
        en.size = size;
        en.health = h;
        entries_[normalize_path_key(path)] = std::move(en);
    }

    // 原子写（tmp + rename）。加载时报过错的库拒绝写盘（见类头注释），返回 false。
    bool save() {
        if (!loadError_.empty()) return false;
        if (jsonPath_.empty()) return false;
        std::string data = "[";
        bool first = true;
        for (const auto& kv : entries_) {
            if (!first) data += ",";
            first = false;
            data += "{\"path\":\"" + detail::json_escape(kv.first) + "\"";
            data += ",\"mtime\":" + std::to_string((long long)kv.second.mtime);
            data += ",\"size\":" + std::to_string((long long)kv.second.size);
            data += ",\"health\":" + track_health_json(kv.second.health);
            data += "}";
        }
        data += "]";
        const std::string tmp = jsonPath_ + ".tmp";
        if (!write_whole_file(tmp, data)) return false;
        std::error_code ec;
        // POSIX（mac）的 rename(2) 语义：目标已存在时**原子替换**，不需要"先删再改名"
        // 的退化分支（那是上游为 Windows MoveFileEx 非覆盖语义留的）。mac 上如果真失败，
        // 说明是跨卷/权限问题，删正身只会让用户丢缓存 —— 所以这里如实失败、保留 tmp。
        const std::filesystem::path from = path_from_utf8(tmp);
        const std::filesystem::path to   = path_from_utf8(jsonPath_);
        std::filesystem::rename(from, to, ec);
        if (ec) { std::filesystem::remove(from, ec); return false; }
        return true;
    }

    size_t size() const { return entries_.size(); }
    const std::string& loadError() const { return loadError_; }
    int skippedEntries() const { return skipped_; }   // 解析时跳过的损坏条数（非致命）

private:
    struct Entry {
        int64_t mtime = 0;
        int64_t size = 0;
        TrackHealth health;
    };

    // 读整个文件。文件不存在返回 false 且 *err 为空（= 合法的空库）；其他读失败 *err 带原因。
    //
    // mac 写法（替代上游的宽字符 fopen + Win32 文件属性探测）：
    //   * fopen 失败时**不能**一律当"空库" —— 那样权限问题会被静默当成"没缓存"，
    //     然后 save() 又把用户缓存覆盖掉。所以用 fs::exists 二次判定：
    //     ec 为空且 exists=false ⟹ 真不存在（空库）；否则如实报错。
    static bool read_whole_file(const std::string& path, std::string* out, std::string* err) {
        out->clear();
        err->clear();
        const std::filesystem::path p = path_from_utf8(path);
        FILE* f = std::fopen(p.c_str(), "rb");
        if (!f) {
            std::error_code ec;
            const bool there = std::filesystem::exists(p, ec);
            if (there && !ec)
                *err = "无法读取缓存文件（可能无权限或被占用）: " + path;
            else if (ec)
                *err = "无法访问缓存文件路径（" + ec.message() + "）: " + path;
            return false;   // 属性都查不到 = 不存在 = 空库
        }
        std::string data;
        char buf[65536];
        size_t got = 0;
        while ((got = std::fread(buf, 1, sizeof(buf), f)) > 0) data.append(buf, got);
        const bool ioErr = std::ferror(f) != 0;
        std::fclose(f);
        if (ioErr) { *err = "读取缓存文件失败（I/O 错误）: " + path; return false; }
        // 空文件也按「损坏」处理：正常 save() 永远写完整 JSON，不该出现 0 字节
        if (data.empty()) { *err = "缓存文件为空（0 字节，正常不应出现）: " + path; return false; }
        *out = std::move(data);
        return true;
    }

    static bool write_whole_file(const std::string& path, const std::string& data) {
        const std::filesystem::path p = path_from_utf8(path);
        FILE* f = std::fopen(p.c_str(), "wb");
        if (!f) return false;
        const bool ok = std::fwrite(data.data(), 1, data.size(), f) == data.size();
        const bool closed = (std::fclose(f) == 0);
        return ok && closed;
    }

    std::string jsonPath_;
    std::map<std::string, Entry> entries_;   // 键 = normalize_path_key
    std::string loadError_;                  // 非空 = 加载失败（此时 save() 拒绝写盘）
    int skipped_ = 0;
};

} // namespace rta::analysis
