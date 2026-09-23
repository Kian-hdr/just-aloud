#!/bin/bash
# Shared synthesis implementation for the menu-bar app and local agent connector.
# Source only: caller owns settings, validation, output lifecycle and cancellation.

start_tts_daemon() {
    local PY="$1"
    "$PY" "$TTS_SERVER_SCRIPT" </dev/null >> "$LOG_FILE" 2>&1 &
    local daemon_pid=$!
    # Wait for socket to appear (model loading can take 5-30s)
    local i=0
    while [ $i -lt 60 ]; do
        [ -S "$TTS_SOCK" ] && return 0
        if ! kill -0 "$daemon_pid" 2>/dev/null; then
            # Our daemon exited.  Two possibilities:
            #  a) Lock conflict — another daemon is running (exit 0).
            #     Its socket may not exist yet (still loading model).
            #  b) Real error (exit non-zero) — no daemon available.
            wait "$daemon_pid" 2>/dev/null
            local daemon_exit=$?
            if [ "$daemon_exit" -eq 0 ]; then
                # Lock conflict: wait for the other daemon's socket.
                while [ $i -lt 60 ]; do
                    [ -S "$TTS_SOCK" ] && return 0
                    sleep 0.5
                    i=$((i + 1))
                done
            fi
            return 1
        fi
        sleep 0.5
        i=$((i + 1))
    done
    return 1  # timed out
}

tts_daemon_request() {
    local text_json voice="${_VOICE:-bf_lily}" speed="${_SPEED:-1.00}" lang="${_LANG:-b}"
    text_json=$(json_encode "$TEXT")
    local req="{\"text\":${text_json},\"voice\":\"${voice}\",\"speed\":\"${speed}\",\"lang_code\":\"${lang}\"}"
    # nc -U on macOS silently drops responses from Unix sockets.
    # Use a python one-liner for reliable socket I/O (one fork, same as nc).
    local resp
    resp=$("$VENV_PYTHON" -c "
import os,socket,sys
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
s.settimeout(float(os.environ.get('JUST_ALOUD_REQUEST_TIMEOUT', '120')))
s.connect(sys.argv[1])
s.sendall(sys.argv[2].encode()+b'\n')
d=b''
while True:
    c=s.recv(4096)
    if not c:break
    d+=c
    if b'\n' in d:break
s.close()
sys.stdout.write(d.decode().strip())
" "$_SOCK" "$req" 2>/dev/null) || return 1
    # Parse audio_file from JSON response with bash string ops.
    # Python json.dumps adds a space after ":", so strip it.
    local audio_file="${resp#*\"audio_file\":}"
    audio_file="${audio_file# }"
    audio_file="${audio_file#\"}"
    audio_file="${audio_file%%\"*}"
    if [ -n "$audio_file" ] && [ -f "$audio_file" ]; then
        printf '%s' "$audio_file"
    else
        local msg="${resp#*\"message\":}"
        msg="${msg# }"
        msg="${msg#\"}"
        msg="${msg%%\"*}"
        printf '%s\n' "${msg:-daemon error}" >&2
        return 1
    fi
}

run_local_tts() {
    _GENERATED_WITH_V3=false
    local PY="${VENV_PYTHON}"
    if [ ! -x "$PY" ]; then
        echo "venv python not found at $PY" >> "$LOG_FILE" 2>/dev/null
        return 1
    fi
    {
        printf "\n[%s] run_local_tts\n" "$(date '+%Y-%m-%d %H:%M:%S')"
        echo "PY=$PY  VOICE=${LOCAL_VOICE:-bf_lily}  SPEED=$LOCAL_SPEED"
    } >> "$LOG_FILE" 2>/dev/null

    # Run a daemon request in background so `wait` is interruptible by SIGTERM
    # (same pattern as curl — bash 3.2 defers signals during foreground $()).
    # Sets caller's `audio_file` on success via dynamic scoping.
    _daemon_request_bg() {
        local _req_out
        _req_out=$(mktemp "${TMPDIR:-/tmp/}just-aloud_req_XXXXXXXXXX") || return 1
        _SOCK="$TTS_SOCK" _VOICE="${LOCAL_VOICE:-bf_lily}" \
            _SPEED="$LOCAL_SPEED" _LANG="${LOCAL_VOICE:0:1}" \
            tts_daemon_request > "$_req_out" 2>> "$LOG_FILE" &
        _DAEMON_PID=$!
        wait "$_DAEMON_PID" 2>/dev/null
        [ $? -eq 0 ] && audio_file=$(cat "$_req_out" 2>/dev/null)
        _DAEMON_PID=""
        rm -f "$_req_out"
    }

    local audio_file=""

    if [ "${JUST_ALOUD_STRICT_GENERATION:-0}" = "1" ]; then
        if [ ! -S "$TTS_SOCK" ]; then
            # The shared daemon must survive cancellation of this job group.
            "$PY" -c 'import subprocess,sys; subprocess.Popen([sys.argv[1],sys.argv[2]],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)' "$PY" "$TTS_SERVER_SCRIPT" || return 1
            local ready=0
            while [ "$ready" -lt 120 ] && [ ! -S "$TTS_SOCK" ]; do
                sleep 0.5
                ready=$((ready + 1))
            done
        fi
        [ -S "$TTS_SOCK" ] || return 1
        _daemon_request_bg
        [ -n "$audio_file" ] && [ -s "$audio_file" ] || return 1
        TMP_FILE="$audio_file"
        TMP_DIR="$(dirname "$audio_file")"
        return 0
    fi

    # Attempt 1: connect to existing daemon
    if [ -S "$TTS_SOCK" ]; then
        _daemon_request_bg
    fi

    # Attempt 2: start daemon and retry
    if [ -z "$audio_file" ] || [ ! -s "$audio_file" ]; then
        if start_tts_daemon "$PY" 2>> "$LOG_FILE"; then
            _daemon_request_bg
        fi
    fi

    # Success via daemon
    if [ -n "$audio_file" ] && [ -s "$audio_file" ]; then
        TMP_FILE="$audio_file"
        TMP_DIR="$(dirname "$audio_file")"
        echo "daemon: $audio_file" >> "$LOG_FILE" 2>/dev/null
        return 0
    fi

    # Fallback: direct invocation (cold start, slow but reliable)
    echo "daemon unavailable, falling back to direct invocation" >> "$LOG_FILE" 2>/dev/null
    TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp/}just_aloud_tts_XXXXXXXXXX")
    (cd "$TMP_DIR" && "$PY" -m mlx_audio.tts.generate \
        --model mlx-community/Kokoro-82M-bf16 \
        --text "$TEXT" \
        --voice "${LOCAL_VOICE:-bf_lily}" \
        --speed "$LOCAL_SPEED" \
        --lang_code "${LOCAL_VOICE:0:1}" \
        --file_prefix just-aloud \
        --audio_format wav \
        --join_audio 2>> "$LOG_FILE") &
    _DAEMON_PID=$!
    wait "$_DAEMON_PID" 2>/dev/null
    _DAEMON_PID=""
    TMP_FILE="$TMP_DIR/just-aloud.wav"
    [ -s "$TMP_FILE" ]
}

