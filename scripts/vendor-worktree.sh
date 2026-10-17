#!/usr/bin/env bash
set -euo pipefail

readonly ghostty_submodule="vendor/ghostty"
readonly zmx_submodule="vendor/zmx"
readonly framework_relative="Frameworks/GhosttyKit.xcframework"
readonly zmx_output_relative="vendor/zmx/zig-out"
readonly ghostty_resources_relative="Sources/AgentStudio/Resources/ghostty"
readonly ghostty_terminfo_relative="Sources/AgentStudio/Resources/terminfo/67/ghostty"
readonly helper_project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

fail() {
  printf '[vendor-worktree] ERROR: %s\n' "$1" >&2
  exit 1
}

canonical_directory() {
  [[ -d "$1" ]] || fail "directory does not exist: $1"
  (cd "$1" && pwd -P)
}

repository_root() {
  git -C "$helper_project_root" rev-parse --show-toplevel 2>/dev/null ||
    fail "run this command from an AgentStudio Git worktree"
}

absolute_git_directory() {
  git -C "$1" rev-parse --path-format=absolute --absolute-git-dir 2>/dev/null ||
    fail "cannot resolve Git directory for worktree: $1"
}

absolute_common_directory() {
  git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null ||
    fail "cannot resolve Git common directory for worktree: $1"
}

primary_worktree_root() {
  local current_root="$1"
  local current_common
  local candidate_root
  local candidate_git
  local candidate_common
  local primary_root=""
  local primary_count=0

  current_common="$(canonical_directory "$(absolute_common_directory "$current_root")")"

  while IFS= read -r -d '' record; do
    [[ "$record" == worktree\ * ]] || continue
    candidate_root="${record#worktree }"
    [[ -d "$candidate_root" ]] || continue
    candidate_root="$(canonical_directory "$candidate_root")"
    # A registered worktree directory can survive after its .git link is gone.
    # It cannot be the primary; skip it without emitting nested failure messages.
    candidate_git="$(git -C "$candidate_root" rev-parse --path-format=absolute --absolute-git-dir 2>/dev/null)" || continue
    candidate_common="$(git -C "$candidate_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || continue
    candidate_git="$(canonical_directory "$candidate_git")"
    candidate_common="$(canonical_directory "$candidate_common")"
    [[ "$candidate_common" == "$current_common" ]] || continue
    if [[ "$candidate_git" == "$candidate_common" ]]; then
      primary_root="$candidate_root"
      primary_count=$((primary_count + 1))
    fi
  done < <(git -C "$current_root" worktree list --porcelain -z)

  [[ "$primary_count" -eq 1 ]] ||
    fail "expected exactly one registered primary worktree; found $primary_count. Restore or register the primary worktree, run plain 'mise run setup' there, then rerun plain 'mise run setup' in this linked worktree."
  printf '%s\n' "$primary_root"
}

gitlink_revision() {
  git -C "$1" rev-parse "HEAD:$2" 2>/dev/null ||
    fail "cannot resolve committed gitlink $2 in $1"
}

submodule_status_line() {
  local status_line
  status_line="$(git -C "$1" submodule status -- "$2" 2>/dev/null)" ||
    fail "cannot inspect submodule $2 in $1"
  [[ -n "$status_line" ]] || fail "submodule is not registered: $2"
  printf '%s\n' "$status_line"
}

submodule_state_marker() {
  local status_line
  status_line="$(submodule_status_line "$1" "$2")"
  printf '%s' "${status_line:0:1}"
}

submodule_checked_out_revision() {
  local status_line
  status_line="$(submodule_status_line "$1" "$2")"
  [[ "${status_line:0:1}" != "-" ]] || fail "submodule is not hydrated: $1/$2"
  printf '%s\n' "${status_line:1:40}"
}

require_real_directory() {
  [[ ! -L "$1" && -d "$1" ]] || fail "expected a real directory: $1"
}

require_real_file() {
  [[ ! -L "$1" && -f "$1" ]] || fail "expected a real file: $1"
}

require_path_within_root() {
  local root
  local path="$2"
  local resolved

  root="$(canonical_directory "$1")"
  if [[ -d "$path" ]]; then
    resolved="$(canonical_directory "$path")"
  else
    resolved="$(canonical_directory "$(dirname "$path")")/$(basename "$path")"
  fi
  [[ "$resolved" == "$root/"* ]] || fail "vendor source escapes its worktree root: $path"
}

