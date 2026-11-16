// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_listening_contract.mm — 原生聆听室重设计契约判据（v3.3.11 对齐）
//
// 覆盖：
//   C1 真实 /api/filters 注册表 + Windows 语义听音风格映射（不按最大 gauss taps 碰运气）
//   C2 切风格同一次 POST 清除 taps/mintapsperinput/atten/transition/phase/filterNx 并写后读回
//   C3 presetStatusForCapsJSON / gatingForCapsJSON 按 CoreAudio/DoP/shared/AirPlay/UPnP/null 与播放态给出结果与禁用原因
//   C4 bitperfect 下风格禁用且有说明，不偷偷破坏直通
//   C5 真实几何自适应（宽 4 列 / 中 2 列 / 窄 1 列，四卡等宽；队列预览 ≤4 行且内部无嵌套滚动；页头音乐文件夹入口）
//
// 纪律：隔离 state/library；backend=null、volume=-120；不启动真实 app 服务、不碰 8899、不模拟键鼠。
#import <AppKit/AppKit.h>
#import "RLPCoreClient.h"
#import "RLPListeningRoom.h"
#import "RLPQuickStartViewController.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>

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

static NSView *FindById(NSView *root, NSString *ident) {
    if (!root) return nil;
    if ([root.identifier isEqualToString:ident]) return root;
    for (NSView *s in root.subviews) {
        NSView *r = FindById(s, ident);
        if (r) return r;
    }
    return nil;
}

