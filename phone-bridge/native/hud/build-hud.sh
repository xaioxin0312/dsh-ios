#!/bin/sh
# 构建 dsh-ios-hud.dylib（SpringBoard 实时进度胶囊）。
# 需要在 macOS + Xcode（或带 iPhoneOS SDK 的 clang）上运行；CI 见
# .github/workflows/build-native-hud.yml。
set -eu
DIR=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-"$DIR/dsh-ios-hud.dylib"}

if command -v xcrun >/dev/null 2>&1; then
    SDK=$(xcrun --sdk iphoneos --show-sdk-path)
    CC=$(xcrun --sdk iphoneos -f clang)
else
    : "${SDK:?set SDK to an iPhoneOS SDK path}"
    CC=${CC:-clang}
fi

# +ios24.8：install_name 改回 rootless 真实路径。旧值是非 rootless 的
# /Library/MobileSubstrate/...，Dopamine rootless 下实际加载路径带 /var/jb 前缀，
# 两者不一致会让部分注入器按 install_name 解析时找不到镜像。
"$CC" -arch arm64 -miphoneos-version-min=15.0 -fobjc-arc -O2 -fmodules \
    -isysroot "$SDK" -dynamiclib \
    -framework UIKit -framework Foundation -framework QuartzCore \
    -install_name /var/jb/Library/MobileSubstrate/DynamicLibraries/dsh-ios-hud.dylib \
    "$DIR/HUDOverlay.m" -o "$OUT"

file "$OUT"
echo "built: $OUT"
