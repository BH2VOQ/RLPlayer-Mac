// SPDX-FileCopyrightText: 2026 rainlain <https://github.com/okhuoyanyan>
// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// process.h — 子进程（平台层契约，跨平台）
//
// 用途：llm/ffmpeg/ffprobe 之类的【外部工具】调用。全是"跑一次、收退出码、收日志"，
// 不需要管道交互、不需要异步。
//
// 契约要点：
//   * 不弹窗、不接管标准输入、不继承控制台（Windows: CREATE_NO_WINDOW + SW_HIDE）
//   * 命令行是 UTF-8 单串（含引号规则已在调用方拼好）；平台层负责转原生编码
//   * capture=true 时合并捕获 stdout+stderr（原样字节，不转码、不裁剪）
//   * 返回 exit_code = -1 表示【启动失败】（进程根本没跑起来），与"退出码 -1"区分看 started
//   * 阻塞直到进程退出
//
// 两种等待语义（2026-10-31，1.1.1.4-beta「封面提取卡 UI」）：
//   * run_hidden          —— **不 kill**。调用方自己保证被调工具会退出（铁律 2）。
//   * run_hidden_timeout  —— 只处理【本函数自己 spawn 的那个 pid】超时：到点 SIGTERM →
//                            短暂等待 → 仍未退出再 SIGKILL → waitpid 回收。不碰进程组，
//                            也不把信号发给任何别的 pid。
//
// 为什么命令行不用 argv 数组：迁移前 writeback.h/audio_loader.h 拼的就是一整条命令行
//（CreateProcessW 语义），改成 argv 会重新引入引号/反斜杠转义差异的风险。
#pragma once
#include <string>

namespace rta::platform {

struct ProcessResult {
    int exit_code = -1;
    bool started = false;
    bool timed_out = false;      // 仅 run_hidden_timeout 会置真：到点后本函数亲手终止了子进程
    std::string output;
};

ProcessResult run_hidden(const std::string& command_line_utf8, bool capture_output = false);

// timeout_ms <= 0 等价 run_hidden（不设超时）。
// 超时：对**本函数自己 spawn 的子进程**发 SIGTERM，短暂等待后若仍未退出再 SIGKILL，
// waitpid 回收；timed_out=true，exit_code=124（shell timeout 惯例）。
ProcessResult run_hidden_timeout(const std::string& command_line_utf8,
                                 bool capture_output, int timeout_ms);

// 找可执行文件：先看 exe 同目录（分发版把 ffmpeg.exe 放这里），再退回 PATH。
// 找不到返回空串（调用方据此报"找不到 ffmpeg"）。
// name 不带扩展名（如 "ffmpeg"）。
std::string find_executable(const char* name);

} // namespace rta::platform

// macOS 实现（PLATFORM.md §9）。2026-10-25 项目转 macOS 单平台：Windows 分派支与 #else/#error 兜底已删除。
#include "platform/macos/process_posix.h"
