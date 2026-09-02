#!/bin/bash
set -euo pipefail
export JUST_ALOUD_DISABLE_RECORDING=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/just-aloud-distribution.XXXXXXXX")
TEST_HOME="$TEST_ROOT/home"
STUBS="$TEST_ROOT/stubs"
mkdir -p "$TEST_HOME" "$STUBS"
export HOME="$TEST_HOME"
export PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin"
unset TERM_PROGRAM

cat > "$STUBS/osascript" <<'SH'
#!/bin/bash
case "$*" in
  *"Welcome to Just Aloud"*) printf 'Continue\n' ;;
  *"Paste your ElevenLabs API key"*) printf 'test-api-key-not-a-real-secret\n' ;;
  *"Install the Just Aloud app"*) printf 'Install\n' ;;
  *"Launch Just Aloud automatically"*) printf 'Not Now\n' ;;
  *"This will completely remove Just Aloud"*) printf 'Uninstall\n' ;;
  *) printf '\n' ;;
esac
SH
cat > "$STUBS/curl" <<'SH'
#!/bin/bash
case "$*" in *"%{http_code}"*) printf '200' ;; *) exit 0 ;; esac
SH
cat > "$STUBS/security" <<'SH'
#!/bin/bash
exit 0
SH
cat > "$STUBS/uname" <<'SH'
#!/bin/bash
printf 'x86_64\n'
SH
cat > "$STUBS/sw_vers" <<'SH'
#!/bin/bash
printf '26.0\n'
SH
cat > "$STUBS/pkgutil" <<'SH'
#!/bin/bash
printf 'package-id: com.apple.pkg.CLTools_Executables\nversion: 26.0\n'
SH
cat > "$STUBS/open" <<'SH'
#!/bin/bash
exit 0
SH
cat > "$STUBS/tccutil" <<'SH'
#!/bin/bash
exit 0
SH
cat > "$STUBS/pkill" <<'SH'
#!/bin/bash
exit 0
SH
cat > "$STUBS/python3" <<'SH'
#!/bin/bash
if [ "${1:-}" = "-m" ] && [ "${2:-}" = "venv" ]; then
  mkdir -p "$3/bin"
  printf '#!/bin/bash\nexit 0\n' > "$3/bin/pip"
  printf '#!/bin/bash\nexit 0\n' > "$3/bin/python3"
  chmod +x "$3/bin/pip" "$3/bin/python3"
fi
exit 0
SH
chmod +x "$STUBS"/*

"$ROOT/install.command" >/dev/null
test -x "$TEST_HOME/Applications/Just Aloud.app/Contents/MacOS/JustAloud"
test -f "$TEST_HOME/Applications/Just Aloud.app/Contents/Resources/Assets.car"
test -f "$TEST_HOME/Applications/Just Aloud.app/Contents/Resources/JustAloud.icns"
test "$(plutil -extract CFBundleIconName raw "$TEST_HOME/Applications/Just Aloud.app/Contents/Info.plist")" = "JustAloud"
test -x "$TEST_HOME/.local/bin/just-aloud"
test -f "$TEST_HOME/.config/just-aloud/config"
test -d "$TEST_HOME/Library/Services/Speak Selection with Just Aloud.workflow"
printf 'PASS: isolated fresh install\n'

cat >> "$TEST_HOME/.config/just-aloud/config" <<'CFG'
CUSTOM_VOICE_IDS="fixture_one,fixture_two"
CUSTOM_VOICE_NAMES_B64="fixture_one:Rml4dHVyZSBPbmU=,fixture_two:Rml4dHVyZSBUd28="
CFG
"$ROOT/install.command" >/dev/null
grep -q 'fixture_one,fixture_two' "$TEST_HOME/.config/just-aloud/config"
printf 'PASS: isolated upgrade preserves custom voices\n'

mkdir -p "$TEST_HOME/.config/speak11" "$TEST_HOME/Applications/Speak11.app"
printf 'VOICE_ID="upstream_fx"\n' > "$TEST_HOME/.config/speak11/config"
"$ROOT/uninstall.command" >/dev/null
test ! -e "$TEST_HOME/Applications/Just Aloud.app"
test ! -e "$TEST_HOME/.config/just-aloud"
test -f "$TEST_HOME/.config/speak11/config"
test -d "$TEST_HOME/Applications/Speak11.app"
printf 'PASS: isolated uninstall preserves Speak11\n'

CACHE="$TEST_ROOT/swift-cache"
mkdir -p "$CACHE"
xcrun swiftc -D TESTING -module-cache-path "$CACHE" "$ROOT/JustAloud.swift" -o "$TEST_ROOT/JustAloudTest"
cat > "$TEST_ROOT/legacy-config" <<'CFG'
TTS_BACKEND="elevenlabs"
VOICE_ID="fixture_one"
CUSTOM_VOICE_IDS="fixture_one,fixture_two"
CUSTOM_VOICE_NAMES_B64="fixture_one:Rml4dHVyZSBPbmU=,fixture_two:Rml4dHVyZSBUd28="
PLAYBACK_SPEED="1.50"
CFG
inspection=$("$TEST_ROOT/JustAloudTest" --inspect-config "$TEST_ROOT/legacy-config")
grep -q 'backend=elevenlabs' <<< "$inspection"
grep -q 'custom_voice_count=2' <<< "$inspection"
grep -q 'named_voice_count=2' <<< "$inspection"
grep -q 'has_active_voice=true' <<< "$inspection"
printf 'PASS: migration-compatible config parsing\n'

WELCOME_SUITE="space.exlumina.justaloud.tests.$$.welcome"
welcome_first=$("$TEST_ROOT/JustAloudTest" --inspect-welcome-state "$WELCOME_SUITE")
grep -q 'should_show=true' <<< "$welcome_first"
grep -q "domain=$WELCOME_SUITE" <<< "$welcome_first"
welcome_complete=$("$TEST_ROOT/JustAloudTest" --inspect-welcome-state "$WELCOME_SUITE" complete)
grep -q 'should_show=false' <<< "$welcome_complete"
defaults delete "$WELCOME_SUITE" >/dev/null 2>&1 || true
grep -q 'showWelcome()' "$ROOT/JustAloud.swift"
grep -q 'Welcome & Setup' "$ROOT/JustAloud.swift"
grep -q 'JUST_ALOUD_DEFAULTS_SUITE' "$ROOT/JustAloud.swift"
printf 'PASS: welcome first-launch completion and About reopen hooks\n'
