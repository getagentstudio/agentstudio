#!/bin/bash
set -Eeuo pipefail

umask 077

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STANDARD_DEBUG_RUNNER="$PROJECT_ROOT/scripts/run-debug-observability.sh"
DEFAULT_OBSERVABILITY_STATE_FILE="$PROJECT_ROOT/tmp/debug-observability/latest-observability.env"
DEFAULT_JOURNEY_STATE_FILE="$PROJECT_ROOT/tmp/debug-observability/latest-bridge-packaged-product-journey.env"
OBSERVABILITY_STATE_FILE="${AGENTSTUDIO_OBSERVABILITY_STATE_FILE:-$DEFAULT_OBSERVABILITY_STATE_FILE}"
JOURNEY_STATE_FILE="${AGENTSTUDIO_BRIDGE_PACKAGED_JOURNEY_STATE_FILE:-$DEFAULT_JOURNEY_STATE_FILE}"
GIT_BIN="${AGENTSTUDIO_BRIDGE_PACKAGED_PRODUCT_JOURNEY_GIT_BIN:-/usr/bin/git}"
SHASUM_BIN="${AGENTSTUDIO_BRIDGE_PACKAGED_PRODUCT_JOURNEY_SHASUM_BIN:-/usr/bin/shasum}"
LSOF_BIN="${AGENTSTUDIO_LSOF_BIN:-/usr/sbin/lsof}"
PROCESS_SIGNAL_COMMAND=kill
FIXTURE_REPOSITORY_URL=https://github.com/askluna/fork-for-fixture-agentstudio.git
FIXTURE_BASE_REF=fixture-for-bridge-review-performance-2026-09-02-base
FIXTURE_BASE_SHA=246c9a81c256ded9431620ae9c8cd99f4a27622d
FIXTURE_HEAD_REF=fixture-for-bridge-review-performance-2026-09-02-head
FIXTURE_HEAD_SHA=40441ec0ad71c48bdc9d8611c2308ed788f65216
MINIMUM_REAL_FIXTURE_TRACKED_FILE_COUNT=3886
MINIMUM_REAL_FIXTURE_REVIEW_DIFF_COUNT=925
MINIMUM_REAL_FIXTURE_DIFF_HUNK_COUNT=4321
MINIMUM_REAL_FIXTURE_CHANGED_CONTENT_LINE_COUNT=354002
MINIMUM_REAL_FIXTURE_CHANGED_CONTENT_BYTE_COUNT=14000000

dry_run=false
complete_journey=false

usage() {
  cat <<'USAGE'
Usage: run-bridge-packaged-product-journey.sh [--dry-run] [--complete-journey]

Creates the disposable current-run fixture and delegates the packaged app launch
to the standard AgentStudio debug observability runner. The launched app and its
fixture remain available for the separate verifier and PID-targeted visual proof.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      dry_run=true
      shift
      ;;
    --complete-journey)
      complete_journey=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$dry_run" = true ]; then
  echo "dry-run contract: delegates to the standard debug observability runner"
  echo "dry-run contract: requires strict LaunchServices with direct fallback disabled"
  echo "dry-run contract: isolates application state inside the current packaged journey"
  echo "dry-run contract: starts the bridge-product-paint-correlation diagnostic with one-shot IPC escrow"
  echo "dry-run contract: seeds a designated default and an explicit symbolic comparison target"
  echo "dry-run contract: prepares same-tree target and shared-base movement without changing fixture bytes"
  echo "dry-run contract: preserves the fixture and app for verification"
  echo "dry-run contract: interactive verification mode preserves the existing single live app journey"
  echo "dry-run contract: complete journey cohort mode uses exactly 3 independent LaunchServices launches"
  echo "dry-run contract: complete journey cohort mode records 100 attempts per journey by default"
  echo "dry-run contract: complete journey cohort mode isolates app data, preserves raw receipts, and stops only each exact PID"
  if [ "$complete_journey" = true ]; then
    echo "dry-run contract: complete journey cohort mode materializes the pinned real Agent Studio fixture repository"
    echo "dry-run contract: verifies exact fixture base and head commit identities before launch"
    echo "dry-run contract: never falls back to the synthetic fixture"
  else
    echo "dry-run contract: creates a private disposable hierarchical Git fixture outside the repo"
    echo "dry-run contract: starts with 257 initial Review diffs across the hierarchical fixture"
  fi
  exit 0
fi

if [ ! -x "$STANDARD_DEBUG_RUNNER" ]; then
  echo "standard debug observability runner is not executable: $STANDARD_DEBUG_RUNNER" >&2
  exit 1
