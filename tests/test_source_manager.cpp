// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// SourceManager 用户可浏览回归：真 WebUi loopback HTTP，绝不访问真实用户配置。
// 所有配置均在自有 mkdtemp 目录；load 是只读恢复，不应覆盖占位项或原文。
// 判据不止 active_id：必须真的请求选中服务器并解析出该服务器的目录/曲目。
// 当前未修复实现预期红点：空 active 项 load、新增 valid 后自动启用、更新后回退、
// invalid 显式启用拒绝，以及无有效配置时不能把 URL malformed 当用户错误。
// 本测试不启动应用/音频，不下载缓存，不需要 pwsh、FFmpeg 或外部服务器。
// 注意：公开 GET /api/src/config 的密码脱敏属于产品路由 smoke，不在此复制路由假测；
// 此处验证 Subsonic 真请求只带 token 而非明文密码、错误不泄密、ping 不改配置。
#include "net/source_mgr.h"
#include "net/webui.h"
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <map>
#include <mutex>
#include <stdexcept>
#include <string>
#include <unistd.h>
#include <vector>

using rta::net::SourceConfig;
using rta::net::SourceManager;
namespace {
int checks = 0, failures = 0;
const std::string password = "source-test-private-password-7391";

void ck(bool ok, const std::string& name) {
    ++checks;
    if (!ok) ++failures;
    // 不打印配置正文、请求 URL、认证信息或密码，即使失败也不回显。
    std::printf("  [%s] %s\n", ok ? "PASS" : "FAIL", name.c_str());
}

std::string read_fixture(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("cannot read owned fixture");
    return std::string(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
}

class TempConfigs {
public:
    TempConfigs() {
        char pattern[] = "/tmp/rlplayer-source-manager-XXXXXX";
        char* p = ::mkdtemp(pattern);
        if (!p) throw std::runtime_error("mkdtemp failed");
        root_ = p;
    }
    ~TempConfigs() {
        // 单例不再持有将被删除的配置；load 不存在的自有路径不会创建/覆盖文件。
        SourceManager::instance().load(path("detached.conf"));
        std::error_code ec;
        std::filesystem::remove_all(root_, ec);
        ck(!ec && !std::filesystem::exists(root_, ec), "删除本测试自有临时目录");
    }
    std::string path(const std::string& name) const { return root_ + "/" + name; }
    std::string put(const std::string& name, const std::string& text) const {
        const std::string p = path(name);
        std::ofstream f(p, std::ios::binary);
        f << text;
        f.close();
        if (!f) throw std::runtime_error("cannot write owned fixture");
        return p;
    }
private:
    std::string root_;
};

class ScopedEnv {
public:
    ScopedEnv(const char* key, const char* value) : key_(key) {
        if (const char* old = ::getenv(key)) { existed_ = true; previous_ = old; }
        if (::setenv(key, value, 1) != 0) throw std::runtime_error("setenv failed");
    }
    ~ScopedEnv() {
        if (existed_) ::setenv(key_.c_str(), previous_.c_str(), 1);
        else ::unsetenv(key_.c_str());
    }
private:
    std::string key_, previous_;
    bool existed_ = false;
};

class LocalSubsonic {
public:
    ~LocalSubsonic() { ui_.stop(); } // 异常路径也先 join，再析构 handler 使用的 mutex/计数表。
    bool start() {
        return ui_.start(0, [this](const rta::net::HttpRequest& req, std::string& ct) {
            ct = "application/json; charset=utf-8";
            const size_t q = req.path.find('?');
            const std::string route = req.path.substr(0, q);
            std::map<std::string, std::string> args;
            if (q != std::string::npos) {
                size_t p = q + 1;
                while (p <= req.path.size()) {
                    const size_t end = req.path.find('&', p);
                    const std::string pair = req.path.substr(p, end - p);
                    const size_t eq = pair.find('=');
                    if (eq != std::string::npos) args[pair.substr(0, eq)] = pair.substr(eq + 1);
                    if (end == std::string::npos) break;
                    p = end + 1;
                }
            }
            const bool first = route.rfind("/one/", 0) == 0;
            const bool second = route.rfind("/two/", 0) == 0;
            const std::string tag = first ? "one" : "two";
            const bool auth = (first || second) && req.method == "GET" &&
                args["u"] == "fixture-user" && !args["s"].empty() &&
                args["t"] == rta::net::md5_hex(password + args["s"]) &&
                args["f"] == "json";
            {
                std::lock_guard<std::mutex> lock(mutex_);
                ++requests_;
                ++routes_[route];
                all_authenticated_ = all_authenticated_ && auth;
                no_password_ = no_password_ && req.path.find(password) == std::string::npos &&
                    req.body.find(password) == std::string::npos && !args.count("p") && !args.count("pass");
            }
            if (!auth) return std::string("{\"subsonic-response\":{\"status\":\"failed\",\"error\":{\"message\":\"fixture authentication rejected\"}}}");
            const std::string prefix = "/" + tag + "/rest/";
            if (route == prefix + "ping.view")
                return std::string("{\"subsonic-response\":{\"status\":\"ok\"}}");
            if (route == prefix + "getIndexes.view")
                return std::string("{\"subsonic-response\":{\"status\":\"ok\",\"indexes\":{\"index\":[{\"artist\":[{\"id\":\"") + tag + "-artist\",\"name\":\"Fixture artist\"}]}]}}}";
            // 原始文件下载：返回可识别字节 + audio/flac（缓存命名用例要用真实下载路径）
            if (route == prefix + "download.view") {
                ct = "audio/flac";
                return std::string("ORIGINAL-BYTES-") + tag + "-" + args["id"];
            }
            if (route == prefix + "getMusicDirectory.view" && args["id"] == tag + "-artist")
                return std::string("{\"subsonic-response\":{\"status\":\"ok\",\"directory\":{\"child\":[{\"id\":\"") + tag + "-track\",\"title\":\"Fixture track\",\"suffix\":\"flac\",\"isDir\":false}]}}}";
            return std::string("{\"subsonic-response\":{\"status\":\"failed\",\"error\":{\"message\":\"unexpected fixture endpoint\"}}}");
        }, true);
    }
    std::string base(const std::string& tag) const {
        return "http://127.0.0.1:" + std::to_string(ui_.port()) + "/" + tag;
    }
    unsigned count(const std::string& route = "") const {
        std::lock_guard<std::mutex> lock(mutex_);
        if (route.empty()) return requests_;
        const auto it = routes_.find(route);
        return it == routes_.end() ? 0 : it->second;
    }
    void verify_credentials() const {
        std::lock_guard<std::mutex> lock(mutex_);
        ck(requests_ > 0 && all_authenticated_, "真实请求均通过 fixture 用户与 MD5 token 校验");
        ck(no_password_, "真实 Subsonic 请求没有明文密码或 p/pass 参数");
    }
    void stop() { ui_.stop(); }
private:
    rta::net::WebUi ui_;
    mutable std::mutex mutex_;
    std::map<std::string, unsigned> routes_;
    unsigned requests_ = 0;
    bool all_authenticated_ = true, no_password_ = true;
};

SourceConfig server(const LocalSubsonic& http, const std::string& tag) {
    SourceConfig c;
    c.name = "Fixture " + tag;
    c.base = http.base(tag);
    c.user = "fixture-user";
    c.pass = password;
    return c;
}

std::string row(const std::string& id, const SourceConfig& c) {
    const std::string k = "srv" + id + ".";
    return k + "name=" + c.name + "\n" + k + "kind=" + c.kind + "\n" +
        k + "base=" + c.base + "\n" + k + "user=" + c.user + "\n" +
        k + "pass=" + c.pass + "\n";
}
std::string v2(const std::string& active, const std::string& rows) {
    return "# owned synthetic fixture; preserve exact bytes on load\nversion=2\nnextid=4\nactive=" + active + "\n" + rows;
}

bool unconfigured_error(const std::string& err) {
    return !err.empty() && err.find(password) == std::string::npos &&
        (err.find("配置") != std::string::npos || err.find("填写") != std::string::npos ||
         err.find("启用") != std::string::npos) &&
        err.find("malformed") == std::string::npos && err.find("URL") == std::string::npos;
}

void expect_browsable(SourceManager& mgr, const LocalSubsonic& http,
                      const std::string& tag, const std::string& label) {
    std::string err;
    const unsigned ix = http.count("/" + tag + "/rest/getIndexes.view");
    const auto artists = mgr.indexes(err);
    ck(err.empty() && artists.size() == 1 && artists[0].id == tag + "-artist" &&
       artists[0].isDir, label + "：真实 indexes 可见预期艺术家");
    ck(http.count("/" + tag + "/rest/getIndexes.view") == ix + 1,
       label + "：indexes 确实抵达所选服务器");
    err.clear();
    const unsigned dirs = http.count("/" + tag + "/rest/getMusicDirectory.view");
    const auto tracks = mgr.browse(tag + "-artist", err);
    ck(err.empty() && tracks.size() == 1 && tracks[0].id == tag + "-track" &&
       !tracks[0].isDir && tracks[0].suffix == "flac", label + "：真实 browse 可见曲目");
    ck(http.count("/" + tag + "/rest/getMusicDirectory.view") == dirs + 1,
       label + "：browse 确实抵达所选服务器");
}

void run_cases(TempConfigs& tmp, LocalSubsonic& http) {
    auto& mgr = SourceManager::instance();
    const auto one = server(http, "one"), two = server(http, "two");
    const SourceConfig blank;
    const std::string three = row("1", blank) + row("2", one) + row("3", two);

    std::puts("-- load active 指向空占位时，第一台 valid 必须真的能浏览 --");
    const std::string original = v2("1", three);
    const std::string originalPath = tmp.put("invalid-active.conf", original);
    mgr.load(originalPath);
    ck(mgr.active_id() == "2" && mgr.config().valid(), "load 回退到第一台有效服务器 2");
    ck(mgr.servers().size() == 3, "load 保留所有条目，不删除用户空占位配置");
    ck(read_fixture(originalPath) == original, "load 修复内存 active 但不覆盖原配置字节");
    expect_browsable(mgr, http, "one", "load 回退");
    ck(read_fixture(originalPath) == original, "浏览不隐式写回原配置");

    std::puts("-- 只有空项/缺用户名：清楚报未配置，不发 HTTP --");
    for (int partial = 0; partial != 2; ++partial) {
        SourceConfig incomplete;
        if (partial) incomplete.base = http.base("one");
        const auto text = v2("1", row("1", incomplete));
        const auto p = tmp.put(partial ? "missing-user.conf" : "only-empty.conf", text);
        mgr.load(p);
        ck(mgr.active_id().empty() && !mgr.config().valid(), "无 valid 时 active 清空");
        unsigned before = http.count();
        std::string err;
        ck(mgr.indexes(err).empty() && unconfigured_error(err), "indexes 给出未配置提示，而非 URL malformed");
        ck(http.count() == before, "indexes 无有效配置时没有真实 HTTP 请求");
        err.clear();
        ck(mgr.browse("one-artist", err).empty() && unconfigured_error(err), "browse 无有效配置也明确拒绝");
        ck(http.count() == before, "browse 无有效配置时没有真实 HTTP 请求");
        err.clear();
        ck(!mgr.ping_server("1", err) && unconfigured_error(err), "ping 已存 invalid 服务器给出配置提示");
        ck(http.count() == before, "ping invalid 不发 HTTP");
        ck(read_fixture(p) == text, "未配置浏览与 ping 不改写配置");
    }

    std::puts("-- 空配置启动，以及先有空占位再添加 --");
    const std::string missing = tmp.path("new-install.conf");
    mgr.load(missing);
    ck(mgr.servers().empty() && mgr.active_id().empty(), "不存在的自有配置按空配置启动");
    const std::string first = mgr.add_server(one);
    ck(!first.empty() && mgr.active_id() == first, "空配置 add valid 自动启用");
    expect_browsable(mgr, http, "one", "空配置 add");
    mgr.load(tmp.put("placeholder-add.conf", v2("1", row("1", blank))));
    const std::string added = mgr.add_server(one);
    ck(!added.empty() && mgr.active_id() == added, "已有空占位 add valid 自动启用新服务器");
    expect_browsable(mgr, http, "one", "占位后 add");

    std::puts("-- 不抢占已有 valid active；显式启用 invalid 必须拒绝 --");
    mgr.load(tmp.put("keep-active.conf", v2("3", three)));
    ck(mgr.active_id() == "3", "load 保持已有有效 active，而不是改选第一台");
    const std::string extra = mgr.add_server(one);
    ck(!extra.empty() && mgr.active_id() == "3", "新增 valid 不抢占现有有效 active");
    ck(!mgr.set_active("1") && mgr.active_id() == "3", "显式启用空占位返回 false 且不改变有效 active");
    expect_browsable(mgr, http, "two", "保持 active");
    ck(!mgr.set_active("missing-id") && mgr.active_id() == "3", "显式启用不存在 ID 不改变有效 active");

    std::puts("-- update 当前服务器失效后回退，不只改 active 字符串 --");
    mgr.load(tmp.put("update-active.conf", v2("2", three)));
    ck(mgr.update_server("2", blank, true), "update active 为 invalid 操作成功");
    ck(mgr.active_id() == "3" && mgr.config().valid(), "update 后跳过空占位回退至 valid 3");
    expect_browsable(mgr, http, "two", "update 后回退");
    mgr.load(tmp.put("update-preserve.conf", v2("2", three)));
    SourceConfig edit = one;
    edit.name = "Edited fixture";
    edit.pass.clear();
    ck(mgr.update_server("2", edit, true), "编辑服务器时允许密码留空保留原值");
    ck(mgr.active_id() == "2" && mgr.config().pass == password, "update keepPass 保留有效 active 与密码");
    expect_browsable(mgr, http, "one", "update keepPass");

    std::puts("-- 兼容 set_config 失效回退；remove active 回退 --");
    mgr.load(tmp.put("legacy-set.conf", v2("2", three)));
    mgr.set_config(blank);
    ck(mgr.active_id() == "3", "兼容 set_config 更新为 invalid 也回退");
    expect_browsable(mgr, http, "two", "set_config 后回退");
    mgr.load(tmp.put("remove-active.conf", v2("2", three)));
    ck(mgr.remove_server("2") && mgr.active_id() == "3", "remove active 跳过空占位选择 valid 3");
    expect_browsable(mgr, http, "two", "remove 后回退");
    ck(mgr.remove_server("3") && mgr.active_id().empty(), "删除最后一台 valid 后 active 清空");
    std::string err;
    const unsigned before = http.count();
    ck(mgr.indexes(err).empty() && unconfigured_error(err), "仅剩空占位时 indexes 清楚报未配置");
    ck(http.count() == before, "删除最后 valid 后无 HTTP 请求");

    std::puts("-- legacy valid 只读迁移，后续保存 v2，valid active 保存重载 --");
    const std::string legacy = "# synthetic legacy\nkind=subsonic\nbase=" + one.base +
        "\nuser=" + one.user + "\npass=" + password + "\n";
    const auto legacyPath = tmp.put("legacy.conf", legacy);
    mgr.load(legacyPath);
    ck(mgr.active_id() == "1" && mgr.servers().size() == 1, "legacy valid 迁移成 active 1");
    ck(read_fixture(legacyPath) == legacy, "legacy load 不覆盖原文、不提前落盘迁移");
    expect_browsable(mgr, http, "one", "legacy 迁移");
    const std::string second = mgr.add_server(two);
    ck(mgr.set_active(second), "可以显式启用第二台 valid");
    const std::string saved = read_fixture(legacyPath);
    ck(saved.find("version=2\n") != std::string::npos, "后续保存自然升级 v2");
    mgr.load(legacyPath);
    ck(mgr.active_id() == second && mgr.servers().size() == 2 && mgr.config().pass == password,
       "v2 重载保留显式选中的 valid active 与密码");
    ck(read_fixture(legacyPath) == saved, "v2 重载仍只读");
    expect_browsable(mgr, http, "two", "valid active 保存重载");

    std::puts("-- 远程曲目缓存名必须是人可读曲名（用户「名字是乱码」）：去重仍按 id --");
    {
        // 缓存目录 = <HOME>/Library/Application Support/RLPlayer/remote-cache：
        // 必须把 HOME 也隔离掉，否则这条用例会往用户真实缓存目录里写测试文件。
        const std::string fakeHome = tmp.path("home");
        std::filesystem::create_directories(fakeHome);
        ScopedEnv homeIso("HOME", fakeHome.c_str());
        mgr.load(tmp.put("fetch-name.conf", v2("2", three)));
        std::string ferr;
        const std::string p1 = mgr.fetch("srv-song-id-Abc123", "flac", "夜的第七章", ferr);
        ck(!p1.empty() && ferr.empty(), "fetch 带曲名下载成功");
        ck(p1.rfind(fakeHome, 0) == 0, "缓存落在隔离 HOME 下（不污染用户真实缓存目录）");
        ck(p1.find("夜的第七章") != std::string::npos, "缓存文件名用曲名（而不是远端 id）");
        ck(p1.find("srv-song-id-Abc123") == std::string::npos, "文件名不再包含远端 id");
        ck(p1.size() > 4 && p1.compare(p1.size() - 5, 5, ".flac") == 0, "扩展名保留 .flac");
        // 同一 id 再取 = 命中缓存，不重复下载
        const unsigned before = http.count("/one/rest/download.view");
        const std::string p2 = mgr.fetch("srv-song-id-Abc123", "flac", "夜的第七章", ferr);
        ck(p2 == p1, "同一 id 命中缓存返回同一路径");
        ck(http.count("/one/rest/download.view") == before, "命中缓存不再发下载请求");
        // 不同 id 但同名 ⟹ 不能互相覆盖
        const std::string p3 = mgr.fetch("srv-song-id-Zzz999", "flac", "夜的第七章", ferr);
        ck(!p3.empty() && p3 != p1, "不同 id 同名曲目不覆盖彼此缓存");
        // 空曲名/脏字符兜底
        const std::string p4 = mgr.fetch("srv-song-id-Def456", "aiff", "", ferr);
        ck(!p4.empty() && p4.find("srv-song-id-Def456") != std::string::npos,
           "空曲名回退成 id（不会产生空文件名或 .aiff 这种隐藏文件）");
        const std::string p5 = mgr.fetch("srv-song-id-Ghi789", "flac", "a/b:c*d?", ferr);
        {
            const std::string fname = std::filesystem::path(p5).filename().string();
            const std::string parent = std::filesystem::path(p5).parent_path().filename().string();
            ck(fname.find('/') == std::string::npos && fname.find('*') == std::string::npos &&
               fname.find('?') == std::string::npos && fname.find(':') == std::string::npos,
               "文件名里的分隔符/通配符被替换");
            ck(parent == "remote-cache", "文件仍在 remote-cache 目录内（没有逃出缓存目录）");
        }
        // 恢复后续用例期望的状态（本节换过 active，不能把状态泄漏给下一节）
        mgr.load(legacyPath);
        ck(mgr.active_id() == second, "缓存命名用例结束后恢复原 active（不泄漏状态给下一节）");
    }

    std::puts("-- 测试已存未启用服务器、未保存表单，不改变当前或磁盘 --");
    const auto activeBefore = mgr.active_id();
    const auto sizeBefore = mgr.servers().size();
    const auto diskBefore = read_fixture(legacyPath);
    const auto pingBefore = http.count("/one/rest/ping.view");
    err.clear();
    ck(mgr.ping_server("1", err) && err.empty(), "ping 已保存但非 active 的服务器成功");
    err.clear();
    ck(mgr.ping_config(one, err) && err.empty(), "未保存表单 ping 成功");
    ck(http.count("/one/rest/ping.view") == pingBefore + 2, "两次 ping 真正抵达非 active 服务器");
    ck(mgr.active_id() == activeBefore && mgr.servers().size() == sizeBefore,
       "ping 不切换 active、不新增未保存表单");
    ck(read_fixture(legacyPath) == diskBefore, "ping 不写盘、不覆盖已有配置");
    const auto invalidBefore = http.count();
    err.clear();
    ck(!mgr.ping_config(blank, err) && unconfigured_error(err), "未保存空表单 ping 明确提示配置");
    err.clear();
    ck(!mgr.ping_server("absent", err) && !err.empty() && err.find(password) == std::string::npos,
       "ping 不存在 ID 明确失败且错误不回显密码");
    ck(http.count() == invalidBefore, "空表单/不存在 ID 的 ping 均不发请求");
    ck(mgr.active_id() == activeBefore && read_fixture(legacyPath) == diskBefore,
       "失败 ping 同样不改变 active 与配置文件");
    expect_browsable(mgr, http, "two", "ping 后仍浏览原 active");
    ck(read_fixture(originalPath) == original, "所有用例结束后原始合成故障配置仍逐字不变");
}
} // namespace

int main() {
    std::puts("=== SourceManager: isolated real loopback browsing regression ===");
    try {
        // 显式本机代理值阻止读取/使用系统代理；no_proxy=* 强制这些 literal-loopback
        // URL 直连。即使宿主系统代理异常，本测试也不会把认证信息送向外部代理。
        ScopedEnv noProxy("no_proxy", "*"), noProxyUpper("NO_PROXY", "*");
        const std::string previousProxy = rta::net::http_proxy();
        struct RestoreProxy {
            std::string previous;
            ~RestoreProxy() { rta::net::set_http_proxy(previous); }
        } restore{previousProxy};
        LocalSubsonic http;
        if (!http.start()) throw std::runtime_error("cannot start loopback WebUi on port 0");
        rta::net::set_http_proxy(http.base("one"));
        {
            TempConfigs tmp;
            run_cases(tmp, http);
            http.verify_credentials();
        }
        http.stop();
    } catch (const std::exception& e) {
        // 异常只有本测试固定文字，不包含配置或请求细节。
        std::fprintf(stderr, "fixture setup failed: %s\n", e.what());
        ++failures;
    }
    std::printf("SourceManager: %d assertions, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
