#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.9.0}"
PROFILE="${NOTARY_PROFILE:-}"
APP="${APP_PATH:-$ROOT/build/Just Aloud.app}"
ARCHIVE="${ARCHIVE_PATH:-$ROOT/artifacts/Just-Aloud-$VERSION.zip}"
[ -n "$PROFILE" ] || {
    printf 'NOTARY_PROFILE must name an existing notarytool Keychain profile.\n' >&2
    printf 'This script never accepts raw Apple credentials.\n' >&2
    exit 2
}
[ -f "$ARCHIVE" ] || { printf 'Missing archive: %s\n' "$ARCHIVE" >&2; exit 1; }

xcrun notarytool submit "$ARCHIVE" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"
rm -f "$ARCHIVE" "$ARCHIVE.sha256"
ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$APP" "$ARCHIVE"
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
printf 'Notarized and stapled %s\n' "$APP"
