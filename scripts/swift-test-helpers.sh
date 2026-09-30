#!/usr/bin/env bash
# Shared test helper functions for mise tasks.
#
# Required variables (set by caller before sourcing):
#   LOG_PREFIX         - Log prefix, e.g. "test" or "test-coverage"
#   TIMEOUT_SECONDS    - Maximum seconds without Swift command output progress
#   PREBUILD_TIMEOUT_SECONDS - Maximum seconds without one-time test bundle build output progress
#   BUILD_PATH         - Swift build path
#
# Optional variables:
#   EXTRA_SWIFT_TEST_ARGS - Additional swift test flags (e.g. "--enable-code-coverage")
#   XCB_EXTRA_ARGS        - Extra xcbeautify flags (e.g. "--renderer github-actions")

# shellcheck source=scripts/xcb-helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/xcb-helpers.sh"
# shellcheck source=scripts/swift-package-sandbox.sh
source "$(dirname "${BASH_SOURCE[0]}")/swift-package-sandbox.sh"

# Maximum test cases Swift Testing may run concurrently inside one test process.
# OPT-IN, WITH NO DEFAULT, ON PURPOSE.
#
# Swift Testing's cap is experimental and off unless
# SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH is set. On this suite, setting a
# width made the fast lane hang intermittently at EVERY width tried — 15 of 28
# local runs on Swift 6.3.3 blocked (widths 3, 8, 16, 17, 64 and 256 all blocked;
# evidence in the CI reliability work). Until that is understood the width stays
# opt-in for experiments only and MUST NOT be given a default.
#
# Prints the width when SWIFT_TEST_PARALLELIZATION_WIDTH is set and non-empty,
# and nothing otherwise.
swift_test_parallelization_width() {
  echo "${SWIFT_TEST_PARALLELIZATION_WIDTH:-}"
}

# The `NAME=value` env word for a test invocation, or NOTHING when no width is
# set. Every invocation uses this one helper, unquoted, so an unset width leaves
# the variable ABSENT from the child environment rather than set to an empty
# string — Swift Testing treats absence as unlimited, and we do not rely on how
# it would parse "" or 0.
swift_test_parallelization_env_word() {
  local width
  width="$(swift_test_parallelization_width)"

  [ -n "$width" ] || return 0
  echo "SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=$width"
}

# What the lane report prints for the width: the number, or `unlimited` when no
# width is set, because an absent cap is the state a log reader needs to see.
swift_test_parallelization_width_label() {
  local width
  width="$(swift_test_parallelization_width)"

  if [ -n "$width" ]; then
    echo "$width"
  else
    echo unlimited
  fi
}

# How many isolated suite PROCESSES the aggregate phase runs at once. Process
# fan-out follows the machine: never more than one per core, and never more
# than 4 (the fan-out that developer machines already used).
# Agent sandboxes can deny sysctl reads. Fall back to sysconf through getconf,
# then to 1: fewer processes is always safe, only slower.
swift_test_cpu_count() {
  local cpu_count
  cpu_count="$(sysctl -n hw.ncpu 2>/dev/null || true)"
  if ! [[ "$cpu_count" =~ ^[1-9][0-9]*$ ]]; then
    cpu_count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  fi
  if ! [[ "$cpu_count" =~ ^[1-9][0-9]*$ ]]; then
    cpu_count=1
  fi
  echo "$cpu_count"
}

swift_test_isolated_process_concurrency() {
  local cpu_count
  cpu_count="$(swift_test_cpu_count)"
  if [ "$cpu_count" -lt 4 ]; then
    echo "$cpu_count"
  else
    echo 4
  fi
}

# Keep WebKit suites serial until the time-coupled Bridge waits are event-driven.
# BridgeProductStreamWebKitFeasibilityWebKitTests.swift:21,26 use 30s/8s waits, and
# BridgeProductRealGitFileAndReviewWebKitTests.swift:145 waits for foreground
# catch-up; all three exceeded their budgets under three-process, three-core CI.
SWIFT_TEST_WEBKIT_PROCESS_CONCURRENCY=1

swift_test_webkit_process_concurrency() {
  echo "$SWIFT_TEST_WEBKIT_PROCESS_CONCURRENCY"
}

# Largest number of tests whose START EVENT had been posted but whose result had
# not, as an ordinal count over one captured console stream. These tests were
# ANNOUNCED, not started or running, and the lane report labels them that way.
#
# This does NOT reflect the parallelization cap. Swift Testing posts .testStarted
# in _runStep BEFORE the test acquires the parallelization serializer, so a test
# counted here may be suspended in a continuation rather than running, and this
# number stays near the total test count even when the cap is working. It is kept
# because it is cheap and shows admission backlog; peak_running_parameterized_cases is the
# number that reflects the cap.
swift_test_peak_announced_from_output() {
  local output_file="$1"

  /usr/bin/iconv -f UTF-8 -t UTF-8 -c <"$output_file" | /usr/bin/awk '
    { line = $0; sub(/^\[[^]]*\] /, "", line) }
    line ~ /^◇ Test / && line ~ /started\.$/ && line !~ /^◇ Test (run|case) / {
      in_flight++
      if (in_flight > peak) { peak = in_flight }
      next
    }
    line ~ /^[✔✘] Test / && line !~ /^[✔✘] Test (run|case) / &&
      (line ~ / passed after / || line ~ / failed after /) {
      if (in_flight > 0) { in_flight-- }
      next
    }
    END { print peak + 0 }
  '
}

# Largest number of test cases RUNNING at once, from Swift Testing's JSON event
# stream. The parallelization serializer gates _runTestCase and testCaseStarted /
# testCaseEnded fire inside it, so unlike peak_announced_tests this observes the cap.
#
# Coverage caveat for this toolchain (Swift 6.3.3): the event stream serializes
# testCase events only for PARAMETERIZED cases — measured 54 testCaseStarted
# records against 880 testStarted records on one lane sample. So this is a lower
# bound taken over the parameterized subset, and reads 0 for a lane that has none.
swift_test_peak_running_cases_from_events() {
  local event_stream_file="${1:-}"

  # -r, not -s: a pipe (process substitution in tests) always reports size 0, and
  # an empty regular stream already yields 0 from the END rule below.
  if [ -z "$event_stream_file" ] || [ ! -r "$event_stream_file" ]; then
    echo 0
    return 0
  fi
  /usr/bin/awk '
    /"kind":"testCaseStarted"/ {
      running++
      if (running > peak) { peak = running }
      next
    }
    /"kind":"testCaseEnded"/ { if (running > 0) { running-- }; next }
    END { print peak + 0 }
  ' "$event_stream_file"
}

# Identifiers of the test cases that had a testCaseStarted with no matching
# testCaseEnded when the stream was read — i.e. what the timed-out command was
# still executing. First-seen order, capped at maximum_ids so one wedged lane
# cannot bury its own log. Returns 1 (and prints nothing) when there is no
# readable stream; the caller turns that into the `unavailable` label.
#
# Same parameterized-case caveat as swift_test_peak_running_cases_from_events:
# this names the stuck PARAMETERIZED cases and stays silent about others.
swift_test_running_case_ids_from_events() {
  local event_stream_file="${1:-}"
  local maximum_ids="${2:-40}"

  if [ -z "$event_stream_file" ] || [ ! -r "$event_stream_file" ]; then
    return 1
  fi
  # A timed-out writer leaves a half-flushed final line; awk just fails to match
  # it. Nothing in here may fail the lane, so stderr is dropped and the caller
  # tolerates a non-zero status.
  /usr/bin/awk -v maximum_ids="$maximum_ids" '
    function case_key(record,   test_id, display_name, case_field) {
      test_id = ""
      display_name = ""
      if (match(record, /"testID":"[^"]*"/)) {
        test_id = substr(record, RSTART + 10, RLENGTH - 11)
      }
      case_field = record
      if (match(case_field, /"_testCase":\{/)) {
        case_field = substr(case_field, RSTART)
        if (match(case_field, /"displayName":"[^"]*"/)) {
          display_name = substr(case_field, RSTART + 15, RLENGTH - 16)
        }
      }
      if (display_name == "") { return test_id }
      return test_id " [" display_name "]"
    }
    /"kind":"testCaseStarted"/ {
      started_key = case_key($0)
      if (!(started_key in seen)) {
        seen[started_key] = 1
        order[++order_count] = started_key
      }
      running[started_key]++
      next
    }
    /"kind":"testCaseEnded"/ {
      ended_key = case_key($0)
      if (running[ended_key] > 0) { running[ended_key]-- }
      next
    }
    END {
      for (position = 1; position <= order_count && printed < maximum_ids; position++) {
        if (running[order[position]] > 0) {
          print order[position]
          printed++
        }
      }
    }
  ' "$event_stream_file" 2>/dev/null
}

# Names what was still executing when the inactivity bound fired, under the same
# greppable lane-report prefix as the rest of the lane load numbers.
# Where a wedged run's event stream is kept, and how many per label survive.
#
# The event stream is the only authoritative record of which test cases started
# and which ended. Deleting it on the timeout path forced regex archaeology over
# console output, which produced two contradictory unfinished-suite counts (3 and
# 21) for the same runs; the preserved ledger named the one parked function
# instead.
LANE_EVENT_STREAM_DIR="${LANE_EVENT_STREAM_DIR:-tmp/plan-workflows/ci-runs}"
LANE_EVENT_STREAM_KEEP_PER_LABEL="${LANE_EVENT_STREAM_KEEP_PER_LABEL:-5}"
# The thread-stack sampler a hang report uses; the task dump does not depend on it.
LANE_STACK_SAMPLE_TOOL="${LANE_STACK_SAMPLE_TOOL:-/usr/bin/sample}"

# Lane labels are prose ("native-concurrent fast non-WebKit suites"), so they are
# slugged before reaching a filename.
lane_event_stream_label_slug() {
  local label="${1:-lane}"
  local label_slug
  label_slug="$(printf '%s' "$label" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cs 'a-z0-9' '-' \
    | sed -E 's/^-+//; s/-+$//')"
  if [ "${#label_slug}" -gt 91 ]; then
    local label_hash
    label_hash="$(printf '%s' "$label" | shasum -a 256 | cut -c 1-10)"
    label_slug="${label_slug:0:80}-$label_hash"
  fi
  printf '%s\n' "$label_slug"
}

# Copies the event stream somewhere durable and prints where. Called on the paths
# where the run ended without Swift Testing recording a failure — a timeout, or a
# child that died without an ✘ — because those are exactly the runs whose console
# output cannot say what was still executing. A clean run keeps nothing.
#
# A COPY, not a move, and on the timeout path it is taken before anything is
# signalled: the child still holds the stream open, so the original must stay
# where its fd points. The caller deletes that original as usual once the run is
# over.
preserve_lane_event_stream() {
  local label="$1"
  local event_stream_file="${2:-}"
  local evidence_stem="${3:-$(lane_evidence_stem "$label")}"

  if [ -z "$event_stream_file" ] || [ ! -r "$event_stream_file" ]; then
    echo "[$LOG_PREFIX] lane-report event_stream=unavailable"
    return 0
  fi

  local label_slug
  label_slug="$(lane_event_stream_label_slug "$label")"
  mkdir -p "$LANE_EVENT_STREAM_DIR"
  local preserved_path
  preserved_path="$evidence_stem.events.jsonl"
  if cp "$event_stream_file" "$preserved_path" 2>/dev/null; then
    echo "[$LOG_PREFIX] lane-report event_stream=$preserved_path"
    prune_lane_event_streams "$label_slug"
  else
    echo "[$LOG_PREFIX] lane-report event_stream=unavailable"
  fi
}

# Where one test invocation's hang evidence goes: the event ledger, one task dump
# per stuck process, and the held-step log all share this stem, so the files that
# explain one wedge sit side by side as
# `lane-<label>-<timestamp>-<runner pid>.{events.jsonl,held-steps.log}` and
# `...-pid<pid>.task-dump.txt`.
lane_evidence_stem() {
  echo "$LANE_EVENT_STREAM_DIR/lane-$(lane_event_stream_label_slug "$1")-$(date +%Y%m%dT%H%M%S)-$$"
}

# The held steps and typed facts a hung lane was still waiting on. The harness
# appends one TAB-separated line per event, with a single O_APPEND write:
#   waiting<TAB><instance id><TAB><name><TAB><fileID function>
#   arrived<TAB><instance id><TAB><name>
# Names contain spaces, so only tabs separate fields. An arrival settles only
# the wait with the same instance id: two steps can share a name, and one
# instance arriving (even before any wait was logged) must not hide another
# instance's missing arrival. Expectation ids pair expecting with settled even
# when settled is first. Only newline-terminated records count; a killed writer
# may leave a partial last line. Every unmatched wait is printed in log order.
print_held_steps_unarrived_at_timeout() {
  local held_step_log="${1:-}"
  local lane_output="${2:-}"
  local record_kind field_one field_two field_three field_four field_five

  if [ -n "$held_step_log" ] && [ -s "$held_step_log" ]; then
    /usr/bin/perl -ne '
      next unless /\n\z/;
      chomp;
      my @field = split /\t/, $_, -1;
      if ($field[0] eq "waiting" && @field >= 3 && $field[1] ne "") {
        push @step_order, $field[1] unless exists $step_name{$field[1]};
        $step_name{$field[1]} = $field[2];
        $step_test{$field[1]} = $field[3] // "";
      } elsif ($field[0] eq "arrived" && @field >= 2 && $field[1] ne "") {
        $arrived{$field[1]} = 1;
      } elsif ($field[0] eq "expecting" && @field >= 6 && $field[1] ne "") {
        push @expectation_order, $field[1] unless exists $expected_case{$field[1]};
        $expected_case{$field[1]} = $field[2];
        $scope{$field[1]} = $field[3];
        $test{$field[1]} = $field[4];
        $site{$field[1]} = $field[5];
      } elsif ($field[0] eq "settled" && @field >= 3 && $field[1] ne "") {
        $settled{$field[1]} = 1;
      }
      END {
        for my $id (@step_order) {
          print join("\t", "held", $step_name{$id}, $id, $step_test{$id}), "\n"
            unless $arrived{$id};
        }
        for my $id (@expectation_order) {
          print join("\t", "expectation", $id, $expected_case{$id}, $scope{$id}, $test{$id}, $site{$id}), "\n"
            unless $settled{$id};
        }
      }
    ' "$held_step_log" 2>/dev/null | while IFS=$'\t' read -r record_kind field_one field_two field_three field_four field_five; do
      case "$record_kind" in
        held)
          printf '[%s] lane-report held_step_unarrived name=%s id=%s test=%s\n' \
            "$LOG_PREFIX" "$field_one" "$field_two" "$field_three"
          ;;
        expectation)
          printf '[%s] lane-report fact_expected id=%s expected=%s scope=%s test=%s site=%s\n' \
            "$LOG_PREFIX" "$field_one" "$field_two" "$field_three" "$field_four" "$field_five"
          ;;
      esac
    done || true
  fi
  if [ -n "$lane_output" ] && [ -f "$lane_output" ] && \
    /usr/bin/grep -Fq '[agentstudio-test-log] unavailable ' "$lane_output"; then
    printf '[%s] lane-report held_step_log_unavailable\n' "$LOG_PREFIX"
  fi
}

