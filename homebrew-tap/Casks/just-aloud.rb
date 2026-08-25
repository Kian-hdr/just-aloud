cask "just-aloud" do
  version "0.9.1"
  sha256 "6a873c8ff2ca8a552b14ed9f0879bd4cccec719ac143d26107d84cf161baf846"

  url "https://github.com/Kian-hdr/just-aloud/releases/download/v#{version}/Just-Aloud-#{version}.zip"
  name "Just Aloud"
  desc "Read selected text aloud with playback controls"
  homepage "https://github.com/Kian-hdr/just-aloud"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :ventura

  app "Just Aloud.app"

  uninstall quit: "space.exlumina.justaloud"

  zap trash: [
    "~/.config/just-aloud",
    "~/.local/bin/just-aloud",
    "~/.local/bin/just-aloud-audio",
    "~/.local/bin/just-aloud-install-local",
    "~/.local/bin/just-aloud-normalize.py",
    "~/.local/bin/just-aloud-tts-server.py",
    "~/.local/bin/just-aloud-uninstall",
    "~/.local/share/just-aloud",
    "~/Library/Preferences/space.exlumina.justaloud.plist",
    "~/Library/Saved Application State/space.exlumina.justaloud.savedState",
    "~/Library/Services/Speak Selection with Just Aloud.workflow",
  ]
end
