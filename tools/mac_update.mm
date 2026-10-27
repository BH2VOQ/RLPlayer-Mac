// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// mac_update.mm — F-4 自动更新的**原生执行层**（下载 / 校验 / 挂载 / 替换 .app）
//
// ============================ 为什么必须在这一层 ============================
// 网页沙箱（WKWebView，rlplayer:// scheme）做不到这些事：
//   * 把文件写到临时目录并按固定路径落盘
//   * 调 hdiutil 挂载 dmg
//   * 用 ditto 覆盖 /Applications/RLPlayer.app
//   * 读 .app 之外的配置文件
// 所以下载、校验、安装全在这里。**判定逻辑不在这里** —— 版本比较、清单解析、
// sha256、白名单、失败分支全在 src/net/update_check.h（可离线单测）。
// 本文件只负责「按判定结果执行 IO」，因此本文件写错最多是"装不上"，
// 不会变成"判成了最新"或"装了被篡改的包"。
//
// ============================ 安全（用户硬要求）============================
//   ① token 绝不硬编码：只从 config_dir_utf8()/update.conf 读，且只在内存里用一次。
//   ② token 绝不进日志/错误信息/UI 文案：本文件所有回传给页面的字符串都过
//      RedactToken()，把 token 出现的位置抹成 "***"（连长度都不暴露）。
//   ③ 下载 URL 必须过 update_download_url_allowed()（https + 精确主机）。
//   ④ 安装前必须过 verify_downloaded_file()；失败即丢弃临时文件，**不挂载、不替换**。
//   ⑤ 重启 = **分离的 bash 脚本**（sleep → open -n），不是自我 exec，也不是自我 fork：
//      脚本由 posix_spawn(SETSID) 脱离本进程会话，本进程退出后才由它起新实例。
//      脚本创建/派发失败 ⟹ **必须回退 NSAlert**（绝不静默：既没重启又没提示是最坏结局）。
//   ⑥ 替换前先做 .app 备份；替换失败可用备份回滚。
//
// ============================ 线程模型 ============================
//   begin_check() / begin_install() 都是**立即返回**，真正工作跑在后台队列，
//   进度与结果通过 block 回调回主线程（由 mac_host.mm 转成 JS 事件）。
//   原因：hdiutil 挂载 + 7 MB 下载要数秒，阻塞主线程会让窗口"转菊花"。
// ⚠️ include 顺序有讲究（踩过一次）：
//   src/net/json.h 内部有 `static const Json nil;` 函数内静态变量，而 Objective-C 的
//   `nil` 是内建标识符（__null）⟹ 若 json.h 在 Foundation 之后被包含，`nil` 已被定义为
//   内建量，那里会报 "expected unqualified-id"。
//   所以：**纯 C++ 头必须在 ObjC 框架之前**包含。json.h 有 #pragma once，
//   后面 update_check.h 再包含它是空操作。
#include "net/json.h"

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#include <cctype>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include <fcntl.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include "mac_update.h"        // 本模块的公开接口（本文件提供实现）
#include "net/http_client.h"    // rta::net::http_get（平台层 libcurl，阻塞同步）
#include "net/update_check.h"
#include "platform/path.h"     // config_dir_utf8 / module_dir_utf8 / temp_dir_utf8 / join

// RLPLAYER_VERSION 来自 src/version.h（唯一真相源）
#include "version.h"

extern char** environ;         // posix_spawn 需要显式传环境

// ---------------------------------------------------------------------------
// NSURLSession 流式下载的 delegate
//
// ⚠️ 必须放在**全局作用域**：ObjC 的 @interface 只能出现在全局域（放进 C++ namespace
//    会报 "Objective-C declarations may only appear in global scope"）。
//
// 为什么用 NSURLSessionDownloadTask 而不是 NSURLSessionDataTask：
//   * dataTask 把字节攒进内存再交给 completionHandler ⟹ 本质上还是"一次性拿整个 body"，
//     只是换了实现（7MB dmg 不算大，但没必要）；
//   * downloadTask 由系统直接写临时文件，delegate 按块回 `totalBytesWritten`，
//     这才是真正**边下边有进度**的形态。
//
// 线程模型：所有 delegate 回调都在 NSOperationQueue（maxConcurrent=1，串行）上跑；
// 调用方在另一个线程用 100ms 切片轮询 `finished`。**主线程完全不需要跑 runloop**
// （已实测：纯 sleep 轮询时 delegate 照样回调 10 次）。
// ---------------------------------------------------------------------------
@interface RLUpdateDownloader : NSObject <NSURLSessionDownloadDelegate> {
@public
    std::string        dstPath;         // 目标文件绝对路径
    std::string        error;           // 首个错误（调用方负责再脱敏一次）
    NSInteger          httpStatus;      // HTTP 状态码（0 = 没拿到响应）
    long long          written;         // 已收字节数（delegate 报的）
    long long          expectedTotal;   // 总字节数（-1 = 服务端没给 Content-Length）
    std::atomic<bool>  finished;        // didCompleteWithError 已跑完 ⟹ 可以收了
    std::atomic<bool>  fileOk;          // 文件已完整落盘
    std::atomic<bool>  httpFailed;      // 非 2xx
    rta::update::DownloadProgressFn progressBlock;   // 节流后的进度回调（可为 nil）
    // 节流状态：只在 delegate 串行队列里读写，无需加锁
    double             lastReportAt;
    int                lastReportedPct;
}
@end

@implementation RLUpdateDownloader
- (instancetype)init {
    if ((self = [super init])) {
        httpStatus = 0;
        written = 0;
        expectedTotal = -1;
        finished = false;
        fileOk = false;
        httpFailed = false;
        progressBlock = nil;
        lastReportAt = 0;
        lastReportedPct = -1;
    }
    return self;
}

- (void)URLSession:(NSURLSession*)session
      downloadTask:(NSURLSessionDownloadTask*)task
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    (void)session; (void)task; (void)bytesWritten;
    expectedTotal = (long long)totalBytesExpectedToWrite;
    written = (long long)totalBytesWritten;
    // 节流（用户要求"每 200ms 或每 1%，别刷爆 UI"）：两个条件取 or
    const int pct = rta::update::download_percent(written, expectedTotal);
    const double now = CFAbsoluteTimeGetCurrent();
    const bool timeDue = (now - lastReportAt) >= 0.2;
    const bool pctDue = (pct > lastReportedPct);
    if (!timeDue && !pctDue) return;
    lastReportAt = now;
    lastReportedPct = pct;
    if (progressBlock) progressBlock(written, expectedTotal);
}

