// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPAnalysisSummary.h"
#import "RLPSupport.h"

BOOL RLPAnlHas(id v) {
    if (![v isKindOfClass:[NSNumber class]]) return NO;
    // NSNull / 字符串都不算数字；NaN/Inf 也不算（后端探测失败时会给 null）。
    double d = [(NSNumber *)v doubleValue];
    return isfinite(d);
}

NSString *RLPAnlFmt(id v, NSInteger digits, NSString *unit) {
    if (!RLPAnlHas(v)) return @"NA";
    double d = [(NSNumber *)v doubleValue];
    NSString *s = [NSString stringWithFormat:@"%.*f", (int)digits, d];
    return unit.length ? [s stringByAppendingString:unit] : s;
}

static NSDictionary *Qual(NSDictionary *h) {
    id q = h[@"quality"];
    return [q isKindOfClass:[NSDictionary class]] ? q : nil;
}

NSString *RLPAnlSumDyn(NSDictionary *h) {
    if (![h isKindOfClass:[NSDictionary class]]) return RLPTr(@"未分析");
    // dr_available 显式 false ⟹ 后端明确说"不适用"，不能拿缺失当 0。
    id avail = h[@"dr_available"];
    if ([avail isKindOfClass:[NSNumber class]] && ![avail boolValue])
        return RLPTr(@"素材过短 · 动态不适用");
    if (!RLPAnlHas(h[@"dr_db"])) return RLPTr(@"素材过短 · 动态不适用");
    const double dr = [h[@"dr_db"] doubleValue];
    if (dr >= 14) return RLPTr(@"良好动态 · 古典/爵士常见");
    if (dr >= 11) return RLPTr(@"中等动态 · 摇滚/原声常见");
    if (dr >= 8)  return RLPTr(@"动态偏紧 · 流行母带常见");
    return RLPTr(@"低动态 · 高压缩母带");
}

NSString *RLPAnlSumQual(NSDictionary *h) {
    if (![h isKindOfClass:[NSDictionary class]]) return RLPTr(@"未分析");
    NSDictionary *q = Qual(h);
    id avail = q[@"available"];
    if (![avail isKindOfClass:[NSNumber class]] || ![avail boolValue])
        return RLPTr(@"不适用 · 样本不足");
    // 数字静音/无有效音频：clipped_samples=0 在静音里没有意义，不能说"干净"。
    if (!RLPAnlHas(q[@"peak_dbfs_q"]) || !RLPAnlHas(q[@"rms_dbfs"]))
        return RLPTr(@"无有效音频 · 指标不适用");
    const double n = RLPAnlHas(q[@"clipped_samples"]) ? [q[@"clipped_samples"] doubleValue] : 0;
    if (n <= 0) return RLPTr(@"干净 · 无明显削波");
    const double runs = RLPAnlHas(q[@"clipped_runs"]) ? [q[@"clipped_runs"] doubleValue] : 0;
    const double longest = RLPAnlHas(q[@"longest_clip_run"]) ? [q[@"longest_clip_run"] doubleValue] : 0;
    if (runs > 0 && longest >= 3)
        return [NSString stringWithFormat:@"%@ %ld %@", RLPTr(@"有削波 · 最长"), (long)longest, RLPTr(@"样本")];
    return [NSString stringWithFormat:@"%@ %ld %@", RLPTr(@"轻微削波 ·"), (long)n, RLPTr(@"样本")];
}

