// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// mac_host.mm — RLPlayer macOS 原生壳（单进程架构：WKURLSchemeHandler 桥接内置核心）
//
// 架构设计（单进程合并）：
//   主程序 rlplayer_mac 为纯 Cocoa 壳进程（NSWindow + WKWebView）。
//   后端以库形式嵌入本进程（tools/rlapp_core.h），不再启动独立服务子进程，
//   不再监听本地 HTTP 端口，避免端口冲突与本地网络权限弹窗。
//
// 通信机制：
//   1. 自定义协议 `rlplayer://app/`：
//      通过 WKURLSchemeHandler 拦截页面主文档、静态资源（/、/app.js、/favicon）及
//      所有 `/api/...` 请求，转交 rlapp::dispatch 处理。
//      请求在 GCD 全局并发队列执行，响应 NSData 保证二进制安全（支持包含 0x00 字节的音频/图片）。
//   2. window.chrome.webview 垫片（PLATFORM.md §10.2 契约）：
//      在 documentStart 注入兼容对象，保留 9 条 postMessage 协议：
//      UI → 宿主：min / max / close / drag / theme:* / openurl:* / resize:*
//      宿主 → UI：max / normal（窗口尺寸变化通知）
//   3. 防御性 transport 垫片：
//      WKWebView 对自定义 scheme 上带 Blob/File 请求体的 XHR/fetch 存在原生忽略历史缺陷，
//      注入防御性包装通过 WKScriptMessageHandlerWithReply (@"rltransport") 转发，
//      确保曲目拖拽上传、诊断 ZIP/JSON 导出等功能不受平台行为差异影响。
//   4. 生命周期与安全退出：
//      主线程定时器轮询 rlapp::exit_requested()（响应 /api/quit 与关闭信号）；
//      退出时等待在途 scheme tasks 完成后调用 rlapp::stop_embedded()，协作优雅退出。
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#include <cstdio>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <cctype>
#include <fstream>
#include <string>
#include <vector>
#include <mutex>
#include <condition_variable>
#include <chrono>

#if __has_include("rlapp_core.h")
#include "rlapp_core.h"
#elif __has_include("net/webui.h")
#include "net/webui.h"
namespace rlapp {
bool start_embedded();
std::string dispatch(const rta::net::HttpRequest&, std::string& contentType);
bool exit_requested();
void request_shutdown();
void stop_embedded();
int cli_main(int argc, char** argv);
}
#else
namespace rta::net {
struct HttpRequest { std::string method, path, body; };
}
namespace rlapp {
bool start_embedded();
std::string dispatch(const rta::net::HttpRequest&, std::string& contentType);
bool exit_requested();
void request_shutdown();
void stop_embedded();
int cli_main(int argc, char** argv);
}
#endif

// F-4 自动更新原生执行层（tools/mac_update.mm）。用 __has_include 保护：
// tests/test_mac_transport.mm 以 #include "../tools/mac_host.mm" 的方式复用本文件的
// scheme handler 与消息表，但它不链接 mac_update.mm，因此这里必须可缺省。
// ⚠️ 用**构建宏**而不是 __has_include 作为门控（2026-10-26 踩过）：
//   tests/test_mac_transport.mm 以 #include "../tools/mac_host.mm" 复用本文件，
//   而它的 include 路径里也有 tools/ ⟹ __has_include("mac_update.h") 会命中，
//   于是编译期认为"有引擎"、链接期却没有 mac_update.o，报 undefined symbols。
//   现在只在 CMake 给 rlplayer_mac 定义 RL_WITH_UPDATE 时才启用真引擎。
#if defined(RL_WITH_UPDATE) && __has_include("mac_update.h")
#define RL_HAVE_MAC_UPDATE 1
#include "mac_update.h"
#else
// tests/test_mac_transport.mm 复用本文件但不链接 mac_update.mm ⟹ 这条回退让
// 「更新」两条消息在没有更新模块时也**编译通过**，运行时回 unsupported（不静默）。
namespace rta::update {
struct NativeProgress { std::string stage, detail; int percent = -1; };
struct CheckResult {
    std::string remoteVersion, notes, error;
    int status = 0;
    bool available() const { return false; }
    bool up_to_date() const { return false; }
    const char* code() const { return "unsupported"; }
};
}
#endif

// 邮件反馈通道原生层（tools/mac_feedback.mm）。同样用**构建宏**门控而不是 __has_include：
// tests/test_mac_transport.mm 以 #include "../tools/mac_host.mm" 复用本文件，它的 include
// 路径里也有 tools/ ⟹ __has_include 会命中，但链接期没有 mac_feedback.o。
// 现在只在 CMake 给目标定义 RL_WITH_FEEDBACK 时才启用真实现。
#if defined(RL_WITH_FEEDBACK) && __has_include("mac_feedback.h")
#define RL_HAVE_MAC_FEEDBACK 1
#include "mac_feedback.h"
#endif

// 1.1.1 D2：更新检查失败也要留稳定错误码（不只在原生弹窗里说人话）。
#if __has_include("diag/diag.h")
#include "diag/diag.h"
#endif

#if __has_include("platform/host_msg.h")
#include "platform/host_msg.h"
#else
namespace rta::platform {
enum class HostAction { None, Minimize, Maximize, Close, Drag, Theme, OpenUrl, Resize, PickDir,
                        UpdateCheck, UpdateInstall, FeedbackCompose, FeedbackDiagOnly };
struct HostMessage {
    HostAction action = HostAction::None;
    std::string arg;
    bool allowed = true;
    std::string reason;
    bool attach_diag = false;   // 2026-10-26 邮件反馈：是否附诊断包
    std::string diag_path;      // 页面给的诊断包临时路径（宿主会校验）
};
inline bool external_url_allowed(const std::string& url) {
    if (url.empty() || url.size() > 4096) return false;
    for (char c : url) if (c == '\n' || c == '\r' || c == '\t' || c == ' ') return false;
    auto starts = [&](const char* p) {
        size_t n = std::char_traits<char>::length(p);
        if (url.size() < n) return false;
        for (size_t i = 0; i < n; ++i) {
            char a = url[i], b = p[i];
            if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
            if (b >= 'A' && b <= 'Z') b = (char)(b - 'A' + 'a');
            if (a != b) return false;
        }
        return true;
    };
    if (!starts("http://") && !starts("https://")) return false;
    size_t host = url.find("://") + 3;
    return host < url.size() && url[host] != '/' && url[host] != '?';
}
inline HostMessage parse_host_message(const std::string& m) {
    HostMessage r;
    if (m == "min") { r.action = HostAction::Minimize; return r; }
    if (m == "max") { r.action = HostAction::Maximize; return r; }
    if (m == "close") { r.action = HostAction::Close; return r; }
    if (m == "drag") { r.action = HostAction::Drag; return r; }
    if (m.rfind("theme:", 0) == 0) {
        r.action = HostAction::Theme;
        r.arg = m.substr(6);
        return r;
    }
    if (m.rfind("resize:", 0) == 0) {
        r.action = HostAction::Resize;
        r.arg = m.substr(7);
        return r;
    }
    if (m.rfind("openurl:", 0) == 0) {
        r.action = HostAction::OpenUrl;
        r.arg = m.substr(8);
        r.allowed = external_url_allowed(r.arg);
        return r;
    }
    // 2026-10-25：原生「选择文件夹」（与 platform/host_msg.h 保持同步）
    if (m == "pickdir") { r.action = HostAction::PickDir; return r; }
    if (m.rfind("pickdir:", 0) == 0) {
        r.action = HostAction::PickDir;
        r.arg = m.substr(8);
        return r;
    }
    // 2026-10-26 邮件反馈（与 src/platform/host_msg.h 保持同步；收件人永远是代码常量，
    // 协议里**没有**收件人字段）。回退版只做最基本的形态切分，清洗仍在 rta::feedback 里。
    if (m.rfind("feedback:", 0) == 0) {
        std::string rest = m.substr(9);
        const std::string dtag = "|diag:";
        const std::size_t dpos = rest.find(dtag);
        if (dpos != std::string::npos) {
            r.diag_path = rest.substr(dpos + dtag.size());
            rest = rest.substr(0, dpos);
            r.attach_diag = true;
        }
        if (rest == "diagonly") { r.action = HostAction::FeedbackDiagOnly; r.attach_diag = true; return r; }
        if (rest == "compose")  { r.action = HostAction::FeedbackCompose; return r; }
        if (rest == "compose+zip") { r.action = HostAction::FeedbackCompose; r.attach_diag = true; return r; }
        if (rest.rfind("compose+zip:", 0) == 0) {
            r.action = HostAction::FeedbackCompose; r.arg = rest.substr(12); r.attach_diag = true; return r;
        }
        if (rest.rfind("compose:", 0) == 0) {
            r.action = HostAction::FeedbackCompose; r.arg = rest.substr(8); return r;
        }
        r.action = HostAction::None;
        r.reason = "unknown feedback command";
        return r;
    }
    return r;
}
}
#endif

