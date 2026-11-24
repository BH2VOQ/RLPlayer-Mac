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

static NSDictionary *FindItemByName(NSString *name, NSArray<NSDictionary *> *items) {
    for (NSDictionary *it in items) {
        if ([ItemName(it) isEqualToString:name]) return it;
    }
    return nil;
}

NSString *RLPFilterForToneStyle(RLPToneStyle style, NSArray<NSDictionary *> *filterItems) {
    NSArray<NSDictionary *> *usable = Usable(filterItems);
    if (!usable.count) return nil;
    NSMutableArray<NSDictionary *> *gauss = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *sharp = [NSMutableArray array];
    for (NSDictionary *it in usable) {
        if (IsGauss(it)) [gauss addObject:it]; else [sharp addObject:it];
    }

    // Windows ui_listening_home.h 语义 + 注册表真实条目：
    //   warm（温和）：gauss 族（优先 poly-sinc-gauss-long / medium / short，不再按表中最大 taps 碰运气）
    //   balanced（均衡）：auto / short / medium（优先 poly-sinc-short-lp / poly-sinc-short / poly-sinc-lp）
    //   sharp（锐利）：long / ext 族（优先 poly-sinc-long-lp / poly-sinc-ext2-medium / poly-sinc-ext2-long / poly-sinc-long / poly-sinc-tight-lp）
    NSArray<NSString *> *prefs = nil;
    if (style == RLPToneStyleWarm) {
        prefs = @[@"poly-sinc-gauss-long", @"poly-sinc-gauss-medium", @"poly-sinc-gauss-short",
                  @"poly-sinc-gauss-2s", @"poly-sinc-gauss-mp"];
    } else if (style == RLPToneStyleBalanced) {
        prefs = @[@"poly-sinc-short-lp", @"poly-sinc-short", @"poly-sinc-lp",
                  @"poly-sinc-short-mp", @"poly-sinc-ext2-short"];
    } else {
        prefs = @[@"poly-sinc-long-lp", @"poly-sinc-ext2-medium", @"poly-sinc-ext2-long",
                  @"poly-sinc-long", @"poly-sinc-ext", @"poly-sinc-tight-lp"];
    }
    for (NSString *cand in prefs) {
        if (FindItemByName(cand, usable)) return cand;
    }

    // 回退：只在候选池找不到首选名时按家族/关键词回退（仍保证返回 usable 里的真实条目）
    if (style == RLPToneStyleWarm) {
        return ItemName(gauss.count ? gauss.firstObject : usable.firstObject);
    }
    NSArray<NSDictionary *> *pool = sharp.count ? sharp : usable;
    if (style == RLPToneStyleBalanced) {
        for (NSDictionary *it in pool) {
            NSString *n = ItemName(it).lowercaseString;
            if ([n rangeOfString:@"short"].location != NSNotFound ||
                [n rangeOfString:@"medium"].location != NSNotFound) {
                return ItemName(it);
            }
        }
        return ItemName(pool[pool.count / 2]);
    }
    // RLPToneStyleSharp
    for (NSDictionary *it in pool) {
        NSString *n = ItemName(it).lowercaseString;
        if ([n rangeOfString:@"long"].location != NSNotFound ||
            [n rangeOfString:@"ext"].location != NSNotFound ||
            [n rangeOfString:@"tight"].location != NSNotFound) {
            return ItemName(it);
        }
    }
    return ItemName(pool.firstObject);
}

NSInteger RLPToneStyleForFilter(NSString *filterName, NSArray<NSDictionary *> *filterItems) {
    if (!filterName.length) return -1;
    for (NSInteger s = RLPToneStyleSharp; s <= RLPToneStyleWarm; ++s) {
        NSString *pick = RLPFilterForToneStyle((RLPToneStyle)s, filterItems);
        if ([pick isEqualToString:filterName]) return s;
    }
    return -1;   // 自定义（用户手动挑了别的滤波）
}

BOOL RLPFilterUsesNxKey(NSString *filterName, NSArray<NSDictionary *> *filterItems) {
    if (!filterName.length) return NO;
    for (id it in filterItems) {
        if (![it isKindOfClass:[NSDictionary class]]) continue;
        if ([ItemName(it) isEqualToString:filterName]) return [it[@"forNx"] boolValue];
    }
    return NO;
}

NSDictionary<NSString *, NSString *> *RLPSettingsPatchForToneStyle(
    RLPToneStyle style, NSArray<NSDictionary *> *filterItems) {
    NSString *name = RLPFilterForToneStyle(style, filterItems);
    if (!name.length) return nil;
    const BOOL isNx = RLPFilterUsesNxKey(name, filterItems);
    NSMutableDictionary<NSString *, NSString *> *patch = [NSMutableDictionary dictionaryWithDictionary:@{
        (isNx ? @"filterNx" : @"filter"): name,
        @"taps": @"0",
        @"mintapsperinput": @"0",
        @"atten": @"0",
        @"transition": @"0",
        @"phase": @"",
    }];
    if (!isNx) patch[@"filterNx"] = @"";
    return patch;
}

