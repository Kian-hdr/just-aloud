#!/bin/bash
# Install a private, self-contained snapshot from source or app Resources.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${JUST_ALOUD_PYTHON:-}"
if [ -z "$PYTHON" ]; then
    for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 "$HOME/.local/share/just-aloud/venv/bin/python3" "$(command -v python3 || true)"; do
        if [ -x "$candidate" ] && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3,9))' >/dev/null 2>&1; then
            PYTHON="$candidate"; break
        fi
    done
fi
[ -n "$PYTHON" ] && [ -x "$PYTHON" ] && "$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3,9))' || {
    echo 'Python 3.9 or later is required. Install Python from python.org, then try again.' >&2; exit 1;
}
RUNTIME="$HOME/.local/share/just-aloud/agent-connector"
LAUNCHER="$HOME/.local/bin/just-aloud-agent"
AUDIO="$ROOT/just-aloud-audio"
[ -x "$AUDIO" ] || AUDIO="$ROOT/build/Just Aloud.app/Contents/Resources/just-aloud-audio"
[ -x "$AUDIO" ] || { echo 'Audio exporter missing. Source users: run ./scripts/build.sh first.' >&2; exit 1; }
TTS="$ROOT/tts_server.py"
[ -f "$TTS" ] || TTS="$ROOT/just-aloud-tts-server.py"
mkdir -p "$(dirname "$RUNTIME")" "$(dirname "$LAUNCHER")"
# Refuse concurrent installs. Never touch active jobs or their output directory.
LOCK="${RUNTIME}.install-lock"
mkdir "$LOCK" 2>/dev/null || { echo 'Another connector install may be in progress.' >&2; exit 1; }
STAGE="$(mktemp -d "${RUNTIME}.stage.XXXXXXXX")"
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
mkdir "$STAGE/agent"
cp "$ROOT"/agent/*.py "$STAGE/agent/"
cp "$ROOT/agent/capabilities.json" "$STAGE/agent/capabilities.json"
cp "$ROOT/agent/README.md" "$STAGE/README.md"
cp "$ROOT/speech-backend.sh" "$ROOT/headless-generate.sh" "$STAGE/"
cp "$TTS" "$STAGE/tts_server.py"
cp "$AUDIO" "$STAGE/just-aloud-audio"
"$PYTHON" - "$STAGE/install.json" "$PYTHON" <<'PY'
import json,sys,datetime
with open(sys.argv[1],'w') as f:
    json.dump({'schema_version':1,'python':sys.argv[2],'installed_at':datetime.datetime.now(datetime.timezone.utc).isoformat()},f)
PY
# Validation does not launch synthesis, read Keychain, or contact a provider.
"$PYTHON" - "$STAGE" <<'PY'
import ast,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
for f in (p/'agent').glob('*.py'): ast.parse(f.read_text())
json.loads((p/'agent/capabilities.json').read_text())
PY
NEW_LAUNCHER="$STAGE/launcher"
{ printf '#!/bin/bash\nexec '; printf '%q ' "$PYTHON" "$RUNTIME/agent/server.py"; printf '\n'; } > "$NEW_LAUNCHER"
chmod 700 "$NEW_LAUNCHER"
# Backups are private and retained; no external recovery utility is required.
BACKUP="$(mktemp -d "${RUNTIME}.backup.XXXXXXXX")"
HAD_RUNTIME=0
HAD_LAUNCHER=0
PROMOTED=0
rollback() {
    result=$?
    if [ "$result" -ne 0 ]; then
        # Preserve a partially promoted new snapshot too, then restore originals.
        if [ "$PROMOTED" -eq 1 ] && [ -e "$RUNTIME" ]; then mv "$RUNTIME" "$BACKUP/failed-new-runtime" || true; fi
        if [ "$HAD_RUNTIME" -eq 1 ]; then mv "$BACKUP/runtime" "$RUNTIME" || true; fi
        if [ "$HAD_LAUNCHER" -eq 1 ]; then mv "$BACKUP/launcher" "$LAUNCHER" || true; fi
        printf 'Installation failed; previous setup restored where possible. Recovery files: %s\n' "$BACKUP" >&2
    fi
    rmdir "$LOCK" 2>/dev/null || true
}
trap rollback EXIT
if [ -e "$RUNTIME" ] || [ -L "$RUNTIME" ]; then mv "$RUNTIME" "$BACKUP/runtime"; HAD_RUNTIME=1; fi
if [ -e "$LAUNCHER" ] || [ -L "$LAUNCHER" ]; then mv "$LAUNCHER" "$BACKUP/launcher"; HAD_LAUNCHER=1; fi
mv "$STAGE" "$RUNTIME"
PROMOTED=1
mv "$RUNTIME/launcher" "$LAUNCHER"
printf 'Installed %s\nPrevious files, if any: %s\n' "$LAUNCHER" "$BACKUP"
printf 'Register with: codex mcp add just-aloud -- %q\n' "$LAUNCHER"
