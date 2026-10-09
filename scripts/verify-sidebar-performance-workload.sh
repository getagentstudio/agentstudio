#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_STACK_HELPER="$HOME/dev/ai-tools/observability/observability-stack"
STACK_HELPER="${AI_TOOLS_OBSERVABILITY_STACK_HELPER:-$DEFAULT_STACK_HELPER}"
DEBUG_RUNNER="${AGENTSTUDIO_SIDEBAR_DEBUG_RUNNER:-$PROJECT_ROOT/scripts/run-debug-observability.sh}"
COLLECTOR_HEALTH_URL="${AI_TOOLS_OBSERVABILITY_COLLECTOR_HEALTH_URL:-http://127.0.0.1:13133/}"
METRICS_QUERY_URL="${AI_TOOLS_OBSERVABILITY_METRICS_QUERY_URL:-http://127.0.0.1:8428/api/v1/query}"
LOGS_QUERY_URL="${AI_TOOLS_OBSERVABILITY_LOGS_QUERY_URL:-http://127.0.0.1:9428/select/logsql/query}"
DEFAULT_PROOF_ROOT="/tmp/as-sp"
WORKLOAD_TRACE_TAGS="performance,app.startup,terminal.startup"
KEY_MUTATION_TRACE_TAGS="performance,app.startup"
WORKLOAD_CYCLES="${AGENTSTUDIO_SIDEBAR_IPC_CYCLES:-100}"
REQUIRED_SAMPLE_COUNT=100
REQUIRED_MATERIALIZED_SAMPLE_COUNT=90
REQUIRED_KEY_MUTATION_COUNT=100
REQUIRED_METRIC_READBACK_ATTEMPTS=45
WORKLOAD_FIXTURE_VERSION=sidebar-workload-v7-fixed-panes-organization
REQUIRED_REPOSITORY_COUNT=150
REQUIRED_WORKTREE_COUNT=180
REQUIRED_TAB_COUNT=12
REQUIRED_PANE_COUNT=36
REQUIRED_ACTIVE_PTY_COUNT=1
STRICT_SIDEBAR_IDLE_POPULATIONS="zero_pty_idle"
STRICT_SIDEBAR_ACTION_POPULATIONS="search_clear grouping hide_show tab_switch"
STRICT_SIDEBAR_READBACK_FIELDS="semantic_generation acknowledged_revision visible_generation focus_disposition accessibility_disposition"
STRICT_SIDEBAR_FALSE_GREEN_OUTCOMES="population_invalidated sampler_gap"
STRICT_SIDEBAR_PERTURBATION_FIELDS="diagnostic_cpu_p95_delta_percentage_points diagnostic_interaction_p95_growth_percent"

usage() {
  cat <<'USAGE'
Usage: verify-sidebar-performance-workload.sh --prepare-only
       verify-sidebar-performance-workload.sh --baseline
       verify-sidebar-performance-workload.sh --compare
       verify-sidebar-performance-workload.sh --sidebar-proof

Runs a marker-scoped sidebar semantic/performance proof through the standard
per-worktree debug observability runner. Proof modes reject unsafe no-auth IPC
and foreground activation. The script never exports sidebar query text,
notification text, labels, repo/worktree names, pane/tab labels, paths, or raw ids.

Environment overrides:
  AGENTSTUDIO_SIDEBAR_PROOF_ROOT          Parent directory for artifacts.
  AGENTSTUDIO_TRACE_NAME                  Safe marker name.
  AGENTSTUDIO_SIDEBAR_ALLOW_TEST_RESPONSES
                                          Only with --prepare-only; injects canned
                                          metrics responses for script tests.
  AGENTSTUDIO_OBSERVABILITY_STATE_FILE    State file passed to debug runner.
USAGE
}

mode=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prepare-only|--baseline|--compare|--sidebar-proof)
      if [ -n "$mode" ]; then
        usage >&2
        exit 2
      fi
      mode="${1#--}"
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

if [ -z "$mode" ]; then
  usage >&2
  exit 2
fi

if [ "$mode" != "prepare-only" ] && [ -n "${AGENTSTUDIO_IPC_UNSAFE_NO_AUTH:-}" ]; then
  echo "sidebar proof refuses AGENTSTUDIO_IPC_UNSAFE_NO_AUTH" >&2
  exit 2
fi

canonical_path() {
  /usr/bin/python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

decode_identity_value() {
  local identity="$1"
  local key="$2"
  local raw_value
  raw_value="$(printf '%s\n' "$identity" | sed -n "s/^$key=//p" | tail -1)"
  /usr/bin/python3 - "$raw_value" <<'PY'
import shlex
import sys

parts = shlex.split(sys.argv[1]) if sys.argv[1] else []
print(parts[0] if parts else "")
PY
}

stop_pid() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  if kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  fi
}

sample_process_cpu() {
  local pid="${1:?missing process pid}"
  local sample_file="${2:?missing CPU sample file}"
  exec /usr/bin/top -l 0 -s 1 -pid "$pid" -stats pid,cpu >"$sample_file"
}

summarize_process_cpu() {
  local sample_file="${1:?missing CPU sample file}"
  local pid="${2:?missing process pid}"
  /usr/bin/python3 - "$sample_file" "$pid" <<'PY'
import math
import pathlib
import sys

values = []
pid = sys.argv[2]
discarded_first_process_sample = False
for raw_line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    fields = raw_line.split()
    if len(fields) != 2 or fields[0] != pid:
        continue
    try:
        value = float(fields[1])
    except ValueError:
        continue
    if not discarded_first_process_sample:
        discarded_first_process_sample = True
        continue
    if math.isfinite(value):
        values.append(value)
if not values:
    raise SystemExit("process CPU sampling produced no values")
values.sort()
def percentile(fraction):
    return values[min(len(values) - 1, max(0, math.ceil(len(values) * fraction) - 1))]
print(percentile(0.50))
print(percentile(0.95))
print(values[-1])
print(len(values))
PY
}

reset_disposable_debug_root() {
  local artifact_root expected_bundle_identifier inventory reset_root zmx_bin zmx_dir session_name
  RESET_IDENTITY="$(AGENTSTUDIO_DEBUG_DATA_DIR="$STRICT_DISPOSABLE_DATA_ROOT" \
    "$DEBUG_RUNNER" --print-identity)"
  RESET_DEBUG_CODE="$(decode_identity_value "$RESET_IDENTITY" AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE)"
  RESET_DATA_DIR="$(decode_identity_value "$RESET_IDENTITY" AGENTSTUDIO_OBSERVABILITY_DATA_DIR)"
  RESET_BUNDLE_IDENTIFIER="$(decode_identity_value "$RESET_IDENTITY" AGENTSTUDIO_OBSERVABILITY_BUNDLE_IDENTIFIER)"

  artifact_root="$(canonical_path "$ARTIFACT")"
  reset_root="$(canonical_path "$RESET_DATA_DIR")"
  [ "$reset_root" = "$(canonical_path "$STRICT_DISPOSABLE_DATA_ROOT")" ] || {
    echo "refusing reset for non-proof data root: $RESET_DATA_DIR" >&2
    return 1
  }
  case "$reset_root" in
    "$artifact_root/"*) ;;
    *) echo "refusing reset outside proof artifact: $RESET_DATA_DIR" >&2; return 1 ;;
  esac
  case "$reset_root" in
    "$(canonical_path "$HOME/.agentstudio-db")"/*)
      echo "refusing to reset persistent debug data root: $RESET_DATA_DIR" >&2
      return 1
      ;;
  esac
  case "$RESET_DEBUG_CODE" in
    ''|*[!a-z0-9]*) echo "refusing reset with unsafe debug code: $RESET_DEBUG_CODE" >&2; return 1 ;;
  esac
  expected_bundle_identifier="com.agentstudio.app.debug.d$RESET_DEBUG_CODE"
  if [ "$RESET_BUNDLE_IDENTIFIER" != "$expected_bundle_identifier" ]; then
    echo "refusing reset for mismatched debug bundle identifier: $RESET_BUNDLE_IDENTIFIER" >&2
    return 1
  fi

  if ! AGENTSTUDIO_DEBUG_DATA_DIR="$STRICT_DISPOSABLE_DATA_ROOT" \
    "$DEBUG_RUNNER" --preflight-idle; then
    echo "refusing to reset a non-idle debug root" >&2
    return 1
  fi
  zmx_dir="$RESET_DATA_DIR/z"
  zmx_bin="$RESET_DATA_DIR/bin/zmx"
  if [ -d "$zmx_dir" ]; then
    inventory="$(AGENTSTUDIO_ZMX_DISPOSABLE_PROOF_ROOT="$STRICT_DISPOSABLE_DATA_ROOT" \
      "$PROJECT_ROOT/scripts/cleanup-debug-zmx-sessions.sh" \
      --inventory-exact-root "$zmx_dir" --zmx-bin "$zmx_bin")" || return 1
    while IFS= read -r session_name; do
      [ -n "$session_name" ] || continue
      ZMX_DIR="$zmx_dir" "$zmx_bin" kill "$session_name"
    done < <(printf '%s\n' "$inventory" | sed -n 's/^session=\([^ ]*\).*/\1/p')
    inventory="$(AGENTSTUDIO_ZMX_DISPOSABLE_PROOF_ROOT="$STRICT_DISPOSABLE_DATA_ROOT" \
      "$PROJECT_ROOT/scripts/cleanup-debug-zmx-sessions.sh" \
      --inventory-exact-root "$zmx_dir" --zmx-bin "$zmx_bin")" || return 1
    printf '%s\n' "$inventory" | grep -q 'session_count=0$' || {
      echo "refusing to remove debug data root while exact-root zmx sessions remain" >&2
      return 1
    }
  fi

  echo "sidebar reset: bundle_id=$RESET_BUNDLE_IDENTIFIER data_dir=$RESET_DATA_DIR exact_zmx_reset=true"
  /bin/rm -rf -- "$RESET_DATA_DIR"
}

prepare_strict_git_continuity_control() {
  local control_root="${1:?missing continuity control root}"
  local origin_root="${control_root}.origin.git"
  case "$control_root" in
    "$RESET_DATA_DIR/"*) ;;
    *) echo "refusing continuity control outside isolated debug root" >&2; return 1 ;;
  esac
  [ ! -e "$control_root" ] || {
    echo "continuity control root already exists" >&2
    return 1
  }
  mkdir -p "$control_root"
  printf '%s\n' '.continuity-proof-ignored' >"$control_root/.gitignore"
  printf '%s\n' 'verified clean continuity baseline' >"$control_root/baseline.txt"
  /usr/bin/git -C "$control_root" init --quiet
  /usr/bin/git -C "$control_root" add .gitignore baseline.txt
  /usr/bin/git -C "$control_root" \
    -c commit.gpgsign=false \
    -c user.name='Agent Studio Performance Proof' \
    -c user.email='performance-proof@invalid.local' \
    commit --quiet -m 'establish continuity control baseline'
  /usr/bin/git clone --quiet --bare "$control_root" "$origin_root"
  /usr/bin/git -C "$control_root" remote add origin "$origin_root"
  /usr/bin/git -C "$control_root" push --quiet --set-upstream origin HEAD
  [ -z "$(/usr/bin/git -C "$control_root" status --porcelain=v1 --untracked-files=all)" ] || {
    echo "continuity control repository is not exactly clean" >&2
    return 1
  }
}

inject_strict_git_continuity_uncertainty() {
  local control_root="${1:?missing continuity control root}"
  local ignored_path="$control_root/.continuity-proof-ignored"
  [ ! -e "$ignored_path" ] || {
    echo "continuity uncertainty was already injected" >&2
    return 1
  }
  : >"$ignored_path"
  [ -z "$(/usr/bin/git -C "$control_root" status --porcelain=v1 --untracked-files=all)" ] || {
    echo "ignored continuity stimulus changed exact Git status" >&2
    return 1
  }
}

retire_current_candidate() {
  [ -s "$STATE_FILE" ] || return 0
  AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$STATE_FILE" \
    AGENTSTUDIO_DEBUG_DATA_DIR="$STRICT_DISPOSABLE_DATA_ROOT" \
    "$DEBUG_RUNNER" --retire-candidate
  APP_PID=""
  # IPC v2 retires escrow at shutdown (IPC escrow and startup diagnostics).
  if [ -n "${IPC_DEBUG_ESCROW_PATH:-}" ] && [ -e "$IPC_DEBUG_ESCROW_PATH" ]; then
    echo "debug IPC escrow was not retired at shutdown: AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW=$IPC_DEBUG_ESCROW_PATH" >&2
    return 1
  fi
}

validate_current_candidate() {
  AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$STATE_FILE" \
    AGENTSTUDIO_DEBUG_DATA_DIR="$STRICT_DISPOSABLE_DATA_ROOT" \
    "$DEBUG_RUNNER" --validate-candidate >/dev/null
}

cleanup() {
  stop_pid "${CPU_SAMPLER_PID:-}"
  stop_pid "${ZMX_MONITOR_PID:-}"
  if [ -f "$STATE_FILE" ] \
    && [ "$(decode_env_file_value "$STATE_FILE" AGENTSTUDIO_OBSERVABILITY_MARKER)" = "$TRACE_MARKER" ]; then
    retire_current_candidate || true
  fi

  if [ -n "$RESET_DATA_DIR" ]; then
    reset_disposable_debug_root || true
  fi
}

validate_no_debug_owned_helpers_json() {
  local records_json="${1:?missing process records}"
  local app_pid="${2:?missing app PID}"
  /usr/bin/python3 - "$records_json" "$app_pid" <<'PY'
import json
import sys

records = json.loads(sys.argv[1])
app_pid = int(sys.argv[2])
if not isinstance(records, list) or app_pid <= 0:
    raise SystemExit("invalid debug-owned process records or app PID")
records_by_pid = {}
children_by_parent = {}
for record in records:
    if not isinstance(record, dict):
        raise SystemExit("invalid debug-owned process record")
    try:
        pid = int(record["pid"])
        parent_pid = int(record["ppid"])
    except (KeyError, TypeError, ValueError):
        raise SystemExit("invalid debug-owned process identity") from None
    if pid <= 0 or parent_pid < 0:
        raise SystemExit("invalid debug-owned process identity")
    records_by_pid[pid] = record
    children_by_parent.setdefault(parent_pid, []).append(pid)
if app_pid not in records_by_pid:
    raise SystemExit("exact debug app PID is absent from process inventory")

descendants = []
pending = list(children_by_parent.get(app_pid, []))
while pending:
    pid = pending.pop()
    if pid in descendants:
        continue
    descendants.append(pid)
    pending.extend(children_by_parent.get(pid, []))
if descendants:
    first = records_by_pid[min(descendants)]
    command = first.get("command", "")
    raise SystemExit(f"debug-owned helper remains active: {first['pid']} {command}")
print("debug_owned_helper_contract=passed")
PY
}

validate_strict_descendant_poll_sequence() {
  local records_json="${1:?missing descendant poll sequence}"
  /usr/bin/python3 - "$records_json" <<'PY'
import json
import sys
records = json.loads(sys.argv[1])
if not isinstance(records, list) or not records:
    raise SystemExit("invalid descendant poll sequence")
for record in records:
    if not isinstance(record, dict) or not isinstance(record.get("descendant_count"), int):
        raise SystemExit("invalid descendant poll record")
    if record["descendant_count"] != 0:
        raise SystemExit("transient debug-owned descendant invalidated population")
print("descendant_poll_contract=passed")
PY
}

record_debug_owned_process_inventory() {
  local receipt_file="${1:?missing inventory receipt file}"
  local phase="${2:?missing inventory phase}"
  local descendant_pids first_descendant_pid first_descendant_command inventory_json pgrep_status=0
  descendant_pids="$(/usr/bin/pgrep -P "$APP_PID" . 2>/dev/null)" || pgrep_status=$?
  if [ "$pgrep_status" -gt 1 ]; then
    echo "failed to inspect exact debug app descendants" >&2
    return 1
  fi
  if [ -n "$descendant_pids" ]; then
    first_descendant_pid="$(printf '%s\n' "$descendant_pids" | head -1)"
    first_descendant_command="$(/bin/ps -p "$first_descendant_pid" -o command= 2>/dev/null || true)"
    echo "debug-owned helper remains active: $first_descendant_pid $first_descendant_command" >&2
    return 1
  fi
  inventory_json="$(/usr/bin/python3 - "$APP_PID" "$phase" <<'PY'
import json
import sys
app_pid = int(sys.argv[1])
phase = sys.argv[2]
print(json.dumps({"phase": phase, "app_pid": app_pid, "owned_pids": [app_pid], "descendant_count": 0}, separators=(",", ":")))
PY
  )"
  printf '%s\n' "$inventory_json" >>"$receipt_file"
}

validate_strict_zmx_state_contract() {
  local sequence_json="${1:?missing zmx state sequence}"
  /usr/bin/python3 - "$sequence_json" <<'PY'
import json
import sys

try:
    records = json.loads(sys.argv[1])
except json.JSONDecodeError as error:
    raise SystemExit(f"zmx state contract failed: {error}") from None
expected_phases = ["ready", "quiescent", "complete", "retired"]
if not isinstance(records, list) or [record.get("phase") for record in records] != expected_phases:
    raise SystemExit("zmx state contract failed: incomplete phases")
counts = []
for record in records:
    if record.get("list_error") is True:
        raise SystemExit("zmx state contract failed: list error")
    count = record.get("count")
    if not isinstance(count, int) or isinstance(count, bool) or count < 0 or count > 1:
        raise SystemExit("zmx state contract failed: invalid session count")
    if count == 1 and record.get("clients") != 1:
        raise SystemExit("zmx state contract failed: invalid client count")
    counts.append(count)
if counts == [0, 0, 0, 0]:
    pass
elif counts[0] == 0 and counts[1] == 1 and counts[2] in {0, 1} and counts[3] == 0:
    pass
else:
    raise SystemExit(f"zmx state contract failed: invalid transition {counts}")
print("zmx_state_contract=passed")
PY
}

validate_strict_workload_receipt_contract() {
  local receipt_json="${1:?missing workload receipt}"
  /usr/bin/python3 - "$receipt_json" <<'PY'
import json
import sys

try:
    receipt = json.loads(sys.argv[1])
except json.JSONDecodeError as error:
    raise SystemExit(f"workload receipt contract failed: {error}") from None
if not isinstance(receipt, dict):
    raise SystemExit("workload receipt contract failed: receipt is not an object")
baseline = receipt.get("baseline")
completion = receipt.get("completion")
if not isinstance(baseline, dict) or not isinstance(completion, dict):
    raise SystemExit("workload receipt contract failed: missing baseline or completion")
if receipt.get("dropped", 0) != 0 or baseline.get("dropped", 0) != 0 or completion.get("dropped", 0) != 0:
    raise SystemExit("workload receipt contract failed: dropped evidence")
for key in ("terminal_input", "terminal_output", "ordered_command"):
    before = baseline.get(key)
    after = completion.get(key)
    if not isinstance(before, int) or isinstance(before, bool) or before < 0:
        raise SystemExit(f"workload receipt contract failed: invalid baseline {key}")
    if not isinstance(after, int) or isinstance(after, bool) or after < before:
        raise SystemExit(f"workload receipt contract failed: reset completion {key}")
    if after != before:
        raise SystemExit(f"workload receipt contract failed: nonzero delta {key}")
print("workload_receipt_contract=passed")
PY
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

validate_controls() {
  validate_loopback_url AI_TOOLS_OBSERVABILITY_COLLECTOR_HEALTH_URL "$COLLECTOR_HEALTH_URL"
  validate_loopback_url AI_TOOLS_OBSERVABILITY_METRICS_QUERY_URL "$METRICS_QUERY_URL"
  if [ "${AGENTSTUDIO_OBSERVABILITY_ALLOW_TEST_OVERRIDES:-0}" = "1" ]; then
    return
  fi
  if [ "$(canonical_path "$STACK_HELPER")" != "$(canonical_path "$DEFAULT_STACK_HELPER")" ]; then
    echo "AI_TOOLS_OBSERVABILITY_STACK_HELPER must point to the trusted ai-tools helper: $DEFAULT_STACK_HELPER" >&2
    exit 2
  fi
}

validate_trace_name() {
  local trace_name="${1:?missing trace name}"
  case "$trace_name" in
    ""|"."|".."|*"/"*|*"\\"*|*".."*|*"*"*|*"?"*|*"["*|*"]"*|*"{"*|*"}"*|*[!A-Za-z0-9_.-]*)
      echo "AGENTSTUDIO_TRACE_NAME must be a safe path component: $trace_name" >&2
      exit 2
      ;;
  esac
  printf '%s\n' "$trace_name"
}

decode_env_file_value() {
  local state_file="${1:?missing state file}"
  local key="${2:?missing key}"
  local raw_value
  raw_value="$(sed -n "s/^$key=//p" "$state_file" | tail -1)"
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

metric_label_selector() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

opaque_trace_marker() {
  local trace_name="${1:?missing trace name}"
  local trace_nonce="${2:?missing trace nonce}"
  printf '%s:%s' "$trace_name" "$trace_nonce" | /usr/bin/shasum -a 256 | awk '{ print "sidebar-" substr($1, 1, 24) }'
}

hashed_identity() {
  local value="${1:?missing identity value}"
  printf '%s' "$value" | /usr/bin/shasum -a 256 | awk '{ print substr($1, 1, 24) }'
}

validate_workload_cycles() {
  /usr/bin/python3 - "$WORKLOAD_CYCLES" "$REQUIRED_SAMPLE_COUNT" <<'PY'
import sys

try:
    cycles = int(sys.argv[1])
    minimum = int(sys.argv[2])
except ValueError:
    print("AGENTSTUDIO_SIDEBAR_IPC_CYCLES must be an integer", file=sys.stderr)
    raise SystemExit(2)
if cycles < minimum:
    print(f"AGENTSTUDIO_SIDEBAR_IPC_CYCLES must be >= {minimum}: {cycles}", file=sys.stderr)
    raise SystemExit(2)
PY
}

query_victoria_metrics() {
  local query="$1"
  local evaluation_time="${2:-}"
  if [ "${AGENTSTUDIO_SIDEBAR_ALLOW_TEST_RESPONSES:-0}" = "1" ]; then
    if [ "$mode" != "prepare-only" ]; then
      echo "canned sidebar metrics responses are allowed only with --prepare-only" >&2
      exit 2
    fi
    printf '%s\n' "${AGENTSTUDIO_SIDEBAR_TEST_METRICS_RESPONSE:-}"
    return 0
  fi
  if [ -n "$evaluation_time" ]; then
    /usr/bin/curl --fail --silent --show-error --max-time 10 --get \
      --data-urlencode "query=$query" \
      --data-urlencode "time=$evaluation_time" \
      "$METRICS_QUERY_URL"
  else
    /usr/bin/curl --fail --silent --show-error --max-time 10 --get \
      --data-urlencode "query=$query" \
      "$METRICS_QUERY_URL"
  fi
}

strict_sidebar_policy_query() {
  printf '%s' '{service.name="AgentStudio",dev.runtime.flavor="debug"} _msg:app.startup_diagnostic.sidebar_proof.policy_projected agent.proof.marker:"'"$TRACE_MARKER"'" | fields agentstudio.startup_diagnostic.sidebar_proof.policy_id,agentstudio.startup_diagnostic.sidebar_proof.policy_version,agentstudio.startup_diagnostic.sidebar_proof.standard_trace_tags,agentstudio.startup_diagnostic.sidebar_proof.diagnostic_trace_tags,agentstudio.startup_diagnostic.sidebar_proof.idle_populations,agentstudio.startup_diagnostic.sidebar_proof.action_populations,agentstudio.startup_diagnostic.sidebar_proof.idle_p99_max_percent,agentstudio.startup_diagnostic.sidebar_proof.action_p95_max_percent,agentstudio.startup_diagnostic.sidebar_proof.sample_interval_ms,agentstudio.startup_diagnostic.sidebar_proof.metrics_export_interval_ms,agentstudio.startup_diagnostic.sidebar_proof.idle_sample_floor,agentstudio.startup_diagnostic.sidebar_proof.action_count_floor,agentstudio.startup_diagnostic.sidebar_proof.action_sample_floor,agentstudio.startup_diagnostic.sidebar_proof.fixture_preparation_timeout_ms,agentstudio.startup_diagnostic.sidebar_proof.fixture_state_observation_interval_ms,agentstudio.startup_diagnostic.sidebar_proof.fixture_tab_count,agentstudio.startup_diagnostic.sidebar_proof.fixture_pane_model_count,agentstudio.startup_diagnostic.sidebar_proof.zero_pty_expected_session_count,agentstudio.startup_diagnostic.sidebar_proof.zmx_inventory_interval_ms,agentstudio.startup_diagnostic.sidebar_proof.search_character_count,agentstudio.startup_diagnostic.sidebar_proof.search_character_interval_ms,agentstudio.startup_diagnostic.sidebar_proof.quiescence_interval_ms,agentstudio.startup_diagnostic.sidebar_proof.readback_timeout_ms,agentstudio.startup_diagnostic.sidebar_proof.sampler_gap_max_ms,agentstudio.startup_diagnostic.sidebar_proof.action_sample_boundary_offset_ms,agentstudio.startup_diagnostic.sidebar_proof.action_sample_start_offset_ms,agentstudio.startup_diagnostic.sidebar_proof.diagnostic_cpu_delta_max_points,agentstudio.startup_diagnostic.sidebar_proof.diagnostic_interaction_growth_max_percent,agentstudio.startup_diagnostic.sidebar_proof.git_status_physical_limit,agentstudio.startup_diagnostic.sidebar_proof.remote_reference_physical_limit,agentstudio.startup_diagnostic.sidebar_proof.forge_physical_limit,agentstudio.startup_diagnostic.sidebar_proof.git_maximum_settlement_ms | limit 1'
}

load_strict_sidebar_policy() {
  local policy_file="${1:?missing policy output file}"
  local query response
  query="$(strict_sidebar_policy_query)"
  for _ in $(seq 1 30); do
    response="$(curl --silent --show-error --max-time 5 "$LOGS_QUERY_URL" --data-urlencode "query=$query")"
    if [ -n "$response" ]; then
      printf '%s\n' "$response" >"$policy_file"
      return 0
    fi
    /bin/sleep 1
  done
  echo "strict sidebar policy did not become queryable for marker $TRACE_MARKER" >&2
  return 1
}

# S12 establishes the descriptor-driven driver/readback protocol. S13 owns
# execution and final acceptance for these six independent populations.
positive_quiescence() {
  local unchanged_seconds="${1:?missing unchanged-second count}"
  [ "$unchanged_seconds" -ge 5 ]
}

monotonic_now_ms() {
  /usr/bin/perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
    -e 'printf "%d\n", clock_gettime(CLOCK_MONOTONIC) * 1000'
}

monotonic_now_ns() {
  /usr/bin/perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
    -e 'printf "%.0f\n", clock_gettime(CLOCK_MONOTONIC) * 1000000000'
}

parse_strict_sidebar_policy() {
  local policy_file="${1:?missing policy file}"
  local environment_file="${2:?missing policy environment file}"
  /usr/bin/python3 - "$policy_file" "$environment_file" <<'PY'
import json, math, pathlib, shlex, sys
records = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()]
if len(records) != 1:
    raise SystemExit(f"strict policy requires exactly one record, got {len(records)}")
record = records[0]
prefix = "agentstudio.startup_diagnostic.sidebar_proof."
mapping = {
    "STRICT_POLICY_ID": "policy_id",
    "STRICT_POLICY_VERSION": "policy_version",
    "STRICT_POLICY_IDLE_P99": "idle_p99_max_percent",
    "STRICT_POLICY_ACTION_P95": "action_p95_max_percent",
    "STRICT_POLICY_SAMPLE_INTERVAL_MS": "sample_interval_ms",
    "STRICT_POLICY_METRICS_EXPORT_INTERVAL_MS": "metrics_export_interval_ms",
    "STRICT_POLICY_IDLE_SAMPLE_FLOOR": "idle_sample_floor",
    "STRICT_POLICY_ACTION_COUNT_FLOOR": "action_count_floor",
    "STRICT_POLICY_ACTION_SAMPLE_FLOOR": "action_sample_floor",
    "STRICT_POLICY_FIXTURE_PREPARATION_TIMEOUT_MS": "fixture_preparation_timeout_ms",
    "STRICT_POLICY_FIXTURE_STATE_OBSERVATION_INTERVAL_MS": "fixture_state_observation_interval_ms",
    "STRICT_POLICY_FIXTURE_TAB_COUNT": "fixture_tab_count",
    "STRICT_POLICY_FIXTURE_PANE_MODEL_COUNT": "fixture_pane_model_count",
    "STRICT_POLICY_ZERO_PTY_SESSION_COUNT": "zero_pty_expected_session_count",
    "STRICT_POLICY_ZMX_INVENTORY_INTERVAL_MS": "zmx_inventory_interval_ms",
    "STRICT_POLICY_QUIESCENCE_MS": "quiescence_interval_ms",
    "STRICT_POLICY_READBACK_TIMEOUT_MS": "readback_timeout_ms",
    "STRICT_POLICY_MAXIMUM_SAMPLER_GAP_MS": "sampler_gap_max_ms",
    "STRICT_POLICY_ACTION_SAMPLE_BOUNDARY_OFFSET_MS": "action_sample_boundary_offset_ms",
    "STRICT_POLICY_ACTION_SAMPLE_START_OFFSET_MS": "action_sample_start_offset_ms",
    "STRICT_POLICY_DIAGNOSTIC_CPU_DELTA_MAX": "diagnostic_cpu_delta_max_points",
    "STRICT_POLICY_DIAGNOSTIC_INTERACTION_GROWTH_MAX": "diagnostic_interaction_growth_max_percent",
    "STRICT_POLICY_GIT_STATUS_PHYSICAL_LIMIT": "git_status_physical_limit",
    "STRICT_POLICY_REMOTE_REFERENCE_PHYSICAL_LIMIT": "remote_reference_physical_limit",
    "STRICT_POLICY_FORGE_PHYSICAL_LIMIT": "forge_physical_limit",
    "STRICT_POLICY_GIT_MAXIMUM_SETTLEMENT_MS": "git_maximum_settlement_ms",
    "STRICT_POLICY_STANDARD_TRACE_TAGS": "standard_trace_tags",
    "STRICT_POLICY_DIAGNOSTIC_TRACE_TAGS": "diagnostic_trace_tags",
    "STRICT_POLICY_IDLE_POPULATIONS": "idle_populations",
    "STRICT_POLICY_ACTION_POPULATIONS": "action_populations",
}
values = {}
for variable, suffix in mapping.items():
    value = record.get(prefix + suffix)
    if value is None:
        raise SystemExit(f"strict policy missing {suffix}")
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    elif isinstance(value, str):
        try:
            numeric_value = float(value)
        except ValueError:
            pass
        else:
            if math.isfinite(numeric_value) and numeric_value.is_integer():
                value = int(numeric_value)
    values[variable] = str(value)
values["STRICT_POLICY_IDLE_POPULATIONS"] = values["STRICT_POLICY_IDLE_POPULATIONS"].replace(",", " ")
values["STRICT_POLICY_ACTION_POPULATIONS"] = values["STRICT_POLICY_ACTION_POPULATIONS"].replace(",", " ")
pathlib.Path(sys.argv[2]).write_text("".join(f"{key}={shlex.quote(value)}\n" for key, value in values.items()))
PY
}

