#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# gen_native_i18n.py — 把 docs/i18n/chunk-*.en.tsv 生成为原生 UI 的 zh→en 表
#
# 为什么要生成而不是手写：词表有 1800+ 条，转义（引号/反斜杠）手写必错；
# 生成器同时提供 --check，门禁可断言"原生表与词表同步"。
# 唯一事实源仍是 docs/i18n/*.en.tsv（与 web 版同一份）。
import glob, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'docs', 'i18n')
OUT = os.path.join(ROOT, 'tools', 'native_ui', 'RLPNativeI18n.mm')

HEADER = '''// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPNativeI18n.mm — 原生 UI 的中文→英文词表（**由 tools/gen_native_i18n.py 生成，不要手改**）
// 数据源：docs/i18n/chunk-*.en.tsv（与 web 版同一份）。
#import <Foundation/Foundation.h>

NSDictionary *RLPNativeI18nTable(void) {
    static NSDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
'''

FOOTER = '''        };
    });
    return table;
}
'''

def cxx(s: str) -> str:
    return s.replace('\\', '\\\\').replace('"', '\\"')

def main() -> int:
    check = '--check' in sys.argv
    files = sorted(glob.glob(os.path.join(SRC, 'chunk-*.en.tsv')))
    pairs, seen = [], {}
    for path in files:
        for line in open(path, encoding='utf-8'):
            line = line.rstrip('\n')
            if not line.strip():
                continue
            cols = line.split('\t')
            if len(cols) < 2:
                continue
            zh, en = cols[0], cols[1]
            if not en.strip() or en.strip() == zh.strip():
                continue
            if zh in seen:
                continue
            seen[zh] = en
            pairs.append((zh, en))
    body = ''.join(f'            @"{cxx(zh)}": @"{cxx(en)}",\n' for zh, en in pairs)
    text = HEADER + body + FOOTER
    if check:
        try:
            cur = open(OUT, encoding='utf-8').read()
        except FileNotFoundError:
            print('FAIL: RLPNativeI18n.mm 不存在', file=sys.stderr)
            return 2
        if cur != text:
            print('FAIL: 原生词表与 docs/i18n 不同步，请运行 python3 tools/gen_native_i18n.py', file=sys.stderr)
            return 2
        print(f'OK: native i18n up to date ({len(pairs)} pairs)')
        return 0
    with open(OUT, 'w', encoding='utf-8') as f:
        f.write(text)
    print(f'wrote {OUT} ({len(pairs)} pairs)')
    return 0

if __name__ == '__main__':
    sys.exit(main())
