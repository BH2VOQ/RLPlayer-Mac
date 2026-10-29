// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_diag_bundle.cpp — 诊断包 v2（src/diag/bundle.h）的离线判据
//
// 判据设计的三个原则（铁律 3：测试通过 ≠ 测对了东西）：
//   ① 不靠自洽：sha256 用 FIPS 官方向量核对，不用"算两遍一样"当证据；
//   ② 对抗优先：正常路径只占一半，另一半是**篡改/伪造/缺失**——只有这些红了，
//      "校验能发现包被动过"这句话才成立；
//   ③ 边界写死：裁剪后的字节数、首行是否仍是完整 JSON、整包是否 ≤ 预算，
//      都按具体数字断言，不用"看起来差不多"。
//
// 全部用例在隔离临时目录里跑（mkdtemp），结束时删除；RTADIAG_KEEP_TMP=1 可保留现场。
// 不联网、不开设备、不播放、不杀进程。
#include "diag/bundle.h"

#include <cstdio>
#include <cstring>
#include <filesystem>
#include <set>
#include <string>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;
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

// ---------------- 临时目录 ----------------
static std::string g_root;

static std::string mk_tmp_root() {
    const char* base = std::getenv("TMPDIR");
    std::string t = (base && *base) ? base : "/tmp";
    while (!t.empty() && t.back() == '/') t.pop_back();
    std::string tmpl = t + "/rlplayer-diagbundle-XXXXXX";
    std::vector<char> buf(tmpl.begin(), tmpl.end());
    buf.push_back('\0');
    if (!mkdtemp(buf.data())) return std::string();
    return std::string(buf.data());
}

static std::string sub(const std::string& name) {
    const std::string p = g_root + "/" + name;
    return p;
}

static bool write_file(const std::string& path, const std::string& data) {
    std::ofstream f(fs::path(path), std::ios::binary | std::ios::trunc);
    if (!f) return false;
    f.write(data.data(), (std::streamsize)data.size());
    return (bool)f;
}

static bool read_file(const std::string& path, std::string& out) {
    std::ifstream f(fs::path(path), std::ios::binary);
    if (!f) return false;
    out.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    return true;
}

// ---------------- 夹具 ----------------
static std::string jsonl_of(size_t lines) {
    std::string s;
    for (size_t i = 0; i < lines; ++i)
        s += "{\"ts\":\"2026-10-29T03:00:00Z\",\"seq\":" + std::to_string(i) +
             ",\"evt\":\"tick\",\"stage\":\"io\",\"kv\":{\"i\":" + std::to_string(i) + "}}\n";
    return s;
}

// 一个"正常"包：4 个必需条目齐全。
static AssembleResult make_ok_bundle(const std::string& diag = "{\"os\":\"macOS 27.0.1\"}") {
    BundleSpec spec;
    spec.app_version = "1.1.1-beta1";
    spec.app_build = "Oct 29 2026";
    spec.platform.os = "macOS 27.0.1";
    spec.platform.arch = "arm64";
    spec.platform.cpu = "Apple M4";
    spec.generator_version = "1.1.1-beta1";
    spec.cs.origin = "test";
    std::vector<BundleEntry> items;
    items.push_back(make_entry(kDiagName, diag, EntryKind::Json, 100));
    items.push_back(make_entry(kEventsName,
        "{\"seq\":1,\"evt\":\"play.start\",\"stage\":\"decode\",\"kv\":{\"format\":\"flac\",\"rate\":96000}}\n",
        EntryKind::Jsonl, 80));
    items.push_back(make_entry(kUiEventsName,
        "{\"seq\":1,\"evt\":\"ui.click\",\"kv\":{\"target\":\"play\"}}\n", EntryKind::Jsonl, 60));
    return assemble(spec, std::move(items), "报告正文\n");
}

static void section(const char* name) {
    std::printf("\n=== %s ===\n", name);
}

