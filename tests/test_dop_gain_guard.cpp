// test_dop_gain_guard.cpp — DoP/DSD 输出时软件音量必须被强制为 0 dB（2026-10-25）
//
// 为什么必须有这条门禁（真实风险，不是假想）：
//   DoP 把 DSD 位流装进 24-bit PCM 容器，靠高 8 位**交替的 0x05 / 0xFA 标记**让 DAC
//   识别出「这是 DSD，不是普通 PCM」。任何软件增益都会改写这些字节 ⟹ 标记失效
//   ⟹ DAC 把 DSD 当普通 PCM 播 ⟹ 输出**刺耳白噪音**（不是「声音变小」，是彻底坏掉）。
//
//   2026-10-25 修音量失效时发现：render_loop 每 tick 无条件调
//   `sink.set_live_gain_db(volDb - startDb)`，DoP 路径**没有任何保护**。
//   一旦音量修复生效（set_live_gain_db 真的作用到数据），DoP + 非 0 dB 就会炸。
//   所以音量修复与这条保护必须同时存在。
//
// 判据（mock sink 记录收到的增益，纯离线不碰设备 —— 铁律 1）：
//   1. dop == true  + 请求 -20 dB → sink 收到的增益必须是 0.0
//   2. dop == false + 请求 -20 dB → sink 收到的增益必须是 -20.0（对照，证明不是一律清零）
//   3. dop == true  + 请求 0 dB   → sink 收到的增益是 0.0（本来就不该衰减）
#include "audio/render_loop.h"
#include <atomic>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

static int fails = 0;
static void ck(bool ok, const char* what, const std::string& detail = "") {
    std::printf("  [%s] %s %s\n", ok ? "PASS" : "FAIL", what, detail.c_str());
    if (!ok) ++fails;
}

// 记录最近一次收到的 live gain，其余行为照常（不碰设备）
struct GainSpySink : rta::render::OutSink {
    std::atomic<double> lastGain{999.0};
    std::atomic<int>    gainCalls{0};
    bool open(const rta::render::SinkOpenOpts&, uint32_t, int, int) override { return true; }
    bool start() override { return true; }
    size_t buffer_frames() const override { return 1024; }
    size_t write_one_period(const int32_t*, size_t n) override { return n; }
    size_t write_available(const int32_t*, size_t n) override { return n; }
    const std::string& last_error() const override { static std::string s; return s; }
    long long last_pad() const override { return 0; }          // 独占：永远有空间
    bool wait_event(int) override { return true; }
    void set_live_gain_db(double db) override {
        lastGain.store(db);
        gainCalls.fetch_add(1);
    }
};

// 跑 render_loop 一小段，返回 sink 收到的最后一次增益
static double run_once(bool dop, double volDb, double startDb) {
    GainSpySink sink;
    rta::render::RenderQ rq;
    std::atomic<bool> abortFlag{false};
    rq.abort.store(false);

    // 灌一段数据，够循环跑几 tick
    for (int i = 0; i < 8; ++i) {
        rta::audio::AudioBuffer b;
        b.rate = 176400; b.channels = 2; b.bits = 24;
        b.raw.assign(4096 * 2, 0);
        rq.q.emplace_back(std::move(b), rq.epoch.load());
    }

    // 必需指针一个都不能少 —— 缺任何一个都会 segfault
    // （实测踩过：只接 volDb/startDb 直接 SIGSEGV，因为循环一进去就解引用 stop/pauseReq…）
    std::atomic<bool>     stop{false}, pauseReq{false}, paused{false};
    std::atomic<double>   seekReq{-1.0};
    std::atomic<size_t>   played{0};
    std::atomic<double>   vol{volDb}, start{startDb};
    std::atomic<long long> dbgPad{0};
    bool gpuOut = false;
    std::atomic<long long> w0{0}, wr{0}, pulls{0}, clip{0}, dry{0}, dryMs{0}, ev{0}, evInt{0}, prod{0};
    std::atomic<double> peak{0.0};
    double clock = 0.0;

    rta::render::RenderHost h;
    h.stop = &stop; h.pauseReq = &pauseReq; h.paused = &paused;
    h.seekReq = &seekReq; h.played = &played;
    h.volDb = &vol; h.startDb = &start;
    h.dbgPad = &dbgPad; h.gpuOut = &gpuOut;
    h.rq = &rq;
    h.deviceRate = 176400; h.outBits = 24; h.outCh = 2;
    h.inRate = 176400; h.inFrames = 8ull * 4096; h.totalOut = 8ull * 4096;
    h.dbgW0 = &w0; h.dbgWr = &wr; h.dbgPulls = &pulls; h.dbgClip = &clip; h.dbgPeak = &peak;
    h.dbgDry = &dry; h.dbgDryMs = &dryMs; h.dbgEv = &ev; h.dbgEvInt = &evInt; h.dbgProd = &prod;
    h.dop = dop;                       // ← 被测开关
    h.onShared = false;
    h.starveEnabled = false;
    h.statPeriodSec = 1000.0;          // 不刷 STAT
    h.deviceLabel = "mock";
    h.deviceIdDesc = "mock";
    h.log = [](const std::string&) {};

    // 让虚拟时钟每 tick 前进，避免无限循环（循环内部会读 nowSec）
    h.nowSec = [&clock]() { clock += 0.001; return clock; };

    // 队列标记 done：循环播完这几块就退出（不标会死循环 —— 实测踩过）
    {
        std::lock_guard<std::mutex> lk(rq.mtx);
        rq.done = true;
    }
    // 兜底：万一循环没按预期退出（例如实现变更），由 stop 强制结束
    h.nowSec = [&clock, &stop]() {
        clock += 0.001;
        if (clock > 5.0) stop.store(true);   // 虚拟 5 秒后强制停
        return clock;
    };

    rta::render::render_loop(sink, h);
    return sink.lastGain.load();
}

