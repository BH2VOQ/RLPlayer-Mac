// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPWorkbench.h"
#import "RLPSupport.h"

NSArray<NSString *> *RLPABSlotKeys(void) {
    // 只有听感相关键。**没有 device / backend / hogexcl / buffer / volume**（切它们会抢独占/爆音）。
    return @[@"filter", @"filterNx", @"rate", @"rateFamilyPolicy", @"dsd", @"dsdnative",
             @"directsdm", @"shaper", @"twostage", @"taps", @"atten", @"transition", @"phase",
             @"modfamily", @"modorder", @"modcut", @"moddith", @"oobgain", @"ahmbits",
             @"sdmfilt", @"sdmfiltnx", @"isp", @"dsdkind", @"dsdconv", @"dsd2stage",
             @"bits", @"channels", @"trim", @"loudness", @"rgmode", @"eq", @"ir", @"irgpu"];
}

static NSString *Str(NSDictionary *d, NSString *k) {
    id v = d[k];
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
    return nil;
}

NSDictionary<NSString *, NSString *> *RLPABSnapshotFromSettings(NSDictionary *settings) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (![settings isKindOfClass:[NSDictionary class]]) return out;
    for (NSString *k in RLPABSlotKeys()) {
        NSString *v = Str(settings, k);
        if (v) out[k] = v;      // 缺失的键不写（让后端保持原值），不臆造默认
    }
    return out;
}

NSString *RLPABFormBody(NSDictionary<NSString *, NSString *> *snapshot) {
    if (![snapshot isKindOfClass:[NSDictionary class]] || !snapshot.count) return @"";
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in RLPABSlotKeys()) {          // 固定顺序，序列化稳定
        NSString *v = snapshot[k];
        if (![v isKindOfClass:[NSString class]]) continue;
        [parts addObject:[NSString stringWithFormat:@"%@=%@", k, RLPEnc(v)]];
    }
    return [parts componentsJoinedByString:@"&"];
}

NSInteger RLPABMatchSlot(NSDictionary *settings, NSArray<NSDictionary<NSString *, NSString *> *> *slots) {
    if (![settings isKindOfClass:[NSDictionary class]] || ![slots isKindOfClass:[NSArray class]]) return -1;
    NSDictionary *cur = RLPABSnapshotFromSettings(settings);
    for (NSInteger i = 0; i < (NSInteger)slots.count; ++i) {
        NSDictionary *s = slots[i];
        if (![s isKindOfClass:[NSDictionary class]] || !s.count) continue;   // 空槽不参与
        if ([s isEqualToDictionary:cur]) return i;
    }
    return -1;
}

NSString *RLPABSlotSummary(NSDictionary<NSString *, NSString *> *snapshot) {
    if (![snapshot isKindOfClass:[NSDictionary class]] || !snapshot.count)
        return RLPTr(@"未保存");
    NSMutableArray *p = [NSMutableArray array];
    NSString *f = snapshot[@"filter"];
    if (f.length) [p addObject:f];
    NSString *dsd = snapshot[@"dsd"];
    if (dsd.length && dsd.integerValue > 0) [p addObject:[NSString stringWithFormat:@"DSD%@", dsd]];
    else {
        NSString *rate = snapshot[@"rate"];
        if (rate.length) [p addObject:([rate isEqualToString:@"follow"] ? RLPTr(@"跟随源") : [NSString stringWithFormat:@"%@ Hz", rate])];
    }
    NSString *eq = snapshot[@"eq"];
    if (eq.length) [p addObject:([eq isEqualToString:@"1"] ? RLPTr(@"EQ 开") : RLPTr(@"EQ 关"))];
    return p.count ? [p componentsJoinedByString:@" · "] : RLPTr(@"未保存");
}

NSArray<NSDictionary *> *RLPFilterGroups(NSArray<NSDictionary *> *items) {
    if (![items isKindOfClass:[NSArray class]]) return @[];
    // 组顺序固定；每组保留后端原始 item（不复制第二份滤波表）。
    NSArray *names = @[@"gauss", @"poly-sinc", @"sinc", @"ext2", RLPTr(@"其它")];
    NSMutableArray *buckets = [NSMutableArray array];
    for (NSUInteger i = 0; i < names.count; ++i) [buckets addObject:[NSMutableArray array]];
    for (id it in items) {
        if (![it isKindOfClass:[NSDictionary class]]) continue;
        NSString *n = [it[@"name"] isKindOfClass:[NSString class]] ? [(NSString *)it[@"name"] lowercaseString] : @"";
        if (!n.length) continue;
        NSUInteger idx = names.count - 1;                 // 默认"其它"
        if ([n rangeOfString:@"gauss"].location != NSNotFound) idx = 0;
        else if ([n hasPrefix:@"poly-sinc"]) idx = 1;
        else if ([n hasPrefix:@"sinc"]) idx = 2;
        else if ([n hasPrefix:@"ext2"]) idx = 3;
        [buckets[idx] addObject:it];
    }
    NSMutableArray *out = [NSMutableArray array];
    for (NSUInteger i = 0; i < names.count; ++i) {
        if ([buckets[i] count] == 0) continue;
        [out addObject:@{@"group": names[i], @"items": buckets[i]}];
    }
    return out;
}

