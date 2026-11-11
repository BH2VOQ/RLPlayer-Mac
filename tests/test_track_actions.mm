// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_track_actions.mm — 曲目动作菜单的完整性判据（1.1.7.1 对齐 web）
//
// 触发原因：web 版任何曲目右键都有四项（加入队列 / 保存到歌单 / 音质体检 / 对比版本），
// 而原生此前曲目页只有两项、专辑详情**完全没有右键菜单**、队列只有两项。
// 这条判据钉住"菜单项齐全"，防止再退化成各页各写一套。
#import <AppKit/AppKit.h>
#import "RLPTrackActions.h"
#import "RLPSupport.h"

#include <cstdio>

static int gFail = 0, gPass = 0;
static void CK(BOOL ok, const char *what, NSString *detail) {
    if (ok) { ++gPass; std::printf("  [PASS] %s\n", what); }
    else { ++gFail; std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); }
}
static BOOL HasItem(NSMenu *m, NSString *title) {
    for (NSMenuItem *it in m.itemArray)
        if ([it.title isEqualToString:RLPTr(title)]) return YES;
    return NO;
}
static NSMenuItem *ItemFor(NSMenu *m, NSString *title) {
    for (NSMenuItem *it in m.itemArray)
        if ([it.title isEqualToString:RLPTr(title)]) return it;
    return nil;
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        (void)app;
        std::printf("=== test_track_actions（曲目右键菜单对齐 web）===\n");

        // ---- 本地文件：四项核心动作都必须在 ----
        NSMenu *m = RLPTrackMenuForPath(@"/music/a.flac", nil, nil, nil);
        CK(m != nil, "T1 本地曲目能生成菜单", @"nil");
        for (NSString *t in @[@"播放", @"加入播放队列", @"收藏", @"保存到歌单…", @"音质体检…", @"对比同目录版本…", @"AI 补全资料"])
            CK(HasItem(m, t), [[NSString stringWithFormat:@"T2 菜单含 %@", t] UTF8String], @"缺失");

        // ---- 网络曲目：体检/对比必须**不出现**（后端没有本地路径，摆出来只会失败）----
        NSMenu *net = RLPTrackMenuForPath(@"https://x/y.mp3", nil, nil, nil);
        CK(net != nil, "T3 网络曲目也有菜单", @"nil");
        CK(!HasItem(net, @"音质体检…"), "T4 网络曲目不显示音质体检", @"出现了");
        CK(!HasItem(net, @"对比同目录版本…"), "T5 网络曲目不显示版本对比", @"出现了");
        CK(HasItem(net, @"加入播放队列"), "T6 网络曲目仍可入队", @"缺失");
        CK(!HasItem(net, @"AI 补全资料"), "T6b 网络曲目不显示 AI 补全（需本地文件）", @"出现了");

        // ---- 空路径：不生成菜单（不摆一个点了没反应的壳）----
        CK(RLPTrackMenuForPath(nil, nil, nil, nil) == nil, "T7 空路径 ⟹ 无菜单", @"");
        CK(RLPTrackMenuForPath(@"", nil, nil, nil) == nil, "T8 空串 ⟹ 无菜单", @"");

        // ---- 每项都带路径与 tag（分派靠它们，漏了就点了没反应）----
        for (NSMenuItem *it in m.itemArray) {
            if (it.isSeparatorItem) continue;
            CK([it.representedObject isEqual:@"/music/a.flac"],
               [[NSString stringWithFormat:@"T9 项带路径：%@", it.title] UTF8String], @"");
            CK(it.tag >= RLPTrackActionPlay && it.tag <= RLPTrackActionEnrich,
               [[NSString stringWithFormat:@"T10 项带合法 tag：%@", it.title] UTF8String],
               [NSString stringWithFormat:@"tag=%ld", (long)it.tag]);
        }

        // ---- 移除项只在调用方要求时出现 ----
        CK(!HasItem(m, @"从队列移除"), "T11 未要求时不出现移除项", @"出现了");
        NSMenu *mq = RLPTrackMenuForPath(@"/music/a.flac", nil, nil, @selector(description));
        CK(HasItem(mq, @"从队列移除"), "T12 要求时出现移除项", @"缺失");

        // ---- 分派：入队/播放这类不需要 UI 的动作要能被处理 ----
        NSMenuItem *enq = ItemFor(m, @"加入播放队列");
        CK(enq != nil && enq.tag == RLPTrackActionEnqueue, "T13 入队项 tag 正确", @"");

        std::printf("\n%s（%d 项失败）\n", gFail == 0 ? "track_actions 全部通过" : "track_actions 有失败", gFail);
        return gFail == 0 ? 0 : 1;
    }
}
