#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
case "$MODE" in run|--verify) ;; *) echo 'Usage: build_and_run.sh [--verify]' >&2; exit 2 ;; esac
# Do not interrupt active selected-text speech merely to run a development build.
PID_FILE="${TMPDIR:-/tmp}/just_aloud_tts.pid"
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo 'Speech is active; finish or cancel that playback before relaunching.' >&2
    exit 1
fi
pkill -x JustAloud 2>/dev/null || true
"$ROOT/scripts/build.sh"
open -n "$ROOT/build/Just Aloud.app"
if [ "$MODE" = --verify ]; then
    sleep 1
    pgrep -x JustAloud >/dev/null
fi
