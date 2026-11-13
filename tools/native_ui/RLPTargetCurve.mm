// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPTargetCurve.mm — web TARGET_CURVES / curveKindOfDetails / getTargetCurveDescInfo 的全量移植。
//
// 数据与判定顺序**逐字对照** src/net/ui_script.h（10797-10960 附近）。
// 为什么逐字：这些文案与分支顺序本身就是产品行为（用户看到的"目标曲线说明"就是它们），
// 自行改写会被判据发现（tests/test_native_target_curve.mm 直接与 web 源文件比对）。
#import "RLPTargetCurve.h"

/// web TARGET_CURVES 的一条：kind / label / pts。
@implementation RLPTargetCurve
@end

/// 内部构造用（readonly 属性的 writable 后备）。
@interface RLPMutableTargetCurve : RLPTargetCurve
@property (nonatomic, copy, readwrite) NSString *kind;
@property (nonatomic, copy, readwrite) NSString *label;
@property (nonatomic, copy, readwrite) NSArray<NSArray<NSNumber *> *> *points;
@end
@implementation RLPMutableTargetCurve
// 显式合成：父类 RLPTargetCurve 的同名属性已声明 readonly，子类这里只是"重新声明 readwrite"，
// clang 不会为它自动合成 setter ⟹ 运行时 unrecognized selector（本判据第一轮就是这样崩的）。
@synthesize kind = _mutableKind;
@synthesize label = _mutableLabel;
@synthesize points = _mutablePoints;
@end

/// web `TARGET_CURVES`：11 条。**顺序与内容都必须与 web 一致**。
static NSArray<RLPTargetCurve *> *BuildCurves(void) {
    // [kind, label, pts(x,db), ...]
    NSArray *table = @[
        @[ @"harman_oe", @"Harman 头戴目标：低频温和提升、中高频平顺",
           @[@[@0,@6],@[@0.08,@6],@[@0.15,@5],@[@0.22,@2.6],@[@0.30,@0.8],@[@0.38,@0],
             @[@0.47,@0.5],@[@0.54,@2.0],@[@0.60,@2.6],@[@0.66,@1.5],@[@0.72,@0.3],
             @[@0.80,@-0.4],@[@0.90,@-0.2],@[@1.0,@0.9]] ],
        @[ @"harman_iem", @"Harman 入耳目标：低频更厚、3kHz 耳道增益",
           @[@[@0,@9],@[@0.07,@9],@[@0.13,@7.2],@[@0.20,@3.4],@[@0.27,@0.8],@[@0.34,@0],
             @[@0.44,@0.4],@[@0.50,@1.8],@[@0.55,@6.0],@[@0.59,@7.2],@[@0.64,@2.6],
             @[@0.70,@0.4],@[@0.80,@-1.0],@[@0.90,@-0.6],@[@1.0,@1.2]] ],
        @[ @"autoeq", @"AutoEQ 校准：按实测目标平直化，小幅低频架",
           @[@[@0,@3.8],@[@0.10,@3.8],@[@0.18,@2.8],@[@0.26,@1.0],@[@0.34,@0],@[@0.46,@0.5],
             @[@0.53,@1.8],@[@0.60,@0.6],@[@0.70,@-0.3],@[@0.82,@0],@[@1.0,@0.6]] ],
        @[ @"studio", @"录音室中性：全频段尽量平直",
           @[@[@0,@0],@[@0.12,@-0.3],@[@0.24,@-0.6],@[@0.36,@-0.2],@[@0.50,@0.2],
             @[@0.62,@0.5],@[@0.74,@0],@[@0.86,@-0.3],@[@1.0,@0]] ],
        @[ @"consumer", @"消费级曲线：低频与极高频微抬",
           @[@[@0,@4.5],@[@0.12,@4.5],@[@0.20,@3.0],@[@0.30,@0.8],@[@0.40,@0],@[@0.52,@0.8],
             @[@0.58,@2.2],@[@0.65,@0.8],@[@0.75,@0.2],@[@0.85,@0.8],@[@1.0,@2.6]] ],
        @[ @"diffuse", @"扩散场目标：声场开阔、高频细节多",
           @[@[@0,@0],@[@0.10,@-0.3],@[@0.20,@-0.6],@[@0.30,@-0.6],@[@0.40,@-0.3],
             @[@0.50,@0.2],@[@0.60,@1.0],@[@0.70,@2.0],@[@0.80,@2.8],@[@0.90,@3.3],@[@1.0,@3.6]] ],
        @[ @"freefield", @"自由场目标：接近消音室直达声",
           @[@[@0,@0],@[@0.15,@-0.2],@[@0.30,@-0.5],@[@0.45,@-0.4],@[@0.55,@-0.1],
             @[@0.65,@0.3],@[@0.75,@0.9],@[@0.85,@1.6],@[@1.0,@2.4]] ],
        @[ @"senselab", @"SenseLab 目标：高频峰谷精细补偿",
           @[@[@0,@0.5],@[@0.15,@0.2],@[@0.28,@-0.2],@[@0.40,@-0.3],@[@0.52,@0.2],
             @[@0.60,@1.2],@[@0.68,@0.4],@[@0.80,@-0.2],@[@1.0,@0.4]] ],
        @[ @"rtings", @"Rtings 参考目标：平直均衡",
           @[@[@0,@2.5],@[@0.12,@2.5],@[@0.22,@1.4],@[@0.32,@0.2],@[@0.45,@0],@[@0.55,@0.6],
             @[@0.62,@1.2],@[@0.72,@0],@[@0.85,@-0.4],@[@1.0,@0.3]] ],
        @[ @"optimum", @"Optimum HiFi：低频克制、中频通透",
           @[@[@0,@2.0],@[@0.14,@2.0],@[@0.24,@1.0],@[@0.34,@0],@[@0.48,@0.3],@[@0.56,@1.0],
             @[@0.66,@0.2],@[@0.80,@-0.4],@[@1.0,@0]] ],
        @[ @"neutral", @"IEF 中性：平直无染",
           @[@[@0,@0],@[@0.12,@0],@[@0.24,@-0.2],@[@0.36,@-0.2],@[@0.50,@0],@[@0.58,@0.8],
             @[@0.66,@0.2],@[@0.80,@-0.4],@[@1.0,@0]] ],
    ];
    NSMutableArray<RLPTargetCurve *> *out = [NSMutableArray array];
    for (NSArray *row in table) {
        RLPMutableTargetCurve *c = [[RLPMutableTargetCurve alloc] init];
        c.kind = row[0];
        c.label = row[1];
        c.points = row[2];
        [out addObject:c];
    }
    return out;
}