fi
if [ ! -x "$GIT_BIN" ]; then
  echo "fixture Git executable is not available: $GIT_BIN" >&2
  exit 1
fi
if [ ! -x "$SHASUM_BIN" ]; then
  echo "fixture SHA-256 executable is not available: $SHASUM_BIN" >&2
  exit 1
fi
if [ ! -x "$LSOF_BIN" ]; then
  echo "process attribution executable is not available: $LSOF_BIN" >&2
  exit 1
fi

decode_state_value() {
  local raw_value="${1:-}"
  /usr/bin/python3 - "$raw_value" <<'PY'
import shlex
import sys

try:
    parsed = shlex.split(sys.argv[1])
except ValueError:
    parsed = []
print(parsed[0] if parsed else "")
PY
}

identity_value() {
  local key="${1:?missing identity key}"
  local raw_value
  raw_value="$(sed -n "s/^${key}=//p" <<<"$identity_output" | tail -1)"
  decode_state_value "$raw_value"
}

write_state_value() {
  local key="${1:?missing state key}"
  local value="${2:-}"
  printf '%s=%q\n' "$key" "$value"
}

state_value() {
  local state_file="${1:?missing state file}"
  local key="${2:?missing state key}"
  local raw_value
  raw_value="$(sed -n "s/^${key}=//p" "$state_file" | tail -1)"
  decode_state_value "$raw_value"
}

process_executable_path() {
  local exact_pid="${1:?missing exact PID}"
  "$LSOF_BIN" -a -p "$exact_pid" -d txt -Fn 2>/dev/null \
    | awk '/^n/ && !found { print substr($0, 2); found = 1 }'
}

terminate_exact_launch_pid() {
  local exact_pid="${1:?missing exact PID}"
  local expected_executable="${2:?missing expected executable}"
  local actual_executable
  actual_executable="$(process_executable_path "$exact_pid")"
  if [ -z "$actual_executable" ] \
    || [ "$(realpath "$actual_executable")" != "$(realpath "$expected_executable")" ]; then
    echo "refusing to terminate PID whose executable does not match the recorded candidate: $exact_pid" >&2
    return 1
  fi
  "$PROCESS_SIGNAL_COMMAND" -TERM "$exact_pid"
  local wait_attempt=1
  while "$PROCESS_SIGNAL_COMMAND" -0 "$exact_pid" >/dev/null 2>&1 \
    && [ "$wait_attempt" -le 120 ]; do
    sleep 1
    wait_attempt=$((wait_attempt + 1))
  done
  if "$PROCESS_SIGNAL_COMMAND" -0 "$exact_pid" >/dev/null 2>&1; then
    echo "exact packaged candidate PID did not exit after termination: $exact_pid" >&2
    return 1
  fi
}

sha256_for_file() {
  local file_path="${1:?missing file path}"
  "$SHASUM_BIN" -a 256 "$file_path" | awk '{ print $1 }'
}

fixture_digest_for_current_worktree() {
  local fixture_path="${1:?missing fixture path}"
  local fixture_baseline="${2:?missing fixture baseline}"
  local content_oid
  local index_metadata
  local index_mode
  local index_oid
  local index_record
  local relative_path
  {
    printf 'baseline\0%s\0' "$fixture_baseline"
    while IFS= read -r -d '' index_record; do
      index_metadata="${index_record%%$'\t'*}"
      relative_path="${index_record#*$'\t'}"
      read -r index_mode index_oid _ <<<"$index_metadata"
      if [ "$index_mode" = 160000 ]; then
        content_oid="$index_oid"
      else
        content_oid="$($GIT_BIN -C "$fixture_path" hash-object -- "$relative_path")"
      fi
      printf 'path\0%s\0blob\0%s\0' "$relative_path" "$content_oid"
    done < <("$GIT_BIN" -C "$fixture_path" ls-files -s -z)
  } | "$SHASUM_BIN" -a 256 | awk '{ print $1 }'
}

resolve_remote_fixture_ref() {
  local fixture_ref="${1:?missing fixture ref}"
  "$GIT_BIN" ls-remote --exit-code "$FIXTURE_REPOSITORY_URL" "refs/heads/$fixture_ref" \
    | awk 'NR == 1 { print $1 }'
}

