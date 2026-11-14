// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_update_result_lifetime.mm — 更新检查结果「跨线程所有权」判据
//
// ============================ 这条判据在证明什么 ============================
// 2026-11-14 实测：`rlplayer_native --audit`（ctest `native_ui_functional`）偶发
// SIGBUS 崩溃，崩溃报告（evidence/native-audit-sigbus-140145.ips）指向
//
//   EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE @0x19bb28000
//   _platform_memmove ← std::string::assign ← rta::update::CheckResult::operator=
//   ← -[RLPUpdateWindowController handleCheckResult:manually:]
//
// 根因不是渲染，也不是专辑详情导航：`rta::update::begin_check` 的 done 回调参数是
// `const CheckResult&`，指向**生产者**的对象；窗口控制器在 done 回调里
// `dispatch_async(主队列, ^{ [self handleCheckResult:r ...]; })`，而 block 捕获
// `const T&` 形式的参数是**引用捕获**（不是拷贝）⟹ done 回调返回后生产者的
// CheckResult 已析构、notes/downloadUrl 的堆缓冲被释放，主线程再读就是读已释放内存。
// 短字符串走 SSO（栈内联）读起来"像正常"，长 notes（发布说明）在 mmap 兜底时
// 会撞 KERN_PROTECTION_FAILURE ⟹ 表现为**偶发** bus error（取决于时机与长度）。
//
// 判据：把「生产者已析构」这件事做成**确定性**场景 —— 用一个带 400 KiB notes 的
// CheckResult 调判据接缝 `postCheckResult:manually:`，**立即离开作用域**让其析构，
// 再跑主队列。修复后主线程必须看到完整、正确的 notes；
// 未修复（引用捕获）时主线程读到已释放缓冲 —— 要么直接崩，要么 notes 视图是空/垃圾。
//
// 纪律：隔离 state/library；不联网（不调 begin_check）；不发声；窗口出现后立刻关掉。
#import <AppKit/AppKit.h>
#import "RLPUpdateWindowController.h"
#include "mac_update.h"   // rta::update::CheckResult / Decision 的真相源

#include <cstdio>
#include <cstdlib>
#include <unistd.h>
#include <string>

// 判据接缝（实现见 RLPUpdateWindowController.mm）。测试自己声明这个类别，
// 避免把 C++ 类型塞进公开 ObjC 头。
@interface RLPUpdateWindowController (RLPResultLifetimeSeam)
- (void)postCheckResult:(const rta::update::CheckResult &)r manually:(BOOL)manually;
@end

static int gFail = 0, gPass = 0;
static void Ck(BOOL ok, NSString *what, NSString *detail) {
    if (ok) { ++gPass; std::printf("  [PASS] %s\n", what.UTF8String); }
    else {
        ++gFail;
        std::printf("  [FAIL] %s — %s\n", what.UTF8String, detail.UTF8String ?: "");
    }
}
static void Pump(NSTimeInterval s) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:s];
    while ([until timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}
static void Collect(NSView *v, NSMutableArray<NSView *> *out) {
    if (!v) return;
    [out addObject:v];
    for (NSView *s in v.subviews) Collect(s, out);
}
/// 在窗口视图树里找 notes 视图（NSTextView，取最长 string 的那个）。
static NSTextView *FindNotes(NSWindow *win) {
    NSMutableArray<NSView *> *all = [NSMutableArray array];
    Collect(win.contentView, all);
    NSTextView *best = nil;
    for (NSView *v in all) {
        if (![v isKindOfClass:[NSTextView class]]) continue;
        NSTextView *tv = (NSTextView *)v;
        if (!best || tv.string.length > best.string.length) best = tv;
    }
    return best;
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        std::printf("=== test_native_update_result_lifetime（跨线程所有权判据 · 不联网 · 不出声）===\n");

        NSString *rootDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"rlp-uplife-%d", (int)getpid()]];
        NSString *state = [rootDir stringByAppendingPathComponent:@"state"];
        NSString *lib = [rootDir stringByAppendingPathComponent:@"lib"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:lib withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("RLPLAYER_STATE_DIR", state.fileSystemRepresentation, 1);
        setenv("RLPLAYER_LIBRARY_DIR", lib.fileSystemRepresentation, 1);

        RLPUpdateWindowController *ctrl = [RLPUpdateWindowController shared];
        Ck(ctrl.window != nil, @"更新窗口在 init 里就已建成（判据前提）", @"window=nil");
        Ck(FindNotes(ctrl.window) != nil, @"窗口里有 notes 视图（判据前提）", @"找不到 NSTextView");

        // 400 KiB 的发布说明：大到 malloc 会用 mmap 兜底，释放后整页归还内核 ⟹
        // 引用捕获时主线程读它必然撞守护页（而不是"碰巧还是旧内容"）。
        const NSUInteger kNotesBytes = 400 * 1024;
        std::string want = std::string(kNotesBytes, 'A') + "ZEND";
        NSString *wantPrefix = @"9.9.9";

        {
            rta::update::CheckResult r;
            r.decision = rta::update::Decision::UpdateAvailable;
            r.status = 200;
            r.size = 12345678;
            r.remoteVersion = "9.9.9";
            r.downloadUrl = "https://github.com/rainlain/RLPlayer/releases/download/v9.9.9/RLPlayer.dmg";
            r.sha256 = std::string(64, 'a');
            r.notes = want;                       // ← 堆缓冲，400 KiB
            [ctrl postCheckResult:r manually:NO];
        }   // ← r 在这里析构：引用捕获时，block 从此指向已释放的对象/缓冲

        Pump(0.6);   // 主队列排空：旧实现此刻读已释放内存

        NSTextView *notes = FindNotes(ctrl.window);
        NSString *got = notes.string ?: @"";
        Ck([got length] == (NSInteger)(kNotesBytes + 4),
           @"主线程读到的 notes 与生产者一致（长度）",
           [NSString stringWithFormat:@"want=%lu got=%lu", (unsigned long)(kNotesBytes + 4),
            (unsigned long)got.length]);
        Ck([[got substringFromIndex:(NSInteger)got.length > 4 ? got.length - 4 : 0]
              isEqualToString:@"ZEND"] || [got hasSuffix:@"ZEND"],
           @"notes 尾部哨兵 ZEND 完整（没有截断/垃圾）",
           [NSString stringWithFormat:@"tail=%@", got.length > 8 ? [got substringFromIndex:got.length - 8] : got]);
        NSString *title = @"";
        NSMutableArray<NSView *> *all = [NSMutableArray array];
        Collect(ctrl.window.contentView, all);
        for (NSView *v in all) {
            if (![v isKindOfClass:[NSTextField class]]) continue;
            NSString *s = ((NSTextField *)v).stringValue;
            if ([s containsString:wantPrefix]) { title = s; break; }
        }
        Ck(title.length > 0, @"窗口标题带远端版本号（说明整条结果都活着，不只 notes）",
           [NSString stringWithFormat:@"title=%@", title]);

        [ctrl close];
        std::printf("结果：%d passed, %d failed\n", gPass, gFail);
        return gFail ? 1 : 0;
    }
}