// ---------------------------------------------------------------------------
// 工具函数：从 NSURLRequest 提取原始请求体（二进制安全）
// ---------------------------------------------------------------------------
static std::string ExtractRequestBody(NSURLRequest *req) {
    if (req.HTTPBody) {
        return std::string((const char *)req.HTTPBody.bytes, req.HTTPBody.length);
    }
    if (req.HTTPBodyStream) {
        NSInputStream *stream = req.HTTPBodyStream;
        [stream open];
        std::string body;
        uint8_t buffer[8192];
        while ([stream hasBytesAvailable]) {
            NSInteger len = [stream read:buffer maxLength:sizeof(buffer)];
            if (len > 0) {
                body.append((const char *)buffer, (size_t)len);
            } else {
                break;
            }
        }
        [stream close];
        return body;
    }
    return "";
}

// ---------------------------------------------------------------------------
// 垫片脚本：window.chrome.webview 桥接 + 自定义 scheme 传输辅助
// ---------------------------------------------------------------------------
static NSString *const kShim = @
"(function() {\n"
"  /* ===== 血泪 BUG 备忘（2026-10-25，勿删）===== */\n"
"  /* 本脚本由相邻 ObjC 字符串字面量拼接而成，而 ObjC 拼接**不会**插入换行。 */\n"
"  /* 因此：每一行字面量末尾都必须显式写反斜杠 n，且本脚本内禁止出现由两条斜线 */\n"
"  /* 组成的行注释 —— 否则整段脚本会被第一条行注释吞成一行、全部失效 */\n"
"  /* （实测后果：machost 类与 window.chrome.webview 垫片都不执行，窗口按钮与 */\n"
"  /* 红绿灯安全区全失效；tests/test_mac_transport.mm 已加回归断言锁死这两条）。 */\n"
"  /* mac 原生宿主标记：macOS 已有左上角红绿灯，页面自带 min/max/close 必须隐藏， */\n"
"  /* 顶栏左侧也据此预留红绿灯安全区（见 ui_page.h 的 html.machost 规则）。 */\n"
"  function markHost() {\n"
"    var de = (typeof document !== 'undefined' && document) ? document.documentElement : null;\n"
"    if (!de || !de.classList || !de.classList.add) return;\n"
"    de.classList.add('machost', 'webview2');\n"
"  }\n"
"  markHost();\n"
"  /* 兜底：documentStart 注入时 documentElement 可能还不存在，DOMContentLoaded 再挂一次， */\n"
"  /* 确保无论何时注入都 100% 挂上 machost 与 webview2 两个类。 */\n"
"  try {\n"
"    if (typeof document !== 'undefined' && document && typeof document.addEventListener === 'function') {\n"
"      document.addEventListener('DOMContentLoaded', function() { markHost(); });\n"
"    }\n"
"  } catch (e) {}\n"
"  /* 1. window.chrome.webview 垫片（对齐 PLATFORM.md 第 10.2 节契约） */\n"
"  if (!window.chrome || !window.chrome.webview) {\n"
"    function emit(data) {\n"
"      var ev = { data: String(data) };\n"
"      (window.chrome.webview.__l || []).forEach(function(fn) { try { fn(ev); } catch (e) {} });\n"
"    }\n"
"    window.chrome = window.chrome || {};\n"
"    window.chrome.webview = {\n"
"      __l: [],\n"
"      postMessage: function(msg) {\n"
"        try { window.webkit.messageHandlers.rlhost.postMessage(String(msg)); } catch (e) {}\n"
"      },\n"
"      addEventListener: function(type, fn) {\n"
"        if (type === 'message' && typeof fn === 'function') this.__l.push(fn);\n"
"      },\n"
"      removeEventListener: function(type, fn) {\n"
"        if (type !== 'message') return;\n"
"        this.__l = this.__l.filter(function(f) { return f !== fn; });\n"
"      },\n"
"      __emit: emit\n"
"    };\n"
"  }\n"
"  /* 2. 自定义 scheme 防御性传输：Blob/File 二进制转换与专用桥接 */\n"
"  function blobToBase64(blob) {\n"
"    return new Promise(function(resolve, reject) {\n"
"      var reader = new FileReader();\n"
"      reader.onload = function() {\n"
"        var bytes = new Uint8Array(reader.result);\n"
"        var binary = '';\n"
"        var chunk = 8192;\n"
"        for (var i = 0; i < bytes.length; i += chunk) {\n"
"          binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));\n"
"        }\n"
"        resolve(btoa(binary));\n"
"      };\n"
"      reader.onerror = reject;\n"
"      reader.readAsArrayBuffer(blob);\n"
"    });\n"
"  }\n"
"  function callNativeTransport(method, url, body) {\n"
"    return Promise.resolve().then(function() {\n"
"      if (body && (body instanceof Blob || (typeof File !== 'undefined' && body instanceof File))) {\n"
"        return blobToBase64(body).then(function(b64) {\n"
"          return { method: method, url: url, bodyBase64: b64 };\n"
"        });\n"
"      } else if (body !== undefined && body !== null) {\n"
"        return { method: method, url: url, body: String(body) };\n"
"      } else {\n"
"        return { method: method, url: url };\n"
"      }\n"
"    }).then(function(payload) {\n"
"      return window.webkit.messageHandlers.rltransport.postMessage(payload);\n"
"    });\n"
"  }\n"
"  var origXHR = window.XMLHttpRequest;\n"
"  if (origXHR) {\n"
"    var origOpen = origXHR.prototype.open;\n"
"    var origSend = origXHR.prototype.send;\n"
"    origXHR.prototype.open = function(method, url) {\n"
"      this._rlMethod = method; this._rlUrl = url;\n"
"      return origOpen.apply(this, arguments);\n"
"    };\n"
"    origXHR.prototype.send = function(body) {\n"
"      var self = this;\n"
"      if (body && (body instanceof Blob || (typeof File !== 'undefined' && body instanceof File))) {\n"
"        callNativeTransport(self._rlMethod || 'POST', self._rlUrl || '/', body).then(function(res) {\n"
"          var respText = res.body || '';\n"
"          if (res.isBase64 && res.bodyBase64) {\n"
"            try { respText = atob(res.bodyBase64); } catch (e) { respText = ''; }\n"
"          }\n"
"          Object.defineProperty(self, 'status', { value: res.status || 200, writable: false });\n"
"          Object.defineProperty(self, 'statusText', { value: 'OK', writable: false });\n"
"          Object.defineProperty(self, 'responseText', { value: respText, writable: false });\n"
"          Object.defineProperty(self, 'response', { value: respText, writable: false });\n"
"          Object.defineProperty(self, 'readyState', { value: 4, writable: false });\n"
"          if (typeof self.onreadystatechange === 'function') self.onreadystatechange();\n"
"          if (typeof self.onload === 'function') self.onload();\n"
"        }).catch(function(err) {\n"
"          if (typeof self.onerror === 'function') self.onerror(err);\n"
"        });\n"
"        return;\n"
"      }\n"
"      return origSend.apply(this, arguments);\n"
"    };\n"
"  }\n"
"  var origFetch = window.fetch;\n"
"  if (origFetch) {\n"
"    window.fetch = function(input, init) {\n"
"      var url = typeof input === 'string' ? input : (input && input.url ? input.url : '');\n"
"      var opt = init || {};\n"
"      var method = opt.method || (input && input.method) || 'GET';\n"
"      var body = opt.body;\n"
"      if (body && (body instanceof Blob || (typeof File !== 'undefined' && body instanceof File))) {\n"
"        return callNativeTransport(method, url, body).then(function(res) {\n"
"          var data;\n"
"          if (res.isBase64 && res.bodyBase64) {\n"
"            var binary = atob(res.bodyBase64);\n"
"            var len = binary.length;\n"
"            var bytes = new Uint8Array(len);\n"
"            for (var i = 0; i < len; i++) bytes[i] = binary.charCodeAt(i);\n"
"            data = bytes.buffer;\n"
"          } else {\n"
"            data = res.body || '';\n"
"          }\n"
"          return new Response(data, {\n"
"            status: res.status || 200,\n"
"            headers: { 'Content-Type': res.contentType || 'text/plain' }\n"
"          });\n"
"        });\n"
"      }\n"
"      return origFetch.apply(this, arguments).catch(function(err) {\n"
"        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.rltransport) {\n"
"          return callNativeTransport(method, url, body).then(function(res) {\n"
"            var data;\n"
"            if (res.isBase64 && res.bodyBase64) {\n"
"              var binary = atob(res.bodyBase64);\n"
"              var len = binary.length;\n"
"              var bytes = new Uint8Array(len);\n"
"              for (var i = 0; i < len; i++) bytes[i] = binary.charCodeAt(i);\n"
"              data = bytes.buffer;\n"
"            } else {\n"
"              data = res.body || '';\n"
"            }\n"
"            return new Response(data, {\n"
"              status: res.status || 200,\n"
"              headers: { 'Content-Type': res.contentType || 'text/plain' }\n"
"            });\n"
"          });\n"
"        }\n"
"        throw err;\n"
"      });\n"
"    };\n"
"  }\n"
"})();\n";

