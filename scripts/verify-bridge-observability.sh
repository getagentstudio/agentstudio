#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="${AGENTSTUDIO_OBSERVABILITY_STATE_FILE:-$PROJECT_ROOT/tmp/debug-observability/latest-observability.env}"
LOGS_QUERY_URL="${AI_TOOLS_OBSERVABILITY_LOGS_QUERY_URL:-http://127.0.0.1:9428/select/logsql/query}"
METRICS_QUERY_URL="${AI_TOOLS_OBSERVABILITY_METRICS_QUERY_URL:-http://127.0.0.1:8428/api/v1/query}"
TRACES_QUERY_URL="${AI_TOOLS_OBSERVABILITY_TRACES_QUERY_URL:-http://127.0.0.1:10428/select/logsql/query}"
CURL_BIN="${AGENTSTUDIO_CURL_BIN:-/usr/bin/curl}"
DEFAULT_BRIDGE_OBSERVABILITY_SCENARIO="package_apply_content_fetch_v1"
VERIFY_ATTEMPTS="${AGENTSTUDIO_OBSERVABILITY_VERIFY_ATTEMPTS:-30}"
VERIFY_RETRY_DELAY_SECONDS="${AGENTSTUDIO_OBSERVABILITY_VERIFY_RETRY_DELAY_SECONDS:-2}"

state_marker=""
state_query_start=""
state_startup_diagnostic_action=""
state_bridge_observability_scenario=""
if [ -f "$STATE_FILE" ]; then
  while IFS='=' read -r key value; do
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
      AGENTSTUDIO_OBSERVABILITY_QUERY_START)
        state_query_start="$decoded_value"
        ;;
      AGENTSTUDIO_OBSERVABILITY_STARTUP_DIAGNOSTIC_ACTION)
        state_startup_diagnostic_action="$decoded_value"
        ;;
      AGENTSTUDIO_BRIDGE_OBSERVABILITY_SCENARIO)
        state_bridge_observability_scenario="$decoded_value"
        ;;
    esac
  done <"$STATE_FILE"
fi

MARKER="${AGENTSTUDIO_OBSERVABILITY_MARKER:-$state_marker}"
BRIDGE_OBSERVABILITY_SCENARIO="$(
  printf '%s' "${AGENTSTUDIO_BRIDGE_OBSERVABILITY_SCENARIO:-${state_bridge_observability_scenario:-$DEFAULT_BRIDGE_OBSERVABILITY_SCENARIO}}"
)"
QUERY_START="${AGENTSTUDIO_OBSERVABILITY_QUERY_START:-${state_query_start:-$(date -u -v-4H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d '4 hours ago' +"%Y-%m-%dT%H:%M:%SZ")}}"
QUERY_END="${AGENTSTUDIO_OBSERVABILITY_QUERY_END:-$(date -u -v+5M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d '5 minutes' +"%Y-%m-%dT%H:%M:%SZ")}"
STARTUP_DIAGNOSTIC_ACTION="${AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION:-$state_startup_diagnostic_action}"

if [ -z "$MARKER" ]; then
  echo "missing AgentStudio debug observability marker; run the Bridge smoke debug app first" >&2
  exit 1
fi

if [ "$STARTUP_DIAGNOSTIC_ACTION" != "bridge-review-observability-smoke" ]; then
  echo "Bridge observability proof requires startup action bridge-review-observability-smoke" >&2
  echo "actual: ${STARTUP_DIAGNOSTIC_ACTION:-<missing>}" >&2
  echo "state file: $STATE_FILE" >&2
  exit 1
fi

AGENTSTUDIO_OBSERVABILITY_ALLOW_COMPLETED_EXIT=1 \
  "$PROJECT_ROOT/scripts/verify-debug-observability.sh" >/dev/null
"$PROJECT_ROOT/scripts/verify-bridge-web-no-direct-otlp.sh" >/dev/null

logsql_exact_value_filter() {
  local field="${1:?missing LogSQL field}"
  local value="${2:-}"
  local escaped_value="${value//\\/\\\\}"
  escaped_value="${escaped_value//\"/\\\"}"
  printf '%s:="%s"' "$field" "$escaped_value"
}

