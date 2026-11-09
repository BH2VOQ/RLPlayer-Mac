// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_knowledge_v6.cpp — 1.1.5-beta2 #21c(knowledge)：缓存代际 v6 + 语言分键
//
// 判据（PLAN §1.4 / §3）：
//   1. 旧 knowledge.json 不读、不写、不删：预置一份带独有材料的旧文件，
//      knowledge_get 不得返回它的内容，且调用后文件字节与 mtime 都不变。
//   2. v<6（或没有 v）的新文件：能解析读出，但 knowledge_peek_cache fresh=false /
//      stale=true / cache_ver<6；离线回退时 KnowledgeResult.stale=true。
//   3. knowledge-zh.json / knowledge-en.json 分语言互不串（含 lang token 转义）。
//   4. round-trip v6 写出后 peek fresh=true、cache_ver=6。
// 全程离线：KnowledgeOpts.include_wikipedia/include_moegirl=false，不起线程、不联网。
#include "meta/knowledge.h"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace fsx = std::filesystem;
using namespace rta::meta;

static int g_fail = 0;
static void ck(bool ok, const std::string& what, const std::string& extra = std::string()) {
    std::printf("  [%s] %s%s%s\n", ok ? "PASS" : "FAIL", what.c_str(),
                extra.empty() ? "" : " — ", extra.c_str());
    if (!ok) ++g_fail;
}

static std::string read_file(const fsx::path& p) {
    std::ifstream f(p, std::ios::binary);
    return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}
static void write_file(const fsx::path& p, const std::string& s) {
    std::error_code ec;
    fsx::create_directories(p.parent_path(), ec);
    std::ofstream f(p, std::ios::binary | std::ios::trunc);
    f.write(s.data(), (std::streamsize)s.size());
}

static KnowledgeMaterial mk_material(const std::string& tag, const std::string& lang) {
    KnowledgeMaterial m;
    m.source = "wikipedia-" + lang;
    m.kind = "biography";
    m.subject = "TestSubject";
    m.title = tag;
    m.text = "正文-" + tag;
    m.url = "https://example.invalid/" + tag;
    m.lang = lang;
    const long long now = (long long)std::time(nullptr);
    m.fetched_at = now - 10;
    m.expires_at = now + 30 * 86400LL;   // 明确未过期，确保 fresh 判据只受代际影响
    m.authority = 4;
    return m;
}

// 手写一份「无 v 字段」的旧代际缓存（等价于 1.1.4 的 knowledge_to_json 输出）。
static std::string legacy_json(const std::string& eid, const KnowledgeMaterial& m) {
    std::ostringstream o;
    o << "{\n"
      << "  \"entity_id\": \"" << meta_jesc(eid) << "\",\n"
      << "  \"subject\": \"" << meta_jesc(m.subject) << "\",\n"
      << "  \"updated_at\": 1000,\n"
      << "  \"materials\": [\n"
      << "    { \"source\": \"" << meta_jesc(m.source) << "\", \"kind\": \"" << meta_jesc(m.kind)
      << "\", \"subject\": \"" << meta_jesc(m.subject) << "\", \"title\": \"" << meta_jesc(m.title)
      << "\", \"text\": \"" << meta_jesc(m.text) << "\", \"url\": \"" << meta_jesc(m.url)
      << "\", \"lang\": \"" << meta_jesc(m.lang) << "\", \"fetched_at\": " << m.fetched_at
      << ", \"expires_at\": " << m.expires_at << ", \"authority\": " << m.authority << " }\n"
      << "  ]\n}\n";
    return o.str();
}

// 手写指定 v 的缓存（用于 v5 边界）。
static std::string v_json(const std::string& eid, const KnowledgeMaterial& m, int ver) {
    std::string s = legacy_json(eid, m);
    const size_t pos = s.find('{');
    return s.substr(0, pos + 1) + "\n  \"v\": " + std::to_string(ver) + "," + s.substr(pos + 1);
}

static KnowledgeOpts offline_opts(const std::string& base, const std::string& lang) {
    KnowledgeOpts o;
    o.metabase = base;
    o.lang = lang;
    o.include_wikipedia = false;
    o.include_moegirl = false;
    return o;
}