// ---------------------------------------------------------------------------
// Scheme Task 状态上下文与 WKURLSchemeHandler 实现
// ---------------------------------------------------------------------------
@interface RLSchemeTaskContext : NSObject
@property (nonatomic, strong) id<WKURLSchemeTask> task;
@property (nonatomic, assign) BOOL stopped;
@end

@implementation RLSchemeTaskContext
@end

@interface RLURLSchemeHandler : NSObject <WKURLSchemeHandler> {
    std::mutex _mutex;
    std::condition_variable _cv;
    NSMapTable<id<WKURLSchemeTask>, RLSchemeTaskContext *> *_tasks;
    int _activeWorkers;
    BOOL _isStopping;
}
- (instancetype)init;
- (BOOL)waitForInFlightTasksWithTimeout:(NSTimeInterval)timeout;
- (int)activeWorkersCount;
- (NSUInteger)registeredTasksCount;
@end

@implementation RLURLSchemeHandler

- (instancetype)init {
    self = [super init];
    if (self) {
        _tasks = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality
                                       valueOptions:NSPointerFunctionsStrongMemory];
        _activeWorkers = 0;
        _isStopping = NO;
    }
    return self;
}

- (int)activeWorkersCount {
    std::lock_guard<std::mutex> lock(_mutex);
    return _activeWorkers;
}

- (NSUInteger)registeredTasksCount {
    std::lock_guard<std::mutex> lock(_mutex);
    return [_tasks count];
}

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id <WKURLSchemeTask>)urlSchemeTask {
    (void)webView;
    RLSchemeTaskContext *ctx = [[RLSchemeTaskContext alloc] init];
    ctx.task = urlSchemeTask;
    ctx.stopped = NO;

    {
        std::lock_guard<std::mutex> lock(_mutex);
        if (_isStopping) {
            // 拒绝新请求时绝不持锁回调 WebKit
            goto reject;
        }
        [_tasks setObject:ctx forKey:urlSchemeTask];
        _activeWorkers++;
    }

    {
        NSURLRequest *req = urlSchemeTask.request;
        NSURL *url = req.URL;
        NSString *methodStr = req.HTTPMethod ?: @"GET";

        NSURLComponents *comp = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        NSString *rawPath = comp.percentEncodedPath;
        if (!rawPath || rawPath.length == 0) rawPath = @"/";
        if (comp.percentEncodedQuery && comp.percentEncodedQuery.length > 0) {
            rawPath = [rawPath stringByAppendingFormat:@"?%@", comp.percentEncodedQuery];
        }

        std::string method = [methodStr UTF8String];
        std::string path = [rawPath UTF8String];
        std::string body = ExtractRequestBody(req);

        // 在 GCD 全局并发队列异步处理业务，绝对不加全局锁，保持完全非阻塞并发
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            std::string contentType;
            std::string respBody;
            try {
                // RAII 保护业务计数：只要离开业务分发范围，无论正常返回、抛异常还是提前返回，必须递减
                struct WorkerGuard {
                    RLURLSchemeHandler *handler;
                    bool active = true;
                    ~WorkerGuard() {
                        if (active) {
                            std::lock_guard<std::mutex> lock(handler->_mutex);
                            handler->_activeWorkers--;
                            handler->_cv.notify_all();
                        }
                    }
                } workerGuard{self};

                rta::net::HttpRequest httpReq;
                httpReq.method = std::move(method);
                httpReq.path = std::move(path);
                httpReq.body = std::move(body);

                try {
                    respBody = rlapp::dispatch(httpReq, contentType);
                } catch (...) {
                    respBody = "{\"ok\":false,\"error\":\"internal error\"}";
                    contentType = "application/json; charset=utf-8";
                }
                if (contentType.empty()) {
                    contentType = "application/octet-stream";
                }

                // dispatch 完成所有核心访问后，在此立即递减业务 worker 计数
                {
                    std::lock_guard<std::mutex> lock(self->_mutex);
                    workerGuard.active = false;
                    self->_activeWorkers--;
                    self->_cv.notify_all();
                }
            } catch (...) {
                // 兜底异常防护
            }

            NSData *respData = [NSData dataWithBytes:respBody.data() length:respBody.size()];
            NSDictionary *headers = @{
                @"Content-Type": [NSString stringWithUTF8String:contentType.c_str()],
                @"Content-Length": [NSString stringWithFormat:@"%zu", respBody.size()],
                @"Access-Control-Allow-Origin": @"*",
                @"Cache-Control": @"no-cache"
            };
            NSHTTPURLResponse *httpResp = [[NSHTTPURLResponse alloc] initWithURL:url
                                                                      statusCode:200
                                                                     HTTPVersion:@"HTTP/1.1"
                                                                    headerFields:headers];

            // 关键死锁点（实测 2026-10-25）：不能持 _mutex 调用 didReceiveResponse/didFinish。
            // WKURLSchemeTask 的回调会同步回到 WebKit 主线程；startURLSchemeTask 同时也要拿
            // _mutex，形成主线程 <-> worker 互等，表现为白屏 + 退出卡住。
            // 做法：锁内只做“取消状态检查 + 摘表”，随后释放锁再回调 WebKit。
            {
                std::lock_guard<std::mutex> lock(self->_mutex);
                if (ctx.stopped) {
                    // Task 已被 WebKit 取消或关闭，绝不重复回调
                    return;
                }
                ctx.stopped = YES;
                [self->_tasks removeObjectForKey:urlSchemeTask];
            }
            self->_cv.notify_all();

            @try {
                [urlSchemeTask didReceiveResponse:httpResp];
                if (respData.length > 0) {
                    [urlSchemeTask didReceiveData:respData];
                }
                [urlSchemeTask didFinish];
            } @catch (NSException *ex) {
                // WebKit 内部在销毁状态可能引发异常，吞掉以防崩溃
            }
        });
        return;
    }

reject:
    // 锁外回调 WebKit，绝不持锁防止死锁
    {
        NSError *err = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
        @try {
            [urlSchemeTask didFailWithError:err];
        } @catch (NSException *ex) {}
    }
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id <WKURLSchemeTask>)urlSchemeTask {
    (void)webView;
    std::lock_guard<std::mutex> lock(_mutex);
    RLSchemeTaskContext *ctx = [_tasks objectForKey:urlSchemeTask];
    if (ctx) {
        ctx.stopped = YES;
        [_tasks removeObjectForKey:urlSchemeTask];
        _cv.notify_all();
    }
}

- (BOOL)waitForInFlightTasksWithTimeout:(NSTimeInterval)timeout {
    std::unique_lock<std::mutex> lock(_mutex);
    _isStopping = YES;   // 此后 startURLSchemeTask 会立即用 NSURLErrorCancelled 拒绝
    auto deadline = std::chrono::steady_clock::now() +
                    std::chrono::milliseconds((int64_t)(timeout * 1000));
    // 等待实际业务 workers 排空（_activeWorkers == 0）且 _tasks 也为空
    return _cv.wait_until(lock, deadline, [self] {
        return self->_activeWorkers == 0 && [self->_tasks count] == 0;
    });
}

@end

// ---------------------------------------------------------------------------
// 专用 RPC 消息处理器：支持带 Reply 的二进制安全传输（用于 Blob/File 上传）
// ---------------------------------------------------------------------------
@interface RLTransportHandler : NSObject <WKScriptMessageHandlerWithReply>
@end

@implementation RLTransportHandler

