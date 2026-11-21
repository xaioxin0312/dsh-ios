#!/usr/bin/env bash
# Build a candidate deb without executing its install scripts or touching a device.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
if [ "$(uname -s)" != Darwin ]; then
  echo 'Use the Dopamine-roothide GitHub workflow: native iOS compilation requires the configured macOS toolchain.' >&2
  exit 1
fi
: "${THEOS:?Set THEOS to the pinned roothide/theos checkout}"
for tool in python3 curl dpkg-deb ldid xcrun "${MAKE:-gmake}"; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
build="$root/build/roothide"
out="$build/output"
mkdir -p "$build/input" "$out"
read_pin() { python3 -c 'import json,sys; print(json.load(open("roothide-port/pinned-inputs.json"))[sys.argv[1]])' "$1"; }
asset_name="$(read_pin asset_name)"
expected="$(read_pin asset_sha256)"
input="${DSH_PORT_INPUT_DEB:-$build/input/$asset_name}"
if [ ! -f "$input" ]; then
  if [ -n "${DSH_PORT_INPUT_DEB:-}" ]; then
    echo "Specified source package does not exist: $input" >&2
    exit 1
  fi
  partial="$(mktemp "$build/input/download.XXXXXX")"
  curl --fail --location --retry 3 --connect-timeout 30 --max-time 600 \
    "$(read_pin asset_url)" --output "$partial"
  python3 - "$partial" "$expected" <<'PY'
import hashlib,pathlib,sys
p=pathlib.Path(sys.argv[1])
if hashlib.sha256(p.read_bytes()).hexdigest() != sys.argv[2]:
    raise SystemExit('Downloaded input package does not match the pinned digest')
PY
  mv "$partial" "$input"
fi
python3 - "$input" "$expected" <<'PY'
import hashlib,pathlib,sys
if hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest()!=sys.argv[2]:
    raise SystemExit('Source deb digest mismatch; preserving it without modification')
print('Pinned upstream deb checksum: PASS')
PY
work="$(mktemp -d "$build/work.XXXXXX")"
# Only remove this script's fresh workspace, under its known build root.
cleanup() {
  case "$work" in "$build"/work.*) rm -rf -- "$work" ;; *) echo 'Unexpected temporary path; preserving it.' >&2 ;; esac
}
trap cleanup EXIT

dpkg-deb -R "$input" "$work/input"
python3 roothide-port/prepare_payload.py "$work/input" "$work/payload"
number="${DSH_PORT_BUILD_NUMBER:-local}"
case "$number" in *[!0-9a-zA-Z.-]*|'') echo 'Invalid candidate build number' >&2; exit 1 ;; esac
version="0.2.2-rc.3+ios24.12+roothide1.$number"
export THEOS_PACKAGE_SCHEME=roothide
export THEOS_PLATFORM_DEB_COMPRESSION_TYPE=gzip
export THEOS_PACKAGE_DIR="$out"
export PACKAGE_VERSION="$version"
export DSH_ROOTHIDE_STAGE_HOOK="python3 $root/roothide-port/finalize_stage.py"
# Native build always replaces the original App/helper/control/HUD executables.
# A missing SDK or native build failure must fail, never reuse rootless prebuilts.
sh roothide-port/build-native.sh "$work/payload" "$work/stage" package
python3 - "$out" "$version" "$input" "$root" <<'PY'
import hashlib,json,pathlib,subprocess,sys
out,version,original,root=pathlib.Path(sys.argv[1]),sys.argv[2],sys.argv[3],pathlib.Path(sys.argv[4])
packages=list(out.glob('*_'+version+'_iphoneos-arm64e.deb'))
if len(packages)!=1:
    raise SystemExit(f'Expected one roothide candidate, found {len(packages)}')
package=packages[0]
report=out/'package-verification.json'
subprocess.run([sys.executable,str(root/'roothide-port/verify_package.py'),str(package),'--original',original,'--report',str(report)],check=True)
digest=hashlib.sha256(package.read_bytes()).hexdigest()
(package.with_name(package.name+'.sha256')).write_text(digest+'  '+package.name+'\n',encoding='utf-8')
manifest={
    'candidate_file':package.name,
    'candidate_sha256':digest,
    'port_commit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
    'inputs':json.loads((root/'roothide-port/pinned-inputs.json').read_text()),
    'static_package_verification_passed':True,
    'device_tested':False,
    'notice':'Experimental Dopamine-roothide candidate; iOS 16.6.1 runtime validation remains necessary.'
}
(out/'build-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print('Candidate packaged and statically verified:',package.name)
print('No device install, respring or runtime validation was performed.')
PY
