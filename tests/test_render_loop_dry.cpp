// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_render_loop_dry.cpp — C2/C3 遥测与端点消失回归（2026-10-24 N300 欠载）
//
// 被测对象是生产代码 src/audio/render_loop.h（rtaweb 播放线程跑的就是同一份循环，
// 铁律 3：不测拷贝）。mock sink 只替换设备 I/O，测试【绝不打开音频设备】（铁律 1）。
//
// 覆盖（方案 §8）：
//   · dry 计数：起播 500ms 后，pad==0 + 手里有数据 + 写不进去 ⟹ 计一次；500ms 内不计数
//   · pad>0 的写失败不算 dry（设备缓冲满 ≠ 欠载）
//   · dryms 与注入的 dry 时长一致（±50ms）
//   · STAT 新字段 per/bf/dry/dryms/ev/evint/prod 真的打印出来
//   · WFAIL 明细只打前 200 条，且带 room/per/avail/toWrite/zr
//   · C3：端点消失 ⟹ DEVICE_LOST + 「输出设备已断开」，且不提示回退共享
//   · C1 L2：起播 0.8s 有数据零写入 ⟹ 调 l2Degrade 重开 20ms，循环改用新缓冲
//
// ⚠️ 未验证（铁律 4）：真机（N300 / DC-Elite / MOTU）上的 dry 与 DEVICE_LOST 行为未复测；
//    本测试【仅 mock 验证】。STARVING 判据本身不在这里重测（test_renderfail 的 8 号用例
//    已钉住「健康设备不误报」），本文件的用例显式关闭 starveEnabled，避免两套判据互相干扰。
#include "audio/render_loop.h"
#include "audio/write_attrib.h"   // ZeroAttrib：生产用的「写不进去」归因分类器（与后端同一份）
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <string>
#include <vector>

#ifdef _WIN32
extern "C" __declspec(dllimport) int __stdcall SetConsoleOutputCP(unsigned int);
#endif
#ifndef CP_UTF8
#define CP_UTF8 65001
#endif

static int g_fail = 0;
static void ck(bool cond, const char* what, const std::string& detail = "") {
    if (cond) std::printf("  [PASS] %s\n", what);
    else { std::printf("  [FAIL] %s  %s\n", what, detail.c_str()); ++g_fail; }
}
static bool contains(const std::string& hay, const char* needle) {
    return hay.find(needle) != std::string::npos;
}
// 从 STAT 行里取某个整数字段（" dry=12" → 12）；找不到返回 -1。
static long long field(const std::string& line, const char* name) {
    const std::string key = std::string(" ") + name + "=";
    const size_t p = line.find(key);
    if (p == std::string::npos) return -1;
    return std::atoll(line.c_str() + p + key.size());
}
static std::string last_stat(const std::vector<std::string>& logs) {
    for (auto it = logs.rbegin(); it != logs.rend(); ++it)
        if (it->rfind("STAT ", 0) == 0) return *it;
    return {};
}
static int count_prefix(const std::vector<std::string>& logs, const char* prefix) {
    int n = 0;
    for (const auto& s : logs) if (s.rfind(prefix, 0) == 0) ++n;
    return n;
}

using rta::render::OutSink;
using rta::render::SinkOpenOpts;

// ---- mock：可编排的「写不进去」形态，虚拟时钟每 tick +20ms ----
// 水位按【第几次尝试】脚本化。pad_before_write() 必须与随后的 write_available() 看到
// 同一次尝试的水位 —— render_loop 在写之前采样，所以这里提前算「下一次」的脚本水位。
// （这不是为了迁就旧实现：判据本身没变，变的只是采样点必须精确对上本次尝试。）
struct ScriptSink : OutSink {
    ScriptSink(double* clk, long long bf, long long per, long long writePer)
        : clk_(clk), bf_(bf), per_(per), writePer_(writePer) {}

    bool open(const SinkOpenOpts&, uint32_t, int, int) override { return true; }
    bool start() override { return true; }
    size_t buffer_frames() const override { return (size_t)bf_; }
    long long device_period_frames() const override { return per_; }
    bool wait_event(int) override { *clk_ += 0.020; return true; }   // 每次都有事件

    // 第 callIdx 次尝试（1 基）是否写不进去，以及那一次的设备水位
    bool failFor(long long callIdx) const {
        if (dead_) return true;
        if (failFirstCalls_ > 0 && callIdx <= failFirstCalls_) return true;
        return failEvery_ > 0 && (callIdx % failEvery_) == 0;
    }
    long long levelFor(long long callIdx) const { return failFor(callIdx) ? failPad_ : padOnSuccess_; }
    // ★ 写前水位：render_loop 在写入【之前】调用它，所以返回「下一次尝试」的脚本值。
    long long pad_before_write() const override { return levelFor(calls_ + 1); }

