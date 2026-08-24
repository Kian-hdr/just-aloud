# Security policy

## Supported versions

Security fixes are provided for the latest published Just Aloud release.

## Reporting a vulnerability

Use the repository's enabled GitHub private vulnerability-reporting channel.
Do not open a public issue containing API keys, voice IDs, personal text,
Keychain output, or exploit details.

Include the affected version, macOS version, reproduction steps, impact, and
the smallest non-sensitive diagnostic excerpt that demonstrates the issue.

## Security boundaries

- ElevenLabs API keys are stored as generic passwords in macOS Keychain.
- Configuration files contain preferences and voice IDs, never API keys.
- Selected text is sent to ElevenLabs only when a cloud backend is active.
- Local Kokoro synthesis runs locally after downloading its dependencies and
  model files.
- Migration copies allowlisted settings and Keychain data without deleting or
  changing the source installation.
- Release archives, signing material, notarization credentials, local configs,
  logs, caches, and user data are excluded from Git.
