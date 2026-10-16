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

source scripts/swift-test-lane-report.sh

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
  local bundle_set
  local comparison_directory
  local comparison_status=0

  bundle_set="$(swift_test_bundle_set)"
  comparison_directory="${LANE_EVENT_STREAM_DIR}/width-comparison/$(
    printf '%s' "$LANE_RECEIPT_HEAD_SHA" | cut -c1-12
  )-bundle-${bundle_set}"
  echo "[$LOG_PREFIX] width comparison on bundle_set=$bundle_set"
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

mandatory_selectors=()
mandatory_selector_output=""
# Requested SwiftPM filters do not execute the lane's isolated inventories.
# The whole map still gets linkage and duplicate checks for those invocations.
if [ "$#" -eq 0 ]; then
  mandatory_selector_output="$(swift_test_lane_mandatory_selectors "$mode")" || exit 1
fi
while IFS= read -r mandatory_selector; do
  [ -n "$mandatory_selector" ] || continue
  mandatory_selectors+=("$mandatory_selector")
done <<<"$mandatory_selector_output"
suite_map_preflight_status=0
if [ "${#mandatory_selectors[@]}" -eq 0 ]; then
  swift_test_suite_map_preflight || suite_map_preflight_status=$?
else
  swift_test_suite_map_preflight "${mandatory_selectors[@]}" || suite_map_preflight_status=$?
fi
if [ "$suite_map_preflight_status" -ne 0 ]; then
  echo "[$LOG_PREFIX] suite map preflight failed" >&2
  exit 1
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
