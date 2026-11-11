// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPWorkbench.h"
#import "RLPSupport.h"

NSArray<NSString *> *RLPABSlotKeys(void) {
    // 只有听感相关键。**没有 device / backend / hogexcl**（切它们会抢独占/爆音）。
    return @[@"filter", @"filterNx", @"rate", @"dsd", @"shaper",
             @"modfamily", @"modorder", @"bits", @"eq", @"taps"];
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
