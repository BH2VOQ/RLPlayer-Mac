// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_eq_contract.mm — EQ 页「真后端 · 真数据 · 真拖动」端到端判据
//
// ============================ 这条判据在证明什么 ============================
// 用户 2026-11-15 实机反馈（原话）：
//   「eq 的效果图无法拖动 没有分 band 然后底下的数据栏会抢滚动焦点」
//
// 上一轮的伪修复：把坐标换算抽成纯函数、加了 13 条几何单测、加了「20 段频点 +
// 20 个增益手柄」的审计断言 —— 全绿。但用户看到的现象一模一样。为什么？
// 因为**判据和产品用了同一套错误假设**：
//   · 原生读 JSON 用 f/g，后端实际给 freq/gain ⟹ 每段都是 nil ⟹ 全变 0；
//   · 原生发 bands=「频率,增益,Q,类型」，后端只认「序号,类型码,频率,增益,Q」
//     ⟹ 每次提交都被拒（"bands 参数格式不对"），一次都没真正下发过；
//   · 审计只数「bandFreqs.count == 20」—— 20 个**0.0** 也满足，于是假绿。
//
// 本测试因此**只认端到端事实**，全部走真实 embedded 核心（rlapp_core），不打桩：
//   E1  GET /api/peq 的 20 段频率是真实 ISO 序列（不是 0）
//   E2  视图吸收后 bandFreqs 是 20 个**互不相同**的真实频率，覆盖 20Hz~20kHz
//   E3  20 段参数表显示的是真实频率（第 1 行 20.0 / 第 11 行 1000.0）
//   E4  20 个手柄的横坐标真的铺满绘图区（不是全叠在最左端 —— 那就是"没有分 band"）
//   E5  在 1 kHz 处按下拖动，命中的是 **1 kHz 那一段**（不是永远第 0 段）
//   E6  拖动后核心 /api/peq 的真实状态里，**恰好那一段**增益变了（其余仍为 0）
//   E7  提交被后端接受（状态行不出现「失败」；这是"格式对不对"的最终裁判）
//   E8  类型下拉给的是后端码 PK/LS/HS（不是 peak/lowshelf/highshelf）
//
// 红→绿（实测）：修复前 E2/E3/E4/E5/E6/E7/E8 全红；修复后全绿。
//
// 纪律：backend=null、volume=-120、不打开任何音频设备、不播放（铁律②）。
#import <AppKit/AppKit.h>
#import "RLPCoreClient.h"
#import "RLPEqualizerView.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

#include <cstdio>
#include <cstdlib>
#include <unistd.h>

