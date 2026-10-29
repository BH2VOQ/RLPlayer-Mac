// SPDX-FileCopyrightText: 2026 rainlain <https://github.com/okhuoyanyan>
// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// host_msg.h — 宿主（launcher）与页面之间的 postMessage 协议解析（261024-02 #2）
//
// 为什么单独抽出来：页面里点资料链接要交给**系统浏览器**打开。协议白名单（只放 http/https）
// 是安全边界 —— 必须能被单元测试直接验证，而不是"藏在 launcher.cpp 的 lambda 里只能靠肉眼看"。
// 这里只做**纯字符串解析与判定**，不做任何系统调用（真正的 ShellExecuteW 在 launcher 里）。
#pragma once

#include <string>

namespace rta::platform {

enum class HostAction {
    None,        // 不认识的消息
    Minimize,
    Maximize,
    Close,
    Drag,
    Theme,
    OpenUrl,
    Resize,       // arg: left/right/top/bottom/topleft/topright/bottomleft/bottomright
    PickDir,      // 2026-10-25：打开原生「选择文件夹」面板（用户要求可点击选目录）
    // 2026-10-26 F-4 自动更新（用户要求「云端发布更新 → 自动提示 → 客户端一键更新」）
    UpdateCheck,  // 查一次更新（异步：结果通过 update:status:* 回传页面）
    UpdateInstall,// 一键更新：下载 → 校验 sha256 → 挂载 dmg → 替换 .app → 提示重启
    // 2026-10-26 邮件反馈通道（用户要求「客户端写反馈 → 收件人 BH2VOQ@163.com → 诊断包作附件」）
    //
    // ⚠️ 安全设计的核心：**收件人不在消息里**。
    //    下面三条都是**无收件人参数**的命令 —— 收件人是 rta::feedback::kRecipient 代码常量，
    //    页面即便被注入脚本也改不了"发给谁"。同理页面的任何输入都只能进"正文"与"诊断包路径"，
    //    两者都在宿主侧被清洗（长度/控制字符/路径白名单），不可能是任意收件人或任意文件。
    FeedbackCompose,    // 写反馈：body 见 HostMessage::arg，是否附诊断包见 attach_diag
    FeedbackDiagOnly    // 只发诊断包（不写正文）：走同一套检查，正文用固定说明
};

struct HostMessage {
    HostAction action = HostAction::None;
    std::string arg;       // Theme: "dark"/"light"/"blue"；OpenUrl: 完整 URL；FeedbackCompose: 反馈正文
    bool allowed = true;   // OpenUrl 专用：协议是否通过白名单
    std::string reason;    // allowed=false 时的原因（写进 launcher.log）

