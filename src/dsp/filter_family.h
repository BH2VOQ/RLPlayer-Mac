// SPDX-FileCopyrightText: 2026 rainlain <https://github.com/okhuoyanyan>
// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// filter_family.h — 滤波器「族」标注（纯头，只做分类与展示，不碰任何滤波器实现）
//
// 族的划分只有两份来源，**没有第三份**：
//   ① docs/滤波器家族纪要.md：窗函数决定「家族性格」——poly-sinc 系用 Kaiser、
//      gauss 系用 Gaussian、closed-form/sinc 系用 Blackman-Harris（旁瓣最低）；
//      -lp / -mp / -ip 后缀决定「时间行为」——线性 / 最小 / 混合相位。
//      §4 还点名了 hb（half-band）族与 minringFIR 属特殊类型。
//   ② src/dsp/filter_families.h 的预设名字表：名字前缀就是族
//      （poly-sinc- / poly-sinc-gauss- / poly-sinc-ext2- / poly-sinc-hb- /
//       sinc- / closed-form- / minringFIR / apod-）。
//
// 纪律：
//   * 分类只看名字前缀（表驱动，加族 = 加一行规则），不看抽头/窗参数 ——
//     那些是预设表的事实，UI 不该复制第二份。
//   * 名字对不上任何规则 ⟹ Unknown（「未分类」），**绝不猜**。
//   * label / note 只写族名与行为描述（取自纪要），不写 dB / 抽头 / 比率等
//     任何数值承诺 —— 用户要看的是「这族是什么性格」，不是「这族多少 dB」。
#pragma once

#include <cstddef>
#include <cstring>
#include <string>

