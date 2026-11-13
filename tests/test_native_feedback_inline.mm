// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_feedback_inline.mm — 反馈发送 + 诊断摘要的**行为**判据（task-3 C/D）
//
// ============================ 这条判据在证明什么 ============================
// C（用户图五）：点「发送反馈」**不许跳出新窗口**，应就地提交上方文本 + 诊断包；
//   通道探活按 web 的真实语义（watchdog 200+ok 才允许发；失败/超时如实显示，绝不假装成功）；
//   字数上限与计数单位对齐 web（web 源码 var FB_MAX_BYTES = 16384，按 UTF-8 字节计）。
//   判据：点击前后 NSApp.windows 数量不变 + 无 attachedSheet；抓请求体断言
//   URL == web 代码常量 kFeedbackUploadUrl、body 含正文 + 诊断包 base64；成功/失败文案逐字。
// D（用户图六/七）：诊断摘要只「复制 + 就地提示」，不弹窗、不显示 JSON 面板；
//   判据：点击前后窗口数不变、剪贴板 == /api/diag 的摘要 JSON、页面出现「摘要已复制」、
//   导出卡内不存在 JSON 面板（无 sp_diagsummarytext / sp_diagscroll）。
//
// 网络层通过测试接缝注入（生产路径仍是 rta::net）；断言的就是 feedback_api.h 里的代码常量。
// 红→绿：旧码点发送会 showAndFocus 打开反馈窗口（窗口数 +1），也根本没有 POST ⟹ C 红；
//   旧码摘要渲染进 sp_diagsummarytext 面板 ⟹ D 红。
// 证据：evidence/native-3-feedback-red.log / -green.log
//
// 纪律：隔离 state/library；backend=null、volume=-120；不播放任何音频（铁律②）。
#import <AppKit/AppKit.h>
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPSettingsViewController.h"

#include <cstdio>
#include <cstdlib>
#include <string>
#include <unistd.h>

#include "net/feedback_api.h"
#include "version.h"

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
static NSArray<NSView *> *Descendants(NSView *v) {
    NSMutableArray<NSView *> *a = [NSMutableArray array];
    Collect(v, a);
    return a;
}
static NSView *FindId(NSView *root, NSString *ident) {
    for (NSView *v in Descendants(root)) if ([v.identifier isEqualToString:ident]) return v;
    return nil;
}
static BOOL SetKVC(id obj, NSString *key, id value) {
    @try { [obj setValue:value forKey:key]; return YES; }
    @catch (NSException *e) { return NO; }
}
static id GetKVC(id obj, NSString *key) {
    @try { return [obj valueForKey:key]; }
    @catch (NSException *e) { return nil; }
}
/// 卡片标题（set.group.head 里的第一个 NSTextField）。
static NSString *CardTitle(NSView *card) {
    NSView *head = FindId(card, @"set.group.head");
    if (!head) return @"";
    for (NSView *s in head.subviews)
        if ([s isKindOfClass:[NSTextField class]]) return ((NSTextField *)s).stringValue;
    return @"";
}
static NSView *CardFor(NSView *v) {
    for (NSView *p = v.superview; p; p = p.superview)
        if ([NSStringFromClass(p.class) isEqualToString:@"RLPSettingsGroup"]) return p;
    return nil;
}
/// 返回当前所有窗口的指纹，用于「没有新窗口」判据（数量 + 标题）。
static NSString *WindowsFingerprint(void) {
    NSMutableArray<NSString *> *a = [NSMutableArray array];
    for (NSWindow *w in [NSApp windows]) [a addObject:w.title ?: @"(untitled)"];
    [a sortUsingSelector:@selector(compare:)];
    return [NSString stringWithFormat:@"%lu:%@", (unsigned long)a.count,
            [a componentsJoinedByString:@"|"]];
}

