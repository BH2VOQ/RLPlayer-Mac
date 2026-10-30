// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
#include "analysis/health_store.h"
#include <filesystem>
#include <fstream>
#include <cstdio>
#include <chrono>
#include <vector>
#include <random>
#include <unistd.h>
#include <sys/time.h>

int main() {
    namespace fs = std::filesystem;
    using namespace rta::analysis;
    bool ok = true;
    auto ck = [&](bool cond, const char* name) {
        printf("%s %s\n", cond ? "PASS" : "FAIL", name);
        if (!cond) ok = false;
    };

    auto root = fs::temp_directory_path() / ("rlp-cache-test-" + std::to_string(getpid()));
    fs::create_directories(root);
    auto file = (root / "audio.bin").string();
    auto cache = (root / "cache.json").string();

    // 1. 创建基准测试文件
    {
        std::ofstream f(file, std::ios::binary);
        std::string bytes(200000, 'a');
        f.write(bytes.data(), bytes.size());
    }
    const FileIdentity id0 = FileIdentity::from_path(file);
    ck(id0.valid, "FileIdentity::from_path valid");
    ck(!id0.ctime_ns_str.empty(), "FileIdentity ctime_ns_str non-empty string");

    TrackHealth h;
    h.status = "ready";
    h.hasQuality = true;
    h.quality.valid = true;
    h.quality.peakDbfs = -3.0;
    h.quality.thdnMethod = "single_tone";
    h.quality.note = "synthetic";
    h.fs = 48000; h.channels = 2; h.bits = 24;
    auto& q = h.quality;
    q.thdnDb = -71.125; q.thdnPct = 0.01234; q.thdnAvailable = true;
    q.nonTonalDb = -65.375; q.imdAvailable = true; q.imdDb = -68.625; q.imdNote = "IMD test";
    q.noiseFloorDbfs = -91.5; q.spectralMinDbfs = -99.25; q.snrDb = 70.75;
    q.centroidHz = 1234.5; q.tiltDbPerOct = -2.125; q.rolloff95Hz = 9876.5; q.hfRatio10kDb = -31.125;
    q.rmsDbfs = -15.875; q.clippedSamples = 7; q.clippedPct = 0.12345;
    q.clippedRuns = 2; q.longestClipRun = 4; q.crestDb = 12.875;
    q.stereo = true; q.channelCorr = -0.4321; q.monoLossDb = 3.875; q.sideMidDb = 8.625;
    q.dynP95P10Db = 9.375; q.dynCentroidDbfs = -18.125; q.quietP10Dbfs = -40.375;
    q.silencePct = 12.875; q.spectralWindows = 37;

    // 2. 存入强身份缓存
    HealthStore store(cache);
    store.upsert(file, id0.mtime, id0.size, h, {}, &id0);
    ck(store.save(), "HealthStore::save() ok");

    TrackHealth got;
    ck(store.lookup(file, id0.mtime, id0.size, got), "same content cache hit (O(1) fast key)");
    ck(got.hasQuality && got.quality.peakDbfs == -3.0 && got.quality.note == "synthetic", "quality preserved");

    // 3. 代际只描述分析算法；缺失/未知/未来/非法代际即使文件身份完全相同也必须 miss。
    // 这些回归只依赖 JSON 契约，能在旧头文件上编译并真实跑红。
    auto readText = [](const std::string& path) {
        std::ifstream f(path);
        return std::string(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    };
    auto writeText = [](const std::string& path, const std::string& text) {
        std::ofstream f(path); f << text;
    };
    const std::string baseline = readText(cache);
    const auto baselineJson = rta::net::json_parse(baseline);
    const auto& generation = baselineJson.at(0)["analysis_generation"];
    ck(generation.type == rta::net::Json::Str && !generation.str.empty(),
       "new upsert persists dedicated analysis_generation string");
    auto withGeneration = [&](const std::string& literal) {
        std::string text = baseline;
        const auto start = text.find(",\"analysis_generation\":");
        if (start != std::string::npos) text.erase(start, text.find(',', start + 1) - start);
        if (!literal.empty()) text.insert(2, "\"analysis_generation\":" + literal + ",");
        return text;
    };
    const auto staleCache = (root / "stale_cache.json").string();
    const auto otherFile = (root / "other.bin").string();
    writeText(otherFile, "independent entry");
    const auto otherId = FileIdentity::from_path(otherFile);
    const std::vector<std::string> staleGenerations = {
        "", "\"health-analysis-unknown\"", "\"health-analysis-999999\"", "\"\"", "123", "true", "null"
    };
    for (const auto& literal : staleGenerations) {
        writeText(staleCache, withGeneration(literal));
        HealthStore stale(staleCache);
        ck(stale.loadError().empty() && stale.size() == 1, "stale generation loads without destructive reset");
        TrackHealth untouched; untouched.quality.note = "unchanged-on-miss";
        ck(!stale.lookup(file, id0.mtime, id0.size, untouched), "missing/unknown/future/malformed analysis generation misses");
        ck(untouched.quality.note == "unchanged-on-miss", "generation miss does not return stale health");
        stale.upsert(otherFile, otherId.mtime, otherId.size, h);
        ck(stale.save(), "mixed stale/current entries save without resetting store");
        const auto saved = rta::net::json_parse(readText(staleCache));
        for (const auto& e : saved.arr) {
            if (e["path"].s() != normalize_path_key(file)) continue;
            const auto before = rta::net::json_parse(withGeneration(literal)).at(0)["analysis_generation"];
            if (before.type == rta::net::Json::Str)
                ck(e["analysis_generation"].type == before.type && e["analysis_generation"].str == before.str,
                   "save preserves original stale string generation exactly");
            else
                ck(e["analysis_generation"].type != rta::net::Json::Str,
                   "save never launders missing/malformed generation into current string");
        }
        HealthStore resaved(staleCache);
        ck(!resaved.lookup(file, id0.mtime, id0.size, untouched), "stale entry remains miss across save/reload");
        ck(resaved.lookup(otherFile, otherId.mtime, otherId.size, got), "fresh upsert beside stale entry hits after reload");
        resaved.upsert(file, id0.mtime, id0.size, h);
        ck(resaved.save(), "explicit fresh upsert replaces stale generation");
        HealthStore refreshed(staleCache);
        ck(refreshed.lookup(file, id0.mtime, id0.size, got), "reanalyzed entry receives current generation and hits");
    }
    // A current generation without strong identity must retain the digest fallback.
    {
        auto digestOnly = baseline;
        for (const char* key : {"ctime_ns", "inode", "dev"}) {
            const auto start = digestOnly.find(std::string(",\"") + key + "\":");
            if (start != std::string::npos) digestOnly.erase(start, digestOnly.find(',', start + 1) - start);
        }
        writeText(staleCache, digestOnly);
        HealthStore digestStore(staleCache);
        ck(digestStore.lookup(file, id0.mtime, id0.size, got), "current generation digest fallback still hits");
    }
    // Corruption must not be overwritten even after a successful fresh upsert in memory.
    for (const std::string broken : {std::string(), std::string("not-json"), std::string("{}")}) {
        writeText(staleCache, broken);
        HealthStore damaged(staleCache);
        damaged.upsert(file, id0.mtime, id0.size, h);
        ck(!damaged.loadError().empty() && !damaged.save() && readText(staleCache) == broken,
           "damaged cache is reported and original bytes are never overwritten");
    }

    // 4. 落盘重载后验证强身份元数据与 quality 字段仍然完整保存
    {
        HealthStore reload(cache);
        ck(reload.lookup(file, id0.mtime, id0.size, got), "persisted quality and strong identity survives reload");
        ck(got.hasQuality && got.quality.peakDbfs == -3.0 && got.quality.note == "synthetic", "reloaded quality exact match");
        ck(track_health_json(got) == track_health_json(h), "every serialized health/quality field survives current-generation reload");
    }

    // 4. 旧 schema 无 sha256 或无强身份时的处理验证 (保留旧 schema miss 逻辑)
    {
        auto oldCachePath = (root / "old_cache.json").string();
        {
            std::ofstream f(oldCachePath);
            f << "[{\"path\":\"" << file << "\",\"mtime\":" << id0.mtime << ",\"size\":" << id0.size
              << ",\"health\":{\"status\":\"ready\",\"dr_db\":10.0}}]";
        }
        HealthStore oldStore(oldCachePath);
        TrackHealth oldGot;
        ck(!oldStore.lookup(file, id0.mtime, id0.size, oldGot), "old schema without digest/strong identity misses as expected");
    }

    // 5. 中段篡改但人为恢复 mtime 和 size：ctime_ns / inode 防中段篡改生效
    usleep(10000); // 确保产生微量时间差
    {
        std::fstream f(file, std::ios::binary | std::ios::in | std::ios::out);
        f.seekp(100000);
        f.put('b');
    }
    // 人为篡改 mtime 回原来的数值 (utimes)
    {
        struct timeval tv[2];
        tv[0].tv_sec = id0.mtime / 1000;
        tv[0].tv_usec = (int)((id0.mtime % 1000) * 1000);
        tv[1].tv_sec = id0.mtime / 1000;
        tv[1].tv_usec = (int)((id0.mtime % 1000) * 1000);
        utimes(file.c_str(), tv);
    }
    ck(!store.lookup(file, id0.mtime, id0.size, got), "middle mutation with restored mtime and size misses (ctime/digest invalidation)");

    // 6. 不存 hash 失败死条目与非 ready 错误条目
    {
        TrackHealth errH;
        errH.status = "error";
        errH.error = "read failed";
        store.upsert(file, id0.mtime, id0.size, errH);
        TrackHealth dummy;
        ck(!store.lookup(file, id0.mtime, id0.size, dummy), "error track_health not stored in cache");

        store.upsert((root / "not_exist.bin").string(), 123, 456, h);
        ck(!store.lookup((root / "not_exist.bin").string(), 123, 456, dummy), "hash failure / non-existent file not stored as dead entry");
    }

    // 7. 50MB 重复命中实测统计 (O(1) fast key vs 重复全量哈希)
    {
        auto largeFile = (root / "blob_50mb.bin").string();
        const size_t sz50 = 50 * 1024 * 1024;
        {
            std::ofstream f(largeFile, std::ios::binary);
            std::vector<char> buf(1024 * 1024, 'z');
            for (size_t i = 0; i < 50; ++i) f.write(buf.data(), buf.size());
        }
        const FileIdentity id50 = FileIdentity::from_path(largeFile);
        TrackHealth h50;
        h50.status = "ready";
        h50.lufs = -14.0;
        store.upsert(largeFile, id50.mtime, id50.size, h50, {}, &id50);

        // 第一次测强身份 O(1) 命中耗时
        auto t0 = std::chrono::steady_clock::now();
        const int iters = 1000;
        int hitCount = 0;
        for (int i = 0; i < iters; ++i) {
            TrackHealth res;
            if (store.lookup(largeFile, id50.mtime, id50.size, res)) hitCount++;
        }
        auto t1 = std::chrono::steady_clock::now();
        double elapsed_us = std::chrono::duration<double, std::micro>(t1 - t0).count();
        printf("50MB cache fast lookup %d iterations: total %.2f ms, avg %.2f us/hit, hits=%d\n",
               iters, elapsed_us / 1000.0, elapsed_us / iters, hitCount);
        ck(hitCount == iters, "50MB repeated cache hits 100%");
        ck((elapsed_us / iters) < 100.0, "50MB O(1) lookup under 100 microseconds");
    }

    fs::remove_all(root);
    return ok ? 0 : 1;
}
