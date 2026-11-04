// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_cast_upsample_plan.cpp —— 投放升频目标率与位深决策纯函数表驱动单测
//
// 验证目标：
//   * 投放升频开关与请求参数解析规则；
//   * 跨族/同族整数倍约束（44.1k 族与 48k 族不互转）；
//   * 降采样绝对拒绝（只升不降）；
//   * 上限 (ceiling) 与渲染器能力约束压低（capped=true）；
//   * 渲染器未声明 (undeclared=true) 时的上限回退与同族倍数校验；
//   * 中英文 note 的如实描述与英文无 CJK 字符约束；
//   * 位深决策与 TPDF 抖动降位规则。
#include "audio/cast_upsample_plan.h"
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include <iostream>

using namespace rta::audio;

static int g_fail = 0;
static int g_pass = 0;

static void ck(bool cond, const char* name, const std::string& detail = "") {
    if (cond) {
        std::printf("  [PASS] %s\n", name);
        ++g_pass;
    } else {
        std::printf("  [FAIL] %s %s\n", name, detail.c_str());
        ++g_fail;
    }
}

// 检查是否包含 CJK 字符（UTF-8 首字节 >= 0xE3）
static bool has_cjk(const std::string& s) {
    for (unsigned char c : s) {
        if (c >= 0xE3) return true;
    }
    return false;
}

struct RateTestCase {
    const char* desc;
    uint32_t sourceRate;
    std::string requested;
    std::vector<uint32_t> rendererRates;
    uint32_t ceiling;
    bool applyUpsample;

    // 预期值
    uint32_t expTargetRate;
    bool expUpsample;
    bool expCapped;
    bool expUndeclared;
    std::string expReason;
    const char* whyProves; // 本条判据证明什么
};

struct BitTestCase {
    const char* desc;
    int sourceBits;
    int rendererMaxBits;
    int expServedBits;
    bool expReduced;
    const char* whyProves;
};

