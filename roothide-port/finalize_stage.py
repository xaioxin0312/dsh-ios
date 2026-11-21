#!/usr/bin/env python3
"""Finalize a generated Theos stage only; never install or launch its contents."""
import argparse
import os
import pathlib
import plistlib
import subprocess
import tempfile

from verify_package import BASE_ENTITLEMENTS


def run(*args):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def finalize(stage):
    stage = stage.resolve(strict=True)
    node = stage / 'usr/lib/dsh/bin/node-real'
    helper = stage / 'usr/bin/dsh-app-helper'
    if not node.is_file() or not helper.is_file():
        raise ValueError('Expected a prepared Theos stage with node-real and helper')
    if node.is_symlink() or helper.is_symlink():
        raise ValueError('Executable finalization targets must not be symlinks')
    before = plistlib.loads(run('ldid', '-e', str(node)))
    # Merge, rather than replace, upstream JIT and executable permissions.
    with tempfile.NamedTemporaryFile(prefix='dsh-base-entitlements-', suffix='.plist', dir=stage.parent) as stream:
        stream.write(plistlib.dumps({key: True for key in BASE_ENTITLEMENTS}))
        stream.flush()
        run('ldid', '-M', '-S' + stream.name, str(node))
    after = plistlib.loads(run('ldid', '-e', str(node)))
    for key, value in before.items():
        if after.get(key) != value:
            raise ValueError('Node entitlement was lost or changed: ' + key)
    for key in BASE_ENTITLEMENTS:
        if after.get(key) is not True:
            raise ValueError('Node is missing required roothide entitlement: ' + key)
    helper.chmod(0o4755)
    for root, dirs, files in os.walk(stage, followlinks=False):
        for name in files:
            p = pathlib.Path(root) / name
            if p.is_symlink():
                continue
            with p.open('rb') as file:
                prefix = file.read(256)
            if prefix.startswith(b'#!'):
                interpreter = prefix.split(b'\n', 1)[0][2:].strip().split()
                if interpreter:
                    shell = interpreter[-1].rsplit(b'/', 1)[-1]
                    if shell in (b'sh', b'bash'):
                        run(shell.decode('ascii'), '-n', str(p))
    print('Stage finalized: upstream Node permissions retained, roothide permissions merged, helper mode and shell syntax checked.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', type=pathlib.Path)
    args = parser.parse_args()
    finalize(args.stage)


if __name__ == '__main__':
    main()
