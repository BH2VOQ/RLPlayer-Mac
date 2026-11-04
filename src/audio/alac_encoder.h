// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// alac_encoder.h — 基于 macOS AudioToolbox 的 Apple Lossless (ALAC) 音频编码器
//
// 契约与实现要点：
//   1) LinearPCM s16 interleaved → kAudioFormatAppleLossless；
//   2) 每包帧数（frames_per_packet）支持 352（AirPlay 默认）与 4096（离线测）；
//   3) 有状态编码器，reset() 保证恢复初态且清空残留缓冲区；
//   4) 输入帧数不足一包时缓存到下次，跨调用不丢弃任何样本；
//   5) 预分配输出缓冲区与工作内存，避免在回调内部异常分配；
//   6) 提供 magic_cookie() 供 SDP 会话自证与解码回环；
//   7) encode_frame() 实施严格单包前置断言（frames == fpp 且 pending == 0），
//      非法输入失败时不改变任何状态（no state loss on invalid）；
//   8) 生产级输入输出校验：防止整数溢出、确保 CoreALAC 准确消费整包帧数、
//      强校验输出包长度与包描述，杜绝静默伪造或截断。
#pragma once

#include <AudioToolbox/AudioToolbox.h>
#include <cstdint>
#include <cstddef>
#include <string>
#include <vector>
#include <algorithm>
#include <limits>

namespace rta::audio {

class AlacEncoder {
public:
    AlacEncoder() = default;
    virtual ~AlacEncoder() {
        dispose();
    }

    AlacEncoder(const AlacEncoder&) = delete;
    AlacEncoder& operator=(const AlacEncoder&) = delete;

    AlacEncoder(AlacEncoder&& other) noexcept {
        move_from(std::move(other));
    }

    AlacEncoder& operator=(AlacEncoder&& other) noexcept {
        if (this != &other) {
            dispose();
            move_from(std::move(other));
        }
        return *this;
    }

    virtual bool init(uint32_t sampleRate, int channels, int bits, int framesPerPacket, std::string* err) {
        dispose();

        if (sampleRate == 0) {
            if (err) *err = "sampleRate must be > 0";
            return false;
        }
        if (channels != 1 && channels != 2) {
            if (err) *err = "channels must be 1 or 2";
            return false;
        }
        if (bits != 16) {
            if (err) *err = "bits must be 16";
            return false;
        }
        if (framesPerPacket != 352 && framesPerPacket != 4096) {
            if (err) *err = "framesPerPacket must be 352 or 4096";
            return false;
        }

        AudioStreamBasicDescription inDesc{};
        inDesc.mFormatID = kAudioFormatLinearPCM;
        inDesc.mSampleRate = static_cast<Float64>(sampleRate);
        inDesc.mChannelsPerFrame = static_cast<UInt32>(channels);
        inDesc.mBitsPerChannel = static_cast<UInt32>(bits);
        inDesc.mBytesPerFrame = static_cast<UInt32>(channels * (bits / 8));
        inDesc.mFramesPerPacket = 1;
        inDesc.mBytesPerPacket = inDesc.mBytesPerFrame;
        inDesc.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;

        AudioStreamBasicDescription outDesc{};
        outDesc.mFormatID = kAudioFormatAppleLossless;
        outDesc.mSampleRate = static_cast<Float64>(sampleRate);
        outDesc.mChannelsPerFrame = static_cast<UInt32>(channels);
        outDesc.mBitsPerChannel = 16;
        outDesc.mFramesPerPacket = static_cast<UInt32>(framesPerPacket);

        OSStatus st = ::AudioConverterNew(&inDesc, &outDesc, &m_conv);
        if (st != noErr || !m_conv) {
            m_conv = nullptr;
            if (err) *err = "AudioConverterNew failed with OSStatus=" + std::to_string(static_cast<int>(st));
            return false;
        }

        m_sampleRate = sampleRate;
        m_channels = channels;
        m_bits = bits;
        m_fpp = framesPerPacket;

        // 查询 AudioConverter 报告的最大单包字节数
        UInt32 maxPkt = 0;
        UInt32 propSize = sizeof(maxPkt);
        st = ::AudioConverterGetProperty(m_conv, kAudioConverterPropertyMaximumOutputPacketSize, &propSize, &maxPkt);
        const size_t pcmBytes = static_cast<size_t>(framesPerPacket) * static_cast<size_t>(channels) * sizeof(int16_t);
        const size_t bufferSize = std::max<size_t>({
            static_cast<size_t>(maxPkt > 0 ? maxPkt * 2 : 0),
            pcmBytes * 2,
            static_cast<size_t>(8192)
        });
        m_maxPacketBytes = (maxPkt > 0) ? std::max<size_t>(static_cast<size_t>(maxPkt), bufferSize) : bufferSize;
        m_packetBuffer.resize(bufferSize);

        // 提取并缓存 magic cookie
        UInt32 cookieSize = 0;
        st = ::AudioConverterGetPropertyInfo(m_conv, kAudioConverterCompressionMagicCookie, &cookieSize, nullptr);
        if (st == noErr && cookieSize > 0) {
            m_cookie.resize(cookieSize);
            st = ::AudioConverterGetProperty(m_conv, kAudioConverterCompressionMagicCookie, &cookieSize, m_cookie.data());
            if (st == noErr && cookieSize > 0) {
                m_cookie.resize(cookieSize);
            } else {
                m_cookie.clear();
            }
        } else {
            m_cookie.clear();
        }

        if (m_cookie.empty()) {
            dispose();
            if (err) *err = "Failed to retrieve ALAC compression magic cookie";
            return false;
        }

        m_pendingPcm.clear();
        m_pendingPcm.reserve(static_cast<size_t>(framesPerPacket) * static_cast<size_t>(channels) * 4);
        return true;
    }

