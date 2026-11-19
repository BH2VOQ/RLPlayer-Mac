// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_tracks_rows.mm — 曲目页（tracks）行几何/内容 = web `.trow-track`
//
// ============================ 这条判据在证明什么 ============================
// web 真源：src/net/ui_script.h:3388-3401（行模板）+ src/net/ui_page.h:364-372（CSS）
//   grid-template-columns: 28px 24px minmax(120px,1.6fr) minmax(0,1fr) 92px 58px 26px; gap:8px
//   7 个格子：序号码 / 心形 / 标题 / artist — album（单格）/ 规格 fmtTag(sr,bits) /
//   时长 / 「+」；行内字号 12.5、序号与时长 11.5 右对齐 tabular、艺术家 11.5、规格 9.5 accent。
//   响应式（ui_page.h:229）：≤1400 规格列 0px、标题:艺术家=1.8:1；≤1120 =1:0.9。
//   web 曲目页**没有列头行**。
//
// 旧原生实现（1.1.7.25，HEAD 36ce2fa）：7 列里第 4 列是独立的「专辑」列（180px）、
// 标题 240 / 艺术家 160、rowHeight 28、字号 theme.body 13、没有规格列、列头
// 标题/艺术家/专辑/时长 还在。所以本文件对旧码必须红。
//
// ============================ 铁律②：绝不出声 ============================
// 不启动核心、不碰音频设备、不打开任何可见窗口：RLPCoreClient 用桩（只记录 URL/body，
// 按夹具回 JSON）。视图树离屏构造（与 --audit 的离屏路径同一条）。
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "RLPTracksViewController.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

#include <cstdio>
#include <cmath>

/// 排序入口是生产代码里的动作方法（不在头文件里）；判据按真实下拉动作调用它。
@interface RLPTracksViewController (TracksSortAudit)
- (void)onSortChanged:(NSPopUpButton *)sender;
@end

static int g_fail = 0, g_pass = 0;

static void Ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++g_fail; }
}
static void Geo(const char *what, double want, double got, double tol) {
    const double d = got - want;
    const BOOL ok = std::fabs(d) <= tol;
    if (ok) { std::printf("  [PASS] %-28s want=%7.2f got=%7.2f diff=%+6.2f (tol %.1f)\n",
                          what, want, got, d, tol); ++g_pass; }
    else { std::printf("  [FAIL] %-28s want=%7.2f got=%7.2f diff=%+6.2f (tol %.1f)\n",
                       what, want, got, d, tol); ++g_fail; }
}
static void EqStr(NSString *got, NSString *want, const char *what) {
    Ck([got isEqualToString:want], what,
       [NSString stringWithFormat:@"got=「%@」 want=「%@」", got ?: @"", want ?: @""]);
}

#pragma mark - 桩客户端（不发任何真实请求）

static NSMutableArray<NSDictionary *> *g_posts = nil;
static NSArray<NSDictionary *> *g_fixtureTracks = nil;
static NSArray<NSString *> *g_fixtureFavs = nil;

static NSDictionary *SearchFixture(void) {
    return @{ @"ok": @YES, @"tracks": g_fixtureTracks, @"total": @(g_fixtureTracks.count) };
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RLPCoreClient
+ (instancetype)shared { static RLPCoreClient *c; if (!c) c = [self new]; return c; }
- (BOOL)started { return YES; }
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    id json = @{ @"ok": @NO };
    if ([path hasPrefix:@"/api/lib/search"]) json = SearchFixture();
    else if ([path hasPrefix:@"/api/fav/list"]) json = @{ @"ok": @YES, @"files": g_fixtureFavs ?: @[] };
    else if ([path hasPrefix:@"/api/fav"]) json = @{ @"ok": @YES };
    else if ([path hasPrefix:@"/api/add"]) json = @{ @"ok": @YES };
    else if ([path hasPrefix:@"/api/queue"]) json = @{ @"ok": @YES, @"items": @[], @"index": @0, @"mode": @0 };
    if (done) done(json);
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done { (void)path; if (done) done(nil); }
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    if (!g_posts) g_posts = [NSMutableArray array];
    [g_posts addObject:@{ @"path": path ?: @"", @"body": body ?: @"" }];
    if (done) done(@{ @"ok": @YES });
}
@end
#pragma clang diagnostic pop

#pragma mark - 小工具

static NSView *FindById(NSView *root, NSString *ident) {
    if (!root) return nil;
    if ([root.identifier isEqualToString:ident]) return root;
    for (NSView *s in root.subviews) {
        NSView *r = FindById(s, ident);
        if (r) return r;
    }
    return nil;
}

static NSString *RoleId(NSString *role) { return [@"track." stringByAppendingString:role]; }

