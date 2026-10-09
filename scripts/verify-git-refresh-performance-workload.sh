#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_STACK_HELPER="$HOME/dev/ai-tools/observability/observability-stack"
STACK_HELPER="${AI_TOOLS_OBSERVABILITY_STACK_HELPER:-$DEFAULT_STACK_HELPER}"
COLLECTOR_HEALTH_URL="${AI_TOOLS_OBSERVABILITY_COLLECTOR_HEALTH_URL:-http://127.0.0.1:13133/}"
LOGS_QUERY_URL="${AI_TOOLS_OBSERVABILITY_LOGS_QUERY_URL:-http://127.0.0.1:9428/select/logsql/query}"
METRICS_QUERY_URL="${AI_TOOLS_OBSERVABILITY_METRICS_QUERY_URL:-http://127.0.0.1:8428/api/v1/query}"
WORKLOAD_TRACE_TAGS="${AGENTSTUDIO_TRACE_TAGS:-performance,app.startup,terminal.startup}"

DEFAULT_PROOF_ROOT="$PROJECT_ROOT/tmp/debug-workflows/2026-06-11-agent-studio-performance-issues-cmdp-slowdown/proofs"
DEFAULT_UI_PROOF_ROOT="/tmp/asperf"

fail_on_legacy_observability_env() {
  local legacy_prefix="SHRAVAN_""OBSERVABILITY_"
  local env_name
  while IFS='=' read -r env_name _; do
    case "$env_name" in
      "$legacy_prefix"*)
        echo "Legacy observability env prefix is no longer supported; use AI_TOOLS_OBSERVABILITY_* instead of $env_name" >&2
        exit 2
        ;;
    esac
  done < <(env)
}

fail_on_legacy_observability_env

canonical_path() {
  /usr/bin/python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

validate_loopback_url() {
  local url_name="${1:?missing url name}"
  local url_value="${2:?missing url value}"
  /usr/bin/python3 - "$url_name" "$url_value" <<'PY'
import sys
from urllib.parse import urlparse

name, value = sys.argv[1], sys.argv[2]
parsed = urlparse(value)
if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
    print(f"{name} must be a loopback http URL: {value}", file=sys.stderr)
    sys.exit(2)
PY
}

validate_observability_controls() {
  validate_loopback_url AI_TOOLS_OBSERVABILITY_COLLECTOR_HEALTH_URL "$COLLECTOR_HEALTH_URL"
  validate_loopback_url AI_TOOLS_OBSERVABILITY_LOGS_QUERY_URL "$LOGS_QUERY_URL"
  validate_loopback_url AI_TOOLS_OBSERVABILITY_METRICS_QUERY_URL "$METRICS_QUERY_URL"
  if [ "${AGENTSTUDIO_OBSERVABILITY_ALLOW_TEST_OVERRIDES:-0}" = "1" ]; then
    return
  fi
  if [ "$(canonical_path "$STACK_HELPER")" != "$(canonical_path "$DEFAULT_STACK_HELPER")" ]; then
    echo "AI_TOOLS_OBSERVABILITY_STACK_HELPER must point to the trusted ai-tools helper: $DEFAULT_STACK_HELPER" >&2
    exit 2
  fi
}

validate_observability_controls

usage() {
  cat <<'USAGE'
Usage: verify-git-refresh-performance-workload.sh [--prepare-only]

Creates a disposable 118-repo / 163-worktree / 14-pane AgentStudio workspace,
launches AgentStudio through the standard per-worktree debug observability
runner, runs five fixture git writers, and captures marker-scoped
VictoriaMetrics performance evidence.

Environment overrides:
  AGENTSTUDIO_PERF_PROOF_ROOT       Parent directory for timestamped artifacts.
                                      Default: repo tmp for git-only runs, /tmp for UI-driven runs.
  AGENTSTUDIO_PERF_REPO_COUNT       Repo count. Default: 118.
  AGENTSTUDIO_PERF_WORKTREE_COUNT   Worktree count. Default: 163.
  AGENTSTUDIO_PERF_ACTIVE_PANES     Pane-owned active worktrees. Default: 14.
  AGENTSTUDIO_PERF_WRITER_COUNT     Concurrent git writers. Default: 5.
  AGENTSTUDIO_PERF_DURATION_SECONDS Busy workload duration. Default: 60.
                                      Set >=255 when this script is used to cover
                                      a full 16-stripe background refresh cycle.
  AGENTSTUDIO_PERF_DRIVE_COMMAND_BAR
                                      Set to 0 to skip startup command-bar repo filter smoke. Default: 1.
  AGENTSTUDIO_PERF_SAMPLE_DURING_WORKLOAD
                                      Set to 1 to capture /usr/bin/sample during the writer
                                      workload. Default: 0 so sampling cannot perturb
                                      latency metrics used as proof.
  AGENTSTUDIO_PERF_ALLOW_JSONL_PROOF
                                      Set to 1 to allow JSONL as an explicit local proof
                                      fallback. Default: 0; standard proof requires Victoria.
  AGENTSTUDIO_PERF_ALLOW_TEST_RESPONSES
                                      Set to 1 only with --prepare-only to let script
                                      tests inject canned Victoria query responses.
  AGENTSTUDIO_OBSERVABILITY_STATE_FILE
                                      State file passed through to the standard debug runner.

The script never reads or mutates the user's live AgentStudio app data, user
worktrees, or global git config. Cleanup kills only PIDs launched by this script.
USAGE
}

prepare_only=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prepare-only)
      prepare_only=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

REPO_COUNT="${AGENTSTUDIO_PERF_REPO_COUNT:-118}"
WORKTREE_COUNT="${AGENTSTUDIO_PERF_WORKTREE_COUNT:-163}"
ACTIVE_PANE_COUNT="${AGENTSTUDIO_PERF_ACTIVE_PANES:-14}"
WRITER_COUNT="${AGENTSTUDIO_PERF_WRITER_COUNT:-5}"
DURATION_SECONDS="${AGENTSTUDIO_PERF_DURATION_SECONDS:-60}"
DRIVE_COMMAND_BAR="${AGENTSTUDIO_PERF_DRIVE_COMMAND_BAR:-1}"
SAMPLE_DURING_WORKLOAD="${AGENTSTUDIO_PERF_SAMPLE_DURING_WORKLOAD:-0}"
ALLOW_JSONL_PROOF="${AGENTSTUDIO_PERF_ALLOW_JSONL_PROOF:-0}"
ALLOW_TEST_RESPONSES="${AGENTSTUDIO_PERF_ALLOW_TEST_RESPONSES:-0}"
COMMON_QUIESCENCE_TIMEOUT_SECONDS=75
METRICS_EXPORT_TIMEOUT_SECONDS=75
REQUIRED_PERFORMANCE_METRIC_MINIMUM_COUNT=1
REQUIRED_COMMANDBAR_QUERY_CHARACTER_MINIMUM=1
REGRESSION_BOUNDARY_PERCENT=10

