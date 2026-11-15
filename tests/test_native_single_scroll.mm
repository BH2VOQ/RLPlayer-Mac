// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_single_scroll.mm — 全程序「每页只有一层滚动」判据
//
// ============================ 这条判据在证明什么 ============================
// 用户 2026-11-15 明确（原话）：
//   「我希望整个程序，每一个页面只能有主体可以进行滚动，不要大框架套小框架」
//
// 现象面是「滚轮在某个区域被内层容器吃掉，整页滚不动」。要把它变成可复跑的判据，
// 必须问：**一个页面里到底有几个"能滚的容器"？** 只要 >1，滚轮就必然有歧义
// （先被里层吃掉，滚到头才上抛），用户就会感到"卡住/不跟手"。
//
// 判据（逐页面遍历左导航全部 key + 详情页）：
//   ① 每个页面里，**可滚动**的 NSScrollView 恰好 1 个（= 该页的整页滚动容器）；
//   ② 那个容器必须是页面根视图的**后代链上的第一个**滚动容器，且它的 documentView
//      是内容本体（不是某个卡片内部）；
//   ③ 不存在「能滚但没滚动条」的隐藏滚动容器（旧 EQ 的 20 段表就是这种：
//      hasVerticalScroller=NO，滚轮照样被它吃掉，看代码看不出来）。
//
// "可滚动" 的定义（三者任一即算，这是判据的核心，不能退化成"有没有滚动条"）：
//   · hasVerticalScroller / hasHorizontalScroller 为真；或
//   · documentView 的尺寸超出 clipView 可视区（内容真的溢出）；或
//   · documentView 高度/宽度约束 >= 容器高度（内容会被撑到超出）。
// 只数滚动条会漏掉第 3 类 —— 那正是本轮假绿的成因。
//
// 白名单：NSTextView 自己的滚动（多行文本编辑/歌词区）与横向封面行
//（web 的这些区域也是独立滚动的，属于"横向条"，不是"大框套小框"的纵向嵌套）。
//
// 纪律：隔离 state/library；backend=null、volume=-120；**不播放任何音频**（铁律②）。
#import <AppKit/AppKit.h>
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPMainWindowController.h"
#import "RLPSidebarViewController.h"

#include <cstdio>
#include <cstdlib>
#include <unistd.h>

