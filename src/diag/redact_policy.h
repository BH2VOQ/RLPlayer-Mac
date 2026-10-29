// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// redact_policy.h — D1/D3：事件落盘前的脱敏策略（在既有 feedback_redact.h 之上补强）
//
// ===========================================================================
// 为什么需要一层"补强"，而不直接用 src/net/feedback_redact.h
//
// 那个文件是为**自由文本日志**写的，规则全是"键名 + 值"的文本形态匹配。它的
// 判据（tests/test_feedback_redact.cpp）证明它在那类输入上是对的，但用在结构化
// 事件上仍有 5 个洞，本文件逐个补：
//
//   ① URL query 完全不处理。`https://api.x.com/v1/search?q=我的搜不到的歌&sig=…`
//      里 q 是用户输入、sig 是凭据，两者都会原文落盘。→ 本层把整段 query 换成
//      `?<redacted-query:N>`（保留参数个数），fragment 换成 `#<redacted-fragment>`，
//      userinfo（`user:pass@`）换成 `<redacted>@`。
//
//   ② 裸 `key=` 只有值 ≥32 字符才抹（feedback_redact.h 的有意偏离 1，为了保住
//      封面缓存键）。代价是 20 字符的短 API key 泄漏。→ 本层按**结构化键名**判定：
//      key 值 ≥16 字符即视为凭据；`api_key/token/password/...` 这类确定的键名
//      有值就抹，不看长度（空的保留，因为"配没配"本身是诊断信息）。
//
//   ③ 歌词/正文整段不落盘没有任何规则。自由文本日志里没人会打歌词，但事件里
//      meta/llm 的 kv 很容易顺手带上。→ 本层对 lyrics/lrc 系列键整段替换为
//      `<redacted:lyrics len=N>`，对 body/content/prompt/response 等正文键替换为
//      `<redacted:body len=N>`（**不保留任何前缀**：正文前 10 个字也可能泄私密）。
//
//   ④ 无长度上限。一条 200 KB 的 LLM 响应会把 8 MB 的事件文件挤掉几十条真实事件。
//      → 本层对普通值截断到 kMaxValueChars，并留 `<truncated len=N>` 标记。
//
//   ⑤ 不做 UTF-8 校验（那是 event.h 序列化时的职责，这里只保证不把坏字节放大）。
//
// ★ 与既有层的分工（刻意不重复实现，避免两套规则打架）：
//     feedback_redact.h 负责「密钥前缀 / 头 / Bearer / 凭据键值 / 用户名 / 邮箱」；
//     本文件负责「URL / 结构化键名 / 歌词与正文 / 截断」，最后仍把结果交给
//     feedback::redact() 过一遍（顺序：URL → JWT → feedback），保证两层都生效。
//
// ★ 已知边界（如实写在这里，不假装覆盖）：
//   - 不认识 `X-Custom-Auth:` 这类自定义头（feedback 的名单里没有）。
//   - 值里如果有"看起来像普通单词的短口令"（如口令 `hunter2` 直接放在
//     kv["cmd"] 里），无从判定，会原样保留 —— 这类应该由调用方用
//     secret 键名（token/password/...）来标注，而不是靠模式猜。
//   - 用户名只按 `/Users/<名>/`、`/home/<名>/` 掩码；`/Volumes/<名>/` 这类
//     外接盘挂载点的用户名不在规则内。
//   - 没有 scheme 的裸 `host/path?query`（例如后端只记 `api.x.com/v1?q=…`）不会
//     被 URL 规则命中 —— 事件里请写完整 URL（含 https://），或把参数拆成独立 kv。
// ===========================================================================
#pragma once

#include <cstddef>
#include <string>
#include <string_view>

#include "diag/event.h"
#include "net/feedback_redact.h"