    size_t write_one_period(const int32_t* p, size_t n) override { return write_available(p, n); }
    size_t write_available(const int32_t*, size_t n) override {
        if (n == 0) return 0;          // 没数据可写：不计入脚本拍子（否则与 dry 的 pend>0 错位）
        ++calls_;
        const long long lvl = levelFor(calls_);
        entryPad_ = lvl;
        pad_ = lvl;
        // dry 的判定口径与 render_loop 完全一致：起播 500ms 后、本次写入前 pad==0、有数据。
        // 注意「写成功」也算：设备缓冲已经触底，补上都来不及消除那段空窗（方案 §6.3）。
        if (lvl == 0 && *clk_ >= 0.5) ++eligible_;
        // 归因用生产分类器（src/audio/write_attrib.h），与 CoreAudio/WASAPI 后端同一份判据。
        const size_t room = lvl >= bf_ ? 0u : (size_t)(bf_ - lvl);
        // 缓冲满（脚本 failPad_==bf）或脚本要求这一拍失败 ⟹ 一帧也写不进去
        size_t w = (failFor(calls_) || lvl >= bf_) ? 0 : std::min(n, (size_t)writePer_);
        lastW_ = (long long)w;
        lastAvail_ = (long long)n;
        z_.classify(w, room, n, (size_t)per_);
        if (w > 0) pad_ = std::min<long long>(bf_, lvl + (long long)w);   // 写后水位（last_pad 显示用）
        return w;
    }
    long long last_pad() const override { return pad_; }
    const std::string& last_error() const override { return e_; }
    // 归因/WFAIL 明细：与 WasapiOutput::last_write_detail 同字段（pad 是写前水位）
    bool last_write_attempt(WriteAttempt& out) const override {
        out.pad = entryPad_; out.room = entryPad_ >= bf_ ? 0 : bf_ - entryPad_;
        out.per = per_; out.avail = lastAvail_; out.toWrite = lastW_; out.gbHr = 0;
        return true;
    }
    long long zero_pad_full() const override { return z_.padFull; }
    long long zero_starved() const override { return z_.starved; }
    long long zero_other() const override { return z_.other; }
    std::string zero_reason() const override { return z_.reason(); }

    double* clk_;
    long long bf_, per_, writePer_;
    long long failEvery_ = 0;       // 每 N 次调用失败一次
    long long failFirstCalls_ = 0;  // 前 N 次调用必失败
    long long failPad_ = 0;         // 失败时报告的设备水位（0 = 真·欠载；bf = 缓冲满）
    long long padOnSuccess_ = 4800; // 写成功时报告的设备水位（4800 = 健康，0 = 2 周期缓冲形态）
    bool dead_ = false;             // 永远写不进去
    long long eligible_ = 0;        // mock 自己数「应计 dry」的次数（时钟 ≥0.5s 且 pad==0）
    long long calls_ = 0;
    long long pad_ = 0;
    long long entryPad_ = 0, lastW_ = -1, lastAvail_ = 0;
    rta::audio::ZeroAttrib z_;      // 生产分类器：每个零写只落进一个桶（zp/zs/zo）
    std::string e_;
};

// ---- mock：端点已从系统枚举中消失（C3）----
struct LostSink : OutSink {
    explicit LostSink(double* clk) : clk_(clk) {}
    bool open(const SinkOpenOpts&, uint32_t, int, int) override { return true; }
    bool start() override { return true; }
    size_t buffer_frames() const override { return 9600; }
    long long device_period_frames() const override { return 960; }
    bool wait_event(int) override { *clk_ += 0.020; return true; }
    size_t write_one_period(const int32_t*, size_t) override { return 0; }
    size_t write_available(const int32_t*, size_t) override { pad_ = 9600; return 0; }
    long long last_pad() const override { return pad_; }
    bool endpoint_alive() const override { return false; }     // ← 端点消失
    const std::string& last_error() const override { return e_; }
    double* clk_;
    long long pad_ = 9600;
    std::string e_;
};

// ---- mock：L2 形态（Start 后流不推进；被要求降级后正常）----
struct L2Sink : OutSink {
    explicit L2Sink(double* clk) : clk_(clk) {}
    bool open(const SinkOpenOpts&, uint32_t, int, int) override { return true; }
    bool start() override { return true; }
    size_t buffer_frames() const override { return degraded_ ? 1920u : 9600u; }
    long long device_period_frames() const override { return 960; }
    bool wait_event(int) override { *clk_ += 0.020; return true; }
    size_t write_one_period(const int32_t* p, size_t n) override { return write_available(p, n); }
    size_t write_available(const int32_t*, size_t n) override {
        if (!degraded_) { pad_ = 9600; return 0; }      // 流不推进
        pad_ = 0;
        return std::min(n, (size_t)1920);
    }
    long long last_pad() const override { return pad_; }
    bool endpoint_alive() const override { return true; }
    const std::string& last_error() const override { return e_; }
    void degrade() { degraded_ = true; }
    bool degraded_ = false;
    double* clk_;
    long long pad_ = 9600;
    std::string e_;
};

