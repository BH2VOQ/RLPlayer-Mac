// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_works_view.mm — 古典作品页判据（2026-11-12 补齐 web works 视图）
//
// web 有 setView('works')（古典作品 · 演绎版本，Discogs），原生此前完全没有。
// 判据只验 UI 契约与输入校验，**不连外网**（Discogs 检索由后端负责，
// 这里不去真打网络：离线环境下必须也能跑绿）。
#import <AppKit/AppKit.h>
#import "RLPWorksViewController.h"
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
static NSView *FindById(NSView *root, NSString *ident) {
    NSMutableArray<NSView *> *all = [NSMutableArray array];
    CollectViews(root, all);
    for (NSView *v in all) if ([v.identifier isEqualToString:ident]) return v;
    return nil;
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        std::printf("=== test_works_view（古典作品页 UI 契约，不连外网）===\n");

        RLPWorksViewController *vc = [[RLPWorksViewController alloc] init];
        vc.view.frame = NSMakeRect(0, 0, 1100, 760);
        [vc.view layoutSubtreeIfNeeded];
        CK(vc.view != nil, "W1a 作品页可离线构建", @"");
        CK(vc.pageTitle.length > 0, "W1b 有页标题", vc.pageTitle ?: @"nil");

        // 搜索控件
        NSTextField *title = (NSTextField *)FindById(vc.view, @"works.title");
        NSTextField *composer = (NSTextField *)FindById(vc.view, @"works.composer");
        CK([title isKindOfClass:[NSTextField class]], "W2a 有作品名输入框", @"");
        CK([composer isKindOfClass:[NSTextField class]], "W2b 有作曲家输入框", @"");
        CK(FindById(vc.view, @"works.search") != nil, "W2c 有查询按钮", @"");
        CK(FindById(vc.view, @"works.refresh") != nil, "W2d 有刷新（强制重拉）按钮", @"");
        CK(FindById(vc.view, @"works.result") != nil, "W2e 有结果容器", @"");

        // 五个示例芯片（web chip-work）
        NSInteger chips = 0;
        for (NSInteger i = 0; i < 5; ++i)
            if (FindById(vc.view, [NSString stringWithFormat:@"works.chip.%ld", (long)i])) ++chips;
        CK(chips == 5, "W3a 五个示例作品芯片", [NSString stringWithFormat:@"n=%ld", (long)chips]);
        // 点芯片必须把作品名/作曲家填进输入框（web 同语义）
        NSButton *chip0 = (NSButton *)FindById(vc.view, @"works.chip.0");
        if (chip0) {
            [chip0 performClick:nil];
            CK([title.stringValue isEqualToString:@"Boléro"], "W3b 点芯片填入作品名",
               title.stringValue ?: @"nil");
            CK([composer.stringValue isEqualToString:@"Maurice Ravel"], "W3c 点芯片填入作曲家",
               composer.stringValue ?: @"nil");
        }

        // 返回正在播放按钮：默认隐藏，loadWork(fromNowPlaying:YES) 后显示
        NSView *back = FindById(vc.view, @"works.backnp");
        CK(back != nil && back.isHidden, "W4a 返回按钮默认隐藏（非从单曲页进入）", @"");
        [vc loadWork:@"Boléro" composer:@"Maurice Ravel" fromNowPlaying:YES];
        CK(back != nil && !back.isHidden, "W4b 从单曲页进入时显示返回按钮", @"");
        CK([title.stringValue isEqualToString:@"Boléro"], "W4c loadWork 填入作品名", @"");

        // 空作品名必须被拦：结果容器里不许出现「正在检索」（证明没发请求）
        title.stringValue = @"   ";
        NSButton *search = (NSButton *)FindById(vc.view, @"works.search");
        if (search) { [search performClick:nil]; }
        NSMutableArray<NSView *> *afterEmpty = [NSMutableArray array];
        CollectViews(vc.view, afterEmpty);
        BOOL startedSearch = NO;
        for (NSView *v in afterEmpty) {
            if (![v isKindOfClass:[NSTextField class]]) continue;
            if ([((NSTextField *)v).stringValue containsString:RLPTr(@"正在从 Discogs 检索版本…")])
                startedSearch = YES;
        }
        CK(!startedSearch, "W5 空作品名被校验拦住（没有发起检索）", @"竟然发起了检索");

        // 切主题不丢已检索数据的能力：applyTheme 只重刷颜色，不重建结果
        [vc applyTheme];
        CK(FindById(vc.view, @"works.result") != nil, "W6 切主题后结果容器仍在", @"");

        std::printf("\n%s（%d 项失败）\n", gFail == 0 ? "works_view 全部通过" : "works_view 有失败", gFail);
        return gFail == 0 ? 0 : 1;
    }
}