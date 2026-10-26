// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// 从 NVIDIA redistrib JSON 里挑出构建 CUDA 后端所需的最小组件（避免 3.7GB 全量安装包）
const https = require('https');

const VER = process.argv[2] || '12.9.0';
const want = ['cuda_nvcc', 'cuda_cudart', 'cuda_cuobjdump', 'cuda_cccl', 'cuda_nvrtc', 'cuda_crt'];
const url = `https://developer.download.nvidia.com/compute/cuda/redist/redistrib_${VER}.json`;

function get(u) {
  return new Promise((res, rej) => {
    https.get(u, r => {
      if (r.statusCode >= 300 && r.statusCode < 400 && r.headers.location) {
        return get(r.headers.location).then(res, rej);
      }
      let b = '';
      r.on('data', d => b += d);
      r.on('end', () => res(b));
    }).on('error', rej);
  });
}

(async () => {
  const raw = await get(url);
  let j;
  try { j = JSON.parse(raw); } catch (e) { console.error('JSON 解析失败，前 300 字符：\n' + raw.slice(0, 300)); process.exit(2); }
  const out = [];
  for (const k of want) {
    const pk = j[k];
    if (!pk) { out.push({ name: k, missing: true }); continue; }
    const plat = pk['windows-x86_64'];
    out.push({
      name: k,
      version: pk.version,
      path: plat && plat.relative_path,
      size: plat && plat.size,
      sha256: plat && plat.sha256,
    });
  }
  console.log(JSON.stringify({ release: j.release_label, components: out }, null, 2));
})();
