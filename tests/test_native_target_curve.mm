// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_target_curve.mm — 耳机目标曲线按 web 方式接入（第8项）
//
// ============================ 这条判据在证明什么 ============================
// 用户原话：「耳机目标曲线仍未能像 web 版那样接入（功能缺失，不是判据问题）」。
// 逐层判定四个可能断点，本文件全部用**可执行判据**固定，不靠读代码自证：
//   ① 桥层：/api/opra/index 的 items 是 **[id,vendor,name] 数组三元组**（rtaweb.cpp:11285），
//      旧原生按 NSDictionary 过滤 ⟹ 搜索结果恒为空。判据：给数组三元组，型号下拉必须出 1 项。
//   ② 绘制层：选中的目标曲线必须**画到 EQ 图上**且能与 PEQ 区分。
//      判据：像素采样 —— 选曲线后曲线视图与该曲线前逐像素比较，变化像素/虚线覆盖率；
//      再切另一条曲线，图形必须跟着变。
//   ③ 请求层：与 web 逐字段一致（web 代码位置见各断言注释）：
//      GET `/api/opra/index`（**不带 q**，web loadOpraIndex 全量拉一次本地过滤）、
//      GET `/api/opra/presets?productId=<encodeURIComponent>`、
//      POST `/api/opra/apply` body `productId=…&presetId=…`、
//      POST `/api/settings` 带 `eq=`/`opraproduct=`/`oprapreset=`（web applyOpraPreset→saveSettings）。
//   ④ 加载时机：选中/应用预设后必须展示目标曲线说明（web showTargetCurveInfo：名称/是什么/适合谁/
//      前级增益/段数）。判据：选中后 info 文案出现对应曲线的中文名与「前级增益」。
//
// 红→绿：旧码（数组不解析、预设读不存在的 name、无 targetCurve 图层、无 info）必红；
// 改完必绿。证据：evidence/native-item8-red-20261113.log / native-item8-green-20261113.log
//
// 纪律：桩客户端，不发任何网络请求、不启动核心、不碰音频设备（铁律②）。
#import <AppKit/AppKit.h>
#import "RLPEqualizerView.h"
#import "RLPCoreClient.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

#include <cstdio>
#include <cstring>
#include <cmath>
#include <vector>

static int g_fail = 0, g_pass = 0;
static void Ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++g_fail; }
}
static void Eq(const char *what, NSString *got, NSString *expect) {
    Ck([got isEqualToString:expect], what,
       [NSString stringWithFormat:@"got=%@ expect=%@", got ?: @"(nil)", expect ?: @"(nil)"]);
}

#pragma mark - 桩客户端（只记录请求，不发任何东西）

static NSMutableArray<NSString *> *g_gets;     // GET 路径
static NSMutableArray<NSString *> *g_posts;    // POST 路径
static NSMutableArray<NSString *> *g_bodies;   // POST body

static NSDictionary *PEQState(void) {
    NSMutableArray *bands = [NSMutableArray array];
    for (int i = 0; i < 20; ++i) [bands addObject:@{ @"freq": @(25.0 * pow(1.35, i)), @"gain": @0, @"q": @1.0 }];
    NSMutableArray *pts = [NSMutableArray array];
    for (int i = 0; i <= 200; ++i) {
        const double f = 20.0 * pow(1000.0, i / 200.0);
        [pts addObject:@[ @(f), @(3.0 * sin(i / 12.0)) ]];
    }
    return @{ @"ok": @YES, @"bands": bands, @"points": pts, @"preamp": @0 };
}
static NSDictionary *IndexPayload(void) {
    return @{ @"ok": @YES, @"count": @2, @"items": @[
        @[ @"sennheiser::hd_600", @"Sennheiser", @"HD 600" ],
        @[ @"apple::airpods_pro_2", @"Apple", @"AirPods Pro 2" ] ] };
}
static NSDictionary *PresetsPayload(void) {
    return @{ @"ok": @YES, @"items": @[
        @{ @"id": @"sennheiser:hd_600::oratory1990_harman_target", @"author": @"oratory1990",
           @"details": @"Harman Target", @"link": @"", @"gainDb": @(-9.3), @"bandsCount": @10 },
        @{ @"id": @"sennheiser:hd_600::autoeq_harman_iem", @"author": @"AutoEQ",
           @"details": @"Harman In-Ear", @"link": @"", @"gainDb": @(-6.0), @"bandsCount": @12 } ] };
}

