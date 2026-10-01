#!/bin/bash
set -euo pipefail

CHANNEL="${1:?usage: render-homebrew-cask.sh <stable|beta> <version> <sha256>}"
VERSION="${2:?missing version}"
SHA256="${3:?missing sha256}"

if [[ ! "$SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "sha256 must be 64 lowercase hex characters" >&2
  exit 1
fi

case "$CHANNEL" in
  stable)
    if [[ "$VERSION" == *"-"* ]]; then
      echo "stable cask version must not contain a prerelease suffix" >&2
      exit 1
    fi
    TOKEN="agent-studio"
    DATA_DIR=".agentstudio"
    CASK_NAME="Agent Studio"
    APP_BUNDLE_NAME="AgentStudio.app"
    APP_CACHE_DOMAIN="com.agentstudio.app"
    ;;
  beta)
    if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$ ]]; then
      echo "beta cask version must match X.Y.Z-beta.N" >&2
      exit 1
    fi
    TOKEN="agent-studio@beta"
    DATA_DIR=".agent-studio-b"
    CASK_NAME="Agent Studio Beta"
    APP_BUNDLE_NAME="AgentStudio Beta.app"
    APP_CACHE_DOMAIN="com.agentstudio.app.beta"
    ;;
  *)
    echo "unsupported cask channel: $CHANNEL" >&2
    exit 1
    ;;
esac

printf 'cask "%s" do\n' "$TOKEN"
printf '  version "%s"\n' "$VERSION"
printf '  sha256 "%s"\n' "$SHA256"
printf '\n'
printf '  url "https://github.com/getagentstudio/agentstudio/releases/download/v#{version}/AgentStudio-v#{version}-macos.zip"\n'
printf '  name "%s"\n' "$CASK_NAME"
printf '  desc "Terminal application with Ghostty terminal emulator and project management"\n'
printf '  homepage "https://github.com/getagentstudio/agentstudio"\n'
printf '\n'
printf '  depends_on macos: :tahoe\n'
printf '\n'
printf '  app "%s"\n' "$APP_BUNDLE_NAME"
printf '\n'
printf '  zap trash: [\n'
printf '    "~/%s",\n' "$DATA_DIR"
printf '    "~/Library/Caches/%s",\n' "$APP_CACHE_DOMAIN"
printf '    "~/Library/Preferences/%s.plist",\n' "$APP_CACHE_DOMAIN"
printf '    "~/Library/Saved Application State/%s.savedState",\n' "$APP_CACHE_DOMAIN"
printf '  ]\n'
printf 'end\n'
