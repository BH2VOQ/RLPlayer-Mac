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
#include <filesystem>
#include <sys/types.h>
#include <signal.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

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

    const uint16_t testPort = 8911;

    // 启动 rtaweb 子进程
    pid_t pid = fork();
    if (pid == 0) {
        // 子进程
        std::string pStr = std::to_string(testPort);
        execl(rtawebBin.c_str(), rtawebBin.c_str(), "--port", pStr.c_str(), "--no-browser", nullptr);
        _exit(127);
    } else if (pid < 0) {
        std::printf("  [FAIL] fork() 失败\n");
        return 1;
    }

    // 等待服务就绪
    if (!wait_port_ready(testPort, 6000)) {
        std::printf("  [FAIL] rtaweb 未能在超时时间内监听端口 %u\n", testPort);
        kill(pid, SIGTERM);
        int st = 0;
        waitpid(pid, &st, 0);
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

    // 优雅退出进程
    kill(pid, SIGTERM);
    int status = 0;
    waitpid(pid, &status, 0);

    std::printf("=== 测试完毕，失败数: %d ===\n", g_fail);
    return g_fail == 0 ? 0 : 1;
}
