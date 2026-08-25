# Third-party notices and dependency audit

Audit date: 2026-08-25

The repository does not vendor a Python environment, model weights, a
standalone Python distribution, Apple frameworks, or ElevenLabs code. Optional
local-TTS components are downloaded into the user's private data directory.

## Baseline and platform

| Component | Version or source | License or terms | Distribution status |
|---|---|---|---|
| Speak11 | v1.1.0, `efc02de…` | Unlicense | Source-derived; attribution preserved |
| Swift and Xcode toolchain | Apple Xcode 26.6 used for RC | Apple license | Build-time only |
| AppKit/Cocoa, ApplicationServices, CoreAudio, AVFoundation, Foundation, Security | macOS SDK | Apple platform terms | System frameworks, not bundled |
| ElevenLabs API | `api.elevenlabs.io` | ElevenLabs service terms | External network service |

## Repository automation

The CI and release definitions pin `actions/checkout` v4.3.1 to commit
`34e114876b0b11c390a56381ad16ebd13914f8d5`, an MIT-licensed GitHub Action. No
action source is vendored into release artifacts. GitHub's hosted runner and
`GITHUB_TOKEN` remain governed by GitHub's service terms.

## Direct and resolved Python components

These are the versions audited for the optional local TTS and normalization
paths. The final release audit report records the resolver output and installed
metadata.

| Package | Audited version | Declared license |
|---|---:|---|
| mlx-audio | 0.4.8 | MIT |
| soundfile | 0.14.0 | BSD-3-Clause |
| sounddevice | 0.5.6 | MIT |
| scipy | 1.18.1 | BSD-3-Clause plus bundled-component notices |
| loguru | 0.7.3 | MIT |
| misaki | 0.8.4 | Apache-2.0 |
| num2words | 0.5.14 | LGPL-2.1-or-later |
| spacy | 3.8.16 | MIT |
| phonemizer-fork | 3.3.2 | GPL-3.0-or-later |
| espeakng-loader | 0.2.4 | No license declared in inspected package metadata |
| pysbd | 0.3.4 | MIT |
| ftfy | 6.3.1 | Apache-2.0 |
| pylatexenc | 2.11 | MIT |

Transitive packages brought in by `mlx-audio`, spaCy, SciPy, and their platform
wheels remain governed by their own metadata and included license files. The
complete resolved inventory is generated as `DEPENDENCY_LICENSE_REPORT.md` by
`scripts/audit-dependencies.sh`.

## Downloaded runtime assets

| Component | Version or reference | Finding |
|---|---|---|
| Kokoro MLX model | `mlx-community/Kokoro-82M-bf16` | Apache-2.0 stated by the model card |
| python-build-standalone | CPython 3.12 distribution selected by the installer | Composite CPython and bundled-component licenses; not committed |

## Distribution finding

Source distribution and a thin native app that downloads optional local-TTS
components do not relicense those components. A release must not bundle the
local Python environment or model cache.

`espeakng-loader` has no declared license in the inspected package metadata.
This is a release blocker for any artifact that bundles that package. The
Just Aloud native release does not bundle it. GPL and LGPL packages
are also downloaded separately and must not be silently folded into a
proprietary prebuilt runtime.

This inventory is an engineering audit, not legal advice.
