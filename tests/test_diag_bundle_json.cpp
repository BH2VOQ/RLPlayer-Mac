// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_diag_bundle_json.cpp — 诊断包单文件 JSON 表示（src/diag/bundle.h 的 bundle_json）
//
// 判据设计（铁律 3：测试通过 ≠ 测对了东西）：
//   ① **不靠实现自证**：UTF-8 合法性用本文件自己写的一份校验器判定，
//      不复用 bundle.h 里的 detail::utf8_valid —— 否则"实现和测试一起错"永远测不出来。
//   ② **绕一圈比对**：所有"内容对不对"的断言都走「输出 → rta::net::json_parse → 与原文比字节」，
//      不接受"看输出里有没有这段字符"这种近似判据（转义/乱码都能骗过眼测）。
//   ③ **坏输入优先**：非法 UTF-8、非法 manifest 这两条对抗用例是核心 ——
//      它们的意义是「宁可拒传，也绝不产出坏 JSON」，后端页面按 UTF-8 解码。
//
// 不联网、不读写文件（append-only 的纯函数）、不开设备、不播放、不杀进程。
#include "diag/bundle.h"

#include <cstdio>
#include <cstring>
#include <set>
#include <string>
#include <vector>

using namespace rta::diag;

static int g_fails = 0;
static int g_pass = 0;

static void ck(bool cond, const std::string& what, const std::string& extra = std::string()) {
    if (cond) {
        ++g_pass;
        std::printf("  [PASS] %s\n", what.c_str());
    } else {
        ++g_fails;
        std::printf("  [FAIL] %s\n", what.c_str());
        if (!extra.empty()) std::printf("         %s\n", extra.c_str());
    }
}

static void section(const char* name) { std::printf("\n=== %s ===\n", name); }

// ---------------- 独立实现的一份严格 UTF-8 校验（刻意不复用 bundle.h）----------------
// 规则：拒绝空续字节、过长编码、UTF-16 代理区、> U+10FFFF。
static bool utf8_valid(const std::string& s) {
    std::size_t i = 0;
    while (i < s.size()) {
        const unsigned char c = (unsigned char)s[i];
        if (c < 0x80) { ++i; continue; }
        std::size_t need = 0;
        unsigned cp = 0;
        if (c >= 0xC2 && c <= 0xDF) { need = 1; cp = c & 0x1Fu; }
        else if (c >= 0xE0 && c <= 0xEF) { need = 2; cp = c & 0x0Fu; }
        else if (c >= 0xF0 && c <= 0xF4) { need = 3; cp = c & 0x07u; }
        else return false;
        if (i + need >= s.size()) return false;
        for (std::size_t k = 1; k <= need; ++k) {
            const unsigned char cc = (unsigned char)s[i + k];
            if ((cc & 0xC0u) != 0x80u) return false;
            cp = (cp << 6) | (cc & 0x3Fu);
        }
        if ((need == 2 && cp < 0x800u) || (need == 3 && cp < 0x10000u)) return false;
        if (cp >= 0xD800u && cp <= 0xDFFFu) return false;
        if (cp > 0x10FFFFu) return false;
        i += need + 1;
    }
    return true;
}

// 造一个"正常"小包，条目内容都由调用方给（便于塞坏字节）。
struct Case {
    std::string name;
    std::string data;
    EntryKind   kind = EntryKind::Text;
    int         priority = 50;
};