# A held-step log is evidence only when a test wrote to it.
discard_empty_held_step_log() {
  local held_step_log="${1:-}"

  if [ -n "$held_step_log" ] && [ ! -s "$held_step_log" ]; then
    rm -f "$held_step_log"
  fi
}

# Keeps the evidence of the newest `LANE_EVENT_STREAM_KEEP_PER_LABEL` runs of one
# label, one run at a time. A run's evidence is every file sharing its stem,
# `lane-<label>-<YYYYmmddTHHMMSS>-<runner pid>`: the ledger (`.events.jsonl`),
# the held-step log (`.held-steps.log`) and one task dump per stuck process
# (`-pid<pid>.task-dump.txt`). Retention is by stem, never per kind, so one
# hang's several dumps cannot evict the dump of a run whose ledger is kept.
#
# Stems are ordered newest first by name: the fixed-width timestamp sorts
# chronologically, and file modification times are not the run's time (a
# copied ledger is stamped when it is copied). An empty held-step log is not
# evidence, so it never makes a stem count; a stem it is the only member of is
# deleted. Files whose stem does not have this label's exact shape belong to
# another label (`lane-foo-bar-…` is not `lane-foo`'s) and are left alone.
prune_lane_event_streams() {
  [ "${LANE_EVENT_STREAM_RETAIN_ALWAYS:-0}" = "1" ] && return 0
  local label_slug="$1"
  local stem_inventory
  local kept_stems
  local evidence_stem
  local stem_counts
  local evidence_name

  [ -d "$LANE_EVENT_STREAM_DIR" ] || return 0
  stem_inventory="$(lane_evidence_stem_inventory "lane-$label_slug-")"
  [ -n "$stem_inventory" ] || return 0

  kept_stems="$(
    printf '%s\n' "$stem_inventory" | /usr/bin/awk '$2 == 1 { print $1 }' | sort -ru |
      head -n "$LANE_EVENT_STREAM_KEEP_PER_LABEL"
  )" || true
  printf '%s\n' "$stem_inventory" | while read -r evidence_stem stem_counts evidence_name; do
    if ! printf '%s\n' "$kept_stems" | grep -Fxq -- "$evidence_stem"; then
      rm -f "$LANE_EVENT_STREAM_DIR/$evidence_name"
    fi
  done || true
}

# One `<stem> <counts> <file name>` line per evidence file of one label, where
# counts is 0 for an empty held-step log and 1 otherwise. A function of its own,
# not inline in the caller's `$(…)`: bash 3.2 (macOS /bin/bash) mis-parses
# `case` patterns inside a command substitution.
lane_evidence_stem_inventory() {
  local label_prefix="$1"
  local evidence_path
  local evidence_name
  local evidence_stem
  local stem_tail
  local stem_counts

  for evidence_path in "$LANE_EVENT_STREAM_DIR/$label_prefix"*; do
    [ -f "$evidence_path" ] || continue
    evidence_name="${evidence_path##*/}"
    stem_counts=1
    case "$evidence_name" in
      *.events.jsonl) evidence_stem="${evidence_name%.events.jsonl}" ;;
      *.timing.json) evidence_stem="${evidence_name%.timing.json}" ;;
      *.held-steps.log)
        evidence_stem="${evidence_name%.held-steps.log}"
        [ -s "$evidence_path" ] || stem_counts=0
        ;;
      *-pid*.task-dump.txt)
        evidence_stem="${evidence_name%-pid*.task-dump.txt}"
        case "${evidence_name#"$evidence_stem"-pid}" in
          *[!0-9]*.task-dump.txt | .task-dump.txt) continue ;;
        esac
        ;;
      *) continue ;;
    esac
    stem_tail="${evidence_stem#"$label_prefix"}"
    case "$stem_tail" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]-*) ;;
      *) continue ;;
    esac
    case "${stem_tail#*T??????-}" in
      '' | *[!0-9]*) continue ;;
    esac
    printf '%s %s %s\n' "$evidence_stem" "$stem_counts" "$evidence_name"
  done
}

print_running_parameterized_cases_at_timeout() {
  local event_stream_file="${1:-}"
  local running_case_ids=""
  local running_case_id

  if [ -z "$event_stream_file" ] || [ ! -r "$event_stream_file" ]; then
    echo "[$LOG_PREFIX] lane-report running_parameterized_cases_at_timeout=unavailable"
    return 0
  fi
  running_case_ids="$(swift_test_running_case_ids_from_events "$event_stream_file" || true)"
  if [ -z "$running_case_ids" ]; then
    echo "[$LOG_PREFIX] lane-report running_parameterized_cases_at_timeout=none"
    return 0
  fi
  while IFS= read -r running_case_id; do
    [ -n "$running_case_id" ] || continue
    echo "[$LOG_PREFIX] lane-report running_parameterized_cases_at_timeout=$running_case_id"
  done <<<"$running_case_ids"
}

# Each run_swift_with_timeout invocation appends its own peaks here; the lane
# reports the maximum. Appending (rather than read-modify-write) keeps the
# isolated phase's concurrent subshells from racing each other.
swift_test_record_lane_peaks() {
  local output_file="$1"
  local event_stream_file="${2:-}"

  if [ -n "${SWIFT_TEST_PEAK_ANNOUNCED_FILE:-}" ]; then
    swift_test_peak_announced_from_output "$output_file" \
      >>"$SWIFT_TEST_PEAK_ANNOUNCED_FILE" 2>/dev/null || true
  fi
  if [ -n "${SWIFT_TEST_PEAK_RUNNING_FILE:-}" ] && [ -n "$event_stream_file" ]; then
    swift_test_peak_running_cases_from_events "$event_stream_file" \
      >>"$SWIFT_TEST_PEAK_RUNNING_FILE" 2>/dev/null || true
  fi
}

swift_test_peak_total_from_file() {
  local peak_file="${1:-}"

  if [ -z "$peak_file" ] || [ ! -s "$peak_file" ]; then
    echo 0
    return 0
  fi
  /usr/bin/awk 'BEGIN { peak = 0 } $1 + 0 > peak { peak = $1 + 0 } END { print peak }' "$peak_file"
}

# Lane receipt identity: which tree and which test bundle a lane tested.
#
# A green lane is evidence only about the tree its bundle was built from. A bundle
# built from uncommitted changes, from another commit, or by nobody this receipt
# can name can pass while the commit under review would not, so such a receipt
# marks itself invalid and never prints a pass verdict. The exit status stays the
# lane's own: the local edit-test loop keeps working, it just cannot claim a pass.
#
# A lane that reuses a bundle (SWIFT_TEST_SKIP_PREBUILD=1, as every CI lane does
# after its prebuild step) is linked to the build receipt the prebuild published
# beside the bundle, and is valid only when that receipt names this commit, a
# clean build tree, and the exact executable the lane runs.

# The tested tree's commit, or `unknown` outside a git checkout.
lane_receipt_head_sha() {
  git rev-parse HEAD 2>/dev/null || echo unknown
}

# `true` when the tree has uncommitted or untracked changes, `false` when it has
# none, and `unknown` when git cannot say.
lane_receipt_tree_dirty() {
  local porcelain

  if ! porcelain="$(git status --porcelain 2>/dev/null)"; then
    echo unknown
    return 0
  fi
  if [ -n "$porcelain" ]; then
    echo true
  else
    echo false
  fi
}

# The tree state a closing receipt reports. A tree that was dirty at the opening,
# or that changed commit or picked up edits while the lane ran, is not the tree
# the opening receipt named.
lane_receipt_tree_dirty_since() {
  local opening_head_sha="$1"
  local opening_tree_dirty="$2"

  if [ "$opening_tree_dirty" != "false" ]; then
    echo "$opening_tree_dirty"
    return 0
  fi
  if [ "$(lane_receipt_head_sha)" != "$opening_head_sha" ]; then
    echo true
    return 0
  fi
  lane_receipt_tree_dirty
}

# The exact test executable the lanes run, as `<path>@<size bytes>@<modification
# epoch seconds>`, or `missing`. Two receipts that print the same identity tested
# the same built executable.
lane_receipt_bundle_identity() {
  local test_bundle
  local size_and_modification

  test_bundle="$(swift_testing_bundle_path 2>/dev/null)" || { echo missing; return 0; }
  size_and_modification="$(stat -f '%z@%m' "$test_bundle" 2>/dev/null)" || { echo missing; return 0; }
  echo "$test_bundle@$size_and_modification"
}

# Where the prebuild publishes its build receipt: beside the bundle, in the
# build path the lanes read, so a lane can only ever find its own slot's.
lane_build_receipt_path() {
  echo "$BUILD_PATH/agentstudio-test-build-receipt"
}

# Builds the test bundles and publishes the build receipt that links later lanes
# to this build. In this order, so no receipt can outlive or misdescribe a build:
#   1. delete the slot's receipt, so a failed or interrupted build leaves none;
#   2. sample the commit and tree state before compiling;
#   3. publish only after the build succeeded, by atomic rename.
prebuild_swift_tests_with_build_receipt() {
  local build_receipt
  local build_head_sha
  local build_tree_dirty
  local staged_receipt

  build_receipt="$(lane_build_receipt_path)"
  rm -f "$build_receipt"
  build_head_sha="$(lane_receipt_head_sha)"
  build_tree_dirty="$(lane_receipt_tree_dirty)"

  prebuild_swift_tests || return $?

  staged_receipt="$(mktemp "$build_receipt.XXXXXX")"
  printf 'bundle_identity=%s\nhead_sha=%s\ntree_dirty=%s\n' \
    "$(lane_receipt_bundle_identity)" "$build_head_sha" "$build_tree_dirty" >"$staged_receipt"
  mv -f "$staged_receipt" "$build_receipt"
}

# One field of a build receipt, or a non-zero status when the receipt or the
# field is absent or empty.
lane_build_receipt_field() {
  local build_receipt="$1"
  local field_name="$2"

  [ -r "$build_receipt" ] || return 1
  /usr/bin/awk -v field_name="$field_name" '
    index($0, field_name "=") == 1 && length($0) > length(field_name) + 1 {
      print substr($0, length(field_name) + 2)
      found = 1
      exit
    }
    END { exit !found }
  ' "$build_receipt"
}

# Why a reused bundle is NOT linked to a clean build of this commit, or nothing
# when it is:
#   reused_bundle_unlinked  no receipt, a malformed one, or one naming another executable
#   built_from_dirty_tree   the receipt says the build tree had uncommitted changes
#   bundle_head_mismatch    the receipt names another commit
lane_build_receipt_link_reason() {
  local build_receipt="$1"
  local current_head_sha="$2"
  local current_bundle_identity="$3"
  local recorded_bundle_identity
  local recorded_head_sha
  local recorded_tree_dirty

  if ! recorded_bundle_identity="$(lane_build_receipt_field "$build_receipt" bundle_identity)" ||
    ! recorded_head_sha="$(lane_build_receipt_field "$build_receipt" head_sha)" ||
    ! recorded_tree_dirty="$(lane_build_receipt_field "$build_receipt" tree_dirty)"
  then
    echo reused_bundle_unlinked
    return 0
  fi
  case "$recorded_tree_dirty" in
    false) ;;
    true | unknown)
      echo built_from_dirty_tree
      return 0
      ;;
    *)
      echo reused_bundle_unlinked
      return 0
      ;;
  esac
  if [ "$recorded_head_sha" != "$current_head_sha" ]; then
    echo bundle_head_mismatch
    return 0
  fi
  if [ "$current_bundle_identity" = "missing" ] || [ "$recorded_bundle_identity" != "$current_bundle_identity" ]; then
    echo reused_bundle_unlinked
  fi
}

# Why a receipt is invalid, comma-separated, or nothing when it is valid.
#   bundle_state: fresh (this invocation's prebuild ran and succeeded),
#                 reused (the prebuild was skipped; valid only when linked),
#                 not_built (it failed or never ran)
#   bundle_link_reason: lane_build_receipt_link_reason's verdict for a reused bundle
lane_receipt_invalid_reasons() {
  local bundle_state="$1"
  local tree_dirty="$2"
  local bundle_link_reason="${3:-}"
  local reasons=()

  case "$bundle_state" in
    fresh) ;;
    reused) [ -z "$bundle_link_reason" ] || reasons+=("$bundle_link_reason") ;;
    *) reasons+=(unbuilt_bundle) ;;
  esac
  case "$tree_dirty" in
    false) ;;
    true) reasons+=(dirty_tree) ;;
    *) reasons+=(unknown_tree) ;;
  esac

  local IFS=','
  printf '%s' "${reasons[*]:-}"
}

