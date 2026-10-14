#!/bin/bash
# Builds SoundMix.app. No Xcode project, no package manager, no network.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SoundMix"
BINARY="SoundMix"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
MODCACHE="${TMPDIR:-/tmp}/soundmix-modcache"

echo "==> Compiling"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$MODCACHE"

swiftc -O -swift-version 5 \
    -module-cache-path "$MODCACHE" \
    -framework AppKit -framework CoreAudio -framework AudioToolbox \
    Sources/SoundMixCore/*.swift \
    Sources/SoundMixEngine/*.swift \
    Sources/SoundMixApp/*.swift \
    -o "$APP/Contents/MacOS/$BINARY"

echo "==> Building test tools"
swiftc -O -swift-version 5 -module-cache-path "$MODCACHE" \
    Tools/BedGenerator/main.swift -o "$BUILD_DIR/bedgen"

cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "    (ad-hoc signing unavailable; the app still runs locally)"

echo "==> Built $APP"
du -sh "$APP" | sed 's/^/    /'