    // 输入：交错 int16（bits==16 时）；返回若干 ALAC 包（每包 = 一个 RTP 载荷）
    virtual bool encode(const int16_t* interleaved, size_t frames,
                        std::vector<std::vector<uint8_t>>& outPackets, std::string* err) {
        outPackets.clear();

        if (!m_conv) {
            if (err) *err = "AlacEncoder not initialized";
            return false;
        }
        if (!interleaved) {
            if (err) *err = "null interleaved pointer";
            return false;
        }
        if (frames == 0) {
            if (err) *err = "frames must be > 0";
            return false;
        }
        if (m_channels <= 0 || m_fpp <= 0) {
            if (err) *err = "invalid encoder state";
            return false;
        }

        // 整数乘法溢出防护：frames * channels
        const size_t ch = static_cast<size_t>(m_channels);
        if (frames > std::numeric_limits<size_t>::max() / ch) {
            if (err) *err = "integer overflow: frames * channels exceeds size_t max";
            return false;
        }
        const size_t totalSamples = frames * ch;

        // 缓冲区累计容量溢出检查
        if (totalSamples > std::numeric_limits<size_t>::max() - m_pendingPcm.size()) {
            if (err) *err = "pending PCM buffer size overflow";
            return false;
        }

        const size_t packetSamples = static_cast<size_t>(m_fpp) * ch;
        const size_t prevPendingSize = m_pendingPcm.size();

        m_pendingPcm.insert(m_pendingPcm.end(), interleaved, interleaved + totalSamples);

        const size_t fullPackets = m_pendingPcm.size() / packetSamples;

        for (size_t i = 0; i < fullPackets; ++i) {
            const int16_t* packetData = m_pendingPcm.data() + i * packetSamples;
            std::vector<uint8_t> pkt;
            if (!encode_single_packet(packetData, pkt, err)) {
                // 编码异常时事务回滚：恢复插入前的 pending 缓冲，清空部分产物，保证不丢也不污染状态
                m_pendingPcm.resize(prevPendingSize);
                outPackets.clear();
                return false;
            }
            if (pkt.empty()) {
                m_pendingPcm.resize(prevPendingSize);
                outPackets.clear();
                if (err) *err = "encode_single_packet produced empty packet";
                return false;
            }
            outPackets.push_back(std::move(pkt));
        }

        if (fullPackets > 0) {
            m_pendingPcm.erase(m_pendingPcm.begin(), m_pendingPcm.begin() + fullPackets * packetSamples);
        }

        return true;
    }

