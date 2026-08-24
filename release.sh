#!/bin/bash
set -euo pipefail

# Local-only release-candidate pipeline. It never pushes, creates a GitHub
# release, uploads an artifact, or modifies Apple Developer resources.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${1:-0.9.0}"
RC_BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/just-aloud-release.XXXXXXXX")
APP="$RC_BUILD_DIR/Just Aloud.app"
VERSION="$VERSION" "$ROOT/scripts/verify.sh"
VERSION="$VERSION" BUILD_DIR="$RC_BUILD_DIR" "$ROOT/scripts/build.sh"
VERSION="$VERSION" "$ROOT/scripts/sign.sh" "$APP"
VERSION="$VERSION" APP_PATH="$APP" "$ROOT/scripts/package.sh"
if [ -n "${NOTARY_PROFILE:-}" ]; then
    VERSION="$VERSION" APP_PATH="$APP" NOTARY_PROFILE="$NOTARY_PROFILE" \
        "$ROOT/scripts/notarize.sh"
    printf 'Local signed, notarized, and stapled release candidate prepared.\n'
else
    printf 'Local signed release candidate prepared. Notarization requires an existing\n'
    printf 'Keychain profile: NOTARY_PROFILE=<name> ./release.sh %s\n' "$VERSION"
fi
printf 'No publication action was performed.\n'
