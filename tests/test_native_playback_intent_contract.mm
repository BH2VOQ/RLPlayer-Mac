// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_playback_intent_contract.mm — 跨入口播放意图竞争与歌单快照契约测试（离线真实组件 mock）
//
// 验证：
//   I1 RLPPlayWholeListFrom 基线语义：不被取代时，mode=2 先切 mode=1 → /api/queue/set → /api/play
//   I2 RLPPlayWholeListFrom 等待 GET /api/playmode 时被 RLPPlayAlbum 取代：
//      不得再发 POST /api/playmode?mode=1、/api/queue/set 或 /api/play 抢播
//   I3 RLPPlayWholeListFrom 等待 GET /api/playmode 时被 RLPPlayPath 取代：
//      不得再发 POST /api/queue/set 或 /api/play 抢播
//   I4 RLPPlayWholeListFrom 等待 POST /api/queue/set 时被 RLPPlayPath 取代：
//      不得再发 POST /api/play 抢播
//   P1 RLPPlaylistsViewController 基线语义：playFromIndex 正常完成 /api/sq/play 后按 CUE cs/ce 起播
//   P2 RLPPlaylistsViewController loadQueueAndPlayAt 等待 POST /api/sq/play 期间切换歌单（selectedName 与 items 均变）：
//      回调不得用新歌单的 items 或 selectedName 播放错歌
//   P3 RLPPlaylistsViewController loadQueueAndPlayAt 等待 POST /api/sq/play 期间同歌单重载（items 改变）：
//      回调不得用已改变的新 items[index] 播放错歌
//   P4 RLPPlaylistsViewController playFromIndex 等待 GET /api/playmode 期间切换歌单（selectedName 改变）：
//      回调不得用新 selectedName 发 /api/sq/play 或 /api/play
//   P5 RLPPlaylistsViewController playFromIndex/loadQueueAndPlayAt 被 RLPPlayAlbum 取代：
//      不得在 /api/sq/play 返回后再发 /api/play 抢播
//
// 纪律：完全离线，不启动真实播放核心（rlapp 桩 + swizzle +[RLPCoreClient shared]）、
//       不打开音频设备（null/-120）、不触碰 8899、不创建可见窗口。

#import <AppKit/AppKit.h>
#import <objc/runtime.h>

#import "RLPCoreClient.h"
#import "RLPPlaylistsViewController.h"
#import "RLPSupport.h"
#import "RLPTheme.h"
#import "rlapp_core.h"

#include <cstdio>
#include <string>

@interface RLPPlaylistsViewController (IntentContractTestAccess)
- (void)openPlaylist:(NSString *)name;
- (void)playFromIndex:(NSInteger)index;
- (void)loadQueueAndPlayAt:(NSInteger)index;
- (void)loadItems;
@end

#pragma mark - 离线 rlapp 链接桩（无需链接 rlapp_core）

namespace rlapp {
bool start_embedded() { return false; }
void request_shutdown() {}
void stop_embedded() {}
bool exit_requested() { return false; }
std::string diag_json(std::size_t) { return "{}"; }
int max_concurrent_dispatches() { return 0; }
long long dispatch_count() { return 0; }
void reset_dispatch_probe() {}
int cli_main(int, char**) { return 0; }
std::string dispatch(const rta::net::HttpRequest&, std::string& contentType) {
    contentType = "application/json";
    return "{\"ok\":true}";
}
} // namespace rlapp

#pragma mark - Mock 客户端（记录请求并支持精确扣留/放行回调）

@interface RLPIntentReq : NSObject
@property (nonatomic, copy) NSString *method;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *body;
@end
@implementation RLPIntentReq
@end

@interface RLPIntentSpy : NSObject
@property (nonatomic, strong) NSMutableArray<RLPIntentReq *> *requests;
@property (nonatomic, assign) NSInteger playmode;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *sqInfoByName;
@property (nonatomic, copy) NSArray<NSDictionary *> *sqListQueues;

@property (nonatomic, assign) BOOL holdPlaymodeGet;
@property (nonatomic, strong) NSMutableArray<RLPJSONCompletion> *heldPlaymodeGets;

@property (nonatomic, assign) BOOL holdPlaymodePost;
@property (nonatomic, strong) NSMutableArray<RLPJSONCompletion> *heldPlaymodePosts;

