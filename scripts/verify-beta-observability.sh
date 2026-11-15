#!/bin/bash
set -euo pipefail

LOGS_QUERY_URL="${AI_TOOLS_OBSERVABILITY_LOGS_QUERY_URL:-http://127.0.0.1:9428/select/logsql/query}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="${AGENTSTUDIO_OBSERVABILITY_STATE_FILE:-$PROJECT_ROOT/tmp/beta-observability/latest-observability.env}"
CURL_BIN="${AGENTSTUDIO_CURL_BIN:-/usr/bin/curl}"
LSOF_BIN="${AGENTSTUDIO_LSOF_BIN:-/usr/sbin/lsof}"

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

state_marker=""
state_proof_token=""
state_service_version=""
state_query_start=""
state_status=""
state_reason=""
state_app=""
state_pid=""
state_startup_diagnostic_action=""
state_preferences_mode=""
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
      AGENTSTUDIO_OBSERVABILITY_PROOF_TOKEN)
        state_proof_token="$decoded_value"
        ;;
      AGENTSTUDIO_OBSERVABILITY_SERVICE_VERSION)
        state_service_version="$decoded_value"
        ;;
      AGENTSTUDIO_OBSERVABILITY_QUERY_START)
        state_query_start="$decoded_value"
        ;;
      AGENTSTUDIO_OBSERVABILITY_STATUS)
        state_status="$decoded_value"
        ;;
      AGENTSTUDIO_OBSERVABILITY_REASON)
        state_reason="$decoded_value"
        ;;
      AGENTSTUDIO_OBSERVABILITY_APP)
        state_app="$decoded_value"
        ;;
      AGENTSTUDIO_OBSERVABILITY_PID)
        state_pid="$decoded_value"
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
    echo "AgentStudio beta observability did not start: $state_status ($state_reason)" >&2
  else
    echo "AgentStudio beta observability did not start: $state_status" >&2
  fi
  echo "state file: $STATE_FILE" >&2
  exit 1
fi

MARKER="${AGENTSTUDIO_OBSERVABILITY_MARKER:-$state_marker}"
SERVICE_VERSION="${AGENTSTUDIO_OBSERVABILITY_SERVICE_VERSION:-$state_service_version}"
EXPECTED_APP="${AGENTSTUDIO_EXPECTED_BETA_APP:-}"

if [ -z "$MARKER" ]; then
  echo "missing AgentStudio observability marker; run mise run run-beta-observability first" >&2
  exit 1
fi

if [ -z "$EXPECTED_APP" ]; then
  echo "missing AGENTSTUDIO_EXPECTED_BETA_APP; beta release proof must bind verification to the exact launched app" >&2
  echo "state file: $STATE_FILE" >&2
  exit 1
fi

bundle_path_for_executable() {
  local executable_path="${1:?missing executable path}"
  case "$executable_path" in
    *.app/Contents/MacOS/AgentStudio)
      printf '%s\n' "${executable_path%/Contents/MacOS/AgentStudio}"
      ;;
  esac
}

bundle_release_channel_for_executable() {
  local executable_path="${1:?missing executable path}"
  local bundle_path
  bundle_path="$(bundle_path_for_executable "$executable_path")"
  [ -n "$bundle_path" ] || return 0
  /usr/libexec/PlistBuddy -c 'Print :AgentStudioReleaseChannel' "$bundle_path/Contents/Info.plist" 2>/dev/null || true
}

process_executable_path() {
  local pid="${1:?missing pid}"
  local txt_output
  if ! txt_output="$("$LSOF_BIN" -a -p "$pid" -d txt -Fn 2>/dev/null)"; then
    echo "unable to inspect AgentStudio beta PID $pid with $LSOF_BIN" >&2
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

actual_app="$(
  /usr/bin/python3 - "$state_app" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]) if sys.argv[1] else "")
PY
)"
expected_app="$(
  /usr/bin/python3 - "$EXPECTED_APP" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
)"
if [ -z "$actual_app" ] || [ "$actual_app" != "$expected_app" ]; then
  echo "AgentStudio beta observability app mismatch" >&2
  echo "expected: $expected_app" >&2
  echo "actual: ${actual_app:-<missing>}" >&2
  echo "state file: $STATE_FILE" >&2
  exit 1
fi

if [ "$state_status" != "running" ]; then
  echo "AgentStudio beta observability state is not running: ${state_status:-<missing>}" >&2
  echo "state file: $STATE_FILE" >&2
  exit 1
fi
case "$state_pid" in
  ''|*[!0-9]*)
    echo "AgentStudio beta observability state missing numeric PID" >&2
    echo "state file: $STATE_FILE" >&2
    exit 1
    ;;
esac
if ! kill -0 "$state_pid" >/dev/null 2>&1; then
  echo "AgentStudio beta observability PID is not running: $state_pid" >&2
  echo "state file: $STATE_FILE" >&2
  exit 1
fi
process_executable="$(process_executable_path "$state_pid")"
if [ -z "$process_executable" ] ||
  [ "$(bundle_release_channel_for_executable "$process_executable")" != "beta" ]; then
  echo "AgentStudio beta observability PID does not resolve to a beta app: $state_pid" >&2
  echo "state file: $STATE_FILE" >&2
  exit 1
fi
process_app="$(realpath_or_empty "$(bundle_path_for_executable "$process_executable")")"
if [ -z "$process_app" ] || [ "$process_app" != "$expected_app" ]; then
  echo "AgentStudio beta observability PID app mismatch" >&2
  echo "expected: $expected_app" >&2
  echo "actual: ${process_app:-<missing>}" >&2
  echo "state file: $STATE_FILE" >&2
  exit 1
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

QUERY_START="${AGENTSTUDIO_OBSERVABILITY_QUERY_START:-${state_query_start:-$(portable_utc_time -4H '4 hours ago')}}"
QUERY_END="${AGENTSTUDIO_OBSERVABILITY_QUERY_END:-$(portable_utc_time +5M '5 minutes')}"

stream_query="{service.name=\"AgentStudio\",dev.release.channel=\"beta\"}"
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

positive_response="$(query_logs "$query | fields service.name,service.version,dev.release.channel,dev.runtime.flavor,_msg | limit 20")"
if [ -z "$positive_response" ]; then
  echo "no AgentStudio beta records found in VictoriaLogs for query window $QUERY_START..$QUERY_END" >&2
  exit 1
fi
if [ -n "$SERVICE_VERSION" ] && ! grep -q "\"service.version\":\"${SERVICE_VERSION}\"" <<<"$positive_response"; then
  echo "AgentStudio beta records did not include expected service.version=$SERVICE_VERSION" >&2
  echo "$positive_response" >&2
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

startup_diagnostic_action="${AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION:-$state_startup_diagnostic_action}"
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
    echo "sensitive field survived AgentStudio OTLP export: $field" >&2
    echo "$sensitive_response" >&2
    exit 1
  fi
done

echo "beta observability ok:"
sed -n '1,5p' <<<"$startup_response"
