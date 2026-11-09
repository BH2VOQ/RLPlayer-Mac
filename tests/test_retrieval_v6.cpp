// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_retrieval_v6.cpp — 1.1.5-beta2 U5/#21a/#21b/#21c(summary)：专辑上下文与缓存 v6
//
// 真实判据（替换 Lead 预置的必红骨架）：
//   1) album 键 A/B 隔离 + 无 album 回退旧键 + 旧 query 逐字断言 + album query 模板
//   2) v3/v4/v5 缓存读出 cache_ver 与 expires_at=1（stale，内容仍可解析）、v6 写入后 fresh
//   3) 合法引用 5 例全通过 + 伪造/跨实体各 3 例整份拒绝（attribution_reject diag）
//   4) select_prompt_materials 剔除计数正确、survivors 不含被拒 URL、attribution 只给 survivors
//   5) 综合 prompt 默认不过滤（旧字符串断言不动）；retrieval_fetch_track 空 title 0 网络
// 全部离线，零网络零音频。判据见 PLAN-1.1.5-beta2.md §1.1/§1.2/§1.3/§1.4/§1.6。
#include "meta/retrieval.h"
#include "platform/console.h"

#include <cstdio>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

using namespace rta::meta;
namespace fsx = std::filesystem;

static int g_fail = 0;
static void ck(bool cond, const std::string& what, const std::string& detail = "") {
    if (cond) std::printf("  [PASS] %s\n", what.c_str());
    else { std::printf("  [FAIL] %s  %s\n", what.c_str(), detail.c_str()); ++g_fail; }
}

// 构造一份最小可解析的 summary 缓存（citations / sections 必须是数组）
static std::string minimal_summary_json(int v, long long expiresAt, const std::string& heading) {
    std::string s = "{\"v\":" + std::to_string(v) + ",\"ok\":true,\"generated_at\":1792690000,"
                    "\"expires_at\":" + std::to_string(expiresAt) + ",\"model\":\"deepseek-flash\","
                    "\"disclaimer\":\"d\",\"fields\":{},\"sections\":[{\"heading\":\"" + heading +
                    "\",\"paragraphs\":[{\"text\":\"t\",\"citations\":[\"c1\"]}]}],"
                    "\"citations\":[{\"id\":\"c1\",\"title\":\"t\",\"url\":\"https://zh.wikipedia.org/wiki/X\","
                    "\"source\":\"w\",\"fetched_at\":1792690000}],\"materials_used\":[],"
                    "\"from_cache\":false,\"offline\":false,\"unverified\":false}";
    return s;
}

// 构造一份带指定 citations 的综合回包（每段引用全部 citation id）
static std::string synthesis_json(const std::vector<std::string>& urls) {
    std::string s = "{\"disclaimer\":\"仅依据下方来源材料综合整理；可能不完整，请以来源为准\","
                    "\"sections\":[{\"heading\":\"概述\",\"paragraphs\":[{\"text\":\"事实陈述。\",\"citations\":[";
    for (size_t i = 0; i < urls.size(); ++i) {
        if (i) s += ",";
        s += "\"c" + std::to_string(i + 1) + "\"";
    }
    s += "]}]}],\"citations\":[";
    for (size_t i = 0; i < urls.size(); ++i) {
        if (i) s += ",";
        s += "{\"id\":\"c" + std::to_string(i + 1) + "\",\"title\":\"来源" +
             std::to_string(i + 1) + "\",\"url\":\"" + urls[i] +
             "\",\"source\":\"wikipedia-zh\",\"fetched_at\":1792690000}";
    }
    s += "]}";
    return s;
}