int main() {
    std::printf("== test_knowledge_v6: 缓存代际 v6 / 语言分键 / 旧文件不碰 ==\n");
    const fsx::path base = fsx::temp_directory_path() / "rta_beta2_knowledge_v6";
    std::error_code ec;
    fsx::remove_all(base, ec);
    fsx::create_directories(base, ec);
    const std::string baseDir = meta_string_of(base);
    const std::string eid = "eid_beta2_know_v6";

    // ---- 1) lang token 纯函数 ----
    std::printf("-- 1. knowledge_lang_token / 新路径 --\n");
    ck(knowledge_lang_token("") == "zh", "空 lang = zh");
    ck(knowledge_lang_token("zh") == "zh", "zh 原样");
    ck(knowledge_lang_token("en-us") == "en-us", "小写字母/数字/'-' 原样保留");
    ck(knowledge_lang_token("zh_hans") == "zh_hans", "'_' 原样保留");
    ck(knowledge_lang_token("ZH") == "%5A%48" && knowledge_lang_token("en-US") == "en-%55%53",
       "大写字母属于『其余』→ %XX（规则只保留小写字母数字 _ -）",
       knowledge_lang_token("ZH") + " / " + knowledge_lang_token("en-US"));
    ck(knowledge_lang_token("a/b") == "a%2Fb", "'/' 编码为 %2F");
    ck(knowledge_lang_token("a.b") == "a%2Eb", "'.' 也编码（规则只允许字母数字 _ -）");
    ck(knowledge_lang_token("zh") != knowledge_lang_token("en"), "zh/en token 不同");
    const fsx::path p2 = knowledge_cache_path(baseDir, eid);
    const fsx::path p3 = knowledge_cache_path(baseDir, eid, "zh");
    ck(p2 == p3, "旧 2 参 path 委托给 3 参 zh（损坏容错判据仍打在真实缓存文件上）");
    ck(p2.filename().string() == "knowledge-zh.json", "默认路径是 knowledge-zh.json");
    ck(knowledge_cache_path(baseDir, eid, "en").filename().string() == "knowledge-en.json",
       "en 路径是 knowledge-en.json");
    ck(knowledge_cache_path(baseDir, eid, "a/b").filename().string() == "knowledge-a%2Fb.json",
       "含 '/' 的 lang 不会穿越目录");
    ck(kKnowledgeCacheVer == 6, "kKnowledgeCacheVer == 6");

    // ---- 2) 旧 knowledge.json 不读不写不删 ----
    std::printf("-- 2. 旧 knowledge.json 零读零写零删 --\n");
    const fsx::path legacyPath = meta_path_of(baseDir) / "entities" / eid / "knowledge.json";
    const KnowledgeMaterial oldMat = mk_material("OLD-LEGACY-FILE", "zh");
    const std::string legacyBytes = legacy_json(eid, oldMat);
    write_file(legacyPath, legacyBytes);
    ck(fsx::exists(legacyPath, ec), "旧 knowledge.json 已预置");
    const auto legacyMtimeBefore = fsx::last_write_time(legacyPath, ec);
    const KnowledgeResult krLegacy = knowledge_get(eid, "TestSubject", offline_opts(baseDir, "zh"));
    ck(krLegacy.materials.empty(), "旧文件的内容不被 knowledge_get 返回");
    ck(krLegacy.cache_ver == 0 && !krLegacy.stale, "未读到任何 v6 缓存（cache_ver=0, stale=false）");
    ck(read_file(legacyPath) == legacyBytes, "旧文件字节未被改写",
       "len=" + std::to_string(read_file(legacyPath).size()));
    ck(fsx::last_write_time(legacyPath, ec) == legacyMtimeBefore, "旧文件 mtime 未变（零写）");
    ck(fsx::exists(legacyPath, ec), "旧文件仍然存在（零删）");
    // 显式 refresh 也不能把旧文件写回来
    KnowledgeOpts ro = offline_opts(baseDir, "zh");
    ro.refresh = true;
    (void)knowledge_get(eid, "TestSubject", ro);
    ck(read_file(legacyPath) == legacyBytes && fsx::exists(legacyPath, ec),
       "refresh 路径同样不写/不删旧文件");

    // ---- 3) v<6 新文件：可读但 stale、不算 fresh ----
    std::printf("-- 3. v<6 新文件：解析成功但不算 fresh，离线回退标 stale --\n");
    const std::string eidV5 = "eid_beta2_know_v5";
    const KnowledgeMaterial v5Mat = mk_material("OLD-GEN-V5", "zh");
    const fsx::path v5Path = knowledge_cache_path(baseDir, eidV5, "zh");
    write_file(v5Path, v_json(eidV5, v5Mat, 5));
    std::vector<KnowledgeMaterial> out5;
    std::string err5, id5, sub5;
    int ver5 = 99;
    const bool parsed5 = knowledge_from_json(read_file(v5Path), out5, id5, sub5,
                                            &err5, &ver5);
    ck(parsed5, "v5 解析本身仍返回 true（旧缓存能读出来）", err5);
    ck(ver5 == 5, "cache_ver_out 回传 5");
    ck(out5.size() == 1 && out5[0].title == "OLD-GEN-V5", "v5 材料内容完整读出");

    bool fresh5 = true, stale5 = false;
    int peekVer5 = -1;
    std::vector<KnowledgeMaterial> peek5;
    const bool peeked5 = knowledge_peek_cache(baseDir, eidV5, "zh", peek5,
                                              fresh5, stale5, &peekVer5, &err5);
    ck(peeked5, "peek 返回 true（文件存在且可解析）");
    ck(!fresh5, "v5 不算 fresh");
    ck(stale5, "v5 标 stale");
    ck(peekVer5 == 5, "peek cache_ver_out=5");
    ck(peek5.size() == 1 && peek5[0].title == "OLD-GEN-V5", "peek 仍把内容读出供离线回退");
    ck(fsx::exists(v5Path, ec), "peek 不删旧代际文件");

    const KnowledgeResult kr5 = knowledge_get(eidV5, "TestSubject", offline_opts(baseDir, "zh"));
    ck(!kr5.materials.empty() && kr5.materials[0].title == "OLD-GEN-V5",
       "离线时 v5 内容可作为 stale 回退读出");
    ck(kr5.from_cache && kr5.offline, "v5 走离线回退（from_cache/offline=true）");
    ck(kr5.stale, "KnowledgeResult.stale=true（仅离线回退旧代际时）");
    ck(kr5.cache_ver == 5, "KnowledgeResult.cache_ver=5");

    // 无 "v" 字段（1.1.4 原样文件）同样不算 fresh
    const std::string eidNoV = "eid_beta2_know_nov";
    write_file(knowledge_cache_path(baseDir, eidNoV, "zh"), legacy_json(eidNoV, v5Mat));
    bool freshN = true, staleN = false;
    int verN = -1;
    std::vector<KnowledgeMaterial> peekN;
    (void)knowledge_peek_cache(baseDir, eidNoV, "zh", peekN, freshN, staleN, &verN, &err5);
    ck(!freshN && staleN && verN == 0, "无 v 字段 → 代际 0、stale、不 fresh");
    const KnowledgeResult krN = knowledge_get(eidNoV, "TestSubject", offline_opts(baseDir, "zh"));
    ck(krN.stale && krN.offline && krN.cache_ver == 0, "无 v 字段离线回退也标 stale");

    // ---- 4) zh / en 分语言互不串 ----
    std::printf("-- 4. knowledge-zh.json / knowledge-en.json 分语言互不串 --\n");
    const std::string eidLang = "eid_beta2_know_lang";
    const KnowledgeMaterial zhMat = mk_material("ZH-ONLY", "zh");
    const KnowledgeMaterial enMat = mk_material("EN-ONLY", "en");
    ck(knowledge_save_cache(baseDir, eidLang, "TestSubject", { zhMat }, "zh"), "写 zh 缓存");
    ck(fsx::exists(knowledge_cache_path(baseDir, eidLang, "zh"), ec), "knowledge-zh.json 存在");
    ck(!fsx::exists(knowledge_cache_path(baseDir, eidLang, "en"), ec),
       "写 zh 时没有生成 knowledge-en.json");
    std::vector<KnowledgeMaterial> enBefore;
    std::string enErr;
    ck(!knowledge_load_cache(baseDir, eidLang, enBefore, "en", &enErr),
       "en 语言读不到 zh 的材料（互不串）", enErr);
    bool freshZ = false, staleZ = true;
    int verZ = -1;
    std::vector<KnowledgeMaterial> peekZ;
    (void)knowledge_peek_cache(baseDir, eidLang, "en", peekZ, freshZ, staleZ, &verZ, &enErr);
    ck(!freshZ && peekZ.empty(), "peek(en) 在只有 zh 缓存时不 fresh、内容为空");
    ck(knowledge_save_cache(baseDir, eidLang, "TestSubject", { enMat }, "en"), "写 en 缓存");
    std::vector<KnowledgeMaterial> zhOut, enOut;
    ck(knowledge_load_cache(baseDir, eidLang, zhOut, "zh", &enErr), "zh 仍可读");
    ck(knowledge_load_cache(baseDir, eidLang, enOut, "en", &enErr), "en 可读");
    ck(zhOut.size() == 1 && zhOut[0].title == "ZH-ONLY", "zh 内容未被 en 覆盖");
    ck(enOut.size() == 1 && enOut[0].title == "EN-ONLY", "en 内容独立");
    const KnowledgeResult krZh = knowledge_get(eidLang, "TestSubject", offline_opts(baseDir, "zh"));
    const KnowledgeResult krEn = knowledge_get(eidLang, "TestSubject", offline_opts(baseDir, "en"));
    ck(krZh.from_cache && !krZh.stale && krZh.materials.size() == 1 &&
       krZh.materials[0].title == "ZH-ONLY", "knowledge_get(lang=zh) 只命中 zh");
    ck(krEn.from_cache && !krEn.stale && krEn.materials.size() == 1 &&
       krEn.materials[0].title == "EN-ONLY", "knowledge_get(lang=en) 只命中 en");
    ck(krZh.cache_ver == 6 && krEn.cache_ver == 6, "两个语言的 v6 代际都是 6");

    // ---- 5) round-trip v6：写出 → peek fresh ----
    std::printf("-- 5. round-trip v6 写出 → peek fresh=true --\n");
    const std::string json6 = knowledge_to_json({ zhMat }, eidLang, "TestSubject");
    ck(json6.find("\"v\": 6") != std::string::npos, "knowledge_to_json 写 \"v\": 6");
    const std::string eidFresh = "eid_beta2_know_fresh";
    ck(knowledge_save_cache(baseDir, eidFresh, "TestSubject", { zhMat }, "ja"), "写 ja v6 缓存");
    ck(fsx::exists(knowledge_cache_path(baseDir, eidFresh, "ja"), ec),
       "knowledge-ja.json 存在");
    bool fresh6 = false, stale6 = true;
    int ver6 = -1;
    std::vector<KnowledgeMaterial> peek6;
    std::string err6;
    const auto t0 = std::chrono::steady_clock::now();
    const bool peeked6 = knowledge_peek_cache(baseDir, eidFresh, "ja", peek6,
                                              fresh6, stale6, &ver6, &err6);
    const long long peekMs = (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - t0).count();
    ck(peeked6, "peek 命中 v6 缓存", err6);
    ck(fresh6, "fresh_out=true");
    ck(!stale6, "stale_out=false");
    ck(ver6 == 6, "cache_ver_out=6");
    ck(peek6.size() == 1 && peek6[0].title == "ZH-ONLY", "peek 读出 v6 材料");
    ck(peekMs < 10, "peek 纯磁盘读 <10ms（实测 " + std::to_string(peekMs) + "ms）");
    const KnowledgeResult kr6 = knowledge_get(eidFresh, "TestSubject", offline_opts(baseDir, "ja"));
    ck(kr6.from_cache && !kr6.offline && !kr6.stale && kr6.cache_ver == 6,
       "v6 fresh 命中不是离线回退、不标 stale");
    ck(kr6.materials.size() == 1 && kr6.materials[0].title == "ZH-ONLY", "v6 内容一致");

    fsx::remove_all(base, ec);
    std::printf("\n%s（失败 %d 项）\n", g_fail ? "FAILED" : "ALL PASS", g_fail);
    return g_fail ? 1 : 0;
}