- (void)userContentController:(WKUserContentController *)ucc
      didReceiveScriptMessage:(WKScriptMessage *)msg
                 replyHandler:(void (^)(id reply, NSString *errorMessage))replyHandler {
    (void)ucc;
    NSDictionary *dict = [msg.body isKindOfClass:[NSDictionary class]] ? (NSDictionary *)msg.body : nil;
    if (!dict) {
        replyHandler(nil, @"Invalid request payload");
        return;
    }

    NSString *methodStr = dict[@"method"] ?: @"GET";
    NSString *urlStr = dict[@"url"] ?: @"/";
    NSString *bodyStr = dict[@"body"];
    NSString *bodyBase64 = dict[@"bodyBase64"];

    std::string method = [methodStr UTF8String];
    std::string path;

    NSURL *parsedUrl = [NSURL URLWithString:urlStr];
    if (parsedUrl) {
        NSURLComponents *comp = [NSURLComponents componentsWithURL:parsedUrl resolvingAgainstBaseURL:NO];
        NSString *rawPath = comp.percentEncodedPath;
        if (!rawPath || rawPath.length == 0) rawPath = @"/";
        if (comp.percentEncodedQuery && comp.percentEncodedQuery.length > 0) {
            rawPath = [rawPath stringByAppendingFormat:@"?%@", comp.percentEncodedQuery];
        }
        path = [rawPath UTF8String];
    } else {
        path = [urlStr UTF8String];
    }

    std::string body;
    if (bodyBase64 && [bodyBase64 length] > 0) {
        NSData *decoded = [[NSData alloc] initWithBase64EncodedString:bodyBase64 options:0];
        if (decoded) {
            body.assign((const char *)decoded.bytes, decoded.length);
        }
    } else if (bodyStr) {
        body = [bodyStr UTF8String];
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        rta::net::HttpRequest httpReq;
        httpReq.method = std::move(method);
        httpReq.path = std::move(path);
        httpReq.body = std::move(body);

        std::string contentType;
        std::string respBody;
        try {
            respBody = rlapp::dispatch(httpReq, contentType);
        } catch (...) {
            respBody = "{\"ok\":false,\"error\":\"internal error\"}";
            contentType = "application/json; charset=utf-8";
        }

        BOOL isBinary = NO;
        if (contentType.find("image/") != std::string::npos ||
            contentType.find("audio/") != std::string::npos ||
            contentType.find("application/zip") != std::string::npos ||
            contentType.find("application/octet-stream") != std::string::npos) {
            isBinary = YES;
        }

        if (isBinary) {
            NSData *nsData = [NSData dataWithBytes:respBody.data() length:respBody.size()];
            NSString *b64 = [nsData base64EncodedStringWithOptions:0];
            replyHandler(@{
                @"status": @200,
                @"contentType": [NSString stringWithUTF8String:contentType.c_str()],
                @"bodyBase64": b64 ?: @"",
                @"isBase64": @YES
            }, nil);
        } else {
            NSString *nsStr = [[NSString alloc] initWithBytes:respBody.data()
                                                       length:respBody.size()
                                                     encoding:NSUTF8StringEncoding];
            if (!nsStr) {
                NSData *nsData = [NSData dataWithBytes:respBody.data() length:respBody.size()];
                NSString *b64 = [nsData base64EncodedStringWithOptions:0];
                replyHandler(@{
                    @"status": @200,
                    @"contentType": [NSString stringWithUTF8String:contentType.c_str()],
                    @"bodyBase64": b64 ?: @"",
                    @"isBase64": @YES
                }, nil);
            } else {
                replyHandler(@{
                    @"status": @200,
                    @"contentType": [NSString stringWithUTF8String:contentType.c_str()],
                    @"body": nsStr,
                    @"isBase64": @NO
                }, nil);
            }
        }
    });
}

@end

// ---------------------------------------------------------------------------
// 宿主应用委托与窗口控制
// ---------------------------------------------------------------------------

// 1.1.1-beta2：原生菜单语言。真相源与页面一致 —— rlplayer-settings.conf 的 `lang=en`。
// 这里刻意**不依赖** rta::platform::config_dir_utf8()（本文件在测试里被 #include 复用，
// 那条路径可能没链平台层），所以自己按同一条规则解析：env RLPLAYER_STATE_DIR >
// ~/Library/Application Support/RLPlayer > 什么都不认（回落中文）。
static bool native_ui_lang_is_en() {
    std::string base;
    if (const char* env = std::getenv("RLPLAYER_STATE_DIR")) {
        if (*env) {
            base = env;
            while (!base.empty() && (base.back() == '\\' || base.back() == '/')) base.pop_back();
        }
    }
    if (base.empty()) {
        @autoreleasepool {
            NSArray<NSString*>* dirs = NSSearchPathForDirectoriesInDomains(
                NSApplicationSupportDirectory, NSUserDomainMask, YES);
            if (dirs.count > 0) {
                NSString* p = [dirs[0] stringByAppendingPathComponent:@"RLPlayer"];
                const char* u = [p fileSystemRepresentation];
                if (u && *u) base = u;
            }
        }
    }
    if (base.empty()) return false;
    std::ifstream f(base + "/rlplayer-settings.conf");
    if (!f) return false;
    std::string line;
    while (std::getline(f, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        const size_t eq = line.find('=');
        if (eq == std::string::npos) continue;
        if (line.substr(0, eq) == "lang") {
            std::string v = line.substr(eq + 1);
            for (char& c : v) c = (char)std::tolower((unsigned char)c);
            return v == "en";
        }
    }
    return false;
}

@interface HostAppDelegate : NSObject <NSApplicationDelegate, WKScriptMessageHandler,
                                       WKNavigationDelegate, NSWindowDelegate, WKUIDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, strong) RLURLSchemeHandler *schemeHandler;
@property (nonatomic, strong) RLTransportHandler *transportHandler;
@property (nonatomic, strong) NSTimer *exitPollTimer;
@property (nonatomic) NSRect savedFrame;       // max 前的窗口 frame（还原用）
@property (nonatomic) bool zoomed;
@property (nonatomic) BOOL startupWindowRevealed;
// F-4：最近一次「检查更新」的结果，作为「一键更新」的安装计划。
// 为什么不接受页面传计划：页面若能把 download_url/sha256 塞进来，就等于让网页决定
// 宿主去下载并安装什么 —— sha256 由页面给的那一版等于没有闸门。
@property (nonatomic) rta::update::CheckResult lastUpdatePlan;
@end

@implementation HostAppDelegate

// The window remains hidden until the HTML theme is applied and WebKit has painted.
// Otherwise light/blue cold launch exposes the default dark native backing first.
- (void)revealStartupWindowForTheme:(NSString*)theme {
    const BOOL light=[theme isEqualToString:@"light"];
    const BOOL blue=[theme isEqualToString:@"blue"];
    NSColor* color=light ? [NSColor whiteColor] : (blue ?
        [NSColor colorWithSRGBRed:248.0/255 green:250.0/255 blue:1 alpha:1] :
        [NSColor colorWithSRGBRed:22.0/255 green:22.0/255 blue:24.0/255 alpha:1]);
    self.window.backgroundColor=color;
    if(@available(macOS 12.0,*))self.web.underPageBackgroundColor=color;
    self.window.appearance=[NSAppearance appearanceNamed:(light||blue)?NSAppearanceNameAqua:NSAppearanceNameDarkAqua];
    if(!self.startupWindowRevealed){self.startupWindowRevealed=YES;[self.window makeKeyAndOrderFront:nil];}
}
- (void)webView:(WKWebView*)webView didFinishNavigation:(WKNavigation*)navigation {
    (void)navigation;
    if(self.startupWindowRevealed || ![webView.URL.scheme isEqualToString:@"rlplayer"])return;
    [webView evaluateJavaScript:@"document.documentElement.dataset.theme||'dark'" completionHandler:^(id value,NSError* error){
        NSString* theme=(!error&&[value isKindOfClass:NSString.class])?value:@"dark";
        // The snapshot completion comes from WebContent after a rendered update, unlike
        // evaluateJavaScript returning an unresolved Promise on older WebKit releases.
        [webView takeSnapshotWithConfiguration:nil completionHandler:^(NSImage* image,NSError* snapshotError){
            (void)image;(void)snapshotError;
            [self revealStartupWindowForTheme:theme];
        }];
    }];
}

// ---------------- JS 对话框（WKUIDelegate）----------------
// 背景（2026-10-28 用户实测「之前保存的无法删除」）：WKWebView **不会**自己弹
// alert/confirm/prompt；页面调用时走 UIDelegate 回调，没有实现就静默返回
// confirm()=false、prompt()=nil ⟹ 删除服务器 / 重置 PEQ / 恢复默认参数这些
// 走了 confirm() 的按钮在 .app 里全部"点了没反应"。
// 这些对话框都是用户点击触发的短交互，这里用 NSAlert 走系统原生样式。
// 注意：completionHandler **必须且只能调用一次**，否则 WebKit 会一直挂着这次导航回调。
- (void)webView:(WKWebView *)webView
    runJavaScriptAlertPanelWithMessage:(NSString *)message
                      initiatedByFrame:(WKFrameInfo *)frame
                     completionHandler:(void (^)(void))completionHandler {
    (void)webView; (void)frame;
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = message.length ? message : @"";
    [a addButtonWithTitle:@"好"];
    a.alertStyle = NSAlertStyleInformational;
    if (self.window && self.window.attachedSheet == nil && self.window.isVisible) {
        [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
            (void)r;
            completionHandler();
        }];
    } else {
        [a runModal];
        completionHandler();
    }
}

- (void)webView:(WKWebView *)webView
    runJavaScriptConfirmPanelWithMessage:(NSString *)message
                        initiatedByFrame:(WKFrameInfo *)frame
                       completionHandler:(void (^)(BOOL))completionHandler {
    (void)webView; (void)frame;
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = message.length ? message : @"";
    // 第一枚按钮 = 确定（返回 YES）。用 firstButtonReturn 判定，不依赖按钮标题文案。
    [a addButtonWithTitle:@"确定"];
    [a addButtonWithTitle:@"取消"];
    a.alertStyle = NSAlertStyleWarning;
    if (self.window && self.window.attachedSheet == nil && self.window.isVisible) {
        [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
            completionHandler(r == NSAlertFirstButtonReturn);
        }];
    } else {
        completionHandler([a runModal] == NSAlertFirstButtonReturn);
    }
}

