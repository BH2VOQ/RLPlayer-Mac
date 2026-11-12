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

        // ---------- ③b 后端 -300 是"不适用"哨兵，绝不能排成 -300.00 dB ----------
        // 依据：src/analysis/dynamics.h:266/301 与 track_health.h:346 —— 不可用时 JSON 写 -300。
        // 这一条抓的是"看着像测量值其实是哨兵"：RLPAnlHas 只判有限数字，会放过 -300。
        CK(!RLPAnlAvail(@(-300)), "C1u -300 哨兵不算可用值", @"");
        CK([RLPAnlVal(@(-300), 2, @" dB") isEqualToString:@"NA"], "C1u -300 ⟹ NA（不是 -300.00 dB）",
           RLPAnlVal(@(-300), 2, @" dB"));
        CK([RLPAnlVal(@(-3.5), 2, @" dB") isEqualToString:@"-3.50 dB"], "C1u -3.5 是真实值 ⟹ 正常格式化",
           RLPAnlVal(@(-3.5), 2, @" dB"));
        // *_available=false 时数值即使存在也不可信（dr_available=false ⟹ 动态不适用）
        {
            NSDictionary *h = @{@"dr_db": @14.2, @"dr_available": @NO};
            NSString *v = RLPAnlValFlag(h, @"dr_db", @"dr_available", 2, @" dB");
            CK([v isEqualToString:@"NA"], "C1v dr_available=false ⟹ 详情 NA（哪怕 dr_db=14.2）", v);
        }
        {
            NSDictionary *h = @{@"dr_db": @14.2, @"dr_available": @YES};
            NSString *v = RLPAnlValFlag(h, @"dr_db", @"dr_available", 2, @" dB");
            CK([v isEqualToString:@"14.20 dB"], "C1v dr_available=true ⟹ 正常显示", v);
        }
        CK([RLPAnlCount(@0) isEqualToString:@"0"], "C1w 计数 0 是真实值（不当成缺失）", RLPAnlCount(@0));
        CK([RLPAnlCount(nil) isEqualToString:@"NA"], "C1w 计数缺失 ⟹ NA", RLPAnlCount(nil));

        // ---------- ③c /api/health 是外层包 health，必须解开 ----------
        // 依据：tools/rtaweb.cpp 的 handle_health_analysis 两条返回路径都是
        //   {"ok":true,"usable":true,"cached":…,"ms":…,"stats":{…},"health":{…}}
        // 不拆外层的后果（实测）：一首 DR 14.2、零削波的歌被显示成
        //   「素材过短 · 动态不适用」+「不适用 · 样本不足」—— 全是假的。
        {
            NSDictionary *env = @{ @"ok": @YES, @"usable": @YES, @"cached": @YES,
                @"health": @{ @"dr_db": @14.2, @"dr_available": @YES, @"status": @"ready",
                              @"quality": @{ @"available": @YES, @"peak_dbfs_q": @-1.0,
                                             @"rms_dbfs": @-20.0, @"clipped_samples": @0 } } };
            NSDictionary *inner = RLPAnlUnwrapHealth(env);
            CK([inner isEqualToDictionary:env[@"health"]], "C1x 解开外层 ⟹ 拿到内层 health", @"");
            CK(Has(RLPAnlSumDyn(inner), @"良好动态"), "C1x 解外层后动态摘要正确",
               RLPAnlSumDyn(inner));
            CK(Has(RLPAnlSumQual(inner), @"干净"), "C1x 解外层后音质摘要正确",
               RLPAnlSumQual(inner));
            // 反向判据：直接把外层喂给摘要函数必须**读不到**（证明这条不是安慰剂）
            CK(Has(RLPAnlSumDyn(env), @"不适用"), "C1x 未解外层会误报「不适用」（这就是要修的 bug）",
               RLPAnlSumDyn(env));
            CK(RLPAnlUnwrapHealth(@{@"ok": @YES})[@"dr_db"] == nil, "C1x 没有内层时退回外层（不崩）", @"");
            CK(RLPAnlUnwrapHealth(nil) == nil, "C1x nil 输入 ⟹ nil", @"");
        }

        // ---------- ③d 详情文本：NA 口径 + 分组 ----------
        {
            NSDictionary *env = @{ @"ok": @YES, @"health": @{
                @"dr_db": @14.2, @"dr_available": @YES, @"lufs": @(-300), @"lufs_available": @NO,
                @"status": @"ready", @"fs": @44100, @"bits": @16, @"channels": @2,
                @"peak_dbfs": @(-300), @"duration_sec": @200.0,
                @"lossless_suspected": @NO, @"cutoff_hz": @0, @"fake24": @NO,
                @"quality": @{ @"available": @YES, @"peak_dbfs_q": @-1.0, @"rms_dbfs": @-20.0,
                               @"clipped_samples": @0, @"longest_clip_run": @0, @"stereo": @YES,
                               @"snr_db": @16.0, @"centroid_hz": @2500.0 } } };
            NSDictionary *h = RLPAnlUnwrapHealth(env);
            NSString *l1 = RLPAnlDetailText(h, 1, NO, nil, @"/m/a.flac");
            CK(Has(l1, @"动态") && Has(l1, @"音质") && Has(l1, @"假无损"), "C1y 详情含三组", l1);
            CK(Has(l1, @"14.20 dB"), "C1y 真实 DR 正常显示", l1);
            CK(!Has(l1, @"-300"), "C1y 详情里绝不出现 -300 哨兵", l1);
            CK(Has(l1, @"未检出"), "C1y cutoff_hz=0 ⟹ 未检出（不是 0.0 kHz）", l1);
            // 层级 2 才出现原始证据
            NSString *l0 = RLPAnlDetailText(h, 0, NO, nil, @"/m/a.flac");
            NSString *l2 = RLPAnlDetailText(h, 2, YES, nil, @"/m/a.flac");
            CK(!Has(l0, @"原始证据"), "C1y L0 不显示原始证据", @"");
            CK(Has(l2, @"原始证据"), "C1y L2 显示原始证据", l2);
            CK(Has(l2, @"缓存命中"), "C1y L2 显示缓存命中标记", l2);
            CK(Has(l2, @"判定依据") || !h[@"reason"], "C1y 有 reason 时显示判定依据", l2);
            // 空态必须如实
            CK(Has(RLPAnlDetailText(nil, 1, NO, nil, @""), @"未播放"), "C1y 无曲目 ⟹ 未播放", @"");
            CK(Has(RLPAnlDetailText(nil, 1, NO, nil, @"https://x/y"), @"仅本地"), "C1y 网络曲目 ⟹ 仅本地文件可分析", @"");
            CK(Has(RLPAnlDetailText(nil, 1, NO, @"解码失败", @"/m/a.flac"), @"解码失败"), "C1y 失败如实显示原因", @"");
        }

        // ---------- ④ 自动分析去重（每曲一次） ----------
        CK(RLPAnlShouldAutoAnalyze(@"/m/a.flac", YES, YES, nil, NO, NO), "C4a 首次 ⟹ 触发", @"");
        CK(!RLPAnlShouldAutoAnalyze(@"/m/a.flac", YES, YES, @"/m/a.flac", NO, NO), "C4b 同曲已跑 ⟹ 不再触发", @"");
        CK(RLPAnlShouldAutoAnalyze(@"/m/b.flac", YES, YES, @"/m/a.flac", NO, NO), "C4c 切歌 ⟹ 重新触发", @"");
        CK(!RLPAnlShouldAutoAnalyze(@"/m/a.flac", NO, YES, nil, NO, NO), "C4d 暂停 ⟹ 不触发", @"");
        CK(!RLPAnlShouldAutoAnalyze(@"/m/a.flac", YES, NO, nil, NO, NO), "C4e autoanl=0 ⟹ 不触发", @"");
        CK(!RLPAnlShouldAutoAnalyze(@"https://x/y", YES, YES, nil, NO, NO), "C4f 非本地 ⟹ 不触发", @"");
        CK(!RLPAnlShouldAutoAnalyze(@"/m/a.flac", YES, YES, nil, YES, NO), "C4g 正在跑 ⟹ 不触发", @"");
        CK(!RLPAnlShouldAutoAnalyze(@"/m/a.flac", YES, YES, nil, NO, YES), "C4h 已缓存 ⟹ 不触发", @"");

        // 2026-11-12: user reference #1 and frozen web .npbody explicitly replace
        // the old "single analysis row / no auto switch" design. Preserve C1/C4
        // numeric and auto-dedup checks above; geometry now checks vertical cards.
        RLPNowPlayingViewController *np = [RLPNowPlayingViewController new];
        np.view.frame=NSMakeRect(0,0,1180,760);[np.view layoutSubtreeIfNeeded];
        NSMutableArray<NSView *> *all=[NSMutableArray array];CollectViews(np.view,all);
        NSMutableDictionary<NSString *,NSView *> *byId=[NSMutableDictionary dictionary];
        for(NSView *v in all)if(v.identifier.length)byId[v.identifier]=v;
        NSView *panel=byId[@"npAnal"];
        CK(panel && panel.frame.size.width>0 && panel.frame.size.height>0,"C2a web vertical analysis panel visible",NSStringFromRect(panel.frame));
        CGFloat lastTop=CGFLOAT_MAX;
        for(NSString *key in @[@"anl.dyn",@"anl.qual",@"anl.fake"]){NSView *v=byId[key];BOOL visible=v&&!v.hidden&&v.frame.size.width>0&&v.frame.size.height>0;CK(visible,[[NSString stringWithFormat:@"C2b %@ real summary card visible",key] UTF8String],NSStringFromRect(v.frame));CK(NSMaxY(v.frame)<=lastTop,"C2c cards stack without overlap",NSStringFromRect(v.frame));lastTop=NSMinY(v.frame);}
        CK(byId[@"npAnlAuto"]!=nil,"C3a web automatic analysis segment exists",@"");
        CK(byId[@"npAnlRun"]!=nil,"C3b web force analysis segment exists",@"");
        CK(byId[@"npAnlToggle"]!=nil,"C3c web detail level segment exists",@"");
        std::printf("\n%s（%d 项失败）\n", gFail == 0 ? "analysis_row 全部通过" : "analysis_row 有失败", gFail);
        return gFail == 0 ? 0 : 1;
    }
}
