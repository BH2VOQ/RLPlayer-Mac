// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_ai_fill.cpp — 1.1.4-beta4「AI 辅助爬取封面歌词」纯函数离线单测
//
// 判据说明（铁律 3：测试通过 ≠ 测对了东西）：
//   只测 src/meta/ai_fill.h 的纯函数（触发判定 / 提示词 / 回包解析 / 名字可用性），
//   全部内存字符串运算，零网络、零文件、零时钟。AI 辅助的**编排**（失败→规范化→重跑
//   确定性链）在 enrich.h 的 enrich_track wrapper，属集成行为，不由本文件伪造「重跑成功」。
//   本文件证明的是「什么情况下触发、提示词约束了什么、回包怎么解析、什么名字值得重跑」。
#include "meta/ai_fill.h"
#include <cstdio>
#include <string>

using namespace rta::meta;

static int g_pass = 0, g_fail = 0;
static void ck(bool cond, const std::string& what, const std::string& detail = std::string()) {
    if (cond) { std::printf("  [PASS] %s\n", what.c_str()); ++g_pass; }
    else { std::printf("  [FAIL] %s  %s\n", what.c_str(), detail.c_str()); ++g_fail; }
}

int main() {
    std::printf("== 1.1.4-beta4 AI 辅助爬取（纯离线）==\n");

    // -- 1) 触发判定：仅「开关开 + LLM 可用 + 首轮未采纳 + 非 skipped」 ----------
    std::printf("-- 1) ai_fill_should_retry 触发判定 --\n");
    ck(ai_fill_should_retry(true, true, false, false), "开关开 + LLM 可用 + 失败 + 非跳过 → 触发重跑");
    ck(!ai_fill_should_retry(false, true, false, false), "开关关 → 不触发（默认关闭，零额外费用）");
    ck(!ai_fill_should_retry(true, false, false, false), "LLM 不可用（无 key）→ 不触发");
    ck(!ai_fill_should_retry(true, true, true, false), "首轮已采纳（ok=true）→ 不触发");
    ck(!ai_fill_should_retry(true, true, false, true), "skipped（已有完整记录）→ 不触发");

    // -- 2) 提示词：含文件名、明确禁止编造封面/歌词/URL ------------------------
    std::printf("-- 2) ai_fill_name_prompt 提示词 --\n");
    {
        const std::string p = ai_fill_name_prompt("周杰伦 - 晴天 [FLAC]", "Track 01", "Unknown", "", "七里香");
        ck(p.find("周杰伦 - 晴天 [FLAC]") != std::string::npos, "提示词含文件名原文（供模型规范化）");
        ck(p.find("Track 01") != std::string::npos && p.find("Unknown") != std::string::npos,
           "提示词含当前解析名（标签名可能是错的，正是要纠正的对象）");
        ck(p.find("七里香") != std::string::npos, "提示词含目录名上下文");
        ck(p.find("不要提供封面图片 URL") != std::string::npos ||
           p.find("不要提供封面") != std::string::npos, "提示词明确禁止 AI 编造封面 URL / 歌词（零幻觉写库）");
        ck(p.find("artist") != std::string::npos && p.find("title") != std::string::npos,
           "提示词要求输出 artist/title 两键 JSON");
        // 文件名含引号/反斜杠时不破坏提示词结构（esc_json）
        const std::string q = ai_fill_name_prompt("a\"b\\c", "", "", "", "");
        ck(q.find("a\\\"b\\\\c") != std::string::npos, "文件名中的引号/反斜杠经 esc_json 转义");
    }

    // -- 3) 回包解析：合法 JSON / 围栏 / 非法输入 -----------------------------
    std::printf("-- 3) ai_fill_parse_name 回包解析 --\n");
    {
        AiFillName n = ai_fill_parse_name("{\"artist\":\"周杰伦\",\"title\":\"晴天\"}");
        ck(n.ok && n.title == "晴天" && n.artist == "周杰伦", "合法两键 JSON 解析成功");
        AiFillName f = ai_fill_parse_name("```json\n{\"artist\":\"A\",\"title\":\"B\"}\n```");
        ck(f.ok && f.title == "B" && f.artist == "A", "带 ```json 围栏的回包解析成功（复用 parse_llm_parse）");
        AiFillName noTitle = ai_fill_parse_name("{\"artist\":\"周杰伦\"}");
        ck(!noTitle.ok, "缺 title → 解析失败（不拿空串去搜，避免无意义重跑）");
        AiFillName bad = ai_fill_parse_name("模型拒绝回答");
        ck(!bad.ok, "纯文本/非法 JSON → 解析失败");
        AiFillName empty = ai_fill_parse_name("");
        ck(!empty.ok, "空回包 → 解析失败");
    }

    // -- 4) 可用性：仅当名字与首轮有实质差异才值得重跑 ------------------------
    std::printf("-- 4) ai_fill_name_usable 名字可用性 --\n");
    {
        AiFillName improved; improved.ok = true; improved.title = "晴天"; improved.artist = "周杰伦";
        ck(ai_fill_name_usable(improved, "Track 01", "Unknown"), "规范化出不同歌名 → 值得重跑");
        ck(!ai_fill_name_usable(improved, "晴天", "周杰伦"), "与首轮完全相同 → 不重跑（省一次 LLM + 网络）");
        AiFillName caseOnly; caseOnly.ok = true; caseOnly.title = "SUNNY"; caseOnly.artist = "Jay";
        ck(!ai_fill_name_usable(caseOnly, "sunny", "jay"), "仅大小写/空白差异 → 不重跑（ai_fill_norm 归一化）");
        AiFillName artistOnly; artistOnly.ok = true; artistOnly.title = "晴天"; artistOnly.artist = "周杰伦";
        ck(ai_fill_name_usable(artistOnly, "晴天", ""), "标题同但补出艺术家 → 值得重跑（查询更准）");
        AiFillName notOk; notOk.ok = false; notOk.title = "晴天";
        ck(!ai_fill_name_usable(notOk, "Track 01", ""), "ok=false（解析失败）→ 不重跑");
        AiFillName emptyTitle; emptyTitle.ok = true; emptyTitle.title = "";
        ck(!ai_fill_name_usable(emptyTitle, "Track 01", ""), "空 title → 不重跑");
    }

    // -- 5) 默认关闭语义（成本铁律）-------------------------------------------
    std::printf("-- 5) 默认关闭语义 --\n");
    {
        // EnrichOpts.aiFill 默认 false —— 与 MetaSettings.aiFill 默认 false 一致。
        // 这里 include enrich.h 会拉入较多依赖，改为直接断言触发式在开关 false 时的结果，
        // 已在第 1 组覆盖。此处补一条：任意失败组合在默认关时都不触发。
        bool allOff = true;
        for (int ok = 0; ok < 2; ++ok)
            for (int skip = 0; skip < 2; ++skip)
                for (int llm = 0; llm < 2; ++llm)
                    if (ai_fill_should_retry(false, llm == 1, ok == 1, skip == 1)) allOff = false;
        ck(allOff, "开关 false 时，任意 (llm/ok/skipped) 组合都不触发兜底");
    }

    std::printf("\nRESULT: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail > 0 ? 1 : 0;
}