    // 适配单包帧流调用（如 RaopSession 每次送 1 包帧数）
    // 契约：
    //   1) 严格单包前置断言：frames 必须精确等于 frames_per_packet()；
    //   2) 状态不变式：pending_frames() 必须为 0（严禁与流式缓冲混合调用）；
    //   3) 非法输入拒绝前绝不改变任何状态（no state loss on invalid）；
    //   4) 成功时产出且仅产出 1 个非空合法 ALAC 包。
    virtual bool encode_frame(const int16_t* interleaved, size_t frames,
                              std::vector<uint8_t>& outPacket, std::string* err) {
        outPacket.clear();

        if (!m_conv) {
            if (err) *err = "AlacEncoder not initialized";
            return false;
        }
        if (!interleaved) {
            if (err) *err = "null interleaved pointer";
            return false;
        }
        if (!m_pendingPcm.empty()) {
            if (err) *err = "cannot call encode_frame when pending buffer has " +
                            std::to_string(pending_frames()) +
                            " frames; drain via encode() or reset() first";
            return false;
        }
        if (frames != static_cast<size_t>(m_fpp)) {
            if (err) *err = "encode_frame requires exactly frames_per_packet (" +
                            std::to_string(m_fpp) + "), got " + std::to_string(frames);
            return false;
        }

        return encode_single_packet(interleaved, outPacket, err);
    }

    virtual void reset() {
        if (m_conv) {
            ::AudioConverterReset(m_conv);
        }
        m_pendingPcm.clear();
    }

    virtual int frames_per_packet() const {
        return m_fpp;
    }

    virtual uint32_t sample_rate() const {
        return m_sampleRate;
    }

    virtual int channels() const {
        return m_channels;
    }

    virtual int bits() const {
        return m_bits;
    }

    virtual size_t pending_frames() const {
        return m_channels > 0 ? m_pendingPcm.size() / static_cast<size_t>(m_channels) : 0;
    }

    virtual std::vector<uint8_t> magic_cookie() const {
        if (!m_cookie.empty()) {
            return m_cookie;
        }
        if (!m_conv) return {};
        UInt32 size = 0;
        OSStatus st = ::AudioConverterGetPropertyInfo(m_conv, kAudioConverterCompressionMagicCookie, &size, nullptr);
        if (st != noErr || size == 0) return {};
        std::vector<uint8_t> cookie(size);
        st = ::AudioConverterGetProperty(m_conv, kAudioConverterCompressionMagicCookie, &size, cookie.data());
        if (st != noErr) return {};
        cookie.resize(size);
        return cookie;
    }

    bool is_initialized() const {
        return m_conv != nullptr;
    }

private:
    struct InputContext {
        const int16_t* pcm;
        size_t framesLeft;
        int channels;
        size_t framesConsumed;
    };

    static OSStatus input_callback(AudioConverterRef /*inAudioConverter*/,
                                   UInt32* ioNumberDataPackets,
                                   AudioBufferList* ioData,
                                   AudioStreamPacketDescription** outDataPacketDescription,
                                   void* inUserData) {
        auto* ctx = static_cast<InputContext*>(inUserData);
        if (!ctx || ctx->framesLeft == 0) {
            *ioNumberDataPackets = 0;
            return noErr;
        }

        const size_t needed = *ioNumberDataPackets;
        const size_t provide = std::min<size_t>(needed, ctx->framesLeft);

        ioData->mNumberBuffers = 1;
        ioData->mBuffers[0].mNumberChannels = static_cast<UInt32>(ctx->channels);
        ioData->mBuffers[0].mDataByteSize = static_cast<UInt32>(provide * static_cast<size_t>(ctx->channels) * sizeof(int16_t));
        ioData->mBuffers[0].mData = const_cast<int16_t*>(ctx->pcm);

        ctx->pcm += provide * static_cast<size_t>(ctx->channels);
        ctx->framesLeft -= provide;
        ctx->framesConsumed += provide;
        *ioNumberDataPackets = static_cast<UInt32>(provide);
        if (outDataPacketDescription) *outDataPacketDescription = nullptr;
        return noErr;
    }

