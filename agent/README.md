# Just Aloud local agent connector

A stdio MCP server exposes Just Aloud's existing ElevenLabs and Kokoro generation
helpers and native WAV exporter. It opens no TCP port and never drives the UI.
The menu-bar app and connector source the same `speech-backend.sh`. Normal app
clipboard normalization, playback, global toggle and fallback are outside the
connector path. App preferences and Keychain account `just-aloud`, service
`just-aloud-api-key`, are reused; presets do not change app preferences.

## Local installation

The bundled connector requires macOS 13+ and Python 3.9+. It uses only Python's
standard library. Optional local Kokoro narration additionally requires the
existing Just Aloud local runtime on Apple Silicon. Python is not bundled; install
it from [python.org](https://www.python.org/downloads/macos/) if needed.

In a build containing this feature, open **Settings → AI Connector**, choose
**Install Connector**, then copy the client setup instructions. Installation is
local and does not register a client or make a provider request. Published older
releases may not contain this section yet.

For Codex, run the setup command copied by Settings, then start a fresh agent
session. Other local MCP clients can use the copied JSON stdio configuration.
The app cannot determine whether an assistant is currently attached. Installation
status is separate from client configuration and connection status. The generic
stdio protocol is tested; no current end-to-end client integration is claimed.

Source developers can use:

```sh
./scripts/build.sh
./scripts/install-agent.sh
codex mcp add just-aloud -- "$HOME/.local/bin/just-aloud-agent"
```

Downloaded-app users do not need the developer checkout, Swift source or Xcode.
The installer and connector resources travel inside the app bundle. Installation
snapshots them privately under `~/.local/share/just-aloud/agent-connector`, and
creates `~/.local/bin/just-aloud-agent`. The launcher uses the selected Python
interpreter and the installed runtime, never a developer checkout path. Update
by installing again from the newer app. Existing runtime and launcher backups
remain next to that directory as `agent-connector.backup.*`; job data is separate
and preserved. Keep backups until the new installation is verified.

[`capabilities.json`](capabilities.json) supplies Settings and `discover` with the
same feature descriptions, requirements, examples and local voice catalog.

## Agent requests

- “Find the warm British voices in Just Aloud. Generate this wording naturally
  with the voice I select at 1.1× native speed, then save it to my Downloads.”
- “Preview this paragraph with Sarah using Multilingual v2 at 1.0×.”
- “Save that voice and delivery as `Document narrator`, then reuse it for this text.”
- “Check that narration job, cancel it if it is still running, and keep earlier exports.”

An agent should call `discover`, resolve the voice with `search_voices`, then
`generate` with the stable ID. Preserve every supplied word; never rewrite or add
audio tags without an explicit request. Match the requested voice exactly; ask
for selection if several names match. Select `local` or `elevenlabs` explicitly,
particularly when app preferences use `auto`. Provider errors never trigger fallback.

```json
{
  "idempotency_key": "my-narration-v1",
  "text": "Your exact narration goes here.",
  "preset": "natural-narration",
  "settings": {
    "provider": "elevenlabs",
    "voice_id": "ID_RETURNED_BY_SEARCH",
    "model_id": "eleven_multilingual_v2",
    "speed": 1.1
  }
}
```

Poll `get_job` with the returned `job_id`; on completion use `export_audio` with
an absolute `.wav` path. The destination directory must exist. Existing files,
including symlinks, are never overwritten. Tool results include duration, sample
rate, channels, bit depth and effective native/post-processing settings.
`preview: true` limits input to 500 characters, without silently truncating it.

## Tools and supported delivery controls

| Tool | Purpose |
| --- | --- |
| `discover` | App defaults, supported models/settings, local runtime presence |
| `search_voices` | Account voices or app-curated Kokoro voices; name/description/ID search |
| `generate` | Preview or narration, returns an asynchronous job |
| `save_preset`, `list_presets` | Named resolved voice settings and natural template |
| `get_job`, `cancel_job` | Progress, effective settings, results, cancellation |
| `export_audio` | Export completed WAV without another provider call |

`natural-narration` uses neutral provider controls, not text rewriting: native
speed 1.0; ElevenLabs stability 0.5 and similarity 0.75 where exposed. Multilingual
v2 also uses style 0 and speaker boost. This is a starting point for natural
narration, not a guarantee of subjective voice quality. Override speed explicitly.

- **Multilingual v2:** native speed 0.7–1.2, stability, similarity, style, speaker boost.
- **Flash/Turbo v2.5:** native speed 0.7–1.2, stability and similarity. No style/boost.
- **v3:** the current shared Just Aloud backend exposes stability 0/0.5/1 and no
  native speed adjustment, similarity, style or speaker boost. This is a connector
  limit, not a claim about every current ElevenLabs interface.
- **Local Kokoro:** app-curated stable English voice IDs and native speed 0.5–2.
- **Explicit time stretching:** `post_speed` 0.5–4 uses the app's pitch-preserving
  exporter. It defaults to 1.0 and is never silently substituted for native speed.
- **Pronunciation:** cloud `pronunciation_dictionary_locators` accepts up to three
  existing dictionary/version pairs. Dictionary creation is outside this tool set;
  dictionary rules and phoneme support depend on the provider/model. Unsupported
  requests fail at the provider. Local pronunciation controls are not exposed.
- **Pauses:** supply `segments` instead of `text`, each with exact `text` and
  `pause_after_ms` 0–5000. The last segment must have no trailing pause. Pauses are
  inserted by the existing offline exporter and retain their real duration.
  Existing punctuation and explicitly supplied provider tags remain unchanged.

The model list is the app's supported subset, not the provider's entire catalog.
Cloud voice/model metadata is cached for five minutes; generation validates live
model capability flags and voice identity. Local model connections and loaded
weights are reused through the existing Unix-socket daemon. Cloud metadata uses
HTTP keep-alive; synthesis retains Just Aloud's curl-per-chunk implementation.
Long text is chunked at up to 4,000 characters, preserving all characters; use
explicit segments for intentional pacing. Cross-chunk prosody may differ from one
continuous provider request. Maximum request is 50,000 characters / 200 segments.

## Jobs, privacy and failure recovery

Cloud synthesis sends supplied text and voice settings to ElevenLabs and uses its
credits. Local Kokoro synthesis stays on this Mac after model/dependency downloads.
The connector never installs models or switches providers automatically.

Reuse the same idempotency key for retries with identical text/settings. It returns
the same job even after failure or restart; changed content with that key is an
error. A new key deliberately creates new work and can incur another charge.
Do not automatically retry an uncertain provider timeout. Completed raw audio,
WAV results, presets and deduplication records persist privately under
`~/.local/share/just-aloud/agent`, with owner-only permissions. Source text is not
stored in the job database; audio itself contains the narration. No automatic
retention/deletion is applied.

Jobs run while the MCP process remains alive. Closing its stdin or terminating it
cancels active work; completed results survive. Abrupt SIGKILL/crashes may leave
interrupted status until read, and accepted cloud requests may still be billed.
Cancellation stops this job's child process group, never the app's playback.
Progress is completed chunks plus export, not provider token-level progress.

Remove discovery with `codex mcp remove just-aloud`. Keep the job directory to
preserve results. Use codex-recovery to trash the launcher/runtime when removal is
wanted; restore a stashed runtime/config if rolling back. The source diff is
uncommitted and no release is published by this workflow.

## Verification

```sh
python3 agent/test_server.py
# Requires a fresh build; uses a disposable user home, with no paid calls:
python3 agent/test_install.py
./scripts/verify.sh
# Explicit cloud smoke test; generates short samples using the saved credential:
python3 agent/verify_live.py --cloud --output-dir /absolute/private/output-directory
```

The live verifier drives actual JSON-RPC tool calls through shared generation and
WAV export, checks stable voice IDs, 1.0/1.1 native speeds, another voice/preset,
explicit pauses and duplicate-request reuse. Unit tests cover strict validation,
protocol framing, real child-process cancellation, failure reuse and safe export.
Native app appearance/accessibility and other OS versions require separate UI QA.

Sources: [MCP stdio transport](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports),
[Codex MCP configuration](https://developers.openai.com/codex/mcp/),
[ElevenLabs model capabilities](https://elevenlabs.io/docs/api-reference/models/list).

The bundle-install test verifies fresh setup, upgrades with retained backups,
rollback after an injected promotion failure, private permissions, and stdio
discovery after the original app resource directory is removed. The voice catalog
test prevents packaged local voices from drifting from the native app catalog.

### Local validation, 2026-09-21

The narration-only Settings/setup implementation passed the universal macOS 13
build, nine connector contract tests, isolated bundled installation/upgrade and
injected-failure rollback, 117 native menu checks, existing distribution tests,
enhanced checks, and repository secret/personal-data scans. Native rendering of
the connector section was inspected in dark and expanded light appearances using
an isolated AppKit/SwiftUI fixture (expanded state seeded by the fixture).
Cross-app click automation was unavailable because macOS denied assistive access.
No new cloud generation, client-host end-to-end session, local Kokoro synthesis,
signing, notarization, publication or installed-app replacement was performed.
The app's existing narration behavior and its process-bound active jobs remain.
