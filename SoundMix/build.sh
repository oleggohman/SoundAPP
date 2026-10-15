#!/bin/bash
# Builds SoundMix.app. No Xcode project, no package manager, no network.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SoundMix"
BINARY="SoundMix"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
MODCACHE="${TMPDIR:-/tmp}/soundmix-modcache"

VERSION=$(cat VERSION)
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid VERSION: expected major.minor.patch" >&2
    exit 1
fi
# Continue from the last local app bundle; CI can supply a release build number.
if [[ -z "${BUILD_NUMBER:-}" ]]; then
    PREVIOUS_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo 0)
    if [[ ! "$PREVIOUS_BUILD" =~ ^[0-9]{1,9}$ ]]; then
        echo "Invalid previous build number; set BUILD_NUMBER explicitly." >&2
        exit 1
    fi
    BUILD_NUMBER=$((10#$PREVIOUS_BUILD + 1))
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]{0,8}$ ]]; then
    echo "Invalid BUILD_NUMBER: expected a positive integer (up to 9 digits)." >&2
    exit 1
fi

echo "==> Preparing app icon"
bash ./build-icon.sh

echo "==> Compiling SoundMix $VERSION (build $BUILD_NUMBER)"
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

cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$APP/Contents/Info.plist"
cp -R Resources/SoundMix.help "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "    (ad-hoc signing unavailable; the app still runs locally)"

echo "==> Built $APP — version $VERSION (build $BUILD_NUMBER)"
du -sh "$APP" | sed 's/^/    /'
