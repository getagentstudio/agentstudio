#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_STACK_HELPER="$HOME/dev/ai-tools/observability/observability-stack"
STACK_HELPER="${AI_TOOLS_OBSERVABILITY_STACK_HELPER:-$DEFAULT_STACK_HELPER}"
COLLECTOR_HEALTH_URL="${AI_TOOLS_OBSERVABILITY_COLLECTOR_HEALTH_URL:-http://127.0.0.1:13133/}"
OPEN_BIN="${AGENTSTUDIO_OPEN_BIN:-/usr/bin/open}"
PGREP_BIN="${AGENTSTUDIO_PGREP_BIN:-/usr/bin/pgrep}"
LSOF_BIN="${AGENTSTUDIO_LSOF_BIN:-/usr/sbin/lsof}"
CURL_BIN="${AGENTSTUDIO_CURL_BIN:-/usr/bin/curl}"
DITTO_BIN="${AGENTSTUDIO_DITTO_BIN:-/usr/bin/ditto}"
CODESIGN_BIN="${AGENTSTUDIO_CODESIGN_BIN:-/usr/bin/codesign}"
SECURITY_BIN="${AGENTSTUDIO_SECURITY_BIN:-/usr/bin/security}"
NORMAL_QUIT_BIN="${AGENTSTUDIO_NORMAL_QUIT_BIN:-/usr/bin/osascript}"
DEBUG_LAUNCH_ACTIVATE="${AGENTSTUDIO_DEBUG_LAUNCH_ACTIVATE:-0}"

if [ "$DEBUG_LAUNCH_ACTIVATE" != "0" ] && [ "$DEBUG_LAUNCH_ACTIVATE" != "1" ]; then
  echo "AGENTSTUDIO_DEBUG_LAUNCH_ACTIVATE must be 0 or 1" >&2
  exit 2
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
  if [ "${AGENTSTUDIO_OBSERVABILITY_ALLOW_TEST_OVERRIDES:-0}" = "1" ]; then
    return
  fi
  if [ -n "${AGENTSTUDIO_OBSERVABILITY_TEST_CANDIDATE_IDENTITY:-}" ] ||
    [ "$NORMAL_QUIT_BIN" != "/usr/bin/osascript" ]
  then
    echo "candidate identity and normal-quit overrides require AGENTSTUDIO_OBSERVABILITY_ALLOW_TEST_OVERRIDES=1" >&2
    exit 2
  fi
  if [ "$(canonical_path "$STACK_HELPER")" != "$(canonical_path "$DEFAULT_STACK_HELPER")" ]; then
    echo "AI_TOOLS_OBSERVABILITY_STACK_HELPER must point to the trusted ai-tools helper: $DEFAULT_STACK_HELPER" >&2
    exit 2
  fi
}

validate_observability_controls

usage() {
  cat <<'USAGE'
Usage: run-debug-observability.sh [--build-path <dir>] [--skip-build] [--detach]
       run-debug-observability.sh --print-identity
       run-debug-observability.sh --preflight-idle
       run-debug-observability.sh --validate-candidate
       run-debug-observability.sh --retire-candidate

Builds the debug AgentStudio binary, wraps it in a per-worktree Debug .app, and
launches that app with full trace tags exported to the already-running shared
Victoria/OTel stack. This helper does not start observability services; run
`mise run observability:up` first.
USAGE
}

set_plist_string() {
  local plist_path="${1:?missing plist path}"
  local key="${2:?missing plist key}"
  local value="${3:?missing plist value}"

  if /usr/libexec/PlistBuddy -c "Print :$key" "$plist_path" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :$key \"$value\"" "$plist_path"
  else
    /usr/libexec/PlistBuddy -c "Add :$key string \"$value\"" "$plist_path"
  fi
}

write_state_value() {
  local key="${1:?missing state key}"
  local value="${2:-}"
  printf '%s=%q\n' "$key" "$value"
}

trace_name_is_safe_path_component() {
  local name="${1:-}"
  [ -n "$name" ] || return 1
  [ "$name" != "." ] || return 1
  [ "$name" != ".." ] || return 1
  [ "${#name}" -le 160 ] || return 1
  case "$name" in
    *[!A-Za-z0-9._-]*)
      return 1
      ;;
  esac
}

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

read_state_value() {
  local key="${1:?missing state key}"
  local state_path="${2:?missing state path}"
  local raw_value
  raw_value="$(sed -n "s/^${key}=//p" "$state_path" | tail -1)"
  decode_state_value "$raw_value"
}

agentstudio_pids_for_binary() {
  local binary_path="${1:?missing binary path}"
  local executable_path
  local pids
  executable_path="$(/usr/bin/python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$binary_path")"
  pids="$("$PGREP_BIN" -x AgentStudio 2>/dev/null || true)"
  [ -n "$pids" ] || return 0

  printf '%s\n' "$pids" |
    while IFS= read -r pid; do
      local txt_output
      local txt_path
      if ! txt_output="$("$LSOF_BIN" -a -p "$pid" -d txt -Fn 2>/dev/null)"; then
        echo "unable to inspect running AgentStudio PID $pid with $LSOF_BIN" >&2
        return 2
      fi
      txt_path="$(awk '/^n/ { print substr($0, 2); exit }' <<<"$txt_output")"
      if [ -z "$txt_path" ]; then
        echo "unable to resolve executable for running AgentStudio PID $pid" >&2
        return 2
      fi
      if [ "$(realpath_value "$txt_path")" = "$executable_path" ]; then
        printf '%s\n' "$pid"
      fi
    done
}

realpath_value() {
  /usr/bin/python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]) if sys.argv[1] else "")' "$1"
}

process_executable_path() {
  local pid="${1:?missing pid}"
  local txt_output
  if ! txt_output="$("$LSOF_BIN" -a -p "$pid" -d txt -Fn 2>/dev/null)"; then
    return 1
  fi
  awk '/^n/ { print substr($0, 2); exit }' <<<"$txt_output"
}

process_start_identity() {
  local pid="${1:?missing pid}"
  if [ "${AGENTSTUDIO_OBSERVABILITY_ALLOW_TEST_OVERRIDES:-0}" = "1" ]; then
    printf '%s\n' "${AGENTSTUDIO_OBSERVABILITY_TEST_PROCESS_START_IDENTITY:-test-process-start-$pid}"
    return 0
  fi
  /usr/bin/python3 - "$pid" <<'PY'
import ctypes
import sys

MAXCOMLEN = 16
PROC_PIDTBSDINFO = 3

class ProcBSDInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * MAXCOMLEN),
        ("pbi_name", ctypes.c_char * (2 * MAXCOMLEN)),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]

libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
libproc.proc_pidinfo.argtypes = [
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_uint64,
    ctypes.c_void_p,
    ctypes.c_int,
]
libproc.proc_pidinfo.restype = ctypes.c_int
info = ProcBSDInfo()
size = ctypes.sizeof(info)
result = libproc.proc_pidinfo(int(sys.argv[1]), PROC_PIDTBSDINFO, 0, ctypes.byref(info), size)
if result != size or info.pbi_pid != int(sys.argv[1]):
    sys.exit(1)
print(f"{info.pbi_start_tvsec}:{info.pbi_start_tvusec}")
PY
}

candidate_test_identity_value() {
  local key="${1:?missing candidate identity key}"
  /usr/bin/python3 - "$key" "${AGENTSTUDIO_OBSERVABILITY_TEST_CANDIDATE_IDENTITY:-}" <<'PY'
import json
import sys

key, raw = sys.argv[1:]
value = json.loads(raw).get(key)
if isinstance(value, bool):
    print("true" if value else "false")
elif value is not None:
    print(value)
PY
}

