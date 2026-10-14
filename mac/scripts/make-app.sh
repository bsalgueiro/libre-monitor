#!/bin/bash
# Builds LibreMonitor.app from the Swift package, ad-hoc signs it and zips it. Run on a Mac.
#
#   ./scripts/make-app.sh            release build, universal (arm64 + x86_64); ignores --dev / --simulate
#   ./scripts/make-app.sh --debug    debug build for this Mac only; accepts --dev and --simulate N
#
# Output: build/LibreMonitor.app, build/LibreMonitor-mac.zip, build/SHA256SUMS.txt
# Set VERSION=1.2.3 to stamp a version (default 0.1.0).
set -euo pipefail

cd "$(dirname "$0")/.." # the mac/ folder

CONFIG=release
ARCH_FLAGS=(--arch arm64 --arch x86_64)
if [[ "${1:-}" == "--debug" ]]; then
  CONFIG=debug
  ARCH_FLAGS=()
fi
VERSION="${VERSION:-0.1.0}"

# ${arr[@]+...} keeps an empty array from tripping `set -u` on the bash 3.2 that macOS ships.
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="build/LibreMonitor.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/LibreMonitorMac" "$APP/Contents/MacOS/LibreMonitor"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"

# App icon: Resources/AppIcon.png (1024x1024) becomes AppIcon.icns. Notifications, Finder and About use it.
ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" > /dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Sign the finished bundle (ad hoc, no Apple account needed). Apple Silicon refuses unsigned code, and
# any change to the bundle after this point would invalidate the signature.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

ditto -c -k --keepParent "$APP" build/LibreMonitor-mac.zip
(cd build && shasum -a 256 LibreMonitor-mac.zip > SHA256SUMS.txt)

echo
echo "Built $CONFIG app: $(pwd)/$APP"
echo "Zip: $(pwd)/build/LibreMonitor-mac.zip"
cat build/SHA256SUMS.txt
