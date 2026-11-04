// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_dsd_decimate_rate.cpp — 1.1.2 P0-3：DSD 抽取目标采样率的"族"判据
//
// ============================ 这个测试在证明什么 ============================
// 缺陷（基线 227de23）：三处都写 `std::min(rate/16, 705600u)`。
//   * 44.1k 族：DSD256 = 11 289 600 / 16 = 705 600 —— 恰好等于上限，看起来一直是对的；
//   * 48k 族：DSD256 = 12 288 000 / 16 = **768 000**，被 705 600 截断后
//       12 288 000 % 705 600 = 292 800 ≠ 0
//     ⟹ 整除校验失败，48k 族 DSD256/DSD512 直接报「无法整数抽取」，根本播不了。
//
// 为什么旧测试没抓到（铁律 3）：既有 DSD 用例全部用 44.1k 族素材，
// 「44.1k 能播」对 48k 族的整除性零信息量。这里的判据直接打**算术**：
// 对每个档位断言"返回值能整除源位率"，而不是"某个文件能播"。
//
// 🔴 铁律 1：纯算术，不开设备、不读用户文件、不出声。
#include "audio/audio_loader.h"

#include <cstdint>
#include <cstdio>
#include <string>

static int g_fail = 0;
static int g_total = 0;

static void ck(bool ok, const std::string& what, const std::string& detail = "") {
    ++g_total;
    if (!ok) ++g_fail;
    std::printf("  [%s] %s%s%s\n", ok ? "PASS" : "FAIL", what.c_str(),
                detail.empty() ? "" : "  ", detail.c_str());
}

struct Case {
    const char* what;
    uint32_t dsdRate;
    uint32_t want;
};

int main() {
    std::printf("=== DSD 抽取目标采样率（按族取上限）===\n");

    // ---- 1. 44.1k 族：既有行为必须逐值不变（零回归）----
    std::printf("\n[1] 44.1k 族（DSD64/128/256/512）\n");
    const Case fam441[] = {
        {"DSD64  = 2 822 400 -> 176 400", 2822400u, 176400u},
        {"DSD128 = 5 644 800 -> 352 800", 5644800u, 352800u},
        {"DSD256 = 11 289 600 -> 705 600", 11289600u, 705600u},
        {"DSD512 = 22 579 200 -> 705 600（上限封顶且整除）", 22579200u, 705600u},
    };
    for (const auto& c : fam441) ck(rta::audio::dsd_decimate_rate(c.dsdRate) == c.want, c.what,
                                    "got=" + std::to_string(rta::audio::dsd_decimate_rate(c.dsdRate)));

    // ---- 2. 48k 族：本轮修复的靶子 ----
    // 旧实现下 DSD256 会得到 705600（不整除 12 288 000），DSD512 同理。
    std::printf("\n[2] 48k 族（旧实现必红）\n");
    const Case fam48[] = {
        {"DSD64  = 3 072 000 -> 192 000", 3072000u, 192000u},
        {"DSD128 = 6 144 000 -> 384 000", 6144000u, 384000u},
        {"DSD256 = 12 288 000 -> 768 000（旧实现给 705 600，不整除）", 12288000u, 768000u},
        {"DSD512 = 24 576 000 -> 768 000（上限封顶且整除）", 24576000u, 768000u},
    };
    for (const auto& c : fam48) ck(rta::audio::dsd_decimate_rate(c.dsdRate) == c.want, c.what,
                                   "got=" + std::to_string(rta::audio::dsd_decimate_rate(c.dsdRate)));

    // ---- 3. 判据本体：任何非零返回值都必须能整除源位率 ----
    // 这条比逐值比对更强：以后再加档位，只要算错族就会被它抓住。
    std::printf("\n[3] 不变量：返回非 0 ⟹ 源位率 对 返回 取模 == 0\n");
    const uint32_t rates[] = {2822400u, 5644800u, 11289600u, 22579200u,
                              3072000u, 6144000u, 12288000u, 24576000u};
    for (uint32_t r : rates) {
        const uint32_t out = rta::audio::dsd_decimate_rate(r);
        const bool ok = out != 0 && (r % out == 0);
        ck(ok, "可整除 " + std::to_string(r),
           "out=" + std::to_string(out) +
           (out && r % out == 0 ? "" : "（余 " + std::to_string(out ? r % out : r) + "）"));
    }

    // ---- 4. 边界：0 与不可能整除的位率必须返回 0（调用方据此明确报错）----
    std::printf("\n[4] 边界与拒绝\n");
    ck(rta::audio::dsd_decimate_rate(0) == 0, "0 Hz -> 0（不猜）");
    // 2822401 / 16 截断成 176400，但 2822401 % 176400 != 0 ⟹ 必须返回 0
    ck(rta::audio::dsd_decimate_rate(2822401u) == 0, "非 16 整数倍位率 -> 0（不静默降级）",
       "got=" + std::to_string(rta::audio::dsd_decimate_rate(2822401u)));

    // ---- 5. 44.1k 与 48k 的 DSD256 结果必须不同（防"统一上限"回潮）----
    std::printf("\n[5] 两族 DSD256 不得相同\n");
    ck(rta::audio::dsd_decimate_rate(11289600u) == 705600u &&
       rta::audio::dsd_decimate_rate(12288000u) == 768000u,
       "44.1k DSD256=705600 与 48k DSD256=768000 各自成立");

    std::printf("\n=== 结果：%d 项，%d 失败 ===\n", g_total, g_fail);
    return g_fail == 0 ? 0 : 1;
}
