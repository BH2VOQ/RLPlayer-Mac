// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_sdm_policy.cpp — U12：1-bit SDM 输出 corner 准入策略单测
//
// 只测策略头（不实例化调制器、不碰设备、不发声）：
//   A. 非真 EC + corner < 100 kHz 一律拒绝：code=sdm.corner_quality，消息以
//      SDM_CORNER_QUALITY 开头。20k/50k 是上游点名样例，99k 证明判据是
//      「< 100 kHz」而不是只认那两个值。
//   A2. 非真 EC + corner >= 100 kHz 准入：100k 作负向对照，证明实现不是「全拒」。
//   B. EC 豁免：Ec/false/20k 准入（EC 族 corner 由 H∞ 预算自适应，不吃 cutoff）。
//   C. Chebyshev 优先：Chebyshev/true/20k 仍拒绝（与 modulator.h 的 NTF 分支同构；
//      ecCorrection 不能把 Chebyshev 变回 EC）。
//   D. 非法数值：0 / 负数 / NaN 拒绝，且 code 与质量下限不同（sdm.corner_invalid）。
//   E. 抛异常版 validate_one_bit_sdm_corner(...) 与不抛版判定一致，异常类型必须是
//      std::invalid_argument，what() 内含对应稳定子串（UI 按子串匹配）。
#include "dsp/sdm_output_policy.h"

#include <cmath>
#include <cstdio>
#include <limits>
#include <stdexcept>
#include <string>

using namespace rta::dsp;

static int fails = 0;
static void check(bool ok, const std::string& what, const std::string& detail = "") {
    printf("  [%s] %s%s\n", ok ? "PASS" : "FAIL", what.c_str(),
           detail.empty() ? "" : ("  <- " + detail).c_str());
    if (!ok) ++fails;
}

static std::string hz_text(double v) {
    if (std::isnan(v)) return "NaN";
    if (std::isinf(v)) return v > 0 ? "+Inf" : "-Inf";
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%.0f", v);
    return std::string(buf);
}

static std::string label(ModulatorFamily fam, bool ec, double hz) {
    return std::string(modulator_family_name(fam)) + "/" + (ec ? "true" : "false") + "/" +
           hz_text(hz) + "Hz";
}

// 按 code 反查稳定子串：这是对外契约，故意用字面量（改字面量 = 测试要改）。
static const char* tag_of(const std::string& code) {
    if (code == "sdm.corner_quality") return "SDM_CORNER_QUALITY";
    if (code == "sdm.corner_invalid") return "SDM_CORNER_INVALID";
    return nullptr;
}

static void expect_admitted(ModulatorFamily fam, bool ec, double hz, const std::string& why) {
    const std::string who = label(fam, ec, hz);
    const SdmCornerAdmission a = sdm_corner_admission(fam, ec, hz);
    check(a.admitted, "准入 " + who + "  (" + why + ")",
          a.admitted ? "" : ("code=" + a.code + " msg=" + a.message));
    // 准入时不得残留 code/message（否则调用方可能误报成拒绝）。
    check(a.code.empty() && a.message.empty(), "准入 " + who + " 不残留 code/message",
          "code=" + a.code);

    bool threwInvalid = false, threwOther = false;
    std::string what;
    try {
        validate_one_bit_sdm_corner(fam, ec, hz);
    } catch (const std::invalid_argument& e) {
        threwInvalid = true;
        what = e.what();
    } catch (const std::exception& e) {
        threwOther = true;
        what = e.what();
    }
    check(!threwInvalid && !threwOther, "准入 " + who + " validate 不抛", what);
}

