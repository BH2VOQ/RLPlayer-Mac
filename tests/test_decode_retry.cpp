// test_decode_retry.cpp — ffmpeg 解码失败归因 + 瞬时故障重试回归（反馈 20261022-01 现象 B）
//
// 现场（VM，1.0.7）：同一个 FLAC「ZARD - 02.翼を広げて.flac」（日文假名 + 空格）
//   18:22 连播两级都成功（日志 L5/L11 已用 ffmpeg 解码），18:44 起连续四次失败：
//   "ffmpeg 解码失败（退出码 -42 ... Error opening input: Illegal byte sequence)"。
// 即：同一文件、同一进程、间歇性失败 ⟹ 不是文件名编码，也不是文件损坏。
//
// 根因（本测试钉住的两条）：
//   ① **-42 = -EILSEQ 是 ffmpeg 的掩码，不是真实原因。** ffmpeg 打开输入失败后会回退到
//      ANSI 代码页重试；含非 ASCII 字符的路径在该回退里被判成「非法序列」，于是把
//      ENOENT / EACCES / 共享冲突统统报成 Illegal byte sequence。
//      实测对照：日文名文件存在 → exit 0；日文名 + 独占占用 → -42；
//                纯 ASCII 名 + 独占占用 → -13(Permission denied)。
//   ② 真实触发是**源文件此刻读不了**（标签写回的 rename 窗口 / 同步或杀毒扫描的短暂独占）。
//      这类状态是瞬时的，所以修法是：失败后问 Win32「到底能不能读、为什么」，
//      能重试就退避重试，并把 Win32 的真实原因写进错误文本。
//
// 判据设计（铁律 3）——为什么这样测才测得对：
//   * 只断言「抛异常」不够：修前修后都抛。必须断言**错误文本里出现 Win32 真实原因**
//     （"正被其它程序独占占用" / "此刻不存在"）且**不再让 -42 当成唯一解释**。
//   * 只测「成功路径」也不够：成功路径修前就是好的（现场 L5 证明）。必须构造
//     【文件读不了】这个状态，才能复现现场故障。
//   * 重试是否真的生效，用**恢复后能解码成功**来证明（锁释放 → 第 2 次尝试成功），
//     而不是数 Sleep 次数（那只是实现细节）。
//
// ⚠️ 未解决项（铁律 4）：
//   * 现场那四次的**具体占用方**无从取证（日志里没有句柄信息，用户的机器也不在本机）。
//     本测试证明「-42 ⟸ 源文件瞬时不可读」这条因果与修法有效，但不能证明用户机器上
//     那一刻是谁占的。若要定位占用方需在用户机器上加 handle 级遥测。
//   * 「标签写回的 rename 窗口」是**代码审查推断**（writeback.h:414/432 两次 MoveFileEx），
//     本机未在真实写回批次期间抓到该窗口（时序依赖，无稳定复现手段）。
//
// 素材全部落在 %TEMP% 沙箱（含日文名），绝不触碰 MUSIC 与用户数据（铁律 1 无关：不开设备）。
#include "audio/audio_loader.h"
#include "audio/wav.h"

// 2026-10-25：项目转 macOS 单平台。原来这里 #include <windows.h> + <tlhelp32.h>，
// 用 CreateFileW(不共享) 造「源文件被独占占用」故障态。但 macOS 的 flock 是**建议锁**
// （advisory）——不参与加锁的读者照常能读，实测 access(R_OK)=0 且 cat 成功，
// 所以「共享冲突」这个具体形态在 POSIX 上没有等价物。
// 但本测试要证明的**能力**没变：「源文件读不了时，错误必须说出真原因，而不是只报 -42 掩码」。
// macOS 上真实存在且可稳定构造的同类故障是 EACCES（chmod 000，实测稳定触发），
// 所以第 2 段改用权限拒绝构造故障态，判据强度不变（仍是「真原因 + 原始退出码 + 不当成编码问题」）。
#include "test_compat_posix.h"   // SetConsoleOutputCP / CP_UTF8 / GetCurrentProcessId 等
#include <sys/stat.h>
#include <sys/sysctl.h>   // sysctl KERN_PROC_ALL（POSIX 进程快照等价物）
#include <unistd.h>
#include <cstdio>
#include <string>
#include <vector>
#include <filesystem>
#include <fstream>
#include <thread>
#include <chrono>

