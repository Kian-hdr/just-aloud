# Changelog

## 1.0.0 (build 3)

- First stable Just Aloud re-release, with universal macOS executables and a
  signed, notarized drag-to-Applications disk image.

- Fixed multi-paragraph truncation in both installed speech-script entry points.
  Sentence records now safely encode embedded newlines and tabs, including the
  missing/failed-Python fallback. Later-chunk failures are visible and do not
  replace complete recordings with partial audio.
- Sentence pauses also work without Python through a built-in macOS fallback.
- Restored the original menu width; long credit balances compact without hiding
  the percentage, while hover and VoiceOver retain exact totals.
- Updated the persistent credit-usage status to show used / total credits and
  percentage, refresh in the background on open and generation completion, and
  retain stale balances on failure. Usage requests never invoke synthesis.
- Added a download arrow for offline WAV export of already-generated audio,
  retaining speed and sentence pauses without additional synthesis requests.
  Downloads requested during generation wait for a complete recording.
- Retained the latest successful recording until app quit, preserving it when
  a newer request fails or is cancelled. Explicit downloads are never cleaned up.
- Grouped listening controls in the main menu and configuration directly under
  Settings, including Speech Engine, Model, Stability, Similarity, API Key,
  and Open at Login. Removed redundant advanced-settings nesting. Credit usage
  stays in a persistent main-menu status row directly above Settings.
- Removed Style and Speaker Boost from the main menu without resetting saved
  preferences. Unsupported v3 options are omitted from requests.

- Replaced sentence-pause presets with a native 0–5 second slider in 50 ms
  steps, a live value, and exact millisecond entry by clicking the value.
  Dragging keeps the menu open and updates active playback without restarting it.

- Prevented recurring Accessibility dialogs by removing launch-time prompting
  and rechecking existing authorization before a user-initiated request.
- Silently detect Accessibility grants made in System Settings and limit the
  user-initiated system prompt to once per session.
- Removed the persistent Accessibility warning from the playback menu.
  Permission setup remains available in the welcome window through About.
- Restored native waveform template rendering and standard menu-bar sizing,
  with a stable autosave name and no forced positioning or tint overrides.
- Documented a macOS Tahoe Control Center association problem that can hide
  the icon despite Just Aloud being enabled in Menu Bar settings.
- Added a native, user-controlled Open at Login menu item using Apple's
  ServiceManagement framework.
- Fixed the sentence-pause control so the chosen duration is real elapsed
  silence rather than shrinking as playback speed increases.
- Added clear pause presets, a validated custom value, live updates for active
  playback, and matching behavior in the fallback audio player.

## v1.1.0

### Highlights

**Gapless playback.** A native Swift audio queue player replaces per-sentence `afplay` calls, cutting the gap between sentences from ~970ms to ~30ms. A configurable pause (default 400ms at 1× speed) restores natural speech rhythm and scales automatically with your speed setting. Adjustable from the menu bar -- click "Sentence Pause" and type any value in milliseconds.

**Text normalizer.** A new 6-phase Python preprocessor turns PDFs, LaTeX, and Markdown into clean, speakable text. It combines general-purpose normalization (currency, abbreviations, Unicode cleanup) with domain-specific handling for technical and scientific content (LaTeX math, SI units, Greek letters). Separate front-ends for PDF, LaTeX, and Markdown input clean up format-specific artifacts before the text reaches the TTS engine.

### New features

- **Audio queue player** (`just-aloud-audio.swift`): gapless sentence playback via `AVAudioPlayer` queue with `CoreAudio` mute detection, replacing the old afplay-per-sentence approach
- **Sentence pause**: configurable inter-sentence silence (0--1000+ ms) that scales inversely with playback speed; free-form input from the menu bar
- **Text normalizer** (`normalize.py`): 1200-line preprocessor with general and domain-specific rules:
  - *General*: currency (`$1.5M` reads as "1.5 million dollars"), abbreviations (`e.g.`, `i.e.`, `et al.`), math symbols (`±`, `×`, `∞`), Unicode cleanup via ftfy
  - *Scientific*: LaTeX math environments (`equation`, `align`, `matrix`, `cases`, fractions, superscripts, subscripts), SI units and compound units (`kg/m³`, `kPa`, `nm`, `°C`, `kcal/mol`), Greek letters (`\alpha`, `\beta`, including diacritics and final sigma), Miller crystallographic indices (`(111)`, `[110]`), set theory symbols (`∈`, `⊂`, `∪`)
  - *PDF front-end*: rejoins mid-word line breaks, strips superscript citations, removes page headers
  - *LaTeX front-end*: converts math environments, commands, and macros into spoken text
  - *Markdown front-end*: strips YAML front matter, wikilinks, callout syntax, inline code, HTML tags

### Performance

- Audio queue player eliminates ~970ms inter-sentence overhead (down to ~30ms hardware latency)
- Test suite runs in ~36s, down from ~2min, with section filtering (`--fast`, `--section`)
- ftfy is now a required dependency for reliable Unicode normalization

### Bug fixes

- Bare URLs (`go.nature.com/4rzrnyx`) verbalized as "go dot nature dot com slash 4rzrnyx" so local TTS reads dots and slashes correctly
- PDF mid-word newlines: text copied from PDFs no longer has spurious line breaks inside words and sentences
- Compound hyphen rejoining across PDF line breaks
- Superscript citations glued to sentence-ending periods (e.g., `result.²³` now strips cleanly)
- Nested LaTeX environments (`\begin{equation}\begin{cases}...\end{cases}\end{equation}`)
- Nested bold/italic in Markdown (`***bold italic***`)
- `\left\langle` / `\right\rangle` bracket commands
- Chained equals signs in equations (`a = b = c`)
- Dollar signs inside math environments (`\$`)
- Scientific notation (`3\times10^{5}`, negative exponents)
- `\cfrac` (continuous fractions)
- Unit slash not triggering false positives on `s/he`
- Greek final sigma (`ς`) spoken as "sigma"
- Greek letters with tonos diacritics
- Star-prefixed lists not breaking italic regex
- siunitx edge cases and unit joining
- Denominator singular vs plural (`per mole` not `per moles`)
- Matrix environments inside equation wrappers
- `SCRIPT_DIR` ordering bug in just-aloud.sh
- Terminal no longer minimizes during install/uninstall

### Infrastructure

- Repo-local dev venv for the test suite
- Always uses the venv Python interpreter, never falls back to system python3
- `VENV_PYTHON` guards on `split_sentences` and `run_local_tts`
- Test suite expanded from ~200 to 1066 tests
- Profiling script (`tests/profile.sh`) for end-to-end pipeline timing

## v1.0.0

Initial release.
