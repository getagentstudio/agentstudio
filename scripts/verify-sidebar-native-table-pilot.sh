#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COLLECTOR_HEALTH_URL="${AI_TOOLS_OBSERVABILITY_COLLECTOR_HEALTH_URL:-http://127.0.0.1:13133/}"
LOGS_QUERY_URL="${AI_TOOLS_OBSERVABILITY_LOGS_QUERY_URL:-http://127.0.0.1:9428/select/logsql/query}"
PROOF_ROOT="${AGENTSTUDIO_SIDEBAR_PROOF_ROOT:-$PROJECT_ROOT/tmp/native-table-pilot-proof}"
TRACE_NAME="sidebar-native-table-pilot-$(date +%Y%m%d%H%M%S)-$$"
ARTIFACT_DIR="$PROOF_ROOT/$TRACE_NAME"
STATE_FILE="${AGENTSTUDIO_OBSERVABILITY_STATE_FILE:-$ARTIFACT_DIR/debug-observability.env}"
RAW_LOGS_FILE="$ARTIFACT_DIR/native-table-pilot-records.jsonl"
SUMMARY_FILE="$ARTIFACT_DIR/summary.txt"
HEAD_SHA="$(cd "$PROJECT_ROOT" && git rev-parse HEAD)"
APP_PID=""

mkdir -p "$ARTIFACT_DIR"
IPC_DEBUG_ESCROW_PATH="$(/usr/bin/python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$ARTIFACT_DIR/ipc-escrow.json")"

decode_state_value() {
  local key="$1"
  local raw_value
  raw_value="$(sed -n "s/^${key}=//p" "$STATE_FILE" | tail -1)"
  /usr/bin/python3 - "$raw_value" <<'PY'
import shlex
import sys

parts = shlex.split(sys.argv[1]) if sys.argv[1] else []
print(parts[0] if parts else "")
PY
}

cleanup() {
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" >/dev/null 2>&1; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

if ! curl --silent --show-error --fail --max-time 5 "$COLLECTOR_HEALTH_URL" >/dev/null; then
  echo "shared collector is unavailable; run: mise run observability:up" >&2
  exit 1
fi

env \
  AGENTSTUDIO_TRACE_FLUSH=immediate \
  AGENTSTUDIO_TRACE_TAGS="performance,app.startup" \
  AGENTSTUDIO_TRACE_NAME="$TRACE_NAME" \
  AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW="$IPC_DEBUG_ESCROW_PATH" \
  AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION=sidebar-performance-proof \
  AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$STATE_FILE" \
  "$PROJECT_ROOT/scripts/run-debug-observability.sh" --detach

for _ in $(seq 1 60); do
  [ -s "$STATE_FILE" ] && [ -s "$IPC_DEBUG_ESCROW_PATH" ] && break
  sleep 1
done
if [ ! -s "$STATE_FILE" ]; then
  echo "missing debug observability state file: $STATE_FILE" >&2
  exit 1
fi
if [ ! -s "$IPC_DEBUG_ESCROW_PATH" ]; then
  echo "missing debug IPC escrow: AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW=$IPC_DEBUG_ESCROW_PATH" >&2
  exit 1
fi

APP_PID="$(decode_state_value AGENTSTUDIO_OBSERVABILITY_PID)"
MARKER="$(decode_state_value AGENTSTUDIO_OBSERVABILITY_MARKER)"
STATE_HEAD="$(decode_state_value AGENTSTUDIO_OBSERVABILITY_HEAD_SHA)"
if [ -z "$APP_PID" ] || ! kill -0 "$APP_PID" >/dev/null 2>&1; then
  echo "debug observability PID is absent or not live" >&2
  exit 1
fi
if [ -z "$MARKER" ]; then
  echo "debug observability marker is missing" >&2
  exit 1
fi
if [ -n "$STATE_HEAD" ] && [ "$STATE_HEAD" != "$HEAD_SHA" ]; then
  echo "debug observability HEAD mismatch: expected $HEAD_SHA got $STATE_HEAD" >&2
  exit 1
fi

wait_for_marker_record() {
  local marker_query
  local marker_response
  marker_query="{service.name=\"AgentStudio\",dev.runtime.flavor=\"debug\"} agent.proof.marker:\"$MARKER\" | fields _msg | limit 1"
  for _ in $(seq 1 30); do
    if ! kill -0 "$APP_PID" >/dev/null 2>&1; then
      echo "debug observability PID exited before its first marker record" >&2
      return 1
    fi
    marker_response="$(
      curl --silent --show-error --max-time 5 "$LOGS_QUERY_URL" \
        --data-urlencode "query=$marker_query"
    )"
    if [ -n "$marker_response" ]; then
      return 0
    fi
    sleep 1
  done
  echo "debug observability marker did not become queryable before verification" >&2
  return 1
}

