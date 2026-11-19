#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# check_native_i18n_coverage.py —— 原生 UI 里每一个 RLPTr(@"中文") 字面量都必须在
# 词表 docs/i18n/chunk-*.en.tsv 里有一条对应中文键，否则英文界面会**回落中文**。
#
# 为什么需要它：gen_i18n_table.py --check 只校验「表本身自洽」（无重复键/空译文），
# 它看不见源码里**新加**的短文案。原生版一路加控件时新增的 RLPTr 文案因此很容易
# 悄悄绕过词表 —— 用户在英文界面就会看到中英混排。
#
# 口径（如实）：
#   * 只查字面量 RLPTr(@"…")。动态拼接（stringWithFormat 的运行时结果、
#     RLPTr([NSString …])）无法静态判定，不在本判据范围内；
#   * 含中文的字面量才算界面上可见的中文（纯 ASCII 的 key/路径不查）；
#   * 键必须**逐字相等**（词表引擎是整串匹配，差一个空格就回落）。
#
# 用法：python3 tools/check_native_i18n_coverage.py [--check] [--list N]
import glob, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TSV = os.path.join(ROOT, 'docs', 'i18n')
UI = os.path.join(ROOT, 'tools', 'native_ui')

CJK = re.compile(r'[\u3400-\u9fff\uf900-\ufaff]')
LIT = re.compile(r'RLPTr\(@"((?:[^"\\]|\\.)*)"\)')


def tsv_keys():
    keys = set()
    for path in glob.glob(os.path.join(TSV, 'chunk-*.en.tsv')):
        for line in open(path, encoding='utf-8'):
            cols = line.rstrip('\n').split('\t')
            if len(cols) < 2:
                continue
            zh, en = cols[0], cols[1]
            if not en.strip() or en.strip() == zh.strip():
                continue     # 空译文/未翻译 ⟹ 生成器跳过，等于不存在
            keys.add(zh)
    return keys


def unescape(s):
    out, i = [], 0
    while i < len(s):
        ch = s[i]
        if ch == '\\' and i + 1 < len(s):
            nxt = s[i + 1]
            out.append({'n': '\n', 't': '\t', '"': '"', '\\': '\\'}.get(nxt, nxt))
            i += 2
        else:
            out.append(ch)
            i += 1
    return ''.join(out)


def main() -> int:
    keys = tsv_keys()
    missing = {}      # zh -> set(files)
    total = 0
    for path in sorted(glob.glob(os.path.join(UI, '*.mm'))):
        src = open(path, encoding='utf-8', errors='replace').read()
        for m in LIT.finditer(src):
            zh = unescape(m.group(1))
            if not CJK.search(zh):
                continue
            total += 1
            if zh not in keys:
                missing.setdefault(zh, set()).add(os.path.basename(path))
    print(f'RLPTr 中文字面量 {total} 处，去重未进词表 {len(missing)} 条（词表键 {len(keys)}）')
    limit = 200
    if '--list' in sys.argv:
        i = sys.argv.index('--list')
        if i + 1 < len(sys.argv):
            limit = int(sys.argv[i + 1])
    for zh, files in sorted(missing.items(), key=lambda kv: (-len(kv[1]), kv[0]))[:limit]:
        print(f'  MISSING  {zh}   [{", ".join(sorted(files))}]')
    if missing:
        print(f'FAIL: {len(missing)} 条中文文案没有英文译文（英文界面会回落中文）')
        return 1
    print('OK: 全部 RLPTr 中文字面量都有英文译文')
    return 0


if __name__ == '__main__':
    sys.exit(main())
