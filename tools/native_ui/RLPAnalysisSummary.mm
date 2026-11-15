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
    // U10：incomplete = 分析**完成**了，但文件可能只有一半。绝不返回「分析未完成」——
    // 那会把用户引向"再点一次分析"，而正确动作是等拷贝/下载结束。摘要照常给有损判读。
    if ([st isKindOfClass:[NSString class]] && [(NSString *)st length] && ![st isEqualToString:@"ready"] &&
        ![st isEqualToString:@"incomplete"])
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
// 完整性（U10，2026-11-16）：后端判「文件可能不完整」的**只读**判读层
//
// 判据的唯一真相源在后端（src/analysis/track_health.h 的 apply_completeness：
// |实际 − 容器声明| > max(1 s, 2%×声明) ⟹ status="incomplete"，容器时长未知就不判）。
// UI 侧**绝不复算**这个阈值，也不从 note 文案反推 —— 只读两个字段：
//   incomplete: true/false（新键）；status: "ready"/"incomplete"/…
// 这样两边口径不会漂移（铁律 3：串接层不许自己发明判据）。
// ---------------------------------------------------------------------------
BOOL RLPAnlIncomplete(NSDictionary *h) {
    if (![h isKindOfClass:[NSDictionary class]]) return NO;
    id flag = h[@"incomplete"];
    if ([flag isKindOfClass:[NSNumber class]] && [(NSNumber *)flag boolValue]) return YES;
    id st = h[@"status"];
    return [st isKindOfClass:[NSString class]] && [(NSString *)st isEqualToString:@"incomplete"];
}

