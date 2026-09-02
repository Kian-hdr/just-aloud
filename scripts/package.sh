#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-1.0.0}"
APP="${APP_PATH:-$ROOT/build/Just Aloud.app}"
ARTIFACTS="${ARTIFACTS_DIR:-$ROOT/artifacts}"
ARCHIVE="$ARTIFACTS/Just-Aloud-$VERSION.zip"
[ -d "$APP" ] || { printf 'Missing app: %s\n' "$APP" >&2; exit 1; }
mkdir -p "$ARTIFACTS"
rm -f "$ARCHIVE" "$ARCHIVE.sha256"
ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$APP" "$ARCHIVE"
(cd "$ARTIFACTS" && shasum -a 256 "$(basename "$ARCHIVE")") > "$ARCHIVE.sha256"
printf 'Packaged %s\n' "$ARCHIVE"
