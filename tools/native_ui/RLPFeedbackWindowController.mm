// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPFeedbackWindowController.mm — 反馈窗口（原生）
//
// 为什么复用 src/net/feedback_api.h 而不在这里重写：
//   清洗/上限/幂等键/脱敏/成功判定都在那一层，且有离线单测。
//   特别是「成功只看 body.ok」——后台 200 也用于幂等重放，业务失败可能带 200。
//   UI 自己判 HTTP 200 就会把失败报成成功。
//
// 诊断包来源：/api/diagjson（与导出/上传同一份组装逻辑，已脱敏）。
// 绝不自己拼一份"现场"，否则会出现"导出的没问题、上传的漏了脱敏"。
#import "RLPFeedbackWindowController.h"
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

#include "net/feedback_api.h"
#include "net/install_id.h"
#include "net/http_client.h"
#include "version.h"

#include <chrono>
#include <random>

@interface RLPFeedbackWindowController ()
@property (nonatomic, strong) NSScrollView *bodyScroll;
@property (nonatomic, strong) NSTextView *body;
@property (nonatomic, strong) NSSwitch *attachDiag;
@property (nonatomic, strong) NSButton *submit;
@property (nonatomic, strong) NSTextField *hintLabel;
@property (nonatomic, strong) NSTextField *diagLabel;
@property (nonatomic, strong) NSTextField *status;
@property (nonatomic, assign) BOOL sending;
@end

@implementation RLPFeedbackWindowController

+ (instancetype)shared {
    static RLPFeedbackWindowController *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[RLPFeedbackWindowController alloc] init]; });
    return s;
}

- (instancetype)init {
    RLPTheme *t = [RLPTheme current];
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 460)
                                            styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                              backing:NSBackingStoreBuffered defer:NO];
    w.title = RLPTr(@"反馈");
    w.backgroundColor = t.bg;
    w.releasedWhenClosed = NO;
    [w center];
    self = [super initWithWindow:w];
    if (self) {
        [self build];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applyLanguage)
                                                     name:RLPLanguageDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applyTheme)
                                                     name:RLPThemeDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    NSWindow *w = self.window;
    if (w) {
        NSAppearanceName appName = !t.isLight ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua;
        w.appearance = [NSAppearance appearanceNamed:appName];
        w.backgroundColor = t.bg;
        NSView *root = w.contentView;
        if (root) {
            root.wantsLayer = YES;
            root.layer.backgroundColor = t.bg.CGColor;
        }
    }
    self.hintLabel.textColor = t.mut;
    self.bodyScroll.drawsBackground = YES;
    self.bodyScroll.backgroundColor = t.bg2;
    self.body.font = t.body;
    self.body.textColor = t.text;
    self.body.backgroundColor = t.bg2;
    self.body.insertionPointColor = t.accent;
    self.diagLabel.textColor = t.text;
    self.status.textColor = t.mut;
}

- (void)applyLanguage {
    self.window.title = RLPTr(@"反馈");
    self.hintLabel.stringValue = RLPTr(@"描述你遇到的问题：做了什么、期望什么、实际发生了什么。可附诊断包（已脱敏）。");
    self.diagLabel.stringValue = RLPTr(@"附诊断包（版本/系统/日志，已脱敏）");
    self.submit.title = RLPTr(@"提交反馈");
}