NSString *RLPAnlDeclaredVsActual(NSDictionary *h) {
    if (![h isKindOfClass:[NSDictionary class]]) return nil;
    id decl = h[@"declared_sec"];
    // declared_sec==0/缺失 = 后端明确"没判"（容器时长未知）：绝不能排成 "声明 0.0 s"。
    if (!RLPAnlAvail(decl) || [(NSNumber *)decl doubleValue] <= 0.0) return nil;
    NSString *actual = RLPAnlVal(h[@"duration_sec"], 3, @" s");
    return [NSString stringWithFormat:@"%@ %.3f s / %@ %@",
            RLPTr(@"容器声明"), [(NSNumber *)decl doubleValue], RLPTr(@"实际解码"), actual];
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
    // U10：半截文件的提示**原样**放首行（后端 note，中文人话里已经带声明值/实际值/百分比）。
    // 这里绝不写死文案：note 是后端判据的一部分，UI 只负责摆在最前面；note 为空就不占行。
    if (RLPAnlIncomplete(health) && [health[@"note"] isKindOfClass:[NSString class]] &&
        [(NSString *)health[@"note"] length]) {
        [s appendFormat:@"%@\n\n", health[@"note"]];
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
        // U10：把判据的两个数摊开（note 已给过一遍，这里是"按字段可核对"的同一对数字）。
        {
            NSString *cmp = RLPAnlDeclaredVsActual(health);
            if (cmp.length) [s appendFormat:@"  %@ %@\n", RLPTr(@"完整性"), cmp];
        }
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

// ---------------------------------------------------------------------------
// 展开档「每张卡」的指标行模型（web anlCardDyn/anlCardQual/anlCardFake 的移植）
//
// 口径全部来自 web src/net/ui_script.h 的 anl*V 系列（:8177-8350）：
//   * *_available=false ⟹ NA（原因），绝不拿哨兵/缺失当 0；
//   * 真峰 >0 才带 "+" 与 warn（母带过载）；
//   * cutoff_hz=0 是「未检出陡沿」，不是「0 kHz 带宽」；
//   * signalw：NA 文案长于 8 字才整行独占（两列网格的节奏不被长原因打乱）。
// ---------------------------------------------------------------------------
static NSString *AnlNA_(NSString *why) {
    return why.length ? [NSString stringWithFormat:@"NA（%@）", why] : @"NA";
}
static NSDictionary *AnlRow(NSString *label, NSString *value, BOOL na, BOOL warn) {
    NSString *v = value ?: @"NA";
    return @{ @"k": @"row", @"l": label ?: @"",
              @"v": v, @"na": @(na), @"warn": @(warn),
              @"wide": @(na && v.length > 8) };
}
static NSDictionary *AnlSec(NSString *title) { return @{ @"k": @"sec", @"t": title ?: @"" }; }
static NSDictionary *AnlWarn(NSString *text, NSString *hint) {
    return @{ @"k": @"warn", @"t": text ?: @"", @"h": hint ?: @"" };
}
static NSDictionary *AnlNote(NSString *text) { return @{ @"k": @"note", @"t": text ?: @"" }; }

static NSDictionary *AnlQ(NSDictionary *h) {
    id q = h[@"quality"];
    return [q isKindOfClass:[NSDictionary class]] ? q : @{};
}
/// 旗标只认显式 false（缺失视为未知），与 RLPAnlValFlag 同口径。
static BOOL AnlFlagOK(id flag) {
    return ![flag isKindOfClass:[NSNumber class]] || [(NSNumber *)flag boolValue];
}
/// *_available=false 的数值行：NA 必须带原因（"素材过短"），不是光秃秃的 NA。
static NSDictionary *AnlValRow(NSDictionary *h, NSString *label,
                               NSString *key, NSString *flagKey,
                               NSInteger digits, NSString *unit, NSString *why) {
    if (!AnlFlagOK(h[flagKey])) return AnlRow(label, AnlNA_(why), YES, NO);
    NSString *v = RLPAnlVal(h[key], digits, unit);
    return AnlRow(label, v, [v isEqualToString:@"NA"], NO);
}

/// web anlVerV：判定（不是整段摘要，摘要里可能还带截止频率）
static NSString *AnlVerdict(NSDictionary *h) {
    id st = h[@"status"];
    // U10：同 RLPAnlSumFake —— incomplete 不是"分析未完成"，它只说明文件可能短了一截。
    if ([st isKindOfClass:[NSString class]] && [(NSString *)st length] && ![st isEqualToString:@"ready"] &&
        ![st isEqualToString:@"incomplete"])
        return RLPTr(@"分析未完成");
    if ([h[@"lossless_suspected"] isKindOfClass:[NSNumber class]] && [h[@"lossless_suspected"] boolValue])
        return RLPTr(@"疑似有损转码");
    // 有截止但置信度不足：说"证据不足"，不要冒充"未发现"。
    if (RLPAnlAvail(h[@"cutoff_hz"]) && [h[@"cutoff_hz"] doubleValue] > 0 &&
        RLPAnlAvail(h[@"confidence"]) && [h[@"confidence"] doubleValue] < 0.5)
        return [NSString stringWithFormat:@"%@ %ld%%", RLPTr(@"证据不足 · 置信度"),
                (long)lround([h[@"confidence"] doubleValue] * 100.0)];
    return RLPTr(@"未发现");
}
/// web anlCutoffV：cutoff=0/缺失 ⟹ 未检出（不是 0.0 kHz）。
static NSString *AnlCutoffV(NSDictionary *h) {
    if (!RLPAnlAvail(h[@"cutoff_hz"]) || [h[@"cutoff_hz"] doubleValue] <= 0) return RLPTr(@"未检出");
    return [NSString stringWithFormat:@"%.1f kHz", [h[@"cutoff_hz"] doubleValue] / 1000.0];
}
static NSString *AnlConfV(NSDictionary *h) {
    if (!RLPAnlAvail(h[@"confidence"])) return @"NA";
    const double c = [h[@"confidence"] doubleValue];
    return [NSString stringWithFormat:@"%.0f%%", c <= 1.0001 ? c * 100.0 : c];
}
static NSString *AnlDurV(NSDictionary *h) {
    return RLPAnlVal(h[@"duration_sec"], 1, @" s");
}
static NSString *AnlClockOf(id msValue) {
    if (!RLPAnlAvail(msValue) || [msValue doubleValue] <= 0) return @"NA";
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:[msValue doubleValue] / 1000.0];
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"HH:mm";
    return [f stringFromDate:d];
}
static NSString *AnlChannelsV(NSDictionary *h) {
    if (!RLPAnlAvail(h[@"channels"])) return @"NA";
    return [NSString stringWithFormat:@"%@ ch", RLPAnlCount(h[@"channels"])];
}
static BOOL AnlHfAvail(NSDictionary *h, NSDictionary *q) {
    id flag = q[@"hf_ratio_10k_available"];
    if ([flag isKindOfClass:[NSNumber class]]) return [(NSNumber *)flag boolValue];
    return RLPAnlAvail(h[@"fs"]) && [h[@"fs"] doubleValue] > 20000.0;
}
static NSString *AnlHfV(NSDictionary *h, NSDictionary *q) {
    if (!AnlHfAvail(h, q)) return AnlNA_(RLPTr(@"采样率 ≤20 kHz"));
    return RLPAnlVal(q[@"hf_ratio_10k_db"], 2, @" dB");
}
static BOOL AnlSideAvail(NSDictionary *h, NSDictionary *q) {
    id flag = q[@"side_mid_available"];
    if ([flag isKindOfClass:[NSNumber class]]) return [(NSNumber *)flag boolValue];
    return RLPAnlAvail(h[@"channels"]) ? [h[@"channels"] doubleValue] <= 2.0 : YES;
}
/// web anlCorrV / anlMonoLossV / anlSideMidV：多声道一律 NA（多声道）
static NSString *AnlStereoV(NSDictionary *h, NSDictionary *q, NSString *key, NSInteger digits, NSString *unit) {
    if (RLPAnlAvail(h[@"channels"]) && [h[@"channels"] doubleValue] > 2.0) return AnlNA_(RLPTr(@"多声道"));
    if (![q[@"stereo"] isKindOfClass:[NSNumber class]] || ![q[@"stereo"] boolValue])
        return AnlNA_(RLPTr(@"单声道素材"));
    if (!AnlSideAvail(h, q)) return @"NA";
    return RLPAnlVal(q[key], digits, unit);
}
/// web anlClipV：计数类 0 是真实值；>0 是警告（琥珀）。
static NSString *AnlClipV(NSDictionary *q, BOOL *warn) {
    if (warn) *warn = NO;
    id n = q[@"clipped_samples"];
    if (![n isKindOfClass:[NSNumber class]] || !isfinite([(NSNumber *)n doubleValue])) return @"NA";
    const double v = [(NSNumber *)n doubleValue];
    if (v <= 0) return @"0";
    if (warn) *warn = YES;
    NSString *pct = RLPAnlAvail(q[@"clipped_pct"])
        ? [NSString stringWithFormat:@"（%.3f%%）", [q[@"clipped_pct"] doubleValue]] : @"";
    return [NSString stringWithFormat:@"%@ %@%@", RLPAnlCount(n), RLPTr(@"个样本"), pct];
}
static NSDictionary *AnlClipRow(NSDictionary *q, NSString *label) {
    BOOL warn = NO;
    NSString *v = AnlClipV(q, &warn);
    return AnlRow(label, v, [v isEqualToString:@"NA"], warn);
}
/// web anlLongestV：>=3 样本才算需要提醒的连续削波
static NSDictionary *AnlLongestRow(NSDictionary *q, NSString *label) {
    id n = q[@"longest_clip_run"];
    if (![n isKindOfClass:[NSNumber class]] || !isfinite([(NSNumber *)n doubleValue]))
        return AnlRow(label, @"NA", YES, NO);
    const double v = [(NSNumber *)n doubleValue];
    if (v <= 0) return AnlRow(label, @"0", NO, NO);
    return AnlRow(label, [NSString stringWithFormat:@"%@ %@", RLPAnlCount(n), RLPTr(@"个样本")], NO, v >= 3);
}
static NSDictionary *AnlRunsRow(NSDictionary *q, NSString *label) {
    id n = q[@"clipped_runs"];
    if (![n isKindOfClass:[NSNumber class]] || !isfinite([(NSNumber *)n doubleValue]))
        return AnlRow(label, @"NA", YES, NO);
    const double v = [(NSNumber *)n doubleValue];
    if (v <= 0) return AnlRow(label, @"0", NO, NO);
    return AnlRow(label, [NSString stringWithFormat:@"%@ %@", RLPAnlCount(n), RLPTr(@"段削波")], NO, YES);
}
static NSDictionary *AnlThdnRow(NSDictionary *q, NSString *label) {
    if (!AnlFlagOK(q[@"thdn_available"])) return AnlRow(label, AnlNA_(RLPTr(@"多峰素材")), YES, NO);
    if (!RLPAnlAvail(q[@"thdn_db"])) return AnlRow(label, @"NA", YES, NO);
    NSString *pct = RLPAnlAvail(q[@"thdn_pct"])
        ? [NSString stringWithFormat:@"（%.3f%%）", [q[@"thdn_pct"] doubleValue]] : @"";
    return AnlRow(label, [NSString stringWithFormat:@"%.2f dB%@", [q[@"thdn_db"] doubleValue], pct], NO, NO);
}
static NSDictionary *AnlImdRow(NSDictionary *q, NSString *label) {
    if (!AnlFlagOK(q[@"imd_available"])) return AnlRow(label, AnlNA_(RLPTr(@"需双音素材")), YES, NO);
    NSString *v = RLPAnlVal(q[@"imd_db"], 2, @" dB");
    return AnlRow(label, v, [v isEqualToString:@"NA"], NO);
}
static NSDictionary *AnlWarnRowForTruePeak(NSDictionary *h) {
    if (!AnlFlagOK(h[@"true_peak_available"])) return nil;
    if (!RLPAnlAvail(h[@"true_peak_dbtp"]) || [h[@"true_peak_dbtp"] doubleValue] <= 0) return nil;
    const double v = [h[@"true_peak_dbtp"] doubleValue];
    return AnlWarn([NSString stringWithFormat:@"%@ %@%.2f dBTP", RLPTr(@"母带要修"), v > 0 ? @"+" : @"", v],
                   RLPTr(@"样本峰值只反映采样点，采样点之间的峰值只有真峰能看见"));
}

static NSArray *AnlRowsDyn(NSDictionary *h, NSInteger L) {
    NSMutableArray *a = [NSMutableArray array];
    NSDictionary *warn = AnlWarnRowForTruePeak(h);
    if (L <= 0) { if (warn) [a addObject:warn]; return a; }

    [a addObject:AnlSec(RLPTr(@"动态"))];
    [a addObject:AnlValRow(h, RLPTr(@"动态范围 DR"), @"dr_db", @"dr_available", 2, @" dB", RLPTr(@"素材过短"))];
    [a addObject:AnlValRow(h, RLPTr(@"响度 (LUFS)"), @"lufs", @"lufs_available", 2, @" LUFS", RLPTr(@"素材过短"))];
    [a addObject:AnlValRow(h, RLPTr(@"响度范围 LRA"), @"lra", @"lra_available", 2, @" LU", RLPTr(@"素材过短"))];
    {
        // 真峰：>0 带 "+" 并按 warn 显示（这是"母带过载"的信号）
        NSString *v = @"NA";
        BOOL na = YES, hot = NO;
        if (AnlFlagOK(h[@"true_peak_available"]) && RLPAnlAvail(h[@"true_peak_dbtp"])) {
            const double tp = [h[@"true_peak_dbtp"] doubleValue];
            v = [NSString stringWithFormat:@"%@%.2f dBTP", tp > 0 ? @"+" : @"", tp];
            na = NO; hot = tp > 0;
        }
        [a addObject:AnlRow(RLPTr(@"真峰 (dBTP)"), v, na, hot)];
    }
    [a addObject:AnlRow(RLPTr(@"样本峰值"), RLPAnlVal(h[@"peak_dbfs"], 2, @" dBFS"),
                        !RLPAnlAvail(h[@"peak_dbfs"]), NO)];
    [a addObject:AnlRow(RLPTr(@"声道"), AnlChannelsV(h),
                        [AnlChannelsV(h) isEqualToString:@"NA"], NO)];
    if (warn) [a addObject:warn];

    if (L >= 2) {
        [a addObject:AnlSec(RLPTr(@"采样规格"))];
        [a addObject:AnlRow(RLPTr(@"采样率"), RLPAnlVal(h[@"fs"], 0, @" Hz"),
                            !RLPAnlAvail(h[@"fs"]), NO)];
        [a addObject:AnlRow(RLPTr(@"位深"), RLPAnlVal(h[@"bits"], 0, @" bit"),
                            !RLPAnlAvail(h[@"bits"]), NO)];
        [a addObject:AnlRow(RLPTr(@"时长"), AnlDurV(h), !RLPAnlAvail(h[@"duration_sec"]), NO)];
        [a addObject:AnlSec(RLPTr(@"分析记录"))];
        [a addObject:AnlRow(RLPTr(@"分析状态"),
                            [h[@"status"] isKindOfClass:[NSString class]] ? h[@"status"] : @"NA",
                            ![h[@"status"] isKindOfClass:[NSString class]], NO)];
        [a addObject:AnlRow(RLPTr(@"分析时刻"), AnlClockOf(h[@"analyzed_at_ms"]),
                            [AnlClockOf(h[@"analyzed_at_ms"]) isEqualToString:@"NA"], NO)];
        if ([h[@"error"] isKindOfClass:[NSString class]] && [h[@"error"] length])
            [a addObject:AnlNote([NSString stringWithFormat:@"%@：%@", RLPTr(@"后端说明"), h[@"error"]])];
    }
    return a;
}

static NSArray *AnlRowsQual(NSDictionary *h, NSInteger L) {
    NSMutableArray *a = [NSMutableArray array];
    if (L <= 0) return a;
    NSDictionary *q = AnlQ(h);
    const BOOL qOK = [q[@"available"] isKindOfClass:[NSNumber class]] && [q[@"available"] boolValue];
    if (!qOK) {
        // 样本不足时不摆一堆无意义的数字（那正是"看着很专业其实是噪声"的来源）
        [a addObject:AnlSec(RLPTr(@"可用性"))];
        [a addObject:AnlRow(RLPTr(@"音质指标"), RLPTr(@"不适用（样本不足）"), YES, NO)];
        [a addObject:AnlRow(RLPTr(@"谱窗数"), RLPAnlCount(q[@"spectral_windows"]),
                            (BOOL)!RLPAnlAvail(q[@"spectral_windows"]), NO)];
        [a addObject:AnlNote([q[@"note"] isKindOfClass:[NSString class]] && [q[@"note"] length]
                             ? q[@"note"] : RLPTr(@"素材太短或静音占比过高，无法做稳定的频谱统计"))];
        return a;
    }

    [a addObject:AnlSec(RLPTr(@"音质"))];
    [a addObject:AnlClipRow(q, RLPTr(@"削波样本"))];
    [a addObject:AnlLongestRow(q, RLPTr(@"最长连续削波"))];
    [a addObject:AnlRow(RLPTr(@"峰值因子"), RLPAnlVal(q[@"crest_db"], 2, @" dB"),
                        !RLPAnlAvail(q[@"crest_db"]), NO)];
    [a addObject:AnlRow(RLPTr(@"信噪比"), RLPAnlVal(q[@"snr_db"], 2, @" dB"),
                        !RLPAnlAvail(q[@"snr_db"]), NO)];
    [a addObject:AnlRow(RLPTr(@"频谱重心"), RLPAnlVal(q[@"centroid_hz"], 0, @" Hz"),
                        !RLPAnlAvail(q[@"centroid_hz"]), NO)];
    [a addObject:AnlRow(RLPTr(@"本底噪声"), RLPAnlVal(q[@"noise_floor_dbfs"], 2, @" dBFS"),
                        !RLPAnlAvail(q[@"noise_floor_dbfs"]), NO)];
    [a addObject:AnlRow(RLPTr(@"10k 以上能量"), AnlHfV(h, q),
                        [AnlHfV(h, q) hasPrefix:@"NA"], NO)];
    {
        NSString *corr = AnlStereoV(h, q, @"channel_corr", 3, @"");
        [a addObject:AnlRow(RLPTr(@"立体声相关"), corr, [corr hasPrefix:@"NA"], NO)];
    }

    if (L >= 2) {
        [a addObject:AnlSec(RLPTr(@"失真"))];
        [a addObject:AnlThdnRow(q, RLPTr(@"THD+N"))];
        [a addObject:AnlImdRow(q, RLPTr(@"互调失真 IMD"))];
        [a addObject:AnlRow(RLPTr(@"非谐波残留"), RLPAnlVal(q[@"non_tonal_db"], 2, @" dB"),
                            !RLPAnlAvail(q[@"non_tonal_db"]), NO)];
        [a addObject:AnlRow(RLPTr(@"THD+N 方法"),
                            [q[@"thdn_method"] isKindOfClass:[NSString class]] ? q[@"thdn_method"] : @"NA",
                            ![q[@"thdn_method"] isKindOfClass:[NSString class]], NO)];

        [a addObject:AnlSec(RLPTr(@"噪声"))];
        [a addObject:AnlRow(RLPTr(@"频谱最小值"), RLPAnlVal(q[@"spectral_min_dbfs"], 2, @" dBFS"),
                            !RLPAnlAvail(q[@"spectral_min_dbfs"]), NO)];
        [a addObject:AnlRow(@"RMS", RLPAnlVal(q[@"rms_dbfs"], 2, @" dBFS"),
                            !RLPAnlAvail(q[@"rms_dbfs"]), NO)];
        [a addObject:AnlRow(RLPTr(@"静音占比"), RLPAnlVal(q[@"silence_pct"], 2, @"%"),
                            !RLPAnlAvail(q[@"silence_pct"]), NO)];

        [a addObject:AnlSec(RLPTr(@"频响"))];
        [a addObject:AnlRow(RLPTr(@"频谱倾斜"), RLPAnlVal(q[@"tilt_db_per_oct"], 2, @" dB/oct"),
                            !RLPAnlAvail(q[@"tilt_db_per_oct"]), NO)];
        [a addObject:AnlRow(RLPTr(@"95% 滚降点"), RLPAnlVal(q[@"rolloff95_hz"], 0, @" Hz"),
                            !RLPAnlAvail(q[@"rolloff95_hz"]), NO)];
        [a addObject:AnlRow(RLPTr(@"10k 以上能量"), AnlHfV(h, q), [AnlHfV(h, q) hasPrefix:@"NA"], NO)];
        [a addObject:AnlRow(RLPTr(@"频谱重心"), RLPAnlVal(q[@"centroid_hz"], 0, @" Hz"),
                            !RLPAnlAvail(q[@"centroid_hz"]), NO)];

        [a addObject:AnlSec(RLPTr(@"削波"))];
        [a addObject:AnlClipRow(q, RLPTr(@"削波样本"))];
        [a addObject:AnlRunsRow(q, RLPTr(@"削波段数"))];
        [a addObject:AnlLongestRow(q, RLPTr(@"最长连续削波"))];
        [a addObject:AnlRow(RLPTr(@"峰值因子"), RLPAnlVal(q[@"crest_db"], 2, @" dB"),
                            !RLPAnlAvail(q[@"crest_db"]), NO)];

        [a addObject:AnlSec(RLPTr(@"立体声"))];
        {
            NSString *corr = AnlStereoV(h, q, @"channel_corr", 3, @"");
            [a addObject:AnlRow(RLPTr(@"声道相关"), corr, [corr hasPrefix:@"NA"], NO)];
            NSString *mono = AnlStereoV(h, q, @"mono_loss_db", 2, @" dB");
            [a addObject:AnlRow(RLPTr(@"单声道兼容损失"), mono, [mono hasPrefix:@"NA"], NO)];
            NSString *sm = AnlStereoV(h, q, @"side_mid_db", 1, @" dB");
            [a addObject:AnlRow(@"side/mid", sm, [sm hasPrefix:@"NA"], NO)];
        }

        [a addObject:AnlSec(RLPTr(@"动态细化"))];
        [a addObject:AnlRow(@"P95−P10", RLPAnlVal(q[@"dyn_p95_p10_db"], 2, @" dB"),
                            !RLPAnlAvail(q[@"dyn_p95_p10_db"]), NO)];
        [a addObject:AnlRow(RLPTr(@"动态重心"), RLPAnlVal(q[@"dyn_centroid_dbfs"], 2, @" dBFS"),
                            !RLPAnlAvail(q[@"dyn_centroid_dbfs"]), NO)];
        [a addObject:AnlRow(RLPTr(@"安静段 P10"), RLPAnlVal(q[@"quiet_p10_dbfs"], 2, @" dBFS"),
                            !RLPAnlAvail(q[@"quiet_p10_dbfs"]), NO)];
        [a addObject:AnlRow(RLPTr(@"谱窗数"), RLPAnlCount(q[@"spectral_windows"]),
                            (BOOL)!RLPAnlAvail(q[@"spectral_windows"]), NO)];
        if ([q[@"note"] isKindOfClass:[NSString class]] && [q[@"note"] length])
            [a addObject:AnlNote(q[@"note"])];
    }
    return a;
}

static NSArray *AnlRowsFake(NSDictionary *h, NSInteger L) {
    NSMutableArray *a = [NSMutableArray array];
    if (L <= 0) return a;
    NSDictionary *q = AnlQ(h);

    [a addObject:AnlSec(RLPTr(@"判定"))];
    {
        NSString *verdict = AnlVerdict(h);
        BOOL hot = ([h[@"lossless_suspected"] isKindOfClass:[NSNumber class]] &&
                    [h[@"lossless_suspected"] boolValue]);
        [a addObject:AnlRow(RLPTr(@"判定"), verdict, NO, hot)];
    }
    [a addObject:AnlRow(RLPTr(@"截止频率"), AnlCutoffV(h), NO, NO)];
    [a addObject:AnlRow(RLPTr(@"置信度"), AnlConfV(h), [AnlConfV(h) isEqualToString:@"NA"], NO)];
    [a addObject:AnlRow(RLPTr(@"谱窗数"), RLPAnlCount(q[@"spectral_windows"]),
                        (BOOL)!RLPAnlAvail(q[@"spectral_windows"]), NO)];
    [a addObject:AnlRow(RLPTr(@"时长"), AnlDurV(h), !RLPAnlAvail(h[@"duration_sec"]), NO)];
    {
        const BOOL hasFake = [h[@"fake24"] isKindOfClass:[NSNumber class]];
        const BOOL fake24 = hasFake && [h[@"fake24"] boolValue];
        NSString *v = hasFake ? (fake24 ? RLPTr(@"是") : RLPTr(@"否")) : @"NA";
        [a addObject:AnlRow(RLPTr(@"24bit 实为低位深"), v, !hasFake, fake24)];
    }

    if (L >= 2) {
        [a addObject:AnlSec(RLPTr(@"原始证据"))];
        [a addObject:AnlRow(@"lossless_suspected",
                            [h[@"lossless_suspected"] isKindOfClass:[NSNumber class]]
                                ? ([(NSNumber *)h[@"lossless_suspected"] boolValue] ? @"true" : @"false") : @"NA",
                            ![h[@"lossless_suspected"] isKindOfClass:[NSNumber class]], NO)];
        [a addObject:AnlRow(@"cutoff_hz", RLPAnlVal(h[@"cutoff_hz"], 1, @" Hz"),
                            !RLPAnlAvail(h[@"cutoff_hz"]), NO)];
        [a addObject:AnlRow(@"confidence", RLPAnlVal(h[@"confidence"], 3, @""),
                            !RLPAnlAvail(h[@"confidence"]), NO)];
        [a addObject:AnlRow(@"fs / 2",
                            RLPAnlAvail(h[@"fs"])
                                ? [NSString stringWithFormat:@"%lld Hz", (long long)llround([h[@"fs"] doubleValue] / 2.0)]
                                : @"NA",
                            !RLPAnlAvail(h[@"fs"]), NO)];
        [a addObject:AnlRunsRow(q, RLPTr(@"削波段数"))];
        [a addObject:AnlRow(RLPTr(@"削波占比"), RLPAnlVal(q[@"clipped_pct"], 3, @"%"),
                            !RLPAnlAvail(q[@"clipped_pct"]), NO)];
        [a addObject:AnlRow(@"RMS", RLPAnlVal(q[@"rms_dbfs"], 2, @" dBFS"),
                            !RLPAnlAvail(q[@"rms_dbfs"]), NO)];
        [a addObject:AnlRow(RLPTr(@"静音占比"), RLPAnlVal(q[@"silence_pct"], 2, @"%"),
                            !RLPAnlAvail(q[@"silence_pct"]), NO)];
        [a addObject:AnlRow(RLPTr(@"频谱倾斜"), RLPAnlVal(q[@"tilt_db_per_oct"], 2, @" dB/oct"),
                            !RLPAnlAvail(q[@"tilt_db_per_oct"]), NO)];
        [a addObject:AnlRow(RLPTr(@"95% 滚降点"), RLPAnlVal(q[@"rolloff95_hz"], 0, @" Hz"),
                            !RLPAnlAvail(q[@"rolloff95_hz"]), NO)];
        [a addObject:AnlThdnRow(q, RLPTr(@"THD+N"))];
        [a addObject:AnlImdRow(q, RLPTr(@"互调失真 IMD"))];
        [a addObject:AnlRow(RLPTr(@"非谐波残留"), RLPAnlVal(q[@"non_tonal_db"], 2, @" dB"),
                            !RLPAnlAvail(q[@"non_tonal_db"]), NO)];
        [a addObject:AnlRow(RLPTr(@"动态重心"), RLPAnlVal(q[@"dyn_centroid_dbfs"], 2, @" dBFS"),
                            !RLPAnlAvail(q[@"dyn_centroid_dbfs"]), NO)];
        [a addObject:AnlRow(@"P95−P10", RLPAnlVal(q[@"dyn_p95_p10_db"], 2, @" dB"),
                            !RLPAnlAvail(q[@"dyn_p95_p10_db"]), NO)];
    }
    if ([h[@"reason"] isKindOfClass:[NSString class]] && [h[@"reason"] length]) {
        [a addObject:AnlSec(RLPTr(@"判定依据"))];
        [a addObject:AnlNote(h[@"reason"])];
    }
    if ([h[@"error"] isKindOfClass:[NSString class]] && [h[@"error"] length])
        [a addObject:AnlNote([NSString stringWithFormat:@"%@：%@", RLPTr(@"后端说明"), h[@"error"]])];
    return a;
}

NSArray<NSDictionary *> *RLPAnlRowsForCard(NSDictionary *health, NSString *cardKey, NSInteger level) {
    const NSInteger L = MAX(0, MIN(2, level));
    NSString *key = [cardKey isKindOfClass:[NSString class]] ? cardKey : @"";
    if (![health isKindOfClass:[NSDictionary class]] || !health.count) return @[];
    if ([key isEqualToString:@"dyn"]) return AnlRowsDyn(health, L);
    if ([key isEqualToString:@"qual"]) return AnlRowsQual(health, L);
    if ([key isEqualToString:@"fake"]) return AnlRowsFake(health, L);
    return @[];
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
