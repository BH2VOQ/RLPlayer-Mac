// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_diag_event.cpp — 1.1.1 D1：统一事件信封 / 错误码表 / JSONL 落盘轮转 / 落盘前脱敏
//
// ===========================================================================
// 这条判据怎么证明事（铁律 3）
//
//   A 段（红侧基线）：**只用**既有 src/net/feedback_redact.h 处理一条真实事件行，
//     断言它确实漏掉三类东西 —— URL query（搜索词/签名参数）、歌词正文、
//     20 字符的 key=（不足 32 字符门槛）。这三条现在 PASS 表示"旧层确实漏"，
//     是可复跑的红证据，不是一次性观察。谁把既有规则改到不漏了，A 段会红 —— 故意的。
//
//   B 段（信封）：非等宽断言字段**顺序**（ts/seq/sid/rid/evt/stage/code/kv），
//     JSON 转义（引号/反斜杠/换行/控制字符）、非法 UTF-8 字节替换、序列化→解析往返。
//
//   C 段（磁盘真值，最关键）：断言判据不是"返回值里没有明文"，而是
//     **把文件读回来逐字节检查**。密钥 / URL query / 家目录用户名 / 歌词正文
//     在磁盘上一个字节都不许留；同时路径结构必须保留（否则诊断无意义）。
//
//   D 段（轮转）：8 MB×3 的默认值；用小阈值（2 KB）真跑轮转，断言只留 3 份、
//     .3 不存在、每份 ≤ 阈值、旧事件真的被滚走、recent() 跨轮转连续且 seq 递增。
//
//   E 段（并发）：4 线程 × 200 条，断言行数、seq 唯一连续、每行可解析（无撕裂行）。
//
//   F 段（边界）：n=0 / n>总数 / 损坏行被跳过并计数（诊断包不能被一行坏数据带崩）。
//
//   G 段（错误码表稳定性）：id/code 唯一、code 前缀 == stage 名、冻结版本号、
//     逐条映射抽查。改名/复用 id 会让这段红。
//
//   H 段（不误伤）：正常事件（曲名里的 "Token Ring"、曲库路径、采样率）原样保留。
// ===========================================================================
#include "diag/diag.h"
#include "diag/error_codes.h"
#include "diag/event.h"
#include "diag/event_log.h"
#include "diag/redact_policy.h"
#include "net/feedback_redact.h"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

#include <unistd.h>

static int g_fail = 0;
static int g_pass = 0;

static void ck(bool cond, const char* what, const std::string& detail = std::string()) {
    if (cond) {
        std::printf("  [PASS] %s\n", what);
        ++g_pass;
    } else {
        std::printf("  [FAIL] %s  %s\n", what, detail.c_str());
        ++g_fail;
    }
}

static void ck_eq(const std::string& got, const std::string& want, const char* what) {
    if (got == want) {
        std::printf("  [PASS] %s\n", what);
        ++g_pass;
    } else {
        std::printf("  [FAIL] %s\n         期望: %s\n         实际: %s\n", what, want.c_str(),
                    got.c_str());
        ++g_fail;
    }
}

static void ck_has(const std::string& hay, const std::string& needle, const char* what) {
    ck(hay.find(needle) != std::string::npos, what, "缺少子串: " + needle + "  ⟹ " + hay);
}

static void ck_not_has(const std::string& hay, const std::string& needle, const char* what) {
    ck(hay.find(needle) == std::string::npos, what, "仍含明文: " + needle + "  ⟹ " + hay);
}

// ---- 隔离用临时目录：unique per pid+tag，清理后重建，绝不碰真实用户目录 ----------
static std::vector<std::string> g_dirs;   // 测试结束统一清理，避免污染 /tmp

static std::string fresh_dir(const std::string& tag) {
    std::error_code ec;
    auto p = std::filesystem::temp_directory_path(ec);
    if (ec) p = "/tmp";
    const auto dir = p / ("rlplayer-diag-test-" + tag + "-" + std::to_string((long)::getpid()));
    std::filesystem::remove_all(dir, ec);
    std::filesystem::create_directories(dir, ec);
    g_dirs.push_back(dir.string());
    return dir.string();
}

