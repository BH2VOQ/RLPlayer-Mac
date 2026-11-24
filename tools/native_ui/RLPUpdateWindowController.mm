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

typedef NS_ENUM(NSInteger, RLPUpdateDisplayState) {
    RLPUpdateDisplayIdle = 0,
    RLPUpdateDisplayChecking,
    RLPUpdateDisplayUpToDate,
    RLPUpdateDisplayError,
    RLPUpdateDisplayIgnored,
    RLPUpdateDisplayAvailable,
    RLPUpdateDisplayInstalled,
};

#ifdef RLP_HAVE_UPDATE
// 安装计划 + 它的取消令牌必须**同生共死**：CancelToken 是 shared_ptr<atomic<bool>>，
// 复制出来的是同一个标志（见 mac_update.h 的说明）。存成堆对象是为了让 ObjC 属性
// 能持有 C++ 类型，同时保证"取消"点到的确实是本次下载用的那个 token。
struct RLPUpdatePlan {
    rta::update::CheckResult plan;
    rta::update::CancelToken cancel;
};
#endif

@interface RLPUpdateWindowController () <NSWindowDelegate>
@property (nonatomic, strong) NSView *infoView;
@property (nonatomic, strong) NSView *downloadView;
@property (nonatomic, strong) NSTextField *titleField;
@property (nonatomic, strong) NSTextView *notesView;
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
@property (nonatomic) BOOL installing;
@property (nonatomic) BOOL cancelling;
@property (nonatomic) BOOL installStageLocked;
@property (nonatomic) BOOL cancelAttempted;
@property (nonatomic) BOOL installed;
@property (nonatomic) BOOL autoRestartScheduled;
@property (nonatomic) BOOL terminationConfirmed;
@property (nonatomic) NSUInteger installSeq;
/// 检查阶段拿到的安装计划：下载/校验/安装全靠它（URL/sha256/size 都由清单给出，
/// UI 不自己拼 URL——那是安全边界）。没有它就不允许点「立即更新」。
@property (nonatomic) BOOL hasPlan;
@property (nonatomic) RLPUpdateDisplayState displayState;
@property (nonatomic, copy) NSString *ignoredVersionDisplay;
@property (nonatomic) BOOL errorNotesUsesFallback;
@property (nonatomic) BOOL installedNotesUsesFallback;
#ifdef RLP_HAVE_UPDATE
@property (nonatomic) std::shared_ptr<RLPUpdatePlan> planPtr;
@property (nonatomic, copy) void (^testInstallRunner)(const rta::update::CheckResult &plan,
                                                rta::update::ProgressFn progress,
                                                rta::update::InstallOutcomeFn done,
                                                rta::update::CancelToken cancel);
#endif
@property (nonatomic, copy) void (^testAlertHandler)(NSString *title, NSString *message);
@property (nonatomic, copy) BOOL (^testConfirmHandler)(NSString *title, NSString *message);
@property (nonatomic, copy) void (^testToastHandler)(NSString *message);
@property (nonatomic, copy) void (^testTerminateHandler)(void);
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
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 380)
                                                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    win.title = RLPTr(@"软件更新");
    win.minSize = NSMakeSize(540, 340);
    win.backgroundColor = t.bg;
    win.appearance = [NSAppearance appearanceNamed:(t.isLight ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua)];
    win.releasedWhenClosed = NO;
    [win center];
    self = [super initWithWindow:win];
    if (!self) return nil;
    win.delegate = self;
    [self buildUI];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyLanguage)
                                                 name:RLPLanguageDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyTheme)
                                                 name:RLPThemeDidChangeNotification
                                               object:nil];
    return self;
}

- (void)showWindow:(id)sender {
    [self applyTheme];
    [super showWindow:sender];
}

