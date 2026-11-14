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
#import "RLPTheme.h"

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

        // ---------- Q 系列：v3.3.11 quickStartModel 的能力门控（纯函数）----------
        // 旧码把 /api/preset/caps 拉下来就丢掉（(void)json），三档永远可点 ——
        // 用户点了才在后端 notes 里看到降级原因，事先毫无提示。
        {
            NSDictionary *full = @{ @"ok": @YES,
                @"device": @{ @"name": @"Mac Speakers", @"backend": @"coreaudio",
                              @"rates": @[ @44100, @48000, @96000 ], @"maxRate": @96000,
                              @"dsdNative": @NO, @"dop": @YES } };
            NSDictionary *g1 = [RLPQuickStartViewController gatingForCapsJSON:full];
            CK([g1[@"known"] boolValue], "Q1a 完整能力 ⟹ known", @"");
            CK([g1[@"pcmReady"] boolValue], "Q1b 完整能力 ⟹ PCM 可用", @"");
            CK([g1[@"dsdReady"] boolValue], "Q1c 有 DoP ⟹ DSD 可用（mac 只有 DoP 通路）", @"");
            NSDictionary *noDsd = @{ @"ok": @YES,
                @"device": @{ @"name": @"USB DAC", @"backend": @"coreaudio",
                              @"rates": @[ @44100 ], @"maxRate": @44100,
                              @"dsdNative": @NO, @"dop": @NO } };
            NSDictionary *g2 = [RLPQuickStartViewController gatingForCapsJSON:noDsd];
            CK(![g2[@"dsdReady"] boolValue], "Q2a 无 DoP 无 Native ⟹ DSD 不可用", @"");
            CK([g2[@"pcmReady"] boolValue], "Q2b 但 PCM 仍可用（不连坐）", @"");
            NSDictionary *off = @{ @"ok": @YES,
                @"device": @{ @"name": @"离线处理（Null）", @"backend": @"null",
                              @"rates": @[ @44100 ], @"maxRate": @44100, @"dop": @YES } };
            NSDictionary *g3 = [RLPQuickStartViewController gatingForCapsJSON:off];
            CK(![g3[@"known"] boolValue], "Q3 离线处理 ⟹ known=false", @"");
            CK(![g3[@"pcmReady"] boolValue] && ![g3[@"dsdReady"] boolValue],
               "Q3b 离线时两档都不可用（不假装支持）", @"");
            NSDictionary *g4 = [RLPQuickStartViewController gatingForCapsJSON:
                @{ @"ok": @YES,
                   @"device": @{ @"name": @"", @"backend": @"coreaudio", @"rates": @[], @"maxRate": @0 } }];
            CK(![g4[@"known"] boolValue], "Q4 无名/无率 ⟹ 能力未确认", @"");
            NSDictionary *g5 = [RLPQuickStartViewController gatingForCapsJSON:@{ @"ok": @NO }];
            CK(![g5[@"known"] boolValue] && ![g5[@"pcmReady"] boolValue], "Q5a ok:false ⟹ 不可用", @"");
            NSDictionary *g6 = [RLPQuickStartViewController gatingForCapsJSON:nil];
            CK(![g6[@"known"] boolValue] && ![g6[@"pcmReady"] boolValue],
               "Q5b nil ⟹ 不可用（不臆造能力）", @"");
        }

        // ---------- A6 主题切换：自建颜色必须重刷（历史真故障）----------
        // 为什么必须单独判：切到浅色后，卡片里那些 applyTheme 漏掉的标签会继续停在深色主题的
        // 颜色上 —— 浅底浅字/深底深字，肉眼几乎看不见字，而"能构造出来"之类的判据全绿。
        // 判据口径：把上一主题的调色板与当前主题的调色板都算出来；某个标签的颜色若只属于
        // **上一主题**而不属于当前主题，就说明它没被重刷。
        {
            [RLPTheme setThemeName:@"dark"];
            RLPTheme *darkT = [RLPTheme current];
            RLPQuickStartViewController *tv = [[RLPQuickStartViewController alloc] init];
            tv.view.frame = NSMakeRect(0, 0, 1100, 760);
            [tv.view layoutSubtreeIfNeeded];

            NSMutableArray<NSView *> *tvAll = [NSMutableArray array];
            CollectViews(tv.view, tvAll);
            // 快照：切主题前每个文本标签的颜色（只取页内**常驻**标签，不含空态占位）
            NSMutableArray<NSArray *> *labels = [NSMutableArray array];
            for (NSView *v in tvAll) {
                if (![v isKindOfClass:[NSTextField class]]) continue;
                NSTextField *tf = (NSTextField *)v;
                if (!tf.stringValue.length || !tf.textColor) continue;
                [labels addObject:@[ tf, tf.stringValue, tf.textColor ]];
            }
            CK(labels.count > 0, "A6 页内确实有文字标签（否则本判据空转）",
               [NSString stringWithFormat:@"labels=%lu", (unsigned long)labels.count]);

            [RLPTheme setThemeName:@"light"];
            RLPTheme *lightT = [RLPTheme current];
            [tv applyTheme];
            [tv.view layoutSubtreeIfNeeded];

            // 上一主题的"专属色"：只出现在 dark 调色板、不出现在 light 调色板的颜色。
            NSArray<NSColor *> *darkPalette = @[ darkT.text, darkT.text2, darkT.mut ];
            NSArray<NSColor *> *lightPalette = @[ lightT.text, lightT.text2, lightT.mut,
                                                  lightT.accentText, lightT.accent ];
            NSMutableArray<NSString *> *stuck = [NSMutableArray array];
            for (NSArray *row in labels) {
                NSTextField *tf = row[0];
                NSColor *before = row[2];
                NSColor *now = tf.textColor;
                BOOL onlyInDark = NO;
                for (NSColor *d in darkPalette) if ([before isEqual:d]) onlyInDark = YES;
                for (NSColor *l in lightPalette) if ([before isEqual:l]) onlyInDark = NO;
                BOOL inLight = NO;
                for (NSColor *l in lightPalette) if ([now isEqual:l]) inLight = YES;
                if (onlyInDark && !inLight)
                    [stuck addObject:[NSString stringWithFormat:@"\"%@\"", row[1]]];
            }
            CK(stuck.count == 0,
               "A6 切到浅色后没有标签停留在深色主题的颜色上",
               [stuck componentsJoinedByString:@", "]);

            // 卡片的 layer 底色也必须跟着走（否则浅色主题下是一块块深色板）
            NSMutableArray<NSString *> *stuckLayers = [NSMutableArray array];
            for (NSView *v in tvAll) {
                if (!v.wantsLayer || !v.layer.backgroundColor || !v.identifier.length) continue;
                NSColor *bg = [NSColor colorWithCGColor:v.layer.backgroundColor];
                if ([bg isEqual:darkT.bg2] && ![bg isEqual:lightT.bg2])
                    [stuckLayers addObject:v.identifier];
            }
            CK(stuckLayers.count == 0,
               "A6 切到浅色后卡片的 layer 底色跟着重刷",
               [stuckLayers componentsJoinedByString:@", "]);

            [RLPTheme setThemeName:@"dark"];
        }

        std::printf("\n%s（%d 项失败）\n", gFail == 0 ? "listening_room 全部通过" : "listening_room 有失败", gFail);
        return gFail == 0 ? 0 : 1;
    }
}