# The closing receipt's validity and verdict lines. Only a valid receipt carries
# a pass or fail verdict; an invalid one is `unverified` whatever the exit status.
print_lane_receipt_verdict() {
  local exit_status="$1"
  local bundle_state="$2"
  local tree_dirty="$3"
  local bundle_link_reason="${4:-}"
  local invalid_reasons

  invalid_reasons="$(lane_receipt_invalid_reasons "$bundle_state" "$tree_dirty" "$bundle_link_reason")"
  if [ -n "$invalid_reasons" ]; then
    echo "[$LOG_PREFIX] lane-report receipt_valid=false reason=$invalid_reasons"
    echo "[$LOG_PREFIX] lane-report verdict=unverified"
    return 0
  fi
  echo "[$LOG_PREFIX] lane-report receipt_valid=true"
  if [ "$exit_status" -eq 0 ]; then
    echo "[$LOG_PREFIX] lane-report verdict=pass"
  else
    echo "[$LOG_PREFIX] lane-report verdict=fail"
  fi
}

# swift build (the prebuild) rejects the Swift Testing event-stream flags; every
# other run_swift_with_timeout caller is a test invocation that accepts them.
swift_test_command_accepts_event_stream() {
  local argument

  for argument in "$@"; do
    if [ "$argument" = "build" ]; then
      return 1
    fi
  done
  return 0
}

swift_test_suite_lane_inventory() {
  cat <<'EOF'
fast|AgentStudioFileViewStartupDiagnosticTests|concurrent
large|AgentStudioGitDependencyTests|concurrent
large|AgentStudioIPCPhaseASmokeScriptTests|concurrent
large|AgentStudioOTLPBootstrapSmokeTests|process-global
fast|AgentStudioStartupDiagnosticActionParsingTests|concurrent
fast|AgentStudioStartupDiagnosticActionTests|concurrent
fast|AgentStudioTraceConfigurationTests|concurrent
large|AppIPCDeferredInitializationIntegrationTests|process-global
large|AppIPCProductionLifecycleIntegrationTests|process-global
large|ArchitectureSwiftLintRulesTests|concurrent
large|AtomLibCompileFailureScriptTests|concurrent
large|BridgeBrowserNativeRPCCutoverSourceScanTests|concurrent
large|BridgeCapacityIntegrationTests|concurrent
large|BridgeFullPyramidSmokeVerifierScriptTests|concurrent
large|BridgeHeadlessManifestVerifierScriptTests|concurrent
large|BridgeObservabilitySmokeReviewSourceProviderTests|concurrent
large|BridgeObservabilityVerifierScriptTests|concurrent
large|BridgePackagedCompleteJourneyScriptTests|concurrent
large|BridgePackagedProductJourneyScriptTests|serial
fast|BridgePaneSurfaceSelectionContractTests|concurrent
large|BridgeProductAdmissionIntegrationTests|concurrent
large|BridgeProductMetadataCatalogNativeIntegrationTests|concurrent
large|BridgeProductPaintCorrelationVerifierScriptTests|concurrent
fast|BridgeProductSessionContractTests|concurrent
large|BridgeProductStreamFeasibilityScriptTests|concurrent
fast|BridgeReviewFileClassifierTests|concurrent
large|BridgeReviewSmokeFrameLivenessTests|concurrent
large|BridgeWorktreeRefreshSessionTests|concurrent
large|CIFastLaneWorkflowTests|concurrent
large|CIFirstAttemptGateWorkflowTests|concurrent
large|CISwiftBuildCachePublishScriptTests|concurrent
large|CISwiftBuildInputsScriptTests|concurrent
benchmark|CommandBarSearchBenchmarkTests|process-global
large|CursorPackageInstallerTests|concurrent
large|DarwinCompositeFSEventContinuityTests|process-global
large|DarwinFSEventStreamClientTests|process-global
large|DarwinSharedExactItemObserverTests|process-global
large|DarwinSharedExactItemRealStreamIntegrationTests|process-global
large|DarwinSharedLocalFSEventObserverFailureTests|process-global
large|DarwinSharedLocalFSEventObserverTests|process-global
large|DerivedActivityNotificationIntegrationTests|process-global
large|DerivedTerminalActivityNotificationRegressionTests|process-global
large|DrawerCommandIntegrationTests|process-global
large|DrawerZoomFrameCurrencyIntegrationTests|process-global
e2e|E2ESerializedTests|serial
e2e|E2ESerializedTests/FilesystemSourceE2ETests|serial
e2e|E2ESerializedTests/ZmxBackendIntegrationTests|serial
zmx|E2ESerializedTests/ZmxE2ETests|serial
large|ExpectationLogTests|process-global
large|FilesystemActorActivityTests|process-global
large|FilesystemActorShellGitIntegrationTests|concurrent
large|FilesystemFetchHeadGitPipelineIntegrationTests|process-global
large|FilesystemGitPipelineDemandIntegrationTests|process-global
large|FilesystemGitPipelineIntegrationTests|process-global
large|FilesystemGitPipelineObservationLifetimeTests|process-global
large|FilesystemGitPipelineRegistrationTests|process-global
fast|FilesystemGitRemoteReferenceTests|process-global
large|FilesystemPipelineScopeOrderingTests|process-global
large|FilesystemToPrimarySidebarIntegrationTests|process-global
large|GitEnrichmentEventPipelineIntegrationTests|process-global
large|GitRefreshPerformanceComparatorScriptTests|concurrent
large|GitRefreshPerformanceWorkloadScriptTests|serial
large|GitRefreshPerformanceWorkloadSettlementScriptTests|concurrent
benchmark|GlobalPreferencesBootstrapBenchmarkTests|serial
large|HomebrewBetaReleaseScriptsTests|concurrent
large|MainWindowControllerInboxToolbarButtonTests|process-global
large|MinimizeLayoutIntegrationTests|process-global
large|NotificationOSCSmokeVerifierTests|concurrent
large|ObservabilityBetaLauncherDuplicateRuntimeTests|concurrent
large|ObservabilityBetaLauncherScriptsTests|concurrent
large|ObservabilityDebugBridgeLaunchScriptsTests|concurrent
large|ObservabilityDebugCandidateLifecycleScriptTests|concurrent
large|ObservabilityDebugIPCLaunchScriptTests|concurrent
large|ObservabilityDebugLaunchMetadataScriptTests|concurrent
large|ObservabilityDebugLaunchScriptVerifierTests|concurrent
large|ObservabilityDebugLaunchScriptsTests|concurrent
large|ObservabilityDebugLaunchServicesSmokeTaskTests|concurrent
large|ObservabilityDebugLaunchZmxIsolationTests|concurrent
large|ObservabilityDebugPaneAssociationProofTests|concurrent
large|ObservabilityDebugVerifierBridgeDiagnosticTests|concurrent
large|ObservabilityDebugVerifierScriptsTests|concurrent
large|ObservabilityLaunchScriptsTests|concurrent
large|ObservabilityPreferencesLaunchScriptsTests|concurrent
large|ObservabilityTCCProbeLauncherScriptsTests|concurrent
large|ObservabilityTCCProbeReportScriptTests|concurrent
large|ObservabilityTCCProtectedDataVerifierScriptTests|concurrent
large|ObservabilityTCCReplacementExperimentScriptTests|concurrent
large|PerformanceReportScriptTests|concurrent
large|PrimarySidebarPipelineIntegrationTests|concurrent
large|ProcessExecutorTests|concurrent
large|RendererPopulationScriptTests|concurrent
large|RepoExplorerFilterFocusIntegrationTests|process-global
large|RepoExplorerListKeyboardIntegrationTests|process-global
benchmark|RepoExplorerNativeTablePilotBenchmarkTests|serial
large|RepoScannerGitDiscoveryReadOnlyIntegrationTests|concurrent
large|RepositoryCacheSaveLifetimeTests|process-global
large|RepositoryCrossScopeFamilyClaimTests|process-global
large|RepositoryDiscoveryLifecyclePersistenceTests|process-global
large|RepositoryNestedDiscoveryContinuityTests|process-global
large|RepositoryRetentionCommitBoundaryRecoveryTests|process-global
large|RepositoryRetentionPipelineTests|process-global
large|RepositoryRetentionPublicationAdmissionTests|process-global
large|RepositoryRetentionReparentedFamilyTests|process-global
large|RepositoryRetentionSourceAdmissionTests|process-global
fast|SQLiteDatabaseFactoryProcessTests|process-global
large|SidebarPerformanceContinuityControlScriptTests|concurrent
large|SidebarPerformanceFixtureParserScriptTests|concurrent
large|SidebarPerformancePolicyParserScriptTests|concurrent
large|SidebarPerformanceWorkloadScriptTests|serial
large|SidebarPerformanceWorkloadSettlementScriptTests|serial
large|StartupPerformanceWorkloadScriptTests|concurrent
large|SurfaceRendererVisibilityIntegrationTests|process-global
fast|SwiftBuildSlotScriptTests|concurrent
large|SwiftLaneHangEvidenceTests|concurrent
large|SwiftLaneIsolationListGateTests|concurrent
large|SwiftLaneReceiptTests|concurrent
large|SwiftLaneRunnerReportTests|concurrent
large|SwiftPackageSandboxScriptTests|concurrent
large|TerminalActivityAgentSettledHeuristicTests|process-global
large|TitlePanePerformanceWorkloadScriptTests|concurrent
large|TopologyEventPipelineIntegrationTests|process-global
large|TopologyRuntimeScopeFeedbackTests|process-global
large|VendorConsumerWiringScriptTests|concurrent
large|VendorWorktreeScriptTests|concurrent
large|WatchedFolderObservationCurrentnessTests|concurrent
large|WatchedFolderPublicationHoldIntegrationTests|concurrent
fast|WebInteractionManagementScriptTests|concurrent
webkit|WebKitSerializedTests|serial
webkit|WebKitSerializedTests/BridgeContentWorldIsolationTests|serial
webkit|WebKitSerializedTests/BridgeTransportIntegrationTests|serial
webkit|WebKitSerializedTests/BridgeWebKitSpikeTests|serial
webkit|WebKitSerializedTests/WorkspaceBridgeConstructionIntegrationTests|serial
webkit|WebKitSerializedTests/WorkspaceBridgePaneActivityIntegrationTests|serial
webkit|WebKitSerializedTests/WorkspaceBridgePaneRefreshIntegrationTests|serial
large|WorktreeDefaultStartPointResolverIntegrationTests|concurrent
large|WorkspaceCacheCoordinatorIntegrationTests|process-global
large|WorkspaceDrawerRestoreIntegrationTests|process-global
large|WorkspaceGeometryReevaluationIntegrationTests|process-global
large|WorkspaceProjectedDividerResizeIntegrationTests|process-global
large|WorkspaceStrictStartupSubprocessTests|process-global
large|WorkspaceSurfaceCoordinatorFilesystemSourceTests|process-global
large|WorkspaceSurfaceTerminalRestoreIntegrationTests|process-global
large|WorkspaceTopologyBootRepairIntegrationTests|process-global
large|WorkspaceUndoDeadlineIntegrationTests|process-global
large|ZmxStartupTraceAnalyzerTests|concurrent
EOF
}

swift_test_lane_suite_types() {
  local requested_lane="${1:-}"
  local requested_mode="${2:-}"
  local inventory="${3:-}"
  local lane suite_type mode
  local matching_inventory_rows=0
  local -a suite_types=()

  if [ "$#" -lt 3 ]; then
    if ! inventory="$(swift_test_suite_lane_inventory)"; then
      printf '[test] failed to generate suite inventory for lane=%s\n' "$requested_lane" >&2
      return 1
    fi
  fi

  while IFS='|' read -r lane suite_type mode; do
    [ "$lane" = "$requested_lane" ] || continue
    [ -z "$requested_mode" ] || [ "$mode" = "$requested_mode" ] || continue
    matching_inventory_rows=$((matching_inventory_rows + 1))
    suite_types+=("$suite_type")
  done <<<"$inventory"

  if [ "${#suite_types[@]}" -ne "$matching_inventory_rows" ]; then
    printf '[test] lane suite inventory mismatch lane=%s mode=%s expected_suite_types=%s emitted_suite_types=%s\n' \
      "$requested_lane" "${requested_mode:-all}" "$matching_inventory_rows" "${#suite_types[@]}" >&2
    return 1
  fi

  if [ "${#suite_types[@]}" -gt 0 ]; then
    if ! printf '%s\n' "${suite_types[@]}"; then
      printf '[test] failed to write complete suite list for lane=%s mode=%s\n' \
        "$requested_lane" "${requested_mode:-all}" >&2
      return 1
    fi
  fi
  return 0
}

swift_test_lane_suite_types_match_inventory() {
  local requested_lane="${1:-}"
  local requested_mode="${2:-}"
  local inventory="${3:-}"
  local suite_types_output="${4:-}"
  local lane suite_type mode
  local matching_inventory_rows=0
  local emitted_suite_type_count=0

  while IFS='|' read -r lane suite_type mode; do
    [ "$lane" = "$requested_lane" ] || continue
    [ -z "$requested_mode" ] || [ "$mode" = "$requested_mode" ] || continue
    matching_inventory_rows=$((matching_inventory_rows + 1))
  done <<<"$inventory"

  while IFS= read -r suite_type; do
    [ -n "$suite_type" ] || continue
    emitted_suite_type_count=$((emitted_suite_type_count + 1))
  done <<<"$suite_types_output"

  if [ "$emitted_suite_type_count" -ne "$matching_inventory_rows" ]; then
    printf '[test] lane suite inventory mismatch lane=%s mode=%s expected_suite_types=%s emitted_suite_types=%s\n' \
      "$requested_lane" "${requested_mode:-all}" "$matching_inventory_rows" "$emitted_suite_type_count" >&2
    return 1
  fi
  return 0
}

swift_test_lane_filter_pattern() {
  local requested_lane="${1:-}"
  local requested_mode="${2:-}"
  local inventory suite_type
  local suite_type_output
  local suite_type_filters=""
  local filter_separator=""

  if ! inventory="$(swift_test_suite_lane_inventory)"; then
    printf '[test] failed to generate suite inventory for lane=%s\n' "$requested_lane" >&2
    return 1
  fi

  if ! suite_type_output="$(swift_test_lane_suite_types "$requested_lane" "$requested_mode" "$inventory")"; then
    return 1
  fi
  if ! swift_test_lane_suite_types_match_inventory \
    "$requested_lane" "$requested_mode" "$inventory" "$suite_type_output"; then
    return 1
  fi

  while IFS= read -r suite_type; do
    [ -n "$suite_type" ] || continue
    suite_type_filters="$suite_type_filters$filter_separator$(swift_test_isolated_suite_filter_pattern "$suite_type")"
    filter_separator='|'
  done <<<"$suite_type_output"

  if [ -n "$suite_type_filters" ] && ! printf '%s' "$suite_type_filters"; then
    printf '[test] failed to write complete filter pattern for lane=%s mode=%s\n' \
      "$requested_lane" "${requested_mode:-all}" >&2
    return 1
  fi
}

