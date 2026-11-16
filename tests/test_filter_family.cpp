// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_filter_family.cpp — U8 滤波器族标注判据（先红后绿）
//
// 判据在证明什么：
//   1) 纪要与名字表里的每个族各取 2–3 个**真实**预设名，族与展示标签都对；
//      名字必须真的出现在 filter_presets() 里（不是手写清单 —— 名字表漂移就红）。
//   2) 展示标签**不含数字**：族名只描述性格，不许变成 dB / 抽头的绩效承诺。
//   3) 未知名 ⟹ Unknown 且标签恰为「未分类」；**负向对照**：不存在、只是长得像的
//      名字（poly-sincx / apodfoo / sinc / x-sinc-M）不许被误判成具体族。
//   4) 预设表里每一个名字都必须能归族 —— 以后加预设忘了配族，这里第一时间红。
//   5) 相位后缀（-lp / -mp / -ip，含 -2s 组合）与族互不干扰。
#include "dsp/filter_family.h"
#include "dsp/filter_families.h"   // 真实名字表（唯一事实源）
#include <cstdio>
#include <string>
#include <vector>

using namespace rta::dsp;

static int fails = 0, passes = 0;
static void ck(bool ok, const std::string& what, const std::string& detail = "") {
    std::printf("  [%s] %s%s%s\n", ok ? "PASS" : "FAIL", what.c_str(),
                detail.empty() ? "" : " — ", detail.c_str());
    if (ok) ++passes; else ++fails;
}

static bool name_in_presets(const std::string& n) {
    for (const auto& p : filter_presets()) if (n == p.name) return true;
    return false;
}

/// 名字里不许出现 ASCII 数字（族标签是性格描述，不是绩效数字）。
static bool has_ascii_digit(const std::string& s) {
    for (char c : s) if (c >= '0' && c <= '9') return true;
    return false;
}

