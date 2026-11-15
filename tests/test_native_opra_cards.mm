// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_opra_cards.mm — OPRA 耳机目标曲线：型号卡片 + 预设卡片墙（对齐 web）
//
// ============================ 这个测试在证明什么 ============================
// 用户 2026-11-14 明确：「EQ/OPRA 改都没改」——原生仍是型号下拉 + 预设下拉，
// web（src/net/ui_script.h:11936-12140）是：
//   搜索 → 型号卡片（vendor · name，点击选中）→ 预设卡片墙（每条含目标曲线小图、
//   作者/详情、段数、前级增益、「应用到 EQ」与当前态）。
//
// 判据（全部走生产入口；桩核心只回数据，不启动播放核心、不出声）：
//   O1 搜索结果出**型号卡片**（2 张，文案 = 「vendor · name」，identifier 正确）
//   O2 点击型号卡片 → 该型号的预设**卡片墙**（2 张；文案 = author · details；段数徽标）
//   O3 每条预设卡有真实绘制的**目标曲线小图**（位图上能看到曲线像素，不是空白）
//   O4 当前态：settings 的 opraproduct/oprapreset 命中 →「已应用当前预设」，其余「应用到 EQ」
//   O5 点「应用到 EQ」→ 真发 `/api/opra/apply`（productId/presetId）→ 写回 settings
//      （eq/opraproduct/oprapreset）→ 卡片当前态跟着变
# import <AppKit/AppKit.h>

/**
 * 测试接缝：生产里 `sp_opra_copychip` 是 `RLPChipHoverButton`（该类型定义在 RLPEqualizerView.mm 内），
 * 判据只用到悬停开关这一个方法，这里按 NSButton 分类声明，避免把实现类型搬进测试头。
 */
@interface NSButton (RLPChipHoverTestSeam)
- (void)setChipHovered:(BOOL)hovered;
@end
#import "RLPEqualizerView.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPTheme.h"
#import "RLPTargetCurve.h"
#import "RLPSupport.h"

#include <cstdio>
#include <cstdlib>

#pragma mark - 桩核心（记录 POST；/api/opra/* 与 settings 用夹具）

static NSString *g_appliedProduct = @"p1";
static NSString *g_appliedPreset = @"e1";
static NSMutableArray<NSDictionary *> *g_posts = nil;

static NSArray *OpraIndexItems(void) {
    return @[ @[ @"p1", @"Sennheiser", @"HD 650" ],
              @[ @"p2", @"AKG", @"K712 Pro" ] ];
}
static NSArray *OpraPresetItems(void) {
    return @[ @{ @"id": @"e1", @"author": @"oratory1990", @"details": @"Harman target",
                 @"gainDb": @(-5.2), @"bandsCount": @10 },
              @{ @"id": @"e2", @"author": @"crinacle", @"details": @"Diffuse field",
                 @"gainDb": @(-4.1), @"bandsCount": @8 } ];
}
static id ResponseForPath(NSString *path) {
    if ([path hasPrefix:@"/api/opra/index"]) return @{ @"ok": @YES, @"items": OpraIndexItems() };
    if ([path hasPrefix:@"/api/opra/presets"]) {
        return @{ @"ok": @YES, @"items": OpraPresetItems(), @"fromCache": @NO };
    }
    if ([path hasPrefix:@"/api/settings"]) {
        return @{ @"ok": @YES, @"kv": @{ @"autoanl": @"0", @"eq": @"", @"ir": @"",
            @"opraproduct": g_appliedProduct, @"oprapreset": g_appliedPreset } };
    }
    if ([path hasPrefix:@"/api/peq"]) {
        return @{ @"ok": @YES, @"bypass": @NO, @"preamp": @0,
                  @"bands": @[ @{ @"f": @100, @"g": @0, @"q": @1, @"type": @"peak" } ],
                  @"points": @[ @[ @20, @0 ], @[ @1000, @0 ], @[ @20000, @0 ] ], @"fs": @44100 };
    }
    if ([path hasPrefix:@"/api/preset"]) return @{ @"ok": @YES, @"items": @[] };
    return @{ @"ok": @YES };
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RLPCoreClient
+ (instancetype)shared { static RLPCoreClient *c; if (!c) c = [self new]; return c; }
- (BOOL)started { return YES; }
- (BOOL)startEmbedded { return YES; }
- (void)shutdown {}
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    id resp = ResponseForPath(path);
    dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(resp); });
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done { (void)path; if (done) done(nil); }
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    if (!g_posts) g_posts = [NSMutableArray array];
    [g_posts addObject:@{ @"path": path ?: @"", @"body": body ?: @"" }];
    if ([path isEqualToString:@"/api/opra/apply"]) {
        // 夹具：productId=…&presetId=…（值不含需要转义的字符）
        NSArray *parts = [(body ?: @"") componentsSeparatedByString:@"&"];
        for (NSString *p in parts) {
            if ([p hasPrefix:@"productId="]) g_appliedProduct = [p substringFromIndex:10];
            if ([p hasPrefix:@"presetId="]) g_appliedPreset = [p substringFromIndex:9];
        }
        if (done) done(@{ @"ok": @YES, @"path": @"/tmp/opra-test-eq.txt" });
        return;
    }
    if (done) done(@{ @"ok": @YES });
}
@end
#pragma clang diagnostic pop