NSString *RLPPlayModeFromSettings(NSDictionary *kv) {
    if (![kv isKindOfClass:[NSDictionary class]]) return @"bitperfect";
    const NSInteger dsdVal = RLPParseDsdRate(kv[@"dsd"]);

    id dirObj = kv[@"directsdm"];
    NSString *dirStr = [dirObj isKindOfClass:[NSString class]] ? dirObj
                     : ([dirObj isKindOfClass:[NSNumber class]] ? [(NSNumber *)dirObj stringValue] : @"0");
    const BOOL direct = [dirStr isEqualToString:@"1"] || [dirStr isEqualToString:@"true"];

    id rateObj = kv[@"rate"];
    NSString *rate = [rateObj isKindOfClass:[NSString class]] ? rateObj
                   : ([rateObj isKindOfClass:[NSNumber class]] ? [(NSNumber *)rateObj stringValue] : @"src");
    if (!rate.length) rate = @"src";
    const BOOL rateIsSrc = [rate isEqualToString:@"src"] || [rate isEqualToString:@"follow"];

    id filtObj = kv[@"filter"];
    NSString *filter = [filtObj isKindOfClass:[NSString class]] ? filtObj : @"";

    // 若 conf 存有 ui_profile 意图，先核对当前实际参数是否已按设备降级/被手工改动；
    // 未冲突时按声明返回（如区分 dsd vs pcm2dsd），已降级时返回真实生效的模式（如 dsd->pcm / custom）。
    id declObj = kv[@"ui_profile"];
    NSString *declared = [declObj isKindOfClass:[NSString class]] ? declObj : @"";
    if ([declared isEqualToString:@"bitperfect"]) {
        if (dsdVal <= 0 && (direct || (rateIsSrc && !filter.length))) return @"bitperfect";
    } else if ([declared isEqualToString:@"pcm"]) {
        if (rateObj == nil || (dsdVal <= 0 && !rateIsSrc)) return @"pcm";
    } else if ([declared isEqualToString:@"dsd"] || [declared isEqualToString:@"pcm2dsd"]) {
        if (kv[@"dsd"] == nil || dsdVal > 0) return declared;
    } else if ([declared isEqualToString:@"custom"]) {
        return @"custom";
    }

    if (direct || (dsdVal <= 0 && rateIsSrc && !filter.length)) return @"bitperfect";
    if (dsdVal > 0) return @"dsd";
    if (!rateIsSrc) return @"pcm";
    return @"custom";
}

NSInteger RLPQuickStartColumnsForWidth(double width) {
    if (width <= 350.0) return 1;
    if (width <= 750.0) return 2;
    return 4;
}

static NSString *RLPTrimStr(id v) {
    if (![v isKindOfClass:[NSString class]]) return @"";
    return [(NSString *)v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

NSArray<NSDictionary<NSString *, NSString *> *> *RLPNormalizeCastDevices(NSArray * _Nullable rawDevices) {
    if (![rawDevices isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *out = [NSMutableArray array];
    for (id item in rawDevices) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *d = (NSDictionary *)item;
        NSString *location = RLPTrimStr(d[@"location"]);
        NSString *friendly = RLPTrimStr(d[@"friendlyName"]);
        NSString *name = RLPTrimStr(d[@"name"]);
        NSString *host = RLPTrimStr(d[@"host"]);
        NSString *model = RLPTrimStr(d[@"model"]);
        NSString *kind = RLPTrimStr(d[@"kind"]);
        NSString *devId = location.length ? location
                        : (friendly.length ? friendly
                        : (name.length ? name : host));
        if (!devId.length) continue;
        NSString *baseName = friendly.length ? friendly
                           : (name.length ? name
                           : (host.length ? host : RLPTr(@"网络播放器")));
        NSString *displayName = (model.length && ![baseName isEqualToString:model])
            ? [NSString stringWithFormat:@"%@ · %@", baseName, model]
            : baseName;
        [out addObject:@{
            @"id": devId,
            @"name": displayName,
            @"kind": kind.length ? kind : @"upnp",
            @"host": host,
        }];
    }
    return out;
}

NSString *RLPRememberedLocalDevice(NSDictionary * _Nullable kv, NSString * _Nullable previousLocalDevice) {
    if (![kv isKindOfClass:[NSDictionary class]]) return previousLocalDevice ?: @"";
    NSString *bk = RLPTrimStr(kv[@"backend"]);
    NSString *dev = RLPTrimStr(kv[@"device"]);
    if (![bk isEqualToString:@"upnp"] && ![bk isEqualToString:@"null"]) {
        return [dev isEqualToString:@"null"] ? @"" : dev;
    }
    if (previousLocalDevice != nil) return previousLocalDevice;
    if (dev.length && ![dev isEqualToString:@"null"]) return dev;
    return @"";
}

NSDictionary<NSString *, NSString *> *RLPOutputSettingsPatchForBackend(
    NSString *targetBackend, NSString * _Nullable upnpDev, NSString * _Nullable localDevice) {
    NSString *bk = targetBackend.length ? targetBackend : @"coreaudio";
    if ([bk isEqualToString:@"upnp"]) {
        return @{
            @"backend": @"upnp",
            @"upnpdev": upnpDev ?: @"",
        };
    }
    if ([bk isEqualToString:@"coreaudio"] || [bk isEqualToString:@"coreaudio-shared"]) {
        NSString *dev = (localDevice.length && ![localDevice isEqualToString:@"null"]) ? localDevice : @"";
        return @{
            @"backend": bk,
            @"device": dev,
        };
    }
    if ([bk isEqualToString:@"null"]) {
        return @{
            @"backend": @"null",
            @"device": @"null",
        };
    }
    return @{ @"backend": bk };
}
