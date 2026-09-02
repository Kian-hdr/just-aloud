#!/bin/bash
set -euo pipefail
export JUST_ALOUD_DISABLE_RECORDING=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/just-aloud-test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
SWIFT_CACHE="$TMP_ROOT/swift-cache"
mkdir -p "$SWIFT_CACHE"

pass() { printf 'PASS: %s\n' "$1"; }

bash -n "$ROOT/just-aloud.sh" "$ROOT/install.command" "$ROOT/install-local.sh" "$ROOT/uninstall.command" "$ROOT/release.sh"
pass "shell syntax"

python3 -m py_compile "$ROOT/normalize.py" "$ROOT/tts_server.py"
pass "Python syntax"

xcrun swiftc -module-cache-path "$SWIFT_CACHE" "$ROOT/JustAloud.swift" -o "$TMP_ROOT/JustAloud"
xcrun swiftc -module-cache-path "$SWIFT_CACHE" "$ROOT/just-aloud-audio.swift" -o "$TMP_ROOT/just-aloud-audio"
pass "Swift app and audio helper build"

BUILD_DIR="$TMP_ROOT/app-build" "$ROOT/scripts/build.sh" >/dev/null
ICON_RESOURCES="$TMP_ROOT/app-build/Just Aloud.app/Contents/Resources"
test -f "$ICON_RESOURCES/Assets.car"
test -f "$ICON_RESOURCES/JustAloud.icns"
ICON_INFO=$(xcrun assetutil --info "$ICON_RESOURCES/Assets.car")
grep -q 'NSAppearanceNameAqua' <<< "$ICON_INFO"
grep -q 'NSAppearanceNameDarkAqua' <<< "$ICON_INFO"
grep -q 'ISAppearanceTintable' <<< "$ICON_INFO"
test "$(plutil -extract CFBundleIconName raw "$TMP_ROOT/app-build/Just Aloud.app/Contents/Info.plist")" = "JustAloud"
pass "adaptive Aqua, Dark, Mono, and fallback app icon resources"

cmp "$ROOT/LICENSE" <(git -C "$ROOT" show v1.1.0:LICENSE)
pass "upstream Unlicense preserved byte-for-byte"

grep -q 'CFBundleIdentifier' "$ROOT/install.command"
grep -q 'space.exlumina.justaloud' "$ROOT/install.command"
grep -q 'Just Aloud.app' "$ROOT/install.command"
! grep -q 'com.just-aloud.app' "$ROOT/install.command"
grep -q '\.config/just-aloud"' "$ROOT/JustAloud.swift"
grep -q 'Bundle.main.path(forResource: "just-aloud"' "$ROOT/JustAloud.swift"
grep -q 'brew install --cask just-aloud' "$ROOT/README.md"
! grep -Rqs 'enhanced-enhanced\|EnhancedEnhanced' --exclude-dir=.git --exclude-dir=.venv --exclude-dir=build --exclude-dir=artifacts "$ROOT"
pass "distinct app name and bundle identifier"

