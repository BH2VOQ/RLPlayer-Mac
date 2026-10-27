// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// feedback_redact.h — 「一键反馈 / 诊断包」唯一的脱敏入口（纯函数、零依赖、可离线单测）
//
// ===========================================================================
// 为什么有这个文件（2026-10-27 F-7）
//
// 本机原本已经有一条**能跑**的反馈通路：前端 fbSend() → Cloudflare Worker；
// 诊断包由 tools/rtaweb.cpp 的 /api/diagzip 在服务端内存里打包。
// 但那个端点里的脱敏是一段**内联 lambda**（redact_secrets），只认 5 个前缀
// 「api_key= / apikey= / token= / password= / secret=」的 `k=v` 形态 + 散落的 `sk-`。
// 实测（见 tests/test_feedback_redact.cpp 的 legacy_redact 对照）漏掉了：
//   ① JSON 形态  `"token": "abcdef123456"`   —— 键后面跟的是 `":`，不是 `=`，整条漏
//   ② 头形态    `Authorization: Bearer eyJ...` —— 不认识 header 名，整条漏
//   ③ 家目录    `/Users/august/...`            —— 完全不做路径归一
//   ④ 邮箱      `tester@example.com`           —— 不做邮箱处理
//   ⑤ `sk-live-ABCDEF...` 只抹到第一个 '-' 为止，**中间那段仍然明文**（比不抹更危险：
//      看起来像脱敏了，实际泄漏）
//
// 上游 src/net/feedback.h（另一套 WinHTTP 通路，1249 行）里有一套更完整的规则。
// 本文件把**规则**吸收成 mac 侧唯一的、可单测的实现；上游的传输层（WinHTTP /
// GitHub Contents API / 表单）属于 Windows 专有，按清单 C-7 **不移植**。
//
// ===========================================================================
// 规则清单（也是 rtaweb 的诊断包 README 与 diag.json 里 redaction.rules 报给用户看的那几条）
//
//   1) openai_key      —— `sk-…` 形态密钥（含 sk-proj- / sk-live- …，整段替换）
//   2) github_token    —— `ghp_ / gho_ / ghu_ / ghs_ / ghr_ / github_pat_` 开头
//   3) aws_key         —— `AKIA…`
//   4) slack_token     —— `xoxb-… / xoxp-…`
//   5) auth_header     —— `Authorization:` / `Proxy-Authorization:` / `X-Api-Key:` /
//                         `api-key:` / `x-auth-token:` / `Cookie:` 之后的值
//   6) bearer_token    —— 裸的 `Bearer <token>`（≥6 字符才算凭据）
//   7) credential_kv   —— api_key / apikey / api-key / x-api-key / token / access_token /
//                         refresh_token / password / passwd / secret / client_secret /
//                         gh_token 后面跟的值（`k=v` 与 `"k": "v"` 两种写法都认）
//   8) user_path       —— `\Users\<名>\` / `/Users/<名>/` / `/home/<名>/` /
//                         `\Documents and Settings\<名>\` 里的**用户名段** → `<user>`
//                         （路径结构保留，只换用户名，便于看出"当时用的哪个位置"）
//   9) email           —— 邮箱本地部分 → `<user>`，域名保留
//
// 被替换掉的值一律写 `<redacted>`，用户目录名写 `<user>`；键名/前缀/路径结构**保留**，
// 这样收到包的人能判断"当时到底配没配"。
//
// ===========================================================================
// 与上游的两处**有意偏离**（都是为了满足本任务的"不许误伤"判据，别当成 bug）
//
//   ★ 偏离 1：`key` 与 `auth` 这两个裸键名不按 credential_kv 处理。
//     上游把它们放进 credential_kv（文档里也承认代价：rtaweb 的 COVERBG 行
//     `key=<封面缓存键>` 会被一并打码）。本地诊断包的主要用处恰恰是排查封面/库问题，
//     把 `key=` 抹掉等于自毁证据。改法：裸 `key` / `auth` 另走「长值才算凭据」规则
//     （值 ≥ 32 字符才替换）—— 真实 API key 都远超 32 字符，而封面缓存键是 10 位十六进制。
//
//   ★ 偏离 2：所有"值"类规则都有**最短长度**门槛，短值原样保留。
//     理由同上：`token=`+空、`auth=none`、`key=a1b2c3` 这类不是凭据，抹掉只会丢诊断信息。
//
// 判据：tests/test_feedback_redact.cpp —— 里面同时保留了**改前的旧实现**（legacy_redact）
// 做对照，逐条断言"旧实现漏、新实现干净"，所以这套规则永远有红侧证据可复跑。
// ===========================================================================
#pragma once

