// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPUpdateWindowController.mm — 原生更新窗口（一窗两视图 + 五出口）
//
// 五出口（对应竞品的 update/later/ignore/cancel/reopen）：
//   ① 立即更新   → begin_install（下载 → sha256 校验 → 挂载 → 替换 → 重启）
//   ② 稍后       → 关闭窗口，本次会话不再自动弹（不落盘）
//   ③ 忽略此版本 → 落盘（NSUserDefaults），该版本今后不再提示
//   ④ 手动下载   → 打开清单里的下载页（网盘 / GitHub）
//   ⑤ 取消下载   → 只置取消标志（协作式，绝不 force-kill）
//
// 为什么不用 NSTextView/富文本说明：清单里的 notes 是发布者写的纯文本，
// 只做等宽显示 + 可选中，避免把外部文本当富文本解释（安全边界）。
#import "RLPUpdateWindowController.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

#include <memory>

#if __has_include("mac_update.h")
#define RLP_HAVE_UPDATE 1
#include "mac_update.h"
#endif

static NSString *const kIgnoredVersionKey = @"RLPIgnoredUpdateVersion";

#ifdef RLP_HAVE_UPDATE
// 安装计划 + 它的取消令牌必须**同生共死**：CancelToken 是 shared_ptr<atomic<bool>>，
// 复制出来的是同一个标志（见 mac_update.h 的说明）。存成堆对象是为了让 ObjC 属性
// 能持有 C++ 类型，同时保证"取消"点到的确实是本次下载用的那个 token。
struct RLPUpdatePlan {
    rta::update::CheckResult plan;
    rta::update::CancelToken cancel;
};
#endif

@interface RLPUpdateWindowController ()
@property (nonatomic, strong) NSView *infoView;
@property (nonatomic, strong) NSView *downloadView;
@property (nonatomic, strong) NSTextField *titleField;
@property (nonatomic, strong) NSTextView *notesView;
@property (nonatomic, strong) NSTextField *hintField;
@property (nonatomic, strong) NSProgressIndicator *progress;
@property (nonatomic, strong) NSTextField *progressText;
@property (nonatomic, strong) NSButton *primaryBtn;
@property (nonatomic, strong) NSButton *laterBtn;
@property (nonatomic, strong) NSButton *ignoreBtn;
@property (nonatomic, strong) NSButton *manualBtn;
@property (nonatomic, strong) NSButton *cancelBtn;
@property (nonatomic, copy) NSString *remoteVersion;
@property (nonatomic, copy) NSString *manualUrl;
@property (nonatomic) BOOL checking;
/// 检查阶段拿到的安装计划：下载/校验/安装全靠它（URL/sha256/size 都由清单给出，
/// UI 不自己拼 URL——那是安全边界）。没有它就不允许点「立即更新」。
@property (nonatomic) BOOL hasPlan;
#ifdef RLP_HAVE_UPDATE
@property (nonatomic) std::shared_ptr<RLPUpdatePlan> planPtr;
#endif
@end

@implementation RLPUpdateWindowController

+ (instancetype)shared {
    static RLPUpdateWindowController *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[RLPUpdateWindowController alloc] init]; });
    return s;
}

+ (BOOL)isVersionIgnored:(NSString *)version {
    if (!version.length) return NO;
    NSString *ignored = [[NSUserDefaults standardUserDefaults] stringForKey:kIgnoredVersionKey];
    return [ignored isEqualToString:version];
}

- (instancetype)init {
    RLPTheme *t = [RLPTheme current];
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 380)
                                                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    win.title = RLPTr(@"软件更新");
    win.backgroundColor = t.bg;
    win.releasedWhenClosed = NO;
    [win center];
    self = [super initWithWindow:win];
    if (!self) return nil;
    [self buildUI];
    return self;
}

