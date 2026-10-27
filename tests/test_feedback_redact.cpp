// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_feedback_redact.cpp — 「一键反馈 / 诊断包」脱敏规则的回归（F-7，2026-10-27）
//
// ===========================================================================
// 这条判据怎么证明事（铁律 3）
//
//   A 段（红侧基线）：本文件里**原样保留**了改前的实现 legacy_redact()
//     ——它就是 tools/rtaweb.cpp:/api/diagzip 里那段内联 lambda 的逐字复制。
//     断言它**确实漏掉**三类明文（JSON 形态 token / 家目录用户名 / Bearer JWT）
//     + 半抹的 sk-live-XXX + 邮箱。这几条现在是绿的，意思是"旧实现确实漏"已被
//     固化成可复跑的判据，不是一次性的手工观察。
//     ⚠️ 如果哪天有人把 legacy_redact 改成也不漏了（"顺手修好对照"），A 段就会 FAIL ——
//        这是故意的：A 段的意义就是"永远有一个红色的历史基线可比"。
//
//   B 段（绿侧）：新实现 rta::feedback::redact() 对**同一批输入**逐条断言**完整输出串**
//     （不是 grep "包含 <redacted>"），例如
//       输入 {"token": "abcdef123456"}
//       期望 {"token": "<redacted>"}      ← 全等断言
//
//   C 段（不许误伤）：曲名里的普通单词 token、"hotkey"（含 key 子串）、
//     COVERBG 的短缓存键 key=a1b2c3d4e5、正常设置行、非用户目录路径、
//     形似邮箱但不成立的串 —— 逐条断言**原样保留**。
//
//   D 段：幂等（redact(redact(x)) == redact(x)）、规则清单非空、统计计数真实增长。
// ===========================================================================
#include "net/feedback_redact.h"

#include <cctype>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

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

// 全等断言：detail 里打印"期望 vs 实际"，失败一眼能看出差在哪
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
    ck(hay.find(needle) != std::string::npos, what, "缺少子串: " + needle);
}

static void ck_not_has(const std::string& hay, const std::string& needle, const char* what) {
    ck(hay.find(needle) == std::string::npos, what, "仍含明文: " + needle + "  ⟹ " + hay);
}

// ===========================================================================
// A 段用的**改前实现**（2026-10-27 从 tools/rtaweb.cpp 的 /api/diagzip 段逐字抄下）
// 不要改它、不要"顺手修好"——它是红侧基线。
// ===========================================================================
namespace legacy {

static std::string redact_secrets(std::string s) {
    // (a) 整行键值：api_key=..., token=..., password=...
    for (const char* key : {"api_key=", "apikey=", "token=", "password=", "secret="}) {
        size_t from = 0;
        for (;;) {
            const size_t hit = s.find(key, from);
            if (hit == std::string::npos) break;
            size_t e = s.find_first_of(" \t\r\n\"',;", hit + std::strlen(key));
            if (e == std::string::npos) e = s.size();
            s.replace(hit + std::strlen(key), e - (hit + std::strlen(key)), "***");
            from = hit + std::strlen(key) + 3;
        }
    }
    // (b) 散落的 sk-xxxx（DeepSeek / OpenAI 形态）
    size_t scan = 0;
    for (;;) {
        const size_t p2 = s.find("sk-", scan);
        if (p2 == std::string::npos) break;
        const bool boundary = (p2 == 0) || !std::isalnum((unsigned char)s[p2 - 1]);
        size_t e2 = p2 + 3;
        while (e2 < s.size() && std::isalnum((unsigned char)s[e2])) ++e2;
        if (boundary && e2 > p2 + 3) {
            s.replace(p2 + 3, e2 - (p2 + 3), "***");
            scan = p2 + 6;
        } else {
            scan = p2 + 3;
        }
    }
    return s;
}

}  // namespace legacy

