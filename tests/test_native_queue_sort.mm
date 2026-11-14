// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_queue_sort.mm — 播放队列页排序 = web #qSort（8 档 + CUE 区间保真）
//
// ============================ 这条判据在证明什么 ============================
// web 真源：
//   ui_script.h:12564-12574  排序下拉恰好 8 档，顺序/值：
//                            默认顺序 / 标题 / 艺术家 / 专辑 / 时长 / 年份 / 随机打乱 / 反转顺序
//                            （default/title/artist/album/dur/year/shuffle/reverse）
//   ui_script.h:12496-12540  applyQueueSort：default → POST /api/qsort?by=default；
//                            其余先 GET /api/queue?meta=1（metas t/a/al/d/y + cues），
//                            本地排索引，再 POST /api/qorder，body = files=<多行 queueItemLine>；
//                            queueItemLine = path + `\t<cs>\t<ce>`（cues[i][0] >= 0 时）。
//                            排序语义：title/artist/album 文本升序；dur 升序；year **降序**；
//                            shuffle = Fisher-Yates；reverse = 反转。
//   ui_script.h:12555-12556 按钮：保存为歌单 / 清空队列；排序标签「排序：」。
//   row click → playPath(items[i], cues[i][0], cues[i][1])（CUE 分轨必须带区间）。
//
// 旧原生（1.1.7.27）：下拉只有 3 档（默认/标题/艺术家）；qorder 只发路径、丢 cue；
// playRow 走 RLPPlayPath 丢 cue；按钮叫「存为歌单 / 清空」。所以本文件对旧码必须红。
//
// ============================ 铁律②：绝不出声 ============================
// 桩 RLPCoreClient：只记录 GET/POST 与 body，不启动核心、不碰音频设备、不创建可见窗口。
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "RLPQueueViewController.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

// 生产接缝（实现在 RLPQueueViewController.mm）：导入 M3U 到队列，不弹系统文件面板。
@interface RLPQueueViewController (RLPM3UImportSeam)
- (void)importM3UAtPath:(NSString *)path playing:(BOOL)playing;
@end

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

#pragma mark - 桩客户端（只记录，不发任何请求）

static NSMutableArray<NSDictionary *> *g_gets;    // @{path}
static NSMutableArray<NSDictionary *> *g_posts;   // @{path, body}

static NSArray<NSString *> *PathsFixture(void) {
    return @[ @"/Music/A/One.flac", @"/Music/B/Two.flac",
              @"/Music/C/Three.flac", @"/Music/D/Four.flac" ];
}
static NSArray<NSDictionary *> *MetasFixture(void) {
    return @[ @{ @"t": @"Zulu",  @"a": @"B", @"al": @"Alb2", @"d": @100, @"y": @2001 },
              @{ @"t": @"Alpha", @"a": @"C", @"al": @"Alb3", @"d": @50,  @"y": @2005 },
              @{ @"t": @"Mike",  @"a": @"A", @"al": @"Alb1", @"d": @300, @"y": @1999 },
              @{ @"t": @"Bravo", @"a": @"D", @"al": @"Alb4", @"d": @20,  @"y": @2010 } ];
}
/// 第 2/4 项是 CUE 分轨：[10,20] / [30,40]；第 1/3 项是整轨 [-1,-1]。
static NSArray<NSArray<NSNumber *> *> *CuesFixture(void) {
    return @[ @[ @(-1), @(-1) ], @[ @(10), @(20) ],
              @[ @(-1), @(-1) ], @[ @(30), @(40) ] ];
}
static NSDictionary *QueuePayload(void) {
    return @{ @"ok": @YES, @"index": @0, @"mode": @0,
              @"items": PathsFixture(), @"cues": CuesFixture(), @"metas": MetasFixture() };
}

