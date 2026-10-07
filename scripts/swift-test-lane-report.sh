#!/usr/bin/env bash
# One lane receipt policy for the normal runner and standalone mise tasks.
# Callers source swift-test-helpers.sh, set their lane variables, and own the slot.

# The machine and the tree a lane ran on. The tree identity is captured here and
# re-checked at the close, so edits made while the lane ran invalidate it.
print_opening_lane_report() {
  LANE_CPU_COUNT="$(swift_test_cpu_count)"
  LANE_RECEIPT_HEAD_SHA="$(lane_receipt_head_sha)"
  LANE_RECEIPT_TREE_DIRTY="$(lane_receipt_tree_dirty)"
  echo "[$LOG_PREFIX] lane-report cpu_count=$LANE_CPU_COUNT"
  echo "[$LOG_PREFIX] lane-report memory_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo unavailable)"
  echo "[$LOG_PREFIX] lane-report parallelization_width=$(swift_test_parallelization_width_label)"
  echo "[$LOG_PREFIX] lane-report isolated_process_concurrency=$(swift_test_isolated_process_concurrency)"
  echo "[$LOG_PREFIX] lane-report xcode=$(xcodebuild -version | tr '\n' ' ')"
  echo "[$LOG_PREFIX] lane-report swift=$(swift --version | head -1)"
  echo "[$LOG_PREFIX] lane-report head_sha=$LANE_RECEIPT_HEAD_SHA"
  echo "[$LOG_PREFIX] lane-report tree_dirty=$LANE_RECEIPT_TREE_DIRTY"
}

# Children CPU seconds (user+sys) from the second line of bash `times`, which
# reads "<minutes>m<seconds>s <minutes>m<seconds>s".
lane_children_cpu_seconds() {
  local times_file="$1"

  [ -s "$times_file" ] || { echo "0.00"; return 0; }
  /usr/bin/awk 'NR == 2 {
      total = 0
      for (field = 1; field <= NF; field++) {
        split($field, parts, "m")
        seconds = parts[2]
        sub(/s$/, "", seconds)
        total += parts[1] * 60 + seconds
      }
      printf "%.2f\n", total
      found = 1
    }
    END { if (!found) { print "0.00" } }' "$times_file"
}

# Starts one lane's load accounting. Every lane that prints a closing receipt
# owns its own tally files, so two lanes in one invocation never share counts.
begin_lane_accounting() {
  LANE_START_SECONDS="$SECONDS"
  swift_test_f2_begin_lane_accounting || true
  swift_test_begin_active_command_groups
  LANE_TIMES_FILE="$(mktemp "${TMPDIR:-/tmp}/agentstudio-lane-times.XXXXXX")"
  SWIFT_TEST_PEAK_ANNOUNCED_FILE="$(mktemp "${TMPDIR:-/tmp}/agentstudio-lane-peak-announced.XXXXXX")"
  SWIFT_TEST_PEAK_RUNNING_FILE="$(mktemp "${TMPDIR:-/tmp}/agentstudio-lane-peak-running.XXXXXX")"
  SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE="$(
    mktemp "${TMPDIR:-/tmp}/agentstudio-lane-failed-isolated-suites.XXXXXX"
  )"
  export SWIFT_TEST_PEAK_ANNOUNCED_FILE SWIFT_TEST_PEAK_RUNNING_FILE
  export SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE
}