int main() {
    std::printf("== test_feedback_redact: 诊断包脱敏规则 ==\n");

    // 三条任务书点名的形态（+ 两条实测中发现的泄漏）
    const std::string kJwt =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0."
        "dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U";
    const std::string kJsonToken   = "{\"token\": \"abcdef123456\"}";
    const std::string kHomePath    = "from=/Users/august/Downloads/DQ/RLPlayer/build-mac";
    const std::string kAuthHeader  = "LLM request headers: Authorization: Bearer " + kJwt;
    const std::string kSkLive      = "OPENAI_KEY=sk-live-ABCDEF123456XYZ len=51";
    const std::string kMail        = "contact=tester@example.com";
    const std::string kBareBearer  = "GET /v1/models HTTP/1.1 authorization: bearer " + kJwt;

    // ---------------------------------------------------------------- A 段（红）
    std::printf("\n-- A. 红侧基线：改前的 redact_secrets() 漏了什么（断言「确实漏」，永远可复跑）--\n");
    {
        // 注意断言方向：这里断言的是**旧实现仍然泄漏**。它 PASS = 红基线成立。
        // 谁要是把 legacy_redact 修好了，这条就 FAIL —— 故意的，A 段就是那只对照样本。
        const std::string a1 = legacy::redact_secrets(kJsonToken);
        std::printf("  旧实现(JSON token)   : %s\n", a1.c_str());
        ck_has(a1, "abcdef123456", "A1 红基线：旧实现漏 JSON 形态 token（明文仍在）");

        const std::string a2 = legacy::redact_secrets(kHomePath);
        std::printf("  旧实现(家目录)       : %s\n", a2.c_str());
        ck_has(a2, "august", "A2 红基线：旧实现漏家目录用户名（明文仍在）");

        const std::string a3 = legacy::redact_secrets(kAuthHeader);
        std::printf("  旧实现(Bearer 头)    : %s\n", a3.c_str());
        ck_has(a3, "eyJhbGciOiJIUzI1NiIs", "A3 红基线：旧实现漏 Authorization: Bearer（明文仍在）");

        const std::string a4 = legacy::redact_secrets(kSkLive);
        std::printf("  旧实现(sk-live)      : %s\n", a4.c_str());
        // 旧实现只吃掉 "sk-" 后第一段 [A-Za-z0-9]+，'live' 之后的 "-ABCDEF..." 全留明文
        ck_has(a4, "ABCDEF123456XYZ", "A4 红基线：旧实现 sk-live 只抹一半，中段仍明文");

        const std::string a5 = legacy::redact_secrets(kMail);
        std::printf("  旧实现(邮箱)         : %s\n", a5.c_str());
        ck_has(a5, "tester@example.com", "A5 红基线：旧实现漏邮箱（明文仍在）");

        // 旧实现确实**做对**的部分也要断言，否则 A 段偏袒新实现
        ck_eq(legacy::redact_secrets("token=abcdef123456"), "token=***",
              "A6 旧实现的 k=v 形态 token= 本来就能抹（不是本轮新增能力）");
    }

    // ---------------------------------------------------------------- B 段（绿）
    std::printf("\n-- B. 绿侧：新实现逐条替换（全等断言）--\n");
    {
        ck_eq(rta::feedback::redact(kJsonToken), "{\"token\": \"<redacted>\"}",
              "B1 JSON 形态 \"token\": \"v\" → <redacted>");
        ck_eq(rta::feedback::redact(kHomePath),
              "from=/Users/<user>/Downloads/DQ/RLPlayer/build-mac",
              "B2 家目录用户名 → <user>，其余路径结构保留");
        ck_eq(rta::feedback::redact(kAuthHeader),
              "LLM request headers: Authorization: <redacted>",
              "B3 Authorization: Bearer <JWT> → <redacted>");
        ck_eq(rta::feedback::redact(kSkLive), "OPENAI_KEY=<redacted> len=51",
              "B4 sk-live-… 整段替换（不再留中段）");
        ck_eq(rta::feedback::redact(kMail), "contact=<user>@example.com",
              "B5 邮箱本地部分 → <user>，域名保留");
        ck_eq(rta::feedback::redact(kBareBearer),
              "GET /v1/models HTTP/1.1 authorization: <redacted>",
              "B6 小写 bearer + 裸 token 也认（大小写不敏感）");
        ck_eq(rta::feedback::redact("token=abcdef123456"), "token=<redacted>",
              "B7 旧能力保留：k=v 形态仍然被抹（只是把 *** 换成 <redacted>）");
        ck_eq(rta::feedback::redact("{\"api_key\":\"sk-proj-ZZZZ9999YYYY8888\",\"x\":1}"),
              "{\"api_key\":\"<redacted>\",\"x\":1}", "B8 JSON 紧凑写法（无空格）也认");
        ck_eq(rta::feedback::redact("HTTP 401 password=hunter2&user=me"),
              "HTTP 401 password=<redacted>&user=me", "B9 查询串形态：password 值被抹，其余参数保留");
        ck_eq(rta::feedback::redact("ghp_0123456789abcdefghij token"),
              "<redacted> token", "B10 GitHub PAT 前缀");
        ck_eq(rta::feedback::redact("AKIAIOSFODNN7EXAMPLE+key"),
              "<redacted>+key", "B11 AWS AccessKeyId");
        ck_eq(rta::feedback::redact("Cookie: sid=deadbeefcafe; lang=zh"),
              "Cookie: <redacted>; lang=zh", "B12 Cookie 头值被抹（分号处停）");
        ck_eq(rta::feedback::redact("secret: s3cr3t-value"),
              "secret: <redacted>", "B13 colon 形态 + 值里带连字符");
        // 一条真实的日志行（就是 /api/diagzip 里那种内容）
        const std::string line =
            "2026-10-27 16:01:00 LLM cfg access_token=\"tok_9f8e7d6c5b4a\" "
            "from=/Users/august/Library/Application Support/RLPlayer";
        const std::string out = rta::feedback::redact(line);
        ck_not_has(out, "tok_9f8e7d6c5b4a", "B14 真实日志行：access_token 值不再明文");
        ck_not_has(out, "august", "B14b 真实日志行：用户名不再明文");
        ck_has(out, "/Users/<user>/Library/Application Support/RLPlayer",
               "B14c 真实日志行：路径结构完整保留，只换用户名");
    }

    // ---------------------------------------------------------------- C 段（不误伤）
    std::printf("\n-- C. 不许误伤：正常内容原样保留（全等断言）--\n");
    {
        ck_eq(rta::feedback::redact("TRACK title=Token Ring Song artist=Test Orchestra"),
              "TRACK title=Token Ring Song artist=Test Orchestra",
              "C1 曲名里的普通单词 token 不被抹");
        ck_eq(rta::feedback::redact("PLAY tokenization test"), "PLAY tokenization test",
              "C2 tokenization（token 后接标识符字符）不被当成键");
        ck_eq(rta::feedback::redact("HOTKEY hotkey=cmd+space"), "HOTKEY hotkey=cmd+space",
              "C3 hotkey（含 key 子串）不被当凭据键");
        ck_eq(rta::feedback::redact("monkey=banana"), "monkey=banana",
              "C4 monkey（含 key 子串）不被当凭据键");
        ck_eq(rta::feedback::redact("COVERBG hit key=a1b2c3d4e5 name=front.jpg"),
              "COVERBG hit key=a1b2c3d4e5 name=front.jpg",
              "C5 封面缓存短键 key=10位十六进制 保留（诊断证据不能被毁）");
        ck_eq(rta::feedback::redact("OPEN backend=null rate=44100 bits=24"),
              "OPEN backend=null rate=44100 bits=24", "C6 正常设置行原样保留");
        ck_eq(rta::feedback::redact("LOG /tmp/rlplayer-playback.log line 42"),
              "LOG /tmp/rlplayer-playback.log line 42", "C7 非用户目录路径原样保留");
        ck_eq(rta::feedback::redact("LIST /Volumes/MUSIC/Album/01.flac"),
              "LIST /Volumes/MUSIC/Album/01.flac", "C8 曲库路径（无用户名）原样保留");
        ck_eq(rta::feedback::redact("see http://127.0.0.1:8899/api/diag"), "see http://127.0.0.1:8899/api/diag",
              "C9 本地 URL 原样保留");
        ck_eq(rta::feedback::redact("token="), "token=", "C10 空值不动（没有可抹的东西）");
        ck_eq(rta::feedback::redact("Note @ 2026-10-27"), "Note @ 2026-10-27",
              "C11 裸 @ 不成立邮箱，原样保留");
        ck_eq(rta::feedback::redact("key=short"), "key=short",
              "C12 裸 key 的短值不按凭据处理（长值才认，见文件头偏离 1）");
        ck_eq(rta::feedback::redact("auth=basic"), "auth=basic", "C13 裸 auth 的短值不处理");
        // 反向：长值仍然要被吃掉（证明 C12/C13 不是"整条规则失效"）
        ck_eq(rta::feedback::redact("key=0123456789abcdef0123456789abcdef"),
              "key=<redacted>", "C14 裸 key 的 32 位长值仍然被抹（规则没失效）");
    }

    // ---------------------------------------------------------------- D 段（性质）
    std::printf("\n-- D. 性质：幂等 / 计数 / 规则清单 --\n");
    {
        const std::string once = rta::feedback::redact(kAuthHeader + " | " + kHomePath + " | " + kJsonToken);
        const std::string twice = rta::feedback::redact(once);
        ck_eq(twice, once, "D1 幂等：redact(redact(x)) == redact(x)");

        rta::feedback::RedactStats st;
        const std::string many = rta::feedback::redact(kJsonToken + "\n" + kHomePath + "\n" + kAuthHeader,
                                                       &st);
        ck(st.credential_kv >= 1, "D2 统计：credential_kv 命中 ≥1",
           "实际 " + std::to_string(st.credential_kv));
        ck(st.user_path >= 1, "D3 统计：user_path 命中 ≥1", "实际 " + std::to_string(st.user_path));
        ck(st.header_value >= 1, "D3b 统计：header_value 命中 ≥1",
           "实际 " + std::to_string(st.header_value));
        ck(st.total() >= 3, "D4 统计：总数 ≥3（证明真的改过东西，不是 applied:true 空话）",
           "实际 " + std::to_string(st.total()));
        ck(!many.empty(), "D5 输出非空");

        rta::feedback::RedactStats clean;
        rta::feedback::redact("OPEN backend=null rate=44100", &clean);
        ck(clean.total() == 0, "D6 正常内容不会产生任何脱敏计数（反向对照）",
           "实际 " + std::to_string(clean.total()));

        const auto rules = rta::feedback::redaction_rules();
        ck(rules.size() == 9, "D7 规则清单 9 条（与 feedback_redact.h 头注释一一对应）",
           "实际 " + std::to_string(rules.size()));
        bool hasCred = false, hasUser = false;
        for (const auto& r : rules) {
            if (r == "credential_kv") hasCred = true;
            if (r == "user_path") hasUser = true;
        }
        ck(hasCred && hasUser, "D8 规则清单含 credential_kv / user_path");
        ck(rta::feedback::redaction_summary_zh().find("<user>") != std::string::npos,
           "D9 给人看的说明里写明了 <user> 标记");
    }

    // ---------------------------------------------------------------- E 段（自文档不被自己打烂）
    // 这两条是**实测事故**的回归（2026-10-27 17:10 在真机上跑 /api/diagzip 才暴露，
    // 单测最初没覆盖到 —— 记在这里防止再犯）：
    //   ① 规则名 "bearer_token" 被 bearer 规则当成 `Bearer <token>` 吃掉，
    //      diag.json 的 rules 数组变成 "bearer<redacted>" ⟹ 文档被自己改坏。
    //   ② README 里 "Authorization: / Proxy-Authorization: ..." 被 auth_header 规则整行吃掉。
    std::printf("\n-- E. 自文档完整性：规则说明不许被自己的规则打烂 --\n");
    {
        const std::string summary = rta::feedback::redaction_summary_zh();
        ck_eq(rta::feedback::redact(summary), summary,
              "E1 规则说明过 redact() 后**逐字不变**（自文档不会被自己改写）");

        // 规则名成数组形态后也要活下来（diag.json 里就是这么拼的）
        std::string arr = "[";
        const auto rules = rta::feedback::redaction_rules();
        for (size_t i = 0; i < rules.size(); ++i) {
            if (i) arr += ",";
            arr += "\"" + rules[i] + "\"";
        }
        arr += "]";
        ck_eq(rta::feedback::redact(arr), arr,
              "E2 rules 数组（含 bearer_token / credential_kv / auth_header）原样保留");

        ck_eq(rta::feedback::redact("bearer_token"), "bearer_token",
              "E3 规则名 bearer_token 不被当成 Bearer 凭据（要求 Bearer 后必须有空格）");
        // 但真正的 Bearer 头仍然要抹（证明 E3 不是把规则整体关掉）
        ck_eq(rta::feedback::redact("Bearer abcdef123456"), "Bearer <redacted>",
              "E4 真 Bearer 头仍然被抹（规则没被关掉）");
        ck_eq(rta::feedback::redact("bearer   tok_abcdef"), "bearer   <redacted>",
              "E5 多个空格也认");
    }

    std::printf("\n== 结果: %d passed, %d failed ==\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
