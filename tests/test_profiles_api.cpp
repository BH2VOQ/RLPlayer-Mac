// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_profiles_api.cpp — U16（上游 v3.3.11）：工作台命名配置档 /api/profiles 的黑盒判据
//
// ============================ 这个测试在证明什么 ============================
// 端点与配置档文件必须真的落在**设置层**上，而不是只回一句 ok:true：
//   ① POST /api/profiles?save=<name>   把当前听感键快照成命名档（白名单以外不存）；
//   ② GET  /api/profiles               读回同一份档列表（id/name/keys/createdAt/active），
//                                      且档列表在 state 目录里持久化（rlplayer-settings.conf 旁边）；
//   ③ POST /api/profiles?apply=<id>    把档内键合并写回 /api/settings：
//                                      GET /api/settings 必须逐键与档内一致；
//                                      不支持的键（cleanup 等）与危险键（backend/device/buffer/
//                                      upnpdev/gpuvendor）**跳过并如实报告**，绝不静默生效；
//   ④ POST /api/profiles?delete=<id>   删除后档消失；重复删除/应用未知档 → 404 + 稳定 code；
//   ⑤ GET 带 save/apply/delete 参数 → 405（<img src> 不能靠 GET 改用户的档）。
//
// 铁律 4：只断言 ok:true 会漏掉「回了 ok 但没改状态」的假实现 ⟹ 每条写操作都读回。
// 负向对照：旧实现 /api/profiles 根本不存在（返回 not found），本测试在改之前必然红。
//
// 环境纪律（铁律 1/2）：backend=null + volume=-120（绝不打开音频设备）、不监听端口
// （只调 rlapp::dispatch，进程内），全部落临时目录，不碰 8899。
#include "rlapp_core.h"
#include "net/webui.h"
#include "net/json.h"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <map>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;
using Json = rta::net::Json;

static int g_fail = 0;
static int g_pass = 0;

static void ck(bool cond, const std::string& what, const std::string& detail = std::string()) {
    if (cond) {
        ++g_pass;
        std::printf("  [PASS] %s\n", what.c_str());
    } else {
        ++g_fail;
        std::printf("  [FAIL] %s%s%s\n", what.c_str(),
                    detail.empty() ? "" : " — ", detail.c_str());
    }
}

static std::string call(const std::string& method, const std::string& path,
                        const std::string& body = std::string()) {
    rta::net::HttpRequest rq;
    rq.method = method;
    rq.path = path;
    rq.body = body;
    std::string ct;
    return rlapp::dispatch(rq, ct);
}

static int status() { return rta::net::webui_status_slot()->load(); }

