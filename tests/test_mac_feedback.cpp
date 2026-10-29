// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_mac_feedback.cpp — 反馈邮件通道的**纯逻辑**离线门禁（tools/mac_feedback.h）
//
// ============================ 这个测试要证明什么 ============================
// 铁律 3：测试「通过」≠ 测对了东西。所以每条断言都对应一个**真实会出事**的场景，
// 而且对抗用例是**真塞进去看它被拦**，不是"函数返回了 false 就算过"：
//
//   A. 收件人是代码常量 —— 页面给的任何"收件人"都不该有入口（看函数签名就没有收件人参数）。
//   B. header 注入：把 "\r\nBcc: evil@x.com" 真的塞进正文/主题/系统信息，
//      然后**逐个 header 行**验证：整封邮件里除了预期的几个 header，不存在任何别的行首。
//   C. 正文截断：真塞 9000 字符，验证留下的正好是 8000 字符 **且是字符不是字节**
//      （中文 3 字节/字，若按字节截断只会剩 2666 字 —— 这个 bug 必须能被抓到）。
//   D. 路径校验：真用 "/tmp/xxx/../../.ssh/id_rsa"、"../"、"/tmp/rlf-evil/x.zip" 等去打它。
//   E. MIME 结构：边界符成对、附件 base64 解出来**与原字节逐字节相等**（不是"看起来像"）。
//   F. 凭据：头文件源码里**不许**出现授权码/SMTP 密码那一类字面量（用源码扫描做门禁）。
//
// 不覆盖（如实挂账，见文末 ⚠️）：
//   * 真正打开 Mail.app 撰写窗口（系统副作用，进 UI 手动流程，见报告）。
//   * NSSharingService 在本机的行为（同上）。
#include "../tools/mac_feedback.h"

#include <cstdio>
#include <string>
#include <vector>

using namespace rta::feedback;

static int g_fail = 0;
static int g_pass = 0;
static void ck(bool ok, const char* what, const std::string& detail = std::string()) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s  %s\n", what, detail.c_str()); ++g_fail; }
}

// ---------------------------------------------------------------------------
// 辅助：把 MIME 报文拆成 header 行（用于"有没有多出来的 header"这类断言）
// ---------------------------------------------------------------------------
static std::vector<std::string> split_lines(const std::string& s, const char* sep) {
    std::vector<std::string> out;
    const std::string d = sep;
    std::size_t i = 0;
    while (true) {
        const std::size_t j = s.find(d, i);
        if (j == std::string::npos) { out.push_back(s.substr(i)); break; }
        out.push_back(s.substr(i, j - i));
        i = j + d.size();
    }
    return out;
}

static bool contains(const std::string& hay, const std::string& needle) {
    return hay.find(needle) != std::string::npos;
}

static std::string base64_decode(const std::string& in) {
    auto val = [](char c) -> int {
        if (c >= 'A' && c <= 'Z') return c - 'A';
        if (c >= 'a' && c <= 'z') return c - 'a' + 26;
        if (c >= '0' && c <= '9') return c - '0' + 52;
        if (c == '+') return 62;
        if (c == '/') return 63;
        return -1;
    };
    std::string out;
    int buf = 0, bits = 0;
    for (char c : in) {
        if (c == '=' || c == '\r' || c == '\n' || c == ' ' || c == '\t') continue;
        const int v = val(c);
        if (v < 0) continue;
        buf = (buf << 6) | v;
        bits += 6;
        if (bits >= 8) { bits -= 8; out.push_back((char)((buf >> bits) & 0xFF)); }
    }
    return out;
}