swift_test_lane_filter_exclusion_pattern() {
  local requested_lane="${1:-}"
  local inventory requested_suite_types_output
  local lane suite_type mode requested_suite_type
  local is_ancestor
  local -a requested_suite_types=()
  local -a excluded_suite_filters=()

  if ! inventory="$(swift_test_suite_lane_inventory)"; then
    printf '[test] failed to generate exclusions for lane=%s\n' "$requested_lane" >&2
    return 1
  fi

  if ! requested_suite_types_output="$(swift_test_lane_suite_types "$requested_lane" "" "$inventory")"; then
    return 1
  fi
  if ! swift_test_lane_suite_types_match_inventory \
    "$requested_lane" "" "$inventory" "$requested_suite_types_output"; then
    return 1
  fi

  while IFS= read -r requested_suite_type; do
    [ -n "$requested_suite_type" ] || continue
    requested_suite_types+=("$requested_suite_type")
  done <<<"$requested_suite_types_output"

  while IFS='|' read -r lane suite_type mode; do
    [ "$lane" = "$requested_lane" ] && continue
    is_ancestor=0
    for requested_suite_type in "${requested_suite_types[@]}"; do
      case "$requested_suite_type" in
        "$suite_type"/*)
          is_ancestor=1
          break
          ;;
      esac
    done
    [ "$is_ancestor" -eq 1 ] && continue
    excluded_suite_filters+=("$(swift_test_isolated_suite_filter_pattern "$suite_type")")
  done <<<"$inventory"

  local IFS='|'
  printf '%s' "${excluded_suite_filters[*]}"
}

swift_test_lane_for_suite_type() {
  local requested_suite_type="${1:-}"
  local inventory
  local lane suite_type mode

  if ! inventory="$(swift_test_suite_lane_inventory)"; then
    printf '[test] failed to generate suite inventory while routing suite=%s\n' "$requested_suite_type" >&2
    return 1
  fi

  while IFS='|' read -r lane suite_type mode; do
    if [ "$suite_type" = "$requested_suite_type" ]; then
      if ! printf '%s\n' "$lane"; then
        printf '[test] failed to emit lane for suite=%s\n' "$requested_suite_type" >&2
        return 1
      fi
      return 0
    fi
  done <<<"$inventory"

  if ! printf '%s\n' fast; then
    printf '[test] failed to emit default lane for unlisted suite=%s\n' "$requested_suite_type" >&2
    return 1
  fi
  return 0
}

swift_test_lane_mode_for_suite_type() {
  local requested_suite_type="${1:-}"
  local inventory
  local lane suite_type mode

  if ! inventory="$(swift_test_suite_lane_inventory)"; then
    printf '[test] failed to generate suite inventory while finding mode for suite=%s\n' \
      "$requested_suite_type" >&2
    return 1
  fi

  while IFS='|' read -r lane suite_type mode; do
    if [ "$suite_type" = "$requested_suite_type" ]; then
      if ! printf '%s\n' "$mode"; then
        printf '[test] failed to emit lane mode for suite=%s\n' "$requested_suite_type" >&2
        return 1
      fi
      return 0
    fi
  done <<<"$inventory"

  return 1
}

swift_test_lane_is_fast_serial_or_unlisted() {
  local requested_suite_type="${1:-}"
  local inventory
  local lane suite_type mode
  local suite_was_listed=0

  if ! inventory="$(swift_test_suite_lane_inventory)"; then
    printf '[test] failed to classify suite lane=%s\n' "$requested_suite_type" >&2
    return 2
  fi

  while IFS='|' read -r lane suite_type mode; do
    [ "$suite_type" = "$requested_suite_type" ] || continue
    suite_was_listed=1
    break
  done <<<"$inventory"

  if [ "$suite_was_listed" -eq 0 ]; then
    return 0
  fi
  [ "$lane" = fast ] && [ "$mode" = serial ]
}

swift_test_lane_fast_concurrent_skip_pattern() {
  local inventory
  local lane suite_type mode
  local -a suite_type_filters=()
  local expected_suite_count=0
  local emitted_suite_count=0

  if ! inventory="$(swift_test_suite_lane_inventory)"; then
    printf '[test] failed to generate fast-lane skip inventory\n' >&2
    return 1
  fi

  while IFS='|' read -r lane suite_type mode; do
    if [ "$lane" != fast ] || [ "$mode" != concurrent ]; then
      expected_suite_count=$((expected_suite_count + 1))
      suite_type_filters+=("$(swift_test_isolated_suite_filter_pattern "$suite_type")")
      emitted_suite_count=$((emitted_suite_count + 1))
    fi
  done <<<"$inventory"

  if [ "$emitted_suite_count" -ne "$expected_suite_count" ]; then
    printf '[test] fast-lane skip inventory mismatch expected_suite_types=%s emitted_suite_types=%s\n' \
      "$expected_suite_count" "$emitted_suite_count" >&2
    return 1
  fi

  local IFS='|'
  if ! printf '%s' "${suite_type_filters[*]}"; then
    printf '[test] failed to emit fast-lane skip filters\n' >&2
    return 1
  fi
  return 0
}

large_non_webkit_filter_pattern() {
  swift_test_lane_filter_pattern large concurrent
}

large_serial_non_webkit_filter_pattern() {
  swift_test_lane_filter_pattern large serial
}

large_process_global_suite_filters() {
  if [ "$#" -gt 0 ]; then
    swift_test_lane_suite_types large process-global "$1"
  else
    swift_test_lane_suite_types large process-global
  fi
}

large_process_global_filter_pattern() {
  swift_test_lane_filter_pattern large process-global
}

serialized_main_actor_suite_pattern() {
  local annotation_order="$1"
  local declaration_modifiers='(?:(?:public|package|internal|fileprivate|private|open|final|indirect|nonisolated(?:\(unsafe\))?)\s+)*'
  local type_declaration_keywords='(?:class|struct|actor|enum|protocol|extension|typealias)'
  local declaration_boundary="${declaration_modifiers}${type_declaration_keywords}\\s"
  local suite_type_declaration="${declaration_modifiers}(?:class|struct)\\s+"
  local suite_arguments="(?:(?!\\n\\s*(?:@[A-Za-z]|${declaration_boundary}))[\\s\\S])*?"
  local suite_annotation="@Suite\\(${suite_arguments}\\.serialized\\b${suite_arguments}\\)"

  case "$annotation_order" in
    main-actor-first)
      printf '%s\n' "@MainActor\\s*\\n\\s*${suite_annotation}\\s*\\n\\s*${suite_type_declaration}([A-Za-z0-9_]+)"
      ;;
    suite-first)
      printf '%s\n' "${suite_annotation}\\s*\\n\\s*@MainActor\\s*\\n\\s*${suite_type_declaration}([A-Za-z0-9_]+)"
      ;;
    *)
      echo "Unknown serialized suite annotation order: $annotation_order" >&2
      return 2
      ;;
  esac
}

serialized_main_actor_suite_matches() {
  local annotation_order="$1"
  local pattern
  pattern="$(serialized_main_actor_suite_pattern "$annotation_order")"

  SERIALIZED_SUITE_PATTERN="$pattern" find Tests/AgentStudioTests -type f -name '*.swift' \
    -exec /usr/bin/perl -0777 -ne '
      BEGIN { $pattern = qr/$ENV{"SERIALIZED_SUITE_PATTERN"}/; }
      while ($_ =~ /$pattern/g) { print "$ARGV:$1\n"; }
    ' {} +
}

serialized_main_actor_suite_names_from_stdin() {
  local annotation_order="$1"
  local pattern
  pattern="$(serialized_main_actor_suite_pattern "$annotation_order")"

  SERIALIZED_SUITE_PATTERN="$pattern" /usr/bin/perl -0777 -ne '
    BEGIN { $pattern = qr/$ENV{"SERIALIZED_SUITE_PATTERN"}/; }
    while ($_ =~ /$pattern/g) { print "$1\n"; }
  '
}

# The ordinary lanes skip these parents by exact type name. Nested children live
# in `extension E2ESerializedTests` files; a name that merely contains E2E or
# Zmx is not a dedicated-lane suite.
is_dedicated_e2e_or_zmx_lane_suite() {
  local source_file="$1"
  local suite_name="$2"
  case "$suite_name" in
    E2ESerializedTests|ZmxE2ETests) return 0 ;;
  esac
  grep -Eq '(^|[[:space:]])extension[[:space:]]+E2ESerializedTests([^[:alnum:]_]|$)' "$source_file"
}

aggregate_serial_non_webkit_suite_filters() {
  # Permit formatted multiline Suite arguments, but never cross into the next
  # attribute or type declaration while searching for the serialized trait.
  local webkit_leaf_suite_pattern
  local main_actor_first_suite_pairs
  local suite_first_suite_pairs
  local additional_suite_pairs
  local suite_pairs
  local source_file suite_name
  local selected_suite_names=""
  local selected_suite_separator=""
  local selected_suite_output
  local classification_status

  if ! webkit_leaf_suite_pattern="$(webkit_leaf_suite_filters | /usr/bin/paste -sd'|' -)"; then
    echo "[test] failed to generate WebKit suite exclusions" >&2
    return 1
  fi
  if ! main_actor_first_suite_pairs="$(serialized_main_actor_suite_matches main-actor-first)"; then
    echo "[test] failed to discover MainActor-first serialized suites" >&2
    return 1
  fi
  if ! suite_first_suite_pairs="$(serialized_main_actor_suite_matches suite-first)"; then
    echo "[test] failed to discover Suite-first MainActor serialized suites" >&2
    return 1
  fi
  if ! additional_suite_pairs="$(
    printf '%s:%s\n' \
      'Tests/AgentStudioTests/Features/Terminal/State/TerminalActivityProjectorTests.swift' \
      'TerminalActivityProjectorTests'
    printf '%s:%s\n' \
      'Tests/AgentStudioTests/Core/PaneRuntime/Sources/GitWorkingDirectoryProjectorTests.swift' \
      'GitWorkingDirectoryProjectorTests'
    printf '%s:%s\n' \
      'Tests/AgentStudioBridgeDevelopmentServerTests/BridgeDevelopmentSeededWorktreeObservationTests.swift' \
      'BridgeDevelopmentSeededWorktreeObservationTests'
    printf '%s:%s\n' \
      'Tests/AgentStudioAppIPCTests/AgentStudioAppIPCServiceTests.swift' \
      'AgentStudioAppIPCServiceTests'
    printf '%s:%s\n' \
      'Tests/AgentStudioAppIPCTests/AgentStudioAppIPCServiceAuthModeTests.swift' \
      'AgentStudioAppIPCServiceAuthModeTests'
    printf '%s:%s\n' \
      'Tests/AgentStudioAppIPCTests/AgentStudioAppIPCServiceCommandTests.swift' \
      'AgentStudioAppIPCServiceCommandTests'
    printf '%s:%s\n' \
      'Tests/AgentStudioAppIPCTests/AgentStudioAppIPCServiceContributionTests.swift' \
      'AgentStudioAppIPCServiceContributionTests'
    printf '%s:%s\n' \
      'Tests/AgentStudioAppIPCTests/AgentStudioIPCBridgeServiceTests.swift' \
      'AgentStudioIPCBridgeServiceTests'
    printf '%s:%s\n' \
      'Tests/AgentStudioAppIPCTests/AgentStudioIPCBridgeServiceTests.swift' \
      'AgentStudioIPCBridgeRenderDiagnosticsTests'
    printf '%s:%s\n' \
      'Tests/AgentStudioAppIPCTests/AgentStudioIPCBridgeServiceTests.swift' \
      'AgentStudioIPCBridgeSearchModeTests'
    printf '%s:%s\n' \
      'Tests/AgentStudioAppIPCTests/AgentStudioIPCBridgeServiceTests.swift' \
      'AgentStudioIPCBridgeNonBridgeTargetTests'
    printf '%s:%s\n' \
      'Tests/AgentStudioAppIPCTests/AgentStudioIPCBridgeServiceTests.swift' \
      'AgentStudioIPCBridgeDiagnosticTargetTests'
    printf '%s:%s\n' \
      'Tests/AgentStudioAppIPCTests/AgentStudioIPCBridgeServiceTests.swift' \
      'AgentStudioIPCBridgePaneAgentTests'
    printf '%s:%s\n' \
      'Tests/AgentStudioAppIPCTests/AgentStudioIPCBridgeServiceTests.swift' \
      'AgentStudioIPCBridgeRejectedControlTests'
    printf '%s:%s\n' \
      'Tests/AgentStudioAppIPCTests/AgentStudioAppIPCCommandExecuteContractTests.swift' \
      'AgentStudioAppIPCCommandExecuteContractTests'
    printf '%s:%s\n' \
      'Tests/AgentStudioAppIPCTests/AppIPCDynamicCommandClientTests.swift' \
      'AppIPCDynamicCommandClientTests'
    printf '%s:%s\n' \
      'Tests/AgentStudioAppIPCTests/AppIPCErrorCorrectionTests.swift' \
      'AppIPCErrorCorrectionTests'
    printf '%s:%s\n' \
      'Tests/AgentStudioAppIPCTests/AgentStudioAppIPCConnectionHandlerLifecycleTests.swift' \
      'AgentStudioAppIPCConnectionHandlerLifecycleTests'
  )"; then
    echo "[test] failed to create explicit serialized-suite candidates" >&2
    return 1
  fi

  suite_pairs="$main_actor_first_suite_pairs
$suite_first_suite_pairs
$additional_suite_pairs"

  while IFS=: read -r source_file suite_name; do
    [ -n "$source_file" ] || continue
    case "$source_file" in
      *"/App/WebKit/"*) continue ;;
    esac
    if is_dedicated_e2e_or_zmx_lane_suite "$source_file" "$suite_name"; then
      continue
    fi
    if printf '%s\n' "$suite_name" | grep -Eq "^(${webkit_leaf_suite_pattern})$"; then
      continue
    fi
    if swift_test_lane_is_fast_serial_or_unlisted "$suite_name"; then
      :
    else
      classification_status=$?
      if [ "$classification_status" -eq 1 ]; then
        continue
      fi
      printf '[test] failed to classify suite for isolated non-WebKit lane suite=%s status=%s\n' \
        "$suite_name" "$classification_status" >&2
      return "$classification_status"
    fi
    selected_suite_names="$selected_suite_names$selected_suite_separator$suite_name"
    selected_suite_separator='
'
  done <<<"$suite_pairs"

  if ! selected_suite_output="$(printf '%s\n' "$selected_suite_names" | /usr/bin/sort -u)"; then
    echo "[test] failed to sort isolated non-WebKit suite membership" >&2
    return 1
  fi
  if [ -n "$selected_suite_output" ] && ! printf '%s\n' "$selected_suite_output"; then
    echo "[test] failed to emit isolated non-WebKit suite membership" >&2
    return 1
  fi
  return 0
}

aggregate_serial_non_webkit_filter_pattern() {
  local suite_types_output suite_type suite_filter
  local joined_filters=""
  local filter_separator=""

  if ! suite_types_output="$(aggregate_serial_non_webkit_suite_filters)"; then
    printf '[test] failed to generate aggregate serial non-WebKit suite filters\n' >&2
    return 1
  fi
  while IFS= read -r suite_type; do
    [ -n "$suite_type" ] || continue
    if ! suite_filter="$(swift_test_isolated_suite_filter_pattern "$suite_type")"; then
      printf '[test] failed to anchor aggregate serial suite filter suite=%s\n' "$suite_type" >&2
      return 1
    fi
    joined_filters="$joined_filters$filter_separator$suite_filter"
    filter_separator='|'
  done <<<"$suite_types_output"

  if [ -n "$joined_filters" ]; then
    if ! printf '%s' "$joined_filters"; then
      printf '[test] failed to emit aggregate serial non-WebKit suite filters\n' >&2
      return 1
    fi
  fi
  return 0
}

fast_serial_process_filter_pattern() {
  swift_test_lane_filter_pattern fast process-global
}

# Anchors a suite type path so `--filter`/`--skip` selects that type and nothing
# that merely lives in a file named after it. Nested suite paths use `/`.
#
# Swift Testing matches these as regexes with `contains` over the test's id, and a
# FUNCTION's id ends with its source location. Captured from a real event stream
# on this branch:
#   suite:    AgentStudioInfrastructureTests.RepoScannerTests
#   function: AgentStudioInfrastructureTests.RepoScannerTests/cloneRootGitdirIndirectionsOutsideScannedPathAreFilteredOut()/RepoScannerTests.swift:234:6
#   sibling:  AgentStudioInfrastructureTests.RepoScannerClassificationTests/gitDirectoryIsCloneRoot()/RepoScannerTests.swift:430:6
# The third id belongs to a DIFFERENT suite that happens to live in
# RepoScannerTests.swift, so the bare name `RepoScannerTests` selected it too:
# `--filter RepoScannerTests` admits 2 suites and 29 ids on this bundle. That is
# how two process-global suites ended up sharing one process and the process
# SIGSEGVed at exit (CI 35276671883).
#
# `\.<name>(/|$)` matches only the type component: the module separator `.` before
# it, and either the function separator `/` or end-of-id after it. A file
# component is always preceded by `/`, never `.`, so it can never match — and the
# leading `.` also stops a name matching a longer type it is a prefix of.
swift_test_isolated_suite_filter_pattern() {
  local suite_type_path="$1"
  local escaped_type_path

  # Escape every non-identifier character. Suite names are Swift identifiers
  # today; the anchor must not silently depend on that staying true.
  escaped_type_path="$(printf '%s' "$suite_type_path" | /usr/bin/sed 's/[^A-Za-z0-9_]/\\&/g')"
  printf '\\.%s(/|$)' "$escaped_type_path"
}

# The same anchor across a `|`-joined list of exact inventory paths or
# source-discovered suite type names.
swift_test_isolated_suite_skip_pattern() {
  local joined_type_names="${1:-}"
  local anchored_patterns=()
  local type_name
  local anchored_pattern
  local IFS='|'

  [ -n "$joined_type_names" ] || return 0
  for type_name in $joined_type_names; do
    [ -n "$type_name" ] || continue
    if ! anchored_pattern="$(swift_test_isolated_suite_filter_pattern "$type_name")"; then
      printf '[test] failed to anchor isolated suite skip filter suite=%s\n' "$type_name" >&2
      return 1
    fi
    anchored_patterns+=("$anchored_pattern")
  done
  printf '%s' "${anchored_patterns[*]}"
}

run_fast_serial_process_swift_tests() {
  local swift_test_bundle
  swift_test_bundle="$(swift_testing_bundle_path)"
  local swift_testing_helper
  swift_testing_helper="$(swift_testing_helper_path)"
  local testing_framework_path
  testing_framework_path="$(swift_testing_framework_path)"
  local lane_inventory fast_process_global_suite_output fast_process_global_suite_filter
  local lane suite_type mode
  local -a fast_process_global_suite_filters=()

  if ! lane_inventory="$(swift_test_suite_lane_inventory)"; then
    printf '[test] failed to generate fast process-global suite inventory\n' >&2
    return 1
  fi
  if ! fast_process_global_suite_output="$(swift_test_lane_suite_types fast process-global "$lane_inventory")"; then
    printf '[test] failed to generate fast process-global suite list\n' >&2
    return 1
  fi
  if ! swift_test_lane_suite_types_match_inventory \
    fast process-global "$lane_inventory" "$fast_process_global_suite_output"; then
    return 1
  fi
  while IFS= read -r fast_process_global_suite_filter; do
    [ -n "$fast_process_global_suite_filter" ] || continue
    fast_process_global_suite_filters+=("$fast_process_global_suite_filter")
  done <<<"$fast_process_global_suite_output"
  local timing_eligible_ms timing_batch=0
  timing_eligible_ms="$(lane_timing_now_ms 2>/dev/null || true)"

  for fast_process_global_suite_filter in "${fast_process_global_suite_filters[@]}"; do
    timing_batch=$((timing_batch + 1))
    LANE_TIMING_PHASE=fast-process-global LANE_TIMING_FILTER="$fast_process_global_suite_filter" \
      LANE_TIMING_BATCH="$timing_batch" LANE_TIMING_SLOT=1 \
      LANE_TIMING_ELIGIBLE_MS="$timing_eligible_ms" run_swift_with_timeout \
      "isolated fast process-global suite: $fast_process_global_suite_filter" \
      "$TIMEOUT_SECONDS" \
      env AGENT_STUDIO_BENCHMARK_MODE=off AGENTSTUDIO_TRACE_BACKEND="${SWIFT_TEST_TRACE_BACKEND:-jsonl}" $(swift_test_parallelization_env_word) \
      DYLD_FRAMEWORK_PATH="$testing_framework_path" \
      "$swift_testing_helper" --test-bundle-path "$swift_test_bundle" \
      --filter "$(swift_test_isolated_suite_filter_pattern "$fast_process_global_suite_filter")" \
      "$swift_test_bundle" --testing-library swift-testing
  done
}

prebuild_swift_tests() {
  if [ -n "${SWIFT_BUILD_STATS_DIR:-}" ]; then
    case "$SWIFT_BUILD_STATS_DIR" in
      /*)
        if mkdir -p "$SWIFT_BUILD_STATS_DIR" 2>/dev/null; then
          # shellcheck disable=SC2086
          run_swift_with_timeout \
            "prebuild test bundles" \
            "$PREBUILD_TIMEOUT_SECONDS" \
            swift build $(swift_package_sandbox_arguments) --build-tests ${EXTRA_SWIFT_TEST_ARGS:-} --build-path "$BUILD_PATH" \
            -Xswiftc -stats-output-dir -Xswiftc "$SWIFT_BUILD_STATS_DIR"
          return $?
        fi
        ;;
    esac
    echo "[$LOG_PREFIX] warning: compiler statistics disabled (directory must be writable and absolute)" >&2
  fi
  # shellcheck disable=SC2086
  run_swift_with_timeout \
    "prebuild test bundles" \
    "$PREBUILD_TIMEOUT_SECONDS" \
    swift build $(swift_package_sandbox_arguments) --build-tests ${EXTRA_SWIFT_TEST_ARGS:-} --build-path "$BUILD_PATH"
}

run_aggregate_serial_non_webkit_swift_tests() {
  local aggregate_serial_suite_filter
  local aggregate_serial_suite_filters
  local -a selected_filters=()

  if ! aggregate_serial_suite_filters="$(aggregate_serial_non_webkit_suite_filters)"; then
    printf '[test] failed to generate aggregate serial non-WebKit suite list\n' >&2
    return 1
  fi
  while IFS= read -r aggregate_serial_suite_filter; do
    [ -n "$aggregate_serial_suite_filter" ] || continue
    selected_filters+=("$aggregate_serial_suite_filter")
  done <<<"$aggregate_serial_suite_filters"
  dispatch_isolated_suites fast "${selected_filters[@]}"
}

run_large_process_global_swift_tests() {
  local lane_inventory large_process_global_suite_filter large_process_global_suite_output
  local -a large_process_global_suite_filters=()

  if ! lane_inventory="$(swift_test_suite_lane_inventory)"; then
    printf '[test] failed to generate large process-global suite inventory\n' >&2
    return 1
  fi
  if ! large_process_global_suite_output="$(large_process_global_suite_filters "$lane_inventory")"; then
    printf '[test] failed to generate large process-global suite list\n' >&2
    return 1
  fi
  if ! swift_test_lane_suite_types_match_inventory \
    large process-global "$lane_inventory" "$large_process_global_suite_output"; then
    return 1
  fi
  while IFS= read -r large_process_global_suite_filter; do
    [ -n "$large_process_global_suite_filter" ] || continue
    large_process_global_suite_filters+=("$large_process_global_suite_filter")
  done <<<"$large_process_global_suite_output"
  dispatch_isolated_suites large "${large_process_global_suite_filters[@]}"
}

swift_testing_bundle_path() {
  local test_bundle
  test_bundle="$(find "$BUILD_PATH" -type f -path '*/debug/AgentStudioPackageTests.xctest/Contents/MacOS/AgentStudioPackageTests' -print -quit)"
  if [ -z "$test_bundle" ]; then
    echo "Swift Testing bundle not found under $BUILD_PATH" >&2
    return 1
  fi
  printf '%s\n' "$test_bundle"
}