- (void)URLSession:(NSURLSession*)session
      downloadTask:(NSURLSessionDownloadTask*)task
didFinishDownloadingToURL:(NSURL*)location {
    (void)session;
    httpStatus = task.response ? [(NSHTTPURLResponse*)task.response statusCode] : 0;
    if (httpStatus < 200 || httpStatus >= 300) {
        // 非 2xx：body 是错误页面，**绝不能**当 dmg 落盘
        httpFailed = true;
        error = "下载失败 HTTP " + std::to_string((int)httpStatus);
        return;
    }
    // 落盘：先写 <dst>.part 再 rename（同目录 rename 是原子的）
    // ⟹ 任何时刻 dstPath 要么不存在，要么是**完整**文件，不存在"半个 dmg"。
    const std::string part = dstPath + ".part";
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* partNS = [NSString stringWithUTF8String:part.c_str()];
    [fm removeItemAtPath:partNS error:nil];
    NSError* ce = nil;
    if (![fm copyItemAtPath:location.path toPath:partNS error:&ce]) {
        error = "下载结果落到临时文件失败";
        return;
    }
    if (::rename(part.c_str(), dstPath.c_str()) != 0) {
        error = std::string("下载落盘失败：") + std::strerror(errno);
        ::unlink(part.c_str());
        return;
    }
    struct stat st {};
    if (::stat(dstPath.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) {
        error = "落盘后文件不可用";
        ::unlink(dstPath.c_str());
        return;
    }
    fileOk = true;
}

- (void)URLSession:(NSURLSession*)session
              task:(NSURLSessionTask*)task
didCompleteWithError:(NSError*)e {
    (void)session;
    if (task.response) httpStatus = [(NSHTTPURLResponse*)task.response statusCode];
    if (e && error.empty()) {
        if (e.code == NSURLErrorCancelled) {
            error = "已取消";
        } else if (e.code == NSURLErrorTimedOut) {
            error = "下载超时";
        } else {
            const char* m = e.localizedDescription.UTF8String;
            error = m ? m : "网络错误";
        }
    }
    finished = true;
}
@end

namespace rta::update {

namespace detail_native {

// 读 settings 配置中的 updbeta：默认 false
inline bool LoadUpdBeta() {
    std::string base;
    if (const char* env = std::getenv("RLPLAYER_STATE_DIR")) {
        if (*env) {
            base = env;
            while (!base.empty() && (base.back() == '\\' || base.back() == '/')) base.pop_back();
        }
    }
    if (base.empty()) base = rta::platform::config_dir_utf8();
    if (base.empty()) base = rta::platform::module_dir_utf8();
    const std::string path = rta::platform::join(base, "rlplayer-settings.conf");
    std::ifstream f(path);
    if (!f) return false;
    std::string line;
    while (std::getline(f, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        const size_t eq = line.find('=');
        if (eq == std::string::npos) continue;
        if (line.substr(0, eq) == "updbeta") {
            const std::string v = line.substr(eq + 1);
            return (v == "1" || v == "true");
        }
    }
    return false;
}

// ---------------- token 脱敏 ----------------
// 任何可能进 UI/日志的字符串都必须过这里。
// 为什么连"长度"都不暴露：长度可用于缩小暴力破解范围。
inline std::string RedactToken(const std::string& input, const std::string& token) {
    if (token.empty() || input.empty()) return input;
    std::string out = input;
    size_t pos = 0;
    while ((pos = out.find(token, pos)) != std::string::npos) {
        out.replace(pos, token.size(), "***");
        pos += 3;
    }
    return out;
}

// ---------------- 配置文件路径 ----------------
inline std::string UpdateConfPath() {
    const std::string dir = rta::platform::config_dir_utf8();
    if (dir.empty()) return "";
    return rta::platform::join(dir, "update.conf");
}

// 读配置：文件不存在 ⟹ 默认匿名（**不报错**，这是首次运行的常态）
inline Config LoadConfig() {
    const std::string path = UpdateConfPath();
    if (path.empty()) return parse_update_config("");
    std::ifstream f(path, std::ios::binary);
    if (!f) return parse_update_config("");
    std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    Config c = parse_update_config(text);
    c.fileExists = true;
    return c;
}

// 首次运行写出 0600 模板（"缺省即安全"：token 行为空 ⟹ 匿名路径）。
// ⚠️ 必须**创建时就 0600**：先 open(O_CREAT,0600) 再写，绝不 0644 落地后 chmod。
inline bool EnsureConfTemplate(const std::string& path, std::string& err) {
    if (path.empty()) { err = "配置目录不可用"; return false; }
    struct stat st {};
    if (::stat(path.c_str(), &st) == 0) return true;      // 已存在，不动它
    const int fd = ::open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) {
        if (errno == EEXIST) return true;                 // 竞态：别人刚建好
        err = "无法创建 update.conf";
        return false;
    }
    const std::string tpl = default_update_conf_template();
    ssize_t written = ::write(fd, tpl.data(), tpl.size());
    ::close(fd);
    if (written < 0 || (size_t)written != tpl.size()) { err = "写入 update.conf 失败"; return false; }
    return true;
}

// ---------------- HTTP ----------------
struct HttpOutcome {
    bool ok = false;
    int status = 0;
    std::string error;
    std::string body;
};

// 统一走 net/http_client.h（平台层 libcurl，阻塞、同步）。
// token 只在这里作为请求头出现一次，绝不写日志。
inline HttpOutcome Fetch(const std::string& url, const std::string& token, int timeoutMs) {
    HttpOutcome out;
    std::vector<std::string> headers;
    if (!token.empty()) headers.push_back("Authorization: token " + token);
    const auto r = rta::net::http_get(url, headers, timeoutMs);
    out.ok = r.ok;
    out.status = r.status;
    out.error = RedactToken(r.error, token);              // ← ① 脱敏
    out.body.assign(r.body.begin(), r.body.end());
    return out;
}

// ---------------- 流式下载（NSURLSession）----------------
// 与 Fetch 的区别（这正是本次要解决的问题）：
//   Fetch  → libcurl 阻塞，整个 body 一次性返回 ⟹ 只有"开始/结束"两个时间点
//   本函数 → NSURLSessionDownloadTask + delegate，按块回 totalBytesWritten ⟹ 真有进度
// 语义保证：返回 false 时 dstPath **一定不存在**（要么没建，要么已 unlink）。
inline DownloadResult DownloadToFile(const std::string& url,
                                     const std::string& token,
                                     const std::string& dstPath,
                                     int timeoutSeconds,
                                     DownloadProgressFn onProgress,
                                     const CancelToken& cancel) {
    DownloadResult out;
    if (dstPath.empty()) { out.error = "目标路径为空"; return out; }
    ::unlink(dstPath.c_str());
    ::unlink((dstPath + ".part").c_str());

    @autoreleasepool {
        NSURL* nsurl = [NSURL URLWithString:[NSString stringWithUTF8String:url.c_str()]];
        if (!nsurl || !nsurl.scheme) { out.error = "下载地址不可用"; return out; }

        RLUpdateDownloader* del = [[RLUpdateDownloader alloc] init];
        del->dstPath = dstPath;
        del->progressBlock = onProgress;

        NSURLSessionConfiguration* cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        // 连接/单次请求超时；整体资源超时按调用方给的秒数（现有 120s 语义保持不变）
        cfg.timeoutIntervalForRequest  = (timeoutSeconds > 0) ? timeoutSeconds : 120;
        cfg.timeoutIntervalForResource = (timeoutSeconds > 0) ? timeoutSeconds : 120;
        cfg.HTTPShouldSetCookies = NO;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

        NSOperationQueue* q = [[NSOperationQueue alloc] init];
        q.maxConcurrentOperationCount = 1;      // delegate 串行 ⟹ 节流状态无需加锁

        NSURLSession* session = [NSURLSession sessionWithConfiguration:cfg
                                                             delegate:del
                                                        delegateQueue:q];

        NSMutableURLRequest* rq = [NSMutableURLRequest requestWithURL:nsurl];
        rq.timeoutInterval = (timeoutSeconds > 0) ? timeoutSeconds : 120;
        rq.HTTPMethod = @"GET";
        // token 只在这里作为请求头出现一次，绝不写日志
        if (!token.empty()) {
            [rq setValue:[NSString stringWithFormat:@"token %s", token.c_str()]
                forHTTPHeaderField:@"Authorization"];
        }
        NSURLSessionDownloadTask* task = [session downloadTaskWithRequest:rq];
        [task resume];

        // 100ms 切片轮询 —— 既能及时响应取消，又不依赖调用线程有 runloop（已实测）
        bool cancelledHere = false;
        while (!del->finished.load()) {
            if (cancel.cancelled()) {
                cancelledHere = true;
                [task cancel];
                // 给取消回调一点时间落定，避免和 didComplete 抢
                for (int i = 0; i < 30 && !del->finished.load(); ++i) {
                    ::usleep(50 * 1000);
                }
                break;
            }
            ::usleep(100 * 1000);
        }
        [session finishTasksAndInvalidate];

        out.status = (int)del->httpStatus;
        out.bytes  = del->written;
        out.cancelled = cancelledHere;
        if (cancelledHere) {
            out.error = "已取消";
        } else if (del->httpFailed.load()) {
            out.error = del->error;                       // 已是固定文案，无 token
        } else if (!del->fileOk.load()) {
            out.error = del->error.empty() ? "下载未完成" : del->error;
        } else {
            out.ok = true;
        }
        out.error = RedactToken(out.error, token);         // ← ① 脱敏（兜底）
    }

    // 失败必清（连 .part 一起）：绝不留半个文件给后续校验/挂载
    if (!out.ok) {
        ::unlink(dstPath.c_str());
        ::unlink((dstPath + ".part").c_str());
    }
    return out;
}

// ---------------- 路径 ----------------
inline std::string ExecutableBundlePath() {
    // .app 的绝对路径：可执行文件在 <bundle>/Contents/MacOS/<exe> ⟹ 上溯 3 级
    std::string exe = rta::platform::module_dir_utf8();   // .../Contents/MacOS
    if (exe.empty()) return "";
    auto up = [](std::string p) {
        const size_t s = p.find_last_of('/');
        return (s == std::string::npos) ? std::string() : p.substr(0, s);
    };
    const std::string contents = exe;                     // Contents/MacOS
    const std::string contentsDir = up(contents);         // Contents
    const std::string bundle = up(contentsDir);           // RLPlayer.app
    if (bundle.empty() || bundle == "/") return "";
    if (bundle.size() < 4 || bundle.compare(bundle.size() - 4, 4, ".app") != 0) return "";
    return bundle;
}

// 目标安装位置：优先"当前 .app 所在位置"（用户可能把 app 放在 ~/Applications）。
// 只有当它在 /Applications 下才需要提权；本机 /Applications 属 admin:2775，无需提权。
inline std::string InstallTargetPath() {
    const std::string cur = ExecutableBundlePath();
    if (!cur.empty()) return cur;
    return "/Applications/RLPlayer.app";
}

// 运行外部命令，收集 stdout（hdiutil 需要解析真实挂载点）
inline int RunCapture(const std::string& cmd, std::string& out) {
    out.clear();
    FILE* p = ::popen(cmd.c_str(), "r");
    if (!p) return -1;
    char buf[4096];
    while (std::fgets(buf, sizeof(buf), p)) out += buf;
    const int rc = ::pclose(p);
    return (rc == -1) ? -1 : WEXITSTATUS(rc);
}

inline std::string ShellQuote(const std::string& s) {
    // 单引号包裹 + 内部单引号转义（路径可能含空格/中文）
    std::string q = "'";
    for (char c : s) {
        if (c == '\'') q += "'\\''";
        else q += c;
    }
    q += "'";
    return q;
}

// 是否为已存在的目录（.app 必须是目录；用 stat 而不是 NSFileManager 以便与 C++ 侧一致）
inline bool IsDirectory(const std::string& p) {
    struct stat st {};
    return !p.empty() && ::stat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

// ---------------- 更新诊断日志（2026-10-26）----------------
// 为什么必须落盘：GUI 双击启动的 .app **没有终端**，stderr 无人接收 ⟹ 写了也看不到。
// 用户报「检查失败：网络不可用 / 下载失败」时，唯一能拿到的现场就是这个文件。
// 位置与其它状态文件一致（config_dir），单文件超 256KB 轮转一次，最多留 .1 一份。
// 只写状态码/URL/错误串，**绝不写 token**（调用方已在拼串前过 redact_token）。
inline void AppendUpdateLog(const std::string& line) {
    const std::string dir = rta::platform::config_dir_utf8();
    if (dir.empty() || line.empty()) return;
    const std::string path = rta::platform::join(dir, "rlplayer-update.log");

    struct stat st {};
    if (::stat(path.c_str(), &st) == 0 && st.st_size > 256 * 1024) {
        const std::string old = path + ".1";
        ::unlink(old.c_str());
        ::rename(path.c_str(), old.c_str());          // 轮转失败也无所谓，继续写新内容
    }

    char ts[32] = {0};
    const std::time_t now = ::time(nullptr);
    struct tm tmv {};
    if (::localtime_r(&now, &tmv)) std::strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", &tmv);

    std::ofstream f(path, std::ios::binary | std::ios::app);
    if (!f) return;
    f << ts << ' ' << line;
    if (line.empty() || line.back() != '\n') f << '\n';
}

// ---------------- 仅测试用的 loopback 放行 ----------------
// 默认关闭；打开后只放行**本机** http 地址（127.0.0.1 / localhost），外部主机仍被白名单拒。
inline std::atomic<bool>& LoopbackTestFlag() {
    static std::atomic<bool> f{false};
    return f;
}

inline bool IsLoopbackUrl(const std::string& url) {
    auto starts = [&](const char* pre) {
        const size_t n = std::strlen(pre);
        if (url.size() < n) return false;
        for (size_t i = 0; i < n; ++i) {
            if (std::tolower((unsigned char)url[i]) != (unsigned char)std::tolower((unsigned char)pre[i])) return false;
        }
        return true;
    };
    std::string rest;
    if (starts("http://127.0.0.1:"))        rest = url.substr(std::strlen("http://127.0.0.1:"));
    else if (starts("http://localhost:"))   rest = url.substr(std::strlen("http://localhost:"));
    else return false;
    const size_t slash = rest.find('/');
    if (slash == std::string::npos || slash == 0) return false;      // 必须有端口 + 路径
    for (size_t i = 0; i < slash; ++i) {
        if (!std::isdigit((unsigned char)rest[i])) return false;     // 端口必须是纯数字
    }
    const int port = std::atoi(rest.substr(0, slash).c_str());
    return port > 0 && port <= 65535;
}

} // namespace detail_native

// ---------------------------------------------------------------------------
// 公开接口：路径 / 模板 / 脱敏（供 mac_host.mm 与测试使用）
// ---------------------------------------------------------------------------
std::string update_conf_path() { return detail_native::UpdateConfPath(); }

bool ensure_conf_template(std::string& err) {
    return detail_native::EnsureConfTemplate(detail_native::UpdateConfPath(), err);
}

std::string redact_token(const std::string& input, const std::string& token) {
    return detail_native::RedactToken(input, token);
}

// ---------------------------------------------------------------------------
// 检查更新（异步）
// ---------------------------------------------------------------------------
void begin_check(ProgressFn progress, DoneFn done) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NativeProgress p; p.stage = "checking"; p.detail = "正在检查更新…"; p.percent = -1;
        if (progress) progress(p);

        const Config cfg = detail_native::LoadConfig();
        const bool useToken = cfg.hasToken;

        CheckResult result;
        if (!cfg.manifestUrlValid) {
            // 配置文件里写了非白名单地址 ⟹ 拒绝（不静默回退，免得用户以为在查公开清单）
            result.decision = Decision::FailedBadUrl;
            result.error = cfg.warning.empty() ? "update.conf 的 manifest_url 不在白名单" : cfg.warning;
            if (done) done(result);
            return;
        }

        std::string manifestUrl = cfg.manifestUrl;
        const std::string token = useToken ? cfg.token : std::string();

        // ---- 私有路径：先问 releases API，找最新非草稿 release 的 latest.json 附件 ----
        if (useToken) {
            const auto rel = detail_native::Fetch(kReleasesApiUrl, token, 15000);
            if (!rel.ok || rel.status < 200 || rel.status >= 300) {
                result.decision = (rel.status == 401 || rel.status == 403) ? Decision::FailedAuth
                                                                          : (rel.status == 0 ? Decision::FailedNetwork
                                                                                             : Decision::FailedHttp);
                result.status = rel.status;
                result.error = (result.decision == Decision::FailedAuth)
                    ? "鉴权失败（检查 update.conf 里的只读 token）"
                    : (result.decision == Decision::FailedNetwork
                           ? "网络不可用（无法连接更新服务器）"
                           : "更新服务器返回 HTTP " + std::to_string(rel.status));
                if (done) done(result);
                return;
            }
            // ⚠️ 2026-10-26 实测（gitea 1.27.3 / 私有仓库）：release 附件下载对 token
            // 全线 403，所以 latest.json **不走附件**，改走仓库 raw 端点（那条对 token 正常）。
            // 具体分支：
            //   ① API 里能找到 latest.json 附件 → 用它的地址（公开仓库/未来 gitea 修好后可用）
            //   ② 找不到 → 退回仓库文件 raw 路径（本机当前唯一实测可用的方式）
            const auto lk = find_manifest_asset_in_releases(rel.body);
            if (lk.found) {
                manifestUrl = lk.url;
            } else {
                // 2026-10-26 迁到 GitHub（公开仓库 BH2VOQ/RLPlayer-Mac）后的退路：
                //   清单直接是仓库根目录的 latest.json 文件，用 raw.githubusercontent.com 读，
                //   **匿名即可**（实测 200）。
                //   旧实现拼的是 kPrivateRawPrefix（api.github.com/.../contents/，形如 Gitea 的
                //   raw 端点）—— 那个常量已删除，因为 api.github.com 不在下载白名单里。
                manifestUrl = std::string("https://raw.githubusercontent.com/") +
                              kRepoOwner + "/" + kRepoName + "/" + kRepoBranch + "/" +
                              kManifestAssetName;
                if (!update_download_url_allowed(manifestUrl)) {
                    result.decision = Decision::FailedBadUrl;
                    result.error = "清单地址不在白名单";
                    if (done) done(result);
                    return;
                }
            }
        }

        // ---- 取清单（公开路径：匿名；私有路径：仍要带 token，因为内容在私有仓库里）----
        const auto man = detail_native::Fetch(manifestUrl, token, 15000);
        const bool allowBeta = detail_native::LoadUpdBeta();
        result = evaluate_update_check(RLPLAYER_VERSION, man.ok, man.status, man.body, allowBeta);
        // 2026-10-26（用户实测反馈「检查失败：网络不可用」，但界面上看不到到底为什么）：
        //   原来的 transport 错误串完全没有出口，用户只能看到一句笼统的"网络不可用"，
        //   连是 DNS、TLS、超时还是被拦都不知道 —— 排查时唯一能做的就是再点一次。
        //
        // ⚠️ 2026-10-26 二次修正：第一版只写 stderr，**GUI 双击启动时 stderr 没人接**
        //   （既没有终端，也没有重定向）⟹ 等于没写。现在同时落盘到
        //   <config_dir>/rlplayer-update.log，用户发诊断包/截图时能直接看到原因。
        //   两件事：
        //     ① 失败时写一行可诊断信息（含底层错误与最终 URL）；
        //     ② 把底层原因拼进给用户的 error 文案（过 redact_token，绝不含凭据）。
        if (!result.available() && !result.up_to_date()) {
            const std::string why = redact_token(man.error, token);
            char line[1024];
            std::snprintf(line, sizeof line,
                          "UPDATE_CHECK_FAIL status=%d decision=%s url=%s err=%s\n",
                          man.status, result.code(), manifestUrl.c_str(), why.c_str());
            fprintf(stderr, "RLPlayer: 更新检查失败 %s", line);
            detail_native::AppendUpdateLog(line);
            if (result.decision == Decision::FailedNetwork && !man.error.empty()) {
                result.error += "：" + why;
            }
        } else if (result.available()) {
            char line[512];
            std::snprintf(line, sizeof line, "UPDATE_CHECK_OK remote=%s local=%s\n",
                          result.remoteVersion.c_str(), RLPLAYER_VERSION);
            detail_native::AppendUpdateLog(line);
        }
        if (done) done(result);
    });
}

