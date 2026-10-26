// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_libroot_regress.cpp — 库根绝对路径不变量 + --music-dir 写盘顺序回归
//
// 2026-10-26 BUG（用户截图：点侧栏「文件夹」主区域显示「目录不存在」）根因链三步：
//   (a) tools/rtaweb.cpp 的 cli_main() 里，--music-dir 处理块**早于** setenv(RLPLAYER_PORT)。
//       Library::confLeaf() 靠 RLPLAYER_PORT 决定文件名后缀（非 8899 加 ".p<port>"），
//       setenv 之前变量为空 ⟹ 后缀不生效 ⟹ 不管 --port 是多少，addRootEx 都写进
//       **默认实例**的 rlplayer-library.conf（用户真实那份）。
//   (b) Library::addRootEx() 只检查 is_directory，不要求绝对路径 ⟹ "./data" 被原样存盘。
//   (c) 相对路径在 .app 里必然解析失败（双击启动 cwd=/ ⟹ ./data → /data），
//       GET /api/files 拿 roots().front() 当默认目录 ⟹ exists 为假 ⟹ 报「目录不存在」。
//
// 判据（铁律 3：测试"通过"≠"测对了东西"）：
//   [1] addRootEx 必须拒绝相对根，且 why 必须点明「绝对路径」。
//       ★ 对照：同一测试里对**真实存在的绝对目录**必须接受 —— 否则「全拒绝」也能过，
//         那等于把库功能删了（铁律：功能不能删除）。
//       ★ 对抗性：先把 "./data" 建成**真实存在的目录**再喂进去。这样"旧代码接受它"
//         的唯一原因就是"没校验绝对性"，而不是"目录不存在"——判据不会被巧合蒙混过关。
//   [2] 核心：fork+exec 起真 rtaweb --port 8937 --music-dir <绝对临时音乐目录>，
//       RLPLAYER_LIBRARY_DIR 指向临时 lib 目录，里面**预置**一份默认 conf（含哨兵根）。
//       跑完断言：默认 conf **逐字节不变**（哨兵还在），且 .p8937 conf 是 --music-dir 那个
//       绝对目录。这一条直接证明「非默认实例不再写坏默认实例的配置」。
//   [3] GET /api/files 不带 dir：conf 里放坏根（./data）在前 + 真实目录在后，
//       ok 必须为 true 且 dir 必须是**真实存在**的目录（不是 ./data）。
//   [4] GET /api/files?dir=<不存在>：ok 必须 false 且 error **带上该路径**
//       （旧代码只说「目录不存在」，等于把根因藏起来）。
//
// 隔离：所有路径都在 temp_directory_path() 下，**绝不触碰**
//   ~/Library/Application Support/RLPlayer/（用户真实数据）。
// 停服务：POST /api/quit 优先，超时兜底只 kill -TERM（铁律 2：绝不 force-kill）。
#include "test_compat_posix.h"   // 必须最顶部：POSIX 垫片 + platform/path.h

#include "net/library.h"

#include <array>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

namespace fs = std::filesystem;
using rta::net::Library;

// ---------------- 输出 / 计数（沿用 tests/test_library.cpp 的 ck 风格）----------------
static int g_fail = 0;
static int g_pass = 0;
static void ck(bool cond, const std::string& what, const std::string& detail = "") {
    if (cond) { std::printf("  [PASS] %s\n", what.c_str()); ++g_pass; }
    else { std::printf("  [FAIL] %s  %s\n", what.c_str(), detail.c_str()); ++g_fail; }
}

static std::string u8str(const fs::path& p) {
    const std::u8string u = p.u8string();
    return std::string(reinterpret_cast<const char*>(u.data()), u.size());
}

