// SPDX-FileCopyrightText: 2026 rainlain <https://github.com/okhuoyanyan>
// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// lyrics_ai.h — 歌词 AI 处理（翻译 / 音译 / 日语假名标注 / 简体转繁体）
//
// 移植来源：上游 Windows 分支 v3.3.11 src/meta/lyrics_ai.h（同一模块、同一组硬约束）。
// mac 侧差异只有三处，都写在对应函数上：
//   ① 错误改成稳定错误码（lyrics_ai.no_key / .length_truncated / .line_mismatch ...），
//      上游只回中文句子，界面无法据此分支；
//   ② 增加 LRC 前缀保留（时间戳只换文本、不动 [mm:ss.xx]），并支持整段 LRC 直接进来；
//   ③ 分块调用在本模块内完成（lyrics_ai_process_all），不再由 rtaweb 手写循环。
//
// 三条硬约束（tests/test_lyrics_ai.cpp 逐条锁死）：
//   ① 行数守恒：界面按行号把结果贴回原文，少一行就是整首歌错位；
//   ② 空行保留：模型几乎总会吞掉空行，所以只送非空行、回来按原下标插回；
//   ③ 截断不交付：finish_reason=="length" 时宁可报错也不返回半首歌
//      （半首歌贴上去，用户会以为歌词本来就这么短，比报错更难发现）。
//
// 缓存目录不在这里拼：本模块不知道进程装在哪（rtaweb 与单测的工作目录不同），
// 目录一律由调用方传入，传空串 = 不缓存。
#pragma once
#include "meta/llm.h"    // LlmConfig / LlmMessage / LlmReply / llm_chat / llm_esc / llm_trim
#include "net/json.h"    // json_parse（本分支的极简解析器；上游用的是 json_parse_strict）

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <mutex>
#include <sstream>
#include <string>
#include <system_error>
#include <vector>

