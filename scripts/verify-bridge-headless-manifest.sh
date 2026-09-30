#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROOF_ROOT="${AGENTSTUDIO_BRIDGE_HEADLESS_PROOF_DIR:-$PROJECT_ROOT/tmp/bridge-headless-manifest-proof}"
TEST_FILTER="${AGENTSTUDIO_BRIDGE_HEADLESS_TEST_FILTER:-WebKitSerializedTests.BridgeWorktreeFileSurfaceCurrentWorktreeProofTests}"
SWIFT_TIMEOUT="${SWIFT_TEST_TIMEOUT_SECONDS:-240}"
METRICS_QUERY_URL="${AI_TOOLS_OBSERVABILITY_METRICS_QUERY_URL:-http://127.0.0.1:8428/api/v1/query}"
COLLECTOR_HEALTH_URL="${AI_TOOLS_OBSERVABILITY_COLLECTOR_HEALTH_URL:-http://127.0.0.1:13133/}"
TRACE_NAME="${AGENTSTUDIO_BRIDGE_HEADLESS_TRACE_NAME:-bridge-headless-manifest-$(date +%s)-$$}"
TRACE_DIR="${AGENTSTUDIO_BRIDGE_HEADLESS_TRACE_DIR:-$PROOF_ROOT/traces}"
VERIFY_ATTEMPTS="${AGENTSTUDIO_BRIDGE_HEADLESS_VICTORIA_ATTEMPTS:-60}"
VERIFY_RETRY_DELAY_SECONDS="${AGENTSTUDIO_BRIDGE_HEADLESS_VICTORIA_RETRY_DELAY_SECONDS:-2}"
VALIDATE_ONLY=0

if [ "${1:-}" = "--validate-only" ]; then
  VALIDATE_ONLY=1
  shift
fi

if [ "$#" -ne 0 ]; then
  echo "usage: $0 [--validate-only]" >&2
  exit 2
fi

artifact_path() {
  if [ -f "$PROOF_ROOT/current-worktree-manifest-proof.json" ]; then
    printf '%s/current-worktree-manifest-proof.json\n' "$PROOF_ROOT"
    return 0
  fi
  find "$PROOF_ROOT" -type f -name current-worktree-manifest-proof.json -print -quit
}

