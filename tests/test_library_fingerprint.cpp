// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
// Real isolated filesystem/process tests; no playback and no user state access.
// Baseline red: fallback startScan rewrites unchanged index and startup API is absent.
#include "net/library.h"
#include <unistd.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <cstdio>
#include <fstream>
#include <future>

using rta::net::Library;
namespace fs = std::filesystem;
static int failed = 0;
static void check(bool ok, const char* label) {
    std::printf("[%s] %s\n", ok ? "PASS" : "FAIL", label);
    if (!ok) ++failed;
}
static void put(const fs::path& p, const std::string& s) { std::ofstream(p, std::ios::binary) << s; }
static std::string get(const fs::path& p) {
    std::ifstream f(p, std::ios::binary); return {std::istreambuf_iterator<char>(f), {}};
}
template<class T> concept HasStartupScan = requires(T& l) { l.startStartupScan(); };
template<class T> static bool startup(T& l) {
    if constexpr (HasStartupScan<T>) return l.startStartupScan();
    else return l.startScan();
}
static bool waitFile(const fs::path& file) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (std::chrono::steady_clock::now() < deadline) {
        if (fs::exists(file)) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    return false;
}
int main(int argc, char** argv) {
    if (argc > 1 && std::string(argv[1]) == "--child") {
        auto& lib = Library::instance(); lib.load();
        std::string reason; bool scan = true;
        lib.startStartupScan([&](const auto& why, bool run) { reason = why; scan = run; }); lib.joinScan();
        check(reason == "unchanged" && !scan, "fresh process reuses persisted fingerprint");
        return failed ? 1 : 0;
    }
    const fs::path base = fs::temp_directory_path() / ("rlplayer-fingerprint-" + std::to_string(getpid()));
    fs::create_directories(base / "library"); fs::create_directories(base / "music/album");
    fs::create_directories(base / "home");
    setenv("HOME", (base / "home").c_str(), 1);
    for (const char* key : {"RLPLAYER_STATE_DIR", "RLPLAYER_COVER_DIR"}) setenv(key, base.c_str(), 1);
    setenv("RLPLAYER_LIBRARY_DIR", (base / "library").c_str(), 1);
    unsetenv("RLPLAYER_PORT");
    auto& lib = Library::instance(); lib.load();
    check(lib.addRoot((base / "music").string()), "add isolated root");
    check(lib.startScan(), "manual scan starts"); lib.joinScan();
    const auto index = base / "library/rlplayer-index.tsv";
    const auto fingerprint = base / "library/rlplayer-index.dirs.tsv";
    const auto before = fs::last_write_time(index);
    check(startup(lib), "startup asynchronous work accepted"); lib.joinScan();
    check(fs::last_write_time(index) == before, "unchanged startup preserves index (no full scan)");
    check(HasStartupScan<Library>, "directory-only startup API exists");
    check(std::system(("\"" + std::string(argv[0]) + "\" --child").c_str()) == 0, "restart process skips unchanged library");

    std::string reason; bool scanned = false;
    auto run = [&] {
        reason.clear(); scanned = false;
        check(lib.startStartupScan([&](const auto& why, bool scan) { reason = why; scanned = scan; }), "startup worker accepted");
        lib.joinScan();
    };
    fs::remove(fingerprint); run(); check(scanned && reason == "missing" && lib.snapshot().complete, "missing fingerprint rescans and rebuilds");
    put(fingerprint, "#libDirsV\t0\n"); run(); check(scanned && reason == "invalid", "old fingerprint rescans");
    put(fingerprint, "#libDirsV\t1\nD\tbogus\n"); run(); check(scanned && reason == "invalid", "corrupt fingerprint rescans");
    const auto goodIndex = get(index); put(index, goodIndex + "#corruption\n");
    run(); check(scanned && reason == "invalid", "index/fingerprint mismatch rescans");
    fs::create_directories(base / "music/newdir"); run(); check(scanned && reason == "changed", "directory addition triggers scan");
    fs::rename(base / "music/newdir", base / "music/renamed"); run(); check(scanned, "directory rename triggers scan");
    fs::remove(base / "music/renamed"); run(); check(scanned, "directory removal triggers scan");
    struct stat st{}; ::stat((base / "music/album").c_str(), &st);
    timespec ts[2] = {st.st_atimespec, st.st_mtimespec};
    ts[1].tv_nsec = ts[1].tv_nsec == 999999999 ? 999999998 : ts[1].tv_nsec + 1;
    check(::utimensat(AT_FDCWD, (base / "music/album").c_str(), ts, 0) == 0, "set directory mtime by one nanosecond");
    run(); check(scanned, "nanosecond-only directory mtime change triggers scan");

    // A fake ffprobe with real process invocation makes missed probes/counts observable.
    const auto probe = base / "probe.sh";
    put(probe, "#!/bin/sh\nprintf x >> \"$FP_COUNT\"\n"
        "if [ -f \"$FP_BLOCK\" ]; then : > \"$FP_STARTED\"; i=0; while [ ! -f \"$FP_RELEASE\" ] && [ $i -lt 200 ]; do sleep .01; i=$((i+1)); done; fi\n"
        "if [ -f \"$FP_FAIL\" ]; then exit 1; fi\n"
        "printf '[STREAM]\\ncodec_type=audio\\ncodec_name=aac\\nsample_rate=44100\\nchannels=2\\n[/STREAM]\\n[FORMAT]\\nduration=1\\n[/FORMAT]\\n'\n");
    ::chmod(probe.c_str(), 0700);
    const auto count = base / "count", block = base / "block", started = base / "started", release = base / "release", fail = base / "fail";
    for (const auto& kv : std::vector<std::pair<const char*, fs::path>>{{"FP_COUNT",count},{"FP_BLOCK",block},{"FP_STARTED",started},{"FP_RELEASE",release},{"FP_FAIL",fail},{"RLPLAYER_FFPROBE",probe}}) setenv(kv.first, kv.second.c_str(), 1);
    setenv("RLPLAYER_NATIVE_TAGS", "0", 1);
    put(base / "music/album/song.m4a", "synthetic"); run();
    std::printf("diagnostic first audio: scanned=%d tracks=%zu calls=%zu reason=%s\n", scanned, lib.trackCount(), get(count).size(), reason.c_str());
    check(scanned && lib.trackCount() == 1 && get(count).size() == 1, "audio addition scans/probes exactly once");
    const auto stable = fs::last_write_time(index); run();
    check(!scanned && reason == "unchanged" && get(count).size() == 1 && fs::last_write_time(index) == stable, "unchanged startup has zero ffprobe and zero index write");
    put(base / "music/album/song.m4a", "changed internally"); run();
    check(!scanned && get(count).size() == 1, "in-place audio/tag edit is intentionally manual-only");
    check(lib.startScan(), "manual scan remains available"); lib.joinScan();
    check(get(count).size() == 2, "manual scan detects in-place audio changes");

    put(block, ""); fs::remove(release); fs::remove(started);
    check(lib.startScan(true), "start blocked full scan");
    check(waitFile(started), "real ffprobe process reached deterministic block");
    check(!fs::exists(fingerprint), "fingerprint invalidated before probe starts");
    check(!lib.startScan() && !lib.startStartupScan(), "manual/startup overlap rejected safely");
    fs::create_directories(base / "music/during-scan"); put(release, ""); lib.joinScan();
    check(!lib.snapshot().complete && !fs::exists(fingerprint), "directory mutation during scan never hidden by end snapshot");
    run(); check(scanned && lib.snapshot().complete, "dirty interrupted snapshot rebuilt next startup");

    fs::remove(started); fs::remove(release);
    check(lib.startScan(true), "start cancellation scan"); check(waitFile(started), "cancellation probe started");
    lib.stopScan(); put(release, ""); lib.joinScan();
    check(!lib.snapshot().complete && !fs::exists(fingerprint), "cancelled scan stays dirty");
    fs::remove(block); run(); check(scanned, "cancelled scan retried on startup");

    put(fail, ""); lib.startScan(true); lib.joinScan();
    check(!lib.snapshot().complete && !fs::exists(fingerprint), "probe failure stays dirty");
    fs::remove(fail); lib.startScan(true); lib.joinScan();
    check(lib.snapshot().complete, "successful full retry restores clean fingerprint");
    fs::remove(index); fs::create_directory(index); put(index / "keep", "prevents rename");
    lib.startScan(); lib.joinScan();
    check(!lib.snapshot().complete && !fs::exists(fingerprint), "index write failure stays dirty");
    fs::remove_all(index); lib.startScan(); lib.joinScan();

    fs::permissions(base / "music/album", fs::perms::none);
    if (geteuid() != 0) {
        lib.startScan(); lib.joinScan();
        check(!lib.snapshot().complete && lib.snapshot().failedDirs > 0 && !fs::exists(fingerprint), "unreadable failedDirs never clean");
    }
    fs::permissions(base / "music/album", fs::perms::owner_all); lib.startScan(); lib.joinScan();
    fs::create_directories(base / "other");
    put(fingerprint, "invalid");
    lib.startStartupScan([&](const auto&, bool scan) { if (scan) lib.addRoot((base / "other").string()); }); lib.joinScan();
    check(!lib.snapshot().complete && !fs::exists(fingerprint), "root change during decision prevents clean marker");
    run(); check(scanned && lib.snapshot().complete, "changed roots included on next scan");

    // Directory helper must not follow symlinks or read FIFOs disguised as audio.
    ::symlink((base / "music").c_str(), (base / "music/loop").c_str());
    ::mkfifo((base / "music/unread.wav").c_str(), 0600);
    const auto dirs = rta::net::lib_directory_fingerprint({(base / "music").string()});
    check(dirs.complete && dirs.dirs.size() == 3, "directory-only helper skips symlink loop and audio FIFO without reading");
    lib.stopScan(); lib.joinScan(); fs::remove_all(base);
    std::printf("fingerprint failures=%d\n", failed);
    return failed ? 1 : 0;
}
