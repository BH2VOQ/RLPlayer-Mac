// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
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
#include <spawn.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <thread>
#include <cstring>
#include <string>
#include <vector>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

extern char** environ;

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

// ---------------------------------------------------------------------------
// 【2026-11-07 新增】夹具：造一个**真的能挂载**的镜像
//
// 首选 hdiutil create -srcfolder（与线上发布的 UDZO 同构）。本机沙箱实测会拒绝
// create（"操作不被允许"），那就退到 hdiutil makehybrid -hfs —— 同一条 DiskImages
// 路径，只是格式不同：一样能 attach / 读文件 / detach，足以验证挂载点语义。
// 两条都不行 ⟹ 夹具造不出来，**如实失败**（不跳过断言、不伪造通过），并打印实际走的是哪条。
// ---------------------------------------------------------------------------
static bool make_image_fixture(const std::string& stageDir, const std::string& outBase,
                               std::string& outImage, std::string& why) {
    outImage.clear();
    why.clear();
    {
        const std::string img = outBase + ".udzo.dmg";
        ::unlink(img.c_str());
        const int rc = run("/usr/bin/hdiutil create -quiet -srcfolder '" + stageDir +
                           "' -format UDZO -volname FixtureF4 '" + img + "'");
        if (rc == 0 && file_exists(img)) {
            outImage = img;
            why = "hdiutil create(UDZO)";
            return true;
        }
    }
    {
        const std::string baseNoExt = outBase + ".hyb";
        run("rm -f '" + baseNoExt + ".dmg' '" + baseNoExt + ".iso'");
        const int rc = run("/usr/bin/hdiutil makehybrid -hfs -quiet -o '" + baseNoExt +
                           "' '" + stageDir + "'");
        const std::string img = baseNoExt + ".dmg";
        if (rc == 0 && file_exists(img)) {
            outImage = img;
            why = "hdiutil makehybrid(HFS)  ← hdiutil create 在本机被沙箱拒绝";
            return true;
        }
    }
    why = "hdiutil create 与 hdiutil makehybrid 都失败（造不出可挂载夹具）";
    return false;
}

// 数一数系统里还挂着几个引用这个镜像文件的设备（0 = 没有残留）。
// 为什么必须数它：只断言"函数返回 true"看不出设备泄漏 —— 而 11-07 事故的形态正是
// 「.app 装好了，但每跑一次就多留一个卸不掉的 disk」。用 -F 精确匹配路径。
static long long count_attached_images(const std::string& imagePath) {
    if (imagePath.empty()) return -1;
    FILE* p = ::popen(("/usr/bin/hdiutil info 2>/dev/null | /usr/bin/grep -F -c -- '" +
                       imagePath + "'").c_str(), "r");
    if (!p) return -1;
    char buf[64] = {0};
    long long n = -1;
    if (std::fgets(buf, sizeof buf, p)) n = std::atoll(buf);
    ::pclose(p);
    return n;
}