NSString *RLPAnlSumFake(NSDictionary *h) {
    if (![h isKindOfClass:[NSDictionary class]]) return RLPTr(@"未分析");
    id st = h[@"status"];
    if ([st isKindOfClass:[NSString class]] && [(NSString *)st length] && ![st isEqualToString:@"ready"])
        return RLPTr(@"分析未完成");
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    const BOOL suspected = [h[@"lossless_suspected"] isKindOfClass:[NSNumber class]] &&
                           [h[@"lossless_suspected"] boolValue];
    if (suspected) {
        [parts addObject:RLPTr(@"疑似有损转码")];
        if (RLPAnlHas(h[@"cutoff_hz"]))
            [parts addObject:[NSString stringWithFormat:@"%@ %.1f kHz", RLPTr(@"截止"),
                              [h[@"cutoff_hz"] doubleValue] / 1000.0]];
    } else {
        [parts addObject:RLPTr(@"未发现")];
        // 「满带宽」必须有证据：截止接近 fs/2 才敢这么说，否则如实写百分比或"未检出"。
        if (RLPAnlHas(h[@"cutoff_hz"]) && [h[@"cutoff_hz"] doubleValue] > 0 && RLPAnlHas(h[@"fs"]) && [h[@"fs"] doubleValue] > 0) {
            const double ratio = [h[@"cutoff_hz"] doubleValue] / ([h[@"fs"] doubleValue] / 2.0);
            if (ratio >= 0.93) [parts addObject:RLPTr(@"满带宽")];
            else [parts addObject:[NSString stringWithFormat:@"%@ %ld%%", RLPTr(@"带宽仅"), (long)lround(ratio * 100)]];
        } else {
            [parts addObject:RLPTr(@"未检出截止")];
        }
    }
    if ([h[@"fake24"] isKindOfClass:[NSNumber class]] && [h[@"fake24"] boolValue])
        [parts addObject:RLPTr(@"24bit 实为低位深")];
    return [parts componentsJoinedByString:@" · "];
}


// ---------------------------------------------------------------------------
// 哨兵 + 可用性双判（铁律 3）
// ---------------------------------------------------------------------------
BOOL RLPAnlAvail(id v) {
    if (![v isKindOfClass:[NSNumber class]]) return NO;
    const double d = [(NSNumber *)v doubleValue];
    // -300 是后端的"不适用"哨兵（dynamics.h:266/301、track_health.h:346），不是测量值。
    return isfinite(d) && d > -299.0;
}

NSString *RLPAnlVal(id v, NSInteger digits, NSString *unit) {
    if (!RLPAnlAvail(v)) return @"NA";
    return [NSString stringWithFormat:@"%.*f%@", (int)digits, [(NSNumber *)v doubleValue], unit ?: @""];
}

NSString *RLPAnlValFlag(NSDictionary *h, NSString *key, NSString *flagKey, NSInteger digits, NSString *unit) {
    if ([h isKindOfClass:[NSDictionary class]] && flagKey.length) {
        id f = h[flagKey];
        // 旗标只认显式 false；缺失视为未知（不擅自判死）
        if ([f isKindOfClass:[NSNumber class]] && ![(NSNumber *)f boolValue]) return @"NA";
    }
    return RLPAnlVal([h isKindOfClass:[NSDictionary class]] ? h[key] : nil, digits, unit);
}

NSString *RLPAnlCount(id v) {
    if (![v isKindOfClass:[NSNumber class]]) return @"NA";
    const double d = [(NSNumber *)v doubleValue];
    if (!isfinite(d)) return @"NA";
    return [NSString stringWithFormat:@"%lld", (long long)llround(d)];
}

NSDictionary *RLPAnlUnwrapHealth(NSDictionary *json) {
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    id inner = json[@"health"];
    if ([inner isKindOfClass:[NSDictionary class]] && [(NSDictionary *)inner count]) return inner;
    return json;
}

