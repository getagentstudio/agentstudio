#!/bin/bash
set -euo pipefail

LOGS_QUERY_URL="${AI_TOOLS_OBSERVABILITY_LOGS_QUERY_URL:-http://127.0.0.1:9428/select/logsql/query}"
METRICS_QUERY_URL="${AI_TOOLS_OBSERVABILITY_METRICS_QUERY_URL:-http://127.0.0.1:8428/api/v1/query}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/scripts/debug-app-identity.sh"
STATE_FILE="${AGENTSTUDIO_OBSERVABILITY_STATE_FILE:-$PROJECT_ROOT/tmp/debug-observability/latest-observability.env}"
CURL_BIN="${AGENTSTUDIO_CURL_BIN:-/usr/bin/curl}"
LSOF_BIN="${AGENTSTUDIO_LSOF_BIN:-/usr/sbin/lsof}"
VERIFY_ATTEMPTS="${AGENTSTUDIO_OBSERVABILITY_VERIFY_ATTEMPTS:-30}"
VERIFY_RETRY_DELAY_SECONDS="${AGENTSTUDIO_OBSERVABILITY_VERIFY_RETRY_DELAY_SECONDS:-2}"

# Report-only time-to-first-interaction gate. Compares the observed TTFI p95 to a soft
# budget (default 300ms, tunable via AGENTSTUDIO_BRIDGE_TTFI_GATE_MS) and logs pass or
# over-budget. It NEVER fails the smoke: enforcing the 300ms target is intentionally
# deferred, so this only reports. Defined early so the self-test hook below can exercise
# the comparison in isolation without the live-process/state-file preamble.
bridge_viewer_ttfi_report_gate() {
  local p95="$1"
  local gate_ms="$2"
  if awk "BEGIN { exit !($p95 <= $gate_ms) }" 2>/dev/null; then
    echo "Bridge viewer TTFI gate PASS: p95=${p95}ms <= ${gate_ms}ms budget"
  else
    echo "Bridge viewer TTFI gate REPORT (over budget, not enforced): p95=${p95}ms > ${gate_ms}ms budget"
  fi
  return 0
}

if [ -n "${AGENTSTUDIO_BRIDGE_TTFI_GATE_SELFTEST_P95:-}" ]; then
  bridge_viewer_ttfi_report_gate \
    "$AGENTSTUDIO_BRIDGE_TTFI_GATE_SELFTEST_P95" \
    "${AGENTSTUDIO_BRIDGE_TTFI_GATE_MS:-300}"
  exit $?
fi

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

validate_loopback_url AI_TOOLS_OBSERVABILITY_LOGS_QUERY_URL "$LOGS_QUERY_URL"
validate_loopback_url AI_TOOLS_OBSERVABILITY_METRICS_QUERY_URL "$METRICS_QUERY_URL"

state_marker=""
state_proof_token=""
state_query_start=""
state_status=""
state_reason=""
state_pid=""
state_process_start=""
state_debug_code=""
state_launch_method=""
state_activation_mode=""
state_ipc_auth_mode=""
state_app=""
state_executable=""
state_startup_diagnostic_action=""
state_preferences_mode=""
if [ -f "$STATE_FILE" ]; then
  while IFS='=' read -r key value || [ -n "$key" ]; do
    decoded_value="$(
      /usr/bin/python3 - "$value" <<'PY'
import shlex
import sys

try:
    parsed = shlex.split(sys.argv[1])
except ValueError:
    parsed = []
print(parsed[0] if parsed else "")
PY
    )"
    case "$key" in
      AGENTSTUDIO_OBSERVABILITY_MARKER)
        state_marker="$decoded_value"
        ;;
      AGENTSTUDIO_OBSERVABILITY_PROOF_TOKEN)
        state_proof_token="$decoded_value"
        ;;
      AGENTSTUDIO_OBSERVABILITY_QUERY_START)
        state_query_start="$decoded_value"
        ;;
      AGENTSTUDIO_OBSERVABILITY_STATUS)
        state_status="$decoded_value"
        ;;
      AGENTSTUDIO_OBSERVABILITY_PROCESS_START_IDENTITY)
        state_process_start="$decoded_value"
        ;;
      AGENTSTUDIO_OBSERVABILITY_PID)
        state_pid="$decoded_value"
        ;;
      AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE)
        state_debug_code="$decoded_value"
        ;;
      AGENTSTUDIO_OBSERVABILITY_LAUNCH_METHOD)
        state_launch_method="$decoded_value"
        ;;
      AGENTSTUDIO_OBSERVABILITY_ACTIVATION_MODE)
        state_activation_mode="$decoded_value"
        ;;
      AGENTSTUDIO_OBSERVABILITY_IPC_AUTH_MODE)
        state_ipc_auth_mode="$decoded_value"
        ;;
      AGENTSTUDIO_OBSERVABILITY_APP)
        state_app="$decoded_value"
        ;;
      AGENTSTUDIO_OBSERVABILITY_EXECUTABLE)
        state_executable="$decoded_value"
        ;;
      AGENTSTUDIO_OBSERVABILITY_REASON)
        state_reason="$decoded_value"
        ;;
      AGENTSTUDIO_OBSERVABILITY_STARTUP_DIAGNOSTIC_ACTION)
        state_startup_diagnostic_action="$decoded_value"
        ;;
      AGENTSTUDIO_OBSERVABILITY_PREFERENCES_MODE)
        state_preferences_mode="$decoded_value"
        ;;
    esac
  done <"$STATE_FILE"
fi

if [ -z "$state_preferences_mode" ] && [ -f "$STATE_FILE" ] &&
  grep -Eq '^[[:space:]]*AGENTSTUDIO_OBSERVABILITY_PREFERENCES_MODE[[:space:]]*=[[:space:]]*honor_preferences[[:space:]]*$' "$STATE_FILE"; then
  state_preferences_mode="honor_preferences"
fi

if [ "$state_status" = "launch_failed" ] || [ "$state_status" = "already_running" ]; then
  if [ -n "$state_reason" ]; then
    echo "AgentStudio debug observability did not start: $state_status ($state_reason)" >&2
  else
    echo "AgentStudio debug observability did not start: $state_status" >&2
  fi
  echo "state file: $STATE_FILE" >&2
  exit 1
fi

MARKER="${AGENTSTUDIO_OBSERVABILITY_MARKER:-$state_marker}"
if [ -z "$MARKER" ]; then
  echo "missing AgentStudio debug observability marker; run mise run run-debug-observability first" >&2
  exit 1
fi

process_executable_path() {
  local pid="${1:?missing pid}"
  local txt_output
  if ! txt_output="$("$LSOF_BIN" -a -p "$pid" -d txt -Fn 2>/dev/null)"; then
    echo "unable to inspect AgentStudio debug PID $pid with $LSOF_BIN" >&2
    return 1
  fi
  awk '/^n/ { print substr($0, 2); exit }' <<<"$txt_output"
}

realpath_or_empty() {
  /usr/bin/python3 - "$1" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]) if sys.argv[1] else "")