// ---------------------------------------------------------------------------
// 可单独调用的安装步骤（测试用真 dmg 跑，见 tests/test_mac_update.mm）
// ---------------------------------------------------------------------------
bool mount_image(const std::string& dmgPath, const std::string& mountPoint,
                 std::string& outAppPath, std::string& err) {
    outAppPath.clear();
    err.clear();
    if (dmgPath.empty() || mountPoint.empty()) { err = "参数为空"; return false; }
    ::mkdir(mountPoint.c_str(), 0700);
    std::string out;
    const std::string cmd = "/usr/bin/hdiutil attach -nobrowse -noverify -noautoopen -mountpoint " +
                            detail_native::ShellQuote(mountPoint) + " " +
                            detail_native::ShellQuote(dmgPath) + " 2>&1";
    if (detail_native::RunCapture(cmd, out) != 0) {
        err = "hdiutil attach 失败：" + out;
        return false;
    }
    // 取镜像内第一个 *.app（不假设名字：产物可能叫 RLPlayer.app）
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* mnt = [NSString stringWithUTF8String:mountPoint.c_str()];
    NSArray<NSString*>* items = [fm contentsOfDirectoryAtPath:mnt error:nil];
    for (NSString* it in items) {
        if ([it hasSuffix:@".app"]) {
            outAppPath = [[mnt stringByAppendingPathComponent:it] UTF8String];
            break;
        }
    }
    if (outAppPath.empty()) {
        std::string um;
        unmount_image(mountPoint, um);
        err = "镜像内没有 .app";
        return false;
    }
    return true;
}