namespace rta::diag {

// 脱敏统计：上层写进事件/诊断包 manifest，证明确实跑过（不是 applied:true 空话）
struct RedactReport {
    int feedback_hits = 0;    // 既有 feedback_redact 命中的条数
    int secret_key = 0;       // 结构化键名判定为凭据
    int url_query = 0;        // 被剥离 query 的 URL 个数
    int url_fragment = 0;     // 被剥离 fragment 的 URL 个数
    int url_userinfo = 0;     // 被剥离 user:pass@ 的 URL 个数
    int jwt = 0;              // 裸 JWT
    int lyrics = 0;           // 歌词整段不落盘
    int body = 0;             // 正文（LLM/元数据）整段不落盘
    int truncated = 0;        // 超长截断
    int total() const {
        return feedback_hits + secret_key + url_query + url_fragment + url_userinfo + jwt + lyrics +
               body + truncated;
    }
};

// 普通值上限（字符 = 字节；UTF-8 多字节会被整体保留，不切半个字符）
inline constexpr std::size_t kMaxValueChars = 512;

namespace detail {

// 键名归一：小写 + 去掉分隔符（api_key / api-key / ApiKey / x-api-key 都归一）
inline std::string norm_key(std::string_view k) {
    std::string o;
    o.reserve(k.size());
    for (char ch : k) {
        const unsigned char c = (unsigned char)ch;
        if (c >= 'A' && c <= 'Z') o.push_back((char)(c - 'A' + 'a'));
        else if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) o.push_back((char)c);
    }
    return o;
}

inline bool one_of(const std::string& v, std::initializer_list<const char*> set) {
    for (const char* s : set)
        if (v == s) return true;
    return false;
}

// 是否"确定是凭据"的键名：有非空值就抹，不看长度
inline bool is_definite_secret_key(const std::string& nk) {
    return one_of(nk, {"apikey", "token", "accesstoken", "refreshtoken", "idtoken", "password",
                       "passwd", "pwd", "secret", "clientsecret", "ghtoken", "authorization",
                       "proxyauthorization", "cookie", "setcookie", "xauthtoken", "privatekey",
                       "credential", "credentials", "passphrase"});
}

// 是否"含义模糊"的键名：短值可能是正常值（auth=basic、key=<缓存键>），
// 长值才当凭据。kAmbiguousSecretMinLen 是有意取 16 的分界（见文件头 ②）。
inline constexpr std::size_t kAmbiguousSecretMinLen = 16;
inline bool is_ambiguous_key(const std::string& nk) {
    return one_of(nk, {"key", "auth", "sig", "signature", "session", "sessionid", "bearer"});
}

inline bool is_lyrics_key(const std::string& nk) {
    return one_of(nk, {"lyrics", "lyric", "lrc", "lyrictext", "lyricsbody", "syncedlyrics",
                       "unsyncedlyrics", "plainlyrics", "lyriclines"});
}

// 正文类键：LLM 回答、元数据正文、UI 富文本。整段不落盘（文件头 ③）
inline bool is_body_key(const std::string& nk) {
    return one_of(nk, {"body", "content", "prompt", "response", "completion", "rawtext",
                       "fulltext", "text", "raw"});
}

// 裸 JWT：三段 base64url、总长 ≥40。反馈层只认带 Bearer/Authorization 前缀的，
// 直接放在 kv 里的 JWT 它看不见。
inline bool looks_like_jwt(std::string_view t) {
    if (t.size() < 40) return false;
    int dots = 0;
    for (char c : t) {
        const unsigned char u = (unsigned char)c;
        const bool b64 = (u >= 'A' && u <= 'Z') || (u >= 'a' && u <= 'z') ||
                         (u >= '0' && u <= '9') || u == '_' || u == '-';
        if (c == '.') { ++dots; continue; }
        if (!b64) return false;
    }
    if (dots != 2) return false;
    const size_t a = t.find('.');
    const size_t b = t.find('.', a + 1);
    return a >= 8 && b > a + 8 && t.size() - b > 8;
}

inline std::string redact_jwts(const std::string& s, RedactReport* rep) {
    std::string o;
    o.reserve(s.size());
    size_t i = 0;
    while (i < s.size()) {
        const unsigned char c = (unsigned char)s[i];
        const bool word = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                          (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.';
        if (!word) { o.push_back(s[i]); ++i; continue; }
        size_t e = i;
        while (e < s.size()) {
            const unsigned char d = (unsigned char)s[e];
            if ((d >= 'A' && d <= 'Z') || (d >= 'a' && d <= 'z') || (d >= '0' && d <= '9') ||
                d == '_' || d == '-' || d == '.')
                ++e;
            else
                break;
        }
        const std::string_view tok(s.data() + i, e - i);
        if (looks_like_jwt(tok)) {
            o += "<redacted>";
            if (rep) ++rep->jwt;
        } else {
            o.append(tok);
        }
        i = e;
    }
    return o;
}

inline bool is_url_char(char c) {
    const unsigned char u = (unsigned char)c;
    if (u <= 0x20) return false;
    switch (c) {
        case '"': case '\'': case '<': case '>': case '(': case ')':
        case '[': case ']': case '{': case '}': case ',': case ';': case '\\':
            return false;
        default: return true;
    }
}

inline char lower1(char c) {
    return (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : c;
}

// 找 http:// 或 https://（大小写不敏感）。返回 npos 表示没有。
inline size_t find_scheme(const std::string& s, size_t from) {
    static const char* kA[] = {"http://", "https://"};
    size_t best = std::string::npos;
    for (const char* sch : kA) {
        const size_t n = std::char_traits<char>::length(sch);
        for (size_t i = from; i + n <= s.size(); ++i) {
            bool hit = true;
            for (size_t k = 0; k < n; ++k) {
                if (lower1(s[i + k]) != sch[k]) { hit = false; break; }
            }
            if (hit) {
                if (best == std::string::npos || i < best) best = i;
                break;
            }
        }
    }
    return best;
}

// 重写一个 URL：保留 scheme/host/path，剥掉 userinfo/query/fragment。
// 之所以保留 path：诊断恰恰需要知道是哪个接口（/v1/models 与 /v1/chat 完全不同）。
inline std::string rewrite_url(const std::string& url, RedactReport* rep) {
    const size_t sep = url.find("://");
    if (sep == std::string::npos) return url;
    size_t p = sep + 3;
    std::string out = url.substr(0, p);
    // authority 结尾
    size_t auth_end = p;
    while (auth_end < url.size() && url[auth_end] != '/' && url[auth_end] != '?' &&
           url[auth_end] != '#')
        ++auth_end;
    const size_t at = url.rfind('@', auth_end == 0 ? 0 : auth_end - 1);
    if (at != std::string::npos && at >= p && at < auth_end) {
        out += "<redacted>";
        out += '@';
        if (rep) ++rep->url_userinfo;
        out.append(url, at + 1, auth_end - at - 1);
    } else {
        out.append(url, p, auth_end - p);
    }
    // path
    size_t q = auth_end;
    while (q < url.size() && url[q] != '?' && url[q] != '#') ++q;
    out.append(url, auth_end, q - auth_end);
    // query
    if (q < url.size() && url[q] == '?') {
        size_t e = q + 1;
        while (e < url.size() && url[e] != '#') ++e;
        int params = 0;
        bool nonEmpty = false;
        for (size_t i = q + 1; i < e; ++i) {
            if (url[i] == '&') { if (nonEmpty) ++params; nonEmpty = false; continue; }
            if (url[i] != ' ') nonEmpty = true;
        }
        if (nonEmpty) ++params;
        out += "?<redacted-query:";
        out += std::to_string(params);
        out += ">";
        if (rep) ++rep->url_query;
        q = e;
    }
    // fragment
    if (q < url.size() && url[q] == '#') {
        out += "#<redacted-fragment>";
        if (rep) ++rep->url_fragment;
    }
    return out;
}

inline std::string redact_urls(const std::string& in, RedactReport* rep) {
    if (in.find("://") == std::string::npos) return in;
    std::string out;
    out.reserve(in.size());
    size_t i = 0;
    while (i < in.size()) {
        const size_t hit = find_scheme(in, i);
        if (hit == std::string::npos) {
            out.append(in, i, std::string::npos);
            break;
        }
        out.append(in, i, hit - i);
        size_t e = hit;
        while (e < in.size() && is_url_char(in[e])) ++e;
        out += rewrite_url(in.substr(hit, e - hit), rep);
        i = e;
    }
    return out;
}

inline void truncate_utf8(std::string& s, std::size_t maxChars, RedactReport* rep) {
    if (s.size() <= maxChars) return;
    const std::size_t original = s.size();
    std::size_t cut = maxChars;
    while (cut > 0 && ((unsigned char)s[cut] & 0xC0) == 0x80) --cut;   // 不切半个 UTF-8 字符
    s.resize(cut);
    s += "…<truncated len=";
    s += std::to_string(original);
    s += ">";
    if (rep) ++rep->truncated;
}

}  // namespace detail

// 自由文本：URL → 裸 JWT → 既有 feedback 规则 → 截断。
// 顺序有讲究：先剥 URL（否则 query 里的 api_key=… 会被 feedback 抹成
// `<redacted>`，反而看不出"这一整段 query 已被丢弃"），再交给既有层兜底。
inline std::string redact_text(const std::string& in, RedactReport* rep = nullptr,
                               bool cap = true) {
    std::string s = detail::redact_urls(in, rep);
    s = detail::redact_jwts(s, rep);
    rta::feedback::RedactStats fs;
    s = rta::feedback::redact(s, &fs);
    if (rep) rep->feedback_hits += fs.total();
    if (cap) detail::truncate_utf8(s, kMaxValueChars, rep);
    return s;
}

// 结构化键值：先按键名判类别（歌词/正文/凭据），否则当普通文本处理。
// 这是既有 feedback 层做不到的部分：它只看"键名=值"的文本形态，
// 而事件里的键是独立字段，值本身不含键名。
inline std::string redact_kv_value(const std::string& key, const std::string& value,
                                   RedactReport* rep = nullptr) {
    const std::string nk = detail::norm_key(key);
    if (value.empty()) return value;   // 空值保留：是否配置过本身是诊断信息
    if (detail::is_lyrics_key(nk)) {
        if (rep) ++rep->lyrics;
        return "<redacted:lyrics len=" + std::to_string(value.size()) + ">";
    }
    if (detail::is_body_key(nk)) {
        if (rep) ++rep->body;
        return "<redacted:body len=" + std::to_string(value.size()) + ">";
    }
    if (detail::is_definite_secret_key(nk)) {
        if (rep) ++rep->secret_key;
        return "<redacted>";
    }
    if (detail::is_ambiguous_key(nk) && value.size() >= detail::kAmbiguousSecretMinLen) {
        if (rep) ++rep->secret_key;
        return "<redacted>";
    }
    return redact_text(value, rep, true);
}

// 改写整个事件（就地）。EventLog 在序列化**之前**调用它 —— 顺序不能反：
// 先序列化再脱敏就要对 JSON 文本做二次转义，很容易把转义符吃掉。
inline void redact_event(Event& e, RedactReport* rep = nullptr) {
    e.sid = redact_text(e.sid, rep, true);
    e.rid = redact_text(e.rid, rep, true);
    e.evt = redact_text(e.evt, rep, true);
    e.stage = redact_text(e.stage, rep, true);
    e.code = redact_text(e.code, rep, true);
    for (auto& p : e.kv) {
        const std::string old_val = p.v;
        p.v = redact_kv_value(p.k, p.v, rep);
        if (p.kind != KvKind::Str && p.v != old_val) {
            p.kind = KvKind::Str;
        }
    }
}

}  // namespace rta::diag