static AssembleResult build(const std::vector<Case>& cases,
                            const std::string& report = "报告正文\n") {
    BundleSpec spec;
    spec.case_id = "RLP-20261111-120000-abcdef";   // 固定，避免"比对时才发现两边不同"
    spec.created_utc = "2026-11-11T04:00:00Z";
    spec.app_version = "1.4.0";
    spec.app_build = "Nov 11 2026";
    spec.generator_version = "1.4.0";
    spec.platform.os = "macOS 27.0.1";
    spec.platform.arch = "arm64";
    spec.platform.cpu = "Apple M4";
    spec.cs.origin = "test";

    std::vector<BundleEntry> items;
    items.push_back(make_entry(kDiagName, "{\"os\":\"macOS 27.0.1\"}", EntryKind::Json, 100));
    items.push_back(make_entry(kEventsName, "{\"seq\":1,\"evt\":\"play.start\"}\n", EntryKind::Jsonl, 80));
    items.push_back(make_entry(kUiEventsName, "{\"seq\":1,\"evt\":\"ui.click\"}\n", EntryKind::Jsonl, 60));
    for (const auto& c : cases) items.push_back(make_entry(c.name, c.data, c.kind, c.priority));
    return assemble(spec, std::move(items), report);
}

// 只造 manifest.json + checksums.txt 的"空 payload"包（required 也清空）。
static AssembleResult build_empty() {
    BundleSpec spec;
    spec.case_id = "RLP-20261111-120000-000000";
    spec.created_utc = "2026-11-11T04:00:00Z";
    spec.required.clear();
    std::vector<BundleEntry> items;
    return assemble(spec, std::move(items), std::string());
}