- (void)buildUI {
    RLPTheme *t = [RLPTheme current];
    NSView *root = self.window.contentView;
    root.wantsLayer = YES;
    root.layer.backgroundColor = t.bg.CGColor;

    // ---- 信息态 ----
    self.infoView = [[NSView alloc] initWithFrame:NSZeroRect];
    self.infoView.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:self.infoView];

    self.titleField = RLPLabel(@"", [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold], t.text);
    self.titleField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.infoView addSubview:self.titleField];

    self.notesView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    self.notesView.editable = NO;
    self.notesView.drawsBackground = NO;
    self.notesView.font = t.body;
    self.notesView.textColor = t.text;
    self.notesView.string = @"";
    NSScrollView *notesScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    notesScroll.drawsBackground = NO;
    notesScroll.hasVerticalScroller = YES;
    notesScroll.documentView = self.notesView;
    notesScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.infoView addSubview:notesScroll];

    // ---- 下载态 ----
    self.downloadView = [[NSView alloc] initWithFrame:NSZeroRect];
    self.downloadView.translatesAutoresizingMaskIntoConstraints = NO;
    self.downloadView.hidden = YES;
    [root addSubview:self.downloadView];

    self.progress = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.progress.style = NSProgressIndicatorStyleBar;
    self.progress.indeterminate = NO;
    self.progress.minValue = 0;
    self.progress.maxValue = 100;
    self.progress.translatesAutoresizingMaskIntoConstraints = NO;
    [self.downloadView addSubview:self.progress];

    self.progressText = RLPLabel(@"", t.small, t.mut);
    self.progressText.translatesAutoresizingMaskIntoConstraints = NO;
    [self.downloadView addSubview:self.progressText];

    // ---- 出口按钮 ----
    self.manualBtn = [NSButton buttonWithTitle:RLPTr(@"手动下载") target:self action:@selector(onManual:)];
    self.laterBtn = [NSButton buttonWithTitle:RLPTr(@"稍后") target:self action:@selector(onLater:)];
    self.ignoreBtn = [NSButton buttonWithTitle:RLPTr(@"忽略此版本") target:self action:@selector(onIgnore:)];
    self.cancelBtn = [NSButton buttonWithTitle:RLPTr(@"取消下载") target:self action:@selector(onCancel:)];
    self.primaryBtn = [NSButton buttonWithTitle:RLPTr(@"立即更新") target:self action:@selector(onPrimary:)];
    for (NSButton *b in @[self.manualBtn, self.laterBtn, self.ignoreBtn, self.cancelBtn, self.primaryBtn]) {
        b.bezelStyle = NSBezelStyleRounded;
        b.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:b];
    }
    self.primaryBtn.keyEquivalent = @"\r";
    self.cancelBtn.hidden = YES;

    [NSLayoutConstraint activateConstraints:@[
        [self.infoView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
        [self.infoView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-20],
        [self.infoView.topAnchor constraintEqualToAnchor:root.topAnchor constant:18],
        [self.infoView.bottomAnchor constraintEqualToAnchor:self.primaryBtn.topAnchor constant:-14],
        [self.titleField.leadingAnchor constraintEqualToAnchor:self.infoView.leadingAnchor],
        [self.titleField.trailingAnchor constraintEqualToAnchor:self.infoView.trailingAnchor],
        [self.titleField.topAnchor constraintEqualToAnchor:self.infoView.topAnchor],
        [notesScroll.leadingAnchor constraintEqualToAnchor:self.infoView.leadingAnchor],
        [notesScroll.trailingAnchor constraintEqualToAnchor:self.infoView.trailingAnchor],
        [notesScroll.topAnchor constraintEqualToAnchor:self.titleField.bottomAnchor constant:10],
        [notesScroll.bottomAnchor constraintEqualToAnchor:self.infoView.bottomAnchor],

        [self.downloadView.leadingAnchor constraintEqualToAnchor:self.infoView.leadingAnchor],
        [self.downloadView.trailingAnchor constraintEqualToAnchor:self.infoView.trailingAnchor],
        [self.downloadView.topAnchor constraintEqualToAnchor:self.infoView.topAnchor],
        [self.downloadView.bottomAnchor constraintEqualToAnchor:self.infoView.bottomAnchor],
        [self.progress.leadingAnchor constraintEqualToAnchor:self.downloadView.leadingAnchor],
        [self.progress.trailingAnchor constraintEqualToAnchor:self.downloadView.trailingAnchor],
        [self.progress.centerYAnchor constraintEqualToAnchor:self.downloadView.centerYAnchor],
        [self.progressText.leadingAnchor constraintEqualToAnchor:self.progress.leadingAnchor],
        [self.progressText.topAnchor constraintEqualToAnchor:self.progress.bottomAnchor constant:10],
        [self.progressText.trailingAnchor constraintEqualToAnchor:self.progress.trailingAnchor],

        [self.primaryBtn.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-20],
        [self.primaryBtn.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-18],
        [self.cancelBtn.trailingAnchor constraintEqualToAnchor:self.primaryBtn.leadingAnchor constant:-8],
        [self.cancelBtn.centerYAnchor constraintEqualToAnchor:self.primaryBtn.centerYAnchor],
        [self.ignoreBtn.trailingAnchor constraintEqualToAnchor:self.cancelBtn.leadingAnchor constant:-8],
        [self.ignoreBtn.centerYAnchor constraintEqualToAnchor:self.primaryBtn.centerYAnchor],
        [self.laterBtn.trailingAnchor constraintEqualToAnchor:self.ignoreBtn.leadingAnchor constant:-8],
        [self.laterBtn.centerYAnchor constraintEqualToAnchor:self.primaryBtn.centerYAnchor],
        [self.manualBtn.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
        [self.manualBtn.centerYAnchor constraintEqualToAnchor:self.primaryBtn.centerYAnchor],
    ]];
}

#pragma mark - 检查

- (void)checkManually:(BOOL)manually {
#ifdef RLP_HAVE_UPDATE
    if (self.checking) return;
    self.checking = YES;
    __weak __typeof__(self) weakSelf = self;
    rta::update::begin_check(
        ^(const rta::update::NativeProgress &p) {
            __typeof__(self) self_ = weakSelf;
            if (!self_) return;
            NSString *detail = [NSString stringWithUTF8String:p.detail.c_str()] ?: @"";
            dispatch_async(dispatch_get_main_queue(), ^{
                self_.progressText.stringValue = detail;
            });
        },
        ^(const rta::update::CheckResult &r) {
            __typeof__(self) self_ = weakSelf;
            if (!self_) return;
            [self_ postCheckResult:r manually:manually];
        });
#else
    (void)manually;
    RLPToast(RLPTr(@"本构建未启用更新模块"));
#endif
}

#ifdef RLP_HAVE_UPDATE
// 判据接缝（供 tests/test_native_update_result_lifetime.mm 调）：
// done 回调收到的 CheckResult 属于**生产者**（begin_check 的内部对象），回调返回即失效。
// 跨线程到主队列必须带一份自己的拷贝 —— 见下方 handleCheckResult 的实现说明。
- (void)postCheckResult:(const rta::update::CheckResult &)r manually:(BOOL)manually {
    // ⚠️ 所有权边界（2026-11-14 实测 SIGBUS 的根因）：
    //   done 回调收到的 r 属于**生产者**（begin_check 内部的对象，回调返回即析构）；
    //   block 捕获 `const T&` 形式的参数是**引用捕获**，不是拷贝 ⟹ 直接
    //   dispatch_async 到主队列，主线程拿到的就是一个悬垂引用，读 notes / downloadUrl
    //   这类会走堆分配的字段就是读已释放内存（偶发 EXC_BAD_ACCESS / SIGBUS）。
    //   所以必须在跳线程**之前**拷一份自己的（shared_ptr 保证生命周期到 block 执行完）。
    std::shared_ptr<rta::update::CheckResult> owned =
        std::make_shared<rta::update::CheckResult>(r);
    __weak __typeof__(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        [self_ handleCheckResult:*owned manually:manually];
    });
}
#endif   // RLP_HAVE_UPDATE（接缝）