bool unmount_image(const std::string& mountPoint, std::string& err) {
    std::string out;
    if (detail_native::RunCapture("/usr/bin/hdiutil detach " + detail_native::ShellQuote(mountPoint) + " 2>&1",
                                  out) != 0) {
        err = "hdiutil detach 失败：" + out;
        // 挂载点目录留给系统清理；不 force（铁律 2 的精神：不硬来）
        return false;
    }
    ::rmdir(mountPoint.c_str());
    return true;
}

bool install_app_bundle(const std::string& srcApp, const std::string& targetApp,
                        std::string& outBackup, std::string& err) {
    outBackup.clear();
    err.clear();
    if (srcApp.empty() || targetApp.empty()) { err = "参数为空"; return false; }

    std::string out;
    NSFileManager* fm = [NSFileManager defaultManager];
    const bool existed = [fm fileExistsAtPath:[NSString stringWithUTF8String:targetApp.c_str()]];

    // 1) 备份（仅在目标已存在时）
    if (existed) {
        const std::string bk = targetApp + ".old-" + std::to_string((long long)::time(nullptr));
        if (detail_native::RunCapture("/usr/bin/ditto " + detail_native::ShellQuote(targetApp) + " " +
                                          detail_native::ShellQuote(bk) + " 2>&1", out) != 0) {
            err = "备份现有 .app 失败，已中止（不覆盖）";
            return false;
        }
        outBackup = bk;
    }

    // 2) 覆盖安装（ditto 保留 xattr/签名结构，比 cp -R 稳）
    if (detail_native::RunCapture("/usr/bin/ditto " + detail_native::ShellQuote(srcApp) + " " +
                                      detail_native::ShellQuote(targetApp) + " 2>&1", out) != 0) {
        err = "复制到目标失败：" + out;
        // 3) 回滚
        if (!outBackup.empty()) {
            if (detail_native::RunCapture("/usr/bin/ditto " + detail_native::ShellQuote(outBackup) + " " +
                                              detail_native::ShellQuote(targetApp) + " 2>&1", out) == 0) {
                err += "（已回滚到备份）";
            } else {
                err += "（回滚也失败，备份保留在 " + outBackup + "）";
            }
        }
        return false;
    }
    return true;
}