int main() {
    std::printf("=== test_cast_upsample_plan: 投放升频目标率与位深决策测试 ===\n\n");

    // =========================================================================
    // 1. 表驱动：采样率决策全矩阵
    // =========================================================================
    std::printf("-- 1. 采样率决策表驱动测试 --\n");

    const std::vector<RateTestCase> rateCases = {
        // 1. 开关关 + 任意请求 → 源率、upsample=false（reason="off"）
        {
            "开关关闭 + max 请求",
            44100, "max", {44100, 88200, 176400}, 192000, false,
            44100, false, false, false, "off",
            "证明：applyUpsample=false 时一律保持源采样率直供，reason 必须为 off"
        },
        {
            "开关关闭 + 数字请求",
            48000, "96000", {48000, 96000}, 192000, false,
            48000, false, false, false, "off",
            "证明：即使数字请求合法且渲染器支持，开关关闭时也绝不升频"
        },

        // 2. requested 为空串 / src / follow → 源率，reason="src"
        {
            "请求空串",
            44100, "", {44100, 88200}, 192000, true,
            44100, false, false, false, "src",
            "证明：请求空串代表跟随源，直接以源采样率直供"
        },
        {
            "请求 src",
            48000, "src", {48000, 96000}, 192000, true,
            48000, false, false, false, "src",
            "证明：显式请求 src 时保持源采样率，不进行升频"
        },
        {
            "请求 follow",
            96000, "follow", {48000, 96000, 192000}, 192000, true,
            96000, false, false, false, "src",
            "证明：显式请求 follow 时保持源采样率直供"
        },

        // 3. 'max' + 渲染器 {48000,96000} + ceiling 192000 + 源 48000 → 96000
        {
            "max 请求 + 渲染器能力受限",
            48000, "max", {48000, 96000}, 192000, true,
            96000, true, true, false, "ok",
            "证明：max 请求下被渲染器最高能力 96000 压低，capped=true 且成功升频到 96000"
        },

        // 4. 数字 384000 + 渲染器 {48000,96000} + ceiling 192000 + 源 48000 → 96000 且 capped=true
        {
            "数字请求超限被压低",
            48000, "384000", {48000, 96000}, 192000, true,
            96000, true, true, false, "ok",
            "证明：指定过高采样率时，cap 被 ceiling 与渲染器共同约束，capped=true 且选出 96000"
        },

        // 5. 跨族/同族约束：源 44100 + 'max' + 渲染器 {44100,48000,96000} + ceiling 192000 → 不升（no-same-family）
        {
            "跨族拒绝：渲染器仅有 48k 族更高速率",
            44100, "max", {44100, 48000, 96000}, 192000, true,
            44100, false, true, false, "no-same-family",
            "证明：44.1k 源绝不升到 48k 族（48000/96000 非 44100 整数倍），必须拒绝并退回源率；且因 max 请求下 rendererMax(96000) < ceiling(192000) 置 capped=true"
        },

        // 6. 同族可用时：源 44100 + 渲染器 {44100,88200,176400} + ceiling 192000 → 176400，upsample=true
        {
            "同族可用：升至同族最大可用倍率",
            44100, "max", {44100, 88200, 176400}, 192000, true,
            176400, true, true, false, "ok",
            "证明：44.1k 源在同族候选 {88200, 176400} 中正确选出最大值 176400；max 请求下 rendererMax(176400) < ceiling(192000) 置 capped=true"
        },

        // 7. 源已是目标率（数字=44100，源 44100）→ upsample=false, reason="already"
        {
            "源已是目标率：数字 44100 请求 44100 源",
            44100, "44100", {44100, 88200}, 192000, true,
            44100, false, false, false, "already",
            "证明：请求采样率与源相同时，认定无需升频，reason 为 already"
        },

        // 7b. 2026-11-05 真实设备实测回归：Rygel 只声明 audio/l16;rate=44100（没有更高同族速率）。
        //     这时**不能**说"源已是目标率 44100，无需升频"——那会让用户以为是自己设置错了；
        //     真实原因是"渲染器没声明更高的同族速率"，必须落在 no-same-family 并点名声明值。
        {
            "渲染器只声明源率本身：max + 声明 {44100} + 源 44100",
            44100, "max", {44100}, 192000, true,
            44100, false, true, false, "no-same-family",
            "证明：cap 塌到源率且用户要的是 max（不是点名要源率）时，原因必须是 no-same-family，"
            "不能冒充 already；note 必须把渲染器实际声明值写出来"
        },

        // 8. 降采样请求（源 192000，渲染器 {96000}，'max'）→ 不升，reason="no-down"
        {
            "降采样请求拒绝：max 算出上限低于源率",
            192000, "max", {96000}, 192000, true,
            192000, false, true, false, "no-down",
            "证明：投放升频只升不降，当目标上限低于源采样率时判定 no-down 并保持源率；max 请求被 rendererMax(96000) 压低故 capped=true"
        },
        {
            "降采样请求拒绝：显式数字请求低于源率",
            96000, "48000", {48000, 96000}, 192000, true,
            96000, false, false, false, "no-down",
            "证明：显式请求更低采样率时被判定为 no-down，绝不主动做降采样；请求 48000 且 cap=48000 未被压低故 capped=false"
        },

        // 9. 非法输入："" / "abc" / "0" / "999999999999" / sourceRate=0
        {
            "非法请求：字母 abc",
            44100, "abc", {44100, 88200}, 192000, true,
            44100, false, false, false, "invalid-request",
            "证明：非数字请求字符安全回退到源采样率，reason 标明 invalid-request"
        },
        {
            "非法请求：数字 0",
            44100, "0", {44100, 88200}, 192000, true,
            44100, false, false, false, "invalid-request",
            "证明：采样率 0 Hz 为非法输入，安全退回源率"
        },
        {
            "非法请求：uint32 溢出大数",
            44100, "999999999999", {44100, 88200}, 192000, true,
            44100, false, false, false, "invalid-request",
            "证明：超出 uint32 范围的大数解析失败并安全回退"
        },
        {
            "非法源率：sourceRate=0",
            0, "max", {44100, 88200}, 192000, true,
            0, false, false, false, "invalid-source",
            "证明：源采样率未知（0）时返回 0，reason 标明 invalid-source"
        },

        // 10. 上限边界：ceiling = 96000 / 192000 / 384000 / 768000 各一行；ceiling=0（不限）一行
        {
            "上限边界：ceiling 96000",
            48000, "max", {48000, 96000, 192000, 384000}, 96000, true,
            96000, true, false, false, "ok",
            "证明：ceiling=96000 成功卡住上限，不选 192000 或 384000"
        },
        {
            "上限边界：ceiling 192000",
            48000, "max", {48000, 96000, 192000, 384000}, 192000, true,
            192000, true, false, false, "ok",
            "证明：ceiling=192000 允许升至 192000"
        },
        {
            "上限边界：ceiling 384000",
            48000, "max", {48000, 96000, 192000, 384000, 768000}, 384000, true,
            384000, true, false, false, "ok",
            "证明：ceiling=384000 允许升至 384000"
        },
        {
            "上限边界：ceiling 768000",
            48000, "max", {48000, 96000, 192000, 384000, 768000}, 768000, true,
            768000, true, false, false, "ok",
            "证明：ceiling=768000 允许升至 768000"
        },
        {
            "上限边界：ceiling 0（不设上限）",
            48000, "max", {48000, 96000, 192000, 384000}, 0, true,
            384000, true, false, false, "ok",
            "证明：ceiling=0 代表不限，直接取渲染器声明的最大倍率 384000"
        },

        // 11. 渲染器未声明（空 vector）+ 'max' + ceiling 192000 + 源 48000 → 192000 且 undeclared=true
        {
            "渲染器未声明 + 同族倍数上限",
            48000, "max", {}, 192000, true,
            192000, true, false, true, "ok",
            "证明：渲染器未声明时触发 undeclared 标志，按同族上限直接作为目标率"
        },

        // 12. 渲染器未声明 + 源 44100 + ceiling 192000 → 不升（跨族 192000 % 44100 != 0），reason="no-same-family"
        {
            "渲染器未声明 + 跨族上限拒绝",
            44100, "max", {}, 192000, true,
            44100, false, false, true, "no-same-family",
            "证明：渲染器未声明时若上限非源率整数倍，判定 no-same-family 并保持源率"
        }
    };

    for (const auto& tc : rateCases) {
        CastRateDecision res = decide_cast_target_rate(tc.sourceRate, tc.requested, tc.rendererRates, tc.ceiling, tc.applyUpsample);
        bool match = (res.targetRate == tc.expTargetRate) &&
                     (res.upsample == tc.expUpsample) &&
                     (res.capped == tc.expCapped) &&
                     (res.undeclared == tc.expUndeclared) &&
                     (res.reason == tc.expReason);

        std::string detail;
        if (!match) {
            detail = "[got: rate=" + std::to_string(res.targetRate) +
                     " up=" + std::to_string(res.upsample) +
                     " cap=" + std::to_string(res.capped) +
                     " undec=" + std::to_string(res.undeclared) +
                     " reason=" + res.reason + "]";
        }
        ck(match, tc.desc, detail);

        // 附带断言：证明每一条判据背后的文案合规
        ck(!res.noteEn.empty(), (std::string(tc.desc) + " noteEn 非空").c_str());
        ck(!has_cjk(res.noteEn), (std::string(tc.desc) + " noteEn 不含 CJK 字符").c_str(), res.noteEn);
        ck(!res.noteZh.empty(), (std::string(tc.desc) + " noteZh 非空").c_str());
    }

    // =========================================================================
    // 2. 深度验证：note 文案中的真相与数字对齐
    // =========================================================================
    std::printf("\n-- 2. 文案真相与数字一致性断言 --\n");
    {
        // 跨族时 note 必须出现声明列表
        CastRateDecision d1 = decide_cast_target_rate(44100, "max", {44100, 48000, 96000}, 192000, true);
        ck(d1.reason == "no-same-family", "跨族拒绝 reason=no-same-family");
        ck(d1.noteZh.find("44100/48000/96000") != std::string::npos, "中文 note 包含完整渲染器声明列表", d1.noteZh);
        ck(d1.noteEn.find("44100/48000/96000") != std::string::npos, "英文 note 包含完整渲染器声明列表", d1.noteEn);
        ck(d1.noteZh.find("44.1 kHz") != std::string::npos, "中文 note 标明 44.1 kHz 族", d1.noteZh);

        // capped 时 note 必须解释被压到多少
        CastRateDecision d2 = decide_cast_target_rate(48000, "384000", {48000, 96000}, 192000, true);
        ck(d2.capped, "capped 标志置位");
        ck(d2.noteZh.find("384000") != std::string::npos && d2.noteZh.find("96000") != std::string::npos,
           "中文 note 同时包含请求值 384000 与压制值 96000", d2.noteZh);
        ck(d2.noteEn.find("384000") != std::string::npos && d2.noteEn.find("96000") != std::string::npos,
           "英文 note 同时包含请求值 384000 与压制值 96000", d2.noteEn);
    }

    // =========================================================================
    // 3. 表驱动：位深决策组合表
    // =========================================================================
    std::printf("\n-- 3. 供源位深决策组合表 (16/24/32 源 × 渲染器上限 16/24/0) --\n");

    const std::vector<BitTestCase> bitCases = {
        // 源 16
        { "源 16 × 渲染器 16", 16, 16, 16, false, "证明：位深相同不降低、不加抖动" },
        { "源 16 × 渲染器 24", 16, 24, 16, false, "证明：渲染器能力高于源时，维持源位深直供" },
        { "源 16 × 渲染器 0（未声明）", 16, 0, 16, false, "证明：渲染器未声明位深上限时，维持源位深直供" },

        // 源 24
        { "源 24 × 渲染器 16", 24, 16, 16, true, "证明：源 24 降至 16，reduced=true 且需加 TPDF 抖动" },
        { "源 24 × 渲染器 24", 24, 24, 24, false, "证明：位深相同时维持 24bit" },
        { "源 24 × 渲染器 0（未声明）", 24, 0, 24, false, "证明：渲染器未声明位深上限时，维持源 24bit" },

        // 源 32
        { "源 32 × 渲染器 16", 32, 16, 16, true, "证明：源 32 降至 16，reduced=true" },
        { "源 32 × 渲染器 24", 32, 24, 24, true, "证明：源 32 降至 24，reduced=true" },
        { "源 32 × 渲染器 0（未声明）", 32, 0, 32, false, "证明：渲染器未声明位深上限时，维持源 32bit" },

        // 异常输入边界
        { "源 <= 0 异常", 0, 24, 0, false, "证明：源位深非法时返回 0" },
        { "源 -1 异常", -1, 16, 0, false, "证明：负源位深返回 0" }
    };

    for (const auto& tc : bitCases) {
        CastBitDecision b1 = decide_cast_served_bits(tc.sourceBits, tc.rendererMaxBits);
        CastBitDecision b2 = decide_served_bits(tc.sourceBits, tc.rendererMaxBits);

        // 验证别名一致性
        bool aliasMatch = (b1.servedBits == b2.servedBits) && (b1.reduced == b2.reduced);
        ck(aliasMatch, (std::string(tc.desc) + " 别名签名一致").c_str());

        bool match = (b1.servedBits == tc.expServedBits) && (b1.reduced == tc.expReduced);
        ck(match, tc.desc, "[got: served=" + std::to_string(b1.servedBits) + " red=" + std::to_string(b1.reduced) + "]");

        if (tc.expReduced) {
            ck(!b1.noteZh.empty(), (std::string(tc.desc) + " noteZh 包含降位说明").c_str());
            ck(!b1.noteEn.empty(), (std::string(tc.desc) + " noteEn 包含降位说明").c_str());
            ck(!has_cjk(b1.noteEn), (std::string(tc.desc) + " noteEn 不含 CJK").c_str(), b1.noteEn);
            ck(b1.noteZh.find("TPDF") != std::string::npos, (std::string(tc.desc) + " noteZh 说明 TPDF 抖动").c_str());
            ck(b1.noteEn.find("TPDF") != std::string::npos, (std::string(tc.desc) + " noteEn 说明 TPDF dither").c_str());
        }
    }

    std::printf("\n=======================================================\n");
    std::printf("test_cast_upsample_plan 结果: PASS=%d, FAIL=%d\n", g_pass, g_fail);
    std::printf("=======================================================\n");

    return g_fail == 0 ? 0 : 1;
}
