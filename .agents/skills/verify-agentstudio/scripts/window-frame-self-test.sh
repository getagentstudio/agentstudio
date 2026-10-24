#!/bin/bash
# Deterministic wrapper tests. Invoked by window-frame.sh --self-test.
# The actual CLI subprocess is a private stub. No app, process inventory, lock
# probe, real escrow, wall-clock wait, launch, quit, or network operation runs.

window_frame_self_test() (
  set -euo pipefail
  umask 077
  fixture="$(mktemp -d "${TMPDIR:-/tmp}/window-frame-self-test.XXXXXX")"
  fixture="$(cd "$fixture" && pwd -P)"
  trap 'rm -rf -- "$fixture"' EXIT
  passed=0; failed=0
  fixture_window=018f0000-0000-7000-8000-000000000001
  fixture_pane=018f0000-0000-7000-8000-000000000002
  fixture_correlation=018f0000-0000-7000-8000-000000000003
  fixture_render=018f0000-0000-7000-8000-000000000004
  real_frame_copy="$(declare -f frame_copy)"
  real_frame_stage="$(declare -f frame_stage)"

  # Replace only external ownership inspection, time/lock inputs and deliberate
  # copy failure. verify_debug_cli (including escrow/environment routing), JSON
  # admission, journaling, publication and recovery remain the actual functions.
  verify_owned_live() {
    [ "${FRAME_TEST_GUARD:-ok}" = ok ] || return 72
    [ "$1" = "$VERIFY_RUN_DIR" ]
  }
  frame_clock() { printf '{"utc":100.000000,"monotonic":50.000000}\n'; }
  frame_settle() { printf 'settle\n' >> "$FRAME_TEST_CASE/events"; }
  frame_lock_archive() {
    case "$FRAME_TEST_LOCK" in
      denied) printf 'controlled lock-probe denial\n' >&2; return 76 ;;
      malformed) printf 'not a plist\n'; return ;;
    esac
    printf '<?xml version="1.0"?><plist version="1.0"><dict><key>IOConsoleUsers</key><array><dict><key>CGSSessionScreenIsLocked</key><%s/></dict></array></dict></plist>\n' "$FRAME_TEST_LOCK"
  }

  cat > "$fixture/cli-stub" <<'CLI'
#!/bin/bash
set -euo pipefail
for variable_name in AGENTSTUDIO_PANE_TOKEN AGENTSTUDIO_WORKSPACE_ID AGENTSTUDIO_IPC_SPOOL_DIR AGENTSTUDIO_PANE_ID AGENTSTUDIO_IPC_SOCKET AGENTSTUDIO_CLI ZMX_DIR ZMX_SESSION ZMX_SESSION_PREFIX; do
  [ -z "${!variable_name:-}" ] || { echo 'Inherited routing escaped' >&2; exit 98; }
done
[ -n "${AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW:-}" ] || exit 98
[ "$#" -eq 3 ] && [ "$2" = --json ] || exit 97
printf '%s\n' "$1" >> "$FRAME_TEST_CASE/events"
printf '%s\n' "$3" > "$FRAME_TEST_CASE/last-request.json"
case "${FRAME_TEST_MODE:-ok}" in
  refusal) printf 'retained CLI refusal\n' >&2; exit 77 ;;
  malformed) printf '{not-json\n'; exit 0 ;;
esac
case "$1" in
  session.query) printf '{"sourceHealth":"live","fixture":"session-owner-fact"}\n' ;;
  window.render)
    source="$FRAME_TEST_DATA/renders/$FRAME_TEST_RENDER.png"
    if [ "${FRAME_TEST_MODE:-ok}" = escape ]; then source="$FRAME_TEST_CASE/protected.png"; fi
    printf '\211PNG\r\n\032\ncontrolled-transfer-bytes' > "$source"
    chmod 600 "$source"
    jq -n --arg id "$FRAME_TEST_WINDOW" --arg source "$source" \
      '{workspaceWindowId:$id,image:{path:$source,pixelWidth:1040,pixelHeight:1200,scale:2,imagePointSize:{width:520,height:600}},contentSize:{width:520,height:600},surfaces:[]}' ;;
  window.resize)
    jq '{workspaceWindowId,correlationId,contentSize:{width:521,height:601}}' "$FRAME_TEST_CASE/last-request.json" ;;
  *) echo 'Unexpected app verb' >&2; exit 96 ;;