/// 从 web 前端源码取真实上限（机器对照，不手抄）：src/net/ui_script.h 的
/// `var FB_MAX_BYTES = <n>;`。这样「原生上限与 web 一致」才是可复核的事实。
static NSString *WebFeedbackMaxBytes(void) {
    NSArray<NSString *> *paths = @[ @"../src/net/ui_script.h", @"src/net/ui_script.h",
                                    @"../../src/net/ui_script.h" ];
    for (NSString *p in paths) {
        NSString *src = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        if (!src.length) continue;
        NSRange r = [src rangeOfString:@"FB_MAX_BYTES = " options:0];
        if (r.location == NSNotFound) continue;
        NSString *tail = [src substringFromIndex:NSMaxRange(r)];
        NSMutableString *num = [NSMutableString string];
        for (NSUInteger i = 0; i < tail.length && i < 12; ++i) {
            unichar c = [tail characterAtIndex:i];
            if (c >= '0' && c <= '9') [num appendFormat:@"%C", c];
            else break;
        }
        if (num.length) return num;
    }
    return nil;
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        std::printf("=== test_native_feedback_inline（task-3 C/D · 真页面 · 不出声）===\n");

        NSString *rootDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"rlp-fbinline-%d", (int)getpid()]];
        NSString *state = [rootDir stringByAppendingPathComponent:@"state"];
        NSString *lib = [rootDir stringByAppendingPathComponent:@"lib"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:lib withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("RLPLAYER_STATE_DIR", state.fileSystemRepresentation, 1);
        setenv("RLPLAYER_LIBRARY_DIR", lib.fileSystemRepresentation, 1);
        RLPCoreClient *core = [RLPCoreClient shared];
        if (![core startEmbedded]) { std::printf("  [FAIL] 核心启动失败\n"); return 1; }
        [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"backend=null&volume=-120"];

        RLPSettingsViewController *settings = [[RLPSettingsViewController alloc] init];
        NSView *v = settings.view;
        v.frame = NSMakeRect(0, 0, 1280, 900);
        [v layoutSubtreeIfNeeded];

        // ---- 探活接缝：在进诊断页之前注入，fillDiag 的首次探活就会走桩（不联网）----
        __block NSInteger probeCalls = 0;
        __block void (^probeReply)(NSInteger, NSData *, BOOL) = nil;
        void (^probeStub)(void (^)(NSInteger, NSData *, BOOL)) =
            ^(void (^done)(NSInteger, NSData *, BOOL)) {
                ++probeCalls;
                probeReply = [done copy];
            };
        Ck(SetKVC(settings, @"fbProbeTransport", probeStub),
           @"测试接缝已注入（探活网络层可替换）", @"KVC 注入失败（旧码没有这个接缝）");

        [settings selectPane:@"diag"];
        [v layoutSubtreeIfNeeded];
        Pump(0.3);

        NSView *diagPane = FindId(v, @"tab.diag");
        Ck(diagPane != nil, @"诊断页根视图存在", @"找不到 tab.diag");
        NSButton *sendBtn = (NSButton *)FindId(diagPane, @"sp_fbsend");
        NSTextField *fbChan = (NSTextField *)FindId(diagPane, @"sp_fbchan");
        NSTextField *fbMsg = (NSTextField *)FindId(diagPane, @"sp_fbmsg");
        NSTextField *fbCount = (NSTextField *)FindId(diagPane, @"sp_fbcount");
        NSTextView *fbText = (NSTextView *)FindId(diagPane, @"sp_fbtext");
        NSSwitch *fbDiag = (NSSwitch *)FindId(diagPane, @"sp_fbdiag");
        Ck(sendBtn && fbChan && fbMsg && fbCount && fbText && fbDiag,
           @"反馈表单控件齐备（发送/通道/结果/计数/正文/附带诊断包）", @"缺控件");

        // 首次探活已经发出（走桩）；回复 200+ok 后才允许发。
        Ck(probeCalls == 1, @"进入诊断页即探活一次（web fbWatchdog 同语义）",
           [NSString stringWithFormat:@"probeCalls=%ld", (long)probeCalls]);
        if (probeReply) {
            NSData *wdBody = [NSData dataWithBytes:
                "{\"ok\":true,\"limits\":{\"textBytes\":16384,\"diagBytes\":8388608,\"ratePerMinute\":5}}"
                length:strlen("{\"ok\":true,\"limits\":{\"textBytes\":16384,\"diagBytes\":8388608,\"ratePerMinute\":5}}")];
            probeReply(200, wdBody, NO);
        }
        Pump(0.4);
        Ck([fbChan.stringValue containsString:@"反馈通道已连接"] &&
           [fbChan.stringValue containsString:@"每分钟最多 5 次"],
           @"探活成功文案与 web 一致（反馈通道已连接（每分钟最多 5 次））", fbChan.stringValue);
        Ck(sendBtn.enabled, @"探活成功后「发送反馈」可点", @"按钮仍禁用");

        // ---- 字数上限与计数单位（对齐 web 源码常量，按 UTF-8 字节计）----
        NSString *webMax = WebFeedbackMaxBytes();
        Ck(webMax.length > 0, @"能从 web 源码抽到 FB_MAX_BYTES（用于机器对照）",
           webMax ? webMax : @"找不到 src/net/ui_script.h");
        NSString *expectEmpty = [NSString stringWithFormat:@"0 / %@ 字节", webMax ?: @"16384"];
        Ck([fbCount.stringValue isEqualToString:expectEmpty],
           @"空文本计数 == web 同款（0 / <FB_MAX_BYTES> 字节）", fbCount.stringValue);
        fbText.string = @"一二三四五六";   // 6 个汉字 = 18 UTF-8 字节
        [settings performSelector:NSSelectorFromString(@"updateFbCount")];
        Pump(0.1);
        NSString *expect18 = [NSString stringWithFormat:@"18 / %@ 字节", webMax ?: @"16384"];
        Ck([fbCount.stringValue isEqualToString:expect18],
           @"中文按 UTF-8 字节计（6 字 = 18 字节，不是 6）", fbCount.stringValue);

        // ---- C：点发送不弹窗 + 真 POST（接缝抓 body）----
        NSString *windowsBefore = WindowsFingerprint();
        const NSUInteger windowsBeforeCount = [NSApp windows].count;
        __block NSString *capturedURL = nil;
        __block NSString *capturedBody = nil;
        __block NSInteger uploadCalls = 0;
        __block void (^pendingReply)(NSInteger, NSData *) = nil;
        void (^uploadStub)(NSString *, NSString *, void (^)(NSInteger, NSData *)) =
            ^(NSString *url, NSString *body, void (^reply)(NSInteger, NSData *)) {
                ++uploadCalls;
                capturedURL = [url copy];
                capturedBody = [body copy];
                pendingReply = [reply copy];
            };
        Ck(SetKVC(settings, @"fbUploadTransport", uploadStub),
           @"上传接缝已注入（POST 网络层可替换）", @"KVC 注入失败（旧码没有这个接缝）");

        // 超限（web 上限的 ~1.6 倍字节）：点击拒绝发送，不发起请求，文案与 web 同构。
        NSMutableString *over = [NSMutableString string];
        for (NSUInteger i = 0; i < 9000; ++i) [over appendString:@"一"];   // 27000 字节 > 16384
        fbText.string = over;
        [settings performSelector:NSSelectorFromString(@"updateFbCount")];
        [sendBtn performClick:nil];   // channel 已 ok，但超限必须被拦下
        Pump(0.3);
        Ck(uploadCalls == 0 && [fbMsg.stringValue hasPrefix:@"内容超过 "],
           @"【C】超过 web 上限时点击被拦下并如实提示（不截断、不静默发送）", fbMsg.stringValue);
        fbText.string = @"";
        [settings performSelector:NSSelectorFromString(@"updateFbCount")];

        NSString *feedbackText = @"测试反馈：播放页偶发无声。";
        fbText.string = feedbackText;
        [settings performSelector:NSSelectorFromString(@"updateFbCount")];
        fbDiag.state = NSControlStateValueOn;
        [sendBtn performClick:nil];
        Pump(1.2);
        Ck([WindowsFingerprint() isEqualToString:windowsBefore] &&
            [NSApp windows].count == windowsBeforeCount,
           @"【C】点「发送反馈」不创建任何新窗口 / 不出现 sheet（NSApp.windows 数量不变）",
           [NSString stringWithFormat:@"before=%@ after=%@", windowsBefore, WindowsFingerprint()]);
        Ck(uploadCalls == 1, @"【C】点击确实发起了一次上传（旧码只是打开弹窗，不发请求）",
           [NSString stringWithFormat:@"calls=%ld", (long)uploadCalls]);

        // 请求体：必须是 web 同款端点 + 正文 + 诊断包（base64 在 diag 字段）。
        NSString *expectURL = [NSString stringWithUTF8String:rta::feedback::kFeedbackUploadUrl];
        Ck([capturedURL isEqualToString:expectURL],
           @"【C】POST 到 web 同款端点 https://rlplayer.rainlain.com/api/v1/feedback/macos",
           capturedURL ?: @"(null)");
        NSDictionary *req = nil;
        if (capturedBody.length) {
            id obj = [NSJSONSerialization JSONObjectWithData:
                [capturedBody dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if ([obj isKindOfClass:[NSDictionary class]]) req = obj;
        }
        Ck(req != nil, @"【C】请求体是合法 JSON", capturedBody ?: @"(null)");
        if (req) {
            Ck([req[@"text"] isEqualToString:feedbackText], @"【C】请求体含上方文本域正文",
               [NSString stringWithFormat:@"text=%@", req[@"text"]]);
            Ck([req[@"version"] isEqualToString:[NSString stringWithUTF8String:RLPLAYER_VERSION]], @"【C】请求体带真实版本号",
               [NSString stringWithFormat:@"version=%@", req[@"version"]]);
            Ck([req[@"client"] isKindOfClass:[NSString class]] &&
               [req[@"idempotency_key"] isKindOfClass:[NSString class]] &&
               [req[@"os"] isKindOfClass:[NSString class]],
               @"【C】请求体带 client / os / idempotency_key（web 协议六字段）",
               [NSString stringWithFormat:@"keys=%@", [req.allKeys componentsJoinedByString:@","]]);
            NSString *diagB64 = [req[@"diag"] isKindOfClass:[NSString class]] ? req[@"diag"] : @"";
            NSData *diagRaw = [[NSData alloc] initWithBase64EncodedString:diagB64 options:0];
            Ck(diagRaw.length > 0, @"【C】附带诊断包（diag 字段非空，解码后是 JSON）",
               [NSString stringWithFormat:@"len=%lu", (unsigned long)diagRaw.length]);
            if (diagRaw.length) {
                id dj = [NSJSONSerialization JSONObjectWithData:diagRaw options:0 error:nil];
                Ck([dj isKindOfClass:[NSDictionary class]],
                   @"【C】诊断包解码后是 JSON 对象（与「导出诊断包」同一份组装）", @"解码不是 JSON");
            }
            // web 协议只发六个字段（多一个都可能被后台 400）。
            NSArray<NSString *> *allowed = @[ @"text", @"version", @"os", @"client", @"diag",
                                              @"idempotency_key" ];
            BOOL onlySix = req.allKeys.count == allowed.count;
            for (NSString *k in req.allKeys) if (![allowed containsObject:k]) onlySix = NO;
            Ck(onlySix, @"【C】请求体恰好六个协议字段（不含多余字段）",
               [NSString stringWithFormat:@"keys=%@", [req.allKeys componentsJoinedByString:@","]]);
        }
        // 成功回包：文案逐字对齐 web（'已收到，工单号 …。感谢反馈！' + 清空正文）
        if (pendingReply) {
            NSData *okBody = [NSData dataWithBytes:"{\"ok\":true,\"id\":\"FB-TEST-1\",\"diagStored\":true}"
                                             length:strlen("{\"ok\":true,\"id\":\"FB-TEST-1\",\"diagStored\":true}")];
            pendingReply(200, okBody);
        }
        Pump(0.5);
        Ck([fbMsg.stringValue isEqualToString:@"已收到，工单号 FB-TEST-1。感谢反馈！"],
           @"【C】成功文案逐字对齐 web（已收到，工单号 …。感谢反馈！）", fbMsg.stringValue);
        Ck(fbText.string.length == 0, @"【C】成功后清空正文（web fbSend 同语义）", fbText.string);
        Ck(sendBtn.enabled && [sendBtn.title isEqualToString:RLPTr(@"发送反馈")],
           @"【C】成功后按钮恢复「发送反馈」", sendBtn.title);

        // 失败回包：绝不假装成功
        fbText.string = @"再发一次";
        [settings performSelector:NSSelectorFromString(@"updateFbCount")];
        [sendBtn performClick:nil];
        Pump(0.8);
        Ck(uploadCalls == 2, @"【C】再次点击发起第二次上传", [NSString stringWithFormat:@"calls=%ld", (long)uploadCalls]);
        if (pendingReply) {
            NSData *failBody = [NSData dataWithBytes:
                "{\"ok\":false,\"code\":\"rate_limited\",\"error\":\"请求过于频繁\"}"
                length:strlen("{\"ok\":false,\"code\":\"rate_limited\",\"error\":\"请求过于频繁\"}")];
            pendingReply(429, failBody);
        }
        Pump(0.5);
        Ck([fbMsg.stringValue isEqualToString:@"发送失败：请求过于频繁（稍等一会儿再试）"] &&
           fbText.string.length > 0,
           @"【C】失败如实显示 web 文案（发送失败：… + rate_limited 提示），不清空正文",
           fbMsg.stringValue);

        // ---- 通道不可用：按钮保持禁用、点击拒发、如实提示（不得假装成功）----
        SetKVC(settings, @"fbLastChannelCheck", nil);
        probeReply = nil;
        [settings performSelector:NSSelectorFromString(@"probeFeedbackChannel")];
        Pump(0.2);
        Ck(probeCalls == 2 && probeReply != nil, @"可重试探活（web 重试探活 同语义）",
           [NSString stringWithFormat:@"probeCalls=%ld", (long)probeCalls]);
        if (probeReply) {
            NSData *dead = [NSData dataWithBytes:"{\"ok\":false,\"error\":\"维护中\"}"
                                           length:strlen("{\"ok\":false,\"error\":\"维护中\"}")];
            probeReply(503, dead, NO);
        }
        Pump(0.4);
        Ck([fbChan.stringValue containsString:@"反馈后台暂不可用"] &&
           [fbChan.stringValue containsString:@"维护中"],
           @"【C】探活失败文案如实（反馈后台暂不可用：<原因>）", fbChan.stringValue);
        Ck(!sendBtn.enabled, @"【C】通道不可用时「发送反馈」保持禁用（绝不假装能发）", @"按钮仍可点");
        NSInteger uploadsBefore = uploadCalls;
        [sendBtn performClick:nil];
        Pump(0.3);
        Ck(uploadCalls == uploadsBefore,
           @"【C】通道不可用且按钮禁用时点击不发请求", [NSString stringWithFormat:@"calls=%ld", (long)uploadCalls]);
        if ([settings respondsToSelector:NSSelectorFromString(@"onSendFeedback:")]) {
            // 键盘/程序化触发的第二道闸门（web fbSend 里 FB.serverOk !== true 的兜底）。
            [settings performSelector:NSSelectorFromString(@"onSendFeedback:") withObject:sendBtn];
            Pump(0.3);
            Ck(uploadCalls == uploadsBefore &&
               [fbMsg.stringValue isEqualToString:@"反馈后台当前不可用，请稍后再试"],
               @"【C】通道不可用时程序化触发也被拒（如实提示、绝不假装成功）", fbMsg.stringValue);
        } else {
            Ck(NO, @"【C】通道不可用时的第二道闸门", @"旧码没有 onSendFeedback:（发送入口是弹窗）");
        }

        // ---- D：诊断摘要只复制 + 就地提示，不弹窗、不显示 JSON 面板 ----
        NSButton *summaryBtn = (NSButton *)FindId(diagPane, @"sp_diagsummary");
        NSTextField *diagMsg = (NSTextField *)FindId(diagPane, @"sp_diagmsg");
        Ck(summaryBtn != nil && diagMsg != nil, @"诊断摘要按钮与就地提示行存在", @"缺控件");
        Ck(FindId(diagPane, @"sp_diagsummarytext") == nil && FindId(diagPane, @"sp_diagscroll") == nil,
           @"【D】不存在摘要 JSON 面板（sp_diagsummarytext / sp_diagscroll）", @"旧面板还在");

        // 摘要数据用固定样例（与 /api/diag 同一形状）：断言剪贴板与生产代码序列化的结果逐字节一致。
        NSDictionary *fixedDiag = @{
            @"version" : [NSString stringWithUTF8String:RLPLAYER_VERSION],
            @"os" : @"macOS 27.2",
            @"endpoints" : @[ @{ @"id" : @"106", @"name" : @"M140F2", @"alive" : @YES } ],
            @"settings" : @{ @"backend" : @"null", @"volume" : @"-120" },
        };
        __block NSInteger diagCalls = 0;
        void (^diagStub)(void (^)(NSDictionary *)) = ^(void (^done)(NSDictionary *)) {
            ++diagCalls;
            if (done) done(fixedDiag);
        };
        Ck(SetKVC(settings, @"diagSummaryTransport", diagStub),
           @"摘要数据测试接缝已注入（生产路径走 /api/diag）", @"KVC 注入失败（旧码没有这个接缝）");

        [[NSPasteboard generalPasteboard] clearContents];
        NSString *winBeforeCopy = WindowsFingerprint();
        [summaryBtn performClick:nil];
        Pump(1.0);
        NSString *expectSummary = nil;
        {
            NSData *d = [NSJSONSerialization dataWithJSONObject:fixedDiag
                options:NSJSONWritingPrettyPrinted error:nil];
            expectSummary = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        }
        Ck(diagCalls == 1, @"【D】点击摘要按钮真的去取摘要数据（不是空操作）",
           [NSString stringWithFormat:@"calls=%ld", (long)diagCalls]);
        NSString *clip = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString] ?: @"";
        Ck([WindowsFingerprint() isEqualToString:winBeforeCopy],
           @"【D】点「查看 / 复制诊断摘要」不创建任何窗口 / sheet",
           [NSString stringWithFormat:@"before=%@ after=%@", winBeforeCopy, WindowsFingerprint()]);
        Ck(expectSummary.length > 0 && [clip isEqualToString:expectSummary],
           @"【D】剪贴板内容 == 诊断摘要文本（与 /api/diag 同源）",
           [NSString stringWithFormat:@"clipLen=%lu expectLen=%lu",
            (unsigned long)clip.length, (unsigned long)expectSummary.length]);
        Ck([diagMsg.stringValue isEqualToString:@"摘要已复制"],
           @"【D】页面内就地提示「摘要已复制」（不弹窗、不出现第二个容器）", diagMsg.stringValue);
        // 摘要文本不得出现在导出卡内的任何文本视图里（面板形态的残留）。
        BOOL jsonPanelInCard = NO;
        for (NSView *x in Descendants(v)) {
            if (![x isKindOfClass:[NSTextView class]]) continue;
            NSTextView *tv = (NSTextView *)x;
            NSView *card = CardFor(tv);
            if (card && [CardTitle(card) containsString:@"导出诊断包"] && tv.string.length > 0)
                jsonPanelInCard = YES;
        }
        Ck(!jsonPanelInCard, @"【D】导出诊断包卡内不存在 JSON 明文面板", @"导出卡内仍有文本视图");
        // 同一按钮再点一次：幂等（不新增窗口 / 不新增容器）
        NSString *winBefore2 = WindowsFingerprint();
        [summaryBtn performClick:nil];
        Pump(0.8);
        Ck([WindowsFingerprint() isEqualToString:winBefore2],
           @"【D】再次点击仍不创建窗口（幂等）", WindowsFingerprint());

        std::printf("结果：%d passed, %d failed\n", gPass, gFail);
        return gFail == 0 ? 0 : 1;
    }
}
