// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_feedback_api.cpp — 反馈后台「纯逻辑层」的回归（校验 / 生成请求体 / 解析响应 / 错误分类 / 幂等键）
//
// ===========================================================================
// 这条判据怎么证明事（铁律 3）
//
//   本层不发网络、不读写文件、不含平台类型，宿主拿它去跑 libcurl。所以判据只能落在
//   「字节级契约」上，不能落在「请求看起来发出去了」上。三条各自的证法：
//
//   ① 生成请求体：不信「json 里有 text 字段」，而是用 rta::net::json_parse **解析回来
//      逐字节比对**（B2/B7/F3），并且 diag 用**测试自带的 base64 解码器**（不是生产代码）
//      解回来比字节（F7/E3）。若生产 encoder 与 decoder 同时写错（比如都按 4 字节对齐），
//      自带解码器能把这种「自洽的错误」拆开。
//   ② 解析响应：逐条枚举 201/200/各错误码，重点钉住 **200 + ok:false 必须判失败**
//      （HTTP 状态不能当成功），以及 **非 JSON 的 nginx HTML 不能被当成 parsed**
//      （json_parse 对 "<html>" 会返回 Num 类型，所以判据必须是 type==Obj，
//        只判 "非 Null" 就会漏 —— 这里 H10 就是钉这个）。
//   ③ 错误分类：断言的是「可重试性 + 用户可读中文的关键子串」，并**反向**断言 message
//      里不出现 URL / 后台域名 / token 明文（J13/J14/J15）——只说「提示友好」是没法验的。
//
//   边界都是**双向**的：16384 允许 / 16385 拒绝；8 MiB 允许 / 8 MiB+1 拒绝；
//   80 字符与 80 个汉字都不截断（证明按字符不按字节）、81 个 emoji 截断后仍是合法 UTF-8
//   （证明不从中间切断多字节字符）。
// ===========================================================================
#include "net/feedback_api.h"
#include "net/json.h"

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

static void ck_num(long long got, long long want, const char* what) {
    ck_eq(std::to_string(got), std::to_string(want), what);
}

static void ck_has(const std::string& hay, const std::string& needle, const char* what) {
    ck(hay.find(needle) != std::string::npos, what, "缺少子串: " + needle + "  ⟹ " + hay);
}

static void ck_not_has(const std::string& hay, const std::string& needle, const char* what) {
    ck(hay.find(needle) == std::string::npos, what, "仍含: " + needle + "  ⟹ " + hay);
}