- (void)dealloc {
    if (self.isWindowLoaded) self.window.delegate = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)refreshLocalizedStateText {
    switch (self.displayState) {
        case RLPUpdateDisplayIdle:
            break;
        case RLPUpdateDisplayChecking:
            self.titleField.stringValue = RLPTr(@"正在检查…");
            break;
        case RLPUpdateDisplayUpToDate:
            self.titleField.stringValue = RLPTr(@"已是最新版本");
            break;
        case RLPUpdateDisplayError:
            self.titleField.stringValue = RLPTr(@"检查更新失败");
            if (self.errorNotesUsesFallback) {
                self.notesView.string = RLPTr(@"检查更新失败");
            }
            break;
        case RLPUpdateDisplayIgnored:
            if (self.ignoredVersionDisplay.length) {
                self.titleField.stringValue = [NSString stringWithFormat:RLPTr(@"%@ 已被忽略"), self.ignoredVersionDisplay];
            }
            break;
        case RLPUpdateDisplayAvailable:
            if (self.remoteVersion.length) {
                self.titleField.stringValue = [NSString stringWithFormat:RLPTr(@"发现新版本 %@"), self.remoteVersion];
            }
            break;
        case RLPUpdateDisplayInstalled:
            self.titleField.stringValue = RLPTr(@"更新已安装");
            if (self.installedNotesUsesFallback) {
                self.notesView.string = RLPTr(@"更新已安装");
            }
            break;
    }
    if (self.installing) {
        if (self.installStageLocked) {
            if (self.cancelAttempted) {
                self.progressText.stringValue = RLPTr(@"安装已开始，无法取消");
            }
        } else if (self.cancelling) {
            self.progressText.stringValue = RLPTr(@"已请求取消");
        } else if (self.progress.doubleValue <= 0.0) {
            self.progressText.stringValue = RLPTr(@"准备下载…");
        }
    }
}

- (void)applyLanguage {
    if (!self.isWindowLoaded) return;
    self.window.title = RLPTr(@"软件更新");
    self.manualBtn.title = RLPTr(@"手动下载");
    self.laterBtn.title = RLPTr(@"稍后");
    self.ignoreBtn.title = RLPTr(@"忽略此版本");
    self.cancelBtn.title = RLPTr(@"取消下载");
    if (self.installed) {
        self.primaryBtn.title = self.autoRestartScheduled ? RLPTr(@"重启") : RLPTr(@"退出 RLPlayer");
    } else {
        self.primaryBtn.title = RLPTr(@"立即更新");
    }
    [self refreshLocalizedStateText];
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
    self.primaryBtn.enabled = NO;
    self.ignoreBtn.enabled = NO;
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
        [self.ignoreBtn.trailingAnchor constraintEqualToAnchor:self.primaryBtn.leadingAnchor constant:-8],
        [self.ignoreBtn.centerYAnchor constraintEqualToAnchor:self.primaryBtn.centerYAnchor],
        [self.laterBtn.trailingAnchor constraintEqualToAnchor:self.ignoreBtn.leadingAnchor constant:-8],
        [self.laterBtn.centerYAnchor constraintEqualToAnchor:self.primaryBtn.centerYAnchor],
        [self.manualBtn.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
        [self.manualBtn.trailingAnchor constraintLessThanOrEqualToAnchor:self.laterBtn.leadingAnchor constant:-8],
        [self.manualBtn.centerYAnchor constraintEqualToAnchor:self.primaryBtn.centerYAnchor],
    ]];
}

- (void)showToastMessage:(NSString *)msg {
    if (!msg.length) return;
    if (self.testToastHandler) {
        self.testToastHandler(msg);
        return;
    }
    RLPToast(msg);
}

- (void)showAlertTitle:(NSString *)title message:(NSString *)message {
    if (self.testAlertHandler) {
        self.testAlertHandler(title ?: @"", message ?: @"");
        return;
    }
    RLPAlert(title, message);
}