static void expect_rejected(ModulatorFamily fam, bool ec, double hz, const char* wantCode,
                            const std::string& why) {
    const std::string who = label(fam, ec, hz);
    const std::string prefix = "拒绝 " + who + "  (" + why + ")";
    const SdmCornerAdmission a = sdm_corner_admission(fam, ec, hz);

    check(!a.admitted, prefix);
    check(a.code == wantCode, prefix + " code==" + wantCode, "实际 code='" + a.code + "'");
    const char* tag = tag_of(wantCode);
    check(tag != nullptr && a.message.rfind(tag, 0) == 0,
          prefix + " 消息以 " + (tag ? tag : "<未知code>") + " 开头", a.message);

    bool threwInvalid = false, threwOther = false;
    std::string what;
    try {
        validate_one_bit_sdm_corner(fam, ec, hz);
    } catch (const std::invalid_argument& e) {
        threwInvalid = true;
        what = e.what();
    } catch (const std::exception& e) {
        threwOther = true;
        what = e.what();
    }
    check(threwInvalid && !threwOther, prefix + " validate 抛 std::invalid_argument", what);
    check(tag != nullptr && what.find(tag) != std::string::npos,
          prefix + " 异常消息含稳定子串", what);
}

int main() {
    printf("U12 1-bit SDM corner 准入策略单测（下限 %.0f Hz）\n", kSdmOneBitCornerFloorHz);

    printf("\n[A] 非真 EC + corner 低于 100 kHz：点名样例 20k/50k 与 99k 全部拒绝\n");
    expect_rejected(ModulatorFamily::Dsd, false, 20000.0, "sdm.corner_quality", "上游点名样例");
    expect_rejected(ModulatorFamily::Dsd, false, 50000.0, "sdm.corner_quality", "上游点名样例");
    expect_rejected(ModulatorFamily::Dsd, false, 99000.0, "sdm.corner_quality",
                    "证明判据是 < 100 kHz，而不是只认 20/50k");

    printf("\n[A2] 非真 EC + corner >= 100 kHz：准入（100k 兼作负向对照）\n");
    expect_admitted(ModulatorFamily::Dsd, false, 100000.0, "边界值 / 负向对照");
    expect_admitted(ModulatorFamily::Dsd, false, 200000.0, "高出下限");

    printf("\n[B] EC 豁免：低于 100 kHz 也准入\n");
    expect_admitted(ModulatorFamily::Ec, false, 20000.0,
                    "EC 族 corner 由 H∞ 预算决定，不吃 cutoff");

    printf("\n[C] Chebyshev 优先：ecCorrection 不能豁免\n");
    expect_rejected(ModulatorFamily::Chebyshev, true, 20000.0, "sdm.corner_quality",
                    "family==Chebyshev 时 ecCorrection 无效（与 NTF 分支同构）");
    expect_admitted(ModulatorFamily::Chebyshev, true, 100000.0, "Chebyshev 在合法 corner 下准入");

    printf("\n[D] 非法数值：corner <= 0 / 非有限，code 必须与质量下限不同\n");
    expect_rejected(ModulatorFamily::Dsd, false, 0.0, "sdm.corner_invalid", "corner == 0");
    expect_rejected(ModulatorFamily::Dsd, false, -1000.0, "sdm.corner_invalid", "corner < 0");
    expect_rejected(ModulatorFamily::Dsd, false, std::nan(""), "sdm.corner_invalid", "corner == NaN");
    // 本地明确定义（见头文件第 3 条）：数值校验先于族豁免，EC 族也不接受 NaN。
    // 若上游要求 EC 不校验 corner 数值，改动点仅此一条断言与 policy 里的顺序。
    expect_rejected(ModulatorFamily::Ec, false, std::nan(""), "sdm.corner_invalid",
                    "EC 族 + NaN（数值校验先于族豁免）");

    printf("\n[E] 两个入口判定一致（逐族抽样交叉核对）\n");
    {
        const struct { ModulatorFamily fam; bool ec; double hz; bool admitted; } rows[] = {
            {ModulatorFamily::Dsd,       false, 20000.0,  false},
            {ModulatorFamily::Dsd,       false, 100000.0, true},
            {ModulatorFamily::Ec,        false, 20000.0,  true},
            {ModulatorFamily::Chebyshev, true,  20000.0,  false},
            {ModulatorFamily::Chebyshev, true,  100000.0, true},
        };
        for (const auto& row : rows) {
            const SdmCornerAdmission a = sdm_corner_admission(row.fam, row.ec, row.hz);
            check(a.admitted == row.admitted,
                  "交叉核对 " + label(row.fam, row.ec, row.hz));
        }
    }

    printf("\n%s（失败项 %d）\n", fails == 0 ? "全部通过" : "存在失败", fails);
    return fails == 0 ? 0 : 1;
}
