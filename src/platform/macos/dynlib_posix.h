// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// platform/macos/dynlib_posix.h — dynlib.h 的 POSIX/macOS 实现（dlopen/dlsym/dlclose）
//
// 语义对齐（PLATFORM.md §3.3 / §9 第 5 条）：
//   * open 失败不抛，返回 false，last_error() 带 dlerror() 原文
//   * symbol 失败返回 nullptr（调用方据此退回 CPU）
//   * detach() = 放弃所有权、模块保持加载（GPU 桥接取到函数指针后绝不能卸载）
//
// 文件名映射（Windows 用 .dll，macOS 用 .dylib）：
//   Windows 侧候选名是 rtagpu.dll / rtagpu_dx12.dll / rtagpu_cuda.dll；
//   macOS 侧对应 librtagpu.dylib 等。本层提供 lib_name_for() 把"基名"变成平台文件名，
//   让 gpu_bridge 的候选名逻辑保持跨平台。
#include <dlfcn.h>
#include <string>

namespace rta::platform {

// 把"库基名"映射成当前平台的文件名。
//   "rtagpu"            -> "librtagpu.dylib"
//   已带 .dylib 后缀的    -> 原样返回（调用方显式指定时尊重它）
inline std::string lib_name_for(const char* base) {
    if (!base || !*base) return "";
    std::string s(base);
    if (s.size() > 6 && s.compare(s.size() - 6, 6, ".dylib") == 0) return s;
    return "lib" + s + ".dylib";
}

inline SharedLib::~SharedLib() { close(); }

inline SharedLib::SharedLib(SharedLib&& o) noexcept
    : handle_(o.handle_), err_(std::move(o.err_)) { o.handle_ = nullptr; }

inline SharedLib& SharedLib::operator=(SharedLib&& o) noexcept {
    if (this != &o) {
        close();
        handle_ = o.handle_;
        err_ = std::move(o.err_);
        o.handle_ = nullptr;
    }
    return *this;
}

inline bool SharedLib::open(const char* filename) {
    close();
    if (!filename || !*filename) { err_ = "dlopen: 文件名为空"; return false; }
    ::dlerror();                                   // 清掉历史错误，才能判断本次是否失败
    void* h = ::dlopen(filename, RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        const char* e = ::dlerror();
        handle_ = nullptr;
        err_ = std::string("dlopen 失败: ") + (e ? e : "未知原因");
        return false;
    }
    handle_ = h;
    err_.clear();
    return true;
}

inline void SharedLib::close() {
    if (handle_) { ::dlclose(handle_); handle_ = nullptr; }
}

inline bool SharedLib::is_open() const { return handle_ != nullptr; }

inline void* SharedLib::symbol(const char* name) const {
    if (!handle_ || !name) return nullptr;
    return ::dlsym(handle_, name);                 // 失败返回 nullptr，符合契约
}

inline void* SharedLib::detach() { void* h = handle_; handle_ = nullptr; return h; }

inline const std::string& SharedLib::last_error() const { return err_; }

} // namespace rta::platform