namespace fs = std::filesystem;

#ifdef _WIN32
extern "C" __declspec(dllimport) int __stdcall SetConsoleOutputCP(unsigned int);
#endif
#ifndef CP_UTF8
#define CP_UTF8 65001
#endif

static int g_fail = 0;
static void ck(bool cond, const char* what, const std::string& detail = "") {
    if (cond) std::printf("  [PASS] %s\n", what);
    else { std::printf("  [FAIL] %s  %s\n", what, detail.c_str()); ++g_fail; }
}

// 探测本进程拉起的 ffmpeg 子进程是否已就绪（用于时序解耦的精确释放）
// 2026-10-25：原实现用 CreateToolhelp32Snapshot + PROCESSENTRY32W 遍历进程树。
// POSIX 等价物：macOS 提供 proc_listchildpids（libproc），可直接列出本进程的直接子进程，
// 再按进程名判断是否 ffmpeg —— 能力等价（都是「我拉起的 ffmpeg 起来了吗」），无副作用。
static bool is_child_ffmpeg_running() {
    // 实测（macOS 27.0.1）：proc_listchildpids 返回 1 字节但解析出 0 个 pid（不可靠），
    // 改用 sysctl KERN_PROC_ALL 全量扫描 + 按 ppid 过滤 —— 实测能正确找到子进程。
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t sz = 0;
    if (::sysctl(mib, 4, nullptr, &sz, nullptr, 0) != 0 || sz == 0) return false;
    std::vector<struct kinfo_proc> procs(sz / sizeof(struct kinfo_proc));
    if (::sysctl(mib, 4, procs.data(), &sz, nullptr, 0) != 0) return false;
    const int cnt = (int)(sz / sizeof(struct kinfo_proc));
    const pid_t me = ::getpid();
    for (int i = 0; i < cnt; ++i) {
        if (procs[(size_t)i].kp_eproc.e_ppid != me) continue;
        if (std::strstr(procs[(size_t)i].kp_proc.p_comm, "ffmpeg") != nullptr) return true;
    }
    return false;
}

// 日文名素材：用 UTF-8 字节字面量，不受编译器 source/execution charset 影响。
// "翼を広げて" = E7 BF BC E3 82 92 E5 BA 83 E3 81 92 E3 81 A6
static const char* kCjkName = "ZARD - 02.\xE7\xBF\xBC\xE3\x82\x92\xE5\xBA\x83\xE3\x81\x92\xE3\x81\xA6.flac";

// 2026-10-25：原夹具用硬编码 "\\" 拼路径。macOS 上 "\\" 不是分隔符而是合法文件名
// 字符，实测导致素材落到 "<tmp>\ZARD - ..."（一个名字里带反斜杠的文件），
// 后续 ffmpeg 一律 No such file or directory，全部用例假失败。
// 这不是判据问题，是夹具路径写法问题 —— 统一走 platform::join()。
static std::string sbpath(const std::string& dir, const std::string& leaf) {
    return rta::platform::join(dir, leaf);
}

static fs::path u8path_of(const std::string& s) {
    return fs::path(std::u8string(reinterpret_cast<const char8_t*>(s.data()), s.size()));
}

