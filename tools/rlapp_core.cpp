// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// rlapp_core.cpp — 进程内后端核心的「库构建形态」翻译单元
//
// 为什么是「#include 一个 .cpp」而不是把业务代码拆成 .h/.cpp：
//   rtaweb.cpp 有 6000+ 行、1517 个全局符号、几十处文件内 static 状态（播放线程、队列、
//   写回批任务、输入采集、PEQ 单例…）。把它拆成头/实现是**大规模重构**，风险与收益完全
//   不成比例 —— 本轮的目标是「去掉多余的服务进程」，不是「重排 6000 行」。
//   单翻译单元方案让 embedded 与 CLI 跑的是**逐字节同一份**业务代码：
//   没有第二份 handle()、没有第二份播放线程、不可能两边语义漂移。
//
// 只有一处条件编译：rtaweb.cpp 末尾的 main() 在 RLPLAYER_EMBEDDED_LIBRARY 下被屏蔽，
// 否则会和 rlapp_cli.cpp 的 main() 重复定义（那是链接错误，不是「两个入口」）。
//
// 构建方式（主控在 CMakeLists 里接线；本文件不改 CMake）：
//   add_library(rlapp_core STATIC tools/rlapp_core.cpp)
//   target_include_directories(rlapp_core PUBLIC ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools)
//   target_link_libraries(rlapp_core PUBLIC ${RL_PLATFORM_LIBS})
//   # 壳：add_executable(rlplayer_mac tools/mac_host.mm) + target_link_libraries(... rlapp_core)
//   # CLI：add_executable(rtaweb tools/rlapp_cli.cpp) + target_link_libraries(... rlapp_core)
#define RLPLAYER_EMBEDDED_LIBRARY 1
#include "rtaweb.cpp"
