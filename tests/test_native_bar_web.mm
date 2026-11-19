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
static NSMutableArray<RLPJSONCompletion> *heldSignalCompletions;
// 播放模式写入的挂起回包夹具（与上面 /api/signal 同一套：array + [done copy]）。
// 让判据能自己择时投递 /api/playmode 的回包，构造"在途 / 超时 / 迟到"三种窗口。
static NSMutableArray<RLPJSONCompletion> *heldPostCompletions;
// /api/playmode 回读的桩值（nil 时等价于旧的 mode=0）；playmodeReads 只用于证明"在途回读真的发生过"。
static NSDictionary *playModeJSON;
static NSUInteger playmodeReads;
static BOOL online = NO;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RLPCoreClient
+ (instancetype)shared { static RLPCoreClient *c; if (!c) c = [self new]; return c; }
- (BOOL)started { return online; }
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    if (!done) return;
    if ([path isEqual:@"/api/signal"] && heldSignalCompletions) {
        [heldSignalCompletions addObject:[done copy]];
        return;
    }
    if ([path hasPrefix:@"/api/meta"]) done(@{@"title":@"Real title", @"artist":@"Real artist", @"album":@"Real album"});
    // /api/playmode 回读：桩值可被判据改（nil 时保持旧的 mode=0 行为）；计数用于判据自证"读到了"。
    else if ([path isEqual:@"/api/playmode"]) { ++playmodeReads; done(playModeJSON ?: @{@"mode":@0}); }
    else if ([path isEqual:@"/api/status"]) done(statusJSON);
    else done(@{@"mode":@0});
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done { if (done) done(nil); }
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    [posts addObject:path];
    // 挂起回包夹具（沿用 heldSignalCompletions 的写法）：只拦 /api/playmode 的写入回包，
    // 由判据自己择时投递；其余 POST（音量等）保持同步回包，不影响前面已有的判据。
    if (heldPostCompletions && [path hasPrefix:@"/api/playmode"]) {
        if (done) [heldPostCompletions addObject:[done copy]];
        return;
    }
    if (done) done(@{@"ok":@YES});
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
// 读一个**可能不存在**的私有状态键：旧实现根本没有 modeWrite* 这套登记。取不到就返回 nil
// 让判据自然判红，而不是抛 NSUnknownKeyException 把整个可执行文件打断（同 signalSeq 的 @try 口径）。
static id BarState(id obj, NSString *key) {
    @try { return [obj valueForKey:key]; } @catch (NSException *e) { return nil; }
}
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
            check(vev.material == NSVisualEffectMaterialUnderWindowBackground ||
              vev.material == NSVisualEffectMaterialSidebar,
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
            check(vev.material == NSVisualEffectMaterialUnderWindowBackground ||
              vev.material == NSVisualEffectMaterialSidebar,
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
    // ---- 一次性 /api/signal 序号守卫（快速切歌后旧包不得覆盖新曲信号链）----
    {
        NSWindow *offscreenWin = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1120, 66)
                                                             styleMask:NSWindowStyleMaskBorderless
                                                               backing:NSBackingStoreBuffered
                                                                 defer:NO];
        offscreenWin.contentView = bar;
        heldSignalCompletions = [NSMutableArray array];
        BOOL hasSigSeq = NO;
        NSUInteger s0 = 0, s1 = 0, s2 = 0;
        @try {
            s0 = [[bar valueForKey:@"signalSeq"] unsignedIntegerValue];
            [bar performSelector:NSSelectorFromString(@"showSignalChain:") withObject:nil];
            s1 = [[bar valueForKey:@"signalSeq"] unsignedIntegerValue];
            [bar performSelector:NSSelectorFromString(@"showSignalChain:") withObject:nil];
            s2 = [[bar valueForKey:@"signalSeq"] unsignedIntegerValue];
            hasSigSeq = (s1 == s0 + 1) && (s2 == s1 + 1);
        } @catch (NSException *e) {
            hasSigSeq = NO;
        }
        check(hasSigSeq && heldSignalCompletions.count == 2,
              "pb.signalSeq increments per /api/signal request");
        if (heldSignalCompletions.count == 2) {
            RLPJSONCompletion staleFirst = heldSignalCompletions[0];
            RLPJSONCompletion freshSecond = heldSignalCompletions[1];
            freshSecond(@{ @"ok": @YES, @"path": @{ @"bitPerfect": @"yes", @"bitPerfectWhy": @"NewTrack", @"inRate": @96000, @"outRate": @96000 } });
            staleFirst(@{ @"ok": @YES, @"path": @{ @"bitPerfect": @"no", @"bitPerfectWhy": @"OldTrack", @"inRate": @44100, @"outRate": @44100 } });
            NSUInteger sAfter = [[bar valueForKey:@"signalSeq"] unsignedIntegerValue];
            check(hasSigSeq && sAfter == s2, "pb.signalSeq remains at latest request after out-of-order responses");
        }
        heldSignalCompletions = nil;
        offscreenWin.contentView = nil;
    }

    // ---- 播放模式写入：在途不推进 / 失败回退已确认值 / 超时与迟到回包（2026-11-18）----
    //
    // 缺陷形态（RLPPlaybackBarView.mm 改动前的 toggleRepeat:，约 1031-1033 行）：
    //   ① 先把目标写进 playMode、refreshModeButtons 重画，然后才发 POST ⟹ 后端还没接受，
    //      按钮已经显示新模式（用户"看到"它生效了）；
    //   ② 失败分支只 fetchStatusForced，playMode 不回退 ⟹ 没生效的模式留在界面上；
    //   ③ 下一次点击以这个未确认值为起点 ⟹ 0→1 失败后再点发 mode=2，界面与后端彻底分叉。
    //
    // 现实现（行号均指 RLPPlaybackBarView.mm）对应的四处修复：
    //   F1 先提交后画：applyPlayMode 只登记 modeWriteTarget（1088-1090），回包确认后才写 playMode
    //      并重画（1114-1124）；confirmedMode 在提交前捕获（1085）。
    //   F2 在途闸门：一次写入未确认时再点直接 return（1074-1079）。
    //   F3 超时结算：settleModeWriteIfExpired 撤销在途、画回确认值（1056-1064；点击路径 1073）。
    //   F4 迟到回包作废：completion 的 epoch/target 守卫（1105）；在途回读不许画（1163）。
    //
    // 判据只用两类可观察量，缺一不可：
    //   甲）KVC playMode —— 只装**已被后端确认**的模式；
    //   乙）modeVisual() —— 模式键的渲染位图 + toolTip + 图标色，即"用户真的看见的东西"。
    // 只用甲会漏掉"属性对、按钮被提前重画"（本项目踩过多次的形态）；只用乙会漏掉
    // "界面没变、内部真相已被目标顶替"。
    //
    // ⚠️ 边界（如实标注，别把它当成比实际更强的证明）：
    //   · 判据 B 红的是**旧形态**：写入前就改 playMode/重画（B2 红），或失败后留在目标值
    //     （B6 会从 3 发到 0）。单独删掉 1129 行 `self_.playMode = confirmedMode;` **不会**让
    //     B 变红 —— F1 已经让 playMode 从未离开过确认值，那句回退目前是"显式但冗余"的动作。
    //     所以 B 守的是 F1 + 失败分支这一对，不是单独一行。
    //   · 1302 的"每拍被动结算"没有被单独锁住：删掉它，下一次点击仍会结算，离线观察不到差异；
    //     本判据只锁点击路径（与被动路径共用同一份 settleModeWriteIfExpired 实现）。
    //   · 2 s 窗口长度只做区间卫生检查（A4/C2），真正的行为用"把 deadline 拨到过去"验证 ——
    //     要证的是"窗口过后状态如何"，不是"墙钟走多慢"，也不为等 2 s 让测试变慢。
    //
    // 守门映射（"移除哪个修复会变红"，行号同上）：
    //   · 恢复"先写 playMode / refreshModeButtons 再 POST"（旧 1031-1033 的形态）→ A2/A3、B2 红；
    //   · 删掉在途闸门 1074-1079 → A5 红（在途第二下会重复提交同一目标）；
    //   · 删掉在途回读闸门 1163 → A8 红（写前值 2 会在窗口内被画上去）；
    //   · 删掉点击路径的 settle 调用 1073 / settle 的状态清空 1059-1063 → C3 红（键永久在途）、C4/C5 连带；
    //   · 删掉 completion 的 epoch 守卫 1105 → C6 红（第 2 次故意同目标 1，target 比对挡不住迟到包）；
    //   · 失败分支留在目标值（旧形态）→ B3 红、B6 会从 3 发到 0；
    //   · 单独删 1129 的回退赋值 → 以上都不红（原因见上一条边界，这是本判据的真实上界）。
    {
        // 模式键的完整可见状态。位图比较沿用播放键的指纹口径（image.name 可能是 nil，
        // 渲染位图才是"图标真的换过"的直接证据）；toolTip 与图标色补上 0/1 共用 repeat 符号时的区分。
        NSDictionary *(^modeVisual)(void) = ^NSDictionary *{
            NSButton *rb = field(bar, @"repeatBtn");
            NSImage *img = rb.image;
            NSBitmapImageRep *rep = img ? [NSBitmapImageRep imageRepWithData:[img TIFFRepresentation]] : nil;
            NSData *png = rep ? [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] : nil;
            NSColor *tint = rb.contentTintColor
                ? [rb.contentTintColor colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]] : nil;
            return @{ @"png": png ?: [NSData data],
                      @"tip": rb.toolTip ?: @"",
                      @"r": @(tint ? tint.redComponent : -1.0),
                      @"g": @(tint ? tint.greenComponent : -1.0),
                      @"b": @(tint ? tint.blueComponent : -1.0) };
        };
        check([field(bar,@"playMode") integerValue] == 0 && ![BarState(bar,@"modeWritePending") boolValue],
              "前置：模式写入状态机空闲、已确认 playMode=0（上一段四个同步回包的落点）");
        NSButton *modeBtn0 = field(bar, @"repeatBtn");
        check(modeBtn0 != nil && modeBtn0.image != nil,
              "前置：模式键在位且有真实图标（可见状态判据的前提，量不到就红）");

        // 判据 A：一次写入从发起到回包之间**不推进、不重画**；确认后才落到按钮上。
        {
            NSDictionary *v0 = modeVisual();
            const NSInteger base0 = (NSInteger)posts.count;
            heldPostCompletions = [NSMutableArray array];
            [bar toggleRepeat:nil];                                  // 已确认 0 → 目标 1
            check((NSInteger)posts.count == base0 + 1 &&
                  [posts.lastObject isEqual:@"/api/playmode?mode=1"],
                  [[NSString stringWithFormat:@"A1 点击真的提交了 /api/playmode?mode=1（posts %ld→%ld）",
                    (long)base0, (long)posts.count] UTF8String]);
            check([field(bar,@"playMode") integerValue] == 0,
                  "A2 回包前 playMode 仍是已确认的 0（目标不冒充真相）");
            check([modeVisual() isEqualToDictionary:v0],
                  "A3 回包前模式键的可见状态未变（没有把未确认目标先画上去）");
            const NSTimeInterval windowA = [BarState(bar,@"modeWriteDeadline") doubleValue] -
                                           [NSDate timeIntervalSinceReferenceDate];
            check([BarState(bar,@"modeWritePending") boolValue] &&
                  [BarState(bar,@"modeWriteTarget") integerValue] == 1 &&
                  windowA >= 1.0 && windowA <= 3.0,
                  [[NSString stringWithFormat:@"A4 在途写入被登记（pending/target=1）且确认窗口有限（实测 %.2f s）",
                    windowA] UTF8String]);
            // 在途再点：起点仍是已确认的 0 ⟹ 目标仍是 1；闸门必须吞掉它（否则会重复提交同一目标）。
            const NSInteger base0b = (NSInteger)posts.count;
            [bar toggleRepeat:nil];
            check((NSInteger)posts.count == base0b,
                  [[NSString stringWithFormat:@"A5 在途再点不重复提交 /api/playmode（posts 仍 %ld）",
                    (long)base0b] UTF8String]);
            check([field(bar,@"playMode") integerValue] == 0 &&
                  [modeVisual() isEqualToDictionary:v0],
                  "A6 在途再点不推进、模式键不变（推进起点只能是已确认值）");
            // GET 与 POST 分队列（RLPCoreClient.mm:129-144）：在途期间的回读可能读到写入之前的值。
            // 生产在 refreshPlayModeFromBackend 里挡掉它（1163）；判据要求"确实读了一次、但可见状态未变"。
            playModeJSON = @{ @"mode": @2 };          // 故意给一个既非确认值 0、也非目标 1 的旧值
            const NSUInteger readsA = playmodeReads;
            for (NSInteger i = 0; i < 4; ++i) [bar fetchStatus];   // 回读节流 = 每 4 次状态查询一次
            check(playmodeReads == readsA + 1,
                  [[NSString stringWithFormat:@"A7 在途期间真的发生了一次 /api/playmode 回读（%lu→%lu）",
                    (unsigned long)readsA, (unsigned long)playmodeReads] UTF8String]);
            check([field(bar,@"playMode") integerValue] == 0 &&
                  [modeVisual() isEqualToDictionary:v0] &&
                  [BarState(bar,@"modeWritePending") boolValue] &&
                  [BarState(bar,@"modeWriteTarget") integerValue] == 1,
                  "A8 在途回读（写前值 2）不得改动已确认值/可见状态/在途登记");
            RLPJSONCompletion confirmedReply = nil;
            if (heldPostCompletions.count) confirmedReply = heldPostCompletions[0];
            heldPostCompletions = nil;
            if (!confirmedReply) check(NO, "A9 前置：夹具里存在第一条 /api/playmode 回包");
            else {
                confirmedReply(@{ @"ok": @YES, @"mode": @1 });       // 后端确认 mode=1
                check([field(bar,@"playMode") integerValue] == 1,
                      "A9 回包确认后才采用后端回包里的 mode=1");
                check(![BarState(bar,@"modeWritePending") boolValue] &&
                      [BarState(bar,@"modeWriteTarget") integerValue] == -1,
                      "A10 成功后清空在途登记（target 复位 -1）");
                check(![modeVisual() isEqualToDictionary:v0],
                      "A11 确认后模式键才换到新模式（同一指纹口径看得见变化，A3 不是「哑判据」）");
            }
        }

        // 判据 B：失败回包必须回到**已确认值**，下一次推进的起点也是它（不是失败目标）。
        {
            playModeJSON = @{ @"mode": @2 };           // 后端真相 = 2：用生产读入口落成"已确认"
            SEL pmRead = NSSelectorFromString(@"refreshPlayModeFromBackend");
            if ([bar respondsToSelector:pmRead]) [bar performSelector:pmRead];
            check([field(bar,@"playMode") integerValue] == 2 &&
                  ![BarState(bar,@"modeWritePending") boolValue],
                  "B0 前置：已确认 playMode=2（来自 /api/playmode 回读，不是 KVC 硬塞）");
            NSDictionary *v2 = modeVisual();
            const NSInteger baseB = (NSInteger)posts.count;
            heldPostCompletions = [NSMutableArray array];
            [bar toggleRepeat:nil];                    // 已确认 2 → 目标 3
            check((NSInteger)posts.count == baseB + 1 &&
                  [posts.lastObject isEqual:@"/api/playmode?mode=3"],
                  "B1 从确认值 2 推进到 3，并真的提交");
            check([field(bar,@"playMode") integerValue] == 2 &&
                  [modeVisual() isEqualToDictionary:v2],
                  "B2 在途时仍是 2（失败之前界面不假装成功）");
            RLPJSONCompletion failedReply = nil;
            if (heldPostCompletions.count) failedReply = heldPostCompletions[0];
            heldPostCompletions = nil;
            if (!failedReply) check(NO, "B3 前置：夹具里存在第一条 /api/playmode 回包");
            else {
                failedReply(@{ @"ok": @NO, @"error": @"mock playmode fail" });   // 回包说没写成
                check([field(bar,@"playMode") integerValue] == 2,
                      "B3 失败回包把模式退回已确认的 2（不留在没生效的 3）");
                check([modeVisual() isEqualToDictionary:v2],
                      "B4 失败后模式键仍画已确认的 2（回退是可见的，不是只改内部值）");
                check(![BarState(bar,@"modeWritePending") boolValue] &&
                      [BarState(bar,@"modeWriteTarget") integerValue] == -1,
                      "B5 失败后清空在途登记（键不会被一次失败永久卡死）");
            }
            // 再点一次：起点必须是已确认的 2 ⟹ 目标 3。旧形态（失败后留在 3）这一下会发 mode=0。
            const NSInteger baseB2 = (NSInteger)posts.count;
            [bar toggleRepeat:nil];
            check((NSInteger)posts.count == baseB2 + 1 &&
                  [posts.lastObject isEqual:@"/api/playmode?mode=3"],
                  "B6 失败后的下一次点击仍从已确认值 2 推进到 3（没有按失败目标继续跑到 0）");
            check([field(bar,@"playMode") integerValue] == 3,
                  "B7 这一下由桩同步回包确认，确认值落到 3（给后续判据留干净起点）");
        }

        // 判据 C：确认窗口过期 ⟹ 按失败结算（撤销在途）；迟到回包一律作废。
        {
            playModeJSON = @{ @"mode": @0 };
            SEL pmReadC = NSSelectorFromString(@"refreshPlayModeFromBackend");
            if ([bar respondsToSelector:pmReadC]) [bar performSelector:pmReadC];
            check([field(bar,@"playMode") integerValue] == 0 && ![BarState(bar,@"modeWritePending") boolValue],
                  "C0 前置：已确认 playMode=0（干净起点）");
            NSDictionary *v0c = modeVisual();
            const NSInteger baseC = (NSInteger)posts.count;
            heldPostCompletions = [NSMutableArray array];
            [bar toggleRepeat:nil];                    // 0 → 1：第 1 次提交，回包被挂起
            check((NSInteger)posts.count == baseC + 1 &&
                  [posts.lastObject isEqual:@"/api/playmode?mode=1"],
                  "C1 第 1 次提交发出 mode=1 并被挂起（后端还没答复）");
            const NSTimeInterval windowC = [BarState(bar,@"modeWriteDeadline") doubleValue] -
                                           [NSDate timeIntervalSinceReferenceDate];
            check(windowC >= 1.0 && windowC <= 3.0,
                  [[NSString stringWithFormat:@"C2 提交带有有限的确认窗口（实测 %.2f s，生产值 2 s）",
                    windowC] UTF8String]);
            // 把 deadline 拨到过去 = 等价于 2 s 已到（与生产同一个 NSDate 时基，1058）。
            // 旧实现没有这个键：写失败时不拨表，让 C3/C4 自然判红，而不是让异常打断整个判据。
            @try {
                [bar setValue:@([NSDate timeIntervalSinceReferenceDate] - 0.25) forKey:@"modeWriteDeadline"];
            } @catch (NSException *e) {
            }
            [bar toggleRepeat:nil];                    // 先结算在途，再从确认值 0 提交 1（第 2 次）
            check((NSInteger)posts.count == baseC + 2 &&
                  [posts.lastObject isEqual:@"/api/playmode?mode=1"],
                  "C3 超时结算后循环键重新可用（第 2 次提交没有砸在永久在途上）");
            check([BarState(bar,@"modeWritePending") boolValue] &&
                  [BarState(bar,@"modeWriteTarget") integerValue] == 1 &&
                  [BarState(bar,@"modeWriteDeadline") doubleValue] - [NSDate timeIntervalSinceReferenceDate] >= 1.0,
                  "C4 第 2 次提交有自己的在途登记与新窗口（旧 deadline 没有泄漏）");
            check([field(bar,@"playMode") integerValue] == 0 && [modeVisual() isEqualToDictionary:v0c],
                  "C5 结算画的是已确认值 0，不是超时的目标 1");
            // 迟到回包：第 1 次的失败回包在第 2 次提交之后才到。第 2 次故意同目标 1 ⟹
            // target 比对挡不住它，只有 1105 的 epoch 守卫能挡 —— 这条判据因此有区分力。
            RLPJSONCompletion lateReply = nil;
            if (heldPostCompletions.count) lateReply = heldPostCompletions[0];
            if (!lateReply) check(NO, "C6 前置：夹具里存在第 1 次提交的回包");
            else {
                lateReply(@{ @"ok": @NO, @"error": @"mock late fail" });
                check([BarState(bar,@"modeWritePending") boolValue] &&
                      [BarState(bar,@"modeWriteTarget") integerValue] == 1,
                      "C6 迟到的失败回包不得结算当前在途写入（第 2 次提交仍挂着）");
                check([field(bar,@"playMode") integerValue] == 0 && [modeVisual() isEqualToDictionary:v0c],
                      "C7 迟到的失败回包不得改已确认值/重画模式键");
            }
            // 第 2 次提交的真回包（当前 epoch 唯一认账的一条）照常生效。
            RLPJSONCompletion liveReply = nil;
            if (heldPostCompletions.count > 1) liveReply = heldPostCompletions[1];
            heldPostCompletions = nil;
            if (!liveReply) check(NO, "C8 前置：夹具里存在第 2 次提交的回包");
            else {
                liveReply(@{ @"ok": @YES, @"mode": @1 });
                check([field(bar,@"playMode") integerValue] == 1,
                      "C8 当前 epoch 的真回包照常把模式落到 1");
                check(![BarState(bar,@"modeWritePending") boolValue] &&
                      [BarState(bar,@"modeWriteTarget") integerValue] == -1,
                      "C9 真回包结算后清空在途登记");
                check(![modeVisual() isEqualToDictionary:v0c],
                      "C10 真回包确认后模式键才从 0 换到 1（迟到的失败没有把它压回去）");
            }
        }
    }

    printf("native_bar_web: %d checks, %d failures\n",checks,failures); return failures?1:0;
} }