// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_lyrics.mm — LRC 解析必须与 web parseLrc 逐条一致
//
// 判据取自 src/net/ui_script.h 的 parseLrc / lyricTimed（只读参考）。
// 这些规则都不是"想当然"能写对的，web 里每条都有来由：
//   L1 [offset:] 正值让歌词提前 ⟹ 时间戳减掉
//   L2 小数位数决定量纲（1/2/3 位 = 0.1/0.01/0.001 秒）
//   L3 一行多时间戳展开成多行，并按时间排序
//   L4 [ti:]/[ar:]/[by:] 与空行不进结果
//   L5 纯文本歌词保留行但 t=-1 ⟹ 不高亮不跟随（不是"解析失败"）
//   L6 高亮取"最后一个 t <= pos"，pos 在首行之前时不高亮
#import <Foundation/Foundation.h>
#import "RLPLyrics.h"
#include <cstdio>
#include <cmath>

static int gFail = 0, gPass = 0;
static void CK(BOOL ok, const char *what, NSString *detail) {
    if (ok) { ++gPass; std::printf("  [PASS] %s\n", what); }
    else { ++gFail; std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); }
}
static BOOL Near(double a, double b) { return std::fabs(a - b) < 1e-6; }

int main() {
    @autoreleasepool {
        std::printf("=== test_native_lyrics（对照 web parseLrc）===\n");

        // L1 offset：+500ms ⟹ 歌词提前，[00:10.00] 变 9.5s
        {
            NSArray<RLPLyricLine *> *l = [RLPLyrics parse:@"[offset:+500]\n[00:10.00]hello"];
            CK(l.count == 1, "L1a offset 行本身不进结果", @(l.count).stringValue);
            CK(l.count == 1 && Near(l[0].t, 9.5), "L1b +500ms offset 让时间提前 0.5s",
               l.count ? @(l[0].t).stringValue : @"nil");
        }
        {
            NSArray<RLPLyricLine *> *l = [RLPLyrics parse:@"[offset:-500]\n[00:10.00]hello"];
            CK(l.count == 1 && Near(l[0].t, 10.5), "L1c -500ms offset 让时间延后 0.5s",
               l.count ? @(l[0].t).stringValue : @"nil");
        }
        // offset 不能把时间压成负数
        {
            NSArray<RLPLyricLine *> *l = [RLPLyrics parse:@"[offset:+5000]\n[00:01.00]x"];
            CK(l.count == 1 && l[0].t == 0, "L1d offset 过大时钳到 0（不出负时间）",
               l.count ? @(l[0].t).stringValue : @"nil");
        }

        // L2 小数位数决定量纲
        {
            NSArray<RLPLyricLine *> *a = [RLPLyrics parse:@"[00:01.5]x"];
            NSArray<RLPLyricLine *> *b = [RLPLyrics parse:@"[00:01.50]x"];
            NSArray<RLPLyricLine *> *c = [RLPLyrics parse:@"[00:01.500]x"];
            CK(a.count == 1 && Near(a[0].t, 1.5),  "L2a 一位小数 = 十分之一秒", @(a.firstObject.t).stringValue);
            CK(b.count == 1 && Near(b[0].t, 1.5),  "L2b 两位小数 = 百分之一秒", @(b.firstObject.t).stringValue);
            CK(c.count == 1 && Near(c[0].t, 1.5),  "L2c 三位小数 = 毫秒", @(c.firstObject.t).stringValue);
            NSArray<RLPLyricLine *> *d = [RLPLyrics parse:@"[00:01.05]x"];
            CK(d.count == 1 && Near(d[0].t, 1.05), "L2d 两位小数 05 = 0.05s（不是 0.5s）",
               @(d.firstObject.t).stringValue);
        }

        // L3 一行多时间戳 + 排序
        {
            NSArray<RLPLyricLine *> *l = [RLPLyrics parse:@"[00:20.00][00:05.00]chorus\n[00:10.00]verse"];
            CK(l.count == 3, "L3a 一行两个时间戳展开成两行", @(l.count).stringValue);
            CK(l.count == 3 && Near(l[0].t, 5) && Near(l[1].t, 10) && Near(l[2].t, 20),
               "L3b 按时间升序排序", @"顺序不对");
            CK(l.count == 3 && [l[0].text isEqualToString:@"chorus"] &&
               [l[2].text isEqualToString:@"chorus"],
               "L3c 展开后文本相同", @"文本丢失");
        }

        // L4 元信息与空行
        {
            NSArray<RLPLyricLine *> *l = [RLPLyrics parse:@"[ti:Title]\n[ar:Artist]\n[by:Someone]\n\n[00:01.00]real"];
            CK(l.count == 1 && [l[0].text isEqualToString:@"real"],
               "L4 ti/ar/by 与空行不进结果", @(l.count).stringValue);
        }
        // 带时间戳但文本为空的行也要跳过
        {
            NSArray<RLPLyricLine *> *l = [RLPLyrics parse:@"[00:01.00]\n[00:02.00]ok"];
            CK(l.count == 1 && [l[0].text isEqualToString:@"ok"],
               "L4b 空文本的时间戳行跳过", @(l.count).stringValue);
        }

        // L5 纯文本歌词
        {
            NSArray<RLPLyricLine *> *l = [RLPLyrics parse:@"first line\nsecond line"];
            CK(l.count == 2, "L5a 纯文本保留每一行", @(l.count).stringValue);
            CK(l.count == 2 && l[0].t == -1 && l[1].t == -1,
               "L5b 纯文本 t=-1（不是 0）", @"t 应为 -1");
            CK(![RLPLyrics isTimed:l], "L5c isTimed=NO ⟹ 不跟随滚动", @"应为 NO");
            CK([RLPLyrics activeIndex:l position:5] == -1,
               "L5d 纯文本永不高亮", @"应为 -1");
        }
        {
            NSArray<RLPLyricLine *> *l = [RLPLyrics parse:@"[00:01.00]a"];
            CK([RLPLyrics isTimed:l], "L5e 有时间轴 isTimed=YES", @"应为 YES");
        }

        // L6 高亮选行
        {
            NSArray<RLPLyricLine *> *l = [RLPLyrics parse:@"[00:01.00]a\n[00:03.00]b\n[00:05.00]c"];
            CK([RLPLyrics activeIndex:l position:0.5] == -1, "L6a 首行之前不高亮", @"应为 -1");
            CK([RLPLyrics activeIndex:l position:1.0] == 0,  "L6b 正好在首行时间点上高亮首行", @"应为 0");
            CK([RLPLyrics activeIndex:l position:2.9] == 0,  "L6c 两行之间保持上一行", @"应为 0");
            CK([RLPLyrics activeIndex:l position:3.0] == 1,  "L6d 到下一行时间点切换", @"应为 1");
            CK([RLPLyrics activeIndex:l position:99] == 2,   "L6e 超过末行仍高亮末行", @"应为 2");
        }

        // 空输入安全
        CK([RLPLyrics parse:nil].count == 0, "L7a nil 安全返回空", @"");
        CK([RLPLyrics parse:@""].count == 0, "L7b 空串安全返回空", @"");
        CK([RLPLyrics isTimed:@[]] == NO, "L7c 空数组 isTimed=NO", @"");
        CK([RLPLyrics activeIndex:@[] position:1] == -1, "L7d 空数组不高亮", @"");

        std::printf("\n%s（%d 项失败）\n",
                    gFail == 0 ? "native lyrics 全部通过" : "native lyrics 有失败", gFail);
        return gFail == 0 ? 0 : 1;
    }
}