@property (nonatomic, assign) BOOL holdQueueSetPost;
@property (nonatomic, strong) NSMutableArray<RLPJSONCompletion> *heldQueueSetPosts;

@property (nonatomic, assign) BOOL holdSqPlayPost;
@property (nonatomic, strong) NSMutableArray<RLPJSONCompletion> *heldSqPlayPosts;
@end

@implementation RLPIntentSpy

- (instancetype)init {
    if ((self = [super init])) {
        _requests = [NSMutableArray array];
        _sqInfoByName = [NSMutableDictionary dictionary];
        _sqListQueues = @[];
        _heldPlaymodeGets = [NSMutableArray array];
        _heldPlaymodePosts = [NSMutableArray array];
        _heldQueueSetPosts = [NSMutableArray array];
        _heldSqPlayPosts = [NSMutableArray array];
    }
    return self;
}

- (void)reset {
    [self.requests removeAllObjects];
    self.playmode = 0;
    [self.sqInfoByName removeAllObjects];
    self.sqListQueues = @[];
    self.holdPlaymodeGet = NO;
    [self.heldPlaymodeGets removeAllObjects];
    self.holdPlaymodePost = NO;
    [self.heldPlaymodePosts removeAllObjects];
    self.holdQueueSetPost = NO;
    [self.heldQueueSetPosts removeAllObjects];
    self.holdSqPlayPost = NO;
    [self.heldSqPlayPosts removeAllObjects];
}

- (void)clearRequests {
    [self.requests removeAllObjects];
}

- (BOOL)started { return YES; }
- (BOOL)startEmbedded { return NO; }
- (void)shutdown {}

- (id)jsonWithMethod:(NSString *)method path:(NSString *)path body:(NSString *)body {
    (void)method; (void)path; (void)body;
    return nil;
}

- (NSData *)dataWithMethod:(NSString *)method path:(NSString *)path body:(NSString *)body
               contentType:(NSString **)contentType {
    (void)method; (void)path; (void)body; (void)contentType;
    return nil;
}

- (void)recordMethod:(NSString *)method path:(NSString *)path body:(NSString *)body {
    RLPIntentReq *r = [[RLPIntentReq alloc] init];
    r.method = method ?: @"";
    r.path = path ?: @"";
    r.body = body ?: @"";
    [self.requests addObject:r];
}

- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    [self recordMethod:@"GET" path:path body:@""];
    if (!done) return;
    if (self.holdPlaymodeGet && [path hasPrefix:@"/api/playmode"]) {
        [self.heldPlaymodeGets addObject:[done copy]];
        return;
    }
    NSDictionary *json = [self fixtureForGetPath:path ?: @""];
    dispatch_async(dispatch_get_main_queue(), ^{ done(json); });
}

- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    [self recordMethod:@"POST" path:path body:body];
    if (self.holdPlaymodePost && [path hasPrefix:@"/api/playmode"]) {
        if (done) [self.heldPlaymodePosts addObject:[done copy]];
        return;
    }
    if (self.holdQueueSetPost && [path isEqualToString:@"/api/queue/set"]) {
        if (done) [self.heldQueueSetPosts addObject:[done copy]];
        return;
    }
    if (self.holdSqPlayPost && [path hasPrefix:@"/api/sq/play"]) {
        if (done) [self.heldSqPlayPosts addObject:[done copy]];
        return;
    }
    if ([path isEqualToString:@"/api/playmode?mode=1"]) {
        self.playmode = 1;
    }
    if (done) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(@{ @"ok": @YES }); });
    }
}

- (void)getData:(NSString *)path completion:(RLPDataCompletion)done {
    (void)path;
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(nil); });
}

- (void)postData:(NSString *)path body:(NSData *)body contentType:(NSString *)contentType
       completion:(RLPJSONCompletion)done {
    (void)body; (void)contentType;
    [self recordMethod:@"POST" path:path body:@""];
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(@{ @"ok": @YES }); });
}

- (BOOL)releaseFirstHeld:(NSMutableArray<RLPJSONCompletion> *)held withJSON:(NSDictionary *)json {
    if (!held.count) return NO;
    RLPJSONCompletion cb = held.firstObject;
    [held removeObjectAtIndex:0];
    cb(json);
    return YES;
}

