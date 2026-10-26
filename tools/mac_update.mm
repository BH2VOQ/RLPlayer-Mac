// mac_update.mm — F-4 自动更新的**原生执行层**（下载 / 校验 / 挂载 / 替换 .app）
//
// ============================ 为什么必须在这一层 ============================
// 网页沙箱（WKWebView，rlplayer:// scheme）做不到这些事：
//   * 把文件写到临时目录并按固定路径落盘
//   * 调 hdiutil 挂载 dmg
//   * 用 ditto 覆盖 /Applications/RLPlayer.app
//   * 读 .app 之外的配置文件
// 所以下载、校验、安装全在这里。**判定逻辑不在这里** —— 版本比较、清单解析、
// sha256、白名单、失败分支全在 src/net/update_check.h（可离线单测）。
// 本文件只负责「按判定结果执行 IO」，因此本文件写错最多是"装不上"，
// 不会变成"判成了最新"或"装了被篡改的包"。
//
// ============================ 安全（用户硬要求）============================
//   ① token 绝不硬编码：只从 config_dir_utf8()/update.conf 读，且只在内存里用一次。
//   ② token 绝不进日志/错误信息/UI 文案：本文件所有回传给页面的字符串都过
//      RedactToken()，把 token 出现的位置抹成 "***"（连长度都不暴露）。
//   ③ 下载 URL 必须过 update_download_url_allowed()（https + 精确主机）。
//   ④ 安装前必须过 verify_downloaded_file()；失败即丢弃临时文件，**不挂载、不替换**。
//   ⑤ **绝不自己重启 .app**（会被 TCC/签名拦）：只弹提示，由用户手动重启。
//   ⑥ 替换前先做 .app 备份；替换失败可用备份回滚。
//
// ============================ 线程模型 ============================
//   begin_check() / begin_install() 都是**立即返回**，真正工作跑在后台队列，
//   进度与结果通过 block 回调回主线程（由 mac_host.mm 转成 JS 事件）。
//   原因：hdiutil 挂载 + 7 MB 下载要数秒，阻塞主线程会让窗口"转菊花"。
// ⚠️ include 顺序有讲究（踩过一次）：
//   src/net/json.h 内部有 `static const Json nil;` 函数内静态变量，而 Objective-C 的
//   `nil` 是内建标识符（__null）⟹ 若 json.h 在 Foundation 之后被包含，`nil` 已被定义为
//   内建量，那里会报 "expected unqualified-id"。
//   所以：**纯 C++ 头必须在 ObjC 框架之前**包含。json.h 有 #pragma once，
//   后面 update_check.h 再包含它是空操作。
#include "net/json.h"

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include "mac_update.h"        // 本模块的公开接口（本文件提供实现）
#include "net/http_client.h"    // rta::net::http_get（平台层 libcurl，阻塞同步）
#include "net/update_check.h"
#include "platform/path.h"     // config_dir_utf8 / module_dir_utf8 / temp_dir_utf8 / join

// RLPLAYER_VERSION 来自 src/version.h（唯一真相源）
#include "version.h"

