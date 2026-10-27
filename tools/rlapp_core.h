// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// rlapp_core.h — RLPlayer 单进程后端核心（进程内 embedded 接口）
//
// ============================ 这是给谁用的 ============================
// macOS 原生壳 tools/mac_host.mm（ObjC++）包含本头文件，把原本「spawn 一个 rtaweb 子进程
// + 走 127.0.0.1:8899 HTTP」的架构，改成「同一个进程内直接调 C++ 函数」：
//
//   旧：壳进程 ──posix_spawn──> rtaweb 子进程（bind 8899，HTTP 控制面，CoreAudio 播放）
//        界面 fetch http://127.0.0.1:8899/api/xxx
//
//   新：壳进程（= 后端，同一个进程）
//        WKURLSchemeHandler 收到 rlplayer://app/api/xxx
//          → rlapp::dispatch(HttpRequest{method,path,body}, ct) → 同一个 handle() 的返回值
//        /api/quit|/api/shutdown → rlapp::exit_requested() == true → 壳收尾 → stop_embedded()
//
// 单进程**只去掉「壳 + 后端」这层多余的服务进程**。程序内部的并行一点没动：
// 扫描线程池、播放线程、UPnP accept/worker、cast worker、后台元数据/资料整理线程
// 全部保留（见 stop_embedded 的注释）。
//
// ============================ 调用契约（重要）============================
//   start_embedded()   仅【主线程】调一次。初始化曲库/配置/OPRA/代理/MetaStore/PEQ/启动横幅。
//                      **绝不** bind/listen 本地 HTTP 端口，**绝不** fork/open 浏览器。
//   dispatch()         任意线程、可并发（WKURLSchemeHandler 有自己的工作线程池）。
//                      内部无全局请求大锁 —— 并发能力与旧 WebUi 的「每连接一个工作线程」等价。
//   exit_requested()   任意线程轮询。/api/quit 或 /api/shutdown 被处理过即为 true。
//   stop_embedded()    仅【主线程】调，且必须在「已停止接收新请求 + 已派发请求全部返回」之后。
//                      协作式收尾（置停止标志让播放/采集/扫描线程自己退），**绝不 force-kill**。
//                      幂等：重复调用安全。
//
// 生命周期顺序（壳侧照抄）：
//   1. rlapp::start_embedded()                       // 主线程
//   2. 起界面 / 注册 scheme handler，之后任意线程 dispatch()
//   3. 轮询到 rlapp::exit_requested()                // /api/quit 或 Dock 退出
//   4. 停掉新请求来源，等已派发任务收完
//   5. rlapp::stop_embedded()                        // 主线程，join 全部后台线程
//
// ============================ 兼容性 ============================
// 独立 CLI 仍然完整可用：rlapp::cli_main() 就是原来的 main()（独立 HTTP 服务 + 自动开浏览器
// + --port/--lan/--no-browser），tools/rtaweb.cpp 单独编译时仍产出真正的 main()。
// 功能一个没删：81 条 /api/* 路由、静态资源（/、/app.js、/favicon）、上传、诊断 zip 全部
// 走同一份 handle()。
#pragma once

#include <string>

#include "net/webui.h"      // rta::net::HttpRequest（-I src 提供；本头文件不自己定义它）

namespace rlapp {

// 初始化后端（曲库/配置/OPRA/代理/MetaStore/PEQ/启动横幅 + 空库首次扫描）。
// 不监听端口、不开浏览器。仅主线程调用；重复调用返回 true（幂等）。
bool start_embedded();

// 把一次请求交给现有 handle()。method/path/body 原样进入，二进制响应的 contentType 不变。
// 允许任意线程并发调用；不得在此加全局请求锁。
std::string dispatch(const rta::net::HttpRequest& request, std::string& contentType);

// /api/quit 或 /api/shutdown 是否被请求过。壳轮询它来触发收尾。
bool exit_requested();

// 提前通知核心准备退出（仅置 g_shutdown 标志并拒绝新工作，不等待或 join 线程）。
// 供宿主在排空 scheme worker 前尽早发起取消信号；由 rtaweb 实现，主线程调用；幂等。
void request_shutdown();

// 协作式收尾：停播放 → 停输入采集 → 收预解码 → 停/join 库扫描 → 收写回批任务。
// 仅主线程调用；幂等。不 force-kill 任何进程。
void stop_embedded();

// 原 rtaweb 的 main()。保留独立 HTTP 服务与「自动打开浏览器」行为。
int cli_main(int argc, char** argv);

// ---------------------------------------------------------------------------
// 并发观测（诊断用；dispatch 内部只做几次原子操作，无锁、无 syscall）
//
// 存在理由：本轮明确要求「不得把 dispatch 串行化」。这件事必须有**可测量的判据**，
// 不能靠代码审查说「我没加锁」（铁律 3：判据要能证明真东西）。tests/test_embedded_api.cpp
// 用它来断言「两个不同请求路径真的同时进入了 handle()」，而不是排队。
// 壳侧也可以在诊断页展示，作为「单进程没有把并行搞坏」的现场证据。
// ---------------------------------------------------------------------------
int       max_concurrent_dispatches();   // 历史峰值：同时在 handle() 里的最大请求数
long long dispatch_count();              // 累计分发次数
void      reset_dispatch_probe();        // 清零峰值与计数（测试/诊断复位用）

} // namespace rlapp
