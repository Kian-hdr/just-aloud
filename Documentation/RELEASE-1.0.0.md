# Just Aloud 1.0.0

The first stable Just Aloud re-release brings native macOS playback controls,
a persistent voice library, and a compact, organized menu to the Speak11-derived
selected-text reader.

## Highlights

- Pause, resume, stop, seek ±10 seconds, adjust speed, and download complete WAV
  recordings without extra synthesis requests.
- A 0–5-second sentence-pause slider and waveform animation only during audible
  playback.
- Custom voice names, persistent selection, click-to-copy IDs, and inline removal.
- Configuration directly under Settings, with a persistent read-only credit
  usage row above it. Large balances compact without widening the menu.
- Cached usage appears immediately. Background GET requests refresh usage after
  generation and when opening the menu; failures retain a labeled stale balance.
- Fixed multi-paragraph truncation without Python, and visible errors for failed
  later synthesis chunks. Incomplete recordings never replace completed ones.
- Adaptive icon, light/dark Welcome and About, Open at Login, and no automatic
  repeated Accessibility prompts.

## Installation

Download `Just-Aloud-1.0.0.dmg`, open it, and drag Just Aloud into Applications.
Eject the disk image and open the installed app. No installation script is needed.

Or use the separate Homebrew tap:

```bash
brew tap Kian-hdr/tap
brew install --cask just-aloud
```

Version 1.0.0, build 3. Universal Apple Silicon/Intel executables target macOS 13
or later. Runtime testing is on Apple Silicon, macOS 26.6.2; older macOS and Intel
hardware have not been live-tested. Optional local Kokoro requires Apple Silicon.
Automated provider tests use mocks and do not consume ElevenLabs credits.

Just Aloud is created and maintained by Kian Konrad Tajbakhsh, based on Speak11
by Stefano Martiniani. This is an independent, unofficial derivative, not
affiliated with or endorsed by Speak11 or ElevenLabs. Source remains under the
Unlicense; Just Aloud brand artwork is © 2026 Kian Konrad Tajbakhsh, all rights
reserved. Dependencies retain their respective licenses.