retire_debug_candidate() {
  local state_path="${1:?missing state path}"
  local expected_code="${2:?missing debug code}"
  local expected_artifact_root="${3:?missing debug artifact root}"
  local expected_data_root="${4:?missing data root}"
  local operation="${5:-retire}"
  [ -f "$state_path" ] || {
    echo "candidate retirement state is missing: $state_path" >&2
    return 1
  }

  local state_status state_runtime state_code state_marker state_pid state_start_identity
  local state_bundle_identifier state_app state_executable state_data_dir state_zmx_dir
  state_status="$(read_state_value AGENTSTUDIO_OBSERVABILITY_STATUS "$state_path")"
  state_runtime="$(read_state_value AGENTSTUDIO_OBSERVABILITY_RUNTIME_FLAVOR "$state_path")"
  state_code="$(read_state_value AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE "$state_path")"
  state_marker="$(read_state_value AGENTSTUDIO_OBSERVABILITY_MARKER "$state_path")"
  state_pid="$(read_state_value AGENTSTUDIO_OBSERVABILITY_PID "$state_path")"
  state_start_identity="$(read_state_value AGENTSTUDIO_OBSERVABILITY_PROCESS_START_IDENTITY "$state_path")"
  state_bundle_identifier="$(read_state_value AGENTSTUDIO_OBSERVABILITY_BUNDLE_IDENTIFIER "$state_path")"
  state_app="$(read_state_value AGENTSTUDIO_OBSERVABILITY_APP "$state_path")"
  state_executable="$(read_state_value AGENTSTUDIO_OBSERVABILITY_EXECUTABLE "$state_path")"
  state_data_dir="$(read_state_value AGENTSTUDIO_OBSERVABILITY_DATA_DIR "$state_path")"
  state_zmx_dir="$(read_state_value AGENTSTUDIO_OBSERVABILITY_ZMX_DIR "$state_path")"

  local expected_bundle_identifier="com.agentstudio.app.debug.d$expected_code"
  local expected_app="$expected_artifact_root/AgentStudio Debug $expected_code.app"
  local expected_executable="$expected_app/Contents/MacOS/AgentStudio"
  local expected_zmx_dir="$expected_data_root/z"
  case "$state_pid" in
    ''|*[!0-9]*)
      echo "candidate identity mismatch: invalid PID" >&2
      return 1
      ;;
  esac
  if [ "$state_status" != "running" ] || [ "$state_runtime" != "debug" ] ||
    [ "$state_code" != "$expected_code" ] || ! trace_name_is_safe_path_component "$state_marker" ||
    [ -z "$state_start_identity" ] || [ "$state_bundle_identifier" != "$expected_bundle_identifier" ] ||
    [ "$(realpath_value "$state_app")" != "$(realpath_value "$expected_app")" ] ||
    [ "$(realpath_value "$state_executable")" != "$(realpath_value "$expected_executable")" ] ||
    [ "$(realpath_value "$state_data_dir")" != "$(realpath_value "$expected_data_root")" ] ||
    [ "$(realpath_value "$state_zmx_dir")" != "$(realpath_value "$expected_zmx_dir")" ]
  then
    echo "candidate identity mismatch: state tuple" >&2
    return 1
  fi

  local actual_present actual_pid actual_runtime actual_code actual_marker actual_start_identity
  local actual_bundle_identifier actual_app actual_executable actual_data_dir actual_zmx_dir
  if [ -n "${AGENTSTUDIO_OBSERVABILITY_TEST_CANDIDATE_IDENTITY:-}" ]; then
    actual_present="$(candidate_test_identity_value present)"
    actual_pid="$(candidate_test_identity_value pid)"
    actual_runtime="$(candidate_test_identity_value runtime_flavor)"
    actual_code="$(candidate_test_identity_value debug_code)"
    actual_marker="$(candidate_test_identity_value marker)"
    actual_start_identity="$(candidate_test_identity_value process_start_identity)"
    actual_bundle_identifier="$(candidate_test_identity_value bundle_identifier)"
    actual_app="$(candidate_test_identity_value app)"
    actual_executable="$(candidate_test_identity_value executable)"
    actual_data_dir="$(candidate_test_identity_value data_dir)"
    actual_zmx_dir="$(candidate_test_identity_value zmx_dir)"
  else
    if ! kill -0 "$state_pid" >/dev/null 2>&1; then
      printf '%s\n' "candidate_retirement=absent"
      return 0
    fi
    actual_present=true
    actual_pid="$state_pid"
    actual_runtime=debug
    actual_code="$expected_code"
    actual_marker="$state_marker"
    actual_start_identity="$(process_start_identity "$state_pid" || true)"
    actual_executable="$(process_executable_path "$state_pid" || true)"
    actual_app="$(bundle_path_for_executable "$actual_executable")"
    actual_bundle_identifier="$(bundle_identifier_for_executable "$actual_executable")"
    actual_data_dir="$expected_data_root"
    actual_zmx_dir="$expected_zmx_dir"
  fi

  if [ "$actual_present" = "false" ]; then
    if [ "$operation" = "validate" ]; then
      echo "candidate identity mismatch: candidate is absent" >&2
      return 1
    fi
    printf '%s\n' "candidate_retirement=absent"
    return 0
  fi
  if [ "$actual_pid" != "$state_pid" ] || [ "$actual_runtime" != "$state_runtime" ] ||
    [ "$actual_code" != "$state_code" ] || [ "$actual_marker" != "$state_marker" ] ||
    [ "$actual_start_identity" != "$state_start_identity" ] ||
    [ "$actual_bundle_identifier" != "$state_bundle_identifier" ] ||
    [ "$(realpath_value "$actual_app")" != "$(realpath_value "$state_app")" ] ||
    [ "$(realpath_value "$actual_executable")" != "$(realpath_value "$state_executable")" ] ||
    [ "$(realpath_value "$actual_data_dir")" != "$(realpath_value "$state_data_dir")" ] ||
    [ "$(realpath_value "$actual_zmx_dir")" != "$(realpath_value "$state_zmx_dir")" ]
  then
    echo "candidate identity mismatch: live tuple" >&2
    return 1
  fi
  if [ "$operation" = "validate" ]; then
    printf '%s\n' "candidate_validation=valid"
    return 0
  fi

  # Revalidate the non-reusable identity immediately before the sole normal
  # AppKit quit request. A POSIX signal would bypass application termination
  # drains and make the idle completion receipt impossible to prove.
  if [ -z "${AGENTSTUDIO_OBSERVABILITY_TEST_CANDIDATE_IDENTITY:-}" ] &&
    [ "$(process_start_identity "$state_pid" || true)" != "$state_start_identity" ]
  then
    echo "candidate identity mismatch: process start changed before graceful quit" >&2
    return 1
  fi
  # AppKit reports the canonical path; the state file stores what the launcher
  # was given. The surrounding tuple check already compares realpaths, so the
  # quit request must too or any artifact root reached through a symlink
  # (/tmp, /var) is unretirable.
  if ! request_normal_candidate_quit \
    "$state_pid" "$state_bundle_identifier" \
    "$(realpath_value "$state_app")" "$(realpath_value "$state_executable")"
  then
    echo "graceful quit request failed for exact candidate PID $state_pid" >&2
    return 1
  fi
  if [ -n "${AGENTSTUDIO_OBSERVABILITY_TEST_CANDIDATE_IDENTITY:-}" ]; then
    printf '%s\n' "candidate_retirement=graceful"
    return 0
  fi
  local observed_start_identity
  for _ in $(seq 1 400); do
    if ! kill -0 "$state_pid" >/dev/null 2>&1; then
      printf '%s\n' "candidate_retirement=graceful"
      return 0
    fi
    observed_start_identity="$(process_start_identity "$state_pid" || true)"
    if [ -n "$observed_start_identity" ] &&
      [ "$observed_start_identity" != "$state_start_identity" ]
    then
      echo "candidate identity mismatch: process start changed after graceful quit" >&2
      return 1
    fi
    sleep 0.05
  done
  echo "graceful candidate retirement timed out for exact candidate PID $state_pid" >&2
  return 1
}