#pragma mark clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RLPCoreClient
+ (instancetype)shared { static RLPCoreClient *c; if (!c) c = [self new]; return c; }
- (BOOL)started { return YES; }
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    if (!done) return;
    [g_gets addObject:@{ @"path": path ?: @"" }];
    if ([path hasPrefix:@"/api/queue?meta=1"]) { done(QueuePayload()); return; }
    if ([path hasPrefix:@"/api/sq/list"]) { done(@{ @"ok": @YES, @"queues": @[] }); return; }
    done(@{ @"ok": @NO });
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done { (void)path; if (done) done(nil); }
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    [g_posts addObject:@{ @"path": path ?: @"", @"body": body ?: @"" }];
    if (done) done(@{ @"ok": @YES });
}
@end
#pragma mark clang diagnostic pop

#pragma mark - 工具

static void CollectAll(NSView *v, NSMutableArray<NSView *> *out) {
    if (!v) return;
    [out addObject:v];
    for (NSView *s in v.subviews) CollectAll(s, out);
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
static void Pump(double seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
static NSString *URLDecodeBody(NSString *body) {
    return [body stringByRemovingPercentEncoding] ?: body;
}
static NSArray<NSString *> *DecodedLines(NSString *body) {
    NSString *prefix = @"files=";
    if (![body hasPrefix:prefix]) return @[];
    NSString *v = URLDecodeBody([body substringFromIndex:prefix.length]);
    NSArray *lines = [v componentsSeparatedByString:@"\n"];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *l in lines) if (l.length) [out addObject:l];
    return out;
}
/// 行的“项”部分（去掉 \tcs\tce 尾巴），用于比较顺序。
static NSArray<NSString *> *LinePaths(NSArray<NSString *> *lines) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *l in lines) [out addObject:[l componentsSeparatedByString:@"\t"][0]];
    return out;
}
static NSDictionary *LastPostFor(NSString *path) {
    NSDictionary *hit = nil;
    for (NSDictionary *p in g_posts) if ([p[@"path"] isEqualToString:path]) hit = p;
    return hit;
}
#pragma mark - 测试

@interface RLPQueueViewController (QueueSortTest)
- (void)reloadData;
- (void)sortBy:(NSString *)key;
- (void)playRow:(NSInteger)row;
- (NSTableView *)table;
@end

static RLPQueueViewController *NewVC(void) {
    RLPQueueViewController *vc = [RLPQueueViewController new];
    NSView *v = vc.view;
    v.frame = NSMakeRect(0, 0, 1200, 800);
    [v layoutSubtreeIfNeeded];
    [vc reloadData];
    Pump(0.05);
    [v layoutSubtreeIfNeeded];
    return vc;
}