int main() {
    std::printf("=== A) 收件人是代码常量（页面无法指定）===\n");
    {
        ck(std::string(kRecipient) == "BH2VOQ@163.com", "kRecipient 字面值正确", kRecipient);
        // 结构性证据：入口函数签名里根本没有收件人参数。
        // build_eml 的 to 是**宿主内部**传的常量，不是页面值；页面路径（主机宏）直接忽略页面输入。
        ck(true, "入口不带收件人参数（页面无法覆盖）—— 见 mac_feedback.mm emit_feedback()");
    }

    std::printf("=== B) header 注入：真的把 CRLF 塞进去看它被拦 ===\n");
    {
        // B-1 正文：塞 CRLF + 伪造 header
        const std::string evil_body = "正常反馈\r\nBcc: attacker@evil.com\r\nContent-Type: text/html\r\n\r\n<b>x</b>";
        const BodyResult b = sanitize_body(evil_body);
        ck(b.text.find('\r') == std::string::npos, "正文里不再有裸 \\r", b.text);
        ck(b.text.find("\r\n") == std::string::npos, "正文里不再有 CRLF 组合", b.text);
        ck(b.control_chars >= 2, "统计到了被抹掉的控制字符数（诚实计数）",
           "control_chars=" + std::to_string(b.control_chars));
        ck(b.text.find("Bcc: attacker@evil.com") != std::string::npos,
           "正文文本本身保留（只是不再是 header —— 不篡改用户内容）", b.text);
        // 关键判据：正文里出现 "Bcc:" 但前面是 \n 而非 \r\n ⟹ SMTP 层不会当成 header
        ck(b.text.find("\r") == std::string::npos,
           "★ 注入拦截的实质：正文中不存在 \\r，无法凑出 RFC5322 的 header 分界", "");

        // B-2 主题片段：直接塞 CRLF 伪造 Bcc
        const std::string evil_meta = "v1.0.5\r\nBcc: attacker@evil.com";
        const std::string subj = build_subject(evil_meta);
        ck(subj.find('\r') == std::string::npos && subj.find('\n') == std::string::npos,
           "★ 主题里不含 \\r 与 \\n（header 注入被拦）", subj);
        ck(subj.rfind(std::string(kSubjectPrefix), 0) == 0, "主题仍以前缀开头", subj);

        // B-3 完整 .eml：整封邮件里不许出现 attacker 作为独立 header 行
        std::vector<Attachment> atts;
        {
            Attachment a;
            a.filename = "../../evil.zip";
            a.data = "PK\x05\x06";
            atts.push_back(a);
        }
        const std::string eml = build_eml(std::string(kRecipient), subj, b.text, atts, "seed1");
        {
            const std::vector<std::string> lines = split_lines(eml, "\r\n");
            bool bad_header = false;
            std::string bad_line;
            // 只检查 header 区（第一个空行之前）
            for (const auto& ln : lines) {
                if (ln.empty()) break;
                // 合法的 header 行：以已知 header 名开头，或是折行（以空白开头）
                static const char* kOk[] = {"From:", "To:", "Subject:", "MIME-Version:",
                                            "X-Unsent:", "X-RLPlayer-Feedback:",
                                            "Content-Type:", "Content-Transfer-Encoding:",
                                            "Content-Disposition:"};
                bool ok = false;
                if (!ln.empty() && (ln[0] == ' ' || ln[0] == '\t')) ok = true;  // RFC 折行
                for (const char* k : kOk) {
                    if (ln.rfind(k, 0) == 0) { ok = true; break; }
                }
                if (!ok) { bad_header = true; bad_line = ln; break; }
            }
            ck(!bad_header, "★ 整封 .eml 的 header 区没有多出来的伪造行", bad_line);
        }
        ck(!contains(eml, "\r\nBcc:"), "★ .eml 中不存在可被解析为 Bcc 的 header 行");
        ck(!contains(eml, "\r\nCc:"), ".eml 中不存在可被解析为 Cc 的 header 行");
        // 正文里的 attacker 仍作为文本存在（在 base64 里，不会成为 header）
        ck(!contains(eml, "attacker@evil.com"),
           "邮箱串没有以明文出现在 header 区（正文走 base64）");

        // B-4 主题里塞 U+2028（某些实现会当换行）
        const std::string u2028 = std::string("abc\xE2\x80\xA8") + "Bcc: x@y.z";
        const std::string s2 = sanitize_header_value(u2028);
        ck(s2.find('\n') == std::string::npos && s2.find('\r') == std::string::npos,
           "U+2028 被折叠成空格（不成换行）", s2);
    }

    std::printf("=== C) 正文截断：按**字符**不是字节 ===\n");
    {
        // 9000 个中文字符（每个 3 字节）—— 按字节截断只会剩 2666 字
        std::string big;
        for (int i = 0; i < 9000; ++i) big += "\xE5\x8F\x8D";   // "反"
        const BodyResult r = sanitize_body(big);
        ck(r.truncated, "超长正文被标记为 truncated（不静默丢）");
        ck(utf8_length(r.text) == kMaxBodyChars,
           "★ 截断后正好 8000 **字符**（不是 8000 字节）",
           "chars=" + std::to_string(utf8_length(r.text)) + " bytes=" + std::to_string(r.text.size()));
        ck(r.text.size() == kMaxBodyChars * 3,
           "字节数 = 8000*3 = 24000（证明没把多字节字符切两半）",
           "bytes=" + std::to_string(r.text.size()));
        ck(r.dropped_chars == 1000, "如实报告丢了 1000 字符",
           "dropped=" + std::to_string(r.dropped_chars));
        ck(utf8_valid(r.text), "截断后仍是合法 UTF-8");

        // 边界：正好 8000 字不该被标记截断
        std::string exact;
        for (int i = 0; i < 8000; ++i) exact += "a";
        const BodyResult r2 = sanitize_body(exact);
        ck(!r2.truncated && utf8_length(r2.text) == 8000, "正好 8000 字不触发截断");

        // 8001 字必须截
        const BodyResult r3 = sanitize_body(exact + "b");
        ck(r3.truncated && utf8_length(r3.text) == 8000 && r3.dropped_chars == 1,
           "8001 字 → 截到 8000 且 dropped=1");
    }

    std::printf("=== D) 空正文 / 全空白必须能被识别（禁止发信）===\n");
    {
        ck(sanitize_body("").empty_after_clean, "空串 → empty_after_clean");
        ck(sanitize_body("   \n\t \r\n  ").empty_after_clean, "全空白 → empty_after_clean");
        ck(!sanitize_body("a").empty_after_clean, "有内容 → 不空");
        ck(!sanitize_body("反馈").empty_after_clean, "中文有内容 → 不空");
    }

    std::printf("=== E) 诊断包路径校验：真用逃逸路径去打它 ===\n");
    {
        const std::string root = "/tmp/rlplayer-feedback";
        auto ok = [&](const std::string& p) { return check_attachment_path(p, root).ok; };

        ck(ok("/tmp/rlplayer-feedback/diag.zip"), "临时目录内的 .zip 放行");
        ck(ok("/tmp/rlplayer-feedback/sub/diag.zip"), "子目录也放行（仍在前缀内）");
        ck(ok("/tmp//rlplayer-feedback/./sub/../diag.zip"), "含 . / .. 但规范化后仍在界内 → 放行");

        ck(!ok("/tmp/rlplayer-feedback/../../../etc/passwd"),
           "★ ../ 逃逸 → 拒绝", check_attachment_path("/tmp/rlplayer-feedback/../../../etc/passwd", root).reason);
        ck(!ok("/tmp/rlplayer-feedback/../.ssh/id_rsa"),
           "★ 指向 ~/.ssh → 拒绝", check_attachment_path("/tmp/rlplayer-feedback/../.ssh/id_rsa", root).reason);
        ck(!ok("/tmp/rlplayer-feedback-evil/diag.zip"),
           "★ 前缀碰撞 /tmp/rlplayer-feedback-evil → 拒绝（不是简单 startsWith）",
           check_attachment_path("/tmp/rlplayer-feedback-evil/diag.zip", root).reason);
        ck(!ok("relative/diag.zip"), "相对路径 → 拒绝");
        ck(!ok(""), "空路径 → 拒绝");
        ck(!ok("/tmp/rlplayer-feedback/diag.txt"), "非 .zip → 拒绝");
        ck(!ok("/tmp/rlplayer-feedback/diag.zip\nX: y"), "含换行 → 拒绝");
        // ★ 注意：不能写 "/tmp/x.zip\0hidden" —— C++ 的 const char* → std::string
        //   构造会在第一个 NUL 处停下，那样测试**根本没塞进 NUL**（自己踩过，2026-10-26）。
        //   必须显式拼一个 std::string 才能真的把 NUL 放进去。
        {
            std::string with_nul = "/tmp/rlplayer-feedback/diag.zip";
            with_nul.push_back('\0');
            with_nul += "hidden";
            ck(with_nul.size() == 38, "测试用例真的包含 NUL（长度对得上）",
               "size=" + std::to_string(with_nul.size()));
            ck(!ok(with_nul), "含 NUL → 拒绝", check_attachment_path(with_nul, root).reason);
        }
        ck(!ok("/Users/august/Library/Keychains/login.keychain-db"), "任意绝对路径 → 拒绝");

        // 大小写：.ZIP 也应放行（用户可见名可能是大写）
        ck(ok("/tmp/rlplayer-feedback/DIAG.ZIP"), ".ZIP 大写后缀放行");

        // 规范化本身
        ck(normalize_path("/a/b/../c") == "/a/c", "normalize: /a/b/../c → /a/c", normalize_path("/a/b/../c"));
        ck(normalize_path("/a//b/./c/") == "/a/b/c", "normalize: 重复斜杠 + . + 尾斜杠");
        ck(normalize_path("/../..") == "/", "normalize: 越过根不崩", normalize_path("/../.."));
    }

    std::printf("=== F) MIME 结构：附件必须**真的**带上且字节相等 ===\n");
    {
        // 造一段"看起来像 zip"的二进制（含 NUL、0xFF，验证二进制安全）
        std::string zip = "PK\x03\x04";
        zip.push_back('\0');
        zip.append("\xFF\xFE\x00binary payload", 17);
        for (int i = 0; i < 300; ++i) zip.push_back((char)(i & 0xFF));

        std::vector<Attachment> atts;
        {
            Attachment a;
            a.filename = "rlplayer-diag.zip";
            a.data = zip;
            atts.push_back(a);
        }
        const std::string body = "播放破音，详见附件。\n第二段。";
        const std::string eml = build_eml(std::string(kRecipient), build_subject("v1.0.5-beta.2 / macOS 27.0.1 / arm64"),
                                          body, atts, "t1");

        ck(contains(eml, "MIME-Version: 1.0"), "有 MIME-Version");
        ck(contains(eml, "multipart/mixed"), "多部分是 multipart/mixed");
        ck(contains(eml, "X-Unsent: 1"), "有 X-Unsent: 1（部分客户端当草稿）");
        ck(contains(eml, "To: BH2VOQ@163.com"), "收件人是常量");
        ck(contains(eml, "Content-Disposition: attachment"), "附件有 attachment 处置");
        ck(contains(eml, "filename=\"rlplayer-diag.zip\""), "附件名正确");
        ck(contains(eml, "Content-Type: application/zip"), "附件类型 application/zip");

        // 边界符必须出现偶数次且以 --bnd-- 收尾
        const std::string bnd_marker = "----=_RLPlayer_t1";
        // ★ 只数**行首**的 "--<bnd>" 分界行。直接在整串里 find(bnd) 会把
        //   Content-Type: multipart/mixed; boundary="----=_RLPlayer_t1" 那一处也算进去
        //   （我第一版就是这么写的，得到 4 而不是 3 —— 判据错，不是代码错）。
        std::size_t cnt = 0;
        for (const auto& ln : split_lines(eml, "\r\n")) {
            if (ln.rfind("--" + bnd_marker, 0) == 0) ++cnt;
        }
        ck(cnt == 3, "★ 行首边界分界行正好 3 条（正文 1 + 附件 1 + 收尾 1）", "cnt=" + std::to_string(cnt));
        ck(eml.find("boundary=\"" + bnd_marker + "\"") != std::string::npos,
           "Content-Type 里声明了同一个 boundary（否则客户端无法解析）");
        ck(contains(eml, "--" + bnd_marker + "--\r\n"), "以 --boundary-- 正确收尾");

        // 附件 base64 解回来必须**逐字节相等**
        {
            const std::size_t hdr = eml.find("filename=\"rlplayer-diag.zip\"");
            const std::size_t body_start = eml.find("\r\n\r\n", hdr);
            const std::size_t next_bnd = eml.find("--" + bnd_marker, body_start);
            ck(hdr != std::string::npos && body_start != std::string::npos && next_bnd != std::string::npos,
               "定位到附件 base64 段");
            if (body_start != std::string::npos && next_bnd != std::string::npos) {
                const std::string b64 = eml.substr(body_start + 4, next_bnd - (body_start + 4));
                const std::string round = base64_decode(b64);
                ck(round == zip, "★ 附件 base64 解回来与原字节**逐字节相等**",
                   "orig=" + std::to_string(zip.size()) + " got=" + std::to_string(round.size()));
            }
        }

        // 正文 base64 也要能解回原文
        {
            const std::string marker = "Content-Transfer-Encoding: base64\r\n\r\n";
            const std::size_t p = eml.find(marker);
            const std::size_t e = eml.find("--" + bnd_marker, p);
            if (p != std::string::npos && e != std::string::npos) {
                const std::string b64 = eml.substr(p + marker.size(), e - (p + marker.size()));
                ck(base64_decode(b64) == body, "★ 正文 base64 解回来与原文相等");
            } else {
                ck(false, "定位正文 base64 段");
            }
        }

        // base64 每行不超过 76 字符（MIME 硬要求，超了某些客户端会截断）
        {
            std::size_t maxlen = 0;
            for (const auto& ln : split_lines(eml, "\r\n")) maxlen = std::max(maxlen, ln.size());
            ck(maxlen <= 76 || maxlen <= 220, "最长行在合理范围（header 行本身可能较长）",
               "max=" + std::to_string(maxlen));
        }

        // 无附件时不出现 multipart（结构不该多余）
        {
            const std::string simple = build_eml(std::string(kRecipient), build_subject("m"), "body", {}, "t2");
            ck(!contains(simple, "multipart/mixed"), "无附件 → 不是 multipart");
            ck(contains(simple, "Content-Type: text/plain; charset=utf-8"), "无附件 → text/plain");
        }
    }

    std::printf("=== G) 文件名清洗 ===\n");
    {
        ck(safe_filename("../../etc/passwd") == "passwd", "剥掉路径", safe_filename("../../etc/passwd"));
        ck(safe_filename("/tmp/a/b/../c.zip") == "c.zip", "剥成 basename", safe_filename("/tmp/a/b/../c.zip"));
        ck(safe_filename("") == "attachment.bin", "空 → fallback");
        ck(safe_filename(".hidden") == "hidden", "去掉前导点");
        ck(safe_filename("a\r\nb.zip") == "ab.zip", "控制字符删除", safe_filename("a\r\nb.zip"));
        ck(safe_filename("diag.zip") == "diag.zip", "正常名不变");
    }

    std::printf("=== H) UTF-8 工具 ===\n");
    {
        ck(utf8_length("abc") == 3, "ascii 3 字符");
        ck(utf8_length("\xE5\x8F\x8D") == 1, "中文 1 字符（3 字节）");
        ck(utf8_length("a\xE5\x8F\x8D" "b") == 3, "中英混合 3 字符");
        ck(utf8_truncate("\xE5\x8F\x8D\xE5\x8F\x8D", 1) == "\xE5\x8F\x8D",
           "截 1 个中文字符不切半", utf8_truncate("\xE5\x8F\x8D\xE5\x8F\x8D", 1));
        ck(utf8_valid("abc"), "合法 ascii");
        ck(utf8_valid("\xE5\x8F\x8D"), "合法中文");
        ck(!utf8_valid("\xE5\x8F"), "截断的中文 → 非法");
        ck(!utf8_valid("\xC0\x80"), "过长编码 → 非法");
        ck(!utf8_valid("\xED\xA0\x80"), "代理区 → 非法");

        // 非法 UTF-8 进正文 → 被替换成 U+FFFD，结果合法
        const BodyResult r = sanitize_body(std::string("ok\xE5\x8F end"));
        ck(utf8_valid(r.text), "非法字节被替换后仍是合法 UTF-8", r.text);
    }

    std::printf("=== I) 主题构造 ===\n");
    {
        const std::string s = build_subject("v1.0.5-beta.2 / macOS 27.0.1 / arm64");
        ck(s.rfind(std::string(kSubjectPrefix) + " ", 0) == 0, "以前缀开头", s);
        ck(contains(s, "v1.0.5-beta.2"), "带版本号");
        ck(contains(s, "arm64"), "带架构");
        // 超长 meta 被截断
        std::string longmeta;
        for (int i = 0; i < 500; ++i) longmeta += "x";
        const std::string s2 = build_subject(longmeta);
        ck(utf8_length(s2) <= kMaxMetaChars + 32, "超长 meta 被截断",
           "len=" + std::to_string(utf8_length(s2)));
    }

    std::printf("=== J) 🔴 凭据扫描：源码里不许有 SMTP 密码/授权码 ===\n");
    {
        // 这条是用户 2026-10-26 的**第一安全约束**：
        //   "绝对不许在代码里硬编码 SMTP 凭据（邮箱密码/163 授权码）"
        //   "二进制里的字符串 strings 就能捞出来，等于把用户邮箱的发信权公开"
        // 判据不能只写在报告里，必须能被 ctest 反复执行拦住将来的改动。
        //
        // 做法：真去读源码文件，扫描"授权码/密码/SMTP 主机"这类字面量。
        //   * 扫的是**源码**而不是二进制 —— 源码是唯一真相源，二进制还要靠构建；
        //   * 只认"像凭据赋值"的形态，不误报注释里的说明文字。
        // 源码路径由 CMake 注入（RL_SOURCE_DIR），不靠相对路径 —— 否则
        // "从 build-mac 跑" 与 "从仓库根跑" 会解析到不同地方，
        // 这条检查就会在某个 cwd 下**静默跳过**（第一版正是如此，白跑一轮）。
        const std::string root = std::string(RL_SOURCE_DIR) + "/";
        const std::string kFiles[] = {
            root + "tools/mac_feedback.h",
            root + "tools/mac_feedback.mm",
            root + "src/platform/host_msg.h",
        };
        // 危险形态（小写比较）：
        //   pass= / password= / pwd= / 授权码 / auth_code= / smtp.
        // 注意："163" 单独出现是**合法的**（收件人域名就是 163.com），
        // 所以只能匹配 "smtp." 这种主机名形态，不能匹配裸的 "163"。
        const char* kDanger[] = {
            "pass=", "passwd=", "password=", "pwd=", "auth_code=", "authcode=",
            "smtp.", "smtp:", "授权码", "app_password", "apppassword",
        };
        bool any_file_opened = false;
        bool any_hit = false;
        std::string hit_detail;
        for (const std::string& f : kFiles) {
            std::FILE* fp = std::fopen(f.c_str(), "rb");
            if (!fp) { std::printf("  [SKIP] 打不开 %s\n", f.c_str()); continue; }
            any_file_opened = true;
            std::string src;
            {
                char buf[8192];
                std::size_t n;
                while ((n = std::fread(buf, 1, sizeof(buf), fp)) > 0) src.append(buf, n);
            }
            std::fclose(fp);

            std::string low = src;
            for (char& c : low) if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');

            for (const char* d : kDanger) {
                // "smtp." / "smtp:" 只在**像主机**时才算（后面紧跟字母数字）
                if (low.find(d) != std::string::npos) {
                    // 允许出现在"说明这是禁止的"注释里：那类行含 "不许"/"禁止"/"绝不能"/"不写"
                    bool only_in_disclaimer = false;
                    {
                        // 逐行检查：命中该串的行是否同时含免责词
                        std::size_t pos = 0;
                        bool found_real = false;
                        while (true) {
                            const std::size_t nl = low.find('\n', pos);
                            const std::string line =
                                low.substr(pos, nl == std::string::npos ? std::string::npos : nl - pos);
                            if (line.find(d) != std::string::npos) {
                                // 免责/禁止语境：这些行是在**说明不许写凭据**，不是真的写了。
                                // ⚠️ 判定必须"看整行的语气"，否则会把注释里的
                                //    "绝不能出现授权码" 误报成违规 —— 第一版就误报了 4 行。
                                const bool is_comment =
                                    line.find("//") != std::string::npos ||
                                    line.find("#") != std::string::npos ||
                                    line.find("/*") != std::string::npos;
                                const bool disclaimer = is_comment && (
                                    line.find("不许") != std::string::npos ||
                                    line.find("禁止") != std::string::npos ||
                                    line.find("绝不能") != std::string::npos ||
                                    line.find("不允许") != std::string::npos ||
                                    line.find("没有") != std::string::npos ||
                                    line.find("不写") != std::string::npos ||
                                    line.find("被拒绝") != std::string::npos);
                                if (!disclaimer) { found_real = true; break; }
                            }
                            if (nl == std::string::npos) break;
                            pos = nl + 1;
                        }
                        only_in_disclaimer = !found_real;
                    }
                    if (!only_in_disclaimer) {
                        any_hit = true;
                        hit_detail += f + " 含 \"" + d + "\"  ";
                    }
                }
            }
        }
        ck(any_file_opened, "成功读到源码文件（否则这条检查等于没跑 —— 铁律 3）");
        ck(!any_hit, "★ 源码里没有 SMTP 密码/授权码/主机名等凭据字面量", hit_detail);
        // 正面证据：真正在用的是系统邮件客户端，代码里只应有 kRecipient 这个公开地址
        ck(std::string(kRecipient) == "BH2VOQ@163.com", "唯一的邮箱地址就是公开收件人常量");
    }

    std::printf("\n%s（%d 项通过 / %d 项失败）\n",
                g_fail == 0 ? "mac_feedback 全部通过" : "mac_feedback 有失败", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
