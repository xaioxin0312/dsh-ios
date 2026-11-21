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
# Exercise the actual endpoint builder and startup gate on the Apple host.
# These are host regressions, not a claim of iOS device runtime validation.
if [ "$(uname -s)" = Darwin ]; then
  mkdir -p build/roothide/host-tests
  xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror \
    -Iapp-bundle/native-ui -framework Foundation \
    app-bundle/native-ui/DSHRHWebEndpoint.m roothide-port/tests/test_web_endpoint.m \
    -o build/roothide/host-tests/web-endpoint
  build/roothide/host-tests/web-endpoint
  xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror \
    -Iapp-bundle/native-ui roothide-port/tests/test_startup_state.c \
    -o build/roothide/host-tests/startup-state
  build/roothide/host-tests/startup-state
fi
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