bundle_path_for_executable() {
  local executable_path="${1:?missing executable path}"
  case "$executable_path" in
    *.app/Contents/MacOS/AgentStudio)
      printf '%s\n' "${executable_path%/Contents/MacOS/AgentStudio}"
      ;;
  esac
}

bundle_identifier_for_executable() {
  local executable_path="${1:?missing executable path}"
  local bundle_path
  bundle_path="$(bundle_path_for_executable "$executable_path")"
  [ -n "$bundle_path" ] || return 0
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle_path/Contents/Info.plist" 2>/dev/null || true
}

request_normal_candidate_quit() {
  local candidate_pid="${1:?missing candidate PID}"
  local expected_bundle_identifier="${2:?missing expected bundle identifier}"
  local expected_app="${3:?missing expected app path}"
  local expected_executable="${4:?missing expected executable path}"
  "$NORMAL_QUIT_BIN" -l JavaScript -e '
ObjC.import("AppKit");
function run(arguments) {
  const processIdentifier = Number(arguments[0]);
  const expectedBundleIdentifier = arguments[1];
  const expectedAppPath = arguments[2];
  const expectedExecutablePath = arguments[3];
  const candidate = $.NSRunningApplication.runningApplicationWithProcessIdentifier(processIdentifier);
  if (candidate.isNil()) {
    throw new Error("candidate is absent before graceful quit");
  }
  const bundleIdentifier = candidate.bundleIdentifier.isNil()
    ? "" : ObjC.unwrap(candidate.bundleIdentifier);
  const appPath = candidate.bundleURL.isNil()
    ? "" : ObjC.unwrap(candidate.bundleURL.path);
  const executablePath = candidate.executableURL.isNil()
    ? "" : ObjC.unwrap(candidate.executableURL.path);
  if (Number(candidate.processIdentifier) !== processIdentifier
      || bundleIdentifier !== expectedBundleIdentifier
      || appPath !== expectedAppPath
      || executablePath !== expectedExecutablePath) {
    throw new Error("candidate AppKit identity mismatch");
  }
  if (!candidate.terminate) {
    throw new Error("candidate rejected graceful quit");
  }
  return "graceful_quit_requested";
}' "$candidate_pid" "$expected_bundle_identifier" "$expected_app" "$expected_executable"
}

debug_signing_identity() {
  if [ -n "${AGENTSTUDIO_DEBUG_SIGNING_IDENTITY:-}" ]; then
    printf '%s\n' "$AGENTSTUDIO_DEBUG_SIGNING_IDENTITY"
    return 0
  fi
  if [ -n "${SIGNING_IDENTITY:-}" ]; then
    printf '%s\n' "$SIGNING_IDENTITY"
    return 0
  fi

  "$SECURITY_BIN" find-identity -v -p codesigning 2>/dev/null |
    awk -F'"' '/Developer ID Application/ { print $2; exit }'
}

codesign_debug_item() {
  local item_path="${1:?missing item path}"
  local signing_identity="${2:-}"
  local entitlements="${3:-}"

  if [ -n "$signing_identity" ]; then
    if [ -n "$entitlements" ]; then
      "$CODESIGN_BIN" --force --sign "$signing_identity" --options runtime \
        --entitlements "$entitlements" "$item_path" >/dev/null
    else
      "$CODESIGN_BIN" --force --sign "$signing_identity" --options runtime "$item_path" >/dev/null
    fi
    return
  fi

  if [ -n "$entitlements" ]; then
    "$CODESIGN_BIN" --force --sign - --entitlements "$entitlements" "$item_path" >/dev/null
  else
    "$CODESIGN_BIN" --force --sign - "$item_path" >/dev/null
  fi
}

app_pid_for_binary() {
  local binary_path="${1:?missing binary path}"
  agentstudio_pids_for_binary "$binary_path" | tail -1
}

running_debug_app_pids() {
  local code="${1:?missing debug code}"
  local expected_bundle_identifier="com.agentstudio.app.debug.d$code"
  local pids
  pids="$("$PGREP_BIN" -x AgentStudio 2>/dev/null || true)"
  [ -n "$pids" ] || return 0

  printf '%s\n' "$pids" |
    while IFS= read -r pid; do
      local txt_output
      if ! txt_output="$("$LSOF_BIN" -a -p "$pid" -d txt -Fn 2>/dev/null)"; then
        echo "unable to inspect running AgentStudio PID $pid with $LSOF_BIN" >&2
        return 2
      fi
      txt_path="$(awk '/^n/ { print substr($0, 2); exit }' <<<"$txt_output")"
      if [ -z "$txt_path" ]; then
        echo "unable to resolve executable for running AgentStudio PID $pid" >&2
        return 2
      fi
      if [ "$(bundle_identifier_for_executable "$txt_path")" = "$expected_bundle_identifier" ]; then
        printf '%s\n' "$pid"
      fi
    done
}

wait_for_app_pid() {
  local binary_path="${1:?missing binary path}"
  local attempts="${2:-${AGENTSTUDIO_PID_WAIT_ATTEMPTS:-200}}"
  local pid=""

  for _ in $(seq 1 "$attempts"); do
    pid="$(app_pid_for_binary "$binary_path" || true)"
    if [ -n "$pid" ]; then
      printf '%s\n' "$pid"
      return 0
    fi
    sleep 0.1
  done

  return 1
}

open_app() {
  local app_path="${1:?missing app path}"
  local launch_log="${2:?missing launch log}"
  local wait_flag="${3:-}"
  shift 3
  local open_args=("$@")

  for attempt in 1 2 3 4 5; do
    if "${clean_open_env[@]}" "$OPEN_BIN" ${wait_flag:+"$wait_flag"} -n "$app_path" \
      --stdout "$launch_log" \
      --stderr "$launch_log" \
      "${open_args[@]}"
    then
      return 0
    fi
    sleep "$attempt"
  done

  return 1
}

write_launch_failed_state() {
  local reason="${1:?missing launch failure reason}"
  {
    write_state_value AGENTSTUDIO_OBSERVABILITY_STATUS launch_failed
    write_state_value AGENTSTUDIO_OBSERVABILITY_RUNTIME_FLAVOR debug
    write_state_value AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE "${debug_code:-}"
    write_state_value AGENTSTUDIO_OBSERVABILITY_REASON "$reason"
    write_state_value AGENTSTUDIO_OBSERVABILITY_APP "${app_path:-}"
    write_state_value AGENTSTUDIO_OBSERVABILITY_DATA_DIR "${launch_data_root:-${debug_root:-}}"
    write_state_value AGENTSTUDIO_OBSERVABILITY_ZMX_DIR "${launch_zmx_dir:-${debug_zmx_dir:-}}"
    write_state_value AGENTSTUDIO_OBSERVABILITY_STARTUP_DIAGNOSTIC_ACTION "${startup_diagnostic_action:-}"
    write_state_value AGENTSTUDIO_OBSERVABILITY_STARTUP_WATCH_FOLDER "${startup_watch_folder:-}"
    write_state_value AGENTSTUDIO_OBSERVABILITY_ACTIVATION_MODE "${launch_activation_mode:-unknown}"
    write_state_value AGENTSTUDIO_OBSERVABILITY_IPC_AUTH_MODE "${ipc_auth_mode:-authenticated}"
    write_state_value AGENTSTUDIO_OBSERVABILITY_TCC_PROBE_REPEAT_COUNT "${tcc_probe_repeat_count:-}"
    write_state_value AGENTSTUDIO_OBSERVABILITY_TCC_PROBE_INTERVAL_SECONDS "${tcc_probe_interval_seconds:-}"
    write_state_value AGENTSTUDIO_OBSERVABILITY_LOG "${launch_log:-}"
    write_state_value AGENTSTUDIO_OBSERVABILITY_BUILD_PATH "${build_path:-}"
    if [ -n "${preferences_mode:-}" ]; then
      write_state_value AGENTSTUDIO_OBSERVABILITY_PREFERENCES_MODE "$preferences_mode"
    fi
  } >"$state_file"
}

