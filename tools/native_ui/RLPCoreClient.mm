// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPCoreClient.h"

#include "rlapp_core.h"
#include "net/webui.h"

@implementation RLPCoreClient {
    dispatch_queue_t _ioQueue;
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

- (void)runAsync:(BOOL)get path:(NSString *)path body:(nullable NSString *)body completion:(nullable RLPJSONCompletion)completion {
    dispatch_async(_ioQueue, ^{
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

@end
