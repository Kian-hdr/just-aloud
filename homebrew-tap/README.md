# Homebrew tap

The authoritative cask lives in the separate
[Kian-hdr/homebrew-tap](https://github.com/Kian-hdr/homebrew-apps/blob/main/Casks/just-aloud.rb)
repository. It is updated after the final notarized artifact and checksum exist,
so a duplicate cask cannot become stale or introduce a source/checksum cycle.

```bash
brew tap kian-hdr/apps
brew install --cask just-aloud
```