grep -q 'installStandardEditMenu' "$ROOT/JustAloud.swift"
grep -q 'CUSTOM_VOICE_IDS' "$ROOT/JustAloud.swift"
grep -q 'CUSTOM_VOICE_NAMES_B64' "$ROOT/JustAloud.swift"
grep -q 'api.elevenlabs.io/v1/voices/' "$ROOT/JustAloud.swift"
grep -q 'json\["name"\]' "$ROOT/JustAloud.swift"
grep -q 'xmark.circle.fill' "$ROOT/JustAloud.swift"
grep -q 'copyCustomVoiceID' "$ROOT/JustAloud.swift"
grep -q 'NSPasteboard.general' "$ROOT/JustAloud.swift"
grep -q 'doc.on.doc' "$ROOT/JustAloud.swift"
grep -q 'circle.inset.filled' "$ROOT/JustAloud.swift"
grep -q 'controlAccentColor' "$ROOT/JustAloud.swift"
! grep -A20 'selectButton.action = #selector(pickCloudVoice' "$ROOT/JustAloud.swift" | grep -q 'systemSymbolName: "checkmark"'
grep -q 'secondaryLabelColor' "$ROOT/JustAloud.swift"
grep -q 'width: 344, height: 44' "$ROOT/JustAloud.swift"
grep -q 'x: 16, y: 25, width: 14, height: 14' "$ROOT/JustAloud.swift"
grep -q 'x: 38, y: 23, width: 250, height: 18' "$ROOT/JustAloud.swift"
grep -q 'x: 38, y: 4, width: 250, height: 18' "$ROOT/JustAloud.swift"
grep -q 'x: 308, y: 10, width: 20, height: 24' "$ROOT/JustAloud.swift"
grep -q 'nameLabel.font = NSFont.menuFont(ofSize: 13)' "$ROOT/JustAloud.swift"
! grep -A8 'func pickCloudVoice' "$ROOT/JustAloud.swift" | grep -q 'cancelTracking\|rebuildMenu'
grep -A8 'func pickCloudVoice' "$ROOT/JustAloud.swift" | grep -q 'updateCloudVoiceSelectionIndicators'
grep -q 'knownVoices.map' "$ROOT/JustAloud.swift"
grep -q 'defaultVoiceItem' "$ROOT/JustAloud.swift"
grep -q 'PLAYBACK_SPEED' "$ROOT/JustAloud.swift"
grep -q 'AVAudioUnitTimePitch' "$ROOT/just-aloud-audio.swift"
grep -q 'migrateFromSpeak11' "$ROOT/JustAloud.swift"
grep -q 'SecItemCopyMatching' "$ROOT/JustAloud.swift"
! grep -A12 'func pickCloudVoice' "$ROOT/JustAloud.swift" | grep -q 'rebuildMenu\|cancelTracking'
! grep -q 'submenuItem("Remove Custom Voice"' "$ROOT/JustAloud.swift"
grep -q 'gobackward.10' "$ROOT/JustAloud.swift"
grep -q 'goforward.10' "$ROOT/JustAloud.swift"
grep -q 'playbackStatePath' "$ROOT/JustAloud.swift"
pass "enhanced UI, paste, voice, and playback features present"

python3 - "$TMP_ROOT/silence.wav" <<'PY'
import struct, sys, wave
with wave.open(sys.argv[1], "wb") as wav:
    wav.setnchannels(1)
    wav.setsampwidth(2)
    wav.setframerate(8000)
    wav.writeframes(struct.pack("<h", 0) * 8000 * 4)
PY

STATE="${TMPDIR:-/tmp}/just_aloud_audio_state"
CONTROL="${TMPDIR:-/tmp}/just_aloud_audio_control"
STATUS="$TMP_ROOT/status"
rm -f "$STATE" "$CONTROL"
printf '%s\t%s\t0\t20\t%s\t0\n' "$TMP_ROOT/silence.wav" "$(date +%s)" "$STATUS" \
    | "$TMP_ROOT/just-aloud-audio" play-queue > "$TMP_ROOT/player.out" &
PLAYER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$STATE" ] && [ "$(tr -d '\n' < "$STATE")" = "playing" ] && break
    sleep 0.1
done
[ "$(tr -d '\n' < "$STATE")" = "playing" ]
printf 'pause\n' > "$CONTROL"
sleep 0.2
[ "$(tr -d '\n' < "$STATE")" = "paused" ]
printf 'seek:10\nplay\n' > "$CONTROL"
sleep 0.2
[ "$(tr -d '\n' < "$STATE")" = "playing" ] || ! kill -0 "$PLAYER_PID" 2>/dev/null
kill "$PLAYER_PID" 2>/dev/null || true
wait "$PLAYER_PID" 2>/dev/null || true
pass "silent-audio play, pause, seek, and resume control channel"

"$ROOT/scripts/scan-secrets.sh"
git -C "$ROOT" diff --check
pass "secret scan and diff hygiene"
