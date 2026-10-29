// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_output_bit_depth.cpp — resolve_output_bits 单元测试
#include "audio/output_bit_depth.h"
#include <cstdio>
#include <string>

static int g_fail = 0;
static void ck(bool cond, const char* what, const std::string& detail = "") {
    if (cond) {
        std::printf("  [PASS] %s\n", what);
    } else {
        std::printf("  [FAIL] %s  %s\n", what, detail.c_str());
        ++g_fail;
    }
}

int main() {
    std::printf("== resolve_output_bits 单元测试 ==\n");

    // 1. setting == -1（跟随源）测试
    ck(rta::audio::resolve_output_bits(-1, 16) == 16, "setting=-1, sourceBits=16 -> 16");
    ck(rta::audio::resolve_output_bits(-1, 24) == 24, "setting=-1, sourceBits=24 -> 24");
    ck(rta::audio::resolve_output_bits(-1, 32) == 32, "setting=-1, sourceBits=32 -> 32");

    // 2. setting == -1 时 sourceBits 为未知/异常情况（fallback 24）
    ck(rta::audio::resolve_output_bits(-1, 0) == 24, "setting=-1, sourceBits=0 -> fallback 24");
    ck(rta::audio::resolve_output_bits(-1, -1) == 24, "setting=-1, sourceBits=-1 -> fallback 24");
    ck(rta::audio::resolve_output_bits(-1, 12) == 24, "setting=-1, sourceBits=12 (非标准) -> fallback 24");

    // 3. setting == 0（默认）固定 24
    ck(rta::audio::resolve_output_bits(0, 16) == 24, "setting=0, sourceBits=16 -> 24");
    ck(rta::audio::resolve_output_bits(0, 24) == 24, "setting=0, sourceBits=24 -> 24");
    ck(rta::audio::resolve_output_bits(0, 32) == 24, "setting=0, sourceBits=32 -> 24");
    ck(rta::audio::resolve_output_bits(0, 0) == 24, "setting=0, sourceBits=0 -> 24");

    // 4. setting > 0（显式固定位深）
    ck(rta::audio::resolve_output_bits(16, 24) == 16, "setting=16, sourceBits=24 -> 16");
    ck(rta::audio::resolve_output_bits(24, 16) == 24, "setting=24, sourceBits=16 -> 24");
    ck(rta::audio::resolve_output_bits(32, 16) == 32, "setting=32, sourceBits=16 -> 32");

    // 5. 其他非法负值
    ck(rta::audio::resolve_output_bits(-2, 16) == 24, "setting=-2 -> fallback 24");
    ck(rta::audio::resolve_output_bits(-99, 32) == 24, "setting=-99 -> fallback 24");

    if (g_fail == 0) {
        std::printf("\nALL TESTS PASSED\n");
        return 0;
    } else {
        std::printf("\n%d TESTS FAILED\n", g_fail);
        return 1;
    }
}
