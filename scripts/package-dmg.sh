#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-1.0.0}"
APP="${APP_PATH:-$ROOT/build/Just Aloud.app}"
OUT="${ARTIFACTS_DIR:-$ROOT/artifacts}"
PYTHON="${PACKAGING_PYTHON:-python3}"
DMG="$OUT/Just-Aloud-$VERSION.dmg"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Kian Konrad Tajbakhsh (HZWY8HT54D)}"
[ -d "$APP" ] && [ ! -e "$DMG" ] || { printf 'Missing app or existing DMG; refusing overwrite.\n' >&2; exit 1; }
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP"
"$PYTHON" -c 'import ds_store'
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/just-aloud-dmg.XXXXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Just Aloud.app"
ln -s /Applications "$STAGE/Applications"
"$PYTHON" "$ROOT/scripts/dmg-layout.py" "$STAGE"
mkdir -p "$OUT"
hdiutil create -srcfolder "$STAGE" -volname 'Just Aloud' -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG"
codesign --timestamp --sign "$IDENTITY" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
hdiutil verify "$DMG"
printf 'Signed DMG ready for notarization: %s\n' "$DMG"
