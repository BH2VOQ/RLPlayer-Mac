// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_right_drawer.mm — 右侧抽屉的「点歌词行跳转」与「切歌后歌词跟随」判据
//
// ============================ 这条判据在证明什么 ============================
// D1（审计 A，S）：web 的歌词行点击走 doSeek(frac) → POST /api/seek?pos=<0..1 比例>
//   （ui_script.h:6654/6671）。后端 /api/seek 只读 "?pos="（tools/rtaweb.cpp:12411-12417）：
//   find("?pos=") 落空 ⟹ frac=0 ⟹ 跳回曲首。旧原生发的是 /api/seek?ratio=…（RLPRightDrawer.mm:578）
//   ⟹ 点任何一行都回到 0s。所以本文件对旧码必须红。
// D2（审计 C，S/M）：web 的歌词只在**当前曲变化**时重拉（pollStatus 发现 lastCur 变了就
//   loadLyrics(cur)，ui_script.h:6861-6906）。旧原生的 1s loadQueue 轮询只更新 qIndex、
//   从不调 loadLyricsForCurrent；playIndex: 又在队列异步返回**之前**同步读旧索引
//   ⟹ 在歌词页签切歌后永远停在上一首的词。
//
// 铁律②：桩客户端；不启动核心、不碰音频设备、不创建可见窗口、不出声。
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "RLPRightDrawer.h"
#import "RLPCoreClient.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

#include <cstdio>
#include <cmath>

static int g_pass = 0, g_fail = 0;
static void Ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++g_fail; }
}

#pragma mark - 桩客户端（按 fixture 回 JSON，并记录所有请求）

static NSMutableArray<NSDictionary *> *g_gets;
static NSMutableArray<NSDictionary *> *g_posts;
static NSInteger g_curIndex = 0;
static NSArray<NSString *> *g_items;
static NSArray *g_cues;
static NSString *g_lrcA;
static NSString *g_lrcB;
static BOOL g_holdLyrics = NO;
static NSMutableArray<NSDictionary *> *g_heldLyrics;
static BOOL g_holdLyricAi = NO;
static NSMutableArray<RLPJSONCompletion> *g_heldLyricAi;

static NSString *LrcA(void) {
    // 6 行带时间戳：第 5 行 t=40s，dur=100 ⟹ pos=0.4000（web toFixed(4) 同口径）
    return @"[00:01.00]ALPHA 1\n[00:10.00]ALPHA 2\n[00:20.00]ALPHA 3\n"
            "[00:30.00]ALPHA 4\n[00:40.00]ALPHA 5\n[00:50.00]ALPHA 6";
}
static NSString *LrcB(void) {
    return @"[00:02.00]BRAVO 1\n[00:06.00]BRAVO 2";
}

/// 回调一律异步回主线程：真实核心是「后台队列执行 → 回主线程回调」，
/// 同步回调会把审计指出的「队列异步返回前用旧索引读歌词」那个竞态掩盖掉。
static void DeliverAsync(RLPJSONCompletion done, NSDictionary *json) {
    if (!done) return;
    dispatch_async(dispatch_get_main_queue(), ^{ done(json); });
}

