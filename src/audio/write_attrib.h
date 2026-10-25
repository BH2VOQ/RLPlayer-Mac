// write_attrib.h — 「写不进去」的归因分类与整周期量化（平台无关纯逻辑）
//
// 2026-10-25 从 src/audio/wasapi_out.h 提取出来。
// 提取原因（用户铁律）：功能不能删除，只做全量移植。
//   这段代码原本住在 WASAPI 后端头里，但它是**纯逻辑**——不碰任何 Windows 类型、
//   不打开设备、只吃四个整数吐一个分类。它是 RENDERFAIL 归因的判据本体
//   （tests/test_renderfail.cpp、test_hotfix_guard.cpp 直接驱动它）。
//   Windows 后端被移除后，如果连它一起删掉，就等于把「欠载归因」这个能力弄丢了，
//   而不是「删掉一个平台实现」。所以提取到跨平台头，macOS 的 CoreAudio 侧继续用同一份。
//
// 原始注释保留如下（说明它为什么独立成结构）：

#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace rta::audio {

// ============================================================================
// 开流失败归因 / 格式能力探测 的数据契约
// ----------------------------------------------------------------------------
// 2026-10-25 从 src/audio/wasapi_out.h 一并提取。
// 为什么必须保留：这两个结构是 HF-01/02 的「地基」——它们承载的是
// 「为什么开不了流」与「设备到底支持哪些采样率/位深」这两个**用户可见能力**
// （诊断页、设置页的能力提示、失败时的可读报错都读它）。
// 它们本身只有 std::string / std::vector / bool，不含任何平台类型，
// 所以平台后端换掉不代表能力该消失。macOS 侧 CoreAudio 用同一份结构填充。
// ============================================================================

// open() 失败时的结构化原因（HF-01/02 地基）：UNSUPPORTED_FORMAT 不再是唯一信息。
// 只在失败路径填充；open() 的出参指针默认为 nullptr，旧调用完全不变。
struct OpenFail {
    std::string request;         // 请求格式，如 "rate=44100 ch=2 bits=24 buf=100.0ms"
    std::string supportedList;   // 该 bits/channels 下独占支持的采样率，"44100/48000/…"；空=探测为空或端点不可用
    std::string hresultText;     // 平台错误码文本，如 "0x88890008 UNSUPPORTED_FORMAT"（macOS 侧填 OSStatus）
    std::string deviceId;        // 实际使用的端点 id（空=默认端点）
};

// 结构化能力探测（HF-01/02 地基，只读）：16/24/32-bit 各自的独占支持率列表。
// 纯探测：不开流、不发声、不接管设备；不做任何回退/降级决策（决策在 rtaweb 接线）。
struct FormatProbe {
    std::vector<uint32_t> rates16, rates24, rates32;
    std::string deviceId;
    bool        endpointAlive = false;   // 设备存在且可用才为 true
    std::string friendlyName;
};

// 旧日志只有 w0/wr，而「写不进去」至少有两条互斥成因，w0 把它们混成一个数：
//   ① 设备缓冲满    ⟹ pad == bufferFrames_ ⟹ room == 0
//   ② 手里数据不足一个周期，整周期量化后归零 ⟹ room > 0 但 avail < per
// 现场（96k/100ms，w0=205 wr=41，每次成功恰写 9600 帧整缓冲）区分不了二者，
// 而处置完全不同：①是设备/驱动问题，②是【我们的轮询粒度喂不上】。
// 独立成结构的原因（铁律 3）：判据本体要能被 mock 输入直接驱动，否则只能
// 「打开真设备再看日志」—— 那既违反铁律 1（不放声/不接管设备），也无法复现。
// 各平台后端的 write_available 都用这个结构，测试与生产走同一份代码。
struct ZeroAttrib {
    long long padFull = 0;   // ① 设备缓冲满
    long long starved = 0;   // ② 供料不足一个周期
    long long other   = 0;   // ③ 其它（可用空间不足一个周期等）
    int       last    = 0;   // 最近一次：0=写成功/未发生 1=满 2=供料不足 3=其它

    // toWrite     量化后的写入帧数（0 = 这次写不进去）
    // room        设备侧可用空间（整周期量化之前）
    // availFrames 手里待写帧数
    // per         设备周期帧数（0 = 未知，不做整周期量化）
    void classify(size_t toWrite, size_t room, size_t availFrames, size_t per) {
        if (toWrite != 0) { last = 0; return; }
        if (room == 0) { ++padFull; last = 1; }
        else if (per > 0 && availFrames < per) { ++starved; last = 2; }
        else { ++other; last = 3; }
    }
    // 最近一次「写不进去」的成因，一行文字，供 STAT / RENDERFAIL 直接打印
    std::string reason() const {
        if (last == 1) return "pad=full";
        if (last == 2) return "avail<period";
        if (last == 3) return "other";
        return "-";
    }
};

// 独占 GetBuffer 要求周期整数倍（WASAPI 语义；CoreAudio 侧同构）：把「想写多少帧」向下取整到周期倍数（方案 §3.2 第 3 条根因）。
// 抽成纯函数只为可测（tests/test_renderfail.cpp 直接驱动，行为与旧内联代码逐字一致）：
//   room 不足一个周期（如 room=4800、per=9600）⟹ 返回 0，这一轮什么也没写，
//   ZeroAttrib 归因为 other —— 不是 padFull（设备缓冲并没有满）。
inline size_t quantize_period_write(size_t toWrite, size_t per, size_t bufferFrames) {
    if (per > 1 && per <= bufferFrames && (toWrite % per) != 0) toWrite = (toWrite / per) * per;
    return toWrite;
}

// 最近一次 write_available 的现场数字（WFAIL 明细用；只读，不改变行为）。
struct WriteDetail {
    long long pad = -1, room = -1, per = -1, avail = -1, toWrite = -1;
    long long gbHr = -999;   // IAudioRenderClient::GetBuffer 的 HRESULT（-999 = 本次未调用）
};


} // namespace rta::audio
