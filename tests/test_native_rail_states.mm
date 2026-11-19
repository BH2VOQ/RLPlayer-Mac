// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_rail_states.mm — AI 整理栏的 nprailempty / npSummHint 状态 = web
//
// ============================ 这条判据在证明什么 ============================
// web 真源：
//   ui_script.h:13055-13060：没有可整理的实体（npDataTargets 为空）时，卡片不渲染，
//                             `nprailempty` 整块说明出现：
//     「播放后在右侧显示歌曲、专辑、艺术家（古典作品还会多一栏演绎版本）的精简整理资料。」
//   ui_script.h:13331-13346 npRailHint：只有三种状态出现——
//     insufficient → npInsufficientText（资料不足）；
//     error → 「歌曲资料未能取到 · 点击重试」（点击 = 强制重取这首歌的 summary）；
//     loading（抽屉未开）→ 「正在后台整理歌曲资料…」。
//   ui_page.h:763/783-786：.nprailempty 10.5/1.6 mut2；.nprailhint 10.5/1.5，err 用 warn 色。
// 旧原生（1.1.7.30）：栏里恒显示 3 张卡（无 meta 时三卡空白），没有 nprailempty；
//   也没有 npSummHint 状态行。所以本文件对旧码必须红。
//
// 铁律②：桩客户端；不启动核心、不碰音频设备、不创建可见窗口。
#import <AppKit/AppKit.h>
#import "RLPNowPlayingViewController.h"
#import "RLPCoreClient.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

#include <cstdio>

static int g_pass = 0, g_fail = 0;
static void Ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++g_fail; }
}
static void EqStr(NSString *got, NSString *want, const char *what) {
    Ck([got isEqualToString:want], what,
       [NSString stringWithFormat:@"got=%@ want=%@", got ?: @"(nil)", want ?: @"(nil)"]);
}

static NSMutableArray<NSString *> *g_gets;
static NSMutableArray<NSString *> *g_posts;

#pragma mark clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RLPCoreClient
+ (instancetype)shared { static RLPCoreClient *c; if (!c) c = [self new]; return c; }
- (BOOL)started { return NO; }
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    [g_gets addObject:path ?: @""];
    if (done) done(@{ @"ok": @NO });
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done { (void)path; if (done) done(nil); }
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    [g_posts addObject:path ?: @""];
    if (done) done(@{ @"ok": @NO });
}
@end
#pragma mark clang diagnostic pop

static NSView *FindById(NSView *root, NSString *ident) {
    if (!root) return nil;
    if ([root.identifier isEqualToString:ident]) return root;
    for (NSView *s in root.subviews) {
        NSView *r = FindById(s, ident);
        if (r) return r;
    }
    return nil;
}
static BOOL ActuallyVisible(NSView *v) {
    for (NSView *x = v; x; x = x.superview) {
        if (x.hidden || x.alphaValue < 0.05) return NO;
        if (x.frame.size.width < 1 || x.frame.size.height < 1) return NO;
    }
    return YES;
}
static NSArray<NSView *> *RailCards(NSView *rail) {
    // 卡片在 `.npchipwrap` 内（web 结构），递归找；可见性判断会沿 superview 链检查 wrap.hidden。
    NSMutableArray *out = [NSMutableArray array];
    __block void (^collect)(NSView *);
    collect = ^(NSView *root){
        for (NSView *v in root.subviews) {
            NSString *cid=v.identifier;
            BOOL isChild=[cid isEqualToString:@"npChip.dot"]||[cid isEqualToString:@"npChip.name"]||
                         [cid isEqualToString:@"npChip.st"]||[cid isEqualToString:@"npChip.p1"]||
                         [cid isEqualToString:@"npChip.p2"];
            if ([cid hasPrefix:@"npChip."] && !isChild) [out addObject:v];
            collect(v);
        }
    };
    collect(rail);
    return out;
}

