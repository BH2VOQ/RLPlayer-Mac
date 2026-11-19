// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <algorithm>
#include <limits>

namespace rta::platform::macos {
struct OutputBufferApi {
    OSStatus deviceGet(AudioDeviceID d, const AudioObjectPropertyAddress& a, UInt32& n, void* v) {
        return ::AudioObjectGetPropertyData(d, &a, 0, nullptr, &n, v);
    }
    OSStatus deviceSet(AudioDeviceID d, const AudioObjectPropertyAddress& a, UInt32 n, const void* v) {
        return ::AudioObjectSetPropertyData(d, &a, 0, nullptr, n, v);
    }
    OSStatus unitGet(AudioUnit u, AudioUnitPropertyID p, UInt32& n, void* v) {
        return ::AudioUnitGetProperty(u, p, kAudioUnitScope_Global, 0, v, &n);
    }
    OSStatus unitSet(AudioUnit u, AudioUnitPropertyID p, UInt32 n, const void* v) {
        return ::AudioUnitSetProperty(u, p, kAudioUnitScope_Global, 0, v, n);
    }
};
struct OutputBufferConfiguration {
    OSStatus status = noErr;
    OSStatus deviceSetStatus = noErr;
    UInt32 frames = 0;
    UInt32 maximumSlice = 0;
};
// Shared with device-free tests. Hardware period belongs to AudioObject, not AudioUnit.
template<class Api>
OutputBufferConfiguration configure_output_buffers(AudioDeviceID device, AudioUnit unit,
                                                    UInt32 requested, bool mayChangeDevice, Api& api) {
    OutputBufferConfiguration result;
    AudioObjectPropertyAddress period{kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (mayChangeDevice) {
        AudioValueRange range{};
        AudioObjectPropertyAddress rangeAddress{kAudioDevicePropertyBufferFrameSizeRange,
            kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        UInt32 n = sizeof(range);
        if (api.deviceGet(device, rangeAddress, n, &range) == noErr && range.mMinimum > 0 && range.mMaximum >= range.mMinimum)
            requested = static_cast<UInt32>(std::clamp<double>(requested, range.mMinimum, range.mMaximum));
        result.deviceSetStatus = api.deviceSet(device, period, sizeof(requested), &requested);
        // A read-only device may reject the request; only actual readback determines the period.
    }
    UInt32 n = sizeof(result.frames);
    result.status = api.deviceGet(device, period, n, &result.frames);
    if (result.status != noErr) return result;
    if (!result.frames || result.frames > std::numeric_limits<UInt32>::max() / 2) {
        result.status = kAudio_ParamError;
        return result;
    }
    UInt32 previousMaximum = 0;
    n = sizeof(previousMaximum);
    api.unitGet(unit, kAudioUnitProperty_MaximumFramesPerSlice, n, &previousMaximum);
    // Leave headroom for AUHAL conversion/variable slices; never reduce an existing larger budget.
    UInt32 required = std::max(previousMaximum, result.frames * 2);
    result.status = api.unitSet(unit, kAudioUnitProperty_MaximumFramesPerSlice, sizeof(required), &required);
    if (result.status != noErr) return result;
    n = sizeof(result.maximumSlice);
    result.status = api.unitGet(unit, kAudioUnitProperty_MaximumFramesPerSlice, n, &result.maximumSlice);
    if (result.status == noErr && result.maximumSlice < required) result.status = kAudio_ParamError;
    return result;
}
} // namespace rta::platform::macos