namespace rta::update {

namespace detail_native {

// ---------------- token 脱敏 ----------------
// 任何可能进 UI/日志的字符串都必须过这里。
// 为什么连"长度"都不暴露：长度可用于缩小暴力破解范围。
inline std::string RedactToken(const std::string& input, const std::string& token) {
    if (token.empty() || input.empty()) return input;
    std::string out = input;
    size_t pos = 0;
    while ((pos = out.find(token, pos)) != std::string::npos) {
        out.replace(pos, token.size(), "***");
        pos += 3;
    }
    return out;
}

// ---------------- 配置文件路径 ----------------
inline std::string UpdateConfPath() {
    const std::string dir = rta::platform::config_dir_utf8();
    if (dir.empty()) return "";
    return rta::platform::join(dir, "update.conf");
}

// 读配置：文件不存在 ⟹ 默认匿名（**不报错**，这是首次运行的常态）
inline Config LoadConfig() {
    const std::string path = UpdateConfPath();
    if (path.empty()) return parse_update_config("");
    std::ifstream f(path, std::ios::binary);
    if (!f) return parse_update_config("");
    std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    Config c = parse_update_config(text);
    c.fileExists = true;
    return c;
}

// 首次运行写出 0600 模板（"缺省即安全"：token 行为空 ⟹ 匿名路径）。
// ⚠️ 必须**创建时就 0600**：先 open(O_CREAT,0600) 再写，绝不 0644 落地后 chmod。
inline bool EnsureConfTemplate(const std::string& path, std::string& err) {
    if (path.empty()) { err = "配置目录不可用"; return false; }
    struct stat st {};
    if (::stat(path.c_str(), &st) == 0) return true;      // 已存在，不动它
    const int fd = ::open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) {
        if (errno == EEXIST) return true;                 // 竞态：别人刚建好
        err = "无法创建 update.conf";
        return false;
    }
    const std::string tpl = default_update_conf_template();
    ssize_t written = ::write(fd, tpl.data(), tpl.size());
    ::close(fd);
    if (written < 0 || (size_t)written != tpl.size()) { err = "写入 update.conf 失败"; return false; }
    return true;
}

// ---------------- HTTP ----------------
struct HttpOutcome {
    bool ok = false;
    int status = 0;
    std::string error;
    std::string body;
};

// 统一走 net/http_client.h（平台层 libcurl，阻塞、同步）。
// token 只在这里作为请求头出现一次，绝不写日志。
inline HttpOutcome Fetch(const std::string& url, const std::string& token, int timeoutMs) {
    HttpOutcome out;
    std::vector<std::string> headers;
    if (!token.empty()) headers.push_back("Authorization: token " + token);
    const auto r = rta::net::http_get(url, headers, timeoutMs);
    out.ok = r.ok;
    out.status = r.status;
    out.error = RedactToken(r.error, token);              // ← ① 脱敏
    out.body.assign(r.body.begin(), r.body.end());
    return out;
}

// ---------------- 路径 ----------------
inline std::string ExecutableBundlePath() {
    // .app 的绝对路径：可执行文件在 <bundle>/Contents/MacOS/<exe> ⟹ 上溯 3 级
    std::string exe = rta::platform::module_dir_utf8();   // .../Contents/MacOS
    if (exe.empty()) return "";
    auto up = [](std::string p) {
        const size_t s = p.find_last_of('/');
        return (s == std::string::npos) ? std::string() : p.substr(0, s);
    };
    const std::string contents = exe;                     // Contents/MacOS
    const std::string contentsDir = up(contents);         // Contents
    const std::string bundle = up(contentsDir);           // RLPlayer.app
    if (bundle.empty() || bundle == "/") return "";
    if (bundle.size() < 4 || bundle.compare(bundle.size() - 4, 4, ".app") != 0) return "";
    return bundle;
}

// 目标安装位置：优先"当前 .app 所在位置"（用户可能把 app 放在 ~/Applications）。
// 只有当它在 /Applications 下才需要提权；本机 /Applications 属 admin:2775，无需提权。
inline std::string InstallTargetPath() {
    const std::string cur = ExecutableBundlePath();
    if (!cur.empty()) return cur;
    return "/Applications/RLPlayer.app";
}

// 运行外部命令，收集 stdout（hdiutil 需要解析真实挂载点）
inline int RunCapture(const std::string& cmd, std::string& out) {
    out.clear();
    FILE* p = ::popen(cmd.c_str(), "r");
    if (!p) return -1;
    char buf[4096];
    while (std::fgets(buf, sizeof(buf), p)) out += buf;
    const int rc = ::pclose(p);
    return (rc == -1) ? -1 : WEXITSTATUS(rc);
}

inline std::string ShellQuote(const std::string& s) {
    // 单引号包裹 + 内部单引号转义（路径可能含空格/中文）
    std::string q = "'";
    for (char c : s) {
        if (c == '\'') q += "'\\''";
        else q += c;
    }
    q += "'";
    return q;
}

} // namespace detail_native

// ---------------------------------------------------------------------------
// 公开接口：路径 / 模板 / 脱敏（供 mac_host.mm 与测试使用）
// ---------------------------------------------------------------------------
std::string update_conf_path() { return detail_native::UpdateConfPath(); }

bool ensure_conf_template(std::string& err) {
    return detail_native::EnsureConfTemplate(detail_native::UpdateConfPath(), err);
}

std::string redact_token(const std::string& input, const std::string& token) {
    return detail_native::RedactToken(input, token);
}