- (void)webView:(WKWebView *)webView
    runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt
                              defaultText:(NSString *)defaultText
                         initiatedByFrame:(WKFrameInfo *)frame
                        completionHandler:(void (^)(NSString *))completionHandler {
    (void)webView; (void)frame;
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = prompt.length ? prompt : @"";
    [a addButtonWithTitle:@"确定"];
    [a addButtonWithTitle:@"取消"];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
    field.stringValue = defaultText.length ? defaultText : @"";
    a.accessoryView = field;
    a.window.initialFirstResponder = field;
    if (self.window && self.window.attachedSheet == nil && self.window.isVisible) {
        [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
            completionHandler(r == NSAlertFirstButtonReturn ? field.stringValue : nil);
        }];
    } else {
        const NSModalResponse r = [a runModal];
        completionHandler(r == NSAlertFirstButtonReturn ? field.stringValue : nil);
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    (void)n;

    // 启动嵌入式核心（初始化库、音频后端与调度器）
    if (!rlapp::start_embedded()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *a = [[NSAlert alloc] init];
            a.messageText = @"RLPlayer 无法启动";
            a.informativeText = @"内置播放与服务核心初始化失败。";
            [a runModal];
            [NSApp terminate:nil];
        });
        return;
    }

    [self buildMenu];

    NSRect frame = NSMakeRect(0, 0, 1180, 760);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                    NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                                    NSWindowStyleMaskFullSizeContentView
                            backing:NSBackingStoreBuffered defer:NO];
    self.window.titleVisibility = NSWindowTitleHidden;      // 无标题文字（页面自带顶栏）
    self.window.titlebarAppearsTransparent = YES;
    self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.window.backgroundColor = [NSColor colorWithSRGBRed:22.0/255 green:22.0/255 blue:24.0/255 alpha:1.0];
    self.window.minSize = NSMakeSize(600, 400);
    [self.window center];
    self.window.delegate = self;

    // 红绿灯位置（2026-10-25）：挂一个**空**的 NSToolbar + Unified 样式，让 macOS 按原生
    // Unified Titlebar 规范摆放红绿灯（与 DSH / Apple Music 的视觉内边距一致）。
    //
    // ⚠️ 以下是本机（macOS 27.0.1 arm64）**像素级实测**结果，不是推测；后续改动请复测：
    //   | 配置                    | 灯组 x 范围 | 距顶 y   | 竖直中心 | 距页面 78px 安全区 |
    //   | 无 toolbar（改前）      | [10,67]     | [9,22]   | 15.5     | 11px              |
    //   | 空 toolbar + Unified    | [20,77]     | [19,32]  | 25.5     | 1px  ← 改后 |
    //   顶栏 52px 的理想竖直中心 = (52-14)/2 = 19 ⟹ y=[19,32]，Unified 正好命中；
    //   无 toolbar 时灯组偏高 9px，与顶栏文字基线不齐 —— 这才是"局促感"的真实来源。
    //   注意：网上常见的 "红绿灯在 (7,7)" 读数取自 NSButton.frame（标题栏容器坐标系），
    //   换算到窗口坐标是 (18,18)，不是真的贴边；别再用那个数当基准。
    //
    // ⚠️ 已知副作用（跨文件，需 ui_page.h 配合，本文件无法单方面解决）：
    //   Unified 把灯组右缘从 67 推到 77，而页面 `html.machost .top{padding-left:78px}`
    //   是按改前的 67+11 定的 ⟹ 现在只剩 1px，第三枚灯与品牌 Logo/标题视觉相接。
    //   建议把 ui_page.h 的 78px 提到 86px（窄窗那条 70px 同步到 78px）。
    //   在那一行改好之前，此处**保留** Unified：竖直居中是正确的，横向只差 8px 余量。
    //
    // 工具栏不放任何 item（showsBaselineSeparator = NO）⟹ 不拦截页面点击（已 hit-test 验证
    // 顶栏 y=10/26/40/51 命中的都是 WKWebView），也不改变 FullSizeContentView 的通栏效果。
    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"rlplayer.main.toolbar"];
    toolbar.showsBaselineSeparator = NO;
    self.window.toolbar = toolbar;
    if (@available(macOS 11.0, *)) {
        self.window.toolbarStyle = NSWindowToolbarStyleUnified;
    }

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];

    // 注册自定义 scheme handler
    self.schemeHandler = [[RLURLSchemeHandler alloc] init];
    [cfg setURLSchemeHandler:self.schemeHandler forURLScheme:@"rlplayer"];

    WKUserContentController *ucc = [[WKUserContentController alloc] init];
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:kShim
                                              injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                           forMainFrameOnly:YES]];
    [ucc addScriptMessageHandler:self name:@"rlhost"];

    self.transportHandler = [[RLTransportHandler alloc] init];
    [ucc addScriptMessageHandlerWithReply:self.transportHandler
                             contentWorld:[WKContentWorld pageWorld]
                                     name:@"rltransport"];
    cfg.userContentController = ucc;

    self.web = [[WKWebView alloc] initWithFrame:frame configuration:cfg];
    self.web.navigationDelegate = self;
    // Public API: never expose WKWebView's default white backing before first paint.
    if (@available(macOS 12.0, *)) self.web.underPageBackgroundColor = self.window.backgroundColor;
    // 2026-10-28（用户「之前保存的无法删除」）：**必须**设 WKUIDelegate。
    // WKWebView 默认不弹 JS 对话框，没有 UIDelegate 时 confirm() 直接返回 false
    // ⟹ 所有「删除/重置」类按钮在 .app 里点了毫无反应，而在 Edge/CLI 里正常
    // （所以网页端 UI 测试抓不到这一类缺陷）。
    self.web.UIDelegate = self;
    self.web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.window setContentView:self.web];

    // 主页面加载自定义 scheme URL
    [self.web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"rlplayer://app/"]]];
    // A bounded fallback preserves startup error visibility if navigation never finishes.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if(!self.startupWindowRevealed)[self revealStartupWindowForTheme:@"dark"];
    });

    // 轮询 rlapp::exit_requested()：响应 /api/quit 或 shutdown 请求
    self.exitPollTimer = [NSTimer scheduledTimerWithTimeInterval:0.2
                                                         repeats:YES
                                                           block:^(NSTimer * _Nonnull timer) {
        if (rlapp::exit_requested()) {
            [timer invalidate];
            [NSApp terminate:nil];
        }
    }];
}

- (void)buildMenu {
    // App 菜单：Cmd+Q / 关窗语义 + GPLv3 要求的「许可证」入口
    //
    // 为什么必须有「许可证」项（不是锦上添花）：
    //   GPLv3 §5(c)/§6 要求分发目标代码时附随许可证文本与获取源码的说明。
    //   打包脚本已把 LICENSE 放进 Contents/Resources/，但用户得**找得到**才行 ——
    //   Finder 里右键「显示包内容」不算合理入口，所以这里给一个菜单项直接打开。
    NSMenu *bar = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] init];
    // 1.1.1-beta2：App 菜单跟随界面语言（与页面同一真相源：rlplayer-settings.conf 的 lang）。
    // 为什么在宿主侧单独读一次：NSMenu 是原生对象，页面里的 i18n 引擎改不到它。
    // 代价（如实记录）：切换语言后菜单要**重启 App** 才变；页面重载不会重建 NSMenu。
    const bool en = native_ui_lang_is_en();
    [appMenu addItemWithTitle:(en ? @"About RLPlayer" : @"关于 RLPlayer")
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:(en ? @"License (GPLv3)" : @"许可证（GPLv3）")
                       action:@selector(openLicense:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:(en ? @"Quit RLPlayer" : @"退出 RLPlayer") action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [bar addItem:appItem];
    [NSApp setMainMenu:bar];
}

// 打开包内的 LICENSE（Contents/Resources/LICENSE）。
// 缺失时用弹窗如实说明，绝不静默什么也不做（铁律 3：不许假装成功）。
- (void)openLicense:(id)sender {
    (void)sender;
    NSString *res = [[[NSBundle mainBundle] bundlePath]
                     stringByAppendingPathComponent:@"Contents/Resources/LICENSE"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:res]) {
        [[NSWorkspace sharedWorkspace] openFile:res];
        return;
    }
    NSAlert *a = [[NSAlert alloc] init];
    if (native_ui_lang_is_en()) {
        a.messageText = @"LICENSE file not found";
        a.informativeText = @"This program is released under the GNU GPL v3 (or later). "
                            @"Contents/Resources/LICENSE is missing from the bundle; "
                            @"see the project repository for the full terms.";
        [a addButtonWithTitle:@"OK"];
    } else {
        a.messageText = @"未找到 LICENSE 文件";
        a.informativeText = @"本程序以 GNU GPL v3（或更新版本）发布。"
                            @"包内 Contents/Resources/LICENSE 缺失，"
                            @"请到项目仓库查看完整条款。";
        [a addButtonWithTitle:@"好"];
    }
    [a runModal];
}