PY
}

require_live_debug_process() {
  if [ "$state_status" != "running" ]; then
    echo "AgentStudio debug observability state is not running: ${state_status:-<missing>}" >&2
    echo "state file: $STATE_FILE" >&2
    exit 1
  fi
  case "$state_pid" in
    ''|*[!0-9]*)
      echo "AgentStudio debug observability state missing numeric PID" >&2
      echo "state file: $STATE_FILE" >&2
      exit 1
      ;;
  esac
  if ! kill -0 "$state_pid" >/dev/null 2>&1; then
    echo "AgentStudio debug observability PID is not running: $state_pid" >&2
    echo "state file: $STATE_FILE" >&2
    exit 1
  fi

  if [ "${AGENTSTUDIO_REQUIRE_LAUNCHSERVICES:-0}" = "1" ] &&
    [ "$state_launch_method" = "direct_executable" ]; then
    echo "AgentStudio debug observability strict GUI proof requires LaunchServices launch; state recorded direct_executable fallback" >&2
    echo "state file: $STATE_FILE" >&2
    exit 1
  fi

  local executable_path
  executable_path="$(process_executable_path "$state_pid")"
  if [ -z "$executable_path" ]; then
    echo "unable to resolve executable for AgentStudio debug PID $state_pid" >&2
    echo "state file: $STATE_FILE" >&2
    exit 1
  fi

  if [ "$state_launch_method" = "direct_executable" ]; then
    local expected_executable actual_executable
    expected_executable="$(realpath_or_empty "$state_executable")"
    actual_executable="$(realpath_or_empty "$executable_path")"
    if [ -z "$expected_executable" ] || [ "$actual_executable" != "$expected_executable" ]; then
      echo "AgentStudio debug observability executable mismatch" >&2
      echo "expected: ${expected_executable:-<missing>}" >&2
      echo "actual: ${actual_executable:-<missing>}" >&2
      echo "state file: $STATE_FILE" >&2
      exit 1
    fi
    return 0
  fi

  if [ -z "$state_debug_code" ]; then
    echo "AgentStudio debug observability state missing debug code" >&2
    echo "state file: $STATE_FILE" >&2
    exit 1
  fi
  local expected_bundle_identifier actual_bundle_identifier
  expected_bundle_identifier="com.agentstudio.app.debug"
  actual_bundle_identifier="$(bundle_identifier_for_executable "$executable_path")"
  local expected_executable actual_executable
  expected_executable="$(realpath_or_empty "$state_app/Contents/MacOS/AgentStudio")"
  actual_executable="$(realpath_or_empty "$executable_path")"
  if [ -z "$state_app" ] || [ "$actual_executable" != "$expected_executable" ] ||
    { [ -n "$state_executable" ] && [ "$(realpath_or_empty "$state_executable")" != "$expected_executable" ]; } ||
    [ "$(debug_code_for_executable "$executable_path")" != "$state_debug_code" ] ||
    [ -z "$state_process_start" ] || [ "$(process_start_identity "$state_pid" || true)" != "$state_process_start" ] ||
    [ "$actual_bundle_identifier" != "$expected_bundle_identifier" ]
  then
    echo "AgentStudio debug observability bundle identity mismatch" >&2
    echo "expected: $expected_bundle_identifier" >&2
    echo "actual: ${actual_bundle_identifier:-<missing>}" >&2
    echo "code: expected=$state_debug_code actual=$(debug_code_for_executable "$executable_path")" >&2
    echo "executable: expected=$expected_executable actual=$actual_executable" >&2
    echo "start: expected=$state_process_start actual=$(process_start_identity "$state_pid" || true)" >&2
    echo "state file: $STATE_FILE" >&2
    exit 1
  fi
}

allow_completed_diagnostic_exit=false
if [ "${AGENTSTUDIO_OBSERVABILITY_ALLOW_COMPLETED_EXIT:-0}" = "1" ] &&
  {
    [ "$state_startup_diagnostic_action" = "bridge-review-observability-smoke" ] ||
      [ "$state_startup_diagnostic_action" = "bridge-file-view-observability-smoke" ] ||
      [ "$state_startup_diagnostic_action" = "bridge-file-view-command-route-observability-smoke" ] ||
      [ "$state_startup_diagnostic_action" = "bridge-file-view-targeted-route-observability-smoke" ] ||
      [ "$state_startup_diagnostic_action" = "bridge-review-to-file-view-observability-smoke" ] ||
      [ "$state_startup_diagnostic_action" = "pane-association-runtime-proof" ]
  }; then
  allow_completed_diagnostic_exit=true
fi

# The quit allowance exists only after termination. Reuse the explicit
# completed-trace mode, pinned to this launch; normal proof still requires a PID.
if [ "${AGENTSTUDIO_RESTORE_R3_COST_PROOF:-0}" = "1" ] &&
  [ "${AGENTSTUDIO_OBSERVABILITY_ALLOW_COMPLETED_EXIT:-0}" = "1" ]; then
  if [ "$state_status" != "running" ] || [ -z "$state_proof_token" ]; then
    echo "completed restore cost proof requires a running launch state with a proof token" >&2
    exit 1
  fi
  allow_completed_diagnostic_exit=true
fi

if [ "$allow_completed_diagnostic_exit" = false ]; then
  require_live_debug_process
fi

