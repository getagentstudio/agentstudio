#!/usr/bin/env bash
set -euo pipefail

mode="${1:-test}"
shift || true

bash "${PROJECT_ROOT}/scripts/vendor-worktree.sh" verify

case "$mode" in
  test|test-fast|test-large|test-prebuild|test-webkit|test-width-comparison)
    ;;
  *)
    echo "run-swift-test-task: unknown mode '$mode'" >&2
    exit 2
    ;;
esac

source "${PROJECT_ROOT}/scripts/swift-build-slot.sh"
source "${PROJECT_ROOT}/scripts/swift-package-sandbox.sh"
swift_build_slot_acquire test "$mode"
BUILD_PATH="$SWIFT_BUILD_DIR"
# Defaults match what every gated path already sets (CI lane env and the
# aggregate `mise run test` task). A bare focused run used to inherit 60/90,
# which kills a correct cold compile rather than a hung one.
TIMEOUT_SECONDS="${SWIFT_TEST_TIMEOUT_SECONDS:-600}"
PREBUILD_TIMEOUT_SECONDS="${SWIFT_TEST_PREBUILD_TIMEOUT_SECONDS:-1200}"

LOG_PREFIX="$mode"
EXTRA_SWIFT_TEST_ARGS="${EXTRA_SWIFT_TEST_ARGS:-}"
source scripts/swift-test-helpers.sh

echo "[$LOG_PREFIX] BUILD_PATH=$BUILD_PATH"
echo "[$LOG_PREFIX] TIMEOUT_SECONDS=$TIMEOUT_SECONDS"
echo "[$LOG_PREFIX] PREBUILD_TIMEOUT_SECONDS=$PREBUILD_TIMEOUT_SECONDS"

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
  local bundle_identity
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
    while IFS=$'\t' read -r failed_suite_filter failed_suite_status failed_suite_signal; do
      [ -n "$failed_suite_filter" ] || continue
      echo "[$LOG_PREFIX] lane-report failed_isolated_suite=$failed_suite_filter" \
        "status=$failed_suite_status signal=$failed_suite_signal"
    done <"$SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE"
  fi

  echo "[$LOG_PREFIX] lane-report head_sha=$LANE_RECEIPT_HEAD_SHA"
  echo "[$LOG_PREFIX] lane-report tree_dirty=$closing_tree_dirty"
  bundle_identity="$(lane_receipt_bundle_identity)"
  if [ "$LANE_BUNDLE_STATE" = "reused" ]; then
    bundle_link_reason="$(
      lane_build_receipt_link_reason "$(lane_build_receipt_path)" "$LANE_RECEIPT_HEAD_SHA" "$bundle_identity"
    )"
  fi
  echo "[$LOG_PREFIX] lane-report bundle_state=$LANE_BUNDLE_STATE"
  echo "[$LOG_PREFIX] lane-report bundle_identity=$bundle_identity"
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

# One half of a width comparison: the fast lane, at one width, reusing the bundle
# this invocation already built. It is a subshell with its own opening and closing
# receipt, and it keeps every event-stream ledger it writes, pass or fail, in a
# directory named for its width and that bundle, beside the half's full output.
#
# It reports its status in WIDTH_COMPARISON_HALF_STATUS and always returns 0,
# because bash ignores `set -e` inside anything called from an `||` or `if`
# context, subshells included: a caller testing the half's status would silently
# let a failing phase inside it continue into the next.
run_width_comparison_half() {
  local width="$1"
  local ledger_directory="$2"

  mkdir -p "$ledger_directory"
  set +e
  (
    set -euo pipefail
    if [ -n "$width" ]; then
      export SWIFT_TEST_PARALLELIZATION_WIDTH="$width"
    else
      unset SWIFT_TEST_PARALLELIZATION_WIDTH
    fi
    LOG_PREFIX="test-fast-width-$(swift_test_parallelization_width_label)"
    # The half runs on the bundle its parent built, so its receipt says so and
    # is valid only when linked to the build receipt that prebuild published.
    LANE_BUNDLE_STATE=reused
    LANE_EVENT_STREAM_DIR="$ledger_directory"
    LANE_EVENT_STREAM_RETAIN_ALWAYS=1
    print_opening_lane_report
    begin_lane_accounting
    trap print_closing_lane_report EXIT
    trap_lane_termination_signals
    run_fast_non_webkit_swift_tests
  ) 2>&1 | tee "$ledger_directory/lane-output.log"
  WIDTH_COMPARISON_HALF_STATUS="${PIPESTATUS[0]}"
  set -e
}

