#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
# 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
# 完整条款见仓库根目录的 LICENSE 文件。
"""1.1.1 收口验证：真生产 HTTP 队列契约（#14）与真 CLI 体检判据（#16/#17/#18）。

隔离与安全（沿用 tools/check_111_backend.py 的纪律，不放松）：
  * 端口 19101 由本脚本独占：起服务前 lsof 预检必须为空；起服务后核对监听者就是自己
    Popen 出来的子进程（pid 不符 = 串台，立刻停手）。8899 无论有没有监听都不碰。
  * backend=null / metaon=0 / metallm=0 / volume=-120；**从不打开任何音频设备**。
  * 夹具全部离线手写（标准库 wave + struct），不用 ffmpeg 造信号；唯一用到 ffmpeg-lite
    的地方是「wav → flac」转码，为了拿一个真的截断 FLAC（该精简版无 lavfi/视频编码）。
  * 停服务：先 `ps -p <pid> -o uid=,ppid=,comm=` 核对属主/父进程/程序名，再 SIGTERM + wait；
    绝不 kill -9，绝不杀进程树。

判据（= 调用方给的验收口径，阈值一处不改）：
  #14 15 项队列 + 队列外第 16 首保序追加 / 重复点不重复 / CUE 同 path 不同区间 /
      /api/queue/set 显式替换 / 随机与排序快照不丢项 / 重启持久化；
  #16 满幅方波 EOF 同号削波段、8 kHz 无 >10 kHz 频带、同相/反相 1 kHz 立体声指标、
      等长 10 s 997 Hz 纯音 vs 5 s 纯音 + 5 s −90 dB 尾的 THD+N 差 <1 dB、
      6 ch 1024/2048 帧保 note；
  #17 空参/不存在/非法 WAV/截断 WAV/截断 FLAC 一律 ok=false usable=false 且指标为 null，
      合法短 WAV 仍 usable=true；
  #18 rtahealth --cache 进程间命中逐字段保留；同大小 + mtime_ns 还原的中段改写必须失效，
      且失效后的重算值与 --force 重算一致。

证据：<output>/results.json 记录每次 HTTP 的原始响应、每次 CLI 的 stdout/stderr/exit、
全部夹具的 sha256 与身份（采样率/声道/位深/帧数/时长），以及每条判据的实测数值。
退出码：0 = 全绿，1 = 有红判据，2 = 拒绝执行（端口被占 / 属主核验失败）。
"""
import argparse
import hashlib
import json
import math
import os
import pathlib
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import wave

PORT = 19101
CLIP_THRESHOLD = 0.999      # 与 src/analysis/quality.h 的 kClipThreshold 同一口径
CLIP_RUN_MIN = 3            # kClipRunMin
BODY_CAP = 4000             # 证据里单条原始响应/输出的字符上限（超出截断并标记）

ap = argparse.ArgumentParser(description='RLPlayer 1.1.1 closeout: real HTTP queue (#14) + real CLI health (#16/#17/#18)')
ap.add_argument('--binary', default='build-mac/rtaweb', help='rtaweb 可执行文件')
ap.add_argument('--health', default='build-mac/rtahealth', help='rtahealth 可执行文件')
ap.add_argument('--ffmpeg', default='', help='ffmpeg-lite（默认按 <binary 目录>/ffmpeg-lite/ffmpeg 查找）')
ap.add_argument('--output', default='', help='证据目录（缺省 = 新建临时目录）')
ARGS = ap.parse_args()

BINARY = pathlib.Path(ARGS.binary).resolve()
HEALTH = pathlib.Path(ARGS.health).resolve()
ROOT = pathlib.Path(ARGS.output).resolve() if ARGS.output else pathlib.Path(tempfile.mkdtemp(prefix='rlp-111-closeout-'))
FIX = ROOT / 'fixtures'
MUSIC = ROOT / 'music'          # 服务端 --music-dir：必须保持**空**（夹具放 FIX 里）
STATE = ROOT / 'env' / 'state'

EV = {'schema': 1, 'generated_at': time.strftime('%Y-%m-%dT%H:%M:%S%z'), 'port': PORT,
      'checks': [], 'http': [], 'cli': [], 'fixtures': [], 'ps_checks': [], 'notes': []}
proc = None
SERVER_LOGS = {}


# ----------------------------------------------------------------------------
# 证据与判据记账
# ----------------------------------------------------------------------------
def cap(text, limit=BODY_CAP):
    text = text if isinstance(text, str) else repr(text)
    if len(text) <= limit:
        return text
    return text[:limit] + '\n…[截断 %d 字符]' % (len(text) - limit)


def ck(cid, name, ok, detail=None):
    rec = {'id': cid, 'name': name, 'pass': bool(ok), 'detail': detail}
    EV['checks'].append(rec)
    print(('PASS ' if ok else 'FAIL ') + cid + ' ' + name, flush=True)
    if not ok:
        print('      实测: ' + cap(json.dumps(detail, ensure_ascii=False), 1200), flush=True)
    return rec


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


