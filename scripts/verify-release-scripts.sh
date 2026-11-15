#!/bin/bash
set -euo pipefail

# These shell-owned fixtures run outside TestToolResolver. Keep their Git
# children, including the tap updater's commits, under the same test policy.
test_git_config_count="${GIT_CONFIG_COUNT-0}"
case "$test_git_config_count" in
  *[!0-9]*|'') echo "Invalid test Git GIT_CONFIG_COUNT" >&2; exit 1 ;;
esac
test_git_config_count=$((10#$test_git_config_count))
for test_git_policy in maintenance.auto=false gc.auto=0; do
  export "GIT_CONFIG_KEY_${test_git_config_count}=${test_git_policy%%=*}"
  export "GIT_CONFIG_VALUE_${test_git_config_count}=${test_git_policy#*=}"
  test_git_config_count=$((test_git_config_count + 1))
done
export GIT_CONFIG_COUNT="$test_git_config_count"

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

# Exercise real commits and pushes with macOS's Bash 3.2, including a stale clone.
make_tap_push_fixture() {
  local fixture_dir="$1"
  mkdir -p "$fixture_dir"
  git init --bare --initial-branch=main -q "$fixture_dir/origin.git"
  # Local receive-pack does not inherit the client config overlay above.
  git -C "$fixture_dir/origin.git" config --local receive.autogc false
  git -C "$fixture_dir/origin.git" config --local gc.auto 0
  git -C "$fixture_dir/origin.git" config --local maintenance.auto false
  git -C "$fixture_dir/origin.git" config receive.denyNonFastForwards true
  git clone -q "$fixture_dir/origin.git" "$fixture_dir/writer"
  git -C "$fixture_dir/writer" config user.name "AgentStudio Release Tests"
  git -C "$fixture_dir/writer" config user.email "release-tests@agentstudio.invalid"
  git -C "$fixture_dir/writer" config commit.gpgsign false
  mkdir -p "$fixture_dir/writer/Casks"
  "$ROOT_DIR/scripts/render-homebrew-cask.sh" stable 0.0.53 "$SHA" \
    > "$fixture_dir/writer/Casks/agent-studio.rb"
  "$ROOT_DIR/scripts/render-homebrew-cask.sh" beta 0.0.53-beta.1 "$SHA" \
    > "$fixture_dir/writer/Casks/agent-studio@beta.rb"
  git -C "$fixture_dir/writer" add Casks
  git -C "$fixture_dir/writer" commit -q -m "Seed both channels"
  git -C "$fixture_dir/writer" push -q origin main
  git clone -q "$fixture_dir/origin.git" "$fixture_dir/updater"
  git -C "$fixture_dir/updater" config commit.gpgsign false
}

for selected_channel in stable beta; do
  fixture_dir="$tap_dir/push-race-$selected_channel"
  make_tap_push_fixture "$fixture_dir"
  if [[ "$selected_channel" == stable ]]; then
    selected_cask="agent-studio.rb"
    selected_tag="v0.0.54"
    other_channel=beta
    other_cask="agent-studio@beta.rb"
    other_version="0.0.54-beta.1"
  else
    selected_cask="agent-studio@beta.rb"
    selected_tag="v0.0.54-beta.1"
    other_channel=stable
    other_cask="agent-studio.rb"
    other_version="0.0.54"
  fi
  "$ROOT_DIR/scripts/render-homebrew-cask.sh" "$other_channel" "$other_version" "$SHA" \
    > "$fixture_dir/writer/Casks/$other_cask"
  git -C "$fixture_dir/writer" add Casks
  git -C "$fixture_dir/writer" commit -q -m "Publish other channel first"
  git -C "$fixture_dir/writer" push -q origin main
  other_channel_commit="$(git -C "$fixture_dir/writer" rev-parse HEAD)"
  if [[ "$selected_channel" == beta ]]; then
    # A known upstream commit produces the other non-fast-forward status.
    git -C "$fixture_dir/updater" fetch -q origin main
    expected_rejection="[rejected] (non-fast-forward)"
  else
    expected_rejection="[rejected] (fetch first)"
  fi

  if ! HOMEBREW_TAP_LOCAL_PATH="$fixture_dir/updater" DRY_RUN=0 SKIP_BREW_STYLE=1 \
    /bin/bash "$ROOT_DIR/scripts/update-homebrew-tap.sh" "$selected_channel" "$selected_tag" "$SHA" \
    > "$fixture_dir/update.log" 2>&1; then
    cat "$fixture_dir/update.log" >&2
    echo "$selected_channel tap update failed to recover from the other channel's push" >&2
    exit 1
  fi
  assert_contains "$(<"$fixture_dir/update.log")" "$expected_rejection"
  test "$(git -C "$fixture_dir/origin.git" rev-list --count main)" = 3
  git -C "$fixture_dir/origin.git" merge-base --is-ancestor "$other_channel_commit" main
  test "$(git -C "$fixture_dir/origin.git" rev-parse main)" = \
    "$(git -C "$fixture_dir/updater" rev-parse HEAD)"
  git -C "$fixture_dir/origin.git" show "main:Casks/$other_cask" > "$fixture_dir/actual-other.rb"
  cmp "$fixture_dir/writer/Casks/$other_cask" "$fixture_dir/actual-other.rb"
  "$ROOT_DIR/scripts/render-homebrew-cask.sh" "$selected_channel" "${selected_tag#v}" "$SHA" \
    > "$fixture_dir/expected-selected.rb"
  git -C "$fixture_dir/origin.git" show "main:Casks/$selected_cask" > "$fixture_dir/actual-selected.rb"
  cmp "$fixture_dir/expected-selected.rb" "$fixture_dir/actual-selected.rb"
  echo "tap push recovery passed: $selected_channel (3 commits; both casks preserved)"
done

fixture_dir="$tap_dir/push-conflict"
make_tap_push_fixture "$fixture_dir"
"$ROOT_DIR/scripts/render-homebrew-cask.sh" stable 0.0.55 "$SHA" \
  > "$fixture_dir/writer/Casks/agent-studio.rb"
git -C "$fixture_dir/writer" add Casks
git -C "$fixture_dir/writer" commit -q -m "Conflicting stable release"
git -C "$fixture_dir/writer" push -q origin main
origin_before_conflict="$(git -C "$fixture_dir/origin.git" rev-parse main)"
if HOMEBREW_TAP_LOCAL_PATH="$fixture_dir/updater" DRY_RUN=0 SKIP_BREW_STYLE=1 \
  /bin/bash "$ROOT_DIR/scripts/update-homebrew-tap.sh" stable v0.0.54 "$SHA" \
  > "$fixture_dir/update.log" 2>&1; then
  echo "conflicting tap rebase unexpectedly succeeded" >&2
  exit 1
fi
assert_contains "$(<"$fixture_dir/update.log")" "CONFLICT (content)"
assert_contains "$(<"$fixture_dir/update.log")" "could not apply"
test "$(git -C "$fixture_dir/origin.git" rev-parse main)" = "$origin_before_conflict"
test -n "$(git -C "$fixture_dir/updater" ls-files --unmerged)"
echo "tap rebase conflict passed: nonzero exit; Git error retained; origin unchanged"

fixture_dir="$tap_dir/push-denied"
make_tap_push_fixture "$fixture_dir"
cat > "$fixture_dir/origin.git/hooks/pre-receive" <<'REJECT_TAP_PUSH'
#!/bin/bash
echo attempt >> push-attempts
echo "tap push denied by server policy" >&2
printf '\t[rejected] (fetch first)\n' >&2
exit 1
REJECT_TAP_PUSH
chmod +x "$fixture_dir/origin.git/hooks/pre-receive"
origin_before_denial="$(git -C "$fixture_dir/origin.git" rev-parse main)"
if HOMEBREW_TAP_LOCAL_PATH="$fixture_dir/updater" DRY_RUN=0 SKIP_BREW_STYLE=1 \
  /bin/bash "$ROOT_DIR/scripts/update-homebrew-tap.sh" stable v0.0.54 "$SHA" \
  > "$fixture_dir/update.log" 2>&1; then
  echo "server-denied tap push unexpectedly succeeded" >&2
  exit 1
fi
assert_contains "$(<"$fixture_dir/update.log")" "tap push denied by server policy"
assert_contains "$(<"$fixture_dir/update.log")" $'\t[rejected] (fetch first)'
assert_contains "$(<"$fixture_dir/update.log")" "[remote rejected]"
denied_push_attempts="$(wc -l < "$fixture_dir/origin.git/push-attempts" | tr -d ' ')"
if [[ "$denied_push_attempts" != 1 ]]; then
  cat "$fixture_dir/update.log" >&2
  echo "server-denied tap push made $denied_push_attempts attempts; expected exactly 1" >&2
  exit 1
fi
test "$(git -C "$fixture_dir/origin.git" rev-parse main)" = "$origin_before_denial"
echo "tap server rejection passed: one attempt; Git error retained; origin unchanged"

fixture_dir="$tap_dir/push-exhausted"
make_tap_push_fixture "$fixture_dir"
mkdir -p "$fixture_dir/bin"
# Inject another real remote commit immediately before each real push.
cat > "$fixture_dir/bin/git" <<'RACE_TAP_PUSH'
#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == push ]]; then
  printf '%s\n' "$*" >> "$TAP_PUSH_RACE_DIR/push-attempts"
  "$TAP_PUSH_REAL_GIT" -C "$TAP_PUSH_RACE_DIR/writer" commit --allow-empty -q -m "Concurrent tap update"
  "$TAP_PUSH_REAL_GIT" -C "$TAP_PUSH_RACE_DIR/writer" push -q origin main
fi
exec "$TAP_PUSH_REAL_GIT" "$@"
RACE_TAP_PUSH
chmod +x "$fixture_dir/bin/git"
if PATH="$fixture_dir/bin:$PATH" TAP_PUSH_RACE_DIR="$fixture_dir" TAP_PUSH_REAL_GIT="$(command -v git)" \
  HOMEBREW_TAP_LOCAL_PATH="$fixture_dir/updater" DRY_RUN=0 SKIP_BREW_STYLE=1 \
  /bin/bash "$ROOT_DIR/scripts/update-homebrew-tap.sh" stable v0.0.54 "$SHA" \
  > "$fixture_dir/update.log" 2>&1; then
  echo "continually outdated tap push unexpectedly succeeded" >&2
  exit 1
fi
assert_contains "$(<"$fixture_dir/update.log")" "[rejected] (fetch first)"
assert_contains "$(<"$fixture_dir/update.log")" "error: failed to push some refs"
assert_contains "$(<"$fixture_dir/update.log")" "Homebrew tap push failed after 3 attempts"
test "$(wc -l < "$fixture_dir/push-attempts" | tr -d ' ')" = 3
while IFS= read -r push_arguments; do
  test "$push_arguments" = "push --porcelain origin main"
done < "$fixture_dir/push-attempts"
test "$(git -C "$fixture_dir/origin.git" rev-list --count main)" = 4
git -C "$fixture_dir/origin.git" show main:Casks/agent-studio.rb > "$fixture_dir/actual-selected.rb"
cmp "$fixture_dir/writer/Casks/agent-studio.rb" "$fixture_dir/actual-selected.rb"
echo "tap push exhaustion passed: 3 ordinary pushes; last Git error retained; remote cask unchanged"

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
