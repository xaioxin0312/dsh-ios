#!/usr/bin/env python3
"""Stage the pinned ios24.12 deb's extracted tree for Theos roothide."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import tempfile

NATIVE = ('Applications/DSH.app/DSHLauncher', 'Applications/DSH.app/DSHNativeApp',
          'usr/bin/dsh-app-helper', 'usr/bin/mcp-logreader',
          'Library/MobileSubstrate/DynamicLibraries/dsh-ios-control.dylib',
          'Library/MobileSubstrate/DynamicLibraries/dsh-ios-hud.dylib')
SCRIPTS = ('dsh', 'dsh-app-ctl', 'dsh-app-ui', 'dsh-autostart', 'dsh-autostart-agent',
           'dsh-compat', 'dsh-daemon', 'dsh-doctor', 'dsh-phone-bridge-ctl',
           'dsh-phone-bridge-daemon', 'pnpm')
LAUNCH = {'Library/LaunchDaemons/dev.airdevs.dsh.plist': 'dsh-daemon',
          'Library/LaunchDaemons/dev.airdevs.dsh.phone-bridge.plist': 'dsh-phone-bridge-daemon',
          'Library/LaunchAgents/dev.airdevs.dsh.agent.plist': 'dsh-autostart-agent'}
EXTRAS = ('dsh-extras-postinst.sh', 'dsh-extras-prerm.sh')
SHELL_FILES = tuple('usr/bin/' + n for n in SCRIPTS) + ('usr/lib/dsh/node-safe', 'usr/lib/dsh/tier.sh')
HASHES = {
    'usr/bin/dsh': 'c2bed15593312eaf3d4455e8b96b4ce0dc21f5dbe23505152eac8ff6672c4296',
    'usr/bin/dsh-app-ctl': '8113a81d9131ce5ef4f87a2bf17ec4cc8aa5fb568d61bad9deb45b294592207a',
    'usr/bin/dsh-app-ui': 'd358a282e78f912d72eac9a035957cab63747fb8192d47da9714e7548db0bf9f',
    'usr/bin/dsh-autostart': '7ea36cd59118aced231aaa19d91b732f2a91d03c99a1399295007b9811a9fea2',
    'usr/bin/dsh-autostart-agent': '0b6b5e0e9183589d5f1af75b26a06be3a2f3e4759a8f7b4d8931da6efaa6b580',
    'usr/bin/dsh-compat': '06761ed867c4bf96115121bae4d8d9ad3d874cc0ab3811df4e6b4a88a2f5406c',
    'usr/bin/dsh-daemon': '83e44db5990af6c53df300e9d1765f9873319ab1c36194835d707a65820efd84',
    'usr/bin/dsh-doctor': '6c95a02a2abd4ded44a9790158f2176f0a41a25dbe6a3c2f9f460c1ff6d8e70d',
    'usr/bin/dsh-phone-bridge-ctl': 'c9ceb79758337af81d0e3f6e387d1e55c8ea0b8df8f2602f61d581d46b02a05c',
    'usr/bin/dsh-phone-bridge-daemon': '3167170d9249c984e5f5cbfe6a25bf4911175e812f40b83a4da1980043eee26d',
    'usr/bin/pnpm': 'cd9fd6085742c7e3cb7742195508e637471a35ad9a5c440a09520279c2b143eb',
    'usr/lib/dsh/node-safe': '3c66ce6c5ddfe3b0916e33f54e77baf0e13094dc8851d00d41b6347608bed4ea',
    'usr/lib/dsh/tier.sh': '6c898b55a34d61f21052d76037408d50508afcce860006ea199a42f7898c7bbf',
    'usr/lib/dsh/dsh-extras-postinst.sh': 'f16394d3a996ddf1c1c30b1c032cf163f9d49bf552e8110587039f60a78f4650',
    'usr/lib/dsh/dsh-extras-prerm.sh': '6db087fceb1402061c5e7a5bb360d71ad99161c3ffd3d9c47ad97bc261342d46',
    'Library/LaunchDaemons/dev.airdevs.dsh.plist': '9aadd5b6d14d3d3460bec56de1974b89d1af5db593dfd7d7b56c2697ffd91f3f',
    'Library/LaunchDaemons/dev.airdevs.dsh.phone-bridge.plist': '81402b888dd083d152104a1bd4abe0c905bfc9b73e53808551a32026894864af',
    'Library/LaunchAgents/dev.airdevs.dsh.agent.plist': '263838d9a1c2a065d165f52e64ff40d441ee34829828b0b8120bb87ee3f1d318',
    'Applications/DSH.app/Info.plist': 'b731a60a47b8e3ddac3fb45f3a90ebfb115e68b124414980b9eb55de4ecde4c2',
    'Applications/DSH.app/DSHLauncher': '1bb8bdd6b5a65e29f63f8ad26dd6aa4eaf0bc2ccc0a3368b91545f94e3f62ec9',
    'Applications/DSH.app/DSHNativeApp': '43bb13d19d3559ecb78e5bc210e9ee6b58d16abb2a5ab5cc0b738a386e2f75cb',
    'usr/bin/dsh-app-helper': '235443a624cf6c2a34d851d566bf871cf8baf38ae37b63ace0ba372825c4ba09',
    'usr/bin/mcp-logreader': 'b6649de89eefb1f7cae98c1a5a8158832471b65642ac8fd5f546920970c09269',
    'Library/MobileSubstrate/DynamicLibraries/dsh-ios-control.dylib': 'c1b83cc05e93beb29d98a9a1d9fbe536295b615ea2158b978d298dbfa9ae4ebc',
    'Library/MobileSubstrate/DynamicLibraries/dsh-ios-hud.dylib': '5d28e855dd80b19edc4f1a1244ee2201ebbe05d9eeaf4ed1b6793a90ff1463b5',
    'usr/lib/dsh/bin/node': '8bebb2a2e45824f9880ac99141ce0ee9359ec4fad72ccd1ef27bcd1341d77697',
    'DEBIAN/control': 'a05371b273cec6fa1ab8f243c9fdc92ad7717f70809f08a74bbfaaa5d347b253',
    'DEBIAN/postinst': '59c2bc88dcc5324ef3c67d50243629d52a01a739331fefc8e9ee77427bbdd56a',
    'DEBIAN/prerm': 'f5d60b70199d9d183d98da79f53d634f05ee31ab40f8c3f7c63e7b2709c220fa',
}

POSTINST = '''#!/bin/sh
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
[ "${1:-configure}" = configure ] || exit 0
mkdir -p /var/log/dsh-app /rootfs/var/mobile/Library/DSH
chown 501:501 /var/log/dsh-app /rootfs/var/mobile/Library/DSH
chmod 755 /var/log/dsh-app /rootfs/var/mobile/Library/DSH
[ -f /Applications/DSH.app/DSHNativeApp ]
[ -u /usr/bin/dsh-app-helper ]
[ -x /usr/lib/dsh/bin/node ]
[ -x /usr/lib/dsh/bin/node-real ]
for label in dev.airdevs.dsh.phone-bridge dev.airdevs.dsh; do
    launchctl bootout "system/$label" >/dev/null 2>&1 || :
    if ! launchctl bootstrap system "/Library/LaunchDaemons/$label.plist"; then
        launchctl load "/Library/LaunchDaemons/$label.plist"
    fi
    launchctl kickstart -k "system/$label"
done
uicache -p /Applications/DSH.app
'''
PRERM = '''#!/bin/sh
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
case "${1:-remove}" in
    remove|deconfigure) ;;
    *) exit 0 ;;
esac
for domain in gui/501 user/501; do
    launchctl bootout "$domain/dev.airdevs.dsh.agent" >/dev/null 2>&1 || :
done
for label in dev.airdevs.dsh dev.airdevs.dsh.phone-bridge; do
    launchctl bootout "system/$label" >/dev/null 2>&1 || :
done
uicache -u /Applications/DSH.app || :
'''


def require(condition, description):
    if not condition:
        raise ValueError(description)


def anchored(text, old, new, count=1):
    require(text.count(old) == count, f'unexpected anchor count: {old!r}')
    return text.replace(old, new)


def regular(path):
    require(stat.S_ISREG(path.lstat().st_mode), f'expected regular file: {path}')
    return path


def directory(path):
    require(stat.S_ISDIR(path.lstat().st_mode), f'expected directory: {path}')
    return path


SOURCE_LINKS = dict(line.split(' ', 1) for line in '''acorn ../acorn/bin/acorn
anthropic-ai-sdk ../@anthropic-ai/sdk/bin/cli
cordis ../@deepseek-ai/cordis/bin.js
dsh ../@deepseek-ai/dsh/lib/bin.js
dsoffice ../@deepseek-ai/libreoffice-kit/lib/cli.js
is-docker ../is-docker/cli.js
is-inside-container ../is-inside-container/cli.js
js-yaml ../js-yaml/bin/js-yaml.js
node-which ../which/bin/node-which
pi-ai ../@earendil-works/pi-ai/dist/cli.js
semver ../semver/bin/semver.js
which-command ../which-command/cli.js
yaml ../yaml/bin.mjs'''.splitlines())


def validate_tree(source):
    bindir = source / 'var/jb/usr/lib/dsh/node_modules/.bin'
    seen = set()
    for base, dirs, files in os.walk(source, followlinks=False):
        for name in dirs:
            directory(Path(base, name))
        for name in files:
            p = Path(base, name)
            if p.is_symlink():
                require(p.parent == bindir and os.readlink(p) == SOURCE_LINKS.get(name),
                        f'unexpected link: {p}')
                seen.add(name)
            else:
                regular(p)
    require(seen == SOURCE_LINKS.keys(), 'missing release node_modules/.bin links')


def shell_transform(name, text):
    if name == 'usr/bin/dsh':
        text = anchored(text, 'if [ ! -L "$JB" ] || [ ! -x "$NODE" ] || [ ! -f "$BIN" ]; then',
                        'if [ ! -x "$NODE" ] || [ ! -f "$BIN" ]; then')
        # Drop automatic home healing: it can rewrite an existing configuration.
        start = text.index('# 2a) +ios12：')
        end = text.index('# 2b) +ios13')
        text = text[:start] + '# Phone bridge registration is explicit: dsh-phone-bridge-ctl config-on\n\n' + text[end:]
    if name == 'usr/bin/dsh-doctor':
        start = text.index('if [ -L "$JB" ] && [ -d "$JB/usr" ]; then')
        end = text.index('\nfi', start) + 3
        text = text[:start] + '''if [ -d /usr/lib/dsh ] && command -v jbroot >/dev/null 2>&1; then
    ok "roothide bootstrap: $(jbroot /)"
else
    bad "roothide bootstrap unavailable" "Activate Dopamine-roothide"
fi''' + text[end:]
        text = anchored(text, 'NS=$(wc -c < "$NODE"', 'INSPECT_NODE="${DSH_NODE:-$D/bin/node-real}"\nNS=$(wc -c < "$INSPECT_NODE"')
        text = anchored(text, 'ldid -e "$NODE"', 'ldid -e "$INSPECT_NODE"')
        text = anchored(text, 'strings "$NODE"', 'strings "$INSPECT_NODE"')
    if name == 'usr/bin/dsh-phone-bridge-ctl':
        text = anchored(text, 'HUDJSON="/var/mobile/Library/DSH/hud.json"', 'HUDJSON="/rootfs/var/mobile/Library/DSH/hud.json"')
        text = anchored(text, 'ACK="/var/mobile/Library/DSH/hud.ack.json"', 'ACK="/rootfs/var/mobile/Library/DSH/hud.ack.json"')
    text = re.sub(r'^JB=/var/jb$', 'JB=', text, flags=re.M)
    text = text.replace('$JB/usr/bin:$JB/bin:/usr/bin:/bin:/usr/sbin:/sbin', '/usr/bin:/bin:/usr/sbin:/sbin')
    # Applied only to exact input hashes and these named bootstrap files, not JS.
    text = re.sub(r'/var/jb(?=/)', '', text)
    text = text.replace('${HOME:-/var/mobile}', '${HOME:-/rootfs/var/mobile}')
    return text


def launch_transform(file, command):
    config = plistlib.loads(file.read_bytes())
    require(config.get('ProgramArguments') == ['/var/jb/usr/bin/' + command], str(file))
    config['ProgramArguments'] = ['/usr/bin/' + command]
    for key in ('StandardErrorPath', 'StandardOutPath'):
        old = config[key]
        require(old.startswith('/var/jb/var/log/dsh-app/'), f'{file}: {key}')
        config[key] = old.removeprefix('/var/jb')
    require(config.get('WorkingDirectory') == '/var/mobile', f'{file}: WorkingDirectory')
    config['WorkingDirectory'] = '/rootfs/var/mobile'
    env = config.get('EnvironmentVariables', {})
    for key, value in env.items():
        if value.startswith('/var/jb/'):
            if key == 'PATH':
                env[key] = '/usr/bin:/bin:/usr/sbin:/sbin'
            else:
                env[key] = value.removeprefix('/var/jb')
        elif key == 'HOME':
            require(value == '/var/mobile', f'{file}: HOME')
            env[key] = '/rootfs/var/mobile'
    file.write_bytes(plistlib.dumps(config, sort_keys=False))


def prepare(source, destination):
    source = directory(source.absolute()).resolve()
    parent = directory(destination.absolute().parent).resolve()
    destination = parent / destination.name
    require(not os.path.lexists(destination) and destination != source and source not in destination.parents,
            'output must not exist or be inside input')
    require({p.name for p in source.iterdir()} == {'var', 'DEBIAN'}, 'unexpected extracted root entries')
    require({p.name for p in directory(source / 'var').iterdir()} == {'jb'}, 'unexpected var contents')
    logical = directory(source / 'var/jb')
    validate_tree(source)
    for name, expected in HASHES.items():
        f = source / name if name.startswith('DEBIAN/') else logical / name
        require(hashlib.sha256(regular(f).read_bytes()).hexdigest() == expected,
                f'release anchor hash mismatch: {name}')
    with tempfile.TemporaryDirectory(prefix='.dsh-roothide-stage-', dir=parent) as tmp:
        stage = Path(tmp) / 'payload'
        shutil.copytree(logical, stage, symlinks=True)
        for name in NATIVE:
            regular(stage / name).unlink()
        for name in EXTRAS:
            regular(stage / 'usr/lib/dsh' / name).unlink()
        node = regular(stage / 'usr/lib/dsh/bin/node')
        require(not os.path.lexists(node.with_name('node-real')), 'node-real already exists')
        node.rename(node.with_name('node-real'))
        for name in SHELL_FILES:
            f = regular(stage / name)
            f.write_bytes(shell_transform(name, f.read_text(encoding='utf-8')).encode('utf-8'))
            if name != 'usr/lib/dsh/tier.sh':
                f.chmod(0o755)
        for name, command in LAUNCH.items():
            launch_transform(stage / name, command)
        info = stage / 'Applications/DSH.app/Info.plist'
        config = plistlib.loads(info.read_bytes())
        require(config.get('CFBundleExecutable') in ('DSHLauncher', 'DSHNativeApp'), 'unexpected app executable')
        config['CFBundleExecutable'] = 'DSHNativeApp'
        info.write_bytes(plistlib.dumps(config, sort_keys=False))
        preload = stage / 'usr/lib/dsh/roothide-node-preload.cjs'
        with preload.open('xb') as f:
            f.write(Path(__file__).with_name(preload.name).read_bytes())
        preload.chmod(0o644)
        control_dir = stage / 'DEBIAN'
        control_dir.mkdir()
        control = regular(source / 'DEBIAN/control').read_text(encoding='utf-8')
        control = anchored(control, 'Architecture: iphoneos-arm64\n', 'Architecture: iphoneos-arm64e\n')
        control = control.split('Description: ', 1)[0] + (
            'Description: DeepSeek Harness for Dopamine-roothide\n'
            ' Native app, Node.js 24 runtime, pnpm, background services and phone bridge.\n'
            'Homepage: https://github.com/xaioxin0312/dsh-ios\n')
        (control_dir / 'control').write_bytes(control.encode('utf-8'))
        for name, contents in (('postinst', POSTINST), ('prerm', PRERM)):
            f = control_dir / name
            f.write_bytes(contents.encode('utf-8'))
            f.chmod(0o755)
        require(not os.path.lexists(destination), f'output appeared during staging: {destination}')
        stage.rename(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input_extracted_root', type=Path)
    parser.add_argument('output_logical_payload', type=Path)
    args = parser.parse_args()
    try:
        prepare(args.input_extracted_root, args.output_logical_payload)
    except (OSError, ValueError) as exc:
        parser.exit(1, f'prepare_payload: {exc}\n')


if __name__ == '__main__':
    main()
