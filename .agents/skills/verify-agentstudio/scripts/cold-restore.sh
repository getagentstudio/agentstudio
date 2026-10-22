#!/bin/bash
# J3 needs a Lead-declared restore build and explicit one-session fault grant.
# NEVER invoke zmx without the launch-state-derived ZMX_DIR.
set -euo pipefail
# Common driver is checked separately; this path is resolved at runtime.
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/debug-lifecycle.sh"

restore_help() {
  cat <<'HELP'
Usage (declared build and explicit fault grant required):
  cold-restore.sh --help | --dry-run | --self-test
  cold-restore.sh select DECLARED_BUILD_COMMIT RUN_DIR NEW_PANE_UUID
  cold-restore.sh list DECLARED_BUILD_COMMIT RUN_DIR
  cold-restore.sh kill DECLARED_BUILD_COMMIT RUN_DIR
Live modes require an explicit run commission and VERIFY_RESTORE_RUN_AUTHORIZED=1.
The full commit must match the J1 launch receipt and the Lead's declaration.
select is a read-only DB mapping; list/kill require owned-app retirement.
kill targets one mapped newly created pane session found in a fresh same-root list.
Every zmx invocation uses ZMX_DIR from the owned launch state, never a default root.
HELP
}
restore_namespace_matches() {
  local namespace="$1" code="$2" data_root="$3"
  [ -n "$namespace" ] && verify_validate_code "$code" &&
    [ "$namespace" = "$HOME/.agentstudio-db/$code/z" ] &&
    [ "$data_root" = "$HOME/.agentstudio-db/$code" ]
}
restore_namespace_self_test() {
  local failed_count=0 expected_root="$HOME/.agentstudio-db/9t8c"
  if restore_namespace_matches "" 9t8c "$expected_root"; then failed_count=$((failed_count + 1)); fi
  if restore_namespace_matches "$HOME/.local/state/zmx" 9t8c "$expected_root"; then failed_count=$((failed_count + 1)); fi
  if restore_namespace_matches "$expected_root/z" 9t8c "$HOME/.agentstudio"; then failed_count=$((failed_count + 1)); fi
  if ! restore_namespace_matches "$expected_root/z" 9t8c "$expected_root"; then failed_count=$((failed_count + 1)); fi
  if ! restore_build_matches aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; then failed_count=$((failed_count + 1)); fi
  if restore_build_matches aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; then failed_count=$((failed_count + 1)); fi
  printf '%s passed, %s failed; namespace and declared-build guards, no zmx/process operation\n' "$((6 - failed_count))" "$failed_count"
  [ "$failed_count" -eq 0 ]
}
restore_build_matches() {
  [[ "$1" =~ ^[a-fA-F0-9]{40}$ ]] && [ "$1" = "$2" ]
}
restore_require_pin() {
  [ "${VERIFY_RESTORE_RUN_AUTHORIZED:-0}" = 1 ] ||
    { verify_fail "Missing Lead run authorization and declared restore build"; return 1; }
  verify_load_context "$1" || return
  restore_build_matches "$VERIFY_SOURCE_COMMIT" "${RESTORE_DECLARED_BUILD_COMMIT:-}" ||
    { verify_fail "Restore build differs from the launch receipt"; return 1; }
}
restore_select() {
  local run_directory="$1" pane_id="$2" stored_session query
  restore_require_pin "$run_directory" || return
  verify_owned_live "$run_directory" && verify_require_new_pane "$pane_id" || return
  [ ! -e "$VERIFY_RUN_DIR/selected-session.env" ] ||
    { verify_fail "Selection already exists; do not replace journey evidence"; return 1; }
  query="SELECT zmx_session_id FROM pane_content_terminal WHERE upper(pane_id)=upper('$pane_id');"
  verify_logged selected-pane sqlite3 -readonly "$VERIFY_DATA_ROOT/local.sqlite" "$query" || return
  stored_session="$(< "$VERIFY_LAST_LOG.stdout")"
  verify_validate_uuid "$stored_session" ||
    { verify_fail "Need one exact stored UUID session for the newly created pane; no derived/ambiguous id"; return 1; }
  {
    printf 'RESTORE_PANE_ID=%q\n' "$pane_id"
    printf 'RESTORE_SESSION_ID=%q\n' "$stored_session"
  } > "$VERIFY_RUN_DIR/selected-session.env"
}
restore_require_retired() {
  restore_require_pin "$1" || return
  [ -f "$VERIFY_RUN_DIR/selected-session.env" ] && [ ! -L "$VERIFY_RUN_DIR/selected-session.env" ] ||
    { verify_fail "No selected new-pane session"; return 1; }
  # shellcheck source=/dev/null
  source "$VERIFY_RUN_DIR/selected-session.env"
  verify_require_new_pane "$RESTORE_PANE_ID" && verify_validate_uuid "$RESTORE_SESSION_ID" || return
  [ -f "$VERIFY_RUN_DIR/quit-confirmed" ] ||
    { verify_fail "Owned-app retirement has not been observed"; return 1; }
  verify_confirm_quit "$1" || return
  # Verify again before EACH zmx invocation; binary location alone is not isolation.
  [ "$STATE_ZMX" = "$VERIFY_ZMX_DIR" ] &&
    restore_namespace_matches "$STATE_ZMX" "$VERIFY_CODE" "$VERIFY_DATA_ROOT" &&
    [ "$(cd "$VERIFY_ZMX_DIR" && pwd -P)" = "$VERIFY_ZMX_DIR" ] &&
    [ "$(cd "$VERIFY_DATA_ROOT/bin" && pwd -P)" = "$VERIFY_DATA_ROOT/bin" ] &&
    [ ! -L "$VERIFY_DATA_ROOT/bin/zmx" ] && [ -x "$VERIFY_DATA_ROOT/bin/zmx" ] ||
    { verify_fail "Missing/mismatched/escaped debug ZMX_DIR or debug zmx binary; no invocation"; return 1; }
}
restore_zmx_list() {
  local run_directory="$1"
  restore_require_retired "$run_directory" || return
  verify_logged zmx-list env ZMX_DIR="$STATE_ZMX" "$VERIFY_DATA_ROOT/bin/zmx" list
}
restore_inventory_has_session() {
  local line token parsed_name found_status=1
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    parsed_name=""
    # Same supported formats as ZmxBackend.extractSessionName: key/value or short.
    for token in $line; do
      case "$token" in
        session_name=*) parsed_name="${token#session_name=}"; break ;;
        name=*) parsed_name="${token#name=}"; break ;;
      esac
    done
    if [ -z "$parsed_name" ]; then
      read -r parsed_name _ <<< "$line"
      case "$parsed_name" in *=*) return 2 ;; esac
    fi
    [ -n "$parsed_name" ] || return 2
    if [ "$parsed_name" = "$RESTORE_SESSION_ID" ]; then found_status=0; fi
  done < "$1"
  return "$found_status"
}
restore_kill_one() {
  local run_directory="$1" inventory_status=0 pane_lower
  restore_require_retired "$run_directory" || return
  [ ! -e "$VERIFY_RUN_DIR/kill-attempted" ] ||
    { verify_fail "One kill was already attempted; reconcile its evidence instead of retrying"; return 1; }
  pane_lower="$(printf '%s' "$RESTORE_PANE_ID" | tr '[:upper:]' '[:lower:]')"
  [ -s "$VERIFY_DATA_ROOT/scrollback/$pane_lower.vt" ] ||
    { verify_fail "No nonempty snapshot for the selected pane; preserve the live session"; return 1; }
  restore_zmx_list "$run_directory" || return
  restore_inventory_has_session "$VERIFY_LAST_LOG.stdout" || inventory_status=$?
  [ "$inventory_status" -eq 0 ] ||
    { verify_fail "Selected session is absent or inventory is not parseable; no kill"; return 1; }
  restore_require_retired "$run_directory" || return
  printf '%s\n' "$RESTORE_SESSION_ID" > "$VERIFY_RUN_DIR/kill-attempted"
  verify_logged zmx-kill env ZMX_DIR="$STATE_ZMX" "$VERIFY_DATA_ROOT/bin/zmx" kill "$RESTORE_SESSION_ID" || return
  restore_zmx_list "$run_directory" || return
  inventory_status=0
  restore_inventory_has_session "$VERIFY_LAST_LOG.stdout" || inventory_status=$?
  [ "$inventory_status" -eq 1 ] ||
    { verify_fail "Session absence not established by successful parseable post-kill inventory"; return 1; }
  printf '%s\n' "$RESTORE_SESSION_ID" > "$VERIFY_RUN_DIR/session-absence-confirmed"
  printf 'One exact owned session absent in pinned debug namespace. Relaunch the SAME pinned build through J1; observe replay before claiming restore.\n'
}
restore_main() {
  local action="${1:---help}"
  case "$action" in
    --help) restore_help; return ;;
    --self-test) restore_namespace_self_test; return ;;
    --dry-run) restore_help; printf 'Plan only: pinned restore build -> new pane nonce -> stored session mapping -> owned quit/snapshot -> explicit debug-root list -> one listed session kill -> same-root absence -> same-build relaunch -> ordered visible replay/fresh input.\n'; return ;;
  esac
  verify_require_root || return
  shift
  [ "$#" -ge 1 ] || { restore_help; return 2; }
  RESTORE_DECLARED_BUILD_COMMIT="$1"; shift
  restore_build_matches "$RESTORE_DECLARED_BUILD_COMMIT" "$RESTORE_DECLARED_BUILD_COMMIT" ||
    { verify_fail "Need the full declared build commit"; return 2; }
  case "$action" in
    select) [ "$#" -eq 2 ] && restore_select "$@" ;;
    list) [ "$#" -eq 1 ] && restore_zmx_list "$@" ;;
    kill) [ "$#" -eq 1 ] && restore_kill_one "$@" ;;
    *) restore_help; return 2 ;;
  esac
}
restore_main "$@"