int main() {
    std::printf("=== test_filter_family（族标注 / 不出声）===\n");

    // ---- 1) 每族 2–3 个真实名字：真实存在 / 归族 / 族标签 / 完整展示标签 ----
    struct Row {
        const char*  name;
        FilterFamily fam;
        const char*  famLabel;   // 族名（不含相位）
        const char*  fullLabel;  // 下拉项括号里那一截（名字写了相位就带上）
    };
    const std::vector<Row> rows = {
        // 多相 sinc（Kaiser）——纪要 §1；-lp / -mp / -ip 是纪要写的三个相位后缀
        { "poly-sinc-lp",             FilterFamily::PolySinc,      "多相 sinc",         "多相 sinc 线性相位" },
        { "poly-sinc-short-mp",       FilterFamily::PolySinc,      "多相 sinc",         "多相 sinc 最小相位" },
        { "poly-sinc-long-ip",        FilterFamily::PolySinc,      "多相 sinc",         "多相 sinc 混合相位" },
        // 多相 sinc 高斯（Gaussian）——纪要 §1「gauss 系用 Gaussian」
        { "poly-sinc-gauss-short",    FilterFamily::PolySincGauss, "多相 sinc 高斯",     "多相 sinc 高斯" },
        { "poly-sinc-gauss-hires-mp", FilterFamily::PolySincGauss, "多相 sinc 高斯",     "多相 sinc 高斯 最小相位" },
        // ext2 扩展频响（Blackman-Harris）——名字表第 3 组
        { "poly-sinc-ext2",           FilterFamily::Ext2,          "多相 sinc 扩展频响",  "多相 sinc 扩展频响" },
        { "poly-sinc-ext2-2s",        FilterFamily::Ext2,          "多相 sinc 扩展频响",  "多相 sinc 扩展频响" },
        // 半带——纪要 §4 点名的 hb 族；-2s 两段式不改族也不改相位
        { "poly-sinc-hb",             FilterFamily::HalfBand,      "半带",              "半带" },
        { "poly-sinc-hb-l-2s",        FilterFamily::HalfBand,      "半带",              "半带" },
        // 超长 sinc——名字表第 5 组（sinc-MG 用高斯窗，但仍属 sinc 系列，不并入 gauss 族）
        { "sinc-M",                   FilterFamily::Sinc,          "超长 sinc",          "超长 sinc" },
        { "sinc-MG",                  FilterFamily::Sinc,          "超长 sinc",          "超长 sinc" },
        // 闭式插值（Blackman-Harris）——纪要 §1
        { "closed-form",              FilterFamily::ClosedForm,    "闭式插值",           "闭式插值" },
        { "closed-form-fast",         FilterFamily::ClosedForm,    "闭式插值",           "闭式插值" },
        // 最小振铃——纪要 §4 列名、名字表第 7 组
        { "minringFIR",               FilterFamily::MinRing,       "最小振铃",           "最小振铃" },
        { "minringFIR-mp",            FilterFamily::MinRing,       "最小振铃",           "最小振铃 最小相位" },
        // 切趾——名字表第 8 组（通带高频平滑滚降）
        { "apod-20k",                 FilterFamily::Apodizing,     "切趾",              "切趾" },
        { "apod-wide",                FilterFamily::Apodizing,     "切趾",              "切趾" },
    };
    for (const Row& r : rows) {
        ck(name_in_presets(r.name), std::string("真实预设名: ") + r.name,
           name_in_presets(r.name) ? "" : "filter_presets() 里没有");
        const FilterFamily fam = filter_family(r.name);
        ck(fam == r.fam, std::string("归族正确: ") + r.name + " ⟹ " + filter_family_id(r.fam),
           std::string("实得 ") + filter_family_id(fam));
        ck(std::string(filter_family_label(fam)) == r.famLabel,
           std::string("族标签正确: ") + r.name, std::string("实得 ") + filter_family_label(fam));
        ck(filter_family_full_label(r.name) == std::string(r.fullLabel),
           std::string("展示标签正确: ") + r.name + " ⟹ " + r.fullLabel,
           std::string("实得 ") + filter_family_full_label(r.name));
    }

    // ---- 2) 展示文案纪律：非空、无数字、id 唯一；Unknown 的标签恰为「未分类」 ----
    const std::vector<FilterFamily> all = {
        FilterFamily::PolySinc, FilterFamily::PolySincGauss, FilterFamily::Ext2,
        FilterFamily::HalfBand, FilterFamily::Sinc, FilterFamily::ClosedForm,
        FilterFamily::MinRing, FilterFamily::Apodizing, FilterFamily::Unknown,
    };
    std::vector<std::string> ids;
    for (const FilterFamily f : all) {
        const std::string label = filter_family_label(f);
        const std::string id = filter_family_id(f);
        ck(!label.empty(), std::string("族标签非空: ") + id, "");
        ck(!has_ascii_digit(label), std::string("族标签不含数字: ") + id, label);
        ck(!id.empty(), "族 id 非空", id);
        for (const std::string& prev : ids) ck(prev != id, "族 id 唯一: " + id, "重复 " + id);
        ids.push_back(id);
    }
    ck(std::string(filter_family_label(FilterFamily::Unknown)) == "未分类", "Unknown 的标签是「未分类」", "");
    ck(std::string(filter_family_id(FilterFamily::Unknown)) == "unknown", "Unknown 的 id 是 unknown", "");

    // ---- 3) 负向对照：不存在 / 只是长得像的名字 ⟹ Unknown +「未分类」 ----
    const std::vector<std::string> fake = {
        "", "foo-bar", "dsd-wide", "minring", "sinc", "x-sinc-M",
        "poly-sincx", "apodfoo", "gauss-long", "closed-formx",
    };
    for (const std::string& n : fake) {
        const FilterFamily fam = filter_family(n);
        ck(fam == FilterFamily::Unknown, std::string("未知名 ⟹ Unknown: \"") + n + "\"",
           std::string("误判为 ") + filter_family_id(fam));
        ck(filter_family_label(fam) == std::string("未分类"), "未知名标签是「未分类」: " + n, "");
        ck(filter_family_full_label(n) == std::string("未分类"), "未知名展示标签是「未分类」: " + n,
           filter_family_full_label(n));
    }

    // ---- 4) 预设表全量：每个真实名字都能归族，标签非空且不含数字 ----
    for (const auto& p : filter_presets()) {
        const FilterFamily fam = filter_family(p.name);
        ck(fam != FilterFamily::Unknown, std::string("预设表每个名字都归族: ") + p.name,
           "未分类 ⟹ 族表缺规则");
        const std::string full = filter_family_full_label(p.name);
        ck(!full.empty() && !has_ascii_digit(full),
           std::string("预设展示标签可用: ") + p.name, full);
    }

    // ---- 5) 相位后缀（与族正交；-2s 先摘掉） ----
    struct PRow { const char* name; FilterPhase ph; };
    const std::vector<PRow> prows = {
        { "poly-sinc-lp",            FilterPhase::Linear },
        { "poly-sinc-short-mp",      FilterPhase::Minimum },
        { "poly-sinc-long-ip",       FilterPhase::Intermediate },
        { "poly-sinc-mp-2s",         FilterPhase::Minimum },   // 后缀在 -2s 之前
        { "poly-sinc-short-2s",      FilterPhase::Unspecified }, // 名字没写相位就不代言
        { "poly-sinc-hb-2s",         FilterPhase::Unspecified },
        { "apod-19k-short",          FilterPhase::Unspecified },
        { "poly-sinc-gauss-hires-ip", FilterPhase::Intermediate },
    };
    for (const PRow& r : prows) {
        ck(filter_phase_of_name(r.name) == r.ph, std::string("相位后缀: ") + r.name,
           std::string("实得 ") + filter_phase_label(filter_phase_of_name(r.name)));
    }

    // ---- 6) UI 上真正出现的那一行（族 + 相位）与说明文案 ----
    ck(filter_family_full_label("poly-sinc-lp") == std::string("多相 sinc 线性相位"),
       "下拉项括号示例: poly-sinc-lp（多相 sinc 线性相位）", filter_family_full_label("poly-sinc-lp"));
    const std::string note = filter_family_full_note("poly-sinc-lp");
    ck(note.find("多相 sinc") != std::string::npos && note.find("线性相位") != std::string::npos,
       "族说明同时含族名与相位名", note);
    ck(!has_ascii_digit(note), "族说明不含数字（不做 dB/抽头承诺）", note);
    ck(!filter_family_full_note("foo-bar").empty(), "未知名的族说明非空", "");

    // ---- 7) 规则表自身：前缀非空、族与前缀不重复 ----
    std::size_t ruleCount = 0;
    const FilterFamilyRule* rules = filter_family_rules(&ruleCount);
    ck(ruleCount >= 8, "族规则表条目够覆盖名字表", std::to_string(ruleCount));
    for (std::size_t i = 0; i < ruleCount; ++i) {
        ck(rules[i].prefix && rules[i].prefix[0], "规则前缀非空", "");
        ck(rules[i].family != FilterFamily::Unknown, "规则不指向 Unknown", std::string(rules[i].prefix));
        for (std::size_t j = 0; j < i; ++j) {
            const bool same = std::string(rules[i].prefix) == std::string(rules[j].prefix);
            ck(!same, "前缀不重复: " + std::string(rules[i].prefix),
               same ? ("与第 " + std::to_string(j) + " 条重复") : "");
        }
    }

    std::printf("结果：%d passed, %d failed\n", passes, fails);
    return fails ? 1 : 0;
}
