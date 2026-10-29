// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// mac_feedback.h — 反馈邮件通道：**纯逻辑层**（正文清洗 / header 注入过滤 / 路径校验 / MIME 拼装）
//
// ======================= 为什么单独拆这一层 =======================
// 真正的"发信"是系统副作用（打开 Mail.app 的撰写窗口），自动化测试里**绝不能**真发出去。
// 但下面这三条是**安全边界**，必须被逐条断言，不能只靠肉眼看：
//   1) 收件人只能是代码常量 —— 页面传什么都不能改变它；
//   2) 用户正文里的 \r\n 不能伪造出 Bcc:/Content-Type: 这类 header（header 注入）；
//   3) 诊断包路径不能指到任意文件（尤其 ~/.ssh / 配置文件）。
// 所以这些判定全部做成**纯 std::string 函数**放本头文件里，由 tests/test_mac_feedback.cpp
// 直接跑（不需要 AppKit、不需要窗口、不会发信）。
//
// ======================= 零凭据（第一优先级）=========================
// 本文件与 mac_feedback.mm 里**没有、也不允许出现**任何 SMTP 服务器 / 账号 / 密码 / 163 授权码。
// 发信走**系统邮件客户端**（NSSharingService / Mail.app），由用户在自己已登录的账户里点发送。
// 理由（用户 2026-10-26 明确的安全约束）：硬编码在二进制里的凭据用 `strings` 就能捞出来，
// 等于把用户邮箱的发信权公开。任何"为了方便"把授权码写进代码的改动都必须被拒绝。
//
// ======================= 本头文件可被纯 C++ 包含 =======================
// 上层 ObjC++（mac_feedback.mm）与纯 C++ 单测都包含它 ⟹ 这里**不许**出现 NSString / NSURL 等
// ObjC 类型。系统集成部分只在 .mm 里。
#pragma once

#include <cstddef>
#include <string>
#include <vector>