- (void)build {
    RLPTheme *t = [RLPTheme current];
    NSView *root = self.window.contentView;
    root.wantsLayer = YES;
    root.layer.backgroundColor = t.bg.CGColor;

    NSTextField *hint = RLPLabel(
        RLPTr(@"描述你遇到的问题：做了什么、期望什么、实际发生了什么。可附诊断包（已脱敏）。"),
        t.small, t.mut);
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.maximumNumberOfLines = 2;
    hint.lineBreakMode = NSLineBreakByWordWrapping;
    self.hintLabel = hint;
    [root addSubview:hint];

    NSScrollView *sc = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 520, 240)];
    sc.hasVerticalScroller = YES;
    sc.drawsBackground = YES;
    sc.backgroundColor = t.bg2;
    sc.borderType = NSBezelBorder;
    sc.translatesAutoresizingMaskIntoConstraints = NO;
    self.bodyScroll = sc;
    self.body = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 520, 240)];
    self.body.minSize = NSMakeSize(0.0, 240.0);
    self.body.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    self.body.verticallyResizable = YES;
    self.body.horizontallyResizable = NO;
    self.body.autoresizingMask = NSViewWidthSizable;
    self.body.richText = NO;
    self.body.font = t.body;
    self.body.textColor = t.text;
    self.body.backgroundColor = t.bg2;
    self.body.automaticQuoteSubstitutionEnabled = NO;
    self.body.textContainer.containerSize = NSMakeSize(520.0, CGFLOAT_MAX);
    self.body.textContainer.widthTracksTextView = YES;
    sc.documentView = self.body;
    [root addSubview:sc];

    self.attachDiag = [[NSSwitch alloc] initWithFrame:NSZeroRect];
    self.attachDiag.state = NSControlStateValueOn;
    self.attachDiag.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *diagLabel = RLPLabel(RLPTr(@"附诊断包（版本/系统/日志，已脱敏）"), t.small, t.text);
    diagLabel.translatesAutoresizingMaskIntoConstraints = NO;
    diagLabel.maximumNumberOfLines = 2;
    diagLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [diagLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                        forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.diagLabel = diagLabel;
    [root addSubview:self.attachDiag];
    [root addSubview:diagLabel];

    self.submit = [NSButton buttonWithTitle:RLPTr(@"提交反馈") target:self action:@selector(onSubmit:)];
    self.submit.bezelStyle = NSBezelStyleRounded;
    self.submit.keyEquivalent = @"\r";
    self.submit.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:self.submit];

    self.status = RLPLabel(@"", t.small, t.mut);
    self.status.translatesAutoresizingMaskIntoConstraints = NO;
    self.status.maximumNumberOfLines = 3;
    self.status.lineBreakMode = NSLineBreakByWordWrapping;
    [root addSubview:self.status];

    [NSLayoutConstraint activateConstraints:@[
        [hint.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
        [hint.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-20],
        [hint.topAnchor constraintEqualToAnchor:root.topAnchor constant:16],
        [sc.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
        [sc.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-20],
        [sc.topAnchor constraintEqualToAnchor:hint.bottomAnchor constant:10],
        [sc.heightAnchor constraintEqualToConstant:240],
        [self.attachDiag.leadingAnchor constraintEqualToAnchor:sc.leadingAnchor],
        [self.attachDiag.topAnchor constraintEqualToAnchor:sc.bottomAnchor constant:12],
        [diagLabel.leadingAnchor constraintEqualToAnchor:self.attachDiag.trailingAnchor constant:8],
        [diagLabel.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-20],
        [diagLabel.centerYAnchor constraintEqualToAnchor:self.attachDiag.centerYAnchor],
        [self.submit.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-20],
        [self.submit.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-16],
        [self.status.leadingAnchor constraintEqualToAnchor:sc.leadingAnchor],
        [self.status.trailingAnchor constraintEqualToAnchor:self.submit.leadingAnchor constant:-12],
        [self.status.centerYAnchor constraintEqualToAnchor:self.submit.centerYAnchor],
    ]];
    [self applyTheme];
}

- (void)showAndFocus {
    [self applyTheme];
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.body];
}

#pragma mark - 安装 ID（与服务端约定的客户端标识）

/// 安装 ID 落在应用支持目录，一次生成后复用（服务端按它做限流/去重）。
/// 读不到就新生成一个；生成用系统随机源，不用时间戳凑。
- (NSString *)installId {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                         NSUserDomainMask, YES) firstObject];
    NSString *path = [[dir stringByAppendingPathComponent:@"RLPlayer"]
                      stringByAppendingPathComponent:@"rlplayer-feedback-client-id"];
    NSString *existing = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (existing.length) {
        NSString *trimmed = [existing stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (rta::feedback::install_id_valid(trimmed.UTF8String ?: "")) return trimmed;
    }
    unsigned char entropy[16];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(entropy), entropy) != errSecSuccess) {
        // 拿不到系统随机源就不伪造 ID（伪造会破坏服务端去重）
        return @"";
    }
    const std::string nid = rta::feedback::install_id_new(entropy);
    NSString *s = [NSString stringWithUTF8String:nid.c_str()] ?: @"";
    if (!s.length) return @"";
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                               withIntermediateDirectories:YES attributes:nil error:nil];
    [s writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return s;
}

#pragma mark - 提交

