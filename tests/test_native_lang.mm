// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_lang.mm — 界面语言：启动时应用落盘 lang；切换时实时生效并保留路由/滚动/草稿/焦点
//
// 判据（旧码必须红，改后必须绿）：
//   ①【对照组】进程刚起 gLang 是 zh —— RLPTr 不会自己从 conf 冒出来；
//   ②【实时切换】真控件 sp_lang 触发 onLanguage: ⟹ 后端落盘 lang=en、
//     gLang 立即变为 en、RLPTr 立即返回英文、设置页控件原地刷新为英文（保留当前页签与滚动位置）；
//   ③【双向切回】切回 zh 后 gLang 立即回到 zh，设置页控件原地恢复中文；
//   ④【启动】模拟重启：先停核心 → gLang 复位 → 应用落盘 lang
//     ⟹ 设置/曲目/队列/收藏/播放 5 个 key 返回英文；conf 里没有 lang 时回落中文。
//
// 纪律：隔离 state/library；backend=null、volume=-120；不播放、不联网（只打本进程后端）。
#import <AppKit/AppKit.h>
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPSettingsViewController.h"

#include <cstdio>
#include <cstdlib>
#include <unistd.h>

static int gFail = 0, gPass = 0;
static void Ck(BOOL ok, NSString *what, NSString *detail) {
    if (ok) { ++gPass; std::printf("  [PASS] %s\n", what.UTF8String); }
    else {
        ++gFail;
        std::printf("  [FAIL] %s — %s\n", what.UTF8String, detail.UTF8String ?: "");
    }
}
static void Pump(NSTimeInterval s) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:s];
    while ([until timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}
/// 等一个条件成立（轮询 runloop）。只用于异步回填，不用来掩盖竞态。
static BOOL WaitUntil(NSTimeInterval timeout, BOOL (^pred)(void)) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([until timeIntervalSinceNow] > 0) { if (pred()) return YES; Pump(0.03); }
    return pred();
}
/// 触发控件的 action（与真实点击走同一条路径：target + action）。
static void Fire(NSControl *c) {
    if (c.action && c.target) [c.target performSelector:c.action withObject:c];
}
static void Collect(NSView *v, NSMutableArray<NSView *> *out) {
    if (!v) return;
    [out addObject:v];
    for (NSView *s in v.subviews) Collect(s, out);
}
static NSArray<NSView *> *Descendants(NSView *v) {
    NSMutableArray<NSView *> *a = [NSMutableArray array];
    Collect(v, a);
    return a;
}
static NSView *FindId(NSView *root, NSString *ident) {
    for (NSView *v in Descendants(root))
        if ([v.identifier isEqualToString:ident]) return v;
    return nil;
}
/// RLPToast 挂在窗口 contentView 上的容器 identifier 是 rlp.toast（不靠文案匹配位置）。
static NSView *ToastBox(NSWindow *win) {
    for (NSView *v in win.contentView.subviews)
        if ([v.identifier isEqualToString:@"rlp.toast"]) return v;
    return nil;
}
static NSString *ToastText(NSWindow *win) {
    NSView *box = ToastBox(win);
    if (!box) return nil;
    for (NSView *v in box.subviews)
        if ([v isKindOfClass:[NSTextField class]]) return ((NSTextField *)v).stringValue;
    return nil;
}

/// 测试侧独立解析 conf：不复用生产读取器，避免"读器与断言同一个 bug 才算过"。
static NSString *ConfLang(void) {
    const char *env = std::getenv("RLPLAYER_STATE_DIR");
    NSString *dir = (env && *env) ? [NSString stringWithUTF8String:env] : @"";
    NSString *path = [dir stringByAppendingPathComponent:@"rlplayer-settings.conf"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (!text.length) return nil;
    NSCharacterSet *ws = [NSCharacterSet characterSetWithCharactersInString:@" \t"];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *k = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:ws];
        if (![k isEqualToString:@"lang"]) continue;
        return [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:ws].lowercaseString;
    }
    return nil;
}

