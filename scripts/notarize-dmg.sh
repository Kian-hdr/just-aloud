#!/bin/bash
set -euo pipefail
DMG="${1:?Pass the signed DMG path}"
PROFILE="${NOTARY_PROFILE:?Name an existing notarytool Keychain profile}"
OUT="$(dirname "$DMG")"
[ -f "$DMG" ] || exit 1
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait --output-format json > "$OUT/notary-dmg.json"
test "$(plutil -extract status raw "$OUT/notary-dmg.json")" = Accepted
xcrun notarytool log "$(plutil -extract id raw "$OUT/notary-dmg.json")" --keychain-profile "$PROFILE" "$OUT/notary-dmg-log.json"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")") > "$DMG.sha256"