bool sha256_of_file(const std::string& path, std::string& outHex, std::string& err) {
    return sha256_file(path, outHex, err);
}

// ---------------------------------------------------------------------------
// 流式下载（公开接口，见 mac_update.h 的语义说明）
// 放在这里而不是 detail_native：测试要直接撞它（真起本机 HTTP 服务）。
// ---------------------------------------------------------------------------
DownloadResult download_to_file(const std::string& url,
                                const std::string& token,
                                const std::string& dstPath,
                                int timeoutSeconds,
                                DownloadProgressFn onProgress,
                                CancelToken cancel) {
    // 白名单是 begin_install 的职责，但这里也挡一次：任何调用方都不该凭空白名单去连外部主机
    bool allowed = update_download_url_allowed(url);
    if (!allowed && detail_native::LoopbackTestFlag().load() && detail_native::IsLoopbackUrl(url)) {
        allowed = true;                       // ← 仅测试开关打开时，且仅本机地址
    }
    if (!allowed) {
        DownloadResult r;
        r.error = "下载地址不在白名单，已拒绝";
        return r;
    }
    return detail_native::DownloadToFile(url, token, dstPath, timeoutSeconds, onProgress, cancel);
}

void set_test_allow_loopback_download(bool enabled) {
    detail_native::LoopbackTestFlag().store(enabled);
}

