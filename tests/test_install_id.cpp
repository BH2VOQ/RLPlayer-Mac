// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_install_id.cpp — 安装 ID（安装指纹）格式与生成的回归
//
// ===========================================================================
// 这条判据怎么证明事（铁律 3）
//
//   安装 ID 是后台唯一的"这台机器是谁"的依据（反馈 / 频率限制 / 排查都要它），
//   所以**形状必须严格**：前缀 + 32 位小写十六进制，总长 38。
//   如果 install_id_valid() 宽容（比如接受大写、接受多余字符），后台会收到形状
//   不同的 ID，同一个用户被算成两台机器；如果 install_id_new() 不是确定性的，
//   单测就没法固定向量（只能"看起来像十六进制"这种弱判据）。
//
//   因此本文件做三件事：
//     1) 固定**全等向量**：给定 entropy 的逐字节取值 → 逐字符期望输出，
//        包括 0x00..0x0f 与 0xFF 这两个最容易写错大小写/补零的边界；
//     2) 反向逐条断言**非法形态一律 false**（大写、长度 ±1、错前缀、非 hex、
//        首尾空白、双前缀、空串）—— 宽容就是漏洞；
//     3) 生成 → 校验 的闭环（1000 个不同 entropy）＋ 确定性（同输入同输出）。
//
//   ⚠️ 这里**不**断言"随机性/熵来源"：熵由宿主（libcurl/系统随机源）提供，
//      本层只做编码转换，测它就是测错了东西。
// ===========================================================================
#include "net/install_id.h"

#include <cstdio>
#include <cstring>
#include <string>

static int g_fail = 0;
static int g_pass = 0;

static void ck(bool cond, const char* what, const std::string& detail = std::string()) {
    if (cond) {
        std::printf("  [PASS] %s\n", what);
        ++g_pass;
    } else {
        std::printf("  [FAIL] %s  %s\n", what, detail.c_str());
        ++g_fail;
    }
}

static void ck_eq(const std::string& got, const std::string& want, const char* what) {
    if (got == want) {
        std::printf("  [PASS] %s\n", what);
        ++g_pass;
    } else {
        std::printf("  [FAIL] %s\n         期望: %s\n         实际: %s\n", what, want.c_str(),
                    got.c_str());
        ++g_fail;
    }
}

// 只用于失败输出可读性，不参与判定
static std::string show(const std::string& s) {
    std::string o;
    for (char ch : s) {
        const unsigned char c = (unsigned char)ch;
        if (c >= 0x20 && c < 0x7F) o += (char)c;
        else {
            char b[8];
            std::snprintf(b, sizeof b, "\\x%02X", c);
            o += b;
        }
    }
    return o + " (len=" + std::to_string(s.size()) + ")";
}

