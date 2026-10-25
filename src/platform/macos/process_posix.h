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

// ---------------- 管道子进程（流式解码用，PLATFORM.md §13.12）----------------
// 为什么要单独一个 API：run_hidden 的语义是「跑完 → 收全部输出 → 返回退出码」，
// 而流式解码要的是「一边跑一边读 stdout」。一首 5 分钟 24/96 的歌解出来是
// 数百 MB，先收完再解析等于把内存当磁盘用，起播延迟一点没改善 —— 那就白移植了。
//
// 与 Win32 逐条对齐（原实现见 git HEAD:src/audio/audio_loader.h 的 read_via_ffmpeg_stream）：
//   CreatePipe(&rd,&wr)          -> ::pipe()
//   si.hStdOutput = wr / hStdError-> posix_spawn_file_actions_adddup2()
//   PeekNamedPipe 轮询可用字节    -> fcntl(O_NONBLOCK) + ::poll()（由调用方驱动）
//   WaitForSingleObject + GetExit-> ::waitpid() + WIFEXITED/WEXITSTATUS
//   被信号杀死                    -> 128 + WTERMSIG（沿用 run_hidden 的 shell 惯例）
//
// ⚠️ 铁律 2：本类只负责"启动/读/等待"，不做任何 kill。
struct PipeProcess {
    pid_t pid   = -1;
    int   out_fd = -1;      // 子进程 stdout 的读端（父进程持有）
    int   err_fd = -1;      // 子进程 stderr 的读端（父进程持有）
    bool  started = false;
    // 被「非阻塞探测退出」路径回收时，原始 waitpid status 落在这里（调用方判退出码用）。
    // -1 = 还没被探测到退出。这样 read_wav_stream_pipe 可以先知道进程已退出、继续排空管道，
    // 而调用方仍然拿得到真实退出码 —— Windows 侧是 WaitForSingleObject + GetExitCodeProcess
    // 两步完成的同一件事。
    int   exit_status_ = -1;

    // 启动子进程：stdout/stderr 各接一个独立管道。失败返回 false（errno 已置位）。
    bool start(const std::string& command_line_utf8) {
        std::vector<std::string> parts = detail::split_command_line(command_line_utf8);
        if (parts.empty()) return false;

        std::vector<char*> argv;
        argv.reserve(parts.size() + 1);
        for (std::string& s : parts) argv.push_back(s.data());
        argv.push_back(nullptr);

        int op[2] = {-1, -1};
        int ep[2] = {-1, -1};
        if (::pipe(op) != 0) return false;
        if (::pipe(ep) != 0) { ::close(op[0]); ::close(op[1]); return false; }

        posix_spawn_file_actions_t actions;
        ::posix_spawn_file_actions_init(&actions);
        ::posix_spawn_file_actions_adddup2(&actions, op[1], STDOUT_FILENO);
        ::posix_spawn_file_actions_adddup2(&actions, ep[1], STDERR_FILENO);
        // 不读我们的 stdin（与 run_hidden 同一处理：子进程拿 /dev/null）
        ::posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
        // 子进程里把管道原 fd 关掉：dup2 已经复制到 0/1/2，留着只是多一份写端副本。
        ::posix_spawn_file_actions_addclose(&actions, op[0]);
        ::posix_spawn_file_actions_addclose(&actions, ep[0]);
        ::posix_spawn_file_actions_addclose(&actions, op[1]);
        ::posix_spawn_file_actions_addclose(&actions, ep[1]);

        pid_t child = 0;
        const int rc = ::posix_spawn(&child, parts[0].c_str(), &actions, nullptr,
                                     argv.data(), environ);
        ::posix_spawn_file_actions_destroy(&actions);

        if (rc != 0) {
            ::close(op[0]); ::close(op[1]);
            ::close(ep[0]); ::close(ep[1]);
            errno = rc;
            return false;
        }
        // ★ 父进程必须立刻关掉写端。否则子进程退出后读端永远收不到 EOF，
        //   poll 会一直挂到超时（Win32 的 CloseHandle(outWr) 是同一件事）。
        ::close(op[1]);
        ::close(ep[1]);

        pid = child;
        out_fd = op[0];
        err_fd = ep[0];
        started = true;
        return true;
    }

    // 把 stdout 读端设为非阻塞 —— 这是 PeekNamedPipe 的等价物：
    // 有数据就立刻返回，没数据返回 EAGAIN，绝不阻塞在读上。
    bool set_stdout_nonblocking() {
        if (out_fd < 0) return false;
        const int fl = ::fcntl(out_fd, F_GETFL, 0);
        if (fl < 0) return false;
        return ::fcntl(out_fd, F_SETFL, fl | O_NONBLOCK) == 0;
    }

    // 关掉父进程持有的读端（幂等）。调用方接管 err_fd 时应先把成员置 -1。
    void close_fds() {
        if (out_fd >= 0) { ::close(out_fd); out_fd = -1; }
        if (err_fd >= 0) { ::close(err_fd); err_fd = -1; }
    }

    // 阻塞等待退出码。返回 WEXITSTATUS；被信号杀死返回 128+WTERMSIG；失败 -1。
    // 若进程已被调用方的非阻塞探测（WNOHANG）回收，直接用记下的 status —— 不能再 waitpid
    // 一次（那会等到 ECHILD 并丢失真实退出码）。
    int wait() {
        if (exit_status_ >= 0) {
            const int status = exit_status_;
            exit_status_ = -1;
            return WIFEXITED(status) ? WEXITSTATUS(status)
                                     : (WIFSIGNALED(status) ? 128 + WTERMSIG(status) : -1);
        }
        if (!started || pid <= 0) return -1;
        int status = 0;
        while (::waitpid(pid, &status, 0) < 0) {
            if (errno != EINTR) { pid = -1; return -1; }
        }
        pid = -1;
        if (WIFEXITED(status)) return WEXITSTATUS(status);
        if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
        return -1;
    }

    ~PipeProcess() { close_fds(); }
};

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