@implementation RLPTargetCurveLibrary

+ (NSArray<RLPTargetCurve *> *)allCurves {
    static NSArray<RLPTargetCurve *> *all;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ all = BuildCurves(); });
    return all;
}

+ (nullable RLPTargetCurve *)curveForKind:(NSString *)kind {
    // web：`TARGET_CURVES[kind] || TARGET_CURVES.autoeq` —— 未知 kind 回落 autoeq。
    for (RLPTargetCurve *c in [self allCurves]) if ([c.kind isEqualToString:kind ?: @""]) return c;
    for (RLPTargetCurve *c in [self allCurves]) if ([c.kind isEqualToString:@"autoeq"]) return c;
    return nil;
}

+ (NSString *)kindForDetails:(NSString *)details {
    // web curveKindOfDetails：**分支顺序**必须一致，否则 'harman' 会先被 iem 分支以外的吃掉。
    NSString *d = [(details ?: @"") lowercaseString];
    if ([d containsString:@"harman"])
        return ([d containsString:@"in-ear"] || [d containsString:@"iem"]) ? @"harman_iem" : @"harman_oe";
    if ([d containsString:@"soundguys_studio"]) return @"studio";
    if ([d containsString:@"soundguys_consumer"]) return @"consumer";
    if ([d containsString:@"diffuse"] || [d containsString:@"hrtf"]) return @"diffuse";
    if ([d containsString:@"free_field"]) return @"freefield";
    if ([d containsString:@"senselab"]) return @"senselab";
    if ([d containsString:@"rtings"]) return @"rtings";
    if ([d containsString:@"optimum"] || [d containsString:@"hifi"]) return @"optimum";
    if ([d containsString:@"neutral"] || [d containsString:@"ief"]) return @"neutral";
    return @"autoeq";
}

