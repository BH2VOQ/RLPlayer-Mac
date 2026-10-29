// SPDX-FileCopyrightText: 2026 rainlain <https://github.com/okhuoyanyan>
// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// console.h — 控制台编码（平台层契约，跨平台）
//
// 现状：所有 CLI 入口（tools/*.cpp、tests/*.cpp）都自己写 SetConsoleOutputCP(CP_UTF8)，
// 有几处甚至为了避开 windows.h 手写 __declspec(dllimport) 声明。本接口是它们统一的目标，
// 本轮【不】批量改工具/测试（避免与 CI/测试分支撞车，见 PLATFORM.md §11 未做项）。
//
// 契约：把标准输出的编码切成 UTF-8（中文日志不乱码）；无控制台时安全失败（返回 false，不抛）。
#pragma once

namespace rta::platform {

bool enable_utf8_console();

} // namespace rta::platform

// macOS 实现（PLATFORM.md §9）。2026-10-25 项目转 macOS 单平台：Windows 分派支与 #else/#error 兜底已删除。
#include "platform/macos/console_posix.h"
