// platform/macos/time_posix.h — time.h 的 POSIX/macOS 实现
//
// 语义 = GetTickCount64()：开机以来毫秒、单调、不回退。
// 用 clock_gettime(CLOCK_MONOTONIC) 而不是 std::chrono::steady_clock —— 后者的 epoch
// 由实现定义，PLATFORM.md §3.7 明确要求保持"刻度与 epoch 可解释"。
#include <cstdint>
#include <ctime>

namespace rta::platform {

inline uint64_t monotonic_ms() {
    struct timespec ts{};
    ::clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ull + (uint64_t)(ts.tv_nsec / 1000000);
}

} // namespace rta::platform
