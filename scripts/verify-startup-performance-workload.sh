#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/scripts/debug-app-identity.sh"
PAIR_COUNT="${AGENTSTUDIO_STARTUP_PERFORMANCE_PAIR_COUNT:-4}"
COMPLETION_ATTEMPTS="${AGENTSTUDIO_STARTUP_PERFORMANCE_COMPLETION_ATTEMPTS:-45}"
SETTLEMENT_WAIT_SECONDS="${AGENTSTUDIO_STARTUP_PERFORMANCE_SETTLEMENT_WAIT_SECONDS:-15}"
TERMINAL_COUNT="${AGENTSTUDIO_STARTUP_PERFORMANCE_TERMINAL_COUNT:-8}"
ARTIFACT_ROOT="${AGENTSTUDIO_STARTUP_PERFORMANCE_ARTIFACT_ROOT:-$PROJECT_ROOT/tmp/startup-performance/$(date -u +%Y%m%dT%H%M%SZ)}"
BASELINE_BUILD_PATH="${AGENTSTUDIO_STARTUP_PERFORMANCE_BASELINE_BUILD_PATH:-}"
CANDIDATE_BUILD_PATH="${AGENTSTUDIO_STARTUP_PERFORMANCE_CANDIDATE_BUILD_PATH:-}"
LOGS_QUERY_URL="${AI_TOOLS_OBSERVABILITY_LOGS_QUERY_URL:-http://127.0.0.1:9428/select/logsql/query}"
CURL_BIN="${AGENTSTUDIO_CURL_BIN:-/usr/bin/curl}"
STATE_FILE="$ARTIFACT_ROOT/latest-observability.env"
RAW_SAMPLES_FILE="$ARTIFACT_ROOT/raw-samples.tsv"
SUMMARY_FILE="$ARTIFACT_ROOT/summary.json"
FIXTURE_JSON="$ARTIFACT_ROOT/restored-workspace-fixture.json"
FIXTURE_DATA_ROOT="$ARTIFACT_ROOT/restored-data-root"
dry_run=false
owned_app_pid=""

if [ "${1:-}" = "--dry-run" ]; then
  dry_run=true
  shift
fi
if [ "$#" -ne 0 ]; then
  echo "usage: verify-startup-performance-workload.sh [--dry-run]" >&2
  exit 2
fi
if ! [[ "$PAIR_COUNT" =~ ^[0-9]+$ ]] || [ "$PAIR_COUNT" -lt 4 ]; then
  echo "AGENTSTUDIO_STARTUP_PERFORMANCE_PAIR_COUNT must be an integer >= 4" >&2
  exit 2
fi
if ! [[ "$COMPLETION_ATTEMPTS" =~ ^[0-9]+$ ]] || [ "$COMPLETION_ATTEMPTS" -lt 1 ]; then
  echo "AGENTSTUDIO_STARTUP_PERFORMANCE_COMPLETION_ATTEMPTS must be an integer >= 1" >&2
  exit 2
fi
if ! [[ "$SETTLEMENT_WAIT_SECONDS" =~ ^[0-9]+$ ]] || [ "$SETTLEMENT_WAIT_SECONDS" -lt 1 ]; then
  echo "AGENTSTUDIO_STARTUP_PERFORMANCE_SETTLEMENT_WAIT_SECONDS must be an integer >= 1" >&2
  exit 2
fi
if ! [[ "$TERMINAL_COUNT" =~ ^[0-9]+$ ]] || [ "$TERMINAL_COUNT" -lt 4 ]; then
  echo "AGENTSTUDIO_STARTUP_PERFORMANCE_TERMINAL_COUNT must be an integer >= 4" >&2
  exit 2
fi

echo "pair_count=$PAIR_COUNT"
echo "phase=cold-empty"
echo "phase=restored-cohort terminal_count=$TERMINAL_COUNT"
echo "order=A/B/A/B"
echo "trace_tags=performance,app.startup,terminal.startup"
echo "trace_flush=immediate"
echo "completion=performance.startup.usable"
echo "completion_attempts=$COMPLETION_ATTEMPTS"
echo "usable_lane=performance.startup.usable"
echo "usable_source=presented|occluded_fallback"
echo "settlement=terminal.startup.surface_create_succeeded count=$TERMINAL_COUNT"
echo "settlement_wait_seconds=$SETTLEMENT_WAIT_SECONDS"
echo "renderer_probe=program_instrument_gap"
[ "$dry_run" = false ] || exit 0