#ifdef RLP_HAVE_UPDATE
- (void)handleCheckResult:(const rta::update::CheckResult &)r manually:(BOOL)manually {
    self.checking = NO;
    NSString *version = [NSString stringWithUTF8String:r.remoteVersion.c_str()] ?: @"";
    NSString *notes = [NSString stringWithUTF8String:r.notes.c_str()] ?: @"";
    NSString *url = [NSString stringWithUTF8String:r.downloadUrl.c_str()] ?: @"";

    if (r.up_to_date()) {
        if (manually) RLPToast(RLPTr(@"已是最新版本"));
        return;
    }
    if (!r.available()) {
        // 失败也要如实说：错误原因来自后端/网络层，不是 UI 编的
        NSString *err = [NSString stringWithUTF8String:r.error.c_str()] ?: @"";
        if (manually) {
            RLPToast(err.length ? err : RLPTr(@"检查更新失败"));
            self.hintField.stringValue = err;
            [self showWindow:nil];
        }
        return;
    }
    if ([RLPUpdateWindowController isVersionIgnored:version]) {
        if (manually) RLPToast([NSString stringWithFormat:RLPTr(@"%@ 已被忽略"), version]);
        return;
    }
    self.remoteVersion = version;
    self.manualUrl = url;
#ifdef RLP_HAVE_UPDATE
    auto ptr = std::make_shared<RLPUpdatePlan>();
    ptr->plan = r;
    self.planPtr = ptr;
    self.hasPlan = YES;
#endif
    self.titleField.stringValue = [NSString stringWithFormat:RLPTr(@"发现新版本 %@"), version];
    self.notesView.string = notes;
    self.infoView.hidden = NO;
    self.downloadView.hidden = YES;
    self.cancelBtn.hidden = YES;
    self.primaryBtn.title = RLPTr(@"立即更新");
    self.primaryBtn.enabled = YES;
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
}
#endif

