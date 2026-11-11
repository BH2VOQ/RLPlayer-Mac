// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_analysis_row.mm — 播放页「音频分析一行」的判据（1.1.7.1）
//
// 用户要求：分析从两行改成一行，行内就是「动态 / 音质 / 假无损 / 展开」四个东西；
// 自动分析挪到设置里；重新分析不摆在面上。
//
// 判据分两层：
//   ① 摘要判读是**纯函数**，用构造的 health 字典钉住全部边界（含"不许用 snr_db"这条负向判据）；
//   ② 一行几何 + 面上没有自动分析开关/重新分析按钮（遍历真实视图树）。
// 纪律：几何判据先断言"量到了"（width>0），把"没量到"与"量到了但不合格"分成两种结论，
// 否则未布局时 frame 全 0 会假红（本项目已踩过一次）。
#import <AppKit/AppKit.h>
#import "RLPAnalysisSummary.h"
#import "RLPNowPlayingViewController.h"
#import "RLPSupport.h"

#include <cstdio>

static int gFail = 0, gPass = 0;
static void CK(BOOL ok, const char *what, NSString *detail) {
    if (ok) { ++gPass; std::printf("  [PASS] %s\n", what); }
    else { ++gFail; std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); }
}
static BOOL Has(NSString *s, NSString *sub) {
    return s.length && sub.length && [s rangeOfString:sub].location != NSNotFound;
}