write_running_state() {
  local launch_method="${1:?missing launch method}"
  local launched_pid="${2:?missing pid}"
  local process_start="${3:?missing process start identity}"
  local launched_executable="$app_binary_path"
  {
    write_state_value AGENTSTUDIO_OBSERVABILITY_STATUS running
    write_state_value AGENTSTUDIO_OBSERVABILITY_MARKER "$trace_name"
    write_state_value AGENTSTUDIO_OBSERVABILITY_PROOF_TOKEN "$trace_proof_token"
    write_state_value AGENTSTUDIO_OBSERVABILITY_RUNTIME_FLAVOR debug
    write_state_value AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE "$debug_code"
    write_state_value AGENTSTUDIO_OBSERVABILITY_LAUNCH_METHOD "$launch_method"
    write_state_value AGENTSTUDIO_OBSERVABILITY_QUERY_START "$query_start"
    write_state_value AGENTSTUDIO_OBSERVABILITY_PID "$launched_pid"
    write_state_value AGENTSTUDIO_OBSERVABILITY_PROCESS_START_IDENTITY "$process_start"
    write_state_value AGENTSTUDIO_OBSERVABILITY_BUNDLE_IDENTIFIER "com.agentstudio.app.debug.d$debug_code"
    write_state_value AGENTSTUDIO_OBSERVABILITY_APP "$app_path"
    write_state_value AGENTSTUDIO_OBSERVABILITY_EXECUTABLE "$launched_executable"
    write_state_value AGENTSTUDIO_OBSERVABILITY_DATA_DIR "$launch_data_root"
    write_state_value AGENTSTUDIO_OBSERVABILITY_ZMX_DIR "$launch_zmx_dir"
    write_state_value AGENTSTUDIO_OBSERVABILITY_STARTUP_DIAGNOSTIC_ACTION "$startup_diagnostic_action"
    write_state_value AGENTSTUDIO_OBSERVABILITY_STARTUP_WATCH_FOLDER "$startup_watch_folder"
    write_state_value AGENTSTUDIO_OBSERVABILITY_ACTIVATION_MODE "$launch_activation_mode"
    write_state_value AGENTSTUDIO_OBSERVABILITY_IPC_AUTH_MODE "$ipc_auth_mode"
    write_state_value AGENTSTUDIO_OBSERVABILITY_TCC_PROBE_REPEAT_COUNT "$tcc_probe_repeat_count"
    write_state_value AGENTSTUDIO_OBSERVABILITY_TCC_PROBE_INTERVAL_SECONDS "$tcc_probe_interval_seconds"
    write_state_value AGENTSTUDIO_OBSERVABILITY_LOG "$launch_log"
    write_state_value AGENTSTUDIO_OBSERVABILITY_BUILD_PATH "$build_path"
    if [ -n "$preferences_mode" ]; then
      write_state_value AGENTSTUDIO_OBSERVABILITY_PREFERENCES_MODE "$preferences_mode"
    fi
  } >"$state_file"
}

running_debug_state_pid() {
  local state_path="${1:?missing state path}"
  local expected_code="${2:?missing debug code}"
  [ -f "$state_path" ] || return 0

  local state_code
  local state_executable
  local state_launch_method
  local state_pid
  local state_status
  state_code="$(sed -n 's/^AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE=//p' "$state_path" | tail -1)"
  state_executable="$(decode_state_value "$(sed -n 's/^AGENTSTUDIO_OBSERVABILITY_EXECUTABLE=//p' "$state_path" | tail -1)")"
  state_launch_method="$(decode_state_value "$(sed -n 's/^AGENTSTUDIO_OBSERVABILITY_LAUNCH_METHOD=//p' "$state_path" | tail -1)")"
  state_pid="$(sed -n 's/^AGENTSTUDIO_OBSERVABILITY_PID=//p' "$state_path" | tail -1)"
  state_status="$(sed -n 's/^AGENTSTUDIO_OBSERVABILITY_STATUS=//p' "$state_path" | tail -1)"

  case "$state_pid" in
    ''|*[!0-9]*)
      return 0
      ;;
  esac

  if [ "$state_code" = "$expected_code" ] &&
    [ "$state_status" = "running" ] &&
    kill -0 "$state_pid" >/dev/null 2>&1
  then
    if [ "$state_launch_method" = "direct_executable" ] && [ -n "$state_executable" ]; then
      local expected_executable actual_executable
      expected_executable="$(realpath_value "$state_executable")"
      actual_executable="$(process_executable_path "$state_pid" || true)"
      actual_executable="$(realpath_value "$actual_executable")"
      if [ -n "$expected_executable" ] && [ "$actual_executable" = "$expected_executable" ]; then
        printf '%s\n' "$state_pid"
      fi
    elif running_debug_app_pids "$expected_code" | grep -qx "$state_pid"; then
      printf '%s\n' "$state_pid"
    fi
  fi
}

launch_direct_binary() {
  local executable_path="${1:?missing executable path}"
  "${direct_launch_env[@]}" "$executable_path" >>"$launch_log" 2>&1 &
  direct_launch_pid=$!

  if kill -0 "$direct_launch_pid" >/dev/null 2>&1; then
    return 0
  fi

  wait "$direct_launch_pid" >/dev/null 2>&1 || true
  return 1
}

start_debug_direct_fallback() {
  local launchservices_reason="${1:?missing LaunchServices failure reason}"

  if [ "${AGENTSTUDIO_DEBUG_DIRECT_FALLBACK:-1}" != "1" ]; then
    return 1
  fi

  echo "LaunchServices failed for debug app ($launchservices_reason); trying debug direct executable fallback." >&2
  if launch_direct_binary "$app_binary_path"; then
    pid="$direct_launch_pid"
    launch_method=direct_executable
    launch_activation_mode=unknown
    launched_with_direct=true
    return 0
  fi

  return 1
}

worktree_debug_code() {
  local canonical_root
  canonical_root="$(cd "$PROJECT_ROOT" && pwd -P)"
  /usr/bin/python3 - "$canonical_root" <<'PY'
import hashlib
import sys

alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
space = 36 ** 4
digest = hashlib.sha256(sys.argv[1].encode("utf-8")).digest()
value = int.from_bytes(digest[:4], "big") % space
chars = []
for _ in range(4):
    value, digit = divmod(value, 36)
    chars.append(alphabet[digit])
print("".join(reversed(chars)))
PY
}

