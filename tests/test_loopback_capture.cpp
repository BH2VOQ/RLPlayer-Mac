// test_loopback_capture.cpp — 系统混音回环（Process Tap）接进输入采集层的门禁
//
// 覆盖（对应任务书的 6 条判据）：
//   1) rl_loopback_supported() 在本机返回 1；返回 0 时打 [SKIP] 并 return 0
//      （低版本 macOS 上没有该 API 是合法的，不是失败）
//   2) enumerate_capture(false) 不含任何 isLoopback==true 的条目 —— 关掉回环时零回归
//   3) enumerate_capture(true) 含【且仅含一条】id=="__system_loopback__" 的 isLoopback 条目，
//      且 name 非空、排在物理设备之前、字段（rate/channels/bits）符合契约
//   4) enumerate_capture(true) 里物理设备的 isLoopback 全为 false
//   5) open() 一个不存在的 deviceId 必须失败且 last_error() 非空（错误路径不许假装成功）
//   6) 【可选，默认关闭】RTA_LOOPBACK_TESTS=1 时才真开回环：open → 采 0.3 秒 →
//      断言 rate()>0 && channels()>0（不校验有没有声音：本机可能静音）→ close，
//      并断言聚合设备已从系统设备表消失（tap/聚合设备泄漏会留下幽灵设备）
//
// 🔴 铁律 1（绝不向用户听音设备播可听声音）：
//   本测试默认【完全不碰物理设备】，只做只读枚举 + 一次注定失败的 open。
//   真开设备的唯一路径是回环聚合设备，而且被 RTA_LOOPBACK_TESTS=1 显式门控。
//   回环 tap 用 CATapUnmuted，抓录时不改变用户正在听的声音；测试本身不播放任何声音。
//
// 🔴 铁律 3（测试通过 ≠ 测对了东西）：
//   判据不是"没崩"，而是：
//     * (true) 与 (false) 的条目数差【恰好 1】，且多出来的那条 id/isLoopback 都对
//       —— 只断言"含回环"会漏掉"顺手把物理设备也标成回环"这类错
//     * 物理设备条目逐条断言 isLoopback==false
//     * 失败路径断言 last_error() 非空 —— 空错误信息等于没告诉用户为什么失败
//     * 可选真开路径额外断言 close() 后聚合设备从设备表消失（泄漏是真实故障，不是形式主义）
//
// ⚠️ 未解决项（铁律 4）：
//   1) 默认路径【不】证明回环能抓到真实声音内容。抓到的数据是否正确由
//      tools/rtaloop record-tap + compare 负责（那边已在真机验证过 tap 抓录链路）；
//      本测试只证明"枚举/打开/格式/清理"这条接线正确。
//   2) RTA_LOOPBACK_TESTS=1 的真开回环需要系统录音权限（TCC）。未授权时
//      rl_loopback_create 会失败并给出中文原因，此时该子项按 FAIL 处理（不是 SKIP）——
//      因为"支持 Process Tap 但建不出来"是真问题，不该被静默吞掉。
//   3) Process Tap 与独占输出（Hog Mode）互斥；本测试不涉及独占，未验证该交互。
#include "platform/macos/audio_in_coreaudio.h"

#include <CoreAudio/CoreAudio.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

using namespace rta::platform;

static int g_failed = 0;
static int g_total = 0;

static void check(bool ok, const std::string& what, const std::string& detail = "") {
    ++g_total;
    if (!ok) ++g_failed;
    std::printf("  [%s] %s%s%s\n", ok ? "PASS" : "FAIL", what.c_str(),
                detail.empty() ? "" : "  ", detail.c_str());
    std::fflush(stdout);
}

static std::string env_str(const char* k) {
    const char* v = std::getenv(k);
    return v ? std::string(v) : std::string();
}

// 系统当前全部 AudioDeviceID（只读查询；用于验证聚合设备真的建出来 / 真的销毁了）
static std::vector<AudioObjectID> all_device_ids() {
    std::vector<AudioObjectID> out;
    AudioObjectPropertyAddress a{kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
                                 kAudioObjectPropertyElementMain};
    UInt32 sz = 0;
    if (::AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, nullptr, &sz) != noErr || !sz)
        return out;
    out.resize(sz / sizeof(AudioObjectID));
    if (::AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &sz, out.data()) != noErr)
        out.clear();
    return out;
}

static bool device_id_present(AudioObjectID id) {
    for (AudioObjectID d : all_device_ids())
        if (d == id) return true;
    return false;
}