static void CollectViews(NSView *v, NSMutableArray<NSView *> *out) {
    if (!v) return;
    [out addObject:v];
    for (NSView *s in v.subviews) CollectViews(s, out);
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        (void)app;
        std::printf("=== test_analysis_row（音频分析一行）===\n");

        // ---------- ① 动态摘要：DR 四档边界必须精确 ----------
        CK(Has(RLPAnlSumDyn(@{@"dr_available": @NO, @"dr_db": @20}), @"不适用"),
           "C1a dr_available=false ⟹ 动态不适用", RLPAnlSumDyn(@{@"dr_available": @NO, @"dr_db": @20}));
        CK(Has(RLPAnlSumDyn(@{}), @"不适用"), "C1b dr_db 缺失 ⟹ 不适用（不当 0）", RLPAnlSumDyn(@{}));
        CK(Has(RLPAnlSumDyn(@{@"dr_db": @14}), @"良好动态"), "C1c dr=14 ⟹ 良好动态（边界）", RLPAnlSumDyn(@{@"dr_db": @14}));
        CK(Has(RLPAnlSumDyn(@{@"dr_db": @13.9}), @"中等动态"), "C1d dr=13.9 ⟹ 中等动态", RLPAnlSumDyn(@{@"dr_db": @13.9}));
        CK(Has(RLPAnlSumDyn(@{@"dr_db": @11}), @"中等动态"), "C1e dr=11 ⟹ 中等动态（边界）", RLPAnlSumDyn(@{@"dr_db": @11}));
        CK(Has(RLPAnlSumDyn(@{@"dr_db": @8}), @"动态偏紧"), "C1f dr=8 ⟹ 动态偏紧（边界）", RLPAnlSumDyn(@{@"dr_db": @8}));
        CK(Has(RLPAnlSumDyn(@{@"dr_db": @7}), @"低动态"), "C1g dr=7 ⟹ 低动态", RLPAnlSumDyn(@{@"dr_db": @7}));

        // ---------- ② 音质摘要 ----------
        CK(Has(RLPAnlSumQual(@{@"quality": @{@"available": @NO}}), @"样本不足"),
           "C1h quality.available=false ⟹ 样本不足", RLPAnlSumQual(@{@"quality": @{@"available": @NO}}));
        NSDictionary *qOK = @{@"available": @YES, @"peak_dbfs_q": @-1.0, @"rms_dbfs": @-20.0};
        CK(Has(RLPAnlSumQual(@{@"quality": @{@"available": @YES}}), @"无有效音频"),
           "C1i 缺 peak/rms ⟹ 无有效音频（静音里 0 削波无意义）", RLPAnlSumQual(@{@"quality": @{@"available": @YES}}));
        {
            NSMutableDictionary *q = [qOK mutableCopy]; q[@"clipped_samples"] = @0;
            CK(Has(RLPAnlSumQual(@{@"quality": q}), @"干净"), "C1j clipped=0 ⟹ 干净", RLPAnlSumQual(@{@"quality": q}));
        }
        {
            NSMutableDictionary *q = [qOK mutableCopy];
            q[@"clipped_samples"] = @50; q[@"clipped_runs"] = @3; q[@"longest_clip_run"] = @5;
            NSString *s = RLPAnlSumQual(@{@"quality": q});
            CK(Has(s, @"有削波") && Has(s, @"5"), "C1k runs>0 且 longest>=3 ⟹ 有削波·最长 5", s);
        }
        {
            NSMutableDictionary *q = [qOK mutableCopy];
            q[@"clipped_samples"] = @9; q[@"clipped_runs"] = @2; q[@"longest_clip_run"] = @2;
            NSString *s = RLPAnlSumQual(@{@"quality": q});
            CK(Has(s, @"轻微削波") && Has(s, @"9"), "C1l longest=2 ⟹ 轻微削波·9 样本", s);
        }
        // ★ 负向判据：snr_db 不许影响音质摘要（压缩过的流行乐天然 15~20 dB，那是动态小不是噪声大）
        {
            NSMutableDictionary *a = [qOK mutableCopy]; a[@"clipped_samples"] = @0; a[@"snr_db"] = @16.0;
            NSMutableDictionary *b = [qOK mutableCopy]; b[@"clipped_samples"] = @0; b[@"snr_db"] = @90.0;
            NSString *sa = RLPAnlSumQual(@{@"quality": a});
            NSString *sb = RLPAnlSumQual(@{@"quality": b});
            CK([sa isEqualToString:sb], "C1m snr_db 不同但摘要必须相同（不许用 SNR 判本底）",
               [NSString stringWithFormat:@"%@ vs %@", sa, sb]);
        }

        // ---------- ③ 假无损摘要 ----------
        CK(Has(RLPAnlSumFake(@{@"status": @"running"}), @"分析未完成"),
           "C1n status!=ready ⟹ 分析未完成", RLPAnlSumFake(@{@"status": @"running"}));
        {
            NSString *s = RLPAnlSumFake(@{@"status": @"ready", @"lossless_suspected": @YES, @"cutoff_hz": @16000});
            CK(Has(s, @"疑似有损转码") && Has(s, @"16.0"), "C1o 疑似有损 + 截止 16.0 kHz", s);
        }
        {
            NSString *s = RLPAnlSumFake(@{@"status": @"ready", @"lossless_suspected": @NO,
                                          @"cutoff_hz": @21000, @"fs": @44100});
            CK(Has(s, @"满带宽"), "C1p 比值>=0.93 ⟹ 满带宽", s);
        }
        {
            NSString *s = RLPAnlSumFake(@{@"status": @"ready", @"lossless_suspected": @NO,
                                          @"cutoff_hz": @17640, @"fs": @44100});
            CK(Has(s, @"80"), "C1q 比值 0.8 ⟹ 带宽仅 80%", s);
        }
        {
            NSString *s = RLPAnlSumFake(@{@"status": @"ready", @"lossless_suspected": @NO});
            CK(Has(s, @"未检出截止"), "C1r 无 cutoff ⟹ 未检出截止（不假装满带宽）", s);
        }
        {
            NSString *s = RLPAnlSumFake(@{@"status": @"ready", @"lossless_suspected": @YES, @"fake24": @YES});
            CK(Has(s, @"24bit"), "C1s fake24 ⟹ 追加 24bit 实为低位深", s);
        }
        CK([RLPAnlFmt(nil, 2, @" dB") isEqualToString:@"NA"], "C1t 不可用值 ⟹ NA（不是\"不适用 dB\"）", RLPAnlFmt(nil, 2, @" dB"));

        // ---------- ④ 自动分析去重（每曲一次） ----------
        CK(RLPAnlShouldAutoAnalyze(@"/m/a.flac", YES, YES, nil, NO, NO), "C4a 首次 ⟹ 触发", @"");
        CK(!RLPAnlShouldAutoAnalyze(@"/m/a.flac", YES, YES, @"/m/a.flac", NO, NO), "C4b 同曲已跑 ⟹ 不再触发", @"");
        CK(RLPAnlShouldAutoAnalyze(@"/m/b.flac", YES, YES, @"/m/a.flac", NO, NO), "C4c 切歌 ⟹ 重新触发", @"");
        CK(!RLPAnlShouldAutoAnalyze(@"/m/a.flac", NO, YES, nil, NO, NO), "C4d 暂停 ⟹ 不触发", @"");
        CK(!RLPAnlShouldAutoAnalyze(@"/m/a.flac", YES, NO, nil, NO, NO), "C4e autoanl=0 ⟹ 不触发", @"");
        CK(!RLPAnlShouldAutoAnalyze(@"https://x/y", YES, YES, nil, NO, NO), "C4f 非本地 ⟹ 不触发", @"");
        CK(!RLPAnlShouldAutoAnalyze(@"/m/a.flac", YES, YES, nil, YES, NO), "C4g 正在跑 ⟹ 不触发", @"");
        CK(!RLPAnlShouldAutoAnalyze(@"/m/a.flac", YES, YES, nil, NO, YES), "C4h 已缓存 ⟹ 不触发", @"");

        // ---------- ⑤ 一行几何 + 面上没有自动分析/重新分析 ----------
        RLPNowPlayingViewController *np = [[RLPNowPlayingViewController alloc] init];
        np.view.frame = NSMakeRect(0, 0, 1100, 700);
        [np.view layoutSubtreeIfNeeded];
        NSMutableArray<NSView *> *all = [NSMutableArray array];
        CollectViews(np.view, all);

        NSArray<NSString *> *ids = @[@"anl.dyn", @"anl.qual", @"anl.fake", @"anl.expand"];
        NSMutableDictionary<NSString *, NSView *> *found = [NSMutableDictionary dictionary];
        for (NSView *v in all) if (v.identifier.length && [ids containsObject:v.identifier]) found[v.identifier] = v;
        for (NSString *k in ids)
            CK(found[k] != nil, [[NSString stringWithFormat:@"C2a 分析行元素存在 %@", k] UTF8String], @"缺失");

        // 几何：先断言"量到了"，再断言"在同一行"
        BOOL measured = found.count == 4;
        // 宽**和高**都必须 > 0：无边框 NSButton 只给宽度约束时高度会塌成 0，
        // 那是"量到了但其实看不见"，只查宽会漏（本轮真踩到）。
        for (NSString *k in ids) {
            NSRect f = found[k].frame;
            if (f.size.width <= 0 || f.size.height <= 0) measured = NO;
        }
        if (!measured) {
            CK(NO, "C2b 分析行几何：没量到（未布局/元素缺失）", @"width<=0，先修可见性再谈一行");
        } else {
            CGFloat minY = CGFLOAT_MAX, maxY = -CGFLOAT_MAX;
            for (NSString *k in ids) {
                NSRect f = found[k].frame;
                minY = MIN(minY, f.origin.y); maxY = MAX(maxY, f.origin.y + f.size.height);
            }
            CK((maxY - minY) <= 44.0, "C2b 四个元素在同一行（总高 <= 44pt）",
               [NSString stringWithFormat:@"span=%.1f", maxY - minY]);
        }

        // 面上不许有自动分析开关；收起态不许有可见的「重新分析」
        BOOL hasAuto = NO, hasReanalyzeVisible = NO;
        for (NSView *v in all) {
            if (![v isKindOfClass:[NSButton class]]) continue;
            NSButton *b = (NSButton *)v;
            NSString *title = b.title ?: @"";
            if (Has(title, @"自动")) hasAuto = YES;
            if (Has(title, @"重新分析") && !b.hidden && b.alphaValue > 0.01) hasReanalyzeVisible = YES;
        }
        CK(!hasAuto, "C3a 播放页没有自动分析开关（已挪到设置）", @"发现标题含「自动」的按钮");
        CK(!hasReanalyzeVisible, "C3b 收起态没有摆在外面的「重新分析」", @"发现可见的重新分析按钮");

        std::printf("\n%s（%d 项失败）\n", gFail == 0 ? "analysis_row 全部通过" : "analysis_row 有失败", gFail);
        return gFail == 0 ? 0 : 1;
    }
}