copy_debug_bundle() {
  local source_binary="${1:?missing source binary}"
  local build_root="${2:?missing build root}"
  local code="${3:?missing debug code}"
  local artifact_root="${4:?missing artifact root}"
  local app_path="$artifact_root/AgentStudio Debug $code.app"
  local app_dir="$app_path/Contents"
  local plist_path="$app_dir/Info.plist"
  local entitlements="Sources/AgentStudio/Resources/AgentStudio.entitlements"
  local signing_identity
  local marketing_version="${APP_MARKETING_VERSION:-0.0.1-debug+$code}"
  local build_version="${APP_BUILD_VERSION:-$(git rev-list --count HEAD)}"

  mkdir -p "$app_dir/MacOS" "$app_dir/Resources" "$app_dir/Helpers"
  chmod 755 "$app_dir/Helpers"
  "$DITTO_BIN" "$source_binary" "$app_dir/MacOS/AgentStudio"

  if [ -f "vendor/zmx/zig-out/bin/zmx" ]; then
    "$DITTO_BIN" "vendor/zmx/zig-out/bin/zmx" "$app_dir/MacOS/zmx"
  fi

  # agentstudio CLI — bundled as Contents/Helpers/agentstudio because
  # Contents/MacOS/agentstudio collides with the app executable on
  # case-insensitive volumes. The pane environment advertises this exact path.
  local cli_source_binary="$build_root/debug/agentstudio-cli"
  if [ -f "$cli_source_binary" ]; then
    "$DITTO_BIN" "$cli_source_binary" "$app_dir/Helpers/agentstudio"
    chmod 755 "$app_dir/Helpers/agentstudio"
  fi

  "$DITTO_BIN" "Sources/AgentStudio/Resources/Info.plist" "$plist_path"
  set_plist_string "$plist_path" CFBundleShortVersionString "$marketing_version"
  set_plist_string "$plist_path" CFBundleVersion "$build_version"
  set_plist_string "$plist_path" AgentStudioReleaseChannel stable
  set_plist_string "$plist_path" CFBundleIdentifier "com.agentstudio.app.debug.d$code"
  set_plist_string "$plist_path" CFBundleName "AgentStudio Debug $code"
  set_plist_string "$plist_path" CFBundleDisplayName "Agent Studio Debug $code"
  /usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$plist_path" >/dev/null 2>&1 || true
  set_plist_string "$plist_path" UTExportedTypeDeclarations:0:UTTypeIdentifier "com.agentstudio.debug.d$code.tab"
  set_plist_string "$plist_path" UTExportedTypeDeclarations:1:UTTypeIdentifier "com.agentstudio.debug.d$code.newtab"
  set_plist_string "$plist_path" UTExportedTypeDeclarations:2:UTTypeIdentifier "com.agentstudio.debug.d$code.pane"

  "$DITTO_BIN" "Sources/AgentStudio/Resources/AppIcon.icns" "$app_dir/Resources/AppIcon.icns"
  [ -d "Sources/AgentStudio/Resources/terminfo" ] &&
    "$DITTO_BIN" "Sources/AgentStudio/Resources/terminfo" "$app_dir/Resources/terminfo"
  [ -d "Sources/AgentStudio/Resources/ghostty" ] &&
    "$DITTO_BIN" "Sources/AgentStudio/Resources/ghostty" "$app_dir/Resources/ghostty"
  # AgentPackage — provider hooks, installer resources and the model skill. The
  # installer resolves this tree from Contents/Helpers/agentstudio, so the path
  # Contents/Resources/AgentPackage is load-bearing.
  if [ -d "Sources/AgentStudio/Resources/AgentPackage" ]; then
    "$DITTO_BIN" "Sources/AgentStudio/Resources/AgentPackage" "$app_dir/Resources/AgentPackage"
    find "$app_dir/Resources/AgentPackage" -name '*.sh' -exec chmod 755 {} +
  fi

  local resource_bundle
  resource_bundle="$(find "$build_root" -path '*/debug/AgentStudio_AgentStudio.bundle' -type d | head -1)"
  [ -n "$resource_bundle" ] && "$DITTO_BIN" "$resource_bundle" "$app_dir/Resources/AgentStudio_AgentStudio.bundle"

  signing_identity="$(debug_signing_identity)"
  if [ -n "$signing_identity" ]; then
    echo "debug signing identity: $signing_identity" >&2
  else
    echo "debug signing identity: ad-hoc" >&2
  fi
  if [ -f "$app_dir/MacOS/zmx" ]; then
    codesign_debug_item "$app_dir/MacOS/zmx" "$signing_identity" "$entitlements"
  fi
  if [ -f "$app_dir/Helpers/agentstudio" ]; then
    codesign_debug_item "$app_dir/Helpers/agentstudio" "$signing_identity" "$entitlements"
  fi
  codesign_debug_item "$app_path" "$signing_identity" "$entitlements"
  "$CODESIGN_BIN" --verify --deep --strict "$app_path"

  printf '%s\n' "$app_path"
}

atomically_swap_paths() {
  local first_path="${1:?missing first path}"
  local second_path="${2:?missing second path}"

  /usr/bin/python3 - "$first_path" "$second_path" <<'PY'
import ctypes
import os
import sys

AT_FDCWD = -2
RENAME_SWAP = 0x00000002

libc = ctypes.CDLL(None, use_errno=True)
renameatx_np = libc.renameatx_np
renameatx_np.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
renameatx_np.restype = ctypes.c_int

result = renameatx_np(
    AT_FDCWD,
    os.fsencode(sys.argv[1]),
    AT_FDCWD,
    os.fsencode(sys.argv[2]),
    RENAME_SWAP,
)
if result != 0:
    error_number = ctypes.get_errno()
    raise OSError(error_number, os.strerror(error_number))
PY
}

publish_debug_bundle() (
  local source_binary="${1:?missing source binary}"
  local build_root="${2:?missing build root}"
  local code="${3:?missing debug code}"
  local published_root="${4:?missing published root}"
  local published_app="$published_root/AgentStudio Debug $code.app"
  local staging_root=""

  cleanup_publish_staging() {
    if [ -n "$staging_root" ] && [ -d "$staging_root" ]; then
      /bin/rm -rf "$staging_root"
    fi
  }
  trap cleanup_publish_staging EXIT

  mkdir -p "$published_root"
  staging_root="$(mktemp -d "$published_root/.staging.XXXXXX")"

  local staged_app
  staged_app="$(copy_debug_bundle "$source_binary" "$build_root" "$code" "$staging_root")"
  if [ -e "$published_app" ]; then
    atomically_swap_paths "$staged_app" "$published_app"
  else
    /bin/mv "$staged_app" "$published_app"
  fi

  printf '%s\n' "$published_app"
)

build_path="${AGENTSTUDIO_DEBUG_BUILD_PATH:-}"
skip_build=false
detach=false
print_identity=false
preflight_idle=false
retire_candidate=false
validate_candidate=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --build-path)
      build_path="${2:?missing value for --build-path}"
      shift 2
      ;;
    --skip-build)
      skip_build=true
      shift
      ;;
    --detach)
      detach=true
      shift
      ;;
    --print-identity)
      print_identity=true
      shift
      ;;
    --preflight-idle)
      preflight_idle=true
      shift
      ;;
    --retire-candidate)
      retire_candidate=true
      shift
      ;;
    --validate-candidate)
      validate_candidate=true
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

cd "$PROJECT_ROOT"

debug_code="$(worktree_debug_code)"
debug_root="$HOME/.agentstudio-db/$debug_code"
debug_artifact_root="${AGENTSTUDIO_DEBUG_ARTIFACT_DIR:-$debug_root/apps}"
launch_data_root="${AGENTSTUDIO_DEBUG_DATA_DIR:-$debug_root}"
debug_zmx_dir="$launch_data_root/z"
state_file="${AGENTSTUDIO_OBSERVABILITY_STATE_FILE:-$PROJECT_ROOT/tmp/debug-observability/latest-observability.env}"

if [ "$retire_candidate" = true ] && [ "$validate_candidate" = true ]; then
  echo "--validate-candidate and --retire-candidate are mutually exclusive" >&2
  exit 2
fi
if [ "$retire_candidate" = true ]; then
  retire_debug_candidate "$state_file" "$debug_code" "$debug_artifact_root" "$launch_data_root" retire
  exit $?
fi
if [ "$validate_candidate" = true ]; then
  retire_debug_candidate "$state_file" "$debug_code" "$debug_artifact_root" "$launch_data_root" validate
  exit $?
fi

if [ "$print_identity" = true ]; then
  write_state_value AGENTSTUDIO_OBSERVABILITY_RUNTIME_FLAVOR debug
  write_state_value AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE "$debug_code"
  write_state_value AGENTSTUDIO_OBSERVABILITY_DATA_DIR "$launch_data_root"
  write_state_value AGENTSTUDIO_OBSERVABILITY_ZMX_DIR "$debug_zmx_dir"
  write_state_value AGENTSTUDIO_OBSERVABILITY_BUNDLE_IDENTIFIER "com.agentstudio.app.debug.d$debug_code"
  write_state_value AGENTSTUDIO_OBSERVABILITY_APP_NAME "Agent Studio Debug $debug_code"
  exit 0
