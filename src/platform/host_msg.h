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
    UpdateInstall // 一键更新：下载 → 校验 sha256 → 挂载 dmg → 替换 .app → 提示重启
};

struct HostMessage {
    HostAction action = HostAction::None;
    std::string arg;       // Theme: "dark"/"light"/"blue"；OpenUrl: 完整 URL
    bool allowed = true;   // OpenUrl 专用：协议是否通过白名单
    std::string reason;    // allowed=false 时的原因（写进 launcher.log）
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
    return r;
}

} // namespace rta::platform
