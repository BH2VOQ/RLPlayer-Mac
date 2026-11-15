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
//   ⑥ 设置键值（S1a · 2026-11-16）：这 4 个控件的**动作都在**，但发出的键/值后端白名单不认 ——
//      /api/settings 是「白名单 + 合并写」，不在白名单的键**静默丢弃**（ok:true 但 conf 里没有该键）。
//      判据 = 触发真控件 action ⟹ 读回 /api/settings 的 kv，按**后端键**断言：
//        ⑥a sp_2s   → twostage=1|0（旧码发 2s，被丢弃）
//        ⑥b sp_loud → loudness=1|0（旧码发 loud，被丢弃）
//        ⑥c sp_rate → max / follow / src / 96000（web ui_page.h:1547 的 option value；
//                     旧码把中文文案当值发）
//        ⑥d sp_bits → -1 / 0 / 16 / 32（web ui_script.h:9855-9858；旧码把中文文案当值发）
//   ⑦ 回填：kv 的值必须能把下拉切回对应项（值 ≠ 文案 ⟹ applyKV 不能再按文案匹配）。
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
/// 等一个条件成立（轮询 runloop）。只用于异步数据回填，不用来掩盖竞态。
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
        // 2026-11-15 用户明确「底下这个 eq 表不要了」⟹ 20 行参数表已移除。
        // 它的职责拆成：频率/增益 → 推子板(eq.fader)；Q/类型/开关 → 单段检查器(eq.inspector)。
        // 判据跟着**新控件集**走（不是放宽）：PEQ 卡体内现在必须有推子板与检查器。
        for (NSString *ident in @[ @"peqBypass", @"peqPreamp", @"eq.fader", @"eq.inspector", @"eq.curve" ]) {
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

        // ====================================================================
        // ⑥ 设置键值判据（S1a · 2026-11-16）：控件在、动作也在，但发出去的**键/值**
        //    必须是后端白名单认的那一套 —— /api/settings 是「白名单 + 合并写」，
        //    不在白名单的键**静默丢弃**（返回 ok:true，conf 里没有该键，重启回默认）。
        //    这种失败无声无息：用户点一下等于没点。
        //    判据口径 = 触发真控件 action ⟹ 读回 /api/settings 的 kv，按**后端键**断言。
        // ====================================================================
        NSDictionary *(^ReadKV)(void) = ^NSDictionary *(void) {
            NSDictionary *js = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil];
            return [js[@"kv"] isKindOfClass:[NSDictionary class]] ? js[@"kv"] : @{};
        };
        NSInteger (^IndexOf)(NSPopUpButton *, NSString *) = ^NSInteger(NSPopUpButton *p, NSString *t) {
            for (NSInteger i = 0; i < (NSInteger)p.numberOfItems; ++i)
                if ([[p itemAtIndex:i].title isEqualToString:t]) return i;
            return -1;
        };

        // ---- ⑥a sp_2s：web #s2s 落盘键是 twostage（ui_script.h:978），不是 2s ----
        [settings selectPane:@"pcm"];
        Pump(0.5);
        [v layoutSubtreeIfNeeded];
        NSSwitch *twoStage = (NSSwitch *)FindId(PaneRoot(v, @"pcm"), @"sp_2s");
        if ([twoStage isKindOfClass:[NSSwitch class]]) {
            twoStage.state = NSControlStateValueOff;
            Fire(twoStage);
            Pump(0.6);
            NSDictionary *kvOff = ReadKV();
            Ck([kvOff[@"twostage"] isEqualToString:@"0"],
               @"【键值】sp_2s 关 ⟹ POST twostage=0（后端白名单键；旧码发的 2s 被丢弃）",
               [NSString stringWithFormat:@"kv.twostage=%@", kvOff[@"twostage"] ?: @"(无)"]);
            twoStage.state = NSControlStateValueOn;
            Fire(twoStage);
            Pump(0.6);
            NSDictionary *kvOn = ReadKV();
            Ck([kvOn[@"twostage"] isEqualToString:@"1"],
               @"【键值】sp_2s 开 ⟹ POST twostage=1",
               [NSString stringWithFormat:@"kv.twostage=%@", kvOn[@"twostage"] ?: @"(无)"]);
        } else {
            Ck(NO, @"【键值】sp_2s 是开关（pcm 页）", twoStage ? NSStringFromClass(twoStage.class) : @"控件缺失");
        }

        // ---- ⑥b sp_loud：web #sLoud 落盘键是 loudness（ui_script.h:976），不是 loud ----
        [settings selectPane:@"adv"];
        Pump(0.5);
        [v layoutSubtreeIfNeeded];
        NSSwitch *loud = (NSSwitch *)FindId(PaneRoot(v, @"adv"), @"sp_loud");
        if ([loud isKindOfClass:[NSSwitch class]]) {
            loud.state = NSControlStateValueOn;
            Fire(loud);
            Pump(0.6);
            NSDictionary *kvLoudOn = ReadKV();
            Ck([kvLoudOn[@"loudness"] isEqualToString:@"1"],
               @"【键值】sp_loud 开 ⟹ POST loudness=1（旧码发的 loud 被丢弃）",
               [NSString stringWithFormat:@"kv.loudness=%@", kvLoudOn[@"loudness"] ?: @"(无)"]);
            loud.state = NSControlStateValueOff;
            Fire(loud);
            Pump(0.6);
            NSDictionary *kvLoudOff = ReadKV();
            Ck([kvLoudOff[@"loudness"] isEqualToString:@"0"],
               @"【键值】sp_loud 关 ⟹ POST loudness=0",
               [NSString stringWithFormat:@"kv.loudness=%@", kvLoudOff[@"loudness"] ?: @"(无)"]);
        } else {
            Ck(NO, @"【键值】sp_loud 是开关（adv 页）", loud ? NSStringFromClass(loud.class) : @"控件缺失");
        }

        // ---- ⑥c sp_rate：web #sRate 的 option value = follow / max / src + Hz（ui_page.h:1547）----
        [settings selectPane:@"out"];
        Pump(0.5);
        [v layoutSubtreeIfNeeded];
        NSPopUpButton *ratePop = (NSPopUpButton *)FindId(PaneRoot(v, @"out"), @"sp_rate");
        NSArray<NSArray<NSString *> *> *rateCases = @[
            @[ RLPTr(@"自动（设备最高）"), @"max" ],
            @[ RLPTr(@"跟随系统"), @"follow" ],
            @[ RLPTr(@"源采样率"), @"src" ],
            @[ @"96000", @"96000" ],
        ];
        if ([ratePop isKindOfClass:[NSPopUpButton class]]) {
            for (NSArray<NSString *> *c in rateCases) {
                const NSInteger idx = IndexOf(ratePop, c[0]);
                if (idx < 0) {
                    Ck(NO, [NSString stringWithFormat:@"【键值】输出采样率有「%@」项", c[0]], @"选项缺失");
                    continue;
                }
                [ratePop selectItemAtIndex:idx];
                Fire(ratePop);
                Pump(0.5);
                NSDictionary *kvRate = ReadKV();
                Ck([kvRate[@"rate"] isEqualToString:c[1]],
                   [NSString stringWithFormat:@"【键值】输出采样率「%@」⟹ POST rate=%@", c[0], c[1]],
                   [NSString stringWithFormat:@"kv.rate=%@", kvRate[@"rate"] ?: @"(无)"]);
            }
        } else {
            Ck(NO, @"【键值】sp_rate 是下拉（out 页）", ratePop ? NSStringFromClass(ratePop.class) : @"控件缺失");
        }

        // ---- ⑥d sp_bits：web #sp_bits 的 option value = -1 / 0 / 16 / 32（ui_script.h:9855-9858）----
        NSPopUpButton *bitsPop = (NSPopUpButton *)FindId(PaneRoot(v, @"out"), @"sp_bits");
        NSArray<NSArray<NSString *> *> *bitsCases = @[
            @[ RLPTr(@"跟随源（按文件位深）"), @"-1" ],
            @[ @"24 bit", @"0" ],
            @[ @"16 bit", @"16" ],
            @[ @"32 bit", @"32" ],
        ];
        if ([bitsPop isKindOfClass:[NSPopUpButton class]]) {
            for (NSArray<NSString *> *c in bitsCases) {
                const NSInteger idx = IndexOf(bitsPop, c[0]);
                if (idx < 0) {
                    Ck(NO, [NSString stringWithFormat:@"【键值】输出位深有「%@」项", c[0]], @"选项缺失");
                    continue;
                }
                [bitsPop selectItemAtIndex:idx];
                Fire(bitsPop);
                Pump(0.5);
                NSDictionary *kvBits = ReadKV();
                Ck([kvBits[@"bits"] isEqualToString:c[1]],
                   [NSString stringWithFormat:@"【键值】输出位深「%@」⟹ POST bits=%@", c[0], c[1]],
                   [NSString stringWithFormat:@"kv.bits=%@", kvBits[@"bits"] ?: @"(无)"]);
            }
        } else {
            Ck(NO, @"【键值】sp_bits 是下拉（out 页）", bitsPop ? NSStringFromClass(bitsPop.class) : @"控件缺失");
        }

        // ---- ⑦ 回填：kv 的**值**必须能把下拉切回对应项（值 ≠ 文案 ⟹ 不能再按文案匹配）----
        if ([ratePop isKindOfClass:[NSPopUpButton class]] && [bitsPop isKindOfClass:[NSPopUpButton class]]) {
            const NSInteger iMax = IndexOf(ratePop, RLPTr(@"自动（设备最高）"));
            const NSInteger i16 = IndexOf(bitsPop, @"16 bit");
            if (iMax >= 0 && i16 >= 0) {
                [ratePop selectItemAtIndex:iMax];
                Fire(ratePop);
                // 两个 POST 都走并发 IO 队列：连发会让后端两次「读全量 → 合并写」交错，
                // 先到的那次可能被后到的覆盖（实测偶发 kv.bits 仍是上一轮的值）。
                // 这里等第一次落盘再发第二次 —— 判据要证明的是写回，不是竞态。
                Pump(0.2);
                [bitsPop selectItemAtIndex:i16];
                Fire(bitsPop);
                Pump(0.5);
                NSDictionary *kvBeforeReload = ReadKV();
                Ck([kvBeforeReload[@"bits"] isEqualToString:@"16"],
                   @"【回填】前置：bits=16 已落盘（否则回填判据会拿旧值骗人）",
                   [NSString stringWithFormat:@"kv.bits=%@", kvBeforeReload[@"bits"] ?: @"(无)"]);
                [ratePop selectItemAtIndex:0];   // 先人为弄错，才能证明 activate 真的切回来
                [bitsPop selectItemAtIndex:0];
                [settings activate];
                const BOOL rateBack = WaitUntil(3.0, ^BOOL {
                    return [[ratePop titleOfSelectedItem] isEqualToString:RLPTr(@"自动（设备最高）")];
                });
                Ck(rateBack, @"【回填】kv.rate=max ⟹ 下拉回到「自动（设备最高）」",
                   [NSString stringWithFormat:@"当前=%@", ratePop.titleOfSelectedItem ?: @"(无)"]);
                const BOOL bitsBack = WaitUntil(3.0, ^BOOL {
                    return [[bitsPop titleOfSelectedItem] isEqualToString:@"16 bit"];
                });
                Ck(bitsBack, @"【回填】kv.bits=16 ⟹ 下拉回到「16 bit」",
                   [NSString stringWithFormat:@"当前=%@", bitsPop.titleOfSelectedItem ?: @"(无)"]);
            }
        }

        // ====================================================================
        // ⑧ S1b（2026-11-16）：DSD 三控件 → 单个 dsd 键；设备 → id；Nx 滤波器 → 空值首项
        //    web applyDsd（ui_script.h:8958）：PCM ⟹ dsd=0；DSD ⟹ dsd=<pk><rt>
        //    （pk=dop|native，rt=64/128/256/512/1024）。旧原生分开发 outmode / dsdpk /
        //    dsd=<裸数字>：前两个不在 /api/settings 白名单里（静默丢弃），第三个也无法把
        //    封装还原出来。判据 = 触发真控件 action ⟹ 读回 kv.dsd；再 POST kv.dsd 让
        //    reloadData 反解三个控件（值回显，不是只看控件在不在）。
        //    设备：web option value = 设备 id（ui_script.h:5337），旧原生发显示名。
        //    Nx 滤波器：web 空值首项 = 「跟随 1x」（POST filterNx=）；旧原生发中文文案。
        // ====================================================================
        [settings selectPane:@"out"];
        Pump(0.5);
        [v layoutSubtreeIfNeeded];
        NSPopUpButton *outModePop = (NSPopUpButton *)FindId(PaneRoot(v, @"out"), @"sp_outmode");
        Ck([outModePop isKindOfClass:[NSPopUpButton class]],
           @"【S1b】sp_outmode 是下拉（out 页）",
           outModePop ? NSStringFromClass(outModePop.class) : @"控件缺失");

        [settings selectPane:@"sdm"];
        Pump(0.5);
        [v layoutSubtreeIfNeeded];
        NSView *sdmPaneS1b = PaneRoot(v, @"sdm");
        NSPopUpButton *dsdRatePop = (NSPopUpButton *)FindId(sdmPaneS1b, @"sp_dsdrate");
        NSPopUpButton *dsdPackPop = (NSPopUpButton *)FindId(sdmPaneS1b, @"sp_dsdpk");
        Ck([dsdRatePop isKindOfClass:[NSPopUpButton class]],
           @"【S1b】sp_dsdrate 是下拉（SDM 页）",
           dsdRatePop ? NSStringFromClass(dsdRatePop.class) : @"控件缺失");
        Ck([dsdPackPop isKindOfClass:[NSPopUpButton class]],
           @"【S1b】sp_dsdpk 是下拉（SDM 页）",
           dsdPackPop ? NSStringFromClass(dsdPackPop.class) : @"控件缺失");

        if ([outModePop isKindOfClass:[NSPopUpButton class]] &&
            [dsdRatePop isKindOfClass:[NSPopUpButton class]] &&
            [dsdPackPop isKindOfClass:[NSPopUpButton class]]) {
            // ---- ⑧a PCM ⟹ dsd=0（旧码发 outmode，白名单静默丢弃 ⟹ kv.dsd 根本不存在）----
            [outModePop selectItemWithTitle:@"pcm"];
            Fire(outModePop);
            Pump(0.6);
            NSDictionary *kvPcmS1b = ReadKV();
            Ck([kvPcmS1b[@"dsd"] isEqualToString:@"0"],
               @"【S1b·dsd】输出模式 PCM ⟹ POST dsd=0（旧码发 outmode，被白名单丢弃）",
               [NSString stringWithFormat:@"kv.dsd=%@ kv.outmode=%@ kv.dsdpk=%@",
                kvPcmS1b[@"dsd"] ?: @"(无)", kvPcmS1b[@"outmode"] ?: @"(无)", kvPcmS1b[@"dsdpk"] ?: @"(无)"]);
            Ck(kvPcmS1b[@"outmode"] == nil,
               @"【S1b·dsd】不再发 outmode（白名单外，POST 回 ok 也不落盘）",
               [NSString stringWithFormat:@"kv.outmode=%@", kvPcmS1b[@"outmode"] ?: @"(无)"]);

            // ---- ⑧b DSD ⟹ dsd=<pk><rt>；改比特率/封装都作用在同一个键上 ----
            [outModePop selectItemWithTitle:@"dsd"];
            Fire(outModePop);
            Pump(0.3);
            [dsdRatePop selectItemWithTitle:@"256"];
            Fire(dsdRatePop);
            [dsdPackPop selectItemWithTitle:@"dop"];
            Fire(dsdPackPop);
            Pump(0.6);
            NSDictionary *kvD256 = ReadKV();
            Ck([kvD256[@"dsd"] isEqualToString:@"dop256"],
               @"【S1b·dsd】DSD + DoP + 256 ⟹ POST dsd=dop256（旧码发 dsd=256 + dsdpk）",
               [NSString stringWithFormat:@"kv.dsd=%@", kvD256[@"dsd"] ?: @"(无)"]);
            [dsdRatePop selectItemWithTitle:@"512"];
            Fire(dsdRatePop);
            Pump(0.6);
            NSDictionary *kvD512 = ReadKV();
            Ck([kvD512[@"dsd"] isEqualToString:@"dop512"],
               @"【S1b·dsd】DSD 比特率 512 ⟹ dsd=dop512",
               [NSString stringWithFormat:@"kv.dsd=%@", kvD512[@"dsd"] ?: @"(无)"]);

            // ---- ⑧c PCM 下改比特率/封装必须联动切到 DSD（web onchange，ui_script.h:10465）----
            [outModePop selectItemWithTitle:@"pcm"];
            Fire(outModePop);
            Pump(0.6);
            NSDictionary *kvPcm2 = ReadKV();
            Ck([kvPcm2[@"dsd"] isEqualToString:@"0"], @"【S1b·dsd】再切回 PCM ⟹ dsd=0",
               [NSString stringWithFormat:@"kv.dsd=%@", kvPcm2[@"dsd"] ?: @"(无)"]);
            [dsdRatePop selectItemWithTitle:@"128"];
            Fire(dsdRatePop);
            Pump(0.6);
            NSDictionary *kvAuto = ReadKV();
            Ck([kvAuto[@"dsd"] isEqualToString:@"dop128"],
               @"【S1b·dsd】PCM 下改比特率 128 ⟹ dsd=dop128（自动切 DSD）",
               [NSString stringWithFormat:@"kv.dsd=%@", kvAuto[@"dsd"] ?: @"(无)"]);
            Ck([[outModePop titleOfSelectedItem] isEqualToString:@"dsd"],
               @"【S1b·dsd】PCM 下改比特率 ⟹ 输出模式下拉联动到 DSD",
               [NSString stringWithFormat:@"当前=%@", outModePop.titleOfSelectedItem ?: @"(无)"]);

            // ---- ⑧d 反解：kv.dsd ⟹ 三个控件（交叉设错再 activate，证明真的按值回显）----
            [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"dsd=dop512"];
            [outModePop selectItemWithTitle:@"pcm"];
            [dsdRatePop selectItemWithTitle:@"64"];
            [dsdPackPop selectItemWithTitle:@"dop"];
            [settings activate];
            BOOL backOutDsd = WaitUntil(3.0, ^BOOL {
                return [[outModePop titleOfSelectedItem] isEqualToString:@"dsd"];
            });
            Ck(backOutDsd, @"【S1b·回填】kv.dsd=dop512 ⟹ 输出模式回显 DSD",
               [NSString stringWithFormat:@"当前=%@", outModePop.titleOfSelectedItem ?: @"(无)"]);
            BOOL backRate512 = WaitUntil(3.0, ^BOOL {
                return [[dsdRatePop titleOfSelectedItem] isEqualToString:@"512"];
            });
            Ck(backRate512, @"【S1b·回填】kv.dsd=dop512 ⟹ 比特率回显 512（旧码找 dsd512 永远找不到）",
               [NSString stringWithFormat:@"当前=%@", dsdRatePop.titleOfSelectedItem ?: @"(无)"]);
            BOOL backPackDop = WaitUntil(3.0, ^BOOL {
                return [[dsdPackPop titleOfSelectedItem] isEqualToString:@"dop"];
            });
            Ck(backPackDop, @"【S1b·回填】kv.dsd=dop512 ⟹ 封装回显 DoP",
               [NSString stringWithFormat:@"当前=%@", dsdPackPop.titleOfSelectedItem ?: @"(无)"]);

            [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"dsd=0"];
            [outModePop selectItemWithTitle:@"dsd"];
            [dsdRatePop selectItemWithTitle:@"512"];
            [settings activate];
            BOOL backOutPcm = WaitUntil(3.0, ^BOOL {
                return [[outModePop titleOfSelectedItem] isEqualToString:@"pcm"];
            });
            Ck(backOutPcm, @"【S1b·回填】kv.dsd=0 ⟹ 输出模式回显 PCM",
               [NSString stringWithFormat:@"当前=%@", outModePop.titleOfSelectedItem ?: @"(无)"]);
            BOOL backRate256 = WaitUntil(3.0, ^BOOL {
                return [[dsdRatePop titleOfSelectedItem] isEqualToString:@"256"];
            });
            Ck(backRate256, @"【S1b·回填】kv.dsd=0 ⟹ 比特率回显默认 256（web dsdRateOf 同口径）",
               [NSString stringWithFormat:@"当前=%@", dsdRatePop.titleOfSelectedItem ?: @"(无)"]);

            // 上一版原生存过裸数字（dsd=128），回填必须兼容，否则升级用户的 DSD 档会被读没
            [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"dsd=128"];
            [settings activate];
            BOOL legacyD = WaitUntil(3.0, ^BOOL {
                return [[outModePop titleOfSelectedItem] isEqualToString:@"dsd"] &&
                       [[dsdRatePop titleOfSelectedItem] isEqualToString:@"128"];
            });
            Ck(legacyD, @"【S1b·回填】旧 conf 的裸数字 dsd=128 也能反解（DSD / 128）",
               [NSString stringWithFormat:@"输出模式=%@ 比特率=%@",
                outModePop.titleOfSelectedItem ?: @"(无)", dsdRatePop.titleOfSelectedItem ?: @"(无)"]);
        }

        // ---- ⑧e 设备：发设备 id（web option value=id），不是显示名 ----
        NSDictionary *devJsonS1b = [core jsonWithMethod:@"GET" path:@"/api/devices" body:nil];
        NSArray *devListS1b = [devJsonS1b[@"devices"] isKindOfClass:[NSArray class]] ? devJsonS1b[@"devices"] : @[];
        NSString *devIdS1b = nil, *devNameS1b = nil;
        for (id d in devListS1b) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            NSString *n = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : nil;
            NSString *i2 = [d[@"id"] isKindOfClass:[NSString class]] ? d[@"id"] : nil;
            if (n.length && i2.length && ![n isEqualToString:i2]) { devIdS1b = i2; devNameS1b = n; break; }
        }
        if (!devIdS1b) {
            Ck(NO, @"【S1b·device】/api/devices 至少一个带稳定 id 的输出设备", @"设备列表为空或没有 id");
        } else {
            [settings selectPane:@"out"];
            Pump(0.5);
            [v layoutSubtreeIfNeeded];
            NSPopUpButton *devicePopS1b = (NSPopUpButton *)FindId(PaneRoot(v, @"out"), @"sp_device");
            Ck([devicePopS1b isKindOfClass:[NSPopUpButton class]],
               @"【S1b·device】sp_device 是下拉", devicePopS1b ? NSStringFromClass(devicePopS1b.class) : @"控件缺失");
            Ck(devicePopS1b.numberOfItems > 0 &&
               [[devicePopS1b itemAtIndex:0].representedObject isKindOfClass:[NSString class]] &&
               [((NSString *)[devicePopS1b itemAtIndex:0].representedObject) isEqualToString:@""],
               @"【S1b·device】首项是空值「默认设备」（web option value=\"\"）",
               [NSString stringWithFormat:@"items=%ld 首项=%@",
                (long)devicePopS1b.numberOfItems, [devicePopS1b itemAtIndex:0].title ?: @"(无)"]);

            NSInteger devIdxS1b = -1;
            for (NSInteger i = 1; i < (NSInteger)devicePopS1b.numberOfItems; ++i) {
                id ro = [devicePopS1b itemAtIndex:i].representedObject;
                if ([ro isKindOfClass:[NSString class]] && [(NSString *)ro isEqualToString:devIdS1b]) {
                    devIdxS1b = i; break;
                }
            }
            Ck(devIdxS1b > 0, @"【S1b·device】下拉项携带设备 id（representedObject）",
               [NSString stringWithFormat:@"id=%@ 未出现在下拉里", devIdS1b]);
            if (devIdxS1b > 0) {
                [devicePopS1b selectItemAtIndex:devIdxS1b];
                Fire(devicePopS1b);
                Pump(0.6);
                NSDictionary *kvDevS1b = ReadKV();
                Ck([kvDevS1b[@"device"] isEqualToString:devIdS1b],
                   @"【S1b·device】选设备 ⟹ POST device=id（旧码发显示名）",
                   [NSString stringWithFormat:@"kv.device=%@ 期望 id=%@（显示名=%@）",
                    kvDevS1b[@"device"] ?: @"(无)", devIdS1b, devNameS1b]);
                Ck(![kvDevS1b[@"device"] isEqualToString:devNameS1b],
                   @"【S1b·device】落盘的不是显示名", [NSString stringWithFormat:@"kv.device=%@", kvDevS1b[@"device"] ?: @"(无)"]);

                [core jsonWithMethod:@"POST" path:@"/api/settings" body:[NSString stringWithFormat:@"device=%@", RLPEnc(devIdS1b)]];
                [devicePopS1b selectItemAtIndex:0];
                [settings activate];
                BOOL devBackS1b = WaitUntil(3.0, ^BOOL {
                    return [[devicePopS1b titleOfSelectedItem] isEqualToString:devNameS1b];
                });
                Ck(devBackS1b, @"【S1b·回填】kv.device=id ⟹ 设备下拉按 id 回显显示名",
                   [NSString stringWithFormat:@"当前=%@ 期望=%@",
                    devicePopS1b.titleOfSelectedItem ?: @"(无)", devNameS1b]);
            }
        }

        // ---- ⑧f Nx 滤波器：保留「跟随 1x」空值首项；选中时发 filterNx=（空串）----
        [settings selectPane:@"pcm"];
        Pump(0.6);
        [v layoutSubtreeIfNeeded];
        NSPopUpButton *filtNxPopS1b = (NSPopUpButton *)FindId(PaneRoot(v, @"pcm"), @"sp_filtNx");
        Ck([filtNxPopS1b isKindOfClass:[NSPopUpButton class]],
           @"【S1b·filtNx】sp_filtNx 是下拉", filtNxPopS1b ? NSStringFromClass(filtNxPopS1b.class) : @"控件缺失");
        NSDictionary *filtersJsonS1b = [core jsonWithMethod:@"GET" path:@"/api/filters" body:nil];
        NSArray *filterItemsS1b = [filtersJsonS1b[@"items"] isKindOfClass:[NSArray class]] ? filtersJsonS1b[@"items"] : @[];
        NSString *nxNameS1b = nil;
        for (id it in filterItemsS1b) {
            NSString *n = [it isKindOfClass:[NSDictionary class]] ? it[@"name"]
                         : ([it isKindOfClass:[NSString class]] ? it : nil);
            if (n.length) { nxNameS1b = n; break; }
        }
        if ([filtNxPopS1b isKindOfClass:[NSPopUpButton class]]) {
            BOOL nxReadyS1b = WaitUntil(3.0, ^BOOL { return filtNxPopS1b.numberOfItems > 1; });
            Ck(nxReadyS1b, @"【S1b·filtNx】/api/filters 已填入下拉", @"清单为空");
            NSMenuItem *nxFirstS1b = filtNxPopS1b.numberOfItems ? [filtNxPopS1b itemAtIndex:0] : nil;
            Ck(nxFirstS1b && [nxFirstS1b.title rangeOfString:@"跟随 1x"].location != NSNotFound,
               @"【S1b·filtNx】首项保留「跟随 1x（不单独指定）」（旧码 removeAllItems 后丢失）",
               [NSString stringWithFormat:@"首项=%@", nxFirstS1b.title ?: @"(无)"]);
            Ck(nxFirstS1b &&
               [nxFirstS1b.representedObject isKindOfClass:[NSString class]] &&
               [((NSString *)nxFirstS1b.representedObject) isEqualToString:@""],
               @"【S1b·filtNx】首项的值是空串（POST filterNx=）",
               [NSString stringWithFormat:@"representedObject=%@", nxFirstS1b.representedObject ?: @"(nil)"]);

            if (nxNameS1b.length) {
                NSInteger nxIdxS1b = IndexOf(filtNxPopS1b, nxNameS1b);
                if (nxIdxS1b < 0) {
                    Ck(NO, [NSString stringWithFormat:@"【S1b·filtNx】下拉有「%@」", nxNameS1b], @"选项缺失");
                } else {
                    [filtNxPopS1b selectItemAtIndex:nxIdxS1b];
                    Fire(filtNxPopS1b);
                    Pump(0.6);
                    NSDictionary *kvNxNamed = ReadKV();
                    Ck([kvNxNamed[@"filterNx"] isEqualToString:nxNameS1b],
                       @"【S1b·filtNx】选中具体滤波器 ⟹ POST filterNx=名字",
                       [NSString stringWithFormat:@"kv.filterNx=%@", kvNxNamed[@"filterNx"] ?: @"(无)"]);

                    [filtNxPopS1b selectItemAtIndex:0];
                    Fire(filtNxPopS1b);
                    Pump(0.6);
                    NSDictionary *kvNxFirst = ReadKV();
                    Ck([kvNxFirst[@"filterNx"] isKindOfClass:[NSString class]] &&
                       [kvNxFirst[@"filterNx"] length] == 0,
                       @"【S1b·filtNx】选中「跟随 1x」⟹ POST filterNx=（空串；旧码发中文文案）",
                       [NSString stringWithFormat:@"kv.filterNx=%@", kvNxFirst[@"filterNx"] ?: @"(无)"]);

                    [core jsonWithMethod:@"POST" path:@"/api/settings"
                                    body:[NSString stringWithFormat:@"filterNx=%@", RLPEnc(nxNameS1b)]];
                    [filtNxPopS1b selectItemAtIndex:0];
                    [settings activate];
                    BOOL nxBackNamed = WaitUntil(3.0, ^BOOL {
                        return [[filtNxPopS1b titleOfSelectedItem] isEqualToString:nxNameS1b];
                    });
                    Ck(nxBackNamed, @"【S1b·回填】kv.filterNx=名字 ⟹ 下拉回显该滤波器",
                       [NSString stringWithFormat:@"当前=%@", filtNxPopS1b.titleOfSelectedItem ?: @"(无)"]);

                    [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"filterNx="];
                    [filtNxPopS1b selectItemAtIndex:nxIdxS1b];
                    [settings activate];
                    BOOL nxBackEmpty = WaitUntil(3.0, ^BOOL {
                        return filtNxPopS1b.indexOfSelectedItem == 0;
                    });
                    Ck(nxBackEmpty, @"【S1b·回填】kv.filterNx=空 ⟹ 下拉回显「跟随 1x」",
                       [NSString stringWithFormat:@"当前=%@", filtNxPopS1b.titleOfSelectedItem ?: @"(无)"]);
                }
            } else {
                Ck(NO, @"【S1b·filtNx】/api/filters 至少返回一个滤波器名", @"清单为空");
            }
        }

        std::printf("结果：%d passed, %d failed\n", gPass, gFail);
        return gFail ? 1 : 0;
    }
}
