// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_volume_contract.mm — 音量闭环契约判据（延迟回包/拖动跨轮询/field editor/epoch/快捷键/DSD锁定）
// 离线对象测试：不启动 rlapp_core、不碰 8899、不播声音、不模拟真实键鼠设备。
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "RLPPlaybackBarView.h"
#import "RLPNowPlayingViewController.h"
#import "RLPVolumeSliderView.h"
#import "RLPVolumeKnobView.h"
#import "RLPShortcuts.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

#include <cmath>
#include <cstdio>

// ---- 延迟可控的 RLPCoreClient Mock ----
typedef void (^PendingCompletion)(NSDictionary * _Nullable json);

@interface RLPDelayedCall : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) RLPJSONCompletion completion;
@end
@implementation RLPDelayedCall
@end

static BOOL gOnline = NO;
static NSMutableArray<RLPDelayedCall *> *gPendingStatus = nil;
static NSMutableArray<RLPDelayedCall *> *gPendingPosts = nil;
static NSMutableArray<NSString *> *gPostHistory = nil;
static NSDictionary *gImmediateMeta = nil;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RLPCoreClient
+ (instancetype)shared {
    static RLPCoreClient *c;
    if (!c) c = [self new];
    return c;
}
- (BOOL)started { return gOnline; }
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    if (!done) return;
    if ([path isEqualToString:@"/api/status"]) {
        RLPDelayedCall *call = [RLPDelayedCall new];
        call.path = path;
        call.completion = done;
        [gPendingStatus addObject:call];
        return;
    }
    if ([path hasPrefix:@"/api/meta"]) {
        done(gImmediateMeta ?: @{@"title": @"Test Track", @"artist": @"Test Artist", @"album": @"Test Album"});
        return;
    }
    if ([path isEqualToString:@"/api/playmode"]) {
        done(@{@"mode": @0});
        return;
    }
    done(@{@"ok": @YES});
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done {
    (void)path;
    if (done) done(nil);
}
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    (void)body;
    [gPostHistory addObject:path];
    if ([path hasPrefix:@"/api/volume"]) {
        RLPDelayedCall *call = [RLPDelayedCall new];
        call.path = path;
        call.completion = done;
        [gPendingPosts addObject:call];
        return;
    }
    if (done) done(@{@"ok": @YES});
}
@end
#pragma clang diagnostic pop

// 测试侧声明（预期生产接口）
@interface RLPPlaybackBarView (ContractSeam)
- (void)fetchStatus;
- (void)commitVolumeDb:(double)db;
- (double)currentVolumeDb;
- (BOOL)isVolumeLocked;
@end

@interface RLPNowPlayingViewController (ContractSeam)
- (void)refresh;
@end

@interface NSObject (NPControlsContract)
- (void)updateVolumeUiForDb:(double)db;
- (void)applyVolumeDb:(double)db;
- (void)onToggleVolumeMute:(id)sender;
@end

static int gPass = 0, gFail = 0;
static void Ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) {
        std::printf("  [PASS] %s\n", what);
        ++gPass;
    } else {
        std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: "");
        ++gFail;
    }
}
static BOOL Near(double a, double b, double eps) { return std::fabs(a - b) <= eps; }

static NSDictionary *StatusDict(double volDb, BOOL rawLocked, BOOL writable) {
    return @{
        @"ok": @YES,
        @"playing": @YES,
        @"paused": @NO,
        @"current": @"/offline/test.flac",
        @"pos": @12.0,
        @"dur": @240.0,
        @"volDb": @(volDb),
        @"rawVolumeLocked": @(rawLocked),
        @"volumeWritable": @(writable),
        @"bitPerfect": @"yes",
        @"outRate": @44100,
        @"outBits": @24
    };
}

static void FlushOldestStatus(NSDictionary *json) {
    if (!gPendingStatus.count) return;
    RLPDelayedCall *c = gPendingStatus.firstObject;
    [gPendingStatus removeObjectAtIndex:0];
    if (c.completion) c.completion(json);
}

