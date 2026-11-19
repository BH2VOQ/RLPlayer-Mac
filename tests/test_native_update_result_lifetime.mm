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
- (void)invalidatePlan;
- (BOOL)canInstallPlan;
- (void)onPrimary:(id)sender;
- (void)onIgnore:(id)sender;
- (void)onCancel:(id)sender;
- (void)onRelaunch:(id)sender;
- (void)onQuit:(id)sender;
- (BOOL)windowShouldClose:(NSWindow *)sender;
- (BOOL)installing;
- (BOOL)cancelling;
- (BOOL)installStageLocked;
- (BOOL)installed;
- (BOOL)autoRestartScheduled;
- (void)clearTestHooks;
- (void)resetForTesting;
- (void)setTestInstallRunner:(void (^)(const rta::update::CheckResult &plan,
                                       rta::update::ProgressFn progress,
                                       rta::update::InstallOutcomeFn done,
                                       rta::update::CancelToken cancel))runner;
- (void)setTestAlertHandler:(void (^)(NSString *title, NSString *message))handler;
- (void)setTestConfirmHandler:(BOOL (^)(NSString *title, NSString *message))handler;
- (void)setTestToastHandler:(void (^)(NSString *message))handler;
- (void)setTestTerminateHandler:(void (^)(void))handler;
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
static NSButton *FindButton(NSWindow *win, NSString *title) {
    NSMutableArray<NSView *> *all = [NSMutableArray array];
    Collect(win.contentView, all);
    for (NSView *v in all) {
        if (![v isKindOfClass:[NSButton class]]) continue;
        NSButton *b = (NSButton *)v;
        if ([b.title isEqualToString:title]) return b;
    }
    return nil;
}
static BOOL HasLabelText(NSWindow *win, NSString *needle) {
    NSMutableArray<NSView *> *all = [NSMutableArray array];
    Collect(win.contentView, all);
    for (NSView *v in all) {
        if (![v isKindOfClass:[NSTextField class]]) continue;
        NSString *s = ((NSTextField *)v).stringValue;
        if ([s containsString:needle]) return YES;
    }
    return NO;
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

        NSButton *primaryBtn = FindButton(ctrl.window, @"立即更新");
        NSButton *ignoreBtn = FindButton(ctrl.window, @"忽略此版本");
        NSButton *cancelBtn = FindButton(ctrl.window, @"取消下载");
        Ck(primaryBtn != nil && ignoreBtn != nil && cancelBtn != nil,
           @"更新窗口关键按钮（立即更新/忽略此版本/取消下载）在位",
           [NSString stringWithFormat:@"primary=%d ignore=%d cancel=%d",
            primaryBtn != nil, ignoreBtn != nil, cancelBtn != nil]);
        Ck(primaryBtn.target == ctrl && primaryBtn.action == @selector(onPrimary:) &&
           ignoreBtn.target == ctrl && ignoreBtn.action == @selector(onIgnore:) &&
           cancelBtn.target == ctrl && cancelBtn.action == @selector(onCancel:),
           @"按钮目标与动作绑定正确", @"");

        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        NSString *const kIgnoredKey = @"RLPIgnoredUpdateVersion";
        id prevIgnored = [ud objectForKey:kIgnoredKey];
        [ud removeObjectForKey:kIgnoredKey];

        @try {
            // 初始态（尚未拿到任何可用检查结果）：无计划、不可更新、空闲态取消安全空转。
            Ck(![ctrl canInstallPlan] && !primaryBtn.enabled && !ignoreBtn.enabled && cancelBtn.hidden,
               @"初始态无安装计划且禁用更新/忽略按钮",
               [NSString stringWithFormat:@"canInstall=%d primary=%d ignore=%d cancelHidden=%d",
                [ctrl canInstallPlan], primaryBtn.enabled, ignoreBtn.enabled, cancelBtn.hidden]);
            [ctrl onPrimary:primaryBtn];
            Ck(cancelBtn.hidden && ![ctrl canInstallPlan],
               @"无计划时触发 onPrimary: 不会进入下载态或启动安装", @"");
            [ctrl onCancel:cancelBtn];
            Ck(cancelBtn.hidden && !primaryBtn.enabled,
               @"非下载态触发 onCancel: 保持空闲信息态（安全空转）", @"");

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
            Ck([ctrl canInstallPlan] && primaryBtn.enabled && ignoreBtn.enabled,
               @"可用更新结果生成有效计划并启用更新/忽略按钮", @"");

            // 注意：现有夹具无网络/安装器注入接缝，因此不调用真 checkManually:/begin_install；
            // 下面通过现有 postCheckResult:manually: 接缝与控制器本地状态动作做离线回归断言。
            auto makeAvail = [](const char *ver, const std::string &notesText) {
                rta::update::CheckResult r;
                r.decision = rta::update::Decision::UpdateAvailable;
                r.status = 200;
                r.size = 12345678;
                r.remoteVersion = ver;
                r.downloadUrl = std::string("https://github.com/rainlain/RLPlayer/releases/download/v") +
                                ver + "/RLPlayer.dmg";
                r.sha256 = std::string(64, 'a');
                r.notes = notesText;
                return r;
            };

            // 1) 检查失败结果：立刻废除先前 9.9.9 的旧计划且不可安装
            {
                rta::update::CheckResult failR;
                failR.decision = rta::update::Decision::FailedNetwork;
                failR.error = "offline simulated failure";
                [ctrl postCheckResult:failR manually:NO];
            }
            Pump(0.2);
            Ck(![ctrl canInstallPlan] && !primaryBtn.enabled && !ignoreBtn.enabled,
               @"检查失败后立即废除旧安装计划并禁用更新/忽略按钮", @"");
            Ck(HasLabelText(ctrl.window, @"检查更新失败") &&
               [notes.string isEqualToString:@"offline simulated failure"],
               @"检查失败会替换陈旧版本标题与更新说明",
               [NSString stringWithFormat:@"notes=%@", notes.string]);
            [ctrl onPrimary:primaryBtn];
            Ck(cancelBtn.hidden, @"失败态调用 onPrimary: 不会进入下载态", @"");

            // 2) 最新版本结果（UpToDate）：同样废除之前有效计划
            [ctrl postCheckResult:makeAvail("9.9.10", "notes 9.9.10") manually:NO];
            Pump(0.2);
            Ck([ctrl canInstallPlan] && primaryBtn.enabled,
               @"重新收到可用更新 9.9.10 后建立新计划", @"");
            {
                rta::update::CheckResult upToDateR;
                upToDateR.decision = rta::update::Decision::UpToDate;
                upToDateR.remoteVersion = "9.9.10";
                [ctrl postCheckResult:upToDateR manually:NO];
            }
            Pump(0.2);
            Ck(![ctrl canInstallPlan] && !primaryBtn.enabled && !ignoreBtn.enabled,
               @"已是最新结果废除旧计划并禁用更新/忽略按钮", @"");
            Ck(HasLabelText(ctrl.window, @"已是最新版本") && notes.string.length == 0,
               @"已是最新会清空旧更新说明", @"");
            [ctrl onPrimary:primaryBtn];
            Ck(cancelBtn.hidden, @"已是最新态调用 onPrimary: 不会启动安装", @"");

            // 3) 忽略此版本：持久化写入并立刻废除计划；同版本再次到达依然不可安装
            [ctrl postCheckResult:makeAvail("9.9.11", "notes 9.9.11") manually:NO];
            Pump(0.2);
            Ck([ctrl canInstallPlan] && primaryBtn.enabled && ignoreBtn.enabled,
               @"可用更新 9.9.11 建立计划并允许忽略", @"");
            [ctrl onIgnore:ignoreBtn];
            Ck([RLPUpdateWindowController isVersionIgnored:@"9.9.11"] &&
               ![ctrl canInstallPlan] && !primaryBtn.enabled && !ignoreBtn.enabled,
               @"点击忽略后记录已忽略版本并立即禁用旧计划", @"");
            [ctrl onPrimary:primaryBtn];
            Ck(cancelBtn.hidden, @"忽略当前版本后调用 onPrimary: 不会启动安装", @"");

            [ctrl postCheckResult:makeAvail("9.9.11", "notes 9.9.11 again") manually:NO];
            Pump(0.2);
            Ck(![ctrl canInstallPlan] && !primaryBtn.enabled && !ignoreBtn.enabled &&
               HasLabelText(ctrl.window, @"9.9.11 已被忽略"),
               @"已被忽略版本再次检查到达仍不可安装", @"");

            // 4) 空版本号的异常 UpdateAvailable：不能视为可安装计划
            {
                rta::update::CheckResult emptyVer = makeAvail("", "missing version");
                [ctrl postCheckResult:emptyVer manually:NO];
            }
            Pump(0.2);
            Ck(![ctrl canInstallPlan] && !primaryBtn.enabled,
               @"空版本号检查结果不可安装", @"");

            // 5) 直接触发 invalidatePlan（同 checkManually: 开场禁用旧计划动作）：立刻清计划并禁按钮
            [ctrl postCheckResult:makeAvail("9.9.12", "notes 9.9.12") manually:NO];
            Pump(0.2);
            Ck([ctrl canInstallPlan] && primaryBtn.enabled,
               @"可用更新 9.9.12 建立新计划（供 invalidatePlan 验证）", @"");
            [ctrl invalidatePlan];
            Ck(![ctrl canInstallPlan] && !primaryBtn.enabled && !ignoreBtn.enabled,
               @"invalidatePlan 立即清除安装计划并禁用更新/忽略按钮", @"");
            [ctrl onPrimary:primaryBtn];
            Ck(cancelBtn.hidden, @"计划失效后调用 onPrimary: 不会启动安装", @"");

            // =========================================================================
            // 6) 【U1 / U3 / U4 / U5】更新窗口取消语义、稳定重启码、关窗/退出确认回归
            // =========================================================================
            __block NSMutableArray<NSString *> *toastLog = [NSMutableArray array];
            __block NSMutableArray<NSString *> *alertLog = [NSMutableArray array];
            __block NSMutableArray<NSString *> *confirmMsgs = [NSMutableArray array];
            __block BOOL confirmNextAnswer = NO;
            __block NSInteger terminateCount = 0;

            __block rta::update::ProgressFn capturedProgress = nil;
            __block rta::update::InstallOutcomeFn capturedDone = nil;
            __block rta::update::CancelToken capturedCancel;

            auto installHooks = ^{
                [toastLog removeAllObjects];
                [alertLog removeAllObjects];
                [confirmMsgs removeAllObjects];
                terminateCount = 0;
                [ctrl setTestToastHandler:^(NSString *m) {
                    if (m) [toastLog addObject:m];
                }];
                [ctrl setTestAlertHandler:^(NSString *t, NSString *m) {
                    [alertLog addObject:[NSString stringWithFormat:@"%@:%@", t ?: @"", m ?: @""]];
                }];
                [ctrl setTestConfirmHandler:^BOOL(NSString *t, NSString *m) {
                    [confirmMsgs addObject:[NSString stringWithFormat:@"%@:%@", t ?: @"", m ?: @""]];
                    return confirmNextAnswer;
                }];
                [ctrl setTestTerminateHandler:^{
                    ++terminateCount;
                }];
                [ctrl setTestInstallRunner:^(const rta::update::CheckResult &plan,
                                             rta::update::ProgressFn progress,
                                             rta::update::InstallOutcomeFn done,
                                             rta::update::CancelToken cancel) {
                    (void)plan;
                    capturedProgress = progress;
                    capturedDone = done;
                    capturedCancel = cancel;
                }];
            };

            auto startInstall = ^(const char *ver) {
                [ctrl resetForTesting];
                [ctrl postCheckResult:makeAvail(ver, "notes") manually:NO];
                Pump(0.15);
                [ctrl onPrimary:primaryBtn];
                Pump(0.05);
            };

            installHooks();

            // --- U1-a: 下载中请求取消 → 后端越界进入 installing → 随后失败：绝不能报「已取消下载」吞掉错误 ---
            startInstall("9.9.13");
            Ck([ctrl installing] && !cancelBtn.hidden && cancelBtn.enabled,
               @"【U1-a】点击立即更新后进入下载态且取消按钮可用", @"");
            {
                rta::update::NativeProgress p;
                p.stage = "downloading"; p.detail = "正在下载 9.9.13"; p.percent = 20;
                capturedProgress(p);
            }
            Pump(0.05);
            [ctrl onCancel:cancelBtn];
            Ck([ctrl cancelling] && !cancelBtn.enabled && capturedCancel.cancelled() &&
               HasLabelText(ctrl.window, @"已请求取消"),
               @"【U1-a】下载中点取消置 cancelling 并提示已请求取消", @"");
            {
                rta::update::NativeProgress p;
                p.stage = "installing"; p.detail = "正在安装…"; p.percent = 60;
                capturedProgress(p);
            }
            Pump(0.05);
            Ck([ctrl installStageLocked] && ![ctrl cancelling] && !cancelBtn.enabled &&
               HasLabelText(ctrl.window, @"安装已开始，无法取消") &&
               !HasLabelText(ctrl.window, @"已请求取消"),
               @"【U1-a】进入 installing 阶段后取消失效，文案改为\"安装已开始，无法取消\"", @"");
            {
                rta::update::InstallOutcome out;
                out.ok = false;
                out.code = rta::update::InstallResultCode::Failed;
                out.cancelled = false;
                out.message = "安装后版本校验失败：1.0.5 vs 9.9.13";
                capturedDone(out);
            }
            Pump(0.1);
            Ck(![ctrl installing] && ![ctrl installed] && alertLog.count == 1 &&
               [alertLog.firstObject containsString:@"1.0.5 vs 9.9.13"] &&
               ![toastLog containsObject:@"已取消下载"],
               @"【U1-a】安装阶段真实失败时必须弹错，绝不因曾点取消而误报已取消下载",
               [NSString stringWithFormat:@"alerts=%@ toasts=%@", alertLog, toastLog]);

            // --- U1-b: 进入 installing 后再点 onCancel: 不得宣称已取消、不得置 token ---
            installHooks();
            startInstall("9.9.14");
            {
                rta::update::NativeProgress p;
                p.stage = "installing"; p.detail = "正在安装…"; p.percent = 60;
                capturedProgress(p);
            }
            Pump(0.05);
            Ck([ctrl installStageLocked] && !cancelBtn.enabled,
               @"【U1-b】installing 开始即禁用取消按钮", @"");
            [ctrl onCancel:cancelBtn];
            Ck(!capturedCancel.cancelled() && ![ctrl cancelling] &&
               HasLabelText(ctrl.window, @"安装已开始，无法取消"),
               @"【U1-b】安装阶段触发 onCancel: 不置 cancel token 也不宣称已请求取消", @"");
            {
                rta::update::InstallOutcome out;
                out.ok = false;
                out.code = rta::update::InstallResultCode::Failed;
                out.cancelled = false;
                out.message = "ditto 复制失败";
                capturedDone(out);
            }
            Pump(0.1);
            Ck(alertLog.count == 1 && [alertLog.firstObject containsString:@"ditto"] &&
               ![toastLog containsObject:@"已取消下载"],
               @"【U1-b】安装阶段后续失败按真实失败弹窗", @"");

            // --- U1-c: 下载阶段取消且后端明确返回 Cancelled ⟹ 报已取消下载且未安装 ---
            installHooks();
            startInstall("9.9.15");
            [ctrl onCancel:cancelBtn];
            {
                rta::update::InstallOutcome out;
                out.ok = false;
                out.code = rta::update::InstallResultCode::Cancelled;
                out.cancelled = true;
                out.message = "更新已取消（未做任何改动）";
                capturedDone(out);
            }
            Pump(0.1);
            Ck(![ctrl installed] && alertLog.count == 0 &&
               [toastLog containsObject:@"已取消下载"],
               @"【U1-c】只有后端明确返回 Cancelled 才走已取消提示且不弹失败框", @"");

            // --- U1-d: 下载阶段点过取消但后端返回校验/网络真实失败 ⟹ 同样不吞错 ---
            installHooks();
            startInstall("9.9.16");
            [ctrl onCancel:cancelBtn];
            {
                rta::update::InstallOutcome out;
                out.ok = false;
                out.code = rta::update::InstallResultCode::Failed;
                out.cancelled = false;
                out.message = "校验失败，已丢弃：sha256 不匹配";
                capturedDone(out);
            }
            Pump(0.1);
            Ck(![ctrl installed] && alertLog.count == 1 &&
               [alertLog.firstObject containsString:@"校验失败"] &&
               ![toastLog containsObject:@"已取消下载"],
               @"【U1-d】即使在下载阶段点过取消，后端回报 Failed 仍如实弹错", @"");

            // --- U3-a: 稳定重启码 InstalledAutoRestart（英文/本地化文案不含中文\"正在自动重启\"）---
            installHooks();
            startInstall("9.9.17");
            {
                rta::update::InstallOutcome out;
                out.ok = true;
                out.code = rta::update::InstallResultCode::InstalledAutoRestart;
                out.autoRestartScheduled = true;
                out.message = "Updated and restarting automatically"; // ← 无中文子串
                capturedDone(out);
            }
            Pump(0.1);
            Ck([ctrl installed] && [ctrl autoRestartScheduled] &&
               [primaryBtn.title isEqualToString:@"重启"] &&
               primaryBtn.action == @selector(onRelaunch:),
               @"【U3-a】稳定码 InstalledAutoRestart 不依赖中文文案即可识别自动重启",
               [NSString stringWithFormat:@"auto=%d title=%@", [ctrl autoRestartScheduled], primaryBtn.title]);
            [ctrl onRelaunch:primaryBtn];
            Ck(terminateCount == 1 && alertLog.count == 0,
               @"【U3-a】onRelaunch: 在 autoRestartScheduled=YES 时直接退出以完成重启", @"");

            // --- U3-b: 对照反证 — InstalledManualRestart 哪怕文案里混入\"正在自动重启\"也不许误判 ---
            installHooks();
            startInstall("9.9.18");
            {
                rta::update::InstallOutcome out;
                out.ok = true;
                out.code = rta::update::InstallResultCode::InstalledManualRestart;
                out.autoRestartScheduled = false;
                out.message = "正在自动重启脚本失败，请手动重启"; // ← 故意包含中文子串
                capturedDone(out);
            }
            Pump(0.1);
            Ck([ctrl installed] && ![ctrl autoRestartScheduled] &&
               [primaryBtn.title isEqualToString:@"退出 RLPlayer"] &&
               primaryBtn.action == @selector(onQuit:),
               @"【U3-b】反证：稳定码 InstalledManualRestart 压倒文案子串，正确切到手动退出",
               [NSString stringWithFormat:@"auto=%d title=%@", [ctrl autoRestartScheduled], primaryBtn.title]);
            [ctrl onRelaunch:nil];
            Ck(terminateCount == 0 && alertLog.count == 1,
               @"【U3-b】手调 onRelaunch: 时不静默退出而提示手动重启", @"");

            // --- U4-a/b: 安装中 onQuit: 先确认，拒绝继续安装，确认才终止且不伪装成功 ---
            installHooks();
            startInstall("9.9.19");
            confirmNextAnswer = NO;
            [ctrl onQuit:nil];
            Ck(confirmMsgs.count == 1 &&
               [confirmMsgs.firstObject containsString:@"正在安装"] &&
               [confirmMsgs.firstObject containsString:@"退出可能留下未完成更新"] &&
               terminateCount == 0 && [ctrl installing] && ![ctrl installed],
               @"【U4-a】安装中 onQuit: 先弹出风险提示，用户取消则不退出且保持安装中",
               [NSString stringWithFormat:@"confirms=%@ term=%ld", confirmMsgs, (long)terminateCount]);

            confirmNextAnswer = YES;
            [ctrl onQuit:nil];
            Ck(confirmMsgs.count == 2 && terminateCount == 1 &&
               ![ctrl installing] && ![ctrl installed],
               @"【U4-b】安装中 onQuit: 用户确认后才终止，且绝不伪装成已安装",
               [NSString stringWithFormat:@"term=%ld installed=%d", (long)terminateCount, [ctrl installed]]);

            // --- U4-c/d/e: 窗口关闭代理 windowShouldClose: 安装中先确认；拒绝不关不取消；确认不伪装成功 ---
            installHooks();
            startInstall("9.9.20");
            {
                rta::update::NativeProgress p;
                p.stage = "installing"; p.detail = "正在安装…"; p.percent = 65;
                capturedProgress(p);
            }
            Pump(0.05);
            confirmNextAnswer = NO;
            const BOOL shouldCloseDenied = [ctrl windowShouldClose:ctrl.window];
            Ck(!shouldCloseDenied && confirmMsgs.count == 1 &&
               [confirmMsgs.firstObject containsString:@"正在安装"] &&
               [ctrl installing] && ![ctrl cancelling] && !capturedCancel.cancelled() && ![ctrl installed],
               @"【U4-c】安装中点关窗用户拒绝 ⟹ windowShouldClose=NO、不静默取消、不终止", @"");

            confirmNextAnswer = YES;
            const BOOL shouldCloseInstallConfirmed = [ctrl windowShouldClose:ctrl.window];
            Ck(shouldCloseInstallConfirmed && confirmMsgs.count == 2 &&
               ![ctrl installed] && ![ctrl cancelling] && !capturedCancel.cancelled() &&
               ![toastLog containsObject:@"已取消下载"],
               @"【U4-d】installing 阶段确认关窗 ⟹ 允许关闭但不触发假取消也不伪装成功", @"");

            // 下载阶段确认关窗：停止下载 token，但不伪装成 installed=YES
            installHooks();
            startInstall("9.9.21");
            confirmNextAnswer = YES;
            const BOOL shouldCloseDlConfirmed = [ctrl windowShouldClose:ctrl.window];
            Ck(shouldCloseDlConfirmed && confirmMsgs.count == 1 &&
               capturedCancel.cancelled() && ![ctrl installed],
               @"【U4-e】下载阶段确认关窗 ⟹ 取消下载令牌且绝不伪装为成功", @"");

            // --- U4-f: 已安装完成后（非安装中）onQuit: 直接退出，不再弹正在安装确认 ---
            installHooks();
            startInstall("9.9.22");
            {
                rta::update::InstallOutcome out;
                out.ok = true;
                out.code = rta::update::InstallResultCode::InstalledManualRestart;
                out.autoRestartScheduled = false;
                out.message = "done";
                capturedDone(out);
            }
            Pump(0.1);
            [ctrl onQuit:nil];
            Ck(confirmMsgs.count == 0 && terminateCount == 1,
               @"【U4-f】安装完成（非安装中）onQuit: 无需提示直接退出", @"");
        } @finally {
            [ctrl clearTestHooks];
            [ctrl resetForTesting];
            if (prevIgnored) [ud setObject:prevIgnored forKey:kIgnoredKey];
            else [ud removeObjectForKey:kIgnoredKey];
            [ctrl invalidatePlan];
            [ctrl close];
        }

        std::printf("结果：%d passed, %d failed\n", gPass, gFail);
        return gFail ? 1 : 0;
    }
}
