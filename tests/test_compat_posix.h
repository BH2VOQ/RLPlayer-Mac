// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_compat_posix.h — 测试专用 POSIX 垫片（仅在非 Windows 上生效）
//
// 为什么需要它：tests/ 下有一批用例的**判据本身是跨平台的**（元数据合并、路径解析、
// 位流往返、索引分组……），只是夹具顺手用了 Win32 的临时目录/删文件/控制台编码 API。
// 这些 API 在 POSIX 上都有**语义等价物**，垫上之后用例测的东西一字不变。
//
// 为什么放在 tests/ 而不是 src/platform/：
//   * 这些是**测试夹具**用的便利函数（GetTempPathA 这种"带尾分隔符的临时目录"写法在
//     生产代码里没人用，生产层已经统一走 rta::platform::temp_dir_utf8()）；
//   * 放 src/platform/ 会让生产代码多出一批 Win32 命名符号，与「平台差异收进 platform 层」
//     的意图相反（生产层不该有 DeleteFileA 这种名字）；
//   * tests/ 是本包的写权范围，src/** 属其它工作包（见任务书白名单）。
//
// 铁律（不许放水）：本文件**只**做「同名同义」的映射，绝不构造假结果。
//   * 每个函数都是真实实现（真读环境、真删文件、真取临时目录）；
//   * 无法真实等价的（宽字符语义）用**本项目既有的字节保序约定**，不是凭空编的：
//     src/audio/audio_loader.h 的 POSIX 分支就是这么做的（widen/narrow 逐字节搬运，
//     UTF-8 字节进 wchar_t，wide_to_utf8 原样还原）。这里与之保持同一约定，
//     因此 GetTempPathW → wide_to_utf8 的往返是**可逆的真实转换**，不是丢弃信息。
//   * 若将来有测试需要真·宽字符语义（如 UTF-16 转码），**不要**在此扩展 —— 那说明该用例
//     本身是 Windows 专属，应走删除流程。
//
// 用法：在测试文件**最顶部**（其它 include 之前）加
//     #include "test_compat_posix.h"
#pragma once

#if !defined(_WIN32)

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

#include "platform/path.h"      // rta::platform::temp_dir_utf8() / module_dir_utf8()（真实 POSIX 实现）
#include "platform/process.h"   // rta::platform::find_executable()（SearchPathW 的真实实现）

// ---------------- 常量 ----------------
// 控制台代码页：POSIX 终端恒为 UTF-8，这个常量只为让源码里的 CP_UTF8 能编译
#ifndef CP_UTF8
#define CP_UTF8 65001
#endif
// 路径缓冲上限：Win32 的 MAX_PATH 是 260，POSIX 上是 PATH_MAX=1024。
// 这里取 4096 是**放大**而不是缩小（只会让缓冲更安全，不会让断言更容易过）
#ifndef MAX_PATH
#define MAX_PATH 4096
#endif

#ifndef DWORD
using DWORD = std::uint32_t;
#endif

namespace testcompat {

// UTF-8 窄串 -> 字节保序宽串（与 audio_loader.h POSIX 分支的 widen 同一约定）
inline std::wstring widen_bytes(const std::string& s) {
    return std::wstring(s.begin(), s.end());
}
// 字节保序宽串 -> UTF-8 窄串（widen 的严格逆运算）
inline std::string narrow_bytes(const std::wstring& w) {
    std::string s;
    s.reserve(w.size());
    for (wchar_t c : w) s += (char)(c & 0xFF);
    return s;
}

// 把 UTF-8 串拷进调用方的窄缓冲；返回写入的字节数（不含 NUL），失败返回 0
inline DWORD copy_utf8_into(char* buf, DWORD cap, const std::string& s) {
    if (buf == nullptr || cap == 0) return 0;
    if (s.size() + 1 > (size_t)cap) { buf[0] = '\0'; return 0; }
    std::memcpy(buf, s.data(), s.size());
    buf[s.size()] = '\0';
    return (DWORD)s.size();
}

// 把 UTF-8 串按字节保序拷进宽缓冲（供 GetTempPathW / GetModuleFileNameW 使用）
inline DWORD copy_bytes_into_wide(wchar_t* buf, DWORD cap, const std::string& s) {
    if (buf == nullptr || cap == 0) return 0;
    if (s.size() + 1 > (size_t)cap) { buf[0] = L'\0'; return 0; }
    for (size_t i = 0; i < s.size(); ++i) buf[i] = (wchar_t)(unsigned char)s[i];
    buf[s.size()] = L'\0';
    return (DWORD)s.size();
}

} // namespace testcompat

// ---------------- 控制台 ----------------
// POSIX 终端本来就是 UTF-8；返回 1 表示"无需切换"。这是**真实的空操作**，
// 不是伪造成功：Win32 上它的作用是切代码页，POSIX 上没有代码页可切。
static inline int SetConsoleOutputCP(int /*codepage*/) { return 1; }

// ---------------- 环境变量 ----------------
// 语义与 _putenv_s 一致：n 为空串等于删除该变量（_putenv_s 的文档行为）
static inline int _putenv_s(const char* name, const char* value) {
    if (name == nullptr) return 22 /*EINVAL*/;
    if (value == nullptr || value[0] == '\0') return unsetenv(name);
    return setenv(name, value, 1) == 0 ? 0 : errno;
}