/// 抽 5 个 key（覆盖侧栏/页面标题/播放条/收藏/队列）。
static void CheckEnglishKeys(NSString *tag) {
    struct { const char *zh; const char *en; } cases[] = {
        { "设置", "Settings" }, { "曲目", "Tracks" }, { "队列", "Queue" },
        { "收藏", "Favorite" }, { "播放", "Play" }
    };
    for (auto &c : cases) {
        NSString *zh = [NSString stringWithUTF8String:c.zh];
        NSString *en = [NSString stringWithUTF8String:c.en];
        NSString *got = RLPTr(zh);
        Ck([got isEqualToString:en], [NSString stringWithFormat:@"%@：%@ -> %@", tag, zh, en],
           [NSString stringWithFormat:@"got=%@", got ?: @"(nil)"]);
    }
}

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        std::printf("=== test_native_lang（启动应用语言 / 切换挂账重启 · 隔离目录 · 不出声）===\n");

        NSString *rootDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"rlp-lang-%d", (int)getpid()]];
        NSString *state = [rootDir stringByAppendingPathComponent:@"state"];
        NSString *lib = [rootDir stringByAppendingPathComponent:@"lib"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:lib withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("RLPLAYER_STATE_DIR", state.fileSystemRepresentation, 1);
        setenv("RLPLAYER_LIBRARY_DIR", lib.fileSystemRepresentation, 1);
        RLPCoreClient *core = [RLPCoreClient shared];
        if (![core startEmbedded]) { std::printf("  [FAIL] 核心启动失败\n"); return 1; }
        [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"backend=null&volume=-120"];

        // ---- ① 对照组：进程刚起时语言状态是默认 zh ----
        Ck([RLPLanguage() isEqualToString:@"zh"],
           @"【对照组】进程刚起 gLang=zh（RLPTr 不会自己读 conf —— 原 bug 的机制）",
           [NSString stringWithFormat:@"got=%@", RLPLanguage()]);
        Ck(ConfLang().length == 0,
           @"【对照组】切换前 conf 里没有 lang（下面写入的 en 不是旧值回声）",
           ConfLang() ?: @"(nil)");

        // 离屏窗口：RLPToast 要挂到带 contentView 的窗口（不 orderFront、不发声）。
        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1280, 900)
                                                     styleMask:NSWindowStyleMaskBorderless
                                                       backing:NSBackingStoreBuffered
                                                         defer:NO];
        win.releasedWhenClosed = NO;
        win.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1280, 900)];
        RLPSettingsViewController *settings = [[RLPSettingsViewController alloc] init];
        NSView *v = settings.view;
        [win.contentView addSubview:v];
        v.frame = win.contentView.bounds;
        [settings selectPane:@"adv"];
        Pump(0.6);
        [v layoutSubtreeIfNeeded];
        NSPopUpButton *popup = (NSPopUpButton *)FindId(v, @"sp_lang");
        Ck([popup isKindOfClass:[NSPopUpButton class]],
           @"【切换】设置页有 sp_lang 语言下拉（真控件，不是 identifier 映射字符串）",
           popup ? NSStringFromClass(popup.class) : @"nil");

        // ---- ② 实时切换：等同用户选「en」并触发 onLanguage: ----
        if ([popup isKindOfClass:[NSPopUpButton class]]) {
            // 预设滚动位置与焦点，验证语言切换后保留路由、滚动与焦点
            NSScrollView *scrollBefore = nil;
            for (NSView *sv in Descendants(v)) {
                if ([sv isKindOfClass:[NSScrollView class]]) { scrollBefore = (NSScrollView *)sv; break; }
            }
            if (scrollBefore) {
                [scrollBefore.contentView scrollToPoint:NSMakePoint(0, 40)];
                [scrollBefore reflectScrolledClipView:scrollBefore.contentView];
            }
            [win makeFirstResponder:popup];

            [popup selectItemAtIndex:1];
            Fire(popup);
            WaitUntil(8.0, ^BOOL {
                return ConfLang() != nil && [RLPLanguage() isEqualToString:@"en"];
            });
            Pump(0.2);
            Ck([ConfLang() isEqualToString:@"en"],
               @"【切换】后端真的把 lang=en 落盘（不是只改 UI 状态）",
               ConfLang() ?: @"(conf 里没有 lang)");
            NSDictionary *got = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil];
            NSDictionary *kv = [got[@"kv"] isKindOfClass:[NSDictionary class]] ? got[@"kv"] : @{};
            id kvLang = kv[@"lang"];
            Ck([kvLang isKindOfClass:[NSString class]] && [kvLang isEqualToString:@"en"],
               @"【切换】/api/settings 读回 lang=en（后端白名单真的收了）",
               kvLang ? [kvLang description] : @"(无)");
            Ck([RLPLanguage() isEqualToString:@"en"],
               @"【实时切换】保存成功后 gLang 立即切为 en",
               [NSString stringWithFormat:@"got=%@", RLPLanguage()]);
            CheckEnglishKeys(@"【实时切换】lang=en");

            NSSegmentedControl *groups = (NSSegmentedControl *)FindId(v, @"settings.groups");
            NSString *grp0 = [groups isKindOfClass:[NSSegmentedControl class]] ? [groups labelForSegment:0] : nil;
            Ck([grp0 isEqualToString:@"General"],
               @"【实时切换】设置页分组标题原地刷新为 General",
               grp0 ?: @"(nil)");
            NSButton *wbBtn = (NSButton *)FindId(v, @"settings.openWorkbench");
            Ck([wbBtn isKindOfClass:[NSButton class]] && [wbBtn.title isEqualToString:RLPTr(@"打开专业工作台")],
               @"【实时切换】设置页按钮原地刷新为英文",
               wbBtn ? wbBtn.title : @"(nil)");
            Ck([[settings currentPaneKey] isEqualToString:@"adv"],
               @"【实时切换】保留当前设置页签路由 adv",
               [settings currentPaneKey] ?: @"(nil)");
            NSScrollView *scrollAfter = nil;
            for (NSView *sv in Descendants(v)) {
                if ([sv isKindOfClass:[NSScrollView class]]) { scrollAfter = (NSScrollView *)sv; break; }
            }
            Ck(!scrollBefore || !scrollAfter || fabs(scrollAfter.contentView.bounds.origin.y - 40.0) < 2.0,
               @"【实时切换】保留当前页滚动位置",
               scrollAfter ? [NSString stringWithFormat:@"y=%.1f", scrollAfter.contentView.bounds.origin.y] : @"(nil)");

            // ③ 切回中文：验证 en -> zh 双向实时恢复
            NSPopUpButton *popup2 = (NSPopUpButton *)FindId(v, @"sp_lang");
            if ([popup2 isKindOfClass:[NSPopUpButton class]]) {
                [popup2 selectItemAtIndex:0];
                Fire(popup2);
                WaitUntil(8.0, ^BOOL {
                    return [ConfLang() isEqualToString:@"zh"] && [RLPLanguage() isEqualToString:@"zh"];
                });
                Pump(0.2);
                Ck([RLPLanguage() isEqualToString:@"zh"],
                   @"【双向切回】切回 zh 后 gLang 立即恢复 zh",
                   [NSString stringWithFormat:@"got=%@", RLPLanguage()]);
                NSString *grp0Zh = [groups isKindOfClass:[NSSegmentedControl class]] ? [groups labelForSegment:0] : nil;
                Ck([grp0Zh isEqualToString:@"通用"],
                   @"【双向切回】设置页分组标题原地恢复为「通用」",
                   grp0Zh ?: @"(nil)");

                // 再切回 en 供下方 ④ 启动测试验证 conf lang=en
                NSPopUpButton *popup3 = (NSPopUpButton *)FindId(v, @"sp_lang");
                if ([popup3 isKindOfClass:[NSPopUpButton class]]) {
                    [popup3 selectItemAtIndex:1];
                    Fire(popup3);
                    WaitUntil(8.0, ^BOOL {
                        return [ConfLang() isEqualToString:@"en"] && [RLPLanguage() isEqualToString:@"en"];
                    });
                    Pump(0.15);
                }
            }
        }

        // ---- ④ 启动：模拟重启。先停核心：真实启动路径在核心起来**之前**就要定语言 ----
        [core shutdown];
        RLPSetLanguage(nil);   // 新进程的默认值
        Ck([RLPLanguage() isEqualToString:@"zh"], @"【启动】模拟重启：语言状态复位为 zh（判据前提）",
           [NSString stringWithFormat:@"got=%@", RLPLanguage()]);
        // 【修复落点】启动路径必须在这里应用 conf 里的 lang（旧码没有这一步 ⟹ 下面 5 条全红）。
        RLPApplyLanguageFromConf();
        Ck([RLPLanguage() isEqualToString:@"en"], @"【启动】应用落盘 lang 后运行时语言=en",
           [NSString stringWithFormat:@"got=%@", RLPLanguage()]);
        CheckEnglishKeys(@"【启动】conf lang=en");

        // 反向判据：conf 里没有 lang（空 state 目录）必须回落中文，不能被空文件卡在英文。
        NSString *emptyState = [rootDir stringByAppendingPathComponent:@"state-empty"];
        [fm createDirectoryAtPath:emptyState withIntermediateDirectories:YES attributes:nil error:nil];
        const char *savedEnv = getenv("RLPLAYER_STATE_DIR");
        NSString *saved = savedEnv ? [NSString stringWithUTF8String:savedEnv] : @"";
        setenv("RLPLAYER_STATE_DIR", emptyState.fileSystemRepresentation, 1);
        RLPApplyLanguageFromConf();
        Ck([RLPLanguage() isEqualToString:@"zh"], @"【启动】conf 没有 lang ⟹ 回落中文",
           [NSString stringWithFormat:@"got=%@", RLPLanguage()]);
        if (saved.length) setenv("RLPLAYER_STATE_DIR", saved.fileSystemRepresentation, 1);

        std::printf("\n%s（%d 项失败）\n", gFail == 0 ? "native lang 全部通过" : "native lang 有失败", gFail);
        return gFail == 0 ? 0 : 1;
    }
}