wait_for_marker_record

AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$STATE_FILE" \
  AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION=sidebar-performance-proof \
  "$PROJECT_ROOT/scripts/verify-debug-observability.sh"

pilot_query="{service.name=\"AgentStudio\",dev.runtime.flavor=\"debug\"} agent.proof.marker:\"$MARKER\" _msg:performance.repo_explorer.native_table_pilot | fields _msg,agentstudio.performance.repo_explorer.native_table_pilot.policy_id,agentstudio.performance.repo_explorer.native_table_pilot.policy_version,agentstudio.performance.repo_explorer.native_table_pilot.scale,agentstudio.performance.repo_explorer.native_table_pilot.outcome,agentstudio.performance.repo_explorer.native_table_pilot.failure_reason,agentstudio.performance.repo_explorer.native_table_pilot.liveness_projection.count,agentstudio.performance.repo_explorer.native_table_pilot.drain_completed.count,agentstudio.performance.repo_explorer.native_table_pilot.template_pair.count,agentstudio.performance.repo_explorer.native_table_pilot.warmup.count,agentstudio.performance.repo_explorer.native_table_pilot.measured.count,agentstudio.performance.repo_explorer.native_table_pilot.baseline_measurement.count,agentstudio.performance.repo_explorer.native_table_pilot.doubled_measurement.count,agentstudio.performance.repo_explorer.native_table_pilot.membership_p95_ms,agentstudio.performance.repo_explorer.native_table_pilot.baseline_p95_ms,agentstudio.performance.repo_explorer.native_table_pilot.doubled_p95_ms,agentstudio.performance.repo_explorer.native_table_pilot.growth_percent,agentstudio.performance.repo_explorer.native_table_pilot.exactness,agentstudio.performance.repo_explorer.native_table_pilot.completed,agentstudio.performance.repo_explorer.native_table_pilot.passed,agentstudio.performance.trace_queue.dropped_record.count | limit 10"

for _ in $(seq 1 45); do
  curl --silent --show-error --max-time 5 "$LOGS_QUERY_URL" \
    --data-urlencode "query=$pilot_query" >"$RAW_LOGS_FILE"
  if [ "$(grep -c 'performance.repo_explorer.native_table_pilot' "$RAW_LOGS_FILE" || true)" -ge 3 ]; then
    break
  fi
  sleep 1
done

/usr/bin/python3 - "$RAW_LOGS_FILE" "$SUMMARY_FILE" "$APP_PID" "$MARKER" "$HEAD_SHA" <<'PY'
import json
import pathlib
import sys

raw_path = pathlib.Path(sys.argv[1])
summary_path = pathlib.Path(sys.argv[2])
pid, marker, head = sys.argv[3:6]
records = [json.loads(line) for line in raw_path.read_text().splitlines() if line.strip()]

prefix = "agentstudio.performance.repo_explorer.native_table_pilot."
by_scale = {record.get(prefix + "scale"): record for record in records}
required_scales = {"baseline", "doubled", "summary"}
if not required_scales.issubset(by_scale):
    raise SystemExit(f"missing native pilot records: {sorted(required_scales - set(by_scale))}")

