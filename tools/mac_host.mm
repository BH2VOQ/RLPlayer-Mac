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
#include <cstdlib>
#include <cstring>
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
void stop_embedded();
int cli_main(int argc, char** argv);
}
#endif

#if __has_include("platform/host_msg.h")
#include "platform/host_msg.h"
#else
namespace rta::platform {
enum class HostAction { None, Minimize, Maximize, Close, Drag, Theme, OpenUrl, Resize };
struct HostMessage {
    HostAction action = HostAction::None;
    std::string arg;
    bool allowed = true;
    std::string reason;
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
    BOOL _isStopping;
}
- (instancetype)init;
- (BOOL)waitForInFlightTasksWithTimeout:(NSTimeInterval)timeout;
@end

@implementation RLURLSchemeHandler

- (instancetype)init {
    self = [super init];
    if (self) {
        _tasks = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality
                                       valueOptions:NSPointerFunctionsStrongMemory];
        _isStopping = NO;
    }
    return self;
}

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id <WKURLSchemeTask>)urlSchemeTask {
    (void)webView;
    RLSchemeTaskContext *ctx = [[RLSchemeTaskContext alloc] init];
    ctx.task = urlSchemeTask;
    ctx.stopped = NO;

    {
        std::lock_guard<std::mutex> lock(_mutex);
        if (_isStopping) {
            NSError *err = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
            [urlSchemeTask didFailWithError:err];
            return;
        }
        [_tasks setObject:ctx forKey:urlSchemeTask];
    }

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
        if (contentType.empty()) {
            contentType = "application/octet-stream";
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
    return _cv.wait_until(lock, deadline, [self] {
        return [self->_tasks count] == 0;
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
@interface HostAppDelegate : NSObject <NSApplicationDelegate, WKScriptMessageHandler,
                                       WKNavigationDelegate, NSWindowDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, strong) RLURLSchemeHandler *schemeHandler;
@property (nonatomic, strong) RLTransportHandler *transportHandler;
@property (nonatomic, strong) NSTimer *exitPollTimer;
@property (nonatomic) NSRect savedFrame;       // max 前的窗口 frame（还原用）
@property (nonatomic) bool zoomed;
@end

@implementation HostAppDelegate

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
    self.window.backgroundColor = [NSColor colorWithCalibratedRed:0.047 green:0.055 blue:0.075 alpha:1.0];
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
    self.web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.window setContentView:self.web];

    // 主页面加载自定义 scheme URL
    [self.web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"rlplayer://app/"]]];
    [self.window makeKeyAndOrderFront:nil];

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
    // 最小 App 菜单：保证 Cmd+Q / 关窗语义存在
    NSMenu *bar = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"退出 RLPlayer" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [bar addItem:appItem];
    [NSApp setMainMenu:bar];
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
        case HostAction::None:
            break;
    }
}

// 宿主 → UI：max/normal 在窗口尺寸变化时发（PLATFORM.md §10.2）
- (void)emitToPage:(NSString *)s {
    NSString *js = [NSString stringWithFormat:@"window.chrome.webview && window.chrome.webview.__emit('%@');", s];
    [self.web evaluateJavaScript:js completionHandler:nil];
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

- (void)applicationWillTerminate:(NSNotification *)n {
    (void)n;
    [self.exitPollTimer invalidate];
    self.exitPollTimer = nil;
    // 退出契约（rlapp_core.h）：先停新请求来源，再等**已派发**的 dispatch 全部返回，
    // 最后才允许销毁核心单例。这里不能给“在途请求”设 2 秒上限后就拆核心：
    // 资料整理/库扫描请求可能仍在 handle() 内访问 MetaStore/Library，提前 stop 会悬垂访问。
    // waitForInFlightTasksWithTimeout 会以 _isStopping 拒绝新 scheme task；已有任务则全部
    // 等到底（每个 handler 本身有网络超时，不会无限等待），满足契约后再收尾。
    if (![self.schemeHandler waitForInFlightTasksWithTimeout:30.0]) {
        fprintf(stderr, "RLPlayer: 退出时仍有 scheme 任务未完成（已等待 30s，放弃等待以避免卡死）\n");
    }
    rlapp::stop_embedded();                                   // 停内置核心（协作式）
}

@end

#ifndef RL_TEST_RUNNER
int main(int argc, const char *argv[]) {
    (void)argc; (void)argv;
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