if [ -z "$BASELINE_BUILD_PATH" ] || [ -z "$CANDIDATE_BUILD_PATH" ]; then
  echo "AGENTSTUDIO_STARTUP_PERFORMANCE_BASELINE_BUILD_PATH and AGENTSTUDIO_STARTUP_PERFORMANCE_CANDIDATE_BUILD_PATH are required" >&2
  exit 2
fi

decode_assignment() {
  local source="$1"
  local key="$2"
  local raw_value
  raw_value="$(printf '%s\n' "$source" | sed -n "s/^$key=//p" | tail -1)"
  /usr/bin/python3 - "$raw_value" <<'PY'
import shlex
import sys

parts = shlex.split(sys.argv[1]) if sys.argv[1] else []
print(parts[0] if parts else "")
PY
}

state_value() {
  decode_assignment "$(<"$STATE_FILE")" "$1"
}

stop_owned_app() {
  local app_pid="${1:-}"
  case "$app_pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if kill -0 "$app_pid" >/dev/null 2>&1; then
    kill "$app_pid"
    wait "$app_pid" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  stop_owned_app "$owned_app_pid"
}
trap cleanup EXIT INT TERM

debug_identity() {
  "$PROJECT_ROOT/scripts/run-debug-observability.sh" --print-identity
}

validate_isolated_debug_root() {
  local identity="$1"
  local debug_code data_dir bundle_identifier expected_bundle_identifier
  debug_code="$(decode_assignment "$identity" AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE)"
  data_dir="$(decode_assignment "$identity" AGENTSTUDIO_OBSERVABILITY_DATA_DIR)"
  bundle_identifier="$(decode_assignment "$identity" AGENTSTUDIO_OBSERVABILITY_BUNDLE_IDENTIFIER)"
  case "$data_dir" in
    "$HOME/.agentstudio-db/$debug_code") ;;
    *) echo "refusing reset outside isolated debug roots: $data_dir" >&2; exit 1 ;;
  esac
  case "$debug_code" in
    ''|*[!a-z0-9]*) echo "refusing reset with unsafe debug code: $debug_code" >&2; exit 1 ;;
  esac
  expected_bundle_identifier="com.agentstudio.app.debug"
  if [ "$bundle_identifier" != "$expected_bundle_identifier" ]; then
    echo "refusing reset for mismatched debug bundle identifier: $bundle_identifier" >&2
    exit 1
  fi
  if ! debug_bundle_path_matches_code "$debug_code" \
    "$(decode_assignment "$identity" AGENTSTUDIO_OBSERVABILITY_APP)" \
    "$(decode_assignment "$identity" AGENTSTUDIO_OBSERVABILITY_EXECUTABLE)"; then
    echo "refusing reset for mismatched debug code or executable path" >&2
    exit 1
  fi
  printf '%s\n' "$data_dir"
}