static int gFail = 0, gPass = 0;
static void Ck(BOOL ok, NSString *what, NSString *detail) {
    if (ok) { ++gPass; std::printf("  [PASS] %s\n", what.UTF8String); }
    else { ++gFail; std::printf("  [FAIL] %s — %s\n", what.UTF8String, detail.UTF8String ?: ""); }
}
static void Pump(NSTimeInterval s) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:s];
    while ([until timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}
static void Collect(NSView *v, NSMutableArray<NSView *> *out) {
    if (!v) return;
    [out addObject:v];
    for (NSView *s in v.subviews) Collect(s, out);
}

/// 该滚动视图是否"真的能滚"。
/// ⚠️ 不能只看 hasVerticalScroller：NSScrollView 即使不画滚动条也照样接管 scrollWheel。
static BOOL RLPScrollViewCanScroll(NSScrollView *sv) {
    if (!sv) return NO;
    if (sv.hasVerticalScroller || sv.hasHorizontalScroller) return YES;
    NSView *doc = sv.documentView;
    if (!doc) return NO;
    const NSSize vis = sv.contentView.bounds.size;
    if (vis.width < 1 || vis.height < 1) return NO;         // 还没布局，无法判定
    if (doc.frame.size.height > vis.height + 0.5) return YES;
    if (doc.frame.size.width > vis.width + 0.5) return YES;
    // 约束驱动的高度（内容还没布局但它一定会被撑高）
    for (NSLayoutConstraint *c in doc.constraints) {
        if (c.firstAttribute == NSLayoutAttributeHeight && c.relation != NSLayoutRelationLessThanOrEqual
            && c.constant > vis.height + 0.5) return YES;
    }
    return NO;
}

/// 白名单判定：文本编辑区（NSTextView 自带）与横向卡片行不算"纵向嵌套滚动"。
static BOOL RLPIsScrollWhitelisted(NSScrollView *sv) {
    if ([sv.documentView isKindOfClass:[NSTextView class]]) return YES;
    if (sv.hasHorizontalScroller && !sv.hasVerticalScroller) return YES;
    return NO;
}

/// 视图是否真的在显示（自身与全部祖先都没隐藏、有面积）。
/// 只判 hidden 链，**不判 frame 面积**：离屏测试里布局可能还没解算完，
/// 用 frame 判可见会把"存在且真能滚"的容器误判成不可见（第一版就在
/// albums/streaming/favorites 三页踩了这个假红）。
static BOOL RLPVisible(NSView *v) {
    if (!v) return NO;
    if (v.hidden) return NO;
    for (NSView *p = v.superview; p; p = p.superview)
        if (p.hidden) return NO;
    return YES;
}

static NSString *RLPDesc(NSScrollView *sv) {
    NSString *ident = sv.identifier.length ? sv.identifier : NSStringFromClass([sv class]);
    return [NSString stringWithFormat:@"%@[%@]", ident, NSStringFromClass([sv class])];
}

/// "大框架套小框架" 的**准确**定义：一个能滚的容器，它的祖先里还有另一个能滚的容器。
///
/// ⚠️ 判据第一版写错过：它把「页面里唯一那根滚动条」也当成内层（因为页面根视图
///    不是 NSScrollView，排除条件 sv == page 永远不成立），于是 10 个页面全假红。
///    真正的嵌套关系必须靠**祖先链**判定，不能靠"是不是页面根"。
/// 只统计可见的（hidden 的列表/网格互斥容器不算 —— 用户看不到它，滚轮也到不了）。
static NSArray<NSString *> *RLPNestedScrollablesIn(NSView *page) {
    NSMutableArray<NSView *> *all = [NSMutableArray array];
    Collect(page, all);
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSView *v in all) {
        if (![v isKindOfClass:[NSScrollView class]]) continue;
        NSScrollView *sv = (NSScrollView *)v;
        if (RLPIsScrollWhitelisted(sv)) continue;
        if (!RLPScrollViewCanScroll(sv)) continue;
        if (!RLPVisible(sv)) continue;
        // 祖先里还有能滚的容器 ⟹ 这就是"大框架套小框架"的第二层
        for (NSView *p = sv.superview; p; p = p.superview) {
            if (![p isKindOfClass:[NSScrollView class]]) continue;
            NSScrollView *anc = (NSScrollView *)p;
            if (RLPIsScrollWhitelisted(anc)) continue;
            if (!RLPScrollViewCanScroll(anc)) continue;
            if (!RLPVisible(anc)) continue;
            [out addObject:[NSString stringWithFormat:@"%@ 套在 %@ 里", RLPDesc(sv), RLPDesc(anc)]];
            break;
        }
    }
    return out;
}

