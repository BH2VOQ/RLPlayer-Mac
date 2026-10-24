// platform/macos/process_posix.h — process.h 的 POSIX/macOS 实现
//
// 关键差异（与 Windows 的 CreateProcessW 相比，必须显式处理）：
//   CreateProcessW 吃【一整条命令行】并自己按 Win32 规则拆 argv；
//   POSIX 的 posix_spawn 吃【argv 数组】。所以本层必须实现一个 Win32 兼容的命令行拆分器
//   —— 否则调用方（writeback.h）拼好的 "\"ffmpeg\" -i \"a b.flac\"" 会被当成一个文件名。
//
// 拆分规则（与 Win32 CommandLineToArgvW 对齐，只实现调用方实际用到的子集）：
//   * 空白分隔参数（引号内除外）
//   * 双引号包裹含空白的参数；"" 内部连续两个引号表示一个字面引号
//   * 反斜杠仅当紧跟双引号时才有转义意义（Win32 规则）；本项目的 wb_quoted 只做
//     "整体加引号 + 内部引号翻倍"，所以这里覆盖到它的全部输出形态
//
// 不用 /bin/sh -c：调用方已按 Win32 规则拼好引号，再过一道 shell 会把 $ ` \ 之类
// 二次解释（文件名里有 $ 就会出错）。直接 exec 更安全、也更接近 Windows 语义。
//
// ⚠️ 铁律 2：本层只负责"启动并等待"，不做任何 kill。子进程退出由它自己决定。
#include <cerrno>
#include <cstring>
#include <string>
#include <vector>

#include <fcntl.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

// find_executable 要用 module_dir_utf8 / join（path.h 的实现）。
// Windows 侧是靠 win_text.h 间接带进来的；POSIX 侧显式包含，不依赖包含顺序。
#include "platform/path.h"

extern char** environ;

namespace rta::platform {

namespace detail {

// Win32 风格命令行拆分（CommandLineToArgvW 的子集，覆盖本项目全部拼法）
inline std::vector<std::string> split_command_line(const std::string& cmd) {
    std::vector<std::string> out;
    std::string cur;
    bool in_quotes = false;
    bool has_token = false;
    size_t i = 0;
    while (i < cmd.size()) {
        const char c = cmd[i];
        if (c == '\\') {
            // 统计连续反斜杠
            size_t n = 0;
            while (i < cmd.size() && cmd[i] == '\\') { ++n; ++i; }
            if (i < cmd.size() && cmd[i] == '"') {
                // 2n 个反斜杠 -> n 个反斜杠 + 引号定界；2n+1 个 -> n 个反斜杠 + 字面引号
                cur.append(n / 2, '\\');
                if (n % 2 == 1) { cur.push_back('"'); ++i; }
                // n 为偶数时引号留给下一轮处理（切换 in_quotes）
            } else {
                cur.append(n, '\\');
            }
            has_token = true;
            continue;
        }
        if (c == '"') {
            if (in_quotes && i + 1 < cmd.size() && cmd[i + 1] == '"') {
                cur.push_back('"'); i += 2; has_token = true; continue;   // "" -> 字面引号
            }
            in_quotes = !in_quotes;
            has_token = true;                       // "" 也要算一个（空）参数
            ++i;
            continue;
        }
        if (!in_quotes && (c == ' ' || c == '\t' || c == '\n' || c == '\r')) {
            if (has_token) { out.push_back(cur); cur.clear(); has_token = false; }
            ++i;
            continue;
        }
        cur.push_back(c);
        has_token = true;
        ++i;
    }
    if (has_token) out.push_back(cur);
    return out;
}

} // namespace detail

inline ProcessResult run_hidden(const std::string& command_line_utf8, bool capture_output) {
    ProcessResult out;                              // exit_code = -1, started = false

    std::vector<std::string> parts = detail::split_command_line(command_line_utf8);
    if (parts.empty()) return out;

    // posix_spawn 需要 char* const argv[]，且不能是临时串的 data()
    std::vector<char*> argv;
    argv.reserve(parts.size() + 1);
    for (std::string& s : parts) argv.push_back(s.data());
    argv.push_back(nullptr);

    int pipefd[2] = {-1, -1};
    if (capture_output && ::pipe(pipefd) != 0) return out;

    posix_spawn_file_actions_t actions;
    ::posix_spawn_file_actions_init(&actions);
    if (capture_output) {
        // 子进程 stdout+stderr 都接到管道写端（= Windows 侧 hStdOutput/hStdError 同一个 wr）
        ::posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
        ::posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDERR_FILENO);
        ::posix_spawn_file_actions_addclose(&actions, pipefd[0]);
        ::posix_spawn_file_actions_addclose(&actions, pipefd[1]);
    }
    // 不弹窗/不抢终端：没有窗口概念，但要保证子进程不读我们的 stdin
    ::posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);

    pid_t pid = 0;
    const int rc = ::posix_spawn(&pid, parts[0].c_str(), &actions, nullptr,
                                 argv.data(), environ);
    ::posix_spawn_file_actions_destroy(&actions);

    if (rc != 0) {
        if (capture_output) { ::close(pipefd[0]); ::close(pipefd[1]); }
        errno = rc;
        return out;                                 // started=false, exit_code=-1
    }
    out.started = true;

    if (capture_output) {
        ::close(pipefd[1]);                         // 父进程只读
        char buf[4096];
        ssize_t got = 0;
        while ((got = ::read(pipefd[0], buf, sizeof(buf))) > 0)
            out.output.append(buf, (size_t)got);
        ::close(pipefd[0]);
    }

    int status = 0;
    while (::waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) break;                  // 被信号打断就重试，其他错误放弃
    }
    if (WIFEXITED(status)) out.exit_code = WEXITSTATUS(status);
    else if (WIFSIGNALED(status)) out.exit_code = 128 + WTERMSIG(status);   // shell 惯例
    else out.exit_code = -1;
    return out;
}

inline std::string find_executable(const char* name) {
    if (!name || !*name) return "";
    const std::string base(name);
    const bool has_sep = base.find('/') != std::string::npos;

    // 1) 先看 exe 同目录（分发版把 ffmpeg 放这里）—— 与 Windows 侧顺序一致
    const std::string dir = module_dir_utf8();
    if (!dir.empty()) {
        const std::string local = join(dir, base);
        struct stat st{};
        if (::stat(local.c_str(), &st) == 0 && S_ISREG(st.st_mode) &&
            ::access(local.c_str(), X_OK) == 0)
            return local;
    }
    if (has_sep) return "";

    // 2) 再退回 PATH
    const char* path_env = ::getenv("PATH");
    if (!path_env) return "";
    std::string paths(path_env);
    size_t start = 0;
    while (start <= paths.size()) {
        const size_t colon = paths.find(':', start);
        const std::string one = (colon == std::string::npos)
                                    ? paths.substr(start)
                                    : paths.substr(start, colon - start);
        if (!one.empty()) {
            const std::string cand = join(one, base);
            struct stat st{};
            if (::stat(cand.c_str(), &st) == 0 && S_ISREG(st.st_mode) &&
                ::access(cand.c_str(), X_OK) == 0)
                return cand;
        }
        if (colon == std::string::npos) break;
        start = colon + 1;
    }
    return "";
}

} // namespace rta::platform
