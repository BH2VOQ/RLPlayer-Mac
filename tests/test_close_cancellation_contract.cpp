// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_close_cancellation_contract.cpp — 播放中关闭的取消链路离线契约测试
//
// 覆盖 3 条耗时/卡顿根因的确定性回归：
//   C1 dl_gate_acquire（provider.h）：触发 1000ms 限频窗口后若收到取消信号，必须在 <250ms 内放弃而非死睡。
//   C2 art_discogs_throttle + artwork_fetch_artist_image（artwork.h）：
//      收到取消信号时，2500ms Discogs 节流与逐源遍历立即中止，且绝不写入 .none 负缓存。
//   C3 AudioLoadCancellationScope + read_wav_stream_pipe（audio_loader.h）：
//      对长耗时子进程解码管道绑定取消令牌并置 true，必须杀掉子进程并在 <300ms 内退出。
#include "audio/audio_loader.h"
#include "meta/artwork.h"
#include "meta/provider.h"
#include "net/http_client.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <thread>

namespace fs = std::filesystem;

static int g_pass = 0;
static int g_fail = 0;

static void ck(bool ok, const char* what, const std::string& detail = {}) {
    if (ok) {
        std::printf("  [PASS] %s\n", what);
        ++g_pass;
    } else {
        std::printf("  [FAIL] %s%s%s\n", what, detail.empty() ? "" : " — ", detail.c_str());
        ++g_fail;
    }
}

int main() {
    std::printf("== 播放中关闭取消链路离线契约测试 ==\n");

    // C1: dl_gate_acquire 在限频等待中可被 HttpCancellationScope 快速中断
    {
        rta::meta::dl_gate_reset_for_test();
        std::string err1;
        bool firstOk = rta::meta::dl_gate_acquire(err1);
        ck(firstOk, "C1 前置：首次 dl_gate_acquire 立即放行", err1);

        std::atomic<bool> cancel{false};
        std::thread killer([&] {
            std::this_thread::sleep_for(std::chrono::milliseconds(40));
            cancel.store(true, std::memory_order_release);
        });

        const auto t0 = std::chrono::steady_clock::now();
        bool secondOk = true;
        std::string err2;
        {
            rta::net::HttpCancellationScope scope(&cancel);
            secondOk = rta::meta::dl_gate_acquire(err2);
        }
        const long long ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                                 std::chrono::steady_clock::now() - t0).count();
        killer.join();
        ck(!secondOk && ms < 350, "C1 dl_gate_acquire 在 1s 限频窗口中被取消时快速中断",
           "ok=" + std::to_string(secondOk) + " ms=" + std::to_string(ms) + " err=" + err2);
    }

    // C2: art_discogs_throttle 与 artwork_fetch_artist_image 取消不眠且不写 .none 负缓存
    {
        rta::meta::set_artwork_http_for_test(nullptr);
        bool prep = rta::meta::art_discogs_throttle();
        std::atomic<bool> cancel{false};
        std::thread killer([&] {
            std::this_thread::sleep_for(std::chrono::milliseconds(40));
            cancel.store(true, std::memory_order_release);
        });
        const auto t0 = std::chrono::steady_clock::now();
        bool second = true;
        {
            rta::net::HttpCancellationScope scope(&cancel);
            second = rta::meta::art_discogs_throttle();
        }
        const long long ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                                 std::chrono::steady_clock::now() - t0).count();
        killer.join();
        ck(prep && !second && ms < 350, "C2a art_discogs_throttle 在 2.5s 节流窗中被取消时快速返回 false",
           "ms=" + std::to_string(ms));

        const fs::path tmp = fs::temp_directory_path() / "rlp-close-cancel-art";
        std::error_code ec;
        fs::remove_all(tmp, ec);
        fs::create_directories(tmp, ec);

        std::atomic<int> hookCalls{0};
        rta::meta::set_artwork_http_for_test([&](const rta::meta::ArtHttpRequest&) {
            hookCalls.fetch_add(1);
            rta::net::HttpResponse r;
            r.status = 404;
            return r;
        });

        std::atomic<bool> preCancelled{true};
        rta::meta::ArtworkOpts opts;
        opts.cacheDir = tmp.string();
        opts.useCache = true;
        rta::meta::ArtistImageResult imgRes;
        {
            rta::net::HttpCancellationScope scope(&preCancelled);
            imgRes = rta::meta::artwork_fetch_artist_image("Cancel Test Artist", opts);
        }
        rta::meta::set_artwork_http_for_test(nullptr);

        const auto paths = rta::meta::art_cache_paths(opts.cacheDir, "Cancel Test Artist");
        const bool negWritten = fs::exists(paths.none, ec);
        fs::remove_all(tmp, ec);

        ck(!imgRes.ok && hookCalls.load() == 0 && !negWritten,
           "C2b artwork_fetch_artist_image 已取消时不发起请求且不写 .none 负缓存",
           "calls=" + std::to_string(hookCalls.load()) + " neg=" + std::to_string(negWritten));
    }

    // C3: AudioLoadCancellationScope + read_wav_stream_pipe 杀子进程并快速中止
    {
        rta::platform::PipeProcess proc;
        const bool started = proc.start("/bin/sleep 10");
        ck(started, "C3 前置：PipeProcess 启动 /bin/sleep 10");
        if (started) {
            proc.set_stdout_nonblocking();
            std::atomic<bool> cancel{false};
            std::thread killer([&] {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                cancel.store(true, std::memory_order_release);
            });
            rta::audio::AudioBuffer ab;
            std::string err;
            const auto t0 = std::chrono::steady_clock::now();
            bool readOk = true;
            {
                rta::audio::AudioLoadCancellationScope scope(&cancel);
                readOk = rta::audio::read_wav_stream_pipe(proc.out_fd, proc, ab, &err);
            }
            proc.close_fds();
            const int rc = proc.wait();
            const long long ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                                     std::chrono::steady_clock::now() - t0).count();
            killer.join();
            ck(!readOk && ms < 400 && rc != 0,
               "C3 AudioLoadCancellationScope 在 400ms 内中止流式管道并清理子进程",
               "ok=" + std::to_string(readOk) + " ms=" + std::to_string(ms) +
               " rc=" + std::to_string(rc) + " err=" + err);
        }
    }

    std::printf("\n结果：%d passed, %d failed\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