NSString *RLPFilterFamilyKey(NSString *name) {
    if (![name isKindOfClass:[NSString class]] || !name.length) return @"";
    NSString *n = [name lowercaseString];
    // 相位/长度变体后缀去掉后就是家族：poly-sinc-gauss-long-2s / -mp / -ip 同属 gauss-long。
    // 只去掉**明确的相位与两段后缀**，不动 short/long/hires 这些"长度档"——
    // 它们是不同滤波，混为一谈会让相位快切把用户切到另一个长度档上去。
    NSArray *suffixes = @[@"-mp", @"-ip", @"-lp", @"-2s"];
    BOOL changed = YES;
    while (changed) {
        changed = NO;
        for (NSString *s in suffixes) {
            if ([n hasSuffix:s]) { n = [n substringToIndex:n.length - s.length]; changed = YES; }
        }
    }
    return n;
}

NSString *RLPFilterWithPhase(NSString *currentName, NSString *wantPhase, NSArray<NSDictionary *> *items) {
    if (![currentName isKindOfClass:[NSString class]] || !currentName.length) return nil;
    if (![wantPhase isKindOfClass:[NSString class]] || !wantPhase.length) return nil;
    if (![items isKindOfClass:[NSArray class]]) return nil;
    NSString *fam = RLPFilterFamilyKey(currentName);
    if (!fam.length) return nil;
    for (id it in items) {
        if (![it isKindOfClass:[NSDictionary class]]) continue;
        NSString *n = [it[@"name"] isKindOfClass:[NSString class]] ? it[@"name"] : nil;
        NSString *ph = [it[@"phase"] isKindOfClass:[NSString class]] ? it[@"phase"] : nil;
        if (!n.length || !ph.length) continue;
        if (![ph isEqualToString:wantPhase]) continue;
        if (![RLPFilterFamilyKey(n) isEqualToString:fam]) continue;   // 不跨家族
        return n;
    }
    return nil;   // 同家族没有该相位 ⟹ 如实返回 nil，UI 禁用那一档
}

BOOL RLPWorkbenchFilterUsesNx(NSDictionary *item) {
    return [item isKindOfClass:[NSDictionary class]] && [item[@"forNx"] boolValue];
}

NSString *RLPWorkbenchEditingFilter(NSDictionary *settings, BOOL editingNx, BOOL *outUsesNx) {
    NSString *f1x = Str(settings, @"filter") ?: @"";
    NSString *fnx = Str(settings, @"filterNx") ?: @"";
    if (editingNx) {
        if (fnx.length) {
            if (outUsesNx) *outUsesNx = YES;
            return fnx;
        }
        if (outUsesNx) *outUsesNx = NO;
        return f1x;
    }
    if (f1x.length) {
        if (outUsesNx) *outUsesNx = NO;
        return f1x;
    }
    if (fnx.length) {
        if (outUsesNx) *outUsesNx = YES;
        return fnx;
    }
    if (outUsesNx) *outUsesNx = NO;
    return @"";
}

NSString *RLPWorkbenchActivePlaybackFilter(NSDictionary *settings, NSDictionary *status, NSString *defaultName) {
    NSString *f1x = Str(settings, @"filter") ?: @"";
    NSString *fnx = Str(settings, @"filterNx") ?: @"";
    double fs = 0.0;
    if ([status isKindOfClass:[NSDictionary class]]) {
        id v = status[@"inRate"];
        if ([v respondsToSelector:@selector(doubleValue)]) fs = [v doubleValue];
    }
    // Match the backend PCM/SDM slot fallback order; the editor slot is unrelated.
    if ([Str(settings, @"dsd") integerValue] >= 64) {
        NSString *sdm1 = Str(settings, @"sdmfilt") ?: @"";
        NSString *sdmNx = Str(settings, @"sdmfiltnx") ?: @"";
        if (fs >= 88200.0) {
            if (sdmNx.length) return sdmNx;
            if (fnx.length) return fnx;
            return sdm1.length ? sdm1 : (defaultName ?: @"");
        }
        if (sdm1.length) return sdm1;
    }
    if (fs >= 88200.0 && fnx.length) return fnx;
    if (f1x.length) return f1x;
    return defaultName ?: @"";
}