    // ---- 2026-10-26 邮件反馈通道 ----
    // 注意这些字段都是**页面给的原值**，尚未清洗。真正的清洗在宿主侧
    // （rta::feedback::sanitize_body / check_attachment_path），这样纯字符串规则能被单测覆盖，
    // 而本头文件保持"只解析、不改写"的既有定位（它现在也确实是纯解析）。
    bool attach_diag = false;   // FeedbackCompose/FeedbackDiagOnly: 是否把诊断包作为附件
    std::string diag_path;      // 页面侧已写好的诊断包临时文件路径（宿主会校验它在临时目录内）
};

// 外链协议白名单：只允许 http:// 与 https://（大小写不敏感）。
// 明确拒绝 file: / javascript: / data: / vbscript: / ftp: / 相对路径 / 带换行的注入。
inline bool external_url_allowed(const std::string& url) {
    if (url.empty() || url.size() > 4096) return false;
    for (char c : url) {
        if (c == '\n' || c == '\r' || c == '\t' || c == ' ') return false;   // 空白/换行 = 注入企图
    }
    auto starts = [&](const char* p) {
        size_t n = std::char_traits<char>::length(p);
        if (url.size() < n) return false;
        for (size_t i = 0; i < n; ++i) {
            char a = url[i], b = p[i];
            if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
            if (b >= 'A' && b <= 'Z') b = (char)(b - 'A' + 'a');
            if (a != b) return false;
        }
        return true;
    };
    if (!starts("http://") && !starts("https://")) return false;
    // 必须真的有主机名（"http://" 后面不能立刻是 / 或结束）
    size_t host = url.find("://") + 3;
    return host < url.size() && url[host] != '/' && url[host] != '?';
}

inline HostMessage parse_host_message(const std::string& m) {
    HostMessage r;
    if (m == "min") { r.action = HostAction::Minimize; return r; }
    if (m == "max") { r.action = HostAction::Maximize; return r; }
    if (m == "close") { r.action = HostAction::Close; return r; }
    if (m == "drag") { r.action = HostAction::Drag; return r; }
    // 2026-10-25（用户要求「要让用户可以通过点击文件夹来选择」）：
    // 页面请求宿主弹原生「选择文件夹」面板。可选参数 = 初始目录。
    // 为什么必须走宿主：WKWebView 里 <input type=file webkitdirectory> 只能选**文件**
    // 不能选空目录，也拿不到 macOS 的原生目录选择体验；NSOpenPanel 才是正解。
    if (m == "pickdir") { r.action = HostAction::PickDir; return r; }
    if (m.rfind("pickdir:", 0) == 0) {
        r.action = HostAction::PickDir;
        r.arg = m.substr(8);          // 初始目录（空 = 用默认位置）
        return r;
    }
    if (m.rfind("theme:", 0) == 0) {
        r.action = HostAction::Theme;
        r.arg = m.substr(6);
        return r;
    }
    // 261024-04 #1：窗口边缘拉伸。WebView2 的 3 个子窗口属于别的进程，原生 subclass 拿不到鼠标，
    // 所以由页面在 8 条 5px 热区上发起 resize:<dir>，宿主自己跟鼠标改窗口大小。
    // 方向做白名单，拼错/注入一律按 None（不动作、留 reason 进日志）。
    if (m.rfind("resize:", 0) == 0) {
        r.action = HostAction::Resize;
        r.arg = m.substr(7);
        static const char* const kDirs[] = {"left", "right", "top", "bottom",
                                            "topleft", "topright", "bottomleft", "bottomright"};
        bool ok = false;
        for (const char* d : kDirs) { if (r.arg == d) { ok = true; break; } }
        if (!ok) { r.action = HostAction::None; r.reason = "unknown resize dir"; }
        return r;
    }
    if (m.rfind("openurl:", 0) == 0) {
        r.action = HostAction::OpenUrl;
        r.arg = m.substr(8);
        r.allowed = external_url_allowed(r.arg);
        if (!r.allowed) r.reason = "scheme not allowed (only http/https)";
        return r;
    }
    // 2026-10-26 F-4 自动更新。两条都是**无参**命令：
    //   "update:check"   → 查一次（页面启动后调一次，也允许用户手动点「检查更新」）
    //   "update:install" → 一键更新（下载/校验/挂载/替换）
    // 为什么无参：更新地址与 token 只能来自 .app 外的 update.conf 与代码常量，
    // **绝不接受页面传 URL** —— 否则网页侧任何脚本都能命令宿主下载任意文件。
    if (m == "update:check")   { r.action = HostAction::UpdateCheck;   return r; }
    if (m == "update:install") { r.action = HostAction::UpdateInstall; return r; }

    // ---------------- 2026-10-26 邮件反馈通道 ----------------
    // 协议形态（**收件人永远不出现** —— 那是代码常量）：
    //   "feedback:compose"                  → 无附件，正文为空 ⟹ 宿主会拒绝并提示"请先写反馈内容"
    //   "feedback:compose:<正文>"            → 正文是页面给的（宿主清洗：控制字符/8000 字上限）
    //   "feedback:compose+zip:<正文>"        → 同样是正文，但**声明**要附诊断包；
    //                                         诊断包路径由后面的 "|diag:<路径>" 段单独给
    //   "feedback:diagonly"                 → 只发诊断包
    //   "feedback:diagonly|diag:<路径>"      → 只发诊断包 + 指定路径
    //
    // 为什么把"附诊断包"和"路径"拆成两段：路径里可能含任何字符（含 '|' 之外的冒号、
    // 空格、中文），如果和正文挤在一个冒号分隔里就没法可靠切分。
    // 分段规则：第一个 ':' 之后到 "|diag:" 之前 = 正文；"|diag:" 之后到结尾 = 路径。
    //
    // ⚠️ 这里**不做**任何"这看起来像不像合法正文"的判断 —— 那是宿主/纯逻辑层的事。
    //    本函数只负责把两段原值取出来；若页面没按格式写，取出来的就是空串/None，
    //    宿主侧 sanitize_body 会把它判成"空反馈"并拒绝发信（不会静默发一封空邮件）。
    if (m.rfind("feedback:", 0) == 0) {
        std::string rest = m.substr(9);          // "compose" / "compose:..." / "diagonly..."
        // 先切出可选的 "|diag:<path>" 尾巴
        std::string diag;
        const std::string dtag = "|diag:";
        const std::size_t dpos = rest.find(dtag);
        if (dpos != std::string::npos) {
            diag = rest.substr(dpos + dtag.size());
            rest = rest.substr(0, dpos);
            r.diag_path = diag;
            r.attach_diag = true;
        }
        if (rest == "diagonly") {
            r.action = HostAction::FeedbackDiagOnly;
            r.attach_diag = true;                // 这条命令的语义就是"必须带诊断包"
            return r;
        }
        if (rest == "compose" || rest == "compose+zip") {
            r.action = HostAction::FeedbackCompose;
            if (rest == "compose+zip") r.attach_diag = true;
            return r;
        }
        if (rest.rfind("compose:", 0) == 0) {
            r.action = HostAction::FeedbackCompose;
            r.arg = rest.substr(8);              // 正文原值（未清洗）
            return r;
        }
        if (rest.rfind("compose+zip:", 0) == 0) {
            r.action = HostAction::FeedbackCompose;
            r.arg = rest.substr(12);
            r.attach_diag = true;
            return r;
        }
        // 形态不认识 ⟹ 不动作（留 reason 进日志），绝不"猜一个"发出去
        r.action = HostAction::None;
        r.reason = "unknown feedback command";
        return r;
    }
    return r;
}

} // namespace rta::platform
