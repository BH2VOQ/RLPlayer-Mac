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

#include <string>

// 前向声明即可：本头只在函数签名里用到 NSString*，不需要 Foundation 的完整定义。
// 这样调用方可以自由决定 include 顺序（Foundation 之前/之后都行）。
@class NSString;

#include "net/update_check.h"

namespace rta::update {

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
// 内部顺序：下载 → verify_downloaded_file（失败即丢弃）→ 挂载 → 备份 → ditto 替换 → 提示重启。
void begin_install(const CheckResult& plan, ProgressFn progress, InstallFn done);

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