measure_real_fixture_profile() {
  /usr/bin/python3 - "$fixture_root" "$baseline_commit" "$FIXTURE_HEAD_SHA" "$GIT_BIN" <<'PY'
import os
import subprocess
import sys

fixture_root, base_sha, head_sha, git_bin = sys.argv[1:]


def git_bytes(*arguments):
    return subprocess.check_output([git_bin, "-C", fixture_root, *arguments])


tracked_paths = [
    os.fsdecode(path)
    for path in git_bytes("ls-files", "-z").split(b"\0")
    if path
]
changed_paths = [
    os.fsdecode(path)
    for path in git_bytes(
        "diff", "--no-renames", "--name-only", "-z", base_sha, head_sha, "--"
    ).split(b"\0")
    if path
]

changed_content_line_count = 0
changed_content_byte_count = 0
changed_regular_files = []
for relative_path in changed_paths:
    absolute_path = os.path.join(fixture_root, relative_path)
    if not os.path.isfile(absolute_path):
        continue
    with open(absolute_path, "rb") as source_file:
        content = source_file.read()
    changed_content_line_count += content.count(b"\n")
    changed_content_byte_count += len(content)
    changed_regular_files.append((len(content), relative_path))

if len(changed_regular_files) < 3:
    raise SystemExit("pinned fixture has fewer than three changed regular files")

diff_process = subprocess.Popen(
    [git_bin, "-C", fixture_root, "diff", "--no-color", "--unified=0", base_sha, head_sha, "--"],
    stdout=subprocess.PIPE,
)
if diff_process.stdout is None:
    raise SystemExit("pinned fixture diff stream is unavailable")
diff_hunk_count = sum(1 for line in diff_process.stdout if line.startswith(b"@@ "))
if diff_process.wait() != 0:
    raise SystemExit("pinned fixture diff failed while measuring hunks")

paths_in_catalog_order = sorted(path for _, path in changed_regular_files)
files_in_size_order = sorted(changed_regular_files)
early_path = paths_in_catalog_order[0]
middle_path = files_in_size_order[len(files_in_size_order) // 2][1]
final_path = paths_in_catalog_order[-1]

profile_values = (
    len(tracked_paths),
    len(changed_paths),
    diff_hunk_count,
    changed_content_line_count,
    changed_content_byte_count,
    early_path,
    middle_path,
    final_path,
)
if any("\t" in str(value) or "\n" in str(value) for value in profile_values):
    raise SystemExit("pinned fixture profile contains an unsupported path delimiter")
print("\t".join(str(value) for value in profile_values))
PY
}

prepare_pinned_real_fixture() {
  local remote_base_sha
  local remote_head_sha
  local profile

  remote_base_sha="$(resolve_remote_fixture_ref "$FIXTURE_BASE_REF")"
  remote_head_sha="$(resolve_remote_fixture_ref "$FIXTURE_HEAD_REF")"
  if [ "$remote_base_sha" != "$FIXTURE_BASE_SHA" ]; then
    echo "pinned fixture base ref SHA mismatch: expected $FIXTURE_BASE_SHA, observed ${remote_base_sha:-<missing>}" >&2
    return 1
  fi
  if [ "$remote_head_sha" != "$FIXTURE_HEAD_SHA" ]; then
    echo "pinned fixture head ref SHA mismatch: expected $FIXTURE_HEAD_SHA, observed ${remote_head_sha:-<missing>}" >&2
    return 1
  fi

  "$GIT_BIN" -C "$fixture_root" init -q
  "$GIT_BIN" -C "$fixture_root" remote add origin "$FIXTURE_REPOSITORY_URL"
  "$GIT_BIN" -C "$fixture_root" fetch --no-tags origin \
    "refs/heads/$FIXTURE_BASE_REF:refs/fixture-source/base" \
    "refs/heads/$FIXTURE_HEAD_REF:refs/fixture-source/head"
  fixture_base_sha="$($GIT_BIN -C "$fixture_root" rev-parse refs/fixture-source/base)"
  fixture_head_sha="$($GIT_BIN -C "$fixture_root" rev-parse refs/fixture-source/head)"
  if [ "$fixture_base_sha" != "$FIXTURE_BASE_SHA" ] \
    || [ "$fixture_head_sha" != "$FIXTURE_HEAD_SHA" ]; then
    echo "fetched fixture authority does not match the pinned base/head commits" >&2
    return 1
  fi
  if "$GIT_BIN" -C "$fixture_root" rev-list --objects --missing=print \
    "$fixture_base_sha" "$fixture_head_sha" | awk '/^\?/ { missing = 1 } END { exit missing ? 0 : 1 }'; then
    echo "pinned fixture materialization is missing reachable Git objects" >&2
    return 1
  fi

  "$GIT_BIN" -C "$fixture_root" config user.name "AgentStudio Packaged Journey"
  "$GIT_BIN" -C "$fixture_root" config user.email "agentstudio-packaged-journey@invalid.local"
  "$GIT_BIN" -C "$fixture_root" config commit.gpgsign false
  "$GIT_BIN" -C "$fixture_root" checkout -q -b "$reviewed_branch_name" "$fixture_head_sha"
  baseline_commit="$fixture_base_sha"
  "$GIT_BIN" -C "$fixture_root" update-ref "refs/heads/$default_branch_name" "$baseline_commit"
  "$GIT_BIN" -C "$fixture_root" update-ref \
    "refs/remotes/origin/$default_branch_name" "$baseline_commit"
  "$GIT_BIN" -C "$fixture_root" symbolic-ref \
    refs/remotes/origin/HEAD "refs/remotes/origin/$default_branch_name"
  "$GIT_BIN" -C "$fixture_root" update-ref \
    "refs/heads/$comparison_target_name" "$baseline_commit"

  profile="$(measure_real_fixture_profile)"
  IFS=$'\t' read -r fixture_file_count review_diff_count diff_hunk_count \
    changed_content_line_count changed_content_byte_count early_relative_path \
    middle_relative_path final_relative_path <<<"$profile"
  tracked_file_count="$fixture_file_count"
  tracked_relative_path="$early_relative_path"

  if [ "$tracked_file_count" -lt "$MINIMUM_REAL_FIXTURE_TRACKED_FILE_COUNT" ] \
    || [ "$review_diff_count" -lt "$MINIMUM_REAL_FIXTURE_REVIEW_DIFF_COUNT" ] \
    || [ "$diff_hunk_count" -lt "$MINIMUM_REAL_FIXTURE_DIFF_HUNK_COUNT" ] \
    || [ "$changed_content_line_count" -lt "$MINIMUM_REAL_FIXTURE_CHANGED_CONTENT_LINE_COUNT" ] \
    || [ "$changed_content_byte_count" -lt "$MINIMUM_REAL_FIXTURE_CHANGED_CONTENT_BYTE_COUNT" ]; then
    echo "pinned fixture workload is below the required real-repository envelope" >&2
    return 1
  fi
  if [ -n "$("$GIT_BIN" -C "$fixture_root" status --porcelain --untracked-files=all)" ]; then
    echo "pinned fixture materialization is not clean" >&2
    return 1
  fi

  early_baseline_sha256="$(sha256_for_file "$fixture_root/$early_relative_path")"
  middle_baseline_sha256="$(sha256_for_file "$fixture_root/$middle_relative_path")"
  final_baseline_sha256="$(sha256_for_file "$fixture_root/$final_relative_path")"
  tracked_sha256="$early_baseline_sha256"
  tracked_byte_count="$(wc -c <"$fixture_root/$tracked_relative_path" | tr -d '[:space:]')"
  fixture_digest="$(fixture_digest_for_current_worktree "$fixture_root" "$baseline_commit")"
}

identity_output="$($STANDARD_DEBUG_RUNNER --print-identity)"
debug_code="$(identity_value AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE)"
debug_data_root="$(identity_value AGENTSTUDIO_OBSERVABILITY_DATA_DIR)"
if [ -z "$debug_code" ] || [ -z "$debug_data_root" ]; then
  echo "standard debug observability runner returned incomplete worktree identity" >&2
  exit 1
fi

# Refuse before fixture creation when this worktree's debug app already exists.
# The standard owner performs process attribution and emits the authoritative error.
AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$OBSERVABILITY_STATE_FILE" \
  "$STANDARD_DEBUG_RUNNER" --preflight-idle

run_identifier="$(date -u +%Y%m%dT%H%M%SZ)-$$-$(uuidgen | tr '[:upper:]' '[:lower:]')"
journey_root="$debug_data_root/bridge-packaged-product-journeys/$run_identifier"
runtime_data_root="$journey_root/app-data"
fixture_root="$journey_root/fixture"
run_state_file="$journey_root/journey.env"
mkdir -p "$fixture_root" "$(dirname "$JOURNEY_STATE_FILE")"
chmod 700 "$journey_root" "$fixture_root"
ipc_debug_escrow_path="$(/usr/bin/python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$journey_root/ipc-escrow.json")"

