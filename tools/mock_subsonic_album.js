// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// mock_subsonic_album.js — 流媒体「专辑详情页」验收用的假 Subsonic/Navidrome（127.0.0.1，随机端口）。
//
// 拓扑（刻意做成用户描述的那种最小树）：
//   根 → 1 位艺术家(ar1) → 1 张专辑(al1) → 3 首曲目(s1/s2/s3，各带 coverArt 与 duration)
//   ar1 下另有一个空目录(d0)，用来验证「空目录仍是原来的空态、不会被当成专辑页」。
//
// 只实现浏览链路需要的四个端点。**绝不实现 /rest/download.view**（铁律 1：不播放音频、
// 不开音频设备）—— 万一有代码误触 download，拿到的只有 404，不存在任何音频字节。
'use strict';
const http = require('http');
const zlib = require('zlib');
const crypto = require('crypto');

const USER = 'demo';
const PASS = 'demo';

const ARTIST = '测试艺术家';
const ALBUM = '远程专辑';
const EMPTY_DIR = '空目录';
// 3 首曲目：时长刻意取 200/180/240（Σ=620s → 10:20），一眼就能核对「3 首 · 总时长 10:20」。
const TRACKS = [
  { id: 's1', title: '远程曲目一', suffix: 'flac', duration: 200 },
  { id: 's2', title: '远程曲目二', suffix: 'flac', duration: 180 },
  { id: 's3', title: '远程曲目三', suffix: 'flac', duration: 240 },
];

// ---- 64x64 PNG（纯手工编码，避免任何外部依赖）----
function crc32(buf) {
  let c, crc = 0xffffffff;
  for (let n = 0; n < buf.length; n++) {
    c = (crc ^ buf[n]) & 0xff;
    for (let k = 0; k < 8; k++) c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
    crc = (crc >>> 8) ^ c;
  }
  return (crc ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length, 0);
  const t = Buffer.from(type, 'ascii');
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(Buffer.concat([t, data])), 0);
  return Buffer.concat([len, t, data, crc]);
}
function makePng(size, base) {
  const raw = Buffer.alloc((size * 3 + 1) * size);
  let p = 0;
  for (let y = 0; y < size; y++) {
    raw[p++] = 0; // filter type 0
    for (let x = 0; x < size; x++) {
      const stripe = ((x + y) % 16) < 6 ? 38 : 0;   // 斜纹，便于截图肉眼确认是"这张封面"
      raw[p++] = Math.min(255, base[0] + stripe);
      raw[p++] = Math.min(255, base[1] + stripe);
      raw[p++] = Math.min(255, base[2] + stripe);
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0); ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw)),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}
const COVER = makePng(64, [40, 120, 220]);

function md5(s) { return crypto.createHash('md5').update(s).digest('hex'); }

function param(url, key) {
  const m = new RegExp('[?&]' + key + '=([^&]*)').exec(url);
  return m ? decodeURIComponent(m[1]) : '';
}

function trackChild(t) {
  return {
    id: t.id, title: t.title, artist: ARTIST, album: ALBUM,
    suffix: t.suffix, duration: t.duration, isDir: false, coverArt: 'al1',
  };
}

function start() {
  const log = [];
  const server = http.createServer((req, res) => {
    const url = req.url.split('#')[0];
    const path = url.split('?')[0];
    const s = param(url, 's'), t = param(url, 't'), u = param(url, 'u');
    const auth = (u === USER) && (t === md5(PASS + s));
    log.push({ path, auth, id: param(url, 'id') });
    const json = (o) => {
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify(o));
    };
    const denied = () => json({ 'subsonic-response': { status: 'failed', error: { message: 'bad credentials' } } });

    if (path === '/rest/ping.view') {
      return json({ 'subsonic-response': { status: 'ok', version: '1.16.1' } });
    }
    if (!auth) { res.writeHead(401, { 'Content-Type': 'text/plain' }); return res.end('auth required'); }

    if (path === '/rest/getIndexes.view') {
      // 真实 Navidrome 的 Index.artist[] 没有 isDir 字段（后端自己补 dir=true），这里同样不补。
      return json({ 'subsonic-response': { status: 'ok', indexes: { index: [
        { name: 'T', artist: [{ id: 'ar1', name: ARTIST, albumCount: 1 }] },
      ] } } });
    }
    if (path === '/rest/getMusicDirectory.view') {
      const id = param(url, 'id');
      if (id === 'ar1') {
        return json({ 'subsonic-response': { status: 'ok', directory: { id: 'ar1', name: ARTIST, child: [
          { id: 'al1', title: ALBUM, name: ALBUM, artist: ARTIST, isDir: true, coverArt: 'al1' },
          { id: 'd0', title: EMPTY_DIR, name: EMPTY_DIR, isDir: true },   // 无封面 + 空目录
        ] } } });
      }
      if (id === 'al1') {
        // 关键：这三项必须**全是非目录**，前端的「专辑层」判定就看这个。
        return json({ 'subsonic-response': { status: 'ok', directory: { id: 'al1', name: ALBUM, child: TRACKS.map(trackChild) } } });
      }
      return json({ 'subsonic-response': { status: 'ok', directory: { id: id, child: [] } } });
    }
    if (path === '/rest/getCoverArt.view') {
      const id = param(url, 'id');
      if (!id) { res.writeHead(404); return res.end(); }
      res.writeHead(200, { 'Content-Type': 'image/png', 'Content-Length': COVER.length });
      return res.end(COVER);
    }
    // 铁律 1：绝不提供音频字节
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('not found (mock subsonic: no audio stream)');
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      resolve({ port: server.address().port, log, close: () => new Promise((r) => server.close(r)) });
    });
  });
}

module.exports = { start, USER, PASS, ARTIST, ALBUM, EMPTY_DIR, TRACKS };
