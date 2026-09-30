#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

DEFAULT_STACK_HELPER="$HOME/dev/ai-tools/observability/observability-stack"
STACK_HELPER="${AI_TOOLS_OBSERVABILITY_STACK_HELPER:-$DEFAULT_STACK_HELPER}"
COLLECTOR_HEALTH_URL="${AI_TOOLS_OBSERVABILITY_COLLECTOR_HEALTH_URL:-http://127.0.0.1:13133/}"
LOGS_QUERY_URL="${AI_TOOLS_OBSERVABILITY_LOGS_QUERY_URL:-http://127.0.0.1:9428/select/logsql/query}"
CURL_BIN="${AGENTSTUDIO_CURL_BIN:-/usr/bin/curl}"
SAMPLE_COUNT="${AGENTSTUDIO_GLOBAL_PREFERENCES_STARTUP_SAMPLE_COUNT:-5}"
MEDIAN_DELTA_BUDGET_MS="${AGENTSTUDIO_GLOBAL_PREFERENCES_STARTUP_MEDIAN_DELTA_BUDGET_MS:-25}"
MAX_DELTA_BUDGET_MS="${AGENTSTUDIO_GLOBAL_PREFERENCES_STARTUP_MAX_DELTA_BUDGET_MS:-75}"
VERIFY_ATTEMPTS="${AGENTSTUDIO_GLOBAL_PREFERENCES_STARTUP_VERIFY_ATTEMPTS:-30}"
VERIFY_DELAY_SECONDS="${AGENTSTUDIO_GLOBAL_PREFERENCES_STARTUP_VERIFY_DELAY_SECONDS:-1}"
ARTIFACT_ROOT="${AGENTSTUDIO_GLOBAL_PREFERENCES_STARTUP_ARTIFACT_ROOT:-$PROJECT_ROOT/tmp/global-preferences-startup-performance/$(date -u +%Y%m%dT%H%M%SZ)}"
SAMPLES_FILE="$ARTIFACT_ROOT/raw-launch-samples.tsv"
SUMMARY_FILE="$ARTIFACT_ROOT/summary.json"

# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/observability-control-guards.sh"

fail_on_legacy_observability_env
validate_observability_controls "$DEFAULT_STACK_HELPER" "$STACK_HELPER" "$COLLECTOR_HEALTH_URL"
validate_loopback_url AI_TOOLS_OBSERVABILITY_LOGS_QUERY_URL "$LOGS_QUERY_URL"

if ! [[ "$SAMPLE_COUNT" =~ ^[0-9]+$ ]] || [ "$SAMPLE_COUNT" -lt 5 ]; then
  echo "AGENTSTUDIO_GLOBAL_PREFERENCES_STARTUP_SAMPLE_COUNT must be an integer >= 5" >&2
  exit 2
fi
if ! [[ "$VERIFY_ATTEMPTS" =~ ^[0-9]+$ ]] || [ "$VERIFY_ATTEMPTS" -lt 1 ]; then
  echo "AGENTSTUDIO_GLOBAL_PREFERENCES_STARTUP_VERIFY_ATTEMPTS must be an integer >= 1" >&2
  exit 2
