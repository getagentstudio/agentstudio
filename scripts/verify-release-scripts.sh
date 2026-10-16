#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHA="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "expected output to contain: $needle" >&2
    exit 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "expected output not to contain: $needle" >&2
    exit 1
  fi
}

stable_metadata="$("$ROOT_DIR/scripts/release-tag-metadata.sh" v0.0.54)"
beta_metadata="$("$ROOT_DIR/scripts/release-tag-metadata.sh" v0.0.54-beta.1)"

assert_contains "$stable_metadata" "channel=stable"
assert_contains "$stable_metadata" "cask_token=agent-studio"
assert_contains "$stable_metadata" "app_bundle_name=AgentStudio.app"
assert_contains "$stable_metadata" "bundle_identifier=com.agentstudio.app"
assert_contains "$stable_metadata" "app_cache_domain=com.agentstudio.app"
assert_contains "$stable_metadata" "oauth_callback_scheme=agentstudio"
assert_contains "$beta_metadata" "channel=beta"
assert_contains "$beta_metadata" "cask_token=agent-studio@beta"
assert_contains "$beta_metadata" "app_bundle_name=AgentStudio Beta.app"
assert_contains "$beta_metadata" "bundle_identifier=com.agentstudio.app.beta"
assert_contains "$beta_metadata" "app_cache_domain=com.agentstudio.app.beta"
assert_contains "$beta_metadata" "oauth_callback_scheme=agentstudio-beta"

if "$ROOT_DIR/scripts/release-tag-metadata.sh" v0.0.54-beta >/dev/null 2>&1; then
  echo "malformed beta tag unexpectedly passed" >&2
  exit 1
fi

beta_repo="$(mktemp -d)"
missing_stable_repo="$(mktemp -d)"
cleanup_beta_repos() {
  find "$beta_repo" -mindepth 1 -delete
  rmdir "$beta_repo"
  find "$missing_stable_repo" -mindepth 1 -delete
  rmdir "$missing_stable_repo"
}
trap cleanup_beta_repos EXIT

git -C "$beta_repo" init -q
git -C "$beta_repo" config user.name "AgentStudio Release Tests"
git -C "$beta_repo" config user.email "release-tests@agentstudio.invalid"
git -C "$beta_repo" config commit.gpgsign false
git -C "$beta_repo" commit --allow-empty -q -m "stable 0.0.67"
git -C "$beta_repo" tag v0.0.67
git -C "$beta_repo" commit --allow-empty -q -m "stable 0.0.68"
git -C "$beta_repo" tag v0.0.68
git -C "$beta_repo" tag v0.0.69-beta.7
git -C "$beta_repo" commit --allow-empty -q -m "daily beta candidate"
beta_candidate_sha="$(git -C "$beta_repo" rev-parse HEAD)"

resolver_output="$(
  GIT_DIR="$beta_repo/.git" GIT_WORK_TREE="$beta_repo" \
    "$ROOT_DIR/scripts/resolve-daily-beta-tag.sh" "$beta_candidate_sha" 123
)"
assert_contains "$resolver_output" "should_tag=true"
assert_contains "$resolver_output" "candidate_sha=$beta_candidate_sha"
assert_contains "$resolver_output" "tag=v0.0.69-beta.123"

git -C "$beta_repo" tag v0.0.69-beta.122 "$beta_candidate_sha"
resolver_noop_output="$(
  GIT_DIR="$beta_repo/.git" GIT_WORK_TREE="$beta_repo" \
    "$ROOT_DIR/scripts/resolve-daily-beta-tag.sh" "$beta_candidate_sha" 123
)"
assert_contains "$resolver_noop_output" "should_tag=false"
assert_contains "$resolver_noop_output" "candidate_sha=$beta_candidate_sha"
assert_contains "$resolver_noop_output" "tag=v0.0.69-beta.122"
git -C "$beta_repo" tag -d v0.0.69-beta.122 >/dev/null