fi

if [ "$preflight_idle" = true ]; then
  if existing_state_pid="$(running_debug_state_pid "$state_file" "$debug_code")" &&
    [ -n "$existing_state_pid" ]
  then
    echo "Agent Studio Debug $debug_code is already running: PID(s) $existing_state_pid" >&2
    exit 1
  fi
  if ! existing_pids="$(running_debug_app_pids "$debug_code" | paste -sd ' ' -)"; then
    echo "Unable to verify whether Agent Studio Debug $debug_code is already running." >&2
    exit 1
  fi
  if [ -n "$existing_pids" ]; then
    echo "Agent Studio Debug $debug_code is already running: PID(s) $existing_pids" >&2
    exit 1
  fi
  exit 0
fi

bash "$PROJECT_ROOT/scripts/vendor-worktree.sh" verify

debug_launch_lock="$debug_root/.launch.lock"
mkdir -p "$debug_root" "$(dirname "$state_file")"
chmod 700 "$debug_root"
exec 9>"$debug_launch_lock"
if ! /usr/bin/lockf -s -t 0 9; then
  write_launch_failed_state debug_launch_in_progress
  echo "Another Agent Studio Debug $debug_code launch is already in progress." >&2
  echo "observability state: $state_file" >&2
  exit 1
fi

if [ -z "$build_path" ]; then
  # shellcheck disable=SC1091
  source "$PROJECT_ROOT/scripts/swift-build-slot.sh"
  source "$PROJECT_ROOT/scripts/swift-package-sandbox.sh"
  swift_build_slot_acquire build "run-debug-observability"
  trap swift_build_slot_release EXIT
  build_path="$SWIFT_BUILD_DIR"
fi
binary_path="$build_path/debug/AgentStudio"

if [ ! -x "$STACK_HELPER" ]; then
  mkdir -p "$(dirname "$state_file")"
  write_launch_failed_state observability_stack_helper_not_executable
  echo "observability stack helper not executable: $STACK_HELPER" >&2
  echo "observability state: $state_file" >&2
  exit 1
fi

preferences_mode="${AGENTSTUDIO_OBSERVABILITY_PREFERENCES_MODE:-}"
if [ -n "$preferences_mode" ] && [ "$preferences_mode" != "honor_preferences" ]; then
  mkdir -p "$(dirname "$state_file")"
  write_launch_failed_state invalid_preferences_mode
  echo "invalid AGENTSTUDIO_OBSERVABILITY_PREFERENCES_MODE: $preferences_mode" >&2
  echo "observability state: $state_file" >&2
  exit 1
fi

if ! "$CURL_BIN" --fail --silent --show-error --max-time 2 "$COLLECTOR_HEALTH_URL" >/dev/null; then
  mkdir -p "$(dirname "$state_file")"
  write_launch_failed_state otlp_collector_unhealthy
  echo "OTLP collector is not healthy at $COLLECTOR_HEALTH_URL" >&2
  echo "Run: mise run observability:up" >&2
  echo "observability state: $state_file" >&2
  exit 1
fi

if existing_state_pid="$(running_debug_state_pid "$state_file" "$debug_code")" &&
  [ -n "$existing_state_pid" ]
then
  mkdir -p "$(dirname "$state_file")"
  {
    write_state_value AGENTSTUDIO_OBSERVABILITY_STATUS already_running
    write_state_value AGENTSTUDIO_OBSERVABILITY_RUNTIME_FLAVOR debug
    write_state_value AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE "$debug_code"
    write_state_value AGENTSTUDIO_OBSERVABILITY_PID "$existing_state_pid"
    write_state_value AGENTSTUDIO_OBSERVABILITY_DATA_DIR "$debug_root"
    write_state_value AGENTSTUDIO_OBSERVABILITY_ZMX_DIR "$debug_zmx_dir"
    if [ -n "${preferences_mode:-}" ]; then
      write_state_value AGENTSTUDIO_OBSERVABILITY_PREFERENCES_MODE "$preferences_mode"
    fi
  } >"$state_file"
  echo "Agent Studio Debug $debug_code is already running: PID(s) $existing_state_pid" >&2
  echo "Quit that debug app before launching another observability run for this worktree." >&2
  echo "observability state: $state_file" >&2
  exit 1
fi
if [ -x "$binary_path" ]; then
  if ! existing_direct_pids="$(agentstudio_pids_for_binary "$binary_path" | paste -sd ' ' -)"; then
    mkdir -p "$(dirname "$state_file")"
    write_launch_failed_state duplicate_attribution_failed
    echo "Unable to verify whether direct AgentStudio Debug $debug_code is already running." >&2
    echo "Refusing to launch because duplicate debug apps would share data and zmx roots." >&2
    echo "observability state: $state_file" >&2
    exit 1
  fi
  if [ -n "$existing_direct_pids" ]; then
    mkdir -p "$(dirname "$state_file")"
    {
      write_state_value AGENTSTUDIO_OBSERVABILITY_STATUS already_running
      write_state_value AGENTSTUDIO_OBSERVABILITY_RUNTIME_FLAVOR debug
      write_state_value AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE "$debug_code"
      write_state_value AGENTSTUDIO_OBSERVABILITY_PID "$existing_direct_pids"
      write_state_value AGENTSTUDIO_OBSERVABILITY_EXECUTABLE "$binary_path"
      write_state_value AGENTSTUDIO_OBSERVABILITY_DATA_DIR "$debug_root"
      write_state_value AGENTSTUDIO_OBSERVABILITY_ZMX_DIR "$debug_zmx_dir"
      if [ -n "${preferences_mode:-}" ]; then
        write_state_value AGENTSTUDIO_OBSERVABILITY_PREFERENCES_MODE "$preferences_mode"
      fi
    } >"$state_file"
    echo "Agent Studio Debug $debug_code direct executable is already running: PID(s) $existing_direct_pids" >&2
    echo "Quit that debug app before launching another observability run for this worktree." >&2
    echo "observability state: $state_file" >&2
    exit 1
  fi
fi
if ! existing_pids="$(running_debug_app_pids "$debug_code" | paste -sd ' ' -)"; then
  mkdir -p "$(dirname "$state_file")"
  {
    write_state_value AGENTSTUDIO_OBSERVABILITY_STATUS launch_failed
    write_state_value AGENTSTUDIO_OBSERVABILITY_RUNTIME_FLAVOR debug
    write_state_value AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE "$debug_code"
    write_state_value AGENTSTUDIO_OBSERVABILITY_REASON duplicate_attribution_failed
    write_state_value AGENTSTUDIO_OBSERVABILITY_DATA_DIR "$debug_root"
    write_state_value AGENTSTUDIO_OBSERVABILITY_ZMX_DIR "$debug_zmx_dir"
    if [ -n "${preferences_mode:-}" ]; then
      write_state_value AGENTSTUDIO_OBSERVABILITY_PREFERENCES_MODE "$preferences_mode"
    fi
  } >"$state_file"
  echo "Unable to verify whether Agent Studio Debug $debug_code is already running." >&2
  echo "Refusing to launch because duplicate debug apps would share data and zmx roots." >&2
  echo "observability state: $state_file" >&2
  exit 1
fi
if [ -n "$existing_pids" ]; then
  mkdir -p "$(dirname "$state_file")"
  {
    write_state_value AGENTSTUDIO_OBSERVABILITY_STATUS already_running
    write_state_value AGENTSTUDIO_OBSERVABILITY_RUNTIME_FLAVOR debug
    write_state_value AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE "$debug_code"
    write_state_value AGENTSTUDIO_OBSERVABILITY_PID "$existing_pids"
    write_state_value AGENTSTUDIO_OBSERVABILITY_DATA_DIR "$debug_root"
    write_state_value AGENTSTUDIO_OBSERVABILITY_ZMX_DIR "$debug_zmx_dir"
    if [ -n "${preferences_mode:-}" ]; then
      write_state_value AGENTSTUDIO_OBSERVABILITY_PREFERENCES_MODE "$preferences_mode"
    fi
  } >"$state_file"
  echo "Agent Studio Debug $debug_code is already running: PID(s) $existing_pids" >&2
  echo "Quit that debug app before launching another observability run for this worktree." >&2
  echo "observability state: $state_file" >&2
  exit 1
