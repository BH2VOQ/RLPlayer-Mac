// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_bar_core.mm — 底栏 × 真实 embedded 核心（第2项判据的**快速**那一份）
//
// ============================ 这个测试在证明什么 ============================
// 用户实机（2026-11-13）：「在播放页之外的页面，播放进行中底部播放条的按钮仍显示三角形（播放），
// 没有切成暂停态；播放页内是正确的。」
//
// 为什么必须单独有这一份（而不是只放在 --audit 里）：
//   * --audit 一轮 13 分钟，改一行判据要等一刻钟才能看到结果；
//   * 底栏的图标是「0.5s 轮询 → 异步回调 → 应用状态」三段异步拼起来的，
//     用固定 Pump 去读一定是假红/假绿。必须在**同一个进程里**把底栏接到真核心上，
//     用「不变量」判：底栏 isPlaying 必须最终等于 /api/status 的 playing。
//
// 判据（全部走生产入口，不 mock）：
//   B1  播放后底栏 isPlaying 变成 true（轮询真的把状态带到非播放页的底栏）
//   B2  此时播放键的图标位图 pause 态；暂停后位图必须**不同**（用户说的"永远是三角形"）
//   B3  暂停后底栏 isPlaying 回到 false（不是单向锁死）
//   B4  停止后底栏 isPlaying=false 且图标回到 play 态
//
// ============================ 铁律②：绝不出声 ============================
//   backend=null + volume=-120：只跑 DSP，样本直接丢弃，绝不打开任何音频设备。
//   曲库/配置落临时目录，不碰用户真实库根；不监听端口；不 fork 任何子进程。
#include "rlapp_core.h"
#include "net/webui.h"

#import <AppKit/AppKit.h>
#import "RLPPlaybackBarView.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>

namespace fs = std::filesystem;

static int g_fail = 0, g_pass = 0;
static void ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++g_fail; }
}

/// 转 runloop：底栏的轮询回调与核心的异步完成都在主队列上，必须放行才走得到。
static void Pump(NSTimeInterval seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
}

/// 播放键当前图标的位图指纹。
/// 为什么不用 image.name：`+imageWithSystemSymbolName:` 生成的 NSImage 的 name 可以是 nil，
/// 拿 name 判「是不是 pause」会永远为 nil ⟹ 判据恒红（本轮真踩到）。
/// 位图指纹是"图标真的长这样"的直接证据，也是两种状态可比较的量。
static NSData *IconFingerprint(RLPPlaybackBarView *bar) {
    NSButton *pb = [bar valueForKey:@"playBtn"];
    NSImage *img = pb.image;
    if (!img) return nil;
    NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:[img TIFFRepresentation]];
    return rep ? [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] : nil;
}

/// 轮询到 predicate 成立或超时；返回是否成立。
static BOOL WaitUntil(NSTimeInterval timeout, BOOL (^pred)(void)) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([until timeIntervalSinceNow] > 0) {
        if (pred()) return YES;
        Pump(0.05);
    }
    return pred();
}