require_no_nested_symlinks() {
  local first_symlink
  first_symlink="$(find "$1" -type l -print -quit)"
  [[ -z "$first_symlink" ]] || fail "symlink is not allowed inside vendor resources: $first_symlink"
}

require_primary_compatibility() {
  local current_root="$1"
  local primary_root="$2"
  local submodule
  local current_gitlink
  local primary_gitlink
  local primary_checkout

  for submodule in "$ghostty_submodule" "$zmx_submodule"; do
    current_gitlink="$(gitlink_revision "$current_root" "$submodule")"
    primary_gitlink="$(gitlink_revision "$primary_root" "$submodule")"
    primary_checkout="$(submodule_checked_out_revision "$primary_root" "$submodule")"
    [[ "$current_gitlink" == "$primary_gitlink" ]] ||
      fail "$submodule pin differs between linked and primary worktrees"
    [[ "$primary_gitlink" == "$primary_checkout" ]] ||
      fail "primary $submodule checkout does not match its committed gitlink"
  done
}

# GhosttyEventRoutingCoverageTests reads <slice>/Headers/GhosttyKit/ghostty.h out of the
# XCFramework at runtime, so an otherwise well-formed framework directory that
# carries no slice header fails the suite with "couldn't be opened" instead of
# failing preflight.
require_framework_slice_header() {
  local framework="$1"
  local slice_header

  slice_header="$(find "$framework" -maxdepth 4 -type f -path '*/Headers/GhosttyKit/ghostty.h' -print -quit 2>/dev/null || true)"
  [[ -n "$slice_header" ]] ||
    fail "GhosttyKit XCFramework has no slice header: expected $framework/<slice>/Headers/GhosttyKit/ghostty.h"
}

require_prepared_sources() {
  local producer_root="$1"
  local framework="$producer_root/$framework_relative"
  local zmx_output="$producer_root/$zmx_output_relative"
  local zmx_binary="$zmx_output/bin/zmx"
  local ghostty_resources="$producer_root/$ghostty_resources_relative"
  local ghostty_terminfo="$producer_root/$ghostty_terminfo_relative"

  require_real_directory "$framework"
  require_path_within_root "$producer_root" "$framework"
  require_no_nested_symlinks "$framework"
  require_framework_slice_header "$framework"
  require_real_directory "$zmx_output"
  require_path_within_root "$producer_root" "$zmx_output"
  require_real_file "$zmx_binary"
  require_path_within_root "$producer_root" "$zmx_binary"
  [[ -x "$zmx_binary" ]] || fail "zmx binary is not executable: $zmx_binary"
  require_real_directory "$ghostty_resources"
  require_path_within_root "$producer_root" "$ghostty_resources"
  require_no_nested_symlinks "$ghostty_resources"
  require_real_file "$ghostty_terminfo"
  require_path_within_root "$producer_root" "$ghostty_terminfo"
}

require_missing_or_real_directory() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    require_real_directory "$path"
  fi
}

require_missing_or_real_file() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    require_real_file "$path"
  fi
}

require_safe_producer_paths() {
  local producer_root="$1"

  ensure_parent_chain_has_no_symlink "$producer_root" "$ghostty_submodule/.producer-root"
  ensure_parent_chain_has_no_symlink "$producer_root" "$zmx_submodule/.producer-root"
  ensure_parent_chain_has_no_symlink \
    "$producer_root" \
    "$ghostty_submodule/src/build/LibtoolStep.zig"
  require_missing_or_real_directory "$producer_root/$ghostty_submodule"
  require_missing_or_real_directory "$producer_root/$zmx_submodule"
  require_missing_or_real_file "$producer_root/$ghostty_submodule/src/build/LibtoolStep.zig"

  ensure_parent_chain_has_no_symlink "$producer_root" "$framework_relative/.producer-output"
  ensure_parent_chain_has_no_symlink "$producer_root" "$zmx_output_relative/.producer-output"
  ensure_parent_chain_has_no_symlink "$producer_root" "$zmx_output_relative/bin/.producer-output"
  ensure_parent_chain_has_no_symlink "$producer_root" "$ghostty_resources_relative/.producer-output"
  ensure_parent_chain_has_no_symlink "$producer_root" "$ghostty_terminfo_relative/.producer-output"
  require_missing_or_real_directory "$producer_root/$framework_relative"
  require_missing_or_real_directory "$producer_root/$zmx_output_relative"
  require_missing_or_real_directory "$producer_root/$zmx_output_relative/bin"
  require_missing_or_real_directory "$producer_root/$ghostty_resources_relative"
  require_missing_or_real_file "$producer_root/$ghostty_terminfo_relative"
}

