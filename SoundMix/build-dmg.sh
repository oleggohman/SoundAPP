#!/bin/bash
# Build a compressed, drag-to-Applications macOS installer using system tools.
set -euo pipefail
cd "$(dirname "$0")"

case "${1:-}" in
    "") bash ./build.sh ;;
    --skip-build) ;;
    *) echo "Usage: $0 [--skip-build]" >&2; exit 2 ;;
esac

APP="build/SoundMix.app"
PLIST="$APP/Contents/Info.plist"
[[ -x "$APP/Contents/MacOS/SoundMix" ]] || { echo "Build SoundMix.app first." >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD" =~ ^[1-9][0-9]*$ ]] || {
    echo "Invalid app version metadata." >&2; exit 1;
}
codesign --verify --deep --strict "$APP"

mkdir -p dist
DMG="dist/SoundMix-$VERSION-build-$BUILD.dmg"
[[ ! -e "$DMG" ]] || { echo "Already exists: $DMG. Use a new build number." >&2; exit 1; }
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/soundmix-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
mkdir "$STAGING/payload"
ditto "$APP" "$STAGING/payload/SoundMix.app"
ln -s /Applications "$STAGING/payload/Applications"
cat > "$STAGING/payload/Install.txt" <<TXT
SoundMix $VERSION (build $BUILD)

1. Drag SoundMix.app to the Applications folder.
2. Eject this disk image.
3. Open SoundMix from Applications.

Requires macOS 14 or later. This build is for $(uname -m).
This local build is ad-hoc signed, not Developer ID signed or notarized.
TXT

echo "==> Creating $DMG"
hdiutil create -volname "SoundMix $VERSION" -srcfolder "$STAGING/payload" \
    -format UDZO -fs HFS+ "$STAGING/installer.dmg"
hdiutil verify "$STAGING/installer.dmg"
mv "$STAGING/installer.dmg" "$DMG"
echo "==> Installer ready: $PWD/$DMG"