portable_utc_time() {
  local macos_offset="$1"
  local gnu_offset="$2"
  date -u -v"${macos_offset}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
    date -u -d "$gnu_offset" +"%Y-%m-%dT%H:%M:%SZ"
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

json_truthy_field() {
  local field="${1:?missing JSON field}"
  local payload="${2:-}"
  grep -Eq "\"$field\":(\"true\"|true|\"1\"|1)([,}[:space:]]|$)" <<<"$payload"
}

json_exact_string_field() {
  local field="${1:?missing JSON field}"
  local expected="${2:?missing expected value}"
  local payload="${3:-}"
  grep -q "\"$field\":\"$expected\"" <<<"$payload"
}

json_falseish_field() {
  local field="${1:?missing JSON field}"
  local payload="${2:-}"
  grep -Eq "\"$field\":(\"false\"|false)([,}[:space:]]|$)" <<<"$payload"
}

is_frame_not_live_skip() {
  local payload="${1:-}"
  json_exact_string_field agentstudio.startup_diagnostic.skip_reason frame_not_live "$payload" &&
    json_falseish_field agentstudio.startup_diagnostic.bridge.frame_liveness.raf_alive "$payload" &&
    json_falseish_field agentstudio.startup_diagnostic.render_proof.succeeded "$payload"
}

require_json_fields() {
  local description="${1:?missing description}"
  local payload="${2:-}"
  shift 2
  local field
  for field in "$@"; do
    if ! grep -q "\"$field\":" <<<"$payload"; then
      echo "$description missing field: $field" >&2
      echo "$payload" >&2
      exit 1
    fi
  done
}

QUERY_START="${AGENTSTUDIO_OBSERVABILITY_QUERY_START:-${state_query_start:-$(portable_utc_time -4H '4 hours ago')}}"
QUERY_END="${AGENTSTUDIO_OBSERVABILITY_QUERY_END:-$(portable_utc_time +5M '5 minutes')}"

stream_query="{service.name=\"AgentStudio\",dev.runtime.flavor=\"debug\"}"
marker_query="$(logsql_exact_filter "agent.proof.marker" "$MARKER")"
query="$stream_query $marker_query"
if [ -n "$state_proof_token" ]; then
  proof_token_query="$(logsql_exact_filter "agent.proof.launch" "$state_proof_token")"
  query="$query $proof_token_query"
fi
startup_event_query="$(logsql_exact_filter "_msg" "app.did_finish_launching.succeeded")"
preferences_loaded_event_query="$(logsql_exact_filter "_msg" "app.preferences.global.loaded")"

query_logs() {
  local logsql="$1"
  "$CURL_BIN" --fail --silent --show-error --max-time 5 --get \
    --data-urlencode "query=$logsql" \
    --data-urlencode "start=$QUERY_START" \
    --data-urlencode "end=$QUERY_END" \
    "$LOGS_QUERY_URL"
}

query_metrics() {
  local promql="$1"
  "$CURL_BIN" --fail --silent --show-error --max-time 5 --get \
    --data-urlencode "query=$promql" \
    "$METRICS_QUERY_URL"
}

metric_value() {
  local promql="$1"
  local response
  response="$(query_metrics "$promql" 2>/dev/null || true)"
  if [ -z "$response" ]; then
    printf '0\n'
    return 0
  fi
  /usr/bin/python3 - "$response" <<'PY'
import json
import math
import sys

total = 0.0
try:
    payload = json.loads(sys.argv[1])
    for item in payload["data"]["result"]:
        value = float(item["value"][1])
        if math.isfinite(value):
            total += value
except Exception:
    pass

print(int(total) if total.is_integer() else total)
PY
}

wait_for_metric_value() {
  local description="${1:?missing description}"
  local promql="${2:?missing PromQL query}"
  local value="0"
  local attempt=1
  while [ "$attempt" -le "$VERIFY_ATTEMPTS" ]; do
    value="$(metric_value "$promql")"
    if [ "$value" != "0" ] && [ "$value" != "0.0" ]; then
      printf '%s' "$value"
      return 0
    fi
    if [ "$attempt" -lt "$VERIFY_ATTEMPTS" ]; then
      sleep "$VERIFY_RETRY_DELAY_SECONDS"
    fi
    attempt=$((attempt + 1))
  done
  echo "$description" >&2
  echo "$promql" >&2
  return 1
}

bridge_native_metric_label_selector() {
  local event_name="$1"
  local phase="$2"
  local priority="$3"
  printf 'service.name="AgentStudio",dev.runtime.flavor="debug",agent.proof.marker="%s",event="%s",phase="%s",plane="data",priority="%s",slice="tree_prepare_input"' \
    "$MARKER" "$event_name" "$phase" "$priority"
}

require_bridge_file_view_native_metric_percentiles() {
  local contract event_name phase priority selector count_query p95_query p99_query count p95 p99
  local required_contracts=(
    "performance.bridge.native.metadata_open_to_first_window|metadata_open_to_first_window|hot"
    "performance.bridge.native.metadata_full_manifest_complete|metadata_full_manifest_complete|cold"
  )
  for contract in "${required_contracts[@]}"; do
    IFS='|' read -r event_name phase priority <<<"$contract"
    selector="$(bridge_native_metric_label_selector "$event_name" "$phase" "$priority")"
    count_query="sum(agentstudio_performance_events_total{$selector})"
    p95_query="histogram_quantile(0.95, sum by (le) (agentstudio_performance_event_elapsed_ms_bucket{$selector}))"
    p99_query="histogram_quantile(0.99, sum by (le) (agentstudio_performance_event_elapsed_ms_bucket{$selector}))"
    count="$(wait_for_metric_value "Bridge FileView native metric percentile proof missing count for $event_name" "$count_query")"
    p95="$(wait_for_metric_value "Bridge FileView native metric percentile proof missing p95 for $event_name" "$p95_query")"
    p99="$(wait_for_metric_value "Bridge FileView native metric percentile proof missing p99 for $event_name" "$p99_query")"
    echo "Bridge FileView native metric percentile proof $event_name count=$count p95=$p95 p99=$p99"
  done
}

bridge_viewer_ttfi_metric_label_selector() {
  printf 'service.name="AgentStudio",dev.runtime.flavor="debug",agent.proof.marker="%s",event="performance.bridge.viewer.time_to_first_interaction",phase="time_to_first_interaction",plane="data",priority="hot",slice="content_fetch"' \
    "$MARKER"
}

require_bridge_viewer_ttfi_report_only_gate() {
  local selector count_query p95_query count p95 gate_ms
  if [ "${AGENTSTUDIO_BRIDGE_TTFI_RAF_ALIVE:-unknown}" = "false" ]; then
    echo "SKIP Bridge viewer TTFI presence proof performance.bridge.viewer.time_to_first_interaction: raf_alive=false"
    return 0
  fi
  selector="$(bridge_viewer_ttfi_metric_label_selector)"
  count_query="sum(agentstudio_performance_events_total{$selector})"
  p95_query="histogram_quantile(0.95, sum by (le) (agentstudio_performance_event_elapsed_ms_bucket{$selector}))"
  # Presence is a hard contract: the browser TTFI mark must reach VictoriaMetrics, or the
  # metric wiring has regressed. The numeric budget below stays report-only.
  count="$(wait_for_metric_value "Bridge viewer TTFI presence proof missing count" "$count_query")"
  p95="$(wait_for_metric_value "Bridge viewer TTFI presence proof missing p95" "$p95_query")"
  echo "Bridge viewer TTFI presence proof performance.bridge.viewer.time_to_first_interaction count=$count p95=$p95"
  gate_ms="${AGENTSTUDIO_BRIDGE_TTFI_GATE_MS:-300}"
  bridge_viewer_ttfi_report_gate "$p95" "$gate_ms"
}

wait_for_log_query() {
  local description="${1:?missing description}"
  local logsql="${2:?missing LogSQL query}"
  local response=""
  local attempt=1
  while [ "$attempt" -le "$VERIFY_ATTEMPTS" ]; do
    response="$(query_logs "$logsql")"
    if [ -n "$response" ]; then
      printf '%s' "$response"
      return 0
    fi
    if [ "$attempt" -lt "$VERIFY_ATTEMPTS" ]; then
      sleep "$VERIFY_RETRY_DELAY_SECONDS"
    fi
    attempt=$((attempt + 1))
  done
  echo "$description" >&2
  return 1
}

wait_for_optional_log_query() {
  local logsql="${1:?missing LogSQL query}"
  local response=""
  local attempt=1
  while [ "$attempt" -le "$VERIFY_ATTEMPTS" ]; do
    response="$(query_logs "$logsql")"
    if [ -n "$response" ]; then
      printf '%s' "$response"
      return 0
    fi
    if [ "$attempt" -lt "$VERIFY_ATTEMPTS" ]; then
      sleep "$VERIFY_RETRY_DELAY_SECONDS"
    fi
    attempt=$((attempt + 1))
  done
  return 0
}

positive_response="$(query_logs "$query | fields service.name,service.version,dev.runtime.flavor,_msg | limit 20")"
if [ -z "$positive_response" ]; then
  echo "no AgentStudio debug records found in VictoriaLogs for query window $QUERY_START..$QUERY_END" >&2
  exit 1
fi

startup_response="$(
  query_logs \
    "$query $startup_event_query | fields _msg,agentstudio.app.startup.phase,agentstudio.app.startup.outcome | limit 5"
)"
if [ -z "$startup_response" ]; then
  echo "no completed app launch record found in VictoriaLogs for marker $MARKER" >&2
  exit 1
