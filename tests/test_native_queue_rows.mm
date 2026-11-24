// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_queue_rows.mm — 播放队列页行布局 = web `.qrow`
//
// ============================ 这条判据在证明什么 ============================
// web 真源：
//   ui_page.h:506-513  .qrow：display:flex; align-items:center; gap:12; padding:9 18;
//                      border-bottom:1px solid var(--line)；hover bg --hov；.qrow.on bg --acc-weak
//                      + .qt color --acc-text / font-weight:650；.qn 26px 右对齐 11px --mut2 tabular；
//                      .qt flex:1 12.5px nowrap ellipsis；.qp 11px --mut2 max-width 38% nowrap ellipsis
//                      （文件夹名，全路径在 tooltip）；.qdel 24×24 radius 6 opacity 0 →
//                      .qrow:hover .qdel opacity 1。
//   ui_script.h:12556-12585 行内容：序号 / 标题（tooltip 全路径）/ 父文件夹名（tooltip 全路径）/ ×。
// 旧原生（1.1.7.28）：6 列（# 34 / 标题 300 / 艺术家 150 / 专辑 170 / 时长 64 / × 28）、
//   rowHeight 26、× 常显、无文件夹列、无底部分隔线、无当前行背景。所以本文件对旧码必须红。
//
// 铁律②：桩客户端；不启动核心、不碰音频设备、不创建可见窗口。
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "RLPQueueViewController.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

#include <cstdio>
#include <cmath>

static int g_pass = 0, g_fail = 0;
static void Ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++g_fail; }
}
static void EqStr(NSString *got, NSString *want, const char *what) {
    Ck([got isEqualToString:want], what,
       [NSString stringWithFormat:@"got=%@ want=%@", got ?: @"(nil)", want ?: @"(nil)"]);
}

#pragma mark - 桩客户端

static NSMutableArray<NSDictionary *> *g_posts;
static BOOL g_holdQdel;                       // 扣留 /api/qdel 回包（模拟真实异步客户端）
static NSMutableArray<RLPJSONCompletion> *g_heldQdel;
static NSDictionary *g_queueOverride = nil;
static NSDictionary *g_statusOverride = nil;

static NSArray<NSString *> *PathsFixture(void) {
    return @[ @"/Music/A/Song One.flac", @"/Music/B/Sub/Song Two.flac" ];
}
static NSDictionary *QueuePayload(void) {
    return @{ @"ok": @YES, @"index": @0, @"mode": @0,
              @"items": PathsFixture(),
              @"cues": @[ @[ @(-1), @(-1) ], @[ @(10), @(20) ] ],
              @"metas": @[ @{ @"t": @"Song One", @"a": @"Artist A", @"al": @"Album A",
                              @"d": @100, @"y": @2019 },
                           @{ @"t": @"Song Two", @"a": @"Artist B", @"al": @"Album B",
                              @"d": @200, @"y": @2020 } ] };
}

#pragma mark clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RLPCoreClient
+ (instancetype)shared { static RLPCoreClient *c; if (!c) c = [self new]; return c; }
- (BOOL)started { return YES; }
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    if (!done) return;
    if ([path hasPrefix:@"/api/queue?meta=1"]) { done(g_queueOverride ?: QueuePayload()); return; }
    if ([path hasPrefix:@"/api/status"] && g_statusOverride) { done(g_statusOverride); return; }
    if ([path hasPrefix:@"/api/sq/list"]) { done(@{ @"ok": @YES, @"queues": @[] }); return; }
    done(@{ @"ok": @NO });
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done { (void)path; if (done) done(nil); }
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    [g_posts addObject:@{ @"path": path ?: @"", @"body": body ?: @"" }];
    if ([path hasPrefix:@"/api/qdel"] && g_holdQdel) {
        if (done && g_heldQdel) [g_heldQdel addObject:[done copy]];
        return;
    }
    if (done) done(@{ @"ok": @YES });
}
@end
#pragma mark clang diagnostic pop

#pragma mark - 工具