logsql_quoted_exact_value_filter() {
  local field="${1:?missing LogSQL field}"
  local value="${2:-}"
  local escaped_value="${value//\\/\\\\}"
  escaped_value="${escaped_value//\"/\\\"}"
  printf '"%s":"%s"' "$field" "$escaped_value"
}

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

query_traces() {
  local logsql="$1"
  "$CURL_BIN" --fail --silent --show-error --max-time 5 --get \
    --data-urlencode "query=$logsql" \
    --data-urlencode "start=$QUERY_START" \
    --data-urlencode "end=$QUERY_END" \
    "$TRACES_QUERY_URL"
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

wait_for_trace_query() {
  local description="${1:?missing description}"
  local logsql="${2:?missing trace LogSQL query}"
  local response=""
  local attempt=1
  while [ "$attempt" -le "$VERIFY_ATTEMPTS" ]; do
    response="$(query_traces "$logsql")"
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
import sys

total = 0.0
try:
    payload = json.loads(sys.argv[1])
    for item in payload["data"]["result"]:
        total += float(item["value"][1])
except Exception:
    pass

print(int(total) if total.is_integer() else total)
PY
}

wait_for_metric_count() {
  local description="${1:?missing description}"
  local promql="${2:?missing PromQL query}"
  local count="0"
  local attempt=1
  while [ "$attempt" -le "$VERIFY_ATTEMPTS" ]; do
    count="$(metric_value "$promql")"
    if [ "$count" != "0" ] && [ "$count" != "0.0" ]; then
      printf '%s' "$count"
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

json_truthy_field() {
  local field="${1:?missing JSON field}"
  local payload="${2:-}"
  grep -q "\"$field\":true" <<<"$payload" ||
    grep -q "\"$field\":\"true\"" <<<"$payload"
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

json_zero_int_field() {
  local field="${1:?missing JSON field}"
  local payload="${2:-}"
  grep -Eq "\"$field\":(\"?0\"?)([,}[:space:]]|$)" <<<"$payload"
}

json_positive_int_field() {
  local field="${1:?missing JSON field}"
  local payload="${2:-}"
  /usr/bin/python3 - "$field" "$payload" <<'PY'
import json
import sys

field, payload = sys.argv[1], sys.argv[2]
for line in payload.splitlines():
    if not line.strip():
        continue
    try:
        record = json.loads(line)
    except json.JSONDecodeError:
        continue
    try:
        value = int(record[field])
    except (KeyError, TypeError, ValueError):
        continue
    if value > 0:
        sys.exit(0)
sys.exit(1)
PY
}

json_positive_materialized_line_count() {
  local payload="${1:-}"
  /usr/bin/python3 - "$payload" <<'PY'
import json
import sys

payload = sys.argv[1]
fields = [
    "agentstudio.startup_diagnostic.bridge.selected_materialized.addition_line.count",
    "agentstudio.startup_diagnostic.bridge.selected_materialized.deletion_line.count",
    "agentstudio.startup_diagnostic.bridge.selected_materialized.file_line.count",
]
for line in payload.splitlines():
    if not line.strip():
        continue
    try:
        record = json.loads(line)
    except json.JSONDecodeError:
        continue
    total = 0
    for field in fields:
        try:
            total += int(record.get(field, 0))
        except (TypeError, ValueError):
            pass
    if total > 0:
        sys.exit(0)
sys.exit(1)
PY
}

json_matching_string_fields() {
  local left_field="${1:?missing left JSON field}"
  local right_field="${2:?missing right JSON field}"
  local payload="${3:-}"
  /usr/bin/python3 - "$left_field" "$right_field" "$payload" <<'PY'
import json
import sys

left_field, right_field, payload = sys.argv[1], sys.argv[2], sys.argv[3]
for line in payload.splitlines():
    if not line.strip():
        continue
    try:
        record = json.loads(line)
    except json.JSONDecodeError:
        continue
    left = record.get(left_field)
    right = record.get(right_field)
    if isinstance(left, str) and left and left == right:
        sys.exit(0)
sys.exit(1)
PY
}

marker_filter="$(logsql_exact_value_filter agent.proof.marker "$MARKER")"
scenario_filter="$(logsql_exact_value_filter agentstudio.bridge.test.scenario "$BRIDGE_OBSERVABILITY_SCENARIO")"
trace_marker_filter="$(logsql_quoted_exact_value_filter span_attr:agent.proof.marker "$MARKER")"
trace_scenario_filter="$(
  logsql_quoted_exact_value_filter span_attr:agentstudio.bridge.test.scenario "$BRIDGE_OBSERVABILITY_SCENARIO"
)"
base_log_query="service.name:AgentStudio dev.runtime.flavor:debug $marker_filter $scenario_filter"
diagnostic_action_filter="$(logsql_exact_value_filter agentstudio.startup_diagnostic.action "$STARTUP_DIAGNOSTIC_ACTION")"
diagnostic_log_query="service.name:AgentStudio dev.runtime.flavor:debug $marker_filter $diagnostic_action_filter"
diagnostic_fields="_msg,agentstudio.startup_diagnostic.action,agentstudio.startup_diagnostic.expected_visible_pane.count,agentstudio.startup_diagnostic.bridge.review_expected_item.count,agentstudio.startup_diagnostic.bridge.review_metadata_item.count,agentstudio.startup_diagnostic.bridge.review_metadata_tree_row.count,agentstudio.startup_diagnostic.bridge.review_shell.visible,agentstudio.startup_diagnostic.bridge.review_shell.state,agentstudio.startup_diagnostic.bridge.code_view.visible,agentstudio.startup_diagnostic.bridge.selected_item.visible,agentstudio.startup_diagnostic.bridge.selected_path.visible,agentstudio.startup_diagnostic.bridge.selected_content.visible,agentstudio.startup_diagnostic.bridge.selected_content.state,agentstudio.startup_diagnostic.bridge.selected_content_role.count,agentstudio.startup_diagnostic.bridge.selected_content_cache_key.count,agentstudio.startup_diagnostic.bridge.selected_content_character.count,agentstudio.startup_diagnostic.bridge.selected_content_line.count,agentstudio.startup_diagnostic.bridge.selected_materialized.update_result,agentstudio.startup_diagnostic.bridge.selected_materialized.item_type,agentstudio.startup_diagnostic.bridge.selected_materialized.item_version,agentstudio.startup_diagnostic.bridge.selected_materialized.addition_line.count,agentstudio.startup_diagnostic.bridge.selected_materialized.deletion_line.count,agentstudio.startup_diagnostic.bridge.selected_materialized.file_line.count,agentstudio.startup_diagnostic.bridge.page_issue.count,agentstudio.startup_diagnostic.bridge.diff_container.count,agentstudio.startup_diagnostic.bridge.code_view.instance.first_item.height_px,agentstudio.startup_diagnostic.bridge.code_view.rendered_item.count,agentstudio.startup_diagnostic.bridge.code_view.rendered_item.type,agentstudio.startup_diagnostic.bridge.code_view.rendered_item.version,agentstudio.startup_diagnostic.bridge.code_view_panel.width_px,agentstudio.startup_diagnostic.bridge.code_view_panel.height_px,agentstudio.startup_diagnostic.bridge.diff_container.width_px,agentstudio.startup_diagnostic.bridge.code_text.length,agentstudio.startup_diagnostic.bridge.code_shadow_text.length,agentstudio.startup_diagnostic.bridge.worker_pool.state,agentstudio.startup_diagnostic.bridge.worker_pool.manager_state,agentstudio.startup_diagnostic.bridge.worker_pool.workers_failed,agentstudio.startup_diagnostic.bridge.worker_diagnostic.diff_success_count,agentstudio.startup_diagnostic.bridge.worker_diagnostic.failure_count,agentstudio.startup_diagnostic.bridge.frame_liveness.raf_alive,agentstudio.startup_diagnostic.render_proof.succeeded"
diagnostic_skipped_query="$diagnostic_log_query _msg:app.startup_diagnostic_action.skipped"

diagnostic_completed_response="$(
  wait_for_optional_log_query \
    "$diagnostic_log_query _msg:app.startup_diagnostic_action.completed | fields $diagnostic_fields | limit 5"
)"

if [ -z "$diagnostic_completed_response" ]; then
  diagnostic_skipped_response="$(
    wait_for_optional_log_query \
      "$diagnostic_skipped_query | fields $diagnostic_fields,agentstudio.startup_diagnostic.skip_reason | limit 5"
  )"
  if is_frame_not_live_skip "$diagnostic_skipped_response"; then
    echo "SKIP Bridge startup diagnostic bridge-review-observability-smoke: frame_not_live"
    echo "$diagnostic_skipped_response"
    exit 0
  fi
  echo "missing Bridge startup diagnostic completed record for marker $MARKER" >&2
  echo "$diagnostic_skipped_response" >&2
  exit 1