fi

if [ "$skip_build" = false ]; then
  if ! mise run bridge-web-build; then
    mkdir -p "$(dirname "$state_file")"
    write_launch_failed_state bridge_web_build_failed
    echo "BridgeWeb packaged resource build failed" >&2
    echo "observability state: $state_file" >&2
    exit 1
  fi
  if ! swift build $(swift_package_sandbox_arguments) --build-path "$build_path"; then
    mkdir -p "$(dirname "$state_file")"
    write_launch_failed_state swift_build_failed
    echo "debug AgentStudio build failed" >&2
    echo "observability state: $state_file" >&2
    exit 1
  fi
fi

if [ ! -x "$binary_path" ]; then
  mkdir -p "$(dirname "$state_file")"
  write_launch_failed_state debug_executable_not_found
  echo "debug AgentStudio executable not found: $binary_path" >&2
  echo "observability state: $state_file" >&2
  exit 1
fi

startup_diagnostic_action="${AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION:-}"
if [ -n "${AGENTSTUDIO_TRACE_TAGS:-}" ]; then
  trace_tags="$AGENTSTUDIO_TRACE_TAGS"
elif [ "$startup_diagnostic_action" = "bridge-review-observability-smoke" ] ||
  [ "$startup_diagnostic_action" = "bridge-file-view-observability-smoke" ] ||
  [ "$startup_diagnostic_action" = "bridge-file-view-command-route-observability-smoke" ] ||
  [ "$startup_diagnostic_action" = "bridge-file-view-targeted-route-observability-smoke" ] ||
  [ "$startup_diagnostic_action" = "bridge-review-to-file-view-observability-smoke" ] ||
  [ "$startup_diagnostic_action" = "bridge-product-paint-correlation" ]; then
  trace_tags="app.startup,bridge.performance.*"
else
  trace_tags="*"
fi
trace_flush="${AGENTSTUDIO_TRACE_FLUSH:-immediate}"
trace_backend=otlp
trace_name="${AGENTSTUDIO_TRACE_NAME:-debug-observability-$debug_code-$(date +%s)-$$}"
trace_proof_token="$(uuidgen | tr '[:upper:]' '[:lower:]')"
startup_watch_folder="${AGENTSTUDIO_STARTUP_WATCH_FOLDER:-}"
ipc_auth_mode=authenticated
if [ -n "${AGENTSTUDIO_IPC_UNSAFE_NO_AUTH:-}" ]; then
  ipc_auth_mode=unsafe_no_auth
fi
launch_activation_mode=unknown
tcc_probe_repeat_count="${AGENTSTUDIO_TCC_UPGRADE_PROBE_REPEAT_COUNT:-}"
tcc_probe_interval_seconds="${AGENTSTUDIO_TCC_UPGRADE_PROBE_INTERVAL_SECONDS:-}"
if ! trace_name_is_safe_path_component "$trace_name"; then
  mkdir -p "$(dirname "$state_file")"
  write_launch_failed_state invalid_trace_name
  echo "invalid AGENTSTUDIO_TRACE_NAME; use only letters, numbers, dot, underscore, and hyphen" >&2
  echo "observability state: $state_file" >&2
  exit 1
fi

if [ -n "${AGENTSTUDIO_DEBUG_ARTIFACT_DIR:-}" ]; then
  app_path="$(copy_debug_bundle "$binary_path" "$build_path" "$debug_code" "$debug_artifact_root")"
else
  app_path="$(publish_debug_bundle "$binary_path" "$build_path" "$debug_code" "$debug_artifact_root")"
fi
app_binary_path="$app_path/Contents/MacOS/AgentStudio"

trace_dir="${AGENTSTUDIO_TRACE_DIR:-$debug_root/traces}"
if [ "$startup_diagnostic_action" = "cross-tab-move-geometry-smoke" ]; then
  launch_data_root="$debug_root/runs/$trace_name"
fi
launch_zmx_dir="$launch_data_root/z"
launch_ipc_socket_dir="${AGENTSTUDIO_IPC_SOCKET_DIR:-$debug_root/ipc-socket}"
launch_zmx_bin_dir="$launch_data_root/bin"
launch_zmx_path="$launch_zmx_bin_dir/zmx"
otlp_endpoint="$(/usr/bin/env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" "$STACK_HELPER" collector-url)"
otlp_protocol=http/protobuf

launch_log="${AGENTSTUDIO_OBSERVABILITY_LAUNCH_LOG:-$debug_root/logs/$trace_name.log}"
mkdir -p "$(dirname "$launch_log")" "$(dirname "$state_file")" "$trace_dir" "$debug_root" "$launch_data_root" "$launch_zmx_dir" "$launch_ipc_socket_dir" "$launch_zmx_bin_dir"
chmod 700 "$debug_root" "$launch_data_root" "$launch_zmx_dir" "$launch_ipc_socket_dir" "$launch_zmx_bin_dir"
if [ ! -x "$app_path/Contents/MacOS/zmx" ]; then
  write_launch_failed_state missing_debug_zmx_binary
  echo "debug app bundle missing executable zmx: $app_path/Contents/MacOS/zmx" >&2
  echo "observability state: $state_file" >&2
  exit 1
fi
"$DITTO_BIN" "$app_path/Contents/MacOS/zmx" "$launch_zmx_path"
chmod 700 "$launch_zmx_path"
: >"$launch_log"
query_start="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

echo "launching debug with OTLP collector: $otlp_endpoint"
echo "debug code: $debug_code"
echo "app: $app_path"
echo "data root: $launch_data_root"
echo "zmx dir: $launch_zmx_dir"
echo "marker: $trace_name"
if [ "$preferences_mode" = "honor_preferences" ]; then
  echo "preferences mode: honor_preferences"
fi

clean_open_env=(
  /usr/bin/env
  -i
  "HOME=$HOME"
  "USER=${USER:-$(id -un)}"
  "LOGNAME=${LOGNAME:-${USER:-$(id -un)}}"
  "SHELL=${SHELL:-/bin/zsh}"
  "TMPDIR=${TMPDIR:-/tmp}"
  "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
)

open_env_args=(
    --env "AGENTSTUDIO_DATA_DIR=$launch_data_root" \
    --env "AGENTSTUDIO_IPC_SOCKET_DIR=$launch_ipc_socket_dir" \
    --env "AGENTSTUDIO_ZMX_PATH=$launch_zmx_path" \
    --env "AGENTSTUDIO_GHOSTTY_DISABLE_DEFAULT_CONFIG=1" \
    --env "AGENTSTUDIO_GHOSTTY_DISABLE_VSYNC=1" \
    --env "AGENTSTUDIO_TRACE_NAME=$trace_name" \
    --env "AGENTSTUDIO_TRACE_PROOF_TOKEN=$trace_proof_token" \
    --env "AGENTSTUDIO_TRACE_DIR=$trace_dir"
)
if [ "$preferences_mode" = "honor_preferences" ]; then
  :
else
  open_env_args+=(
    --env "AGENTSTUDIO_TRACE_TAGS=$trace_tags" \
    --env "AGENTSTUDIO_TRACE_FLUSH=$trace_flush" \
    --env "AGENTSTUDIO_TRACE_BACKEND=$trace_backend" \
    --env "OTEL_EXPORTER_OTLP_ENDPOINT=$otlp_endpoint" \
    --env "OTEL_EXPORTER_OTLP_PROTOCOL=$otlp_protocol"
  )
fi
if [ -n "$startup_diagnostic_action" ]; then
  open_env_args+=(--env "AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION=$startup_diagnostic_action")
