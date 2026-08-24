#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

tracked=$(git ls-files -co --exclude-standard)
bad=0

scan_pattern() {
    local label="$1" pattern="$2"
    local hits
    hits=$(printf '%s\n' "$tracked" | xargs grep -InE "$pattern" 2>/dev/null || true)
    if [ -n "$hits" ]; then
        printf 'FAIL: %s\n%s\n' "$label" "$hits"
        bad=1
    fi
}

scan_pattern "private key material" 'BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY'
scan_pattern "common cloud or service token" '(AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9]{20,}|sk_[A-Za-z0-9]{20,})'
scan_pattern "committed credential assignment" "(API_KEY|ACCESS_TOKEN|AUTH_TOKEN|SECRET_KEY)[[:space:]]*=[[:space:]]*['\"][A-Za-z0-9][A-Za-z0-9_./+=:-]{19,}['\"]"
voice_hits=$(printf '%s\n' "$tracked" | xargs grep -InE \
    "(VOICE_ID|CUSTOM_VOICE_IDS)[[:space:]]*=[[:space:]]*['\"][A-Za-z0-9_-]{16,}['\"]" \
    2>/dev/null | grep -vE \
    'pFZP5JQG7iQjIQuC4Bku|Xb7hH8MSUJpSbSDYk0k2|21m00Tcm4TlvDq8ikWAM|pNInz6obpgDQGcFmaJgB|AZnzlk1XvdvUeBnXmlld|TxGEqnHWrfWFTfGW9XjX|yoZ06aMxZJJ28mfd3POQ' || true)
if [ -n "$voice_hits" ]; then
    printf 'FAIL: custom or non-upstream ElevenLabs voice assignment\n%s\n' "$voice_hits"
    bad=1
fi

history_hits=$(git log -p --all --no-ext-diff 2>/dev/null \
    | grep -E '(BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9]{20,}|sk_[A-Za-z0-9]{20,})' \
    | head -20 || true)
if [ -n "$history_hits" ]; then
    printf 'FAIL: possible secret found in Git history\n%s\n' "$history_hits"
    bad=1
fi

history_voice_hits=$(git log -p --all --no-ext-diff 2>/dev/null \
    | grep -E "(VOICE_ID|CUSTOM_VOICE_IDS)[[:space:]]*=[[:space:]]*['\"][A-Za-z0-9_-]{16,}['\"]" \
    | grep -vE 'pFZP5JQG7iQjIQuC4Bku|Xb7hH8MSUJpSbSDYk0k2|21m00Tcm4TlvDq8ikWAM|pNInz6obpgDQGcFmaJgB|AZnzlk1XvdvUeBnXmlld|TxGEqnHWrfWFTfGW9XjX|yoZ06aMxZJJ28mfd3POQ' \
    | head -20 || true)
if [ -n "$history_voice_hits" ]; then
    printf 'FAIL: possible custom voice ID found in Git history\n%s\n' "$history_voice_hits"
    bad=1
fi

for path in $tracked; do
    case "$path" in
        *.app/*|*.dmg|*.pkg|*.zip|*.log|*.cache|*.bak|*.backup|*.pem|*.key|*.p12|*/config|.env|.env.*)
            printf 'FAIL: disallowed tracked artifact: %s\n' "$path"
            bad=1
            ;;
    esac
done

if [ "$bad" -ne 0 ]; then
    exit 1
fi
printf 'PASS: no secrets detected in the publishable tree or Git history; no disallowed artifacts tracked\n'