// ---------------- PLATFORM.md §10.2 消息表：UI → 宿主 ----------------
- (void)userContentController:(WKUserContentController *)ucc
      didReceiveScriptMessage:(WKScriptMessage *)msg {
    (void)ucc;
    NSString *m = [msg.body isKindOfClass:[NSString class]] ? (NSString *)msg.body : nil;
    if (!m) return;

    using namespace rta::platform;
    HostMessage hm = parse_host_message([m UTF8String]);
    switch (hm.action) {
        case HostAction::Minimize:
            [self.window miniaturize:nil];                    // ShowWindow(SW_MINIMIZE)
            break;
        case HostAction::Maximize:
            // Windows 语义：最大化/还原切换（占满工作区，不是 mac 全屏）
            if (!self.zoomed) {
                self.savedFrame = self.window.frame;
                NSRect full = self.window.screen.visibleFrame;
                [self.window setFrame:full display:YES animate:YES];
                self.zoomed = YES;
                [self emitToPage:@"max"];
            } else {
                [self.window setFrame:self.savedFrame display:YES animate:YES];
                self.zoomed = NO;
                [self emitToPage:@"normal"];
            }
            break;
        case HostAction::Close:
            [NSApp terminate:nil];                            // PostMessage(WM_CLOSE)
            break;
        case HostAction::Drag: {
            // 页面顶栏拖动：最近一次鼠标事件发起窗口拖拽
            NSEvent *ev = [NSApp currentEvent];
            if (ev && (ev.type == NSEventTypeLeftMouseDown || ev.type == NSEventTypeLeftMouseDragged))
                [self.window performWindowDragWithEvent:ev];
            break;
        }
        case HostAction::Theme:
            // Do not reveal during document loading; didFinishNavigation owns first reveal.
            if(self.startupWindowRevealed)[self revealStartupWindowForTheme:[NSString stringWithUTF8String:hm.arg.c_str()]];
            if (hm.arg == "dark") {
                self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
            } else if (hm.arg == "light" || hm.arg == "blue") {
                self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
            }
            break;
        case HostAction::OpenUrl:
            if (hm.allowed) {
                NSURL *target = [NSURL URLWithString:[NSString stringWithUTF8String:hm.arg.c_str()]];
                if (target) {
                    [[NSWorkspace sharedWorkspace] openURL:target];
                }
            }
            break;
        case HostAction::PickDir: {
            // 2026-10-25（用户要求「要让用户可以通过点击文件夹来选择」）：
            // 弹原生 NSOpenPanel 选**目录**（canChooseDirectories=YES / canChooseFiles=NO）。
            // 为什么不在页面里用 <input type=file webkitdirectory>：
            //   它只能选"包含文件的目录"，**选不了空目录**，而且拿不到 macOS 原生目录选择体验。
            // 结果通过 emitToPage 回传：页面监听 pickdir:ok:<path> / pickdir:cancel。
            // 注意：必须在主线程弹（WKScriptMessageHandler 回调已在主线程，这里直接调）。
            NSOpenPanel *panel = [NSOpenPanel openPanel];
            panel.canChooseFiles = NO;
            panel.canChooseDirectories = YES;
            panel.allowsMultipleSelection = NO;
            panel.canCreateDirectories = YES;
            panel.prompt = @"选择";
            panel.message = @"选择音乐目录";
            // 初始目录：页面传进来的 arg（不存在就忽略，用系统默认）
            if (!hm.arg.empty()) {
                NSString *startPath = [NSString stringWithUTF8String:hm.arg.c_str()];
                if (startPath && startPath.length) {
                    BOOL isDir = NO;
                    if ([[NSFileManager defaultManager] fileExistsAtPath:startPath isDirectory:&isDir] && isDir) {
                        panel.directoryURL = [NSURL fileURLWithPath:startPath isDirectory:YES];
                    }
                }
            }
            NSModalResponse resp = [panel runModal];
            if (resp == NSModalResponseOK && panel.URL) {
                NSString *chosen = [panel.URL path];
                if (chosen && chosen.length) {
                    // 路径里可能有冒号（极罕见）与换行：换成安全形式再回传，
                    // 页面侧按 "pickdir:ok:" 前缀切第一个冒号之后的全部内容，所以冒号无碍。
                    NSString *safe = [chosen stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
                    [self emitToPage:[NSString stringWithFormat:@"pickdir:ok:%@", safe]];
                } else {
                    [self emitToPage:@"pickdir:cancel"];
                }
            } else {
                [self emitToPage:@"pickdir:cancel"];
            }
            break;
        }
        case HostAction::Resize: {
            // 窗口边缘拉伸：页面在最外 5px 铺 8 条热区发起 resize:<dir>
            // 宿主跟踪鼠标拖拽更新窗口 frame（方向对齐 platform/host_msg.h 白名单）
            std::string dir = hm.arg;
            NSWindow *win = self.window;
            if (!win) break;
            if (self.zoomed) {
                self.zoomed = NO;
                [self emitToPage:@"normal"];
            }
            NSRect startFrame = win.frame;
            NSPoint startMouse = [NSEvent mouseLocation];
            CGFloat minW = win.minSize.width > 0 ? win.minSize.width : 600.0;
            CGFloat minH = win.minSize.height > 0 ? win.minSize.height : 400.0;

            BOOL modifiesLeft = (dir == "left" || dir == "topleft" || dir == "bottomleft");
            BOOL modifiesRight = (dir == "right" || dir == "topright" || dir == "bottomright");
            BOOL modifiesTop = (dir == "top" || dir == "topleft" || dir == "topright");
            BOOL modifiesBottom = (dir == "bottom" || dir == "bottomleft" || dir == "bottomright");

            while (([NSEvent pressedMouseButtons] & 1) != 0) {
                NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp
                                                    untilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]
                                                       inMode:NSEventTrackingRunLoopMode
                                                      dequeue:YES];
                if (!event) continue;
                if (event.type == NSEventTypeLeftMouseUp) {
                    break;
                }
                if (event.type == NSEventTypeLeftMouseDragged) {
                    NSPoint curMouse = [NSEvent mouseLocation];
                    CGFloat dx = curMouse.x - startMouse.x;
                    CGFloat dy = curMouse.y - startMouse.y;
                    CGFloat newX = startFrame.origin.x;
                    CGFloat newY = startFrame.origin.y;
                    CGFloat newW = startFrame.size.width;
                    CGFloat newH = startFrame.size.height;

                    if (modifiesRight) newW = startFrame.size.width + dx;
                    if (modifiesLeft) {
                        newW = startFrame.size.width - dx;
                        newX = startFrame.origin.x + dx;
                    }
                    if (modifiesTop) newH = startFrame.size.height + dy;
                    if (modifiesBottom) {
                        newH = startFrame.size.height - dy;
                        newY = startFrame.origin.y + dy;
                    }

                    if (newW < minW) {
                        if (modifiesLeft) newX = startFrame.origin.x + (startFrame.size.width - minW);
                        newW = minW;
                    }
                    if (newH < minH) {
                        if (modifiesBottom) newY = startFrame.origin.y + (startFrame.size.height - minH);
                        newH = minH;
                    }
                    [win setFrame:NSMakeRect(newX, newY, newW, newH) display:YES animate:NO];
                }
            }
            break;
        }
        // ---------------- F-4 自动更新（2026-10-26）----------------
        // 设计取舍：这里**不做任何判定**，只把动作转给 rta::update::begin_check/begin_install。
        // 版本比较/清单解析/sha256/白名单/失败分支全在 src/net/update_check.h（有离线单测）。
        // 这样壳层写错最多"装不上"，不会变成"误报已是最新"或"装了被篡改的包"。
        case HostAction::UpdateCheck: {
#ifdef RL_HAVE_MAC_UPDATE
            rta::update::begin_check(
                ^(const rta::update::NativeProgress& p) {
                    [self emitUpdateProgress:p];
                },
                ^(const rta::update::CheckResult& r) {
                    [self emitUpdateResult:r];
                });
#else
            [self emitToPage:@"update:status:{\"stage\":\"failed\",\"code\":\"unsupported\","
                             "\"message\":\"\u672c\u6784\u5efa\u672a\u542f\u7528\u66f4\u65b0\u6a21\u5757\"}"];
#endif
            break;
        }
        case HostAction::UpdateInstall: {
#ifdef RL_HAVE_MAC_UPDATE
            // 用最近一次 check 的结果作为安装计划（避免安装时被页面塞新的 URL）
            if (!self.lastUpdatePlan.available()) {
                [self emitToPage:@"update:status:{\"stage\":\"failed\",\"code\":\"no-plan\","
                                 "\"message\":\"\u8bf7\u5148\u68c0\u67e5\u66f4\u65b0\"}"];
                break;
            }
            rta::update::begin_install(
                self.lastUpdatePlan,
                ^(const rta::update::NativeProgress& p) { [self emitUpdateProgress:p]; },
                ^(bool ok, NSString* msg) {
                    NSDictionary* d = @{ @"stage": ok ? @"installed" : @"failed",
                                         @"code": ok ? @"ok" : @"install-failed",
                                         @"message": msg ?: @"" };
                    [self emitUpdateJson:d];
                });
#else
            [self emitToPage:@"update:status:{\"stage\":\"failed\",\"code\":\"unsupported\"}"];
#endif
            break;
        }
        // ---------------- 2026-10-26 邮件反馈通道 ----------------
        // 设计取舍（与 F-4 更新同思路）：这里**不做**任何"这内容合不合法"的判断，
        // 全部交给纯逻辑层 rta::feedback（有离线单测）。壳层写错最多"发不出去"，
        // 不会变成"发到错误的人"或"带上任意文件"。
        //
        // 三道硬闸门（缺任何一条都不发信）：
        //   ① 正文清洗后不能为空（用户没写正文 → 拒绝，并明确提示）；
        //   ② 附诊断包时，路径必须过 check_attachment_path（在临时目录内 + .zip）+ 文件系统核验；
        //   ③ 收件人只能是 rta::feedback::kRecipient（这里是唯一取值处，页面无从干预）。
        case HostAction::FeedbackCompose:
        case HostAction::FeedbackDiagOnly: {
#ifdef RL_HAVE_MAC_FEEDBACK
            [self handleFeedbackMessage:hm];
#else
            [self emitToPage:@"feedback:status:{\"stage\":\"failed\",\"code\":\"unsupported\","
                             "\"message\":\"\u672c\u6784\u5efa\u672a\u542f\u7528\u53cd\u9988\u90ae\u4ef6\u6a21\u5757\"}"];
#endif
            break;
        }
        case HostAction::None:
            break;
    }
}