static void FlushNewestStatus(NSDictionary *json) {
    if (!gPendingStatus.count) return;
    RLPDelayedCall *c = gPendingStatus.lastObject;
    [gPendingStatus removeLastObject];
    if (c.completion) c.completion(json);
}

static void FlushPostAt(NSUInteger idx, NSDictionary * _Nullable json) {
    if (idx >= gPendingPosts.count) return;
    RLPDelayedCall *c = gPendingPosts[idx];
    [gPendingPosts removeObjectAtIndex:idx];
    if (c.completion) c.completion(json);
}

int main() { @autoreleasepool {
    [NSApplication sharedApplication];
    gPendingStatus = [NSMutableArray array];
    gPendingPosts = [NSMutableArray array];
    gPostHistory = [NSMutableArray array];
    gOnline = YES;

    std::printf("== 音量闭环契约判据（延迟status/post、拖动、field editor、[-120,+20]、DSD锁定）==\n");

    // A partial status must not invent 0 dB (full gain) for an unknown volume.
    Ck(std::isnan([RLPPlaybackStatus statusFromJSON:@{@"ok": @YES}].volumeDb),
       "V0 missing volume remains unknown", @"");
    Ck(std::isnan([RLPPlaybackStatus statusFromJSON:@{@"ok": @YES, @"volDb": NSNull.null}].volumeDb),
       "V0 null volume remains unknown", @"");
    Ck(std::isnan([RLPPlaybackStatus statusFromJSON:@{@"ok": @YES, @"volDb": @"invalid"}].volumeDb),
       "V0 malformed volume remains unknown", @"");
    Ck(Near([RLPPlaybackStatus statusFromJSON:@{@"ok": @YES, @"volDb": @0}].volumeDb, 0, 0.001),
       "V0 explicit zero dB is still valid", @"");

    RLPVolumeMuteReset();
    Ck(Near(RLPVolumeMuteNextDb(-25.0), -120.0, 0.001), "V4 known mute remembers actual gain", @"");
    Ck(std::isnan(RLPVolumeMuteNextDb(NAN)) && RLPVolumeMuteHasRestore(),
       "V4 unknown mute does not consume saved restore value", @"");
    Ck(Near(RLPVolumeMuteNextDb(-120.0), -25.0, 0.001), "V4 later known mute restores original gain", @"");
    RLPVolumeMuteReset();

    // A failed first write has no confirmed value to broadcast to other views.
    {
        RLPPlaybackBarView *fresh = [[RLPPlaybackBarView alloc] initWithFrame:NSMakeRect(0,0,1120,66)];
        [fresh startPolling];
        __block NSUInteger volumeBroadcasts = 0;
        id token = [[NSNotificationCenter defaultCenter] addObserverForName:@"RLPVolumeDidChangeNotification" object:nil queue:nil usingBlock:^(NSNotification *note) {
            if (note.userInfo[@"source"] == fresh) ++volumeBroadcasts;
        }];
        [fresh commitVolumeDb:-30.0];
        FlushPostAt(0, @{@"ok": @NO, @"error": @"first write failed"});
        Ck(volumeBroadcasts == 0, "V2 failed first write cannot broadcast invented confirmed volume",
           [NSString stringWithFormat:@"broadcasts=%lu", (unsigned long)volumeBroadcasts]);
        Ck(std::isnan([fresh currentVolumeDb]), "V2 failure before first status keeps volume unknown", @"");
        [[NSNotificationCenter defaultCenter] removeObserver:token];
        [fresh stopPolling];
        [gPendingStatus removeAllObjects];
        [gPendingPosts removeAllObjects];
    }

    {
        RLPNowPlayingViewController *freshNP = [RLPNowPlayingViewController new];
        (void)freshNP.view;
        id controls = [freshNP valueForKey:@"webControls"];
        Ck(controls != nil, "V3 first-write fixture contains playback controls", @"");
        __block NSUInteger broadcasts = 0;
        id token = [[NSNotificationCenter defaultCenter] addObserverForName:@"RLPVolumeDidChangeNotification" object:nil queue:nil usingBlock:^(NSNotification *note) {
            if (note.userInfo[@"source"] == controls) ++broadcasts;
        }];
        RLPVolumeMuteReset();
        [controls onToggleVolumeMute:nil];
        Ck(gPendingPosts.count == 0 && !RLPVolumeMuteHasRestore(),
           "V5 unconfirmed playback-page mute cannot invent restore gain", @"");
        [gPendingPosts removeAllObjects];
        RLPVolumeMuteReset();
        [controls applyVolumeDb:-30.0];
        FlushPostAt(0, @{@"ok": @NO, @"error": @"first page write failed"});
        Ck(![[controls valueForKey:@"hasConfirmedVolume"] boolValue] && broadcasts == 0,
           "V3 failed first page write does not confirm or broadcast default volume",
           [NSString stringWithFormat:@"confirmed=%@ broadcasts=%lu", [controls valueForKey:@"hasConfirmedVolume"], (unsigned long)broadcasts]);
        [[NSNotificationCenter defaultCenter] removeObserver:token];
        [freshNP stopPolling];
        [gPendingStatus removeAllObjects];
        [gPendingPosts removeAllObjects];
    }

    // 构造底栏与播放页，挂在同一个 offscreen window 上以测试 firstResponder / field editor
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1120, 720)
                                                styleMask:NSWindowStyleMaskTitled
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    RLPPlaybackBarView *bar = [[RLPPlaybackBarView alloc] initWithFrame:NSMakeRect(0, 0, 1120, 66)];
    [win.contentView addSubview:bar];
    [bar layoutSubtreeIfNeeded];
    [bar startPolling];
    Ck(std::isnan([bar currentVolumeDb]),
       "V1 first pending status exposes unknown volume instead of zero dB", @"");
    // 初始 status 到位：-15.0 dB
    FlushOldestStatus(StatusDict(-15.0, NO, YES));

    RLPVolumeSliderView *barSlider = [bar valueForKey:@"volKnob"];
    NSTextField *barField = [bar valueForKey:@"volDbField"];
    NSButton *barMute = [bar valueForKey:@"volMuteBtn"];

    [bar fetchStatus];
    FlushOldestStatus(@{@"ok": @YES, @"playing": @YES, @"paused": @NO, @"current": @"/tmp/volume-contract.flac"});
    Ck(Near([bar currentVolumeDb], -15.0, 0.01), "V0 partial status preserves confirmed bar volume",
       [NSString stringWithFormat:@"%.2f", [bar currentVolumeDb]]);

    // ---- C1：底栏拖动跨轮询不跳回 + live 刷新精确数值框 ----
    {
        [bar fetchStatus]; // 发出一个在途的旧 status 请求（将回报 -15.0）
        const NSRect tr = [barSlider trackRect];
        const CGFloat x0 = [barSlider xForNorm:RLPVolSliderDbToNorm(-15.0)];
        NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                           location:[barSlider convertPoint:NSMakePoint(x0, NSMidY(tr)) toView:nil]
                                      modifierFlags:0 timestamp:0 windowNumber:win.windowNumber
                                            context:nil eventNumber:0 clickCount:1 pressure:1.0];
        [barSlider mouseDown:down];

        const CGFloat xDrag = [barSlider xForNorm:RLPVolSliderDbToNorm(-6.0)];
        NSEvent *drag = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDragged
                                           location:[barSlider convertPoint:NSMakePoint(xDrag, NSMidY(tr)) toView:nil]
                                      modifierFlags:0 timestamp:0 windowNumber:win.windowNumber
                                            context:nil eventNumber:0 clickCount:1 pressure:1.0];
        [barSlider mouseDragged:drag];
        const double liveDb = barSlider.db;
        Ck(barSlider.dragging && liveDb > -14.0,
           "C1a 底栏滑杆拖动进入 dragging 且值已变化",
           [NSString stringWithFormat:@"dragging=%d db=%.1f", barSlider.dragging, liveDb]);
        Ck(Near([barField.stringValue doubleValue], liveDb, 0.15),
           "C1b 拖动 live 期间立即刷新精确数值框",
           [NSString stringWithFormat:@"field=%@ live=%.1f", barField.stringValue, liveDb]);

        // 此时旧 poll (-15.0) 到达：绝不能覆盖拖动中的滑杆和输入框！
        FlushOldestStatus(StatusDict(-15.0, NO, YES));
        Ck(Near(barSlider.db, liveDb, 1e-6),
           "C1c 拖动跨轮询不被旧 status(-15.0) 覆盖",
           [NSString stringWithFormat:@"got=%.1f want=%.1f", barSlider.db, liveDb]);
        Ck(Near([barField.stringValue doubleValue], liveDb, 0.15),
           "C1d 拖动跨轮询精确数值框也不被旧 status 覆盖",
           [NSString stringWithFormat:@"field=%@ want=%.1f", barField.stringValue, liveDb]);

        NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp
                                         location:[barSlider convertPoint:NSMakePoint(xDrag, NSMidY(tr)) toView:nil]
                                    modifierFlags:0 timestamp:0 windowNumber:win.windowNumber
                                          context:nil eventNumber:0 clickCount:1 pressure:1.0];
        [barSlider mouseUp:up];
        Ck(!barSlider.dragging && gPendingPosts.count == 1,
           "C1e mouseUp 结束拖动并提交 1 次 /api/volume",
           [NSString stringWithFormat:@"posts=%lu", (unsigned long)gPendingPosts.count]);
        FlushPostAt(0, @{@"ok": @YES, @"db": @(liveDb)});
    }

    // ---- C2：延迟 status + 提交 epoch/seq 保护 + 乱序 post + 失败回滚 ----
    {
        [gPendingStatus removeAllObjects];
        [gPendingPosts removeAllObjects];
        // 先发出一个旧 status 请求（将来返回 -15.0）
        [bar fetchStatus];
        // 用户立即提交新音量 -4.0（POST 在途）
        [bar commitVolumeDb:-4.0];
        // 在 POST 尚未返回时，旧 status(-15.0) 到达 -> 必须被 epoch/pending 拦截，不能把 -4.0 拉回 -15.0
        FlushOldestStatus(StatusDict(-15.0, NO, YES));
        Ck(Near(barSlider.db, -4.0, 0.1),
           "C2a POST 在途时，早先发出的旧 status(-15.0) 不得覆盖新值(-4.0)",
           [NSString stringWithFormat:@"got=%.1f", barSlider.db]);

        // 再发一次新提交 -2.0（此时两个 POST 在途）
        [bar commitVolumeDb:-2.0];
        Ck(gPendingPosts.count == 2, "C2b 连续两次提交产生 2 个在途 POST", @"");
        // 较新的 POST (-2.0) 先成功返回
        FlushPostAt(1, @{@"ok": @YES, @"db": @(-2.0)});
        // 较旧的 POST (-4.0) 后返回（乱序/甚至失败）-> 必须被 seq 丢弃，不得回滚或覆盖 -2.0
        FlushPostAt(0, @{@"ok": @NO});
        Ck(Near(barSlider.db, -2.0, 0.1),
           "C2c 乱序到达的旧 POST 回包（即使失败）不得覆盖已确认的最新值 -2.0",
           [NSString stringWithFormat:@"got=%.1f", barSlider.db]);

        // 此时再发一次提交 +6.0，并让它失败 -> 必须回滚到上次确认的 -2.0，不能把未生效的 +6.0 留在界面上
        [bar commitVolumeDb:6.0];
        FlushPostAt(0, @{@"ok": @NO, @"error": @"failed"});
        Ck(Near(barSlider.db, -2.0, 0.1),
           "C2d 最新 POST 失败时必须回滚到上次确认值(-2.0)",
           [NSString stringWithFormat:@"got=%.1f", barSlider.db]);
        // 失败触发的补偿 status 返回 -2.0 后，状态收敛
        while (gPendingStatus.count) FlushOldestStatus(StatusDict(-2.0, NO, YES));
    }

    // ---- C3：field editor 保护（window.firstResponder == currentEditor）----
    {
        [win makeFirstResponder:barField];
        barField.stringValue = @"-8.5";
        [bar fetchStatus];
        FlushOldestStatus(StatusDict(-2.0, NO, YES));
        Ck([barField.stringValue isEqualToString:@"-8.5"],
           "C3 编辑精确数值框（field editor 激活）时，status 轮询不得覆盖输入中文本",
           [NSString stringWithFormat:@"got=%@ firstResponder=%@", barField.stringValue, win.firstResponder]);
        [win makeFirstResponder:nil];
    }

    // ---- C4：NowPlaying 旋钮与底栏同步 + 拖动保护 + field editor 保护 ----
    {
        RLPNowPlayingViewController *np = [[RLPNowPlayingViewController alloc] init];
        [win.contentView addSubview:np.view];
        [np startPolling];
        FlushOldestStatus(StatusDict(-2.0, NO, YES));
        id npControls = [np valueForKey:@"webControls"];
        RLPVolumeKnobView *npKnob = [npControls valueForKey:@"volKnob"];
        NSTextField *npField = [npControls valueForKey:@"volDbField"];

        Ck(Near(npKnob.db, -2.0, 0.1),
           "C4a NowPlaying 轮询同步更新可见 RLPVolumeKnobView.db",
           [NSString stringWithFormat:@"npKnob.db=%.1f", npKnob.db]);

        // 在底栏提交 +3.5，确认后 NowPlaying 立即同步（不等下一次轮询）
        [bar commitVolumeDb:3.5];
        FlushPostAt(0, @{@"ok": @YES, @"db": @3.5});
        Ck(Near(npKnob.db, 3.5, 0.1) && Near([npField.stringValue doubleValue], 3.5, 0.15),
           "C4b 底栏提交 +3.5 后，NowPlaying 旋钮与精确框立即同步",
           [NSString stringWithFormat:@"npKnob=%.1f npField=%@", npKnob.db, npField.stringValue]);

        // NowPlaying 旋钮拖动中，旧 status(-2.0) 到达不覆盖
        NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                           location:[npKnob convertPoint:NSMakePoint(8.0, 32.0) toView:nil]
                                      modifierFlags:0 timestamp:0 windowNumber:win.windowNumber
                                            context:nil eventNumber:0 clickCount:1 pressure:1.0];
        [npKnob mouseDown:down];
        const double npDraggingDb = npKnob.db;
        [np refresh];
        FlushOldestStatus(StatusDict(-2.0, NO, YES));
        Ck(npKnob.dragging && Near(npKnob.db, npDraggingDb, 1e-6),
           "C4c NowPlaying 旋钮拖动中，status 轮询不得覆盖旋钮",
           [NSString stringWithFormat:@"got=%.1f want=%.1f", npKnob.db, npDraggingDb]);
        NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp
                                         location:[npKnob convertPoint:NSMakePoint(8.0, 32.0) toView:nil]
                                    modifierFlags:0 timestamp:0 windowNumber:win.windowNumber
                                          context:nil eventNumber:0 clickCount:1 pressure:1.0];
        [npKnob mouseUp:up];
        while (gPendingPosts.count) FlushPostAt(0, @{@"ok": @YES, @"db": @(npDraggingDb)});
        // Cross-entry confirmations must invalidate a poll started by the other view.
        [gPendingStatus removeAllObjects];
        [np refresh];
        [bar commitVolumeDb:3.5];
        FlushPostAt(0, @{ @"ok": @YES, @"db": @3.5 });
        FlushOldestStatus(StatusDict(-12.0, NO, YES));
        Ck(Near(npKnob.db, 3.5, 0.1), "C4d 底栏确认新音量后，播放页在途旧poll不得回跳", @"");

        [gPendingStatus removeAllObjects];
        [bar fetchStatus];
        [npControls applyVolumeDb:4.5];
        FlushPostAt(0, @{ @"ok": @YES, @"db": @4.5 });
        FlushOldestStatus(StatusDict(-12.0, NO, YES));
        Ck(Near(barSlider.db, 4.5, 0.1), "C4e 播放页确认新音量后，底栏在途旧poll不得回跳", @"");

        [np stopPolling];
        [np.view removeFromSuperview];
    }

    // ---- C5：[-120, +20] 快捷键步进与连续连按不丢步 ----
    {
        BOOL ch = NO;
        double s1 = RLPVolumeStepDb(0.0, 0.5, &ch);
        Ck(ch && Near(s1, 0.5, 1e-6), "C5a 快捷键步进支持正增益 0.0 -> +0.5 dB",
           [NSString stringWithFormat:@"got=%.1f ch=%d", s1, ch]);
        double s2 = RLPVolumeStepDb(20.0, 0.5, &ch);
        Ck(!ch && Near(s2, 20.0, 1e-6), "C5b 快捷键步进上限 +20.0 dB",
           [NSString stringWithFormat:@"got=%.1f ch=%d", s2, ch]);
        double s3 = RLPVolumeStepDb(-120.0, 0.5, &ch);
        Ck(ch && Near(s3, -119.5, 1e-6), "C5c 快捷键步进从 -120.0 +0.5 -> -119.5（不再跳 -54.5）",
           [NSString stringWithFormat:@"got=%.1f ch=%d", s3, ch]);

        // 连按三次 +0.5（期间没有任何 status 返回，lastStatus 仍停在旧值）：不得丢步
        [gPendingPosts removeAllObjects];
        [bar commitVolumeDb:0.0];
        FlushPostAt(0, @{@"ok": @YES, @"db": @0.0});
        while (gPendingStatus.count) FlushOldestStatus(StatusDict(0.0, NO, YES));

        for (int i = 0; i < 3; ++i) {
            BOOL stepChanged = NO;
            double cur = [bar currentVolumeDb];
            double nxt = RLPVolumeStepDb(cur, 0.5, &stepChanged);
            if (stepChanged) [bar commitVolumeDb:nxt];
        }
        Ck(Near([bar currentVolumeDb], 1.5, 0.05) && gPendingPosts.count == 3,
           "C5d 连续三次快捷键 +0.5 dB（无 status 回包）基于本地乐观值累加到 +1.5 dB",
           [NSString stringWithFormat:@"cur=%.1f posts=%lu", [bar currentVolumeDb], (unsigned long)gPendingPosts.count]);
        while (gPendingPosts.count) FlushPostAt(0, @{@"ok": @YES, @"db": @1.5});
    }

    // ---- C6：原始 DSD 锁定（rawVolumeLocked / volumeWritable=false）----
    {
        [gPostHistory removeAllObjects];
        [bar fetchStatus];
        FlushOldestStatus(StatusDict(0.0, YES, NO));
        Ck([bar isVolumeLocked] && barSlider.isLocked && !barMute.enabled && !barField.enabled,
           "C6a rawVolumeLocked/volumeWritable=false 时底栏滑杆/静音/精确框全锁定",
           [NSString stringWithFormat:@"barLocked=%d slider=%d muteEn=%d fieldEn=%d",
            [bar isVolumeLocked], barSlider.isLocked, barMute.enabled, barField.enabled]);
        NSUInteger postsBefore = gPostHistory.count;
        [bar commitVolumeDb:-10.0];
        [barMute performClick:nil];
        Ck(gPostHistory.count == postsBefore,
           "C6b 原始 DSD 锁定时不允许下发 /api/volume",
           [NSString stringWithFormat:@"postsDelta=%lu", (unsigned long)(gPostHistory.count - postsBefore)]);

        // 解锁恢复
        [bar fetchStatus];
        FlushOldestStatus(StatusDict(-10.0, NO, YES));
        Ck(![bar isVolumeLocked] && !barSlider.isLocked && barMute.enabled && barField.enabled,
           "C6c volumeWritable=true 恢复可写状态", @"");
    }

    // ---- C7：底栏缩窄到 626pt 保留有效行程 ----
    {
        bar.frame = NSMakeRect(0, 0, 626, 66);
        [bar layout];
        Ck(NSWidth(barSlider.frame) >= 48.0 && NSWidth([barSlider trackRect]) >= 48.0,
           "C7 底栏缩窄至 626pt 时音量滑杆与轨道仍保留 >= 48pt 有效行程",
           [NSString stringWithFormat:@"frameW=%.1f trackW=%.1f",
            NSWidth(barSlider.frame), NSWidth([barSlider trackRect])]);
    }

    // C8: both volume entry points must roll back mute memory when POST fails.
    {
        RLPNowPlayingViewController *page = [RLPNowPlayingViewController new];
        (void)page.view;
        id pageControls = [page valueForKey:@"webControls"];
        for (id target in @[bar, pageControls]) {
            BOOL isBar = target == bar;
            [gPendingPosts removeAllObjects];
            [gPendingStatus removeAllObjects];
            RLPVolumeMuteReset();
            if (isBar) [bar commitVolumeDb:-25.0]; else [target applyVolumeDb:-25.0];
            FlushPostAt(0, @{@"ok": @YES, @"db": @(-25.0)});
            [target onToggleVolumeMute:nil];
            FlushPostAt(0, @{@"ok": @YES, @"db": @(-120.0)});
            Ck(RLPVolumeMuteHasRestore(), "C8 successful mute has restore memory", @"");
            [target onToggleVolumeMute:nil];
            FlushPostAt(0, @{@"ok": @NO, @"error": @"restore rejected"});
            Ck(RLPVolumeMuteHasRestore(), "C8 rejected unmute preserves retry memory", isBar ? @"bar" : @"page");
            [target onToggleVolumeMute:nil];
            Ck(gPendingPosts.count == 1 && [gPendingPosts[0].path isEqualToString:@"/api/volume?db=-25.0"],
               "C8 unmute retry sends original gain", isBar ? @"bar" : @"page");
            if (gPendingPosts.count) FlushPostAt(0, @{@"ok": @YES, @"db": @(-25.0)});
            Ck(!RLPVolumeMuteHasRestore(), "C8 successful unmute consumes restore memory", @"");
            RLPVolumeMuteReset();
            if (isBar) [bar commitVolumeDb:-25.0]; else [target applyVolumeDb:-25.0];
            FlushPostAt(0, @{@"ok": @YES, @"db": @(-25.0)});
            [target onToggleVolumeMute:nil];
            FlushPostAt(0, @{@"ok": @NO, @"error": @"mute rejected"});
            Ck(!RLPVolumeMuteHasRestore(), "C8 rejected mute leaves no restore memory", isBar ? @"bar" : @"page");
        }
        // An old failure in one entry must not undo a later mute in the other.
        RLPVolumeMuteReset();
        [gPendingPosts removeAllObjects];
        [bar commitVolumeDb:-25.0];
        FlushPostAt(0, @{@"ok": @YES, @"db": @(-25.0)});
        [bar onToggleVolumeMute:nil];
        [pageControls applyVolumeDb:-30.0];
        FlushPostAt(1, @{@"ok": @YES, @"db": @(-30.0)});
        [pageControls onToggleVolumeMute:nil];
        Ck(gPendingPosts.count == 2, "C9 old bar mute and newer page mute are pending", @"");
        FlushPostAt(0, @{@"ok": @NO, @"error": @"old mute failed"});
        Ck(Near(RLPVolumeMuteCapture().restoreDb, -30.0, 0.001),
           "C9 old cross-entry failure preserves newer restore memory", @"");
        FlushPostAt(0, @{@"ok": @YES, @"db": @(-120.0)});
        [page stopPolling];
        [gPendingPosts removeAllObjects];
        [gPendingStatus removeAllObjects];
        RLPVolumeMuteReset();
    }

    [bar stopPolling];
    std::printf("\n结果：%d passed, %d failed\n", gPass, gFail);
    return gFail == 0 ? 0 : 1;
} }
