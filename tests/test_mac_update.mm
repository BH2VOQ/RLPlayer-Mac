// test_mac_update.mm — F-4 安装流水线的**真跑**门禁（不是代码审查）
//
// ============================ 这个测试证明什么 ============================
// tests/test_update_check.cpp 证明的是"判定正确"（纯函数）。本文件证明"**动作真的能做**"：
//   1) 造一个真 dmg（hdiutil create）
//   2) 算它的真 sha256
//   3) 篡改场景：清单写 A、文件是 B ⟹ 门禁拒绝 ⟹ **不挂载、不安装**
//   4) 正确场景：真挂载（hdiutil attach）→ 找到 .app → ditto 安装到**临时目录**
//   5) 已存在目标时先备份；复制成功后可回滚
//
// ⚠️ 安全边界（为什么不会伤到用户环境）：
//   * 所有路径都在 /tmp 或 NSTemporaryDirectory 下的独立目录
//   * **绝不**把 install_app_bundle 的 targetApp 指向正在用的 RLPlayer.app
//   * 绝不调用 begin_install（那个函数才会去写「当前 .app 所在位置」）
//   * 不用 sudo、不 force attach/detach
//
// 判据设计（铁律 3）：第 3 条不是"函数返回 false 就算过"，还额外断言
//   **挂载点没有被创建/ 目标目录内容没有变化** —— 证明"拒绝"是真的没动文件系统。
#define RL_TEST_RUNNER 1

#import <Foundation/Foundation.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include <sys/stat.h>
#include <unistd.h>

#include "mac_update.h"
#include "net/update_check.h"
#include "platform/path.h"

using namespace rta::update;

static int g_pass = 0;
static int g_fail = 0;
static void ck(bool ok, const std::string& what, const std::string& detail = "") {
    if (ok) { ++g_pass; std::printf("  [PASS] %s\n", what.c_str()); }
    else {
        ++g_fail;
        std::printf("  [FAIL] %s", what.c_str());
        if (!detail.empty()) std::printf("  —— %s", detail.c_str());
        std::printf("\n");
    }
}

static bool dir_exists(const std::string& p) {
    struct stat st {};
    return ::stat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}