- (void)onSubmit:(id)sender {
    if (self.sending) return;
    NSString *text = self.body.string ?: @"";
    if (![text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length) {
        self.status.stringValue = RLPTr(@"请先写下遇到的问题");
        return;
    }
    if (![RLPCoreClient shared].started) {
        self.status.stringValue = RLPTr(@"核心未启动");
        return;
    }
    self.sending = YES;
    self.submit.enabled = NO;
    const BOOL wantDiag = self.attachDiag.state == NSControlStateValueOn;
    self.status.stringValue = wantDiag ? RLPTr(@"正在打包诊断…") : RLPTr(@"正在提交…");

    __weak __typeof__(self) weakSelf = self;
    // 诊断包走 /api/diagjson（与导出同一份组装 + 脱敏），不自己拼现场
    [[RLPCoreClient shared] getData:@"/api/diagjson" completion:^(NSData * _Nullable data) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSString *diag = (wantDiag && data.length)
            ? ([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"") : @"";
        if (wantDiag && !diag.length) {
            // 打包失败要如实说，但仍允许只发正文（用户可能只想说句话）
            self_.status.stringValue = RLPTr(@"诊断包读取失败，将只提交正文");
        }
        [self_ uploadText:text diagJson:diag attach:(wantDiag && diag.length > 0)];
    }];
}

/// 真正的上传：在后台队列做网络 IO，回调切主线程。
/// 成功判定**只看 body.ok**（parse_feedback_upload_reply 的语义），不看 HTTP 200。
- (void)uploadText:(NSString *)text diagJson:(NSString *)diag attach:(BOOL)attach {
    NSString *client = [self installId];
    const std::string textCpp = text.UTF8String ?: "";
    const std::string diagCpp = diag.UTF8String ?: "";
    const std::string clientCpp = client.UTF8String ?: "";
    const std::string verCpp = RLPLAYER_VERSION;

    NSProcessInfo *pi = [NSProcessInfo processInfo];
    NSString *osStr = [NSString stringWithFormat:@"macOS %@", pi.operatingSystemVersionString];
    const std::string osCpp = osStr.UTF8String ?: "";

    const long long epoch = (long long)std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    std::random_device rd;
    const std::string idem = rta::feedback::make_feedback_idempotency_key(epoch, (unsigned int)rd());

    rta::feedback::FeedbackUploadInput in;
    in.text = textCpp;
    in.version = verCpp;
    in.os = osCpp;
    in.client = clientCpp;
    in.diag_json = diagCpp;
    in.idempotency_key = idem;
    in.attach_diag = attach;

    const rta::feedback::FeedbackUploadBody built = rta::feedback::build_feedback_upload(in);
    if (!built.ok) {
        NSString *err = [NSString stringWithUTF8String:built.error.c_str()] ?: RLPTr(@"内容不合法");
        self.sending = NO;
        self.submit.enabled = YES;
        self.status.stringValue = err;
        return;
    }

    self.status.stringValue = RLPTr(@"正在上传…");
    const std::string bodyCpp = built.json;
    __weak __typeof__(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        const auto resp = rta::net::http_post(rta::feedback::kFeedbackUploadUrl, bodyCpp, {},
                                             "application/json",
                                             rta::feedback::kFeedbackUploadTimeoutMs);
        // HttpResponse.body 是字节数组（vector<unsigned char>），不是 string：
        // 服务端响应可能含非 UTF8 字节，转成 string 时按原字节保留，交给解析层判定。
        const std::string respBody(resp.body.begin(), resp.body.end());
        const auto reply = rta::feedback::parse_feedback_upload_reply(resp.status, respBody);
        const bool ok = reply.ok;
        NSString *ticket = [NSString stringWithUTF8String:reply.id.c_str()] ?: @"";
        NSString *err = [NSString stringWithUTF8String:reply.error.c_str()] ?: @"";
        const int status = resp.status;
        dispatch_async(dispatch_get_main_queue(), ^{
            __typeof__(self) self_ = weakSelf;
            if (!self_) return;
            self_.sending = NO;
            self_.submit.enabled = YES;
            if (ok) {
                self_.status.stringValue = ticket.length
                    ? [NSString stringWithFormat:RLPTr(@"已提交，工单号 %@"), ticket]
                    : RLPTr(@"已提交（后台未返回工单号）");
                RLPToast(RLPTr(@"反馈已提交，谢谢"));
                self_.body.string = @"";
            } else {
                self_.status.stringValue = err.length ? err
                    : [NSString stringWithFormat:RLPTr(@"提交失败（HTTP %d）"), status];
            }
        });
    });
}

@end