// ---------------------------------------------------------------------------
// 检查更新（异步）
// ---------------------------------------------------------------------------
void begin_check(ProgressFn progress, DoneFn done) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NativeProgress p; p.stage = "checking"; p.detail = "正在检查更新…"; p.percent = -1;
        if (progress) progress(p);

        const Config cfg = detail_native::LoadConfig();
        const bool useToken = cfg.hasToken;

        CheckResult result;
        if (!cfg.manifestUrlValid) {
            // 配置文件里写了非白名单地址 ⟹ 拒绝（不静默回退，免得用户以为在查公开清单）
            result.decision = Decision::FailedBadUrl;
            result.error = cfg.warning.empty() ? "update.conf 的 manifest_url 不在白名单" : cfg.warning;
            if (done) done(result);
            return;
        }

        std::string manifestUrl = cfg.manifestUrl;
        const std::string token = useToken ? cfg.token : std::string();

        // ---- 私有路径：先问 releases API，找最新非草稿 release 的 latest.json 附件 ----
        if (useToken) {
            const auto rel = detail_native::Fetch(kReleasesApiUrl, token, 15000);
            if (!rel.ok || rel.status < 200 || rel.status >= 300) {
                result.decision = (rel.status == 401 || rel.status == 403) ? Decision::FailedAuth
                                                                          : (rel.status == 0 ? Decision::FailedNetwork
                                                                                             : Decision::FailedHttp);
                result.status = rel.status;
                result.error = (result.decision == Decision::FailedAuth)
                    ? "鉴权失败（检查 update.conf 里的只读 token）"
                    : (result.decision == Decision::FailedNetwork
                           ? "网络不可用（无法连接更新服务器）"
                           : "更新服务器返回 HTTP " + std::to_string(rel.status));
                if (done) done(result);
                return;
            }
            // ⚠️ 2026-10-26 实测（gitea 1.27.3 / 私有仓库）：release 附件下载对 token
            // 全线 403，所以 latest.json **不走附件**，改走仓库 raw 端点（那条对 token 正常）。
            // 具体分支：
            //   ① API 里能找到 latest.json 附件 → 用它的地址（公开仓库/未来 gitea 修好后可用）
            //   ② 找不到 → 退回仓库文件 raw 路径（本机当前唯一实测可用的方式）
            const auto lk = find_manifest_asset_in_releases(rel.body);
            if (lk.found) {
                manifestUrl = lk.url;
            } else {
                manifestUrl = std::string(kPrivateRawPrefix) + kManifestAssetName +
                              "?ref=" + kPrivateManifestRef;
                if (!update_download_url_allowed(manifestUrl)) {
                    result.decision = Decision::FailedBadUrl;
                    result.error = "私有清单地址不在白名单";
                    if (done) done(result);
                    return;
                }
            }
        }

        // ---- 取清单（公开路径：匿名；私有路径：仍要带 token，因为内容在私有仓库里）----
        const auto man = detail_native::Fetch(manifestUrl, token, 15000);
        result = evaluate_update_check(RLPLAYER_VERSION, man.ok, man.status, man.body);
        if (done) done(result);
    });
}

// ---------------------------------------------------------------------------
// 可单独调用的安装步骤（测试用真 dmg 跑，见 tests/test_mac_update.mm）
// ---------------------------------------------------------------------------
bool mount_image(const std::string& dmgPath, const std::string& mountPoint,
                 std::string& outAppPath, std::string& err) {
    outAppPath.clear();
    err.clear();
    if (dmgPath.empty() || mountPoint.empty()) { err = "参数为空"; return false; }
    ::mkdir(mountPoint.c_str(), 0700);
    std::string out;
    const std::string cmd = "/usr/bin/hdiutil attach -nobrowse -noverify -noautoopen -mountpoint " +
                            detail_native::ShellQuote(mountPoint) + " " +
                            detail_native::ShellQuote(dmgPath) + " 2>&1";
    if (detail_native::RunCapture(cmd, out) != 0) {
        err = "hdiutil attach 失败：" + out;
        return false;
    }
    // 取镜像内第一个 *.app（不假设名字：产物可能叫 RLPlayer.app）
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* mnt = [NSString stringWithUTF8String:mountPoint.c_str()];
    NSArray<NSString*>* items = [fm contentsOfDirectoryAtPath:mnt error:nil];
    for (NSString* it in items) {
        if ([it hasSuffix:@".app"]) {
            outAppPath = [[mnt stringByAppendingPathComponent:it] UTF8String];
            break;
        }
    }
    if (outAppPath.empty()) {
        std::string um;
        unmount_image(mountPoint, um);
        err = "镜像内没有 .app";
        return false;
    }
    return true;
}