journey_status=preparing
journey_reason=""
fixture_file_count=0
review_diff_count=0
fixture_digest=""
baseline_commit=""
fixture_identity=synthetic-hierarchical-worktree
fixture_base_sha=""
fixture_head_sha=""
tracked_file_count=0
diff_hunk_count=0
changed_content_line_count=0
changed_content_byte_count=0
reviewed_branch_name=journey-reviewed
default_branch_name=journey-integration
comparison_target_name=journey-stack-base
tracked_relative_path=tracked.txt
tracked_sha256=""
tracked_byte_count=0
early_relative_path="tree/group-00/segment-00/file-000.swift"
middle_relative_path="tree/group-04/segment-00/file-128.swift"
final_relative_path="tree/group-07/segment-03/file-255.swift"
early_baseline_sha256=""
middle_baseline_sha256=""
final_baseline_sha256=""
complete_journey_attempt_count="${AGENTSTUDIO_BRIDGE_COMPLETE_JOURNEY_ATTEMPTS:-100}"
source_head="$(/usr/bin/git -C "$PROJECT_ROOT" rev-parse HEAD)"
journey_mode=interactive
active_launch_pid=""
active_launch_executable=""

if [ "$complete_journey" = true ]; then
  journey_mode=complete-journey
  case "$complete_journey_attempt_count" in
    ''|*[!0-9]*)
      echo "complete journey attempt count must be a positive integer" >&2
      exit 2
      ;;
  esac
  if [ "$complete_journey_attempt_count" -le 0 ] || [ "$complete_journey_attempt_count" -gt 10000 ]; then
    echo "complete journey attempt count must be between 1 and 10000" >&2
    exit 2
  fi
