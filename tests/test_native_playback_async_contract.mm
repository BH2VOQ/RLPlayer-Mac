// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_playback_async_contract.mm — 原生播放异步并发与状态契约测试（真实延迟回调）
//
// 验证：
//   C1 RLPCoreClient：写队列严格串行（POST 不乱序），读队列保持并发且不被慢写阻塞
//   C2 RLPPlaybackBarView：fetchStatus inflight/epoch 保护，旧回包不覆盖新状态
//   C3 RLPPlaybackBarView + RLPQuickStartViewController：
//      动作完成后主动刷新状态；QuickStart 停止态重播 /api/play（非 pause no-op）；
//      暂停态连点不反向引入错暂停；QuickStart reloadStatus 旧回包不覆盖新状态
//   C4 RLPPlayWholeListFrom：多段异步竞争下 generation 最新意图胜出，覆盖所有后续副作用
//      （含 GET /api/playmode、POST /api/playmode?mode=1、POST /api/queue/set、POST /api/play）
//
// 铁律：不启动真实播放核心、不打开音频设备（backend=null, volDb=-120）、不触碰 8899。
#import <AppKit/AppKit.h>

#import "RLPCoreClient.h"
#import "RLPPlaybackBarView.h"
#import "RLPQuickStartViewController.h"
#import "RLPRightDrawer.h"
#import "RLPModels.h"
#import "RLPSupport.h"
#import "rlapp_core.h"

@interface RLPRightDrawer (AsyncContractTestAccess)
- (void)playIndex:(NSInteger)i;
@end

#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#pragma mark - 真实 rlapp::dispatch 延迟/门控桩

namespace {

struct Gate {
    std::mutex mu;
    std::condition_variable cv;
    bool armed = false;
    bool entered = false;
    bool released = false;

    void arm() {
        std::lock_guard<std::mutex> lk(mu);
        armed = true;
        entered = false;
        released = false;
    }
    bool tryConsumeArmed() {
        std::lock_guard<std::mutex> lk(mu);
        if (!armed) return false;
        armed = false;
        entered = true;
        cv.notify_all();
        return true;
    }
    void waitReleased() {
        std::unique_lock<std::mutex> lk(mu);
        cv.wait(lk, [this] { return released; });
    }
    void waitIfArmed() {
        if (tryConsumeArmed()) waitReleased();
    }
    bool hasEntered() {
        std::lock_guard<std::mutex> lk(mu);
        return entered;
    }
    bool waitEntered(int timeoutMs = 2000) {
        std::unique_lock<std::mutex> lk(mu);
        return cv.wait_for(lk, std::chrono::milliseconds(timeoutMs), [this] { return entered; });
    }
    void release() {
        std::lock_guard<std::mutex> lk(mu);
        armed = false;
        released = true;
        cv.notify_all();
    }
};

struct PostRecord {
    std::string path;
    std::string body;
};

std::mutex g_mu;
std::vector<std::string> g_trace;
std::vector<PostRecord> g_posts;
std::atomic<int> g_activeReads{0};
std::atomic<int> g_maxConcurrentReads{0};
std::atomic<int> g_statusCount{0};

// 播放状态夹具
bool g_playing = false;
bool g_paused = false;
std::string g_current = "/tmp/async-contract-fixture.aiff";
std::string g_statusError;
std::string g_playError;
std::string g_libPlayError;
std::string g_skipError;
int g_playmode = 0;

// 可选延迟与门控
Gate g_statusGate;
std::string g_statusGatePayload;
Gate g_pausePostGate;
int g_pausePostDelayMs = 0;
Gate g_playmodeGetGate;
int g_playmodeGetGateMode = 2;
Gate g_playmodePostGate;
Gate g_queueSetGate;
Gate g_playPostGate;
std::string g_playGateError;
Gate g_skipPostGate;
std::string g_skipGateError;

void UpdateMaxReads(int cur) {
    int prev = g_maxConcurrentReads.load();
    while (cur > prev && !g_maxConcurrentReads.compare_exchange_weak(prev, cur)) {}
}

void ResetMockState() {
    std::lock_guard<std::mutex> lk(g_mu);
    g_trace.clear();
    g_posts.clear();
    g_activeReads = 0;
    g_maxConcurrentReads = 0;
    g_statusCount = 0;
    g_playing = false;
    g_paused = false;
    g_current = "/tmp/async-contract-fixture.aiff";
    g_statusError.clear();
    g_playError.clear();
    g_libPlayError.clear();
    g_skipError.clear();
    g_playmode = 0;
    g_statusGatePayload.clear();
    g_pausePostDelayMs = 0;
    g_statusGate.release();
    g_pausePostGate.release();
    g_playmodeGetGate.release();
    g_playmodePostGate.release();
    g_queueSetGate.release();
    g_playGateError.clear();
    g_skipGateError.clear();
    g_playPostGate.release();
    g_skipPostGate.release();
}

std::string MakeStatusJSON(bool playing, bool paused, const std::string& cur) {
    return std::string("{\"ok\":true,\"playing\":") + (playing ? "true" : "false") +
           ",\"paused\":" + (paused ? "true" : "false") +
           ",\"current\":\"" + cur + "\"" +
           ",\"error\":\"" + g_statusError + "\"" +
           ",\"dur\":180,\"pos\":15,\"volDb\":-120,\"backend\":\"null\"}";
}

} // namespace

