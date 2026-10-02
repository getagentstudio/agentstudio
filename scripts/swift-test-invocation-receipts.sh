#!/usr/bin/env bash
# F2 observation only: these helpers never choose a command verdict or a bound.

swift_test_f2_begin_receipt() {
  local stem="$1"
  rm -f "$stem.invocation.json" "$stem.invocation-report.txt" "$stem.pending-waits.txt" \
    "$stem.resources.txt" "$stem.resource-mode" 2>/dev/null || true
}

swift_test_f2_launch_command_group() {
  local stem="$1" timer="${SWIFT_TEST_RESOURCE_TIMER:-/usr/bin/time}"
  shift
  printf 'unavailable\n' >"$stem.resource-mode" 2>/dev/null || true
  # A capability failure is diagnostic unavailability, never a failed command.
  # Probe once per invocation, not per test; no supported-tool assumption leaks
  # into command execution on another platform or an incomplete runner image.
  if [ -x "$timer" ] && : >"$stem.resources.txt" 2>/dev/null && \
    "$timer" -l -p /usr/bin/true > /dev/null 2>"$stem.resource-probe.txt"
  then
    printf 'bsd_time\n' >"$stem.resource-mode" 2>/dev/null || true
    rm -f "$stem.resource-probe.txt" || true
    # BSD time turns a directly signalled child into status 1. Time the EXISTING
    # pipeline supervisor instead: it already captures 139/143 and exits with
    # that status normally. CPU includes its reaped command/tee/formatter tree.
    # FD 3 retains the original stderr while only time's stderr goes to stats.
    # The bootstrap exec closes FD 3 before the existing supervisor runs.
    swift_test_launch_command_group "$timer" -l -p /bin/bash -c \
      'exec 2>&3 3>&-; unset SWIFT_TEST_F2_SIDECAR_LIST; exec "$@"' swift-test-resource-wrapper "$@" \
      3>&2 2>"$stem.resources.txt"
    return $?
  fi
  rm -f "$stem.resource-probe.txt" || true
  swift_test_launch_command_group /bin/bash -c \
    'unset SWIFT_TEST_F2_SIDECAR_LIST; exec "$@"' swift-test-resource-unavailable "$@"
}

swift_test_f2_collect_events() {
  local stem="$1" output="$2" events="$3" held="$4" snapshot="$5"
  [ -s "$stem.invocation.json" ] && return 0
  local analyzer="${BASH_SOURCE[0]%/*}/swift-test-invocation-receipts.pl"
  LOG_PREFIX="${LOG_PREFIX:-test}" /usr/bin/perl "$analyzer" collect \
    "$stem" "$output" "$events" "$held" "$snapshot" 2>/dev/null || \
    echo "[${LOG_PREFIX:-test}] lane-report invocation_observation=unavailable" >&2
  return 0
}

swift_test_f2_print_pending_waits() {
  local stem="$1" held="$2" output="$3"
  if [ -r "$stem.pending-waits.txt" ]; then
    cat "$stem.pending-waits.txt" || true
  else
    print_held_steps_unarrived_at_timeout "$held" "$output" || true
  fi
}

swift_test_f2_finalize_resources() {
  local stem="$1" child_timing="$2" dispatch="$3" complete="$4" timed_out="$5"
  local analyzer="${BASH_SOURCE[0]%/*}/swift-test-invocation-receipts.pl"
  /usr/bin/perl "$analyzer" resources "$stem" "$child_timing" "$dispatch" "$complete" "$timed_out" \
    2>/dev/null || true
  rm -f "$stem.resources.txt" "$stem.resource-mode" || true
  return 0
}

swift_test_f2_attach_receipt() {
  local sidecar="$1" stem="${1%.timing.json}"
  local analyzer="${BASH_SOURCE[0]%/*}/swift-test-invocation-receipts.pl"
  /usr/bin/perl "$analyzer" attach "$stem" "$sidecar" 2>/dev/null || true
  rm -f "$stem.invocation.json" "$stem.invocation-report.txt" "$stem.pending-waits.txt" || true
  return 0
}

swift_test_f2_begin_lane_accounting() {
  SWIFT_TEST_F2_SIDECAR_LIST="$(mktemp "${TMPDIR:-/tmp}/agentstudio-invocation-sidecars.XXXXXX")" || true
  export SWIFT_TEST_F2_SIDECAR_LIST
  return 0
}

swift_test_f2_report_resource_table() {
  local list="${SWIFT_TEST_F2_SIDECAR_LIST:-}"
  [ -r "$list" ] || return 0
  local analyzer="${BASH_SOURCE[0]%/*}/swift-test-invocation-receipts.pl"
  LOG_PREFIX="${LOG_PREFIX:-test}" /usr/bin/perl "$analyzer" table "$list" 2>/dev/null || true
  rm -f "$list" || true
  return 0
}