fi

required_truthy_diagnostic_fields=(
  agentstudio.startup_diagnostic.render_proof.succeeded
  agentstudio.startup_diagnostic.bridge.review_shell.visible
  agentstudio.startup_diagnostic.bridge.code_view.visible
  agentstudio.startup_diagnostic.bridge.selected_item.visible
  agentstudio.startup_diagnostic.bridge.selected_path.visible
  agentstudio.startup_diagnostic.bridge.selected_content.visible
)

for field in "${required_truthy_diagnostic_fields[@]}"; do
  if ! json_truthy_field "$field" "$diagnostic_completed_response"; then
    echo "Bridge startup diagnostic completed with false or missing field: $field" >&2
    echo "$diagnostic_completed_response" >&2
    exit 1
  fi
done

if ! json_exact_string_field \
  agentstudio.startup_diagnostic.bridge.selected_content.state \
  ready \
  "$diagnostic_completed_response"; then
  echo "Bridge startup diagnostic selected content is not ready" >&2
  echo "$diagnostic_completed_response" >&2
  exit 1
fi

if ! json_exact_string_field \
  agentstudio.startup_diagnostic.bridge.selected_materialized.update_result \
  updated \
  "$diagnostic_completed_response"; then
  echo "Bridge startup diagnostic did not materialize selected content" >&2
  echo "$diagnostic_completed_response" >&2
  exit 1