// 文件里是否出现某段文本（用来断言"失败/warning 真的写进了日志"）
static bool file_contains(const std::string& path, const std::string& needle) {
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return false;
    std::string s;
    char buf[4096];
    size_t n = 0;
    while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) s.append(buf, n);
    std::fclose(f);
    return s.find(needle) != std::string::npos;
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
            std::string backup, gerr, gwarn;
            const bool r = install_from_local_dmg(dmg, wrongSha, 0, mnt, target, backup, gerr, gwarn);
            ck(!r, "【篡改】install_from_local_dmg 拒绝安装", gerr);
            ck(backup.empty(), "【篡改】没有产生备份（说明连备份都没开始）", backup);
            ck(read_marker(target) == beforeSha,
               "【篡改】已安装的 .app 内容**逐字节未变**", read_marker(target));
            ck(file_size(target + "/Contents/MacOS/RLPlayer") == beforeSize,
               "【篡改】旧版文件大小未变（没被截断/覆盖）");
            ck(!dir_exists(mnt), "【篡改】挂载点未被创建（拒绝发生在挂载之前）");

            // 反向对照：同一份 dmg + **正确**摘要 ⟹ 必须真的换掉（否则上面那条可能只是"恒不变"）
            std::string backup2, gerr2, gwarn2;
            const std::string mnt2 = base + "/mnt-guard-ok";
            const bool r2 = install_from_local_dmg(dmg, realSha, file_size(dmg), mnt2, target, backup2, gerr2, gwarn2);
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

        // =====================================================================
        // 9. 【本次新增】真实下载进度：真 NSURLSession 打真本机 HTTP 服务
        //
        // 判据设计（铁律 3 —— "有回调"不等于"进度在推进"）：
        //   a) 回调**次数** ≥ 8（只报 0 和 40 的假进度会失败）
        //   b) pct **严格单调不减**，且至少出现 5 个不同的值（证明是连续推进）
        //   c) 首值接近 0、末值 == 40（覆盖下载全程 0→40）
        //   d) 落盘文件字节数与服务端发的**完全一致**（证明不是"进度假、文件也没下全"）
        //   e) 服务端分块慢发（每块 40ms）⟹ 进度必然是多点采样，不是一次跳到底
        // =====================================================================
        {
            set_test_allow_loopback_download(true);          // 仅本机 loopback，外部仍被白名单拒

            // 起一个分块慢发的 HTTP 服务（python3 系统自带）
            const std::string srvPy = base + "/srv.py";
            const std::string portFile = base + "/port.txt";
            const long long kBody = 640 * 1024;              // 640 KB（40 块 × 16KB ⟹ 足够多点采样）
            {
                FILE* f = std::fopen(srvPy.c_str(), "wb");
                std::string py;
                py += "import http.server, socketserver, time, sys\n";
                py += "N = " + std::to_string(kBody) + "\n";
                py += "class H(http.server.BaseHTTPRequestHandler):\n";
                py += "    def do_GET(self):\n";
                py += "        self.send_response(200)\n";
                py += "        self.send_header('Content-Length', str(N))\n";
                py += "        self.end_headers()\n";
                py += "        chunk = 16 * 1024\n";
                py += "        for i in range(0, N, chunk):\n";
                py += "            self.wfile.write(b'A' * min(chunk, N - i))\n";
                py += "            self.wfile.flush()\n";
                py += "            time.sleep(0.04)          # 慢发 ⟹ 强制多点采样\n";
                py += "    def log_message(self, *a): pass\n";
                py += "srv = socketserver.TCPServer(('127.0.0.1', 0), H)\n";
                py += "print(srv.server_address[1], flush=True)\n";
                py += "srv.serve_forever()\n";
                std::fwrite(py.data(), 1, py.size(), f);
                std::fclose(f);
            }
            const std::string srvCmd = "/usr/bin/python3 '" + srvPy + "' > '" + portFile + "' 2>&1 &";
            const int srvRc = std::system(srvCmd.c_str());
            ck(srvRc == 0, "起本机慢速 HTTP 服务", "rc=" + std::to_string(srvRc));

            int port = 0;
            for (int i = 0; i < 80 && port <= 0; ++i) {
                ::usleep(100 * 1000);
                FILE* f = std::fopen(portFile.c_str(), "r");
                if (!f) continue;
                char buf[32] = {0};
                if (std::fgets(buf, sizeof buf, f)) port = std::atoi(buf);
                std::fclose(f);
            }
            ck(port > 0, "拿到服务端口", "port=" + std::to_string(port));

            if (port > 0) {
                const std::string url = "http://127.0.0.1:" + std::to_string(port) + "/payload.bin";
                const std::string outFile = base + "/downloaded.bin";

                // ⚠️ ARC 的 block 按值捕获 C++ 对象会得到 **const 副本**，不能 push_back。
                //    用 shared_ptr 持有（生产侧 DownloadPctTracker 也是 shared_ptr，同一套思路）。
                auto pcts = std::make_shared<std::vector<int>>();
                auto bytes = std::make_shared<std::vector<long long>>();
                auto tracker = std::make_shared<DownloadPctTracker>();
                tracker->expectedSize = kBody;
                DownloadProgressFn prog = ^(long long written, long long total) {
                    bytes->push_back(written);
                    // 与生产**完全同一份**映射与单调逻辑（头文件里的纯函数 + tracker）
                    int pct = 0;
                    if (tracker->update(written, total, pct)) pcts->push_back(pct);
                };

                const auto t0 = std::chrono::steady_clock::now();
                const DownloadResult dr = download_to_file(url, "", outFile, 60, prog);
                const long long ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now() - t0).count();

                std::string seq;
                for (size_t i = 0; i < pcts->size(); ++i) {
                    if (i) seq += ",";
                    seq += std::to_string((*pcts)[i]);
                }
                std::printf("  [info] 下载耗时 %lld ms，进度回调 %zu 次\n", ms, pcts->size());
                std::printf("  [info] pct 序列 = [%s]\n", seq.c_str());

                ck(dr.ok, "流式下载成功（真 NSURLSession）", dr.error);
                ck(dr.status == 200, "HTTP 200", "status=" + std::to_string(dr.status));

                // 判据 a：次数够多（假进度只会 1~2 次）
                ck(pcts->size() >= 8, "进度回调次数 ≥ 8（证明是真流式，不是只有首尾两次）",
                   "calls=" + std::to_string(pcts->size()));

                // 判据 b：单调不减 + 至少 5 个不同值
                bool monotonic = true;
                for (size_t i = 1; i < pcts->size(); ++i) {
                    if ((*pcts)[i] < (*pcts)[i - 1]) { monotonic = false; break; }
                }
                ck(monotonic, "pct 单调不减（进度条绝不倒退）", seq);
                {
                    std::vector<int> uniq = *pcts;
                    std::sort(uniq.begin(), uniq.end());
                    uniq.erase(std::unique(uniq.begin(), uniq.end()), uniq.end());
                    ck(uniq.size() >= 5, "至少出现 5 个不同的 pct（连续推进，不是 0→40 直跳）",
                       "uniq=" + std::to_string(uniq.size()));
                }

                // 判据 c：覆盖 0→40 全程
                ck(!pcts->empty() && pcts->front() < InstallProgressRange::kDownloadEnd,
                   "首个 pct 在区间内（不是一上来就 40）",
                   pcts->empty() ? "empty" : std::to_string(pcts->front()));
                ck(!pcts->empty() && pcts->back() == InstallProgressRange::kDownloadEnd,
                   "末个 pct 恰好 = 40（下载阶段收满 0→40）",
                   pcts->empty() ? "empty" : std::to_string(pcts->back()));

                // 判据 d：落盘字节数 == 服务端发的
                ck(dr.bytes == kBody, "下载器报的字节数 == 服务端发送量",
                   std::to_string(dr.bytes) + " vs " + std::to_string(kBody));
                ck(file_size(outFile) == kBody, "落盘文件大小 == 服务端发送量",
                   std::to_string(file_size(outFile)) + " vs " + std::to_string(kBody));

                // 判据 e：字节数也单调（底层真在累加）
                bool bytesMono = true;
                for (size_t i = 1; i < bytes->size(); ++i) {
                    if ((*bytes)[i] < (*bytes)[i - 1]) { bytesMono = false; break; }
                }
                ck(bytesMono, "已收字节数单调不减");
            }

            // 停服务（只 kill -TERM 我们自己起的那个，按端口找属主）
            if (port > 0) {
                run("lsof -nP -iTCP:" + std::to_string(port) + " -sTCP:LISTEN -t | xargs -r kill -TERM");
                ::usleep(200 * 1000);
            }
        }

        // =====================================================================
        // 9b. 【本次新增】下载失败/取消 ⟹ 绝不留下半个文件
        //
        // 判据设计（铁律 3）：不能只断言"返回 false"，必须断言**文件系统上真的没有残留**。
        // 三种失败：① 服务端半路断开（EOF 早于 Content-Length）② HTTP 404 ③ 主动取消
        // =====================================================================
        {
            set_test_allow_loopback_download(true);

            // --- 9b-① 服务端发一半就断开 ---
            {
                const std::string truncPy = base + "/trunc.py";
                const std::string truncPort = base + "/truncport.txt";
                {
                    FILE* f = std::fopen(truncPy.c_str(), "wb");
                    const std::string py =
                        "import socket, sys\n"
                        "s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)\n"
                        "s.bind(('127.0.0.1', 0)); s.listen(1)\n"
                        "print(s.getsockname()[1], flush=True)\n"
                        "c, _ = s.accept()\n"
                        "c.recv(65536)\n"
                        "c.sendall(b'HTTP/1.1 200 OK\\r\\nContent-Length: 500000\\r\\n\\r\\n')\n"
                        "c.sendall(b'A' * 50000)   # 只发 10% 就关\n"
                        "c.close(); s.close()\n";
                    std::fwrite(py.data(), 1, py.size(), f);
                    std::fclose(f);
                }
                const int rr = std::system(("/usr/bin/python3 '" + truncPy + "' > '" + truncPort + "' 2>&1 &").c_str());
                int tp = 0;
                for (int i = 0; i < 60 && tp <= 0; ++i) {
                    ::usleep(100 * 1000);
                    FILE* f = std::fopen(truncPort.c_str(), "r");
                    if (!f) continue;
                    char buf[32] = {0};
                    if (std::fgets(buf, sizeof buf, f)) tp = std::atoi(buf);
                    std::fclose(f);
                }
                ck(rr == 0 && tp > 0, "起「半路断开」服务", "rc=" + std::to_string(rr));

                if (tp > 0) {
                    const std::string f1 = base + "/truncated.dmg";
                    const DownloadResult d1 = download_to_file(
                        "http://127.0.0.1:" + std::to_string(tp) + "/x.dmg", "", f1, 30, nil);
                    ck(!d1.ok, "【截断】服务端半路断开 ⟹ 下载失败", d1.error);
                    ck(!file_exists(f1), "【截断】目标文件不存在（没有半个 dmg 残留）", f1);
                    ck(!file_exists(f1 + ".part"), "【截断】临时 .part 文件也已清理", f1 + ".part");
                }
            }

            // --- 9b-② HTTP 404 ---
            {
                const std::string srv404 = base + "/srv404.py";
                const std::string p404 = base + "/p404.txt";
                {
                    FILE* f = std::fopen(srv404.c_str(), "wb");
                    const std::string py =
                        "import http.server, socketserver\n"
                        "class H(http.server.BaseHTTPRequestHandler):\n"
                        "    def do_GET(self):\n"
                        "        b = b'nope'\n"
                        "        self.send_response(404); self.send_header('Content-Length', str(len(b)))\n"
                        "        self.end_headers(); self.wfile.write(b)\n"
                        "    def log_message(self, *a): pass\n"
                        "srv = socketserver.TCPServer(('127.0.0.1', 0), H)\n"
                        "print(srv.server_address[1], flush=True); srv.serve_forever()\n";
                    std::fwrite(py.data(), 1, py.size(), f);
                    std::fclose(f);
                }
                std::system(("/usr/bin/python3 '" + srv404 + "' > '" + p404 + "' 2>&1 &").c_str());
                int p4 = 0;
                for (int i = 0; i < 60 && p4 <= 0; ++i) {
                    ::usleep(100 * 1000);
                    FILE* f = std::fopen(p404.c_str(), "r");
                    if (!f) continue;
                    char buf[32] = {0};
                    if (std::fgets(buf, sizeof buf, f)) p4 = std::atoi(buf);
                    std::fclose(f);
                }
                if (p4 > 0) {
                    const std::string f2 = base + "/notfound.dmg";
                    const DownloadResult d2 = download_to_file(
                        "http://127.0.0.1:" + std::to_string(p4) + "/x.dmg", "", f2, 30, nil);
                    ck(!d2.ok && d2.status == 404, "【404】非 2xx ⟹ 下载失败",
                       "status=" + std::to_string(d2.status) + " err=" + d2.error);
                    ck(!file_exists(f2), "【404】404 的错误页**没有**被当成 dmg 落盘", f2);
                }
            }

            // --- 9b-③ 主动取消 ---
            {
                const std::string slowPy = base + "/slow.py";
                const std::string slowPort = base + "/slowport.txt";
                {
                    FILE* f = std::fopen(slowPy.c_str(), "wb");
                    const std::string py =
                        "import http.server, socketserver, time\n"
                        "N = 4 * 1024 * 1024\n"
                        "class H(http.server.BaseHTTPRequestHandler):\n"
                        "    def do_GET(self):\n"
                        "        self.send_response(200); self.send_header('Content-Length', str(N))\n"
                        "        self.end_headers()\n"
                        "        try:\n"
                        "            for i in range(0, N, 8192):\n"
                        "                self.wfile.write(b'A' * 8192); self.wfile.flush(); time.sleep(0.02)\n"
                        "        except Exception: pass\n"
                        "    def log_message(self, *a): pass\n"
                        "srv = socketserver.TCPServer(('127.0.0.1', 0), H)\n"
                        "print(srv.server_address[1], flush=True); srv.serve_forever()\n";
                    std::fwrite(py.data(), 1, py.size(), f);
                    std::fclose(f);
                }
                std::system(("/usr/bin/python3 '" + slowPy + "' > '" + slowPort + "' 2>&1 &").c_str());
                int ps = 0;
                for (int i = 0; i < 60 && ps <= 0; ++i) {
                    ::usleep(100 * 1000);
                    FILE* f = std::fopen(slowPort.c_str(), "r");
                    if (!f) continue;
                    char buf[32] = {0};
                    if (std::fgets(buf, sizeof buf, f)) ps = std::atoi(buf);
                    std::fclose(f);
                }
                if (ps > 0) {
                    const std::string f3 = base + "/cancelled.dmg";
                    CancelToken tok;
                    // 200ms 后从另一个线程取消
                    std::thread canceller([&tok]() {
                        ::usleep(400 * 1000);
                        tok.cancel();
                    });
                    const auto t0 = std::chrono::steady_clock::now();
                    const DownloadResult d3 = download_to_file(
                        "http://127.0.0.1:" + std::to_string(ps) + "/big.dmg", "", f3, 60, nil, tok);
                    const long long ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                        std::chrono::steady_clock::now() - t0).count();
                    canceller.join();
                    ck(!d3.ok && d3.cancelled, "【取消】中途取消 ⟹ 报 cancelled（不是报成功）", d3.error);
                    ck(ms < 5000, "【取消】真的提前停了（没等 4MB 下完）",
                       "elapsed=" + std::to_string(ms) + "ms");
                    ck(!file_exists(f3), "【取消】取消后目标文件不存在", f3);
                    ck(!file_exists(f3 + ".part"), "【取消】取消后 .part 也清理了", f3 + ".part");
                    ck(tok.sameAs(tok), "CancelToken 复制语义：同一标志（shared_ptr）");
                    CancelToken copy = tok;
                    ck(copy.sameAs(tok) && copy.cancelled(), "CancelToken 副本共享同一取消状态");
                }
            }

            // 收尾：停掉本轮起的 python 服务（只 kill -TERM，按脚本名精确匹配自己起的临时文件）
            run("pkill -TERM -f '" + base + "/srv.py' 2>/dev/null; pkill -TERM -f '" + base + "/srv404.py' 2>/dev/null; pkill -TERM -f '" + base + "/slow.py' 2>/dev/null");
            ::usleep(150 * 1000);
        }

        // =====================================================================
        // 10. 【本次新增】白名单闸门没被测试开关撕开
        // 测试开关只放行 loopback；外部主机必须仍然被拒。
        // =====================================================================
        {
            set_test_allow_loopback_download(true);
            const std::string evil = base + "/evil.bin";
            const DownloadResult r1 = download_to_file("https://evil.example.com/x.dmg", "", evil, 5, nil);
            ck(!r1.ok && r1.error.find("白名单") != std::string::npos,
               "【安全】开关打开后，外部主机仍被白名单拒绝", r1.error);

            const DownloadResult r2 = download_to_file("http://127.0.0.1:1/x.dmg", "", evil, 5, nil);
            ck(!r2.ok && r2.error.find("白名单") == std::string::npos,
               "【对照】同一开关下 loopback 能过白名单（证明拒绝来自主机判断而非其他）", r2.error);

            set_test_allow_loopback_download(false);
            const DownloadResult r3 = download_to_file("http://127.0.0.1:1/x.dmg", "", evil, 5, nil);
            ck(!r3.ok && r3.error.find("白名单") != std::string::npos,
               "【安全】开关关闭后 loopback 也被拒（默认必须安全）", r3.error);
            ck(!file_exists(evil), "被拒的下载没有留下任何文件", evil);
        }

        // =====================================================================
        // 11. 【本次新增】进度百分比映射（纯函数，边界全覆盖）
        // =====================================================================
        {
            ck(download_percent(0, 100) == 0, "0/100 ⟹ 0%");
            ck(download_percent(50, 100) == 20, "50/100 ⟹ 20%（区间中点）");
            ck(download_percent(100, 100) == 40, "100/100 ⟹ 40%（上界）");
            ck(download_percent(200, 100) == 40, "超量也不越过 40（夹住）");
            ck(download_percent(50, 0) == 0, "总量未知 ⟹ 0（不瞎猜）");
            ck(download_percent(50, -1) == 0, "总量 -1 ⟹ 0");
            ck(download_percent(-5, 100) == 0, "负数进度 ⟹ 0");
            ck(InstallProgressRange::kDownloadEnd == 40 &&
               InstallProgressRange::kVerifyEnd == 60 &&
               InstallProgressRange::kInstallEnd == 95 &&
               InstallProgressRange::kDone == 100,
               "区间常量 = 0/40/60/95/100（用户指定的映射）");

            // tracker：单调 + 只在变化时上报
            DownloadPctTracker t;
            t.expectedSize = 1000;
            int out = -1;
            // 首帧 **必须**上报 0%：UI 要在下载一开始就把进度条摆到 0，
            // 而不是"什么都没有 → 突然出现在 4%"。这是设计意图，不是笔误。
            ck(t.update(0, 1000, out) == true && out == 0, "tracker：首帧上报 0%（UI 一开始就有起点）");
            ck(t.update(0, 1000, out) == false, "tracker：重复的 0 字节不再上报（不刷 UI）");
            ck(t.update(100, 1000, out) && out == 4, "tracker：10% ⟹ 4%");
            ck(t.update(500, 1000, out) && out == 20, "tracker：50% ⟹ 20%");
            ck(t.update(400, 1000, out) == false, "tracker：字节数回落 ⟹ 不上报（不倒退）");
            ck(t.update(1000, 1000, out) && out == 40, "tracker：100% ⟹ 40%");
            ck(t.update(1000, 1000, out) == false, "tracker：重复终值不再上报");
            // 分母优先用清单 size（服务端的 Content-Length 不可信/可缺失）
            DownloadPctTracker t2;
            t2.expectedSize = 0;
            ck(t2.update(50, 100, out) && out == 20, "tracker：清单没写 size ⟹ 用服务端总量");
        }

        // =====================================================================
        // 12. 【本次新增】自动重启脚本：内容 / 创建 / 真执行 / 失败回退
        // =====================================================================
        {
            // --- 12a 脚本正文（纯函数）：sleep 时长 + open -n + 自删 ---
            const std::string fakeApp = base + "/RestartMe.app";
            AutoRestartOptions ro;
            ro.sleepMs = 1500;
            const std::string body = auto_restart_script_body(fakeApp, ro);
            ck(body.find("#!/bin/bash") == 0, "脚本首行是 #!/bin/bash");
            ck(body.find("sleep 1.5") != std::string::npos, "脚本里 sleep 1.5（用户要求的约 1.5 秒）",
               body);
            ck(body.find("/usr/bin/open -n") != std::string::npos,
               "脚本用 open -n（新建实例，避免只激活旧实例）", body);
            ck(body.find(fakeApp) != std::string::npos, "脚本引用的是新的 .app 路径", body);
            ck(body.find("rm -f \"$0\"") != std::string::npos, "脚本执行完自删（不留垃圾）");

            // 路径带空格/中文也必须被正确引用（单引号包裹）
            {
                const std::string weird = base + "/带 空格的 App.app";
                const std::string b2 = auto_restart_script_body(weird, ro);
                ck(b2.find("'" + weird + "'") != std::string::npos,
                   "含空格/中文的 .app 路径被单引号正确包裹", b2);
            }
            // 毫秒精度（测试用短值时必须真的短）
            {
                AutoRestartOptions r300; r300.sleepMs = 300;
                ck(auto_restart_script_body(fakeApp, r300).find("sleep 0.300") != std::string::npos,
                   "非整秒 sleep 保留毫秒精度（sleep 0.300）");
            }

            // --- 12b 拒绝不存在的 .app（不能"重启"一个不存在的东西）---
            {
                std::string sp, se;
                const bool r = schedule_auto_restart(base + "/NoSuch.app", sp, se);
                ck(!r && sp.empty(), "对不存在的 .app 拒绝生成重启", se);
                ck(!se.empty(), "拒绝时给出可读原因（供 NSAlert 兜底）", se);
            }

            // --- 12c 真执行：脚本真的在 sleep 之后 open -n 了目标 ---
            // 用"假 .app"没法可靠断言 open 成功（open 一个非真 .app 会失败），
            // 所以这里直接验证**脚本本体能跑**：把 open 换成它自己的可观察副作用。
            // 判据：脚本被创建（0700）、能被 bash 执行、按 sleep 时长执行、并自删。
            {
                const std::string probeScript = base + "/probe-script.sh";
                {
                    // 与 auto_restart_script_body 同构，只把 open 换成写标记文件
                    FILE* f = std::fopen(probeScript.c_str(), "wb");
                    const std::string sh =
                        "#!/bin/bash\n"
                        "sleep 0.300\n"
                        "echo RAN > '" + base + "/probe.marker'\n"
                        "rm -f \"$0\" 2>/dev/null\n";
                    std::fwrite(sh.data(), 1, sh.size(), f);
                    std::fclose(f);
                }
                ::chmod(probeScript.c_str(), 0700);
                ck(file_exists(probeScript), "重启脚本可落盘", probeScript);

                const auto t0 = std::chrono::steady_clock::now();
                const int rc = std::system(("/bin/bash '" + probeScript + "'").c_str());
                const long long ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now() - t0).count();
                ck(rc == 0, "脚本能被 bash 执行（rc=0）", "rc=" + std::to_string(rc));
                ck(file_exists(base + "/probe.marker"), "脚本的副作用真的发生了（证明不是空跑）");
                ck(ms >= 280, "sleep 真的生效（≥280ms）", "elapsed=" + std::to_string(ms) + "ms");
                ck(!file_exists(probeScript), "脚本执行后自删（$0 清理生效）");
                run("rm -f '" + base + "/probe.marker'");
            }

            // --- 12d schedule_auto_restart 真的能创建脚本并派发（spawn=false 只写不跑）---
            {
                make_fake_app(base + "/SpawnMe.app", "X");
                std::string sp, se;
                AutoRestartOptions rq;
                rq.spawn = false;            // 只验证"能写出来"
                const bool ok = schedule_auto_restart(base + "/SpawnMe.app", sp, se, rq);
                ck(ok && !sp.empty(), "schedule_auto_restart 能创建脚本", se);
                ck(file_exists(sp), "脚本文件确实存在", sp);
                {
                    struct stat st {};
                    const bool got = (::stat(sp.c_str(), &st) == 0);
                    ck(got && (st.st_mode & 0111) != 0, "脚本有可执行位（0700）",
                       got ? ("mode=" + std::to_string((int)(st.st_mode & 0777))) : "stat 失败");
                }
                // 内容与 auto_restart_script_body 一致
                std::string got;
                {
                    FILE* f = std::fopen(sp.c_str(), "rb");
                    if (f) {
                        char buf[4096];
                        const size_t n = std::fread(buf, 1, sizeof buf, f);
                        got.assign(buf, n);
                        std::fclose(f);
                    }
                }
                ck(got.find("/usr/bin/open -n") != std::string::npos &&
                   got.find(base + "/SpawnMe.app") != std::string::npos,
                   "落盘内容含 open -n 与目标 .app", got.substr(0, 200));
                ::unlink(sp.c_str());
            }

            // --- 12e 真派发一条（spawn=true），证明 posix_spawn(SETSID) 能起子进程 ---
            // 判据：脚本执行后它写出的标记文件存在。用 sleepMs=300 + waitPid=0（不等任何人）。
            {
                const std::string realApp = base + "/RealSpawn.app";
                make_fake_app(realApp, "Y");
                const std::string marker = base + "/spawn.marker";
                run("rm -f '" + marker + "'");
                // 用 auto_restart_script_body 打底，把 open 换成一个必然成功的可观察动作
                // （真 open 一个假 .app 会失败，这会掩盖"派发链路通不通"这个要测的点）
                std::string sp2, se2;
                {
                    // 直接构造：写完通过同一个 posix_spawn 路径派发
                    const std::string sh = base + "/realspawn.sh";
                    FILE* f = std::fopen(sh.c_str(), "wb");
                    const std::string bodySh =
                        "#!/bin/bash\n"
                        "sleep 0.300\n"
                        "echo DISPATCHED > '" + marker + "'\n"
                        "rm -f \"$0\" 2>/dev/null\n";
                    std::fwrite(bodySh.data(), 1, bodySh.size(), f);
                    std::fclose(f);
                    ::chmod(sh.c_str(), 0700);
                    // 复刻 schedule_auto_restart 的派发方式
                    posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
                    posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
                    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
                    posix_spawnattr_t at; posix_spawnattr_init(&at);
                    posix_spawnattr_setflags(&at, POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT);
                    // ⚠️ 必须先把命令串存成具名 std::string：写成临时表达式的 .c_str()，
                    //    临时对象在 posix_spawn 之前就析构了 ⟹ argv 指向已释放内存（
                    //    clang 的 -Wdangling-gsl 正是报这个）。实测症状：spawn 返回 0，
                    //    但子进程拿到垃圾参数、脚本根本没执行。
                    const std::string spawnCmd = "/bin/bash '" + sh + "'";
                    const char* av[] = {"/bin/bash", "-c", spawnCmd.c_str(), nullptr};
                    pid_t pid = 0;
                    const int src = ::posix_spawn(&pid, "/bin/bash", &fa, &at,
                                                  const_cast<char* const*>(av), environ);
                    posix_spawnattr_destroy(&at);
                    posix_spawn_file_actions_destroy(&fa);
                    ck(src == 0, "posix_spawn(SETSID) 派发成功（rc=0）",
                       "rc=" + std::to_string(src));
                    // 等它跑完（脚本 300ms sleep + 余量）
                    for (int i = 0; i < 60 && !file_exists(marker); ++i) ::usleep(50 * 1000);
                    ck(file_exists(marker),
                       "分离子进程真的执行了脚本（标记文件出现 ⟹ 派发链路通）", marker);
                }
                (void)sp2; (void)se2; (void)realApp;
            }
        }

        // =====================================================================
        // 13. 【本次新增·最关键】完整流水线端到端：真下载 → 真校验 → 真挂载 → 真安装
        //
        // 这是**整条 begin_install 的实质内容**（run_install_pipeline），只把 targetApp
        // 指到 /tmp、autoRestart 关掉。因此它证明的是：
        //   a) 进度 pct 覆盖**全部四个区间** 0→40→60→95→100，且全程单调不减
        //   b) sha256+size 校验真的发生在挂载**之前**（用坏摘要撞：挂载点必须没被创建）
        //   c) 好包能真装进去（内容可核对）
        //   d) 坏包被丢弃、不挂载、目标 .app 一个字节都没变
        // =====================================================================
        {
            set_test_allow_loopback_download(true);

            // 造真 dmg（复用第 1 步那份 stage/dmg 的构造方式，但单独一份避免相互影响）
            const std::string pipeBase = base + "/pipe";
            run("mkdir -p '" + pipeBase + "/stage'");
            ck(make_fake_app(pipeBase + "/stage/RLPlayer.app", "PIPE-PAYLOAD-v9.9.9"),
               "流水线：构造最小 .app");
            const std::string pipeDmg = pipeBase + "/update.dmg";
            const int crc2 = run("/usr/bin/hdiutil create -quiet -srcfolder '" + pipeBase + "/stage'"
                                 " -format UDZO -volname PipeF4 '" + pipeDmg + "'");
            ck(crc2 == 0 && file_exists(pipeDmg), "流水线：造真 dmg");
            std::string pipeSha;
            std::string pkErr;
            ck(sha256_of_file(pipeDmg, pipeSha, pkErr), "流水线：算 dmg 摘要", pkErr);
            const long long pipeSize = file_size(pipeDmg);

            // 起一个把该 dmg 原样吐出来的 HTTP 服务
            const std::string srvPy = pipeBase + "/srv.py";
            const std::string portFile = pipeBase + "/port.txt";
            {
                FILE* f = std::fopen(srvPy.c_str(), "wb");
                std::string py;
                py += "import http.server, socketserver, time\n";
                py += "PATH = " + std::string("'") + pipeDmg + "'\n";
                py += "DATA = open(PATH,'rb').read()\n";
                py += "class H(http.server.BaseHTTPRequestHandler):\n";
                py += "    def do_GET(self):\n";
                py += "        self.send_response(200)\n";
                py += "        self.send_header('Content-Length', str(len(DATA)))\n";
                py += "        self.end_headers()\n";
                py += "        chunk = max(1, len(DATA)//24)\n";
                py += "        for i in range(0, len(DATA), chunk):\n";
                py += "            self.wfile.write(DATA[i:i+chunk]); self.wfile.flush(); time.sleep(0.03)\n";
                py += "    def log_message(self, *a): pass\n";
                py += "srv = socketserver.TCPServer(('127.0.0.1', 0), H)\n";
                py += "print(srv.server_address[1], flush=True); srv.serve_forever()\n";
                std::fwrite(py.data(), 1, py.size(), f);
                std::fclose(f);
            }
            std::system(("/usr/bin/python3 '" + srvPy + "' > '" + portFile + "' 2>&1 &").c_str());
            int port = 0;
            for (int i = 0; i < 100 && port <= 0; ++i) {
                ::usleep(100 * 1000);
                FILE* f = std::fopen(portFile.c_str(), "r");
                if (!f) continue;
                char buf[32] = {0};
                if (std::fgets(buf, sizeof buf, f)) port = std::atoi(buf);
                std::fclose(f);
            }
            ck(port > 0, "流水线：dmg HTTP 服务就绪", "port=" + std::to_string(port));

            if (port > 0) {
                const std::string url = "http://127.0.0.1:" + std::to_string(port) + "/u.dmg";

                // ---------- 13a 好包：全区间进度 + 真装进去 ----------
                {
                    CheckResult plan;
                    plan.decision = Decision::UpdateAvailable;
                    plan.remoteVersion = "9.9.9";
                    plan.downloadUrl = url;
                    plan.sha256 = pipeSha;
                    plan.size = pipeSize;

                    const std::string target = pipeBase + "/Applications/RLPlayer.app";
                    run("mkdir -p '" + pipeBase + "/Applications'");

                    auto pcts = std::make_shared<std::vector<int>>();
                    auto stages = std::make_shared<std::vector<std::string>>();
                    ProgressFn prog = ^(const NativeProgress& pr) {
                        if (pr.percent >= 0) pcts->push_back(pr.percent);
                        stages->push_back(pr.stage + "/" + std::to_string(pr.percent));
                    };

                    InstallPipelineOptions opt;
                    opt.targetApp = target;
                    opt.dmgPath = pipeBase + "/pipe.dmg";
                    opt.mountPoint = pipeBase + "/pipe-mnt";
                    opt.autoRestart = false;              // ← 测试绝不真的重启

                    std::string perr, pbackup;
                    const bool pok = run_install_pipeline(plan, prog, CancelToken(), opt, perr, pbackup);

                    std::string seq;
                    for (size_t i = 0; i < pcts->size(); ++i) {
                        if (i) seq += ",";
                        seq += std::to_string((*pcts)[i]);
                    }
                    std::printf("  [info] 流水线 pct 序列（%zu 个）= [%s]\n", pcts->size(), seq.c_str());

                    ck(pok, "流水线：好包安装成功", perr);
                    ck(read_marker(target) == "PIPE-PAYLOAD-v9.9.9",
                       "流水线：装进去的确实是包里那份（内容可核对）", read_marker(target));

                    // a) 单调不减
                    bool mono = true;
                    for (size_t i = 1; i < pcts->size(); ++i) {
                        if ((*pcts)[i] < (*pcts)[i - 1]) { mono = false; break; }
                    }
                    ck(mono, "流水线：pct 全程单调不减", seq);

                    // b) 覆盖四个区间（这是"进度真的走完全程"的判据，不是"有回调"）
                    auto has = [&](int v) {
                        return std::find(pcts->begin(), pcts->end(), v) != pcts->end();
                    };
                    ck(has(InstallProgressRange::kDownloadEnd),
                       "流水线：出现 40（下载阶段收满）", seq);
                    ck(has(InstallProgressRange::kVerifyEnd),
                       "流水线：出现 60（校验阶段收满）", seq);
                    ck(has(InstallProgressRange::kInstallEnd),
                       "流水线：出现 95（安装阶段收满）", seq);
                    ck(has(InstallProgressRange::kDone),
                       "流水线：出现 100（完成）", seq);
                    ck(pcts->size() >= 10,
                       "流水线：上报次数 ≥ 10（下载段多点采样 + 3 个阶段标记）",
                       "n=" + std::to_string(pcts->size()));

                    // c) 阶段名确实出现过
                    {
                        bool sawVerify = false, sawInstall = false;
                        for (const auto& st : *stages) {
                            if (st.rfind("verifying", 0) == 0) sawVerify = true;
                            if (st.rfind("installing", 0) == 0) sawInstall = true;
                        }
                        ck(sawVerify, "流水线：上报过 verifying 阶段");
                        ck(sawInstall, "流水线：上报过 installing 阶段");
                    }
                    // d) 临时 dmg 被清理
                    ck(!file_exists(opt.dmgPath), "流水线：安装后临时 dmg 已删除", opt.dmgPath);
                }

                // ---------- 13b 坏摘要：必须**在挂载之前**被拒 ----------
                {
                    CheckResult bad;
                    bad.decision = Decision::UpdateAvailable;
                    bad.remoteVersion = "9.9.9";
                    bad.downloadUrl = url;
                    bad.sha256 = std::string(64, 'c');        // 与真摘要必然不同
                    bad.size = pipeSize;

                    const std::string target2 = pipeBase + "/Applications2/RLPlayer.app";
                    run("mkdir -p '" + pipeBase + "/Applications2'");
                    ck(make_fake_app(target2, "OLD-INSTALLED-v1"), "流水线：预置一份旧版");
                    const std::string beforeMarker = read_marker(target2);

                    InstallPipelineOptions opt;
                    opt.targetApp = target2;
                    opt.dmgPath = pipeBase + "/pipe-bad.dmg";
                    opt.mountPoint = pipeBase + "/pipe-bad-mnt";
                    opt.autoRestart = false;

                    std::string berr, bbackup;
                    const bool bok = run_install_pipeline(bad, nil, CancelToken(), opt, berr, bbackup);

                    ck(!bok, "【安全】流水线：坏摘要 ⟹ 安装失败", berr);
                    ck(berr.find("校验失败") != std::string::npos,
                       "【安全】失败原因明确是校验失败（不是网络/挂载别的原因）", berr);
                    ck(!dir_exists(opt.mountPoint),
                       "【安全·最关键】挂载点**从未被创建** ⟹ 校验确实发生在挂载之前", opt.mountPoint);
                    ck(!file_exists(opt.dmgPath), "【安全】坏包已被丢弃（unlink）", opt.dmgPath);
                    ck(read_marker(target2) == beforeMarker,
                       "【安全】已有 .app 内容逐字节未变", read_marker(target2));
                    ck(bbackup.empty(), "【安全】没有产生备份（连备份都没开始）", bbackup);
                }
            }

            run("pkill -TERM -f '" + srvPy + "' 2>/dev/null");
            ::usleep(150 * 1000);
            set_test_allow_loopback_download(false);
        }


        // =====================================================================
        // 14. 【本次修复·A】挂载点已被别的真镜像占着 ⟹ 先清路再挂，绝不叠挂
        //
        // 现场（2026-11-07）：写死的挂载点 <temp>/rlplayer-update-mnt 上还挂着 11-06
        // 那次更新留下的 disk25，第二天再走同一路径。
        // 本机实测：hdiutil attach -mountpoint <已被占用的路径> 会**成功**并把新卷
        // 盖在旧卷上面（rc=0），旧卷从此既看不见也卸不掉 ⟹ 收尾 detach 就是"资源忙"。
        //
        // 判据设计（铁律 3：不能只断言"返回 true"）：
        //   a) 前提成立：调用前挂载点上**确实**挂着一个镜像，且内容是可核对的旧载荷
        //   b) install_from_local_dmg 返回 true 且 err 为空
        //   c) 目标 .app 的内容是**新**镜像里的那份（证明真的换了，不是没动）
        //   d) 收尾后 hdiutil info 里**一个**挂着这两个镜像的设备都不剩
        //      （旧实现在这里会留下"旧"镜像 —— 这正是事故里 disk23/26/27 的来源）
        // =====================================================================
        {
            const std::string occBase = base + "/occ";
            run("mkdir -p '" + occBase + "/stage-old' '" + occBase + "/stage-new'");
            ck(make_fake_app(occBase + "/stage-old/RLPlayer.app", "PAYLOAD-OLD-A"),
               "【A】构造「旧」镜像载荷");
            ck(make_fake_app(occBase + "/stage-new/RLPlayer.app", "PAYLOAD-NEW-B"),
               "【A】构造「新」镜像载荷");

            std::string imgOld, imgNew, howOld, howNew;
            const bool okOld = make_image_fixture(occBase + "/stage-old", occBase + "/img-old",
                                                  imgOld, howOld);
            const bool okNew = make_image_fixture(occBase + "/stage-new", occBase + "/img-new",
                                                  imgNew, howNew);
            std::printf("  [info] 夹具镜像：old=%s（%s）  new=%s（%s）\n",
                        imgOld.c_str(), howOld.c_str(), imgNew.c_str(), howNew.c_str());
            ck(okOld && file_exists(imgOld), "【A】造出「旧」镜像（真能挂载的那种）", howOld);
            ck(okNew && file_exists(imgNew), "【A】造出「新」镜像（真能挂载的那种）", howNew);

            // 挂载点名成我们自己的命名（万一本机需要 -force 兜底时守卫能放行；正常路径不会用到）
            const std::string mpOcc = base + "/rlplayer-update-mnt-occ";
            std::string srcApp, aerr;
            const bool preMounted = mount_image(imgOld, mpOcc, srcApp, aerr);
            ck(preMounted, "【A】前提：先把「旧」镜像挂到目标挂载点", aerr);
            ck(is_mount_point(mpOcc),
               "【A】前提：该路径确实已是挂载点（is_mount_point 判定正确）", mpOcc);
            ck(!srcApp.empty() && read_marker(srcApp) == "PAYLOAD-OLD-A",
               "【A】前提：挂载点上此刻真的躺着旧载荷", read_marker(srcApp));

            std::string shaNew, aShaErr;
            ck(sha256_of_file(imgNew, shaNew, aShaErr), "【A】算「新」镜像的摘要", aShaErr);

            const std::string targetOcc = base + "/occ-apps/RLPlayer.app";
            run("mkdir -p '" + base + "/occ-apps'");
            std::string backupOcc, insErr, warnOcc;
            const bool okOcc = install_from_local_dmg(imgNew, shaNew, file_size(imgNew),
                                                      mpOcc, targetOcc, backupOcc, insErr, warnOcc);
            ck(okOcc, "【A】挂载点被占用时安装仍然成功（先清路，不是硬往上叠）", insErr);
            ck(insErr.empty(), "【A】成功时 err 为空", insErr);
            ck(warnOcc.empty(), "【A】正常卸载不产生 warning", warnOcc);
            ck(read_marker(targetOcc) == "PAYLOAD-NEW-B",
               "【A】装进去的是**新**镜像里的那份", read_marker(targetOcc));
            ck(!dir_exists(mpOcc), "【A】挂载点目录已清掉（rmdir，不留空壳）", mpOcc);

            const long long leftOld = count_attached_images(imgOld);
            const long long leftNew = count_attached_images(imgNew);
            std::printf("  [info] 安装后仍 attach 的设备数：old=%lld new=%lld\n", leftOld, leftNew);
            ck(leftOld == 0, "【A】旧镜像已彻底卸下（hdiutil info 里 0 条）",
               "count=" + std::to_string(leftOld));
            ck(leftNew == 0, "【A】新镜像也已彻底卸下（0 条）",
               "count=" + std::to_string(leftNew));
        }

        // =====================================================================
        // 15. 【本次修复·B】卸载失败不再算整单失败（注入式强制失败）
        //
        // 现场（2026-11-07 11:07）：.app 已经从 1.1.3.2 换成 1.1.4-beta1（备份也在），
        // 但 UI 报「检查失败：hdiutil detach 失败 … couldn't eject "disk25" - 资源忙」，
        // 也没有自动重启。用户以为没更新，实际已经更新了。
        //
        // 判据：
        //   ① install_from_local_dmg：装成功 + 卸载失败 ⟹ **返回 true**、err 为空、warning 非空
        //   ② run_install_pipeline：同样返回 true（不再整单失败），且 .app 已换好
        //   ③ 那条 warning 必须**落盘**（UPDATE_UNMOUNT_WARN stage=unmount err=…）
        //   ④ 流水线的默认挂载点 = <temp>/rlplayer-update-mnt-<pid>（每轮唯一，不写死）
        //   ⑤ 测试自己把挂载残留清干净（不许把这个测试变成新的"disk25"来源）
        // =====================================================================
        {
            const std::string fBase = base + "/fu";
            run("mkdir -p '" + fBase + "/stage'");
            ck(make_fake_app(fBase + "/stage/RLPlayer.app", "PAYLOAD-C"), "【B】构造镜像载荷");
            std::string imgFu, howFu, shaFu, bShaErr;
            ck(make_image_fixture(fBase + "/stage", fBase + "/img", imgFu, howFu),
               "【B】造出可挂载镜像", howFu);
            ck(sha256_of_file(imgFu, shaFu, bShaErr), "【B】算镜像摘要", bShaErr);
            const long long szFu = file_size(imgFu);
            std::printf("  [info] 镜像夹具：%s（%s） size=%lld\n",
                        imgFu.c_str(), howFu.c_str(), szFu);

            // ---------- B-① install_from_local_dmg + 注入强制卸载失败 ----------
            {
                const std::string targetB = base + "/fu-apps/RLPlayer.app";
                run("mkdir -p '" + base + "/fu-apps'");
                const std::string mpFu = base + "/rlplayer-update-mnt-fu";

                set_test_force_unmount_failure(true);
                std::string backupB, errB, warnB;
                const bool okB = install_from_local_dmg(imgFu, shaFu, szFu, mpFu, targetB,
                                                        backupB, errB, warnB);
                set_test_force_unmount_failure(false);   // 立刻关掉：后面的真卸载不能被注入污染

                ck(okB, "【B】装成功但卸载失败 ⟹ install_from_local_dmg 仍返回 true", errB);
                ck(errB.empty(), "【B】返回 true 时 err 必须为空（warning 不许混进 err）", errB);
                ck(!warnB.empty(), "【B】warning 被带出来（调用方能看到「没卸干净」）", warnB);
                ck(read_marker(targetB) == "PAYLOAD-C",
                   "【B】.app 确实已经换成新版（更新是真的生效了）", read_marker(targetB));
                ck(is_mount_point(mpFu),
                   "【B】注入确实生效：那一刻挂载点还挂着（证明卸载真的失败了）", mpFu);

                std::string cleanErr;
                ck(unmount_image(mpFu, cleanErr),
                   "【B】关掉注入后能真正卸掉（本测试不留挂载残留）", cleanErr);
                ck(!is_mount_point(mpFu), "【B】挂载点已清", mpFu);
            }

            // ---------- B-② run_install_pipeline 也不再整单失败 ----------
            {
                const std::string srvFu = fBase + "/srv.py";
                const std::string portFu = fBase + "/port.txt";
                {
                    FILE* f = std::fopen(srvFu.c_str(), "wb");
                    std::string py;
                    py += "import http.server, socketserver\n";
                    py += "DATA = open('" + imgFu + "','rb').read()\n";
                    py += "class H(http.server.BaseHTTPRequestHandler):\n";
                    py += "    def do_GET(self):\n";
                    py += "        self.send_response(200)\n";
                    py += "        self.send_header('Content-Length', str(len(DATA)))\n";
                    py += "        self.end_headers()\n";
                    py += "        self.wfile.write(DATA); self.wfile.flush()\n";
                    py += "    def log_message(self, *a): pass\n";
                    py += "srv = socketserver.TCPServer(('127.0.0.1', 0), H)\n";
                    py += "print(srv.server_address[1], flush=True); srv.serve_forever()\n";
                    std::fwrite(py.data(), 1, py.size(), f);
                    std::fclose(f);
                }
                std::system(("/usr/bin/python3 '" + srvFu + "' > '" + portFu + "' 2>&1 &").c_str());
                int port = 0;
                for (int i = 0; i < 100 && port <= 0; ++i) {
                    ::usleep(100 * 1000);
                    FILE* f = std::fopen(portFu.c_str(), "r");
                    if (!f) continue;
                    char buf[32] = {0};
                    if (std::fgets(buf, sizeof buf, f)) port = std::atoi(buf);
                    std::fclose(f);
                }
                ck(port > 0, "【B】本地 dmg HTTP 服务就绪", "port=" + std::to_string(port));

                if (port > 0) {
                    CheckResult plan;
                    plan.decision = Decision::UpdateAvailable;
                    plan.remoteVersion = "9.9.9-fu";
                    plan.downloadUrl = "http://127.0.0.1:" + std::to_string(port) + "/u.dmg";
                    plan.sha256 = shaFu;
                    plan.size = szFu;

                    const std::string targetP = base + "/fu-pipe/RLPlayer.app";
                    run("mkdir -p '" + base + "/fu-pipe'");
                    InstallPipelineOptions opt;
                    opt.targetApp = targetP;
                    opt.dmgPath = fBase + "/pipe.dmg";
                    // ⚠️ mountPoint 故意留空：要验证**默认**挂载点是每轮唯一的
                    //    <temp>/rlplayer-update-mnt-<pid>，而不是写死的老名字
                    opt.autoRestart = false;      // 测试绝不真的 open 一个 .app

                    const std::string defMp = rta::platform::join(
                        rta::platform::temp_dir_utf8(),
                        "rlplayer-update-mnt-" + std::to_string((long long)::getpid()));

                    // loopback 下载闸门只在本测试里放行（外部地址仍被白名单拒）
                    set_test_allow_loopback_download(true);
                    set_test_force_unmount_failure(true);
                    std::string perr, pbackup;
                    const bool okP = run_install_pipeline(plan, nil, CancelToken(), opt, perr, pbackup);
                    set_test_force_unmount_failure(false);
                    set_test_allow_loopback_download(false);

                    ck(okP, "【B】流水线：卸载失败也返回 true（整单不再失败）", perr);
                    ck(perr.empty(), "【B】流水线：err 为空（不该把 warning 当失败）", perr);
                    ck(read_marker(targetP) == "PAYLOAD-C",
                       "【B】流水线：新版本确实装好了", read_marker(targetP));
                    ck(is_mount_point(defMp),
                       "【B】流水线默认挂载点 = <temp>/rlplayer-update-mnt-<pid>（且当时确实挂着）",
                       defMp);
                    ck(defMp.find("rlplayer-update-mnt-" + std::to_string((long long)::getpid())) !=
                       std::string::npos,
                       "【B】默认挂载点带 pid（每轮唯一，不再写死老名字）", defMp);

                    const std::string logPath = rta::platform::join(
                        rta::platform::config_dir_utf8(), "rlplayer-update.log");
                    ck(file_contains(logPath, "UPDATE_UNMOUNT_WARN stage=unmount err="),
                       "【B】UPDATE_UNMOUNT_WARN 已落盘到 rlplayer-update.log", logPath);

                    std::string cleanErr2;
                    ck(unmount_image(defMp, cleanErr2),
                       "【B】关掉注入后流水线的挂载点也能真卸掉（不留残留）", cleanErr2);
                }
                std::system(("pkill -TERM -f '" + srvFu + "' 2>/dev/null").c_str());
                ::usleep(150 * 1000);
            }
        }

        // =====================================================================
        // 16. 【本次修复·C】-force 的保险丝：is_own_temp_mount()
        //
        // 这是**唯一**允许 `hdiutil detach -force` 的守卫。判错的后果不是"更新失败"，
        // 而是**强制卸载用户真盘/外接盘上的卷**。所以必须单独测，且"必须 false"的那几
        // 条一个都不能少。
        // =====================================================================
        {
            const std::string tmpDir = rta::platform::temp_dir_utf8();
            ck(!tmpDir.empty(), "temp_dir_utf8 非空", tmpDir);
            std::printf("  [info] temp_dir_utf8 = [%s]\n", tmpDir.c_str());

            const std::string leaf = "rlplayer-update-mnt-" + std::to_string((long long)::getpid());
            const std::string own = rta::platform::join(tmpDir, leaf);
            ck(is_own_temp_mount(own), "【C】temp 目录下 rlplayer-update-mnt* ⟹ true", own);
            ck(is_own_temp_mount(own + "-occ"),
               "【C】同前缀的后缀变体也算自己的（...-occ）", own + "-occ");
            ck(is_own_temp_mount(rta::platform::join(tmpDir, "rlplayer-update-mnt")),
               "【C】老名字（不带后缀）同一判定 ⟹ true（兼容旧残留的清理）");

            ck(!is_own_temp_mount(rta::platform::join(tmpDir, "someone-else-mnt")),
               "【C】temp 下但 basename 前缀不对 ⟹ false");
            ck(!is_own_temp_mount(rta::platform::join(tmpDir, "rlplayer-update")),
               "【C】前缀更短（rlplayer-update）⟹ false");
            ck(!is_own_temp_mount(rta::platform::join(tmpDir, "xrlplayer-update-mnt-1")),
               "【C】前缀不在开头 ⟹ false");
            ck(!is_own_temp_mount(own + "/RLPlayer.app"),
               "【C】挂载点**里面**的子路径 ⟹ false（只认挂载点本身）", own + "/RLPlayer.app");

            ck(!is_own_temp_mount("/Applications/rlplayer-update-mnt-1"),
               "【C】/Applications 下的同名 ⟹ false（绝不 force 用户的应用盘）");
            ck(!is_own_temp_mount("/Volumes/Backup/rlplayer-update-mnt-1"),
               "【C】/Volumes/... 下的同名 ⟹ false（绝不 force 外接盘）");
            ck(!is_own_temp_mount("/Users/Shared/rlplayer-update-mnt-1"),
               "【C】用户目录下的同名 ⟹ false");
            ck(!is_own_temp_mount("/"), "【C】根目录 ⟹ false");
            ck(!is_own_temp_mount(""), "【C】空串 ⟹ false");
            ck(!is_own_temp_mount("rlplayer-update-mnt-1"),
               "【C】相对路径 ⟹ false（不是绝对路径就不能证明在 temp 下）");
            ck(!is_own_temp_mount(tmpDir), "【C】temp 目录本身不是挂载点 ⟹ false", tmpDir);

            // /var 与 /private/var（/tmp 与 /private/tmp）必须归一化后等价 ——
            // 内核挂载表里记的是 /private/... 那一份，调用方传的常是 /var 或 /tmp。
            ck(is_own_temp_mount("/private" + own),
               "【C】/var(=/tmp) 与 /private/var 归一化后等价 ⟹ true", "/private" + own);

            // is_mount_point 的基本判定（真挂载点的那条在用例 A/B 里已经验过）
            ck(!is_mount_point(""), "【C】空串不是挂载点");
            ck(!is_mount_point("/tmp/no-such-mount-pt-" + std::to_string((long long)::getpid())),
               "【C】不存在的路径不是挂载点");
            ck(is_mount_point("/"), "【C】/ 是挂载点（f_mntonname == /）");
            ck(!is_mount_point("/Applications"),
               "【C】/Applications 不是挂载点（在数据卷里，不是卷根）");
        }

        // =====================================================================
        // 17. 【本次修复·D】install 阶段失败必须落盘（UPDATE_INSTALL_FAIL）
        //
        // 现场（2026-11-07）：整单失败时 rlplayer-update.log 里只有一行 BEGIN_INSTALL_ENTER，
        // 到底是 verify / mount / install 哪一步、什么原因，**完全没有**，事后无法复盘。
        // 三个 stage 各撞一次，逐个断言日志里有对应记录。
        // =====================================================================
        {
            const std::string lBase = base + "/logf";
            run("mkdir -p '" + lBase + "'");
            const std::string logPath = rta::platform::join(
                rta::platform::config_dir_utf8(), "rlplayer-update.log");

            // ---------- D-① verify 失败 ----------
            {
                std::string imgL, howL, shaL, e0;
                run("mkdir -p '" + lBase + "/stage'");
                make_fake_app(lBase + "/stage/RLPlayer.app", "PAYLOAD-D");
                if (make_image_fixture(lBase + "/stage", lBase + "/img", imgL, howL) &&
                    sha256_of_file(imgL, shaL, e0)) {
                    std::string bk, er, wn;
                    const std::string wrongSha(64, 'd');
                    const bool bad = install_from_local_dmg(imgL, wrongSha, 0,
                                                            base + "/rlplayer-update-mnt-v",
                                                            base + "/logf/t1.app", bk, er, wn);
                    ck(!bad && !er.empty(), "【D】坏摘要 ⟹ 安装失败（前提）", er);
                    ck(file_contains(logPath, "UPDATE_INSTALL_FAIL stage=verify err="),
                       "【D】verify 失败已落盘（stage=verify）", logPath);
                } else {
                    ck(false, "【D】准备好 verify 用例的镜像夹具", howL);
                }
            }

            // ---------- D-② mount 失败（摘要全对、但根本不是镜像）----------
            {
                const std::string notImage = lBase + "/not-an-image.bin";
                {
                    FILE* f = std::fopen(notImage.c_str(), "wb");
                    if (f) { const char* junk = "this is definitely not a disk image\n"; std::fwrite(junk, 1, std::strlen(junk), f); std::fclose(f); }
                }
                std::string shaJ, e1;
                ck(sha256_of_file(notImage, shaJ, e1), "【D】算「非镜像文件」的摘要", e1);
                std::string bk, er, wn;
                const bool bad = install_from_local_dmg(notImage, shaJ, file_size(notImage),
                                                        base + "/rlplayer-update-mnt-m",
                                                        base + "/logf/t2.app", bk, er, wn);
                ck(!bad, "【D】摘要对但不是镜像 ⟹ 挂载失败（前提）", er);
                ck(er.find("hdiutil attach") != std::string::npos || er.find("挂载点") != std::string::npos,
                   "【D】失败原因确实是挂载（不是校验）", er);
                ck(file_contains(logPath, "UPDATE_INSTALL_FAIL stage=mount err="),
                   "【D】mount 失败已落盘（stage=mount）", logPath);
            }

            // ---------- D-③ install 失败（能挂载，但目标位置写不进去）----------
            {
                std::string imgL, howL, shaL, e2;
                const bool haveImg = make_image_fixture(lBase + "/stage", lBase + "/img2", imgL, howL) &&
                                     sha256_of_file(imgL, shaL, e2);
                ck(haveImg, "【D】准备 install 用例的镜像夹具", howL);
                if (haveImg) {
                    std::string bk, er, wn;
                    // /dev/null/RLPlayer.app ⟹ ditto 必然 "Not a directory"（已实测）
                    const bool bad = install_from_local_dmg(imgL, shaL, file_size(imgL),
                                                            base + "/rlplayer-update-mnt-i",
                                                            "/dev/null/RLPlayer.app", bk, er, wn);
                    ck(!bad, "【D】目标写不进去 ⟹ 安装失败（前提）", er);
                    ck(er.find("复制到目标失败") != std::string::npos,
                       "【D】失败原因确实是复制（不是校验/挂载）", er);
                    ck(file_contains(logPath, "UPDATE_INSTALL_FAIL stage=install err="),
                       "【D】install 失败已落盘（stage=install）", logPath);
                    ck(!is_mount_point(base + "/rlplayer-update-mnt-i"),
                       "【D】install 失败后挂载点照样被卸掉（不残留）");
                }
            }
        }


        // =====================================================================
        // 18. 【本次修复·E】旧写死挂载点的遗留残留：流水线开工时自愈
        //
        // 旧版本把挂载点写死成 <temp>/rlplayer-update-mnt，踩过这个 bug 的用户机器上
        // 可能**还挂着一份卸不掉的镜像**（本机现场：/dev/disk25s1 在
        // /private/var/folders/…/T/rlplayer-update-mnt 上挂了一天多）。
        // 发版后应当自愈，而不是等用户手工 detach。
        //
        // 判据：
        //   ① 旧路径仍是挂载点 ⟹ 清掉它，并写 UPDATE_STALE_MOUNT_CLEANED path=… ok=1
        //   ② 清不掉时（注入失败）⟹ **不阻断**：流水线照样 true，日志里 ok=0
        //   ③ 两种情形都要求新版本**真的装好**（不能为了清残留把安装搞坏）
        // =====================================================================
        {
            const std::string sBase = base + "/stale";
            run("mkdir -p '" + sBase + "/stage'");
            ck(make_fake_app(sBase + "/stage/RLPlayer.app", "PAYLOAD-STALE"), "【E】构造镜像载荷");
            std::string imgS, howS, shaS, eS;
            ck(make_image_fixture(sBase + "/stage", sBase + "/img", imgS, howS),
               "【E】造出可挂载镜像", howS);
            ck(sha256_of_file(imgS, shaS, eS), "【E】算镜像摘要", eS);
            const long long szS = file_size(imgS);

            const std::string staleMnt = rta::platform::join(rta::platform::temp_dir_utf8(),
                                                             "rlplayer-update-mnt");
            const std::string logPath = rta::platform::join(rta::platform::config_dir_utf8(),
                                                            "rlplayer-update.log");
            std::printf("  [info] 旧写死挂载点 = [%s]\n", staleMnt.c_str());

            const std::string srvS = sBase + "/srv.py";
            const std::string portS = sBase + "/port.txt";
            {
                FILE* f = std::fopen(srvS.c_str(), "wb");
                std::string py;
                py += "import http.server, socketserver\n";
                py += "DATA = open('" + imgS + "','rb').read()\n";
                py += "class H(http.server.BaseHTTPRequestHandler):\n";
                py += "    def do_GET(self):\n";
                py += "        self.send_response(200)\n";
                py += "        self.send_header('Content-Length', str(len(DATA)))\n";
                py += "        self.end_headers()\n";
                py += "        self.wfile.write(DATA); self.wfile.flush()\n";
                py += "    def log_message(self, *a): pass\n";
                py += "srv = socketserver.TCPServer(('127.0.0.1', 0), H)\n";
                py += "print(srv.server_address[1], flush=True); srv.serve_forever()\n";
                std::fwrite(py.data(), 1, py.size(), f);
                std::fclose(f);
            }
            std::system(("/usr/bin/python3 '" + srvS + "' > '" + portS + "' 2>&1 &").c_str());
            int portS8 = 0;
            for (int i = 0; i < 100 && portS8 <= 0; ++i) {
                ::usleep(100 * 1000);
                FILE* f = std::fopen(portS.c_str(), "r");
                if (!f) continue;
                char buf[32] = {0};
                if (std::fgets(buf, sizeof buf, f)) portS8 = std::atoi(buf);
                std::fclose(f);
            }
            ck(portS8 > 0, "【E】本地 dmg HTTP 服务就绪", "port=" + std::to_string(portS8));

            if (portS8 > 0) {
                CheckResult plan;
                plan.decision = Decision::UpdateAvailable;
                plan.remoteVersion = "9.9.9-stale";
                plan.downloadUrl = "http://127.0.0.1:" + std::to_string(portS8) + "/u.dmg";
                plan.sha256 = shaS;
                plan.size = szS;

                // ---------- 18a：旧路径被占着 ⟹ 自愈 + 流水线成功 ----------
                {
                    std::string srcApp, me;
                    const bool pre = mount_image(imgS, staleMnt, srcApp, me);
                    ck(pre, "【E】前提：把镜像挂到旧写死挂载点上（模拟用户的遗留残留）", me);
                    ck(is_mount_point(staleMnt), "【E】前提：旧路径确实已是挂载点", staleMnt);

                    InstallPipelineOptions opt;
                    opt.targetApp = base + "/stale-apps-a/RLPlayer.app";
                    run("mkdir -p '" + base + "/stale-apps-a'");
                    opt.dmgPath = sBase + "/a.dmg";
                    opt.autoRestart = false;

                    set_test_allow_loopback_download(true);
                    std::string perr, pback;
                    const bool okP = run_install_pipeline(plan, nil, CancelToken(), opt, perr, pback);
                    set_test_allow_loopback_download(false);
                    ck(okP, "【E】旧残留存在时流水线照样成功", perr);
                    ck(read_marker(opt.targetApp) == "PAYLOAD-STALE",
                       "【E】新版本确实装好了", read_marker(opt.targetApp));
                    ck(file_contains(logPath, "UPDATE_STALE_MOUNT_CLEANED path=" + staleMnt),
                       "【E】自愈动作已落盘（带路径）", logPath);
                    ck(file_contains(logPath, "UPDATE_STALE_MOUNT_CLEANED path=" + staleMnt + " ok=1"),
                       "【E】清理结果 ok=1（真的清掉了）", logPath);
                    ck(!is_mount_point(staleMnt), "【E】旧挂载点已清空", staleMnt);
                    const long long leftS = count_attached_images(imgS);
                    ck(leftS == 0, "【E】旧镜像不再有 attach 残留",
                       "count=" + std::to_string(leftS));
                }

                // ---------- 18b：清不掉时不阻断（注入强制失败）----------
                {
                    std::string srcApp, me;
                    const bool pre = mount_image(imgS, staleMnt, srcApp, me);
                    ck(pre, "【E】前提：再挂一份到旧路径（给「清不掉」分支用）", me);
                    ck(is_mount_point(staleMnt), "【E】前提（18b）：旧路径又挂上了", staleMnt);

                    InstallPipelineOptions opt;
                    opt.targetApp = base + "/stale-apps-b/RLPlayer.app";
                    run("mkdir -p '" + base + "/stale-apps-b'");
                    opt.dmgPath = sBase + "/b.dmg";
                    opt.autoRestart = false;

                    set_test_allow_loopback_download(true);
                    set_test_force_unmount_failure(true);
                    std::string perr, pback;
                    const bool okP = run_install_pipeline(plan, nil, CancelToken(), opt, perr, pback);
                    set_test_force_unmount_failure(false);
                    set_test_allow_loopback_download(false);

                    ck(okP, "【E】旧残留清不掉也**不阻断**更新（仍返回 true）", perr);
                    ck(read_marker(opt.targetApp) == "PAYLOAD-STALE",
                       "【E】「清不掉」分支里新版本照样装好", read_marker(opt.targetApp));
                    ck(file_contains(logPath, "UPDATE_STALE_MOUNT_CLEANED path=" + staleMnt + " ok=0"),
                       "【E】清不掉时日志如实写 ok=0", logPath);
                    ck(is_mount_point(staleMnt),
                       "【E】清不掉 ⟹ 旧路径确实还挂着（注入生效，不是被别的东西清了）", staleMnt);

                    // 收尾：注入关掉后把两份残留都清干净（本测试不制造新的 disk25）
                    std::string c1;
                    ck(unmount_image(staleMnt, c1), "【E】关掉注入后清掉旧路径残留", c1);
                    const std::string defMp = rta::platform::join(
                        rta::platform::temp_dir_utf8(),
                        "rlplayer-update-mnt-" + std::to_string((long long)::getpid()));
                    std::string c2;
                    ck(unmount_image(defMp, c2), "【E】关掉注入后清掉本轮默认挂载点残留", c2);
                    const long long left2 = count_attached_images(imgS);
                    ck(left2 == 0, "【E】收尾后没有任何 attach 残留",
                       "count=" + std::to_string(left2));
                }
            }
            std::system(("pkill -TERM -f '" + srvS + "' 2>/dev/null").c_str());
            ::usleep(150 * 1000);
        }

        // 清理
        run("rm -rf '" + base + "'");

        std::printf("\n=== 汇总：%d 通过 / %d 失败 ===\n", g_pass, g_fail);
        std::printf("%s\n", g_fail == 0 ? "全部通过" : "存在失败");
        return g_fail == 0 ? 0 : 1;
    }
}
