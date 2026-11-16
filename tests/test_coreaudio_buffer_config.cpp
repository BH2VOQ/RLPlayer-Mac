// SPDX-License-Identifier: GPL-3.0-or-later
// Device-free production configuration contract; never constructs a hardware stream.
#include "platform/macos/output_buffer_config.h"
#include <cstdio>
#include <chrono>
#include <thread>
#include "platform/audio_out.h"
#include "platform/macos/audio_out_coreaudio.h"
namespace rta::platform {
struct CoreAudioOutputOfflineAccess {
    static void prepare(CoreAudioOutput& out) {
        out.opened_ = true; out.channels_ = 2; out.bits_ = 16; out.clientBits_ = 16;
        out.ring_frames_ = 129; out.ring_.assign(258, 0);
    }
    static bool consume(CoreAudioOutput& out, int16_t wanted, UInt32 requested = 1) {
        int16_t samples[2] = {};
        AudioBufferList io{}; io.mNumberBuffers = 1;
        io.mBuffers[0] = {2, sizeof(samples), samples};
        CoreAudioOutput::render_trampoline(&out, nullptr, nullptr, 0, requested, &io);
        return samples[0] == wanted && samples[1] == -wanted;
    }
};
}
using namespace rta::platform::macos;
struct MockApi {
    UInt32 actual = 4096, maximum = 512, requested = 0;
    int sets = 0; bool wrongApi = false, readFails = false, sliceFails = false, undersized = false;
    OSStatus deviceSetStatus = noErr;
    OSStatus deviceGet(AudioDeviceID d, const AudioObjectPropertyAddress& a, UInt32&, void* p) {
        if (d != 101 || a.mScope != kAudioObjectPropertyScopeGlobal) wrongApi = true;
        if (a.mSelector == kAudioDevicePropertyBufferFrameSizeRange) {
            *static_cast<AudioValueRange*>(p) = {32,4096}; return noErr;
        }
        if (a.mSelector != kAudioDevicePropertyBufferFrameSize) wrongApi = true;
        if (readFails) return -77;
        *static_cast<UInt32*>(p) = actual; return noErr;
    }
    OSStatus deviceSet(AudioDeviceID d, const AudioObjectPropertyAddress& a, UInt32, const void* p) {
        if (d != 101 || a.mSelector != kAudioDevicePropertyBufferFrameSize) wrongApi = true;
        requested = *static_cast<const UInt32*>(p); ++sets; return deviceSetStatus;
    }
    OSStatus unitGet(AudioUnit, AudioUnitPropertyID p, UInt32&, void* v) {
        if (p != kAudioUnitProperty_MaximumFramesPerSlice) wrongApi = true;
        *static_cast<UInt32*>(v) = undersized ? 512 : maximum; return noErr;
    }
    OSStatus unitSet(AudioUnit, AudioUnitPropertyID p, UInt32, const void* v) {
        if (p != kAudioUnitProperty_MaximumFramesPerSlice) wrongApi = true;
        if (sliceFails) return -88;
        maximum = *static_cast<const UInt32*>(v); return noErr;
    }
};
int main() {
    int failed=0;
    auto check=[&](bool ok,const char* name){std::printf("[%s] %s\n",ok?"PASS":"FAIL",name); if(!ok)++failed;};
    MockApi api;
    auto result=configure_output_buffers(101,nullptr,4410,true,api);
    check(result.status==noErr && result.frames==4096 && result.maximumSlice>=8192,"4096-frame period gets sufficient AUHAL slice budget");
    check(!api.wrongApi && api.requested==4096 && api.sets==1,"period uses device API and supported range; unit receives only slice property");
    MockApi shared; shared.actual=256;
    auto sharedResult=configure_output_buffers(101,nullptr,4410,false,shared);
    check(sharedResult.status==noErr && sharedResult.frames==256 && shared.sets==0,"shared mode reads actual period without changing hardware");
    MockApi readOnly; readOnly.actual=1024; readOnly.deviceSetStatus=-1;
    auto readOnlyResult=configure_output_buffers(101,nullptr,4410,true,readOnly);
    check(readOnlyResult.status==noErr && readOnlyResult.frames==1024 && readOnlyResult.deviceSetStatus==-1,"rejected period request uses actual readback instead of guessed request");
    MockApi readError; readError.readFails=true;
    check(configure_output_buffers(101,nullptr,4410,false,readError).status==-77,"readback failure is not presented as a configured stream");
    MockApi sliceError; sliceError.sliceFails=true;
    check(configure_output_buffers(101,nullptr,4410,false,sliceError).status==-88,"slice configuration failure propagates before initialization");
    MockApi under; under.undersized=true;
    check(configure_output_buffers(101,nullptr,4410,false,under).status!=noErr,"insufficient slice readback is rejected");
    MockApi larger; larger.maximum=16384;
    check(configure_output_buffers(101,nullptr,4410,false,larger).maximumSlice==16384,"existing larger slice budget is preserved");
    {
        rta::platform::CoreAudioOutput output;
        rta::platform::CoreAudioOutputOfflineAccess::prepare(output);
        constexpr int count = 10000;
        std::atomic<bool> bad{false};
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        std::thread producer([&] {
            for (int i = 0; i < count && !bad.load(); ++i) {
                int32_t sample[2] = {i % 1000 + 1, -(i % 1000 + 1)};
                while (!output.write(sample, 1)) {
                    if (std::chrono::steady_clock::now() >= deadline || bad.load()) { bad.store(true); return; }
                    std::this_thread::yield();
                }
            }
        });
        for (int i = 0; i < count && !bad.load(); ++i) {
            while (output.queued_frames() == 0) {
                if (std::chrono::steady_clock::now() >= deadline || bad.load()) { bad.store(true); break; }
                std::this_thread::yield();
            }
            if (!bad.load() && !rta::platform::CoreAudioOutputOfflineAccess::consume(output, i % 1000 + 1)) bad.store(true);
        }
        producer.join();
        check(!bad.load() && output.frames_written() == count && output.frames_rendered() == count && output.render_callbacks() == count,
              "concurrent production write/render preserves 10000 stereo frames without a device");
    }
    {
        rta::platform::CoreAudioOutput bounded;
        rta::platform::CoreAudioOutputOfflineAccess::prepare(bounded);
        const int32_t samples[] = {1,-1,2,-2,3,-3,4,-4};
        bounded.write(samples, 4);
        check(rta::platform::CoreAudioOutputOfflineAccess::consume(bounded, 1, 4) && bounded.queued_frames() == 3,
              "short callback buffer consumes only the frame actually written");
    }
    return failed?1:0;
}