fi

required_positive_diagnostic_fields=(
  agentstudio.startup_diagnostic.expected_visible_pane.count
  agentstudio.startup_diagnostic.bridge.review_expected_item.count
  agentstudio.startup_diagnostic.bridge.review_metadata_item.count
  agentstudio.startup_diagnostic.bridge.review_metadata_tree_row.count
  agentstudio.startup_diagnostic.bridge.selected_content_role.count
  agentstudio.startup_diagnostic.bridge.selected_content_cache_key.count
  agentstudio.startup_diagnostic.bridge.selected_content_character.count
  agentstudio.startup_diagnostic.bridge.selected_materialized.item_version
  agentstudio.startup_diagnostic.bridge.diff_container.count
  agentstudio.startup_diagnostic.bridge.code_view.instance.first_item.height_px
  agentstudio.startup_diagnostic.bridge.code_view.rendered_item.count
  agentstudio.startup_diagnostic.bridge.code_view.rendered_item.version
  agentstudio.startup_diagnostic.bridge.code_view_panel.width_px
  agentstudio.startup_diagnostic.bridge.code_view_panel.height_px
  agentstudio.startup_diagnostic.bridge.diff_container.width_px
  agentstudio.startup_diagnostic.bridge.code_text.length
  agentstudio.startup_diagnostic.bridge.code_shadow_text.length
  agentstudio.startup_diagnostic.bridge.worker_diagnostic.diff_success_count
)

for field in "${required_positive_diagnostic_fields[@]}"; do
  if ! json_positive_int_field "$field" "$diagnostic_completed_response"; then
    echo "Bridge startup diagnostic completed with non-positive or missing field: $field" >&2
    echo "$diagnostic_completed_response" >&2
    exit 1
  fi
done

if ! json_positive_materialized_line_count "$diagnostic_completed_response"; then
  echo "Bridge startup diagnostic completed without materialized selected content lines" >&2
  echo "$diagnostic_completed_response" >&2
  exit 1
fi

if ! json_zero_int_field \
  agentstudio.startup_diagnostic.bridge.page_issue.count \
  "$diagnostic_completed_response"; then
  echo "Bridge startup diagnostic reported page issues" >&2
  echo "$diagnostic_completed_response" >&2
  exit 1
fi

if ! json_zero_int_field \
  agentstudio.startup_diagnostic.bridge.worker_diagnostic.failure_count \
  "$diagnostic_completed_response"; then
  echo "Bridge startup diagnostic reported worker diagnostic failures" >&2
  echo "$diagnostic_completed_response" >&2
  exit 1
fi

