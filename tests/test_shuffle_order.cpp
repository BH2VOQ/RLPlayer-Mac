// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_shuffle_order.cpp — 随机播放顺序的纯逻辑判据（1.1.7.1）
//
// 为什么单独抽这一层：随机播放在"用户可感知"层面只有三条硬要求，
// 任何一条错了都会立刻被听出来：
//   ① 一轮内不重复（排列，不是逐首 roll）；
//   ② 一轮走完重洗后，**不要把刚播完的那首立刻排到第一个**；
//   ③ 洗牌本身要均匀（不是"看起来随机"）。
// 本测试逐条断言，并用可注入 RNG 做确定性复现。
#include "net/shuffle_order.h"

#include <cstdio>
#include <map>
#include <random>
#include <set>
#include <vector>

using rta::playback::make_shuffle_order;
using rta::playback::kNoAvoidIndex;

static int g_fail = 0;
static void ck(bool ok, const char *what, const std::string &detail = std::string()) {
    if (ok) std::printf("  [PASS] %s\n", what);
    else { std::printf("  [FAIL] %s  %s\n", what, detail.c_str()); ++g_fail; }
}

int main() {
    std::printf("=== test_shuffle_order: 随机播放顺序 ===\n");

    // 1) 排列合法性：0..n-1 每个恰好出现一次
    for (std::size_t n : {0u, 1u, 2u, 3u, 10u, 100u}) {
        std::mt19937_64 rng(12345 + n);
        const auto order = make_shuffle_order(n, rng);
        std::vector<int> seen(n, 0);
        bool inrange = true, unique = true;
        for (std::size_t v : order) {
            if (v >= n) { inrange = false; continue; }
            if (seen[v]++) unique = false;
        }
        ck(order.size() == n && inrange && unique,
           ("n=" + std::to_string(n) + " 是 0..n-1 的合法排列").c_str(),
           "size=" + std::to_string(order.size()));
    }

    // 2) 确定性：同种子同结果，不同种子大概率不同
    {
        std::mt19937_64 a(777), b(777), c(778);
        const auto oa = make_shuffle_order(50, a);
        const auto ob = make_shuffle_order(50, b);
        const auto oc = make_shuffle_order(50, c);
        ck(oa == ob, "同种子 → 同排列（可复现）");
        ck(oa != oc, "不同种子 → 不同排列");
    }

    // 3) avoid：n>1 时首元素永远不是刚播完的那首
    {
        bool all = true;
        for (std::size_t n = 2; n <= 40; n += 7) {
            for (std::size_t avoid = 0; avoid < n; ++avoid) {
                for (int seed = 0; seed < 20; ++seed) {
                    std::mt19937_64 rng((std::uint64_t)(seed * 131 + n * 17 + avoid));
                    const auto order = make_shuffle_order(n, rng, avoid);
                    if (order.size() != n || order[0] == avoid) { all = false; break; }
                }
                if (!all) break;
            }
            if (!all) break;
        }
        ck(all, "重洗后第一首 ≠ 刚播完的那首（n=2..40 全枚举）");
    }
    {
        std::mt19937_64 rng(1);
        const auto one = make_shuffle_order(1, rng, 0);
        ck(one.size() == 1 && one[0] == 0, "n=1 + avoid=0 仍返回唯一元素（不越界/不死循环）");
        const auto none = make_shuffle_order(5, rng, kNoAvoidIndex);
        ck(none.size() == 5, "kNoAvoidIndex 表示不做规避");
    }

    // 4) 均匀性（粗糙但足够的合理性检查）：n=3 的 6 种排列在 12000 次里都应出现，
    //    且每种的频率在 1/6 的 ±40% 内。这里证明的是"不是只用了少数排列"，
    //    不是严格的卡方检验（严格检验需要固定 RNG 序列，反而更脆）。
    {
        std::mt19937_64 rng(20261111);
        std::map<std::vector<std::size_t>, int> freq;
        const int N = 12000;
        for (int i = 0; i < N; ++i) freq[make_shuffle_order(3, rng)]++;
        ck(freq.size() == 6, "n=3 的 6 种排列全部出现", "kinds=" + std::to_string(freq.size()));
        bool balanced = true;
        for (const auto &kv : freq) {
            const double p = (double)kv.second / N;
            if (p < 1.0 / 6 * 0.6 || p > 1.0 / 6 * 1.4) balanced = false;
        }
        ck(balanced, "每种排列频率在 1/6 ±40% 内");
    }

    // 5) 大 n 不重复、不越界（1000）
    {
        std::mt19937_64 rng(999);
        const auto order = make_shuffle_order(1000, rng, 500);
        std::vector<char> seen(1000, 0);
        bool ok = true;
        for (std::size_t v : order) { if (v >= 1000 || seen[v]) ok = false; seen[v] = 1; }
        ck(ok && order[0] != 500, "n=1000：排列完整且首元素规避生效");
    }

    std::printf("\n%s（%d 项失败）\n", g_fail == 0 ? "shuffle_order 全部通过" : "shuffle_order 有失败", g_fail);
    return g_fail == 0 ? 0 : 1;
}
