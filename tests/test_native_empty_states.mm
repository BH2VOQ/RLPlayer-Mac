// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_empty_states.mm — 专辑页 / 文件夹页空态 = web emptyStateHtml（非 classic 分支）
//
// ============================ 这条判据在证明什么 ============================
// web 真源：
//   专辑页 0 张专辑 → `emptyStateHtml()`（`ui_script.h:1603-1651`）：
//     · 无 roots：「还没有添加音乐目录」+「RLPlayer 会自动…」+「支持 FLAC…」；
//       按钮「添加音乐目录 / 扫描目录 / 打开快速开始」。
//     · 有 roots 但 0 曲目：「已添加音乐目录，但未找到音频文件」+「当前目录中未发现…」；
//       按钮「管理音乐目录 / 重新扫描 / 打开快速开始」，并显示 root 路径。
//     动作：bEmptyAddRoot → openSettingsTab('adv')；bEmptyScan → #bScan（POST /api/lib/scan）；
//           emptyGoStation → 快速开始页。
//   文件夹页（`ui_script.h:3545`）：rows 为空时追加「此目录没有音频文件」。
// 旧原生（1.1.7.29）：专辑页 0 张时只显示空网格与「0 张专辑」计数（无空态卡）；
//   文件夹页 0 行时没有提示。所以本文件对旧码必须红。
//
// 铁律②：桩客户端；不启动核心、不碰音频设备、不创建可见窗口。
#import <AppKit/AppKit.h>
#import "RLPAlbumsViewController.h"
#import "RLPFoldersViewController.h"
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

#pragma mark - 桩客户端（可切换空/非空）

static BOOL g_albumsEmpty = YES;
static BOOL g_filesEmpty = YES;
static NSMutableArray<NSDictionary *> *g_posts;
static NSMutableArray<NSNotification *> *g_notes;

static NSDictionary *AlbumPayload(void) {
    if (g_albumsEmpty) return @{ @"ok": @YES, @"albums": @[] };
    return @{ @"ok": @YES, @"albums": @[
        @{ @"k": @"k1", @"name": @"Album One", @"artist": @"Artist",
           @"year": @2019, @"dur": @180, @"cv": @NO } ] };
}
static NSDictionary *FilesPayload(void) {
    if (g_filesEmpty) return @{ @"ok": @YES, @"dir": @"/Music", @"dirs": @[], @"files": @[] };
    return @{ @"ok": @YES, @"dir": @"/Music", @"dirs": @[ @"Sub" ],
              @"files": @[ @"song.flac" ] };
}

#pragma mark clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RLPCoreClient
+ (instancetype)shared { static RLPCoreClient *c; if (!c) c = [self new]; return c; }
- (BOOL)started { return YES; }
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    if (!done) return;
    if ([path hasPrefix:@"/api/lib/albums"]) { done(AlbumPayload()); return; }
    if ([path hasPrefix:@"/api/lib/stats"]) { done(@{ @"ok": @YES, @"roots": @[ @"/Music" ] }); return; }
    if ([path hasPrefix:@"/api/files"]) { done(FilesPayload()); return; }
    done(@{ @"ok": @NO });
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done {
    (void)path;
    if (done) done(nil);
}
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    [g_posts addObject:@{ @"path": path ?: @"", @"body": body ?: @"" }];
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
static BOOL ActuallyVisible(NSView *v) {
    for (NSView *x = v; x; x = x.superview) {
        if (x.hidden || x.alphaValue < 0.05) return NO;
        if (x.frame.size.width < 1 || x.frame.size.height < 1) return NO;
    }
    return YES;
}
static BOOL HasText(NSView *root, NSString *want) {
    if (!root) return NO;
    if ([root isKindOfClass:[NSTextField class]] &&
        [((NSTextField *)root).stringValue containsString:want]) return YES;
    for (NSView *s in root.subviews) if (HasText(s, want)) return YES;
    return NO;
}
static NSArray<NSButton *> *Buttons(NSView *root) {
    NSMutableArray *out = [NSMutableArray array];
    if ([root isKindOfClass:[NSButton class]]) [out addObject:root];
    for (NSView *s in root.subviews) [out addObjectsFromArray:Buttons(s)];
    return out;
}
static NSButton *ButtonByTitle(NSView *root, NSString *title) {
    for (NSButton *b in Buttons(root)) if ([b.title isEqualToString:title]) return b;
    return nil;
}
static BOOL SawPost(NSString *prefix) {
    for (NSDictionary *p in g_posts) if ([p[@"path"] hasPrefix:prefix]) return YES;
    return NO;
}
static NSNotification *NoteNamed(NSString *name) {
    for (NSNotification *n in g_notes) if ([n.name isEqualToString:name]) return n;
    return nil;
}