if ! json_matching_string_fields \
  agentstudio.startup_diagnostic.bridge.code_view.rendered_item.type \
  agentstudio.startup_diagnostic.bridge.selected_materialized.item_type \
  "$diagnostic_completed_response"; then
  echo "Bridge startup diagnostic rendered item type does not match materialized selected item type" >&2
  echo "$diagnostic_completed_response" >&2
  exit 1
fi

if ! json_exact_string_field \
  agentstudio.startup_diagnostic.bridge.worker_pool.state \
  ready \
  "$diagnostic_completed_response"; then
  echo "Bridge startup diagnostic worker pool is not ready" >&2
  echo "$diagnostic_completed_response" >&2
  exit 1
fi

if ! json_exact_string_field \
  agentstudio.startup_diagnostic.bridge.worker_pool.manager_state \
  initialized \
  "$diagnostic_completed_response"; then
  echo "Bridge startup diagnostic worker pool manager is not initialized" >&2
  echo "$diagnostic_completed_response" >&2
  exit 1
fi

required_log_event_contracts=(
  "performance.bridge.swift.package_build|package_build|data|cold|review_metadata|swift"
  "performance.bridge.swift.delta_build|delta_build|data|warm|review_delta|swift"
  "performance.bridge.swift.content_register|content_register|data|cold|review_metadata|swift"
  "performance.bridge.swift.content_load|success|data|hot|content_fetch|content"
  "performance.bridge.swift.telemetry_ingest|accepted|observability|best_effort|telemetry_ingest|swift"
  "performance.bridge.webkit.push_envelope|transport|data|hot|diff_status|push"
  "performance.bridge.webkit.rpc_dispatch|dispatch|control|warm|review_rpc|rpc"
  "performance.bridge.webkit.rpc_response|success|control|warm|review_rpc|rpc"
  "performance.bridge.webkit.telemetry_batch|accepted|observability|best_effort|telemetry_batch|rpc"
  "performance.bridge.web.intake_frame|intake|data|cold|review_metadata|intake"
  "performance.bridge.web.push_apply|apply|data|hot|diff_status|push"
  "performance.bridge.web.review_metadata_apply|review_metadata_apply|data|hot|review_metadata|intake"
  "performance.bridge.web.rpc_send|send|control|warm|review_rpc|rpc"
  "performance.bridge.web.content_fetch|fetch|data|hot|content_fetch|content"
  "performance.bridge.web.first_render|render|data|hot|review_metadata|intake"
  "performance.bridge.trees.projection_build|projection_build|data|warm|review_projection|worker"
  "performance.bridge.viewer.content_queue|content_queue|data|hot|content_fetch|content"
  "performance.bridge.pierre.item_update|item_update|data|hot|code_view_item|swift"
  "performance.bridge.shiki.highlight|highlight|data|hot|shiki_highlight|worker"
  "performance.bridge.worker.task|worker_task|data|warm|worker_task|worker"
)

historical_bridge_lane_field="agentstudio.bridge.${BRIDGE_HISTORICAL_LANE_SUFFIX:-lane}"

for contract in "${required_log_event_contracts[@]}"; do
  IFS='|' read -r event_name phase plane priority slice transport <<<"$contract"
  response="$(wait_for_log_query \
    "missing Bridge log event for marker $MARKER: $event_name $plane/$priority/$slice/$transport" \
    "$base_log_query _msg:$event_name $(logsql_exact_value_filter agentstudio.bridge.phase "$phase") $(logsql_exact_value_filter agentstudio.bridge.plane "$plane") $(logsql_exact_value_filter agentstudio.bridge.priority "$priority") $(logsql_exact_value_filter agentstudio.bridge.slice "$slice") $(logsql_exact_value_filter agentstudio.bridge.transport "$transport") | fields _msg,agentstudio.bridge.phase,agentstudio.bridge.plane,agentstudio.bridge.priority,agentstudio.bridge.slice,agentstudio.bridge.transport,trace_id,span_id | limit 20")"
done