- (NSDictionary *)fixtureForGetPath:(NSString *)path {
    if ([path hasPrefix:@"/api/playmode"]) {
        return @{ @"ok": @YES, @"mode": @(self.playmode) };
    }
    if ([path hasPrefix:@"/api/sq/list"]) {
        return @{ @"ok": @YES, @"queues": self.sqListQueues ?: @[] };
    }
    if ([path hasPrefix:@"/api/sq/info?"]) {
        NSString *name = @"";
        NSRange r = [path rangeOfString:@"name="];
        if (r.location != NSNotFound) {
            name = [path substringFromIndex:NSMaxRange(r)];
            NSRange amp = [name rangeOfString:@"&"];
            if (amp.location != NSNotFound) name = [name substringToIndex:amp.location];
            name = [name stringByRemovingPercentEncoding] ?: name;
        }
        NSDictionary *info = self.sqInfoByName[name];
        if (info) return info;
        return @{ @"ok": @YES, @"name": name, @"items": @[] };
    }
    if ([path hasPrefix:@"/api/status"]) {
        return @{ @"ok": @YES, @"playing": @NO, @"paused": @NO, @"current": @"",
                  @"pos": @0, @"dur": @0, @"volDb": @(-120), @"backend": @"null" };
    }
    return @{ @"ok": @YES };
}

@end

static RLPIntentSpy *g_spy;
static id FakeSharedClient(id cls, SEL sel) { (void)cls; (void)sel; return g_spy; }

#pragma mark - 辅助工具

static int g_pass = 0, g_fail = 0;
static void Ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++g_fail; }
}

static void Pump(NSTimeInterval seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

static BOOL WaitUntil(NSTimeInterval timeout, BOOL (^pred)(void)) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([until timeIntervalSinceNow] > 0) {
        if (pred()) return YES;
        Pump(0.01);
    }
    return pred();
}

static BOOL HasPost(RLPIntentSpy *spy, NSString *pathPrefix, NSString * _Nullable bodySubstr) {
    for (RLPIntentReq *r in spy.requests) {
        if (![r.method isEqualToString:@"POST"]) continue;
        if (![r.path hasPrefix:pathPrefix]) continue;
        if (!bodySubstr || [r.body containsString:bodySubstr]) return YES;
    }
    return NO;
}