static BOOL IsDsdOut(NSDictionary *s) {
    NSString *d = Str(s, @"dsd");
    return d.length && d.integerValue > 0;
}

BOOL RLPChainNodeApplies(NSString *node, NSDictionary *settings) {
    return RLPChainNodeDisabledReason(node, settings) == nil;
}

NSString *RLPChainNodeDisabledReason(NSString *node, NSDictionary *settings) {
    if (![node isKindOfClass:[NSString class]]) return nil;
    const BOOL dsd = IsDsdOut(settings);
    NSString *rate = Str(settings, @"rate") ?: @"follow";
    const BOOL resampling = !(rate.length == 0 || [rate isEqualToString:@"follow"]);
    if ([node isEqualToString:@"sdm"]) {
        // PCM 输出根本不经过 SDM 调制器 —— 灰掉并说清，比画一个假节点有价值。
        if (!dsd) return RLPTr(@"PCM 输出不经过调制器");
        return nil;
    }
    if ([node isEqualToString:@"shaper"]) {
        // DoP 路径强制无抖动（抖动交给调制器之后的 1-bit 量化）。
        if (dsd) return RLPTr(@"DSD/DoP 路径强制无抖动");
        return nil;
    }
    if ([node isEqualToString:@"resample"]) {
        if (dsd) return nil;      // DSD 路径有自己的速率转换，节点仍适用（显示 DirectSDM/转换）
        if (!resampling) return RLPTr(@"跟随源，不做重采样");
        return nil;
    }
    if ([node isEqualToString:@"eq"]) {
        NSString *eq = Str(settings, @"eq");
        if (eq.length && ![eq isEqualToString:@"1"]) return RLPTr(@"EQ 已旁路");
        return nil;
    }
    if ([node isEqualToString:@"ir"]) {
        NSString *ir = Str(settings, @"ir");
        if (!ir.length || [ir isEqualToString:@"0"]) return RLPTr(@"未加载卷积 IR");
        return nil;
    }
    return nil;   // src / out 恒适用
}

NSString *RLPProfileSummary(NSDictionary *profile) {
    if (![profile isKindOfClass:[NSDictionary class]]) return RLPTr(@"未保存");
    NSDictionary *keys = [profile[@"keys"] isKindOfClass:[NSDictionary class]] ? profile[@"keys"] : @{};
    NSMutableArray<NSString *> *p = [NSMutableArray array];
    NSString *f = keys[@"filter"];
    if ([f isKindOfClass:[NSString class]] && f.length) [p addObject:f];
    NSString *dsd = keys[@"dsd"];
    if ([dsd isKindOfClass:[NSString class]] && dsd.integerValue > 0) {
        [p addObject:[NSString stringWithFormat:@"DSD%@", dsd]];
    } else {
        NSString *rate = keys[@"rate"];
        if ([rate isKindOfClass:[NSString class]] && rate.length)
            [p addObject:([rate isEqualToString:@"follow"] ? RLPTr(@"跟随源")
                                                          : [NSString stringWithFormat:@"%@ Hz", rate])];
    }
    NSString *eqName = profile[@"eqId"];
    if ([eqName isKindOfClass:[NSString class]] && eqName.length) [p addObject:eqName];
    return p.count ? [p componentsJoinedByString:@" · "] : RLPTr(@"未保存");
}

static BOOL IsNonZeroOverride(NSString *v) {
    if (!v.length) return NO;
    if ([v isEqualToString:@"0"] || [v isEqualToString:@"0.0"]) return NO;
    return [v doubleValue] != 0.0 || [v isEqualToString:@"auto"] == NO;
}

NSArray<NSString *> *RLPWorkbenchFilterOverrideKeys(NSDictionary *settings) {
    if (![settings isKindOfClass:[NSDictionary class]]) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSString *phase = Str(settings, @"phase");
    if (phase.length) [out addObject:@"phase"];
    NSString *taps = Str(settings, @"taps");
    if (taps.length && [taps integerValue] > 0) [out addObject:@"taps"];
    NSString *atten = Str(settings, @"atten");
    if (atten.length && IsNonZeroOverride(atten) && [atten doubleValue] > 0.0) [out addObject:@"atten"];
    NSString *trans = Str(settings, @"transition");
    if (trans.length && IsNonZeroOverride(trans) && [trans doubleValue] > 0.0) [out addObject:@"transition"];
    return out;
}