static void CheckSort(RLPQueueViewController *vc, NSString *key, NSArray<NSString *> *wantPaths,
                      NSDictionary<NSNumber *, NSString *> *cueLines) {
    [g_posts removeAllObjects];
    [g_gets removeAllObjects];
    [vc sortBy:key];
    Pump(0.05);
    NSDictionary *post = LastPostFor(@"/api/qorder");
    Ck(post != nil, [[NSString stringWithFormat:@"排序 %@ 走 /api/qorder（web applyQueueSort）", key] UTF8String],
       @"没有 qorder 请求");
    NSArray<NSString *> *lines = post ? DecodedLines(post[@"body"]) : @[];
    NSArray<NSString *> *paths = LinePaths(lines);
    Ck([paths isEqualToArray:wantPaths],
       [[NSString stringWithFormat:@"排序 %@ 的顺序 = web", key] UTF8String],
       [NSString stringWithFormat:@"got=%@ want=%@ body=%@", paths, wantPaths, post[@"body"] ?: @""]);
    for (NSNumber *pos in cueLines) {
        NSString *want = cueLines[pos];
        NSString *got = (pos.integerValue >= 0 && pos.integerValue < (NSInteger)lines.count)
            ? lines[(NSUInteger)pos.integerValue] : @"(缺行)";
        Ck([got isEqualToString:want],
           [[NSString stringWithFormat:@"%@：第 %ld 行保留 \\tcs\\tce", key, (long)(pos.integerValue + 1)] UTF8String],
           [NSString stringWithFormat:@"got=%@ want=%@", got, want]);
    }
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        g_gets = [NSMutableArray array];
        g_posts = [NSMutableArray array];
        [RLPTheme setThemeName:@"light"];
        [RLPTheme setUiStyle:@"apple"];
        std::printf("=== test_native_queue_sort（#qSort 8 档 + CUE 保真 · 离屏 · 不出声）===\n");

        RLPQueueViewController *vc = NewVC();
        NSPopUpButton *sort = (NSPopUpButton *)FindById(vc.view, @"queue.sort");
        Ck(sort != nil, "找得到排序下拉 queue.sort", @"下拉缺失");
        if (!sort) { std::printf("结果：%d passed, %d failed\n", g_pass, g_fail); return 1; }

        // ---- 1. 8 档的顺序、标题、representedObject ----
        Ck(sort.numberOfItems == 8, "排序下拉恰好 8 档（web #qSort）",
           [NSString stringWithFormat:@"items=%ld", (long)sort.numberOfItems]);
        NSArray<NSArray<NSString *> *> *spec = @[
            @[ @"default", RLPTr(@"默认顺序") ], @[ @"title", RLPTr(@"标题") ],
            @[ @"artist", RLPTr(@"艺术家") ], @[ @"album", RLPTr(@"专辑") ],
            @[ @"dur", RLPTr(@"时长") ], @[ @"year", RLPTr(@"年份") ],
            @[ @"shuffle", RLPTr(@"随机打乱") ], @[ @"reverse", RLPTr(@"反转顺序") ] ];
        for (NSInteger i = 0; i < MIN((NSInteger)spec.count, sort.numberOfItems); ++i) {
            EqStr([sort itemTitleAtIndex:i], spec[(NSUInteger)i][1],
                  "排序档标题与 web 同序");
            NSMenuItem *it = sort.itemArray[(NSUInteger)i];
            EqStr([it.representedObject isKindOfClass:[NSString class]] ? it.representedObject : @"",
                  spec[(NSUInteger)i][0], "排序档 representedObject 与 web 同序");
        }

        // ---- 2. 按钮与标签 ----
        NSButton *save = (NSButton *)FindById(vc.view, @"save");
        NSButton *clear = (NSButton *)FindById(vc.view, @"clear");
        Ck(save && clear, "找得到 保存/清空 按钮（identifier 不变）", @"按钮缺失");
        if (save) EqStr(save.title, RLPTr(@"保存为歌单"), "按钮文案 = 保存为歌单（web）");
        if (clear) EqStr(clear.title, RLPTr(@"清空队列"), "按钮文案 = 清空队列（web）");
        BOOL sawSortLabel = NO;
        NSMutableArray<NSView *> *all = [NSMutableArray array];
        NSMutableArray *stack = [NSMutableArray arrayWithObject:vc.view];
        while (stack.count) {
            NSView *x = stack.lastObject; [stack removeLastObject]; [all addObject:x];
            [stack addObjectsFromArray:x.subviews];
        }
        for (NSView *x in all)
            if ([x isKindOfClass:[NSTextField class]] &&
                [((NSTextField *)x).stringValue isEqualToString:RLPTr(@"排序：")]) sawSortLabel = YES;
        Ck(sawSortLabel, "排序标签 = 「排序：」（web 同文案）", @"没找到「排序：」");

        // ---- 3. 排序语义与 qorder 行（含 CUE）----
        NSString *cue2 = @"/Music/B/Two.flac\t10.000\t20.000";
        NSString *cue4 = @"/Music/D/Four.flac\t30.000\t40.000";
        CheckSort(vc, @"title",
                  @[ @"/Music/B/Two.flac", @"/Music/D/Four.flac",
                     @"/Music/C/Three.flac", @"/Music/A/One.flac" ],
                  @{ @0: cue2, @1: cue4 });
        CheckSort(vc, @"artist",
                  @[ @"/Music/C/Three.flac", @"/Music/A/One.flac",
                     @"/Music/B/Two.flac", @"/Music/D/Four.flac" ],
                  @{ @2: cue2, @3: cue4 });
        CheckSort(vc, @"album",
                  @[ @"/Music/C/Three.flac", @"/Music/A/One.flac",
                     @"/Music/B/Two.flac", @"/Music/D/Four.flac" ],
                  @{ @2: cue2, @3: cue4 });
        CheckSort(vc, @"dur",
                  @[ @"/Music/D/Four.flac", @"/Music/B/Two.flac",
                     @"/Music/A/One.flac", @"/Music/C/Three.flac" ],
                  @{ @0: cue4, @1: cue2 });
        CheckSort(vc, @"year",
                  @[ @"/Music/D/Four.flac", @"/Music/B/Two.flac",
                     @"/Music/A/One.flac", @"/Music/C/Three.flac" ],
                  @{ @0: cue4, @1: cue2 });
        // reverse：p4/p3/p2/p1；第 1 行 p4 带 cue，第 3 行 p2 带 cue。
        CheckSort(vc, @"reverse",
                  @[ @"/Music/D/Four.flac", @"/Music/C/Three.flac",
                     @"/Music/B/Two.flac", @"/Music/A/One.flac" ],
                  @{ @0: cue4, @2: cue2 });

        // shuffle：同一批路径、无重复；顺序不保证（不写随机断言）。
        [g_posts removeAllObjects];
        [vc sortBy:@"shuffle"];
        Pump(0.05);
        NSDictionary *spost = LastPostFor(@"/api/qorder");
        NSArray<NSString *> *slines = spost ? DecodedLines(spost[@"body"]) : @[];
        NSArray<NSString *> *spaths = LinePaths(slines);
        NSSet *set = [NSSet setWithArray:spaths];
        Ck(set.count == 4 && spaths.count == 4, "shuffle：4 条不重复（Fisher-Yates 合法排列）",
           [NSString stringWithFormat:@"paths=%@", spaths]);
        BOOL cueStill = NO;
        for (NSString *l in slines) if ([l hasSuffix:@"\t10.000\t20.000"]) cueStill = YES;
        Ck(cueStill, "shuffle：CUE 区间仍随行保留", [slines componentsJoinedByString:@" | "]);

        // default：POST /api/qsort?by=default（不是 qorder）
        [g_posts removeAllObjects];
        [vc sortBy:@"default"];
        Pump(0.05);
        Ck([g_posts containsObject:@{ @"path": @"/api/qsort?by=default", @"body": @"" }] ||
           LastPostFor(@"/api/qsort?by=default") != nil,
           "default 走 /api/qsort?by=default（web applyQueueSort）",
           [g_posts componentsJoinedByString:@" | "]);

        // ---- 4. 行点击播放：CUE 分轨带 cs/ce ----
        [g_posts removeAllObjects];
        [vc playRow:1];
        NSDictionary *play2 = LastPostFor(@"/api/play");
        Ck(play2 != nil, "点 CUE 行发出 /api/play", @"无 /api/play");
        if (play2) {
            NSString *body2 = URLDecodeBody(play2[@"body"]);
            Ck([body2 containsString:@"cs=10.000"] && [body2 containsString:@"ce=20.000"],
               "CUE 行播放 body 带 cs=10.000 & ce=20.000（web playPath(file,cs,ce)）", body2);
            Ck([body2 containsString:@"file=/Music/B/Two.flac"], "CUE 行播放 file = 第 2 项路径", body2);
        }
        [g_posts removeAllObjects];
        [vc playRow:0];
        NSDictionary *play1 = LastPostFor(@"/api/play");
        if (play1) {
            NSString *body1 = URLDecodeBody(play1[@"body"]);
            Ck(![body1 containsString:@"cs="] && ![body1 containsString:@"ce="],
               "整轨行播放不带 cs/ce（不编造区间）", body1);
        }

        // ---- 5. 既有行内入口/拖拽不回退 ----
        NSTableView *table = (NSTableView *)FindById(vc.view, @"queue.table") ?: nil;
        if (!table) {
            // 生产码没有给 table 配 identifier；按类在视图树里找第一个 NSTableView 兜底。
            for (NSView *x in all) if ([x isKindOfClass:[NSTableView class]]) { table = (NSTableView *)x; break; }
        }
        Ck(table != nil, "找得到队列表格", @"表格缺失");
        if (table) {
            Ck([table.registeredDraggedTypes containsObject:@"RLPQueueRowDrag"],
               "拖拽排序的 pasteboard 类型仍注册（/api/qmove 路径未回退）",
               [table.registeredDraggedTypes componentsJoinedByString:@","]);
            // 行视图是 AppKit 懒创建的：离屏时 viewAtColumn 不一定会被调用，
            // 直接扫视图树会随布局时机时红时绿（实测同树两次运行结果不同）。
            // 先强制物化第 0 行的第 3 列（行尾 × 所在列），再扫描 ⟹ 判据确定性。
            [table reloadData];
            [table layoutSubtreeIfNeeded];
            (void)[table viewAtColumn:3 row:0 makeIfNecessary:YES];
            [table layoutSubtreeIfNeeded];
            Pump(0.1);
            all = [NSMutableArray array];
            CollectAll(vc.view, all);
            NSButton *del = nil;
            for (NSView *x in all) if ([x isKindOfClass:[NSButton class]] && [x.identifier isEqualToString:@"q.del"]) del = (NSButton *)x;
            Ck(del != nil, "行尾 × 按钮仍存在（q.del）", @"找不到 q.del");
        }

        // ---- v3.3.11 qImportM3u：队列页导入按钮与 /api/queue/set 下发 ----
        {
            NSError *err = nil;
            NSString *m3uPath = [@"/tmp" stringByAppendingPathComponent:
                                 [NSString stringWithFormat:@"rlp-q-import-%d.m3u", (int)getpid()]];
            NSString *m3u = @"#EXTM3U\r\n/Music/A/One.flac\r\n/Music/B/Two.flac\r\n";
            Ck([m3u writeToFile:m3uPath atomically:YES encoding:NSUTF8StringEncoding error:&err],
               "Q0 夹具 .m3u 已写入", err.localizedDescription);
            RLPQueueViewController *q = [RLPQueueViewController new];
            NSView *qv = q.view;
            NSButton *imp = (NSButton *)FindById(qv, @"qImportM3u");
            Ck(imp != nil && [imp isKindOfClass:[NSButton class]],
               "Q1 队列页有 qImportM3u 导入按钮", imp ? @"found" : @"nil");
            Ck(imp.target != nil && imp.action != NULL, "Q2 按钮有真实 target/action", @"");
            // 生产接缝：不允许真弹系统文件面板（离屏判据），路由到夹具路径。
            BOOL hasSeam = [q respondsToSelector:@selector(importM3UAtPath:playing:)];
            Ck(hasSeam, "Q2b 生产接缝 importM3UAtPath:playing: 存在", @"");
            NSInteger before = (NSInteger)g_posts.count;
            if (hasSeam) [q importM3UAtPath:m3uPath playing:NO];
            Pump(0.3);
            NSString *setPath = nil, *setBody = nil;
            for (NSDictionary *p in [g_posts copy]) {
                if ([p[@"path"] hasPrefix:@"/api/queue/set"]) { setPath = p[@"path"]; setBody = p[@"body"]; }
            }
            Ck(setPath != nil, "Q3 导入真发 /api/queue/set", setPath ?: @"(none)");
            NSString *decoded = URLDecodeBody(setBody ?: @"");
            Ck([decoded containsString:@"/Music/A/One.flac"] && [decoded containsString:@"/Music/B/Two.flac"],
               "Q4 下发体含歌单两首路径", decoded);
            Ck([decoded containsString:@"require_stopped=1"],
               "Q5 下发体带 require_stopped=1（与 web 同契约）", decoded);
            Ck((NSInteger)g_posts.count > before, "Q6 POST 真的追加了请求", @"");
            // 播放中必须拒绝替换队列
            NSInteger afterPlay = (NSInteger)g_posts.count;
            if (hasSeam) [q importM3UAtPath:m3uPath playing:YES];
            Pump(0.2);
            Ck((NSInteger)g_posts.count == afterPlay,
               "Q7 播放中导入被拒绝（不替换队列）", @"");
            // 过大歌单闸门
            NSString *bigPath = [@"/tmp" stringByAppendingPathComponent:
                                 [NSString stringWithFormat:@"rlp-q-big-%d.m3u", (int)getpid()]];
            // 每行 ~100 字节 × 200000 行 ≈ 20 MB > 16 MiB（旧夹具 7.6 MB 到不了闸门，判据假红）
            NSString *longDir = @"/Music/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/";
            NSMutableString *big = [NSMutableString stringWithString:@"#EXTM3U\r\n"];
            for (NSUInteger i = 0; i < 220000; ++i) [big appendString:longDir];   // ~17.6 MB > 16 MiB
            [big appendString:@"One.flac\r\n"];
            [big writeToFile:bigPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSInteger afterBig = (NSInteger)g_posts.count;
            if (hasSeam) [q importM3UAtPath:bigPath playing:NO];
            Pump(0.2);
            Ck((NSInteger)g_posts.count == afterBig, "Q8 过大歌单被拒绝（16 MiB 闸门）", @"");
            [[NSFileManager defaultManager] removeItemAtPath:m3uPath error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:bigPath error:nil];
        }

        // ---- v3.3.11 parseTransportM3u（POSIX 适配）判据 ----
        {
            NSDictionary *p = RLPParseM3U(@"\uFEFF#EXTM3U\r\n/Music/A.flac\r\n# note\r\nsub/B.flac\r\n", @"/List");
            NSArray *items = p[@"items"];
            Ck(items.count == 2, "U1 M3U BOM/CRLF/注释解析出 2 首",
               [NSString stringWithFormat:@"got %lu", (unsigned long)items.count]);
            EqStr(items.count > 0 ? items[0] : nil, @"/Music/A.flac", "U2 M3U 绝对路径原样");
            EqStr(items.count > 1 ? items[1] : nil, @"/List/sub/B.flac", "U3 M3U 相对路径按文件夹拼接");
            Ck(p != nil && [p[@"needsFolder"] boolValue] == NO, "U4 有文件夹时不需要追问", @"");
            NSDictionary *p2 = RLPParseM3U(@"#EXTM3U\nrel/C.flac\n", nil);
            Ck(p2 != nil && [p2[@"needsFolder"] boolValue] == YES, "U5 相对路径无文件夹时标记 needsFolder", @"");
            NSDictionary *p3 = RLPParseM3U(@"#RTA-CUE 10 20\n/Music/C.flac\n", @"/List");
            EqStr([p3[@"items"] firstObject], @"/Music/C.flac\t10\t20", "U6 CUE 区间附加到下一首");
            Ck(RLPParseM3U(@"#EXT-X-STREAM-INF\nx\n", nil) == nil, "U7 HLS 歌单被拒绝", @"");
            Ck(RLPParseM3U(@"#RTA-CUE 1 2\n", nil) == nil, "U8 孤立 CUE 被拒绝", @"");
            Ck(RLPParseM3U(@"#EXTM3U\n", nil) == nil, "U9 空歌单被拒绝", @"");
            Ck(RLPParseM3U(@"/Music/A.flac\n\u0001bad\n", nil) == nil, "U10 控制字符被拒绝", @"");
        }

        std::printf("结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