int main() {
    std::printf("=== test_dop_gain_guard: DoP 输出时软件音量必须锁 0 dB ===\n");
    std::printf("（mock sink 记录增益，不打开任何音频设备 —— 铁律 1）\n\n");

    std::printf("-- 1. dop=true + 请求 -20 dB → 必须被强制为 0 dB --\n");
    {
        const double g = run_once(true, -20.0, 0.0);
        ck(std::fabs(g - 0.0) < 1e-9,
           "DoP 路径强制 0 dB（保护 DoP 标记字节）",
           "got=" + std::to_string(g) + "（若为 -20 则 DoP 标记会被破坏）");
    }

    std::printf("\n-- 2. dop=false + 请求 -20 dB → 必须真的是 -20 dB（对照）--\n");
    {
        const double g = run_once(false, -20.0, 0.0);
        ck(std::fabs(g - (-20.0)) < 1e-9,
           "PCM 路径正常应用 -20 dB（证明不是一律清零）",
           "got=" + std::to_string(g));
        // 反证：如果实现是「永远 set_live_gain_db(0)」，这里会是 0 —— 判据能分辨
        ck(std::fabs(g - 0.0) > 1e-9,
           "判据有分辨力：PCM 路径不会误报成 0 dB");
    }

    std::printf("\n-- 3. dop=true + 请求 0 dB → 仍是 0 dB --\n");
    {
        const double g = run_once(true, 0.0, 0.0);
        ck(std::fabs(g - 0.0) < 1e-9, "DoP + 0 dB 保持 0 dB", "got=" + std::to_string(g));
    }

    std::printf("\n-- 4. dop=true + 请求 -60 dB（用户拉到很低）→ 仍锁 0 dB --\n");
    {
        const double g = run_once(true, -60.0, 0.0);
        ck(std::fabs(g - 0.0) < 1e-9,
           "DoP 下任何音量请求都锁 0 dB（宁可不变小，也不能出白噪音）",
           "got=" + std::to_string(g));
    }

    std::printf("\n=== %s（%d 失败）===\n", fails ? "FAIL" : "PASS", fails);
    return fails ? 1 : 0;
}

// 红→绿演示（铁律 3）：
//   把 render_loop.h 的 `if (h.dop) sink.set_live_gain_db(0.0); else ...` 改回
//   无条件 `sink.set_live_gain_db(h.volDb->load() - h.startDb->load());`，
//   判据 1 与 4 立即变红：
//     [FAIL] DoP 路径强制 0 dB  got=-20.000000（若为 -20 则 DoP 标记会被破坏）
//     [FAIL] DoP 下任何音量请求都锁 0 dB  got=-60.000000
