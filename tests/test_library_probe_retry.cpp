// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Real subprocess/isolated filesystem regression; never opens an audio device.
// The fake ffprobe models stat-success/open-failure, transient failure and recovery.
// Build against a HEAD library.h copy first to demonstrate the missing-marker red.
#include "net/library.h"
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fstream>
#include <sstream>

namespace fs = std::filesystem;
using rta::net::Library;
static int failures = 0;
static void check(bool ok, const char* label) {
    std::printf("[%s] %s\n", ok ? "PASS" : "FAIL", label);
    std::fflush(stdout);
    if (!ok) ++failures;
}
static void put(const fs::path& path, const std::string& value) {
    std::ofstream(path, std::ios::binary) << value;
}
static std::string get(const fs::path& path) {
    std::ifstream input(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(input), {}};
}
static void env(const char* key, const fs::path& value) { ::setenv(key, value.c_str(), 1); }
static bool waitFile(const fs::path& path) {
    const auto end = std::chrono::steady_clock::now() + std::chrono::seconds(8);
    while (!fs::exists(path) && std::chrono::steady_clock::now() < end)
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    return fs::exists(path);
}
static std::string trackRows(const std::string& index) {
    std::istringstream input(index); std::string line, out;
    while (std::getline(input, line)) if (!line.empty() && line[0] != '#') out += line + '\n';
    return out;
}
struct State {
    bool api = false, directoryComplete = false, metadataHealthy = false, complete = false;
    size_t pending = 0, unreadable = 0;
};
template<class T> static State state(const T& snapshot) {
    State result; result.complete = snapshot.complete;
    if constexpr (requires { snapshot.directoryComplete; snapshot.metadataHealthy;
                            snapshot.metadataPending; snapshot.probeUnreadable; }) {
        result.api = true;
        result.directoryComplete = snapshot.directoryComplete;
        result.metadataHealthy = snapshot.metadataHealthy;
        result.pending = snapshot.metadataPending;
        result.unreadable = snapshot.probeUnreadable;
    }
    return result;
}
static rta::net::LibTrack findTrack(Library& library, const fs::path& path) {
    rta::net::LibTrack track;
    for (size_t i = 0; i < library.trackCount(); ++i)
        if (library.trackAt(i, track) && track.path == path.string()) return track;
    return {};
}
static std::string cueIdentities(Library& library, const fs::path& cue) {
    std::vector<std::string> rows;
    rta::net::LibTrack track;
    for (size_t i = 0; i < library.trackCount(); ++i) {
        if (!library.trackAt(i, track) || track.cuePath != cue.string()) continue;
        rows.push_back(track.path + "|" + track.cuePath + "|" + std::to_string(track.cueNo) + "|" +
            std::to_string(track.cueOff) + "|" + std::to_string(track.cueLen) + "|" +
            std::to_string(track.sampleRate) + "|" + track.title);
    }
    std::sort(rows.begin(), rows.end());
    std::string result;
    for (const auto& row : rows) result += row + '\n';
    return result;
}
static bool forceDue(const fs::path& index, const fs::path& marker) {
    const auto old = get(index);
    std::vector<std::string> roots; std::map<std::string, long long> dirs;
    if (!rta::net::lib_fingerprint_parse(get(marker), old, roots, dirs)) return false;
    std::istringstream input(old); std::string line, next; size_t changed = 0;
    while (std::getline(input, line)) {
        if (line.rfind("#probeRetryV1\t", 0) == 0) {
            const size_t start = std::string("#probeRetryV1\t").size();
            const auto tab = line.find('\t', start);
            if (tab == std::string::npos) return false;
            line.replace(start, tab - start, "0"); ++changed;
        }
        next += line + '\n';
    }
    if (!changed) return false;
    put(index, next);
    put(marker, rta::net::lib_fingerprint_text(roots, dirs, next));
    return true;
}
static int child(const std::string& mode) {
    auto& library = Library::instance(); library.load();
    const fs::path base = std::getenv("PROBE_RETRY_ROOT");
    const fs::path index = base / "library/rlplayer-index.tsv";
    const auto before = get(index), count = get(base / "calls");
    const auto mtime = fs::last_write_time(index);
    std::string reason; bool scanned = true;
    check(library.startStartupScan([&](const auto& why, bool scan) { reason = why; scanned = scan; }), "child startup accepted");
    library.joinScan();
    const auto snapshot = state(library.snapshot());
    const std::string calls = get(base / "calls").substr(count.size());
    if (mode == "invalid") {
        check(scanned && (reason == "invalid" || reason == "invalid-retry-footer"),
              "malformed persisted index/footer triggers explicit invalid rebuild");
        check(snapshot.api && snapshot.metadataHealthy && snapshot.complete,
              "invalid-state rebuild restores known metadata health");
        library.stopScan(); library.joinScan();
        return failures ? 1 : 0;
    }
    check(!scanned && reason == "unchanged", "fresh process performs no full-library scan");
    if (mode == "future") {
        check(calls.empty(), "persisted future retry deadline causes zero ffprobe calls");
        check(get(index) == before && fs::last_write_time(index) == mtime, "future retry skip performs zero index writes");
        check(snapshot.api && snapshot.pending == 2 && !snapshot.metadataHealthy && !snapshot.complete,
              "fresh process exposes pending failures, not fake healthy state");
    } else if (mode == "cue-recover") {
        check(calls.find("cue-single.flac") != std::string::npos && calls.find("cue-left.flac") != std::string::npos &&
              calls.find("cue-right.flac") != std::string::npos && calls.find("good.flac") == std::string::npos,
              "CUE retry targets only pending source files");
        check(snapshot.api && snapshot.pending == 1 && !snapshot.metadataHealthy && !snapshot.complete,
              "multi-FILE CUE retains the still-failed source pending entry");
        check(cueIdentities(library, base / "music/album/single.cue") == get(base / "single-identities"),
              "targeted single-source recovery preserves all three virtual identities");
        check(cueIdentities(library, base / "music/album/multi.cue") == get(base / "multi-identities"),
              "mixed multi-FILE recovery preserves both sources' virtual identities");
    } else if (mode == "cue-final") {
        check(calls.find("cue-right.flac") != std::string::npos && calls.find("cue-left.flac") == std::string::npos &&
              calls.find("cue-single.flac") == std::string::npos && calls.find("good.flac") == std::string::npos,
              "last multi-FILE recovery retries only its remaining source");
        check(snapshot.api && snapshot.pending == 0 && snapshot.metadataHealthy && snapshot.complete,
              "CUE queue clears only after all source probes recover");
        check(cueIdentities(library, base / "music/album/single.cue") == get(base / "single-identities") &&
              cueIdentities(library, base / "music/album/multi.cue") == get(base / "multi-identities"),
              "full CUE recovery never degrades virtual tracks into a whole-file row");
    } else if (mode == "healthy") {
        check(calls.empty() && get(index) == before && fs::last_write_time(index) == mtime,
              "recovered retry index/marker hash survives another process without scan or write");
        check(snapshot.api && snapshot.pending == 0 && snapshot.metadataHealthy && snapshot.complete,
              "fresh process reloads fully healthy recovered metadata");
    } else if (mode == "due-fail") {
        check(calls.find("bad-a.flac") != std::string::npos && calls.find("bad-b.flac") != std::string::npos &&
              calls.find("good.flac") == std::string::npos, "due retry probes failed paths only, never good file");
        check(trackRows(get(index)) == trackRows(before), "failed retry preserves all metadata rows byte-for-byte");
        check(snapshot.api && snapshot.pending == 2 && !snapshot.metadataHealthy && !snapshot.complete,
              "failed due retry remains explicitly unhealthy");
    } else if (mode == "due-recover") {
        check(calls.find("bad-a.flac") != std::string::npos && calls.find("bad-b.flac") != std::string::npos &&
              calls.find("good.flac") == std::string::npos, "recovery still probes pending paths only");
        check(snapshot.api && snapshot.pending == 0 && snapshot.metadataHealthy && snapshot.complete,
              "successful targeted recovery clears queue and restores healthy complete state");
        for (const char* name : {"bad-a.flac", "bad-b.flac"}) {
            const auto track = findTrack(library, base / "music/album" / name);
            check(track.sampleRate == 48000 && track.channels == 2 && track.title == "Preserved title",
                  "recovered metadata persisted and loaded");
        }
    }
    library.stopScan(); library.joinScan();
    return failures ? 1 : 0;
}
static bool runChild(const std::string& executable, const std::string& mode) {
    const pid_t pid = ::fork();
    if (pid == 0) { ::execl(executable.c_str(), executable.c_str(), "--child", mode.c_str(), nullptr); _exit(127); }
    int status = 0;
    return pid > 0 && ::waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}