bool unmount_image(const std::string& mountPoint, std::string& err) {
    std::string out;
    if (detail_native::RunCapture("/usr/bin/hdiutil detach " + detail_native::ShellQuote(mountPoint) + " 2>&1",
                                  out) != 0) {
        err = "hdiutil detach 失败：" + out;
        // 挂载点目录留给系统清理；不 force（铁律 2 的精神：不硬来）
        return false;
    }
    ::rmdir(mountPoint.c_str());
    return true;
}

bool install_app_bundle(const std::string& srcApp, const std::string& targetApp,
                        std::string& outBackup, std::string& err) {
    outBackup.clear();
    err.clear();
    if (srcApp.empty() || targetApp.empty()) { err = "参数为空"; return false; }

    std::string out;
    NSFileManager* fm = [NSFileManager defaultManager];
    const bool existed = [fm fileExistsAtPath:[NSString stringWithUTF8String:targetApp.c_str()]];

    // 1) 备份（仅在目标已存在时）
    if (existed) {
        const std::string bk = targetApp + ".old-" + std::to_string((long long)::time(nullptr));
        if (detail_native::RunCapture("/usr/bin/ditto " + detail_native::ShellQuote(targetApp) + " " +
                                          detail_native::ShellQuote(bk) + " 2>&1", out) != 0) {
            err = "备份现有 .app 失败，已中止（不覆盖）";
            return false;
        }
        outBackup = bk;
    }

    // 2) 覆盖安装（ditto 保留 xattr/签名结构，比 cp -R 稳）
    if (detail_native::RunCapture("/usr/bin/ditto " + detail_native::ShellQuote(srcApp) + " " +
                                      detail_native::ShellQuote(targetApp) + " 2>&1", out) != 0) {
        err = "复制到目标失败：" + out;
        // 3) 回滚
        if (!outBackup.empty()) {
            if (detail_native::RunCapture("/usr/bin/ditto " + detail_native::ShellQuote(outBackup) + " " +
                                              detail_native::ShellQuote(targetApp) + " 2>&1", out) == 0) {
                err += "（已回滚到备份）";
            } else {
                err += "（回滚也失败，备份保留在 " + outBackup + "）";
            }
        }
        return false;
    }
    return true;
}

bool sha256_of_file(const std::string& path, std::string& outHex, std::string& err) {
    return sha256_file(path, outHex, err);
}

bool install_from_local_dmg(const std::string& dmgPath,
                            const std::string& expectedSha256, long long expectedSize,
                            const std::string& mountPoint,
                            const std::string& targetApp,
                            std::string& outBackup, std::string& err) {
    outBackup.clear();
    err.clear();          // 成功时不留上一次的失败文案（调用方可能在同一个 err 上复用）

    // ① 校验必须是第一道闸门。过了才允许挂载/替换 —— 顺序即安全边界。
    const VerifyResult vr = verify_downloaded_file(dmgPath, expectedSha256, expectedSize);
    if (!vr.ok) {
        err = vr.error;                  // 调用方负责丢弃 dmg 文件
        return false;                    // ← 绝不进入 ②③
    }

    // ② 挂载
    std::string srcApp;
    if (!mount_image(dmgPath, mountPoint, srcApp, err)) return false;

    // ③ 安装（内部备份 + 失败回滚）
    std::string backup;
    const bool ok = install_app_bundle(srcApp, targetApp, backup, err);
    outBackup = backup;

    // ④ 无论成败都卸载（否则会残留挂载点）
    std::string uerr;
    if (!unmount_image(mountPoint, uerr)) {
        if (ok) { err = uerr; return false; }        // 装成功但没卸干净 → 报失败让人看到
    }
    return ok;
}

