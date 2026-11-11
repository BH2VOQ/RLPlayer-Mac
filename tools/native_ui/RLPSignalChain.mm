// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPSignalChain.mm — JSON → 信号链节点（纯函数，契约见 .h）
//
// 所有数字与布尔都来自后端 /api/signal.path（实测值，不是设置项）。
// 分支顺序、徽标用词、bit-perfect 结论都按 web showChain 逐条对齐；
// 拿不到的字段一律不编造（"–" / 省略），绝不显示 undefined。
#import "RLPSignalChain.h"

@implementation RLPSignalNode
@end

static double Num(NSDictionary *d, NSString *k) {
    id v = d[k];
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0.0;
}
static BOOL Bool(NSDictionary *d, NSString *k) {
    id v = d[k];
    return [v respondsToSelector:@selector(boolValue)] && [v boolValue];
}
static NSString *Str(NSDictionary *d, NSString *k) {
    id v = d[k];
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : @"";
}
static NSString *BaseName(NSString *p) {
    NSString *n = p.lastPathComponent ?: p;
    return n.length ? n : @"?";
}
static NSString *Hz(double r) {
    return r > 0 ? [NSString stringWithFormat:@"%.0f Hz", r] : @"—";
}

static RLPSignalNode *Node(NSString *key, NSString *value, NSString *badge, RLPSignalNodeKind kind) {
    RLPSignalNode *n = [[RLPSignalNode alloc] init];
    n.key = key; n.value = value; n.badge = badge; n.kind = kind;
    return n;
}

@implementation RLPSignalChain

+ (NSString *)kindName:(RLPSignalNodeKind)kind {
    switch (kind) {
        case RLPSignalNodeLossless: return @"lossless";
        case RLPSignalNodeDsp:      return @"dsp";
        case RLPSignalNodeGpu:      return @"gpu";
        case RLPSignalNodeTel:      return @"tel";
    }
    return @"dsp";
}

+ (NSString *)heroTitleForResponse:(NSDictionary *)response why:(NSString * _Nullable * _Nullable)why {
    NSDictionary *p = [response[@"path"] isKindOfClass:[NSDictionary class]] ? response[@"path"] : nil;
    NSString *w = p ? Str(p, @"bitPerfectWhy") : @"";
    if (why) *why = w.length ? w : @"（本次未记录）";
    if (!response || ![response[@"ok"] boolValue] || !p) return @"还没有开始播放";
    NSString *bp = Str(p, @"bitPerfect");
    NSString *transport = Str(p, @"transport");
    if ([bp isEqualToString:@"direct"]) return @"BIT-PERFECT · 1-bit DSD 直通";
    if ([bp isEqualToString:@"yes"]) return @"BIT-PERFECT · 全链路逐位无损";
    if ([bp isEqualToString:@"no"]) {
        // AirPlay 的"非 bit-perfect"是传输本身逐位未验证，不是 DSP 造成的（web AP-1.2 同口径）。
        if ([transport isEqualToString:@"airplay"]) return @"非 Bit-Perfect · AirPlay 传输（端到端逐位未获验证）";
        return @"非 Bit-Perfect · 信号经过 DSP 处理";
    }
    return @"Bit-Perfect 状态未知";
}

