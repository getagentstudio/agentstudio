#!/bin/bash
# One settled app render, resize, and recorded-file transfer recovery.
set -euo pipefail
FRAME_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

frame_help() {
  cat <<'HELP'
window-frame.sh --help | --self-test
window-frame.sh render RUN_DIR WINDOW_UUID NEW_LABEL [SESSION_PANE_UUID]
window-frame.sh resize RUN_DIR WINDOW_UUID WIDTH_PT HEIGHT_PT CORRELATION_UUIDV7 NEW_LABEL
window-frame.sh cleanup RUN_DIR

Run from the repository root after a declared debug lifecycle ownership receipt.
Every live action needs its own commission. render waits exactly 3 s, optionally
records session.query immediately before capture, then calls window.render ONCE.
resize calls window.resize once and returns the actual applied size; it does not
render. No launch, activation, permission change, state setter or render retry.

Evidence: RUN_DIR/window-frames/LABEL/{request,response,receipt}.json, raw clock
and lock probes, CLI stderr/status, and frame.png. receipt.sourcePath always
retains the original app path. Only a completed copy is published, then its
recorded source is removed. cleanup resumes recorded transfers, including after
owned app retirement; it does not call the app or scan its renders directory.
Exit 0 means collection/transfer, never UI PASS or a confirmed locked state.
HELP
}
frame_fail() { printf '%s\n' "$*" >&2; return 2; }
frame_clock() {
  /usr/bin/perl -MTime::HiRes=time,clock_gettime,CLOCK_MONOTONIC -e \
    'printf "{\"utc\":%.6f,\"monotonic\":%.6f}\n", time(), clock_gettime(CLOCK_MONOTONIC)'
}
frame_settle() { /bin/sleep 3; }
frame_copy() { /bin/cp -p "$1" "$2"; }
frame_lock_archive() { /usr/sbin/ioreg -n Root -d1 -a; }
frame_lock() {
  local prefix="$1" probe_status=0 state=UNKNOWN
  frame_lock_archive > "$prefix.plist" 2> "$prefix.stderr" || probe_status=$?
  if [ "$probe_status" -eq 0 ]; then
    if /usr/bin/plutil -extract IOConsoleUsers json -o "$prefix.users.json" "$prefix.plist" 2>> "$prefix.stderr"; then
      if ! state="$(jq -r '
        [.[] | .CGSSessionScreenIsLocked] as $values |
        if ($values | length) == 0 or any($values[]; type != "boolean") then "UNKNOWN"
        elif all($values[]; . == true) then "locked"
        elif all($values[]; . == false) then "unlocked" else "UNKNOWN" end
      ' "$prefix.users.json" 2>> "$prefix.stderr")"; then state=UNKNOWN; fi
    fi
  fi
  jq -n --arg state "$state" --argjson probeExit "$probe_status" '{state:$state,probeExit:$probeExit}' > "$prefix.json"
}
frame_cli() {
  verify_owned_live "$VERIFY_RUN_DIR" || return
  # Escrow discovery is owned by the existing lifecycle helper. No --socket,
  # bearer argv, inherited pane identity, or alternate authentication route.
  ( unset ZMX_DIR ZMX_SESSION ZMX_SESSION_PREFIX; verify_debug_cli "$1" "$2"; )
}
frame_new_operation() {
  local label="$1" method="$2"
  [[ "$label" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { frame_fail 'Invalid evidence label'; return 2; }
  [ ! -L "$VERIFY_RUN_DIR/window-frames" ] || { frame_fail 'Symlinked frame evidence'; return 2; }
  mkdir -p "$VERIFY_RUN_DIR/window-frames" || return
  FRAME_OPERATION="$VERIFY_RUN_DIR/window-frames/$label"
  mkdir "$FRAME_OPERATION" || { frame_fail 'Evidence label already exists; retain the earlier operation'; return 2; }
  printf '%s\n' "$method" > "$FRAME_OPERATION/method"
}
frame_request() {
  local method="$1" operation="$2" status=0
  frame_clock > "$operation/call-start.json" || return
  frame_cli "$method" "$(cat "$operation/request.json")" > "$operation/response.json" 2> "$operation/cli.stderr" || status=$?
  printf '%s\n' "$status" > "$operation/cli.rc" || return
  frame_clock > "$operation/call-end.json" || return
  return "$status"
}
frame_source_guard() {
  local source="$1" filename
  [ "$(dirname -- "$source")" = "$VERIFY_DATA_ROOT/renders" ] || { frame_fail 'Render source escapes the declared debug root'; return 2; }
  filename="$(basename -- "$source")"
  case "$filename" in *.png) ;; *) frame_fail 'Render source is not PNG'; return 2 ;; esac
  verify_validate_correlation "${filename%.png}" || { frame_fail 'Render filename is not UUIDv7'; return 2; }
  [ ! -L "$VERIFY_DATA_ROOT/renders" ] && [ ! -L "$source" ] || { frame_fail 'Symlinked render source'; return 2; }
}
frame_record_source() {
  local operation="$1" source
  source="$(jq -er '.image.path | select(type == "string" and length > 0)' "$operation/response.json")" || return
  jq -n --arg source "$source" --arg destination "$operation/frame.png" \
    --arg code "$VERIFY_CODE" --arg root "$VERIFY_DATA_ROOT" --arg pid "$VERIFY_PID" \
    --arg marker "$VERIFY_MARKER" --arg incarnation "$VERIFY_KERNEL_START" \
    '{stage:"received",sourcePath:$source,evidencePath:$destination,
      owner:{code:$code,dataRoot:$root,pid:$pid,marker:$marker,incarnation:$incarnation}}' \
    > "$operation/receipt.json.new" || return
  mv "$operation/receipt.json.new" "$operation/receipt.json"
}
frame_stage() {
  jq --arg stage "$2" '.stage=$stage' "$1/receipt.json" > "$1/receipt.json.new" || return
  mv "$1/receipt.json.new" "$1/receipt.json"
}
frame_transfer() {
  local operation="$1" source destination stage partial
  [ ! -L "$operation/receipt.json" ] || { frame_fail 'Symlinked transfer receipt'; return 2; }
  jq -e --arg code "$VERIFY_CODE" --arg root "$VERIFY_DATA_ROOT" --arg pid "$VERIFY_PID" \
    --arg marker "$VERIFY_MARKER" --arg incarnation "$VERIFY_KERNEL_START" \
    '.owner == {code:$code,dataRoot:$root,pid:$pid,marker:$marker,incarnation:$incarnation}' \
    "$operation/receipt.json" > /dev/null || { frame_fail 'Transfer owner changed'; return 2; }
  source="$(jq -er .sourcePath "$operation/receipt.json")"
  destination="$operation/frame.png"; partial="$operation/frame.partial.png"
  [ "$(jq -er .evidencePath "$operation/receipt.json")" = "$destination" ] || { frame_fail 'Evidence path changed'; return 2; }
  frame_source_guard "$source" || return
  [ ! -L "$destination" ] && [ ! -L "$partial" ] || { frame_fail 'Symlinked transfer destination'; return 2; }
  stage="$(jq -er .stage "$operation/receipt.json")"
  case "$stage" in received|publishing|published|moved) ;; *) frame_fail 'Unknown transfer stage'; return 2 ;; esac
  if [ "$stage" = received ]; then
    [ -f "$source" ] && [ -s "$source" ] && [ ! -e "$destination" ] || { frame_fail 'Missing source or destination collision; HOLD'; return 2; }
    # The exact partial path is ours; a failed copy leaves the source and receipt.
    frame_copy "$source" "$partial" || return
    cmp -s "$source" "$partial" || { frame_fail 'Incomplete render copy'; return 2; }
    frame_stage "$operation" publishing || return
    stage=publishing
  fi
  if [ "$stage" = publishing ]; then
    if [ -e "$destination" ]; then
      [ ! -e "$partial" ] && cmp -s "$source" "$destination" || { frame_fail 'Publication collision'; return 2; }
    else
      [ -f "$partial" ] && cmp -s "$source" "$partial" || { frame_fail 'Missing completed partial'; return 2; }
      mv "$partial" "$destination" || return
    fi
    frame_stage "$operation" published || return
    stage=published
  fi
  [ -f "$destination" ] && [ -s "$destination" ] || { frame_fail 'Published evidence missing; HOLD'; return 2; }
  if [ -e "$source" ]; then
    cmp -s "$source" "$destination" || { frame_fail 'Source differs from evidence; HOLD'; return 2; }
    rm -- "$source" || return
  fi
  frame_stage "$operation" moved || return
  cat "$operation/receipt.json"
}
frame_render() {
  local window="$1" label="$2" session_pane="${3:-}" operation render_status=0
  verify_validate_uuid "$window" || { frame_fail 'Need workspace window UUID'; return 2; }
  [ -z "$session_pane" ] || verify_validate_uuid "$session_pane" || return
  frame_new_operation "$label" window.render || return
  operation="$FRAME_OPERATION"
  jq -n --arg id "$window" '{workspaceWindowId:$id}' > "$operation/request.json" || return
  frame_clock > "$operation/settle-start.json" || return
  frame_settle || return
  frame_clock > "$operation/settle-end.json" || return
  frame_lock "$operation/lock-before" || return
  if [ -n "$session_pane" ]; then
    frame_clock > "$operation/session-query-start.json" || return
    frame_cli session.query "$(jq -nc --arg id "$session_pane" '{handle:$id}')" \
      > "$operation/session-query.json" 2> "$operation/session-query.stderr" || return
    frame_clock > "$operation/session-query-end.json" || return
  fi
  frame_request window.render "$operation" || render_status=$?
  frame_lock "$operation/lock-after" || return
  [ "$render_status" -eq 0 ] || return "$render_status"
  # Journal every received source path before validation/copy, retaining even
  # refused/malformed responses for the cleanup owner's diagnosis.
  frame_record_source "$operation" || return
  jq -e --arg id "$window" '
    (.workspaceWindowId | ascii_downcase) == ($id | ascii_downcase) and
    (.image.pixelWidth > 0) and (.image.pixelHeight > 0) and (.image.scale > 0) and
    (.surfaces | type == "array")' "$operation/response.json" > /dev/null || return
  frame_transfer "$operation"
}
frame_resize() {
  local window="$1" width="$2" height="$3" correlation="$4" label="$5" operation
  verify_validate_uuid "$window" && verify_validate_correlation "$correlation" || return
  frame_new_operation "$label" window.resize || return
  operation="$FRAME_OPERATION"
  jq -n --arg id "$window" --argjson width "$width" --argjson height "$height" --arg correlation "$correlation" \
    '{workspaceWindowId:$id,contentWidth:$width,contentHeight:$height,correlationId:$correlation}' > "$operation/request.json" || return
  jq -e '(.contentWidth | type == "number") and (.contentHeight | type == "number") and
    .contentWidth > 0 and .contentHeight > 0' "$operation/request.json" > /dev/null || return
  frame_request window.resize "$operation" || return
  jq -e --arg id "$window" --arg correlation "$correlation" '
    (.workspaceWindowId | ascii_downcase) == ($id | ascii_downcase) and
    (.correlationId | ascii_downcase) == ($correlation | ascii_downcase) and
    .contentSize.width > 0 and .contentSize.height > 0' "$operation/response.json" > /dev/null || return
  cat "$operation/response.json"
}
frame_cleanup_context() {
  verify_run_directory "$1" || return
  [ -f "$VERIFY_RUN_DIR/owner.env" ] && [ ! -L "$VERIFY_RUN_DIR/owner.env" ] || return 2
  # Fixed owner-local J1 receipt, also used by verify_load_context. Cleanup uses
  # its original identity, never a replacement app's current escrow/handoff.
  source "$VERIFY_RUN_DIR/owner.env" || return
  verify_validate_code "$VERIFY_CODE" && [[ "$VERIFY_PID" =~ ^[0-9]+$ ]] &&
    [ -n "$VERIFY_MARKER" ] && [ -n "$VERIFY_KERNEL_START" ] &&
    [ "$VERIFY_DATA_ROOT" = "$HOME/.agentstudio-db/$VERIFY_CODE" ] &&
    [ "$(cd "$VERIFY_DATA_ROOT" && pwd -P)" = "$VERIFY_DATA_ROOT" ] || return 2
}
frame_cleanup() {
  local operation status=0
  [ ! -L "$VERIFY_RUN_DIR/window-frames" ] || return 2
  for operation in "$VERIFY_RUN_DIR"/window-frames/*; do
    [ -e "$operation" ] || continue
    [ -d "$operation" ] && [ ! -L "$operation" ] || { status=2; continue; }
    [ -f "$operation/method" ] && [ ! -L "$operation/method" ] || {
      printf 'Unresolved operation method: %s\n' "$operation" >&2; status=2; continue;
    }
    [ "$(cat "$operation/method")" = window.render ] || continue
    if [ ! -e "$operation/receipt.json" ]; then
      frame_record_source "$operation" || { printf 'Unresolved render response: %s\n' "$operation" >&2; status=2; continue; }
    fi
    frame_transfer "$operation" || status=$?
  done
  return "$status"
}
window_frame_main() {
  local action="${1:---help}"
  [ "$action" != --help ] || { frame_help; return; }
  command -v jq > /dev/null || { frame_fail 'jq is required'; return 2; }
  source "$FRAME_SCRIPT_DIR/debug-lifecycle.sh"
  if [ "$action" = --self-test ]; then
    source "$FRAME_SCRIPT_DIR/window-frame-self-test.sh"
    window_frame_self_test
    return
  fi
  verify_require_root || return
  umask 077
  shift
  case "$action" in
    render)
      [ "$#" -eq 3 ] || [ "$#" -eq 4 ] || { frame_help >&2; return 2; }
      verify_owned_live "$1" || return; shift; frame_render "$@" ;;
    resize)
      [ "$#" -eq 6 ] || { frame_help >&2; return 2; }
      verify_owned_live "$1" || return; shift; frame_resize "$@" ;;
    cleanup)
      [ "$#" -eq 1 ] || { frame_help >&2; return 2; }
      frame_cleanup_context "$1" || return; frame_cleanup ;;
    *) frame_help >&2; return 2 ;;
  esac
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then window_frame_main "$@"; fi