// _dupenv_s：分配一份环境变量值的副本（调用方负责 free）。
// 变量不存在时把 *buffer 置 nullptr 并返回 0 —— 与 MSVC 行为一致
//（MSVC 在变量不存在时返回 0 且 *buffer=nullptr，不是错误码）。
static inline int _dupenv_s(char** buffer, size_t* numberOfElements, const char* varname) {
    if (buffer == nullptr) return 22;
    *buffer = nullptr;
    if (numberOfElements) *numberOfElements = 0;
    if (varname == nullptr) return 22;
    const char* v = std::getenv(varname);
    if (v == nullptr) return 0;
    const size_t n = std::strlen(v);
    char* copy = (char*)std::malloc(n + 1);
    if (copy == nullptr) return 12 /*ENOMEM*/;
    std::memcpy(copy, v, n + 1);
    *buffer = copy;
    if (numberOfElements) *numberOfElements = n + 1;
    return 0;
}

// ---------------- 临时目录 ----------------
// GetTempPathA 的返回值语义：写入的字节数（**带尾分隔符**，与 Win32 一致）
static inline DWORD GetTempPathA(DWORD cap, char* buf) {
    return testcompat::copy_utf8_into(buf, cap, rta::platform::temp_dir_utf8());
}
// 宽字符版本：按字节保序约定填充（配合 audio_loader.h 的 wide_to_utf8 往返无损）
static inline DWORD GetTempPathW(DWORD cap, wchar_t* buf) {
    return testcompat::copy_bytes_into_wide(buf, cap, rta::platform::temp_dir_utf8());
}

// ---------------- 文件 / 目录 ----------------
// 删除文件：成功返回非 0（Win32 语义），失败返回 0
static inline int DeleteFileA(const char* path) {
    if (path == nullptr) return 0;
    return std::remove(path) == 0 ? 1 : 0;
}
// POSIX 上原生路径就是 char*，所以 fs::path::c_str() 直接可传；
// 保留 W 名字只为让 Windows 写法的调用点不用改（W/A 在 POSIX 上合一）。
static inline int DeleteFileW(const char* path) { return DeleteFileA(path); }

// 建目录：已存在也算成功（Win32 的 CreateDirectoryA 会报 ERROR_ALREADY_EXISTS，
// 但测试夹具的用法都是"确保目录在"，这里对齐这个用法；返回非 0 = 目录已可用）
static inline int CreateDirectoryA(const char* path, void* /*sa*/ = nullptr) {
    if (path == nullptr) return 0;
    if (::mkdir(path, 0777) == 0) return 1;
    if (errno == EEXIST) return 1;
    return 0;
}

// ---------------- 进程 / 模块 ----------------
static inline DWORD GetCurrentProcessId() { return (DWORD)::getpid(); }

// 可执行文件的**完整路径**（不是目录）——对齐 Win32 GetModuleFileNameW(nullptr,...) 的语义。
// 调用方（test_ffmpeg_matrix 的 exe_dir）会自己对它做 find_last_of("\\/") 取目录，
// 所以这里必须给完整路径；只给目录会让那条取父目录的逻辑悄悄退化成上一级目录。
static inline std::string exe_path_utf8() {
#if defined(__APPLE__)
    std::uint32_t size = 0;
    ::_NSGetExecutablePath(nullptr, &size);          // 只为拿 size
    if (size == 0) return "";
    std::string buf(size, '\0');
    if (::_NSGetExecutablePath(buf.data(), &size) != 0) return "";
    buf.resize(std::char_traits<char>::length(buf.c_str()));
    char resolved[PATH_MAX] = {0};
    if (::realpath(buf.c_str(), resolved) != nullptr) return std::string(resolved);
    return buf;
#else
    char resolved[PATH_MAX] = {0};
    const ssize_t n = ::readlink("/proc/self/exe", resolved, sizeof(resolved) - 1);
    if (n <= 0) return "";
    return std::string(resolved, (size_t)n);
#endif
}

static inline DWORD GetModuleFileNameW(void* /*hModule*/, wchar_t* buf, DWORD cap) {
    const std::string p = exe_path_utf8();
    if (p.empty()) return 0;
    return testcompat::copy_bytes_into_wide(buf, cap, p);
}

// SearchPathW：在 exe 同目录 + PATH 里找可执行文件。
// POSIX 没有 .exe 后缀，所以把 ".exe" 当作"可有可无的后缀"：先去掉 .exe 找，再按原样找。
// 找到则返回完整路径长度（Win32 语义：不含 NUL），找不到返回 0。
// 注意：这里只做**查找**，不伪造"找到"——真找不到就返回 0，调用方照原逻辑走失败分支。
static inline DWORD SearchPathW(const wchar_t* /*lpPath*/, const wchar_t* lpFileName,
                                const wchar_t* lpExtension, DWORD cap, wchar_t* buf,
                                wchar_t** /*lpFilePart*/) {
    if (lpFileName == nullptr || buf == nullptr || cap == 0) return 0;
    const std::string name = testcompat::narrow_bytes(lpFileName);
    std::string found;
    // 先试去掉 .exe 的名字（POSIX 的可执行文件没有后缀）
    if (lpExtension != nullptr) {
        const std::string ext = testcompat::narrow_bytes(lpExtension);
        if (!ext.empty() && name.size() > ext.size() &&
            name.compare(name.size() - ext.size(), ext.size(), ext) == 0) {
            found = rta::platform::find_executable(
                name.substr(0, name.size() - ext.size()).c_str());
        }
    }
    if (found.empty()) found = rta::platform::find_executable(name.c_str());
    if (found.empty()) return 0;
    const DWORD n = testcompat::copy_bytes_into_wide(buf, cap, found);
    return n == 0 ? 0 : n;
}

#endif // !_WIN32
