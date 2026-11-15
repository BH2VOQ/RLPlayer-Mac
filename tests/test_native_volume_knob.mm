// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_volume_knob.mm — v3.3.11 音量旋钮的几何与映射判据
//
// 为什么这些必须是判据而不是审查：
//   ① 大弧标志阈值写错（0.5 而不是 2/3）会让 0 dB 附近的弧绕到圈外 —— 这是 3.3.10 的真事故；
//   ② 角度→dB 映射写错，用户拖到中间就没声音（web 2026-10-25 修过的同名事故）；
//   ③ 两者都看起来像那么回事，只有把具体坐标/数值钉死才测得出来。
#import <AppKit/AppKit.h>
#import "RLPVolumeKnobView.h"

#include <cmath>
#include <cstdio>

static int gPass = 0, gFail = 0;

static void Ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++gPass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++gFail; }
}

static BOOL Near(double a, double b, double eps) { return std::fabs(a - b) <= eps; }

int main() {
    std::printf("== 音量旋钮（v3.3.11 .rlVolKnob）判据 ==\n");

    // ---- K1..K3：三点几何（与 web rlVolPoint 同值）----
    {
        const NSPoint p0 = RLPVolKnobPoint(0.0, 24.0);
        Ck(Near(p0.x, 15.03, 0.02) && Near(p0.y, 48.97, 0.02),
           "K1 norm=0 落在左下 (15.03, 48.97)（与 web 轨道起点同值）",
           [NSString stringWithFormat:@"got (%.2f, %.2f)", p0.x, p0.y]);
        const NSPoint pH = RLPVolKnobPoint(0.5, 24.0);
        Ck(Near(pH.x, 32.0, 0.02) && Near(pH.y, 8.0, 0.02),
           "K2 norm=0.5 落在正上方 (32, 8) ⟹ 0 dB 在正上方",
           [NSString stringWithFormat:@"got (%.2f, %.2f)", pH.x, pH.y]);
        const NSPoint p1 = RLPVolKnobPoint(1.0, 24.0);
        Ck(Near(p1.x, 48.97, 0.02) && Near(p1.y, 48.97, 0.02),
           "K3 norm=1 落在右下 (48.97, 48.97)（与 web 轨道终点同值）",
           [NSString stringWithFormat:@"got (%.2f, %.2f)", p1.x, p1.y]);
    }

    // ---- K4..K5：大弧标志（历史事故点）----
    {
        Ck(!RLPVolKnobArcIsLarge(0.5), "K4a norm=0.5（扫角 135°）不是大弧", @"");
        Ck(!RLPVolKnobArcIsLarge(0.53),
           "K4b norm=0.53（约 0 dB）仍不是大弧 —— 旧码 norm>0.5 会错判成 216° 大弧", @"");
        Ck(!RLPVolKnobArcIsLarge(0.666), "K4c norm=0.666（扫角 179.8°）不是大弧", @"");
        Ck(RLPVolKnobArcIsLarge(0.68), "K5a norm=0.68（扫角 183.6°）是大弧", @"");
        Ck(RLPVolKnobArcIsLarge(1.0), "K5b norm=1（270°）是大弧", @"");
    }

    // ---- K6：起点没有弧 ----
    Ck([RLPVolKnobArcPath(0.0) length] == 0, "K6 norm=0 时弧为空（不画零长度弧）", RLPVolKnobArcPath(0.0));

    // ---- K7：dB 与 norm 互逆（0 dB 居中，两端到极值）----
    {
        Ck(Near(RLPVolDbToNorm(0.0), 0.5, 1e-9), "K7a 0 dB ⟹ norm 0.5", @"");
        Ck(Near(RLPVolDbToNorm(-120.0), 0.0, 1e-6) && Near(RLPVolDbToNorm(20.0), 1.0, 1e-6),
           "K7b -120 dB ⟹ 0、+20 dB ⟹ 1（两端铺满）", @"");
        Ck(Near(RLPVolNormToDb(0.5), 0.0, 0.051), "K7c norm 0.5 ⟹ 0 dB", @"");
        Ck(Near(RLPVolNormToDb(0.0), -120.0, 0.051) && Near(RLPVolNormToDb(1.0), 20.0, 0.051),
           "K7d norm 0 ⟹ -120 dB、norm 1 ⟹ +20 dB", @"");
        BOOL inverse = YES;
        for (double db = -110.0; db <= 18.0; db += 7.0) {
            const double back = RLPVolNormToDb(RLPVolDbToNorm(db));
            if (!Near(back, db, 0.11)) inverse = NO;
        }
        Ck(inverse, "K7e dB→norm→dB 互逆（误差 ≤ 0.1 dB，即 volClamp 量化步长）", @"");
    }

    // ---- K8：拖动映射（角度 → dB）----
    {
        Ck(Near(RLPVolKnobDbFromAngleDegrees(0.0), 0.0, 0.051),
           "K8a 正上方（0°）⟹ 0 dB", @"");
        Ck(Near(RLPVolKnobDbFromAngleDegrees(-135.0), -120.0, 0.051),
           "K8b 左端 -135° ⟹ -120 dB", @"");
        Ck(Near(RLPVolKnobDbFromAngleDegrees(135.0), 20.0, 0.051),
           "K8c 右端 +135° ⟹ +20 dB", @"");
        Ck(Near(RLPVolKnobDbFromAngleDegrees(-200.0), -120.0, 0.051) &&
           Near(RLPVolKnobDbFromAngleDegrees(200.0), 20.0, 0.051),
           "K8d 超出一圈的角度被夹到端点（不越界）", @"");
        const double nanDb = RLPVolKnobDbFromAngleDegrees(NAN);
        Ck(std::isfinite(nanDb) && Near(nanDb, 0.0, 1e-9),
           "K8e NaN 角度不产生 NaN dB（按 0 处理，不会把音量写坏）",
           [NSString stringWithFormat:@"db=%.1f", nanDb]);
    }

    // ---- K9：刻度表与 major 判定（与 web RL_VOL_TICKS 逐项一致）----
    {
        NSArray<NSNumber *> *want = @[ @(-120), @(-60), @(-30), @(-18), @(-12), @(-9), @(-6),
                                       @(-3), @0, @3, @6, @12, @20 ];
        Ck([RLPVolKnobTickDbs() isEqualToArray:want],
           "K9a 刻度表逐项等于 web RL_VOL_TICKS",
           [RLPVolKnobTickDbs() componentsJoinedByString:@","]);
        Ck(RLPVolKnobTickIsMajor(0) && RLPVolKnobTickIsMajor(-12) && RLPVolKnobTickIsMajor(20) &&
           !RLPVolKnobTickIsMajor(-30) && !RLPVolKnobTickIsMajor(3),
           "K9b major 判定与 web 一致（-120/-60/-12/0/6/12/20）", @"");
    }

    // ---- K10：视图行为（可拖、锁定后不拖、拖动中不提交）----
    {
        RLPVolumeKnobView *knob = [[RLPVolumeKnobView alloc] initWithFrame:NSMakeRect(0, 0, 64, 64)];
        knob.db = 0.0;
        __block double live = NAN, commit = NAN;
        knob.onLiveChange = ^(double db) { live = db; };
        knob.onCommit = ^(double db) { commit = db; };
        const BOOL changed = [knob dragToPointForAudit:NSMakePoint(8.0, 32.0)];
        Ck(changed && knob.db < 0.0, "K10a 拖到左侧得到负 dB（且真的变了）",
           [NSString stringWithFormat:@"db=%.1f", knob.db]);
        Ck(Near(live, knob.db, 0.001), "K10b 拖动中回调收到同一个值（实时反馈）", @"");
        Ck(std::isnan(commit), "K10c 拖动中不提交（只有松开才 commitVolumeGesture）", @"");
        knob.locked = YES;
        const double before = knob.db;
        Ck(![knob dragToPointForAudit:NSMakePoint(60.0, 10.0)] && Near(knob.db, before, 1e-9),
           "K10d 锁定后拖动无效（web data-locked=true 同语义）",
           [NSString stringWithFormat:@"db=%.1f", knob.db]);
        knob.locked = NO;
        knob.db = 999.0;
        Ck(Near(knob.db, 20.0, 1e-9), "K10e 越界赋值被夹到 +20 dB（volClamp 同语义）",
           [NSString stringWithFormat:@"db=%.1f", knob.db]);
    }

    std::printf("\n结果：%d passed, %d failed\n", gPass, gFail);
    return gFail == 0 ? 0 : 1;
}
