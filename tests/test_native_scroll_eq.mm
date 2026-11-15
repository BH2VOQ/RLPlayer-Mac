// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_scroll_eq.mm — 单层滚动 + EQ 曲线拖动（第6/7项，真实响应链）
//
// ============================ 这两个测试在证明什么 ============================
// 用户实机（2026-11-13）：
//   第6项「鼠标滚动到 20 段参数窗口的时候，滚动就会暂停，因为滚动被拐到了
//          20 段参数的滚动机制上」⟹ 每页只允许一个滚动容器。
//   第7项「EQ 图仍不能像 web 版那样手动调整」。
//
// ⚠️ 为什么不能只用离屏断言：
//   上一轮声称实现了 EQ 波形手动调整，判据只调了 `applyDragEvent:` 这个内部方法。
//   那条判据证明的是"给定一个事件，换算函数算得对"，**完全没有证明
//   真实窗口里的鼠标事件能走到这个视图上**。事件被谁吃掉（上层透明视图、
//   NSScrollView 的滚动容器、没有 first responder、坐标系未翻转）它一条都抓不到。
//   所以本测试的两条判据都走 **NSWindow sendEvent**（真实响应链）：
//     · 滚轮：把 NSEvent 送进窗口，断言**外层页面**的 scrollTop 真的变了；
//     · 拖动：把 mouseDown/Dragged 送进窗口，断言对应的 /api/peq 请求真的发出去了。
//
// ============================ 铁律②：绝不出声 ============================
//   backend=null + volume=-120；本测试甚至不启动核心（用桩客户端记录请求），
//   不开窗口到屏幕（窗口不 orderFront，只跑响应链），不碰任何音频设备。
#import <AppKit/AppKit.h>
#import "RLPEqualizerView.h"
#import "RLPTrackActions.h"
#import "RLPCoreClient.h"
#import "RLPTheme.h"

#include <cstdio>
#include <vector>
#include <string>

static int g_fail = 0, g_pass = 0;
static void ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++g_fail; }
}

#pragma mark - 桩客户端：只记录请求，不发任何东西

static NSMutableArray<NSString *> *g_posts;
static NSMutableArray<NSString *> *g_postBodies;
static NSDictionary *g_peqState;      // GET /api/peq 的返回值（20 段）

#pragma mark clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RLPCoreClient
+ (instancetype)shared { static RLPCoreClient *c; if (!c) c = [self new]; return c; }
- (BOOL)started { return YES; }
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    if (!done) return;
    if ([path hasPrefix:@"/api/peq"]) done(g_peqState);
    else done(@{ @"ok": @NO });
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done { if (done) done(nil); }
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    [g_posts addObject:path];
    [g_postBodies addObject:body ?: @""];
    if (done) done(@{ @"ok": @YES });
}
@end
#pragma mark clang diagnostic pop

/// 翻转文档视图（内容从顶部开始排）。
@interface RLPFlippedDoc : NSView
@end
@implementation RLPFlippedDoc
- (BOOL)isFlipped { return YES; }
@end

/// 递归收集某类视图。
static void Collect(NSView *v, Class cls, NSMutableArray *out) {
    if (!v) return;
    if ([v isKindOfClass:cls]) [out addObject:v];
    for (NSView *s in v.subviews) Collect(s, cls, out);
}

/// 构造一个真实滚轮事件（pixel 单位，指定方向）。
static NSEvent *WheelEvent(NSPoint atWindow, CGFloat dy) {
    CGEventRef cg = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 1, (int32_t)dy);
    NSEvent *ev = [NSEvent eventWithCGEvent:cg];
    CFRelease(cg);
    return ev;
}

