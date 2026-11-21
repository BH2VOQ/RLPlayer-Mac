#!/usr/bin/env node
'use strict';

/*
 * 把仓库根目录的 latest.json 同步到 website/latest.json。
 * 发版后先跑这一步，站点部署后版本号、下载直链与 SHA-256 才会一起更新。
 */

const fs = require('fs');
const path = require('path');

const siteRoot = path.resolve(__dirname, '..');
const source = path.join(siteRoot, '..', 'latest.json');
const target = path.join(siteRoot, 'latest.json');

if (!fs.existsSync(source)) {
  console.error('找不到仓库根目录 latest.json：' + source);
  process.exit(1);
}

const text = fs.readFileSync(source, 'utf8');
const data = JSON.parse(text);

for (const key of ['version', 'download_url', 'sha256', 'size']) {
  if (data[key] === undefined || data[key] === '') {
    console.error('latest.json 缺少必要字段：' + key);
    process.exit(1);
  }
}
if (!/^[a-fA-F0-9]{64}$/.test(data.sha256)) {
  console.error('latest.json 的 sha256 不是 64 位十六进制');
  process.exit(1);
}

fs.writeFileSync(target, text);
console.log('已同步 latest.json → website/latest.json');
console.log('  version = ' + data.version);
console.log('  size    = ' + data.size + ' bytes');
