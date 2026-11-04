// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_airplay_policy.cpp — 1.1.2 AirPlay 平台策略与能力核查离线测试
//
// 验证内容：
//   1. CoreAudio kAudioDeviceTransportTypeAirPlay ('airp') 识别及 FourCC 转换
//   2. DeviceCaps 新增 transport/transportType/sharedOnly/latency/current* 契约字段
//   3. sanitize_airplay_caps 纯函数正确重置 AirPlay 设备的独占、bit-perfect、DSD 与 DoP
//   4. validate_open_spec 拦截 AirPlay 或 shared 模式下的 DoP 开流，严禁写硬件前通过
//   5. validate_open_spec 对 AirPlay 强制 shared=true、拒绝 Hog 独占
//   6. 延迟计算函数保留可读来源，当信息不足时不虚报、不写死 2.0s
//   7. endpoint_alive 生命周期查询辅助函数与状态语义
#include "platform/audio_out.h"
#include "platform/macos/airplay_policy.h"
#include "platform/macos/audio_out_coreaudio.h"

#include <cstdio>
#include <string>
#include <vector>

using namespace rta::platform;
using namespace rta::platform::macos;

static int g_failed = 0;
static int g_total = 0;

static void check(bool cond, const char* what, const std::string& extra = "") {
    ++g_total;
    if (!cond) {
        ++g_failed;
        std::printf("  [FAIL] %s %s\n", what, extra.c_str());
    } else {
        std::printf("  [PASS] %s\n", what);
    }
}

static void test_transport_type_mapping() {
    std::printf("\n-- test_transport_type_mapping --\n");
    check(is_airplay_transport(kTransportAirPlay), "is_airplay_transport for 'airp'");
    check(!is_airplay_transport(kTransportUsb), "not airplay for 'usb '");
    check(!is_airplay_transport(kTransportBuiltIn), "not airplay for 'bltn'");
    check(!is_airplay_transport(0), "not airplay for 0");

    check(transport_type_to_string(kTransportAirPlay) == "airplay", "FourCC 'airp' -> airplay");
    check(transport_type_to_string(kTransportUsb) == "usb", "FourCC 'usb ' -> usb");
    check(transport_type_to_string(kTransportBuiltIn) == "builtin", "FourCC 'bltn' -> builtin");
    check(transport_type_to_string(kTransportBluetooth) == "bluetooth", "FourCC 'blue' -> bluetooth");
    check(transport_type_to_string(kTransportBluetoothLE) == "bluetooth", "FourCC 'blea' -> bluetooth");
    check(transport_type_to_string(kTransportAggregate) == "aggregate", "FourCC 'grup' -> aggregate");
    check(transport_type_to_string(kTransportVirtual) == "virtual", "FourCC 'virt' -> virtual");
    check(transport_type_to_string(kTransportPCI) == "pci", "FourCC 'pci ' -> pci");
    check(transport_type_to_string(kTransportHDMI) == "hdmi", "FourCC 'hdmi' -> hdmi");
    check(transport_type_to_string(kTransportDisplayPort) == "displayport", "FourCC 'dprt' -> displayport");
    check(transport_type_to_string(kTransportThunderbolt) == "thunderbolt", "FourCC 'thun' -> thunderbolt");
    check(transport_type_to_string(0x12345678) == "unknown", "Unknown FourCC -> unknown");
    check(transport_type_to_string(0) == "unknown", "Zero FourCC -> unknown");
}

static void test_airplay_caps_sanitization() {
    std::printf("\n-- test_airplay_caps_sanitization --\n");
    DeviceCaps c;
    c.transportType = kTransportAirPlay;
    c.rates = {44100, 48000};
    c.bitDepths = {16, 24};
    c.maxChannels = 2;
    // 假设原始探测或驱动给出了不切实际的独占或 DoP 声明
    c.exclusiveMode = true;
    c.bitPerfectCapable = true;
    c.dsd = DsdTransport::DoP;
    c.dopCarrierRate = 176400;
    c.nativeDsdRate = 2822400;

    sanitize_airplay_caps(c);

    check(c.transport == "airplay", "transport string set to airplay");
    check(c.sharedOnly == true, "sharedOnly must be true for AirPlay");
    check(c.exclusiveMode == false, "exclusiveMode must be false for AirPlay");
    check(c.bitPerfectCapable == false, "bitPerfectCapable must be false for AirPlay");
    check(c.dsd == DsdTransport::None, "dsd transport must be None for AirPlay");
    check(c.dopCarrierRate == 0, "dopCarrierRate must be 0 for AirPlay");
    check(c.nativeDsdRate == 0, "nativeDsdRate must be 0 for AirPlay");
}