- (BOOL)confirmStopInstallWithTitle:(NSString *)title
                            message:(NSString *)message
                      confirmButton:(NSString *)confirmButton {
    if (self.testConfirmHandler) {
        return self.testConfirmHandler(title ?: @"", message ?: @"");
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = title ?: @"";
    alert.informativeText = message ?: @"";
    // 默认放「继续安装」防止误按 Return 中断安装，第二按钮为确认操作。
    [alert addButtonWithTitle:RLPTr(@"继续安装")];
    [alert addButtonWithTitle:confirmButton.length ? confirmButton : RLPTr(@"仍要退出")];
    return [alert runModal] == NSAlertSecondButtonReturn;
}

- (void)triggerAppTerminate {
    if (self.testTerminateHandler) {
        self.testTerminateHandler();
        return;
    }
    [NSApp terminate:nil];
}

- (void)clearTestHooks {
#ifdef RLP_HAVE_UPDATE
    self.testInstallRunner = nil;
#endif
    self.testAlertHandler = nil;
    self.testConfirmHandler = nil;
    self.testToastHandler = nil;
    self.testTerminateHandler = nil;
}

- (void)resetForTesting {
    ++self.installSeq;
    self.checking = NO;
    self.installing = NO;
    self.cancelling = NO;
    self.installStageLocked = NO;
    self.cancelAttempted = NO;
    self.installed = NO;
    self.autoRestartScheduled = NO;
    self.terminationConfirmed = NO;
    [self invalidatePlan];
    self.displayState = RLPUpdateDisplayIdle;
    self.ignoredVersionDisplay = nil;
    self.errorNotesUsesFallback = NO;
    self.installedNotesUsesFallback = NO;
    self.titleField.stringValue = @"";
    self.notesView.string = @"";
    [self switchToInfoState];
}

#pragma mark - 检查

- (void)invalidatePlan {
    self.hasPlan = NO;
    self.remoteVersion = nil;
    self.manualUrl = nil;
#ifdef RLP_HAVE_UPDATE
    self.planPtr.reset();
#endif
    if (!self.installed) {
        self.primaryBtn.title = RLPTr(@"立即更新");
        self.primaryBtn.target = self;
        self.primaryBtn.action = @selector(onPrimary:);
        self.primaryBtn.enabled = NO;
        self.ignoreBtn.enabled = NO;
    }
}

- (BOOL)canInstallPlan {
#ifdef RLP_HAVE_UPDATE
    if (self.checking || self.installing || self.cancelling || self.installed) return NO;
    if (!self.hasPlan || !self.planPtr) return NO;
    if (!self.remoteVersion.length) return NO;
    if (!self.planPtr->plan.available()) return NO;
    if (!rta::update::update_download_url_allowed(self.planPtr->plan.downloadUrl)) return NO;
    if (!rta::update::is_hex64(self.planPtr->plan.sha256)) return NO;
    if ([RLPUpdateWindowController isVersionIgnored:self.remoteVersion]) return NO;
    return YES;
#else
    return NO;
#endif
}

- (void)checkManually:(BOOL)manually {
#ifdef RLP_HAVE_UPDATE
    if (self.checking) {
        if (manually) [self showToastMessage:RLPTr(@"正在检查…")];
        return;
    }
    if (self.installing || self.cancelling) {
        if (manually) {
            NSString *busyMsg = (self.cancelling && !self.installStageLocked)
                ? RLPTr(@"已请求取消")
                : RLPTr(@"正在更新…");
            [self showToastMessage:busyMsg];
            [self showWindow:nil];
            [self.window makeKeyAndOrderFront:nil];
        }
        return;
    }
    if (self.installed) {
        if (manually) {
            [self switchToInfoState];
            [self showToastMessage:RLPTr(@"更新已安装")];
            [self showWindow:nil];
            [self.window makeKeyAndOrderFront:nil];
        }
        return;
    }
    // 重新检查即禁用旧计划，防止在途检查期间或后续失败时误装陈旧版本。
    [self invalidatePlan];
    self.displayState = RLPUpdateDisplayChecking;
    self.ignoredVersionDisplay = nil;
    self.errorNotesUsesFallback = NO;
    self.installedNotesUsesFallback = NO;
    self.titleField.stringValue = RLPTr(@"正在检查…");
    self.notesView.string = @"";
    self.checking = YES;
    [self switchToInfoState];
    __weak __typeof__(self) weakSelf = self;
    rta::update::begin_check(
        ^(const rta::update::NativeProgress &p) {
            __typeof__(self) self_ = weakSelf;
            if (!self_) return;
            NSString *detail = [NSString stringWithUTF8String:p.detail.c_str()] ?: @"";
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self_.checking || self_.installing || self_.cancelling || self_.installed) return;
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
    [self invalidatePlan];
    [self showToastMessage:RLPTr(@"本构建未启用更新模块")];
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
    // 互斥：安装进行中或等待取消终态/待重启期间，不覆盖当前计划与下载态。
    if (self.installing || self.cancelling || self.installed) {
        return;
    }
    NSString *version = [NSString stringWithUTF8String:r.remoteVersion.c_str()] ?: @"";
    NSString *notes = [NSString stringWithUTF8String:r.notes.c_str()] ?: @"";
    NSString *url = [NSString stringWithUTF8String:r.downloadUrl.c_str()] ?: @"";

    if (r.up_to_date()) {
        [self invalidatePlan];
        self.displayState = RLPUpdateDisplayUpToDate;
        self.errorNotesUsesFallback = NO;
        self.installedNotesUsesFallback = NO;
        self.titleField.stringValue = RLPTr(@"已是最新版本");
        self.notesView.string = @"";
        [self switchToInfoState];
        if (manually) RLPToast(RLPTr(@"已是最新版本"));
        return;
    }
    if (!r.available()) {
        // 失败也要如实说：错误原因来自后端/网络层，不是 UI 编的
        [self invalidatePlan];
        NSString *err = [NSString stringWithUTF8String:r.error.c_str()] ?: @"";
        NSString *shownErr = err.length ? err : RLPTr(@"检查更新失败");
        self.displayState = RLPUpdateDisplayError;
        self.errorNotesUsesFallback = (err.length == 0);
        self.installedNotesUsesFallback = NO;
        self.titleField.stringValue = RLPTr(@"检查更新失败");
        self.notesView.string = shownErr;
        [self switchToInfoState];
        if (manually) {
            RLPToast(shownErr);
            [self showWindow:nil];
        }
        return;
    }
    if (!version.length) {
        [self invalidatePlan];
        self.displayState = RLPUpdateDisplayError;
        self.errorNotesUsesFallback = YES;
        self.installedNotesUsesFallback = NO;
        self.titleField.stringValue = RLPTr(@"检查更新失败");
        self.notesView.string = RLPTr(@"检查更新失败");
        [self switchToInfoState];
        if (manually) {
            RLPToast(RLPTr(@"检查更新失败"));
            [self showWindow:nil];
        }
        return;
    }
    if ([RLPUpdateWindowController isVersionIgnored:version]) {
        [self invalidatePlan];
        self.displayState = RLPUpdateDisplayIgnored;
        self.ignoredVersionDisplay = version;
        self.errorNotesUsesFallback = NO;
        self.installedNotesUsesFallback = NO;
        self.titleField.stringValue = [NSString stringWithFormat:RLPTr(@"%@ 已被忽略"), version];
        self.notesView.string = @"";
        [self switchToInfoState];
        if (manually) RLPToast([NSString stringWithFormat:RLPTr(@"%@ 已被忽略"), version]);
        return;
    }
    self.remoteVersion = version;
    self.manualUrl = url;
    auto ptr = std::make_shared<RLPUpdatePlan>();
    ptr->plan = r;
    self.planPtr = ptr;
    self.hasPlan = YES;
    self.displayState = RLPUpdateDisplayAvailable;
    self.ignoredVersionDisplay = nil;
    self.errorNotesUsesFallback = NO;
    self.installedNotesUsesFallback = NO;
    self.titleField.stringValue = [NSString stringWithFormat:RLPTr(@"发现新版本 %@"), version];
    self.notesView.string = notes;
    [self switchToInfoState];
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
}
#endif

#pragma mark - 出口

- (void)onPrimary:(id)sender {
    (void)sender;
#ifdef RLP_HAVE_UPDATE
    if (self.checking) {
        [self showToastMessage:RLPTr(@"正在检查…")];
        return;
    }
    if (self.installing || self.cancelling) {
        NSString *busyMsg = (self.cancelling && !self.installStageLocked)
            ? RLPTr(@"已请求取消")
            : RLPTr(@"正在更新…");
        [self showToastMessage:busyMsg];
        return;
    }
    if (self.installed) return;
    if (![self canInstallPlan]) {
        [self invalidatePlan];
        [self showToastMessage:RLPTr(@"更新计划已失效，请重新检查")];
        return;
    }
    self.installing = YES;
    self.cancelling = NO;
    self.installStageLocked = NO;
    self.cancelAttempted = NO;
    self.terminationConfirmed = NO;
    self.autoRestartScheduled = NO;
    const NSUInteger seq = ++self.installSeq;
    rta::update::CancelToken token;
    self.planPtr->cancel = token;
    const rta::update::CheckResult plan = self.planPtr->plan;
    [self switchToDownloadState];
    __weak __typeof__(self) weakSelf = self;

    rta::update::ProgressFn progressBlock = ^(const rta::update::NativeProgress &p) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        // 与 1.1.7.38 的 CheckResult SIGBUS 同源：block 捕获 `const T&` 是**引用捕获**，
        // 回调返回后生产者的 p 即析构，主线程再读 p.percent / p.stage / p.detail.c_str() 是悬垂。
        // 必须在跳线程前把标量与 NSString 拷出来（同 checkManually 的进度回调口径）。
        const double pct = p.percent;
        NSString *stage = [NSString stringWithUTF8String:p.stage.c_str()] ?: @"";
        NSString *detail = [NSString stringWithUTF8String:p.detail.c_str()] ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self_.installing || self_.installSeq != seq) return;
            const BOOL enteredApplyStage =
                [stage isEqualToString:@"mounting"] ||
                [stage isEqualToString:@"installing"] ||
                [stage isEqualToString:@"done"];
            if (enteredApplyStage) {
                self_.installStageLocked = YES;
                self_.cancelling = NO;
                self_.cancelBtn.enabled = NO;
            }
            if (pct >= 0) self_.progress.doubleValue = pct;
            if (self_.installStageLocked) {
                if (self_.cancelAttempted || token.cancelled()) {
                    self_.progressText.stringValue = RLPTr(@"安装已开始，无法取消");
                } else {
                    self_.progressText.stringValue = detail.length ? detail : RLPTr(@"正在安装…");
                }
            } else if (!self_.cancelling && !token.cancelled()) {
                self_.progressText.stringValue = detail.length ? detail : RLPTr(@"正在安装…");
            }
        });
    };

    rta::update::InstallOutcomeFn doneBlock = ^(const rta::update::InstallOutcome &outcome) {
        __typeof__(self) self_ = weakSelf;
        // 在跳线程前按值拷出，避免 const 引用在异步执行时悬垂。
        const rta::update::InstallOutcome outCopy = outcome;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self_ || self_.installSeq != seq) return;
            const BOOL backendCancelled =
                (outCopy.code == rta::update::InstallResultCode::Cancelled) || outCopy.cancelled;
            self_.installing = NO;
            self_.cancelling = NO;
            self_.installStageLocked = NO;
            self_.cancelAttempted = NO;
            NSString *msg = [NSString stringWithUTF8String:outCopy.message.c_str()] ?: @"";

            if (outCopy.ok && !backendCancelled) {
                // U3：只读后端稳定结果码/枚举，绝不靠中文子串 @"正在自动重启" 判断。
                const BOOL autoRestartScheduled =
                    (outCopy.code == rta::update::InstallResultCode::InstalledAutoRestart) ||
                    (outCopy.code != rta::update::InstallResultCode::InstalledManualRestart &&
                     outCopy.autoRestartScheduled);
                self_.installed = YES;
                self_.autoRestartScheduled = autoRestartScheduled;
                [self_ invalidatePlan];
                NSString *statusMsg = msg.length ? msg : RLPTr(@"更新已安装");
                self_.displayState = RLPUpdateDisplayInstalled;
                self_.errorNotesUsesFallback = NO;
                self_.installedNotesUsesFallback = (msg.length == 0);
                self_.titleField.stringValue = RLPTr(@"更新已安装");
                self_.notesView.string = statusMsg;
                [self_ switchToInfoState];
            } else if (backendCancelled) {
                // U1：只有后端明确 Cancelled 才按取消提示；绝不用本地 cancelling 吞掉真实安装失败。
                self_.installed = NO;
                if (self_.planPtr) self_.planPtr->cancel = rta::update::CancelToken();
                [self_ switchToInfoState];
                [self_ showToastMessage:RLPTr(@"已取消下载")];
            } else {
                self_.installed = NO;
                if (self_.planPtr) self_.planPtr->cancel = rta::update::CancelToken();
                [self_ switchToInfoState];
                [self_ showAlertTitle:RLPTr(@"更新失败")
                              message:msg.length ? msg : RLPTr(@"请稍后重试，或用「手动下载」安装。")];
            }
        });
    };

    if (self.testInstallRunner) {
        self.testInstallRunner(plan, progressBlock, doneBlock, token);
    } else {
        rta::update::begin_install_outcome(plan, progressBlock, doneBlock, token);
    }
