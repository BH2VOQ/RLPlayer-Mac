// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_window_frame.mm — 启动窗口 frame 必须收敛在屏幕可见区
// 背景：autosave 会把换屏/拖拽后的 2975×1003 frame 永久保存；在 1920×1050 屏上恢复后
// 右半截在屏外，聆听室卡片与专辑被屏幕边缘裁掉（用户 2026-11-17 截图）。

#include <cstdio>
#import <AppKit/AppKit.h>
#import "RLPSupport.h"

static int g_fail = 0;
static void ck(BOOL cond, const char *what, NSString *detail = @"") {
    if (cond) {
        std::printf("  [PASS] %s\n", what);
    } else {
        std::printf("  [FAIL] %s %s\n", what, detail.UTF8String ?: "");
        ++g_fail;
    }
}
static BOOL same(NSRect a, NSRect b) {
    return fabs(a.origin.x - b.origin.x) < 0.5 && fabs(a.origin.y - b.origin.y) < 0.5 &&
           fabs(a.size.width - b.size.width) < 0.5 && fabs(a.size.height - b.size.height) < 0.5;
}
static NSString *str(NSRect r) {
    return [NSString stringWithFormat:@"%.0f,%.0f %.0fx%.0f", r.origin.x, r.origin.y, r.size.width, r.size.height];
}

int main() {
    @autoreleasepool {
        std::printf("=== test_native_window_frame（离线纯函数）===\n");
        const NSRect vis = NSMakeRect(0, 0, 1920, 1050);
        const NSSize minSize = NSMakeSize(900, 600);

        // 真实脏记录：2975 宽存于 1920 屏，右半截在屏外。
        NSRect dirty = NSMakeRect(572, -42, 2975, 1003);
        NSRect got = RLPClampWindowFrameToVisible(dirty, vis, minSize);
        ck(same(got, NSMakeRect(0, 0, 1920, 1003)),
           "2975×1003 @572,-42 收敛到 1920×1003 @0,0", str(got));

        NSRect huge = NSMakeRect(100, 100, 2500, 1200);
        got = RLPClampWindowFrameToVisible(huge, vis, minSize);
        ck(same(got, NSMakeRect(0, 0, 1920, 1050)),
           "超宽超高 frame 收敛为可见区全尺寸", str(got));

        NSRect small = NSMakeRect(50, 50, 800, 500);
        got = RLPClampWindowFrameToVisible(small, vis, minSize);
        ck(same(got, NSMakeRect(50, 50, 900, 600)),
           "低于最小尺寸的 frame 放大到 minSize 且位置不变", str(got));

        NSRect ok = NSMakeRect(300, 200, 1180, 760);
        got = RLPClampWindowFrameToVisible(ok, vis, minSize);
        ck(same(got, ok), "合法 frame 原样保留", str(got));

        NSRect negative = NSMakeRect(-200, -100, 1180, 760);
        got = RLPClampWindowFrameToVisible(negative, vis, minSize);
        ck(same(got, NSMakeRect(0, 0, 1180, 760)),
           "负坐标 frame 拉回可见区原点", str(got));

        const NSRect tinyScreen = NSMakeRect(0, 0, 800, 500);
        NSRect over = NSMakeRect(0, 0, 1000, 700);
        got = RLPClampWindowFrameToVisible(over, tinyScreen, minSize);
        ck(same(got, NSMakeRect(0, 0, 800, 500)),
           "可见区小于 minSize 时以可见区为准", str(got));

        std::printf("\n结果：%d failed\n", g_fail);
    }
    return g_fail == 0 ? 0 : 1;
}
