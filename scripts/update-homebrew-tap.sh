#!/usr/bin/env bash
set -euo pipefail

CHANNEL="${1:?usage: update-homebrew-tap.sh <stable|beta> <tag> <sha256>}"
TAG="${2:?missing tag}"
SHA256="${3:?missing sha256}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${TAG#v}"
DRY_RUN="${DRY_RUN:-0}"
TAP_DIR=""
CLEANUP_TAP_DIR=0

cleanup() {
  if [[ "$CLEANUP_TAP_DIR" == "1" && -n "$TAP_DIR" && -d "$TAP_DIR" ]]; then
    find "$TAP_DIR" -mindepth 1 -delete
    rmdir "$TAP_DIR"
    local tap_parent
    tap_parent="$(dirname "$TAP_DIR")"
    if [[ "$tap_parent" == */getagentstudio ]]; then
      rmdir "$tap_parent" 2>/dev/null || true
    fi
  fi
}
trap cleanup EXIT

make_tap_clone_dir() {
  if command -v brew >/dev/null 2>&1; then
    local brew_repository
    brew_repository="$(brew --repository 2>/dev/null || true)"
    if [[ -n "$brew_repository" ]]; then
      local tap_parent="$brew_repository/Library/Taps/getagentstudio"
      local preferred_tap_dir="$tap_parent/homebrew-agentstudio"
      if mkdir -p "$tap_parent" 2>/dev/null; then
        if [[ -e "$preferred_tap_dir" ]]; then
          mktemp -d "$tap_parent/homebrew-agentstudio-release.XXXXXX"
        else
          echo "$preferred_tap_dir"
        fi
        return
      fi
    fi
  fi
  mktemp -d
}

case "$CHANNEL" in
  stable)
    CASK_FILE="Casks/agent-studio.rb"
    ;;
  beta)
    CASK_FILE="Casks/agent-studio@beta.rb"
    ;;
  *)
    echo "unsupported cask channel: $CHANNEL" >&2
    exit 1
    ;;
esac

if [[ -n "${HOMEBREW_TAP_LOCAL_PATH:-}" ]]; then
  TAP_DIR="$HOMEBREW_TAP_LOCAL_PATH"
else
  if [[ -z "${HOMEBREW_TAP_TOKEN:-}" ]]; then
    echo "HOMEBREW_TAP_TOKEN is required when HOMEBREW_TAP_LOCAL_PATH is not set" >&2
    exit 1
  fi

  TAP_DIR="$(make_tap_clone_dir)"
  CLEANUP_TAP_DIR=1
  git clone "https://x-access-token:${HOMEBREW_TAP_TOKEN}@github.com/getagentstudio/homebrew-agentstudio.git" "$TAP_DIR"
fi

mkdir -p "$TAP_DIR/Casks"
"$REPO_ROOT/scripts/render-homebrew-cask.sh" "$CHANNEL" "$VERSION" "$SHA256" > "$TAP_DIR/$CASK_FILE"

if [[ "${SKIP_BREW_STYLE:-0}" != "1" ]] && command -v brew >/dev/null 2>&1; then
  (
    cd "$TAP_DIR"
    brew style --cask "$CASK_FILE"
  )
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "dry run: wrote $CASK_FILE"
  exit 0
fi

(
  cd "$TAP_DIR"
  git config user.name "github-actions[bot]"
  git config user.email "github-actions[bot]@users.noreply.github.com"
  git add "$CASK_FILE"
  if git diff --cached --quiet; then
    echo "No Homebrew tap changes for $CASK_FILE"
    exit 0
  fi
  git commit -m "Update ${CASK_FILE#Casks/} to ${TAG}"

  max_push_attempts=3
  for ((push_attempt = 1; push_attempt <= max_push_attempts; push_attempt++)); do
    # Keep remote diagnostics on stderr; only stdout contains porcelain records.
    if push_output="$(LC_ALL=C git push --porcelain origin main)"; then
      printf '%s\n' "$push_output"
      exit 0
    else
      push_status=$?
    fi
    printf '%s\n' "$push_output" >&2

    retryable_push_rejection=0
    while IFS= read -r push_record; do
      case "$push_record" in
        $'!\trefs/heads/main:refs/heads/main\t[rejected] (fetch first)'|\
        $'!\trefs/heads/main:refs/heads/main\t[rejected] (non-fast-forward)')
          retryable_push_rejection=1
          ;;
      esac
    done <<< "$push_output"
    if [[ "$retryable_push_rejection" != 1 ]]; then
      exit "$push_status"
    fi
    if [[ "$push_attempt" -eq "$max_push_attempts" ]]; then
      echo "Homebrew tap push failed after $max_push_attempts attempts" >&2
      exit "$push_status"
    fi
    echo "Homebrew tap changed upstream; rebasing before push attempt $((push_attempt + 1))" >&2
    git pull --rebase origin main
  done
)
