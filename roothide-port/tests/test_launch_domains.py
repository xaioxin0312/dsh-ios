#!/usr/bin/env python3
"""Capture launchctl argv offline; no installed service or maintainer action runs."""
import json
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import prepare_payload as stage

DOMAIN = 'user/foreground'
MAIN = 'dev.airdevs.dsh'
BRIDGE = MAIN + '.phone-bridge'
AGENT = MAIN + '.agent'
LABELS = {MAIN, BRIDGE, AGENT}
MOCK = '''import json, os, pathlib, sys
p = pathlib.Path(os.environ['CAPTURE'])
args = sys.argv[1:]
with p.open('a') as f: f.write(json.dumps(args) + '\\n')
state = pathlib.Path(os.environ['STATE'])
loaded = set(json.loads(state.read_text()))
verb = args[0]
if verb == 'print':
    if args[1] not in loaded: sys.exit(3)
    print('    pid = 1234')
elif verb == 'bootstrap':
    if os.environ.get('FAIL_BOOTSTRAP') == '1':
        print('fixture bootstrap failed', file=sys.stderr); sys.exit(5)
    label = pathlib.Path(args[2]).stem
    loaded.add(args[1] + '/' + label)
elif verb == 'bootout':
    if args[1] not in loaded: sys.exit(3)
    loaded.remove(args[1])
elif verb == 'kickstart':
    if args[-1] not in loaded: sys.exit(3)
else:
    print('unexpected launchctl command', args, file=sys.stderr); sys.exit(99)
state.write_text(json.dumps(sorted(loaded)))
'''


def capture(script, *, loaded=(), fail_bootstrap=False):
    with tempfile.TemporaryDirectory(prefix='dsh-launch-domain-') as tmp:
        root = Path(tmp)
        mock = root / 'mock.py'
        mock.write_text(MOCK)
        state = root / 'state.json'
        state.write_text(json.dumps([DOMAIN + '/' + name for name in loaded]))
        log = root / 'argv.jsonl'
        log.touch()
        wrapper = root / 'launchctl'
        wrapper.write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' ' + shlex.quote(str(mock)) + ' "$@"\n')
        wrapper.chmod(0o755)
        for label in LABELS:
            (root / (label + '.plist')).touch()
        env = dict(os.environ, CAPTURE=str(log), STATE=str(state), FIXTURE=str(root),
                   LC_FIXTURE=str(wrapper), FAIL_BOOTSTRAP='1' if fail_bootstrap else '0')
        prefix = 'launchctl() { "$LC_FIXTURE" "$@"; }\npgrep() { return 1; }; ps() { :; }\n'
        result = subprocess.run(['sh', '-c', prefix + script], env=env,
                                text=True, capture_output=True, timeout=10)
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        return result, calls, set(json.loads(state.read_text()))


def assert_domains(calls):
    assert calls, 'no launchctl calls captured'
    for args in calls:
        verb = args[0]
        if verb == 'bootstrap':
            assert len(args) == 3 and args[1] == DOMAIN, args
            assert Path(args[2]).stem in LABELS, args
        else:
            assert verb in ('print', 'bootout', 'kickstart'), args
            target = args[-1]
            assert target.startswith(DOMAIN + '/'), args
            assert target[len(DOMAIN) + 1:] in LABELS, args


def maintainer_script(contents):
    # Suppress filesystem effects and native existence checks in this harness
    # only. The actual launchctl loops/arguments are executed without edits.
    for line in ('[ -f /Applications/DSH.app/DSHNativeApp ]\n',
                 '[ -u /usr/bin/dsh-app-helper ]\n',
                 '[ -x /usr/lib/dsh/bin/node ]\n',
                 '[ -x /usr/lib/dsh/bin/node-real ]\n'):
        contents = contents.replace(line, '')
    return 'mkdir() { :; }; chown() { :; }; chmod() { :; }; uicache() { :; }\n' + contents


