// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// health_store.h — 体检缓存：规范路径 + 强文件身份 (mtime, size, ctime_ns 字符串, inode, dev) + SHA-256
//
// 设计要点：
//  1) 键 = std::filesystem::weakly_canonical 规范化后的路径（generic 形式，'/' 分隔）。
//  2) 强文件身份快速命中：
//     包含 mtime (ms), size (bytes), ctime_ns (秒.纳秒 字符串格式，彻底避免 double 精度损失),
//     inode, dev。
//     如果文件身份元数据完全一致（有效且未修改），快速 O(1) 判定命中，无需对几十/几百MB音频重复哈希；
//     对于旧 schema 缺少这些强身份字段的旧缓存条目，判定 miss 并重新计算更新；
//     对于文件同大小、mtime 被人为篡改但中段被修改的情况，inode / ctime_ns 变化将立即触发失效；
//  3) 防竞态与错误防污染：
//     分析前取文件身份并计算哈希，分析后核验文件身份与哈希是否一致（防分析期间并发写覆盖将老指标赋给新内容）；
//     哈希失败或读失败时不存入死条目；错误结果（status != "ready"）绝不入库。
//  4) 损坏文件如实报错、绝不静默清空：构造时解析失败 → loadError() 非空，此时 save() 拒绝写盘。
//  5) save() 原子写：先写 <path>.tmp 再 rename，POSIX rename 语义保证原子替换。
#pragma once
#include "track_health.h"
#include "../net/update_check.h"
#include "../net/json.h"             // rta::net::json_parse（只读解析）
#include <filesystem>
#include <map>
#include <string>
#include <cstdint>
#include <cstdio>
#include <cmath>
#include <fstream>
#include <sys/stat.h>

namespace rta::analysis {

// 当前体检分析算法代际标识：
// 算法/指标口径变化后升级此代号，确保旧代际缓存安全 miss 重算，
// 同时保留合法未损坏旧缓存条目不被强制洗白。
inline constexpr const char* kCurrentAnalysisGeneration = "health-analysis-v2";


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

// 强文件身份结构：支持 O(1) 快速比对
struct FileIdentity {
    int64_t mtime = 0;         // 毫秒时间戳（与现有 mtime 保持一致）
    int64_t size = 0;          // 文件字节大小
    uint64_t inode = 0;        // st_ino
    uint64_t dev = 0;          // st_dev
    std::string ctime_ns_str;  // 秒.纳秒 字符串形式，避免 double 精度丢失 (如 "1793268154.813815379")
    bool valid = false;

    static FileIdentity from_path(const std::string& path) {
        FileIdentity id;
        struct stat st;
        const auto p = path_from_utf8(path);
        if (::stat(p.c_str(), &st) == 0) {
#if defined(__APPLE__)
            id.mtime = (int64_t)st.st_mtime * 1000 + (int64_t)(st.st_mtimespec.tv_nsec / 1000000);
            const long c_nsec = st.st_ctimespec.tv_nsec;
#elif defined(_POSIX_C_SOURCE) && _POSIX_C_SOURCE >= 200809L
            id.mtime = (int64_t)st.st_mtime * 1000 + (int64_t)(st.st_mtim.tv_nsec / 1000000);
            const long c_nsec = st.st_ctim.tv_nsec;
#else
            id.mtime = (int64_t)st.st_mtime * 1000;
            const long c_nsec = 0;
#endif
            id.size = (int64_t)st.st_size;
            id.inode = (uint64_t)st.st_ino;
            id.dev = (uint64_t)st.st_dev;

            char buf[64];
            std::snprintf(buf, sizeof(buf), "%lld.%09ld", (long long)st.st_ctime, c_nsec);
            id.ctime_ns_str = buf;
            id.valid = true;
        }
        return id;
    }