// ---------------- 2026-10-26 邮件反馈通道：宿主侧执行 ----------------
// 回传协议（页面侧 JSON.parse，命名与 update:status:* 对齐）：
//   feedback:status:{"stage":"...","code":"...","message":"..."}
//   stage ∈ rejected（被闸门拦下）/ compose-opened（撰写窗口已开）/ fellback（.eml 兜底）/ failed
#ifdef RL_HAVE_MAC_FEEDBACK
- (void)handleFeedbackMessage:(const rta::platform::HostMessage &)hm {
    namespace fb = rta::feedback;

    // ---- ① 正文 ----
    std::string raw_body = hm.arg;
    if (hm.action == rta::platform::HostAction::FeedbackDiagOnly) {
        // 「只上传诊断不写反馈」：给一段固定说明，别让收件人收到一封空邮件。
        raw_body = "（用户选择只发送诊断包，未填写反馈正文。）";
    }
    const fb::BodyResult body = fb::sanitize_body(raw_body);
    if (body.empty_after_clean) {
        [self emitFeedbackJson:@{ @"stage": @"rejected",
                                  @"code": @"empty-body",
                                  @"message": @"请先写下反馈内容再发送（空邮件不发送）" }];
        return;
    }

    // ---- ② 诊断包（可选）----
    std::string diag_data, diag_name, diag_err, diag_norm;
    std::vector<std::string> attach_paths;
    if (hm.attach_diag) {
        // 「必须带诊断包」的两条命令（DiagOnly / compose+zip）在这里就把路径卡死
        if (hm.diag_path.empty()) {
            [self emitFeedbackJson:@{ @"stage": @"rejected",
                                      @"code": @"no-diag-path",
                                      @"message": @"缺少诊断包路径：请先在页面生成诊断包"
                                                  "（诊断包会存到临时目录再交给邮件）" }];
            return;
        }
        if (!fb::load_diagnostic(hm.diag_path, diag_data, diag_name, diag_err, &diag_norm)) {
            // 诊断包不可用是**可降级**的：告诉用户"附件没带上"，让他选择是否只发正文。
            [self emitFeedbackJson:@{ @"stage": @"rejected",
                                      @"code": @"bad-diag",
                                      @"message": @"诊断包不可用，已取消发送",
                                      @"detail": [NSString stringWithUTF8String:diag_err.c_str()] ?: @"" }];
            return;
        }
        // 用 **load_diagnostic 校验通过的规范化路径**（不是页面原值）：
        // 页面给的是 "…/sub/../diag.zip" 这种也认，但交给邮件客户端的一定是消过 "../" 的形式。
        attach_paths.push_back(diag_norm);
    }

    // ---- ③ 主题：版本 + 系统信息（页面无法干预格式）----
    const std::string subject = fb::build_subject(fb::system_meta());

    // ---- ④ 组装提示文字（正文末尾追加截断/清洗说明，让用户知道发生了什么）----
    std::string body_final = body.text;
    std::string warning;
    if (body.truncated) {
        warning += "\n\n—— 反馈内容超过 " + std::to_string(fb::kMaxBodyChars) +
                   " 字，已截断（省略 " + std::to_string(body.dropped_chars) + " 字）。";
    }
    if (!warning.empty()) body_final += warning;

    // ---- ⑤ 交给原生层（只打开撰写窗口，绝不由代码发送）----
    const fb::ComposeResult cr = fb::open_compose_window(subject, body_final, attach_paths);

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    switch (cr.outcome) {
        case fb::ComposeOutcome::Opened:        d[@"stage"] = @"compose-opened"; break;
        case fb::ComposeOutcome::FellBackToEml: d[@"stage"] = @"fellback";       break;
        case fb::ComposeOutcome::Failed:        d[@"stage"] = @"failed";         break;
    }
    d[@"code"] = @"ok";
    d[@"message"] = [NSString stringWithUTF8String:cr.detail.c_str()] ?: @"";
    d[@"to"] = [NSString stringWithUTF8String:fb::kRecipient];
    d[@"truncated"] = @(body.truncated);
    d[@"droppedChars"] = @((double)body.dropped_chars);
    d[@"controlChars"] = @((double)body.control_chars);
    d[@"attachment"] = hm.attach_diag ? [NSString stringWithUTF8String:diag_name.c_str()] : @"";
    d[@"recipientPreset"] = @(cr.recipient_preset);
    d[@"subjectPreset"] = @(cr.subject_preset);
    if (!cr.eml_path.empty()) d[@"emlPath"] = [NSString stringWithUTF8String:cr.eml_path.c_str()];
    [self emitFeedbackJson:d];
}

- (void)emitFeedbackJson:(NSDictionary *)dict {
    if (!dict) return;
    NSData *d = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (!d) return;
    NSString *json = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!json) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self emitToPage:[@"feedback:status:" stringByAppendingString:json]];
    });
}
#endif

// 宿主 → UI：max/normal 在窗口尺寸变化时发（PLATFORM.md §10.2）
//
// 2026-10-25（安全）：原来用 @"...__emit('%@')" 直接插字符串。这对 "max"/"normal" 没问题，
// 但本轮新增的 pickdir:ok:<路径> 带**用户可控的绝对路径** —— 路径里只要有一个单引号
// （例如 /Users/o'brien/Music）就会破坏 JS 字面量、轻则消息丢失、重则执行注入代码。
// 改为走 JSON 序列化（NSJSONSerialization 会正确转义引号/反斜杠/控制字符），
// 页面侧 JSON.parse 回来。参数用数组包一层，保证任意字符串都安全。
- (void)emitToPage:(NSString *)s {
    NSArray *arr = @[ s ?: @"" ];
    NSData *d = [NSJSONSerialization dataWithJSONObject:arr options:0 error:nil];
    if (!d) return;
    NSString *json = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!json) return;
    // json 形如 ["..."]；取出第一个元素作为字符串参数
    NSString *js = [NSString stringWithFormat:
        @"(function(){try{var a=%@;if(window.chrome.webview&&window.chrome.webview.__emit)window.chrome.webview.__emit(a[0]);}catch(e){}})();",
        json];
    [self.web evaluateJavaScript:js completionHandler:nil];
}

// ---------------- F-4：更新进度/结果 → 页面 ----------------
// 统一出口：所有回传都序列化成 JSON，再走与 emitToPage 相同的安全通道
// （NSString 由 NSJSONSerialization 产出，引号/反斜杠/控制字符都已转义）。
- (void)emitUpdateJson:(NSDictionary *)dict {
    if (!dict) return;
    NSData *d = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (!d) return;
    NSString *json = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!json) return;
    [self emitToPage:[@"update:status:" stringByAppendingString:json]];
}

- (void)emitUpdateProgress:(const rta::update::NativeProgress &)p {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"stage"] = [NSString stringWithUTF8String:p.stage.c_str()] ?: @"";
    d[@"message"] = [NSString stringWithUTF8String:p.detail.c_str()] ?: @"";
    if (p.percent >= 0) d[@"percent"] = @(p.percent);
    // 进度是高频事件：直接下发，不额外做别的处理
    dispatch_async(dispatch_get_main_queue(), ^{
        [self emitUpdateJson:d];
    });
}

- (void)emitUpdateResult:(const rta::update::CheckResult &)r {
    // 记下安装计划（只有 UpdateAvailable 才会被 begin_install 接受）
    self.lastUpdatePlan = r;
    if(!r.up_to_date() && !r.available()) rta::diag::diag_emit("update.failed",rta::diag::Stage::Update,
        rta::diag::find_code("update.check_failed"),{{"decision",r.code()},{"reason",r.error},{"http_status",std::to_string(r.status),rta::diag::KvKind::Num}});

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"stage"]  = r.up_to_date() ? @"up-to-date" : (r.available() ? @"available" : @"failed");
    d[@"code"]   = [NSString stringWithUTF8String:r.code()] ?: @"unknown";
    d[@"message"] = [NSString stringWithUTF8String:r.error.c_str()] ?: @"";
    if (!r.remoteVersion.empty())
        d[@"version"] = [NSString stringWithUTF8String:r.remoteVersion.c_str()];
    if (!r.notes.empty())
        d[@"notes"] = [NSString stringWithUTF8String:r.notes.c_str()];
    if (r.status > 0) d[@"status"] = @(r.status);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self emitUpdateJson:d];
    });
}