fi

write_receipt() {
  local status="${1:?missing journey status}"
  local reason="${2:-}"
  local temporary_run_state="$run_state_file.tmp"
  local temporary_latest_state="$JOURNEY_STATE_FILE.tmp"

  {
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_SCHEMA_VERSION 1
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_STATUS "$status"
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_REASON "$reason"
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_MODE "$journey_mode"
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_COMPLETE_ATTEMPT_COUNT "$complete_journey_attempt_count"
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_SOURCE_HEAD "$source_head"
    write_state_value DEBUG_CODE "$debug_code"
    write_state_value JOURNEY_ROOT "$journey_root"
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_DATA_ROOT "$runtime_data_root"
    write_state_value RUN_STATE_FILE "$run_state_file"
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_OBSERVABILITY_STATE_FILE "$OBSERVABILITY_STATE_FILE"
    write_state_value AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW "$ipc_debug_escrow_path"
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_FIXTURE_ROOT "$fixture_root"
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_FIXTURE_IDENTITY "$fixture_identity"
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_FIXTURE_BASE_SHA "$fixture_base_sha"
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_FIXTURE_HEAD_SHA "$fixture_head_sha"
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_TRACKED_FILE_COUNT "$tracked_file_count"
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_DIFF_HUNK_COUNT "$diff_hunk_count"
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_CHANGED_CONTENT_LINE_COUNT "$changed_content_line_count"
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_CHANGED_CONTENT_BYTE_COUNT "$changed_content_byte_count"
    write_state_value STARTUP_ACTION bridge-product-paint-correlation
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_EXPECTED_FILE_COUNT "$fixture_file_count"
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_EXPECTED_REVIEW_DIFF_COUNT "$review_diff_count"
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_FIXTURE_DIGEST "$fixture_digest"
    write_state_value BASELINE_COMMIT "$baseline_commit"
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_REVIEWED_BRANCH_NAME "$reviewed_branch_name"
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_DEFAULT_BRANCH_NAME "$default_branch_name"
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_TARGET_NAME "$comparison_target_name"
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_TRACKED_PATH "$tracked_relative_path"
    write_state_value TRACKED_CANARY bridge-product-paint-canary
    write_state_value TRACKED_SHA256 "$tracked_sha256"
    write_state_value TRACKED_BYTE_COUNT "$tracked_byte_count"
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_EARLY_PATH "$early_relative_path"
    write_state_value EARLY_BASELINE_SHA256 "$early_baseline_sha256"
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_MIDDLE_PATH "$middle_relative_path"
    write_state_value MIDDLE_BASELINE_SHA256 "$middle_baseline_sha256"
    write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_FINAL_PATH "$final_relative_path"
    write_state_value FINAL_BASELINE_SHA256 "$final_baseline_sha256"
  } >"$temporary_run_state"
  chmod 600 "$temporary_run_state"
  mv "$temporary_run_state" "$run_state_file"
  /usr/bin/ditto "$run_state_file" "$temporary_latest_state"
  chmod 600 "$temporary_latest_state"
  mv "$temporary_latest_state" "$JOURNEY_STATE_FILE"
}

record_unexpected_failure() {
  local exit_code="$1"
  local line_number="$2"
  trap - ERR
  if [ -n "$active_launch_pid" ] \
    && "$PROCESS_SIGNAL_COMMAND" -0 "$active_launch_pid" >/dev/null 2>&1; then
    terminate_exact_launch_pid "$active_launch_pid" "$active_launch_executable" || true
  fi
  journey_status=failed
  journey_reason="unexpected_failure_line_${line_number}_exit_${exit_code}"
  write_receipt "$journey_status" "$journey_reason" || true
  echo "packaged product journey preparation failed; preserved fixture: $fixture_root" >&2
  exit "$exit_code"
}

