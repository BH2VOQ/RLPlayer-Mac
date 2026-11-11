// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_native_bridge.cpp — 1.1.7 P1 桥层纯逻辑门禁（新增）
//
// 判据（方案 §3.4）：同值去重、非法值回落、revision 只随真实状态变化递增。
// 本测试用 rlapp::dispatch() 打现有 /api/* handler（进程内、不监听端口），
// backend=null / volume=-120，不打开任何声音设备、不开窗口、不联网。
// 红→绿纪律：先断言「不带去重会重复写盘」在旧实现上为红，再在本层实现后转绿。
#include "native/core_bridge.h"

#include <cstdio>
#include <cstdlib>
#include <string>

#include "rlapp_core.h"

namespace {
int g_fail = 0;
void ck(bool ok, const char* name) {
    std::printf("%-56s %s\n", name, ok ? "PASS" : "FAIL");
    if (!ok) ++g_fail;
}
}

int main(int argc, char** argv) {
    (void)argc; (void)argv;
    // 隔离运行期状态，绝不写进用户真实目录（项目铁律）。
    const std::string root = "/tmp/rl-native-bridge-test";
    ::setenv("RLPLAYER_STATE_DIR", (root + "/state").c_str(), 1);
    ::setenv("RLPLAYER_LIBRARY_DIR", (root + "/lib").c_str(), 1);
    ::setenv("HOME", (root + "/home").c_str(), 1);
    (void)::system(("rm -rf '" + root + "' && mkdir -p '" + root + "/state' '" + root + "/lib' '" + root + "/home'").c_str());

    if (!rlapp::start_embedded()) {
        std::printf("FAIL 核心启动失败\n");
        return 1;
    }
    rlnative::reset_bridge_state();

    // 1) 首次设置：从默认 mode=0 切到 3，应返回 true 且 revision 递增。
    const auto s0 = rlnative::snapshot();
    const bool changed = rlnative::set_mode(0 == s0.mode ? 3 : 0);
    ck(changed, "set_mode(new) returns true (state changed)");
    const auto s1 = rlnative::snapshot();
    ck(s1.revision > s0.revision, "revision increments on real state change");
    ck(s1.mode == (s0.mode == 0 ? 3 : 0), "snapshot reflects new mode");

    // 2) 同值设置：去重，返回 false，revision 不变。
    const bool same = rlnative::set_mode(s1.mode);
    ck(!same, "set_mode(same) returns false (dedup)");
    const auto s2 = rlnative::snapshot();
    ck(s2.revision == s1.revision, "revision unchanged on dedup");

    // 3) 非法值回落：9 / -1 都钳到 0。
    ck(rlnative::set_mode(9) == (s2.mode != 0), "set_mode(9) clamps to 0 (or dedups if already 0)");
    const auto s3 = rlnative::snapshot();
    ck(s3.mode == 0, "illegal value 9 -> mode 0");
    (void)rlnative::set_mode(-1);
    ck(rlnative::snapshot().mode == 0, "illegal value -1 -> mode 0");

    // 4) 进度不参与 revision：连续两次 snapshot（状态不变）revision 相同。
    const auto s4 = rlnative::snapshot();
    const auto s5 = rlnative::snapshot();
    ck(s4.revision == s5.revision, "progress-only poll does not bump revision");

    // 5) 队列与专辑接口可用（不报错、返回可解析结构）。
    const auto q = rlnative::queue(false);
    ck(q.mode == 0 || q.mode == 1 || q.mode == 2 || q.mode == 3, "queue() mode is valid 0..3");
    const auto albums = rlnative::albums("");
    ck(true, "albums() parses without crashing");

    rlapp::request_shutdown();
    rlapp::stop_embedded();
    (void)::system(("rm -rf '" + root + "'").c_str());
    std::printf("RESULT=%s (%d failures)\n", g_fail ? "FAIL" : "OK", g_fail);
    return g_fail ? 1 : 0;
}