static void test_non_airplay_caps_untouched() {
    std::printf("\n-- test_non_airplay_caps_untouched --\n");
    DeviceCaps c;
    c.transportType = kTransportUsb;
    c.rates = {44100, 96000, 192000};
    c.bitDepths = {16, 24, 32};
    c.maxChannels = 2;
    c.exclusiveMode = true;
    c.bitPerfectCapable = true;
    c.dsd = DsdTransport::DoP;
    c.dopCarrierRate = 176400;

    sanitize_airplay_caps(c);

    check(c.transport == "usb", "transport string set to usb");
    check(c.sharedOnly == false, "sharedOnly stays false for USB");
    check(c.exclusiveMode == true, "exclusiveMode preserved for USB");
    check(c.bitPerfectCapable == true, "bitPerfectCapable preserved for USB");
    check(c.dsd == DsdTransport::DoP, "dsd preserved for USB");
    check(c.dopCarrierRate == 176400, "dopCarrierRate preserved for USB");
}

static void test_validate_open_spec() {
    std::printf("\n-- test_validate_open_spec --\n");
    DeviceCaps airplayCaps;
    airplayCaps.transportType = kTransportAirPlay;
    airplayCaps.rates = {44100};
    airplayCaps.bitDepths = {16};
    airplayCaps.maxChannels = 2;
    airplayCaps.currentRate = 44100;
    airplayCaps.currentChannels = 2;
    sanitize_airplay_caps(airplayCaps);

    std::string errZh, errEn;

    // Case 1: AirPlay + DoP 请求 -> 必须拦截
    {
        OpenSpec spec;
        spec.rate = 44100;
        spec.bits = 16;
        spec.channels = 2;
        spec.shared = true;
        spec.dop = true;

        bool ok = validate_open_spec(airplayCaps, spec, errZh, errEn);
        check(!ok, "AirPlay + DoP must be rejected");
        check(errZh.find("DoP") != std::string::npos, "Error mentions DoP");
    }

    // Case 2: 普通 USB 设备在 shared 模式下 + DoP 请求 -> 必须拦截
    {
        DeviceCaps usbCaps;
        usbCaps.transportType = kTransportUsb;
        usbCaps.rates = {44100, 176400};
        usbCaps.bitDepths = {16, 24};
        usbCaps.maxChannels = 2;
        usbCaps.exclusiveMode = true;
        sanitize_airplay_caps(usbCaps);

        OpenSpec spec;
        spec.rate = 176400;
        spec.bits = 24;
        spec.channels = 2;
        spec.shared = true; // shared mode
        spec.dop = true;

        bool ok = validate_open_spec(usbCaps, spec, errZh, errEn);
        check(!ok, "Shared mode + DoP must be rejected");
        check(errZh.find("DoP") != std::string::npos, "Error explains DoP rejection in shared mode");
    }

    // Case 3: AirPlay 请求 exclusive=true -> 策略强制修正或校验拒绝
    {
        OpenSpec spec;
        spec.rate = 44100;
        spec.bits = 16;
        spec.channels = 2;
        spec.shared = false;
        spec.exclusive = true; // request Hog
        spec.dop = false;

        bool ok = validate_open_spec(airplayCaps, spec, errZh, errEn);
        check(!ok, "AirPlay requesting exclusive/Hog must be rejected");
        check(errZh.find("独占") != std::string::npos || errZh.find("AirPlay") != std::string::npos,
              "Error mentions exclusive or AirPlay constraint");
    }

    // Case 4: AirPlay 正常 PCM 请求 -> 接受
    {
        OpenSpec spec;
        spec.rate = 44100;
        spec.bits = 16;
        spec.channels = 2;
        spec.shared = true;
        spec.exclusive = false;
        spec.dop = false;

        bool ok = validate_open_spec(airplayCaps, spec, errZh, errEn);
        check(ok, "AirPlay normal PCM request accepted", errZh);
    }

    // Case 5: 格式未协商匹配：AirPlay 当前为 44100Hz，若请求 96000Hz 且未重采样 -> 平台拒绝
    {
        OpenSpec spec;
        spec.rate = 96000;
        spec.bits = 16;
        spec.channels = 2;
        spec.shared = true;
        spec.exclusive = false;
        spec.dop = false;

        bool ok = validate_open_spec(airplayCaps, spec, errZh, errEn);
        check(!ok, "AirPlay rate mismatch without resampling must be rejected");
    }
}