fi
if [ -n "$startup_watch_folder" ]; then
  open_env_args+=(--env "AGENTSTUDIO_STARTUP_WATCH_FOLDER=$startup_watch_folder")
fi
if [ -n "$tcc_probe_repeat_count" ]; then
  open_env_args+=(--env "AGENTSTUDIO_TCC_UPGRADE_PROBE_REPEAT_COUNT=$tcc_probe_repeat_count")
fi
if [ -n "$tcc_probe_interval_seconds" ]; then
  open_env_args+=(--env "AGENTSTUDIO_TCC_UPGRADE_PROBE_INTERVAL_SECONDS=$tcc_probe_interval_seconds")
fi
if [ -n "${AGENTSTUDIO_RESTORE_TRACE:-}" ]; then
  open_env_args+=(--env "AGENTSTUDIO_RESTORE_TRACE=$AGENTSTUDIO_RESTORE_TRACE")
fi
if [ -n "${AGENTSTUDIO_IPC_UNSAFE_NO_AUTH:-}" ]; then
  open_env_args+=(--env "AGENTSTUDIO_IPC_UNSAFE_NO_AUTH=$AGENTSTUDIO_IPC_UNSAFE_NO_AUTH")
fi
if [ -n "${AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW:-}" ]; then
  open_env_args+=(--env "AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW=$AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW")
fi

direct_launch_env=(
  /usr/bin/env
  -i
  "HOME=$HOME"
  "USER=${USER:-$(id -un)}"
  "LOGNAME=${LOGNAME:-${USER:-$(id -un)}}"
  "SHELL=${SHELL:-/bin/zsh}"
  "TMPDIR=${TMPDIR:-/tmp}"
  "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
  "AGENTSTUDIO_DATA_DIR=$launch_data_root"
  "AGENTSTUDIO_IPC_SOCKET_DIR=$launch_ipc_socket_dir"
  "AGENTSTUDIO_ZMX_PATH=$launch_zmx_path"
  "AGENTSTUDIO_GHOSTTY_DISABLE_DEFAULT_CONFIG=1"
  "AGENTSTUDIO_GHOSTTY_DISABLE_VSYNC=1"
  "AGENTSTUDIO_TRACE_NAME=$trace_name"
  "AGENTSTUDIO_TRACE_PROOF_TOKEN=$trace_proof_token"
  "AGENTSTUDIO_TRACE_DIR=$trace_dir"
)
if [ "$preferences_mode" = "honor_preferences" ]; then
  :
else
  direct_launch_env+=(
    "AGENTSTUDIO_TRACE_TAGS=$trace_tags"
    "AGENTSTUDIO_TRACE_FLUSH=$trace_flush"
    "AGENTSTUDIO_TRACE_BACKEND=$trace_backend"
    "OTEL_EXPORTER_OTLP_ENDPOINT=$otlp_endpoint"
    "OTEL_EXPORTER_OTLP_PROTOCOL=$otlp_protocol"
  )
fi
if [ -n "$startup_diagnostic_action" ]; then
  direct_launch_env+=("AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION=$startup_diagnostic_action")
fi
if [ -n "$startup_watch_folder" ]; then
  direct_launch_env+=("AGENTSTUDIO_STARTUP_WATCH_FOLDER=$startup_watch_folder")
fi
if [ -n "$tcc_probe_repeat_count" ]; then
  direct_launch_env+=("AGENTSTUDIO_TCC_UPGRADE_PROBE_REPEAT_COUNT=$tcc_probe_repeat_count")
fi
if [ -n "$tcc_probe_interval_seconds" ]; then
  direct_launch_env+=("AGENTSTUDIO_TCC_UPGRADE_PROBE_INTERVAL_SECONDS=$tcc_probe_interval_seconds")
fi
if [ -n "${AGENTSTUDIO_RESTORE_TRACE:-}" ]; then
  direct_launch_env+=("AGENTSTUDIO_RESTORE_TRACE=$AGENTSTUDIO_RESTORE_TRACE")
fi
if [ -n "${AGENTSTUDIO_IPC_UNSAFE_NO_AUTH:-}" ]; then
  direct_launch_env+=("AGENTSTUDIO_IPC_UNSAFE_NO_AUTH=$AGENTSTUDIO_IPC_UNSAFE_NO_AUTH")
fi
if [ -n "${AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW:-}" ]; then
  direct_launch_env+=("AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW=$AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW")
fi

launch_method=launchservices
launched_with_direct=false
direct_launch_pid=""
if [ "$detach" = true ]; then
  launch_activation_flag="-g"
  launch_activation_mode=background
  if [ "$DEBUG_LAUNCH_ACTIVATE" = "1" ]; then
    launch_activation_flag=""
    launch_activation_mode=foreground
  fi
  if ! open_app "$app_path" "$launch_log" "$launch_activation_flag" "${open_env_args[@]}"; then
    if ! start_debug_direct_fallback launchservices_open_failed; then
      write_launch_failed_state launchservices_open_failed
      echo "LaunchServices open failed for debug app; GUI observability proof was not started." >&2
      echo "Use an accepted app bundle or run beta proof against an installed notarized beta." >&2
      echo "observability state: $state_file" >&2
      exit 1
    fi
  fi
  if [ "$launched_with_direct" = false ] && ! pid="$(wait_for_app_pid "$app_binary_path")"; then
    write_launch_failed_state launchservices_pid_not_found
    echo "LaunchServices started but Agent Studio Debug PID was not found." >&2
    echo "Refusing direct fallback because LaunchServices already accepted the app launch." >&2
    echo "observability state: $state_file" >&2
    exit 1
  fi
else
  launch_activation_mode=foreground_wait
  open_app "$app_path" "$launch_log" "-W" "${open_env_args[@]}" &
  open_pid=$!
  if ! pid="$(wait_for_app_pid "$app_binary_path")"; then
    if kill -0 "$open_pid" >/dev/null 2>&1; then
      failure_reason=launchservices_pid_not_found
      kill "$open_pid" >/dev/null 2>&1 || true
      wait "$open_pid" >/dev/null 2>&1 || true
    elif wait "$open_pid" >/dev/null 2>&1; then
      failure_reason=launchservices_pid_not_found
    else
      failure_reason=launchservices_open_failed
    fi
    if [ "$failure_reason" = "launchservices_open_failed" ] &&
      start_debug_direct_fallback "$failure_reason"
    then
      :
    else
      write_launch_failed_state "$failure_reason"
      echo "LaunchServices started but Agent Studio Debug PID was not found." >&2
      if [ "$failure_reason" = "launchservices_pid_not_found" ]; then
        echo "Refusing direct fallback because LaunchServices already accepted the app launch." >&2
      fi
      echo "observability state: $state_file" >&2
      exit 1
    fi
  fi
fi

process_start_identity_value="$(process_start_identity "$pid" || true)"
if [ -z "$process_start_identity_value" ]; then
  write_launch_failed_state process_start_identity_unavailable
  echo "unable to capture kernel process-start identity for debug candidate PID $pid" >&2
  echo "candidate was left running because a safe retirement identity is unavailable" >&2
  exit 1
fi
write_running_state "$launch_method" "$pid" "$process_start_identity_value"

echo "pid: $pid"
echo "launch method: $launch_method"
echo "log: $launch_log"
echo "observability state: $state_file"

if [ "$detach" = false ]; then
  terminate_child() {
    kill "$pid" >/dev/null 2>&1 || true
    wait "$open_pid" >/dev/null 2>&1 || true
    exit 0
  }
  trap terminate_child INT TERM
  set +e
  if [ "$launched_with_direct" = true ]; then
    wait "$pid"
  else
    wait "$open_pid"
  fi
  child_status=$?
  set -e
  case "$child_status" in
    0|130|143)
      exit 0
      ;;
    *)
      exit "$child_status"
      ;;
  esac
fi
