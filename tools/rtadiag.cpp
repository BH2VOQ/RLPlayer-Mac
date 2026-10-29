// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// ============================================================================
// rtadiag — 离线诊断工具（ROADMAP 1.1.1 · D5）
// ============================================================================
//
// 用法：
//   rtadiag [选项] <包目录 | 包.zip>
//
//   默认为人类可读报告（= 包内 report.txt 的同一份内容，但**基于当前字节重算**，
//   所以包里的 report.txt 被改过也不影响判定）。
//   --json              机器可读（rtadiag 的 CI/夹具用它）
//   --list              只列条目 + 校验结果（--json --list 给 JSON 版）
//   --out <file>        把报告正文写到文件
//   --expect <id>       断言结论 id（不符 → 退出 1）。夹具/回归用
//   --require-real      拒绝"模拟/夹具"数据当作真实诊断（→ 退出 1）
//   --quiet             不打印提醒
//   -h/--help, -V/--version
//
// 退出码（验收脚本按这个判红绿）：
//   0  唯一明确结论，且包通过完整性校验
//   1  证据不足 / 并列冲突 / --expect 不符 / --require-real 但数据是模拟的
//   2  包无法读取，或完整性校验失败（含 v1 旧包：格式不足以定论）
//   3  用法错误
//
// 为什么"旧包失败、新包绿"是正确判据（而不是工具坏了）：
//   v1 包里没有 manifest.json / events.jsonl / uievents.jsonl，缺的正是回答问题所需的
//   结构化证据。此时**必须**承认无法定论（退出 2），而不是拿日志文本猜一个原因 ——
//   猜出来的结论在公网上就会变成"用户按错误方向折腾几天"。
//
// 本工具**只读**：不写用户的包目录、不改任何日志、不联网、不启动播放、不开设备。
// 唯一会写的路径是显式的 --out。
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "diag/bundle.h"
#include "diag/report.h"
#include "diag/error_codes.h"
#include "version.h"