static int gFail = 0, gPass = 0;
static void Ck(BOOL ok, NSString *what, NSString *detail) {
    if (ok) { ++gPass; std::printf("  [PASS] %s\n", what.UTF8String); }
    else { ++gFail; std::printf("  [FAIL] %s — %s\n", what.UTF8String, detail.UTF8String ?: ""); }
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
static NSView *FindId(NSView *root, NSString *ident) {
    NSMutableArray<NSView *> *all = [NSMutableArray array];
    Collect(root, all);
    for (NSView *v in all) if ([v.identifier isEqualToString:ident]) return v;
    return nil;
}

/// 曲线视图的私有几何入口（同 RLPEqualizerView.mm 的 drawRect 坐标；仅测试侧可见）。
@interface NSObject (RLPEQCurveGeometry)
- (NSRect)plotRect;
- (CGFloat)xForFreq:(double)f;
@end

/// 翻转文档视图（内容从顶部开始排；否则 hitTest 直接返回 nil）。
@interface RLPEQFlippedDoc : NSView
@end
@implementation RLPEQFlippedDoc
- (BOOL)isFlipped { return YES; }
@end

int main() {
    @autoreleasepool {
        [NSApplication sharedApplication];
        std::printf("=== test_native_eq_contract（真后端 / 真数据 / 真拖动）===\n");

        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"rlp-eqcontract-%d", (int)getpid()]];
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

        // ---- E1：真实后端给的是 freq/gain 而不是 f/g ----
        NSDictionary *peq = [core jsonWithMethod:@"GET" path:@"/api/peq" body:nil];
        NSArray *rawBands = [peq[@"bands"] isKindOfClass:[NSArray class]] ? peq[@"bands"] : @[];
        Ck(rawBands.count == 20, @"E1 后端 /api/peq 给出 20 段",
           [NSString stringWithFormat:@"bands=%lu", (unsigned long)rawBands.count]);
        NSDictionary *b0 = rawBands.count ? rawBands[0] : nil;
        Ck([b0[@"freq"] respondsToSelector:@selector(doubleValue)] && !b0[@"f"],
           @"E1 后端字段名是 freq/gain（不是 f/g）—— 说明原生旧读法是错的",
           [NSString stringWithFormat:@"band0=%@", b0]);

        // ---- 造真实窗口 + 整页滚动外层（拖动要用 window 坐标）----
        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1180, 900)
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        NSScrollView *pageScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 1180, 860)];
        pageScroll.hasVerticalScroller = YES;
        RLPEQFlippedDoc *doc = [[RLPEQFlippedDoc alloc] initWithFrame:NSMakeRect(0, 0, 1180, 2400)];
        pageScroll.documentView = doc;
        [win.contentView addSubview:pageScroll];

        RLPEqualizerView *eq = [[RLPEqualizerView alloc] initWithFrame:NSMakeRect(0, 0, 1000, 1500)];
        eq.translatesAutoresizingMaskIntoConstraints = NO;
        [doc addSubview:eq];
        [NSLayoutConstraint activateConstraints:@[
            [eq.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor],
            [eq.topAnchor constraintEqualToAnchor:doc.topAnchor],
            [eq.widthAnchor constraintEqualToConstant:1000],
            [eq.heightAnchor constraintEqualToConstant:1500],
        ]];
        [eq setEmbeddedInPage:YES];
        [eq reload];
        Pump(1.0);
        [win layoutIfNeeded];
        [doc layoutSubtreeIfNeeded];
        [eq layoutSubtreeIfNeeded];

        // ---- E2：视图吸收到的频段是 20 个互不相同的真实频率 ----
        NSView *curve = FindId(eq, @"eq.curve");
        Ck(curve != nil, @"E2 找到 EQ 曲线视图", @"缺 eq.curve");
        NSArray *bandFreqs = [curve valueForKey:@"bandFreqs"];
        Ck(bandFreqs.count == 20, @"E2 曲线拿到 20 个频点",
           [NSString stringWithFormat:@"n=%lu", (unsigned long)bandFreqs.count]);
        NSMutableSet *uniq = [NSMutableSet set];
        double fMin = 1e9, fMax = 0;
        for (NSNumber *f in bandFreqs) {
            [uniq addObject:f];
            fMin = MIN(fMin, f.doubleValue);
            fMax = MAX(fMax, f.doubleValue);
        }
        Ck(uniq.count == 20,
           @"E2 20 个频点互不相同（全 0 就是旧 bug：JSON 键读错，freq 取到 nil）",
           [NSString stringWithFormat:@"unique=%lu 前三个=%@", (unsigned long)uniq.count,
            [bandFreqs count] > 2 ? [bandFreqs[0] description] : @"-"]);
        Ck(fMin <= 25.0 && fMax >= 19999.0,
           @"E2 频点覆盖 20Hz~20kHz（ISO 1/3 倍频程序列）",
           [NSString stringWithFormat:@"min=%.1f max=%.1f", fMin, fMax]);

        // ---- E3：20 段参数表显示真实频率 ----
        NSTableView *table = (NSTableView *)FindId(eq, @"peq.bands");
        Ck(table != nil, @"E3 找到 20 段参数表", @"缺 peq.bands");
        NSArray *cell0 = [table.tableColumns[0] identifier] ? nil : nil;
        (void)cell0;
        NSView *row0f = [eq respondsToSelector:@selector(tableView:viewForTableColumn:row:)]
            ? [(id)eq tableView:table viewForTableColumn:table.tableColumns[1] row:0] : nil;
        NSView *row10f = [(id)eq tableView:table viewForTableColumn:table.tableColumns[1] row:10];
        NSString *t0 = [row0f isKindOfClass:[NSTextField class]] ? ((NSTextField *)row0f).stringValue : @"";
        NSString *t10 = [row10f isKindOfClass:[NSTextField class]] ? ((NSTextField *)row10f).stringValue : @"";
        Ck([t0 doubleValue] > 19.0 && [t0 doubleValue] < 21.0,
           @"E3 参数表第 1 行频率显示 20 Hz（旧码显示 0.0）",
           [NSString stringWithFormat:@"row0=%@", t0]);
        Ck([t10 doubleValue] > 999.0 && [t10 doubleValue] < 1001.0,
           @"E3 参数表第 11 行频率显示 1000 Hz",
           [NSString stringWithFormat:@"row10=%@", t10]);

        // ---- E4：20 个手柄横坐标真的铺满绘图区 ----
        // 旧 bug：bandFreqs 全是 0 ⟹ 全部落在绘图区最左端 ⟹ 视觉上"没有分 band"。
        NSRect plot = [(id)curve respondsToSelector:NSSelectorFromString(@"plotRect")]
            ? [(id)curve plotRect] : NSZeroRect;
        NSMutableArray<NSNumber *> *xs = [NSMutableArray array];
        for (NSNumber *f in bandFreqs) {
            const CGFloat x = [(id)curve respondsToSelector:NSSelectorFromString(@"xForFreq:")]
                ? [(id)curve xForFreq:f.doubleValue] : 0;
            [xs addObject:@(x)];
        }
        NSMutableSet *uniqX = [NSMutableSet set];
        for (NSNumber *x in xs) [uniqX addObject:@(((int)round(x.doubleValue)))];
        double span = 0;
        if (xs.count >= 2) {
            span = xs.lastObject.doubleValue - xs.firstObject.doubleValue;
        }
        Ck(plot.size.width > 100 && uniqX.count == 20 && span > plot.size.width * 0.7,
           @"E4 20 个手柄横坐标铺满绘图区（不是全叠在最左端）",
           [NSString stringWithFormat:@"uniqX=%lu span=%.0f plotW=%.0f",
            (unsigned long)uniqX.count, span, plot.size.width]);

        // ---- E5/E6/E7：在 1 kHz 处拖动，命中的必须是 1 kHz 那一段 ----
        // 先把核心状态清成 Flat（全 0 dB），这样"哪一段变了"没有歧义。
        [core jsonWithMethod:@"POST" path:@"/api/peq/preset" body:@"action=reset&name="];
        eq.reload;
        [eq reload];
        Pump(0.8);
        [eq layoutSubtreeIfNeeded];

        // 1 kHz 在 20Hz..20kHz 的对数轴上是 0.5663（见 test_native_eq_geometry 的 E3）
        const CGFloat xFrac = 0.5663;
        const NSRect plot2 = [(id)curve plotRect];
        const NSRect inWin = [curve convertRect:curve.bounds toView:nil];
        const NSPoint p0 = NSMakePoint(inWin.origin.x + plot2.origin.x + plot2.size.width * xFrac,
                                       inWin.origin.y + NSMidY(plot2));
        const NSPoint p1 = NSMakePoint(p0.x, p0.y + 40);   // 向上拖 = 提升增益

        NSEvent *(^mouse)(NSEventType, NSPoint) = ^NSEvent *(NSEventType type, NSPoint at) {
            return [NSEvent mouseEventWithType:type location:at modifierFlags:0
                                     timestamp:[NSDate timeIntervalSinceReferenceDate]
                                  windowNumber:win.windowNumber context:nil eventNumber:0
                                    clickCount:1 pressure:type == NSEventTypeLeftMouseUp ? 0.0 : 1.0];
        };
        NSView *hit = [win.contentView hitTest:[win.contentView convertPoint:p0 fromView:nil]];
        Ck(hit == curve, @"E5 1 kHz 处的 hitTest 命中曲线视图本身",
           [NSString stringWithFormat:@"hit=%@", hit ? NSStringFromClass(hit.class) : @"nil"]);
        [curve mouseDown:mouse(NSEventTypeLeftMouseDown, p0)];
        [curve mouseDragged:mouse(NSEventTypeLeftMouseDragged, p1)];
        [curve mouseUp:mouse(NSEventTypeLeftMouseUp, p1)];
        Pump(1.2);   // 260ms 节流 + 主线程回调

        NSInteger activeBand = [[curve valueForKey:@"activeBand"] integerValue];
        Ck(activeBand == 10,
           @"E5 拖动命中第 11 段（1 kHz）—— 不是永远第 1 段（旧 bug：频点全 0）",
           [NSString stringWithFormat:@"activeBand=%ld", (long)activeBand]);

        NSDictionary *after = [core jsonWithMethod:@"GET" path:@"/api/peq" body:nil];
        NSArray *afterBands = [after[@"bands"] isKindOfClass:[NSArray class]] ? after[@"bands"] : @[];
        NSInteger changedIdx = -1;
        double changedGain = 0;
        NSInteger changedCount = 0;
        for (NSUInteger i = 0; i < afterBands.count; ++i) {
            const double g = [afterBands[i][@"gain"] doubleValue];
            if (fabs(g) > 0.05) { ++changedCount; changedIdx = (NSInteger)i; changedGain = g; }
        }
        Ck(changedCount == 1 && changedIdx == 10,
           @"E6 核心状态里恰好第 11 段（1 kHz）增益变了，其余段不变",
           [NSString stringWithFormat:@"changed=%ld idx=%ld gain=%.2f",
            (long)changedCount, (long)changedIdx, changedGain]);
        Ck(fabs(changedGain - 5.5) < 4.0 || changedGain > 1.0,
           @"E6 增益真的被抬上去了（不是 0）",
           [NSString stringWithFormat:@"gain=%.2f", changedGain]);

        // ---- E7：提交被后端接受（格式对了才可能 ok）----
        NSTextField *status = (NSTextField *)FindId(eq, @"peqStatus");
        NSMutableArray<NSView *> *all = [NSMutableArray array];
        Collect(eq, all);
        for (NSView *v in all) {
            if ([v isKindOfClass:[NSTextField class]] && [((NSTextField *)v).stringValue hasPrefix:@"生效"]) {
                status = (NSTextField *)v; break;
            }
        }
        NSString *st = status.stringValue ?: @"";
        Ck(![st containsString:@"失败"],
           @"E7 提交被后端接受（状态行不出现「失败」，即 bands 格式符合契约）",
           st.length ? st : @"状态行为空");
        Ck([st containsString:@"11/20"] || [st containsString:@"1/20"],
           @"E7 状态行如实报出非零段数（证明它读到了真实增益）",
           st.length ? st : @"状态行为空");

        // ---- E8：类型下拉是后端码 ----
        NSView *typeCell = [(id)eq tableView:table viewForTableColumn:table.tableColumns[4] row:0];
        NSString *typeTitle = [typeCell isKindOfClass:[NSPopUpButton class]]
            ? ((NSPopUpButton *)typeCell).titleOfSelectedItem : @"";
        NSString *typeCode = [typeCell isKindOfClass:[NSPopUpButton class]]
            ? [[(NSPopUpButton *)typeCell itemTitleAtIndex:0] copy] : @"";
        Ck([typeCode containsString:@"PK"],
           @"E8 类型下拉首项是「峰值 PK」（后端码；旧码是 peak/lowshelf/highshelf）",
           [NSString stringWithFormat:@"first=%@ selected=%@", typeCode, typeTitle]);

        // ---- E9：web 有而原生曾经没有的两个动作（铁律①：功能不能删减）----
        NSView *autoPre = FindId(eq, @"peqAutoPre");
        NSView *flatBtn = FindId(eq, @"peqReset");
        Ck(autoPre != nil, @"E9 有「自动前级（防削波）」按钮（web #peqAutoPre）", @"缺失");
        Ck(flatBtn != nil, @"E9 有「重置 Flat」按钮（web #peqReset）", @"缺失");

        // ---- E10：自动前级按 web 口径算（-ceil(曲线峰值 − 旧前级)）----
        // 先造一个已知峰值：把第 11 段（1 kHz）做成 +6 dB，再点自动前级。
        [core jsonWithMethod:@"POST" path:@"/api/peq/preset" body:@"action=reset&name="];
        NSMutableString *bp = [NSMutableString string];
        for (NSUInteger i = 1; i <= 20; ++i) {
            const double g = (i == 11) ? 6.0 : 0.0;
            [bp appendFormat:@"%@%lu,PK,%.1f,%.2f,1.41", (i > 1 ? @";" : @""),
                               (unsigned long)i,
                               i == 11 ? 1000.0 : 20.0 * pow(1.0, 1.0) + (double)i,
                               g];
        }
        NSDictionary *setRes = [core jsonWithMethod:@"POST" path:@"/api/peq"
            body:[NSString stringWithFormat:@"bypass=0&preamp=0&bands=%@", bp]];
        Ck([setRes[@"ok"] boolValue], @"E10 前置：把第 11 段设为 +6 dB（真落盘）",
           [setRes[@"error"] description]);
        [eq reload];
        Pump(0.8);
        [eq layoutSubtreeIfNeeded];
        if (autoPre && [autoPre isKindOfClass:[NSButton class]]) {
            [(NSButton *)autoPre performClick:nil];
            Pump(0.9);
            NSDictionary *afterAuto = [core jsonWithMethod:@"GET" path:@"/api/peq" body:nil];
            const double pre = [afterAuto[@"preamp"] doubleValue];
            // 峰值 +6 dB、旧前级 0 ⟹ 前级应为 -ceil(6) = -6 dB
            Ck(fabs(pre + 6.0) < 0.6,
               @"E10 自动前级把前级设成 -6 dB（曲线峰值 +6 dB 向上取整取负）",
               [NSString stringWithFormat:@"preamp=%.2f", pre]);
        }

        std::printf("\n%s（%d passed, %d failed）\n",
                    gFail == 0 ? "EQ 端到端全部通过" : "EQ 端到端有失败", gPass, gFail);
        return gFail == 0 ? 0 : 1;
    }
}