json_encode() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
}

run_elevenlabs_tts() {
    _GENERATED_WITH_V3=false
    [ "$MODEL_ID" != "eleven_v3" ] || _GENERATED_WITH_V3=true
    local sentence="$1"
    JSON_TEXT=$(json_encode "$sentence")
    if [ -z "$JSON_TEXT" ]; then
        return 1
    fi

    TMP_FILE=$(mktemp "${TMPDIR:-/tmp/}just_aloud_tts_XXXXXXXXXX")
    [ -z "$TMP_FILE" ] || [ ! -f "$TMP_FILE" ] && return 1

    local code_file="${TMP_FILE}.code"
    # Keep saved preferences intact, but omit unsupported v3 speaker boost.
    local boost_json=",\"use_speaker_boost\": ${USE_SPEAKER_BOOST}"
    local speed_json=",\"speed\": ${SPEED}"
    local similarity_json="\"similarity_boost\": ${SIMILARITY_BOOST},"
    local request_stability="$STABILITY"
    if [ "$MODEL_ID" = "eleven_v3" ]; then
        boost_json=""
        speed_json=""
        similarity_json=""
        request_stability=$(/usr/bin/perl -e 'print $ARGV[0] < .25 ? 0 : $ARGV[0] < .75 ? 0.5 : 1' "$STABILITY")
    fi
    case "$ELEVENLABS_API_KEY" in *$'\n'*|*$'\r'*) return 1 ;; esac
    local header_file
    header_file=$(mktemp "${TMPDIR:-/tmp/}just_aloud_header_XXXXXXXXXX") || return 1
    _SECRET_HEADER_FILE="$header_file"
    chmod 600 "$header_file"
    printf 'xi-api-key: %s\n' "$ELEVENLABS_API_KEY" > "$header_file"
    local style_json="\"style\": ${STYLE},"
    if [ "${JUST_ALOUD_STRICT_GENERATION:-0}" = "1" ]; then
        [ "${JUST_ALOUD_OMIT_STYLE:-0}" != "1" ] || style_json=""
        [ "${JUST_ALOUD_OMIT_BOOST:-0}" != "1" ] || boost_json=""
    fi
    local pronunciation_json=""
    if [ -n "${PRONUNCIATION_DICTIONARY_LOCATORS:-}" ]; then
        pronunciation_json=",\"pronunciation_dictionary_locators\":${PRONUNCIATION_DICTIONARY_LOCATORS}"
    fi
    curl -s -w "%{http_code}" \
        --max-time "${JUST_ALOUD_REQUEST_TIMEOUT:-30}" \
        -o "$TMP_FILE" \
        -X POST \
        "https://api.elevenlabs.io/v1/text-to-speech/${VOICE_ID}/stream" \
        -H "@$header_file" \
        -H "Content-Type: application/json" \
        -d "{
            \"text\": ${JSON_TEXT},
            \"model_id\": \"${MODEL_ID}\"${pronunciation_json},
            \"voice_settings\": {
                ${similarity_json}
                ${style_json}
                \"stability\": ${request_stability}
                ${boost_json}
                ${speed_json}
            }
        }" > "$code_file" &
    _CURL_PID=$!
    wait "$_CURL_PID" 2>/dev/null
    CURL_EXIT=$?
    rm -f "$header_file"
    _SECRET_HEADER_FILE=""
    _CURL_PID=""
    HTTP_CODE=$(cat "$code_file" 2>/dev/null)
    rm -f "$code_file"
    [ $CURL_EXIT -eq 0 ] && [ "$HTTP_CODE" = "200" ] && [ -s "$TMP_FILE" ]
}