#else
    (void)sender;
    [self showToastMessage:RLPTr(@"本构建未启用更新模块")];
#endif
}

- (void)switchToDownloadState {
    self.infoView.hidden = YES;
    self.downloadView.hidden = NO;
    self.cancelBtn.hidden = NO;
    self.cancelBtn.enabled = YES;
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
    self.progress.doubleValue = 0;
    self.progressText.stringValue = @"";
    self.cancelBtn.hidden = YES;
    self.cancelBtn.enabled = YES;
    self.manualBtn.hidden = NO;
    self.ignoreBtn.hidden = NO;
    self.laterBtn.hidden = NO;
    self.manualBtn.enabled = !self.installed;
    self.ignoreBtn.enabled = (self.remoteVersion.length > 0 && !self.checking && !self.installing && !self.cancelling && !self.installed);
    if (self.installed) {
        if (self.autoRestartScheduled) {
            self.primaryBtn.title = RLPTr(@"重启");
            self.primaryBtn.target = self;
            self.primaryBtn.action = @selector(onRelaunch:);
        } else {
            self.primaryBtn.title = RLPTr(@"退出 RLPlayer");
            self.primaryBtn.target = self;
            self.primaryBtn.action = @selector(onQuit:);
        }
        self.primaryBtn.enabled = YES;
    } else {
        self.primaryBtn.title = RLPTr(@"立即更新");
        self.primaryBtn.target = self;
        self.primaryBtn.action = @selector(onPrimary:);
        self.primaryBtn.enabled = [self canInstallPlan];
    }
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    (void)sender;
    if (self.terminationConfirmed) return YES;
    if (!self.installing && !self.cancelling) return YES;

    NSString *title = RLPTr(@"正在安装");
    NSString *msg = RLPTr(@"正在安装，退出可能留下未完成更新/需要手动重启");
    if (![self confirmStopInstallWithTitle:title
                                   message:msg
                             confirmButton:RLPTr(@"仍要关闭")]) {
        return NO;
    }

    const BOOL locked = self.installStageLocked;
    self.installed = NO;
    self.autoRestartScheduled = NO;
    self.installing = NO;
    self.cancelling = NO;
    self.installStageLocked = NO;
    self.cancelAttempted = NO;
    ++self.installSeq;
#ifdef RLP_HAVE_UPDATE
    if (!locked && self.planPtr) {
        self.planPtr->cancel.cancel();
    }
#else
    (void)locked;
#endif
    return YES;
}

- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    if (!self.installing && !self.cancelling) {
        [self switchToInfoState];
    }
}

- (void)onLater:(id)sender {
    (void)sender;
    if ((self.installing || self.cancelling) && ![self windowShouldClose:self.window]) {
        return;
    }
    [self.window close];
}

- (void)onIgnore:(id)sender {
    (void)sender;
    if (self.checking || self.installing || self.cancelling || self.installed) return;
    if (self.remoteVersion.length) {
        NSString *ignoredVer = [self.remoteVersion copy];
        [[NSUserDefaults standardUserDefaults] setObject:ignoredVer forKey:kIgnoredVersionKey];
        [self showToastMessage:[NSString stringWithFormat:RLPTr(@"已忽略 %@"), ignoredVer]];
    }
    [self invalidatePlan];
    self.displayState = RLPUpdateDisplayIdle;
    self.ignoredVersionDisplay = nil;
    self.errorNotesUsesFallback = NO;
    self.installedNotesUsesFallback = NO;
    self.titleField.stringValue = @"";
    self.notesView.string = @"";
    [self.window close];
}

- (void)onManual:(id)sender {
    (void)sender;
    if (self.checking || self.installing || self.cancelling || self.installed) return;
    if (self.manualUrl.length) {
        NSURL *u = [NSURL URLWithString:self.manualUrl];
        if (u) [[NSWorkspace sharedWorkspace] openURL:u];
    } else {
        [self showToastMessage:RLPTr(@"清单未提供下载地址")];
    }
}

