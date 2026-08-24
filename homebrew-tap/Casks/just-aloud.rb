cask "just-aloud" do
  version "REPLACE_WITH_RELEASE_VERSION"
  sha256 "REPLACE_WITH_RELEASE_SHA256"

  url "https://github.com/REPLACE_WITH_GITHUB_ACCOUNT/just-aloud/releases/download/v#{version}/Just-Aloud-#{version}.zip"
  name "Just Aloud"
  desc "Read selected text aloud with playback controls"
  homepage "https://github.com/REPLACE_WITH_GITHUB_ACCOUNT/just-aloud"

  depends_on macos: ">= :ventura"
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
    "~/Library/Services/Speak Selection with Just Aloud.workflow",
    "~/Library/Preferences/space.exlumina.justaloud.plist",
    "~/Library/Saved Application State/space.exlumina.justaloud.savedState",
  ]

  livecheck do
    url :url
    strategy :github_latest
  end
end
