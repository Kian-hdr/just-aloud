#!/bin/bash
# Private, single-attempt generation adapter. JSON stdin; raw audio at output_path.
# The MCP layer resolves preferences, validates capabilities and owns durable jobs.
set -o pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${JUST_ALOUD_PYTHON:-$HOME/.local/share/just-aloud/venv/bin/python3}"
[ -x "$PY" ] || { printf 'runtime_unavailable\n' >&2; exit 2; }
WORK=$(mktemp -d "${TMPDIR:-/tmp/}just-aloud-headless.XXXXXXXXXX") || exit 2
TMP_FILE=""; TMP_DIR=""; _SECRET_HEADER_FILE=""
cleanup_headless() {
    [ -z "${_CURL_PID:-}" ] || kill "$_CURL_PID" 2>/dev/null
    [ -z "${_DAEMON_PID:-}" ] || { pkill -P "$_DAEMON_PID" 2>/dev/null; kill "$_DAEMON_PID" 2>/dev/null; }
    [ -z "$_SECRET_HEADER_FILE" ] || rm -f "$_SECRET_HEADER_FILE"
    [ -z "$TMP_FILE" ] || rm -f "$TMP_FILE" "${TMP_FILE}.code"
    [ -z "$TMP_DIR" ] || rmdir "$TMP_DIR" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup_headless EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# This generated file contains shlex-quoted assignments only, never sourced user config.
"$PY" -c '
import json,math,re,shlex,sys
try:
 r=json.load(sys.stdin)
 assert isinstance(r,dict)
 def number(k,lo,hi,default):
  x=r.get(k,default)
  assert type(x) in (int,float) and math.isfinite(x) and lo<=x<=hi
  return x
 p=r["provider"]; assert p in ("local","elevenlabs")
 t=r["text"]; assert isinstance(t,str) and t.strip() and all(ord(c)>=32 or c in "\n\r\t" for c in t)
 v=r["voice_id"]; assert isinstance(v,str) and re.fullmatch(r"[A-Za-z0-9_-]+",v)
 m=r["model_id"]; assert isinstance(m,str) and re.fullmatch(r"[A-Za-z0-9_./-]+",m)
 o=r["output_path"]; assert isinstance(o,str) and o.startswith("/") and "\0" not in o
 speed=number("speed",.5 if p=="local" else .7,2 if p=="local" else 1.2,1)
 stability=number("stability",0,1,.5)
 assert m!="eleven_v3" or (speed==1 and stability in (0,.5,1))
 boost=r.get("use_speaker_boost",True); assert type(boost) is bool
 loc=r.get("pronunciation_dictionary_locators",[])
 assert isinstance(loc,list) and len(loc)<=3
 for x in loc:
  assert isinstance(x,dict) and set(x)<= {"pronunciation_dictionary_id","version_id"}
  assert isinstance(x.get("pronunciation_dictionary_id"),str)
  assert all(isinstance(y,str) and re.fullmatch(r"[A-Za-z0-9_-]+",y) for y in x.values())
 vals={"TEXT":t,"TTS_BACKEND":p,"VOICE_ID":v,"LOCAL_VOICE":v,"MODEL_ID":m,
 "SPEED":speed,"LOCAL_SPEED":speed,"STABILITY":stability,
 "SIMILARITY_BOOST":number("similarity_boost",0,1,.75),"STYLE":number("style",0,1,0),
 "USE_SPEAKER_BOOST":str(boost).lower(),"OUTPUT_PATH":o,
 "JUST_ALOUD_OMIT_STYLE":"1" if "style" not in r else "0",
 "JUST_ALOUD_OMIT_BOOST":"1" if "use_speaker_boost" not in r else "0",
 "PRONUNCIATION_DICTIONARY_LOCATORS":json.dumps(loc) if loc else ""}
 for k,v in vals.items(): print(k+"="+shlex.quote(str(v)))
except Exception:
 print("invalid_generation_request",file=sys.stderr); sys.exit(2)
' > "$WORK/request.sh" || exit 2
source "$WORK/request.sh"
[ ! -e "$OUTPUT_PATH" ] && [ ! -L "$OUTPUT_PATH" ] || { printf 'output_exists\n' >&2; exit 2; }
VENV_PYTHON="$PY"
if [ "$TTS_BACKEND" = local ]; then
    VENV_PYTHON="$HOME/.local/share/just-aloud/venv/bin/python3"
    [ -x "$VENV_PYTHON" ] || { printf 'runtime_unavailable\n' >&2; exit 1; }
fi
LOG_FILE=/dev/null
TTS_SERVER_SCRIPT="$SCRIPT_DIR/tts_server.py"
[ -f "$TTS_SERVER_SCRIPT" ] || TTS_SERVER_SCRIPT="$SCRIPT_DIR/just-aloud-tts-server.py"
TTS_SOCK="${TTS_SOCK:-$HOME/.local/share/just-aloud/tts.sock}"
export JUST_ALOUD_STRICT_GENERATION=1
export JUST_ALOUD_REQUEST_TIMEOUT="${JUST_ALOUD_REQUEST_TIMEOUT:-600}"
source "$SCRIPT_DIR/speech-backend.sh"
if [ "$TTS_BACKEND" = local ]; then
    run_local_tts >/dev/null 2>&1 || { printf 'local_generation_failed\n' >&2; exit 1; }
else
    # Reuses the app credential. The value never leaves this process except in
    # the private curl header file removed on success, failure and cancellation.
    ELEVENLABS_API_KEY="${ELEVENLABS_API_KEY:-$(/usr/bin/security find-generic-password -a just-aloud -s just-aloud-api-key -w 2>/dev/null)}"
    export -n ELEVENLABS_API_KEY
    [ -n "$ELEVENLABS_API_KEY" ] || { printf 'credential_unavailable\n' >&2; exit 1; }
    case "$ELEVENLABS_API_KEY" in *$'\n'*|*$'\r'*) printf 'credential_invalid\n' >&2; exit 1 ;; esac
    run_elevenlabs_tts "$TEXT" >/dev/null 2>&1 || {
        printf 'cloud_generation_failed http=%s transport=%s\n' "${HTTP_CODE:-0}" "${CURL_EXIT:-0}" >&2
        exit 1
    }
fi
# Exclusive creation prevents accidental overwrites, including dangling symlinks.
"$PY" -c 'import os,shutil,sys
try:
 with open(sys.argv[1],"rb") as src, open(sys.argv[2],"xb") as dst: shutil.copyfileobj(src,dst)
 os.chmod(sys.argv[2],0o600)
except Exception:
 print("audio_copy_failed",file=sys.stderr); sys.exit(1)
' "$TMP_FILE" "$OUTPUT_PATH"