static void Pump(double seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
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
static NSTableView *FindTable(NSView *root) {
    if (!root) return nil;
    if ([root isKindOfClass:[NSTableView class]]) return (NSTableView *)root;
    for (NSView *s in root.subviews) {
        NSTableView *t = FindTable(s);
        if (t) return t;
    }
    return nil;
}
static NSTableColumn *ColForRole(NSTableView *t, NSString *ident) {
    for (NSTableColumn *c in t.tableColumns) if ([c.identifier isEqualToString:ident]) return c;
    return nil;
}
static NSTableCellView *CellAt(NSTableView *t, NSString *ident, NSInteger row) {
    NSInteger idx = -1;
    for (NSInteger i = 0; i < (NSInteger)t.tableColumns.count; ++i)
        if ([t.tableColumns[(NSUInteger)i].identifier isEqualToString:ident]) { idx = i; break; }
    if (idx < 0) return nil;
    NSView *v = [t viewAtColumn:idx row:row makeIfNecessary:YES];
    return [v isKindOfClass:[NSTableCellView class]] ? (NSTableCellView *)v : nil;
}
static NSButton *DelButton(NSTableView *t, NSInteger row) {
    NSTableCellView *cell = CellAt(t, @"q.del", row);
    for (NSView *v in cell.subviews) if ([v isKindOfClass:[NSButton class]]) return (NSButton *)v;
    return nil;
}
static CGFloat LayerRadius(NSView *v) { return v.layer ? (CGFloat)v.layer.cornerRadius : 0.0; }
static CGFloat NumWidth(NSTableColumn *c) { return c ? c.width : -1.0; }
static BOOL SameColor(NSColor *a, NSColor *b) {
    if (!a || !b) return NO;
    NSColor *ca = [a colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    NSColor *cb = [b colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!ca || !cb) return NO;
    return fabs(ca.redComponent - cb.redComponent) < 0.02 &&
           fabs(ca.greenComponent - cb.greenComponent) < 0.02 &&
           fabs(ca.blueComponent - cb.blueComponent) < 0.02;
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        g_posts = [NSMutableArray array];
        g_heldQdel = [NSMutableArray array];
        [RLPTheme setThemeName:@"light"];
        [RLPTheme setUiStyle:@"apple"];
        std::printf("=== test_native_queue_rows（web .qrow 布局 · 离屏 · 不出声）===\n");

        RLPQueueViewController *vc = [RLPQueueViewController new];
        NSView *v = vc.view;
        v.frame = NSMakeRect(0, 0, 1200, 800);
        [v layoutSubtreeIfNeeded];
        [vc performSelector:NSSelectorFromString(@"reloadData")];
        Pump(0.05);
        [v layoutSubtreeIfNeeded];

        NSTableView *table = FindTable(v);
        Ck(table != nil, "找得到队列表格", @"表格缺失");
        if (!table) { std::printf("结果：%d passed, %d failed\n", g_pass, g_fail); return 1; }

        // ---- 1. 4 列 + 行高 + 无列头 ----
        const NSUInteger wantCols = 4;
        Ck(table.tableColumns.count == wantCols, "恰好 4 列（web .qrow 四个子元素）",
           [NSString stringWithFormat:@"cols=%lu", (unsigned long)table.tableColumns.count]);
        for (NSString *ident in @[ @"q.n", @"q.t", @"q.f", @"q.del" ])
            Ck(ColForRole(table, ident) != nil,
               [[NSString stringWithFormat:@"列 %@ 存在", ident] UTF8String], @"缺列");
        Ck(ColForRole(table, @"q.a") == nil && ColForRole(table, @"q.al") == nil &&
           ColForRole(table, @"q.d") == nil,
           "没有艺术家/专辑/时长旧列（web 不显示）", @"旧列还在");
        Ck(fabs(table.rowHeight - 38.0) < 0.51, "行高 38（web padding 9+9 + 12.5 正文）",
           [NSString stringWithFormat:@"rowHeight=%.1f", (double)table.rowHeight]);
        Ck(table.headerView == nil, "没有列头行（web 队列无 thead）", @"headerView 回来了");
        Ck(fabs(NumWidth(ColForRole(table, @"q.n")) - 26.0) < 2.0, "序号列宽 26", @"");
        Ck(fabs(NumWidth(ColForRole(table, @"q.del")) - 24.0) < 2.0, "× 列宽 24", @"");

        // ---- 2. 行内容 = 序号 / 标题 / 父文件夹 / × ----
        NSTableCellView *n0 = CellAt(table, @"q.n", 0);
        NSTableCellView *t0 = CellAt(table, @"q.t", 0);
        NSTableCellView *f0 = CellAt(table, @"q.f", 0);
        NSTableCellView *f1 = CellAt(table, @"q.f", 1);
        Ck(n0 && t0 && f0 && f1, "行内 序号/标题/文件夹 cell 都真实存在", @"缺 cell");
        if (n0) EqStr(n0.textField.stringValue, @"1", "序号文本 = 1");
        if (t0) EqStr(t0.textField.stringValue, @"Song One", "标题文本 = meta.t");
        if (f0) EqStr(f0.textField.stringValue, @"A", "文件夹名 = 路径父目录 basename（A）");
        if (f1) EqStr(f1.textField.stringValue, @"Sub", "文件夹名 = 路径父目录 basename（Sub）");
        if (t0) Ck([t0.textField.toolTip isEqualToString:@"/Music/A/Song One.flac"],
                   "标题 tooltip = 全路径（web .qt title）", t0.textField.toolTip ?: @"");
        if (f0) Ck([f0.textField.toolTip isEqualToString:@"/Music/A/Song One.flac"],
                   "文件夹 tooltip = 全路径（web .qp title）", f0.textField.toolTip ?: @"");

        // ---- 3. 当前行：标题 accent + 行背景 accent-weak；非当前行普通 ----
        RLPTheme *t = [RLPTheme current];
        if (t0) Ck(SameColor(t0.textField.textColor, t.accentText),
                   "当前行标题 = --acc-text（web .qrow.on .qt）",
                   [NSString stringWithFormat:@"got=%@", t0.textField.textColor]);
        NSTableCellView *t1 = CellAt(table, @"q.t", 1);
        if (t1) Ck(SameColor(t1.textField.textColor, t.text),
                   "非当前行标题 = --txt", [NSString stringWithFormat:@"got=%@", t1.textField.textColor]);
        NSTableRowView *rv0 = [table rowViewAtRow:0 makeIfNecessary:YES];
        Ck([rv0 isKindOfClass:NSClassFromString(@"RLPQueueRowView")],
           "行视图 = RLPQueueRowView（hover/当前行/分隔线）",
           NSStringFromClass(rv0.class));

        // ---- 4. ×：默认透明，行悬停后出现 ----
        NSButton *del0 = DelButton(table, 0);
        Ck(del0 != nil && [del0.identifier isEqualToString:@"q.del"], "× 按钮 identifier = q.del", @"缺 ×");
        if (del0) {
            Ck(del0.alphaValue < 0.05, "未悬停时 × 透明（web opacity:0）",
               [NSString stringWithFormat:@"alpha=%.2f", del0.alphaValue]);
            Ck(fabs(LayerRadius(del0) - 6.0) < 0.01 || del0.wantsLayer,
               "× 是 24×24/radius6 的按钮（web .qdel）", @"");
        }
        [(RLPHoverRowView *)rv0 setHoveredForAudit:YES];
        Pump(0.05);
        NSButton *del0b = DelButton(table, 0);
        if (del0b) Ck(del0b.alphaValue > 0.95, "行悬停后 × 不透明（web .qrow:hover .qdel）",
                      [NSString stringWithFormat:@"alpha=%.2f", del0b.alphaValue]);
        // 悬停离开后收回去
        [(RLPHoverRowView *)rv0 setHoveredForAudit:NO];
        Pump(0.05);
        NSButton *del0c = DelButton(table, 0);
        if (del0c) Ck(del0c.alphaValue < 0.05, "悬停离开后 × 恢复透明", [NSString stringWithFormat:@"alpha=%.2f", del0c.alphaValue]);

        // ---- 5. × 点击：只删这一行，不触发播放 ----
        [g_posts removeAllObjects];
        NSButton *delClick = DelButton(table, 1);
        if (delClick) [delClick performClick:nil];
        Pump(0.05);
        BOOL served = NO, played = NO;
        for (NSDictionary *p in g_posts) {
            if ([p[@"path"] hasPrefix:@"/api/qdel"]) served = YES;
            if ([p[@"path"] hasPrefix:@"/api/play"]) played = YES;
        }
        Ck(served, "点 × 发出 /api/qdel（web .qdel）", [g_posts componentsJoinedByString:@" | "]);
        Ck(!played, "点 × 不触发行播放（/api/play 未出现）", @"触发了播放");

        // ---- 6. 拖拽排序仍在 ----
        Ck([table.registeredDraggedTypes containsObject:@"com.rta.rlplayer.queue-row"],
           "拖拽 pasteboard 类型仍注册（qmove 未回退）",
           [table.registeredDraggedTypes componentsJoinedByString:@","]);

        // ---- 7. 连点 × 只发一次 /api/qdel（旧实现第二次用旧 tag 会删掉顶上来那一首）----
        // 2026-11-18 夜间评审 A1：删除没有在途闸门，两次 performClick 会连发两个 qdel。
        {
            [g_posts removeAllObjects];
            NSButton *delDbl = DelButton(table, 1);
            Ck(delDbl != nil, "7-precondition: 拿得到第 2 行的 ×", @"缺按钮");
            if (delDbl) {
                g_holdQdel = YES;
                [g_heldQdel removeAllObjects];
                [delDbl performClick:nil];
                [delDbl performClick:nil];          // 同一在途窗口内连点（回包还没回来）
                Pump(0.05);
                NSInteger qdelCount = 0;
                for (NSDictionary *p in g_posts) if ([p[@"path"] hasPrefix:@"/api/qdel"]) ++qdelCount;
                Ck(qdelCount == 1,
                   "同一在途窗口内连点 × 只发一次 /api/qdel（否则第二次会删掉顶上来那一首）",
                   [NSString stringWithFormat:@"qdel=%ld held=%lu posts=%@", (long)qdelCount,
                    (unsigned long)g_heldQdel.count, [g_posts componentsJoinedByString:@" | "]]);
                g_holdQdel = NO;
                for (RLPJSONCompletion held in g_heldQdel) held(@{ @"ok": @YES, @"count": @1 });
                [g_heldQdel removeAllObjects];
                Pump(0.05);
            }
        }

        // ---- 8. Q2/Q3/Q4 切歌跟随（selectRow + scrollRowToVisible + 轮询 + 边界空队列/不在队列）----
        {
            NSMutableArray<NSString *> *items15 = [NSMutableArray array];
            NSMutableArray<NSDictionary *> *metas15 = [NSMutableArray array];
            NSMutableArray<NSArray<NSNumber *> *> *cues15 = [NSMutableArray array];
            for (NSInteger i = 0; i < 15; ++i) {
                [items15 addObject:[NSString stringWithFormat:@"/Music/Q/track_%02ld.flac", (long)i]];
                [metas15 addObject:@{ @"t": [NSString stringWithFormat:@"Track %02ld", (long)i],
                                      @"a": @"Artist Q", @"al": @"Album Q", @"d": @(180 + i) }];
                [cues15 addObject:@[ @(-1), @(-1) ]];
            }

            RLPQueueViewController *qvc = [RLPQueueViewController new];
            NSView *qv = qvc.view;
            qv.frame = NSMakeRect(0, 0, 900, 180); // 短视口（~3 行可见），第 12/14 行必在视口外
            [qv layoutSubtreeIfNeeded];

            g_queueOverride = @{ @"ok": @YES, @"index": @0, @"mode": @0,
                                 @"items": items15, @"cues": cues15, @"metas": metas15 };
            g_statusOverride = @{ @"ok": @YES, @"playing": @YES, @"paused": @NO,
                                  @"currentPath": items15[0] };
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [qvc performSelector:NSSelectorFromString(@"reloadData")];
#pragma clang diagnostic pop
            Pump(0.05);
            [qv layoutSubtreeIfNeeded];

            NSTableView *qTable = FindTable(qv);
            NSScrollView *qScroll = qTable.enclosingScrollView;
            Ck(qTable != nil && qScroll != nil && qTable.numberOfRows == 15,
               "Q2-precondition: 15 首队列加载成功",
               [NSString stringWithFormat:@"rows=%ld", (long)(qTable ? qTable.numberOfRows : -1)]);
            Ck(qTable.selectedRow == 0, "Q2-precondition: 初始选中第 0 行",
               [NSString stringWithFormat:@"selectedRow=%ld", (long)qTable.selectedRow]);

            auto verifyOrder = ^BOOL(NSTableView *tbl) {
                if (tbl.numberOfRows != (NSInteger)items15.count) return NO;
                for (NSInteger i = 0; i < (NSInteger)items15.count; ++i) {
                    NSTableCellView *tc = CellAt(tbl, @"q.t", i);
                    if (!tc || ![tc.textField.toolTip isEqualToString:items15[(NSUInteger)i]]) return NO;
                }
                return YES;
            };
            auto isRowVisible = ^BOOL(NSTableView *tbl, NSScrollView *sc, NSInteger row) {
                if (!tbl || !sc || row < 0 || row >= tbl.numberOfRows) return NO;
                NSRect rowR = [tbl rectOfRow:row];
                NSRect visR = sc.documentVisibleRect;
                NSRect inter = NSIntersectionRect(visR, rowR);
                return inter.size.height >= rowR.size.height - 1.0;
            };

            // Q2: 从 0 切到 12（队列 JSON 使用 current=B 且无 index 字段），selectRow=12 且滚入可见区
            g_queueOverride = @{ @"ok": @YES, @"current": items15[12], @"mode": @0,
                                 @"items": items15, @"cues": cues15, @"metas": metas15 };
            g_statusOverride = @{ @"ok": @YES, @"playing": @YES, @"paused": @NO,
                                  @"currentPath": items15[12] };
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPPlaybackStatusNotification"
                                                                object:g_statusOverride];
            Pump(0.05);
            NSString *q2Path = (qTable.selectedRow >= 0 && qTable.selectedRow < qTable.numberOfRows)
                ? CellAt(qTable, @"q.t", qTable.selectedRow).textField.toolTip : nil;
            NSTableCellView *q2Cell12 = CellAt(qTable, @"q.t", 12);
            NSTableCellView *q2Cell0 = CellAt(qTable, @"q.t", 0);
            std::printf("  [INFO] Q2 highlighted index=%ld path=%s\n",
                        (long)qTable.selectedRow, q2Path.UTF8String ?: "(nil)");
            Ck(qTable.selectedRow == 12 &&
               [q2Path isEqualToString:items15[12]] &&
               q2Cell12 && SameColor(q2Cell12.textField.textColor, t.accentText) &&
               q2Cell0 && SameColor(q2Cell0.textField.textColor, t.text) &&
               isRowVisible(qTable, qScroll, 12) &&
               verifyOrder(qTable),
               "Q2 主队列页切到 B 后 selectRow=12、滚入可见且不改队列顺序",
               [NSString stringWithFormat:@"sel=%ld path=%@ vis=%@ row12=%@",
                (long)qTable.selectedRow, q2Path ?: @"nil",
                NSStringFromRect(qScroll.documentVisibleRect),
                NSStringFromRect([qTable rectOfRow:12])]);

            // Q3: 连续切 3 首（cur=2 -> index=14 -> 轮询 current=5）仍跟随
            // 1) cur=2
            g_queueOverride = @{ @"ok": @YES, @"cur": @2, @"mode": @0,
                                 @"items": items15, @"cues": cues15, @"metas": metas15 };
            g_statusOverride = @{ @"ok": @YES, @"playing": @YES, @"paused": @NO,
                                  @"currentPath": items15[2] };
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPPlaybackStatusNotification"
                                                                object:g_statusOverride];
            Pump(0.05);
            NSString *q3aPath = (qTable.selectedRow >= 0 && qTable.selectedRow < qTable.numberOfRows)
                ? CellAt(qTable, @"q.t", qTable.selectedRow).textField.toolTip : nil;
            std::printf("  [INFO] Q3-1 highlighted index=%ld path=%s\n",
                        (long)qTable.selectedRow, q3aPath.UTF8String ?: "(nil)");
            Ck(qTable.selectedRow == 2 && [q3aPath isEqualToString:items15[2]] &&
               isRowVisible(qTable, qScroll, 2) && verifyOrder(qTable),
               "Q3a 连续第 1 次切歌跟随到 index=2",
               [NSString stringWithFormat:@"sel=%ld path=%@", (long)qTable.selectedRow, q3aPath ?: @"nil"]);

            // 2) index=14
            g_queueOverride = @{ @"ok": @YES, @"index": @14, @"mode": @0,
                                 @"items": items15, @"cues": cues15, @"metas": metas15 };
            g_statusOverride = @{ @"ok": @YES, @"playing": @YES, @"paused": @NO,
                                  @"currentPath": items15[14] };
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPPlaybackStatusNotification"
                                                                object:g_statusOverride];
            Pump(0.05);
            NSString *q3bPath = (qTable.selectedRow >= 0 && qTable.selectedRow < qTable.numberOfRows)
                ? CellAt(qTable, @"q.t", qTable.selectedRow).textField.toolTip : nil;
            std::printf("  [INFO] Q3-2 highlighted index=%ld path=%s\n",
                        (long)qTable.selectedRow, q3bPath.UTF8String ?: "(nil)");
            Ck(qTable.selectedRow == 14 && [q3bPath isEqualToString:items15[14]] &&
               isRowVisible(qTable, qScroll, 14) && verifyOrder(qTable),
               "Q3b 连续第 2 次切歌跟随到 index=14",
               [NSString stringWithFormat:@"sel=%ld path=%@", (long)qTable.selectedRow, q3bPath ?: @"nil"]);

            // 3) 轮询定时器自动发现切到 index=5（不发通知，验证 1s poll）
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [qvc performSelector:NSSelectorFromString(@"activate")];
#pragma clang diagnostic pop
            Pump(0.05);
            g_queueOverride = @{ @"ok": @YES, @"current": items15[5], @"mode": @0,
                                 @"items": items15, @"cues": cues15, @"metas": metas15 };
            g_statusOverride = @{ @"ok": @YES, @"playing": @YES, @"paused": @NO,
                                  @"currentPath": items15[5] };
            Pump(1.15);
            NSString *q3cPath = (qTable.selectedRow >= 0 && qTable.selectedRow < qTable.numberOfRows)
                ? CellAt(qTable, @"q.t", qTable.selectedRow).textField.toolTip : nil;
            std::printf("  [INFO] Q3-3 (poll) highlighted index=%ld path=%s\n",
                        (long)qTable.selectedRow, q3cPath.UTF8String ?: "(nil)");
            Ck(qTable.selectedRow == 5 && [q3cPath isEqualToString:items15[5]] &&
               isRowVisible(qTable, qScroll, 5) && verifyOrder(qTable),
               "Q3c 连续第 3 次通过状态轮询自动跟随到 index=5",
               [NSString stringWithFormat:@"sel=%ld path=%@", (long)qTable.selectedRow, q3cPath ?: @"nil"]);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [qvc performSelector:NSSelectorFromString(@"viewDidDisappear")];
#pragma clang diagnostic pop

            // Q4: 当前不在队列 / 索引越界 / 空队列 -> 不崩、不高亮错行
            g_queueOverride = @{ @"ok": @YES, @"current": @"/Music/Q/NotInQueue.flac", @"mode": @0,
                                 @"items": items15, @"cues": cues15, @"metas": metas15 };
            g_statusOverride = @{ @"ok": @YES, @"playing": @YES, @"paused": @NO,
                                  @"currentPath": @"/Music/Q/NotInQueue.flac" };
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPPlaybackStatusNotification"
                                                                object:g_statusOverride];
            Pump(0.05);
            BOOL anyAccentRow = NO;
            for (NSInteger i = 0; i < qTable.numberOfRows; ++i) {
                NSTableCellView *tc = CellAt(qTable, @"q.t", i);
                if (tc && SameColor(tc.textField.textColor, t.accentText)) anyAccentRow = YES;
            }
            Ck(qTable.numberOfRows == 15 && qTable.selectedRow == -1 &&
               qTable.selectedRowIndexes.count == 0 && !anyAccentRow,
               "Q4a 当前曲目不在队列时不崩且不高亮错行（selectedRow=-1）",
               [NSString stringWithFormat:@"rows=%ld sel=%ld accent=%d",
                (long)qTable.numberOfRows, (long)qTable.selectedRow, anyAccentRow]);

            g_queueOverride = @{ @"ok": @YES, @"index": @99, @"mode": @0,
                                 @"items": items15, @"cues": cues15, @"metas": metas15 };
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPQueueChangedNotification object:nil];
            Pump(0.05);
            Ck(qTable.numberOfRows == 15 && qTable.selectedRow == -1,
               "Q4b 队列越界 index=99 时不崩且不选中任何行",
               [NSString stringWithFormat:@"rows=%ld sel=%ld", (long)qTable.numberOfRows, (long)qTable.selectedRow]);

            g_queueOverride = @{ @"ok": @YES, @"current": items15[0], @"mode": @0,
                                 @"items": @[], @"cues": @[], @"metas": @[] };
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPQueueChangedNotification object:nil];
            Pump(0.05);
            Ck(qTable.numberOfRows == 0 && qTable.selectedRow == -1,
               "Q4c 空队列时不崩且无选中行",
               [NSString stringWithFormat:@"rows=%ld sel=%ld", (long)qTable.numberOfRows, (long)qTable.selectedRow]);

            // v2.0.3 Q5: 窄窗(454pt) + 英文环境下顶部工具栏自动折行、不重叠、不裁切；主题切换更新 sortLabel
            qv.frame = NSMakeRect(0, 0, 454, 640);
            [qv layoutSubtreeIfNeeded];
            Pump(0.05);

            NSView *barView = [qvc valueForKey:@"barView"];
            NSTextField *sortLbl = [qvc valueForKey:@"sortLabel"];
            NSPopUpButton *sortPop = [qvc valueForKey:@"sortPopup"];
            NSArray<NSButton *> *actBtns = [qvc valueForKey:@"actionButtons"];
            NSMutableArray<NSView *> *barCtrls = [NSMutableArray array];
            if (sortLbl) [barCtrls addObject:sortLbl];
            if (sortPop) [barCtrls addObject:sortPop];
            for (NSButton *b in actBtns) [barCtrls addObject:b];

            auto barNoOverflowOrOverlap = ^BOOL(NSString **diag) {
                if (!barView || NSWidth(barView.bounds) < 100.0) {
                    if (diag) *diag = @"barView missing";
                    return NO;
                }
                for (NSUInteger i = 0; i < barCtrls.count; ++i) {
                    NSRect a = barCtrls[i].frame;
                    if (NSMinX(a) < -0.5 || NSMaxX(a) > NSWidth(barView.bounds) + 1.0 ||
                        NSMinY(a) < -0.5 || NSMaxY(a) > NSHeight(barView.bounds) + 1.0) {
                        if (diag) *diag = [NSString stringWithFormat:@"outOfBounds[%lu]=%@ bar=%@",
                                           (unsigned long)i, NSStringFromRect(a), NSStringFromRect(barView.bounds)];
                        return NO;
                    }
                    for (NSUInteger j = i + 1; j < barCtrls.count; ++j) {
                        NSRect b = barCtrls[j].frame;
                        if (NSIntersectsRect(a, b)) {
                            if (diag) *diag = [NSString stringWithFormat:@"overlap[%lu,%lu]=%@ vs %@",
                                               (unsigned long)i, (unsigned long)j, NSStringFromRect(a), NSStringFromRect(b)];
                            return NO;
                        }
                    }
                }
                return YES;
            };

            NSString *zhDiag = @"ok";
            BOOL zhBarOk = barNoOverflowOrOverlap(&zhDiag);
            Ck(zhBarOk && NSHeight(barView.bounds) > 30.0,
               "v2.0.3 Q5a 播放队列 454pt 窄窗下工具栏自动折行且不溢出不重叠",
               [NSString stringWithFormat:@"%@ bar=%@", zhDiag, NSStringFromRect(barView.bounds)]);

            RLPSetLanguage(@"en");
            [(id)qvc applyLanguage];
            [qvc.view layoutSubtreeIfNeeded];
            Pump(0.03);
            NSString *enDiag = @"ok";
            BOOL enBarOk = barNoOverflowOrOverlap(&enDiag);
            Ck(enBarOk && NSHeight(barView.bounds) > 30.0,
               "v2.0.3 Q5b 播放队列切英文且 454pt 窄窗下工具栏自动重排不溢出不重叠",
               [NSString stringWithFormat:@"%@ bar=%@", enDiag, NSStringFromRect(barView.bounds)]);

            [RLPTheme setThemeName:@"dark"];
            [(id)qvc applyTheme];
            Ck(SameColor(sortLbl.textColor, [RLPTheme current].mut2) &&
               SameColor(qTable.backgroundColor, [RLPTheme current].bg),
               "v2.0.3 Q5c 播放队列切暗黑主题同步刷新 sortLabel 与表格背景色",
               @"");

            RLPSetLanguage(@"zh");
            [(id)qvc applyLanguage];
            [RLPTheme setThemeName:@"light"];
            [(id)qvc applyTheme];
            qv.frame = NSMakeRect(0, 0, 900, 640);
            [qv layoutSubtreeIfNeeded];

            g_queueOverride = nil;
            g_statusOverride = nil;
        }

        std::printf("结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