// ---------------------------------------------------------------------------
// 自动重启：脚本正文 + 落盘 + 分离执行
// ---------------------------------------------------------------------------
std::string auto_restart_script_body(const std::string& appPath, const AutoRestartOptions& opts) {
    const int ms = (opts.sleepMs < 0) ? 0 : opts.sleepMs;
    std::string s;
    s += "#!/bin/bash\n";
    s += "# RLPlayer 自动更新重启脚本（由 update 安装流程生成，执行完自删）\n";
    s += "# 为什么要 sleep：ditto 刚替换完 .app，当前进程还在用它 → 先等本进程退出，\n";
    s += "# 避免文件占用/竞态（用户要求约 1.5 秒）。\n";
    s += "sleep ";
    s += std::to_string(ms / 1000);
    if (ms % 1000 != 0) {
        // 保留毫秒精度（测试用 0/300ms 这类短值时要真的短）
        s += ".";
        char buf[8];
        std::snprintf(buf, sizeof buf, "%03d", ms % 1000);
        s += buf;
    }
    s += "\n";
    s += "# open -n = 新开一个实例。直接 open 在 .app 已被替换、旧进程仍在时会激活旧实例。\n";
    s += "/usr/bin/open -n ";
    s += detail_native::ShellQuote(appPath);
    s += "\n";
    s += "# 自删：不留临时脚本垃圾（$0 是本脚本路径）\n";
    s += "rm -f \"$0\" 2>/dev/null\n";
    return s;
}

bool schedule_auto_restart(const std::string& appPath, std::string& outScriptPath,
                           std::string& outErr, const AutoRestartOptions& opts) {
    outScriptPath.clear();
    outErr.clear();

    if (appPath.empty()) { outErr = "新版本 .app 路径为空"; return false; }
    if (!detail_native::IsDirectory(appPath)) {
        outErr = "新版本 .app 不存在或不是目录：" + appPath;
        return false;
    }

    const std::string tmp = rta::platform::temp_dir_utf8();
    if (tmp.empty()) { outErr = "没有可用的临时目录"; return false; }
    char nm[64];
    std::snprintf(nm, sizeof nm, "rlplayer-restart-%d.sh", (int)::getpid());
    const std::string script = rta::platform::join(tmp, nm);

    const std::string body = auto_restart_script_body(appPath, opts);
    // 0600 创建 + 直写：用 open(O_CREAT|O_TRUNC) 而不是 popen/echo，避免 shell 二次解释
    const int fd = ::open(script.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0700);
    if (fd < 0) { outErr = std::string("无法创建重启脚本：") + std::strerror(errno); return false; }
    const ssize_t n = ::write(fd, body.data(), body.size());
    ::close(fd);
    if (n < 0 || (size_t)n != body.size()) {
        ::unlink(script.c_str());
        outErr = "写入重启脚本失败";
        return false;
    }
    ::chmod(script.c_str(), 0700);          // 有 umask 时补一次，确保可执行

    outScriptPath = script;
    if (!opts.spawn) return true;           // 只写不跑（测试/诊断）

    // ---------------- 分离执行 ----------------
    // 用 posix_spawn + POSIX_SPAWN_SETSID 而不是 NSTask：
    //   * SETSID 让脚本进入**新会话**，本进程退出/收到信号都带不走它（这才是"分离"）
    //   * NSTask 属于 Foundation 进程管理，跟着 NSApp 生命周期，退出时可能被带走
    // 已实测：POSIX_SPAWN_SETSID(1024) 在本机可用，spawn 返回 0，子进程真能跑起来。
    const std::string logPath = opts.logPath.empty()
        ? rta::platform::join(tmp, "rlplayer-restart.log")
        : opts.logPath;

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    // stdout/stderr 重定向到日志（诊断用）；脚本自己不打印关键内容，日志为空也正常
    posix_spawn_file_actions_addopen(&fa, 1, logPath.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0600);
    posix_spawn_file_actions_addopen(&fa, 2, logPath.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0600);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    short flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT;
#ifdef POSIX_SPAWN_SETSIGDEF
    flags |= POSIX_SPAWN_SETSIGDEF;
#endif
    posix_spawnattr_setflags(&attr, flags);
#ifdef POSIX_SPAWN_SETSIGDEF
    sigset_t def;
    sigemptyset(&def);
    sigaddset(&def, SIGTERM);
    sigaddset(&def, SIGINT);
    posix_spawnattr_setsigdefault(&attr, &def);
#endif

    // 参数：waitPid > 0 时先等那个 pid（生产=当前进程；测试可传 0 不等）
    std::string cmd;
    if (opts.waitPid > 0) {
        // 等旧进程真的退出再起新的。`while kill -0` 比固定 sleep 更稳（进程可能退得慢）。
        cmd = "while /bin/kill -0 " + std::to_string((long long)opts.waitPid) +
              " 2>/dev/null; do /bin/sleep 0.05; done; ";
        cmd += "/bin/bash ";
    } else {
        cmd = "/bin/bash ";
    }
    cmd += detail_native::ShellQuote(script);

    const char* argv[] = {"/bin/bash", "-c", cmd.c_str(), nullptr};
    pid_t pid = 0;
    const int rc = ::posix_spawn(&pid, "/bin/bash", &fa, &attr,
                                 const_cast<char* const*>(argv), environ);
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&fa);

    if (rc != 0) {
        ::unlink(script.c_str());
        outScriptPath.clear();
        outErr = std::string("无法派发重启脚本：") + std::strerror(rc);
        return false;
    }

    fprintf(stderr, "RLPlayer: 已派发自动重启（pid=%d, script=%s, log=%s）\n",
            (int)pid, script.c_str(), logPath.c_str());
    return true;
}

