#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
CACHE="${TMPDIR:-/tmp/}MKVStudio-build"
export CLANG_MODULE_CACHE_PATH="$CACHE/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$CACHE/modules"
mkdir -p "$CACHE" "$ROOT/build"
swift build --package-path "$ROOT" --scratch-path "$CACHE/products" --cache-path "$CACHE/cache" --config-path "$CACHE/config" --security-path "$CACHE/security" --disable-sandbox --build-system native -c release
BIN_DIR="$(swift build --package-path "$ROOT" --scratch-path "$CACHE/products" --cache-path "$CACHE/cache" --config-path "$CACHE/config" --security-path "$CACHE/security" --disable-sandbox --build-system native -c release --show-bin-path)"
STAGE="$(mktemp -d "$CACHE/package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/MKVStudio.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$STAGE/AppIcon.iconset"
cp -X "$BIN_DIR/MKVStudio" "$APP/Contents/MacOS/MKVStudio"
cp -X "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT"/MKVStudio/Assets.xcassets/AppIcon.appiconset/icon_*.png "$STAGE/AppIcon.iconset/"
cp "$ROOT/MKVStudio/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" "$STAGE/AppIcon.iconset/icon_512x512@2x.png"
python3 "$ROOT/Scripts/package-icon.py" "$ROOT/MKVStudio/Assets.xcassets/AppIcon.appiconset" "$APP/Contents/Resources/AppIcon.icns"
python3 "$ROOT/Scripts/bundle-console-tools.py" "$APP"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
python3 "$ROOT/Scripts/verify-bundle.py" "$APP"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ROOT/build/MKVStudio-$VERSION-macOS-arm64.zip"
# Replace the generated bundle completely; ditto alone can retain obsolete helpers.
rm -rf "$ROOT/build/MKVStudio.app"
ditto --norsrc --noextattr "$APP" "$ROOT/build/MKVStudio.app"
(cd "$ROOT/build" && shasum -a 256 "MKVStudio-$VERSION-macOS-arm64.zip") > "$ROOT/build/SHA256SUMS.txt"
printf 'Built: %s\n' "$ROOT/build/MKVStudio.app"
