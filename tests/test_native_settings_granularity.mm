// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_settings_granularity.mm — 设置页「卡片粒度」与 cal 页真控件判据（task-4）
//
// ============================ 这条判据在证明什么 ============================
// 逐行比对 web `src/net/ui_script.h` 的 eqSettingsHtml() / calSettingsHtml()：
//
//   web EQ  页 = **两张** sgroup：「参数均衡 PEQ（20 段 · HIFI）」「耳机 EQ（OPRA 校准预设）」
//   web cal 页 = **三张** sgroup：「房间校正（测量向导）」「EQ 文件（REW / AutoEq 文本）」
//                「房间校正 IR（WAV 脉冲响应）」
//   而原生 1.1.7.38 之前：EQ 页 = 1 张卡（整块均衡器子界面）；cal 页 = 1 张卡。
//
// 更要紧的是 **cal 页的 sp_eq / sp_ir / sp_irgpu 是"假对齐"**：
//   `tools/native_ui/RLPSettingsViewController.mm` 里只有把它们写进 identifier 映射表的
//   字符串（`@"sp_eq": @"sp_eq"`），屏幕上**没有任何对应控件** ——
//   parity_scan 只认源码字面量，于是把它记成 done（missing=0 是假绿）。
//   web 上这三个控件是真控件：sp_eq = EQ 文件路径输入、sp_ir = IR WAV 路径输入、
//   sp_irgpu = GPU 卷积开关，改完会 POST /api/settings 的 eq / ir / irgpu。
//
// 判据：
//   ① EQ 页必须是 2 张卡、标题逐字等于 web，且各自的控件归属正确（PEQ 控件在第 1 张、
//      OPRA 控件在第 2 张）；
//   ② cal 页必须是 3 张卡、标题逐字等于 web；
//   ③ sp_eq / sp_ir / sp_irgpu 必须是**真实控件**（NSTextField / NSSwitch，尺寸 > 0）
//      且在对应卡片体内；
//   ④ 行为：给 sp_eq 填路径并触发 action ⟹ 后端 /api/settings 的 kv.eq 真的变成该值
//      （不是只改 UI 状态）；sp_irgpu 同理（0/1）。
//   ⑤ 单层滚动：EQ / cal 页签内不得再有 NSScrollView（用户 2026-11-13 要求整页只有一根滚动条）。
//
// 纪律：隔离 state/library；backend=null、volume=-120；不播放；不联网（只打本进程后端）。
#import <AppKit/AppKit.h>
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPSettingsViewController.h"
#import "RLPCalibrationView.h"
#import "RLPEqualizerView.h"

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
static BOOL IsCard(NSView *v) {
    return v && [NSStringFromClass(v.class) isEqualToString:@"RLPSettingsGroup"];
}
static NSView *CardFor(NSView *v) {
    for (NSView *p = v.superview; p; p = p.superview) if (IsCard(p)) return p;
    return nil;
}
/// 页签内**嵌套**的 NSScrollView 列表。
/// 注意：页签根视图本身就是「整页滚动容器」（buildPane 返回的 NSScrollView，
/// identifier = tab.<key>），它是这根滚动条的本体、不算嵌套；只统计它内部又套的滚动视图。
/// 只算「用户能看见的第二根滚动条」：显式开着滚动条（hasVerticalScroller / hasHorizontalScroller）。
/// NSTableView 必需的固定高度包装（EQ 的 20 段表：hasVerticalScroller=NO、内容=可视区）不是滚动条，
/// 页签根自己（= 整页滚动容器本体）也不算。
static NSArray<NSString *> *NestedScrollersIn(NSView *pane) {
    NSMutableArray<NSString *> *a = [NSMutableArray array];
    for (NSView *x in Descendants(pane)) {
        if (x == pane) continue;
        if (![x isKindOfClass:[NSScrollView class]]) continue;
        NSScrollView *s = (NSScrollView *)x;
        if (!s.hasVerticalScroller && !s.hasHorizontalScroller) continue;
        [a addObject:s.identifier ?: @"-"];
    }
    return a;
}
static NSArray<NSView *> *CardsIn(NSView *pane) {
    NSMutableArray<NSView *> *a = [NSMutableArray array];
    for (NSView *v in Descendants(pane)) if (IsCard(v)) [a addObject:v];
    return a;
}
static NSString *CardTitle(NSView *card) {
    NSView *head = FindId(card, @"set.group.head");
    if (!head) return @"";
    for (NSView *s in head.subviews)
        if ([s isKindOfClass:[NSTextField class]]) return ((NSTextField *)s).stringValue;
    return @"";
}
static NSView *PaneRoot(NSView *root, NSString *key) {
    return FindId(root, [@"tab." stringByAppendingString:key]);
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        std::printf("=== test_native_settings_granularity（卡片粒度 / cal 真控件 · 不出声）===\n");

        NSString *rootDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"rlp-gran-%d", (int)getpid()]];
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

        RLPSettingsViewController *settings = [[RLPSettingsViewController alloc] init];
        NSView *v = settings.view;
        v.frame = NSMakeRect(0, 0, 1280, 900);
        [v layoutSubtreeIfNeeded];

        // ---- ① EQ 页：两张卡，标题逐字等于 web ----
        [settings selectPane:@"eq"];
        Pump(0.5);
        [v layoutSubtreeIfNeeded];
        NSView *eqPane = PaneRoot(v, @"eq");
        Ck(eqPane != nil, @"EQ 页签有根视图", @"tab.eq 缺失");
        NSArray<NSView *> *eqCards = CardsIn(eqPane);
        Ck(eqCards.count == 2, @"EQ 页 = 两张卡片（web 参数均衡 / 耳机 EQ）",
           [NSString stringWithFormat:@"cards=%lu: %@", (unsigned long)eqCards.count,
            [[eqCards valueForKey:@"description"] componentsJoinedByString:@" "]]);
        NSMutableArray<NSString *> *titles = [NSMutableArray array];
        for (NSView *c in eqCards) [titles addObject:CardTitle(c)];
        Ck(eqCards.count == 2 &&
           [titles[0] hasPrefix:@"参数均衡 PEQ"] && [titles[1] hasPrefix:@"耳机 EQ"],
           @"EQ 两卡标题与顺序逐字对齐 web",
           [titles componentsJoinedByString:@" | "]);

        NSView *peqCard = eqCards.count ? eqCards[0] : nil;
        NSView *opraCard = eqCards.count > 1 ? eqCards[1] : nil;
        for (NSString *ident in @[ @"peqBypass", @"peqPreamp", @"peq.bands", @"eq.curve" ]) {
            NSView *x = FindId(eqPane, ident);
            Ck(x && peqCard && CardFor(x) == peqCard,
               [NSString stringWithFormat:@"【EQ】%@ 在「参数均衡 PEQ」卡体内", ident],
               x ? @"归卡错误" : @"控件缺失");
        }
        for (NSString *ident in @[ @"opra.query", @"opra.search" ]) {
            NSView *x = FindId(eqPane, ident);
            Ck(x && opraCard && CardFor(x) == opraCard,
               [NSString stringWithFormat:@"【EQ】%@ 在「耳机 EQ」卡体内", ident],
               x ? @"归卡错误" : @"控件缺失");
        }

        // ---- ⑤ 单层滚动：EQ / cal 页签内不得再有自己的 NSScrollView ----
        NSArray<NSString *> *eqScrollers = NestedScrollersIn(eqPane);
        Ck(eqScrollers.count == 0, @"【EQ】页签内没有嵌套 NSScrollView（外层页面统一滚动）",
           [eqScrollers componentsJoinedByString:@" | "]);

        // ---- ② cal 页：三张卡 + 真控件 ----
        [settings selectPane:@"cal"];
        Pump(0.6);
        [v layoutSubtreeIfNeeded];
        NSView *calPane = PaneRoot(v, @"cal");
        Ck(calPane != nil, @"声音校准页签有根视图", @"tab.cal 缺失");
        NSArray<NSView *> *calCards = CardsIn(calPane);
        NSMutableArray<NSString *> *calTitles = [NSMutableArray array];
        for (NSView *c in calCards) [calTitles addObject:CardTitle(c)];
        Ck(calCards.count == 3, @"cal 页 = 三张卡片（测量向导 / EQ 文件 / 房间校正 IR）",
           [NSString stringWithFormat:@"cards=%lu: %@", (unsigned long)calCards.count,
            [calTitles componentsJoinedByString:@" | "]]);
        Ck(calCards.count == 3 &&
           [calTitles[0] hasPrefix:@"房间校正"] && [calTitles[1] hasPrefix:@"EQ 文件"] &&
           [calTitles[2] hasPrefix:@"房间校正 IR"],
           @"cal 三卡标题与顺序逐字对齐 web", [calTitles componentsJoinedByString:@" | "]);

        NSView *wizCard = calCards.count == 3 ? calCards[0] : nil;
        NSView *eqFileCard = calCards.count == 3 ? calCards[1] : nil;
        NSView *irCard = calCards.count == 3 ? calCards[2] : nil;

        NSView *spEq = FindId(calPane, @"sp_eq");
        Ck(spEq != nil, @"【cal】sp_eq 是真实控件（web EQ 文件路径输入）——旧码只有标识符映射没有控件",
           @"找不到 sp_eq 控件");
        Ck([spEq isKindOfClass:[NSTextField class]] && spEq.frame.size.width > 20,
           @"【cal】sp_eq 是可用宽度的文本输入框", spEq ? NSStringFromClass(spEq.class) : @"nil");
        Ck(spEq && eqFileCard && CardFor(spEq) == eqFileCard,
           @"【cal】sp_eq 在「EQ 文件」卡体内", spEq ? @"归卡错误" : @"控件缺失");

        NSView *spIr = FindId(calPane, @"sp_ir");
        NSView *spIrGpu = FindId(calPane, @"sp_irgpu");
        Ck(spIr != nil, @"【cal】sp_ir 是真实控件（web IR WAV 路径输入）", @"找不到 sp_ir");
        Ck(spIrGpu != nil, @"【cal】sp_irgpu 是真实控件（web GPU 卷积开关）", @"找不到 sp_irgpu");
        Ck([spIrGpu isKindOfClass:[NSSwitch class]], @"【cal】sp_irgpu 是开关而不是文字",
           spIrGpu ? NSStringFromClass(spIrGpu.class) : @"nil");
        Ck(spIr && irCard && CardFor(spIr) == irCard && spIrGpu && CardFor(spIrGpu) == irCard,
           @"【cal】sp_ir / sp_irgpu 在「房间校正 IR」卡体内", @"归卡错误");

        NSArray<NSString *> *calScrollers = NestedScrollersIn(calPane);
        Ck(calScrollers.count == 0, @"【cal】页签内没有嵌套 NSScrollView（外层页面统一滚动）",
           [calScrollers componentsJoinedByString:@" | "]);

        // ---- ④ 行为：sp_eq 填值并触发 action ⟹ /api/settings 的 eq 真的变 ----
        if ([spEq isKindOfClass:[NSTextField class]]) {
            NSTextField *f = (NSTextField *)spEq;
            f.stringValue = @"/tmp/gran-eq.txt";
            if (f.action && f.target) [f.target performSelector:f.action withObject:f];
            Pump(0.6);
            NSDictionary *j = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil];
            NSDictionary *kv = [j[@"kv"] isKindOfClass:[NSDictionary class]] ? j[@"kv"] : nil;
            Ck([kv[@"eq"] isEqualToString:@"/tmp/gran-eq.txt"],
               @"【cal】改 sp_eq 后 /api/settings 的 eq 真的落盘（行为判据，不是只改 UI）",
               [NSString stringWithFormat:@"kv.eq=%@", kv[@"eq"] ?: @"(nil)"]);
            // 复位，别污染后面的用例
            [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"eq="];
        }
        if ([spIrGpu isKindOfClass:[NSSwitch class]]) {
            NSSwitch *s = (NSSwitch *)spIrGpu;
            s.state = NSControlStateValueOn;
            if (s.action && s.target) [s.target performSelector:s.action withObject:s];
            Pump(0.6);
            NSDictionary *j = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil];
            NSDictionary *kv = [j[@"kv"] isKindOfClass:[NSDictionary class]] ? j[@"kv"] : nil;
            Ck([kv[@"irgpu"] isEqualToString:@"1"],
               @"【cal】sp_irgpu 打开后 /api/settings 的 irgpu = 1",
               [NSString stringWithFormat:@"kv.irgpu=%@", kv[@"irgpu"] ?: @"(nil)"]);
            [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"irgpu=0"];
        }

        std::printf("结果：%d passed, %d failed\n", gPass, gFail);
        return gFail ? 1 : 0;
    }
}