bool install_from_local_dmg(const std::string& dmgPath,
                            const std::string& expectedSha256, long long expectedSize,
                            const std::string& mountPoint,
                            const std::string& targetApp,
                            std::string& outBackup, std::string& err) {
    outBackup.clear();
    err.clear();          // 成功时不留上一次的失败文案（调用方可能在同一个 err 上复用）

    // ① 校验必须是第一道闸门。过了才允许挂载/替换 —— 顺序即安全边界。
    const VerifyResult vr = verify_downloaded_file(dmgPath, expectedSha256, expectedSize);
    if (!vr.ok) {
        err = vr.error;                  // 调用方负责丢弃 dmg 文件
        return false;                    // ← 绝不进入 ②③
    }

    // ② 挂载
    std::string srcApp;
    if (!mount_image(dmgPath, mountPoint, srcApp, err)) return false;

    // ③ 安装（内部备份 + 失败回滚）
    std::string backup;
    const bool ok = install_app_bundle(srcApp, targetApp, backup, err);
    outBackup = backup;

    // ④ 无论成败都卸载（否则会残留挂载点）
    std::string uerr;
    if (!unmount_image(mountPoint, uerr)) {
        if (ok) { err = uerr; return false; }        // 装成功但没卸干净 → 报失败让人看到
    }
    return ok;
}

// ---------------------------------------------------------------------------
// 安装流水线（同步、可注入目标路径）—— begin_install 的全部实质内容
//
// 进度区间（2026-10-26 用户要求，唯一真相源在 mac_update.h 的 InstallProgressRange）：
//   下载 0→40（按真实字节数插值，不是只报 0 和 40）
//   校验 40→60
//   安装 60→95
//   完成 100
//
// ⚠️ 顺序即安全边界：verify 必须在 mount 之前。改成流式下载**不改变**这一顺序。
// ---------------------------------------------------------------------------
bool run_install_pipeline(const CheckResult& plan, ProgressFn progress, CancelToken cancel,
                          const InstallPipelineOptions& opts,
                          std::string& outErr, std::string& outBackup) {
    outErr.clear();
    outBackup.clear();

    auto report = [&](const char* stage, const std::string& d, int pct) {
        NativeProgress p; p.stage = stage; p.detail = d; p.percent = pct;
        if (progress) progress(p);
    };

    const Config cfg = detail_native::LoadConfig();
    const std::string token = cfg.hasToken ? cfg.token : std::string();

    const std::string target = opts.targetApp.empty() ? detail_native::InstallTargetPath()
                                                      : opts.targetApp;
    const std::string dmgPath = opts.dmgPath.empty()
        ? rta::platform::join(rta::platform::temp_dir_utf8(), "rlplayer-update.dmg")
        : opts.dmgPath;
    const std::string mntPath = opts.mountPoint.empty()
        ? rta::platform::join(rta::platform::temp_dir_utf8(), "rlplayer-update-mnt")
        : opts.mountPoint;

    // ---------- 1. 下载（NSURLSession 流式，真进度）----------
    report("downloading", "正在下载 " + plan.remoteVersion + " …", 0);
    ::unlink(dmgPath.c_str());
    ::unlink((dmgPath + ".part").c_str());

    // 进度：单调不减 + 变化才上报。用头文件里的 DownloadPctTracker（生产与测试同一份）
    // 而不是在这里内联一套 —— 否则测试测的是测试自己写的逻辑（铁律 3）。
    auto tracker = std::make_shared<DownloadPctTracker>();
    tracker->expectedSize = plan.size;          // 清单给了 size 就以它为准
    DownloadProgressFn onProgress = ^(long long written, long long total) {
        int pct = 0;
        if (!tracker->update(written, total, pct)) return;     // 没变化 ⟹ 不刷 UI
        const long long denom = (plan.size > 0) ? plan.size : total;
        std::string d = "正在下载 " + plan.remoteVersion + "（" +
                        std::to_string((long long)written / 1024) + " KB";
        if (denom > 0) d += " / " + std::to_string((long long)denom / 1024) + " KB";
        d += "）";
        NativeProgress p; p.stage = "downloading"; p.detail = d; p.percent = pct;
        if (progress) progress(p);
    };

    const DownloadResult dl = download_to_file(plan.downloadUrl, token, dmgPath,
                                               opts.downloadTimeoutSeconds, onProgress, cancel);
    if (dl.cancelled) {
        ::unlink(dmgPath.c_str());
        outErr = "更新已取消（未做任何改动）";
        return false;
    }
    if (!dl.ok) {
        // 失败可重试（不改状态、不写"已是最新"）
        std::string msg = (dl.status == 401 || dl.status == 403)
                              ? "下载失败：鉴权被拒（检查 update.conf）"
                              : "下载失败（可重试）";
        if (dl.status > 0) msg += " HTTP " + std::to_string(dl.status);
        if (!dl.error.empty()) msg += "：" + dl.error;
        // 2026-10-26：下载失败也必须留痕。用户截图只给了「下载地址不在白名单」，
        // 而这句话只在 download_to_file 的白名单闸门里出现 —— 不把**当时的 URL**
        // 记下来，就无法判断到底是哪一版二进制、哪一份清单给出的地址。
        {
            char line[1200];
            std::snprintf(line, sizeof line,
                          "UPDATE_DOWNLOAD_FAIL status=%d bytes=%lld url=[%s] err=%s\n",
                          dl.status, (long long)dl.bytes, plan.downloadUrl.c_str(),
                          redact_token(dl.error, token).c_str());
            detail_native::AppendUpdateLog(line);
        }
        ::unlink(dmgPath.c_str());
        outErr = redact_token(msg, token);
        return false;
    }
    report("downloading", "下载完成（" + std::to_string(dl.bytes) + " 字节）",
           InstallProgressRange::kDownloadEnd);

    // ---------- 2. 校验（篡改/截断必失败 ⟹ 丢弃，绝不挂载）----------
    // ⚠️ 位置是硬要求：**必须在挂载之前**。这条闸门（sha256 + size）是安全边界。
    report("verifying", "正在校验 sha256 …", InstallProgressRange::kDownloadEnd);
    const VerifyResult vr = verify_downloaded_file(dmgPath, plan.sha256, plan.size);
    if (!vr.ok) {
        if (!opts.keepDmgOnFailure) ::unlink(dmgPath.c_str());   // ← 关键：失败即丢弃
        outErr = "校验失败，已丢弃：" + vr.error;
        return false;
    }
    report("verifying", "sha256 校验通过", InstallProgressRange::kVerifyEnd);

    // 取消的最后一个安全边界：校验已过但还没动 .app，此时取消是零代价的
    if (cancel.cancelled()) {
        ::unlink(dmgPath.c_str());
        outErr = "更新已取消（未做任何改动）";
        return false;
    }

    // ---------- 3+4. 挂载 → 备份 → 替换 → 卸载（复用有序流水线）----------
    // ⚠️ install_from_local_dmg 内部第一件事就是**再校验一次** sha256（双重闸门）。
    report("installing", "正在安装…", InstallProgressRange::kVerifyEnd);
    std::string backup, ierr;
    const bool installed = install_from_local_dmg(dmgPath, plan.sha256, plan.size,
                                                 mntPath, target, backup, ierr);
    ::unlink(dmgPath.c_str());
    ::rmdir(mntPath.c_str());
    outBackup = backup;
    if (!installed) {
        outErr = ierr;
        return false;
    }
    fprintf(stderr, "RLPlayer: 更新已安装到 %s（备份：%s）\n",
            target.c_str(), backup.empty() ? "无（全新安装）" : backup.c_str());
    report("installing", "安装完成", InstallProgressRange::kInstallEnd);

    // ---------- 5. 自动重启 ----------
    // 只在 opts.autoRestart 时做（测试必须关掉：绝不真的 open 一个 .app）。
    if (opts.autoRestart) {
        std::string scriptPath, serr;
        AutoRestartOptions ro;
        ro.sleepMs = 1500;
        ro.waitPid = (long long)::getpid();    // 等本进程真的退出再起新实例
        if (!schedule_auto_restart(target, scriptPath, serr, ro)) {
            fprintf(stderr, "RLPlayer: 自动重启失败（%s），回退到手动重启提示\n", serr.c_str());
            // 失败不改变"安装成功"这个事实，但要让调用方知道要不要提示手动重启
            outErr = "installed-but-needs-manual-restart:" + serr;
        }
    }
    report("done", "更新完成", InstallProgressRange::kDone);
    return true;
}

