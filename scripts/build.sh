#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
APP="$BUILD_DIR/Just Aloud.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-3}"
SWIFT_CACHE="${SWIFT_CACHE:-$BUILD_DIR/swift-module-cache}"

case "$APP" in
    ""|"/"|"$HOME"|"$ROOT") printf 'Refusing unsafe build target: %s\n' "$APP" >&2; exit 1 ;;
esac
if [ -d "$APP" ]; then
    /bin/rm -rf "$APP"
fi
mkdir -p "$MACOS" "$RESOURCES" "$SWIFT_CACHE"
for arch in arm64 x86_64; do
    xcrun swiftc -target "$arch-apple-macos13.0" -module-cache-path "$SWIFT_CACHE" -O \
        "$ROOT/JustAloud.swift" -o "$BUILD_DIR/JustAloud-$arch"
    xcrun swiftc -target "$arch-apple-macos13.0" -module-cache-path "$SWIFT_CACHE" -O \
        "$ROOT/just-aloud-audio.swift" -o "$BUILD_DIR/just-aloud-audio-$arch"
done
xcrun lipo -create "$BUILD_DIR/JustAloud-arm64" "$BUILD_DIR/JustAloud-x86_64" -output "$MACOS/JustAloud"
xcrun lipo -create "$BUILD_DIR/just-aloud-audio-arm64" "$BUILD_DIR/just-aloud-audio-x86_64" -output "$RESOURCES/just-aloud-audio"

cp "$ROOT/just-aloud.sh" "$RESOURCES/just-aloud"
cp "$ROOT/normalize.py" "$RESOURCES/just-aloud-normalize.py"
cp "$ROOT/tts_server.py" "$RESOURCES/just-aloud-tts-server.py"
cp "$ROOT/install-local.sh" "$RESOURCES/just-aloud-install-local"
cp "$ROOT/uninstall.command" "$RESOURCES/uninstall.command"
cp "$ROOT/Assets.xcassets/MenuBarIcon.imageset/menu-bar-template.svg" "$RESOURCES/menu-bar-template.svg"
for file in LICENSE ATTRIBUTION.md LICENSING.md BRAND.md THIRD_PARTY_NOTICES.md CHANGES.md; do
    cp "$ROOT/$file" "$RESOURCES/$file"
done
chmod 755 "$MACOS/JustAloud" "$RESOURCES/just-aloud" "$RESOURCES/just-aloud-audio" \
    "$RESOURCES/just-aloud-install-local" "$RESOURCES/uninstall.command"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDisplayName</key><string>Just Aloud</string>
  <key>CFBundleExecutable</key><string>JustAloud</string>
  <key>CFBundleIconFile</key><string>JustAloud</string>
  <key>CFBundleIconName</key><string>JustAloud</string>
  <key>CFBundleIdentifier</key><string>space.exlumina.justaloud</string>
  <key>CFBundleName</key><string>Just Aloud</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Kian Konrad Tajbakhsh. Just Aloud brand artwork reserved.</string>
</dict></plist>
PLIST

# Compile the Icon Composer document into an appearance-aware Assets.car. The
# same command also generates the .icns fallback used on older macOS releases.
ICON_PARTIAL="$BUILD_DIR/icon-partial.plist"
xcrun actool \
    --compile "$RESOURCES" \
    --platform macosx \
    --minimum-deployment-target 13.0 \
    --app-icon JustAloud \
    --output-partial-info-plist "$ICON_PARTIAL" \
    "$ROOT/Design/Icon/JustAloud.icon" >/dev/null
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile JustAloud' "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconName JustAloud' "$CONTENTS/Info.plist"

plutil -lint "$CONTENTS/Info.plist"
# Cloud-backed source folders can attach Finder/File Provider metadata to copied
# build products. Strip only the generated bundle before Developer ID signing.
xattr -cr "$APP"
printf 'Built %s\n' "$APP"
