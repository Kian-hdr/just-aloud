#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /private/tmp/just-aloud-recording-test.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/modules"
xcrun swiftc -O -module-cache-path "$TEST_ROOT/modules" \
    "$ROOT/just-aloud-audio.swift" -o "$TEST_ROOT/just-aloud-audio"
xcrun swiftc -DTESTING -module-cache-path "$TEST_ROOT/modules" \
    "$ROOT/JustAloud.swift" -o "$TEST_ROOT/JustAloud"
python3 "$ROOT/tests/recording-export-test.py" "$TEST_ROOT/just-aloud-audio" "$TEST_ROOT/JustAloud"
python3 "$ROOT/tests/recording-shell-test.py" "$TEST_ROOT/just-aloud-audio"
python3 "$ROOT/tests/sentence-records-test.py" "$TEST_ROOT/just-aloud-audio"
