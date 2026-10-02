cask "agent-studio" do
  version "0.0.8-alpha"
  sha256 "fad65cdbab3e80c6af4ba37c8f3d806eae41b1fdd7fe5569947b203733919d73"

  url "https://github.com/getagentstudio/agentstudio/releases/download/v#{version}/AgentStudio-v#{version}-macos.zip"
  name "Agent Studio"
  desc "macOS terminal application with Ghostty terminal emulator and project management"
  homepage "https://github.com/getagentstudio/agentstudio"

  depends_on macos: ">= :tahoe"
  depends_on formula: "gh"

  app "AgentStudio.app"

  zap trash: [
    "~/Library/Preferences/com.agentstudio.app.plist",
    "~/Library/Caches/com.agentstudio.app",
    "~/Library/Application Support/AgentStudio",
  ]
end