// ---- mock：物理化设备（缓冲占用是【时间的函数】，写不进用生产分类器 ZeroAttrib 归因）----
// 与 ScriptSink 的区别（为什么需要它）：
//   ScriptSink 的水位是「第几次尝试」的脚本，天然不受采样点先后影响；真实设备不同 ——
//   写成功会把缓冲填高，所以「写前读」和「写后读」是两个不同的数。fastFeed 每轮都是先写，
//   写后缓冲就是满的；只要谁把 pad_before_write() 挪到写之后（或退回写后的 last_pad()），
//   dry 立刻恒为 0，而日志看起来「健康」。本 mock 让写前触底 / 写后变满同时成立，
//   于是 dry>0 只能来自正确的写前采样（铁律 3：判据必须能证明自己没失明）。
// 采样语义与 rtaweb 的 CoreAudioOutput::queued_frames() 同构：pad_before_write() 是实时读。
struct DeviceSink : OutSink {
    DeviceSink(double* clk, double rate, long long bf, long long per, double stallSec)
        : clk_(clk), rate_(rate), bf_(bf), per_(per), stall_(stallSec) {}

    bool open(const SinkOpenOpts&, uint32_t, int, int) override { return true; }
    bool start() override { return true; }
    size_t buffer_frames() const override { return (size_t)bf_; }
    long long device_period_frames() const override { return per_; }
    // 模型：请求等 5ms，但线程被调度拖到 stall_（过载/优先级不足的真实现场）
    bool wait_event(int) override { *clk_ += stall_; refresh(); return true; }
    long long last_pad() const override { refresh(); return pad_; }
    // ★ 实时读=调用这一刻的占用。render_loop 在写入【之前】采它 ⟹ 这就是写前水位。
    // samples_ 用来自证采样顺序（见 write_available 里的核对）：每次尝试都必须恰好先采一次。
    long long pad_before_write() const override { refresh(); ++samples_; return pad_; }
    size_t write_one_period(const int32_t* p, size_t n) override { return write_available(p, n); }
    size_t write_available(const int32_t*, size_t n) override {
        refresh();
        if (n == 0) return 0;
        // 采样顺序核对：正常是「每次尝试前恰好采一次」⟹ samples_ == attempts_ + 1。
        // 谁把 pad_before_write() 挪到写之后，这里立刻记到（判据不会静默失明）。
        if (samples_ != attempts_ + 1) ++sampleOrderBad_;
        ++attempts_;
        entryPad_ = pad_;
        // 独立于 render_loop 的「应计 dry」地面真值：写前触底 + 已过 500ms 门槛 + 手里有数据。
        // 有了它才能区分「设备确实没触底」与「判据失明」（两者在 STAT 里都表现为 dry=0）。
        if (entryPad_ == 0 && *clk_ >= 0.5) ++dryEntriesAfterGate_;
        lastAvail_ = (long long)n;
        const size_t room = (size_t)std::max<long long>(0, bf_ - pad_);
        size_t w = std::min<size_t>(n, room);
        w = rta::audio::quantize_period_write(w, (size_t)per_, (size_t)bf_);   // 整周期量化（与后端同构）
        lastW_ = (long long)w;
        z_.classify(w, room, n, (size_t)per_);
        if (w > 0) {
            if (entryPad_ == 0) ++zeroEntryWrites_;   // 写前已触底、这一拍却补上了 ⟹ dry 必须仍可见
            pad_ = std::min<long long>(bf_, pad_ + (long long)w);
        }
        if (afterAttempt) afterAttempt();          // 零写也要回调（否则「几次尝试后停」永远等不到）
        return w;
    }
    const std::string& last_error() const override { return e_; }
    bool last_write_attempt(WriteAttempt& o) const override {
        o.pad = entryPad_; o.room = entryPad_ >= bf_ ? 0 : bf_ - entryPad_;
        o.per = per_; o.avail = lastAvail_; o.toWrite = lastW_; o.gbHr = 0;
        return true;
    }
    long long zero_pad_full() const override { return z_.padFull; }
    long long zero_starved() const override { return z_.starved; }
    long long zero_other() const override { return z_.other; }
    std::string zero_reason() const override { return z_.reason(); }

    // 设备按墙钟消费：pad 与时钟严格同步（写成功也能看见它被吃掉）
    void refresh() const {
        const double dt = *clk_ - lastT_;
        if (dt <= 0.0) return;
        pad_ = std::max<long long>(0, pad_ - (long long)std::llround(rate_ * dt));
        lastT_ = *clk_;
    }

