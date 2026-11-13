// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_writeback_card.mm — 元数据页「标签写回」并入卡片（第12项）
//
// ============================ 这条判据在证明什么 ============================
// 用户 2026-11-13 第12项原话：页面是「联网检索端点」大卡片，其下「标签写回」是
// **孤立的标题条 + 断裂说明 + 两个按钮（页面并列散块）**，视觉散落。
// web 的真实结构（src/net/ui_script.h:10264-10272）：标签写回是「AI 接入（OpenAI 兼容）」
// 卡片体内的 .mh.sub 子段 —— 标题、说明、两个按钮和卡片的其它字段在**同一个卡体**里。
//
// 判据分两层（用户指定）：
//   ① 结构：标题 / 说明 / 「预览写回」/「执行写回」必须是**同一个卡片容器的共同后代**，
//      并且那个容器就是 AI 接入卡（不是页面并列的 stack）；
//   ② 几何：写回块的左内边距、按钮高度、按钮间距与**同页其它卡片实测值**一致（±2pt）。
//
// 红→绿：旧码（空壳卡片 + 页面并列 desc/按钮）结构判据必红；改完必绿。
// 证据：evidence/native-item12-red-20261113.log / native-item12-green-20261113.log
//
// 纪律：隔离 state/library；backend=null、volume=-120；**不播放任何音频**（铁律②）。
#import <AppKit/AppKit.h>
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPSettingsViewController.h"

#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <unistd.h>