namespace rta::diag::tool {

inline void usage(FILE* f) {
    std::fprintf(f,
        "rtadiag %s — RLPlayer 离线诊断（bundle schema %s）\n"
        "\n"
        "用法: rtadiag [选项] <包目录 | 包.zip>\n"
        "\n"
        "选项:\n"
        "  --json            以 JSON 输出（机器可读）\n"
        "  --list            列出包内条目与校验结果（与 --json 合用给 JSON 版）\n"
        "  --out <file>      把报告正文写到该文件（唯一会写的路径）\n"
        "  --expect <id>     断言结论 id，例如 decode.flac_truncated；不符则退出 1\n"
        "  --require-real    拒绝把模拟/夹具数据当作真实诊断（退出 1）\n"
        "  --quiet           不打印提醒\n"
        "  -h, --help        本帮助\n"
        "  -V, --version     版本\n"
        "\n"
        "退出码: 0=唯一明确结论  1=证据不足/冲突/断言不符  2=包不可读或校验失败  3=用法错误\n",
        RLPLAYER_VERSION, kBundleSchema);
}

namespace detail_cli {

inline std::string bytes_human(std::size_t n) {
    char buf[32];
    if (n >= 1024u * 1024u) std::snprintf(buf, sizeof buf, "%.1f MB", (double)n / (1024.0 * 1024.0));
    else if (n >= 1024u)    std::snprintf(buf, sizeof buf, "%.1f KB", (double)n / 1024.0);
    else                    std::snprintf(buf, sizeof buf, "%zu B", n);
    return std::string(buf);
}

// --list：条目表。sha256 只显示前 12 位 —— 人眼对账够用，整串在 manifest 里。
inline void print_list_text(const Bundle& b, FILE* out) {
    std::fprintf(out, "包: %s%s\n", b.verify.source.c_str(), b.verify.is_zip ? "（zip）" : "（目录）");
    std::fprintf(out, "校验: %s\n", b.verify.summary().c_str());
    for (const auto& line : b.verify.issue_lines()) std::fprintf(out, "  %s\n", line.c_str());
    std::fprintf(out, "case_id: %s\n", b.meta.case_id.empty() ? "（无）" : b.meta.case_id.c_str());
    if (b.meta.truncated)
        std::fprintf(out, "裁剪: 是（%s，丢弃头部 %lld 字节）\n",
                     b.meta.truncation_policy.empty() ? "?" : b.meta.truncation_policy.c_str(),
                     b.meta.dropped_head_bytes);
    else
        std::fprintf(out, "裁剪: 否\n");
    std::fprintf(out, "\n%-28s %10s %10s %6s  %s\n", "条目", "字节", "原始", "裁剪", "sha256(前12)");
    for (const auto& f : b.files) {
        const ManifestEntry* me = nullptr;
        for (const auto& e : b.meta.entries) if (e.name == f.first) { me = &e; break; }
        std::fprintf(out, "%-28s %10zu %10lld %6s  %s\n",
                     f.first.c_str(), f.second.size(),
                     me ? me->original_bytes : 0LL,
                     (me && me->truncated) ? "yes" : "-",
                     me ? me->sha256.substr(0, 12).c_str() : "-");
    }
    std::fprintf(out, "\n合计 %zu 个文件 / %s\n", b.files.size(), bytes_human(b.total_bytes()).c_str());
}

inline void print_list_json(const Bundle& b, FILE* out) {
    std::string s = "{\"ok\":";
    s += b.verify.ok ? "true" : "false";
    s += ",\"source\":\"" + json_escape(b.verify.source) + "\"";
    s += std::string(",\"is_zip\":") + (b.verify.is_zip ? "true" : "false");
    s += std::string(",\"legacy_v1\":") + (b.verify.legacy ? "true" : "false");
    s += ",\"summary\":\"" + json_escape(b.verify.summary()) + "\"";
    s += ",\"case_id\":\"" + json_escape(b.meta.case_id) + "\"";
    s += ",\"schema\":\"" + json_escape(b.meta.schema) + "\"";
    s += std::string(",\"truncated\":") + (b.meta.truncated ? "true" : "false");
    s += ",\"dropped_head_bytes\":" + std::to_string(b.meta.dropped_head_bytes);
    s += std::string(",\"simulated\":") + (b.meta.cs.simulated ? "true" : "false");
    s += ",\"issues\":[";
    const auto issues = b.verify.issue_lines();
    for (std::size_t i = 0; i < issues.size(); ++i) {
        if (i) s += ",";
        s += "\"" + json_escape(issues[i]) + "\"";
    }
    s += "],\"files\":[";
    for (std::size_t i = 0; i < b.files.size(); ++i) {
        if (i) s += ",";
        const auto& f = b.files[i];
        const ManifestEntry* me = nullptr;
        for (const auto& e : b.meta.entries) if (e.name == f.first) { me = &e; break; }
        s += "{\"name\":\"" + json_escape(f.first) + "\"";
        s += ",\"bytes\":" + std::to_string(f.second.size());
        s += ",\"declared_bytes\":" + std::to_string(me ? me->bytes : 0);
        s += std::string(",\"truncated\":") + ((me && me->truncated) ? "true" : "false");
        s += std::string(",\"declared\":") + (me ? "true" : "false");
        s += ",\"sha256\":\"" + json_escape(me ? me->sha256 : std::string()) + "\"}";
    }
    s += "],\"total_bytes\":" + std::to_string(b.total_bytes()) + "}";
    std::fprintf(out, "%s\n", s.c_str());
}

}  // namespace detail_cli

// 真正的入口。测试直接调它（tests/test_rtadiag.cpp 用 RTADIAG_NO_MAIN 编译本文件），
// 于是"退出码"这条判据也能被离线断言，而不是只有人手跑一遍。
inline int rtadiag_main(int argc, char** argv, FILE* out, FILE* errf) {
    std::string path, outfile, expect;
    bool json = false, list = false, quiet = false, require_real = false;

    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        if (a == "--json") json = true;
        else if (a == "--list") list = true;
        else if (a == "--quiet") quiet = true;
        else if (a == "--require-real") require_real = true;
        else if (a == "-h" || a == "--help") { usage(out); return 0; }
        else if (a == "-V" || a == "--version") {
            std::fprintf(out, "rtadiag %s (bundle schema %s)\n", RLPLAYER_VERSION, kBundleSchema);
            return 0;
        } else if (a == "--out" || a == "--expect") {
            if (i + 1 >= argc) {
                std::fprintf(errf, "选项 %s 需要一个参数\n", a.c_str());
                return 3;
            }
            if (a == "--out") outfile = argv[++i];
            else expect = argv[++i];
        } else if (!a.empty() && a[0] == '-' && a != "-") {
            std::fprintf(errf, "未知选项 %s\n", a.c_str());
            usage(errf);
            return 3;
        } else if (path.empty()) {
            path = a;
        } else {
            std::fprintf(errf, "只接受一个包路径（多余参数：%s）\n", a.c_str());
            return 3;
        }
    }
    if (path.empty()) {
        std::fprintf(errf, "缺少包路径\n\n");
        usage(errf);
        return 3;
    }