trap 'record_unexpected_failure "$?" "$LINENO"' ERR
write_receipt "$journey_status" "$journey_reason"

if [ "$complete_journey" = true ]; then
  fixture_identity=pinned-real-worktree
  prepare_pinned_real_fixture
else
  "$GIT_BIN" -C "$fixture_root" init -q
  "$GIT_BIN" -C "$fixture_root" symbolic-ref HEAD "refs/heads/$reviewed_branch_name"
  "$GIT_BIN" -C "$fixture_root" config user.name "AgentStudio Packaged Journey"
  "$GIT_BIN" -C "$fixture_root" config user.email "agentstudio-packaged-journey@invalid.local"
  "$GIT_BIN" -C "$fixture_root" config commit.gpgsign false

  printf 'bridge-product-paint-baseline\n' >"$fixture_root/$tracked_relative_path"
  fixture_file_count=1
  for index in $(seq 0 255); do
    group_index=$((index / 32))
    segment_index=$(((index % 32) / 8))
    printf -v relative_path 'tree/group-%02d/segment-%02d/file-%03d.swift' \
      "$group_index" "$segment_index" "$index"
    mkdir -p "$(dirname "$fixture_root/$relative_path")"
    printf '// bridge packaged journey baseline %03d\nlet fixtureValue%03d = %d\n' \
      "$index" "$index" "$index" >"$fixture_root/$relative_path"
    fixture_file_count=$((fixture_file_count + 1))
  done

  if [ "$fixture_file_count" -ne 257 ]; then
    echo "fixture file count mismatch: expected 257, observed $fixture_file_count" >&2
    exit 1
  fi

  early_baseline_sha256="$(sha256_for_file "$fixture_root/$early_relative_path")"
  middle_baseline_sha256="$(sha256_for_file "$fixture_root/$middle_relative_path")"
  final_baseline_sha256="$(sha256_for_file "$fixture_root/$final_relative_path")"

  "$GIT_BIN" -C "$fixture_root" add -- .
  "$GIT_BIN" -C "$fixture_root" commit -q -m "fixture: establish packaged journey baseline"
  baseline_commit="$($GIT_BIN -C "$fixture_root" rev-parse HEAD)"
  "$GIT_BIN" -C "$fixture_root" update-ref "refs/heads/$default_branch_name" "$baseline_commit"
  "$GIT_BIN" -C "$fixture_root" update-ref \
    "refs/remotes/origin/$default_branch_name" "$baseline_commit"
  "$GIT_BIN" -C "$fixture_root" symbolic-ref \
    refs/remotes/origin/HEAD "refs/remotes/origin/$default_branch_name"
  "$GIT_BIN" -C "$fixture_root" update-ref \
    "refs/heads/$comparison_target_name" "$baseline_commit"

  printf 'bridge-product-paint-canary\npackaged-journey-selected-source\n' \
    >"$fixture_root/$tracked_relative_path"
  for index in $(seq 0 255); do
    group_index=$((index / 32))
    segment_index=$(((index % 32) / 8))
    printf -v relative_path 'tree/group-%02d/segment-%02d/file-%03d.swift' \
      "$group_index" "$segment_index" "$index"
    printf '\nbridge-packaged-live::%s\n' "$relative_path" >>"$fixture_root/$relative_path"
  done
  tracked_sha256="$(sha256_for_file "$fixture_root/$tracked_relative_path")"
  tracked_byte_count="$(wc -c <"$fixture_root/$tracked_relative_path" | tr -d '[:space:]')"

  review_diff_count="$(
    "$GIT_BIN" -C "$fixture_root" diff --no-renames --name-only "$baseline_commit" -- \
      | awk 'NF { count += 1 } END { print count + 0 }'
  )"
  if [ "$review_diff_count" -ne "$fixture_file_count" ]; then
    echo "fixture Review diff count mismatch: expected $fixture_file_count, observed $review_diff_count" >&2
    exit 1
  fi
  if [ "$review_diff_count" -lt 100 ]; then
    echo "fixture Review diff count is below the required minimum: $review_diff_count" >&2
    exit 1
  fi
  if ! "$GIT_BIN" -C "$fixture_root" diff --cached --quiet --; then
    echo "fixture contains unexpected staged changes after its baseline commit" >&2
    exit 1
  fi
  if [ -n "$("$GIT_BIN" -C "$fixture_root" ls-files --others --exclude-standard)" ]; then
    echo "fixture contains unexpected untracked files after its baseline commit" >&2
    exit 1
  fi
  fixture_digest="$(fixture_digest_for_current_worktree "$fixture_root" "$baseline_commit")"