/// web getTargetCurveDescInfo 的分支（name/scene/tech 三元组）。
/// 返回 @[name, scene, tech]；用同一份分支保证三者永不串口径。
+ (NSArray<NSString *> *)descForDetails:(NSString *)details author:(NSString *)author {
    NSString *d = [(details ?: @"") lowercaseString];
    if ([d containsString:@"harman"] && ([d containsString:@"in-ear"] || [d containsString:@"iem"])) {
        return @[ @"哈曼入耳目标曲线 (Harman In-Ear)",
                  @"针对入耳式耳道封闭增强低频动态与人声清晰度，适合现代流行、人声与节奏感强的音乐。",
                  @"Harman In-Ear Target 补偿了耳道封闭效应，适度提升 100Hz 以下低频与 3kHz 附近耳甲腔增益，提供接近高品质音箱的听感。" ];
    }
    if ([d containsString:@"harman"]) {
        return @[ @"哈曼头戴目标曲线 (Harman Over-Ear)",
                  @"符合大众听音盲测偏好，低频温暖厚实、中高频平衡耐听，杂食百搭，适合绝大多数现代流行乐与影视原声。",
                  @"Harman Target 基于 Harman 实验室长期双盲听音实验，低频有约 4~6dB 适度平滑提升，高频平顺无刺激刺耳感。" ];
    }
    if ([d containsString:@"soundguys_studio"]) {
        return @[ @"SoundGuys 录音室中性曲线",
                  @"严格平直的工作室参考曲线，适合录音棚监听、音频剪辑与追求原汁原味还原的听众。",
                  @"SoundGuys Studio 目标注重全频段线性度，消除耳机本身声学谐振，为混音制作提供真实基准。" ];
    }
    if ([d containsString:@"soundguys_consumer"]) {
        return @[ @"SoundGuys 大众消费曲线",
                  @"兼顾清晰度与氛围感，微调低频弹性与高频空气感，适合日常通勤随身聆听与流媒体影视。",
                  @"面向普通消费者的均衡曲线，在平直基础上微抬极低频与极高频，听感更具感染力。" ];
    }
    if ([d containsString:@"diffuse"] || [d containsString:@"hrtf_5128"]) {
        return @[ @"扩散场目标曲线 (Diffuse Field / HRTF)",
                  @"模拟无指向多反射声学空间，空间定位感与高频解析力极强，特别适合大编制古典交响乐与现场录音。",
                  @"Diffuse Field 曲线基于人工头在混响室中测量的自由声场平均响应，声场开阔通透，高频细节丰富。" ];
    }
    if ([d containsString:@"free_field"]) {
        return @[ @"自由场目标曲线 (Free Field)",
                  @"模拟消音室正前方向直达声，干脆纯净，适合需要清晰方向判断的专业监听。",
                  @"Free Field 曲线反映消音室内扬声器正前方的直达声听觉响应。" ];
    }
    if ([d containsString:@"senselab"]) {
        return @[ @"SenseLab 声学实验室目标",
                  @"注重高保真声学平直度与相位一致性，适合乐器真实音色鉴赏与原声发烧录音。",
                  @"SenseLab 方案基于精细声学补偿，重点修正耳机单元在高频段的群延迟与频响峰谷。" ];
    }
    if ([d containsString:@"rtings"]) {
        return @[ @"Rtings 参考目标曲线",
                  @"Rtings 实验室测量的平直均衡曲线，适合影视与游戏声效还原。",
                  @"Rtings 综合目标结合声学生理模型，旨在使耳机频响趋近于平直扬声器室内频响。" ];
    }
    if ([d containsString:@"optimum"] || [d containsString:@"hifi"]) {
        return @[ @"最佳高保真目标曲线 (Optimum HiFi)",
                  @"低频平顺不轰鸣、中频通透无染色，适合古典乐、爵士乐与纯乐器发烧录音。",
                  @"Optimum HiFi 强调极低失真与线性动态，不对低频做过多主观提升，保持纯正声底。" ];
    }
    (void)author;
    return @[ @"AutoEQ 校准目标",
              @"按实测目标把频响平直化，适合希望尽量还原录音、不加个人偏好的听众。",
              @"AutoEQ 基于公开测量数据拟合到选定目标，得到一组最小相位 PEQ 参数。" ];
}

+ (NSString *)targetCurveNameForDetails:(NSString *)details author:(NSString *)author {
    return [self descForDetails:details author:author][0];
}
+ (NSString *)targetCurveSceneForDetails:(NSString *)details author:(NSString *)author {
    return [self descForDetails:details author:author][1];
}
+ (NSString *)targetCurveTechForDetails:(NSString *)details author:(NSString *)author {
    return [self descForDetails:details author:author][2];
}

+ (NSArray<NSValue *> *)plotPoints:(RLPTargetCurve *)curve inRect:(NSRect)plot {
    // web targetCurveSvg：x 归一化 0..1 线性铺满（PAD 由调用方的 plot 承担），
    // y 用 MAXDB=9 / MINDB=-2（**不是** EQ 图的 ±18）。照抄这两个常数，否则形状会变形。
    NSMutableArray<NSValue *> *out = [NSMutableArray array];
    if (!curve || plot.size.width < 2 || plot.size.height < 2) return out;
    const double kMaxDb = 9.0, kMinDb = -2.0;
    for (NSArray<NSNumber *> *p in curve.points) {
        if (p.count < 2) continue;
        const double x = MAX(0.0, MIN(1.0, p[0].doubleValue));
        const double db = MAX(kMinDb, MIN(kMaxDb, p[1].doubleValue));
        const double px = plot.origin.x + x * plot.size.width;
        const double py = plot.origin.y + (kMaxDb - db) / (kMaxDb - kMinDb) * plot.size.height;
        [out addObject:[NSValue valueWithPoint:NSMakePoint(px, py)]];
    }
    return out;
}

@end
