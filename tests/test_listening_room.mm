// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_listening_room.mm — 聆听室（合并页）的判据（1.1.7.1）
//
// 用户要求：聆听室与快速开始合并成一页；页内设置全部用卡片式弹层就地完成，
// **不许跳设置页**；聆听模式里不许有「设置」入口；新增「听音风格」（本质是一组预设滤波）。
//
// 判据能证明真东西的关键：
//   A3 在**旧页面**上必然红（旧页有四个 identifier=adv/stream/meta/in 的跳设置按钮）；
//   A4/A5 是纯函数，钉住"档位只能选后端真实存在的滤波"与"DSD 档按源类型分流"。
#import <AppKit/AppKit.h>
#import "RLPListeningRoom.h"
#import "RLPQuickStartViewController.h"
#import "RLPSupport.h"

#include <cstdio>

static int gFail = 0, gPass = 0;
static void CK(BOOL ok, const char *what, NSString *detail) {
    if (ok) { ++gPass; std::printf("  [PASS] %s\n", what); }
    else { ++gFail; std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); }
}
static void CollectViews(NSView *v, NSMutableArray<NSView *> *out) {
    if (!v) return;
    [out addObject:v];
    for (NSView *s in v.subviews) CollectViews(s, out);
}
/// 构造一份"像 /api/filters 那样"的名单（含 gauss 族、tight、Nx 专用项）
static NSArray<NSDictionary *> *FakeFilters(void) {
    return @[
        @{@"name": @"poly-sinc-tight-lp",     @"taps": @4095,  @"forNx": @NO,  @"phase": @"linear"},
        @{@"name": @"poly-sinc-short",        @"taps": @1023,  @"forNx": @NO,  @"phase": @"linear"},
        @{@"name": @"poly-sinc-long",         @"taps": @16383, @"forNx": @NO,  @"phase": @"linear"},
        @{@"name": @"poly-sinc-gauss-short",  @"taps": @4095,  @"forNx": @NO,  @"phase": @"linear"},
        @{@"name": @"poly-sinc-gauss-long",   @"taps": @32767, @"forNx": @NO,  @"phase": @"linear"},
        @{@"name": @"poly-sinc-gauss-hires-lp",@"taps": @65535,@"forNx": @YES, @"phase": @"linear"},
    ];
}
static BOOL NameExists(NSString *n, NSArray<NSDictionary *> *items) {
    for (NSDictionary *it in items) if ([it[@"name"] isEqualToString:n]) return YES;
    return NO;
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        (void)app;
        std::printf("=== test_listening_room（聆听室合并页）===\n");

        // ---------- A5 播放三档 → profile（DSD 档必须按源类型分流）----------
        CK([RLPProfileForPlayMode(RLPPlayMode3Direct, NO) isEqualToString:@"bitperfect"],
           "A5a 原音直通(PCM源) ⟹ bitperfect", RLPProfileForPlayMode(RLPPlayMode3Direct, NO));
        CK([RLPProfileForPlayMode(RLPPlayMode3Direct, YES) isEqualToString:@"bitperfect"],
           "A5b 原音直通(DSD源) ⟹ bitperfect", RLPProfileForPlayMode(RLPPlayMode3Direct, YES));
        CK([RLPProfileForPlayMode(RLPPlayMode3Pcm, YES) isEqualToString:@"pcm"],
           "A5c PCM 升频恒 pcm", RLPProfileForPlayMode(RLPPlayMode3Pcm, YES));
        CK([RLPProfileForPlayMode(RLPPlayMode3Dsd, YES) isEqualToString:@"dsd"],
           "A5d DSD 档 + DSD 源 ⟹ dsd（DSD→DSD）", RLPProfileForPlayMode(RLPPlayMode3Dsd, YES));
        CK([RLPProfileForPlayMode(RLPPlayMode3Dsd, NO) isEqualToString:@"pcm2dsd"],
           "A5e DSD 档 + PCM 源 ⟹ pcm2dsd（PCM→DSD）", RLPProfileForPlayMode(RLPPlayMode3Dsd, NO));
        CK(RLPPathIsDsd(@"/m/a.dsf") && RLPPathIsDsd(@"/m/b.DFF") && !RLPPathIsDsd(@"/m/c.flac"),
           "A5f 源类型判定 dsf/dff/大小写", @"");

        // ---------- A4 听音风格 → 真实滤波（不许凭空造名）----------
        NSArray<NSDictionary *> *fs = FakeFilters();
        NSString *warm = RLPFilterForToneStyle(RLPToneStyleWarm, fs);
        NSString *sharp = RLPFilterForToneStyle(RLPToneStyleSharp, fs);
        NSString *bal = RLPFilterForToneStyle(RLPToneStyleBalanced, fs);
        CK(warm.length && [warm.lowercaseString rangeOfString:@"gauss"].location != NSNotFound,
           "A4a 温和档选出的滤波含 gauss", warm ?: @"nil");
        CK(sharp.length && [sharp.lowercaseString rangeOfString:@"gauss"].location == NSNotFound,
           "A4b 锐利档不含 gauss", sharp ?: @"nil");
        for (NSString *n in @[warm ?: @"", sharp ?: @"", bal ?: @""])
            CK(NameExists(n, fs), "A4c 档位映射结果必须来自后端名单", n);
        CK(![warm isEqualToString:sharp], "A4d 温和与锐利必须是不同滤波", @"");
        // Nx 专用项不该被听音风格选中（它在当前采样率下不生效）
        CK(![warm isEqualToString:@"poly-sinc-gauss-hires-lp"] &&
           ![sharp isEqualToString:@"poly-sinc-gauss-hires-lp"] &&
           ![bal isEqualToString:@"poly-sinc-gauss-hires-lp"],
           "A4e 不选 forNx 专用项", @"");
        CK(RLPFilterForToneStyle(RLPToneStyleWarm, @[]) == nil, "A4f 空名单 ⟹ nil（不臆造）", @"");
        // 反查回显
        CK(RLPToneStyleForFilter(warm, fs) == RLPToneStyleWarm, "A4g 反查温和档", @"");
        CK(RLPToneStyleForFilter(@"some-user-picked-filter", fs) == -1, "A4h 未知滤波 ⟹ 自定义(-1)", @"");
        CK(RLPFilterUsesNxKey(@"poly-sinc-gauss-hires-lp", fs) && !RLPFilterUsesNxKey(warm, fs),
           "A4i forNx 项写 filterNx 键", @"");

        // ---------- A1/A2/A3 页面契约 ----------
        RLPQuickStartViewController *vc = [[RLPQuickStartViewController alloc] init];
        vc.view.frame = NSMakeRect(0, 0, 1100, 760);
        [vc.view layoutSubtreeIfNeeded];
        CK(vc.view != nil, "A1a 聆听室可离线构建（无核心不崩）", @"");
        CK([vc.pageTitle isEqualToString:RLPTr(@"聆听室")], "A1b 标题是「聆听室」", vc.pageTitle ?: @"nil");

        NSMutableArray<NSView *> *all = [NSMutableArray array];
        CollectViews(vc.view, all);
        NSArray<NSString *> *cards = @[@"room.device", @"room.output", @"room.play", @"room.style"];
        for (NSString *k in cards) {
            BOOL found = NO;
            for (NSView *v in all) if ([v.identifier isEqualToString:k]) found = YES;
            CK(found, [[NSString stringWithFormat:@"A2 四张卡存在 %@", k] UTF8String], @"缺失");
        }

        // ★ A3：不许有跳设置页的入口（旧页面在这里必然红）
        NSMutableArray<NSString *> *bad = [NSMutableArray array];
        NSArray<NSString *> *jumpIds = @[@"adv", @"out", @"eq", @"stream", @"in", @"meta"];
        for (NSView *v in all) {
            if (![v isKindOfClass:[NSButton class]]) continue;
            NSButton *b = (NSButton *)v;
            if (b.identifier.length && [jumpIds containsObject:b.identifier])
                [bad addObject:[NSString stringWithFormat:@"id=%@", b.identifier]];
            if ([b.title rangeOfString:RLPTr(@"设置")].location != NSNotFound)
                [bad addObject:[NSString stringWithFormat:@"title=%@", b.title]];
        }
        CK(bad.count == 0, "A3 聆听室没有跳设置页的入口（用户硬要求）",
           [bad componentsJoinedByString:@", "]);

        std::printf("\n%s（%d 项失败）\n", gFail == 0 ? "listening_room 全部通过" : "listening_room 有失败", gFail);
        return gFail == 0 ? 0 : 1;
    }
}