# ----------------------------------------------------------------------------
# 夹具：离线手写 WAV（不调 ffmpeg、不用 lavfi）
# ----------------------------------------------------------------------------
def wav_write(path, fs, channels, samples, bits=16):
    """samples = 交错整数样本；只写 PCM 整型（16/8 bit）。"""
    assert bits in (16, 8), '本脚本只手写 16/8-bit PCM'
    if bits == 16:
        for v in samples:
            assert -32768 <= v <= 32767, v
        payload = struct.pack('<%dh' % len(samples), *samples)
    else:
        payload = bytes((v + 128) & 0xFF for v in samples)
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(channels)
        w.setsampwidth(bits // 8)
        w.setframerate(fs)
        w.writeframes(payload)
    return pathlib.Path(path)


def i16(x, amp=1.0):
    return max(-32768, min(32767, int(round(amp * 32767.0 * x))))


def sine(fs, secs, f, amp):
    n = int(round(fs * secs))
    return [i16(math.sin(2.0 * math.pi * f * i / fs), amp) for i in range(n)]


def lcg(seed):
    state = seed & 0x7FFFFFFF

    def nxt():
        nonlocal state
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        return state
    return nxt


def register_fixture(path, fs, channels, bits, frames, note):
    path = pathlib.Path(path)
    EV['fixtures'].append({
        'name': path.name, 'path': str(path), 'bytes': path.stat().st_size,
        'sha256': sha256_file(path), 'fs': fs, 'channels': channels, 'bits': bits,
        'frames': frames, 'duration_sec': round(frames / float(fs), 6) if fs else 0.0,
        'note': note,
    })


def build_fixtures():
    FIX.mkdir(parents=True, exist_ok=True)
    # ---- #14 队列夹具：8000 Hz 单声道，0.25 s，数字静音（只做队列语义，不出声）----
    for i in range(1, 17):
        p = wav_write(FIX / ('q%02d.wav' % i), 8000, 1, [0] * 2000)
        register_fixture(p, 8000, 1, 16, 2000, 'queue item #%d' % i)
    cue = wav_write(FIX / 'cue.wav', 8000, 1, sine(8000, 2.0, 100.0, 1.0 / 32768))
    register_fixture(cue, 8000, 1, 16, 16000, 'CUE 分轨源（2 s，覆盖 0-0.3 / 0.3-0.6 两个区间）')

    # ---- #16 满幅方波：997 Hz，1 s，末尾**停在同号削波段里**（证明 EOF 未闭合段要结算）----
    n = 44100
    sq = [32767 if math.sin(2.0 * math.pi * 997.0 * i / 44100) >= 0 else -32767 for i in range(n)]
    p = wav_write(FIX / 'square_fs_997.wav', 44100, 1, sq)
    register_fixture(p, 44100, 1, 16, n, '满幅方波 997 Hz / 1 s（全样本 |x|=32767，末段在 EOF 处未闭合）')

    # ---- #16 8 kHz：997 Hz 纯音（Nyquist=4 kHz，频带里没有 >10 kHz 的 bin）----
    p = wav_write(FIX / 'tone_8k_997.wav', 8000, 1, sine(8000, 2.0, 997.0, 0.5))
    register_fixture(p, 8000, 1, 16, 16000, '8 kHz 采样率 997 Hz 纯音（-6 dBFS）')

    # ---- #16 同相/反相 1 kHz 立体声 ----
    left = sine(44100, 2.0, 1000.0, 0.5)
    ip, ap = [], []
    for v in left:
        ip.extend((v, v))
        ap.extend((v, -v))
    p = wav_write(FIX / 'stereo_1k_inphase.wav', 44100, 2, ip)
    register_fixture(p, 44100, 2, 16, len(left), '1 kHz 立体声同相（L=R）：corr 应为 +1、单声道损失 0')
    p = wav_write(FIX / 'stereo_1k_antiphase.wav', 44100, 2, ap)
    register_fixture(p, 44100, 2, 16, len(left), '1 kHz 立体声反相（R=-L）：corr 应为 -1、单声道化后无能量')

    # ---- #16 等长 10 s：纯音 vs 5 s 纯音 + 5 s −90 dB 尾（±1 LSB 白噪声，峰值 −90.3 dBFS）----
    tone = sine(44100, 10.0, 997.0, 0.5)
    p = wav_write(FIX / 'tone10_997.wav', 44100, 1, tone)
    register_fixture(p, 44100, 1, 16, len(tone), '10 s 997 Hz 纯音（-6 dBFS）')
    rnd = lcg(20261030)
    tail = [1 if (rnd() >> 16) & 1 else -1 for _ in range(44100 * 5)]
    p = wav_write(FIX / 'tone5_tail90.wav', 44100, 1, tone[:44100 * 5] + tail)
    register_fixture(p, 44100, 1, 16, 44100 * 10,
                     '5 s 997 Hz 纯音 + 5 s −90 dB 尾（±1 LSB 白噪声，峰值/有效值 ≈ −90.3 dBFS）——与上一条等长')
    # 对照：同样的 10 s 结构与窗位置，但尾段是**数字零**。用来区分「红来自时长/窗位」还是
    # 「红来自近静音尾」——若静音尾通过而 −90 dB 尾失败，说明问题就在近静音窗口的处理上。
    p = wav_write(FIX / 'tone5_tail_silence.wav', 44100, 1, tone[:44100 * 5] + [0] * (44100 * 5))
    register_fixture(p, 44100, 1, 16, 44100 * 10,
                     '5 s 997 Hz 纯音 + 5 s 数字静音尾（对照组：同长度、同窗位置）')

    # ---- #16 6 ch 短样本 1024 / 2048 帧 ----
    for nf in (1024, 2048):
        frames = []
        for i in range(nf):
            v = i16(math.sin(2.0 * math.pi * 440.0 * i / 44100), 0.3)
            frames.extend((v, -v, v // 2, -(v // 2), v // 3, 0))
        p = wav_write(FIX / ('six_ch_%d.wav' % nf), 44100, 6, frames)
        register_fixture(p, 44100, 6, 16, nf, '6 ch 短样本 %d 帧（多声道 note 必须保留）' % nf)

    # ---- #17 合法短 WAV / 非法 WAV / 截断 WAV ----
    p = wav_write(FIX / 'short_ok.wav', 44100, 1, sine(44100, 0.2, 997.0, 0.3))
    register_fixture(p, 44100, 1, 16, 8820, '合法短 WAV（0.2 s），体检必须 usable=true')
    (FIX / 'illegal.wav').write_bytes(b'not a wave')
    register_fixture(FIX / 'illegal.wav', 0, 0, 0, 0, '非法 WAV（16 字节非 RIFF 垃圾），必须失败')
    full = FIX / 'full_tmp.wav'
    wav_write(full, 44100, 1, sine(44100, 1.0, 440.0, 0.5))
    data = full.read_bytes()
    (FIX / 'truncated.wav').write_bytes(data[:int(len(data) * 0.6)])   # 头声明满，数据只剩 60%
    full.unlink()
    register_fixture(FIX / 'truncated.wav', 44100, 1, 16, 26460, '截断 WAV（声明 44100 帧，实际约 60% 字节）')

    # ---- #17 截断 FLAC：先用 ffmpeg-lite 转码（唯一用 ffmpeg 的地方），再切掉一半 ----
    rnd = lcg(4242)
    noise = [max(-300, min(300, (rnd() % 601) - 300)) for _ in range(44100)]
    src = FIX / 'flac_source.wav'
    wav_write(src, 44100, 1, noise)
    flac = FIX / 'full.flac'
    rc, out, err = run_cli([str(FFMPEG), '-v', 'error', '-y', '-i', str(src), str(flac)], 'ffmpeg: wav->flac')
    if rc != 0 or not flac.exists():
        raise RuntimeError('ffmpeg-lite 转码失败（rc=%s）: %s' % (rc, err))
    blob = flac.read_bytes()
    (FIX / 'truncated.flac').write_bytes(blob[:len(blob) // 2])
    src.unlink()
    register_fixture(FIX / 'truncated.flac', 44100, 1, 16, 44100,
                     '截断 FLAC（ffmpeg-lite 转码后切一半，%d→%d 字节）' % (len(blob), len(blob) // 2))


# ----------------------------------------------------------------------------
# CLI / HTTP 记录器
# ----------------------------------------------------------------------------
def run_cli(argv, label):
    argv = [str(a) for a in argv]
    t0 = time.time()
    r = subprocess.run(argv, text=True, capture_output=True)
    rec = {'label': label, 'argv': argv, 'exit': r.returncode,
           'stdout': cap(r.stdout), 'stderr': cap(r.stderr),
           'ms': round((time.time() - t0) * 1000.0, 1)}
    EV['cli'].append(rec)
    return r.returncode, r.stdout, r.stderr


def http(path, body=None, method=None):
    """真 HTTP：GET（body=None）或 POST（body=dict/str/''）。原始响应全部入证据。"""
    data = None
    if body is not None:
        if isinstance(body, dict):
            data = urllib.parse.urlencode(body).encode()
        elif isinstance(body, bytes):
            data = body
        else:
            data = str(body).encode()
    req = urllib.request.Request(BASE + path, data=data, method=method or ('POST' if data is not None else 'GET'))
    if data is not None:
        req.add_header('Content-Type', 'application/x-www-form-urlencoded')
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            status, raw = r.status, r.read()
    except urllib.error.HTTPError as e:
        status, raw = e.code, e.read()
    text = raw.decode('utf-8', 'replace')
    try:
        parsed = json.loads(text)
    except ValueError:
        parsed = None
    EV['http'].append({'method': method or ('POST' if data is not None else 'GET'),
                       'path': cap(path, 600), 'request_body': cap(data.decode('utf-8', 'replace') if data else '', 2000),
                       'status': status, 'raw': cap(text), 'ms': round((time.time() - t0) * 1000.0, 1)})
    return status, parsed if parsed is not None else text


def queue_state():
    _, q = http('/api/queue')
    return q if isinstance(q, dict) else {}


def items_of(q):
    return list(q.get('items') or [])


def cues_of(q):
    return [list(c) for c in (q.get('cues') or [])]


def entries_of(q):
    """(path, cs, ce) 三元组序列 —— 队列项的完整身份（路径 + CUE 区间）。"""
    out = []
    for p, c in zip(items_of(q), cues_of(q)):
        out.append([p, round(float(c[0]), 6), round(float(c[1]), 6)])
    return out


# ----------------------------------------------------------------------------
# 服务进程：lsof 预检 / 属主核验 / SIGTERM（绝不 force kill）
# ----------------------------------------------------------------------------
def lsof_listener_pids(port):
    try:
        r = subprocess.run(['lsof', '-nP', '-iTCP:%d' % port, '-sTCP:LISTEN', '-t'],
                           text=True, capture_output=True)
    except FileNotFoundError:
        return None            # 没有 lsof：只用 bind 探测
    if r.returncode not in (0, 1):
        return None
    return [x for x in r.stdout.split() if x.strip()]


def refuse_if_port_busy():
    pids = lsof_listener_pids(PORT)
    if pids:
        print('REFUSE 端口 %d 已被占用（lsof pid=%s），本脚本不碰别人的进程/端口。' % (PORT, ','.join(pids)),
              flush=True)
        EV['notes'].append('port busy: %s' % pids)
        raise SystemExit(2)
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)   # 只放过 TIME_WAIT，不会抢占在听的进程
    try:
        s.bind(('127.0.0.1', PORT))
    except OSError as e:
        print('REFUSE 端口 %d 无法绑定（%s）。' % (PORT, e), flush=True)
        EV['notes'].append('port bind failed: %s' % e)
        raise SystemExit(2)
    finally:
        s.close()


def server_env():
    env = os.environ.copy()
    for key, leaf in (('HOME', 'home'), ('CFFIXED_USER_HOME', 'home'),
                      ('RLPLAYER_STATE_DIR', 'state'), ('RLPLAYER_LIBRARY_DIR', 'library'),
                      ('RLPLAYER_COVER_DIR', 'covers')):
        p = ROOT / 'env' / leaf
        p.mkdir(parents=True, exist_ok=True)
        env[key] = str(p)
    env.pop('RLPLAYER_STREAM_DECODE', None)
    return env


ENV = None


def start(tag):
    global proc
    so = open(ROOT / ('server-%s.stdout.log' % tag), 'ab', buffering=0)
    se = open(ROOT / ('server-%s.stderr.log' % tag), 'ab', buffering=0)
    SERVER_LOGS[tag] = (so, se)
    proc = subprocess.Popen([str(BINARY), '--port', str(PORT), '--no-browser', '--music-dir', str(MUSIC)],
                            env=ENV, cwd=str(ROOT), stdout=so, stderr=se)
    for _ in range(300):
        if proc.poll() is not None:
            raise RuntimeError('server exited early rc=%s' % proc.returncode)
        try:
            st, body = http('/api/ping')
            if st == 200 and isinstance(body, dict) and body.get('ok'):
                break
        except (OSError, urllib.error.URLError):
            pass
        time.sleep(0.1)
    else:
        raise RuntimeError('server start timed out')
    owners = lsof_listener_pids(PORT)
    if owners is not None:      # 串台检查：监听者必须就是我们 Popen 的那个 pid
        if owners != [str(proc.pid)]:
            raise RuntimeError('port %d listener pid %s != our child %s（拒绝串台）' % (PORT, owners, proc.pid))
        EV['ps_checks'].append({'event': 'listener-owner', 'port': PORT, 'pid': proc.pid, 'ok': True})


def stop():
    global proc
    if proc is None:
        return
    if proc.poll() is None:
        ps = subprocess.run(['ps', '-p', str(proc.pid), '-o', 'uid=,ppid=,comm='],
                            text=True, capture_output=True)
        line = ps.stdout.strip()
        fields = line.split(None, 2)
        owned = (len(fields) == 3 and int(fields[0]) == os.getuid()
                 and int(fields[1]) == os.getpid()
                 and pathlib.Path(fields[2]).name == BINARY.name)
        EV['ps_checks'].append({'event': 'before-term', 'pid': proc.pid, 'ps': line, 'owned': owned})
        if not owned:
            raise RuntimeError('owned server identity changed; no signal sent: %r' % line)
        proc.terminate()
        try:
            proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            raise RuntimeError('server did not exit on SIGTERM（禁止 force kill，交人工处理）')
        EV['ps_checks'].append({'event': 'exited', 'pid': proc.pid, 'rc': proc.returncode})
    proc = None
    for tag, handles in list(SERVER_LOGS.items()):
        for h in handles:
            h.close()
        SERVER_LOGS.pop(tag)


# ----------------------------------------------------------------------------
# #14 队列契约（真 HTTP）
# ----------------------------------------------------------------------------
def line_of(entry):
    """队列项 → 磁盘/协议同款一行文本：普通曲目 = 路径；CUE 分轨 = 路径<TAB>cs<TAB>ce。"""
    path, cs, ce = entry
    return path if (cs is None or cs < 0) else '%s\t%.6f\t%.6f' % (path, cs, ce)


def text_of(entries):
    return '\n'.join(line_of(e) for e in entries)


def set_queue(items):
    """items: [(path, cs, ce)]；cs<0 = 整首。返回 (status, json)。"""
    return http('/api/queue/set', {'files': text_of(items)})


def play(file, cs=None, ce=None, extra=None):
    body = {'file': file, 'backend': 'null', 'rate': '8000', 'bits': '16', 'volume': '-120'}
    if cs is not None:
        body['cue_start'] = '%.6f' % cs
        body['cue_end'] = '%.6f' % ce
    if extra:
        body.update(extra)
    return http('/api/play', body)


def check_iso():
    st, b = http('/api/settings')
    kv = (b or {}).get('kv') if isinstance(b, dict) else None
    kv = kv or {}
    ck('iso.1', '运行中的服务确认以 backend=null / volume=-120 / meta 全关 运行（不开设备、不联网）',
       st == 200 and kv.get('backend') == 'null' and kv.get('volume') == '-120'
       and kv.get('metaon') == '0' and kv.get('metallm') == '0',
       {'status': st, 'backend': kv.get('backend'), 'volume': kv.get('volume'),
        'metaon': kv.get('metaon'), 'metallm': kv.get('metallm')})


def check_14():
    q = [str(FIX / ('q%02d.wav' % i)) for i in range(1, 17)]
    cue = str(FIX / 'cue.wav')

    st, q0 = http('/api/queue')
    ck('14.0', '隔离实例启动后队列为空', st == 200 and isinstance(q0, dict) and items_of(q0) == [],
       {'status': st, 'items': items_of(q0)[:3]})

    st, r = set_queue([(p, -1, -1) for p in q[:15]])
    qa = queue_state()
    ck('14.1', '15 项队列整列写入且顺序一致',
       r.get('ok') and r.get('count') == 15 and items_of(qa) == q[:15],
       {'set': r, 'queue_len': len(items_of(qa)), 'order_ok': items_of(qa) == q[:15]})

    st, rp = play(q[15])
    qb = queue_state()
    ck('14.2', '队列外第 16 首：追加而不是覆盖，前 15 项保序',
       rp.get('ok') and rp.get('appended') is True and rp.get('count') == 16 and rp.get('index') == 15
       and items_of(qb) == q[:16],
       {'play': rp, 'queue_len': len(items_of(qb)), 'order_ok': items_of(qb) == q[:16]})

    st, rp2 = play(q[15])
    qc = queue_state()
    ck('14.3', '重复点同一首：定位而不是重复入队',
       rp2.get('ok') and rp2.get('appended') is False and rp2.get('count') == 16 and rp2.get('index') == 15
       and items_of(qc) == q[:16],
       {'play': rp2, 'queue_len': len(items_of(qc)), 'dup': len(items_of(qc)) - len(set(items_of(qc)))})

    st, rp3 = play(q[4])
    qd = queue_state()
    ck('14.4', '点队列内已有曲目：索引定位、条数不变',
       rp3.get('ok') and rp3.get('count') == 16 and rp3.get('index') == 4 and rp3.get('appended') is False,
       {'play': rp3, 'index': qd.get('index')})

    st, _ = http('/api/stop', '')
    st, r = set_queue([(cue, 0.0, 0.3), (cue, 0.3, 0.6)])
    qe = queue_state()
    ck('14.5', 'CUE 同 path 不同区间 = 两个不同队列项',
       r.get('ok') and r.get('count') == 2 and items_of(qe) == [cue, cue] and cues_of(qe) == [[0.0, 0.3], [0.3, 0.6]],
       {'set': r, 'items': items_of(qe), 'cues': cues_of(qe)})

    st, rp4 = play(cue, 0.3, 0.6)
    qf = queue_state()
    ck('14.6', '带区间点播已在队列里的 CUE 项：定位到第 2 项、不新增',
       rp4.get('ok') and rp4.get('count') == 2 and rp4.get('index') == 1 and rp4.get('appended') is False
       and cues_of(qf) == [[0.0, 0.3], [0.3, 0.6]],
       {'play': rp4, 'cues': cues_of(qf)})

    st, _ = http('/api/stop', '')
    st, r = set_queue([(p, -1, -1) for p in q[:3]])
    qg = queue_state()
    ck('14.7', '/api/queue/set 是显式整列替换（旧 2 项被替换掉）',
       r.get('ok') and r.get('count') == 3 and items_of(qg) == q[:3],
       {'set': r, 'items': items_of(qg)})

    # 随机 / 排序快照：每一步只认「项集合不丢、条数不变」。刻意把**同 path 不同 CUE 区间**
    # 的两项放进这 10 项里 —— 按路径去重的实现会在这里丢掉一项，纯路径夹具抓不到。
    mix = [(x, -1, -1) for x in q[:8]] + [(cue, 0.0, 0.3), (cue, 0.3, 0.6)]
    st, r = set_queue(mix)
    base = entries_of(queue_state())
    st, rs = http('/api/shuffle?on=1', '')
    qs = queue_state()
    shuffled = entries_of(qs)
    distinct_paths = len(set(x[0] for x in shuffled))
    ck('14.8', '随机模式：条数不变、项集合不变（含同 path 不同区间的两项）',
       rs.get('ok') and qs.get('shuffle') is True and len(shuffled) == 10
       and sorted(map(str, shuffled)) == sorted(map(str, base))
       and distinct_paths == 9,          # 夹具自检：按路径去重的实现只会剩 9 项
       {'shuffle': rs, 'len': len(shuffled), 'set_ok': sorted(map(str, shuffled)) == sorted(map(str, base)),
        'mode': qs.get('mode'), 'distinct_paths': distinct_paths, 'entries': shuffled,
        'teeth': '判据按 (path,cs,ce) 比；若实现按路径去重，这里只剩 9 项 → 立刻变红'})

    rev = list(reversed(shuffled))
    st, ro = http('/api/qorder', {'files': text_of(rev)})
    qo = entries_of(queue_state())
    ck('14.9', '随机模式下排序（qorder）：生成快照但不丢项（反序后逐项一致）',
       ro.get('ok') and qo == rev and sorted(map(str, qo)) == sorted(map(str, base)),
       {'qorder': ro, 'len': len(qo), 'order_ok': qo == rev})

    st, rdef = http('/api/qsort?by=default', '')
    qr = entries_of(queue_state())
    ck('14.10', '恢复默认顺序（qsort）：还原快照且一项不丢',
       rdef.get('ok') and len(qr) == 10 and sorted(map(str, qr)) == sorted(map(str, base)),
       {'qsort': rdef, 'len': len(qr), 'snapshot': qr})

    st, rso = http('/api/shuffle?on=0', '')
    qz = entries_of(queue_state())
    ck('14.11', '关随机：还原原始顺序、一项不丢',
       rso.get('ok') and qz == base,
       {'shuffle_off': rso, 'order_ok': qz == base, 'entries': qz})

    # 重启持久化：普通项 + CUE 项 + 索引 + 模式一起验
    st, _ = http('/api/stop', '')
    st, r = set_queue([(q[0], -1, -1), (q[1], -1, -1), (cue, 0.0, 0.3), (cue, 0.3, 0.6)])   # 普通项 + 同 path 两个区间
    play(q[1])
    http('/api/repeat', {'rate': '1'})
    before = queue_state()
    stop()
    start('restart')
    after = queue_state()
    ck('14.12', '重启后队列项、CUE 区间、索引与模式全部保留',
       entries_of(after) == entries_of(before) and after.get('index') == before.get('index')
       and after.get('mode') == before.get('mode') and after.get('mode') == 1,
       {'before': {'items': entries_of(before), 'index': before.get('index'), 'mode': before.get('mode')},
        'after': {'items': entries_of(after), 'index': after.get('index'), 'mode': after.get('mode')}})


# ----------------------------------------------------------------------------
# #16 音质统计边界（真 CLI：rtahealth --json）
# ----------------------------------------------------------------------------
def health_json(path):
    rc, out, err = run_cli([str(HEALTH), '--json', str(path)], 'rtahealth #16 %s' % pathlib.Path(path).name)
    rows = [json.loads(l) for l in out.splitlines() if l.startswith('{')]
    if rc != 0 or not rows:
        raise RuntimeError('rtahealth 失败 %s rc=%s err=%s' % (path, rc, err))
    return rows[0]


def expect_runs(samples):
    """按 quality.h 的口径独立重算：|x|/32768 >= 0.999、同号连续、>=3 才算一段、EOF 未闭合段也结算。"""
    runs, longest, cur, sign = 0, 0, 0, 0
    for v in samples:
        if abs(v) / 32768.0 >= CLIP_THRESHOLD:
            s = -1 if v < 0 else 1
            if sign != s:
                if cur >= CLIP_RUN_MIN:
                    runs += 1
                cur, sign = 0, s
            cur += 1
            longest = max(longest, cur)
        else:
            if cur >= CLIP_RUN_MIN:
                runs += 1
            cur, sign = 0, 0
    tail_open = cur >= CLIP_RUN_MIN          # 文件在削波段里结束 → 必须由 finalize 兜底结算
    if tail_open:
        runs += 1
    return {'runs': runs, 'longest': longest, 'tail_open': tail_open,
            'tail_len': cur, 'without_eof_flush': runs - (1 if tail_open else 0)}


def check_16():
    Q = {}

    # 16.1 满幅方波 + EOF 同号削波段
    sq_path = FIX / 'square_fs_997.wav'
    with wave.open(str(sq_path), 'rb') as w:
        raw = w.readframes(w.getnframes())
    samples = list(struct.unpack('<%dh' % (len(raw) // 2), raw))
    exp = expect_runs(samples)
    h = health_json(sq_path)
    Q['square_fs_997'] = h.get('quality')
    q = h['quality']
    ck('16.1', '满幅方波：削波段按同号切分，EOF 处未闭合的段也被结算',
       q['clipped_samples'] == sum(1 for v in samples if abs(v) / 32768.0 >= CLIP_THRESHOLD)
       and q['clipped_runs'] == exp['runs'] and q['longest_clip_run'] == exp['longest']
       and exp['tail_open'],
       {'reported': {'clipped_samples': q['clipped_samples'], 'clipped_runs': q['clipped_runs'],
                     'longest_clip_run': q['longest_clip_run'], 'clipped_pct': q['clipped_pct']},
        'expected': exp, 'eof_tail_len': exp['tail_len'], 'runs_if_no_eof_flush': exp['without_eof_flush']})

    # 16.2 8 kHz：频带里不存在 >10 kHz 的能量
    h = health_json(FIX / 'tone_8k_997.wav')
    Q['tone_8k_997'] = h.get('quality')
    q = h['quality']
    ck('16.2', '8 kHz 采样率：不报 >10 kHz 频带内容（hf_ratio 落到下限、重心/滚降在 4 kHz 内）',
       q['hf_ratio_10k_db'] <= -119.9 and 0.0 < q['centroid_hz'] <= 4000.0
       and 0.0 < q['rolloff95_hz'] <= 4000.0,
       {'hf_ratio_10k_db': q['hf_ratio_10k_db'], 'centroid_hz': q['centroid_hz'],
        'rolloff95_hz': q['rolloff95_hz'], 'fs': h.get('fs'), 'nyquist_hz': h.get('fs', 0) / 2.0})

    # 16.3 同相 / 反相 1 kHz 立体声
    hi = health_json(FIX / 'stereo_1k_inphase.wav')
    ha = health_json(FIX / 'stereo_1k_antiphase.wav')
    Q['stereo_1k_inphase'] = hi.get('quality')
    Q['stereo_1k_antiphase'] = ha.get('quality')
    qi, qa = hi['quality'], ha['quality']
    ck('16.3a', '同相/反相 1 kHz：声道相关系数分别为 +1 / −1',
       abs(qi['channel_corr'] - 1.0) <= 1e-3 and abs(qa['channel_corr'] + 1.0) <= 1e-3,
       {'inphase_corr': qi['channel_corr'], 'antiphase_corr': qa['channel_corr']})
    ck('16.3b', '同相/反相 1 kHz：单声道兼容损失 0 dB vs 上限（两值相反且可区分）',
       qi['mono_loss_db'] <= 0.1 and qa['mono_loss_db'] >= 100.0,
       {'inphase_mono_loss_db': qi['mono_loss_db'], 'antiphase_mono_loss_db': qa['mono_loss_db']})
    ck('16.3c', '同相/反相 1 kHz：side/mid 与「有没有 mid 分量」一致',
       qi['side_mid_db'] <= -100.0 and qa['side_mid_db'] >= 100.0,
       {'inphase_side_mid_db': qi['side_mid_db'], 'antiphase_side_mid_db': qa['side_mid_db'],
        'rule': '定义 = 10log10(side²/mid²)；反相时 mid=0 ⟹ 应为很大的正值，实测与同相一样是 −120',
        'antiphase_mono_loss_db': qa['mono_loss_db'],
        'impact': '该字段无法区分「没有 side」与「没有 mid」，两端都落在同一个下限哨兵 −120',
        'suggested_fix_in_production': 'monoPow==0 时按上限钳位（+120）或输出 null，与 mono_loss 的 120 上限同口径'})

    # 16.4 等长 10 s：纯音 vs 5 s 纯音 + 5 s −90 dB 尾
    h1 = health_json(FIX / 'tone10_997.wav')
    h2 = health_json(FIX / 'tone5_tail90.wav')
    Q['tone10_997'] = h1.get('quality')
    Q['tone5_tail90'] = h2.get('quality')
    a, b = h1['quality']['thdn_db'], h2['quality']['thdn_db']
    same_len = abs(h1['duration_sec'] - h2['duration_sec']) <= 1e-3
    tail_peak_dbfs = 20.0 * math.log10(1.0 / 32768.0)                 # ±1 LSB
    tail_rms_dbfs = 20.0 * math.log10(math.sqrt(1.0) / 32768.0)
    ck('16.4', '等长 10 s：纯音 vs 5 s 纯音 + 5 s −90 dB 尾，THD+N 差 <1 dB',
       same_len and h1['quality']['thdn_available'] and h2['quality']['thdn_available'] and abs(a - b) < 1.0,
       {'pure_thdn_db': a, 'tail_thdn_db': b, 'delta_db': round(abs(a - b), 3),
        'pure_duration': h1['duration_sec'], 'tail_duration': h2['duration_sec'],
        'pure_windows': h1['quality']['spectral_windows'], 'tail_windows': h2['quality']['spectral_windows'],
        'tail_fixture_peak_dbfs': round(tail_peak_dbfs, 3), 'tail_fixture_rms_dbfs': round(tail_rms_dbfs, 3),
        'file_peak_dbfs': h2['peak_dbfs'],
        'why': '8 个谱窗里 4 个落在尾段；thdn_db 取窗间中位数，被近静音窗的「残差/总能量≈1」拉到 0 dB'})

    # 16.4b 对照：同样 10 s、同样窗位置，尾段换成数字零 → 若这里绿而 16.4 红，
    # 说明缺陷定位在「近静音窗口参与 THD+N 中位数」，不是时长/分段口径本身有问题。
    h3 = health_json(FIX / 'tone5_tail_silence.wav')
    Q['tone5_tail_silence'] = h3.get('quality')
    c = h3['quality']['thdn_db']
    ck('16.4b', '对照：5 s 纯音 + 5 s 数字静音尾（同长度）THD+N 差 <1 dB',
       same_len and h3['quality']['thdn_available'] and abs(a - c) < 1.0,
       {'pure_thdn_db': a, 'silence_tail_thdn_db': c, 'delta_db': round(abs(a - c), 3),
        'silence_tail_duration': h3['duration_sec'],
        'why': '数字零窗 tot=0 被跳过；±1 LSB 尾窗 tot>0 参与中位数 —— 两种尾的差别就是缺陷所在'})

    # 16.5 6 ch 短样本 1024 / 2048 帧：多声道 note 必须保留
    n = {}
    for nf in (1024, 2048):
        h = health_json(FIX / ('six_ch_%d.wav' % nf))
        Q['six_ch_%d' % nf] = h.get('quality')
        n[nf] = h['quality']
    ck('16.5', '6 ch 1024/2048 帧：quality 可用、多声道 note 保留、立体声指标不适用',
       all(x['available'] and x['stereo'] is False
           and '多声道（6 ch）' in x['note'] and '立体声指标不适用' in x['note']
           and x['spectral_windows'] >= 1 for x in n.values()),
       {str(k): {'available': v['available'], 'stereo': v['stereo'], 'windows': v['spectral_windows'],
                 'note': v['note']} for k, v in n.items()})

    EV['quality'] = Q


# ----------------------------------------------------------------------------
# #17 体检错误契约（真 HTTP /api/track/health）
# ----------------------------------------------------------------------------
NULL_FIELDS = ('dr_db', 'lufs', 'lra', 'peak_dbfs', 'cutoff_hz', 'confidence')


def failure_ok(status, body, want_status, want_code=None):
    if not isinstance(body, dict):
        return False, {'body': cap(str(body), 400)}
    health = body.get('health') or {}
    quality = health.get('quality') or {}
    good = (status == want_status and body.get('ok') is False and body.get('usable') is False
            and health.get('status') == 'error'
            and all(health.get(f) is None for f in NULL_FIELDS)
            and quality.get('available') is False
            and isinstance(body.get('code'), str) and body['code'])
    if want_code:
        good = good and body.get('code') == want_code
    return good, {'status': status, 'code': body.get('code'), 'ok': body.get('ok'),
                  'usable': body.get('usable'), 'health_null': all(health.get(f) is None for f in NULL_FIELDS),
                  'quality_available': quality.get('available'), 'error': body.get('error')}


def check_17():
    st, b = http('/api/track/health?file=')
    ok, d = failure_ok(st, b, 400, 'decode.read_failed')
    ck('17.1', '空参数：400 + ok/usable=false + 指标 null', ok, d)

    st, b = http('/api/track/health?file=' + urllib.parse.quote(str(FIX / 'does-not-exist.wav')))
    ok, d = failure_ok(st, b, 404, 'library.path_missing')
    ck('17.2', '文件不存在：404 + 指标 null', ok, d)

    st, b = http('/api/track/health?file=' + urllib.parse.quote(str(FIX / 'illegal.wav')))
    ok, d = failure_ok(st, b, 422)
    ck('17.3', '非法 WAV：422 + usable=false + 指标 null（不许拿 0 冒充结果）', ok, d)

    st, b = http('/api/track/health?file=' + urllib.parse.quote(str(FIX / 'truncated.wav')))
    ok, d = failure_ok(st, b, 422)
    ck('17.4', '截断 WAV：422 + 指标 null', ok, d)

    st, b = http('/api/track/health?file=' + urllib.parse.quote(str(FIX / 'truncated.flac')))
    ok, d = failure_ok(st, b, 422)
    ck('17.5', '截断 FLAC（ffmpeg-lite 转码后切一半）：422 + 指标 null', ok, d)

    st, b = http('/api/track/health?file=' + urllib.parse.quote(str(FIX / 'short_ok.wav')))
    good = (isinstance(b, dict) and st == 200 and b.get('ok') is True and b.get('usable') is True
            and (b.get('health') or {}).get('status') == 'ready'
            and isinstance((b.get('health') or {}).get('lufs'), (int, float))
            and isinstance((b.get('health') or {}).get('quality', {}).get('thdn_db'), (int, float)))
    ck('17.6', '合法短 WAV（0.2 s）：200 + usable=true + 指标是真实数值', good,
       {'status': st, 'ok': (b or {}).get('ok'), 'usable': (b or {}).get('usable'),
        'health': {k: (b or {}).get('health', {}).get(k) for k in ('status', 'lufs', 'dr_db', 'peak_dbfs', 'duration_sec')}})


# ----------------------------------------------------------------------------
# #18 CLI 缓存（真 rtahealth --cache，进程间）
# ----------------------------------------------------------------------------
def one_health(argv, label):
    rc, out, err = run_cli(argv, label)
    rows = [json.loads(l) for l in out.splitlines() if l.startswith('{')]
    if rc != 0 or not rows:
        raise RuntimeError('rtahealth 失败 rc=%s err=%s' % (rc, err))
    return rows[0]


def check_18():
    work = ROOT / 'cachecase'
    work.mkdir(parents=True, exist_ok=True)
    wav = work / 'cache_tone.wav'
    tone = sine(44100, 3.0, 997.0, 0.4)
    wav_write(wav, 44100, 1, tone)
    register_fixture(wav, 44100, 1, 16, len(tone), '#18 缓存用例：3 s 997 Hz 纯音（会被中段改写）')
    cache = str(work / 'health-cache.json')
    if pathlib.Path(cache).exists():
        pathlib.Path(cache).unlink()

    a = one_health([str(HEALTH), '--json', '--cache', cache, str(wav)], '#18 首次（写缓存）')
    b = one_health([str(HEALTH), '--json', '--cache', cache, str(wav)], '#18 第二次（独立进程，应命中）')
    metric_keys = [k for k in a if k not in ('cached', 'analysis_ms')]
    same = all(a.get(k) == b.get(k) for k in metric_keys)
    ck('18.1', '进程间命中：cached=true 且全部指标逐字段精确保留',
       a.get('cached') is False and b.get('cached') is True and same
       and (a.get('quality') or {}) == (b.get('quality') or {}),
       {'first_cached': a.get('cached'), 'second_cached': b.get('cached'),
        'diff_keys': [k for k in metric_keys if a.get(k) != b.get(k)]})

    # 同大小 + mtime_ns 还原的中段改写：内容变了，缓存必须失效
    st0 = wav.stat()
    data = bytearray(wav.read_bytes())
    head = 44 + (len(data) - 44) // 2                     # 中段（跳过 44 字节头）
    seg = 44100 * 2                                        # 1 s = 88200 字节
    for i in range(seg):
        data[head + i] = 0x7F if (i // 2) % 2 else 0x80    # 中段 1 s 换成满幅方波，字节数不变
    wav.write_bytes(bytes(data))
    os.utime(wav, ns=(st0.st_atime_ns, st0.st_mtime_ns))
    st1 = wav.stat()
    same_size = st1.st_size == st0.st_size
    same_mtime = st1.st_mtime_ns == st0.st_mtime_ns
    try:
        cache_entry = {k: v for k, v in json.loads(pathlib.Path(cache).read_text())[0].items() if k != 'health'}
    except Exception as e:      # 缓存结构读不出来就如实记账，不影响判据
        cache_entry = {'read_error': str(e)}

    c = one_health([str(HEALTH), '--json', '--cache', cache, str(wav)], '#18 中段改写后（应失效重算）')
    d = one_health([str(HEALTH), '--json', '--cache', cache, '--force', str(wav)], '#18 --force 重算（真值）')
    # analyzed_at_ms 是「这次什么时候算的」墙钟时间戳（两次独立进程必然不同），不是指标；
    # 只有走缓存命中时它才必须与写缓存那次相同（18.1 已经用「含 analyzed_at_ms 的全字段相等」证明了）。
    keys = [k for k in c if k not in ('cached', 'analysis_ms', 'analyzed_at_ms')]
    ck('18.2', '同大小 + mtime_ns 还原的中段改写：缓存必须失效（cached=false）',
       same_size and same_mtime and c.get('cached') is False,
       {'size_same': same_size, 'mtime_ns_same': same_mtime,
        'ctime_changed': st1.st_ctime_ns != st0.st_ctime_ns, 'cached': c.get('cached'),
        'cache_entry_identity': {k: cache_entry.get(k) for k in ('mtime', 'size', 'ctime_ns', 'inode', 'dev')},
        'note': '强身份 = mtime/size/inode/dev/ctime_ns；mtime 被还原、size 相同，靠 inode+ctime_ns 判定内容变更'})
    ck('18.3', '失效后的重算与 --force 重算逐字段一致（不是把旧值贴回来）',
       all(c.get(k) == d.get(k) for k in keys) and d.get('cached') is False,
       {'diff_keys': [k for k in keys if c.get(k) != d.get(k)],
        'recomputed_peak_dbfs': c.get('peak_dbfs'), 'old_peak_dbfs': a.get('peak_dbfs'),
        'recomputed_lufs': c.get('lufs'), 'old_lufs': a.get('lufs')})
    ck('18.4', '改写确实改变了内容（峰值/响度与改写前不同，证明失效判据有意义）',
       abs(float(c.get('peak_dbfs', 0.0)) - float(a.get('peak_dbfs', 0.0))) > 0.5,
       {'old_peak_dbfs': a.get('peak_dbfs'), 'new_peak_dbfs': c.get('peak_dbfs'),
        'old_lufs': a.get('lufs'), 'new_lufs': c.get('lufs')})


# ----------------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------------
def resolve_ffmpeg():
    cands = []
    if ARGS.ffmpeg:
        cands.append(pathlib.Path(ARGS.ffmpeg))
    cands += [BINARY.parent / 'ffmpeg-lite' / 'ffmpeg', HEALTH.parent / 'ffmpeg-lite' / 'ffmpeg',
              pathlib.Path('/usr/local/bin/ffmpeg')]
    for c in cands:
        if c.exists() and os.access(str(c), os.X_OK):
            return c.resolve()
    return None


def write_results():
    """把证据写盘（正常结束 / 拒绝执行 / 致命异常三条路径共用，保证总有 results.json）。"""
    fails = [c for c in EV['checks'] if not c['pass']]
    fatal = bool(EV.get('fatal') or EV.get('fatal_stop'))
    EV['summary'] = {'total': len(EV['checks']), 'pass': len(EV['checks']) - len(fails),
                     'fail': len(fails), 'failed_ids': [c['id'] for c in fails],
                     'fatal': fatal, 'refused': bool(EV.get('refused')),
                     'exit': 1 if fatal else (2 if EV.get('refused') else (1 if fails else 0))}
    ROOT.mkdir(parents=True, exist_ok=True)
    (ROOT / 'results.json').write_text(json.dumps(EV, ensure_ascii=False, indent=2))


FFMPEG = None
BASE = 'http://127.0.0.1:%d' % PORT


def main():
    global ENV, FFMPEG
    ROOT.mkdir(parents=True, exist_ok=True)
    MUSIC.mkdir(parents=True, exist_ok=True)
    STATE.mkdir(parents=True, exist_ok=True)
    ENV = server_env()

    EV['environment'] = {
        'binary': {'path': str(BINARY), 'sha256': sha256_file(BINARY), 'bytes': BINARY.stat().st_size,
                   'mtime': time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime(BINARY.stat().st_mtime))},
        'health': {'path': str(HEALTH), 'sha256': sha256_file(HEALTH), 'bytes': HEALTH.stat().st_size,
                   'mtime': time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime(HEALTH.stat().st_mtime))},
        'os': '%s / %s' % (sys.platform, os.uname().machine),
        'python': sys.version.split()[0],
        'isolation': {'home': ENV['HOME'], 'cffixed_user_home': ENV['CFFIXED_USER_HOME'],
                      'state': ENV['RLPLAYER_STATE_DIR'], 'library': ENV['RLPLAYER_LIBRARY_DIR'],
                      'covers': ENV['RLPLAYER_COVER_DIR'], 'music': str(MUSIC),
                      'music_empty_before_start': not any(MUSIC.iterdir())},
    }
    # 服务端配置：全 backend=null、不开设备、不外网
    (STATE / 'rlplayer-settings.conf').write_text('backend=null\nmetaon=0\nmetallm=0\nvolume=-120\n')
    EV['environment']['isolation']['settings_conf'] = (STATE / 'rlplayer-settings.conf').read_text()

    FFMPEG = resolve_ffmpeg()
    if FFMPEG is None:
        raise RuntimeError('找不到 ffmpeg-lite（需要它把 wav 转成 flac 做截断 FLAC 夹具）')
    rc, out, _ = run_cli([str(FFMPEG), '-version'], 'ffmpeg-lite -version')
    EV['environment']['ffmpeg'] = {'path': str(FFMPEG), 'sha256': sha256_file(FFMPEG),
                                   'exit': rc, 'version_line': cap(out.splitlines()[0] if out else '')}

    refuse_if_port_busy()
    build_fixtures()

    try:
        start('main')
        check_iso()
        check_14()
        check_17()
        stop()
        check_16()
        check_18()
    except Exception as e:
        EV['fatal'] = '%s: %s' % (type(e).__name__, e)
        raise
    finally:
        try:
            stop()
        except Exception as e:
            EV['fatal_stop'] = '%s: %s' % (type(e).__name__, e)
            raise
        finally:
            # 证据：服务日志尾部 + 哈希
            EV['server_logs'] = {}
            for p in sorted(ROOT.glob('server-*.log')):
                EV['server_logs'][p.name] = {'bytes': p.stat().st_size, 'sha256': sha256_file(p),
                                             'tail': cap(p.read_text('utf-8', 'replace')[-1500:], 1500)}
            write_results()
            print('\nEVIDENCE %s' % ROOT, flush=True)
            label = ('致命异常（未完成）' if EV['summary']['fatal'] else
                     ('拒绝执行' if EV['summary']['refused'] else
                      ('失败: ' + ','.join(EV['summary']['failed_ids'])
                       if EV['summary']['failed_ids'] else '全绿')))
            print('SUMMARY pass=%d fail=%d exit=%d %s' %
                  (EV['summary']['pass'], EV['summary']['fail'], EV['summary']['exit'], label),
                  flush=True)
    return EV['summary']['exit']


if __name__ == '__main__':
    try:
        sys.exit(main())
    except SystemExit as e:     # 拒绝执行（端口被占等）也要留下证据
        if e.code not in (0, None):
            EV['refused'] = (e.code == 2)
            EV.setdefault('notes', []).append('refused/exited early rc=%s' % e.code)
            write_results()
        raise
    except Exception as e:      # 任何异常都要留下证据，而不是只打一行 traceback
        EV['fatal'] = '%s: %s' % (type(e).__name__, e)
        try:
            stop()
        except Exception as e2:
            EV['fatal_stop'] = '%s: %s' % (type(e2).__name__, e2)
        write_results()
        print('FATAL %s\nEVIDENCE %s' % (EV['fatal'], ROOT), flush=True)
        sys.exit(1)
