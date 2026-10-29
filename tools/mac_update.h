// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// mac_update.h — F-4 自动更新原生执行层的**接口**（实现见 mac_update.mm）
//
// 为什么单独拆一个头：tools/mac_host.mm 要与它解耦。
//   * mac_host.mm 只负责「收到 update:check / update:install → 调这里」
//   * 纯判定逻辑在 src/net/update_check.h（可离线单测）
//   * 本层只做 IO（下载/校验/挂载/替换），IO 失败绝不会被误判成"已是最新"
//
// ⚠️ 只有 ObjC++（.mm）翻译单元可以包含本头（签名里用了 block）。
#pragma once

// 本头里的安装回调用了 NSString —— 只能被 Objective-C++（.mm）翻译单元包含。
// 给出明确报错而不是让编译器报 "unknown type name 'NSString'"（那种信息很难定位）。
#if !defined(__OBJC__)
#error "tools/mac_update.h 只能由 Objective-C++（.mm / .mm 目标）包含"
#endif

#include <algorithm>
#include <atomic>
#include <memory>
#include <string>
#include <vector>

// 前向声明即可：本头只在函数签名里用到 NSString*，不需要 Foundation 的完整定义。
// 这样调用方可以自由决定 include 顺序（Foundation 之前/之后都行）。
@class NSString;

#include "net/update_check.h"

namespace rta::update {

// ---------------------------------------------------------------------------
// 取消令牌（2026-10-26：真实进度 + 可取消）
//
// 为什么是一个共享的原子标志：begin_install 跑在后台队列，下载的进度回调跑在
// NSURLSession 的 delegate 队列，取消可能来自主线程（UI「取消」按钮）。
// 三方共享同一个 atomic<bool>，复制 CancelToken 得到的是**同一个**标志（shared_ptr）。
//
// 取消的响应边界（如实说明，不夸大）：
//   * 下载阶段：每 100ms 检查一次 ⟹ 实际的下载立刻停；
//   * 校验/挂载/替换是不可中断的短阶段（各自秒级以内），取消只在**阶段边界**生效，
//     不会把正在 ditto 的 .app 砍一半（那才是真正会毁掉用户环境的行为）。
// ---------------------------------------------------------------------------
class CancelToken {
public:
    CancelToken() : flag_(std::make_shared<std::atomic<bool>>(false)) {}
    void cancel() const { if (flag_) flag_->store(true); }
    bool cancelled() const { return flag_ && flag_->load(); }
    // 两个 token 是否指向同一个标志（测试用）
    bool sameAs(const CancelToken& o) const { return flag_ == o.flag_; }
private:
    std::shared_ptr<std::atomic<bool>> flag_;
};

// ---------------------------------------------------------------------------
// 进度区间映射（唯一真相源）
//
//   下载 0 → 40    校验 40 → 60    安装 60 → 95    完成 100
//
// 抽出 download_percent() 当纯函数是为了**可被真正测到**：判据不是"回调有被调用"，
// 而是"用下载器实际报上来的字节数算出的 pct 序列单调不减、覆盖 0→40、终值恰好 40"。
// ---------------------------------------------------------------------------
struct InstallProgressRange {
    static constexpr int kDownloadEnd = 40;
    static constexpr int kVerifyEnd   = 60;
    static constexpr int kInstallEnd  = 95;
    static constexpr int kDone        = 100;
};

// 已下载 written / 总大小 total ⟹ 下载阶段的百分比（夹在 [0, 40]）。
// total <= 0（服务端没给 Content-Length 且清单没写 size）⟹ 返回 0（不知道就是 0，不瞎猜）。
inline int download_percent(long long written, long long total) {
    if (total <= 0 || written <= 0) return 0;
    if (written >= total) return InstallProgressRange::kDownloadEnd;
    const long long pct = (written * InstallProgressRange::kDownloadEnd) / total;
    return (int)std::max(0LL, std::min<long long>(pct, InstallProgressRange::kDownloadEnd));
}

// ---------------------------------------------------------------------------
// 下载进度的百分数跟踪器（**单调不减 + 只在变化时上报**）
//
// 为什么单独抽出来：底层 delegate 报的是字节数，理论上可能抖动（重传/分段），
// 直接映射成 pct 再去刷 UI 会出现"40 → 39"这种倒退，用户看到进度条往回跳。
// 这里做两件事，且是**生产与测试共用同一份**（测试因此能断言真东西）：
//   ① pct 单调不减（newPct = max(newPct, last)）；
//   ② 值没变就不上报（不刷爆 UI）。
// 返回 true 表示 outPct 有更新、调用方应该上报。
// ---------------------------------------------------------------------------
struct DownloadPctTracker {
    // 分母：优先用清单里的 size（服务端 Content-Length 可能缺失或不可信）
    long long expectedSize = 0;
    int       last = -1;

