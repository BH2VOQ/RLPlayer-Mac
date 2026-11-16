// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_queue_import_contract.mm — M3U 导入表单编码契约（RLPEnc(files)）
//
// 证明：
//   旧实现用 URLQueryAllowedCharacterSet 编码 files，会放过 '&'、'+'、'='：
//     - '&' 把 files 字段截断，导致路径后半段丢失；
//     - '+' 被后端 urlDecode 当成空格，导致含 '+' 的文件名损坏；
//     - '=' 破坏键值或路径。
//   改为 RLPEnc(files) 后，后端按 '&'/'=' + urlDecode 解析可无损还原原始路径。
//
// 铁律 1：桩 RLPCoreClient，不启动核心、不碰音频设备、不弹面板。

#import <AppKit/AppKit.h>
#import "RLPQueueViewController.h"
#import "RLPCoreClient.h"
#import "RLPSupport.h"

#include <cstdio>
#include <string>
#include <sstream>
#include <unistd.h>

@interface RLPQueueViewController (RLPM3UImportSeam)
- (void)importM3UAtPath:(NSString *)path playing:(BOOL)playing;
@end

static int g_pass = 0, g_fail = 0;
static void Ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++g_fail; }
}

static NSMutableArray<NSDictionary *> *g_posts;

// 与 tools/rtaweb.cpp 完全同口径的 urlDecode
static std::string rtaweb_url_decode(const std::string& s) {
    std::string out;
    out.reserve(s.size());
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] == '%' && i + 2 < s.size()) {
            auto hex = [](char c) -> int {
                if (c >= '0' && c <= '9') return c - '0';
                if (c >= 'a' && c <= 'f') return c - 'a' + 10;
                if (c >= 'A' && c <= 'F') return c - 'A' + 10;
                return -1;
            };
            int h = hex(s[i + 1]), l = hex(s[i + 2]);
            if (h >= 0 && l >= 0) {
                out.push_back((char)((h << 4) | l));
                i += 2;
                continue;
            }
        }
        out.push_back(s[i] == '+' ? ' ' : s[i]);
    }
    return out;
}

static void parse_form_body(const std::string& body, std::string& reqStopped, std::string& files) {
    std::istringstream is(body);
    std::string tok;
    while (std::getline(is, tok, '&')) {
        const size_t e = tok.find('=');
        if (e == std::string::npos) continue;
        const std::string k = rtaweb_url_decode(tok.substr(0, e));
        const std::string v = rtaweb_url_decode(tok.substr(e + 1));
        if (k == "require_stopped") reqStopped = v;
        else if (k == "files") files = v;
    }
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RLPCoreClient
+ (instancetype)shared { static RLPCoreClient *c; if (!c) c = [self new]; return c; }
- (BOOL)started { return YES; }
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    (void)path;
    if (done) done(@{ @"ok": @YES, @"items": @[], @"metas": @[], @"cues": @[] });
}
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    [g_posts addObject:@{ @"path": path ?: @"", @"body": body ?: @"" }];
    if (done) done(@{ @"ok": @YES, @"count": @2 });
}
@end
#pragma clang diagnostic pop

int main(int argc, const char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        [NSApplication sharedApplication];
        g_posts = [NSMutableArray array];

        RLPQueueViewController *q = [[RLPQueueViewController alloc] init];
        (void)q.view;

        NSString *p1 = @"/Music/Simon & Garfunkel/01+02=Sound%20.flac";
        NSString *p2 = @"/Music/A&B/C+D=1.flac";
        NSString *m3uPath = [NSString stringWithFormat:@"/tmp/rlp-m3u-enc-%d.m3u", (int)getpid()];
        NSString *m3u = [NSString stringWithFormat:@"#EXTM3U\r\n%@\r\n%@\r\n", p1, p2];
        NSError *err = nil;
        Ck([m3u writeToFile:m3uPath atomically:YES encoding:NSUTF8StringEncoding error:&err],
           "写入含 &/+/=/% 字符的 .m3u 夹具", err.localizedDescription);

        [q importM3UAtPath:m3uPath playing:NO];
        [[NSFileManager defaultManager] removeItemAtPath:m3uPath error:nil];

        NSString *body = nil;
        for (NSDictionary *p in g_posts) {
            if ([p[@"path"] hasPrefix:@"/api/queue/set"]) { body = p[@"body"]; break; }
        }
        Ck(body != nil, "已发起 POST /api/queue/set", @"");

        if (body) {
            // 1. 原始表单体里除了参数分隔符 `require_stopped=1&files=` 外，files 值中不得出现未编码的 & / + / =
            NSRange filesPrefix = [body rangeOfString:@"files="];
            Ck(filesPrefix.location != NSNotFound, "请求体包含 files= 字段", body);
            NSString *filesVal = (filesPrefix.location != NSNotFound)
                ? [body substringFromIndex:NSMaxRange(filesPrefix)] : @"";
            Ck([filesVal rangeOfString:@"&"].location == NSNotFound,
               "files 值中 '&' 已百分号编码（未裸露截断表单）", filesVal);
            Ck([filesVal rangeOfString:@"+"].location == NSNotFound,
               "files 值中 '+' 已百分号编码（不会被 urlDecode 变成空格）", filesVal);
            Ck([filesVal rangeOfString:@"="].location == NSNotFound,
               "files 值中 '=' 已百分号编码", filesVal);

            // 2. 用 rtaweb 同口径解析，必须无损还原两首路径
            std::string reqStopped, decodedFiles;
            parse_form_body(body.UTF8String ?: "", reqStopped, decodedFiles);
            NSString *want = [NSString stringWithFormat:@"%@\n%@", p1, p2];
            NSString *got = [NSString stringWithUTF8String:decodedFiles.c_str()] ?: @"";
            Ck(reqStopped == "1", "require_stopped=1 完整解析",
               [NSString stringWithUTF8String:reqStopped.c_str()]);
            Ck([got isEqualToString:want], "后端 form+urlDecode 无损还原含 &/+/=/% 的路径",
               [NSString stringWithFormat:@"got=[%@] want=[%@]", got, want]);
        }

        std::printf("\n结果: %d 通过, %d 失败\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