swift_testing_helper_path() {
  local swift_executable
  swift_executable="$(xcrun --find swift)"
  printf '%s/libexec/swift/pm/swiftpm-testing-helper\n' "$(dirname "$(dirname "$swift_executable")")"
}

swift_testing_framework_path() {
  local platform_path
  platform_path="$(xcrun --sdk macosx --show-sdk-platform-path)"
  printf '%s/Developer/Library/Frameworks\n' "$platform_path"
}

# Appends one failing isolated suite to the lane's tally. The lane reports every
# failure at the end rather than stopping at the first, so one crashed process
# cannot hide whether the suites after it would also have failed.
swift_test_record_failed_isolated_suite() {
  local suite_filter="$1"
  local status="$2"
  local signal_name="${3:-$(swift_test_signal_name "$status")}"

  [ -n "${SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE:-}" ] || return 0
  printf '%s\t%s\t%s\n' \
    "$suite_filter" "$status" "$signal_name" \
    >>"$SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE" 2>/dev/null || true
}

swift_test_failed_isolated_suite_count() {
  local tally_file="${SWIFT_TEST_FAILED_ISOLATED_SUITES_FILE:-}"

  if [ -z "$tally_file" ] || [ ! -s "$tally_file" ]; then
    echo 0
    return 0
  fi
  /usr/bin/awk 'END { print NR + 0 }' "$tally_file"
}

