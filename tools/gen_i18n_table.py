#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# gen_i18n_table.py —— 把 docs/i18n/chunk-*.en.tsv 合成 src/net/i18n_table.h
#
# 为什么用生成而不是手写：表有一千多条，手写转义（引号/反斜杠）一定会出错；
# 生成器可以同时做校验（重复键、空译文、残留中文、格式破坏），把校验变成门禁。
#
# 用法：
#   python3 tools/gen_i18n_table.py            # 生成并自检
#   python3 tools/gen_i18n_table.py --check    # 只校验，不写文件（CI/门禁用）
#
# 输入格式（每行三列，TAB 分隔）：中文 <TAB> English <TAB> 上下文（忽略）
#   * en 为空 或 en == zh  ⟹ 视为未翻译，跳过（界面回落中文，不生成死条目）
#   * 同一中文出现两次且译文不同 ⟹ 直接失败（禁止一稿两译）
import glob
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'docs', 'i18n')
OUT = os.path.join(ROOT, 'src', 'net', 'i18n_table.h')

HEADER = '''// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// i18n_table.h —— 界面中文 → 英文对照表（**由 tools/gen_i18n_table.py 生成，不要手改**）
//
// 数据源：docs/i18n/chunk-*.en.tsv（人译 + 主控校对）
// 重新生成：python3 tools/gen_i18n_table.py
//
// 规矩见 docs/i18n-glossary.md：
//   * 只收界面上能看见的中文（含 title / placeholder / aria-label / alt）；
//   * zh 必须与源码字符串逐字一致，引擎是整串匹配 + 长短语替换；
//   * 同一术语全站只用一种译法；出现第二种写法就是缺陷。
#pragma once

#include <cstddef>

namespace rta::net {

struct I18nPair {
    const char* zh;
    const char* en;
};

inline const I18nPair* i18n_table(std::size_t* count) {
    static const I18nPair k[] = {
'''


def cxx_escape(s: str) -> str:
    out = []
    for ch in s:
        if ch == '\\':
            out.append('\\\\')
        elif ch == '"':
            out.append('\\"')
        elif ch == '\t':
            out.append('\\t')
        elif ch == '\n':
            out.append('\\n')
        elif ch == '\r':
            continue
        else:
            out.append(ch)
    return ''.join(out)


def main() -> int:
    check_only = '--check' in sys.argv
    def _order(name):
        stem = os.path.basename(name).split('-', 1)[1].split('.')[0]
        return (0, int(stem), '') if stem.isdigit() else (1, 0, stem)

    files = sorted(glob.glob(os.path.join(SRC, 'chunk-*.en.tsv')), key=_order)
    if not files:
        print('FAIL: no docs/i18n/chunk-*.en.tsv found', file=sys.stderr)
        return 2

    pairs = []          # [(zh, en, source_file)]
    seen = {}           # zh -> (en, file)
    skipped = 0
    total = 0
    for path in files:
        with open(path, encoding='utf-8') as f:
            for lineno, line in enumerate(f, 1):
                line = line.rstrip('\n')
                if not line.strip():
                    continue
                cols = line.split('\t')
                if len(cols) < 2:
                    print(f'FAIL: {path}:{lineno} 少于两列', file=sys.stderr)
                    return 2
                zh, en = cols[0], cols[1]
                total += 1
                if not zh.strip():
                    print(f'FAIL: {path}:{lineno} 中文为空', file=sys.stderr)
                    return 2
                if '\t' in en or '"' in en or '\\' in en:
                    print(f'FAIL: {path}:{lineno} 译文含 TAB/双引号/反斜杠: {en!r}', file=sys.stderr)
                    return 2
                if not en.strip() or en.strip() == zh.strip():
                    skipped += 1
                    continue
                if zh in seen:
                    if seen[zh][0] != en:
                        print(f'FAIL: 一稿两译 {zh!r}: {seen[zh][0]!r} ({seen[zh][1]}) vs {en!r} ({path})',
                              file=sys.stderr)
                        return 2
                    skipped += 1
                    continue
                seen[zh] = (en, os.path.basename(path))
                pairs.append((zh, en))

    if not pairs:
        print('FAIL: 没有任何可用译文', file=sys.stderr)
        return 2

    body = []
    for zh, en in pairs:
        body.append(f'        {{"{cxx_escape(zh)}", "{cxx_escape(en)}"}},\n')
    text = HEADER + ''.join(body) + '''    };
    if (count) *count = sizeof(k) / sizeof(k[0]);
    return k;
}

}  // namespace rta::net
'''

    if check_only:
        try:
            cur = open(OUT, encoding='utf-8').read()
        except FileNotFoundError:
            print('FAIL: src/net/i18n_table.h 不存在', file=sys.stderr)
            return 2
        if cur != text:
            print('FAIL: src/net/i18n_table.h 与 docs/i18n/*.en.tsv 不同步，请运行 '
                  'python3 tools/gen_i18n_table.py', file=sys.stderr)
            return 2
        print(f'OK: i18n table up to date ({len(pairs)} pairs)')
        return 0

    with open(OUT, 'w', encoding='utf-8') as f:
        f.write(text)
    print(f'wrote {OUT}')
    print(f'  rows total={total} pairs={len(pairs)} skipped(untranslated/dup)={skipped}')
    print(f'  sources: {", ".join(os.path.basename(p) for p in files)}')
    if skipped:
        print(f'  NOTE: {skipped} 条仍是中文（界面会回落中文），这些行要在交付里如实列出')
    return 0


if __name__ == '__main__':
    sys.exit(main())