int main() {
    rta::platform::enable_utf8_console();
    std::printf("== meta/retrieval.h v6 专辑上下文 / 归属 / 缓存代际 ==\n");

    const std::string title = "六等星の夜";
    const std::string artist = "Aimer";
    const std::string albA = "Sleepless Nights";
    const std::string albB = "BEST SELECTION";
    const long long now = (long long)std::time(nullptr);

    // ---------------- 1) 实体键与 query ----------------
    std::printf("-- 1. summary_track_entity_id / build_track_query --\n");
    {
        const std::string oldId = entity_make_id("track",
            entity_norm(artist) + "\x1f" + entity_norm(title));
        const std::string noAlbum = summary_track_entity_id(title, artist, "");
        ck(noAlbum == oldId, "album 空 == 旧键（逐字回退）", noAlbum + " vs " + oldId);

        const std::string idA = summary_track_entity_id(title, artist, albA);
        const std::string idB = summary_track_entity_id(title, artist, albB);
        ck(idA != idB, "同一 title+artist、不同 album -> 不同实体 id");
        ck(idA != oldId && idB != oldId, "带 album 的键与旧键都不同");
        ck(summary_track_entity_id(title, artist, "") == summary_track_entity_id(title, artist, ""),
           "同输入幂等");

        // 缓存路径隔离：A 写入后 B 与旧键都读不到
        const fsx::path base = fsx::temp_directory_path() / "rta_test_retrieval_v6";
        std::error_code ec;
        fsx::remove_all(base, ec);
        fsx::create_directories(base, ec);
        const std::string baseDir = meta_string_of(base);
        SummaryResult sr;
        sr.ok = true;
        sr.generated_at = now;
        sr.expires_at = now + 7 * 86400;
        sr.disclaimer = "d";
        SummarySection sec; sec.heading = "概述";
        SummaryParagraph p; p.text = "t"; p.citations = { "c1" };
        sec.paragraphs.push_back(p); sr.sections.push_back(sec);
        SummaryCitation c; c.id = "c1"; c.url = "https://zh.wikipedia.org/wiki/X"; c.source = "w";
        sr.citations.push_back(c);
        ck(summary_save_cache(baseDir, idA, "zh", sr), "写入 A 的缓存");
        SummaryResult out;
        ck(summary_load_cache(baseDir, idA, "zh", out), "A 能读回自己的缓存");
        ck(!summary_load_cache(baseDir, idB, "zh", out), "B 读不到 A 的缓存（A/B 隔离）");
        ck(!summary_load_cache(baseDir, oldId, "zh", out), "无 album 请求读不到有 album 的缓存");
        ck(summary_cache_path(baseDir, idA, "zh") != summary_cache_path(baseDir, idB, "zh"),
           "A/B 缓存文件路径不同");

        // 旧 query：album 空时逐字沿用
        ck(build_track_query(title, artist, "", {}, "zh") ==
           "Aimer 六等星の夜 歌曲 作词 作曲 编曲 发行", "旧 zh query 逐字不变");
        ck(build_track_query(title, artist, "", {}, "ja") ==
           "Aimer 六等星の夜 楽曲 作詞 作曲 編曲", "旧 ja query 逐字不变");
        ck(build_track_query(title, artist, "", {}, "en") ==
           "Aimer 六等星の夜 song credits release lyrics", "旧 en query 逐字不变");
        ck(build_track_query(title, "", "", {}, "zh") ==
           "六等星の夜 歌曲 作词 作曲 编曲 发行", "无 artist 的旧 zh query 逐字不变");
        ck(build_track_query(title, artist, "", { {"genre", "J-POP"} }, "zh") ==
           "Aimer 六等星の夜 歌曲 作词 作曲 编曲 发行", "album 空时 album_tags 不改旧 query");

        // album 非空：模板 album + " " + title，artist 不在 album+title 中才追加
        ck(build_track_query(title, artist, albA, {}, "zh") ==
           "Sleepless Nights 六等星の夜 Aimer 歌曲 作词 作曲 编曲 发行",
           "album query = album+title+artist+语言后缀");
        ck(build_track_query(title, artist, albA, {}, "ja") ==
           "Sleepless Nights 六等星の夜 Aimer 楽曲 作詞 作曲 編曲", "album query ja 后缀");
        ck(build_track_query(title, artist, albA, {}, "en") ==
           "Sleepless Nights 六等星の夜 Aimer song credits release lyrics", "album query en 后缀");
        ck(build_track_query(title, artist, "Aimer Best", {}, "zh") ==
           "Aimer Best 六等星の夜 歌曲 作词 作曲 编曲 发行",
           "artist 已出现在 album+title 时不再追加");
        ck(build_track_query(title, artist, albA, { {"genre", "J-POP"} }, "zh") ==
           "Sleepless Nights 六等星の夜 Aimer 歌曲 作词 作曲 编曲 发行 J-POP",
           "album_tags[genre] 作为 query 提示追加在末尾，不进缓存键");
        ck(summary_track_entity_id(title, artist, albA) ==
           summary_track_entity_id(title, artist, albA), "album_tags 不参与键（同 album 同键）");
    }

    // ---------------- 2) 缓存代际 v3/v4/v5 -> stale，v6 -> fresh ----------------
    std::printf("-- 2. kSummaryCacheVer=6 与旧代际 stale --\n");
    {
        ck(kSummaryCacheVer == 6, "kSummaryCacheVer == 6");
        const long long future = now + 7 * 86400;
        int badOld = 0;
        for (int v = 3; v <= 5; ++v) {
            const std::string js = minimal_summary_json(v, future, "旧代际");
            SummaryResult r;
            std::string err;
            const bool ok = summary_from_json(js, r, &err);
            if (!ok) { ++badOld; std::printf("  [FAIL] v%d summary_from_json 返回 false（旧缓存必须仍能解析）err=%s\n", v, err.c_str()); continue; }
            if (r.cache_ver != v) { ++badOld; std::printf("  [FAIL] v%d cache_ver=%d\n", v, r.cache_ver); }
            if (r.expires_at != 1) { ++badOld; std::printf("  [FAIL] v%d expires_at=%lld（应为 1）\n", v, r.expires_at); }
            if (!r.sections.empty() && r.sections[0].heading == "旧代际" &&
                r.sections[0].paragraphs.size() == 1) {
                // 内容确实解析出来了
            } else { ++badOld; std::printf("  [FAIL] v%d 旧缓存正文没解析出来\n", v); }
            if (!summary_is_expired(r, now)) { ++badOld; std::printf("  [FAIL] v%d 未判为过期\n", v); }
            if (summary_cache_current(r)) { ++badOld; std::printf("  [FAIL] v%d 被判为 current\n", v); }
        }
        ck(badOld == 0, "v3/v4/v5 均解析成功、cache_ver 正确、expires_at=1、stale、非 current",
           "bad=" + std::to_string(badOld));

        // 无 v 字段（v0）同样 stale
        {
            SummaryResult r;
            ck(summary_from_json(minimal_summary_json(0, future, "v0"), r), "v0 缓存仍能解析");
            ck(r.expires_at == 1 && summary_is_expired(r, now) && !summary_cache_current(r),
               "v0 也是 stale");
        }

        // v6 写入后 fresh
        SummaryResult fresh;
        fresh.ok = true;
        fresh.generated_at = now;
        fresh.expires_at = future;
        fresh.disclaimer = "d";
        SummarySection sec; sec.heading = "概述";
        SummaryParagraph p; p.text = "t"; p.citations = { "c1" };
        sec.paragraphs.push_back(p); fresh.sections.push_back(sec);
        SummaryCitation c; c.id = "c1"; c.url = "https://zh.wikipedia.org/wiki/ZARD"; c.source = "w";
        fresh.citations.push_back(c);
        const std::string js = summary_to_json(fresh);
        ck(js.find("\"v\": 6") != std::string::npos, "summary_to_json 写 \"v\": 6");
        SummaryResult loaded;
        ck(summary_from_json(js, loaded), "v6 缓存可解析");
        ck(loaded.cache_ver == 6, "v6 读出 cache_ver=6");
        ck(summary_cache_current(loaded), "v6 summary_cache_current=true");
        ck(!summary_is_expired(loaded, now), "v6 未过期");
        ck(loaded.sections.size() == 1 && loaded.citations.size() == 1, "v6 round-trip 结构无损");

        // 主命中判据：v6 且未过期才算 fresh；旧代际即使在磁盘也过不了这个合取
        {
            const fsx::path base = fsx::temp_directory_path() / "rta_test_retrieval_v6_fresh";
            std::error_code ec;
            fsx::remove_all(base, ec);
            fsx::create_directories(base, ec);
            const std::string baseDir = meta_string_of(base);
            const std::string eid = entity_id(EntityKind::Person, "ZARD");
            ck(summary_save_cache(baseDir, eid, "zh", fresh), "落盘 v6 缓存");
            SummaryResult disk;
            ck(summary_load_cache(baseDir, eid, "zh", disk) && summary_cache_current(disk) &&
               !summary_is_expired(disk, now), "磁盘 v6 缓存满足 fresh 合取");
            // 覆盖成 v5 且 expires_at 很新：仍必须判 stale（expires_at 被强制为 1）
            {
                std::ofstream f(summary_cache_path(baseDir, eid, "zh"), std::ios::binary | std::ios::trunc);
                f << minimal_summary_json(5, future, "旧");
            }
            SummaryResult oldDisk;
            ck(summary_load_cache(baseDir, eid, "zh", oldDisk) && oldDisk.cache_ver == 5 &&
               oldDisk.expires_at == 1 && !summary_cache_current(oldDisk) &&
               summary_is_expired(oldDisk, now), "磁盘 v5 缓存即使原 expires 很新也判 stale");
            fsx::remove_all(base, ec);
        }
    }

    // ---------------- 3) parse_synthesis_reply 新重载：⑥ 归属硬门 ----------------
    std::printf("-- 3. AttributionMap 引用归属：合法 5 例 / 伪造 3 例 / 跨实体 3 例 --\n");
    {
        // 5 个合法引用（其中一条用尾斜杠，验证归一化后仍能命中）
        const std::vector<std::string> legal = {
            "https://zh.wikipedia.org/wiki/Aimer",
            "https://www.discogs.com/artist/Aimer",
            "https://musicbrainz.org/artist/123",
            "https://music.apple.com/album/123/",
            "https://monster-siren.hypergryph.com/song/1",
        };
        AttributionMap amap;
        for (size_t i = 0; i < legal.size(); ++i) {
            CitationAttribution ca;
            ca.kind = PageKind::Track;
            ca.belongs = true;
            ca.reason = "";
            amap[normalize_url_for_compare(legal[i])] = ca;
        }
        int badLegal = 0;
        for (size_t i = 0; i < legal.size(); ++i) {
            const std::string js = synthesis_json({ legal[i] });
            const SummaryResult r = parse_synthesis_reply(js, legal, true, &amap);
            if (!r.ok || r.sections.size() != 1 || r.citations.size() != 1 ||
                r.diag.find("attribution_reject") != std::string::npos) {
                ++badLegal;
                std::printf("  [FAIL] 合法引用#%zu 被拒 ok=%d err='%s' diag='%s'\n",
                            i, r.ok ? 1 : 0, r.error.c_str(), r.diag.c_str());
            }
        }
        ck(legal.size() >= 5 && badLegal == 0, "合法引用 5 例全通过（含 URL 尾斜杠归一化）",
           "bad=" + std::to_string(badLegal));

        // 多引用全合法也要通过
        {
            const SummaryResult r = parse_synthesis_reply(synthesis_json(legal), legal, true, &amap);
            ck(r.ok && r.citations.size() == legal.size(), "5 条引用同时全合法 -> 整份通过");
        }

        // 伪造：URL 在 allowed_urls 但不在 attribution 表（或表项被抹掉）
        int badForge = 0;
        {
            const std::vector<std::string> forged = {
                "https://evil.example.com/fake",
                "https://zh.wikipedia.org/wiki/NotInMap",
                "https://www.discogs.com/release/999999",
            };
            for (size_t i = 0; i < forged.size(); ++i) {
                const std::string js = synthesis_json({ forged[i] });
                const SummaryResult r = parse_synthesis_reply(js, forged, true, &amap);
                if (r.ok || r.error.find(forged[i]) == std::string::npos ||
                    r.error.find("归属") == std::string::npos ||
                    r.diag.find("attribution_reject=" + forged[i]) == std::string::npos ||
                    !r.sections.empty() || !r.citations.empty() || r.validation_ok) {
                    ++badForge;
                    std::printf("  [FAIL] 伪造#%zu ok=%d err='%s' diag='%s'\n",
                                i, r.ok ? 1 : 0, r.error.c_str(), r.diag.c_str());
                }
            }
        }
        ck(badForge == 0, "伪造引用 3 例整份拒绝（error 带 url+原因、diag=attribution_reject、无部分接受）",
           "bad=" + std::to_string(badForge));

        // 跨实体：表项 belongs=false，reason 写明类型不符
        int badCross = 0;
        {
            const std::vector<std::string> cross = {
                "https://example.com/label/SME",
                "https://example.com/series/Arknights",
                "https://example.com/group/ZARD",
            };
            AttributionMap crossMap = amap;
            for (size_t i = 0; i < cross.size(); ++i) {
                CitationAttribution ca;
                ca.kind = (i == 0) ? PageKind::Label : ((i == 1) ? PageKind::Series : PageKind::Group);
                ca.belongs = false;
                ca.reason = "跨实体页面: 类型" + std::string(page_kind_tag(ca.kind)) + " 与查询track 不符";
                crossMap[normalize_url_for_compare(cross[i])] = ca;
            }
            for (size_t i = 0; i < cross.size(); ++i) {
                const std::string js = synthesis_json({ cross[i] });
                const SummaryResult r = parse_synthesis_reply(js, cross, true, &crossMap);
                if (r.ok || r.error.find(cross[i]) == std::string::npos ||
                    r.error.find("跨实体页面") == std::string::npos ||
                    r.diag.find("attribution_reject=" + cross[i]) == std::string::npos ||
                    !r.sections.empty()) {
                    ++badCross;
                    std::printf("  [FAIL] 跨实体#%zu ok=%d err='%s' diag='%s'\n",
                                i, r.ok ? 1 : 0, r.error.c_str(), r.diag.c_str());
                }
            }
        }
        ck(badCross == 0, "跨实体引用 3 例整份拒绝（reason 含「跨实体页面」）",
           "bad=" + std::to_string(badCross));

        // nullptr / 空 map 保持旧行为
        {
            const std::string js = synthesis_json({ "https://evil.example.com/fake" });
            const std::vector<std::string> fakeAllowed = { "https://evil.example.com/fake" };
            const SummaryResult r1 = parse_synthesis_reply(js, fakeAllowed, true, nullptr);
            ck(r1.ok, "attribution=nullptr 保持旧行为（不启用 ⑥）");
            AttributionMap empty;
            const SummaryResult r2 = parse_synthesis_reply(js, fakeAllowed, true, &empty);
            ck(r2.ok, "空 attribution map 保持旧行为");
            // 旧 ①–⑤ 仍然生效：URL 不在 allowed 集合时即使有 attribution 也拒绝
            const SummaryResult r3 = parse_synthesis_reply(js, std::vector<std::string>{}, true, &amap);
            ck(!r3.ok && r3.error.find("不在允许来源集合") != std::string::npos,
               "旧 ④ 防幻觉硬门仍先于 ⑥ 生效");
            // 旧 2 参数重载签名/行为不变
            const SummaryResult r4 = parse_synthesis_reply(js, fakeAllowed);
            ck(r4.ok, "旧 2 参数重载行为不变（test_retrieval 字符串断言依赖）");
        }
    }

    // ---------------- 4) select_prompt_materials ----------------
    std::printf("-- 4. select_prompt_materials 剔除计数 / survivors / attribution --\n");
    {
        std::vector<KnowledgeMaterial> mats;
        std::vector<SearchHit> hits;
        // 合法材料：歌曲页，名称/艺术家/专辑证据齐
        {
            KnowledgeMaterial m;
            m.source = "wikipedia-zh"; m.title = "六等星の夜 - Aimer 歌曲";
            m.url = "https://example.com/track/六等星の夜";
            m.text = "作词 作曲 编曲，所属专辑 Sleepless Nights，演唱 Aimer";
            mats.push_back(m);
        }
        // 跨实体材料：厂牌页（kdrop）
        {
            KnowledgeMaterial m;
            m.source = "wikipedia-zh"; m.title = "厂牌 唱片公司";
            m.url = "https://example.com/label/SME";
            m.text = "旗下艺人 六等星の夜 Aimer Sleepless Nights";
            mats.push_back(m);
        }
        // 缺艺术家材料（udrop）
        {
            KnowledgeMaterial m;
            m.source = "wikipedia-zh"; m.title = "六等星の夜 歌曲";
            m.url = "https://example.com/track/missing-artist";
            m.text = "作词 作曲 Sleepless Nights";
            mats.push_back(m);
        }
        // 合法命中：发行页（Track 请求兼容 Release），证据齐
        {
            SearchHit h;
            h.title = "Sleepless Nights 专辑 Aimer";
            h.url = "https://www.discogs.com/release/123";
            h.snippet = "曲目列表：六等星の夜，Sleepless Nights，Aimer";
            hits.push_back(h);
        }
        // 伪造命中：缺名称（udrop）
        {
            SearchHit h;
            h.title = "别的歌 歌曲";
            h.url = "https://example.com/track/other-song";
            h.snippet = "作词 作曲 Aimer Sleepless Nights";
            hits.push_back(h);
        }
        // 跨实体命中：人物页（kdrop）
        {
            SearchHit h;
            h.title = "Aimer 歌手 简介";
            h.url = "https://musicbrainz.org/artist/Aimer";
            h.snippet = "出生于日本 六等星の夜 Sleepless Nights";
            hits.push_back(h);
        }

        const PromptMaterialSelection sel = select_prompt_materials(
            EntityKind::Track, "六等星の夜", "Aimer", "Sleepless Nights", mats, hits);
        ck(sel.dropped_incompatible == 2, "kdrop=2（厂牌页 + 人物页）",
           "kdrop=" + std::to_string(sel.dropped_incompatible));
        ck(sel.dropped_unattributed == 2, "udrop=2（缺艺术家 + 缺名称）",
           "udrop=" + std::to_string(sel.dropped_unattributed));
        ck(sel.materials.size() == 1 && sel.hits.size() == 1,
           "survivors: 1 material + 1 hit",
           "mats=" + std::to_string(sel.materials.size()) + " hits=" + std::to_string(sel.hits.size()));
        ck(sel.diag() == "kdrop=2 udrop=2", "diag() = kdrop=2 udrop=2", sel.diag());

        const std::vector<std::string> rejected = {
            "https://example.com/label/SME",
            "https://example.com/track/missing-artist",
            "https://example.com/track/other-song",
            "https://musicbrainz.org/artist/Aimer",
        };
        int badSurv = 0;
        for (const auto& m : sel.materials) {
            for (const auto& u : rejected) if (m.url == u) ++badSurv;
        }
        for (const auto& h : sel.hits) {
            for (const auto& u : rejected) if (h.url == u) ++badSurv;
        }
        ck(badSurv == 0, "survivors 不含任何被拒 URL");
        ck(sel.attribution.size() == 2, "attribution map 只给 2 个 survivor",
           "size=" + std::to_string(sel.attribution.size()));
        int badAttr = 0;
        for (const auto& kv : sel.attribution) {
            if (!kv.second.belongs || !kv.second.reason.empty()) ++badAttr;
        }
        ck(badAttr == 0, "attribution 每个 survivor belongs=true 且 reason 空");
        ck(sel.attribution.count(normalize_url_for_compare("https://example.com/track/六等星の夜")) == 1 &&
           sel.attribution.count(normalize_url_for_compare("https://www.discogs.com/release/123")) == 1,
           "attribution 键是 normalize_url_for_compare(url)");

        // 用 survivors 的 allowed_urls + attribution 走解析：合法引用通过、被拒 URL 整份拒绝
        {
            std::vector<std::string> allowed;
            for (const auto& m : sel.materials) allowed.push_back(m.url);
            for (const auto& h : sel.hits) allowed.push_back(h.url);
            const std::string js = synthesis_json(allowed);
            const SummaryResult r = parse_synthesis_reply(js, allowed, true, &sel.attribution);
            ck(r.ok && r.citations.size() == 2, "survivors 引用全合法 -> 整份通过");
            const std::string badJs = synthesis_json({ "https://example.com/label/SME" });
            const SummaryResult br = parse_synthesis_reply(badJs, allowed, false, &sel.attribution);
            ck(!br.ok && br.diag.find("attribution_reject") != std::string::npos,
               "被剔除 URL 即使回包引用也整份拒绝");
        }
    }

    // ---------------- 5) 默认综合 prompt 不过滤 + track 空 title 0 网络 ----------------
    std::printf("-- 5. 默认路径兼容与 track 入口硬保护 --\n");
    {
        KnowledgeMaterial m;
        m.source = "wikipedia-zh"; m.title = "不相关页面";
        m.url = "https://zh.wikipedia.org/wiki/Ivoris";
        m.text = "一些不含实体名的 mock 正文";
        SearchHit h;
        h.title = "不相关命中"; h.url = "https://zh.wikipedia.org/wiki/Other";
        h.snippet = "也不含实体名";
        const std::vector<LlmMessage> msgs = build_synthesis_prompt("Ivoris", { m }, { h });
        ck(msgs.size() == 2 && msgs[1].content.find(m.url) != std::string::npos &&
           msgs[1].content.find(h.url) != std::string::npos,
           "默认 build_synthesis_prompt 保留不含实体名的 mock 材料（metacache 夹具不变红）");
        ck(msgs[0].content.find("只依据材料") != std::string::npos &&
           msgs[0].content.find("每段至少 1 条引用") != std::string::npos,
           "旧 prompt 硬约束字符串不变");

        // 新函数：survivors 材料块追加「页面类型: ...」行
        AttributionMap amap;
        CitationAttribution ca; ca.kind = PageKind::Track; ca.belongs = true;
        amap[normalize_url_for_compare(m.url)] = ca;
        amap[normalize_url_for_compare(h.url)] = ca;
        const std::vector<LlmMessage> strictMsgs = build_synthesis_prompt_attributed(
            "Ivoris", { m }, { h }, "zh", "", amap);
        ck(strictMsgs.size() == 2 &&
           strictMsgs[1].content.find("页面类型: 歌曲") != std::string::npos,
           "build_synthesis_prompt_attributed 给 survivors 追加「页面类型: 歌曲」行");
        ck(strictMsgs[0].content == msgs[0].content &&
           strictMsgs[0].content.find("只依据材料") != std::string::npos,
           "同 lang/kindLabel 下新函数 system 消息与旧函数逐字一致");

        // retrieval_fetch_track 空 title：0 网络（mock transport 计数必须全 0）
        int calls = 0;
        LlmConfig cfg;
        cfg.apiKey = "test-key";          // 有 key 也不能联网，证明是入口早返回
        cfg.model = "deepseek-flash";
        cfg.usagePath = meta_string_of(fsx::temp_directory_path() / "rta_test_retrieval_v6_usage.json");
        cfg.transport = [&calls](const std::string&, const std::string&,
                                  const std::vector<std::string>&) {
            ++calls;
            rta::net::HttpResponse resp;
            resp.ok = false; resp.status = 0;
            return resp;
        };
        RetrievalOptions ro;
        ro.metabase = meta_string_of(fsx::temp_directory_path() / "rta_test_retrieval_v6_empty");
        ro.llm_cfg = cfg;
        ro.enable_search = true;
        const SummaryResult empty = retrieval_fetch_track("", "Aimer", "zh", ro);
        ck(!empty.ok && empty.error.find("资料不足") != std::string::npos,
           "空 title 直接返回 insufficient 错误", "err='" + empty.error + "'");
        ck(calls == 0, "空 title 0 次网络/LLM 调用（transport 计数=0）",
           "calls=" + std::to_string(calls));
    }

    std::printf("== retrieval_v6 %s ==\n", g_fail ? "RED/FAIL" : "GREEN/PASS");
    return g_fail ? 1 : 0;
}
