#!/bin/bash
# J1: isolated debug launch, authenticated readback, and owned retirement.
# Source: scripts/run-debug-observability.sh and references/debug-launch.md.
set -euo pipefail

VERIFY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
VERIFY_SKILL_DIR="$(cd "$VERIFY_SCRIPT_DIR/.." && pwd -P)"
VERIFY_PROJECT_ROOT="$(cd "$VERIFY_SKILL_DIR/../../.." && pwd -P)"
VERIFY_STATE_FILE="$VERIFY_PROJECT_ROOT/tmp/debug-observability/latest-observability.env"

verify_fail() { printf '%s\n' "$*" >&2; return 1; }
verify_scrub_agent_environment() {
  local variable_name
  for variable_name in $(compgen -v AGENTSTUDIO_); do unset "$variable_name"; done
}
verify_export_debug_escrow() {
  export AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW="$VERIFY_RUN_DIR/ipc-escrow.json"
}
verify_require_root() {
  [ "$(pwd -P)" = "$VERIFY_PROJECT_ROOT" ] ||
    verify_fail "Run from repository root: $VERIFY_PROJECT_ROOT"
}
verify_validate_code() { [[ "$1" =~ ^[a-z0-9]{4}$ ]]; }
verify_validate_uuid() {
  [[ "$1" =~ ^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$ ]]
}
verify_validate_correlation() {
  [[ "$1" =~ ^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-7[a-fA-F0-9]{3}-[89aAbB][a-fA-F0-9]{3}-[a-fA-F0-9]{12}$ ]]
}
verify_run_directory() {
  local supplied_path="$1" relative_path component walked_path
  case "$supplied_path" in
    "$VERIFY_PROJECT_ROOT"/tmp/verify-agentstudio/*) VERIFY_RUN_DIR="$supplied_path" ;;
    tmp/verify-agentstudio/*) VERIFY_RUN_DIR="$VERIFY_PROJECT_ROOT/$supplied_path" ;;
    *) verify_fail "Runtime evidence must be below repository tmp/verify-agentstudio/ with a run write grant"; return 1 ;;
  esac
  relative_path="${VERIFY_RUN_DIR#"$VERIFY_PROJECT_ROOT/"}"
  walked_path="$VERIFY_PROJECT_ROOT"
  while [ -n "$relative_path" ]; do
    component="${relative_path%%/*}"
    if [ "$relative_path" = "$component" ]; then relative_path=""; else relative_path="${relative_path#*/}"; fi
    case "$component" in ""|"."|"..") verify_fail "Unsafe evidence component"; return 1 ;; esac
    walked_path="$walked_path/$component"
    [ ! -L "$walked_path" ] || { verify_fail "Symlink in evidence path: $walked_path"; return 1; }
  done
}
verify_logged() {
  local label="$1" sequence=1 operation_status=0
  shift
  while [ -e "$VERIFY_RUN_DIR/$label.$sequence.command" ]; do sequence=$((sequence + 1)); done
  VERIFY_LAST_LOG="$VERIFY_RUN_DIR/$label.$sequence"
  printf '%q ' "$@" > "$VERIFY_LAST_LOG.command"
  printf '\n' >> "$VERIFY_LAST_LOG.command"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$VERIFY_LAST_LOG.started"
  "$@" > "$VERIFY_LAST_LOG.stdout" 2> "$VERIFY_LAST_LOG.stderr" || operation_status=$?
  date -u +%Y-%m-%dT%H:%M:%SZ > "$VERIFY_LAST_LOG.ended"
  printf '%s\n' "$operation_status" > "$VERIFY_LAST_LOG.rc"
  cat "$VERIFY_LAST_LOG.stdout"
  cat "$VERIFY_LAST_LOG.stderr" >&2
  return "$operation_status"
}
verify_inspection_available() {
  local inspection_output inspection_status=0
  inspection_output="$(ps -p "$$" -o pid= 2>&1)" || inspection_status=$?
  if [ "$inspection_status" -ne 0 ]; then
    printf '%s\n' "$inspection_output" >&2
    return "$inspection_status"
  fi
  read -r inspection_output <<< "$inspection_output"
  [ "$inspection_output" = "$$" ] || verify_fail "ps did not return this shell; inspection unavailable"
}
verify_preflight() {
  local debug_code="$1" build_path="$2" candidate_pids candidate_pid candidate_path
  local inventory_status=0
  verify_validate_code "$debug_code" || { verify_fail "Invalid debug code"; return 1; }
  verify_inspection_available || return
  # One inventory only. Status 1 is absence only with empty combined output
  # and a successful independent ps observation. Status 0 without IDs is invalid.
  candidate_pids="$(pgrep -x AgentStudio 2>&1)" || inventory_status=$?
  if [ "$inventory_status" -eq 1 ] && [ -z "$candidate_pids" ]; then
    printf 'Process inventory succeeded; no AgentStudio PID returned.\n'
    return 0
  fi
  if [ "$inventory_status" -ne 0 ] || [ -z "$candidate_pids" ]; then
    printf '%s\n' "$candidate_pids" >&2
    [ "$inventory_status" -ne 0 ] || inventory_status=1
    return "$inventory_status"
  fi
  for candidate_pid in $candidate_pids; do
    [[ "$candidate_pid" =~ ^[0-9]+$ ]] ||
      { printf '%s\n' "$candidate_pids" >&2; verify_fail "Inventory contains non-PID output"; return 1; }
    candidate_path="$(ps -p "$candidate_pid" -ww -o comm=)" || return
    read -r candidate_path <<< "$candidate_path"
    case "$candidate_path" in
      "$HOME/.agentstudio-db/$debug_code/apps/AgentStudio Debug $debug_code.app/Contents/MacOS/AgentStudio"|"$build_path/debug/AgentStudio")
        verify_fail "Existing debug target PID $candidate_pid; leave it alone"; return 1 ;;
    esac
  done
}
verify_read_handoff() {
  [ -f "$VERIFY_STATE_FILE" ] && [ ! -L "$VERIFY_STATE_FILE" ] ||
    { verify_fail "Missing or symlinked launch state"; return 1; }
  verify_scrub_agent_environment
  # Source only the fixed owner-local launcher-generated handoff, never a
  # caller-supplied shell path.
  # shellcheck disable=SC1090
  source "$VERIFY_STATE_FILE"
  STATE_STATUS="${AGENTSTUDIO_OBSERVABILITY_STATUS:-}"
  STATE_FLAVOR="${AGENTSTUDIO_OBSERVABILITY_RUNTIME_FLAVOR:-}"
  STATE_CODE="${AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE:-}"
  STATE_PID="${AGENTSTUDIO_OBSERVABILITY_PID:-}"
  STATE_KERNEL_START="${AGENTSTUDIO_OBSERVABILITY_PROCESS_START_IDENTITY:-}"
  STATE_MARKER="${AGENTSTUDIO_OBSERVABILITY_MARKER:-}"
  STATE_BUNDLE="${AGENTSTUDIO_OBSERVABILITY_BUNDLE_IDENTIFIER:-}"
  STATE_APP="${AGENTSTUDIO_OBSERVABILITY_APP:-}"
  STATE_EXECUTABLE="${AGENTSTUDIO_OBSERVABILITY_EXECUTABLE:-}"
  STATE_DATA="${AGENTSTUDIO_OBSERVABILITY_DATA_DIR:-}"
  STATE_ZMX="${AGENTSTUDIO_OBSERVABILITY_ZMX_DIR:-}"
  STATE_BUILD="${AGENTSTUDIO_OBSERVABILITY_BUILD_PATH:-}"
  STATE_ACTIVATION="${AGENTSTUDIO_OBSERVABILITY_ACTIVATION_MODE:-}"
  verify_scrub_agent_environment
}
verify_validate_handoff() {
  [ "$STATE_STATUS" = running ] && [ "$STATE_FLAVOR" = debug ] &&
    verify_validate_code "$STATE_CODE" && [[ "$STATE_PID" =~ ^[0-9]+$ ]] &&
    [ -n "$STATE_KERNEL_START" ] && [ -n "$STATE_MARKER" ] &&
    [ "$STATE_BUNDLE" = "com.agentstudio.app.debug" ] &&
    [ "$STATE_APP" = "$HOME/.agentstudio-db/$STATE_CODE/apps/AgentStudio Debug $STATE_CODE.app" ] &&
    [ "$STATE_EXECUTABLE" = "$STATE_APP/Contents/MacOS/AgentStudio" ] &&
    [ "$STATE_DATA" = "$HOME/.agentstudio-db/$STATE_CODE" ] &&
    [ "$STATE_ZMX" = "$STATE_DATA/z" ] ||
    { verify_fail "Handoff is incomplete or not the expected isolated debug identity"; return 1; }
  [ "$(cd "$STATE_DATA" && pwd -P)" = "$STATE_DATA" ] &&
    [ "$(cd "$STATE_ZMX" && pwd -P)" = "$STATE_ZMX" ] ||
    verify_fail "Debug root or zmx root resolves elsewhere"
}
verify_load_context() {
  verify_run_directory "$1" || return
  [ -f "$VERIFY_RUN_DIR/owner.env" ] && [ ! -L "$VERIFY_RUN_DIR/owner.env" ] ||
    { verify_fail "No ownership receipt from this driver's successful launch"; return 1; }
  # shellcheck source=/dev/null
  source "$VERIFY_RUN_DIR/owner.env"
  verify_read_handoff || return
  verify_validate_handoff || return
  [ "$VERIFY_PID" = "$STATE_PID" ] && [ "$VERIFY_MARKER" = "$STATE_MARKER" ] &&
    [ "$VERIFY_CODE" = "$STATE_CODE" ] && [ "$VERIFY_EXECUTABLE" = "$STATE_EXECUTABLE" ] &&
    [ "$VERIFY_KERNEL_START" = "$STATE_KERNEL_START" ] && [ "$VERIFY_BUILD_PATH" = "$STATE_BUILD" ] &&
    [ "$VERIFY_ZMX_DIR" = "$STATE_ZMX" ] && [ "$VERIFY_DATA_ROOT" = "$STATE_DATA" ] ||
    verify_fail "Current launch state changed; do not operate the old or replacement instance"
}
verify_owned_live() {
  local observed_executable observed_start
  verify_load_context "$1" || return
  [ ! -e "$VERIFY_RUN_DIR/quit-confirmed" ] ||
    { verify_fail "This owned app was already retired"; return 1; }
  verify_inspection_available || return
  verify_logged identity /bin/bash "$VERIFY_PROJECT_ROOT/scripts/run-debug-observability.sh" --validate-candidate || return
  observed_executable="$(ps -p "$VERIFY_PID" -ww -o comm=)" || return
  read -r observed_executable <<< "$observed_executable"
  observed_start="$(LC_ALL=C ps -p "$VERIFY_PID" -o lstart=)" || return
  [ "$observed_executable" = "$VERIFY_EXECUTABLE" ] && [ -n "$observed_start" ] &&
    [ "$observed_start" = "$VERIFY_PROCESS_START" ] ||
    verify_fail "Owned process path/start no longer matches; leave it alone"
}
verify_debug_cli() {
  local method_name="$1" json_payload="${2:-}" cli_path
  cli_path="$VERIFY_DATA_ROOT/apps/AgentStudio Debug $VERIFY_CODE.app/Contents/Helpers/agentstudio"
  [ -x "$cli_path" ] || { verify_fail "Published debug CLI missing"; return 1; }
  (
    verify_scrub_agent_environment
    verify_export_debug_escrow
    if [ -n "$json_payload" ]; then verify_logged debug-cli "$cli_path" "$method_name" --json "$json_payload"; else verify_logged debug-cli "$cli_path" "$method_name"; fi
  )
}
verify_health() {
  verify_owned_live "$1" || return
  verify_logged pane-list verify_debug_cli pane.list || return
  if [ ! -e "$VERIFY_RUN_DIR/panes-baseline.json" ]; then
    cat "$VERIFY_LAST_LOG.stdout" > "$VERIFY_RUN_DIR/panes-baseline.json"
  fi
  verify_logged window-list verify_debug_cli window.list || return
  printf 'Readbacks collected. Inspect their JSON and terminal readiness; this is not a journey PASS.\n'
}
verify_launch() {
  local supplied_run="$1" supplied_build="$2" source_commit="$3" code="$4" watch_folder="$5"
  local variable_name process_start launch_status=0
  verify_run_directory "$supplied_run" || return
  verify_validate_code "$code" && [[ "$source_commit" =~ ^[a-fA-F0-9]{40}$ ]] ||
    { verify_fail "Need declared four-character code and full source commit"; return 1; }
  [ -d "$supplied_build" ] && [ -x "$supplied_build/debug/AgentStudio" ] && [ -d "$watch_folder" ] ||
    { verify_fail "Pinned build or declared watch fixture is missing; never build here"; return 1; }
  supplied_build="$(cd "$supplied_build" && pwd -P)"
  verify_preflight "$code" "$supplied_build" || return
  [ ! -e "$VERIFY_RUN_DIR" ] || { verify_fail "Use a new run directory to preserve earlier evidence"; return 1; }
  umask 077
  mkdir -p "$VERIFY_RUN_DIR"
  (
    verify_scrub_agent_environment
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.app/Contents/Developer}"
    export AGENTSTUDIO_STARTUP_WATCH_FOLDER="$watch_folder"
    verify_export_debug_escrow
    verify_logged launch mise run run-debug-observability -- --detach --skip-build --build-path "$supplied_build"
  ) || launch_status=$?
  [ "$launch_status" -eq 0 ] || { printf 'Launch failed (rc=%s); no stale receipt accepted.\n' "$launch_status" >&2; return "$launch_status"; }
  verify_read_handoff || return
  verify_validate_handoff || return
  [ "$STATE_CODE" = "$code" ] && [ "$STATE_BUILD" = "$supplied_build" ] ||
    { verify_fail "Launcher target differs from declaration; no mutation follows"; return 1; }
  process_start="$(LC_ALL=C ps -p "$STATE_PID" -o lstart=)" || return
  [ -n "$process_start" ] || { verify_fail "No independently observable process start"; return 1; }
  {
    for variable_name in PID KERNEL_START MARKER EXECUTABLE DATA ZMX BUILD CODE; do
      case "$variable_name" in
        DATA) printf 'VERIFY_DATA_ROOT=%q\n' "$STATE_DATA" ;;
        ZMX) printf 'VERIFY_ZMX_DIR=%q\n' "$STATE_ZMX" ;;
        BUILD) printf 'VERIFY_BUILD_PATH=%q\n' "$STATE_BUILD" ;;
        *) local state_variable="STATE_$variable_name"; printf 'VERIFY_%s=%q\n' "$variable_name" "${!state_variable}" ;;
      esac
    done
    printf 'VERIFY_PROCESS_START=%q\nVERIFY_SOURCE_COMMIT=%q\nVERIFY_WATCH_FOLDER=%q\n' "$process_start" "$source_commit" "$watch_folder"
  } > "$VERIFY_RUN_DIR/owner.env"
  verify_owned_live "$VERIFY_RUN_DIR" || return
  if [ "$STATE_ACTIVATION" != background ]; then
    verify_fail "Launch is not background; owned receipt retained for explicit cleanup"
    return 1
  fi
  verify_health "$VERIFY_RUN_DIR"
}
verify_confirm_quit() {
  local remaining_pid inspection_error inspection_status=0
  verify_load_context "$1" || return
  [ -e "$VERIFY_RUN_DIR/quit-requested" ] ||
    { verify_fail "No successful owned quit request"; return 1; }
  verify_inspection_available || return
  inspection_error="$(ps -p "$VERIFY_PID" -o pid= 2>&1 >/dev/null)" || inspection_status=$?
  if [ -n "$inspection_error" ] || [ "$inspection_status" -gt 1 ]; then
    printf '%s\n' "$inspection_error" >&2
    verify_fail "PID retirement unobservable; inspection failure is not absence"
    return 1
  fi
  if [ "$inspection_status" -eq 0 ]; then
    remaining_pid="$(ps -p "$VERIFY_PID" -o pid=)" || return
    verify_fail "Quit accepted; PID $remaining_pid still observed. No polling/retry/kill."
    return 1
  fi
  printf '%s\n' "$VERIFY_PID $VERIFY_MARKER" > "$VERIFY_RUN_DIR/quit-confirmed"
  printf 'Owned app PID %s retired; evidence retained at %s\n' "$VERIFY_PID" "$VERIFY_RUN_DIR"
}
verify_quit() {
  verify_owned_live "$1" || return
  verify_logged quit /bin/bash "$VERIFY_PROJECT_ROOT/scripts/run-debug-observability.sh" --retire-candidate || return
  printf '%s\n' "$VERIFY_PID $VERIFY_MARKER" > "$VERIFY_RUN_DIR/quit-requested"
  verify_confirm_quit "$VERIFY_RUN_DIR"
}
verify_require_new_pane() {
  local pane_id="$1" baseline
  verify_validate_uuid "$pane_id" || { verify_fail "Need returned pane UUID"; return 1; }
  [ -f "$VERIFY_RUN_DIR/panes-baseline.json" ] || { verify_fail "No initial pane inventory"; return 1; }
  baseline="$(< "$VERIFY_RUN_DIR/panes-baseline.json")"
  shopt -s nocasematch
  case "$baseline" in *"$pane_id"*) shopt -u nocasematch; verify_fail "Pane existed before this run; leave its process alone"; return 1 ;; esac
  shopt -u nocasematch
}
verify_lifecycle_help() {
  cat <<'HELP'
Usage (repository root; explicit live grant required):
  debug-lifecycle.sh --help | --dry-run | --self-test
  debug-lifecycle.sh preflight CODE BUILD_PATH
  debug-lifecycle.sh launch NEW_RUN_DIR BUILD_PATH FULL_COMMIT CODE WATCH_FOLDER
  debug-lifecycle.sh health RUN_DIR
  debug-lifecycle.sh cli RUN_DIR METHOD [JSON]
  debug-lifecycle.sh quit RUN_DIR
  debug-lifecycle.sh confirm-quit RUN_DIR
RUN_DIR must be below repository tmp/verify-agentstudio/ with an explicit run write grant.
No build, automatic retry, foreground activation, broad cleanup or default zmx.
--self-test uses controlled process/launcher/quit results and private scratch;
it never calls ps, pgrep, osascript, mise, the app or IPC.
HELP
}
verify_lifecycle_main() {
  local action="${1:---help}"
  case "$action" in
    --help) verify_lifecycle_help; return ;;
    --dry-run) verify_lifecycle_help; printf 'Plan only: inspect -> pinned skip-build background launch -> owned receipt -> CLI readbacks -> explicit owned quit.\n'; return ;;
    --self-test)
      source "$VERIFY_SCRIPT_DIR/debug-lifecycle-self-test.sh"
      verify_lifecycle_self_test
      return ;;
  esac
  verify_require_root || return
  shift
  case "$action" in
    preflight) [ "$#" -eq 2 ] && verify_preflight "$@" ;;
    launch) [ "$#" -eq 5 ] && verify_launch "$@" ;;
    health) [ "$#" -eq 1 ] && verify_health "$@" ;;
    cli) [ "$#" -ge 2 ] && [ "$#" -le 3 ] && verify_owned_live "$1" && verify_logged cli verify_debug_cli "$2" "${3:-}" ;;
    quit) [ "$#" -eq 1 ] && verify_quit "$@" ;;
    confirm-quit) [ "$#" -eq 1 ] && verify_confirm_quit "$@" ;;
    *) verify_lifecycle_help; return 2 ;;
  esac
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_lifecycle_main "$@"; fi