validate_artifact() {
  local artifact="${1:?missing artifact path}"
  /usr/bin/python3 - "$artifact" <<'PY'
import json
import sys
from pathlib import Path

artifact = Path(sys.argv[1])
payload = json.loads(artifact.read_text())

def require_int(name: str) -> int:
    value = payload.get(name)
    if not isinstance(value, int):
        raise SystemExit(f"{name} missing or not an integer")
    return value

def require_dict(container: dict, name: str) -> dict:
    value = container.get(name)
    if not isinstance(value, dict):
        raise SystemExit(f"{name} missing")
    return value

def require_number(container: dict, name: str) -> float:
    value = container.get(name)
    if not isinstance(value, (int, float)):
        raise SystemExit(f"{name} missing")
    return float(value)

def require_empty_list(name: str) -> None:
    value = payload.get(name)
    if value != []:
        raise SystemExit(f"{name} must be an empty list")

expected_files = require_int("expectedMetadataFileTotal")
emitted_files = require_int("emittedMetadataFileTotal")
expected_rows = require_int("expectedMetadataRowTotal")
emitted_rows = require_int("emittedMetadataRowTotal")
remaining_rows = require_int("remainingMetadataRowTotal")
first_window_rows = require_int("firstWindowRowCount")
unique_paths = require_int("uniquePathCount")

if expected_files <= 0:
    raise SystemExit("expectedMetadataFileTotal must be positive")
if emitted_files != expected_files:
    raise SystemExit("emittedMetadataFileTotal must equal expectedMetadataFileTotal")
if emitted_rows != expected_rows:
    raise SystemExit("emittedMetadataRowTotal must equal expectedMetadataRowTotal")
if remaining_rows != 0:
    raise SystemExit("remainingMetadataRowTotal must be zero")
if unique_paths != emitted_rows:
    raise SystemExit("uniquePathCount must match emittedMetadataRowTotal")
if first_window_rows <= 0:
    raise SystemExit("firstWindowRowCount must be positive")

require_empty_list("missingExpectedFilePaths")
require_empty_list("unexpectedPublishedFilePaths")

metadata_interest = payload.get("metadataInterestRequestToDeliveredFrame")
if not isinstance(metadata_interest, dict):
    raise SystemExit("metadataInterestRequestToDeliveredFrame missing")
if metadata_interest.get("p95Milliseconds") is None:
    raise SystemExit("metadataInterestRequestToDeliveredFrame.p95Milliseconds missing")
if metadata_interest.get("p99Milliseconds") is None:
    raise SystemExit("metadataInterestRequestToDeliveredFrame.p99Milliseconds missing")

no_starvation = payload.get("noStarvationProgress")
if not isinstance(no_starvation, dict) or no_starvation.get("completed") is not True:
    raise SystemExit("noStarvationProgress.completed must be true")

queue_wait = payload.get("queueWaitByLane")
if not isinstance(queue_wait, dict):
    raise SystemExit("queueWaitByLane missing")
for lane in ("foreground", "visible"):
    lane_wait = queue_wait.get(lane)
    if not isinstance(lane_wait, dict):
        raise SystemExit(f"queueWaitByLane.{lane} missing")
    if lane_wait.get("measurementName") != "metadata_scheduler_queue_wait_by_lane":
        raise SystemExit(f"queueWaitByLane.{lane}.measurementName must be scheduler queue wait")
    if lane_wait.get("p95Milliseconds") is None:
        raise SystemExit(f"queueWaitByLane.{lane}.p95Milliseconds missing")
    if lane_wait.get("p99Milliseconds") is None:
        raise SystemExit(f"queueWaitByLane.{lane}.p99Milliseconds missing")

gated_benchmark = require_dict(payload, "gatedBenchmark")
if gated_benchmark.get("completed") is not True:
    raise SystemExit("gatedBenchmark.completed must be true")

gated_metadata_interest = require_dict(
    gated_benchmark,
    "metadataInterestRequestToDeliveredFrame",
)
if gated_metadata_interest.get("measurementName") != "metadata_interest_request_to_delivered_intake_frame":
    raise SystemExit(
        "gatedBenchmark.metadataInterestRequestToDeliveredFrame.measurementName invalid"
    )
if require_number(gated_metadata_interest, "sampleCount") < 100:
    raise SystemExit("metadataInterestRequestToDeliveredFrame.sampleCount must be at least 100")
sample_count_by_lane = require_dict(gated_metadata_interest, "sampleCountByLane")
for lane in ("foreground", "visible"):
    if require_number(sample_count_by_lane, lane) < 50:
        raise SystemExit(
            f"metadataInterestRequestToDeliveredFrame.sampleCountByLane.{lane} must be at least 50"
        )
if gated_metadata_interest.get("p95Milliseconds") is None:
    raise SystemExit("gatedBenchmark.metadataInterestRequestToDeliveredFrame.p95Milliseconds missing")
if gated_metadata_interest.get("p99Milliseconds") is None:
    raise SystemExit("gatedBenchmark.metadataInterestRequestToDeliveredFrame.p99Milliseconds missing")
if require_number(gated_metadata_interest, "p95Milliseconds") >= 32.0:
    raise SystemExit("metadataInterestRequestToDeliveredFrame p95 must be below 32ms")
if require_number(gated_metadata_interest, "p99Milliseconds") >= 64.0:
    raise SystemExit("metadataInterestRequestToDeliveredFrame p99 must be below 64ms")

gated_queue_wait = require_dict(gated_benchmark, "queueWaitByLane")
queue_wait_thresholds = {
    "foreground": (16.0, 32.0),
    "visible": (32.0, 64.0),
}
for lane, (p95_limit, p99_limit) in queue_wait_thresholds.items():
    lane_wait = require_dict(gated_queue_wait, lane)
    if lane_wait.get("measurementName") != "metadata_scheduler_queue_wait_by_lane":
        raise SystemExit(f"queueWaitByLane.{lane}.measurementName must be scheduler queue wait")
    if require_number(lane_wait, "sampleCount") < 50:
        raise SystemExit("queueWaitByLane.{lane}.sampleCount must be at least 50")
    p95 = require_number(lane_wait, "p95Milliseconds")
    p99 = require_number(lane_wait, "p99Milliseconds")
    if p95 >= p95_limit:
        raise SystemExit(f"{lane} queue wait p95 must be below {int(p95_limit)}ms")
    if p99 >= p99_limit:
        raise SystemExit(f"{lane} queue wait p99 must be below {int(p99_limit)}ms")

gated_content_fetch = require_dict(gated_benchmark, "contentFetch")
if gated_content_fetch.get("measurementName") != "content_fetch":
    raise SystemExit("gatedBenchmark.contentFetch.measurementName must be content_fetch")
if require_number(gated_content_fetch, "sampleCount") < 20:
    raise SystemExit("contentFetch.sampleCount must be at least 20")
if gated_content_fetch.get("p95Milliseconds") is None:
    raise SystemExit("gatedBenchmark.contentFetch.p95Milliseconds missing")
if gated_content_fetch.get("p99Milliseconds") is None:
    raise SystemExit("gatedBenchmark.contentFetch.p99Milliseconds missing")

print(f"artifact={artifact}")
print(f"expectedMetadataFileTotal={expected_files}")
print(f"emittedMetadataFileTotal={emitted_files}")
print(f"expectedMetadataRowTotal={expected_rows}")
print(f"emittedMetadataRowTotal={emitted_rows}")
PY
}