namespace rta::feedback {

// ---------------------------------------------------------------------------
// 常量（安全边界的唯一真相源）
// ---------------------------------------------------------------------------

// 反馈收件人：**唯一来源**就是这里。页面不能传、配置不能改、环境变量不能覆盖。
// 即使页面 JS 被注入，也无法把用户写的正文发到攻击者邮箱。
inline constexpr const char* kRecipient = "BH2VOQ@163.com";

// 正文上限（**字符**数，不是字节数 —— 中文用户不该被字节数少算）。
inline constexpr std::size_t kMaxBodyChars = 8000;

// 主题里"系统信息"片段的上限（字符）。
inline constexpr std::size_t kMaxMetaChars = 160;

// 主题固定前缀。
inline constexpr const char* kSubjectPrefix = "[RLPlayer \xE5\x8F\x8D\xE9\xA6\x88]";   // "[RLPlayer 反馈]"

// 附件文件名上限（字节）。
inline constexpr std::size_t kMaxAttachmentNameBytes = 128;

// ---------------------------------------------------------------------------
// UTF-8 工具
// ---------------------------------------------------------------------------

// 返回 s 里"当前字节不是 UTF-8 续字节(10xxxxxx)"的个数 = 字符数（近似但不会把字符切两半）。
// 非法序列按"每字节 1 字符"计，保证任何输入都不会越界。
std::size_t utf8_length(const std::string& s);

// 按**字符边界**截断到最多 max_chars 个字符；绝不把多字节字符切成两半。
std::string utf8_truncate(const std::string& s, std::size_t max_chars);

// 校验 s 是否是合法 UTF-8（严格：拒绝过长编码/代理区/超范围）。
bool utf8_valid(const std::string& s);

// ---------------------------------------------------------------------------
// 正文清洗与截断
// ---------------------------------------------------------------------------
struct BodyResult {
    std::string text;               // 清洗+截断后可直接用的正文
    bool truncated = false;         // 是否发生截断
    std::size_t dropped_chars = 0;  // 被丢掉了多少字符（告知用户用）
    std::size_t control_chars = 0;  // 抹掉了多少个控制字符（含 CR/LF/NUL）
    bool empty_after_clean = false; // 清洗后为空 ⟹ 调用方必须拒绝发信
};

// 清洗用户反馈正文：
//   * 抹掉 NUL 与除 \n / \t 外的全部 C0、DEL 与 C1 控制字符 —— \r 尤其必须死
//     （CRLF 是 RFC 5322 header 的分界，正文里留下 \r\n 就能伪造 header）；
//   * \r\n 与孤立 \r 统一成 \n（保留分段，但不再可能凑出 CRLF）；
//   * 非 UTF-8 的字节序列整段替换成 U+FFFD，避免下游 base64/JSON 出现非法编码；
//   * 按字符数截断到 kMaxBodyChars，截断事实如实回报（绝不静默丢内容）。
BodyResult sanitize_body(const std::string& raw);

// ---------------------------------------------------------------------------
// header 值（主题/文件名等）清洗
// ---------------------------------------------------------------------------

// 比正文更严：**任何**换行（\r、\n、U+2028、U+2029）一律折叠成单个空格，
// 其余控制字符直接删除。返回值保证**不含 \r 与 \n**。
// 这是 header 注入的硬边界 —— 单测会真塞 "\r\nBcc: evil@x" 进来验它被拦。
std::string sanitize_header_value(const std::string& raw, std::size_t max_chars = 200);

// 拼主题：`[RLPlayer 反馈] <meta>`，整体再清洗一遍。
std::string build_subject(const std::string& meta);

// 只取 basename 并清成安全文件名：去掉路径分隔符、控制字符、前导点、".."。
std::string safe_filename(const std::string& raw, const char* fallback = "attachment.bin");

// ---------------------------------------------------------------------------
// 附件路径校验（诊断包）
// ---------------------------------------------------------------------------
struct PathCheck {
    bool ok = false;
    std::string normalized;  // 通过校验的**词法规范化**路径（宿主内部用，不回传页面）
    std::string reason;      // 拒绝原因（中文，可写日志）
};

// 词法规范化：合并重复 '/'、消掉 "."、按栈消掉 ".."（不解析软链、不碰磁盘）。
std::string normalize_path(const std::string& p);

// 校验页面提供的临时文件路径：
//   * 必须绝对（以 '/' 开头）；
//   * 不含 NUL / CR / LF（否则底层 open 会被截断成另一个文件）；
//   * 规范化后必须仍以 temp_root 为前缀（防 "../" 逃逸；比较时要求前缀后是 '/' 或结束，
//     防 "/tmp/rlf" 前缀命中 "/tmp/rlf-evil"）；
//   * 文件名必须以 .zip 结尾（诊断包只有这一个形态）。
// ⚠️ 本函数**不碰磁盘**（不 stat、不解软链）⟹ 可离线测。
//    真开文件前的存在性/普通文件/软链核验，由宿主侧 emit_feedback() 再做一遍。
PathCheck check_attachment_path(const std::string& raw_path, const std::string& temp_root);

// ---------------------------------------------------------------------------
// MIME(.eml) 拼装
// ---------------------------------------------------------------------------
// 用途：
//   (a) 首选发信路径（NSSharingService）失败/不可用时的**兜底产物** —— 把 .eml 存到桌面，
//       用户双击就能在任意邮件客户端里看到填好的收件人/主题/正文/附件；
//   (b) 让"附件真的带上了"这件事能被**离线逐字节断言**（边界符、base64、Content-Disposition）。
// 注意 .eml 只是**草稿**：不含任何认证信息，也不能自己发出去。
struct Attachment {
    std::string filename;      // 只用 basename，内部会过 safe_filename
    std::string data;          // 原始字节（内部 base64）
    std::string content_type;  // 空则用 application/zip
};

// 生成符合 RFC 5322 / MIME 的邮件字节串：
//   * Subject 用 RFC 2047 的 =?UTF-8?B?...?= 编码（中文不乱码，也不会泄漏裸 CRLF）；
//   * 正文与附件一律 base64 ⟹ 长行不会撞 998 字节的硬上限；
//   * 有附件时 multipart/mixed，每个附件 Content-Disposition: attachment，filename 也做 RFC 2231 编码；
//   * X-Unsent: 1（部分客户端据此当草稿打开）；
//   * 所有 header 值再过一次 sanitize_header_value（纵深防御：即使调用方忘了清洗也不会注入）。
// boundary_seed 为空时用固定串（测试可复现）；实际发信时宿主传随机种子避免碰撞。
std::string build_eml(const std::string& to,
                      const std::string& subject,
                      const std::string& body_utf8,
                      const std::vector<Attachment>& attachments,
                      const std::string& boundary_seed = std::string());

// base64 编码，每 76 字符插 CRLF（MIME 对 body/附件的要求）。
std::string base64_mime(const std::string& raw);

// 无折行 base64 —— RFC 2047 header 编码（主题）必须用它，否则 header 里会出现裸 CRLF。
std::string base64_flat(const std::string& raw);

// ===========================================================================
// 原生执行层接口（**定义**在 tools/mac_feedback.mm，需要 AppKit）
//
// 这一段的签名只用 std::string / std::vector ⟹ 纯 C++ 单测也能包含本头文件，
// 只要**不调用**这些函数就不需要链接 .mm。
// ⚠️ 这些函数有系统副作用（写磁盘 / 打开邮件客户端），自动化测试里不许调。
// ===========================================================================

// 主题里的系统信息段："v1.0.5-beta.2 / macOS 27.0.1 / arm64"
std::string system_meta();

// 诊断包临时目录（$TMPDIR/rlplayer-feedback）。页面先把 zip 写进这里，再把路径传上来。
std::string diagnostic_temp_root();

// 确保上面的目录存在。失败时 err 写原因。
bool ensure_diagnostic_temp_root(std::string& err);

// 校验（双层：词法 + 文件系统）并把诊断包读进内存。
// 失败时 err 写人类可读原因，且 out_data/out_name 为空 —— 调用方必须据此拒绝发信。
bool load_diagnostic(const std::string& raw_path, std::string& out_data,
                     std::string& out_name, std::string& err,
                     std::string* out_norm_path = nullptr);

enum class ComposeOutcome {
    Opened,          // 系统邮件撰写窗口已打开（用户仍需自己点「发送」）
    FellBackToEml,   // 共享服务不可用 → 写了 .eml 兜底文件
    Failed           // 连兜底都失败
};

struct ComposeResult {
    ComposeOutcome outcome = ComposeOutcome::Failed;
    std::string detail;             // 人类可读（中文），直接显示给用户
    std::string eml_path;           // 兜底 .eml 的路径（outcome==FellBackToEml 时有值）
    bool recipient_preset = false;  // 收件人是否真的被预填（KVC 是否成功）
    bool subject_preset = false;    // 主题是否真的被预填
};

// 打开系统邮件撰写窗口。**绝不**在这里发送 —— 发送是用户的行为。
//   attachment_paths 必须是已经通过 load_diagnostic() 校验的文件路径。
ComposeResult open_compose_window(const std::string& subject,
                                  const std::string& body_clean,
                                  const std::vector<std::string>& attachment_paths,
                                  const std::string& sender_hint = std::string());

// 把同一封邮件另存成 .eml（兜底/留档用）。成功返回 true 并写 out_path。
bool save_eml_copy(const std::string& subject,
                   const std::string& body_clean,
                   const std::vector<Attachment>& attachments,
                   std::string& out_path, std::string& err);

// ===========================================================================
// 以下是**定义**（inline）—— 单测只需 #include 本头文件即可链接，无需额外 .o
// ===========================================================================

namespace detail {

inline bool is_utf8_continuation(unsigned char c) { return (c & 0xC0) == 0x80; }

// C0 控制字符（除 allowed 中的）与 DEL(0x7F)
inline bool is_forbidden_c0(unsigned char c, bool allow_nl, bool allow_tab) {
    if (c == '\n' && allow_nl) return false;
    if (c == '\t' && allow_tab) return false;
    return c < 0x20 || c == 0x7F;
}

inline const char* b64_alphabet() {
    return "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
}

} // namespace detail

inline bool is_utf8_continuation(unsigned char c) { return detail::is_utf8_continuation(c); }

inline std::size_t utf8_length(const std::string& s) {
    std::size_t n = 0;
    for (unsigned char c : s) if (!detail::is_utf8_continuation(c)) ++n;
    return n;
}

inline std::string utf8_truncate(const std::string& s, std::size_t max_chars) {
    std::size_t chars = 0, i = 0;
    while (i < s.size()) {
        if (chars == max_chars) break;
        // 走到下一个字符首字节
        ++i;
        while (i < s.size() && detail::is_utf8_continuation((unsigned char)s[i])) ++i;
        ++chars;
    }
    return s.substr(0, i);
}

inline bool utf8_valid(const std::string& s) {
    std::size_t i = 0;
    const std::size_t n = s.size();
    while (i < n) {
        const unsigned char c = (unsigned char)s[i];
        std::size_t len = 0;
        unsigned int cp = 0;
        if (c < 0x80) { ++i; continue; }
        else if ((c & 0xE0) == 0xC0) { len = 2; cp = c & 0x1F; }
        else if ((c & 0xF0) == 0xE0) { len = 3; cp = c & 0x0F; }
        else if ((c & 0xF8) == 0xF0) { len = 4; cp = c & 0x07; }
        else return false;
        if (i + len > n) return false;
        for (std::size_t k = 1; k < len; ++k) {
            const unsigned char cc = (unsigned char)s[i + k];
            if (!detail::is_utf8_continuation(cc)) return false;
            cp = (cp << 6) | (cc & 0x3F);
        }
        // 拒绝过长编码、代理区、超范围
        if (len == 2 && cp < 0x80) return false;
        if (len == 3 && cp < 0x800) return false;
        if (len == 4 && cp < 0x10000) return false;
        if (cp >= 0xD800 && cp <= 0xDFFF) return false;
        if (cp > 0x10FFFF) return false;
        i += len;
    }
    return true;
}

inline BodyResult sanitize_body(const std::string& raw) {
    BodyResult r;
    std::string out;
    out.reserve(raw.size());

    const std::string kReplacement = "\xEF\xBF\xBD";   // U+FFFD

    std::size_t i = 0;
    while (i < raw.size()) {
        const unsigned char c = (unsigned char)raw[i];

        // 非 UTF-8 起点：整段非法序列折叠成一个 U+FFFD，避免下游出现非法编码
        if (c >= 0x80) {
            std::size_t len = 0;
            if ((c & 0xE0) == 0xC0) len = 2;
            else if ((c & 0xF0) == 0xE0) len = 3;
            else if ((c & 0xF8) == 0xF0) len = 4;
            bool good = (len != 0) && (i + len <= raw.size());
            if (good) {
                for (std::size_t k = 1; k < len; ++k) {
                    if (!detail::is_utf8_continuation((unsigned char)raw[i + k])) { good = false; break; }
                }
            }
            if (!good) {
                out += kReplacement;
                ++r.control_chars;
                ++i;
                continue;
            }
            out.append(raw, i, len);
            i += len;
            continue;
        }

        // \r\n / 孤立 \r → \n（消灭 CRLF 组合，保留用户分段）
        if (c == '\r') {
            ++r.control_chars;
            out.push_back('\n');
            ++i;
            if (i < raw.size() && raw[i] == '\n') ++i;   // 吞掉 CRLF 的 LF
            continue;
        }

        if (detail::is_forbidden_c0(c, /*allow_nl=*/true, /*allow_tab=*/true)) {
            ++r.control_chars;
            ++i;
            continue;
        }

        out.push_back((char)c);
        ++i;
    }

    // 按字符数截断
    if (utf8_length(out) > kMaxBodyChars) {
        const std::size_t before = utf8_length(out);
        out = utf8_truncate(out, kMaxBodyChars);
        r.truncated = true;
        r.dropped_chars = before - kMaxBodyChars;
    }

    // "清洗后是否为空" 用 trim 判定（全空白等于没写）
    bool all_space = true;
    for (unsigned char c : out) {
        if (c != ' ' && c != '\t' && c != '\n' && c != '\r') { all_space = false; break; }
    }
    r.empty_after_clean = all_space;
    r.text = std::move(out);
    return r;
}

inline std::string sanitize_header_value(const std::string& raw, std::size_t max_chars) {
    std::string out;
    out.reserve(raw.size());
    std::size_t i = 0;
    while (i < raw.size()) {
        const unsigned char c = (unsigned char)raw[i];

        // U+2028 / U+2029（行/段分隔符）也折叠成空格：它们在某些实现里会被当换行
        if (c == 0xE2 && i + 2 < raw.size() &&
            (unsigned char)raw[i + 1] == 0x80 &&
            ((unsigned char)raw[i + 2] == 0xA8 || (unsigned char)raw[i + 2] == 0xA9)) {
            out.push_back(' ');
            i += 3;
            continue;
        }

        if (c >= 0x80) { out.push_back((char)c); ++i; continue; }

        if (c == '\r' || c == '\n' || c == '\t') { out.push_back(' '); ++i; continue; }
        if (c < 0x20 || c == 0x7F) { ++i; continue; }      // 其余控制字符直接删

        out.push_back((char)c);
        ++i;
    }

    // 连续空格折叠成单个（避免主题里出现一长串空白）
    std::string squeezed;
    squeezed.reserve(out.size());
    bool prev_space = false;
    for (char ch : out) {
        const bool sp = (ch == ' ');
        if (sp && prev_space) continue;
        squeezed.push_back(ch);
        prev_space = sp;
    }

    return utf8_truncate(squeezed, max_chars);
}

inline std::string build_subject(const std::string& meta) {
    std::string s = std::string(kSubjectPrefix) + " " + sanitize_header_value(meta, kMaxMetaChars);
    // 整体再洗一次：即使 kSubjectPrefix / meta 里有人塞了换行也活不下来
    return sanitize_header_value(s, kMaxMetaChars + 32);
}

inline std::string normalize_path(const std::string& p) {
    std::string s = p;
    for (char& c : s) if (c == '\\') c = '/';

    std::vector<std::string> parts;
    std::size_t i = 0;
    while (i < s.size()) {
        std::size_t j = s.find('/', i);
        if (j == std::string::npos) j = s.size();
        const std::string seg = s.substr(i, j - i);
        if (seg.empty() || seg == ".") {
            // 跳过
        } else if (seg == "..") {
            if (!parts.empty()) parts.pop_back();
        } else {
            parts.push_back(seg);
        }
        i = j + 1;
    }

    std::string out;
    for (const auto& part : parts) { out.push_back('/'); out += part; }
    if (out.empty()) out = "/";
    return out;
}

inline PathCheck check_attachment_path(const std::string& raw_path, const std::string& temp_root) {
    PathCheck r;
    if (raw_path.empty()) { r.reason = "诊断包路径为空"; return r; }
    if (raw_path[0] != '/' && raw_path[0] != '\\') { r.reason = "诊断包路径必须是绝对路径"; return r; }
    for (char c : raw_path) {
        if (c == '\0' || c == '\n' || c == '\r') { r.reason = "路径含控制字符（拒绝）"; return r; }
    }
    if (temp_root.empty()) { r.reason = "临时目录未知（宿主未初始化）"; return r; }

    const std::string norm = normalize_path(raw_path);
    const std::string root = normalize_path(temp_root);

    // 前缀判定：必须严格是 "<root>/..." 或等于 root（后者不可能，因为还要 .zip）
    bool in_root = false;
    if (norm.size() > root.size() && norm.compare(0, root.size(), root) == 0) {
        in_root = (norm[root.size()] == '/');   // 防 "/tmp/rlf" 命中 "/tmp/rlf-evil"
    }
    if (!in_root) { r.reason = "诊断包路径不在临时目录内（拒绝）"; return r; }

    // 文件名后缀必须是 .zip（大小写不敏感）
    std::string lower = norm;
    for (char& c : lower) if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
    if (lower.size() < 4 || lower.compare(lower.size() - 4, 4, ".zip") != 0) {
        r.reason = "诊断包必须是 .zip 文件（拒绝）";
        return r;
    }

    // basename 不能是 "." / ".."（normalize 已消掉，但再守一道）
    const std::size_t slash = norm.find_last_of('/');
    const std::string base = (slash == std::string::npos) ? norm : norm.substr(slash + 1);
    if (base.empty() || base == "." || base == "..") { r.reason = "文件名非法（拒绝）"; return r; }
    if (base.size() > kMaxAttachmentNameBytes) { r.reason = "文件名过长（拒绝）"; return r; }

    r.ok = true;
    r.normalized = norm;
    return r;
}

inline std::string safe_filename(const std::string& raw, const char* fallback) {
    std::string base = raw;
    const std::size_t slash = base.find_last_of("/\\");
    if (slash != std::string::npos) base = base.substr(slash + 1);

    std::string out;
    for (unsigned char c : base) {
        if (c < 0x20 || c == 0x7F) continue;                        // 控制字符
        if (c == '/' || c == '\\' || c == '"' || c == ':' ) continue; // 路径/引号/驱动器
        out.push_back((char)c);
    }
    while (!out.empty() && out[0] == '.') out.erase(out.begin());     // 前导点（隐藏文件/..）
    while (!out.empty() && out.back() == ' ') out.pop_back();

    if (out.empty() || out == "." || out == "..") out = fallback ? fallback : "attachment.bin";
    if (out.size() > kMaxAttachmentNameBytes) out = utf8_truncate(out, 100);
    return out;
}

// 无折行的 base64 —— 用于 header 内的 RFC 2047 编码（header 里**绝不能**有裸 CRLF）
inline std::string base64_flat(const std::string& raw) {
    const char* A = detail::b64_alphabet();
    std::string out;
    out.reserve(((raw.size() + 2) / 3) * 4);
    std::size_t i = 0;
    while (i + 2 < raw.size()) {
        const unsigned int v = ((unsigned char)raw[i] << 16) |
                               ((unsigned char)raw[i + 1] << 8) |
                               (unsigned char)raw[i + 2];
        out.push_back(A[(v >> 18) & 0x3F]);
        out.push_back(A[(v >> 12) & 0x3F]);
        out.push_back(A[(v >> 6) & 0x3F]);
        out.push_back(A[v & 0x3F]);
        i += 3;
    }
    const std::size_t rem = raw.size() - i;
    if (rem == 1) {
        const unsigned int v = ((unsigned char)raw[i] << 16);
        out.push_back(A[(v >> 18) & 0x3F]);
        out.push_back(A[(v >> 12) & 0x3F]);
        out += "==";
    } else if (rem == 2) {
        const unsigned int v = ((unsigned char)raw[i] << 16) | ((unsigned char)raw[i + 1] << 8);
        out.push_back(A[(v >> 18) & 0x3F]);
        out.push_back(A[(v >> 12) & 0x3F]);
        out.push_back(A[(v >> 6) & 0x3F]);
        out.push_back('=');
    }
    return out;
}

// 折行 base64 —— 用于 body / attachment（MIME 要求每行 <= 76 字符，硬上限 998）
inline std::string base64_mime(const std::string& raw) {
    const std::string flat = base64_flat(raw);
    std::string out;
    out.reserve(flat.size() + (flat.size() / 76 + 1) * 2);
    for (std::size_t i = 0; i < flat.size(); i += 76) {
        out.append(flat, i, std::min<std::size_t>(76, flat.size() - i));
        out += "\r\n";
    }
    if (out.empty()) out = "\r\n";   // 空 body 也占一个空行
    return out;
}

inline std::string build_eml(const std::string& to,
                             const std::string& subject,
                             const std::string& body_utf8,
                             const std::vector<Attachment>& attachments,
                             const std::string& boundary_seed) {
    // 收件人/主题一律再清洗一遍（纵深防御）
    const std::string to_clean = sanitize_header_value(to, 320);
    const std::string subj_clean = sanitize_header_value(subject, 400);

    std::string seed = boundary_seed;
    if (seed.empty()) seed = "rlfixedboundary";
    // 边界符只留安全字符，避免和 base64 内容撞车
    std::string bnd;
    for (unsigned char c : seed) {
        if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) bnd.push_back((char)c);
    }
    if (bnd.empty()) bnd = "rlfixedboundary";
    bnd = "----=_RLPlayer_" + bnd;