// ---------------------------------------------------------------------------
// 一键更新（异步）：run_install_pipeline + 主线程收尾
// ⚠️ 任何一步失败都**立即中止**且不碰现有 .app（除替换阶段的备份回滚）。
// ---------------------------------------------------------------------------
void begin_install(const CheckResult& plan, ProgressFn progress, InstallFn done, CancelToken cancel) {
    // 先做一次纯本地合法性检查：只有 UpdateAvailable 才允许安装
    if (plan.decision != Decision::UpdateAvailable) {
        if (done) done(false, @"没有可用的更新计划");
        return;
    }
    // 2026-10-26 诊断：用户实测「下载地址不在白名单」，但日志里 url=[] 是空的。
    // 这行记录**入口看到的**原始值，用来区分"plan 本来就是空的"与"后面被改坏了"。
    {
        char line[1200];
        std::snprintf(line, sizeof line,
                      "BEGIN_INSTALL_ENTER decision=%s url=[%s] sha_len=%zu size=%lld\n",
                      plan.code(), plan.downloadUrl.c_str(), plan.sha256.size(), plan.size);
        detail_native::AppendUpdateLog(line);
    }
    if (!update_download_url_allowed(plan.downloadUrl)) {
        char line[1200];
        std::snprintf(line, sizeof line, "BEGIN_INSTALL_REJECT url=[%s]\n", plan.downloadUrl.c_str());
        detail_native::AppendUpdateLog(line);
        if (done) done(false, @"下载地址不在白名单，已拒绝");
        return;
    }
    if (!is_hex64(plan.sha256)) {
        if (done) done(false, @"清单未提供合法的 sha256，已拒绝安装");
        return;
    }
    if (rta::platform::temp_dir_utf8().empty()) {
        if (done) done(false, @"没有可用的临时目录");
        return;
    }

    // ⚠️ 2026-10-26 修的真 BUG（用户实测「下载地址不在白名单」，日志里 url=[] 为空）：
    //   plan 是 **const 引用参数**，而下面的 dispatch_async 是**异步**执行。
    //   调用方 mac_host.mm 传的是 `self.lastUpdatePlan`（结构体属性）⟹ 取值得临时对象，
    //   begin_install 一返回临时对象就析构，block 里那个引用立刻悬垂；
    //   等后台队列真跑起来，读到的 downloadUrl 是被回收的内存（实测就是空串）。
    //   症状极具迷惑性：**入口检查通过**（临时对象那时还活着），异步下载时才变空
    //   ⟹ 白名单闸门拒绝空串，UI 显示「下载地址不在白名单」，看起来像白名单配错了。
    //   修法：进 block 前做**值拷贝**，block 按值捕获这份拷贝，生命周期与 block 一致。
    const CheckResult planCopy = plan;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        InstallPipelineOptions opts;      // 生产默认：目标=当前 .app，自动重启=开
        std::string err, backup;
        const bool ok = run_install_pipeline(planCopy, progress, cancel, opts, err, backup);

        // outErr 以 "installed-but-needs-manual-restart:" 开头 = 装好了但没重启成 ⟹ 走兜底
        const bool installedButNoRestart =
            ok && err.rfind("installed-but-needs-manual-restart:", 0) == 0;

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) {
                if (done) done(false, [NSString stringWithUTF8String:err.c_str()]);
                return;
            }
            if (installedButNoRestart) {
                // 兜底：脚本建不出来/派发失败（磁盘满、权限、临时目录不可用）⟹ 必须提示
                NSAlert* a = [[NSAlert alloc] init];
                a.messageText = @"更新已安装";
                a.informativeText = [NSString stringWithFormat:
                    @"RLPlayer %s 已安装，但**自动重启没能启动**。\n\n"
                    @"请手动退出并重新打开 RLPlayer 以完成更新。",
                    planCopy.remoteVersion.c_str()];
                [a addButtonWithTitle:@"好"];
                [a runModal];
                if (done) done(true, @"更新已安装，请手动重启");
                return;
            }
            // 正常路径：脚本已在等本进程退出，这里干净退出即可
            if (done) done(true, @"更新已安装，正在自动重启");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               // NSApp terminate 会走 applicationWillTerminate（协作式停核心），
                               // 比 exit(0) 干净；脚本已经在等本 pid 消失。
                               [NSApp terminate:nil];
                           });
        });
    });
}

} // namespace rta::update
