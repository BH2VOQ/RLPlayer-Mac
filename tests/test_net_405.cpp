// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_net_405.cpp — 验证副作用端点强制 POST（405）与只读/豁免端点允许 GET
//
// 判据覆盖：
//   ① curl "http://127.0.0.1:<port>/api/play?file=x" (GET) -> 405 Method Not Allowed
//   ② curl -X POST "http://127.0.0.1:<port>/api/play" -> 200 (不是 405)
//   ③ curl "http://127.0.0.1:<port>/api/status" (GET) -> 200 OK
//   ④ curl "http://127.0.0.1:<port>/api/llm" (GET) -> 200 OK (豁免端点)

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <chrono>
#include <thread>
#include <array>
#include <memory>
#include <fstream>
#include <sstream>
#include <filesystem>
#include <sys/types.h>
#include <signal.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>

namespace fs = std::filesystem;

static int g_fail = 0;
static void ck(bool cond, const std::string& what, const std::string& detail = "") {
    if (cond) {
        std::printf("  [PASS] %s\n", what.c_str());
    } else {
        std::printf("  [FAIL] %s %s\n", what.c_str(), detail.c_str());
        ++g_fail;
    }
}

// 执行 shell 命令并捕获输出
static std::string exec_cmd(const std::string& cmd) {
    std::array<char, 256> buffer;
    std::string result;
    std::unique_ptr<FILE, decltype(&pclose)> pipe(popen(cmd.c_str(), "r"), pclose);
    if (!pipe) return "";
    while (fgets(buffer.data(), buffer.size(), pipe.get()) != nullptr) {
        result += buffer.data();
    }
    while (!result.empty() && (result.back() == '\r' || result.back() == '\n')) {
        result.pop_back();
    }
    return result;
}

// 只读核验进程：PID/uid/comm 是否完全属于本次测试 spawn 的 rtaweb
static bool verify_spawned_process(pid_t targetPid, uid_t expectedUid, const std::string& expectedCommSubstr) {
    if (targetPid <= 0) return false;
    std::string cmd = "ps -p " + std::to_string(targetPid) + " -o pid=,uid=,comm=";
    std::string out = exec_cmd(cmd);
    if (out.empty()) return false;
    std::istringstream iss(out);
    pid_t p = 0;
    uid_t u = 0;
    std::string comm;
    if (!(iss >> p >> u >> comm)) return false;
    if (p != targetPid) return false;
    if (u != expectedUid) return false;
    if (comm.find(expectedCommSubstr) == std::string::npos) return false;
    return true;
}