    std::string eml;
    eml += "From: RLPlayer <noreply@localhost>\r\n";
    eml += "To: " + to_clean + "\r\n";
    // RFC 2047：中文主题必须编码，否则裸 UTF-8 会违反 7bit 传输要求。
    // 用 base64_flat（**不折行**）：header 里出现裸 CRLF 就等于把一行拆成两行，
    // 下面那半截会被当成新 header 解析 —— 这正是 header 注入的形态。
    eml += "Subject: =?UTF-8?B?" + base64_flat(subj_clean) + "?=\r\n";
    eml += "MIME-Version: 1.0\r\n";
    eml += "X-Unsent: 1\r\n";
    eml += "X-RLPlayer-Feedback: 1\r\n";

    if (attachments.empty()) {
        eml += "Content-Type: text/plain; charset=utf-8\r\n";
        eml += "Content-Transfer-Encoding: base64\r\n";
        eml += "\r\n";
        eml += base64_mime(body_utf8);
    } else {
        eml += "Content-Type: multipart/mixed; boundary=\"" + bnd + "\"\r\n";
        eml += "\r\n";
        eml += "This is a multi-part message in MIME format.\r\n";

        // 正文
        eml += "--" + bnd + "\r\n";
        eml += "Content-Type: text/plain; charset=utf-8\r\n";
        eml += "Content-Transfer-Encoding: base64\r\n";
        eml += "\r\n";
        eml += base64_mime(body_utf8);

        // 附件
        for (const auto& a : attachments) {
            const std::string fn = safe_filename(a.filename, "rlplayer-diag.zip");
            const std::string ct = a.content_type.empty() ? "application/zip" : sanitize_header_value(a.content_type, 120);
            eml += "--" + bnd + "\r\n";
            eml += "Content-Type: " + ct + "; name=\"" + fn + "\"\r\n";
            eml += "Content-Disposition: attachment; filename=\"" + fn + "\"\r\n";
            eml += "Content-Transfer-Encoding: base64\r\n";
            eml += "\r\n";
            eml += base64_mime(a.data);
        }
        eml += "--" + bnd + "--\r\n";
    }
    return eml;
}

} // namespace rta::feedback
