// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_alac_encoder.cpp — AudioToolbox ALAC 编码器与无损回环解码深度验证测试
#include "audio/alac_encoder.h"
#include <AudioToolbox/AudioToolbox.h>
#include <iostream>
#include <vector>
#include <cmath>
#include <string>
#include <algorithm>
#include <memory>
#include <limits>

static int g_fail = 0;
static void ck(bool cond, const std::string& what, const std::string& detail = "") {
    if (cond) {
        std::cout << "  [PASS] " << what << std::endl;
    } else {
        std::cout << "  [FAIL] " << what << "  " << detail << std::endl;
        ++g_fail;
    }
}

// 辅助：用 AudioConverter 创建 ALAC 解码器并做回环解码（支持单声道与双声道，以及任意 fpp）
static bool decode_alac_packets(uint32_t sampleRate, int channels, int fpp,
                                const std::vector<uint8_t>& magicCookie,
                                const std::vector<std::vector<uint8_t>>& packets,
                                std::vector<int16_t>& outPcm, std::string* err) {
    outPcm.clear();

    AudioStreamBasicDescription pcmDesc{};
    pcmDesc.mFormatID = kAudioFormatLinearPCM;
    pcmDesc.mSampleRate = static_cast<Float64>(sampleRate);
    pcmDesc.mChannelsPerFrame = static_cast<UInt32>(channels);
    pcmDesc.mBitsPerChannel = 16;
    pcmDesc.mBytesPerFrame = static_cast<UInt32>(channels * sizeof(int16_t));
    pcmDesc.mFramesPerPacket = 1;
    pcmDesc.mBytesPerPacket = pcmDesc.mBytesPerFrame;
    pcmDesc.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;

    AudioStreamBasicDescription alacDesc{};
    alacDesc.mFormatID = kAudioFormatAppleLossless;
    alacDesc.mSampleRate = static_cast<Float64>(sampleRate);
    alacDesc.mChannelsPerFrame = static_cast<UInt32>(channels);
    alacDesc.mBitsPerChannel = 16;
    alacDesc.mFramesPerPacket = static_cast<UInt32>(fpp);

    AudioConverterRef dec = nullptr;
    OSStatus st = ::AudioConverterNew(&alacDesc, &pcmDesc, &dec);
    if (st != noErr || !dec) {
        if (err) *err = "AudioConverterNew(dec) failed: " + std::to_string(static_cast<int>(st));
        return false;
    }

    if (!magicCookie.empty()) {
        st = ::AudioConverterSetProperty(dec, kAudioConverterDecompressionMagicCookie,
                                         static_cast<UInt32>(magicCookie.size()), magicCookie.data());
        if (st != noErr) {
            ::AudioConverterDispose(dec);
            if (err) *err = "AudioConverterSetProperty(cookie) failed: " + std::to_string(static_cast<int>(st));
            return false;
        }
    }

    struct DecCtx {
        const uint8_t* data;
        size_t size;
        int channels;
        bool done;
    };

    auto decCb = [](AudioConverterRef /*conv*/,
                    UInt32* ioPackets,
                    AudioBufferList* ioData,
                    AudioStreamPacketDescription** outDesc,
                    void* userData) -> OSStatus {
        auto* ctx = static_cast<DecCtx*>(userData);
        if (ctx->done) {
            *ioPackets = 0;
            return noErr;
        }
        static AudioStreamPacketDescription asp{};
        asp.mStartOffset = 0;
        asp.mVariableFramesInPacket = 0;
        asp.mDataByteSize = static_cast<UInt32>(ctx->size);

        ioData->mNumberBuffers = 1;
        ioData->mBuffers[0].mNumberChannels = static_cast<UInt32>(ctx->channels);
        ioData->mBuffers[0].mDataByteSize = asp.mDataByteSize;
        ioData->mBuffers[0].mData = const_cast<uint8_t*>(ctx->data);
        *ioPackets = 1;
        if (outDesc) *outDesc = &asp;
        ctx->done = true;
        return noErr;
    };

    std::vector<int16_t> decBuf(static_cast<size_t>(fpp) * static_cast<size_t>(channels));

    for (size_t i = 0; i < packets.size(); ++i) {
        DecCtx dctx{packets[i].data(), packets[i].size(), channels, false};
        UInt32 outFrames = static_cast<UInt32>(fpp);

        AudioBufferList abl{};
        abl.mNumberBuffers = 1;
        abl.mBuffers[0].mNumberChannels = static_cast<UInt32>(channels);
        abl.mBuffers[0].mDataByteSize = static_cast<UInt32>(decBuf.size() * sizeof(int16_t));
        abl.mBuffers[0].mData = decBuf.data();

        st = ::AudioConverterFillComplexBuffer(dec, decCb, &dctx, &outFrames, &abl, nullptr);
        if (st != noErr) {
            ::AudioConverterDispose(dec);
            if (err) *err = "AudioConverterFillComplexBuffer(dec) failed at packet " + std::to_string(i) +
                            ": " + std::to_string(static_cast<int>(st));
            return false;
        }
        outPcm.insert(outPcm.end(), decBuf.data(), decBuf.data() + outFrames * channels);
    }

    ::AudioConverterDispose(dec);
    return true;
}