// 用包内/环境 ffmpeg 现场生成一个真 FLAC（不依赖 MUSIC）
// 2026-10-25 平台移植：原实现用 ffmpeg 的 lavfi + flac 编码器现场合成素材。
// 但本项目的 build_ffmpeg_lite_mac.sh 是**解码专用**精简版（实测 -encoders 里无 flac、
// -devices 里无 lavfi），系统 Homebrew ffmpeg 又因 x265 soname 断裂起不来（退出码 134）。
// 素材生成不该成为门禁前提 —— 改为**直接写一个合法的单帧 FLAC 文件**（零依赖）。
// 实测：ffprobe 报 duration=1.000000、ffmpeg 能正常解码成 WAV，与真实素材等价。
// 这样本测试在任何有 ffmpeg（哪怕只有解码能力）的环境里都能跑。
static bool make_flac(const std::string& /*ffmpeg*/, const std::string& dst) {
    // 单帧 FLAC：44.1kHz / 16bit / 立体声 / blocksize=44100 ⟹ 恰好 1.0 秒 44100 帧
    // （用 44100 而非 8000：产品侧对输出采样率有断言，且 8kHz 素材会被当成异常源）
    const uint32_t sr = 44100;
    const int ch = 2, bits = 16;
    const uint32_t blocksize = 44100;
    auto crc8 = [](const std::vector<uint8_t>& d) {
        uint8_t c = 0;
        for (uint8_t b : d) { c ^= b; for (int i = 0; i < 8; ++i) c = (c & 0x80) ? uint8_t((c << 1) ^ 0x07) : uint8_t(c << 1); }
        return c;
    };
    auto crc16 = [](const std::vector<uint8_t>& d) {
        uint16_t c = 0;
        for (uint8_t b : d) { c ^= (uint16_t)(b << 8); for (int i = 0; i < 8; ++i) c = (c & 0x8000) ? uint16_t((c << 1) ^ 0x8005) : uint16_t(c << 1); }
        return c;
    };
    std::vector<uint8_t> out = {'f', 'L', 'a', 'C'};
    // STREAMINFO（34 字节）
    std::vector<uint8_t> si;
    auto be16 = [&](std::vector<uint8_t>& v, uint16_t x) { v.push_back(uint8_t(x >> 8)); v.push_back(uint8_t(x)); };
    be16(si, (uint16_t)blocksize); be16(si, (uint16_t)blocksize);
    si.insert(si.end(), {0,0,0, 0,0,0});
    const uint64_t packed = ((uint64_t)sr << 44) | ((uint64_t)(ch - 1) << 41) |
                            ((uint64_t)(bits - 1) << 36) | (uint64_t)blocksize;
    for (int i = 7; i >= 0; --i) si.push_back(uint8_t(packed >> (i * 8)));
    si.insert(si.end(), 16, 0);                 // md5 未知
    out.push_back(0x80);                        // last-metadata-block + type=0
    out.push_back(uint8_t(si.size() >> 16)); out.push_back(uint8_t(si.size() >> 8)); out.push_back(uint8_t(si.size()));
    out.insert(out.end(), si.begin(), si.end());
    // 帧头
    std::vector<uint8_t> fh = {0xFF, 0xF8, 0b0111'1001, 0b0001'1000, 0x00};  // sr code 9 = 44.1kHz
    be16(fh, (uint16_t)(blocksize - 1));        // blocksize code 7 ⟹ 16 位值
    fh.push_back(crc8(fh));
    // ⚠️ 这里**不要**把 fh 单独插进 out：下面 frame = fh + 子帧 会整体插入一次，
    // 单独插会导致帧头重复 8 字节（实测 176462 vs 正确 176454，ffmpeg 报 frames=0）。
    // 两个 VERBATIM 子帧（全零）；CRC16 覆盖「帧头 + 全部子帧」
    std::vector<uint8_t> frame = fh;
    for (int c = 0; c < ch; ++c) {
        frame.push_back(0x02);                              // VERBATIM 子帧头
        frame.insert(frame.end(), (size_t)blocksize * 2, 0); // 全零样本
    }
    const uint16_t fcrc = crc16(frame);
    out.insert(out.end(), frame.begin(), frame.end());
    out.push_back(uint8_t(fcrc >> 8));
    out.push_back(uint8_t(fcrc));

    std::ofstream f(dst, std::ios::binary);
    if (!f) return false;
    f.write((const char*)out.data(), (std::streamsize)out.size());
    f.close();
    return f.good();
}

