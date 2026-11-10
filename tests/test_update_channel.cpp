// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_update_channel.cpp — 1.1.5.1「更新通道（中国大陆 / 全球）」框架的**离线**门禁
//                           （不联网、不开窗口、不碰音频设备、不发任何请求）
//
// 判据设计原则（铁律 3：测试"通过"≠测对了东西）：
//   ① 默认值必须**逐字**断言 Global，并在注释里写清「后台适配后改为 ChinaMainland」的切换点 ——
//      否则将来某人把默认值改成大陆时，这组测试会静默跟着变绿（测不出行为变化）。
//   ② 通道解析用**真值表**，且必须含**对抗用例**：URL 冒充通道值（"https://rlplayer.rainlain.com"）、
//      形近域名（"cn.evil.com"）必须判非法 —— 证明「通道值不是任意字符串通道」，
//      否则这个函数等于「填什么就选什么」，把它当安全边界用的人会被骗。
//   ③ 白名单不只测「放行后台域名」，还测**原有两条规则没被放宽**（evil.com / 形近域名仍拒）——
//      加第三个主机最常见的失误就是把 while/前缀匹配写松。
//   ④ 大陆通道「不可用」必须与「已是最新」**互斥**：逐条断言 up_to_date/available/ok 全 false，
//      并把文案的「不含 URL」「不引导网盘」也断言掉（用户 2026-11-09 定的语义）。
//   ⑤ 两套通道的版本比较必须**行为一致**：同一份清单只换 download_url 域名，
//      decision / remoteVersion / sha256 必须完全相同 —— 证明大陆通道不是另立一套判定。
//   ⑥ ChannelManifest::ready() 是「验签/重组未完成就不得进入安装链路」的类型级闸门，
//      用**顺序闸门**逐级断言（缺一环都不许 true）。
#include "net/update_channel.h"
#include "net/update_check.h"

#include <cstdio>
#include <string>
#include <vector>

using namespace rta::update;

static int g_fail = 0;
static int g_pass = 0;

static void ck(bool ok, const std::string& what, const std::string& detail = "") {
    if (ok) { ++g_pass; std::printf("  [PASS] %s\n", what.c_str()); }
    else {
        ++g_fail;
        std::printf("  [FAIL] %s", what.c_str());
        if (!detail.empty()) std::printf("  —— %s", detail.c_str());
        std::printf("\n");
    }
}

static const char* ch_name(UpdateChannel c) {
    return c == UpdateChannel::ChinaMainland ? "ChinaMainland" : "Global";
}