#pragma mark clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RLPCoreClient
+ (instancetype)shared { static RLPCoreClient *c; if (!c) c = [self new]; return c; }
- (BOOL)started { return YES; }
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    if (!done) return;
    [g_gets addObject:path ?: @""];
    if ([path hasPrefix:@"/api/peq"]) { done(PEQState()); return; }
    if ([path isEqualToString:@"/api/opra/index"]) { done(IndexPayload()); return; }
    if ([path hasPrefix:@"/api/opra/presets"]) { done(PresetsPayload()); return; }
    done(@{ @"ok": @NO });
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done { if (done) done(nil); }
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    [g_posts addObject:path ?: @""];
    [g_bodies addObject:body ?: @""];
    if (done) {
        if ([path isEqualToString:@"/api/opra/apply"])
            done(@{ @"ok": @YES, @"path": @"eq/opra-hd600.txt" });
        else done(@{ @"ok": @YES });
    }
}
@end
#pragma mark clang diagnostic pop

#pragma mark - 视图查找与像素采样

static void Collect(NSView *v, NSMutableArray<NSView *> *out) {
    if (!v) return;
    [out addObject:v];
    for (NSView *s in v.subviews) Collect(s, out);
}
static NSView *FindById(NSView *root, NSString *ident) {
    NSMutableArray *all = [NSMutableArray array]; Collect(root, all);
    for (NSView *v in all) if ([v.identifier isEqualToString:ident]) return v;
    return nil;
}
static NSView *FindByClass(NSView *root, NSString *cls) {
    NSMutableArray *all = [NSMutableArray array]; Collect(root, all);
    for (NSView *v in all) if ([NSStringFromClass(v.class) isEqualToString:cls]) return v;
    return nil;
}
static NSButton *FindButton(NSView *root, NSString *title) {
    NSMutableArray *all = [NSMutableArray array]; Collect(root, all);
    for (NSView *v in all) if ([v isKindOfClass:[NSButton class]] &&
        [((NSButton *)v).title isEqualToString:title]) return (NSButton *)v;
    return nil;
}
static NSTextField *FindFieldWithPlaceholder(NSView *root, NSString *frag) {
    NSMutableArray *all = [NSMutableArray array]; Collect(root, all);
    for (NSView *v in all) if ([v isKindOfClass:[NSTextField class]] &&
        [((NSTextField *)v).placeholderString containsString:frag]) return (NSTextField *)v;
    return nil;
}
static NSPopUpButton *FindPopupWithAction(NSView *root, NSString *sel) {
    NSMutableArray *all = [NSMutableArray array]; Collect(root, all);
    for (NSView *v in all) if ([v isKindOfClass:[NSPopUpButton class]] &&
        [NSStringFromSelector(((NSPopUpButton *)v).action) isEqualToString:sel]) return (NSPopUpButton *)v;
    return nil;
}

