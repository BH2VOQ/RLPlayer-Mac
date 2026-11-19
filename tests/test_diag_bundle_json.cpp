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
// 不联网、不开设备、不播放、不杀进程。
#define RLPLAYER_EMBEDDED_LIBRARY
#include "../tools/rtaweb.cpp"

namespace rta::platform {
bool make_jpeg_thumb(const unsigned char*, size_t, int, int, std::vector<unsigned char>&) { return false; }
}
extern "C" {
int rl_loopback_supported(void) { return 0; }
int rl_loopback_create(const char*, uint32_t*, uint32_t*, char*, size_t) { return -1; }
void rl_loopback_destroy(uint32_t, uint32_t) {}
}

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <set>
#include <string>
#include <unistd.h>
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

    // ------------------------------------------------------------------
    section("11. diag_snapshot_json 排障快照字段、脱敏与预算验证");
    {
        const char* prevHome = std::getenv("HOME");
        const char* prevState = std::getenv("RLPLAYER_STATE_DIR");
        const char* prevLib = std::getenv("RLPLAYER_LIBRARY_DIR");
        const bool hadHome = (prevHome != nullptr);
        const bool hadState = (prevState != nullptr);
        const bool hadLib = (prevLib != nullptr);
        const std::string savedHome = prevHome ? prevHome : "";
        const std::string savedState = prevState ? prevState : "";
        const std::string savedLib = prevLib ? prevLib : "";
        const std::string savedDiagDir = g_diagStartup.dir;

        const char* tmpBase = std::getenv("TMPDIR");
        std::string tmpRoot = (tmpBase && *tmpBase) ? tmpBase : "/tmp";
        while (!tmpRoot.empty() && tmpRoot.back() == '/') tmpRoot.pop_back();
        std::string tmpl = tmpRoot + "/rlp-diagsnap-test-XXXXXX";
        std::vector<char> tbuf(tmpl.begin(), tmpl.end());
        tbuf.push_back('\0');
        const bool mkOk = (::mkdtemp(tbuf.data()) != nullptr);
        ck(mkOk, "创建隔离临时根目录");
        if (mkOk) {
            const std::string root(tbuf.data());
            const std::string secretUser = "diag_secret_alice";
            const std::string fakeHome = root + "/Users/" + secretUser;
            const std::string fakeState = fakeHome + "/custom_state";
            const std::string fakeLib = fakeHome + "/custom_library";
            const std::string fakeCfg = fakeHome + "/Library/Application Support/RLPlayer";
            std::error_code ec;
            fs::create_directories(fs::path(fakeState), ec);
            fs::create_directories(fs::path(fakeLib), ec);
            fs::create_directories(fs::path(fakeCfg), ec);

            ::setenv("HOME", fakeHome.c_str(), 1);
            ::setenv("RLPLAYER_STATE_DIR", fakeState.c_str(), 1);
            ::setenv("RLPLAYER_LIBRARY_DIR", fakeLib.c_str(), 1);

            const std::string kFakeUpdateTok = "ghp_SuperSecretUpdateToken9876543210";
            const std::string kFakeErrTok = "ghp_SecretInErrorToken1234567890";
            const std::string kFakeQueryTok = "tok_query_leak_888999";
            const std::string kFakeStreamTok = "tok_stream_leak_777666";
            const std::string kFakeIr = "/Users/" + secretUser + "/Rooms/living_room_ir.wav";
            const std::string kFakeEq = "/Users/" + secretUser + "/EQ/hd800s_eq.txt";
            g_diagStartup.dir = fakeState + "/instances/test-sid";

            {
                std::ofstream uf(fakeCfg + "/update.conf", std::ios::binary | std::ios::trunc);
                uf << "token=" << kFakeUpdateTok << "\n"
                   << "channel=cn\n";
            }
            {
                std::ofstream sf(fakeState + "/rlplayer-settings.conf", std::ios::binary | std::ios::trunc);
                sf << "backend=coreaudio-shared\n"
                   << "rate=96000\n"
                   << "bits=24\n"
                   << "filter=poly-sinc-ext2\n"
                   << "shaper=ns5\n"
                   << "metaon=1\n"
                   << "channels=2\n"
                   << "device=77\n"
                   << "buffer=120\n"
                   << "hogexcl=0\n"
                   << "rateFamilyPolicy=strict\n"
                   << "ir=" << kFakeIr << "\n"
                   << "eq=" << kFakeEq << "\n";
            }

            {
                std::lock_guard<std::mutex> lk(g_ps.mtx);
                g_ps.playing.store(true);
                g_ps.paused.store(false);
                g_ps.current = "/Users/" + secretUser + "/Music/Miles Davis/01 So What.flac";
                g_ps.error = "http fail https://api.example.com/v1/x?access_token=" + kFakeQueryTok +
                             " path=/Users/" + secretUser + "/track.flac token=" + kFakeErrTok;
            }
            {
                std::lock_guard<std::mutex> lk(g_q.mtx);
                g_q.items.clear();
                g_q.items.push_back(QItem("/Users/" + secretUser + "/Music/01.flac"));
                g_q.items.push_back(QItem("/Users/" + secretUser + "/Music/02.flac"));
                g_q.items.push_back(QItem("/Users/" + secretUser + "/Music/03.flac"));
            }

            const std::string snapCn = diag_snapshot_json(false);
            const rta::net::Json d = rta::net::json_parse(snapCn);
            ck(utf8_valid(snapCn), "diag_snapshot_json(false) 输出合法 UTF-8");
            ck(d.type == rta::net::Json::Obj && d["ok"].b, "diag_snapshot_json(false) 解析为 ok=true JSON 对象");

            // 打印实际顶层与子对象 keys 供核验
            auto joinKeys = [](const rta::net::Json& obj) {
                std::string s;
                for (const auto& kv : obj.obj) {
                    if (!s.empty()) s += ",";
                    s += kv.first;
                }
                return s;
            };
            std::printf("  [KEYS] top: %s\n", joinKeys(d).c_str());
            if (d.has("app") && d["app"].type == rta::net::Json::Obj)
                std::printf("  [KEYS] app: %s\n", joinKeys(d["app"]).c_str());
            if (d.has("runtime") && d["runtime"].type == rta::net::Json::Obj)
                std::printf("  [KEYS] runtime: %s\n", joinKeys(d["runtime"]).c_str());
            if (d.has("channels") && d["channels"].type == rta::net::Json::Obj)
                std::printf("  [KEYS] channels: %s\n", joinKeys(d["channels"]).c_str());
            if (d.has("playback") && d["playback"].type == rta::net::Json::Obj)
                std::printf("  [KEYS] playback: %s\n", joinKeys(d["playback"]).c_str());
            if (d.has("settings") && d["settings"].type == rta::net::Json::Obj)
                std::printf("  [KEYS] settings: %s\n", joinKeys(d["settings"]).c_str());
            if (d.has("diagnostics") && d["diagnostics"].type == rta::net::Json::Obj)
                std::printf("  [KEYS] diagnostics: %s\n", joinKeys(d["diagnostics"]).c_str());

            // 1) app
            ck(d.has("app") && d["app"].type == rta::net::Json::Obj, "diag.json 含 app 对象");
            const rta::net::Json& app = d["app"];
            ck(app.has("bundleId") && app["bundleId"].type == rta::net::Json::Str, "app.bundleId 存在");
            ck(app.has("path") && app["path"].type == rta::net::Json::Str && !app["path"].s().empty() &&
               app["path"].s().find('/') == std::string::npos && app["path"].s().find('\\') == std::string::npos,
               "app.path 仅留 basename（不含目录分隔符）", app["path"].s());
            ck(app.has("build") && !app["build"].s().empty(), "app.build 非空");
            ck(app.has("version") && app["version"].s() == RLPLAYER_VERSION, "app.version 一致", app["version"].s());

            // 2) runtime
            ck(d.has("runtime") && d["runtime"].type == rta::net::Json::Obj, "diag.json 含 runtime 对象");
            const rta::net::Json& rt = d["runtime"];
            ck(rt.has("stateDir") && rt["stateDir"].s() == "custom_state",
               "runtime.stateDir 只留最后目录名", rt["stateDir"].s());
            ck(rt.has("libraryDir") && rt["libraryDir"].s() == "custom_library",
               "runtime.libraryDir 只留最后目录名", rt["libraryDir"].s());
            ck(rt.has("configDir") && rt["configDir"].s() == "RLPlayer",
               "runtime.configDir 脱敏且不含绝对路径", rt["configDir"].s());
            ck(rt.has("pid") && rt["pid"].n() > 0, "runtime.pid > 0");
            ck(rt.has("port") && rt["port"].type == rta::net::Json::Num, "runtime.port 存在");
            ck(rt.has("lan") && rt["lan"].type == rta::net::Json::Bool, "runtime.lan 存在");

            // 3) channels (cn & global)
            ck(d.has("channels") && d["channels"].type == rta::net::Json::Obj, "diag.json 含 channels 对象");
            const rta::net::Json& ch = d["channels"];
            ck(ch.has("updateChannel") && ch["updateChannel"].s() == "cn",
               "channels.updateChannel=cn", ch["updateChannel"].s());
            ck(ch.has("updateManifestHost") && ch["updateManifestHost"].s() == "rlplayer.rainlain.com",
               "channels.updateManifestHost=rlplayer.rainlain.com (cn)", ch["updateManifestHost"].s());
            ck(ch.has("feedbackEndpointHost") && ch["feedbackEndpointHost"].s() == "rlplayer.rainlain.com",
               "channels.feedbackEndpointHost", ch["feedbackEndpointHost"].s());
            ck(ch.has("feedbackWatchdogHost") && ch["feedbackWatchdogHost"].s() == "rlplayer.rainlain.com",
               "channels.feedbackWatchdogHost", ch["feedbackWatchdogHost"].s());
            ck(!ch.has("token"), "channels 不含 token 键");

            // 4) playback
            ck(d.has("playback") && d["playback"].type == rta::net::Json::Obj, "diag.json 含 playback 对象");
            const rta::net::Json& pb = d["playback"];
            ck(pb.has("currentPath") && pb["currentPath"].s() == "01 So What.flac",
               "playback.currentPath 仅留文件名（不含目录与用户名）", pb["currentPath"].s());
            ck(pb.has("playing") && pb["playing"].b == true, "playback.playing=true");
            ck(pb.has("paused") && pb["paused"].b == false, "playback.paused=false");
            ck(pb.has("queueCount") && (long long)pb["queueCount"].n() == 3, "playback.queueCount=3");
            ck(pb.has("lastError") && !pb["lastError"].s().empty(), "playback.lastError 存在");
            ck(pb["lastError"].s().find(secretUser) == std::string::npos &&
               pb["lastError"].s().find(kFakeErrTok) == std::string::npos &&
               pb["lastError"].s().find(kFakeQueryTok) == std::string::npos,
               "playback.lastError 已脱敏（无用户名/token/query）", pb["lastError"].s());

            // 5) settings
            ck(d.has("settings") && d["settings"].type == rta::net::Json::Obj, "diag.json 含 settings 对象");
            const rta::net::Json& st = d["settings"];
            ck(st["backend"].s() == "coreaudio-shared" && st["rate"].s() == "96000" &&
               st["bits"].s() == "24" && st["filter"].s() == "poly-sinc-ext2" &&
               st["shaper"].s() == "ns5" && st["metaon"].s() == "1",
               "settings 保留原有六键");
            ck(st.has("channels") && st["channels"].s() == "2", "settings.channels=2", st["channels"].s());
            ck(st.has("device") && st["device"].s() == "77", "settings.device=77", st["device"].s());
            ck(st.has("output") && st["output"].s() == "coreaudio-shared", "settings.output", st["output"].s());
            ck(st.has("buffer") && st["buffer"].s() == "120", "settings.buffer=120", st["buffer"].s());
            ck(st.has("hogexcl") && st["hogexcl"].s() == "0", "settings.hogexcl=0", st["hogexcl"].s());
            ck(st.has("rateFamilyPolicy") && st["rateFamilyPolicy"].s() == "strict",
               "settings.rateFamilyPolicy=strict", st["rateFamilyPolicy"].s());
            ck(!st.has("ir") && !st.has("eq"), "settings 不含 ir/eq 键");

            // 6) diagnostics
            ck(d.has("diagnostics") && d["diagnostics"].type == rta::net::Json::Obj, "diag.json 含 diagnostics 对象");
            const rta::net::Json& dg = d["diagnostics"];
            ck(dg.has("schema") && !dg["schema"].s().empty(), "diagnostics.schema 非空", dg["schema"].s());
            ck(dg.has("caseId") && dg["caseId"].s() == d["caseId"].s() && !dg["caseId"].s().empty(),
               "diagnostics.caseId 与顶层 caseId 一致");
            ck(dg.has("sid") && dg["sid"].s() == d["sid"].s(), "diagnostics.sid 与顶层 sid 一致");
            ck(dg.has("eventCounts") && dg["eventCounts"].type == rta::net::Json::Obj &&
               dg["eventCounts"].has("written") && dg["eventCounts"].has("dropped") &&
               dg["eventCounts"].has("recent"),
               "diagnostics.eventCounts 含 written/dropped/recent");
            ck(dg.has("retention") && dg["retention"].type == rta::net::Json::Obj &&
               dg["retention"]["files"].n() >= 1 && dg["retention"]["maxBytes"].n() > 0 &&
               dg["retention"]["totalMaxBytes"].n() > 0,
               "diagnostics.retention 含 files/maxBytes/totalMaxBytes");

            // 全局防泄露断言 + 通过真实 diag_bundle_assemble / bundle_json 校验
            std::vector<BundleEntry> bItems;
            bItems.push_back(make_entry(kDiagName, snapCn, EntryKind::Json, 100));
            bItems.push_back(make_entry(kEventsName, rta::diag::event_log().snapshot_text(), EntryKind::Jsonl, 80));
            bItems.push_back(make_entry(kUiEventsName, diag_ui_log().snapshot_text(), EntryKind::Jsonl, 60));
            const AssembleResult ar = diag_bundle_assemble(diag_bundle_spec(), std::move(bItems));
            ck(snapCn.size() < diag_bundle_spec().budget_bytes,
               "diag.json 体积远小于 bundle 预算",
               std::to_string(snapCn.size()) + " / " + std::to_string(diag_bundle_spec().budget_bytes));
            ck(ar.ok && !ar.over_budget, "真实 diag.json 经 diag_bundle_assemble 组装成功且不超预算", ar.err);
            const std::string bj = bundle_json(ar);
            ck(!bj.empty() && utf8_valid(bj), "bundle_json(ar) 产出合法 UTF-8 非空串");
            const std::string zipBytes = zip_of(ar);
            ck(zipBytes.size() > 4 && zipBytes[0] == 'P' && zipBytes[1] == 'K',
               "真实 diag.json 经 zip_of 产出合法 PK ZIP", std::to_string(zipBytes.size()));
            const rta::net::Json bParsed = rta::net::json_parse(bj);
            ck(bParsed.type == rta::net::Json::Obj && bParsed["files"][kDiagName].s() == snapCn,
               "bundle_json 中 files['diag.json'] 与 diag_snapshot_json 逐字节一致");

            auto noLeaks = [&](const std::string& blob, const char* label) {
                ck(blob.find(kFakeUpdateTok) == std::string::npos, std::string(label) + ": 无 update token");
                ck(blob.find(kFakeErrTok) == std::string::npos, std::string(label) + ": 无 error token");
                ck(blob.find(kFakeQueryTok) == std::string::npos, std::string(label) + ": 无 URL query token");
                ck(blob.find(kFakeStreamTok) == std::string::npos, std::string(label) + ": 无 stream URL token");
                ck(blob.find(secretUser) == std::string::npos, std::string(label) + ": 无真实用户名");
                ck(blob.find("/Users/" + secretUser) == std::string::npos, std::string(label) + ": 无绝对用户路径");
                ck(blob.find("living_room_ir.wav") == std::string::npos && blob.find("hd800s_eq.txt") == std::string::npos &&
                   blob.find("ir=") == std::string::npos && blob.find("eq=") == std::string::npos,
                   std::string(label) + ": 无 ir=/eq= 文件路径");
            };
            noLeaks(snapCn, "diag.json");
            noLeaks(bj, "bundle_json");
            noLeaks(zipBytes, "diagzip");

            // 切到 global 通道、paused + 空队列 + 带 token 流媒体路径复测
            {
                std::ofstream uf(fakeCfg + "/update.conf", std::ios::binary | std::ios::trunc);
                uf << "token=" << kFakeUpdateTok << "\n"
                   << "channel=global\n";
            }
            {
                std::lock_guard<std::mutex> lk(g_ps.mtx);
                g_ps.playing.store(false);
                g_ps.paused.store(true);
                g_ps.current = "https://cdn.example.com/audio/HiResTrack.flac?token=" + kFakeStreamTok;
                g_ps.error.clear();
            }
            {
                std::lock_guard<std::mutex> lk(g_q.mtx);
                g_q.items.clear();
            }
            const std::string snapGlobal = diag_snapshot_json(false);
            const rta::net::Json dg2 = rta::net::json_parse(snapGlobal);
            ck(dg2["channels"]["updateChannel"].s() == "global" &&
               dg2["channels"]["updateManifestHost"].s() == "raw.githubusercontent.com",
               "channels 切回 global 时 updateChannel/updateManifestHost 随之更新",
               dg2["channels"]["updateChannel"].s() + "/" + dg2["channels"]["updateManifestHost"].s());
            ck(dg2["playback"]["playing"].b == false && dg2["playback"]["paused"].b == true &&
               (long long)dg2["playback"]["queueCount"].n() == 0 &&
               dg2["playback"]["currentPath"].s() == "HiResTrack.flac" &&
               dg2["playback"]["lastError"].s().empty(),
               "playback 暂停/空队列/无错误/URL 去 query 仅留文件名");
            noLeaks(snapGlobal, "diag.json(global)");

            {
                std::lock_guard<std::mutex> lk(g_ps.mtx);
                g_ps.playing.store(false);
                g_ps.paused.store(false);
                g_ps.current.clear();
                g_ps.error.clear();
            }
            g_diagStartup.dir = savedDiagDir;
            fs::remove_all(fs::path(root), ec);
        }

        if (hadHome) ::setenv("HOME", savedHome.c_str(), 1);
        if (hadState) ::setenv("RLPLAYER_STATE_DIR", savedState.c_str(), 1);
        else ::unsetenv("RLPLAYER_STATE_DIR");
        if (hadLib) ::setenv("RLPLAYER_LIBRARY_DIR", savedLib.c_str(), 1);
        else ::unsetenv("RLPLAYER_LIBRARY_DIR");
    }

    std::printf("\n----------------------------------------\n");
    std::printf("PASS %d / FAIL %d\n", g_pass, g_fails);
    return g_fails == 0 ? 0 : 1;
}