// ---------------------------------------------------------------------------
// 详情文本（L1 = 关键指标；L2 = 全量 + 原始证据）
// 对齐 web 版 anlCardDyn / anlCardQual / anlCardFake 的字段清单。
// ---------------------------------------------------------------------------
NSString *RLPAnlDetailText(NSDictionary *health, NSInteger level, BOOL cached,
                           NSString *error, NSString *path) {
    const NSInteger L = MAX(0, MIN(2, level));
    NSMutableString *s = [NSMutableString string];
    if (![health isKindOfClass:[NSDictionary class]] || !health.count) {
        if (error.length) [s appendFormat:@"%@：%@", RLPTr(@"分析失败"), error];
        else if (!path.length) [s appendString:RLPTr(@"未播放")];
        else if (!RLPAnlIsLocalPath(path)) [s appendString:RLPTr(@"仅本地文件可分析")];
        else [s appendString:RLPTr(@"未分析")];
        return s;
    }
    NSDictionary *q = [health[@"quality"] isKindOfClass:[NSDictionary class]] ? health[@"quality"] : @{};
    const BOOL qOK = [q[@"available"] isKindOfClass:[NSNumber class]] && [q[@"available"] boolValue];

    // ---------------- ① 动态 ----------------
    [s appendFormat:@"%@\n", RLPTr(@"动态")];
    [s appendFormat:@"  %@ %@\n", RLPTr(@"动态范围 DR"), RLPAnlValFlag(health, @"dr_db", @"dr_available", 2, @" dB")];
    [s appendFormat:@"  %@ %@\n", RLPTr(@"响度 (LUFS)"), RLPAnlValFlag(health, @"lufs", @"lufs_available", 2, @" LUFS")];
    [s appendFormat:@"  %@ %@\n", RLPTr(@"响度范围 LRA"), RLPAnlValFlag(health, @"lra", @"lra_available", 2, @" LU")];
    [s appendFormat:@"  %@ %@\n", RLPTr(@"真峰 (dBTP)"), RLPAnlValFlag(health, @"true_peak_dbtp", @"true_peak_available", 2, @" dBTP")];
    [s appendFormat:@"  %@ %@\n", RLPTr(@"样本峰值"), RLPAnlVal(health[@"peak_dbfs"], 2, @" dBFS")];
    [s appendFormat:@"  %@ %@\n", RLPTr(@"声道"),
        RLPAnlAvail(health[@"channels"]) ? [NSString stringWithFormat:@"%@ ch", RLPAnlCount(health[@"channels"])] : @"NA"];

    // ---------------- ② 音质 ----------------
    [s appendFormat:@"\n%@\n", RLPTr(@"音质")];
    if (!qOK) {
        // 样本不足时不摆一堆无意义的 0（那正是"看着很专业其实是噪声"的来源）
        [s appendFormat:@"  %@ %@\n", RLPTr(@"音质指标"), RLPTr(@"不适用（样本不足）")];
        [s appendFormat:@"  %@ %@\n", RLPTr(@"谱窗数"), RLPAnlCount(q[@"spectral_windows"])];
    } else {
        [s appendFormat:@"  %@ %@\n", RLPTr(@"削波样本"), RLPAnlCount(q[@"clipped_samples"])];
        [s appendFormat:@"  %@ %@\n", RLPTr(@"最长连续削波"), RLPAnlCount(q[@"longest_clip_run"])];
        [s appendFormat:@"  %@ %@\n", RLPTr(@"峰值因子"), RLPAnlVal(q[@"crest_db"], 2, @" dB")];
        [s appendFormat:@"  %@ %@\n", RLPTr(@"信噪比"), RLPAnlVal(q[@"snr_db"], 2, @" dB")];
        [s appendFormat:@"  %@ %@\n", RLPTr(@"频谱重心"), RLPAnlVal(q[@"centroid_hz"], 0, @" Hz")];
        [s appendFormat:@"  %@ %@\n", RLPTr(@"本底噪声"), RLPAnlVal(q[@"noise_floor_dbfs"], 2, @" dBFS")];
        [s appendFormat:@"  %@ %@\n", RLPTr(@"10k 以上能量"), RLPAnlVal(q[@"hf_ratio_10k_db"], 2, @" dB")];
        NSString *corr = @"NA";
        if (RLPAnlAvail(health[@"channels"]) && [health[@"channels"] doubleValue] <= 2.0) {
            corr = ([q[@"stereo"] isKindOfClass:[NSNumber class]] && [q[@"stereo"] boolValue])
                 ? RLPAnlVal(q[@"channel_corr"], 3, @"") : RLPTr(@"单声道素材");
        }
        [s appendFormat:@"  %@ %@\n", RLPTr(@"立体声相关"), corr];
    }

    // ---------------- ③ 假无损 ----------------
    [s appendFormat:@"\n%@\n", RLPTr(@"假无损")];
    [s appendFormat:@"  %@ %@\n", RLPTr(@"判定"), RLPAnlSumFake(health)];
    {
        // cutoff_hz=0 是「未检出陡沿」，不是「0 kHz 带宽」——排成 0.0 kHz 会被读成结论。
        const BOOL cOK = RLPAnlAvail(health[@"cutoff_hz"]) && [health[@"cutoff_hz"] doubleValue] > 0;
        [s appendFormat:@"  %@ %@\n", RLPTr(@"截止频率"),
            cOK ? [NSString stringWithFormat:@"%.1f kHz", [health[@"cutoff_hz"] doubleValue] / 1000.0]
                : RLPTr(@"未检出")];
    }
    {
        // confidence 后端是 0..1；>1 视为已是百分数（与 web 版 anlConfV 同口径）
        NSString *conf = @"NA";
        if (RLPAnlAvail(health[@"confidence"])) {
            const double c = [health[@"confidence"] doubleValue];
            conf = [NSString stringWithFormat:@"%.0f%%", (c <= 1.0001 ? c * 100.0 : c)];
        }
        [s appendFormat:@"  %@ %@\n", RLPTr(@"置信度"), conf];
    }
    [s appendFormat:@"  %@ %@\n", RLPTr(@"谱窗数"), RLPAnlCount(q[@"spectral_windows"])];
    [s appendFormat:@"  %@ %@\n", RLPTr(@"时长"), RLPAnlVal(health[@"duration_sec"], 1, @" s")];
    [s appendFormat:@"  %@ %@\n", RLPTr(@"24bit 实为低位深"),
        [health[@"fake24"] isKindOfClass:[NSNumber class]]
            ? ([(NSNumber *)health[@"fake24"] boolValue] ? RLPTr(@"是") : RLPTr(@"否")) : @"NA"];

    if (L >= 1) {
        // ---------------- L2：采样规格 + 分析记录 + 原始证据 + 判定依据 ----------------
        [s appendFormat:@"\n%@\n", RLPTr(@"采样规格")];
        [s appendFormat:@"  %@ %@\n", RLPTr(@"采样率"), RLPAnlVal(health[@"fs"], 0, @" Hz")];
        [s appendFormat:@"  %@ %@\n", RLPTr(@"位深"), RLPAnlVal(health[@"bits"], 0, @" bit")];

        [s appendFormat:@"\n%@\n", RLPTr(@"分析记录")];
        [s appendFormat:@"  %@ %@\n", RLPTr(@"分析状态"),
            [health[@"status"] isKindOfClass:[NSString class]] ? health[@"status"] : @"NA"];
        {
            NSString *clock = @"NA";
            const double ms = RLPAnlAvail(health[@"analyzed_at_ms"]) ? [health[@"analyzed_at_ms"] doubleValue] : 0;
            if (ms > 0) {
                NSDate *d = [NSDate dateWithTimeIntervalSince1970:ms / 1000.0];
                NSDateFormatter *f = [[NSDateFormatter alloc] init];
                f.dateFormat = @"HH:mm";
                clock = [f stringFromDate:d];
            }
            [s appendFormat:@"  %@ %@\n", RLPTr(@"分析时刻"), clock];
        }
        if (cached) [s appendFormat:@"  %@\n", RLPTr(@"缓存命中")];
    }

    if (L >= 2) {
        [s appendFormat:@"\n%@\n", RLPTr(@"原始证据")];
        [s appendFormat:@"  lossless_suspected %@\n",
            [health[@"lossless_suspected"] isKindOfClass:[NSNumber class]]
                ? ([(NSNumber *)health[@"lossless_suspected"] boolValue] ? @"true" : @"false") : @"NA"];
        [s appendFormat:@"  cutoff_hz %@\n", RLPAnlVal(health[@"cutoff_hz"], 1, @" Hz")];
        [s appendFormat:@"  confidence %@\n", RLPAnlVal(health[@"confidence"], 3, @"")];
        [s appendFormat:@"  fs / 2 %@\n",
            RLPAnlAvail(health[@"fs"])
                ? [NSString stringWithFormat:@"%lld Hz", (long long)llround([health[@"fs"] doubleValue] / 2.0)]
                : @"NA"];
        [s appendFormat:@"  %@ %@\n", RLPTr(@"削波段数"), RLPAnlCount(q[@"clipped_runs"])];
        [s appendFormat:@"  %@ %@\n", RLPTr(@"削波占比"), RLPAnlVal(q[@"clipped_pct"], 3, @"%")];
        [s appendFormat:@"  %@ %@\n", RLPTr(@"RMS"), RLPAnlVal(q[@"rms_dbfs"], 2, @" dBFS")];
        [s appendFormat:@"  %@ %@\n", RLPTr(@"静音占比"), RLPAnlVal(q[@"silence_pct"], 2, @"%")];
        [s appendFormat:@"  %@ %@\n", RLPTr(@"频谱倾斜"), RLPAnlVal(q[@"tilt_db_per_oct"], 2, @" dB/oct")];
        [s appendFormat:@"  %@ %@\n", RLPTr(@"95%% 滚降点"), RLPAnlVal(q[@"rolloff95_hz"], 0, @" Hz")];
        [s appendFormat:@"  %@ %@\n", RLPTr(@"THD+N"), RLPAnlValFlag(q, @"thdn_db", @"thdn_available", 2, @" dB")];
        [s appendFormat:@"  %@ %@\n", RLPTr(@"互调失真 IMD"), RLPAnlValFlag(q, @"imd_db", @"imd_available", 2, @" dB")];
        [s appendFormat:@"  %@ %@\n", RLPTr(@"非谐波残留"), RLPAnlVal(q[@"non_tonal_db"], 2, @" dB")];
        [s appendFormat:@"  %@ %@\n", RLPTr(@"动态重心"), RLPAnlVal(q[@"dyn_centroid_dbfs"], 2, @" dBFS")];
        [s appendFormat:@"  %@ %@\n", RLPTr(@"P95−P10"), RLPAnlVal(q[@"dyn_p95_p10_db"], 2, @" dB")];
        if ([q[@"note"] isKindOfClass:[NSString class]] && [q[@"note"] length])
            [s appendFormat:@"  %@\n", q[@"note"]];
    }

    if ([health[@"reason"] isKindOfClass:[NSString class]] && [health[@"reason"] length])
        [s appendFormat:@"\n%@：%@\n", RLPTr(@"判定依据"), health[@"reason"]];
    if ([health[@"error"] isKindOfClass:[NSString class]] && [health[@"error"] length])
        [s appendFormat:@"%@：%@\n", RLPTr(@"后端说明"), health[@"error"]];
    return s;
}

BOOL RLPAnlIsLocalPath(NSString *path) {
    if (![path isKindOfClass:[NSString class]] || !path.length) return NO;
    // 只认绝对本地路径；http(s)/流媒体协议一律不可分析（与 web 版 anlIsLocal 同口径）。
    if (![path hasPrefix:@"/"]) return NO;
    if ([path hasPrefix:@"//"]) return NO;
    return YES;
}

BOOL RLPAnlShouldAutoAnalyze(NSString *path, BOOL playing, BOOL autoEnabled,
                             NSString *alreadyDonePath, BOOL busy, BOOL cached) {
    if (!autoEnabled) return NO;
    if (!playing) return NO;                       // 暂停/停止不触发
    if (!RLPAnlIsLocalPath(path)) return NO;
    if (alreadyDonePath.length && [alreadyDonePath isEqualToString:path]) return NO;  // 每曲一次
    if (busy || cached) return NO;
    return YES;
}