    Bundle b;
    load_bundle(path, b);                       // 失败时 issues 里已有原因，不静默
    const Evidence ev = evidence_from_bundle(b);
    const Report rep = analyze(ev, [](const std::string& code, CodeInfo& info) {
        const auto* c=find_code(code); if(!c) return false;
        info.code=c->code;info.stage=stage_name(c->stage);info.name_zh=c->zh;return true;
    });

    if (!quiet && rep.simulated)
        std::fprintf(errf, "提醒: 本包 case.simulated=true（模拟/夹具证据），不能当作真实诊断结论\n");
    if (!quiet && b.verify.legacy)
        std::fprintf(errf, "提醒: 这是 v1 旧诊断包，缺少 v2 的结构化证据 —— 只能报「缺什么」\n");

    // ---- 输出 ----
    if (json && list) {
        detail_cli::print_list_json(b, out);
    } else if (list) {
        detail_cli::print_list_text(b, out);
    } else if (json) {
        std::fprintf(out, "%s\n", rep.to_json().c_str());
    } else {
        std::fprintf(out, "%s", rep.text.c_str());
    }

    if (!outfile.empty()) {
        FILE* f = std::fopen(outfile.c_str(), "wb");
        if (!f) {
            std::fprintf(errf, "无法写入 %s\n", outfile.c_str());
            return 3;
        }
        const std::string& text = rep.text;
        const std::size_t n = std::fwrite(text.data(), 1, text.size(), f);
        std::fclose(f);
        if (n != text.size()) {
            std::fprintf(errf, "写入不完整: %s\n", outfile.c_str());
            return 3;
        }
        if (!quiet) std::fprintf(errf, "报告已写入 %s\n", outfile.c_str());
    }

    // ---- 退出码 ----
    int code = report_exit_code(rep);
    if (code == 0 && require_real && rep.simulated) {
        std::fprintf(errf, "--require-real: 数据显示这是模拟/夹具证据，拒绝作为真实诊断结论\n");
        code = 1;
    }
    if (code == 0 && !expect.empty() && rep.conclusion.id != expect) {
        std::fprintf(errf, "--expect %s：实际结论 %s（不符）\n",
                     expect.c_str(), rep.conclusion.id.c_str());
        code = 1;
    }
    // 失败时给一行"为什么"（人不用翻报告就知道下一步）
    if (code != 0 && !quiet) {
        if (code == 2) std::fprintf(errf, "退出码 2：包不可信（%s）\n", b.verify.summary().c_str());
        else if (code == 1) std::fprintf(errf, "退出码 1：%s\n", rep.conclusion.title.c_str());
    }
    return code;
}

}  // namespace rta::diag::tool

#ifndef RTADIAG_NO_MAIN
int main(int argc, char** argv) {
    return rta::diag::tool::rtadiag_main(argc, argv, stdout, stderr);
}
#endif