esac
CLI
  chmod 700 "$fixture/cli-stub"

  reset_case() {
    FRAME_TEST_CASE="$fixture/case-$1"
    VERIFY_PROJECT_ROOT="$FRAME_TEST_CASE"
    VERIFY_RUN_DIR="$FRAME_TEST_CASE/tmp/verify-agentstudio/run"
    VERIFY_DATA_ROOT="$FRAME_TEST_CASE/home/.agentstudio-db/t3st"
    VERIFY_CODE=t3st; VERIFY_PID=4242; VERIFY_MARKER=owned-fixture
    VERIFY_KERNEL_START=fixture-incarnation
    FRAME_TEST_GUARD=ok; FRAME_TEST_MODE=ok
    FRAME_TEST_LOCK=true
    FRAME_TEST_WINDOW="$fixture_window"; FRAME_TEST_RENDER="$fixture_render"
    FRAME_TEST_DATA="$VERIFY_DATA_ROOT"
    export FRAME_TEST_CASE FRAME_TEST_MODE FRAME_TEST_WINDOW FRAME_TEST_RENDER FRAME_TEST_DATA
    mkdir -p "$VERIFY_RUN_DIR" "$VERIFY_DATA_ROOT/renders" "$VERIFY_DATA_ROOT/apps/AgentStudio Debug t3st.app/Contents/Helpers"
    cp "$fixture/cli-stub" "$VERIFY_DATA_ROOT/apps/AgentStudio Debug t3st.app/Contents/Helpers/agentstudio"
    printf '{}\n' > "$VERIFY_RUN_DIR/ipc-escrow.json"
    : > "$FRAME_TEST_CASE/events"
    eval "$real_frame_copy"
    eval "$real_frame_stage"
  }
  check_case() {
    local name="$1" case_status; shift
    reset_case "$name"
    # Keep errexit active in each case. An if-wrapped function would disable it
    # and let a later successful assertion conceal an earlier failure.
    set +e
    ( set -e; "$@" ) > "$FRAME_TEST_CASE/output" 2>&1
    case_status=$?
    set -e
    if [ "$case_status" -eq 0 ]; then
      printf 'PASS %s\n' "$name"; passed=$((passed + 1))
    else
      printf 'FAIL %s\n' "$name"; cat "$FRAME_TEST_CASE/output"; failed=$((failed + 1))
    fi
  }
  good_render() {
    export AGENTSTUDIO_PANE_TOKEN=fixture-inherited AGENTSTUDIO_IPC_SOCKET=fixture-wrong-socket ZMX_DIR=fixture-wrong-zmx
    frame_render "$fixture_window" image "$fixture_pane" > /dev/null
    operation="$VERIFY_RUN_DIR/window-frames/image"
    [ "$(cat "$FRAME_TEST_CASE/events")" = $'settle\nsession.query\nwindow.render' ]
    [ -s "$operation/frame.png" ] && [ ! -e "$VERIFY_DATA_ROOT/renders/$fixture_render.png" ]
    jq -e --arg source "$VERIFY_DATA_ROOT/renders/$fixture_render.png" \
      '.stage=="moved" and .sourcePath==$source' "$operation/receipt.json" > /dev/null
    [ -f "$operation/call-start.json" ] && [ -f "$operation/call-end.json" ]
    [ "$(jq -r .state "$operation/lock-before.json")" = locked ]
    [ "$(jq -r .state "$operation/lock-after.json")" = locked ]
    [ -f "$operation/session-query.json" ]
  }
  resize_only() {
    frame_resize "$fixture_window" 520 600 "$fixture_correlation" width > "$FRAME_TEST_CASE/applied.json"
    [ "$(cat "$FRAME_TEST_CASE/events")" = window.resize ]
    jq -e '.contentSize.width==521 and .contentSize.height==601' "$FRAME_TEST_CASE/applied.json" > /dev/null
    [ ! -e "$VERIFY_RUN_DIR/window-frames/width/frame.png" ]
  }
  refused_cli() {
    FRAME_TEST_MODE=refusal; export FRAME_TEST_MODE
    status=0; frame_render "$fixture_window" refusal > /dev/null || status=$?
    [ "$status" -eq 77 ]
    [ "$(cat "$FRAME_TEST_CASE/events")" = $'settle\nwindow.render' ]
    [ -s "$VERIFY_RUN_DIR/window-frames/refusal/cli.stderr" ]
    [ -e "$VERIFY_RUN_DIR/window-frames/refusal/lock-after.json" ]
  }
  changed_target() {
    FRAME_TEST_GUARD=changed
    if frame_render "$fixture_window" changed > /dev/null; then return 1; fi
    [ "$(cat "$FRAME_TEST_CASE/events")" = settle ]
    [ ! -e "$VERIFY_RUN_DIR/window-frames/changed/receipt.json" ]
  }
  malformed_reply() {
    FRAME_TEST_MODE=malformed; export FRAME_TEST_MODE
    if frame_render "$fixture_window" malformed > /dev/null; then return 1; fi
    [ "$(cat "$FRAME_TEST_CASE/events")" = $'settle\nwindow.render' ]
    [ -s "$VERIFY_RUN_DIR/window-frames/malformed/response.json" ]
  }
  escaped_source() {
    FRAME_TEST_MODE=escape; export FRAME_TEST_MODE
    if frame_render "$fixture_window" escape > /dev/null; then return 1; fi
    [ -s "$FRAME_TEST_CASE/protected.png" ]
    [ -f "$VERIFY_RUN_DIR/window-frames/escape/receipt.json" ]
    if frame_cleanup > /dev/null; then return 1; fi
    [ -s "$FRAME_TEST_CASE/protected.png" ]
  }
  interrupted_copy() {
    frame_copy() { printf 'partial' > "$2"; return 73; }
    status=0; frame_render "$fixture_window" interrupted > /dev/null || status=$?
    [ "$status" -eq 73 ]
    operation="$VERIFY_RUN_DIR/window-frames/interrupted"
    [ -s "$VERIFY_DATA_ROOT/renders/$fixture_render.png" ]
    [ "$(jq -r .stage "$operation/receipt.json")" = received ]
    eval "$real_frame_copy"
    calls_before="$(cat "$FRAME_TEST_CASE/events")"
    # App is no longer inspectable. Filesystem cleanup must not call its guard/CLI.
    FRAME_TEST_GUARD=retired
    frame_cleanup > /dev/null
    [ "$calls_before" = "$(cat "$FRAME_TEST_CASE/events")" ]
    [ -s "$operation/frame.png" ] && [ ! -e "$VERIFY_DATA_ROOT/renders/$fixture_render.png" ]
    [ "$(jq -r .stage "$operation/receipt.json")" = moved ]
  }
  unreceived_file_survives() {
    printf 'unreceived' > "$VERIFY_DATA_ROOT/renders/unreceived.png"
    mkdir -p "$VERIFY_RUN_DIR/window-frames"
    frame_cleanup > /dev/null
    [ "$(cat "$VERIFY_DATA_ROOT/renders/unreceived.png")" = unreceived ]
    [ ! -s "$FRAME_TEST_CASE/events" ]
  }
  repeated_label() {
    frame_render "$fixture_window" repeated > /dev/null
    calls_before="$(cat "$FRAME_TEST_CASE/events")"
    if frame_render "$fixture_window" repeated > /dev/null; then return 1; fi
    [ "$calls_before" = "$(cat "$FRAME_TEST_CASE/events")" ]
  }
  transfer_owner_changes() {
    frame_copy() { return 73; }
    if frame_render "$fixture_window" owner > /dev/null; then return 1; fi
    VERIFY_MARKER=replacement
    if frame_cleanup > /dev/null; then return 1; fi
    [ -f "$VERIFY_DATA_ROOT/renders/$fixture_render.png" ]
  }
  source_symlink() {
    frame_copy() { return 73; }
    if frame_render "$fixture_window" linked > /dev/null; then return 1; fi
    source="$VERIFY_DATA_ROOT/renders/$fixture_render.png"
    mv "$source" "$FRAME_TEST_CASE/protected.png"
    ln -s "$FRAME_TEST_CASE/protected.png" "$source"
    if frame_cleanup > /dev/null; then return 1; fi
    [ -s "$FRAME_TEST_CASE/protected.png" ] && [ -L "$source" ]
  }
  interrupted_unlink() {
    rm() { return 74; }
    status=0; frame_render "$fixture_window" unlink > /dev/null || status=$?
    [ "$status" -eq 74 ]
    operation="$VERIFY_RUN_DIR/window-frames/unlink"
    [ -s "$VERIFY_DATA_ROOT/renders/$fixture_render.png" ] && [ -s "$operation/frame.png" ]
    [ "$(jq -r .stage "$operation/receipt.json")" = published ]
    unset -f rm
    frame_cleanup > /dev/null
    [ ! -e "$VERIFY_DATA_ROOT/renders/$fixture_render.png" ]
    [ -s "$operation/frame.png" ]
  }
  interrupted_publication_receipt() {
    frame_stage() {
      [ "$2" != published ] || return 75
      jq --arg stage "$2" '.stage=$stage' "$1/receipt.json" > "$1/receipt.json.new"
      mv "$1/receipt.json.new" "$1/receipt.json"
    }
    status=0; frame_render "$fixture_window" publish > /dev/null || status=$?
    [ "$status" -eq 75 ]
    operation="$VERIFY_RUN_DIR/window-frames/publish"
    [ -s "$VERIFY_DATA_ROOT/renders/$fixture_render.png" ] && [ -s "$operation/frame.png" ]
    [ "$(jq -r .stage "$operation/receipt.json")" = publishing ]
    eval "$real_frame_stage"
    frame_cleanup > /dev/null
    [ ! -e "$VERIFY_DATA_ROOT/renders/$fixture_render.png" ]
    [ -s "$operation/frame.png" ]
  }
  invalid_dimensions() {
    if frame_resize "$fixture_window" '"wide"' 600 "$fixture_correlation" invalid > /dev/null; then return 1; fi
    [ ! -s "$FRAME_TEST_CASE/events" ]
  }
  missing_method() {
    mkdir -p "$VERIFY_RUN_DIR/window-frames/incomplete"
    if frame_cleanup > /dev/null; then return 1; fi
    [ ! -s "$FRAME_TEST_CASE/events" ]
  }
  unlocked_probe() {
    FRAME_TEST_LOCK=false
    frame_lock "$FRAME_TEST_CASE/unlocked"
    jq -e '.state=="unlocked" and .probeExit==0' "$FRAME_TEST_CASE/unlocked.json" > /dev/null
  }
  denied_probe() {
    FRAME_TEST_LOCK=denied
    frame_render "$fixture_window" denied-lock > /dev/null
    operation="$VERIFY_RUN_DIR/window-frames/denied-lock"
    jq -e '.state=="UNKNOWN" and .probeExit==76' "$operation/lock-before.json" > /dev/null
    [ -s "$operation/lock-before.stderr" ]
    [ -s "$operation/frame.png" ]
  }
  malformed_probe() {
    FRAME_TEST_LOCK=malformed
    frame_lock "$FRAME_TEST_CASE/malformed-lock"
    jq -e '.state=="UNKNOWN"' "$FRAME_TEST_CASE/malformed-lock.json" > /dev/null
    [ -s "$FRAME_TEST_CASE/malformed-lock.stderr" ]
  }

  check_case render good_render
  check_case resize resize_only
  check_case refusal refused_cli
  check_case changed-target changed_target
  check_case malformed malformed_reply
  check_case escape escaped_source
  check_case interrupted interrupted_copy
  check_case unreceived unreceived_file_survives
  check_case repeated-label repeated_label
  check_case replacement-owner transfer_owner_changes
  check_case symlink source_symlink
  check_case unlink interrupted_unlink
  check_case publication-receipt interrupted_publication_receipt
  check_case invalid-dimensions invalid_dimensions
  check_case missing-method missing_method
  check_case unlocked-probe unlocked_probe
  check_case denied-probe denied_probe
  check_case malformed-probe malformed_probe
  printf '%s passed, %s failed; stub CLI/process/lock/time inputs only, no live proof\n' "$passed" "$failed"
  [ "$failed" -eq 0 ]
)