static std::string read_file(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return std::string();
    return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

static bool has(const std::string& hay, const std::string& needle) {
    return hay.find(needle) != std::string::npos;
}

static size_t count_lines(const std::string& s) {
    size_t n = 0;
    for (char c : s)
        if (c == '\n') ++n;
    return n;
}

int main() {
    std::printf("== test_diag_event: 事件信封 / 错误码 / JSONL 落盘与轮转 ==\n");

    // ---------------------------------------------------------------- A（红基线）
    std::printf("\n-- A. 红侧基线：既有 feedback_redact.h 单独用在事件行上漏了什么 --\n");
    {
        const std::string evtLine =
            "{\"evt\":\"meta.fetch\",\"kv\":{\"url\":\"https://api.example.com/v1/search?q=My+Secret+Song"
            "&sig=deadbeef\",\"lyrics\":\"第一句歌词\\n第二句歌词\",\"key\":\"0123456789abcdef0123\"}}";
        const std::string legacy = rta::feedback::redact(evtLine);
        std::printf("  旧层输出: %s\n", legacy.c_str());
        ck_has(legacy, "My+Secret+Song", "A1 红基线：不认 URL query，搜索词明文仍在");
        ck_has(legacy, "第一句歌词", "A2 红基线：不认歌词正文，整段明文仍在");
        ck_has(legacy, "0123456789abcdef0123",
               "A3 红基线：裸 key= 只有 ≥32 字符才抹，20 字符密钥泄漏");
        // 既有能力对照（不是本轮新增）：家目录用户名会被抹
        ck_has(rta::feedback::redact("/Users/august/Library/x"), "/Users/<user>/Library/x",
               "A4 既有层已经能抹家目录用户名（对照，防把旧能力算成新能力）");
    }

    // ---------------------------------------------------------------- B（信封）
    std::printf("\n-- B. 信封：字段顺序 / 转义 / 非法 UTF-8 / 往返 --\n");
    {
        rta::diag::Event e;
        e.ts = 1750000000123LL;
        e.seq = 7;
        e.sid = "s1";
        e.rid = "r1";
        e.evt = "play.start";
        e.stage = "io";
        e.code = "io.open_failed";
        e.num("rate", 44100);
        e.boolean("ok", true);
        e.str("path", "a\"b\\c");
        const std::string got = rta::diag::event_to_json(e);
        ck_eq(got,
              "{\"ts\":1750000000123,\"seq\":7,\"sid\":\"s1\",\"rid\":\"r1\",\"evt\":\"play.start\","
              "\"stage\":\"io\",\"code\":\"io.open_failed\",\"kv\":{\"rate\":44100,\"ok\":true,"
              "\"path\":\"a\\\"b\\\\c\"}}",
              "B1 字段顺序固定 + 引号/反斜杠转义");

        rta::diag::Event p;
        std::string err;
        ck(rta::diag::event_from_json(got, &p, &err), "B2 序列化结果可解析", err);
        ck_eq(p.evt, "play.start", "B3 往返 evt");
        ck_eq(p.sid, "s1", "B4 往返 sid");
        ck(p.seq == 7 && p.ts == 1750000000123LL, "B5 往返 ts/seq 精确");
        ck(p.kv.size() == 3, "B6 往返 kv 条数", std::to_string(p.kv.size()));
        ck(p.get("rate") && *p.get("rate") == "44100", "B7 数值 kv 往返");
        ck(p.get("ok") && *p.get("ok") == "true", "B8 布尔 kv 往返");
        ck(p.get("path") && *p.get("path") == "a\"b\\c", "B9 转义往返逐字一致");

        // 控制字符与非法 UTF-8：JSONL 一行一条，绝不能被值里的换行撕裂
        rta::diag::Event u;
        u.evt = "x";
        u.str("nl", "a\nb\tc");
        u.str("bad", std::string("ok") + (char)0x80 + "md");
        const std::string uj = rta::diag::event_to_json(u);
        ck(count_lines(uj) == 0, "B10 值内换行被转义，序列化结果不含裸换行", uj);
        ck_has(uj, "\"a\\nb\\tc\"", "B11 \\n/\\t 用短转义");
        rta::diag::Event up;
        ck(rta::diag::event_from_json(uj, &up, &err), "B12 含转义的事件仍可解析", err);
        ck(up.get("nl") && *up.get("nl") == "a\nb\tc", "B13 转义往返");
    }

    // ---------------------------------------------------------------- C（磁盘真值）
    std::printf("\n-- C. 落盘脱敏：判据是磁盘字节，不是返回值 --\n");
    {
        const std::string dir = fresh_dir("redact");
        rta::diag::EventLog log({dir, "events.jsonl", 8ull << 20, 3, true});
        std::string err;
        ck(log.open(&err), "C0 打开事件日志", err);
        log.set_sid("sess-test-1");

        const std::string kKey = "sk-live-ABCDEF1234567890XYZ";
        const std::string kLyric = "第一句歌词\n第二句歌词\n第三句歌词";
        rta::diag::Event e;
        e.rid = "req-12345";
        e.evt = "meta.fetch";
        e.stage = rta::diag::stage_name(rta::diag::Stage::Meta);
        e.code = "meta.timeout";
        e.str("api_key", kKey);
        e.str("url", "https://api.example.com/v1/tracks?q=My%20Secret%20Song&access_token=zzz&sig=abc");
        e.str("path", "/Users/august/Library/Application Support/RLPlayer/cache.db");
        e.str("lyrics", kLyric);
        e.str("key", "0123456789abcdef0123");   // 20 字符：既有层门槛 32，会漏
        e.num("rate", 44100);
        rta::diag::RedactReport rep;
        ck(log.write(e, &rep), "C1 写入成功");
        ck(rep.secret_key >= 2, "C2 结构化键名判定命中 ≥2（api_key + 短 key）",
           "实际 " + std::to_string(rep.secret_key));
        ck(rep.url_query >= 1, "C3 URL query 命中", "实际 " + std::to_string(rep.url_query));
        ck(rep.lyrics >= 1, "C4 歌词正文命中", "实际 " + std::to_string(rep.lyrics));
        log.close();

        const std::string disk = read_file(dir + "/events.jsonl");
        std::printf("  磁盘一行: %s\n", disk.c_str());
        ck_not_has(disk, kKey, "C5 磁盘无 OpenAI 形态密钥");
        ck_not_has(disk, "ABCDEF1234567890", "C5b 磁盘无密钥中段");
        ck_not_has(disk, "My%20Secret%20Song", "C6 磁盘无 URL query 搜索词");
        ck_not_has(disk, "sig=abc", "C6b 磁盘无 URL query 签名参数");
        ck_has(disk, "https://api.example.com/v1/tracks?<redacted-query:3>",
               "C6c URL 结构保留、query 整体标记（3 个参数）");
        ck_not_has(disk, "august", "C7 磁盘无用户名");
        ck_has(disk, "/Users/<user>/Library/Application Support/RLPlayer/cache.db",
               "C7b 家目录结构保留，只换用户名段");
        ck_not_has(disk, "第一句歌词", "C8 磁盘无歌词正文");
        ck_has(disk, "<redacted:lyrics", "C8b 歌词位置留长度标记");
        ck_not_has(disk, "0123456789abcdef0123", "C9 磁盘无 20 字符裸 key 值");
        ck_has(disk, "\"rate\":44100", "C10 正常数值原样保留");
        ck(count_lines(disk) == 1, "C11 五类内容混在一个事件里仍然只有一行（歌词含换行）",
           "行数 " + std::to_string(count_lines(disk)));
        rta::diag::Event back;
        ck(rta::diag::event_from_json(disk.substr(0, disk.find('\n')), &back, &err),
           "C12 脱敏后仍是合法 JSON 事件", err);
        ck_eq(back.rid, "req-12345", "C13 rid 保留（定位请求要它）");
    }

    // ---------------------------------------------------------------- D（轮转）
    std::printf("\n-- D. 轮转：默认 8MB×3，实测小阈值滚动 --\n");
    {
        const rta::diag::EventLogConfig def{};
        ck(def.max_bytes == 8ull * 1024 * 1024, "D1 默认上限 8 MB",
           std::to_string(def.max_bytes));
        ck(def.files == 3, "D2 默认保留 3 份", std::to_string(def.files));

        const std::string dir = fresh_dir("rotate");
        const uint64_t kMax = 2048;
        rta::diag::EventLog log({dir, "events.jsonl", kMax, 3, true});
        std::string err;
        ck(log.open(&err), "D3 打开", err);
        log.set_sid("sess-rot");
        for (int i = 0; i < 200; ++i) {
            rta::diag::Event e;
            e.evt = "tick";
            e.stage = "io";
            e.num("i", i);
            e.str("pad", std::string(60, 'x'));
            if (!log.write(e)) {
                ck(false, "D4 写入中途失败", "i=" + std::to_string(i));
                break;
            }
        }
        log.close();
        const auto st = log.stats();
        ck(st.rotations > 0, "D4 确实发生过轮转", std::to_string(st.rotations));
        ck(st.lines == 200, "D5 事件条数 200（不丢）", std::to_string(st.lines));
        ck(std::filesystem::exists(dir + "/events.jsonl"), "D6 当前文件存在");
        ck(std::filesystem::exists(dir + "/events.jsonl.1"), "D7 .1 存在");
        ck(std::filesystem::exists(dir + "/events.jsonl.2"), "D8 .2 存在");
        ck(!std::filesystem::exists(dir + "/events.jsonl.3"), "D9 只有 3 份，无 .3");
        std::error_code ec;
        bool sizesOk = true;
        for (const char* n : {"events.jsonl", "events.jsonl.1", "events.jsonl.2"}) {
            const auto sz = std::filesystem::file_size(dir + "/" + n, ec);
            if (ec || sz > kMax) {
                sizesOk = false;
                std::printf("  超限: %s size=%llu\n", n, (unsigned long long)sz);
            }
        }
        ck(sizesOk, "D10 每份都 ≤ 阈值");
    }

    // ---------------------------------------------------------------- E（并发）
    std::printf("\n-- E. 线程安全：4×200 并发写 --\n");
    {
        const std::string dir = fresh_dir("thread");
        rta::diag::EventLog log({dir, "events.jsonl", 8ull << 20, 3, true});
        std::string err;
        ck(log.open(&err), "E1 打开", err);
        std::vector<std::thread> th;
        for (int t = 0; t < 4; ++t) {
            th.emplace_back([&log, t] {
                for (int i = 0; i < 200; ++i) {
                    rta::diag::Event e;
                    e.evt = "conc";
                    e.stage = "io";
                    e.num("t", t);
                    e.num("i", i);
                    log.write(e);
                }
            });
        }
        for (auto& x : th) x.join();
        const auto st = log.stats();
        ck(st.lines == 800, "E2 行数 800", std::to_string(st.lines));
        log.close();

        const std::string disk = read_file(dir + "/events.jsonl");
        ck(count_lines(disk) == 800, "E3 磁盘行数 800（无撕裂/丢行）",
           std::to_string(count_lines(disk)));
        std::vector<uint64_t> seqs;
        size_t pos = 0;
        bool allParse = true;
        while (pos < disk.size()) {
            const size_t nl = disk.find('\n', pos);
            if (nl == std::string::npos) break;
            rta::diag::Event e;
            std::string perr;
            if (!rta::diag::event_from_json(disk.substr(pos, nl - pos), &e, &perr)) allParse = false;
            seqs.push_back(e.seq);
            pos = nl + 1;
        }
        ck(allParse, "E4 每一行都能解析");
        bool contiguous = seqs.size() == 800;
        for (size_t i = 0; i < seqs.size(); ++i)
            if (seqs[i] != i + 1) contiguous = false;
        ck(contiguous, "E5 seq 从 1 连续且唯一（锁内分配）",
           seqs.empty() ? "空" : ("首 " + std::to_string(seqs.front()) + " 尾 " +
                                  std::to_string(seqs.back())));
    }

    // ---------------------------------------------------------------- F（recent 边界）
    std::printf("\n-- F. 最近事件读取：n=0 / n>总数 / 损坏行 --\n");
    {
        const std::string dir = fresh_dir("recent");
        rta::diag::EventLog log({dir, "events.jsonl", 4096, 3, true});
        std::string err;
        ck(log.open(&err), "F1 打开", err);
        log.set_sid("sess-recent");
        for (int i = 0; i < 120; ++i) {
            rta::diag::Event e;
            e.evt = "tick";
            e.stage = "io";
            e.num("i", i);
            e.str("pad", std::string(40, 'y'));
            log.write(e);
        }
        log.close();

        ck(log.recent(0).empty(), "F2 n=0 返回空");
        size_t skipped = 0;
        const auto tail = log.recent(5, &skipped);
        ck(tail.size() == 5, "F3 n=5 返回 5 条", std::to_string(tail.size()));
        bool asc = true;
        for (size_t i = 1; i < tail.size(); ++i)
            if (tail[i].seq <= tail[i - 1].seq) asc = false;
        ck(asc, "F4 返回按时间（seq）升序，最后一条是最新");
        ck(tail.back().get("i") && *tail.back().get("i") == "119", "F5 最后一条确实是最新事件",
           tail.back().get("i") ? *tail.back().get("i") : "null");
        ck(tail.front().seq == 116, "F6 最近 5 条正好是 seq 116..120",
           std::to_string(tail.front().seq));

        const auto all = log.recent(100000, &skipped);
        ck(!all.empty() && all.size() < 120, "F7 n>总数：返回全部保留事件（轮转后 <120）",
           std::to_string(all.size()));
        ck(all.back().seq == 120, "F8 轮转后仍能读到最新一条", std::to_string(all.back().seq));

        // 往当前文件追加一行坏数据：不得崩溃、必须被计数跳过
        {
            std::ofstream f(dir + "/events.jsonl", std::ios::app | std::ios::binary);
            f << "{not json at all\n";
        }
        size_t sk2 = 0;
        const auto after = log.recent(3, &sk2);
        ck(after.size() == 3, "F9 损坏行之后仍能读到 3 条");
        ck(sk2 == 1, "F10 损坏行被跳过并计数", std::to_string(sk2));
    }

    // ---------------------------------------------------------------- G（错误码表）
    std::printf("\n-- G. 错误码表：唯一 / 稳定 / 与阶段一致 --\n");
    {
        ck(rta::diag::kErrorCodeTableVersion == 2,
           "G1 码表版本号 2（改码表必须显式升版本并同步本测试）",
           std::to_string(rta::diag::kErrorCodeTableVersion));
        bool uniqueId = true, uniqueCode = true, prefixOk = true, zhOk = true;
        for (size_t i = 0; i < rta::diag::kErrorCodeCount; ++i) {
            const auto& a = rta::diag::kErrorCodes[i];
            if (!a.zh || !*a.zh) zhOk = false;
            const std::string pref = std::string(rta::diag::stage_name(a.stage)) + ".";
            if (std::string(a.code).rfind(pref, 0) != 0) {
                prefixOk = false;
                std::printf("  前缀不符: %s vs %s\n", a.code, pref.c_str());
            }
            for (size_t j = i + 1; j < rta::diag::kErrorCodeCount; ++j) {
                if (a.id == rta::diag::kErrorCodes[j].id) uniqueId = false;
                if (std::string(a.code) == rta::diag::kErrorCodes[j].code) uniqueCode = false;
            }
        }
        ck(uniqueId, "G2 id 唯一");
        ck(uniqueCode, "G3 code 字符串唯一");
        ck(prefixOk, "G4 code 前缀与 stage 名一致（界面可只按前缀分组）");
        ck(zhOk, "G5 每条都有中文说明");
        ck(rta::diag::kErrorCodeCount >= 30, "G6 覆盖 8 类场景所需码数",
           std::to_string(rta::diag::kErrorCodeCount));

        const auto* c = rta::diag::find_code("decode.truncated_flac");
        ck(c && c->id == 10 && c->stage == rta::diag::Stage::Decode,
           "G7 冻结映射：decode.truncated_flac = id 10 / Stage::Decode");
        const auto* c2 = rta::diag::find_code("io.underrun");
        ck(c2 && c2->stage == rta::diag::Stage::Io, "G8 io.underrun 归 io 阶段");
        const auto* c3 = rta::diag::find_code_by_id(70);
        ck(c3 && std::string(c3->code) == "upnp.no_renderer",
           "G9 id 70 → upnp.no_renderer（按 id 查询稳定）");
        ck(rta::diag::find_code("nope.never") == nullptr, "G10 未知码返回 nullptr，不猜");
        ck(std::string(rta::diag::zh_of("meta.timeout")) != "", "G11 中文说明可查");

        bool stageRound = true;
        for (int i = 0; i < rta::diag::kStageCount; ++i) {
            const auto s = (rta::diag::Stage)i;
            bool ok = false;
            if (rta::diag::stage_from_name(rta::diag::stage_name(s), &ok) != s || !ok)
                stageRound = false;
        }
        ck(stageRound, "G12 stage 名 ↔ 枚举双向往返");
    }

    // ---------------------------------------------------------------- H（不误伤）
    std::printf("\n-- H. 不误伤：正常事件内容原样保留 --\n");
    {
        rta::diag::Event e;
        e.evt = "track.open";
        e.stage = "decode";
        e.str("title", "Token Ring Song");
        e.str("path", "/Volumes/MUSIC/Album/01.flac");
        e.num("rate", 96000);
        e.str("format", "flac");
        rta::diag::RedactReport rep;
        rta::diag::redact_event(e, &rep);
        ck_eq(e.get("title") ? *e.get("title") : "", "Token Ring Song",
              "H1 曲名里的 Token 不被当凭据");
        ck_eq(e.get("path") ? *e.get("path") : "", "/Volumes/MUSIC/Album/01.flac",
              "H2 曲库路径（无用户名）原样保留");
        ck_eq(e.get("format") ? *e.get("format") : "", "flac", "H3 普通值原样保留");
        ck(rep.total() == 0, "H4 正常事件不产生任何脱敏计数",
           std::to_string(rep.total()));

        // 长值：不是歌词键，但也不许整段落盘（截断并留下长度证据）
        rta::diag::Event big;
        big.evt = "llm.raw";
        big.stage = "llm";
        big.str("msg", std::string(4000, 'z'));
        rta::diag::RedactReport rep2;
        rta::diag::redact_event(big, &rep2);
        const std::string v = big.get("msg") ? *big.get("msg") : "";
        ck(v.size() <= rta::diag::kMaxValueChars + 64, "H5 超长值被截断",
           std::to_string(v.size()));
        ck_has(v, "<truncated", "H5b 截断处有显式标记");
        ck(rep2.truncated >= 1, "H6 截断被计数");
    }

    // ---------------------------------------------------------------- I（兼容既有前缀）
    std::printf("\n-- I. 保留既有播放日志前缀（D1 硬要求）--\n");
    {
        rta::diag::Event e;
        e.ts = 1750000000123LL;
        e.evt = "play.start";
        e.stage = "io";
        e.code = "io.open_failed";
        e.rid = "req-9";
        e.num("rate", 44100);
        const std::string line = rta::diag::legacy_prefix_line(e);
        std::printf("  镜像行: %s\n", line.c_str());
        // 前缀必须与 tools/rtaweb.cpp play_log() 一致：YYYY-MM-DD HH:MM:SS.mmm + 空格
        const std::string prefix = line.substr(0, 24);
        bool shapeOk = prefix.size() == 24 && prefix[4] == '-' && prefix[7] == '-' &&
                       prefix[10] == ' ' && prefix[13] == ':' && prefix[16] == ':' &&
                       prefix[19] == '.' && prefix[23] == ' ';
        ck(shapeOk, "I1 时间戳前缀形态与既有播放日志一致（24 字符）", prefix);
        ck(has(line, " play.start "), "I2 事件名紧跟前缀", line);
        ck(has(line, " stage=io"), "I3 阶段可 grep", line);
        ck(has(line, " code=io.open_failed"), "I4 错误码可 grep", line);
        ck(has(line, " rid=req-9"), "I5 rid 可 grep", line);
        ck(has(line, " rate=44100"), "I6 kv 用 k=v 形态，老脚本不用改", line);
        ck(line.find('\n') == std::string::npos, "I7 单行输出（可直接交给 play_log）");
    }

    // ---------------------------------------------------------------- J（非字符串值脱敏后类型自适应）
    std::printf("\n-- J. 非字符串脱敏转 KvKind::Str 规避非法 JSON --\n");
    {
        const std::string dir = fresh_dir("redact_types");
        rta::diag::EventLog log({dir, "events.jsonl", 8ull << 20, 3, true});
        std::string err;
        ck(log.open(&err), "J0 打开事件日志", err);
        log.set_sid("sess-types-1");

        rta::diag::Event e;
        e.evt = "llm.config";
        e.set_stage(rta::diag::Stage::Llm);
        e.num("token", 1234567890123456LL);      // 数值型凭据键名 -> 脱敏为 "<redacted>"
        e.boolean("body", true);                 // 布尔型正文键名 -> 脱敏为 "<redacted:body len=4>"
        e.num("lyrics", 999);                    // 数值型歌词键名 -> 脱敏为 "<redacted:lyrics len=3>"
        e.num("rate", 44100);                    // 正常数值，不应改动类型
        e.boolean("ok", true);                   // 正常布尔，不应改动类型

        ck(log.write(e), "J1 写入成功");
        log.close();

        // 读回磁盘上的原始 JSON 行，验证是合法 JSON，且类型自适应为引号字符串
        const std::string disk = read_file(dir + "/events.jsonl");
        const std::string line = disk.substr(0, disk.find('\n'));
        ck_has(line, "\"token\":\"<redacted>\"", "J2 token 字段带引号（合法字符串类型）");
        ck_has(line, "\"body\":\"<redacted:body len=4>\"", "J3 body 字段带引号");
        ck_has(line, "\"lyrics\":\"<redacted:lyrics len=3>\"", "J4 lyrics 字段带引号");
        ck_has(line, "\"rate\":44100", "J5 未脱敏的 rate 仍是原生数字");
        ck_has(line, "\"ok\":true", "J6 未脱敏的 ok 仍是原生布尔");

        // 读回验证：反序列化成功且 skipped_lines == 0
        std::size_t skipped = 0;
        const auto rec = log.recent(10, &skipped);
        ck(rec.size() == 1, "J7 读回 1 条事件", std::to_string(rec.size()));
        ck(skipped == 0, "J8 skipped_lines 为 0（没有因非法 JSON 导致损坏跳过）",
           std::to_string(skipped));
        if (!rec.empty()) {
            ck(rec[0].get("token") && *rec[0].get("token") == "<redacted>", "J9 读回 token 为 <redacted>");
            ck(rec[0].get("rate") && *rec[0].get("rate") == "44100", "J10 读回 rate 为 44100");
            ck(rec[0].get("ok") && *rec[0].get("ok") == "true", "J11 读回 ok 为 true");
        }
    }

    // ---------------------------------------------------------------- K（diag_start/diag_stop 与单例状态）
    std::printf("\n-- K. diag_start/diag_stop 禁用、失败与非单例不重开 --\n");
    {
        const std::string dir = fresh_dir("lifecycle");
        rta::diag::DiagConfig cfg;
        cfg.dir = dir;
        cfg.app_version = "1.1.1-test";
        cfg.enabled = true;

        auto st = rta::diag::diag_start(cfg);
        ck(st.ok, "K1 diag_start 启动成功", st.error);
        ck(rta::diag::diag_active(), "K2 diag_active() 为 true");

        rta::diag::Event e1;
        e1.evt = "test.active";
        e1.stage = "io";
        ck(rta::diag::diag_emit(e1), "K3 启动期间 diag_emit 成功");

        // diag_stop 停止会话
        rta::diag::diag_stop("user_quit");
        ck(!rta::diag::diag_active(), "K4 diag_stop 后 diag_active() 为 false");

        // 停止后调用 diag_emit，不应重新打开 EventLog，不应写无 marker 记录，且返回 false
        rta::diag::Event e2;
        e2.evt = "test.after_stop";
        e2.stage = "io";
        bool emit_res = rta::diag::diag_emit(e2);
        ck(!emit_res, "K5 stop 之后 diag_emit 返回 false，不静默自开");
        ck(!rta::diag::event_log().is_open(), "K6 stop 之后 EventLog 仍处于关闭状态");

        // 测试 diag_start 在 marker 写失败时不可返回 ok=true
        rta::diag::DiagConfig bad_cfg;
        bad_cfg.dir = "/dev/null/impossible_dir";
        bad_cfg.enabled = true;
        auto bad_st = rta::diag::diag_start(bad_cfg);
        ck(!bad_st.ok, "K7 目录不可写时 diag_start 返回 ok=false");
        ck(!bad_st.error.empty(), "K8 错误信息非空", bad_st.error);
        ck(!rta::diag::diag_active(), "K9 失败时 diag_active() 保持 false");
    }

    // 清理：只删本进程自己造的那些目录（名字带 pid，绝不触及真实用户目录）
    for (const auto& d : g_dirs) {
        std::error_code ec;
        std::filesystem::remove_all(d, ec);
    }

    std::printf("\n== 结果: %d passed, %d failed ==\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