namespace rlapp {

bool start_embedded() { return true; }
void request_shutdown() {}
void stop_embedded() {}
bool exit_requested() { return false; }
std::string diag_json(std::size_t) { return "{}"; }
int max_concurrent_dispatches() { return g_maxConcurrentReads.load(); }
long long dispatch_count() { return 0; }
void reset_dispatch_probe() { g_maxConcurrentReads = 0; }
int cli_main(int, char**) { return 0; }

std::string dispatch(const rta::net::HttpRequest& req, std::string& contentType) {
    contentType = "application/json";
    const std::string& m = req.method;
    const std::string& p = req.path;

    // C1 读写并发与串行测试路由
    if (m == "POST" && p == "/api/test/w1") {
        { std::lock_guard<std::mutex> lk(g_mu); g_trace.push_back("POST:w1:enter"); }
        std::this_thread::sleep_for(std::chrono::milliseconds(60));
        { std::lock_guard<std::mutex> lk(g_mu); g_trace.push_back("POST:w1:exit"); }
        return "{\"ok\":true}";
    }
    if (m == "POST" && p == "/api/test/w2") {
        { std::lock_guard<std::mutex> lk(g_mu); g_trace.push_back("POST:w2:enter"); g_trace.push_back("POST:w2:exit"); }
        return "{\"ok\":true}";
    }
    if (m == "POST" && p == "/api/test/w3") {
        { std::lock_guard<std::mutex> lk(g_mu); g_trace.push_back("POST:w3:enter"); g_trace.push_back("POST:w3:exit"); }
        return "{\"ok\":true}";
    }
    if (m == "GET" && (p == "/api/test/r1" || p == "/api/test/r2")) {
        int cur = ++g_activeReads;
        UpdateMaxReads(cur);
        std::this_thread::sleep_for(std::chrono::milliseconds(60));
        --g_activeReads;
        return "{\"ok\":true}";
    }
    if (m == "GET" && p == "/api/test/rfast") {
        { std::lock_guard<std::mutex> lk(g_mu); g_trace.push_back("GET:rfast:exit"); }
        return "{\"ok\":true}";
    }

    if (m == "POST") {
        if (p.rfind("/api/pause", 0) == 0) {
            if (g_pausePostDelayMs > 0) {
                std::this_thread::sleep_for(std::chrono::milliseconds(g_pausePostDelayMs));
            }
            g_pausePostGate.waitIfArmed();
            std::lock_guard<std::mutex> lk(g_mu);
            g_posts.push_back({p, req.body});
            if (p.find("on=1") != std::string::npos) { g_playing = true; g_paused = true; }
            else if (p.find("on=0") != std::string::npos) { g_playing = true; g_paused = false; }
            return "{\"ok\":true}";
        }
        if (p == "/api/play") {
            if (g_playPostGate.tryConsumeArmed()) {
                std::string gatedErr = g_playGateError;
                g_playPostGate.waitReleased();
                std::lock_guard<std::mutex> lk(g_mu);
                g_posts.push_back({p, req.body});
                if (!gatedErr.empty()) {
                    return std::string("{\"ok\":false,\"error\":\"") + gatedErr + "\"}";
                }
                g_playing = true;
                g_paused = false;
                return "{\"ok\":true}";
            }
            std::lock_guard<std::mutex> lk(g_mu);
            g_posts.push_back({p, req.body});
            if (!g_playError.empty()) {
                return std::string("{\"ok\":false,\"error\":\"") + g_playError + "\"}";
            }
            g_playing = true;
            g_paused = false;
            return "{\"ok\":true}";
        }
        if (p == "/api/lib/play") {
            std::lock_guard<std::mutex> lk(g_mu);
            g_posts.push_back({p, req.body});
            if (!g_libPlayError.empty()) {
                return std::string("{\"ok\":false,\"error\":\"") + g_libPlayError + "\"}";
            }
            g_playing = true;
            g_paused = false;
            return "{\"ok\":true}";
        }
        if (p.rfind("/api/skip", 0) == 0) {
            if (g_skipPostGate.tryConsumeArmed()) {
                std::string gatedErr = g_skipGateError;
                g_skipPostGate.waitReleased();
                std::lock_guard<std::mutex> lk(g_mu);
                g_posts.push_back({p, req.body});
                if (!gatedErr.empty()) {
                    return std::string("{\"ok\":false,\"error\":\"") + gatedErr + "\"}";
                }
                return "{\"ok\":true}";
            }
            std::lock_guard<std::mutex> lk(g_mu);
            g_posts.push_back({p, req.body});
            if (!g_skipError.empty()) {
                return std::string("{\"ok\":false,\"error\":\"") + g_skipError + "\"}";
            }
            return "{\"ok\":true}";
        }
        if (p == "/api/stop") {
            std::lock_guard<std::mutex> lk(g_mu);
            g_posts.push_back({p, req.body});
            g_playing = false;
            g_paused = false;
            return "{\"ok\":true}";
        }
        if (p.rfind("/api/playmode", 0) == 0) {
            g_playmodePostGate.waitIfArmed();
            std::lock_guard<std::mutex> lk(g_mu);
            g_posts.push_back({p, req.body});
            if (p.find("mode=1") != std::string::npos) g_playmode = 1;
            return "{\"ok\":true}";
        }
        if (p == "/api/queue/set") {
            g_queueSetGate.waitIfArmed();
            std::lock_guard<std::mutex> lk(g_mu);
            g_posts.push_back({p, req.body});
            return "{\"ok\":true}";
        }
        std::lock_guard<std::mutex> lk(g_mu);
        g_posts.push_back({p, req.body});
        return "{\"ok\":true}";
    }

    // GET 路由
    if (p.rfind("/api/status", 0) == 0) {
        ++g_statusCount;
        if (g_statusGate.tryConsumeArmed()) {
            std::string payload = g_statusGatePayload;
            g_statusGate.waitReleased();
            return payload;
        }
        std::lock_guard<std::mutex> lk(g_mu);
        return MakeStatusJSON(g_playing, g_paused, g_current);
    }
    if (p.rfind("/api/playmode", 0) == 0) {
        if (g_playmodeGetGate.tryConsumeArmed()) {
            int gatedMode = g_playmodeGetGateMode;
            g_playmodeGetGate.waitReleased();
            return std::string("{\"ok\":true,\"mode\":") + std::to_string(gatedMode) + "}";
        }
        std::lock_guard<std::mutex> lk(g_mu);
        return std::string("{\"ok\":true,\"mode\":") + std::to_string(g_playmode) + "}";
    }
    if (p.rfind("/api/settings", 0) == 0) {
        return "{\"ok\":true,\"kv\":{\"backend\":\"null\",\"device\":\"\",\"hogexcl\":\"0\"}}";
    }
    if (p.rfind("/api/devices", 0) == 0) return "{\"ok\":true,\"devices\":[]}";
    if (p.rfind("/api/filters", 0) == 0) return "{\"ok\":true,\"items\":[]}";
    if (p.rfind("/api/lib/roots", 0) == 0) return "{\"ok\":true,\"roots\":[]}";
    if (p.rfind("/api/lib/albums", 0) == 0) return "{\"ok\":true,\"albums\":[]}";
    if (p.rfind("/api/queue", 0) == 0) return "{\"ok\":true,\"items\":[],\"metas\":[],\"index\":-1}";
    if (p.rfind("/api/meta", 0) == 0) return "{\"ok\":true,\"title\":\"Fixture\"}";
    if (p.rfind("/api/cover", 0) == 0) { contentType = "application/octet-stream"; return ""; }
    return "{\"ok\":true}";
}

} // namespace rlapp

