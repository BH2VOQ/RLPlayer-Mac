// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_pause_paths.mm — 播放/暂停三条入口（底栏 / 播放页 / 菜单·媒体键）的请求契约
//
// ============================ 这个测试在证明什么 ============================
// 用户 2026-11-14 实机：「音乐现在无法暂停」。三条入口必须都落到同一条判定，
// 且**请求真的发出**（不是只改图标）：
//   T1 底栏：播放中按按钮 → 恰发 /api/pause?on=1；暂停中 → on=0；已停止 → /api/play（重播）
//   T2 播放页：同一状态机（webControls.playBtn 走 onPause:）
//   T3 菜单/媒体键的显式命令（pauseCommand/playCommand）：不看过期快照，
//      pause 永远发 on=1；play 在已停止时重播，而不是发一个停止态 no-op 的 on=0
//
// 为什么用桩：三条入口的判定是纯 UI 侧逻辑；真核心的端到端已由
// native_bar_core / --audit 覆盖（真起播、真暂停、真恢复）。这里固定"发什么请求"，
// 否则以后谁把判定改回 "只发 pause" 都不会有测试红。
//
// 铁律②：不启动核心、不打开音频设备、不读写用户曲库（全桩 + 临时目录）。
#import <AppKit/AppKit.h>

#import "RLPSupport.h"
#import "RLPPlaybackBarView.h"
#import "RLPNowPlayingViewController.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPTheme.h"

#include <cstdio>
#include <string>

#pragma mark - 桩核心（记录请求，按夹具回状态）

static BOOL g_playing = NO;
static BOOL g_paused = NO;
static NSString *g_current = @"/tmp/pause-paths-fixture.aiff";
static NSMutableArray<NSDictionary *> *g_posts = nil;
static NSInteger g_settingsHits = 0;

static void ResetLog(void) {
    if (!g_posts) g_posts = [NSMutableArray array];
    [g_posts removeAllObjects];
}
static NSArray<NSDictionary *> *PostsWithPrefix(NSString *prefix) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *p in g_posts) {
        if ([(NSString *)p[@"path"] hasPrefix:prefix]) [out addObject:p];
    }
    return out;
}
static NSString *LastPostPath(void) {
    return g_posts.count ? (NSString *)g_posts.lastObject[@"path"] : nil;
}

static id ResponseForPath(NSString *path) {
    if ([path hasPrefix:@"/api/status"]) {
        return @{ @"ok": @YES, @"playing": @(g_playing), @"paused": @(g_paused),
                  @"current": g_current ?: @"", @"dur": @225, @"pos": @12,
                  @"volDb": @(-120) };
    }
    if ([path hasPrefix:@"/api/settings"]) {
        ++g_settingsHits;
        return @{ @"ok": @YES, @"kv": @{ @"autoanl": @"0", @"eq": @"", @"ir": @"" } };
    }
    if ([path hasPrefix:@"/api/cast/state"]) {
        return @{ @"ok": @YES, @"running": @NO, @"device": @"" };
    }
    if ([path hasPrefix:@"/api/queue"]) {
        return @{ @"ok": @YES, @"items": @[], @"index": @(-1), @"mode": @0 };
    }
    if ([path hasPrefix:@"/api/fav/list"]) return @{ @"ok": @YES, @"files": @[] };
    if ([path hasPrefix:@"/api/sq/list"]) return @{ @"ok": @YES, @"queues": @[] };
    if ([path hasPrefix:@"/api/lyrics"]) return @{ @"ok": @NO };
    if ([path hasPrefix:@"/api/meta"]) return @{ @"ok": @YES, @"title": @"Fixture" };
    if ([path hasPrefix:@"/api/entity"]) return @{ @"ok": @NO };
    if ([path hasPrefix:@"/api/anl"]) return @{ @"ok": @NO };
    if ([path hasPrefix:@"/api/playmode"]) return @{ @"ok": @YES, @"mode": @0 };
    return @{ @"ok": @YES };
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RLPCoreClient
+ (instancetype)shared { static RLPCoreClient *c; if (!c) c = [self new]; return c; }
- (BOOL)started { return YES; }
- (BOOL)startEmbedded { return YES; }
- (void)shutdown {}
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    id resp = ResponseForPath(path);
    dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(resp); });
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done {
    (void)path;
    if (done) done(nil);
}
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    if (!g_posts) g_posts = [NSMutableArray array];
    [g_posts addObject:@{ @"path": path ?: @"", @"body": body ?: @"" }];
    if (done) done(@{ @"ok": @YES });
}
@end
#pragma clang diagnostic pop