static NSString *DumpPosts(RLPIntentSpy *spy) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (RLPIntentReq *r in spy.requests) {
        if ([r.method isEqualToString:@"POST"]) {
            [parts addObject:[NSString stringWithFormat:@"%@(%@)", r.path, r.body]];
        }
    }
    return [parts componentsJoinedByString:@", "];
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [RLPTheme setThemeName:@"light"];
        [RLPTheme setUiStyle:@"apple"];

        g_spy = [[RLPIntentSpy alloc] init];
        Method sharedM = class_getClassMethod(RLPCoreClient.class, @selector(shared));
        method_setImplementation(sharedM, (IMP)FakeSharedClient);

        std::printf("== 原生跨入口播放意图与歌单快照契约测试（离线 mock，null/-120）==\n");

        // ====================================================================
        // I1: RLPPlayWholeListFrom 基线语义（未被取代时正常工作）
        // ====================================================================
        [g_spy reset];
        g_spy.playmode = 2;
        RLPPlayWholeListFrom(@[@"/music/base1.flac", @"/music/base2.flac"], 1);
        BOOL i1Done = WaitUntil(1.0, ^BOOL {
            return HasPost(g_spy, @"/api/playmode?mode=1", nil) &&
                   HasPost(g_spy, @"/api/queue/set", @"base1.flac") &&
                   HasPost(g_spy, @"/api/play", @"base2.flac");
        });
        Ck(i1Done, "I1 基线：RLPPlayWholeListFrom 未被取代时 mode=2 切 mode=1 → queue/set → play",
           DumpPosts(g_spy));

        // ====================================================================
        // I2: RLPPlayWholeListFrom 等 GET /api/playmode 时被 RLPPlayAlbum 取代
        // ====================================================================
        [g_spy reset];
        g_spy.holdPlaymodeGet = YES;
        RLPPlayWholeListFrom(@[@"/music/WL_A1.flac", @"/music/WL_A2.flac"], 0);
        BOOL i2Held = WaitUntil(1.0, ^BOOL { return g_spy.heldPlaymodeGets.count == 1; });
        g_spy.holdPlaymodeGet = NO;

        RLPPlayAlbum(@"alb-override", 2);
        BOOL i2AlbumPosted = WaitUntil(1.0, ^BOOL {
            return HasPost(g_spy, @"/api/lib/play", @"k=alb-override&i=2");
        });

        [g_spy clearRequests];
        [g_spy releaseFirstHeld:g_spy.heldPlaymodeGets withJSON:@{ @"ok": @YES, @"mode": @2 }];
        Pump(0.08);
        BOOL i2Hijacked = HasPost(g_spy, @"/api/playmode", nil) ||
                          HasPost(g_spy, @"/api/queue/set", nil) ||
                          HasPost(g_spy, @"/api/play", nil);
        Ck(i2Held && i2AlbumPosted && !i2Hijacked,
           "I2 RLPPlayWholeListFrom 等待 GET /api/playmode 被 RLPPlayAlbum 取代后，不再 POST playmode/queue/set/play 抢播",
           [NSString stringWithFormat:@"held=%d album=%d leaked=[%@]", i2Held, i2AlbumPosted, DumpPosts(g_spy)]);

        // ====================================================================
        // I3: RLPPlayWholeListFrom 等 GET /api/playmode 时被 RLPPlayPath 取代
        // ====================================================================
        [g_spy reset];
        g_spy.holdPlaymodeGet = YES;
        RLPPlayWholeListFrom(@[@"/music/WL_B1.flac", @"/music/WL_B2.flac"], 1);
        BOOL i3Held = WaitUntil(1.0, ^BOOL { return g_spy.heldPlaymodeGets.count == 1; });
        g_spy.holdPlaymodeGet = NO;

        RLPPlayPath(@"/music/single-override.flac");
        BOOL i3PlayPosted = WaitUntil(1.0, ^BOOL {
            return HasPost(g_spy, @"/api/play", @"single-override.flac");
        });

        [g_spy clearRequests];
        [g_spy releaseFirstHeld:g_spy.heldPlaymodeGets withJSON:@{ @"ok": @YES, @"mode": @0 }];
        Pump(0.08);
        BOOL i3Hijacked = HasPost(g_spy, @"/api/queue/set", nil) ||
                          HasPost(g_spy, @"/api/play", nil);
        Ck(i3Held && i3PlayPosted && !i3Hijacked,
           "I3 RLPPlayWholeListFrom 等待 GET /api/playmode 被 RLPPlayPath 取代后，不再 POST queue/set 或 play 抢播",
           [NSString stringWithFormat:@"held=%d play=%d leaked=[%@]", i3Held, i3PlayPosted, DumpPosts(g_spy)]);

        // ====================================================================
        // I4: RLPPlayWholeListFrom 等 POST /api/queue/set 时被 RLPPlayPath 取代
        // ====================================================================
        [g_spy reset];
        g_spy.playmode = 0;
        g_spy.holdQueueSetPost = YES;
        RLPPlayWholeListFrom(@[@"/music/WL_C1.flac", @"/music/WL_C2.flac"], 0);
        BOOL i4Held = WaitUntil(1.0, ^BOOL { return g_spy.heldQueueSetPosts.count == 1; });
        g_spy.holdQueueSetPost = NO;

        RLPPlayPath(@"/music/urgent-track.flac");
        BOOL i4UrgentPosted = WaitUntil(1.0, ^BOOL {
            return HasPost(g_spy, @"/api/play", @"urgent-track.flac");
        });

        [g_spy clearRequests];
        [g_spy releaseFirstHeld:g_spy.heldQueueSetPosts withJSON:@{ @"ok": @YES }];
        Pump(0.08);
        BOOL i4Hijacked = HasPost(g_spy, @"/api/play", @"WL_C1.flac");
        Ck(i4Held && i4UrgentPosted && !i4Hijacked,
           "I4 RLPPlayWholeListFrom 等待 POST /api/queue/set 被 RLPPlayPath 取代后，不再 POST /api/play 抢播",
           [NSString stringWithFormat:@"held=%d urgent=%d leaked=[%@]", i4Held, i4UrgentPosted, DumpPosts(g_spy)]);

        // ====================================================================
        // Part 2: RLPPlaylistsViewController 真实组件测试
        // ====================================================================
        RLPPlaylistsViewController *sqVC = [[RLPPlaylistsViewController alloc] init];
        (void)sqVC.view;

        // P1: 基线语义 —— 正常 loadQueueAndPlayAt 保留 CUE cs/ce 并起播
        [g_spy reset];
        g_spy.playmode = 0;
        g_spy.sqInfoByName[@"ListA"] = @{
            @"ok": @YES,
            @"name": @"ListA",
            @"items": @[
                @{ @"file": @"/music/A1.flac", @"cs": @(-1), @"ce": @(-1) },
                @{ @"file": @"/music/A2.flac", @"cs": @(12.5), @"ce": @(45.0) },
            ]
        };
        g_spy.sqInfoByName[@"ListB"] = @{
            @"ok": @YES,
            @"name": @"ListB",
            @"items": @[
                @{ @"file": @"/music/B1.flac", @"cs": @(-1), @"ce": @(-1) },
            ]
        };
        [sqVC openPlaylist:@"ListA"];
        Pump(0.05);
        [sqVC playFromIndex:1];
        BOOL p1Done = WaitUntil(1.0, ^BOOL {
            return HasPost(g_spy, @"/api/sq/play", nil) &&
                   HasPost(g_spy, @"/api/play", @"A2.flac") &&
                   HasPost(g_spy, @"/api/play", @"cs=12.500") &&
                   HasPost(g_spy, @"/api/play", @"ce=45.000");
        });
        Ck(p1Done, "P1 基线：歌单 playFromIndex 正常完成 /api/sq/play 后按 CUE cs/ce 起播",
           DumpPosts(g_spy));

        // P2: loadQueueAndPlayAt 等待 POST /api/sq/play 期间切换歌单（selectedName 与 items 均变）
        [g_spy reset];
        g_spy.playmode = 0;
        g_spy.sqInfoByName[@"ListA"] = @{
            @"ok": @YES,
            @"name": @"ListA",
            @"items": @[
                @{ @"file": @"/music/A1.flac", @"cs": @(-1), @"ce": @(-1) },
            ]
        };
        g_spy.sqInfoByName[@"ListB"] = @{
            @"ok": @YES,
            @"name": @"ListB",
            @"items": @[
                @{ @"file": @"/music/B1.flac", @"cs": @(-1), @"ce": @(-1) },
            ]
        };
        [sqVC openPlaylist:@"ListA"];
        Pump(0.05);

        g_spy.holdSqPlayPost = YES;
        [sqVC playFromIndex:0];
        BOOL p2Held = WaitUntil(1.0, ^BOOL { return g_spy.heldSqPlayPosts.count == 1; });
        g_spy.holdSqPlayPost = NO;

        // 在 /api/sq/play?name=ListA&i=0 在途时切到 ListB
        [sqVC openPlaylist:@"ListB"];
        Pump(0.05);
        Ck([[sqVC valueForKey:@"selectedName"] isEqualToString:@"ListB"],
           "P2 前置：已切换到 ListB", [sqVC valueForKey:@"selectedName"] ?: @"nil");

        [g_spy clearRequests];
        [g_spy releaseFirstHeld:g_spy.heldSqPlayPosts withJSON:@{ @"ok": @YES }];
        Pump(0.08);
        BOOL p2WrongSong = HasPost(g_spy, @"/api/play", nil);
        Ck(p2Held && !p2WrongSong,
           "P2 歌单 loadQueueAndPlayAt 回调期间切换歌单，不用新 selectedName/items 播放错歌",
           [NSString stringWithFormat:@"held=%d leaked=[%@]", p2Held, DumpPosts(g_spy)]);

        // P3: loadQueueAndPlayAt 等待 POST /api/sq/play 期间同歌单重载（items 改变）
        [g_spy reset];
        g_spy.playmode = 0;
        g_spy.sqInfoByName[@"ListA"] = @{
            @"ok": @YES,
            @"name": @"ListA",
            @"items": @[
                @{ @"file": @"/music/A_OLD.flac", @"cs": @(-1), @"ce": @(-1) },
            ]
        };
        [sqVC openPlaylist:@"ListA"];
        Pump(0.05);

        g_spy.holdSqPlayPost = YES;
        [sqVC playFromIndex:0];
        BOOL p3Held = WaitUntil(1.0, ^BOOL { return g_spy.heldSqPlayPosts.count == 1; });
        g_spy.holdSqPlayPost = NO;

        // 同歌单内容被刷新，index 0 变成另一首
        g_spy.sqInfoByName[@"ListA"] = @{
            @"ok": @YES,
            @"name": @"ListA",
            @"items": @[
                @{ @"file": @"/music/A_REPLACED.flac", @"cs": @(-1), @"ce": @(-1) },
            ]
        };
        [sqVC loadItems];
        Pump(0.05);

        [g_spy clearRequests];
        [g_spy releaseFirstHeld:g_spy.heldSqPlayPosts withJSON:@{ @"ok": @YES }];
        Pump(0.08);
        BOOL p3PlayedReplaced = HasPost(g_spy, @"/api/play", @"A_REPLACED.flac");
        Ck(p3Held && !p3PlayedReplaced,
           "P3 歌单 loadQueueAndPlayAt 回调期间 items 改变，不得用新 items[index] 播放错歌 A_REPLACED",
           [NSString stringWithFormat:@"held=%d leaked=[%@]", p3Held, DumpPosts(g_spy)]);

        // P4: playFromIndex 等待 GET /api/playmode 期间切换歌单（selectedName 改变）
        [g_spy reset];
        g_spy.playmode = 0;
        g_spy.sqInfoByName[@"ListA"] = @{
            @"ok": @YES,
            @"name": @"ListA",
            @"items": @[ @{ @"file": @"/music/A1.flac", @"cs": @(-1), @"ce": @(-1) } ]
        };
        g_spy.sqInfoByName[@"ListB"] = @{
            @"ok": @YES,
            @"name": @"ListB",
            @"items": @[ @{ @"file": @"/music/B1.flac", @"cs": @(-1), @"ce": @(-1) } ]
        };
        [sqVC openPlaylist:@"ListA"];
        Pump(0.05);

        g_spy.holdPlaymodeGet = YES;
        [sqVC playFromIndex:0];
        BOOL p4Held = WaitUntil(1.0, ^BOOL { return g_spy.heldPlaymodeGets.count == 1; });
        g_spy.holdPlaymodeGet = NO;

        [sqVC openPlaylist:@"ListB"];
        Pump(0.05);
        [g_spy clearRequests];
        [g_spy releaseFirstHeld:g_spy.heldPlaymodeGets withJSON:@{ @"ok": @YES, @"mode": @0 }];
        Pump(0.08);
        BOOL p4LeakedSqPlay = HasPost(g_spy, @"/api/sq/play", nil) || HasPost(g_spy, @"/api/play", nil);
        Ck(p4Held && !p4LeakedSqPlay,
           "P4 歌单 playFromIndex 等待 GET /api/playmode 期间切换歌单，不再用新 selectedName 发 /api/sq/play",
           [NSString stringWithFormat:@"held=%d leaked=[%@]", p4Held, DumpPosts(g_spy)]);

        // P5: playFromIndex/loadQueueAndPlayAt 等待 POST /api/sq/play 期间被 RLPPlayAlbum 取代
        [g_spy reset];
        g_spy.playmode = 0;
        g_spy.sqInfoByName[@"ListA"] = @{
            @"ok": @YES,
            @"name": @"ListA",
            @"items": @[ @{ @"file": @"/music/A1.flac", @"cs": @(-1), @"ce": @(-1) } ]
        };
        [sqVC openPlaylist:@"ListA"];
        Pump(0.05);

        g_spy.holdSqPlayPost = YES;
        [sqVC playFromIndex:0];
        BOOL p5Held = WaitUntil(1.0, ^BOOL { return g_spy.heldSqPlayPosts.count == 1; });
        g_spy.holdSqPlayPost = NO;

        RLPPlayAlbum(@"alb-supersede", 0);
        BOOL p5AlbumPosted = WaitUntil(1.0, ^BOOL {
            return HasPost(g_spy, @"/api/lib/play", @"k=alb-supersede&i=0");
        });

        [g_spy clearRequests];
        [g_spy releaseFirstHeld:g_spy.heldSqPlayPosts withJSON:@{ @"ok": @YES }];
        Pump(0.08);
        BOOL p5Hijacked = HasPost(g_spy, @"/api/play", @"A1.flac");
        Ck(p5Held && p5AlbumPosted && !p5Hijacked,
           "P5 歌单 loadQueueAndPlayAt 被 RLPPlayAlbum 取代后，不再发 /api/play 抢播",
           [NSString stringWithFormat:@"held=%d album=%d leaked=[%@]", p5Held, p5AlbumPosted, DumpPosts(g_spy)]);

        std::printf("结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
