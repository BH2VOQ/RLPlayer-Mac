// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_update_check.cpp — F-4 自动更新的**离线**门禁（不联网、不开窗口、不碰音频设备）
//
// 判据设计原则（铁律 3：测试"通过"≠测对了东西）：
//   ① 版本比较用**真值表**，且必须能区分"数值比较"与"字符串比较"：
//      1.0.10 > 1.0.9 在字符串比较下是**错的**（"1.0.10" < "1.0.9" 逐字节），
//      所以这一条能真正证明实现走的是数值比较。
//   ② sha256 用 **NIST/FIPS 180-4 官方向量**（空串 / "abc" / 448 位边界 / 896 位边界 /
//      一百万 'a'）。只测"算两遍一样"什么也证明不了 —— 错的实现也自洽。
//   ③ 白名单用**对抗用例**：形近域名、http、user@host、带端口，必须全部拒绝。
//   ④ 「篡改必失败」不只测 sha 不等，而是测**完整安装门禁函数**：
//      清单写 A、文件实际是 B ⟹ verify_downloaded_file 返回 false 且带上"不替换"的语义。
//   ⑤ 「失败不得写已是最新」：网络/鉴权/HTTP/解析/白名单五条独立分支逐条断言，
//      并交叉断言它们**都不等于** UpToDate。
#include "net/update_check.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using namespace rta::update;

static int g_fail = 0;
static int g_pass = 0;

static void ck(bool ok, const std::string& what, const std::string& detail = "") {
    if (ok) { ++g_pass; std::printf("  [PASS] %s\n", what.c_str()); }
    else {
        ++g_fail;
        std::printf("  [FAIL] %s", what.c_str());
        if (!detail.empty()) std::printf("  —— %s", detail.c_str());
        std::printf("\n");
    }
}

static const char* cmp_name(VersionCmp c) {
    switch (c) {
        case VersionCmp::Less: return "<";
        case VersionCmp::Equal: return "==";
        case VersionCmp::Greater: return ">";
        case VersionCmp::Invalid: return "INVALID";
    }
    return "?";
}

// 真值表一行：比较 lhs 与 rhs，期望某个关系；同时断言**反向也成立**（反对称性）。
static void ck_cmp(const std::string& lhs, const std::string& rhs, VersionCmp want) {
    const Version a = parse_version(lhs);
    const Version b = parse_version(rhs);
    if (!a.valid || !b.valid) {
        ck(false, lhs + " ? " + rhs, "解析失败（a.valid=" + std::to_string(a.valid) +
                                      " b.valid=" + std::to_string(b.valid) + "）");
        return;
    }
    const VersionCmp got = compare_versions(a, b);
    const bool ok = (got == want);
    const VersionCmp rev = compare_versions(b, a);
    const VersionCmp wantRev = (want == VersionCmp::Less) ? VersionCmp::Greater
                            : (want == VersionCmp::Greater) ? VersionCmp::Less
                                                            : VersionCmp::Equal;
    const bool okRev = (rev == wantRev);
    ck(ok && okRev,
       lhs + " " + cmp_name(want) + " " + rhs,
       std::string("实际 ") + cmp_name(got) + "（反向 " + cmp_name(rev) + "，期望 " +
           cmp_name(wantRev) + "）");
}

