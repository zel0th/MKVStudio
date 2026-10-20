#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
APP="$ROOT/build/MKVStudio.app"
[ -d "$APP" ] || bash "$ROOT/Scripts/build-app.sh"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION" ] || {
    echo "Rebuild the app before packaging."; exit 1;
}
WORK="$(mktemp -d "${TMPDIR:-/tmp/}MKVStudio-installer.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/root/Applications" "$WORK/scripts" "$WORK/resources" "$WORK/dmg"
ditto --norsrc --noextattr "$APP" "$WORK/root/Applications/MKVStudio.app"
codesign --verify --deep --strict "$WORK/root/Applications/MKVStudio.app"
cp "$ROOT/Installer/scripts/"* "$WORK/scripts/"
chmod 755 "$WORK/scripts/"*
cp "$ROOT/Installer/Welcome.html" "$WORK/resources/Welcome.html"
cat > "$WORK/components.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><array><dict>
<key>RootRelativeBundlePath</key><string>Applications/MKVStudio.app</string>
<key>BundleIsRelocatable</key><false/>
<key>BundleIsVersionChecked</key><true/>
<key>BundleOverwriteAction</key><string>upgrade</string>
</dict></array></plist>
PLIST
pkgbuild --root "$WORK/root" --component-plist "$WORK/components.plist" \
    --scripts "$WORK/scripts" --identifier com.zshfan.MKVStudio \
    --version "$VERSION" --install-location / "$WORK/application.pkg"
cat > "$WORK/Distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>MKVStudio $VERSION</title>
  <welcome file="Welcome.html"/>
  <options customize="never" require-scripts="true" hostArchitectures="arm64"/>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <allowed-os-versions><os-version min="14.0"/></allowed-os-versions>
  <choices-outline><line choice="application"/></choices-outline>
  <choice id="application" visible="false"><pkg-ref id="com.zshfan.MKVStudio"/></choice>
  <pkg-ref id="com.zshfan.MKVStudio" version="$VERSION" onConclusion="none">application.pkg</pkg-ref>
</installer-gui-script>
XML
PKG="$WORK/dmg/Install MKVStudio.pkg"
productbuild --distribution "$WORK/Distribution.xml" --package-path "$WORK" --resources "$WORK/resources" "$PKG"
cp "$ROOT/Installer/Welcome.html" "$WORK/dmg/Начните здесь.html"
ln -s /Applications "$WORK/dmg/Программы"
DMG="$ROOT/build/MKVStudio-$VERSION-macOS-arm64.dmg"
# Use a fresh output and replace only this version's previous build after success.
hdiutil create -volname "MKVStudio $VERSION" -srcfolder "$WORK/dmg" -format UDZO -fs APFS "$WORK/release.dmg"
hdiutil verify "$WORK/release.dmg"
cp "$PKG" "$ROOT/build/MKVStudio-$VERSION.pkg"
mv "$WORK/release.dmg" "$DMG"
(cd "$ROOT/build" && shasum -a 256 "MKVStudio-$VERSION-macOS-arm64.zip" "MKVStudio-$VERSION-macOS-arm64.dmg" "MKVStudio-$VERSION.pkg") > "$ROOT/build/SHA256SUMS.txt"
printf 'Built: %s\n' "$DMG"