static bool readAll(const fs::path& p, std::string& out) {
    std::ifstream f(p, std::ios::binary);
    if (!f) return false;
    out.assign((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    return true;
}
static bool writeAll(const fs::path& p, const std::string& s) {
    std::ofstream f(p, std::ios::binary | std::ios::trunc);
    if (!f) return false;
    f.write(s.data(), (std::streamsize)s.size());
    return f.good();
}

// 极简 JSON 取值：够用即可（只取本测试自己断言的那两个字段，不引入 JSON 依赖）
static std::string jsonStr(const std::string& js, const std::string& key) {
    const std::string pat = "\"" + key + "\":\"";
    const size_t a = js.find(pat);
    if (a == std::string::npos) return "";
    const size_t b = a + pat.size();
    const size_t e = js.find('"', b);
    if (e == std::string::npos) return "";
    return js.substr(b, e - b);
}

// ---------------- 进程 / 端口 ----------------
static bool portFree(int port) {
    int s = ::socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return false;
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int one = 1;
    ::setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    const bool free = (::bind(s, (sockaddr*)&a, sizeof(a)) == 0);
    ::close(s);
    return free;
}

static bool portAnswers(int port) {
    int s = ::socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return false;
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    const bool ok = (::connect(s, (sockaddr*)&a, sizeof(a)) == 0);
    ::close(s);
    return ok;
}

static std::string execSh(const std::string& cmd) {
    std::array<char, 4096> buf{};
    std::string res;
    std::unique_ptr<FILE, decltype(&pclose)> pipe(popen(cmd.c_str(), "r"), pclose);
    if (!pipe) return "";
    while (fgets(buf.data(), (int)buf.size(), pipe.get()) != nullptr) res += buf.data();
    return res;
}

static std::string curlGet(int port, const std::string& path) {
    return execSh("curl -s -m 8 'http://127.0.0.1:" + std::to_string(port) + path + "'");
}

// 起 rtaweb：cwd 固定为 "/"（**忠实复现 .app 双击启动的 cwd**，相对路径因此必然解析失败）。
// 返回子进程 pid，失败返回 -1。
static pid_t spawnRtaweb(const std::string& exe, int port, const std::vector<std::string>& extraArgs,
                         const std::string& libDir, const std::string& logPath) {
    std::vector<std::string> argvS = { exe, "--port", std::to_string(port), "--no-browser" };
    for (const auto& a : extraArgs) argvS.push_back(a);
    std::vector<char*> argv;
    argv.reserve(argvS.size() + 1);
    for (auto& s : argvS) argv.push_back(const_cast<char*>(s.c_str()));
    argv.push_back(nullptr);

    const pid_t pid = ::fork();
    if (pid != 0) return pid;

    // ---- 子进程 ----
    ::setsid();                       // 独立进程组：Ctrl+C 不误伤测试自身
    ::chdir("/");                     // .app 双击形态的 cwd
    // 关键：清掉从测试进程继承来的 RLPLAYER_PORT。否则"setenv 太晚"这个 BUG 会被
    // 继承值掩盖（confLeaf 照样能拿到端口），回归测试就失去意义。
    ::unsetenv("RLPLAYER_PORT");
    ::setenv("RLPLAYER_LIBRARY_DIR", libDir.c_str(), 1);

    const int fd = ::open(logPath.c_str(), O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd >= 0) { ::dup2(fd, STDOUT_FILENO); ::dup2(fd, STDERR_FILENO); if (fd > 2) ::close(fd); }

    ::execv(exe.c_str(), argv.data());
    ::_exit(127);
}

// 优雅停：POST /api/quit → 等退出；超时兜底只 SIGTERM（铁律 2）
static void stopRtaweb(pid_t pid, int port) {
    if (pid <= 0) return;
    execSh("curl -s -m 5 -X POST 'http://127.0.0.1:" + std::to_string(port) + "/api/quit' >/dev/null 2>&1");
    int status = 0;
    for (int i = 0; i < 80; ++i) {                     // 最多 ~8s
        if (::waitpid(pid, &status, WNOHANG) == pid) return;
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    ::kill(pid, SIGTERM);                              // 兜底：绝不 SIGKILL
    ::waitpid(pid, &status, 0);
}

static bool waitPort(int port, int ms) {
    const auto t0 = std::chrono::steady_clock::now();
    while (true) {
        if (portAnswers(port)) return true;
        const auto ms_elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                                    std::chrono::steady_clock::now() - t0).count();
        if (ms_elapsed > ms) return false;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
}

int main() {
    SetConsoleOutputCP(CP_UTF8);
    std::printf("== 库根绝对路径 / --music-dir 写盘顺序 回归 ==\n");

    std::error_code ec;
    const fs::path tmp = fs::temp_directory_path() / "rta_libroot_regress";
    fs::remove_all(tmp, ec);
    fs::create_directories(tmp / "lib", ec);
    fs::create_directories(tmp / "music_ok", ec);     // 真实存在的绝对目录（对照组）
    fs::create_directories(tmp / "music_cli", ec);    // --music-dir 指向的真实目录

    const std::string tmpS    = u8str(tmp);
    const std::string libS    = u8str(tmp / "lib");
    const std::string musicOk = u8str(tmp / "music_ok");
    const std::string musicCli= u8str(tmp / "music_cli");

    // 全程把库配置/索引关进临时目录 —— 绝不写用户 Application Support
    _putenv_s("RLPLAYER_LIBRARY_DIR", libS.c_str());
    _putenv_s("RLPLAYER_PORT", "");                    // 未设 = 默认实例（confLeaf 无后缀）

    // =====================================================================
    // [1] addRootEx 的绝对路径不变量（含对照组）
    // =====================================================================
    std::printf("\n== [1] 库根必须是绝对路径 ==\n");
    {
        const fs::path oldCwd = fs::current_path(ec);
        fs::create_directories(tmp / "data", ec);       // 让 "./data" 成为**真实存在**的相对目录
        fs::current_path(tmp, ec);                      // cwd = tmp ⟹ ./data 有效

        Library& L = Library::instance();
        const auto bad = L.addRootEx("./data");
        ck(!bad.ok, "相对根 \"./data\" 被拒绝", "ok=" + std::to_string((int)bad.ok));
        ck(bad.why.find("绝对路径") != std::string::npos,
           "拒绝理由点明「绝对路径」", "why=" + bad.why);

        // 对照：绝对目录必须仍然能加（防止"全拒绝"式假绿）
        const auto good = L.addRootEx(musicOk);
        ck(good.ok, "对照：真实绝对目录仍可添加", "why=" + good.why);
        bool recorded = false;
        for (const auto& r : L.roots()) if (r == musicOk) recorded = true;
        ck(recorded, "对照：绝对根已记入 roots()");
        for (const auto& r : L.roots()) L.removeRoot(r);   // 清场，别影响后面

        fs::current_path(oldCwd, ec);
    }

    // 找 rtaweb 可执行文件（CMake 生成的测试都在 build-mac 下，同目录即可）
    const fs::path exeDir = fs::path(exe_path_utf8()).parent_path();
    std::string rtaweb;
    for (const char* cand : { "rtaweb" }) {
        const fs::path p = exeDir / cand;
        if (fs::is_regular_file(p, ec)) { rtaweb = u8str(p); break; }
    }
    if (rtaweb.empty()) {
        // 兜底：源码树里的 build-mac（本机固定位置）
        const fs::path p = "/Users/august/Downloads/DQ/RLPlayer/build-mac/rtaweb";
        if (fs::is_regular_file(p, ec)) rtaweb = p.string();
    }
    ck(!rtaweb.empty(), "找到 rtaweb 可执行文件", rtaweb.empty() ? "(未找到，后续子进程判据无法执行)" : rtaweb);
    if (rtaweb.empty()) { std::printf("\nFAIL=%d PASS=%d\n", g_fail, g_pass); return 1; }

    // =====================================================================
    // [2] 核心：--music-dir 不得写坏默认实例的 conf（写盘顺序回归）
    // =====================================================================
    std::printf("\n== [2] --music-dir 写盘顺序（核心）==\n");
    const int kPort = 8937;
    ck(portFree(kPort), "端口 " + std::to_string(kPort) + " 空闲可用（不会碰 8899 用户实例）");
    {
        const fs::path defConf = tmp / "lib" / "rlplayer-library.conf";
        const std::string sentinel = "# sentinel 哨兵\n/\xE5\x93\xA8\xE5\x85\xB5/\xE4\xB8\x8D\xE8\xAF\xA5\xE8\xA2\xAB\xE6\x94\xB9\n";
        writeAll(defConf, sentinel);
        std::string before;
        readAll(defConf, before);

        const pid_t pid = spawnRtaweb(rtaweb, kPort, { "--music-dir", musicCli }, libS,
                                      u8str(tmp / "rtaweb_8937.log"));
        ck(pid > 0, "rtaweb 子进程已启动", "pid=" + std::to_string((int)pid));
        ck(waitPort(kPort, 15000), "rtaweb 端口就绪");

        std::string after;
        readAll(defConf, after);
        ck(before == after, "默认实例 conf 逐字节未被改动（哨兵还在）",
           "before=" + std::to_string(before.size()) + "B after=" + std::to_string(after.size()) + "B [" + after + "]");
        ck(after.find("\xE5\x93\xA8\xE5\x85\xB5") != std::string::npos, "哨兵根仍存在于默认 conf");

        const fs::path pConf = tmp / "lib" / ("rlplayer-library.conf.p" + std::to_string(kPort));
        std::string pc;
        const bool has = readAll(pConf, pc);
        ck(has, "实例私有 conf 已生成：" + u8str(pConf.filename()));
        ck(pc.find(musicCli) != std::string::npos,
           "实例私有 conf 存的是 --music-dir 的**绝对**目录", "[" + pc + "]");

        // 顺手在**这个**实例上验判据 [4]（显式 dir 不存在 → 错误里要带路径）
        const std::string miss = "/no_such_dir_rta_libroot/xyz";
        const std::string r = curlGet(kPort, "/api/files?dir=" + miss);
        ck(r.find("\"ok\":false") != std::string::npos, "[4] 显式不存在的 dir → ok:false", r);
        ck(r.find(miss) != std::string::npos, "[4] 错误信息里带上那个不存在的路径", r);

        stopRtaweb(pid, kPort);
        ck(!portAnswers(kPort), "rtaweb 已退出（POST /api/quit）");
    }

    // =====================================================================
    // [3] GET /api/files 不带 dir：坏根在前也要挑到真实存在的目录
    // =====================================================================
    std::printf("\n== [3] /api/files 默认目录兜底 ==\n");
    const int kPort2 = 8938;
    ck(portFree(kPort2), "端口 " + std::to_string(kPort2) + " 空闲可用");
    {
        // conf 里放一个坏根（相对路径 ./data，cwd=/ 时必不存在）在前，真实目录在后
        const fs::path pConf2 = tmp / "lib" / ("rlplayer-library.conf.p" + std::to_string(kPort2));
        writeAll(pConf2, "# RLPlayer 音乐库根目录，每行一个\n./data\n" + musicOk + "\n");

        const pid_t pid = spawnRtaweb(rtaweb, kPort2, {}, libS, u8str(tmp / "rtaweb_8938.log"));
        ck(pid > 0, "rtaweb 子进程已启动（坏根实例）", "pid=" + std::to_string((int)pid));
        ck(waitPort(kPort2, 15000), "rtaweb 端口就绪");

        const std::string r = curlGet(kPort2, "/api/files");
        const std::string dir = jsonStr(r, "dir");
        ck(r.find("\"ok\":true") != std::string::npos, "不带 dir → ok:true（不再是「目录不存在」）", r);
        ck(!dir.empty() && dir != "./data", "默认目录不是那个坏根 ./data", "dir=" + dir);
        ck(!dir.empty() && fs::is_directory(fs::path(dir), ec),
           "默认目录在磁盘上真实存在", "dir=" + dir);

        stopRtaweb(pid, kPort2);
        ck(!portAnswers(kPort2), "rtaweb 已退出（POST /api/quit）");
    }

    // ---- 清理 ----
    fs::remove_all(tmp, ec);

    std::printf("\n== 汇总 ==\n  PASS=%d  FAIL=%d\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