// ---------------------------------------------------------------------------
// 测试自带的 base64 解码器：**故意不复用生产代码**，否则 encoder/decoder 一起错也测不出来
// ---------------------------------------------------------------------------
static int b64val(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

static bool b64decode(const std::string& in, std::string& out) {
    out.clear();
    if (in.empty()) return true;
    if (in.size() % 4 != 0) return false;
    for (size_t i = 0; i < in.size(); i += 4) {
        int v[4] = {0, 0, 0, 0};
        int pad = 0;
        for (int k = 0; k < 4; ++k) {
            const char c = in[i + (size_t)k];
            if (c == '=') {
                // 填充只可能出现在整个串的末尾
                if (i + 4 != in.size()) return false;
                if (pad > 0 && k != 3) return false;   // "==" 必须连续出现在最后两格
                ++pad;
            } else {
                if (pad > 0) return false;             // 填充后面不许再有数据
                v[k] = b64val(c);
                if (v[k] < 0) return false;
            }
        }
        if (pad > 2) return false;
        out += (char)((v[0] << 2) | (v[1] >> 4));
        if (pad < 2) out += (char)(((v[1] & 0x0F) << 4) | (v[2] >> 2));
        if (pad < 1) out += (char)(((v[2] & 0x03) << 6) | v[3]);
    }
    return true;
}

// ---------------------------------------------------------------------------
// 夹具
// ---------------------------------------------------------------------------
static const char* kId = "rlmac-0123456789abcdeffedcba9876543210";
static const char* kKey = "fb-20261111-ABCDEF12";

static rta::feedback::FeedbackUploadInput base_input() {
    rta::feedback::FeedbackUploadInput in;
    in.text = "播放时偶发爆音";       // 中文：验证不被转义、原样 UTF-8
    in.version = "1.3.14";
    in.os = "macOS 27.1 arm64";
    in.client = kId;
    in.idempotency_key = kKey;
    return in;
}

static rta::net::Json parse_body(const rta::feedback::FeedbackUploadBody& b) {
    return rta::net::json_parse(b.json);
}

// 真实样例（任务书给定的 watchdog 响应，逐字抄下）
static const char* kWatchdogBody =
    "{\"ok\":true,\"service\":\"rlplayer-feedback\",\"platform\":\"macos\",\"version\":1,"
    "\"serverTime\":\"2026-11-11T04:47:52Z\","
    "\"limits\":{\"textBytes\":16384,\"diagBytes\":8388608,\"ratePerMinute\":5},"
    "\"retentionDays\":90,\"deleteWindowDays\":7}";

int main() {
    std::printf("== test_feedback_api: 反馈后台纯逻辑层 ==\n");

    // ================================================================ A. 常量
    std::printf("\n-- A. 常量逐字一致（改一个字就等于换了接口）--\n");
    {
        ck_eq(rta::feedback::kFeedbackHost, "rlplayer.rainlain.com", "A1 kFeedbackHost");
        ck_eq(rta::feedback::kFeedbackBaseUrl, "https://rlplayer.rainlain.com", "A2 kFeedbackBaseUrl");
        ck_eq(rta::feedback::kFeedbackWatchdogUrl,
              "https://rlplayer.rainlain.com/api/v1/feedback/macos/watchdog", "A3 kFeedbackWatchdogUrl");
        ck_eq(rta::feedback::kFeedbackUploadUrl,
              "https://rlplayer.rainlain.com/api/v1/feedback/macos", "A4 kFeedbackUploadUrl");
        ck_eq(rta::feedback::kFeedbackTicketUrlPrefix,
              "https://rlplayer.rainlain.com/api/v1/feedback/macos/ticket/", "A5 ticket 前缀");
        ck_num(rta::feedback::kFeedbackMaxTextBytes, 16384, "A6 文本上限 16384 字节");
        ck_num(rta::feedback::kFeedbackMaxDiagBytes, 8388608, "A7 诊断包上限 8 MiB");
        ck_num(rta::feedback::kFeedbackMaxVersionChars, 80, "A8 version 上限 80 字符");
        ck_num(rta::feedback::kFeedbackMaxOsChars, 120, "A9 os 上限 120 字符");
        ck_num(rta::feedback::kFeedbackMaxClientChars, 160, "A10 client 上限 160 字符");
        ck_num(rta::feedback::kFeedbackMinKeyChars, 8, "A11 幂等键最短 8");
        ck_num(rta::feedback::kFeedbackMaxKeyChars, 160, "A12 幂等键最长 160");
        ck_num(rta::feedback::kFeedbackWatchdogTimeoutMs, 10000, "A13 watchdog 超时 10s");
        ck_num(rta::feedback::kFeedbackUploadTimeoutMs, 120000, "A14 上传超时 120s");
        // URL 必须落在 kFeedbackHost 上：否则「改了域名但没改 URL」这种漏改测不出来
        ck_eq(std::string(rta::feedback::kFeedbackBaseUrl), "https://" + std::string(rta::feedback::kFeedbackHost),
              "A15 BaseUrl == https:// + Host（防漏改）");
    }

    // ================================================================ B. text 清洗与上限
    std::printf("\n-- B. text：UTF-8 清洗 + 按字节判空/上限 --\n");
    {
        // B1 合法 UTF-8（中文 + emoji 4 字节）原样保留
        {
            auto in = base_input();
            in.text = "爆音🎵abc";
            const auto r = rta::feedback::build_feedback_upload(in);
            ck(r.ok, "B1 合法 UTF-8 通过", r.code);
            ck_eq(parse_body(r)["text"].s(), in.text, "B1b 中文 + emoji 原样保留（不转义、不改字节）");
            ck_num((long long)r.text_bytes, (long long)in.text.size(), "B1c text_bytes = 原始字节数");
        }
        // B2 单个游离续字节 0x80 → 一个 U+FFFD
        {
            auto in = base_input();
            in.text = std::string("a\x80") + "b";
            const auto r = rta::feedback::build_feedback_upload(in);
            ck(r.ok, "B2 非法字节不导致整条失败（清洗而非拒绝）", r.code);
            ck_eq(parse_body(r)["text"].s(), "a\xEF\xBF\xBD" "b", "B2b 0x80 → U+FFFD（EF BF BD）");
        }
        // B3 被截断的 3 字节序列 → **一个** U+FFFD（不是每个字节各一个）
        {
            auto in = base_input();
            in.text = std::string("\xE4\xBD");
            const auto r = rta::feedback::build_feedback_upload(in);
            ck_eq(parse_body(r)["text"].s(), "\xEF\xBF\xBD", "B3 截断的 3 字节序列 → 一个 U+FFFD");
        }
        // B4 被截断的 4 字节（emoji 半截）→ 一个 U+FFFD
        {
            auto in = base_input();
            in.text = std::string("\xF0\x9F\x92");
            const auto r = rta::feedback::build_feedback_upload(in);
            ck_eq(parse_body(r)["text"].s(), "\xEF\xBF\xBD", "B4 截断的 4 字节序列 → 一个 U+FFFD");
        }
        // B5 0xFF 永不合法 → 一个 U+FFFD
        {
            auto in = base_input();
            in.text = std::string("\xFF");
            const auto r = rta::feedback::build_feedback_upload(in);
            ck_eq(parse_body(r)["text"].s(), "\xEF\xBF\xBD", "B5 0xFF → 一个 U+FFFD");
        }
        // B6 过度长编码（C0 AF）不得被当成 '/' 放行
        {
            auto in = base_input();
            in.text = std::string("\xC0\xAF");
            const auto r = rta::feedback::build_feedback_upload(in);
            const std::string g = parse_body(r)["text"].s();
            ck(g.find('/') == std::string::npos, "B6 过度长编码 C0 AF 不被解成 '/'", g);
            ck(g.find("\xEF\xBF\xBD") != std::string::npos, "B6b 过度长编码产生 U+FFFD", g);
        }
        // B7 全空白（trim 后空）→ empty_text
        {
            auto in = base_input();
            in.text = " \t\r\n  \t ";
            const auto r = rta::feedback::build_feedback_upload(in);
            ck(!r.ok, "B7 全空白 text 必须失败", "ok 竟然为 true");
            ck_eq(r.code, "empty_text", "B7b code == empty_text");
            ck(r.error.find("空") != std::string::npos, "B7c error 是可直接显示的中文（含「空」）", r.error);
            ck(r.json.empty(), "B7d 失败时不产出可发送的 body（防止宿主误发半成品）", r.json);
        }
        // B8 空串同样是 empty_text
        {
            auto in = base_input();
            in.text = "";
            const auto r = rta::feedback::build_feedback_upload(in);
            ck_eq(r.code, "empty_text", "B8 空串 → empty_text");
        }
        // B9 U+3000 全角空格：**不算** ASCII 空白（文档化的判据，避免误判中文文本为空）
        {
            auto in = base_input();
            in.text = "\xE3\x80\x80";
            const auto r = rta::feedback::build_feedback_upload(in);
            ck(r.ok, "B9 全角空格 U+3000 不算空白（只有 ASCII 空白判空）", r.code);
        }
        // B10 16384 字节允许 / B11 16385 拒绝（双向边界）
        {
            auto in = base_input();
            in.text = std::string((size_t)rta::feedback::kFeedbackMaxTextBytes, 'x');
            const auto r = rta::feedback::build_feedback_upload(in);
            ck(r.ok, "B10 恰好 16384 字节允许", r.code);
            ck_num((long long)r.text_bytes, 16384, "B10b text_bytes == 16384");

            in.text += "y";
            const auto r2 = rta::feedback::build_feedback_upload(in);
            ck(!r2.ok, "B11 16385 字节必须失败", "竟然通过了");
            ck_eq(r2.code, "text_too_long", "B11b code == text_too_long");
            ck(r2.error.find("16384") != std::string::npos, "B11c error 里写明上限，用户能自己裁剪",
               r2.error);
        }
        // B12 text_bytes 统计的是**清洗后**的字节数（不然宿主与后台会对不上）
        {
            auto in = base_input();
            in.text = std::string("a\x80\x80\x80") + "b";    // 1 + 3×3 + 1 = 11
            const auto r = rta::feedback::build_feedback_upload(in);
            ck_num((long long)r.text_bytes, 11, "B12 text_bytes 为清洗后的字节数");
            ck_eq(parse_body(r)["text"].s(), "a\xEF\xBF\xBD\xEF\xBF\xBD\xEF\xBF\xBD" "b",
                  "B12b 三个连续非法字节各替换一次");
        }
    }

    // ================================================================ C. version / os 截断
    std::printf("\n-- C. version/os：按**字符**截断（绝不切半个字）--\n");
    {
        // C1 81 个 ASCII → 80
        {
            auto in = base_input();
            in.version = std::string(81, 'v');
            const auto r = rta::feedback::build_feedback_upload(in);
            ck(r.ok, "C1 超长 version 不报错（只截断）", r.code);
            ck_num((long long)parse_body(r)["version"].s().size(), 80, "C1b version 截到 80 字符");
        }
        // C2 80 个汉字（240 字节）**不**被截断 —— 证明按字符不按字节
        {
            std::string zh80;
            for (int i = 0; i < 80; ++i) zh80 += "汉";
            auto in = base_input();
            in.version = zh80;
            const auto r = rta::feedback::build_feedback_upload(in);
            ck_eq(parse_body(r)["version"].s(), zh80, "C2 80 个汉字（240 字节）不被截断");
        }
        // C3 100 个汉字 → 80 个汉字（240 字节），且没切半个字
        {
            std::string zh100;
            for (int i = 0; i < 100; ++i) zh100 += "汉";
            auto in = base_input();
            in.version = zh100;
            const auto r = rta::feedback::build_feedback_upload(in);
            const std::string got = parse_body(r)["version"].s();
            ck_num((long long)got.size(), 240, "C3 100 汉字截到 80 字符 = 240 字节");
            int han = 0;
            for (size_t i = 0; i + 2 < got.size() + 1; i += 3) {
                if (got.compare(i, 3, "汉") == 0) ++han;
            }
            ck_num(han, 80, "C3b 恰好 80 个完整汉字（没有半截字节）");
        }
        // C4 81 个 emoji（4 字节）→ 80 个，仍是合法 UTF-8
        {
            std::string emo;
            for (int i = 0; i < 81; ++i) emo += "\xF0\x9F\x8E\xB5";   // U+1F3B5
            auto in = base_input();
            in.version = emo;
            const auto r = rta::feedback::build_feedback_upload(in);
            const std::string got = parse_body(r)["version"].s();
            ck_num((long long)got.size(), 320, "C4 81 个 emoji 截到 80 个 = 320 字节");
            ck_eq(got.substr(0, 4), std::string("\xF0\x9F\x8E\xB5"), "C4b 首字符仍是完整 emoji");
            // 逐 4 字节校验（半截会产生非法 UTF-8，被 json_parse 原样带回后长度会变 3）
            bool aligned = (got.size() % 4 == 0);
            for (size_t i = 0; aligned && i < got.size(); i += 4) {
                if (got.compare(i, 4, "\xF0\x9F\x8E\xB5") != 0) aligned = false;
            }
            ck(aligned, "C4c 没有任何半个 emoji（4 字节对齐）", got);
        }
        // C5 os 121 字符 → 120
        {
            std::string os121(121, 'o');
            auto in = base_input();
            in.os = os121;
            const auto r = rta::feedback::build_feedback_upload(in);
            ck_num((long long)parse_body(r)["os"].s().size(), 120, "C5 os 截到 120 字符");
        }
        // C6 空 version → bad_version；空 os → bad_os
        {
            auto in = base_input();
            in.version.clear();
            const auto r = rta::feedback::build_feedback_upload(in);
            ck_eq(r.code, "bad_version", "C6 空 version → bad_version");
            ck(!r.error.empty(), "C6b bad_version 有中文 error", r.error);
        }
        {
            auto in = base_input();
            in.os.clear();
            const auto r = rta::feedback::build_feedback_upload(in);
            ck_eq(r.code, "bad_os", "C7 空 os → bad_os");
        }
    }

    // ================================================================ D. client / key
    std::printf("\n-- D. client（安装 ID）与幂等键 --\n");
    {
        auto in = base_input();
        in.client = "not-an-install-id";
        ck_eq(rta::feedback::build_feedback_upload(in).code, "bad_client", "D1 非法 client → bad_client");

        in = base_input();
        in.client = "rlmac-0123456789ABCDEFFEDCBA9876543210";
        ck_eq(rta::feedback::build_feedback_upload(in).code, "bad_client", "D2 大写 hex 的 client → bad_client");

        in = base_input();
        in.client = std::string(200, 'a');
        ck_eq(rta::feedback::build_feedback_upload(in).code, "bad_client", "D3 超 160 字符的 client → bad_client");

        in = base_input();
        in.idempotency_key = "abc";
        ck_eq(rta::feedback::build_feedback_upload(in).code, "bad_key", "D4 过短 key → bad_key");

        in = base_input();
        in.idempotency_key = "fb 20261111 ABCDEF12";
        ck_eq(rta::feedback::build_feedback_upload(in).code, "bad_key", "D5 含空格 key → bad_key");

        in = base_input();
        in.idempotency_key = std::string(161, 'k');
        ck_eq(rta::feedback::build_feedback_upload(in).code, "bad_key", "D6 161 字符 key → bad_key");
    }

    // ================================================================ E. 诊断包
    std::printf("\n-- E. 诊断包（diag_json → base64）--\n");
    {
        // E1 attach_diag=true 但没内容
        {
            auto in = base_input();
            in.attach_diag = true;
            const auto r = rta::feedback::build_feedback_upload(in);
            ck_eq(r.code, "diag_empty", "E1 勾选诊断包但内容为空 → diag_empty");
        }
        // E2 attach_diag=true 且只有空白 → 同样 diag_empty
        {
            auto in = base_input();
            in.attach_diag = true;
            in.diag_json = "   \n\t ";
            ck_eq(rta::feedback::build_feedback_upload(in).code, "diag_empty",
                  "E2 诊断包只有空白 → diag_empty");
        }
        // E3 未勾选 → diag == ""、diag_bytes == 0
        {
            auto in = base_input();
            const auto r = rta::feedback::build_feedback_upload(in);
            ck(r.ok, "E3 不带诊断包可以提交", r.code);
            ck_eq(parse_body(r)["diag"].s(), "", "E3b 未附诊断时 diag == \"\"");
            ck_num((long long)r.diag_bytes, 0, "E3c 未附诊断时 diag_bytes == 0");
        }
        // E4 前导空白后是 '{' → 合法；base64 解回来逐字节相等
        {
            const std::string diag = "  \n {\"os\":\"macOS 27.1\",\"n\":[1,2,3]}";
            auto in = base_input();
            in.attach_diag = true;
            in.diag_json = diag;
            const auto r = rta::feedback::build_feedback_upload(in);
            ck(r.ok, "E4 前导空白后以 '{' 开头 → 合法", r.code);
            std::string dec;
            const bool dec_ok = b64decode(parse_body(r)["diag"].s(), dec);
            ck(dec_ok, "E4b diag 字段是合法 base64（测试自带解码器解得开）");
            ck(dec == diag, "E4c 解码后**逐字节**等于输入 diag_json", "长度 " + std::to_string(dec.size()));
            ck_num((long long)r.diag_bytes, (long long)diag.size(), "E4d diag_bytes 按解码后字节数算");
        }
        // E5 顶层是数组也合法
        {
            auto in = base_input();
            in.attach_diag = true;
            in.diag_json = "[{\"a\":1}]";
            const auto r = rta::feedback::build_feedback_upload(in);
            ck(r.ok, "E5 顶层 '[' 也视为 JSON", r.code);
        }
        // E6 不是 JSON → diag_not_json
        {
            auto in = base_input();
            in.attach_diag = true;
            in.diag_json = "not json at all";
            const auto r = rta::feedback::build_feedback_upload(in);
            ck_eq(r.code, "diag_not_json", "E6 非 JSON → diag_not_json");
            ck(r.json.empty(), "E6b 失败时不出请求体", r.json);
        }
        // E7 未勾选但塞了合法 diag_json → 仍然不附带（避免"用户取消了却被偷偷上传"）
        {
            auto in = base_input();
            in.attach_diag = false;
            in.diag_json = "{\"a\":1}";
            const auto r = rta::feedback::build_feedback_upload(in);
            ck(r.ok, "E7 未勾选 + 有 diag_json → 通过", r.code);
            ck_eq(parse_body(r)["diag"].s(), "", "E7b 未勾选时 diag 必须为空（不许偷偷附带）");
        }
        // E8 8 MiB 恰好允许（双向边界之一）
        {
            std::string big = "[";
            big.append((size_t)rta::feedback::kFeedbackMaxDiagBytes - 2, ' ');
            big += "]";
            ck_num((long long)big.size(), 8388608, "E8 夹具确实是 8 MiB");
            auto in = base_input();
            in.attach_diag = true;
            in.diag_json = big;
            const auto r = rta::feedback::build_feedback_upload(in);
            ck(r.ok, "E8b 恰好 8 MiB 允许", r.code);
            ck_num((long long)r.diag_bytes, 8388608, "E8c diag_bytes == 8388608");
            std::string dec;
            ck(b64decode(parse_body(r)["diag"].s(), dec) && dec.size() == 8388608,
               "E8d 8 MiB 往返解回来仍是 8388608 字节");
        }
        // E10 体积判据必须看**原串**（服务端解码 base64 后看到的就是原串，含空白）。
        // 这条是补漏：实现若用 trim 后的长度判上限，就会放过 8 MiB + 1 个尾部空白的包，
        // 客户端以为能过、后台 413 —— 那是最难查的一类不一致。
        {
            std::string big = "[";
            // "[" + N 个空格 + "]" 必须凑成 8 MiB，再多 1 个尾部空白 = 8 MiB + 1
            big.append((size_t)rta::feedback::kFeedbackMaxDiagBytes - 2, ' ');
            big += "]";
            big += " ";                     // 恰好 8 MiB + 1 字节
            ck_num((long long)big.size(), 8388609, "E10 夹具确实是 8 MiB+1（尾部空白）");
            auto in = base_input();
            in.attach_diag = true;
            in.diag_json = big;
            const auto r = rta::feedback::build_feedback_upload(in);
            ck_eq(r.code, "diag_too_large", "E10b 8 MiB+1（仅尾部多一个空白）→ diag_too_large");
        }

        // E9 8 MiB + 1 → diag_too_large（先判体积，不是先挑格式）
        {
            auto in = base_input();
            in.attach_diag = true;
            in.diag_json = std::string((size_t)rta::feedback::kFeedbackMaxDiagBytes + 1, 'x');
            const auto r = rta::feedback::build_feedback_upload(in);
            ck_eq(r.code, "diag_too_large",
                  "E9 8 MiB+1 且不是 JSON → 先报 diag_too_large（体积优先）");
        }
    }

    // ================================================================ F. 请求体 JSON
    std::printf("\n-- F. 请求体：合法 JSON + 字段齐全 + 转义正确 --\n");
    {
        // 覆盖全部必须转义的字符
        std::string tricky = "引号\" 反斜杠\\ 换行\n 回车\r 制表\t 退格\b 换页\f 控制\x01\x1F 中文 🎵 结尾";
        auto in = base_input();
        in.text = tricky;
        const auto r = rta::feedback::build_feedback_upload(in);
        ck(r.ok, "F1 含全部转义字符的 text 能通过", r.code);

        const auto j = parse_body(r);
        ck(j.type == rta::net::Json::Obj, "F2 请求体能被 json_parse 解析且是对象");
        ck_eq(j["text"].s(), tricky, "F3 text 往返**完全一致**（双引号/反斜杠/控制字符/中文/emoji）");

        const char* kFields[] = {"text", "version", "os", "client", "diag", "idempotency_key"};
        bool all_there = true;
        for (const char* f : kFields) {
            if (!j.has(f) || j[f].type != rta::net::Json::Str) all_there = false;
        }
        ck(all_there, "F4 六个字段齐全且都是字符串（text/version/os/client/diag/idempotency_key）");
        ck_num((long long)j.obj.size(), 6, "F4b 没有多余字段（后台会拒未知字段就麻烦）");

        ck_eq(j["version"].s(), in.version, "F5 version 往返一致");
        ck_eq(j["os"].s(), in.os, "F6 os 往返一致");
        ck_eq(j["client"].s(), in.client, "F7 client 往返一致");
        ck_eq(j["idempotency_key"].s(), in.idempotency_key, "F8 idempotency_key 往返一致");

        // 转义形态也要钉住：只判"往返一致"会放过"用原始控制字节进 JSON"这种非法写法
        ck_not_has(r.json, std::string(1, '\x01'), "F9 请求体里没有裸 0x01 控制字节");
        ck_not_has(r.json, std::string(1, '\x1F'), "F10 请求体里没有裸 0x1F 控制字节");
        ck_has(r.json, "\\u0001", "F11 0x01 被写成 \\u0001");
        ck_has(r.json, "\\u001F", "F12 0x1F 被写成大写十六进制 \\u001F");
        ck_has(r.json, "\\\"", "F13 双引号被转义");
        ck_has(r.json, "\\\\", "F14 反斜杠被转义");
        ck_has(r.json, "\\n", "F15 换行被转义为 \\n");
        ck_has(r.json, "\\r", "F16 回车被转义为 \\r");
        ck_has(r.json, "\\t", "F17 制表被转义为 \\t");
        ck_has(r.json, "\\b", "F18 退格被转义为 \\b");
        ck_has(r.json, "\\f", "F19 换页被转义为 \\f");
        // 中文与 emoji 必须原样（不能被 \\uXXXX 化，后台按 UTF-8 计字节）
        ck_has(r.json, "中文 🎵", "F20 中文与 emoji 原样 UTF-8（不转 \\u）");
        ck_not_has(r.json, "\\u4e2d", "F21 中文没有被转成 \\u4e2d 形态");
    }

    // ================================================================ G. base64
    std::printf("\n-- G. base64（RFC4648 标准表 + '=' 填充，无换行）--\n");
    {
        ck_eq(rta::feedback::feedback_base64(""), "", "G1 空串 → 空串");
        ck_eq(rta::feedback::feedback_base64("f"), "Zg==", "G2 \"f\" → Zg==");
        ck_eq(rta::feedback::feedback_base64("fo"), "Zm8=", "G3 \"fo\" → Zm8=");
        ck_eq(rta::feedback::feedback_base64("foo"), "Zm9v", "G4 \"foo\" → Zm9v（3 的倍数无填充）");
        ck_eq(rta::feedback::feedback_base64("foob"), "Zm9vYg==", "G5 \"foob\" → Zm9vYg==");
        ck_eq(rta::feedback::feedback_base64("fooba"), "Zm9vYmE=", "G6 \"fooba\" → Zm9vYmE=");
        ck_eq(rta::feedback::feedback_base64("foobar"), "Zm9vYmFy", "G7 \"foobar\" → Zm9vYmFy");

        // 二进制全 256 字节：验证标准字母表（+/）与逐字节无损
        std::string all;
        for (int i = 0; i < 256; ++i) all += (char)i;
        const std::string enc = rta::feedback::feedback_base64(all);
        std::string dec;
        ck(b64decode(enc, dec) && dec == all, "G8 0x00..0xFF 往返无损（含 + / 两个非字母数字字符）");
        ck(enc.find('+') != std::string::npos || enc.find('/') != std::string::npos,
           "G9 用到标准字母表的 + / （不是 URL 安全变体）");
        ck_not_has(enc, "\n", "G10 无换行");
        ck_not_has(enc, "\r", "G11 无回车");
        ck_num((long long)enc.size() % 4, 0, "G12 长度总是 4 的倍数");
        ck_num((long long)rta::feedback::feedback_base64("ab").size(), 4, "G13 余 2 字节 → 4 字符含 '='");
    }

    // ================================================================ H. 解析上传响应
    std::printf("\n-- H. 解析上传响应（HTTP 状态不能当成功）--\n");
    {
        // H1 201 完整成功
        {
            const auto r = rta::feedback::parse_feedback_upload_reply(
                201,
                "{\"ok\":true,\"id\":\"FB-20261111-ABCDEFGHIJ\",\"diagStored\":true}");
            ck(r.parsed, "H1 201 合法 JSON → parsed");
            ck(r.ok, "H1b 201 + ok:true → ok");
            ck_eq(r.id, "FB-20261111-ABCDEFGHIJ", "H1c 取出 id");
            ck(r.diag_stored, "H1d 取出 diagStored=true");
            ck_num(r.status, 201, "H1e status 原样保留");
        }
        // H2 200 幂等重放
        {
            const auto r = rta::feedback::parse_feedback_upload_reply(
                200, "{\"ok\":true,\"id\":\"FB-20261111-ABCDEFGHIJ\"}");
            ck(r.parsed && r.ok, "H2 200 + ok:true（幂等重放）→ ok");
            ck_eq(r.id, "FB-20261111-ABCDEFGHIJ", "H2b 同一个工单 id");
        }
        // H3 200 + ok:false **必须判失败**
        {
            const auto r = rta::feedback::parse_feedback_upload_reply(
                200, "{\"ok\":false,\"code\":\"bad_request\",\"error\":\"text empty\"}");
            ck(r.parsed, "H3 200 带 JSON → parsed");
            ck(!r.ok, "H3b 200 + ok:false 必须判失败（HTTP 状态不能当成功）");
            ck_eq(r.code, "bad_request", "H3c 取出 code");
            ck_eq(r.error, "text empty", "H3d 取出 error");
            ck(r.id.empty(), "H3e 失败时 id 为空", r.id);
        }
        // H4..H9 各错误码
        struct Case {
            int status;
            const char* code;
        };
        const Case cases[] = {{400, "bad_request"},   {403, "forbidden"},      {404, "not_found"},
                              {413, "request_too_large"}, {422, "unsupported_diagnostic"},
                              {429, "rate_limited"}};
        for (const auto& c : cases) {
            const std::string body = std::string("{\"ok\":false,\"code\":\"") + c.code +
                                     "\",\"error\":\"服务端说明\"}";
            const auto r = rta::feedback::parse_feedback_upload_reply(c.status, body);
            const std::string what = std::string("H4 ") + std::to_string(c.status) + " → parsed 且 !ok 且 code 正确";
            ck(r.parsed && !r.ok && r.code == c.code, what.c_str(), "code=" + r.code);
        }
        // H10 nginx 的 HTML 501：不是 JSON，不许算 parsed
        {
            const std::string html =
                "<html><head><title>501 Not Implemented</title></head><body>501</body></html>";
            const auto r = rta::feedback::parse_feedback_upload_reply(501, html);
            ck(!r.parsed, "H10 HTML 错误页 → parsed=false（json_parse 返回 Num 不算对象）");
            ck(!r.ok, "H10b HTML 错误页 → ok=false");
            ck_eq(r.error, "", "H10c 不臆造 error（让上层走 describe_feedback_failure）");
        }
        // H11 201 缺 id
        {
            const auto r = rta::feedback::parse_feedback_upload_reply(201, "{\"ok\":true}");
            ck(r.parsed && r.ok, "H11 201 缺 id 仍算成功");
            ck(r.id.empty(), "H11b id 为空（调用方显示「无工单号」），不崩", r.id);
        }
        // H12 空 body
        {
            const auto r = rta::feedback::parse_feedback_upload_reply(200, "");
            ck(!r.parsed && !r.ok, "H12 空 body → parsed=false / ok=false");
        }
        // H13 201 缺 diagStored → false（不能默认 true）
        {
            const auto r = rta::feedback::parse_feedback_upload_reply(201, "{\"ok\":true,\"id\":\"X\"}");
            ck(!r.diag_stored, "H13 缺 diagStored 时默认 false（不许乐观默认 true）");
        }
        // H14 ok 是字符串 "true" 不算成功
        {
            const auto r = rta::feedback::parse_feedback_upload_reply(201, "{\"ok\":\"true\"}");
            ck(!r.ok, "H14 ok 为字符串 \"true\" 不算成功（类型必须严格）", r.code);
        }
        // H15 纯数字 body（"501"）也不算 JSON 响应
        {
            const auto r = rta::feedback::parse_feedback_upload_reply(501, "501");
            ck(!r.parsed, "H15 body 是裸数字 → parsed=false");
        }
    }

    // ================================================================ I. watchdog
    std::printf("\n-- I. 解析 watchdog（limits 的实际值）--\n");
    {
        const auto w = rta::feedback::parse_feedback_watchdog(200, kWatchdogBody);
        ck(w.reachable, "I1 真实样例 → reachable", w.error);
        ck_num(w.status, 200, "I1b status=200");
        ck_num((long long)w.text_bytes, 16384, "I2 textBytes=16384");
        ck_num((long long)w.diag_bytes, 8388608, "I3 diagBytes=8388608");
        ck_num(w.rate_per_minute, 5, "I4 ratePerMinute=5");
        ck_num(w.retention_days, 90, "I5 retentionDays=90");
        ck_num(w.delete_window_days, 7, "I6 deleteWindowDays=7");
        ck(w.error.empty(), "I7 可达时不带 error", w.error);

        // I8 200 + ok:false
        const auto w2 = rta::feedback::parse_feedback_watchdog(
            200, "{\"ok\":false,\"code\":\"forbidden\",\"error\":\"维护中\"}");
        ck(!w2.reachable, "I8 200 + ok:false → reachable=false");
        ck(!w2.error.empty(), "I8b error 非空", w2.error);
        ck_has(w2.error, "维护中", "I8c error 带服务端说明");

        // I9 非 JSON
        const auto w3 = rta::feedback::parse_feedback_watchdog(200, "<html>oops</html>");
        ck(!w3.reachable, "I9 非 JSON → reachable=false");
        ck(!w3.error.empty(), "I9b error 非空", w3.error);

        // I10 500 + 非 JSON
        const auto w4 = rta::feedback::parse_feedback_watchdog(500, "Internal Server Error");
        ck(!w4.reachable, "I10 500 非 JSON → reachable=false");
        ck_has(w4.error, "500", "I10b error 里带 HTTP 码，便于排查");

        // I11 响应里没 limits → 保留默认（不能变成 0，否则客户端会以为"上限是 0 字节"）
        const auto w5 = rta::feedback::parse_feedback_watchdog(200, "{\"ok\":true,\"service\":\"x\"}");
        ck(w5.reachable, "I11 只有 ok:true 也算可达");
        ck_num((long long)w5.text_bytes, 16384, "I11b 缺 limits 时 text_bytes 保留默认 16384");
        ck_num(w5.rate_per_minute, 5, "I11c 缺 limits 时 rate_per_minute 保留默认 5");
        ck_num(w5.retention_days, 90, "I11d 缺 retentionDays 时保留默认 90");

        // I12 服务端下调 limits 时**必须采用服务端值**（写死默认就失去意义了）
        const auto w6 = rta::feedback::parse_feedback_watchdog(
            200, "{\"ok\":true,\"limits\":{\"textBytes\":2048,\"diagBytes\":1024,\"ratePerMinute\":1}}");
        ck_num((long long)w6.text_bytes, 2048, "I12 采用服务端的 textBytes=2048");
        ck_num((long long)w6.diag_bytes, 1024, "I12b 采用服务端的 diagBytes=1024");
        ck_num(w6.rate_per_minute, 1, "I12c 采用服务端的 ratePerMinute=1");
    }

    // ================================================================ J. 错误分类
    std::printf("\n-- J. describe_feedback_failure（用户能直接看到的中文）--\n");
    {
        using rta::feedback::describe_feedback_failure;
        // J1 400
        {
            const auto f = describe_feedback_failure(400, "bad_request", "", false, "");
            ck(!f.retryable, "J1 400 不可重试");
            ck_has(f.message, "不合法", "J1b 400 提示「字段/请求不合法」");
            ck_eq(f.code, "bad_request", "J1c code 透传服务端");
        }
        // J2 403
        {
            const auto f = describe_feedback_failure(403, "", "", false, "");
            ck(!f.retryable, "J2 403 不可重试");
            ck_has(f.message, "权限", "J2b 403 提示无权限");
            ck_has(f.message, "安装 ID", "J2c 403 提示安装 ID 可能不匹配");
        }
        // J3 404
        {
            const auto f = describe_feedback_failure(404, "", "", false, "");
            ck(!f.retryable, "J3 404 不可重试");
            ck_has(f.message, "接口不存在", "J3b 404 提示接口不存在");
        }
        // J4 413
        {
            const auto f = describe_feedback_failure(413, "request_too_large", "", false, "");
            ck(!f.retryable, "J4 413 不可重试");
            ck_has(f.message, "超过", "J4b 413 提示超限");
            ck_has(f.message, "取消勾选", "J4c 413 建议取消勾选附带诊断包");
        }
        // J5 422
        {
            const auto f = describe_feedback_failure(422, "", "", false, "");
            ck(!f.retryable, "J5 422 不可重试");
            ck_has(f.message, "诊断包", "J5b 422 提到诊断包");
            ck_has(f.message, "JSON", "J5c 422 说明诊断包必须是 JSON");
        }
        // J6 429
        {
            const auto f = describe_feedback_failure(429, "rate_limited", "", false, "");
            ck(f.retryable, "J6 429 可重试（等一会儿就好）");
            ck_has(f.message, "稍后再试", "J6b 429 提示稍后再试");
            ck_eq(f.code, "rate_limited", "J6c code 透传");
        }
        // J7 5xx 各值
        for (int st : {500, 502, 503}) {
            const auto f = describe_feedback_failure(st, "", "", false, "");
            ck(f.retryable, ("J7 " + std::to_string(st) + " 可重试").c_str());
            ck_has(f.message, std::to_string(st), "J7b message 带 HTTP 码");
        }
        // J8 超时
        {
            const auto f = describe_feedback_failure(0, "", "", true, "");
            ck(f.retryable, "J8 超时可重试");
            ck_has(f.message, "超时", "J8b 提示「超时」");
        }
        // J9 传输层错误（非超时）
        {
            const auto f = describe_feedback_failure(0, "", "", false, "Connection reset by peer");
            ck(f.retryable, "J9 传输层错误可重试");
            ck_has(f.message, "Connection reset by peer", "J9b message 包含 transport_error 原文");
        }
        // J10 其它 4xx（401）
        {
            const auto f = describe_feedback_failure(401, "", "", false, "");
            ck(!f.retryable, "J10 其它 4xx（401）不可重试");
            ck_has(f.message, "401", "J10b message 带 HTTP 码");
        }
        // J11 服务端 error 摘要被并入（便于排查），但不含 URL/token
        {
            const auto f = describe_feedback_failure(
                400, "", "text too long; docs at https://rlplayer.rainlain.com/wiki/feedback", false, "");
            ck_has(f.message, "text too long", "J11 服务端 error 摘要并入 message");
            ck_not_has(f.message, "https://", "J11b message 里没有 URL");
            ck_not_has(f.message, "rainlain", "J11c message 里没有后台域名");
        }
        // J12 token 明文也必须抹掉
        {
            const auto f = describe_feedback_failure(
                400, "", "bad request token=abcdef12345 secret=\"s3cr3tvalue\"", false, "");
            ck_not_has(f.message, "abcdef12345", "J12 message 里没有 token 明文");
            ck_not_has(f.message, "s3cr3tvalue", "J12b message 里没有 secret 明文");
            ck_has(f.message, "bad request", "J12c 非敏感部分仍保留");
        }
        // J13 transport_error 里带后台域名时也要抹
        {
            const auto f = describe_feedback_failure(
                0, "", "", false, "SSL connect error to rlplayer.rainlain.com");
            ck_not_has(f.message, "rainlain", "J13 transport_error 里的后台域名被抹");
        }
        // J14 所有分支：message 非空、无 scheme、code 非空、不含控制字符
        {
            const int statuses[] = {0, 400, 401, 403, 404, 413, 418, 422, 429, 500, 502, 503, 599};
            bool all_ok = true;
            std::string bad;
            for (int st : statuses) {
                const auto f = describe_feedback_failure(st, "", "", st == 0, "");
                if (f.message.empty() || f.code.empty()) { all_ok = false; bad += " empty@"; bad += std::to_string(st); }
                if (f.message.find("://") != std::string::npos) { all_ok = false; bad += " url@"; bad += std::to_string(st); }
                for (char c : f.message) {
                    if ((unsigned char)c < 0x20) { all_ok = false; bad += " ctl@"; bad += std::to_string(st); break; }
                }
                // 可重试性：429/5xx/status 0 才可重试
                const bool want_retry = (st == 0 || st == 429 || (st >= 500 && st <= 599));
                if (f.retryable != want_retry) { all_ok = false; bad += " retry@"; bad += std::to_string(st); }
            }
            ck(all_ok, "J14 全状态矩阵：message/code 非空、无 URL、无控制字符、可重试性正确", bad);
        }
        // J16 服务端 error 摘要里若带 Authorization / Bearer，同样必须抹掉。
        // 这条是补漏：最初只处理了 "token=..." 形态，而 header 形态（冒号 + Bearer）
        // 会被原样并入 message，等于把凭据写进用户可见文案与日志。
        {
            const auto f = describe_feedback_failure(
                400, "", "rejected: Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig", false, "");
            ck_not_has(f.message, "eyJhbGciOiJIUzI1NiJ9", "J16 Bearer token 明文被抹");
            ck_not_has(f.message, "Bearer eyJ", "J16b Bearer 后紧跟的 token 不残留");
            ck_has(f.message, "rejected", "J16c 非敏感部分保留");
        }
        // J17 查询串形态：抹掉 password，但**后面的参数要留下**（否则诊断信息被过度吞掉）
        {
            const auto f = describe_feedback_failure(400, "", "password=hunter2&user=me&x=1", false, "");
            ck_not_has(f.message, "hunter2", "J17 password 值被抹");
            ck_has(f.message, "user=me", "J17b '&' 之后的参数保留（不被整段吞掉）");
        }

        // J15 过长的服务端 error 会被截断（不能把 8KB 的 body 塞进 UI）
        {
            const auto f = describe_feedback_failure(400, "", std::string(4000, 'z'), false, "");
            ck(f.message.size() < 600, "J15 超长的服务端 error 被截断，不会撑爆 UI",
               "长度 " + std::to_string(f.message.size()));
        }
    }

    // ================================================================ K. 幂等键
    std::printf("\n-- K. 幂等键：fb-YYYYMMDD-XXXXXXXX（UTC + 大写 hex）--\n");
    {
        using rta::feedback::make_feedback_idempotency_key;
        ck_eq(make_feedback_idempotency_key(1794355200LL, 0xDEADBEEF), "fb-20261111-DEADBEEF",
              "K1 2026-11-11 00:00:00Z → fb-20261111-DEADBEEF");
        ck_eq(make_feedback_idempotency_key(1794441599LL, 0x00000000), "fb-20261111-00000000",
              "K2 当日 23:59:59Z 仍是同一天，且补足 8 位 0");
        ck_eq(make_feedback_idempotency_key(1794441600LL, 0x00000001), "fb-20261112-00000001",
              "K3 次日 00:00:00Z → 20261112（UTC 边界）");
        ck_eq(make_feedback_idempotency_key(0, 0xFFFFFFFF), "fb-19700101-FFFFFFFF",
              "K4 epoch 0 → 19700101");
        ck_eq(make_feedback_idempotency_key(1709208000LL, 0x0000000A), "fb-20240229-0000000A",
              "K5 闰日 2024-02-29");
        ck_eq(make_feedback_idempotency_key(1904256000LL, 0x0000000B), "fb-20300506-0000000B",
              "K6 2030-05-06");
        ck_eq(make_feedback_idempotency_key(-86400, 0x0000000C), "fb-19700101-0000000C",
              "K7 负时间戳夹到 19700101（文档化：时钟倒退不产生非法日期）");
        ck_eq(make_feedback_idempotency_key(946684800LL, 0x0000000D), "fb-20000101-0000000D",
              "K8 2000-01-01");

        // K9 确定性
        const std::string a = make_feedback_idempotency_key(1794355200LL, 42);
        const std::string b = make_feedback_idempotency_key(1794355200LL, 42);
        ck_eq(a, b, "K9 同参数两次调用逐字相同");

        // K10 不同 random → 不同键（8 位 hex 全部参与）
        std::vector<std::string> keys;
        int dup = 0;
        for (unsigned int i = 0; i < 256; ++i) {
            const std::string k = make_feedback_idempotency_key(1794355200LL, i * 16777259u);
            for (const auto& s : keys)
                if (s == k) ++dup;
            keys.push_back(k);
        }
        ck(dup == 0, "K10 256 个不同 random32 → 256 个不同键（没丢位）",
           "重复 " + std::to_string(dup));

        // K11 形态：^fb-[0-9]{8}-[0-9A-F]{8}$（逐字符检查，不用正则也不含糊）
        {
            const std::string k = make_feedback_idempotency_key(1794355200LL, 0xABCDEF01);
            // "fb-" (3) + 8 位日期 + '-' (1) + 8 位 hex = **20** 字符。
            // （一版判据写成 19 是数错了，不是实现错：K1..K8 的全等断言早就把 20 字符钉死了。）
            bool shape = k.size() == 20 && k.compare(0, 3, "fb-") == 0 && k[11] == '-';
            for (size_t i = 3; shape && i < 11; ++i) shape = (k[i] >= '0' && k[i] <= '9');
            for (size_t i = 12; shape && i < k.size(); ++i)
                shape = (k[i] >= '0' && k[i] <= '9') || (k[i] >= 'A' && k[i] <= 'F');
            ck(shape, "K11 形态 ^fb-[0-9]{8}-[0-9A-F]{8}$", k);
        }
        // K13 极端时钟（year > 9999）不许破坏格式：仍必须匹配 ^fb-[0-9]{8}-[0-9A-F]{8}$。
        // 不夹住的话 append_u32_padded 会把年份写成 5 位，客户端会发出后台必拒的键。
        {
            const long long absurd[] = {253402300800LL, 300000000000LL, 9223372036854775807LL};
            bool all_shape = true;
            std::string bad;
            for (long long ep : absurd) {
                const std::string k = make_feedback_idempotency_key(ep, 0x12345678);
                bool shape = k.size() == 20 && k.compare(0, 3, "fb-") == 0 && k[11] == '-';
                for (size_t i = 3; shape && i < 11; ++i) shape = (k[i] >= '0' && k[i] <= '9');
                for (size_t i = 12; shape && i < 20; ++i)
                    shape = (k[i] >= '0' && k[i] <= '9') || (k[i] >= 'A' && k[i] <= 'F');
                if (!shape) { all_shape = false; bad += " " + std::to_string(ep) + "->" + k; }
                if (!rta::feedback::feedback_idempotency_key_valid(k)) {
                    all_shape = false;
                    bad += " invalid:" + k;
                }
            }
            ck(all_shape, "K13 荒谬时钟仍产出的合法形态（年份夹到 9999）", bad);
        }

        // K12 生成的键必须能过 valid()
        ck(rta::feedback::feedback_idempotency_key_valid(make_feedback_idempotency_key(1794355200LL, 7)),
           "K12 生成的键通过 feedback_idempotency_key_valid");
    }

    // ================================================================ L. 幂等键校验边界
    std::printf("\n-- L. feedback_idempotency_key_valid 边界 --\n");
    {
        using rta::feedback::feedback_idempotency_key_valid;
        ck(feedback_idempotency_key_valid("fb-20261111-ABCDEF12"), "L1 规范键 true");
        ck(feedback_idempotency_key_valid("abcdefgh"), "L2 恰好 8 字符 true（下界含）");
        ck(!feedback_idempotency_key_valid("abcdefg"), "L2b 7 字符 false（下界外）");
        ck(feedback_idempotency_key_valid(std::string(160, 'k')), "L3 恰好 160 字符 true（上界含）");
        ck(!feedback_idempotency_key_valid(std::string(161, 'k')), "L3b 161 字符 false（上界外）");
        ck(!feedback_idempotency_key_valid(""), "L4 空串 false");
        ck(!feedback_idempotency_key_valid("fb 20261111 ABCDEF12"), "L5 含空格 false");
        ck(!feedback_idempotency_key_valid("fb-20261111-ABCDEF1\n"), "L6 含换行 false");
        ck(!feedback_idempotency_key_valid("中文键中文键"), "L7 非 ASCII false（字符集限定 ASCII）");
        ck(!feedback_idempotency_key_valid("abc/defg"), "L8 '/' 不在字符集 false");
        ck(!feedback_idempotency_key_valid("abc@defg"), "L9 '@' 不在字符集 false");
        ck(feedback_idempotency_key_valid("A.z_0:-9"), "L10 允许的字符集 [A-Za-z0-9._:-] 全放行");
    }

    std::printf("\n== 结果: %d passed, %d failed ==\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