require_ci_prepared_sources() {
  local producer_root="$1"
  local framework="$producer_root/$framework_relative"
  local zmx_output="$producer_root/$zmx_output_relative"
  local zmx_binary="$zmx_output/bin/zmx"
  local ghostty_resources="$producer_root/$ghostty_resources_relative"

  require_real_directory "$framework"
  require_path_within_root "$producer_root" "$framework"
  require_no_nested_symlinks "$framework"
  require_framework_slice_header "$framework"
  require_real_directory "$zmx_output"
  require_path_within_root "$producer_root" "$zmx_output"
  require_real_file "$zmx_binary"
  require_path_within_root "$producer_root" "$zmx_binary"
  [[ -x "$zmx_binary" ]] || fail "zmx binary is not executable: $zmx_binary"
  require_real_directory "$ghostty_resources"
  require_path_within_root "$producer_root" "$ghostty_resources"
  require_no_nested_symlinks "$ghostty_resources"
}

require_shared_primary_ready() {
  local current_root="$1"
  local primary_root="$2"
  local failure_output

  if ! failure_output="$(require_primary_compatibility "$current_root" "$primary_root" 2>&1)"; then
    printf '%s\n' "$failure_output" >&2
    fail "prepare vendors by running plain 'mise run setup' in the primary worktree: $primary_root. Then rerun plain 'mise run setup' in this linked worktree: $current_root"
  fi
  if ! failure_output="$(require_prepared_sources "$primary_root" 2>&1)"; then
    printf '%s\n' "$failure_output" >&2
    fail "prepare vendors by running plain 'mise run setup' in the primary worktree: $primary_root. Then rerun plain 'mise run setup' in this linked worktree: $current_root"
  fi
}

ensure_parent_chain_has_no_symlink() {
  local root="$1"
  local relative="$2"
  local partial="$root"
  local component
  local old_ifs="$IFS"

  IFS="/"
  read -r -a components <<< "$relative"
  IFS="$old_ifs"
  for component in "${components[@]:0:${#components[@]}-1}"; do
    partial="$partial/$component"
    [[ ! -L "$partial" ]] || fail "destination ancestor must not be a symlink: $partial"
  done
}

require_exact_or_missing_symlink_destination() {
  local destination="$1"
  local expected_target="$2"

  if [[ -L "$destination" ]]; then
    [[ "$(readlink "$destination")" == "$expected_target" ]] ||
      fail "foreign symlink collision: $destination"
  elif [[ -e "$destination" ]]; then
    fail "regular output collision: $destination"
  fi
}

resource_copies_match() {
  local current_root="$1"
  local primary_root="$2"
  diff -qr \
    "$primary_root/$ghostty_resources_relative" \
    "$current_root/$ghostty_resources_relative" >/dev/null &&
    cmp -s \
      "$primary_root/$ghostty_terminfo_relative" \
      "$current_root/$ghostty_terminfo_relative"
}

exact_shared_links_exist() {
  local current_root="$1"
  local primary_root="$2"
  [[ -L "$current_root/$framework_relative" ]] &&
    [[ "$(readlink "$current_root/$framework_relative")" == "$primary_root/$framework_relative" ]] &&
    [[ -L "$current_root/$zmx_output_relative" ]] &&
    [[ "$(readlink "$current_root/$zmx_output_relative")" == "$primary_root/$zmx_output_relative" ]]
}

local_outputs_exist() {
  local current_root="$1"
  [[ ! -L "$current_root/$framework_relative" && -d "$current_root/$framework_relative" ]] &&
    [[ ! -L "$current_root/$zmx_output_relative" && -d "$current_root/$zmx_output_relative" ]] &&
    [[ ! -L "$current_root/$ghostty_resources_relative" && -d "$current_root/$ghostty_resources_relative" ]] &&
    [[ ! -L "$current_root/$ghostty_terminfo_relative" && -f "$current_root/$ghostty_terminfo_relative" ]]
}