    bool matches(const FileIdentity& o) const {
        if (!valid || !o.valid) return false;
        return mtime == o.mtime &&
               size == o.size &&
               inode == o.inode &&
               dev == o.dev &&
               !ctime_ns_str.empty() &&
               ctime_ns_str == o.ctime_ns_str;
    }
};

// Full-content digest, not a head/tail sample: middle-byte edits must invalidate.
inline std::string health_content_digest(const std::string& path) {
    std::ifstream f(path_from_utf8(path), std::ios::binary);
    if (!f) return {};
    uint32_t h[8]; rta::update::detail_sha256::init(h);
    uint64_t total = 0;
    uint8_t block[64];
    for (;;) {
        f.read(reinterpret_cast<char*>(block), sizeof(block));
        const size_t n = (size_t)f.gcount(); total += n;
        if (n == sizeof(block)) { rta::update::detail_sha256::block(h, block); continue; }
        if (f.bad() || (!f.eof() && f.fail())) return {};
        uint8_t tail[128]{};
        if (n) std::memcpy(tail, block, n);
        tail[n] = 0x80;
        const size_t bytes = n < 56 ? 64 : 128;
        for (int i=0;i<8;++i) tail[bytes-1-i] = (uint8_t)((total*8)>>(i*8));
        rta::update::detail_sha256::block(h, tail);
        if (bytes==128) rta::update::detail_sha256::block(h, tail+64);
        return rta::update::detail_sha256::hex_of(h);
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
            en.digest = e["sha256"].s();
            en.ctime_ns = e["ctime_ns"].s();
            en.inode = (uint64_t)std::strtoull(e["inode"].s().c_str(), nullptr, 10);
            if (en.inode == 0 && e["inode"].type == rta::net::Json::Num) en.inode = (uint64_t)e["inode"].n();
            en.dev = (uint64_t)std::strtoull(e["dev"].s().c_str(), nullptr, 10);
            if (en.dev == 0 && e["dev"].type == rta::net::Json::Num) en.dev = (uint64_t)e["dev"].n();

            if (e.has("analysis_generation")) {
                en.hasGeneration = true;
                const auto& gj = e["analysis_generation"];
                if (gj.type == rta::net::Json::Str) {
                    en.generation = gj.str;
                    en.rawGenerationJson = "\"" + detail::json_escape(gj.str) + "\"";
                } else if (gj.type == rta::net::Json::Num) {
                    // Invalid numeric generations stay invalid; never narrow untrusted doubles to integers.
                    en.rawGenerationJson = "null";
                } else if (gj.type == rta::net::Json::Bool) {
                    en.rawGenerationJson = gj.b ? "true" : "false";
                } else if (gj.type == rta::net::Json::Null) {
                    en.rawGenerationJson = "null";
                } else {
                    en.rawGenerationJson = "null";
                }
            }

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
            const auto& q = hj["quality"];
            h.hasQuality = q["available"].b;
            h.quality.valid = h.hasQuality;
            h.quality.fs = h.fs; h.quality.channels = h.channels;
            h.quality.thdnDb = q["thdn_db"].n();
            h.quality.thdnPct = q["thdn_pct"].n();
            h.quality.nonTonalDb = q["non_tonal_db"].n();
            h.quality.imdDb = q["imd_db"].n();
            h.quality.noiseFloorDbfs = q["noise_floor_dbfs"].n();
            h.quality.spectralMinDbfs = q["spectral_min_dbfs"].n();
            h.quality.snrDb = q["snr_db"].n();
            h.quality.centroidHz = q["centroid_hz"].n();
            h.quality.tiltDbPerOct = q["tilt_db_per_oct"].n();
            h.quality.rolloff95Hz = q["rolloff95_hz"].n();
            h.quality.hfRatio10kDb = q["hf_ratio_10k_db"].n();
            h.quality.peakDbfs = q["peak_dbfs_q"].n();
            h.quality.rmsDbfs = q["rms_dbfs"].n();
            h.quality.clippedSamples = q["clipped_samples"].n();
            h.quality.clippedPct = q["clipped_pct"].n();
            h.quality.clippedRuns = q["clipped_runs"].n();
            h.quality.longestClipRun = q["longest_clip_run"].n();
            h.quality.crestDb = q["crest_db"].n();
            h.quality.channelCorr = q["channel_corr"].n();
            h.quality.monoLossDb = q["mono_loss_db"].n();
            h.quality.sideMidDb = q["side_mid_db"].n();
            h.quality.dynP95P10Db = q["dyn_p95_p10_db"].n();
            h.quality.dynCentroidDbfs = q["dyn_centroid_dbfs"].n();
            h.quality.quietP10Dbfs = q["quiet_p10_dbfs"].n();
            h.quality.silencePct = q["silence_pct"].n();
            h.quality.spectralWindows = q["spectral_windows"].n();
            h.quality.thdnAvailable = q["thdn_available"].b;
            h.quality.imdAvailable = q["imd_available"].b;
            h.quality.stereo = q["stereo"].b;
            h.quality.thdnMethod = q["thdn_method"].s();
            h.quality.imdNote = q["imd_note"].s();
            h.quality.note = q["note"].s();
            entries_[normalize_path_key(p)] = std::move(en);
        }
    }

