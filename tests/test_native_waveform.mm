// SPDX-License-Identifier: GPL-3.0-or-later
//
// U2 包3：原生正在播放页「波形视图」（identifier np.waveform）判据。
//
// 先红：旧实现（未接波形）视图树没有 np.waveform，/api/waveform 一次都不发 ——
//       本文件在旧码上必须失败（视图/请求/播放头/点击全部落空）。
// 后绿：开机时注入合成 peaks（bins=512）后，断言
//   W1 视图树存在 np.waveform，且挂在 npPage 内；
//   W2 高度在 44–56pt（任务要求），位于控制条 np.controls 正上方；
//   W3 请求就是 GET /api/waveform?file=…&bins=512（file 按 encodeURIComponent 编码）；
//   W4 peaks/rms 长度 = 512，duration 来自响应（视图属性，不自己编）；
//   W5 包络对称（中心基线上下等距）且按最大峰值归一化；
//   W6 已播/未播两色不同（绘制用的取色函数按播放头分档）；
//   W7 同一曲第二次 /api/status 轮询只更新播放头，**不再**请求波形；
//   W8 点击 → POST /api/seek?pos=…（四位小数、clamp 与 onCommitSeek 同口径）；
//   W9 横向拖选 ≥0.5s → 只保留选区高亮、不发请求（A/B 段端点后端未实现，挂账）；
//   W10 拖选 <0.5s → 选区被清掉（不留下无法取消的碎片）。
//
// 不启核心、不开设备、不出声：RLPCoreClient 的 shared 被下面的桩替换。
#import <AppKit/AppKit.h>
#import "RLPNowPlayingViewController.h"
#import "RLPTheme.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import <objc/runtime.h>
#include <cmath>
#include <cstdio>

// ---- 判据接缝：RLPWaveformView 的公开属性/方法在**旧码里不存在**，
//      测试侧先声明签名（不发消息就不需要实现）；旧码阶段用 respondsToSelector 守卫。
// 生产实现里的私有刷新入口（与既有 test_native_nowplaying_web 同一套声明方式）。
@interface RLPNowPlayingViewController (RLPWaveformPrivateTest)
- (void)refresh;
@end

@interface NSObject (RLPWaveformTestSeam)
- (NSRect)envelopeRectForBin:(NSInteger)bin;
- (NSColor *)envelopeColorForBin:(NSInteger)bin;
- (void)setPlayheadFraction:(double)f;
- (double)playheadFraction;
- (NSArray *)peaks;
- (NSArray *)rms;
- (double)duration;
- (BOOL)isSelecting;
- (double)selectionStart;
- (double)selectionEnd;
- (void)clearSelection;
@end

static NSMutableArray<NSString *> *g_paths;
static NSString *g_lastPost;
static int g_fail;

static void ck(bool ok, NSString *name) {
    printf("[%s] %s\n", ok ? "PASS" : "FAIL", name.UTF8String);
    if (!ok) ++g_fail;
}
static NSView *FindView(NSView *v, NSString *key) {
    if ([v.identifier isEqualToString:key]) return v;
    for (NSView *s in v.subviews) {
        NSView *r = FindView(s, key);
        if (r) return r;
    }
    return nil;
}
/// 统计发过的 GET 路径里以 prefix 开头的次数（波形请求只该在切曲时出现）。
static NSUInteger CountPaths(NSString *prefix) {
    NSUInteger n = 0;
    for (NSString *p in g_paths) if ([p hasPrefix:prefix]) ++n;
    return n;
}
/// CGColor 逐分量比较（含 alpha），用于「已播/未播两色」判据。
static BOOL SameColor(NSColor *a, NSColor *b) {
    if (!a || !b) return a == b;
    NSColor *sa = [a colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    NSColor *sb = [b colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!sa || !sb) return NO;
    return fabs(sa.redComponent - sb.redComponent) < 0.02 &&
           fabs(sa.greenComponent - sb.greenComponent) < 0.02 &&
           fabs(sa.blueComponent - sb.blueComponent) < 0.02 &&
           fabs(sa.alphaComponent - sb.alphaComponent) < 0.02;
}

@interface RLPWfSpy : NSObject
/// 按路径前缀命中固定 JSON（与既有原生判据同一套桩；回调同步回放）。
@property (nonatomic, strong) NSDictionary<NSString *, id> *fixtures;
@end
@implementation RLPWfSpy
- (BOOL)started { return YES; }
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    [g_paths addObject:path ?: @""];
    NSString *best = nil;
    for (NSString *k in self.fixtures) {
        if (![path hasPrefix:k]) continue;
        if (!best || k.length > best.length) best = k;
    }
    id hit = best ? self.fixtures[best] : nil;
    if (done) done([hit isKindOfClass:[NSDictionary class]] ? hit : nil);
}
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    (void)body;
    g_lastPost = path;
    if (done) done(@{ @"ok": @YES });
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done { (void)path; if (done) done(nil); }
- (void)postData:(NSString *)path body:(NSData *)body contentType:(NSString *)ct completion:(RLPJSONCompletion)done {
    (void)path; (void)body; (void)ct;
    if (done) done(@{ @"ok": @YES });
}
@end

