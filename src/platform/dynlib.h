// dynlib.h — 动态库加载（平台层契约，跨平台）
//
// 用途：GPU 加速后端是"锦上添花"的 DLL/SO（rtagpu.dll / rtagpu_dx12.dll / rtagpu_cuda.dll /
// librtagpu.so）。管线在链接期【不】依赖它们，运行时按需加载，找不到就退回 CPU。
//
// 语义要点（Mac 组必须一致）：
//   * open 失败不抛异常，返回 false，last_error() 给出原因
//   * symbol 失败返回 nullptr（调用方据此判定"符号缺失"并退回 CPU）
//   * 析构 = 卸载（除非 detach()）
//   * detach() = 放弃所有权，模块保持加载（迁移前 LoadLibrary 后不 Free 的语义）
#pragma once
#include <string>

namespace rta::platform {

class SharedLib {
public:
    SharedLib() = default;
    ~SharedLib();
    SharedLib(const SharedLib&) = delete;
    SharedLib& operator=(const SharedLib&) = delete;
    SharedLib(SharedLib&& o) noexcept;
    SharedLib& operator=(SharedLib&& o) noexcept;

    bool open(const char* filename);   // 已打开则先 close()
    void close();
    bool is_open() const;
    void* symbol(const char* name) const;   // 失败返回 nullptr
    void* detach();                         // 交出句柄，模块保持加载
    const std::string& last_error() const;

private:
    void* handle_ = nullptr;
    std::string err_;
};

} // namespace rta::platform

// macOS 实现（PLATFORM.md §9）。2026-10-25 项目转 macOS 单平台：Windows 分派支与 #else/#error 兜底已删除。
#include "platform/macos/dynlib_posix.h"