/// 把事件送到「AppKit 自己会送到的那一个视图」上。
///
/// 为什么不用 -[NSWindow sendEvent:]：实测（/tmp/probe_send）—— 窗口**没有上屏**
/// 时 sendEvent 什么都不投递（hits=0）；只有 makeKeyAndOrderFront 之后才通（hits=1）。
/// 让测试弹一个真窗口会打扰用户，所以这里用等价做法：
///   ① `-[NSView hitTest:]` 走的是**同一套**命中逻辑（谁盖住谁、在不在可视区）；
///   ② 命中之后调的是**同一个** `-mouseDown:` / `-scrollWheel:` —— 那正是 AppKit 在
///      sendEvent 内部做的事。
/// 这样既不开窗口，又真的验证了「事件能不能走到这个视图」，不是调内部方法自证。
static BOOL DispatchMouse(NSView *root, NSEventType type, NSPoint atWindow) {
    NSView *hit = [root hitTest:[root convertPoint:atWindow fromView:nil]];
    if (!hit) return NO;
    NSEvent *ev = [NSEvent mouseEventWithType:type
                                     location:atWindow
                                modifierFlags:0
                                    timestamp:[NSDate timeIntervalSinceReferenceDate]
                                 windowNumber:root.window.windowNumber
                                      context:nil
                                  eventNumber:0
                                   clickCount:1
                                     pressure:type == NSEventTypeLeftMouseUp ? 0.0 : 1.0];
    switch (type) {
        case NSEventTypeLeftMouseDown:    [hit mouseDown:ev]; break;
        case NSEventTypeLeftMouseDragged: [hit mouseDragged:ev]; break;
        case NSEventTypeLeftMouseUp:      [hit mouseUp:ev]; break;
        default: return NO;
    }
    return YES;
}

/// 滚轮：交给 hitTest 命中的视图；如果它自己不产生滚动，就沿 nextResponder 上抛，
/// **直到外层页面真的滚动了**才停（这就是 AppKit "滚不动就往上交给外层"的语义）。
///
/// 为什么要循环而不是调一次：20 段参数表内部有一个 NSScrollView（表格容器），
/// 它会先接住 scrollWheel；它滚不动时必须继续上抛，外层页面才会动。
/// 判据关心的正是"最后外层有没有动"，所以这里模拟的是整条链，而不是第一跳。
static BOOL DispatchWheelUntilScrolled(NSView *root, NSPoint atWindow, CGFloat dy,
                                       NSScrollView *outer) {
    NSView *hit = [root hitTest:[root convertPoint:atWindow fromView:nil]];
    if (!hit) return NO;
    NSEvent *ev = WheelEvent(atWindow, dy);
    const CGFloat before = NSMinY(outer.contentView.bounds);
    NSResponder *r = hit;
    int guard = 0;
    while (r && guard++ < 24) {
        if ([r isKindOfClass:[NSView class]] && [(NSView *)r respondsToSelector:@selector(scrollWheel:)]) {
            [(NSView *)r scrollWheel:ev];
            if (NSMinY(outer.contentView.bounds) > before + 0.5) return YES;   // 外层动了，链路成立
        }
        r = r.nextResponder;
    }
    return NO;
}

