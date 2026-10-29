// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
const fs = require('fs');
const path = require('path');
const png = fs.readFileSync(process.argv[2]);
const bytes = Array.from(png);
let out = '// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>\n';
out += '// SPDX-License-Identifier: GPL-3.0-or-later\n';
out += '//\n';
out += '// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。\n';
out += '// 完整条款见仓库根目录的 LICENSE 文件。\n';
out += '//\n';
out += '// app_icon.h — 内嵌的 64x64 图标（由 tools/make_icon.js + tools/embed_icon.js 生成）\n';
out += '// 用途：网页 /favicon.png，以及不依赖外部文件\n';
out += '#pragma once\n#include <cstddef>\n\nnamespace rta::net {\n\n';
out += 'inline const unsigned char kAppIconPng[] = {\n';
for (let i = 0; i < bytes.length; i += 16) {
  out += '    ' + bytes.slice(i, i + 16).map(b => b + ',').join('') + '\n';
}
out += '};\n\n';
out += 'inline const size_t kAppIconPngSize = sizeof(kAppIconPng);\n\n';
out += '} // namespace rta::net\n';
fs.writeFileSync(process.argv[3], out);
console.log('写出 ' + process.argv[3] + ' (' + png.length + ' 字节 PNG)');
