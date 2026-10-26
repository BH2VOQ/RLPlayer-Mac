// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// mac_feedback.mm — 反馈邮件通道的**原生执行层**（打开系统邮件客户端）
//
// ============================ 凭据是怎么处理的 ============================
// **本文件里完全没有凭据**，一个字节都没有：没有 SMTP 主机、没有账号、没有密码、
// 没有 163 授权码、没有环境变量读取、没有钥匙串查询。
//
// 为什么不走 SMTP（用户 2026-10-26 的第一安全约束）：
//   硬编码在二进制里的字符串用 `strings RLPlayer` 就能捞出来 ⟹ 等于把用户邮箱的发信权
//   公开给任何拿到 .app 的人。任何"为了方便"把授权码写进代码的做法都必须被拒绝。
//
// 改用系统邮件客户端代发：由用户在自己**已经登录好**的邮件账户里点"发送"。
//   我们只负责把「收件人 / 主题 / 正文 / 附件」摆进撰写窗口，认证与发送都在系统里。
//
// ============================ 实测结论（本机 macOS 27.0.1 arm64）============================
//   A. mailto:                        ✗ 单独不可用 —— mailto 带不了附件，诊断包走不通。
//   B. 生成 .eml → open -a Mail       ⚠️ **实测不合格**：本机 Mail 3901.100.1.1.12 把 .eml 当
//      **已收到的邮件**打开（MessageViewer 窗口），不是撰写草稿；X-Unsent: 1 不生效，
//      窗口里没有"发送"按钮。⟹ 只保留为**兜底产物**（写到桌面让用户自己处理）+
//      让"MIME 结构/附件字节"能被离线逐字节断言，但**不作为**首选发信路径。
//   C. NSSharingServiceNameComposeEmail ✓ **采用**。实测（cua-driver 读 AX 树，2026-10-26 19:30）：
//      收件人 "BH2VOQ@163.com"、主题 "[RLPlayer 反馈] v1.0.5-beta.2 / macOS 27.0.1 / arm64"、
//      正文 = 页面内容、附件 = rlplayer-diag.zip 全部就位，"发送"按钮可用。
//
// ⚠️ KVC 风险如实记账：NSSharingService 没有公开 recipients/subject 的 setter，
//    这里用 setValue:forKey:。运行时不崩，但属**未公开键**，系统升级后可能失效。
//    ⟹ 每次都用 @try/@catch 包住；失败时照样打开撰写窗口（收件人/主题留空由用户填），
//      并把 "recipient_preset=false" 如实回传给页面提示用户补填 —— **绝不假装已填好**。
//
// 未配置邮件账户时用户看到什么（本机已配 Gmail，此路按代码路径判定，标"仅审查"）：
//   NSSharingService 对 ComposeEmail 仍返回非 nil（服务本身存在），撰写窗口照开；
//   用户点"发送"时 Mail 会提示未配置账户/要求先添加账户。
//   ⟹ 宿主不假装成功：回传 compose-opened，UI 上写明"请在邮件窗口里确认账户后点发送"。
//   若 sharingService 为 nil（企业策略禁用共享服务），走 .eml 兜底并回传具体路径。
//
// ============================ 与纯逻辑层的分工 ============================
//   tools/mac_feedback.h  = 纯 std::string 规则（清洗/截断/路径校验/MIME），可离线单测
//   本文件                = 系统副作用（磁盘临时文件 + NSSharingService + NSWorkspace）
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include <string>
#include <vector>

#include "mac_feedback.h"