write_restored_fixture_json() {
  /usr/bin/python3 - "$FIXTURE_JSON" "$PROJECT_ROOT" "$TERMINAL_COUNT" <<'PY'
import json
import secrets
import sys
import time
from pathlib import Path

destination, project_root, terminal_count_raw = sys.argv[1:]
terminal_count = int(terminal_count_raw)

def uuid_v7() -> str:
    timestamp = int(time.time() * 1000)
    random_bits = secrets.randbits(74)
    value = (timestamp << 80) | (0x7 << 76) | ((random_bits >> 62) << 64)
    value |= (0x2 << 62) | (random_bits & ((1 << 62) - 1))
    hexadecimal = f"{value:032x}"
    return f"{hexadecimal[:8]}-{hexadecimal[8:12]}-{hexadecimal[12:16]}-{hexadecimal[16:20]}-{hexadecimal[20:]}"

repository_id = uuid_v7()
worktree_id = uuid_v7()
pane_ids = [uuid_v7() for _ in range(terminal_count)]
tab_id = uuid_v7()
arrangement_id = uuid_v7()
fixture = {
    "schemaVersion": 1,
    "id": uuid_v7(),
    "name": "Startup Restored Cohort",
    "repos": [{"id": repository_id, "name": "agent-studio", "repoPath": Path(project_root).as_uri(), "createdAt": 0}],
    "worktrees": [{"id": worktree_id, "repoId": repository_id, "name": "startup-fixture", "path": Path(project_root).as_uri(), "isMainWorktree": True}],
    "unavailableRepoIds": [],
    "panes": [
        {
            "id": pane_id,
            "content": {"version": 3, "type": "terminal", "state": {"provider": "zmx", "lifetime": "persistent", "zmxSessionID": uuid_v7()}},
            "metadata": {
                "paneId": pane_id,
                "contentType": {"terminal": {}},
                "launchDirectory": Path(project_root).as_uri(),
                "executionBackend": {"local": {}},
                "createdAt": 0,
                "title": f"restored-terminal-{index + 1}",
                "facets": {"repoId": repository_id, "worktreeId": worktree_id, "cwd": None, "tags": []},
                "checkoutRef": None,
                "note": None,
            },
            "residency": {"active": {}},
            "kind": {"layout": {"drawer": {"drawerId": uuid_v7(), "parentPaneId": pane_id, "paneIds": [], "isExpanded": False}}},
        }
        for index, pane_id in enumerate(pane_ids)
    ],
    "tabs": [{
        "id": tab_id,
        "name": "Restored Cohort",
        "panes": pane_ids,
        "arrangements": [{
            "id": arrangement_id,
            "name": "Default",
            "isDefault": True,
            "layout": {
                "panes": [{"paneId": pane_id, "ratio": 1.0 / terminal_count} for pane_id in pane_ids],
                "dividerIds": [uuid_v7() for _ in range(terminal_count - 1)],
            },
            "minimizedPaneIds": [],
            "activePaneId": pane_ids[0],
            "drawerViews": [],
        }],
        "activeArrangementId": arrangement_id,
    }],
    "activeTabId": tab_id,
    "sidebarWidth": 250,
    "windowFrame": None,
    "watchedPaths": [],
    "createdAt": 0,
    "updatedAt": 0,
}
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(fixture, handle)
PY
}

materialize_restored_fixture() {
  write_restored_fixture_json
  mkdir -p "$FIXTURE_DATA_ROOT"
  env \
    AGENTSTUDIO_PERF_FIXTURE_JSON="$FIXTURE_JSON" \
    AGENTSTUDIO_PERF_FIXTURE_DATA_ROOT="$FIXTURE_DATA_ROOT" \
    AGENTSTUDIO_PERF_FIXTURE_EXPECTED_REPOS=1 \
    AGENTSTUDIO_PERF_FIXTURE_EXPECTED_WORKTREES=1 \
    AGENTSTUDIO_PERF_FIXTURE_EXPECTED_PANES="$TERMINAL_COUNT" \
    AGENTSTUDIO_PERF_FIXTURE_EXPECTED_TABS=1 \
    mise run test:swift -- --filter GitRefreshPerformanceWorkloadScriptTests.workloadFixtureMaterializesThroughStrictSQLite \
    >"$ARTIFACT_ROOT/fixture-materialization.log" 2>&1
}

seed_phase_root() {
  local phase="$1"
  local data_dir="$2"
  /bin/rm -rf -- "$data_dir"
  if [ "$phase" = "restored-cohort" ]; then
    /usr/bin/ditto "$FIXTURE_DATA_ROOT" "$data_dir"
  fi
}

logsql_exact_filter() {
  local field="$1"
  local value="$2"
  local escaped="${value//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  printf '%s:="%s"' "$field" "$escaped"
}

query_logs() {
  local query="$1"
  local query_start="$2"
  "$CURL_BIN" --fail --silent --show-error --max-time 5 --get \
    --data-urlencode "query=$query" \
    --data-urlencode "start=$query_start" \
    --data-urlencode "end=$(date -u -v+5M +%Y-%m-%dT%H:%M:%SZ)" \
    "$LOGS_QUERY_URL"
}

