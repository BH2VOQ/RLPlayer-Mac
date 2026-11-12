// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// main.mm — rlplayer_native（纯 AppKit 客户端）入口
//
// 三种模式：
//   （默认）      正常启动 GUI
//   --selftest   只构建视图树并断言契约（不启动核心、不窗口）
//   --smoke      隔离状态/曲库目录下启动核心，拉一次 /api/lib/albums 与 /api/status，
//                打印结果后退出（验证 ObjC 桥→C++ 核心的真实链路，不开窗口、不发声）
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import "RLPAppDelegate.h"
#import "RLPCoreClient.h"
#import "RLPFunctionalAudit.h"
#import "RLPTheme.h"

#include <cstdio>
#include <cstring>

static int RunSmoke(void) {
    NSString *tmp = NSTemporaryDirectory();
    NSString *state = [tmp stringByAppendingPathComponent:[NSString stringWithFormat:@"rlp-native-smoke-%d/state", (int)getpid()]];
    NSString *library = [tmp stringByAppendingPathComponent:[NSString stringWithFormat:@"rlp-native-smoke-%d/lib", (int)getpid()]];
    [[NSFileManager defaultManager] createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:library withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("RLPLAYER_STATE_DIR", state.fileSystemRepresentation ?: "", 1);
    setenv("RLPLAYER_LIBRARY_DIR", library.fileSystemRepresentation ?: "", 1);

    printf("=== rlplayer_native smoke（隔离目录：%s）===\n", state.UTF8String ?: "");
    int fail = 0;
    RLPCoreClient *core = [RLPCoreClient shared];
    if (![core startEmbedded]) {
        printf("  [FAIL] 核心启动失败\n");
        return 1;
    }
    printf("  [PASS] 核心启动\n");

    NSDictionary *ping = [core jsonWithMethod:@"GET" path:@"/api/ping" body:nil];
    printf("  [%s] /api/ping %s\n", ping ? "PASS" : "FAIL",
           ping ? [[ping description] UTF8String] : "nil");
    if (!ping) ++fail;

    NSDictionary *albums = [core jsonWithMethod:@"GET" path:@"/api/lib/albums" body:nil];
    BOOL albumsOK = albums && [albums[@"ok"] boolValue];
    printf("  [%s] /api/lib/albums ok=%s count=%ld\n", albumsOK ? "PASS" : "FAIL",
           albumsOK ? "true" : "false",
           albumsOK ? (long)[(NSArray *)albums[@"albums"] count] : 0L);
    if (!albumsOK) ++fail;

    NSDictionary *status = [core jsonWithMethod:@"GET" path:@"/api/status" body:nil];
    BOOL statusOK = status && [status[@"ok"] boolValue];
    printf("  [%s] /api/status ok=%s playing=%s\n", statusOK ? "PASS" : "FAIL",
           statusOK ? "true" : "false",
           statusOK && [status[@"playing"] boolValue] ? "true" : "false");
    if (!statusOK) ++fail;

    [core shutdown];
    printf("\n%s（%d 项失败）\n", fail == 0 ? "native smoke 全部通过" : "native smoke 有失败", fail);
    return fail == 0 ? 0 : fail;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL selftest = NO, smoke = NO;
        NSString *auditDir = nil;
        for (int i = 1; i < argc; ++i) {
            if (std::strcmp(argv[i], "--selftest") == 0) selftest = YES;
            if (std::strcmp(argv[i], "--smoke") == 0) smoke = YES;
            if (std::strcmp(argv[i], "--audit") == 0) {
                // --audit [目录]：功能级验收 + 离屏截图（不弹窗、不出声）
                auditDir = (i + 1 < argc && argv[i + 1][0] != '-')
                    ? [NSString stringWithUTF8String:argv[++i]]
                    : [NSTemporaryDirectory() stringByAppendingPathComponent:@"rlp-native-audit"];
            }
        }
        // --dump-theme <apple|classic> <dark|light>：把主题令牌以 JSON 打到 stdout。
        // 用途：tools/native_ui/theme_parity.py 逐 token 与 web 的 CSS 值比对。
        // 为什么要有这个出口：色值对不对不能靠人眼看截图，必须能机械核对。
        for (int i = 1; i < argc; ++i) {
            if (std::strcmp(argv[i], "--dump-theme") == 0 && i + 2 < argc) {
                [RLPTheme setUiStyle:[NSString stringWithUTF8String:argv[i + 1]]];
                [RLPTheme setThemeName:[NSString stringWithUTF8String:argv[i + 2]]];
                NSDictionary *dump = [[RLPTheme current] tokenDump];
                NSData *j = [NSJSONSerialization dataWithJSONObject:dump
                    options:NSJSONWritingSortedKeys error:nil];
                if (j) fwrite(j.bytes, 1, j.length, stdout);
                printf("\n");
                return 0;
            }
        }
        if (selftest) return RLPAppDelegateRunSelfTest();
        if (smoke) return RunSmoke();
        if (auditDir) return RLPRunFunctionalAudit(auditDir);

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        RLPAppDelegate *delegate = [[RLPAppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
        (void)delegate;
    }
    return 0;
}