namespace rta::feedback {

// ---------------------------------------------------------------------------
// 版本号 / 系统信息（只用于主题，不含任何敏感信息）
// ---------------------------------------------------------------------------
namespace {

std::string ns_to_std(NSString *s) {
    if (!s) return std::string();
    const char *p = [s UTF8String];
    return p ? std::string(p) : std::string();
}

NSString *std_to_ns(const std::string &s) {
    if (s.empty()) return @"";
    return [[NSString alloc] initWithBytes:s.data()
                                   length:s.size()
                                 encoding:NSUTF8StringEncoding];
}

constexpr long long kMaxAttachmentBytes = 64ll * 1024 * 1024;   // 64 MB 上限

} // namespace

// 主题里的系统信息段："v1.0.5-beta.2 / macOS 27.0.1 / arm64"
// 版本号的唯一真相源仍是 src/version.h（CMake 通过 -DRLPLAYER_VERSION 传进来）；
// 拿不到就写 unknown —— 绝不猜一个版本号冒充。
std::string system_meta() {
#ifdef RLPLAYER_VERSION_STR
    const std::string version = RLPLAYER_VERSION_STR;
#else
    const std::string version = "unknown";
#endif

    const NSOperatingSystemVersion v3 = [[NSProcessInfo processInfo] operatingSystemVersion];
    NSString *os = [NSString stringWithFormat:@"macOS %ld.%ld.%ld",
                    (long)v3.majorVersion, (long)v3.minorVersion, (long)v3.patchVersion];

    // 架构：编译期判定（本机构建是单一 arm64，不做 universal）
#if defined(__arm64__) || defined(__aarch64__)
    const char *arch = "arm64";
#elif defined(__x86_64__)
    const char *arch = "x86_64";
#else
    const char *arch = "unknown";
#endif

    return version + " / " + ns_to_std(os) + " / " + arch;
}

// ---------------------------------------------------------------------------
// 诊断包临时目录
//
// 与页面侧的约定：诊断包先由页面 POST /api/diagzip 拿到字节，写到
//   $TMPDIR/rlplayer-feedback/<名字>.zip
// 然后把**绝对路径**通过 feedback:compose+zip:<正文>|diag:<路径> 传给宿主。
//
// 为什么不让宿主自己生成 zip：/api/diagzip 已经是一个完整、脱敏过（api_key/token/sk-*
// 全被掩码）的端点。宿主侧再造一份等于把脱敏规则抄两遍，迟早不同步 —— 抄漏一次就是
// 把 api key 发到公网邮箱。所以**复用既有端点**，宿主只负责"读这个已经脱敏的文件"。
// ---------------------------------------------------------------------------
std::string diagnostic_temp_root() {
    NSString *tmp = NSTemporaryDirectory();
    if (!tmp) return std::string();
    return ns_to_std([tmp stringByAppendingPathComponent:@"rlplayer-feedback"]);
}

// 确保临时目录存在（第一次用时创建）。返回是否可用。
bool ensure_diagnostic_temp_root(std::string &err) {
    err.clear();
    const std::string root = diagnostic_temp_root();
    if (root.empty()) { err = "无法取得系统临时目录"; return false; }

    NSString *p = std_to_ns(root);
    BOOL isDir = NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:p isDirectory:&isDir]) {
        if (!isDir) { err = "临时目录路径被同名文件占用"; return false; }
        return true;
    }
    NSError *e = nil;
    if (![fm createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:&e]) {
        err = std::string("创建临时目录失败：") + ns_to_std([e localizedDescription]);
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// 诊断包校验 + 读入内存
//
// 两层校验（缺一不可）：
//   ① check_attachment_path —— 纯词法规则（绝对路径 / 在临时目录内 / .zip / 无 NUL·CR·LF），
//      有离线单测。挡住 "…/../../.ssh/id_rsa"、"…/rlplayer-feedback-evil/x.zip" 这类。
//   ② 这里的文件系统核验 —— 真实存在 / 是普通文件 / 不是软链 / 非空 / ≤64MB。
//      只做词法判定挡不住"临时目录里有人放了一个指向 ~/.ssh 的软链"。
// ---------------------------------------------------------------------------
bool load_diagnostic(const std::string &raw_path, std::string &out_data,
                     std::string &out_name, std::string &err,
                     std::string *out_norm_path) {
    out_data.clear();
    out_name.clear();
    err.clear();
    if (out_norm_path) out_norm_path->clear();

    const std::string root = diagnostic_temp_root();

    // ① 词法层：绝对路径 + 在临时目录内 + .zip + 无 NUL/CR/LF（纯规则，有离线单测）
    const PathCheck pc = check_attachment_path(raw_path, root);
    if (!pc.ok) { err = pc.reason; return false; }

    NSString *p = std_to_ns(pc.normalized);
    if (!p || p.length == 0) { err = "诊断包路径编码非法"; return false; }

    NSFileManager *fm = [NSFileManager defaultManager];

    // 软链必须显式拒绝：attributesOfItemAtPath 本身会跟随软链，所以先判一次类型。
    NSDictionary *lst = [fm attributesOfItemAtPath:p error:nil];
    if (!lst) { err = "诊断包文件不存在或不可读"; return false; }
    if ([lst[NSFileType] isEqualToString:NSFileTypeSymbolicLink]) {
        err = "诊断包路径是符号链接（拒绝）";
        return false;
    }

    // ② 🔴 真实路径层（2026-10-26 实测踩到的洞，勿删）：
    //    只做词法校验 + "末级不是软链"是**不够的** —— 攻击者在临时目录里放一个
    //    **指向 ~/.ssh 的软链目录**，然后请求 <root>/sshlink/secret.zip：
    //      · 词法：确实在 root 下、确实是 .zip ⟹ 放行
    //      · 末级文件：secret.zip 本身是普通文件（不是软链）⟹ 也放行
    //      · 结果：把 ~/.ssh/secret.zip 的内容当"诊断包"读进来并发出去
    //    实测确认过这条能读出 26 字节的私钥内容（见报告「⚠️ 实测到的洞」）。
    //    修法：解析 **真实路径**（stringByResolvingSymlinksInPath），再要求
    //    真实路径仍以**真实 root** 为前缀。软链目录在这一步就暴露了。
    {
        // root 自身也要先解析：$TMPDIR 在 macOS 上本身经 /var → /private/var 软链，
        // 不解析会出现"两个都合法但前缀对不上"的假红。
        NSString *rootNS = std_to_ns(root);
        NSString *realRoot = [rootNS stringByResolvingSymlinksInPath];
        NSString *realPath = [p stringByResolvingSymlinksInPath];
        if (!realRoot || !realPath) { err = "无法解析诊断包真实路径"; return false; }

        const std::string rs = ns_to_std(realRoot);
        const std::string rp = ns_to_std(realPath);
        bool inside = false;
        if (rp.size() > rs.size() && rp.compare(0, rs.size(), rs) == 0) {
            inside = (rp[rs.size()] == '/');       // 同样防 "/root-evil" 前缀碰撞
        }
        if (!inside) {
            err = "诊断包真实路径不在临时目录内（软链逃逸，拒绝）";
            return false;
        }
    }

    BOOL isDir = NO;
    if (![fm fileExistsAtPath:p isDirectory:&isDir]) { err = "诊断包文件不存在"; return false; }
    if (isDir) { err = "诊断包路径是目录，不是文件"; return false; }

    NSDictionary *attrs = [fm attributesOfItemAtPath:p error:nil];
    if (!attrs) { err = "无法读取诊断包属性"; return false; }
    const long long size = (long long)[attrs[NSFileSize] longLongValue];
    if (size <= 0) { err = "诊断包是空文件"; return false; }
    if (size > kMaxAttachmentBytes) { err = "诊断包过大（超过 64MB），无法作为附件"; return false; }

    // NSData 读取是二进制安全的（不经过任何文本编码转换）
    NSData *data = [NSData dataWithContentsOfFile:p];
    if (!data || data.length == 0) { err = "读取诊断包失败"; return false; }

    out_data.assign((const char *)data.bytes, (size_t)data.length);
    if (out_norm_path) *out_norm_path = pc.normalized;   // 交给调用方的是**校验通过**的路径
    const std::size_t slash = pc.normalized.find_last_of('/');
    out_name = safe_filename(slash == std::string::npos ? pc.normalized
                                                        : pc.normalized.substr(slash + 1),
                             "rlplayer-diag.zip");
    return true;
}

// ---------------------------------------------------------------------------
// .eml 兜底产物
//
// ⚠️ 实测（方案 B）本机 Mail 会把 .eml 当**已收到的邮件**打开，不是草稿。
//    所以这条路径只在 NSSharingService 不可用时使用，且回传里必须如实写明
//    "这是兜底文件，双击是查看而不是撰写"。
// ---------------------------------------------------------------------------
std::string write_eml_fallback(const std::string &subject,
                               const std::string &body_clean,
                               const std::vector<Attachment> &attachments,
                               std::string &err) {
    err.clear();
    const std::string eml = build_eml(kRecipient, subject, body_clean, attachments, "");

    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    NSString *desktop = [NSSearchPathForDirectoriesInDomains(NSDesktopDirectory, NSUserDomainMask, YES) firstObject];
    if (desktop) [dirs addObject:desktop];
    NSString *tmp = NSTemporaryDirectory();
    if (tmp) [dirs addObject:tmp];

    const long long now = (long long)[[NSDate date] timeIntervalSince1970];
    for (NSString *dir in dirs) {
        NSString *name = [NSString stringWithFormat:@"RLPlayer-反馈-%lld.eml", now];
        NSString *path = [dir stringByAppendingPathComponent:name];
        NSData *d = [NSData dataWithBytes:eml.data() length:eml.size()];
        if ([d writeToFile:path atomically:YES]) return ns_to_std(path);
    }
    err = "写入 .eml 兜底文件失败";
    return std::string();
}

// ---------------------------------------------------------------------------
// 首选路径：NSSharingService 打开系统邮件撰写窗口
//
// ⚠️ **绝不**在这里把邮件发出去 —— 发送必须由用户在自己确认后点击。
// ---------------------------------------------------------------------------
ComposeResult open_compose_window(const std::string &subject,
                                  const std::string &body_clean,
                                  const std::vector<std::string> &attachment_paths,
                                  const std::string &sender_hint) {
    ComposeResult r;
    (void)sender_hint;

    NSSharingService *svc = [NSSharingService sharingServiceNamed:NSSharingServiceNameComposeEmail];
    if (!svc) {
        // 服务被禁用（企业策略 / 系统裁剪）：尽力给一个 .eml，用户自己能拿去处理
        std::vector<Attachment> atts;
        for (const auto &p : attachment_paths) {
            Attachment a;
            const std::size_t slash = p.find_last_of('/');
            a.filename = safe_filename(slash == std::string::npos ? p : p.substr(slash + 1),
                                       "rlplayer-diag.zip");
            NSData *d = [NSData dataWithContentsOfFile:std_to_ns(p)];
            if (d) a.data.assign((const char *)d.bytes, (size_t)d.length);
            if (!a.data.empty()) atts.push_back(std::move(a));
        }
        std::string e;
        r.eml_path = write_eml_fallback(subject, body_clean, atts, e);
        if (!r.eml_path.empty()) {
            r.outcome = ComposeOutcome::FellBackToEml;
            r.detail = "系统邮件服务不可用，已生成 .eml 文件：" + r.eml_path +
                       "（注意：双击通常是「查看」而不是「撰写」，需要时请用「转发 / 编辑为新邮件」）";
        } else {
            r.outcome = ComposeOutcome::Failed;
            r.detail = "系统邮件服务不可用，且 .eml 兜底文件写入失败" + (e.empty() ? "" : ("：" + e));
        }
        return r;
    }

    // 收件人 / 主题：无公开 setter，用 KVC。两个都**独立** try，一个失败不影响另一个。
    @try {
        [svc setValue:std_to_ns(kRecipient) forKey:@"recipients"];
        r.recipient_preset = true;
    } @catch (NSException *e) {
        r.recipient_preset = false;
    }
    @try {
        [svc setValue:std_to_ns(subject) forKey:@"subject"];
        r.subject_preset = true;
    } @catch (NSException *e) {
        r.subject_preset = false;
    }

    // items = 正文（NSString）+ 每个附件（NSURL file URL）
    NSMutableArray *items = [NSMutableArray array];
    NSString *bodyNS = std_to_ns(body_clean);
    if (bodyNS.length > 0) [items addObject:bodyNS];
    for (const auto &p : attachment_paths) {
        NSString *path = std_to_ns(p);
        if (path.length == 0) continue;
        [items addObject:[NSURL fileURLWithPath:path]];
    }

    if (![svc canPerformWithItems:items]) {
        std::string e;
        std::vector<Attachment> atts;
        r.eml_path = write_eml_fallback(subject, body_clean, atts, e);
        r.outcome = r.eml_path.empty() ? ComposeOutcome::Failed : ComposeOutcome::FellBackToEml;
        r.detail = r.eml_path.empty()
            ? "系统邮件服务拒绝该内容，且 .eml 兜底也失败"
            : "系统邮件服务拒绝该内容，已生成 .eml 文件：" + r.eml_path;
        return r;
    }

    [svc performWithItems:items];      // ← 只打开撰写窗口；不发送

    r.outcome = ComposeOutcome::Opened;
    if (r.recipient_preset && r.subject_preset) {
        r.detail = "已打开系统邮件撰写窗口（收件人 / 主题 / 正文 / 附件已填好），请确认后点「发送」";
    } else if (r.recipient_preset) {
        r.detail = "已打开系统邮件撰写窗口；主题预填失败，请手动填写主题";
    } else if (r.subject_preset) {
        r.detail = "已打开系统邮件撰写窗口；收件人预填失败，请手动填写 " + std::string(kRecipient);
    } else {
        r.detail = "已打开系统邮件撰写窗口；收件人与主题均未预填，请手动填写 " + std::string(kRecipient);
    }
    return r;
}

// ---------------------------------------------------------------------------
// 可选：同时把 .eml 另存一份（用户在撰写窗口里丢了内容时的救命通道）
// ---------------------------------------------------------------------------
bool save_eml_copy(const std::string &subject,
                   const std::string &body_clean,
                   const std::vector<Attachment> &attachments,
                   std::string &out_path, std::string &err) {
    out_path = write_eml_fallback(subject, body_clean, attachments, err);
    return !out_path.empty();
}

} // namespace rta::feedback