sample_measurements() {
  local marker="$1"
  local query_start="$2"
  local expected_surface_count="$3"
  local marker_filter usable_filter surface_filter usable_response surface_response
  marker_filter="$(logsql_exact_filter agent.proof.marker "$marker")"
  usable_filter="$(logsql_exact_filter _msg performance.startup.usable)"
  surface_filter="$(logsql_exact_filter _msg terminal.startup.surface_create_succeeded)"
  usable_response="$(query_logs "{service.name=\"AgentStudio\",dev.runtime.flavor=\"debug\"} $marker_filter $usable_filter | fields agentstudio.performance.elapsed_ms,agentstudio.performance.startup.source | limit 5" "$query_start")"
  surface_response="$(query_logs "{service.name=\"AgentStudio\",dev.runtime.flavor=\"debug\"} $marker_filter $surface_filter | fields _time | limit 100" "$query_start")"
  /usr/bin/python3 - "$usable_response" "$surface_response" "$expected_surface_count" "$query_start" <<'PY'
from datetime import datetime
import json
import sys


def parse_victoria_timestamp(value):
    timestamp_without_utc_suffix = value.removesuffix("Z")
    if "." in timestamp_without_utc_suffix:
        whole_seconds, fractional_seconds = timestamp_without_utc_suffix.rsplit(".", 1)
        timestamp_without_utc_suffix = f"{whole_seconds}.{fractional_seconds.ljust(6, '0')}"
    return datetime.fromisoformat(f"{timestamp_without_utc_suffix}+00:00")


usable_raw, surfaces_raw, expected_raw, launch_time_raw = sys.argv[1:]
usable_values = []
usable_sources = []
for line in usable_raw.splitlines():
    try:
        value = json.loads(line).get("agentstudio.performance.elapsed_ms")
        if value is not None:
            usable_values.append(float(value))
            usable_sources.append(json.loads(line).get("agentstudio.performance.startup.source"))
    except (json.JSONDecodeError, TypeError, ValueError):
        pass
surface_times = []
for line in surfaces_raw.splitlines():
    try:
        value = json.loads(line).get("_time")
        if isinstance(value, str):
            surface_times.append(parse_victoria_timestamp(value))
    except (json.JSONDecodeError, ValueError):
        pass
expected = int(expected_raw)
if len(usable_values) != 1 or len(surface_times) != expected or usable_sources[0] not in {"presented", "occluded_fallback"}:
    raise SystemExit(1)
settled_ms = ""
if expected:
    launch_time = datetime.fromisoformat(launch_time_raw.replace("Z", "+00:00"))
    settled_ms = f"{(max(surface_times) - launch_time).total_seconds() * 1000:.3f}"
print(f"{usable_values[0]:.3f}\t{settled_ms}\t{len(surface_times)}\t{usable_sources[0]}")
PY
}

run_sample() {
  local phase="$1"
  local revision="$2"
  local pair_index="$3"
  local build_path="$4"
  local identity data_dir trace_name app_pid marker query_start expected_surface_count wait_attempts measurements
  identity="$(debug_identity)"
  data_dir="$(validate_isolated_debug_root "$identity")"
  "$PROJECT_ROOT/scripts/run-debug-observability.sh" --preflight-idle
  seed_phase_root "$phase" "$data_dir"
  trace_name="startup-${phase}-${revision}-$(/usr/bin/uuidgen | tr '[:upper:]' '[:lower:]')"
  env \
    AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$STATE_FILE" \
    AGENTSTUDIO_TRACE_NAME="$trace_name" \
    AGENTSTUDIO_TRACE_TAGS=performance,app.startup,terminal.startup \
    AGENTSTUDIO_TRACE_FLUSH=immediate \
    "$PROJECT_ROOT/scripts/run-debug-observability.sh" --build-path "$build_path" --skip-build --detach
  app_pid="$(state_value AGENTSTUDIO_OBSERVABILITY_PID)"
  owned_app_pid="$app_pid"
  marker="$(state_value AGENTSTUDIO_OBSERVABILITY_MARKER)"
  query_start="$(state_value AGENTSTUDIO_OBSERVABILITY_QUERY_START)"
  expected_surface_count=0
  [ "$phase" = "restored-cohort" ] && expected_surface_count="$TERMINAL_COUNT"
  wait_attempts="$COMPLETION_ATTEMPTS"
  [ "$phase" = "restored-cohort" ] && wait_attempts="$SETTLEMENT_WAIT_SECONDS"
  measurements=""
  for _ in $(seq 1 "$wait_attempts"); do
    if measurements="$(sample_measurements "$marker" "$query_start" "$expected_surface_count" 2>/dev/null)"; then
      break
    fi
    /bin/sleep 1
  done
  if [ -z "$measurements" ]; then
    stop_owned_app "$app_pid"
    owned_app_pid=""
    for _ in $(seq 1 "$COMPLETION_ATTEMPTS"); do
      if measurements="$(sample_measurements "$marker" "$query_start" "$expected_surface_count" 2>/dev/null)"; then
        break
      fi
      /bin/sleep 1
    done
  fi
  if [ -z "$measurements" ]; then
    echo "bounded completion wait expired for $phase $revision pair $pair_index" >&2
    exit 1
  fi
  if [ -n "${measurements#*$'\t'}" ] && [ "$phase" = "restored-cohort" ]; then
    settled_ms="$(printf '%s\n' "$measurements" | cut -f2)"
    if ! /usr/bin/python3 - "$settled_ms" "$SETTLEMENT_WAIT_SECONDS" <<'PY'
import sys

raise SystemExit(0 if float(sys.argv[1]) <= float(sys.argv[2]) * 1000 else 1)
PY
    then
      echo "settlement exceeded ${SETTLEMENT_WAIT_SECONDS}s for $phase $revision pair $pair_index: ${settled_ms}ms" >&2
      exit 1
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$phase" "$revision" "$pair_index" "$marker" "$measurements" >>"$RAW_SAMPLES_FILE"
  echo "completed phase=$phase revision=$revision pair=$pair_index marker=$marker measurements=$measurements"
  stop_owned_app "$app_pid"
  owned_app_pid=""
}