// URL 组件编码：RFC 3986 unreserved 之外全部 %XX（中文名必须靠它进查询串）
static std::string pct(const std::string& s) {
    static const char* hex = "0123456789ABCDEF";
    std::string out;
    for (unsigned char c : s) {
        const bool safe = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                          (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~';
        if (safe) { out += (char)c; continue; }
        out += '%';
        out += hex[c >> 4];
        out += hex[c & 0x0F];
    }
    return out;
}

static void write_text(const fs::path& p, const std::string& text) {
    std::ofstream f(p, std::ios::binary | std::ios::trunc);
    f << text;
}

static Json parse(const std::string& text) { return rta::net::json_parse(text); }

static bool okp(const Json& j) { return j.has("ok") && j["ok"].type == Json::Bool && j["ok"].b; }

// 档内 keys → std::map（服务端字段是字符串对象）
static std::map<std::string, std::string> key_map(const Json& profile) {
    std::map<std::string, std::string> out;
    const Json& keys = profile["keys"];
    if (keys.type != Json::Obj) return out;
    for (const auto& kv : keys.obj)
        if (kv.second.type == Json::Str) out[kv.first] = kv.second.str;
    return out;
}

static const Json* find_profile(const Json& list, const std::string& id) {
    if (list.type != Json::Arr) return nullptr;
    for (const auto& p : list.arr)
        if (p["id"].type == Json::Str && p["id"].str == id) return &p;
    return nullptr;
}

static std::string keys_detail(const std::map<std::string, std::string>& keys) {
    std::string s;
    for (const auto& kv : keys) { if (!s.empty()) s += ','; s += kv.first; }
    return s.empty() ? std::string("(空)") : s;
}

// 白名单之外的危险键：切档绝不能携带它们（否则会切输出设备/抢独占/改缓冲）。
static const char* kDanger[] = {"backend", "device", "buffer", "upnpdev", "gpuvendor"};

int main() {
    std::printf("== /api/profiles 黑盒判据（保存 / 读回 / 应用 / 删除 / 安全排除）==\n");

    const fs::path tmp = fs::temp_directory_path() /
                         ("rlplayer_profiles_api_" + std::to_string(::getpid()));
    std::error_code ec;
    fs::remove_all(tmp, ec);
    fs::create_directories(tmp, ec);
    if (ec) { std::printf("!! 无法创建临时目录\n"); return 2; }

    // 隔离 + 绝不出声（铁律 1）：backend=null、volume=-120
    for (const char* leaf : {"home", "state", "covers", "lib"})
        fs::create_directories(tmp / leaf, ec);
    ::setenv("HOME", (tmp / "home").string().c_str(), 1);
    ::setenv("CFFIXED_USER_HOME", (tmp / "home").string().c_str(), 1);
    ::setenv("RLPLAYER_STATE_DIR", (tmp / "state").string().c_str(), 1);
    ::setenv("RLPLAYER_LIBRARY_DIR", (tmp / "lib").string().c_str(), 1);
    ::setenv("RLPLAYER_COVER_DIR", (tmp / "covers").string().c_str(), 1);

    const fs::path confPath = tmp / "state" / "rlplayer-settings.conf";
    write_text(confPath,
               "backend=null\nvolume=-120\nscanonstartup=0\nmetaon=0\nmetallm=0\n"
               "filter=poly-sinc-gauss-long\nfilterNx=poly-sinc-gauss-hires-lp\n"
               "rate=176400\nrateFamilyPolicy=strict\n"
               "dsd=0\nshaper=auto\nbits=24\ntaps=16384\nphase=linear\n"
               "modfamily=ec\nmodorder=7\nrgmode=track\natten=60\ntransition=0.04\n"
               "device=TestDAC\nbuffer=100\nupnpdev=uuid:test\ngpuvendor=auto\n"
               "channels=2\ntrim=0,0,0,0,0,0,0,0\n");

    // 外来档夹具：故意带危险键 + macOS 不支持的 cleanup 键 + 非法值。
    // 这不是"我们存出来的档"，而是从别处/手改来的文件 —— 应用时**必须逐键拒绝**。
    const fs::path profilePath = tmp / "state" / "rlplayer-workbench-profiles.json";
    write_text(profilePath,
        "{\"version\":1,\"nextId\":2,\"active\":\"x1\",\"profiles\":[{\"id\":\"x1\","
        "\"name\":\"外来档\",\"createdAt\":1000,\"eqId\":\"工作室 EQ\",\"keys\":{"
        "\"backend\":\"coreaudio\",\"device\":\"EvilDAC\",\"buffer\":\"50\","
        "\"upnpdev\":\"uuid:evil\",\"gpuvendor\":\"off\",\"cleanup_strength\":\"0.5\","
        "\"rateFamilyPolicy\":\"bogus\",\"filter\":\"poly-sinc-tight-lp\","
        "\"bits\":\"16\",\"dsd\":\"64\"}}]}\n");

    ck(rlapp::start_embedded(), "start_embedded() 返回 true");

    // ---- ① 外来档：读取（档列表必须来自持久化文件，而不是内存默认值）----
    std::printf("\n[读档] GET /api/profiles（state 目录里已有一份外来档）\n");
    Json list = Json{};
    {
        const std::string got = call("GET", "/api/profiles");
        ck(status() == 200, "GET /api/profiles → 200", "status=" + std::to_string(status()));
        list = parse(got);
        ck(okp(list), "GET 返回 ok:true（旧实现是 not found）", got.substr(0, 200));
        ck(list["profiles"].type == Json::Arr && list["profiles"].size() == 1,
           "读回 1 个持久化档", got.substr(0, 220));
        const Json* p = find_profile(list["profiles"], "x1");
        ck(p != nullptr, "外来档 id 读回", got.substr(0, 220));
        if (p) {
            ck(p->has("name") && (*p)["name"].s() == "外来档", "外来档 name 读回", (*p)["name"].s());
            ck(p->has("eqId") && (*p)["eqId"].s() == "工作室 EQ", "外来档 eqId 读回", (*p)["eqId"].s());
            ck(p->has("createdAt") && (*p)["createdAt"].n() == 1000, "外来档 createdAt 读回",
               std::to_string((*p)["createdAt"].n()));
            const auto keys = key_map(*p);
            ck(keys.count("filter") == 1, "外来档 keys 里有 filter", keys_detail(keys));
        }
    }

    // ---- ② 应用外来档：危险键 / 不支持键 / 非法值必须跳过并如实返回 ----
    std::printf("\n[安全应用] POST /api/profiles?apply=x1\n");
    {
        const std::string post = call("POST", "/api/profiles?apply=x1");
        const Json j = parse(post);
        ck(status() == 200, "apply 外来档 → 200", "status=" + std::to_string(status()));
        ck(okp(j), "apply 返回 ok:true", post.substr(0, 240));
        std::map<std::string, bool> skipped;
        for (const auto& s : j["skipped"].arr)
            if (s["key"].type == Json::Str) skipped[s["key"].str] = true;
        for (const char* k : kDanger)
            ck(skipped.count(k) == 1, std::string("apply 跳过危险键 ") + k, post.substr(0, 300));
        ck(skipped.count("cleanup_strength") == 1, "apply 跳过 macOS 不支持的键 cleanup_strength",
           post.substr(0, 300));
        ck(skipped.count("rateFamilyPolicy") == 1, "apply 跳过非法值 rateFamilyPolicy=bogus",
           post.substr(0, 300));
        std::map<std::string, bool> applied;
        for (const auto& a : j["applied"].arr)
            if (a.type == Json::Str) applied[a.str] = true;
        ck(applied.count("filter") == 1 && applied.count("bits") == 1 && applied.count("dsd") == 1,
           "apply 接受了 filter / bits / dsd", post.substr(0, 300));

        // 读回：被接受的键真的写进了设置层；危险键/不支持键一个都没生效。
        const std::string got = call("GET", "/api/settings");
        const Json kv = parse(got)["kv"];
        auto v = [&](const char* k) { return kv.has(k) ? kv[k].s() : std::string("<缺>"); };
        ck(v("filter") == "poly-sinc-tight-lp", "读回 filter 已应用", v("filter"));
        ck(v("bits") == "16", "读回 bits 已应用", v("bits"));
        ck(v("dsd") == "64", "读回 dsd 已应用", v("dsd"));
        // 负向对照：危险键必须保持原值（跳过 = 真的没写）。
        ck(v("backend") == "null", "危险键 backend 未被档改写", v("backend"));
        ck(v("device") == "TestDAC", "危险键 device 未被档改写", v("device"));
        ck(v("buffer") == "100", "危险键 buffer 未被档改写", v("buffer"));
        ck(v("upnpdev") == "uuid:test", "危险键 upnpdev 未被档改写", v("upnpdev"));
        ck(v("gpuvendor") == "auto", "危险键 gpuvendor 未被档改写", v("gpuvendor"));
        ck(!kv.has("cleanup_strength"), "不支持的键没有被写进 conf", got.substr(0, 200));
        ck(v("rateFamilyPolicy") == "strict", "非法值没有改掉已生效的族策略", v("rateFamilyPolicy"));
    }

    // ---- ③ 删除外来档 → 空态 ----
    std::printf("\n[删除] POST /api/profiles?delete=x1 与空态\n");
    {
        const std::string post = call("POST", "/api/profiles?delete=x1");
        const Json j = parse(post);
        ck(status() == 200 && okp(j), "删除外来档 → ok:true", post.substr(0, 200));
        const std::string got = call("GET", "/api/profiles");
        const Json list2 = parse(got);
        ck(okp(list2) && list2["profiles"].size() == 0, "删除后档列表为空", got.substr(0, 200));
        ck(list2["active"].type == Json::Str && list2["active"].str.empty(),
           "删除当前档后 active 清空", got.substr(0, 200));
        const std::string again = call("POST", "/api/profiles?delete=x1");
        ck(status() == 404, "重复删除 → 404", "status=" + std::to_string(status()));
        ck(again.find("\"code\":\"profiles.not_found\"") != std::string::npos,
           "重复删除 → 稳定 code profiles.not_found", again.substr(0, 200));
    }

    // ---- ④ 存 3 个档：每次先改设置，证明快照抓的是「当前」而不是第一次的值 ----
    std::printf("\n[保存] POST /api/profiles?save=<中文名>（3 档）\n");
    std::string id1, id2, id3;
    {
        call("POST", "/api/settings",
             "filter=poly-sinc-gauss-long&rate=176400&dsd=0&shaper=auto&bits=24"
             "&loudness=1&phase=linear&rateFamilyPolicy=strict&modfamily=ec&modorder=7");
        const std::string s1 = call("POST", "/api/profiles?save=" + pct("夜听"));
        const Json j1 = parse(s1);
        ck(status() == 200 && okp(j1), "保存「夜听」→ ok:true", s1.substr(0, 200));
        id1 = j1["saved"].s();
        ck(!id1.empty(), "保存返回新档 id", s1.substr(0, 200));

        call("POST", "/api/settings",
             "filter=poly-sinc-tight-lp&rate=follow&dsd=128&shaper=NS5&loudness=0"
             "&rateFamilyPolicy=prefer&modfamily=ec&modorder=7");
        const std::string s2 = call("POST", "/api/profiles?save=" + pct("对比"));
        const Json j2 = parse(s2);
        ck(status() == 200 && okp(j2), "保存「对比」→ ok:true", s2.substr(0, 200));
        id2 = j2["saved"].s();
        ck(!id2.empty() && id2 != id1, "第二次保存得到不同的 id", id2);

        call("POST", "/api/settings",
             "filter=sinc-L&rate=96000&dsd=0&shaper=TPDF&bits=16&phase=minimum&loudness=1");
        const std::string s3 = call("POST", "/api/profiles?save=" + pct("直通"));
        const Json j3 = parse(s3);
        ck(status() == 200 && okp(j3), "保存「直通」→ ok:true", s3.substr(0, 200));
        id3 = j3["saved"].s();
        ck(!id3.empty() && id3 != id1 && id3 != id2, "第三次保存得到不同的 id", id3);

        const std::string bad = call("POST", "/api/profiles?save=");
        ck(status() == 400 && !okp(parse(bad)),
           "空名字 save → 400（档名不能为空）", "status=" + std::to_string(status()));
        ck(bad.find("\"code\":\"profiles.bad_name\"") != std::string::npos,
           "空名字 → 稳定 code profiles.bad_name", bad.substr(0, 200));
    }

    // ---- ⑤ 读回 3 档：内容、active、白名单（负向对照）----
    std::printf("\n[读回] GET /api/profiles（3 档）\n");
    Json list3 = Json{};
    {
        const std::string got = call("GET", "/api/profiles");
        list3 = parse(got);
        ck(status() == 200 && okp(list3), "GET 3 档 → ok:true", got.substr(0, 200));
        ck(list3["profiles"].size() == 3, "读回 3 个档",
           std::to_string(list3["profiles"].size()));
        ck(list3["active"].type == Json::Str && list3["active"].str == id3,
           "active = 最后保存的档", list3["active"].str);

        const Json* p1 = find_profile(list3["profiles"], id1);
        const Json* p2 = find_profile(list3["profiles"], id2);
        const Json* p3 = find_profile(list3["profiles"], id3);
        ck(p1 && p2 && p3, "三个 id 都能读回", keys_detail({}));
        if (p1 && p2 && p3) {
            ck((*p1)["name"].s() == "夜听" && (*p2)["name"].s() == "对比" &&
               (*p3)["name"].s() == "直通", "档名逐字读回", (*p1)["name"].s());
            for (const Json* p : {p1, p2, p3})
                ck(p->has("createdAt") && (*p)["createdAt"].n() > 0, "createdAt 是正整数时间戳",
                   std::to_string((*p)["createdAt"].n()));
            const auto k1 = key_map(*p1), k2 = key_map(*p2), k3 = key_map(*p3);
            ck(k1.size() >= 30, "档 1 存了完整白名单快照（>=30 键）",
               std::to_string(k1.size()) + " keys: " + keys_detail(k1));
            ck(k1.at("filter") == "poly-sinc-gauss-long", "档 1 filter 是保存时的值", k1.at("filter"));
            ck(k1.at("rate") == "176400", "档 1 rate 是保存时的值", k1.at("rate"));
            ck(k2.at("filter") == "poly-sinc-tight-lp", "档 2 filter 是第二次的值", k2.at("filter"));
            ck(k2.at("dsd") == "128", "档 2 dsd=128", k2.at("dsd"));
            ck(k3.at("filter") == "sinc-L" && k3.at("bits") == "16",
               "档 3 filter/bits 是第三次的值", k3.at("filter") + "/" + k3.at("bits"));
            // 负向对照：白名单之外（尤其输出独占相关）的键绝不能进档。
            int leaked = 0;
            std::string leakDetail;
            for (const Json* p : {p1, p2, p3}) {
                const auto ks = key_map(*p);
                for (const char* k : kDanger)
                    if (ks.count(k)) { ++leaked; leakDetail += (*p)["id"].s() + ":" + k + " "; }
                if (ks.count("hogexcl") || ks.count("volume")) { ++leaked; leakDetail += "hogexcl/volume "; }
            }
            ck(leaked == 0, "档里不含 backend/device/buffer/upnpdev/gpuvendor（也不含 hogexcl/volume）",
               leakDetail);
        }
    }

    // ---- ⑥ 持久化：档列表必须真的落在 conf 目录旁 ----
    std::printf("\n[持久化] 档文件在 state 目录里\n");
    {
        ck(fs::is_regular_file(profilePath), "档文件存在（rlplayer-settings.conf 同目录）",
           profilePath.string());
        std::ifstream in(profilePath);
        std::string bytes, line;
        while (std::getline(in, line)) bytes += line + "\n";
        const Json j = parse(bytes);
        ck(j["version"].n() == 1 && j["profiles"].size() == 3,
           "档文件是可解析的 v1 JSON 且含 3 档", bytes.substr(0, 160));
        ck(j["active"].s() == id3, "档文件里 active 已落盘", j["active"].s());
    }

    // ---- ⑦ 应用档 1：设置层逐键与档内一致（铁律 4 的核心断言）----
    std::printf("\n[应用] POST /api/profiles?apply=<档1> → GET /api/settings 逐键一致\n");
    {
        const Json* p1 = find_profile(list3["profiles"], id1);
        if (!p1) {
            ck(false, "档 1 读回（apply 的前置条件）", "没有档 1，无法应用");
        } else {
        const auto want = key_map(*p1);
        const std::string post = call("POST", "/api/profiles?apply=" + id1);
        const Json j = parse(post);
        ck(status() == 200 && okp(j), "apply 档 1 → ok:true", post.substr(0, 220));
        ck(j["skipped"].size() == 0, "应用自有档没有跳过项", post.substr(0, 240));
        ck(!j["applied"].arr.empty(), "applied 非空（不是空操作）", post.substr(0, 240));
        ck(j["active"].s() == id1, "apply 后 active = 该档", j["active"].s());

        const std::string got = call("GET", "/api/settings");
        const Json kv = parse(got)["kv"];
        int mismatch = 0;
        std::string detail;
        for (const auto& kvIt : want) {
            if (!kv.has(kvIt.first) || kv[kvIt.first].s() != kvIt.second) {
                ++mismatch;
                if (detail.size() < 200)
                    detail += kvIt.first + "=" + (kv.has(kvIt.first) ? kv[kvIt.first].s() : std::string("<缺>")) +
                              " want " + kvIt.second + "; ";
            }
        }
        ck(mismatch == 0, "设置读回与档内逐键一致（" + std::to_string(want.size()) + " 键）", detail);
        }
    }

    // ---- ⑧ GET 带副作用参数必须被拦住 ----
    std::printf("\n[安全] GET /api/profiles?save=evil\n");
    {
        const std::string got = call("GET", "/api/profiles?save=evil");
        ck(status() == 405, "GET 带 save= → 405", "status=" + std::to_string(status()));
        const Json list2 = parse(call("GET", "/api/profiles"));
        ck(list2["profiles"].size() == 3, "被拦下的 GET 没有新增档", got.substr(0, 160));
    }

    // ---- ⑨ 应用档 2：真读回该档的差异值 ----
    std::printf("\n[应用] POST /api/profiles?apply=<档2>\n");
    {
        const std::string post = call("POST", "/api/profiles?apply=" + id2);
        const Json j = parse(post);
        ck(status() == 200 && okp(j) && j["active"].s() == id2, "apply 档 2 → ok:true 且 active 更新",
           post.substr(0, 200));
        const Json kv = parse(call("GET", "/api/settings"))["kv"];
        ck(kv["filter"].s() == "poly-sinc-tight-lp", "读回档 2 filter", kv["filter"].s());
        ck(kv["rate"].s() == "follow", "读回档 2 rate=follow", kv["rate"].s());
        ck(kv["dsd"].s() == "128", "读回档 2 dsd=128", kv["dsd"].s());
        ck(kv["shaper"].s() == "NS5", "读回档 2 shaper=NS5", kv["shaper"].s());
    }

    // ---- ⑩ 删除档 2：消失 / active 清空 / 未知档 404 ----
    std::printf("\n[删除] POST /api/profiles?delete=<档2>\n");
    {
        const std::string post = call("POST", "/api/profiles?delete=" + id2);
        const Json j = parse(post);
        ck(status() == 200 && okp(j) && j["deleted"].s() == id2, "删除档 2 → ok:true", post.substr(0, 200));
        const Json list2 = parse(call("GET", "/api/profiles"));
        ck(list2["profiles"].size() == 2, "删除后剩 2 档", std::to_string(list2["profiles"].size()));
        ck(find_profile(list2["profiles"], id2) == nullptr, "档 2 确实消失", id2);
        ck(list2["active"].type == Json::Str && list2["active"].str.empty(),
           "删除当前档后 active 清空", list2["active"].str);

        const std::string ap = call("POST", "/api/profiles?apply=" + id2);
        ck(status() == 404, "apply 已删除的档 → 404", "status=" + std::to_string(status()));
        ck(ap.find("\"code\":\"profiles.not_found\"") != std::string::npos,
           "apply 未知档 → 稳定 code", ap.substr(0, 200));

        const std::string del = call("POST", "/api/profiles?delete=" + id2);
        ck(status() == 404 && del.find("\"code\":\"profiles.not_found\"") != std::string::npos,
           "重复删除档 2 → 404 + 稳定 code", del.substr(0, 200));
    }

    // ---- ⑪ 删除后仍可应用剩余档（状态可重建）----
    std::printf("\n[重建] 删除后再应用剩余档\n");
    {
        const std::string post = call("POST", "/api/profiles?apply=" + id1);
        ck(status() == 200 && okp(parse(post)), "删除别的档后仍可应用档 1", post.substr(0, 200));
        const Json list2 = parse(call("GET", "/api/profiles"));
        ck(list2["profiles"].size() == 2, "剩余 2 档稳定", std::to_string(list2["profiles"].size()));
    }

    rlapp::stop_embedded();

    std::printf("\n结果：%d passed, %d failed\n", g_pass, g_fail);
    if (g_fail) { std::printf("!! 有失败项\n"); return 1; }
    std::printf("/api/profiles 黑盒判据全部通过\n");
    return 0;
}