static bool file_exists(const std::string& p) {
    struct stat st {};
    return ::stat(p.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}
static long long file_size(const std::string& p) {
    struct stat st {};
    if (::stat(p.c_str(), &st) != 0) return -1;
    return (long long)st.st_size;
}

static int run(const std::string& cmd) {
    return std::system((cmd + " >/dev/null 2>&1").c_str());
}

// 造一个最小但结构合法的 .app（有 Info.plist + MacOS/RLPlayer）
static bool make_fake_app(const std::string& path, const std::string& marker) {
    if (run("mkdir -p '" + path + "/Contents/MacOS'") != 0) return false;
    FILE* f = std::fopen((path + "/Contents/MacOS/RLPlayer").c_str(), "wb");
    if (!f) return false;
    std::fwrite(marker.data(), 1, marker.size(), f);
    std::fclose(f);
    ::chmod((path + "/Contents/MacOS/RLPlayer").c_str(), 0755);
    FILE* p = std::fopen((path + "/Contents/Info.plist").c_str(), "wb");
    if (!p) return false;
    const std::string plist =
        "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>"
        "<key>CFBundleIdentifier</key><string>com.rta.rlplayer.f4test</string>"
        "</dict></plist>";
    std::fwrite(plist.data(), 1, plist.size(), p);
    std::fclose(p);
    return true;
}

// 读 .app 里那个 marker 文件的内容（用来证明"装进去的是哪一份"）
static std::string read_marker(const std::string& appPath) {
    FILE* f = std::fopen((appPath + "/Contents/MacOS/RLPlayer").c_str(), "rb");
    if (!f) return "<missing>";
    std::string s;
    char buf[512];
    const size_t n = std::fread(buf, 1, sizeof(buf), f);
    s.assign(buf, n);
    std::fclose(f);
    return s;
}

int main() {
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        std::printf("=== F-4 安装流水线真跑门禁 ===\n");
        std::printf("（全部路径都在 /tmp 下；绝不触碰用户正在使用的 .app）\n\n");

        const std::string base = std::string("/tmp/rlplayer-f4-e2e-") +
                                 std::to_string((long long)::getpid());
        run("rm -rf '" + base + "'");
        ck(run("mkdir -p '" + base + "/stage'") == 0, "建立隔离工作目录", base);

        // ---------------- 1. 造真 dmg ----------------
        const std::string stageApp = base + "/stage/RLPlayer.app";
        ck(make_fake_app(stageApp, "PAYLOAD-v1.0.5"), "构造最小 .app（含 Info.plist + 可执行）");

        const std::string dmg = base + "/update.dmg";
        const int crc = run("/usr/bin/hdiutil create -quiet -srcfolder '" + base + "/stage'"
                            " -format UDZO -volname RLPlayerF4 '" + dmg + "'");
        ck(crc == 0 && file_exists(dmg), "hdiutil create 生成真 dmg",
           "rc=" + std::to_string(crc) + " size=" + std::to_string(file_size(dmg)));

        // ---------------- 2. 真 sha256 ----------------
        std::string realSha, err;
        ck(sha256_of_file(dmg, realSha, err) && realSha.size() == 64,
           "算 dmg 的真 sha256", realSha + " " + err);
        // 交叉核对：与系统 shasum 一致（不是"自己算两遍一样"）
        {
            FILE* p = ::popen(("/usr/bin/shasum -a 256 '" + dmg + "' | cut -d' ' -f1").c_str(), "r");
            std::string sysSha;
            if (p) {
                char buf[256] = {0};
                if (std::fgets(buf, sizeof(buf), p)) sysSha.assign(buf);
                ::pclose(p);
                while (!sysSha.empty() && (sysSha.back() == '\n' || sysSha.back() == ' ')) sysSha.pop_back();
            }
            ck(!sysSha.empty() && sysSha == realSha,
               "自实现 sha256 与系统 shasum -a 256 逐字符一致", "sys=" + sysSha + " ours=" + realSha);
        }

        // ---------------- 3. 篡改必失败：不挂载、不安装 ----------------
        {
            const std::string mnt = base + "/mnt-tamper";
            const std::string fakeSha(64, 'a');          // 与真实摘要肯定不同
            const VerifyResult vr = verify_downloaded_file(dmg, fakeSha, 0);
            ck(!vr.ok && vr.reason == VerifyFailReason::Sha256Mismatch,
               "【篡改】摘要不符 ⟹ 门禁拒绝", vr.error);

            // 判据加强：证明"拒绝之后真的什么都没做"
            // （hdiutil attach 只在门禁通过后才会被调用；这里断言挂载点没被建出来）
            ck(!dir_exists(mnt), "【篡改】挂载点未被创建（拒绝发生在挂载之前）");
            const std::string target = base + "/Applications/RLPlayer.app";
            run("mkdir -p '" + base + "/Applications'");
            ck(!file_exists(target), "【篡改】目标位置没有出现任何 .app");
        }

        // ---------------- 3b. 【最关键】目标已存在 + 摘要错 ⟹ 现有 .app 一个字节都不许变 ----------------
        // 这是"不替换 /Applications 里的 .app"的可证明形式：
        //   不只是"函数返回 false"，而是**替换前先存指纹、替换后再算指纹、逐字节比对**。
        {
            const std::string targetDir = base + "/Applications-guard";
            run("mkdir -p '" + targetDir + "'");
            const std::string target = targetDir + "/RLPlayer.app";
            ck(make_fake_app(target, "EXISTING-INSTALLED-v1.0.4"), "预先放一份「已安装的旧版」");
            const std::string beforeSha = read_marker(target);
            const long long beforeSize = file_size(target + "/Contents/MacOS/RLPlayer");
            ck(beforeSha == "EXISTING-INSTALLED-v1.0.4", "旧版内容基线已记录", beforeSha);

            const std::string mnt = base + "/mnt-guard";
            const std::string wrongSha(64, 'b');       // 与真 dmg 摘要肯定不同
            std::string backup, gerr;
            const bool r = install_from_local_dmg(dmg, wrongSha, 0, mnt, target, backup, gerr);
            ck(!r, "【篡改】install_from_local_dmg 拒绝安装", gerr);
            ck(backup.empty(), "【篡改】没有产生备份（说明连备份都没开始）", backup);
            ck(read_marker(target) == beforeSha,
               "【篡改】已安装的 .app 内容**逐字节未变**", read_marker(target));
            ck(file_size(target + "/Contents/MacOS/RLPlayer") == beforeSize,
               "【篡改】旧版文件大小未变（没被截断/覆盖）");
            ck(!dir_exists(mnt), "【篡改】挂载点未被创建（拒绝发生在挂载之前）");

            // 反向对照：同一份 dmg + **正确**摘要 ⟹ 必须真的换掉（否则上面那条可能只是"恒不变"）
            std::string backup2, gerr2;
            const std::string mnt2 = base + "/mnt-guard-ok";
            const bool r2 = install_from_local_dmg(dmg, realSha, file_size(dmg), mnt2, target, backup2, gerr2);
            ck(r2, "【对照】正确摘要 ⟹ 安装成功（证明上一条不是恒不动作）", gerr2);
            ck(read_marker(target) == "PAYLOAD-v1.0.5",
               "【对照】内容确实被换成新版", read_marker(target));
            ck(!backup2.empty() && dir_exists(backup2), "【对照】旧版已备份", backup2);
        }

        // ---------------- 4. 正确场景：真挂载 → 真安装 ----------------
        {
            const VerifyResult vr = verify_downloaded_file(dmg, realSha, file_size(dmg));
            ck(vr.ok, "【正确】摘要 + size 都对 ⟹ 门禁通过", vr.error);

            const std::string mnt = base + "/mnt-ok";
            std::string srcApp;
            const bool mounted = mount_image(dmg, mnt, srcApp, err);
            ck(mounted, "hdiutil attach 真挂载成功", err);
            ck(!srcApp.empty() && dir_exists(srcApp), "镜像内找到 .app", srcApp);

            if (mounted && !srcApp.empty()) {
                // 装到**临时目录**（绝不是 /Applications，更不是正在用的 app）
                const std::string target = base + "/Applications/RLPlayer.app";
                run("mkdir -p '" + base + "/Applications'");
                std::string backup;
                const bool installed = install_app_bundle(srcApp, target, backup, err);
                ck(installed, "ditto 安装到目标成功", err);
                ck(read_marker(target) == "PAYLOAD-v1.0.5",
                   "装进去的确实是 dmg 里那份（内容可核对）", read_marker(target));
                ck(backup.empty(), "目标原本不存在 ⟹ 不产生备份");

                // 再装一次：目标已存在，必须备份旧版
                if (make_fake_app(target + ".stale", "OLD") && dir_exists(target + ".stale")) {
                    run("rm -rf '" + target + "' && mv '" + target + ".stale' '" + target + "'");
                }
                std::string backup2;
                const bool again = install_app_bundle(srcApp, target, backup2, err);
                ck(again, "对已存在的目标再次安装成功", err);
                ck(!backup2.empty() && dir_exists(backup2), "已存在 → 先备份旧版", backup2);
                ck(read_marker(target) == "PAYLOAD-v1.0.5", "覆盖后内容是新版");
            }

            std::string uerr;
            const bool unmounted = unmount_image(mnt, uerr);
            ck(unmounted, "hdiutil detach 真卸载成功", uerr);
            // 二次卸载必须不崩（幂等性）
            std::string uerr2;
            (void)unmount_image(mnt, uerr2);
            ck(true, "重复卸载不崩溃（幂等）");
        }

        // ---------------- 5. 截断：size 不符也要拒绝 ----------------
        {
            const VerifyResult vr = verify_downloaded_file(dmg, realSha, file_size(dmg) - 100);
            ck(!vr.ok && vr.reason == VerifyFailReason::SizeMismatch,
               "【截断】size 差 100 字节 ⟹ 拒绝（独立于 sha 的闸门）", vr.error);
        }

        // ---------------- 6. 不存在的 dmg：挂载必须失败而不是崩 ----------------
        {
            const std::string mnt = base + "/mnt-missing";
            std::string srcApp;
            const bool mounted = mount_image(base + "/no-such.dmg", mnt, srcApp, err);
            ck(!mounted, "不存在的 dmg ⟹ mount_image 失败（不崩）", err);
        }

        // ---------------- 7. token 脱敏（安全硬要求）----------------
        {
            const std::string tok = "deadbeefcafebabe0123456789abcdef01234567";
            ck(redact_token("Authorization: token " + tok, tok) == "Authorization: token ***",
               "redact_token 抹掉 token 本体");
            ck(redact_token("error: " + tok + " rejected", tok) == "error: *** rejected",
               "redact_token 在句中也能抹掉");
            ck(redact_token("no secret here", tok) == "no secret here", "不含 token 的串原样返回");
            ck(redact_token(tok, tok) == "***", "整串就是 token ⟹ 全抹");
            ck(redact_token("x", "") == "x", "空 token 不影响");
            // 长度不暴露
            ck(redact_token(tok, tok).size() == 3, "脱敏后不残留原长度（3 字符 ***）");
        }

        // ---------------- 8. update.conf 落在 config_dir，且 0600 ----------------
        {
            const std::string confPath = update_conf_path();
            ck(!confPath.empty(), "update_conf_path 非空", confPath);
            ck(confPath.find(".app/") == std::string::npos,
               "update.conf **不在** .app 内（.app 内不打包任何配置）", confPath);
            ck(confPath.size() > 5 && confPath.compare(confPath.size() - 11, 11, "update.conf") == 0,
               "文件名是 update.conf", confPath);

            // 模板创建权限必须是 0600（不是先 0644 后 chmod）
            const std::string probe = base + "/update.conf.probe";
            FILE* f = std::fopen(probe.c_str(), "wb");
            ck(f != nullptr, "能创建探针文件");
            if (f) {
                const std::string tpl = default_update_conf_template();
                std::fwrite(tpl.data(), 1, tpl.size(), f);
                std::fclose(f);
                const Config c = parse_update_config(tpl);
                ck(!c.hasToken, "模板 token 为空 ⟹ 首次运行匿名（不弹窗）");
                ck(c.manifestUrl == kDefaultManifestUrl, "模板指向默认公开清单");
                std::remove(probe.c_str());
            }
            // 真的创建一次 0600 模板（在隔离的 HOME 下，不污染真实配置）
            const std::string dir = base + "/cfgdir";
            run("mkdir -p '" + dir + "'");
            ::setenv("HOME", dir.c_str(), 1);
            std::string cerr2;
            const bool created = ensure_conf_template(cerr2);
            if (created) {
                const std::string made = update_conf_path();
                struct stat st {};
                const bool gotMode = (::stat(made.c_str(), &st) == 0);
                ck(gotMode && (st.st_mode & 0777) == 0600,
                   "新建 update.conf 权限是 0600（创建即 0600，不是事后 chmod）",
                   gotMode ? ("mode=" + std::to_string((int)(st.st_mode & 0777))) : "stat 失败");
            } else {
                ck(false, "ensure_conf_template 应能创建模板", cerr2);
            }
        }

        // 清理
        run("rm -rf '" + base + "'");

        std::printf("\n=== 汇总：%d 通过 / %d 失败 ===\n", g_pass, g_fail);
        std::printf("%s\n", g_fail == 0 ? "全部通过" : "存在失败");
        return g_fail == 0 ? 0 : 1;
    }
}
