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
// ==================== 2026-11-18 夜间评审补充（在途旧回包 · 错位索引）====================
// 本文件另外钉住两件事（生产修复见 commit dafb14f，tools/native_ui/RLPQueueViewController.mm）：
//   1) 排序/拖动在途时，已发出的旧 /api/queue?meta=1 回包不得落表（否则会覆盖刚提交的新顺序，
//      并让拖动的行号错位）。修复 = sortInFlight/moveInFlight/dragSessionActive +
//      reloadData:/applyQueueSnapshot: 的在途闸门 + sortBy:/acceptDrop 的 ++seq。
//   2) 拖动负载必须带行身份（row + path + cs/ce）；拖动期间队列变过时，同一行号已不是原来那首
//      ⟹ acceptDrop 必须拒绝且不发 /api/qmove（后端 qmove 不校验曲目身份）。
//      修复 = pasteboardWriterForRow: 写身份 plist + acceptDrop 的 path/cs/ce 复核。
// 哪一处修复被移除会让判据变红，写在各判据块开头的注释里：
//   * P8a（拖动在途）唯一由 applyQueueSnapshot: 闸门兜底（拖动开始不 ++seq）；
//   * P8b（排序在途）由 ++seq 与 applyQueueSnapshot: 闸门互为冗余兜底（单独移除一道仍绿）；
//   * P8b 的“刷新被压住”只由 reloadData 的早退兜底；
//   * P9 的 path 复核、cs/ce 复核各自独立，移除任一道都会让对应子判据红；
//     P9a 的负载契约（裸行号 vs 身份 plist）与 P9d 的裸行号负载单独钉住 writer/acceptDrop 的格式修复。
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
/// 队列夹具：P7 需要把队列清空，其它判据仍用 4 首默认夹具。
static NSArray<NSString *> *g_queueItems;
static NSArray<NSDictionary *> *g_queueMetas;
static NSArray<NSArray<NSNumber *> *> *g_queueCues;
static NSInteger g_queueMode;
/// 失败注入 + 保存响应（P2/P6：真实走 ok/error 字段，不靠文案猜测）。
static BOOL g_failQorder;
static NSString *g_qorderErr;
static BOOL g_failQsortDefault;
static NSString *g_qsortErr;
static NSDictionary *g_saveResponse;
static NSInteger g_savedQueueNotes;
/// P8（在途旧回包）：/api/queue?meta=1 的回包可以扣住，由判据手动投递，
/// 模拟真实异步客户端里「读取已发出、排序/拖动已开始、回包才回来」的竞态。
static BOOL g_holdQueueMetaGet;
static NSMutableArray<RLPJSONCompletion> *g_heldQueueMetaDone;
static NSMutableArray<NSDictionary *> *g_heldQueueMetaPayload;
/// P8b（排序在途）：/api/qorder 的回包同样扣住，制造“请求未回包”的窗口。
static BOOL g_holdReorderPost;
static NSMutableArray<RLPJSONCompletion> *g_heldReorderDone;
static NSMutableArray<NSString *> *g_heldReorderPaths;
/// P8 的旧快照（3 首）只在被扣住的那次读取里生效，不改全局夹具。
static NSDictionary *g_queueOverride;

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
/// P8 的旧快照：3 首（当前 4 首）。旧回包若落表，行数/标题会立刻可见地变。
static NSDictionary *StaleQueuePayload(void) {
    return @{ @"ok": @YES, @"index": @0, @"mode": @0,
              @"items": @[ @"/Music/A/One.flac", @"/Music/B/Two.flac", @"/Music/C/Three.flac" ],
              @"cues": @[ @[ @(-1), @(-1) ], @[ @(10), @(20) ], @[ @(-1), @(-1) ] ],
              @"metas": @[ @{ @"t": @"Zulu",  @"a": @"B", @"al": @"Alb2", @"d": @100, @"y": @2001 },
                           @{ @"t": @"Alpha", @"a": @"C", @"al": @"Alb3", @"d": @50,  @"y": @2005 },
                           @{ @"t": @"Mike",  @"a": @"A", @"al": @"Alb1", @"d": @300, @"y": @1999 } ] };
}
/// P9a：拖动期间队列变过序（第 0 行 A/One → C/Three）。
/// 第 0 行 cue 仍是整轨 [-1,-1]（与拖动负载相同）⟹ 只有 path 复核能挡住这一落；
/// 若移除 path 复核，cs/ce 复核会放行并发 qmove（判据红）。
static NSArray<NSString *> *ReorderedPathsFixture(void) {
    return @[ @"/Music/C/Three.flac", @"/Music/B/Two.flac",
              @"/Music/A/One.flac", @"/Music/D/Four.flac" ];
}
static NSArray<NSDictionary *> *ReorderedMetasFixture(void) {
    return @[ @{ @"t": @"Mike",  @"a": @"A", @"al": @"Alb1", @"d": @300, @"y": @1999 },
              @{ @"t": @"Alpha", @"a": @"C", @"al": @"Alb3", @"d": @50,  @"y": @2005 },
              @{ @"t": @"Zulu",  @"a": @"B", @"al": @"Alb2", @"d": @100, @"y": @2001 },
              @{ @"t": @"Bravo", @"a": @"D", @"al": @"Alb4", @"d": @20,  @"y": @2010 } ];
}
static NSArray<NSArray<NSNumber *> *> *ReorderedCuesFixture(void) {
    return @[ @[ @(-1), @(-1) ], @[ @(10), @(20) ],
              @[ @(-1), @(-1) ], @[ @(30), @(40) ] ];
}
/// P9b：路径不变、区间变了（第 1 行 B/Two 从 [10,20] 变整轨）⟹ 只有 cs/ce 复核能挡住。
static NSArray<NSArray<NSNumber *> *> *FlatCuesFixture(void) {
    return @[ @[ @(-1), @(-1) ], @[ @(-1), @(-1) ],
              @[ @(-1), @(-1) ], @[ @(-1), @(-1) ] ];
}
static void ResetQueueFixtures(void) {
    g_queueItems = PathsFixture(); g_queueMetas = MetasFixture(); g_queueCues = CuesFixture();
    g_queueMode = 0;
}