local_inputs_are_hydrated() {
  local current_root="$1"
  local submodule
  local gitlink
  local checkout

  for submodule in "$ghostty_submodule" "$zmx_submodule"; do
    [[ "$(submodule_state_marker "$current_root" "$submodule")" == " " ]] || return 1
    gitlink="$(gitlink_revision "$current_root" "$submodule")"
    checkout="$(submodule_checked_out_revision "$current_root" "$submodule")"
    [[ "$gitlink" == "$checkout" ]] || return 1
  done
  [[ ! -L "$current_root/$framework_relative" ]] &&
    [[ ! -L "$current_root/$zmx_output_relative" ]]
}

worktree_role() {
  local current_root="$1"
  local primary_root="$2"
  local current_git
  local current_common
  local ghostty_marker
  local zmx_marker

  current_git="$(canonical_directory "$(absolute_git_directory "$current_root")")"
  current_common="$(canonical_directory "$(absolute_common_directory "$current_root")")"
  if [[ "$current_git" == "$current_common" ]]; then
    printf 'primary\n'
    return
  fi

  ghostty_marker="$(submodule_state_marker "$current_root" "$ghostty_submodule")"
  zmx_marker="$(submodule_state_marker "$current_root" "$zmx_submodule")"
  if [[ "$ghostty_marker" == "-" && "$zmx_marker" == "-" ]] &&
    exact_shared_links_exist "$current_root" "$primary_root" &&
    [[ ! -L "$current_root/$ghostty_resources_relative" ]] &&
    [[ -d "$current_root/$ghostty_resources_relative" ]] &&
    [[ ! -L "$current_root/$ghostty_terminfo_relative" ]] &&
    [[ -f "$current_root/$ghostty_terminfo_relative" ]]; then
    printf 'shared\n'
  elif [[ "$ghostty_marker" == " " && "$zmx_marker" == " " ]] &&
    local_outputs_exist "$current_root"; then
    printf 'local\n'
  else
    printf 'partial\n'
  fi
}

verify_shared() {
  local current_root="$1"
  local primary_root="$2"

  require_shared_primary_ready "$current_root" "$primary_root"
  [[ "$(submodule_state_marker "$current_root" "$ghostty_submodule")" == "-" ]] ||
    fail "shared worktree must not hydrate $ghostty_submodule"
  [[ "$(submodule_state_marker "$current_root" "$zmx_submodule")" == "-" ]] ||
    fail "shared worktree must not hydrate $zmx_submodule"
  exact_shared_links_exist "$current_root" "$primary_root" ||
    fail "shared vendor links are missing or point at the wrong primary outputs"
  require_real_directory "$current_root/$ghostty_resources_relative"
  require_no_nested_symlinks "$current_root/$ghostty_resources_relative"
  require_real_file "$current_root/$ghostty_terminfo_relative"
  resource_copies_match "$current_root" "$primary_root" ||
    fail "shared Ghostty resource copies are stale; run: mise run setup"
}

verify_local() {
  local current_root="$1"
  local submodule
  local gitlink
  local checkout

  for submodule in "$ghostty_submodule" "$zmx_submodule"; do
    gitlink="$(gitlink_revision "$current_root" "$submodule")"
    checkout="$(submodule_checked_out_revision "$current_root" "$submodule")"
    [[ "$gitlink" == "$checkout" ]] ||
      fail "local $submodule checkout does not match its committed gitlink"
  done
  require_prepared_sources "$current_root"
}

verify_current() {
  local current_root="$1"
  local primary_root="$2"
  local role

  if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
    require_ci_prepared_sources "$current_root"
    return
  fi

  role="$(worktree_role "$current_root" "$primary_root")"
  case "$role" in
    primary | local)
      verify_local "$current_root"
      ;;
    shared)
      verify_shared "$current_root" "$primary_root"
      ;;
    *)
      fail "vendor state is partial; run mise run setup, or use --use-local-vendors only for authorized vendor work"
      ;;
  esac
}

publish_directory_copy() (
  local source="$1"
  local destination="$2"
  local destination_parent
  local temporary_copy

  destination_parent="$(dirname "$destination")"
  mkdir -p "$destination_parent"
  temporary_copy="$(mktemp -d "$destination_parent/.vendor-worktree-copy.XXXXXX")"
  trap '[[ -z "$temporary_copy" ]] || rm -rf -- "$temporary_copy"' EXIT
  cp -R "$source/." "$temporary_copy/"
  if [[ -e "$destination" ]]; then
    rm -rf "$destination"
  fi
  mv "$temporary_copy" "$destination"
  temporary_copy=""
)