static NSTableColumn *ColumnForRole(NSTableView *t, NSString *role) {
    for (NSTableColumn *c in t.tableColumns)
        if ([c.identifier isEqualToString:RoleId(role)]) return c;
    return nil;
}

static double WidthOfRole(NSTableView *t, NSString *role) {
    NSTableColumn *c = ColumnForRole(t, role);
    return c ? (double)c.width : 0.0;
}

static NSFont *FontOf(NSTextField *tf) {
    NSAttributedString *as = tf.attributedStringValue;
    if (as.length) {
        NSFont *f = [as attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
        if (f) return f;
    }
    return tf.font;
}
static NSColor *ColorOf(NSTextField *tf) {
    NSAttributedString *as = tf.attributedStringValue;
    if (as.length) {
        NSColor *c = [as attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL];
        if (c) return c;
    }
    return tf.textColor;
}
static BOOL ColorEq(NSColor *a, NSColor *b, double tol) {
    NSColor *ca = [a colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    NSColor *cb = [b colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!ca || !cb) return NO;
    return std::fabs(ca.redComponent - cb.redComponent) <= tol &&
           std::fabs(ca.greenComponent - cb.greenComponent) <= tol &&
           std::fabs(ca.blueComponent - cb.blueComponent) <= tol &&
           std::fabs(ca.alphaComponent - cb.alphaComponent) <= tol;
}
static double KernOf(NSTextField *tf) {
    NSAttributedString *as = tf.attributedStringValue;
    if (as.length == 0) return 0.0;
    id k = [as attribute:NSKernAttributeName atIndex:0 effectiveRange:NULL];
    return k ? [k doubleValue] : 0.0;
}

/// 把 "/api/fav?file=…&on=1" 拆开，测试只比对真实请求（不猜）。
static NSDictionary *SplitURL(NSString *url) {
    NSURLComponents *c = [NSURLComponents componentsWithString:[@"http://localhost" stringByAppendingString:url ?: @""]];
    NSMutableDictionary *q = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *it in c.queryItems ?: @[]) if (it.name) q[it.name] = it.value ?: @"";
    return @{ @"path": c.path ?: @"", @"query": q };
}
static NSDictionary *SplitBody(NSString *body) {
    NSURLComponents *c = [NSURLComponents componentsWithString:[@"http://localhost/?" stringByAppendingString:body ?: @""]];
    NSMutableDictionary *q = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *it in c.queryItems ?: @[]) if (it.name) q[it.name] = it.value ?: @"";
    return q;
}

static NSArray<NSString *> *FixtureRoles(void) {
    return @[ @"index", @"fav", @"title", @"artistAlbum", @"format", @"duration", @"add" ];
}

static NSArray<NSDictionary *> *FixtureTracks(void) {
    return @[
        @{ @"path": @"/Users/test/Music/Aimer/Album Y/01 - Track One.flac",
           @"title": @"Track One", @"artist": @"Aimer", @"album": @"Album Y",
           @"dur": @225, @"sr": @96000, @"bits": @24, @"ch": @2, @"codec": @"flac",
           @"year": @1999 },   // 后端 /api/lib/search 的 year（rtaweb.cpp:8244）必须进模型
        @{ @"path": @"/Users/test/Music/Aimer/Album Y/02 - Track Two.mp3",
           @"title": @"Track Two", @"artist": @"Aimer", @"album": @"Album Y",
           @"dur": @180, @"sr": @44100, @"bits": @16, @"ch": @2, @"codec": @"mp3",
           @"year": @2005 },
    ];
}

static RLPTracksViewController *NewVC(void) {
    RLPTracksViewController *vc = [RLPTracksViewController new];
    NSView *v = vc.view;                      // loadView → buildContent（离屏）
    v.frame = NSMakeRect(0, 0, 900, 700);
    [v layoutSubtreeIfNeeded];
    [vc activate];                            // 同步桩：数据立刻到位
    [v layoutSubtreeIfNeeded];
    return vc;
}

/// 设整页宽度并触发一次布局 —— 表格宽度 = 页面宽度 - 左右各 24pt。
static void SetPageWidth(RLPTracksViewController *vc, CGFloat pageW) {
    NSView *v = vc.view;
    v.frame = NSMakeRect(0, 0, pageW, 700);
    [v layoutSubtreeIfNeeded];
    [v layoutSubtreeIfNeeded];
}

static NSTableView *TableOf(RLPTracksViewController *vc) {
    id t = [vc valueForKey:@"_tableView"];
    return [t isKindOfClass:[NSTableView class]] ? (NSTableView *)t : nil;
}

