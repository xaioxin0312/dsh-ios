#!/usr/bin/env bash
# Host-only tests: no jailbreak service, installed device, or package script runs.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
python3 -m unittest discover -s roothide-port/tests -p 'test_*.py' -v
node --check roothide-port/roothide-node-preload.cjs
shopt -s nullglob
js_tests=(roothide-port/tests/*.test.cjs roothide-port/tests/*.test.mjs)
if [ "${#js_tests[@]}" -eq 0 ]; then
  echo 'Node path-boundary tests are required before building.' >&2
  exit 1
fi
node --test "${js_tests[@]}"
for script in roothide-port/build.sh roothide-port/build-native.sh; do
  bash -n "$script"
done
python3 - <<'PY'
import json, pathlib
pins = json.loads(pathlib.Path('roothide-port/pinned-inputs.json').read_text())
for key in ('theos_commit', 'sdk_commit', 'upstream_commit'):
    assert len(pins[key]) == 40 and all(c in '0123456789abcdef' for c in pins[key]), key
assert pins['sdk_directory'] == 'iPhoneOS16.5.sdk'
assert len(pins['asset_sha256']) == 64
print('Pinned inputs: PASS')
PY
