// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// raop_packet_cache.h — 有界的 RTP 重传缓存。
//
// 接收端丢包时会向我们 control 端口发 NACK（raop_protocol.h 里的 parse_nack），
// 我们要用**原序号、原时间戳、原 ALAC 载荷**补发。所以最近发出的包必须留一份。
//
// 设计约束：
//   1) 容量固定（默认 512 包 ≈ 4.0 s @352 帧/包），内存与流时长无关；
//      要比默认 latency(2.0 s) 大：暂停时接收端被 FLUSH 丢掉的是“已发未播”那段，
//      恢复时要从缓存里按原 seq/rtptime 重发回来，窗口必须覆盖整段在途音频；
//   2) 序号召回绕（65535 → 0）时按 16 位相等查找，天然正确；
//   3) 已被淘汰的“过老”序号就是 Miss，绝不返回别的包（宁可让对端静音一个包，也不放错音频）；
//   4) 写入线程与 NACK 线程并发访问，内部加锁。
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <vector>

namespace rta::net::raop {

struct CachedRtpPacket {
    uint16_t sequence = 0;
    uint32_t timestamp = 0;
    std::vector<uint8_t> payload;   // 仅 ALAC 载荷（RTP 头按原 seq/ts/ssrc 重建）
};

class RtpPacketCache {
public:
    static constexpr size_t kDefaultCapacity = 512;
    static constexpr size_t kMinCapacity = 8;
    static constexpr size_t kMaxCapacity = 4096;

    explicit RtpPacketCache(size_t capacity = kDefaultCapacity)
        : capacity_(clamp_capacity(capacity)), ring_(capacity_) {}

    void reset(size_t capacity = 0) {
        std::lock_guard<std::mutex> lk(mtx_);
        if (capacity != 0) {
            capacity_ = clamp_capacity(capacity);
            ring_.assign(capacity_, CachedRtpPacket{});
        }
        for (auto& p : ring_) {
            p.sequence = 0;
            p.timestamp = 0;
            p.payload.clear();
        }
        count_ = 0;
        next_ = 0;
        storedTotal_ = 0;
        evictedTotal_ = 0;
    }

    void clear() {
        std::lock_guard<std::mutex> lk(mtx_);
        for (auto& p : ring_) {
            p.sequence = 0;
            p.timestamp = 0;
            p.payload.clear();
        }
        count_ = 0;
        next_ = 0;
    }

    void store(uint16_t seq, uint32_t timestamp, const uint8_t* payload, size_t len) {
        if (!payload || len == 0) return;
        std::lock_guard<std::mutex> lk(mtx_);
        if (ring_.empty()) return;
        CachedRtpPacket& slot = ring_[next_];
        slot.sequence = seq;
        slot.timestamp = timestamp;
        slot.payload.assign(payload, payload + len);
        next_ = (next_ + 1) % capacity_;
        if (count_ < capacity_) {
            ++count_;
        } else {
            ++evictedTotal_;
        }
        ++storedTotal_;
    }

    bool find(uint16_t seq, CachedRtpPacket& out) const {
        std::lock_guard<std::mutex> lk(mtx_);
        for (size_t i = 0; i < count_; ++i) {
            if (ring_[i].sequence == seq) {
                out = ring_[i];
                return true;
            }
        }
        return false;
    }

    // 按写入顺序（即发送顺序）拷出快照。有界：最多 capacity() 个包。
    // 暂停/恢复重放在途窗口时用它，保证重发顺序与原始发送顺序一致。
    //
    // ⚠️ 环形缓冲**写满之后**最老的元素在 next_，不是下标 0：
    //   旧实现直接取 ring_[0..count_-1]，满载时会把“最新 21 个包”当成最老的先发出去，
    //   补发顺序因此整体错乱（2026-11-04 十分钟长跑实测：一次恢复后出现 21 个包的跳号）。
    //   有界快照必须从 next_ 起绕环读，否则恢复播放会把时间戳逆序的包推给接收端。
    void snapshot_in_order(std::vector<CachedRtpPacket>& out) const {
        std::lock_guard<std::mutex> lk(mtx_);
        out.clear();
        if (ring_.empty() || count_ == 0) return;
        out.reserve(count_);
        const size_t start = (count_ < capacity_) ? 0 : next_;
        for (size_t i = 0; i < count_; ++i) out.push_back(ring_[(start + i) % capacity_]);
    }

    size_t capacity() const {
        std::lock_guard<std::mutex> lk(mtx_);
        return capacity_;
    }
    size_t size() const {
        std::lock_guard<std::mutex> lk(mtx_);
        return count_;
    }
    uint64_t stored_total() const {
        std::lock_guard<std::mutex> lk(mtx_);
        return storedTotal_;
    }
    uint64_t evicted_total() const {
        std::lock_guard<std::mutex> lk(mtx_);
        return evictedTotal_;
    }

private:
    static size_t clamp_capacity(size_t c) {
        if (c < kMinCapacity) return kMinCapacity;
        if (c > kMaxCapacity) return kMaxCapacity;
        return c;
    }

    mutable std::mutex mtx_;
    size_t capacity_ = kDefaultCapacity;
    std::vector<CachedRtpPacket> ring_;
    size_t next_ = 0;
    size_t count_ = 0;
    uint64_t storedTotal_ = 0;
    uint64_t evictedTotal_ = 0;
};

}  // namespace rta::net::raop
