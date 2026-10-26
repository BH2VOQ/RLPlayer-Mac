// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// platform/macos/console_posix.h — console.h 的 POSIX/macOS 实现
//
// POSIX 终端本来就是 UTF-8，无需切代码页（PLATFORM.md §9 第 3 条）。
// 返回 true 表示"输出编码已是 UTF-8"，与 Windows 侧"切换成功"语义对齐。
#pragma once

namespace rta::platform {

inline bool enable_utf8_console() {
    // 不做任何事：macOS 的 Terminal / iTerm 默认 UTF-8，且没有 CP_UTF8 这种全局代码页概念。
    // 保留返回值 true 让调用方可以无差别地写 if (!enable_utf8_console()) { ... }。
    return true;
}

} // namespace rta::platform