#pragma mark - 工具

static int g_fail = 0, g_pass = 0;
static void ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++g_fail; }
}

static void Pump(NSTimeInterval seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
}
static BOOL WaitUntil(NSTimeInterval timeout, BOOL (^pred)(void)) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([until timeIntervalSinceNow] > 0) { if (pred()) return YES; Pump(0.03); }
    return pred();
}

/// 点一下真按钮（不是直接调方法）——证明的是"按钮真的连着动作"，而不只是函数存在。
static void ClickButton(NSButton *b) {
    [b performClick:nil];
    Pump(0.08);
}

static void SetState(BOOL playing, BOOL paused, NSString *current) {
    g_playing = playing;
    g_paused = paused;
    g_current = current;
}

int main() {
    @autoreleasepool {
        std::printf("== 播放/暂停三入口请求契约（桩核心，不启动播放、不出声）==\n");

        [NSApplication sharedApplication];
        ResetLog();

        // ---------------- T1 底栏 ----------------
        RLPPlaybackBarView *bar = [[RLPPlaybackBarView alloc] initWithFrame:NSMakeRect(0, 0, 1120, 66)];
        [bar layout];
        [bar startPolling];
        ck(bar.polling, "T1 底栏进入轮询", @"");

        NSButton *barPlay = [bar valueForKey:@"playBtn"];
        ck(barPlay != nil && barPlay.target != nil && barPlay.action != NULL,
           "T1 底栏播放键有 target/action", @"");

        SetState(YES, NO, @"/tmp/pause-paths-fixture.aiff");
        WaitUntil(2.0, ^BOOL { return bar.lastStatus.playing && bar.lastStatus.paused == NO; });
        ResetLog();
        ClickButton(barPlay);
        ck([PostsWithPrefix(@"/api/pause") count] == 1 &&
           [LastPostPath() isEqualToString:@"/api/pause?on=1"],
           "T1 播放中→底栏按钮真发 /api/pause?on=1（不是只改图标）", LastPostPath() ?: @"无请求");

        SetState(YES, YES, @"/tmp/pause-paths-fixture.aiff");
        WaitUntil(2.0, ^BOOL { return bar.lastStatus.paused; });
        ResetLog();
        ClickButton(barPlay);
        ck([PostsWithPrefix(@"/api/pause") count] == 1 &&
           [LastPostPath() isEqualToString:@"/api/pause?on=0"],
           "T1 暂停中→底栏按钮真发 /api/pause?on=0（能恢复）", LastPostPath() ?: @"无请求");

        // 已停止：web playOrPause 的语义是**重播**；只发 on=0 是 no-op。
        SetState(NO, NO, @"/tmp/pause-paths-fixture.aiff");
        WaitUntil(2.0, ^BOOL { return bar.lastStatus.playing == NO && bar.lastStatus.paused == NO; });
        ResetLog();
        ClickButton(barPlay);
        BOOL barReplay = [PostsWithPrefix(@"/api/play") count] == 1 &&
            [(NSString *)((NSDictionary *)PostsWithPrefix(@"/api/play").firstObject)[@"body"] containsString:@"file="];
        ck(barReplay, "T1 已停止→底栏按钮重播 /api/play（不是停止态 no-op 的 pause）",
           LastPostPath() ?: @"无请求");

        SetState(NO, NO, @"");
        WaitUntil(2.0, ^BOOL { return bar.lastStatus.currentPath.length == 0; });
        ResetLog();
        ClickButton(barPlay);
        ck([PostsWithPrefix(@"/api/pause") count] == 0 && [PostsWithPrefix(@"/api/play") count] == 0,
           "T1 无当前曲目→不发无效请求", LastPostPath() ?: @"无请求");

        // ---------------- T3 媒体键显式命令（生产方法，媒体键回调直接调它们） ----------------
        // 旧码没有这两个方法 ⟹ 这里必须红：系统 pauseCommand 当时依赖 isPlaying 快照，
        // 快照过期时命令被静默丢弃；playCommand 在停止态发 on=0 no-op。
        BOOL hasPauseExplicit = [bar respondsToSelector:@selector(pausePlayback)];
        ck(hasPauseExplicit, "T3 底栏提供媒体键显式暂停入口 pausePlayback", @"方法不存在");
        SetState(NO, NO, @"/tmp/pause-paths-fixture.aiff");   // 故意给过期快照：UI 认为没在播
        WaitUntil(2.0, ^BOOL { return bar.lastStatus.playing == NO; });
        ResetLog();
        if (hasPauseExplicit) [bar performSelector:@selector(pausePlayback)];
        Pump(0.08);
        ck([LastPostPath() isEqualToString:@"/api/pause?on=1"],
           "T3 媒体键暂停不依赖过期快照，仍真发 /api/pause?on=1", LastPostPath() ?: @"无请求");

        BOOL hasResume = [bar respondsToSelector:@selector(resumeOrReplay)];
        ck(hasResume, "T3 底栏提供媒体键显式继续入口 resumeOrReplay", @"方法不存在");
        SetState(NO, NO, @"/tmp/pause-paths-fixture.aiff");
        WaitUntil(2.0, ^BOOL {
            return bar.lastStatus.playing == NO && bar.lastStatus.paused == NO &&
                   [bar.lastStatus.currentPath isEqualToString:@"/tmp/pause-paths-fixture.aiff"];
        });
        ResetLog();
        if (hasResume) [bar performSelector:@selector(resumeOrReplay)];
        Pump(0.08);
        ck([PostsWithPrefix(@"/api/play") count] == 1,
           "T3 媒体键 play 在已停止时重播 /api/play（不是 on=0 no-op）", LastPostPath() ?: @"无请求");

        SetState(YES, YES, @"/tmp/pause-paths-fixture.aiff");
        WaitUntil(2.0, ^BOOL { return bar.lastStatus.paused; });
        ResetLog();
        if (hasResume) [bar performSelector:@selector(resumeOrReplay)];
        Pump(0.08);
        ck([LastPostPath() isEqualToString:@"/api/pause?on=0"],
           "T3 媒体键 play 在暂停中发 /api/pause?on=0（继续）", LastPostPath() ?: @"无请求");

        // ---------------- T2 播放页 ----------------
        RLPNowPlayingViewController *np = [[RLPNowPlayingViewController alloc] init];
        (void)np.view;
        np.view.frame = NSMakeRect(0, 0, 1180, 720);
        [np.view layoutSubtreeIfNeeded];
        [np startPolling];
        ck([[np valueForKey:@"polling"] boolValue], "T2 播放页进入轮询", @"");

        id wc = [np valueForKey:@"webControls"];
        NSButton *npPlay = [wc valueForKey:@"playBtn"];
        ck(npPlay != nil && npPlay.target != nil && npPlay.action != NULL,
           "T2 播放页暂停键有 target/action", @"");

        SetState(YES, NO, @"/tmp/pause-paths-fixture.aiff");
        WaitUntil(2.0, ^BOOL {
            id st = [np valueForKey:@"webStatus"];
            return [[st valueForKey:@"playing"] boolValue] && ![[st valueForKey:@"paused"] boolValue];
        });
        ResetLog();
        ClickButton(npPlay);
        ck([PostsWithPrefix(@"/api/pause") count] == 1 &&
           [LastPostPath() isEqualToString:@"/api/pause?on=1"],
           "T2 播放中→播放页暂停键真发 /api/pause?on=1", LastPostPath() ?: @"无请求");

        SetState(YES, YES, @"/tmp/pause-paths-fixture.aiff");
        WaitUntil(2.0, ^BOOL { id st = [np valueForKey:@"webStatus"]; return [[st valueForKey:@"paused"] boolValue]; });
        ResetLog();
        ClickButton(npPlay);
        ck([LastPostPath() isEqualToString:@"/api/pause?on=0"],
           "T2 暂停中→播放页暂停键真发 /api/pause?on=0", LastPostPath() ?: @"无请求");

        SetState(NO, NO, @"/tmp/pause-paths-fixture.aiff");
        WaitUntil(2.0, ^BOOL {
            id st = [np valueForKey:@"webStatus"];
            return ![[st valueForKey:@"playing"] boolValue] && ![[st valueForKey:@"paused"] boolValue];
        });
        ResetLog();
        ClickButton(npPlay);
        ck([PostsWithPrefix(@"/api/play") count] == 1,
           "T2 已停止→播放页播放键重播 /api/play（与 web playOrPause 同语义）",
           LastPostPath() ?: @"无请求");

        [np stopPolling];
        [bar stopPolling];

        std::printf("\n%s（%d passed, %d failed）\n",
                    g_fail == 0 ? "播放/暂停三入口 全部通过" : "播放/暂停三入口 有失败", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
