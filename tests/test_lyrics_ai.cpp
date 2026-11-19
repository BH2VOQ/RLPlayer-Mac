// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_lyrics_ai.cpp — 歌词 AI（翻译 / 音译 / 假名 / 繁体）离线单测
//
// 移植自上游 v3.3.11 tests/test_lyrics_ai.cpp，判据按本分支任务书加固：
//   ① 行数守恒：40 行日文（含空行）⟹ 输出行数 == 输入、空行仍空；
//   ② finish_reason=length 不交付半首 ⟹ 稳定错误码 lyrics_ai.length_truncated；
//   ③ 行数不守恒 ⟹ lyrics_ai.line_mismatch；
//   ④ 没 key ⟹ lyrics_ai.no_key（不发请求、不崩、不静默）；
//   ⑤ LRC 时间戳前缀逐字节保留，只换文本。
// 全程不联网：假 LLM 走 cfg.transport 钩子（计数器是"没发请求"的唯一证据）。
#include "meta/lyrics_ai.h"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>
#include <unistd.h>

using namespace rta::meta;
namespace fs = std::filesystem;

static int g_pass = 0;
static int g_fail = 0;

static void ck(bool cond, const std::string& what, const std::string& detail = std::string()) {
    if (cond) {
        ++g_pass;
        std::printf("  [PASS] %s\n", what.c_str());
    } else {
        ++g_fail;
        std::printf("  [FAIL] %s%s%s\n", what.c_str(), detail.empty() ? "" : "  |  ", detail.c_str());
    }
}

static std::string json_array(const std::vector<std::string>& v) {
    std::string s = "[";
    for (size_t i = 0; i < v.size(); ++i) {
        if (i) s += ',';
        s += '"';
        s += llm_esc(v[i]);
        s += '"';
    }
    s += ']';
    return s;
}

// ---------------------------------------------------------------------------
// 假 LLM：从请求体里解析"送检行"（编号列表），再按模式生成答复。
// 这样断言是"模型拿到几行、回了什么"，不是"看起来没报错"。
// ---------------------------------------------------------------------------
struct FakeLlm {
    int calls = 0;
    std::string finish = "stop";
    int status = 200;                       // 0 = 模拟网络底层失败
    int totalTokens = 128;
    std::string lastBody;
    std::vector<std::string> lastPayload;   // 本次送检的非空行（按编号顺序）
    std::vector<int> maxTokensPerCall;
    std::vector<size_t> payloadPerCall;
    std::string mode = "furigana";          // furigana | echo | short | fixed
    std::vector<std::string> fixedReply;

    void parse_request(const std::string& body) {
        lastPayload.clear();
        lastBody = body;
        const size_t mt = body.find("\"max_tokens\":");
        if (mt != std::string::npos) {
            maxTokensPerCall.push_back(std::atoi(body.c_str() + mt + 13));
        }
        // user 里的编号列表被 llm_esc 转义成 "\n<号>. 文本"（反斜杠 + n 两个字符）
        size_t pos = 0;
        while ((pos = body.find("\\n", pos)) != std::string::npos) {
            const size_t q = pos + 2;
            size_t d = q;
            while (d < body.size() && body[d] >= '0' && body[d] <= '9') ++d;
            if (d > q && d + 1 < body.size() && body[d] == '.' && body[d + 1] == ' ') {
                const size_t st = d + 2;
                size_t en = body.find("\\n", st);
                if (en == std::string::npos) en = body.size();
                lastPayload.push_back(body.substr(st, en - st));
                pos = en;
            } else {
                pos = q;
            }
        }
        payloadPerCall.push_back(lastPayload.size());
    }

    std::vector<std::string> build_reply() const {
        std::vector<std::string> out;
        for (const std::string& p : lastPayload) {
            if (mode == "echo") {
                out.push_back("译:" + p);
                continue;
            }
            // 假名模式：把「漢字」标成「漢字(かんじ)」，其余行尾部加一个注音
            const size_t at = p.find("漢字");
            if (at != std::string::npos) {
                std::string s = p;
                s.replace(at, 2, "漢字(かんじ)");
                out.push_back(s);
            } else {
                out.push_back(p + "(かんじ)");
            }
        }
        return out;
    }

