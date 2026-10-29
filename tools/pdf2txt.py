# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
# 完整条款见仓库根目录的 LICENSE 文件。
#
import sys
from pypdf import PdfReader
src, dst = sys.argv[1], sys.argv[2]
r = PdfReader(src)
print("pages:", len(r.pages))
with open(dst, "w", encoding="utf-8", errors="replace") as f:
    for i, p in enumerate(r.pages):
        try:
            t = p.extract_text() or ""
        except Exception as e:
            t = f"[PAGE {i+1} EXTRACT ERROR: {e}]"
        f.write(f"\n===== PAGE {i+1} =====\n{t}")
print("done ->", dst)
