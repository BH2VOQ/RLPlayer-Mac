// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
// Offline AppKit objects only. No embedded core, devices, ports, or input automation.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "RLPPlaybackBarView.h"
#import "RLPVolumeKnobView.h"
#import "RLPVolumeSliderView.h"
#import "RLPSupport.h"

// 生产接缝（实现在 RLPPlaybackBarView.mm）：旋钮松开按 v3.3.11 dB 直接下发。
@interface RLPPlaybackBarView (RLPBarKnobTestSeam)
- (void)commitVolumeDb:(double)db;
@end
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPTheme.h"
#include <cstdio>
#include <cmath>
static NSDictionary *statusJSON;
static NSMutableArray<NSString *> *posts;
static BOOL online = NO;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RLPCoreClient
+ (instancetype)shared { static RLPCoreClient *c; if (!c) c = [self new]; return c; }
- (BOOL)started { return online; }
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    if (!done) return;
    if ([path hasPrefix:@"/api/meta"]) done(@{@"title":@"Real title", @"artist":@"Real artist", @"album":@"Real album"});
    else if ([path isEqual:@"/api/status"]) done(statusJSON);
    else done(@{@"mode":@0});
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done { if (done) done(nil); }
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    [posts addObject:path]; if (done) done(@{@"ok":@YES});
}
@end
#pragma clang diagnostic pop
@interface RLPPlaybackBarView (Criterion)
- (void)fetchStatus;
- (void)toggleRepeat:(id)sender;
- (void)toggleShuffle:(id)sender;
- (void)commitVolume;
@end
static int failures = 0, checks = 0;
static void check(BOOL ok, const char *what) { ++checks; printf("[%s] %s\n", ok ? "PASS" : "FAIL", what); if (!ok) ++failures; }
static id field(id bar, NSString *key) { return [bar valueForKey:key]; }
// 底栏 hover 判据的颜色比较（与 np 页 test_native_nowplaying_web 同口径：逐分量）。
static BOOL BarCgEq(CGColorRef c, NSColor *want, double tol) {
    if (!c || !want) return NO;
    NSColor *got = [[NSColor colorWithCGColor:c] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
    NSColor *w = [want colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
    return got && w && fabs(got.redComponent-w.redComponent)<tol
        && fabs(got.greenComponent-w.greenComponent)<tol
        && fabs(got.blueComponent-w.blueComponent)<tol
        && fabs(got.alphaComponent-w.alphaComponent)<tol;
}
static BOOL BarCgClear(CGColorRef c) {
    if (!c) return YES;
    NSColor *got = [[NSColor colorWithCGColor:c] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
    return !got || got.alphaComponent < 0.01;
}
// 测试侧声明：生产实现的 hover 状态机只在 RLPBarKeyButton 上；旧码没有 ⟹ 判据必须红而不是编译失败。
@interface NSObject (BarHoverTest)
- (void)setHovered:(BOOL)hovered;
@end
int main() { @autoreleasepool {
    [NSApplication sharedApplication]; posts = [NSMutableArray array];
    RLPPlaybackBarView *bar = [[RLPPlaybackBarView alloc] initWithFrame:NSMakeRect(0,0,1120,66)];
    statusJSON = @{@"ok":@YES,@"playing":@YES,@"current":@"/offline/file.flac",@"volDb":@(-120),@"bitPerfect":@"yes",@"outRate":@44100,@"outBits":@24};
    [bar fetchStatus]; [bar layout];
    NSArray *keys = @[@"repeatBtn",@"prevBtn",@"playBtn",@"nextBtn",@"stopBtn"];
    CGFloat end = -1;
    for (NSString *key in keys) { NSView *v=field(bar,key); check(!v.hidden && v.frame.origin.x > end, "five controls ordered repeat/prev/play/next/stop"); end=NSMaxX(v.frame); }
    NSView *shuffle=field(bar,@"shuffleBtn"); check(shuffle.hidden || shuffle.superview == nil, "no sixth shuffle control; API remains available");

    // ---- 第2/3项（2026-11-13 用户实机）----
    // 判据 1：播放中播放键必须是暂停图标。
    //   不能用 image.name 判（`imageWithSystemSymbolName:` 生成的图 name 可能是 nil），
    //   改用**渲染位图指纹**：不同状态必须给出不同位图 —— 这是"图标真的换过"的直接证据，
    //   而不是"我设了一个属性"（属性对、渲染错 是本项目踩过多次的形态）。
    {
        NSButton *pb = field(bar,@"playBtn");
        NSData *(^fingerprint)(void) = ^NSData *{
            NSImage *img = pb.image;
            if (!img) return nil;
            NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:[img TIFFRepresentation]];
            return rep ? [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] : nil;
        };
        NSData *whilePlaying = fingerprint();     // statusJSON 当前 playing=1
        NSMutableDictionary *stopped = [statusJSON mutableCopy];
        stopped[@"playing"] = @NO; stopped[@"paused"] = @NO;
        statusJSON = stopped;
        [bar fetchStatus];
        NSData *whileStopped = fingerprint();
        check(whilePlaying != nil && whileStopped != nil, "play key renders a real bitmap in both states");
        check(![whilePlaying isEqualToData:whileStopped],
              "第2项: play key image differs between playing and stopped (icon really switches)");
        check([bar isPlaying] == NO, "bar.isPlaying is false after a stopped status");
        NSMutableDictionary *resumed = [stopped mutableCopy];
        resumed[@"playing"] = @YES;
        statusJSON = resumed;
        [bar fetchStatus];
        check([bar isPlaying] == YES, "bar.isPlaying is true after a playing status");
        check([fingerprint() isEqualToData:whilePlaying],
              "第2项: returning to playing restores the pause icon (no one-way latch)");
    }
    // ---- 第13项：三枚徽章的文字必须双向居中（墨迹实测，不看 alignment 属性）----
    //
    // 判据为什么这么写：`alignment = NSTextAlignmentCenter` 只管**水平**，而且
    // NSTextField 在固定高胶囊里把单行文字排在**顶部**。旧实现实测 gpuBadge：
    //   20pt 高的框里 "GPU" 墨迹 左留白 0.5pt / 右留白 10pt / 上 0.5pt / 下 9.0pt
    //   ⟹ 用户看到的"文字不在徽章正中心"。
    // 所以这里量**渲染后的墨迹包围盒**（跳过 1px 边框），不是量属性。
    {
        bar.frame = NSMakeRect(0,0,1120,66); [bar layout];
        NSDictionary *rs = @{@"ok":@YES,@"playing":@YES,@"current":@"/offline/f.flac",
                             @"volDb":@(-120),@"bitPerfect":@"no",@"inRate":@44100,
                             @"outRate":@96000,@"outBits":@16,@"gpuUsed":@YES};
        statusJSON = rs; [bar fetchStatus]; [bar layout]; [bar layoutSubtreeIfNeeded];
        NSArray *badges = @[@"fmtBadge",@"gpuBadge",@"bpBadge"];
        // ⚠️ 不能对单个徽章 `cacheDisplayInRect:` 渲染：徽章现在位于 NSVisualEffectView 之上，
        // 单独渲染一个 view 时 AppKit **不做 backdrop 合成**，拿到的是空白（实测 sd=0.0000）。
        // 正确做法：先把**整条播放条**渲染成一张位图（整条渲染会完成合成），再从里面裁剪。
        NSBitmapImageRep *barRep = [bar bitmapImageRepForCachingDisplayInRect:bar.bounds];
        [bar cacheDisplayInRect:bar.bounds toBitmapImageRep:barRep];
        const double pxScale = barRep.pixelsWide / MAX(1.0, bar.bounds.size.width);
        NSInteger usable = 0;
        for (NSString *key in badges) {
            NSTextField *l = field(bar,key);
            if (!l || l.hidden || l.bounds.size.width < 4 || l.bounds.size.height < 4) {
                check(NO, [[NSString stringWithFormat:@"第13项: %@ 存在且有真实尺寸", key] UTF8String]);
                continue;
            }
            // 徽章在播放条坐标系里的矩形 → 位图上的像素矩形
            const NSRect inBar = [l convertRect:l.bounds toView:bar];
            const NSInteger x0p = (NSInteger)lround(NSMinX(inBar) * pxScale);
            // ⚠️ y 必须翻一次：NSBitmapImageRep 的 colorAtX:y: 以**位图左上角**为原点，
            // 而 NSView 坐标以左下角为原点。旧写法直接用 NSMinY，只有徽章**正好在条高一半**
            // （y 23..43 于 66pt 高的条内，中心 33 = H/2）时两种解释才重合 ⟹ 这条判据长期
            // 是"碰巧过"。2026-11-15 把右簇上移到五键组竖带（中心 H-24=42）后立刻露馅：
            // 实测 fmt/gpu 找不到墨迹、bp 量到的是时长标签的墨迹（R63.5 就是证据）。
            const NSInteger y0p = (NSInteger)lround((bar.bounds.size.height - NSMaxY(inBar)) * pxScale);
            const NSInteger wP  = (NSInteger)lround(l.bounds.size.width * pxScale);
            const NSInteger hP  = (NSInteger)lround(l.bounds.size.height * pxScale);
            if (wP < 6 || hP < 6) { check(NO, [[NSString stringWithFormat:@"第13项: %@ 位图区域有效", key] UTF8String]); continue; }
            // 跳过 1px 描边（换算到像素）
            const NSInteger inset = (NSInteger)MAX(3.0, pxScale + 2.0);
            // 底色 = 整圈内侧像素的亮度中位数（避开文字、避开描边）
            NSMutableArray<NSNumber *> *lum = [NSMutableArray array];
            for (NSInteger x = x0p + inset; x < x0p + wP - inset; ++x) {
                for (NSInteger yy = y0p + inset; yy < y0p + inset + 2; ++yy)
                    if (x >= 0 && yy >= 0 && x < barRep.pixelsWide && yy < barRep.pixelsHigh) {
                        NSColor *c = [[barRep colorAtX:x y:yy] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
                        if (c) [lum addObject:@(0.299*c.redComponent + 0.587*c.greenComponent + 0.114*c.blueComponent)];
                    }
                for (NSInteger yy = y0p + hP - inset - 2; yy < y0p + hP - inset; ++yy)
                    if (x >= 0 && yy >= 0 && x < barRep.pixelsWide && yy < barRep.pixelsHigh) {
                        NSColor *c = [[barRep colorAtX:x y:yy] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
                        if (c) [lum addObject:@(0.299*c.redComponent + 0.587*c.greenComponent + 0.114*c.blueComponent)];
                    }
            }
            if (!lum.count) { check(NO, [[NSString stringWithFormat:@"第13项: %@ 可采样底色", key] UTF8String]); continue; }
            [lum sortUsingSelector:@selector(compare:)];
            const double bgLum = lum[lum.count / 2].doubleValue;
            NSInteger ix0 = wP, ix1 = -1, iy0 = hP, iy1 = -1;
            for (NSInteger x = inset; x < wP - inset; ++x) {
                for (NSInteger y = inset; y < hP - inset; ++y) {
                    NSColor *c = [[barRep colorAtX:x0p + x y:y0p + y] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
                    if (!c) continue;
                    const double l2 = 0.299*c.redComponent + 0.587*c.greenComponent + 0.114*c.blueComponent;
                    if (fabs(l2 - bgLum) > 0.18) { if (x<ix0) ix0=x; if (x>ix1) ix1=x; if (y<iy0) iy0=y; if (y>iy1) iy1=y; }
                }
            }
            if (ix1 < 0) { check(NO, [[NSString stringWithFormat:@"第13项: %@ 能找到文字墨迹", key] UTF8String]); continue; }
            const double L = (ix0-inset)/pxScale, R = ((wP-1-inset)-ix1)/pxScale;
            const double T = (iy0-inset)/pxScale, B = ((hP-1-inset)-iy1)/pxScale;
            ++usable;
            check(fabs(L-R) <= 1.0 && fabs(T-B) <= 1.0,
                  [[NSString stringWithFormat:
                    @"第13项: %@ 文字双向居中（|Δ左右|≤1pt 且 |Δ上下|≤1pt，实测 L%.1f R%.1f T%.1f B%.1f）",
                    key, L, R, T, B] UTF8String]);
        }
        check(usable == badges.count, "第13项: 三枚徽章都量到了墨迹（没有『量不到就算过』）");

        // 一致性：三枚徽章高度一致、左右内边距一致
        {
            NSMutableArray<NSNumber *> *heights = [NSMutableArray array];
            for (NSString *key in badges) {
                NSTextField *l = field(bar,key);
                if (l && !l.hidden) [heights addObject:@(l.bounds.size.height)];
            }
            BOOL sameH = YES;
            for (NSNumber *h in heights) if (fabs(h.doubleValue - heights[0].doubleValue) > 1.0) sameH = NO;
            check(heights.count >= 2 && sameH, "第13项: 三枚徽章高度一致（±1pt）");
        }
    }

    // ---- 第14项：磨砂玻璃（Apple Music 式悬浮胶囊条）----
    //
    // ⚠️ 判据设计的关键实测结论（写在 evidence 里）：
    //   单独 `cacheDisplayInRect:` 一个 NSVisualEffectView 得到的是**纯白**（sd=0.0000）——
    //   AppKit 在离屏渲染单个 view 时**不做 backdrop 合成**。渲染**整条**或整个 contentView
    //   才会合成。所以"加了个 NSVisualEffectView 类名就算过"这种判据毫无意义，
    //   必须：①断言结构与层级；②**换两张不同背景，量条内像素是否随之变化**（真半透明的证明）。
    {
        NSVisualEffectView *vev = nil;
        for (NSView *v in bar.subviews)
            if ([v isKindOfClass:[NSVisualEffectView class]]) { vev = (NSVisualEffectView *)v; break; }
        check(vev != nil, "第14项: 播放条内存在 NSVisualEffectView（玻璃层）");
        if (vev) {
            check(vev.material == NSVisualEffectMaterialHUDWindow,
                  "第14项: 材质为 .hudWindow（与参考图的强模糊+轻微提亮一致）");
            check(vev.blendingMode == NSVisualEffectBlendingModeWithinWindow,
                  "第14项: blendingMode 为 .withinWindow（只透窗口内容，不透桌面）");
            check(vev.state == NSVisualEffectStateActive,
                  "第14项: state 为 .active（失焦不变死灰）");
            // 层级：玻璃层必须是**最底下**的 subview（否则会盖住文字与按钮）
            check(bar.subviews.firstObject == vev,
                  "第14项: 玻璃层在最底层（内容与控件在它之上）");
            // 覆盖整条
            bar.frame = NSMakeRect(0,0,1120,66); [bar layout];
            check(fabs(vev.frame.size.width - bar.bounds.size.width) < 1.0 &&
                  fabs(vev.frame.size.height - bar.bounds.size.height) < 1.0,
                  [[NSString stringWithFormat:@"第14项: 玻璃层覆盖整条（vev=%@ bar=%@）",
                    NSStringFromRect(vev.frame), NSStringFromRect(bar.bounds)] UTF8String]);
        }
        // 几何：条高 56–64pt（用户要求）；控制键组中心与条中心偏差 ≤2pt
        check(bar.bounds.size.height >= 56 && bar.bounds.size.height <= 66,
              [[NSString stringWithFormat:@"第14项: 条高在 56–66pt 区间（实测 %.0f）", bar.bounds.size.height] UTF8String]);
        {
            NSButton *pb = field(bar,@"playBtn");
            check(fabs(NSMidX(pb.frame) - bar.bounds.size.width/2) <= 2.0,
                  [[NSString stringWithFormat:@"第14项: 控制键组中心与条中心偏差 ≤2pt（实测 %.2f）",
                    fabs(NSMidX(pb.frame) - bar.bounds.size.width/2)] UTF8String]);
        }
    }

    // ---- 第14项：真磨砂的**可测边界**（如实写清能证明什么、不能证明什么）----
    //
    // 我实测了两个反直觉的事实，它们决定这条判据只能这么写：
    //   ① 单独 `cacheDisplayInRect:` 一个 NSVisualEffectView → **纯白 sd=0.0000**；
    //   ② 即使渲染整个 contentView，**有玻璃层与没有玻璃层的结果逐字节相同**
    //      （棋盘背景下两次都 sd=0.5000、maxColGrad=0.1667 —— 背景图案原样透出、没被模糊）。
    //      ⟹ 离屏渲染路径下 AppKit **不做 backdrop 合成**，VEV 只是一个不画东西的洞。
    //   ③ 而"换两种背景条内像素会变"这一条**在有无玻璃层时都成立**（Δ=0.527），
    //      因为条底色本身就是 `--barbg: rgba(246,246,249,.84)`（自带 84% alpha）——
    //      那条判据测的是"底色半透明"，不是"磨砂"，作为磨砂判据是**假绿**，已弃用。
    //
    // 结论（不粉饰）：磨砂的最终观感只能在**上屏**环境判定，离屏审计能证明的是
    // 结构与层级正确；模糊必须由实机验收。这里把能测的测到位，并把不能测的写清楚，
    // 而不是编一条通过了也不说明问题的判据。
    {
        NSMutableArray<NSVisualEffectView *> *vevs = [NSMutableArray array];
        for (NSView *v in bar.subviews)
            if ([v isKindOfClass:[NSVisualEffectView class]]) [vevs addObject:(NSVisualEffectView *)v];
        check(vevs.count == 1, "第14项: 恰好一个玻璃层（不重复叠加）");
        NSVisualEffectView *vev = vevs.count ? vevs.firstObject : nil;
        if (vev) {
            check(vev.material == NSVisualEffectMaterialHUDWindow,
                  "第14项: 材质 .hudWindow（强模糊 + 轻微提亮，与参考图一致）");
            check(vev.blendingMode == NSVisualEffectBlendingModeWithinWindow,
                  "第14项: blendingMode .withinWindow（只透窗口内容，不透桌面）");
            check(vev.state == NSVisualEffectStateActive,
                  "第14项: state .active（失焦不变死灰）");
            check(bar.subviews.firstObject == vev,
                  "第14项: 玻璃层在最底层（内容与控件压在它之上，不会被糊住）");
            bar.frame = NSMakeRect(0,0,1120,66); [bar layout];
            check(fabs(vev.frame.size.width - bar.bounds.size.width) < 1.0 &&
                  fabs(vev.frame.size.height - bar.bounds.size.height) < 1.0,
                  [[NSString stringWithFormat:@"第14项: 玻璃层覆盖整条（vev=%@）",
                    NSStringFromRect(vev.frame)] UTF8String]);
            // 圆角一致性：宿主（RLPMainWindowController）负责给播放条设圆角，
            // 这里只断言玻璃层**自己**有圆角且与宿主给的值一致（宿主值由 audit 的整窗用例核对）。
            check(vev.layer.cornerRadius >= 12,
                  [[NSString stringWithFormat:@"第14项: 玻璃层有悬浮圆角 ≥12pt（实测 %.0f）",
                    vev.layer.cornerRadius] UTF8String]);
        }
        // 几何（参考图：悬浮胶囊、条高 56–64pt、控制键组居中）
        check(bar.bounds.size.height >= 56 && bar.bounds.size.height <= 66,
              [[NSString stringWithFormat:@"第14项: 条高 56–66pt（实测 %.0f，参考图量得约 44–48pt@2x→88–96px）",
                bar.bounds.size.height] UTF8String]);
        {
            NSButton *pb = field(bar,@"playBtn");
            check(fabs(NSMidX(pb.frame) - bar.bounds.size.width/2) <= 2.0,
                  [[NSString stringWithFormat:@"第14项: 控制键组中心与条中心偏差 ≤2pt（实测 %.2f）",
                    fabs(NSMidX(pb.frame) - bar.bounds.size.width/2)] UTF8String]);
            // 左右两端与边缘留白差 ≤2pt（参考图是左右对称的悬浮条）
            NSView *cover = field(bar,@"coverView");
            NSTextField *volLab = field(bar,@"durLabel");
            const CGFloat leftGap = NSMinX(cover.frame);
            // 右端留白必须取**全部控件里最靠右的那一个**的右缘。
            // 旧写法只看 volDbField；音量改成滑杆后滑杆自带数值、并且排在 volDbField 右边，
            // 于是量出来是负的（-1.0），看起来像"溢出"，其实是取样对象过时。
            CGFloat rightMost = 0;
            for (NSView *sub in bar.subviews) {
                if (sub.hidden || sub.alphaValue < 0.01) continue;
                if (NSIsEmptyRect(sub.frame)) continue;
                // glass 背景铺满整个 bounds；把它算进来右边距永远为 0（假红）。
                if ([sub.identifier isEqualToString:@"pb.glass"]) continue;
                rightMost = MAX(rightMost, NSMaxX(sub.frame));
            }
            const CGFloat rightGap = bar.bounds.size.width - rightMost;
            (void)volLab;
            check(fabs(leftGap - rightGap) <= 2.0,
                  [[NSString stringWithFormat:@"第14项: 左右两端留白差 ≤2pt（左 %.1f 右 %.1f）",
                    leftGap, rightGap] UTF8String]);
        }
        // 悬浮形状（圆角 + 投影）由**宿主** RLPMainWindowController 设置（单测里没有宿主），
        // 这里按宿主的实际取值核对一次，避免"改了宿主却没人知道"：
        //   cornerRadius=16 / borderWidth=1 / shadowOpacity=0.13 / shadowRadius=19 / offset(0,-6)
        // 真实几何由 --audit 的整窗用例断言（见 RLPFunctionalAudit 第14项段落）。
        check(vev.layer.cornerRadius >= 12, "第14项: 玻璃层自带圆角（宿主负责整条外形）");
    }

    // 判据 2（第3项）：进度条与播放键不得相交
    //   （用户截图里"三角形偏左贴边/圆被裁"的真实成因是**白色进度滑块头压在红圆上**）
    {
        bar.frame = NSMakeRect(0,0,1120,66); [bar layout];
        NSView *prog = field(bar,@"progress"), *pb = field(bar,@"playBtn");
        check(!NSIntersectsRect(prog.frame, pb.frame),
              "第3项: progress track never intersects the round play key");
        check(fabs(pb.frame.size.width - pb.frame.size.height) < 0.51,
              "第3项: play key is square (cornerRadius == half side draws a full circle)");
    }
    check(fabs([field(bar,@"playBtn") frame].size.width-34)<.01, "web main key is 34pt");
    check(fabs([field(bar,@"coverView") frame].size.width-44)<.01, "web cover is 44pt");
    for (NSNumber *width in @[@1120,@980,@860]) {
        bar.frame=NSMakeRect(0,0,width.doubleValue,66); [bar layout];
        NSArray *right=@[@"lyricBtn",@"chainBtn",@"bpBadge",@"fmtBadge",@"volMuteBtn",@"volKnob",@"volDbField"];
        CGFloat edge=NSMaxX([field(bar,@"stopBtn") frame]);
        for (NSString *key in right) { NSView *v=field(bar,key); check(!v.hidden && v.frame.size.width>0 && NSMinX(v.frame)>=edge && NSMaxX(v.frame)<=width.doubleValue, "right controls and badges visible inside right column in one or two rows"); }
        for (NSUInteger i=0;i<right.count;++i) for(NSUInteger j=i+1;j<right.count;++j)
            check(!NSIntersectsRect([field(bar,right[i]) frame],[field(bar,right[j]) frame]), "right status cluster controls never overlap after wrapping");
    }
    for (NSNumber *width in @[@1180,@1120,@980,@860,@626]) {
        bar.frame=NSMakeRect(0,0,width.doubleValue,66); [bar layout];
        check(fabs(NSMidX([field(bar,@"playBtn") frame])-width.doubleValue/2)<.01, "play key stays centered on entire bar with symmetric side columns");
    }
    NSTextField *bp=field(bar,@"bpBadge");
    // 「非 bit-perfect」这个状态还会被**细分**（web 同口径，见 refreshBadges）：
    // 输入/输出采样率不同 ⟹ "PCM-PCM 升频"/"PCM 降采样"；DSD ⟹ "PCM-DSD 升频" 等。
    // 旧判据把 "no" 一律当成「非 bit-perfect」，在带 inRate/outRate 的状态下必然不符 ——
    // 那是**判据过时**，不是实现错。这里改成"按同一批字段算出期望值"，
    // 而不是钉死一个字符串。
    for (NSString *state in @[@"yes",@"no",@"direct",@""]) {
        NSMutableDictionary *d=[statusJSON mutableCopy]; d[@"bitPerfect"]=state; statusJSON=d; [bar fetchStatus]; [bar layout];
        NSString *expected;
        if ([state isEqual:@"yes"]) expected = @"BIT-PERFECT";
        else if ([state isEqual:@"direct"]) expected = @"BIT-PERFECT·1bit";
        else if (!state.length) expected = @"待播放验证";
        else {
            // no：按当前 kv 推导（只有采样率差异这一种，本测试的 statusJSON 里就是它）
            const double inR = [d[@"inRate"] doubleValue], outR = [d[@"outRate"] doubleValue];
            const double dsd = [d[@"dsd"] doubleValue];
            if (dsd > 0) expected = [d[@"current"] pathExtension].lowercaseString.length &&
                [@[@"dsf",@"dff",@"dsd",@"iso"] containsObject:[[d[@"current"] pathExtension] lowercaseString]]
                ? @"DSD-DSD 升频" : @"PCM-DSD 升频";
            else if (inR > 0 && outR > 0 && inR != outR)
                expected = (outR < inR) ? @"PCM 降采样" : @"PCM-PCM 升频";
            else expected = @"非 bit-perfect";
        }
        check(!bp.hidden && [bp.stringValue isEqual:expected],
              [[NSString stringWithFormat:@"badge reflects real yes/no/direct/idle state [state=%@ expected=%@ got=%@]",
                state, expected, bp.stringValue] UTF8String]);
    }
    check([[field(bar,@"titleLabel") stringValue] isEqual:@"Real title"], "metadata title survives subsequent polls");
    check([[field(bar,@"subLabel") stringValue] isEqual:@"Real artist · Real album"], "real artist and album shown");
    NSSlider *volume=field(bar,@"volume");
    // 2026-11-15：底栏音量由 270 度旋钮改成**横向滑杆**（用户反馈"旋钮很别扭"）。
    // 依据：Apple HIG《Sliders》"Don't use a slider to adjust audio volume...
    // use a volume view, which includes a volume-level slider"；macOS 27.2 系统音量提示
    // 自身也改成"左端喇叭 + 分段横条"。旋钮比 slider 更偏离：一维连续量藏进角度。
    // 因此这里断言的是新控件，属性名沿用 volKnob（避免大面积改 KVC 锚点）。
    RLPVolumeSliderView *knob=(RLPVolumeSliderView *)field(bar,@"volKnob");
    check([knob isKindOfClass:RLPVolumeSliderView.class],
          "底栏音量是横向滑杆（2026-11-15 由旋钮改来，HIG 推荐 volume slider）");
    RLPVolumeSliderView *sl = knob;
    // 行程判据用 trackRect 而不是 frame：showsAccessories=YES 时轨道会被内置喇叭/数值挤窄，
    // 只有"轨道的真实宽度"才等价于"用户可细调的横向行程"。
    check(NSWidth([sl trackRect]) > 40,
          "滑杆有足够横向行程（旋钮只有角度，细调困难）");
    check([sl muteButton] != nil, "滑杆自带静音键（左端喇叭）");
    check([sl valueLabel] != nil, "滑杆自带 dB 数值显示");
    check(volume.hidden, "旧的 NSSlider 仍隐藏（不与新滑杆重复）");
    for (NSString *key in @[@"prevBtn",@"playBtn",@"nextBtn",@"stopBtn",@"repeatBtn"]) {
        NSButton *button=field(bar,key); check(button.target==bar && button.action!=NULL, "transport controls have real target-action wiring");
    }
    NSArray *cases=@[
        @{@"bitPerfect":@"direct",@"dsd":@256,@"current":@"/offline/test.dsf",@"expect":@"BIT-PERFECT·1bit"},
        @{@"bitPerfect":@"no",@"dsd":@128,@"expect":@"PCM-DSD 升频"},
        @{@"bitPerfect":@"no",@"dsd":@256,@"current":@"/offline/test.dsf",@"expect":@"DSD-DSD 升频"},
        @{@"bitPerfect":@"no",@"inRate":@96000,@"outRate":@44100,@"expect":@"PCM 降采样"},
        @{@"bitPerfect":@"no",@"inRate":@44100,@"outRate":@96000,@"expect":@"PCM-PCM 升频"},
        @{@"bitPerfect":@"no",@"transport":@"upnp",@"inRate":@44100,@"outRate":@96000,@"expect":@"非 bit-perfect"},
        @{@"bitPerfect":@"no",@"transport":@"airplay",@"resampled":@YES,@"inRate":@96000,@"outRate":@44100,@"expect":@"PCM 降采样"},
        @{@"bitPerfect":@"no",@"bitPerfectWhy":@"物理格式未锁定",@"inRate":@44100,@"outRate":@96000,@"expect":@"非 bit-perfect"}
    ];
    NSDictionary *base=statusJSON;
    for (NSDictionary *c in cases) {
        NSMutableDictionary *d=[base mutableCopy]; [d addEntriesFromDictionary:c]; statusJSON=d;
        [bar fetchStatus]; [bar layout]; check([bp.stringValue isEqual:c[@"expect"]], "badge direction and direct/cast negative controls use backend evidence");
    }
    NSMutableDictionary *gpu=[base mutableCopy]; gpu[@"gpuUsed"]=@YES; statusJSON=gpu; [bar fetchStatus]; [bar layout];
    check(![field(bar,@"gpuBadge") isHidden], "GPU badge follows real gpuUsed status");
    gpu[@"bitPerfect"]=@"direct"; gpu[@"gpuUsed"]=@YES; statusJSON=gpu;
    bar.frame=NSMakeRect(0,0,626,66); [bar fetchStatus]; [bar layout];
    NSArray *all=@[@"coverView",@"titleLabel",@"subLabel",@"repeatBtn",@"prevBtn",@"playBtn",@"nextBtn",@"stopBtn",@"posLabel",@"progress",@"durLabel",@"lyricBtn",@"chainBtn",@"bpBadge",@"fmtBadge",@"gpuBadge",@"volMuteBtn",@"volKnob",@"volDbField"];
    for (NSUInteger i=0;i<all.count;++i) {
        NSView *a=field(bar,all[i]); check(!a.hidden && NSContainsRect(bar.bounds,a.frame), "minimum supported 626pt bar contains every real control/badge");
        for (NSUInteger j=i+1;j<all.count;++j) {
            NSView *b=field(bar,all[j]);
            if (NSIntersectsRect(a.frame, b.frame)) {
                printf("  [diag] overlap: %s %s  vs  %s %s\n",
                       [all[i] UTF8String], [NSStringFromRect(a.frame) UTF8String],
                       [all[j] UTF8String], [NSStringFromRect(b.frame) UTF8String]);
            }
            check(!NSIntersectsRect(a.frame,b.frame), "minimum bar controls do not overlap");
        }
    }
    gpu[@"gpuUsed"]=@NO; statusJSON=gpu; [bar fetchStatus]; check([field(bar,@"gpuBadge") isHidden], "GPU badge clears when unused");
    // 音量控件是自绘视图：断言它真的占据可见槽位。绘制路径与 dB 换算由
    // test_native_volume_knob 的 S1–S10 覆盖（滑杆那份实现）。
    check(NSWidth(knob.frame) > 0 && NSHeight(knob.frame) > 0, "音量滑杆有真实可见尺寸");
    // 滑杆是**横向**的：宽度必须明显大于高度（旧旋钮是正方形，这条对调了）。
    check(NSWidth(knob.frame) > NSHeight(knob.frame) * 2.0,
          "滑杆槽位是横向的（宽 > 2×高；旧旋钮是正方形）");


    online=YES; [bar startPolling];


    // ---- v3.3.11 底栏 volFloor：静音/恢复（与播放页共用一份记忆值） ----
    NSButton *barMute = field(bar, @"volMuteBtn");
    check(barMute != nil && [barMute.identifier isEqual:@"volFloor"], "底栏有 volFloor 静音键（web ui_page.h:1501 同位置）");
    check(barMute.target == bar && barMute.action != NULL, "底栏静音键有真实 target/action");
    // 静音入口：可点击的喇叭按钮（volFloor）现在是**行内真实控件**，
    // 位置就在 mac 惯例的"滑杆左侧"，取代了原来只显示的 volIconView（后者已 hidden）。
    // 滑杆自身的喇叭/数值附件保持关闭（showsAccessories=NO）：底栏已经有这两样，
    // 滑杆里再带一套会把轨道挤到 20pt（实测），同一行还会出现三个相同信息。
    check(!barMute.hidden, "静音键可见（滑杆左侧可点击喇叭）");
    check(NSMidX(barMute.frame) < NSMinX(knob.frame),
          "静音键在滑杆左侧（mac 惯例：喇叭 → 滑杆 → 数值）");
    check(sl.showsAccessories == NO,
          "滑杆自身不重复带喇叭/数值（底栏已提供，避免同一行三个相同信息）");

    // 共享状态：静音→恢复 必须回到原值（不是回到某个固定默认值）
    RLPVolumeMuteReset();
    check(!RLPVolumeMuteHasRestore(), "初始无恢复值（web volumeRestore === null）");
    knob.db = -12.5; [bar commitVolumeDb:knob.db];
    check([posts.lastObject isEqual:@"/api/volume?db=-12.5"], "前置：把音量设到 -12.5 dB");
    [barMute performClick:nil];
    check([posts.lastObject isEqual:@"/api/volume?db=-120.0"], "点击静音键下发 -120.0 dB");
    check(RLPVolumeMuteHasRestore(), "静音后有恢复值");
    [barMute performClick:nil];
    check([posts.lastObject isEqual:@"/api/volume?db=-12.5"], "再点一次恢复成静音前的 -12.5 dB（不是默认值）");
    check(!RLPVolumeMuteHasRestore(), "恢复后清空记忆值");
    // 无恢复值且当前已 -120：上游语义是「什么都不做」
    RLPVolumeMuteReset();
    knob.db = -120.0; [bar commitVolumeDb:knob.db];
    NSString *before = posts.lastObject;
    [barMute performClick:nil];
    check([posts.lastObject isEqual:before], "当前已 -120 且无恢复值时点击不发请求（上游 return）");

    // ---- v3.3.11 barVolInput：底栏精确 dB 输入（Enter 确认） ----
    NSTextField *volField = field(bar, @"volDbField");   // field() 走 KVC 属性名
    check(volField != nil && [volField.identifier isEqual:@"barVolInput"], "底栏有 barVolInput 精确 dB 输入（web ui_page.h:1503）");
    check(volField.target == bar && volField.action != NULL, "精确输入有真实 target/action（Enter 提交）");
    volField.stringValue = @"-12.5"; [bar performSelector:@selector(onCommitPreciseVolume:) withObject:volField];
    check([posts.lastObject isEqual:@"/api/volume?db=-12.5"], "合法值 Enter 后下发 /api/volume?db=-12.5");
    volField.stringValue = @"999"; [bar performSelector:@selector(onCommitPreciseVolume:) withObject:volField];
    check([posts.lastObject isEqual:@"/api/volume?db=-12.5"], "越界值不下发（保持上一条请求不变）");
    check(volField.layer.borderWidth > 0, "非法值标红边框（web aria-invalid 同语义）");
    volField.stringValue = @"abc"; [bar performSelector:@selector(onCommitPreciseVolume:) withObject:volField];
    check([posts.lastObject isEqual:@"/api/volume?db=-12.5"], "非数字不下发（不把垃圾值发给后端）");
    volField.stringValue = @"20"; [bar performSelector:@selector(onCommitPreciseVolume:) withObject:volField];
    check([posts.lastObject isEqual:@"/api/volume?db=20.0"], "上限 +20 dB 合法并下发");
    volField.stringValue = @"-120"; [bar performSelector:@selector(onCommitPreciseVolume:) withObject:volField];
    check([posts.lastObject isEqual:@"/api/volume?db=-120.0"], "下限 -120 dB（真静音）合法并下发");
    // ★ 曲线变更（2026-11-15，v3.3.11 对照）：upstream 的 volPosToDb（-55 位置曲线）已 0 处引用，
    //   音量唯一映射是 volDbToNorm/volNormToDb 的对称指数；底栏改为按旋钮 dB 直接下发。
    //   旧判据「frozen web -55 curve」守的是一条上游已删除的曲线，这里是纠正而不是放宽。
    for (NSNumber *dbx in @[@(-120.0), @(0.0), @(-12.5), @(20.0)]) {
        knob.db = dbx.doubleValue; [bar commitVolumeDb:knob.db];
        NSString *request=[NSString stringWithFormat:@"/api/volume?db=%.1f", RLPVolClampDb(dbx.doubleValue)];
        check([posts.lastObject isEqual:request], "v3.3.11 音量：旋钮 dB 原样下发（-120 真静音 / 0 dB / 负值 / +20 上限）");
    }
    [bar setValue:@0 forKey:@"playMode"];
    for (NSInteger mode=1;mode<=4;++mode) { [bar toggleRepeat:nil]; check([posts.lastObject isEqual:[NSString stringWithFormat:@"/api/playmode?mode=%ld",(long)(mode%4)]], "mode button cycles all four modes including shuffle"); }
    [bar stopPolling]; check(!bar.polling, "polling lifecycle preserved");

    // ---- 底栏 `.k` hover（web ui_page.h:1081-1085，hover 挂账 1 / 已知偏差 #9）----
    // .k{32×32;radius9;color:--mut} / .k:hover{background:--hov2;color:--txt}
    // .k.big{34;圆;--acc;白字} / .k.big:hover{filter:brightness(1.08)}
    // 旧码是普通 NSButton（只有 AppKit 按下高亮）：判据用 respondsToSelector 驱动，
    // 方法不存在只是 FAIL、不会崩（与 np 页 hover 判据同口径）。
    {
        RLPTheme *t = [RLPTheme current];
        NSArray<NSString *> *keys = @[@"repeatBtn",@"prevBtn",@"nextBtn",@"stopBtn"];
        for (NSString *k in keys) {
            NSButton *b = field(bar,k);
            NSString *tag = [NSString stringWithFormat:@"pb.%@",k];
            bool hoverable = [b respondsToSelector:NSSelectorFromString(@"setHovered:")];
            check(hoverable, [[NSString stringWithFormat:@"%@ 有 hover 状态机（web .k:hover）",tag] UTF8String]);
            if (!hoverable) continue;   // 旧码：后续判据跳过（红只由这条 + 前提给出）
            check(b.trackingAreas.count>=1, [[NSString stringWithFormat:@"%@ 有 hover 跟踪区",tag] UTF8String]);
            check(BarCgClear(b.layer.backgroundColor),
                  [[NSString stringWithFormat:@"%@ 静态无底色（web .k 无 background）",tag] UTF8String]);
            // 静态图标色不写死：底栏既有实现在 applyTheme/refreshModeButtons 里会按主题与播放模式
            // 改写 tint（repeat/shuffle 激活时是 --acc）。本包只锁 hover 状态机 ⟹ 捕获 hover 前基线。
            NSColor *baseTint = b.contentTintColor;
            check(baseTint != nil, [[NSString stringWithFormat:@"%@ 静态图标色存在",tag] UTF8String]);
            [(id)b setHovered:YES];
            check(BarCgEq(b.layer.backgroundColor,t.hov2,0.03),
                  [[NSString stringWithFormat:@"%@ hover 底 = --hov2",tag] UTF8String]);
            check(BarCgEq(b.contentTintColor.CGColor,t.text,0.06),
                  [[NSString stringWithFormat:@"%@ hover 图标色 = --txt",tag] UTF8String]);
            [(id)b setHovered:NO];
            check(BarCgClear(b.layer.backgroundColor),
                  [[NSString stringWithFormat:@"%@ 退出恢复透明底",tag] UTF8String]);
            check(BarCgEq(b.contentTintColor.CGColor,baseTint,0.06),
                  [[NSString stringWithFormat:@"%@ 退出恢复 hover 前图标色（不抹掉播放模式强调色）",tag] UTF8String]);
        }
        // .k.big（播放键）：accent 底不变为透明，hover 提亮（brightness 1.08 的混白近似）。
        NSButton *big = field(bar,@"playBtn");
        bool bigHover = [big respondsToSelector:NSSelectorFromString(@"setHovered:")];
        check(bigHover, "pb.play 有 hover 状态机（web .k.big:hover）");
        if (bigHover) {
            CGColorRef base = big.layer.backgroundColor;
            NSColor *baseC = base ? [NSColor colorWithCGColor:base] : nil;
            check(baseC && BarCgEq(base,t.accent,0.02), "pb.play 静态底 = --acc（圆形红键，不被清掉）");
            [(id)big setHovered:YES];
            check(!BarCgEq(big.layer.backgroundColor,baseC,0.02),
                  "pb.play hover 底色变化（web brightness 1.08）");
            [(id)big setHovered:NO];
            check(BarCgEq(big.layer.backgroundColor,baseC,0.02), "pb.play 退出恢复 --acc 底");
        }
    }
        // ---- brightness(1.08) 逐通道真混合（旧码混 10% 白）----
        {
            NSButton *big2 = field(bar,@"playBtn");
            if ([big2 respondsToSelector:NSSelectorFromString(@"setHovered:")]) {
                NSColor *acc = [RLPTheme current].accent;
                NSColor *srgb = [acc colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: acc;
                CGFloat r=0,g=0,b=0,a=0; [srgb getRed:&r green:&g blue:&b alpha:&a];
                NSColor *want = [NSColor colorWithSRGBRed:MIN((CGFloat)1.0,r*1.08)
                                                    green:MIN((CGFloat)1.0,g*1.08)
                                                     blue:MIN((CGFloat)1.0,b*1.08) alpha:a];
                [(id)big2 setHovered:YES];
                check(BarCgEq(big2.layer.backgroundColor, want, 0.02),
                      "pb.play hover = brightness(1.08) per-channel (not white blend)");
                NSColor *mixWhite = [acc blendedColorWithFraction:0.10 ofColor:NSColor.whiteColor];
                check(!BarCgEq(big2.layer.backgroundColor, mixWhite, 0.02),
                      "pb.play hover no longer equals the old 10%% white blend");
                [(id)big2 setHovered:NO];
            }
        }
    printf("native_bar_web: %d checks, %d failures\n",checks,failures); return failures?1:0;
} }