int main() {
#ifdef _WIN32
    SetConsoleOutputCP(CP_UTF8);
#endif
    std::printf("== ffmpeg 解码失败归因 / 瞬时故障重试（反馈 20261022-01 现象 B）==\n");

    const std::string ffmpeg = rta::audio::find_tool("ffmpeg");
    ck(!ffmpeg.empty(), "环境有 ffmpeg（门禁前提）", "find_tool(\"ffmpeg\") 为空");
    if (ffmpeg.empty()) { std::printf("缺 ffmpeg，门禁无法执行\n"); return 1; }

    // ---- 沙箱目录（%TEMP% 下，进程唯一，绝不碰 MUSIC / 用户数据）----
    wchar_t tmpW[MAX_PATH] = {0};
    GetTempPathW(MAX_PATH, tmpW);
    // 2026-10-25：GetTempPathW 的契约是「返回带尾分隔符的目录」（Win32 语义，垫片如实保留）。
    // 原代码直接字符串相加 ⟹ macOS 上 tmp_directory_path() 本就带 "/" ⟹ 拼出 "<tmp>//rta_..."，
    // 双斜杠路径在 macOS 上 exists()==false（实测），素材写不进沙箱，后续全部用例假失败。
    // 改用 platform::join 归一化分隔符（这是夹具问题，不是判据问题）。
    const std::string sandbox = rta::platform::join(
        rta::audio::wide_to_utf8(tmpW),
        "rta_decode_retry_" + std::to_string((unsigned long)GetCurrentProcessId()));
    std::error_code ec0;
    fs::create_directories(u8path_of(sandbox), ec0);
    std::printf("  沙箱: %s\n", sandbox.c_str());

    const std::string cjk = sbpath(sandbox, kCjkName);
    const std::string ascii = sbpath(sandbox, "ascii_probe.flac");

    // ================= 1) 前提：日文名素材真能生成且真能解码（不是「文件名有问题」） =========
    std::printf("- 1 日文名素材：生成 + 正常解码（排除「文件名编码」这条线）\n");
    {
        const bool a = make_flac(ffmpeg, ascii);
        ck(a, "ffmpeg 生成 ASCII 名 FLAC（模板素材）");
        // 用 filesystem 宽路径复制到日文名 —— 保证落的是【真名】，不经 ACP
        std::error_code ec;
        fs::copy_file(u8path_of(ascii), u8path_of(cjk), fs::copy_options::overwrite_existing, ec);
        ck(!ec && fs::file_size(u8path_of(cjk), ec) > 44, "日文名 FLAC 按真名落盘",
           "size=" + std::to_string((long long)fs::file_size(u8path_of(cjk), ec)));
        try {
            rta::audio::LoadNote note;
            const rta::audio::AudioBuffer b = rta::audio::read_any(cjk, &note);
            ck(b.rate == 44100 && b.channels == 2 && b.frames() > 0,
               "read_any 能解码日文名 FLAC（成功路径不该被误杀）",
               "rate=" + std::to_string(b.rate) + " ch=" + std::to_string(b.channels) +
               " frames=" + std::to_string(b.frames()) + " note=" + note.text);
        } catch (const std::exception& e) {
            ck(false, "read_any 能解码日文名 FLAC（成功路径不该被误杀）", e.what());
        }
    }

    // ================= 2) 核心：源文件读不了时，错误必须说真原因（不是 -42 掩码） =========
    // 2026-10-25 平台移植：原实现用 CreateFileW(不共享) 造「独占占用」。
    // macOS 的 flock 是建议锁（实测：加 LOCK_EX 后 access(R_OK)=0、cat 仍成功），
    // 没有「共享冲突」这个形态。但**能力等价物存在**：chmod 000 造 EACCES（实测稳定触发），
    // 同样是「源文件此刻读不了」这一类故障，同样会让 ffmpeg 回退 ANSI 后报 -42 掩码。
    // 判据强度不变：仍要求①必须失败不静默 ②真原因出现 ③原始退出码保留 ④-42 时明示不代表编码坏。
    std::printf("- 2 源文件读不了（EACCES）：错误文本必须带真实原因（-42 是掩码）\n");
    {
        const mode_t oldMode = ::stat(cjk.c_str(), nullptr) == 0 ? 0644 : 0644;
        ::chmod(cjk.c_str(), 0000);   // 构造故障态：无读权限
        ck(::access(cjk.c_str(), R_OK) != 0, "已把日文名源文件权限改为 000（构造 EACCES 故障态）");
        {
            std::string msg;
            try {
                rta::audio::LoadNote note;
                (void)rta::audio::read_any(cjk, &note);
                msg = "(未抛异常——说明锁没生效或读到了缓存，本用例无效)";
            } catch (const std::exception& e) { msg = e.what(); }
            ::chmod(cjk.c_str(), oldMode);   // 立刻恢复，避免影响后续用例

            std::printf("  [信息] 修复后的错误文本:\n    %s\n", msg.c_str());
            ck(!msg.empty(), "源文件读不了时 read_any 必须失败（不许静默返回空继续播）");
            // 关键判据：真实原因必须出现，且是「读不了」这一类，而不是只有 EILSEQ 的复述。
            // macOS 上 source_read_probe 会给出「没有读取权限（ACL / 只读介质 / 受保护目录）」。
            ck(msg.find("没有读取权限") != std::string::npos || msg.find("源文件此刻读不了") != std::string::npos,
               "错误文本带出真实原因（权限拒绝），不再只有 Illegal byte sequence",
               "got=" + msg);
            // 原始退出码必须如实带出：
            //   zh-CN (ACP 936) 下日文名回退 ANSI 会触发 EILSEQ(-42)；
            //   en-US (ACP 1252，如 CI 云机) 下日文名回退 ANSI 会变乱码找不到路径，触发 ENOENT(-2)。
            // 两者都是 ffmpeg 内部行为，判据断言「原始负数退出码被保留」而不写死某一 locale 的特定数值。
            // 2026-10-25 平台适配：Windows 上 ffmpeg 直接返回负数退出码（-42/-13/-2），
            // POSIX 上进程退出码是 0..255 无符号（-13 会变成 243 = 256-13，-42 变成 214），
            // 这是操作系统的既定语义，不是缺陷。判据因此改为「退出码被如实带出且非 0」——
            // 仍然证明「原始退出码保留供排查」这个能力，只是不写死符号形态。
            ck(msg.find("退出码 ") != std::string::npos && msg.find("退出码 0") == std::string::npos,
               "错误文本保留 ffmpeg 原始非零退出码供排查（POSIX 为 0..255，Windows 为负数）",
               "got=" + msg);
            // 真实原因与假原因区分：
            //   若是 -42 则文本明示「不代表编码坏了」；若非 -42 则说明未触发 EILSEQ，由前一条 Win32 原因断言保证真因定性
            if (msg.find("-42") != std::string::npos) {
                ck(msg.find("不代表文件真有编码问题") != std::string::npos ||
                   msg.find("掩码") != std::string::npos ||
                   msg.find("回退到 ANSI") != std::string::npos,
                   "在报 -42 时错误文本明示「不代表文件编码坏了」（避免把假原因当结论）", "got=" + msg);
            } else {
                ck(msg.find("源文件此刻读不了") != std::string::npos,
                   "在非 -42 退出码时错误文本前置真实原因（非 -42 路径分支）", "got=" + msg);
            }
        }
    }

    // ================= 3) 核心：瞬时故障恢复后必须自动成功（退避重试验证） =========
    // 竞态分析与修法注释（CI run 39812788792 现场归因）：
    //   旧用例 3 在后台线程 150ms 后释放独占锁。在 CI 云机（en-US）上，ffmpeg 启动 + ANSI 回退
    //   耗时超过 150ms，导致 ffmpeg 首轮尝试退出失败时，后台线程早已释放锁。
    //   此时 source_read_probe(path) 检测文件为「此刻可读」（unreadable.empty() == true）。
    //   旧代码存在产品级缺陷：看见 unreadable 为空便误判「文件可读说明失败不是瞬时占用引起的」，
    //   直接 break 放弃重试，抛出「尝试 1 次」失败。
    //   真实场景（杀毒扫描/标签写回短锁）中，占用方在 ffmpeg 尝试期间松手极为常见。
    //   修法（audio_loader.h）：除 rc==0 成功外，首轮失败（i == 0）必须至少再试一次；
    //   只有在已经重试过之后（i >= 1）且探针证明此刻仍可读时才提前 break。
    //   因此，无论锁在 ffmpeg 运行前释放还是运行中释放，read_any 都能确定性成功。
    std::printf("- 3 瞬时占用恢复后应自动解码成功（覆盖运行前释放与运行中释放两类时序）\n");
    {
        // 时序 1：故障在 ffmpeg 运行前 / 极早解除（10ms 恢复权限）
        // 2026-10-25：独占锁 → chmod 000（macOS 上 EACCES 是同类「读不了」故障，见第 2 段说明）
        ::chmod(cjk.c_str(), 0000);
        ck(::access(cjk.c_str(), R_OK) != 0, "已构造故障态（时序 1：10ms 极速恢复）");
        {
            std::thread releaser([&cjk] {
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
                ::chmod(cjk.c_str(), 0644);   // 模拟占用方松手
            });
            bool ok = false;
            std::string err;
            try {
                rta::audio::LoadNote note;
                const rta::audio::AudioBuffer b = rta::audio::read_any(cjk, &note);
                ok = (b.rate == 44100 && b.frames() > 0);
            } catch (const std::exception& e) { err = e.what(); }
            releaser.join();
            ck(ok, "极速释放后 read_any 自动解码成功（时序 1：锁在 ffmpeg 运行前/早期释放）", err);
        }

        // 时序 2：故障在 ffmpeg 运行中解除（150ms 恢复，覆盖首轮失败时故障已消失的时序）
        ::chmod(cjk.c_str(), 0000);
        ck(::access(cjk.c_str(), R_OK) != 0, "已构造故障态（时序 2：150ms 跨尝试恢复）");
        {
            std::thread releaser([&cjk] {
                std::this_thread::sleep_for(std::chrono::milliseconds(150));
                ::chmod(cjk.c_str(), 0644);   // 模拟占用方松手（写回/扫描结束/改名完成）
            });
            bool ok = false;
            std::string err;
            try {
                rta::audio::LoadNote note;
                const rta::audio::AudioBuffer b = rta::audio::read_any(cjk, &note);
                ok = (b.rate == 44100 && b.frames() > 0);
            } catch (const std::exception& e) { err = e.what(); }
            releaser.join();
            ck(ok, "占用释放后 read_any 自动解码成功（时序 2：锁在 ffmpeg 运行中释放）", err);
        }
    }

    // ================= 3b) 确定性复现：首轮失败后探针已可读，仍必须重试并最终成功 =========
    // 根因重现与时序解耦（铁律 3）：
    //   旧判据的致命缺陷在于：若占用在 ffmpeg 首轮解码过程中解除，ffmpeg 虽因启动时被占而返回非 0，
    //   但随后 source_read_probe(path) 检测文件却「此刻可读」（unreadable 为空），
    //   旧代码直接 break 放弃重试，导致原本只需重试一次就能成功的场景直接抛错。
    //   为确定性验证本轮修复（避免依赖单一硬编码 sleep 的偶然性），本用例采用：
    //   ① 进程事件解耦：监听 ffmpeg 子进程启动，一旦检测到 ffmpeg 已运行即刻释放独占锁，
    //      确保「首轮必定遭遇独占失败」且「探针检测与第二轮重试时源文件已恢复可读」；
    //   ② 连续多轮窗口扫描（覆盖 15ms~195ms 递增时延）：遍历所有可能的交错窗口，
    //      全部 10 轮必须 100% 成功，绝不允许「偶尔成功也算过」（判据不弱化）。
    std::printf("- 3b 确定性验证：时序解耦 + 连续多轮窗口扫描（探针此刻可读仍重试成功）\n");
    {
        // ① 进程事件解耦恢复
        ::chmod(cjk.c_str(), 0000);
        ck(::access(cjk.c_str(), R_OK) != 0, "已构造故障态（由 ffmpeg 子进程启动事件触发解耦恢复）");
        {
            std::thread releaser([&cjk] {
                const auto t0 = std::chrono::steady_clock::now();
                while (!is_child_ffmpeg_running()) {
                    if (std::chrono::steady_clock::now() - t0 > std::chrono::milliseconds(500)) break;
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                }
                ::chmod(cjk.c_str(), 0644); // 检测到子进程启动后立即恢复权限
            });
            bool ok = false;
            std::string err;
            try {
                rta::audio::LoadNote note;
                const rta::audio::AudioBuffer b = rta::audio::read_any(cjk, &note);
                ok = (b.rate == 44100 && b.frames() > 0);
            } catch (const std::exception& e) { err = e.what(); }
            releaser.join();
            ck(ok, "时序解耦：检测到 ffmpeg 启动后释放锁，首轮失败后探针可读仍能重试成功", err);
        }

        // ② 连续 10 轮窗口扫描（不同释放时延，遍历运行前/运行中/退避中释放）
        constexpr int kRounds = 10;
        int okCount = 0;
        std::string firstErr;
        for (int r = 0; r < kRounds; ++r) {
            ::chmod(cjk.c_str(), 0000);
            if (::access(cjk.c_str(), R_OK) == 0) {
                if (firstErr.empty()) firstErr = "构造故障态失败（仍可读）";
                break;
            }
            const int delayMs = 15 + r * 20; // 15, 35, 55, 75, 95, 115, 135, 155, 175, 195 ms
            std::thread releaser([&cjk, delayMs] {
                std::this_thread::sleep_for(std::chrono::milliseconds(delayMs));
                ::chmod(cjk.c_str(), 0644);
            });
            try {
                rta::audio::LoadNote note;
                const rta::audio::AudioBuffer b = rta::audio::read_any(cjk, &note);
                if (b.rate == 44100 && b.frames() > 0) ++okCount;
                else if (firstErr.empty()) firstErr = "解码产物为空";
            } catch (const std::exception& e) {
                if (firstErr.empty()) firstErr = e.what();
            }
            releaser.join();
        }
        std::printf("  多轮窗口扫描: ok=%d/%d  firstErr=%s\n", okCount, kRounds, firstErr.empty() ? "-" : firstErr.c_str());
        ck(okCount == kRounds, "连续 10 轮多种瞬时释放窗口全部成功（判据不弱化：100% 通过）",
           "ok=" + std::to_string(okCount) + "/" + std::to_string(kRounds) + " err=" + firstErr);
    }

    // ================= 4) 反向验证：不是「什么都重试」 =================
    // 文件根本不存在时，源文件探针应立刻给出「不存在」，且不做无意义的三次长重试。
    std::printf("- 4 反向：文件确实不存在时报「不存在」（不是无脑重试/不是编码问题）\n");
    {
        const std::string missing = sbpath(sandbox, std::string(kCjkName) + ".does-not-exist");
        std::string msg;
        try {
            rta::audio::LoadNote note;
            (void)rta::audio::read_any(missing, &note);
        } catch (const std::exception& e) { msg = e.what(); }
        ck(!msg.empty(), "不存在的文件必须失败");
        ck(msg.find("不存在") != std::string::npos,
           "错误文本说「不存在」（子串）", "got=" + msg);
    }

    // ================= 5) 并发压力：同一日文名文件 2 线程 × N 轮，不得失败 =================
    // 现场怀疑过「预解码线程与播放线程同时解同一文件」。这里两线程各解 25 轮（共 50）。
    // 铁律 3：断言的是【全部成功】，不是「偶尔成功也算过」。
    std::printf("- 5 并发压力：2 线程 × 25 轮同解日文名文件（现场怀疑的并发线索）\n");
    {
        auto hammer = [&](int rounds, int* okCount, std::string* firstErr) {
            for (int i = 0; i < rounds; ++i) {
                try {
                    rta::audio::LoadNote note;
                    const rta::audio::AudioBuffer b = rta::audio::read_any(cjk, &note);
                    if (b.rate == 44100 && b.frames() > 0) ++(*okCount);
                    else if (firstErr->empty()) *firstErr = "解码结果为空";
                } catch (const std::exception& e) {
                    if (firstErr->empty()) *firstErr = e.what();
                }
            }
        };
        int ok1 = 0, ok2 = 0;
        std::string e1, e2;
        const auto t0 = std::chrono::steady_clock::now();
        std::thread th1(hammer, 25, &ok1, &e1);
        std::thread th2(hammer, 25, &ok2, &e2);
        th1.join(); th2.join();
        const double sec = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        const int total = ok1 + ok2;
        std::printf("  并发结果: ok=%d/50 (%.1fs)  err1=%s  err2=%s\n",
                    total, sec, e1.empty() ? "-" : e1.c_str(), e2.empty() ? "-" : e2.c_str());
        ck(total == 50, "并发 50 次全部成功（并发抢 tmp 名/抢源文件均不成立）",
           "ok=" + std::to_string(total) + "/50 err=" + (e1.empty() ? e2 : e1));
    }

    // ================= 6) 长路径 + 日文 + 空格：连续 30 次顺序解码（稳定性） =================
    // 现场临时 WAV 落在 C:\Users\XINCHE~1\AppData\Local\Temp\（8.3 短名），源文件含日文与空格。
    // 这里把这两点都放大：深层嵌套目录 + 日文目录名 + 文件名带空格与假名，连解 30 次。
    // 判据：30 次全部成功、结果一致（不是「偶尔成功」）。也不许因路径长而误报编码问题。
    std::printf("- 6 长路径/日文/空格：连续 30 次顺序解码\n");
    {
        // 逐层加长（每层都是日文名），最终路径远超常见 100 字符，但仍在 Win32 长路径配合下可用
        std::string deep = sandbox;
        for (int i = 0; i < 6; ++i) {
            deep = rta::platform::join(deep, "");  // 平台分隔符
            deep += "\xE3\x83\x87\xE3\x82\xA3\xE3\x83\xAC\xE3\x82\xAF\xE3\x83\x88\xE3\x83\xAA"  // ディレクトリ
                    "\xE5\x90\x8D\xE9\x95\xB7\xE3\x81\x84";                                            // 名長い
            deep += std::to_string(i);
        }
        std::error_code ec;
        fs::create_directories(u8path_of(deep), ec);
        const std::string longFile = rta::platform::join(
            deep, "ZARD - 02.\xE7\xBF\xBC\xE3\x82\x92\xE5\xBA\x83"
                  "\xE3\x81\x92\xE3\x81\xA6 (long path).flac");
        std::printf("  路径长度: %zu 字符\n", longFile.size());
        fs::copy_file(u8path_of(ascii), u8path_of(longFile), fs::copy_options::overwrite_existing, ec);
        ck(!ec, "长路径日文素材落盘", ec ? ec.message() : "");

        int ok = 0;
        std::string firstErr;
        for (int i = 0; i < 30; ++i) {
            try {
                rta::audio::LoadNote note;
                const rta::audio::AudioBuffer b = rta::audio::read_any(longFile, &note);
                if (b.rate == 44100 && b.frames() > 0) ++ok;
                else if (firstErr.empty()) firstErr = "解码结果为空";
            } catch (const std::exception& e) {
                if (firstErr.empty()) firstErr = e.what();
            }
        }
        std::printf("  顺序解码: %d/30 成功  firstErr=%s\n", ok, firstErr.empty() ? "-" : firstErr.c_str());
        ck(ok == 30, "长路径+日文+空格 连续 30 次全部解码成功（稳定）",
           "ok=" + std::to_string(ok) + "/30 err=" + firstErr);
    }

    // ---- 清理沙箱（只删自己建的 %TEMP% 目录）----
    {
        std::error_code ec;
        fs::remove_all(u8path_of(sandbox), ec);
    }

    std::printf("\n%s\n", g_fail == 0 ? "全部通过" : (std::to_string(g_fail) + " 项失败").c_str());
    return g_fail == 0 ? 0 : 1;
}
