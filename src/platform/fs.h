// SPDX-FileCopyrightText: 2026 rainlain <https://github.com/okhuoyanyan>
// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// fs.h — 文件操作（平台层契约，跨平台）
//
// 只抽"语义在各平台不等价、必须由平台保证"的那几个操作：
//   * 覆盖式重命名（原子替换）—— WAV/写回的安全红线全靠它
//   * 非覆盖式重命名（备份搬移）、跨盘复制
//   * 删除可能不存在的文件
//   * 最近一次系统错误码（用户可见文案里要带数字，便于现场诊断）
//   * 容错目录枚举（2026-10-31，1.1.1.4）
//
// 不抽：读/写文件内容（std::ifstream/ofstream 已经足够，且行为一致）。
//
// 为什么要抽目录枚举：std::filesystem::recursive_directory_iterator 在 SMB 挂载上遇到
// 失效目录项时，increment 直接失败并把迭代器置为 end —— 整次遍历静默中止
// （例如遇到网络共享失效目录项时 err=2，导致索引被截断）。
// 平台层用 opendir/readdir + lstat 逐项判定，失效项只计数不中止。
#pragma once
#include <filesystem>
#include <string>
#include <vector>

namespace rta::platform {

// 删除文件。文件不存在也返回 false（与 DeleteFileW 一致，调用方历来忽略返回值）
bool remove_file(const std::filesystem::path& p);

// 重命名/搬移。replace_existing=true 时允许覆盖目标（原子替换）；
// false 时目标已存在即失败（备份场景：绝不覆盖最早的原始备份）。
// 跨卷时按平台语义失败（Windows: MoveFileEx 返回 FALSE + ERROR_NOT_SAME_DEVICE）。
bool move_file(const std::filesystem::path& from, const std::filesystem::path& to,
               bool replace_existing);

// 复制文件。fail_if_exists=true 时目标已存在即失败。
bool copy_file(const std::filesystem::path& from, const std::filesystem::path& to,
               bool fail_if_exists);

// 文件是否存在（目录也返回 true，语义 = GetFileAttributesW != INVALID）
bool file_exists(const std::filesystem::path& p);

// 目录项（只做"是不是目录/符号链接"的判定，不 follow 链接）。
struct DirEntry {
    std::string name;         // 只有文件名，不含目录前缀
    bool is_dir = false;      // 真实目录（符号链接一律 false，由 is_symlink 区分）
    bool is_symlink = false;  // 符号链接（目标是目录也不递归）
};

// 列出目录（不递归）。失效项（lstat 失败，例如 SMB 返回 ENOENT）计入 skipped 并跳过；
// 目录本身打不开返回 false，errno 由 last_error_code() 读取。
// 调用方负责跳过 "." / ".."（本函数已过滤），但**不**负责过滤隐藏项。
bool list_dir(const std::string& path, std::vector<DirEntry>& out, size_t& skipped);

// 同上，但额外返回失效项的文件名，便于调用方做**一次**重试：
// SMB 上失效目录项分两类 —— 缓存里残留的名字（重试仍 ENOENT，永久）、瞬时抖动（重试即成功）。
// 不区分这两类会导致「库里有 1 个永久失效项 ⟹ 每次启动都整库重扫」。
bool list_dir(const std::string& path, std::vector<DirEntry>& out, size_t& skipped,
              std::vector<std::string>* skipped_names);

// 最近一次系统错误码的数字值（Windows: GetLastError()；POSIX: errno）。
// 用户可见错误文案必须带上它 —— 不许只说"失败了"。
int last_error_code();

// 原子替换 = 覆盖式重命名（语义糖，写明意图）
inline bool atomic_replace(const std::filesystem::path& from, const std::filesystem::path& to) {
    return move_file(from, to, true);
}

} // namespace rta::platform

// macOS 实现（PLATFORM.md §9）。2026-10-25 项目转 macOS 单平台：Windows 分派支与 #else/#error 兜底已删除。
#include "platform/macos/fs_posix.h"