// ============================================================================
int main() {
    setvbuf(stdout, nullptr, _IONBF, 0);

    // ------------------------------------------------------------------
    section("1. 输出是可解析对象：schema / format / case_id / created_utc");
    AssembleResult r = build({Case{"note.txt", "hello\n", EntryKind::Text, 40}});
    std::string out = bundle_json(r);
    {
        ck(r.ok, "底层 assemble 成功", r.err);
        ck(!out.empty(), "bundle_json 非空");
        const rta::net::Json j = rta::net::json_parse(out);
        ck(j.type == rta::net::Json::Obj, "输出被 json_parse 解析成对象");
        ck(j["schema"].s() == "rlplayer.diag.bundle/2", "schema", j["schema"].s());
        ck(j["format"].s() == "json", "format=json", j["format"].s());
        ck(j["case_id"].s() == r.case_id, "case_id 与 r.case_id 一致", j["case_id"].s());
        ck(j["created_utc"].s() == r.created_utc, "created_utc 与 r.created_utc 一致",
           j["created_utc"].s());
        ck(j["manifest"].type == rta::net::Json::Obj,
           "manifest 是**对象**，不是被转义过的字符串");
        ck(j["files"].type == rta::net::Json::Obj, "files 是对象");
        ck(utf8_valid(out), "整个输出是合法 UTF-8");
    }

    // ------------------------------------------------------------------
    section("2. manifest 字段：与 r.manifest_json 解析后逐字段相等");
    {
        const rta::net::Json got = rta::net::json_parse(out)["manifest"];
        const rta::net::Json want = rta::net::json_parse(r.manifest_json);
        ck(got["schema"].s() == want["schema"].s(), "manifest.schema 相同", got["schema"].s());
        ck(got["case_id"].s() == want["case_id"].s(), "manifest.case_id 相同", got["case_id"].s());
        ck(got["created_utc"].s() == want["created_utc"].s(), "manifest.created_utc 相同");
        ck((long long)got["schema_version"].n() == (long long)want["schema_version"].n(),
           "manifest.schema_version 相同");
        ck(got["app"]["version"].s() == want["app"]["version"].s(), "manifest.app.version 相同",
           got["app"]["version"].s());
        ck(got["entries"].size() == want["entries"].size(), "manifest.entries 条数相同",
           std::to_string(got["entries"].size()) + " vs " + std::to_string(want["entries"].size()));

        bool names_ok = true, sha_ok = true, bytes_ok = true, kind_ok = true;
        for (std::size_t i = 0; i < want["entries"].size() && i < got["entries"].size(); ++i) {
            const rta::net::Json& a = want["entries"].at(i);
            const rta::net::Json& b = got["entries"].at(i);
            if (a["name"].s() != b["name"].s()) names_ok = false;
            if (a["sha256"].s() != b["sha256"].s()) sha_ok = false;
            if ((long long)a["bytes"].n() != (long long)b["bytes"].n()) bytes_ok = false;
            if (a["kind"].s() != b["kind"].s()) kind_ok = false;
        }
        ck(names_ok, "每条 entry 的 name 相同");
        ck(sha_ok, "每条 entry 的 sha256 相同");
        ck(bytes_ok, "每条 entry 的 bytes 相同");
        ck(kind_ok, "每条 entry 的 kind 相同");
        ck(got["truncation"]["applied"].b == want["truncation"]["applied"].b,
           "manifest.truncation.applied 相同");
    }

    // ------------------------------------------------------------------
    section("3. checksums 字段：与 r.checksums_txt 逐字节相等");
    {
        const std::string got = rta::net::json_parse(out)["checksums"].s();
        ck(got == r.checksums_txt, "checksums 逐字节相等",
           "got " + std::to_string(got.size()) + " B, want " +
           std::to_string(r.checksums_txt.size()) + " B");
        ck(!got.empty() && got.find("  manifest.json\n") != std::string::npos,
           "checksums 里仍覆盖 manifest.json 本身");
    }

    // ------------------------------------------------------------------
    section("4. UTF-8 安全：合法原样往返，非法替换为 U+FFFD 并进 sanitized");
    {
        const std::string good_text = "中文🙂";                       // F0 9F 99 82
        std::string bad_text = "ok";
        bad_text.push_back((char)0xFF);                                // 非法起始字节
        bad_text += "ok";
        AssembleResult rb = build({Case{"unicode.txt", good_text, EntryKind::Text, 40},
                                   Case{"bad.bin", bad_text, EntryKind::Binary, 30}});
        const std::string ob = bundle_json(rb);
        ck(rb.ok, "含坏字节的包也能组装（本函数负责清洗，不是 assemble）", rb.err);
        ck(utf8_valid(ob), "包含坏字节的输出**仍然**是合法 UTF-8");
        const rta::net::Json jb = rta::net::json_parse(ob);
        ck(jb.type == rta::net::Json::Obj, "含坏字节的输出仍是合法 JSON 对象");

        ck(jb["files"]["unicode.txt"].s() == good_text, "合法 UTF-8（中文/emoji）原样往返",
           jb["files"]["unicode.txt"].s());
        const std::string want_bad = std::string("ok") + "\xEF\xBF\xBD" + "ok";
        ck(jb["files"]["bad.bin"].s() == want_bad, "非法字节被替换成 U+FFFD（EF BF BD）",
           jb["files"]["bad.bin"].s());

        bool has_bad = false, has_good = false;
        for (std::size_t i = 0; i < jb["sanitized"].size(); ++i) {
            const std::string n = jb["sanitized"].at(i).s();
            if (n == "bad.bin") has_bad = true;
            if (n == "unicode.txt") has_good = true;
        }
        ck(has_bad, "被清洗的条目进了 sanitized");
        ck(!has_good, "合法条目**没有**进 sanitized",
           "sanitized 条数 " + std::to_string(jb["sanitized"].size()));

        // 边界：条目**名**带非法字节 ⇒ 拒传（返回空串），不尝试"洗名字"。
        // 为什么不能洗：这个名字同时出现在 manifest.entries 与 checksums.txt 里，而规格要求
        // 这两处原文嵌入/逐字节相等 —— 洗了名字，checksums 就不再等于 r.checksums_txt；
        // 不洗，输出就不是合法 UTF-8。两条判据不可能同时满足，只能拒传（详见 bundle.h 注释）。
        // 也顺带证明"清洗"不会误伤结构：坏名字的包宁可没有 JSON，也不产一个自相矛盾的包。
        std::string bad_name = "weird";
        bad_name.push_back((char)0xFF);
        bad_name += ".txt";
        AssembleResult rn = build({Case{bad_name, "x", EntryKind::Text, 40}});
        ck(rn.ok, "名字含非法字节的包能被 assemble 组装（拒传是 bundle_json 的判断）", rn.err);
        ck(bundle_json(rn).empty(), "名字含非法字节 ⇒ 空串（不产出与 checksums 自相矛盾的 JSON）");
        // 反向对照：内容坏但名字合法 ⇒ 不一定拒传（清洗 + sanitized），见本节上半个用例。
        ck(!bundle_json(rb).empty(), "对照：内容含坏字节仍产出（清洗而非拒传）");
    }

    // ------------------------------------------------------------------
    section("5. 转义：引号/反斜杠/换行/制表/0x01/中文/emoji 往返逐字节相等");
    {
        std::string esc = "a\"b\\c\nd\te";
        esc.push_back((char)0x01);
        esc += "中文 emoji=";
        esc += "\xF0\x9F\x99\x82";
        esc += "\x7F";                                    // DEL：合法 JSON，不需转义
        AssembleResult re = build({Case{"esc.txt", esc, EntryKind::Text, 40}});
        const std::string oe = bundle_json(re);
        const rta::net::Json je = rta::net::json_parse(oe);
        const std::string back = je["files"]["esc.txt"].s();
        ck(back == esc, "转义后解析回来与原内容逐字节相等",
           "size " + std::to_string(back.size()) + " vs " + std::to_string(esc.size()));
        ck(oe.find("\\u0001") != std::string::npos, "0x01 以 \\u0001 形式出现（不是裸控制字节）");
        ck(oe.find("\\n") != std::string::npos, "换行被转义成 \\n");
        ck(utf8_valid(oe), "含转义的输出仍是合法 UTF-8");
    }

    // ------------------------------------------------------------------
    section("6. files 键集合与取值：条目 + manifest.json + checksums.txt");
    {
        const rta::net::Json j = rta::net::json_parse(out);
        std::set<std::string> got_keys;
        for (const auto& kv : j["files"].obj) got_keys.insert(kv.first);

        std::set<std::string> want_keys;
        for (const auto& m : r.entries) want_keys.insert(m.rec.name);
        want_keys.insert(kManifestName);
        want_keys.insert(kChecksumsName);
        ck(got_keys == want_keys, "键集合 == 条目名集合 + {manifest.json, checksums.txt}",
           "got " + std::to_string(got_keys.size()) + " keys, want " +
           std::to_string(want_keys.size()) + " keys");

        bool values_ok = true;
        std::string first_bad;
        for (const auto& m : r.entries) {
            if (j["files"][m.rec.name].s() != m.data) {
                values_ok = false;
                if (first_bad.empty()) first_bad = m.rec.name;
            }
        }
        ck(values_ok, "每个键的值与对应条目原文逐字节相等", first_bad.empty() ? "" : first_bad);
        ck(j["files"][kManifestName].s() == r.manifest_json, "manifest.json 的值 == r.manifest_json");
        ck(j["files"][kChecksumsName].s() == r.checksums_txt,
           "checksums.txt 的值 == r.checksums_txt");
        ck(j["files"]["report.txt"].s() == r.report_txt, "report.txt 也在 files 里且内容一致");
    }

    // ------------------------------------------------------------------
    section("7. 空 payload（只有 manifest/checksums）不崩、输出合法 JSON");
    {
        AssembleResult r0 = build_empty();
        ck(r0.ok, "空包的底层组装成功", r0.err);
        ck(r0.entries.empty(), "确实没有 payload 条目",
           std::to_string(r0.entries.size()) + " 条");
        const std::string o0 = bundle_json(r0);
        ck(!o0.empty(), "空包也有 JSON 输出（不是拒传）");
        const rta::net::Json j0 = rta::net::json_parse(o0);
        ck(j0.type == rta::net::Json::Obj, "空包输出是合法 JSON 对象");
        ck(j0["files"].type == rta::net::Json::Obj && j0["files"].obj.size() == 2,
           "空包 files 只有 manifest.json + checksums.txt",
           std::to_string(j0["files"].obj.size()));
        ck(j0["sanitized"].type == rta::net::Json::Arr && j0["sanitized"].size() == 0,
           "空包 sanitized 是空数组");
    }

    // ------------------------------------------------------------------
    section("8. 大内容（≥2 MB 日志）只转义、不截断、不丢内容");
    {
        std::string big;
        const std::string line = "{\"seq\":123456,\"evt\":\"tick\",\"note\":\"中文日志一行\"}\n";
        while (big.size() < 2u * 1024u * 1024u) big += line;
        AssembleResult rg = build({Case{"big.log", big, EntryKind::Log, 70}});
        ck(rg.ok, "大内容包组装成功", rg.err);
        // 大条目没被预算裁掉（12 MB 预算）
        std::string kept;
        for (const auto& m : rg.entries) if (m.rec.name == "big.log") kept = m.data;
        ck(kept == big, "assemble 未裁剪 big.log（否则下面的比对没有意义）",
           std::to_string(kept.size()) + " vs " + std::to_string(big.size()));

        const std::string og = bundle_json(rg);
        const rta::net::Json jg = rta::net::json_parse(og);
        const std::string backg = jg["files"]["big.log"].s();
        ck(backg.size() == big.size(), "解析后长度一致（不截断、不丢内容）",
           std::to_string(backg.size()) + " vs " + std::to_string(big.size()));
        ck(backg == big, "解析后逐字节一致");
        ck(utf8_valid(og), "2 MB 输出仍是合法 UTF-8");
    }

    // ------------------------------------------------------------------
    section("9. manifest 不是合法 JSON ⇒ 返回空串（宁可拒传，不产坏 JSON）");
    {
        AssembleResult bad;
        bad.ok = false;
        bad.case_id = "RLP-20261111-120000-badbad";
        bad.created_utc = "2026-11-11T04:00:00Z";
        bad.manifest_json = "{\"schema\":\"rlplayer.diag.bundle/2\",\"case_id\":\"x\",";  // 截断
        ck(bundle_json(bad).empty(), "截断的对象 ⇒ 空串（rta::net::json_parse 本身很宽容，必须由本函数严格校验）");

        AssembleResult bad2 = bad;
        bad2.manifest_json = "not json at all";
        ck(bundle_json(bad2).empty(), "纯文本 ⇒ 空串");

        AssembleResult bad3 = bad;
        bad3.manifest_json = std::string("[1,2,3]");
        ck(bundle_json(bad3).empty(), "顶层是数组（不是对象）⇒ 空串");

        AssembleResult bad4 = bad;
        bad4.manifest_json = std::string();
        ck(bundle_json(bad4).empty(), "manifest 为空 ⇒ 空串");

        AssembleResult bad5 = bad;
        bad5.manifest_json = "{}";
        ck(!bundle_json(bad5).empty(), "{} 是合法对象 ⇒ 仍然产出（结构合法性由 verify 负责）");

        AssembleResult bad6 = bad;
        bad6.manifest_json = std::string("{\"a\":\"\xFF\"}");   // 结构合法但含非法 UTF-8
        ck(bundle_json(bad6).empty(), "manifest 含非法 UTF-8 ⇒ 空串（输出必须可被 UTF-8 解码）");
    }

    // ------------------------------------------------------------------
    section("10. 纯函数：同样输入两次调用逐字节相同、不改输入");
    {
        const std::string a = bundle_json(r);
        const std::string b = bundle_json(r);
        ck(a == b, "同一 AssembleResult 两次调用结果相同");

        AssembleResult r1 = build({Case{"note.txt", "hello\n", EntryKind::Text, 40}});
        AssembleResult r2 = build({Case{"note.txt", "hello\n", EntryKind::Text, 40}});
        ck(bundle_json(r1) == bundle_json(r2),
           "两个独立组装（固定 case_id/created_utc）结果相同 ⇒ 不依赖时间/随机/全局状态");
        ck(r1.manifest_json == r.manifest_json, "调用前后 r.manifest_json 未被改动");
    }

    std::printf("\n----------------------------------------\n");
    std::printf("PASS %d / FAIL %d\n", g_pass, g_fails);
    return g_fails == 0 ? 0 : 1;
}