if GIT_DIR="$beta_repo/.git" GIT_WORK_TREE="$beta_repo" \
  "$ROOT_DIR/scripts/resolve-daily-beta-tag.sh" "$beta_candidate_sha" abc >/dev/null 2>&1
then
  echo "non-numeric daily beta run number unexpectedly passed" >&2
  exit 1
fi

git -C "$missing_stable_repo" init -q
git -C "$missing_stable_repo" config user.name "AgentStudio Release Tests"
git -C "$missing_stable_repo" config user.email "release-tests@agentstudio.invalid"
git -C "$missing_stable_repo" config commit.gpgsign false
git -C "$missing_stable_repo" commit --allow-empty -q -m "candidate without stable tag"
missing_stable_sha="$(git -C "$missing_stable_repo" rev-parse HEAD)"
if GIT_DIR="$missing_stable_repo/.git" GIT_WORK_TREE="$missing_stable_repo" \
  "$ROOT_DIR/scripts/resolve-daily-beta-tag.sh" "$missing_stable_sha" 123 >/dev/null 2>&1
then
  echo "daily beta resolver unexpectedly accepted a repository without a stable tag" >&2
  exit 1
fi

git -C "$beta_repo" tag v0.0.69-beta.123 v0.0.68
if GIT_DIR="$beta_repo/.git" GIT_WORK_TREE="$beta_repo" \
  "$ROOT_DIR/scripts/resolve-daily-beta-tag.sh" "$beta_candidate_sha" 123 >/dev/null 2>&1
then
  echo "daily beta resolver unexpectedly accepted a tag collision" >&2
  exit 1
fi

cleanup_beta_repos
trap - EXIT

daily_beta_workflow_path="$ROOT_DIR/.github/workflows/daily-beta.yml"
if [[ ! -f "$daily_beta_workflow_path" ]]; then
  echo "daily beta workflow is missing: $daily_beta_workflow_path" >&2
  exit 1
fi
daily_beta_workflow="$(<"$daily_beta_workflow_path")"

assert_contains "$daily_beta_workflow" "schedule:"
assert_contains "$daily_beta_workflow" "cron: '0 12 * * *'"
assert_contains "$daily_beta_workflow" "timezone: 'America/Toronto'"
assert_contains "$daily_beta_workflow" "workflow_dispatch:"
assert_contains "$daily_beta_workflow" "contents: write"
assert_contains "$daily_beta_workflow" "group: daily-beta-tag"
assert_contains "$daily_beta_workflow" "cancel-in-progress: false"
assert_contains "$daily_beta_workflow" \
  "uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4"
assert_contains "$daily_beta_workflow" "ref: main"
assert_contains "$daily_beta_workflow" "fetch-depth: 0"
assert_contains "$daily_beta_workflow" 'token: ${{ secrets.HOMEBREW_TAP_TOKEN }}'
assert_contains "$daily_beta_workflow" "git fetch origin main --tags"
assert_contains "$daily_beta_workflow" "git rev-parse 'origin/main^{commit}'"
assert_contains "$daily_beta_workflow" "scripts/resolve-daily-beta-tag.sh"
assert_contains "$daily_beta_workflow" "if: steps.beta.outputs.should_tag == 'true'"
assert_contains "$daily_beta_workflow" 'git tag "$BETA_TAG" "$CANDIDATE_SHA"'
assert_contains "$daily_beta_workflow" 'git push origin "refs/tags/$BETA_TAG"'
assert_not_contains "$daily_beta_workflow" "GITHUB_TOKEN"
assert_not_contains "$daily_beta_workflow" "APPLE_CERTIFICATE_BASE64"
assert_not_contains "$daily_beta_workflow" "APPLE_NOTARY_PASSWORD"
assert_not_contains "$daily_beta_workflow" "notarytool"
assert_not_contains "$daily_beta_workflow" "update-homebrew-tap.sh"
assert_not_contains "$daily_beta_workflow" "softprops/action-gh-release"