fi

required_startup_fields=(
  agentstudio.app.startup.phase
  agentstudio.app.startup.outcome
)

for field in "${required_startup_fields[@]}"; do
  if ! grep -q "\"$field\":" <<<"$startup_response"; then
    echo "completed app launch record missing field: $field" >&2
    echo "$startup_response" >&2
    exit 1
  fi
done

if [ "$state_preferences_mode" = "honor_preferences" ]; then
  preferences_response="$(
    query_logs \
      "$query $preferences_loaded_event_query | fields _msg,agentstudio.preferences.global.status,agentstudio.preferences.global.schema_version,agentstudio.preferences.global.observability_enabled,agentstudio.preferences.global.load_elapsed_ms | limit 5"
  )"
  if [ -z "$preferences_response" ]; then
    echo "no global preferences loaded record found in VictoriaLogs for marker $MARKER" >&2
    exit 1
  fi
  required_preferences_fields=(
    agentstudio.preferences.global.status
    agentstudio.preferences.global.load_elapsed_ms
  )
  for field in "${required_preferences_fields[@]}"; do
    if ! grep -q "\"$field\":" <<<"$preferences_response"; then
      echo "global preferences loaded record missing field: $field" >&2
      echo "$preferences_response" >&2
      exit 1
    fi
  done
fi

# R3 uses synchronous slices, never suspended lifetimes. Aggregate over every
# matching record in the marker/launch window: an absent phase is not a zero,
# and one valid sample cannot hide a later main-thread execution or missing field.
if [ "${AGENTSTUDIO_RESTORE_R3_COST_PROOF:-0}" = "1" ]; then
  restore_cost_phases=(
    "performance.restore.outbox.import"
    "performance.restore.resume.decide"
  )
  restore_cost_allowances=(
    "performance.restore.allowance.mount_apply"
    "performance.restore.allowance.resumed_start_end"
  )
  for restore_cost_phase in "${restore_cost_phases[@]}" "${restore_cost_allowances[@]}"; do
    restore_on_main=0
    case "$restore_cost_phase" in performance.restore.allowance.*) restore_on_main=1 ;; esac
    restore_valid_filter="agentstudio.performance.restore.execution.count:range[1,1] agentstudio.performance.restore.main_thread.execution.count:range[$restore_on_main,$restore_on_main] agentstudio.performance.elapsed_ms:range[0,Inf)"
    if [ "$restore_on_main" = "0" ]; then
      restore_valid_filter="$restore_valid_filter agentstudio.performance.restore.main_thread.elapsed_ms:range[0,0]"
    else
      restore_valid_filter="$restore_valid_filter agentstudio.performance.restore.main_thread.elapsed_ms:range[0,Inf)"
    fi
    restore_cost_phase_query="$query $(logsql_exact_filter "_msg" "$restore_cost_phase")"
    restore_cost_response="$(query_logs "$restore_cost_phase_query | stats count() as restore_records, count() if ($restore_valid_filter) as restore_valid_records, sum(agentstudio.performance.elapsed_ms) as restore_elapsed_ms, sum(agentstudio.performance.restore.main_thread.elapsed_ms) as restore_main_thread_elapsed_ms")"
    /usr/bin/python3 - "$restore_cost_phase" "$restore_on_main" "$restore_cost_response" <<'RESTORE_COST_PY'
import json
import math
import sys

class MissingRestorePhase(Exception):
    pass

phase, on_main, payload = sys.argv[1:]
try:
    rows = [json.loads(line) for line in payload.splitlines() if line.strip()]
    if not rows:
        raise MissingRestorePhase
    if len(rows) != 1:
        raise ValueError("expected one aggregate")
    row = rows[0]
    def scalar(key):
        value = float(row[key])
        if not math.isfinite(value) or value < 0:
            raise ValueError(key)
        return value
    count = scalar("restore_records")
    if count == 0:
        raise MissingRestorePhase
    valid = scalar("restore_valid_records")
    elapsed = scalar("restore_elapsed_ms")
    main_elapsed = scalar("restore_main_thread_elapsed_ms")
    if not count.is_integer() or valid != count:
        raise ValueError("a slice has missing/invalid counters or ran on the wrong thread")
    if on_main == "0" and main_elapsed != 0:
        raise ValueError("off-main phase contains main-thread time")
    if on_main == "1" and not math.isclose(elapsed, main_elapsed, rel_tol=1e-12, abs_tol=1e-12):
        raise ValueError("allowance elapsed time differs from its main-thread time")
except MissingRestorePhase:
    sys.exit("missing restore phase " + phase)
except (ValueError, TypeError, KeyError) as error:
    sys.exit("invalid restore phase " + phase + " cost telemetry: " + str(error))
print(f"restore cost {phase} slices={int(count)} elapsed_ms={elapsed} main_thread_elapsed_ms={main_elapsed}")
RESTORE_COST_PY
  done
fi

startup_diagnostic_action="${AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION:-$state_startup_diagnostic_action}"
if [ "$startup_diagnostic_action" = "sidebar-performance-proof" ]; then
  if [ "$state_activation_mode" != "background" ]; then
    echo "sidebar-performance-proof requires background LaunchServices activation mode: ${state_activation_mode:-<missing>}" >&2
    exit 1
  fi
  if [ "$state_ipc_auth_mode" != "authenticated" ]; then
    echo "sidebar-performance-proof requires authenticated IPC auth mode: ${state_ipc_auth_mode:-<missing>}" >&2
    exit 1
  fi