# Printed on every exit, including a failing one: a failing lane is the one we
# most need to read load numbers from.
print_closing_lane_report() {
  local exit_status="${1:-$?}"
  local wall_seconds=$((SECONDS - LANE_START_SECONDS))
  local cpu_seconds
  local closing_tree_dirty
  local bundle_set bundle_count
  local bundle_link_reason=""

  times >"$LANE_TIMES_FILE" 2>/dev/null || true
  cpu_seconds="$(lane_children_cpu_seconds "$LANE_TIMES_FILE")"
  closing_tree_dirty="$(lane_receipt_tree_dirty_since "$LANE_RECEIPT_HEAD_SHA" "$LANE_RECEIPT_TREE_DIRTY")"

  echo "[$LOG_PREFIX] lane-report exit_status=$exit_status"
  echo "[$LOG_PREFIX] lane-report wall_seconds=$wall_seconds"
  echo "[$LOG_PREFIX] lane-report cpu_seconds=$cpu_seconds"
  swift_test_f2_report_resource_table || true
  echo "[$LOG_PREFIX] lane-report cpu_utilization=$(
    /usr/bin/awk -v cpu="$cpu_seconds" -v wall="$wall_seconds" -v cores="$LANE_CPU_COUNT" \
      'BEGIN { if (wall <= 0 || cores <= 0) { print "0.00" } else { printf "%.2f\n", cpu / (wall * cores) } }'
  )"
  # peak_announced_tests counts tests whose start event was posted and does NOT
  # reflect the parallelization cap; peak_running_parameterized_cases does.
  # Both labels say "parameterized" because Swift Testing's v0 event stream emits
  # test-case records only for parameterized cases, so that number is a floor over
  # that subset and reads 0 for a lane with no parameterized tests.
  echo "[$LOG_PREFIX] lane-report peak_announced_tests=$(
    swift_test_peak_total_from_file "${SWIFT_TEST_PEAK_ANNOUNCED_FILE:-}"
  )"
  echo "[$LOG_PREFIX] lane-report peak_running_parameterized_cases=$(
    swift_test_peak_total_from_file "${SWIFT_TEST_PEAK_RUNNING_FILE:-}"
  )"

  # The whole truth about the isolated inventory: how many suites failed, and
  # which. A crashed process no longer hides the suites that ran after it.
  echo "[$LOG_PREFIX] lane-report failed_isolated_suites=$(swift_test_failed_isolated_suite_count)"
  if [ -s "${SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE:-}" ]; then
    while IFS=$'\t' read -r failed_suite_filter failed_suite_status failed_suite_signal failed_suite_reason; do
      [ -n "$failed_suite_filter" ] || continue
      echo "[$LOG_PREFIX] lane-report failed_isolated_suite=$failed_suite_filter" \
        "status=$failed_suite_status signal=$failed_suite_signal reason=${failed_suite_reason:-crashed}"
    done <"$SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE"
  fi

  echo "[$LOG_PREFIX] lane-report head_sha=$LANE_RECEIPT_HEAD_SHA"
  echo "[$LOG_PREFIX] lane-report tree_dirty=$closing_tree_dirty"
  bundle_set="$(swift_test_bundle_set)"
  bundle_count="$(swift_test_bundle_count)"
  if [ "$LANE_BUNDLE_STATE" = "reused" ] || [ "$LANE_BUNDLE_STATE" = "fresh" ]; then
    bundle_link_reason="$(
      lane_build_receipt_link_reason "$(lane_build_receipt_path)" "$LANE_RECEIPT_HEAD_SHA" "$bundle_set"
    )"
  fi
  echo "[$LOG_PREFIX] lane-report bundle_state=$LANE_BUNDLE_STATE"
  echo "[$LOG_PREFIX] lane-report bundle_set=$bundle_set"
  echo "[$LOG_PREFIX] lane-report bundle_count=$bundle_count"
  # The linkage: which commit the build receipt beside this bundle says it built.
  echo "[$LOG_PREFIX] lane-report build_receipt_head_sha=$(
    lane_build_receipt_field "$(lane_build_receipt_path)" head_sha || echo none
  )"
  print_lane_receipt_verdict "$exit_status" "$LANE_BUNDLE_STATE" "$closing_tree_dirty" "$bundle_link_reason"

  rm -f "$LANE_TIMES_FILE" "${SWIFT_TEST_PEAK_ANNOUNCED_FILE:-}" "${SWIFT_TEST_PEAK_RUNNING_FILE:-}" \
    "${SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE:-}"
  swift_test_cleanup_active_command_groups_directory
}

# A lane ended by a signal exits with 128+signal, so its receipt says so. Without
# these, bash runs the EXIT trap after a fatal signal with `$?` still holding the
# last completed command's status, and a SIGTERMed lane printed
# `exit_status=0 verdict=pass`.
# These handlers also run in receipt fixtures that do not source the process-group
# helpers, so group forwarding is optional and every cleanup must leave slot release reachable.
trap_lane_termination_signals() {
  trap '
    if declare -F swift_test_signal_active_command_groups >/dev/null 2>&1; then
      swift_test_signal_active_command_groups HUP || true
    fi
    swift_test_terminate_active_isolated_suites || true
    exit 129
  ' HUP
  trap '
    if declare -F swift_test_signal_active_command_groups >/dev/null 2>&1; then
      swift_test_signal_active_command_groups INT || true
    fi
    swift_test_terminate_active_isolated_suites || true
    exit 130
  ' INT
  trap '
    if declare -F swift_test_signal_active_command_groups >/dev/null 2>&1; then
      swift_test_signal_active_command_groups TERM || true
    fi
    swift_test_terminate_active_isolated_suites || true
    exit 143
  ' TERM
}

# The invocation's single EXIT handler owns the lane receipt and slot release.
finish_lane_invocation() {
  local exit_status=$?
  # Optional group helpers and cleanup failures must never prevent the slot release.
  if declare -F swift_test_signal_active_command_groups >/dev/null 2>&1; then
    swift_test_signal_active_command_groups TERM || true
  fi
  swift_test_terminate_active_isolated_suites || true
  if declare -F swift_test_signal_active_command_groups >/dev/null 2>&1; then
    swift_test_signal_active_command_groups KILL || true
  fi
  print_closing_lane_report "$exit_status" || true
  if declare -F swift_test_cleanup_active_command_groups_directory >/dev/null 2>&1; then
    swift_test_cleanup_active_command_groups_directory || true
  fi
  swift_build_slot_release || true
  swift_test_output_relay_finish_dispatcher || true
  return "$exit_status"
}

swift_test_begin_receipted_lane() {
  print_opening_lane_report
  begin_lane_accounting
  LANE_BUNDLE_STATE=not_built
  trap finish_lane_invocation EXIT
  trap_lane_termination_signals
  swift_test_output_relay_begin_dispatcher
}