int main() {
    setvbuf(stdout, nullptr, _IONBF, 0);

    // =====================================================================
    std::printf("=== 1. 默认值（框架阶段 = 全球；切换点唯一）===\n");
    // =====================================================================
    // ⚠️ 框架阶段默认必须是 Global：后台 dmg 尚未适配，默认切大陆会立刻不可用。
    //    后台适配完成后才允许把 kDefaultChannel 改成 ChinaMainland ——
    //    届时这条断言会**故意变红**，改动者必须同步更新注释里的切换说明
    //    （见 update_channel.h:46-51）与设置页默认值，这是有意留下的显式提醒。
    {
        // 默认值只能有一个真相源：Config 的缺省通道必须与 kDefaultChannel 一致。
        const Config c;
        ck(kDefaultChannel == UpdateChannel::Global,
           "kDefaultChannel == UpdateChannel::Global（后台适配后应改为 ChinaMainland）",
           ch_name(kDefaultChannel));
        ck(c.channel == kDefaultChannel, "Config 缺省通道派生自 kDefaultChannel（唯一真相源）",
           ch_name(c.channel));
        // 枚举 → 配置键：写回 update.conf 与模板用的就是这两个值。
        ck(std::string(channel_config_value(UpdateChannel::Global)) == "global",
           "channel_config_value(Global) == \"global\"", channel_config_value(UpdateChannel::Global));
        ck(std::string(channel_config_value(UpdateChannel::ChinaMainland)) == "cn",
           "channel_config_value(ChinaMainland) == \"cn\"",
           channel_config_value(UpdateChannel::ChinaMainland));
        ck(std::string(channel_code(UpdateChannel::ChinaMainland)) == "cn" &&
               std::string(channel_code(UpdateChannel::Global)) == "global",
           "channel_code 与配置键同形（UI 命令/回显）");
    }

    // =====================================================================
    std::printf("\n=== 2. 通道解析真值表（含对抗用例）===\n");
    // =====================================================================
    // 2.1 合法值（大小写不敏感、容忍首尾空白、china 为容错别名）
    {
        struct Row { const char* raw; UpdateChannel want; };
        const Row rows[] = {
            {"global",      UpdateChannel::Global},
            {"cn",          UpdateChannel::ChinaMainland},
            {"china",       UpdateChannel::ChinaMainland},   // 容错别名
            {"CN",          UpdateChannel::ChinaMainland},
            {"China",       UpdateChannel::ChinaMainland},
            {"GLOBAL",      UpdateChannel::Global},
            {"  cn  ",      UpdateChannel::ChinaMainland},   // 首尾空白
            {"\tcn\n",      UpdateChannel::ChinaMainland},   // 其它空白字符
            {" china ",     UpdateChannel::ChinaMainland},
        };
        for (const Row& r : rows) {
            const ChannelParseResult p = parse_channel(r.raw);
            ck(p.valid && p.channel == r.want && p.warning.empty(),
               std::string("解析 \"") + r.raw + "\" → " + ch_name(r.want) + "（valid、无 warning）",
               std::string("实际 ") + ch_name(p.channel) +
                   " valid=" + std::to_string((int)p.valid) + " warning=" + p.warning);
        }
    }
    // 2.2 空 / 纯空白 = 未配置 ⟹ 默认通道、valid、**无 warning**（首次运行不该弹窗）
    {
        const char* empties[] = {"", "   ", "\t", "\n\r\t "};
        for (const char* e : empties) {
            const ChannelParseResult p = parse_channel(e);
            ck(p.channel == kDefaultChannel && p.valid && p.warning.empty(),
               std::string("空/纯空白 \"") + e + "\" ⟹ 默认通道、valid=true、无 warning",
               std::string("实际 ") + ch_name(p.channel) +
                   " valid=" + std::to_string((int)p.valid) + " warning=" + p.warning);
        }
    }
    // 2.3 非法值：安全回退默认通道 + valid=false + warning 非空（绝不静默选未知通道）
    {
        const char* bad[] = {
            "wat", "cn2", "globalx", "-cn", "cn-", "0", "1", "true", "china mainland",
            "cn;evil", "cn\tglobal",
        };
        for (const char* b : bad) {
            const ChannelParseResult p = parse_channel(b);
            ck(!p.valid && p.channel == UpdateChannel::Global && !p.warning.empty(),
               std::string("非法值 \"") + b + "\" ⟹ 回退 Global、valid=false、warning 非空",
               std::string("实际 ") + ch_name(p.channel) +
                   " valid=" + std::to_string((int)p.valid) + " warning=" + p.warning);
        }
    }
    // 2.4 【关键对抗判据】通道值**不是任意字符串通道**：
    //     把 URL 或形近域名填进 channel= 必须判非法并回退。
    //     若实现写成「包含 cn 就算大陆」或「非空就是通道」，下面两条会变绿 —— 那正是要防的。
    {
        const char* adversarial[] = {
            "cn.evil.com",                              // 形近域名
            "https://rlplayer.rainlain.com",            // URL 冒充通道值
            "https://rlplayer.rainlain.com/",           // URL（带路径）
            "https://evil.com/cn",                      // URL 里含 cn
            "rlplayer.rainlain.com",                    // 裸主机名也不是通道值
            "cn.evil.com/",                             // 形近 + 路径
        };
        for (const char* a : adversarial) {
            const ChannelParseResult p = parse_channel(a);
            ck(!p.valid && p.channel == UpdateChannel::Global,
               std::string("【对抗】\"") + a + "\" 不是通道值 ⟹ valid=false 且回退 Global",
               std::string("实际 ") + ch_name(p.channel) +
                   " valid=" + std::to_string((int)p.valid));
        }
        // 反向自证：这组用例真的能区分「精确匹配」与「包含匹配」。
        // 若实现用 find("cn")，下面两条会返回 ChinaMainland —— 上面那组对抗断言才有意义。
        ck(parse_channel("cn.evil.com").channel == UpdateChannel::Global,
           "对照组：不因字符串里含 \"cn\" 就选大陆（证明上面用的是精确匹配）");
        ck(parse_channel("https://rlplayer.rainlain.com").valid == false,
           "对照组：合法 URL 不等于合法通道值");
        // warning 文案不得回显原始输入（避免把可疑清单/URL 带进日志）
        const ChannelParseResult evil = parse_channel("https://evil.com/cn");
        ck(evil.warning.find("evil.com") == std::string::npos,
           "invalid 的 warning 不回显原始输入（不把可疑字符串带进日志）", evil.warning);
    }

    // =====================================================================
    std::printf("\n=== 3. 通道 → 清单来源（只返回常量，不发请求）===\n");
    // =====================================================================
    {
        // 3.1 global 必须**原样**返回调用方给的地址（现有行为一字不变）
        const std::string gh = "https://raw.githubusercontent.com/X/latest.json";
        ck(channel_manifest_url(UpdateChannel::Global, gh) == gh,
           "global ⟹ 原样返回传入的 globalManifestUrl（无行为变更）",
           channel_manifest_url(UpdateChannel::Global, gh));
        // 3.2 用真实的默认清单地址再验一次（防止实现偷偷把 global 也改到别处）
        ck(channel_manifest_url(UpdateChannel::Global, kDefaultManifestUrl) == kDefaultManifestUrl,
           "global + kDefaultManifestUrl ⟹ 仍是 kDefaultManifestUrl");
        // global 传空串也必须回空串（不做任何「顺手替换成大陆」的兜底）
        ck(channel_manifest_url(UpdateChannel::Global, "").empty(),
           "global + 空串 ⟹ 空串（不偷偷兜底到别的来源）");
    }
    {
        // 3.3 cn 必须等于后台常量，且常量字面量正确
        ck(std::string(kChinaManifestUrl) ==
               "https://rlplayer.rainlain.com/api/v1/update/macos/latest",
           "kChinaManifestUrl 字面量正确", kChinaManifestUrl);
        ck(channel_manifest_url(UpdateChannel::ChinaMainland, "") == std::string(kChinaManifestUrl),
           "cn + 任意输入 ⟹ kChinaManifestUrl（忽略 global 地址）",
           channel_manifest_url(UpdateChannel::ChinaMainland, ""));
        ck(channel_manifest_url(UpdateChannel::ChinaMainland,
                                "https://raw.githubusercontent.com/X/latest.json") ==
               std::string(kChinaManifestUrl),
           "cn + 全球地址 ⟹ 仍走后台清单（不会串到 GitHub）");
        ck(std::string(kChinaHost) == "rlplayer.rainlain.com", "kChinaHost 与清单主机一致",
           kChinaHost);
        // 3.4 清单来源本身必须在白名单内 —— 否则 cn 分支拿到清单也过不了闸门
        ck(update_download_url_allowed(kChinaManifestUrl),
           "kChinaManifestUrl 过 update_download_url_allowed（清单来源在白名单内）");
    }

    // =====================================================================
    std::printf("\n=== 4. 白名单：后台域名放行、形近/端口/userinfo/非 https 全拒 ===\n");
    // =====================================================================
    {
        // 4.1 放行：清单 + 对象（对象名 = 64 hex）
        const std::string objUrl =
            "https://rlplayer.rainlain.com/api/v1/update/macos/objects/" +
            std::string(64, 'a') + ".zip";
        ck(update_download_url_allowed("https://rlplayer.rainlain.com/api/v1/update/macos/latest"),
           "放行：后台清单 URL");
        ck(update_download_url_allowed(objUrl), "放行：后台对象 URL（64 hex + .zip）", objUrl);
        // 主机大小写不敏感（与既有规则一致）
        ck(update_download_url_allowed("HTTPS://RLPLAYER.RAINLAIN.COM/api/v1/update/macos/latest"),
           "放行：后台主机大小写不敏感（与既有规则一致）");
    }
    {
        // 4.2 全拒：形近域名 / 端口 / userinfo / 非 https / 无路径 / 空路径
        const char* deny[] = {
            "https://rlplayer.rainlain.com.evil.com/x",   // 后缀伪装
            "https://evil.rlplayer.rainlain.com/x",       // 子域伪装（前缀多一段）
            "https://evilrlplayer.rainlain.com/x",        // 无点前缀伪装
            "https://rlplayer.rainlain.com:8080/x",       // 端口变体
            "https://rlplayer.rainlain.com:443/x",        // 显式 443 也不认（精确匹配主机）
            "http://rlplayer.rainlain.com/x",             // 非 https
            "https://user@rlplayer.rainlain.com/x",       // userinfo 伪装
            "https://user:pass@rlplayer.rainlain.com/x",  // userinfo（带密码）
            "https://rlplayer.rainlain.com",              // 无路径
            "https://rlplayer.rainlain.com/",             // 路径空
            "https://rlplayer.rainlain.com/x\nHost: evil.com",  // CRLF 注入
            "ftp://rlplayer.rainlain.com/x",              // 其它 scheme
        };
        for (const char* d : deny) ck(!update_download_url_allowed(d), std::string("拒绝：") + d);
    }
    {
        // 4.3 回归：加第三个主机**不得放宽**原有规则（证明白名单不是"多一个就全都多过"）
        const char* denyOld[] = {
            "https://evil.com/x",
            "https://raw.githubusercontent.com.evil.com/x",
            "https://github.com.evil.com/x",
            "https://evilgithub.com/x",
            "https://github.com:8080/x",
            "https://user@github.com/x",
        };
        for (const char* d : denyOld) ck(!update_download_url_allowed(d),
                                        std::string("回归拒绝：") + d);
        // 原有两条规则仍在放行
        ck(update_download_url_allowed(
               "https://github.com/BH2VOQ/RLPlayer-Mac/releases/download/v1.0.4/x.dmg"),
           "回归放行：github.com release 附件");
        ck(update_download_url_allowed(
               "https://raw.githubusercontent.com/BH2VOQ/RLPlayer-Mac/main/latest.json"),
           "回归放行：raw.githubusercontent.com 清单");
    }

    // =====================================================================
    std::printf("\n=== 5. cn 不可用 ≠ 已是最新（最关键的一条）===\n");
    // =====================================================================
    {
        const CheckResult r = evaluate_china_channel_placeholder();
        ck(!r.up_to_date(), "【关键】cn 占位失败态 up_to_date() == false（绝不谎报已是最新）");
        ck(!r.available(), "cn 占位失败态 available() == false（不谎报有更新）");
        ck(!r.ok(), "cn 占位失败态 ok() == false（UI 只允许对 ok() 显示成功）");
        ck(r.decision == Decision::FailedNetwork, "cn 占位决策 == FailedNetwork（诚实失败）",
           decision_code(r.decision));
        ck(r.status == 0, "cn 占位 status == 0（传输层根本没发生）", std::to_string(r.status));
        ck(r.error == kChinaChannelUnavailableMessage, "cn 占位 error == kChinaChannelUnavailableMessage",
           r.error);
        ck(!r.error.empty(), "cn 占位 error 非空（用户能看到明确原因）");
        // 文案红线：不含 URL（不把用户引到某个地址）、不引导网盘
        ck(r.error.find("http") == std::string::npos, "错误文案不含 URL", r.error);
        ck(r.error.find("baidu") == std::string::npos &&
               r.error.find("百度") == std::string::npos &&
               r.error.find("pan.") == std::string::npos,
           "错误文案不引导网盘", r.error);
        // 也不得回显 token / 凭据类字样
        ck(r.error.find("token") == std::string::npos &&
               r.error.find("Token") == std::string::npos,
           "错误文案不提 token/凭据", r.error);
        // 交叉断言：它与「真正的传输层失败」是同一个决策码（调用方只需处理一套失败语义）
        const CheckResult netFail = evaluate_update_check("1.1.5", false, 0, "");
        ck(netFail.decision == r.decision,
           "cn 占位的决策码与真实网络失败同一套（调用链形状一致）",
           std::string(decision_code(netFail.decision)) + " vs " + decision_code(r.decision));
    }

    // =====================================================================
    std::printf("\n=== 6. 两套通道的版本/sha256 比较行为一致 ===\n");
    // =====================================================================
    // 说明：真实 cn 分支本轮走第 5 条的 placeholder（不取清单）；这里证明的是
    //       「清单一旦合法，判定逻辑不因来源域名而不同」—— 等后台就绪后
    //       placeholder 换成「取签名清单 → 验签 → 取对象 → 重组 → evaluate_update_check」时，
    //       版本比较/sha256 的语义不需要第二套实现。
    {
        const std::string kSha =
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
        const std::string ghUrl =
            "https://github.com/BH2VOQ/RLPlayer-Mac/a.dmg";
        const std::string cnUrl =
            "https://rlplayer.rainlain.com/api/v1/update/macos/objects/" +
            std::string(64, 'b') + ".zip";
        auto body = [&](const std::string& url, const std::string& ver) {
            return std::string("{\"version\":\"") + ver + "\",\"download_url\":\"" + url +
                   "\",\"sha256\":\"" + kSha + "\",\"size\":7139420,\"notes\":\"n\"}";
        };
        // 前提：两个地址都真的过白名单（否则下面测的就不是"域名差异"，而是"域名非法"）
        ck(update_download_url_allowed(ghUrl) && update_download_url_allowed(cnUrl),
           "前提：两条通道的 download_url 都在白名单内");

        // 6.1 本地 1.1.4、远端 1.1.5 ⟹ 两者都 UpdateAvailable
        const CheckResult ghNew = evaluate_update_check("1.1.4", true, 200, body(ghUrl, "1.1.5"), false);
        const CheckResult cnNew = evaluate_update_check("1.1.4", true, 200, body(cnUrl, "1.1.5"), false);
        ck(ghNew.decision == Decision::UpdateAvailable, "全球通道 ⟹ UpdateAvailable",
           std::string(decision_code(ghNew.decision)) + " " + ghNew.error);
        ck(cnNew.decision == Decision::UpdateAvailable,
           "大陆通道域名 ⟹ UpdateAvailable（同一套版本比较，不是另立一套）",
           std::string(decision_code(cnNew.decision)) + " " + cnNew.error);
        ck(ghNew.decision == cnNew.decision, "两通道 decision 相同");
        ck(ghNew.remoteVersion == "1.1.5" && cnNew.remoteVersion == "1.1.5",
           "两通道 remoteVersion 都是 1.1.5",
           ghNew.remoteVersion + " / " + cnNew.remoteVersion);
        ck(ghNew.sha256 == kSha && cnNew.sha256 == kSha && ghNew.sha256 == cnNew.sha256,
           "两通道 sha256 一致（同一条校验闸门）");
        ck(ghNew.size == cnNew.size && ghNew.size == 7139420, "两通道 size 一致");

        // 6.2 反向：本地 1.1.5、远端 1.1.5 ⟹ 两者都 UpToDate
        const CheckResult ghSame = evaluate_update_check("1.1.5", true, 200, body(ghUrl, "1.1.5"), false);
        const CheckResult cnSame = evaluate_update_check("1.1.5", true, 200, body(cnUrl, "1.1.5"), false);
        ck(ghSame.decision == Decision::UpToDate, "全球通道同版本 ⟹ UpToDate",
           std::string(decision_code(ghSame.decision)) + " " + ghSame.error);
        ck(cnSame.decision == Decision::UpToDate,
           "大陆通道域名同版本 ⟹ UpToDate（不因域名不同就改变「已是最新」判定）",
           std::string(decision_code(cnSame.decision)) + " " + cnSame.error);
        ck(ghSame.up_to_date() && cnSame.up_to_date(), "两者的 up_to_date() 都为 true");

        // 6.3 反面：合法清单但地址非法 ⟹ 两条通道都必须 FailedBadUrl
        //     （白名单是"清单被篡改"的闸门，与通道来源无关）
        const std::string evilBody = body("https://evil.com/x.dmg", "1.1.5");
        const CheckResult bad = evaluate_update_check("1.1.4", true, 200, evilBody, false);
        ck(bad.decision == Decision::FailedParse || bad.decision == Decision::FailedBadUrl,
           "非白名单地址 ⟹ 拒绝（FailedParse/FailedBadUrl）",
           std::string(decision_code(bad.decision)) + " " + bad.error);
        ck(!bad.available() && !bad.up_to_date(), "地址非法 ⟹ 既不「有更新」也不「已是最新」");
    }

    // =====================================================================
    std::printf("\n=== 7. 配置解析（channel= 键）===\n");
    // =====================================================================
    {
        ck(parse_update_config("channel=cn\n").channel == UpdateChannel::ChinaMainland,
           "channel=cn ⟹ ChinaMainland");
        ck(parse_update_config("channel=global\n").channel == UpdateChannel::Global,
           "channel=global ⟹ Global");
        ck(parse_update_config("").channel == UpdateChannel::Global,
           "空配置 ⟹ Global（默认）");
        // 大小写 / 空白 / 别名
        ck(parse_update_config("CHANNEL = CN\n").channel == UpdateChannel::ChinaMainland,
           "键名/取值大小写与 '=' 两侧空白都容忍");
        ck(parse_update_config("channel=china\n").channel == UpdateChannel::ChinaMainland,
           "channel=china 别名 ⟹ ChinaMainland");
    }
    {
        // 7.2 非法值 ⟹ 安全回退 Global + warning 非空
        const Config c = parse_update_config("channel=wat\n");
        ck(c.channel == UpdateChannel::Global, "channel=wat ⟹ 回退 Global", ch_name(c.channel));
        ck(!c.warning.empty(), "channel=wat ⟹ warning 非空（不静默）", c.warning);
        ck(c.warning.find("channel") != std::string::npos, "warning 指出是 channel 键的问题", c.warning);
        // 非法通道值时其余键照常生效（不能因为一个坏键整体失效）
        const Config c2 = parse_update_config("channel=wat\ntoken=abc\n");
        ck(c2.channel == UpdateChannel::Global && c2.hasToken && c2.token == "abc",
           "channel 非法不影响 token 解析");
    }
    {
        // 7.3 两键共存：channel=cn 与 token 互不覆盖
        const Config c = parse_update_config("channel=cn\ntoken=abc\n");
        ck(c.channel == UpdateChannel::ChinaMainland, "两键共存：channel=cn 生效");
        ck(c.hasToken && c.token == "abc", "两键共存：token 生效");
        ck(c.warning.empty(), "两键都合法 ⟹ 无 warning（不该拿合法配置弹窗）");
        // manifest_url 与 channel 也是独立键
        const Config c3 = parse_update_config(
            "channel=cn\nmanifest_url=https://evil.com/latest.json\n");
        ck(c3.channel == UpdateChannel::ChinaMainland && !c3.manifestUrlValid,
           "channel 与 manifest_url 各自独立判定（非法 manifest_url 不被 channel 掩盖）");
    }
    {
        // 7.4 默认模板含 channel=global，且模板能被自己解析回默认通道
        const std::string tpl = default_update_conf_template();
        ck(tpl.find("channel=global") != std::string::npos,
           "默认模板含子串 \"channel=global\"");
        const Config c = parse_update_config(tpl);
        ck(c.channel == kDefaultChannel, "模板解析回来 == kDefaultChannel（模板与默认值不分叉）",
           ch_name(c.channel));
        ck(c.warning.empty(), "模板自身解析无 warning");
        // 模板里 channel 只出现一次（防止两行 channel= 互相覆盖的糊状模板）
        size_t n = 0, p = 0;
        while ((p = tpl.find("channel=", p)) != std::string::npos) { ++n; ++p; }
        ck(n == 1, "模板里 channel= 只出现一次（不给自己留两个入口）", std::to_string(n));
    }

    // =====================================================================
    std::printf("\n=== 8. ChannelManifest::ready() 顺序闸门 ===\n");
    // =====================================================================
    {
        // 8.1 默认构造：未验签、未重组 ⟹ 一律不得进入安装链路
        ck(!ChannelManifest{}.ready(), "默认构造 ⟹ ready()==false（框架阶段永远进不了安装）");
    }
    {
        // 8.2 只填判定字段、不置两个 flag ⟹ false（证明"数据看起来齐了"不等于"可以装"）
        ChannelManifest m;
        m.version = "1.1.5";
        m.sha256  = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
        m.size    = 7139420;
        m.notes   = "n";
        ck(!m.ready(), "只填 version/sha256/size ⟹ ready()==false（没验签/没重组就不许装）");

        // 8.3 只验签、没重组 ⟹ false（顺序闸门：② 完成不等于 ④ 完成）
        m.signatureVerified = true;
        ck(!m.ready(), "只置 signatureVerified ⟹ ready()==false（objectsAssembled 仍是 false）");

        // 8.4 只重组、没验签 ⟹ false（反向也不能漏）
        m.signatureVerified = false;
        m.objectsAssembled  = true;
        ck(!m.ready(), "只置 objectsAssembled ⟹ ready()==false（未验签的对象绝不许装）");

        // 8.5 两个 flag 都 true 但摘要为空 ⟹ false（最后一道摘要闸门）
        m.signatureVerified = true;
        m.objectsAssembled  = true;
        ck(m.ready(), "全部齐备 ⟹ ready()==true（闸门不是恒假）");

        const std::string keepSha = m.sha256;
        m.sha256.clear();
        ck(!m.ready(), "两 flag 都 true 但 sha256 为空 ⟹ ready()==false");
        m.sha256 = keepSha;

        // 8.6 其它字段缺失同样拦住
        m.version.clear();
        ck(!m.ready(), "两 flag 都 true 但 version 为空 ⟹ ready()==false");
        m.version = "1.1.5";

        m.size = 0;
        ck(!m.ready(), "两 flag 都 true 但 size==0 ⟹ ready()==false（无法校验截断）");
        m.size = 7139420;

        ck(m.ready(), "恢复全部字段 ⟹ ready() 再次 true（前面几条不是靠「永远 false」混过）");

        // 8.7 objects 只是数据，不参与 ready()：空对象列表也不许绕过前两道闸门
        ChannelManifest empty;
        empty.version = "1.1.5";
        empty.sha256  = keepSha;
        empty.size    = 1;
        ck(!empty.ready(), "无对象列表 + 未验签 ⟹ ready()==false（files[] 缺失也不放行）");
        empty.signatureVerified = true;
        empty.objectsAssembled  = true;
        ck(empty.ready(), "对象的完整性由 ③④ 实现负责，ready() 只做顺序闸门（显式记录该边界）");
    }

    // =====================================================================
    // 汇总
    // =====================================================================
    std::printf("\n=== 汇总：%d 通过 / %d 失败 ===\n", g_pass, g_fail);
    if (g_fail == 0) std::printf("全部通过\n");
    else std::printf("存在失败\n");
    return g_fail == 0 ? 0 : 1;
}
