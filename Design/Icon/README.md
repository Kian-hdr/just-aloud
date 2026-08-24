# Just Aloud icon source

The three layer SVGs are the editable 1024 × 1024 vector sources used by the
Icon Composer document. They deliberately contain no background plate,
rounded-square mask, baked shadow, text, Apple artwork, Speak11 artwork, or
ElevenLabs artwork.

- `listening-arc.svg`: listening silhouette and inner reflection
- `play.svg`: playback focal point
- `sound-waves.svg`: audible-output indication
- `just-aloud-default.svg`: composited fallback source
- `just-aloud-dark.svg`: dark-appearance source
- `just-aloud-mono.svg`: single-color source for mono and tinted previews

The generated bitmap in `../Concept/` is an ideation reference only. It is not
used in the application or release artifacts.

The build compiles `JustAloud.icon` with Apple's asset compiler. This creates
an appearance-aware `Assets.car` plus a generated `JustAloud.icns` fallback.
Copying only the fallback `.icns` disables Dark and Mono appearance switching.