- (void)windowDidResize:(NSNotification *)n {
    (void)n;
    if (self.zoomed != (self.window.frame.size.width >= self.window.screen.visibleFrame.size.width - 1 &&
                        self.window.frame.size.height >= self.window.screen.visibleFrame.size.height - 1)) {
        self.zoomed = !self.zoomed;
        [self emitToPage:self.zoomed ? @"max" : @"normal"];
    }
}

// ---------------- 生命周期 ----------------
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a {
    (void)a; return YES;                                      // 关窗 = 退出
}

// 关窗路径计时（2026-10-28）：实测点红叉 0.42s vs ⌘Q 0.15s，差 0.27s 发生在
// applicationWillTerminate **之前**（窗口关闭 → AppKit 终止流程）。这里打点确认卡在哪一段。
- (void)windowWillClose:(NSNotification *)n {
    (void)n;
    fprintf(stderr, "RLPlayer: 窗口开始关闭 t=%lld\n",
            (long long)([[NSDate date] timeIntervalSince1970] * 1000));
}
- (void)windowDidClose:(NSNotification *)n {
    (void)n;
    fprintf(stderr, "RLPlayer: 窗口已关闭 t=%lld\n",
            (long long)([[NSDate date] timeIntervalSince1970] * 1000));
}
- (BOOL)windowShouldClose:(NSWindow *)sender {
    (void)sender;
    fprintf(stderr, "RLPlayer: 窗口请求关闭 t=%lld\n",
            (long long)([[NSDate date] timeIntervalSince1970] * 1000));
    // ⚠️ 2026-10-28 严重回归教训（beta3 用户实测：「点完叉，音乐还在播」「卡死」）：
    //   这里曾经调 [sender orderOut:nil] 想让窗口"立刻消失"。结果窗口被 orderOut 之后，
    //   AppKit 不再把它当作「最后一个窗口已关闭」⟹ applicationShouldTerminateAfterLastWindowClosed
    //   **永远不触发** ⟹ 进程不终止 ⟹ 音乐继续播、程序挂在那里 = 用户看到的卡死。
    //   而且当初加它的理由是错的：实测加了 orderOut 窗口消失仍是 0.45~0.50s，一无收益。
    //   ⟹ 绝不在这里动窗口生命周期；要「点叉即静音」就在下面直接停播放。

    // 点叉的**第一时间**停播放（而不是等 applicationWillTerminate 里的 stop_embedded）。
    // 走公开的 dispatch 入口调 /api/stop：它内部是 ps.stopJoin()，协作停播放线程并关流，
    // 不会像 orderOut 那样破坏 AppKit 的关窗/终止判定。失败也不影响后续正常收尾。
    {
        rta::net::HttpRequest stopReq;
        stopReq.method = "POST";
        stopReq.path = "/api/stop";
        std::string stopCt;
        (void)rlapp::dispatch(stopReq, stopCt);
        fprintf(stderr, "RLPlayer: 关窗时已停播放 t=%lld\n",
                (long long)([[NSDate date] timeIntervalSince1970] * 1000));
    }
    // 尽早置退出标志：拒绝新工作、取消在途网络（真正的 join 仍在 applicationWillTerminate）
    rlapp::request_shutdown();

    // 视觉上**立刻**消失（用户待办：「点击红叉之后应该立即关闭程序的全部功能」）。
    // ⚠️ 这里绝不能 orderOut/close：窗口一旦被移出窗口列表，AppKit 就不再认为
    //    「最后一个窗口已关闭」，applicationShouldTerminateAfterLastWindowClosed 不触发，
    //    进程不退出、音乐继续播（beta3 实测事故）。
    // alpha=0 只是让窗口不可见，窗口本身仍在，关窗/终止判定完全照常。
    sender.alphaValue = 0.0;
    return YES;      // 让 AppKit 走正常的 关窗 → 终止 流程
}

- (void)applicationWillTerminate:(NSNotification *)n {
    (void)n;
    // 分段计时（2026-10-28 用户实测「关闭就会卡一下」）：每段都打点，日志里能看出卡在哪一步。
    // 之前整段只有一句结论，无法区分是 timer、排空 worker、还是 stop_embedded 慢。
    const auto tQuit0 = std::chrono::steady_clock::now();
    auto msSince = [&tQuit0]() {
        return (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - tQuit0).count();
    };
    fprintf(stderr, "RLPlayer: 退出开始 t=0ms\n");
    [self.exitPollTimer invalidate];
    self.exitPollTimer = nil;
    fprintf(stderr, "RLPlayer: 退出 timer 已停 t=%lldms\n", msSince());

    // 退出契约（rlapp_core.h）：
    // 1. 优先提前通知核心退出（置 g_shutdown 并拒绝新工作，不 join），加速在途任务取消
    rlapp::request_shutdown();
    fprintf(stderr, "RLPlayer: 退出已通知核心 t=%lldms（在途 worker=%d）\n",
            msSince(), [self.schemeHandler activeWorkersCount]);

    // 2. 停新请求来源，并等待**已派发**的 scheme worker 全部退出核心（_activeWorkers == 0）
    // applicationWillTerminate 是通知，不是可否退出的询问；return 并不能阻止 exit。
    // 诊断超时后继续等业务排空，绝不带着还访问核心的 worker 进入静态析构。
    // worker 排空同样给硬上限（2026-10-28 用户实测「退出太慢、卡死」）：
    // 原来这里是**无限循环**等 _activeWorkers 归零。只要有一个 worker 卡在不可取消的
    // 阻塞调用里（出站连接 / ffmpeg / 文件系统），进程就永远退不出去 = 用户看到的卡死。
    // 现在：最多等 kWorkerDrainHardCapMs，超时走 _exit(0) —— 不跑静态析构，
    // 因而不存在「返回后析构、worker 还在摸核心」的 UAF；也不是 force-kill（进程自己退）。
    static const long long kWorkerDrainHardCapMs = 3000;
    if (![self.schemeHandler waitForInFlightTasksWithTimeout:1.0]) {
        while (![self.schemeHandler waitForInFlightTasksWithTimeout:0.5]) {
            const long long waited = msSince();
            fprintf(stderr, "RLPlayer: 退出仍在等待 %d 个业务 worker 安全结束 t=%lldms\n",
                    [self.schemeHandler activeWorkersCount], waited);
            if (waited >= kWorkerDrainHardCapMs) {
                fprintf(stderr,
                        "RLPlayer: 退出达到硬上限 %lldms，仍有 %d 个 worker 未结束 ⟹ _exit(0) 直接结束"
                        "（不跑静态析构）\n",
                        kWorkerDrainHardCapMs, [self.schemeHandler activeWorkersCount]);
                fflush(stdout);
                fflush(stderr);
                std::_Exit(0);
            }
        }
    }
    fprintf(stderr, "RLPlayer: 退出 worker 已排空 t=%lldms\n", msSince());

    // 3. 协作式收尾：此时保证无任何 scheme worker 在 handle()/核心内运行
    rlapp::stop_embedded();
    fprintf(stderr, "RLPlayer: 退出收尾完成 t=%lldms\n", msSince());

    // ⚠️ 2026-10-28 实测教训：不要在这里手动拆 WKWebView / 关窗口。
    //   加过一版 [web stopLoading] + removeScriptMessageHandler + [window close] + 置 nil，
    //   真机实测 **Segmentation fault: 11**（且"UI 已拆除"那行都没打出来，死在拆除途中）。
    //   原因：applicationWillTerminate 阶段 WebKit 已进入自己的销毁流程，此时再改它的
    //   contentController / 窗口生命周期，会与 WebContent 进程的异步回调竞争。
    //   ⟹ 交给 AppKit/WebKit 自己收尾；本函数只负责「核心状态安全排空」。
}

@end

#ifndef RL_TEST_RUNNER
int main(int argc, const char *argv[]) {
    (void)argc; (void)argv;
    // 2026-10-28（用户实测闪退根因）：忽略 SIGPIPE。壳在 core_init_common() 之前就会往
    // stderr 写诊断；.app 由 launchd 启动、stdout/stderr 无终端承接，读端一关，写即触发
    // SIGPIPE，默认动作直接终止进程 —— 现场证据：launchd `exited due to SIGPIPE`、
    // runningboardd `(2, 13, 13)`，且没有 .ips、没有 SHUTDOWN 日志。
    // 在进程第一行生效，覆盖核心初始化之前的写。
    ::signal(SIGPIPE, SIG_IGN);
    @autoreleasepool {
        HostAppDelegate *del = [[HostAppDelegate alloc] init];
        NSApplication *app = [NSApplication sharedApplication];
        app.delegate = del;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
#endif