strict_sidebar_fixture_ready_query() {
  printf '%s' '{service.name="AgentStudio",dev.runtime.flavor="debug"} _msg:app.startup_diagnostic.sidebar_proof.fixture_ready agent.proof.marker:"'"$TRACE_MARKER"'" | fields agentstudio.startup_diagnostic.sidebar_proof.open_source_root_present,agentstudio.startup_diagnostic.sidebar_proof.project_dev_root_present,agentstudio.startup_diagnostic.sidebar_proof.control_root_present,agentstudio.startup_diagnostic.sidebar_proof.discovered_repository_count,agentstudio.startup_diagnostic.sidebar_proof.discovered_worktree_count,agentstudio.startup_diagnostic.sidebar_proof.warm_repository_count,agentstudio.startup_diagnostic.sidebar_proof.inactive_repository_count,agentstudio.startup_diagnostic.sidebar_proof.unknown_repository_count,agentstudio.startup_diagnostic.sidebar_proof.warm_worktree_count,agentstudio.startup_diagnostic.sidebar_proof.inactive_worktree_count,agentstudio.startup_diagnostic.sidebar_proof.unknown_worktree_count,agentstudio.startup_diagnostic.sidebar_proof.cold_automatic_deadline_count,agentstudio.startup_diagnostic.sidebar_proof.cold_local_automatic_source_start_count,agentstudio.startup_diagnostic.sidebar_proof.cold_fsevent_local_completion_count,agentstudio.startup_diagnostic.sidebar_proof.explicit_source_admitted_count,agentstudio.startup_diagnostic.sidebar_proof.explicit_source_terminal_count,agentstudio.startup_diagnostic.sidebar_proof.explicit_progress_settled_count,agentstudio.startup_diagnostic.sidebar_proof.explicit_local_admitted_count,agentstudio.startup_diagnostic.sidebar_proof.explicit_remote_admitted_count,agentstudio.startup_diagnostic.sidebar_proof.explicit_forge_admitted_count,agentstudio.startup_diagnostic.sidebar_proof.topology_fingerprint,agentstudio.startup_diagnostic.sidebar_proof.tab_count,agentstudio.startup_diagnostic.sidebar_proof.pane_model_count,agentstudio.startup_diagnostic.sidebar_proof.expected_session_variant | limit 1'
}

strict_sidebar_fixture_blocked_query() {
  printf '%s' '{service.name="AgentStudio",dev.runtime.flavor="debug"} _msg:app.startup_diagnostic_action.blocked agent.proof.marker:"'"$TRACE_MARKER"'" | fields agentstudio.startup_diagnostic.skip_reason | limit 1'
}

report_strict_sidebar_fixture_blocked() {
  local response="${1:?missing blocked fixture response}"
  local reason
  reason="$(/usr/bin/python3 - "$response" <<'PY'
import json
import sys

records = [json.loads(line) for line in sys.argv[1].splitlines() if line.strip()]
if len(records) != 1:
    raise SystemExit(f"strict fixture blocked response requires exactly one record, got {len(records)}")
reason = records[0].get("agentstudio.startup_diagnostic.skip_reason")
if not isinstance(reason, str) or not reason:
    raise SystemExit("strict fixture blocked response is missing its reason")
print(reason)
PY
  )"
  echo "strict sidebar fixture blocked for marker $TRACE_MARKER: $reason" >&2
  return 1
}

load_strict_sidebar_fixture_ready() {
  local fixture_file="${1:?missing fixture output file}"
  local blocked_query blocked_response timeout_seconds response query
  timeout_seconds="$(/usr/bin/python3 -c 'import sys; print(max(1, int(float(sys.argv[1]) / 1000)))' \
    "$STRICT_POLICY_FIXTURE_PREPARATION_TIMEOUT_MS")"
  query="$(strict_sidebar_fixture_ready_query)"
  blocked_query="$(strict_sidebar_fixture_blocked_query)"
  for _ in $(seq 1 "$timeout_seconds"); do
    response="$(curl --silent --show-error --max-time 5 "$LOGS_QUERY_URL" --data-urlencode "query=$query")"
    if [ -n "$response" ]; then
      printf '%s\n' "$response" >"$fixture_file"
      return 0
    fi
    blocked_response="$(curl --silent --show-error --max-time 5 "$LOGS_QUERY_URL" \
      --data-urlencode "query=$blocked_query")"
    if [ -n "$blocked_response" ]; then
      report_strict_sidebar_fixture_blocked "$blocked_response"
      return 1
    fi
    /bin/sleep 1
  done
  echo "strict sidebar fixture did not become ready for marker $TRACE_MARKER" >&2
  return 1
}

validate_and_bind_strict_sidebar_fixture() {
  local fixture_file="${1:?missing fixture file}"
  local population="${2:?missing population}"
  local fixture_environment="${3:?missing fixture environment}"
  /usr/bin/python3 - "$fixture_file" "$population" "$STRICT_POLICY_FIXTURE_TAB_COUNT" \
    "$STRICT_POLICY_FIXTURE_PANE_MODEL_COUNT" "$STRICT_POLICY_ZERO_PTY_SESSION_COUNT" \
    "$fixture_environment" <<'PY'
import json
import pathlib
import shlex
import sys

path, population, raw_tabs, raw_panes, raw_zero, output = sys.argv[1:]
records = [json.loads(line) for line in pathlib.Path(path).read_text().splitlines() if line.strip()]
if len(records) != 1:
    raise SystemExit(f"strict fixture requires exactly one record, got {len(records)}")
record = records[0]
prefix = "agentstudio.startup_diagnostic.sidebar_proof."
def exact_true(name):
    raw = record.get(prefix + name)
    return raw is True or raw == "true"
if not exact_true("open_source_root_present"):
    raise SystemExit("strict fixture missing open-source root")
if not exact_true("project_dev_root_present"):
    raise SystemExit("strict fixture missing project-dev root")
if not exact_true("control_root_present"):
    raise SystemExit("strict fixture missing isolated continuity control root")
def exact_int(name):
    raw = record.get(prefix + name)
    try:
        value = int(float(raw))
    except (TypeError, ValueError):
        raise SystemExit(f"strict fixture invalid {name}") from None
    if float(raw) != value:
        raise SystemExit(f"strict fixture nonintegral {name}")
    return value
repository_count = exact_int("discovered_repository_count")
worktree_count = exact_int("discovered_worktree_count")
warm_repository_count = exact_int("warm_repository_count")
inactive_repository_count = exact_int("inactive_repository_count")
unknown_repository_count = exact_int("unknown_repository_count")
warm_worktree_count = exact_int("warm_worktree_count")
inactive_worktree_count = exact_int("inactive_worktree_count")
unknown_worktree_count = exact_int("unknown_worktree_count")
cold_automatic_deadline_count = exact_int("cold_automatic_deadline_count")
cold_local_automatic_source_start_count = exact_int("cold_local_automatic_source_start_count")
cold_fsevent_local_completion_count = exact_int("cold_fsevent_local_completion_count")
explicit_source_admitted_count = exact_int("explicit_source_admitted_count")
explicit_source_terminal_count = exact_int("explicit_source_terminal_count")
explicit_progress_settled_count = exact_int("explicit_progress_settled_count")
explicit_local_admitted_count = exact_int("explicit_local_admitted_count")
explicit_remote_admitted_count = exact_int("explicit_remote_admitted_count")
explicit_forge_admitted_count = exact_int("explicit_forge_admitted_count")
tab_count = exact_int("tab_count")
pane_count = exact_int("pane_model_count")
session_variant = exact_int("expected_session_variant")
fingerprint = record.get(prefix + "topology_fingerprint")
if repository_count <= 0 or worktree_count <= 0:
    raise SystemExit("strict fixture discovery counts must be positive")
if warm_repository_count <= 0 or inactive_repository_count <= 0:
    raise SystemExit("strict fixture requires positive warm and inactive repository counts")
if warm_worktree_count <= 0 or inactive_worktree_count <= 0:
    raise SystemExit("strict fixture requires positive warm and inactive worktree counts")
if unknown_repository_count <= 0 or unknown_worktree_count <= 0:
    raise SystemExit("strict fixture requires positive unknown membership")
if cold_automatic_deadline_count != 0 or cold_local_automatic_source_start_count != 0:
    raise SystemExit("strict fixture contains cold automatic work")
if cold_fsevent_local_completion_count != 1:
    raise SystemExit("strict fixture did not prove one cold FSEvent local completion")
if explicit_source_admitted_count != 1 or explicit_source_terminal_count != 1:
    raise SystemExit("strict fixture did not prove one remote-only explicit source settlement")
if explicit_progress_settled_count != 1:
    raise SystemExit("strict fixture did not prove one settled composite progress lifetime")
if (explicit_local_admitted_count, explicit_remote_admitted_count, explicit_forge_admitted_count) != (0, 1, 0):
    raise SystemExit("strict fixture explicit source admission is not remote-only")
if tab_count != int(float(raw_tabs)) or pane_count != int(float(raw_panes)):
    raise SystemExit(f"strict fixture expected 5/20-compatible policy counts, got {tab_count}/{pane_count}")
expected_sessions = int(float(raw_zero))
if session_variant != expected_sessions:
    raise SystemExit("strict fixture session variant mismatch")
if not isinstance(fingerprint, str) or len(fingerprint) != 64:
    raise SystemExit("strict fixture topology fingerprint is missing or malformed")
values = {
    "STRICT_FIXTURE_REPOSITORY_COUNT": repository_count,
    "STRICT_FIXTURE_WORKTREE_COUNT": worktree_count,
    "STRICT_FIXTURE_WARM_REPOSITORY_COUNT": warm_repository_count,
    "STRICT_FIXTURE_INACTIVE_REPOSITORY_COUNT": inactive_repository_count,
    "STRICT_FIXTURE_UNKNOWN_REPOSITORY_COUNT": unknown_repository_count,
    "STRICT_FIXTURE_WARM_WORKTREE_COUNT": warm_worktree_count,
    "STRICT_FIXTURE_INACTIVE_WORKTREE_COUNT": inactive_worktree_count,
    "STRICT_FIXTURE_UNKNOWN_WORKTREE_COUNT": unknown_worktree_count,
    "STRICT_FIXTURE_TAB_COUNT": tab_count,
    "STRICT_FIXTURE_PANE_COUNT": pane_count,
    "STRICT_FIXTURE_EXPECTED_SESSION_COUNT": expected_sessions,
    "STRICT_FIXTURE_TOPOLOGY_FINGERPRINT": fingerprint,
}

pathlib.Path(output).write_text(
    "".join(f"{key}={shlex.quote(str(value))}\n" for key, value in values.items())
)
PY
  # shellcheck disable=SC1090
  source "$fixture_environment"
  if [ -z "${STRICT_EXPECTED_TOPOLOGY_FINGERPRINT:-}" ]; then
    STRICT_EXPECTED_TOPOLOGY_FINGERPRINT="$STRICT_FIXTURE_TOPOLOGY_FINGERPRINT"
    STRICT_EXPECTED_REPOSITORY_COUNT="$STRICT_FIXTURE_REPOSITORY_COUNT"
    STRICT_EXPECTED_WORKTREE_COUNT="$STRICT_FIXTURE_WORKTREE_COUNT"
  elif [ "$STRICT_FIXTURE_TOPOLOGY_FINGERPRINT" != "$STRICT_EXPECTED_TOPOLOGY_FINGERPRINT" ] ||
    [ "$STRICT_FIXTURE_REPOSITORY_COUNT" != "$STRICT_EXPECTED_REPOSITORY_COUNT" ] ||
    [ "$STRICT_FIXTURE_WORKTREE_COUNT" != "$STRICT_EXPECTED_WORKTREE_COUNT" ]; then
    echo "strict fixture topology drifted across populations" >&2
    return 1
  fi
}

validate_strict_repository_update_telemetry() {
  local output="${1:?missing repository update telemetry output}"
  local query response
  query='{service.name="AgentStudio",dev.runtime.flavor="debug"} agent.proof.marker:"'"$TRACE_MARKER"'" _msg:performance.repository_fact_update | fields agentstudio.performance.repository_update.stage,agentstudio.performance.repository_update.outcome,agentstudio.performance.repository_update.applicable_source.count,agentstudio.performance.repository_update.unsettled_source.count,agentstudio.performance.repository_update.terminal_source.count | limit 20'
  for _ in $(seq 1 30); do
    response="$(curl --silent --show-error --max-time 5 "$LOGS_QUERY_URL" --data-urlencode "query=$query")"
    if printf '%s\n' "$response" | grep -q 'partial_failure\|complete'; then
      printf '%s\n' "$response" >"$output"
      break
    fi
    /bin/sleep 1
  done
  /usr/bin/python3 - "$output" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
if not path.exists():
    raise SystemExit("repository update telemetry did not become queryable")
records = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
prefix = "agentstudio.performance.repository_update."
by_stage = {record.get(prefix + "stage"): record for record in records}
if set(by_stage) != {"captured", "admitted", "settled"}:
    raise SystemExit("repository update telemetry stage sequence is incomplete")
if by_stage["admitted"].get(prefix + "outcome") != "loading":
    raise SystemExit("repository update telemetry lacks admitted loading lifetime")
if by_stage["settled"].get(prefix + "outcome") not in {
    "complete", "partial_failure", "failed", "cancelled", "obsolete", "mixed_terminal"
}:
    raise SystemExit("repository update telemetry lacks bounded terminal outcome")
PY
}

load_and_bind_strict_sidebar_policy() {
  local population_artifact="${1:?missing population artifact}"
  local projected_policy="$population_artifact/projected-policy.jsonl"
  local projected_environment="$population_artifact/projected-policy.env"
  load_strict_sidebar_policy "$projected_policy"
  parse_strict_sidebar_policy "$projected_policy" "$projected_environment"
  if [ ! -f "$ARTIFACT/strict-sidebar-policy.env" ]; then
    cp "$projected_environment" "$ARTIFACT/strict-sidebar-policy.env"
    cp "$projected_policy" "$ARTIFACT/strict-sidebar-policy.jsonl"
  elif ! cmp -s "$projected_environment" "$ARTIFACT/strict-sidebar-policy.env"; then
    echo "strict sidebar policy drifted across populations" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "$projected_environment"
}

nearest_rank_percentile() {
  local samples_file="${1:?missing samples file}"
  local percentile="${2:?missing percentile}"
  /usr/bin/python3 - "$samples_file" "$percentile" <<'PY'
import math, pathlib, sys
values = sorted(float(line.split()[-1]) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip())
if not values: raise SystemExit("population has no usable samples")
rank = max(1, math.ceil(len(values) * float(sys.argv[2])))
print(values[rank - 1])
PY
}

strict_zmx_inventory_json() {
  local phase="${1:?missing zmx inventory phase}"
  local data_dir zmx_dir zmx_bin inventory
  if [ -s "$STATE_FILE" ]; then
    data_dir="$(decode_env_file_value "$STATE_FILE" AGENTSTUDIO_OBSERVABILITY_DATA_DIR)"
  else
    data_dir="$RESET_DATA_DIR"
  fi
  zmx_dir="$data_dir/z"
  zmx_bin="$data_dir/bin/zmx"
  if [ ! -d "$zmx_dir" ]; then
    printf '{"phase":"%s","count":0}\n' "$phase"
    return 0
  fi
  if ! inventory="$("$PROJECT_ROOT/scripts/cleanup-debug-zmx-sessions.sh" \
    --inventory-exact-root "$zmx_dir" --zmx-bin "$zmx_bin")"; then
    printf '{"phase":"%s","list_error":true}\n' "$phase"
    return 1
  fi
  /usr/bin/python3 - "$phase" "$inventory" <<'PY'
import json
import re
import sys

phase, inventory = sys.argv[1:]
header = re.search(r"session_count=(\d+)", inventory)
if header is None:
    raise SystemExit("zmx inventory missing session count")
count = int(header.group(1))
sessions = []
for line in inventory.splitlines():
    match = re.fullmatch(r"session=(\S+) clients=(\d+) start_dir=(.+)", line)
    if match:
        sessions.append((match.group(1), int(match.group(2)), match.group(3)))
if len(sessions) != count or len({name for name, _, _ in sessions}) != len(sessions):
    raise SystemExit("zmx inventory session rows are incomplete or duplicated")
record = {"phase": phase, "count": count}
if count == 1:
    record["clients"] = sessions[0][1]
print(json.dumps(record, separators=(",", ":")))
PY
}

record_strict_zmx_inventory() {
  local population="${1:?missing population}"
  local phase="${2:?missing zmx inventory phase}"
  local population_artifact="$ARTIFACT/populations/$population"
  local receipt
  if ! receipt="$(strict_zmx_inventory_json "$phase")"; then
    printf '%s\n' "$receipt" >>"$population_artifact/zmx-lifecycle.jsonl"
    return 1
  fi
  printf '%s\n' "$receipt" >>"$population_artifact/zmx-lifecycle.jsonl"
  /usr/bin/python3 - "$receipt" "$STRICT_FIXTURE_EXPECTED_SESSION_COUNT" <<'PY'
import json
import sys

record = json.loads(sys.argv[1])
expected = int(float(sys.argv[2]))
count = record.get("count")
if not isinstance(count, int) or count < 0 or count > expected:
    raise SystemExit("zmx inventory exceeds population contract")
if count == 1 and record.get("clients") != 1:
    raise SystemExit("zmx inventory has unexpected client count")
PY
}

start_strict_zmx_monitor() {
  local population="${1:?missing population}"
  local population_artifact="$ARTIFACT/populations/$population"
  local stop_file="$population_artifact/stop-zmx-monitor"
  local invalid_file="$population_artifact/zmx-invalid.env"
  local interval_seconds
  interval_seconds="$(/usr/bin/python3 -c 'import sys; print(float(sys.argv[1]) / 1000)' \
    "$STRICT_POLICY_ZMX_INVENTORY_INTERVAL_MS")"
  /bin/rm -f -- "$stop_file" "$invalid_file"
  : >"$population_artifact/zmx-monitor.jsonl"
  (
    while [ ! -f "$stop_file" ]; do
      local receipt
      if ! receipt="$(strict_zmx_inventory_json during)"; then
        printf '%s\n' "$receipt" >>"$population_artifact/zmx-monitor.jsonl"
        echo "population_invalidated=zmx_inventory" >"$invalid_file"
        exit 1
      fi
      printf '%s\n' "$receipt" >>"$population_artifact/zmx-monitor.jsonl"
      if ! /usr/bin/python3 - "$receipt" "$STRICT_FIXTURE_EXPECTED_SESSION_COUNT" <<'PY'
import json
import sys
record = json.loads(sys.argv[1])
expected = int(float(sys.argv[2]))
count = record.get("count")
raise SystemExit(0 if isinstance(count, int) and 0 <= count <= expected and (count == 0 or record.get("clients") == 1) else 1)
PY
      then
        echo "population_invalidated=zmx_inventory" >"$invalid_file"
        exit 1
      fi
      /bin/sleep "$interval_seconds"
    done
  ) &
  ZMX_MONITOR_PID=$!
}

stop_strict_zmx_monitor() {
  local population="${1:?missing population}"
  local population_artifact="$ARTIFACT/populations/$population"
  local monitor_failed=0
  : >"$population_artifact/stop-zmx-monitor"
  if [ -n "${ZMX_MONITOR_PID:-}" ]; then
    wait "$ZMX_MONITOR_PID" || monitor_failed=1
    ZMX_MONITOR_PID=""
  fi
  [ ! -s "$population_artifact/zmx-invalid.env" ] || monitor_failed=1
  [ "$monitor_failed" = "0" ]
}