    // 命中判定：
    //  1. 路径匹配；
    //  2. 分析代际匹配当前代（缺失/未知/未来/非法代际一律 miss）；
    //  3. 强身份（mtime, size, ctime_ns, inode, dev）完整存在且全等 → O(1) 极速命中！
    //  4. 若缓存条目未携带 inode/ctime_ns（或测试注入的虚拟三元组）：
    //     如果存在有效 digest，对真实文件做全内容哈希核验（旧 schema 只有 mtime/size 无 sha256 则 miss 重算）。
    bool lookup(const std::string& path, int64_t mtime, int64_t size, TrackHealth& out) const {
        if (!loadError_.empty()) return false;
        const auto it = entries_.find(normalize_path_key(path));
        if (it == entries_.end()) return false;
        if (!it->second.hasGeneration || it->second.generation != kCurrentAnalysisGeneration) return false;
        if (it->second.mtime != mtime || it->second.size != size) return false;
        if (it->second.digest.empty()) return false; // 旧 schema 缺少 digest，触发重新分析

        // 如果缓存条目具备强身份元数据 (ctime_ns 非空且 inode 非 0)，且当前文件实际存在
        const FileIdentity currId = FileIdentity::from_path(path);
        if (currId.valid && !it->second.ctime_ns.empty() && it->second.inode != 0) {
            // 真实物理文件强身份匹配：mtime, size, inode, dev, ctime_ns 比对
            if (currId.mtime == it->second.mtime &&
                currId.size == it->second.size &&
                currId.inode == it->second.inode &&
                currId.dev == it->second.dev &&
                currId.ctime_ns_str == it->second.ctime_ns) {
                out = it->second.health;
                return true;
            }
            // 强身份已记录但当前与文件状态不符（说明发生修改）
            return false;
        }

        // 条目未记录强身份（如老条目迁移，或使用自定义 mtime/size 的模拟测试），回退校验 content digest
        const std::string digest = health_content_digest(path);
        if (digest.empty() || digest != it->second.digest) return false;
        out = it->second.health;
        return true;
    }

    void upsert(const std::string& path, int64_t mtime, int64_t size, const TrackHealth& h,
                const std::string& verifiedDigest = {}, const FileIdentity* id = nullptr) {
        if (h.status != "ready") return; // 错误条目不入库
        std::string digest = verifiedDigest;
        if (digest.empty()) {
            digest = health_content_digest(path);
            if (digest.empty()) return; // 哈希失败不存入死条目
        }
        FileIdentity currentId;
        if (id && id->valid) {
            currentId = *id;
        } else {
            currentId = FileIdentity::from_path(path);
        }

        Entry en;
        en.mtime = mtime;
        en.size = size;
        en.health = h;
        en.digest = std::move(digest);
        en.hasGeneration = true;
        en.generation = kCurrentAnalysisGeneration;
        en.rawGenerationJson = "\"" + std::string(kCurrentAnalysisGeneration) + "\"";
        // 只有当 mtime 和 size 与真实磁盘文件一致时，才将磁盘文件的 inode/ctime 强身份绑定进条目
        if (currentId.valid && currentId.mtime == mtime && currentId.size == size) {
            en.ctime_ns = currentId.ctime_ns_str;
            en.inode = currentId.inode;
            en.dev = currentId.dev;
        }
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
            if (kv.second.hasGeneration && !kv.second.rawGenerationJson.empty()) {
                data += ",\"analysis_generation\":" + kv.second.rawGenerationJson;
            }
            data += ",\"mtime\":" + std::to_string((long long)kv.second.mtime);
            data += ",\"size\":" + std::to_string((long long)kv.second.size);
            data += ",\"sha256\":\"" + kv.second.digest + "\"";
            if (!kv.second.ctime_ns.empty()) data += ",\"ctime_ns\":\"" + kv.second.ctime_ns + "\"";
            if (kv.second.inode != 0) data += ",\"inode\":\"" + std::to_string(kv.second.inode) + "\"";
            if (kv.second.dev != 0) data += ",\"dev\":\"" + std::to_string(kv.second.dev) + "\"";
            data += ",\"health\":" + track_health_json(kv.second.health);
            data += "}";
        }
        data += "]";
        const std::string tmp = jsonPath_ + ".tmp";
        if (!write_whole_file(tmp, data)) return false;
        std::error_code ec;
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
        std::string digest;
        std::string ctime_ns; // 秒.纳秒 字符串
        uint64_t inode = 0;
        uint64_t dev = 0;
        std::string rawGenerationJson;
        bool hasGeneration = false;
        std::string generation;
    };

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