@interface RLPNowPlayingViewController (RailStatesTest)
- (void)renderRailMetadata;
@end

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        g_gets = [NSMutableArray array];
        g_posts = [NSMutableArray array];
        [RLPTheme setThemeName:@"light"];
        [RLPTheme setUiStyle:@"apple"];
        std::printf("=== test_native_rail_states（nprailempty / npSummHint · 离屏 · 不出声）===\n");

        RLPNowPlayingViewController *vc = [RLPNowPlayingViewController new];
        NSView *v = vc.view;
        v.frame = NSMakeRect(0, 0, 1400, 900);
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"RLPNPRailHidden"];
        [v layoutSubtreeIfNeeded];
        NSView *rail = FindById(v, @"npRail");
        Ck(rail != nil, "找得到 AI 整理栏 #npRail", @"npRail 缺失");
        if (!rail) { std::printf("结果：%d passed, %d failed\n", g_pass, g_fail); return 1; }

        // ---- 1. 无任何可整理实体：3 卡不显示、nprailempty 出现 ----
        [vc setValue:@{} forKey:@"trackMetadata"];
        [vc setValue:@{} forKey:@"railStates"];
        [vc renderRailMetadata];
        [vc performSelector:NSSelectorFromString(@"layoutWebPlayback")];
        [v layoutSubtreeIfNeeded];
        NSTextField *empty = (NSTextField *)FindById(rail, @"npRailEmpty");
        Ck(empty != nil, "存在 nprailempty 标签（npRailEmpty）", @"缺 npRailEmpty");
        Ck(empty && ActuallyVisible(empty), "无实体时空态说明可见",
           empty ? [NSString stringWithFormat:@"hidden=%d", (int)empty.hidden] : @"缺标签");
        if (empty) EqStr(empty.stringValue,
                         RLPTr(@"播放后在右侧显示歌曲、专辑、艺术家（古典作品还会多一栏演绎版本）的精简整理资料。"),
                         "空态文案逐字 = web nprailempty");
        BOOL anyCardVisible = NO;
        for (NSView *c in RailCards(rail)) if (ActuallyVisible(c)) anyCardVisible = YES;
        Ck(!anyCardVisible, "无实体时三张卡不显示（不是三张空白卡）", @"仍有卡片可见");

        // ---- 2. 有实体：卡片回来、空态收起 ----
        [vc setValue:@{ @"title": @"T", @"album": @"A", @"artist": @"Aimer" } forKey:@"trackMetadata"];
        [vc renderRailMetadata];
        [vc performSelector:NSSelectorFromString(@"layoutWebPlayback")];
        [v layoutSubtreeIfNeeded];
        Ck(empty && !ActuallyVisible(empty), "有实体时 nprailempty 收起", @"空态仍可见");
        BOOL cardsBack = NO;
        for (NSView *c in RailCards(rail)) if (ActuallyVisible(c)) cardsBack = YES;
        Ck(cardsBack, "有实体时卡片重新可见", @"卡片未显示");

        // ---- 3. 状态行三态：loading / insufficient / error(+重试) / ok 隐藏 ----
        NSButton *hint = (NSButton *)FindById(rail, @"npSummHint");
        Ck(hint != nil, "存在 npSummHint 状态行", @"缺 npSummHint");
        if (!hint) { std::printf("结果：%d passed, %d failed\n", g_pass, g_fail); return 1; }

        [vc setValue:[@{ @"track": @{ @"state": @"loading" } } mutableCopy] forKey:@"railStates"];
        [vc renderRailMetadata];
        Ck(ActuallyVisible(hint), "loading 时状态行可见", @"loading 未显示");
        EqStr(hint.attributedTitle.string, RLPTr(@"正在后台整理歌曲资料…"),
              "loading 文案 = web「正在后台整理歌曲资料…」");

        [vc setValue:[@{ @"track": @{ @"state": @"insufficient", @"data": @{} } } mutableCopy] forKey:@"railStates"];
        [vc renderRailMetadata];
        Ck(ActuallyVisible(hint), "insufficient 时状态行可见", @"insufficient 未显示");
        Ck([hint.attributedTitle.string containsString:RLPTr(@"资料不足")],
           "insufficient 文案含「资料不足」", hint.attributedTitle.string);

        [vc setValue:[@{ @"track": @{ @"state": @"error", @"error": @"x" } } mutableCopy] forKey:@"railStates"];
        [vc renderRailMetadata];
        Ck(ActuallyVisible(hint), "error 时状态行可见", @"error 未显示");
        EqStr(hint.attributedTitle.string, RLPTr(@"歌曲资料未能取到 · 点击重试"),
              "error 文案 = web「歌曲资料未能取到 · 点击重试」");

        [vc setValue:[@{ @"track": @{ @"state": @"ok", @"data": @{} } } mutableCopy] forKey:@"railStates"];
        [vc renderRailMetadata];
        Ck(!ActuallyVisible(hint), "ok 时状态行收起（不打扰）", @"ok 仍显示");

        // ---- 4. error 点击 = 强制重取 track summary ----
        [vc setValue:[@{ @"track": @{ @"state": @"error", @"error": @"x" } } mutableCopy] forKey:@"railStates"];
        [vc setValue:@{ @"track": @{ @"kind": @"track", @"name": @"T", @"artist": @"Aimer",
                                     @"album": @"A", @"file": @"/x.flac", @"genre": @"" } }
              forKey:@"railTargets"];
        [vc setValue:@"/x.flac" forKey:@"currentPath"];
        [vc renderRailMetadata];
        [g_gets removeAllObjects];
        @try { [NSApp sendAction:hint.action to:hint.target from:hint]; }
        @catch (NSException *e) { std::printf("  (sendAction caught: %s)\n", e.reason.UTF8String ?: ""); }
        Ck([g_gets count] > 0, "点 error 状态行真的发起 summary 请求（web npSummRetry）",
           [g_gets componentsJoinedByString:@" | "]);
        BOOL sawTrack = NO;
        for (NSString *p in g_gets) if ([p hasPrefix:@"/api/entity/summary?kind=track"]) sawTrack = YES;
        Ck(sawTrack, "重试请求 = /api/entity/summary?kind=track", [g_gets componentsJoinedByString:@" | "]);

        std::printf("结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