static NSDictionary *QueuePayload(void) {
    if (g_queueOverride) return g_queueOverride;
    return @{ @"ok": @YES, @"index": @0, @"mode": @(g_queueMode),
              @"items": g_queueItems ?: @[], @"cues": g_queueCues ?: @[],
              @"metas": g_queueMetas ?: @[] };
}

#pragma mark clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RLPCoreClient
+ (instancetype)shared { static RLPCoreClient *c; if (!c) c = [self new]; return c; }
- (BOOL)started { return YES; }
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    if (!done) return;
    [g_gets addObject:@{ @"path": path ?: @"" }];
    if ([path hasPrefix:@"/api/queue?meta=1"]) {
        if (g_holdQueueMetaGet) {
            [g_heldQueueMetaDone addObject:[done copy]];
            [g_heldQueueMetaPayload addObject:QueuePayload()];
            return;
        }
        done(QueuePayload()); return;
    }
    if ([path hasPrefix:@"/api/playmode"]) { done(@{ @"ok": @YES, @"mode": @(g_queueMode) }); return; }
    if ([path hasPrefix:@"/api/sq/list"]) { done(@{ @"ok": @YES, @"queues": @[] }); return; }
    done(@{ @"ok": @NO });
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done { (void)path; if (done) done(nil); }
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    [g_posts addObject:@{ @"path": path ?: @"", @"body": body ?: @"" }];
    // 失败注入：判据必须看到 ok 字段被读、下拉回滚、错误按后端原文提示。
    if ([path hasPrefix:@"/api/qorder"] && g_failQorder) {
        NSMutableDictionary *j = [@{ @"ok": @NO } mutableCopy];
        if (g_qorderErr.length) j[@"error"] = g_qorderErr;
        if (done) done(j);
        return;
    }
    if ([path hasPrefix:@"/api/qsort"] && g_failQsortDefault) {
        NSMutableDictionary *j = [@{ @"ok": @NO } mutableCopy];
        if (g_qsortErr.length) j[@"error"] = g_qsortErr;
        if (done) done(j);
        return;
    }
    if ([path hasPrefix:@"/api/qorder"] || [path hasPrefix:@"/api/qmove"]) {
        if (g_holdReorderPost) {
            if (done) {
                [g_heldReorderDone addObject:[done copy]];
                [g_heldReorderPaths addObject:path ?: @""];
            }
            return;
        }
    }
    if ([path hasPrefix:@"/api/sq/save"] && g_saveResponse) { if (done) done(g_saveResponse); return; }
    if ([path hasPrefix:@"/api/playmode?mode="]) {
        g_queueMode = [[path substringFromIndex:@"/api/playmode?mode=".length] integerValue];
        if (done) done(@{ @"ok": @YES });
        return;
    }
    if (done) done(@{ @"ok": @YES });
}
@end
#pragma mark clang diagnostic pop

#pragma mark - 拖动夹具（P9：生产码只读 draggingPasteboard 的两个取值方法）

/// 离屏拖放夹具：**不**声明 NSDraggingInfo 协议（协议有 11 个 @required 成员，
/// 与本判据无关）；acceptDrop 只读 draggingPasteboard，故只实现这一个属性。
@interface RLPQueueDragInfoStub : NSObject
@property (nonatomic, strong) id draggingPasteboard;
@end

@implementation RLPQueueDragInfoStub
@end

/// 离屏粘贴板夹具：acceptDrop 只调 propertyListForType:/stringForType:。
/// 用轻量对象替代真 NSPasteboard：离线/无 WindowServer 时也不依赖 pboard 服务，
/// 且能精确模拟“旧负载是字符串、新负载是 plist 字典”两种契约。
@interface RLPQueueDragPasteboardStub : NSObject
@property (nonatomic, copy) id payload;             // propertyListForType:
@property (nonatomic, copy) NSString *stringPayload;    // stringForType:
@end

@implementation RLPQueueDragPasteboardStub
- (id)propertyListForType:(NSString *)type { (void)type; return self.payload; }
- (NSString *)stringForType:(NSString *)type { (void)type; return self.stringPayload; }
@end

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
static NSArray<NSDictionary *> *PostsWithPrefix(NSString *prefix) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *p in g_posts) if ([p[@"path"] hasPrefix:prefix]) [out addObject:p];
    return out;
}

/// 与生产 kQueueDragType 同值（生产常量是 .mm 私有，测试按契约字面量复核）。
static NSString *const kQueueDragTypeTest = @"com.rta.rlplayer.queue-row";

