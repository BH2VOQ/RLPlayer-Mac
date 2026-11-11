// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// feedback_api.h — 反馈后台（rlplayer.rainlain.com /api/v1/feedback/macos）纯逻辑层
//
// ===========================================================================
// 为什么有这么一层（2026-11-11）
//
// 新后台的接口是**线上实测过**的协议：字段名、字节上限、状态码语义都定死了。
// 如果把这些判断散落在宿主里（libcurl 调用点、ObjC++ UI 代码），后果是三重的：
//   ① 单测跑不到 —— 只能靠"真机点一下看看"来验证，等于没有回归；
//   ② 上限漂移 —— 后台把 textBytes 从 16384 调小、客户端没跟，用户看到的是 413；
//   ③ 判据含糊 —— "200 就算成功"这种错误在真实世界里会发生（后台约定 200 只用于
//      幂等重放，业务失败也可以带 200 + ok:false）。
//
// 所以本层只做四件事，且**都是纯函数**：
//   校验 → 生成请求体(JSON) → 解析响应(JSON) → 错误分类(中文文案)
// 不发起网络、不读写文件、不含 ObjC / 平台类型。宿主拿到 std::string 去跑 libcurl 即可。
//
// ===========================================================================
// 判据要点（细节见 tests/test_feedback_api.cpp，那边逐条钉死）
//
//   • 请求体：字段必须是 text / version / os / client / diag / idempotency_key 六个；
//     diag 是 base64(原始 diag_json)，**解码后逐字节等于输入**（后台按解码后判 8 MiB）。
//   • 文本：先做 UTF-8 清洗（非法序列 → U+FFFD），再按**字节**判空与上限。
//     清洗而非拒绝：用户粘贴的半截 emoji 不值得让整条反馈发不出去。
//   • version / os：按**字符**截断，绝不切半个多字节字符（切一半的 UTF-8 会被后台拒）。
//   • 响应：**HTTP 状态不能当成功**。只有 body 里 ok==true 才算成功；200 + ok:false 是失败。
//     非 JSON（nginx 的 HTML 501）必须 parsed=false，不许把 Json 的 Num 类型当对象。
//   • 错误文案：中文、可直接显示，且**只放 HTTP 码与服务端 error 摘要**，
//     绝不放 URL / 后台域名 / token（那些会进日志与截图，等于外泄）。
//
// ⚠️ 有意如此的两处：
//   1) 未勾选 attach_diag 时，即使调用方塞了 diag_json 也不附带 —— 用户取消勾选后
//      "偷偷带上诊断包"是隐私事故，不是便利。
//   2) 请求体故意只发 6 个字段（不多发 schema/时间戳之类）：后台对未知字段的处理
//      没有承诺，多一个字段就可能变成 400。
// ===========================================================================
#pragma once

#include <cstddef>
#include <cstdio>
#include <string>

#include "net/install_id.h"
#include "net/json.h"