static NSTextField *CellText(NSTableView *t, NSString *role, NSInteger row) {
    NSTableColumn *c = ColumnForRole(t, role);
    if (!c) return nil;
    NSInteger col = [t.tableColumns indexOfObject:c];
    NSView *cell = [t viewAtColumn:col row:row makeIfNecessary:YES];
    if (!cell) return nil;
    [cell layoutSubtreeIfNeeded];
    NSView *tf = FindById(cell, RoleId(role));
    if (tf && [tf isKindOfClass:[NSTextField class]]) return (NSTextField *)tf;
    return [cell isKindOfClass:[NSTableCellView class]] ? ((NSTableCellView *)cell).textField : nil;
}

static NSView *CellView(NSTableView *t, NSString *role, NSInteger row) {
    NSTableColumn *c = ColumnForRole(t, role);
    if (!c) return nil;
    NSInteger col = [t.tableColumns indexOfObject:c];
    NSView *cell = [t viewAtColumn:col row:row makeIfNecessary:YES];
    [cell layoutSubtreeIfNeeded];
    return cell;
}

static NSButton *CellButton(NSTableView *t, NSString *role, NSInteger row) {
    NSView *cell = CellView(t, role, row);
    NSView *v = FindById(cell, RoleId(role));
    return [v isKindOfClass:[NSButton class]] ? (NSButton *)v : nil;
}

/// 某一列在 row0 的几何：文本字段相对单元格的左右 inset / 垂直居中。
static void TextInsets(NSTableView *t, NSString *role, NSInteger row, const char *what) {
    NSView *cell = CellView(t, role, row);
    NSTextField *tf = CellText(t, role, row);
    if (!cell || !tf) { Ck(NO, what, @"找不下单元格/文本字段"); return; }
    Geo("inset.left", 10, NSMinX(tf.frame), 2);
    Geo("inset.right", 10, cell.bounds.size.width - NSMaxX(tf.frame), 2);
    Geo("centerY", cell.bounds.size.height / 2,
        NSMinY(tf.frame) + tf.frame.size.height / 2, 2);
}