fi
if [ "$startup_diagnostic_action" = "cross-tab-move-geometry-smoke" ] ||
  [ "$startup_diagnostic_action" = "ipc-terminal-smoke" ] ||
  [ "$startup_diagnostic_action" = "pane-association-runtime-proof" ] ||
  [ "$startup_diagnostic_action" = "bridge-review-observability-smoke" ] ||
  [ "$startup_diagnostic_action" = "bridge-file-view-observability-smoke" ] ||
  [ "$startup_diagnostic_action" = "bridge-file-view-command-route-observability-smoke" ] ||
  [ "$startup_diagnostic_action" = "bridge-file-view-targeted-route-observability-smoke" ] ||
  [ "$startup_diagnostic_action" = "bridge-review-to-file-view-observability-smoke" ] ||
  [ "$startup_diagnostic_action" = "sidebar-performance-proof" ]; then
  startup_diagnostic_action_filter="$(
    logsql_exact_filter agentstudio.startup_diagnostic.action "$startup_diagnostic_action"
  )"
  diagnostic_query="$query $startup_diagnostic_action_filter"
  diagnostic_fields="_msg,agentstudio.startup_diagnostic.action,agentstudio.startup_diagnostic.created_pane.count"
  if [ "$startup_diagnostic_action" = "ipc-terminal-smoke" ]; then
    diagnostic_fields="_msg,agentstudio.startup_diagnostic.action,agentstudio.startup_diagnostic.created_pane.count,agentstudio.startup_diagnostic.expected_visible_pane.count,agentstudio.startup_diagnostic.fixture.terminal_view.count,agentstudio.startup_diagnostic.fixture.surface_reference.count,agentstudio.startup_diagnostic.fixture.surface.count,agentstudio.startup_diagnostic.fixture.valid_geometry.count,agentstudio.startup_diagnostic.render_proof.succeeded"
  fi
  if [ "$startup_diagnostic_action" = "cross-tab-move-geometry-smoke" ]; then
    diagnostic_fields="_msg,agentstudio.startup_diagnostic.action,agentstudio.startup_diagnostic.expected_visible_pane.count,agentstudio.startup_diagnostic.fixture.terminal_view.count,agentstudio.startup_diagnostic.fixture.surface_reference.count,agentstudio.startup_diagnostic.fixture.surface.count,agentstudio.startup_diagnostic.fixture.valid_geometry.count,agentstudio.startup_diagnostic.render_proof.succeeded"
  fi
  if [ "$startup_diagnostic_action" = "pane-association-runtime-proof" ]; then
    diagnostic_fields="_msg,agentstudio.startup_diagnostic.action,agentstudio.startup_diagnostic.created_pane.count,agentstudio.startup_diagnostic.association.initial_succeeded,agentstudio.startup_diagnostic.association.cwd_move_succeeded,agentstudio.startup_diagnostic.association.topology_clear_succeeded,agentstudio.startup_diagnostic.association.topology_residency_preserved,agentstudio.startup_diagnostic.association.topology_adopt_succeeded,agentstudio.startup_diagnostic.association.free_pane_remained_nil,agentstudio.startup_diagnostic.association_proof.succeeded"
  fi
  if [ "$startup_diagnostic_action" = "bridge-review-observability-smoke" ]; then
    review_diagnostic_fields="agentstudio.startup_diagnostic.bridge.review_expected_item.count,agentstudio.startup_diagnostic.bridge.review_metadata_item.count,agentstudio.startup_diagnostic.bridge.review_metadata_tree_row.count,agentstudio.startup_diagnostic.bridge.review_metadata.converged"
    review_diagnostic_fields="$review_diagnostic_fields,agentstudio.startup_diagnostic.bridge.review_tree_scroll_stress.count,agentstudio.startup_diagnostic.bridge.review_tree_scroll_stress.reached_bottom,agentstudio.startup_diagnostic.bridge.review_tree.client_height_px,agentstudio.startup_diagnostic.bridge.review_tree.scroll_height_px"
    review_diagnostic_fields="$review_diagnostic_fields,agentstudio.startup_diagnostic.bridge.review_tree_click.selected_matches_target,agentstudio.startup_diagnostic.bridge.review_tree_click.selected_content_state,agentstudio.startup_diagnostic.bridge.review_tree_click.selected_materialized.item_type,agentstudio.startup_diagnostic.bridge.review_tree_click.selected_materialized.item_version,agentstudio.startup_diagnostic.bridge.review_tree_click.selected_content_character.count"
    review_diagnostic_fields="$review_diagnostic_fields,agentstudio.startup_diagnostic.bridge.review_shell.visible,agentstudio.startup_diagnostic.bridge.review_shell.state,agentstudio.startup_diagnostic.bridge.review_canvas.branch,agentstudio.startup_diagnostic.bridge.review_shell.selected_path.visible,agentstudio.startup_diagnostic.bridge.review_shell.selected_content.state,agentstudio.startup_diagnostic.bridge.code_view.visible,agentstudio.startup_diagnostic.bridge.selected_item.visible,agentstudio.startup_diagnostic.bridge.selected_path.visible,agentstudio.startup_diagnostic.bridge.selected_change_kind"
    review_diagnostic_fields="$review_diagnostic_fields,agentstudio.startup_diagnostic.bridge.selected_demand.failed.count,agentstudio.startup_diagnostic.bridge.selected_demand.deferred.count,agentstudio.startup_diagnostic.bridge.selected_demand.loaded.count,agentstudio.startup_diagnostic.bridge.selected_demand.result.status,agentstudio.startup_diagnostic.bridge.selected_demand.result.reason,agentstudio.startup_diagnostic.bridge.selected_demand.load_failure.kind"
    review_diagnostic_fields="$review_diagnostic_fields,agentstudio.startup_diagnostic.bridge.selected_content.visible,agentstudio.startup_diagnostic.bridge.selected_content.state,agentstudio.startup_diagnostic.bridge.selected_content.roles,agentstudio.startup_diagnostic.bridge.selected_content.cache_keys_present,agentstudio.startup_diagnostic.bridge.selected_content_role.count,agentstudio.startup_diagnostic.bridge.selected_content_cache_key.count,agentstudio.startup_diagnostic.bridge.selected_content_character.count,agentstudio.startup_diagnostic.bridge.selected_content_line.count"
    review_diagnostic_fields="$review_diagnostic_fields,agentstudio.startup_diagnostic.bridge.selected_materialized.update_result,agentstudio.startup_diagnostic.bridge.selected_materialized.item_type,agentstudio.startup_diagnostic.bridge.selected_materialized.item_version,agentstudio.startup_diagnostic.bridge.selected_materialized.addition_line.count,agentstudio.startup_diagnostic.bridge.selected_materialized.deletion_line.count,agentstudio.startup_diagnostic.bridge.selected_materialized.file_line.count"
    review_diagnostic_fields="$review_diagnostic_fields,agentstudio.startup_diagnostic.bridge.modified_click.filter_requested,agentstudio.startup_diagnostic.bridge.modified_click.click_attempt.count,agentstudio.startup_diagnostic.bridge.modified_click.target_found,agentstudio.startup_diagnostic.bridge.modified_click.first_rendered_present,agentstudio.startup_diagnostic.bridge.modified_click.selected_matches_target,agentstudio.startup_diagnostic.bridge.modified_click.shell_selected_matches_target,agentstudio.startup_diagnostic.bridge.modified_click.rendered_row.count,agentstudio.startup_diagnostic.bridge.modified_click.set_filter.status,agentstudio.startup_diagnostic.bridge.modified_click.set_filter.reason"
    review_diagnostic_fields="$review_diagnostic_fields,agentstudio.startup_diagnostic.bridge.modified_click.selected_change_kind,agentstudio.startup_diagnostic.bridge.modified_click.selected_content_state,agentstudio.startup_diagnostic.bridge.modified_click.selected_content.roles,agentstudio.startup_diagnostic.bridge.modified_click.selected_content.cache_keys_present,agentstudio.startup_diagnostic.bridge.modified_click.selected_materialized.item_type,agentstudio.startup_diagnostic.bridge.modified_click.selected_materialized.item_version,agentstudio.startup_diagnostic.bridge.modified_click.selected_content_character.count"
    review_diagnostic_fields="$review_diagnostic_fields,agentstudio.startup_diagnostic.bridge.diff_container.count,agentstudio.startup_diagnostic.bridge.code_text.length,agentstudio.startup_diagnostic.bridge.code_shadow_text.length"
    review_native_fields="agentstudio.startup_diagnostic.bridge.bridge_command.count,agentstudio.startup_diagnostic.bridge.review_intake_ready_command.count,agentstudio.startup_diagnostic.bridge.bridge_response.count,agentstudio.startup_diagnostic.bridge.intake_frame.count,agentstudio.startup_diagnostic.bridge.review_intake_snapshot_frame.count,agentstudio.startup_diagnostic.bridge.review_intake_metadata_window_frame.count,agentstudio.startup_diagnostic.bridge.review_intake.last_frame_kind,agentstudio.startup_diagnostic.bridge.review_intake.last_stream_id_matches"
    review_worker_fields="agentstudio.startup_diagnostic.bridge.worker_pool.state,agentstudio.startup_diagnostic.bridge.worker_pool.manager_state,agentstudio.startup_diagnostic.bridge.worker_pool.workers_failed,agentstudio.startup_diagnostic.bridge.worker_diagnostic.diff_success_count,agentstudio.startup_diagnostic.bridge.worker_diagnostic.failure_count,agentstudio.startup_diagnostic.bridge.page_issue.count,agentstudio.startup_diagnostic.bridge.page_issue.last_kind,agentstudio.startup_diagnostic.bridge.page_issue.last_class,agentstudio.startup_diagnostic.bridge.page_issue.disallowed.count,agentstudio.startup_diagnostic.bridge.frame_liveness.raf_alive,agentstudio.startup_diagnostic.bridge.frame_liveness.raf_fired_latency.bucket"
    diagnostic_fields="_msg,agentstudio.startup_diagnostic.action,agentstudio.startup_diagnostic.expected_visible_pane.count,$review_diagnostic_fields,$review_native_fields,$review_worker_fields,agentstudio.startup_diagnostic.render_proof.succeeded"
  fi
  if [ "$startup_diagnostic_action" = "bridge-file-view-observability-smoke" ] ||
    [ "$startup_diagnostic_action" = "bridge-file-view-command-route-observability-smoke" ] ||
    [ "$startup_diagnostic_action" = "bridge-file-view-targeted-route-observability-smoke" ] ||
    [ "$startup_diagnostic_action" = "bridge-review-to-file-view-observability-smoke" ]; then
    file_view_diagnostic_fields="agentstudio.startup_diagnostic.bridge.file_view.shell.visible,agentstudio.startup_diagnostic.bridge.file_view.tree.visible,agentstudio.startup_diagnostic.bridge.file_view.code_view.visible,agentstudio.startup_diagnostic.bridge.file_view.expected_bootstrap.protocol,agentstudio.startup_diagnostic.bridge.file_view.bootstrap.protocol,agentstudio.startup_diagnostic.bridge.file_view.descriptor.count,agentstudio.startup_diagnostic.bridge.file_view.total_descriptor.count,agentstudio.startup_diagnostic.bridge.file_view.tree_extent.kind,agentstudio.startup_diagnostic.bridge.file_view.tree_path.count,agentstudio.startup_diagnostic.bridge.file_view.metadata_tree_row.count,agentstudio.startup_diagnostic.bridge.file_view.metadata_file_row.count,agentstudio.startup_diagnostic.bridge.file_view.source.state,agentstudio.startup_diagnostic.bridge.file_view.open_file.state,agentstudio.startup_diagnostic.bridge.file_view.body_preview.length,agentstudio.startup_diagnostic.bridge.file_view.tree.height_px,agentstudio.startup_diagnostic.bridge.file_view.code_view.width_px,agentstudio.startup_diagnostic.bridge.file_view.code_view.height_px,agentstudio.startup_diagnostic.bridge.file_view.code_text.length,agentstudio.startup_diagnostic.bridge.file_view.bridge_command.count,agentstudio.startup_diagnostic.bridge.file_view.open_source_command.count,agentstudio.startup_diagnostic.bridge.file_view.intake_ready_command.count,agentstudio.startup_diagnostic.bridge.file_view.descriptor_request_command.count,agentstudio.startup_diagnostic.bridge.file_view.bridge_response.count,agentstudio.startup_diagnostic.bridge.file_view.intake_frame.count,agentstudio.startup_diagnostic.bridge.file_view.native_probe.count,agentstudio.startup_diagnostic.bridge.file_view.native_probe.last_reason,agentstudio.startup_diagnostic.bridge.file_view.native_probe.last_receiver_reason,agentstudio.startup_diagnostic.bridge.file_view.native_probe.last_frame_kind,agentstudio.startup_diagnostic.bridge.file_view.native_probe.last_generation,agentstudio.startup_diagnostic.bridge.file_view.native_probe.last_sequence,agentstudio.startup_diagnostic.bridge.file_view.native_probe.last_stream_id_matches"
    file_view_click_fields="agentstudio.startup_diagnostic.bridge.file_view.click.target_found,agentstudio.startup_diagnostic.bridge.file_view.click.selected_matches,agentstudio.startup_diagnostic.bridge.file_view.click.open_file_matches,agentstudio.startup_diagnostic.bridge.file_view.click.rendered_file_matches,agentstudio.startup_diagnostic.bridge.file_view.click.body_preview.length,agentstudio.startup_diagnostic.bridge.file_view.second_click.target_found,agentstudio.startup_diagnostic.bridge.file_view.second_click.selected_matches,agentstudio.startup_diagnostic.bridge.file_view.second_click.open_file_matches,agentstudio.startup_diagnostic.bridge.file_view.second_click.rendered_file_matches,agentstudio.startup_diagnostic.bridge.file_view.second_click.body_preview.length,agentstudio.startup_diagnostic.bridge.file_view.offscreen_click.target_found,agentstudio.startup_diagnostic.bridge.file_view.offscreen_click.selected_matches,agentstudio.startup_diagnostic.bridge.file_view.offscreen_click.open_file_matches,agentstudio.startup_diagnostic.bridge.file_view.offscreen_click.rendered_file_matches,agentstudio.startup_diagnostic.bridge.file_view.offscreen_click.body_preview.length"
    file_view_stress_fields="agentstudio.startup_diagnostic.bridge.file_view.mode_switch.count,agentstudio.startup_diagnostic.bridge.file_view.mode_switch.final_file_selected,agentstudio.startup_diagnostic.bridge.file_view.tree_scroll_stress.count,agentstudio.startup_diagnostic.bridge.file_view.tree_scroll_stress.reached_bottom"
    file_view_worker_fields="agentstudio.startup_diagnostic.bridge.worker_pool.state,agentstudio.startup_diagnostic.bridge.worker_pool.manager_state,agentstudio.startup_diagnostic.bridge.worker_pool.workers_failed,agentstudio.startup_diagnostic.bridge.worker_diagnostic.file_success_count,agentstudio.startup_diagnostic.bridge.worker_diagnostic.failure_count,agentstudio.startup_diagnostic.bridge.page_issue.count,agentstudio.startup_diagnostic.bridge.page_issue.last_kind,agentstudio.startup_diagnostic.bridge.page_issue.last_class,agentstudio.startup_diagnostic.bridge.page_issue.disallowed.count,agentstudio.startup_diagnostic.bridge.frame_liveness.raf_alive,agentstudio.startup_diagnostic.bridge.frame_liveness.raf_fired_latency.bucket"
    diagnostic_fields="_msg,agentstudio.startup_diagnostic.action,agentstudio.startup_diagnostic.expected_visible_pane.count,$file_view_diagnostic_fields,$file_view_click_fields,$file_view_stress_fields,$file_view_worker_fields,agentstudio.startup_diagnostic.render_proof.succeeded"
  fi
  if [ "$startup_diagnostic_action" = "sidebar-performance-proof" ]; then
    diagnostic_fields="_msg,agentstudio.startup_diagnostic.action,agentstudio.startup_diagnostic.native_table_pilot.scale.count,agentstudio.startup_diagnostic.native_table_pilot.completed,agentstudio.startup_diagnostic.native_table_pilot.passed"
  fi
  diagnostic_command_response="$(
    wait_for_log_query \
      "startup diagnostic command_exercised record missing for action $startup_diagnostic_action" \
      "$diagnostic_query _msg:app.startup_diagnostic_action.command_exercised | fields $diagnostic_fields | limit 5"
  )"

  diagnostic_completed_response="$(
    wait_for_optional_log_query \
      "$diagnostic_query _msg:app.startup_diagnostic_action.completed | fields $diagnostic_fields | limit 5"
  )"
  if [ -z "$diagnostic_completed_response" ]; then
    diagnostic_blocked_response="$(
      query_logs \
        "$diagnostic_query _msg:app.startup_diagnostic_action.blocked | fields $diagnostic_fields,agentstudio.startup_diagnostic.skip_reason | limit 5"
    )"
    diagnostic_skipped_response="$(
      wait_for_optional_log_query \
        "$diagnostic_query _msg:app.startup_diagnostic_action.skipped | fields $diagnostic_fields,agentstudio.startup_diagnostic.skip_reason | limit 5"
    )"
    if is_frame_not_live_skip "$diagnostic_skipped_response"; then
      echo "SKIP startup diagnostic $startup_diagnostic_action: frame_not_live"
      echo "$diagnostic_skipped_response"
      exit 0
    fi
    echo "startup diagnostic did not complete successfully for action $startup_diagnostic_action" >&2
    if [ -n "$diagnostic_blocked_response" ]; then
      echo "$diagnostic_blocked_response" >&2
    fi
    if [ -n "$diagnostic_skipped_response" ]; then
      echo "$diagnostic_skipped_response" >&2
    fi
    exit 1
  fi
  if [ "$startup_diagnostic_action" = "ipc-terminal-smoke" ] &&
    ! grep -Eq '"agentstudio.startup_diagnostic.created_pane.count":("?1"?)([,}[:space:]]|$)' <<<"$diagnostic_completed_response"; then
    echo "startup diagnostic completed without creating one IPC smoke pane for action $startup_diagnostic_action" >&2
    echo "$diagnostic_completed_response" >&2
    exit 1
  fi
  diagnostic_proof_field="agentstudio.startup_diagnostic.render_proof.succeeded"
  if [ "$startup_diagnostic_action" = "sidebar-performance-proof" ]; then
    diagnostic_proof_field="agentstudio.startup_diagnostic.native_table_pilot.passed"
  fi
  if [ "$startup_diagnostic_action" = "pane-association-runtime-proof" ]; then
    diagnostic_proof_field="agentstudio.startup_diagnostic.association_proof.succeeded"
  fi
  if ! json_truthy_field "$diagnostic_proof_field" "$diagnostic_completed_response"; then
    if [ "$startup_diagnostic_action" = "ipc-terminal-smoke" ]; then
      echo "startup diagnostic completed without successful IPC terminal render proof for action $startup_diagnostic_action" >&2
    else
      echo "startup diagnostic completed without successful proof for action $startup_diagnostic_action" >&2
    fi
    echo "$diagnostic_completed_response" >&2
    exit 1
  fi
  if [ "$startup_diagnostic_action" = "pane-association-runtime-proof" ] &&
    ! json_truthy_field "agentstudio.startup_diagnostic.association.topology_residency_preserved" "$diagnostic_completed_response"; then
    echo "pane association runtime proof did not verify active residency preservation" >&2
    echo "$diagnostic_completed_response" >&2
    exit 1
  fi
  if [ "$startup_diagnostic_action" = "pane-association-runtime-proof" ]; then
    association_outcome_response="$(
      wait_for_log_query \
        "pane association outcome telemetry missing" \
        "$query _msg:performance.pane.association | fields _msg,agentstudio.performance.pane.association_outcome | limit 65"
    )"
    association_outcome_count="$(grep -c 'performance.pane.association' <<<"$association_outcome_response" || true)"
    if [ "$association_outcome_count" -lt 3 ] || [ "$association_outcome_count" -gt 64 ]; then
      echo "pane association outcome telemetry must contain 3...64 bounded records; got $association_outcome_count" >&2
      echo "$association_outcome_response" >&2
      exit 1
    fi
    for required_association_outcome in resolved_changed free_nil topology_removed; do
      if ! grep -q "\"agentstudio.performance.pane.association_outcome\":\"$required_association_outcome\"" <<<"$association_outcome_response"; then
        echo "pane association outcome telemetry missing $required_association_outcome" >&2
        echo "$association_outcome_response" >&2
        exit 1
      fi
    done
  fi
  if [ "$startup_diagnostic_action" = "bridge-review-observability-smoke" ]; then
    require_json_fields \
      "Bridge Review diagnostic native lineage proof" \
      "$diagnostic_completed_response" \
      agentstudio.startup_diagnostic.bridge.bridge_command.count \
      agentstudio.startup_diagnostic.bridge.review_intake_ready_command.count \
      agentstudio.startup_diagnostic.bridge.bridge_response.count \
      agentstudio.startup_diagnostic.bridge.intake_frame.count \
      agentstudio.startup_diagnostic.bridge.review_intake_snapshot_frame.count \
      agentstudio.startup_diagnostic.bridge.review_intake_metadata_window_frame.count \
      agentstudio.startup_diagnostic.bridge.review_intake.last_frame_kind \
      agentstudio.startup_diagnostic.bridge.review_intake.last_stream_id_matches \
      agentstudio.startup_diagnostic.bridge.page_issue.disallowed.count
  fi
  if [ "$startup_diagnostic_action" = "bridge-file-view-observability-smoke" ] ||
    [ "$startup_diagnostic_action" = "bridge-file-view-command-route-observability-smoke" ] ||
    [ "$startup_diagnostic_action" = "bridge-file-view-targeted-route-observability-smoke" ] ||
    [ "$startup_diagnostic_action" = "bridge-review-to-file-view-observability-smoke" ]; then
    require_json_fields \
      "Bridge FileView diagnostic native path proof" \
      "$diagnostic_completed_response" \
      agentstudio.startup_diagnostic.bridge.file_view.bridge_command.count \
      agentstudio.startup_diagnostic.bridge.file_view.open_source_command.count \
      agentstudio.startup_diagnostic.bridge.file_view.intake_ready_command.count \
      agentstudio.startup_diagnostic.bridge.file_view.descriptor_request_command.count \
      agentstudio.startup_diagnostic.bridge.file_view.bridge_response.count \
      agentstudio.startup_diagnostic.bridge.file_view.intake_frame.count \
      agentstudio.startup_diagnostic.bridge.file_view.native_probe.count \
      agentstudio.startup_diagnostic.bridge.file_view.native_probe.last_stream_id_matches \
      agentstudio.startup_diagnostic.bridge.page_issue.disallowed.count
    require_bridge_file_view_native_metric_percentiles
    require_bridge_viewer_ttfi_report_only_gate
  fi
