# Just Aloud changes

This file records the independent downstream work relative to
[Speak11 `v1.1.0`](https://github.com/smcantab/speak11/releases/tag/v1.1.0).

Baseline commit: `efc02de6b2c8be25d2845dbd66885aeb15b361d2`.

## Unreleased

- Stopped requesting Accessibility access automatically at launch. Permission
  prompting is now user-initiated and skips the prompt when access is already
  granted.
- Restored the menu-bar item explicitly at launch, retained the requested
  waveform symbol, and assigned a distinct visible default position instead
  of importing Speak11's conflicting position.
- Added a native Open at Login control that reflects enabled, disabled, and
  approval-required macOS states without changing the setting automatically.
- Fixed sentence-pause timing so the selected milliseconds remain exact at
  every playback speed and are also honored by the `afplay` fallback.
- Replaced the free-form-only pause control with a native preset submenu plus
  a validated custom value from 0 to 5000 milliseconds.
- Applied pause changes to an active audio queue at the next sentence boundary.

## 0.9.1

- Added a native first-launch welcome and setup window with adaptive icon,
  creator and Speak11 attribution, privacy summary, ElevenLabs API-key setup,
  Accessibility guidance, optional migration, licensing links, and a clear
  completion action.
- Added an About-window action for reopening Welcome & Setup at any time.
- Stored welcome completion only in the Just Aloud preferences namespace and
  added isolated first-launch/completion regression coverage.
- Clarified code-versus-brand licensing and acknowledged Codex only as a
  development-assistance tool.

## 0.9.0

### Playback

- Native pause/resume, stop, back 10 seconds, and forward 10 seconds controls.
- Pitch-preserving playback-speed slider from 0.7× to 3×.
- External playback state and control channels for the native audio queue.
- Menu-bar waveform animation only during audible playback. Generation,
  sentence pauses, pause, stop, and standby remain static.

### Voices

- Standard macOS Edit commands, including Command-V in voice-ID dialogs.
- Persistent library of multiple custom ElevenLabs voices.
- Voice-name lookup through the authenticated ElevenLabs voice endpoint.
- Voice name as the primary label and copyable ID as secondary text.
- Inline remove button and a unified radio-style selector for preset and custom
  cloud voices. Only one cloud voice can be active.
- Selection updates in place so the Voice menu stays open while comparing
  voices.

### Independent product

- Product, app bundle, executable, process, bundle ID, Quick Action, config,
  data, Keychain, runtime files, build output, and installer are renamed to
  Just Aloud namespaces.
- Safe opt-in migration copies compatible Speak11 or Speak11 Enhanced settings
  and Keychain credentials without revealing keys, removing data, or changing
  the original installation.
- Original application icon with editable Apple Icon Composer document,
  layered SVG sources, compiled adaptive Dark and Mono renditions, asset
  catalog, and `.icns` fallback.
- About window with creator credit, accurate Speak11 attribution, version/build,
  source, license, notices, copy-version, and migration actions.
- Reproducible local build, signing, packaging, notarization, verification,
  CI, scanning, and Homebrew-cask preparation.

### Distribution and licensing

- Upstream Unlicense text preserved byte-for-byte.
- Added attribution, licensing, brand, security, contribution, dependency, and
  release documentation.
- No signed app, executable, archive, credentials, user configuration, custom
  voice IDs, personal data, logs, caches, or backups are tracked.
