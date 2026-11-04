// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_dsd_production.cpp — 1.1.2 DSD P0-1 / P0-2 生产函数级回归与端到端断言
#include <cstdio>
#include <cassert>
#include <cmath>
#include <string>
#include <vector>
#include <filesystem>
#include <fstream>
#include <random>

#define RLPLAYER_EMBEDDED_LIBRARY 1
#include "rtaweb.cpp"

static int g_fail = 0;
static void ck(bool cond, const std::string& name, const std::string& detail = "") {
    if (cond) {
        std::printf("  [PASS] %s\n", name.c_str());
    } else {
        std::printf("  [FAIL] %s (%s)\n", name.c_str(), detail.c_str());
        g_fail++;
    }
}

// 辅助函数：构造 DSF 文件
static std::string create_dummy_dsf(const std::string& path, uint32_t sampleRate, int channels, size_t bitsPerCh, uint8_t fillByte = 0x55) {
    std::filesystem::create_directories(std::filesystem::path(path).parent_path());
    rta::audio::DsdStream s;
    s.rate = sampleRate;
    s.channels = channels;
    s.bits = bitsPerCh;
    s.container = "dsf";
    const size_t bytesPerCh = (bitsPerCh + 7) / 8;
    s.data.assign((size_t)channels, std::vector<uint8_t>(bytesPerCh, fillByte));
    rta::audio::write_dsf(path, s);
    return path;
}