int main(int argc, char** argv) {
    if (argc == 3 && std::string(argv[1]) == "--child") return child(argv[2]);
    const std::string executable = fs::absolute(argv[0]).string();
    char pattern[] = "/tmp/rlplayer-probe-retry-XXXXXX";
    char* made = ::mkdtemp(pattern);
    if (!made) return 2;
    const fs::path base = made;
    for (const char* dir : {"home", "state", "library", "covers", "music/album"}) fs::create_directories(base / dir);
    env("PROBE_RETRY_ROOT", base);
    env("HOME", base / "home"); env("CFFIXED_USER_HOME", base / "home");
    env("RLPLAYER_STATE_DIR", base / "state"); env("RLPLAYER_LIBRARY_DIR", base / "library");
    env("RLPLAYER_COVER_DIR", base / "covers"); env("RLPLAYER_FFPROBE", base / "ffprobe");
    ::setenv("RLPLAYER_NATIVE_TAGS", "0", 1);
    const auto probe = base / "ffprobe";
    put(probe, R"SH(#!/bin/sh
for file do :; done
name=${file##*/}
printf '%s\n' "$name" >> "$PROBE_RETRY_ROOT/calls"
if [ -f "$PROBE_RETRY_ROOT/block" ]; then
  : > "$PROBE_RETRY_ROOT/started"
  i=0
  while [ ! -f "$PROBE_RETRY_ROOT/release" ] && [ $i -lt 500 ]; do sleep .01; i=$((i+1)); done
fi
if [ -f "$PROBE_RETRY_ROOT/fail-all" ] || [ -f "$PROBE_RETRY_ROOT/fail-$name" ] || { [ "$name" != good.flac ] && [ -f "$PROBE_RETRY_ROOT/fail-bad" ]; }; then
  printf '%s: No such file or directory\n' "$file" >&2
  exit 1
fi
if [ -f "$PROBE_RETRY_ROOT/fail-once" ] && [ ! -f "$PROBE_RETRY_ROOT/once-done" ]; then
  : > "$PROBE_RETRY_ROOT/once-done"
  exit 1
fi
printf '[STREAM]\ncodec_type=audio\ncodec_name=flac\nsample_rate=48000\nchannels=2\nbits_per_raw_sample=24\n[/STREAM]\n[FORMAT]\nduration=2\nTAG:title=Preserved title\nTAG:artist=Fixture artist\nTAG:album=Fixture album\n[/FORMAT]\n'
)SH");
    ::chmod(probe.c_str(), 0700);
    for (const char* name : {"good.flac", "bad-a.flac", "bad-b.flac"}) put(base / "music/album" / name, "synthetic audio fixture");
    put(base / "fail-bad", "");
    const auto index = base / "library/rlplayer-index.tsv", marker = base / "library/rlplayer-index.dirs.tsv";
    auto& library = Library::instance(); library.load(); library.setScanThreads(1);
    check(library.addRoot((base / "music").string()), "add isolated synthetic library root");
    check(library.startScan(true), "initial partial-failure scan accepted"); library.joinScan();
    auto snapshot = state(library.snapshot());
    const bool partialMarker = fs::exists(marker);
    check(partialMarker, "one good and two unreadable files still persist directory fingerprint (HEAD red)");
    check(snapshot.api && snapshot.directoryComplete && snapshot.pending == 2 && snapshot.unreadable == 2 &&
          !snapshot.metadataHealthy && !snapshot.complete, "directory completeness and visible metadata failures are separate");
    const auto good = findTrack(library, base / "music/album/good.flac");
    check(good.sampleRate == 48000 && good.channels == 2 && good.title == "Preserved title", "real fake-probe output reaches good track metadata");
    check(get(base / "calls").find("bad-a.flac") != std::string::npos, "stat-visible bad filename really reaches subprocess");
    if (partialMarker && snapshot.api) {
        check(runChild(executable, "future"), "new process skips whole library and future pending jobs");
        check(forceDue(index, marker), "make only persisted queue due with consistent marker hash");
        check(runChild(executable, "due-fail"), "new process retries only due failed files");
        check(runChild(executable, "future"), "failed retry writes a valid marker hash and renewed backoff");
        fs::remove(base / "fail-bad");
        check(forceDue(index, marker), "make recovery queue due");
        check(runChild(executable, "due-recover"), "new process recovers metadata through targeted retry");
        check(runChild(executable, "healthy"), "recovered retry writes a valid marker hash for future startups");
    }
    fs::remove(base / "fail-bad");
    check(library.startScan(true), "establish all-good metadata before preservation case"); library.joinScan();
    const auto oldGood = findTrack(library, base / "music/album/good.flac");
    put(base / "fail-all", "");
    check(library.startScan(true), "force full scan with global probe failure"); library.joinScan();
    const auto preserved = findTrack(library, base / "music/album/good.flac");
    snapshot = state(library.snapshot());
    check(preserved.sampleRate == oldGood.sampleRate && preserved.channels == oldGood.channels &&
          preserved.title == oldGood.title && preserved.mtime == oldGood.mtime && preserved.size == oldGood.size,
          "failed refresh preserves prior usable metadata and successful file signature");
    check(snapshot.api && snapshot.pending == 3 && !snapshot.metadataHealthy && !snapshot.complete,
          "total probe failure is never reported healthy or complete");
    fs::remove(base / "fail-all"); put(base / "fail-once", "");
    check(library.startScan(true), "transient one-shot failure scan accepted"); library.joinScan();
    snapshot = state(library.snapshot());
    check(snapshot.api && snapshot.pending == 0 && snapshot.metadataHealthy && snapshot.complete,
          "bounded immediate retry heals transient probe failure");
    fs::remove(base / "fail-once");

    // CUE identities must survive a failed refresh and source-targeted recovery.
    const auto album = base / "music/album", singleCue = album / "single.cue", multiCue = album / "multi.cue";
    for (const char* name : {"cue-single.flac", "cue-left.flac", "cue-right.flac"}) put(album / name, "synthetic CUE audio");
    put(singleCue, "TITLE \"Single\"\nFILE \"cue-single.flac\" WAVE\n"
        " TRACK 01 AUDIO\n TITLE \"S1\"\n INDEX 01 00:00:00\n"
        " TRACK 02 AUDIO\n TITLE \"S2\"\n INDEX 01 00:00:30\n"
        " TRACK 03 AUDIO\n TITLE \"S3\"\n INDEX 01 00:01:00\n");
    put(multiCue, "TITLE \"Multi\"\nFILE \"cue-left.flac\" WAVE\n"
        " TRACK 01 AUDIO\n TITLE \"L1\"\n INDEX 01 00:00:00\n"
        " TRACK 02 AUDIO\n TITLE \"L2\"\n INDEX 01 00:01:00\n"
        "FILE \"cue-right.flac\" WAVE\n"
        " TRACK 03 AUDIO\n TITLE \"R1\"\n INDEX 01 00:00:00\n"
        " TRACK 04 AUDIO\n TITLE \"R2\"\n INDEX 01 00:01:00\n");
    library.startScan(true); library.joinScan();
    const auto singleIds = cueIdentities(library, singleCue), multiIds = cueIdentities(library, multiCue);
    check(std::count(singleIds.begin(), singleIds.end(), '\n') == 3 &&
          std::count(multiIds.begin(), multiIds.end(), '\n') == 4, "establish three-track single-source and four-track multi-FILE CUE fixtures");
    put(base / "single-identities", singleIds); put(base / "multi-identities", multiIds);
    for (const char* name : {"cue-single.flac", "cue-left.flac", "cue-right.flac"}) put(base / (std::string("fail-") + name), "");
    library.startScan(true); library.joinScan();
    snapshot = state(library.snapshot());
    check(snapshot.api && snapshot.pending == 3 && !snapshot.metadataHealthy, "failed CUE sources each have their own pending record");
    check(cueIdentities(library, singleCue) == singleIds && cueIdentities(library, multiCue) == multiIds,
          "failed refresh preserves cuePath/cueNo/cueOff/cueLen and virtual-track metadata");
    fs::remove(base / "fail-cue-single.flac"); fs::remove(base / "fail-cue-left.flac");
    check(forceDue(index, marker) && runChild(executable, "cue-recover"), "CUE retry-only recovery does not full scan or clear unrelated failed source");
    fs::remove(base / "fail-cue-right.flac");
    check(forceDue(index, marker) && runChild(executable, "cue-final"), "remaining multi-FILE source recovers without losing virtual tracks");
    // A malformed retry footer must not silently disappear and claim healthy.
    {
        const auto old = get(index);
        std::vector<std::string> roots; std::map<std::string, long long> dirs;
        check(rta::net::lib_fingerprint_parse(get(marker), old, roots, dirs), "recovered marker parses before corruption fixture");
        const auto broken = old + "#probeRetryV1\tnot-a-deadline\t1\tzz\n";
        put(index, broken); put(marker, rta::net::lib_fingerprint_text(roots, dirs, broken));
        check(runChild(executable, "invalid"), "corrupt retry footer cannot masquerade as an empty healthy queue");
    }
    {
        const auto old = get(index);
        auto broken = old;
        broken.replace(0, std::string("#libIndexV\t4").size(), "#libIndexV\t0");
        put(index, broken);
        check(runChild(executable, "invalid"), "unsupported index version cannot bypass startup rebuild");
    }
    // Reload the parent singleton's snapshot from the child's newly persisted index.
    library.load();

    put(base / "block", "");
    check(library.startScan(true), "blocked cancellation scan accepted");
    check(waitFile(base / "started"), "real fake ffprobe entered deterministic block");
    library.stopScan();
    put(base / "release", ""); library.joinScan();
    check(!library.snapshot().complete && !fs::exists(marker), "cancelled scan stays dirty and cannot save directory marker");
    fs::remove(base / "block");
    library.startScan(true); library.joinScan();
    fs::permissions(base / "music/album", fs::perms::none);
    if (::geteuid() != 0) {
        library.startScan(true); library.joinScan();
        check(!library.snapshot().complete && library.snapshot().failedDirs > 0 && !fs::exists(marker),
              "failed directory enumeration stays dirty rather than metadata-only pending");
    }
    fs::permissions(base / "music/album", fs::perms::owner_all);
    library.stopScan(); library.joinScan();
    fs::remove_all(base);
    std::printf("probe-retry failures=%d\n", failures);
    return failures ? 1 : 0;
}