@interface RLPAlbumsViewController (EmptyTest)
- (void)reload;
@end
@interface RLPFoldersViewController (EmptyTest)
- (void)loadDir:(NSString *)dir;
@end

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        g_posts = [NSMutableArray array];
        g_notes = [NSMutableArray array];
        [RLPTheme setThemeName:@"light"];
        [RLPTheme setUiStyle:@"apple"];
        [NSNotificationCenter.defaultCenter addObserverForName:nil object:nil queue:nil
            usingBlock:^(NSNotification *n) { [g_notes addObject:n]; }];

        // ---- 1. 专辑页：有 roots 但 0 张专辑 ----
        g_albumsEmpty = YES;
        RLPAlbumsViewController *albums = [RLPAlbumsViewController new];
        NSView *av = albums.view;
        av.frame = NSMakeRect(0, 0, 1200, 800);
        [av layoutSubtreeIfNeeded];
        [albums reload];
        Pump(0.05);
        [av layoutSubtreeIfNeeded];

        NSButton *addBtn = (NSButton *)FindById(av, @"albums.emptyAdd");
        Ck(addBtn != nil, "空态卡有「添加/管理音乐目录」按钮（albums.emptyAdd）", @"按钮缺失");
        Ck(addBtn && ActuallyVisible(addBtn), "0 张专辑时空态卡真实可见", @"空态卡不可见");
        Ck(HasText(av, RLPTr(@"已添加音乐目录，但未找到音频文件")),
           "标题 = 「已添加音乐目录，但未找到音频文件」（有 roots 变体）", @"标题不对");
        Ck(HasText(av, RLPTr(@"当前目录中未发现可识别的音频文件，请确认音频格式或更换目录。")),
           "说明 = web 同文案", @"说明缺失");
        Ck(HasText(av, @"/Music"), "root 路径可见（web .eroot）", @"root 路径缺失");
        if (addBtn) EqStr(addBtn.title, RLPTr(@"管理音乐目录"), "按钮文案 = 管理音乐目录（hasRoots）");
        Ck(ButtonByTitle(av, RLPTr(@"重新扫描")) != nil, "扫描按钮 = 重新扫描（hasRoots）", @"扫描按钮缺失");
        Ck(ButtonByTitle(av, RLPTr(@"打开快速开始")) != nil, "第三入口 = 打开快速开始", @"缺快速开始");

        // 动作：扫描 → /api/lib/scan；管理目录 → 设置 adv；快速开始 → 导航 sq。
        [g_posts removeAllObjects];
        NSButton *scanBtn = ButtonByTitle(av, RLPTr(@"重新扫描"));
        if (scanBtn) [scanBtn performClick:nil];
        Pump(0.02);
        Ck(SawPost(@"/api/lib/scan"), "点「重新扫描」发 /api/lib/scan（web bScan）",
           [g_posts componentsJoinedByString:@" | "]);

        [g_notes removeAllObjects];
        if (addBtn) [addBtn performClick:nil];
        Pump(0.02);
        NSNotification *openSet = NoteNamed(@"RLPOpenSettingsPaneNotification");
        Ck(openSet && [openSet.object isEqualToString:@"adv"],
           "点「管理音乐目录」打开设置·通用（adv，web bEmptyAddRoot）",
           openSet ? [NSString stringWithFormat:@"object=%@", openSet.object] : @"无通知");

        [g_notes removeAllObjects];
        NSButton *stationBtn = ButtonByTitle(av, RLPTr(@"打开快速开始"));
        if (stationBtn) [stationBtn performClick:nil];
        Pump(0.02);
        NSNotification *nav = NoteNamed(@"RLPNavigateKeyNotification");
        Ck(nav && [nav.object isEqualToString:@"sq"],
           "点「打开快速开始」导航到 sq（web emptyGoStation）",
           nav ? [NSString stringWithFormat:@"object=%@", nav.object] : @"无通知");

        // ---- 2. 专辑页：有专辑时空态卡隐藏 ----
        g_albumsEmpty = NO;
        [albums reload];
        Pump(0.05);
        [av layoutSubtreeIfNeeded];
        Ck(addBtn && !ActuallyVisible(addBtn), "有专辑时不再显示空态卡", (addBtn ? @"仍可见" : @"按钮没了"));

        // ---- 3. 专辑页：无 roots 变体 ----
        g_albumsEmpty = YES;
        // 用新 VC 避免缓存 roots：桩 /api/lib/stats 始终返回 /Music，这里只验证「有 roots」分支已覆盖；
        // 「无 roots」分支由 refreshEmptyStateWithRoots:@[] 直接驱动（生产入口）。
        RLPAlbumsViewController *albums2 = [RLPAlbumsViewController new];
        NSView *av2 = albums2.view;
        av2.frame = NSMakeRect(0, 0, 1200, 800);
        NSButton *add2 = (NSButton *)FindById(av2, @"albums.emptyAdd");
        Ck(add2 != nil, "第二个实例也有空态按钮（构造不依赖 reload）", @"缺按钮");
        if (add2) EqStr(add2.title, RLPTr(@"添加音乐目录"),
                       "无 roots 默认文案 = 添加音乐目录（web no-roots 变体）");

        // ---- 4. 文件夹页：空目录显示「此目录没有音频文件」 ----
        g_filesEmpty = YES;
        RLPFoldersViewController *folders = [RLPFoldersViewController new];
        NSView *fv = folders.view;
        fv.frame = NSMakeRect(0, 0, 1200, 800);
        [fv layoutSubtreeIfNeeded];
        [folders loadDir:@"/Music"];
        Pump(0.05);
        [fv layoutSubtreeIfNeeded];
        NSTextField *empty = (NSTextField *)FindById(fv, @"folders.empty");
        Ck(empty != nil && !empty.hidden, "空目录时显示「此目录没有音频文件」",
           empty ? [NSString stringWithFormat:@"hidden=%d", (int)empty.hidden] : @"缺 emptyLabel");
        if (empty) EqStr(empty.stringValue, RLPTr(@"此目录没有音频文件"), "文案 = web 同串");

        // ---- 5. 文件夹页：有文件后收起 ----
        g_filesEmpty = NO;
        [folders loadDir:@"/Music"];
        Pump(0.05);
        Ck(empty && empty.hidden, "有目录/文件后空态收起", [NSString stringWithFormat:@"hidden=%d", (int)empty.hidden]);

        std::printf("结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
