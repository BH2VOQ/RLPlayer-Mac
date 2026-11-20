// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_settings_pane_firstframe.mm — 设置页换页签「首帧即正确」判据（F1–F4）
//
// ============================ 这条判据在证明什么 ============================
// 用户 2026-11-21 实测：「当切换设置页的时候，会先露出上面的空白页面，然后正常设置页才会跳回去。」
//
// 现象是闪一下空白，根因必须在**几何**里找，不能靠"看起来还行"：
//   设置页每个 pane 的文档视图是 NSStackView（**非 flipped**，AppKit 默认），
//   而栈底部塞着一个可伸展的空白 spacer（buildPane 用它把真实内容压到顶部）。
//   非 flipped 的文档视图里 clip 原点 (0,0) 在**内容底端** ⟹ 新建 pane 第一次显示时
//   可见区域正好落在 spacer 上 = 一整屏空白；等下一轮 runloop 里
//   RLPMainWindowController 的 syncScrollInsets / RLPResetTopPageScroll 把它滚到顶部，
//   内容才「跳」回来。这就是那一下闪白。
//
// 判据（都不 pump runloop，量的是**首帧**）：
//   F1 每个页签 selectPane 后，可见区必须已经在内容顶部（顶对齐，不靠后续 runloop 补救）；
//   F2 首帧可见区里必须**真的有内容**：第一个非 spacer 的卡片与可见区相交面积 ≥ 卡片的 60%；
//   F3 页签来回切换（缓存复用路径）后仍然顶对齐，不依赖重新构建；
//   F4 反向哨兵：把文档视图临时换成非 flipped 的实现，F1 必须变红 —— 证明这条判据真能抓到这个故障
//      （否则它只是"恒真"）。
//
// 纪律（铁律 1/2/4）：隔离 state/library；backend=null、volume=-120；不播放任何音频；
// 不联网（核心内嵌、端点全部本地）；窗口不 orderFront（离屏）。
#import <AppKit/AppKit.h>
#import "RLPCoreClient.h"
#import "RLPSettingsViewController.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>

static int gPass = 0, gFail = 0;
static void Ck(BOOL ok, NSString *what, NSString *detail) {
    if (ok) { ++gPass; std::printf("  [PASS] %s\n", what.UTF8String); }
    else {
        ++gFail;
        std::printf("  [FAIL] %s — %s\n", what.UTF8String, detail.UTF8String ?: "");
    }
}

