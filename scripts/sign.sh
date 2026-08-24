#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/build/Just Aloud.app}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Kian Konrad Tajbakhsh (HZWY8HT54D)}"
TIMESTAMP_URL="${TIMESTAMP_URL:-http://timestamp.apple.com/ts01}"
[ -d "$APP" ] || { printf 'Missing app: %s\n' "$APP" >&2; exit 1; }
security find-identity -v -p codesigning | grep -Fq "$IDENTITY" || {
    printf 'Developer ID identity is not available in the active Keychain.\n' >&2; exit 1;
}
xattr -cr "$APP"

# Nested Mach-O files first, outer app last. --deep is never used to sign.
codesign --force --timestamp="$TIMESTAMP_URL" --options runtime --sign "$IDENTITY" "$APP/Contents/Resources/just-aloud-audio"
codesign --force --timestamp="$TIMESTAMP_URL" --options runtime --sign "$IDENTITY" "$APP/Contents/MacOS/JustAloud"
codesign --force --timestamp="$TIMESTAMP_URL" --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
printf 'Signed %s\n' "$APP"
