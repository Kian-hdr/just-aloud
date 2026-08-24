#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${AUDIT_OUTPUT:-$ROOT/build/dependency-audit}"
PYTHON="${AUDIT_PYTHON:-}"
if [ -z "$PYTHON" ]; then
    PYTHON=$(command -v python3.12 || command -v python3)
fi
mkdir -p "$OUT"
"$PYTHON" -m pip install --dry-run --ignore-installed --report "$OUT/pip-resolver-report.json" \
    'mlx-audio==0.4.8' soundfile sounddevice scipy loguru \
    'misaki==0.8.4' num2words spacy phonemizer-fork espeakng_loader pysbd \
    'ftfy==6.3.1' 'pylatexenc==2.11'
"$PYTHON" - "$OUT/pip-resolver-report.json" "$OUT/licenses.tsv" "$ROOT/DEPENDENCY_LICENSE_REPORT.md" <<'PY'
import json, sys, urllib.request
report, output, markdown = sys.argv[1:]
resolved = json.load(open(report, encoding="utf-8"))["install"]
rows = []
verified_license_overrides = {
    "fsspec": "BSD-3-Clause (upstream LICENSE at tag 2026.7.0)",
}
for item in resolved:
    name = item["metadata"]["name"]
    version = item["metadata"]["version"]
    with urllib.request.urlopen(f"https://pypi.org/pypi/{name}/{version}/json", timeout=20) as response:
        info = json.load(response)["info"]
    value = (info.get("license_expression") or info.get("license") or "").strip()
    if not value:
        classifiers = [
            entry.removeprefix("License :: ")
            for entry in info.get("classifiers", [])
            if entry.startswith("License :: ")
        ]
        value = "; ".join(classifiers) or "UNDECLARED"
    value = verified_license_overrides.get(name.lower(), value)
    project_urls = info.get("project_urls") or {}
    source = (project_urls.get("Source") or project_urls.get("Source Code") or
              project_urls.get("Repository") or project_urls.get("Homepage") or
              f"https://pypi.org/project/{name}/{version}/")
    rows.append((name, version, source, value.replace("\t", " ").replace("\n", " ")))
with open(output, "w", encoding="utf-8") as handle:
    handle.write("name\tversion\tlicense\n")
    for name, version, source, license_value in sorted(rows, key=lambda value: value[0].lower()):
        handle.write("\t".join((name, version, license_value)) + "\n")
with open(markdown, "w", encoding="utf-8") as handle:
    handle.write("# Dependency license report\n\n")
    from datetime import date
    handle.write(f"Generated on {date.today().isoformat()} by `scripts/audit-dependencies.sh`. ")
    handle.write("Versions are the resolver result for the optional local-TTS install set.\n\n")
    handle.write("| Package | Version | Source | License finding |\n")
    handle.write("|---|---:|---|---|\n")
    for name, version, source, license_value in sorted(rows, key=lambda value: value[0].lower()):
        compact = " ".join(license_value.split())
        if len(compact) > 160:
            compact = compact[:157] + "..."
        compact = compact.replace("|", "\\|")
        source = source.replace("|", "%7C")
        handle.write(f"| {name} | {version} | [project]({source}) | {compact} |\n")
    undeclared = [name for name, _, _, license_value in rows if license_value == "UNDECLARED"]
    handle.write("\n## Findings\n\n")
    handle.write(f"- Resolved packages: {len(rows)}.\n")
    handle.write(f"- Packages without a PyPI license declaration or license classifier: {len(undeclared)}")
    if undeclared:
        handle.write(" (`" + "`, `".join(sorted(undeclared, key=str.lower)) + "`).\n")
    else:
        handle.write(".\n")
    handle.write("- The signed native application does not contain this Python environment; it is an optional, separate download.\n")
    handle.write("- `phonemizer-fork` is GPL-3.0-or-later and `num2words` is LGPL-2.1-or-later. Do not bundle the optional runtime into a differently licensed binary without a separate compliance review.\n")
    handle.write("- This generated metadata inventory is an engineering aid, not legal advice.\n")
PY
printf 'Dependency audit written to %s\n' "$OUT"