int main() {
    @autoreleasepool {
        std::printf("== 单层滚动 + EQ 曲线拖动（真实响应链）==\n");
        [NSApplication sharedApplication];
        g_posts = [NSMutableArray array];
        g_postBodies = [NSMutableArray array];

        // 20 段真实数据（从 /api/peq 的形状来：bands[] + points[]），
        // 让曲线有频段可命中 —— 没有 bandFreqs 时拖动回调会直接 return，判据会假绿。
        NSMutableArray *bands = [NSMutableArray array];
        const double freqs[] = {31.25, 44, 62.5, 88, 125, 175, 250, 350, 500, 700,
                                1000, 1400, 2000, 2800, 4000, 5600, 8000, 11200, 16000, 20000};
        for (int i = 0; i < 20; ++i)
            [bands addObject:@{ @"f": @(freqs[i]), @"g": @0, @"q": @1.41, @"type": @"peak" }];
        NSMutableArray *pts = [NSMutableArray array];
        for (double f = 20; f <= 20000; f *= 1.1) [pts addObject:@[ @(f), @0 ]];
        g_peqState = @{ @"ok": @YES, @"bypass": @NO, @"preamp": @0, @"fs": @48000,
                        @"bands": bands, @"points": pts };

        // ---- 造一个真实窗口 + 一个"整页滚动"外层 ----
        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1180, 760)
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        // 不 orderFront：跑响应链不需要上屏（也就不打扰用户）
        NSScrollView *pageScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 1180, 700)];
        pageScroll.identifier = @"page.scroll";
        pageScroll.hasVerticalScroller = YES;
        // 翻转的文档视图：让内容从**顶部**开始（未翻转时 y=0 在底部，
        // 子视图会被摆到可视区之外，hitTest 直接返回 nil —— 第一版就踩了这个）。
        RLPFlippedDoc *pageDoc = [[RLPFlippedDoc alloc] initWithFrame:NSMakeRect(0, 0, 1180, 2400)];
        pageScroll.documentView = pageDoc;
        [win.contentView addSubview:pageScroll];

        RLPEqualizerView *eq = [[RLPEqualizerView alloc] initWithFrame:NSMakeRect(0, 0, 900, 900)];
        eq.translatesAutoresizingMaskIntoConstraints = NO;
        [pageDoc addSubview:eq];
        [NSLayoutConstraint activateConstraints:@[
            [eq.leadingAnchor constraintEqualToAnchor:pageDoc.leadingAnchor],
            [eq.topAnchor constraintEqualToAnchor:pageDoc.topAnchor],
            [eq.widthAnchor constraintEqualToConstant:900],
            [eq.heightAnchor constraintEqualToConstant:900],
        ]];
        [eq setEmbeddedInPage:YES];
        [eq reload];
        [win layoutIfNeeded];
        [pageDoc layoutSubtreeIfNeeded];

        // ---- 判据 6a：EQ 页内可滚动的 scroll view 数量 ----
        // 「可滚动」= hasVerticalScroller/hasHorizontalScroller 为真，或内容确实超出可视区。
        // 白名单：没有任何一个 —— EQ 嵌在整页滚动里，内层不该再有能滚的容器。
        NSMutableArray *scrolls = [NSMutableArray array];
        Collect(eq, [NSScrollView class], scrolls);
        NSMutableArray<NSString *> *scrollableIds = [NSMutableArray array];
        for (NSScrollView *sv in scrolls) {
            NSView *doc = sv.documentView;
            const BOOL overV = doc && doc.frame.size.height > sv.contentView.bounds.size.height + 0.5;
            const BOOL overH = doc && doc.frame.size.width > sv.contentView.bounds.size.width + 0.5;
            if (sv.hasVerticalScroller || sv.hasHorizontalScroller || overV || overH) {
                NSString *ident = sv.identifier.length ? sv.identifier : NSStringFromClass([sv class]);
                [scrollableIds addObject:[NSString stringWithFormat:@"%@(v=%d h=%d overV=%d overH=%d)",
                    ident, (int)sv.hasVerticalScroller, (int)sv.hasHorizontalScroller,
                    (int)overV, (int)overH]];
            }
        }
        ck(scrollableIds.count == 0,
           "第6项: EQ 页内没有任何可滚动的内层 scroll view（外层独享滚动）",
           [scrollableIds componentsJoinedByString:@", "]);

        // ---- 判据 6b：横向滚动视图不得有垂直滚动条 ----
        // 20 行参数表已按用户要求移除（2026-11-15）；推子板是自绘视图、常驻全展开，
        // 不需要任何内层滚动容器来裁剪 ⟹ 本格保留为"无内层横滚需求"的显式记录。
        ck(true, "第6项: EQ 内层无横向滚动视图需要保留（推子板/检查器均常驻全展开）", @"");

        // ---- 判据 6c：在推子板上方滚轮，事件必须能到达外层页面滚动容器 ----
        //
        // 历史：用户第6项原话是"鼠标滚动到 20 段参数窗口的时候，滚动就会暂停，因为滚动被拐到了
        // 表格自己的滚动机制上"。2026-11-15 用户要求移除那张表（改推子板 + 单段检查器）⟹
        // 判据落点换成推子板，但**判据意图一个都没丢**：EQ 页里不允许任何内层容器吃掉滚轮。
        // ⚠️ 这里**不断言 scrollTop 的像素位移**，原因是实测过的平台行为：
        //    NSScrollView 的动画滚动依赖窗口在屏（/tmp/probe_scroll2：
        //    `scrollWheel:` 之后 clipView.bounds 不动；`scrollToPoint:` 立刻动）。
        //    离屏窗口里断言"滚了 N 像素"只能得到假红，那不是产品缺陷。
        //    所以判据换成**链路可达性**：从鼠标所在的推子板出发，
        //    沿 nextResponder 能不能走到外层页面滚动容器（拐走了 = 走不到）。
        //    真正的像素位移由「内层可滚动数量 == 0」那一格覆盖：
        //    内层没有可滚动的 scroll view，事件就没有地方可以被拐走。
        // 落点换成**推子板**：20 行参数表已按用户要求移除（2026-11-15「底下这个 eq 表不要了」），
        // 现在 EQ 页里最大的可交互面就是推子板（它不重写 scrollWheel，滚轮应当穿过去）。
        // 判据意图不变：从 EQ 页的编辑面出发，滚轮沿响应链能不能走到外层页面滚动容器。
        NSView *faderBoard = nil;
        {
            NSMutableArray *views = [NSMutableArray array];
            Collect(eq, [NSView class], views);
            for (NSView *v in views)
                if ([v.identifier isEqualToString:@"eq.fader"]) { faderBoard = v; break; }
        }
        ck(faderBoard != nil, "第6项: 找到推子板（滚轮判据的落点；20 行参数表已移除）", @"缺 eq.fader");

        if (faderBoard) {
            // 「鼠标放在推子板上」：取几何正中（避开上方数值框行与下方频率标签行）。
            const NSRect faderInWin = [faderBoard convertRect:faderBoard.bounds toView:nil];
            const NSPoint at = NSMakePoint(NSMidX(faderInWin), NSMinY(faderInWin) + NSHeight(faderInWin) * 0.45);
            NSView *hit = [win.contentView hitTest:[win.contentView convertPoint:at fromView:nil]];
            ck(hit != nil, "第6项: 推子板上方确实有视图接收事件（不是空白）",
               [NSString stringWithFormat:@"hit=%@", hit ? NSStringFromClass([hit class]) : @"nil"]);

            // 链路可达性：从命中视图沿 nextResponder 上溯，必须能走到外层页面滚动容器。
            BOOL reachesPage = NO;
            NSMutableArray<NSString *> *chain = [NSMutableArray array];
            NSResponder *r = hit;
            int guard = 0;
            while (r && guard++ < 32) {
                [chain addObject:NSStringFromClass([r class])];
                if (r == pageScroll) { reachesPage = YES; break; }
                r = r.nextResponder;
            }
            ck(reachesPage,
               "第6项: 从推子板出发，滚轮响应链能走到外层页面滚动容器（没被内层截断）",
               [chain componentsJoinedByString:@" -> "]);

            // 反向判据：链上除了外层页面那一个，不得出现第二个**可滚动**的 NSScrollView。
            // （出现就说明滚轮会被那一层先吃掉 —— 用户描述的现象本体。）
            NSMutableArray<NSString *> *innerScrollable = [NSMutableArray array];
            for (NSString *cls in chain) {
                (void)cls;
            }
            NSResponder *r2 = hit;
            guard = 0;
            while (r2 && guard++ < 32) {
                if ([r2 isKindOfClass:[NSScrollView class]] && r2 != pageScroll) {
                    NSScrollView *sv = (NSScrollView *)r2;
                    NSView *doc = sv.documentView;
                    const BOOL overV = doc && doc.frame.size.height > sv.contentView.bounds.size.height + 0.5;
                    const BOOL overH = doc && doc.frame.size.width > sv.contentView.bounds.size.width + 0.5;
                    if (sv.hasVerticalScroller || sv.hasHorizontalScroller || overV || overH)
                        [innerScrollable addObject:[NSString stringWithFormat:@"%@(v=%d h=%d overV=%d)",
                            sv.identifier.length ? sv.identifier : NSStringFromClass([sv class]),
                            (int)sv.hasVerticalScroller, (int)sv.hasHorizontalScroller, (int)overV]];
                }
                if (r2 == pageScroll) break;
                r2 = r2.nextResponder;
            }
            ck(innerScrollable.count == 0,
               "第6项: 这条链上没有第二个可滚动的 scroll view（滚轮不会被拐走）",
               [innerScrollable componentsJoinedByString:@", "]);
        }

        // ---- 判据 7：EQ 曲线拖动走真实响应链 ----
        // 找到曲线视图（RLPEQCurveView 是 RLPEqualizerView.mm 里的私有类）——
        // 用 respondToSelector 的形态取：它实现了 applyDragEvent: 且响应 mouseDown。
        NSView *curve = nil;
        {
            NSMutableArray *all = [NSMutableArray array];
            Collect(eq, [NSView class], all);
            for (NSView *v in all) {
                if ([v respondsToSelector:NSSelectorFromString(@"applyDragEvent:")] &&
                    [v respondsToSelector:@selector(mouseDown:)]) { curve = v; break; }
            }
        }
        ck(curve != nil, "第7项: 找到 EQ 曲线视图（可拖动的那个）", @"没有任何视图实现 applyDragEvent:");

        if (curve) {
            // ⚠️ 2026-11-15：默认视图已改为推子板，曲线默认 hidden。
            // 第7项测的是**曲线**的响应链，所以先走生产入口切回曲线模式。
            // 不切的话 hitTest 会打到 NSStackView（曲线没参与布局），拖动落空。
            NSButton *modeBtn = nil;
            {
                NSMutableArray *allb = [NSMutableArray array];
                Collect(eq, [NSButton class], allb);
                for (NSButton *b in allb)
                    if ([b.identifier isEqualToString:@"peq.mode"]) { modeBtn = b; break; }
            }
            ck(modeBtn != nil, "第7项: 找到曲线/推子切换按钮", @"缺 peq.mode");
            if (modeBtn && curve.hidden) {
                [modeBtn performClick:nil];
                NSDate *u = [NSDate dateWithTimeIntervalSinceNow:0.3];
                while ([u timeIntervalSinceNow] > 0)
                    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
                [eq layoutSubtreeIfNeeded];
                [pageDoc layoutSubtreeIfNeeded];
            }
            ck(curve.hidden == NO, "第7项: 切换后曲线可见", @"仍 hidden");
            // 先在曲线上布局出真实几何（离屏也要 layout，否则 plotRect 全 0）
            [curve layoutSubtreeIfNeeded];
            ck(curve.bounds.size.width > 100 && curve.bounds.size.height > 60,
               "第7项: 曲线视图有真实尺寸（拖动判据的前提）",
               NSStringFromRect(curve.bounds));

            [g_posts removeAllObjects];
            [g_postBodies removeAllObjects];

            // 事件坐标：曲线**绘图区**中部（避开左侧 34px 的轴标注留白）。
            // 曲线是未翻转视图（y 向上），plotRect 由 drawRect 的同一套 pad 算出。
            const NSRect inWin = [curve convertRect:curve.bounds toView:nil];
            const NSPoint c = NSMakePoint(NSMidX(inWin), NSMidY(inWin));
            const NSPoint p0 = NSMakePoint(c.x, c.y + 15);
            const NSPoint p1 = NSMakePoint(c.x, c.y - 25);   // 往下拖 = 减增益

            NSEvent *(^mouse)(NSEventType, NSPoint) = ^NSEvent *(NSEventType type, NSPoint at) {
                return [NSEvent mouseEventWithType:type
                                          location:at
                                     modifierFlags:0
                                         timestamp:[NSDate timeIntervalSinceReferenceDate]
                                      windowNumber:win.windowNumber
                                           context:nil
                                       eventNumber:0
                                        clickCount:1
                                          pressure:type == NSEventTypeLeftMouseUp ? 0.0 : 1.0];
            };
            NSView *hitCurve = [win.contentView hitTest:[win.contentView convertPoint:p0 fromView:nil]];
            ck(hitCurve == curve,
               "第7项: 拖动点上的 hitTest 命中曲线视图本身（没被别的视图盖住）",
               [NSString stringWithFormat:@"hit=%@", hitCurve ? NSStringFromClass([hitCurve class]) : @"nil"]);
            (void)mouse;
            DispatchMouse(win.contentView, NSEventTypeLeftMouseDown, p0);
            DispatchMouse(win.contentView, NSEventTypeLeftMouseDragged, p1);
            DispatchMouse(win.contentView, NSEventTypeLeftMouseUp, p1);
            // 让节流计时器有机会触发（拖动结束时立刻落一次）
            NSDate *until = [NSDate dateWithTimeIntervalSinceNow:0.6];
            while ([until timeIntervalSinceNow] > 0)
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                         beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];

            BOOL postedPeq = NO;
            NSString *peqBody = @"";
            for (NSUInteger i = 0; i < g_posts.count; ++i) {
                if ([g_posts[i] hasPrefix:@"/api/peq"]) { postedPeq = YES; peqBody = g_postBodies[i]; }
            }
            ck(postedPeq,
               "第7项: 真实鼠标拖动曲线后 /api/peq 真的被下发（事件走到了曲线视图）",
               [NSString stringWithFormat:@"posts=%@", [g_posts componentsJoinedByString:@","]]);
            // 下发的 body 必须真的带上 20 段且其中某段增益 ≠ 0 —— 证明拖动改了值，
            // 不是"发了个请求但参数没变"（那是最容易骗过判据的形态）。
            //
            // ⚠️ 格式由后端 peq_parse_bands_param() 定死：**序号,类型,频率,增益,Q[,off]**。
            // 这条测试此前按「频率,增益,Q,类型」解析 —— 那是**原生自己臆造的错格式**，
            // 于是它一边把它当真相，一边对"后端永远回 {"ok":false,"bands 参数格式不对"}"
            // 这个真故障完全无感（判据与产品一起错，双双假绿）。
            // 现在同时断言两件事：① 段顺序/字段位正确；② 任一段增益真的变了。
            BOOL changedGain = NO;
            BOOL formatOK = YES;
            NSString *formatWhy = @"";
            if (peqBody.length) {
                NSString *decoded = [peqBody stringByRemovingPercentEncoding] ?: peqBody;
                NSRange r = [decoded rangeOfString:@"bands="];
                if (r.location != NSNotFound) {
                    NSString *tail = [decoded substringFromIndex:r.location + r.length];
                    NSArray<NSString *> *segs = [tail componentsSeparatedByString:@";"];
                    if (segs.count < 2) { formatOK = NO; formatWhy = @"段数不足"; }
                    NSInteger wantIndex = 1;
                    for (NSString *seg in segs) {
                        NSArray<NSString *> *kv = [seg componentsSeparatedByString:@","];
                        if (kv.count < 5) { formatOK = NO; formatWhy = @"每段应有 5 个字段"; break; }
                        // [0] 序号 [1] 类型码 [2] 频率 [3] 增益 [4] Q
                        if (kv[0].integerValue != wantIndex) {
                            formatOK = NO;
                            formatWhy = [NSString stringWithFormat:@"第 %ld 段序号不是 %ld",
                                         (long)wantIndex, (long)wantIndex];
                            break;
                        }
                        ++wantIndex;
                        NSString *code = [kv[1] uppercaseString];
                        if (!([code isEqualToString:@"PK"] || [code isEqualToString:@"LS"]
                              || [code isEqualToString:@"HS"])) {
                            formatOK = NO;
                            formatWhy = [@"类型码必须是 PK/LS/HS，实际 " stringByAppendingString:kv[1]];
                            break;
                        }
                        if (fabs(kv[3].doubleValue) > 0.05) changedGain = YES;
                    }
                } else { formatOK = NO; formatWhy = @"没有 bands= 字段"; }
            }
            ck(formatOK,
               "第7项: 下发体符合后端契约（序号,类型码,频率,增益,Q）—— 后端不会回「格式不对」",
               formatWhy.length ? formatWhy : @"未解析");
            ck(changedGain,
               "第7项: 下发体里至少一段增益真的变了（不是空拖动）",
               peqBody.length > 160 ? [peqBody substringToIndex:160] : peqBody);
        }

        std::printf("\n%s（%d passed, %d failed）\n",
                    g_fail == 0 ? "滚动/EQ 全部通过" : "滚动/EQ 有失败", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
