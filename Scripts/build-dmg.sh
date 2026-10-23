#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
APP="$ROOT/build/MKVStudio.app"
[ -d "$APP" ] || bash "$ROOT/Scripts/build-app.sh"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION" ] || {
    echo "Rebuild the app before packaging."; exit 1;
}
WORK="$(mktemp -d "${TMPDIR:-/tmp/}MKVStudio-dmg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/dmg"
ditto --norsrc --noextattr "$APP" "$WORK/dmg/MKVStudio.app"
python3 "$ROOT/Scripts/verify-bundle.py" "$WORK/dmg/MKVStudio.app"
ln -s /Applications "$WORK/dmg/Программы"
cp "$ROOT/Distribution/Установка.txt" "$WORK/dmg/Установка.txt"
DMG="$ROOT/build/MKVStudio-$VERSION-macOS-arm64.dmg"
hdiutil create -volname "MKVStudio $VERSION" -srcfolder "$WORK/dmg" -format UDZO -fs APFS "$WORK/release.dmg"
hdiutil verify "$WORK/release.dmg"
mv "$WORK/release.dmg" "$DMG"
(cd "$ROOT/build" && shasum -a 256 "MKVStudio-$VERSION-macOS-arm64.zip" "MKVStudio-$VERSION-macOS-arm64.dmg") > "$ROOT/build/SHA256SUMS.txt"
printf 'Built: %s\n' "$DMG"