summarize() {
  /usr/bin/python3 - "$RAW_SAMPLES_FILE" "$SUMMARY_FILE" <<'PY'
import csv
import json
import statistics
import sys

samples_path, summary_path = sys.argv[1:]
rows = list(csv.DictReader(open(samples_path, encoding="utf-8"), delimiter="\t"))
summary = {}
for phase in ("cold-empty", "restored-cohort"):
    summary[phase] = {}
    for revision in ("A", "B"):
        selected = [row for row in rows if row["phase"] == phase and row["revision"] == revision]
        usable = [float(row["launch_to_usable_ms"]) for row in selected]
        settled = [float(row["launch_to_settled_ms"]) for row in selected if row["launch_to_settled_ms"]]
        source_breakdown = {
            source: sum(row["usable_source"] == source for row in selected)
            for source in ("presented", "occluded_fallback")
        }
        summary[phase][revision] = {
            "usable_samples_ms": usable,
            "usable_median_ms": statistics.median(usable),
            "settled_samples_ms": settled,
            "settled_median_ms": statistics.median(settled) if settled else None,
            "source_breakdown": source_breakdown,
        }
    baseline = summary[phase]["A"]["usable_median_ms"]
    candidate = summary[phase]["B"]["usable_median_ms"]
    summary[phase]["usable_delta_ms"] = candidate - baseline
    summary[phase]["usable_improvement_percent"] = (baseline - candidate) / baseline * 100
summary["gates"] = {
    "restored_usable_improved": summary["restored-cohort"]["usable_delta_ms"] < 0,
    "cold_empty_within_noise": abs(summary["cold-empty"]["usable_delta_ms"]) <= 50,
}
with open(summary_path, "w", encoding="utf-8") as handle:
    json.dump(summary, handle, indent=2)
print(json.dumps(summary, indent=2))
if not all(summary["gates"].values()):
    raise SystemExit(1)
PY
}

mkdir -p "$ARTIFACT_ROOT"
printf 'phase\trevision\tpair\tmarker\tlaunch_to_usable_ms\tlaunch_to_settled_ms\tsurface_count\tusable_source\n' >"$RAW_SAMPLES_FILE"
materialize_restored_fixture
for phase in cold-empty restored-cohort; do
  for pair_index in $(seq 1 "$PAIR_COUNT"); do
    run_sample "$phase" A "$pair_index" "$BASELINE_BUILD_PATH"
    run_sample "$phase" B "$pair_index" "$CANDIDATE_BUILD_PATH"
  done
done

summarize
echo "raw_samples=$RAW_SAMPLES_FILE"
echo "summary=$SUMMARY_FILE"