int main() {
    std::printf("== test_install_id: 安装 ID 形态 ==\n");

    // ---------------------------------------------------------------- A. 前缀常量
    std::printf("\n-- A. 前缀常量 --\n");
    {
        ck_eq(std::string(rta::feedback::kInstallIdPrefix), "rlmac-", "A1 kInstallIdPrefix == \"rlmac-\"");
        // 判据本身先对一遍：\"rlmac-\" = r,l,m,a,c,- = 6 字节。6 + 32 = 38 才成立。
        ck(std::strlen(rta::feedback::kInstallIdPrefix) == 6, "A2 前缀长度 6 字节",
           std::to_string(std::strlen(rta::feedback::kInstallIdPrefix)));
    }

    // ---------------------------------------------------------------- B. 全等向量
    std::printf("\n-- B. 固定向量（逐字节 → 逐字符）--\n");
    {
        // 0x00..0x0f：验证"必须补足两位小写 hex"
        const unsigned char e1[16] = {0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
                                      0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f};
        ck_eq(rta::feedback::install_id_new(e1), "rlmac-000102030405060708090a0b0c0d0e0f",
              "B1 0x00..0x0f → 补零 + 小写 hex");

        // 全 0xFF：验证不出现大写、不溢出
        unsigned char e2[16];
        std::memset(e2, 0xFF, sizeof e2);
        ck_eq(rta::feedback::install_id_new(e2), "rlmac-ffffffffffffffffffffffffffffffff",
              "B2 0xFF×16 → 小写 f");

        // 大写字符（A-F）绝不能出现：这是后台区分机器的主键形态
        const unsigned char e3[16] = {0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67, 0x89,
                                      0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32, 0x10};
        ck_eq(rta::feedback::install_id_new(e3), "rlmac-abcdef0123456789fedcba9876543210",
              "B3 0xAB/0xCD/0xEF → abcdef（全小写）");
    }

    // ---------------------------------------------------------------- C. 形态自检
    std::printf("\n-- C. 生成结果的形态 --\n");
    {
        const unsigned char e[16] = {0xde, 0xad, 0xbe, 0xef, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4};
        const std::string id = rta::feedback::install_id_new(e);
        ck(id.size() == 38, "C1 总长 38（6 前缀 + 32 hex）", std::to_string(id.size()));
        ck(id.compare(0, 6, "rlmac-") == 0, "C2 前缀是 rlmac-");
        bool lower_hex = true;
        for (size_t i = 7; i < id.size(); ++i) {
            const char c = id[i];
            const bool ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
            if (!ok) lower_hex = false;
        }
        ck(lower_hex, "C3 后 32 位只含 0-9a-f（无大写、无其它字符）");
        ck(rta::feedback::install_id_valid(id), "C4 install_id_valid(生成的 ID) == true");
    }

    // ---------------------------------------------------------------- D. 确定性
    std::printf("\n-- D. 确定性（同输入同输出）--\n");
    {
        const unsigned char e[16] = {9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff};
        const std::string a = rta::feedback::install_id_new(e);
        // 中间插几次别的调用，确认没有"内部计数器/全局状态"影响结果
        const unsigned char other[16] = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1};
        (void)rta::feedback::install_id_new(other);
        (void)rta::feedback::install_id_new(other);
        const std::string b = rta::feedback::install_id_new(e);
        ck_eq(a, b, "D1 同 entropy 两次调用结果逐字相同（无全局状态）");

        const unsigned char e2[16] = {9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xfe};
        ck(a != rta::feedback::install_id_new(e2), "D2 只差最后 1 字节，结果也必须不同");
    }

    // ---------------------------------------------------------------- E. 唯一性闭环
    std::printf("\n-- E. 生成 → 校验 闭环（1000 个不同 entropy）--\n");
    {
        int dup = 0, bad = 0;
        std::string seen[1000];
        for (int k = 0; k < 1000; ++k) {
            // 16 字节大端计数器：保证 1000 个 entropy **两两不同**。
            // （原先用 (k*37 + i*11)&0xFF，k 到 256 就打转，测出的"重复"是夹具周期，
            //   不是编码丢位 —— 判据错，改成计数器才证明得了"不丢位"。）
            unsigned char e[16];
            {
                int v = k;
                for (int i = 15; i >= 0; --i) { e[i] = (unsigned char)(v & 0xFF); v >>= 8; }
            }
            const std::string id = rta::feedback::install_id_new(e);
            if (!rta::feedback::install_id_valid(id)) ++bad;
            for (int j = 0; j < k; ++j)
                if (seen[j] == id) ++dup;
            seen[k] = id;
        }
        ck(bad == 0, "E1 1000 个生成的 ID 全部通过 install_id_valid", "不合格 " + std::to_string(bad));
        // 注意：entropy 序列本身有周期，出现重复说明编码丢位（不是测"随机性"）
        ck(dup == 0, "E2 编码未丢位（不同 entropy 不产生同一 ID）", "重复 " + std::to_string(dup));
    }

    // ---------------------------------------------------------------- F. 反向：必须是 false
    std::printf("\n-- F. 非法形态一律 false（宽容就是漏洞）--\n");
    {
        const std::string good = "rlmac-0123456789abcdeffedcba9876543210";
        ck(rta::feedback::install_id_valid(good), "F1 规范形态为 true");

        ck(!rta::feedback::install_id_valid(""),
           "F2 空串 false");
        ck(!rta::feedback::install_id_valid("rlmac-"), "F3 只有前缀 false");
        ck(!rta::feedback::install_id_valid("rlmac-0123456789abcdeffedcba987654321"),
           "F4 hex 只有 31 位 false（少一位）");
        ck(!rta::feedback::install_id_valid("rlmac-0123456789abcdeffedcba98765432100"),
           "F5 hex 有 33 位 false（多一位）");
        ck(!rta::feedback::install_id_valid("rlmac-0123456789ABCDEFFEDCBA9876543210"),
           "F6 大写 hex false（后台按小写主键）");
        ck(!rta::feedback::install_id_valid("RLMAC-0123456789abcdeffedcba9876543210"),
           "F7 大写前缀 false");
        ck(!rta::feedback::install_id_valid("rlmac_0123456789abcdeffedcba9876543210"),
           "F8 下划线代替连字符 false");
        ck(!rta::feedback::install_id_valid("rlmax-0123456789abcdeffedcba9876543210"),
           "F9 前缀错一个字母 false");
        ck(!rta::feedback::install_id_valid("rlmac-0123456789abcdeffedcba987654321g"),
           "F10 非 hex 字符 g false");
        ck(!rta::feedback::install_id_valid("rlmac-0123456789abcdeffedcba9876543210\n"),
           "F11 尾部换行 false（绝不 trim 后放行）");
        ck(!rta::feedback::install_id_valid(" rlmac-0123456789abcdeffedcba9876543210"),
           "F12 前导空格 false");
        ck(!rta::feedback::install_id_valid("rlmac-rlmac-0123456789abcdeffedcba98765"),
           "F13 双前缀 false");
        ck(!rta::feedback::install_id_valid("0123456789abcdeffedcba9876543210" "rlmac-"),
           "F14 前缀不在开头 false");
        ck(!rta::feedback::install_id_valid(std::string(200, 'a')), "F15 200 个 a false");
        ck(!rta::feedback::install_id_valid("rlmac-0123456789abcdeffedcba9876543210" "0"),
           "F16 规范串后面粘一个字符 false");
    }

    // ---------------------------------------------------------------- G. 防御：空指针不崩
    std::printf("\n-- G. 防御（契约未规定，但绝不允许崩）--\n");
    {
        // 契约没写 nullptr 行为；这里只要求"不崩溃且返回串仍是前缀开头"，
        // 刻意不断言具体内容（那是实现自由）。
        const std::string s = rta::feedback::install_id_new(nullptr);
        ck(s.compare(0, 6, "rlmac-") == 0, "G1 install_id_new(nullptr) 不崩且带前缀", show(s));
        ck(s.size() == 38 && rta::feedback::install_id_valid(s),
           "G2 install_id_new(nullptr) 仍返回合法形态（可校验）", show(s));
    }

    std::printf("\n== 结果: %d passed, %d failed ==\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