#pragma mark - 工具

static int g_fail = 0, g_pass = 0;
static void ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++g_fail; }
}
static void Pump(NSTimeInterval seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
}
static BOOL WaitUntil(NSTimeInterval timeout, BOOL (^pred)(void)) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([until timeIntervalSinceNow] > 0) { if (pred()) return YES; Pump(0.03); }
    return pred();
}
static NSArray *Arr(RLPEqualizerView *v, NSString *key) {
    @try {
        id x = [v valueForKey:key];
        return [x isKindOfClass:[NSArray class]] ? x : nil;
    } @catch (__unused NSException *e) { return nil; }
}
static id Obj(RLPEqualizerView *v, NSString *key) {
    @try { return [v valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}
static NSView *FindByIdent(NSView *root, NSString *ident) {
    if ([root.identifier isEqualToString:ident]) return root;
    for (NSView *s in root.subviews) { NSView *r = FindByIdent(s, ident); if (r) return r; }
    return nil;
}
static NSView *FindByName(NSView *root, NSString *cls) {
    if ([NSStringFromClass(root.class) isEqualToString:cls]) return root;
    for (NSView *s in root.subviews) {
        NSView *hit = FindByName(s, cls);
        if (hit) return hit;
    }
    return nil;
}
/// 位图上除背景色外的像素数（证明小图真的画了曲线，而不是一块空底色）。
static NSInteger NonBackgroundPixels(NSView *v) {
    [v layoutSubtreeIfNeeded];
    NSRect r = v.bounds;
    if (r.size.width < 2 || r.size.height < 2) return 0;
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:r];
    if (!rep) return 0;
    [v cacheDisplayInRect:r toBitmapImageRep:rep];
    NSColorSpace *srgb = [NSColorSpace sRGBColorSpace];
    NSColor *bg = [[RLPTheme current].bg2 colorUsingColorSpace:srgb] ?: [RLPTheme current].bg2;
    NSInteger n = 0;
    for (NSInteger y = 0; y < rep.pixelsHigh; ++y) {
        for (NSInteger x = 0; x < rep.pixelsWide; ++x) {
            NSColor *c = [rep colorAtX:x y:y];
            if (!c) continue;
            c = [c colorUsingColorSpace:srgb] ?: c;
            if (fabs(c.redComponent - bg.redComponent) > 0.02 ||
                fabs(c.greenComponent - bg.greenComponent) > 0.02 ||
                fabs(c.blueComponent - bg.blueComponent) > 0.02) {
                ++n;
                if (n > 40) return n;
            }
        }
    }
    return n;
}

#pragma mark - 生产私有入口（测试经 category 调用，不改生产头文件）

@interface RLPEqualizerView (OpraCardsTest)
- (void)onOpraSearch:(id)sender;
@end

int main() {
    @autoreleasepool {
        std::printf("== OPRA 型号卡片 + 预设卡片墙（桩核心，不启动播放）==\n");
        [NSApplication sharedApplication];
        g_posts = [NSMutableArray array];

        RLPEqualizerView *v = [[RLPEqualizerView alloc] initWithFrame:NSMakeRect(0, 0, 980, 760)];
        // 离屏窗口：不显示，但给视图一个真实响应链/绘制上下文（曲线小图判据要真画）。
        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 980, 760)
                                                    styleMask:NSWindowStyleMaskBorderless
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
        win.contentView = v;
        [win.contentView layoutSubtreeIfNeeded];
        [v reload];
        WaitUntil(2.0, ^BOOL {
            id x = Obj(v, @"appliedProductId");
            return [x isKindOfClass:[NSString class]] && [(NSString *)x isEqualToString:@"p1"];
        });
        ck([Obj(v, @"appliedProductId") isEqual:@"p1"] &&
           [Obj(v, @"appliedPresetId") isEqual:@"e1"],
           "O0 settings 的当前态已读入（opraproduct/oprapreset）",
           [NSString stringWithFormat:@"%@/%@", Obj(v, @"appliedProductId"), Obj(v, @"appliedPresetId")]);

        NSTextField *query = Obj(v, @"opraQuery");
        ck(query != nil, "搜索框存在", @"");
        query.stringValue = @"HD";
        [v onOpraSearch:nil];
        WaitUntil(2.0, ^BOOL { return Arr(v, @"opraModelCardViews").count >= 1; });

        NSArray *models = Arr(v, @"opraModelCardViews");
        // 夹具里 "HD" 只命中 Sennheiser HD 650（AKG K712 Pro 不含 HD）—— 判据是"搜索结果真的变成卡片"。
        ck(models.count == 1, "O1 搜索结果 = 1 张型号卡片", [NSString stringWithFormat:@"%lu", (unsigned long)models.count]);
        if (models.count == 1) {
            ck([[models[0] valueForKey:@"productId"] isEqual:@"p1"] &&
               [[models[0] valueForKey:@"vendor"] isEqual:@"Sennheiser"] &&
               [[models[0] valueForKey:@"name"] isEqual:@"HD 650"],
               "O1 型号卡文案字段 = vendor·name（第一条）",
               [NSString stringWithFormat:@"%@/%@", [models[0] valueForKey:@"vendor"], [models[0] valueForKey:@"name"]]);
            ck([[models[0] valueForKey:@"identifier"] isEqual:@"opra.model.card"],
               "O1 卡片 identifier 统一（判据/无障碍可定位）", @"");
        }

        // 点击第一张型号卡 → 预设卡片墙（走生产 click 入口）
        if (models.count) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [(id)models[0] performSelector:@selector(click)];
#pragma clang diagnostic pop
        }
        WaitUntil(2.0, ^BOOL { return Arr(v, @"opraPresetCardViews").count >= 2; });
        NSArray *presets = Arr(v, @"opraPresetCardViews");
        ck(presets.count == 2, "O2 预设卡片墙 = 2 张卡", [NSString stringWithFormat:@"%lu", (unsigned long)presets.count]);
        if (presets.count == 2) {
            NSString *t1 = [presets[1] valueForKey:@"titleText"];
            ck([t1 containsString:@"crinacle"] && [t1 containsString:@"Diffuse field"],
               "O2 预设卡文案 = author · details（不是 name 字段）", t1 ?: @"");
            NSButton *apply2 = [presets[1] valueForKey:@"applyBtn"];
            ck([apply2.title isEqual:RLPTr(@"应用到 EQ")], "O2 非当前态卡片按钮 = 应用到 EQ", apply2.title ?: @"");
            NSButton *apply1 = [presets[0] valueForKey:@"applyBtn"];
            ck([apply1.title isEqual:RLPTr(@"已应用当前预设")],
               "O4 当前预设（settings e1）在卡片上显示「已应用当前预设」", apply1.title ?: @"");
            NSTextField *badge = nil;
            for (NSView *sub in [presets[0] subviews]) {
                if ([sub isKindOfClass:[NSTextField class]] &&
                    [[sub valueForKey:@"identifier"] isEqual:@"opra.preset.badge"]) badge = (NSTextField *)sub;
            }
            ck([badge.stringValue containsString:@"10"], "O2 段数徽标存在", badge.stringValue ?: @"");
            NSView *thumb0 = [presets[0] valueForKey:@"thumb"];
            ck(thumb0 != nil, "O3 预设卡有目标曲线小图", @"");
            if (thumb0) {
                ck(NonBackgroundPixels(thumb0) > 20, "O3 小图真的画了曲线（非背景像素 > 20）",
                   [NSString stringWithFormat:@"%ld px", (long)NonBackgroundPixels(thumb0)]);
            }
        }

        // 应用第二张预设 → /api/opra/apply + settings 写回 → 当前态翻转
        [g_posts removeAllObjects];
        if (presets.count == 2) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [(id)presets[1] performSelector:@selector(applyCard)];
#pragma clang diagnostic pop
        }
        WaitUntil(2.0, ^BOOL {
            for (NSDictionary *p in g_posts) {
                if ([p[@"path"] isEqual:@"/api/settings"]) return YES;
            }
            return NO;
        });
        NSDictionary *applyPost = nil;
        NSDictionary *settingsPost = nil;
        for (NSDictionary *p in g_posts) {
            if ([p[@"path"] isEqual:@"/api/opra/apply"]) applyPost = p;
            if ([p[@"path"] isEqual:@"/api/settings"]) settingsPost = p;
        }
        ck(applyPost != nil && [applyPost[@"body"] containsString:@"productId=p1"] &&
           [applyPost[@"body"] containsString:@"presetId=e2"],
           "O5 应用按钮真发 /api/opra/apply（productId/presetId）", applyPost[@"body"] ?: @"无请求");
        ck(settingsPost != nil && [settingsPost[@"body"] containsString:@"eq="] &&
           [settingsPost[@"body"] containsString:@"oprapreset=e2"],
           "O5 成功后写回 settings（eq/opraproduct/oprapreset）", settingsPost[@"body"] ?: @"无请求");
        ck([Obj(v, @"appliedPresetId") isEqual:@"e2"], "O5 当前态切到 e2（卡片状态跟着变）",
           Obj(v, @"appliedPresetId") ?: @"nil");

        NSArray *after = Arr(v, @"opraPresetCardViews");
        if (after.count == 2) {
            NSButton *a0 = [after[0] valueForKey:@"applyBtn"];
            NSButton *a1 = [after[1] valueForKey:@"applyBtn"];
            ck([a0.title isEqual:RLPTr(@"应用到 EQ")] && [a1.title isEqual:RLPTr(@"已应用当前预设")],
               "O5 重渲染后「已应用当前预设」落在 e2 卡片",
               [NSString stringWithFormat:@"%@ / %@", a0.title, a1.title]);
        }

        // 可选：整页离屏渲染（before/after 证据用；不写进仓库、只在显式 env 下产生）。
        const char *shotPath = std::getenv("RLP_OPRA_SHOT");
        if (shotPath && *shotPath) {
            NSScrollView *sc = nil;
            @try { id x = [v valueForKey:@"scroll"]; if ([x isKindOfClass:[NSScrollView class]]) sc = x; }
            @catch (__unused NSException *e) { sc = nil; }
            NSView *doc = sc.documentView ?: v;
            [doc layoutSubtreeIfNeeded];
            NSRect r = doc.bounds;
            if (r.size.width > 0 && r.size.height > 0) {
                NSBitmapImageRep *rep = [doc bitmapImageRepForCachingDisplayInRect:r];
                if (rep) {
                    [doc cacheDisplayInRect:r toBitmapImageRep:rep];
                    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                    BOOL ok = png && [png writeToFile:[NSString stringWithUTF8String:shotPath] atomically:YES];
                    std::printf("shot -> %s (%d, %dx%d)\n", shotPath, (int)ok,
                                (int)rep.pixelsWide, (int)rep.pixelsHigh);
                }
            }
        }

        // ---- sp_opra_copychip：web 有 1 个可点 .chip 复制 OPRA 官网链接 ----
        // 旧原生只有 RLPSettingsViewController 的 identifier 字典字符串，parity_scan 因此假绿。
        {
            NSView *chip = FindByIdent(v, @"sp_opra_copychip");
            ck(chip != nil, "C1 sp_opra_copychip 是视图树里的真实控件（不是只有 id 字符串）", @"");
            ck([chip isKindOfClass:[NSButton class]], "C2 sp_opra_copychip 是可点按钮（web .chip）", @"");
            NSButton *btn = (NSButton *)chip;
            if (btn) {
                ck(btn.action != NULL && btn.target != nil, "C3 sp_opra_copychip 有真实 target/action", @"");
                // C3b–C3d：web `.chip:hover{background:var(--hov);color:var(--txt);border-color:var(--acc)}`。
                // 只补悬停态（形状沿用系统圆角 bezel）；钉住「进入变色 / 退出复原」。
                ck([btn respondsToSelector:NSSelectorFromString(@"setChipHovered:")],
                   "C3b 芯片按钮支持悬停态（web .chip:hover 的原生入口）", @"");
                [btn setChipHovered:YES];
                NSColor *hw = [[RLPTheme current].hov colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
                NSColor *hg = [btn.bezelColor colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
                ck(hw && hg && fabs(hg.redComponent - hw.redComponent) < 0.02 &&
                   fabs(hg.greenComponent - hw.greenComponent) < 0.02,
                   "C3c 悬停时 bezel 取主题 hov（web background:var(--hov)）",
                   [NSString stringWithFormat:@"bezel=%@ hov=%@", btn.bezelColor, [RLPTheme current].hov]);
                ck(btn.attributedTitle.length > 0 &&
                   [btn.attributedTitle attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL] != nil,
                   "C3d 悬停时文字显式取主题 txt 色（web color:var(--txt)）", @"");
                [btn setChipHovered:NO];
                ck(btn.bezelColor == nil,
                   "C3e 退出悬停复原成系统默认 bezel（不留下永久着色）",
                   [NSString stringWithFormat:@"bezel=%@", btn.bezelColor]);
                ck([btn.title containsString:@"opra.roon.app"], "C4 sp_opra_copychip 显示官网链接", btn.title ?: @"(nil)");
                NSPasteboard *pb = [NSPasteboard generalPasteboard];
                [pb clearContents];
                [pb setString:@"SENTINEL-NOT-COPIED" forType:NSPasteboardTypeString];
                [btn performClick:nil];
                NSString *copied = [pb stringForType:NSPasteboardTypeString];
                ck([copied isEqualToString:@"https://opra.roon.app/"],
                   "C5 点击真把 https://opra.roon.app/ 写进剪贴板", copied ?: @"(nil)");
            }
        }

        std::printf("\n%s（%d passed, %d failed）\n",
                    g_fail == 0 ? "OPRA 卡片墙 全部通过" : "OPRA 卡片墙 有失败", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