#include <cstddef>
#include <cstring>
#include <string>
#include <vector>

namespace rta::feedback {

// ---- 基础工具 -------------------------------------------------------------

// 标识符字符：字母/数字/下划线。用于判断"键名边界"，避免 hotkey / monkey / tokenization 误伤
inline bool is_ident_char(char c) {
    const unsigned char u = (unsigned char)c;
    return (u >= '0' && u <= '9') || (u >= 'A' && u <= 'Z') || (u >= 'a' && u <= 'z') || u == '_';
}

inline std::string to_lower_ascii(const std::string& s) {
    std::string o;
    o.resize(s.size());
    for (size_t i = 0; i < s.size(); ++i) {
        const unsigned char c = (unsigned char)s[i];
        o[i] = (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : (char)c;
    }
    return o;
}

// 命中计数：让上层能证明"脱敏真的跑过并且改掉了东西"，而不是印一句 applied:true
struct RedactStats {
    int prefixed_token = 0;
    int header_value = 0;
    int bearer = 0;
    int credential_kv = 0;
    int user_path = 0;
    int email = 0;
    int total() const {
        return prefixed_token + header_value + bearer + credential_kv + user_path + email;
    }
};

namespace detail {

// 原文 + 等长小写副本：搜索走 std::string::find（memchr 优化），比逐位 tolower 比较快一个量级。
// 2MB 日志 × 十几条规则，逐位比较会到秒级；这里保证毫秒级。
struct Buf {
    std::string s;
    std::string low;
    explicit Buf(std::string in) : s(std::move(in)), low(to_lower_ascii(s)) {}
    void replace(size_t a, size_t b, const char* rep) {
        if (a >= b || b > s.size()) return;
        s.replace(a, b - a, rep);
        low.replace(a, b - a, rep);   // 两个替换串本身都是小写，无需再转
    }
    // 在小写副本里找（keyLower 必须是全小写字面量）
    bool find(const char* keyLower, size_t from, size_t& hit) const {
        const size_t p = low.find(keyLower, from);
        if (p == std::string::npos) return false;
        hit = p;
        return true;
    }
};

inline int find_min(const Buf& b, const char* const* keys, size_t n, size_t from,
                    size_t& hit, size_t& klen) {
    size_t best = std::string::npos;
    size_t blen = 0;
    for (size_t i = 0; i < n; ++i) {
        size_t p = 0;
        if (!b.find(keys[i], from, p)) continue;
        if (best == std::string::npos || p < best) { best = p; blen = std::strlen(keys[i]); }
    }
    if (best == std::string::npos) return 0;
    hit = best;
    klen = blen;
    return 1;
}

// 规则 1~4：带固定前缀的密钥。整段（含前缀）替换 —— 只抹前缀后面的部分是泄漏（见文件头 ⑤）
inline void mask_prefixed(Buf& b, RedactStats* st) {
    // 全部小写：搜索走 low 副本，大小写不敏感（AKIA / akia 都认）
    static const char* kPfx[] = {"sk-", "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_",
                                 "xoxb-", "xoxp-", "akia"};
    size_t scan = 0;
    for (;;) {
        size_t hit = 0, plen = 0;
        if (!find_min(b, kPfx, sizeof(kPfx) / sizeof(kPfx[0]), scan, hit, plen)) break;
        const bool leftOk = (hit == 0) || !is_ident_char(b.s[hit - 1]);
        size_t e = hit + plen;
        while (e < b.s.size() && (is_ident_char(b.s[e]) || b.s[e] == '-' || b.s[e] == '.')) ++e;
        const size_t vlen = e - (hit + plen);
        if (leftOk && vlen >= 6) {
            b.replace(hit, e, "<redacted>");
            if (st) ++st->prefixed_token;
            scan = hit + 10;
        } else {
            scan = hit + plen;
        }
    }
}

// 规则 5：HTTP 头。值一直吃到行尾/引号/逗号/分号，整段替换
inline void mask_headers(Buf& b, RedactStats* st) {
    static const char* kHdr[] = {"authorization", "proxy-authorization", "x-api-key", "api-key",
                                 "x-auth-token", "cookie"};
    size_t scan = 0;
    for (;;) {
        size_t hit = 0, hlen = 0;
        if (!find_min(b, kHdr, sizeof(kHdr) / sizeof(kHdr[0]), scan, hit, hlen)) break;
        if (hit > 0 && is_ident_char(b.s[hit - 1])) { scan = hit + hlen; continue; }
        size_t j = hit + hlen;
        while (j < b.s.size() && (b.s[j] == ' ' || b.s[j] == '\t')) ++j;
        if (j >= b.s.size() || b.s[j] != ':') { scan = hit + hlen; continue; }
        ++j;
        while (j < b.s.size() && (b.s[j] == ' ' || b.s[j] == '\t')) ++j;
        const size_t vstart = j;
        size_t e = j;
        while (e < b.s.size()) {
            const char c = b.s[e];
            if (c == '\r' || c == '\n' || c == '"' || c == ',' || c == '}' || c == ';') break;
            ++e;
        }
        size_t ee = e;
        while (ee > vstart && (b.s[ee - 1] == ' ' || b.s[ee - 1] == '\t')) --ee;
        if (ee > vstart && b.s.compare(vstart, ee - vstart, "<redacted>") != 0) {
            b.replace(vstart, ee, "<redacted>");
            if (st) ++st->header_value;
            scan = vstart + 10;
        } else {
            scan = vstart;
            if (scan <= hit) scan = hit + hlen;
        }
    }
}

// 规则 6：裸 Bearer
// ★ 必须要求 "Bearer" 后面**至少一个空白**才认。
//   2026-10-27 实测事故：不要求空白时，把规则清单里的规则名 "bearer_token" 也吃了
//   （`bearer` + `_token` 恰好满足「后接 ≥6 个标识符字符」），结果 diag.json 的
//   rules 数组被改成 "bearer<redacted>"，自己把自己的文档打烂。
//   真实 HTTP 头一定是 `Bearer <token>`（有空格），所以加这条前提不会漏真凭据。
inline void mask_bearer(Buf& b, RedactStats* st) {
    size_t scan = 0;
    for (;;) {
        size_t hit = 0;
        if (!b.find("bearer", scan, hit)) break;
        if (hit > 0 && is_ident_char(b.s[hit - 1])) { scan = hit + 6; continue; }
        size_t j = hit + 6;
        if (j >= b.s.size() || (b.s[j] != ' ' && b.s[j] != '\t')) { scan = hit + 6; continue; }
        while (j < b.s.size() && (b.s[j] == ' ' || b.s[j] == '\t')) ++j;
        size_t e = j;
        while (e < b.s.size() && (is_ident_char(b.s[e]) || b.s[e] == '-' || b.s[e] == '.' ||
                                  b.s[e] == '+' || b.s[e] == '/' || b.s[e] == '=')) ++e;
        if (e - j >= 6) {
            b.replace(j, e, "<redacted>");
            if (st) ++st->bearer;
            scan = j + 10;
        } else {
            scan = hit + 6;
        }
    }
}

// 规则 7：key = value / "key": "value"。minValue：值短于此长度不当作凭据
inline void mask_kv(Buf& b, const char* keyLower, size_t keyLen, size_t minValue, RedactStats* st) {
    size_t scan = 0;
    for (;;) {
        size_t hit = 0;
        if (!b.find(keyLower, scan, hit)) break;
        const size_t after = hit + keyLen;
        // 左右边界：前面不能是标识符字符（hotkey / oauth / refresh_token 的 token 段），
        // 后面不能紧跟标识符字符或 '-'（api-key / x-api-key 由各自的键名负责）
        const bool leftOk = (hit == 0) || !is_ident_char(b.s[hit - 1]);
        const bool rightOk = (after >= b.s.size()) ||
                             !(is_ident_char(b.s[after]) || b.s[after] == '-');
        if (!leftOk || !rightOk) { scan = after; continue; }
        size_t j = after;
        while (j < b.s.size() && (b.s[j] == ' ' || b.s[j] == '\t')) ++j;
        if (j < b.s.size() && (b.s[j] == '"' || b.s[j] == '\'')) ++j;   // "key": ...
        while (j < b.s.size() && (b.s[j] == ' ' || b.s[j] == '\t')) ++j;
        if (j >= b.s.size() || (b.s[j] != '=' && b.s[j] != ':')) { scan = after; continue; }
        ++j;
        while (j < b.s.size() && (b.s[j] == ' ' || b.s[j] == '\t')) ++j;
        bool quoted = false;
        if (j < b.s.size() && (b.s[j] == '"' || b.s[j] == '\'')) { quoted = true; ++j; }
        const size_t vstart = j;
        size_t e = j;
        while (e < b.s.size()) {
            const char c = b.s[e];
            if (quoted) { if (c == '"' || c == '\'' || c == '\r' || c == '\n') break; }
            else if (c == '&' || c == '"' || c == '\'' || c == ',' || c == '}' || c == ';' ||
                     c == '\r' || c == '\n' || c == ' ' || c == '\t') break;
            ++e;
        }
        if (e > vstart && (e - vstart) >= minValue &&
            b.s.compare(vstart, e - vstart, "<redacted>") != 0) {
            b.replace(vstart, e, "<redacted>");
            if (st) ++st->credential_kv;
            scan = vstart + 10;
        } else {
            scan = vstart;
            if (scan <= hit) scan = after;
        }
    }
}

// 规则 8：用户目录名 → <user>（路径结构保留）
inline void mask_user_paths(Buf& b, RedactStats* st) {
    static const char* kRoots[] = {"\\users\\", "/users/", "/home/",
                                   "\\documents and settings\\"};
    size_t scan = 0;
    for (;;) {
        size_t hit = 0, rlen = 0;
        if (!find_min(b, kRoots, sizeof(kRoots) / sizeof(kRoots[0]), scan, hit, rlen)) break;
        const size_t start = hit + rlen;
        size_t e = start;
        while (e < b.s.size() && b.s[e] != '\\' && b.s[e] != '/' && b.s[e] != '"' &&
               b.s[e] != '\'' && b.s[e] != ' ' && b.s[e] != '\r' && b.s[e] != '\n') ++e;
        if (e > start && b.s.compare(start, e - start, "<user>") != 0) {
            b.replace(start, e, "<user>");
            if (st) ++st->user_path;
            scan = start + 6;
        } else {
            scan = hit + rlen + 1;
        }
    }
}

// 规则 9：邮箱本地部分 → <user>，域名保留
inline void mask_emails(Buf& b, RedactStats* st) {
    size_t at = 0;
    for (;;) {
        const size_t p = b.s.find('@', at);
        if (p == std::string::npos) break;
        size_t a = p;
        while (a > 0 && (is_ident_char(b.s[a - 1]) || b.s[a - 1] == '.' || b.s[a - 1] == '-' ||
                         b.s[a - 1] == '+' || b.s[a - 1] == '%')) --a;
        size_t z = p + 1;
        while (z < b.s.size() && (is_ident_char(b.s[z]) || b.s[z] == '.' || b.s[z] == '-')) ++z;
        const size_t dot = b.s.find('.', p + 1);
        const bool looksMail = (z > p + 2) && (dot != std::string::npos) && (dot < z) && (p - a >= 2);
        if (looksMail && b.s.compare(a, p - a, "<user>") != 0) {
            b.replace(a, p, "<user>");
            if (st) ++st->email;
            at = a + 7;
        } else {
            at = p + 1;
        }
    }
}

}  // namespace detail

// ---- 公开入口 -------------------------------------------------------------

// 任何要进诊断包 / 反馈 payload 的文本都必须过这里。
// 幂等：redact(redact(x)) == redact(x)（替换串本身不会再被规则命中）。
inline std::string redact(const std::string& in, RedactStats* st = nullptr) {
    detail::Buf b(in);
    detail::mask_prefixed(b, st);      // 1~4 先做：先把整段密钥吃掉，后面的规则看不到它
    detail::mask_headers(b, st);       // 5
    detail::mask_bearer(b, st);        // 6（header 已吃掉的值不会再被当成裸 Bearer）
    // 7：显式凭据键名。最短值长 1（有值就遮），键名区分靠边界判定
    static const char* kKeys[] = {"api_key", "apikey", "api-key", "x-api-key", "token",
                                  "access_token", "refresh_token", "password", "passwd",
                                  "secret", "client_secret", "gh_token"};
    for (const char* k : kKeys) detail::mask_kv(b, k, std::strlen(k), 1, st);
    // 7b：裸 key / auth —— 只有**长值**才当凭据（偏离上游，见文件头「偏离 1」）
    detail::mask_kv(b, "key", 3, 32, st);
    detail::mask_kv(b, "auth", 4, 32, st);
    detail::mask_user_paths(b, st);    // 8
    detail::mask_emails(b, st);        // 9
    return std::move(b.s);
}

// 规则名清单（写进 diag.json 的 redaction.rules，也是 tests 断言的对象）
inline std::vector<std::string> redaction_rules() {
    return {"openai_key",  "github_token", "aws_key",       "slack_token",  "auth_header",
            "bearer_token", "credential_kv", "user_path",   "email"};
}

// 给人看的脱敏说明（诊断包 README.txt 用；纯文本，不含 markdown）
//
// ★ 这段文本**自己也会被 redact() 过一遍**（诊断包里所有条目一视同仁，不给例外）。
//   所以措辞必须做到「不会命中自己的规则」，否则文档会被自己改坏 —— 2026-10-27 实测
//   连踩两次，两条都固化成了 tests 的 E 段（谁改坏就红）：
//     ① 原来写 "Authorization: / Proxy-Authorization: …"，被 auth_header 规则整行吃成
//        "Authorization: <redacted>"
//     ② 原来写 `/Users/<名>/`（想给用户看路径格式），被 user_path 规则把 `<名>` 换成
//        `<user>` —— 于是「讲规则的文本」和「实际输出」对不上。
//   修法：规则 5/6/8 的描述里**不出现「键名+冒号+值」或任何真实路径字面量**，
//         只描述"哪一类位置"，把具体形态交给单测去证明。
inline std::string redaction_summary_zh() {
    return
        "1) openai_key      sk-… 形态密钥（sk-proj- / sk-live- … 整段替换）\n"
        "2) github_token    ghp_ / gho_ / ghu_ / ghs_ / ghr_ / github_pat_ 开头\n"
        "3) aws_key         AKIA…\n"
        "4) slack_token     xoxb-… / xoxp-…\n"
        "5) auth_header     请求头 Authorization、Proxy-Authorization、X-Api-Key、Cookie\n"
        "                   后面跟的值（整段吃掉，直到行尾或引号/分号）\n"
        "6) bearer_token    HTTP 认证方案 Bearer 后面跟的 token（中间至少一个空格才算）\n"
        "7) credential_kv   api_key / token / access_token / password / secret / client_secret 等\n"
        "                   后面跟的值（k=v 与 \"k\": \"v\" 两种写法都认）\n"
        "8) user_path       用户目录前缀（macOS 家目录、Linux home、Windows 用户目录）后面的\n"
        "                   用户名 → <user>；路径其余层级原样保留，便于判断当时用的哪个位置\n"
        "9) email           邮箱本地部分 → <user>，域名保留\n"
        "被替换的值一律写 <redacted>，用户目录名写 <user>；键名与路径结构保留。\n"
        "注：裸 key / auth 只有值达到 32 字符才按凭据处理（真实密钥远长于此，"
        "而封面缓存键这类短值必须留作诊断证据）。";
}

}  // namespace rta::feedback