absolute_path() {
  local path="$1"
  case "$path" in
    /*)
      printf '%s\n' "$path"
      ;;
    *)
      printf '%s/%s\n' "$PROJECT_ROOT" "$path"
      ;;
  esac
}

workload_fingerprint() {
  printf '%s' \
    "repos=$REPO_COUNT;worktrees=$WORKTREE_COUNT;panes=$ACTIVE_PANE_COUNT;writers=$WRITER_COUNT;duration=$DURATION_SECONDS;commandbar=$DRIVE_COMMAND_BAR;sample=$SAMPLE_DURING_WORKLOAD;metric_min=$REQUIRED_PERFORMANCE_METRIC_MINIMUM_COUNT;query_min=$REQUIRED_COMMANDBAR_QUERY_CHARACTER_MINIMUM" \
    | shasum -a 256 \
    | awk '{print $1}'
}

source_digest() {
  /usr/bin/python3 - "$PROJECT_ROOT" <<'PY'
import hashlib
import os
import subprocess
import sys

project_root = sys.argv[1]
tracked_and_untracked = subprocess.check_output(
    ["git", "-C", project_root, "ls-files", "--cached", "--others", "--exclude-standard", "-z"]
)
relative_paths = sorted(
    path
    for path in tracked_and_untracked.split(b"\0")
    if path and os.path.lexists(os.path.join(project_root, os.fsdecode(path)))
)
digest = hashlib.sha256()
for relative_path_bytes in relative_paths:
    relative_path = os.fsdecode(relative_path_bytes)
    absolute_path = os.path.join(project_root, relative_path)
    digest.update(relative_path_bytes)
    digest.update(b"\0")
    if os.path.islink(absolute_path):
        digest.update(b"symlink\0")
        digest.update(os.fsencode(os.readlink(absolute_path)))
    elif os.path.isdir(absolute_path):
        digest.update(b"gitlink\0")
        digest.update(
            subprocess.check_output(
                ["git", "-C", project_root, "ls-files", "--stage", "--", relative_path]
            )
        )
    else:
        digest.update(b"file\0")
        with open(absolute_path, "rb") as source_file:
            while chunk := source_file.read(1024 * 1024):
                digest.update(chunk)
    digest.update(b"\0")
print(digest.hexdigest())
PY
}

if [ -n "${AGENTSTUDIO_PERF_PROOF_ROOT:-}" ]; then
  PROOF_ROOT="$(absolute_path "$AGENTSTUDIO_PERF_PROOF_ROOT")"
elif [ "$DRIVE_COMMAND_BAR" = "1" ]; then
  PROOF_ROOT="$(absolute_path "$DEFAULT_UI_PROOF_ROOT")"
else
  PROOF_ROOT="$(absolute_path "$DEFAULT_PROOF_ROOT")"
fi

validate_trace_name() {
  local trace_name="$1"
  if [ -z "$trace_name" ]; then
    echo "AGENTSTUDIO_TRACE_NAME must not be empty" >&2
    exit 2
  fi
  case "$trace_name" in
    "."|".."|*"/"*|*"\\"*|*".."*|*"*"*|*"?"*|*"["*|*"]"*|*"{"*|*"}"*)
      echo "AGENTSTUDIO_TRACE_NAME must be a safe path component: $trace_name" >&2
      exit 2
      ;;
  esac
  case "$trace_name" in
    *[!A-Za-z0-9_.-]*)
      echo "AGENTSTUDIO_TRACE_NAME may only contain letters, numbers, '.', '_' and '-': $trace_name" >&2
      exit 2
      ;;
  esac
  printf '%s\n' "$trace_name"
}

if [ -n "${AGENTSTUDIO_TRACE_NAME:-}" ]; then
  TRACE_NAME="$(validate_trace_name "$AGENTSTUDIO_TRACE_NAME")"
elif [ "$DRIVE_COMMAND_BAR" = "1" ]; then
  TRACE_NAME="$(validate_trace_name "perf-$(date +%H%M%S)-$$")"
else
  TRACE_NAME="$(validate_trace_name "git-refresh-performance-$(date +%Y%m%d%H%M%S)-$$")"
fi
ARTIFACT="$PROOF_ROOT/$TRACE_NAME"
FIXTURE_ROOT="$ARTIFACT/fixtures"
APP_DATA_DIR="$ARTIFACT/app-data"
TRACE_DIR="$ARTIFACT/traces"
PID_DIR="$ARTIFACT/pids"
COMMAND_LOG="$ARTIFACT/commands.log"
SUMMARY_FILE="$ARTIFACT/summary.txt"
DEBUG_OBSERVABILITY_STATE_FILE="${AGENTSTUDIO_OBSERVABILITY_STATE_FILE:-$PROJECT_ROOT/tmp/debug-observability/latest-observability.env}"
DEBUG_IDENTITY_FILE="$ARTIFACT/debug-identity.env"
DEBUG_STATE_COPY="$ARTIFACT/debug-observability.env"
ZMX_CLEANUP_SCRIPT="$PROJECT_ROOT/scripts/cleanup-owned-zmx-sessions.sh"
ZMX_CLEANUP_ARTIFACT="$ARTIFACT/zmx-cleanup.env"
RUNTIME_DATA_ROOT=""
WORKLOAD_ZMX_DIR=""
WORKLOAD_ZMX_EXECUTABLE=""
DEBUG_IDENTITY_DATA_DIR=""
LAUNCH_ATTEMPTED=0
CLEANUP_RAN=0
ZMX_SESSION_IDS=()

APP_PID=""
APP_BINARY=""
APP_LAUNCH_BUNDLE=""
APP_LAUNCH_METHOD=""
ACTIVATION_MODE=""
IPC_AUTH_MODE=""
EXECUTABLE_DIGEST=""
QUERY_START=""
WRITERS_FINISHED_AT=""
ISSUED_INTERACTION_COUNT=0
TAB_BAR_CAPTURE_COUNT=0
TAB_BAR_TERMINAL_COUNT=0
TAB_BAR_LIFECYCLE_EXACT=false
TAB_BAR_DUPLICATE_CAPTURE_SEQUENCE_COUNT=0
TAB_BAR_DUPLICATE_TERMINAL_SEQUENCE_COUNT=0
TAB_BAR_MISSING_TERMINAL_SEQUENCE_COUNT=0
TAB_BAR_UNEXPECTED_TERMINAL_SEQUENCE_COUNT=0
TAB_BAR_INVALID_TERMINAL_OUTCOME_COUNT=0
TRACE_QUEUE_DROPPED_RECORD_COUNT=""
TRACE_QUEUE_HIGH_WATERMARK=""
FINAL_TAB_COUNT=0
FINAL_PANE_COUNT=0
FINAL_ACTIVE_PANE_COUNT=0
FINAL_TAB_COUNT_EQUIVALENT=false
FINAL_ACTIVE_TAB_EQUIVALENT=false
FINAL_MEMBERSHIP_EQUIVALENT=false
WRITER_PIDS=()

log_command() {
  printf '+ %s\n' "$*" | tee -a "$COMMAND_LOG"
}

stop_pid() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  if kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" >/dev/null 2>&1 || true
    local attempt
    for attempt in $(seq 1 50); do
      if ! kill -0 "$pid" >/dev/null 2>&1; then
        wait "$pid" >/dev/null 2>&1 || true
        return 0
      fi
      sleep 0.1
    done
    return 1
  fi
}

cleanup() {
  [ "$CLEANUP_RAN" -eq 0 ] || return 0
  CLEANUP_RAN=1
  local cleanup_log="$ARTIFACT/cleanup.log"
  local cleanup_failed=0
  mkdir -p "$ARTIFACT"
  {
    echo "cleanup started $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    for pid in "${WRITER_PIDS[@]:-}"; do
      if stop_pid "$pid"; then
        echo "writer pid stopped: $pid"
      else
        echo "writer pid did not exit within 5 seconds: $pid"
        cleanup_failed=1
      fi
    done
    if [ -n "$APP_PID" ]; then
      if stop_pid "$APP_PID"; then
        echo "app pid stopped: $APP_PID"
      else
        echo "app pid did not exit within 5 seconds: $APP_PID"
        cleanup_failed=1
      fi
    fi
    local live_writers=0
    for pid_file in "$PID_DIR"/writer-*.pid; do
      [ -f "$pid_file" ] || continue
      local pid
      pid="$(cat "$pid_file")"
      if kill -0 "$pid" >/dev/null 2>&1; then
        live_writers=$((live_writers + 1))
      fi
    done
    echo "live writer pids after cleanup: $live_writers"
    if [ "$live_writers" -ne 0 ]; then
      cleanup_failed=1
    fi
  } >>"$cleanup_log"

  if [ "$LAUNCH_ATTEMPTED" -eq 1 ] && [ "${#ZMX_SESSION_IDS[@]}" -gt 0 ]; then
    if ! "$ZMX_CLEANUP_SCRIPT" \
      "$WORKLOAD_ZMX_EXECUTABLE" \
      "$WORKLOAD_ZMX_DIR" \
      "$ZMX_CLEANUP_ARTIFACT" \
      "${ZMX_SESSION_IDS[@]}"
    then
      cleanup_failed=1
    fi
  fi
  echo "cleanup finished $(date -u +"%Y-%m-%dT%H:%M:%SZ") status=$cleanup_failed" >>"$cleanup_log"
  return "$cleanup_failed"
}

finish() {
  local body_status="$?"
  local cleanup_status=0
  trap - EXIT INT TERM
  cleanup || cleanup_status=$?
  if [ "$body_status" -ne 0 ]; then
    exit "$body_status"
  fi
  exit "$cleanup_status"
}

trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_positive_integer() {
  local name="$1"
  local value="$2"
  case "$value" in
    ''|*[!0-9]*)
      echo "$name must be a positive integer: $value" >&2
      exit 2
      ;;
  esac
  if [ "$value" -le 0 ]; then
    echo "$name must be a positive integer: $value" >&2
    exit 2
  fi
}

require_positive_integer AGENTSTUDIO_PERF_REPO_COUNT "$REPO_COUNT"
require_positive_integer AGENTSTUDIO_PERF_WORKTREE_COUNT "$WORKTREE_COUNT"
require_positive_integer AGENTSTUDIO_PERF_ACTIVE_PANES "$ACTIVE_PANE_COUNT"
require_positive_integer AGENTSTUDIO_PERF_WRITER_COUNT "$WRITER_COUNT"
require_positive_integer AGENTSTUDIO_PERF_DURATION_SECONDS "$DURATION_SECONDS"
if [ "$DRIVE_COMMAND_BAR" != "0" ] && [ "$DRIVE_COMMAND_BAR" != "1" ]; then
  echo "AGENTSTUDIO_PERF_DRIVE_COMMAND_BAR must be 0 or 1" >&2
  exit 2
fi
if [ "$SAMPLE_DURING_WORKLOAD" != "0" ] && [ "$SAMPLE_DURING_WORKLOAD" != "1" ]; then
  echo "AGENTSTUDIO_PERF_SAMPLE_DURING_WORKLOAD must be 0 or 1" >&2
  exit 2
fi
if [ "$ALLOW_JSONL_PROOF" != "0" ] && [ "$ALLOW_JSONL_PROOF" != "1" ]; then
  echo "AGENTSTUDIO_PERF_ALLOW_JSONL_PROOF must be 0 or 1" >&2
  exit 2
fi
if [ "$ALLOW_TEST_RESPONSES" != "0" ] && [ "$ALLOW_TEST_RESPONSES" != "1" ]; then
  echo "AGENTSTUDIO_PERF_ALLOW_TEST_RESPONSES must be 0 or 1" >&2
  exit 2
fi
case ",$WORKLOAD_TRACE_TAGS," in
  *,performance,*)
    ;;
  *)
    echo "AGENTSTUDIO_TRACE_TAGS must contain the performance tag: $WORKLOAD_TRACE_TAGS" >&2
    exit 2
    ;;
esac

test_responses_enabled() {
  [ "$prepare_only" = true ] && [ "$ALLOW_TEST_RESPONSES" = "1" ]
}

reject_canned_query_responses_outside_tests() {
  local response_names=()
  [ -n "${AGENTSTUDIO_PERF_TEST_LOGS_RESPONSE+x}" ] && response_names+=("AGENTSTUDIO_PERF_TEST_LOGS_RESPONSE")
  [ -n "${AGENTSTUDIO_PERF_TEST_METRICS_RESPONSE+x}" ] && response_names+=("AGENTSTUDIO_PERF_TEST_METRICS_RESPONSE")
  [ -n "${AGENTSTUDIO_PERF_TEST_COMMON_DEBT_SNAPSHOT+x}" ] && response_names+=("AGENTSTUDIO_PERF_TEST_COMMON_DEBT_SNAPSHOT")
  [ "${#response_names[@]}" -eq 0 ] && return 0
  if test_responses_enabled; then
    return 0
  fi
  echo "${response_names[*]} may only be used with --prepare-only and AGENTSTUDIO_PERF_ALLOW_TEST_RESPONSES=1" >&2
  exit 2
}

reject_canned_query_responses_outside_tests

if [ "$WORKTREE_COUNT" -lt "$REPO_COUNT" ]; then
  echo "AGENTSTUDIO_PERF_WORKTREE_COUNT must be >= repo count" >&2
  exit 2
fi
if [ "$WORKTREE_COUNT" -gt $((REPO_COUNT * 2)) ]; then
  echo "AGENTSTUDIO_PERF_WORKTREE_COUNT must be <= 2x repo count for this fixture generator" >&2
  exit 2
fi
if [ "$ACTIVE_PANE_COUNT" -gt "$WORKTREE_COUNT" ]; then
  echo "AGENTSTUDIO_PERF_ACTIVE_PANES must be <= worktree count" >&2
  exit 2
fi

decode_env_file_value() {
  local env_file="$1"
  local lookup_key="$2"
  [ -f "$env_file" ] || return 1
  local raw_value
  raw_value="$(sed -n "s/^$lookup_key=//p" "$env_file" | tail -1)"
  [ -n "$raw_value" ] || return 1
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

load_debug_identity_for_workload() {
  mkdir -p "$ARTIFACT"
  log_command "$PROJECT_ROOT/scripts/run-debug-observability.sh" --print-identity
  AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$DEBUG_OBSERVABILITY_STATE_FILE" \
    "$PROJECT_ROOT/scripts/run-debug-observability.sh" --print-identity >"$DEBUG_IDENTITY_FILE"
  DEBUG_IDENTITY_DATA_DIR="$(decode_env_file_value "$DEBUG_IDENTITY_FILE" AGENTSTUDIO_OBSERVABILITY_DATA_DIR)"
  if [ -z "$DEBUG_IDENTITY_DATA_DIR" ]; then
    echo "debug identity did not provide data/trace directories: $DEBUG_IDENTITY_FILE" >&2
    exit 1
  fi
  RUNTIME_DATA_ROOT="$(mktemp -d /tmp/asw.XXXXXX)"
  chmod 700 "$RUNTIME_DATA_ROOT"
  APP_DATA_DIR="$RUNTIME_DATA_ROOT"
  WORKLOAD_ZMX_DIR="$RUNTIME_DATA_ROOT/z"
  WORKLOAD_ZMX_EXECUTABLE="$RUNTIME_DATA_ROOT/bin/zmx"
  TRACE_DIR="$ARTIFACT/traces"
}

preflight_debug_observability_idle() {
  log_command "$PROJECT_ROOT/scripts/run-debug-observability.sh" --preflight-idle
  AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$DEBUG_OBSERVABILITY_STATE_FILE" \
    "$PROJECT_ROOT/scripts/run-debug-observability.sh" --preflight-idle
}

fail_if_trace_marker_would_reuse_jsonl() {
  if find "$TRACE_DIR" -maxdepth 1 -name "agentstudio-$TRACE_NAME-*.jsonl" -type f -print -quit 2>/dev/null |
    grep -q .
  then
    echo "trace marker already has JSONL files in $TRACE_DIR: $TRACE_NAME" >&2
    echo "Choose a fresh AGENTSTUDIO_TRACE_NAME before running workload proof." >&2
    exit 1
  fi
}

uuid_v7() {
  local seconds millis ts_hex random_hex
  seconds="$(date +%s)"
  millis=$((seconds * 1000))
  printf -v ts_hex '%012x' "$millis"
  random_hex="$(openssl rand -hex 10 | tr '[:upper:]' '[:lower:]')"
  printf '%s-%s-7%s-8%s-%s\n' \
    "${ts_hex:0:8}" \
    "${ts_hex:8:4}" \
    "${random_hex:0:3}" \
    "${random_hex:3:3}" \
    "${random_hex:6:12}"
}

json_url() {
  printf 'file://%s' "$1"
}

json_string() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

init_repo() {
  local repo_dir="$1"
  mkdir -p "$repo_dir"
  log_command git init "$repo_dir"
  git init "$repo_dir" >>"$ARTIFACT/fixture-setup.log" 2>&1
  git -C "$repo_dir" config user.email agentstudio-perf@example.invalid
  git -C "$repo_dir" config user.name 'AgentStudio Perf Fixture'
  git -C "$repo_dir" config commit.gpgsign false
  git -C "$repo_dir" config tag.gpgsign false
  printf 'initial\n' >"$repo_dir/README.md"
  git -C "$repo_dir" add README.md >>"$ARTIFACT/fixture-setup.log" 2>&1
  git -C "$repo_dir" commit -m initial >>"$ARTIFACT/fixture-setup.log" 2>&1
}

create_linked_worktree() {
  local repo_dir="$1"
  local worktree_dir="$2"
  local branch_name="$3"
  mkdir -p "$(dirname "$worktree_dir")"
  log_command git -C "$repo_dir" worktree add -b "$branch_name" "$worktree_dir"
  git -C "$repo_dir" worktree add -b "$branch_name" "$worktree_dir" >>"$ARTIFACT/fixture-setup.log" 2>&1
  git -C "$worktree_dir" config user.email agentstudio-perf@example.invalid
  git -C "$worktree_dir" config user.name 'AgentStudio Perf Fixture'
  git -C "$worktree_dir" config commit.gpgsign false
  git -C "$worktree_dir" config tag.gpgsign false
}

write_workspace_json() {
  local workspace_id="$1"
  local workspace_file="$ARTIFACT/workspace-fixture.json"
  local timestamp=0

  {
    printf '{\n'
    printf '  "schemaVersion": 1,\n'
    printf '  "id": "%s",\n' "$workspace_id"
    printf '  "name": "Git Refresh Performance Fixture",\n'
    printf '  "repos": [\n'
    local repo_index
    for repo_index in $(seq 0 $((REPO_COUNT - 1))); do
      [ "$repo_index" -gt 0 ] && printf ',\n'
      printf '    {"id": "%s", "name": "repo-%03d", "repoPath": "%s", "createdAt": %s}' \
        "${REPO_IDS[$repo_index]}" \
        "$repo_index" \
        "$(json_url "${REPO_PATHS[$repo_index]}")" \
        "$timestamp"
    done
    printf '\n  ],\n'

    printf '  "worktrees": [\n'
    local worktree_index
    for worktree_index in $(seq 0 $((WORKTREE_COUNT - 1))); do
      [ "$worktree_index" -gt 0 ] && printf ',\n'
      printf '    {"id": "%s", "repoId": "%s", "name": "%s", "path": "%s", "isMainWorktree": %s}' \
        "${WORKTREE_IDS[$worktree_index]}" \
        "${WORKTREE_REPO_IDS[$worktree_index]}" \
        "$(json_string "${WORKTREE_NAMES[$worktree_index]}")" \
        "$(json_url "${WORKTREE_PATHS[$worktree_index]}")" \
        "${WORKTREE_IS_MAIN[$worktree_index]}"
    done
    printf '\n  ],\n'
    printf '  "unavailableRepoIds": [],\n'

    printf '  "panes": [\n'
    local pane_index
    for pane_index in $(seq 0 $((ACTIVE_PANE_COUNT - 1))); do
      [ "$pane_index" -gt 0 ] && printf ',\n'
      local pane_id="${PANE_IDS[$pane_index]}"
      local repo_id="${WORKTREE_REPO_IDS[$pane_index]}"
      local worktree_id="${WORKTREE_IDS[$pane_index]}"
      local worktree_path="${WORKTREE_PATHS[$pane_index]}"
      local title="repo-pane-$pane_index"
      printf '    {\n'
      printf '      "id": "%s",\n' "$pane_id"
      printf '      "content": {"version": 3, "type": "terminal", "state": {"provider": "zmx", "lifetime": "persistent", "zmxSessionID": "%s"}},\n' \
        "${ZMX_SESSION_IDS[$pane_index]}"
      printf '      "metadata": {\n'
      printf '        "paneId": "%s",\n' "$pane_id"
      printf '        "contentType": {"terminal": {}},\n'
      # Keep canonical launch placement separate from the nil live CWD so the
      # shell's first real PWD report exercises the production topology lookup.
      printf '        "launchDirectory": "%s",\n' "$(json_url "$worktree_path")"
      printf '        "executionBackend": {"local": {}},\n'
      printf '        "createdAt": %s,\n' "$timestamp"
      printf '        "title": "%s",\n' "$title"
      printf '        "facets": {"repoId": "%s", "worktreeId": "%s", "cwd": null, "tags": []},\n' \
        "$repo_id" "$worktree_id"
      printf '        "checkoutRef": null,\n'
      printf '        "note": null\n'
      printf '      },\n'
      printf '      "residency": {"active": {}},\n'
      printf '      "kind": {"layout": {"drawer": {"drawerId": "%s", "parentPaneId": "%s", "paneIds": [], "isExpanded": false}}}\n' \
        "${DRAWER_IDS[$pane_index]}" "$pane_id"
      printf '    }'
    done
    printf '\n  ],\n'

    printf '  "tabs": [\n'
    printf '    {\n'
    printf '      "id": "%s",\n' "$TAB_ID"
    printf '      "name": "Performance",\n'
    printf '      "panes": ['
    local tab_pane_index
    for tab_pane_index in $(seq 0 $((ACTIVE_PANE_COUNT - 1))); do
      [ "$tab_pane_index" -gt 0 ] && printf ', '
      printf '"%s"' "${PANE_IDS[$tab_pane_index]}"
    done
    printf '],\n'
    printf '      "arrangements": [\n'
    printf '        {\n'
    printf '          "id": "%s",\n' "$ARRANGEMENT_ID"
    printf '          "name": "Default",\n'
    printf '          "isDefault": true,\n'
    printf '          "layout": {"panes": ['
    for tab_pane_index in $(seq 0 $((ACTIVE_PANE_COUNT - 1))); do
      [ "$tab_pane_index" -gt 0 ] && printf ', '
      printf '{"paneId": "%s", "ratio": %.8f}' \
        "${PANE_IDS[$tab_pane_index]}" \
        "$(awk "BEGIN { printf \"%.8f\", 1 / $ACTIVE_PANE_COUNT }")"
    done
    printf '], "dividerIds": ['
    if [ "$ACTIVE_PANE_COUNT" -gt 1 ]; then
      local divider_index
      for divider_index in $(seq 0 $((ACTIVE_PANE_COUNT - 2))); do
        [ "$divider_index" -gt 0 ] && printf ', '
        printf '"%s"' "${DIVIDER_IDS[$divider_index]}"
      done
    fi
    printf ']},\n'
    printf '          "minimizedPaneIds": [],\n'
    printf '          "activePaneId": "%s",\n' "${PANE_IDS[0]}"
    printf '          "drawerViews": []\n'
    printf '        }\n'
    printf '      ],\n'
    printf '      "activeArrangementId": "%s"\n' "$ARRANGEMENT_ID"
    printf '    }\n'
    printf '  ],\n'
    printf '  "activeTabId": "%s",\n' "$TAB_ID"
    printf '  "sidebarWidth": 250,\n'
    printf '  "windowFrame": null,\n'
    printf '  "watchedPaths": [],\n'
    printf '  "createdAt": %s,\n' "$timestamp"
    printf '  "updatedAt": %s\n' "$timestamp"
    printf '}\n'
  } >"$workspace_file"

  echo "$workspace_file"
}

prepare_fixture() {
  REPO_IDS=()
  REPO_PATHS=()
  WORKTREE_IDS=()
  WORKTREE_REPO_IDS=()
  WORKTREE_PATHS=()
  WORKTREE_NAMES=()
  WORKTREE_IS_MAIN=()
  PANE_IDS=()
  ZMX_SESSION_IDS=()
  DRAWER_IDS=()
  DIVIDER_IDS=()

  local linked_worktrees_needed=$((WORKTREE_COUNT - REPO_COUNT))
  local worktree_index=0
  local repo_index
  for repo_index in $(seq 0 $((REPO_COUNT - 1))); do
    local repo_id repo_dir
    repo_id="$(uuid_v7)"
    repo_dir="$FIXTURE_ROOT/repos/repo-$(printf '%03d' "$repo_index")"
    init_repo "$repo_dir"

    REPO_IDS[$repo_index]="$repo_id"
    REPO_PATHS[$repo_index]="$repo_dir"

    WORKTREE_IDS[$worktree_index]="$(uuid_v7)"
    WORKTREE_REPO_IDS[$worktree_index]="$repo_id"
    WORKTREE_PATHS[$worktree_index]="$repo_dir"
    WORKTREE_NAMES[$worktree_index]="main"
    WORKTREE_IS_MAIN[$worktree_index]="true"
    worktree_index=$((worktree_index + 1))

    if [ "$linked_worktrees_needed" -gt 0 ]; then
      local linked_dir branch_name
      branch_name="perf-$repo_index"
      linked_dir="$FIXTURE_ROOT/linked/repo-$(printf '%03d' "$repo_index")-$branch_name"
      create_linked_worktree "$repo_dir" "$linked_dir" "$branch_name"
      WORKTREE_IDS[$worktree_index]="$(uuid_v7)"
      WORKTREE_REPO_IDS[$worktree_index]="$repo_id"
      WORKTREE_PATHS[$worktree_index]="$linked_dir"
      WORKTREE_NAMES[$worktree_index]="$branch_name"
      WORKTREE_IS_MAIN[$worktree_index]="false"
      worktree_index=$((worktree_index + 1))
      linked_worktrees_needed=$((linked_worktrees_needed - 1))
    fi
  done

  local pane_index
  for pane_index in $(seq 0 $((ACTIVE_PANE_COUNT - 1))); do
    PANE_IDS[$pane_index]="$(uuid_v7)"
    ZMX_SESSION_IDS[$pane_index]="$(uuid_v7)"
    DRAWER_IDS[$pane_index]="$(uuid_v7)"
  done
  if [ "$prepare_only" != true ]; then
    local owned_session_id
    for owned_session_id in "${ZMX_SESSION_IDS[@]}"; do
      if [ $((${#WORKLOAD_ZMX_DIR} + 1 + ${#owned_session_id})) -gt 103 ]; then
        echo "workload zmx socket path exceeds Darwin's 103-byte limit: $WORKLOAD_ZMX_DIR/$owned_session_id" >&2
        exit 1
      fi
    done
  fi
  if [ "$ACTIVE_PANE_COUNT" -gt 1 ]; then
    local divider_index
    for divider_index in $(seq 0 $((ACTIVE_PANE_COUNT - 2))); do
      DIVIDER_IDS[$divider_index]="$(uuid_v7)"
    done
  fi
  TAB_ID="$(uuid_v7)"
  ARRANGEMENT_ID="$(uuid_v7)"
  WORKSPACE_ID="$(uuid_v7)"
  WORKSPACE_FILE="$(write_workspace_json "$WORKSPACE_ID")"
}

materialize_workspace_fixture() {
  local materialization_log="$ARTIFACT/fixture-materialization.log"
  local materializer_filter="GitRefreshPerformanceWorkloadScriptTests.workloadFixtureMaterializesThroughStrictSQLite"
  local materializer_env=(
    "AGENTSTUDIO_PERF_FIXTURE_JSON=$WORKSPACE_FILE"
    "AGENTSTUDIO_PERF_FIXTURE_DATA_ROOT=$APP_DATA_DIR"
    "AGENTSTUDIO_PERF_FIXTURE_EXPECTED_REPOS=$REPO_COUNT"
    "AGENTSTUDIO_PERF_FIXTURE_EXPECTED_WORKTREES=$WORKTREE_COUNT"
    "AGENTSTUDIO_PERF_FIXTURE_EXPECTED_PANES=$ACTIVE_PANE_COUNT"
    "AGENTSTUDIO_PERF_FIXTURE_EXPECTED_TABS=1"
  )

  log_command env "${materializer_env[@]}" mise run test:swift -- --filter "$materializer_filter"
  env "${materializer_env[@]}" mise run test:swift -- --filter "$materializer_filter" \
    >"$materialization_log" 2>&1
}

launch_debug_observability_app() {
  if [ ! -x "$STACK_HELPER" ]; then
    echo "observability stack helper not executable: $STACK_HELPER" >&2
    exit 1
  fi
  if ! curl --fail --silent --show-error --max-time 2 "$COLLECTOR_HEALTH_URL" >/dev/null; then
    echo "OTLP collector is not healthy at $COLLECTOR_HEALTH_URL" >&2
    echo "Run: mise run observability:up" >&2
    exit 1
  fi

  local launcher_env=(
    "AGENTSTUDIO_OBSERVABILITY_STATE_FILE=$DEBUG_OBSERVABILITY_STATE_FILE"
    "AGENTSTUDIO_TRACE_TAGS=$WORKLOAD_TRACE_TAGS"
    "AGENTSTUDIO_TRACE_FLUSH=immediate"
    "AGENTSTUDIO_TRACE_NAME=$TRACE_NAME"
    "AGENTSTUDIO_TRACE_DIR=$TRACE_DIR"
    "AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW=1"
    "AGENTSTUDIO_DEBUG_DATA_DIR=$RUNTIME_DATA_ROOT"
  )
  if [ "$DRIVE_COMMAND_BAR" = "1" ]; then
    launcher_env+=("AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION=command-bar-repo-filter")
  fi

  LAUNCH_ATTEMPTED=1
  log_command env "${launcher_env[@]}" "$PROJECT_ROOT/scripts/run-debug-observability.sh" --detach
  env "${launcher_env[@]}" "$PROJECT_ROOT/scripts/run-debug-observability.sh" --detach \
    >"$ARTIFACT/run-debug-observability.log" 2>&1

  cp "$DEBUG_OBSERVABILITY_STATE_FILE" "$DEBUG_STATE_COPY"
  APP_PID="$(decode_env_file_value "$DEBUG_OBSERVABILITY_STATE_FILE" AGENTSTUDIO_OBSERVABILITY_PID)"
  APP_BINARY="$(decode_env_file_value "$DEBUG_OBSERVABILITY_STATE_FILE" AGENTSTUDIO_OBSERVABILITY_EXECUTABLE)"
  APP_LAUNCH_BUNDLE="$(decode_env_file_value "$DEBUG_OBSERVABILITY_STATE_FILE" AGENTSTUDIO_OBSERVABILITY_APP)"
  APP_LAUNCH_METHOD="$(
    decode_env_file_value "$DEBUG_OBSERVABILITY_STATE_FILE" AGENTSTUDIO_OBSERVABILITY_LAUNCH_METHOD
  )"
  ACTIVATION_MODE="$(
    decode_env_file_value "$DEBUG_OBSERVABILITY_STATE_FILE" AGENTSTUDIO_OBSERVABILITY_ACTIVATION_MODE
  )"
  IPC_AUTH_MODE="$(
    decode_env_file_value "$DEBUG_OBSERVABILITY_STATE_FILE" AGENTSTUDIO_OBSERVABILITY_IPC_AUTH_MODE
  )"
  WORKLOAD_ZMX_DIR="$(decode_env_file_value "$DEBUG_OBSERVABILITY_STATE_FILE" AGENTSTUDIO_OBSERVABILITY_ZMX_DIR)"
  QUERY_START="$(decode_env_file_value "$DEBUG_OBSERVABILITY_STATE_FILE" AGENTSTUDIO_OBSERVABILITY_QUERY_START)"
  if [ -z "$APP_PID" ] || [ -z "$APP_BINARY" ]; then
    echo "debug observability state did not include PID/executable: $DEBUG_OBSERVABILITY_STATE_FILE" >&2
    exit 1
  fi
  if [ "$WORKLOAD_ZMX_DIR" != "$RUNTIME_DATA_ROOT/z" ]; then
    echo "debug workload did not use its isolated zmx root: $WORKLOAD_ZMX_DIR" >&2
    exit 1
  fi
  if [ "$APP_LAUNCH_METHOD" != "launchservices" ]; then
    echo "performance workload requires launch_method=launchservices: ${APP_LAUNCH_METHOD:-<missing>}" >&2
    exit 1
  fi
  if [ "$ACTIVATION_MODE" != "background" ]; then
    echo "performance workload requires activation_mode=background: ${ACTIVATION_MODE:-<missing>}" >&2
    exit 1
  fi
  if [ "$IPC_AUTH_MODE" != "authenticated" ]; then
    echo "performance workload requires authenticated IPC: ${IPC_AUTH_MODE:-<missing>}" >&2
    exit 1
  fi
  EXECUTABLE_DIGEST="$(/usr/bin/shasum -a 256 "$APP_BINARY" | awk '{print $1}')"
  printf '%s\n' "$APP_PID" >"$PID_DIR/app.pid"

  log_command "$PROJECT_ROOT/scripts/verify-debug-observability.sh"
  local deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$DEBUG_OBSERVABILITY_STATE_FILE" \
      "$PROJECT_ROOT/scripts/verify-debug-observability.sh" \
      >"$ARTIFACT/verify-debug-observability.log" 2>&1
    then
      return 0
    fi
    sleep 2
  done
  cat "$ARTIFACT/verify-debug-observability.log" >&2
  return 1
}

query_victoria_logs() {
  local logsql="$1"
  if test_responses_enabled && [ -n "${AGENTSTUDIO_PERF_TEST_LOGS_RESPONSE+x}" ]; then
    printf '%s\n' "$AGENTSTUDIO_PERF_TEST_LOGS_RESPONSE"
    return 0
  fi
  local args=(
    --fail
    --silent
    --show-error
    --max-time 5
    --get
    --data-urlencode "query=$logsql"
  )
  if [ -n "$QUERY_START" ]; then
    args+=(--data-urlencode "start=$QUERY_START")
  fi
  curl "${args[@]}" "$LOGS_QUERY_URL"
}

query_victoria_metrics() {
  local promql="$1"
  local latency_offset="${2:-}"
  if test_responses_enabled && [ -n "${AGENTSTUDIO_PERF_TEST_METRICS_RESPONSE+x}" ]; then
    printf '%s\n' "$AGENTSTUDIO_PERF_TEST_METRICS_RESPONSE"
    return 0
  fi
  local args=(
    --fail
    --silent
    --show-error
    --max-time 5
    --get
    --data-urlencode "query=$promql"
  )
  if [ -n "$latency_offset" ]; then
    args+=(--data-urlencode "latency_offset=$latency_offset")
  fi
  curl "${args[@]}" "$METRICS_QUERY_URL"
}

logsql_escape_exact_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  printf '%s' "$value"
}

logsql_exact_filter() {
  local field_name="$1"
  local field_value="$2"
  printf '%s:="%s"' "$field_name" "$(logsql_escape_exact_value "$field_value")"
}

victoria_event_query() {
  local event_name="$1"
  printf '{service.name="AgentStudio",dev.runtime.flavor="debug"} %s %s' \
    "$(logsql_exact_filter "agent.proof.marker" "$TRACE_NAME")" \
    "$(logsql_exact_filter "_msg" "$event_name")"
}

victoria_event_count() {
  local event_name="$1"
  local response
  response="$(query_victoria_logs "$(victoria_event_query "$event_name") | fields _msg | limit 10000" 2>/dev/null || true)"
  if [ -z "$response" ]; then
    printf '0\n'
  else
    printf '%s\n' "$response" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' '
  fi
}

victoria_metric_value() {
  local promql="$1"
  local response
  response="$(query_victoria_metrics "$promql" 2>/dev/null || true)"
  if [ -z "$response" ]; then
    printf '0\n'
    return 0
  fi
  /usr/bin/python3 -c '
import json
import math
import sys

total = 0.0
try:
    payload = json.load(sys.stdin)
    for item in payload["data"]["result"]:
        try:
            value = float(item["value"][1])
            if math.isfinite(value):
                total += value
        except Exception:
            pass
except Exception:
    pass

if total.is_integer():
    print(int(total))
else:
    print(total)
' <<<"$response"
}

victoria_metric_event_label_selector() {
  local event_name="$1"
  local extra_selector="${2:-}"
  printf 'service.name="AgentStudio",dev.runtime.flavor="debug",agent.proof.marker="%s",event="%s"%s' \
    "$TRACE_NAME" "$event_name" "$extra_selector"
}

victoria_metric_event_query() {
  local event_name="$1"
  printf 'agentstudio_performance_events_total{%s}' \
    "$(victoria_metric_event_label_selector "$event_name")"
}

victoria_metric_event_count_query() {
  local event_name="$1"
  local extra_selector="${2:-}"
  printf 'sum(agentstudio_performance_events_total{%s})' \
    "$(victoria_metric_event_label_selector "$event_name" "$extra_selector")"
}

victoria_metric_event_count_for_reason() {
  local event_name="$1"
  local reason="$2"
  victoria_metric_value "$(victoria_metric_event_count_query "$event_name" ",reason=\"$reason\"")"
}

victoria_metric_event_elapsed_p95() {
  local event_name="$1"
  local extra_selector="${2:-}"
  victoria_metric_value \
    "histogram_quantile(0.95, sum by (le) (agentstudio_performance_event_elapsed_ms_bucket{$(victoria_metric_event_label_selector "$event_name" "$extra_selector")}))"
}

victoria_metric_event_elapsed_max() {
  local event_name="$1"
  local extra_selector="${2:-}"
  victoria_metric_value \
    "max(agentstudio_performance_event_elapsed_ms_max{$(victoria_metric_event_label_selector "$event_name" "$extra_selector")})"
}

victoria_metric_event_elapsed_mean() {
  local event_name="$1"
  local extra_selector="${2:-}"
  printf 'sum(agentstudio_performance_event_elapsed_ms_sum{%s}) / sum(agentstudio_performance_event_elapsed_ms_count{%s})' \
    "$(victoria_metric_event_label_selector "$event_name" "$extra_selector")" \
    "$(victoria_metric_event_label_selector "$event_name" "$extra_selector")"
}

victoria_metric_event_elapsed_mean_value() {
  local event_name="$1"
  local extra_selector="${2:-}"
  victoria_metric_value "$(victoria_metric_event_elapsed_mean "$event_name" "$extra_selector")"
}

victoria_metric_status_unavailable_reason_values() {
  printf '%s\n' \
    provider_returned_nil \
    timeout \
    read_already_in_flight \
    cancelled \
    sdk_error
}

require_status_latency_metrics() {
  local event_count max_value p95_value
  event_count="$(victoria_metric_event_count performance.git.status)"
  [ "$event_count" != "0" ] || return 0
  max_value="$(victoria_metric_event_elapsed_max performance.git.status)"
  p95_value="$(victoria_metric_event_elapsed_p95 performance.git.status)"
  if [ "$max_value" = "0" ] || [ "$p95_value" = "0" ]; then
    echo "did not observe performance.git.status elapsed p95/max metrics for marker $TRACE_NAME" >&2
    summarize_traces
    exit 1
  fi
}

victoria_metric_event_elapsed_query() {
  local event_name="$1"
  printf 'agentstudio_performance_event_elapsed_ms_bucket{%s}' \
    "$(victoria_metric_event_label_selector "$event_name")"
}

victoria_metric_event_elapsed_p95_query() {
  local event_name="$1"
  printf 'histogram_quantile(0.95, sum by (le) (%s))' "$(victoria_metric_event_elapsed_query "$event_name")"
}

victoria_event_elapsed_max() {
  local event_name="$1"
  local response
  response="$(query_victoria_logs "$(victoria_event_query "$event_name") | fields agentstudio.performance.elapsed_ms | limit 10000" 2>/dev/null || true)"
  if [ -z "$response" ]; then
    printf '0\n'
    return 0
  fi
  /usr/bin/python3 -c '
import json
import math
import sys

values = []
for line in sys.stdin:
    if not line.strip():
        continue
    try:
        payload = json.loads(line)
    except Exception:
        continue
    raw_value = payload.get("agentstudio.performance.elapsed_ms")
    try:
        value = float(raw_value)
    except Exception:
        continue
    if math.isfinite(value):
        values.append(value)

if not values:
    print(0)
else:
    maximum = max(values)
    if maximum.is_integer():
        print(int(maximum))
    else:
        print(maximum)
' <<<"$response"
}

victoria_metric_value_or_empty() {
  local promql="$1"
  local response
  response="$(query_victoria_metrics "$promql" 2>/dev/null || true)"
  if [ -z "$response" ]; then
    return 0
  fi
  /usr/bin/python3 -c '
import json
import math
import sys

values = []
try:
    payload = json.load(sys.stdin)
    for item in payload["data"]["result"]:
        try:
            value = float(item["value"][1])
            if math.isfinite(value):
                values.append(value)
        except Exception:
            pass
except Exception:
    pass

if not values:
    sys.exit(0)

total = sum(values)
if total.is_integer():
    print(int(total))
else:
    print(total)
' <<<"$response"
}

fresh_common_debt_metric_query() {
  local metric_name="$1"
  local event_name="$2"
  local minimum_timestamp="$3"
  local selector
  selector="$(victoria_metric_event_label_selector "$event_name")"

  printf '%s{%s} and (timestamp(%s{%s}) >= %s)' \
    "$metric_name" \
    "$selector" \
    "$metric_name" \
    "$selector" \
    "$minimum_timestamp"
}

common_debt_metric_query() {
  local minimum_timestamp="$1"
  local queries=(
    "$(fresh_common_debt_metric_query \
      agentstudio_performance_filesystem_logical_debt_count \
      performance.filesystem.logical_debt \
      "$minimum_timestamp")"
    "$(fresh_common_debt_metric_query \
      agentstudio_performance_runtime_delivery_total_pending_count \
      performance.runtime_delivery.snapshot \
      "$minimum_timestamp")"
  )
  local field metric_name fresh_query
  while IFS=$'\t' read -r field metric_name; do
    fresh_query="$(fresh_common_debt_metric_query \
      "$metric_name" performance.git.logical_debt "$minimum_timestamp")"
    queries+=("label_set(($fresh_query),\"settlement_field\",\"$field\")")
  done <<'EOF'
logical_debt	agentstudio_performance_git_logical_debt_count
future_automatic	agentstudio_performance_git_future_automatic_count
future_failure	agentstudio_performance_git_future_failure_count
ready_pending	agentstudio_performance_git_ready_pending_count
capacity_pending	agentstudio_performance_git_capacity_pending_count
active_follow_up	agentstudio_performance_git_active_follow_up_count
unclassified_pending	agentstudio_performance_git_unclassified_pending_count
overdue_deadline	agentstudio_performance_git_overdue_deadline_count
running	agentstudio_performance_git_logical_running_count
oldest_preparation_ms	agentstudio_performance_git_oldest_preparation_ms
next_deadline_ms	agentstudio_performance_git_next_deadline_ms
EOF
  local joined="" query
  for query in "${queries[@]}"; do
    joined="${joined}${joined:+ or }(${query})"
  done
  printf '%s' "$joined"
}

common_debt_snapshot() {
  local writers_finished_at="$1"
  local response
  response="$(query_victoria_metrics \
    "$(common_debt_metric_query "$writers_finished_at")" \
    1ms 2>/dev/null || true)"
  [ -n "$response" ] || {
    echo "ready=false reason=missing_response"
    return 0
  }
  /usr/bin/python3 -c '
import json
import math
import sys

expected = {
    "filesystem": ("agentstudio_performance_filesystem_logical_debt_count", "performance.filesystem.logical_debt", True),
    "runtime": ("agentstudio_performance_runtime_delivery_total_pending_count", "performance.runtime_delivery.snapshot", True),
    "git_logical_debt": ("agentstudio_performance_git_logical_debt_count", "performance.git.logical_debt", False),
    "git_future_automatic": ("agentstudio_performance_git_future_automatic_count", "performance.git.logical_debt", False),
    "git_future_failure": ("agentstudio_performance_git_future_failure_count", "performance.git.logical_debt", False),
    "git_ready_pending": ("agentstudio_performance_git_ready_pending_count", "performance.git.logical_debt", True),
    "git_capacity_pending": ("agentstudio_performance_git_capacity_pending_count", "performance.git.logical_debt", True),
    "git_active_follow_up": ("agentstudio_performance_git_active_follow_up_count", "performance.git.logical_debt", True),
    "git_unclassified_pending": ("agentstudio_performance_git_unclassified_pending_count", "performance.git.logical_debt", True),
    "git_overdue_deadline": ("agentstudio_performance_git_overdue_deadline_count", "performance.git.logical_debt", True),
    "git_running": ("agentstudio_performance_git_logical_running_count", "performance.git.logical_debt", True),
    "git_oldest_preparation_ms": ("agentstudio_performance_git_oldest_preparation_ms", "performance.git.logical_debt", False),
    "git_next_deadline_ms": ("agentstudio_performance_git_next_deadline_ms", "performance.git.logical_debt", False),
}
observed = {name: [] for name in expected}
try:
    payload = json.load(sys.stdin)
    for item in payload["data"]["result"]:
        metric = item.get("metric", {})
        metric_name = metric.get("__name__")
        settlement_field = metric.get("settlement_field")
        name = f"git_{settlement_field}" if settlement_field else next(
            (candidate for candidate, (expected_metric, _, _) in expected.items() if expected_metric == metric_name),
            None,
        )
        if name not in expected:
            continue
        expected_metric, expected_event, _ = expected[name]
        if metric_name != expected_metric or metric.get("event") != expected_event:
            continue
        value = float(item["value"][1])
        if math.isfinite(value) and value >= 0:
            observed[name].append(value)
except Exception:
    pass

ready = True
parts = []
for name, (_, _, requires_zero) in expected.items():
    samples = observed[name]
    if not samples:
        ready = False
        parts.append(f"{name}=missing")
        continue
    total = sum(samples)
    if requires_zero:
        ready = ready and total == 0
    parts.append(f"{name}={total:g}")

print(f"ready={str(ready).lower()} " + " ".join(parts))
' <<<"$response"
}

wait_for_common_quiescence() {
  local writers_finished_at="$1"
  local quiescence_log="$ARTIFACT/common-quiescence.log"
  local deadline=$((SECONDS + COMMON_QUIESCENCE_TIMEOUT_SECONDS))
  local snapshot="ready=false reason=not_sampled"

  : >"$quiescence_log"
  while [ "$SECONDS" -lt "$deadline" ]; do
    if ! kill -0 "$APP_PID" >/dev/null 2>&1; then
      echo "app pid $APP_PID exited before common quiescence" | tee -a "$quiescence_log" >&2
      return 1
    fi

    snapshot="$(common_debt_snapshot "$writers_finished_at")"
    printf 'observed_at=%s %s writers_finished_at=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$snapshot" \
      "$writers_finished_at" >>"$quiescence_log"

    if [[ "$snapshot" == ready=true* ]]; then
      echo "common_quiescence=succeeded" >>"$quiescence_log"
      return 0
    fi
    sleep 1
  done

  echo "common_quiescence=timed_out timeout_seconds=$COMMON_QUIESCENCE_TIMEOUT_SECONDS" \
    | tee -a "$quiescence_log" >&2
  return 1
}

capture_final_process_resources() {
  local captured_at
  captured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  {
    echo "captured_at=$captured_at"
    echo "app_pid=$APP_PID"
    /bin/ps -p "$APP_PID" -o pid=,time=,rss=,etime=,command=
  } >"$ARTIFACT/post-quiescence-process.txt" || {
    echo "failed to capture post-quiescence process state for PID $APP_PID" >&2
    return 1
  }

  local footprint_status
  if [ ! -x /usr/bin/footprint ]; then
    footprint_status="unavailable"
    echo "footprint is unavailable" >"$ARTIFACT/post-quiescence-footprint.txt"
  elif /usr/bin/footprint -p "$APP_PID" >"$ARTIFACT/post-quiescence-footprint.txt" 2>&1; then
    footprint_status="succeeded"
  else
    footprint_status="failed"
  fi
  {
    echo "captured_at=$captured_at"
    echo "app_pid=$APP_PID"
    echo "footprint_status=$footprint_status"
  } >"$ARTIFACT/post-quiescence-resources.env"

  if [ "$footprint_status" != "succeeded" ]; then
    echo "failed to capture post-quiescence footprint for PID $APP_PID: $footprint_status" >&2
    return 1
  fi
  if ! kill -0 "$APP_PID" >/dev/null 2>&1; then
    echo "app pid $APP_PID exited during final resource capture" >&2
    return 1
  fi
}

victoria_metric_command_bar_filter_query() {
  printf 'max_over_time(agentstudio_performance_commandbar_query_character_count{service.name="AgentStudio",dev.runtime.flavor="debug",agent.proof.marker="%s",event="performance.commandbar.filter"}[5m])' \
    "$TRACE_NAME"
}

victoria_log_command_bar_filter_query_character_max() {
  local response
  response="$(
    query_victoria_logs \
      "$(victoria_event_query performance.commandbar.filter) | fields agentstudio.performance.commandbar.query_character.count | limit 10000" \
      2>/dev/null || true
  )"
  [ -n "$response" ] || {
    printf '0\n'
    return 0
  }
  /usr/bin/python3 -c '
import json
import math
import sys

values = []
for line in sys.stdin:
    if not line.strip():
        continue
    try:
        payload = json.loads(line)
        value = float(payload.get("agentstudio.performance.commandbar.query_character.count", 0))
    except Exception:
        continue
    if math.isfinite(value):
        values.append(value)

print(max(values, default=0))
' <<<"$response"
}

victoria_metric_event_count() {
  local event_name="$1"
  victoria_metric_value "$(victoria_metric_event_query "$event_name")"
}

required_performance_metric_event_names() {
  cat <<'EOF'
performance.commandbar.items
performance.commandbar.filter
performance.tabbar.capture
performance.tabbar.refresh
performance.tabbar.worker
performance.tabbar.current
performance.tabbar.terminal
performance.tabbar.publication
performance.tabbar.visible
performance.sidebar.projection
performance.sidebar.row_index
performance.coordinator.write
EOF
}

missing_required_performance_metric_events() {
  local missing_events=()
  local event_name
  while IFS= read -r event_name; do
    [ -n "$event_name" ] || continue
    if [ "$(victoria_metric_event_count "$event_name")" = "0" ]; then
      missing_events+=("$event_name")
    fi
  done < <(required_performance_metric_event_names)

  local IFS=,
  printf '%s\n' "${missing_events[*]-}"
}

wait_for_required_performance_metrics_export() {
  local export_log="$ARTIFACT/metrics-export-readiness.log"
  local deadline=$((SECONDS + METRICS_EXPORT_TIMEOUT_SECONDS))
  local missing_metric_events

  : >"$export_log"
  while [ "$SECONDS" -lt "$deadline" ]; do
    if ! kill -0 "$APP_PID" >/dev/null 2>&1; then
      echo "app pid $APP_PID exited before required performance metrics exported" \
        | tee -a "$export_log" >&2
      return 1
    fi

    missing_metric_events="$(missing_required_performance_metric_events)"
    printf 'observed_at=%s missing_metric_events=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "${missing_metric_events:-none}" >>"$export_log"
    if [ -z "$missing_metric_events" ]; then
      echo "metrics_export_readiness=succeeded" >>"$export_log"
      return 0
    fi
    sleep 1
  done

  missing_metric_events="$(missing_required_performance_metric_events)"
  {
    echo "metrics_export_readiness=timed_out timeout_seconds=$METRICS_EXPORT_TIMEOUT_SECONDS"
    echo "missing_metric_events=$missing_metric_events"
    local event_name
    while IFS= read -r event_name; do
      [ -n "$event_name" ] || continue
      echo "$event_name.victoria_metrics_count=$(victoria_metric_event_count "$event_name")"
    done < <(required_performance_metric_event_names)
  } | tee -a "$export_log" >&2
  return 1
}

wait_for_tab_bar_lifecycle_continuity() {
  local continuity_log="$ARTIFACT/tabbar-lifecycle-continuity.log"
  local deadline=$((SECONDS + METRICS_EXPORT_TIMEOUT_SECONDS))
  : >"$continuity_log"
  while [ "$SECONDS" -lt "$deadline" ]; do
    if ! capture_tab_bar_lifecycle_snapshot; then
      echo "tabbar_lifecycle_continuity=query_failed" >>"$continuity_log"
      return 1
    fi
    printf 'observed_at=%s capture_count=%s terminal_count=%s exact=%s duplicate_capture=%s duplicate_terminal=%s missing_terminal=%s unexpected_terminal=%s invalid_outcome=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$TAB_BAR_CAPTURE_COUNT" \
      "$TAB_BAR_TERMINAL_COUNT" \
      "$TAB_BAR_LIFECYCLE_EXACT" \
      "$TAB_BAR_DUPLICATE_CAPTURE_SEQUENCE_COUNT" \
      "$TAB_BAR_DUPLICATE_TERMINAL_SEQUENCE_COUNT" \
      "$TAB_BAR_MISSING_TERMINAL_SEQUENCE_COUNT" \
      "$TAB_BAR_UNEXPECTED_TERMINAL_SEQUENCE_COUNT" \
      "$TAB_BAR_INVALID_TERMINAL_OUTCOME_COUNT" >>"$continuity_log"
    if [ "$TAB_BAR_LIFECYCLE_EXACT" = "true" ]; then
      echo "tabbar_lifecycle_continuity=succeeded" >>"$continuity_log"
      return 0
    fi
    if tab_bar_lifecycle_has_irrecoverable_failure; then
      report_tab_bar_lifecycle_errors
      echo "tabbar_lifecycle_continuity=invalid" >>"$continuity_log"
      return 1
    fi
    sleep 1
  done
  echo "tabbar_lifecycle_continuity=timed_out" >>"$continuity_log"
  return 1
}

capture_tab_bar_lifecycle_snapshot() {
  local capture_response terminal_response snapshot
  if ! capture_response="$(
    query_victoria_logs \
      "$(victoria_event_query performance.tabbar.capture) | fields _msg, agentstudio.performance.tabbar.sequence | limit 10000" \
      2>&1
  )"; then
    echo "VictoriaLogs Tab Bar capture query failed: $capture_response" >&2
    return 1
  fi
  if ! terminal_response="$(
    query_victoria_logs \
      "$(victoria_event_query performance.tabbar.terminal) | fields _msg, agentstudio.performance.tabbar.sequence, agentstudio.performance.tabbar.terminal.outcome | limit 10000" \
      2>&1
  )"; then
    echo "VictoriaLogs Tab Bar terminal query failed: $terminal_response" >&2
    return 1
  fi
  snapshot="$(
    /usr/bin/python3 - \
      <(printf '%s\n' "$capture_response") \
      <(printf '%s\n' "$terminal_response") <<'PY'
import collections
import json
import sys

capture_path, terminal_path = sys.argv[1:3]
valid_outcomes = {"published", "equal", "superseded", "cancelled"}


def records(path):
    with open(path, "r", encoding="utf-8") as response_file:
        for line in response_file:
            if not line.strip():
                continue
            try:
                yield json.loads(line)
            except (TypeError, ValueError):
                continue


def sequence(record):
    try:
        value = int(record.get("agentstudio.performance.tabbar.sequence"))
    except (TypeError, ValueError):
        return None
    return value if value >= 0 else None


captures = []
for record in records(capture_path):
    if record.get("_msg") not in (None, "performance.tabbar.capture"):
        continue
    value = sequence(record)
    if value is not None:
        captures.append(value)

terminals = []
invalid_outcome_count = 0
for record in records(terminal_path):
    if record.get("_msg") not in (None, "performance.tabbar.terminal"):
        continue
    value = sequence(record)
    outcome = record.get("agentstudio.performance.tabbar.terminal.outcome")
    if value is None or outcome not in valid_outcomes:
        invalid_outcome_count += 1
        continue
    terminals.append(value)

capture_counts = collections.Counter(captures)
terminal_counts = collections.Counter(terminals)
duplicate_capture_count = sum(count - 1 for count in capture_counts.values() if count > 1)
duplicate_terminal_count = sum(count - 1 for count in terminal_counts.values() if count > 1)
missing_terminal_count = sum((capture_counts - terminal_counts).values())
unexpected_terminal_count = sum((terminal_counts - capture_counts).values())
is_exact = (
    bool(captures)
    and capture_counts == terminal_counts
    and duplicate_capture_count == 0
    and duplicate_terminal_count == 0
    and invalid_outcome_count == 0
)

print(f"capture_count={len(captures)}")
print(f"terminal_count={len(terminals)}")
print(f"lifecycle_exact={str(is_exact).lower()}")
print(f"duplicate_capture_sequence_count={duplicate_capture_count}")
print(f"duplicate_terminal_sequence_count={duplicate_terminal_count}")
print(f"missing_terminal_sequence_count={missing_terminal_count}")
print(f"unexpected_terminal_sequence_count={unexpected_terminal_count}")
print(f"invalid_terminal_outcome_count={invalid_outcome_count}")
PY
  )"

  TAB_BAR_CAPTURE_COUNT="$(sed -n 's/^capture_count=//p' <<<"$snapshot")"
  TAB_BAR_TERMINAL_COUNT="$(sed -n 's/^terminal_count=//p' <<<"$snapshot")"
  TAB_BAR_LIFECYCLE_EXACT="$(sed -n 's/^lifecycle_exact=//p' <<<"$snapshot")"
  TAB_BAR_DUPLICATE_CAPTURE_SEQUENCE_COUNT="$(sed -n 's/^duplicate_capture_sequence_count=//p' <<<"$snapshot")"
  TAB_BAR_DUPLICATE_TERMINAL_SEQUENCE_COUNT="$(sed -n 's/^duplicate_terminal_sequence_count=//p' <<<"$snapshot")"
  TAB_BAR_MISSING_TERMINAL_SEQUENCE_COUNT="$(sed -n 's/^missing_terminal_sequence_count=//p' <<<"$snapshot")"
  TAB_BAR_UNEXPECTED_TERMINAL_SEQUENCE_COUNT="$(sed -n 's/^unexpected_terminal_sequence_count=//p' <<<"$snapshot")"
  TAB_BAR_INVALID_TERMINAL_OUTCOME_COUNT="$(sed -n 's/^invalid_terminal_outcome_count=//p' <<<"$snapshot")"
}

tab_bar_lifecycle_has_irrecoverable_failure() {
  [ "$TAB_BAR_DUPLICATE_CAPTURE_SEQUENCE_COUNT" != "0" ] \
    || [ "$TAB_BAR_DUPLICATE_TERMINAL_SEQUENCE_COUNT" != "0" ] \
    || [ "$TAB_BAR_UNEXPECTED_TERMINAL_SEQUENCE_COUNT" != "0" ] \
    || [ "$TAB_BAR_INVALID_TERMINAL_OUTCOME_COUNT" != "0" ]
}

report_tab_bar_lifecycle_errors() {
  [ "$TAB_BAR_DUPLICATE_CAPTURE_SEQUENCE_COUNT" = "0" ] \
    || echo "Tab Bar lifecycle has duplicate capture sequences: $TAB_BAR_DUPLICATE_CAPTURE_SEQUENCE_COUNT" >&2
  [ "$TAB_BAR_DUPLICATE_TERMINAL_SEQUENCE_COUNT" = "0" ] \
    || echo "Tab Bar lifecycle has duplicate terminal sequences: $TAB_BAR_DUPLICATE_TERMINAL_SEQUENCE_COUNT" >&2
  [ "$TAB_BAR_MISSING_TERMINAL_SEQUENCE_COUNT" = "0" ] \
    || echo "Tab Bar lifecycle has missing terminal sequences: $TAB_BAR_MISSING_TERMINAL_SEQUENCE_COUNT" >&2
  [ "$TAB_BAR_UNEXPECTED_TERMINAL_SEQUENCE_COUNT" = "0" ] \
    || echo "Tab Bar lifecycle has unexpected terminal sequences: $TAB_BAR_UNEXPECTED_TERMINAL_SEQUENCE_COUNT" >&2
  [ "$TAB_BAR_INVALID_TERMINAL_OUTCOME_COUNT" = "0" ] \
    || echo "Tab Bar lifecycle has invalid terminal outcomes: $TAB_BAR_INVALID_TERMINAL_OUTCOME_COUNT" >&2
}

require_exact_tab_bar_lifecycle() {
  capture_tab_bar_lifecycle_snapshot || return 1
  report_tab_bar_lifecycle_errors
  [ "$TAB_BAR_LIFECYCLE_EXACT" = "true" ]
}

trace_queue_metric_query() {
  local metric_name="$1"
  printf 'max(%s{service.name="AgentStudio",dev.runtime.flavor="debug",agent.proof.marker="%s"})' \
    "$metric_name" \
    "$TRACE_NAME"
}

require_trace_queue_completeness() {
  TRACE_QUEUE_DROPPED_RECORD_COUNT="$(
    victoria_metric_value_or_empty "$(
      trace_queue_metric_query agentstudio_performance_trace_queue_dropped_record_count
    )"
  )"
  TRACE_QUEUE_HIGH_WATERMARK="$(
    victoria_metric_value_or_empty "$(
      trace_queue_metric_query agentstudio_performance_trace_queue_high_watermark
    )"
  )"
  /usr/bin/python3 - "$TRACE_QUEUE_DROPPED_RECORD_COUNT" "$TRACE_QUEUE_HIGH_WATERMARK" <<'PY'
import math
import sys

try:
    dropped_record_count = float(sys.argv[1])
    high_watermark = float(sys.argv[2])
except (IndexError, ValueError):
    print("trace queue completeness metrics are missing", file=sys.stderr)
    sys.exit(1)

if not math.isfinite(dropped_record_count) or dropped_record_count != 0:
    print(f"trace queue dropped record count must be zero: {dropped_record_count:g}", file=sys.stderr)
    sys.exit(1)
if not math.isfinite(high_watermark) or high_watermark < 0:
    print(f"trace queue high-water mark must be present and nonnegative: {high_watermark:g}", file=sys.stderr)
    sys.exit(1)
PY
}

jsonl_proof_enabled() {
  [ "$ALLOW_JSONL_PROOF" = "1" ]
}

jsonl_event_count() {
  local event_name="$1"
  local jsonl_file="$2"
  [ -n "$jsonl_file" ] && [ -f "$jsonl_file" ] || {
    printf '0\n'
    return 0
  }
  grep -c "\"body\":\"$event_name\"" "$jsonl_file" || true
}

current_trace_jsonl_files() {
  find "$TRACE_DIR" -maxdepth 1 -name "agentstudio-$TRACE_NAME-*.jsonl" -type f -print 2>/dev/null
}

current_trace_jsonl_has_event() {
  local event_name="$1"
  local jsonl_file
  while IFS= read -r jsonl_file; do
    if grep "\"body\":\"$event_name\"" "$jsonl_file" >/dev/null 2>&1; then
      return 0
    fi
  done < <(current_trace_jsonl_files)
  return 1
}

current_trace_jsonl_has_command_bar_filter() {
  local jsonl_file
  while IFS= read -r jsonl_file; do
    if grep "\"body\":\"performance.commandbar.filter\"" "$jsonl_file" 2>/dev/null \
      | grep -E "\"agentstudio.performance.commandbar.query_character.count\":\"?[1-9][0-9]*\"?" >/dev/null 2>&1
    then
      return 0
    fi
  done < <(current_trace_jsonl_files)
  return 1
}

wait_for_trace_event() {
  local event_name="$1"
  local timeout_seconds="$2"
  local deadline=$((SECONDS + timeout_seconds))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$(victoria_event_count "$event_name")" -gt 0 ]; then
      return 0
    fi
    if jsonl_proof_enabled && current_trace_jsonl_has_event "$event_name"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_command_bar_repo_filter_event() {
  local timeout_seconds="$1"
  local deadline=$((SECONDS + timeout_seconds))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$(victoria_log_command_bar_filter_query_character_max)" != "0" ]; then
      return 0
    fi
    if jsonl_proof_enabled && current_trace_jsonl_has_command_bar_filter; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_startup_diagnostic_completion() {
  local timeout_seconds="$1"
  local deadline=$((SECONDS + timeout_seconds))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$(victoria_event_count app.startup_diagnostic_action.completed)" -gt 0 ]; then
      return 0
    fi
    if [ "$(victoria_event_count app.startup_diagnostic_action.blocked)" -gt 0 ]; then
      echo "startup diagnostic reported blocked" >&2
      return 1
    fi
    sleep 1
  done
  echo "timed out waiting for startup diagnostic completion" >&2
  return 1
}

writer_loop() {
  local writer_index="$1"
  local worktree_path="$2"
  local end_at=$((SECONDS + DURATION_SECONDS))
  local iteration=0
  while [ "$SECONDS" -lt "$end_at" ]; do
    local file_path="$worktree_path/perf-writer-$writer_index.txt"
    printf 'writer=%s iteration=%s marker=%s\n' "$writer_index" "$iteration" "$TRACE_NAME" >>"$file_path"
    git -C "$worktree_path" add "$file_path" >/dev/null 2>&1
    git -C "$worktree_path" \
      -c user.email=agentstudio-perf@example.invalid \
      -c user.name='AgentStudio Perf Fixture' \
      -c commit.gpgsign=false \
      -c tag.gpgsign=false \
      commit -m "perf writer $writer_index iteration $iteration" >/dev/null 2>&1 || true
    iteration=$((iteration + 1))
    sleep 1
  done
  printf '%s\n' "$iteration" >"$ARTIFACT/writer-$writer_index.iterations"
}

start_writers() {
  local writer_index
  for writer_index in $(seq 0 $((WRITER_COUNT - 1))); do
    local worktree_slot=$((writer_index % WORKTREE_COUNT))
    local writer_log="$ARTIFACT/writer-$writer_index.log"
    writer_loop "$writer_index" "${WORKTREE_PATHS[$worktree_slot]}" >"$writer_log" 2>&1 &
    local writer_pid=$!
    WRITER_PIDS+=("$writer_pid")
    printf '%s\n' "$writer_pid" >"$PID_DIR/writer-$writer_index.pid"
  done
}

sum_issued_interaction_count() {
  local total=0
  local writer_index
  for writer_index in $(seq 0 $((WRITER_COUNT - 1))); do
    local count_file="$ARTIFACT/writer-$writer_index.iterations"
    if [ ! -f "$count_file" ]; then
      echo "writer did not record completed iterations: $writer_index" >&2
      return 1
    fi
    local iteration_count
    iteration_count="$(cat "$count_file")"
    case "$iteration_count" in
      ''|*[!0-9]*)
        echo "writer recorded invalid iteration count: $writer_index" >&2
        return 1
        ;;
    esac
    total=$((total + iteration_count))
  done
  if [ "$total" -le 0 ]; then
    echo "workload did not issue any writer interactions" >&2
    return 1
  fi
  printf '%s\n' "$total"
}

drive_command_bar_smoke() {
  if [ "$DRIVE_COMMAND_BAR" != "1" ]; then
    echo "command-bar smoke skipped by AGENTSTUDIO_PERF_DRIVE_COMMAND_BAR=0" >"$ARTIFACT/commandbar-smoke.log"
    return 0
  fi
  if [ -z "$APP_PID" ]; then
    echo "command-bar smoke skipped: no app PID" >"$ARTIFACT/commandbar-smoke.log"
    return 1
  fi
  log_command startup diagnostic command-bar repo filter smoke for PID "$APP_PID"
  {
    echo "driver=startup-diagnostic"
    echo "action=command-bar-repo-filter"
    echo "app_pid=$APP_PID"
  } >"$ARTIFACT/commandbar-smoke.log"
}

sample_app() {
  if [ -z "$APP_PID" ]; then
    return 0
  fi
  if [ -x /usr/bin/sample ]; then
    log_command /usr/bin/sample "$APP_PID" 5 1 -file "$ARTIFACT/main-sample.txt"
    /usr/bin/sample "$APP_PID" 5 1 -file "$ARTIFACT/main-sample.txt" >>"$ARTIFACT/sample.log" 2>&1 || true
  fi
}

capture_restore_trace() {
  local restore_trace_source="/tmp/agentstudio_debug.log"
  local restore_trace_target="$ARTIFACT/restore-trace.log"
  [ -n "$APP_PID" ] || return 0
  [ -f "$restore_trace_source" ] || return 0
  grep "pid=$APP_PID " "$restore_trace_source" >"$restore_trace_target" 2>/dev/null || true
}

capture_authenticated_final_state_oracle() {
  local ipc_metadata_path="${AGENTSTUDIO_OBSERVABILITY_IPC_METADATA:-$APP_DATA_DIR/ipc/runtime.json}"
  local ipc_debug_token_path="${AGENTSTUDIO_OBSERVABILITY_IPC_DEBUG_TOKEN:-$APP_DATA_DIR/ipc/debug-token}"
  local oracle_file="$ARTIFACT/final-state-oracle.env"
  if [ ! -f "$ipc_metadata_path" ] || [ ! -f "$ipc_debug_token_path" ]; then
    echo "authenticated IPC metadata or token is missing for final-state oracle" >&2
    return 1
  fi

  /usr/bin/python3 - \
    "$ipc_metadata_path" \
    "$ipc_debug_token_path" \
    "$TAB_ID" \
    "$ACTIVE_PANE_COUNT" >"$oracle_file" <<'PY'
import json
import socket
import sys

metadata_path, token_path, expected_tab_id = sys.argv[1:4]
expected_pane_count = int(sys.argv[4])
expected_tab_id = expected_tab_id.lower()

with open(metadata_path, "r", encoding="utf-8") as metadata_file:
    socket_path = json.load(metadata_file).get("socketPath")
with open(token_path, "r", encoding="utf-8") as token_file:
    token = token_file.read().strip()
if not socket_path or not token:
    print("authenticated IPC metadata or token is incomplete", file=sys.stderr)
    sys.exit(1)

ipc_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
ipc_socket.settimeout(15)
ipc_socket.connect(socket_path)
reader = ipc_socket.makefile("rb")


def request(request_id, method, params):
    payload = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
    ipc_socket.sendall((json.dumps(payload, separators=(",", ":")) + "\n").encode("utf-8"))
    while True:
        line = reader.readline()
        if not line:
            print(f"IPC socket closed before {method} response", file=sys.stderr)
            sys.exit(1)
        response = json.loads(line.decode("utf-8"))
        if response.get("id") != request_id:
            continue
        if response.get("error") is not None:
            print(f"{method} failed", file=sys.stderr)
            sys.exit(1)
        return response.get("result", {})


try:
    request(1, "auth.login", {"token": token})
    workspace_result = request(2, "workspace.list", {})
    pane_result = request(3, "pane.list", {})
finally:
    reader.close()
    ipc_socket.close()

current_workspaces = [workspace for workspace in workspace_result.get("workspaces", []) if workspace.get("isCurrent")]
panes = pane_result.get("panes", [])
current_tab_count = current_workspaces[0].get("tabCount", 0) if len(current_workspaces) == 1 else 0
active_panes = [pane for pane in panes if pane.get("isActive")]


def normalized_uuid(value):
    return value.lower() if isinstance(value, str) else None


tab_count_equivalent = current_tab_count == 1
active_tab_equivalent = (
    len(active_panes) == 1 and normalized_uuid(active_panes[0].get("tabId")) == expected_tab_id
)
membership_equivalent = (
    len(panes) == expected_pane_count
    and all(normalized_uuid(pane.get("tabId")) == expected_tab_id for pane in panes)
)

print(f"final_tab_count={current_tab_count}")
print(f"final_pane_count={len(panes)}")
print(f"final_active_pane_count={len(active_panes)}")
print(f"final_tab_count_equivalent={str(tab_count_equivalent).lower()}")
print(f"final_active_tab_equivalent={str(active_tab_equivalent).lower()}")
print(f"final_membership_equivalent={str(membership_equivalent).lower()}")
PY

  FINAL_TAB_COUNT="$(sed -n 's/^final_tab_count=//p' "$oracle_file")"
  FINAL_PANE_COUNT="$(sed -n 's/^final_pane_count=//p' "$oracle_file")"
  FINAL_ACTIVE_PANE_COUNT="$(sed -n 's/^final_active_pane_count=//p' "$oracle_file")"
  FINAL_TAB_COUNT_EQUIVALENT="$(sed -n 's/^final_tab_count_equivalent=//p' "$oracle_file")"
  FINAL_ACTIVE_TAB_EQUIVALENT="$(sed -n 's/^final_active_tab_equivalent=//p' "$oracle_file")"
  FINAL_MEMBERSHIP_EQUIVALENT="$(sed -n 's/^final_membership_equivalent=//p' "$oracle_file")"

  if [ "$FINAL_TAB_COUNT_EQUIVALENT" != "true" ] \
    || [ "$FINAL_ACTIVE_TAB_EQUIVALENT" != "true" ] \
    || [ "$FINAL_MEMBERSHIP_EQUIVALENT" != "true" ]
  then
    echo "authenticated IPC final-state oracle did not match the fixture" >&2
    return 1
  fi
}

summary_event_names() {
  cat <<'EOF'
performance.git.tick
performance.git.admission
performance.git.status
performance.git.status_unavailable
performance.git.snapshot_dedup
performance.git.event_posted
performance.coordinator.write
performance.topology.repo_and_worktree
performance.tabbar.capture
performance.tabbar.current
performance.tabbar.publication
performance.tabbar.refresh
performance.tabbar.terminal
performance.tabbar.visible
performance.tabbar.worker
performance.sidebar.projection
performance.sidebar.row_index
performance.commandbar.items
performance.commandbar.filter
EOF
}

summarize_performance_event() {
  local event_name="$1"
  local jsonl_file="$2"
  local victoria_metrics_count victoria_logs_count jsonl_count elapsed_max elapsed_p95 p95_unavailable
  victoria_metrics_count="$(victoria_metric_event_count "$event_name")"
  victoria_logs_count="$(victoria_event_count "$event_name")"
  jsonl_count="$(jsonl_event_count "$event_name" "$jsonl_file")"
  elapsed_max="$(victoria_event_elapsed_max "$event_name")"
  elapsed_p95="$(victoria_metric_value_or_empty "$(victoria_metric_event_elapsed_p95_query "$event_name")")"
  if [ -z "$elapsed_p95" ]; then
    elapsed_p95=0
    p95_unavailable=true
  else
    p95_unavailable=false
  fi

  echo "$event_name victoria_metrics_count=$victoria_metrics_count victoria_logs_count=$victoria_logs_count jsonl_count=$jsonl_count"
  echo "$event_name.victoria_metrics_count=$victoria_metrics_count"
  echo "$event_name.victoria_logs_count=$victoria_logs_count"
  echo "$event_name.jsonl_count=$jsonl_count"
  echo "$event_name.elapsed_ms.max=$elapsed_max"
  echo "$event_name.elapsed_ms.p95=$elapsed_p95"
  echo "$event_name.elapsed_ms.p95_unavailable=$p95_unavailable"
}

summarize_traces() {
  capture_restore_trace
  local jsonl_file query_character_max
  jsonl_file="$(current_trace_jsonl_files | head -n 1)"
  query_character_max="$(victoria_log_command_bar_filter_query_character_max)"
  {
    echo "artifact=$ARTIFACT"
    echo "trace_name=$TRACE_NAME"
    echo "source_head=$SOURCE_HEAD"
    echo "source_digest=$SOURCE_DIGEST"
    echo "executable_digest=$EXECUTABLE_DIGEST"
    echo "trace_tags=$WORKLOAD_TRACE_TAGS"
    echo "activation_mode=$ACTIVATION_MODE"
    echo "launch_method=$APP_LAUNCH_METHOD"
    echo "ipc_auth_mode=$IPC_AUTH_MODE"
    echo "executable_identity=$APP_BINARY"
    echo "worktree_identity=$WORKTREE_IDENTITY"
    echo "workload_fingerprint=$WORKLOAD_FINGERPRINT"
    echo "issued_interaction_count=$ISSUED_INTERACTION_COUNT"
    echo "regression_boundary_percent=$REGRESSION_BOUNDARY_PERCENT"
    echo "performance.tabbar.capture_count=$TAB_BAR_CAPTURE_COUNT"
    echo "performance.tabbar.terminal_count=$TAB_BAR_TERMINAL_COUNT"
    echo "performance.tabbar.lifecycle_exact=$TAB_BAR_LIFECYCLE_EXACT"
    echo "performance.tabbar.duplicate_capture_sequence_count=$TAB_BAR_DUPLICATE_CAPTURE_SEQUENCE_COUNT"
    echo "performance.tabbar.duplicate_terminal_sequence_count=$TAB_BAR_DUPLICATE_TERMINAL_SEQUENCE_COUNT"
    echo "performance.tabbar.missing_terminal_sequence_count=$TAB_BAR_MISSING_TERMINAL_SEQUENCE_COUNT"
    echo "performance.tabbar.unexpected_terminal_sequence_count=$TAB_BAR_UNEXPECTED_TERMINAL_SEQUENCE_COUNT"
    echo "performance.tabbar.invalid_terminal_outcome_count=$TAB_BAR_INVALID_TERMINAL_OUTCOME_COUNT"
    echo "agentstudio.performance.trace_queue.dropped_record.count=${TRACE_QUEUE_DROPPED_RECORD_COUNT:-}"
    echo "agentstudio.performance.trace_queue.high_watermark=${TRACE_QUEUE_HIGH_WATERMARK:-}"
    echo "final_tab_count=$FINAL_TAB_COUNT"
    echo "final_pane_count=$FINAL_PANE_COUNT"
    echo "final_active_pane_count=$FINAL_ACTIVE_PANE_COUNT"
    echo "final_tab_count_equivalent=$FINAL_TAB_COUNT_EQUIVALENT"
    echo "final_active_tab_equivalent=$FINAL_ACTIVE_TAB_EQUIVALENT"
    echo "final_membership_equivalent=$FINAL_MEMBERSHIP_EQUIVALENT"
    echo "required_performance_metric_minimum_count=$REQUIRED_PERFORMANCE_METRIC_MINIMUM_COUNT"
    echo "required_commandbar_query_character_minimum=$REQUIRED_COMMANDBAR_QUERY_CHARACTER_MINIMUM"
    echo "workspace_file=$WORKSPACE_FILE"
    echo "app_data_dir=$APP_DATA_DIR"
    echo "fixture_root=$FIXTURE_ROOT"
    echo "repo_count=$REPO_COUNT"
    echo "worktree_count=$WORKTREE_COUNT"
    echo "active_pane_count=$ACTIVE_PANE_COUNT"
    echo "writer_count=$WRITER_COUNT"
    echo "duration_seconds=$DURATION_SECONDS"
    echo "drive_command_bar=$DRIVE_COMMAND_BAR"
    echo "sample_during_workload=$SAMPLE_DURING_WORKLOAD"
    echo "allow_jsonl_proof=$ALLOW_JSONL_PROOF"
    echo "allow_test_responses=$ALLOW_TEST_RESPONSES"
    echo "app_pid=$APP_PID"
    echo "debug_observability_state_file=$DEBUG_OBSERVABILITY_STATE_FILE"
    [ -f "$DEBUG_STATE_COPY" ] && echo "debug_observability_state_copy=$DEBUG_STATE_COPY"
    echo "jsonl_file=$jsonl_file"
    [ -f "$ARTIFACT/restore-trace.log" ] && echo "restore_trace_file=$ARTIFACT/restore-trace.log"
    while IFS= read -r event_name; do
      [ -n "$event_name" ] || continue
      summarize_performance_event "$event_name" "$jsonl_file"
      case "$event_name" in
        performance.coordinator.write)
          : # Keep the event name in source for script-contract tests.
          ;;
      esac
      # performance.coordinator.write \
    done < <(summary_event_names)
    echo "performance.git.status.elapsed_ms.mean=$(victoria_metric_event_elapsed_mean_value performance.git.status)"
    echo "performance.git.status.elapsed_ms.p95=$(victoria_metric_event_elapsed_p95 performance.git.status)"
    echo "performance.git.status.elapsed_ms.max=$(victoria_metric_event_elapsed_max performance.git.status)"
    local unavailable_reason
    while IFS= read -r unavailable_reason; do
      local reason_selector=",reason=\"$unavailable_reason\""
      echo "performance.git.status_unavailable.reason.$unavailable_reason.count=$(victoria_metric_event_count_for_reason performance.git.status_unavailable "$unavailable_reason")"
      echo "performance.git.status_unavailable.reason.$unavailable_reason.elapsed_ms.mean=$(victoria_metric_event_elapsed_mean_value performance.git.status_unavailable "$reason_selector")"
      echo "performance.git.status_unavailable.reason.$unavailable_reason.elapsed_ms.p95=$(victoria_metric_event_elapsed_p95 performance.git.status_unavailable "$reason_selector")"
      echo "performance.git.status_unavailable.reason.$unavailable_reason.elapsed_ms.max=$(victoria_metric_event_elapsed_max performance.git.status_unavailable "$reason_selector")"
    done < <(victoria_metric_status_unavailable_reason_values)
    echo "performance.commandbar.filter.query_character.max=$query_character_max"
  } | tee "$SUMMARY_FILE"
}

if test_responses_enabled && [ "${AGENTSTUDIO_PERF_TEST_COMMON_DEBT_SNAPSHOT:-0}" = "1" ]; then
  common_debt_snapshot "${AGENTSTUDIO_PERF_TEST_COMMON_DEBT_MINIMUM_TIMESTAMP:-0}"
  exit 0
fi

SOURCE_HEAD="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
SOURCE_DIGEST="$(source_digest)"
WORKTREE_IDENTITY="$(canonical_path "$PROJECT_ROOT")"
WORKLOAD_FINGERPRINT="$(workload_fingerprint)"

mkdir -p "$ARTIFACT" "$FIXTURE_ROOT" "$PID_DIR"
: >"$COMMAND_LOG"
if [ "$prepare_only" != true ]; then
  load_debug_identity_for_workload
  preflight_debug_observability_idle
  fail_if_trace_marker_would_reuse_jsonl
fi
mkdir -p "$APP_DATA_DIR/workspaces" "$TRACE_DIR"

prepare_fixture

{
  echo "trace_name=$TRACE_NAME"
  echo "artifact=$ARTIFACT"
  echo "workspace_file=$WORKSPACE_FILE"
  echo "app_data_dir=$APP_DATA_DIR"
  echo "runtime_zmx_dir=$WORKLOAD_ZMX_DIR"
  echo "debug_observability_state_file=$DEBUG_OBSERVABILITY_STATE_FILE"
  echo "fixture_root=$FIXTURE_ROOT"
  echo "repo_count=$REPO_COUNT"
  echo "worktree_count=$WORKTREE_COUNT"
  echo "active_pane_count=$ACTIVE_PANE_COUNT"
} >"$ARTIFACT/observability-state.env"

if [ "$prepare_only" = true ]; then
  if test_responses_enabled; then
    if ! wait_for_tab_bar_lifecycle_continuity; then
      echo "Tab Bar capture/terminal continuity did not settle within $METRICS_EXPORT_TIMEOUT_SECONDS seconds" >&2
      summarize_traces
      exit 1
    fi
    if ! require_trace_queue_completeness; then
      summarize_traces
      exit 1
    fi
  fi
  summarize_traces
  echo "prepared fixture only: $ARTIFACT"
  exit 0
fi

materialize_workspace_fixture
launch_debug_observability_app

if ! wait_for_trace_event performance.coordinator.write 45; then
  echo "did not observe performance.coordinator.write within startup timeout" >&2
  sample_app
  summarize_traces
  exit 1
fi

if ! drive_command_bar_smoke; then
  echo "command-bar smoke did not run; see $ARTIFACT/commandbar-smoke.log" >&2
fi
if [ "$DRIVE_COMMAND_BAR" = "1" ]; then
  if ! wait_for_startup_diagnostic_completion 20; then
    summarize_traces
    exit 1
  fi
else
  echo "perf:report candidate selection requires AGENTSTUDIO_PERF_DRIVE_COMMAND_BAR=1; startup diagnostic completion wait skipped"
fi

start_writers
if [ "$SAMPLE_DURING_WORKLOAD" = "1" ]; then
  sample_app
else
  echo "sample skipped during measured workload; set AGENTSTUDIO_PERF_SAMPLE_DURING_WORKLOAD=1 for stack capture" \
    >"$ARTIFACT/sample.log"
fi

for writer_pid in "${WRITER_PIDS[@]}"; do
  wait "$writer_pid" >/dev/null 2>&1 || true
done
if ! ISSUED_INTERACTION_COUNT="$(sum_issued_interaction_count)"; then
  summarize_traces
  exit 1
fi
# VictoriaMetrics timestamps have one-second precision at this proof boundary.
# Use the enclosing second so a final zero-debt snapshot emitted immediately
# before the writer processes exit remains eligible for the freshness check.
WRITERS_FINISHED_AT="$(date -u +%s)"
echo "writers_finished_at=$WRITERS_FINISHED_AT" >"$ARTIFACT/writers-finished.env"

if ! wait_for_trace_event performance.git.status 30; then
  echo "did not observe performance.git.status after busy workload" >&2
  summarize_traces
  exit 1
fi

if [ "$DRIVE_COMMAND_BAR" = "1" ] && ! wait_for_command_bar_repo_filter_event 10; then
  echo "did not observe non-empty performance.commandbar.filter after startup command-bar repo filter smoke" >&2
  summarize_traces
  exit 1
fi

if ! wait_for_common_quiescence "$WRITERS_FINISHED_AT"; then
  echo "common runtime debt did not reach fresh zero within $COMMON_QUIESCENCE_TIMEOUT_SECONDS seconds" >&2
  summarize_traces
  exit 1
fi

if ! wait_for_required_performance_metrics_export; then
  echo "required performance metrics did not export within $METRICS_EXPORT_TIMEOUT_SECONDS seconds" >&2
  summarize_traces
  exit 1
fi
if ! wait_for_tab_bar_lifecycle_continuity; then
  echo "Tab Bar capture/terminal continuity did not settle within $METRICS_EXPORT_TIMEOUT_SECONDS seconds" >&2
  summarize_traces
  exit 1
fi
if ! require_trace_queue_completeness; then
  summarize_traces
  exit 1
fi
require_status_latency_metrics

if ! capture_final_process_resources; then
  summarize_traces
  exit 1
fi
if ! capture_authenticated_final_state_oracle; then
  summarize_traces
  exit 1
fi

summarize_traces
echo "git refresh performance workload proof: $ARTIFACT"