    rta::net::HttpResponse operator()(const std::string& url, const std::string& body,
                                      const std::vector<std::string>& headers) {
        ++calls;
        (void)url;
        (void)headers;
        parse_request(body);

        rta::net::HttpResponse r;
        if (status == 0) {
            r.status = 0;
            r.error = "模拟网络失败";
            return r;
        }
        r.status = status;
        r.ok = (status >= 200 && status < 300);
        std::string json;
        if (r.ok) {
            std::vector<std::string> out;
            if (mode == "fixed") {
                out = fixedReply;
            } else if (mode == "short") {
                out = build_reply();
                if (!out.empty()) out.pop_back();   // 少一行：行数不守恒
            } else {
                out = build_reply();
            }
            json = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"" +
                   llm_esc(json_array(out)) + "\"},\"finish_reason\":\"" + finish +
                   "\"}],\"usage\":{\"total_tokens\":" + std::to_string(totalTokens) + "}}";
        } else {
            json = "{\"error\":{\"message\":\"boom\"}}";
        }
        r.body.assign(json.begin(), json.end());
        return r;
    }
};

static LlmConfig make_cfg(FakeLlm& f, const std::string& tmp) {
    LlmConfig c;
    c.baseUrl = "http://127.0.0.1:9";        // 不会被真的访问：transport 已接管
    c.apiKey = "sk-test-offline";
    c.model = "deepseek-flash";
    c.usagePath = tmp + "/llm-usage.json";   // 别把用量写到仓库目录
    c.transport = [&f](const std::string& u, const std::string& b,
                       const std::vector<std::string>& h) { return f(u, b, h); };
    return c;
}