#pragma mark - 出口

- (void)onPrimary:(id)sender {
#ifdef RLP_HAVE_UPDATE
    if (!self.remoteVersion.length) return;
    if (!self.planPtr) {
        RLPToast(RLPTr(@"更新计划已失效，请重新检查"));
        return;
    }
    [self switchToDownloadState];
    __weak __typeof__(self) weakSelf = self;
    const rta::update::CheckResult plan = self.planPtr->plan;
    const rta::update::CancelToken token = self.planPtr->cancel;
    rta::update::begin_install(plan,
        ^(const rta::update::NativeProgress &p) {
            __typeof__(self) self_ = weakSelf;
            if (!self_) return;
            // 与 1.1.7.38 的 CheckResult SIGBUS 同源：block 捕获 `const T&` 是**引用捕获**，
            // 回调返回后生产者的 p 即析构，主线程再读 p.percent / p.detail.c_str() 是悬垂。
            // 必须在跳线程前把标量与 NSString 拷出来（同 checkManually 的进度回调口径）。
            const double pct = p.percent;
            NSString *detail = [NSString stringWithUTF8String:p.detail.c_str()] ?: @"";
            dispatch_async(dispatch_get_main_queue(), ^{
                self_.progress.doubleValue = pct >= 0 ? pct : 0;
                self_.progressText.stringValue = detail.length ? detail : RLPTr(@"正在安装…");
            });
        },
        ^(bool ok, NSString *msg) {
            __typeof__(self) self_ = weakSelf;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self_) return;
                if (ok) {
                    self_.primaryBtn.title = RLPTr(@"重启");
                    self_.primaryBtn.enabled = YES;
                    self_.primaryBtn.target = self_;
                    self_.primaryBtn.action = @selector(onRelaunch:);
                    self_.progressText.stringValue = msg.length ? msg : RLPTr(@"更新已安装");
                } else {
                    self_.progressText.stringValue = msg.length ? msg : RLPTr(@"更新失败");
                    [self_ switchToInfoState];
                    RLPAlert(RLPTr(@"更新失败"), msg.length ? msg : RLPTr(@"请稍后重试，或用「手动下载」安装。"));
                }
            });
        },
        token);
#else
    (void)sender;
    RLPToast(RLPTr(@"本构建未启用更新模块"));
#endif
}

- (void)switchToDownloadState {
    self.infoView.hidden = YES;
    self.downloadView.hidden = NO;
    self.cancelBtn.hidden = NO;
    self.manualBtn.hidden = YES;
    self.ignoreBtn.hidden = YES;
    self.laterBtn.hidden = YES;
    self.primaryBtn.enabled = NO;
    self.progress.doubleValue = 0;
    self.progressText.stringValue = RLPTr(@"准备下载…");
}

- (void)switchToInfoState {
    self.infoView.hidden = NO;
    self.downloadView.hidden = YES;
    self.cancelBtn.hidden = YES;
    self.manualBtn.hidden = NO;
    self.ignoreBtn.hidden = NO;
    self.laterBtn.hidden = NO;
    self.primaryBtn.enabled = YES;
    self.primaryBtn.title = RLPTr(@"立即更新");
}

- (void)onLater:(id)sender {
    [self.window close];
}

- (void)onIgnore:(id)sender {
    if (self.remoteVersion.length) {
        [[NSUserDefaults standardUserDefaults] setObject:self.remoteVersion forKey:kIgnoredVersionKey];
        RLPToast([NSString stringWithFormat:RLPTr(@"已忽略 %@"), self.remoteVersion]);
    }
    [self.window close];
}

- (void)onManual:(id)sender {
    if (self.manualUrl.length) {
        NSURL *u = [NSURL URLWithString:self.manualUrl];
        if (u) [[NSWorkspace sharedWorkspace] openURL:u];
    } else {
        RLPToast(RLPTr(@"清单未提供下载地址"));
    }
}

- (void)onCancel:(id)sender {
#ifdef RLP_HAVE_UPDATE
    if (self.planPtr) self.planPtr->cancel.cancel();
#endif
    self.progressText.stringValue = RLPTr(@"已取消下载");
    [self switchToInfoState];
}

- (void)onRelaunch:(id)sender {
    // 安装脚本已在等待本进程退出；这里正常退出即可（绝不 force-kill 自己）
    [NSApp terminate:nil];
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.window.backgroundColor = t.bg;
    self.window.contentView.layer.backgroundColor = t.bg.CGColor;
    self.titleField.textColor = t.text;
    self.notesView.textColor = t.text;
    self.progressText.textColor = t.mut;
}

@end