fi

if [ "$startup_diagnostic_action" = "tcc-upgrade-probe" ]; then
  startup_diagnostic_action_filter="$(
    logsql_exact_filter agentstudio.startup_diagnostic.action "$startup_diagnostic_action"
  )"
  tcc_probe_event_query="$(logsql_exact_filter "_msg" "terminal.tcc.access_probe")"
  tcc_identity_event_query="$(logsql_exact_filter "_msg" "terminal.tcc.app_identity_snapshot")"
  diagnostic_query="$query $startup_diagnostic_action_filter"
  tcc_identity_response="$(
    query_logs \
      "$diagnostic_query $tcc_identity_event_query | fields _msg,agentstudio.tcc.phase,agentstudio.tcc.bundle.kind,agentstudio.tcc.code_identity.kind,agentstudio.tcc.bundle.changed,agentstudio.tcc.bundle.executable.reachable,agentstudio.tcc.probe.sequence | limit 5"
  )"
  if [ -z "$tcc_identity_response" ]; then
    echo "TCC app identity snapshot missing for action $startup_diagnostic_action" >&2
    exit 1
  fi
  tcc_probe_response="$(
    query_logs \
      "$diagnostic_query $tcc_probe_event_query | fields _msg,agentstudio.tcc.phase,agentstudio.tcc.subject,agentstudio.tcc.access.target,agentstudio.tcc.access.result,agentstudio.tcc.responsible.kind,agentstudio.tcc.command.exit_class,agentstudio.tcc.probe.sequence | limit 5"
  )"
  if [ -z "$tcc_probe_response" ]; then
    echo "TCC upgrade probe record missing for action $startup_diagnostic_action" >&2
    exit 1
  fi
  required_tcc_fields=(
    agentstudio.tcc.phase
    agentstudio.tcc.subject
    agentstudio.tcc.access.target
    agentstudio.tcc.access.result
    agentstudio.tcc.responsible.kind
    agentstudio.tcc.command.exit_class
    agentstudio.tcc.probe.sequence
  )
  required_tcc_identity_fields=(
    agentstudio.tcc.phase
    agentstudio.tcc.bundle.kind
    agentstudio.tcc.code_identity.kind
    agentstudio.tcc.bundle.changed
    agentstudio.tcc.bundle.executable.reachable
    agentstudio.tcc.probe.sequence
  )
  for field in "${required_tcc_identity_fields[@]}"; do
    if ! grep -q "\"$field\":" <<<"$tcc_identity_response"; then
      echo "TCC app identity snapshot missing field: $field" >&2
      echo "$tcc_identity_response" >&2
      exit 1
    fi
  done
  for field in "${required_tcc_fields[@]}"; do
    if ! grep -q "\"$field\":" <<<"$tcc_probe_response"; then
      echo "TCC upgrade probe record missing field: $field" >&2
      echo "$tcc_probe_response" >&2
      exit 1
    fi
  done
  if [ "${AGENTSTUDIO_TCC_REQUIRE_PROTECTED_DATA_GRANT:-0}" = "1" ]; then
    tcc_messages_target_filter="$(logsql_exact_filter agentstudio.tcc.access.target messages_data)"
    tcc_granted_result_filter="$(logsql_exact_filter agentstudio.tcc.access.result granted)"
    tcc_denied_result_response=""
    for tcc_denied_result in denied_eacces denied_eperm path_missing timed_out unknown_error; do
      tcc_denied_result_filter="$(logsql_exact_filter agentstudio.tcc.access.result "$tcc_denied_result")"
      tcc_denied_result_response="$(
        query_logs \
          "$diagnostic_query $tcc_probe_event_query $tcc_messages_target_filter $tcc_denied_result_filter | fields _msg,agentstudio.tcc.access.target,agentstudio.tcc.access.result,agentstudio.tcc.command.exit_class,agentstudio.tcc.probe.sequence | limit 1"
      )"
      if [ -n "$tcc_denied_result_response" ]; then
        echo "TCC protected-data grant was required but messages_data had non-granted result $tcc_denied_result for action $startup_diagnostic_action" >&2
        echo "$tcc_denied_result_response" >&2
        exit 1
      fi
    done
    tcc_messages_grant_response="$(
      query_logs \
        "$diagnostic_query $tcc_probe_event_query $tcc_messages_target_filter $tcc_granted_result_filter | fields _msg,agentstudio.tcc.access.target,agentstudio.tcc.access.result,agentstudio.tcc.command.exit_class,agentstudio.tcc.probe.sequence | limit 1"
    )"
    if [ -z "$tcc_messages_grant_response" ]; then
      echo "TCC protected-data grant was required but messages_data was not granted for action $startup_diagnostic_action" >&2
      echo "$tcc_probe_response" >&2
      exit 1
    fi
  fi
fi

sensitive_fields=(
  agent.proof.marker.raw
  db.statement
  dev.repo.name
  error
  error.message
  exception.message
  payload
  process.pid
  secret
  token
)

for field in "${sensitive_fields[@]}"; do
  sensitive_response="$(query_logs "$query ${field}:* | limit 1")"
  if [ -n "$sensitive_response" ]; then
    echo "sensitive field survived AgentStudio debug OTLP export: $field" >&2
    echo "$sensitive_response" >&2
    exit 1
  fi
done

echo "debug observability ok:"
echo "launch_method=$state_launch_method activation_mode=${state_activation_mode:-unknown} ipc_auth_mode=${state_ipc_auth_mode:-unknown}"
sed -n '1,5p' <<<"$startup_response"
