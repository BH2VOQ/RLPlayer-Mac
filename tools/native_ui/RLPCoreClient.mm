// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPCoreClient.h"

#include "rlapp_core.h"
#include <atomic>
#include "net/webui.h"

@implementation RLPCoreClient {
    dispatch_queue_t _ioQueue;
    dispatch_queue_t _writeQueue;
    dispatch_queue_t _slowQueue;
    // 2026-11-17（并发审计已证实）：shutdown 只 stop_embedded 就返回，后台队列里
    // 在途的 rlapp::dispatch 会在 C++ 全局单例析构后继续跑 ⟹ 退出时崩溃。
    // 关闸后先排空快队列，再停核心。
    std::atomic<bool> _shuttingDown;
    BOOL _startedStorage;
}

@synthesize started = _startedStorage;

+ (instancetype)shared {
    static RLPCoreClient *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[RLPCoreClient alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _ioQueue = dispatch_queue_create("rlplayer.native.core", DISPATCH_QUEUE_CONCURRENT);
        _writeQueue = dispatch_queue_create("rlplayer.native.core.write", DISPATCH_QUEUE_SERIAL);
        // 2026-11-17（后端审计已证实）：AI 歌词/实体整理这类端点是**同步阻塞**的后端调用，
        // 若与播控写共用 _writeQueue，LLM 卡住时暂停/停止/切歌/音量全会无限期排队。
        // 单独一条串行队列承接它们：长任务只互相排队，不拖住实时播控。
        _slowQueue = dispatch_queue_create("rlplayer.native.core.slow", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)started { return _startedStorage; }

- (BOOL)startEmbedded {
    if (_startedStorage) return YES;
    const BOOL ok = rlapp::start_embedded() ? YES : NO;
    _startedStorage = ok;
    return ok;
}

- (void)shutdown {
    if (!_startedStorage) return;
    _shuttingDown.store(true);
    // 排空短任务队列：barrier 保证排在此前的任务都执行完，且之后不再插入读任务。
    dispatch_barrier_sync(_ioQueue, ^{});
    dispatch_sync(_writeQueue, ^{});
    // 慢队列可能正卡在不可取消的网络调用：不阻塞退出（那会把「关不掉」变成新 bug），
    // 但已关闸，后续不会再有新任务进 dispatch。
    rlapp::request_shutdown();
    rlapp::stop_embedded();
    _startedStorage = NO;
}

- (nullable NSDictionary *)jsonWithMethod:(NSString *)method
                                     path:(NSString *)path
                                     body:(nullable NSString *)body {
    const std::string m = method.UTF8String ?: "GET";
    const std::string p = path.UTF8String ?: "";
    const std::string b = body.UTF8String ?: "";
    rta::net::HttpRequest req;
    req.method = m;
    req.path = p;
    req.body = b;
    std::string ct;
    const std::string out = rlapp::dispatch(req, ct);
    if (out.empty()) return nil;
    NSData *data = [NSData dataWithBytes:out.data() length:out.size()];
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? (NSDictionary *)obj : nil;
}

- (nullable NSData *)dataWithMethod:(NSString *)method
                               path:(NSString *)path
                               body:(nullable NSString *)body
                        contentType:(NSString * _Nullable * _Nullable)contentType {
    const std::string m = method.UTF8String ?: "GET";
    const std::string p = path.UTF8String ?: "";
    const std::string b = body.UTF8String ?: "";
    rta::net::HttpRequest req;
    req.method = m;
    req.path = p;
    req.body = b;
    std::string ct;
    const std::string out = rlapp::dispatch(req, ct);
    if (contentType) *contentType = [NSString stringWithUTF8String:ct.c_str()];
    if (out.empty()) return nil;
    return [NSData dataWithBytes:out.data() length:out.size()];
}

- (void)getJSON:(NSString *)path completion:(nullable RLPJSONCompletion)completion {
    [self runAsync:YES path:path body:nil completion:completion];
}

- (void)postJSON:(NSString *)path body:(nullable NSString *)body completion:(nullable RLPJSONCompletion)completion {
    [self runAsync:NO path:path body:body completion:completion];
}

+ (BOOL)isSlowWritePath:(NSString *)path {
    if (![path isKindOfClass:[NSString class]]) return NO;
    return [path hasPrefix:@"/api/lyrics/ai"] ||
           [path hasPrefix:@"/api/entity/knowledge"] ||
           [path hasPrefix:@"/api/entity/summary"];
}

- (void)runAsync:(BOOL)get path:(NSString *)path body:(nullable NSString *)body completion:(nullable RLPJSONCompletion)completion {
    if (_shuttingDown.load()) return;   // 关闸后拒绝新任务（见 shutdown 注释）
    dispatch_queue_t q = get ? _ioQueue
                             : ([[self class] isSlowWritePath:path] ? _slowQueue : _writeQueue);
    dispatch_async(q, ^{
        NSDictionary *j = [self jsonWithMethod:(get ? @"GET" : @"POST") path:path body:body];
        if (!completion) return;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(j); });
    });
}

- (void)getData:(NSString *)path completion:(nullable RLPDataCompletion)completion {
    dispatch_async(_ioQueue, ^{
        NSData *d = [self dataWithMethod:@"GET" path:path body:nil contentType:nil];
        if (!completion) return;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(d); });
    });
}

- (void)postData:(NSString *)path
            body:(NSData *)body
     contentType:(NSString *)contentType
      completion:(nullable RLPJSONCompletion)completion {
    // HttpRequest.body 是 std::string，但这里塞的是**原始字节**（图片）。
    // std::string 能承载任意字节（含 \0），dispatch 侧按字节取用，不做 UTF-8 解释。
    const std::string p = path.UTF8String ?: "";
    const std::string bytes((const char *)body.bytes, (size_t)body.length);
    dispatch_async(_writeQueue, ^{
        rta::net::HttpRequest req;
        req.method = "POST";
        req.path = p;
        req.body = bytes;
        std::string ct;
        const std::string out = rlapp::dispatch(req, ct);
        NSDictionary *j = nil;
        if (!out.empty()) {
            NSData *d = [NSData dataWithBytes:out.data() length:out.size()];
            id parsed = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            if ([parsed isKindOfClass:[NSDictionary class]]) j = parsed;
        }
        (void)contentType;   // 端点按路径判定，不依赖请求头；保留参数以便将来扩展
        if (!completion) return;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(j); });
    });
}

@end