int main() {
    @autoreleasepool {
        std::printf("== 底栏 × 真实 embedded 核心（backend=null, volume=-120）==\n");

        // ---- 隔离：临时目录 + 关掉启动扫描（本用例不需要索引，只要一个能播的文件）----
        const fs::path tmp = fs::temp_directory_path() /
            ("rlp_bar_core_" + std::to_string((int)::getpid()));
        std::error_code ec;
        fs::remove_all(tmp, ec);
        for (const char *leaf : {"", "home", "state", "covers", "music"})
            fs::create_directories(tmp / leaf, ec);
        ::setenv("HOME", (tmp / "home").c_str(), 1);
        ::setenv("CFFIXED_USER_HOME", (tmp / "home").c_str(), 1);
        ::setenv("RLPLAYER_STATE_DIR", (tmp / "state").c_str(), 1);
        ::setenv("RLPLAYER_LIBRARY_DIR", tmp.c_str(), 1);
        ::setenv("RLPLAYER_COVER_DIR", (tmp / "covers").c_str(), 1);
        std::ofstream(tmp / "state" / "rlplayer-settings.conf")
            << "backend=null\nvolume=-120\nscanonstartup=0\nmetaon=0\nmetallm=0\n";
        std::ofstream(tmp / "rlplayer-library.conf") << (tmp / "music").string() << "\n";

        [NSApplication sharedApplication];

        ck([[RLPCoreClient shared] startEmbedded], "embedded 核心启动（隔离目录，不监听端口）", @"");

        // ---- C1 /api/qdel 越界索引必须如实报失败（2026-11-18 夜间评审 A1）----
        // 旧实现：idx >= items.size() 时什么都不删，仍回 {"ok":true,"count":N} ⟹
        // 客户端只能看到"成功"，把没删掉的行也提示成「已移除」。
        {
            __block NSDictionary *resp = nil;
            __block BOOL replied = NO;
            [[RLPCoreClient shared] postJSON:@"/api/qdel?i=0" body:nil completion:^(NSDictionary * _Nullable j) {
                resp = j;
                replied = YES;
            }];
            (void)WaitUntil(5.0, ^BOOL { return replied; });
            ck(replied && [resp isKindOfClass:[NSDictionary class]] &&
               [resp[@"ok"] boolValue] == NO,
               "空队列上 qdel?i=0 返回 ok:false（旧实现恒 ok:true ⟹ 假报已移除）",
               [NSString stringWithFormat:@"resp=%@", resp ?: @"(nil)"]);
            ck(replied && [resp[@"count"] integerValue] == 0,
               "失败回包仍带真实 count=0（客户端可据此判断队列没有变）",
               [NSString stringWithFormat:@"count=%@", resp[@"count"] ?: @"(nil)"]);
        }

        // 夹具：一个真实可解码的音频文件（用系统 say 生成，与 --audit 同法；绝不播放）
        NSString *music = [NSString stringWithUTF8String:(tmp / "music").c_str()];
        NSString *media = [music stringByAppendingPathComponent:@"probe.aiff"];
        {
            NSTask *say = [[NSTask alloc] init];
            say.launchPath = @"/usr/bin/say";
            say.arguments = @[ @"-o", media, @"test" ];
            @try { [say launch]; [say waitUntilExit]; } @catch (NSException *e) { (void)e; }
        }
        ck([[NSFileManager defaultManager] fileExistsAtPath:media] &&
           [[[NSFileManager defaultManager] attributesOfItemAtPath:media error:nil] fileSize] > 1000,
           "夹具音频文件已生成（真实可解码）", media);

        RLPPlaybackBarView *bar = [[RLPPlaybackBarView alloc] initWithFrame:NSMakeRect(0, 0, 1120, 66)];
        ck(bar != nil, "底栏视图构造成功", @"nil");
        [bar layout];

        // 生产入口：主窗口启动时就是这么做的
        [bar startPolling];
        ck(bar.polling, "底栏进入轮询（startPolling 生效）", @"");

        // 初始应为「未播放」
        WaitUntil(2.0, ^BOOL { return bar.lastStatus != nil; });
        ck(bar.lastStatus != nil, "底栏收到了第一次 /api/status", @"lastStatus=nil");
        ck(!bar.isPlaying, "未播放时 isPlaying=false", @"");
        NSData *iconIdle = IconFingerprint(bar);
        ck(iconIdle != nil, "未播放时播放键有真实图标位图", @"");

        // ---- 起播（生产入口 RLPPlayPath → /api/play）----
        RLPPostJSON(@"/api/play", [NSString stringWithFormat:@"file=%@", RLPEnc(media)]);
        const BOOL sawPlaying = WaitUntil(6.0, ^BOOL { return bar.isPlaying; });
        ck(sawPlaying, "B1: 播放后底栏 isPlaying=true（状态真的到了非播放页的底栏）",
           [NSString stringWithFormat:@"polling=%d lastStatus=%@",
            (int)bar.polling, bar.lastStatus ? @"有" : @"nil"]);
        NSData *iconPlaying = IconFingerprint(bar);

        // ---- 暂停：图标必须换，状态必须回 false ----
        RLPPostJSON(@"/api/pause?on=1", nil);
        const BOOL sawPaused = WaitUntil(6.0, ^BOOL { return !bar.isPlaying; });
        ck(sawPaused, "B3: 暂停后底栏 isPlaying=false（不是单向锁死）", @"");
        NSData *iconPaused = IconFingerprint(bar);

        ck(iconPlaying != nil && iconPaused != nil &&
           ![iconPlaying isEqualToData:iconPaused],
           "B2: 播放/暂停两态的播放键图标位图不同（真换图，不是一直画三角形）",
           [NSString stringWithFormat:@"playing=%luB paused=%luB",
            (unsigned long)iconPlaying.length, (unsigned long)iconPaused.length]);

        // ---- 停止：图标必须回到 idle 那一张 ----
        RLPPostJSON(@"/api/stop", nil);
        WaitUntil(4.0, ^BOOL { return !bar.isPlaying; });
        Pump(0.8);
        NSData *iconStopped = IconFingerprint(bar);
        ck(!bar.isPlaying, "B4: 停止后 isPlaying=false", @"");
        ck(iconStopped != nil && iconIdle != nil && [iconStopped isEqualToData:iconIdle],
           "B4: 停止后播放键图标回到未播放态（与初始同一张图）",
           [NSString stringWithFormat:@"stopped=%luB idle=%luB",
            (unsigned long)iconStopped.length, (unsigned long)iconIdle.length]);

        [bar stopPolling];
        [[RLPCoreClient shared] shutdown];
        fs::remove_all(tmp, ec);

        std::printf("\n%s（%d passed, %d failed）\n",
                    g_fail == 0 ? "底栏×核心 全部通过" : "底栏×核心 有失败", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