fi

journey_status=fixture_ready
write_receipt "$journey_status" ""

unset AGENTSTUDIO_IPC_UNSAFE_NO_AUTH
if [ "$complete_journey" = true ]; then
  for launch_number in 1 2 3; do
    launch_id="native-launch-$launch_number"
    launch_data_root="$runtime_data_root/$launch_id"
    launch_config_path="$launch_data_root/bridge-complete-journey/config.json"
    launch_receipt_path="$launch_data_root/bridge-complete-journey/native-launch.json"
    preserved_receipt_path="$journey_root/$launch_id.json"
    launch_state_file="$journey_root/$launch_id-observability.env"
    launch_escrow_path="$(dirname "$ipc_debug_escrow_path")/$launch_id-ipc-escrow.json"
    mkdir -p "$(dirname "$launch_config_path")"
    printf '{"enabled":true,"mode":"native","attemptCount":%s,"launchId":"%s"}\n' \
      "$complete_journey_attempt_count" "$launch_id" >"$launch_config_path"
    chmod 600 "$launch_config_path"

    runner_arguments=(--detach)
    if [ "$launch_number" -gt 1 ]; then
      runner_arguments+=(--skip-build)
    fi
    if ! AGENTSTUDIO_DEBUG_DIRECT_FALLBACK=0 \
      AGENTSTUDIO_DEBUG_LAUNCH_ACTIVATE=1 \
      AGENTSTUDIO_DEBUG_DATA_DIR="$launch_data_root" \
      AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW="$launch_escrow_path" \
      AGENTSTUDIO_STARTUP_WATCH_FOLDER="$fixture_root" \
      AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION=bridge-product-paint-correlation \
      AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$launch_state_file" \
      "$STANDARD_DEBUG_RUNNER" "${runner_arguments[@]}"; then
      journey_status=launch_failed
      journey_reason="${launch_id}_standard_debug_observability_runner_failed"
      write_receipt "$journey_status" "$journey_reason"
      exit 1
    fi

    active_launch_pid="$(state_value "$launch_state_file" AGENTSTUDIO_OBSERVABILITY_PID)"
    active_launch_executable="$(state_value "$launch_state_file" AGENTSTUDIO_OBSERVABILITY_EXECUTABLE)"
    launch_status="$(state_value "$launch_state_file" AGENTSTUDIO_OBSERVABILITY_STATUS)"
    launch_method="$(state_value "$launch_state_file" AGENTSTUDIO_OBSERVABILITY_LAUNCH_METHOD)"
    launch_activation_mode="$(
      state_value "$launch_state_file" AGENTSTUDIO_OBSERVABILITY_ACTIVATION_MODE
    )"
    recorded_launch_data_root="$(state_value "$launch_state_file" AGENTSTUDIO_OBSERVABILITY_DATA_DIR)"
    if [ "$launch_status" != "running" ] || [ "$launch_method" != "launchservices" ]; then
      echo "$launch_id did not start as a strict LaunchServices candidate" >&2
      exit 1
    fi
    if [ "$launch_activation_mode" != "foreground" ]; then
      echo "$launch_id did not request foreground LaunchServices activation" >&2
      exit 1
    fi
    if [ "$recorded_launch_data_root" != "$launch_data_root" ]; then
      echo "$launch_id did not start with its isolated application data root" >&2
      exit 1
    fi
    case "$active_launch_pid" in
      ''|*[!0-9]*)
        echo "$launch_id observability state is missing a numeric PID" >&2
        exit 1
        ;;
    esac
    if [ -z "$active_launch_executable" ] || [ ! -x "$active_launch_executable" ]; then
      echo "$launch_id observability state is missing its executable identity" >&2
      exit 1
    fi

    receipt_wait_attempt=1
    receipt_wait_limit="${AGENTSTUDIO_BRIDGE_COMPLETE_JOURNEY_RECEIPT_WAIT_ATTEMPTS:-7200}"
    case "$receipt_wait_limit" in
      ''|*[!0-9]*)
        echo "complete journey receipt wait attempts must be a positive integer" >&2
        exit 2
        ;;
    esac
    if [ "$receipt_wait_limit" -le 0 ]; then
      echo "complete journey receipt wait attempts must be positive" >&2
      exit 2
    fi
    while { [ ! -f "$launch_receipt_path" ] || [ ! -s "$launch_escrow_path" ]; } \
      && [ "$receipt_wait_attempt" -le "$receipt_wait_limit" ]; do
      if ! "$PROCESS_SIGNAL_COMMAND" -0 "$active_launch_pid" >/dev/null 2>&1; then
        echo "$launch_id exited before producing its complete journey receipt" >&2
        exit 1
      fi
      sleep 1
      receipt_wait_attempt=$((receipt_wait_attempt + 1))
    done
    if [ ! -f "$launch_receipt_path" ]; then
      echo "$launch_id did not produce its complete journey receipt within the bounded wait" >&2
      exit 1
    fi
    if [ ! -s "$launch_escrow_path" ]; then
      echo "$launch_id did not produce debug IPC escrow: AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW=$launch_escrow_path" >&2
      exit 1
    fi
    /usr/bin/python3 - "$launch_receipt_path" "$launch_id" "$complete_journey_attempt_count" <<'PY'
