#!/bin/sh
# Build/stage the Roothide native targets without touching the prepared payload.
# Usage: build-native.sh PAYLOAD_ROOT STAGE_DIR [stage|package]
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PAYLOAD=${1:-${THEOS_LAYOUT_DIR:-}}
STAGE=${2:-${THEOS_STAGING_DIR:-"$HERE/.theos/roothide-stage"}}
MODE=${3:-stage}

[ -n "$PAYLOAD" ] || { echo "usage: $0 PAYLOAD_ROOT STAGE_DIR [stage|package]" >&2; exit 64; }
[ -d "$PAYLOAD" ] || { echo "payload root does not exist: $PAYLOAD" >&2; exit 66; }
case "$MODE" in
    stage|package) ;;
    *) echo "mode must be stage or package: $MODE" >&2; exit 64 ;;
esac

PAYLOAD=$(CDPATH= cd -- "$PAYLOAD" && pwd)
STAGE_PARENT=$(dirname -- "$STAGE")
STAGE_NAME=$(basename -- "$STAGE")
mkdir -p "$STAGE_PARENT"
STAGE_PARENT=$(CDPATH= cd -- "$STAGE_PARENT" && pwd)
STAGE="$STAGE_PARENT/$STAGE_NAME"
[ "$PAYLOAD" != "$STAGE" ] || { echo "payload root and stage directory must be different" >&2; exit 65; }

# The parent build exports TARGET/ARCHS/PACKAGE_VERSION/THEOS_PACKAGE_DIR and
# compression settings. Do not overwrite those values here.
MAKE_CMD=${MAKE:-make}
exec "$MAKE_CMD" -C "$HERE" \
    THEOS_PACKAGE_SCHEME=roothide \
    THEOS_LAYOUT_DIR="$PAYLOAD" \
    THEOS_STAGING_DIR="$STAGE" \
    "$MODE"