// ============================================================================
int main() {
    setvbuf(stdout, nullptr, _IONBF, 0);
    g_root = mk_tmp_root();
    if (g_root.empty()) {
        std::printf("无法创建临时目录，放弃\n");
        return 2;
    }
    std::printf("临时目录: %s\n", g_root.c_str());

    // ------------------------------------------------------------------
    section("sha256 对 FIPS 180-4 官方向量（不靠自洽）");
    ck(rta::update::sha256_hex(std::string("")) ==
       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
       "sha256(\"\")");
    ck(rta::update::sha256_hex(std::string("abc")) ==
       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
       "sha256(\"abc\")");
    ck(rta::update::sha256_hex(std::string("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")) ==
       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
       "sha256(448 bit 标准串)");

    // ------------------------------------------------------------------
    section("case_id 格式与唯一性");
    {
        const std::time_t now = 1790000000;   // 固定时间，避免跨秒抖动
        const std::string id = make_case_id(now, 1);
        ck(id.rfind("RLP-", 0) == 0, "前缀 RLP-", id);
        ck(id.size() == 26, "长度 26（4+8+1+6+1+6；RLP-YYYYMMDD-HHMMSS-XXXXXX）", id);
        bool digits_ok = true;
        for (std::size_t i = 4; i < 19; ++i) {
            const char c = id[i];
            if (i == 12) { if (c != '-') digits_ok = false; continue; }
            if (!std::isdigit((unsigned char)c)) digits_ok = false;
        }
        ck(digits_ok, "日期时间段是数字且第 12 位为 '-'", id);
        bool hex_ok = true;
        for (std::size_t i = 20; i < 26; ++i) {
            const char c = id[i];
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) hex_ok = false;
        }
        ck(hex_ok, "后 6 位是小写 hex", id);

        std::set<std::string> seen;
        for (int i = 0; i < 2000; ++i) seen.insert(make_case_id(now, (uint64_t)i));
        ck(seen.size() == 2000, "同秒内 2000 次生成无重复",
           "实际 " + std::to_string(seen.size()));
    }

    // ------------------------------------------------------------------
    section("JSON 转义");
    {
        ck(json_escape(std::string("a\"b\\c\nd\te")) == "a\\\"b\\\\c\\nd\\te", "引号/反斜杠/换行/制表");
        ck(json_escape(std::string(1, (char)0x01)) == "\\u0001", "控制字符转 \\u00xx");
        ck(json_escape(std::string("中文 UTF-8")) == "中文 UTF-8", "UTF-8 原样保留（不转义）");
    }

    // ------------------------------------------------------------------
    section("组装：schema / case_id / 逐条目 sha256 / checksums 链");
    AssembleResult good;
    {
        good = make_ok_bundle();
        ck(good.ok, "组装成功", good.err);
        ck(!good.case_id.empty(), "回填了 case_id", good.case_id);
        ck(good.entries.size() == 4, "4 个 payload 条目（diag/events/uievents/report）",
           std::to_string(good.entries.size()));
        ck(!good.truncated && !good.over_budget, "小包不裁剪、不超预算");
        ck(good.total_bytes <= good.budget_bytes, "整包 ≤ 预算",
           std::to_string(good.total_bytes) + " vs " + std::to_string(good.budget_bytes));

        const rta::net::Json m = rta::net::json_parse(good.manifest_json);
        ck(m.type == rta::net::Json::Obj, "manifest 是 JSON 对象");
        ck(m["schema"].s() == kBundleSchema, "manifest.schema 正确", m["schema"].s());
        ck(m["schema_version"].n() == 2, "schema_version=2");
        ck(m["case_id"].s() == good.case_id, "manifest.case_id 与回填一致");
        ck(m["entries"].size() == 4, "manifest 声明 4 条 entries");
        ck(m["required"].size() == 4, "manifest 声明 4 条 required");
        ck(m["run"].has("clean_exit"), "manifest 带运行标记 clean_exit");

        // 逐条目：声明值 == 真实文件字节的 sha256
        bool all_sha_ok = true, all_bytes_ok = true;
        for (std::size_t i = 0; i < m["entries"].size(); ++i) {
            const rta::net::Json& e = m["entries"].at(i);
            std::string actual;
            for (const auto& me : good.entries)
                if (me.rec.name == e["name"].s()) actual = me.data;
            if (rta::update::sha256_hex(actual) != e["sha256"].s()) all_sha_ok = false;
            if ((long long)actual.size() != (long long)e["bytes"].n()) all_bytes_ok = false;
        }
        ck(all_sha_ok, "每条 entry 的 sha256 与真实字节一致");
        ck(all_bytes_ok, "每条 entry 的 bytes 与真实字节数一致");

        // checksums.txt：sha256sum 兼容 + 覆盖 manifest 本身
        {
            bool manifest_covered = false;
            std::size_t lines = 0;
            std::istringstream in(good.checksums_txt);
            std::string line;
            bool all_match = true;
            while (std::getline(in, line)) {
                if (line.empty()) continue;
                ++lines;
                std::string hex, name;
                if (!parse_checksum_line(line, hex, name)) { all_match = false; continue; }
                if (name == kManifestName) {
                    manifest_covered = true;
                    if (hex != rta::update::sha256_hex(good.manifest_json)) all_match = false;
                    continue;
                }
                std::string actual;
                for (const auto& me : good.entries) if (me.rec.name == name) actual = me.data;
                if (rta::update::sha256_hex(actual) != hex) all_match = false;
            }
            ck(lines == 5, "checksums.txt 有 5 行（manifest + 4 payload）", std::to_string(lines));
            ck(all_match, "checksums.txt 每行都与真实字节一致");
            ck(manifest_covered, "checksums.txt 覆盖 manifest.json 本身（链闭合）");
        }
    }

    // ------------------------------------------------------------------
    section("组装：拒绝非法输入（不产出‘看起来正常’的包）");
    {
        // 缺必需条目
        {
            BundleSpec spec;
            std::vector<BundleEntry> items;
            items.push_back(make_entry(kDiagName, "{}", EntryKind::Json, 100));
            items.push_back(make_entry(kEventsName, "", EntryKind::Jsonl, 80));
            const auto r = assemble(spec, std::move(items), "");
            ck(!r.ok, "缺 uievents/report 时失败");
            ck(r.err.find("uievents.jsonl") != std::string::npos ||
               r.err.find("report.txt") != std::string::npos, "错误信息点名缺哪个", r.err);
        }
        // 解包穿越
        {
            BundleSpec spec;
            std::vector<BundleEntry> items;
            items.push_back(make_entry("../evil.json", "{}", EntryKind::Json, 100));
            const auto r = assemble(spec, std::move(items), "");
            ck(!r.ok && r.err.find("..") != std::string::npos, "拒绝 '../' 条目名", r.err);
        }
        {
            BundleSpec spec;
            std::vector<BundleEntry> items;
            items.push_back(make_entry("/etc/passwd", "x", EntryKind::Text, 100));
            const auto r = assemble(spec, std::move(items), "");
            ck(!r.ok, "拒绝绝对路径条目名", r.err);
        }
        // 重名
        {
            BundleSpec spec;
            std::vector<BundleEntry> items;
            items.push_back(make_entry("a.txt", "1", EntryKind::Text, 10));
            items.push_back(make_entry("a.txt", "2", EntryKind::Text, 20));
            const auto r = assemble(spec, std::move(items), "");
            ck(!r.ok && r.err.find("重复") != std::string::npos, "拒绝重名条目", r.err);
        }
    }

    // ------------------------------------------------------------------
    section("预算裁剪：保留最近内容 + 显式标记 + 首行仍是完整 JSON");
    {
        BundleSpec spec;
        spec.budget_bytes = 400u * 1024u;
        std::vector<BundleEntry> items;
        items.push_back(make_entry(kDiagName, "{\"os\":\"macOS\"}", EntryKind::Json, 100));
        items.push_back(make_entry(kEventsName, jsonl_of(20000), EntryKind::Jsonl, 80));
        items.push_back(make_entry(kUiEventsName, jsonl_of(2000), EntryKind::Jsonl, 60));
        items.push_back(make_entry("rlplayer-playback.log", jsonl_of(20000), EntryKind::Log, 40));
        items.push_back(make_entry("rlplayer-playback.log.1", jsonl_of(20000), EntryKind::Log, 40));
        const auto r = assemble(spec, std::move(items), "报告");

        ck(r.ok, "裁剪后仍能组装成功", r.err);
        ck(r.truncated, "标记为已裁剪");
        ck(r.total_bytes <= spec.budget_bytes, "裁剪后整包 ≤ 预算",
           std::to_string(r.total_bytes) + " vs " + std::to_string(spec.budget_bytes));
        ck(r.dropped.size() == 2, "两份低优先级旧日志被整条丢弃（不足最小尾部）",
           std::to_string(r.dropped.size()));

        // diag.json 是 pinned：一个字节都不许少
        bool diag_intact = false;
        for (const auto& e : r.entries)
            if (e.rec.name == kDiagName) diag_intact = (!e.rec.truncated && e.data == "{\"os\":\"macOS\"}");
        ck(diag_intact, "pinned 条目（diag.json）完整保留");

        // events.jsonl：保留尾部、裁头对齐到行首、首行是完整 JSON、最后一个事件是"最新的"
        bool ev_ok = false;
        for (const auto& e : r.entries) {
            if (e.rec.name != kEventsName) continue;
            // JSONL 通常以换行结束；最后的空串不是最后一条事件。
            const size_t end = e.data.find_last_not_of("\r\n");
            const size_t nl = end == std::string::npos ? std::string::npos : e.data.rfind('\n', end);
            const std::string tail_line = end == std::string::npos ? std::string() :
                e.data.substr(nl == std::string::npos ? 0 : nl + 1,
                              end + 1 - (nl == std::string::npos ? 0 : nl + 1));
            const rta::net::Json last = rta::net::json_parse(tail_line);
            const rta::net::Json first = rta::net::json_parse(e.data.substr(0, e.data.find('\n')));
            ev_ok = e.rec.truncated &&
                    e.rec.dropped_head_bytes > 0 &&
                    e.rec.dropped_head_bytes == e.rec.original_bytes - e.rec.bytes &&
                    e.rec.newline_aligned &&
                    first.type == rta::net::Json::Obj &&
                    last.type == rta::net::Json::Obj &&
                    (long long)last["seq"].n() == 19999;   // 最新那条保留着
        }
        ck(ev_ok, "events.jsonl 保留尾部、裁头对齐行首、首末行都是完整 JSON、seq=19999 在");

        // 没有切断 UTF-8
        bool utf8_ok = true;
        for (const auto& e : r.entries) {
            if (e.data.empty()) continue;
            const unsigned char c0 = (unsigned char)e.data[0];
            if ((c0 & 0xC0u) == 0x80u) utf8_ok = false;   // 首字节是续字节 = 切断
        }
        ck(utf8_ok, "所有条目首字节都不是 UTF-8 续字节");

        // manifest 里写明裁剪事实
        const rta::net::Json m = rta::net::json_parse(r.manifest_json);
        ck(m["truncation"]["applied"].b, "manifest.truncation.applied=true");
        ck(m["truncation"]["policy"].s() == "keep-newest-by-priority", "裁剪策略写进 manifest");
        ck(m["truncation"]["dropped"].size() == 2, "manifest 列出被丢弃的条目名");
        ck(m["truncation"]["dropped_head_bytes"].n() > 0, "manifest 记录丢弃的头部字节数");
        bool entry_flagged = false;
        for (std::size_t i = 0; i < m["entries"].size(); ++i) {
            const rta::net::Json& e = m["entries"].at(i);
            if (e["name"].s() == kEventsName && e["truncated"].b && e["original_bytes"].n() > e["bytes"].n())
                entry_flagged = true;
        }
        ck(entry_flagged, "manifest 的 events 条目带 truncated/original_bytes/dropped_head_bytes");
    }

    // ------------------------------------------------------------------
    section("往返：目录 → 读回 → 校验通过");
    {
        std::string err;
        ck(write_bundle_dir(sub("ok"), good, err), "写出目录", err);
        Bundle b;
        ck(load_bundle(sub("ok"), b), "读目录并校验通过", b.verify.summary());
        ck(b.verify.ok && !b.verify.is_zip, "ok=true / is_zip=false");
        ck(b.meta.case_id == good.case_id, "case_id 一致", b.meta.case_id);
        ck(b.verify.verified == good.entries.size(), "逐条目 sha256 全部复核通过",
           std::to_string(b.verify.verified) + "/" + std::to_string(good.entries.size()));
        ck(b.find(kEventsName) != nullptr && b.text(kReportName) == "报告正文\n", "内容读回一致");
        ck(b.verify.issue_lines().empty(), "没有 issue");
    }

    // ------------------------------------------------------------------
    section("往返：zip → 读回 → 校验通过（复用 rta::zip STORE）");
    {
        const std::string z = zip_of(good);
        ck(z.size() > 22 && z[0] == 'P' && z[1] == 'K', "zip 以 PK 开头");
        Bundle b;
        ck(load_from_zip_bytes(z, "memory", b), "从内存 zip 校验通过", b.verify.summary());
        ck(b.verify.is_zip, "is_zip=true");
        ck(b.meta.schema == kBundleSchema, "schema 读回正确");
        std::string err;
        ck(write_bundle_zip(sub("ok.zip"), good, err), "写出 zip", err);
        Bundle b2;
        ck(load_bundle(sub("ok.zip"), b2), "从 zip 文件校验通过");
    }

    // ------------------------------------------------------------------
    section("对抗：改一个字节（目录）");
    {
        std::string err;
        write_bundle_dir(sub("tamper"), good, err);
        std::string d;
        read_file(sub("tamper") + "/" + kDiagName, d);
        d.push_back(' ');                       // 只加一个字节
        write_file(sub("tamper") + "/" + kDiagName, d);
        Bundle b;
        ck(!load_bundle(sub("tamper"), b), "校验失败");
        bool size_or_hash = false;
        for (const auto& i : b.verify.issues)
            if ((i.kind == IssueKind::SizeMismatch || i.kind == IssueKind::HashMismatch) &&
                i.name == kDiagName) size_or_hash = true;
        ck(size_or_hash, "报出 diag.json 的 size/hash 不符");
        ck(b.verify.fail_count() >= 1, "至少一项 Fail",
           std::to_string(b.verify.fail_count()));
    }

    // ------------------------------------------------------------------
    section("对抗：同长度替换（只翻一个 bit，大小不变）");
    {
        std::string err;
        write_bundle_dir(sub("bitflip"), good, err);
        std::string d;
        read_file(sub("bitflip") + "/" + kEventsName, d);
        d[5] = (char)(d[5] ^ 0x01);
        write_file(sub("bitflip") + "/" + kEventsName, d);
        Bundle b;
        ck(!load_bundle(sub("bitflip"), b), "校验失败");
        bool hash = false, cks = false;
        for (const auto& i : b.verify.issues) {
            if (i.kind == IssueKind::HashMismatch && i.name == kEventsName) hash = true;
            if (i.kind == IssueKind::ChecksumsMismatch && i.name == kEventsName) cks = true;
        }
        ck(hash, "manifest 侧发现 hash 不符");
        ck(cks, "checksums 侧也发现不符（两道保险都响）");
    }

    // ------------------------------------------------------------------
    section("对抗：zip 内数据被改（CRC32 兜住）");
    {
        std::string z = zip_of(good);
        // 在 events.jsonl 的数据区里翻一个字节：按本地头长度定位（STORE 无压缩）
        const std::string needle = "play.start";
        const std::size_t at = z.find(needle);
        ck(at != std::string::npos, "找到要改的字节位置");
        if (at != std::string::npos) {
            z[at] = (char)(z[at] ^ 0x20);
            Bundle b;
            ck(!load_from_zip_bytes(z, "tampered-zip", b), "zip 校验失败");
            bool corrupt = false;
            for (const auto& i : b.verify.issues) if (i.kind == IssueKind::CorruptEntry) corrupt = true;
            ck(corrupt, "报出 CRC 不符（包级损坏，与 manifest 不符分开报）");
        }
    }

    // ------------------------------------------------------------------
    section("对抗：伪造 manifest（改 sha256 / 改 schema）");
    {
        std::string err;
        write_bundle_dir(sub("forge"), good, err);
        std::string mf;
        read_file(sub("forge") + "/" + kManifestName, mf);
        // 把 events.jsonl 的 sha256 改成全 0
        std::size_t p = mf.find("\"name\":\"events.jsonl\"");
        std::size_t q = mf.find("\"sha256\":\"", p);
        ck(p != std::string::npos && q != std::string::npos, "定位到 manifest 里的 sha256 字段");
        if (p != std::string::npos && q != std::string::npos) {
            mf.replace(q + 10, 64, std::string(64, '0'));
            write_file(sub("forge") + "/" + kManifestName, mf);
            Bundle b;
            ck(!load_bundle(sub("forge"), b), "伪造 manifest 后校验失败");
            bool hash = false;
            for (const auto& i : b.verify.issues)
                if (i.kind == IssueKind::HashMismatch && i.name == kEventsName) hash = true;
            ck(hash, "报出 hash_mismatch（改 manifest 骗不过实际字节）");
        }
    }
    {
        std::string err;
        write_bundle_dir(sub("badschema"), good, err);
        std::string mf;
        read_file(sub("badschema") + "/" + kManifestName, mf);
        const std::size_t p = mf.find(kBundleSchema);
        if (p != std::string::npos) mf.replace(p, std::strlen(kBundleSchema), "rlplayer.diag.bundle/1");
        write_file(sub("badschema") + "/" + kManifestName, mf);
        Bundle b;
        ck(!load_bundle(sub("badschema"), b), "错误 schema 被拒");
        bool sch = false;
        for (const auto& i : b.verify.issues) if (i.kind == IssueKind::SchemaUnsupported) sch = true;
        ck(sch, "报出 schema_unsupported");
    }

    // ------------------------------------------------------------------
    section("对抗：缺文件（删 diag.json / 删 checksums.txt）");
    {
        std::string err;
        write_bundle_dir(sub("miss"), good, err);
        fs::remove(fs::path(sub("miss") + "/" + kDiagName));
        Bundle b;
        ck(!load_bundle(sub("miss"), b), "缺 diag.json ⇒ 校验失败");
        bool missing = false;
        for (const auto& i : b.verify.issues)
            if (i.kind == IssueKind::FileMissing && i.name == kDiagName) missing = true;
        ck(missing, "报出 file_missing diag.json");

        write_bundle_dir(sub("miss2"), good, err);
        fs::remove(fs::path(sub("miss2") + "/" + kChecksumsName));
        Bundle b2;
        ck(!load_bundle(sub("miss2"), b2), "缺 checksums.txt ⇒ 校验失败");
        bool cks = false;
        for (const auto& i : b2.verify.issues) if (i.kind == IssueKind::ChecksumsMissing) cks = true;
        ck(cks, "报出 checksums_missing");
    }

    // ------------------------------------------------------------------
    section("边界：多余文件只警告、不判死");
    {
        std::string err;
        write_bundle_dir(sub("extra"), good, err);
        write_file(sub("extra") + "/notes.txt", "随手放的文件\n");
        Bundle b;
        ck(load_bundle(sub("extra"), b), "仍通过（多余文件不影响证据链）", b.verify.summary());
        bool warn = false;
        for (const auto& i : b.verify.issues)
            if (i.kind == IssueKind::ExtraFile && i.sev == IssueSeverity::Warn) warn = true;
        ck(warn, "但记一条 warn: extra_file");
    }

    // ------------------------------------------------------------------
    section("旧 v1 包：读得进，但明确报「无法核验」");
    {
        std::vector<rta::zip::Entry> z;
        {
            rta::zip::Entry e;
            e.name = "rlplayer-diag.json";
            e.data = "{\"ok\":true,\"version\":\"1.1.0\"}";
            z.push_back(e);
        }
        {
            rta::zip::Entry e;
            e.name = "rlplayer-playback.log";
            e.data = "2026-10-27 23:51:07 START file=/x.flac\n";
            z.push_back(e);
        }
        {
            rta::zip::Entry e;
            e.name = "README.txt";
            e.data = "old package\n";
            z.push_back(e);
        }
        const std::string legacy = rta::zip::build(z);
        Bundle b;
        ck(!load_from_zip_bytes(legacy, "v1.zip", b), "v1 包校验不通过（预期）");
        ck(b.verify.legacy, "标记 legacy=true");
        bool mf = false;
        for (const auto& i : b.verify.issues) if (i.kind == IssueKind::ManifestMissing) mf = true;
        ck(mf, "报出 manifest_missing，并说明这是 v1 包");
        ck(!b.meta.present, "meta.present=false（没有 v2 自描述）");
        ck(b.verify.summary().find("v1") != std::string::npos, "summary 里点名 v1",
           b.verify.summary());
    }

    // ------------------------------------------------------------------
    section("边界：空目录 / 非 zip 文件 / 不存在的路径");
    {
        fs::create_directories(fs::path(sub("empty")));
        Bundle b;
        ck(!load_bundle(sub("empty"), b), "空目录 ⇒ 失败");
        bool empty = false;
        for (const auto& i : b.verify.issues) if (i.kind == IssueKind::EmptyBundle) empty = true;
        ck(empty, "报出 empty_bundle");

        write_file(sub("plain.txt"), "hello, not a zip\n");
        Bundle b2;
        ck(!load_bundle(sub("plain.txt"), b2), "非 zip 文件 ⇒ 失败");
        bool notzip = false;
        for (const auto& i : b2.verify.issues) if (i.kind == IssueKind::NotAZip) notzip = true;
        ck(notzip, "报出 not_a_zip");

        Bundle b3;
        ck(!load_bundle(sub("does-not-exist"), b3), "不存在的路径 ⇒ 失败");
        ck(!b3.verify.issues.empty(), "但仍然给出原因（不静默）");
    }

    // ------------------------------------------------------------------
    section("checksums.txt 行解析（sha256sum 兼容）");
    {
        std::string hex, name;
        ck(parse_checksum_line("ab12cd34" + std::string(56, '0') + "  events.jsonl", hex, name) &&
           hex == "ab12cd34" + std::string(56, '0') && name == "events.jsonl",
           "两个空格分隔");
        ck(parse_checksum_line(std::string(64, 'A') + " *diag.json\r", hex, name) &&
           hex == std::string(64, 'a') && name == "diag.json",
           "星号（-b 模式）+ CRLF + 大写 hex 归一化");
        ck(!parse_checksum_line("deadbeef  x", hex, name), "过短的 hex 被拒");
        ck(!parse_checksum_line(std::string(64, 'z') + "  x", hex, name), "非 hex 字符被拒");
        ck(!parse_checksum_line(std::string(64, 'a'), hex, name), "缺名字被拒");
    }

    // ------------------------------------------------------------------
    std::printf("\n%s：通过 %d / 失败 %d\n", g_fails == 0 ? "全部通过" : "存在失败",
                g_pass, g_fails);
    if (std::getenv("RTADIAG_KEEP_TMP")) {
        std::printf("保留现场: %s\n", g_root.c_str());
    } else {
        std::error_code ec;
        fs::remove_all(fs::path(g_root), ec);
    }
    return g_fails == 0 ? 0 : 1;
}
