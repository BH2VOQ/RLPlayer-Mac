// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// platform/macos/path_posix.h — path.h 的 POSIX/macOS 实现
//
// 与 Windows 实现的语义对齐点（PLATFORM.md §3.1 / §6.2）：
//   * module_dir_utf8：可执行文件所在目录，【无】尾分隔符
//   * temp_dir_utf8  ：系统临时目录，【带】尾分隔符（= GetTempPathW 语义，写回直接拼后缀）
//   * config_dir_utf8 / data_dir_utf8：~/Library/Application Support/RLPlayer
//
// 与 Windows 的差异（如实记录，PLATFORM.md §6.2 已批准）：
//   Windows 是便携式（配置与数据都在 exe 同目录）；macOS 按 Apple 惯例落到
//   ~/Library/Application Support/RLPlayer。宿主【必须】在启动时把 MetaStore 的 baseDir
//   显式指到 data_dir_utf8()/rlplayer-meta —— 否则会落到当前工作目录（双击启动时是 "/"）。
#pragma once
#include <cstdlib>
#include <string>
#include <sys/stat.h>

#include <mach-o/dyld.h>

namespace rta::platform {

// 可执行文件所在目录（UTF-8，无尾分隔符；失败返回空串）
inline std::string module_dir_utf8() {
    // _NSGetExecutablePath 需要"先问大小再取"，且返回的可能是相对路径或含符号链接，
    // 因此再过一道 realpath 归一化（与 GetModuleFileNameW 的绝对路径语义对齐）。
    uint32_t size = 0;
    ::_NSGetExecutablePath(nullptr, &size);           // 只为拿 size，必然失败
    if (size == 0) return "";
    std::string buf(size, '\0');
    if (::_NSGetExecutablePath(buf.data(), &size) != 0) return "";
    buf.resize(std::char_traits<char>::length(buf.c_str()));

    // realpath 展开符号链接与 ".."，得到真正的绝对路径
    char resolved[PATH_MAX] = {0};
    if (::realpath(buf.c_str(), resolved) != nullptr) buf.assign(resolved);

    const size_t slash = buf.find_last_of('/');
    if (slash == std::string::npos) return "";
    if (slash == 0) return "/";                       // 根目录下的可执行文件
    return buf.substr(0, slash);
}

// 语义 = GetTempPathW：返回值【带尾分隔符】
inline std::string temp_dir_utf8() {
    // TMPDIR 在 macOS 上由 launchd 注入（形如 /var/folders/xx/.../T/），
    // 与 NSTemporaryDirectory() 同源；取不到时退回 /tmp。
    const char* env = std::getenv("TMPDIR");
    std::string dir = (env && *env) ? std::string(env) : std::string("/tmp/");
    if (dir.empty()) return "/tmp/";
    if (dir.back() != '/') dir.push_back('/');
    return dir;
}

// ~/Library/Application Support/RLPlayer（按需创建，失败则退回 HOME）
inline std::string app_support_dir_utf8() {
    const char* home = std::getenv("HOME");
    if (!home || !*home) return "";
    std::string dir = join(std::string(home), "Library");
    dir = join(dir, "Application Support");
    dir = join(dir, "RLPlayer");
    // 递归创建（mkdir 逐级，失败不致命 —— 调用方写文件时会再报错）
    std::string acc;
    for (size_t i = 0; i < dir.size(); ++i) {
        acc.push_back(dir[i]);
        if (dir[i] == '/' && acc.size() > 1) ::mkdir(acc.c_str(), 0755);
    }
    ::mkdir(dir.c_str(), 0755);
    return dir;
}

inline std::string config_dir_utf8() { return app_support_dir_utf8(); }
inline std::string data_dir_utf8()   { return app_support_dir_utf8(); }

} // namespace rta::platform