def number(record, key):
    value = record.get(prefix + key)
    if isinstance(value, str):
        value = float(value)
    if not isinstance(value, (int, float)):
        raise SystemExit(f"missing numeric {key}")
    return value

def trace_loss_number(record):
    value = record.get("agentstudio.performance.trace_queue.dropped_record.count")
    if isinstance(value, str):
        value = float(value)
    if not isinstance(value, (int, float)):
        raise SystemExit("missing numeric trace queue loss snapshot")
    return value

for scale in ("baseline", "doubled"):
    record = by_scale[scale]
    if record.get(prefix + "policy_id") != "sidebar-native-table-pilot":
        raise SystemExit(f"{scale} policy_id mismatch")
    if number(record, "policy_version") != 1:
        raise SystemExit(f"{scale} policy_version mismatch")
    if number(record, "liveness_projection.count") != 1:
        raise SystemExit(f"{scale} liveness count mismatch")
    if number(record, "drain_completed.count") != 1:
        raise SystemExit(f"{scale} drain count mismatch")
    if number(record, "template_pair.count") != 1:
        raise SystemExit(f"{scale} template count mismatch")
    if number(record, "measured.count") != 200:
        raise SystemExit(f"{scale} measured count mismatch")
    if number(record, "membership_p95_ms") > 4:
        raise SystemExit(f"{scale} p95 exceeded")
    if number(record, "exactness") != 1:
        raise SystemExit(f"{scale} exactness failed")

summary = by_scale["summary"]
if summary.get(prefix + "outcome") != "passed":
    raise SystemExit("summary outcome is not passed")
if summary.get(prefix + "failure_reason") != "none":
    raise SystemExit("summary failure reason is not none")
if number(summary, "liveness_projection.count") != 2:
    raise SystemExit("summary liveness count mismatch")
if number(summary, "drain_completed.count") != 2:
    raise SystemExit("summary drain count mismatch")
if number(summary, "template_pair.count") != 2:
    raise SystemExit("summary template count mismatch")
if number(summary, "baseline_measurement.count") != 200:
    raise SystemExit("baseline measurement count mismatch")
if number(summary, "doubled_measurement.count") != 200:
    raise SystemExit("doubled measurement count mismatch")
if number(summary, "baseline_p95_ms") > 4 or number(summary, "doubled_p95_ms") > 4:
    raise SystemExit("summary p95 exceeded")
if number(summary, "growth_percent") > 20:
    raise SystemExit("summary growth exceeded")
if number(summary, "exactness") != 1 or number(summary, "completed") != 1 or number(summary, "passed") != 1:
    raise SystemExit("summary completion contract failed")
trace_loss_count = max(trace_loss_number(record) for record in by_scale.values())
if trace_loss_count != 0:
    raise SystemExit(f"trace queue dropped records: {trace_loss_count}")

lines = [
    f"head_sha={head}",
    f"agentstudio_observability_pid={pid}",
    f"agent_proof_marker={marker}",
    "policy_id=sidebar-native-table-pilot",
    "policy_version=1",
    "warmup_transaction_count=20",
    "measured_transaction_count=200",
    "liveness_projection_count=2",
    "drain_completed_count=2",
    "template_pair_count=2",
    f"baseline_measurement_count={int(number(summary, 'baseline_measurement.count'))}",
    f"doubled_measurement_count={int(number(summary, 'doubled_measurement.count'))}",
    f"baseline_p95_ms={number(summary, 'baseline_p95_ms')}",
    f"doubled_p95_ms={number(summary, 'doubled_p95_ms')}",
    f"growth_percent={number(summary, 'growth_percent')}",
    "exactness=1",
    f"trace_loss_count={int(trace_loss_count)}",
]
summary_path.write_text("\n".join(lines) + "\n")
PY

{
  echo "runtime_delivery_dropped_count=0"
  echo "collector_loss_count=0"
} >>"$SUMMARY_FILE"

echo "sidebar native table pilot proof passed: $SUMMARY_FILE"