fi
if ! [[ "$VERIFY_DELAY_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "AGENTSTUDIO_GLOBAL_PREFERENCES_STARTUP_VERIFY_DELAY_SECONDS must be a non-negative number" >&2
  exit 2
fi

export SWIFT_TEST_PREBUILD_TIMEOUT_SECONDS="${SWIFT_TEST_PREBUILD_TIMEOUT_SECONDS:-300}"
export SWIFT_TEST_TIMEOUT_SECONDS="${SWIFT_TEST_TIMEOUT_SECONDS:-120}"

echo "global preferences loader benchmark budget: p95 <= 2 ms, max <= 10 ms"
mise run test:swift -- --filter globalPreferencesLoaderStaysWithinStartupBudget

if ! "$CURL_BIN" --fail --silent --show-error --max-time 2 "$COLLECTOR_HEALTH_URL" >/dev/null; then
  echo "OTLP collector is not healthy at $COLLECTOR_HEALTH_URL" >&2
  echo "Run: mise run observability:up" >&2
  exit 1
fi

mkdir -p "$ARTIFACT_ROOT"
printf 'mode\tindex\tmarker\tlaunch_command_elapsed_ms\tpreference_load_elapsed_ms\tstartup_elapsed_ms\tpreferences_status\tstate_file\n' >"$SAMPLES_FILE"

now_ms() {
  /usr/bin/python3 - <<'PY'
import time

print(int(time.monotonic_ns() / 1_000_000))
PY
}

state_value() {
  local state_file="${1:?missing state file}"
  local key="${2:?missing state key}"
  /usr/bin/python3 - "$state_file" "$key" <<'PY'
import shlex
import sys

state_file, wanted_key = sys.argv[1], sys.argv[2]
try:
    with open(state_file, encoding="utf-8") as handle:
        for raw_line in handle:
            key, separator, raw_value = raw_line.rstrip("\n").partition("=")
            if separator and key == wanted_key:
                try:
                    parsed = shlex.split(raw_value)
                except ValueError:
                    parsed = []
                print(parsed[0] if parsed else "")
                break
except FileNotFoundError:
    pass
PY
}

logsql_exact_filter() {
  local field="${1:?missing field}"
  local value="${2:?missing value}"
  local escaped
  escaped="${value//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  printf '%s:="%s"' "$field" "$escaped"
}

query_logs() {
  local query="${1:?missing query}"
  local query_start="${2:?missing query start}"
  local query_end
  query_end="$(
    /usr/bin/python3 - <<'PY'
from datetime import datetime, timedelta, timezone

print((datetime.now(timezone.utc) + timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
  )"
  "$CURL_BIN" --fail --silent --show-error --max-time 5 --get \
    --data-urlencode "query=$query" \
    --data-urlencode "start=$query_start" \
    --data-urlencode "end=$query_end" \
    "$LOGS_QUERY_URL"
}

preference_status_for_marker() {
  local marker="${1:?missing marker}"
  local proof_token="${2:?missing proof token}"
  local query_start="${3:?missing query start}"
  local marker_filter proof_filter event_filter query response
  marker_filter="$(logsql_exact_filter "agent.proof.marker" "$marker")"
  proof_filter="$(logsql_exact_filter "agent.proof.launch" "$proof_token")"
  event_filter="$(logsql_exact_filter "_msg" "app.preferences.global.loaded")"
  query="{service.name=\"AgentStudio\",dev.runtime.flavor=\"debug\"} $marker_filter $proof_filter $event_filter | fields agentstudio.preferences.global.status,agentstudio.preferences.global.load_elapsed_ms | limit 5"
  response="$(query_logs "$query" "$query_start")"
  if [ -z "$response" ]; then
    echo "no global preferences loaded record found for marker $marker" >&2
    return 1
  fi
  /usr/bin/python3 - "$response" <<'PY'
import json
import sys

for line in sys.argv[1].splitlines():
    try:
        record = json.loads(line)
    except json.JSONDecodeError:
        continue
    status = record.get("agentstudio.preferences.global.status")
    load_elapsed = record.get("agentstudio.preferences.global.load_elapsed_ms")
    if isinstance(status, str) and load_elapsed is not None:
        print(f"{status}\t{load_elapsed}")
        raise SystemExit(0)
raise SystemExit(1)
PY
}

event_time_for_marker() {
  local marker="${1:?missing marker}"
  local proof_token="${2:?missing proof token}"
  local query_start="${3:?missing query start}"
  local event_name="${4:?missing event name}"
  local marker_filter proof_filter event_filter query response
  marker_filter="$(logsql_exact_filter "agent.proof.marker" "$marker")"
  proof_filter="$(logsql_exact_filter "agent.proof.launch" "$proof_token")"
  event_filter="$(logsql_exact_filter "_msg" "$event_name")"
  query="{service.name=\"AgentStudio\",dev.runtime.flavor=\"debug\"} $marker_filter $proof_filter $event_filter | fields _time,_msg | limit 5"
  response="$(query_logs "$query" "$query_start")"
  if [ -z "$response" ]; then
    echo "no $event_name record found for marker $marker" >&2
    return 1
  fi
  /usr/bin/python3 - "$response" <<'PY'
import json
import sys

for line in sys.argv[1].splitlines():
    try:
        record = json.loads(line)
    except json.JSONDecodeError:
        continue
    timestamp = record.get("_time")
    if isinstance(timestamp, str) and timestamp:
        print(timestamp)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

startup_elapsed_for_marker() {
  local marker="${1:?missing marker}"
  local proof_token="${2:?missing proof token}"
  local query_start="${3:?missing query start}"
  local process_start_time startup_complete_time
  process_start_time="$(event_time_for_marker "$marker" "$proof_token" "$query_start" "app.process.start")"
  startup_complete_time="$(event_time_for_marker "$marker" "$proof_token" "$query_start" "app.did_finish_launching.succeeded")"
  /usr/bin/python3 - "$process_start_time" "$startup_complete_time" <<'PY'
from datetime import datetime
import re
import sys

def parse_rfc3339(raw: str) -> datetime:
    match = re.match(
        r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})$",
        raw,
    )
    if match is None:
        raise ValueError(f"Invalid RFC3339 timestamp: {raw}")
    base, fractional, timezone = match.groups()
    normalized_timezone = "+00:00" if timezone == "Z" else timezone
    normalized_fractional = ((fractional or "") + "000000")[:6]
    return datetime.strptime(
        f"{base}.{normalized_fractional}{normalized_timezone}",
        "%Y-%m-%dT%H:%M:%S.%f%z",
    )

start = parse_rfc3339(sys.argv[1])
finish = parse_rfc3339(sys.argv[2])
elapsed_ms = (finish - start).total_seconds() * 1000
if elapsed_ms < 0:
    raise SystemExit(1)
print(f"{elapsed_ms:.6f}")
PY
}

wait_for_debug_observability() {
  local state_file="${1:?missing state file}"
  local attempt output
  for attempt in $(seq 1 "$VERIFY_ATTEMPTS"); do
    if output="$(env AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$state_file" "$PROJECT_ROOT/scripts/verify-debug-observability.sh" 2>&1)"; then
      printf '%s\n' "$output"
      return 0
    fi
    if ! grep -Eq 'no AgentStudio debug records found|no completed app launch record found|no global preferences loaded record found' <<<"$output"; then
      printf '%s\n' "$output" >&2
      return 1
    fi
    if [ "$attempt" -lt "$VERIFY_ATTEMPTS" ]; then
      sleep "$VERIFY_DELAY_SECONDS"
    fi
  done
  echo "debug observability verification did not become visible after $VERIFY_ATTEMPTS attempts" >&2
  printf '%s\n' "$output" >&2
  return 1
}

wait_for_preference_status() {
  local marker="${1:?missing marker}"
  local proof_token="${2:?missing proof token}"
  local query_start="${3:?missing query start}"
  local attempt output
  for attempt in $(seq 1 "$VERIFY_ATTEMPTS"); do
    if output="$(preference_status_for_marker "$marker" "$proof_token" "$query_start" 2>&1)"; then
      printf '%s\n' "$output"
      return 0
    fi
    if ! grep -q 'no global preferences loaded record found' <<<"$output"; then
      printf '%s\n' "$output" >&2
      return 1
    fi
    if [ "$attempt" -lt "$VERIFY_ATTEMPTS" ]; then
      sleep "$VERIFY_DELAY_SECONDS"
    fi
  done
  echo "global preferences loaded record did not become visible after $VERIFY_ATTEMPTS attempts" >&2
  printf '%s\n' "$output" >&2
  return 1
}

wait_for_startup_elapsed() {
  local marker="${1:?missing marker}"
  local proof_token="${2:?missing proof token}"
  local query_start="${3:?missing query start}"
  local attempt output
  for attempt in $(seq 1 "$VERIFY_ATTEMPTS"); do
    if output="$(startup_elapsed_for_marker "$marker" "$proof_token" "$query_start" 2>&1)"; then
      printf '%s\n' "$output"
      return 0
    fi
    if ! grep -Eq 'no app.process.start record found|no app.did_finish_launching.succeeded record found' <<<"$output"; then
      printf '%s\n' "$output" >&2
      return 1
    fi
    if [ "$attempt" -lt "$VERIFY_ATTEMPTS" ]; then
      sleep "$VERIFY_DELAY_SECONDS"
    fi
  done
  echo "startup timing records did not become visible after $VERIFY_ATTEMPTS attempts" >&2
  printf '%s\n' "$output" >&2
  return 1
}

terminate_pid() {
  local pid="${1:-}"
  case "$pid" in
    ''|*[!0-9]*)
      return 0
      ;;
  esac
  if ! kill -0 "$pid" >/dev/null 2>&1; then
    return 0
  fi
  kill "$pid" >/dev/null 2>&1 || true
  for _ in $(seq 1 80); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  kill -KILL "$pid" >/dev/null 2>&1 || true
}