    double* clk_;
    double rate_;
    long long bf_, per_;
    double stall_;
    mutable long long pad_ = 0;
    mutable double lastT_ = 0.0;
    long long entryPad_ = 0, lastAvail_ = 0, lastW_ = -1;
    long long attempts_ = 0, zeroEntryWrites_ = 0;
    mutable long long samples_ = 0;   // pad_before_write() 被调用次数（采样顺序自证）
    long long sampleOrderBad_ = 0;    // 写之前没先采样（或重复采样）的次数
    long long dryEntriesAfterGate_ = 0;   // mock 自数的「应计 dry」尝试数（地面真值）
    rta::audio::ZeroAttrib z_;
    std::function<void()> afterAttempt;   // 测试用来在若干次尝试后停循环（不靠强杀、不靠超时判据）
    std::string e_;
};

struct Bench {
    std::atomic<bool> stop{false}, pauseReq{false}, paused{false};
    std::atomic<double> seekReq{-1.0};
    std::atomic<size_t> played{0};
    std::atomic<double> volDb{0.0}, startDb{0.0};
    std::atomic<long long> dbgPad{0};
    bool gpu = false;
    rta::render::RenderQ rq;
    std::atomic<long long> w0{0}, wr{0}, pulls{0}, clip{0};
    std::atomic<double> peak{0.0};
    std::atomic<long long> dry{0}, dryMs{0}, ev{0}, evInt{0}, prod{0};
    std::vector<std::string> logs;
    double clock = 0.0;

    rta::render::RenderHost make(uint32_t rate) {
        rta::render::RenderHost h;
        h.stop = &stop; h.pauseReq = &pauseReq; h.paused = &paused;
        h.seekReq = &seekReq; h.played = &played;
        h.volDb = &volDb; h.startDb = &startDb; h.dbgPad = &dbgPad; h.gpuOut = &gpu;
        h.rq = &rq;
        h.nowSec = [this]() { return clock; };
        h.deviceRate = rate; h.outBits = 24; h.outCh = 2;
        h.inRate = rate; h.inFrames = 2000000; h.totalOut = 2000000;
        h.dbgW0 = &w0; h.dbgWr = &wr; h.dbgPulls = &pulls; h.dbgClip = &clip; h.dbgPeak = &peak;
        h.dbgDry = &dry; h.dbgDryMs = &dryMs; h.dbgEv = &ev; h.dbgEvInt = &evInt; h.dbgProd = &prod;
        h.log = [this](const std::string& s) { logs.push_back(s); };
        h.deviceLabel = "扬声器 (mock)";
        h.deviceIdDesc = "{0.0.0.00000000}.{mock-endpoint}";
        h.fallbackEligible = true;
        h.dop = false;
        h.onShared = false;
        h.fastFeed = false; // 既有20ms虚拟时钟夹具固定旧调度；上方单独验证生产fastFeed。
        h.starveEnabled = false;     // 本文件只测 C2/C3；STARVING 由 test_renderfail 覆盖
        h.statPeriodSec = 1.0;       // 虚拟时钟下 1 秒一条 STAT，便于断言字段
        return h;
    }
    // 入队 frames 帧（2 ch / 24-bit 静音）；done=true 表示生产结束。
    void push_frames(size_t frames, bool done, size_t chunk = 4096) {
        size_t left = frames;
        while (left > 0) {
            const size_t n = left < chunk ? left : chunk;
            rta::audio::AudioBuffer b;
            b.rate = 96000; b.channels = 2; b.bits = 24;
            b.raw.assign(n * 2, 0);
            rq.q.emplace_back(std::move(b), rq.epoch.load());
            left -= n;
        }
        if (done) rq.done = true;
    }
    void feed_frames(size_t frames, size_t chunk = 4096) { push_frames(frames, true, chunk); }
    // 只喂一小段且【不关闭队列】：模拟「生产者一时供不上」——手里不足一个周期，
    // 但设备并没有拒绝数据（这是 zs=供料不足 的真实形态，不能冒充 pad 满）。
    void feed_partial(size_t frames, size_t chunk = 4096) { push_frames(frames, false, chunk); }
};

