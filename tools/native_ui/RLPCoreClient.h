// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPCoreClient.h — 原生 UI ↔ C++ 核心的唯一桥（ObjC++）
//
// 设计约束（1.1.7.1 起）：
//   * UI 层不复制业务真相：曲库/播放/队列/设置全部在 rlapp_core（tools/rtaweb.cpp 的
//     rlapp::dispatch）。本类只做三件事：把 /api 请求转成 C++ 调用、把 JSON 变成
//     Foundation 对象、把阻塞调用挪到后台队列。
//   * 线程契约：dispatch 允许任意线程并发（见 rlapp_core.h）；UI 侧只从主线程发起，
//     回调统一回主线程，避免 NSView 跨线程。
//   * 不监听端口、不起子进程：直接调进程内 dispatch（与 web 版同一条路径）。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^RLPJSONCompletion)(NSDictionary * _Nullable json);
typedef void (^RLPDataCompletion)(NSData * _Nullable data);

@interface RLPCoreClient : NSObject

+ (instancetype)shared;

/// 是否已经 startEmbedded（selftest/离线渲染时需要判断，避免误启动核心）。
@property (nonatomic, readonly) BOOL started;

/// 主线程调用一次：初始化曲库/配置/播放核心（不监听端口、不开浏览器）。
- (BOOL)startEmbedded;

/// 主线程调用：协作式收尾（先 request_shutdown 再 stop_embedded）。幂等。
- (void)shutdown;

/// 同步请求（任意线程）。返回解析后的 JSON；失败返回 nil。
/// path 例："/api/lib/albums"；body 是表单串（GET 传 nil）。
- (nullable NSDictionary *)jsonWithMethod:(NSString *)method
                                     path:(NSString *)path
                                     body:(nullable NSString *)body;

/// 同步请求原始字节（封面图）。失败返回 nil；contentType 可空。
- (nullable NSData *)dataWithMethod:(NSString *)method
                               path:(NSString *)path
                               body:(nullable NSString *)body
                        contentType:(NSString * _Nullable * _Nullable)contentType;

/// 异步 GET/POST：在后台队列跑，完成后回主线程调用 completion。
- (void)getJSON:(NSString *)path completion:(nullable RLPJSONCompletion)completion;
- (void)postJSON:(NSString *)path body:(nullable NSString *)body completion:(nullable RLPJSONCompletion)completion;

/// 异步取原始字节（封面）。completion 在主线程。
- (void)getData:(NSString *)path completion:(nullable RLPDataCompletion)completion;

@end

NS_ASSUME_NONNULL_END