+ (NSArray<RLPSignalNode *> *)nodesForResponse:(NSDictionary *)response {
    NSDictionary *p = [response[@"path"] isKindOfClass:[NSDictionary class]] ? response[@"path"] : nil;
    if (!response || ![response[@"ok"] boolValue] || !p) return @[];   // 没播放 ⟹ 空，不填假节点

    NSMutableArray<RLPSignalNode *> *out = [NSMutableArray array];
    const double inRate = Num(p, @"inRate"), outRate = Num(p, @"outRate");
    const double inBits = Num(p, @"inBits"), outBits = Num(p, @"outBits");
    const double inCh = Num(p, @"inCh"), outCh = Num(p, @"outCh");
    const double volume = Num(p, @"volume");
    NSString *codec = Str(p, @"codec");
    NSString *dev = Str(p, @"device");
    NSString *transport = Str(p, @"transport");

    // ① 源文件
    NSString *srcV = BaseName(Str(p, @"src"));
    if (codec.length) srcV = [srcV stringByAppendingFormat:@"  ·  %@", codec.uppercaseString];
    [out addObject:Node(@"源文件", srcV, @"无损源", RLPSignalNodeLossless)];

    // ② 解码
    NSString *note = Str(p, @"note");
    NSString *decV = [NSString stringWithFormat:@"%@  ·  %@ / %.0f bit / %.0f ch",
                      note.length ? note : @"原生无损解码", Hz(inRate), inBits, inCh];
    [out addObject:Node(@"解码", decV, @"无损解码", RLPSignalNodeLossless)];

    const BOOL gpuUsed = Bool(p, @"gpuUsed");
    const BOOL convGpu = Bool(p, @"convGpu");
    const BOOL castBypass = Bool(p, @"castDspBypass");

    // ③ 采样率转换（方向必须按 inRate/outRate 说话，降采样绝不给"升频"章 —— web 2026-11-09）
    if (castBypass) {
        NSString *v;
        if (Bool(p, @"upsampleApplied")) {
            NSString *f = Str(p, @"servedFilter");
            if (!f.length) f = Str(p, @"filter");
            v = [NSString stringWithFormat:@"本机升频 %.0f → %@ Hz · %@（投放供源）%@",
                 inRate, Hz(Num(p, @"servedRate") ?: outRate), f.length ? f : @"poly-sinc-lp",
                 Bool(p, @"upsampleForced") ? @" · 强制（渲染器未声明该速率）" : @""];
        } else if (Str(p, @"upsampleNote").length) {
            v = Str(p, @"upsampleNote");
        } else {
            v = @"旁路（投放不经过本机 DSP：升频/EQ/IR/音量都不参与）";
        }
        [out addObject:Node(@"采样率转换", v, @"投放旁路", RLPSignalNodeDsp)];
    } else if (Bool(p, @"resample")) {
        NSString *rd = Str(p, @"rateDir");
        if (!rd.length) rd = (inRate > 0 && outRate > 0)
            ? (outRate < inRate ? @"down" : (outRate > inRate ? @"up" : @"same")) : @"unknown";
        NSString *rdText = [rd isEqualToString:@"down"] ? @"降采样"
                          : ([rd isEqualToString:@"up"] ? @"升频" : @"重采样");
        NSString *rdBadge = [rd isEqualToString:@"down"]
            ? (gpuUsed ? @"GPU 降采样" : @"64-Bit 降采样")
            : (gpuUsed ? @"GPU 升频" : @"64-Bit 升频");
        NSString *f = Str(p, @"filter");
        NSString *phase = Str(p, @"phase");
        NSString *v = [NSString stringWithFormat:@"%@：%@  ·  %@  ·  %.0f 抽头%@  %.0f → %.0f Hz%@",
                       rdText, f.length ? f : @"Kaiser sinc", phase.length ? phase : @"线性",
                       Num(p, @"taps"), Bool(p, @"twoStage") ? @"  ·  两段式" : @"",
                       inRate, outRate, gpuUsed ? @"  ·  GPU" : @""];
        [out addObject:Node(@"采样率转换", v, rdBadge, gpuUsed ? RLPSignalNodeGpu : RLPSignalNodeDsp)];
    } else {
        [out addObject:Node(@"采样率转换", @"旁路（源采样率与输出一致，逐位直通）",
                            @"逐位旁路", RLPSignalNodeLossless)];
    }

    // ④ EQ / 卷积
    if (Bool(p, @"eq") || Bool(p, @"conv")) {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        if (Bool(p, @"eq")) [parts addObject:@"参数 EQ"];
        if (Bool(p, @"conv")) [parts addObject:@"FIR 卷积"];
        NSString *v = [[parts componentsJoinedByString:@"  ·  "] stringByAppendingFormat:
                       @"  ·  %@", convGpu ? @"GPU 计算" : @"CPU 计算"];
        [out addObject:Node(@"EQ / 卷积", v, convGpu ? @"GPU 卷积" : @"DSP 均衡",
                            convGpu ? RLPSignalNodeGpu : RLPSignalNodeDsp)];
    }

    // ⑤ DSD 调制 + DoP / 抖动
    if (Bool(p, @"dsd")) {
        const double mhz = Num(p, @"dsdRate") / 1000000.0;
        NSString *v = [NSString stringWithFormat:@"DSD%.0f（%.4f MHz）· 1-bit · %.0f 阶 SDM",
                       Num(p, @"dsd"), mhz, Num(p, @"modOrder") ?: 5];
        [out addObject:Node(@"DSD 调制", v, @"SDM 调制", RLPSignalNodeDsp)];
        NSString *dop = [NSString stringWithFormat:@"24-bit 载波 %@ Hz · 标记 0x05/0xFA 交替", Hz(outRate)];
        [out addObject:Node(@"DoP 封装", dop, @"DoP 1.1", RLPSignalNodeLossless)];
    } else {
        NSString *shaper = Str(p, @"shaper");
        const BOOL noShaper = (!shaper.length || [shaper isEqualToString:@"none"]);
        [out addObject:Node(@"抖动 / 噪声整形", noShaper ? @"无（逐位）" : shaper,
                            noShaper ? @"逐位直通" : @"噪声整形",
                            noShaper ? RLPSignalNodeLossless : RLPSignalNodeDsp)];
    }

    // ⑥ ISP 峰值保护
    const double preAtten = Num(p, @"preAtten");
    if (preAtten < 0) {
        NSString *v = [NSString stringWithFormat:@"检测到过采样峰值 %.1f%%（%.0f 个点超出满幅）→ 预衰减 %.1f dB",
                       Num(p, @"ispPeak") * 100.0, Num(p, @"ispOver"), preAtten];
        [out addObject:Node(@"峰值保护", v, @"ISP 保护", RLPSignalNodeDsp)];
    }
    // ⑦ 等响度
    if (Bool(p, @"loudness")) [out addObject:Node(@"等响度补偿", @"开启", @"DSP 响度", RLPSignalNodeDsp)];

    // ⑧ 音量（|volume| < 0.05 = 逐位无损）
    const BOOL unitVol = fabs(volume) < 0.05;
    NSString *volV = unitVol ? @"0 dB（逐位）" : [NSString stringWithFormat:@"%.1f dB", volume];
    [out addObject:Node(@"音量", volV, unitVol ? @"逐位无损" : @"数字衰减",
                        unitVol ? RLPSignalNodeLossless : RLPSignalNodeDsp)];

    // ⑨ 输出（如实说明送到哪里、走什么传输、延迟来源）
    const BOOL isAirPlay = [transport isEqualToString:@"airplay"];
    const BOOL isShared = Bool(p, @"sharedOnly") || isAirPlay;
    NSString *outMode = isAirPlay ? @"AirPlay 网络输出（非 bit-perfect，端到端逐位未获验证）"
                       : (isShared ? @"共享模式（非 bit-perfect）" : @"独占模式");
    NSMutableString *ov = [NSMutableString stringWithFormat:@"%@  ·  %@ / %.0f bit / %.0f ch  ·  %@",
                           dev.length ? dev : @"默认设备", Hz(outRate), outBits, outCh, outMode];
    const double lat = Num(p, @"latencyMs");
    if (Bool(p, @"latencyKnown") && lat > 0) {
        NSString *ls = Str(p, @"latencySource");
        [ov appendFormat:@"  ·  %@ %.0f ms%@", isAirPlay ? @"网络缓冲" : @"系统属性延迟", lat,
                         ls.length ? [NSString stringWithFormat:@" (%@)", ls] : @""];
    } else if (isAirPlay) {
        [ov appendString:@"  ·  延迟未知（发送端未上报缓冲长度）"];
    }
    const double buf = Num(p, @"buffer");
    if (buf > 0) [ov appendFormat:@"  ·  缓冲 %.0f ms", buf];
    [out addObject:Node(@"输出", ov, isAirPlay ? @"AirPlay" : (isShared ? @"系统混音" : @"硬件独占"),
                        (isAirPlay || isShared) ? RLPSignalNodeDsp : RLPSignalNodeLossless)];

    // ⑩ 耗时统计（实时遥测，缺字段显 –，绝不 undefined）
    const double decMs = Num(p, @"decodeMs");
    NSString *tDec = decMs > 0
        ? (decMs >= 1000 ? [NSString stringWithFormat:@"%.2f s", decMs / 1000.0]
                         : [NSString stringWithFormat:@"%.1f ms", decMs]) : @"–";
    NSString *tWav = @"–";
    const double ffMs = Num(p, @"ffmpegMs"), wavMs = Num(p, @"wavReadMs");
    if (ffMs > 0) tWav = [NSString stringWithFormat:@"转码写 %.1f ms%@", ffMs,
                          wavMs > 0 ? [NSString stringWithFormat:@" / 读 %.1f ms", wavMs] : @""];
    else if (wavMs > 0) tWav = [NSString stringWithFormat:@"读取 %.1f ms", wavMs];
    NSString *tDsp = @"–";
    const double dspBlock = Num(p, @"dspBlockMs"), dspTotal = Num(p, @"dspTotalMs");
    if (dspBlock > 0) tDsp = [NSString stringWithFormat:@"%.2f ms/块%@", dspBlock,
                              dspTotal > 0 ? [NSString stringWithFormat:@"（累计 %.1f ms）", dspTotal] : @""];
    else if (dspTotal > 0) tDsp = [NSString stringWithFormat:@"累计 %.1f ms", dspTotal];
    const double scanMs = Num(p, @"scanMs");
    NSString *tScan = scanMs > 0
        ? (scanMs >= 1000 ? [NSString stringWithFormat:@"%.2f s", scanMs / 1000.0]
                          : [NSString stringWithFormat:@"%.0f ms", scanMs]) : @"–";
    NSString *timing = [NSString stringWithFormat:@"解码 %@  ·  临时WAV %@  ·  DSP %@  ·  库扫描 %@",
                        tDec, tWav, tDsp, tScan];
    [out addObject:Node(@"耗时统计", timing, @"实时遥测", RLPSignalNodeTel)];

    return out;
}

@end