#pragma mark - 主流程

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app finishLaunching];
        std::printf("=== test_native_tracks_rows（曲目页 = web .trow-track · 离屏几何 · 不出声）===\n");
        std::printf("--- web 基准: ui_script.h:3388-3401 / ui_page.h:364-372(229) ---\n");

        g_fixtureTracks = FixtureTracks();
        // 收藏夹具：第 2 首已收藏 ⟹ 点第 1 行心形必须是 on=1（不是取消）。
        g_fixtureFavs = @[ g_fixtureTracks[1][@"path"] ];

        RLPTracksViewController *vc = NewVC();
        NSTableView *table = TableOf(vc);
        Ck(table != nil, "曲目页有真实表格", @"_tableView 缺失");
        if (!table) { std::printf("结果：FAIL（没有表格，后续无从量起）\n"); return 1; }
        NSArray *rows = [vc valueForKey:@"_tracks"];
        Ck(rows.count == 2, "夹具两首曲目都进表了（判据前提）",
           [NSString stringWithFormat:@"rows=%lu", (unsigned long)rows.count]);

        // ---- 1. 列结构：恰好 7 列，角色齐全，没有独立「专辑」列 ----
        std::printf("--- 列结构（实际 tableColumns）---\n");
        NSMutableArray<NSString *> *ids = [NSMutableArray array];
        for (NSTableColumn *c in table.tableColumns) [ids addObject:c.identifier ?: @"(nil)"];
        std::printf("  columns(7 期望) = %lu: %s\n", (unsigned long)ids.count,
                    [ids componentsJoinedByString:@", "].UTF8String);
        Ck(ids.count == 7, "列数恰好 7（web 7 个格子）",
           [NSString stringWithFormat:@"columns=%lu [%@]", (unsigned long)ids.count,
            [ids componentsJoinedByString:@","]]);
        for (NSString *role in FixtureRoles()) {
            Ck(ColumnForRole(table, role) != nil,
               [[NSString stringWithFormat:@"有列角色 %@", RoleId(role)] UTF8String],
               [NSString stringWithFormat:@"缺少 %@；实际 [%@]", RoleId(role), [ids componentsJoinedByString:@","]]);
        }
        BOOL hasAlbumColumn = NO, hasArtistColumn = NO;
        for (NSString *ident in ids) {
            NSString *low = ident.lowercaseString;
            NSString *withoutArtistAlbum = [low stringByReplacingOccurrencesOfString:@"artistalbum" withString:@""];
            if ([withoutArtistAlbum containsString:@"album"]) hasAlbumColumn = YES;
            if ([low containsString:@"artist"] && ![low containsString:@"artistalbum"]) hasArtistColumn = YES;
        }
        Ck(!hasAlbumColumn, "没有独立「专辑」列（专辑已并入 artist — album 单格）",
           [ids componentsJoinedByString:@","]);
        Ck(!hasArtistColumn, "没有旧 track.artist 列（只有 track.artistAlbum）",
           [ids componentsJoinedByString:@","]);

        // 宽表（表格 1500）：先设宽，规格列才可见 —— 隐藏列 viewAtColumn 返回 nil 是正常的。
        SetPageWidth(vc, 1500 + 48);

        // 范围取第 0 行（真实 cell），不只看列配置。
        for (NSString *role in FixtureRoles()) {
            Ck(CellView(table, role, 0) != nil,
               [NSString stringWithFormat:@"第 0 行有 %@ 单元格", RoleId(role)].UTF8String,
               [NSString stringWithFormat:@"viewAtColumn=%@ 为 nil", RoleId(role)]);
        }

        // ---- 2. 行度量：rowHeight 34、无列头、gap 8 ----
        std::printf("--- 行度量 ---\n");
        Geo("rowHeight", 34, table.rowHeight, 2);
        Geo("intercellSpacing.w", 8, table.intercellSpacing.width, 0.5);
        Ck(table.headerView == nil, "没有列头行（web 曲目页无 thead）",
           [NSString stringWithFormat:@"headerView=%@", NSStringFromClass(table.headerView.class)]);
        Ck(table.numberOfRows == 2, "表格行数 = 2", [NSString stringWithFormat:@"rows=%ld", (long)table.numberOfRows]);

        // ---- 3. 大宽度（表格 1500）：固定列宽 / 行高比 1.6 / 规格可见 ----
        SetPageWidth(vc, 1500 + 48);
        const double w1500 = (double)table.bounds.size.width;
        NSScrollView *scroll = [[vc valueForKey:@"_scrollView"] isKindOfClass:[NSScrollView class]]
                             ? (NSScrollView *)[vc valueForKey:@"_scrollView"] : nil;
        double colSum = 0.0;
        NSInteger visibleCols = 0;
        for (NSTableColumn *c in table.tableColumns) {
            if (c.hidden) continue;
            colSum += c.width; ++visibleCols;
        }
        // NSTableView plain style 给每列尾部留 intercellGap（包括最后一列），
        // 所以表格 frame 比"可视内容"多一个 gap；内容宽 = 列和 + (n-1)*gap。
        const double content1500 = colSum + (double)(visibleCols - 1) * 8.0;
        std::printf("--- 内容宽 %.1f（页面 1548；scroll=%.1f clip=%.1f；列和=%.1f + %ld*gap）固定列宽 ---\n",
                    content1500, scroll ? (double)scroll.frame.size.width : -1.0,
                    scroll ? (double)scroll.contentView.bounds.size.width : -1.0,
                    colSum, (long)(visibleCols - 1));
        {
            NSView *addCell0 = CellView(table, @"add", 0);
            NSTextField *fmtCellTf = CellText(table, @"format", 0);
            NSView *fmtCell0 = CellView(table, @"format", 0);
            std::printf("  [dbg] table.frame=%.1f  addCell=[%.1f,%.1f]  fmtCell=[%.1f,%.1f]  fmtTf=[%.1f,%.1f]\n",
                        (double)table.frame.size.width,
                        addCell0 ? (double)NSMinX(addCell0.frame) : -1.0,
                        addCell0 ? (double)NSMaxX(addCell0.frame) : -1.0,
                        fmtCell0 ? (double)NSMinX(fmtCell0.frame) : -1.0,
                        fmtCell0 ? (double)NSMaxX(fmtCell0.frame) : -1.0,
                        fmtCellTf ? (double)NSMinX(fmtCellTf.frame) : -1.0,
                        fmtCellTf ? (double)NSMaxX(fmtCellTf.frame) : -1.0);
        }
        Geo("content width @1500", 1500, content1500, 2);

        Geo("index.width", 28, WidthOfRole(table, @"index"), 2);
        Geo("fav.width", 24, WidthOfRole(table, @"fav"), 2);
        Geo("format.width", 92, WidthOfRole(table, @"format"), 2);
        Geo("duration.width", 58, WidthOfRole(table, @"duration"), 2);
        Geo("add.width", 26, WidthOfRole(table, @"add"), 2);
        NSTableColumn *fmtCol = ColumnForRole(table, @"format");
        Ck(fmtCol != nil && !fmtCol.hidden && fmtCol.width >= 90,
           "宽表（>1400）规格列可见且宽 92",
           [NSString stringWithFormat:@"hidden=%d width=%.1f", fmtCol ? (int)fmtCol.hidden : -1,
            fmtCol ? (double)fmtCol.width : -1.0]);
        {
            const double tw = WidthOfRole(table, @"title"), aw = WidthOfRole(table, @"artistAlbum");
            Ck(tw > 0 && aw > 0, "标题/艺术家列都量得到", [NSString stringWithFormat:@"title=%.1f artist=%.1f", tw, aw]);
            if (tw > 0 && aw > 0) {
                const double ratio = tw / aw;
                std::printf("  title=%.1f artist=%.1f ratio=%.3f (want 1.600)\n", tw, aw, ratio);
                Geo("title:artist ratio", 1.6, ratio, 0.04);
                // AppKit plain style 在表格尾部额外留一个 gap：表格 frame(1508) 比内容(1500) 多 8。
            // 判据要用**内容宽**（列和 + 可见列间隙），不能用 table.bounds，否则量的是尾部空槽。
            const double sumWant = content1500 - 6 * 8 - (28 + 24 + 92 + 58 + 26);
                Geo("title+artist=remaining", sumWant, tw + aw, 1.5);
            }
        }

        // ---- 4. 内容：artist — album、fmtTag、时长、序号 ----
        std::printf("--- 内容 ---\n");
        NSTextField *artistTf = CellText(table, @"artistAlbum", 0);
        NSTextField *fmtTf = CellText(table, @"format", 0);
        NSTextField *durTf = CellText(table, @"duration", 0);
        NSTextField *idxTf = CellText(table, @"index", 0);
        NSTextField *titleTf = CellText(table, @"title", 0);
        EqStr(artistTf.stringValue, @"Aimer \u2014 Album Y", "艺术家格 = 「Aimer — Album Y」（U+2014 带空格）");
        EqStr(fmtTf.stringValue, @"96k/24", "第 1 行规格 = 96k/24（FLAC 96000/24）");
        EqStr(CellText(table, @"format", 1).stringValue, @"44.1k/16", "第 2 行规格 = 44.1k/16（MP3 44100/16）");
        EqStr(durTf.stringValue, @"3:45", "第 1 行时长 = 3:45");
        EqStr(idxTf.stringValue, @"1", "第 1 行序号 = 1");
        EqStr(titleTf.stringValue, @"Track One", "第 1 行标题");
        Ck([artistTf.toolTip isEqualToString:@"Aimer \u2014 Album Y"],
           "艺术家格 tooltip 与文本同串",
           [NSString stringWithFormat:@"tooltip=「%@」", artistTf.toolTip ?: @""]);
        Ck([CellView(table, @"artistAlbum", 0).toolTip isEqualToString:@"Aimer \u2014 Album Y"],
           "艺术家放在单元格上的 tooltip 同串", @"cell.toolTip 不一致");

        // 字体/颜色/对齐（web ui_page.h:367-371）
        std::printf("--- 字体（web 行 12.5 / 序号·时长 11.5 / 规格 9.5 / 艺术家 11.5）---\n");
        Geo("title.font", 12.5, FontOf(titleTf).pointSize, 0.5);
        Geo("artist.font", 11.5, FontOf(artistTf).pointSize, 0.5);
        Geo("format.font", 9.5, FontOf(fmtTf).pointSize, 0.5);
        Geo("duration.font", 11.5, FontOf(durTf).pointSize, 0.5);
        Geo("index.font", 11.5, FontOf(idxTf).pointSize, 0.5);
        Geo("format.kern", 0.3, KernOf(fmtTf), 0.1);
        Ck(fmtTf.alignment == NSTextAlignmentRight, "规格右对齐", @"alignment 不是 right");
        Ck(durTf.alignment == NSTextAlignmentRight, "时长右对齐", @"alignment 不是 right");
        Ck(idxTf.alignment == NSTextAlignmentRight, "序号右对齐", @"alignment 不是 right");
        RLPTheme *theme = [RLPTheme current];
        Ck(ColorEq(ColorOf(fmtTf), theme.accentText, 0.02), "规格颜色 = --acc-text",
           [NSString stringWithFormat:@"got=%@ want=%@", ColorOf(fmtTf), theme.accentText]);
        Ck(ColorEq(ColorOf(artistTf), theme.mut2, 0.02), "艺术家颜色 = --mut2",
           [NSString stringWithFormat:@"got=%@ want=%@", ColorOf(artistTf), theme.mut2]);
        Ck(ColorEq(ColorOf(durTf), theme.mut2, 0.02), "时长颜色 = --mut2",
           [NSString stringWithFormat:@"got=%@ want=%@", ColorOf(durTf), theme.mut2]);
        Ck(ColorEq(ColorOf(idxTf), theme.mut2, 0.02), "序号颜色 = --mut2",
           [NSString stringWithFormat:@"got=%@ want=%@", ColorOf(idxTf), theme.mut2]);

        // 横向内缩 ~10（web padding 8 20 / margin 0 10 的近似）
        std::printf("--- 单元格横向内缩 ---\n");
        TextInsets(table, @"title", 0, "title.insets");
        TextInsets(table, @"artistAlbum", 0, "artist.insets");
        TextInsets(table, @"duration", 0, "duration.insets");
        TextInsets(table, @"format", 0, "format.insets");
        TextInsets(table, @"index", 0, "index.insets");

        // ---- 5. 心形 / 加号：真实按钮、identifier、请求形状 ----
        std::printf("--- 行内按钮 ---\n");
        NSButton *fav0 = CellButton(table, @"fav", 0);
        NSButton *fav1 = CellButton(table, @"fav", 1);
        NSButton *add0 = CellButton(table, @"add", 0);
        Ck([fav0.identifier isEqualToString:@"track.fav"],
           "心形按钮 identifier = track.fav", fav0.identifier ?: @"nil");
        Ck([add0.identifier isEqualToString:@"track.add"],
           "+ 按钮 identifier = track.add", add0.identifier ?: @"nil");
        Ck(fav0 && add0 && fav0.frame.size.width > 0 && add0.frame.size.width > 0,
           "心形/+ 有真实尺寸", @"零尺寸控件");
        if (fav0 && fav1) {
            Ck(ColorEq(fav1.contentTintColor, theme.accent, 0.02),
               "已收藏行心形 = accent（/api/fav/list 事实源）",
               [NSString stringWithFormat:@"got=%@", fav1.contentTintColor]);
            Ck(!ColorEq(fav0.contentTintColor, theme.accent, 0.02),
               "未收藏行心形不是 accent", [NSString stringWithFormat:@"got=%@", fav0.contentTintColor]);
        }

        // 点第 1 行心形：请求必须是 /api/fav?file=<p1>&on=1
        [g_posts removeAllObjects];
        [fav0 performClick:nil];
        NSDictionary *favPost = g_posts.count ? g_posts.lastObject : nil;
        Ck(favPost != nil && [favPost[@"path"] hasPrefix:@"/api/fav"],
           "点心形发出 /api/fav 请求", favPost[@"path"] ?: @"(无请求)");
        if (favPost) {
            NSDictionary *u = SplitURL(favPost[@"path"]);
            EqStr(u[@"path"], @"/api/fav", "请求路径 = /api/fav");
            EqStr(u[@"query"][@"file"], g_fixtureTracks[0][@"path"], "收藏 file 参数 = 第 1 行路径");
            EqStr(u[@"query"][@"on"], @"1", "收藏 on=1（未收藏 → 收藏）");
        }
        // 点第 1 行「+」：当前实现（与 web addPathCue 同一条后端路径）是 /api/add。
        // 任务书写的是 /api/queue，但 web ui_script.h:4015-4016 与 RLPSupport.mm:354
        // 两边都是 /api/add；这里断言真实契约，不按笔误改行为。
        NSButton *add0b = CellButton(table, @"add", 0);
        [g_posts removeAllObjects];
        [add0b performClick:nil];
        NSDictionary *addPost = g_posts.count ? g_posts.lastObject : nil;
        Ck(addPost != nil && [addPost[@"path"] hasPrefix:@"/api/add"],
           "+ 发出 /api/add（web addPathCue 同契约）", addPost[@"path"] ?: @"(无请求)");
        if (addPost) {
            EqStr(addPost[@"path"], @"/api/add", "入队路径 = /api/add");
            EqStr(SplitBody(addPost[@"body"])[@"file"], g_fixtureTracks[0][@"path"], "入队 file 参数 = 第 1 行路径");
        }

        // ---- 6. 中宽度（表格 1300）：规格列隐藏、1.8:1 ----
        SetPageWidth(vc, 1300 + 48);
        const double w1300 = (double)table.bounds.size.width;
        std::printf("--- 表格宽 %.1f（页面宽 1348）---\n", w1300);
        NSTableColumn *fmt1300 = ColumnForRole(table, @"format");
        Ck(fmt1300 != nil && (fmt1300.hidden || fmt1300.width <= 0.5),
           "≤1400 规格列隐藏（width 0 或 hidden）",
           [NSString stringWithFormat:@"hidden=%d width=%.1f", fmt1300 ? (int)fmt1300.hidden : -1,
            fmt1300 ? (double)fmt1300.width : -1.0]);
        {
            const double tw = WidthOfRole(table, @"title"), aw = WidthOfRole(table, @"artistAlbum");
            const double ratio = aw > 0 ? tw / aw : 0;
            std::printf("  title=%.1f artist=%.1f ratio=%.3f (want 1.800)\n", tw, aw, ratio);
            Geo("title:artist ratio 1300", 1.8, ratio, 0.04);
            double colSum1300 = 0.0; NSInteger vis1300 = 0;
            for (NSTableColumn *c in table.tableColumns) { if (c.hidden) continue; colSum1300 += c.width; ++vis1300; }
            const double content1300 = colSum1300 + (double)(vis1300 - 1) * 8.0;
            const double sumWant = content1300 - 5 * 8 - (28 + 24 + 58 + 26);
            Geo("title+artist=remaining", sumWant, tw + aw, 1.5);
        }
        Geo("add.width@1300", 26, WidthOfRole(table, @"add"), 2);
        Ck(table.headerView == nil, "调整宽度后仍无列头", @"headerView 回来了");

        // ---- 7. 窄宽度（表格 1100）：1:0.9、title ≥120、+ 永不消失 ----
        SetPageWidth(vc, 1100 + 48);
        const double w1100 = (double)table.bounds.size.width;
        std::printf("--- 表格宽 %.1f（页面宽 1148）---\n", w1100);
        {
            const double tw = WidthOfRole(table, @"title"), aw = WidthOfRole(table, @"artistAlbum");
            const double ratio = aw > 0 ? tw / aw : 0;
            std::printf("  title=%.1f artist=%.1f ratio=%.3f (want %.3f)\n", tw, aw, ratio, 1.0 / 0.9);
            Geo("title:artist ratio 1100", 1.0 / 0.9, ratio, 0.04);
            Ck(tw >= 120, "窄表标题列 ≥120（不压成 0）", [NSString stringWithFormat:@"title=%.1f", tw]);
        }
        Ck(WidthOfRole(table, @"add") >= 24,
           "窄表 + 列始终保留（≥26 的宽度）",
           [NSString stringWithFormat:@"add=%.1f", WidthOfRole(table, @"add")]);
        NSTableColumn *fmt1100 = ColumnForRole(table, @"format");
        Ck(fmt1100 != nil && (fmt1100.hidden || fmt1100.width <= 0.5),
           "≤1120 规格列仍隐藏", [NSString stringWithFormat:@"hidden=%d", fmt1100 ? (int)fmt1100.hidden : -1]);

        // ---- 8. 放大回去：响应式不是一次性（规格列要回来） ----
        SetPageWidth(vc, 1500 + 48);
        fmtCol = ColumnForRole(table, @"format");
        Ck(fmtCol != nil && !fmtCol.hidden && fmtCol.width >= 90,
           "从 1100 放大回 1500 后规格列恢复",
           [NSString stringWithFormat:@"hidden=%d width=%.1f", fmtCol ? (int)fmtCol.hidden : -1,
            fmtCol ? (double)fmtCol.width : -1.0]);

        // ---- 9. 既有功能不回退：搜索 / 排序 7 档 / 加载更多 / 悬停 ----
        std::printf("--- 既有功能 ---\n");
        id searchObj = [vc valueForKey:@"_searchField"];
        NSSearchField *search = [searchObj isKindOfClass:[NSSearchField class]] ? (NSSearchField *)searchObj : nil;
        Ck(search != nil, "页面内搜索框仍在", @"NSSearchField 缺失");
        NSPopUpButton *sort = (NSPopUpButton *)FindById(vc.view, @"tracks.sort");
        Ck(sort != nil, "排序下拉仍在", @"tracks.sort 缺失");
        if (sort) {
            Ck(sort.numberOfItems == 7, "排序下拉恰好 7 档（web track-sort）",
               [NSString stringWithFormat:@"items=%ld", (long)sort.numberOfItems]);
            NSArray *want = @[ @"default", @"title", @"artist", @"album", @"dur", @"year", @"fav" ];
            for (NSInteger i = 0; i < MIN((NSInteger)want.count, sort.numberOfItems); ++i) {
                id rep = sort.itemArray[(NSUInteger)i].representedObject;
                Ck([rep isEqual:want[(NSUInteger)i]], "排序档 representedObject 顺序",
                   [NSString stringWithFormat:@"i=%ld got=%@ want=%@", (long)i, rep ?: @"nil", want[(NSUInteger)i]]);
            }
        }
        // 加载更多在 2/2 时应该收起
        id moreObj = [vc valueForKey:@"_loadMoreButton"];
        NSButton *more = [moreObj isKindOfClass:[NSButton class]] ? (NSButton *)moreObj : nil;
        Ck(more == nil || more.hidden, "未截断时不显示「加载更多」",
           [NSString stringWithFormat:@"hidden=%d", more ? (int)more.hidden : -1]);

        // 行悬停：自定义 row view + web --hov
        NSTableRowView *rv = [table rowViewAtRow:0 makeIfNecessary:YES];
        Ck([rv isKindOfClass:[RLPHoverRowView class]], "行视图仍是 RLPHoverRowView（可悬停）",
           NSStringFromClass(rv.class));
        if ([rv isKindOfClass:[RLPHoverRowView class]]) {
            Ck(ColorEq(((RLPHoverRowView *)rv).hoverColor, theme.hov, 0.02),
               "悬停底色 = web --hov（未改动）",
               [NSString stringWithFormat:@"got=%@", ((RLPHoverRowView *)rv).hoverColor]);
        }

        // ---- 10. 空字段不吐悬空破折号 ----
        // 只改数据、不碰生产接口：给第 2 行喂一条 artist 空、album 空以外的边界。
        {
            NSMutableArray *edge = [NSMutableArray array];
            [edge addObject:@{ @"path": @"/edge/only-artist.flac", @"title": @"Only Artist",
                               @"artist": @"Solo", @"album": @"", @"dur": @1, @"sr": @48000, @"bits": @16 }];
            [edge addObject:@{ @"path": @"/edge/only-album.flac", @"title": @"Only Album",
                               @"artist": @"", @"album": @"Alb", @"dur": @1, @"sr": @48000, @"bits": @16 }];
            [edge addObject:@{ @"path": @"/edge/neither.flac", @"title": @"Neither",
                               @"artist": @"", @"album": @"", @"dur": @1, @"sr": @0, @"bits": @0 }];
            g_fixtureTracks = edge;
            [vc reloadData];
            [vc.view layoutSubtreeIfNeeded];
            Ck(table.numberOfRows == 3, "边界夹具 3 行进表", [NSString stringWithFormat:@"rows=%ld", (long)table.numberOfRows]);
            EqStr(CellText(table, @"artistAlbum", 0).stringValue, @"Solo",
                  "只有艺术家时不吐悬空「—」");
            EqStr(CellText(table, @"artistAlbum", 1).stringValue, @"Alb",
                  "只有专辑时不吐悬空「—」");
            Ck(CellText(table, @"artistAlbum", 2).stringValue.length == 0,
               "两项都空时艺术家格为空（不是「 — 」）",
               [NSString stringWithFormat:@"got=「%@」", CellText(table, @"artistAlbum", 2).stringValue]);
            Ck(CellText(table, @"format", 2).stringValue.length == 0,
               "sr 为空时规格格为空",
               [NSString stringWithFormat:@"got=「%@」", CellText(table, @"format", 2).stringValue]);
            // 恢复夹具，避免后续状态污染（本进程只跑一遍，仍做干净收尾）。
            g_fixtureTracks = FixtureTracks();
        }

        // ---- 11. 排序：年份降序（P4）与默认可逆（P5）----
        // web 真源：ui_script.h:3352-3363
        //   var sorted = ...（每次从 S.trackRows 原始序派生）；year 比较器 (b.year||0)-(a.year||0) 降序；
        //   default 显示原始 trackRows（所以点过别的档再回默认必须回到原序）。
        // 旧码（RLPTracksViewController.mm:770-794）：就地覆盖 _tracks、default 直接 return、
        //   year 分支固定 NSOrderedSame（注释还写着"曲目没有 year 字段"，与后端事实不符）。
        {
            g_fixtureTracks = FixtureTracks();
            [vc reloadData];
            [vc.view layoutSubtreeIfNeeded];
            NSPopUpButton *sort11 = (NSPopUpButton *)FindById(vc.view, @"tracks.sort");
            Ck(sort11 != nil, "排序下拉存在（P4/P5 判据前提）", @"tracks.sort 缺失");
            if (sort11) {
                // P4：年份降序。夹具 Track One=1999 / Track Two=2005 ⟹ 原序 One,Two，排序后 Two 在前。
                [sort11 selectItemAtIndex:5];   // default/title/artist/album/dur/year
                [vc onSortChanged:sort11];
                [vc.view layoutSubtreeIfNeeded];
                EqStr(CellText(table, @"title", 0).stringValue, @"Track Two",
                      "P4 年份排序真的排：2005 的曲目排第一（降序，与 web 同向）");
                EqStr(CellText(table, @"title", 1).stringValue, @"Track One",
                      "P4 年份排序：1999 的曲目排第二");

                // P5：先排"收藏优先"（夹具第 2 首已收藏 ⟹ Two 在前），再切回默认必须回到原始顺序。
                [sort11 selectItemAtIndex:6];   // fav
                [vc onSortChanged:sort11];
                EqStr(CellText(table, @"title", 0).stringValue, @"Track Two",
                      "P5 收藏优先排序生效（已收藏的 Track Two 在前）");

                [sort11 selectItemAtIndex:0];   // default
                [vc onSortChanged:sort11];
                [vc.view layoutSubtreeIfNeeded];
                EqStr(CellText(table, @"title", 0).stringValue, @"Track One",
                      "P5 默认排序可逆：切回默认后回到接口原始顺序（保留 _rawTracks）");
                EqStr(CellText(table, @"title", 1).stringValue, @"Track Two",
                      "P5 默认排序可逆：第 2 行也回到原始顺序");
            }
        }

        std::printf("结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