int main() {
    setvbuf(stdout, nullptr, _IONBF, 0);

    // =====================================================================
    std::printf("=== 1. 版本比较真值表 ===\n");
    // =====================================================================
    // 1.1 预发布 vs 正式版（用户明确要求：1.0.5-beta.1 < 1.0.5）
    ck_cmp("1.0.5-beta.1", "1.0.5",   VersionCmp::Less);
    ck_cmp("1.0.5",       "1.0.5-beta.1", VersionCmp::Greater);
    // 1.2 预发布序号递增
    ck_cmp("1.0.5-beta.2", "1.0.5-beta.1", VersionCmp::Greater);
    // 1.3 数值比较，不是字符串比较（字符串下 "1.0.10" < "1.0.9"）
    ck_cmp("1.0.10", "1.0.9", VersionCmp::Greater);
    // 证明这条真的能区分：字符串比较会给出相反结果
    {
        const std::string s1 = "1.0.10", s2 = "1.0.9";
        const bool strSaysGreater = (s1 > s2);
        ck(!strSaysGreater,
           "对照组：字符串比较确实给出 1.0.10 < 1.0.9（证明上面的用例有区分力）",
           "s1=" + s1 + " s2=" + s2);
    }
    // 1.4 相等（含不同写法）
    ck_cmp("1.0.5-beta.1", "1.0.5-beta.1", VersionCmp::Equal);
    ck_cmp("1.0.0", "1.0",  VersionCmp::Equal);
    ck_cmp("v1.0.4", "1.0.4", VersionCmp::Equal);
    ck_cmp("1.0.5+build7", "1.0.5", VersionCmp::Equal);          // 构建元数据忽略
    // 1.5 预发布标识符长度（前缀短的更低）
    ck_cmp("1.0.5-beta", "1.0.5-beta.1", VersionCmp::Less);
    // 1.6 数字段前缀 vs 正式版
    ck_cmp("1.0.5-alpha", "1.0.5-beta", VersionCmp::Less);       // 字典序
    ck_cmp("1.0.5-rc.1", "1.0.5",       VersionCmp::Less);
    // 1.7 次版本/主版本跃迁
    ck_cmp("1.1.0", "1.0.99", VersionCmp::Greater);
    ck_cmp("2.0.0", "1.99.99", VersionCmp::Greater);
    // 1.8 预发布中的纯数字 vs 字母（SemVer：数字 < 字母）
    ck_cmp("1.0.5-1", "1.0.5-alpha", VersionCmp::Less);
    // 1.9 预发布数字按**数值**比，不是字符串（beta.2 vs beta.10）
    ck_cmp("1.0.5-beta.10", "1.0.5-beta.2", VersionCmp::Greater);

    // 1.10 非法输入：不崩、valid=false，且比较返回 Invalid（绝不当成"有更新"）
    {
        const char* bad[] = {"", "   ", "v", "-beta.1", "1.0.5-", "1.0.5-beta..1",
                             "1..0", "a.b.c", "1.0.5-beta.", "1.2.3.4.5", "1.0.-1"};
        for (const char* b : bad) {
            const Version v = parse_version(b);
            ck(!v.valid, std::string("非法版本号判非法：\"") + b + "\"");
        }
    }
    // 1.11 非法输入参与比较必须是 Invalid，且 is_newer 必须 false
    {
        const Version a = parse_version("1.0.5");
        const Version bad = parse_version("not-a-version");
        ck(compare_versions(a, bad) == VersionCmp::Invalid, "合法 vs 非法 → Invalid（不是 Greater）");
        ck(!is_newer("not-a-version", "1.0.5"), "非法远端版本 ⟹ is_newer=false（不会误报更新）");
        ck(!is_newer("1.0.5", "bogus-local"), "非法本地版本 ⟹ is_newer=false");
    }
    // 1.12 is_newer 的真实场景（当前版本 1.0.5-beta.1）
    ck(is_newer("1.0.5", "1.0.5-beta.1"),     "1.0.5 比当前 1.0.5-beta.1 新");
    ck(!is_newer("1.0.4", "1.0.5-beta.1"),    "1.0.4 不比当前新");
    ck(!is_newer("1.0.5-beta.1", "1.0.5-beta.1"), "同版本不算新");

    // =====================================================================
    std::printf("\n=== 2. SHA-256 官方标准向量（FIPS 180-4 / NIST）===\n");
    // =====================================================================
    ck(sha256_hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
       "空串 → e3b0c442…", sha256_hex(""));
    ck(sha256_hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
       "\"abc\" → ba7816bf…", sha256_hex("abc"));
    ck(sha256_hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
           "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
       "448-bit 向量 → 248d6a61…",
       sha256_hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"));
    ck(sha256_hex("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmno"
                  "ijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu") ==
           "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1",
       "896-bit 向量 → cf5b16a7…");
    {
        // 一百万 'a'：走多块循环，能证明长度填充与块循环都对
        std::string million(1000000, 'a');
        ck(sha256_hex(million) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
           "1,000,000 × 'a' → cdc76e5c…", sha256_hex(million));
    }
    // 2.1 长度敏感性：只差 1 字节必须不同（防"只算前缀"）
    ck(sha256_hex("abc") != sha256_hex("abd"), "不同内容 → 不同摘要");
    // 2.2 文件路径与内存路径必须一致（证明读文件这条路没错）
    {
        const std::string tmp = "/tmp/rlplayer-f4-sha-test.bin";
        FILE* f = std::fopen(tmp.c_str(), "wb");
        ck(f != nullptr, "能创建临时文件");
        if (f) {
            const std::string payload = "abc";
            std::fwrite(payload.data(), 1, payload.size(), f);
            std::fclose(f);
            std::string hex, err;
            const bool ok = sha256_file(tmp, hex, err);
            ck(ok && hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
               "sha256_file 读文件得到与内存一致的官方摘要", ok ? hex : err);
            std::remove(tmp.c_str());
        }
    }

    // =====================================================================
    std::printf("\n=== 3. 下载 URL 白名单 ===\n");
    // =====================================================================
    const char* allow[] = {
        "https://github.com/BH2VOQ/RLPlayer-Mac/releases/download/v1.0.4/x.dmg",
        "https://raw.githubusercontent.com/BH2VOQ/RLPlayer-Mac/main/latest.json",
        "HTTPS://RAW.GITHUBUSERCONTENT.COM/x/y.dmg",     // scheme/host 大小写不敏感
    };
    for (const char* u : allow) ck(update_download_url_allowed(u), std::string("放行：") + u);

    const char* deny[] = {
        "http://raw.githubusercontent.com/x/y.dmg",               // 非 https
        "https://evil.com/x/y.dmg",                               // 别的域名
        "https://raw.githubusercontent.com.evil.com/x/y.dmg",     // 后缀伪装
        "https://evilraw.githubusercontent.com/x/y.dmg",         // 前缀伪装
        "https://raw.githubusercontent.com:8443/x/y.dmg",         // 端口变体
        "https://user@raw.githubusercontent.com/x/y.dmg",         // userinfo 伪装
        "https://raw.githubusercontent.com/",                     // 没有路径
        "https://raw.githubusercontent.com",                      // 没有路径
        "file:///etc/passwd",                                     // 本地文件
        "data:text/plain,hi",                                     // data URI
        "javascript:alert(1)",                                    // 脚本
        "",                                                       // 空
        "https://raw.githubusercontent.com/x/y.dmg\nHost: evil.com",  // CRLF 注入
    };
    for (const char* u : deny) ck(!update_download_url_allowed(u), std::string("拒绝：") + u);

    // 3b. 私有路径的相对地址解析（2026-10-26 实测：私有仓库 release 附件对 token 全 403，
    //     所以 dmg 必须放在仓库文件里、走 raw 端点）
    {
        const std::string r1 = resolve_private_download_url("dist/RLPlayer-1.0.5.dmg", "feat/macos-platform");
        // 2026-10-26 迁到 GitHub 后，相对路径的形状是
        //   https://raw.githubusercontent.com/<owner>/<repo>/<ref>/<path>
        // ref 是**路径段**（GitHub 的约定），不再是 Gitea 那种 ?ref= 查询参数。
        ck(update_download_url_allowed(r1) && r1.find("/BH2VOQ/RLPlayer-Mac/feat/macos-platform/dist/RLPlayer-1.0.5.dmg") != std::string::npos,
           "相对路径 → raw 绝对地址（过白名单）", r1);
        ck(r1.find("raw.githubusercontent.com/BH2VOQ/RLPlayer-Mac/") != std::string::npos,
           "ref 作为路径段拼进 raw 地址（GitHub 约定，不是 ?ref=）", r1);
        const std::string r2 = resolve_private_download_url("/lead/RLPlayer.dmg", "");
        ck(!r2.empty() && r2.find("/BH2VOQ/RLPlayer-Mac/main/lead/RLPlayer.dmg") != std::string::npos,
           "前导 '/' 被剥掉，且空 ref 回退到仓库默认分支", r2);
        const std::string abs = "https://raw.githubusercontent.com/BH2VOQ/RLPlayer-Mac/main/x.dmg";
        ck(resolve_private_download_url(abs, "main") == abs, "已是 https 绝对地址 ⟹ 原样返回");
        ck(resolve_private_download_url("https://evil.com/x.dmg", "main").empty(),
           "绝对地址但非白名单 ⟹ 拒绝");
        ck(resolve_private_download_url("", "main").empty(), "空值 ⟹ 空");
    }

    // =====================================================================
    std::printf("\n=== 4. 清单解析 ===\n");
    // =====================================================================
    const std::string kShaA = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    const std::string goodJson =
        "{\"version\":\"1.0.5\",\"download_url\":"
        "\"https://github.com/BH2VOQ/RLPlayer-Mac/releases/download/v1.0.5/RLPlayer.dmg\","
        "\"sha256\":\"" + kShaA + "\",\"size\":7139420,\"notes\":\"修复若干问题\"}";
    {
        const Manifest m = parse_update_manifest(goodJson);
        ck(m.valid, "合法清单解析成功", m.error);
        ck(m.version == "1.0.5", "version 字段");
        ck(m.sha256 == kShaA, "sha256 字段（保持小写）");
        ck(m.size == 7139420, "size 字段");
        ck(m.notes == "修复若干问题", "notes UTF-8 字段");
    }
    // 4.1 缺必填项
    ck(!parse_update_manifest("{}").valid, "空对象 → 非法");
    ck(!parse_update_manifest("not json").valid, "非 JSON → 非法");
    ck(!parse_update_manifest("[]").valid, "数组 → 非法");
    ck(!parse_update_manifest(
            "{\"download_url\":\"https://github.com/BH2VOQ/RLPlayer-Mac/a.dmg\",\"sha256\":\"" + kShaA + "\"}").valid,
       "缺 version → 非法");
    ck(!parse_update_manifest(
            "{\"version\":\"1.0.5\",\"sha256\":\"" + kShaA + "\"}").valid,
       "缺 download_url → 非法");
    ck(!parse_update_manifest(
            "{\"version\":\"1.0.5\",\"download_url\":\"https://github.com/BH2VOQ/RLPlayer-Mac/a.dmg\"}").valid,
       "缺 sha256 → 非法");
    // 4.2 字段格式不对
    ck(!parse_update_manifest(
            "{\"version\":\"x.y\",\"download_url\":\"https://github.com/BH2VOQ/RLPlayer-Mac/a.dmg\","
            "\"sha256\":\"" + kShaA + "\"}").valid,
       "version 非法 → 非法");
    ck(!parse_update_manifest(
            "{\"version\":\"1.0.5\",\"download_url\":\"https://evil.com/a.dmg\","
            "\"sha256\":\"" + kShaA + "\"}").valid,
       "download_url 非白名单 → 非法（防篡改成任意地址）");
    ck(!parse_update_manifest(
            "{\"version\":\"1.0.5\",\"download_url\":\"https://github.com/BH2VOQ/RLPlayer-Mac/a.dmg\","
            "\"sha256\":\"deadbeef\"}").valid,
       "sha256 长度不对 → 非法（防截断技巧）");
    ck(!parse_update_manifest(
            "{\"version\":\"1.0.5\",\"download_url\":\"https://github.com/BH2VOQ/RLPlayer-Mac/a.dmg\","
            "\"sha256\":\"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\"}").valid,
       "sha256 含非 hex → 非法");
    // 4.2b 相对路径（私有仓库路径）与路径穿越防护
    {
        const Manifest ok = parse_update_manifest(
            "{\"version\":\"1.0.5\",\"download_url\":\"dist/RLPlayer-1.0.5.dmg\","
            "\"sha256\":\"" + kShaA + "\"}");
        ck(ok.valid && ok.downloadUrlIsRelative, "仓库内相对路径 ⟹ 合法且标记为 relative", ok.error);

        const char* bad[] = {
            "../etc/passwd",                       // 路径穿越
            "dist/../../secret.dmg",               // 路径穿越
            "dist\\file.dmg",                      // 反斜杠
            "dist/file name.dmg",                  // 空格
            "dist/file\"quote.dmg",                 // 引号
        };
        for (const char* b : bad) {
            const Manifest m = parse_update_manifest(
                std::string("{\"version\":\"1.0.5\",\"download_url\":\"") + b +
                "\",\"sha256\":\"" + kShaA + "\"}");
            ck(!m.valid, std::string("非法相对路径 ⟹ 拒绝：") + b, m.error);
        }
    }

    // 4.3 sha256 大小写归一
    {
        std::string upper = kShaA;
        for (char& c : upper) c = (char)std::toupper((unsigned char)c);
        const Manifest m = parse_update_manifest(
            "{\"version\":\"1.0.5\",\"download_url\":\"https://github.com/BH2VOQ/RLPlayer-Mac/a.dmg\","
            "\"sha256\":\"" + upper + "\"}");
        ck(m.valid && m.sha256 == kShaA, "大写 sha256 归一为小写", m.sha256);
    }

    // 4.4 hex 比较本身：必须**全长**比较，不能只比前缀（攻击者可磨到前 N 位相同）
    {
        const std::string a64 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
        std::string lastDiff = a64;
        lastDiff[63] = (lastDiff[63] == '0') ? '1' : '0';       // 只改**最后一位**
        ck(hex_equals_ci(a64, a64), "hex 完全相同 → true");
        ck(!hex_equals_ci(a64, lastDiff), "【关键】只差最后 1 位 → false（不是前缀比较）", lastDiff);
        ck(hex_equals_ci(a64, detail::lower(a64)) , "大小写不敏感");
        ck(!hex_equals_ci(a64, a64.substr(0, 8)), "长度不等 → false（防截断后只比前 8 位）");
        ck(!hex_equals_ci("", ""), "双空 → false（空串绝不能算匹配）");
        ck(!hex_equals_ci(a64, a64.substr(0, 63)), "少一位 → false");
    }

    // =====================================================================
    std::printf("\n=== 5. 「篡改必失败」安装门禁（最关键的一条）===\n");
    // =====================================================================
    // 场景：清单声明 sha256=abc 的摘要，而磁盘上实际文件内容不是 "abc" ⟹ 必须拒绝安装。
    {
        const std::string tmp = "/tmp/rlplayer-f4-tamper.bin";
        FILE* f = std::fopen(tmp.c_str(), "wb");
        ck(f != nullptr, "创建待校验文件");
        if (f) {
            const std::string tampered = "abc-TAMPERED-PAYLOAD";   // 实际内容
            std::fwrite(tampered.data(), 1, tampered.size(), f);
            std::fclose(f);

            std::string actualHex, err;
            ck(sha256_file(tmp, actualHex, err), "能计算实际文件摘要", err);
            ck(actualHex != kShaA, "实际摘要 ≠ 清单声明（前提成立：文件确实被改过）");

            // ---- 这是安装流程必须走的门禁 ----
            const VerifyResult vr = verify_downloaded_file(tmp, kShaA, 0);
            ck(!vr.ok, "【篡改】verify_downloaded_file 返回失败 ⟹ 中止安装、不替换 .app", vr.error);
            ck(vr.reason == VerifyFailReason::Sha256Mismatch, "失败原因是 sha256 不匹配（不是网络/IO）",
               std::to_string((int)vr.reason));

            // 同大小但内容不同 ⟹ size 闸门放行、sha 闸门必须拦下（证明两道闸门独立）
            if (true) {
                const std::string tmp2 = "/tmp/rlplayer-f4-samesize.bin";
                FILE* f2 = std::fopen(tmp2.c_str(), "wb");
                if (f2) {
                    const std::string other = "abc-TAMPERED-PAYLOAX";   // 与上面等长、内容不同
                    std::fwrite(other.data(), 1, other.size(), f2);
                    std::fclose(f2);
                    const VerifyResult vs = verify_downloaded_file(tmp2, kShaA, (long long)other.size());
                    ck(!vs.ok && vs.reason == VerifyFailReason::Sha256Mismatch,
                       "【同大小不同内容】size 通过但 sha 拦下 → 仍拒绝", vs.error);
                    std::remove(tmp2.c_str());
                }
            }

            // 声明了 size 且不符也必须失败
            const VerifyResult vr2 = verify_downloaded_file(tmp, actualHex, (long long)tampered.size() + 1);
            ck(!vr2.ok && vr2.reason == VerifyFailReason::SizeMismatch,
               "【截断】size 不符 → 失败（独立于 sha 的闸门）", vr2.error);

            // 正确摘要 + 正确 size → 通过（证明门禁不是"一律拒绝"）
            const VerifyResult vr3 = verify_downloaded_file(tmp, actualHex, (long long)tampered.size());
            ck(vr3.ok, "摘要与 size 都对 → 通过（门禁不是恒假）", vr3.error);

            // 文件不存在
            const VerifyResult vr4 = verify_downloaded_file("/tmp/rlplayer-f4-not-exist-xyz.bin", kShaA, 0);
            ck(!vr4.ok && vr4.reason == VerifyFailReason::OpenFailed, "文件不存在 → 失败（IO）", vr4.error);

            // 空清单 sha（伪造清单漏填）→ 失败，绝不能"没写摘要就放行"
            const VerifyResult vr5 = verify_downloaded_file(tmp, "", 0);
            ck(!vr5.ok && vr5.reason == VerifyFailReason::MissingExpectedSha,
               "清单没给 sha256 → 拒绝（缺省即拒绝，不是缺省即放行）", vr5.error);

            std::remove(tmp.c_str());
        }
    }
    // 5.1 大小写不同的 hex 也要能通过（Gitea 可能大写）
    {
        std::string upper = kShaA;
        for (char& c : upper) c = (char)std::toupper((unsigned char)c);
        const std::string tmp = "/tmp/rlplayer-f4-ci.bin";
        FILE* f = std::fopen(tmp.c_str(), "wb");
        if (f) {
            std::fwrite("abc", 1, 3, f);
            std::fclose(f);
            const VerifyResult vr = verify_downloaded_file(tmp, upper, 3);
            ck(vr.ok, "大写 hex 也能通过校验（大小写不敏感比较）", vr.error);
            std::remove(tmp.c_str());
        }
    }

    // =====================================================================
    std::printf("\n=== 6. 决策分支：失败不得落到「已是最新」===\n");
    // =====================================================================
    const std::string kLocal = "1.0.5-beta.1";
    const std::string goodBody = goodJson;
    {
        // 6.1 正常：有更新
        const CheckResult r = evaluate_update_check(kLocal, true, 200, goodBody);
        ck(r.decision == Decision::UpdateAvailable, "远端 1.0.5 > 本地 1.0.5-beta.1 ⟹ 有更新", r.error);
        ck(r.available() && !r.up_to_date(), "语义：available 且非 up_to_date");
        ck(std::string(r.code()) == "update-available", "决策码 update-available", r.code());
    }
    {
        // 6.2 确实最新（只有这一条能说「已是最新」）
        const std::string sameBody =
            "{\"version\":\"1.0.5-beta.1\",\"download_url\":"
            "\"https://github.com/BH2VOQ/RLPlayer-Mac/a.dmg\",\"sha256\":\"" + kShaA + "\"}";
        const CheckResult r = evaluate_update_check(kLocal, true, 200, sameBody);
        ck(r.decision == Decision::UpToDate, "同版本 ⟹ 已是最新", r.error);
        ck(r.up_to_date(), "up_to_date() 为真");
        // 远端更旧也不算更新（降级不提示）
        const std::string olderBody =
            "{\"version\":\"1.0.4\",\"download_url\":"
            "\"https://github.com/BH2VOQ/RLPlayer-Mac/a.dmg\",\"sha256\":\"" + kShaA + "\"}";
        const CheckResult r2 = evaluate_update_check(kLocal, true, 200, olderBody);
        ck(r2.decision == Decision::UpToDate, "远端更旧 ⟹ 不提示更新（不下拉降级）", r2.error);
    }
    {
        // 6.3 网络失败
        const CheckResult r = evaluate_update_check(kLocal, false, 0, "");
        ck(r.decision == Decision::FailedNetwork, "网络失败 ⟹ FailedNetwork", r.error);
        ck(!r.up_to_date(), "【关键】网络失败不得写成「已是最新」");
        ck(!r.ok(), "网络失败时 ok()=false（UI 不该显示绿色/最新）");
        ck(r.error.find("最新") == std::string::npos, "网络失败的错误文案不含「最新」");
    }
    {
        // 6.4 鉴权失败（401/403）
        for (int code : {401, 403}) {
            const CheckResult r = evaluate_update_check(kLocal, false, code, "");
            ck(r.decision == Decision::FailedAuth, "HTTP " + std::to_string(code) + " ⟹ FailedAuth", r.error);
            ck(!r.up_to_date(), "【关键】鉴权失败不得写成「已是最新」");
            ck(r.error.find("最新") == std::string::npos, "鉴权失败文案不含「最新」");
        }
    }
    {
        // 6.5 其它 HTTP 错误（含 404 = 公开清单仓库还没建）
        for (int code : {404, 500, 502, 429}) {
            const CheckResult r = evaluate_update_check(kLocal, false, code, "");
            ck(r.decision == Decision::FailedHttp, "HTTP " + std::to_string(code) + " ⟹ FailedHttp", r.error);
            ck(!r.up_to_date(), "HTTP " + std::to_string(code) + " 不得写成「已是最新」");
        }
    }
    {
        // 6.6 解析失败（200 但内容是垃圾）
        for (const std::string& bad : {std::string(""), std::string("<html>502</html>"),
                                       std::string("null"), std::string("{}")}) {
            const CheckResult r = evaluate_update_check(kLocal, true, 200, bad);
            ck(r.decision == Decision::FailedParse,
               "200 + 非法清单 ⟹ FailedParse（内容：" + bad.substr(0, 16) + "）", r.error);
            ck(!r.up_to_date(), "解析失败不得写成「已是最新」");
        }
    }
    {
        // 6.7 清单合法但下载地址被换成别的域
        const std::string badUrlBody =
            "{\"version\":\"9.9.9\",\"download_url\":\"https://evil.com/x.dmg\","
            "\"sha256\":\"" + kShaA + "\"}";
        const CheckResult r = evaluate_update_check(kLocal, true, 200, badUrlBody);
        ck(r.decision == Decision::FailedParse || r.decision == Decision::FailedBadUrl,
           "下载地址被篡改 ⟹ 拒绝（FailedParse/FailedBadUrl）", std::string(r.code()) + " " + r.error);
        ck(!r.available(), "【关键】地址被篡改时不得进入「有更新」状态");
        ck(!r.up_to_date(), "地址被篡改时也不得写「已是最新」");
    }
    {
        // 6.8 本地版本非法 → 不能声称最新，也不能乱装
        const CheckResult r = evaluate_update_check("bogus", true, 200, goodBody);
        ck(r.decision == Decision::FailedParse, "本地版本非法 ⟹ FailedParse（不猜）", r.error);
        ck(!r.up_to_date(), "本地版本非法时不得写「已是最新」");
    }
    {
        // 6.9 五种失败彼此不同（防止有人图省事把它们并成一个分支）
        std::vector<Decision> fails = {
            evaluate_update_check(kLocal, false, 0, "").decision,
            evaluate_update_check(kLocal, false, 401, "").decision,
            evaluate_update_check(kLocal, false, 404, "").decision,
            evaluate_update_check(kLocal, true, 200, "garbage").decision,
        };
        bool allDistinct = true;
        for (size_t i = 0; i < fails.size(); ++i)
            for (size_t j = i + 1; j < fails.size(); ++j)
                if (fails[i] == fails[j]) allDistinct = false;
        ck(allDistinct, "网络/鉴权/HTTP/解析 四种失败是四个不同分支");
        for (Decision d : fails) ck(d != Decision::UpToDate && d != Decision::UpdateAvailable,
                                    std::string("失败分支 ") + decision_code(d) + " 既不最新也不是更新");
    }

    // =====================================================================
    std::printf("\n=== 7. 配置文件（缺省即安全）===\n");
    // =====================================================================
    {
        // 7.1 没有配置文件 → 匿名公开清单，不报错
        const Config c = parse_update_config("");
        ck(!c.hasToken, "空配置 ⟹ 无 token");
        ck(c.manifestUrl == kDefaultManifestUrl, "空配置 ⟹ 用默认公开清单地址");
        ck(c.manifestUrlValid, "空配置 ⟹ 清单地址有效（不报错）");
        ck(c.warning.empty(), "空配置 ⟹ 无警告（首次运行不该弹窗）");
    }
    {
        // 7.2 有 token
        const Config c = parse_update_config("token=abc123def456\nmanifest_url=https://raw.githubusercontent.com/BH2VOQ/RLPlayer-Mac/main/latest.json\n");
        ck(c.hasToken && c.token == "abc123def456", "token= 被正确读取");
        ck(c.manifestUrl == "https://raw.githubusercontent.com/BH2VOQ/RLPlayer-Mac/main/latest.json", "manifest_url 被正确读取");
    }
    {
        // 7.3 注释与空行
        const Config c = parse_update_config("# 注释行\ntoken=\n\n  # 另一条注释\n");
        ck(!c.hasToken, "token= 留空 ⟹ 视为没有 token（匿名路径）");
    }
    {
        // 7.4 非法 manifest_url 必须被标记（不静默接受任意域）
        const Config c = parse_update_config("manifest_url=https://evil.com/latest.json\n");
        ck(!c.manifestUrlValid, "非白名单 manifest_url ⟹ 标记无效");
        ck(!c.warning.empty(), "非白名单 manifest_url ⟹ 给出警告");
        ck(c.warning.find("https://evil.com") == std::string::npos ||
               c.warning.find("evil.com") == std::string::npos,
           "警告文案不回显具体主机（避免把可疑清单内容带进日志）");
    }
    {
        // 7.5 token 含空白 → 丢弃（防止复制粘贴带换行拼出非法头）
        const Config c = parse_update_config("token=abc def\n");
        ck(!c.hasToken, "含空白的 token ⟹ 丢弃");
        ck(!c.warning.empty(), "含空白的 token ⟹ 给出警告");
        ck(c.warning.find("abc") == std::string::npos, "警告文案不回显 token 内容/前缀");
    }
    {
        // 7.6 默认模板：token 必须为空（这是"缺省即安全"的落地形式）
        const std::string tpl = default_update_conf_template();
        const Config c = parse_update_config(tpl);
        ck(!c.hasToken, "默认模板 ⟹ token 为空（首次运行匿名）");
        ck(c.manifestUrl == kDefaultManifestUrl, "默认模板 ⟹ 指向默认公开清单");
        ck(tpl.find("token=\n") != std::string::npos, "模板里是 token=（空值），不是示例 token");
    }

    // =====================================================================
    std::printf("\n=== 8. 私有仓库路径：releases → latest.json 附件 ===\n");
    // =====================================================================
    {
        const std::string releases =
            "[{\"tag_name\":\"v1.0.4\",\"draft\":false,\"assets\":["
            "{\"name\":\"RLPlayer-v1.0.4-macOS-arm64.dmg\",\"size\":7139420,"
            "\"browser_download_url\":\"https://github.com/BH2VOQ/RLPlayer-Mac/releases/download/v1.0.4/x.dmg\"}]},"
            "{\"tag_name\":\"v1.0.5\",\"draft\":false,\"assets\":["
            "{\"name\":\"latest.json\",\"browser_download_url\":"
            "\"https://github.com/BH2VOQ/RLPlayer-Mac/releases/download/v1.0.5/latest.json\"}]},"
            "{\"tag_name\":\"v9.9.9\",\"draft\":true,\"assets\":["
            "{\"name\":\"latest.json\",\"browser_download_url\":"
            "\"https://github.com/BH2VOQ/RLPlayer-Mac/draft/latest.json\"}]}]";
        const ReleaseAssetLookup lk = find_manifest_asset_in_releases(releases);
        ck(lk.found, "找到 latest.json 附件", lk.error);
        ck(lk.tag == "v1.0.5", "取的是**最新非草稿** release（v1.0.5，不是 draft 的 v9.9.9）", lk.tag);
        ck(lk.url == "https://github.com/BH2VOQ/RLPlayer-Mac/releases/download/v1.0.5/latest.json",
           "附件 URL", lk.url);
    }
    {
        // 8.1 没有 latest.json 附件 → 明确失败（不退回"用 dmg URL 猜"）
        const std::string releases =
            "[{\"tag_name\":\"v1.0.4\",\"assets\":[{\"name\":\"x.dmg\","
            "\"browser_download_url\":\"https://github.com/BH2VOQ/RLPlayer-Mac/x.dmg\"}]}]";
        const ReleaseAssetLookup lk = find_manifest_asset_in_releases(releases);
        ck(!lk.found && !lk.error.empty(), "缺 latest.json 附件 ⟹ 明确失败", lk.error);
    }
    {
        // 8.2 空数组（私有仓库 token 有效但还没发布）
        const ReleaseAssetLookup lk = find_manifest_asset_in_releases("[]");
        ck(!lk.found, "无 release ⟹ 失败");
    }
    {
        // 8.3 附件地址被篡改
        const std::string releases =
            "[{\"tag_name\":\"v1.0.5\",\"assets\":[{\"name\":\"latest.json\","
            "\"browser_download_url\":\"https://evil.com/latest.json\"}]}]";
        const ReleaseAssetLookup lk = find_manifest_asset_in_releases(releases);
        ck(!lk.found, "附件地址非白名单 ⟹ 拒绝");
    }
    {
        // 8.4 非 JSON
        const ReleaseAssetLookup lk = find_manifest_asset_in_releases("<html>404</html>");
        ck(!lk.found && !lk.error.empty(), "非 JSON 响应 ⟹ 明确失败");
    }

    // =====================================================================
    // 9. 预发布/beta 接收开关（b7: update_available 纯函数）
    // =====================================================================
    std::printf("\n--- 9. 预发布/beta 接收开关 ---\n");
    {
        // 9.1 本机 1.1.4 + 远端 1.1.5-beta.1: allowPre=false ⟹ false; allowPre=true ⟹ true
        ck(!update_available("1.1.5-beta.1", "1.1.4", false),
           "1.1.4 vs 1.1.5-beta.1 (allowPre=false) ⟹ false");
        ck(update_available("1.1.5-beta.1", "1.1.4", true),
           "1.1.5-beta.1 vs 1.1.4 (allowPre=true) ⟹ true");

        // 9.2 本机 1.1.4 + 远端 1.1.5: 两种情况都 true
        ck(update_available("1.1.5", "1.1.4", false),
           "1.1.4 vs 1.1.5 (allowPre=false) ⟹ true");
        ck(update_available("1.1.5", "1.1.4", true),
           "1.1.4 vs 1.1.5 (allowPre=true) ⟹ true");

        // 9.3 本机 1.1.4-beta.2 + 远端 1.1.4-beta.1: false（不倒退）
        ck(!update_available("1.1.4-beta.1", "1.1.4-beta.2", false),
           "1.1.4-beta.2 vs 1.1.4-beta.1 (allowPre=false) ⟹ false");
        ck(!update_available("1.1.4-beta.1", "1.1.4-beta.2", true),
           "1.1.4-beta.2 vs 1.1.4-beta.1 (allowPre=true) ⟹ false");

        // 9.4 边界测试：相同版本 ⟹ false
        ck(!update_available("1.1.4", "1.1.4", false),
           "1.1.4 vs 1.1.4 (allowPre=false) ⟹ false");
        ck(!update_available("1.1.4", "1.1.4", true),
           "1.1.4 vs 1.1.4 (allowPre=true) ⟹ false");

        // 9.5 边界测试：本机 1.1.4-rc.1 + 远端 1.1.4 (正式版): 两种情况都 true（正式版比 rc 高）
        ck(update_available("1.1.4", "1.1.4-rc.1", false),
           "1.1.4-rc.1 vs 1.1.4 (allowPre=false) ⟹ true");
        ck(update_available("1.1.4", "1.1.4-rc.1", true),
           "1.1.4-rc.1 vs 1.1.4 (allowPre=true) ⟹ true");
    }

    // =====================================================================
    // 汇总
    // =====================================================================
    std::printf("\n=== 汇总：%d 通过 / %d 失败 ===\n", g_pass, g_fail);
    if (g_fail == 0) std::printf("全部通过\n");
    else std::printf("存在失败\n");
    return g_fail == 0 ? 0 : 1;
}
