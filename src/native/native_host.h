// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// native_host.h — 纯 AppKit UI 的唯一入口（P1，1.1.7）
//
// 为什么是 C 函数而不是 ObjC 类：编译单元 tools/native/native_host.mm 是 ObjC++，
// 但 tools/mac_host.mm 里只需要「起/停」两个动作；用 C 链接避免把 AppKit 类型
// 泄进宿主头文件，也不影响 test_mac_transport 以 #include mac_host.mm 方式复用。
//
// 双 UI 并行（功能不删除）：CMake 用 RLPLAYER_UI=web|native 决定 rlplayer_mac 链接
// 哪套界面。native 构建下不创建 WKWebView 主内容区；web 构建仍走原有 WKWebView。
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// 起原生纯 AppKit 界面。必须在 rlapp::start_embedded() 之后、主线程调用。
// 返回 YES/NO（BOOL 语义）；失败时宿主回退到 web 界面。
int rlnative_start(void);

// 供宿主退出轮询调用：原生窗口是否已被用户关闭（应触发优雅退出）。
int rlnative_should_terminate(void);

#ifdef __cplusplus
} // extern "C"
#endif