/// 页面当前队列（生产私有属性 paths）：判据只读，不写。
static NSArray<NSString *> *PathsOf(RLPQueueViewController *vc) {
    id p = [vc valueForKey:@"paths"];
    return [p isKindOfClass:[NSArray class]] ? (NSArray<NSString *> *)p : @[];
}
static NSString *PathAt(RLPQueueViewController *vc, NSInteger row) {
    NSArray<NSString *> *ps = PathsOf(vc);
    return (row >= 0 && row < (NSInteger)ps.count) ? ps[(NSUInteger)row] : nil;
}
static NSInteger QueueGetCount(void) {
    NSInteger n = 0;
    for (NSDictionary *g in g_gets) if ([g[@"path"] hasPrefix:@"/api/queue?meta=1"]) ++n;
    return n;
}
/// 投递一条被扣住的旧队列回包（completion + 当时捕获的快照）。
static void DeliverHeldQueueMetaGet(NSUInteger index) {
    if (index >= g_heldQueueMetaDone.count || index >= g_heldQueueMetaPayload.count) return;
    RLPJSONCompletion done = g_heldQueueMetaDone[index];
    NSDictionary *payload = g_heldQueueMetaPayload[index];
    [g_heldQueueMetaDone removeObjectAtIndex:index];
    [g_heldQueueMetaPayload removeObjectAtIndex:index];
    if (done) done(payload);
}
/// 投递所有被扣住的 qorder/qmove 回包（P8b 放行排序）。
static void DeliverHeldReorder(NSDictionary *result) {
    NSArray<RLPJSONCompletion> *held = [g_heldReorderDone copy];
    [g_heldReorderDone removeAllObjects];
    [g_heldReorderPaths removeAllObjects];
    for (RLPJSONCompletion done in held) if (done) done(result);
}

#pragma mark - 轻提示断言（与 test_native_nowplaying_web 同一条离屏口径）

/// RLPToast 挂在窗口 contentView 上的视图 identifier 是 rlp.toast（不靠文案匹配）。
static NSView *ToastBox(NSWindow *win) {
    for (NSView *v in win.contentView.subviews)
        if ([v.identifier isEqualToString:@"rlp.toast"]) return v;
    return nil;
}
static void ClearToasts(NSWindow *win) {
    NSMutableArray<NSView *> *doomed = [NSMutableArray array];
    for (NSView *v in win.contentView.subviews)
        if ([v.identifier isEqualToString:@"rlp.toast"]) [doomed addObject:v];
    for (NSView *v in doomed) [v removeFromSuperview];
}
/// 当前 toast 的文案（RLPToast 显示的是 RLPTr(message)，所以断言也用 RLPTr 比对）。
static NSString *ToastText(NSWindow *win) {
    NSView *box = ToastBox(win);
    if (!box) return nil;
    for (NSView *v in box.subviews)
        if ([v isKindOfClass:[NSTextField class]]) return ((NSTextField *)v).stringValue;
    return nil;
}
#pragma mark - 测试