// ---------------------------------------------------------------------------
// 一键更新（异步）：下载 → 校验 → 挂载 → 替换 → 提示重启
// ⚠️ 任何一步失败都**立即中止**且不碰现有 .app（除替换阶段的备份回滚）。
// ---------------------------------------------------------------------------
void begin_install(const CheckResult& plan, ProgressFn progress, InstallFn done) {
    // 先做一次纯本地合法性检查：只有 UpdateAvailable 才允许安装
    if (plan.decision != Decision::UpdateAvailable) {
        if (done) done(false, @"没有可用的更新计划");
        return;
    }
    if (!update_download_url_allowed(plan.downloadUrl)) {
        if (done) done(false, @"下载地址不在白名单，已拒绝");
        return;
    }
    if (!is_hex64(plan.sha256)) {
        if (done) done(false, @"清单未提供合法的 sha256，已拒绝安装");
        return;
    }

    const std::string tmpDir = rta::platform::temp_dir_utf8();
    if (tmpDir.empty()) { if (done) done(false, @"没有可用的临时目录"); return; }
    const std::string dmgPath = rta::platform::join(tmpDir, "rlplayer-update.dmg");
    const std::string mntPath = rta::platform::join(tmpDir, "rlplayer-update-mnt");

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        auto report = [&](const char* stage, const std::string& d, int pct) {
            NativeProgress p; p.stage = stage; p.detail = d; p.percent = pct;
            if (progress) progress(p);
        };

        const Config cfg = detail_native::LoadConfig();
        const std::string token = cfg.hasToken ? cfg.token : std::string();

        // ---------- 1. 下载 ----------
        report("downloading", "正在下载 " + plan.remoteVersion + " …", 0);
        ::unlink(dmgPath.c_str());
        const auto dl = detail_native::Fetch(plan.downloadUrl, token, 120000);
        if (!dl.ok || dl.status < 200 || dl.status >= 300) {
            // 失败可重试（不改状态、不写"已是最新"）
            std::string msg = (dl.status == 401 || dl.status == 403)
                                  ? "下载失败：鉴权被拒（检查 update.conf）"
                                  : "下载失败（可重试）";
            if (dl.status > 0) msg += " HTTP " + std::to_string(dl.status);
            if (done) done(false, [NSString stringWithUTF8String:msg.c_str()]);
            return;
        }
        // 落盘（二进制安全）
        {
            FILE* f = ::fopen(dmgPath.c_str(), "wb");
            if (!f) { if (done) done(false, @"无法写入临时文件"); return; }
            const size_t n = dl.body.empty() ? 0 : std::fwrite(dl.body.data(), 1, dl.body.size(), f);
            const bool wok = (n == dl.body.size());
            std::fclose(f);
            if (!wok) { ::unlink(dmgPath.c_str()); if (done) done(false, @"下载写入不完整，已丢弃"); return; }
        }
        report("downloading", "下载完成（" + std::to_string((long long)dl.body.size()) + " 字节）", 40);

        // ---------- 2. 校验（篡改/截断必失败 ⟹ 丢弃，绝不挂载）----------
        report("verifying", "正在校验 sha256 …", 50);
        const VerifyResult vr = verify_downloaded_file(dmgPath, plan.sha256, plan.size);
        if (!vr.ok) {
            ::unlink(dmgPath.c_str());                       // ← 关键：失败即丢弃
            if (done) done(false, [NSString stringWithUTF8String:("校验失败，已丢弃：" + vr.error).c_str()]);
            return;
        }
        report("verifying", "sha256 校验通过", 60);

        // ---------- 3+4. 挂载 → 备份 → 替换 → 卸载（复用有序流水线，杜绝两份实现漂移）----------
        // ⚠️ 这里调的是 install_from_local_dmg，它内部第一件事就是再校验一次 sha256。
        //    上面第 2 步的校验是"早失败早丢弃"；这里是"替换前的最后一道闸门"。
        //    两道关卡共用同一个实现 ⟹ 不可能出现"一处放宽了另一处没放宽"。
        report("installing", "正在安装…", 80);
        const std::string target = detail_native::InstallTargetPath();
        std::string backup, ierr;
        const bool installed = install_from_local_dmg(dmgPath, plan.sha256, plan.size,
                                                     mntPath, target, backup, ierr);
        ::unlink(dmgPath.c_str());
        ::rmdir(mntPath.c_str());
        if (!installed) {
            if (done) done(false, [NSString stringWithUTF8String:ierr.c_str()]);
            return;
        }
        fprintf(stderr, "RLPlayer: 更新已安装到 %s（备份：%s）\n",
                target.c_str(), backup.empty() ? "无（全新安装）" : backup.c_str());
        report("done", "安装完成，请手动重启 RLPlayer", 100);

        // ---------- 5. 提示用户重启（**绝不自己重启**：会被 TCC/签名拦）----------
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert* a = [[NSAlert alloc] init];
            a.messageText = @"更新已安装";
            a.informativeText = [NSString stringWithFormat:
                @"RLPlayer %s 已安装。请退出并重新打开 RLPlayer 以完成更新。\n\n"
                @"（程序不会自动重启：macOS 的 TCC/签名机制会拦截自我重启。）",
                plan.remoteVersion.c_str()];
            [a addButtonWithTitle:@"好"];
            [a runModal];
            if (done) done(true, @"更新已安装，请手动重启");
        });
    });
}

} // namespace rta::update