int main() {
#ifdef _WIN32
    SetConsoleOutputCP(CP_UTF8);
#endif
    std::printf("== render_loop_dry：dry/STAT/WFAIL/DEVICE_LOST/L2（mock）==\n");

    // Fast-feed must write queued data before its first wait; no physical audio.
    {
        struct FastSink : ScriptSink {
            using ScriptSink::ScriptSink;
            bool waitedBeforeFirstWrite = false;
            int maxWait = 0, waits = 0;
            bool wait_event(int ms) override {
                if (calls_ == 0) waitedBeforeFirstWrite = true;
                ++waits; maxWait = std::max(maxWait, ms); *clk_ += ms / 1000.0;
                return true;
            }
            size_t write_available(const int32_t* p, size_t n) override {
                // Accept one period then report full, so clock progresses via bounded waits.
                if (++attempts % 2 == 0) { ++calls_; pad_ = bf_; return 0; }
                return ScriptSink::write_available(p,n);
            }
            int attempts=0;
        };
        Bench b; b.feed_frames(96000); b.played.store(38400); auto h=b.make(96000); h.fastFeed=true;
        FastSink sink(&b.clock,9600,960,960);
        rta::render::render_loop(sink,h);
        ck(!sink.waitedBeforeFirstWrite,"fastFeed writes before waiting");
        ck(sink.waits>0 && sink.maxWait<=5,"fastFeed waits at most device period/2 (5 ms)");
        ck(h.normalEnd && !h.renderFail,"fastFeed completes queued audio");
        ck(b.played.load() >= 38400+96000,"resume retains initial played offset rather than resetting to zero");
    }

    // ---- 1z. 生产形态 fastFeed：设备真的触底时 dry 必须仍然可见，且 w0 == zp+zs+zo ----
    // 为什么这条不可省（铁律 3）：fastFeed 每轮先写，写【完】缓冲就是满的。只要谁把
    // pad_before_write() 挪到写之后（或退回写后的 last_pad()），dry 会恒为 0 —— 而日志里
    // 既没有 RENDERFAIL 也没有 error，看起来完全健康。本用例让「写前触底 + 写后变满」同时成立，
    // 于是 dry>0 只可能来自正确的写前采样。
    {
        std::printf("[fastFeed：dry 可见 + w0==zp+zs+zo]\n");
        Bench b;
        b.feed_frames(96000u * 8u);
        auto h = b.make(96000);
        h.fastFeed = true;                       // 生产默认调度
        // 2 个周期的 96k 缓冲（bf=1920 = 20ms 音频）+ 每次实际过去 25ms（线程被调度拖住）：
        // 设备真的会把缓冲吃空，我们补上，再吃空 —— 这就是 A 组形态在 fastFeed 下的样子。
        DeviceSink sink(&b.clock, 96000.0, /*bf=*/1920, /*per=*/960, /*stall=*/0.025);
        rta::render::render_loop(sink, h);
        ck(!h.renderFail, "间歇触底不触发 RENDERFAIL（设备仍在放）", h.failMsg);
        ck(b.wr.load() > 0, "确有写成功", std::to_string(b.wr.load()));
        ck(sink.zeroEntryWrites_ > 0,
           "「写前已触底、这一拍补上了」的写成功确实发生过（判据能力前提）",
           std::to_string(sink.zeroEntryWrites_));
        ck(b.dry.load() > 0, "fastFeed 下设备触底仍被 dry 计数（写成功也算）",
           "dry=" + std::to_string(b.dry.load()));
        ck(sink.sampleOrderBad_ == 0, "每次写尝试之前都恰好采了一次写前水位",
           std::to_string(sink.sampleOrderBad_) + " 次采样点错位");
        ck(b.dry.load() == sink.dryEntriesAfterGate_,
           "dry 次数 == mock 独立统计的触底尝试数（不是判据自说自话）",
           "dry=" + std::to_string(b.dry.load()) + " 注入=" + std::to_string(sink.dryEntriesAfterGate_));
        // ⚠️ 未解决（铁律 4）：dryms 在这个形态下必然是 0，不是 bug 但要知道它的含义。
        //   dry 的计时从「观测到触底」开始，到「下一次观测到 pad>0」结束；fastFeed 下
        //   写完立刻变满，下一次观测与本次同一虚拟时刻 ⟹ 时长 0。所以 fastFeed 形态
        //   只能用 dry（触底次数）判欠载，dryms 只对「连续多拍都触底」的形态有意义。
        ck(b.dryMs.load() >= 0, "dryms 不出现负数（0 是该形态下应有的值）",
           std::to_string(b.dryMs.load()));

        // ---- w0 的成因必须逐次闭合：w0 == zp + zs + zo ----
        const long long zp = sink.z_.padFull, zs = sink.z_.starved, zo = sink.z_.other;
        ck(zp > 0, "缓冲满计入 zp", std::to_string(zp));
        ck(b.w0.load() == zp + zs + zo, "w0 == zp+zs+zo（每次零写只落进一个桶）",
           "w0=" + std::to_string(b.w0.load()) + " zp=" + std::to_string(zp) +
           " zs=" + std::to_string(zs) + " zo=" + std::to_string(zo));
        ck(sink.attempts_ == b.wr.load() + b.w0.load(),
           "每次 write_available 都各记一次（wr+w0 == 尝试数）",
           "尝试=" + std::to_string(sink.attempts_) + " wr=" + std::to_string(b.wr.load()) +
           " w0=" + std::to_string(b.w0.load()));
        const std::string st = last_stat(b.logs);
        ck(!st.empty(), "fastFeed 下 STAT 有输出", st);
        ck(field(st, "dry") > 0, "STAT dry 反映触底", st);
        ck(field(st, "zo") >= 0, "STAT 打印 zo（三种成因都可见）", st);
        ck(field(st, "w0") == field(st, "zp") + field(st, "zs") + field(st, "zo"),
           "STAT 同一行自证 w0 == zp+zs+zo", st);
        std::printf("  样例 STAT: %s\n", st.c_str());
    }

    // ---- 1x. fastFeed 的负对照：设备没触底时必须 dry=0（零写 ≠ 欠载）----
    // 线程只被拖到 7ms（< 20ms 缓冲）⟹ 缓冲不会空，但会出现「可用空间不足一个周期」
    // （整周期量化后归零，zo）。这条钉住 dry 不是「任何 0 写入都算」：判据仍是 pad==0。
    {
        std::printf("[fastFeed：未触底 ⟹ dry=0（zo 才是成因）]\n");
        Bench b;
        b.feed_frames(96000u * 8u);
        auto h = b.make(96000);
        h.fastFeed = true;
        DeviceSink sink(&b.clock, 96000.0, /*bf=*/1920, /*per=*/960, /*stall=*/0.007);
        rta::render::render_loop(sink, h);
        ck(!h.renderFail, "无 RENDERFAIL", h.failMsg);
        ck(b.dry.load() == 0, "设备缓冲没触底 ⟹ dry=0", std::to_string(b.dry.load()));
        ck(sink.sampleOrderBad_ == 0, "采样点在写之前（负对照同样成立）",
           std::to_string(sink.sampleOrderBad_));
        ck(sink.dryEntriesAfterGate_ == 0, "设备确实一次都没触底（不是判据失明）",
           std::to_string(sink.dryEntriesAfterGate_));
        ck(sink.z_.other > 0, "空间不足一个周期计入 zo（不冒充 pad 满、也不算 dry）",
           std::to_string(sink.z_.other));
        ck(sink.z_.padFull > 0, "缓冲满计入 zp", std::to_string(sink.z_.padFull));
        ck(b.w0.load() == sink.z_.padFull + sink.z_.starved + sink.z_.other,
           "w0 == zp+zs+zo 闭合",
           "w0=" + std::to_string(b.w0.load()));
    }

    // ---- 1y. 供料不足一个周期（zs）：手里不足 per，设备并没有拒绝 ⟹ 不能冒充 zp ----
    {
        std::printf("[fastFeed：供料不足一个周期 → zs]\n");
        Bench b;
        b.feed_partial(300);                     // 只给 300 帧（< per=960），且不关闭队列
        auto h = b.make(96000);
        h.fastFeed = true;
        DeviceSink sink(&b.clock, 96000.0, /*bf=*/1920, /*per=*/960, /*stall=*/0.007);
        sink.afterAttempt = [&] { if (sink.attempts_ >= 2) b.stop.store(true); };  // 两次尝试后停
        rta::render::render_loop(sink, h);
        ck(!h.renderFail, "手里不足一个周期不判 RENDERFAIL（不是设备不接受数据）", h.failMsg);
        ck(sink.z_.starved > 0, "不足一个周期计入 zs", std::to_string(sink.z_.starved));
        ck(sink.z_.padFull == 0, "设备缓冲有空间 ⟹ 不冒充 pad 满", std::to_string(sink.z_.padFull));
        ck(b.w0.load() == sink.z_.padFull + sink.z_.starved + sink.z_.other,
           "w0 == zp+zs+zo 在 zs 形态下也闭合",
           "w0=" + std::to_string(b.w0.load()) + " zs=" + std::to_string(sink.z_.starved));
    }

    // ---- 1. dry 计数 + dryms：每 10 拍失败 1 次，失败时 pad==0 ----
    {
        std::printf("[dry/dryms]\n");
        Bench b;
        b.feed_frames(96000u * 8u);
        auto h = b.make(96000);
        ScriptSink sink(&b.clock, /*bf=*/9600, /*per=*/960, /*writePer=*/1920);
        sink.failEvery_ = 10;         // 每 10 次调用（200ms）失败一次
        rta::render::render_loop(sink, h);
        ck(!h.renderFail, "间歇欠载不触发 RENDERFAIL（吞吐正常）", h.failMsg);
        ck(sink.eligible_ > 0, "mock 确实注入了 pad==0 的写失败", std::to_string(sink.eligible_));
        ck(b.dry.load() == sink.eligible_,
           "dry 次数 == 注入的「pad==0 且写不进去」次数",
           "dry=" + std::to_string(b.dry.load()) + " 注入=" + std::to_string(sink.eligible_));
        const long long expectMs = sink.eligible_ * 20;   // 每拍 20ms，单拍故障
        ck(std::llabs((long long)b.dryMs.load() - expectMs) <= 50,
           "dryms ≈ 注入时长（±50ms）",
           "dryms=" + std::to_string(b.dryMs.load()) + " 期望≈" + std::to_string(expectMs));
        const std::string st = last_stat(b.logs);
        ck(!st.empty(), "虚拟时钟下 STAT 有输出", st);
        ck(field(st, "per") == 960, "STAT per = 设备周期帧数", st);
        ck(field(st, "bf") == 9600, "STAT bf = 缓冲帧数", st);
        ck(field(st, "dry") > 0, "STAT dry 反映了欠载", st);
        ck(field(st, "dryms") >= 0, "STAT dryms 存在", st);
        ck(field(st, "ev") > 0, "STAT ev = wait_event 命中次数", st);
        ck(field(st, "evint") == 20, "STAT evint = 20ms（mock 事件间隔）", st);
        ck(field(st, "prod") >= 0, "STAT prod 存在（pull_chunk 最长阻塞）", st);
    }

    // ---- 1b. A 组形态：2 个周期的 20ms 缓冲，每次轮询 pad 都已触底（但都补上了）----
    // 这是方案 §2 的现场形态（pad==0 占 85.7%、吞吐仍 1.0）。旧代码的 STARVING 看吞吐率
    // 永远看不见它；新 dry 必须在【写成功】时也能计数，否则判据又失明。
    {
        std::printf("[A 组形态：2 周期缓冲 pad 触底]\n");
        Bench b;
        b.feed_frames(96000u * 8u);
        auto h = b.make(96000);
        ScriptSink sink(&b.clock, /*bf=*/1920, /*per=*/960, /*writePer=*/1920);
        sink.padOnSuccess_ = 0;      // 设备在每次轮询时都是空的
        rta::render::render_loop(sink, h);
        ck(!h.renderFail, "吞吐正常：每次都补上了，无 RENDERFAIL", h.failMsg);
        ck(b.dry.load() > 0, "pad 触底的轮询被 dry 计数（即使这一拍写成功）",
           std::to_string(b.dry.load()));
        ck(b.dry.load() == sink.eligible_, "dry 次数 == mock 统计的触底轮询数",
           "dry=" + std::to_string(b.dry.load()) + " 注入=" + std::to_string(sink.eligible_));
        ck(b.dryMs.load() > 7000, "dryms 累计处于触底状态的墙钟（≈7.5s）",
           std::to_string(b.dryMs.load()));
    }

    // ---- 1c. B 组形态：10 个周期的 100ms 缓冲，pad 不触底 ⟹ dry=0（M2 判据形态）----
    {
        std::printf("[B 组形态：10 周期缓冲 pad 不触底]\n");
        Bench b;
        b.feed_frames(96000u * 8u);
        auto h = b.make(96000);
        ScriptSink sink(&b.clock, /*bf=*/9600, /*per=*/960, /*writePer=*/1920);
        sink.padOnSuccess_ = 4800;   // 设备缓冲里始终有货
        rta::render::render_loop(sink, h);
        ck(b.dry.load() == 0, "pad 不触底 ⟹ dry=0", std::to_string(b.dry.load()));
        ck(b.dryMs.load() == 0, "dryms=0", std::to_string(b.dryMs.load()));
        ck(!h.renderFail, "B 组形态无 RENDERFAIL");
    }

    // ---- 2. 起播 500ms 内不计数 ----
    {
        std::printf("[500ms 门槛]\n");
        Bench b;
        b.feed_frames(96000u * 4u);
        auto h = b.make(96000);
        ScriptSink sink(&b.clock, 9600, 960, 1920);
        sink.failFirstCalls_ = 20;    // 前 20 拍（= 0.4s）全失败，之后正常
        rta::render::render_loop(sink, h);
        ck(b.w0.load() >= 20, "确实发生了 20 次写失败", std::to_string(b.w0.load()));
        ck(b.dry.load() == 0, "起播 500ms 内的写失败不计 dry", "dry=" + std::to_string(b.dry.load()));
        ck(b.dryMs.load() == 0, "起播 500ms 内 dryms 仍为 0", std::to_string(b.dryMs.load()));
    }

    // ---- 3. pad>0（设备缓冲满）的写失败不算 dry ----
    {
        std::printf("[pad 满 ≠ 欠载]\n");
        Bench b;
        b.feed_frames(96000u * 4u);
        auto h = b.make(96000);
        ScriptSink sink(&b.clock, 9600, 960, 1920);
        sink.dead_ = true;            // 永远写不进去
        sink.failPad_ = 9600;         // 但设备缓冲是满的（不是我们欠载）
        rta::render::render_loop(sink, h);
        ck(b.w0.load() > 0, "确实有写失败", std::to_string(b.w0.load()));
        ck(b.dry.load() == 0, "pad 满导致的写失败不计 dry", "dry=" + std::to_string(b.dry.load()));
        ck(h.renderFail, "持续 4 秒不接受数据仍按 RENDERFAIL 归因");
        // 旧时序（fastFeed=false）同样要能自证归因没丢数：缓冲满只进 zp 桶。
        ck(sink.z_.padFull > 0 && sink.z_.starved == 0 && sink.z_.other == 0,
           "缓冲满只计 zp（不混进 zs/zo）",
           "zp=" + std::to_string(sink.z_.padFull) + " zs=" + std::to_string(sink.z_.starved) +
           " zo=" + std::to_string(sink.z_.other));
        ck(b.w0.load() == sink.z_.padFull + sink.z_.starved + sink.z_.other,
           "旧时序下 w0 == zp+zs+zo 也闭合",
           "w0=" + std::to_string(b.w0.load()));
    }

    // ---- 4. WFAIL 明细：前 200 条 + 字段齐全 ----
    {
        std::printf("[WFAIL 前 200 条]\n");
        Bench b;
        b.feed_frames(96000u * 4u);
        auto h = b.make(96000);
        ScriptSink sink(&b.clock, 9600, 960, 1920);
        sink.dead_ = true;
        sink.failPad_ = 9600;
        rta::render::render_loop(sink, h);
        const int n = count_prefix(b.logs, "WFAIL ");
        ck(n > 0, "写失败有 WFAIL 明细", std::to_string(n));
        ck(n <= 200, "WFAIL 最多 200 条（不刷爆日志）", std::to_string(n));
        std::string first;
        for (const auto& s : b.logs) if (s.rfind("WFAIL ", 0) == 0) { first = s; break; }
        ck(contains(first, "t=") && contains(first, "pad=9600"), "WFAIL 带 t 与 pad", first);
        ck(contains(first, "room=0") && contains(first, "per=960"), "WFAIL 带 room/per", first);
        ck(contains(first, "avail=") && contains(first, "toWrite=0"),
           "WFAIL 带 avail 与量化后的 toWrite", first);
        ck(contains(first, "gb_hr="), "WFAIL 带 GetBuffer HRESULT", first);
        ck(contains(first, "zr="), "WFAIL 带归因 zr", first);
        std::printf("  样例 WFAIL: %s\n", first.c_str());
    }

    // ---- 5. C3：端点消失 ⟹ DEVICE_LOST，如实报「输出设备已断开」----
    {
        std::printf("[DEVICE_LOST]\n");
        Bench b;
        b.feed_frames(96000u * 4u);
        auto h = b.make(96000);
        LostSink sink(&b.clock);
        rta::render::render_loop(sink, h);
        ck(h.renderFail, "设备消失 ⟹ renderFail");
        ck(h.deviceLost, "deviceLost 置位（调用方据此不回退共享）");
        ck(contains(h.failMsg, "输出设备已断开"), "ps.error 文案 = 输出设备已断开", h.failMsg);
        ck(contains(h.failMsg, "USB"), "文案说明是 USB 掉线这类物理断开", h.failMsg);
        ck(contains(h.failMsg, "不自动回退") && contains(h.failMsg, "不从头重播"),
           "文案明确不降级、不重播", h.failMsg);
        ck(!contains(h.failMsg, "已自动回退"), "没有「已自动回退共享」这种误导", h.failMsg);
        ck(count_prefix(b.logs, "DEVICE_LOST ") == 1, "play_log 里有一条 DEVICE_LOST",
           std::to_string(count_prefix(b.logs, "DEVICE_LOST ")));
        for (const auto& s : b.logs)
            if (s.rfind("DEVICE_LOST ", 0) == 0) { std::printf("  样例 DEVICE_LOST: %s\n", s.c_str()); break; }
        std::printf("  样例 ps.error: %s\n", h.failMsg.c_str());
    }

    // ---- 6. C1 L2：起播 0.8s 有数据零写入 ⟹ 降级 20ms 后继续播 ----
    {
        std::printf("[L2 起播看门狗]\n");
        Bench b;
        b.feed_frames(96000u * 8u);
        auto h = b.make(96000);
        L2Sink sink(&b.clock);
        int hookCalls = 0;
        h.l2Degrade = [&]() { ++hookCalls; sink.degrade(); return true; };
        rta::render::render_loop(sink, h);
        ck(hookCalls == 1, "L2 只尝试一次", std::to_string(hookCalls));
        ck(sink.degraded_, "L2 确实重开了 20ms");
        ck(!h.renderFail, "降级后正常播放，不触发 RENDERFAIL", h.failMsg);
        ck(h.normalEnd, "降级后播完（normalEnd）");
        bool sawNewBf = false;
        for (const auto& s : b.logs)
            if (s.rfind("STAT ", 0) == 0 && field(s, "bf") == 1920) sawNewBf = true;
        ck(sawNewBf, "降级后 STAT bf 变成 1920（循环重取了 period）");
        bool sawNote = false;
        for (const auto& s : b.logs)
            if (s.rfind("BUFPOLICY l2_degraded", 0) == 0) sawNote = true;
        ck(sawNote, "日志留下 BUFPOLICY l2_degraded 归因");
    }

    std::printf("\n%s（失败 %d 项）\n", g_fail == 0 ? "render_loop_dry 全部通过" : "存在失败", g_fail);
    return g_fail == 0 ? 0 : 1;
}
