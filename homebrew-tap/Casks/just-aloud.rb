cask "just-aloud" do
  version "0.9.0"
  sha256 "1ab1f5469e7dbaf538327c435d83830d0cdd00d9e5edfdddce2f8e85b7d64be1"

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
