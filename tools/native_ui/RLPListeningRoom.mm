// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPListeningRoom.h"
#import "RLPSupport.h"

NSString *RLPProfileForPlayMode(RLPPlayMode3 mode, BOOL sourceIsDsd) {
    switch (mode) {
        case RLPPlayMode3Direct: return @"bitperfect";
        case RLPPlayMode3Pcm:    return @"pcm";
        case RLPPlayMode3Dsd:    return sourceIsDsd ? @"dsd" : @"pcm2dsd";
    }
    return @"bitperfect";
}

BOOL RLPPathIsDsd(NSString *path) {
    if (![path isKindOfClass:[NSString class]] || !path.length) return NO;
    NSString *ext = path.pathExtension.lowercaseString;
    return [ext isEqualToString:@"dsf"] || [ext isEqualToString:@"dff"] || [ext isEqualToString:@"dsd"];
}

NSString *RLPToneStyleName(RLPToneStyle style) {
    switch (style) {
        case RLPToneStyleSharp:    return RLPTr(@"清亮锐利");
        case RLPToneStyleBalanced: return RLPTr(@"均衡自然");
        case RLPToneStyleWarm:     return RLPTr(@"柔和温润");
    }
    return RLPTr(@"均衡自然");
}

static BOOL IsGauss(NSDictionary *item) {
    NSString *n = [item[@"name"] isKindOfClass:[NSString class]] ? item[@"name"] : @"";
    return [n.lowercaseString rangeOfString:@"gauss"].location != NSNotFound;
}
static NSString *ItemName(NSDictionary *item) {
    return [item[@"name"] isKindOfClass:[NSString class]] ? item[@"name"] : nil;
}
/// 只收"普通滤波"（forNx=false）作为听音风格的候选：Nx 专用项属于另一条链路，
/// 把它们混进来会让用户选了个在当前采样率下根本不生效的滤波。
static NSArray<NSDictionary *> *Usable(NSArray<NSDictionary *> *items) {
    NSMutableArray *out = [NSMutableArray array];
    for (id it in items) {
        if (![it isKindOfClass:[NSDictionary class]]) continue;
        if (!ItemName(it).length) continue;
        if ([it[@"forNx"] boolValue]) continue;
        [out addObject:it];
    }
    return out;
}

NSString *RLPFilterForToneStyle(RLPToneStyle style, NSArray<NSDictionary *> *filterItems) {
    NSArray<NSDictionary *> *usable = Usable(filterItems);
    if (!usable.count) return nil;
    NSMutableArray<NSDictionary *> *gauss = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *sharp = [NSMutableArray array];
    for (NSDictionary *it in usable) {
        if (IsGauss(it)) [gauss addObject:it]; else [sharp addObject:it];
    }
    // 温和：gauss 族里抽头最多的（越长越柔顺）；没有 gauss 就退而取普通族里抽头最多的。
    // 锐利：非 gauss 族里名字含 tight 的优先（项目预设升频档就用它），否则取第一个。
    // 均衡：非 gauss 族里抽头居中的那个。
    NSArray<NSDictionary *> *pool = nil;
    if (style == RLPToneStyleWarm) pool = gauss.count ? gauss : usable;
    else pool = sharp.count ? sharp : usable;

    if (style == RLPToneStyleSharp) {
        for (NSDictionary *it in pool) {
            NSString *n = ItemName(it).lowercaseString;
            if ([n rangeOfString:@"tight"].location != NSNotFound) return ItemName(it);
        }
        return ItemName(pool.firstObject);
    }
    // 按 taps 排序后取端点/中点（taps 缺失当 0，稳定排序）
    NSArray<NSDictionary *> *sorted = [pool sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double ta = [a[@"taps"] isKindOfClass:[NSNumber class]] ? [a[@"taps"] doubleValue] : 0;
        double tb = [b[@"taps"] isKindOfClass:[NSNumber class]] ? [b[@"taps"] doubleValue] : 0;
        if (ta < tb) return NSOrderedAscending;
        if (ta > tb) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    if (style == RLPToneStyleWarm) return ItemName(sorted.lastObject);
    return ItemName(sorted[sorted.count / 2]);
}

NSInteger RLPToneStyleForFilter(NSString *filterName, NSArray<NSDictionary *> *filterItems) {
    if (!filterName.length) return -1;
    for (NSInteger s = RLPToneStyleSharp; s <= RLPToneStyleWarm; ++s) {
        NSString *pick = RLPFilterForToneStyle((RLPToneStyle)s, filterItems);
        if ([pick isEqualToString:filterName]) return s;
    }
    return -1;   // 自定义（用户在专业模式里手挑了别的滤波）
}

BOOL RLPFilterUsesNxKey(NSString *filterName, NSArray<NSDictionary *> *filterItems) {
    if (!filterName.length) return NO;
    for (id it in filterItems) {
        if (![it isKindOfClass:[NSDictionary class]]) continue;
        if ([ItemName(it) isEqualToString:filterName]) return [it[@"forNx"] boolValue];
    }
    return NO;
}