import json
import sys

receipt_path, expected_launch_id, raw_attempt_count = sys.argv[1:]
expected_attempt_count = int(raw_attempt_count)
with open(receipt_path, "r", encoding="utf-8") as receipt_file:
    receipt = json.load(receipt_file)
if receipt.get("launchId") != expected_launch_id:
    raise SystemExit(f"{expected_launch_id} receipt launch identity mismatch")
attempts = receipt.get("attemptsByJourney")
expected_journeys = {"firstFile", "firstReview", "fileToReview", "reviewToFile"}
if not isinstance(attempts, dict) or set(attempts) != expected_journeys:
    raise SystemExit(f"{expected_launch_id} receipt must contain exactly four journey arrays")
for journey in sorted(expected_journeys):
    values = attempts.get(journey)
    if not isinstance(values, list) or len(values) != expected_attempt_count:
        raise SystemExit(f"{expected_launch_id} {journey} attempt count mismatch")
PY
    /usr/bin/ditto "$launch_receipt_path" "$preserved_receipt_path"
    chmod 600 "$preserved_receipt_path"

    launch_pid="$active_launch_pid"
    launch_executable="$active_launch_executable"
    terminate_exact_launch_pid "$launch_pid" "$launch_executable"
    active_launch_pid=""
    active_launch_executable=""
    AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$launch_state_file" \
      "$STANDARD_DEBUG_RUNNER" --preflight-idle
  done

  journey_status=cohort_ready
  journey_reason=""
  write_receipt "$journey_status" "$journey_reason"
  trap - ERR
  echo "Bridge packaged complete journey cohort is ready for verification."
  echo "fixture preserved at: $fixture_root"
  echo "journey state: $JOURNEY_STATE_FILE"
  exit 0
fi

if ! AGENTSTUDIO_DEBUG_DIRECT_FALLBACK=0 \
  AGENTSTUDIO_DEBUG_DATA_DIR="$runtime_data_root" \
  AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW="$ipc_debug_escrow_path" \
  AGENTSTUDIO_STARTUP_WATCH_FOLDER="$fixture_root" \
  AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION=bridge-product-paint-correlation \
  AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$OBSERVABILITY_STATE_FILE" \
  "$STANDARD_DEBUG_RUNNER" --detach; then
  journey_status=launch_failed
  journey_reason=standard_debug_observability_runner_failed
  write_receipt "$journey_status" "$journey_reason"
  echo "packaged product journey launch failed; preserved fixture: $fixture_root" >&2
  exit 1
fi

launched_app_path="$(
  decode_state_value "$(
    sed -n 's/^AGENTSTUDIO_OBSERVABILITY_APP=//p' "$OBSERVABILITY_STATE_FILE" | tail -1
  )"
)"
if [ -z "$launched_app_path" ] || [ ! -d "$launched_app_path" ]; then
  journey_status=launch_failed
  journey_reason=packaged_candidate_activation_failed
  write_receipt "$journey_status" "$journey_reason"
  echo "packaged product journey candidate app is unavailable; preserved fixture: $fixture_root" >&2
  exit 1
fi
if ! /usr/bin/open -a "$launched_app_path"; then
  journey_status=launch_failed
  journey_reason=packaged_candidate_activation_failed
  write_receipt "$journey_status" "$journey_reason"
  echo "packaged product journey candidate activation failed; preserved fixture: $fixture_root" >&2
  exit 1
fi

journey_status=running
journey_reason=""
write_receipt "$journey_status" "$journey_reason"
trap - ERR

echo "Bridge packaged product journey launched through strict LaunchServices."
echo "fixture preserved at: $fixture_root"
echo "journey state: $JOURNEY_STATE_FILE"
echo "observability state: $OBSERVABILITY_STATE_FILE"
echo "Run the packaged product journey verifier before closing the app."