static void test_compute_device_latency() {
    std::printf("\n-- test_compute_device_latency --\n");
    // 正常全部可读的情况
    {
        double latMs = 0.0;
        std::string src;
        bool known = compute_device_latency(128, 64, 32, 44100.0, true, true, true, latMs, src);
        check(known, "Latency known when all components available");
        // (128 + 64 + 32) / 44100.0 * 1000 = 224 / 44.1 = ~5.079 ms
        check(latMs > 5.0 && latMs < 5.1, "Calculated latency correct (~5.08 ms)");
        check(src.find("device") != std::string::npos && src.find("safety") != std::string::npos &&
              src.find("stream") != std::string::npos, "Source explicitly notes components included");
    }

    // 部分属性缺失（例如 stream latency 不可读，仅读回 device + safety）
    {
        double latMs = 0.0;
        std::string src;
        bool known = compute_device_latency(256, 128, 0, 48000.0, true, true, false, latMs, src);
        check(known, "Latency known partially");
        // (256 + 128) / 48000.0 * 1000 = 384 / 48 = 8.0 ms
        check(latMs == 8.0, "Latency exactly 8.0 ms");
        check(src.find("stream latency unavailable") != std::string::npos ||
              src.find("partial") != std::string::npos, "Source notes partial availability");
    }

    // 完全不可读情况
    {
        double latMs = 0.0;
        std::string src;
        bool known = compute_device_latency(0, 0, 0, 44100.0, false, false, false, latMs, src);
        check(!known, "Latency unknown when no properties readable");
        check(latMs == 0.0, "Latency is 0.0 when unknown (not hardcoded 2.0s)");
        check(src == "unknown", "Source is unknown");
    }
}

static void test_endpoint_alive_mock() {
    std::printf("\n-- test_endpoint_alive_mock --\n");
    // 验证逻辑策略：alive 为 1 且 output stream count > 0 才判定存活
    check(check_endpoint_alive(1, 1), "Alive when alive=1 and streams=1");
    check(check_endpoint_alive(1, 2), "Alive when alive=1 and streams=2");
    check(!check_endpoint_alive(0, 1), "Dead when alive=0");
    check(!check_endpoint_alive(1, 0), "Dead when output streams=0 (e.g. input-only or detached)");
    check(!check_endpoint_alive(0, 0), "Dead when both 0");
}

static void test_coreaudio_output_interface_wiring() {
    std::printf("\n-- test_coreaudio_output_interface_wiring --\n");
    // 验证 CoreAudioOutput 实例挂载与接口存在
    CoreAudioOutput out;
    check(!out.endpoint_alive(), "endpoint_alive returns false when not opened");

    // 设备能力读取空串（系统默认设备）
    DeviceCaps c = out.caps("");
    check(!c.transport.empty(), "caps().transport is populated", c.transport);
    check(c.transportType != 0 || c.transport == "unknown", "transportType or unknown");
    std::printf("   Default device transport: %s (0x%08x), latencyKnown: %s, latency: %.2f ms (source: %s)\n",
                c.transport.c_str(), c.transportType, c.latencyKnown ? "true" : "false",
                c.latencyMs, c.latencySource.c_str());
    if (c.transport == "airplay") {
        check(c.sharedOnly, "AirPlay default device has sharedOnly=true");
        check(!c.exclusiveMode, "AirPlay default device has exclusiveMode=false");
        check(!c.bitPerfectCapable, "AirPlay default device has bitPerfectCapable=false");
    }
}

int main() {
    std::printf("=== test_airplay_policy ===\n");
    test_transport_type_mapping();
    test_airplay_caps_sanitization();
    test_non_airplay_caps_untouched();
    test_validate_open_spec();
    test_compute_device_latency();
    test_endpoint_alive_mock();
    test_coreaudio_output_interface_wiring();

    std::printf("\nTotal: %d, Failed: %d\n", g_total, g_failed);
    return g_failed == 0 ? 0 : 1;
}
