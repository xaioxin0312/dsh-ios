#!/usr/bin/env python3
"""Offline test against the pinned release archive; never install or run scripts."""
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import prepare_payload as stage

RELEASE_SHA = '1fd86988ee9371bf2890f8cf7c1812521fc158eb1333b16a62f33ac18014d215'


def sha(path):
    with path.open('rb') as f:
        digest = hashlib.sha256()
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            digest.update(chunk)
        return digest.hexdigest()


def main(archive):
    stage.require(sha(archive) == RELEASE_SHA, 'expected pinned upstream release archive')
    with tempfile.TemporaryDirectory(prefix='dsh-rh-verify-') as temp:
        parent = Path(temp)
        src, out = parent / 'input', parent / 'payload'
        subprocess.run(['dpkg-deb', '-R', str(archive), str(src)], check=True)
        stage.prepare(src, out)
        assert (out / 'usr/lib/dsh/bin/node-real').stat().st_mode & 0o111
        assert sha(out / 'usr/lib/dsh/bin/node-real') == stage.HASHES['usr/lib/dsh/bin/node']
        assert not (out / 'usr/lib/dsh/bin/node').exists()
        assert not (out / 'var/jb').exists()
        assert not any((out / n).exists() for n in stage.NATIVE)
        assert plistlib.loads((out / 'Applications/DSH.app/Info.plist').read_bytes())['CFBundleExecutable'] == 'DSHNativeApp'
        scripts = (*stage.SHELL_FILES, 'DEBIAN/postinst', 'DEBIAN/prerm')
        for name in scripts:
            subprocess.run(['sh', '-n', str(out / name)], check=True)
        for p, cmd in stage.LAUNCH.items():
            obj = plistlib.loads((out / p).read_bytes())
            assert obj['ProgramArguments'] == ['/usr/bin/' + cmd]
            assert obj['WorkingDirectory'] == '/rootfs/var/mobile'
        for name, target in stage.SOURCE_LINKS.items():
            assert os.readlink(out / 'usr/lib/dsh/node_modules/.bin' / name) == target
        for n, expected in stage.HASHES.items():
            assert sha(src / n if n.startswith('DEBIAN/') else src / 'var/jb' / n) == expected, n
        anchor = src / 'var/jb/usr/bin/dsh'
        anchor.write_bytes(anchor.read_bytes() + b'\n')
        bad = parent / 'bad'
        try:
            stage.prepare(src, bad)
        except ValueError as exc:
            assert 'hash mismatch: usr/bin/dsh' in str(exc), exc
        else:
            raise AssertionError('mutated input unexpectedly accepted')
        assert not bad.exists()
        assert sorted(p.name for p in parent.iterdir()) == ['input', 'payload']
        print(f'Stage verified: {len(scripts)} shell syntax checks, {len(stage.SOURCE_LINKS)} links, exact Node preservation and fail-closed mismatch.')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: verify_payload_stage.py PATH_TO_RELEASE_DEB')
    main(Path(sys.argv[1]).resolve(strict=True))