# The dispatcher reaps reporting subshells by PID. Each reporter waits for its
# wrapper, so a wrapper killed before publishing its worker status still has a
# terminal outcome. FIFO records are atomic (shorter than PIPE_BUF). Bash 3.2
# needs neither wait -n nor a signal trap interrupting a blocked FIFO read.
dispatch_isolated_suites() {
  local lane_kind="$1"
  shift
  [ "$#" -gt 0 ] || return 0
  local -a suite_filters=("$@") active_pids=() active_filters=()
  local concurrency next_filter=0 active_count=0 dispatch_ordinal=0
  local slot suite_filter reporter_pid completed_slot completed_pid completed_status completed_reason waited_status
  local lane_status=0 timing_eligible_ms dispatch_dir fifo_path
  if [ "$lane_kind" = webkit ]; then
    concurrency="$(swift_test_webkit_process_concurrency)"
    echo "[$LOG_PREFIX] WebKit process-global concurrency: $concurrency"
  else
    concurrency="$(swift_test_isolated_process_concurrency)"
    echo "[$LOG_PREFIX] isolated process-global concurrency: $concurrency"
  fi
  timing_eligible_ms="$(lane_timing_now_ms 2>/dev/null || true)"
  mkdir -p "$LANE_EVENT_STREAM_DIR"
  dispatch_dir="$(mktemp -d "${LANE_EVENT_STREAM_DIR:-${TMPDIR:-/tmp}}/agentstudio-isolated-dispatch.XXXXXX")"
  fifo_path="$dispatch_dir/completions"
  mkfifo "$fifo_path"
  exec 7<>"$fifo_path"
  SWIFT_TEST_ACTIVE_ISOLATED_PIDS=""

  while [ "$next_filter" -lt "${#suite_filters[@]}" ] || [ "$active_count" -gt 0 ]; do
    for ((slot=1; slot<=concurrency && next_filter<${#suite_filters[@]}; slot++)); do
      [ -z "${active_pids[$slot]:-}" ] || continue
      suite_filter="${suite_filters[$next_filter]}"
      next_filter=$((next_filter + 1))
      dispatch_ordinal=$((dispatch_ordinal + 1))
      (
        local child_status=0 completion_reason=completed worker_pid=""
        (
          # Keep the wrapper's Bash 3.2 PID handshake before worker launch.
          # The reporter, rather than this fallible wrapper, owns FIFO output.
          /bin/sh -c 'printf "%s\n" "$PPID"' >"$dispatch_dir/pid-$slot"
          read -r child_pid <"$dispatch_dir/pid-$slot"
          rm -f "$dispatch_dir/pid-$slot"
          export LANE_TIMING_PHASE="$lane_kind" LANE_TIMING_FILTER="$suite_filter" LANE_TIMING_BATCH="$dispatch_ordinal"
          export LANE_TIMING_SLOT="$slot" LANE_TIMING_CONCURRENCY="$concurrency"
          export LANE_TIMING_ELIGIBLE_MS="$timing_eligible_ms"
          local worker_status=0
          (run_selected_isolated_suite "$lane_kind" "$suite_filter") &
          local worker_pid=$!
          # If SIGKILL lands before this write, the reporter has no worker PID to reap.
          printf '%s\n' "$worker_pid" >"$dispatch_dir/worker-$slot"
          wait "$worker_pid" || worker_status=$?
          printf '%s\n' "$worker_status" >"$dispatch_dir/status-$slot"
          exit "$worker_status"
        ) &
        local reporting_child_pid=$!
        wait "$reporting_child_pid" || child_status=$?
        if [ ! -f "$dispatch_dir/status-$slot" ]; then
          completion_reason=wrapper_exited_without_completion
          if [ -r "$dispatch_dir/worker-$slot" ] && read -r worker_pid <"$dispatch_dir/worker-$slot"; then
            [ -z "$worker_pid" ] || terminate_lane_child_tree TERM "$worker_pid"
          fi
        fi
        rm -f "$dispatch_dir/pid-$slot" "$dispatch_dir/status-$slot" "$dispatch_dir/worker-$slot" || true
        # The writer's PPID is the reporter, including on Bash 3.2 where $$
        # still names the lane shell. No fallible reporter PID handshake.
        /bin/sh -c 'printf "%s %s %s %s\n" "$1" "$PPID" "$2" "$3"' \
          sh "$slot" "$child_status" "$completion_reason" >&7
        exit "$child_status"
      ) &
      reporter_pid=$!
      active_pids[$slot]="$reporter_pid"
      active_filters[$slot]="$suite_filter"
      SWIFT_TEST_ACTIVE_ISOLATED_PIDS="$SWIFT_TEST_ACTIVE_ISOLATED_PIDS $reporter_pid"
      active_count=$((active_count + 1))
    done

    if ! read -r -u 7 completed_slot completed_pid completed_status completed_reason; then
      lane_status=1
      break
    fi
    reporter_pid="${active_pids[$completed_slot]:-}"
    if [ -z "$reporter_pid" ] || [ "$reporter_pid" != "$completed_pid" ]; then
      echo "[$LOG_PREFIX] invalid isolated completion: slot=$completed_slot pid=$completed_pid" >&2
      lane_status=1
      break
    fi
    waited_status=0
    wait "$reporter_pid" || waited_status=$?
    suite_filter="${active_filters[$completed_slot]}"
    active_pids[$completed_slot]=""
    active_filters[$completed_slot]=""
    active_count=$((active_count - 1))
    SWIFT_TEST_ACTIVE_ISOLATED_PIDS=" ${active_pids[*]}"
    if [ "$completed_status" -ne 0 ] || [ "$waited_status" -ne "$completed_status" ] ||
      [ "$completed_reason" != completed ]; then
      lane_status=1
      if [ "$lane_kind" != webkit ] || [ "$completed_reason" != completed ]; then
        echo "[$LOG_PREFIX] isolated suite failed: $suite_filter" \
          "status=$completed_status signal=$(swift_test_signal_name "$completed_status") reason=$completed_reason" >&2
        swift_test_record_failed_isolated_suite "$suite_filter" "$completed_status"
      fi
    fi
  done

  if [ "$active_count" -gt 0 ]; then
    swift_test_terminate_active_isolated_suites
  fi
  SWIFT_TEST_ACTIVE_ISOLATED_PIDS=""
  exec 7>&-
  rm -f "$fifo_path"
  rmdir "$dispatch_dir"
  return "$lane_status"
}

run_selected_isolated_suite() {
  local lane_kind="$1" suite_filter="$2"
  if [ "$lane_kind" = webkit ]; then
    run_webkit_suite "$suite_filter"
    return $?
  fi
  local swift_test_bundle swift_testing_helper testing_framework_path
  local label="isolated process-global non-WebKit suite: $suite_filter"
  if [ "$lane_kind" = large ]; then
    label="isolated large process-global suite: $suite_filter"
  fi
  swift_test_bundle="$(swift_testing_bundle_path)"
  swift_testing_helper="$(swift_testing_helper_path)"
  testing_framework_path="$(swift_testing_framework_path)"
  run_swift_with_timeout \
    "$label" \
    "$TIMEOUT_SECONDS" \
    env AGENT_STUDIO_BENCHMARK_MODE=off AGENTSTUDIO_TRACE_BACKEND="${SWIFT_TEST_TRACE_BACKEND:-jsonl}" $(swift_test_parallelization_env_word) \
    DYLD_FRAMEWORK_PATH="$testing_framework_path" \
    "$swift_testing_helper" --test-bundle-path "$swift_test_bundle" \
    --filter "$(swift_test_isolated_suite_filter_pattern "$suite_filter")" \
    "$swift_test_bundle" --testing-library swift-testing
}

swift_test_terminate_active_isolated_suites() {
  local suite_pid
  for suite_pid in ${SWIFT_TEST_ACTIVE_ISOLATED_PIDS:-}; do
    terminate_lane_child_tree TERM "$suite_pid"
  done
  for suite_pid in ${SWIFT_TEST_ACTIVE_ISOLATED_PIDS:-}; do
    terminate_lane_child_tree KILL "$suite_pid"
    wait "$suite_pid" 2>/dev/null || true
  done
}

# The fast concurrent phase is the default lane minus the exact inventory rows
# that belong to another lane or to one of fast's isolated execution modes.
fast_non_webkit_skip_pattern() {
  local fast_lane_skip_filters aggregate_serial_skip_filters

  if ! fast_lane_skip_filters="$(swift_test_lane_fast_concurrent_skip_pattern)"; then
    printf '[test] failed to generate fast-lane concurrent skip filters\n' >&2
    return 1
  fi
  if ! aggregate_serial_skip_filters="$(aggregate_serial_non_webkit_filter_pattern)"; then
    return 1
  fi
  if ! printf '%s|%s' "$fast_lane_skip_filters" "$aggregate_serial_skip_filters"; then
    printf '[test] failed to emit fast-lane skip filter pattern\n' >&2
    return 1
  fi
  return 0
}

run_fast_non_webkit_swift_tests() {
  # Swift Testing provides in-process case concurrency, bounded by the explicit
  # SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH exported below. SwiftPM's
  # --parallel harness is not used for the fast inventory; suites that need a
  # process of their own get one from the isolated phases that follow.
  local fast_lane_skip_pattern
  if ! fast_lane_skip_pattern="$(fast_non_webkit_skip_pattern)"; then
    printf '[test] failed to prepare fast-lane skip pattern; no fast suites were started\n' >&2
    return 1
  fi

  run_swift_with_timeout \
    "native-concurrent fast non-WebKit suites" \
    "$TIMEOUT_SECONDS" \
    env AGENT_STUDIO_BENCHMARK_MODE=off AGENTSTUDIO_TRACE_BACKEND="${SWIFT_TEST_TRACE_BACKEND:-jsonl}" $(swift_test_parallelization_env_word) swift test $(swift_package_sandbox_arguments) ${EXTRA_SWIFT_TEST_ARGS:-} --skip-build \
    --skip "$fast_lane_skip_pattern" --build-path "$BUILD_PATH"

  run_aggregate_serial_non_webkit_swift_tests
  run_fast_serial_process_swift_tests
}

run_large_non_webkit_swift_tests() {
  local large_concurrent_filter_pattern large_serial_filter_pattern large_process_global_filter_pattern

  if ! large_concurrent_filter_pattern="$(large_non_webkit_filter_pattern)"; then
    printf '[test] failed to prepare large concurrent filter; no large suites were started\n' >&2
    return 1
  fi
  if ! large_serial_filter_pattern="$(large_serial_non_webkit_filter_pattern)"; then
    printf '[test] failed to prepare large serial filter; no large suites were started\n' >&2
    return 1
  fi
  if ! large_process_global_filter_pattern="$(large_process_global_filter_pattern)"; then
    printf '[test] failed to prepare large process-global filter; no large suites were started\n' >&2
    return 1
  fi

  if [ "${SWIFT_TEST_PARALLEL:-1}" = "1" ]; then
    local parallel_args=(--parallel)
    run_swift_with_timeout \
      "parallel large non-WebKit suites" \
      "$TIMEOUT_SECONDS" \
      env AGENT_STUDIO_BENCHMARK_MODE=off AGENTSTUDIO_TRACE_BACKEND="${SWIFT_TEST_TRACE_BACKEND:-jsonl}" $(swift_test_parallelization_env_word) swift test $(swift_package_sandbox_arguments) ${EXTRA_SWIFT_TEST_ARGS:-} --skip-build \
      "${parallel_args[@]}" \
      --filter "$large_concurrent_filter_pattern" \
      --skip "$large_serial_filter_pattern|$large_process_global_filter_pattern" \
      --build-path "$BUILD_PATH"

    run_swift_with_timeout \
      "serial large process suites" \
      "$TIMEOUT_SECONDS" \
      env AGENT_STUDIO_BENCHMARK_MODE=off AGENTSTUDIO_TRACE_BACKEND="${SWIFT_TEST_TRACE_BACKEND:-jsonl}" $(swift_test_parallelization_env_word) swift test $(swift_package_sandbox_arguments) ${EXTRA_SWIFT_TEST_ARGS:-} --skip-build \
      --filter "$large_serial_filter_pattern" \
      --build-path "$BUILD_PATH"
  else
    run_swift_with_timeout \
      "serial large non-WebKit suites" \
      "$TIMEOUT_SECONDS" \
      env AGENT_STUDIO_BENCHMARK_MODE=off AGENTSTUDIO_TRACE_BACKEND="${SWIFT_TEST_TRACE_BACKEND:-jsonl}" $(swift_test_parallelization_env_word) swift test $(swift_package_sandbox_arguments) ${EXTRA_SWIFT_TEST_ARGS:-} --skip-build \
      --filter "$large_concurrent_filter_pattern|$large_serial_filter_pattern" \
      --skip "$large_process_global_filter_pattern" \
      --build-path "$BUILD_PATH"
  fi

  run_large_process_global_swift_tests
}

webkit_suite_filters() {
  cat <<'EOF'
WebKitSerializedTests/BridgePaneControllerTests
WebKitSerializedTests/BridgePaneControllerContentAuthorityTests
WebKitSerializedTests/BridgePaneControllerInitialLoadTests
WebKitSerializedTests/BridgeSchemeHandlerSpikeTests
WebKitSerializedTests/BridgeContentWorldIsolationTests
WebKitSerializedTests/BridgePaneControllerIPCProjectionTests
WebKitSerializedTests/BridgePaneControllerRealGitReviewLoadTests
WebKitSerializedTests/BridgePaneControllerTelemetryTests
WebKitSerializedTests/BridgePaneProductActiveViewerModeTests
WebKitSerializedTests/BridgePaneProductActiveViewerModeTelemetryTests
WebKitSerializedTests/BridgeURLSchemeEnvelopeCapacityTests
WebKitSerializedTests/BridgeProductRealGitFileAndReviewWebKitTests
WebKitSerializedTests/BridgeReviewComparisonPresentationTests
WebKitSerializedTests/BridgeReviewContentStreamTransportTests
WebKitSerializedTests/WorkspaceSurfaceCoordinatorViewFactoryTests
WebKitSerializedTests/WorkspaceBridgeGitReadActivityOrderingTests
WebKitSerializedTests/WorkspaceBridgePaneRefreshIntegrationTests
WebKitSerializedTests/RepositoryBridgeObservationLifetimeTests
WebKitSerializedTests/WorkspaceBridgeConstructionIntegrationTests
WebKitSerializedTests/WorkspaceBridgePaneActivityIntegrationTests
WebKitSerializedTests/WorkspaceBridgePaneActivityRemediationTests
WebKitSerializedTests/WorkspaceSurfaceCoordinatorZoomCompanionTests
WebKitSerializedTests/WorkspaceSurfaceCoordinatorZoomLifecycleTests
WebKitSerializedTests/WorkspaceSurfaceCoordinatorZoomRecoveryTests
WebKitSerializedTests/WorkspaceHeldPreviewBridgeAdmissionTests
WebKitSerializedTests/PaneTabViewControllerBridgeCommandTests
WebKitSerializedTests/WorkspaceActionExecutorWebKitTests
WebKitSerializedTests/BridgePaneControllerProductBootstrapDeliveryTests
WebKitSerializedTests/BridgeTelemetryBootstrapDeliveryTests
WebKitSerializedTests/BridgeProductReviewIntakeLockOrderTests
WebKitSerializedTests/BridgeTransportIntegrationTests/test_bridgeReady_gatesAndIsIdempotent
WebKitSerializedTests/BridgeTransportIntegrationTests/test_teardown_resetsBridgeReady
WebKitSerializedTests/BridgeTransportIntegrationTests/test_schemeHandler_servesPackagedReactApp
WebKitSerializedTests/BridgeTransportIntegrationTests/test_handleDiffCommandWithSmokeProvider_rendersReviewViewerShell
WebKitSerializedTests/BridgeTransportIntegrationTests/test_sourceBackedInitialReviewLoad_rendersReviewViewerShell
WebKitSerializedTests/BridgeWebKitSpikeTests
WebKitSerializedTests/WebviewPaneControllerTests
WebKitSerializedTests/PreparedNonterminalContentMountTests
EOF
}

webkit_leaf_suite_filters() {
  webkit_suite_filters | awk -F/ 'NF >= 2 { print $2 }' | sort -u
}

run_webkit_suites() {
  echo "--- WebKit serialized tests (isolated processes) ---"
  local webkit_filters
  if ! webkit_filters="$(webkit_suite_filters)"; then
    echo "[test] failed to generate WebKit suite list" >&2
    return 1
  fi
  local -a selected_filters=()
  while IFS= read -r filter; do
    [ -n "$filter" ] || continue
    selected_filters+=("$filter")
  done <<<"$webkit_filters"
  dispatch_isolated_suites webkit "${selected_filters[@]}"
}

swift_test_watchdog_state() {
  local previous_output_size="$1"
  local current_output_size="$2"
  local previous_progress_epoch="$3"
  local current_epoch="$4"

  if [ "$current_output_size" -gt "$previous_output_size" ]; then
    printf '%s %s\n' "$current_output_size" "$current_epoch"
  else
    printf '%s %s\n' "$previous_output_size" "$previous_progress_epoch"
  fi
}

swift_test_watchdog_timeout_status() {
  local last_progress_epoch="$1"
  local current_epoch="$2"
  local timeout_seconds="$3"
  local inactive_seconds=$((current_epoch - last_progress_epoch))

  if [ "$inactive_seconds" -ge "$timeout_seconds" ]; then
    return 124
  fi
  return 0
}

# Epoch milliseconds share a clock domain across the wrapper and its child.
lane_timing_now_ms() {
  /usr/bin/perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'
}

write_lane_timing_sidecar() {
  local sidecar_path="$1" label="$2" child_timing_file="$3" dispatch_ms="$4"
  local wrapper_complete_ms="$5" timed_out="$6" event_stream_path="$7"
  local child_start_ms="" child_exit_ms="" child_status=""
  if [ -r "$child_timing_file" ]; then
    IFS=' ' read -r child_start_ms child_exit_ms child_status <"$child_timing_file" || true
  fi
  LANE_TIMING_LANE="${LOG_PREFIX:-unknown}" LANE_TIMING_LABEL="$label" \
    LANE_TIMING_DISPATCH="$dispatch_ms" LANE_TIMING_START="$child_start_ms" \
    LANE_TIMING_EXIT="$child_exit_ms" LANE_TIMING_STATUS="$child_status" \
    LANE_TIMING_COMPLETE="$wrapper_complete_ms" LANE_TIMING_TIMEOUT="$timed_out" \
    LANE_TIMING_CAP="${LANE_TIMING_CONCURRENCY:-}" \
    LANE_TIMING_PHASE="${LANE_TIMING_PHASE:-}" \
    LANE_TIMING_EVENT_FILE="$event_stream_path" \
    /usr/bin/perl -MJSON::PP -e '
      sub nullable_number { defined $_[0] && $_[0] =~ /^[0-9]+$/ ? 0 + $_[0] : undef }
      sub nullable_text { defined $_[0] && length $_[0] ? $_[0] : undef }
      my $record = {
        schema_version => 1, lane => $ENV{LANE_TIMING_LANE}, label => $ENV{LANE_TIMING_LABEL},
        phase => nullable_text($ENV{LANE_TIMING_PHASE}),
        filter => nullable_text($ENV{LANE_TIMING_FILTER}),
        batch_id => nullable_number($ENV{LANE_TIMING_BATCH}),
        slot => nullable_number($ENV{LANE_TIMING_SLOT}),
        slot_cap => nullable_number($ENV{LANE_TIMING_CAP}),
        eligible_ms => nullable_number($ENV{LANE_TIMING_ELIGIBLE_MS}),
        dispatch_ms => nullable_number($ENV{LANE_TIMING_DISPATCH}),
        command_start_ms => nullable_number($ENV{LANE_TIMING_START}),
        command_exit_ms => nullable_number($ENV{LANE_TIMING_EXIT}),
        command_status => nullable_number($ENV{LANE_TIMING_STATUS}),
        wrapper_complete_ms => nullable_number($ENV{LANE_TIMING_COMPLETE}),
        timed_out => $ENV{LANE_TIMING_TIMEOUT} eq "1" ? JSON::PP::true : JSON::PP::false,
        event_stream_file => nullable_text($ENV{LANE_TIMING_EVENT_FILE}),
      };
      print JSON::PP->new->canonical->encode($record), "\n";
    ' >"$sidecar_path" 2>/dev/null || \
    echo "[${LOG_PREFIX:-test}] warning: timing sidecar unavailable: $sidecar_path" >&2
  rm -f "$child_timing_file" || true
  return 0
}

run_swift_with_timeout() {
  local timing_dispatch_ms
  timing_dispatch_ms="$(lane_timing_now_ms 2>/dev/null || true)"
  local label="$1"
  shift
  local timeout_seconds="$1"
  shift

  echo "[$LOG_PREFIX] >>> $label (inactivity-timeout=${timeout_seconds}s)"
  local start_epoch
  start_epoch=$(date +%s)
  local last_heartbeat="$start_epoch"
  local last_progress_epoch="$start_epoch"
  local last_output_size=0
  local watchdog_state
  local timed_out=0

  local xcb_pipe
  xcb_pipe=$(_xcb_pipe_cmd)
  local output_file
  output_file="$(mktemp "${TMPDIR:-/tmp}/agentstudio-swift-test-output.XXXXXX")"

  # Both `swift test` and swiftpm-testing-helper accept these trailing flags on
  # Swift 6.3.3 (neither advertises them in --help).
  local event_stream_file=""
  local evidence_stem
  evidence_stem="$(lane_evidence_stem "$label")"
  mkdir -p "$LANE_EVENT_STREAM_DIR" 2>/dev/null || true
  local child_timing_file="$evidence_stem.child-timing"
  # The test process appends to this log through AGENTSTUDIO_HELD_STEP_LOG; it is
  # handed over as an absolute path because the test process's working directory
  # is not this script's to promise.
  local held_step_log=""
  if swift_test_command_accepts_event_stream "$@"; then
    event_stream_file="$(mktemp "${TMPDIR:-/tmp}/agentstudio-swift-test-events.XXXXXX")"
    set -- "$@" --event-stream-version 0 --event-stream-output-path "$event_stream_file"
    mkdir -p "$LANE_EVENT_STREAM_DIR"
    held_step_log="$evidence_stem.held-steps.log"
    case "$held_step_log" in
      /*) ;;
      *) held_step_log="$PWD/$held_step_log" ;;
    esac
    : >"$held_step_log"
  fi

  # Run command piped through xcbeautify in a subshell so we track one PID.
  # Subshell inherits pipefail from parent — swift exit code propagates.
  #
  # shellcheck disable=SC2086
  (
    if [ -n "$held_step_log" ]; then
      export AGENTSTUDIO_HELD_STEP_LOG="$held_step_log"
    fi
    local command_start_ms pipeline_result command_exit_ms
    local -a pipeline_status
    command_start_ms="$(lane_timing_now_ms 2>/dev/null || true)"
    set +e
    "$@" 2>&1 | tee "$output_file" | $xcb_pipe
    pipeline_result=$? pipeline_status=("${PIPESTATUS[@]}")
    command_exit_ms="$(lane_timing_now_ms 2>/dev/null || true)"
    printf '%s %s %s\n' "$command_start_ms" "$command_exit_ms" "${pipeline_status[0]}" \
      >"$child_timing_file" 2>/dev/null || true
    exit "$pipeline_result"
  ) &
  local command_pid=$!

  while kill -0 "$command_pid" 2>/dev/null; do
    sleep 1
    local now_epoch
    now_epoch=$(date +%s)
    local elapsed_seconds=$((now_epoch - start_epoch))
    local output_size
    output_size=$(wc -c <"$output_file" | tr -d '[:space:]')
    if ! watchdog_state="$(
      swift_test_watchdog_state \
        "$last_output_size" \
        "$output_size" \
        "$last_progress_epoch" \
        "$now_epoch"
    )"; then
      echo "[$LOG_PREFIX] lane-report watchdog state generation failed" >&2
      preserve_lane_event_stream "$label" "$event_stream_file" "$evidence_stem"
      terminate_lane_child_tree KILL "$command_pid"
      kill_lane_processes_by_run_token "$event_stream_file"
      wait "$command_pid" 2>/dev/null || true
      swift_test_record_lane_peaks "$output_file" "$event_stream_file"
      discard_empty_held_step_log "$held_step_log"
      rm -f "$output_file" ${event_stream_file:+"$event_stream_file"}
      local retained_event_stream=""
      [ -f "$evidence_stem.events.jsonl" ] && retained_event_stream="$evidence_stem.events.jsonl"
      write_lane_timing_sidecar "$evidence_stem.timing.json" "$label" "$child_timing_file" \
        "$timing_dispatch_ms" "$(lane_timing_now_ms 2>/dev/null || true)" "$timed_out" \
        "$retained_event_stream"
      return 1
    fi
    read -r last_output_size last_progress_epoch <<<"$watchdog_state"
    local inactive_seconds=$((now_epoch - last_progress_epoch))

    # Hang tests arm the watchdog only after their child is parked.
    if [ -z "${LANE_WATCHDOG_ARM_PATH:-}" ] || [ -e "$LANE_WATCHDOG_ARM_PATH" ]; then
      if ! swift_test_watchdog_timeout_status \
        "$last_progress_epoch" \
        "$now_epoch" \
        "$timeout_seconds"
      then
        timed_out=1
        break
      fi
    fi

    if [ $((now_epoch - last_heartbeat)) -ge 20 ]; then
      # A heartbeat write can fail with EINTR when the child exits mid-write; that is not a
      # test failure and must not abort the watchdog under `set -e`.
      echo "[$LOG_PREFIX] ... $label still running (${elapsed_seconds}s elapsed, ${inactive_seconds}s without output)" || true
      last_heartbeat="$now_epoch"
    fi
  done

  if [ "$timed_out" -eq 1 ]; then
    echo "[$LOG_PREFIX] ERROR: no output progress from '$label' for ${timeout_seconds}s"
    # Read the stream before terminating anything: this names what was still
    # executing at the timeout, not what survived the kill.
    print_running_parameterized_cases_at_timeout "$event_stream_file"
    print_held_steps_unarrived_at_timeout "$held_step_log" "$output_file"
    print_timeout_process_diagnostics "$label" "$command_pid" "$evidence_stem"
    echo "[$LOG_PREFIX] raw output tail for '$label':"
    tail -n 120 "$output_file" || true
    # Copy the ledger BEFORE anything is signalled, while the writer is still
    # alive: the child holds the stream open and a copy taken after termination
    # can miss records it had not flushed. Copying rather than moving also keeps
    # the writer's fd pointing at a file that still exists, which a
    # cross-filesystem move would not — it would leave the child appending to an
    # unlinked inode.
    preserve_lane_event_stream "$label" "$event_stream_file" "$evidence_stem"
    terminate_lane_child_tree TERM "$command_pid"
    # Writing the report IS the grace period. It is work the lane must do anyway,
    # so a child that honours TERM exits while it happens and no `sleep` has to
    # guess how long that takes.
    swift_test_record_lane_peaks "$output_file" "$event_stream_file"

    if lane_run_has_survivors "$command_pid" "$event_stream_file"; then
      terminate_lane_child_tree KILL "$command_pid"
      # The tree walk cannot see a survivor that re-parented, so sweep this run's
      # token as well. SIGKILL can be neither caught nor ignored, so the wait
      # below returns as soon as the kernel has finished teardown — however long
      # that takes on this machine. The only thing that could hold it is a
      # process wedged in an uninterruptible kernel wait, which is a kernel fault
      # outside this runner's remit and already covered by the job-level timeout.
      kill_lane_processes_by_run_token "$event_stream_file"
      wait "$command_pid" 2>/dev/null || true
      echo "[$LOG_PREFIX] lane-report timeout_reap=killed"
    else
      echo "[$LOG_PREFIX] lane-report timeout_reap=terminated"
      wait "$command_pid" 2>/dev/null || true
    fi
    discard_empty_held_step_log "$held_step_log"
    rm -f "$output_file" ${event_stream_file:+"$event_stream_file"}
    local retained_event_stream=""
    [ -f "$evidence_stem.events.jsonl" ] && retained_event_stream="$evidence_stem.events.jsonl"
    write_lane_timing_sidecar "$evidence_stem.timing.json" "$label" "$child_timing_file" \
      "$timing_dispatch_ms" "$(lane_timing_now_ms 2>/dev/null || true)" "$timed_out" \
      "$retained_event_stream"
    return 124
  fi

  set +e
  wait "$command_pid"
  local command_status=$?
  set -e
  local should_preserve_event_stream=0

  if [ "$command_status" -eq 0 ] && swift_test_output_has_failures "$output_file"; then
    echo "[$LOG_PREFIX] ERROR: '$label' emitted Swift Testing failure output despite exit 0" >&2
    command_status=1
  elif [ "$command_status" -ne 0 ] && ! swift_test_output_has_failures "$output_file"; then
    # A child that died without recording a Swift Testing failure — a signal, or a
    # runtime abort after its tests passed. Without this the lane printed only
    # "ERROR task failed" and bash's job-table line, and the reason was gone with
    # the output file.
    print_failed_child_diagnostics "$label" "$command_status" "$output_file"
    # Same reason as the timeout path: a child that died without recording a
    # Swift Testing failure leaves the event stream as the only record of what
    # had actually started, and console output cannot reconstruct it.
    should_preserve_event_stream=1
  fi

  swift_test_record_lane_peaks "$output_file" "$event_stream_file"
  # A width comparison compares what ran, so it keeps every ledger, passing or not.
  if [ "$should_preserve_event_stream" -eq 1 ] || [ "${LANE_EVENT_STREAM_RETAIN_ALWAYS:-0}" = "1" ]; then
    # Discarded first, so retention never sees this run's empty held-step log.
    discard_empty_held_step_log "$held_step_log"
    preserve_lane_event_stream "$label" "$event_stream_file" "$evidence_stem"
  elif [ -n "$held_step_log" ]; then
    # A run that ended cleanly has nothing to explain, so it keeps nothing.
    rm -f "$held_step_log"
  fi
  rm -f "$output_file" ${event_stream_file:+"$event_stream_file"}
  local retained_event_stream=""
  if [ "$should_preserve_event_stream" -eq 1 ] || [ "${LANE_EVENT_STREAM_RETAIN_ALWAYS:-0}" = "1" ]; then
    [ -f "$evidence_stem.events.jsonl" ] && retained_event_stream="$evidence_stem.events.jsonl"
  fi
  write_lane_timing_sidecar "$evidence_stem.timing.json" "$label" "$child_timing_file" \
    "$timing_dispatch_ms" "$(lane_timing_now_ms 2>/dev/null || true)" "$timed_out" \
    "$retained_event_stream"
  return "$command_status"
}

# The signal that killed a child, or `none` when the status is an ordinary exit
# code. Shells report a signalled child as 128 + signal number.
swift_test_signal_name() {
  local status="${1:-0}"

  if [ "$status" -gt 128 ]; then
    kill -l $((status - 128)) 2>/dev/null || echo "unknown"
  else
    echo none
  fi
}

# The signal that ended a test run: from the status when the child itself was
# signalled, else from `swift test`'s own report of a helper it lost to a signal
# ("unexpected signal code N"), which `swift test` exits 1 for. `none` otherwise.
swift_test_crash_signal_name() {
  local status="${1:-0}"
  local output="${2:-}"
  local reported_signal_code

  if [ "$status" -gt 128 ]; then
    swift_test_signal_name "$status"
    return 0
  fi
  if ! grep -Eq "unexpected signal code [0-9]+" <<<"$output"; then
    echo none
    return 0
  fi
  reported_signal_code="$(
    grep -Eo "unexpected signal code [0-9]+" <<<"$output" | grep -Eo "[0-9]+" | tail -n 1
  )"
  kill -l "$reported_signal_code" 2>/dev/null || echo unknown
}

# Mirrors the timeout branch's diagnostics for a child that exited non-zero
# without an ✘ marker, and must run BEFORE the captured output is deleted.
print_failed_child_diagnostics() {
  local label="$1"
  local status="$2"
  local output_file="$3"
  local signal_name
  signal_name="$(swift_test_signal_name "$status")"

  echo "[$LOG_PREFIX] ERROR: '$label' exited $status with no recorded test failure" >&2
  echo "[$LOG_PREFIX] exit_status=$status signal=$signal_name" >&2
  echo "[$LOG_PREFIX] raw output tail for '$label':" >&2
  tail -n 120 "$output_file" >&2 || true
}

swift_test_output_has_failures() {
  local output_file="$1"

  (
    set -o pipefail
    /usr/bin/iconv -f UTF-8 -t UTF-8 -c <"$output_file" |
      grep -Eq \
        '(^|[[:space:]])(✘|✖)[[:space:]]|recorded an issue|failed after [0-9.]+ seconds with [0-9]+ issue\(s\)|Test run with .* failed after|No matching test cases were run'
  )
}

print_timeout_process_diagnostics() {
  local label="$1"
  local root_pid="$2"
  local evidence_stem="${3:-$(lane_evidence_stem "$label")}"

  echo "[$LOG_PREFIX] process tree for timed out '$label' (root pid=$root_pid):"
  print_timeout_process_tree "$root_pid" 0
  print_timeout_process_snapshot "$label" "$root_pid"
  sample_stuck_swift_test_processes "$label" "$root_pid" "$evidence_stem"
}

print_timeout_process_tree() {
  local root_pid="$1"
  local indent_columns="$2"
  local process_command

  process_command="$(ps -p "$root_pid" -o command= 2>/dev/null || true)"
  [ -n "$process_command" ] || return 0
  printf '[%s] %*s%s %s\n' "$LOG_PREFIX" "$indent_columns" "" "$root_pid" "$process_command"

  local child_pid
  for child_pid in $(pgrep -P "$root_pid" 2>/dev/null || true); do
    print_timeout_process_tree "$child_pid" $((indent_columns + 2))
  done
}

print_timeout_process_snapshot() {
  local label="$1"
  local root_pid="$2"

  echo "[$LOG_PREFIX] ps snapshot for timed out '$label':"
  echo "[$LOG_PREFIX]   PID  PPID  PGID STAT ELAPSED COMMAND"

  local process_pid
  for process_pid in "$root_pid" $(descendant_process_pids "$root_pid"); do
    ps -o pid=,ppid=,pgid=,stat=,etime=,command= -p "$process_pid" 2>/dev/null |
      sed "s/^/[$LOG_PREFIX] /" || true
  done
}

descendant_process_pids() {
  local root_pid="$1"
  local child_pid

  for child_pid in $(pgrep -P "$root_pid" 2>/dev/null || true); do
    echo "$child_pid"
    descendant_process_pids "$child_pid"
  done
}

sample_stuck_swift_test_processes() {
  local label="$1"
  local root_pid="$2"
  local evidence_stem="${3:-$(lane_evidence_stem "$label")}"
  local sampled_count=0

  # Each process gets a stack sample and a task dump, attempted independently:
  # the two tools are separately available, and a missing one must not cost the
  # evidence the other can still give.
  local process_pid
  for process_pid in $(descendant_process_pids "$root_pid"); do
    local process_command
    process_command="$(ps -p "$process_pid" -o command= 2>/dev/null || true)"
    case "$process_command" in
      *AgentStudioPackageTests* | *.xctest* | *"swift test"*)
        sample_stuck_swift_test_process "$label" "$process_pid"
        dump_stuck_swift_test_process_tasks "$label" "$process_pid" "$evidence_stem"
        sampled_count=$((sampled_count + 1))
        if [ "$sampled_count" -ge 3 ]; then
          break
        fi
        ;;
    esac
  done

  if [ "$sampled_count" -eq 0 ]; then
    echo "[$LOG_PREFIX] no Swift test process matched for stack capture"
  fi
}

sample_stuck_swift_test_process() {
  local label="$1"
  local process_pid="$2"
  local sample_file
  local sample_status=0

  if [ ! -x "$LANE_STACK_SAMPLE_TOOL" ]; then
    echo "[$LOG_PREFIX] lane-report stack_sample=unavailable pid=$process_pid" \
      "reason=$LANE_STACK_SAMPLE_TOOL is not executable"
    return 0
  fi
  sample_file="$(mktemp "${TMPDIR:-/tmp}/agentstudio-swift-test-sample.XXXXXX")"
  echo "[$LOG_PREFIX] sampling stuck Swift test process pid=$process_pid for '$label'"
  "$LANE_STACK_SAMPLE_TOOL" "$process_pid" 3 1 -file "$sample_file" >/dev/null 2>&1 || sample_status=$?
  if [ "$sample_status" -eq 0 ]; then
    echo "[$LOG_PREFIX] sampled stuck Swift test process pid=$process_pid:"
    sed -n '1,220p' "$sample_file" | sed "s/^/[$LOG_PREFIX] /" || true
  else
    echo "[$LOG_PREFIX] lane-report stack_sample=unavailable pid=$process_pid" \
      "reason=$LANE_STACK_SAMPLE_TOOL exited $sample_status"
  fi
  rm -f "$sample_file"
}

# The concurrency task dump of one stuck test process, kept beside the event-stream
# ledger. `sample` shows threads, and a wedged Swift Testing run usually has none
# busy: the stuck work is suspended tasks, which only swift-inspect can list, each
# with the function it would resume in.
#
# swift-inspect exits 0 even when it cannot attach (it prints "Failed to create
# inspector" and nothing on stdout), so success is judged by the dump having
# content, and any refusal is recorded instead of failing the lane.
dump_stuck_swift_test_process_tasks() {
  local label="$1"
  local process_pid="$2"
  local evidence_stem="${3:-$(lane_evidence_stem "$label")}"
  local label_slug
  local dump_path
  local dump_error_file
  local refusal_reason

  label_slug="$(lane_event_stream_label_slug "$label")"
  mkdir -p "$LANE_EVENT_STREAM_DIR"
  dump_path="$evidence_stem-pid$process_pid.task-dump.txt"
  dump_error_file="$(mktemp "${TMPDIR:-/tmp}/agentstudio-swift-inspect-error.XXXXXX")"

  if xcrun swift-inspect dump-concurrency "$process_pid" >"$dump_path" 2>"$dump_error_file" &&
    [ -s "$dump_path" ]
  then
    echo "[$LOG_PREFIX] lane-report task_dump=$dump_path"
    prune_lane_event_streams "$label_slug"
  else
    refusal_reason="$(tr '\n' ' ' <"$dump_error_file" | sed -E 's/[[:space:]]+/ /g; s/ $//')"
    echo "[$LOG_PREFIX] lane-report task_dump=unavailable pid=$process_pid reason=${refusal_reason:-empty dump}"
    rm -f "$dump_path"
  fi
  rm -f "$dump_error_file"
}

# Signals one process tree: children first, then the root.
#
# A process-group attempt was reverted because it was environment-dependent.
# `set -m` only puts a background job in its own group when bash's job control is
# active, and whether that happens depends on the launching context: the same
# probe put the subshell in its own group in one worktree and left it in the
# parent's group in another, where `kill -<sig> -<pid>` was ESRCH and the liveness
# check then read "gone". A reap whose branch depends on the launching context
# cannot be shipped, so the tree walk is back and the survivors it cannot see are
# handled by the run token below.
terminate_lane_child_tree() {
  local signal="$1"
  local root_pid="$2"
  local child_pid

  for child_pid in $(pgrep -P "$root_pid" 2>/dev/null || true); do
    terminate_lane_child_tree "$signal" "$child_pid"
  done
  kill -"$signal" "$root_pid" 2>/dev/null || true
}

# Kills anything still carrying THIS run's event-stream path on its command line.
#
# The tree walk reads live parent links, so a helper that re-parented when its
# parent died is unreachable from the child pid — that survivor is what held a
# build slot and made the next run fail with "all 2 slots are busy". The
# event-stream path is a per-run `mktemp` name passed as
# `--event-stream-output-path`, so it appears on the command line of this lane's
# own `swift test` / `swiftpm-testing-helper` and of nothing else on the machine:
# it identifies exactly this run and can never match another worktree's. `pgrep`
# only lists; every kill is explicit and by pid, so no pattern-matching kill
# command is involved.
kill_lane_processes_by_run_token() {
  local run_token="${1:-}"
  local token_pid

  [ -n "$run_token" ] || return 0
  for token_pid in $(pgrep -f -- "$run_token" 2>/dev/null || true); do
    [ "$token_pid" = "$$" ] && continue
    kill -KILL "$token_pid" 2>/dev/null || true
  done
}

# True while any process of this run is still alive — the lane's own child, or a
# survivor that re-parented away from it.
#
# Both halves are needed. Checking only the child pid would report "gone" the
# moment the subshell honoured TERM, even though the grandchild that ignored it
# is still running and still holding a slot; that is the exact defect this path
# exists to close, and the token is the only thing that can still see it.
lane_run_has_survivors() {
  local child_pid="$1"
  local run_token="${2:-}"

  if kill -0 "$child_pid" 2>/dev/null; then
    return 0
  fi
  [ -n "$run_token" ] || return 1
  pgrep -f -- "$run_token" >/dev/null 2>&1
}

# One WebKit suite, run once. A crash fails the lane and is recorded, with its
# signal, in the same failed-isolated-suite tally the closing receipt prints.
# There is no in-lane retry: a retry turned a teardown crash into a green lane
# whose receipt said nothing, which is a rerun the CI gate could not see.
run_webkit_suite() {
  local filter="$1"
  local output
  local command_status=0
  local swift_test_bundle swift_testing_helper testing_framework_path
  swift_test_bundle="$(swift_testing_bundle_path)"
  swift_testing_helper="$(swift_testing_helper_path)"
  testing_framework_path="$(swift_testing_framework_path)"

  echo "[webkit] running $filter"
  # Use the already-built helper directly, as in the other isolated phases.
  # Concurrent `swift test --skip-build` calls contend for SwiftPM's build lock.
  # Preserve raw output so a signalled helper remains visible in the receipt.
  # Set _XCB_BYPASS on its own line: bash evaluates $() before assignments on the same line.
  _XCB_BYPASS=1
  if [ -n "${EXTRA_SWIFT_TEST_ARGS:-}" ]; then
    # swiftpm-testing-helper has no coverage option. Let SwiftPM apply the
    # requested flags to this suite rather than silently dropping them.
    # shellcheck disable=SC2086
    output=$(run_swift_with_timeout "$filter" "$TIMEOUT_SECONDS" \
      env AGENT_STUDIO_BENCHMARK_MODE=off AGENTSTUDIO_TRACE_BACKEND="${SWIFT_TEST_TRACE_BACKEND:-jsonl}" $(swift_test_parallelization_env_word) \
      swift test $(swift_package_sandbox_arguments) ${EXTRA_SWIFT_TEST_ARGS} --skip-build --filter "$filter" --build-path "$BUILD_PATH" \
      2>&1) || command_status=$?
  else
    output=$(run_swift_with_timeout "$filter" "$TIMEOUT_SECONDS" \
      env AGENT_STUDIO_BENCHMARK_MODE=off AGENTSTUDIO_TRACE_BACKEND="${SWIFT_TEST_TRACE_BACKEND:-jsonl}" $(swift_test_parallelization_env_word) \
      DYLD_FRAMEWORK_PATH="$testing_framework_path" \
      "$swift_testing_helper" --test-bundle-path "$swift_test_bundle" \
      --filter "$filter" "$swift_test_bundle" --testing-library swift-testing \
      2>&1) || command_status=$?
  fi
  unset _XCB_BYPASS
  echo "$output"

  if [ "$command_status" -ne 0 ]; then
    local signal_name
    signal_name="$(swift_test_crash_signal_name "$command_status" "$output")"
    echo "[$LOG_PREFIX] WebKit suite failed: $filter status=$command_status signal=$signal_name" >&2
    swift_test_record_failed_isolated_suite "$filter" "$command_status" "$signal_name"
  fi
  return "$command_status"
}