stable_cask="$("$ROOT_DIR/scripts/render-homebrew-cask.sh" stable 0.0.54 "$SHA")"
beta_cask="$("$ROOT_DIR/scripts/render-homebrew-cask.sh" beta 0.0.54-beta.1 "$SHA")"

assert_contains "$stable_cask" 'cask "agent-studio" do'
assert_contains "$stable_cask" 'name "Agent Studio"'
assert_contains "$stable_cask" 'desc "Terminal application with Ghostty terminal emulator and project management"'
assert_not_contains "$stable_cask" 'conflicts_with cask: "agent-studio@beta"'
assert_contains "$stable_cask" 'depends_on macos: :tahoe'
assert_contains "$stable_cask" 'app "AgentStudio.app"'
assert_contains "$stable_cask" '"~/.agentstudio"'
assert_contains "$stable_cask" '"~/Library/Caches/com.agentstudio.app"'
assert_contains "$stable_cask" '"~/Library/Preferences/com.agentstudio.app.plist"'
assert_contains "$stable_cask" '"~/Library/Saved Application State/com.agentstudio.app.savedState"'
assert_not_contains "$stable_cask" 'desc "macOS'
assert_not_contains "$stable_cask" 'depends_on macos: ">= :tahoe"'
assert_contains "$beta_cask" 'cask "agent-studio@beta" do'
assert_contains "$beta_cask" 'name "Agent Studio Beta"'
assert_contains "$beta_cask" 'desc "Terminal application with Ghostty terminal emulator and project management"'
assert_not_contains "$beta_cask" 'conflicts_with cask: "agent-studio"'
assert_contains "$beta_cask" 'depends_on macos: :tahoe'
assert_contains "$beta_cask" 'app "AgentStudio Beta.app"'
assert_contains "$beta_cask" '"~/.agent-studio-b"'
assert_contains "$beta_cask" '"~/Library/Caches/com.agentstudio.app.beta"'
assert_contains "$beta_cask" '"~/Library/Preferences/com.agentstudio.app.beta.plist"'
assert_contains "$beta_cask" '"~/Library/Saved Application State/com.agentstudio.app.beta.savedState"'
assert_not_contains "$beta_cask" 'desc "macOS'
assert_not_contains "$beta_cask" 'depends_on macos: ">= :tahoe"'

if ! awk '
  /depends_on macos: :tahoe/ { depends = NR }
  /app "AgentStudio Beta.app"/ { app = NR }
  END {
    if (!depends || !app || depends >= app) {
      exit 1
    }
  }
' < <(printf '%s\n' "$beta_cask"); then
  echo "beta cask stanza order is incorrect or missing expected stanzas" >&2
  exit 1
fi

if ! awk '
  /"~\/\.agent-studio-b",/ { data = NR }
  /"~\/Library\/Caches\/com\.agentstudio\.app\.beta",/ { cache = NR }
  /"~\/Library\/Preferences\/com\.agentstudio\.app\.beta\.plist",/ { preferences = NR }
  /"~\/Library\/Saved Application State\/com\.agentstudio\.app\.beta\.savedState",/ { saved_state = NR }
  END {
    if (!data || !cache || !preferences || !saved_state || data >= cache || cache >= preferences || preferences >= saved_state) {
      exit 1
    }
  }
' < <(printf '%s\n' "$beta_cask"); then
  echo "beta cask zap trash order is incorrect or missing expected paths" >&2
  exit 1
fi

tap_dir="$(mktemp -d)"
cleanup() {
  find "$tap_dir" -mindepth 1 -delete
  rmdir "$tap_dir"
}
trap cleanup EXIT
mkdir -p "$tap_dir/Casks"

