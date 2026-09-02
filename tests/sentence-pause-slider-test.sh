#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /private/tmp/just-aloud-slider-test.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/runtime/config" "$TEST_ROOT/modules"
xcrun swiftc -DTESTING -module-cache-path "$TEST_ROOT/modules" \
    "$ROOT/JustAloud.swift" -o "$TEST_ROOT/slider-test"
JUST_ALOUD_CONFIG_DIR="$TEST_ROOT/runtime/config" JUST_ALOUD_TEST_RUNTIME_DIR="$TEST_ROOT/runtime" \
    "$TEST_ROOT/slider-test" --test-sentence-pause-slider
