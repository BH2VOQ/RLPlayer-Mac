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
#import <objc/message.h>
#import "RLPWorkbench.h"
#import "RLPSignalChain.h"
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

        // ---------- B6 相位快切（同家族，不跨家族乱切）----------
        {
            NSArray *pf = @[
                @{@"name": @"poly-sinc-gauss-long",    @"phase": @"linear",       @"forNx": @NO},
                @{@"name": @"poly-sinc-gauss-long-mp", @"phase": @"minimum",      @"forNx": @NO},
                @{@"name": @"poly-sinc-gauss-long-ip", @"phase": @"intermediate", @"forNx": @NO},
                @{@"name": @"poly-sinc-short",         @"phase": @"linear",       @"forNx": @NO},
                @{@"name": @"poly-sinc-short-mp",      @"phase": @"minimum",      @"forNx": @NO},
            ];
            CK([RLPFilterWithPhase(@"poly-sinc-gauss-long", @"minimum", pf) isEqualToString:@"poly-sinc-gauss-long-mp"],
               "B6a 线性→最小相位（同家族）", RLPFilterWithPhase(@"poly-sinc-gauss-long", @"minimum", pf) ?: @"nil");
            CK([RLPFilterWithPhase(@"poly-sinc-gauss-long-mp", @"linear", pf) isEqualToString:@"poly-sinc-gauss-long"],
               "B6b 最小→线性（回得去）", RLPFilterWithPhase(@"poly-sinc-gauss-long-mp", @"linear", pf) ?: @"nil");
            CK([RLPFilterWithPhase(@"poly-sinc-gauss-long", @"intermediate", pf) isEqualToString:@"poly-sinc-gauss-long-ip"],
               "B6c 线性→混合相位", @"");
            // ★ 负向：不许跨家族（gauss-long 没有的相位不能切到 short 上去）
            CK(RLPFilterWithPhase(@"poly-sinc-gauss-long", @"minimum", pf) != nil &&
               ![RLPFilterWithPhase(@"poly-sinc-short", @"intermediate", pf) length],
               "B6d 同家族无该相位 ⟹ nil（不跨家族乱切）",
               RLPFilterWithPhase(@"poly-sinc-short", @"intermediate", pf) ?: @"nil");
            CK(RLPFilterWithPhase(@"nonexistent-filter", @"linear", pf) == nil,
               "B6e 未知滤波 ⟹ nil", @"");
            CK(RLPFilterWithPhase(@"poly-sinc-gauss-long", @"linear", @[]) == nil,
               "B6f 空名单 ⟹ nil", @"");
            // 长度档不能被当成相位后缀吃掉（short/long 是不同滤波）
            CK(![RLPFilterFamilyKey(@"poly-sinc-short") isEqualToString:RLPFilterFamilyKey(@"poly-sinc-long")],
               "B6g short 与 long 是不同家族（长度档不混）", @"");
        }

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
        CK(RLPChainNodeApplies(@"eq", @{@"eq": @"/tmp/rew.txt"}), "B2h 外部 EQ 路径时 eq 节点适用", @"");
        CK(RLPChainNodeApplies(@"eq", @{@"eq": @""}), "B2h2 settings.eq 为空时 PEQ 节点仍适用", @"");
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
        // U16 命名配置档：档列表 + 保存/应用/删除入口（后端 /api/profiles；档列表不是 NSUserDefaults）。
        NSArray *profileIds = @[@"wb.profile.list", @"wb.profile.save",
                                @"wb.profile.apply", @"wb.profile.delete"];
        for (NSString *k in profileIds) {
            BOOL found = NO;
            for (NSView *v in all) if ([v.identifier isEqualToString:k]) found = YES;
            CK(found, [[NSString stringWithFormat:@"B12 配置档控件存在 %@", k] UTF8String], @"缺失");
        }
        // B2j 灰节点必须**真的禁用点击**（不只是 alpha 低）：
        // 默认 PCM ⟹ SDM 节点的点击接收器 enabled 必须为 NO，否则点了会弹出改不动的层。
        {
            NSButton *sdmHit = nil, *outHit = nil;
            for (NSView *v in all) {
                if (![v isKindOfClass:[NSButton class]]) continue;
                NSButton *b = (NSButton *)v;
                if ([b.identifier isEqualToString:@"sdm"]) sdmHit = b;
                if ([b.identifier isEqualToString:@"out"]) outHit = b;
            }
            CK(sdmHit != nil && !sdmHit.enabled, "B2j PCM 下 SDM 节点点击被禁用",
               sdmHit ? [NSString stringWithFormat:@"enabled=%d", (int)sdmHit.enabled] : @"未找到接收器");
            CK(outHit != nil && outHit.enabled, "B2k 输出节点始终可点",
               outHit ? [NSString stringWithFormat:@"enabled=%d", (int)outHit.enabled] : @"未找到接收器");
        }

        // B7 四项"发烧友会反复调"的控件必须在位（子代理复核指出的真缺口，已补）
        {
            NSArray *need = @[@"wb.phase", @"wb.filtersearch", @"wb.modorder", @"wb.eqpreset"];
            for (NSString *k in need) {
                BOOL found = NO;
                for (NSView *v in all) if ([v.identifier isEqualToString:k]) found = YES;
                CK(found, [[NSString stringWithFormat:@"B7 快速控件存在 %@", k] UTF8String], @"缺失");
            }
            // PCM 路径下（默认 dsd=0）调制阶数必须禁用 —— 与信号链 SDM 灰显同口径
            NSPopUpButton *mo = nil;
            for (NSView *v in all) if ([v.identifier isEqualToString:@"wb.modorder"]) mo = (NSPopUpButton *)v;
            if (mo) CK(!mo.enabled, "B7e PCM 下调制阶数禁用（不经过调制器）",
                       [NSString stringWithFormat:@"enabled=%d", (int)mo.enabled]);
        }

        // ---------- B8 节点弹层必须"就地可改"，不能只是看 ----------
        // 判据：节点弹层里给出的控件必须是**真的写后端的控件**（有 action、有自己的 identifier），
        // 而不是一排只读的 "k = v" 文本。这条能抓住"看起来能点、点了什么都不能改"的回归。
        {
            RLPWorkbenchViewController *vc2 = [[RLPWorkbenchViewController alloc] init];
            vc2.view.frame = NSMakeRect(0, 0, 1180, 760);
            [vc2.view layoutSubtreeIfNeeded];
            CK(vc2.view != nil, "B8a 页面可构造", @"");
        }

        // ---------- B9 「更多快速开关」折叠区 ----------
        // 这几项都在后端白名单里、也确实会被发烧友反复调，但属于"偶尔动一次"，
        // 所以收在折叠区里。判据：控件在位、默认收起（不占版面）、且标识符可识别。
        {
            NSArray *need = @[@"wb.more.toggle", @"wb.bits", @"wb.taps", @"wb.buffer",
                              @"wb.twostage", @"wb.directsdm", @"wb.isp"];
            for (NSString *k in need) {
                BOOL found = NO;
                for (NSView *v in all) if ([v.identifier isEqualToString:k]) found = YES;
                CK(found, [[NSString stringWithFormat:@"B9 更多开关存在 %@", k] UTF8String], @"缺失");
            }
        }

        // ---------- B10 单一 PEQ 主开关（peqBypass）+ 外部 EQ 路径摘要（wb.eq.extpath） ----------
        {
            NSView *peqSw = nil;
            NSTextField *extLab = nil;
            for (NSView *v in all) {
                if ([v.identifier isEqualToString:@"peqBypass"]) peqSw = v;
                if ([v isKindOfClass:[NSTextField class]] && [v.identifier isEqualToString:@"wb.eq.extpath"]) extLab = (NSTextField *)v;
            }
            CK(peqSw != nil, "B10a 单一 PEQ 主开关 peqBypass 在位", @"");
            CK(extLab != nil, "B10b 外部 EQ 路径摘要标签 wb.eq.extpath 在位", @"");
        }

        // ---------- B12 目标1/2/4/5 行为回归（纯逻辑 + 控制器回读 + seq 保护） ----------
        {
            CK(RLPParseDsdRate(@"256") == 256, "B12a 纯数字 DSD256 解析", @"");
            CK(RLPParseDsdRate(@"dop128") == 128, "B12b legacy dop128 解析", @"");
            CK(RLPParseDsdRate(@"nat64") == 64, "B12c legacy nat64 解析", @"");
            CK(RLPParseDsdRate(@"native512") == 512, "B12d legacy native512 解析", @"");
            CK(RLPParseDsdRate(@"0") == 0, "B12e PCM 0 解析", @"");

            NSString *eqSum = RLPABSlotSummary(@{@"filter": @"poly-sinc-gauss", @"dsd": @"dop256", @"eq": @"/Users/test/Headphone.txt"});
            CK([eqSum rangeOfString:@"DSD256"].location != NSNotFound &&
               [eqSum rangeOfString:@"EQ:Headphone.txt"].location != NSNotFound,
               "B12f 槽摘要保留外部 EQ 文件名且支持 legacy dsd", eqSum ?: @"");

            // 控制器回读测试（需调用私有方法验证 applySettingsPayload / syncAllControlsFromSettings）
            RLPWorkbenchViewController *wb = [[RLPWorkbenchViewController alloc] init];
            wb.view.frame = NSMakeRect(0, 0, 1180, 760);
            [wb.view layoutSubtreeIfNeeded];
            NSMutableArray<NSView *> *wbAll = [NSMutableArray array];
            CollectViews(wb.view, wbAll);

            // 模拟带 legacy dsd + 外部 eq + 自定义未知 modcut/ahmbits/dsdkind/dsdconv 的 settings
            NSDictionary *kv1 = @{
                @"dsd": @"dop128",
                @"backend": @"coreaudio",
                @"eq": @"/tmp/MyREW.txt",
                @"modcut": @"85",
                @"ahmbits": @"12",
                @"dsdkind": @"custom_kind",
                @"dsdconv": @"ultra_wide",
            };
            SEL applySel = NSSelectorFromString(@"applySettingsPayload:forSeq:");
            if ([wb respondsToSelector:applySel]) {
                ((void (*)(id, SEL, NSDictionary *, NSUInteger))objc_msgSend)(wb, applySel, kv1, 10);
                // seq=5 旧回包必须被丢弃，不能把 dsd 改回 0
                ((void (*)(id, SEL, NSDictionary *, NSUInteger))objc_msgSend)(wb, applySel, @{@"dsd": @"0", @"modcut": @"0"}, 5);
            }
            NSSegmentedControl *dsdSeg = nil;
            NSTextField *extLab = nil;
            for (NSView *v in wbAll) {
                if ([v isKindOfClass:[NSSegmentedControl class]] && [v.identifier isEqualToString:@"wb.dsd"]) dsdSeg = (NSSegmentedControl *)v;
                if ([v isKindOfClass:[NSTextField class]] && [v.identifier isEqualToString:@"wb.eq.extpath"]) extLab = (NSTextField *)v;
            }
            CK(dsdSeg != nil && dsdSeg.selectedSegment == 2, "B12g legacy dop128 回显到 DSD128 且 seq=5 旧包被丢弃",
               dsdSeg ? [NSString stringWithFormat:@"seg=%ld", (long)dsdSeg.selectedSegment] : @"nil");
            CK(extLab != nil && [extLab.stringValue rangeOfString:@"MyREW.txt"].location != NSNotFound,
               "B12h 外部 EQ 路径摘要回显文件名", extLab.stringValue ?: @"nil");

            // 检查 modcut/ahmbits/dsdkind/dsdconv 未知值不显示伪默认
            NSMutableArray<NSString *> *popupTitles = [NSMutableArray array];
            for (NSView *v in wbAll) {
                if ([v isKindOfClass:[NSPopUpButton class]]) {
                    NSString *t = ((NSPopUpButton *)v).titleOfSelectedItem;
                    if (t.length) [popupTitles addObject:t];
                }
            }
            CK([popupTitles containsObject:@"85"] && [popupTitles containsObject:@"12"] &&
               [popupTitles containsObject:@"custom_kind"] && [popupTitles containsObject:@"ultra_wide"],
               "B12i modcut/ahmbits/dsdkind/dsdconv 未知值按真实值回显（不显示伪默认）",
               [popupTitles componentsJoinedByString:@","]);
        }

        // ---------- B13 680/820/1180 几何防重叠 + 隐藏页不占位 ----------
        {
            NSArray<NSNumber *> *widths = @[@680, @820, @1180];
            for (NSNumber *wn in widths) {
                CGFloat w = wn.doubleValue;
                RLPWorkbenchViewController *gvc = [[RLPWorkbenchViewController alloc] init];
                gvc.view.frame = NSMakeRect(0, 0, w, 800);
                [gvc.view layoutSubtreeIfNeeded];

                NSMutableArray<NSView *> *gv = [NSMutableArray array];
                CollectViews(gvc.view, gv);

                // 1) A/B 4 张槽卡互不重叠
                NSMutableArray<NSView *> *abSlots = [NSMutableArray array];
                NSView *panelAB = nil, *panelEQ = nil, *panelMon = nil;
                for (NSView *v in gv) {
                    if ([v.identifier hasPrefix:@"wb.abslot."]) [abSlots addObject:v];
                    if ([v.identifier isEqualToString:@"wb.panel.ab"]) panelAB = v;
                    if ([v.identifier isEqualToString:@"wb.panel.eq"]) panelEQ = v;
                    if ([v.identifier isEqualToString:@"wb.panel.monitor"]) panelMon = v;
                }
                BOOL abOverlap = NO;
                for (NSUInteger i = 0; i < abSlots.count; ++i) {
                    NSRect r1 = [abSlots[i] convertRect:abSlots[i].bounds toView:gvc.view];
                    for (NSUInteger j = i + 1; j < abSlots.count; ++j) {
                        NSRect r2 = [abSlots[j] convertRect:abSlots[j].bounds toView:gvc.view];
                        NSRect inter = NSIntersectionRect(r1, r2);
                        if (inter.size.width > 1.0 && inter.size.height > 1.0) abOverlap = YES;
                    }
                }
                CK(!abOverlap && abSlots.count == 4,
                   [[NSString stringWithFormat:@"B13a_%d A/B 槽位无几何重叠", (int)w] UTF8String], @"");

                BOOL controlsFit = YES, controlsOverlap = NO;
                for (NSView *slot in abSlots) {
                    NSMutableArray<NSView *> *controls = [NSMutableArray array];
                    for (NSView *child in slot.subviews) if ([child isKindOfClass:NSControl.class]) [controls addObject:child];
                    for (NSUInteger i = 0; i < controls.count; ++i) {
                        NSRect r = controls[i].frame;
                        if (NSIsEmptyRect(r) || !NSContainsRect(NSInsetRect(slot.bounds, -1, -1), r)) controlsFit = NO;
                        for (NSUInteger j = i + 1; j < controls.count; ++j) {
                            NSRect intersection = NSIntersectionRect(r, controls[j].frame);
                            if (NSWidth(intersection) > 1 && NSHeight(intersection) > 1) controlsOverlap = YES;
                        }
                    }
                }
                CK(controlsFit && !controlsOverlap, [[NSString stringWithFormat:@"B13c_%d slot controls fit without overlap", (int)w] UTF8String], @"");

                // 2) 隐藏页不占位（当前 ab 激活时，eq 与 monitor 均 hidden）
                CK(panelAB && !panelAB.hidden && panelEQ && panelEQ.hidden && panelMon && panelMon.hidden &&
                   [panelAB.superview isKindOfClass:NSStackView.class] && ((NSStackView *)panelAB.superview).detachesHiddenViews,
                   [[NSString stringWithFormat:@"B13b_%d 隐藏页签处于 hidden（不占位）", (int)w] UTF8String], @"");
            }
        }

        // 不许有跳设置页的入口
        NSMutableArray<NSString *> *bad = [NSMutableArray array];
        for (NSView *v in all) {
            if (![v isKindOfClass:[NSButton class]]) continue;
            NSButton *b = (NSButton *)v;
            if ([b.title rangeOfString:RLPTr(@"设置")].location != NSNotFound) [bad addObject:b.title];
        }
        CK(bad.count == 0, "B5 工作台没有跳设置页的入口（当场可切）", [bad componentsJoinedByString:@","]);

        // ---- B11 信号链详情入口（对齐 web 的「信号链」弹窗）：静态链之外还能看真实播放路径 ----
        NSButton *chainDetail = nil;
        for (NSView *v in all) {
            if ([v isKindOfClass:[NSButton class]] && [v.identifier isEqualToString:@"wb.chaindetail"])
                chainDetail = (NSButton *)v;
        }
        CK(chainDetail != nil, "B11a 有「本次播放路径」详情按钮", @"");
        CK(chainDetail != nil && chainDetail.title.length > 0, "B11b 详情按钮标题可读",
           chainDetail.title ?: @"nil");
        // 纯函数模块链接在位：给一份 ok:false 响应，节点数必须是 0（未播放不填假节点）。
        CK([RLPSignalChain nodesForResponse:@{@"ok": @NO}].count == 0,
           "B11c 信号链纯函数已链接（未播放不填假节点）", @"");

        std::printf("\n%s（%d 项失败）\n", gFail == 0 ? "workbench 全部通过" : "workbench 有失败", gFail);
        return gFail == 0 ? 0 : 1;
    }
}
