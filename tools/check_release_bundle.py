#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check an app bundle and decode synthetic fixtures. Never opens audio devices.

Usage: python3 tools/check_release_bundle.py path/to/RLPlayer.app --version 1.1.2
Requires macOS command-line tools and Python's standard library only.
"""
import argparse
import hashlib
import json
import os
import plistlib
import re
import struct
import subprocess
import tempfile
import wave
from pathlib import Path


def check_bundle(app, version):
    app = Path(app).resolve()
    mac = app / 'Contents/MacOS'
    res = app / 'Contents/Resources'
    checks = []

    def ck(ok, label, detail=''):
        checks.append({'ok': bool(ok), 'check': label, 'detail': str(detail)})
        print(('PASS ' if ok else 'FAIL ') + label + (' ' + str(detail) if detail else ''))
        if not ok:
            raise RuntimeError(label)

    def run(args):
        r = subprocess.run(list(map(str, args)), capture_output=True, text=True,
                           timeout=45, env=dict(os.environ, PATH='/usr/bin:/bin:/usr/sbin:/sbin'))
        ck(r.returncode == 0, 'command ' + str(args[0]), r.stderr[-200:] if r.returncode else '')
        return r.stdout

    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    ck(info['CFBundleShortVersionString'] == version, 'bundle version', info['CFBundleShortVersionString'])
    ck(info['CFBundleVersion'] == version, 'numeric build version', info['CFBundleVersion'])
    ck(info['LSMinimumSystemVersion'] == '13.0', 'minimum OS')
    ck('_raop._tcp' in info.get('NSBonjourServices', []), 'Bonjour declaration')
    for name in ['RLPlayer', 'ffmpeg', 'ffprobe', 'librtagpu.dylib', 'rtadiag']:
        f = mac / name
        ck(f.is_file(), 'bundle file ' + name)
        ck(run(['/usr/bin/lipo', '-archs', f]).strip() == 'arm64', 'arm64 ' + name)
        load = run(['/usr/bin/otool', '-l', f])
        ck(re.search(r'\bminos\s+13\.0\b', load) is not None, 'deployment target ' + name)
        deps = run(['/usr/bin/otool', '-L', f])
        ck('/usr/local/' not in deps and '/opt/homebrew/' not in deps, 'no Homebrew dylibs ' + name)
    ck(not (mac / 'rtaweb').exists(), 'no separate app server')
    for name in ['LICENSE', 'COPYRIGHT.md', 'OPRA-NOTICE.txt',
                 'third_party/ffmpeg/COPYING.LGPLv2.1', 'third_party/lame/COPYING']:
        ck((res / name).is_file(), 'notice ' + name)
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
    for name in ['ffmpeg', 'ffprobe']:
        ver = run([mac / name, '-version'])
        ck('8.1.2' in ver, 'packaged self-test ' + name)
        ck('--enable-gpl' not in ver and '--enable-nonfree' not in ver, 'FFmpeg license flags ' + name)
    ck(version in run([mac / 'rtadiag', '--help']), 'rtadiag version')

    with tempfile.TemporaryDirectory(prefix='rlplayer-release-smoke-') as td:
        d = Path(td)
        wav = d / 'source.wav'
        flac = d / 'roundtrip.flac'
        decoded = d / 'decoded.wav'
        samples = [-32768, -32767, -1000, -1, 0, 1, 1000, 32766, 32767] * 97
        pcm = struct.pack('<' + 'h' * len(samples), *samples)
        with wave.open(str(wav), 'wb') as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(44100)
            wf.writeframes(pcm)
        run([mac / 'ffmpeg', '-v', 'error', '-y', '-i', wav, '-c:a', 'flac', flac])
        run([mac / 'ffmpeg', '-v', 'error', '-y', '-i', flac, '-c:a', 'pcm_s16le', decoded])
        with wave.open(str(decoded), 'rb') as rf:
            got = rf.readframes(rf.getnframes())
        ck(got == pcm, 'packaged FLAC roundtrip exact', hashlib.sha256(got).hexdigest())
        # DSF stereo DSD64, per-channel blocks. Decoded to a file, never an audio output.
        dsf = d / 'fixture.dsf'
        block = 4096
        data = bytes([0x69]) * block + bytes([0x96]) * block
        fmt = b'fmt ' + struct.pack('<QIIIIIIQII', 52, 1, 0, 2, 2, 2822400, 1, block * 8, block, 0)
        total = 28 + len(fmt) + 12 + len(data)
        dsf.write_bytes(b'DSD ' + struct.pack('<QQQ', 28, total, 0) + fmt +
                        b'data' + struct.pack('<Q', 12 + len(data)) + data)
        probe = json.loads(run([mac / 'ffprobe', '-v', 'error', '-show_entries',
                                'stream=codec_name,sample_rate,channels', '-of', 'json', dsf]))
        ck(probe['streams'][0]['channels'] == 2, 'packaged DSD probe')
        run([mac / 'ffmpeg', '-v', 'error', '-i', dsf, '-c:a', 'pcm_s16le', '-f', 'wav', d / 'dsd-decoded.wav'])
        ck((d / 'dsd-decoded.wav').stat().st_size > 44, 'packaged DSD decode')
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app')
    parser.add_argument('--version', required=True)
    parser.add_argument('--output', help='Optional JSON report, outside the source tree when public')
    args = parser.parse_args()
    checks = check_bundle(args.app, args.version)
    if args.output:
        Path(args.output).write_text(json.dumps(checks, ensure_ascii=False, indent=2))
    print('Silent bundle validation complete:', len(checks), 'checks')


if __name__ == '__main__':
    main()