#pragma mark clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RLPCoreClient
+ (instancetype)shared { static RLPCoreClient *c; if (!c) c = [self new]; return c; }
- (BOOL)started { return YES; }
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    [g_gets addObject:@{ @"path": path ?: @"" }];
    if (!done) return;
    if ([path hasPrefix:@"/api/queue"]) {
        DeliverAsync(done, @{ @"ok": @YES, @"items": g_items, @"cues": g_cues,
                              @"index": @(g_curIndex), @"mode": @0 });
        return;
    }
    if ([path hasPrefix:@"/api/lyrics?file="]) {
        // 用 fixture 里的曲目路径判断是哪一首（请求里是百分号编码的 file=）
        NSDictionary *resp = [path containsString:RLPEnc(@"/Music/B/B.flac")]
            ? @{ @"ok": @YES, @"lrc": LrcB() } : @{ @"ok": @YES, @"lrc": LrcA() };
        if (g_holdLyrics) {
            [g_heldLyrics addObject:@{ @"path": path, @"done": [done copy], @"resp": resp }];
            return;
        }
        DeliverAsync(done, resp);
        return;
    }
    DeliverAsync(done, @{ @"ok": @NO });
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done { (void)path; if (done) done(nil); }
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    [g_posts addObject:@{ @"path": path ?: @"" , @"body": body ?: @"" }];
    if ([path isEqualToString:@"/api/lyrics/ai"]) {
        if (g_holdLyricAi && done) {
            [g_heldLyricAi addObject:[done copy]];
            return;
        }
        DeliverAsync(done, @{ @"ok": @YES, @"lines": @[ @"AI 1", @"AI 2", @"AI 3", @"AI 4", @"AI 5", @"AI 6" ] });
        return;
    }
    // 模拟真实后端：/api/play 之后队列 index 指向被点的那一首（歌词跟随即由队列驱动）
    if ([path hasPrefix:@"/api/play"]) {
        for (NSUInteger i = 0; i < g_items.count; ++i)
            if ([body containsString:RLPEnc(g_items[i])]) { g_curIndex = (NSInteger)i; break; }
    }
    DeliverAsync(done, @{ @"ok": @YES });
}
@end
#pragma mark clang diagnostic pop

#pragma mark - 工具