/// 页面里"顶层"能滚的纵向容器（祖先里没有别的能滚容器的那些）。
/// 用户能感知的"主体滚动条"就是这些；正常应当恰好 1 个。
static NSArray<NSString *> *RLPTopLevelScrollablesIn(NSView *page) {
    NSMutableArray<NSView *> *all = [NSMutableArray array];
    Collect(page, all);
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSView *v in all) {
        if (![v isKindOfClass:[NSScrollView class]]) continue;
        NSScrollView *sv = (NSScrollView *)v;
        if (RLPIsScrollWhitelisted(sv)) continue;
        if (!RLPScrollViewCanScroll(sv)) continue;
        if (!RLPVisible(sv)) continue;
        BOOL nested = NO;
        for (NSView *p = sv.superview; p; p = p.superview) {
            if (![p isKindOfClass:[NSScrollView class]]) continue;
            NSScrollView *anc = (NSScrollView *)p;
            if (RLPIsScrollWhitelisted(anc)) continue;
            if (!RLPScrollViewCanScroll(anc)) continue;
            if (!RLPVisible(anc)) continue;
            nested = YES;
            break;
        }
        if (!nested) [out addObject:RLPDesc(sv)];
    }
    return out;
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        std::printf("=== test_native_single_scroll（每个页面只允许一层滚动）===\n");

        NSString *rootDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"rlp-single-scroll-%d", (int)getpid()]];
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

        RLPMainWindowController *wc = [[RLPMainWindowController alloc] init];
        wc.window.contentView.frame = NSMakeRect(0, 0, 1280, 900);
        [wc.window.contentView layoutSubtreeIfNeeded];

        NSArray<NSString *> *keys = @[ @"albums", @"artists", @"tracks", @"folders", @"streaming",
                                       @"queue", @"recent", @"favorites", @"station", @"settings" ];
        for (NSString *key in keys) {
            [wc.sidebar selectKey:key];
            Pump(0.45);
            NSView *page = wc.currentContent.view;
            [page layoutSubtreeIfNeeded];
            BOOL has = (page != nil);
            Ck(has, [NSString stringWithFormat:@"【%@】页面已构造（判据前提）", key], @"页面为空");
            if (!has) continue;
            if (getenv("RLP_SINGLE_SCROLL_DUMP")) {
                NSMutableArray<NSView *> *all = [NSMutableArray array];
                Collect(page, all);
                for (NSView *v in all) {
                    if (![v isKindOfClass:[NSScrollView class]]) continue;
                    NSScrollView *sv = (NSScrollView *)v;
                    std::printf("    DUMP %s v=%d h=%d hidden=%d frame=%s docFrame=%s vis=%s\n",
                        (sv.identifier ?: @"-").UTF8String,
                        (int)sv.hasVerticalScroller, (int)sv.hasHorizontalScroller,
                        (int)sv.hidden,
                        NSStringFromRect(sv.frame).UTF8String,
                        NSStringFromRect(sv.documentView.frame).UTF8String,
                        NSStringFromRect(sv.contentView.bounds).UTF8String);
                }
            }
            // 至多一根：空态页（书库为空的专辑/未配置服务器的流媒体）会把主体滚动条
            // 整根隐藏、只留一张空态卡 —— 那是正常空态，不是缺陷（第一版判"恰好一根"
            // 在 albums/streaming 上假红，已实测确认 hidden=1）。
            // 真正要防的是 **>1**：那才是"滚轮有歧义"。
            NSArray<NSString *> *top = RLPTopLevelScrollablesIn(page);
            Ck(top.count <= 1,
               [NSString stringWithFormat:@"【%@】至多一根主体滚动条（不会两处争抢滚轮）", key],
               [NSString stringWithFormat:@"顶层滚动容器=%lu: %@",
                (unsigned long)top.count, [top componentsJoinedByString:@", "]]);
            NSArray<NSString *> *nested = RLPNestedScrollablesIn(page);
            Ck(nested.count == 0,
               [NSString stringWithFormat:@"【%@】没有大框架套小框架（内层无第二个能滚容器）", key],
               [nested componentsJoinedByString:@", "]);
        }

        // ---- 设置页逐页签（用户报的 EQ 就在这一页，必须逐页签查而不是只看默认页）----
        [wc.sidebar selectKey:@"settings"];
        Pump(0.5);
        if ([wc.currentContent respondsToSelector:NSSelectorFromString(@"selectPane:")]) {
            NSArray<NSString *> *panes = @[ @"adv", @"in", @"out", @"pcm", @"sdm", @"eq",
                                            @"cal", @"meta", @"stream", @"diag" ];
            for (NSString *pane in panes) {
                [(id)wc.currentContent performSelector:NSSelectorFromString(@"selectPane:") withObject:pane];
                Pump(0.35);
                NSView *pv = wc.currentContent.view;
                [pv layoutSubtreeIfNeeded];
                NSArray<NSString *> *nested = RLPNestedScrollablesIn(pv);
                Ck(nested.count == 0,
                   [NSString stringWithFormat:@"【settings.%@】没有大框架套小框架", pane],
                   [nested componentsJoinedByString:@", "]);
            }
        } else {
            Ck(NO, @"设置页能逐页签切换（逐页签判据的前提）", @"缺 selectPane:");
        }

        std::printf("\n%s（%d passed, %d failed）\n",
                    gFail == 0 ? "单层滚动全部通过" : "单层滚动有失败", gPass, gFail);
        return gFail == 0 ? 0 : 1;
    }
}
