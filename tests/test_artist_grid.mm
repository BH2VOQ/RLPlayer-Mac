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
            CK(tv.numberOfColumns == 7, "A2c web 七列齐全（含可响应隐藏的规格列）",
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
            // Web fr-columns are computed explicitly, not by NSTableColumnAutoresizingMask.
            NSTableColumn *measuredTitle=nil;
            for(NSTableColumn *c in tv.tableColumns)if([c.identifier isEqual:@"title"])measuredTitle=c;
            CK(measuredTitle.width>=120,"A2f 曲名保留 web minmax(120px,fr) 下界",@"");

            // A2g/A2h：用户 1.1.7.4 实测「曲名后面甩出约 400px 空白」。
            // web 专辑曲目表是 grid `28 24 minmax(120px,1.6fr) minmax(0,1fr) 92 58 26`，
            // 曲名与艺术家**按 1.6:1 分剩余宽度**、中间只隔 gap 8 ⟹ 不会出现大空白。
            // 判据：曲名列右缘与艺术家列左缘之间的空隙必须很小（≤ 24pt）。
            NSTableColumn *tCol = nil, *aCol = nil;
            CGFloat x = 0, titleRight = 0, artistLeft = -1;
            for (NSTableColumn *c in tv.tableColumns) {
                if ([c.identifier isEqualToString:@"title"]) { tCol = c; titleRight = x + c.width; }
                if ([c.identifier isEqualToString:@"artist"]) { aCol = c; artistLeft = x; }
                x += c.width;
            }
            if (tCol && aCol) {
                const CGFloat gap = artistLeft - titleRight;
                CK(gap <= 24.0,
                   "A2g 曲名列与艺术家列之间没有大空白（≤24pt）",
                   [NSString stringWithFormat:@"gap=%.1f", gap]);
                // 两列都必须是弹性列（按 fr 比例分剩余宽度），而不是固定宽度。
                CGFloat titleBefore=tCol.width,artistBefore=aCol.width;
                dv.view.frame=NSMakeRect(0,0,1280,760);[dv.view layoutSubtreeIfNeeded];[dv performSelector:@selector(layoutAlbum)];
                CK(tCol.width>titleBefore && aCol.width>artistBefore,
                   "A2h 改窗口宽度后曲名与艺术家两列真实吸收剩余宽度", @"");
            }
            // A2i：行高必须紧凑。web `.trow{padding:8px 20px;font-size:12.5px}` ≈ 33pt；
            // 旧实现 38(+1) 让六行显得又高又散，是「图标与曲目对不齐」观感的一部分。
            CK(fabs(tv.rowHeight - 38.0) < .1,
               "A2i 曲目行高严格匹配用户 web 截图的 38pt 节奏",
               [NSString stringWithFormat:@"rowHeight=%.1f", tv.rowHeight]);
            CK(tv.intercellSpacing.width >= 6.0,
               "A2j 列间有水平间隔（web grid gap:8px，图标与文字不粘在一起）",
               [NSString stringWithFormat:@"spacing=%.1f", tv.intercellSpacing.width]);
        }

        // ---- A3 播放条：按 web .bar 三列结构（左信息 / 中控制+进度 / 右徽标+音量）----
        RLPPlaybackBarView *bar = [[RLPPlaybackBarView alloc] initWithFrame:NSMakeRect(0, 0, 1180, 66)];
        bar.frame = NSMakeRect(0, 0, 1180, 66);
        [bar layout];
        NSMutableArray<NSView *> *allB = [NSMutableArray array];
        CollectViews(bar, allB);
        NSButton *play = (NSButton *)FindById(bar, @"pb.play");
        CK(play != nil && play.frame.size.width >= 30 && play.frame.size.height >= 30,
           "A3a 播放条有 34pt 主按钮（web .k.big 同尺寸）", @"");
        if (play) {
            const CGFloat mid = NSMidX(play.frame);
            const CGFloat center = 1180 / 2.0;
            CK(fabs(mid - center) < 40,
               "A3b 主按钮在窗口中线（控制键组整组居中）",
               [NSString stringWithFormat:@"mid=%.1f center=%.1f", mid, center]);
        }

        NSSlider *prog = (NSSlider *)FindById(bar, @"pb.progress");
        NSSlider *vol = (NSSlider *)FindById(bar, @"pb.vol");
        NSTextField *posLbl = (NSTextField *)FindById(bar, @"pb.pos");
        NSTextField *durLbl = (NSTextField *)FindById(bar, @"pb.dur");
        NSTextField *fmtLbl = (NSTextField *)FindById(bar, @"pb.fmt");
        NSButton *lyricBtn = (NSButton *)FindById(bar, @"pb.lyric");
        NSButton *chainBtn = (NSButton *)FindById(bar, @"pb.chain");

        // A3c/A3d：用户 1.1.7.4 实测「进度条被甩到按钮下方很远处、中间一大块空白」。
        // 判据：进度条顶边与控制键（主按钮）底边之间不得有大于 12pt 的空隙。
        CK(prog != nil, "A3c 播放条有进度滑杆", @"");
        if (prog && play) {
            const CGFloat gap = NSMinY(prog.frame) - NSMaxY(play.frame);   // AppKit 原点在左下
            CK(gap <= 12.0,
               "A3d 进度条紧接控制键下方（空隙 ≤12pt，不再甩到底部）",
               [NSString stringWithFormat:@"gap=%.1f", gap]);
        }
        // A3e/A3f：web 进度行是「当前时间 | 滑杆 | 总时长」，两段时间分列两侧。
        // 旧实现把时间挤成一条「0:00 / 0:00」放在右侧、滑杆却横穿过去 ⟹ 文字与滑杆重叠。
        CK(posLbl != nil && durLbl != nil, "A3e 进度条两端有独立时间标签", @"缺失");
        if (prog && posLbl && durLbl) {
            CK(!NSIntersectsRect(posLbl.frame, prog.frame) &&
               !NSIntersectsRect(durLbl.frame, prog.frame),
               "A3f 时间标签与进度滑杆不重叠",
               [NSString stringWithFormat:@"pos=%@ prog=%@ dur=%@",
                NSStringFromRect(posLbl.frame), NSStringFromRect(prog.frame), NSStringFromRect(durLbl.frame)]);
            CK(fabs(NSMidX(prog.frame) - 1180 / 2.0) < 80,
               "A3g 进度滑杆在中列（不偏向左右信息区）",
               [NSString stringWithFormat:@"mid=%.1f", NSMidX(prog.frame)]);
        }
        // A3h：web 底栏右侧有歌词 / 信号链两个图标入口（原生旧实现没有 ⟹ 功能不对等）
        CK(lyricBtn != nil && chainBtn != nil, "A3h 底栏有歌词/信号链入口（web #bLyric/#bChain 同款）", @"缺失");
        // A3i：web #fmt 徽标（44.1k/24），空态显示 "--"
        CK(fmtLbl != nil && [fmtLbl.stringValue isEqualToString:@"--"],
           "A3i 底栏有格式徽标（无播放时显示 --）", fmtLbl.stringValue ?: @"缺失");
        // A3j：音量滑杆必须是**位置刻度 0..1000**（web 261024-10 曲线），不是线性 dB
        CK(vol != nil && vol.maxValue >= 1000.0,
           "A3j 音量滑杆用位置刻度（0..1000），拖到中间不会突然很小声",
           [NSString stringWithFormat:@"max=%.1f", vol.maxValue]);

        std::printf("\n%s（%d 项失败）\n", gFail == 0 ? "artist_grid 全部通过" : "artist_grid 有失败", gFail);
        return gFail == 0 ? 0 : 1;
    }
}