namespace rta::dsp {

enum class FilterFamily {
    PolySinc,       // 多相 sinc（Kaiser 窗）：纪要 §1「poly-sinc 系用 Kaiser」
    PolySincGauss,  // 多相 sinc 高斯（Gaussian 窗）：纪要 §1「gauss 系用 Gaussian」
    Ext2,           // 多相 sinc 扩展频响（Blackman-Harris 窗）：名字表第 3 组
    HalfBand,       // 半带：纪要 §4 点名的 hb 族
    Sinc,           // 超长 sinc（名字表第 5 组：S / M / MG / L / LL）
    ClosedForm,     // 闭式插值（Blackman-Harris 窗）：纪要 §1
    MinRing,        // 最小振铃：纪要 §4 点名、名字表第 7 组
    Apodizing,      // 切趾：名字表第 8 组（通带高频平滑滚降，压低预振铃）
    Unknown         // 未分类（对不上任何前缀）
};

// 名字后缀给出的相位。纪要把相位列为与窗正交的第二根轴，所以它是独立于族的
// 维度，**不**塞进 FilterFamily —— 否则「多相 sinc」会按相位被切成三份，
// 加一个新相位后缀就要加三个族。
enum class FilterPhase { Linear, Minimum, Intermediate, Unspecified };

// ------------- 名字工具 -------------

inline bool filter_name_ends_with(const std::string& s, const char* suffix) {
    const std::size_t n = std::strlen(suffix);
    return s.size() >= n && n > 0 && s.compare(s.size() - n, n, suffix) == 0;
}

// 「-2s」（两段式）与族/相位都正交，判族与判相位前先把它摘掉：
//   poly-sinc-mp-2s ⟹ 基础名 poly-sinc-mp ⟹ 多相 sinc · 最小相位
// 不摘也不会认错族（前缀匹配在行首），但会把 -mp-2s 的相位丢掉。
inline std::string filter_base_name(const std::string& name) {
    if (filter_name_ends_with(name, "-2s")) return name.substr(0, name.size() - 3);
    return name;
}

// 规则前缀必须**在词首成词**：整名等于前缀，或前缀后紧跟 '-'。
// 为什么不是裸的 startsWith：那样 "poly-sincx" / "apodfoo" 这类不存在的名字
// 会被误判成具体族 —— 负向对照要求「不存在的名字不误判」。
inline bool filter_prefix_at_word_start(const std::string& base, const char* prefix) {
    const std::size_t n = std::strlen(prefix);
    if (n == 0 || base.size() < n) return false;
    if (base.compare(0, n, prefix) != 0) return false;
    if (prefix[n - 1] == '-') return true;               // 前缀自带分隔符
    return base.size() == n || base[n] == '-';           // 其余必须成词
}

// ------------- 分类 -------------

struct FilterFamilyRule {
    const char*  prefix;   // 名字前缀（长前缀优先，见 filter_family）
    FilterFamily family;
};

/// 前缀 → 族的规则表。**加族 = 加一行**（并同步 label / note / id 三个 switch）。
inline const FilterFamilyRule* filter_family_rules(std::size_t* count) {
    static const FilterFamilyRule k[] = {
        { "poly-sinc-gauss", FilterFamily::PolySincGauss },
        { "poly-sinc-ext2",  FilterFamily::Ext2          },
        { "poly-sinc-hb",    FilterFamily::HalfBand      },
        { "poly-sinc",       FilterFamily::PolySinc      },
        { "closed-form",     FilterFamily::ClosedForm    },
        { "sinc-",           FilterFamily::Sinc          },
        { "minringFIR",      FilterFamily::MinRing       },
        { "apod",            FilterFamily::Apodizing     },
    };
    if (count) *count = sizeof(k) / sizeof(k[0]);
    return k;
}

/// 按名字前缀归族；对不上 ⟹ Unknown。最长前缀优先（poly-sinc-gauss 胜过 poly-sinc）。
inline FilterFamily filter_family(const std::string& name) {
    const std::string base = filter_base_name(name);
    std::size_t n = 0;
    const FilterFamilyRule* rules = filter_family_rules(&n);
    const FilterFamilyRule* best = nullptr;
    std::size_t bestLen = 0;
    for (std::size_t i = 0; i < n; ++i) {
        const std::size_t len = std::strlen(rules[i].prefix);
        if (len <= bestLen) continue;
        if (!filter_prefix_at_word_start(base, rules[i].prefix)) continue;
        best = &rules[i];
        bestLen = len;
    }
    return best ? best->family : FilterFamily::Unknown;
}

/// 名字后缀给出的相位（-2s 先摘掉）。名字没写相位 ⟹ Unspecified，不替预设表代言。
inline FilterPhase filter_phase_of_name(const std::string& name) {
    const std::string base = filter_base_name(name);
    if (filter_name_ends_with(base, "-lp")) return FilterPhase::Linear;
    if (filter_name_ends_with(base, "-mp")) return FilterPhase::Minimum;
    if (filter_name_ends_with(base, "-ip")) return FilterPhase::Intermediate;
    return FilterPhase::Unspecified;
}

// ------------- 展示文案（UI 与 /api/filters 的唯一出处） -------------

/// 稳定的机器可读族 id（/api/filters 的 family 字段）。用名字前缀是因为它本来就是
/// 用户认得出的族名，且改 id 会破坏前端缓存/日志比对。
inline const char* filter_family_id(FilterFamily f) {
    switch (f) {
        case FilterFamily::PolySinc:      return "poly-sinc";
        case FilterFamily::PolySincGauss: return "poly-sinc-gauss";
        case FilterFamily::Ext2:          return "poly-sinc-ext2";
        case FilterFamily::HalfBand:      return "poly-sinc-hb";
        case FilterFamily::Sinc:          return "sinc";
        case FilterFamily::ClosedForm:    return "closed-form";
        case FilterFamily::MinRing:       return "minringFIR";
        case FilterFamily::Apodizing:     return "apod";
        case FilterFamily::Unknown:       return "unknown";
    }
    return "unknown";
}

/// 族的中文名（下拉项括号里的前半截 / /api/filters 的 familyLabel 基础名）。
/// **不含任何数值**。
inline const char* filter_family_label(FilterFamily f) {
    switch (f) {
        case FilterFamily::PolySinc:      return "多相 sinc";
        case FilterFamily::PolySincGauss: return "多相 sinc 高斯";
        case FilterFamily::Ext2:          return "多相 sinc 扩展频响";
        case FilterFamily::HalfBand:      return "半带";
        case FilterFamily::Sinc:          return "超长 sinc";
        case FilterFamily::ClosedForm:    return "闭式插值";
        case FilterFamily::MinRing:       return "最小振铃";
        case FilterFamily::Apodizing:     return "切趾";
        case FilterFamily::Unknown:       return "未分类";
    }
    return "未分类";
}

/// 一行的族说明（与具体相位无关的性格描述）。文案出自纪要，**不含数值承诺**；
/// 对纪要点到名字但没展开描述的族，就如实只说「手册里的某族」，不补编特性。
inline const char* filter_family_note(FilterFamily f) {
    switch (f) {
        case FilterFamily::PolySinc:
            return "多相 sinc：Kaiser 窗，经典高衰减家族。";
        case FilterFamily::PolySincGauss:
            return "多相 sinc 高斯：Gaussian 窗，滚降更平缓。";
        case FilterFamily::Ext2:
            return "多相 sinc 扩展频响：Blackman-Harris 窗，旁瓣更低。";
        case FilterFamily::HalfBand:
            return "半带：手册里的 half-band 族。";
        case FilterFamily::Sinc:
            return "超长 sinc：档位 S / M / MG / L / LL 逐级加长。";
        case FilterFamily::ClosedForm:
            return "闭式插值：Blackman-Harris 窗，旁瓣最低。";
        case FilterFamily::MinRing:
            return "最小振铃：手册列为特殊类型。";
        case FilterFamily::Apodizing:
            return "切趾：通带高频平滑滚降，压低预振铃。";
        case FilterFamily::Unknown:
            return "未分类：纪要的族划分与名字表里都没有把握归族。";
    }
    return "未分类：纪要的族划分与名字表里都没有把握归族。";
}

inline const char* filter_phase_label(FilterPhase p) {
    switch (p) {
        case FilterPhase::Linear:       return "线性相位";
        case FilterPhase::Minimum:      return "最小相位";
        case FilterPhase::Intermediate: return "混合相位";
        case FilterPhase::Unspecified:  return "";
    }
    return "";
}

/// 相位的行为说明（纪要 §1「相位决定时间行为」+ §2 的核心验证结论）。
inline const char* filter_phase_note(FilterPhase p) {
    switch (p) {
        case FilterPhase::Linear:
            return "线性相位：冲激响应对称，峰值前后都有振铃。";
        case FilterPhase::Minimum:
            return "最小相位：无前振铃，能量集中在脉冲起始处。";
        case FilterPhase::Intermediate:
            return "混合相位：幅频不变，群延迟落在最小与线性之间。";
        case FilterPhase::Unspecified:
            return "";
    }
    return "";
}

/// 展示标签 = 族名 +（名字真的写了相位时）相位名。名字没写相位就不替预设表代言。
/// 例：poly-sinc-lp ⟹ 「多相 sinc 线性相位」；unknown ⟹ 「未分类」。
inline std::string filter_family_full_label(const std::string& name) {
    const FilterFamily fam = filter_family(name);
    std::string s = filter_family_label(fam);
    if (fam == FilterFamily::Unknown) return s;
    const FilterPhase ph = filter_phase_of_name(name);
    if (ph == FilterPhase::Unspecified) return s;
    s += " ";
    s += filter_phase_label(ph);
    return s;
}

/// 一行的族说明 = 族说明 +（名字真的写了相位时）相位说明。
inline std::string filter_family_full_note(const std::string& name) {
    const FilterFamily fam = filter_family(name);
    std::string s = filter_family_note(fam);
    if (fam == FilterFamily::Unknown) return s;
    const FilterPhase ph = filter_phase_of_name(name);
    if (ph == FilterPhase::Unspecified) return s;
    s += " ";
    s += filter_phase_note(ph);
    return s;
}

}  // namespace rta::dsp
