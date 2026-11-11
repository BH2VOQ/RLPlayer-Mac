// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_workbench.mm — 专业工作台的判据（1.1.7.1）
//
// 用户要求：专业模式要看得出专业 —— 信号链、快速 EQ/滤波/升频/输出切换，
// 以及「同一首歌挂不同滤波与升频规格，存成多套配置，左右点着就能切、当场对比」。
// 装饰性 UI（黑胶唱片那类）一律不要。
//
// 判据能证明真东西的关键：
//   B3a A/B 快照**绝不能含 device/backend/hogexcl** —— 含了就会在 A/B 时切输出设备、
//       抢独占、爆音。这条是安全性判据，故意写错的实现必须跑红。
//   B2  不适用的信号链节点必须真的灰掉（PCM 路径下的 SDM、DoP 下的 shaper）。
#import <AppKit/AppKit.h>
#import "RLPWorkbench.h"
#import "RLPWorkbenchViewController.h"
#import "RLPSupport.h"

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
static NSArray<NSDictionary *> *FakeFilters(void) {
    return @[
        @{@"name": @"poly-sinc-tight-lp",      @"taps": @4095,  @"forNx": @NO,  @"phaseName": @"线性相位"},
        @{@"name": @"poly-sinc-gauss-long",    @"taps": @32767, @"forNx": @NO,  @"phaseName": @"线性相位"},
        @{@"name": @"poly-sinc-gauss-hires-lp",@"taps": @65535, @"forNx": @YES, @"phaseName": @"线性相位"},
        @{@"name": @"sinc-L",                  @"taps": @8192,  @"forNx": @NO,  @"phaseName": @"线性相位"},
        @{@"name": @"ext2-fast",               @"taps": @2048,  @"forNx": @NO,  @"phaseName": @"最小相位"},
        @{@"name": @"weird-one",               @"taps": @100,   @"forNx": @NO,  @"phaseName": @"线性相位"},
    ];
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        (void)app;
        std::printf("=== test_workbench（专业工作台）===\n");

        NSDictionary *full = @{
            @"filter": @"poly-sinc-tight-lp", @"rate": @"176400", @"dsd": @"0",
            @"shaper": @"auto", @"bits": @"0", @"eq": @"1", @"taps": @"512",
            @"modfamily": @"ec", @"modorder": @"7",
            // 下面三个是**危险键**：绝不能进 A/B 快照
            @"device": @"USB-DAC-1", @"backend": @"coreaudio", @"hogexcl": @"1",
            @"volume": @"-19", @"theme": @"light",
        };

        // ---------- B3 A/B 槽位 ----------
        NSDictionary *snap = RLPABSnapshotFromSettings(full);
        NSArray *danger = @[@"device", @"backend", @"hogexcl"];
        for (NSString *k in danger)
            CK(snap[k] == nil,
               [[NSString stringWithFormat:@"B3a 快照不含危险键 %@", k] UTF8String],
               snap[k] ?: @"");
        CK([snap[@"filter"] isEqualToString:@"poly-sinc-tight-lp"] &&
           [snap[@"rate"] isEqualToString:@"176400"] && [snap[@"eq"] isEqualToString:@"1"],
           "B3b 快照含听感相关键", snap.description);
        // 往返一致
        NSString *body = RLPABFormBody(snap);
        CK([body rangeOfString:@"filter=poly-sinc-tight-lp"].location != NSNotFound &&
           [body rangeOfString:@"rate=176400"].location != NSNotFound,
           "B3c 序列化成表单串", body);
        for (NSString *k in danger)
            CK([body rangeOfString:[k stringByAppendingString:@"="]].location == NSNotFound,
               [[NSString stringWithFormat:@"B3d 表单串不含 %@", k] UTF8String], body);
        CK([RLPABFormBody(@{}) isEqualToString:@""], "B3e 空快照 ⟹ 空串", @"");
        // 匹配
        // 槽 2 用**真实存法**构造（改两个听感键后再抓快照），而不是手写一个只有 2 键的残缺槽：
        // 真实槽永远是 RLPABSnapshotFromSettings 的产物（全键），残缺槽是测试自己造的假数据。
        NSMutableDictionary *alt = [full mutableCopy];
        alt[@"filter"] = @"poly-sinc-gauss-long";
        alt[@"rate"] = @"follow";
        NSDictionary *snap2 = RLPABSnapshotFromSettings(alt);
        NSArray *slots = @[snap, @{}, snap2];
        CK(RLPABMatchSlot(full, slots) == 0, "B3f 全等 ⟹ 命中槽 0", @"");
        CK(RLPABMatchSlot(alt, slots) == 2, "B3g 改成槽 2 的值 ⟹ 命中槽 2", @"");
        // 部分键相等**不算命中**（否则会把"只改了滤波"误判成"切到了 B"）
        CK(RLPABMatchSlot(@{@"filter": @"poly-sinc-gauss-long"}, slots) == -1,
           "B3g2 残缺设置不误判命中", @"");
        NSMutableDictionary *other = [full mutableCopy];
        other[@"filter"] = @"something-else";
        CK(RLPABMatchSlot(other, slots) == -1, "B3h 都不等 ⟹ 自定义(-1)", @"");
        CK(RLPABMatchSlot(full, @[@{}, @{}]) == -1, "B3i 空槽不参与匹配", @"");
        // 危险键变化不该影响命中（因为它们本来就不在快照里）
        NSMutableDictionary *devChanged = [full mutableCopy];
        devChanged[@"device"] = @"Another-DAC";
        CK(RLPABMatchSlot(devChanged, slots) == 0, "B3j 换设备不影响 A/B 命中", @"");
        CK([RLPABSlotSummary(@{}) isEqualToString:RLPTr(@"未保存")], "B3k 空槽摘要=未保存", RLPABSlotSummary(@{}));
        CK(RLPABSlotSummary(snap).length > 0, "B3l 槽摘要非空", RLPABSlotSummary(snap));

        // ---------- B4 滤波分组（不丢项）----------
        NSArray<NSDictionary *> *fs = FakeFilters();
        NSArray<NSDictionary *> *groups = RLPFilterGroups(fs);
        NSInteger total = 0;
        BOOL gaussOK = YES;
        for (NSDictionary *g in groups) {
            NSArray *items = g[@"items"];
            total += items.count;
            if ([g[@"group"] isEqualToString:@"gauss"])
                for (NSDictionary *it in items)
                    if ([it[@"name"] rangeOfString:@"gauss"].location == NSNotFound) gaussOK = NO;
        }
        CK(total == (NSInteger)fs.count, "B4a 分组不丢项", [NSString stringWithFormat:@"%ld vs %ld", (long)total, (long)fs.count]);
        CK(gaussOK, "B4b gauss 组全部含 gauss", @"");
        BOOL nxFound = NO;
        for (NSDictionary *it in fs) if (RLPWorkbenchFilterUsesNx(it)) nxFound = YES;
        CK(nxFound, "B4c forNx 项被识别（要写 filterNx 键）", @"");

        // ---------- B2 信号链节点适用性 ----------
        CK(!RLPChainNodeApplies(@"sdm", full), "B2a PCM 路径下 SDM 节点不适用", @"");
        CK(RLPChainNodeDisabledReason(@"sdm", full).length > 0, "B2b 不适用必须给原因", @"");
        NSDictionary *dsdSet = @{@"dsd": @"256", @"rate": @"follow", @"eq": @"1"};
        CK(RLPChainNodeApplies(@"sdm", dsdSet), "B2c DSD 路径下 SDM 适用", @"");
        CK(!RLPChainNodeApplies(@"shaper", dsdSet), "B2d DoP 路径下 shaper 不适用（强制无抖动）", @"");
        CK(RLPChainNodeApplies(@"shaper", full), "B2e PCM 路径下 shaper 适用", @"");
        CK(!RLPChainNodeApplies(@"resample", @{@"dsd": @"0", @"rate": @"follow"}),
           "B2f 跟随源时重采样节点不适用", @"");
        CK(RLPChainNodeApplies(@"resample", full), "B2g 指定采样率时重采样适用", @"");
        CK(!RLPChainNodeApplies(@"eq", @{@"eq": @"0"}), "B2h EQ 旁路时不适用", @"");
        CK(RLPChainNodeApplies(@"src", full) && RLPChainNodeApplies(@"out", full),
           "B2i 源与输出节点恒适用", @"");

        // ---------- B1/B5 页面契约 ----------
        RLPWorkbenchViewController *vc = [[RLPWorkbenchViewController alloc] init];
        vc.view.frame = NSMakeRect(0, 0, 1180, 760);
        [vc.view layoutSubtreeIfNeeded];
        CK(vc.view != nil, "B1a 工作台可离线构建（无核心不崩）", @"");
        CK([vc.pageTitle isEqualToString:RLPTr(@"专业工作台")], "B1b 标题是「专业工作台」", vc.pageTitle ?: @"nil");

        NSMutableArray<NSView *> *all = [NSMutableArray array];
        CollectViews(vc.view, all);
        NSArray *nodes = @[@"wb.node.src", @"wb.node.resample", @"wb.node.eq",
                           @"wb.node.ir", @"wb.node.shaper", @"wb.node.sdm", @"wb.node.out"];
        for (NSString *k in nodes) {
            BOOL found = NO;
            for (NSView *v in all) if ([v.identifier isEqualToString:k]) found = YES;
            CK(found, [[NSString stringWithFormat:@"B1c 信号链节点存在 %@", k] UTF8String], @"缺失");
        }
        // A/B 槽位控件必须在位
        NSArray *abIds = @[@"wb.ab.0", @"wb.ab.1", @"wb.ab.toggle"];
        for (NSString *k in abIds) {
            BOOL found = NO;
            for (NSView *v in all) if ([v.identifier isEqualToString:k]) found = YES;
            CK(found, [[NSString stringWithFormat:@"B1d A/B 控件存在 %@", k] UTF8String], @"缺失");
        }
        // 不许有跳设置页的入口
        NSMutableArray<NSString *> *bad = [NSMutableArray array];
        for (NSView *v in all) {
            if (![v isKindOfClass:[NSButton class]]) continue;
            NSButton *b = (NSButton *)v;
            if ([b.title rangeOfString:RLPTr(@"设置")].location != NSNotFound) [bad addObject:b.title];
        }
        CK(bad.count == 0, "B5 工作台没有跳设置页的入口（当场可切）", [bad componentsJoinedByString:@","]);

        std::printf("\n%s（%d 项失败）\n", gFail == 0 ? "workbench 全部通过" : "workbench 有失败", gFail);
        return gFail == 0 ? 0 : 1;
    }
}