BOOL RLPWorkbenchHasFilterOverride(NSDictionary *settings) {
    return RLPWorkbenchFilterOverrideKeys(settings).count > 0;
}

NSDictionary<NSString *, NSString *> *RLPWorkbenchClearFilterOverridePayload(void) {
    return @{@"phase": @"", @"taps": @"0", @"atten": @"0", @"transition": @"0"};
}

NSString *RLPWorkbenchFilterOverrideSummary(NSDictionary *settings) {
    NSArray<NSString *> *keys = RLPWorkbenchFilterOverrideKeys(settings);
    if (!keys.count) return nil;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *k in keys) {
        NSString *v = Str(settings, k) ?: @"";
        if ([k isEqualToString:@"phase"]) [parts addObject:[NSString stringWithFormat:@"%@=%@", RLPTr(@"相位"), v]];
        else if ([k isEqualToString:@"taps"]) [parts addObject:[NSString stringWithFormat:@"%@=%@", RLPTr(@"抽头"), v]];
        else if ([k isEqualToString:@"atten"]) [parts addObject:[NSString stringWithFormat:@"%@=%@ dB", RLPTr(@"衰减"), v]];
        else if ([k isEqualToString:@"transition"]) [parts addObject:[NSString stringWithFormat:@"%@=%@", RLPTr(@"过渡带"), v]];
    }
    return [parts componentsJoinedByString:@" · "];
}

static NSString *MonValStr(NSDictionary *st, NSString *key) {
    if (![st isKindOfClass:[NSDictionary class]]) return nil;
    id v = st[key];
    if (!v || v == [NSNull null]) return nil;
    if ([v isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)v;
        return s.length ? s : nil;
    }
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
    return nil;
}

static NSString *MonHz(NSDictionary *st, NSString *key) {
    id v = [st isKindOfClass:[NSDictionary class]] ? st[key] : nil;
    if (![v respondsToSelector:@selector(doubleValue)]) return @"N/A";
    double hz = [v doubleValue];
    return (hz > 0.0) ? [NSString stringWithFormat:@"%.0f Hz", hz] : @"N/A";
}

static NSString *MonBool(NSDictionary *st, NSString *key, NSString *yesStr, NSString *noStr) {
    id v = [st isKindOfClass:[NSDictionary class]] ? st[key] : nil;
    if (!v || v == [NSNull null] || ![v respondsToSelector:@selector(boolValue)]) return @"N/A";
    return [v boolValue] ? yesStr : noStr;
}

static NSString *MonNum(NSDictionary *st, NSString *key, NSString *unit, int decimals, BOOL positiveOnly) {
    id v = [st isKindOfClass:[NSDictionary class]] ? st[key] : nil;
    if (!v || v == [NSNull null] || ![v respondsToSelector:@selector(doubleValue)]) return @"N/A";
    double val = [v doubleValue];
    if (positiveOnly && val <= 0.0) return @"N/A";
    NSString *fmt = [NSString stringWithFormat:@"%%.%df", decimals];
    NSString *num = [NSString stringWithFormat:fmt, val];
    return unit.length ? [NSString stringWithFormat:@"%@ %@", num, unit] : num;
}