publish_file_copy() (
  local source="$1"
  local destination="$2"
  local destination_parent
  local temporary_copy

  destination_parent="$(dirname "$destination")"
  mkdir -p "$destination_parent"
  temporary_copy="$(mktemp "$destination_parent/.vendor-worktree-copy.XXXXXX")"
  trap '[[ -z "$temporary_copy" ]] || rm -f -- "$temporary_copy"' EXIT
  cp "$source" "$temporary_copy"
  if [[ -e "$destination" ]]; then
    rm -f "$destination"
  fi
  mv "$temporary_copy" "$destination"
  temporary_copy=""
)

setup_shared() {
  local current_root="$1"
  local primary_root="$2"
  local current_role
  local framework_source="$primary_root/$framework_relative"
  local framework_destination="$current_root/$framework_relative"
  local zmx_source="$primary_root/$zmx_output_relative"
  local zmx_destination="$current_root/$zmx_output_relative"
  local resources_source="$primary_root/$ghostty_resources_relative"
  local resources_destination="$current_root/$ghostty_resources_relative"
  local terminfo_source="$primary_root/$ghostty_terminfo_relative"
  local terminfo_destination="$current_root/$ghostty_terminfo_relative"

  current_role="$(worktree_role "$current_root" "$primary_root")"
  if [[ "$current_role" == "primary" || "$current_role" == "local" ]]; then
    verify_local "$current_root"
    printf '[vendor-worktree] preserving %s vendor outputs\n' "$current_role"
    return
  fi

  [[ "$(submodule_state_marker "$current_root" "$ghostty_submodule")" == "-" ]] &&
    [[ "$(submodule_state_marker "$current_root" "$zmx_submodule")" == "-" ]] ||
    fail "partial local vendor state requires: mise run setup --use-local-vendors"

  require_shared_primary_ready "$current_root" "$primary_root"
  ensure_parent_chain_has_no_symlink "$current_root" "$framework_relative"
  ensure_parent_chain_has_no_symlink "$current_root" "$zmx_output_relative"
  ensure_parent_chain_has_no_symlink "$current_root" "$ghostty_resources_relative"
  ensure_parent_chain_has_no_symlink "$current_root" "$ghostty_terminfo_relative"
  require_exact_or_missing_symlink_destination "$framework_destination" "$framework_source"
  require_exact_or_missing_symlink_destination "$zmx_destination" "$zmx_source"
  preflight_local_resource_destination "$resources_destination" directory
  preflight_local_resource_destination "$terminfo_destination" file

  mkdir -p "$(dirname "$framework_destination")" "$(dirname "$zmx_destination")"
  if [[ ! -L "$framework_destination" ]]; then
    ln -s "$framework_source" "$framework_destination"
  fi
  if [[ ! -L "$zmx_destination" ]]; then
    ln -s "$zmx_source" "$zmx_destination"
  fi
  publish_directory_copy "$resources_source" "$resources_destination"
  publish_file_copy "$terminfo_source" "$terminfo_destination"
  verify_shared "$current_root" "$primary_root"
  printf '[vendor-worktree] shared vendor inputs prepared from %s\n' "$primary_root"
}

preflight_local_output_destination() {
  local role="$1"
  local destination="$2"
  local expected_shared_target="$3"

  if [[ -L "$destination" ]]; then
    [[ "$(readlink "$destination")" == "$expected_shared_target" ]] ||
      fail "foreign symlink collision: $destination"
  elif [[ -e "$destination" ]]; then
    if [[ "$role" != "local" || ! -d "$destination" ]]; then
      fail "unexpected local vendor output collision: $destination"
    fi
  fi
}

preflight_local_resource_destination() {
  local destination="$1"
  local expected_type="$2"

  [[ ! -L "$destination" ]] || fail "resource destination must not be a symlink: $destination"
  if [[ -e "$destination" ]]; then
    case "$expected_type" in
      directory)
        [[ -d "$destination" ]] || fail "resource destination must be a directory: $destination"
        require_no_nested_symlinks "$destination"
        ;;
      file)
        [[ -f "$destination" ]] || fail "resource destination must be a file: $destination"
        ;;
    esac
  fi
}

remove_exact_shared_link() {
  local destination="$1"
  local expected_shared_target="$2"

  if [[ -L "$destination" ]]; then
    [[ "$(readlink "$destination")" == "$expected_shared_target" ]] ||
      fail "refusing to remove foreign symlink: $destination"
    unlink "$destination"
  fi
}