    bool encode_single_packet(const int16_t* pcm, std::vector<uint8_t>& out, std::string* err) {
        out.clear();
        if (!m_conv) {
            if (err) *err = "AlacEncoder not initialized";
            return false;
        }
        if (!pcm) {
            if (err) *err = "null pcm pointer";
            return false;
        }

        InputContext ctx{pcm, static_cast<size_t>(m_fpp), m_channels, 0};

        AudioBufferList abl{};
        abl.mNumberBuffers = 1;
        abl.mBuffers[0].mNumberChannels = static_cast<UInt32>(m_channels);
        abl.mBuffers[0].mDataByteSize = static_cast<UInt32>(m_packetBuffer.size());
        abl.mBuffers[0].mData = m_packetBuffer.data();

        UInt32 ioPackets = 1;
        AudioStreamPacketDescription asp{};
        const OSStatus st = ::AudioConverterFillComplexBuffer(m_conv, input_callback, &ctx, &ioPackets, &abl, &asp);
        if (st != noErr) {
            if (err) *err = "AudioConverterFillComplexBuffer failed: " + std::to_string(static_cast<int>(st));
            return false;
        }

        // 生产级校验 1：CoreALAC 内部输入消费必须精准等于要求的每包帧数
        if (ctx.framesLeft != 0 || ctx.framesConsumed != static_cast<size_t>(m_fpp)) {
            if (err) *err = "CoreALAC input consumption mismatch: consumed " +
                            std::to_string(ctx.framesConsumed) + " frames, expected " +
                            std::to_string(m_fpp) + " (framesLeft=" + std::to_string(ctx.framesLeft) + ")";
            return false;
        }

        // 生产级校验 2：必须恰好产出 1 个包
        if (ioPackets != 1) {
            if (err) *err = "AudioConverter produced invalid packet count (" + std::to_string(ioPackets) + ")";
            return false;
        }

        // 生产级校验 3：包长严格有界且非空（杜绝静默空包）
        const UInt32 byteSize = abl.mBuffers[0].mDataByteSize;
        if (byteSize == 0) {
            if (err) *err = "AudioConverter produced 0-byte ALAC packet";
            return false;
        }
        if (byteSize > m_packetBuffer.size()) {
            if (err) *err = "AudioConverter packet size exceeded buffer size (" +
                            std::to_string(byteSize) + " > " + std::to_string(m_packetBuffer.size()) + ")";
            return false;
        }
        if (m_maxPacketBytes > 0 && byteSize > m_maxPacketBytes) {
            if (err) *err = "AudioConverter packet size exceeded max bounds (" +
                            std::to_string(byteSize) + " > " + std::to_string(m_maxPacketBytes) + ")";
            return false;
        }

        // 生产级校验 4：若底层驱动提供了 AudioStreamPacketDescription，双向校验长度与帧数
        if (asp.mDataByteSize > 0 && asp.mDataByteSize != byteSize) {
            if (err) *err = "AudioStreamPacketDescription byte size mismatch (asp=" +
                            std::to_string(asp.mDataByteSize) + ", abl=" + std::to_string(byteSize) + ")";
            return false;
        }
        if (asp.mVariableFramesInPacket > 0 && asp.mVariableFramesInPacket != static_cast<UInt32>(m_fpp)) {
            if (err) *err = "AudioStreamPacketDescription frame count mismatch (asp=" +
                            std::to_string(asp.mVariableFramesInPacket) + ", fpp=" + std::to_string(m_fpp) + ")";
            return false;
        }

        out.assign(m_packetBuffer.data(), m_packetBuffer.data() + byteSize);
        return true;
    }

    void dispose() {
        if (m_conv) {
            ::AudioConverterDispose(m_conv);
            m_conv = nullptr;
        }
        m_pendingPcm.clear();
        m_packetBuffer.clear();
        m_cookie.clear();
        m_sampleRate = 0;
        m_channels = 0;
        m_bits = 0;
        m_fpp = 0;
        m_maxPacketBytes = 0;
    }

    void move_from(AlacEncoder&& other) noexcept {
        m_conv = other.m_conv;
        other.m_conv = nullptr;
        m_sampleRate = other.m_sampleRate;
        other.m_sampleRate = 0;
        m_channels = other.m_channels;
        other.m_channels = 0;
        m_bits = other.m_bits;
        other.m_bits = 0;
        m_fpp = other.m_fpp;
        other.m_fpp = 0;
        m_maxPacketBytes = other.m_maxPacketBytes;
        other.m_maxPacketBytes = 0;
        m_cookie = std::move(other.m_cookie);
        other.m_cookie.clear();
        m_pendingPcm = std::move(other.m_pendingPcm);
        m_packetBuffer = std::move(other.m_packetBuffer);
    }

    AudioConverterRef m_conv = nullptr;
    uint32_t m_sampleRate = 0;
    int m_channels = 0;
    int m_bits = 0;
    int m_fpp = 0;
    size_t m_maxPacketBytes = 0;
    std::vector<uint8_t> m_cookie;
    std::vector<int16_t> m_pendingPcm;
    std::vector<uint8_t> m_packetBuffer;
};

} // namespace rta::audio