metric_query_value() {
  local promql="${1:?missing PromQL query}"
  local response
  response="$(
    curl \
      --fail \
      --silent \
      --show-error \
      --max-time 5 \
      --get \
      --data-urlencode "query=$promql" \
      "$METRICS_QUERY_URL" 2>/dev/null || true
  )"
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
        value = float(item["value"][1])
        if math.isfinite(value):
            total += value
except Exception:
    pass

print(int(total) if total.is_integer() else total)
' <<<"$response"
}

wait_for_metric_value() {
  local description="${1:?missing description}"
  local promql="${2:?missing PromQL query}"
  local value="0"
  local attempt=1
  while [ "$attempt" -le "$VERIFY_ATTEMPTS" ]; do
    value="$(metric_query_value "$promql")"
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

bridge_metric_label_selector() {
  local event_name="${1:?missing event name}"
  local phase="${2:?missing phase}"
  local priority="${3:?missing priority}"
  local slice="${4:?missing slice}"
  local lane="${5:-}"
  local selector
  selector="$(printf 'service.name="AgentStudio",dev.runtime.flavor="debug",agent.proof.marker="%s",event="%s",phase="%s",plane="data",priority="%s",slice="%s"' \
    "$TRACE_NAME" "$event_name" "$phase" "$priority" "$slice")"
  if [ -n "$lane" ]; then
    selector="$selector,lane=\"$lane\""
  fi
  printf '%s' "$selector"
}

require_victoria_metric_percentiles() {
  local event_name="${1:?missing event name}"
  local phase="${2:?missing phase}"
  local priority="${3:?missing priority}"
  local slice="${4:?missing slice}"
  local lane="${5:-}"
  local selector count p95 p99
  selector="$(bridge_metric_label_selector "$event_name" "$phase" "$priority" "$slice" "$lane")"
  count="$(wait_for_metric_value \
    "Bridge headless Victoria metric missing count for $event_name lane=${lane:-none}" \
    "sum(agentstudio_performance_events_total{$selector})")"
  p95="$(wait_for_metric_value \
    "Bridge headless Victoria metric missing p95 for $event_name lane=${lane:-none}" \
    "histogram_quantile(0.95, sum by (le) (agentstudio_performance_event_elapsed_ms_bucket{$selector}))")"
  p99="$(wait_for_metric_value \
    "Bridge headless Victoria metric missing p99 for $event_name lane=${lane:-none}" \
    "histogram_quantile(0.99, sum by (le) (agentstudio_performance_event_elapsed_ms_bucket{$selector}))")"
  echo "Bridge headless Victoria metric $event_name lane=${lane:-none} count=$count p95=$p95 p99=$p99"
}

require_victoria_metrics() {
  require_victoria_metric_percentiles \
    "performance.bridge.native.metadata_open_to_first_window" \
    "metadata_open_to_first_window" \
    "hot" \
    "tree_prepare_input"
  require_victoria_metric_percentiles \
    "performance.bridge.native.metadata_full_manifest_complete" \
    "metadata_full_manifest_complete" \
    "cold" \
    "tree_prepare_input"
  require_victoria_metric_percentiles \
    "performance.bridge.swift.metadata_scheduler_queue_wait" \
    "demand_queue_wait" \
    "hot" \
    "tree_prepare_input" \
    "foreground"
  require_victoria_metric_percentiles \
    "performance.bridge.swift.metadata_scheduler_queue_wait" \
    "demand_queue_wait" \
    "hot" \
    "tree_prepare_input" \
    "visible"
  require_victoria_metric_percentiles \
    "performance.bridge.swift.content_load" \
    "success" \
    "hot" \
    "content_fetch"
}

if [ "$VALIDATE_ONLY" != "1" ]; then
  rm -rf "$PROOF_ROOT"
  mkdir -p "$PROOF_ROOT"
  if ! curl --fail --silent --show-error --max-time 2 "$COLLECTOR_HEALTH_URL" >/dev/null; then
    echo "OTLP collector health check failed: $COLLECTOR_HEALTH_URL" >&2
    echo "Run 'mise run observability:up' before verify-bridge-headless-manifest." >&2
    exit 1
  fi
  source "$PROJECT_ROOT/scripts/swift-build-slot.sh"
  source "$PROJECT_ROOT/scripts/swift-package-sandbox.sh"
  swift_build_slot_acquire test "verify-bridge-headless-manifest"
  trap swift_build_slot_release EXIT
  bash "$PROJECT_ROOT/scripts/vendor-worktree.sh" verify
  swift build $(swift_package_sandbox_arguments) --build-path "$SWIFT_BUILD_DIR" --build-tests
  PROJECT_ROOT="$PROJECT_ROOT" \
    AGENTSTUDIO_BRIDGE_HEADLESS_PROOF_DIR="$PROOF_ROOT" \
    AGENTSTUDIO_BRIDGE_HEADLESS_BENCHMARK_MODE=1 \
    AGENTSTUDIO_BRIDGE_HEADLESS_VICTORIA_MODE=1 \
    AGENTSTUDIO_TRACE_BACKEND=both \
    AGENTSTUDIO_TRACE_DIR="$TRACE_DIR" \
    AGENTSTUDIO_TRACE_FLUSH=immediate \
    AGENTSTUDIO_TRACE_NAME="$TRACE_NAME" \
    AGENTSTUDIO_TRACE_TAGS=bridge.performance.swift \
    OTEL_EXPORTER_OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-http://127.0.0.1:4318}" \
    OTEL_EXPORTER_OTLP_PROTOCOL="${OTEL_EXPORTER_OTLP_PROTOCOL:-http/protobuf}" \
    SWIFT_TEST_TIMEOUT_SECONDS="$SWIFT_TIMEOUT" \
    swift test $(swift_package_sandbox_arguments) --build-path "$SWIFT_BUILD_DIR" --skip-build --filter "$TEST_FILTER"
fi

ARTIFACT="$(artifact_path)"
if [ -z "$ARTIFACT" ]; then
  echo "missing current-worktree-manifest-proof.json under $PROOF_ROOT" >&2
  exit 1
fi

validate_artifact "$ARTIFACT"

if [ "$VALIDATE_ONLY" != "1" ]; then
  require_victoria_metrics
fi