required_metric_event_contracts=(
  "performance.bridge.swift.package_build|package_build|data|cold|review_metadata"
  "performance.bridge.swift.content_load|success|data|hot|content_fetch"
  "performance.bridge.webkit.push_envelope|transport|data|hot|diff_status"
  "performance.bridge.webkit.rpc_dispatch|dispatch|control|warm|review_rpc"
  "performance.bridge.webkit.telemetry_batch|accepted|observability|best_effort|telemetry_batch"
  "performance.bridge.web.intake_frame|intake|data|cold|review_metadata"
  "performance.bridge.web.push_apply|apply|data|hot|diff_status"
  "performance.bridge.web.review_metadata_apply|review_metadata_apply|data|hot|review_metadata"
  "performance.bridge.web.content_fetch|fetch|data|hot|content_fetch"
  "performance.bridge.web.first_render|render|data|hot|review_metadata"
  "performance.bridge.trees.projection_build|projection_build|data|warm|review_projection"
  "performance.bridge.viewer.content_queue|content_queue|data|hot|content_fetch"
  "performance.bridge.pierre.item_update|item_update|data|hot|code_view_item"
  "performance.bridge.shiki.highlight|highlight|data|hot|shiki_highlight"
  "performance.bridge.worker.task|worker_task|data|warm|worker_task"
)

for contract in "${required_metric_event_contracts[@]}"; do
  IFS='|' read -r event_name phase plane priority slice <<<"$contract"
  promql='agentstudio_performance_events_total{service.name="AgentStudio",dev.runtime.flavor="debug",agent.proof.marker="'"$MARKER"'",event="'"$event_name"'",phase="'"$phase"'",plane="'"$plane"'",priority="'"$priority"'",slice="'"$slice"'"}'
  count="$(wait_for_metric_count "missing Bridge metric counter for marker $MARKER: $event_name $phase/$plane/$priority/$slice" "$promql")"
done

for forbidden_review_push_slice in \
  diff_package_metadata \
  diff_package_delta \
  review_metadata \
  review_delta \
  review_invalidation \
  review_reset
do
  forbidden_package_push_promql='agentstudio_performance_events_total{service.name="AgentStudio",dev.runtime.flavor="debug",agent.proof.marker="'"$MARKER"'",event="performance.bridge.webkit.push_envelope",phase="transport",plane="data",slice="'"$forbidden_review_push_slice"'"}'
  forbidden_package_push_count="$(metric_value "$forbidden_package_push_promql")"
  if [ "$forbidden_package_push_count" != "0" ] && [ "$forbidden_package_push_count" != "0.0" ]; then
    echo "Bridge Review package data still used WebKit push transport" >&2
    echo "slice=$forbidden_review_push_slice count=$forbidden_package_push_count" >&2
    exit 1
  fi

  forbidden_web_push_apply_promql='agentstudio_performance_events_total{service.name="AgentStudio",dev.runtime.flavor="debug",agent.proof.marker="'"$MARKER"'",event="performance.bridge.web.push_apply",phase="apply",plane="data",slice="'"$forbidden_review_push_slice"'",transport="push"}'
  forbidden_web_push_apply_count="$(metric_value "$forbidden_web_push_apply_promql")"
  if [ "$forbidden_web_push_apply_count" != "0" ] && [ "$forbidden_web_push_apply_count" != "0.0" ]; then
    echo "Bridge Review package data still used web push apply transport" >&2
    echo "slice=$forbidden_review_push_slice count=$forbidden_web_push_apply_count" >&2
    exit 1
  fi
done

for forbidden_first_render_push_slice in diff_package_metadata review_metadata; do
  forbidden_first_render_push_promql='agentstudio_performance_events_total{service.name="AgentStudio",dev.runtime.flavor="debug",agent.proof.marker="'"$MARKER"'",event="performance.bridge.web.first_render",phase="render",plane="data",slice="'"$forbidden_first_render_push_slice"'",transport="push"}'
  forbidden_first_render_push_count="$(metric_value "$forbidden_first_render_push_promql")"
  if [ "$forbidden_first_render_push_count" != "0" ] && [ "$forbidden_first_render_push_count" != "0.0" ]; then
    echo "Bridge Review first render still reported push transport" >&2
    echo "slice=$forbidden_first_render_push_slice count=$forbidden_first_render_push_count" >&2
    exit 1
  fi
done

