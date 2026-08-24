#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
files=$(git ls-files -co --exclude-standard)
bad=0
hits=$(printf '%s\n' "$files" | xargs grep -InE \
    '(/Users/[A-Za-z0-9._-]+|/home/[A-Za-z0-9._-]+|[A-Za-z0-9._%+-]+@(gmail|icloud|me|outlook|protonmail)\.[A-Za-z]{2,}|CUSTOM_VOICE_IDS="[A-Za-z0-9_-]{16,}|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY)' \
    2>/dev/null | grep -v '^scripts/scan-personal-data.sh:' || true)
if [ -n "$hits" ]; then
    printf 'FAIL: possible personal or private data in working tree\n%s\n' "$hits"; bad=1
fi
for forbidden in "$HOME/.config" "$HOME/.local/share" "$HOME/Library"; do
    if printf '%s\n' "$files" | xargs grep -IlF "$forbidden" 2>/dev/null | grep -q .; then
        printf 'FAIL: machine-specific absolute path present: %s\n' "$forbidden"; bad=1
    fi
done
history_hits=$(git log -p --format= --all --no-ext-diff 2>/dev/null \
    | grep -E '(/Users/[A-Za-z0-9._-]+|/home/[A-Za-z0-9._-]+|[A-Za-z0-9._%+-]+@(gmail|icloud|me|outlook|protonmail)\.[A-Za-z]{2,}|CUSTOM_VOICE_IDS="[A-Za-z0-9_-]{16,})' \
    | head -20 || true)
if [ -n "$history_hits" ]; then
    printf 'FAIL: possible personal or private data in Git history\n%s\n' "$history_hits"; bad=1
fi
[ "$bad" -eq 0 ] || exit 1
printf 'PASS: no machine paths, private email addresses, custom voice values, or private keys detected in tree or history\n'
