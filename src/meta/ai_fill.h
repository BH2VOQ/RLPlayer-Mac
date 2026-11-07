// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// ai_fill.h — 1.1.4-beta4「AI 辅助爬取封面歌词」的纯函数层
//
// 设计（用户 2026-11-07 修正）：在「设置 → 元数据」里增加开关，自动爬取失败后
//   **自动切换**成 AI 辅助爬取。根因是「自动爬取无法对应歌曲名」——文件名杂乱 /
//   拆分错 / 冷门曲，导致确定性 provider 搜索无候选或低分不敢采纳。
//
// 为什么 AI 只做「歌名规范化」而不是「直接产出封面 URL / 歌词文本」：
//   LLM 编造的图片 URL 大概率 404，编造的歌词会把 B 歌的词写进 A 歌 —— 这正是
//   enrich.h 里 ed_cover_reject_reason / pv_lyric_identity 两道闸要防的事故（铁律 3）。
//   所以 AI 辅助 = 用模型把「标题 + 艺术家」规范化，再用修正后的查询**重跑现有确定性
//   爬取链**：封面来自 provider 的 coverUrl（过魔数/尺寸闸），歌词来自 lyric 源
//   （过 pv_lyric_identity 同曲校验）。AI 不写任何内容进库，只纠正「查询用的名字」。
//
// 本文件全部是纯函数（内存字符串运算，零网络/零文件/零时钟），离线喂写死文本即可测；
//   llm_chat 网络调用不在这里，留在 enrich.h 的编排层（用同一份 LlmConfig）。
#pragma once
#include "meta/parse.h"        // esc_json / parse_llm_parse / ParsedName
#include <algorithm>
#include <cctype>
#include <string>
#include <vector>

namespace rta::meta {

// ---------------------------------------------------------------------------
// 触发判定：自动爬取「失败」+ 开关开启 + LLM 可用。
//   「失败」= 未采纳任何候选（!autoOk），且不是「已有完整记录直接跳过」(!autoSkipped)。
//   跳过不算失败（用户已有完整标签，不该再花一次 LLM 调用）。
//   采纳成功但个别封面/歌词源无结果不在这里触发（本版边界，避免重复计费）；
//   重跑成功链时第 7/8 步会用修正查询自然补齐封面/歌词。
// ---------------------------------------------------------------------------
inline bool ai_fill_should_retry(bool optAiFill, bool llmReady, bool autoOk, bool autoSkipped) {
    return optAiFill && llmReady && !autoSkipped && !autoOk;
}

// ---------------------------------------------------------------------------
// 提示词：只要求规范化「标题 / 艺术家」，明确禁止编造封面 / 歌词 / URL。
//   stem 原文经 esc_json 嵌入（与 parse_llm_prompt 同口径）；把当前解析结果与专辑 /
//   目录名一并给模型当上下文，但要求「拿不准就原样返回，不要臆测」。
// ---------------------------------------------------------------------------
inline std::string ai_fill_name_prompt(const std::string& stem,
                                       const std::string& curTitle,
                                       const std::string& curArtist,
                                       const std::string& album,
                                       const std::string& dirName) {
    std::string o;
    o += "你是音乐文件名规范化助手。自动抓取元数据失败，需要你只做一件事："
         "把杂乱的音频文件名还原成正确的「艺术家 + 曲名」，用于重新检索公开的元数据。\n"
         "严格要求：\n"
         "1. 只输出一个 JSON 对象：{\"artist\":\"艺术家\",\"title\":\"曲名\"}，不要任何解释或代码块围栏；\n"
         "2. 不要提供封面图片 URL、歌词文本或任何链接 —— 那些由程序按规范化后的名字检索，"
         "你编造会写错数据；\n"
         "3. 拿不准就原样返回已有的 artist/title，不要臆测、不要翻译、不要把专辑名当曲名；\n"
         "4. 去掉文件名里的音质标记（FLAC/320K/Hi-Res）、站点后缀、乱码编号，但保留 "
         "Live / Inst / feat. 等真实版本与合作关系。\n";
    o += "文件名：" + esc_json(stem) + "\n";
    o += "当前解析：artist=" + esc_json(curArtist) + " | title=" + esc_json(curTitle) + "\n";
    if (!album.empty())  o += "专辑（仅供参考）：" + esc_json(album) + "\n";
    if (!dirName.empty())o += "所在目录（仅供参考）：" + esc_json(dirName) + "\n";
    return o;
}

// ---------------------------------------------------------------------------
// 回包解析：复用 parse_llm_parse（剥围栏 → 取 {…} → 四键 JSON），只取 artist/title。
//   非法 JSON / 缺 title → ok=false（调用方据此放弃重跑，绝不拿空串去搜）。
// ---------------------------------------------------------------------------
struct AiFillName {
    std::string artist, title;
    bool ok = false;
};
inline AiFillName ai_fill_parse_name(const std::string& text) {
    AiFillName r;
    const ParsedName p = parse_llm_parse(text);
    if (p.title.empty()) return r;              // 无标题 = 解析失败
    r.artist = p.artist;
    r.title  = p.title;
    r.ok = true;
    return r;
}

// 去首尾空白 + 折小写，仅用于「是否与旧名字实质相同」的比较（不参与查询）。
inline std::string ai_fill_norm(const std::string& s) {
    size_t a = 0, z = s.size();
    while (a < z && (unsigned char)s[a] <= 0x20) ++a;
    while (z > a && (unsigned char)s[z - 1] <= 0x20) --z;
    std::string t = s.substr(a, z - a);
    for (char& c : t) c = (char)std::tolower((unsigned char)c);
    return t;
}

// 可用性：修正后 title 非空，且 (title 或 artist) 与旧值有实质差异 —— 否则重跑
//   同一个查询必然得到同样的失败结果，白白再花一次 LLM 调用与一轮网络请求。
inline bool ai_fill_name_usable(const AiFillName& n,
                                const std::string& oldTitle, const std::string& oldArtist) {
    if (!n.ok || n.title.empty()) return false;
    const bool titleChanged  = ai_fill_norm(n.title)  != ai_fill_norm(oldTitle);
    const bool artistChanged = ai_fill_norm(n.artist) != ai_fill_norm(oldArtist);
    return titleChanged || artistChanged;
}

} // namespace rta::meta