sample_strict_process_cpu() {
  local samples="${1:?missing CPU samples file}"
  local stop_file="${2:?missing CPU sampler stop file}"
  local sample_interval_seconds
  sample_interval_seconds="$(/usr/bin/python3 -c 'import sys; print(float(sys.argv[1])/1000)' \
    "$STRICT_POLICY_SAMPLE_INTERVAL_MS")"
  /usr/bin/python3 - "$APP_PID" "$sample_interval_seconds" "$stop_file" \
    "$STRICT_POLICY_ACTION_SAMPLE_BOUNDARY_OFFSET_MS" >>"$samples" <<'PY'
import ctypes
import math
import subprocess
import sys
import time

PROC_PIDTASKINFO = 4

class ProcTaskInfo(ctypes.Structure):
    _fields_ = [
        ("pti_virtual_size", ctypes.c_uint64),
        ("pti_resident_size", ctypes.c_uint64),
        ("pti_total_user", ctypes.c_uint64),
        ("pti_total_system", ctypes.c_uint64),
        ("pti_threads_user", ctypes.c_uint64),
        ("pti_threads_system", ctypes.c_uint64),
        ("pti_policy", ctypes.c_int32),
        ("pti_faults", ctypes.c_int32),
        ("pti_pageins", ctypes.c_int32),
        ("pti_cow_faults", ctypes.c_int32),
        ("pti_messages_sent", ctypes.c_int32),
        ("pti_messages_received", ctypes.c_int32),
        ("pti_syscalls_mach", ctypes.c_int32),
        ("pti_syscalls_unix", ctypes.c_int32),
        ("pti_csw", ctypes.c_int32),
        ("pti_threadnum", ctypes.c_int32),
        ("pti_numrunning", ctypes.c_int32),
        ("pti_priority", ctypes.c_int32),
    ]

pid = int(sys.argv[1])
interval_seconds = float(sys.argv[2])
stop_file = sys.argv[3]
maximum_phase_offset_ns = float(sys.argv[4]) * 1_000_000
if pid <= 0 or not math.isfinite(interval_seconds) or interval_seconds <= 0:
    raise SystemExit("invalid exact-process CPU sample input")

libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
libproc.proc_pidinfo.argtypes = [
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_uint64,
    ctypes.c_void_p,
    ctypes.c_int,
]
libproc.proc_pidinfo.restype = ctypes.c_int

def total_process_cpu_nanoseconds(process_id, required=False):
    info = ProcTaskInfo()
    size = ctypes.sizeof(info)
    result = libproc.proc_pidinfo(process_id, PROC_PIDTASKINFO, 0, ctypes.byref(info), size)
    if result != size:
        if required:
            raise SystemExit("exact debug process task info is unavailable")
        return None
    return int(info.pti_total_user + info.pti_total_system)

def debug_owned_process_ids():
    owned = {pid}
    pending = [pid]
    while pending:
        parent = pending.pop()
        result = subprocess.run(
            ["/usr/bin/pgrep", "-P", str(parent)],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode not in (0, 1):
            raise SystemExit("debug-owned PID lineage is unavailable")
        for raw_child in result.stdout.split():
            child = int(raw_child)
            if child > 0 and child not in owned:
                owned.add(child)
                pending.append(child)
    return owned

interval_ns = int(interval_seconds * 1_000_000_000)
now_ns = time.monotonic_ns()
next_phase_ns = ((now_ns // interval_ns) + 1) * interval_ns
time.sleep(max(0, next_phase_ns - now_ns) / 1_000_000_000)
while not __import__("os").path.exists(stop_file):
    now_ns = time.monotonic_ns()
    time.sleep(max(0, next_phase_ns - now_ns) / 1_000_000_000)
    started_ns = time.monotonic_ns()
    if started_ns - next_phase_ns > maximum_phase_offset_ns:
        raise SystemExit("continuous sampler missed absolute phase envelope")
    before_cpu_by_pid = {
        process_id: total_process_cpu_nanoseconds(process_id, required=process_id == pid)
        for process_id in debug_owned_process_ids()
    }
    deadline_ns = next_phase_ns + interval_ns
    while time.monotonic_ns() < deadline_ns:
        descendants = debug_owned_process_ids() - {pid}
        if descendants:
            raise SystemExit("transient debug-owned descendant invalidated population")
        remaining_seconds = max(0, deadline_ns - time.monotonic_ns()) / 1_000_000_000
        time.sleep(min(0.05, remaining_seconds))
    after_cpu_by_pid = {
        process_id: total_process_cpu_nanoseconds(process_id, required=process_id == pid)
        for process_id in debug_owned_process_ids()
    }
    ended_ns = time.monotonic_ns()
    wall_delta_ns = ended_ns - started_ns
    cpu_delta_ns = 0
    for process_id, after_cpu_ns in after_cpu_by_pid.items():
        if after_cpu_ns is None:
            continue
        before_cpu_ns = before_cpu_by_pid.get(process_id)
        cpu_delta_ns += after_cpu_ns if before_cpu_ns is None else max(0, after_cpu_ns - before_cpu_ns)
    if wall_delta_ns <= 0 or cpu_delta_ns < 0:
        raise SystemExit("invalid exact-process CPU time delta")
    cpu_percent = cpu_delta_ns / wall_delta_ns * 100.0
    print(f"{started_ns} {ended_ns} {cpu_percent:.6f}", flush=True)
    next_phase_ns += interval_ns
PY
}

validate_strict_sampler_gaps() {
  local samples="${1:?missing samples file}"
  /usr/bin/python3 - "$samples" "$STRICT_POLICY_MAXIMUM_SAMPLER_GAP_MS" \
    "$STRICT_POLICY_SAMPLE_INTERVAL_MS" "$STRICT_POLICY_ACTION_SAMPLE_BOUNDARY_OFFSET_MS" <<'PY'
import pathlib, sys

timestamps = [int(line.split()[0]) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()]
maximum_gap_ns = float(sys.argv[2]) * 1_000_000
sample_interval_ns = float(sys.argv[3]) * 1_000_000
maximum_phase_offset_ns = float(sys.argv[4]) * 1_000_000
for prior, current in zip(timestamps, timestamps[1:]):
    if current <= prior or current - prior > maximum_gap_ns:
        raise SystemExit(f"sampler_gap={current - prior}")
for timestamp in timestamps:
    if timestamp % sample_interval_ns > maximum_phase_offset_ns:
        raise SystemExit("continuous sampler drifted outside absolute phase envelope")
PY
}

start_strict_action_sampler() {
  local population="${1:?missing population}"
  local population_artifact="$ARTIFACT/populations/$population"
  local raw_samples="$population_artifact/cpu.raw.samples"
  local stop_file="$population_artifact/stop-sampler"
  : >"$raw_samples"
  /bin/rm -f -- "$stop_file"
  sample_strict_process_cpu "$raw_samples" "$stop_file" &
  CPU_SAMPLER_PID=$!
}

validate_strict_zero_loss() {
  local summary="${1:?missing population summary}"
  grep -q '^trace_queue_dropped_record_count=0$' "$summary"
  grep -q '^runtime_delivery_dropped_count=0$' "$summary"
  grep -q '^collector_loss_count=0$' "$summary"
}

capture_strict_population_loss() {
  local summary="${1:?missing population summary}"
  local population="${2:?missing population}"
  local marker_selector
  marker_selector="$(metric_label_selector "$TRACE_MARKER")"
  local trace_loss runtime_loss required_record_loss
  trace_loss="$(metric_value_or_empty "max(agentstudio_performance_trace_queue_dropped_record_count{agent.proof.marker=\"$marker_selector\"})")"
  runtime_loss="$(metric_value_or_empty "max(agentstudio_performance_runtime_delivery_runtime_channel_outbound_dropped_count{agent.proof.marker=\"$marker_selector\"}) + max(agentstudio_performance_runtime_delivery_eventbus_live_dropped_count{agent.proof.marker=\"$marker_selector\"}) + max(agentstudio_performance_runtime_delivery_eventbus_replay_dropped_count{agent.proof.marker=\"$marker_selector\"})")"
  [ -n "$trace_loss" ] || return 1
  runtime_loss="${runtime_loss:-0}"
  required_record_loss="$(strict_required_record_loss "$population")"
  {
    echo "trace_queue_dropped_record_count=$trace_loss"
    echo "runtime_delivery_dropped_count=$runtime_loss"
    echo "collector_loss_count=$required_record_loss"
  } >"$summary"
}

strict_quiescence_signature_from_json() {
  local vector_json="${1:?missing quiescence vector}"
  local expected_unknown_worktree_count="${STRICT_FIXTURE_UNKNOWN_WORKTREE_COUNT:-}"
  /usr/bin/python3 - "$vector_json" "$expected_unknown_worktree_count" <<'PY'
import json
import math
import sys

required = (
    "capture", "execution", "publication", "binding", "visible_update",
    "cold_automatic_deadline_count", "cold_automatic_source_start_count",
    "unknown_worktree_count", "unknown_background_only_count",
    "unknown_remote_demand_count", "unknown_forge_demand_count",
    "git_logical_debt", "git_future_automatic_count", "git_future_failure_count",
    "git_ready_pending_count", "git_capacity_pending_count",
    "git_active_follow_up_count", "git_unclassified_pending_count",
    "git_overdue_deadline_count", "git_running_count", "git_physical_limit",
    "git_oldest_preparation_ms", "git_next_deadline_ms",
    "git_background_only_automatic_count", "git_background_only_deadline_count",
    "git_background_only_owned_count",
    "git_background_only_visible_tier_count",
    "remote_physical_active", "remote_pending_total", "remote_pending_future",
    "remote_pending_ready", "remote_pending_capacity", "remote_pending_active_follow_up",
    "remote_pending_unclassified", "remote_overdue_deadline", "remote_next_deadline_ms",
    "remote_physical_limit", "forge_physical_active", "forge_pending_total",
    "forge_pending_future", "forge_pending_ready", "forge_pending_capacity",
    "forge_pending_active_follow_up", "forge_pending_unclassified",
    "forge_overdue_deadline", "forge_next_deadline_ms", "forge_physical_limit",
    "git_maximum_settlement_ms", "export_backlog", "proof_failure_count",
)
clock_relative_fields = {
    "git_oldest_preparation_ms",
    "git_next_deadline_ms",
    "remote_next_deadline_ms",
    "forge_next_deadline_ms",
}
try:
    vector = json.loads(sys.argv[1])
except json.JSONDecodeError as error:
    raise SystemExit(f"invalid quiescence vector JSON: {error}")
if not isinstance(vector, dict):
    raise SystemExit("quiescence vector must be an object")
normalized = []
for name in required:
    if name not in vector:
        raise SystemExit(f"quiescence vector missing {name}")
    raw_value = vector[name]
    if raw_value is None or raw_value == "":
        raise SystemExit(f"quiescence vector empty {name}")
    try:
        value = float(raw_value)
    except (TypeError, ValueError):
        raise SystemExit(f"quiescence vector invalid {name}: {raw_value}") from None
    if not math.isfinite(value) or value < 0:
        raise SystemExit(f"quiescence vector invalid {name}: {raw_value}")
    if name in {"capture", "execution", "publication", "binding", "visible_update"} and value < 1:
        raise SystemExit(f"quiescence vector nonpositive {name}: {raw_value}")
    if name == "export_backlog" and value != 0:
        raise SystemExit("quiescence export backlog must remain zero")
    # Countdown and elapsed-age gauges are validated against policy below,
    # but their expected wall-clock movement is not a semantic state change.
    if name not in clock_relative_fields:
        normalized.append(f"{name}={value:g}")
if float(vector["git_overdue_deadline_count"]) != 0:
    raise SystemExit("quiescence Git deadline is overdue")
if float(vector["proof_failure_count"]) != 0:
    raise SystemExit("quiescence native proof has failed")
if float(vector["cold_automatic_deadline_count"]) != 0:
    raise SystemExit("quiescence cold automatic deadline remains")
if float(vector["cold_automatic_source_start_count"]) != 0:
    raise SystemExit("quiescence cold automatic source start was observed")
unknown_worktree_count = float(vector["unknown_worktree_count"])
unknown_background_only_count = float(vector["unknown_background_only_count"])
raw_expected_unknown_worktree_count = sys.argv[2]
if unknown_worktree_count <= 0:
    raise SystemExit("quiescence requires positive unknown membership")
if raw_expected_unknown_worktree_count and unknown_worktree_count != float(raw_expected_unknown_worktree_count):
    raise SystemExit("quiescence unknown membership does not match the strict fixture")
if unknown_background_only_count != unknown_worktree_count:
    raise SystemExit("quiescence unknown background classification is incomplete")
if float(vector["git_background_only_automatic_count"]) != unknown_background_only_count:
    raise SystemExit("quiescence unknown background classification did not reach Git")
if float(vector["git_background_only_deadline_count"]) > unknown_background_only_count:
    raise SystemExit("quiescence unknown background deadline count exceeds eligibility")
if float(vector["git_background_only_owned_count"]) != unknown_background_only_count:
    raise SystemExit("quiescence unknown background self-heal ownership is incomplete")
if float(vector["unknown_remote_demand_count"]) != 0:
    raise SystemExit("quiescence unknown remote demand was observed")
if float(vector["unknown_forge_demand_count"]) != 0:
    raise SystemExit("quiescence unknown Forge demand was observed")
if float(vector["git_background_only_visible_tier_count"]) != 0:
    raise SystemExit("quiescence unknown visible tier was observed")
if float(vector["git_ready_pending_count"]) != 0:
    raise SystemExit("quiescence Git ready work remains pending")
if float(vector["git_capacity_pending_count"]) != 0:
    raise SystemExit("quiescence Git capacity retry remains pending")
if float(vector["git_unclassified_pending_count"]) != 0:
    raise SystemExit("quiescence Git preparation debt is unclassified")
running_count = float(vector["git_running_count"])
physical_limit = float(vector["git_physical_limit"])
if physical_limit < 1:
    raise SystemExit("quiescence Git physical limit must be positive")
if running_count > physical_limit:
    raise SystemExit("quiescence Git running count exceeds physical limit")
if float(vector["git_active_follow_up_count"]) > running_count:
    raise SystemExit("quiescence Git active follow-up exceeds running ownership")
maximum_settlement_ms = float(vector["git_maximum_settlement_ms"])
if maximum_settlement_ms <= 0:
    raise SystemExit("quiescence Git maximum settlement must be positive")
if float(vector["git_oldest_preparation_ms"]) > maximum_settlement_ms:
    raise SystemExit("quiescence Git preparation debt exceeds settlement policy")
next_deadline_ms = float(vector["git_next_deadline_ms"])
if next_deadline_ms > maximum_settlement_ms:
    raise SystemExit("quiescence Git next deadline exceeds settlement policy")
future_count = float(vector["git_future_automatic_count"]) + float(vector["git_future_failure_count"])
if future_count > 0 and next_deadline_ms <= 0:
    raise SystemExit("quiescence Git future eligibility is missing its next deadline")
for source in ("remote", "forge"):
    pending_total = float(vector[f"{source}_pending_total"])
    pending_future = float(vector[f"{source}_pending_future"])
    pending_ready = float(vector[f"{source}_pending_ready"])
    pending_capacity = float(vector[f"{source}_pending_capacity"])
    pending_active_follow_up = float(vector[f"{source}_pending_active_follow_up"])
    pending_unclassified = float(vector[f"{source}_pending_unclassified"])
    classified_total = (
        pending_future + pending_ready + pending_capacity
        + pending_active_follow_up + pending_unclassified
    )
    if pending_total != classified_total:
        raise SystemExit(f"quiescence {source} pending classification is inconsistent")
    if pending_ready != 0:
        raise SystemExit(f"quiescence {source} ready work remains pending")
    if pending_capacity != 0:
        raise SystemExit(f"quiescence {source} capacity work remains pending")
    if pending_unclassified != 0:
        raise SystemExit(f"quiescence {source} pending work is unclassified")
    if float(vector[f"{source}_overdue_deadline"]) != 0:
        raise SystemExit(f"quiescence {source} deadline is overdue")
    physical_active = float(vector[f"{source}_physical_active"])
    physical_limit = float(vector[f"{source}_physical_limit"])
    if physical_limit < 1:
        raise SystemExit(f"quiescence {source} physical limit must be positive")
    if physical_active > physical_limit:
        raise SystemExit(f"quiescence {source} physical count exceeds its limit")
    if pending_active_follow_up > physical_active:
        raise SystemExit(f"quiescence {source} active follow-up exceeds physical ownership")
    source_next_deadline_ms = float(vector[f"{source}_next_deadline_ms"])
    if source_next_deadline_ms > maximum_settlement_ms:
        raise SystemExit(f"quiescence {source} next deadline exceeds settlement policy")
    if pending_future > 0 and source_next_deadline_ms <= 0:
        raise SystemExit(f"quiescence {source} future eligibility is missing its next deadline")
print(";".join(normalized))
PY
}

validate_strict_test_quiescence_sequence() {
  local sequence_json="${1:?missing quiescence sequence}"
  local vectors
  vectors="$(/usr/bin/python3 - "$sequence_json" <<'PY'
import json
import sys

try:
    sequence = json.loads(sys.argv[1])
except json.JSONDecodeError as error:
    raise SystemExit(f"invalid quiescence sequence JSON: {error}")
if not isinstance(sequence, list) or not sequence:
    raise SystemExit("quiescence test sequence must be a nonempty array")
for vector in sequence:
    print(json.dumps(vector, separators=(",", ":")))
PY
  )"
  local prior="" unchanged=0 baseline_time="" last_time="" elapsed_ms=0
  local state
  while IFS= read -r vector_json; do
    [ -n "$vector_json" ] || continue
    if ! state="$(strict_quiescence_transition \
      "$prior" "$unchanged" "$baseline_time" "$last_time" "$vector_json")"
    then
      return 1
    fi
    IFS='|' read -r prior unchanged baseline_time last_time elapsed_ms <<<"$state"
  done <<<"$vectors"
  strict_quiescence_state_is_complete "$unchanged" "$elapsed_ms" || {
    echo "quiescence vector changed during required interval" >&2
    return 1
  }
  echo "positive_quiescence=test_contract_passed"
}

strict_quiescence_transition() {
  local prior_signature="$1"
  local prior_unchanged="$2"
  local baseline_time="$3"
  local last_time="$4"
  local vector_json="${5:?missing quiescence vector}"
  local signature
  if ! signature="$(strict_quiescence_signature_from_json "$vector_json")"; then
    return 1
  fi
  /usr/bin/python3 - "$prior_signature" "$prior_unchanged" "$baseline_time" "$last_time" \
    "$signature" "$vector_json" "$STRICT_POLICY_METRICS_EXPORT_INTERVAL_MS" \
    "$STRICT_POLICY_MAXIMUM_SAMPLER_GAP_MS" <<'PY'
import json
import math
import sys

prior_signature, raw_unchanged, raw_baseline, raw_last, signature, vector_json, raw_export_interval, raw_maximum_age = (
    sys.argv[1:]
)
vector = json.loads(vector_json)
try:
    observation_time = float(vector["observation_time"])
    export_sample_time = float(vector["export_sample_time"])
    # Canned contract sequences predate source gauges; production vectors always
    # provide both values because their metric queries fail closed when absent.
    remote_sample_time = float(vector.get("remote_sample_time", export_sample_time))
    forge_sample_time = float(vector.get("forge_sample_time", export_sample_time))
except (KeyError, TypeError, ValueError):
    raise SystemExit("quiescence vector has missing or invalid observation time") from None
if not all(
    math.isfinite(value)
    for value in (observation_time, export_sample_time, remote_sample_time, forge_sample_time)
):
    raise SystemExit("quiescence vector has nonfinite observation time")
maximum_export_age = (float(raw_export_interval) + float(raw_maximum_age)) / 1000
export_sample_age = observation_time - export_sample_time
if export_sample_age < -0.001 or export_sample_age > maximum_export_age:
    raise SystemExit("quiescence export backlog sample is stale")
for sample_name, sample_time in (
    ("remote settlement", remote_sample_time),
    ("forge settlement", forge_sample_time),
):
    if observation_time - sample_time < -0.001:
        raise SystemExit(f"quiescence {sample_name} sample is from the future")
if raw_last and observation_time <= float(raw_last):
    raise SystemExit("quiescence observation time is not monotonic")
if prior_signature == signature and raw_baseline:
    unchanged = int(raw_unchanged) + 1
    baseline = float(raw_baseline)
else:
    unchanged = 0
    baseline = export_sample_time
if export_sample_time < baseline - 0.001:
    raise SystemExit("quiescence export sample time moved backwards")
elapsed_ms = max(0, int((export_sample_time - baseline) * 1000))
print(f"{signature}|{unchanged}|{baseline:.6f}|{observation_time:.6f}|{elapsed_ms}")
PY
}

strict_quiescence_state_is_complete() {
  local unchanged="${1:?missing unchanged count}"
  local elapsed_ms="${2:?missing elapsed milliseconds}"
  local required_unchanged=$((STRICT_POLICY_QUIESCENCE_MS / STRICT_POLICY_SAMPLE_INTERVAL_MS))
  [ "$unchanged" -ge "$required_unchanged" ] \
    && [ "$elapsed_ms" -ge "$STRICT_POLICY_QUIESCENCE_MS" ]
}

strict_final_git_settlement_from_json() {
  local vector_json="${1:?missing final Git settlement vector}"
  strict_quiescence_signature_from_json "$vector_json" >/dev/null
  /usr/bin/python3 - "$vector_json" <<'PY'
import json
import sys

vector = json.loads(sys.argv[1])
if float(vector["git_running_count"]) != 0:
    raise SystemExit("final Git settlement still owns running work")
if float(vector["git_active_follow_up_count"]) != 0:
    raise SystemExit("final Git settlement still owns an active follow-up")
for source in ("remote", "forge"):
    if float(vector[f"{source}_physical_active"]) != 0:
        raise SystemExit(f"final {source} physical settlement still owns running work")
    if float(vector[f"{source}_pending_active_follow_up"]) != 0:
        raise SystemExit(f"final {source} settlement still owns an active follow-up")
print("final_git_physical_settlement=complete")
PY
}

wait_for_strict_git_physical_settlement() {
  local marker="${1:?missing marker}"
  local monotonic_deadline_ms=$(( \
    $(monotonic_now_ms) + STRICT_POLICY_FIXTURE_PREPARATION_TIMEOUT_MS \
  ))
  local observation_time vector_json
  while [ "$(monotonic_now_ms)" -lt "$monotonic_deadline_ms" ]; do
    observation_time="$(/usr/bin/python3 -c 'import time; print(f"{time.time():.6f}")')"
    STRICT_WAIT_MONOTONIC_DEADLINE_MS="$monotonic_deadline_ms"
    export STRICT_WAIT_MONOTONIC_DEADLINE_MS
    vector_json="$(strict_sidebar_quiescence_vector_json \
      "$marker" "$observation_time" 2>/dev/null || true)"
    unset STRICT_WAIT_MONOTONIC_DEADLINE_MS
    if [ -n "$vector_json" ] \
      && strict_final_git_settlement_from_json "$vector_json" >/dev/null 2>&1
    then
      printf '%s\n' "final_git_physical_settlement=complete"
      return 0
    fi
    if [ "$(monotonic_now_ms)" -lt "$monotonic_deadline_ms" ]; then
      /bin/sleep "$(/usr/bin/python3 -c 'import sys; print(float(sys.argv[1])/1000)' \
        "$STRICT_POLICY_SAMPLE_INTERVAL_MS")"
    fi
  done
  echo "final Git physical settlement did not complete" >&2
  return 1
}

validate_strict_periodic_completion_delta() {
  local baseline="${1:?missing periodic completion baseline}"
  local final="${2:?missing periodic completion final}"
  /usr/bin/python3 - "$baseline" "$final" <<'PY'
import sys
baseline, final = map(float, sys.argv[1:])
if final <= baseline:
    raise SystemExit("idle population did not observe a periodic Git self-heal completion")
print(f"periodic_completion_delta={final - baseline:g}")
PY
}

metric_value_at_observation() {
  local query="${1:?missing metric query}"
  local observation_time="${2:?missing observation time}"
  if [ -n "${STRICT_WAIT_MONOTONIC_DEADLINE_MS:-}" ] \
    && [ "$(monotonic_now_ms)" -ge "$STRICT_WAIT_MONOTONIC_DEADLINE_MS" ]; then
    echo "metric read exceeded strict wait deadline" >&2
    return 124
  fi
  local response
  response="$(query_victoria_metrics "$query" "$observation_time")" || return 1
  /usr/bin/python3 - "$response" "$observation_time" <<'PY'
import json
import math
import sys

try:
    payload = json.loads(sys.argv[1])
except json.JSONDecodeError as error:
    raise SystemExit(f"invalid Victoria metric response: {error}")
if payload.get("status") != "success":
    raise SystemExit("Victoria metric response was not successful")
results = payload.get("data", {}).get("result", [])
if len(results) != 1:
    raise SystemExit(f"Victoria metric response expected one result, got {len(results)}")
sample = results[0].get("value")
if not isinstance(sample, list) or len(sample) != 2:
    raise SystemExit("Victoria metric response has no instant sample")
try:
    response_time = float(sample[0])
    expected_time = float(sys.argv[2])
    value = float(sample[1])
except (TypeError, ValueError):
    raise SystemExit("Victoria metric response contains a nonnumeric sample") from None
if not math.isfinite(response_time) or abs(response_time - expected_time) > 0.001:
    raise SystemExit("Victoria metric response is not bound to the requested observation time")
if not math.isfinite(value):
    raise SystemExit("Victoria metric response contains a nonfinite value")
print(f"{value:g}")
PY
}

source_settlement_metric_value_at_observation() {
  local source="${1:?missing source}"
  local metric_suffix="${2:?missing metric suffix}"
  local marker_selector="${3:?missing marker selector}"
  local observation_time="${4:?missing observation time}"
  local event_name
  case "$source" in
    remote_reference) event_name="performance.remote_reference.refresh" ;;
    forge) event_name="performance.forge.refresh" ;;
    *) echo "unsupported settlement source: $source" >&2; return 1 ;;
  esac
  metric_value_at_observation \
    "max(agentstudio_performance_${source}_settlement_${metric_suffix}{agent.proof.marker=\"$marker_selector\",event=\"$event_name\"})" \
    "$observation_time"
}

strict_sidebar_quiescence_vector_json() {
  local marker="${1:?missing marker}"
  local observation_time="${2:?missing observation time}"
  local marker_selector capture execution publication binding visible_update proof_failure_count
  local cold_automatic_deadline_count cold_automatic_source_start_count
  local unknown_worktree_count unknown_background_only_count
  local unknown_remote_demand_count unknown_forge_demand_count
  local git_logical_debt
  local git_future_automatic_count git_future_failure_count git_ready_pending_count
  local git_capacity_pending_count git_active_follow_up_count git_unclassified_pending_count
  local git_overdue_deadline_count git_running_count git_oldest_preparation_ms git_next_deadline_ms
  local git_background_only_automatic_count git_background_only_deadline_count
  local git_background_only_owned_count
  local git_background_only_visible_tier_count
  local remote_physical_active remote_pending_total remote_pending_future remote_pending_ready
  local remote_pending_capacity remote_pending_active_follow_up remote_pending_unclassified
  local remote_overdue_deadline remote_next_deadline_ms remote_sample_time
  local forge_physical_active forge_pending_total forge_pending_future forge_pending_ready
  local forge_pending_capacity forge_pending_active_follow_up forge_pending_unclassified
  local forge_overdue_deadline forge_next_deadline_ms forge_sample_time
  local export_backlog
  local export_sample_time export_metric_selector
  marker_selector="$(metric_label_selector "$marker")"
  capture="$(metric_value_at_observation \
    "sum(agentstudio_performance_events_total{agent.proof.marker=\"$marker_selector\",event=\"performance.sidebar.projection\",surface=\"repo\",phase=\"request_build_mainactor\"})" \
    "$observation_time")"
  execution="$(metric_value_at_observation \
    "sum(agentstudio_performance_events_total{agent.proof.marker=\"$marker_selector\",event=\"performance.repo_explorer.stage_snapshot\",stage=\"projection_worker\"})" \
    "$observation_time")"
  publication="$(metric_value_at_observation \
    "sum(agentstudio_performance_events_total{agent.proof.marker=\"$marker_selector\",event=\"performance.repo_explorer.stage_snapshot\",stage=\"projection_worker\",outcome=\"published\"})" \
    "$observation_time")"
  binding="$(metric_value_at_observation \
    "sum(agentstudio_performance_events_total{agent.proof.marker=\"$marker_selector\",event=\"performance.repo_explorer.stage_snapshot\",stage=\"mainactor_apply\",outcome=\"published\"})" \
    "$observation_time")"
  visible_update="$(metric_value_at_observation \
    "sum(agentstudio_performance_events_total{agent.proof.marker=\"$marker_selector\",event=\"performance.repo_explorer.stage_snapshot\",stage=\"materialize\",outcome=\"materialized\"})" \
    "$observation_time")"
  proof_failure_count="$(metric_value_at_observation \
    "sum(agentstudio_performance_events_total{agent.proof.marker=\"$marker_selector\",event=\"performance.sidebar.proof_action.failed\"}) or vector(0)" \
    "$observation_time")"
  cold_automatic_deadline_count="$(metric_value_at_observation \
    "max(agentstudio_performance_git_inactive_automatic_deadline_count{agent.proof.marker=\"$marker_selector\",event=\"performance.git.logical_debt\"})" \
    "$observation_time")"
  cold_automatic_source_start_count="$(metric_value_at_observation \
    "max(agentstudio_performance_git_inactive_automatic_source_start_count{agent.proof.marker=\"$marker_selector\",event=\"performance.git.logical_debt\"}) + (sum(agentstudio_performance_remote_reference_execution_automatic_without_demand_started_count{agent.proof.marker=\"$marker_selector\",event=\"performance.remote_reference.refresh\"}) or vector(0)) + (sum(agentstudio_performance_forge_execution_automatic_without_demand_started_count{agent.proof.marker=\"$marker_selector\",event=\"performance.forge.refresh\"}) or vector(0))" \
    "$observation_time")"
  unknown_worktree_count="$(metric_value_at_observation \
    "max(agentstudio_performance_repository_fact_demand_pipeline_unknown_worktree_current{agent.proof.marker=\"$marker_selector\",event=\"performance.repository_fact_demand\"})" \
    "$observation_time")"
  unknown_background_only_count="$(metric_value_at_observation \
    "max(agentstudio_performance_repository_fact_demand_pipeline_unknown_background_only_current{agent.proof.marker=\"$marker_selector\",event=\"performance.repository_fact_demand\"})" \
    "$observation_time")"
  unknown_remote_demand_count="$(metric_value_at_observation \
    "max(agentstudio_performance_repository_fact_demand_pipeline_unknown_remote_demand_current{agent.proof.marker=\"$marker_selector\",event=\"performance.repository_fact_demand\"})" \
    "$observation_time")"
  unknown_forge_demand_count="$(metric_value_at_observation \
    "max(agentstudio_performance_repository_fact_demand_pipeline_unknown_forge_demand_current{agent.proof.marker=\"$marker_selector\",event=\"performance.repository_fact_demand\"})" \
    "$observation_time")"
  git_logical_debt="$(metric_value_at_observation \
    "max(agentstudio_performance_git_logical_debt_count{agent.proof.marker=\"$marker_selector\",event=\"performance.git.logical_debt\"})" \
    "$observation_time")"
  git_future_automatic_count="$(metric_value_at_observation \
    "max(agentstudio_performance_git_future_automatic_count{agent.proof.marker=\"$marker_selector\",event=\"performance.git.logical_debt\"})" \
    "$observation_time")"
  git_future_failure_count="$(metric_value_at_observation \
    "max(agentstudio_performance_git_future_failure_count{agent.proof.marker=\"$marker_selector\",event=\"performance.git.logical_debt\"})" \
    "$observation_time")"
  git_ready_pending_count="$(metric_value_at_observation \
    "max(agentstudio_performance_git_ready_pending_count{agent.proof.marker=\"$marker_selector\",event=\"performance.git.logical_debt\"})" \
    "$observation_time")"
  git_capacity_pending_count="$(metric_value_at_observation \
    "max(agentstudio_performance_git_capacity_pending_count{agent.proof.marker=\"$marker_selector\",event=\"performance.git.logical_debt\"})" \
    "$observation_time")"
  git_active_follow_up_count="$(metric_value_at_observation \
    "max(agentstudio_performance_git_active_follow_up_count{agent.proof.marker=\"$marker_selector\",event=\"performance.git.logical_debt\"})" \
    "$observation_time")"
  git_unclassified_pending_count="$(metric_value_at_observation \
    "max(agentstudio_performance_git_unclassified_pending_count{agent.proof.marker=\"$marker_selector\",event=\"performance.git.logical_debt\"})" \
    "$observation_time")"
  git_overdue_deadline_count="$(metric_value_at_observation \
    "max(agentstudio_performance_git_overdue_deadline_count{agent.proof.marker=\"$marker_selector\",event=\"performance.git.logical_debt\"})" \
    "$observation_time")"
  git_running_count="$(metric_value_at_observation \
    "max(agentstudio_performance_git_logical_running_count{agent.proof.marker=\"$marker_selector\",event=\"performance.git.logical_debt\"})" \
    "$observation_time")"
  git_oldest_preparation_ms="$(metric_value_at_observation \
    "max(agentstudio_performance_git_oldest_preparation_ms{agent.proof.marker=\"$marker_selector\",event=\"performance.git.logical_debt\"})" \
    "$observation_time")"
  git_next_deadline_ms="$(metric_value_at_observation \
    "max(agentstudio_performance_git_next_deadline_ms{agent.proof.marker=\"$marker_selector\",event=\"performance.git.logical_debt\"})" \
    "$observation_time")"
  git_background_only_automatic_count="$(metric_value_at_observation \
    "max(agentstudio_performance_git_background_only_automatic_current{agent.proof.marker=\"$marker_selector\",event=\"performance.git.logical_debt\"})" \
    "$observation_time")"
  git_background_only_deadline_count="$(metric_value_at_observation \
    "max(agentstudio_performance_git_background_only_automatic_deadline_current{agent.proof.marker=\"$marker_selector\",event=\"performance.git.logical_debt\"})" \
    "$observation_time")"
  git_background_only_owned_count="$(metric_value_at_observation \
    "max(agentstudio_performance_git_background_only_automatic_owned_current{agent.proof.marker=\"$marker_selector\",event=\"performance.git.logical_debt\"})" \
    "$observation_time")"
  git_background_only_visible_tier_count="$(metric_value_at_observation \
    "max(agentstudio_performance_git_background_only_resolved_visible_tier_current{agent.proof.marker=\"$marker_selector\",event=\"performance.git.logical_debt\"})" \
    "$observation_time")"
  remote_physical_active="$(source_settlement_metric_value_at_observation \
    remote_reference physical_active_current "$marker_selector" "$observation_time")"
  remote_pending_total="$(source_settlement_metric_value_at_observation \
    remote_reference pending_total_current "$marker_selector" "$observation_time")"
  remote_pending_future="$(source_settlement_metric_value_at_observation \
    remote_reference pending_future_current "$marker_selector" "$observation_time")"
  remote_pending_ready="$(source_settlement_metric_value_at_observation \
    remote_reference pending_ready_current "$marker_selector" "$observation_time")"
  remote_pending_capacity="$(source_settlement_metric_value_at_observation \
    remote_reference pending_capacity_current "$marker_selector" "$observation_time")"
  remote_pending_active_follow_up="$(source_settlement_metric_value_at_observation \
    remote_reference pending_active_follow_up_current "$marker_selector" "$observation_time")"
  remote_pending_unclassified="$(source_settlement_metric_value_at_observation \
    remote_reference pending_unclassified_current "$marker_selector" "$observation_time")"
  remote_overdue_deadline="$(source_settlement_metric_value_at_observation \
    remote_reference deadline_overdue_current "$marker_selector" "$observation_time")"
  remote_next_deadline_ms="$(source_settlement_metric_value_at_observation \
    remote_reference deadline_next_ms "$marker_selector" "$observation_time")"
  remote_sample_time="$(metric_value_at_observation \
    "max(timestamp(agentstudio_performance_remote_reference_settlement_physical_active_current{agent.proof.marker=\"$marker_selector\",event=\"performance.remote_reference.refresh\"}))" \
    "$observation_time")"
  forge_physical_active="$(source_settlement_metric_value_at_observation \
    forge physical_active_current "$marker_selector" "$observation_time")"
  forge_pending_total="$(source_settlement_metric_value_at_observation \
    forge pending_total_current "$marker_selector" "$observation_time")"
  forge_pending_future="$(source_settlement_metric_value_at_observation \
    forge pending_future_current "$marker_selector" "$observation_time")"
  forge_pending_ready="$(source_settlement_metric_value_at_observation \
    forge pending_ready_current "$marker_selector" "$observation_time")"
  forge_pending_capacity="$(source_settlement_metric_value_at_observation \
    forge pending_capacity_current "$marker_selector" "$observation_time")"
  forge_pending_active_follow_up="$(source_settlement_metric_value_at_observation \
    forge pending_active_follow_up_current "$marker_selector" "$observation_time")"
  forge_pending_unclassified="$(source_settlement_metric_value_at_observation \
    forge pending_unclassified_current "$marker_selector" "$observation_time")"
  forge_overdue_deadline="$(source_settlement_metric_value_at_observation \
    forge deadline_overdue_current "$marker_selector" "$observation_time")"
  forge_next_deadline_ms="$(source_settlement_metric_value_at_observation \
    forge deadline_next_ms "$marker_selector" "$observation_time")"
  forge_sample_time="$(metric_value_at_observation \
    "max(timestamp(agentstudio_performance_forge_settlement_physical_active_current{agent.proof.marker=\"$marker_selector\",event=\"performance.forge.refresh\"}))" \
    "$observation_time")"
  export_metric_selector='agentstudio_performance_trace_queue_pending_request_count{agent.proof.marker="'"$marker_selector"'",event="performance.runtime_delivery.snapshot"}'
  export_backlog="$(metric_value_at_observation \
    "max($export_metric_selector)" \
    "$observation_time")"
  export_sample_time="$(metric_value_at_observation \
    "max(timestamp($export_metric_selector))" \
    "$observation_time")"
  /usr/bin/python3 - "$capture" "$execution" "$publication" "$binding" "$visible_update" \
    "$cold_automatic_deadline_count" "$cold_automatic_source_start_count" \
    "$unknown_worktree_count" "$unknown_background_only_count" \
    "$unknown_remote_demand_count" "$unknown_forge_demand_count" \
    "$git_logical_debt" "$git_future_automatic_count" "$git_future_failure_count" \
    "$git_ready_pending_count" "$git_capacity_pending_count" "$git_active_follow_up_count" \
    "$git_unclassified_pending_count" "$git_overdue_deadline_count" "$git_running_count" \
    "$STRICT_POLICY_GIT_STATUS_PHYSICAL_LIMIT" "$git_oldest_preparation_ms" \
    "$git_next_deadline_ms" "$git_background_only_automatic_count" \
    "$git_background_only_deadline_count" "$git_background_only_owned_count" \
    "$git_background_only_visible_tier_count" \
    "$remote_physical_active" "$remote_pending_total" \
    "$remote_pending_future" "$remote_pending_ready" "$remote_pending_capacity" \
    "$remote_pending_active_follow_up" "$remote_pending_unclassified" "$remote_overdue_deadline" \
    "$remote_next_deadline_ms" "$STRICT_POLICY_REMOTE_REFERENCE_PHYSICAL_LIMIT" \
    "$forge_physical_active" "$forge_pending_total" "$forge_pending_future" \
    "$forge_pending_ready" "$forge_pending_capacity" "$forge_pending_active_follow_up" \
    "$forge_pending_unclassified" "$forge_overdue_deadline" "$forge_next_deadline_ms" \
    "$STRICT_POLICY_FORGE_PHYSICAL_LIMIT" "$STRICT_POLICY_GIT_MAXIMUM_SETTLEMENT_MS" \
    "$export_backlog" "$proof_failure_count" "$observation_time" "$export_sample_time" \
    "$remote_sample_time" "$forge_sample_time" <<'PY'
import json
import sys

names = (
    "capture", "execution", "publication", "binding", "visible_update",
    "cold_automatic_deadline_count", "cold_automatic_source_start_count",
    "unknown_worktree_count", "unknown_background_only_count",
    "unknown_remote_demand_count", "unknown_forge_demand_count",
    "git_logical_debt", "git_future_automatic_count", "git_future_failure_count",
    "git_ready_pending_count", "git_capacity_pending_count", "git_active_follow_up_count",
    "git_unclassified_pending_count", "git_overdue_deadline_count", "git_running_count",
    "git_physical_limit", "git_oldest_preparation_ms", "git_next_deadline_ms",
    "git_background_only_automatic_count", "git_background_only_deadline_count",
    "git_background_only_owned_count",
    "git_background_only_visible_tier_count",
    "remote_physical_active", "remote_pending_total", "remote_pending_future",
    "remote_pending_ready", "remote_pending_capacity", "remote_pending_active_follow_up",
    "remote_pending_unclassified", "remote_overdue_deadline", "remote_next_deadline_ms",
    "remote_physical_limit", "forge_physical_active", "forge_pending_total",
    "forge_pending_future", "forge_pending_ready", "forge_pending_capacity",
    "forge_pending_active_follow_up", "forge_pending_unclassified", "forge_overdue_deadline",
    "forge_next_deadline_ms", "forge_physical_limit", "git_maximum_settlement_ms",
    "export_backlog", "proof_failure_count", "observation_time", "export_sample_time", "remote_sample_time",
    "forge_sample_time",
)
print(json.dumps(dict(zip(names, sys.argv[1:]))))
PY
}

strict_sidebar_proof_has_failed() {
  local marker="${1:?missing marker}"
  local query response
  query='{service.name="AgentStudio",dev.runtime.flavor="debug"} agent.proof.marker:"'"$marker"'" _msg:performance.sidebar.proof_action.failed | fields _msg | limit 1'
  response="$(curl --fail --silent --show-error --max-time 5 \
    "$LOGS_QUERY_URL" --data-urlencode "query=$query" 2>/dev/null || true)"
  [ -n "$response" ]
}

wait_for_positive_quiescence() {
  local marker="${1:?missing marker}"
  local timeout_ms=$((STRICT_POLICY_GIT_MAXIMUM_SETTLEMENT_MS \
    + STRICT_POLICY_QUIESCENCE_MS + STRICT_POLICY_READBACK_TIMEOUT_MS))
  local monotonic_deadline_ms=$(( $(monotonic_now_ms) + timeout_ms ))
  local prior="" unchanged=0 vector_json observation_time
  local baseline_time="" last_time="" elapsed_ms=0 state
  while [ "$elapsed_ms" -lt "$STRICT_POLICY_QUIESCENCE_MS" ] \
    && [ "$(monotonic_now_ms)" -lt "$monotonic_deadline_ms" ]; do
    if strict_sidebar_proof_has_failed "$marker"; then
      echo "native sidebar proof failed before quiescence" >&2
      return 1
    fi
    observation_time="$(/usr/bin/python3 -c 'import time; print(f"{time.time():.6f}")')"
    STRICT_WAIT_MONOTONIC_DEADLINE_MS="$monotonic_deadline_ms"
    export STRICT_WAIT_MONOTONIC_DEADLINE_MS
    vector_json="$(strict_sidebar_quiescence_vector_json \
      "$marker" "$observation_time" 2>/dev/null || true)"
    unset STRICT_WAIT_MONOTONIC_DEADLINE_MS
    if [ -n "$vector_json" ]; then
      state="$(strict_quiescence_transition \
        "$prior" "$unchanged" "$baseline_time" "$last_time" "$vector_json" \
        2>/dev/null || true)"
    else
      state=""
    fi
    if [ -n "$state" ]; then
      IFS='|' read -r prior unchanged baseline_time last_time elapsed_ms <<<"$state"
    else
      prior=""
      unchanged=0
      baseline_time=""
      last_time=""
      elapsed_ms=0
    fi
    if [ "$elapsed_ms" -lt "$STRICT_POLICY_QUIESCENCE_MS" ] \
      && [ "$(monotonic_now_ms)" -lt "$monotonic_deadline_ms" ]; then
      /bin/sleep "$(/usr/bin/python3 -c 'import sys; print(float(sys.argv[1])/1000)' \
        "$STRICT_POLICY_SAMPLE_INTERVAL_MS")"
    fi
  done
  strict_quiescence_state_is_complete "$unchanged" "$elapsed_ms" || {
    echo "positive quiescence did not observe a complete unchanged stage/export vector" >&2
    return 1
  }
}

strict_git_continuity_counter_value() {
  local metric_suffix="${1:?missing continuity counter suffix}"
  local marker_selector
  marker_selector="$(metric_label_selector "$TRACE_MARKER")"
  metric_value_or_empty \
    "sum(agentstudio_performance_git_aggregate_continuity_${metric_suffix}_count{agent.proof.marker=\"$marker_selector\",event=\"performance.git.aggregate\"})"
}

strict_git_continuity_authority_value() {
  local marker_selector
  marker_selector="$(metric_label_selector "$TRACE_MARKER")"
  metric_value_or_empty \
    "max(agentstudio_performance_git_aggregate_continuity_authority_current{agent.proof.marker=\"$marker_selector\",event=\"performance.git.aggregate\"})"
}

capture_strict_git_continuity_baseline() {
  local output="${1:?missing continuity baseline output}"
  local timeout_ms=$((STRICT_POLICY_GIT_MAXIMUM_SETTLEMENT_MS \
    + STRICT_POLICY_QUIESCENCE_MS + STRICT_POLICY_READBACK_TIMEOUT_MS))
  local deadline_ms=$(( $(monotonic_now_ms) + timeout_ms ))
  local accepted authority mutation uncertainty fallback_admitted fallback_coalesced
  local renewed avoided_facts avoided_detail
  while [ "$(monotonic_now_ms)" -lt "$deadline_ms" ]; do
    accepted="$(strict_git_continuity_counter_value baseline_accepted)"; accepted="${accepted:-0}"
    authority="$(strict_git_continuity_authority_value)"; authority="${authority:-0}"
    if /usr/bin/python3 - "$accepted" "$authority" <<'PY'
import sys
accepted, authority = map(float, sys.argv[1:])
raise SystemExit(0 if accepted > 0 and authority > 0 else 1)
PY
    then
      mutation="$(strict_git_continuity_counter_value mutation_invalidated)"; mutation="${mutation:-0}"
      uncertainty="$(strict_git_continuity_counter_value uncertainty_mutation_observed)"; uncertainty="${uncertainty:-0}"
      fallback_admitted="$(strict_git_continuity_counter_value fallback_admitted)"; fallback_admitted="${fallback_admitted:-0}"
      fallback_coalesced="$(strict_git_continuity_counter_value fallback_coalesced)"; fallback_coalesced="${fallback_coalesced:-0}"
      renewed="$(strict_git_continuity_counter_value renewed)"; renewed="${renewed:-0}"
      avoided_facts="$(strict_git_continuity_counter_value physical_fact_read_avoided)"; avoided_facts="${avoided_facts:-0}"
      avoided_detail="$(strict_git_continuity_counter_value physical_detail_read_avoided)"; avoided_detail="${avoided_detail:-0}"
      {
        printf 'STRICT_CONTINUITY_BASELINE_ACCEPTED=%s\n' "$accepted"
        printf 'STRICT_CONTINUITY_BASELINE_MUTATION=%s\n' "$mutation"
        printf 'STRICT_CONTINUITY_BASELINE_UNCERTAINTY=%s\n' "$uncertainty"
        printf 'STRICT_CONTINUITY_BASELINE_FALLBACK_ADMITTED=%s\n' "$fallback_admitted"
        printf 'STRICT_CONTINUITY_BASELINE_FALLBACK_COALESCED=%s\n' "$fallback_coalesced"
        printf 'STRICT_CONTINUITY_BASELINE_RENEWED=%s\n' "$renewed"
        printf 'STRICT_CONTINUITY_BASELINE_AVOIDED_FACTS=%s\n' "$avoided_facts"
        printf 'STRICT_CONTINUITY_BASELINE_AVOIDED_DETAIL=%s\n' "$avoided_detail"
      } >"$output"
      return 0
    fi
    /bin/sleep 1
  done
  echo "verified-clean continuity authority did not become observable before mutation" >&2
  return 1
}

validate_strict_git_continuity_recovery() {
  local baseline_file="${1:?missing continuity baseline file}"
  # shellcheck disable=SC1090
  source "$baseline_file"
  local accepted mutation uncertainty fallback_admitted fallback_coalesced
  local renewed avoided_facts avoided_detail authority
  accepted="$(strict_git_continuity_counter_value baseline_accepted)"; accepted="${accepted:-0}"
  mutation="$(strict_git_continuity_counter_value mutation_invalidated)"; mutation="${mutation:-0}"
  uncertainty="$(strict_git_continuity_counter_value uncertainty_mutation_observed)"; uncertainty="${uncertainty:-0}"
  fallback_admitted="$(strict_git_continuity_counter_value fallback_admitted)"; fallback_admitted="${fallback_admitted:-0}"
  fallback_coalesced="$(strict_git_continuity_counter_value fallback_coalesced)"; fallback_coalesced="${fallback_coalesced:-0}"
  renewed="$(strict_git_continuity_counter_value renewed)"; renewed="${renewed:-0}"
  avoided_facts="$(strict_git_continuity_counter_value physical_fact_read_avoided)"; avoided_facts="${avoided_facts:-0}"
  avoided_detail="$(strict_git_continuity_counter_value physical_detail_read_avoided)"; avoided_detail="${avoided_detail:-0}"
  authority="$(strict_git_continuity_authority_value)"; authority="${authority:-0}"
  validate_strict_git_continuity_delta_values \
    "$STRICT_CONTINUITY_BASELINE_ACCEPTED" "$accepted" \
    "$STRICT_CONTINUITY_BASELINE_MUTATION" "$mutation" \
    "$STRICT_CONTINUITY_BASELINE_UNCERTAINTY" "$uncertainty" \
    "$STRICT_CONTINUITY_BASELINE_FALLBACK_ADMITTED" "$fallback_admitted" \
    "$STRICT_CONTINUITY_BASELINE_FALLBACK_COALESCED" "$fallback_coalesced" \
    "$STRICT_CONTINUITY_BASELINE_RENEWED" "$renewed" \
    "$STRICT_CONTINUITY_BASELINE_AVOIDED_FACTS" "$avoided_facts" \
    "$STRICT_CONTINUITY_BASELINE_AVOIDED_DETAIL" "$avoided_detail" "$authority"
}

validate_strict_git_continuity_delta_values() {
  [ "$#" -eq 17 ] || {
    echo "continuity delta validation requires 17 values" >&2
    return 2
  }
  /usr/bin/python3 - "$@" <<'PY'
import sys
values = list(map(float, sys.argv[1:]))
(accepted_before, accepted_after, mutation_before, mutation_after,
 uncertainty_before, uncertainty_after, admitted_before, admitted_after,
 coalesced_before, coalesced_after, renewed_before, renewed_after,
 facts_before, facts_after, detail_before, detail_after, authority) = values
if accepted_after <= accepted_before:
    raise SystemExit("controlled exact fallback did not remint clean authority")
if mutation_after - mutation_before != 1:
    raise SystemExit("controlled ignored mutation did not invalidate exactly one authority")
if uncertainty_after - uncertainty_before != 1:
    raise SystemExit("controlled mutation uncertainty reason was not observed exactly once")
if (admitted_after - admitted_before) + (coalesced_after - coalesced_before) != 1:
    raise SystemExit("controlled mutation did not produce exactly one bounded fallback outcome")
if renewed_after <= renewed_before:
    raise SystemExit("measured interval did not contain a positive continuity renewal")
if facts_after <= facts_before or detail_after <= detail_before:
    raise SystemExit("measured interval did not prove avoided physical Git reads")
if authority <= 0:
    raise SystemExit("continuity authority did not recover after exact fallback")
PY
}

begin_strict_population() {
  local population="${1:?missing population}"
  local selector="${2:?missing diagnostic selector}"
  local trace_tags="${3:-$WORKLOAD_TRACE_TAGS}"
  local population_artifact="$ARTIFACT/populations/$population"
  local fixture_environment="$population_artifact/fixture.env"
  local activation_mode
  mkdir -p "$population_artifact"
  reset_disposable_debug_root
  STRICT_CONTROL_ROOT="$RESET_DATA_DIR/sidebar-performance-continuity-control"
  prepare_strict_git_continuity_control "$STRICT_CONTROL_ROOT"
  TRACE_MARKER="$(opaque_trace_marker "${TRACE_NAME}-${population}" "$(/usr/bin/uuidgen)")"
  STATE_FILE="$population_artifact/debug-observability.env"
  : >"$population_artifact/zmx-lifecycle.jsonl"
  strict_zmx_inventory_json ready >>"$population_artifact/zmx-lifecycle.jsonl"
  env AGENTSTUDIO_TRACE_FLUSH=immediate \
    AGENTSTUDIO_DEBUG_DATA_DIR="$STRICT_DISPOSABLE_DATA_ROOT" \
    AGENTSTUDIO_DEBUG_LAUNCH_ACTIVATE=1 \
    AGENTSTUDIO_TRACE_TAGS="$trace_tags" \
    AGENTSTUDIO_TRACE_NAME="$TRACE_MARKER" \
    AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION="$selector" \
    AGENTSTUDIO_STARTUP_WATCH_FOLDER="$STRICT_CONTROL_ROOT" \
    AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$STATE_FILE" \
    "$DEBUG_RUNNER" --detach
  for _ in $(seq 1 60); do [ -s "$STATE_FILE" ] && break; /bin/sleep 1; done
  [ -s "$STATE_FILE" ] || return 1
  APP_PID="$(decode_env_file_value "$STATE_FILE" AGENTSTUDIO_OBSERVABILITY_PID)"
  activation_mode="$(decode_env_file_value "$STATE_FILE" AGENTSTUDIO_OBSERVABILITY_ACTIVATION_MODE)"
  if [ "$activation_mode" != "foreground" ]; then
    echo "strict sidebar population requires foreground LaunchServices activation mode: ${activation_mode:-<missing>}" >&2
    return 1
  fi
  validate_current_candidate
  load_and_bind_strict_sidebar_policy "$population_artifact"
  load_strict_sidebar_fixture_ready "$population_artifact/fixture-ready.jsonl"
  validate_and_bind_strict_sidebar_fixture \
    "$population_artifact/fixture-ready.jsonl" "$population" "$fixture_environment"
  validate_strict_repository_update_telemetry \
    "$population_artifact/repository-update-telemetry.jsonl"
  echo "$TRACE_MARKER" >"$population_artifact/marker.txt"
  echo "$APP_PID" >"$population_artifact/pid.txt"
  if printf '%s\n' "$STRICT_POLICY_ACTION_POPULATIONS" | grep -qw "$population" \
    || [ "$population" = "grouping_diagnostic" ]
  then
    start_strict_action_sampler "$population"
  fi
  wait_for_positive_quiescence "$TRACE_MARKER"
  record_strict_zmx_inventory "$population" quiescent
  start_strict_zmx_monitor "$population"
}

sample_strict_idle_population() {
  local population="${1:?missing population}"
  local raw_samples="$ARTIFACT/populations/$population/cpu.raw.samples"
  local samples="$ARTIFACT/populations/$population/cpu.samples"
  local marker_selector periodic_query periodic_completion_baseline periodic_completion_final
  local continuity_baseline="$ARTIFACT/populations/$population/continuity-baseline.env"
  marker_selector="$(metric_label_selector "$TRACE_MARKER")"
  periodic_query="sum(agentstudio_performance_events_total{agent.proof.marker=\"$marker_selector\",event=\"performance.git.status\",trigger_source=\"periodic\"})"
  periodic_completion_baseline="$(metric_value_or_empty "$periodic_query")"
  periodic_completion_baseline="${periodic_completion_baseline:-0}"
  /usr/bin/python3 - "$STRICT_POLICY_IDLE_SAMPLE_FLOOR" "$STRICT_POLICY_SAMPLE_INTERVAL_MS" \
    "$STRICT_POLICY_GIT_MAXIMUM_SETTLEMENT_MS" <<'PY'
import sys
sample_floor, sample_interval_ms, maximum_settlement_ms = map(float, sys.argv[1:])
if sample_floor * sample_interval_ms < maximum_settlement_ms:
    raise SystemExit("idle population is shorter than the maximum Git settlement interval")
PY
  if [ "$population" = "zero_pty_idle" ]; then
    capture_strict_git_continuity_baseline "$continuity_baseline"
    inject_strict_git_continuity_uncertainty "$STRICT_CONTROL_ROOT"
  fi
  start_strict_action_sampler "$population"
  while [ "$(wc -l <"$raw_samples")" -lt "$STRICT_POLICY_IDLE_SAMPLE_FLOOR" ]; do
    kill -0 "$CPU_SAMPLER_PID" || return 1
    /bin/sleep 0.1
  done
  : >"$ARTIFACT/populations/$population/stop-sampler"
  wait "$CPU_SAMPLER_PID"
  CPU_SAMPLER_PID=""
  validate_current_candidate
  cp "$raw_samples" "$samples"
  validate_strict_sampler_gaps "$samples"
  wait_for_strict_git_physical_settlement "$TRACE_MARKER"
  wait_for_positive_quiescence "$TRACE_MARKER"
  periodic_completion_final="$(metric_value_or_empty "$periodic_query")"
  periodic_completion_final="${periodic_completion_final:-0}"
  validate_strict_periodic_completion_delta \
    "$periodic_completion_baseline" "$periodic_completion_final"
  if [ "$population" = "zero_pty_idle" ]; then
    validate_strict_git_continuity_recovery "$continuity_baseline"
  fi
  finish_strict_population "$population"
}

drive_strict_action_population() {
  local population="${1:?missing population}"
  local marker="$TRACE_MARKER"
  local population_artifact="$ARTIFACT/populations/$population"
  local raw_samples="$population_artifact/cpu.raw.samples"
  local samples="$population_artifact/cpu.samples"
  local records="$population_artifact/action-records.jsonl"
  local terminal_query='{service.name="AgentStudio",dev.runtime.flavor="debug"} agent.proof.marker:"'"$marker"'" _msg:performance.sidebar.proof_population.completed | fields _msg,agentstudio.performance.sidebar.proof.action.sequence | limit 1'
  local response=""
  while [ -z "$response" ]; do
    kill -0 "$APP_PID" || return 1
    response="$(curl --silent --show-error --max-time 5 "$LOGS_QUERY_URL" --data-urlencode "query=$terminal_query")"
    [ -n "$response" ] || /bin/sleep 1
  done
  printf '%s\n' "$response" >"$population_artifact/action-terminal.jsonl"
  : >"$population_artifact/stop-sampler"
  wait "$CPU_SAMPLER_PID"
  CPU_SAMPLER_PID=""
  query_strict_action_records "$marker" "$records" "$population"
  classify_strict_action_samples "$raw_samples" "$records" "$samples"
  validate_strict_sampler_gaps "$raw_samples"
  finish_strict_population "$population"
}

query_and_validate_strict_workload_receipt() {
  local population="${1:?missing population}"
  local population_artifact="$ARTIFACT/populations/$population"
  local output="$population_artifact/workload-receipt-records.jsonl"
  local query response
  query='{service.name="AgentStudio",dev.runtime.flavor="debug"} agent.proof.marker:"'"$TRACE_MARKER"'" (_msg:performance.sidebar.proof_population.ready OR _msg:performance.sidebar.proof_population.completed OR _msg:performance.sidebar.proof_action.failed OR _msg:performance.sidebar.proof_workload_changed) | fields _msg,outcome,agentstudio.performance.sidebar.proof.terminal_input_baseline,agentstudio.performance.sidebar.proof.terminal_output_baseline,agentstudio.performance.sidebar.proof.ordered_command_baseline,agentstudio.performance.sidebar.proof.terminal_input_completion,agentstudio.performance.sidebar.proof.terminal_output_completion,agentstudio.performance.sidebar.proof.ordered_command_completion | limit 20'
  for _ in $(seq 1 30); do
    response="$(curl --silent --show-error --max-time 5 "$LOGS_QUERY_URL" --data-urlencode "query=$query")"
    if printf '%s\n' "$response" | grep -q 'performance.sidebar.proof_population.completed'; then
      printf '%s\n' "$response" >"$output"
      break
    fi
    /bin/sleep 1
  done
  [ -s "$output" ] || {
    echo "workload receipt completion did not become queryable for $population" >&2
    return 1
  }
  local receipt_json
  receipt_json="$(/usr/bin/python3 - "$output" <<'PY'
import json
import pathlib
import sys

records = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()]
ready = [record for record in records if record.get("_msg") == "performance.sidebar.proof_population.ready"]
completed = [record for record in records if record.get("_msg") == "performance.sidebar.proof_population.completed"]
changed = [record for record in records if record.get("_msg") == "performance.sidebar.proof_workload_changed"]
failed = [record for record in records if record.get("_msg") == "performance.sidebar.proof_action.failed"]
if len(ready) != 1 or len(completed) != 1 or changed or failed:
    raise SystemExit("workload receipt records are missing, duplicated, or invalidated")
prefix = "agentstudio.performance.sidebar.proof."
def exact_counter(record, suffix):
    raw = record.get(prefix + suffix)
    try:
        value = int(float(raw))
    except (TypeError, ValueError):
        raise SystemExit(f"workload receipt missing {suffix}") from None
    if float(raw) != value:
        raise SystemExit(f"workload receipt nonintegral {suffix}")
    return value
receipt = {
    "baseline": {
        "terminal_input": exact_counter(ready[0], "terminal_input_baseline"),
        "terminal_output": exact_counter(ready[0], "terminal_output_baseline"),
        "ordered_command": exact_counter(ready[0], "ordered_command_baseline"),
    },
    "completion": {
        "terminal_input": exact_counter(completed[0], "terminal_input_completion"),
        "terminal_output": exact_counter(completed[0], "terminal_output_completion"),
        "ordered_command": exact_counter(completed[0], "ordered_command_completion"),
    },
}
print(json.dumps(receipt, separators=(",", ":")))
PY
  )"
  validate_strict_workload_receipt_contract "$receipt_json" \
    >"$population_artifact/workload-receipt-validation.txt"
}

finish_strict_population() {
  local population="${1:?missing population}"
  local population_artifact="$ARTIFACT/populations/$population"
  stop_strict_zmx_monitor "$population"
  record_strict_zmx_inventory "$population" complete
  retire_current_candidate
  query_and_validate_strict_workload_receipt "$population"
  reset_disposable_debug_root
  record_strict_zmx_inventory "$population" retired
  local lifecycle_json
  lifecycle_json="$(/usr/bin/python3 - "$population_artifact/zmx-lifecycle.jsonl" <<'PY'
import json
import pathlib
import sys
records = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()]
print(json.dumps(records, separators=(",", ":")))
PY
  )"
  validate_strict_zmx_state_contract "$lifecycle_json" \
    >"$population_artifact/zmx-lifecycle-validation.txt"
}

query_strict_action_records() {
  local marker="${1:?missing marker}"
  local output="${2:?missing output file}"
  local population="${3:?missing population}"
  local query='{service.name="AgentStudio",dev.runtime.flavor="debug"} agent.proof.marker:"'"$marker"'" (_msg:performance.sidebar.proof_action.started OR _msg:performance.sidebar.proof_action.settled OR _msg:performance.sidebar.proof_action.failed OR _msg:performance.sidebar.proof_population.completed) | fields _msg,agentstudio.performance.sidebar.proof.action.sequence,agentstudio.performance.sidebar.proof.monotonic_ns,agentstudio.performance.sidebar.proof.readback.semantic_generation,agentstudio.performance.sidebar.proof.readback.acknowledged_revision,agentstudio.performance.sidebar.proof.readback.visible_generation,agentstudio.performance.sidebar.proof.readback.materialization_fingerprint,agentstudio.performance.sidebar.proof.readback.native_materialization_generation,agentstudio.performance.sidebar.proof.readback.native_materialization_fingerprint,agentstudio.performance.sidebar.proof.readback.native_projection_required,agentstudio.performance.sidebar.proof.readback.native_projection_matches,agentstudio.performance.sidebar.proof.readback.grouping_mode,agentstudio.performance.sidebar.proof.readback.inactive_repository_header.count,agentstudio.performance.sidebar.proof.readback.suppressed_repository_fact_row.count,agentstudio.performance.sidebar.proof.readback.updating_repository_header.count | limit 1000'
  curl --fail --silent --show-error --max-time 10 "$LOGS_QUERY_URL" \
    --data-urlencode "query=$query" >"$output"
  /usr/bin/python3 - "$output" "$STRICT_POLICY_ACTION_COUNT_FLOOR" \
    "$STRICT_POLICY_ACTION_SAMPLE_FLOOR" "$population" <<'PY'
import json, pathlib, sys

path = pathlib.Path(sys.argv[1])
required = max(int(float(sys.argv[2])), int(float(sys.argv[3])))
population = sys.argv[4]
records = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
by_sequence = {}
completed = []
for record in records:
    message = record.get("_msg")
    def exact_integer(raw, name):
        if isinstance(raw, bool):
            raise SystemExit(f"action record invalid integer {name}")
        if isinstance(raw, int):
            return raw
        if isinstance(raw, str):
            try: return int(raw)
            except ValueError:
                raise SystemExit(f"action record invalid integer {name}") from None
        raise SystemExit(f"action record invalid integer {name}")
    sequence = exact_integer(
        record.get("agentstudio.performance.sidebar.proof.action.sequence"), "sequence")
    if message == "performance.sidebar.proof_population.completed":
        completed.append(sequence)
        continue
    if message == "performance.sidebar.proof_action.failed":
        raise SystemExit(f"action population contains failed sequence {sequence}")
    if message not in {
        "performance.sidebar.proof_action.started",
        "performance.sidebar.proof_action.settled",
    }:
        continue
    timestamp = exact_integer(
        record.get("agentstudio.performance.sidebar.proof.monotonic_ns"), "monotonic_ns")
    prefix = "agentstudio.performance.sidebar.proof.readback."
    def exact_int(name):
        raw = record.get(prefix + name)
        return exact_integer(raw, f"readback {name}")
    readback = {
        "semantic": exact_int("semantic_generation"),
        "acknowledged": exact_int("acknowledged_revision"),
        "visible": exact_int("visible_generation"),
        "fingerprint": exact_int("materialization_fingerprint"),
        "native_generation": exact_int("native_materialization_generation"),
        "native_fingerprint": exact_int("native_materialization_fingerprint"),
        "native_required": record.get(prefix + "native_projection_required") in (True, "true"),
        "native_matches": record.get(prefix + "native_projection_matches") in (True, "true"),
        "grouping_mode": record.get(prefix + "grouping_mode"),
        "inactive_headers": exact_int("inactive_repository_header.count"),
        "suppressed_rows": exact_int("suppressed_repository_fact_row.count"),
        "updating_headers": exact_int("updating_repository_header.count"),
    }
    if readback["native_required"] and (
        not readback["native_matches"]
        or readback["native_generation"] != readback["visible"]
        or readback["native_fingerprint"] != readback["fingerprint"]
    ):
        raise SystemExit("action record native readback identity mismatch")
    events = by_sequence.setdefault(sequence, {})
    if message in events:
        raise SystemExit(f"duplicate action record {sequence} {message}")
    events[message] = (timestamp, readback)
if completed != [required]:
    raise SystemExit(f"action population terminal did not satisfy both floors: {completed}")
if sorted(by_sequence) != list(range(1, required + 1)):
    raise SystemExit("action sequence is incomplete or out of order")
prior_settlement = 0
for sequence in range(1, required + 1):
    events = by_sequence[sequence]
    if set(events) != {
        "performance.sidebar.proof_action.started",
        "performance.sidebar.proof_action.settled",
    }:
        raise SystemExit(f"action sequence {sequence} lacks a complete pair")
    started, started_readback = events["performance.sidebar.proof_action.started"]
    settled, settled_readback = events["performance.sidebar.proof_action.settled"]
    if started <= prior_settlement or settled <= started:
        raise SystemExit(f"action sequence {sequence} overlaps or is non-monotonic")
    if population in {"search_clear", "grouping", "grouping_diagnostic"} and not (
        settled_readback["semantic"] > started_readback["semantic"]
        and settled_readback["acknowledged"] > started_readback["acknowledged"]
        and settled_readback["visible"] > started_readback["visible"]
    ):
        raise SystemExit("action settled readback identity did not advance")
    if settled_readback["grouping_mode"] == "repo" and settled_readback["inactive_headers"] <= 0:
        raise SystemExit("By Repo settled readback lacks inactive repository presentation")
    if settled_readback["grouping_mode"] in {"pane", "tab"} and (
        settled_readback["inactive_headers"] != 0 or settled_readback["updating_headers"] != 0
    ):
        raise SystemExit("By Pane/Tab settled readback repeats repository activity controls")
    prior_settlement = settled
PY
}

classify_strict_action_samples() {
  local raw_samples="${1:?missing raw samples}"
  local records="${2:?missing action records}"
  local samples="${3:?missing classified samples}"
  /usr/bin/python3 - "$raw_samples" "$records" "$samples" \
    "$STRICT_POLICY_ACTION_SAMPLE_FLOOR" "$STRICT_POLICY_ACTION_SAMPLE_BOUNDARY_OFFSET_MS" <<'PY'
import json, pathlib, sys

raw_path, records_path, output_path, minimum, maximum_boundary_offset_ms = sys.argv[1:]
minimum = int(float(minimum))
maximum_boundary_offset_ns = float(maximum_boundary_offset_ms) * 1_000_000
actions = {}
for line in pathlib.Path(records_path).read_text().splitlines():
    if not line.strip():
        continue
    record = json.loads(line)
    message = record.get("_msg")
    if message not in {
        "performance.sidebar.proof_action.started",
        "performance.sidebar.proof_action.settled",
    }:
        continue
    sequence = int(float(record["agentstudio.performance.sidebar.proof.action.sequence"]))
    actions.setdefault(sequence, {})[message] = int(
        float(record["agentstudio.performance.sidebar.proof.monotonic_ns"])
    )
intervals = [
    (events["performance.sidebar.proof_action.started"], events["performance.sidebar.proof_action.settled"])
    for _, events in sorted(actions.items())
]
raw_samples = [line for line in pathlib.Path(raw_path).read_text().splitlines() if line.strip()]
parsed_samples = [tuple(map(float, line.split())) for line in raw_samples]
for action_start, _ in intervals:
    candidates = [sample for sample in parsed_samples if sample[0] <= action_start < sample[1]]
    if len(candidates) != 1:
        raise SystemExit("action sample boundary phase is missing or ambiguous")
    boundary_offset_ns = action_start - candidates[0][0]
    if boundary_offset_ns < 0 or boundary_offset_ns > maximum_boundary_offset_ns:
        raise SystemExit(f"action sample boundary offset {boundary_offset_ns:g}ns exceeds policy")
retained = []
covered_actions = set()
for line in raw_samples:
    if not line.strip():
        continue
    fields = line.split()
    if len(fields) != 3:
        raise SystemExit(f"malformed CPU sample: {line}")
    sample_start, sample_end = map(int, fields[:2])
    if sample_end <= sample_start:
        raise SystemExit(f"partial CPU sample: {line}")
    overlaps = {
        index for index, (action_start, action_end) in enumerate(intervals)
        if sample_start < action_end and sample_end > action_start
    }
    if overlaps:
        retained.append(line)
        covered_actions.update(overlaps)
if len(covered_actions) != len(intervals):
    raise SystemExit("one or more actions had no action-bearing CPU interval")
if len(retained) < minimum:
    raise SystemExit("action population terminal did not satisfy both floors")
pathlib.Path(output_path).write_text("\n".join(retained) + "\n")
PY
}

strict_required_record_loss() {
  local population="${1:?missing population}"
  [ -s "$ARTIFACT/populations/$population/workload-receipt-validation.txt" ] || return 1
  [ -s "$ARTIFACT/populations/$population/zmx-lifecycle-validation.txt" ] || return 1
  if printf '%s\n' "$STRICT_POLICY_ACTION_POPULATIONS" | grep -qw "$population" \
    || [ "$population" = "grouping_diagnostic" ]
  then
    local records="$ARTIFACT/populations/$population/action-records.jsonl"
    [ -s "$records" ] || return 1
    # Exact started/settled/terminal validation proves the required records
    # traversed the app exporter and collector into VictoriaLogs.
    printf '0\n'
    return
  fi
  printf '0\n'
}

validate_strict_population() {
  local population="${1:?missing population}"
  local samples="$ARTIFACT/populations/$population/cpu.samples"
  local percentile limit
  if printf '%s\n' "$STRICT_POLICY_IDLE_POPULATIONS" | grep -qw "$population"; then
    percentile="$(nearest_rank_percentile "$samples" 0.99)"; limit="$STRICT_POLICY_IDLE_P99"
  else
    percentile="$(nearest_rank_percentile "$samples" 0.95)"; limit="$STRICT_POLICY_ACTION_P95"
  fi
  /usr/bin/python3 - "$percentile" "$limit" <<'PY'
import sys
value, limit = map(float, sys.argv[1:])
if value >= limit: raise SystemExit(f"population CPU percentile {value} must be below {limit}")
PY
  validate_strict_sampler_gaps "$samples"
  # no sample replacement or trimming: every retained sample belongs to this marker and PID.
}

validate_strict_perturbation_pair() {
  local standard_cpu="${1:?missing standard cpu p95}" diagnostic_cpu="${2:?missing diagnostic cpu p95}"
  local standard_interaction="${3:?missing standard interaction p95}" diagnostic_interaction="${4:?missing diagnostic interaction p95}"
  /usr/bin/python3 - "$standard_cpu" "$diagnostic_cpu" "$standard_interaction" "$diagnostic_interaction" \
    "$STRICT_POLICY_DIAGNOSTIC_CPU_DELTA_MAX" "$STRICT_POLICY_DIAGNOSTIC_INTERACTION_GROWTH_MAX" <<'PY'
import sys
s_cpu, d_cpu, s_time, d_time, cpu_limit, time_limit = map(float, sys.argv[1:])
if d_cpu - s_cpu > cpu_limit: raise SystemExit("diagnostic CPU perturbation exceeded")
if s_time <= 0 or ((d_time - s_time) / s_time * 100) > time_limit: raise SystemExit("diagnostic interaction perturbation exceeded")
PY
}

strict_interaction_p95_ms() {
  local marker="${1:?missing marker}"
  local output="${2:?missing interaction output}"
  local query='{service.name="AgentStudio",dev.runtime.flavor="debug"} agent.proof.marker:"'"$marker"'" (_msg:performance.sidebar.proof_action.started OR _msg:performance.sidebar.proof_action.settled) | fields _msg,agentstudio.performance.sidebar.proof.action.sequence,agentstudio.performance.sidebar.proof.monotonic_ns | limit 1000'
  curl --silent --show-error --max-time 10 "$LOGS_QUERY_URL" --data-urlencode "query=$query" >"$output"
  /usr/bin/python3 - "$output" <<'PY'
import json, math, pathlib, sys
times = {}
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if not line.strip(): continue
    record = json.loads(line); sequence = record.get("agentstudio.performance.sidebar.proof.action.sequence")
    timestamp = record.get("agentstudio.performance.sidebar.proof.monotonic_ns")
    if sequence is None or timestamp is None: continue
    times.setdefault(int(sequence), {})[record.get("_msg")] = int(timestamp)
durations = sorted((pair["performance.sidebar.proof_action.settled"] - pair["performance.sidebar.proof_action.started"]) / 1_000_000 for pair in times.values() if len(pair) == 2)
if not durations: raise SystemExit("missing complete interaction pairs")
print(durations[math.ceil(len(durations) * .95) - 1])
PY
}

run_strict_sidebar_cpu_populations() {
  local specifications=(
    "zero_pty_idle:sidebar-cpu-zero-pty-idle"
    "search_clear:sidebar-cpu-search-clear" "grouping:sidebar-cpu-grouping"
    "hide_show:sidebar-cpu-hide-show" "tab_switch:sidebar-cpu-tab-switch"
  )
  local specification population selector
  for specification in "${specifications[@]}"; do
    population="${specification%%:*}"; selector="${specification#*:}"
    begin_strict_population "$population" "$selector"
    if printf '%s\n' "$STRICT_POLICY_IDLE_POPULATIONS" | grep -qw "$population"; then
      sample_strict_idle_population "$population"
    else
      drive_strict_action_population "$population"
    fi
    validate_strict_population "$population"
    capture_strict_population_loss "$ARTIFACT/populations/$population/loss.env" "$population"
    validate_strict_zero_loss "$ARTIFACT/populations/$population/loss.env"
  done
  local standard_cpu standard_interaction diagnostic_cpu diagnostic_interaction
  standard_cpu="$(nearest_rank_percentile "$ARTIFACT/populations/grouping/cpu.samples" 0.95)"
  standard_interaction="$(strict_interaction_p95_ms \
    "$(cat "$ARTIFACT/populations/grouping/marker.txt")" \
    "$ARTIFACT/populations/grouping/interaction-records.jsonl")"
  begin_strict_population "grouping_diagnostic" "sidebar-cpu-grouping" \
    "$STRICT_POLICY_DIAGNOSTIC_TRACE_TAGS"
  drive_strict_action_population "grouping_diagnostic"
  diagnostic_cpu="$(nearest_rank_percentile "$ARTIFACT/populations/grouping_diagnostic/cpu.samples" 0.95)"
  diagnostic_interaction="$(strict_interaction_p95_ms "$TRACE_MARKER" \
    "$ARTIFACT/populations/grouping_diagnostic/interaction-records.jsonl")"
  validate_strict_perturbation_pair "$standard_cpu" "$diagnostic_cpu" \
    "$standard_interaction" "$diagnostic_interaction"
  capture_strict_population_loss "$ARTIFACT/populations/grouping_diagnostic/loss.env" \
    "grouping_diagnostic"
  validate_strict_zero_loss "$ARTIFACT/populations/grouping_diagnostic/loss.env"
}

metric_result_count() {
  local response="$1"
  /usr/bin/python3 - "$response" <<'PY'
import json
import sys

payload = sys.argv[1]
try:
    data = json.loads(payload)
except json.JSONDecodeError:
    print(0)
    raise SystemExit
print(len(data.get("data", {}).get("result", [])))
PY
}

metric_max_value() {
  local response="$1"
  /usr/bin/python3 - "$response" <<'PY'
import json
import sys

payload = sys.argv[1]
try:
    data = json.loads(payload)
except json.JSONDecodeError:
    raise SystemExit
values = []
for result in data.get("data", {}).get("result", []):
    try:
        values.append(float(result.get("value", [None, ""])[1]))
    except (TypeError, ValueError, IndexError):
        pass
if values:
    print(max(values))
PY
}

metric_value_or_empty() {
  local query="$1"
  local response
  response="$(query_victoria_metrics "$query")"
  metric_max_value "$response"
}

metric_event_elapsed_selector() {
  local surface="$1"
  local phase="$2"
  local group_mode="$3"
  local trigger="$4"
  local event_name="performance.sidebar.projection"
  if [ "$phase" = "row_index" ]; then
    event_name="performance.sidebar.row_index"
  fi
  printf 'agent.proof.marker="%s",event="%s",surface="%s",phase="%s",group_mode="%s",trigger="%s"' \
    "$(metric_label_selector "$TRACE_MARKER")" \
    "$(metric_label_selector "$event_name")" \
    "$(metric_label_selector "$surface")" \
    "$(metric_label_selector "$phase")" \
    "$(metric_label_selector "$group_mode")" \
    "$(metric_label_selector "$trigger")"
}

metric_event_elapsed_max_query() {
  local surface="$1"
  local phase="$2"
  local group_mode="$3"
  local trigger="$4"
  printf 'max(agentstudio_performance_event_elapsed_ms_max{%s})' \
    "$(metric_event_elapsed_selector "$surface" "$phase" "$group_mode" "$trigger")"
}

metric_event_elapsed_p95_query() {
  local surface="$1"
  local phase="$2"
  local group_mode="$3"
  local trigger="$4"
  printf 'histogram_quantile(0.95, sum by (le) (agentstudio_performance_event_elapsed_ms_bucket{%s}))' \
    "$(metric_event_elapsed_selector "$surface" "$phase" "$group_mode" "$trigger")"
}

metric_event_elapsed_count_query() {
  local surface="$1"
  local phase="$2"
  local group_mode="$3"
  local trigger="$4"
  printf 'sum(agentstudio_performance_event_elapsed_ms_bucket{%s,le="+Inf"})' \
    "$(metric_event_elapsed_selector "$surface" "$phase" "$group_mode" "$trigger")"
}

require_metric_value() {
  local key="$1"
  local query="$2"
  local value
  value="$(metric_value_or_empty "$query")"
  if [ -z "$value" ]; then
    echo "missing required sidebar metric series: $key" >&2
    echo "query: $query" >&2
    exit 1
  fi
  printf '%s\n' "$value"
}

wait_for_required_metric_count() {
  local key="$1"
  local query="$2"
  local minimum="$3"
  local attempt
  local value
  for attempt in $(seq 1 "$REQUIRED_METRIC_READBACK_ATTEMPTS"); do
    value="$(metric_value_or_empty "$query")"
    if [ -n "$value" ]; then
      if /usr/bin/python3 - "$value" "$minimum" <<'PY'
import sys

value = float(sys.argv[1])
minimum = float(sys.argv[2])
raise SystemExit(0 if value >= minimum else 1)
PY
      then
        printf '%s\n' "$value"
        return 0
      fi
    fi
    /bin/sleep 2
  done
  echo "missing required sidebar metric sample count: $key >= $minimum" >&2
  echo "query: $query" >&2
  echo "value: ${value:-<missing>}" >&2
  exit 1
}

wait_for_required_metric_value() {
  local key="$1"
  local query="$2"
  local attempt
  local value
  for attempt in $(seq 1 "$REQUIRED_METRIC_READBACK_ATTEMPTS"); do
    value="$(metric_value_or_empty "$query")"
    if [ -n "$value" ]; then
      printf '%s\n' "$value"
      return 0
    fi
    /bin/sleep 2
  done
  require_metric_value "$key" "$query"
}

record_required_metric_value() {
  local key="$1"
  local query="$2"
  local value
  value="$(wait_for_required_metric_value "$key" "$query")"
  printf '%s\n' "$key" >>"$REQUIRED_METRIC_KEYS_FILE"
  printf '%s=%s\n' "$key" "$value" >>"$METRIC_VALUES_FILE"
  eval "$key=\"\$value\""
}

record_required_metric_count() {
  local key="$1"
  local query="$2"
  local minimum="$3"
  local value
  value="$(wait_for_required_metric_count "$key" "$query" "$minimum")"
  printf '%s\n' "$key" >>"$REQUIRED_METRIC_KEYS_FILE"
  printf '%s=%s\n' "$key" "$value" >>"$METRIC_VALUES_FILE"
  eval "$key=\"\$value\""
}

record_required_metric_series() {
  local surface="$1"
  local phase="$2"
  local group_mode="$3"
  local trigger="$4"
  local key_prefix="$5"
  local minimum_count="$6"

  record_required_metric_value "${key_prefix}_elapsed_ms_p95" \
    "$(metric_event_elapsed_p95_query "$surface" "$phase" "$group_mode" "$trigger")"
  record_required_metric_value "${key_prefix}_elapsed_ms_max" \
    "$(metric_event_elapsed_max_query "$surface" "$phase" "$group_mode" "$trigger")"
  record_required_metric_count "${key_prefix}_elapsed_ms_count" \
    "$(metric_event_elapsed_count_query "$surface" "$phase" "$group_mode" "$trigger")" \
    "$minimum_count"
}

record_required_sidebar_metric_matrix() {
  local mode_name
  local phase
  local minimum_count

  : >"$REQUIRED_METRIC_KEYS_FILE"
  : >"$METRIC_VALUES_FILE"

  for mode_name in repo activity; do
    for phase in request_build_mainactor projection_worker row_index mainactor_apply; do
      minimum_count="$REQUIRED_MATERIALIZED_SAMPLE_COUNT"
      if [ "$phase" = "request_build_mainactor" ]; then
        minimum_count="$REQUIRED_SAMPLE_COUNT"
      fi
      record_required_metric_series repo "$phase" "$mode_name" grouping_switch \
        "repos_${mode_name}_${phase}" "$minimum_count"
    done
  done

  for phase in request_build_mainactor projection_worker row_index mainactor_apply; do
    minimum_count="$REQUIRED_MATERIALIZED_SAMPLE_COUNT"
    if [ "$phase" = "request_build_mainactor" ]; then
      minimum_count="$REQUIRED_SAMPLE_COUNT"
    fi
    record_required_metric_series panes "$phase" activity data_refresh \
      "panes_fixed_activity_${phase}" "$minimum_count"
  done

}

metric_env_value() {
  local file="$1"
  local key="$2"
  awk -F= -v key="$key" '$1 == key { value = substr($0, length($1) + 2) } END { if (value != "") print value }' "$file"
}

metric_value_is_nonnegative_finite() {
  local value="$1"
  /usr/bin/python3 - "$value" <<'PY'
import math
import sys

try:
    value = float(sys.argv[1])
except (IndexError, ValueError):
    raise SystemExit(1)
raise SystemExit(0 if math.isfinite(value) and value >= 0 else 1)
PY
}

required_metric_keys_line() {
  tr '\n' ' ' <"$REQUIRED_METRIC_KEYS_FILE" | sed 's/[[:space:]]*$//'
}

append_required_metric_values() {
  local output_file="$1"
  cat "$METRIC_VALUES_FILE" >>"$output_file"
  printf "required_metric_keys='%s'\n" "$(required_metric_keys_line)" >>"$output_file"
}

compare_required_metric_matrix() {
  local baseline_values_file="$1"
  local compare_values_file="$2"
  local key
  local baseline_value
  local compare_value

  for key in $required_metric_keys; do
    baseline_value="$(metric_env_value "$baseline_values_file" "$key")"
    compare_value="$(metric_env_value "$compare_values_file" "$key")"
    if [ -z "$baseline_value" ]; then
      echo "missing baseline required sidebar metric: $key" >&2
      exit 1
    fi
    if [ -z "$compare_value" ]; then
      echo "missing compare required sidebar metric: $key" >&2
      exit 1
    fi
    if ! metric_value_is_nonnegative_finite "$baseline_value"; then
      echo "invalid baseline required sidebar metric: $key" >&2
      exit 1
    fi
    if ! metric_value_is_nonnegative_finite "$compare_value"; then
      echo "invalid compare required sidebar metric: $key" >&2
      exit 1
    fi
    case "$key" in
      *_elapsed_ms_p95 | *_elapsed_ms_max)
        performance_threshold_check "$key" "$baseline_value" "$compare_value"
        ;;
    esac
  done
}

load_baseline_metric_value() {
  local baseline_values_file="$1"
  local key="$2"
  local value
  value="$(metric_env_value "$baseline_values_file" "$key")"
  if ! metric_value_is_nonnegative_finite "$value"; then
    echo "invalid or missing baseline sidebar metric: $key" >&2
    exit 1
  fi
  printf -v "$key" '%s' "$value"
}

validate_compare_baseline_fixture() {
  if [ "$mode" != "compare" ]; then
    return
  fi
  if [ ! -f "$BASELINE_FILE" ]; then
    echo "missing sidebar baseline artifact: $BASELINE_FILE; run --baseline first" >&2
    exit 1
  fi

  local baseline_workload_fixture_key
  local baseline_worktree_fixture_key
  baseline_workload_fixture_key="$(metric_env_value "$BASELINE_FILE" workload_fixture_key)"
  baseline_worktree_fixture_key="$(metric_env_value "$BASELINE_FILE" worktree_fixture_key)"
  if [ "$baseline_workload_fixture_key" != "$WORKLOAD_FIXTURE_KEY" ]; then
    echo "sidebar baseline workload fixture mismatch" >&2
    exit 1
  fi
  if [ "$baseline_worktree_fixture_key" != "$WORKTREE_FIXTURE_KEY" ]; then
    echo "sidebar baseline worktree fixture mismatch" >&2
    exit 1
  fi
}

run_authenticated_sidebar_ipc_workload() {
  local metadata_path="${1:?missing metadata path}"
  local escrow_path="${2:?missing debug escrow path}"
  local sort_direction_receipt_path="$ARTIFACT/repos-sort-direction-receipts.jsonl"
  : >"$sort_direction_receipt_path"
  /usr/bin/python3 - "$metadata_path" "$escrow_path" "$LOGS_QUERY_URL" "$TRACE_MARKER" \
    "$sort_direction_receipt_path" <<'PY'
import datetime
import json
import os
import socket
import sys
import time
import urllib.parse
import urllib.request

metadata_path = sys.argv[1]
escrow_path = sys.argv[2]
logs_query_url = sys.argv[3]
trace_marker = sys.argv[4]
sort_direction_receipt_path = sys.argv[5]
timeout = float(os.environ.get("AGENTSTUDIO_SIDEBAR_IPC_TIMEOUT_SECONDS", "15"))
step_delay = float(os.environ.get("AGENTSTUDIO_SIDEBAR_IPC_STEP_DELAY_SECONDS", "0.35"))
readback_poll_delay = float(os.environ.get("AGENTSTUDIO_SIDEBAR_IPC_READBACK_POLL_SECONDS", "0.01"))
cycles = int(os.environ["AGENTSTUDIO_SIDEBAR_IPC_CYCLES"])

with open(metadata_path, "r", encoding="utf-8") as metadata_file:
    metadata = json.load(metadata_file)
socket_path = metadata.get("socketPath")
if not socket_path:
    print(f"IPC metadata missing socketPath: {metadata_path}", file=sys.stderr)
    sys.exit(1)
with open(escrow_path, "r", encoding="utf-8") as escrow_file:
    escrow = json.load(escrow_file)
token = escrow.get("token")
if not isinstance(token, str) or not token:
    print(f"IPC debug escrow has no token: AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW={escrow_path}", file=sys.stderr)
    sys.exit(1)
if (escrow.get("socketPath") != socket_path or not escrow.get("runtimeId")
        or escrow.get("runtimeId") != metadata.get("runtimeId")):
    print("AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW does not match IPC metadata", file=sys.stderr)
    sys.exit(1)


class Session:
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(timeout)
        self.socket.connect(path)
        self.reader = self.socket.makefile("rb")

    def close(self):
        self.reader.close()
        self.socket.close()

    def request(self, request_id, method, params):
        payload = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        self.socket.sendall((json.dumps(payload, separators=(",", ":")) + "\n").encode("utf-8"))
        while True:
            line = self.reader.readline()
            if not line:
                print(f"IPC socket closed before response for {method}", file=sys.stderr)
                sys.exit(1)
            response = json.loads(line.decode("utf-8"))
            if response.get("id") == request_id:
                return response


def require_success(response, label):
    if response.get("error") is not None:
        print(f"{label} failed: {response['error']}", file=sys.stderr)
        sys.exit(1)
    return response.get("result", {})


def require_error(response, label, expected_code, expected_message):
    error = response.get("error")
    if error is None:
        print(f"{label} unexpectedly succeeded: {response.get('result', {})}", file=sys.stderr)
        sys.exit(1)
    if error.get("code") != expected_code or error.get("message") != expected_message:
        print(f"{label} returned unexpected error: {error}", file=sys.stderr)
        sys.exit(1)


def marker_records():
    query = f'agent.proof.marker:="{trace_marker}"'
    url = logs_query_url + "?" + urllib.parse.urlencode({"query": query})
    with urllib.request.urlopen(url, timeout=10) as response:
        lines = response.read().decode().splitlines()
    records = []
    for line in lines:
        if not line.strip():
            continue
        decoded = json.loads(line)
        records.extend(decoded if isinstance(decoded, list) else [decoded])
    return records


def record_time_ns(record):
    timestamp = str(record.get("_time", "")).replace("Z", "+00:00")
    parsed = datetime.datetime.strptime(timestamp, "%Y-%m-%dT%H:%M:%S.%f%z")
    return int(parsed.timestamp() * 1_000_000_000)


def latest_completed_sidebar_projection(surface):
    matching = [
        record for record in marker_records()
        if record.get("_msg") == "performance.sidebar.projection"
        and record.get("agentstudio.performance.sidebar.surface") == surface
        and record.get("agentstudio.performance.sidebar.phase") == "projection_worker"
    ]
    if not matching:
        return None
    return max(matching, key=record_time_ns)


def wait_for_sidebar_projection(surface, expected_grouping=None, expected_sort_order=None, after_ns=0):
    deadline = time.monotonic() + timeout
    latest = None
    while time.monotonic() < deadline:
        latest = latest_completed_sidebar_projection(surface)
        if latest is not None and record_time_ns(latest) > after_ns:
            grouping = latest.get("agentstudio.performance.sidebar.group_mode")
            sort_order = latest.get("agentstudio.performance.sidebar.sort_order")
            if (expected_grouping is None or grouping == expected_grouping) and (
                expected_sort_order is None or sort_order == expected_sort_order
            ):
                return latest
        if readback_poll_delay > 0:
            time.sleep(readback_poll_delay)
    print(
        "sidebar projection readiness timed out: "
        f"surface={surface} grouping={expected_grouping} sort_order={expected_sort_order} latest={latest}",
        file=sys.stderr,
    )
    sys.exit(1)


session = Session(socket_path)
try:
    require_success(session.request(1, "auth.login", {"token": token}), "auth.login")
    # IPC v2 escrow is reusable until shutdown (IPC escrow and startup diagnostics).
    if not os.path.isfile(escrow_path):
        print(f"IPC debug escrow disappeared: AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW={escrow_path}", file=sys.stderr)
        sys.exit(1)
    replay = Session(socket_path)
    try:
        replay_result = require_success(replay.request(900, "auth.login", {"token": token}), "auth.login replay")
        if replay_result.get("authenticated") is not True:
            print("auth.login replay did not authenticate", file=sys.stderr)
            sys.exit(1)
    finally:
        replay.close()

    tampered_token = ("A" if token[0] != "A" else "B") + token[1:]
    denied_session = Session(socket_path)
    try:
        require_error(denied_session.request(901, "auth.login", {"token": tampered_token}),
                      "auth.login tampered credential", -32001, "unauthenticated")
    finally:
        denied_session.close()

    request_id = [2]

    def next_id():
        current = request_id[0]
        request_id[0] += 1
        return current

    def execute_sidebar_command(command_id, arguments, label):
        result = require_success(
            session.request(
                next_id(),
                "command.execute",
                {
                    "commandId": command_id,
                    "targetHandle": None,
                    "arguments": arguments,
                },
            ),
            label,
        )
        if result.get("applied") is not True:
            print(f"{label} did not apply: {result}", file=sys.stderr)
            sys.exit(1)
        return result

    def pace_projection_application():
        if step_delay > 0:
            time.sleep(step_delay)

    retired_panes_organization_commands = {
        "setPanesSortFieldName",
        "setPanesSortFieldActivity",
        "togglePanesSortDirection",
    }
    removed_panes_organization_commands = {
        "setPanesGroupingRepo", "setPanesGroupingTab", "setPanesGroupingActivity",
        "setPanesSubgroupNone", "setPanesSubgroupActivity",
    }
    command_list = require_success(
        session.request(next_id(), "command.list", {}),
        "command.list",
    )
    commands_by_id = {command.get("id"): command for command in command_list.get("commands", [])}
    for command_id in removed_panes_organization_commands:
        if command_id in commands_by_id:
            print(f"removed Panes command remains in command.list: {command_id}", file=sys.stderr)
            sys.exit(1)
    for command_id in sorted(retired_panes_organization_commands):
        command_entry = commands_by_id.get(command_id)
        if command_entry is None:
            print(f"command.list omitted retained retired command {command_id}", file=sys.stderr)
            sys.exit(1)
        if command_entry.get("executionModes") != [] or command_entry.get("requiredPrivileges") != []:
            print(f"retired command retained IPC authority: {command_entry}", file=sys.stderr)
            sys.exit(1)

    def assert_fixed_panes_projection(projection, label):
        grouping = projection.get("agentstudio.performance.sidebar.group_mode")
        sort_order = projection.get("agentstudio.performance.sidebar.sort_order")
        if grouping != "activity" or sort_order != "descending":
            print(
                f"{label} violated fixed Panes activity/descending/no-subgroup policy: {projection}",
                file=sys.stderr,
            )
            sys.exit(1)

    def reject_retired_panes_organization_commands():
        before = wait_for_sidebar_projection("panes")
        assert_fixed_panes_projection(before, "Panes projection before retired commands")
        for command_id in sorted(retired_panes_organization_commands):
            require_error(
                session.request(
                    next_id(),
                    "command.execute",
                    {"commandId": command_id, "targetHandle": None, "arguments": {}},
                ),
                f"command.execute retired {command_id}",
                -32007,
                "parameters required",
            )
        after = wait_for_sidebar_projection("panes")
        assert_fixed_panes_projection(after, "Panes projection after retired commands")
        for attribute in (
            "agentstudio.performance.sidebar.group_mode",
            "agentstudio.performance.sidebar.sort_order",
        ):
            if after.get(attribute) != before.get(attribute):
                print(
                    f"retired Panes organization commands mutated {attribute}: before={before} after={after}",
                    file=sys.stderr,
                )
                sys.exit(1)

    def set_repo_grouping(mode):
        command_by_grouping = {
            "repo": "setReposGroupingRepo",
            "activity": "setReposGroupingActivity",
        }
        command_id = command_by_grouping.get(mode)
        if command_id is None:
            print(f"unsupported Repos grouping command: mode={mode}", file=sys.stderr)
            sys.exit(1)
        previous_projection = wait_for_sidebar_projection("repo")
        previous_grouping = previous_projection.get("agentstudio.performance.sidebar.group_mode")
        execute_sidebar_command(command_id, {}, f"command.execute {command_id}")
        if previous_grouping != mode:
            wait_for_sidebar_projection(
                "repo",
                expected_grouping=mode,
                after_ns=record_time_ns(previous_projection),
            )
        pace_projection_application()

    def toggle_repos_sort_direction_pair():
        initial_projection = wait_for_sidebar_projection("repo", expected_grouping="repo")
        initial_order = initial_projection.get("agentstudio.performance.sidebar.sort_order")
        if initial_order not in {"ascending", "descending"}:
            print(f"invalid initial Repos sort order: {initial_projection}", file=sys.stderr)
            sys.exit(1)
        opposite_order = "descending" if initial_order == "ascending" else "ascending"
        first_toggle_result = execute_sidebar_command(
            "toggleReposSortDirection",
            {},
            "command.execute toggleReposSortDirection first toggle",
        )
        opposite_projection = wait_for_sidebar_projection(
            "repo",
            expected_grouping="repo",
            expected_sort_order=opposite_order,
            after_ns=record_time_ns(initial_projection),
        )
        second_toggle_result = execute_sidebar_command(
            "toggleReposSortDirection",
            {},
            "command.execute toggleReposSortDirection second toggle",
        )
        restored_projection = wait_for_sidebar_projection(
            "repo",
            expected_grouping="repo",
            expected_sort_order=initial_order,
            after_ns=record_time_ns(opposite_projection),
        )
        with open(sort_direction_receipt_path, "a", encoding="utf-8") as receipt_file:
            receipt_file.write(json.dumps({
                "initial": initial_order,
                "opposite": opposite_order,
                "restored": restored_projection.get("agentstudio.performance.sidebar.sort_order"),
                "firstApplied": first_toggle_result.get("applied"),
                "secondApplied": second_toggle_result.get("applied"),
            }, sort_keys=True) + "\n")
        pace_projection_application()

    def toggle_panes_shows_pinned_pair():
        initial_projection = wait_for_sidebar_projection("panes")
        assert_fixed_panes_projection(initial_projection, "Panes projection before Show Pinned toggle")
        execute_sidebar_command(
            "togglePanesShowsPinned",
            {},
            "command.execute togglePanesShowsPinned first toggle",
        )
        toggled_projection = wait_for_sidebar_projection(
            "panes",
            expected_grouping="activity",
            expected_sort_order="descending",
            after_ns=record_time_ns(initial_projection),
        )
        assert_fixed_panes_projection(toggled_projection, "Panes projection after first Show Pinned toggle")
        execute_sidebar_command(
            "togglePanesShowsPinned",
            {},
            "command.execute togglePanesShowsPinned second toggle",
        )
        restored_projection = wait_for_sidebar_projection(
            "panes",
            expected_grouping="activity",
            expected_sort_order="descending",
            after_ns=record_time_ns(toggled_projection),
        )
        assert_fixed_panes_projection(restored_projection, "Panes projection after second Show Pinned toggle")
        pace_projection_application()

    execute_sidebar_command("showPanesSidebar", {}, "command.execute showPanesSidebar")
    initial_panes_projection = wait_for_sidebar_projection("panes")
    assert_fixed_panes_projection(initial_panes_projection, "initial Panes projection")
    reject_retired_panes_organization_commands()

    for _ in range(cycles):
        execute_sidebar_command("showPanesSidebar", {}, "command.execute showPanesSidebar")
        wait_for_sidebar_projection("panes", expected_grouping="activity", expected_sort_order="descending")
        toggle_panes_shows_pinned_pair()
        execute_sidebar_command("showReposSidebar", {}, "command.execute showReposSidebar")
        wait_for_sidebar_projection("repo")
        for _ in range(3):
            set_repo_grouping("activity")
            set_repo_grouping("repo")
            toggle_repos_sort_direction_pair()
finally:
    session.close()
PY
  local expected_sort_direction_receipt_count=$((AGENTSTUDIO_SIDEBAR_IPC_CYCLES * 3))
  local actual_sort_direction_receipt_count
  actual_sort_direction_receipt_count="$(wc -l <"$sort_direction_receipt_path" | tr -d '[:space:]')"
  if [ "$actual_sort_direction_receipt_count" != "$expected_sort_direction_receipt_count" ]; then
    echo "Repos sort direction receipt count mismatch: expected=$expected_sort_direction_receipt_count actual=$actual_sort_direction_receipt_count" >&2
    return 1
  fi
}

run_repo_explorer_key_mutation_phase() {
  : "${APP_PID:?missing first phase app pid}"
  retire_current_candidate
  reset_disposable_debug_root

  TRACE_MARKER="$TRACE_MARKER_K"
  env \
    AGENTSTUDIO_DEBUG_DATA_DIR="$STRICT_DISPOSABLE_DATA_ROOT" \
    AGENTSTUDIO_TRACE_FLUSH=immediate \
    AGENTSTUDIO_TRACE_TAGS="$KEY_MUTATION_TRACE_TAGS" \
    AGENTSTUDIO_TRACE_NAME="$TRACE_MARKER" \
    AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION=repo-explorer-key-mutation-proof \
    AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$STATE_FILE" \
    "$DEBUG_RUNNER" --detach

  AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$STATE_FILE" \
    wait_for_debug_observability
  APP_PID="$(decode_env_file_value "$STATE_FILE" AGENTSTUDIO_OBSERVABILITY_PID)"
  TRACE_MARKER="$TRACE_MARKER_W"
}

run_repo_explorer_interaction_phase() {
  wait_for_required_metric_count keyed_wake_key_mutation_completion \
    "sum(agentstudio_performance_events_total{agent.proof.marker=\"$(metric_label_selector "$TRACE_MARKER_K")\",event=\"performance.repo_explorer.keyed_wake\",key_class=\"missing_declared_key\",stage=\"membership_path\"})" \
    "$WORKLOAD_CYCLES" >/dev/null
  : "${APP_PID:?missing key phase app pid}"
  retire_current_candidate
  reset_disposable_debug_root
  TRACE_MARKER="$TRACE_MARKER_I"
  env \
    AGENTSTUDIO_DEBUG_DATA_DIR="$STRICT_DISPOSABLE_DATA_ROOT" \
    AGENTSTUDIO_TRACE_FLUSH=immediate \
    AGENTSTUDIO_TRACE_TAGS="$WORKLOAD_TRACE_TAGS" \
    AGENTSTUDIO_TRACE_NAME="$TRACE_MARKER" \
    AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION=repo-explorer-interaction-proof \
    AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$STATE_FILE" \
    "$DEBUG_RUNNER" --detach
  AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$STATE_FILE" wait_for_debug_observability
  APP_PID="$(decode_env_file_value "$STATE_FILE" AGENTSTUDIO_OBSERVABILITY_PID)"
  TRACE_MARKER="$TRACE_MARKER_W"
}

performance_threshold_check() {
  local label="${1:?missing label}"
  local baseline_value="${2:?missing baseline value}"
  local compare_value="${3:?missing compare value}"
  /usr/bin/python3 - "$label" "$baseline_value" "$compare_value" <<'PY'
import sys

label, baseline_raw, compare_raw = sys.argv[1], sys.argv[2], sys.argv[3]
baseline = float(baseline_raw)
compare = float(compare_raw)
threshold = max(baseline * 2.0, baseline + 25.0)
if compare > threshold:
    print(f"{label} regressed: baseline={baseline:.3f}ms compare={compare:.3f}ms threshold={threshold:.3f}ms", file=sys.stderr)
    sys.exit(1)
PY
}

ratio_value() {
  local numerator="${1:?missing numerator}"
  local denominator="${2:?missing denominator}"
  /usr/bin/python3 - "$numerator" "$denominator" <<'PY'
import sys
numerator, denominator = map(float, sys.argv[1:])
print(0 if denominator == 0 else numerator / denominator)
PY
}

require_exact_fixture_count() {
  local label="${1:?missing fixture label}"
  local actual="${2:?missing fixture actual}"
  local expected="${3:?missing fixture expected}"
  if [ "$actual" != "$expected" ] && [ "$actual" != "${expected}.0" ]; then
    echo "$label expected $expected, got ${actual:-<missing>}" >&2
    exit 1
  fi
}

wait_for_debug_observability() {
  local attempt
  for attempt in $(seq 1 45); do
    if AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$STATE_FILE" \
      "$PROJECT_ROOT/scripts/verify-debug-observability.sh" >/dev/null; then
      return 0
    fi
    /bin/sleep 2
  done
  AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$STATE_FILE" \
    "$PROJECT_ROOT/scripts/verify-debug-observability.sh"
}

wait_for_sidebar_metric_count() {
  local attempt
  local metrics_response
  local metrics_count
  for attempt in $(seq 1 45); do
    metrics_response="$(query_victoria_metrics "$sidebar_metric_query")"
    metrics_count="$(metric_result_count "$metrics_response")"
    if [ "$metrics_count" != "0" ]; then
      printf '%s\n%s\n' "$metrics_count" "$metrics_response"
      return 0
    fi
    /bin/sleep 2
  done
  metrics_response="$(query_victoria_metrics "$sidebar_metric_query")"
  metrics_count="$(metric_result_count "$metrics_response")"
  printf '%s\n%s\n' "$metrics_count" "$metrics_response"
}

wait_for_sidebar_metric_value() {
  local query="$1"
  local attempt
  local metrics_response
  local metrics_count
  local metrics_value
  for attempt in $(seq 1 45); do
    metrics_response="$(query_victoria_metrics "$query")"
    metrics_count="$(metric_result_count "$metrics_response")"
    if [ "$metrics_count" != "0" ]; then
      metrics_value="$(metric_max_value "$metrics_response")"
      printf '%s\n%s\n%s\n' "$metrics_count" "$metrics_value" "$metrics_response"
      return 0
    fi
    /bin/sleep 2
  done
  metrics_response="$(query_victoria_metrics "$query")"
  metrics_count="$(metric_result_count "$metrics_response")"
  metrics_value="$(metric_max_value "$metrics_response")"
  printf '%s\n%s\n%s\n' "$metrics_count" "$metrics_value" "$metrics_response"
}

keyed_wake_count() {
  local key_class="${1:?missing key class}"
  local stage="${2:?missing stage}"
  local selector='agent.proof.marker="'"$(metric_label_selector "$TRACE_MARKER_K")"'",event="performance.repo_explorer.keyed_wake",key_class="'"$key_class"'",stage="'"$stage"'"'
  local response
  local value
  response="$(query_victoria_metrics "sum(agentstudio_performance_events_total{$selector})")"
  value="$(metric_max_value "$response")"
  printf '%s\n' "${value:-0}"
}

keyed_wake_outcome_count() {
  local stage="${1:?missing stage}"
  local outcome="${2:?missing outcome}"
  local selector='agent.proof.marker="'"$(metric_label_selector "$TRACE_MARKER_K")"'",event="performance.repo_explorer.keyed_wake",stage="'"$stage"'",outcome="'"$outcome"'"'
  local response
  local value
  response="$(query_victoria_metrics "sum(agentstudio_performance_events_total{$selector})")"
  value="$(metric_max_value "$response")"
  printf '%s\n' "${value:-0}"
}

keyed_wake_stage_count() {
  local stage="${1:?missing stage}"
  local selector='agent.proof.marker="'"$(metric_label_selector "$TRACE_MARKER_K")"'",event="performance.repo_explorer.keyed_wake",stage="'"$stage"'"'
  local response
  local value
  response="$(query_victoria_metrics "sum(agentstudio_performance_events_total{$selector})")"
  value="$(metric_max_value "$response")"
  printf '%s\n' "${value:-0}"
}

assert_keyed_wake_contract() {
  local key_class="${1:?missing key class}"
  local stage="${2:?missing stage}"
  local expected="${3:?missing expected count}"
  local actual
  actual="$(keyed_wake_count "$key_class" "$stage")"
  if [ "$expected" = "bounded" ]; then
    /usr/bin/python3 - "$key_class" "$stage" "$actual" "$WORKLOAD_CYCLES" <<'PY'
import sys
key_class, stage, actual, limit = sys.argv[1], sys.argv[2], float(sys.argv[3]), int(sys.argv[4])
if actual < 1 or actual > limit:
    raise SystemExit(f"{key_class} {stage} expected 1..{limit}, got {actual:g}")
PY
    return
  fi
  if [ "$actual" != "$expected" ] && [ "$actual" != "${expected}.0" ]; then
    echo "$key_class $stage expected $expected, got $actual" >&2
    exit 1
  fi
}

validate_controls
validate_workload_cycles

PROOF_ROOT="${AGENTSTUDIO_SIDEBAR_PROOF_ROOT:-$DEFAULT_PROOF_ROOT}"
TRACE_NAME="$(validate_trace_name "${AGENTSTUDIO_TRACE_NAME:-s-$(date +%s)-$$}")"
TRACE_NONCE="$(/usr/bin/uuidgen)"
TRACE_MARKER_W="$(opaque_trace_marker "${TRACE_NAME}-w" "$TRACE_NONCE")"
TRACE_MARKER_K="$(opaque_trace_marker "${TRACE_NAME}-k" "$(/usr/bin/uuidgen)")"
TRACE_MARKER_I="$(opaque_trace_marker "${TRACE_NAME}-i" "$(/usr/bin/uuidgen)")"
TRACE_MARKER="$TRACE_MARKER_W"
ARTIFACT="$PROOF_ROOT/$TRACE_NAME"
STRICT_DISPOSABLE_DATA_ROOT="$ARTIFACT/d"
STATE_FILE="${AGENTSTUDIO_OBSERVABILITY_STATE_FILE:-$ARTIFACT/debug-observability.env}"
SUMMARY_FILE="$ARTIFACT/summary.txt"
REQUIRED_METRIC_KEYS_FILE="$ARTIFACT/required-metric-keys.txt"
METRIC_VALUES_FILE="$ARTIFACT/metric-values.env"
KEYED_WAKE_VALUES_FILE="$ARTIFACT/keyed-wake-values.env"
BASELINE_FILE="$PROOF_ROOT/sidebar-performance-baseline.env"
WORKTREE_FIXTURE_KEY="$(hashed_identity "repos=$REQUIRED_REPOSITORY_COUNT:worktrees=$REQUIRED_WORKTREE_COUNT:tabs=$REQUIRED_TAB_COUNT:panes=$REQUIRED_PANE_COUNT:active_ptys=$REQUIRED_ACTIVE_PTY_COUNT")"
WORKLOAD_FIXTURE_KEY="$(hashed_identity "$WORKLOAD_FIXTURE_VERSION:cycles=$WORKLOAD_CYCLES:tags=$WORKLOAD_TRACE_TAGS:backend=otlp")"
validate_compare_baseline_fixture

# macOS sockaddr_un allows 103 pathname bytes. Fresh proof sessions use 36-byte UUIDv7 names.
# Validate the canonical path before launch/reset; /tmp may resolve to /private/tmp.
if [ "$mode" != "prepare-only" ]; then
  /usr/bin/python3 - "$STRICT_DISPOSABLE_DATA_ROOT/z" <<'PY_SOCKET_PATH'
import os
import sys

socket_path = os.path.realpath(sys.argv[1]) + "/" + "0" * 36
path_bytes = len(os.fsencode(socket_path))
if path_bytes > 103:
    raise SystemExit(
        f"zmx proof socket path requires {path_bytes} bytes; macOS maximum is 103. "
        "Use a shorter AGENTSTUDIO_SIDEBAR_PROOF_ROOT or AGENTSTUDIO_TRACE_NAME."
    )
PY_SOCKET_PATH
fi
mkdir -p "$ARTIFACT" "$(dirname "$STATE_FILE")"
IPC_DEBUG_ESCROW_PATH="$(/usr/bin/python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$ARTIFACT/ipc-escrow.json")"

sidebar_metric_query='agentstudio_performance_events_total{agent.proof.marker="'$(metric_label_selector "$TRACE_MARKER")'",event="performance.sidebar.projection",surface="repo",phase=~"startup_diagnostic|request_build_mainactor|mainactor_apply|projection_worker|row_index"}'

if [ "$mode" = "prepare-only" ]; then
  if [ -n "${AGENTSTUDIO_SIDEBAR_TEST_BLOCKED_FIXTURE_RESPONSE:-}" ]; then
    [ "${AGENTSTUDIO_SIDEBAR_ALLOW_TEST_RESPONSES:-0}" = "1" ] || {
      echo "blocked fixture response test requires canned test-response authorization" >&2
      exit 2
    }
    report_strict_sidebar_fixture_blocked "$AGENTSTUDIO_SIDEBAR_TEST_BLOCKED_FIXTURE_RESPONSE"
    exit $?
  fi
  if [ -n "${AGENTSTUDIO_SIDEBAR_TEST_CONTROL_ROOT:-}" ]; then
    [ "${AGENTSTUDIO_SIDEBAR_ALLOW_TEST_RESPONSES:-0}" = "1" ] || {
      echo "continuity control test requires canned test-response authorization" >&2
      exit 2
    }
    RESET_DATA_DIR="$(dirname "$AGENTSTUDIO_SIDEBAR_TEST_CONTROL_ROOT")"
    prepare_strict_git_continuity_control "$AGENTSTUDIO_SIDEBAR_TEST_CONTROL_ROOT"
    inject_strict_git_continuity_uncertainty "$AGENTSTUDIO_SIDEBAR_TEST_CONTROL_ROOT"
    printf 'continuity_control_clean=true\ncontinuity_ignored_file_present=true\n'
    exit 0
  fi
  if [ -n "${AGENTSTUDIO_SIDEBAR_TEST_CONTINUITY_DELTAS:-}" ]; then
    [ "${AGENTSTUDIO_SIDEBAR_ALLOW_TEST_RESPONSES:-0}" = "1" ] || {
      echo "continuity delta test requires canned test-response authorization" >&2
      exit 2
    }
    IFS=',' read -r -a continuity_delta_values <<<"$AGENTSTUDIO_SIDEBAR_TEST_CONTINUITY_DELTAS"
    validate_strict_git_continuity_delta_values "${continuity_delta_values[@]}"
    exit 0
  fi
  if [ -n "${AGENTSTUDIO_SIDEBAR_TEST_POLICY_RECORD:-}" ]; then
    [ "${AGENTSTUDIO_SIDEBAR_ALLOW_TEST_RESPONSES:-0}" = "1" ] || {
      echo "policy record test requires canned test-response authorization" >&2
      exit 2
    }
    policy_record_test_file="$ARTIFACT/test-policy-record.jsonl"
    policy_record_environment="$ARTIFACT/test-policy-record.env"
    printf '%s\n' "$AGENTSTUDIO_SIDEBAR_TEST_POLICY_RECORD" >"$policy_record_test_file"
    parse_strict_sidebar_policy "$policy_record_test_file" "$policy_record_environment"
    cat "$policy_record_environment"
    exit 0
  fi
  if [ -n "${AGENTSTUDIO_SIDEBAR_TEST_FIXTURE_RECORD:-}" ]; then
    [ "${AGENTSTUDIO_SIDEBAR_ALLOW_TEST_RESPONSES:-0}" = "1" ] || {
      echo "fixture record test requires canned test-response authorization" >&2
      exit 2
    }
    fixture_record_test_file="$ARTIFACT/test-fixture-record.jsonl"
    fixture_record_environment="$ARTIFACT/test-fixture-record.env"
    printf '%s\n' "$AGENTSTUDIO_SIDEBAR_TEST_FIXTURE_RECORD" >"$fixture_record_test_file"
    validate_and_bind_strict_sidebar_fixture \
      "$fixture_record_test_file" "${AGENTSTUDIO_SIDEBAR_TEST_FIXTURE_POPULATION:-zero_pty_idle}" \
      "$fixture_record_environment"
    cat "$fixture_record_environment"
    exit 0
  fi
  if [ -n "${AGENTSTUDIO_SIDEBAR_TEST_DEBUG_PROCESS_RECORDS:-}" ]; then
    [ "${AGENTSTUDIO_SIDEBAR_ALLOW_TEST_RESPONSES:-0}" = "1" ] || {
      echo "debug process test requires canned test-response authorization" >&2
      exit 2
    }
    validate_no_debug_owned_helpers_json \
      "$AGENTSTUDIO_SIDEBAR_TEST_DEBUG_PROCESS_RECORDS" \
      "${AGENTSTUDIO_SIDEBAR_TEST_DEBUG_APP_PID:?missing debug app PID}"
    exit 0
  fi
  if [ -n "${AGENTSTUDIO_SIDEBAR_TEST_ZMX_STATE_SEQUENCE:-}" ]; then
    [ "${AGENTSTUDIO_SIDEBAR_ALLOW_TEST_RESPONSES:-0}" = "1" ] || {
      echo "zmx state test requires canned test-response authorization" >&2
      exit 2
    }
    validate_strict_zmx_state_contract "$AGENTSTUDIO_SIDEBAR_TEST_ZMX_STATE_SEQUENCE"
    exit 0
  fi
  if [ -n "${AGENTSTUDIO_SIDEBAR_TEST_WORKLOAD_RECEIPT:-}" ]; then
    [ "${AGENTSTUDIO_SIDEBAR_ALLOW_TEST_RESPONSES:-0}" = "1" ] || {
      echo "workload receipt test requires canned test-response authorization" >&2
      exit 2
    }
    validate_strict_workload_receipt_contract "$AGENTSTUDIO_SIDEBAR_TEST_WORKLOAD_RECEIPT"
    exit 0
  fi
  if [ -n "${AGENTSTUDIO_SIDEBAR_TEST_METRIC_OBSERVATION_TIME:-}" ]; then
    [ "${AGENTSTUDIO_SIDEBAR_ALLOW_TEST_RESPONSES:-0}" = "1" ] || {
      echo "metric observation test requires canned test-response authorization" >&2
      exit 2
    }
    metric_value_at_observation \
      "sum(agentstudio_performance_events_total)" \
      "$AGENTSTUDIO_SIDEBAR_TEST_METRIC_OBSERVATION_TIME"
    exit 0
  fi
  if [ -n "${AGENTSTUDIO_SIDEBAR_TEST_PERIODIC_COMPLETION_BASELINE:-}" ]; then
    [ "${AGENTSTUDIO_SIDEBAR_ALLOW_TEST_RESPONSES:-0}" = "1" ] || {
      echo "periodic completion test requires canned test-response authorization" >&2
      exit 2
    }
    validate_strict_periodic_completion_delta \
      "$AGENTSTUDIO_SIDEBAR_TEST_PERIODIC_COMPLETION_BASELINE" \
      "${AGENTSTUDIO_SIDEBAR_TEST_PERIODIC_COMPLETION_FINAL:?missing final periodic completion count}"
    exit 0
  fi
  if [ -n "${AGENTSTUDIO_SIDEBAR_TEST_FINAL_GIT_SETTLEMENT_VECTOR:-}" ]; then
    [ "${AGENTSTUDIO_SIDEBAR_ALLOW_TEST_RESPONSES:-0}" = "1" ] || {
      echo "final Git settlement test requires canned test-response authorization" >&2
      exit 2
    }
    strict_final_git_settlement_from_json \
      "$AGENTSTUDIO_SIDEBAR_TEST_FINAL_GIT_SETTLEMENT_VECTOR"
    exit 0
  fi
  if [ -n "${AGENTSTUDIO_SIDEBAR_TEST_QUIESCENCE_SEQUENCE:-}" ]; then
    [ "${AGENTSTUDIO_SIDEBAR_ALLOW_TEST_RESPONSES:-0}" = "1" ] || {
      echo "quiescence test sequence requires canned test-response authorization" >&2
      exit 2
    }
    validate_strict_test_quiescence_sequence "$AGENTSTUDIO_SIDEBAR_TEST_QUIESCENCE_SEQUENCE"
    exit 0
  fi
  if [ -n "${AGENTSTUDIO_SIDEBAR_TEST_ACTION_SAMPLES:-}" ]; then
    [ "${AGENTSTUDIO_SIDEBAR_ALLOW_TEST_RESPONSES:-0}" = "1" ] || {
      echo "action sample test requires canned test-response authorization" >&2
      exit 2
    }
    action_samples_file="$ARTIFACT/test-action.samples"
    action_records_file="$ARTIFACT/test-action-records.jsonl"
    action_output_file="$ARTIFACT/test-action-classified.samples"
    printf '%s\n' "$AGENTSTUDIO_SIDEBAR_TEST_ACTION_SAMPLES" >"$action_samples_file"
    /usr/bin/python3 - "$AGENTSTUDIO_SIDEBAR_TEST_ACTION_RECORDS" "$action_records_file" <<'PY'
import json
import pathlib
import sys
records = []
for item in sys.argv[1].split(","):
    timestamp, message = item.split(":", 1)
    records.append({
        "_msg": message,
        "agentstudio.performance.sidebar.proof.action.sequence": 1,
        "agentstudio.performance.sidebar.proof.monotonic_ns": int(timestamp),
    })
pathlib.Path(sys.argv[2]).write_text("".join(json.dumps(record) + "\n" for record in records))
PY
    classify_strict_action_samples "$action_samples_file" "$action_records_file" "$action_output_file"
    exit 0
  fi
  if [ -n "${AGENTSTUDIO_SIDEBAR_TEST_DESCENDANT_POLL_SEQUENCE:-}" ]; then
    [ "${AGENTSTUDIO_SIDEBAR_ALLOW_TEST_RESPONSES:-0}" = "1" ] || {
      echo "descendant poll test requires canned test-response authorization" >&2
      exit 2
    }
    validate_strict_descendant_poll_sequence "$AGENTSTUDIO_SIDEBAR_TEST_DESCENDANT_POLL_SEQUENCE"
    exit 0
  fi
  if [ -n "${AGENTSTUDIO_SIDEBAR_TEST_SAMPLER_SEQUENCE:-}" ]; then
    [ "${AGENTSTUDIO_SIDEBAR_ALLOW_TEST_RESPONSES:-0}" = "1" ] || {
      echo "sampler sequence test requires canned test-response authorization" >&2
      exit 2
    }
    sampler_sequence_file="$ARTIFACT/test-sampler-sequence.samples"
    printf '%s\n' "$AGENTSTUDIO_SIDEBAR_TEST_SAMPLER_SEQUENCE" >"$sampler_sequence_file"
    validate_strict_sampler_gaps "$sampler_sequence_file"
    exit 0
  fi
  metrics_response="$(query_victoria_metrics "$sidebar_metric_query")"
  metrics_count="$(metric_result_count "$metrics_response")"
  {
    echo "mode=$mode"
    echo "trace_name=$TRACE_NAME"
    echo "state_file=$STATE_FILE"
    echo "startup_diagnostic=sidebar-performance-proof"
    echo "requires_unsafe_no_auth=false"
    echo "requires_non_foreground_activation=true"
    echo "workload_fixture_key=$WORKLOAD_FIXTURE_KEY"
    echo "worktree_fixture_key=$WORKTREE_FIXTURE_KEY"
    echo "workload_cycles=$WORKLOAD_CYCLES"
    echo "sidebar_projection.metric_result_count=$metrics_count"
  } >"$SUMMARY_FILE"
  echo "sidebar performance workload prepare-only ok: $SUMMARY_FILE"
  exit 0
fi

APP_PID=""
CPU_SAMPLER_PID=""
ZMX_MONITOR_PID=""
RESET_IDENTITY=""
RESET_DEBUG_CODE=""
RESET_DATA_DIR=""
RESET_BUNDLE_IDENTIFIER=""
STRICT_EXPECTED_TOPOLOGY_FINGERPRINT=""
STRICT_EXPECTED_REPOSITORY_COUNT=""
STRICT_EXPECTED_WORKTREE_COUNT=""
STRICT_CONTROL_ROOT=""
trap cleanup EXIT INT TERM
if [ "$mode" = "sidebar-proof" ]; then
  run_strict_sidebar_cpu_populations
  echo "strict sidebar CPU populations passed: $ARTIFACT"
  exit 0
fi
reset_disposable_debug_root

env \
  AGENTSTUDIO_DEBUG_DATA_DIR="$STRICT_DISPOSABLE_DATA_ROOT" \
  AGENTSTUDIO_TRACE_FLUSH=immediate \
  AGENTSTUDIO_TRACE_TAGS="$WORKLOAD_TRACE_TAGS" \
  AGENTSTUDIO_TRACE_NAME="$TRACE_MARKER" \
  AGENTSTUDIO_SIDEBAR_IPC_CYCLES="$WORKLOAD_CYCLES" \
  AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW="$IPC_DEBUG_ESCROW_PATH" \
  AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION=sidebar-performance-proof \
  AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$STATE_FILE" \
  "$DEBUG_RUNNER" --detach

AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$STATE_FILE" \
  wait_for_debug_observability
APP_PID="$(decode_env_file_value "$STATE_FILE" AGENTSTUDIO_OBSERVABILITY_PID)"
CPU_SAMPLES_FILE="$ARTIFACT/process-cpu-percent.txt"
: >"$CPU_SAMPLES_FILE"
sample_process_cpu "$APP_PID" "$CPU_SAMPLES_FILE" &
CPU_SAMPLER_PID=$!

activation_mode="$(decode_env_file_value "$STATE_FILE" AGENTSTUDIO_OBSERVABILITY_ACTIVATION_MODE)"
ipc_auth_mode="$(decode_env_file_value "$STATE_FILE" AGENTSTUDIO_OBSERVABILITY_IPC_AUTH_MODE)"
if [ "$ipc_auth_mode" != "authenticated" ]; then
  echo "sidebar proof requires authenticated IPC auth mode: ${ipc_auth_mode:-<missing>}" >&2
  exit 1
fi
if [ "$activation_mode" != "background" ]; then
  echo "sidebar proof requires background LaunchServices activation mode: ${activation_mode:-<missing>}" >&2
  exit 1
fi

state_data_dir="$(decode_env_file_value "$STATE_FILE" AGENTSTUDIO_OBSERVABILITY_DATA_DIR)"
ipc_metadata_path="${AGENTSTUDIO_OBSERVABILITY_IPC_METADATA:-$state_data_dir/ipc/runtime.json}"
if [ ! -s "$IPC_DEBUG_ESCROW_PATH" ]; then
  echo "missing debug IPC escrow: AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW=$IPC_DEBUG_ESCROW_PATH" >&2
  exit 1
fi
AGENTSTUDIO_SIDEBAR_IPC_CYCLES="$WORKLOAD_CYCLES" \
  run_authenticated_sidebar_ipc_workload "$ipc_metadata_path" "$IPC_DEBUG_ESCROW_PATH"
stop_pid "$CPU_SAMPLER_PID"
CPU_SAMPLER_PID=""
process_cpu_summary="$(summarize_process_cpu "$CPU_SAMPLES_FILE" "$APP_PID")"
process_cpu_percent_p50="$(printf '%s\n' "$process_cpu_summary" | sed -n '1p')"
process_cpu_percent_p95="$(printf '%s\n' "$process_cpu_summary" | sed -n '2p')"
process_cpu_percent_max="$(printf '%s\n' "$process_cpu_summary" | sed -n '3p')"
process_cpu_sample_count="$(printf '%s\n' "$process_cpu_summary" | sed -n '4p')"
record_required_sidebar_metric_matrix

metrics_result="$(wait_for_sidebar_metric_count)"
metrics_count="$(printf '%s\n' "$metrics_result" | sed -n '1p')"
metrics_response="$(printf '%s\n' "$metrics_result" | sed '1d')"
if [ "$metrics_count" = "0" ]; then
  echo "missing sidebar projection Victoria metric for marker $TRACE_NAME" >&2
  echo "$metrics_response" >&2
  exit 1
fi

fixture_repo_count="$(wait_for_required_metric_value fixture_repo_count \
  "max(agentstudio_startup_diagnostic_fixture_repo_count{agent.proof.marker=\"$(metric_label_selector "$TRACE_MARKER_W")\"})")"
fixture_worktree_count="$(wait_for_required_metric_value fixture_worktree_count \
  "max(agentstudio_startup_diagnostic_fixture_worktree_count{agent.proof.marker=\"$(metric_label_selector "$TRACE_MARKER_W")\"})")"
fixture_tab_count="$(wait_for_required_metric_value fixture_tab_count \
  "max(agentstudio_startup_diagnostic_fixture_tab_count{agent.proof.marker=\"$(metric_label_selector "$TRACE_MARKER_W")\"})")"
fixture_pane_count="$(wait_for_required_metric_value fixture_pane_count \
  "max(agentstudio_startup_diagnostic_fixture_pane_count{agent.proof.marker=\"$(metric_label_selector "$TRACE_MARKER_W")\"})")"
fixture_active_pty_count="$(wait_for_required_metric_value fixture_active_pty_count \
  "max(agentstudio_startup_diagnostic_fixture_active_pty_count{agent.proof.marker=\"$(metric_label_selector "$TRACE_MARKER_W")\"})")"
require_exact_fixture_count fixture_repo_count "$fixture_repo_count" "$REQUIRED_REPOSITORY_COUNT"
require_exact_fixture_count fixture_worktree_count "$fixture_worktree_count" "$REQUIRED_WORKTREE_COUNT"
require_exact_fixture_count fixture_tab_count "$fixture_tab_count" "$REQUIRED_TAB_COUNT"
require_exact_fixture_count fixture_pane_count "$fixture_pane_count" "$REQUIRED_PANE_COUNT"
require_exact_fixture_count fixture_active_pty_count "$fixture_active_pty_count" "$REQUIRED_ACTIVE_PTY_COUNT"

repo_pane_projection_worker_elapsed_ms_p95="$(
  wait_for_required_metric_value repo_pane_projection_worker_elapsed_ms_p95 \
    "$(metric_event_elapsed_p95_query repo projection_worker activity grouping_switch)"
)"
repo_pane_projection_worker_elapsed_ms_max="$(
  wait_for_required_metric_value repo_pane_projection_worker_elapsed_ms_max \
    "$(metric_event_elapsed_max_query repo projection_worker activity grouping_switch)"
)"
repo_tab_mainactor_apply_elapsed_ms_p95="$(
  wait_for_required_metric_value repo_tab_mainactor_apply_elapsed_ms_p95 \
    "$(metric_event_elapsed_p95_query panes mainactor_apply activity data_refresh)"
)"
repo_tab_mainactor_apply_elapsed_ms_max="$(
  wait_for_required_metric_value repo_tab_mainactor_apply_elapsed_ms_max \
    "$(metric_event_elapsed_max_query panes mainactor_apply activity data_refresh)"
)"
repo_pane_projection_worker_elapsed_ms_count="$(
  wait_for_required_metric_count repo_pane_projection_worker_elapsed_ms_count \
    "$(metric_event_elapsed_count_query repo projection_worker activity grouping_switch)" \
    "$REQUIRED_MATERIALIZED_SAMPLE_COUNT"
)"
repo_sort_projection_worker_elapsed_ms_p95="$(
  wait_for_required_metric_value repo_sort_projection_worker_elapsed_ms_p95 \
    "$(metric_event_elapsed_p95_query repo projection_worker repo sort_order)"
)"
repo_sort_projection_worker_elapsed_ms_max="$(
  wait_for_required_metric_value repo_sort_projection_worker_elapsed_ms_max \
    "$(metric_event_elapsed_max_query repo projection_worker repo sort_order)"
)"
repo_sort_projection_worker_elapsed_ms_count="$(
  wait_for_required_metric_count repo_sort_projection_worker_elapsed_ms_count \
    "$(metric_event_elapsed_count_query repo projection_worker repo sort_order)" \
    "$REQUIRED_MATERIALIZED_SAMPLE_COUNT"
)"
repo_sort_mainactor_apply_elapsed_ms_p95="$(
  wait_for_required_metric_value repo_sort_mainactor_apply_elapsed_ms_p95 \
    "$(metric_event_elapsed_p95_query repo mainactor_apply repo sort_order)"
)"
repo_sort_mainactor_apply_elapsed_ms_max="$(
  wait_for_required_metric_value repo_sort_mainactor_apply_elapsed_ms_max \
    "$(metric_event_elapsed_max_query repo mainactor_apply repo sort_order)"
)"
repo_sort_mainactor_apply_elapsed_ms_count="$(
  wait_for_required_metric_count repo_sort_mainactor_apply_elapsed_ms_count \
    "$(metric_event_elapsed_count_query repo mainactor_apply repo sort_order)" \
    "$REQUIRED_MATERIALIZED_SAMPLE_COUNT"
)"
repo_sort_request_build_mainactor_elapsed_ms_p95="$(
  wait_for_required_metric_value repo_sort_request_build_mainactor_elapsed_ms_p95 \
    "$(metric_event_elapsed_p95_query repo request_build_mainactor repo sort_order)"
)"
repo_sort_request_build_mainactor_elapsed_ms_max="$(
  wait_for_required_metric_value repo_sort_request_build_mainactor_elapsed_ms_max \
    "$(metric_event_elapsed_max_query repo request_build_mainactor repo sort_order)"
)"
repo_sort_request_build_mainactor_elapsed_ms_count="$(
  wait_for_required_metric_count repo_sort_request_build_mainactor_elapsed_ms_count \
    "$(metric_event_elapsed_count_query repo request_build_mainactor repo sort_order)" "$REQUIRED_SAMPLE_COUNT"
)"
repo_sort_row_index_elapsed_ms_p95="$(
  wait_for_required_metric_value repo_sort_row_index_elapsed_ms_p95 \
    "$(metric_event_elapsed_p95_query repo row_index repo sort_order)"
)"
repo_sort_row_index_elapsed_ms_max="$(
  wait_for_required_metric_value repo_sort_row_index_elapsed_ms_max \
    "$(metric_event_elapsed_max_query repo row_index repo sort_order)"
)"
repo_sort_row_index_elapsed_ms_count="$(
  wait_for_required_metric_count repo_sort_row_index_elapsed_ms_count \
    "$(metric_event_elapsed_count_query repo row_index repo sort_order)" \
    "$REQUIRED_MATERIALIZED_SAMPLE_COUNT"
)"
repo_tab_mainactor_apply_elapsed_ms_count="$(
  wait_for_required_metric_count repo_tab_mainactor_apply_elapsed_ms_count \
    "$(metric_event_elapsed_count_query panes mainactor_apply activity data_refresh)" \
    "$REQUIRED_MATERIALIZED_SAMPLE_COUNT"
)"
repo_pane_request_build_mainactor_elapsed_ms_p95="$(
  wait_for_required_metric_value repo_pane_request_build_mainactor_elapsed_ms_p95 \
    "$(metric_event_elapsed_p95_query repo request_build_mainactor activity grouping_switch)"
)"
repo_pane_request_build_mainactor_elapsed_ms_max="$(
  wait_for_required_metric_value repo_pane_request_build_mainactor_elapsed_ms_max \
    "$(metric_event_elapsed_max_query repo request_build_mainactor activity grouping_switch)"
)"
repo_pane_request_build_mainactor_elapsed_ms_count="$(
  wait_for_required_metric_count repo_pane_request_build_mainactor_elapsed_ms_count \
    "$(metric_event_elapsed_count_query repo request_build_mainactor activity grouping_switch)" "$REQUIRED_SAMPLE_COUNT"
)"
repo_pane_row_index_elapsed_ms_p95="$(
  wait_for_required_metric_value repo_pane_row_index_elapsed_ms_p95 \
    "$(metric_event_elapsed_p95_query repo row_index activity grouping_switch)"
)"
repo_pane_row_index_elapsed_ms_max="$(
  wait_for_required_metric_value repo_pane_row_index_elapsed_ms_max \
    "$(metric_event_elapsed_max_query repo row_index activity grouping_switch)"
)"
repo_pane_row_index_elapsed_ms_count="$(
  wait_for_required_metric_count repo_pane_row_index_elapsed_ms_count \
    "$(metric_event_elapsed_count_query repo row_index activity grouping_switch)" \
    "$REQUIRED_MATERIALIZED_SAMPLE_COUNT"
)"

run_repo_explorer_key_mutation_phase
run_repo_explorer_interaction_phase

: >"$KEYED_WAKE_VALUES_FILE"
for key_class in rendered_repo_pinned rendered_worktree_fact unrelated_tab_arrangement_pane observed_tab_title unrendered_attendance relevant missing_declared_key; do
  for stage in capture_rebuild membership_path affected_row whole_surface atom_slot eager_admission projection_worker mainactor_apply final_projection; do
    printf '%s=%s\n' \
      "keyed_wake_${key_class}_${stage}" \
      "$(keyed_wake_count "$key_class" "$stage")" >>"$KEYED_WAKE_VALUES_FILE"
  done
done
eager_family_admission_count="$(keyed_wake_count relevant eager_admission)"
assert_keyed_wake_contract rendered_repo_pinned capture_rebuild "$REQUIRED_KEY_MUTATION_COUNT"
assert_keyed_wake_contract rendered_repo_pinned whole_surface "$REQUIRED_KEY_MUTATION_COUNT"
assert_keyed_wake_contract rendered_repo_pinned eager_admission "$REQUIRED_KEY_MUTATION_COUNT"
assert_keyed_wake_contract rendered_repo_pinned affected_row 0
assert_keyed_wake_contract rendered_repo_pinned membership_path 0
assert_keyed_wake_contract rendered_worktree_fact whole_surface 0
assert_keyed_wake_contract rendered_worktree_fact affected_row "$REQUIRED_KEY_MUTATION_COUNT"
assert_keyed_wake_contract rendered_worktree_fact capture_rebuild "$REQUIRED_KEY_MUTATION_COUNT"
assert_keyed_wake_contract unrelated_tab_arrangement_pane capture_rebuild 0
assert_keyed_wake_contract unrendered_attendance capture_rebuild 0
assert_keyed_wake_contract relevant whole_surface 0
assert_keyed_wake_contract relevant affected_row "$REQUIRED_KEY_MUTATION_COUNT"
assert_keyed_wake_contract relevant capture_rebuild "$REQUIRED_KEY_MUTATION_COUNT"
assert_keyed_wake_contract missing_declared_key membership_path "$REQUIRED_KEY_MUTATION_COUNT"

reference_different_count="$(keyed_wake_outcome_count final_projection reference_different)"
if [ "$reference_different_count" != "0" ] && [ "$reference_different_count" != "0.0" ]; then
  echo "final_projection reference_different expected 0, got $reference_different_count" >&2
  exit 1
fi

semantic_input_count=$((REQUIRED_KEY_MUTATION_COUNT * 3))
semantic_fact_count="$(keyed_wake_stage_count affected_row)"
capture_admission_count="$(keyed_wake_stage_count capture_rebuild)"
execution_admission_count="$(keyed_wake_stage_count projection_worker)"
publication_count="$(keyed_wake_stage_count final_projection)"
materialization_count="$(keyed_wake_stage_count mainactor_apply)"
input_to_semantic_fact_contraction_ratio="$(ratio_value "$semantic_fact_count" "$semantic_input_count")"
semantic_fact_to_capture_admission_ratio="$(ratio_value "$capture_admission_count" "$semantic_fact_count")"
capture_to_execution_admission_ratio="$(ratio_value "$execution_admission_count" "$capture_admission_count")"
execution_to_publication_ratio="$(ratio_value "$publication_count" "$execution_admission_count")"
publication_to_materialization_ratio="$(ratio_value "$materialization_count" "$publication_count")"

trace_queue_dropped_record_count="$(wait_for_required_metric_value trace_queue_dropped_record_count \
  "max(agentstudio_performance_trace_queue_dropped_record_count{agent.proof.marker=\"$(metric_label_selector "$TRACE_MARKER_W")\"})")"
runtime_delivery_dropped_count="$(metric_value_or_empty \
  "max(agentstudio_performance_runtime_delivery_runtime_channel_outbound_dropped_count{agent.proof.marker=\"$(metric_label_selector "$TRACE_MARKER_W")\"}) + max(agentstudio_performance_runtime_delivery_eventbus_live_dropped_count{agent.proof.marker=\"$(metric_label_selector "$TRACE_MARKER_W")\"}) + max(agentstudio_performance_runtime_delivery_eventbus_replay_dropped_count{agent.proof.marker=\"$(metric_label_selector "$TRACE_MARKER_W")\"})")"
runtime_delivery_dropped_count="${runtime_delivery_dropped_count:-0}"
collector_loss_count=0
require_exact_fixture_count trace_queue_dropped_record_count "$trace_queue_dropped_record_count" 0
require_exact_fixture_count runtime_delivery_dropped_count "$runtime_delivery_dropped_count" 0

if [ "$mode" = "baseline" ]; then
  {
    echo "trace_name=$TRACE_NAME"
    echo "workload_fixture_key=$WORKLOAD_FIXTURE_KEY"
    echo "worktree_fixture_key=$WORKTREE_FIXTURE_KEY"
    echo "workload_cycles=$WORKLOAD_CYCLES"
    echo "repo_pane_projection_worker_elapsed_ms_p95=$repo_pane_projection_worker_elapsed_ms_p95"
    echo "repo_pane_projection_worker_elapsed_ms_max=$repo_pane_projection_worker_elapsed_ms_max"
    echo "repo_sort_projection_worker_elapsed_ms_p95=$repo_sort_projection_worker_elapsed_ms_p95"
    echo "repo_sort_projection_worker_elapsed_ms_max=$repo_sort_projection_worker_elapsed_ms_max"
    echo "repo_sort_mainactor_apply_elapsed_ms_p95=$repo_sort_mainactor_apply_elapsed_ms_p95"
    echo "repo_sort_mainactor_apply_elapsed_ms_max=$repo_sort_mainactor_apply_elapsed_ms_max"
    echo "repo_sort_request_build_mainactor_elapsed_ms_p95=$repo_sort_request_build_mainactor_elapsed_ms_p95"
    echo "repo_sort_request_build_mainactor_elapsed_ms_max=$repo_sort_request_build_mainactor_elapsed_ms_max"
    echo "repo_sort_row_index_elapsed_ms_p95=$repo_sort_row_index_elapsed_ms_p95"
    echo "repo_sort_row_index_elapsed_ms_max=$repo_sort_row_index_elapsed_ms_max"
    echo "repo_tab_mainactor_apply_elapsed_ms_p95=$repo_tab_mainactor_apply_elapsed_ms_p95"
    echo "repo_tab_mainactor_apply_elapsed_ms_max=$repo_tab_mainactor_apply_elapsed_ms_max"
    echo "repo_pane_request_build_mainactor_elapsed_ms_p95=$repo_pane_request_build_mainactor_elapsed_ms_p95"
    echo "repo_pane_request_build_mainactor_elapsed_ms_max=$repo_pane_request_build_mainactor_elapsed_ms_max"
    echo "repo_pane_row_index_elapsed_ms_p95=$repo_pane_row_index_elapsed_ms_p95"
    echo "repo_pane_row_index_elapsed_ms_max=$repo_pane_row_index_elapsed_ms_max"
  } >"$BASELINE_FILE"
  append_required_metric_values "$BASELINE_FILE"
fi

if [ "$mode" = "compare" ]; then
  compare_repo_pane_projection_worker_elapsed_ms_p95="$repo_pane_projection_worker_elapsed_ms_p95"
  compare_repo_pane_projection_worker_elapsed_ms_max="$repo_pane_projection_worker_elapsed_ms_max"
  compare_repo_sort_projection_worker_elapsed_ms_p95="$repo_sort_projection_worker_elapsed_ms_p95"
  compare_repo_sort_projection_worker_elapsed_ms_max="$repo_sort_projection_worker_elapsed_ms_max"
  compare_repo_sort_mainactor_apply_elapsed_ms_p95="$repo_sort_mainactor_apply_elapsed_ms_p95"
  compare_repo_sort_mainactor_apply_elapsed_ms_max="$repo_sort_mainactor_apply_elapsed_ms_max"
  compare_repo_sort_request_build_mainactor_elapsed_ms_p95="$repo_sort_request_build_mainactor_elapsed_ms_p95"
  compare_repo_sort_request_build_mainactor_elapsed_ms_max="$repo_sort_request_build_mainactor_elapsed_ms_max"
  compare_repo_sort_row_index_elapsed_ms_p95="$repo_sort_row_index_elapsed_ms_p95"
  compare_repo_sort_row_index_elapsed_ms_max="$repo_sort_row_index_elapsed_ms_max"
  compare_repo_tab_mainactor_apply_elapsed_ms_p95="$repo_tab_mainactor_apply_elapsed_ms_p95"
  compare_repo_tab_mainactor_apply_elapsed_ms_max="$repo_tab_mainactor_apply_elapsed_ms_max"
  compare_repo_pane_request_build_mainactor_elapsed_ms_p95="$repo_pane_request_build_mainactor_elapsed_ms_p95"
  compare_repo_pane_request_build_mainactor_elapsed_ms_max="$repo_pane_request_build_mainactor_elapsed_ms_max"
  compare_repo_pane_row_index_elapsed_ms_p95="$repo_pane_row_index_elapsed_ms_p95"
  compare_repo_pane_row_index_elapsed_ms_max="$repo_pane_row_index_elapsed_ms_max"
  compare_metric_values_file="$METRIC_VALUES_FILE"
  required_metric_keys="$(required_metric_keys_line)"
  for baseline_metric_key in \
    repo_pane_projection_worker_elapsed_ms_p95 \
    repo_pane_projection_worker_elapsed_ms_max \
    repo_sort_projection_worker_elapsed_ms_p95 \
    repo_sort_projection_worker_elapsed_ms_max \
    repo_sort_mainactor_apply_elapsed_ms_p95 \
    repo_sort_mainactor_apply_elapsed_ms_max \
    repo_sort_request_build_mainactor_elapsed_ms_p95 \
    repo_sort_request_build_mainactor_elapsed_ms_max \
    repo_sort_row_index_elapsed_ms_p95 \
    repo_sort_row_index_elapsed_ms_max \
    repo_tab_mainactor_apply_elapsed_ms_p95 \
    repo_tab_mainactor_apply_elapsed_ms_max \
    repo_pane_request_build_mainactor_elapsed_ms_p95 \
    repo_pane_request_build_mainactor_elapsed_ms_max \
    repo_pane_row_index_elapsed_ms_p95 \
    repo_pane_row_index_elapsed_ms_max
  do
    load_baseline_metric_value "$BASELINE_FILE" "$baseline_metric_key"
  done
  compare_required_metric_matrix "$BASELINE_FILE" "$compare_metric_values_file"
  performance_threshold_check repo_pane_projection_worker_elapsed_ms_p95 \
    "${repo_pane_projection_worker_elapsed_ms_p95:?missing baseline repo pane worker p95}" \
    "$compare_repo_pane_projection_worker_elapsed_ms_p95"
  performance_threshold_check repo_pane_projection_worker_elapsed_ms_max \
    "${repo_pane_projection_worker_elapsed_ms_max:?missing baseline repo pane worker max}" \
    "$compare_repo_pane_projection_worker_elapsed_ms_max"
  performance_threshold_check repo_sort_projection_worker_elapsed_ms_p95 \
    "${repo_sort_projection_worker_elapsed_ms_p95:?missing baseline repo sort worker p95}" \
    "$compare_repo_sort_projection_worker_elapsed_ms_p95"
  performance_threshold_check repo_sort_projection_worker_elapsed_ms_max \
    "${repo_sort_projection_worker_elapsed_ms_max:?missing baseline repo sort worker max}" \
    "$compare_repo_sort_projection_worker_elapsed_ms_max"
  performance_threshold_check repo_sort_mainactor_apply_elapsed_ms_p95 \
    "${repo_sort_mainactor_apply_elapsed_ms_p95:?missing baseline repo sort apply p95}" \
    "$compare_repo_sort_mainactor_apply_elapsed_ms_p95"
  performance_threshold_check repo_sort_mainactor_apply_elapsed_ms_max \
    "${repo_sort_mainactor_apply_elapsed_ms_max:?missing baseline repo sort apply max}" \
    "$compare_repo_sort_mainactor_apply_elapsed_ms_max"
  performance_threshold_check repo_sort_request_build_mainactor_elapsed_ms_p95 \
    "${repo_sort_request_build_mainactor_elapsed_ms_p95:?missing baseline repo sort request-build p95}" \
    "$compare_repo_sort_request_build_mainactor_elapsed_ms_p95"
  performance_threshold_check repo_sort_request_build_mainactor_elapsed_ms_max \
    "${repo_sort_request_build_mainactor_elapsed_ms_max:?missing baseline repo sort request-build max}" \
    "$compare_repo_sort_request_build_mainactor_elapsed_ms_max"
  performance_threshold_check repo_sort_row_index_elapsed_ms_p95 \
    "${repo_sort_row_index_elapsed_ms_p95:?missing baseline repo sort row-index p95}" \
    "$compare_repo_sort_row_index_elapsed_ms_p95"
  performance_threshold_check repo_sort_row_index_elapsed_ms_max \
    "${repo_sort_row_index_elapsed_ms_max:?missing baseline repo sort row-index max}" \
    "$compare_repo_sort_row_index_elapsed_ms_max"
  performance_threshold_check repo_tab_mainactor_apply_elapsed_ms_p95 \
    "${repo_tab_mainactor_apply_elapsed_ms_p95:?missing baseline repo tab apply p95}" \
    "$compare_repo_tab_mainactor_apply_elapsed_ms_p95"
  performance_threshold_check repo_tab_mainactor_apply_elapsed_ms_max \
    "${repo_tab_mainactor_apply_elapsed_ms_max:?missing baseline repo tab apply max}" \
    "$compare_repo_tab_mainactor_apply_elapsed_ms_max"
  performance_threshold_check repo_pane_request_build_mainactor_elapsed_ms_p95 \
    "${repo_pane_request_build_mainactor_elapsed_ms_p95:?missing baseline repo pane request-build p95}" \
    "$compare_repo_pane_request_build_mainactor_elapsed_ms_p95"
  performance_threshold_check repo_pane_request_build_mainactor_elapsed_ms_max \
    "${repo_pane_request_build_mainactor_elapsed_ms_max:?missing baseline repo pane request-build max}" \
    "$compare_repo_pane_request_build_mainactor_elapsed_ms_max"
  performance_threshold_check repo_pane_row_index_elapsed_ms_p95 \
    "${repo_pane_row_index_elapsed_ms_p95:?missing baseline repo pane row-index p95}" \
    "$compare_repo_pane_row_index_elapsed_ms_p95"
  performance_threshold_check repo_pane_row_index_elapsed_ms_max \
    "${repo_pane_row_index_elapsed_ms_max:?missing baseline repo pane row-index max}" \
    "$compare_repo_pane_row_index_elapsed_ms_max"
  repo_pane_projection_worker_elapsed_ms_p95="$compare_repo_pane_projection_worker_elapsed_ms_p95"
  repo_pane_projection_worker_elapsed_ms_max="$compare_repo_pane_projection_worker_elapsed_ms_max"
  repo_sort_projection_worker_elapsed_ms_p95="$compare_repo_sort_projection_worker_elapsed_ms_p95"
  repo_sort_projection_worker_elapsed_ms_max="$compare_repo_sort_projection_worker_elapsed_ms_max"
  repo_sort_mainactor_apply_elapsed_ms_p95="$compare_repo_sort_mainactor_apply_elapsed_ms_p95"
  repo_sort_mainactor_apply_elapsed_ms_max="$compare_repo_sort_mainactor_apply_elapsed_ms_max"
  repo_sort_request_build_mainactor_elapsed_ms_p95="$compare_repo_sort_request_build_mainactor_elapsed_ms_p95"
  repo_sort_request_build_mainactor_elapsed_ms_max="$compare_repo_sort_request_build_mainactor_elapsed_ms_max"
  repo_sort_row_index_elapsed_ms_p95="$compare_repo_sort_row_index_elapsed_ms_p95"
  repo_sort_row_index_elapsed_ms_max="$compare_repo_sort_row_index_elapsed_ms_max"
  repo_tab_mainactor_apply_elapsed_ms_p95="$compare_repo_tab_mainactor_apply_elapsed_ms_p95"
  repo_tab_mainactor_apply_elapsed_ms_max="$compare_repo_tab_mainactor_apply_elapsed_ms_max"
  repo_pane_request_build_mainactor_elapsed_ms_p95="$compare_repo_pane_request_build_mainactor_elapsed_ms_p95"
  repo_pane_request_build_mainactor_elapsed_ms_max="$compare_repo_pane_request_build_mainactor_elapsed_ms_max"
  repo_pane_row_index_elapsed_ms_p95="$compare_repo_pane_row_index_elapsed_ms_p95"
  repo_pane_row_index_elapsed_ms_max="$compare_repo_pane_row_index_elapsed_ms_max"
fi

{
  echo "mode=$mode"
  echo "trace_name=$TRACE_NAME"
  echo "state_file=$STATE_FILE"
  echo "activation_mode=$activation_mode"
  echo "ipc_auth_mode=$ipc_auth_mode"
  echo "fixture_repo_count=$fixture_repo_count"
  echo "fixture_worktree_count=$fixture_worktree_count"
  echo "fixture_tab_count=$fixture_tab_count"
  echo "fixture_pane_count=$fixture_pane_count"
  echo "fixture_active_pty_count=$fixture_active_pty_count"
  echo "process_cpu_sample_count=$process_cpu_sample_count"
  echo "process_cpu_percent_p50=$process_cpu_percent_p50"
  echo "process_cpu_percent_p95=$process_cpu_percent_p95"
  echo "process_cpu_percent_max=$process_cpu_percent_max"
  echo "trace_queue_dropped_record_count=$trace_queue_dropped_record_count"
  echo "runtime_delivery_dropped_count=$runtime_delivery_dropped_count"
  echo "collector_loss_count=$collector_loss_count"
  echo "input_to_semantic_fact_contraction_ratio=$input_to_semantic_fact_contraction_ratio"
  echo "semantic_fact_to_capture_admission_ratio=$semantic_fact_to_capture_admission_ratio"
  echo "capture_to_execution_admission_ratio=$capture_to_execution_admission_ratio"
  echo "execution_to_publication_ratio=$execution_to_publication_ratio"
  echo "publication_to_materialization_ratio=$publication_to_materialization_ratio"
  echo "sidebar_projection.metric_result_count=$metrics_count"
  echo "repo_pane_projection_worker_elapsed_ms_p95=$repo_pane_projection_worker_elapsed_ms_p95"
  echo "repo_pane_projection_worker_elapsed_ms_max=$repo_pane_projection_worker_elapsed_ms_max"
  echo "repo_pane_projection_worker_elapsed_ms_count=$repo_pane_projection_worker_elapsed_ms_count"
  echo "repo_sort_projection_worker_elapsed_ms_p95=$repo_sort_projection_worker_elapsed_ms_p95"
  echo "repo_sort_projection_worker_elapsed_ms_max=$repo_sort_projection_worker_elapsed_ms_max"
  echo "repo_sort_projection_worker_elapsed_ms_count=$repo_sort_projection_worker_elapsed_ms_count"
  echo "repo_sort_mainactor_apply_elapsed_ms_p95=$repo_sort_mainactor_apply_elapsed_ms_p95"
  echo "repo_sort_mainactor_apply_elapsed_ms_max=$repo_sort_mainactor_apply_elapsed_ms_max"
  echo "repo_sort_mainactor_apply_elapsed_ms_count=$repo_sort_mainactor_apply_elapsed_ms_count"
  echo "repo_sort_request_build_mainactor_elapsed_ms_p95=$repo_sort_request_build_mainactor_elapsed_ms_p95"
  echo "repo_sort_request_build_mainactor_elapsed_ms_max=$repo_sort_request_build_mainactor_elapsed_ms_max"
  echo "repo_sort_request_build_mainactor_elapsed_ms_count=$repo_sort_request_build_mainactor_elapsed_ms_count"
  echo "repo_sort_row_index_elapsed_ms_p95=$repo_sort_row_index_elapsed_ms_p95"
  echo "repo_sort_row_index_elapsed_ms_max=$repo_sort_row_index_elapsed_ms_max"
  echo "repo_sort_row_index_elapsed_ms_count=$repo_sort_row_index_elapsed_ms_count"
  echo "repo_tab_mainactor_apply_elapsed_ms_p95=$repo_tab_mainactor_apply_elapsed_ms_p95"
  echo "repo_tab_mainactor_apply_elapsed_ms_max=$repo_tab_mainactor_apply_elapsed_ms_max"
  echo "repo_tab_mainactor_apply_elapsed_ms_count=$repo_tab_mainactor_apply_elapsed_ms_count"
  echo "repo_pane_request_build_mainactor_elapsed_ms_p95=$repo_pane_request_build_mainactor_elapsed_ms_p95"
  echo "repo_pane_request_build_mainactor_elapsed_ms_max=$repo_pane_request_build_mainactor_elapsed_ms_max"
  echo "repo_pane_request_build_mainactor_elapsed_ms_count=$repo_pane_request_build_mainactor_elapsed_ms_count"
  echo "repo_pane_row_index_elapsed_ms_p95=$repo_pane_row_index_elapsed_ms_p95"
  echo "repo_pane_row_index_elapsed_ms_max=$repo_pane_row_index_elapsed_ms_max"
  echo "repo_pane_row_index_elapsed_ms_count=$repo_pane_row_index_elapsed_ms_count"
  echo "repos_workload.ipc_sequence=grouping_and_sort"
  echo "repos_sort.ipc_sequence=toggle,restore,toggle,restore,toggle,restore"
  echo "panes_fixed_policy=activity,descending,no_subgroup"
  echo "panes_supported_workload.ipc_sequence=show_pinned_toggle,restore"
  echo "panes_retired_commands=absent,rejected,no_mutation"
  echo "eager_family_admission_count=$eager_family_admission_count"
  echo "marker_w=$TRACE_MARKER_W"
  echo "marker_k=$TRACE_MARKER_K"
  echo "marker_i=$TRACE_MARKER_I"
  echo "repo_explorer_key_mutation_phase=rendered_repo_pinned,rendered_worktree_fact,relevant_key,unrelated_tab_arrangement_pane,observed_tab_title_informational,unrendered_attendance,pane_activity_facet_change,missing_key_insertion"
  echo "interaction_phase=command_bar_open,command_bar_close,tab_move_program_instrument_gap,cmd_r_program_instrument_gap,divider_program_instrument_gap"
  echo "divider_frame=program_instrument_gap"
  if [ "$mode" = "baseline" ] || [ "$mode" = "compare" ]; then
    echo "baseline_file=$BASELINE_FILE"
  fi
} >"$SUMMARY_FILE"
append_required_metric_values "$SUMMARY_FILE"
cat "$KEYED_WAKE_VALUES_FILE" >>"$SUMMARY_FILE"
echo "sidebar performance workload ok: $SUMMARY_FILE"
