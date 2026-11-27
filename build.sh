#!/bin/bash
# Builds WGToggle.app (universal) and WGToggle.dmg into ./build
set -euo pipefail
cd "$(dirname "$0")"

APP=build/WGToggle.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -target $arch-apple-macos13 -o build/WGToggle-$arch Sources/*.swift
done
lipo -create build/WGToggle-arm64 build/WGToggle-x86_64 -output "$APP/Contents/MacOS/WGToggle"
rm build/WGToggle-*

cp Resources/Info.plist "$APP/Contents/"
# `wgtoggle` command line wrapper (Homebrew links it into bin/)
cat > "$APP/Contents/Resources/wgtoggle" <<'SH'
#!/bin/bash
# Resolve symlinks so the app bundle (and its settings) is found.
exec "$(dirname "$(/usr/bin/readlink -f "$0")")/../MacOS/WGToggle" cli "$@"
SH
chmod 755 "$APP/Contents/Resources/wgtoggle"
# CI passes APP_VERSION (from the git tag) and BUILD_NUMBER
if [ -n "${APP_VERSION:-}" ]; then
  plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
  plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

# App icon rendered from an SF Symbol
swift Resources/make-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/AppIcon.iconset

codesign --force --deep --sign - "$APP"

# DMG with drag-to-Applications layout
STAGE=build/dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cp README.md "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname WGToggle -srcfolder "$STAGE" -ov -format UDZO build/WGToggle.dmg >/dev/null
rm -rf "$STAGE"

echo "Built: $(pwd)/build/WGToggle.dmg"
