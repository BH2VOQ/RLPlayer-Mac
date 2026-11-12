// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_artist_grid.mm — 艺术家网格与专辑曲目表的几何判据（2026-11-12 用户实测反馈）
//
// 三次真故障，全部是「能构造但布局错」，只有量几何才抓得住：
//   ① 艺术家卡原来是 48pt 小头像 + 右侧一行文字，与 web 大圆头像网格差太远；
//   ② 专辑表六列宽度全写死，多余宽度被 NSTableView 均摊 ⟹ 图标与曲目对不齐；
//   ③ 我第一次修列宽时把艺术家列拉宽，结果时长与「+」被挤出可视区（截图里时长变 0）。
// 判据只量几何，不连网络、不出声。
#import <AppKit/AppKit.h>
#import "RLPArtistsViewController.h"
#import "RLPAlbumDetailViewController.h"
#import "RLPPlaybackBarView.h"
#import "RLPCoreClient.h"
#import "RLPTheme.h"

#include <cstdio>

static int gFail = 0, gPass = 0;
static void CK(BOOL ok, const char *what, NSString *detail) {
    if (ok) { ++gPass; std::printf("  [PASS] %s\n", what); }
    else { ++gFail; std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); }
}
static void CollectViews(NSView *v, NSMutableArray<NSView *> *out) {
    if (!v) return;
    [out addObject:v];
    for (NSView *s in v.subviews) CollectViews(s, out);
}
static NSView *FindById(NSView *root, NSString *ident) {
    NSMutableArray<NSView *> *all = [NSMutableArray array];
    CollectViews(root, all);
    for (NSView *v in all) if ([v.identifier isEqualToString:ident]) return v;
    return nil;
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        std::printf("=== test_artist_grid（几何判据，离线）===\n");

        // ---- A1 艺术家卡片必须是大圆头像（≥100pt），不是小图标行 ----
        RLPArtistsViewController *av = [[RLPArtistsViewController alloc] init];
        av.view.frame = NSMakeRect(0, 0, 1180, 760);
        [av.view layoutSubtreeIfNeeded];
        [av activate];
        [av.view layoutSubtreeIfNeeded];
        CK(av.view != nil, "A1a 艺术家页可离线构建", @"");

        // 网格必须真实存在且卡片尺寸够大（量 collectionView 的 itemSize）
        NSCollectionView *cv = nil;
        NSMutableArray<NSView *> *allA = [NSMutableArray array];
        CollectViews(av.view, allA);
        for (NSView *v in allA) if ([v isKindOfClass:[NSCollectionView class]]) { cv = (NSCollectionView *)v; break; }
        CK(cv != nil, "A1b 有网格视图", @"");
        if (cv && [cv.collectionViewLayout isKindOfClass:[NSCollectionViewFlowLayout class]]) {
            NSCollectionViewFlowLayout *fl = (NSCollectionViewFlowLayout *)cv.collectionViewLayout;
            CK(fl.itemSize.height >= 180,
               "A1c 卡片高度 ≥180pt（大圆头像卡，不是 74pt 小行）",
               [NSString stringWithFormat:@"h=%.1f", fl.itemSize.height]);
            CK(fl.itemSize.width >= 150,
               "A1d 卡片宽度 ≥150pt", [NSString stringWithFormat:@"w=%.1f", fl.itemSize.width]);
            CK(fl.minimumInteritemSpacing >= 12,
               "A1e 卡间距 ≥12pt（留白呼吸）",
               [NSString stringWithFormat:@"gap=%.1f", fl.minimumInteritemSpacing]);
        }

        // ---- A2 专辑曲目表：右侧固定列不得被挤出可视区 ----
        RLPAlbumDetailViewController *dv =
            [[RLPAlbumDetailViewController alloc] initWithAlbumKey:@"x"];
        dv.view.frame = NSMakeRect(0, 0, 1180, 760);
        [dv.view layoutSubtreeIfNeeded];
        [dv activate];
        [dv.view layoutSubtreeIfNeeded];
        CK(dv.view != nil, "A2a 专辑详情可离线构建", @"");

        NSTableView *tv = nil;
        NSMutableArray<NSView *> *allD = [NSMutableArray array];
        CollectViews(dv.view, allD);
        for (NSView *v in allD) if ([v isKindOfClass:[NSTableView class]]) { tv = (NSTableView *)v; break; }
        CK(tv != nil, "A2b 有曲目表", @"");
        if (tv) {
            CK(tv.numberOfColumns == 6, "A2c 六列齐全（序号/收藏/曲名/艺术家/时长/入队）",
               [NSString stringWithFormat:@"n=%ld", (long)tv.numberOfColumns]);
            // 关键：所有列宽之和必须 ≤ 表格可视宽度，否则最右列被裁掉。
            CGFloat sum = 0;
            for (NSTableColumn *c in tv.tableColumns) sum += c.width;
            const CGFloat avail = tv.bounds.size.width;
            CK(sum <= avail + 2.0,
               "A2d 列宽总和不超出表格宽度（最右「+」列不会被裁）",
               [NSString stringWithFormat:@"sum=%.1f avail=%.1f", sum, avail]);
            // 每一列都必须有正宽度（0 宽 = 被挤没了，正是我第二版改坏的症状）
            BOOL allPositive = YES;
            NSMutableString *zero = [NSMutableString string];
            for (NSTableColumn *c in tv.tableColumns) {
                if (c.width < 20) {
                    allPositive = NO;
                    [zero appendFormat:@"%@=%.1f ", c.identifier, c.width];
                }
            }
            CK(allPositive, "A2e 没有列被压成 0 宽（时长/加号必须可见）", zero);
            // 曲名列是唯一吸收窗口宽度的列：它必须是弹性列
            BOOL titleFlexible = NO;
            for (NSTableColumn *c in tv.tableColumns)
                if ([c.identifier isEqualToString:@"title"] &&
                    (c.resizingMask & NSTableColumnAutoresizingMask)) titleFlexible = YES;
            CK(titleFlexible, "A2f 曲名列是弹性列（其余列宽恒定 ⟹ 图标位置稳定）", @"");
        }

        // ---- A3 播放条：控制键组必须居中（不是硬编码 x=250 偏左） ----
        RLPPlaybackBarView *bar = [[RLPPlaybackBarView alloc] initWithFrame:NSMakeRect(0, 0, 1180, 66)];
        [bar layoutSubtreeIfNeeded];
        bar.frame = NSMakeRect(0, 0, 1180, 66);
        [bar layout];
        NSMutableArray<NSView *> *allB = [NSMutableArray array];
        CollectViews(bar, allB);
        NSButton *play = nil;
        for (NSView *v in allB) {
            if ([v isKindOfClass:[NSButton class]]) {
                NSButton *b = (NSButton *)v;
                if (b.frame.size.width >= 40 && b.frame.size.height >= 40) { play = b; break; }
            }
        }
        CK(play != nil, "A3a 播放条有 44pt 主按钮", @"");
        if (play) {
            const CGFloat mid = NSMidX(play.frame);
            const CGFloat center = 1180 / 2.0;
            CK(fabs(mid - center) < 120,
               "A3b 主按钮接近窗口中线（控制键组居中，不再硬编码偏左）",
               [NSString stringWithFormat:@"mid=%.1f center=%.1f", mid, center]);
        }

        std::printf("\n%s（%d 项失败）\n", gFail == 0 ? "artist_grid 全部通过" : "artist_grid 有失败", gFail);
        return gFail == 0 ? 0 : 1;
    }
}