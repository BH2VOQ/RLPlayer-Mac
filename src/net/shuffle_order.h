// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// shuffle_order.h — 随机播放的**排列生成**（纯逻辑、可注入 RNG、可离线单测）
//
// 为什么把这几行单独抽出来：随机播放只有三条用户能立刻听出来的硬要求
//   （一轮不重复 / 重洗后不立刻重复上一首 / 洗牌足够均匀），
// 而它们都落在"排列怎么生成"这一件事上。抽成纯函数后可以用固定种子复现，
// 不必起播放器、不碰音频设备。
#pragma once

#include <cstddef>
#include <random>
#include <utility>
#include <vector>

namespace rta::playback {

inline constexpr std::size_t kNoAvoidIndex = static_cast<std::size_t>(-1);

// Fisher–Yates 生成 0..n-1 的随机排列。
//   * n < 2 时直接返回原序（调用方不必特殊判断）；
//   * avoid != kNoAvoidIndex 且 n > 1 时保证 order[0] != avoid：
//     用于"一轮走完重洗后，不要把刚播完的那首立刻又排到第一个"。
// 用调用方注入的 RNG（生产 = 系统 CSPRNG 播种的 mt19937_64；测试 = 固定种子）。
inline std::vector<std::size_t> make_shuffle_order(std::size_t n,
                                                   std::mt19937_64& rng,
                                                   std::size_t avoid = kNoAvoidIndex) {
    std::vector<std::size_t> order(n);
    for (std::size_t i = 0; i < n; ++i) order[i] = i;
    if (n < 2) return order;

    for (std::size_t i = n - 1; i > 0; --i) {
        std::uniform_int_distribution<std::size_t> dist(0, i);
        std::swap(order[i], order[dist(rng)]);
    }

    if (avoid < n && order[0] == avoid) {
        for (std::size_t k = 1; k < n; ++k) {
            if (order[k] != avoid) {
                std::swap(order[0], order[k]);
                break;
            }
        }
    }
    return order;
}

}  // namespace rta::playback