namespace rta::feedback {

// ---- 协议常量（逐字一致；改一个字就等于换了接口）--------------------------

inline constexpr const char* kFeedbackHost     = "rlplayer.rainlain.com";
inline constexpr const char* kFeedbackBaseUrl  = "https://rlplayer.rainlain.com";
inline constexpr const char* kFeedbackWatchdogUrl =
    "https://rlplayer.rainlain.com/api/v1/feedback/macos/watchdog";
inline constexpr const char* kFeedbackUploadUrl =
    "https://rlplayer.rainlain.com/api/v1/feedback/macos";
inline constexpr const char* kFeedbackTicketUrlPrefix =
    "https://rlplayer.rainlain.com/api/v1/feedback/macos/ticket/";

inline constexpr std::size_t kFeedbackMaxTextBytes = 16384;                 // 文本上限（字节）
inline constexpr std::size_t kFeedbackMaxDiagBytes = 8 * 1024 * 1024;        // 诊断包上限（解码后字节）
inline constexpr std::size_t kFeedbackMaxVersionChars = 80;                  // 按**字符**
inline constexpr std::size_t kFeedbackMaxOsChars      = 120;                 // 按**字符**
inline constexpr std::size_t kFeedbackMaxClientChars  = 160;                 // 安装 ID 上限（字符）
inline constexpr std::size_t kFeedbackMinKeyChars     = 8;                   // 幂等键最短
inline constexpr std::size_t kFeedbackMaxKeyChars     = 160;                 // 幂等键最长
inline constexpr int kFeedbackWatchdogTimeoutMs = 10000;                     // 探活超时（毫秒）
inline constexpr int kFeedbackUploadTimeoutMs   = 120000;                    // 上传超时（毫秒）

namespace impl {

// ASCII 空白：判"全空白"与诊断包的"只有空白"都只认这个集合。
// 故意**不含** U+3000（全角空格）：中文正文里它是有效字符，判空会误杀。
inline bool is_ascii_space(char c) {
    return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f';
}

inline std::string trim_ascii(const std::string& s) {
    std::size_t a = 0;
    std::size_t b = s.size();
    while (a < b && is_ascii_space(s[a])) ++a;
    while (b > a && is_ascii_space(s[b - 1])) --b;
    return s.substr(a, b - a);
}

inline void append_replacement(std::string& out) { out += "\xEF\xBF\xBD"; }   // U+FFFD

// UTF-8 清洗：合法序列原样搬走，非法序列替换成 U+FFFD。
// 采用「最大子部分」策略：一个被截断/越界的多字节序列只产生**一个** U+FFFD，
// 因此 "\xE4\xBD"（3 字节序列只剩 2 字节）→ 一个 U+FFFD，而不是两个。
inline std::string clean_utf8(const std::string& in) {
    std::string out;
    out.reserve(in.size());
    const std::size_t n = in.size();
    std::size_t i = 0;
    while (i < n) {
        const unsigned char c = (unsigned char)in[i];
        if (c < 0x80) { out += (char)c; ++i; continue; }

        // 起始字节 → 期望长度。0x80..0xC1 与 0xF5..0xFF 都不是合法起始字节
        // （C0/C1 只会出现在过度长编码里，直接拒）。
        std::size_t need = 0;
        if (c >= 0xC2 && c <= 0xDF) need = 2;
        else if (c >= 0xE0 && c <= 0xEF) need = 3;
        else if (c >= 0xF0 && c <= 0xF4) need = 4;
        if (need == 0) { append_replacement(out); ++i; continue; }

        // 第二字节要更严：排除过度长编码（E0 A0..）、代理区（ED > 9F）、> U+10FFFF（F4 > 8F）。
        if (i + 1 >= n) { append_replacement(out); i = n; break; }
        const unsigned char c1 = (unsigned char)in[i + 1];
        bool ok = (c1 >= 0x80 && c1 <= 0xBF);
        if (ok && need == 3) ok = !(c == 0xE0 && c1 < 0xA0) && !(c == 0xED && c1 > 0x9F);
        if (ok && need == 4) ok = !(c == 0xF0 && c1 < 0x90) && !(c == 0xF4 && c1 > 0x8F);
        if (!ok) { append_replacement(out); ++i; continue; }

        // 后续续字节：中途断开就把已经确认的部分当一个 U+FFFD 吃掉（最大子部分）
        std::size_t k = 2;
        while (k < need) {
            if (i + k >= n) break;
            const unsigned char cc = (unsigned char)in[i + k];
            if (cc < 0x80 || cc > 0xBF) break;
            ++k;
        }
        if (k < need) { append_replacement(out); i += k; continue; }
        out.append(in, i, need);
        i += need;
    }
    return out;
}

// 按**字符**（码点）截断。合法 UTF-8 序列整段保留；遇到非法字节按 1 个"字符"处理
// （这种串本来就不该出现在 version/os，截断只是兜底，不负责修复）。
inline std::string truncate_chars(const std::string& s, std::size_t max_chars) {
    std::size_t chars = 0;
    std::size_t i = 0;
    const std::size_t n = s.size();
    while (i < n) {
        if (chars == max_chars) break;
        const unsigned char c = (unsigned char)s[i];
        std::size_t need = 1;
        if (c >= 0xC2 && c <= 0xDF) need = 2;
        else if (c >= 0xE0 && c <= 0xEF) need = 3;
        else if (c >= 0xF0 && c <= 0xF4) need = 4;
        // 只有整段都在（且都是续字节）才整段前进，否则当成单字节字符
        if (need > 1) {
            if (i + need > n) need = 1;
            else {
                for (std::size_t k = 1; k < need; ++k) {
                    const unsigned char cc = (unsigned char)s[i + k];
                    if (cc < 0x80 || cc > 0xBF) { need = 1; break; }
                }
            }
        }
        i += need;
        ++chars;
    }
    return s.substr(0, i);
}

// JSON 字符串转义（不含外层引号）。
// 必须覆盖：双引号、反斜杠、\n \r \t \b \f、其它 <0x20 控制字符（\u00XX，大写 hex）。
// 中文与 emoji **不转 \u**：后台按 UTF-8 计字节，转义只会让体积膨胀。
inline std::string json_escape(const std::string& s) {
    static const char kHex[] = "0123456789ABCDEF";
    std::string o;
    o.reserve(s.size() + 16);
    for (char ch : s) {
        const unsigned char c = (unsigned char)ch;
        switch (c) {
            case '"':  o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            case '\n': o += "\\n";  break;
            case '\r': o += "\\r";  break;
            case '\t': o += "\\t";  break;
            case '\b': o += "\\b";  break;
            case '\f': o += "\\f";  break;
            default:
                if (c < 0x20) {
                    o += "\\u00";
                    o += kHex[(c >> 4) & 0x0F];
                    o += kHex[c & 0x0F];
                } else {
                    o += (char)c;
                }
        }
    }
    return o;
}

// base64（RFC4648 标准字母表 + '=' 填充，无换行）
inline std::string base64(const std::string& raw) {
    static const char kTbl[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string o;
    o.reserve(((raw.size() + 2) / 3) * 4);
    std::size_t i = 0;
    const std::size_t n = raw.size();
    while (i + 3 <= n) {
        const unsigned v = ((unsigned)(unsigned char)raw[i] << 16) |
                           ((unsigned)(unsigned char)raw[i + 1] << 8) |
                           (unsigned)(unsigned char)raw[i + 2];
        o += kTbl[(v >> 18) & 0x3F];
        o += kTbl[(v >> 12) & 0x3F];
        o += kTbl[(v >> 6) & 0x3F];
        o += kTbl[v & 0x3F];
        i += 3;
    }
    const std::size_t rest = n - i;
    if (rest == 1) {
        const unsigned v = (unsigned)(unsigned char)raw[i] << 16;
        o += kTbl[(v >> 18) & 0x3F];
        o += kTbl[(v >> 12) & 0x3F];
        o += "==";
    } else if (rest == 2) {
        const unsigned v = ((unsigned)(unsigned char)raw[i] << 16) |
                           ((unsigned)(unsigned char)raw[i + 1] << 8);
        o += kTbl[(v >> 18) & 0x3F];
        o += kTbl[(v >> 12) & 0x3F];
        o += kTbl[(v >> 6) & 0x3F];
        o += '=';
    }
    return o;
}

inline bool is_ident_lower(char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

// 把服务端文本洗成「可安全显示 / 可安全进日志」的一句话：
//   ① 控制字符 → 空格（防止把终端/日志搅乱）
//   ② 任何 scheme://xxx 形式的 URL 整段 → <url>
//   ③ 后台域名 → <host>（transport_error 里常带主机名）
//   ④ token= / secret: / password= 之类的值 → <redacted>
//   ⑤ 超长截断（服务端 error 可能是整段 HTML，塞进 UI 会撑爆）
inline std::string scrub(const std::string& in, std::size_t max_chars) {
    std::string s = in.substr(0, max_chars > 0 ? max_chars * 4 : 0);   // 先粗截，别对 8KB body 反复扫描
    for (char& c : s) {
        const unsigned char u = (unsigned char)c;
        if (u < 0x20 || u == 0x7F) c = ' ';
    }

    // ① URL：找到 "://"，把 scheme 起点到 URL 结尾（空白或引号）整段换成 <url>
    for (;;) {
        const std::size_t sep = s.find("://");
        if (sep == std::string::npos) break;
        std::size_t a = sep;
        while (a > 0 && !is_ascii_space(s[a - 1]) && s[a - 1] != '"' && s[a - 1] != '\'' &&
               s[a - 1] != '(' && s[a - 1] != '<')
            --a;
        std::size_t b = sep + 3;
        while (b < s.size() && !is_ascii_space(s[b]) && s[b] != '"' && s[b] != '\'' && s[b] != ')' &&
               s[b] != '>' && s[b] != ',')
            ++b;
        s.replace(a, b - a, "<url>");
    }

    // ② 后台主机名（有的 transport_error 只给主机，不给 URL）
    for (const char* host : {kFeedbackHost, "rainlain.com"}) {
        const std::string h(host);
        for (;;) {
            const std::size_t p = s.find(h);
            if (p == std::string::npos) break;
            s.replace(p, h.size(), "<host>");
        }
    }

    // ③ 头形态：Authorization / Proxy-Authorization / Bearer / X-Api-Key / Cookie
    //    服务端 error 里带 "Authorization: Bearer eyJ..." 时，键值规则（要求键后紧跟 = 或 :）
    //    抓不到 "Authorization: ..." 整段，必须单独处理，否则凭据会进用户可见文案。
    {
        std::string low = s;
        for (char& c : low) {
            const unsigned char u = (unsigned char)c;
            if (u >= 'A' && u <= 'Z') c = (char)(u - 'A' + 'a');
        }
        // (a) "<header-name>: <value>" → 值抹掉，键名保留（保留才能看出"当时带了什么"）
        static const char* kHdrs[] = {"proxy-authorization", "authorization", "x-api-key",
                                      "api-key", "x-auth-token", "cookie"};
        for (const char* hname : kHdrs) {
            const std::size_t hlen = std::string(hname).size();
            std::size_t from = 0;
            for (;;) {
                const std::size_t hit = low.find(hname, from);
                if (hit == std::string::npos) break;
                from = hit + hlen;
                if (hit > 0 && is_ident_lower(s[hit - 1])) continue;
                std::size_t colon = hit + hlen;
                while (colon < s.size() && is_ascii_space(s[colon])) ++colon;
                if (colon >= s.size() || s[colon] != ':') continue;
                std::size_t v = colon + 1;
                while (v < s.size() && is_ascii_space(s[v])) ++v;
                std::size_t e = v;
                while (e < s.size() && !is_ascii_space(s[e]) && s[e] != ',' && s[e] != ';') ++e;
                if (e == v) continue;
                // 值若以认证方案名开头（Bearer / Basic / …），方案名本身不是凭据、
                // 但与值连在一起，单独抹值会留下 "Authorization: Bearer <redacted>"
                // 这种半截形态。整段（方案名 + 值）一起替换，输出 "Authorization: <redacted>"。
                {
                    std::string word = s.substr(v, e - v);
                    for (char& c : word) {
                        const unsigned char u = (unsigned char)c;
                        if (u >= 'A' && u <= 'Z') c = (char)(u - 'A' + 'a');
                    }
                    static const char* kSchemes[] = {"bearer", "basic", "digest", "negotiate", "token"};
                    bool is_scheme = false;
                    for (const char* sc : kSchemes)
                        if (word == sc) is_scheme = true;
                    if (is_scheme) {
                        std::size_t v2 = e;
                        while (v2 < s.size() && is_ascii_space(s[v2])) ++v2;
                        std::size_t e2 = v2;
                        while (e2 < s.size() && !is_ascii_space(s[e2]) && s[e2] != ',' && s[e2] != ';') ++e2;
                        e = e2;
                    }
                }
                s.replace(v, e - v, "<redacted>");
                low.replace(v, e - v, "<redacted>");
                from = v + 10;
            }
        }
        // (b) 裸 "Bearer <token>"（≥6 字符才算凭据，避免 "Bearer abc" 这类误伤）
        low = s;
        for (char& c : low) {
            const unsigned char u = (unsigned char)c;
            if (u >= 'A' && u <= 'Z') c = (char)(u - 'A' + 'a');
        }
        std::size_t from = 0;
        for (;;) {
            const std::size_t hit = low.find("bearer", from);
            if (hit == std::string::npos) break;
            from = hit + 6;
            std::size_t v = hit + 6;
            const std::size_t spaces = v;
            while (v < s.size() && s[v] == ' ') ++v;
            if (v == spaces) continue;                 // 必须有空格（bearer_token 不算）
            std::size_t e = v;
            while (e < s.size() && !is_ascii_space(s[e]) && s[e] != ',' && s[e] != ';') ++e;
            if (e - v < 6) continue;
            s.replace(v, e - v, "<redacted>");
            low.replace(v, e - v, "<redacted>");
            from = v + 10;
        }
    }

    // ④ 凭据键值：键名大小写不敏感，值一直吃到空白 / 引号 / 逗号 / 分号 / &
    static const char* kKeys[] = {"access_token", "refresh_token", "client_secret", "api_key",
                                  "apikey", "gh_token", "password", "passwd", "secret", "token"};
    for (const char* key : kKeys) {
        const std::size_t klen = std::string(key).size();
        std::size_t from = 0;
        for (;;) {
            // 大小写不敏感查找：先在小写副本上找，再回到原串定位
            std::string low = s;
            for (char& c : low) {
                const unsigned char u = (unsigned char)c;
                if (u >= 'A' && u <= 'Z') c = (char)(u - 'A' + 'a');
            }
            const std::size_t hit = low.find(key, from);
            if (hit == std::string::npos) break;
            from = hit + klen;
            // 键名边界：前面不能是标识符字符（避免 hotkey / monkey 误伤）
            if (hit > 0 && is_ident_lower(s[hit - 1])) continue;
            if (hit + klen >= s.size()) continue;
            const char sepch = s[hit + klen];
            if (sepch != '=' && sepch != ':') continue;
            std::size_t v = hit + klen + 1;
            while (v < s.size() && is_ascii_space(s[v])) ++v;
            if (v < s.size() && (s[v] == '"' || s[v] == '\'')) ++v;
            std::size_t e = v;
            while (e < s.size() && !is_ascii_space(s[e]) && s[e] != '"' && s[e] != '\'' &&
                   s[e] != ',' && s[e] != ';' && s[e] != '&')
                ++e;
            if (e == v) continue;                 // 空值不动（没有可抹的东西）
            s.replace(v, e - v, "<redacted>");
            from = v + 10;
        }
    }

    if (s.size() > max_chars) {
        s.resize(max_chars);
        s += "…";
    }
    return s;
}

// 十进制定宽数字（避免 <cstdio> 的 snprintf 在 -Wall 下的格式警告，也比 iostream 快）
inline void append_u32_padded(std::string& out, unsigned long long v, int width) {
    char buf[24];
    int n = 0;
    do {
        buf[n++] = (char)('0' + (int)(v % 10));
        v /= 10;
    } while (v != 0);
    while (n < width) buf[n++] = '0';
    while (n > 0) out += buf[--n];
}

}  // namespace impl

// ---- 上传输入 / 输出 ------------------------------------------------------

struct FeedbackUploadInput {
    std::string text;
    std::string version;
    std::string os;
    std::string client;            // 安装 ID（install_id_valid）
    std::string diag_json;         // 诊断包原文（JSON 文本），diag 字段是它的 base64
    std::string idempotency_key;
    bool attach_diag = false;      // 未勾选时即使有 diag_json 也不发
};

struct FeedbackUploadBody {
    bool ok = false;
    std::string json;              // ok 时是可直接 POST 的请求体
    std::string code;              // 失败码（empty_text / text_too_long / …）
    std::string error;             // 可直接给用户看的中文
    std::size_t text_bytes = 0;    // 清洗后的真实字节数
    std::size_t diag_bytes = 0;    // 诊断包**解码后**的字节数
};

// 前置声明：build_feedback_upload() 要用它，但定义放在文件后半段（与 base64/幂等键生成
// 放在一起更好读）。头文件内 inline 函数的前置声明不引入额外符号，也没有全局状态。
inline bool feedback_idempotency_key_valid(const std::string& key);

// 校验顺序是有意的：先文本（用户最可能出问题的地方）、再元信息、最后附件。
// 这样用户改一处就能往下走，不会修完 version 又被告知 text 太长。
inline FeedbackUploadBody build_feedback_upload(const FeedbackUploadInput& in) {
    FeedbackUploadBody r;

    // 1) text：清洗 → 判空 → 判上限（都按字节）
    const std::string text = impl::clean_utf8(in.text);
    r.text_bytes = text.size();
    if (impl::trim_ascii(text).empty()) {
        r.code = "empty_text";
        r.error = "反馈内容为空：请先写下遇到的问题（可以只写一两句话）。";
        return r;
    }
    if (r.text_bytes > kFeedbackMaxTextBytes) {
        r.code = "text_too_long";
        r.error = "反馈内容过长：上限 " + std::to_string((unsigned long long)kFeedbackMaxTextBytes) +
                  " 字节，请精简后再提交。";
        return r;
    }

    // 2) version / os：按字符截断，空则拒
    if (in.version.empty()) {
        r.code = "bad_version";
        r.error = "缺少版本号：无法定位问题出在哪个版本上。";
        return r;
    }
    if (in.os.empty()) {
        r.code = "bad_os";
        r.error = "缺少系统信息：无法判断问题是否与系统版本有关。";
        return r;
    }
    const std::string version = impl::truncate_chars(in.version, kFeedbackMaxVersionChars);
    const std::string os      = impl::truncate_chars(in.os, kFeedbackMaxOsChars);

    // 3) client：必须已是规范安装 ID（长度上限自然由格式保证）
    if (!install_id_valid(in.client)) {
        r.code = "bad_client";
        r.error = "安装 ID 无效：本机安装标识缺失或格式不对，请重新启动应用后再试。";
        return r;
    }

    // 4) 幂等键：字符集与长度都按后台规则本地先判，省一次必然失败的请求
    if (!feedback_idempotency_key_valid(in.idempotency_key)) {
        r.code = "bad_key";
        r.error = "内部错误：提交标识无效（幂等键格式不对），请重新提交。";
        return r;
    }

    // 5) 诊断包：体积优先于格式（都超时应该先告诉用户"太大了"）
    std::string diag_b64;
    if (in.attach_diag) {
        const std::string raw = impl::trim_ascii(in.diag_json);
        if (raw.empty()) {
            r.code = "diag_empty";
            r.error = "已勾选附带诊断包，但诊断内容为空：请取消勾选，或重新生成诊断包。";
            return r;
        }
        // ⚠️ 体积按**原串**判，不是按 trim 后的 raw：diag 字段是 base64(原串)，
        // 后台解码后看到的是原串（含首尾空白）。用 trim 后的长度判会放过
        // "8 MiB + 若干尾部空白" 的包 —— 本地绿灯、后台 413，最难查的那种不一致。
        if (in.diag_json.size() > kFeedbackMaxDiagBytes) {
            r.code = "diag_too_large";
            r.error = "诊断包过大：上限 8 MiB，请取消勾选附带诊断包后提交。";
            return r;
        }
        const char head = raw[0];
        if (head != '{' && head != '[') {
            r.code = "diag_not_json";
            r.error = "诊断包格式不对：诊断内容必须是 JSON 文本。";
            return r;
        }
        diag_b64 = impl::base64(in.diag_json);   // 逐字节编码**原串**，含前导空白
        r.diag_bytes = in.diag_json.size();
    }

    // 6) 组装请求体：只有这 6 个字段
    std::string& j = r.json;
    j.reserve(text.size() + version.size() + os.size() + in.client.size() +
              in.idempotency_key.size() + diag_b64.size() + 96);
    j += "{\"text\":\"";
    j += impl::json_escape(text);
    j += "\",\"version\":\"";
    j += impl::json_escape(version);
    j += "\",\"os\":\"";
    j += impl::json_escape(os);
    j += "\",\"client\":\"";
    j += impl::json_escape(in.client);
    j += "\",\"diag\":\"";
    j += diag_b64;
    j += "\",\"idempotency_key\":\"";
    j += impl::json_escape(in.idempotency_key);
    j += "\"}";

    r.ok = true;
    return r;
}

// ---- 上传响应 -------------------------------------------------------------

struct FeedbackUploadReply {
    bool parsed = false;          // body 是 JSON 对象（不代表成功）
    bool ok = false;              // body.ok == true（不代表 HTTP 2xx）
    bool diag_stored = false;
    int status = 0;
    std::string id;               // 工单号；可能为空（调用方显示「无工单号」）
    std::string code;
    std::string error;
};

// 关键判据：**成功只看 body.ok**。后台约定 200 只用于幂等重放，业务失败也可能带 200。
inline FeedbackUploadReply parse_feedback_upload_reply(int http_status, const std::string& body) {
    FeedbackUploadReply r;
    r.status = http_status;

    const rta::net::Json j = rta::net::json_parse(body);
    // 必须是**对象**：nginx 的 HTML 错误页会被 json_parse 解析成 Num，
    // 只判 "非 Null" 会把 HTML 当成合法响应。
    if (j.type != rta::net::Json::Obj) return r;
    r.parsed = true;

    const rta::net::Json& jok = j["ok"];
    r.ok = (jok.type == rta::net::Json::Bool && jok.b);

    const rta::net::Json& jdiag = j["diagStored"];
    r.diag_stored = (jdiag.type == rta::net::Json::Bool && jdiag.b);

    const rta::net::Json& jid = j["id"];
    if (jid.type == rta::net::Json::Str) r.id = jid.str;

    const rta::net::Json& jcode = j["code"];
    if (jcode.type == rta::net::Json::Str) r.code = jcode.str;

    const rta::net::Json& jerr = j["error"];
    if (jerr.type == rta::net::Json::Str) r.error = jerr.str;

    return r;
}

// ---- watchdog（探活 / 拉服务端上限）---------------------------------------

struct FeedbackWatchdogInfo {
    bool reachable = false;
    int status = 0;
    std::string error;
    // 默认值 = 协议当前值。服务端若下发更小的值则采用服务端的（否则客户端会先撞 413）
    std::size_t text_bytes = kFeedbackMaxTextBytes;
    std::size_t diag_bytes = kFeedbackMaxDiagBytes;
    int rate_per_minute = 5;
    int retention_days = 90;
    int delete_window_days = 7;
};

inline FeedbackWatchdogInfo parse_feedback_watchdog(int http_status, const std::string& body) {
    FeedbackWatchdogInfo r;
    r.status = http_status;

    const rta::net::Json j = rta::net::json_parse(body);
    const bool is_obj = (j.type == rta::net::Json::Obj);
    const rta::net::Json& jok = j["ok"];
    const bool ok_flag = (jok.type == rta::net::Json::Bool && jok.b);

    if (!is_obj) {
        r.error = "反馈服务响应无法解析（HTTP " + std::to_string(http_status) + "）：请稍后重试。";
        return r;
    }
    if (!ok_flag) {
        r.error = "反馈服务当前不可用（HTTP " + std::to_string(http_status) + "）";
        const rta::net::Json& jerr = j["error"];
        if (jerr.type == rta::net::Json::Str && !jerr.str.empty())
            r.error += "：" + impl::scrub(jerr.str, 160);
        else
            r.error += "：请稍后重试。";
        return r;
    }

    r.reachable = true;

    const rta::net::Json& lim = j["limits"];
    if (lim.type == rta::net::Json::Obj) {
        const rta::net::Json& tb = lim["textBytes"];
        if (tb.type == rta::net::Json::Num && tb.n() > 0) r.text_bytes = (std::size_t)tb.n();
        const rta::net::Json& db = lim["diagBytes"];
        if (db.type == rta::net::Json::Num && db.n() > 0) r.diag_bytes = (std::size_t)db.n();
        const rta::net::Json& rpm = lim["ratePerMinute"];
        if (rpm.type == rta::net::Json::Num && rpm.n() > 0) r.rate_per_minute = (int)rpm.n();
    }
    const rta::net::Json& ret = j["retentionDays"];
    if (ret.type == rta::net::Json::Num && ret.n() > 0) r.retention_days = (int)ret.n();
    const rta::net::Json& del = j["deleteWindowDays"];
    if (del.type == rta::net::Json::Num && del.n() > 0) r.delete_window_days = (int)del.n();

    return r;
}

// ---- base64 / 幂等键 -----------------------------------------------------

inline std::string feedback_base64(const std::string& raw) { return impl::base64(raw); }

// 幂等键：fb-YYYYMMDD-XXXXXXXX（UTC 日期 + 8 位大写 hex）。
// 字符集落在 [A-Za-z0-9._:-] 内，长度 19，天然满足 8..160。
// 同一秒内重试要传同一个 key（后台据此幂等重放同一工单）；random32 由宿主给。
inline std::string make_feedback_idempotency_key(long long epoch_seconds, unsigned int random32) {
    // 时钟倒退/未同步的机器可能给出负值；夹到 epoch 0，避免产生非法日期字符串。
    const long long secs = epoch_seconds < 0 ? 0 : epoch_seconds;
    const long long days = secs / 86400;

    // Howard Hinnant 的 civil_from_days：把"自 1970-01-01 起的天数"换成公历年月日。
    // 自己算而不是用 localtime/gmtime —— 那两个依赖 TZ 环境且不是线程安全的，
    // 而本层要求纯函数、可确定性单测。
    const long long z = days + 719468;
    const long long era = (z >= 0 ? z : z - 146096) / 146097;
    const unsigned long long doe = (unsigned long long)(z - era * 146097);
    const unsigned long long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const long long y = (long long)yoe + era * 400;
    const unsigned long long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const unsigned long long mp = (5 * doy + 2) / 153;
    const unsigned long long d = doy - (153 * mp + 2) / 5 + 1;
    const unsigned long long m = mp < 10 ? mp + 3 : mp - 9;
    long long year = y + (m <= 2 ? 1 : 0);
    // 时钟荒谬（year > 9999）时必须夹住：否则年份写成 5 位 ⟹ 键长 22 位、
    // 不再匹配 ^fb-[0-9]{8}-[0-9A-F]{8}$，后台必然拒掉（而且是难查的"偶发失败"）。
    if (year > 9999) year = 9999;
    if (year < 0) year = 1970;

    std::string key = "fb-";
    impl::append_u32_padded(key, (unsigned long long)year, 4);
    impl::append_u32_padded(key, m, 2);
    impl::append_u32_padded(key, d, 2);
    key += '-';
    static const char kHex[] = "0123456789ABCDEF";
    for (int shift = 28; shift >= 0; shift -= 4) key += kHex[(random32 >> shift) & 0x0F];
    return key;
}

// 与后台一致的规则：8..160 字符，字符集 [A-Za-z0-9._:-]。
inline bool feedback_idempotency_key_valid(const std::string& key) {
    if (key.size() < kFeedbackMinKeyChars || key.size() > kFeedbackMaxKeyChars) return false;
    for (char c : key) {
        const bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
                        c == '.' || c == '_' || c == ':' || c == '-';
        if (!ok) return false;
    }
    return true;
}

// ---- 错误分类 -------------------------------------------------------------

struct FeedbackFailure {
    bool retryable = false;   // 宿主可据此决定是否给「重试」按钮
    std::string code;         // 机器可读：优先用服务端 code，没有就给本地默认
    std::string message;      // 中文、可直接显示；绝不含 URL / 域名 / token
};

// 文案原则：
//   ① 先说人话（用户能理解的现象），再给 HTTP 码（便于对照日志）；
//   ② 能给下一步动作的就给（"取消勾选附带诊断包""稍后再试"）；
//   ③ 服务端 error 只做**洗过的摘要**并入，绝不整段塞进 UI。
inline FeedbackFailure describe_feedback_failure(int http_status, const std::string& server_code,
                                                const std::string& server_error, bool timed_out,
                                                const std::string& transport_error) {
    FeedbackFailure f;

    // 服务端说明（洗过、截断），用于附加信息；为空就不附加
    std::string extra;
    if (!server_error.empty()) extra = impl::scrub(server_error, 200);

    auto set_code = [&](const char* fallback) {
        f.code = server_code.empty() ? std::string(fallback) : server_code;
    };
    auto append_extra = [&]() {
        if (!extra.empty()) f.message += " 服务端说明：" + extra;
    };

    if (http_status == 0) {
        // 没拿到 HTTP 状态 = 传输层失败
        if (timed_out) {
            set_code("timeout");
            f.retryable = true;
            f.message = "提交反馈超时：网络较慢或服务端暂时无响应，请稍后再试。";
        } else {
            set_code("network_error");
            f.retryable = true;
            f.message = "无法连接反馈服务：";
            f.message += transport_error.empty() ? std::string("网络不可用")
                                                 : impl::scrub(transport_error, 200);
            f.message += "。请检查网络后重试。";
        }
        return f;
    }

    if (http_status == 400) {
        set_code("bad_request");
        f.retryable = false;
        f.message = "反馈内容或参数不合法（HTTP 400）：服务端未接受本次提交，请检查后重试。";
        append_extra();
        return f;
    }
    if (http_status == 403) {
        set_code("forbidden");
        f.retryable = false;
        f.message = "没有提交反馈的权限（HTTP 403）：可能是安装 ID 与本机不匹配，或被服务端拒绝。";
        append_extra();
        return f;
    }
    if (http_status == 404) {
        set_code("not_found");
        f.retryable = false;
        f.message = "反馈接口不存在（HTTP 404）：服务端接口可能已变更，请更新应用后再试。";
        append_extra();
        return f;
    }
    if (http_status == 413) {
        set_code("request_too_large");
        f.retryable = false;
        f.message = "反馈内容超过服务端限制（HTTP 413）：请缩短正文，或取消勾选附带诊断包后重试。";
        append_extra();
        return f;
    }
    if (http_status == 422) {
        set_code("unsupported_diagnostic");
        f.retryable = false;
        f.message = "服务端无法接受诊断包（HTTP 422）：诊断包必须是 JSON 文本，可取消勾选后重试。";
        append_extra();
        return f;
    }
    if (http_status == 429) {
        set_code("rate_limited");
        f.retryable = true;
        f.message = "提交过于频繁（HTTP 429）：请稍后再试。";
        append_extra();
        return f;
    }
    if (http_status >= 500 && http_status <= 599) {
        set_code("server_error");
        f.retryable = true;
        f.message = "反馈服务暂时不可用（HTTP " + std::to_string(http_status) + "）：请稍后再试。";
        append_extra();
        return f;
    }

    // 其它 4xx（401/405/418…）：状态码本身已经足够定位，不去猜原因
    set_code(("http_" + std::to_string(http_status)).c_str());
    f.retryable = false;
    f.message = "提交未成功（HTTP " + std::to_string(http_status) + "）：请稍后再试或更新应用。";
    append_extra();
    return f;
}

}  // namespace rta::feedback