static NSBitmapImageRep *Snap(NSView *v) {
    if (!v || v.bounds.size.width < 10 || v.bounds.size.height < 10) return nil;
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
    [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
    return rep;
}
static double XOf(NSView *v) { return v.bounds.size.width; }

/// 两张渲染图在 plot 区域内的变化像素数 + 变化列覆盖率（虚线判据）。
/// plot 区域与 RLPEQCurveView 的 pad 一致：左 34 / 右 8 / 下 18 / 上 8（点为坐标，非翻转）。
static NSInteger DiffPixels(NSBitmapImageRep *a, NSBitmapImageRep *b, NSView *v,
                            double *outColCoverage, double *outCentroidY) {
    if (!a || !b) return -1;
    const CGFloat W = v.bounds.size.width, H = v.bounds.size.height;
    const double scale = a.pixelsWide / MAX(1.0, W);
    if (fabs(scale - b.pixelsWide / MAX(1.0, W)) > 0.01) return -1;
    const NSInteger x0 = (NSInteger)lround(34 * scale);
    const NSInteger x1 = (NSInteger)lround((W - 8) * scale);
    const NSInteger y0 = (NSInteger)lround(18 * scale);
    const NSInteger y1 = (NSInteger)lround((H - 8) * scale);
    NSInteger count = 0, cols = 0, colsHit = 0;
    double sumY = 0;
    for (NSInteger x = x0; x < x1; x += (NSInteger)MAX(1, lround(1 * scale))) {
        BOOL colChanged = NO; ++cols;
        for (NSInteger y = y0; y < y1; y += (NSInteger)MAX(1, lround(1 * scale))) {
            NSColor *ca = [a colorAtX:x y:y], *cb = [b colorAtX:x y:y];
            if (!ca || !cb) continue;
            ca = [ca colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            cb = [cb colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            if (!ca || !cb) continue;
            const double d = fabs(ca.redComponent - cb.redComponent) +
                             fabs(ca.greenComponent - cb.greenComponent) +
                             fabs(ca.blueComponent - cb.blueComponent);
            if (d > 0.05) { ++count; colChanged = YES; sumY += y; }
        }
        if (colChanged) ++colsHit;
    }
    if (outColCoverage) *outColCoverage = cols ? (double)colsHit / (double)cols : 0.0;
    if (outCentroidY) *outCentroidY = count ? (sumY / count) / scale : 0.0;
    return count;
}
static void Pump(void) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:0.05];
    while ([until timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        std::printf("=== test_native_target_curve（第8项 · 桩客户端 · 不出声）===\n");
        g_gets = [NSMutableArray array];
        g_posts = [NSMutableArray array];
        g_bodies = [NSMutableArray array];

        RLPEqualizerView *eq = [[RLPEqualizerView alloc] initWithFrame:NSMakeRect(0, 0, 640, 1200)];
        NSView *v = eq;
        [v layoutSubtreeIfNeeded];
        [eq reload];
        [v layoutSubtreeIfNeeded];

        NSView *curve = FindById(v, @"eq.curve");
        if (!curve) curve = FindByClass(v, @"RLPEQCurveView");   // 旧码没有 identifier，按类兜底
        Ck(curve != nil, "找得到 EQ 曲线视图（像素判据的取样对象）", @"RLPEQCurveView 缺失");
        if (!curve) { std::printf("结果：%d passed, %d failed\n", g_pass, g_fail); return 1; }

        NSTextField *query = FindFieldWithPlaceholder(v, @"HD650");
        NSButton *searchBtn = FindButton(v, RLPTr(@"搜索"));
        NSButton *applyBtn = FindButton(v, RLPTr(@"应用"));
        Ck(query && searchBtn && applyBtn, "OPRA 搜索框 / 搜索键 / 应用键都在",
           [NSString stringWithFormat:@"query=%d search=%d apply=%d", !!query, !!searchBtn, !!applyBtn]);
        if (!query || !searchBtn) { std::printf("结果：%d passed, %d failed\n", g_pass, g_fail); return 1; }

        NSBitmapImageRep *base = Snap(curve);   // 未选任何目标曲线时的渲染

        // ---- ① 桥层：数组三元组 + web 的「全量索引一次 + 本地过滤」 ----
        query.stringValue = @"hd 600";
        [searchBtn performClick:nil];
        Pump();
        [v layoutSubtreeIfNeeded];

        BOOL sawIndexNoQuery = NO, sawIndexWithQuery = NO;
        for (NSString *p in g_gets) {
            if ([p isEqualToString:@"/api/opra/index"]) sawIndexNoQuery = YES;
            if ([p hasPrefix:@"/api/opra/index?"]) sawIndexWithQuery = YES;
        }
        Ck(sawIndexNoQuery && !sawIndexWithQuery,
           "【请求】索引请求 = /api/opra/index（不带 q，web loadOpraIndex 同口径）",
           [NSString stringWithFormat:@"noQ=%d withQ=%d gets=%@", sawIndexNoQuery, sawIndexWithQuery, g_gets]);
        // 空输入严禁发请求（web 261023-03 #6）
        {
            NSInteger before = (NSInteger)g_gets.count;
            query.stringValue = @"   ";
            [searchBtn performClick:nil];
            Ck((NSInteger)g_gets.count == before, "【请求】空关键词不发起任何请求", @"");
        }

        NSPopUpButton *product = FindPopupWithAction(v, @"onOpraProduct:");
        NSPopUpButton *preset = nil;
        if (product) {
            NSMutableArray *all = [NSMutableArray array]; Collect(v, all);
            for (NSView *x in all)
                if ([x isKindOfClass:[NSPopUpButton class]] && x != product && x.superview == product.superview)
                    preset = (NSPopUpButton *)x;
        }
        Ck(product != nil && preset != nil, "找得到型号 / 预设两个下拉框", @"");
        if (!product) { std::printf("结果：%d passed, %d failed\n", g_pass, g_fail); return 1; }
        Ck(product.numberOfItems == 1,
           "【①桥层】数组三元组被解析成型号项（旧码恒 0 项 —— 用户说『没接入』的直接原因）",
           [NSString stringWithFormat:@"items=%ld", (long)product.numberOfItems]);
        if (product.numberOfItems == 1)
            Eq("【①桥层】型号显示名 = vendor · name", [product itemTitleAtIndex:0], @"Sennheiser · HD 600");

        NSString *presetsPath = @"";
        for (NSString *p in g_gets) if ([p hasPrefix:@"/api/opra/presets"]) { presetsPath = p; break; }
        Eq("【③请求】预设请求 = presets?productId=<encodeURIComponent>",
           presetsPath, @"/api/opra/presets?productId=sennheiser%3A%3Ahd_600");

        // ---- ③ 字段：预设没有 name，显示名 = author · details ----
        Ck(preset && preset.numberOfItems == 2,
           "【③字段】预设列表被填满（后端没有 name 字段，旧码读 name ⟹ 恒空）",
           [NSString stringWithFormat:@"items=%ld", (long)(preset ? preset.numberOfItems : -1)]);
        if (preset && preset.numberOfItems == 2) {
            Eq("【③字段】预设显示名 1 = author · details", [preset itemTitleAtIndex:0],
               @"oratory1990 · Harman Target");
            Eq("【③字段】预设显示名 2 = author · details", [preset itemTitleAtIndex:1],
               @"AutoEQ · Harman In-Ear");
        }

        // ---- ④ 加载时机：选中即展示目标曲线说明（web showTargetCurveInfo）----
        NSTextField *info = (NSTextField *)FindById(v, @"opra.info");
        Ck(info != nil, "【④时机】选中预设后有目标曲线说明行（web showTargetCurveInfo 同构）", @"opra.info 缺失");
        if (info) {
            Ck([info.stringValue containsString:@"哈曼头戴目标曲线"],
               "【④时机】说明里出现当前曲线的中文名（Harman Over-Ear）", info.stringValue);
            Ck([info.stringValue containsString:RLPTr(@"前级增益：")],
               "【④时机】说明里出现「前级增益」（web 同一行信息）", info.stringValue);
        }

        // ---- ② 绘制层：目标曲线图层（像素采样，可与 PEQ 区分）----
        NSBitmapImageRep *p0 = Snap(curve);
        double cov0 = 0, cen0 = 0;
        NSInteger d0 = DiffPixels(base, p0, curve, &cov0, &cen0);
        Ck(d0 > 40, "【②绘制】选中目标曲线后 EQ 图上出现新图层（像素变化）",
           [NSString stringWithFormat:@"changedPixels=%ld", (long)d0]);
        Ck(d0 > 0 && cov0 > 0.20 && cov0 < 0.85,
           "【②绘制】新图层是**虚线**（列覆盖率 <85%）⟹ 与实线 PEQ 可区分",
           [NSString stringWithFormat:@"colCoverage=%.2f", cov0]);

        // 切到另一条曲线：图形必须随之变化
        if (preset && preset.numberOfItems >= 2) {
            [preset selectItemAtIndex:1];
            [preset sendAction:preset.action to:preset.target];
            Pump();
            NSBitmapImageRep *p1 = Snap(curve);
            double cov1 = 0, cen1 = 0;
            NSInteger d1 = DiffPixels(p0, p1, curve, &cov1, &cen1);
            Ck(d1 > 20, "【②绘制】切换曲线后图形随之变化（两条目标曲线不同）",
               [NSString stringWithFormat:@"changedPixels=%ld", (long)d1]);
            Ck(fabs(cen1 - cen0) > 1.0, "【②绘制】新曲线重心真的移动（不是同一形状重画）",
               [NSString stringWithFormat:@"cen0=%.1f cen1=%.1f", cen0, cen1]);
            if (info) Ck([info.stringValue containsString:@"哈曼入耳目标曲线"],
                         "【④时机】切曲线后说明同步改成 In-Ear", info.stringValue);
        }

        // ---- ③ 请求：apply body 与 web 逐字段一致 ----
        if (applyBtn) {
            [preset selectItemAtIndex:1];
            [preset sendAction:preset.action to:preset.target];
            [applyBtn performClick:nil];
            Pump();
        }
        NSString *applyBody = @"", *settingsBody = @"";
        for (NSUInteger i = 0; i < g_posts.count; ++i) {
            if ([g_posts[i] isEqualToString:@"/api/opra/apply"]) applyBody = g_bodies[i];
            if ([g_posts[i] isEqualToString:@"/api/settings"]) settingsBody = g_bodies[i];
        }
        Eq("【③请求】apply body = productId&presetId（encodeURIComponent 同 web）",
           applyBody, @"productId=sennheiser%3A%3Ahd_600&presetId=sennheiser%3Ahd_600%3A%3Aautoeq_harman_iem");
        Ck([settingsBody rangeOfString:@"eq=eq%2Fopra-hd600.txt"].location != NSNotFound,
           "【③请求】apply 成功后写回 settings 的 eq=（web saveSettings(true)，旧码没写⟹不热重载）",
           settingsBody);
        Ck([settingsBody rangeOfString:@"opraproduct=sennheiser%3A%3Ahd_600"].location != NSNotFound &&
           [settingsBody rangeOfString:@"oprapreset=sennheiser%3Ahd_600%3A%3Aautoeq_harman_iem"].location != NSNotFound,
           "【③请求】settings 同时写回 opraproduct / oprapreset（web 同一次 saveSettings）", settingsBody);

        std::printf("结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