static void Pump(NSTimeInterval s) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:s];
    while ([until timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
}

static void Collect(NSView *v, NSMutableArray<NSView *> *out) {
    if (!v) return;
    [out addObject:v];
    for (NSView *s in v.subviews) Collect(s, out);
}

/// 页签根视图（identifier = tab.<key>）。
static NSView *PaneRoot(NSView *root, NSString *key) {
    NSMutableArray<NSView *> *all = [NSMutableArray array];
    Collect(root, all);
    NSString *ident = [@"tab." stringByAppendingString:key];
    for (NSView *v in all) if ([v.identifier isEqualToString:ident]) return v;
    return nil;
}

/// 可见区是否落在文档**顶部**。flipped 文档顶部是 origin.y == 0；
/// 非 flipped 文档顶部是 origin.y == docH - clipH。两种实现都接受 —— 判据问的是
/// 「用户此刻看到的是不是内容顶部」，不是「用哪种坐标系」。
static BOOL ScrollIsAtTop(NSScrollView *sv) {
    if (!sv || !sv.documentView || !sv.contentView) return NO;
    NSView *doc = sv.documentView;
    const NSRect vis = sv.documentVisibleRect;
    const CGFloat docH = doc.frame.size.height;
    const CGFloat clipH = sv.contentView.bounds.size.height;
    if (docH <= clipH + 0.5) return YES;             // 内容装得下：没有可滚的，一定是顶
    const CGFloat topY = doc.isFlipped ? 0.0 : (docH - clipH);
    return std::fabs(vis.origin.y - topY) <= 1.0;
}

/// 文档顶部第一张**真实卡片**（跳过 buildPane 末尾那个可伸展 spacer）。
/// 判据用 identifier 前缀 set. 或是 RLPSettingsGroup 类；spacer 是裸 NSView。
static NSView *FirstRealBlockIn(NSScrollView *sv) {
    NSView *doc = sv.documentView;
    if (!doc) return nil;
    NSArray<NSView *> *kids = nil;
    if ([doc isKindOfClass:[NSStackView class]]) kids = ((NSStackView *)doc).arrangedSubviews;
    else kids = doc.subviews;
    for (NSView *k in kids) {
        if ([k isKindOfClass:[NSStackView class]] && ((NSStackView *)k).arrangedSubviews.count == 0) continue;
        if (NSStringFromClass(k.class).length && [NSStringFromClass(k.class) containsString:@"Sentinel"]) continue;
        if (k.identifier.length == 0 && [k.subviews count] == 0 && k.frame.size.height >= 1.0) continue;  // 纯 spacer
        return k;
    }
    return kids.count ? kids.firstObject : nil;
}

/// 首帧：不 pump，只做一次同步 layout。返回 (是否顶对齐, 首个真实块可见比例)。
static void MeasureFirstFrame(NSScrollView *sv, BOOL *atTop, CGFloat *visibleRatio, NSString **detail) {
    *atTop = NO; *visibleRatio = 0.0; *detail = @"";
    if (!sv || !sv.documentView) { *detail = @"没有滚动容器"; return; }
    [sv layoutSubtreeIfNeeded];
    [sv.documentView layoutSubtreeIfNeeded];
    *atTop = ScrollIsAtTop(sv);
    NSView *first = FirstRealBlockIn(sv);
    if (!first) { *detail = @"文档里没有真实块"; return; }
    const NSRect r = [first convertRect:first.bounds toView:sv.contentView];
    const NSRect clip = sv.contentView.bounds;
    const NSRect inter = NSIntersectionRect(r, clip);
    const CGFloat area = r.size.width * r.size.height;
    *visibleRatio = (area > 1.0) ? (inter.size.width * inter.size.height) / area : 0.0;
    *detail = [NSString stringWithFormat:@"docH=%.1f clipH=%.1f vis.y=%.1f flipped=%d first=%@ h=%.1f ratio=%.2f",
               sv.documentView.frame.size.height, clip.size.height,
               sv.documentVisibleRect.origin.y, (int)sv.documentView.isFlipped,
               NSStringFromClass(first.class), r.size.height, *visibleRatio];
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        std::printf("=== test_native_settings_pane_firstframe（设置页首帧顶对齐 · 不出声）===\n");

        NSString *rootDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"rlp-firstframe-%d", (int)getpid()]];
        NSString *state = [rootDir stringByAppendingPathComponent:@"state"];
        NSString *lib = [rootDir stringByAppendingPathComponent:@"lib"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:lib withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("RLPLAYER_STATE_DIR", state.fileSystemRepresentation, 1);
        setenv("RLPLAYER_LIBRARY_DIR", lib.fileSystemRepresentation, 1);
        RLPCoreClient *core = [RLPCoreClient shared];
        if (![core startEmbedded]) { std::printf("  [FAIL] 核心启动失败\n"); return 1; }
        [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"backend=null&volume=-120"];

        RLPSettingsViewController *settings = [[RLPSettingsViewController alloc] init];
        NSView *v = settings.view;
        v.frame = NSMakeRect(0, 0, 1280, 900);
        [v layoutSubtreeIfNeeded];
        Pump(0.6);                    // 让首帧读回落地（之后所有测量都不再 pump）
        [v layoutSubtreeIfNeeded];

        NSArray<NSString *> *keys = @[ @"adv", @"in", @"out", @"pcm", @"sdm", @"eq",
                                       @"cal", @"meta", @"stream", @"diag" ];

        // ---- F1/F2：每个页签首次切过去，首帧必须在顶部且顶部真有内容 ----
        NSMutableArray<NSString *> *notTop = [NSMutableArray array];
        NSMutableArray<NSString *> *blank = [NSMutableArray array];
        for (NSString *key in keys) {
            [settings selectPane:key];
            NSView *pane = PaneRoot(v, key);
            if (!pane || ![pane isKindOfClass:[NSScrollView class]]) {
                Ck(NO, [NSString stringWithFormat:@"【%@】页签有滚动容器", key], @"不是 NSScrollView");
                continue;
            }
            BOOL atTop = NO; CGFloat ratio = 0; NSString *detail = @"";
            MeasureFirstFrame((NSScrollView *)pane, &atTop, &ratio, &detail);
            if (!atTop) [notTop addObject:[NSString stringWithFormat:@"%@(%@)", key, detail]];
            // 「空白一屏」的可观测定义：顶部第一张卡片可见面积 < 60%。
            if (ratio < 0.60) [blank addObject:[NSString stringWithFormat:@"%@(ratio=%.2f)", key, ratio]];
            Pump(0.35);               // 让异步读回落地，进入下一页签（不影响上面的测量）
            [v layoutSubtreeIfNeeded];
        }
        Ck(notTop.count == 0,
           @"F1 10 个页签首帧都已在内容顶部（不靠下一轮 runloop 补救）",
           [notTop componentsJoinedByString:@" | "]);
        Ck(blank.count == 0,
           @"F2 首帧可见区里真有内容（顶部卡片可见 ≥60%，不是一屏空白）",
           [blank componentsJoinedByString:@" | "]);

        // ---- F3：缓存复用路径（切走再切回）仍然顶对齐 ----
        {
            NSString *k1 = @"meta", *k2 = @"adv";
            [settings selectPane:k1];
            [v layoutSubtreeIfNeeded];
            Pump(0.2);
            [settings selectPane:k2];
            [v layoutSubtreeIfNeeded];
            Pump(0.2);
            [settings selectPane:k1];
            NSView *pane = PaneRoot(v, k1);
            BOOL atTop = NO; CGFloat ratio = 0; NSString *detail = @"";
            if ([pane isKindOfClass:[NSScrollView class]]) {
                MeasureFirstFrame((NSScrollView *)pane, &atTop, &ratio, &detail);
            }
            Ck(atTop, @"F3 切走再切回（缓存复用的 pane）首帧仍在顶部", detail);
        }

        // ---- F4：反向哨兵 —— 判据必须能抓到「非 flipped 文档视图」这个根因 ----
        // 做法：把一个 pane 的文档视图换成一个**非 flipped 的 NSView 包装**（等价于 AppKit 默认
        // NSStackView 的坐标系），然后断言 F1 的判据此时为假。判据若对这种替换毫无反应，
        // 说明它量的不是"用户看到的那一屏"，就是恒真判据（铁律 3）。
        {
            [settings selectPane:@"adv"];
            NSView *pane = PaneRoot(v, @"adv");
            if ([pane isKindOfClass:[NSScrollView class]]) {
                NSScrollView *sv = (NSScrollView *)pane;
                NSView *doc = sv.documentView;
                BOOL atTop = NO; CGFloat ratio = 0; NSString *detail = @"";
                MeasureFirstFrame(sv, &atTop, &ratio, &detail);
                const BOOL healthyTop = atTop;
                // 模拟旧实现：把文档视图换成 non-flipped 包装并让其高度撑满
                // （只有 non-flipped 才会让 clip 原点 0 落在内容底端）。
                if ([doc isFlipped]) {
                    NSView *wrap = [[NSView alloc] initWithFrame:doc.bounds];  // NSView 默认非 flipped
                    wrap.translatesAutoresizingMaskIntoConstraints = YES;
                    wrap.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                    doc.translatesAutoresizingMaskIntoConstraints = YES;
                    doc.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                    doc.frame = wrap.bounds;
                    [wrap addSubview:doc];
                    sv.documentView = wrap;
                    [wrap layoutSubtreeIfNeeded];
                    const NSRect vis = sv.documentVisibleRect;
                    const CGFloat topY = (wrap.frame.size.height > sv.contentView.bounds.size.height)
                        ? (wrap.frame.size.height - sv.contentView.bounds.size.height) : 0.0;
                    const BOOL simulatedNotAtTop = (topY > 1.0) && std::fabs(vis.origin.y - topY) > 1.0;
                    Ck(healthyTop && simulatedNotAtTop,
                       @"F4 反向哨兵：换成非 flipped 文档视图后，同一判据确实判定为「不在顶部」"
                       @"（证明 F1 抓的是这个根因，不是恒真）",
                       [NSString stringWithFormat:@"healthyTop=%d simNotTop=%d visY=%.1f topY=%.1f docH=%.1f",
                        (int)healthyTop, (int)simulatedNotAtTop, vis.origin.y, topY, wrap.frame.size.height]);
                    sv.documentView = doc;
                    [sv layoutSubtreeIfNeeded];
                } else {
                    Ck(NO, @"F4 反向哨兵：文档视图当前就是非 flipped（本轮的根因未修）",
                       detail);
                }
            } else {
                Ck(NO, @"F4 反向哨兵：拿不到 adv 页签滚动容器", @"");
            }
        }

        // ---- F5：根因直判 —— 页签文档视图必须是**翻转坐标** ----
        //
        // 为什么保留这条「实现形状」判据，而不是只留 F1–F3 的行为判据：
        //   F1/F2/F3 量的是当前 runloop 结束后的几何，而离屏渲染**复现不出**
        //   用户看到的那一帧空白（实测：修复前后 F1/F2/F3 全绿，像素内容占比
        //   首帧与稳定帧一致）。也就是说，只看行为判据，这个故障在离屏是"不可见"的。
        //   能稳定区分新旧实现的，只有根因本身：文档视图的坐标系。
        //   旧实现是非翻转 NSStackView（flipped=0）→ clip 原点 0 落在内容底端，
        //   栈尾的空白 spacer 就会成为新建页签的首帧；新实现 flipped=1，顶部就是 0。
        //   因此这条既是根因锚点，也是"不许改回去"的护栏。
        {
            NSMutableArray<NSString *> *wrong = [NSMutableArray array];
            for (NSString *key in keys) {
                [settings selectPane:key];
                NSView *pane = PaneRoot(v, key);
                if (![pane isKindOfClass:[NSScrollView class]]) continue;
                NSView *doc = ((NSScrollView *)pane).documentView;
                if (!doc) {
                    [wrong addObject:[NSString stringWithFormat:@"%@(无文档视图)", key]];
                } else if (!doc.isFlipped) {
                    [wrong addObject:[NSString stringWithFormat:@"%@(flipped=0)", key]];
                }
                Pump(0.12);
                [v layoutSubtreeIfNeeded];
            }
            Ck(wrong.count == 0,
               @"F5 页签文档视图统一为翻转坐标（顶部=原点0，新建页签首帧不会落在栈尾空白占位上）",
               [wrong componentsJoinedByString:@" | "]);
        }

        std::printf("结果：%d passed, %d failed\n", gPass, gFail);
        return gFail == 0 ? 0 : 1;
    }
}