- (void)onCancel:(id)sender {
    (void)sender;
#ifdef RLP_HAVE_UPDATE
    if (!self.installing) return;
    self.cancelAttempted = YES;
    if (self.installStageLocked) {
        // U1：安装阶段（mount/替换）已开始，不再宣称"已取消"或置 cancelling
        self.cancelling = NO;
        self.cancelBtn.enabled = NO;
        self.progressText.stringValue = RLPTr(@"安装已开始，无法取消");
        return;
    }
    if (self.cancelling) return;
    self.cancelling = YES;
    self.cancelBtn.enabled = NO;
    self.primaryBtn.enabled = NO;
    if (self.planPtr) self.planPtr->cancel.cancel();
    self.progressText.stringValue = RLPTr(@"已请求取消");
#endif
}

- (void)onRelaunch:(id)sender {
    (void)sender;
    if (self.installing || !self.installed) return;
    if (!self.autoRestartScheduled) {
        // 未能确认重启脚本已在等待时，绝不静默退出假装"重启成功"。
        [self showAlertTitle:RLPTr(@"更新已安装")
                      message:RLPTr(@"已更新，请手动重启应用以完成")];
        [self switchToInfoState];
        return;
    }
    // 安装脚本已在等待本进程退出；这里正常退出即可（绝不 force-kill 自己）
    [self triggerAppTerminate];
}

