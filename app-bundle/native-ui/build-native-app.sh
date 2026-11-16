#!/bin/sh
# build-native-app.sh — 编译原生 UIKit App 的可执行文件（+ios24.10 起，主界面即实时进度）。
#
# 必须带 iPhoneOS SDK：本机 Linux 无 SDK 时会明确失败，产物应通过
# .github/workflows/build-native-app.yml（macos-15 + Xcode）编译后回填到
# app-bundle/prebuilt/DSHNativeApp。
#
# 无 Apple 证书：产出 Mach-O 后用 ldid -S 伪签名（rootless 越狱标准做法）。
# Info.plist 用 -sectcreate 内嵌，让系统把它当真正的 App 加载。
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APPB=$(CDPATH= cd -- "$HERE/.." && pwd)
REPO=$(CDPATH= cd -- "$APPB/.." && pwd)
OUT=${1:-"$HERE/DSHNativeApp"}
PLIST="$APPB/payload/var/jb/Applications/DSH.app/Info.plist"

SDK="${IOS_SDK:-}"
if [ -z "$SDK" ] && command -v xcrun >/dev/null 2>&1; then
    SDK=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)
fi
if [ -z "$SDK" ] && [ -d /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs ]; then
    SDK=$(ls -d /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS*.sdk 2>/dev/null | tail -1)
fi
if [ -z "$SDK" ] || [ ! -d "$SDK" ]; then
    echo "FATAL: 未找到 iPhoneOS SDK；请用 GitHub Actions macos-15 编译" >&2
    exit 2
fi

CC="${CC:-}"
if [ -z "$CC" ]; then CC=$(command -v clang || true); fi
command -v "$CC" >/dev/null 2>&1 || { echo "缺少 clang" >&2; exit 1; }

echo "==> SDK: $SDK"
"$CC" -arch arm64 -isysroot "$SDK" -miphoneos-version-min=15.0 \
      -fobjc-arc -O2 -fmodules -Wall \
      -I"$HERE" \
      "$HERE/main.m" \
      "$HERE/DSHAppDelegate.m" \
      "$HERE/DSHRootVC.m" \
      "$HERE/DSHSettingsVC.m" \
      -o "$OUT" \
      -framework UIKit -framework Foundation -framework SafariServices -framework QuartzCore \
      -Wl,-no_uuid \
      -Wl,-sectcreate,__TEXT,__info_plist,"$PLIST"
if command -v ldid >/dev/null 2>&1; then
    ldid -S "$OUT" || echo "warn: ldid 签名失败（CI 可忽略）" >&2
else
    echo "warn: 无 ldid，产物未伪签名（需在设备上 ldid -S）" >&2
fi
lipo -info "$OUT" 2>/dev/null || file "$OUT"
ls -l "$OUT"
sha256sum "$OUT"
echo "==> done: $OUT"
