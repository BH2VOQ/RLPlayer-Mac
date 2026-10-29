// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
#include "dsp/ir_resample.h"
#include <cstdio>
#include <numeric>
#include <cmath>
#include <vector>

int main() {
    bool ok = true;
    auto ck = [&](bool cond, const char* name) {
        printf("%s %s\n", cond ? "PASS" : "FAIL", name);
        if (!cond) ok = false;
    };

    // 1. 同率逐位不改 (same-rate bitwise passthrough)
    {
        std::vector<double> ir(4096);
        ir[441] = 1.0;
        auto same = rta::dsp::resample_ir(ir, 44100, 44100);
        ck(same == ir, "same-rate bitwise passthrough");
    }

    // 2. 长 IR (4096 tap)：44.1k -> 96k 物理峰位不偏且 sum 约 1
    {
        std::vector<double> ir(4096, 0.0);
        ir[441] = 1.0;
        auto out = rta::dsp::resample_ir(ir, 44100, 96000);
        auto peak = std::max_element(out.begin(), out.end(), [](double a, double b) { return std::abs(a) < std::abs(b); });
        const auto pos = peak - out.begin();
        double sum = std::accumulate(out.begin(), out.end(), 0.0);
        ck(std::abs((long)pos - 960) <= 1, "long IR 44.1k->96k peak position preserved (expected 960)");
        ck(std::abs(sum - 1.0) < 0.02, "long IR 44.1k->96k sum approx 1");
    }

    // 3. 短 IR (<200 tap) 保尾防 sum 偏差：测试 4 种比率下 sum 均约 1，且物理峰位不偏
    // 4 种比率：44.1k->96k, 96k->44.1k, 44.1k->48k, 48k->44.1k
    const std::pair<uint32_t, uint32_t> rates[4] = {
        {44100, 96000}, {96000, 44100}, {44100, 48000}, {48000, 44100}
    };

    for (size_t n : {16u, 64u, 128u, 199u}) {
        size_t imp = n / 2;
        for (const auto& pr : rates) {
            std::vector<double> ir(n, 0.0);
            ir[imp] = 1.0;
            auto out = rta::dsp::resample_ir(ir, pr.first, pr.second);
            double sum = std::accumulate(out.begin(), out.end(), 0.0);
            auto peak = std::max_element(out.begin(), out.end(), [](double a, double b) { return std::abs(a) < std::abs(b); });
            size_t pos = peak - out.begin();
            double expected_pos = imp * ((double)pr.second / pr.first);

            char desc[128];
            std::snprintf(desc, sizeof(desc), "short IR n=%zu %u->%u sum=%.4f (target ~1.0)", n, pr.first, pr.second, sum);
            ck(std::abs(sum - 1.0) < 0.02, desc);

            std::snprintf(desc, sizeof(desc), "short IR n=%zu %u->%u peak pos=%zu (exp=%.1f)", n, pr.first, pr.second, pos, expected_pos);
            ck(std::abs((double)pos - expected_pos) <= 1.0, desc);
        }
    }

    return ok ? 0 : 1;
}