int main() {
    const fs::path tmpPath = fs::temp_directory_path() / ("rlp-test-lyrics-ai-" + std::to_string((long)::getpid()));
    std::error_code ec;
    fs::remove_all(tmpPath, ec);
    fs::create_directories(tmpPath, ec);
    const std::string tmp = tmpPath.string();
    std::printf("临时目录：%s\n", tmp.c_str());

    FakeLlm f;
    const LlmConfig cfg = make_cfg(f, tmp);
    const std::string cacheDir = tmp + "/cache";

    // ---------------- 1) 40 行日文（含空行）假名标注 ----------------
    std::printf("\n-- 1) 40 行日文 Furigana：行数守恒 / 空行保留 / 漢字(かんじ)\n");
    std::vector<std::string> ja40;
    for (int i = 0; i < 40; ++i) {
        if (i % 6 == 0) ja40.push_back("");                    // 空行（7 个）
        else if (i == 7) ja40.push_back("漢字");                // 汉字行
        else if (i == 9) ja40.push_back("   ");                // 纯空白也算空行
        else ja40.push_back("日文行" + std::to_string(i));
    }
    {
        f.calls = 0; f.maxTokensPerCall.clear(); f.payloadPerCall.clear();
        const LyricsAiResult r1 = lyrics_ai_process_all(cfg, LyricsAiTask::Furigana, ja40, "ja", "", cacheDir);
        ck(r1.ok, "ok=true", r1.error);
        ck(r1.lines.size() == ja40.size(), "输出行数 == 输入行数（40）",
           std::to_string(r1.lines.size()));
        bool blanksOk = true;
        for (size_t i = 0; i < ja40.size(); ++i) {
            if (llm_trim(ja40[i]).empty() && !llm_trim(r1.lines[i]).empty()) blanksOk = false;
        }
        ck(blanksOk, "空行 / 纯空白行的位置仍为空");
        ck(r1.lines[7].find("漢字(かんじ)") != std::string::npos,
           "汉字行出现「漢字(かんじ)」", r1.lines.size() > 7 ? r1.lines[7] : std::string());
        ck(f.calls == 3, "40 行按 14 行/块切 ⟹ 3 次调用", std::to_string(f.calls));
        bool chunkOk = true;
        for (size_t n : f.payloadPerCall) if (n > 14) chunkOk = false;
        ck(chunkOk, "每块送检行不超过 14（重任务）", std::to_string(f.payloadPerCall.size()));
        ck(!r1.fromCache, "首次 fromCache=false");

        // 14 行连续正文 ⟹ 重任务预算 800 + 500*14 = 7800
        std::vector<std::string> fourteen;
        for (int i = 0; i < 14; ++i) fourteen.push_back("行" + std::to_string(i));
        f.calls = 0; f.maxTokensPerCall.clear(); f.payloadPerCall.clear();
        const LyricsAiResult r14 = lyrics_ai_process_all(cfg, LyricsAiTask::Furigana, fourteen, "ja", "", "");
        ck(r14.ok, "14 行 ok", r14.error);
        ck(f.payloadPerCall.size() == 1 && f.payloadPerCall[0] == 14, "14 行走 1 次调用",
           std::to_string(f.payloadPerCall.size()));
        ck(f.maxTokensPerCall.size() == 1 && f.maxTokensPerCall[0] == 7800,
           "重任务预算 800 + 500*14 = 7800",
           f.maxTokensPerCall.empty() ? std::string() : std::to_string(f.maxTokensPerCall[0]));

        // 轻任务（翻译）：20 行/块，300/行 + 800
        std::vector<std::string> zh20;
        for (int i = 0; i < 20; ++i) zh20.push_back("中文行" + std::to_string(i));
        f.calls = 0; f.maxTokensPerCall.clear(); f.payloadPerCall.clear();
        f.mode = "echo";
        const LyricsAiResult rz = lyrics_ai_process_all(cfg, LyricsAiTask::Translate, zh20, "ja", "zh", "");
        ck(rz.ok, "20 行翻译 ok", rz.error);
        ck(rz.lines.size() == 20, "翻译行数守恒（20）", std::to_string(rz.lines.size()));
        ck(f.maxTokensPerCall.size() == 1 && f.maxTokensPerCall[0] == 6800,
           "轻任务预算 300*20 + 800 = 6800",
           f.maxTokensPerCall.empty() ? std::string() : std::to_string(f.maxTokensPerCall[0]));
        f.mode = "furigana";

        // 缓存命中：同输入第二次不再发请求（断网也能命中）
        f.calls = 0;
        const LyricsAiResult r2 = lyrics_ai_process_all(cfg, LyricsAiTask::Furigana, ja40, "ja", "", cacheDir);
        ck(r2.ok && r2.fromCache, "第二次 fromCache=true", r2.error);
        ck(f.calls == 0, "命中缓存不发 HTTP", std::to_string(f.calls));
        ck(r2.lines == r1.lines, "缓存结果与首次一致");
        const int savedStatus = f.status;
        f.status = 0;                          // 模拟断网：仍然只能命中缓存
        const LyricsAiResult r3 = lyrics_ai_process_all(cfg, LyricsAiTask::Furigana, ja40, "ja", "", cacheDir);
        ck(r3.ok && r3.fromCache, "断网（transport 失败）仍命中缓存", r3.error);
        f.status = savedStatus;
    }

    // ---------------- 2) 缓存 key：任务 / 目标语言 / 内容 ----------------
    std::printf("\n-- 2) 缓存 key：任务 + 目标语言 + 内容\n");
    {
        const std::string k = lyrics_cache_key(LyricsAiTask::Translate, "ja", "zh", ja40);
        ck(k == lyrics_cache_key(LyricsAiTask::Translate, "ja", "zh", ja40), "同输入同 key");
        ck(k.size() == 16, "16 位十六进制", k);
        bool hex = true;
        for (char ch : k) if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'))) hex = false;
        ck(hex, "只含 0-9a-f", k);
        ck(lyrics_cache_key(LyricsAiTask::Furigana, "ja", "zh", ja40) != k, "任务不同 ⟹ key 不同");
        ck(lyrics_cache_key(LyricsAiTask::Translate, "ja", "en", ja40) != k, "目标语言不同 ⟹ key 不同");
        ck(lyrics_cache_key(LyricsAiTask::Translate, "en", "zh", ja40) != k, "源语言不同 ⟹ key 不同");
        std::vector<std::string> changed = ja40;
        changed[1] = "改一行";
        ck(lyrics_cache_key(LyricsAiTask::Translate, "ja", "zh", changed) != k, "内容不同 ⟹ key 不同");
        ck(lyrics_cache_key(LyricsAiTask::Translate, "JA", "ZH", ja40) == k, "语言码大小写归一");
        const std::vector<std::string> a1 = {"ab", "c"};
        const std::vector<std::string> a2 = {"a", "bc"};
        ck(lyrics_cache_key(LyricsAiTask::Translate, "ja", "zh", a1) !=
           lyrics_cache_key(LyricsAiTask::Translate, "ja", "zh", a2), "行边界不歧义");
    }

    // ---------------- 3) finish_reason=length：不交付半首 ----------------
    std::printf("\n-- 3) 截断（finish_reason=length）⟹ lyrics_ai.length_truncated\n");
    {
        f.finish = "length";
        const std::vector<std::string> two = {"夜に駆ける", "沈むように"};
        const LyricsAiResult r = lyrics_ai_process(cfg, LyricsAiTask::Furigana, two, "ja", "", "");
        ck(!r.ok, "ok=false");
        ck(r.code == kLyricsAiErrTruncated, "错误码 lyrics_ai.length_truncated", r.code);
        ck(r.lines.empty(), "不返回半首（lines 为空）", std::to_string(r.lines.size()));
        // 分块场景同理：任何一块被截断 ⟹ 整体失败，绝不拼接半首歌
        const LyricsAiResult ra = lyrics_ai_process_all(cfg, LyricsAiTask::Furigana, ja40, "ja", "", "");
        ck(!ra.ok && ra.code == kLyricsAiErrTruncated, "分块中有一块截断 ⟹ 整体失败", ra.code);
        ck(ra.lines.empty(), "分块截断不返回任何行", std::to_string(ra.lines.size()));
        f.finish = "stop";
    }

    // ---------------- 4) 行数不守恒 ⟹ lyrics_ai.line_mismatch ----------------
    std::printf("\n-- 4) 行数不守恒 ⟹ lyrics_ai.line_mismatch\n");
    {
        f.mode = "short";
        const std::vector<std::string> three = {"a", "b", "c"};
        const LyricsAiResult r = lyrics_ai_process(cfg, LyricsAiTask::Translate, three, "ja", "zh", "");
        ck(!r.ok, "ok=false");
        ck(r.code == kLyricsAiErrLineMismatch, "错误码 lyrics_ai.line_mismatch", r.code);
        ck(r.lines.empty(), "不返回错位结果", std::to_string(r.lines.size()));
        f.mode = "furigana";
    }

    // ---------------- 5) 没 key ⟹ lyrics_ai.no_key ----------------
    std::printf("\n-- 5) 没 key：快速失败、不发请求\n");
    {
        LlmConfig c = cfg;
        c.apiKey.clear();
        f.calls = 0;
        const LyricsAiResult r = lyrics_ai_process(c, LyricsAiTask::Translate, ja40, "ja", "zh");
        ck(!r.ok, "ok=false");
        ck(r.code == kLyricsAiErrNoKey, "错误码 lyrics_ai.no_key", r.code);
        ck(f.calls == 0, "transport 调用次数 = 0", std::to_string(f.calls));
        ck(r.lines.empty(), "没有结果行");
    }

    // ---------------- 6) LRC 时间戳：只换文本、不动前缀 ----------------
    std::printf("\n-- 6) LRC：时间戳前缀逐字节保留\n");
    {
        const std::string lrc =
            "[ti:夜に駆ける]\n"
            "[00:01.00]夜に駆ける\n"
            "[00:05.00]沈むように\n"
            "\n"
            "[00:09.00]\n";
        const std::vector<LyricsAiLrcLine> parts = lyrics_ai_split_lrc(lrc);
        ck(parts.size() == 6, "物理行数（末行空行也算 1 行）= 6", std::to_string(parts.size()));
        ck(parts[0].prefix == "[ti:夜に駆ける]" && parts[0].text.empty(), "元信息行进前缀、不进正文");
        ck(parts[1].prefix == "[00:01.00]" && parts[1].text == "夜に駆ける", "时间戳与被替换文本分开");
        ck(parts[3].text.empty() && parts[3].prefix.empty(), "空行没有正文");
        ck(parts[4].prefix == "[00:09.00]" && parts[4].text.empty(), "空文本时间戳行保留前缀");

        std::vector<std::string> payload;
        for (const auto& p : parts) if (!llm_trim(p.text).empty()) payload.push_back(p.text);
        ck(payload.size() == 2, "只送 2 个正文行", std::to_string(payload.size()));

        f.calls = 0; f.mode = "echo";
        const LyricsAiResult rr = lyrics_ai_process(cfg, LyricsAiTask::Translate, payload, "ja", "zh", "");
        ck(rr.ok && rr.lines.size() == 2, "正文翻译 ok", rr.error);
        const std::vector<std::string> joined = lyrics_ai_apply_lrc(parts, rr.lines);
        ck(joined.size() == parts.size(), "回填后行数守恒（6）", std::to_string(joined.size()));
        ck(joined[0] == "[ti:夜に駆ける]", "元信息行原样保留", joined.size() > 0 ? joined[0] : std::string());
        ck(joined[1].rfind("[00:01.00]", 0) == 0, "译文行保留 [00:01.00] 前缀",
           joined.size() > 1 ? joined[1] : std::string());
        ck(joined[1].find("译:夜に駆ける") != std::string::npos, "前缀之后是译文",
           joined.size() > 1 ? joined[1] : std::string());
        ck(joined[3].empty(), "空行仍是空行", joined.size() > 3 ? joined[3] : std::string());
        ck(joined[4] == "[00:09.00]", "空文本时间戳行原样保留",
           joined.size() > 4 ? joined[4] : std::string());
        ck(!joined[1].empty() && joined[1].substr(0, 10) == "[00:01.00]", "前缀逐字节相同（10 字节）");
        f.mode = "furigana";

        // 行数不守恒的回填必须拒绝，而不是悄悄错位
        std::vector<std::string> wrong = rr.lines;
        wrong.pop_back();
        ck(lyrics_ai_apply_lrc(parts, wrong).empty(), "回填行数不符 ⟹ 返回空（拒绝错位）");
    }

    // ---------------- 7) 全空行：不调模型 ----------------
    std::printf("\n-- 7) 全空行输入：不调模型\n");
    {
        const std::vector<std::string> blanks = {"", "   ", "\t"};
        f.calls = 0;
        const LyricsAiResult r = lyrics_ai_process(cfg, LyricsAiTask::Translate, blanks, "ja", "zh", "");
        ck(r.ok, "ok=true", r.error);
        ck(r.lines.size() == blanks.size() && r.lines[0].empty() && r.lines[2].empty(), "输出仍是空行");
        ck(f.calls == 0, "没有发起 HTTP", std::to_string(f.calls));
    }

    // ---------------- 8) 缓存往返 / 损坏自愈 ----------------
    std::printf("\n-- 8) 缓存文件：往返一致 / 损坏即删\n");
    {
        LyricsAiResult good;
        good.ok = true; good.tokens = 7;
        good.lines = {"he said \"hi\"", "back\\slash", "tab\there", ""};
        ck(lyrics_cache_save(cacheDir, "aaaaaaaaaaaaaaaa", good), "特殊字符结果可写缓存");
        LyricsAiResult got;
        ck(lyrics_cache_load(cacheDir, "aaaaaaaaaaaaaaaa", got), "可读回");
        ck(got.lines == good.lines, "引号/反斜杠/制表符/空串逐字节一致");
        ck(got.fromCache && got.tokens == 7, "load 置 fromCache 且 tokens 保留");

        LyricsAiResult failed;
        failed.error = "网络失败";
        ck(!lyrics_cache_save(cacheDir, "deadbeefdeadbeef", failed), "失败结果不写缓存");
        ck(!lyrics_cache_load("", "aaaaaaaaaaaaaaaa", got), "dir 为空 ⟹ load=false");
        ck(!lyrics_cache_save("", "aaaaaaaaaaaaaaaa", good), "dir 为空 ⟹ save=false");

        const std::string badDir = tmp + "/cache-bad";
        fs::create_directories(lyrics_ai_u8path(badDir), ec);
        const fs::path badFile = lyrics_ai_cache_file(badDir, "0123456789abcdef");
        {
            std::ofstream o(badFile, std::ios::binary | std::ios::trunc);
            o << "{\"v\":1,\"lines\":[\"a\",\"b\"";
        }
        ck(!lyrics_cache_load(badDir, "0123456789abcdef", got), "截断文件 load=false");
        ck(!fs::exists(badFile, ec), "截断文件已被删除");
        {
            std::ofstream o(badFile, std::ios::binary | std::ios::trunc);
            o << "{\"v\":999,\"lines\":[\"a\"]}";
        }
        ck(!lyrics_cache_load(badDir, "0123456789abcdef", got), "版本不符 load=false");
        ck(!fs::exists(badFile, ec), "版本不符的文件也被删除");
    }

    // ---------------- 9) HTTP 失败 / 任务解析 ----------------
    std::printf("\n-- 9) HTTP 失败与任务解析\n");
    {
        f.status = 500;
        const std::vector<std::string> two = {"a", "b"};
        const LyricsAiResult r = lyrics_ai_process(cfg, LyricsAiTask::Translate, two, "ja", "zh", "");
        ck(!r.ok && r.code == kLyricsAiErrLlm, "HTTP 500 ⟹ lyrics_ai.llm_error", r.code);
        ck(r.error.find("500") != std::string::npos, "error 里有状态码", r.error);
        f.status = 200;

        LyricsAiTask t = LyricsAiTask::Translate;
        ck(lyrics_ai_parse_task("furigana", t) && t == LyricsAiTask::Furigana, "task=furigana");
        ck(lyrics_ai_parse_task("translit", t) && t == LyricsAiTask::Transliterate, "task=translit");
        ck(lyrics_ai_parse_task("trad", t) && t == LyricsAiTask::TradChinese, "task=trad");
        ck(lyrics_ai_parse_task("translate", t) && t == LyricsAiTask::Translate, "task=translate");
        ck(!lyrics_ai_parse_task("bogus", t), "非法 task 被拒");
        ck(lyrics_ai_task_tag(LyricsAiTask::Furigana) == "furigana", "tag=furigana");
        ck(lyrics_ai_task_tag(LyricsAiTask::TradChinese) == "tradchinese", "tag=tradchinese");

        // 翻译任务缺目标语言：不发请求
        f.calls = 0;
        const LyricsAiResult nol = lyrics_ai_process(cfg, LyricsAiTask::Translate, two, "ja", "");
        ck(!nol.ok && f.calls == 0, "翻译缺目标语言 ⟹ 不发请求", nol.error);
    }

    // ---------------- 10) 回显原文清理（翻译/繁体专用） ----------------
    std::printf("\n-- 10) 模型把原文和译文写在同一行时剥掉原文前缀\n");
    {
        ck(lyrics_strip_echoed_source("夜に駆ける", "夜に駆ける 向着夜晚奔跑") == "向着夜晚奔跑",
           "空格分隔的原句被剥掉");
        ck(lyrics_strip_echoed_source("夜に駆ける", "夜に駆ける — 向着夜晚奔跑") == "向着夜晚奔跑",
           "破折号分隔也被剥掉");
        ck(lyrics_strip_echoed_source("abc", "abc") == "abc", "只有原文 ⟹ 保留原样");
        ck(lyrics_strip_echoed_source("abc", "123") == "123", "没有原文前缀 ⟹ 原样返回");
    }

    fs::remove_all(tmpPath, ec);
    std::printf("\n== 结束：%s（断言 %d 项，PASS %d / FAIL %d）==\n",
                g_fail == 0 ? "全部通过" : "有失败", g_pass + g_fail, g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
