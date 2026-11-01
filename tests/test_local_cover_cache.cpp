// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
// Real subprocess regression: the executable doubles as a deterministic fake ffmpeg.
// This tests extraction/cache decisions, not image decoding or real SMB performance.
#include "net/library.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <unistd.h>

namespace fs = std::filesystem;
static int failures = 0;
static void check(bool ok, const char* name) {
    std::cout << (ok ? "PASS " : "FAIL ") << name << '\n';
    if (!ok) ++failures;
}
static void put(const fs::path& p, const std::string& s) {
    fs::create_directories(p.parent_path());
    std::ofstream f(p, std::ios::binary); f.write(s.data(), s.size());
}
static int calls(const fs::path& root) {
    std::ifstream f(root / "calls"); int n = 0; std::string s;
    while (std::getline(f, s)) ++n;
    return n;
}
static std::string image(char mark = 'A') {
    std::string s(2048, mark); s[0] = char(0xff); s[1] = char(0xd8); s[2] = char(0xff);
    return s;
}
int main(int argc, char** argv) {
    if (argc == 2 && std::string(argv[1]) == "-version") { std::cout << "ffmpeg fixture\n"; return 0; }
    // Product invokes: -v error -y -i SOURCE ... OUTPUT. No shell is involved.
    if (argc > 2 && std::string(argv[1]) == "-v") {
        const char* root = std::getenv("TEST_LOCAL_COVER_ROOT");
        std::ofstream(fs::path(root) / "calls", std::ios::app) << "extract\n";
        std::ifstream input(argv[5], std::ios::binary);
        if (!input) return 9; // proves command-line escaping preserves the complete source path
        if (std::getenv("TEST_LOCAL_COVER_FAIL")) return 1;
        if (std::getenv("TEST_LOCAL_COVER_SLOW")) std::this_thread::sleep_for(std::chrono::milliseconds(250));
        if (std::getenv("TEST_LOCAL_COVER_TIMEOUT")) std::this_thread::sleep_for(std::chrono::seconds(7));
        put(argv[argc - 1], image());
        return 0;
    }
    if (argc == 3 && std::string(argv[1]) == "--request") {
        auto& lib = rta::net::Library::instance(); lib.load();
        const auto albums = lib.albums();
        if (albums.size() != 1) return 2;
        std::vector<unsigned char> bytes; std::string mime;
        if (!lib.albumCover(albums[0].key, bytes, mime)) return 3;
        return std::string(bytes.begin(), bytes.end()) == image() && mime == "image/jpeg" ? 0 : 4;
    }
    const fs::path root = fs::temp_directory_path() / ("rlplayer_local_cover_" + std::to_string(getpid()));
    fs::create_directories(root);
    const fs::path audio = root / "music" / "quote \" slash \\ 空格.wav";
    put(audio, "source");
    put(root / "lib" / "rlplayer-index.tsv", "#libIndexV\t4\n" + audio.string() +
        "\t111\t6\tCache Album\tArtist\tArtist\tTrack\t1\t1\t2026\t44100\t16\t2\t1\t1\tRock\t\t0\t0\t0\n");
    setenv("HOME", (root / "home").c_str(), 1);
    setenv("RLPLAYER_STATE_DIR", (root / "state").c_str(), 1);
    setenv("RLPLAYER_LIBRARY_DIR", (root / "lib").c_str(), 1);
    setenv("RLPLAYER_COVER_DIR", (root / "covers").c_str(), 1);
    setenv("TEST_LOCAL_COVER_ROOT", root.c_str(), 1);
    setenv("RLPLAYER_FFMPEG", fs::absolute(argv[0]).c_str(), 1);
    const std::string cmd = "\"" + fs::absolute(argv[0]).string() + "\" --request \"" + root.string() + "\"";
    check(rta::platform::run_hidden(cmd).exit_code == 0, "first process returns fixture bytes");
    check(calls(root) == 1, "first process starts ffmpeg once");
    check(rta::platform::run_hidden(cmd).exit_code == 0, "second process returns same bytes");
    check(calls(root) == 1, "new process starts zero ffmpeg (persistent cache)");
    auto& lib = rta::net::Library::instance(); lib.load();
    const std::string key = lib.albums().at(0).key;
    std::vector<unsigned char> bytes; std::string mime, source; bool busy = true;
    auto request = [&] { return lib.albumCover(key, bytes, mime, &source, &busy); };
    check(request() && source == "embedcache" && !busy, "disk hit reports embedcache");
    const int before = calls(root);
    check(request() && calls(root) == before, "same-process validated memory hit skips ffmpeg");
    const auto oldTime = fs::last_write_time(audio);
    fs::last_write_time(audio, oldTime + std::chrono::nanoseconds(1234567));
    check(request() && calls(root) == before + 1 && source == "embed", "nanosecond audio mtime invalidates memory and disk");
    put(audio, "source changed size");
    check(request() && calls(root) == before + 2, "audio size change extracts once");
    check(rta::platform::run_hidden(cmd).exit_code == 0 && calls(root) == before + 2,
          "new process after source update uses refreshed cache");
    const fs::path base = root / "covers" / "embed" / key;
    put(base.string() + ".img", image('C')); // same size and valid magic but wrong checksum
    check(rta::platform::run_hidden(cmd).exit_code == 0 && calls(root) == before + 3,
          "corrupt image checksum is a miss and is repaired");
    put(base.string() + ".meta", "broken metadata");
    check(rta::platform::run_hidden(cmd).exit_code == 0 && calls(root) == before + 4,
          "truncated metadata is a miss and is repaired");
    const int beforeSibling = calls(root);
    put(audio.parent_path() / "cover.jpg", image('B'));
    check(request() && std::string(bytes.begin(), bytes.end()) == image('B') && calls(root) == beforeSibling,
          "new sibling cover invalidates embedded memory hit without ffmpeg");
    const auto picTime = fs::last_write_time(audio.parent_path() / "cover.jpg");
    put(audio.parent_path() / "cover.jpg", image('C'));
    fs::last_write_time(audio.parent_path() / "cover.jpg", picTime + std::chrono::nanoseconds(1000));
    check(request() && std::string(bytes.begin(), bytes.end()) == image('C'), "sibling content mtime invalidates memory hit");
    fs::remove(audio.parent_path() / "cover.jpg");
    put(audio.parent_path() / "COVER.JPG", image('B'));
    std::string upperBefore, upperAfter;
    check(rta::net::local_cover::snapshot({audio.string()}, upperBefore), "uppercase sibling snapshot succeeds");
    const auto upperTime = fs::last_write_time(audio.parent_path() / "COVER.JPG");
    put(audio.parent_path() / "COVER.JPG", image('C'));
    fs::last_write_time(audio.parent_path() / "COVER.JPG", upperTime + std::chrono::nanoseconds(1000));
    check(rta::net::local_cover::snapshot({audio.string()}, upperAfter) && upperBefore != upperAfter,
          "case-variant sibling content update changes fingerprint");
    fs::remove(audio.parent_path() / "COVER.JPG");
    check(request() && std::string(bytes.begin(), bytes.end()) == image() && calls(root) == beforeSibling + 1,
          "removing sibling falls back to embedded extraction");
    fs::last_write_time(audio, fs::last_write_time(audio) + std::chrono::seconds(1));
    check(rta::net::cover_gate_acquire(0) && rta::net::cover_gate_acquire(0), "two concurrency slots available");
    const auto start = std::chrono::steady_clock::now();
    check(!request() && busy && source == "busy" && bytes.empty(), "gate contention explicitly reports busy");
    check(std::chrono::steady_clock::now() - start < std::chrono::milliseconds(500), "gate contention no longer waits 1.5 seconds");
    rta::net::cover_gate_release(); rta::net::cover_gate_release();
    const int beforeFlight = calls(root);
    setenv("TEST_LOCAL_COVER_SLOW", "1", 1);
    std::atomic<bool> got{false};
    std::thread worker([&] { std::vector<unsigned char> b; std::string m;
        got = lib.albumCover(key, b, m); });
    while (calls(root) == beforeFlight) std::this_thread::yield();
    check(!request() && busy, "same-album singleflight reports busy while extraction runs");
    worker.join(); unsetenv("TEST_LOCAL_COVER_SLOW");
    check(got && calls(root) == beforeFlight + 1, "singleflight extracts exactly once");
    const int beforeFailure = calls(root);
    fs::last_write_time(audio, fs::last_write_time(audio) + std::chrono::seconds(1));
    setenv("TEST_LOCAL_COVER_FAIL", "1", 1);
    check(!request() && !busy && bytes.empty(), "failed subprocess produces no stale image");
    unsetenv("TEST_LOCAL_COVER_FAIL");
    check(request() && calls(root) == beforeFailure + 2, "failed extraction does not poison future requests");
    fs::last_write_time(audio, fs::last_write_time(audio) + std::chrono::seconds(1));
    setenv("TEST_LOCAL_COVER_TIMEOUT", "1", 1);
    const auto timeoutStart = std::chrono::steady_clock::now();
    check(!request() && busy, "six-second timeout is retryable busy");
    const auto timeoutMs = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - timeoutStart).count();
    check(timeoutMs >= 5900 && timeoutMs < 6800, "single-file extraction preserves six-second deadline");
    unsetenv("TEST_LOCAL_COVER_TIMEOUT");
    check(request(), "timeout creates no permanent negative cache");
    bool hasPart = false;
    for (auto& entry : fs::directory_iterator(base.parent_path()))
        if (entry.path().extension() == ".part") hasPart = true;
    check(!hasPart, "atomic cache writes leave no part files");
    check(!rta::net::local_cover::valid_key("../escape"), "cache key rejects path traversal");
    unsetenv("RLPLAYER_COVER_DIR");
    check(rta::net::local_cover::root() == (root / "state" / "covercache" / "embed").string(),
          "default cache path respects isolated runtime state");
    std::cout << "root=" << root << " calls=" << calls(root) << " failures=" << failures << '\n';
    fs::remove_all(root);
    return failures ? 1 : 0;
}