plist_under_test="$tap_dir/Info.plist"
cp "$ROOT_DIR/Sources/AgentStudio/Resources/Info.plist" "$plist_under_test"
/bin/bash "$ROOT_DIR/scripts/inject-bundle-version.sh" "$plist_under_test" 0.0.54-beta.1 123 beta
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLName' "$plist_under_test")" = "com.agentstudio.oauth.beta"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$plist_under_test")" = "agentstudio-beta"

HOMEBREW_TAP_LOCAL_PATH="$tap_dir" DRY_RUN=1 SKIP_BREW_STYLE=1 \
  "$ROOT_DIR/scripts/update-homebrew-tap.sh" beta v0.0.54-beta.1 "$SHA" >/dev/null

test -f "$tap_dir/Casks/agent-studio@beta.rb"
test ! -f "$tap_dir/Casks/agent-studio.rb"

fake_bin="$tap_dir/fake-bin"
fake_homebrew="$tap_dir/fake-homebrew"
mkdir -p "$fake_bin" "$fake_homebrew/Library/Taps"

cat > "$fake_bin/brew" <<'FAKE_BREW'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  --repository)
    if [[ "${FAKE_BREW_REPOSITORY_FAIL:-0}" == "1" ]]; then
      exit 42
    fi
    echo "$FAKE_HOMEBREW_REPOSITORY"
    ;;
  style)
    if [[ "$(pwd)" != "$FAKE_HOMEBREW_REPOSITORY"/Library/Taps/* ]]; then
      echo "Homebrew requires casks to be in a tap, rejecting:" >&2
      echo "  $(pwd)/${3:-}" >&2
      exit 1
    fi
    ;;
  *)
    echo "unexpected fake brew invocation: $*" >&2
    exit 1
    ;;
esac
FAKE_BREW
chmod +x "$fake_bin/brew"

cat > "$fake_bin/git" <<'FAKE_GIT'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "clone" ]]; then
  mkdir -p "${3:?missing clone destination}/Casks"
  exit 0
fi

echo "unexpected fake git invocation: $*" >&2
exit 1
FAKE_GIT
chmod +x "$fake_bin/git"

PATH="$fake_bin:$PATH" FAKE_HOMEBREW_REPOSITORY="$fake_homebrew" HOMEBREW_TAP_TOKEN=fake \
  DRY_RUN=1 "$ROOT_DIR/scripts/update-homebrew-tap.sh" beta v0.0.54-beta.1 "$SHA" >/dev/null

PATH="$fake_bin:$PATH" FAKE_BREW_REPOSITORY_FAIL=1 HOMEBREW_TAP_TOKEN=fake \
  DRY_RUN=1 SKIP_BREW_STYLE=1 "$ROOT_DIR/scripts/update-homebrew-tap.sh" beta v0.0.54-beta.1 "$SHA" >/dev/null

# macOS /bin/bash is 3.2: an empty array is unset under nounset.
for xcb_extra_args in "" "--renderer github-actions"; do
  xcb_output="$(XCB_EXTRA_ARGS="$xcb_extra_args" /bin/bash -eu -c '
    source "$1/scripts/xcb-helpers.sh"
    xcbeautify() {
      printf "argument-count=%s\n" "$#"
      for argument in "$@"; do printf "argument=%s\n" "$argument"; done
      cat
    }
    printf "release build output\n" | _xcb_pipe
  ' _ "$ROOT_DIR")"
  assert_contains "$xcb_output" "release build output"
  assert_contains "$xcb_output" "argument=--preserve-unbeautified"
  assert_contains "$xcb_output" "argument=--disable-logging"
  if [[ -z "$xcb_extra_args" ]]; then
    assert_contains "$xcb_output" "argument-count=2"
  else
    assert_contains "$xcb_output" "argument-count=4"
    assert_contains "$xcb_output" "argument=--renderer"
    assert_contains "$xcb_output" "argument=github-actions"
  fi
done

echo "release script verification passed"