namespace rta::meta {

// ---------------------------------------------------------------------------
// 稳定错误码
//
// 界面要能据此分支（"去设置里填 key" vs "重试" vs "换任务"），所以错误不能只是一句
// 中文。码一旦发布就不能改名 —— 调用方与测试都按字面量断言。
// ---------------------------------------------------------------------------
inline constexpr const char* kLyricsAiErrNoKey       = "lyrics_ai.no_key";
inline constexpr const char* kLyricsAiErrNoLang      = "lyrics_ai.no_lang";
inline constexpr const char* kLyricsAiErrTruncated   = "lyrics_ai.length_truncated";
inline constexpr const char* kLyricsAiErrLineMismatch = "lyrics_ai.line_mismatch";
inline constexpr const char* kLyricsAiErrLlm         = "lyrics_ai.llm_error";
inline constexpr const char* kLyricsAiErrParse       = "lyrics_ai.parse_error";
inline constexpr const char* kLyricsAiErrEmpty       = "lyrics_ai.empty_reply";

// ---------------------------------------------------------------------------
// 任务与结果
// ---------------------------------------------------------------------------

// 枚举值参与缓存 key（见 lyrics_cache_key），只能往后追加：
// 改旧值等于让历史缓存全部对不上号，用户会白花一次钱重算。
enum class LyricsAiTask {
    Translate,      // 翻译成目标语言
    Transliterate,  // 音译（拉丁字母转写：中文→拼音、日文→罗马字、俄文→拉丁）
    Furigana,       // 日语假名标注：给汉字标读音，输出「漢字(かんじ)」这种行内形式
    // 简体 → 繁体。为什么也走大模型而不是内置码表：一简对多繁（发/髮/發、干/乾/幹）
    // 要按词义选字，码表只能给最常见的那一个，歌词里「头发」「发展」会一起变成同一个字。
    // 追加在末尾而不是插在中间：枚举值参与缓存 key，改动旧值会让历史缓存全部失效。
    TradChinese
};

struct LyricsAiResult {
    bool ok = false;
    std::string error;                // 人话（给界面显示）
    std::string code;                 // 稳定错误码（见上面 kLyricsAiErr*）
    std::vector<std::string> lines;   // 与输入逐行对应（行数必须相等）
    int tokens = 0;
    bool fromCache = false;
};

// 每行约 40 token（译文通常比原文长一截）+ 200 余量。
// 上限 8000 是兼容端点的常见单次响应天花板，再大也只会在服务端被截断。
// 2026-10-30 上游实测修正：40/200 在 deepseek-flash 上 3 行就被截断（finish_reason=length，
// max_tokens=320）。真因是这类模型会先吐一段**推理/思考**再给 JSON，思考 token 也计入
// max_tokens ⟹ 预算必须按"每行译文 + 每行可能附带的思考"来估，不能只按译文长度。
// 150 是上游实测能稳定跑完 3~40 行的值；再大就撞 8000 上限。
// 轻任务（翻译 / 繁体）：上游实测 3 行 575 token，但单行请求波动很大（1 行 650 仍被截断），
// 所以按 300/行 + 800 余量给。
inline constexpr int kLyricsAiTokensPerLine = 300;
inline constexpr int kLyricsAiTokenMargin = 800;
// 重任务（假名标注 / 音译）：模型要先逐字判断读音再改写，推理长度远超译文本身。
// 500/行 是上游实测 440 再留一成余量；8000 上限 ⟹ 单块最多 14 行。
inline constexpr int kLyricsAiTokensPerLineHeavy = 500;
inline constexpr int kLyricsAiTokenMarginHeavy = 800;
inline constexpr int kLyricsAiMaxTokens = 8000;
// 分块：轻任务 20 行/块（20*300+800=6800 < 8000），重任务 14 行/块 (14*500+800=7800 < 8000)。
// 注：上游 rtaweb 对重任务实际取的是 8 行（"留足余量"），本分支按任务书口径取 14 ——
// 14 是 token 估算下的上限值；若线上真出现 length 截断，错误码会明确报出来而不是交付半首。
inline constexpr size_t kLyricsAiChunkLines = 20;
inline constexpr size_t kLyricsAiChunkLinesHeavy = 14;
// 缓存格式版本：改提示词或改解析规则时 +1。旧缓存是旧提示词的产物，
// 与当前语义不可互换，宁可删掉重算。
inline constexpr int kLyricsAiCacheVersion = 1;
// 解析失败时回显的原文长度（字节）。200 足够看出模型回了什么，又不至于把日志撑爆。
inline constexpr size_t kLyricsAiSnippetBytes = 200;
// Markdown 代码围栏（三个反引号）。写成常量是因为它本身含有反引号。
inline constexpr const char* kLyricsAiFence = "```";

// ---------------------------------------------------------------------------
// 任务 / 语言 的名字（提示词里给模型看的中文名）
// ---------------------------------------------------------------------------

inline std::string lyrics_ai_task_tag(LyricsAiTask t) {
    switch (t) {
        case LyricsAiTask::Translate:     return "translate";
        case LyricsAiTask::Transliterate: return "transliterate";
        case LyricsAiTask::Furigana:      return "furigana";
        case LyricsAiTask::TradChinese:   return "tradchinese";
    }
    return "unknown";
}

inline std::string lyrics_ai_task_name(LyricsAiTask t) {
    switch (t) {
        case LyricsAiTask::Translate:     return "翻译";
        case LyricsAiTask::Transliterate: return "音译";
        case LyricsAiTask::Furigana:      return "日语假名标注";
        case LyricsAiTask::TradChinese:   return "简体转繁体";
    }
    return "未知任务";
}

// 语言码归一化：只用于比较与拼 key（"ZH" 与 "zh" 是同一门语言，
// 不归一化会让同一首歌在两种写法下各存一份缓存、各花一次钱）。
inline std::string lyrics_ai_norm_lang(const std::string& s) {
    std::string o = llm_trim(s);
    for (char& c : o) {
        if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
    }
    return o;
}

inline std::string lyrics_ai_lang_name(const std::string& code) {
    const std::string c = lyrics_ai_norm_lang(code);
    if (c.empty()) return "自动判断";
    if (c == "zh" || c.rfind("zh-", 0) == 0) return "中文";
    if (c == "ja" || c.rfind("ja-", 0) == 0) return "日语";
    if (c == "en" || c.rfind("en-", 0) == 0) return "英语";
    if (c == "ko" || c.rfind("ko-", 0) == 0) return "韩语";
    if (c == "fr") return "法语";
    if (c == "de") return "德语";
    if (c == "ru") return "俄语";
    if (c == "es") return "西班牙语";
    if (c == "ar") return "阿拉伯语";
    if (c == "it") return "意大利语";
    if (c == "pt") return "葡萄牙语";
    // 表里没有的短码原样交给模型：BCP-47 的组合远多于这张表，模型自己认得。
    return code;
}

// 界面对外接受的任务名：translate / translit / furigana / trad（并容忍上游拼写）。
inline bool lyrics_ai_parse_task(const std::string& raw, LyricsAiTask& out) {
    const std::string t = lyrics_ai_norm_lang(raw);
    if (t.empty() || t == "translate") { out = LyricsAiTask::Translate; return true; }
    if (t == "translit" || t == "transliterate") { out = LyricsAiTask::Transliterate; return true; }
    if (t == "furigana") { out = LyricsAiTask::Furigana; return true; }
    if (t == "trad" || t == "tradchinese" || t == "traditional" || t == "trad_chinese") {
        out = LyricsAiTask::TradChinese;
        return true;
    }
    return false;
}

inline size_t lyrics_ai_chunk_size(LyricsAiTask t) {
    const bool heavy = (t == LyricsAiTask::Furigana || t == LyricsAiTask::Transliterate);
    return heavy ? kLyricsAiChunkLinesHeavy : kLyricsAiChunkLines;
}

// 一行歌词里若混入换行（CUE 合并行、LRC 里塞了两句），编号列表会被拆散，
// 模型就对不上"第 i 行"了 —— 送模型前压成空格。
inline std::string lyrics_ai_flatten(const std::string& s) {
    std::string o = s;
    for (char& c : o) {
        if (c == '\n' || c == '\r' || c == '\t') c = ' ';
    }
    return o;
}

// 按字节截断时退到 UTF-8 字符边界：截在半个汉字上，错误信息本身就是非法 UTF-8，
// 界面显示会变成乱码（这行错误是给人定位用的，不能先坏掉）。
inline std::string lyrics_ai_clip_utf8(const std::string& s, size_t maxBytes) {
    if (s.size() <= maxBytes) return s;
    size_t n = maxBytes;
    while (n > 0 && ((unsigned char)s[n] & 0xC0u) == 0x80u) --n;
    return s.substr(0, n);
}

// 目录/文件名一律按 UTF-8 解释：安装目录/缓存目录可能含中文，
// 窄字符 path 会按 ANSI 代码页解释而打不开。
inline std::filesystem::path lyrics_ai_u8path(const std::string& s) {
#if defined(__cpp_lib_char8_t)
    return std::filesystem::path(std::u8string(s.begin(), s.end()));
#else
    return std::filesystem::u8path(s);
#endif
}

// ---------------------------------------------------------------------------
// 提示词
//
// 格式纪律写进 system、内容与编号列表写进 user：
// 模型对"最后一段用户消息"的服从度最高，把任务描述放在那里，任务相关的偏差最少；
// 而"只输出 JSON"是跨任务的不变量，放 system 才不会被任务描述挤掉。
// ---------------------------------------------------------------------------

inline std::string lyrics_ai_system_prompt(LyricsAiTask task, int n) {
    std::ostringstream o;
    o << "你是歌词处理引擎，只做逐行的机械改写，不创作、不解释。\n"
      << "输出格式（必须严格遵守）：\n"
      << "- 只输出一个 JSON 数组，元素个数必须等于 " << n << "；\n"
      << "- 不要输出任何解释、前言或结语，不要给元素编号，不要使用 Markdown 代码围栏；\n"
      << "- 数组第 i 个元素对应输入的第 i 行，不要合并、拆分、增删或调换顺序；\n"
      << "- 每个元素必须是字符串；输入已剔除空行，所以不要输出空字符串。\n"
      << "任务：" << lyrics_ai_task_name(task) << "。";
    return o.str();
}

inline std::string lyrics_ai_task_instruction(LyricsAiTask task, const std::string& targetLang) {
    switch (task) {
        case LyricsAiTask::Translate:
            return "把每一行歌词翻译成" + lyrics_ai_lang_name(targetLang) +
                   "：保持原意、语气与分行，不要合并或拆分句子，不要添加原文没有的内容。";
        case LyricsAiTask::Transliterate:
            return "把每一行歌词转写成拉丁字母（音译，不翻译语义）：中文转汉语拼音，"
                   "日文转罗马字（Hepburn），俄文转拉丁字母；保留原有标点与语气词。";
        case LyricsAiTask::Furigana:
            return "给每一行歌词里的日语汉字标注平假名读音，写成「漢字(かんじ)」的行内形式；"
                   "假名与拉丁字母原样保留，不要翻译成中文或英文，不要加注释。";
        case LyricsAiTask::TradChinese:
            return "把每一行歌词从简体中文转成繁体中文（台湾/香港通行写法）：只换字形，"
                   "不改词句、不翻译、不改标点；一简对多繁按词义选字（头发→頭髮、发展→發展、"
                   "干净→乾淨）。本来就是繁体的行原样返回。";
    }
    return std::string();
}

inline std::string lyrics_ai_target_desc(LyricsAiTask task, const std::string& targetLang) {
    switch (task) {
        case LyricsAiTask::Translate: {
            const std::string name = lyrics_ai_lang_name(targetLang);
            const std::string code = lyrics_ai_norm_lang(targetLang);
            return (code.empty() || code == name) ? name : name + "（" + code + "）";
        }
        case LyricsAiTask::Transliterate: return "拉丁字母转写（拼音 / 罗马字 / 拉丁化）";
        case LyricsAiTask::Furigana:      return "日语假名（平假名行内注音）";
        case LyricsAiTask::TradChinese:   return "繁体中文（正体字）";
    }
    return targetLang;
}

inline std::string lyrics_ai_user_prompt(LyricsAiTask task, const std::vector<std::string>& payload,
                                         const std::string& sourceLang, const std::string& targetLang) {
    std::ostringstream o;
    o << "任务：" << lyrics_ai_task_instruction(task, targetLang) << "\n";
    o << "源语言：" << lyrics_ai_lang_name(sourceLang) << "\n";
    o << "目标语言：" << lyrics_ai_target_desc(task, targetLang) << "\n";
    o << "共 " << payload.size() << " 行（编号只为对齐，输出里不要带编号）：\n";
    for (size_t i = 0; i < payload.size(); ++i) {
        o << (i + 1) << ". " << lyrics_ai_flatten(payload[i]) << "\n";
    }
    o << "请输出 JSON 数组，共 " << payload.size() << " 个元素。";
    return o.str();
}

// 逐字段赋值而不是聚合初始化：LlmMessage 只有 role/content 两个字段，
// 聚合写法一旦将来加字段就会触发 -Wmissing-field-initializers。
inline LlmMessage lyrics_ai_message(const char* role, const std::string& content) {
    LlmMessage m;
    m.role = role;
    m.content = content;
    return m;
}

// ---------------------------------------------------------------------------
// 响应解析（容错但不将就）
// ---------------------------------------------------------------------------

// 顶层是不是"看起来像 JSON 容器"。本分支的 net/json.h 解析器很宽容（会接受前缀、
// 忽略尾随垃圾），所以先用首字符过滤掉"好的，这是结果……"这类纯文本，避免把
// 人类叙述误判成解析成功。
inline bool lyrics_ai_looks_like_json(const std::string& t) {
    const std::string s = llm_trim(t);
    return !s.empty() && (s[0] == '[' || s[0] == '{');
}

// 括号/引号配平：本分支的 net/json.h 是**宽容**解析器（前缀能解析、尾随垃圾忽略），
// 截断的半截 JSON 也会"解析成功"（{"v":1,"lines":["a","b" 就能得到 lines=["a","b"]）。
// 上游用 json_parse_strict 挡住这种情况；这里用等价的配平检查补上 —— 缓存文件被截断时
// 必须判坏并删掉重算，绝不能把半份歌词当成正式缓存（比读不出来更危险）。
inline bool lyrics_ai_json_balanced(const std::string& t) {
    int depth = 0;
    bool inStr = false, esc = false;
    for (char c : t) {
        if (esc) { esc = false; continue; }
        if (inStr) {
            if (c == '\\') esc = true;
            else if (c == '"') inStr = false;
            continue;
        }
        if (c == '"') { inStr = true; continue; }
        if (c == '{' || c == '[') { ++depth; continue; }
        if (c == '}' || c == ']') { --depth; if (depth < 0) return false; continue; }
    }
    return depth == 0 && !inStr && !esc;
}

inline bool lyrics_ai_parse_json(const std::string& t, rta::net::Json& j) {
    if (!lyrics_ai_looks_like_json(t)) return false;
    const std::string s = llm_trim(t);
    if (!lyrics_ai_json_balanced(s)) return false;
    j = rta::net::json_parse(s);
    return j.type == rta::net::Json::Arr || j.type == rta::net::Json::Obj;
}

// 从 JSON 里取"字符串数组"。顶层数组直接用；顶层对象则认 lines 字段，
// 或者唯一的一个数组字段 —— json_object 模式下部分兼容端点只允许顶层对象，
// 坚持"非数组即失败"会把本来完全可用的结果判死。
inline bool lyrics_ai_json_to_lines(const rta::net::Json& j, std::vector<std::string>& out,
                                    std::string* err) {
    const rta::net::Json* arr = nullptr;
    if (j.type == rta::net::Json::Arr) {
        arr = &j;
    } else if (j.type == rta::net::Json::Obj) {
        if (j.has("lines") && j["lines"].type == rta::net::Json::Arr) {
            arr = &j["lines"];
        } else {
            const rta::net::Json* only = nullptr;
            size_t count = 0;
            for (const auto& kv : j.obj) {
                if (kv.second.type != rta::net::Json::Arr) continue;
                only = &kv.second;
                ++count;
            }
            if (count == 1) arr = only;
        }
    }
    if (!arr) {
        if (err) *err = "顶层既不是数组，也找不到唯一的歌词数组字段";
        return false;
    }
    std::vector<std::string> tmp;
    tmp.reserve(arr->size());
    for (size_t i = 0; i < arr->size(); ++i) {
        const rta::net::Json& e = arr->at(i);
        if (e.type != rta::net::Json::Str) {
            if (err) *err = "第 " + std::to_string(i + 1) + " 个元素不是字符串";
            return false;
        }
        tmp.push_back(e.str);
    }
    out.swap(tmp);
    return true;
}

// 三层解析：原文 → 剥 Markdown 代码围栏 → 取第一个 [ 到最后一个 ]。
// 为什么必须容错：模型经常把数组套在代码围栏里，或在数组前后写"这是结果："；
// 直接按纯 JSON 解析会把完全正确的译文判成失败，用户看到的是"AI 出错了"。
inline bool lyrics_ai_extract_lines(const std::string& raw, std::vector<std::string>& out,
                                    std::string* err) {
    const std::string text = llm_trim(raw);
    rta::net::Json j;
    std::string why;

    // ① 原文本身就是纯 JSON（json_object 模式下的正常返回）。
    if (lyrics_ai_parse_json(text, j)) {
        std::string serr;
        if (lyrics_ai_json_to_lines(j, out, &serr)) return true;
        why = serr;
    } else {
        why = "首字符不是 [ 或 {";
    }

    // ② 剥围栏：从第一行围栏之后取到最后一个围栏。
    const std::string fence = kLyricsAiFence;
    const size_t at = text.find(fence);
    if (at != std::string::npos) {
        const size_t nl = text.find('\n', at);
        if (nl != std::string::npos) {
            std::string body = text.substr(nl + 1);
            const size_t close = body.rfind(fence);
            if (close != std::string::npos) body = body.substr(0, close);
            body = llm_trim(body);
            if (lyrics_ai_parse_json(body, j)) {
                std::string serr;
                if (lyrics_ai_json_to_lines(j, out, &serr)) return true;
                why = serr;
            } else {
                why = "围栏内不是 JSON 容器";
            }
        }
    }

    // ③ 取第一个 [ 到最后一个 ]：前后夹闲话时这是最后一招。
    const size_t lb = text.find('[');
    const size_t rb = text.rfind(']');
    if (lb != std::string::npos && rb != std::string::npos && rb > lb) {
        const std::string sub = text.substr(lb, rb - lb + 1);
        if (lyrics_ai_parse_json(sub, j)) {
            std::string serr;
            if (lyrics_ai_json_to_lines(j, out, &serr)) return true;
            why = serr;
        } else {
            why = "方括号片段不是合法 JSON";
        }
    }

    if (err) {
        const std::string snip = lyrics_ai_flatten(lyrics_ai_clip_utf8(text, kLyricsAiSnippetBytes));
        *err = "模型返回的内容不是合法 JSON 数组" +
               (why.empty() ? std::string() : "（" + why + "）") +
               "；原文摘要（最多 " + std::to_string(kLyricsAiSnippetBytes) + " 字符）：" + snip;
    }
    return false;
}

// ---------------------------------------------------------------------------
// 缓存 key / 读写
// ---------------------------------------------------------------------------

// FNV-1a 64（offset basis 0xcbf29ce484222325、prime 0x100000001b3）。
// 为什么自己写：key 只需要"同输入必同 key、不同输入几乎不同 key"，不需要密码学强度；
// 为一次哈希引入新依赖（SHA/xxhash）不值得，项目里也没有现成的。
inline unsigned long long lyrics_ai_fnv1a64(const std::string& s) {
    unsigned long long h = 14695981039346656037ull;
    for (unsigned char c : s) {
        h ^= (unsigned long long)c;
        h *= 1099511628211ull;
    }
    return h;
}

// key = 缓存格式版本 + 任务 + 源语言 + 目标语言 + 全部行的内容（任务书口径）：
// 任务不同、语言不同、内容不同的三份歌词，绝不能命中同一份缓存。
inline std::string lyrics_cache_key(LyricsAiTask task, const std::string& srcLang,
                                    const std::string& dstLang, const std::vector<std::string>& lines) {
    std::string m;
    m.reserve(64 + lines.size() * 24);
    m += "rta-lyrics-ai|";
    m += std::to_string(kLyricsAiCacheVersion);
    m += '|';
    m += lyrics_ai_task_tag(task);
    m += '|';
    m += lyrics_ai_norm_lang(srcLang);
    m += '|';
    m += lyrics_ai_norm_lang(dstLang);
    // 每行带长度前缀：否则 ["ab","c"] 与 ["a","bc"] 会拼成同一串，命中别人的译文。
    for (const std::string& l : lines) {
        m += '\x1f';
        m += std::to_string(l.size());
        m += ':';
        m += l;
    }
    char buf[17];
    std::snprintf(buf, sizeof(buf), "%016llx", lyrics_ai_fnv1a64(m));
    return std::string(buf);
}

// 同一进程里 rtaweb 的多个请求线程可能同时处理同一首歌（用户连点两次"翻译"）：
// 序列化读写，避免两条线程同时写同一个 .part 把文件写成半截。
inline std::mutex& lyrics_ai_cache_mutex() {
    static std::mutex m;
    return m;
}

inline std::filesystem::path lyrics_ai_cache_file(const std::string& dir, const std::string& key) {
    return lyrics_ai_u8path(dir) / (key + ".json");
}

inline std::string lyrics_ai_cache_json(const LyricsAiResult& r) {
    std::ostringstream o;
    o << "{\"v\":" << kLyricsAiCacheVersion
      << ",\"tokens\":" << r.tokens
      << ",\"lines\":[";
    for (size_t i = 0; i < r.lines.size(); ++i) {
        if (i) o << ',';
        o << '"' << llm_esc(r.lines[i]) << '"';
    }
    o << "]}";
    return o.str();
}

// 先写 .part 再 rename：进程被杀/断电时最多留下一个 .part，绝不会让半截 JSON
// 变成正式缓存 —— 半截文件有时仍是"合法 JSON"，比读不出来更危险。
// 缓存容量上限（2026-11-16 评审 MINOR）：缓存目录只增不减会长期占盘。
// 规则：最多 maxFiles 个 *.json、总字节 ≤ maxBytes，超出按**最近修改时间最旧**先删。
// 0 表示该维度不限。返回删除的文件数。调用方必须已持有 lyrics_ai_cache_mutex()。
inline size_t lyrics_cache_prune_locked(const std::filesystem::path& d,
                                        size_t maxFiles, size_t maxBytes) {
    std::error_code ec;
    if (!std::filesystem::exists(d, ec) || ec) return 0;

    struct Ent { std::filesystem::path p; std::filesystem::file_time_type t; size_t sz; };
    std::vector<Ent> ents;
    size_t total = 0;
    for (const auto& e : std::filesystem::directory_iterator(d, ec)) {
        if (ec) break;
        if (e.path().filename().extension() != std::filesystem::path(".json")) continue;
        std::error_code ec2;
        const auto sz = e.file_size(ec2);
        const auto tm = e.last_write_time(ec2);
        if (ec2) continue;
        ents.push_back({e.path(), tm, (size_t)sz});
        total += (size_t)sz;
    }

    auto within = [&](void) {
        return (maxFiles == 0 || ents.size() <= maxFiles)
            && (maxBytes == 0 || total <= maxBytes);
    };
    if (within()) return 0;

    std::sort(ents.begin(), ents.end(), [](const Ent& a, const Ent& b) {
        return a.t < b.t;                       // 最旧在前
    });

    size_t cnt = ents.size();
    size_t removed = 0;
    for (const auto& e : ents) {                // 从最旧开始删，删到两条上限都满足为止
        const bool okFiles = (maxFiles == 0 || cnt <= maxFiles);
        const bool okBytes = (maxBytes == 0 || total <= maxBytes);
        if (okFiles && okBytes) break;
        std::error_code rm;
        std::filesystem::remove(e.p, rm);
        if (rm) continue;
        ++removed;
        if (cnt > 0) --cnt;
        total = (e.sz <= total) ? (total - e.sz) : 0;
    }
    return removed;
}

// 公开入口：自己加锁（recursive 不需要，因为内部实现不含再次加锁的路径）。
inline size_t lyrics_cache_prune(const std::string& dir, size_t maxFiles = 500,
                                 size_t maxBytes = 200ull * 1024ull * 1024ull) {
    if (dir.empty()) return 0;
    std::lock_guard<std::mutex> lk(lyrics_ai_cache_mutex());
    return lyrics_cache_prune_locked(lyrics_ai_u8path(dir), maxFiles, maxBytes);
}

inline bool lyrics_cache_save(const std::string& dir, const std::string& key, const LyricsAiResult& r) {
    // 失败结果不入缓存：断网/超限/解析失败都是临时状态，缓存下来会让用户
    // 永远看不到正确歌词（而界面上并没有"清缓存重算"这个入口）。
    if (dir.empty() || key.empty() || !r.ok) return false;

    const std::string json = lyrics_ai_cache_json(r);
    std::lock_guard<std::mutex> lk(lyrics_ai_cache_mutex());

    std::error_code ec;
    const std::filesystem::path d = lyrics_ai_u8path(dir);
    std::filesystem::create_directories(d, ec);      // 首次调用时目录通常还不存在

    const std::filesystem::path target = d / (key + ".json");
    const std::filesystem::path part = d / (key + ".json.part");
    {
        std::ofstream f(part, std::ios::binary | std::ios::trunc);
        if (!f) return false;
        f.write(json.data(), (std::streamsize)json.size());
        f.flush();
        if (!f.good()) {
            f.close();
            std::error_code rm;
            std::filesystem::remove(part, rm);
            return false;
        }
    }   // 句柄必须先关：目标被打开时 rename 会失败
    std::filesystem::rename(part, target, ec);
    if (ec) {
        // 有些平台/文件系统上 rename 不覆盖已存在文件，删掉目标再试一次。
        std::error_code ec2;
        std::filesystem::remove(target, ec2);
        std::filesystem::rename(part, target, ec2);
        if (ec2) {
            std::error_code rm;
            std::filesystem::remove(part, rm);
            return false;
        }
    }
    // 写完顺手做一次容量清理（仍在本锁内；上限内的正常情况是 0 次删除）。
    (void)lyrics_cache_prune_locked(d, 500, 200ull * 1024ull * 1024ull);
    return true;
}

inline bool lyrics_cache_load(const std::string& dir, const std::string& key, LyricsAiResult& out) {
    if (dir.empty() || key.empty()) return false;

    std::lock_guard<std::mutex> lk(lyrics_ai_cache_mutex());
    const std::filesystem::path target = lyrics_ai_cache_file(dir, key);
    std::error_code ec;
    if (!std::filesystem::exists(target, ec) || ec) return false;

    std::string text;
    {
        std::ifstream f(target, std::ios::binary);
        if (!f) return false;
        text.assign((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    }

    rta::net::Json j;
    std::vector<std::string> lines;
    bool good = lyrics_ai_parse_json(text, j) && j.type == rta::net::Json::Obj;
    if (good && (!j.has("v") || (int)j["v"].n() != kLyricsAiCacheVersion)) good = false;
    if (good && (!j.has("lines") || j["lines"].type != rta::net::Json::Arr)) good = false;
    if (good) {
        for (size_t i = 0; i < j["lines"].size(); ++i) {
            const rta::net::Json& e = j["lines"].at(i);
            if (e.type != rta::net::Json::Str) { good = false; break; }
            lines.push_back(e.str);
        }
    }
    if (!good) {
        // 损坏文件必须删掉：留着会让每次打开播放页都读到同一份坏数据，
        // 而"删掉重算"是本模块唯一能自愈的路径（上层没有清缓存的入口）。
        std::error_code rm;
        std::filesystem::remove(target, rm);
        return false;
    }

    out.ok = true;
    out.fromCache = true;
    out.error.clear();
    out.code.clear();
    out.lines.swap(lines);
    // tokens 保留当初的实际消耗（fromCache 说明本次没花钱）：
    // 统计"这首歌的 AI 歌词总共花了多少"时才有依据，累加时要先看 fromCache。
    out.tokens = (int)j["tokens"].n();
    return true;
}

// ---------------------------------------------------------------------------
// LRC 时间戳：只换文本、不动前缀
//
// 需求（任务书）：翻译结果必须保留 LRC 时间戳、逐行替换显示；行数守恒按"时间轴行"计。
// 所以进模型的是"去掉 [mm:ss.xx] 之后的正文行"，回来再按同样的前缀拼回去。
// 前缀只认**行首连续的方括号组**（[00:01.00]、[ti:标题] 都是），正文里出现的方括号不动。
// ---------------------------------------------------------------------------

struct LyricsAiLrcLine {
    std::string prefix;   // 行首方括号组 + 紧跟的空格（原样保留）
    std::string text;     // 要被替换的正文（可能为空 = 空行/纯元信息行）
};

inline std::vector<LyricsAiLrcLine> lyrics_ai_split_lrc(const std::string& text) {
    std::vector<LyricsAiLrcLine> out;
    size_t i = 0;
    while (i <= text.size()) {
        const size_t nl = text.find('\n', i);
        const size_t end = (nl == std::string::npos) ? text.size() : nl;
        std::string line = text.substr(i, end - i);
        if (!line.empty() && line.back() == '\r') line.pop_back();

        LyricsAiLrcLine part;
        size_t p = 0;
        // 行首连续的 ... 组
        while (p < line.size() && line[p] == '[') {
            const size_t close = line.find(']', p);
            if (close == std::string::npos) break;
            part.prefix.append(line, p, close - p + 1);
            p = close + 1;
            const size_t ws = p;
            while (p < line.size() && (line[p] == ' ' || line[p] == '\t')) ++p;
            part.prefix.append(line, ws, p - ws);   // 时间戳后的空格也归前缀
        }
        part.text = line.substr(p);
        out.push_back(std::move(part));

        if (nl == std::string::npos) break;
        i = nl + 1;
    }
    return out;
}

// 把译文按原下标贴回前缀。行数不符一律返回空（宁可报错，也不给出错位歌词）。
inline std::vector<std::string> lyrics_ai_apply_lrc(const std::vector<LyricsAiLrcLine>& parts,
                                                    const std::vector<std::string>& out) {
    size_t need = 0;
    for (const auto& p : parts) if (!llm_trim(p.text).empty()) ++need;
    if (out.size() != need) return {};

    std::vector<std::string> joined;
    joined.reserve(parts.size());
    size_t k = 0;
    for (const auto& p : parts) {
        if (llm_trim(p.text).empty()) {
            joined.push_back(p.prefix + p.text);
        } else {
            joined.push_back(p.prefix + out[k++]);
        }
    }
    return joined;
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------
//
// cacheDir：缓存目录（UTF-8）。空串 = 不缓存。rtaweb 传
// <运行期状态目录>/lyrics-cache（与 covercache / artistcache 同一层），测试传临时目录。
// 做成参数而不是全局变量：同一进程里可能有多个数据目录（便携版/测试），全局状态会互相串味。
// 模型有时把「原文」和「译文」写在**同一行**（"原句 译文"），于是界面上看起来就是
// "原词跟翻译挤在一行"。这里在落结果前把回显的原文前缀剥掉，让每一行只留译文；
// 剥不掉（或剥完为空）就原样保留 —— 绝不因为清洗把整行吞掉。
//   只处理"行数一一对应"的翻译/繁体任务；音译/假名本来就该保留原文，不碰。
inline std::string lyrics_strip_echoed_source(const std::string& original, const std::string& got) {
    if (original.empty() || got.empty()) return got;
    const std::string o = llm_trim(original);
    if (o.empty()) return got;
    std::string g = llm_trim(got);
    if (g.size() <= o.size()) return got;
    // 前缀必须**逐字符相同**（大小写不敏感，日文/中文没有大小写概念，无副作用）
    for (size_t i = 0; i < o.size(); ++i) {
        const unsigned char a = (unsigned char)o[i];
        const unsigned char b = (unsigned char)g[i];
        const unsigned char la = (a >= 'A' && a <= 'Z') ? (unsigned char)(a - 'A' + 'a') : a;
        const unsigned char lb = (b >= 'A' && b <= 'Z') ? (unsigned char)(b - 'A' + 'a') : b;
        if (la != lb) return got;
    }
    size_t p = o.size();
    // 原文后面紧跟的分隔符：空白 / 制表 / 横线 / 冒号 / 竖线 / 箭头 / 括号
    while (p < g.size()) {
        const char c = g[p];
        // 注意：这里**只列单字节**分隔符。把 0xE2 这种多字节首字节当分隔符会拆坏 "—"/"→"，
        // 结果留下半截 UTF-8（实测："abc — 甲乙" 变成 "?? 甲乙"）。多字节交给下面那个循环。
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '-' || c == ':' ||
            c == '|' || c == '(' || c == ')' || c == '/' || c == '~' || c == '=')
            ++p;
        else break;
    }
    // 跳过三字节的破折号/箭头（——、→）等常见分隔符
    while (p + 2 < g.size() && (unsigned char)g[p] >= 0xE0) {
        const unsigned char c1 = (unsigned char)g[p + 1], c2 = (unsigned char)g[p + 2];
        // —(E2 80 94) –(E2 80 93) →(E2 86 92) ：(EF BC 9A) （(EF BC 88)
        const bool dash = ((unsigned char)g[p] == 0xE2) &&
                          (c1 == 0x80 || c1 == 0x86);
        const bool colon = ((unsigned char)g[p] == 0xEF) && c1 == 0xBC && (c2 == 0x9A || c2 == 0x88);
        if (!dash && !colon) break;
        p += 3;
        while (p < g.size() && (g[p] == ' ' || g[p] == '\t')) ++p;
    }
    const std::string rest = llm_trim(g.substr(std::min(p, g.size())));
    return rest.empty() ? got : rest;   // 剥完为空 ⟹ 说明这行本来就是原文，保留原样
}

inline LyricsAiResult lyrics_ai_process(const LlmConfig& cfg, LyricsAiTask task,
                                        const std::vector<std::string>& lines,
                                        const std::string& sourceLang,
                                        const std::string& targetLang,
                                        const std::string& cacheDir = std::string()) {
    LyricsAiResult r;

    // 没 key 就不发请求：未配置时必须快速失败，界面才好提示"去设置里填 key"。
    if (cfg.apiKey.empty()) {
        r.error = "未配置 api_key（rlplayer-llm.conf）";
        r.code = kLyricsAiErrNoKey;
        return r;
    }
    // 目标语言是翻译的唯一必需参数；空着发出去只会让模型自己猜，白花钱。
    if (task == LyricsAiTask::Translate && llm_trim(targetLang).empty()) {
        r.error = "翻译任务缺少目标语言（lang 为空）";
        r.code = kLyricsAiErrNoLang;
        return r;
    }

    const std::string key = lyrics_cache_key(task, sourceLang, targetLang, lines);
    if (!cacheDir.empty() && lyrics_cache_load(cacheDir, key, r)) {
        r.fromCache = true;      // 命中就不发请求：这正是"同一首歌不重复花钱"的实现
        return r;
    }

    // 只把非空行送模型，并记下它们原来的下标。模型几乎总会把空行吞掉，
    // 直接送会让返回行数少于输入行数，界面就整首歌错位。
    std::vector<size_t> slots;
    std::vector<std::string> payload;
    slots.reserve(lines.size());
    payload.reserve(lines.size());
    for (size_t i = 0; i < lines.size(); ++i) {
        if (llm_trim(lines[i]).empty()) continue;   // 纯空白也算空行
        slots.push_back(i);
        payload.push_back(lines[i]);
    }

    // 全是空行（纯间奏/纯器乐）：没有要处理的内容，不值得花一次调用。
    if (payload.empty()) {
        r.ok = true;
        r.lines.assign(lines.size(), std::string());
        if (!cacheDir.empty() && !lines.empty()) lyrics_cache_save(cacheDir, key, r);
        return r;
    }

    // 按行数估 max_tokens：估小了长歌词会被截断（下面的 length 检查会报错，
    // 但用户白等一次）；估大了只是浪费上限，所以宁可宽一点。
    // 预算必须按任务给，否则假名/音译永远 length（见常量注释）。
    const bool heavy = (task == LyricsAiTask::Furigana || task == LyricsAiTask::Transliterate);
    const int perLine = heavy ? kLyricsAiTokensPerLineHeavy : kLyricsAiTokensPerLine;
    const int margin  = heavy ? kLyricsAiTokenMarginHeavy : kLyricsAiTokenMargin;
    const long long est = (long long)margin + (long long)perLine * (long long)payload.size();
    const int maxTokens = (int)std::min<long long>(kLyricsAiMaxTokens, est);

    std::vector<LlmMessage> msgs;
    msgs.push_back(lyrics_ai_message("system", lyrics_ai_system_prompt(task, (int)payload.size())));
    msgs.push_back(lyrics_ai_message("user", lyrics_ai_user_prompt(task, payload, sourceLang, targetLang)));

    // 不开 jsonObject：response_format=json_object 要求顶层是对象，与 system 里
    // "只输出 JSON **数组**" 冲突 —— 上游实测 deepseek-flash 在这种矛盾下会一直推理到
    // finish_reason=length（3 行烧掉 950 token）。解析侧本来就容错（剥围栏 + 取首 '[' 到末 ']'），
    // 所以关掉它零损失。
    const LlmReply reply = llm_chat(cfg, msgs, maxTokens, 0.2f, /*jsonObject=*/false);
    if (!reply.ok) {
        r.error = reply.error.empty() ? std::string("模型调用失败（未给出原因）") : reply.error;
        r.code = kLyricsAiErrLlm;
        return r;
    }
    if (reply.finishReason == "length") {
        r.error = "模型输出被截断（finish_reason=length，max_tokens=" + std::to_string(maxTokens) +
                  "）：为避免只返回半首歌，本次结果丢弃";
        r.code = kLyricsAiErrTruncated;
        return r;
    }
    if (llm_trim(reply.content).empty()) {
        r.error = "模型返回了空内容（finish_reason=" +
                  (reply.finishReason.empty() ? std::string("空") : reply.finishReason) + "）";
        r.code = kLyricsAiErrEmpty;
        return r;
    }

    std::vector<std::string> got;
    std::string perr;
    if (!lyrics_ai_extract_lines(reply.content, got, &perr)) {
        r.error = perr;
        r.code = kLyricsAiErrParse;
        return r;
    }
    if (got.size() != payload.size()) {
        // 不"凑合对齐"：少一行就整首歌错位，多一行则后面全串。
        r.error = "模型返回的行数与输入不符：送检 " + std::to_string(payload.size()) +
                  " 行（输入共 " + std::to_string(lines.size()) + " 行，空行已剔除），返回 " +
                  std::to_string(got.size()) + " 行；为避免界面歌词错行，本次结果丢弃";
        r.code = kLyricsAiErrLineMismatch;
        return r;
    }

    r.ok = true;
    r.tokens = reply.totalTokens;
    r.lines.assign(lines.size(), std::string());     // 空行位置保持空串
    for (size_t k = 0; k < got.size(); ++k) {
        const bool echoable = (task == LyricsAiTask::Translate || task == LyricsAiTask::TradChinese);
        r.lines[slots[k]] = echoable ? lyrics_strip_echoed_source(lines[slots[k]], got[k]) : got[k];
    }

    if (!cacheDir.empty()) lyrics_cache_save(cacheDir, key, r);   // 写缓存失败不影响本次结果
    return r;
}

// ---------------------------------------------------------------------------
// 分块：一次处理整首歌
//
// 单次调用有 max_tokens 天花板（8000），整首 40+ 行的歌词必须切块；
// 分块只影响调用次数，不影响行序 —— 逐块拼接后行数仍与输入一一对应。
// 任何一块失败都是整体失败（绝不拼接"半首歌"），并原样透传该块的错误码。
// ---------------------------------------------------------------------------
inline LyricsAiResult lyrics_ai_process_all(const LlmConfig& cfg, LyricsAiTask task,
                                            const std::vector<std::string>& lines,
                                            const std::string& sourceLang,
                                            const std::string& targetLang,
                                            const std::string& cacheDir = std::string(),
                                            size_t chunkOverride = 0) {
    LyricsAiResult all;
    if (lines.empty()) {
        all.ok = true;
        return all;
    }
    const size_t chunk = chunkOverride ? chunkOverride : lyrics_ai_chunk_size(task);
    bool cacheOk = true;
    for (size_t off = 0; off < lines.size(); off += chunk) {
        std::vector<std::string> part(lines.begin() + (long)off,
                                      lines.begin() + (long)std::min(off + chunk, lines.size()));
        const LyricsAiResult r = lyrics_ai_process(cfg, task, part, sourceLang, targetLang, cacheDir);
        if (!r.ok) {
            LyricsAiResult bad;          // 失败时不带任何已完成的行
            bad.error = r.error;
            bad.code = r.code;
            return bad;
        }
        if (r.lines.size() != part.size()) {   // 防御：单块行数必须守恒
            LyricsAiResult bad;
            bad.error = "分块结果行数与块内输入不符（" + std::to_string(r.lines.size()) + " vs " +
                        std::to_string(part.size()) + "）";
            bad.code = kLyricsAiErrLineMismatch;
            return bad;
        }
        for (const std::string& s : r.lines) all.lines.push_back(s);
        all.tokens += r.tokens;
        if (!r.fromCache) cacheOk = false;
    }
    all.ok = true;
    all.fromCache = cacheOk;
    return all;
}

}  // namespace rta::meta
