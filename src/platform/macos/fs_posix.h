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
#include <sys/stat.h>

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

} // namespace rta::platform