// 优雅且安全退出子进程：核验属主，POST /api/quit 优先，超时兜底只发 SIGTERM，绝不 force kill
static void stop_spawned_process(pid_t pid, uint16_t port) {
    if (pid <= 0) return;
    int observed = 0;
    if (::waitpid(pid, &observed, WNOHANG) == pid) return;
    if (!verify_spawned_process(pid, ::getuid(), "rtaweb")) {
        ck(false, "停止前属主核验失败：不发请求或信号");
        return;
    }
    const std::string listener = exec_cmd("lsof -nP -iTCP:" + std::to_string(port) + " -sTCP:LISTEN -t");
    if (listener == std::to_string(pid)) {
        std::string quitCmd = "curl -s -m 3 -X POST \"http://127.0.0.1:" + std::to_string(port) + "/api/quit\" >/dev/null 2>&1";
        exec_cmd(quitCmd);
    }
    int status = 0;
    for (int i = 0; i < 50; ++i) {
        if (::waitpid(pid, &status, WNOHANG) == pid) return;
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    // 若未退出，stop 前核验自己 spawn 的 PID / uid / 命令（只读），核验通过后只发 SIGTERM，绝不 force kill
    int st = 0;
    if (::waitpid(pid, &st, WNOHANG) == 0) {
        if (verify_spawned_process(pid, ::getuid(), "rtaweb")) {
            ::kill(pid, SIGTERM);
            for (int i = 0; i < 50; ++i) {
                if (::waitpid(pid, &status, WNOHANG) == pid) return;
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
        } else {
            std::printf("  [WARN] PID %d 属主/命令核验不通过，跳过 SIGTERM 以免误伤\n", (int)pid);
        }
    }
}

// 探测端口是否已开始应答
static bool wait_port_ready(uint16_t port, int timeoutMs = 5000) {
    auto start = std::chrono::steady_clock::now();
    while (true) {
        int s = ::socket(AF_INET, SOCK_STREAM, 0);
        if (s >= 0) {
            sockaddr_in a{};
            a.sin_family = AF_INET;
            a.sin_port = htons(port);
            a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            if (::connect(s, (sockaddr*)&a, sizeof(a)) == 0) {
                ::close(s);
                return true;
            }
            ::close(s);
        }
        auto now = std::chrono::steady_clock::now();
        if (std::chrono::duration_cast<std::chrono::milliseconds>(now - start).count() > timeoutMs) {
            return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
}

int main(int argc, char* argv[]) {
    (void)argc;
    (void)argv;
    std::printf("=== test_net_405: 副作用端点 405 与豁免端点验证 ===\n");

    // 寻找 rtaweb 二进制路径（ctest 运行时的 cwd 可能是 build-mac，直接运行时可能是仓库根）
    fs::path exeDir = fs::current_path();
    fs::path rtawebBin = exeDir / "rtaweb";
    if (!fs::exists(rtawebBin)) {
        rtawebBin = exeDir / "build-mac" / "rtaweb";
    }
    if (!fs::exists(rtawebBin)) {
        rtawebBin = exeDir / "RLPlayer" / "build-mac" / "rtaweb";
    }
    if (!fs::exists(rtawebBin)) {
        // 尝试基于 __FILE__ 的绝对路径解析
        fs::path srcDir = fs::path(__FILE__).parent_path().parent_path();
        rtawebBin = srcDir / "build-mac" / "rtaweb";
    }

    if (!fs::exists(rtawebBin)) {
        std::printf("  [FAIL] 找不到 rtaweb 可执行文件: %s\n", rtawebBin.string().c_str());
        return 1;
    }

    rtawebBin = fs::absolute(rtawebBin);
    // 固定测试服务端口使用 19101 允许范围并串行复用
    const uint16_t testPort = 19101;
    const std::string listeners = exec_cmd("lsof -nP -iTCP:19101 -sTCP:LISTEN -t");
    if (!listeners.empty()) { ck(false, "测试端口已有属主，不启动或停止任何服务", listeners); return 1; }
    int probe = ::socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in bindAddr{}; bindAddr.sin_family = AF_INET; bindAddr.sin_port = htons(testPort);
    bindAddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int reuse = 1; ::setsockopt(probe, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    const bool freePort = probe >= 0 && ::bind(probe, (sockaddr*)&bindAddr, sizeof(bindAddr)) == 0;
    if (probe >= 0) ::close(probe);
    if (!freePort) { ck(false, "测试端口预绑定检查失败"); return 1; }

    // 独立 mkdtemp 根目录，全隔离 HOME / CFFIXED_USER_HOME / STATE / LIBRARY / COVER
    char tempTemplate[] = "/tmp/rta_net405_iso_XXXXXX";
    char* tempDir = ::mkdtemp(tempTemplate);
    if (!tempDir) {
        std::printf("  [FAIL] mkdtemp 创建隔离目录失败\n");
        return 1;
    }
    fs::path isoRoot(tempDir);
    fs::path isoHome = isoRoot / "home";
    fs::path isoState = isoRoot / "state";
    fs::path isoLib = isoRoot / "lib";
    fs::path isoCover = isoRoot / "cover";
    fs::path isoLogs = isoRoot / "logs";

    std::error_code ec;
    fs::create_directories(isoHome / "Library" / "Application Support" / "RLPlayer", ec);
    fs::create_directories(isoState, ec);
    fs::create_directories(isoLib, ec);
    fs::create_directories(isoCover, ec);
    fs::create_directories(isoLogs, ec);

    // 预写入隔离的 rlplayer-settings.conf：backend=null / metaon=0 / metallm=0 / volume=-120
    const std::string confContent =
        "backend=null\n"
        "metaon=0\n"
        "metallm=0\n"
        "volume=-120\n";
    {
        std::ofstream cf(isoState / "rlplayer-settings.conf");
        cf << confContent;
    }
    {
        std::ofstream cf(isoHome / "Library" / "Application Support" / "RLPlayer" / "rlplayer-settings.conf");
        cf << confContent;
    }

    const std::string isoHomeS = isoHome.string();
    const std::string isoStateS = isoState.string();
    const std::string isoLibS = isoLib.string();
    const std::string isoCoverS = isoCover.string();
    const std::string outLogFile = (isoLogs / "rtaweb_stdout_stderr.log").string();

    // 启动 rtaweb 子进程
    pid_t pid = fork();
    if (pid == 0) {
        // 子进程环境完全隔离，绝不读用户任何真实配置
        ::setsid();
        ::chdir(isoRoot.c_str());
        ::setenv("HOME", isoHomeS.c_str(), 1);
        ::setenv("CFFIXED_USER_HOME", isoHomeS.c_str(), 1);
        ::setenv("RLPLAYER_STATE_DIR", isoStateS.c_str(), 1);
        ::setenv("RLPLAYER_LIBRARY_DIR", isoLibS.c_str(), 1);
        ::setenv("RLPLAYER_COVER_DIR", isoCoverS.c_str(), 1);

        // log 重定向专属目录
        int fd = ::open(outLogFile.c_str(), O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (fd >= 0) {
            ::dup2(fd, STDOUT_FILENO);
            ::dup2(fd, STDERR_FILENO);
            if (fd > 2) ::close(fd);
        }

        std::string pStr = std::to_string(testPort);
        execl(rtawebBin.c_str(), rtawebBin.c_str(), "--port", pStr.c_str(), "--no-browser", nullptr);
        _exit(127);
    } else if (pid < 0) {
        std::printf("  [FAIL] fork() 失败\n");
        fs::remove_all(isoRoot, ec);
        return 1;
    }

    // 等待服务就绪
    if (!wait_port_ready(testPort, 6000)) {
        std::printf("  [FAIL] rtaweb 未能在超时时间内监听端口 %u\n", testPort);
        stop_spawned_process(pid, testPort);
        fs::remove_all(isoRoot, ec);
        return 1;
    }
    const std::string listenerPid = exec_cmd("lsof -nP -iTCP:19101 -sTCP:LISTEN -t");
    if (listenerPid != std::to_string(pid)) {
        ck(false, "监听属主不是本次子进程，不发业务请求", listenerPid);
        stop_spawned_process(pid, testPort);
        return 1;
    }

    // ① GET /api/play?file=x -> 405
    {
        std::string cmd = "curl -s -o /dev/null -w \"%{http_code}\" \"http://127.0.0.1:" +
                          std::to_string(testPort) + "/api/play?file=x\"";
        std::string code = exec_cmd(cmd);
        ck(code == "405", "① GET /api/play?file=x 必须返回 405 Method Not Allowed", "实际: " + code);
    }

    // ② POST /api/play -> 不是 405
    {
        std::string cmd = "curl -s -o /dev/null -w \"%{http_code}\" -X POST \"http://127.0.0.1:" +
                          std::to_string(testPort) + "/api/play\"";
        std::string code = exec_cmd(cmd);
        ck(!code.empty() && code != "405", "② POST /api/play 允许通过（不为 405）", "实际: " + code);
    }

    // ③ GET /api/status -> 200
    {
        std::string cmd = "curl -s -o /dev/null -w \"%{http_code}\" \"http://127.0.0.1:" +
                          std::to_string(testPort) + "/api/status\"";
        std::string code = exec_cmd(cmd);
        ck(code == "200", "③ GET /api/status 正常返回 200 OK", "实际: " + code);
    }

    // ④ GET /api/llm -> 200 (exempt 豁免端点)
    {
        std::string cmd = "curl -s -o /dev/null -w \"%{http_code}\" \"http://127.0.0.1:" +
                          std::to_string(testPort) + "/api/llm\"";
        std::string code = exec_cmd(cmd);
        ck(code == "200", "④ GET /api/llm 豁免只读返回 200 OK", "实际: " + code);
    }

    // 优雅退出进程并核验属主
    stop_spawned_process(pid, testPort);

    // 清理临时目录
    fs::remove_all(isoRoot, ec);

    std::printf("=== 测试完毕，失败数: %d ===\n", g_fail);
    return g_fail == 0 ? 0 : 1;
}
