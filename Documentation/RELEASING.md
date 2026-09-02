# Local release workflow

Build only from a clean, recorded source commit after the verification suite and
GitHub CI pass. Use an existing Developer ID identity and notarytool Keychain
profile. Do not export signing keys or put credentials in source or arguments.

```bash
./scripts/verify.sh
./scripts/build.sh
./scripts/sign.sh
./scripts/package.sh
NOTARY_PROFILE="<existing Keychain profile>" ./scripts/notarize.sh
python3 -m venv build/packaging
build/packaging/bin/pip install -r scripts/packaging-requirements.txt
PACKAGING_PYTHON=build/packaging/bin/python ./scripts/package-dmg.sh
NOTARY_PROFILE="<existing Keychain profile>" ./scripts/notarize-dmg.sh artifacts/Just-Aloud-1.0.0.dmg
```

Notarization must report Accepted. Inspect both notary logs, validate the stapled
app and DMG, mount the image read-only, inspect Finder, and test copying into
Applications. Verify codesign, Gatekeeper, and stapling on the copied application.
The DMG checksum is generated only after stapling and contains a filename, never
a build-machine path. Keep notary logs and artifacts out of Git.

Publish an explicit tag on the verified source commit. Upload the DMG and its
checksum, download both again, and compare bytes. Update the separate Homebrew
tap with that exact DMG URL and SHA-256; run style, audit, livecheck, install,
uninstall, and reinstall without zap. Preserve existing user data and Speak11.

## Private-data-free UI inspection

The production app supports `JUST_ALOUD_OFFLINE_PREVIEW=1` for UI inspection:
credential reads/writes, cloud lookups, API-key validation, speech hotkeys, and
local model startup are disabled. Use it together with an isolated
`JUST_ALOUD_CONFIG_DIR` and `JUST_ALOUD_DEFAULTS_SUITE`. This shows real native UI
with Credits unavailable instead of exposing an account balance. A fresh defaults
suite exercises Welcome on first launch. Never use personal voice libraries or
keys in repository screenshots. Normal launches do not use this mode.

Report automated, offline UI, live-provider, architecture, and OS test coverage
separately. Do not spend synthesis credits solely for release validation without
the account owner's permission.