// 模拟协议层测试派生类（验证虚析构与虚函数派发契约）
class MockAlacEncoder : public rta::audio::AlacEncoder {
public:
    bool encode_frame_called = false;
    bool encode_frame(const int16_t* interleaved, size_t frames,
                      std::vector<uint8_t>& outPacket, std::string* err) override {
        encode_frame_called = true;
        return AlacEncoder::encode_frame(interleaved, frames, outPacket, err);
    }
};

int main() {
    std::cout << "=== Running test_alac_encoder (Production Audit) ===" << std::endl;

    // 1. 先红可见：未初始化、无效参数、空指针、零帧以及溢出边界校验
    {
        std::cout << "[Test 1: Input Validation & Negative Cases]" << std::endl;
        rta::audio::AlacEncoder uninitEnc;
        std::vector<std::vector<uint8_t>> pkts;
        std::vector<uint8_t> singlePkt;
        std::string err;
        int16_t dummyPcm[704] = {0};

        bool ok = uninitEnc.encode(dummyPcm, 352, pkts, &err);
        ck(!ok && !err.empty(), "Uninitialized encoder fails encode() with non-empty err", err);

        err.clear();
        ok = uninitEnc.encode_frame(dummyPcm, 352, singlePkt, &err);
        ck(!ok && !err.empty(), "Uninitialized encoder fails encode_frame() with non-empty err", err);

        rta::audio::AlacEncoder enc;
        err.clear();
        ok = enc.init(0, 2, 16, 352, &err);
        ck(!ok && !err.empty(), "init(sampleRate=0) fails with err", err);

        err.clear();
        ok = enc.init(44100, 0, 16, 352, &err);
        ck(!ok && !err.empty(), "init(channels=0) fails with err", err);

        err.clear();
        ok = enc.init(44100, 3, 16, 352, &err);
        ck(!ok && !err.empty(), "init(channels=3) fails with err", err);

        err.clear();
        ok = enc.init(44100, 2, 24, 352, &err);
        ck(!ok && !err.empty(), "init(bits=24) fails with err", err);

        err.clear();
        ok = enc.init(44100, 2, 16, 512, &err);
        ck(!ok && !err.empty(), "init(framesPerPacket=512) fails with err", err);

        err.clear();
        ok = enc.init(44100, 2, 16, 352, &err);
        ck(ok && err.empty(), "init(44100, 2, 16, 352) succeeds");
        ck(enc.is_initialized(), "is_initialized() reports true");

        err.clear();
        ok = enc.encode(nullptr, 352, pkts, &err);
        ck(!ok && !err.empty(), "encode(nullptr) fails with err", err);

        err.clear();
        ok = enc.encode(dummyPcm, 0, pkts, &err);
        ck(!ok && !err.empty(), "encode(frames=0) fails with err", err);

        // 整数溢出检测：frames * channels 超过 size_t 最大值
        err.clear();
        const size_t hugeFrames = std::numeric_limits<size_t>::max() / 2 + 10;
        ok = enc.encode(dummyPcm, hugeFrames, pkts, &err);
        ck(!ok && !err.empty(), "encode(hugeFrames) rejects integer overflow with err", err);
        ck(enc.pending_frames() == 0, "No state change on integer overflow rejection");
    }

    // 2. encode_frame 严格前置断言与状态不变式（Strict Preconditions & No State Loss）
    {
        std::cout << "[Test 2: encode_frame() Invariants & Preconditions]" << std::endl;
        rta::audio::AlacEncoder encFrame;
        std::string err;
        ck(encFrame.init(44100, 2, 16, 352, &err), "encFrame.init(44100, 2, 16, 352)");

        int16_t validPcm[352 * 2] = {1234};
        std::vector<uint8_t> pkt;

        // 2.1 帧数不足 1 包（351 帧）时必须立即失败，且不得修改状态
        err.clear();
        bool ok = encFrame.encode_frame(validPcm, 351, pkt, &err);
        ck(!ok && !err.empty(), "encode_frame rejects undersized frames (351 != 352)", err);
        ck(pkt.empty(), "outPacket remains empty on undersized rejection");
        ck(encFrame.pending_frames() == 0, "pending_frames remains 0 after undersized rejection");

        // 2.2 帧数超出 1 包（353 帧或 704 帧）时必须立即失败，不得静默丢弃多余帧
        err.clear();
        ok = encFrame.encode_frame(validPcm, 353, pkt, &err);
        ck(!ok && !err.empty(), "encode_frame rejects oversized frames (353 != 352)", err);
        ck(pkt.empty(), "outPacket remains empty on oversized rejection");
        ck(encFrame.pending_frames() == 0, "pending_frames remains 0 after oversized rejection");

        err.clear();
        ok = encFrame.encode_frame(validPcm, 704, pkt, &err);
        ck(!ok && !err.empty(), "encode_frame rejects 704 frames before mutation", err);
        ck(encFrame.pending_frames() == 0, "pending_frames remains 0 after 704 rejection");

        // 2.3 状态不变式：若之前通过 encode() 留有 pending 帧，encode_frame 必须拒绝混用，防止状态破坏
        std::vector<std::vector<uint8_t>> pkts;
        ok = encFrame.encode(validPcm, 100, pkts, &err); // 送 100 帧留底
        ck(ok && encFrame.pending_frames() == 100, "encode() buffered 100 pending frames");

        err.clear();
        ok = encFrame.encode_frame(validPcm, 352, pkt, &err);
        ck(!ok && !err.empty(), "encode_frame rejects call while pending buffer is non-empty", err);
        ck(encFrame.pending_frames() == 100, "pending buffer unmodified after refused encode_frame");

        // 清理 pending 缓冲
        encFrame.reset();
        ck(encFrame.pending_frames() == 0, "reset() cleared pending buffer");

        // 2.4 满足契约时正常单包编码，输出包非空且 pending 严格为 0
        err.clear();
        ok = encFrame.encode_frame(validPcm, 352, pkt, &err);
        ck(ok && !pkt.empty(), "encode_frame with exact 352 frames succeeds");
        ck(encFrame.pending_frames() == 0, "pending_frames is strictly 0 after encode_frame");
    }

    // 3. 全量 int16 极值与全范围边界测试（Full int16 Range Roundtrip: -32768..32767）
    {
        std::cout << "[Test 3: Full int16 Range & Extreme Values Roundtrip]" << std::endl;
        rta::audio::AlacEncoder encRange;
        std::string err;
        ck(encRange.init(44100, 2, 16, 352, &err), "init stereo 352 for range test");

        const int fpp = 352;
        const int ch = 2;
        std::vector<int16_t> extremesPcm(fpp * ch);
        for (int i = 0; i < fpp; ++i) {
            if (i % 8 == 0) {
                extremesPcm[i * 2] = -32768;     // 负极值
                extremesPcm[i * 2 + 1] = 32767;  // 正极值
            } else if (i % 8 == 1) {
                extremesPcm[i * 2] = 32767;
                extremesPcm[i * 2 + 1] = -32768;
            } else if (i % 8 == 2) {
                extremesPcm[i * 2] = -32768;
                extremesPcm[i * 2 + 1] = -32768;
            } else if (i % 8 == 3) {
                extremesPcm[i * 2] = 32767;
                extremesPcm[i * 2 + 1] = 32767;
            } else if (i % 8 == 4) {
                extremesPcm[i * 2] = 0;
                extremesPcm[i * 2 + 1] = -1;
            } else if (i % 8 == 5) {
                extremesPcm[i * 2] = 1;
                extremesPcm[i * 2 + 1] = 0;
            } else if (i % 8 == 6) {
                extremesPcm[i * 2] = -32767;
                extremesPcm[i * 2 + 1] = 32766;
            } else {
                // 最大满幅跳变：从 -32768 直跳 +32767（考验预测器和熵编码极值处理）
                extremesPcm[i * 2] = (i % 2 == 0) ? -32768 : 32767;
                extremesPcm[i * 2 + 1] = (i % 2 == 0) ? 32767 : -32768;
            }
        }

        std::vector<uint8_t> pkt;
        bool ok = encRange.encode_frame(extremesPcm.data(), fpp, pkt, &err);
        ck(ok && !pkt.empty(), "encode_frame with extreme values succeeds");

        std::vector<std::vector<uint8_t>> pkts = {pkt};
        std::vector<int16_t> decodedPcm;
        ok = decode_alac_packets(44100, ch, fpp, encRange.magic_cookie(), pkts, decodedPcm, &err);
        ck(ok, "decode extreme values packet succeeded", err);
        ck(decodedPcm == extremesPcm, "Extreme int16 values (-32768, 32767) decode 100% bit-exact");
    }

    // 4. 多声道支持测试（Mono 1-Channel 与 Stereo 2-Channel 全覆盖）
    {
        std::cout << "[Test 4: Channel Support (Mono 1-ch and Stereo 2-ch)]" << std::endl;
        // 4.1 Mono 测试
        rta::audio::AlacEncoder monoEnc;
        std::string err;
        ck(monoEnc.init(44100, 1, 16, 352, &err), "monoEnc.init(44100, 1, 16, 352)");
        ck(monoEnc.channels() == 1, "monoEnc.channels() == 1");

        const int fpp = 352;
        std::vector<int16_t> monoPcm(fpp);
        for (int i = 0; i < fpp; ++i) {
            monoPcm[i] = static_cast<int16_t>((i % 2 == 0) ? -32768 : 32767);
        }

        std::vector<uint8_t> monoPkt;
        bool ok = monoEnc.encode_frame(monoPcm.data(), fpp, monoPkt, &err);
        ck(ok && !monoPkt.empty(), "mono encode_frame succeeds");

        std::vector<std::vector<uint8_t>> monoPkts = {monoPkt};
        std::vector<int16_t> decodedMono;
        ok = decode_alac_packets(44100, 1, fpp, monoEnc.magic_cookie(), monoPkts, decodedMono, &err);
        ck(ok, "decode mono packet succeeded", err);
        ck(decodedMono == monoPcm, "Mono int16 decode 100% bit-exact");

        // 4.2 多块流式 Mono 编码
        std::vector<int16_t> monoStream(fpp * 3 + 100);
        for (size_t i = 0; i < monoStream.size(); ++i) {
            monoStream[i] = static_cast<int16_t>(std::sin(2.0 * M_PI * 440.0 * i / 44100.0) * 15000.0);
        }
        std::vector<std::vector<uint8_t>> outMonoPkts;
        ok = monoEnc.encode(monoStream.data(), monoStream.size(), outMonoPkts, &err);
        ck(ok && outMonoPkts.size() == 3, "Mono stream produced 3 full packets");
        ck(monoEnc.pending_frames() == 100, "Mono stream pending_frames is 100");

        // 补齐 252 帧
        std::vector<int16_t> monoTail(252, 0);
        std::vector<std::vector<uint8_t>> tailPkts;
        ok = monoEnc.encode(monoTail.data(), 252, tailPkts, &err);
        ck(ok && tailPkts.size() == 1, "Mono stream tail encode produced 1 packet");
        ck(monoEnc.pending_frames() == 0, "Mono pending frames drained to 0");
    }

    // 5. 变长 Chunk 分割输入、连续性及 EOS 语义（Protocol Zero-Pad Verification）
    {
        std::cout << "[Test 5: Variable Chunks & Protocol EOS Zero-Pad Semantics]" << std::endl;
        rta::audio::AlacEncoder encVar;
        std::string err;
        ck(encVar.init(44100, 2, 16, 352, &err), "encVar.init(44100, 2, 16, 352)");

        // 模拟任意大小的音频块（素数、单帧、混合）：7, 13, 1, 100, 31, 200 = 352 frames
        std::vector<size_t> chunkSizes = {7, 13, 1, 100, 31, 200};
        const size_t totalChunkFrames = 352;
        std::vector<int16_t> expectedPcm(totalChunkFrames * 2);
        for (size_t i = 0; i < totalChunkFrames; ++i) {
            expectedPcm[i * 2] = static_cast<int16_t>(i * 40 - 5000);
            expectedPcm[i * 2 + 1] = static_cast<int16_t>(-(int16_t)(i * 40 - 5000));
        }

        std::vector<std::vector<uint8_t>> collectedPkts;
        size_t offset = 0;
        for (size_t sz : chunkSizes) {
            std::vector<std::vector<uint8_t>> curPkts;
            bool ok = encVar.encode(expectedPcm.data() + offset * 2, sz, curPkts, &err);
            ck(ok, "Chunk encode for sz=" + std::to_string(sz));
            collectedPkts.insert(collectedPkts.end(), curPkts.begin(), curPkts.end());
            offset += sz;
        }
        ck(collectedPkts.size() == 1, "Exactly 1 packet produced across fragmented inputs totaling 352");
        ck(encVar.pending_frames() == 0, "Pending buffer drained after full 352 frames");

        std::vector<int16_t> decodedVar;
        bool ok = decode_alac_packets(44100, 2, 352, encVar.magic_cookie(), collectedPkts, decodedVar, &err);
        ck(ok && decodedVar == expectedPcm, "Decoded fragmented chunks are bit-for-bit identical to source");

        // 5.2 EOS 语义自证：
        // 契约明确说明：ALAC 编码器自身不猜测何时流结束、也不自动补零；
        // 当音频流结束且余下不满 352 帧（例如 100 帧）时，协议层（RaopSession/finish）负责补齐零到 352 帧送给编码器。
        // 测试验证编码器在接收到「真实音频 + 补零尾巴」时，输出的 ALAC 包能精准无损还原出前 100 帧真实值与后 252 帧全零。
        encVar.reset();
        const size_t realFrames = 100;
        const size_t padFrames = 252;
        std::vector<int16_t> eosPcm(352 * 2, 0);
        for (size_t i = 0; i < realFrames; ++i) {
            eosPcm[i * 2] = static_cast<int16_t>(i * 100 + 300);
            eosPcm[i * 2 + 1] = static_cast<int16_t>(-i * 100 - 300);
        }
        // 后 padFrames 自动为 0

        std::vector<uint8_t> eosPkt;
        ok = encVar.encode_frame(eosPcm.data(), 352, eosPkt, &err);
        ck(ok && !eosPkt.empty(), "encode_frame encoded padded EOS packet");

        std::vector<std::vector<uint8_t>> eosPktsList = {eosPkt};
        std::vector<int16_t> decodedEos;
        ok = decode_alac_packets(44100, 2, 352, encVar.magic_cookie(), eosPktsList, decodedEos, &err);
        ck(ok, "decoded EOS packet successfully");
        ck(decodedEos.size() == 352 * 2, "Decoded EOS packet has exactly 352 frames");
        ck(decodedEos == eosPcm, "Decoded EOS packet exactly matches 100 real frames followed by 252 zeros");
    }

    // 6. 4096 帧/包（离线测口径）支持与回环验证
    {
        std::cout << "[Test 6: 4096 Frames/Packet Mode & Loopback]" << std::endl;
        rta::audio::AlacEncoder enc4096;
        std::string err;
        bool ok = enc4096.init(44100, 2, 16, 4096, &err);
        ck(ok, "enc4096.init(44100, 2, 16, 4096) succeeded");
        ck(enc4096.frames_per_packet() == 4096, "frames_per_packet() == 4096");

        // 编码 3 个包 = 12288 帧
        const size_t totalFrames = 4096 * 3;
        std::vector<int16_t> pcm4096(totalFrames * 2);
        for (size_t i = 0; i < totalFrames; ++i) {
            pcm4096[i * 2] = static_cast<int16_t>(std::sin(2.0 * M_PI * 1000.0 * i / 44100.0) * 25000.0);
            pcm4096[i * 2 + 1] = static_cast<int16_t>(std::cos(2.0 * M_PI * 1000.0 * i / 44100.0) * 25000.0);
        }

        std::vector<std::vector<uint8_t>> pkts4096;
        ok = enc4096.encode(pcm4096.data(), totalFrames, pkts4096, &err);
        ck(ok, "enc4096.encode succeeded");
        ck(pkts4096.size() == 3, "Generated exactly 3 packets for 12288 frames");

        std::vector<int16_t> dec4096;
        ok = decode_alac_packets(44100, 2, 4096, enc4096.magic_cookie(), pkts4096, dec4096, &err);
        ck(ok, "4096 fpp decode succeeded", err);
        ck(dec4096 == pcm4096, "4096 fpp ALAC decoded PCM bit-for-bit identical");
    }

    // 7. 移动语义、Cookie 一致性与重置/重开生命周期（Move, Cookie, Reset, Reopen）
    {
        std::cout << "[Test 7: Move Semantics, Cookie Consistency & Lifecycle]" << std::endl;
        rta::audio::AlacEncoder encA;
        std::string err;
        ck(encA.init(44100, 2, 16, 352, &err), "encA init");
        std::vector<uint8_t> cookieA = encA.magic_cookie();
        ck(!cookieA.empty(), "encA magic_cookie() non-empty");

        // 7.1 移动构造测试
        rta::audio::AlacEncoder encMoved(std::move(encA));
        ck(!encA.is_initialized(), "Moved-from encA is_initialized() == false");
        ck(encMoved.is_initialized(), "Moved-to encMoved is_initialized() == true");
        ck(encMoved.magic_cookie() == cookieA, "encMoved retains identical magic_cookie");
        ck(encMoved.frames_per_packet() == 352, "encMoved frames_per_packet() == 352");
        ck(encMoved.sample_rate() == 44100, "encMoved sample_rate() == 44100");
        ck(encMoved.channels() == 2, "encMoved channels() == 2");
        ck(encMoved.bits() == 16, "encMoved bits() == 16");

        // 验证 moved-to 实例正常工作
        int16_t testPcm[352 * 2];
        for (int i = 0; i < 352 * 2; ++i) testPcm[i] = static_cast<int16_t>(i * 15);
        std::vector<uint8_t> movedPkt;
        bool ok = encMoved.encode_frame(testPcm, 352, movedPkt, &err);
        ck(ok && !movedPkt.empty(), "Moved-to encoder encodes frame successfully");

        // 7.2 移动赋值测试
        rta::audio::AlacEncoder encAssign;
        encAssign = std::move(encMoved);
        ck(!encMoved.is_initialized(), "Moved-from encMoved is_initialized() == false");
        ck(encAssign.is_initialized(), "Moved-to encAssign is_initialized() == true");
        ck(encAssign.magic_cookie() == cookieA, "encAssign retains identical magic_cookie");

        // 7.3 reset() 与 reopen（多次 init）测试
        encAssign.reset();
        ck(encAssign.pending_frames() == 0, "pending_frames == 0 after reset");
        ck(encAssign.magic_cookie() == cookieA, "magic_cookie unchanged after reset");

        // reopen（在同一对象上重新 init）
        ck(encAssign.init(48000, 2, 16, 352, &err), "Reopen with 48000Hz succeeds");
        ck(encAssign.sample_rate() == 48000, "sample_rate updated to 48000");
        std::vector<uint8_t> cookie48k = encAssign.magic_cookie();
        ck(!cookie48k.empty(), "New sample rate cookie retrieved");
    }

    // 8. 虚接口保留与协议 Fake Subclass 派发测试（Virtual API Compatibility）
    {
        std::cout << "[Test 8: Virtual API & Subclass Compatibility]" << std::endl;
        std::unique_ptr<rta::audio::AlacEncoder> mock = std::make_unique<MockAlacEncoder>();
        std::string err;
        ck(mock->init(44100, 2, 16, 352, &err), "mock->init() succeeds");

        int16_t dummy[352 * 2] = {42};
        std::vector<uint8_t> pkt;
        bool ok = mock->encode_frame(dummy, 352, pkt, &err);
        ck(ok && !pkt.empty(), "Virtual dispatch to encode_frame succeeds");

        auto* derived = dynamic_cast<MockAlacEncoder*>(mock.get());
        ck(derived != nullptr, "dynamic_cast to derived class succeeds");
        ck(derived && derived->encode_frame_called, "Overridden encode_frame was invoked via virtual dispatch");
    }

    std::cout << "=== test_alac_encoder complete, total failures: " << g_fail << " ===" << std::endl;
    return g_fail > 0 ? 1 : 0;
}
