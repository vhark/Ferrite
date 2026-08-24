# Homebrew cask for Ferrite. This repository doubles as the tap:
#
#   brew tap vhark/ferrite https://github.com/vhark/Ferrite.git
#   brew install --cask ferrite
#
# version and sha256 are rewritten by scripts/release.sh on each release.
cask "ferrite" do
  version "0.11.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/vhark/Ferrite/releases/download/v#{version}/Ferrite-#{version}.zip"
  name "Ferrite"
  desc "Window layout manager: position persistence, workspaces, and magnet groups"
  homepage "https://github.com/vhark/Ferrite"

  depends_on macos: :ventura

  app "Ferrite.app"

  uninstall quit: "dev.ferrite.Ferrite"

  zap trash: [
    "~/Library/Application Support/Ferrite",
    "~/Library/Preferences/dev.ferrite.Ferrite.plist",
  ]

  caveats <<~EOS
    Ferrite drives windows through the Accessibility API. On first launch,
    grant it access under:
      System Settings > Privacy & Security > Accessibility

    Launch at Login is offered from Ferrite's own menu bar item.

    Note: zapping deletes the per-install identity salt along with every
    saved layout and window record; the old data cannot be reused afterwards.
  EOS
end