#pragma mark - 辅助工具

static int g_pass = 0, g_fail = 0;
static void ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++g_fail; }
}

static void Pump(NSTimeInterval seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

static BOOL WaitUntil(NSTimeInterval timeout, BOOL (^pred)(void)) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([until timeIntervalSinceNow] > 0) {
        if (pred()) return YES;
        Pump(0.015);
    }
    return pred();
}

static NSInteger IndexInTrace(const std::vector<std::string>& trace, const std::string& item) {
    for (size_t i = 0; i < trace.size(); ++i) {
        if (trace[i] == item) return (NSInteger)i;
    }
    return -1;
}

static std::vector<PostRecord> SnapshotPosts() {
    std::lock_guard<std::mutex> lk(g_mu);
    return g_posts;
}

static void ClearPosts() {
    std::lock_guard<std::mutex> lk(g_mu);
    g_posts.clear();
}

int main() {
    @autoreleasepool {
        std::printf("== 原生播放异步并发与状态契约测试（真实延迟回调，null/-120）==\n");
        [NSApplication sharedApplication];
        RLPCoreClient *client = [RLPCoreClient shared];
        [client startEmbedded];

        // ====================================================================
        // C1: CoreClient 写队列严格串行，读队列保持并发且不被慢写阻塞
        // ====================================================================
        ResetMockState();
        __block int c1Done = 0;
        [client postJSON:@"/api/test/w1" body:nil completion:^(NSDictionary *j) { (void)j; ++c1Done; }];
        [client postJSON:@"/api/test/w2" body:nil completion:^(NSDictionary *j) { (void)j; ++c1Done; }];
        [client postData:@"/api/test/w3" body:[NSData dataWithBytes:"x" length:1] contentType:@"application/octet-stream"
              completion:^(NSDictionary *j) { (void)j; ++c1Done; }];
        [client getJSON:@"/api/test/r1" completion:^(NSDictionary *j) { (void)j; ++c1Done; }];
        [client getJSON:@"/api/test/r2" completion:^(NSDictionary *j) { (void)j; ++c1Done; }];
        [client getJSON:@"/api/test/rfast" completion:^(NSDictionary *j) { (void)j; ++c1Done; }];

        BOOL allDone = WaitUntil(3.0, ^BOOL { return c1Done == 6; });
        std::vector<std::string> trace;
        { std::lock_guard<std::mutex> lk(g_mu); trace = g_trace; }
        NSInteger w1Exit = IndexInTrace(trace, "POST:w1:exit");
        NSInteger w2Enter = IndexInTrace(trace, "POST:w2:enter");
        NSInteger w2Exit = IndexInTrace(trace, "POST:w2:exit");
        NSInteger w3Enter = IndexInTrace(trace, "POST:w3:enter");
        NSInteger rfastExit = IndexInTrace(trace, "GET:rfast:exit");

        ck(allDone && w1Exit >= 0 && w2Enter >= 0 && w1Exit < w2Enter && w2Exit < w3Enter,
           "C1 POST/postData 写入严格按提交顺序串行执行（w1 退出早于 w2 进入，w2 早于 w3）",
           [NSString stringWithFormat:@"w1Exit=%ld w2Enter=%ld w2Exit=%ld w3Enter=%ld",
            (long)w1Exit, (long)w2Enter, (long)w2Exit, (long)w3Enter]);
        ck(g_maxConcurrentReads.load() >= 2,
           "C1 GET 读请求保持并发执行（maxConcurrentReads >= 2）",
           [NSString stringWithFormat:@"maxConcurrentReads=%d", g_maxConcurrentReads.load()]);
        ck(rfastExit >= 0 && w1Exit >= 0 && rfastExit < w1Exit,
           "C1 读请求不被慢写队列阻塞（rfast 早于 w1 完成）",
           [NSString stringWithFormat:@"rfastExit=%ld w1Exit=%ld", (long)rfastExit, (long)w1Exit]);
        ck([RLPCoreClient isSlowWritePath:@"/api/lyrics/ai"] &&
           [RLPCoreClient isSlowWritePath:@"/api/entity/knowledge"] &&
           [RLPCoreClient isSlowWritePath:@"/api/entity/summary"],
           "C1e 长耗时 AI 请求被识别并走独立慢队列（LLM 卡住不拖住播控）", @"");
        ck(![RLPCoreClient isSlowWritePath:@"/api/pause"] &&
           ![RLPCoreClient isSlowWritePath:@"/api/stop"] &&
           ![RLPCoreClient isSlowWritePath:@"/api/volume"],
           "C1f 实时播控端点仍走写队列（不被误分类进慢队列）", @"");

        // ====================================================================
        // C2: PlaybackBar fetchStatus inflight/epoch 保护，旧回包不覆盖新状态
        // ====================================================================
        ResetMockState();
        RLPPlaybackBarView *bar = [[RLPPlaybackBarView alloc] initWithFrame:NSMakeRect(0, 0, 1120, 66)];
        [bar layout];

        // 先让请求 1（返回旧状态 playing=true, /old.flac）卡在 gate 上
        g_statusGatePayload = MakeStatusJSON(true, false, "/tmp/old-stale.flac");
        g_statusGate.arm();
        [bar startPolling]; // 发起请求 1
        BOOL req1Entered = g_statusGate.waitEntered(2000);
        ck(req1Entered, "C2 请求 1（旧状态）已进入 dispatch 并挂起", @"");

        // 保持请求 1 挂起期间，验证 0.5s 定时器不会堆积更多并发 /api/status
        int countAtStart = g_statusCount.load();
        Pump(0.65);
        int countAfterTimer = g_statusCount.load();
        ck(countAfterTimer == countAtStart,
           "C2 fetchStatus 挂起期间 500ms 定时器不堆积并发请求 (inflight 保护)",
           [NSString stringWithFormat:@"before=%d after=%d", countAtStart, countAfterTimer]);

        // 此时后端已切到新状态 /new.flac (playing=false)，发起新动作 stopPlayback 触发新一轮 epoch 刷新
        {
            std::lock_guard<std::mutex> lk(g_mu);
            g_playing = false;
            g_paused = false;
            g_current = "/tmp/new-fresh.flac";
        }
        [bar stopPlayback:nil]; // POST /api/stop 完成后会刷新 status（请求 2）
        BOOL req2Applied = WaitUntil(2.0, ^BOOL {
            return [bar.lastStatus.currentPath isEqualToString:@"/tmp/new-fresh.flac"] && !bar.lastStatus.playing;
        });
        ck(req2Applied, "C2 请求 2（新状态 /new-fresh.flac）已生效",
           bar.lastStatus.currentPath ?: @"nil");

        // 现在放行旧请求 1（/old-stale.flac, playing=true）
        g_statusGate.release();
        Pump(0.15);
        ck([bar.lastStatus.currentPath isEqualToString:@"/tmp/new-fresh.flac"] && !bar.lastStatus.playing,
           "C2 延迟到达的旧 /api/status 回包被 epoch 丢弃，不覆盖新状态",
           [NSString stringWithFormat:@"path=%@ playing=%d", bar.lastStatus.currentPath, bar.lastStatus.playing]);

        // ====================================================================
        // C3: 动作完成刷新 + QuickStart 停止态重播 + 连点不误发错暂停 + QuickStart epoch
        // ====================================================================
        {
            std::lock_guard<std::mutex> lk(g_mu);
            g_playing = true;
            g_paused = false;
            g_current = "/tmp/c3-track.flac";
            g_pausePostDelayMs = 30;
        }
        // 重启轮询使 500ms 定时器从零计时，确保 0.25s 内的刷新完全来自 playPause 动作完成回调
        [bar stopPolling];
        [bar startPolling];
        WaitUntil(2.0, ^BOOL { return bar.lastStatus.playing && !bar.lastStatus.paused; });

        // 验证 playPause 动作完成后主动刷新状态（不等 500ms 轮询）
        NSButton *barPlay = [bar valueForKey:@"playBtn"];
        [barPlay performClick:nil];
        BOOL barRefreshed = WaitUntil(0.25, ^BOOL { return bar.lastStatus.paused; });
        ck(barRefreshed, "C3 PlaybackBar playPause 延迟 POST 完成后主动刷新 lastStatus.paused=YES",
           bar.lastStatus.paused ? @"YES" : @"NO");

        // 暂停态连点两次：在 POST 延迟期间连点，绝不反向发出 /api/pause?on=1
        ClearPosts();
        g_pausePostGate.arm();
        [barPlay performClick:nil];
        [barPlay performClick:nil];
        Pump(0.05);
        g_pausePostGate.release();
        WaitUntil(2.0, ^BOOL { return bar.lastStatus.playing && !bar.lastStatus.paused; });
        BOOL barWrongPause = NO;
        for (const auto& rec : SnapshotPosts()) {
            if (rec.path == "/api/pause?on=1") barWrongPause = YES;
        }
        ck(!barWrongPause, "C3 PlaybackBar 暂停态连点不反向发出 /api/pause?on=1 错暂停", @"");
        Pump(0.08); // 让连点的第二个异步请求收尾，避免污染下一段用例

        [bar stopPolling];

        // QuickStart：停止态点击播放按钮应重播 /api/play，且完成后主动刷新状态
        ResetMockState();
        {
            std::lock_guard<std::mutex> lk(g_mu);
            g_playing = false;
            g_paused = false;
            g_current = "/tmp/qs-stopped.flac";
        }
        RLPQuickStartViewController *qs = [[RLPQuickStartViewController alloc] init];
        (void)qs.view;
        [qs activate];
        BOOL qsSynced = WaitUntil(2.0, ^BOOL {
            NSString *cur = [qs valueForKey:@"currentPath"];
            return [cur isEqualToString:@"/tmp/qs-stopped.flac"] &&
                   ![[qs valueForKey:@"playing"] boolValue] &&
                   ![[qs valueForKey:@"pausedNow"] boolValue];
        });
        ck(qsSynced, "C3 QuickStart 同步到停止态",
           [NSString stringWithFormat:@"cur=%@ playing=%d pausedNow=%d",
            [qs valueForKey:@"currentPath"],
            [[qs valueForKey:@"playing"] boolValue],
            [[qs valueForKey:@"pausedNow"] boolValue]]);

        ClearPosts();
        NSButton *npToggle = [qs valueForKey:@"npToggle"];
        [npToggle performClick:nil];
        BOOL qsReplayed = WaitUntil(2.0, ^BOOL {
            for (const auto& rec : SnapshotPosts()) {
                if (rec.path == "/api/play" && rec.body.find("qs-stopped.flac") != std::string::npos) return YES;
            }
            return NO;
        });
        BOOL qsUsedPauseNoop = NO;
        for (const auto& rec : SnapshotPosts()) {
            if (rec.path.rfind("/api/pause", 0) == 0) qsUsedPauseNoop = YES;
        }
        ck(qsReplayed && !qsUsedPauseNoop,
           "C3 QuickStart 停止态点播放发 /api/play 重播（非 /api/pause?on=0 no-op）", @"");

        BOOL qsRefreshedAfterPlay = WaitUntil(0.25, ^BOOL {
            return [[qs valueForKey:@"playing"] boolValue] && ![[qs valueForKey:@"pausedNow"] boolValue];
        });
        ck(qsRefreshedAfterPlay, "C3 QuickStart 播放动作完成后主动刷新 playing=YES（不等 1s 轮询）", @"");

        // QuickStart reloadStatus 旧回包不覆盖新状态
        g_statusGatePayload = MakeStatusJSON(true, false, "/tmp/qs-old-stale.flac");
        g_statusGate.arm();
        [qs performSelector:@selector(reloadStatus)];
        BOOL qsReq1Entered = g_statusGate.waitEntered(2000);
        {
            std::lock_guard<std::mutex> lk(g_mu);
            g_playing = false;
            g_paused = false;
            g_current = "/tmp/qs-new-fresh.flac";
        }
        [qs performSelector:@selector(reloadStatus)];
        BOOL qsReq2Applied = WaitUntil(2.0, ^BOOL {
            return [[qs valueForKey:@"currentPath"] isEqualToString:@"/tmp/qs-new-fresh.flac"] &&
                   ![[qs valueForKey:@"playing"] boolValue];
        });
        g_statusGate.release();
        Pump(0.15);
        ck(qsReq1Entered && qsReq2Applied &&
           [[qs valueForKey:@"currentPath"] isEqualToString:@"/tmp/qs-new-fresh.flac"] &&
           ![[qs valueForKey:@"playing"] boolValue],
           "C3 QuickStart reloadStatus 延迟旧回包被 epoch 丢弃，不覆盖新状态",
           [qs valueForKey:@"currentPath"] ?: @"nil");
        [qs viewDidDisappear];

        // ====================================================================
        // C4: RLPPlayWholeListFrom 多段异步竞争，generation 最新意图胜出并拦截所有后续副作用
        // ====================================================================
        // 4a: A 卡在 Stage 1 (GET /api/playmode)，B 跑完后释放 A -> A 不得发 playmode?mode=1 / queue/set / play
        ResetMockState();
        g_playmodeGetGateMode = 2;
        g_playmodeGetGate.arm();
        RLPPlayWholeListFrom(@[@"/music/A1.flac", @"/music/A2.flac"], 0);
        BOOL a1Entered = g_playmodeGetGate.waitEntered(2000);
        {
            std::lock_guard<std::mutex> lk(g_mu);
            g_playmode = 0;
        }
        RLPPlayWholeListFrom(@[@"/music/B1.flac", @"/music/B2.flac"], 1);
        BOOL b1Done = WaitUntil(2.0, ^BOOL {
            bool qB = false, pB = false;
            for (const auto& rec : SnapshotPosts()) {
                if (rec.path == "/api/queue/set" && rec.body.find("B1.flac") != std::string::npos) qB = true;
                if (rec.path == "/api/play" && rec.body.find("B2.flac") != std::string::npos) pB = true;
            }
            return qB && pB;
        });
        ClearPosts();
        g_playmodeGetGate.release();
        Pump(0.15);
        BOOL a1Leaked = SnapshotPosts().size() > 0;
        ck(a1Entered && b1Done && !a1Leaked,
           "C4a wholelist A 卡在 GET /api/playmode 后被 B 取代：A 零后续副作用（无 playmode=1 / queue/set / play）",
           [NSString stringWithFormat:@"leakedPosts=%zu", SnapshotPosts().size()]);

        // 4b: A 卡在 Stage 2 (POST /api/playmode?mode=1)，B 跑完后释放 A -> A 不得发 queue/set / play
        ResetMockState();
        {
            std::lock_guard<std::mutex> lk(g_mu);
            g_playmode = 2;
        }
        g_playmodePostGate.arm();
        RLPPlayWholeListFrom(@[@"/music/A1.flac", @"/music/A2.flac"], 0);
        BOOL a2Entered = WaitUntil(2.0, ^BOOL { return g_playmodePostGate.hasEntered(); });
        {
            std::lock_guard<std::mutex> lk(g_mu);
            g_playmode = 0;
        }
        RLPPlayWholeListFrom(@[@"/music/B1.flac", @"/music/B2.flac"], 1);
        Pump(0.05);
        ClearPosts();
        g_playmodePostGate.release();
        BOOL b2Done = WaitUntil(2.0, ^BOOL {
            bool qB = false, pB = false;
            for (const auto& rec : SnapshotPosts()) {
                if (rec.path == "/api/queue/set" && rec.body.find("B1.flac") != std::string::npos) qB = true;
                if (rec.path == "/api/play" && rec.body.find("B2.flac") != std::string::npos) pB = true;
            }
            return qB && pB;
        });
        Pump(0.1);
        BOOL a2Leaked = NO;
        for (const auto& rec : SnapshotPosts()) {
            if ((rec.path == "/api/queue/set" && rec.body.find("A1.flac") != std::string::npos) ||
                (rec.path == "/api/play" && rec.body.find("A1.flac") != std::string::npos)) {
                a2Leaked = YES;
            }
        }
        ck(a2Entered && b2Done && !a2Leaked,
           "C4b wholelist A 卡在 POST /api/playmode?mode=1 后被 B 取代：A 不得旧 queue 覆盖新 queue 或 play",
           a2Leaked ? @"A leaked queue/play" : (b2Done ? @"ok" : @"B did not finish"));

        // 4c: A 卡在 Stage 3 (POST /api/queue/set)，B 跑完后释放 A -> A 不得发 play
        ResetMockState();
        g_queueSetGate.arm();
        RLPPlayWholeListFrom(@[@"/music/A1.flac", @"/music/A2.flac"], 0);
        BOOL a3Entered = WaitUntil(2.0, ^BOOL { return g_queueSetGate.hasEntered(); });
        RLPPlayWholeListFrom(@[@"/music/B1.flac", @"/music/B2.flac"], 1);
        Pump(0.05);
        ClearPosts();
        g_queueSetGate.release();
        BOOL b3Won = WaitUntil(2.0, ^BOOL {
            bool qB = false, pB = false;
            for (const auto& rec : SnapshotPosts()) {
                if (rec.path == "/api/queue/set" && rec.body.find("B1.flac") != std::string::npos) qB = true;
                if (rec.path == "/api/play" && rec.body.find("B2.flac") != std::string::npos) pB = true;
            }
            return qB && pB;
        });
        Pump(0.1);
        BOOL a3Played = NO;
        for (const auto& rec : SnapshotPosts()) {
            if (rec.path == "/api/play" && rec.body.find("A1.flac") != std::string::npos) a3Played = YES;
        }
        ck(a3Entered && b3Won && !a3Played,
           "C4c wholelist A 卡在 POST /api/queue/set 时被 B 取代：A 完成后不得发 /api/play A1，B 最终胜出",
           a3Played ? @"A1 leaked play" : (b3Won ? @"ok" : @"B did not win"));

        // A no-op action has no completion notification: invalidating an old poll
        // must still release its inflight flag so timer polling can resume.
        [bar setValue:@YES forKey:@"polling"];
        [bar setValue:[RLPPlaybackStatus statusFromJSON:@{@"playing": @YES, @"paused": @NO, @"current": @"/tmp/already-playing.flac"}] forKey:@"lastStatus"];
        [bar setValue:@YES forKey:@"statusInflight"];
        [bar resumeOrReplay];
        ck(![[bar valueForKey:@"statusInflight"] boolValue], "C5 已播放时继续的 no-op 不阻断后续状态轮询", @"");
        [bar setValue:[RLPPlaybackStatus statusFromJSON:@{@"playing": @NO, @"paused": @NO, @"current": @""}] forKey:@"lastStatus"];
        [bar setValue:@YES forKey:@"statusInflight"];
        [barPlay performClick:nil];
        ck(![[bar valueForKey:@"statusInflight"] boolValue], "C5 空队列播放的 no-op 不阻断后续状态轮询", @"");
        [bar stopPolling];

        // ====================================================================
        // C6: 全局同步/异步播放失败气泡（轮询不重报 / 重试再报 / 丢弃旧状态）
        // ====================================================================
        {
            ResetMockState();
            RLPResetPlaybackErrorState();
            NSWindow *toastWin = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 600)
                                                             styleMask:NSWindowStyleMaskBorderless
                                                               backing:NSBackingStoreBuffered
                                                                 defer:NO];
            toastWin.releasedWhenClosed = NO;
            toastWin.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
            auto toastMsg = ^NSString *() {
                for (NSView *v in toastWin.contentView.subviews) {
                    if (![v.identifier isEqualToString:@"rlp.toast"]) continue;
                    for (NSView *s in v.subviews) {
                        if ([s isKindOfClass:[NSTextField class]]) return ((NSTextField *)s).stringValue;
                    }
                }
                return nil;
            };
            auto clearToast = ^() {
                for (NSView *v in [toastWin.contentView.subviews copy]) {
                    if ([v.identifier isEqualToString:@"rlp.toast"]) [v removeFromSuperview];
                }
            };

            // C6a: 同步 /api/play, /api/lib/play, /api/skip 失败均弹全局气泡
            {
                std::lock_guard<std::mutex> lk(g_mu);
                g_playError = "sync play open failed";
                g_libPlayError = "sync album failed";
                g_skipError = "sync skip failed";
            }
            RLPPlayPath(@"/tmp/c6-fail.flac");
            ck(WaitUntil(2.0, ^BOOL { return [toastMsg() isEqualToString:@"sync play open failed"]; }),
               "C6a 同步 /api/play 失败弹出全局气泡", toastMsg() ?: @"(nil)");

            // C6b: 重试相同错误再次报
            clearToast();
            RLPPlayPath(@"/tmp/c6-fail.flac");
            ck(WaitUntil(2.0, ^BOOL { return [toastMsg() isEqualToString:@"sync play open failed"]; }),
               "C6b 重试相同错误再次弹出全局气泡", toastMsg() ?: @"(nil)");

            clearToast();
            RLPPlayAlbum(@"alb-1", 0);
            ck(WaitUntil(2.0, ^BOOL { return [toastMsg() isEqualToString:@"sync album failed"]; }),
               "C6a 同步 /api/lib/play 失败弹出全局气泡", toastMsg() ?: @"(nil)");

            clearToast();
            [bar setValue:@YES forKey:@"polling"];
            [bar nextTrack];
            ck(WaitUntil(2.0, ^BOOL { return [toastMsg() isEqualToString:@"sync skip failed"]; }),
               "C6a 同步 /api/skip 失败弹出全局气泡", toastMsg() ?: @"(nil)");
            [bar stopPolling];

            // C6c: 后台 /api/status error 轮询不重报，重试后再次报
            clearToast();
            {
                std::lock_guard<std::mutex> lk(g_mu);
                g_playError.clear();
                g_statusError = "async device busy";
            }
            [bar startPolling];
            ck(WaitUntil(2.0, ^BOOL { return [toastMsg() isEqualToString:@"async device busy"]; }),
               "C6c 后台 /api/status 异步 error 在全局播放条轮询时弹出气泡", toastMsg() ?: @"(nil)");
            clearToast();
            Pump(0.65);
            ck(toastMsg() == nil, "C6c 同一异步 error 连续轮询不重报", toastMsg() ?: @"(nil)");

            // A different queued track may fail with the same device error.
            { std::lock_guard<std::mutex> lk(g_mu); g_current = "/tmp/next-failed.flac"; }
            ck(WaitUntil(2.0, ^BOOL { return [toastMsg() isEqualToString:@"async device busy"]; }),
               "C6e 自动下一曲同一原因仍重新提示", toastMsg() ?: @"(nil)");
            clearToast();

            // C6d: 在途旧 /api/status 带着旧错误，在 RLPPlayPath 发起后必须被丢弃
            [bar stopPolling];
            clearToast();
            g_statusGatePayload = "{\"ok\":true,\"playing\":false,\"paused\":false,\"current\":\"/tmp/stale.flac\",\"error\":\"stale poll error\",\"dur\":10,\"pos\":0,\"volDb\":-120,\"backend\":\"null\"}";
            g_statusGate.arm();
            [bar startPolling];
            BOOL staleEntered = g_statusGate.waitEntered(2000);
            {
                std::lock_guard<std::mutex> lk(g_mu);
                g_statusError.clear();
            }
            RLPPlayPath(@"/tmp/c6-fresh.flac");
            Pump(0.05);
            g_statusGate.release();
            Pump(0.15);
            ck(staleEntered && toastMsg() == nil,
               "C6d 动作发起前的在途旧 /api/status 错误被 actionEpoch 丢弃，不误报旧气泡",
               toastMsg() ?: @"(nil)");
            [bar stopPolling];

            // C6f: RLPPostPlaybackAction 旧请求慢失败被新请求起播取代，过期失败回调不弹旧错误
            ResetMockState();
            RLPResetPlaybackErrorState();
            clearToast();
            g_playGateError = "stale slow play failed";
            g_playPostGate.arm();
            RLPPlayPath(@"/tmp/c6f-old-slow.flac");
            BOOL c6fEntered = g_playPostGate.waitEntered(2000);
            RLPPlayPath(@"/tmp/c6f-new-fast.flac");
            g_playPostGate.release();
            BOOL c6fNewPosted = WaitUntil(2.0, ^BOOL {
                for (const auto& rec : SnapshotPosts()) {
                    if (rec.path == "/api/play" && rec.body.find("c6f-new-fast.flac") != std::string::npos) return YES;
                }
                return NO;
            });
            Pump(0.15);
            ck(c6fEntered && c6fNewPosted && toastMsg() == nil,
               "C6f RLPPostPlaybackAction 旧请求慢失败被新请求起播取代：过期失败回包不弹气泡",
               toastMsg() ?: @"(nil)");

            // C6g: PlaybackBar nextTrack/previousTrack 旧请求慢失败被新动作取代，过期失败回调不弹旧错误
            ResetMockState();
            RLPResetPlaybackErrorState();
            clearToast();
            [bar setValue:@YES forKey:@"polling"];
            g_skipGateError = "stale slow skip failed";
            g_skipPostGate.arm();
            [bar nextTrack];
            BOOL c6gEntered = g_skipPostGate.waitEntered(2000);
            [bar previousTrack];
            g_skipPostGate.release();
            BOOL c6gNewPosted = WaitUntil(2.0, ^BOOL {
                for (const auto& rec : SnapshotPosts()) {
                    if (rec.path == "/api/skip?dir=-1") return YES;
                }
                return NO;
            });
            Pump(0.15);
            ck(c6gEntered && c6gNewPosted && toastMsg() == nil,
               "C6g PlaybackBar nextTrack 旧请求慢失败被 previousTrack 取代：过期失败回包不弹气泡",
               toastMsg() ?: @"(nil)");
            [bar stopPolling];

            // C6h: RightDrawer playIndex 旧请求慢失败被新请求取代，过期失败回调不弹旧错误
            ResetMockState();
            RLPResetPlaybackErrorState();
            clearToast();
            RLPRightDrawer *drawer = [[RLPRightDrawer alloc] initWithFrame:NSMakeRect(0, 0, 320, 480)];
            [drawer setValue:@[@"/tmp/c6h-old.flac", @"/tmp/c6h-new.flac"] forKey:@"items"];
            g_playGateError = "stale drawer play failed";
            g_playPostGate.arm();
            [drawer playIndex:0];
            BOOL c6hEntered = g_playPostGate.waitEntered(2000);
            [drawer playIndex:1];
            g_playPostGate.release();
            BOOL c6hNewPosted = WaitUntil(2.0, ^BOOL {
                for (const auto& rec : SnapshotPosts()) {
                    if (rec.path == "/api/play" && rec.body.find("c6h-new.flac") != std::string::npos) return YES;
                }
                return NO;
            });
            Pump(0.15);
            ck(c6hEntered && c6hNewPosted && toastMsg() == nil,
               "C6h RightDrawer playIndex 旧请求慢失败被新 playIndex 取代：过期失败回包不弹气泡",
               toastMsg() ?: @"(nil)");

            // C6i: pause 不重置错误去重，残留 /api/status error 不重报；play 重试则重置并再报
            ResetMockState();
            RLPResetPlaybackErrorState();
            clearToast();
            {
                std::lock_guard<std::mutex> lk(g_mu);
                g_playing = true;
                g_paused = false;
                g_current = "/tmp/c6i-pause.flac";
                g_statusError = "async device busy";
            }
            [bar startPolling];
            ck(WaitUntil(2.0, ^BOOL { return [toastMsg() isEqualToString:@"async device busy"]; }),
               "C6i 前置：/api/status 首次报告 async device busy", toastMsg() ?: @"(nil)");
            clearToast();
            ClearPosts();
            [bar playPause]; // /api/pause?on=1
            BOOL pausedDone = WaitUntil(2.0, ^BOOL {
                bool sawPause = false;
                for (const auto& rec : SnapshotPosts()) {
                    if (rec.path == "/api/pause?on=1") sawPause = true;
                }
                return sawPause && bar.lastStatus.paused;
            });
            Pump(0.15);
            ck(pausedDone && toastMsg() == nil,
               "C6i pause(/api/pause?on=1) 不清空去重，残留 status error 不重报",
               toastMsg() ?: @"(nil)");

            ClearPosts();
            [bar playPause]; // /api/pause?on=0
            BOOL resumedDone = WaitUntil(2.0, ^BOOL {
                bool sawResume = false;
                for (const auto& rec : SnapshotPosts()) {
                    if (rec.path == "/api/pause?on=0") sawResume = true;
                }
                return sawResume && !bar.lastStatus.paused;
            });
            Pump(0.15);
            ck(resumedDone && toastMsg() == nil,
               "C6i resume(/api/pause?on=0) 不清空去重，残留 status error 不重报",
               toastMsg() ?: @"(nil)");

            RLPPlayPath(@"/tmp/c6i-pause.flac");
            ck(WaitUntil(2.0, ^BOOL { return [toastMsg() isEqualToString:@"async device busy"]; }),
               "C6i /api/play 重试重置去重，残留 status error 再次提示", toastMsg() ?: @"(nil)");
            [bar stopPolling];
        }

        [client shutdown];
        std::printf("\n%s（%d passed, %d failed）\n",
                    g_fail == 0 ? "原生播放异步并发与状态契约 全部通过" : "原生播放异步并发与状态契约 有失败",
                    g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