- (void)onQuit:(id)sender {
    (void)sender;
    if (self.installing || self.cancelling) {
        NSString *title = RLPTr(@"正在安装");
        NSString *msg = RLPTr(@"正在安装，退出可能留下未完成更新/需要手动重启");
        if (![self confirmStopInstallWithTitle:title
                                       message:msg
                                 confirmButton:RLPTr(@"仍要退出")]) {
            return;
        }
        const BOOL locked = self.installStageLocked;
        self.installed = NO;
        self.autoRestartScheduled = NO;
        self.installing = NO;
        self.cancelling = NO;
        self.installStageLocked = NO;
        self.cancelAttempted = NO;
        ++self.installSeq;
#ifdef RLP_HAVE_UPDATE
        if (!locked && self.planPtr) {
            self.planPtr->cancel.cancel();
        }
#else
        (void)locked;
#endif
        self.terminationConfirmed = YES;
        [self triggerAppTerminate];
        return;
    }
    [self triggerAppTerminate];
}

- (void)applyTheme {
    if (!self.isWindowLoaded) return;
    RLPTheme *t = [RLPTheme current];
    self.window.appearance = [NSAppearance appearanceNamed:(t.isLight ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua)];
    self.window.backgroundColor = t.bg;
    if (self.window.contentView) {
        self.window.contentView.wantsLayer = YES;
        self.window.contentView.layer.backgroundColor = t.bg.CGColor;
    }
    self.titleField.textColor = t.text;
    self.notesView.font = t.body;
    self.notesView.textColor = t.text;
    self.notesView.insertionPointColor = t.accent;
    self.progressText.textColor = t.mut;
}

@end