static void Pump(double seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
static NSView *FindById(NSView *root, NSString *ident) {
    if (!root) return nil;
    if ([root.identifier isEqualToString:ident]) return root;
    for (NSView *s in root.subviews) {
        NSView *r = FindById(s, ident);
        if (r) return r;
    }
    return nil;
}
/// 合成一次左键按下：两个自定义行视图（歌词行/队列行）都只在自己的 mouseDown: 里派发点击，
/// 不需要窗口或命中测试，所以离屏也能真实走"点击"这条路径。
static void ClickView(NSView *v) {
    NSEvent *e = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                    location:NSMakePoint(3, 3)
                               modifierFlags:0
                                   timestamp:NSProcessInfo.processInfo.systemUptime
                                windowNumber:0
                                     context:nil
                                 eventNumber:1
                                  clickCount:1
                                    pressure:1.0];
    [v mouseDown:e];
}
static NSTextField *RowLabel(NSView *row) {
    if ([row isKindOfClass:[NSTextField class]]) return (NSTextField *)row;
    for (NSView *v in row.subviews) if ([v isKindOfClass:[NSTextField class]]) return (NSTextField *)v;
    return nil;
}
/// 歌词区里是否出现某段文字（用来证明"内容真的换成了 B"而不是只发了请求）。
static BOOL StackHasText(NSStackView *stack, NSString *needle) {
    for (NSView *row in stack.arrangedSubviews) {
        NSTextField *l = RowLabel(row);
        if (l && [l.stringValue containsString:needle]) return YES;
    }
    return NO;
}
static NSInteger CountPaths(NSArray<NSDictionary *> *arr, NSString *prefix) {
    NSInteger n = 0;
    for (NSDictionary *d in arr) if ([d[@"path"] hasPrefix:prefix]) ++n;
    return n;
}
static NSArray<NSDictionary *> *PostsWithPrefix(NSString *prefix) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in g_posts) if ([d[@"path"] hasPrefix:prefix]) [out addObject:d];
    return out;
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        g_gets = [NSMutableArray array];
        g_posts = [NSMutableArray array];
        g_heldLyrics = [NSMutableArray array];
        g_heldLyricAi = [NSMutableArray array];
        g_holdLyrics = NO;
        g_holdLyricAi = NO;
        g_items = @[ @"/Music/A/A.flac", @"/Music/B/B.flac" ];
        g_cues = @[ @[ @(-1), @(-1) ], @[ @(-1), @(-1) ] ];
        g_curIndex = 0;
        [RLPTheme setThemeName:@"light"];
        [RLPTheme setUiStyle:@"apple"];
        std::printf("=== test_native_right_drawer（歌词行 seek 参数名 + 切歌后歌词跟随 · 离屏 · 不出声）===\n");

        RLPRightDrawer *d = [[RLPRightDrawer alloc] initWithFrame:NSMakeRect(0, 0, 320, 600)];
        [d layoutSubtreeIfNeeded];
        [d activate];                       // 拉队列 + 起 1s 轮询
        Pump(0.1);
        Ck(g_gets.count > 0 && [g_gets.firstObject[@"path"] hasPrefix:@"/api/queue"],
           "activate 发起 /api/queue", g_gets.firstObject[@"path"] ?: @"");

        [d showTab:@"l"];
        Pump(0.1);
        NSStackView *lbox = (NSStackView *)FindById(d, @"right.lyricbox");
        Ck(lbox != nil, "找得到歌词容器 right.lyricbox", @"缺歌词容器");
        if (!lbox) { std::printf("结果：%d passed, %d failed\n", g_pass, g_fail); return 1; }
        Ck(CountPaths(g_gets, @"/api/lyrics?file=") >= 1, "歌词页签拉 /api/lyrics?file=",
           [g_gets componentsJoinedByString:@" | "]);
        Ck(StackHasText(lbox, @"ALPHA 1"), "歌词页签显示当前曲 A 的歌词", @"没有 A 的歌词");
        Ck((NSInteger)lbox.arrangedSubviews.count == 6, "6 行带时间轴歌词（fixture）",
           [NSString stringWithFormat:@"rows=%lu", (unsigned long)lbox.arrangedSubviews.count]);

        // ---- D1：点第 5 行（t=40s / dur=100）→ /api/seek?pos=0.4000（不是 ratio=）----
        [d updatePosition:0 duration:100];       // 点歌词行的前提是 dur>0
        [g_posts removeAllObjects];
        ClickView(lbox.arrangedSubviews[4]);
        Pump(0.02);
        NSArray<NSDictionary *> *seeks = PostsWithPrefix(@"/api/seek");
        Ck(seeks.count == 1, "点歌词行只发一次 /api/seek",
           [g_posts componentsJoinedByString:@" | "]);
        if (seeks.count) {
            NSString *p = seeks.lastObject[@"path"];
            Ck([p isEqualToString:@"/api/seek?pos=0.4000"],
               "seek 用 pos= 且比例 = 该行时刻/时长（web doSeek 同参数名同精度）", p);
            Ck(![p containsString:@"ratio="], "不再发后端不认的 ratio=", p);
        }
        // 该行高亮：跳到 41s 时第 5 行 15px/加粗提亮（web .ly.on）
        [d updatePosition:41 duration:100];
        Pump(0.02);
        NSTextField *l4 = RowLabel(lbox.arrangedSubviews[4]);
        NSTextField *l3 = RowLabel(lbox.arrangedSubviews[3]);
        RLPTheme *t = [RLPTheme current];
        Ck(l4 != nil && fabs(l4.font.pointSize - 15.0) < 0.01, "第 5 行进入高亮态（15px）",
           [NSString stringWithFormat:@"pt=%.1f", l4.font.pointSize]);
        Ck(l3 != nil && fabs(l3.font.pointSize - 13.5) < 0.01, "第 4 行仍是非高亮态（13.5px）",
           [NSString stringWithFormat:@"pt=%.1f", l3.font.pointSize]);
        Ck(l4 != nil && [l4.textColor isEqual:t.text], "高亮行文字色 = --txt", @"");

        // ---- D2a：曲目在别处切到 B（底栏下一首）→ 1s 轮询必须把歌词跟到 B ----
        const NSInteger lyricsBefore = CountPaths(g_gets, @"/api/lyrics?file=");
        g_curIndex = 1;                              // 后端已经播到 B
        Pump(1.15);                                  // 抽屉 1s 轮询
        Pump(0.05);
        const NSInteger lyricsAfter = CountPaths(g_gets, @"/api/lyrics?file=");
        Ck(lyricsAfter > lyricsBefore, "换曲后轮询重拉歌词（/api/lyrics?file=B）",
           [NSString stringWithFormat:@"before=%ld after=%ld", (long)lyricsBefore, (long)lyricsAfter]);
        Ck([g_gets.lastObject[@"path"] containsString:RLPEnc(g_items.lastObject)],
           "重拉的 file = 新当前曲 B", g_gets.lastObject[@"path"] ?: @"");
        Ck(StackHasText(lbox, @"BRAVO"), "歌词内容变成 B", @"仍是 A 的歌词");
        Ck(!StackHasText(lbox, @"ALPHA"), "不再残留 A 的歌词", @"A 的歌词还在");

        // ---- D2b：同一首不重复拉（每秒重拉会把后端打爆，也违反 web 语义）----
        const NSInteger sameTrackBefore = CountPaths(g_gets, @"/api/lyrics?file=");
        Pump(1.15);
        Ck(CountPaths(g_gets, @"/api/lyrics?file=") == sameTrackBefore,
           "当前曲没变时轮询不重拉歌词",
           [NSString stringWithFormat:@"before=%ld after=%ld", (long)sameTrackBefore,
            (long)CountPaths(g_gets, @"/api/lyrics?file=")]);

        // ---- D2c：回到 A，再点队列第 2 行（= 播 B）→ 歌词必须跟到 B ----
        g_curIndex = 0;
        Pump(1.15);
        Ck(StackHasText(lbox, @"ALPHA"), "回到 A 后歌词跟回 A", @"没有回到 A");
        NSStackView *qbox = (NSStackView *)FindById(d, @"right.qlist");
        Ck(qbox != nil && qbox.arrangedSubviews.count == 2, "找得到 2 行队列", @"队列行缺失");
        [g_posts removeAllObjects];
        if (qbox && qbox.arrangedSubviews.count == 2) {
            ClickView(qbox.arrangedSubviews[1]);
            Pump(0.2);
            Ck([PostsWithPrefix(@"/api/play") count] == 1, "点队列行发起 /api/play",
               [g_posts componentsJoinedByString:@" | "]);
            Ck([g_gets.lastObject[@"path"] containsString:RLPEnc(g_items.lastObject)] ||
               CountPaths(g_gets, @"/api/lyrics?file=") > 0,
               "点队列行后重拉歌词", g_gets.lastObject[@"path"] ?: @"");
            Ck(StackHasText(lbox, @"BRAVO"), "点队列切歌后歌词内容变成 B", @"仍是 A 的歌词");
        }

        // ---- D3a：队列清空（!nowPath.length）→ 触发歌词空态并清空残留状态/禁用右键菜单 ----
        g_items = @[ @"/Music/A/A.flac", @"/Music/B/B.flac" ];
        g_curIndex = 0;
        Pump(1.15);
        Ck(StackHasText(lbox, @"ALPHA"), "D3a 前置：回到 A", @"");
        g_items = @[];
        g_cues = @[];
        g_curIndex = -1;
        Pump(1.15);
        Ck(StackHasText(lbox, @"还没有播放曲目"), "D3a 空队列切歌后歌词区显示空态", @"仍残留上一首或空白");
        Ck(!StackHasText(lbox, @"ALPHA"), "D3a 空队列后不再残留 A 的歌词", @"");
        Ck([(NSArray *)[d valueForKey:@"lines"] count] == 0, "D3a 空队列后 lines 清空", @"");
        [(id<NSMenuDelegate>)d menuWillOpen:lbox.menu];
        BOOL anyAiEnabledOnEmpty = NO;
        for (NSMenuItem *it in lbox.menu.itemArray) {
            if (!it.isSeparatorItem && it.enabled) anyAiEnabledOnEmpty = YES;
        }
        Ck(!anyAiEnabledOnEmpty, "D3a 空队列后歌词右键菜单全部禁用", @"仍有启用的菜单项");

        // ---- D3b：网络曲目（http/https）→ 清空残留歌词与 AI 状态，右键菜单禁用 ----
        g_items = @[ @"/Music/A/A.flac", @"/Music/B/B.flac" ];
        g_curIndex = 0;
        Pump(1.15);
        Ck(StackHasText(lbox, @"ALPHA"), "D3b 前置：加载 A 的歌词", @"");
        g_items = @[ @"https://example.com/live.flac" ];
        g_cues = @[ @[ @(-1), @(-1) ] ];
        g_curIndex = 0;
        Pump(1.15);
        Ck(StackHasText(lbox, @"网络曲目暂无歌词"), "D3b 网络曲目显示无歌词提示", @"");
        Ck([(NSArray *)[d valueForKey:@"lines"] count] == 0, "D3b 网络曲目清空 lines", @"");
        [(id<NSMenuDelegate>)d menuWillOpen:lbox.menu];
        BOOL anyAiEnabledOnNet = NO;
        for (NSMenuItem *it in lbox.menu.itemArray) {
            if (!it.isSeparatorItem && it.enabled) anyAiEnabledOnNet = YES;
        }
        Ck(!anyAiEnabledOnNet, "D3b 网络曲目歌词右键菜单全部禁用", @"仍有启用的菜单项");

        // ---- D3c：/api/lyrics 迟到回包不得覆盖新歌 ----
        g_items = @[ @"/Music/A/A.flac", @"/Music/B/B.flac" ];
        g_cues = @[ @[ @(-1), @(-1) ], @[ @(-1), @(-1) ] ];
        g_curIndex = 0;
        g_holdLyrics = YES;
        [g_heldLyrics removeAllObjects];
        Pump(1.15); // 发起 A 的 /api/lyrics（被 hold）
        g_holdLyrics = NO;
        g_curIndex = 1;
        Pump(1.15); // 切到 B，B 的 /api/lyrics 立即返回
        Ck(StackHasText(lbox, @"BRAVO"), "D3c 新歌 B 的歌词先到达并显示", @"");
        if (g_heldLyrics.count) {
            NSDictionary *lateA = g_heldLyrics.firstObject;
            RLPJSONCompletion doneA = lateA[@"done"];
            doneA(lateA[@"resp"]);
            Pump(0.05);
        }
        Ck(StackHasText(lbox, @"BRAVO") && !StackHasText(lbox, @"ALPHA"),
           "D3c 旧歌 A 的迟到 /api/lyrics 回包不得覆盖新歌 B", @"被旧歌覆盖");

        // ---- D3d：旧歌 AI 未完成切歌不锁死新歌，旧 AI 迟到回包被丢弃 ----
        g_curIndex = 0;
        Pump(1.15);
        Ck(StackHasText(lbox, @"ALPHA"), "D3d 前置：回到 A", @"");
        g_holdLyricAi = YES;
        [g_heldLyricAi removeAllObjects];
        [d performSelector:@selector(runLyricAiTask:lang:) withObject:@"translate" withObject:@"en"];
        Ck([[d valueForKey:@"lyricAiBusy"] boolValue] == YES, "D3d A 发起 AI 后进入 busy", @"");
        g_curIndex = 1;
        Pump(1.15); // 切到 B
        Ck([[d valueForKey:@"lyricAiBusy"] boolValue] == NO,
           "D3d 切到新歌 B 后旧歌 AI 不得锁死新歌（lyricAiBusy==NO）", @"仍被旧歌锁死");
        if (g_heldLyricAi.count) {
            RLPJSONCompletion aiDoneA = g_heldLyricAi.firstObject;
            aiDoneA(@{ @"ok": @YES, @"lines": @[ @"OLD_AI_1", @"OLD_AI_2", @"OLD_AI_3", @"OLD_AI_4", @"OLD_AI_5", @"OLD_AI_6" ] });
            Pump(0.05);
        }
        g_holdLyricAi = NO;
        Ck(StackHasText(lbox, @"BRAVO") && !StackHasText(lbox, @"OLD_AI_1"),
           "D3d 旧歌 A 的迟到 AI 回包不得污染新歌 B", @"B 被旧歌 AI 覆盖");

        // ---- D3e：deleteIndex: 发送 RLPQueueChangedNotification ----
        __block NSInteger qChangedCount = 0;
        id qObs = [[NSNotificationCenter defaultCenter] addObserverForName:RLPQueueChangedNotification
                                                                    object:nil
                                                                     queue:[NSOperationQueue mainQueue]
                                                                usingBlock:^(NSNotification *n) {
            (void)n;
            ++qChangedCount;
        }];
        {
            NSMethodSignature *sig = [d methodSignatureForSelector:@selector(deleteIndex:)];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:d];
            [inv setSelector:@selector(deleteIndex:)];
            NSInteger idx0 = 0;
            [inv setArgument:&idx0 atIndex:2];
            [inv invoke];
        }
        Pump(0.05);
        [[NSNotificationCenter defaultCenter] removeObserver:qObs];
        Ck(qChangedCount >= 1, "D3e deleteIndex: 发送 RLPQueueChangedNotification",
           [NSString stringWithFormat:@"count=%ld", (long)qChangedCount]);

        std::printf("结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