int main() {
    std::printf("=== test_dsd_production: DSD P0-1 / P0-2 生产级回归测试 ===\n");

    const std::string tmpDir = "/tmp/rlplayer-test-dsd-prod";
    std::filesystem::create_directories(tmpDir);

    // 44.1k 族素材：DSD64 (2822400) 与 DSD128 (5644800)
    const std::string dsf44_64 = tmpDir + "/test_44_dsd64.dsf";
    const std::string dsf44_128 = tmpDir + "/test_44_dsd128.dsf";
    create_dummy_dsf(dsf44_64, 2822400, 2, 2822400);   // 1s DSD64
    create_dummy_dsf(dsf44_128, 5644800, 2, 5644800);  // 1s DSD128

    // 48k 族素材：DSD64 (3072000) 与 DSD128 (6144000)
    const std::string dsf48_64 = tmpDir + "/test_48_dsd64.dsf";
    const std::string dsf48_128 = tmpDir + "/test_48_dsd128.dsf";
    create_dummy_dsf(dsf48_64, 3072000, 2, 3072000);   // 1s DSD64@48k
    create_dummy_dsf(dsf48_128, 6144000, 2, 6144000);  // 1s DSD128@48k

    // 尾部非 16 整数倍素材：1s + 11 bits
    const std::string dsf_odd = tmpDir + "/test_odd_bits.dsf";
    create_dummy_dsf(dsf_odd, 2822400, 2, 2822400 + 11);

    const DsdInfo info44_64 = probe_dsd(dsf44_64);
    const DsdInfo info44_128 = probe_dsd(dsf44_128);
    const DsdInfo info48_64 = probe_dsd(dsf48_64);
    const DsdInfo info48_128 = probe_dsd(dsf48_128);
    const DsdInfo info_odd = probe_dsd(dsf_odd);

    // =========================================================================
    // 1. P0-2 严格直通资格判定：全面覆盖所有处理通道与音量
    // =========================================================================
    std::printf("\n--- 1. P0-2 严格直通资格覆盖测试 ---\n");
    {
        std::string why;

        // 1.1 EQ 文件
        PlayParams p1; p1.dsd = 128; p1.eqFile = "/dummy/eq.txt";
        ck(!direct_sdm_eligible(p1, info44_64, why), "EQ 文件存在时拒绝直通/变速");

        // 1.2 卷积 IR
        PlayParams p2; p2.dsd = 128; p2.convIr = "/dummy/ir.wav";
        ck(!direct_sdm_eligible(p2, info44_64, why), "卷积 IR 存在时拒绝直通/变速");

        // 1.3 响度
        PlayParams p3; p3.dsd = 128; p3.loudness = true;
        ck(!direct_sdm_eligible(p3, info44_64, why), "响度开启时拒绝直通/变速");

        // 1.4 ReplayGain
        PlayParams p4; p4.dsd = 128; p4.rgMode = "track";
        ck(!direct_sdm_eligible(p4, info44_64, why), "ReplayGain 开启时拒绝直通/变速");

        // 1.5 声道 Trim
        PlayParams p5; p5.dsd = 128; p5.trim[0] = -1.5;
        ck(!direct_sdm_eligible(p5, info44_64, why), "声道微调 Trim 存在时拒绝直通/变速");

        // 1.6 声道数映射变化
        PlayParams p6; p6.dsd = 128; p6.outChannels = 4;
        ck(!direct_sdm_eligible(p6, info44_64, why), "声道数映射变化时拒绝直通/变速");

        // 1.7 音量非 0 dB
        PlayParams p7; p7.dsd = 128; p7.volume = -0.5;
        ck(!direct_sdm_eligible(p7, info44_64, why), "音量非 0dB 时拒绝直通/变速");

        // 1.8 PEQ 生效检测 (g_peq has_effect)
        if (!g_peq) peq_load_current();
        rta::dsp::PeqSettings peqS = rta::dsp::peq_flat_settings();
        peqS.bypass = false;
        peqS.bands[0].gainDb = 2.0; // 提升 2dB
        g_peq->set_settings(peqS);
        PlayParams p8; p8.dsd = 64; // 同速
        ck(!direct_sdm_eligible(p8, info44_64, why), "PEQ 有增益激活时拒绝直通");

        // 恢复 PEQ bypass
        peqS.bypass = true;
        g_peq->set_settings(peqS);
        ck(direct_sdm_eligible(p8, info44_64, why), "PEQ bypass 后同速直通恢复合格");
    }

    // =========================================================================
    // 2. 无处理同速直通：Pack / Unpack 逐位一致性验证
    // =========================================================================
    std::printf("\n--- 2. 同速直通 DoP 打包/解包逐位一致性测试 ---\n");
    {
        // 构造一个具有特定 bit 模式的 1-bit 流
        const size_t testFrames = 1000; // 1000 个 16-bit DoP 帧 = 16000 bits
        rta::audio::DsdStream s;
        s.rate = 2822400;
        s.channels = 2;
        s.bits = testFrames * 16;
        s.data.resize(2);
        std::mt19937 rng(42);
        for (int c = 0; c < 2; ++c) {
            s.data[c].resize(testFrames * 2);
            for (size_t b = 0; b < testFrames * 2; ++b) s.data[c][b] = (uint8_t)(rng() & 0xFF);
        }

        std::vector<int32_t> packed;
        rta::dsp::DopPackState packSt;
        size_t groups = rta::dsp::dsd_to_dop(s, packed, packSt);
        ck(groups == testFrames, "打包帧数等于预期");

        std::vector<std::vector<double>> unpacked;
        bool unpackOk = rta::dsp::dop_unpack(packed.data(), 2, groups, unpacked);
        ck(unpackOk, "DoP 解包成功，标记合法");

        bool bitMatch = true;
        for (int c = 0; c < 2; ++c) {
            for (size_t n = 0; n < groups; ++n) {
                const uint16_t orig16 = ((uint16_t)s.data[c][n * 2] << 8) | (uint16_t)s.data[c][n * 2 + 1];
                for (int b = 0; b < 16; ++b) {
                    const double bitVal = ((orig16 >> (15 - b)) & 1u) ? 1.0 : -1.0;
                    if (unpacked[c][n * 16 + b] != bitVal) {
                        bitMatch = false;
                        break;
                    }
                }
            }
        }
        ck(bitMatch, "同速直通 DoP pack/unpack 逐位逐样本完全一致");
    }

    // =========================================================================
    // 3. 44.1k 族与 48k 族：升速与降速两族生产路径测试 (P0-1 & P0-2)
    // =========================================================================
    std::printf("\n--- 3. P0-1 两族升降速生产调用与参数一致性 ---\n");
    {
        // 3.1 44.1k 族升速：DSD64 (2.8224MHz) -> DSD128 (5.6448MHz, carrier=352800)
        {
            PlayParams p;
            p.file = dsf44_64;
            p.dsd = 128;
            p.backend = "null";
            p.directSdm = true;
            p.cueStart = 0.1;
            p.cueEnd = 0.9; // 0.8s 区间: 352800 * 0.8 = 282240 帧

            bool ok = play_one_direct(dsf44_64, p);
            ck(ok, "44.1k 族升速 play_one_direct 成功");
            ck(g_ps.outRate == 352800, "44.1k 升速 carrier 更新为 352800 Hz", std::to_string(g_ps.outRate));
            ck(g_ps.total.load() == 282240, "44.1k 升速 CUE 总帧数基于新速率计算为 282240", std::to_string(g_ps.total.load()));
            ck(g_ps.bpState == "no", "44.1k 升速 bitPerfectState 为 no");
            ck(g_ps.signal.find("\"directSdm\":false") != std::string::npos, "44.1k 升速 signal 中 directSdm=false");
            ck(g_ps.signal.find("\"phaseCode\":\"convert\"") != std::string::npos, "44.1k 升速 phaseCode 为 convert");
            ck(g_ps.signal.find("\"inRate\":2822400") != std::string::npos, "44.1k 升速 signal inRate 保留源位率 2822400");
            ck(g_ps.signal.find("\"outRate\":5644800") != std::string::npos, "44.1k 升速 signal outRate 标记为 5644800");
        }

        // 3.2 44.1k 族降速：DSD128 (5.6448MHz) -> DSD64 (2.8224MHz, carrier=176400)
        {
            PlayParams p;
            p.file = dsf44_128;
            p.dsd = 64;
            p.backend = "null";
            p.directSdm = true;
            p.cueStart = 0.2;
            p.cueEnd = 0.7; // 0.5s 区间: 176400 * 0.5 = 88200 帧

            bool ok = play_one_direct(dsf44_128, p);
            ck(ok, "44.1k 族降速 play_one_direct 成功");
            ck(g_ps.outRate == 176400, "44.1k 降速 carrier 更新为 176400 Hz", std::to_string(g_ps.outRate));
            ck(g_ps.total.load() == 88200, "44.1k 降速 CUE 总帧数计算为 88200", std::to_string(g_ps.total.load()));
            ck(g_ps.bpState == "no", "44.1k 降速 bitPerfectState 为 no");
            ck(g_ps.signal.find("\"inRate\":5644800") != std::string::npos, "44.1k 降速 signal inRate 5644800");
            ck(g_ps.signal.find("\"outRate\":2822400") != std::string::npos, "44.1k 降速 signal outRate 2822400");
        }

        // 3.3 48k 族升速：DSD64@48k (3.072MHz) -> DSD128@48k (6.144MHz, carrier=384000)
        {
            PlayParams p;
            p.file = dsf48_64;
            p.dsd = 128;
            p.backend = "null";
            p.directSdm = true;
            p.cueStart = -1.0; // 整轨 1s = 384000 帧

            bool ok = play_one_direct(dsf48_64, p);
            ck(ok, "48k 族升速 play_one_direct 成功");
            ck(g_ps.outRate == 384000, "48k 升速 carrier 为 384000 Hz", std::to_string(g_ps.outRate));
            ck(g_ps.total.load() == 384000, "48k 升速总帧数 384000", std::to_string(g_ps.total.load()));
            ck(g_ps.bpState == "no", "48k 升速 bitPerfectState 为 no");
        }

        // 3.4 48k 族降速：DSD128@48k (6.144MHz) -> DSD64@48k (3.072MHz, carrier=192000)
        {
            PlayParams p;
            p.file = dsf48_128;
            p.dsd = 64;
            p.backend = "null";
            p.directSdm = true;

            bool ok = play_one_direct(dsf48_128, p);
            ck(ok, "48k 族降速 play_one_direct 成功");
            ck(g_ps.outRate == 192000, "48k 降速 carrier 为 192000 Hz", std::to_string(g_ps.outRate));
            ck(g_ps.total.load() == 192000, "48k 降速总帧数 192000", std::to_string(g_ps.total.load()));
            ck(g_ps.bpState == "no", "48k 降速 bitPerfectState 为 no");
        }
    }

    // =========================================================================
    // 4. CUE 与 Seek 边界测试
    // =========================================================================
    std::printf("\n--- 4. CUE 与 Seek 边界条件测试 ---\n");
    {
        // 4.1 越界 CUE：起点越界
        PlayParams p_bad1;
        p_bad1.file = dsf44_64;
        p_bad1.dsd = 64;
        p_bad1.backend = "null";
        p_bad1.cueStart = 2.0; // 文件只有 1s
        p_bad1.cueEnd = 3.0;
        bool ok1 = play_one_direct(dsf44_64, p_bad1);
        ck(!ok1, "CUE 起点越界应拒绝播放并报错");
        ck(!g_ps.error.empty(), "CUE 错误信息已记录在 ps.error: " + g_ps.error);

        // 4.2 越界 CUE：终点小于等于起点
        PlayParams p_bad2;
        p_bad2.file = dsf44_64;
        p_bad2.dsd = 64;
        p_bad2.backend = "null";
        p_bad2.cueStart = 0.5;
        p_bad2.cueEnd = 0.3;
        bool ok2 = play_one_direct(dsf44_64, p_bad2);
        ck(!ok2, "CUE 终点小于起点应拒绝播放并报错");

        // 4.3 尾部非 16 整数倍截断
        PlayParams p_odd;
        p_odd.file = dsf_odd;
        p_odd.dsd = 64;
        p_odd.backend = "null";
        bool ok3 = play_one_direct(dsf_odd, p_odd);
        ck(ok3, "尾部非 16 整数倍正常播放", g_ps.error);
        // 2822400 + 11 位，DoP 帧必须为 2822400 / 16 = 176400 帧（余数 11 位丢弃）
        ck(g_ps.total.load() == 176400, "尾部 11 bits 被安全舍弃，total 为 176400 帧", std::to_string(g_ps.total.load()));
    }

    std::printf("\n=== test_dsd_production 结束: FAIL=%d ===\n", g_fail);
    return g_fail == 0 ? 0 : 1;
}