def verify_maintainers(postinst=stage.POSTINST, prerm=stage.PRERM):
    # Candidate 8 compatibility can already have loaded both jobs in foreground.
    other = 'org.example.unrelated'
    result, calls, state = capture('set -- configure;\n' + maintainer_script(postinst), loaded=LABELS | {other})
    assert result.returncode == 0, result.stderr
    assert_domains(calls)
    expected = [['bootout', DOMAIN + '/' + AGENT]]
    for label in (BRIDGE, MAIN):
        expected += [['bootout', DOMAIN + '/' + label],
                     ['bootstrap', DOMAIN, '/Library/LaunchDaemons/' + label + '.plist'],
                     ['kickstart', '-k', DOMAIN + '/' + label]]
    assert calls == expected, calls
    assert state == {DOMAIN + '/' + label for label in (MAIN, BRIDGE, other)}, state
    for action in ('remove', 'deconfigure'):
        result, calls, state = capture('set -- ' + action + ';\n' + maintainer_script(prerm), loaded=LABELS)
        assert result.returncode == 0, result.stderr
        assert_domains(calls)
        assert state == set(), state
    result, calls, state = capture('set -- upgrade;\n' + maintainer_script(prerm), loaded=LABELS)
    assert result.returncode == 0 and not calls
    result, calls, _ = capture('set -- configure;\n' + maintainer_script(postinst), fail_bootstrap=True)
    assert result.returncode != 0 and 'fixture bootstrap failed' in result.stderr
    assert not any(args[0] == 'kickstart' for args in calls)


def definitions(file):
    text = file.read_text()
    marker = '\ncase "${1:-status}" in'
    assert text.count(marker) == 1, file
    return text.split(marker)[0]


def verify_launch_domains(payload):
    verify_maintainers((payload / 'DEBIAN/postinst').read_text(), (payload / 'DEBIAN/prerm').read_text())
    for name, label in (('dsh-app-ctl', MAIN), ('dsh-phone-bridge-ctl', BRIDGE)):
        prefix = definitions(payload / 'usr/bin' / name)
        configure = '\nLC="$LC_FIXTURE"; PLIST="$FIXTURE/' + label + '.plist"\n'
        for loaded in ((), (label,)):
            result, calls, state = capture(prefix + configure + 'do_bootstrap\n', loaded=loaded)
            assert result.returncode == 0, result.stderr
            assert_domains(calls)
            assert sum(args[0] == 'bootstrap' for args in calls) == (not loaded), calls
            assert DOMAIN + '/' + label in state
        result, calls, _ = capture(prefix + configure + 'do_bootstrap\n', fail_bootstrap=True)
        assert result.returncode != 0 and 'fixture bootstrap failed' in result.stderr
        for loaded in ((), (label,)):
            result, calls, state = capture(prefix + configure + 'do_bootout\n', loaded=loaded)
            assert result.returncode == 0, result.stderr
            assert_domains(calls)
            assert not state
        pid_function = 'daemon_pid' if name == 'dsh-app-ctl' else 'bridge_pid'
        result, calls, _ = capture(prefix + configure + pid_function, loaded=(label,))
        assert result.returncode == 0 and result.stdout.strip() == '1234', (result.stdout, result.stderr)
        assert_domains(calls)
    prefix = definitions(payload / 'usr/bin/dsh-autostart')
    configure = '\nLC="$LC_FIXTURE"; PL="$FIXTURE/' + MAIN + '.plist"; AG="$FIXTURE/' + AGENT + '.plist"; LOGDIR="$FIXTURE/log"\nprobe() { return 0; }; chown() { :; }; chmod() { :; }\n'
    result, calls, state = capture(prefix + configure + 'cmd_repair; cmd_status\n', loaded=LABELS)
    assert result.returncode == 0, result.stderr
    assert_domains(calls)
    assert {DOMAIN + '/' + MAIN, DOMAIN + '/' + AGENT}.issubset(state)
    assert any(args == ['print', DOMAIN + '/' + AGENT] for args in calls), calls
    assert sum(args[0] == 'bootstrap' for args in calls) == 2, calls
    result, calls, _ = capture(prefix + configure + 'cmd_repair\n', fail_bootstrap=True)
    assert result.returncode != 0 and 'fixture bootstrap failed' in result.stderr
    assert not any(args[0] == 'kickstart' for args in calls), calls
    for name in stage.LAUNCH:
        config = plistlib.loads((payload / name).read_bytes())
        assert all(key not in config for key in ('UserName', 'GroupName', 'LimitLoadToSessionType')), name
    print('Launch domains verified: captured postinst/prerm, both controllers and autostart; loaded/absent/failure paths.')


class LaunchDomainsTests(unittest.TestCase):
    def test_generated_maintainer_arguments(self):
        verify_maintainers()

    def test_control_functions_have_explicit_domains(self):
        result, calls, state = capture('LABEL=' + MAIN + '\nPLIST="$FIXTURE/' + MAIN + '.plist"\nLC="$LC_FIXTURE"\n' +
                                       stage.CONTROL_LAUNCH_FUNCTIONS + '\ndo_bootstrap; do_bootout\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        assert_domains(calls)
        self.assertFalse(state)


if __name__ == '__main__':
    unittest.main()