NSArray<NSDictionary<NSString *, NSString *> *> *RLPWorkbenchMonitorRows(NSDictionary *status) {
    NSDictionary *st = [status isKindOfClass:[NSDictionary class]] ? status : @{};
    const BOOL hasStatus = st.count > 0;
    auto Row = ^NSDictionary *(NSString *grp, NSString *key, NSString *label, NSString *val) {
        return @{@"group": grp, @"key": key, @"label": label, @"value": val.length ? val : @"N/A"};
    };
    NSString *playState = @"N/A";
    if (hasStatus && st[@"playing"] != nil) {
        BOOL playing = [st[@"playing"] boolValue];
        BOOL paused = [st[@"paused"] boolValue];
        playState = playing ? (paused ? RLPTr(@"已暂停") : RLPTr(@"播放中")) : RLPTr(@"已停止");
    }
    NSString *outBits = @"N/A";
    if ([st[@"outBits"] respondsToSelector:@selector(integerValue)] && [st[@"outBits"] integerValue] > 0) {
        outBits = [NSString stringWithFormat:@"%ld bit", (long)[st[@"outBits"] integerValue]];
    }
    NSString *dsdVal = @"N/A";
    if ([st[@"dsd"] respondsToSelector:@selector(integerValue)]) {
        NSInteger d = [st[@"dsd"] integerValue];
        dsdVal = (d > 0) ? [NSString stringWithFormat:@"DSD%ld", (long)d] : @"PCM (0)";
    }
    NSString *latVal = @"N/A";
    if (hasStatus && [st[@"latencyKnown"] boolValue]) {
        latVal = MonNum(st, @"latencyMs", @"ms", 1, NO);
        NSString *lsrc = MonValStr(st, @"latencySource");
        if (lsrc.length) latVal = [NSString stringWithFormat:@"%@ (%@)", latVal, lsrc];
    }
    NSString *bpVal = MonValStr(st, @"bitPerfect") ?: @"N/A";
    NSString *bpWhy = MonValStr(st, @"bitPerfectWhy");
    if (![bpVal isEqualToString:@"N/A"] && bpWhy.length) {
        bpVal = [NSString stringWithFormat:@"%@ · %@", bpVal, bpWhy];
    }
    return @[
        Row(RLPTr(@"信号与采样率"), @"playing", RLPTr(@"运行状态"), playState),
        Row(RLPTr(@"信号与采样率"), @"inRate", RLPTr(@"源采样率"), MonHz(st, @"inRate")),
        Row(RLPTr(@"信号与采样率"), @"outRate", RLPTr(@"输出采样率"), MonHz(st, @"outRate")),
        Row(RLPTr(@"信号与采样率"), @"outBits", RLPTr(@"输出位深"), outBits),
        Row(RLPTr(@"信号与采样率"), @"resampled", RLPTr(@"是否重采样"), hasStatus ? MonBool(st, @"resampled", RLPTr(@"是"), RLPTr(@"否")) : @"N/A"),
        Row(RLPTr(@"信号与采样率"), @"rateFamilyPolicy", RLPTr(@"采样率族策略"), MonValStr(st, @"rateFamilyPolicy") ?: @"N/A"),

        Row(RLPTr(@"输出与独占"), @"outMode", RLPTr(@"输出后端"), MonValStr(st, @"outMode") ?: @"N/A"),
        Row(RLPTr(@"输出与独占"), @"transport", RLPTr(@"传输方式"), MonValStr(st, @"transport") ?: @"N/A"),
        Row(RLPTr(@"输出与独占"), @"hogAcquired", RLPTr(@"Hog 独占"), hasStatus ? MonBool(st, @"hogAcquired", RLPTr(@"已获取"), RLPTr(@"未获取")) : @"N/A"),
        Row(RLPTr(@"输出与独占"), @"bitPerfect", @"Bit-Perfect", bpVal),

        Row(RLPTr(@"DSD 与调制"), @"dsd", RLPTr(@"DSD 档位"), dsdVal),
        Row(RLPTr(@"DSD 与调制"), @"modFamily", RLPTr(@"调制器族"), MonValStr(st, @"modFamily") ?: @"N/A"),
        Row(RLPTr(@"DSD 与调制"), @"modOrder", RLPTr(@"生效阶数"), ([st[@"modOrder"] respondsToSelector:@selector(integerValue)] && [st[@"modOrder"] integerValue] > 0) ? [st[@"modOrder"] stringValue] : @"N/A"),
        Row(RLPTr(@"DSD 与调制"), @"fallbackWhy", RLPTr(@"回退说明"), MonValStr(st, @"fallbackWhy") ?: @"N/A"),

        Row(RLPTr(@"性能与遥测"), @"gpuUsed", RLPTr(@"GPU 参与"), hasStatus ? MonBool(st, @"gpuUsed", RLPTr(@"是"), RLPTr(@"否")) : @"N/A"),
        Row(RLPTr(@"性能与遥测"), @"latencyMs", RLPTr(@"输出延迟"), latVal),
        Row(RLPTr(@"性能与遥测"), @"dry", RLPTr(@"缓冲欠载 (dry)"), hasStatus ? MonNum(st, @"dry", @"", 0, NO) : @"N/A"),
        Row(RLPTr(@"性能与遥测"), @"decodeMs", RLPTr(@"解码耗时"), hasStatus ? MonNum(st, @"decodeMs", @"ms", 2, NO) : @"N/A"),
        Row(RLPTr(@"性能与遥测"), @"dspBlockMs", RLPTr(@"DSP 块耗时"), hasStatus ? MonNum(st, @"dspBlockMs", @"ms", 2, NO) : @"N/A"),
        Row(RLPTr(@"性能与遥测"), @"wsMb", RLPTr(@"内存占用"), hasStatus ? MonNum(st, @"wsMb", @"MB", 1, YES) : @"N/A"),
    ];
}