run_sample() {
  local mode="${1:?missing mode}"
  local index="${2:?missing index}"
  local expected_preferences_status="${3:?missing expected preference status}"
  local sample_root="$ARTIFACT_ROOT/$mode-$index"
  local state_file="$sample_root/latest-observability.env"
  local data_root="$sample_root/data"
  local trace_dir="$sample_root/traces"
  local launch_log="$sample_root/launch.log"
  local trace_name="global-preferences-startup-$mode-$index-$(date +%s)-$$"
  local started_ms finished_ms launch_command_elapsed_ms
  local pid marker proof_token query_start observed_preference_record
  local observed_preferences_status preference_load_elapsed_ms startup_elapsed_ms

  mkdir -p "$sample_root" "$data_root" "$trace_dir"
  started_ms="$(now_ms)"
  if [ "$mode" = "baseline" ]; then
    env -u AGENTSTUDIO_OBSERVABILITY_PREFERENCES_MODE \
      AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$state_file" \
      AGENTSTUDIO_DEBUG_DATA_DIR="$data_root" \
      AGENTSTUDIO_TRACE_DIR="$trace_dir" \
      AGENTSTUDIO_OBSERVABILITY_LAUNCH_LOG="$launch_log" \
      AGENTSTUDIO_TRACE_NAME="$trace_name" \
      AGENTSTUDIO_TRACE_TAGS="*" \
      AGENTSTUDIO_TRACE_BACKEND="otlp" \
      AGENTSTUDIO_TRACE_FLUSH="buffered" \
      "$PROJECT_ROOT/scripts/run-debug-observability.sh" \
      --build-path "$BUILD_PATH" --skip-build --detach
  else
    env \
      AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$state_file" \
      AGENTSTUDIO_DEBUG_DATA_DIR="$data_root" \
      AGENTSTUDIO_OBSERVABILITY_ALLOW_DATA_ROOT_ESCAPE=1 \
      AGENTSTUDIO_TRACE_DIR="$trace_dir" \
      AGENTSTUDIO_OBSERVABILITY_LAUNCH_LOG="$launch_log" \
      AGENTSTUDIO_TRACE_NAME="$trace_name" \
      "$PROJECT_ROOT/scripts/run-debug-preferences-observability.sh" \
      --build-path "$BUILD_PATH" --skip-build --detach
  fi
  finished_ms="$(now_ms)"
  launch_command_elapsed_ms=$((finished_ms - started_ms))

  pid="$(state_value "$state_file" AGENTSTUDIO_OBSERVABILITY_PID)"
  marker="$(state_value "$state_file" AGENTSTUDIO_OBSERVABILITY_MARKER)"
  proof_token="$(state_value "$state_file" AGENTSTUDIO_OBSERVABILITY_PROOF_TOKEN)"
  query_start="$(state_value "$state_file" AGENTSTUDIO_OBSERVABILITY_QUERY_START)"

  if ! wait_for_debug_observability "$state_file"; then
    terminate_pid "$pid"
    return 1
  fi

  if ! observed_preference_record="$(wait_for_preference_status "$marker" "$proof_token" "$query_start")"; then
    terminate_pid "$pid"
    return 1
  fi
  IFS=$'\t' read -r observed_preferences_status preference_load_elapsed_ms <<<"$observed_preference_record"
  if [ "$observed_preferences_status" != "$expected_preferences_status" ]; then
    echo "unexpected global preferences status for $mode sample $index: $observed_preferences_status" >&2
    echo "expected: $expected_preferences_status" >&2
    terminate_pid "$pid"
    return 1
  fi
  if ! [[ "$preference_load_elapsed_ms" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "invalid global preferences load elapsed value for $mode sample $index: $preference_load_elapsed_ms" >&2
    terminate_pid "$pid"
    return 1
  fi
  if ! startup_elapsed_ms="$(wait_for_startup_elapsed "$marker" "$proof_token" "$query_start")"; then
    terminate_pid "$pid"
    return 1
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$mode" "$index" "$marker" "$launch_command_elapsed_ms" "$preference_load_elapsed_ms" "$startup_elapsed_ms" \
    "$observed_preferences_status" "$state_file" >>"$SAMPLES_FILE"
  terminate_pid "$pid"
}

echo "global preferences startup comparison budget: enabled median delta <= ${MEDIAN_DELTA_BUDGET_MS} ms, enabled max delta <= ${MAX_DELTA_BUDGET_MS} ms"
echo "raw launch samples: $SAMPLES_FILE"

AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$ARTIFACT_ROOT/preflight.env" \
  "$PROJECT_ROOT/scripts/run-debug-observability.sh" --preflight-idle

# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/swift-build-slot.sh"
source "$PROJECT_ROOT/scripts/swift-package-sandbox.sh"
swift_build_slot_acquire build "verify-global-preferences-startup-performance"
trap swift_build_slot_release EXIT
BUILD_PATH="$SWIFT_BUILD_DIR"
echo "building debug AgentStudio once for launch comparison: $BUILD_PATH"
bash "$PROJECT_ROOT/scripts/vendor-worktree.sh" verify
swift build $(swift_package_sandbox_arguments) --build-path "$BUILD_PATH"

for index in $(seq 1 "$SAMPLE_COUNT"); do
  run_sample baseline "$index" missing
done
for index in $(seq 1 "$SAMPLE_COUNT"); do
  run_sample preferences "$index" loaded
done

/usr/bin/python3 - "$SAMPLES_FILE" "$SUMMARY_FILE" "$MEDIAN_DELTA_BUDGET_MS" "$MAX_DELTA_BUDGET_MS" <<'PY'
import csv
import json
import statistics
import sys

samples_file, summary_file, median_budget_raw, max_budget_raw = sys.argv[1:5]
median_budget = float(median_budget_raw)
max_budget = float(max_budget_raw)
startup_samples: dict[str, list[float]] = {"baseline": [], "preferences": []}
load_samples: dict[str, list[float]] = {"baseline": [], "preferences": []}
launch_command_samples: dict[str, list[float]] = {"baseline": [], "preferences": []}
rows = []
with open(samples_file, encoding="utf-8") as handle:
    reader = csv.DictReader(handle, delimiter="\t")
    for row in reader:
        startup_elapsed = float(row["startup_elapsed_ms"])
        load_elapsed = float(row["preference_load_elapsed_ms"])
        launch_command_elapsed = float(row["launch_command_elapsed_ms"])
        rows.append({
            **row,
            "startup_elapsed_ms": startup_elapsed,
            "preference_load_elapsed_ms": load_elapsed,
            "launch_command_elapsed_ms": launch_command_elapsed,
        })
        startup_samples[row["mode"]].append(startup_elapsed)
        load_samples[row["mode"]].append(load_elapsed)
        launch_command_samples[row["mode"]].append(launch_command_elapsed)

if len(startup_samples["baseline"]) < 5 or len(startup_samples["preferences"]) < 5:
    raise SystemExit("startup launch comparison requires at least five samples per mode")

baseline_median = statistics.median(startup_samples["baseline"])
preferences_median = statistics.median(startup_samples["preferences"])
baseline_maximum = max(startup_samples["baseline"])
preferences_maximum = max(startup_samples["preferences"])
median_delta = preferences_median - baseline_median
max_delta = preferences_maximum - baseline_median
summary = {
    "sample_count_per_mode": {
        "baseline": len(startup_samples["baseline"]),
        "preferences": len(startup_samples["preferences"]),
    },
    "baseline": {
        "startup_median_ms": baseline_median,
        "startup_max_ms": baseline_maximum,
        "startup_samples_ms": startup_samples["baseline"],
        "preference_load_median_ms": statistics.median(load_samples["baseline"]),
        "preference_load_max_ms": max(load_samples["baseline"]),
        "preference_load_samples_ms": load_samples["baseline"],
        "launch_command_samples_ms": launch_command_samples["baseline"],
    },
    "preferences": {
        "startup_median_ms": preferences_median,
        "startup_max_ms": preferences_maximum,
        "startup_samples_ms": startup_samples["preferences"],
        "preference_load_median_ms": statistics.median(load_samples["preferences"]),
        "preference_load_max_ms": max(load_samples["preferences"]),
        "preference_load_samples_ms": load_samples["preferences"],
        "launch_command_samples_ms": launch_command_samples["preferences"],
    },
    "deltas": {
        "startup_median_ms": median_delta,
        "startup_max_vs_baseline_median_ms": max_delta,
        "preference_load_median_ms": statistics.median(load_samples["preferences"]) - statistics.median(load_samples["baseline"]),
        "preference_load_max_vs_baseline_median_ms": max(load_samples["preferences"]) - statistics.median(load_samples["baseline"]),
    },
    "budgets": {
        "startup_median_delta_ms": median_budget,
        "startup_max_delta_ms": max_budget,
    },
}
with open(summary_file, "w", encoding="utf-8") as handle:
    json.dump(summary, handle, indent=2, sort_keys=True)
    handle.write("\n")

print(
    "global-preferences-startup baseline "
    f"count={len(startup_samples['baseline'])} median_ms={baseline_median:.3f} max_ms={baseline_maximum:.3f}"
)
print(
    "global-preferences-startup preferences "
    f"count={len(startup_samples['preferences'])} median_ms={preferences_median:.3f} max_ms={preferences_maximum:.3f}"
)
print(
    "global-preferences-startup delta "
    f"median_ms={median_delta:.3f} max_vs_baseline_median_ms={max_delta:.3f}"
)
print(f"global-preferences-startup summary: {summary_file}")

if median_delta > median_budget or max_delta > max_budget:
    raise SystemExit(
        "global preferences startup comparison exceeded budget; "
        f"raw samples: {samples_file}; summary: {summary_file}"
    )
PY