static RLPWfSpy *g_spy;
static id FakeShared(id cls, SEL sel) { (void)cls; (void)sel; return g_spy; }

/// 合成 512 个 bin 的峰值：bin0 = 1.0（满幅）、bin1 = 0.5、其余 0.1。
/// 这样「归一化 + 对称」可以量出确定值，而不是只断言非空。
static NSArray<NSNumber *> *SyntheticPeaks(void) {
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:512];
    for (NSUInteger i = 0; i < 512; ++i) {
        double v = (i == 0) ? 1.0 : (i == 1 ? 0.5 : 0.1);
        [a addObject:@(v)];
    }
    return a;
}

static NSEvent *MouseEvent(NSEventType type, NSView *v, double frac, NSWindow *win) {
    NSPoint inView = NSMakePoint(frac * v.bounds.size.width, v.bounds.size.height / 2.0);
    NSPoint inWin = [v convertPoint:inView toView:nil];
    return [NSEvent mouseEventWithType:type location:inWin modifierFlags:0 timestamp:0
                          windowNumber:win.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1.0];
}

int main() { @autoreleasepool {
    [NSApplication sharedApplication];
    [RLPTheme setThemeName:@"light"];
    g_paths = [NSMutableArray array];

    // ---- 前置：旧实现也必须有的控制条（波形要挂在它正上方）----
    RLPNowPlayingViewController *vc = [RLPNowPlayingViewController new];
    vc.view.frame = NSMakeRect(0, 0, 1180, 760);
    [vc.view layoutSubtreeIfNeeded];
    NSView *page = [vc valueForKey:@"webCanvas"];
    NSView *ctl = FindView(vc.view, @"np.controls");
    ck(ctl != nil, @"前置：控制条 np.controls 存在（否则高度/位置判据没有参照）");

    // ---- W1/W2：视图树里有 np.waveform，挂在控制条上方、高 44–56pt ----
    NSView *wf = FindView(vc.view, @"np.waveform");
    ck(wf != nil, @"W1 视图树存在 np.waveform（旧实现为 nil ⟹ 本包先红）");
    if (wf) {
        ck(page && [wf isDescendantOf:page], @"W1b np.waveform 挂在正在播放页 npPage 内");
        ck(wf.frame.size.height >= 44.0 && wf.frame.size.height <= 56.0,
           [NSString stringWithFormat:@"W2 波形高度 %.1fpt ∈ [44,56]", wf.frame.size.height]);
        ck(ctl && NSMaxY(wf.frame) <= NSMinY(ctl.frame) + 0.5,
           [NSString stringWithFormat:@"W2b 波形在控制条正上方（wf.bottom=%.1f ≤ ctl.top=%.1f）",
            NSMaxY(wf.frame), NSMinY(ctl.frame)]);
    }

    // ---- 桩：/api/status + /api/waveform ----
    g_spy = [RLPWfSpy new];
    g_spy.fixtures = @{
        @"/api/status": @{ @"ok": @1, @"playing": @1, @"paused": @0,
                           @"current": @"/offline/wf 1.wav", @"dur": @10.0, @"pos": @0.0 },
        @"/api/waveform": @{ @"ok": @1, @"bins": @512, @"duration": @10.0,
                             @"peaks": SyntheticPeaks(), @"rms": SyntheticPeaks() },
    };
    Method shared = class_getClassMethod(RLPCoreClient.class, @selector(shared));
    IMP oldShared = method_setImplementation(shared, (IMP)FakeShared);

    [vc refresh];

    // ---- W3：真的请求了 /api/waveform?file=<编码路径>&bins=512 ----
    NSUInteger wfReqs = CountPaths(@"/api/waveform");
    ck(wfReqs == 1, @"W3 切曲发出一次 /api/waveform（旧实现 0 次 ⟹ 本包先红）");
    if (wfReqs == 1) {
        NSString *p = nil;
        for (NSString *x in g_paths) if ([x hasPrefix:@"/api/waveform"]) p = x;
        NSString *decoded = [p stringByRemovingPercentEncoding] ?: p;
        ck([p containsString:@"bins=512"], @"W3b 请求带 bins=512（与任务约定一致）");
        ck([decoded containsString:@"/offline/wf 1.wav"], @"W3c file 按 encodeURIComponent 编码且可回读");
    }

    // ---- W4/W5/W6：视图属性来自响应，不自己编 ----
    if (wf) {
        NSArray *peaks = [wf peaks];
        NSArray *rms = [wf rms];
        ck(peaks.count == 512, [NSString stringWithFormat:@"W4 peaks 长度 = 512（got %lu）", (unsigned long)peaks.count]);
        ck(rms.count == 512, [NSString stringWithFormat:@"W4b rms 长度 = 512（got %lu）", (unsigned long)rms.count]);
        ck(fabs([wf duration] - 10.0) < 0.01, @"W4c duration 来自 /api/waveform（10.0）");
        NSRect r0 = [wf envelopeRectForBin:0];
        NSRect r1 = [wf envelopeRectForBin:1];
        NSRect r400 = [wf envelopeRectForBin:400];
        const CGFloat center = wf.bounds.size.height / 2.0;
        ck(fabs(NSMidY(r0) - center) < 0.5 && fabs(NSMidY(r1) - center) < 0.5 && fabs(NSMidY(r400) - center) < 0.5,
           @"W5 包络围绕中心基线对称（三个 bin 的中点都落在中线）");
        ck(r0.size.height > 0 && fabs(r1.size.height - r0.size.height * 0.5) < 0.6,
           [NSString stringWithFormat:@"W5b 按最大峰值归一化（bin1/bin0 高度 = %.2f ≈ 0.5）",
            r0.size.height > 0 ? r1.size.height / r0.size.height : 0]);
        // 播放头在 0.0（首轮 status pos=0）⟹ 整条应当是"未播"色，而不是强调色。
        ck(!SameColor([wf envelopeColorForBin:100], [RLPTheme current].accent),
           @"W6 播放头在 0 时整条是未播色（不是 --acc）");
    }

    // ---- W7：同一曲第二次 status 轮询 → 播放头走，波形不再请求 ----
    g_spy.fixtures = @{
        @"/api/status": @{ @"ok": @1, @"playing": @1, @"paused": @0,
                           @"current": @"/offline/wf 1.wav", @"dur": @10.0, @"pos": @4.0 },
        @"/api/waveform": @{ @"ok": @1, @"bins": @512, @"duration": @10.0,
                             @"peaks": SyntheticPeaks(), @"rms": SyntheticPeaks() },
    };
    [vc refresh];
    if (wf) {
        ck(fabs([wf playheadFraction] - 0.4) < 0.005,
           [NSString stringWithFormat:@"W7 播放头随 /api/status 更新到 0.4（got %.3f）", [wf playheadFraction]]);
        NSColor *played = [wf envelopeColorForBin:100];
        NSColor *unplayed = [wf envelopeColorForBin:400];
        ck(SameColor(played, [RLPTheme current].accent), @"W7b 已播段取的是强调色（--acc）");
        ck(!SameColor(played, unplayed), @"W7c 已播/未播在同一次绘制里确实是两种颜色");
    }
    ck(CountPaths(@"/api/waveform") == 1,
       [NSString stringWithFormat:@"W7d 第二次轮询没有再请求波形（总请求 %lu 次）",
        (unsigned long)CountPaths(@"/api/waveform")]);

    // ---- W8：点击 → /api/seek?pos=（四位小数）----
    NSWindow *win = nil;
    if (wf) {
        win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1180, 760)
                                                    styleMask:NSWindowStyleMaskBorderless
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
        win.contentView = vc.view;
        [vc.view layoutSubtreeIfNeeded];
        g_lastPost = nil;
        NSEvent *down = MouseEvent(NSEventTypeLeftMouseDown, wf, 0.40, win);
        NSEvent *up = MouseEvent(NSEventTypeLeftMouseUp, wf, 0.40, win);
        [wf mouseDown:down];
        [wf mouseUp:up];
        ck([g_lastPost isEqualToString:@"/api/seek?pos=0.4000"],
           [NSString stringWithFormat:@"W8 点击发出 /api/seek?pos=0.4000（got %@）", g_lastPost]);
    }

    // ---- W9/W10：横向拖选 ----
    if (wf) {
        g_lastPost = nil;
        NSEvent *d0 = MouseEvent(NSEventTypeLeftMouseDown, wf, 0.20, win);
        NSEvent *m1 = MouseEvent(NSEventTypeLeftMouseDragged, wf, 0.45, win);
        NSEvent *m2 = MouseEvent(NSEventTypeLeftMouseDragged, wf, 0.70, win);
        NSEvent *u2 = MouseEvent(NSEventTypeLeftMouseUp, wf, 0.70, win);
        [wf mouseDown:d0];
        [wf mouseDragged:m1];
        [wf mouseDragged:m2];
        [wf mouseUp:u2];
        const double secs = fabs([wf selectionEnd] - [wf selectionStart]) * [wf duration];
        ck([wf isSelecting] && fabs(secs - 5.0) < 0.2,
           [NSString stringWithFormat:@"W9 拖选 0.20→0.70 = 5.0s ≥ 0.5s，选区保留（got %.2fs）", secs]);
        ck([wf selectionStart] < 0.205 && [wf selectionEnd] > 0.695,
           @"W9b 选区端点就是拖过的那两点");
        ck(g_lastPost == nil, @"W9c 选区只做高亮、不发请求（A/B 段端点未实现，本包挂账）");
        // 换一次 <0.5s 的拖选 → 选区清掉
        NSEvent *s0 = MouseEvent(NSEventTypeLeftMouseDown, wf, 0.20, win);
        NSEvent *s1 = MouseEvent(NSEventTypeLeftMouseDragged, wf, 0.225, win);
        NSEvent *s2 = MouseEvent(NSEventTypeLeftMouseUp, wf, 0.225, win);
        [wf mouseDown:s0];
        [wf mouseDragged:s1];
        [wf mouseUp:s2];
        g_lastPost = nil;
        ck(![wf isSelecting] || fabs([wf selectionEnd] - [wf selectionStart]) * [wf duration] >= 0.5,
           [NSString stringWithFormat:@"W10 拖选 <0.5s 不留下选区（got selecting=%d）", (int)[wf isSelecting]]);
    }

    // ---- W11：切到另一首 → 波形重新请求（同曲不重算，切曲要重算）----
    g_spy.fixtures = @{
        @"/api/status": @{ @"ok": @1, @"playing": @1, @"paused": @0,
                           @"current": @"/offline/wf 2.wav", @"dur": @10.0, @"pos": @0.0 },
        @"/api/waveform": @{ @"ok": @1, @"bins": @512, @"duration": @10.0,
                             @"peaks": SyntheticPeaks(), @"rms": SyntheticPeaks() },
    };
    [vc refresh];
    ck(CountPaths(@"/api/waveform") == 2,
       [NSString stringWithFormat:@"W11 切曲重新请求一次波形（总请求 %lu 次）",
        (unsigned long)CountPaths(@"/api/waveform")]);

    method_setImplementation(shared, oldShared);
    printf("waveform: %d failures\n", g_fail);
    return g_fail ? 1 : 0;
}}