@interface RLPQueueViewController (QueueSortTest)
- (void)reloadData;
- (void)sortBy:(NSString *)key;
- (void)playRow:(NSInteger)row;
- (void)onSortPicked:(NSPopUpButton *)sender;
- (void)savePlaylistNamed:(NSString *)name;   // 生产接缝：不弹「保存为歌单」名对话框
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
        g_heldQueueMetaDone = [NSMutableArray array];
        g_heldQueueMetaPayload = [NSMutableArray array];
        g_heldReorderDone = [NSMutableArray array];
        g_heldReorderPaths = [NSMutableArray array];
        g_queueItems = PathsFixture();
        g_queueMetas = MetasFixture();
        g_queueCues = CuesFixture();
        g_queueMode = 0;
        [RLPTheme setThemeName:@"light"];
        [RLPTheme setUiStyle:@"apple"];
        // 离屏窗口承载页面：P2/P6/P7 要断言**用户看得见的 toast**（RLPToast 无窗口时会静默丢弃）。
        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1200, 800)
                                                    styleMask:NSWindowStyleMaskBorderless
                                                      backing:NSBackingStoreBuffered defer:NO];
        win.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1200, 800)];
        [win orderFront:nil];
        static NSWindow *sWindow; sWindow = win; (void)sWindow;   // 不 close：离屏测试不承担 dealloc 顺序
        [[NSNotificationCenter defaultCenter] addObserverForName:@"RLPSavedQueuesChangedNotification"
                                                           object:nil queue:nil
                                                        usingBlock:^(NSNotification *note) {
            (void)note;
            ++g_savedQueueNotes;
        }];
        std::printf("=== test_native_queue_sort（#qSort 8 档 + CUE 保真 · 离屏 · 不出声）===\n");

        RLPQueueViewController *vc = NewVC();
        vc.view.frame = win.contentView.bounds;
        [win.contentView addSubview:vc.view];
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
            Ck([table.registeredDraggedTypes containsObject:@"com.rta.rlplayer.queue-row"],
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

        // ---- P7 空队列守卫：按钮禁用 + 直接提示，不弹框不发请求（web saveQueueDialog 的 n==0 分支）----
        {
            g_queueItems = @[]; g_queueMetas = @[]; g_queueCues = @[];
            RLPQueueViewController *emptyVC = [RLPQueueViewController new];
            NSView *ev = emptyVC.view;
            ev.frame = win.contentView.bounds;
            [win.contentView addSubview:ev];
            [ev layoutSubtreeIfNeeded];
            [emptyVC reloadData];
            Pump(0.05);
            Ck([emptyVC valueForKey:@"paths"] != nil && [[emptyVC valueForKey:@"paths"] count] == 0,
               "P7 空队列已载入（判据前提）", [NSString stringWithFormat:@"paths=%@", [emptyVC valueForKey:@"paths"]]);
            NSButton *save = (NSButton *)FindById(ev, @"save");
            Ck([save isKindOfClass:[NSButton class]], "P7 找得到「保存为歌单」按钮（save）", @"save 缺失");
            Ck(save != nil && !save.enabled,
               "P7 空队列时「保存为歌单」按钮禁用（web 空队列不渲染保存按钮）",
               [NSString stringWithFormat:@"enabled=%d", save ? (int)save.enabled : -1]);
            [g_posts removeAllObjects];
            ClearToasts(win);
            [emptyVC savePlaylistNamed:@"Empty Queue"];
            Pump(0.05);
            Ck(PostsWithPrefix(@"/api/sq/save").count == 0,
               "P7 空队列保存不发 /api/sq/save（后端本来也会拒，前端不先弹框）",
               [g_posts componentsJoinedByString:@" | "]);
            Ck([ToastText(win) isEqualToString:RLPTr(@"队列是空的，先加几首歌再保存")],
               "P7 空队列保存直接提示（web 原文：队列是空的，先加几首再保存）",
               ToastText(win) ?: @"(无 toast)");
            [ev removeFromSuperview];
            // 恢复夹具（后续 M3U 判据仍用 4 首队列）。
            g_queueItems = PathsFixture(); g_queueMetas = MetasFixture(); g_queueCues = CuesFixture();
            [vc reloadData];
            Pump(0.05);
        }

        // ---- P2 保存歌单后侧栏刷新 + toast 带歌单名/首数（web ui_script.h:3930-3932）----
        {
            g_saveResponse = @{ @"ok": @YES, @"name": @"Night Mix", @"count": @4 };
            g_savedQueueNotes = 0;
            [g_posts removeAllObjects];
            ClearToasts(win);
            [vc savePlaylistNamed:@"Night Mix"];
            Pump(0.05);
            NSArray<NSDictionary *> *saves = PostsWithPrefix(@"/api/sq/save");
            Ck(saves.count == 1, "P2 保存歌单真发 /api/sq/save", [g_posts componentsJoinedByString:@" | "]);
            if (saves.count == 1) {
                NSString *decoded = [saves[0][@"path"] stringByRemovingPercentEncoding] ?: saves[0][@"path"];
                Ck([decoded containsString:@"name=Night Mix"], "P2 歌单名下发正确", decoded);
            }
            Ck(g_savedQueueNotes == 1,
               "P2 成功后发 RLPSavedQueuesChangedNotification（侧栏行数 +1 含新名）",
               [NSString stringWithFormat:@"notes=%ld", (long)g_savedQueueNotes]);
            NSString *wantToast = [NSString stringWithFormat:@"%@%@（%ld %@）",
                                   RLPTr(@"已存为歌单："), @"Night Mix", (long)4, RLPTr(@"首")];
            Ck([ToastText(win) isEqualToString:wantToast],
               "P2 toast = 已存为歌单：<名>（<N> 首）（带名与首数，不是裸的已保存歌单）",
               [NSString stringWithFormat:@"got=%@ want=%@", ToastText(win) ?: @"(无 toast)", wantToast]);
            g_saveResponse = nil;
        }

        // ---- P6 排序失败反馈 + 下拉回滚（web ui_script.h:12496-12500 / 12541-12543）----
        {
            // P6a qorder 失败：toast 后端 error，下拉回到上一档（不留在用户刚点的档位）。
            g_failQorder = YES;
            g_qorderErr = @"排序失败：无法写入队列文件";
            ClearToasts(win);
            [sort selectItemAtIndex:0];                 // 上一档 = 默认顺序
            [sort selectItemAtIndex:5];                 // 用户点「年份」
            [g_posts removeAllObjects];
            [vc onSortPicked:sort];
            Pump(0.1);
            Ck([ToastText(win) isEqualToString:g_qorderErr],
               "P6 排序失败 toast = 后端 error（不再静默）",
               [NSString stringWithFormat:@"got=%@ want=%@", ToastText(win) ?: @"(无 toast)", g_qorderErr]);
            Ck(sort.indexOfSelectedItem == 0,
               "P6 排序失败后下拉回滚到上一档（默认顺序）",
               [NSString stringWithFormat:@"selected=%ld", (long)sort.indexOfSelectedItem]);
            g_failQorder = NO;

            // P6b 先成功排一次标题（成为"上一档"），再让 default 恢复失败。
            [sort selectItemAtIndex:1];
            [vc onSortPicked:sort];
            Pump(0.1);
            Ck([g_posts count] > 0, "P6b 标题排序已下发（判据前提）", @"");

            g_failQsortDefault = YES;
            g_qsortErr = nil;
            ClearToasts(win);
            [sort selectItemAtIndex:0];
            [vc onSortPicked:sort];
            Pump(0.1);
            Ck([ToastText(win) isEqualToString:RLPTr(@"没有可恢复的排序")],
               "P6 default 失败且后端无 error 时提示「没有可恢复的排序」（web fallback 文案）",
               [NSString stringWithFormat:@"got=%@", ToastText(win) ?: @"(无 toast)"]);
            Ck(sort.indexOfSelectedItem == 1,
               "P6 default 失败后下拉回滚到上一档（标题）",
               [NSString stringWithFormat:@"selected=%ld", (long)sort.indexOfSelectedItem]);
            g_failQsortDefault = NO;

            // P6c default 成功：web 回 toast「已恢复默认顺序」并把档位留在默认。
            ClearToasts(win);
            [sort selectItemAtIndex:0];
            [vc onSortPicked:sort];
            Pump(0.1);
            Ck([ToastText(win) isEqualToString:RLPTr(@"已恢复默认顺序")],
               "P6 default 成功提示「已恢复默认顺序」（web ui_script.h:12500）",
               [NSString stringWithFormat:@"got=%@", ToastText(win) ?: @"(无 toast)"]);
            Ck(sort.indexOfSelectedItem == 0, "P6 成功后档位停在默认顺序",
               [NSString stringWithFormat:@"selected=%ld", (long)sort.indexOfSelectedItem]);
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

        // ---- 缺口1：同一排序项可重复触发 + 队列变更广播 RLPQueueChangedNotification ----
        {
            __block NSInteger qChangedCount = 0;
            __block id qChangedObj = nil;
            id obs = [[NSNotificationCenter defaultCenter] addObserverForName:RLPQueueChangedNotification
                                                                       object:nil
                                                                        queue:nil
                                                                   usingBlock:^(NSNotification *note) {
                ++qChangedCount;
                qChangedObj = note.object;
            }];

            // 1) 同一项（如 shuffle index=6）连续通过 menu 触发两次，每次都发 /api/qorder 且广播通知
            [sort selectItemAtIndex:0];
            [g_posts removeAllObjects];
            qChangedCount = 0;
            [sort.menu performActionForItemAtIndex:6];
            Pump(0.05);
            NSInteger firstPosts = (NSInteger)PostsWithPrefix(@"/api/qorder").count;
            NSInteger firstNotes = qChangedCount;
            [sort.menu performActionForItemAtIndex:6];
            Pump(0.05);
            NSInteger secondPosts = (NSInteger)PostsWithPrefix(@"/api/qorder").count;
            NSInteger secondNotes = qChangedCount;
            Ck(firstPosts == 1 && secondPosts == 2,
               "缺口1 同一排序项(shuffle)连续点击两次均触发 /api/qorder",
               [NSString stringWithFormat:@"first=%ld second=%ld", (long)firstPosts, (long)secondPosts]);
            Ck(firstNotes == 1 && secondNotes == 2 && qChangedObj == vc,
               "缺口1 排序成功后广播 RLPQueueChangedNotification(object:self)",
               [NSString stringWithFormat:@"notes=%ld/%ld objMatch=%d",
                (long)firstNotes, (long)secondNotes, (int)(qChangedObj == vc)]);

            // 2) 行尾删除触发 RLPQueueChangedNotification(object:self)
            NSTableView *tbl = (NSTableView *)FindById(vc.view, @"queue.table");
            if (!tbl) {
                NSMutableArray<NSView *> *tvs = [NSMutableArray array];
                CollectAll(vc.view, tvs);
                for (NSView *x in tvs) if ([x isKindOfClass:[NSTableView class]]) { tbl = (NSTableView *)x; break; }
            }
            NSButton *rowDel = nil;
            if (tbl) {
                [tbl reloadData];
                [tbl layoutSubtreeIfNeeded];
                NSView *cell = [tbl viewAtColumn:3 row:0 makeIfNecessary:YES];
                NSMutableArray<NSView *> *cs = [NSMutableArray array];
                CollectAll(cell, cs);
                for (NSView *x in cs) if ([x isKindOfClass:[NSButton class]] && [x.identifier isEqualToString:@"q.del"]) { rowDel = (NSButton *)x; break; }
            }
            qChangedCount = 0; qChangedObj = nil;
            [g_posts removeAllObjects];
            if (rowDel) [rowDel sendAction:rowDel.action to:rowDel.target];
            Pump(0.05);
            Ck(PostsWithPrefix(@"/api/qdel").count == 1 && qChangedCount == 1 && qChangedObj == vc,
               "缺口1 行尾删除后广播 RLPQueueChangedNotification(object:self)",
               [NSString stringWithFormat:@"qdel=%lu notes=%ld objMatch=%d",
                (unsigned long)PostsWithPrefix(@"/api/qdel").count, (long)qChangedCount, (int)(qChangedObj == vc)]);

            [[NSNotificationCenter defaultCenter] removeObserver:obs];
        }

        // ---- P8 排序/拖动在途：已发出的旧队列回包不得落表（2026-11-18 夜间评审）----
        // 真实竞态：1s 轮询/外部通知先发了一次 /api/queue?meta=1，用户随即点排序或开始拖动，
        // 旧回包这时才回来。旧快照若落表会覆盖刚提交的新顺序，并让拖动的行号错位。
        // 判据把回包扣在 mock 里（g_holdQueueMetaGet）人为放大这个窗口。
        {
            ResetQueueFixtures();
            [vc reloadData];
            Pump(0.05);
            Ck([PathsOf(vc) count] == 4 && table.numberOfRows == 4,
               "P8 前置：当前表格 = 4 首默认队列（判据基线）",
               [NSString stringWithFormat:@"paths=%lu rows=%ld",
                (unsigned long)[PathsOf(vc) count], (long)table.numberOfRows]);

            // --- P8a 拖动会话在途 ---
            // 这条路径不 ++seq（拖动开始只置 dragSessionActive），唯一屏障 = applyQueueSnapshot: 的闸门。
            // ⟹ 移除 applyQueueSnapshot: 的早退，本子判据红（旧码没有这道闸门，旧快照会直接落表）。
            [g_heldQueueMetaDone removeAllObjects];
            [g_heldQueueMetaPayload removeAllObjects];
            g_queueOverride = StaleQueuePayload();
            g_holdQueueMetaGet = YES;
            [vc reloadData];                        // 读取在拖动前发出，回包被扣住
            g_holdQueueMetaGet = NO;
            g_queueOverride = nil;
            Ck(g_heldQueueMetaDone.count == 1 && g_heldQueueMetaPayload.count == 1,
               "P8a 前置：旧队列读取已扣在 mock（3 首旧快照，当前 4 首）",
               [NSString stringWithFormat:@"done=%lu payload=%lu",
                (unsigned long)g_heldQueueMetaDone.count, (unsigned long)g_heldQueueMetaPayload.count]);
            // 旧码（dafb14f^）没有这两个 delegate 入口；respondsToSelector 只为避免向未实现
            // 的选择器发消息而崩，缺入口本身仍判红（前置 Ck），旧快照照常投递以暴露漏闸。
            SEL p8WillBegin = @selector(tableView:draggingSession:willBeginAtPoint:forRowIndexes:);
            SEL p8Ended = @selector(tableView:draggingSession:endedAtPoint:operation:);
            BOOL p8HasDragSession = [vc respondsToSelector:p8WillBegin] && [vc respondsToSelector:p8Ended];
            Ck(p8HasDragSession,
               "P8a 前置：拖动会话 delegate 入口存在（dragSessionActive 才有置位入口）",
               @"缺少 willBegin/ended 选择器");
            if (p8HasDragSession) {
                [vc tableView:table draggingSession:nil willBeginAtPoint:NSMakePoint(0, 0)
                    forRowIndexes:[NSIndexSet indexSetWithIndex:1]];
            }
            DeliverHeldQueueMetaGet(0);
            Pump(0.05);
            Ck([PathsOf(vc) count] == 4 && table.numberOfRows == 4,
               "P8a 拖动在途：旧队列回包不落表（行数仍是 4、顺序不回到旧快照）",
               [NSString stringWithFormat:@"paths=%lu rows=%ld",
                (unsigned long)[PathsOf(vc) count], (long)table.numberOfRows]);
            // 拖动结束补拉（生产在 endedAtPoint: 里做），也保证后续判据不被拖动态压住。
            if (p8HasDragSession) {
                [vc tableView:table draggingSession:nil endedAtPoint:NSMakePoint(0, 0)
                    operation:NSDragOperationNone];
            }
            Pump(0.05);
            Ck([PathsOf(vc) count] == 4,
               "P8a 收尾：拖动结束后补拉仍回到 4 首（闸门没有把刷新永久压死）",
               [NSString stringWithFormat:@"paths=%lu", (unsigned long)[PathsOf(vc) count]]);

            // --- P8b 排序在途（qorder 未回包）---
            // 这条窗口有两道冗余闸门：sortBy: 的 ++seq 与 applyQueueSnapshot: 的在途闸门；
            // 移除任一仍会被另一道兜住，两者同时移除才红（旧码两者都没有 ⟹ 对旧码红）。
            // “刷新被压住”只由 reloadData 的早退兜底 ⟹ 移除它，下面条数判据红。
            [g_heldQueueMetaDone removeAllObjects];
            [g_heldQueueMetaPayload removeAllObjects];
            g_queueOverride = StaleQueuePayload();
            g_holdQueueMetaGet = YES;
            [vc reloadData];                        // 旧读取（扣住）
            g_holdQueueMetaGet = NO;
            g_queueOverride = nil;
            Ck(g_heldQueueMetaDone.count == 1,
               "P8b 前置：旧队列读取已扣在 mock",
               [NSString stringWithFormat:@"done=%lu", (unsigned long)g_heldQueueMetaDone.count]);

            [g_heldReorderDone removeAllObjects];
            [g_heldReorderPaths removeAllObjects];
            g_holdReorderPost = YES;
            [g_posts removeAllObjects];
            [vc sortBy:@"title"];                   // qorder 扣住 ⟹ 排序在途窗口保持
            Ck(g_heldReorderDone.count == 1,
               "P8b 前置：qorder 停在未回包窗口（排序在途）",
               [NSString stringWithFormat:@"held=%lu posts=%@",
                (unsigned long)g_heldReorderDone.count, [g_posts componentsJoinedByString:@" | "]]);

            DeliverHeldQueueMetaGet(0);
            Pump(0.05);
            Ck([PathsOf(vc) count] == 4 && table.numberOfRows == 4,
               "P8b 排序在途：旧队列回包不落表（不覆盖已提交的新顺序）",
               [NSString stringWithFormat:@"paths=%lu rows=%ld",
                (unsigned long)[PathsOf(vc) count], (long)table.numberOfRows]);

            const NSInteger p8GetsBefore = QueueGetCount();
            [vc reloadData];                        // 在途期间外部通知/轮询会走到这里
            const NSInteger p8GetsAfter = QueueGetCount();
            Ck(p8GetsAfter == p8GetsBefore,
               "P8b 排序在途：reloadData 被压住（不新发队列读取）",
               [NSString stringWithFormat:@"before=%ld after=%ld",
                (long)p8GetsBefore, (long)p8GetsAfter]);

            DeliverHeldReorder(@{ @"ok": @YES });
            g_holdReorderPost = NO;
            Pump(0.05);
            Ck([PathsOf(vc) count] == 4 && table.numberOfRows == 4,
               "P8b 收尾：qorder 成功后仍为 4 首（旧快照没有抢先占位）",
               [NSString stringWithFormat:@"paths=%lu rows=%ld",
                (unsigned long)[PathsOf(vc) count], (long)table.numberOfRows]);
        }

        // ---- P9 错位索引不 qmove（2026-11-18 夜间评审）----
        // 拖动负载必须带行身份（row + path + cs/ce）。拖动期间队列被轮询/外部通知改过时，
        // 同一行号已不是原来那首；后端 qmove 只按行号搬、不校验身份 ⟹ 前端必须拒绝落下。
        // 旧码（dafb14f^）负载只有裸行号、acceptDrop 只做 from 越界检查 ⟹ 会搬错歌（判据红）。
        {
            ResetQueueFixtures();
            [vc reloadData];
            Pump(0.05);
            Ck([PathsOf(vc) count] == 4,
               "P9 前置：默认 4 首队列已载入",
               [NSString stringWithFormat:@"paths=%lu", (unsigned long)[PathsOf(vc) count]]);

            // --- P9a 行号在拖动期间错位（path 身份复核）---
            // 队列变序后第 0 行 = C/Three（整轨），拖动负载仍是 A/One（整轨）⟹ cs/ce 相同，
            // 只有 path 复核能挡住这一落 ⟹ 移除 path 复核，qmove 判据红。
            // 负载契约直接读 writer 返回的 NSPasteboardItem（不经 pasteboard round-trip）：
            // 旧码的 writer 只写裸行号字符串 ⟹ 下面的“带行身份”判据红。
            id<NSPasteboardWriting> writerA = [vc tableView:table pasteboardWriterForRow:0];
            Ck(writerA != nil, "P9a 前置：拿得到第 0 行的拖动负载", @"writer 返回 nil");
            NSDictionary *plistA = nil;
            if ([writerA isKindOfClass:[NSPasteboardItem class]])
                plistA = (NSDictionary *)[(NSPasteboardItem *)writerA propertyListForType:kQueueDragTypeTest];
            Ck([plistA isKindOfClass:[NSDictionary class]] &&
               [plistA[@"row"] integerValue] == 0 &&
               [plistA[@"path"] isEqualToString:@"/Music/A/One.flac"],
               "P9a 拖动负载带行身份（row + path，不是裸行号）",
               [NSString stringWithFormat:@"plist=%@", plistA ?: @"(nil)"]);
            // 落下用的负载：优先用生产 writer 写出的 plist（当前码是行身份 plist）；
            // 若 writer 已被回退成裸行号，用同契约的等价负载继续验 acceptDrop 的复核
            // （格式回归由上面的 Ck 单独判红，P9d 再验裸行号负载不得 qmove）。
            NSDictionary *dropA = [plistA isKindOfClass:[NSDictionary class]]
                ? plistA
                : @{ @"row": @0, @"path": @"/Music/A/One.flac", @"cs": @(-1.0), @"ce": @(-1.0) };
            RLPQueueDragPasteboardStub *pasteA = [RLPQueueDragPasteboardStub new];
            pasteA.payload = dropA;
            g_queueItems = ReorderedPathsFixture();
            g_queueMetas = ReorderedMetasFixture();
            g_queueCues = ReorderedCuesFixture();
            [vc reloadData];
            Pump(0.05);
            Ck([PathAt(vc, 0) isEqualToString:@"/Music/C/Three.flac"],
               "P9a 前置：队列在拖动期间变过（第 0 行现在是 C/Three，不再是负载里的 A/One）",
               [NSString stringWithFormat:@"row0=%@", PathAt(vc, 0) ?: @"(nil)"]);

            RLPQueueDragInfoStub *infoA = [RLPQueueDragInfoStub new];
            infoA.draggingPasteboard = pasteA;
            [g_posts removeAllObjects];
            ClearToasts(win);
            BOOL acceptedA = [vc tableView:table acceptDrop:(id<NSDraggingInfo>)infoA
                                      row:3 dropOperation:NSTableViewDropAbove];
            Pump(0.05);
            Ck(PostsWithPrefix(@"/api/qmove").count == 0,
               "P9a 错位索引不发 /api/qmove（同一行号已指向另一首）",
               [g_posts componentsJoinedByString:@" | "]);
            Ck(!acceptedA, "P9a acceptDrop 返回 NO（拒绝落下）",
               [NSString stringWithFormat:@"accepted=%d", (int)acceptedA]);
            Ck([ToastText(win) isEqualToString:RLPTr(@"排序失败")],
               "P9a 拒绝时提示「排序失败」（不静默搬歌）",
               ToastText(win) ?: @"(无 toast)");
            Ck([PathsOf(vc) isEqualToArray:ReorderedPathsFixture()],
               "P9a 拒绝后队列顺序不变（没有本地假搬动）",
               [NSString stringWithFormat:@"paths=%@", PathsOf(vc)]);

            // --- P9b CUE 身份错位（同一路径的多个分轨只比 path 仍会搬错）---
            // 路径不变、第 1 行 B/Two 的区间从 [10,20] 变成整轨 ⟹ 只有 cs/ce 复核能挡住
            // ⟹ 移除 cs/ce 复核，qmove 判据红。
            ResetQueueFixtures();
            [vc reloadData];
            Pump(0.05);
            id<NSPasteboardWriting> writerB = [vc tableView:table pasteboardWriterForRow:1];
            Ck(writerB != nil, "P9b 前置：拿得到第 1 行的拖动负载", @"writer 返回 nil");
            NSDictionary *plistB = nil;
            if ([writerB isKindOfClass:[NSPasteboardItem class]])
                plistB = (NSDictionary *)[(NSPasteboardItem *)writerB propertyListForType:kQueueDragTypeTest];
            Ck([plistB isKindOfClass:[NSDictionary class]] &&
               [plistB[@"path"] isEqualToString:@"/Music/B/Two.flac"] &&
               fabs([plistB[@"cs"] doubleValue] - 10.0) < 0.0005 &&
               fabs([plistB[@"ce"] doubleValue] - 20.0) < 0.0005,
               "P9b 拖动负载带 CUE 区间（cs/ce 随行保留）",
               [NSString stringWithFormat:@"plist=%@", plistB ?: @"(nil)"]);
            NSDictionary *dropB = [plistB isKindOfClass:[NSDictionary class]]
                ? plistB
                : @{ @"row": @1, @"path": @"/Music/B/Two.flac", @"cs": @(10.0), @"ce": @(20.0) };
            RLPQueueDragPasteboardStub *pasteB = [RLPQueueDragPasteboardStub new];
            pasteB.payload = dropB;
            g_queueItems = PathsFixture();
            g_queueMetas = MetasFixture();
            g_queueCues = FlatCuesFixture();
            [vc reloadData];
            Pump(0.05);
            Ck([PathAt(vc, 1) isEqualToString:@"/Music/B/Two.flac"],
               "P9b 前置：路径没变、区间已变（B/Two 从 10..20 变整轨）",
               [NSString stringWithFormat:@"row1=%@ cues=%@", PathAt(vc, 1) ?: @"(nil)",
                [vc valueForKey:@"cues"]]);
            RLPQueueDragInfoStub *infoB = [RLPQueueDragInfoStub new];
            infoB.draggingPasteboard = pasteB;
            [g_posts removeAllObjects];
            ClearToasts(win);
            BOOL acceptedB = [vc tableView:table acceptDrop:(id<NSDraggingInfo>)infoB
                                      row:3 dropOperation:NSTableViewDropAbove];
            Pump(0.05);
            Ck(PostsWithPrefix(@"/api/qmove").count == 0,
               "P9b CUE 身份错位不发 /api/qmove",
               [g_posts componentsJoinedByString:@" | "]);
            Ck(!acceptedB && [ToastText(win) isEqualToString:RLPTr(@"排序失败")],
               "P9b CUE 错位时拒绝并提示「排序失败」",
               [NSString stringWithFormat:@"accepted=%d toast=%@", (int)acceptedB,
                ToastText(win) ?: @"(无 toast)"]);

            // --- P9c 对照：身份一致时必须真发 qmove（防止“一律拒绝”也被判绿）---
            ResetQueueFixtures();
            [vc reloadData];
            Pump(0.05);
            id<NSPasteboardWriting> writerC = [vc tableView:table pasteboardWriterForRow:0];
            NSDictionary *plistC = nil;
            if ([writerC isKindOfClass:[NSPasteboardItem class]])
                plistC = (NSDictionary *)[(NSPasteboardItem *)writerC propertyListForType:kQueueDragTypeTest];
            NSDictionary *dropC = [plistC isKindOfClass:[NSDictionary class]]
                ? plistC
                : @{ @"row": @0, @"path": @"/Music/A/One.flac", @"cs": @(-1.0), @"ce": @(-1.0) };
            RLPQueueDragPasteboardStub *pasteC = [RLPQueueDragPasteboardStub new];
            pasteC.payload = dropC;
            RLPQueueDragInfoStub *infoC = [RLPQueueDragInfoStub new];
            infoC.draggingPasteboard = pasteC;
            [g_posts removeAllObjects];
            ClearToasts(win);
            BOOL acceptedC = [vc tableView:table acceptDrop:(id<NSDraggingInfo>)infoC
                                      row:3 dropOperation:NSTableViewDropAbove];
            Pump(0.05);
            Ck(acceptedC && PostsWithPrefix(@"/api/qmove").count == 1 &&
               LastPostFor(@"/api/qmove?from=0&to=2") != nil,
               "P9c 对照：身份一致时真发 /api/qmove?from=0&to=2（不是把落下一律拒绝）",
               [NSString stringWithFormat:@"accepted=%d posts=%@", (int)acceptedC,
                [g_posts componentsJoinedByString:@" | "]]);

            // --- P9d 裸行号（旧负载格式）不得触发 qmove ---
            // 旧码用 stringForType: 读裸行号；队列变序后它会从错位的行号发 qmove。
            // 修复后 acceptDrop 只接受带身份的 plist ⟹ 字符串负载（无身份）直接拒绝；
            // 把 acceptDrop 退回 stringForType:，本判据红。
            g_queueItems = ReorderedPathsFixture();
            g_queueMetas = ReorderedMetasFixture();
            g_queueCues = ReorderedCuesFixture();
            [vc reloadData];
            Pump(0.05);
            // 旧负载的字符串也是合法 property list ⟹ 两个取值方法都返回字符串，
            // 与真 pasteboard 的语义一致（新 acceptDrop 必须因“不是字典”拒绝它）。
            RLPQueueDragPasteboardStub *pasteD = [RLPQueueDragPasteboardStub new];
            pasteD.payload = @"0";
            pasteD.stringPayload = @"0";
            RLPQueueDragInfoStub *infoD = [RLPQueueDragInfoStub new];
            infoD.draggingPasteboard = pasteD;
            [g_posts removeAllObjects];
            ClearToasts(win);
            BOOL acceptedD = [vc tableView:table acceptDrop:(id<NSDraggingInfo>)infoD
                                      row:3 dropOperation:NSTableViewDropAbove];
            Pump(0.05);
            Ck(PostsWithPrefix(@"/api/qmove").count == 0,
               "P9d 裸行号负载不发 /api/qmove（没有行身份可核，绝不按旧行号搬歌）",
               [g_posts componentsJoinedByString:@" | "]);
            Ck(!acceptedD, "P9d acceptDrop 返回 NO（裸行号负载被拒）",
               [NSString stringWithFormat:@"accepted=%d", (int)acceptedD]);

            ResetQueueFixtures();
            [vc reloadData];
            Pump(0.05);
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
