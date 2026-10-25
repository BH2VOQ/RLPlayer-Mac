// gpu_pref.h — GPU 后端偏好（AMD / NVIDIA / 自动 / 关闭）
//
// 为什么需要它：不同厂商的加速后端导出符号完全一样，所以"选哪张卡/哪个后端"
// 只需要换加载的库名字。
// 注意：选了一个没有对应后端的厂商，不会报错崩掉，而是如实退回 CPU 并在信号链里写清楚。
//
// ---- 2026-10-25：macOS 单平台化 ----
// 平台文件名映射：Windows 用 rtagpu.dll，macOS 用 librtagpu.dylib。
// 之前这里恒返回 Windows 名字，macOS 上 dlopen("rtagpu.dll") 必然失败 ⟹ GPU 永远不可用。
// 现在候选名在返回前统一过一遍 rta::platform::lib_name_for()：
//   "rtagpu"            -> "librtagpu.dylib"
//   "rtagpu_cuda"       -> "librtagpu_cuda.dylib"
//   已带 .dylib 后缀的   -> 原样返回
// 同时补上 dlopen 的真实搜索路径：dlopen 不会像 Windows 那样先找"可执行文件所在目录"，
// 所以把 @executable_path / @loader_path 的形式也放进候选（见 macOS 分支）。
//
// 返回值类型必须是 std::vector<std::string>（不能是 const char*）：
// 拼接出来的名字是临时 std::string，返回其 .c_str() 会立刻悬垂。
#pragma once
#include <string>
#include <vector>
#include "platform/dynlib.h"   // 提供 rta::platform::lib_name_for()（macOS/POSIX 实现）

namespace rta::dsp {

inline std::string& gpu_vendor_ref() {
    static std::string v = "auto";
    return v;
}
inline void set_gpu_vendor(const std::string& v) { gpu_vendor_ref() = v; }
inline const std::string& gpu_vendor() { return gpu_vendor_ref(); }

// 把一批"库基名"映射成当前平台的文件名（Windows: 原样 .dll；macOS: lib*.dylib）
inline std::vector<std::string> gpu_map_names(const std::vector<const char*>& bases) {
    std::vector<std::string> out;
    out.reserve(bases.size());
    for (const char* b : bases) {
#if defined(__APPLE__)
        const std::string nm = rta::platform::lib_name_for(b);
#else
        const std::string nm = b ? b : "";
#endif
        if (!nm.empty()) out.push_back(nm);
    }
    return out;
}

// 按偏好给出要尝试的库名（按顺序）
inline std::vector<std::string> gpu_dll_candidates() {
    const std::string& v = gpu_vendor();
    if (v == "off") return {};

#if defined(__APPLE__)
    // macOS：只有一个后端（Metal），且只有一个候选名。
    // 不保留 rtagpu_dx12 / rtagpu_cuda 的 macOS 名字：本机既无 D3D12 也无 CUDA，
    // 让候选表里出现永远不会存在的名字只会污染状态栏文案。
    // 厂商偏好（amd/nvidia）在 macOS 上没有意义 —— 无论选哪个都返回同一个 Metal 后端，
    // 因为 Metal 就是 Apple GPU 唯一的编程接口。
    (void)v;
    std::vector<std::string> out;
    // 先按 dlopen 搜索顺序（DYLD_LIBRARY_PATH / 当前工作目录 / 系统路径）
    out.push_back("librtagpu.dylib");
    // 再按 .app 包内位置（发布版把 dylib 放在 Contents/MacOS/ 或 Contents/Frameworks/）
    out.push_back("@executable_path/librtagpu.dylib");
    out.push_back("@executable_path/../Frameworks/librtagpu.dylib");
    return out;
#else
    // 顺序：HIP（AMD）→ D3D12（AMD/NVIDIA/Intel 通用）→ CUDA（可选）
    if (v == "amd")                     return gpu_map_names({ "rtagpu.dll", "rtagpu_dx12.dll" });
    if (v == "nvidia" || v == "cuda")   return gpu_map_names({ "rtagpu_cuda.dll", "rtagpu_dx12.dll" });
    return gpu_map_names({ "rtagpu.dll", "rtagpu_dx12.dll", "rtagpu_cuda.dll" });   // auto
#endif
}

} // namespace rta::dsp