static int gFail = 0, gPass = 0;
static void Ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { ++gPass; std::printf("  [PASS] %s\n", what); }
    else { ++gFail; std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); }
}
static void Geo(const char *what, double got, double expected, double tol) {
    const double d = got - expected;
    const BOOL ok = std::fabs(d) <= tol;
    if (ok) { std::printf("  [PASS] %-30s got=%6.2f expected=%6.2f diff=%+6.2f\n", what, got, expected, d); ++gPass; }
    else { std::printf("  [FAIL] %-30s got=%6.2f expected=%6.2f diff=%+6.2f\n", what, got, expected, d); ++gFail; }
}
static void CollectViews(NSView *v, NSMutableArray<NSView *> *out) {
    if (!v) return;
    [out addObject:v];
    for (NSView *s in v.subviews) CollectViews(s, out);
}
static NSArray<NSView *> *Descendants(NSView *v) {
    NSMutableArray<NSView *> *all = [NSMutableArray array];
    CollectViews(v, all);
    return all;
}
static NSView *FindById(NSView *root, NSString *ident) {
    for (NSView *v in Descendants(root)) if ([v.identifier isEqualToString:ident]) return v;
    return nil;
}
static BOOL IsDescendant(NSView *child, NSView *ancestor) {
    for (NSView *v = child; v; v = v.superview) if (v == ancestor) return YES;
    return NO;
}
static void Pump(NSTimeInterval s) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:s];
    while ([until timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}
/// 卡片标题（set.group.head 里的第一个 NSTextField）。
static NSString *CardTitle(NSView *card) {
    NSView *head = FindById(card, @"set.group.head");
    if (!head) return @"";
    for (NSView *s in head.subviews) if ([s isKindOfClass:[NSTextField class]]) return ((NSTextField *)s).stringValue;
    return @"";
}
/// 某视图相对卡片内容区的左内边距（转换到卡片坐标系）。
static double LeftInsetIn(NSView *v, NSView *card) {
    NSRect r = [v convertRect:v.bounds toView:card];
    return NSMinX(r);
}
/// 上下相邻两个视图的竖向间距（自动处理翻转/非翻转坐标系）。
static double VerticalGap(NSView *upper, NSView *lower, NSView *card) {
    NSRect a = [upper convertRect:upper.bounds toView:card];
    NSRect b = [lower convertRect:lower.bounds toView:card];
    if (card.isFlipped) return NSMinY(b) - NSMaxY(a);
    return NSMinY(a) - NSMaxY(b);
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        std::printf("=== test_native_writeback_card（第12项 · 真页面离屏 · 不出声）===\n");

        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"rlp-wb-%d", (int)getpid()]];
        NSString *state = [root stringByAppendingPathComponent:@"state"];
        NSString *lib = [root stringByAppendingPathComponent:@"lib"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:lib withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("RLPLAYER_STATE_DIR", state.fileSystemRepresentation, 1);
        setenv("RLPLAYER_LIBRARY_DIR", lib.fileSystemRepresentation, 1);
        RLPCoreClient *core = [RLPCoreClient shared];
        if (![core startEmbedded]) { std::printf("  [FAIL] 核心启动失败\n"); return 1; }
        [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"backend=null&volume=-120"];

        RLPSettingsViewController *settings = [[RLPSettingsViewController alloc] init];
        NSView *v = settings.view;
        v.frame = NSMakeRect(0, 0, 1280, 900);
        [v layoutSubtreeIfNeeded];
        [settings selectPane:@"meta"];
        [v layoutSubtreeIfNeeded];
        Pump(0.4);
        [v layoutSubtreeIfNeeded];

        // 展开「高级选项」（web sp_metamore）：写回块在 #sp_metaadv 里。
        NSButton *more = (NSButton *)FindById(v, @"sp_metamore");
        Ck(more != nil, "元数据页有「高级选项」按钮", @"sp_metamore 缺失");
        if (more) { [more performClick:nil]; [v layoutSubtreeIfNeeded]; Pump(0.3); [v layoutSubtreeIfNeeded]; }

        // ---- 离屏渲染前后对比图（用户要求附对比图）----
        // RLP_WB_SNAP=<png path> 时把「高级选项」整块离屏渲染成 PNG：
        // 旧码 = 空壳「标签写回」卡片 + 页面并列说明/按钮；新码 = 并入 AI 接入卡体内。
        const char *snapEnv = getenv("RLP_WB_SNAP");
        if (snapEnv && *snapEnv) {
            NSView *adv = FindById(v, @"sp_metaadv");
            if (adv && adv.bounds.size.width > 40 && adv.bounds.size.height > 40) {
                [adv layoutSubtreeIfNeeded];
                NSBitmapImageRep *rep = [adv bitmapImageRepForCachingDisplayInRect:adv.bounds];
                [adv cacheDisplayInRect:adv.bounds toBitmapImageRep:rep];
                NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                const BOOL ok = [png writeToFile:[NSString stringWithUTF8String:snapEnv] atomically:YES];
                Ck(ok, "离屏渲染对比图已写出", [NSString stringWithUTF8String:snapEnv]);
            }
        }

        // ---- 结构判据：标题/说明/两个按钮必须在同一张卡片里 ----
        NSMutableArray<NSView *> *cards = [NSMutableArray array];
        Class groupCls = NSClassFromString(@"RLPSettingsGroup");
        for (NSView *x in Descendants(v)) if (groupCls && [x isKindOfClass:groupCls]) [cards addObject:x];

        NSView *dry = FindById(v, @"sp_wbdry");
        NSView *apply = FindById(v, @"sp_wbapply");
        NSView *desc = FindById(v, @"sp_wbdesc");
        NSView *subTitle = nil;
        {
            // 子标题：卡片内的「标签写回」文本（web .mh.sub）
            NSMutableArray<NSView *> *all = [NSMutableArray array];
            CollectViews(v, all);
            for (NSView *x in all) {
                if ([x isKindOfClass:[NSTextField class]] && [((NSTextField *)x).stringValue isEqualToString:RLPTr(@"标签写回")])
                    subTitle = x;
            }
        }
        Ck(dry && apply && desc, "写回块的按钮与说明都存在（不是改名后消失）",
           [NSString stringWithFormat:@"dry=%d apply=%d desc=%d", !!dry, !!apply, !!desc]);

        NSView *wbCard = nil;
        for (NSView *card in cards) {
            const BOOL hasAll = dry && apply && desc && IsDescendant(dry, card) &&
                                IsDescendant(apply, card) && IsDescendant(desc, card);
            if (hasAll) { wbCard = card; break; }
        }
        Ck(wbCard != nil,
           "【结构】标题/说明/「预览写回」/「执行写回」是同一卡片容器的共同后代（不是页面并列）",
           [NSString stringWithFormat:@"cards=%lu dry.superview=%@ desc.superview=%@",
            (unsigned long)cards.count, dry.superview.className ?: @"nil", desc.superview.className ?: @"nil"]);
        if (!wbCard) { std::printf("结果：%d passed, %d failed\n", gPass, gFail); return 1; }

        // 子标题也必须在同一张表里（web .mh.sub 属于卡体）
        Ck(subTitle && IsDescendant(subTitle, wbCard),
           "【结构】「标签写回」子标题在同一张卡片里", subTitle ? @"不在同一卡片" : @"找不到标题");
        // 承载它的必须是 AI 接入卡（web 的位置）
        NSString *cardTitle = CardTitle(wbCard);
        Ck([cardTitle containsString:@"AI 接入"],
           "【结构】写回块承载在「AI 接入（OpenAI 兼容）」卡体内（与 web 同位置）",
           [NSString stringWithFormat:@"所在卡片标题=%@", cardTitle]);
        // 页面并列不成立：按钮的祖先链上必须出现这张卡，而不是设置页根 stack/adv
        Ck(IsDescendant(dry, wbCard) && IsDescendant(apply, wbCard),
           "【结构】按钮祖先链经过该卡片（旧码是 sp_metaadv 页面并列）", @"");

        // ---- 几何判据：与同页其它卡片实测一致（±2pt）----
        // 同页基准：联网检索端点卡片（保存端点 / 清除检索 Key）与 AI 卡片里的「保存端点」按钮。
        NSView *searchSave = FindById(v, @"search.save");
        NSView *searchClear = FindById(v, @"search.clear");
        NSView *llmSave = FindById(v, @"llm.save");
        NSView *searchProvider = FindById(v, @"search.provider");
        NSView *subBox = subTitle ? subTitle.superview : nil;   // set.subhead（含底部 8pt + 1px 线）
        Ck(searchSave != nil, "同页基准卡（联网检索端点）的按钮存在", @"search.save 缺失");
        Ck(searchProvider != nil, "同页基准卡（联网检索端点）的字段存在", @"search.provider 缺失");

        // 左内边距：卡片内容区 = 16（web .sgbody padding:14px 16px）
        // NSTextField 的 frame 含 alignmentRectInsets（左右各 2pt），量"控件 frame 左边距"
        // 与纯 NSView 卡体差 2pt；用户给的容差就是 ±2，这里按 16±2 判定视觉对齐。
        Geo("wb.desc.leftInset", LeftInsetIn(desc, wbCard), 16, 2.0);
        Geo("wb.subhead.leftInset", LeftInsetIn(subBox ?: subTitle, wbCard), 16, 2);
        Geo("wb.dryBtn.leftInset", LeftInsetIn(dry, wbCard), 16, 2);
        if (searchProvider) {
            NSView *searchCard = nil;
            for (NSView *card in cards) if (IsDescendant(searchProvider, card)) { searchCard = card; break; }
            if (searchCard) Geo("otherCard.field.leftInset", LeftInsetIn(searchProvider, searchCard),
                               LeftInsetIn(desc, wbCard), 2.0);
        }
        // 按钮规格：与同页其它按钮同高
        if (searchSave) Geo("wb.btn.height", dry.frame.size.height, searchSave.frame.size.height, 2);
        // 按钮间距：与同页另一张卡片（联网检索端点）的按钮行实测间距一致
        {
            NSRect dryR = [dry convertRect:dry.bounds toView:wbCard];
            NSRect applyR = [apply convertRect:apply.bounds toView:wbCard];
            Geo("wb.btnRow.spacing", NSMinX(applyR) - NSMaxX(dryR), 8, 2);
            if (searchSave && searchClear) {
                NSRect a = [searchSave convertRect:searchSave.bounds toView:nil];
                NSRect b = [searchClear convertRect:searchClear.bounds toView:nil];
                Geo("wb.btnRow.spacing.vsOtherCard", NSMinX(applyR) - NSMaxX(dryR),
                    NSMinX(b) - NSMaxX(a), 2);
            }
        }
        // 块间竖向间距：子标题块底 → 说明顶、说明底 → 按钮行顶，都必须是网格 gap 14（±2）
        if (subBox) {
            Geo("wb.gap.subheadToDesc", VerticalGap(subBox, desc, wbCard), 14, 2);
            Geo("wb.gap.descToButtons", VerticalGap(desc, dry, wbCard), 14, 2);
        }
        // 右边界不越界（写回块不再用写死的 560/520pt 宽度横向溢出）
        {
            NSRect card = wbCard.bounds;
            NSRect applyRect = [apply convertRect:apply.bounds toView:wbCard];
            Geo("wb.rightInset", NSMaxX(card) - NSMaxX(applyRect) >= 16 ? 0 : (NSMaxX(card) - NSMaxX(applyRect)),
                0, 0.5);
        }

        std::printf("结果：%d passed, %d failed\n", gPass, gFail);
        return gFail == 0 ? 0 : 1;
    }
}