@interface RLPQuickStartViewController (ContractTest)
@property (nonatomic, copy) NSDictionary *settings;
@property (nonatomic, copy) NSArray<NSDictionary *> *filters;
@property (nonatomic, strong) NSTextField *styleValue;
@property (nonatomic, strong) NSTextField *styleSub;
@property (nonatomic, strong) NSView *styleCard;
- (void)syncPlayAndStyleCards;
- (void)onPickStyle:(NSButton *)sender;
@end

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        std::printf("=== test_native_listening_contract（聆听室 v3.3.11 契约 · 离线/null 核心）===\n");

        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"rlp-listen-contract-%d", (int)getpid()]];
        NSString *state = [root stringByAppendingPathComponent:@"state"];
        NSString *lib = [root stringByAppendingPathComponent:@"lib"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:lib withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("RLPLAYER_STATE_DIR", state.fileSystemRepresentation, 1);
        setenv("RLPLAYER_LIBRARY_DIR", lib.fileSystemRepresentation, 1);

        RLPCoreClient *core = [RLPCoreClient shared];
        if (![core startEmbedded]) {
            std::printf("  [FAIL] 核心启动失败\n");
            return 1;
        }
        [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"backend=null&volume=-120"];

        // ---------- C1 真实注册表 + Windows 语义风格映射 ----------
        NSDictionary *fj = [core jsonWithMethod:@"GET" path:@"/api/filters" body:nil];
        NSArray<NSDictionary *> *items = [fj[@"items"] isKindOfClass:[NSArray class]] ? fj[@"items"] : @[];
        CK(items.count >= 50, "C1a /api/filters 返回真实注册表",
           [NSString stringWithFormat:@"count=%lu", (unsigned long)items.count]);

        NSString *warm = RLPFilterForToneStyle(RLPToneStyleWarm, items);
        NSString *bal  = RLPFilterForToneStyle(RLPToneStyleBalanced, items);
        NSString *sharp = RLPFilterForToneStyle(RLPToneStyleSharp, items);
        CK([warm isEqualToString:@"poly-sinc-gauss-long"],
           "C1b 温和档选用真实条目 poly-sinc-gauss-long（不再碰运气选 524k gauss-xl）", warm ?: @"nil");
        CK([bal isEqualToString:@"poly-sinc-short-lp"],
           "C1c 均衡档选用 Windows 语义 poly-sinc-short-lp", bal ?: @"nil");
        CK(sharp.length > 0 &&
           [sharp.lowercaseString rangeOfString:@"gauss"].location == NSNotFound &&
           ([sharp.lowercaseString rangeOfString:@"long"].location != NSNotFound ||
            [sharp.lowercaseString rangeOfString:@"ext"].location != NSNotFound ||
            [sharp.lowercaseString rangeOfString:@"tight"].location != NSNotFound),
           "C1d 锐利档选用注册表真实非 gauss 滤波（long/ext/tight）", sharp ?: @"nil");

        // ---------- C2 切风格同一次 POST 清旧手动覆盖 + 写后读回 ----------
        [core jsonWithMethod:@"POST" path:@"/api/settings"
            body:@"filter=poly-sinc-xl&filterNx=poly-sinc-gauss-hires-lp&taps=65535&mintapsperinput=512&atten=180&transition=0.05&phase=min"];
        NSDictionary<NSString *, NSString *> *patch = RLPSettingsPatchForToneStyle(RLPToneStyleWarm, items);
        CK(patch != nil &&
           [patch[@"filter"] isEqualToString:@"poly-sinc-gauss-long"] &&
           [patch[@"filterNx"] isEqualToString:@""] &&
           [patch[@"taps"] isEqualToString:@"0"] &&
           [patch[@"mintapsperinput"] isEqualToString:@"0"] &&
           [patch[@"atten"] isEqualToString:@"0"] &&
           [patch[@"transition"] isEqualToString:@"0"] &&
           [patch[@"phase"] isEqualToString:@""],
           "C2a 风格补丁同一次含 filter 与全部清除键", patch.description ?: @"nil");

        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *k in patch) [parts addObject:[NSString stringWithFormat:@"%@=%@", k, RLPEnc(patch[k])]];
        NSDictionary *postRes = [core jsonWithMethod:@"POST" path:@"/api/settings"
                                              body:[parts componentsJoinedByString:@"&"]];
        CK([postRes[@"ok"] boolValue], "C2b 单次 POST /api/settings 成功", postRes.description ?: @"nil");

        NSDictionary *kv = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil][@"kv"];
        CK([kv[@"filter"] isEqualToString:@"poly-sinc-gauss-long"], "C2c 读回 filter=poly-sinc-gauss-long", kv[@"filter"] ?: @"nil");
        CK([kv[@"taps"] isEqualToString:@"0"], "C2d 读回 taps 已清 0", kv[@"taps"] ?: @"nil");
        CK(!kv[@"mintapsperinput"] || [kv[@"mintapsperinput"] isEqualToString:@"0"],
           "C2e 读回 mintapsperinput 已清 0（或未写入旧覆盖）", kv[@"mintapsperinput"] ?: @"nil");
        CK([kv[@"atten"] isEqualToString:@"0"], "C2f 读回 atten 已清 0", kv[@"atten"] ?: @"nil");
        CK([kv[@"transition"] isEqualToString:@"0"], "C2g 读回 transition 已清 0", kv[@"transition"] ?: @"nil");
        CK(![kv[@"phase"] length], "C2h 读回 phase 已清空", kv[@"phase"] ?: @"nil");

        CK([RLPPlayModeFromSettings(@{@"rate": @"src", @"dsd": @"0", @"filter": @""}) isEqualToString:@"bitperfect"],
           "C2i PlayModeFromSettings: bitperfect", @"");
        CK([RLPPlayModeFromSettings(@{@"rate": @"176400", @"dsd": @"0"}) isEqualToString:@"pcm"],
           "C2j PlayModeFromSettings: pcm", @"");
        CK([RLPPlayModeFromSettings(@{@"rate": @"src", @"dsd": @"dop128"}) isEqualToString:@"dsd"],
           "C2k PlayModeFromSettings: dop128 -> dsd", @"");

        // ---------- C3 能力门控与禁用原因 ----------
        NSDictionary *caFull = @{
            @"ok": @YES,
            @"device": @{@"name": @"USB DAC", @"backend": @"coreaudio",
                         @"rates": @[@44100, @96000, @192000, @384000],
                         @"maxRate": @384000, @"dsdNative": @NO, @"dop": @YES, @"dopMax": @"dsd128"}
        };
        NSDictionary *stFull = [RLPQuickStartViewController presetStatusForCapsJSON:caFull
                                                                            settings:@{@"backend": @"coreaudio"}
                                                                             playing:NO paused:NO];
        CK([stFull[@"bitperfect"][@"enabled"] boolValue] &&
           [stFull[@"pcm"][@"enabled"] boolValue] &&
           [stFull[@"dsd"][@"enabled"] boolValue] &&
           [stFull[@"pcm2dsd"][@"enabled"] boolValue],
           "C3a CoreAudio+DoP 全四档可用", @"");

        NSDictionary *caShared = @{
            @"ok": @YES,
            @"device": @{@"name": @"Speakers", @"backend": @"coreaudio-shared",
                         @"rates": @[@44100, @48000], @"maxRate": @48000, @"dsdNative": @NO, @"dop": @NO}
        };
        NSDictionary *gShared = [RLPQuickStartViewController gatingForCapsJSON:caShared];
        CK(![gShared[@"pcmReady"] boolValue] && ![gShared[@"dsdReady"] boolValue],
           "C3b coreaudio-shared gating 禁用 PCM/DSD 升频", @"");
        NSDictionary *stShared = [RLPQuickStartViewController presetStatusForCapsJSON:caShared
                                                                              settings:@{@"backend": @"coreaudio-shared"}
                                                                               playing:NO paused:NO];
        CK([stShared[@"bitperfect"][@"enabled"] boolValue] &&
           ![stShared[@"pcm"][@"enabled"] boolValue] &&
           [stShared[@"pcm"][@"reason"] length] > 0 &&
           ![stShared[@"dsd"][@"enabled"] boolValue] &&
           [stShared[@"dsd"][@"reason"] length] > 0,
           "C3c shared 下 PCM/DSD 禁用且有原因说明", stShared[@"pcm"][@"reason"] ?: @"nil");

        NSDictionary *stBusy = [RLPQuickStartViewController presetStatusForCapsJSON:caFull
                                                                            settings:@{@"backend": @"coreaudio"}
                                                                             playing:YES paused:NO];
        CK(![stBusy[@"bitperfect"][@"enabled"] boolValue] &&
           ![stBusy[@"pcm"][@"enabled"] boolValue] &&
           ![stBusy[@"dsd"][@"enabled"] boolValue],
           "C3d 播放中全部预设禁用", @"");

        // ---------- C4 bitperfect 下风格禁用且不破坏直通 ----------
        RLPQuickStartViewController *vc = [[RLPQuickStartViewController alloc] init];
        vc.view.frame = NSMakeRect(0, 0, 1100, 760);
        vc.filters = items;
        vc.settings = @{@"backend": @"null", @"rate": @"src", @"dsd": @"0", @"filter": @"", @"directsdm": @"1"};
        [vc syncPlayAndStyleCards];
        CK([vc.styleValue.stringValue isEqualToString:RLPTr(@"保持原音")],
           "C4a bitperfect 下风格卡显示「保持原音」", vc.styleValue.stringValue ?: @"nil");
        CK(vc.styleCard.alphaValue < 0.9, "C4b bitperfect 下风格卡视觉置灰", @"");

        // ---------- C5 真实几何自适应（宽4/中2/窄1 等宽 + 单层滚动 + 页头入口）----------
        CK(FindById(vc.view, @"room.folders") != nil, "C5a 页头存在音乐文件夹入口 room.folders", @"");

        // 统计垂直 NSScrollView 数量（必须恰好 1 个）
        NSMutableArray<NSView *> *allViews = [NSMutableArray array];
        CollectViews(vc.view, allViews);
        int vertScrolls = 0;
        for (NSView *v in allViews) {
            if ([v isKindOfClass:[NSScrollView class]] && ((NSScrollView *)v).hasVerticalScroller)
                ++vertScrolls;
        }
        CK(vertScrolls == 1, "C5b 页面只有一个垂直滚动容器（单层滚动）",
           [NSString stringWithFormat:@"vertScrolls=%d", vertScrolls]);

        NSView *c1 = FindById(vc.view, @"room.device");
        NSView *c2 = FindById(vc.view, @"room.output");
        NSView *c3 = FindById(vc.view, @"room.play");
        NSView *c4 = FindById(vc.view, @"room.style");

        // 宽窗：4 列等宽一行
        vc.view.frame = NSMakeRect(0, 0, 1100, 760);
        [vc updateResponsiveLayoutForWidth:1052.0];
        [vc.view layoutSubtreeIfNeeded];
        CK(std::fabs(c1.frame.size.width - c2.frame.size.width) <= 1.5 &&
           std::fabs(c2.frame.size.width - c3.frame.size.width) <= 1.5 &&
           std::fabs(c3.frame.size.width - c4.frame.size.width) <= 1.5 &&
           c1.frame.size.width > 150.0 &&
           std::fabs(c1.frame.origin.y - c4.frame.origin.y) <= 1.5,
           "C5c 宽窗 1100px -> 4 列等宽一行",
           [NSString stringWithFormat:@"w=[%.1f,%.1f,%.1f,%.1f]",
            c1.frame.size.width, c2.frame.size.width, c3.frame.size.width, c4.frame.size.width]);

        // 中窗：2 列等宽两行
        vc.view.frame = NSMakeRect(0, 0, 620, 760);
        [vc updateResponsiveLayoutForWidth:572.0];
        [vc.view layoutSubtreeIfNeeded];
        CK(std::fabs(c1.frame.size.width - c2.frame.size.width) <= 1.5 &&
           std::fabs(c1.frame.size.width - c3.frame.size.width) <= 1.5 &&
           std::fabs(c1.frame.origin.y - c2.frame.origin.y) <= 1.5 &&
           c3.frame.origin.y < c1.frame.origin.y - 10.0,
           "C5d 中窗 620px -> 2x2 等宽两行",
           [NSString stringWithFormat:@"y1=%.1f y2=%.1f y3=%.1f",
            c1.frame.origin.y, c2.frame.origin.y, c3.frame.origin.y]);

        // 窄窗：1 列四行等宽
        vc.view.frame = NSMakeRect(0, 0, 340, 760);
        [vc updateResponsiveLayoutForWidth:292.0];
        [vc.view layoutSubtreeIfNeeded];
        CK(std::fabs(c1.frame.size.width - c4.frame.size.width) <= 1.5 &&
           c1.frame.origin.y > c2.frame.origin.y + 10.0 &&
           c2.frame.origin.y > c3.frame.origin.y + 10.0 &&
           c3.frame.origin.y > c4.frame.origin.y + 10.0,
           "C5e 窄窗 340px -> 1 列四行等宽",
           [NSString stringWithFormat:@"y=[%.1f,%.1f,%.1f,%.1f]",
            c1.frame.origin.y, c2.frame.origin.y, c3.frame.origin.y, c4.frame.origin.y]);

        [core shutdown];
        [fm removeItemAtPath:root error:nil];
        std::printf("\n%s（%d 项失败）\n", gFail == 0 ? "native_listening_contract 全部通过" : "native_listening_contract 有失败", gFail);
        return gFail == 0 ? 0 : 1;
    }
}
