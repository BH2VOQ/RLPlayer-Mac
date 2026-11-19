// SPDX-FileCopyrightText: 2026 rainlain <https://github.com/okhuoyanyan>
// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
#pragma once
#include <atomic>
#include <stdexcept>

namespace rta::dsp {

// Design-only cooperative cancellation. Playback leaves the thread-local flag
// null. A caller owns the flag until its design worker has joined.
class DesignCancelled : public std::runtime_error {
public:
    DesignCancelled() : std::runtime_error("Filter preparation cancelled") {}
};

inline thread_local const std::atomic_bool* design_cancel_flag = nullptr;

class DesignCancellationScope {
    const std::atomic_bool* previous_;
public:
    explicit DesignCancellationScope(const std::atomic_bool* flag)
        : previous_(design_cancel_flag) {
        if (flag) design_cancel_flag = flag;
    }
    ~DesignCancellationScope() { design_cancel_flag = previous_; }
    DesignCancellationScope(const DesignCancellationScope&) = delete;
    DesignCancellationScope& operator=(const DesignCancellationScope&) = delete;
};

inline void check_design_cancel() {
    if (design_cancel_flag && design_cancel_flag->load(std::memory_order_relaxed))
        throw DesignCancelled();
}

} // namespace rta::dsp