broad_push_envelope_promql='agentstudio_performance_events_total{service.name="AgentStudio",dev.runtime.flavor="debug",agent.proof.marker="'"$MARKER"'",event="performance.bridge.webkit.push_envelope"} unless agentstudio_performance_events_total{service.name="AgentStudio",dev.runtime.flavor="debug",agent.proof.marker="'"$MARKER"'",event="performance.bridge.webkit.push_envelope",phase=~".+",plane=~".+",priority=~".+",slice=~".+"}'
broad_push_envelope_count="$(metric_value "$broad_push_envelope_promql")"
if [ "$broad_push_envelope_count" != "0" ] && [ "$broad_push_envelope_count" != "0.0" ]; then
  echo "missing Bridge broad push_envelope metric fallback guard: unlabeled fallback series survived" >&2
  echo "count=$broad_push_envelope_count" >&2
  exit 1
fi

unknown_push_envelope_promql='agentstudio_performance_events_total{service.name="AgentStudio",dev.runtime.flavor="debug",agent.proof.marker="'"$MARKER"'",event="performance.bridge.webkit.push_envelope",slice="unknown"}'
unknown_push_envelope_count="$(metric_value "$unknown_push_envelope_promql")"
if [ "$unknown_push_envelope_count" != "0" ] && [ "$unknown_push_envelope_count" != "0.0" ]; then
  echo "Bridge push_envelope metric used unknown producer slice" >&2
  echo "count=$unknown_push_envelope_count" >&2
  exit 1
fi

legacy_package_push_count="$(metric_value 'agentstudio_performance_events_total{service.name="AgentStudio",dev.runtime.flavor="debug",agent.proof.marker="'"$MARKER"'",event="performance.bridge.webkit.package_push"}')"
if [ "$legacy_package_push_count" != "0" ] && [ "$legacy_package_push_count" != "0.0" ]; then
  echo "legacy Bridge package_push metric survived hard cutover" >&2
  echo "count=$legacy_package_push_count" >&2
  exit 1
fi

legacy_package_apply_count="$(metric_value 'agentstudio_performance_events_total{service.name="AgentStudio",dev.runtime.flavor="debug",agent.proof.marker="'"$MARKER"'",event="performance.bridge.web.package_apply"}')"
if [ "$legacy_package_apply_count" != "0" ] && [ "$legacy_package_apply_count" != "0.0" ]; then
  echo "legacy Bridge package_apply metric survived hard cutover" >&2
  echo "count=$legacy_package_apply_count" >&2
  exit 1
fi

trace_response="$(
  wait_for_trace_query \
    "missing Bridge Swift package_build span in VictoriaTraces for marker $MARKER" \
    "$trace_marker_filter $trace_scenario_filter \"span_attr:agentstudio.bridge.phase\":\"package_build\" \"span_attr:agentstudio.bridge.transport\":\"swift\" | fields trace_id,span_id,span_name,span_attr:agent.proof.marker,span_attr:agentstudio.bridge.test.scenario,span_attr:agentstudio.bridge.phase | limit 20"
)"

content_trace_response="$(
  wait_for_trace_query \
    "missing Bridge content fetch span in VictoriaTraces for marker $MARKER" \
    "$trace_marker_filter $trace_scenario_filter \"span_attr:agentstudio.bridge.phase\":\"fetch\" \"span_attr:agentstudio.bridge.transport\":\"content\" | fields trace_id,span_id,span_name,span_attr:agent.proof.marker,span_attr:agentstudio.bridge.test.scenario,span_attr:agentstudio.bridge.phase | limit 20"
)"

rpc_trace_response="$(
  wait_for_trace_query \
    "missing Bridge review RPC span in VictoriaTraces for marker $MARKER" \
    "$trace_marker_filter $trace_scenario_filter \"span_attr:agentstudio.bridge.phase\":\"dispatch\" \"span_attr:agentstudio.bridge.transport\":\"rpc\" \"span_attr:agentstudio.bridge.rpc.method_class\":\"review\" | fields trace_id,span_id,span_name,span_attr:agent.proof.marker,span_attr:agentstudio.bridge.test.scenario,span_attr:agentstudio.bridge.phase,span_attr:agentstudio.bridge.rpc.method_class | limit 20"
)"

for unsafe_field in \
  "$historical_bridge_lane_field" \
  agentstudio.bridge.dynamic_key \
  agentstudio.bridge.prompt \
  agentstudio.bridge.raw_error \
  agentstudio.bridge.payload \
  agentstudio.bridge.text \
  agentstudio.bridge.output \
  agentstudio.bridge.token \
  agentstudio.bridge.secret