// 等聚合设备从设备表消失（销毁是异步的，给 1.5 秒；超时 = 真泄漏）
static bool wait_device_gone(AudioObjectID id, int timeoutMs) {
    for (int w = 0; w <= timeoutMs; w += 50) {
        if (!device_id_present(id)) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    return !device_id_present(id);
}

int main() {
    std::printf("=== test_loopback_capture（系统混音回环接线门禁）===\n");
    std::printf("  只读枚举 + 一次注定失败的 open；默认不打开任何音频设备\n\n");

    // ---- 判据 1：本机是否支持 Process Tap -------------------------------------
    std::printf("[1] rl_loopback_supported()\n");
    const int sup = ::rl_loopback_supported();
    check(sup == 0 || sup == 1, "返回值只有 0/1", "got=" + std::to_string(sup));
    if (sup != 1) {
        std::printf("  [SKIP] 本机不支持 Process Tap（macOS < 14.2 或 CoreAudio 符号缺失）\n");
        std::printf("  [SKIP] 低版本 macOS 上没有该 API 是合法的，本测试按跳过处理\n");
        std::printf("\n=== 结果：SKIP（%d 项检查已跑，%d 失败）===\n", g_total, g_failed);
        return g_failed == 0 ? 0 : 1;
    }
    std::printf("  → 支持 Process Tap（macOS >= 14.2 且符号可解析）\n\n");

    // ---- 判据 2：includeLoopback=false 不含回环 ---------------------------------
    std::printf("[2] enumerate_capture(false) 不含回环条目（零回归）\n");
    const auto noLb = CoreAudioInput::enumerate_capture(false);
    size_t lbInNoLb = 0;
    for (const auto& d : noLb) if (d.isLoopback) ++lbInNoLb;
    check(lbInNoLb == 0, "没有任何 isLoopback==true 的条目",
          "count=" + std::to_string(lbInNoLb) + " / 总条目 " + std::to_string(noLb.size()));
    bool hasLoopbackIdWhenOff = false;
    for (const auto& d : noLb)
        if (d.id == kLoopbackDeviceId) hasLoopbackIdWhenOff = true;
    check(!hasLoopbackIdWhenOff, "也不含 __system_loopback__ 这条 id");
    std::printf("  → 物理输入设备 %zu 条\n\n", noLb.size());

    // ---- 判据 3：includeLoopback=true 恰好一条回环，且排在最前 ------------------
    std::printf("[3] enumerate_capture(true) 含且仅含一条回环条目\n");
    const auto withLb = CoreAudioInput::enumerate_capture(true);
    std::vector<const MacCaptureInfo*> lbs;
    for (const auto& d : withLb) if (d.isLoopback) lbs.push_back(&d);
    check(lbs.size() == 1, "isLoopback==true 的条目恰好 1 条",
          "count=" + std::to_string(lbs.size()));
    size_t idMatches = 0;
    for (const auto& d : withLb) if (d.id == kLoopbackDeviceId) ++idMatches;
    check(idMatches == 1, "id==__system_loopback__ 的条目恰好 1 条",
          "count=" + std::to_string(idMatches));
    if (!lbs.empty()) {
        const MacCaptureInfo& lb = *lbs.front();
        check(lb.id == kLoopbackDeviceId, "该条目的 id 就是 kLoopbackDeviceId", "id=" + lb.id);
        check(!lb.name.empty(), "name 非空", "name=" + lb.name);
        check(!lb.isDefault, "isDefault==false（回环不是默认输入设备）");
        check(lb.mixRate == 48000, "mixRate==48000（open 时按聚合设备真实格式填）",
              "got=" + std::to_string(lb.mixRate));
        check(lb.mixChannels == 2, "mixChannels==2", "got=" + std::to_string(lb.mixChannels));
        check(lb.mixBits == 32, "mixBits==32", "got=" + std::to_string(lb.mixBits));
        check(!withLb.empty() && withLb.front().isLoopback,
              "排在第 0 位（物理输入设备之前）");
    }
    // 条目数只多 1：证明没有顺手把物理设备也复制成回环
    check(withLb.size() == noLb.size() + 1, "条目数 = 关闭时 + 1",
          std::to_string(noLb.size()) + " + 1 vs " + std::to_string(withLb.size()));
    std::printf("\n");

    // ---- 判据 4：物理设备的 isLoopback 全为 false -------------------------------
    std::printf("[4] enumerate_capture(true) 里物理设备的 isLoopback 全为 false\n");
    size_t physicalLb = 0, physical = 0;
    for (const auto& d : withLb) {
        if (d.id == kLoopbackDeviceId) continue;   // 唯一允许为 true 的那条
        ++physical;
        if (d.isLoopback) ++physicalLb;
    }
    check(physicalLb == 0, "物理设备 isLoopback 全 false",
          "true 的条数=" + std::to_string(physicalLb) + " / 物理设备 " + std::to_string(physical));
    // 物理设备 id 必须是十进制 AudioDeviceID（不能被伪设备污染成字符串）
    bool idsNumeric = true;
    for (const auto& d : withLb) {
        if (d.id == kLoopbackDeviceId) continue;
        if (d.id.empty() || d.id.find_first_not_of("0123456789") != std::string::npos) idsNumeric = false;
    }
    check(idsNumeric, "物理设备 id 全是十进制数字");
    std::printf("\n");

    // ---- 判据 5：不存在的 deviceId 必须失败且给出原因 ---------------------------
    std::printf("[5] open() 不存在的 deviceId 必须失败 + last_error() 非空\n");
    {
        CoreAudioInput in;
        MacCaptureConfig cfg;
        cfg.deviceId = "__no_such_device_6f3a9c__";
        cfg.bufferMs = 50.0;
        const bool ok = in.open(cfg);
        check(!ok, "open 返回 false（不许假装成功）");
        check(!in.last_error().empty(), "last_error() 非空", "err=" + in.last_error());
        check(!in.is_loopback(), "失败后 is_loopback()==false");
        check(in.loopback_agg_device_id() == 0, "失败后没有残留聚合设备 id");
        check(!in.is_running(), "失败后 is_running()==false");
        in.close();
        check(!in.is_running(), "close() 后 is_running()==false（幂等）");
    }
    // 空 deviceId 是"默认输入设备"的合法语义，不能因为它不存在就报错；
    // 这里只验证它不会误判成回环（本机可能没有输入设备，故不断言成功）
    {
        CoreAudioInput in;
        MacCaptureConfig cfg;
        cfg.deviceId = "";
        cfg.bufferMs = 50.0;
        (void)in.open(cfg);
        check(!in.is_loopback(), "空 deviceId 不会走进回环分支");
        in.close();
    }
    std::printf("\n");

    // ---- 判据 6（可选）：真开回环 ----------------------------------------------
    const std::string wantReal = env_str("RTA_LOOPBACK_TESTS");
    const bool realEnabled = wantReal == "1";
    std::printf("[6] 真开回环（%s）\n", realEnabled ? "RTA_LOOPBACK_TESTS=1 → 执行"
                                                    : "默认跳过，设 RTA_LOOPBACK_TESTS=1 才跑");
    if (!realEnabled) {
        std::printf("  [SKIP] 未设 RTA_LOOPBACK_TESTS=1；默认不打开任何设备\n");
        std::printf("          （真开回环需要系统录音权限，且会短暂创建一个 private 聚合设备）\n");
    } else {
        CoreAudioInput in;
        MacCaptureConfig cfg;
        cfg.deviceId = kLoopbackDeviceId;
        cfg.bufferMs = 200.0;
        std::printf("  ┌──────────────────────────────────────────────────────────┐\n");
        std::printf("  │ 打开【系统混音回环】聚合设备（不播放任何声音）            │\n");
        std::printf("  │ 采集 0.3 秒；CATapUnmuted → 用户正在听的声音不受影响      │\n");
        std::printf("  └──────────────────────────────────────────────────────────┘\n");
        AudioObjectID aggOpened = kAudioObjectUnknown;
        const bool ok = in.open(cfg);
        check(ok, "open(回环) 成功", ok ? "" : ("err=" + in.last_error()));
        if (ok) {
            check(in.is_loopback(), "is_loopback()==true");
            check(in.rate() > 0, "rate()>0", "rate=" + std::to_string(in.rate()));
            check(in.channels() > 0, "channels()>0", "channels=" + std::to_string(in.channels()));
            aggOpened = (AudioObjectID)in.loopback_agg_device_id();
            check(aggOpened != kAudioObjectUnknown, "聚合设备 id 有效",
                  "agg=" + std::to_string(aggOpened));
            check(device_id_present(aggOpened), "聚合设备真的出现在系统设备表里");

            check(in.start(), "start() 成功", in.last_error());
            std::vector<float> buf(4096 * 8);
            const auto t0 = std::chrono::steady_clock::now();
            size_t got = 0;
            while (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() < 0.3) {
                got += in.read_available(buf.data(), 4096);
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
            in.stop();
            // 不校验内容/电平：本机可能静音，抓到全零是合法结果。
            // 只报告，不作为判据（铁律 3：这个数字证明不了"回环内容正确"）。
            std::printf("  [INFO] 0.3s 内取到 %zu 帧，设备回调累计 %zu 帧，欠载 %llu 次，峰值水位 %.3f\n",
                        got, in.total_captured_frames(),
                        (unsigned long long)in.underflow_count(), in.water_level());
            check(in.total_captured_frames() > 0, "设备回调真的在拉帧（不是只开了个空设备）",
                  "frames=" + std::to_string(in.total_captured_frames()));
        }
        in.close();
        check(!in.is_running(), "close() 后停止");
        check(!in.is_loopback(), "close() 后 is_loopback()==false");
        check(in.loopback_agg_device_id() == 0, "close() 后聚合设备 id 归零（不泄漏）");
        if (aggOpened != kAudioObjectUnknown) {
            // 泄漏的聚合设备会永久留在系统设备表里（幽灵设备），这是真实故障
            check(wait_device_gone(aggOpened, 1500), "close() 后聚合设备从系统设备表消失",
                  "agg=" + std::to_string(aggOpened));
        }
        std::printf("  [INFO] 可选真开路径结束\n");
    }
    std::printf("\n");

    std::printf("=== 结果：%s（%d 项检查，%d 失败）===\n",
                g_failed == 0 ? "PASS" : "FAIL", g_total, g_failed);
    return g_failed == 0 ? 0 : 1;
}
