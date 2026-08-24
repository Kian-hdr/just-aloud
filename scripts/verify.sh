#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
bash -n just-aloud.sh install-local.sh install.command uninstall.command release.sh scripts/*.sh
python3 -m py_compile normalize.py tts_server.py
./tests/enhanced-test.sh
./tests/distribution-test.sh
bash tests/test.sh --fast
./scripts/scan-secrets.sh
./scripts/scan-personal-data.sh
cmp LICENSE <(git show v1.1.0:LICENSE)
git diff --check
printf 'PASS: verification suite\n'