do
  unsafe_field_response="$(query_logs "$base_log_query $unsafe_field:* | limit 1")"
  if [ -n "$unsafe_field_response" ]; then
    echo "unsafe Bridge field survived OTLP logs: $unsafe_field" >&2
    echo "$unsafe_field_response" >&2
    exit 1
  fi
done

unknown_push_envelope_log_response="$(
  query_logs "$base_log_query _msg:performance.bridge.webkit.push_envelope $(logsql_exact_value_filter agentstudio.bridge.slice unknown) | limit 1"
)"
if [ -n "$unknown_push_envelope_log_response" ]; then
  echo "Bridge push_envelope log used unknown producer slice" >&2
  echo "$unknown_push_envelope_log_response" >&2
  exit 1
fi

legacy_package_push_log_response="$(
  query_logs "$base_log_query _msg:performance.bridge.webkit.package_push | limit 1"
)"
if [ -n "$legacy_package_push_log_response" ]; then
  echo "legacy Bridge package_push log survived hard cutover" >&2
  echo "$legacy_package_push_log_response" >&2
  exit 1
fi

legacy_package_apply_log_response="$(
  query_logs "$base_log_query _msg:performance.bridge.web.package_apply | limit 1"
)"
if [ -n "$legacy_package_apply_log_response" ]; then
  echo "legacy Bridge package_apply log survived hard cutover" >&2
  echo "$legacy_package_apply_log_response" >&2
  exit 1
fi

for forbidden_review_push_slice in \
  diff_package_metadata \
  diff_package_delta \
  review_metadata \
  review_delta \
  review_invalidation \
  review_reset
do
  forbidden_package_push_log_response="$(
    query_logs "$base_log_query _msg:performance.bridge.webkit.push_envelope $(logsql_exact_value_filter agentstudio.bridge.slice "$forbidden_review_push_slice") | limit 1"
  )"
  if [ -n "$forbidden_package_push_log_response" ]; then
    echo "Bridge Review package data still used WebKit push logs" >&2
    echo "$forbidden_package_push_log_response" >&2
    exit 1
  fi

  forbidden_web_push_apply_log_response="$(
    query_logs "$base_log_query _msg:performance.bridge.web.push_apply $(logsql_exact_value_filter agentstudio.bridge.slice "$forbidden_review_push_slice") $(logsql_exact_value_filter agentstudio.bridge.transport push) | limit 1"
  )"
  if [ -n "$forbidden_web_push_apply_log_response" ]; then
    echo "Bridge Review package data still used web push apply logs" >&2
    echo "$forbidden_web_push_apply_log_response" >&2
    exit 1
  fi
done

for forbidden_first_render_push_slice in diff_package_metadata review_metadata; do
  forbidden_first_render_push_log_response="$(
    query_logs "$base_log_query _msg:performance.bridge.web.first_render $(logsql_exact_value_filter agentstudio.bridge.slice "$forbidden_first_render_push_slice") $(logsql_exact_value_filter agentstudio.bridge.transport push) | limit 1"
  )"
  if [ -n "$forbidden_first_render_push_log_response" ]; then
    echo "Bridge Review first render still reported push transport in logs" >&2
    echo "$forbidden_first_render_push_log_response" >&2
    exit 1
  fi
done

telemetry_self_rpc_log_response="$(
  query_logs "$base_log_query agentstudio.bridge.rpc.method_class:telemetry | limit 1"
)"
if [ -n "$telemetry_self_rpc_log_response" ]; then
  echo "Bridge telemetry self-RPC survived OTLP logs" >&2
  echo "$telemetry_self_rpc_log_response" >&2
  exit 1
fi

telemetry_self_rpc_trace_response="$(
  query_traces "$trace_marker_filter $trace_scenario_filter \"span_attr:agentstudio.bridge.rpc.method_class\":\"telemetry\" | limit 1"
)"
if [ -n "$telemetry_self_rpc_trace_response" ]; then
  echo "Bridge telemetry self-RPC survived VictoriaTraces" >&2
  echo "$telemetry_self_rpc_trace_response" >&2
  exit 1
fi

echo "bridge observability ok:"
echo "marker=$MARKER"
echo "scenario=$BRIDGE_OBSERVABILITY_SCENARIO"
echo "logs=${#required_log_event_contracts[@]} metrics=${#required_metric_event_contracts[@]} traces=3"
echo "telemetry_self_rpc=absent"
