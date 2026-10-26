// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// time.h — 单调时钟（平台层契约，跨平台）
//
// 为什么需要它：内核里有两处用"开机以来的毫秒数"当随机盐/超时基准
// （net/subsonic.h 的认证盐、net/upnp.h 的发现超时）。Windows 上是 GetTickCount64()，
// POSIX 上是 clock_gettime(CLOCK_MONOTONIC)。std::chrono::steady_clock 看似可以替代，
// 但它的 epoch 与取值刻度由实现定义 —— 想保持行为逐位等价就不能偷换成 chrono。
//
// 契约：单调递增、不回退；单位毫秒；溢出/回绕不在本层处理（64 位够用 5 亿年）。
#pragma once
#include <cstdint>

namespace rta::platform {

uint64_t monotonic_ms();

} // namespace rta::platform

// macOS 实现（PLATFORM.md §9）。2026-10-25 项目转 macOS 单平台：Windows 分派支与 #else/#error 兜底已删除。
#include "platform/macos/time_posix.h"
