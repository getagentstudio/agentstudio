#!/bin/bash
# J2: use the real pane CLI, then collect PID-bound AX and original frames.
set -euo pipefail
# Common driver is checked separately; this path is resolved at runtime.
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/debug-lifecycle.sh"

J2_ORACLE_COMMIT=""
J2_DECLARED_BUILD_COMMIT=""
row_build_matches() {
  [[ "$1" =~ ^[a-fA-F0-9]{40}$ ]] && [[ "$2" =~ ^[a-fA-F0-9]{40}$ ]] && [ "$1" = "$2" ]
}
row_require_build() {
  row_build_matches "${VERIFY_SOURCE_COMMIT:-}" "$J2_DECLARED_BUILD_COMMIT" ||
    { verify_fail "J2 declared build differs from the launch receipt"; return 1; }
}
row_target_evidence() {
  printf 'J2_ORACLE_COMMIT=%s\nJ2_DECLARED_BUILD_COMMIT=%s\nJ2_RECEIPT_DECLARED_BUILD_COMMIT=%s\n' \
    "$J2_ORACLE_COMMIT" "$J2_DECLARED_BUILD_COMMIT" "$1"
}

row_help() {
  cat <<'HELP'
Usage:
  panes-row.sh --help | --dry-run | --self-test
  panes-row.sh show DECLARED_BUILD_COMMIT ORACLE_COMMIT RUN_DIR WINDOW_UUID FRESH_UUIDV7
  panes-row.sh drive DECLARED_BUILD_COMMIT ORACLE_COMMIT RUN_DIR NEW_PANE_UUID working|monitoring|done|blocked|clear|stream FRESH_UUIDV7
  panes-row.sh capture DECLARED_BUILD_COMMIT ORACLE_COMMIT RUN_DIR PHASE
Use the documented typed titleChanged wait and actual state readback before capture.
Take both full commits from the Lead declaration; build must match the launch receipt.
This driver uses the legacy stateful-line CLI; incompatible builds need a declared stimulus.
Each capture saves declared build/oracle and receipt declaration in PHASE-target.env.
Capture saves AX before/after and ten frames. Compare exact chip labels before diffing.
Changed label: chip/text repaint-spanned; keep glyph verdict; three consecutive repaints: UNKNOWN.
HELP
}
row_json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}
row_self_test() {
  local failed_count=0
  local previous_oracle="$J2_ORACLE_COMMIT" previous_build="$J2_DECLARED_BUILD_COMMIT"
  J2_ORACLE_COMMIT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  J2_DECLARED_BUILD_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  if [ "$(row_json_escape '"quoted"')" != '\"quoted\"' ]; then failed_count=$((failed_count + 1)); fi
  if [ "$(row_json_escape $'one\ntwo')" != 'one\ntwo' ]; then failed_count=$((failed_count + 1)); fi
  if [ "$(row_json_escape '\033')" != '\\033' ]; then failed_count=$((failed_count + 1)); fi
  if ! row_build_matches "$J2_DECLARED_BUILD_COMMIT" "$J2_DECLARED_BUILD_COMMIT"; then failed_count=$((failed_count + 1)); fi
  if row_build_matches "$J2_ORACLE_COMMIT" "$J2_DECLARED_BUILD_COMMIT"; then failed_count=$((failed_count + 1)); fi
  if row_build_matches short "$J2_DECLARED_BUILD_COMMIT"; then failed_count=$((failed_count + 1)); fi
  if [ "$(row_target_evidence "$J2_DECLARED_BUILD_COMMIT")" != $'J2_ORACLE_COMMIT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nJ2_DECLARED_BUILD_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nJ2_RECEIPT_DECLARED_BUILD_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ]; then failed_count=$((failed_count + 1)); fi
  J2_ORACLE_COMMIT="$previous_oracle"; J2_DECLARED_BUILD_COMMIT="$previous_build"
  printf '%s passed, %s failed; pure JSON escaping and separate J2 oracle/build evidence, no terminal input\n' "$((7 - failed_count))" "$failed_count"
  [ "$failed_count" -eq 0 ]
}
row_show() {
  local run_directory="$1" window_id="$2" correlation_id="$3" request
  verify_owned_live "$run_directory" || return
  row_require_build || return
  if ! verify_validate_uuid "$window_id" || ! verify_validate_correlation "$correlation_id"; then
    verify_fail "Need returned window UUID and fresh UUIDv7 correlation"; return 1
  fi
  printf -v request '{"commandId":"showPanesSidebar","arguments":{"kind":"workspaceWindow","workspaceWindowId":"%s"},"correlationId":"%s"}' "$window_id" "$correlation_id"
  verify_logged show-sidebar verify_debug_cli command.execute "$request"
}
row_drive() {
  local run_directory="$1" pane_id="$2" phase="$3" correlation_id="$4"
  local base_command shell_line encoded_input request
  verify_owned_live "$run_directory" || return
  row_require_build || return
  if ! verify_require_new_pane "$pane_id" || ! verify_validate_correlation "$correlation_id"; then
    verify_fail "Need this run's new pane and fresh UUIDv7 correlation"; return 1
  fi
  case "$phase" in
    working) base_command="\"\$AGENTSTUDIO_CLI\" line \"verify working\" --working" ;;
    monitoring) base_command="\"\$AGENTSTUDIO_CLI\" line \"verify monitoring\" --monitoring verification" ;;
    done) base_command="\"\$AGENTSTUDIO_CLI\" line \"verify done\" --done" ;;
    blocked) base_command="\"\$AGENTSTUDIO_CLI\" line \"verify blocked\" --blocked-on-you verification" ;;
    clear) base_command="\"\$AGENTSTUDIO_CLI\" line --clear" ;;
    stream) base_command="for i in \$(seq 1 45); do echo tick \$i; sleep 1; done" ;;
    *) verify_fail "Unknown phase"; return 2 ;;
  esac
  shell_line="$base_command && printf \"\\033]0;verify-$phase-$correlation_id\\007\""$'\n'
  encoded_input="$(row_json_escape "$shell_line")"
  printf -v request '{"handle":"%s","input":"%s","correlationId":"%s"}' "$pane_id" "$encoded_input" "$correlation_id"
  verify_logged "drive-$phase" verify_debug_cli terminal.send "$request" || return
  printf 'Input accepted only. Await/read the correlated title and actual row state; not a completion or motion verdict.\n'
}
row_capture() {
  local run_directory="$1" phase="$2" frame_index
  verify_owned_live "$run_directory" || return
  row_require_build || return
  [[ "$phase" =~ ^[a-zA-Z0-9_-]+$ ]] || { verify_fail "Unsafe phase name"; return 1; }
  [ ! -e "$VERIFY_RUN_DIR/$phase-ax-before.json" ] && [ ! -e "$VERIFY_RUN_DIR/$phase-target.env" ] ||
    { verify_fail "Phase evidence already exists; preserve it and use a new phase label"; return 1; }
  row_target_evidence "$VERIFY_SOURCE_COMMIT" > "$VERIFY_RUN_DIR/$phase-target.env"
  verify_logged "$phase-ax-before" peekaboo see --pid "$VERIFY_PID" --json-output --path "$VERIFY_RUN_DIR/$phase-ax-before.png" || return
  cat "$VERIFY_LAST_LOG.stdout" > "$VERIFY_RUN_DIR/$phase-ax-before.json"
  for frame_index in 0 1 2 3 4 5 6 7 8 9; do
    verify_owned_live "$run_directory" || return
    [ ! -e "$VERIFY_RUN_DIR/$phase-frame-$frame_index.png" ] || { verify_fail "Frame exists"; return 1; }
    verify_logged "$phase-frame-$frame_index" peekaboo see --pid "$VERIFY_PID" --no-elements --path "$VERIFY_RUN_DIR/$phase-frame-$frame_index.png" || return
    [ -s "$VERIFY_RUN_DIR/$phase-frame-$frame_index.png" ] ||
      { verify_fail "Capture returned without a nonempty frame"; return 1; }
  done
  verify_owned_live "$run_directory" || return
  verify_logged "$phase-ax-after" peekaboo see --pid "$VERIFY_PID" --json-output --path "$VERIFY_RUN_DIR/$phase-ax-after.png" || return
  cat "$VERIFY_LAST_LOG.stdout" > "$VERIFY_RUN_DIR/$phase-ax-after.json"
  printf 'Collected original frames/AX. Read the same chip label before/after: stable permits whole-chip zero-change checks; repaint defers chip/text only. Glyph is judged on every burst.\n'
}
row_main() {
  local action="${1:---help}"
  case "$action" in
    --help) row_help; return ;;
    --self-test) row_self_test; return ;;
    --dry-run) row_help; printf 'Plan only: validate owned app/new pane -> real CLI stimulus -> typed completion + state -> PID AX/frames -> region diff + visual judgment.\n'; return ;;
  esac
  verify_require_root || return
  shift
  [ "$#" -ge 2 ] || { row_help; return 2; }
  J2_DECLARED_BUILD_COMMIT="$1"; J2_ORACLE_COMMIT="$2"; shift 2
  row_build_matches "$J2_DECLARED_BUILD_COMMIT" "$J2_DECLARED_BUILD_COMMIT" &&
    row_build_matches "$J2_ORACLE_COMMIT" "$J2_ORACLE_COMMIT" ||
    { verify_fail "Need full declared build and separate oracle commits"; return 2; }
  case "$action" in
    show) [ "$#" -eq 3 ] && row_show "$@" ;;
    drive) [ "$#" -eq 4 ] && row_drive "$@" ;;
    capture) [ "$#" -eq 2 ] && row_capture "$@" ;;
    *) row_help; return 2 ;;
  esac
}
row_main "$@"