setup_local() {
  local current_root="$1"
  local primary_root="$2"
  local role
  local output_preflight_role
  local framework_destination="$current_root/$framework_relative"
  local zmx_destination="$current_root/$zmx_output_relative"
  local resources_destination="$current_root/$ghostty_resources_relative"
  local terminfo_destination="$current_root/$ghostty_terminfo_relative"

  role="$(worktree_role "$current_root" "$primary_root")"
  if [[ "$role" == "primary" ]]; then
    mise run copy-xcframework
    mise run --skip-deps setup-dev-resources
    mise run --skip-deps build-zmx
    verify_local "$current_root"
    return
  fi

  output_preflight_role="$role"
  if [[ "$role" == "partial" ]] && local_inputs_are_hydrated "$current_root"; then
    output_preflight_role="local"
  fi

  ensure_parent_chain_has_no_symlink "$current_root" "$framework_relative"
  ensure_parent_chain_has_no_symlink "$current_root" "$zmx_output_relative"
  ensure_parent_chain_has_no_symlink "$current_root" "$ghostty_resources_relative"
  ensure_parent_chain_has_no_symlink "$current_root" "$ghostty_terminfo_relative"
  preflight_local_output_destination \
    "$output_preflight_role" \
    "$framework_destination" \
    "$primary_root/$framework_relative"
  preflight_local_output_destination \
    "$output_preflight_role" \
    "$zmx_destination" \
    "$primary_root/$zmx_output_relative"
  preflight_local_resource_destination "$resources_destination" directory
  preflight_local_resource_destination "$terminfo_destination" file

  remove_exact_shared_link \
    "$framework_destination" \
    "$primary_root/$framework_relative"
  remove_exact_shared_link \
    "$zmx_destination" \
    "$primary_root/$zmx_output_relative"
  if [[ -e "$resources_destination" ]]; then
    rm -rf "$resources_destination"
  fi
  if [[ -e "$terminfo_destination" ]]; then
    rm -f "$terminfo_destination"
  fi

  git -C "$current_root" submodule update --init --recursive -- \
    "$ghostty_submodule" "$zmx_submodule"
  local_inputs_are_hydrated "$current_root" ||
    fail "local vendor submodules did not hydrate at the committed gitlinks"

  (
    cd "$current_root"
    export _AGENTSTUDIO_VENDOR_SETUP_LOCAL_TRANSITION=1
    mise run copy-xcframework
    mise run --skip-deps setup-dev-resources
    mise run --skip-deps build-zmx
  )
  verify_local "$current_root"
  printf '[vendor-worktree] local vendor inputs built in %s\n' "$current_root"
}

require_producer() {
  local current_root="$1"
  local primary_root="$2"
  local role

  role="$(worktree_role "$current_root" "$primary_root")"
  if [[ "$role" == "primary" ]]; then
    require_safe_producer_paths "$current_root"
    return
  fi
  if [[ "$role" == "local" ]]; then
    verify_local "$current_root"
    require_safe_producer_paths "$current_root"
    return
  fi
  if [[ "${_AGENTSTUDIO_VENDOR_SETUP_LOCAL_TRANSITION:-0}" == "1" ]]; then
    local_inputs_are_hydrated "$current_root" ||
      fail "local setup transition does not have hydrated vendor inputs"
    require_safe_producer_paths "$current_root"
    return
  fi
  fail "vendor producer is unavailable in a $role worktree; use mise run setup"
}

main() {
  local operation="${1:-}"
  local current_root
  local primary_root

  [[ -n "$operation" ]] ||
    fail "usage: scripts/vendor-worktree.sh role|setup-shared|setup-local|verify|require-producer"
  [[ "$#" -eq 1 ]] || fail "this helper does not accept arbitrary paths"
  current_root="$(canonical_directory "$(repository_root)")"
  primary_root="$(primary_worktree_root "$current_root")"

  case "$operation" in
    role)
      worktree_role "$current_root" "$primary_root"
      ;;
    setup-shared)
      setup_shared "$current_root" "$primary_root"
      ;;
    setup-local)
      setup_local "$current_root" "$primary_root"
      ;;
    verify)
      verify_current "$current_root" "$primary_root"
      ;;
    require-producer)
      require_producer "$current_root" "$primary_root"
      ;;
    *)
      fail "unknown operation: $operation"
      ;;
  esac
}

main "$@"