    bool update(long long written, long long serverTotal, int& outPct) {
        const long long denom = (expectedSize > 0) ? expectedSize : serverTotal;
        int pct = download_percent(written, denom);
        if (pct < last) pct = last;              // ← ① 单调不减
        if (pct <= last) return false;           // ← ② 没变化不上报
        last = pct;
        outPct = pct;
        return true;
    }
};

// 进度回调：stage ∈ checking/downloading/verifying/mounting/installing/done/failed
struct NativeProgress {
    std::string stage;
    std::string detail;      // 人类可读（**不含 token**）
    int         percent = -1;   // -1 = 未知
};

using ProgressFn = void (^)(const NativeProgress& p);
using DoneFn     = void (^)(const rta::update::CheckResult& result);
using InstallFn  = void (^)(bool ok, NSString *message);

// 异步检查更新。立即返回；结果通过 done 回调（已在后台队列，调用方自行切主线程）。
void begin_check(ProgressFn progress, DoneFn done);

// 异步一键更新。只有 plan.decision == UpdateAvailable 才会执行；
// 内部顺序：下载 → verify_downloaded_file（失败即丢弃）→ 挂载 → 备份 → ditto 替换
//           → 自动重启（失败则回退到 NSAlert 手动重启提示）。
// cancel 可为空 token（默认构造就是"永不取消"）。
// 实现 = run_install_pipeline + 「目标 .app 取当前进程所在位置」这一句。
void begin_install(const CheckResult& plan, ProgressFn progress, InstallFn done,
                   CancelToken cancel = CancelToken());

// ---------------------------------------------------------------------------
// **可测的安装流水线**（begin_install 的全部实质内容）
//
// 为什么拆出来：begin_install 会把 .app 装到「当前 .app 所在位置」，测试若直接调它，
// 就会覆盖用户正在用的 RLPlayer.app（拿用户环境当试验场，不可接受）。
// 拆出注入点之后，测试能跑**同一份流水线代码**——真下载（本机 HTTP）、真 dmg、
// 真校验、真挂载、真 ditto——只把 targetApp 指到 /tmp，把 autoRestart 关掉。
//
// 判据因此才站得住：进度序列不是"测试模拟出来的"，而是这条真流水线真跑出来的。
// ---------------------------------------------------------------------------
struct InstallPipelineOptions {
    std::string targetApp;              // 空 = detail_native::InstallTargetPath()
    std::string dmgPath;                // 空 = <temp>/rlplayer-update.dmg
    std::string mountPoint;             // 空 = <temp>/rlplayer-update-mnt
    int         downloadTimeoutSeconds = 120;
    bool        autoRestart = true;     // 测试必须传 false（绝不真的去 open 一个 .app）
    bool        keepDmgOnFailure = false;  // 仅诊断用；默认 false = 失败即删
};

// 同步执行（调用方负责放到后台队列）。成功返回 true；outErr 人类可读、不含 token。
// ⚠️ 顺序即安全边界：verify（sha256+size）**必须**在 mount 之前，不许重排。
bool run_install_pipeline(const CheckResult& plan, ProgressFn progress, CancelToken cancel,
                          const InstallPipelineOptions& opts,
                          std::string& outErr, std::string& outBackup);

// ---------------------------------------------------------------------------
// 流式下载（NSURLSession，带真实进度）—— 也可以单独测
//
// 为什么单独暴露：begin_install 会去网络上下真包，测试里没法稳定复现"下载中途"。
// 拆出来后 tests/test_mac_update.mm 可以起一个**本机慢速 HTTP 服务**（分块写、每块
// sleep），断言：① 进度回调真的被多次调用；② 字节数单调递增；③ 落盘文件字节数
// 与服务端发的一致；④ 中断（服务端半路断开）时不留半个文件。
//
// 语义：
//   * 成功才返回 true，此时 dstPath 是**完整**文件；
//   * 任何失败（网络/HTTP 非 2xx/写盘/取消）都 unlink(dstPath) —— 绝不留下半个文件；
//   * onProgress 在后台队列被调用，参数是"已写入字节数 / 总字节数"，后者未知时为 -1；
//   * 每 200ms 或每 1% 最多回调一次（内部节流，别刷爆 UI）。
// ---------------------------------------------------------------------------
using DownloadProgressFn = void (^)(long long written, long long total);

struct DownloadResult {
    bool        ok = false;
    int         status = 0;          // HTTP 状态码（0 = 连不上）
    long long   bytes = 0;           // 真正写盘的字节数
    std::string error;               // 人类可读，**已脱敏**，不含 token
    bool        cancelled = false;
};

DownloadResult download_to_file(const std::string& url,
                                const std::string& token,
                                const std::string& dstPath,
                                int timeoutSeconds,
                                DownloadProgressFn onProgress,
                                CancelToken cancel = CancelToken());

// ⚠️ **仅测试用**：默认完全关闭。
// 生产路径必须过 update_download_url_allowed()（https + 精确主机白名单）。
// 打开的副作用（刻意做成只在 loopback 上生效，防止被误用于生产）：
//   只额外放行 http://127.0.0.1:<port>/ 与 http://localhost:<port>/ 这种**本机**地址，
//   任何外部主机仍然被白名单拒绝 —— 所以它不能让"清单被篡改成任意地址"变得可能。
//
// 为什么需要它：要用**真 NSURLSession 打真 HTTP**验证流式进度，就必须能指向一个临时
// 本机服务；否则这条改动永远只能靠代码审查（违反铁律 3）。
void set_test_allow_loopback_download(bool enabled);

// ---------------------------------------------------------------------------
// 自动重启（2026-10-26：不再只说"请手动重启"）
//
// 做法（唯一实现，测试直接调它）：写一个临时 bash 脚本再分离执行 ——
//   #!/bin/bash
//   sleep 1.5          # 等当前进程退出，避免 .app 内文件仍被占用
//   open -n "<新 .app>"    # -n = 新建实例（直接 open 可能只激活旧实例）
//   rm -f "$0"         # 自删，不留垃圾
//
// 返回 false 表示**连脚本都没能创建**（调用方必须回退到 NSAlert，不能静默）。
// 返回 true 只代表"脚本创建并成功派发"，不代表新版本一定起来了（由 script_path 可查）。
// outErr 人类可读；outScriptPath 是脚本落盘位置（诊断用，成功时非空）。
// ---------------------------------------------------------------------------
// 可调参数只为一件事：让测试能在**几十毫秒**内跑完真链路（默认值就是线上值）。
struct AutoRestartOptions {
    int         sleepMs = 1500;    // 等旧进程退出的固定等待（用户要求的"约 1.5 秒"）
    long long   waitPid = -1;      // -1 = 等当前进程；0 = 不等（测试用）
    std::string logPath;           // 空 = temp_dir/rlplayer-restart.log
    bool        spawn = true;      // false = 只写脚本不执行（诊断/测试用）
};

bool schedule_auto_restart(const std::string& appPath, std::string& outScriptPath,
                           std::string& outErr,
                           const AutoRestartOptions& opts = AutoRestartOptions());

// 脚本正文生成（纯函数，可离线断言内容：sleep 时长、open -n、路径引用是否正确）
std::string auto_restart_script_body(const std::string& appPath, const AutoRestartOptions& opts);


// update.conf 路径（= config_dir_utf8()/update.conf）。空串表示配置目录不可用。
std::string update_conf_path();

// 首次运行写出 0600 的模板（token 为空 ⟹ 匿名路径）。已存在则不动。
bool ensure_conf_template(std::string& err);

// 测试/诊断用：把可能含 token 的字符串脱敏（连长度都不暴露）。
std::string redact_token(const std::string& input, const std::string& token);

// ---------------------------------------------------------------------------
// 安装流水线拆成可单独调用的步骤 —— **为了能被真正测到**
//
// 为什么拆：begin_install 会把 .app 装到「当前 .app 所在位置」，测试若直接调它，
// 就会覆盖正在用的 RLPlayer.app（等于拿用户环境当试验场）。
// 拆出来后 tests/test_mac_update.mm 可以用临时目录当目标，把
// 「挂载真实 dmg → 找 .app → ditto 安装 → 校验结果」跑成真事，
// 而不是靠代码审查说"应该能装"。
// ---------------------------------------------------------------------------

// 挂载 dmg 到 mountPoint（会先 mkdir）。成功后 *outAppPath 为镜像内第一个 *.app。
// 调用方**必须**成功后调 unmount_image()。
bool mount_image(const std::string& dmgPath, const std::string& mountPoint,
                 std::string& outAppPath, std::string& err);

// 卸载挂载点（幂等；失败只写 err 不抛）。
bool unmount_image(const std::string& mountPoint, std::string& err);

// 把 srcApp 拷到 targetApp。若 targetApp 已存在，先备份到 *outBackup（可为空串=没备份）。
// 复制失败且备份成功时**自动回滚**（把备份拷回 targetApp）。
bool install_app_bundle(const std::string& srcApp, const std::string& targetApp,
                        std::string& outBackup, std::string& err);

// 计算 dmg 的 sha256（测试造包后要用它写清单）。
bool sha256_of_file(const std::string& path, std::string& outHex, std::string& err);

// ---------------------------------------------------------------------------
// 安装流水线的**有序实现**（从"已验证落盘的本地 dmg"走到"替换 targetApp"）
//
// 这是「一键更新」去掉网络后的骨架，begin_install 复用同一份代码。
// 抽出来的唯一理由：好让测试能用**真实的坏摘要**去撞它，并断言
//   「已有的 targetApp 一个字节都没变」—— 这才是"不替换"的可证明形式。
//
// 固定顺序（顺序本身就是安全边界，不许重排）：
//   ① verify_downloaded_file  ← 不过就 return，绝不进入 ②③
//   ② mount_image
//   ③ install_app_bundle（内部先备份、失败回滚）
//   ④ unmount_image（无论 ③ 成败都要卸）
// ---------------------------------------------------------------------------
bool install_from_local_dmg(const std::string& dmgPath,
                            const std::string& expectedSha256, long long expectedSize,
                            const std::string& mountPoint,
                            const std::string& targetApp,
                            std::string& outBackup, std::string& err);

} // namespace rta::update
