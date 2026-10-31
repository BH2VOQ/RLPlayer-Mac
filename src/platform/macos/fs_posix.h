// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// platform/macos/fs_posix.h — fs.h 的 POSIX/macOS 实现
//
// 语义对齐（PLATFORM.md §3.2）：
//   * move_file(replace=false) 目标已存在即失败 —— 备份场景绝不覆盖最早的原始备份
//   * move_file(replace=true)  原子替换，但【只在同一卷内】原子
//   * last_error_code 取 errno（Windows 取 GetLastError），用户可见文案必须带这个数字
//
// POSIX 与 Win32 的真实差异（必须显式处理，不能假装一样）：
//   1. rename(2) 在【目标已存在且是目录】时行为不同；这里只处理常规文件场景。
//   2. rename(2) 跨卷返回 EXDEV —— 与 Windows ERROR_NOT_SAME_DEVICE 同类，
//      按契约"由调用方退化处理"，本层不偷偷改成 copy+unlink（那会破坏原子性假设）。
//   3. MoveFileEx(MOVEFILE_REPLACE_EXISTING) 允许跨卷，rename(2) 不允许 —— 差异记录在此，
//      调用方（writeback）本来就把临时文件放在同目录，所以不会触发。
#include <cerrno>
#include <cstdio>
#include <filesystem>
#include <string>
#include <vector>
#include <sys/stat.h>

#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>

namespace rta::platform {

inline bool remove_file(const std::filesystem::path& p) {
    errno = 0;
    return ::unlink(p.c_str()) == 0;
}

inline bool move_file(const std::filesystem::path& from, const std::filesystem::path& to,
                      bool replace_existing) {
    errno = 0;
    if (!replace_existing) {
        // 非覆盖语义：目标已存在就失败（与 CopyFileW(failIfExists) 一致）
        struct stat st{};
        if (::stat(to.c_str(), &st) == 0) {
            errno = EEXIST;
            return false;
        }
        // link+unlink 能保证"目标不存在才成功"，但跨卷仍会失败；这里直接用 rename，
        // 因为同一卷上 rename 到不存在的目标本身就是原子的，且不会覆盖。
        return ::rename(from.c_str(), to.c_str()) == 0;
    }
    return ::rename(from.c_str(), to.c_str()) == 0;   // POSIX rename 天然覆盖已存在目标
}

inline bool copy_file(const std::filesystem::path& from, const std::filesystem::path& to,
                      bool fail_if_exists) {
    errno = 0;
    if (fail_if_exists) {
        struct stat st{};
        if (::stat(to.c_str(), &st) == 0) {
            errno = EEXIST;
            return false;
        }
    }
    // 用 C 标准库逐块复制：语义简单、无第三方依赖、失败时 errno 有意义
    std::FILE* in = std::fopen(from.c_str(), "rb");
    if (!in) return false;
    std::FILE* out = std::fopen(to.c_str(), "wb");
    if (!out) { std::fclose(in); return false; }
    char buf[65536];
    size_t got = 0;
    bool ok = true;
    while ((got = std::fread(buf, 1, sizeof(buf), in)) > 0) {
        if (std::fwrite(buf, 1, got, out) != got) { ok = false; errno = EIO; break; }
    }
    if (std::ferror(in)) { ok = false; if (errno == 0) errno = EIO; }
    std::fclose(in);
    if (std::fclose(out) != 0) { ok = false; if (errno == 0) errno = EIO; }
    if (!ok) ::unlink(to.c_str());
    return ok;
}

inline bool file_exists(const std::filesystem::path& p) {
    struct stat st{};
    return ::stat(p.c_str(), &st) == 0;      // 目录也返回 true，与 GetFileAttributesW 一致
}

inline int last_error_code() { return errno; }

// ---- 容错目录枚举（2026-10-31，1.1.1.4）----
// opendir/readdir 逐项拿名字，再用 lstat 判定类型：
//   * 目录打不开（ENOENT/EACCES/…）→ 返回 false，errno 留给调用方
//   * 单项 lstat 失败（SMB 上常见的失效目录项，实测 errno=2 ENOENT）→ ++skipped 后继续
//   * 不用 d_type（部分网络文件系统给 DT_UNKNOWN，不可信）
//   * 符号链接只 lstat 不 stat：目标是目录也不递归（由调用方的 is_symlink 决定）
inline bool list_dir(const std::string& path, std::vector<DirEntry>& out, size_t& skipped) {
    DIR* d = ::opendir(path.c_str());
    if (!d) return false;
    out.clear();
    skipped = 0;
    // 拼子项路径时避免出现 "//"（根目录 "/" 自带分隔符）
    const bool needSep = !path.empty() && path.back() != '/';
    std::string full;
    full.reserve(path.size() + 256);
    int readErr = 0;
    struct dirent* de = nullptr;
    for (;;) {
        errno = 0;
        de = ::readdir(d);
        if (!de) { readErr = errno; break; }
        const char* nm = de->d_name;
        if (nm[0] == '.' && (nm[1] == '\0' || (nm[1] == '.' && nm[2] == '\0'))) continue;
        full.assign(path);
        if (needSep) full += '/';
        full += nm;
        struct stat st{};
        if (::lstat(full.c_str(), &st) != 0) { ++skipped; continue; }   // 失效项：跳过，不中止遍历
        DirEntry e;
        e.name = nm;
        e.is_symlink = S_ISLNK(st.st_mode);            // lstat ⟹ 链接自身，不是目标
        e.is_dir = !e.is_symlink && S_ISDIR(st.st_mode);
        out.push_back(std::move(e));
    }
    ::closedir(d);
    errno = readErr;   // 保留 readdir 的真实错误；lstat 的 ENOENT 不算目录错误
    // 读到一半出错绝不能当成"目录已读完"（那又会变成静默截断）；交给调用方按 failedDir 处理。
    return readErr == 0;
}

} // namespace rta::platform