# Width 3 (the CI runner's core count) against an unset width, on ONE bundle, so
# the only difference between the two receipts is the width. Both halves always
# run; the comparison fails if either half failed. Neither result changes the
# default width, which stays unset.
run_width_comparison() {
  local bundle_identity
  local comparison_directory
  local comparison_status=0

  bundle_identity="$(lane_receipt_bundle_identity)"
  comparison_directory="${LANE_EVENT_STREAM_DIR}/width-comparison/$(
    printf '%s' "$LANE_RECEIPT_HEAD_SHA" | cut -c1-12
  )-bundle-${bundle_identity##*@}"
  echo "[$LOG_PREFIX] width comparison on bundle_identity=$bundle_identity"
  echo "[$LOG_PREFIX] width comparison ledgers: $comparison_directory"

  run_width_comparison_half 3 "$comparison_directory/width-3"
  [ "$WIDTH_COMPARISON_HALF_STATUS" -eq 0 ] || comparison_status=1
  run_width_comparison_half "" "$comparison_directory/width-unlimited"
  [ "$WIDTH_COMPARISON_HALF_STATUS" -eq 0 ] || comparison_status=1
  return "$comparison_status"
}

print_opening_lane_report
begin_lane_accounting
# fresh only once THIS invocation's prebuild has succeeded; a reused bundle is
# valid only when linked to its build receipt. See lane_receipt_invalid_reasons.
LANE_BUNDLE_STATE=not_built
trap finish_lane_invocation EXIT
trap_lane_termination_signals
swift_test_output_relay_begin_dispatcher

if [ "$mode" != "test-prebuild" ] && [ "${SWIFT_TEST_SKIP_PREBUILD:-0}" = "1" ]; then
  echo "[$LOG_PREFIX] skipping prebuild test bundles (SWIFT_TEST_SKIP_PREBUILD=1)"
  LANE_BUNDLE_STATE=reused
else
  prebuild_swift_tests_with_build_receipt
  LANE_BUNDLE_STATE=fresh
fi

if [ "$mode" = "test-prebuild" ]; then
  exit 0
fi

if [ "$#" -gt 0 ]; then
  requested_filter_mentions_suite() {
    local requested_suite="$1"
    shift

    local argument
    local filter_pattern
    local expects_filter_pattern=0
    for argument in "$@"; do
      filter_pattern=""
      if [ "$expects_filter_pattern" = "1" ]; then
        filter_pattern="$argument"
        expects_filter_pattern=0
      else
        case "$argument" in
          --filter)
            expects_filter_pattern=1
            continue
            ;;
          --filter=*)
            filter_pattern="${argument#--filter=}"
            ;;
          *)
            continue
            ;;
        esac
      fi

      case "$filter_pattern" in
        *"$requested_suite"*)
          return 0
          ;;
      esac
    done
    return 1
  }

  swift_test_args=("$@")
  if ! requested_filter_mentions_suite WebKitSerializedTests "$@"; then
    swift_test_args+=(--skip WebKitSerializedTests)
  fi
  if ! requested_filter_mentions_suite E2ESerializedTests "$@" &&
    ! requested_filter_mentions_suite ZmxE2ETests "$@"
  then
    swift_test_args+=(--skip E2ESerializedTests)
  fi
  if ! requested_filter_mentions_suite ZmxE2ETests "$@"; then
    swift_test_args+=(--skip ZmxE2ETests)
  fi

  run_swift_with_timeout \
    "requested swift test args: $*" \
    "$TIMEOUT_SECONDS" \
    env AGENT_STUDIO_BENCHMARK_MODE=off AGENTSTUDIO_TRACE_BACKEND="${SWIFT_TEST_TRACE_BACKEND:-jsonl}" $(swift_test_parallelization_env_word) swift test $(swift_package_sandbox_arguments) --skip-build "${swift_test_args[@]}" \
    --build-path "$BUILD_PATH"
  exit $?
fi

case "$mode" in
  test)
    run_fast_non_webkit_swift_tests
    run_large_non_webkit_swift_tests
    run_webkit_suites

    echo "--- E2E serialized tests (serial) ---"
    if [ "${SWIFT_TEST_INCLUDE_E2E:-0}" = "1" ]; then
      run_swift_with_timeout \
        "E2ESerializedTests" \
        "$TIMEOUT_SECONDS" \
        env AGENT_STUDIO_BENCHMARK_MODE=off AGENTSTUDIO_TRACE_BACKEND="${SWIFT_TEST_TRACE_BACKEND:-jsonl}" $(swift_test_parallelization_env_word) swift test $(swift_package_sandbox_arguments) --skip-build \
        --filter "$(swift_test_lane_filter_pattern e2e)" \
        --skip "$(swift_test_lane_filter_pattern zmx)" --build-path "$BUILD_PATH"
    else
      echo "[test] skipping E2ESerializedTests (SWIFT_TEST_INCLUDE_E2E=${SWIFT_TEST_INCLUDE_E2E:-0})"
    fi
    ;;
  test-fast)
    run_fast_non_webkit_swift_tests
    ;;
  test-large)
    run_large_non_webkit_swift_tests
    ;;
  test-webkit)
    run_webkit_suites
    ;;
  test-width-comparison)
    run_width_comparison
    ;;
esac
